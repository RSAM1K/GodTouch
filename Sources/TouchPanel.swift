import AppKit
import SwiftUI

// MARK: - Shared CRT palette

enum CRT {
    static let black = Color.black
    static let panel = Color(red: 0.04, green: 0.04, blue: 0.04)
    static let amber = Color(red: 1.0, green: 0.69, blue: 0.0)
    static let amberDim = Color(red: 0.72, green: 0.48, blue: 0.0)
    static let phosphor = Color(red: 0.55, green: 0.95, blue: 0.45)
    static let label = Color(red: 0.62, green: 0.64, blue: 0.58)

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Panel

enum PanelMetrics {
    static let hMargin: CGFloat = 6
    /// Same width as the hands frame + thin side margin (home and CFG match).
    static var width: CGFloat { ArtSlot.outerWidth + hMargin * 2 }
}

struct TouchPanelView: View {
    @ObservedObject var engine: Engine
    @State private var showSettings = false
    @State private var pingRows: [PingRow] = []
    @State private var pingError: String?
    @State private var pinging = false

    var body: some View {
        Group {
            if showSettings {
                TouchSettingsView(engine: engine) {
                    showSettings = false
                }
            } else {
                mainPanel
            }
        }
        .frame(width: PanelMetrics.width)
        .fixedSize(horizontal: true, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(CRT.amber.opacity(0.22), lineWidth: 1)
        }
    }

    private var mainPanel: some View {
        VStack(spacing: 0) {
            header
            screen
        }
        .background(CRT.panel)
    }

    private var header: some View {
        ZStack {
            Text("God Touch")
                .font(CRT.mono(12, weight: .heavy))
                .foregroundStyle(CRT.amber)

            HStack {
                Spacer()
                Text("v0.1")
                    .font(CRT.mono(8))
                    .foregroundStyle(CRT.amberDim)
            }
        }
        .padding(.horizontal, PanelMetrics.hMargin)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(CRT.black)
    }

    private var screen: some View {
        VStack(spacing: 6) {
            LinkTerminalArt(
                connected: engine.isOn && !engine.busy,
                busy: engine.busy,
                engineLine: engine.engineStatusText
            )
            .transaction { $0.animation = nil }

            connectButton

            HStack(spacing: 4) {
                CRTActionButton(title: "[ CFG ]", disabled: engine.busy) {
                    showSettings = true
                }
                CRTActionButton(
                    title: pinging ? "[ … ]" : "[ PING ]",
                    disabled: engine.busy || pinging
                ) {
                    runHomePing()
                }
                CRTActionButton(title: "[ QUIT ]", disabled: false) {
                    engine.turnOff()
                    NSApplication.shared.terminate(nil)
                }
            }

            if !pingRows.isEmpty || pingError != nil {
                homePingBlock
            }

            if let err = engine.lastError, !err.isEmpty {
                Text("! \(err)")
                    .font(CRT.mono(8))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .lineLimit(2)
            }
        }
        .frame(width: ArtSlot.outerWidth)
        .padding(.horizontal, PanelMetrics.hMargin)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .background(CRT.black)
        .overlay {
            Rectangle()
                .strokeBorder(CRT.amber.opacity(0.08), lineWidth: 1)
        }
        .padding(.horizontal, PanelMetrics.hMargin)
        .padding(.bottom, 6)
    }

    private var homePingBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let pingError {
                Text("! \(pingError)")
                    .font(CRT.mono(8))
                    .foregroundStyle(Color.red.opacity(0.85))
            }
            ForEach(pingRows) { row in
                HStack(spacing: 6) {
                    Text(row.label)
                        .font(CRT.mono(8))
                        .foregroundStyle(CRT.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 2)
                    Text(row.latencyText)
                        .font(CRT.mono(8, weight: .bold))
                        .foregroundStyle(homePingColor(row))
                    Text(row.mark)
                        .font(CRT.mono(8, weight: .bold))
                        .foregroundStyle(homePingColor(row))
                        .frame(width: 10, alignment: .trailing)
                }
            }
        }
        .padding(6)
        .background(CRT.amber.opacity(0.04))
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(CRT.amber.opacity(0.18), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func homePingColor(_ row: PingRow) -> Color {
        if row.skipped { return CRT.amberDim }
        return row.ok ? CRT.phosphor : Color.red.opacity(0.85)
    }

    private func runHomePing() {
        pinging = true
        pingRows = []
        pingError = nil
        Task {
            let result = await engine.pingServices()
            await MainActor.run {
                pingRows = result.rows
                pingError = result.error
                pinging = false
            }
        }
    }

    private var connectButton: some View {
        CRTActionButton(
            title: buttonLabel,
            filled: !engine.isOn || engine.busy,
            disabled: false
        ) {
            engine.toggle()
        }
    }

    private var buttonLabel: String {
        if engine.busy { return "[ ABORT ]" }
        return engine.isOn ? "[ DISCONNECT ]" : "[ CONNECT ]"
    }
}
