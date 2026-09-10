import Foundation

enum SystemProxy {
    /// All real network services (Wi‑Fi, Ethernet, Thunderbolt, …) — not just the
    /// default route. On another Mac the active interface is often not "Wi-Fi",
    /// so enabling PAC only on the default service leaves YouTube/TG unbroken.
    static func hardwareServices() -> [String] {
        let ports = shell("networksetup -listallhardwareports")
        var names: [String] = []
        var current: String?
        for line in ports.split(separator: "\n").map(String.init) {
            if line.hasPrefix("Hardware Port: ") {
                current = String(line.dropFirst("Hardware Port: ".count))
            } else if line.hasPrefix("Device: "), let name = current {
                let device = String(line.dropFirst("Device: ".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Skip bridges / virtual junk that networksetup still lists.
                if device.hasPrefix("en") || device.hasPrefix("eth") {
                    names.append(name)
                }
                current = nil
            }
        }
        if names.isEmpty { return [defaultService()] }
        return Array(Set(names)).sorted()
    }

    static func defaultService() -> String {
        let iface = shell("route -n get default 2>/dev/null | awk '/interface:/{print $2}'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !iface.isEmpty else { return "Wi-Fi" }

        let ports = shell("networksetup -listallhardwareports")
        var current: String?
        for line in ports.split(separator: "\n").map(String.init) {
            if line.hasPrefix("Hardware Port: ") {
                current = String(line.dropFirst("Hardware Port: ".count))
            } else if line.hasPrefix("Device: "), line.hasSuffix(iface), let name = current {
                return name
            }
        }
        return "Wi-Fi"
    }

    static func autoProxyOurs() -> Bool {
        hardwareServices().contains { service in
            let out = shell("networksetup -getautoproxyurl \(q(service))")
            return out.contains("Enabled: Yes") && out.contains("127.0.0.1:9877")
        }
    }

    static func enablePAC(_ url: String) throws {
        let services = hardwareServices()
        var lines: [String] = []
        for service in services {
            lines.append("networksetup -setautoproxyurl \(q(service)) \(q(url))")
            lines.append("networksetup -setautoproxystate \(q(service)) on")
            lines.append("networksetup -setsocksfirewallproxystate \(q(service)) off")
            lines.append("networksetup -setwebproxystate \(q(service)) off")
            lines.append("networksetup -setsecurewebproxystate \(q(service)) off")
        }
        try runAdmin(lines.joined(separator: "\n"))

        // osascript can succeed while a service silently ignores PAC — verify.
        Thread.sleep(forTimeInterval: 0.25)
        guard autoProxyOurs() else {
            throw NSError(domain: "Touch", code: 125, userInfo: [
                NSLocalizedDescriptionKey:
                    "PAC не включился (\(services.joined(separator: ", "))). Проверь пароль Mac и Сеть."
            ])
        }
    }

    static func disableAll() throws {
        let services = hardwareServices()
        var lines: [String] = []
        for service in services {
            lines.append("networksetup -setautoproxystate \(q(service)) off")
            lines.append("networksetup -setsocksfirewallproxystate \(q(service)) off")
            lines.append("networksetup -setsocksfirewallproxy \(q(service)) '' 0")
            lines.append("networksetup -setwebproxystate \(q(service)) off")
            lines.append("networksetup -setsecurewebproxystate \(q(service)) off")
        }
        try runAdmin(lines.joined(separator: "\n"))
    }

    private static func q(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func shell(_ command: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    static func runAdmin(_ script: String) throws {
        let oneLine = script
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ; ")
        let wrapped = oneLine
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let apple = "do shell script \"\(wrapped)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", apple]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        try p.run()
        if !Proc.wait(p, timeout: 90) {
            Proc.forceKill(p)
            throw NSError(domain: "Touch", code: 124, userInfo: [
                NSLocalizedDescriptionKey: "Ждал пароль слишком долго. Нажми CONNECT ещё раз и введи пароль Mac."
            ])
        }
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "Touch", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: msg.isEmpty ? "Нужны права администратора" : msg
            ])
        }
    }
}
