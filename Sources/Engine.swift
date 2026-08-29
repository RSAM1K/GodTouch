import Foundation
import Combine

enum ScanMark: Equatable {
    case idle
    case testing
    case ok
    case fail
}

@MainActor
final class Engine: ObservableObject {
    @Published var isOn = false
    @Published var busy = false
    @Published var status = "Выключено"
    @Published var profile: DPIProfile = .default
    @Published var lastError: String?
    @Published var probing = false
    @Published var probeProgress = ""
    @Published var scanMarks: [String: ScanMark] = [:]
    @Published var scanLatencies: [String: Int] = [:]
    @Published var activeScanTargetId: String?
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
        } else {
            profile = .default
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

    func scanMark(for target: ScanTarget) -> ScanMark {
        scanMarks[target.id] ?? .idle
    }

    var scanningAll: Bool {
        probing && activeScanTargetId == ScanTargets.allScanId
    }

    private func resetScanMarks(testing: Bool = false) {
        scanMarks = Dictionary(
            uniqueKeysWithValues: ScanTargets.bundle.map {
                ($0.id, testing ? ScanMark.testing : ScanMark.idle)
            }
        )
    }

    private func applyScanHit(_ targetId: String, hit: ServiceProbe?) {
        guard let hit else {
            scanMarks[targetId] = .fail
            return
        }
        scanMarks[targetId] = hit.ok ? .ok : .fail
        if hit.ok {
            scanLatencies[targetId] = hit.ms
        }
    }

    func pingServices(profile: DPIProfile? = nil, arguments: [String]? = nil) async -> (rows: [PingRow], error: String?) {
        let wasConnected = isOn
        let probeProfile = profile ?? (wasConnected ? self.profile : activeProfileForProbe())
        let probeArgs = arguments ?? TouchSettings.effectiveArguments(for: probeProfile)
        let restoreProfile = wasConnected ? self.profile : nil
        let restoreArgs = TouchSettings.effectiveArguments(for: restoreProfile ?? probeProfile)

        dpi.stop(portWait: 0.35)
        do {
            try dpi.start(profile: probeProfile, probeMode: true, argumentsOverride: probeArgs)
            let warmup: UInt64 = probeProfile.backend == .touchcore
                ? 450_000_000
                : 220_000_000
            try await Task.sleep(nanoseconds: warmup)
        } catch {
            dpi.stop()
            if let restoreProfile, wasConnected {
                try? dpi.start(profile: restoreProfile, argumentsOverride: restoreArgs)
            }
            return ([], error.localizedDescription)
        }

        let tgPort = telegram.isRunning ? telegram.port : nil
        let longProbe = probeProfile.backend == .touchcore
        let rows = await Task.detached { [dpi, tgPort, longProbe] in
            ConnectivityTest.run(
                dpiPort: dpi.port,
                telegramPort: tgPort,
                timeout: longProbe ? 7 : 5,
                connectTimeout: longProbe ? 4 : 4
            )
        }.value

        dpi.stop(portWait: 0.35)
        if let restoreProfile, wasConnected {
            try? dpi.start(profile: restoreProfile, argumentsOverride: restoreArgs)
        }

        return (rows, nil)
    }

    private func activeProfileForProbe() -> DPIProfile {
        if TouchSettings.strategyMode == .manual {
            return TouchSettings.savedProfile() ?? profile
        }
        if let saved = TouchSettings.savedProfile() {
            return saved
        }
        return profile
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
            try telegram.start()
            try pac.start(pacScript: pacBody)
            isOn = true
            status = statusLine(profile: profile)
            telegramUp = telegram.isRunning
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

    private func applyScanServices(_ services: [ServiceProbe]) {
        for service in services {
            applyScanHit(service.targetId, hit: service)
        }
    }

    private func finishScan(
        gen: Int,
        profile: DPIProfile,
        reconnect: Bool,
        statusLine: String
    ) {
        guard gen == generation else { return }
        probing = false
        busy = false
        activeScanTargetId = nil
        probeProgress = ""
        TouchSettings.strategyMode = .auto
        TouchSettings.save(profile: profile)
        self.profile = profile
        lastError = nil
        status = statusLine
        if reconnect {
            reconnectIfOn()
        }
    }

    func scanAll() {
        guard !busy else { return }

        generation += 1
        let gen = generation
        busy = true
        probing = true
        lastError = nil
        activeScanTargetId = ScanTargets.allScanId
        probeProgress = ""
        resetScanMarks(testing: true)
        status = "SCAN ALL…"

        let reconnect = isOn

        Task.detached { [dpi] in
            let best = StrategyProbe.findBestOverall(dpi: dpi) { profile, current, total, services in
                Task { @MainActor in
                    guard gen == self.generation else { return }
                    self.probeProgress = "\(current)/\(total)"
                    self.status = "ALL · \(profile.shortTitle)"
                    self.applyScanServices(services)
                }
            }

            dpi.stop()

            await MainActor.run {
                guard gen == self.generation else { return }
                guard let best else {
                    self.probing = false
                    self.busy = false
                    self.activeScanTargetId = nil
                    self.probeProgress = ""
                    self.lastError = "Нет рабочей стратегии"
                    self.status = "Ошибка"
                    return
                }

                let line = "ALL \(best.passCount)/\(best.services.count) · \(best.profile.shortTitle) · \(best.latencyMs)ms"
                self.finishScan(
                    gen: gen,
                    profile: best.profile,
                    reconnect: reconnect,
                    statusLine: line
                )
            }
        }
    }

    func scanForTarget(_ target: ScanTarget) {
        guard !busy else { return }

        generation += 1
        let gen = generation
        busy = true
        probing = true
        lastError = nil
        activeScanTargetId = target.id
        probeProgress = ""
        resetScanMarks()
        scanMarks[target.id] = .testing
        scanLatencies.removeValue(forKey: target.id)
        status = "SCAN \(target.tag)…"

        let reconnect = isOn

        Task.detached { [dpi] in
            let best = StrategyProbe.findBest(for: target, dpi: dpi) { profile, current, total, hit in
                Task { @MainActor in
                    guard gen == self.generation else { return }
                    self.probeProgress = "\(current)/\(total)"
                    self.status = "\(target.tag) · \(profile.shortTitle)"
                    self.applyScanHit(target.id, hit: hit)
                }
            }

            dpi.stop()

            await MainActor.run {
                guard gen == self.generation else { return }
                guard let best else {
                    self.probing = false
                    self.busy = false
                    self.activeScanTargetId = nil
                    self.probeProgress = ""
                    self.scanMarks[target.id] = .fail
                    self.lastError = "Нет стратегии для \(target.tag)"
                    self.status = "Ошибка"
                    return
                }

                self.scanMarks[target.id] = .ok
                self.scanLatencies[target.id] = best.latencyMs
                self.finishScan(
                    gen: gen,
                    profile: best.profile,
                    reconnect: reconnect,
                    statusLine: "\(target.tag) · \(best.profile.shortTitle) · \(best.latencyMs)ms"
                )
            }
        }
    }

    func setupTelegramAgain() {
        TouchSettings.resetTelegramProxyOffer()
        if !telegram.isRunning, isOn {
            try? telegram.start()
        }
        telegram.offerProxyToTelegram(force: true)
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
        let domains = HostLists.load(from: resourceDir)
        let pacBody = HostLists.pacScript(domains: domains, socksPort: dpi.port)
        _ = forceProbe

        Task.detached { [dpi, telegram, pac] in
            var chosen = await MainActor.run { self.profile }
            if let saved = TouchSettings.savedProfile() {
                chosen = saved
            }
            do {
                await Self.setStatus(self, gen, "Запуск…")
                chosen = try DPIFallback.startForConnect(dpi: dpi, profile: chosen)

                try pac.start(pacScript: pacBody)
                await Self.setStatus(self, gen, "Пароль Mac…")
                try SystemProxy.enablePAC(pac.url)

                await Self.setStatus(self, gen, "Telegram…")
                try telegram.start()
                TouchSettings.resetTelegramProxyOffer()
                await MainActor.run {
                    telegram.offerProxyToTelegram(force: true)
                }

                let finalProfile = chosen
                await MainActor.run {
                    guard gen == self.generation else { return }
                    self.profile = finalProfile
                    self.isOn = true
                    self.busy = false
                    self.probing = false
                    self.probeProgress = ""
                    self.needsTelegramSetup = true
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
