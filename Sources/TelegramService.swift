import AppKit
import Darwin
import Foundation

/// Telegram via local SOCKS → WebSocket (kws*.web.telegram.org:443).
/// Same idea as Flowseal tg-ws-proxy — no WARP/WireGuard needed.
final class TelegramService {
    private var process: Process?
    private let binary: URL
    let port = 1081

    init(binary: URL) {
        self.binary = binary
    }

    var isRunning: Bool { process?.isRunning == true }

    func start() throws {
        stop()
        try waitUntilPortFree(timeout: 2)

        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw NSError(domain: "Touch", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Не найден tg-proxy: \(binary.path)"
            ])
        }

        let errURL = URL(fileURLWithPath: "/tmp/touch-tg-proxy.err")
        try? FileManager.default.removeItem(at: errURL)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)

        let p = Process()
        p.executableURL = binary
        p.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "RUST_LOG": "info",
        ]
        // Telegram DC IPs are blackholed here; WS goes through Cloudflare fronts
        // (kwsN.cakeisalie.co.uk / fixtelega / pclead / lovetrue). --dc-ip only
        // picks the hub used if a path still opens raw TCP.
        p.arguments = [
            "--host", "127.0.0.1",
            "--port", String(port),
            "--dc-ip", "1:149.154.167.220",
            "--dc-ip", "2:149.154.167.220",
            "--dc-ip", "3:149.154.167.220",
            "--dc-ip", "4:149.154.167.220",
            "--dc-ip", "5:149.154.167.220",
            "--pool-size", "0",
            "--connect-timeout", "8",
            "--pool-max-age", "90",
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle(forWritingAtPath: errURL.path)
        try p.run()
        process = p
        Thread.sleep(forTimeInterval: 0.3)
        if !p.isRunning {
            let err = (try? String(contentsOf: errURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(domain: "Touch", code: 2, userInfo: [
                NSLocalizedDescriptionKey: err.isEmpty ? "tg-proxy сразу завершился" : err
            ])
        }
    }

    func stop() {
        Proc.forceKill(process)
        process = nil
        for pid in listeningPIDs() {
            kill(pid, SIGKILL)
        }
        _ = waitUntilPortFreeQuiet(timeout: 1.0)
    }

    /// Opens Telegram to apply SOCKS proxy via deep link.
    func offerProxyToTelegram(force: Bool = false) {
        if !force, TouchSettings.telegramProxyOffered { return }
        let url = URL(string: "tg://socks?server=127.0.0.1&port=\(port)")!
        NSWorkspace.shared.open(url)
        TouchSettings.markTelegramProxyOffered()
    }

    private func listeningPIDs() -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        if !Proc.wait(p, timeout: 1.5) {
            Proc.forceKill(p)
            return []
        }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func waitUntilPortFree(timeout: TimeInterval) throws {
        if waitUntilPortFreeQuiet(timeout: timeout) { return }
        throw NSError(domain: "Touch", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Порт \(port) занят"
        ])
    }

    private func waitUntilPortFreeQuiet(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if listeningPIDs().isEmpty { return true }
            Thread.sleep(forTimeInterval: 0.08)
        }
        return listeningPIDs().isEmpty
    }
}
