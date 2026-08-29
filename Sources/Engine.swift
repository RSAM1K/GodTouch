import Foundation
import Combine

@MainActor
final class Engine: ObservableObject {
    @Published var isOn = false
    @Published var busy = false
    @Published var status = "Выключено"
    @Published var profile: DPIProfile = .default
    @Published var lastError: String?
    @Published var probing = false
    @Published var probeProgress = ""
    @Published var needsTelegramSetup = false
    @Published var telegramUp = false

    private let dpi: DPIService
    private let telegram: TelegramService
    private let pac = PACServer()
    private let resourceDir: URL
    private var generation = 0

    init() {
        let res = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        self.resourceDir = res
        self.dpi = DPIService(resourceDir: res)
        self.telegram = TelegramService(binary: res.appendingPathComponent("tg-proxy"))
        if let saved = TouchSettings.savedProfile() {
            profile = saved
        }
        startWatchdog()
        Task { await self.healOrphanPAC() }
        scheduleAutoConnectIfNeeded()
    }

    private func scheduleAutoConnectIfNeeded() {
        guard TouchSettings.autoConnect else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.isOn, !self.busy else { return }
            self.turnOn()
        }
    }

    var engineStatusText: String {
        if isOn {
            if TouchSettings.strategyMode == .manual,
               !TouchSettings.customStrategyArgs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               TouchSettings.customStrategyArgs != profile.argumentsLine {
                return "ENG: \(profile.backend.title) · custom"
            }
            return "ENG: \(profile.title)"
        }
        if let saved = TouchSettings.savedProfile(), TouchSettings.hasProbed {
            return "ENG: \(saved.title)"
        }
        return "ENG: —"
    }

    var servicesStatusText: String {
        telegramUp ? "TG ✓" : "TG —"
    }

    func pingServices() async -> [PingRow] {
        let dpiPort = dpi.port
        let tgPort = telegram.isRunning ? telegram.port : nil
        guard dpi.isRunning else { return [] }
        return await Task.detached {
            ConnectivityTest.run(dpiPort: dpiPort, telegramPort: tgPort)
        }.value
    }

    private func startWatchdog() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isOn, !self.busy else { return }
                if !self.dpi.isRunning {
                    try? self.dpi.start(profile: self.profile)
                }
                if !self.telegram.isRunning {
                    try? self.telegram.start()
                }
                self.telegramUp = self.telegram.isRunning
            }
        }
    }

    private func healOrphanPAC() async {
        guard SystemProxy.autoProxyOurs() else { return }
        status = "Восстанавливаю…"
        let domains = HostLists.load(from: resourceDir)
        let pacBody = HostLists.pacScript(domains: domains, socksPort: dpi.port)
        let profile = self.profile
        do {
            try dpi.start(profile: profile)
            try pac.start(pacScript: pacBody)
            isOn = true
            status = statusLine(profile: profile)
        } catch {
            lastError = error.localizedDescription
            status = "Ошибка"
        }
    }

    func toggle() {
        if busy {
            cancel()
            return
        }
        if isOn { turnOff() } else { turnOn() }
    }

    func cancel() {
        generation += 1
        dpi.stop()
        pac.stop()
        telegram.stop()
        try? SystemProxy.disableAll()
        isOn = false
        busy = false
        probing = false
        probeProgress = ""
        needsTelegramSetup = false
        telegramUp = false
        status = "Выключено"
        lastError = "Отменено"
    }

    func reprobeStrategies() {
        guard !busy else { return }
        TouchSettings.clearProbe()
        TouchSettings.strategyMode = .auto
        if isOn {
            turnOff()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.turnOn(forceProbe: true)
            }
        } else {
            turnOn(forceProbe: true)
        }
    }

    func setupTelegramAgain() {
        TouchSettings.resetTelegramProxyOffer()
        if !telegram.isRunning, isOn {
            try? telegram.start()
        }
        telegram.offerProxyToTelegram()
        needsTelegramSetup = true
    }

    func saveStrategySettings(mode: StrategyMode, profile: DPIProfile, argsLine: String) throws {
        TouchSettings.strategyMode = mode
        TouchSettings.save(profile: profile)
        TouchSettings.customBackend = profile.backend
        if mode == .manual {
            let trimmed = argsLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw NSError(domain: "Touch", code: 20, userInfo: [
                    NSLocalizedDescriptionKey: "Введи флаги движка"
                ])
            }
            TouchSettings.customStrategyArgs = trimmed
        } else {
            TouchSettings.customStrategyArgs = ""
        }
        self.profile = profile
        reconnectIfOn()
    }

    func reconnectIfOn() {
        guard isOn, !busy else { return }
        turnOff()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.turnOn()
        }
    }

    func turnOn(forceProbe: Bool = false) {
        guard !busy else { return }
        busy = true
        lastError = nil
        needsTelegramSetup = false
        generation += 1
        let gen = generation
        let mode = TouchSettings.strategyMode
        let needsProbe = forceProbe || (mode == .auto && !TouchSettings.hasProbed)
        let domains = HostLists.load(from: resourceDir)
        let pacBody = HostLists.pacScript(domains: domains, socksPort: dpi.port)

        Task.detached { [dpi, telegram, pac] in
            var chosen = await MainActor.run { self.profile }
            if let saved = TouchSettings.savedProfile() {
                chosen = saved
            }
            do {
                if needsProbe {
                    await Self.setProbing(self, gen, true, "Подбор…")
                    let best = StrategyProbe.findBest(dpi: dpi) { profile, current, total in
                        Task { @MainActor in
                            guard gen == self.generation else { return }
                            self.probeProgress = "\(current)/\(total)"
                            self.status = profile.shortTitle
                        }
                    }
                    await Self.setProbing(self, gen, false, "")
                    guard let best else {
                        throw NSError(domain: "Touch", code: 10, userInfo: [
                            NSLocalizedDescriptionKey: "Не нашёл рабочую стратегию"
                        ])
                    }
                    chosen = best.profile
                    TouchSettings.save(profile: chosen)
                    try dpi.start(profile: chosen)
                } else {
                    await Self.setStatus(self, gen, "Запуск…")
                    try dpi.start(profile: chosen)
                }

                try pac.start(pacScript: pacBody)
                await Self.setStatus(self, gen, "Пароль Mac…")
                try SystemProxy.enablePAC(pac.url)

                await Self.setStatus(self, gen, "Telegram…")
                try telegram.start()
                let offerTG = !TouchSettings.telegramProxyOffered
                await MainActor.run {
                    if offerTG {
                        telegram.offerProxyToTelegram()
                    }
                }

                let finalProfile = chosen
                await MainActor.run {
                    guard gen == self.generation else { return }
                    self.profile = finalProfile
                    self.isOn = true
                    self.busy = false
                    self.probing = false
                    self.probeProgress = ""
                    self.needsTelegramSetup = offerTG
                    self.telegramUp = telegram.isRunning
                    self.lastError = nil
                    self.status = self.statusLine(profile: finalProfile)
                }
            } catch {
                dpi.stop()
                pac.stop()
                telegram.stop()
                try? SystemProxy.disableAll()
                await MainActor.run {
                    guard gen == self.generation else { return }
                    self.isOn = false
                    self.busy = false
                    self.probing = false
                    self.probeProgress = ""
                    self.needsTelegramSetup = false
                    self.telegramUp = false
                    self.lastError = error.localizedDescription
                    self.status = "Ошибка"
                }
            }
        }
    }

    func turnOff() {
        generation += 1
        busy = true
        status = "Выключаю…"
        Task.detached { [dpi, telegram, pac] in
            dpi.stop()
            pac.stop()
            telegram.stop()
            try? SystemProxy.disableAll()
            await MainActor.run {
                self.isOn = false
                self.busy = false
                self.probing = false
                self.probeProgress = ""
                self.needsTelegramSetup = false
                self.telegramUp = false
                self.status = "Выключено"
            }
        }
    }

    private func statusLine(profile: DPIProfile) -> String {
        if TouchSettings.strategyMode == .manual,
           !TouchSettings.customStrategyArgs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           TouchSettings.customStrategyArgs != profile.argumentsLine {
            return "Работает · \(profile.backend.title) · custom"
        }
        return "Работает · \(profile.title)"
    }

    private static func setStatus(_ engine: Engine, _ gen: Int, _ text: String) async {
        await MainActor.run {
            guard gen == engine.generation else { return }
            engine.status = text
        }
    }

    private static func setProbing(_ engine: Engine, _ gen: Int, _ on: Bool, _ text: String) async {
        await MainActor.run {
            guard gen == engine.generation else { return }
            engine.probing = on
            if !text.isEmpty { engine.status = text }
            if !on { engine.probeProgress = "" }
        }
    }
}
