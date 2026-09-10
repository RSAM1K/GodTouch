import AppKit
import SwiftUI

// MARK: - CRT terminal (reference: dither hands fill the art frame)

enum ArtSlot {
    /// Visible art area inside the main panel.
    static let width: CGFloat = 204
    static let height: CGFloat = 88
    static let pngWidth = 392
    static let pngHeight = 176
    /// Black terminal frame around the art (padding 8pt each side).
    static var outerWidth: CGFloat { width + 16 }
}

private typealias Terminal = CRT

struct LinkTerminalArt: View {
    let connected: Bool
    let busy: Bool
    var engineLine: String = ""

    @State private var spark = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            artFrame
            footerRow
        }
        .padding(8)
        .frame(width: ArtSlot.outerWidth, alignment: .leading)
        .background(Terminal.black)
        .overlay(border)
        .overlay(scanlines.allowsHitTesting(false))
        .opacity(busy ? 0.9 : 1)
        .onChange(of: connected) { _, on in
            if on { burstSpark() }
        }
        // Never withAnimation.repeatForever here — it leaks into MenuBarExtra
        // and the popup window rides up/down while it remeasures.
        .transaction { $0.animation = nil }
    }

    // MARK: chrome

    private var headerRow: some View {
        HStack(spacing: 4) {
            Text("> LINK_INTERFACE")
                .font(Terminal.mono(7.5, weight: .bold))
                .foregroundStyle(Terminal.amber)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 2)
            Text(connected ? "STATUS: CONNECTED" : "STATUS: DISCONNECTED")
                .font(Terminal.mono(6.5))
                .foregroundStyle(connected ? Terminal.amber : Terminal.amberDim)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            statusDot
        }
        .frame(height: 14)
        .padding(.bottom, 5)
    }

    private var statusDot: some View {
        // Fixed box — no .shadow (SwiftUI shadows inflate layout → window jump).
        ZStack {
            if connected {
                Circle()
                    .fill(Terminal.amber.opacity(0.35))
                    .frame(width: 9, height: 9)
            }
            Circle()
                .strokeBorder(Terminal.amber, lineWidth: 1)
                .background(Circle().fill(connected ? Terminal.amber : Color.clear))
                .frame(width: 5, height: 5)
        }
        .frame(width: 9, height: 9)
    }

    private var artFrame: some View {
        ZStack {
            Terminal.black

            handsLayer("hands-off")
                .opacity(connected ? 0 : 1)

            handsLayer("hands-on")
                .opacity(connected ? 1 : 0)

            artScanlines

            if spark && connected {
                sparkGlyph
            }
        }
        .frame(width: ArtSlot.width, height: ArtSlot.height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Terminal.amber.opacity(0.9), lineWidth: 1)
        )
    }

    private func handsLayer(_ name: String) -> some View {
        ZStack {
            if let img = BundleImage.load(name) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFill()
            }
        }
        .frame(width: ArtSlot.width, height: ArtSlot.height)
        .clipped()
    }

    private var sparkGlyph: some View {
        Text("+")
            .font(Terminal.mono(16, weight: .bold))
            .foregroundStyle(Terminal.amber)
            .background(
                Text("+")
                    .font(Terminal.mono(16, weight: .bold))
                    .foregroundStyle(Terminal.amber.opacity(0.35))
                    .blur(radius: 4)
            )
    }

    private var footerRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Text("LINK: [")
                Text(connected ? "ON" : "OFF")
                    .foregroundStyle(connected ? Terminal.amber : Terminal.amberDim)
                Text("]")
                BlinkBlock(interval: 0.55)
                    .padding(.leading, 2)
            }
            Text(engineLine.isEmpty ? " " : engineLine)
                .foregroundStyle(Terminal.amberDim)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .font(Terminal.mono(7.5, weight: .bold))
        .foregroundStyle(Terminal.amber)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 28)
        .padding(.top, 4)
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Terminal.amber.opacity(0.3), lineWidth: 1)
    }

    private var scanlines: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(path, with: .color(Terminal.amber.opacity(0.04)), lineWidth: 1)
                y += 2
            }
        }
    }

    private var artScanlines: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(path, with: .color(Color.black.opacity(0.2)), lineWidth: 1)
                y += 3
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: effects

    private func burstSpark() {
        spark = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            spark = false
        }
    }
}

/// Tiny blinker — TimelineView only around the 6×9 cursor so the MenuBarExtra
/// window is not remeasured on every tick.
private struct BlinkBlock: View {
    let interval: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: interval, paused: false)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate / interval) % 2 == 0
            Rectangle()
                .fill(CRT.amber.opacity(on ? 1 : 0.15))
        }
        .frame(width: 6, height: 9)
        .transaction { $0.animation = nil }
    }
}

private enum BundleImage {
    private static var cache: [String: NSImage] = [:]

    static func load(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        cache[name] = img
        return img
    }
}
