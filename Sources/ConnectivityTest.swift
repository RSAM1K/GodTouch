import Foundation

struct PingRow: Identifiable {
    let id: String
    let label: String
    let ok: Bool
    let ms: Int?
    let skipped: Bool

    var latencyText: String {
        if skipped { return "—" }
        if let ms { return "\(ms)ms" }
        return "fail"
    }

    var mark: String {
        if skipped { return "—" }
        return ok ? "✓" : "✗"
    }
}

enum ConnectivityTest {
    private struct Target {
        let tag: String
        let label: String
        let url: String
        var headOnly: Bool = false
    }

    private static let dpiTargets: [Target] = [
        Target(tag: "YT", label: "YouTube", url: "https://www.youtube.com/generate_204"),
        Target(tag: "G", label: "Google", url: "https://www.google.com/generate_204"),
        Target(tag: "DC", label: "Discord", url: "https://discord.com/api/v10/gateway"),
        Target(tag: "TW", label: "Twitch", url: "https://www.twitch.tv", headOnly: true)
    ]

    private static let telegramTarget = Target(
        tag: "TG", label: "Telegram", url: "https://api.telegram.org"
    )

    static func run(dpiPort: Int, telegramPort: Int? = nil, timeout: Int = 5) -> [PingRow] {
        typealias IndexedRow = (order: Int, row: PingRow)
        var indexed: [IndexedRow] = []
        let lock = NSLock()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)

        for (order, target) in dpiTargets.enumerated() {
            group.enter()
            queue.async {
                defer { group.leave() }
                let result = curlTest(
                    url: target.url,
                    port: dpiPort,
                    timeout: timeout,
                    headOnly: target.headOnly
                )
                let row = PingRow(
                    id: target.tag,
                    label: target.label,
                    ok: result.ok,
                    ms: result.ok ? result.ms : nil,
                    skipped: false
                )
                lock.lock()
                indexed.append((order, row))
                lock.unlock()
            }
        }

        let tgOrder = dpiTargets.count
        if let tgPort = telegramPort {
            group.enter()
            queue.async {
                defer { group.leave() }
                let result = curlTest(url: telegramTarget.url, port: tgPort, timeout: timeout)
                let row = PingRow(
                    id: telegramTarget.tag,
                    label: telegramTarget.label,
                    ok: result.ok,
                    ms: result.ok ? result.ms : nil,
                    skipped: false
                )
                lock.lock()
                indexed.append((tgOrder, row))
                lock.unlock()
            }
        }

        group.wait()
        var rows = indexed.sorted { $0.order < $1.order }.map(\.row)
        if telegramPort == nil {
            rows.append(PingRow(
                id: telegramTarget.tag,
                label: telegramTarget.label,
                ok: false,
                ms: nil,
                skipped: true
            ))
        }
        return rows
    }

    private static func curlTest(
        url: String,
        port: Int,
        timeout: Int,
        headOnly: Bool = false
    ) -> (ok: Bool, ms: Int) {
        let headFlag = headOnly ? "-I " : ""
        let connectTimeout = min(timeout, 4)
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
        let ms = max(1, Int(sec * 1000))
        return (ok, ms)
    }
}
