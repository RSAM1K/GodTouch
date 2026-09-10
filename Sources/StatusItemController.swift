import AppKit
import Combine
import SwiftUI

/// Menubar icon + popover panel.
/// Replaces SwiftUI `MenuBarExtra(.window)`, which first materializes the window
/// at the top-left of the screen and then slides it under the status item.
@MainActor
final class StatusItemController: NSObject {
    private let engine: Engine
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var hosting: SizeReportingHostingView<TouchPanelView>?
    private var iconBag: AnyCancellable?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(engine: Engine) {
        self.engine = engine
        super.init()
    }

    func install() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = MenuBarIcon.image(connected: engine.isOn)
            button.imageScaling = .scaleProportionallyDown
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 260),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true

        let root = TouchPanelView(engine: engine)
        let host = SizeReportingHostingView(rootView: root)
        host.onSizeChange = { [weak self] size in
            self?.applyContentSize(size, animate: false)
        }
        panel.contentView = host

        self.panel = panel
        self.hosting = host

        iconBag = engine.$isOn
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                self?.statusItem?.button?.image = MenuBarIcon.image(connected: on)
            }
    }

    @objc func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        guard let panel, let button = statusItem?.button else { return }

        let size = hosting?.fittingSize ?? panel.frame.size
        applyContentSize(size, animate: false)
        positionUnderStatusItem(size: panel.frame.size)

        // Appear already in place — no slide from screen origin.
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        button.isHighlighted = true
        startDismissMonitors()
    }

    func hidePanel() {
        panel?.orderOut(nil)
        statusItem?.button?.isHighlighted = false
        stopDismissMonitors()
    }

    private func applyContentSize(_ size: NSSize, animate: Bool) {
        guard let panel, size.width > 1, size.height > 1 else { return }
        var frame = panel.frame
        let top = frame.maxY
        let newSize = NSSize(
            width: ceil(size.width),
            height: ceil(size.height)
        )
        if abs(frame.width - newSize.width) < 0.5, abs(frame.height - newSize.height) < 0.5 {
            return
        }
        frame.size = newSize
        if panel.isVisible {
            frame.origin.y = top - newSize.height
            // Keep centered on the status button when height changes.
            if let button = statusItem?.button, let win = button.window {
                let buttonRect = button.convert(button.bounds, to: nil)
                let screenRect = win.convertToScreen(buttonRect)
                frame.origin.x = round(screenRect.midX - newSize.width / 2)
                clamp(&frame, to: screenRect)
            }
        }
        panel.setFrame(frame, display: true, animate: animate)
    }

    private func positionUnderStatusItem(size: NSSize) {
        guard let panel, let button = statusItem?.button, let win = button.window else { return }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = win.convertToScreen(buttonRect)
        var frame = NSRect(
            x: round(screenRect.midX - size.width / 2),
            y: round(screenRect.minY - size.height - 5),
            width: size.width,
            height: size.height
        )
        clamp(&frame, to: screenRect)
        panel.setFrame(frame, display: false, animate: false)
    }

    private func clamp(_ frame: inout NSRect, to buttonScreenRect: NSRect) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(buttonScreenRect.origin) })
            ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        if frame.maxX > visible.maxX {
            frame.origin.x = visible.maxX - frame.width - 4
        }
        if frame.minX < visible.minX {
            frame.origin.x = visible.minX + 4
        }
        if frame.minY < visible.minY {
            frame.origin.y = visible.minY + 4
        }
    }

    private func startDismissMonitors() {
        stopDismissMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleMouseDown(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleMouseDown(event)
        }
    }

    private func stopDismissMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard let panel, panel.isVisible else { return }
        let screenPoint = NSEvent.mouseLocation
        if panel.frame.contains(screenPoint) { return }
        if let button = statusItem?.button, let win = button.window {
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = win.convertToScreen(buttonRect)
            if screenRect.contains(screenPoint) { return }
        }
        hidePanel()
    }
}

/// Reports intrinsic SwiftUI size so the panel can resize without AppKit animation.
final class SizeReportingHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: ((NSSize) -> Void)?
    private var lastReported: NSSize = .zero

    override func layout() {
        super.layout()
        let size = fittingSize
        guard size.width > 1, size.height > 1 else { return }
        if abs(size.width - lastReported.width) > 0.5
            || abs(size.height - lastReported.height) > 0.5
        {
            lastReported = size
            onSizeChange?(size)
        }
    }
}
