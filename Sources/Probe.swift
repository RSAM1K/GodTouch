import Foundation

struct TargetProbeResult: Sendable {
    let profile: DPIProfile
    let target: ScanTarget
    let latencyMs: Int
}

struct BundleProbeResult: Sendable {
    let profile: DPIProfile
    let services: [ServiceProbe]

    /// How many targets (DS/YT/TW/DBD) respond through this profile.
    var passCount: Int { services.filter(\.ok).count }
    /// Worst latency among working targets — used to compare profiles fairly.
    var latencyMs: Int {
        let hits = services.filter(\.ok).map(\.ms)
        return hits.isEmpty ? Int.max : hits.max()!
    }

    /// More working resources wins; tie → lower max latency.
    func better(than other: BundleProbeResult) -> Bool {
        if passCount != other.passCount { return passCount > other.passCount }
        return latencyMs < other.latencyMs
    }
}

enum StrategyProbe {
    private static let probeTimeout = 6
    private static let connectTimeout = 4

    /// Single resource: scan every profile, pick lowest latency (not the first hit).
    static func findBest(
        for target: ScanTarget,
        dpi: DPIService,
        onProgress: @escaping @Sendable (DPIProfile, Int, Int, ServiceProbe?) -> Void
    ) -> TargetProbeResult? {
        let all = profileList()
        var best: TargetProbeResult?

        for (index, profile) in all.enumerated() {
            dpi.stop(portWait: 0.35)
            do {
                try dpi.start(profile: profile, probeMode: true)
            } catch {
                onProgress(profile, index + 1, all.count, nil)
                continue
            }

            let hit = probeTarget(dpi: dpi, target: target)
            onProgress(profile, index + 1, all.count, hit)

            guard hit.ok else { continue }
            let entry = TargetProbeResult(profile: profile, target: target, latencyMs: hit.ms)
            if let current = best {
                if entry.latencyMs < current.latencyMs { best = entry }
            } else {
                best = entry
            }
        }

        dpi.stop()
        return best
    }

    /// All resources: scan every profile; most working wins, then lowest max latency.
    static func findBestOverall(
        dpi: DPIService,
        onProgress: @escaping @Sendable (DPIProfile, Int, Int, [ServiceProbe]) -> Void
    ) -> BundleProbeResult? {
        let all = profileList()
        var best: BundleProbeResult?

        for (index, profile) in all.enumerated() {
            dpi.stop(portWait: 0.35)
            do {
                try dpi.start(profile: profile, probeMode: true)
            } catch {
                onProgress(profile, index + 1, all.count, [])
                continue
            }

            let services = probeAll(dpi: dpi)
            onProgress(profile, index + 1, all.count, services)

            let result = BundleProbeResult(profile: profile, services: services)
            guard result.passCount > 0 else { continue }

            if let current = best {
                if result.better(than: current) { best = result }
            } else {
                best = result
            }
        }

        dpi.stop()
        return best
    }

    private static func profileList() -> [DPIProfile] {
        let priority = DPIProfile.scanProfiles()
        let fallback = DPIProfile.scanFallbackProfiles(excluding: priority)
        return priority + fallback
    }

    static func probeAll(dpi: DPIService) -> [ServiceProbe] {
        ScanTargets.probe(
            port: dpi.port,
            timeout: probeTimeout,
            connectTimeout: connectTimeout
        )
    }

    static func probeTarget(dpi: DPIService, target: ScanTarget) -> ServiceProbe {
        let r = ScanTargets.curlTest(
            url: target.url,
            port: dpi.port,
            timeout: probeTimeout,
            connectTimeout: connectTimeout,
            headOnly: target.headOnly
        )
        return ServiceProbe(target: target, ok: r.ok, ms: r.ms)
    }

    static func quickCheck(dpi: DPIService) -> Bool {
        guard dpi.isRunning else { return false }
        return ScanTargets.quickProbe(port: dpi.port)
    }
}
