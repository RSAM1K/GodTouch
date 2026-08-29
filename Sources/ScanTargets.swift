import Foundation

struct ScanTarget: Identifiable, Sendable, Hashable {
    let id: String
    let tag: String
    let label: String
    let url: String
    var headOnly: Bool = false
}

struct ServiceProbe: Sendable, Identifiable {
    var id: String { targetId }
    let targetId: String
    let tag: String
    let label: String
    let ok: Bool
    let ms: Int

    init(target: ScanTarget, ok: Bool, ms: Int) {
        self.targetId = target.id
        self.tag = target.tag
        self.label = target.label
        self.ok = ok
        self.ms = ms
    }
}

/// Resources we optimize SCAN / PING for.
enum ScanTargets {
    /// Special id while a full multi-resource SCAN is running.
    static let allScanId = "ALL"

    static let bundle: [ScanTarget] = [
        ScanTarget(id: "DC", tag: "DS", label: "Discord", url: "https://discord.com/api/v10/gateway"),
        ScanTarget(id: "YT", tag: "YT", label: "YouTube", url: "https://www.youtube.com/generate_204"),
        ScanTarget(id: "TW", tag: "TW", label: "Twitch", url: "https://www.twitch.tv", headOnly: true),
        ScanTarget(
            id: "DBD",
            tag: "DBD",
            label: "Dead by Daylight",
            url: "https://www.deadbydaylight.com/",
            headOnly: true
        ),
    ]

    static func probe(
        port: Int,
        timeout: Int = 4,
        connectTimeout: Int = 2
    ) -> [ServiceProbe] {
        let group = DispatchGroup()
        let lock = NSLock()
        var indexed: [(Int, ServiceProbe)] = []
        let queue = DispatchQueue.global(qos: .userInitiated)

        for (order, target) in bundle.enumerated() {
            group.enter()
            queue.async {
                defer { group.leave() }
                let r = curlTest(
                    url: target.url,
                    port: port,
                    timeout: timeout,
                    connectTimeout: connectTimeout,
                    headOnly: target.headOnly
                )
                let probe = ServiceProbe(target: target, ok: r.ok, ms: r.ms)
                lock.lock()
                indexed.append((order, probe))
                lock.unlock()
            }
        }

        group.wait()
        return indexed.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func quickProbe(port: Int) -> Bool {
        guard let yt = bundle.first(where: { $0.id == "YT" }) else { return false }
        return curlTest(
            url: yt.url,
            port: port,
            timeout: 2,
            connectTimeout: 1,
            headOnly: yt.headOnly
        ).ok
    }

    static func curlTest(
        url: String,
        port: Int,
        timeout: Int,
        connectTimeout: Int,
        headOnly: Bool = false
    ) -> (ok: Bool, ms: Int) {
        let headFlag = headOnly ? "-I " : ""
        let out = SystemProxy.shell("""
        curl -sS -o /dev/null \(headFlag)-w '%{http_code} %{time_starttransfer}' \
          --max-time \(timeout) --connect-timeout \(connectTimeout) \
          --socks5-hostname 127.0.0.1:\(port) '\(url)' 2>/dev/null
        """).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = out.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[0]), let sec = Double(parts[1]) else {
            return (false, Int.max)
        }
        let ok = (200...399).contains(code)
        return (ok, max(1, Int(sec * 1000)))
    }
}
