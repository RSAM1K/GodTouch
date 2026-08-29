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

struct TouchPanelView: View {
    @ObservedObject var engine: Engine
    @State private var showSettings = false

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
        .frame(width: 268)
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
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(CRT.black)
    }

    private var screen: some View {
        VStack(spacing: 6) {
            LinkTerminalArt(
                connected: engine.isOn && !engine.busy,
                busy: engine.busy,
                engineLine: engine.engineStatusText,
                servicesLine: engine.servicesStatusText
            )

            connectButton

            HStack(spacing: 6) {
                CRTActionButton(title: "[ CFG ]", disabled: engine.busy) {
                    showSettings = true
                }
                CRTActionButton(title: "[ EXIT ]", disabled: false) {
                    engine.turnOff()
                    NSApplication.shared.terminate(nil)
                }
            }

            if engine.needsTelegramSetup {
                telegramRow
            }

            if let err = engine.lastError, !err.isEmpty, !engine.needsTelegramSetup {
                Text("! \(err)")
                    .font(CRT.mono(8))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(CRT.black)
        .overlay {
            Rectangle()
                .strokeBorder(CRT.amber.opacity(0.08), lineWidth: 1)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
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

    private var telegramRow: some View {
        HStack {
            Text("TG proxy pending")
                .font(CRT.mono(8))
                .foregroundStyle(CRT.label)
            Spacer()
            Button("OPEN") { engine.setupTelegramAgain() }
                .buttonStyle(.plain)
                .font(CRT.mono(8, weight: .bold))
                .foregroundStyle(CRT.amber)
        }
        .padding(6)
        .background(CRT.amber.opacity(0.06))
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(CRT.amber.opacity(0.2), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
