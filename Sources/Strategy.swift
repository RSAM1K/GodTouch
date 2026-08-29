import Foundation

/// tpws strategies inspired by Flowseal/zapret-discord-youtube and zapret-macos-easy.
/// Do not combine --oob and --disorder in one strategy.
enum ZapretStrategy: String, CaseIterable, Identifiable, Codable {
    case general
    case alt
    case alt2
    case alt3
    case simple
    case oobMidsld
    case disorderMidsld
    case tlsrecMidsld
    case oobTlsrec

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "general"
        case .alt: return "ALT"
        case .alt2: return "ALT2"
        case .alt3: return "ALT3"
        case .simple: return "simple"
        case .oobMidsld: return "oob-midsld"
        case .disorderMidsld: return "disorder-midsld"
        case .tlsrecMidsld: return "tlsrec-midsld"
        case .oobTlsrec: return "oob-tlsrec"
        }
    }

    /// tpws tamper flags (SOCKS mode; bind/port added by DPIService).
    var arguments: [String] {
        switch self {
        case .general:
            return ["--split-pos=1", "--disorder", "--tlsrec=1"]
        case .alt:
            return ["--split-pos=1", "--oob"]
        case .alt2:
            return ["--split-pos=1", "--tlsrec=1"]
        case .alt3:
            return ["--split-pos=1", "--disorder"]
        case .simple:
            return ["--split-pos=1"]
        case .oobMidsld:
            return ["--split-pos=midsld", "--oob"]
        case .disorderMidsld:
            return ["--split-pos=midsld", "--disorder"]
        case .tlsrecMidsld:
            return ["--split-pos=1", "--tlsrec=midsld"]
        case .oobTlsrec:
            return ["--split-pos=1", "--tlsrec=1", "--oob"]
        }
    }

    var argumentsLine: String { arguments.joined(separator: " ") }

    static func parseArgumentsLine(_ line: String) -> [String] {
        line.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

enum StrategyMode: String, CaseIterable, Identifiable, Codable {
    case auto
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Авто"
        case .manual: return "Вручную"
        }
    }
}

enum TouchSettings {
    private static let strategyKey = "touch.selectedStrategy"
    private static let profileKey = "touch.selectedProfile"
    private static let probedKey = "touch.hasProbed"
    private static let strategyModeKey = "touch.strategyMode"
    private static let customArgsKey = "touch.customStrategyArgs"
    private static let customBackendKey = "touch.customBackend"

    static func savedProfile() -> DPIProfile? {
        if let raw = UserDefaults.standard.string(forKey: profileKey),
           let data = raw.data(using: .utf8),
           let profile = try? JSONDecoder().decode(DPIProfile.self, from: data) {
            if raw.contains("touchdpi") {
                save(profile: profile)
            }
            return profile
        }
        if let legacy = savedStrategyLegacy() {
            return DPIProfile(backend: .tpws, strategyId: legacy.rawValue)
        }
        return nil
    }

    private static func savedStrategyLegacy() -> ZapretStrategy? {
        guard let raw = UserDefaults.standard.string(forKey: strategyKey) else { return nil }
        return ZapretStrategy(rawValue: raw)
    }

    static func save(profile: DPIProfile) {
        if let data = try? JSONEncoder().encode(profile),
           let raw = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(raw, forKey: profileKey)
        }
        UserDefaults.standard.set(profile.strategyId, forKey: strategyKey)
        UserDefaults.standard.set(true, forKey: probedKey)
    }

    /// Legacy helper for tpws-only call sites during migration.
    static func savedStrategy() -> ZapretStrategy? {
        savedProfile()?.zapretStrategy
    }

    static func save(strategy: ZapretStrategy) {
        save(profile: DPIProfile(backend: .tpws, strategyId: strategy.rawValue))
    }

    static var hasProbed: Bool {
        UserDefaults.standard.bool(forKey: probedKey)
    }

    static func clearProbe() {
        UserDefaults.standard.removeObject(forKey: probedKey)
    }

    static func resetStrategy() {
        UserDefaults.standard.removeObject(forKey: strategyKey)
        UserDefaults.standard.removeObject(forKey: profileKey)
        UserDefaults.standard.removeObject(forKey: probedKey)
        UserDefaults.standard.removeObject(forKey: customArgsKey)
        UserDefaults.standard.removeObject(forKey: customBackendKey)
        strategyMode = .auto
    }

    static var customStrategyArgs: String {
        get { UserDefaults.standard.string(forKey: customArgsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: customArgsKey) }
    }

    static var customBackend: DPIBackend {
        get {
            guard let raw = UserDefaults.standard.string(forKey: customBackendKey) else { return .tpws }
            if raw == "touchdpi" {
                UserDefaults.standard.set(DPIBackend.touchcore.rawValue, forKey: customBackendKey)
                return .touchcore
            }
            guard let b = DPIBackend(rawValue: raw) else { return .tpws }
            return b
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: customBackendKey) }
    }

    static func effectiveArguments(for profile: DPIProfile) -> [String] {
        if strategyMode == .manual {
            let custom = customStrategyArgs.trimmingCharacters(in: .whitespacesAndNewlines)
            if !custom.isEmpty {
                return DPIProfile.parseArgumentsLine(custom, backend: profile.backend)
            }
        }
        return profile.arguments
    }

    static var strategyMode: StrategyMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: strategyModeKey),
                  let mode = StrategyMode(rawValue: raw) else { return .auto }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: strategyModeKey) }
    }

    private static let launchAtLoginKey = "touch.launchAtLogin"
    private static let autoConnectKey = "touch.autoConnect"

    static var launchAtLogin: Bool {
        get { UserDefaults.standard.bool(forKey: launchAtLoginKey) }
        set { UserDefaults.standard.set(newValue, forKey: launchAtLoginKey) }
    }

    static var autoConnect: Bool {
        get { UserDefaults.standard.bool(forKey: autoConnectKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoConnectKey) }
    }

    private static let tgProxyKey = "touch.telegramProxyOffered"

    static var telegramProxyOffered: Bool {
        UserDefaults.standard.bool(forKey: tgProxyKey)
    }

    static func markTelegramProxyOffered() {
        UserDefaults.standard.set(true, forKey: tgProxyKey)
    }

    static func resetTelegramProxyOffer() {
        UserDefaults.standard.removeObject(forKey: tgProxyKey)
    }
}

enum HostLists {
    static func load(from resourceDir: URL) -> [String] {
        let files = ["list-general.txt", "list-google.txt"]
        var out: [String] = []
        for name in files {
            let url = resourceDir.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for raw in text.split(separator: "\n") {
                var line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                if line.hasPrefix("^") { line.removeFirst() }
                out.append(line)
            }
        }
        return Array(Set(out)).sorted()
    }

    static func pacScript(domains: [String], socksPort: Int) -> String {
        var body = """
        function FindProxyForURL(url, host) {
          host = host.toLowerCase();
          if (host == "127.0.0.1" || host == "localhost") return "DIRECT";

        """
        for d in domains {
            let lower = d.lowercased()
            body += "  if (dnsDomainIs(host, \"\(lower)\") || shExpMatch(host, \"*.\(lower)\")) return \"SOCKS5 127.0.0.1:\(socksPort)\";\n"
        }
        body += "  return \"DIRECT\";\n}\n"
        return body
    }
}
