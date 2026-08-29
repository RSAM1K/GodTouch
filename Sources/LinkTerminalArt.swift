import AppKit
import SwiftUI

// MARK: - CRT terminal (reference: dither hands fill the art frame)

enum ArtSlot {
    /// Visible art area inside LinkTerminalArt (points @1x).
    static let width: CGFloat = 212
    static let height: CGFloat = 96
    /// Recommended PNG size @2x for Retina.
    static let pngWidth = 424
    static let pngHeight = 192
}

private typealias Terminal = CRT

struct LinkTerminalArt: View {
    let connected: Bool
    let busy: Bool
    var engineLine: String = ""
    var servicesLine: String = ""

    @State private var flicker = false
    @State private var spark = false
    @State private var cursorPhase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            artFrame
            footerRow
        }
        .padding(8)
        .background(Terminal.black)
        .overlay(border)
        .overlay(scanlines.allowsHitTesting(false))
        .animation(.easeInOut(duration: 0.4), value: connected)
        .onChange(of: connected) { _, on in
            if on { burstSpark() }
        }
        .onAppear { startEffects() }
        .onChange(of: busy) { _, _ in startEffects() }
        .opacity(busy && flicker ? 0.85 : 1)
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
        .padding(.bottom, 5)
    }

    private var statusDot: some View {
        Circle()
            .strokeBorder(Terminal.amber, lineWidth: 1)
            .background(Circle().fill(connected ? Terminal.amber : Color.clear))
            .frame(width: 5, height: 5)
            .shadow(color: connected ? Terminal.amber.opacity(0.9) : .clear, radius: 3)
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
        Group {
            if let img = BundleImage.load(name) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFill()
                    .frame(width: ArtSlot.width, height: ArtSlot.height)
                    .clipped()
            }
        }
    }

    private var sparkGlyph: some View {
        Text("+")
            .font(Terminal.mono(16, weight: .bold))
            .foregroundStyle(Terminal.amber)
            .shadow(color: Terminal.amber, radius: 6)
            .shadow(color: Terminal.amber.opacity(0.6), radius: 14)
            .transition(.scale.combined(with: .opacity))
    }

    private var footerRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Text("LINK: [")
                Text(connected ? "ON" : "OFF")
                    .foregroundStyle(connected ? Terminal.amber : Terminal.amberDim)
                Text("]")
                blockCursor
            }
            if !engineLine.isEmpty {
                Text(engineLine)
                    .foregroundStyle(Terminal.amberDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            if !servicesLine.isEmpty {
                Text(servicesLine)
                    .foregroundStyle(Terminal.amberDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
        }
        .font(Terminal.mono(7.5, weight: .bold))
        .foregroundStyle(Terminal.amber)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private var blockCursor: some View {
        Rectangle()
            .fill(Terminal.amber.opacity(cursorPhase ? 1 : 0.15))
            .frame(width: 6, height: 9)
            .padding(.leading, 2)
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Terminal.amber.opacity(0.3), lineWidth: 1)
    }

    private var scanlines: some View {
        GeometryReader { geo in
            Path { path in
                var y: CGFloat = 0
                while y < geo.size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    y += 2
                }
            }
            .stroke(Terminal.amber.opacity(0.04), lineWidth: 1)
        }
    }

    private var artScanlines: some View {
        GeometryReader { geo in
            Path { path in
                var y: CGFloat = 0
                while y < geo.size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    y += 3
                }
            }
            .stroke(Color.black.opacity(0.2), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    // MARK: effects

    private func burstSpark() {
        withAnimation(.easeOut(duration: 0.55)) { spark = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation { spark = false }
        }
    }

    private func startEffects() {
        if busy {
            withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                flicker = true
            }
        } else {
            flicker = false
        }
        withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
            cursorPhase = true
        }
    }
}

private enum BundleImage {
    static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
