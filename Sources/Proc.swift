import Darwin
import Foundation

enum Proc {
    @discardableResult
    static func run(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) throws -> (status: Int32, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = arguments
        p.currentDirectoryURL = currentDirectory
        if let environment {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in environment { env[k] = v }
            p.environment = env
        }
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        try p.run()
        if !wait(p, timeout: timeout) {
            kill(p.processIdentifier, SIGKILL)
            throw NSError(domain: "Touch", code: 124, userInfo: [
                NSLocalizedDescriptionKey: "Команда зависла (\(launchPath))"
            ])
        }
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, msg)
    }

    static func wait(_ p: Process, timeout: TimeInterval) -> Bool {
        let box = TimeoutBox()
        let thread = Thread {
            p.waitUntilExit()
            box.done = true
        }
        thread.start()
        let deadline = Date().addingTimeInterval(timeout)
        while !box.done, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return box.done
    }

    static func forceKill(_ p: Process?) {
        guard let p else { return }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
        }
    }
}

private final class TimeoutBox: @unchecked Sendable {
    var done = false
}
