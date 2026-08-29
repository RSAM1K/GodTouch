import AppKit
import Foundation

enum AppSingleton {
    /// Quit if another Touch instance is already running (same bundle id).
    static func enforce() {
        let id = Bundle.main.bundleIdentifier ?? "local.touch.app"
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
            guard app.processIdentifier != me else { continue }
            app.activate()
            exit(0)
        }
    }
}
