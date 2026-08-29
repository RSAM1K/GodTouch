import Darwin
import Foundation

/// Local DPI bypass: tpws or ciadpi (ByeDPI) in SOCKS mode on :1080.
final class DPIService {
    private var process: Process?
    private let tpwsBinary: URL
    private let ciadpiBinary: URL
    private let spoofdpiBinary: URL
    private let touchcoreBinary: URL
    private(set) var activeBackend: DPIBackend?
    let port = 1080

    init(resourceDir: URL) {
        self.tpwsBinary = resourceDir.appendingPathComponent("tpws")
        self.ciadpiBinary = resourceDir.appendingPathComponent("ciadpi")
        self.spoofdpiBinary = resourceDir.appendingPathComponent("spoofdpi")
        self.touchcoreBinary = resourceDir.appendingPathComponent("touchcore")
    }

    var isRunning: Bool { process?.isRunning == true }

    private func backendWarmup(probeMode: Bool, backend: DPIBackend) -> TimeInterval {
        switch backend {
        case .touchcore:
            return probeMode ? 0.28 : 0.45
        case .spoofdpi:
            return probeMode ? 0.2 : 0.4
        default:
            return probeMode ? 0.15 : 0.35
        }
    }

    func start(profile: DPIProfile, probeMode: Bool = false, argumentsOverride: [String]? = nil) throws {
        let args = argumentsOverride ?? TouchSettings.effectiveArguments(for: profile)
        try start(backend: profile.backend, arguments: args, probeMode: probeMode)
    }

    func start(backend: DPIBackend, arguments: [String], probeMode: Bool = false) throws {
        stop(portWait: probeMode ? 0.35 : 1.2)
        try waitUntilPortFree(timeout: probeMode ? 0.5 : 2)

        let binary: URL
        let baseArgs: [String]
        let errName: String

        switch backend {
        case .tpws:
            binary = tpwsBinary
            baseArgs = ["--bind-addr=127.0.0.1", "--port=\(port)", "--socks"]
            errName = "touch-tpws.err"
        case .ciadpi:
            binary = ciadpiBinary
            baseArgs = ["-i", "127.0.0.1", "-p", "\(port)", "-x", "0"]
            errName = "touch-ciadpi.err"
        case .spoofdpi:
            binary = spoofdpiBinary
            baseArgs = [
                "--app-mode", "socks5",
                "--listen-addr", "127.0.0.1:\(port)",
                "--no-tui",
                "--log-level", "error",
                "--auto-configure-network=false"
            ]
            errName = "touch-spoofdpi.err"
        case .touchcore:
            binary = touchcoreBinary
            baseArgs = ["--listen", "127.0.0.1:\(port)"]
            errName = "touch-touchcore.err"
        }

        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw NSError(domain: "Touch", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Не найден \(backend.title): \(binary.path)"
            ])
        }
        guard !arguments.isEmpty else {
            throw NSError(domain: "Touch", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Пустой конфиг стратегии"
            ])
        }

        let errURL = FileManager.default.temporaryDirectory.appendingPathComponent(errName)
        try? FileManager.default.removeItem(at: errURL)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)

        let p = Process()
        p.executableURL = binary
        p.arguments = baseArgs + arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle(forWritingAtPath: errURL.path)
        try p.run()
        process = p
        activeBackend = backend
        Thread.sleep(forTimeInterval: probeMode ? backendWarmup(probeMode: true, backend: backend) : backendWarmup(probeMode: false, backend: backend))
        if !p.isRunning {
            let err = (try? String(contentsOf: errURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            activeBackend = nil
            throw NSError(domain: "Touch", code: 2, userInfo: [
                NSLocalizedDescriptionKey: err.isEmpty ? "\(backend.title) сразу завершился" : err
            ])
        }
    }

    func stop(portWait: TimeInterval = 1.2) {
        Proc.forceKill(process)
        process = nil
        activeBackend = nil
        for pid in listeningPIDs() {
            kill(pid, SIGKILL)
        }
        _ = waitUntilPortFreeQuiet(timeout: portWait)
    }

    private func listeningPIDs() -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return []
        }
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
