import AppKit
import SwiftUI

@main
struct TouchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AppSingleton.enforce()
    }

    var body: some Scene {
        // Agent (LSUIElement): no Dock window. Panel lives on NSStatusItem.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = Engine()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let controller = StatusItemController(engine: engine)
        controller.install()
        statusItem = controller
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        statusItem?.togglePanel()
        return false
    }
}
