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
        } label: {
            MenuBarLabel(connected: engine.isOn)
        }
        .menuBarExtraStyle(.window)
    }
}
