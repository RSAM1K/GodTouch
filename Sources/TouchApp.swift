import AppKit
import SwiftUI

@main
struct TouchApp: App {
    @StateObject private var engine = Engine()

    init() {
        AppSingleton.enforce()
    }

    var body: some Scene {
        MenuBarExtra {
            TouchPanelView(engine: engine)
                .transaction { $0.animation = nil }
        } label: {
            MenuBarLabel(connected: engine.isOn)
        }
        .menuBarExtraStyle(.window)
    }
}
