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

    init(probe: ServiceProbe, skipped: Bool = false) {
        self.id = probe.tag
        self.label = probe.label
        self.ok = probe.ok
        self.ms = probe.ok ? probe.ms : nil
        self.skipped = skipped
    }

    init(id: String, label: String, ok: Bool, ms: Int?, skipped: Bool) {
        self.id = id
        self.label = label
        self.ok = ok
        self.ms = ms
        self.skipped = skipped
    }
}

enum ConnectivityTest {
    private static let telegramTarget = (
        tag: "TG",
        label: "Telegram",
        url: "https://api.telegram.org"
    )

    static func run(
        dpiPort: Int,
        telegramPort: Int? = nil,
        timeout: Int = 5,
        connectTimeout: Int = 4
    ) -> [PingRow] {
        var rows = ScanTargets.probe(
            port: dpiPort,
            timeout: timeout,
            connectTimeout: connectTimeout
        ).map { PingRow(probe: $0) }

        if let tgPort = telegramPort {
            let result = tgProxyHealthCheck(port: tgPort)
            rows.append(PingRow(
                id: telegramTarget.tag,
                label: telegramTarget.label,
                ok: result.ok,
                ms: result.ok ? result.ms : nil,
                skipped: false
            ))
        } else {
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

    private static func tgProxyHealthCheck(port: Int) -> (ok: Bool, ms: Int) {
        let start = Date()
        let out = SystemProxy.shell("""
        lsof -nP -iTCP:\(port) -sTCP:LISTEN 2>/dev/null | wc -l | tr -d ' '
        """).trimmingCharacters(in: .whitespacesAndNewlines)
        let listening = (Int(out) ?? 0) > 0
        let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
        return (listening, listening ? ms : Int.max)
    }
}
