import Foundation

/// When touchcore profile fails connectivity, try equivalent tpws strategy.
enum DPIFallback {
    static func tpwsEquivalent(for profile: DPIProfile) -> DPIProfile? {
        guard profile.backend == .touchcore,
              let core = profile.touchcoreStrategy else { return nil }
        let zapret: ZapretStrategy? = switch core {
        case .comboMidsld, .disorderMidsld, .tlsrecMidsld, .splitMidsld:
            .tlsrecMidsld
        case .comboSni, .disorderSni, .splitSni, .multiSniMidsld:
            .disorderMidsld
        case .disorder1, .split1, .split2, .tlsrec1:
            .general
        case .oob1:
            .oobMidsld
        }
        guard let zapret else { return nil }
        return DPIProfile(backend: .tpws, strategyId: zapret.rawValue)
    }

    /// Fast connect — no curl probe unless touchcore needs tpws fallback.
    static func startForConnect(dpi: DPIService, profile: DPIProfile) throws -> DPIProfile {
        try dpi.start(profile: profile)
        guard profile.backend == .touchcore else { return profile }

        Thread.sleep(forTimeInterval: 0.12)
        if StrategyProbe.quickCheck(dpi: dpi) { return profile }

        if let fallback = tpwsEquivalent(for: profile) {
            dpi.stop(portWait: 0.35)
            try dpi.start(profile: fallback, probeMode: true)
            return fallback
        }
        return profile
    }
}
