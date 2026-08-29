import AppKit
import SwiftUI

/// Menubar glyph: CRT frame + touch spark (God Touch / LINK motif).
enum MenuBarIcon {
  private static let size = NSSize(width: 18, height: 18)

  /// Matches `CRT.amber` in TouchPanel.
  private static let amber = NSColor(red: 1.0, green: 0.69, blue: 0.0, alpha: 1)
  private static let amberDim = NSColor(red: 0.72, green: 0.48, blue: 0.0, alpha: 1)

  static func image(connected: Bool) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()

    let main = connected ? amber : amberDim
    let glow = main.withAlphaComponent(connected ? 0.35 : 0.2)

    // CRT terminal frame (like panel chrome)
    glow.setStroke()
    let frame = NSBezierPath(
      roundedRect: NSRect(x: 2.2, y: 2.2, width: 13.6, height: 13.6),
      xRadius: 2,
      yRadius: 2
    )
    frame.lineWidth = 1.1
    frame.stroke()

    // Corner pixels — retro dither hint
    main.setFill()
    for point in [
      NSPoint(x: 3.5, y: 14.2),
      NSPoint(x: 14.2, y: 3.5),
      NSPoint(x: 14.2, y: 14.2)
    ] {
      NSBezierPath(rect: NSRect(x: point.x, y: point.y, width: 1, height: 1)).fill()
    }

    let center = NSPoint(x: 9, y: 9)

    // Two touch points (finger ↔ spark)
    for dx in [-4.2, 4.2] {
      NSBezierPath(ovalIn: NSRect(x: center.x + dx - 1.1, y: center.y - 1.1, width: 2.2, height: 2.2)).fill()
    }

    // Spark cross — same idea as LinkTerminalArt "+"
    NSBezierPath(
      roundedRect: NSRect(x: center.x - 3.2, y: center.y - 0.75, width: 6.4, height: 1.5),
      xRadius: 0.35,
      yRadius: 0.35
    ).fill()
    NSBezierPath(
      roundedRect: NSRect(x: center.x - 0.75, y: center.y - 3.2, width: 1.5, height: 6.4),
      xRadius: 0.35,
      yRadius: 0.35
    ).fill()

    if connected {
      glow.setFill()
      NSBezierPath(ovalIn: NSRect(x: center.x - 2.8, y: center.y - 2.8, width: 5.6, height: 5.6)).fill()
      main.setFill()
      NSBezierPath(
        roundedRect: NSRect(x: center.x - 3.2, y: center.y - 0.75, width: 6.4, height: 1.5),
        xRadius: 0.35,
        yRadius: 0.35
      ).fill()
      NSBezierPath(
        roundedRect: NSRect(x: center.x - 0.75, y: center.y - 3.2, width: 1.5, height: 6.4),
        xRadius: 0.35,
        yRadius: 0.35
      ).fill()
    }

    image.unlockFocus()
    image.isTemplate = false
    return image
  }
}

struct MenuBarLabel: View {
  let connected: Bool

  var body: some View {
    Image(nsImage: MenuBarIcon.image(connected: connected))
  }
}
