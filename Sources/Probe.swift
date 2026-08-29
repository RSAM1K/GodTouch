import Foundation

struct ProbeResult: Sendable {
    let profile: DPIProfile
    let youtubeOK: Bool
    let googleOK: Bool
    let latencyMs: Int

    var allOK: Bool { youtubeOK && googleOK }
}

enum StrategyProbe {
    private static let youtubeURL = "https://www.youtube.com/generate_204"
    private static let googleURL = "https://www.google.com/generate_204"

    /// Try every backend × strategy; return the fastest working profile.
    static func findBest(
        dpi: DPIService,
        onProgress: @escaping @Sendable (DPIProfile, Int, Int) -> Void
    ) -> ProbeResult? {
        var working: [ProbeResult] = []
        let all = DPIProfile.allProfiles()
        for (index, profile) in all.enumerated() {
            onProgress(profile, index + 1, all.count)
            dpi.stop()
            do {
                try dpi.start(backend: profile.backend, arguments: profile.arguments)
            } catch {
                continue
            }
            Thread.sleep(forTimeInterval: 0.2)
            if let result = probeCurrent(dpi: dpi, profile: profile), result.allOK {
                working.append(result)
            }
        }
        dpi.stop()
        return working.min(by: { $0.latencyMs < $1.latencyMs })
    }

    static func probeCurrent(dpi: DPIService, profile: DPIProfile) -> ProbeResult? {
        guard dpi.isRunning else { return nil }
        let yt = curlTest(url: youtubeURL, port: dpi.port)
        let g = curlTest(url: googleURL, port: dpi.port)
        let latency = max(yt.ms, g.ms)
        return ProbeResult(
            profile: profile,
            youtubeOK: yt.ok,
            googleOK: g.ok,
            latencyMs: latency
        )
    }

    private static func curlTest(url: String, port: Int, timeout: Int = 8) -> (ok: Bool, ms: Int) {
        let out = SystemProxy.shell("""
        curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time \(timeout) \
          --socks5-hostname 127.0.0.1:\(port) '\(url)' 2>/dev/null
        """).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = out.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[0]), let sec = Double(parts[1]) else {
            return (false, Int.max)
        }
        let ok = (200...399).contains(code)
        return (ok, Int(sec * 1000))
    }
}
