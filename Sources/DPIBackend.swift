import Foundation

enum DPIBackend: String, CaseIterable, Identifiable, Codable {
    case tpws
    case ciadpi
    case spoofdpi
    case touchcore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tpws: return "tpws"
        case .ciadpi: return "ciadpi"
        case .spoofdpi: return "spoofdpi"
        case .touchcore: return "touchcore"
        }
    }

    var binaryName: String { rawValue }

    init?(rawValue: String) {
        switch rawValue {
        case "touchdpi": self = .touchcore
        case "tpws": self = .tpws
        case "ciadpi": self = .ciadpi
        case "spoofdpi": self = .spoofdpi
        case "touchcore": self = .touchcore
        default: return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = DPIBackend(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown backend: \(raw)"
            )
        }
        self = value
    }
}

/// ByeDPI / ciadpi strategies for macOS SOCKS mode.
enum CiadpiStrategy: String, CaseIterable, Identifiable, Codable {
    case disorder1
    case disorderSni
    case split1
    case tlsrecSni
    case oobSni
    case splitDisorder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disorder1: return "disorder-1"
        case .disorderSni: return "disorder-sni"
        case .split1: return "split-1"
        case .tlsrecSni: return "tlsrec-sni"
        case .oobSni: return "oob-sni"
        case .splitDisorder: return "split+disorder"
        }
    }

    var arguments: [String] {
        switch self {
        case .disorder1: return ["-d", "1"]
        case .disorderSni: return ["-d", "1+s"]
        case .split1: return ["-s", "1"]
        case .tlsrecSni: return ["-r", "1+s"]
        case .oobSni: return ["-o", "1+s"]
        case .splitDisorder: return ["-s", "1", "-d", "1"]
        }
    }
}

/// SpoofDPI strategies (TLS ClientHello fragmentation).
enum SpoofDPIStrategy: String, CaseIterable, Identifiable, Codable {
    case chunk1
    case chunk2
    case chunk3
    case chunk1Fake
    case splitSni

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chunk1: return "chunk-1"
        case .chunk2: return "chunk-2"
        case .chunk3: return "chunk-3"
        case .chunk1Fake: return "chunk-1+fake"
        case .splitSni: return "split-sni"
        }
    }

    var arguments: [String] {
        switch self {
        case .chunk1:
            return ["--https-split-default", "chunk", "--https-chunk-size", "1"]
        case .chunk2:
            return ["--https-split-default", "chunk", "--https-chunk-size", "2"]
        case .chunk3:
            return ["--https-split-default", "chunk", "--https-chunk-size", "3"]
        case .chunk1Fake:
            return [
                "--https-split-default", "chunk", "--https-chunk-size", "1",
                "--https-fake-count", "1"
            ]
        case .splitSni:
            return ["--https-split-default", "sni"]
        }
    }
}

/// God Touch Rust DPI engine (SOCKS5 + TLS tamper, macOS syscall-level).
enum TouchCoreStrategy: String, CaseIterable, Identifiable, Codable {
    case comboMidsld
    case comboSni
    case multiSniMidsld
    case split1
    case split2
    case splitSni
    case splitMidsld
    case disorder1
    case disorderSni
    case disorderMidsld
    case tlsrec1
    case tlsrecMidsld
    case oob1

    var id: String { rawValue }

    var title: String {
        switch self {
        case .comboMidsld: return "combo-midsld"
        case .comboSni: return "combo-sni"
        case .multiSniMidsld: return "multi-sni-midsld"
        case .split1: return "split-1"
        case .split2: return "split-2"
        case .splitSni: return "split-sni"
        case .splitMidsld: return "split-midsld"
        case .disorder1: return "disorder-1"
        case .disorderSni: return "disorder-sni"
        case .disorderMidsld: return "disorder-midsld"
        case .tlsrec1: return "tlsrec-1"
        case .tlsrecMidsld: return "tlsrec-midsld"
        case .oob1: return "oob-1"
        }
    }

    var arguments: [String] {
        switch self {
        case .comboMidsld:
            return ["--split-pos", "midsld", "--disorder", "--tlsrec", "midsld"]
        case .comboSni:
            return ["--split", "sni", "--disorder", "--tlsrec", "midsld"]
        case .multiSniMidsld:
            return ["--split-pos", "sni,midsld", "--disorder", "--tlsrec", "midsld"]
        case .split1:
            return ["--split", "1"]
        case .split2:
            return ["--split", "2"]
        case .splitSni:
            return ["--split", "sni"]
        case .splitMidsld:
            return ["--split", "midsld"]
        case .disorder1:
            return ["--split", "1", "--disorder"]
        case .disorderSni:
            return ["--split", "sni", "--disorder"]
        case .disorderMidsld:
            return ["--split", "midsld", "--disorder"]
        case .tlsrec1:
            return ["--split", "1", "--tlsrec", "1"]
        case .tlsrecMidsld:
            return ["--split", "midsld", "--tlsrec", "midsld"]
        case .oob1:
            return ["--oob"]
        }
    }
}

struct DPIProfile: Codable, Identifiable, Equatable, Hashable {
    let backend: DPIBackend
    let strategyId: String

    var id: String { "\(backend.rawValue):\(strategyId)" }

    var title: String {
        if let s = zapretStrategy { return "\(backend.title) · \(s.title)" }
        if let s = ciadpiStrategy { return "\(backend.title) · \(s.title)" }
        if let s = spoofdpiStrategy { return "\(backend.title) · \(s.title)" }
        if let s = touchcoreStrategy { return "\(backend.title) · \(s.title)" }
        return "\(backend.title) · \(strategyId)"
    }

    var shortTitle: String {
        zapretStrategy?.title ?? ciadpiStrategy?.title ?? spoofdpiStrategy?.title
            ?? touchcoreStrategy?.title ?? strategyId
    }

    var arguments: [String] {
        zapretStrategy?.arguments ?? ciadpiStrategy?.arguments ?? spoofdpiStrategy?.arguments
            ?? touchcoreStrategy?.arguments ?? []
    }

    var argumentsLine: String { arguments.joined(separator: " ") }

    var zapretStrategy: ZapretStrategy? {
        guard backend == .tpws else { return nil }
        return ZapretStrategy(rawValue: strategyId)
    }

    var ciadpiStrategy: CiadpiStrategy? {
        guard backend == .ciadpi else { return nil }
        return CiadpiStrategy(rawValue: strategyId)
    }

    var spoofdpiStrategy: SpoofDPIStrategy? {
        guard backend == .spoofdpi else { return nil }
        return SpoofDPIStrategy(rawValue: strategyId)
    }

    var touchcoreStrategy: TouchCoreStrategy? {
        guard backend == .touchcore else { return nil }
        return TouchCoreStrategy(rawValue: strategyId)
    }

    static let `default` = DPIProfile(backend: .touchcore, strategyId: TouchCoreStrategy.comboMidsld.rawValue)

    static func allProfiles() -> [DPIProfile] {
        var out: [DPIProfile] = []
        for s in ZapretStrategy.allCases {
            out.append(DPIProfile(backend: .tpws, strategyId: s.rawValue))
        }
        for s in CiadpiStrategy.allCases {
            out.append(DPIProfile(backend: .ciadpi, strategyId: s.rawValue))
        }
        for s in SpoofDPIStrategy.allCases {
            out.append(DPIProfile(backend: .spoofdpi, strategyId: s.rawValue))
        }
        for s in TouchCoreStrategy.allCases {
            out.append(DPIProfile(backend: .touchcore, strategyId: s.rawValue))
        }
        return out
    }

    /// Fast SCAN order — likely winners first; full list only if none work.
    static func scanProfiles() -> [DPIProfile] {
        let picks: [(DPIBackend, String)] = [
            (.touchcore, TouchCoreStrategy.comboMidsld.rawValue),
            (.touchcore, TouchCoreStrategy.disorderMidsld.rawValue),
            (.touchcore, TouchCoreStrategy.comboSni.rawValue),
            (.touchcore, TouchCoreStrategy.multiSniMidsld.rawValue),
            (.tpws, ZapretStrategy.disorderMidsld.rawValue),
            (.tpws, ZapretStrategy.tlsrecMidsld.rawValue),
            (.tpws, ZapretStrategy.alt.rawValue),
            (.tpws, ZapretStrategy.alt2.rawValue),
            (.tpws, ZapretStrategy.general.rawValue),
            (.ciadpi, CiadpiStrategy.disorderSni.rawValue),
            (.spoofdpi, SpoofDPIStrategy.chunk1.rawValue),
        ]
        return picks.map { DPIProfile(backend: $0.0, strategyId: $0.1) }
    }

    static func scanFallbackProfiles(excluding scanned: [DPIProfile]) -> [DPIProfile] {
        let seen = Set(scanned.map(\.id))
        return allProfiles().filter { !seen.contains($0.id) }
    }

    static func parseArgumentsLine(_ line: String, backend: DPIBackend) -> [String] {
        line.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
