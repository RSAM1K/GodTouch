import SwiftUI

struct TouchSettingsView: View {
    @ObservedObject var engine: Engine
    let onBack: () -> Void

    @State private var mode: StrategyMode = TouchSettings.strategyMode
    @State private var manualProfile: DPIProfile = TouchSettings.savedProfile() ?? .default
    @State private var argsText = ""
    @State private var launchAtLogin = TouchSettings.launchAtLogin
    @State private var autoConnect = TouchSettings.autoConnect
    @State private var pingRows: [PingRow] = []
    @State private var pingError: String?
    @State private var pinging = false
    @State private var savedFlash = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    systemSection
                    strategySection
                    if mode == .manual {
                        configSection
                    }
                    if let errorText {
                        Text("! \(errorText)")
                            .font(CRT.mono(10))
                            .foregroundStyle(Color.red.opacity(0.85))
                    }
                    if savedFlash {
                        Text("> сохранено")
                            .font(CRT.mono(10))
                            .foregroundStyle(CRT.phosphor)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 300)
            footer
        }
        .frame(width: PanelMetrics.width)
        .fixedSize(horizontal: true, vertical: true)
        .background(CRT.panel)
        .onAppear { reloadFromSettings() }
        .onChange(of: engine.profile) { _, p in
            manualProfile = p
        }
        .onChange(of: engine.probing) { _, probing in
            if !probing, let saved = TouchSettings.savedProfile() {
                manualProfile = saved
                mode = TouchSettings.strategyMode
            }
        }
    }

    private var settingsHeader: some View {
        HStack {
            Text("> CONFIG")
                .font(CRT.mono(13, weight: .heavy))
                .foregroundStyle(CRT.amber)
            Spacer()
            Text("CFG")
                .font(CRT.mono(10))
                .foregroundStyle(CRT.amberDim)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CRT.black)
    }

    private var strategySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("СТРАТЕГИЯ DPI")

            HStack(spacing: 6) {
                modeButton(.auto)
                modeButton(.manual)
            }

            if mode == .auto {
                autoModeBlock
            } else {
                manualModeBlock
            }

            CRTActionButton(title: "[ СБРОС ]", disabled: engine.busy) {
                TouchSettings.resetStrategy()
                mode = .auto
                manualProfile = .default
                argsText = DPIProfile.default.argumentsLine
                engine.profile = .default
                errorText = nil
                flashSaved()
            }
        }
        .padding(8)
        .background(CRT.black)
        .overlay { boxStroke }
    }

    private var autoModeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let saved = TouchSettings.savedProfile(), TouchSettings.hasProbed {
                Text(saved.title)
                    .font(CRT.mono(10, weight: .bold))
                    .foregroundStyle(CRT.amber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text("Ещё не сканировали")
                    .font(CRT.mono(10))
                    .foregroundStyle(CRT.amberDim)
            }

            scanTargetsPanel

            scanPingRow

            if !pingRows.isEmpty {
                pingList
            }
            if let pingError {
                Text("! \(pingError)")
                    .font(CRT.mono(9))
                    .foregroundStyle(Color.red.opacity(0.85))
            }

            if engine.probing {
                Text("тест: \(engine.status)")
                    .font(CRT.mono(9))
                    .foregroundStyle(CRT.amber)
            }
        }
    }

    private var scanTargetsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            CRTActionButton(
                title: engine.scanningAll
                    ? "[ ALL \(engine.probeProgress) ]"
                    : "[ ALL ]",
                filled: engine.scanningAll,
                disabled: engine.busy && !engine.scanningAll
            ) {
                errorText = nil
                engine.scanAll()
            }

            HStack(spacing: 4) {
                ForEach(ScanTargets.bundle) { target in
                    scanTargetButton(target)
                }
            }
        }
        .padding(8)
        .background(CRT.black)
        .overlay { boxStroke }
    }

    private func scanTargetButton(_ target: ScanTarget) -> some View {
        let active = engine.probing && engine.activeScanTargetId == target.id
        let mark = engine.scanMark(for: target)
        return Button {
            errorText = nil
            engine.scanForTarget(target)
        } label: {
            VStack(spacing: 2) {
                Text("[\(target.tag)]")
                    .font(CRT.mono(7.5, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(scanChipLabel(target: target, mark: mark, active: active))
                    .font(CRT.mono(8, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .foregroundStyle(scanChipColor(mark, active: active))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(CRT.amber.opacity(active ? 0.14 : 0.03))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(scanChipBorder(mark, active: active), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .disabled(engine.busy && !active)
    }

    private func scanChipLabel(target: ScanTarget, mark: ScanMark, active: Bool) -> String {
        if active { return "…" }
        if let ms = engine.scanLatencies[target.id] { return "\(ms)ms" }
        switch mark {
        case .idle: return "SCAN"
        case .testing: return "…"
        case .ok: return "✓"
        case .fail: return "✗"
        }
    }

    private func scanChipColor(_ mark: ScanMark, active: Bool) -> Color {
        if active { return CRT.amber }
        switch mark {
        case .idle: return CRT.amberDim
        case .testing: return CRT.amber
        case .ok: return CRT.phosphor
        case .fail: return Color.red.opacity(0.85)
        }
    }

    private func scanChipBorder(_ mark: ScanMark, active: Bool) -> Color {
        if active { return CRT.amber.opacity(0.85) }
        switch mark {
        case .idle: return CRT.amber.opacity(0.25)
        case .testing: return CRT.amber.opacity(0.55)
        case .ok: return CRT.phosphor.opacity(0.55)
        case .fail: return Color.red.opacity(0.45)
        }
    }

    private var pingList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(pingRows) { row in
                HStack(spacing: 8) {
                    Text(row.label)
                        .font(CRT.mono(9))
                        .foregroundStyle(CRT.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 4)
                    Text(row.latencyText)
                        .font(CRT.mono(9, weight: .bold))
                        .foregroundStyle(rowColor(row))
                    Text(row.mark)
                        .font(CRT.mono(9, weight: .bold))
                        .foregroundStyle(rowColor(row))
                        .frame(width: 12, alignment: .trailing)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(CRT.black)
        .overlay { boxStroke }
    }

    private func rowColor(_ row: PingRow) -> Color {
        if row.skipped { return CRT.amberDim }
        return row.ok ? CRT.phosphor : Color.red.opacity(0.85)
    }

    private var probeProfile: DPIProfile {
        if mode == .manual { return manualProfile }
        return TouchSettings.savedProfile() ?? engine.profile
    }

    private var probeArguments: [String]? {
        guard mode == .manual else { return nil }
        let line = argsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        return DPIProfile.parseArgumentsLine(line, backend: manualProfile.backend)
    }

    private var scanPingRow: some View {
        CRTActionButton(
            title: pinging ? "[ PING … ]" : "[ PING ]",
            disabled: engine.busy || pinging
        ) {
            pinging = true
            pingRows = []
            pingError = nil
            Task {
                let result = await engine.pingServices(
                    profile: probeProfile,
                    arguments: probeArguments
                )
                await MainActor.run {
                    pingRows = result.rows
                    pingError = result.error
                    pinging = false
                }
            }
        }
    }

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("СИСТЕМА")

            CRTToggle(label: "Запуск при входе", isOn: $launchAtLogin)
            CRTToggle(label: "CONNECT при старте", isOn: $autoConnect)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(CRT.black)
        .overlay { boxStroke }
    }

    private var manualModeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Выбери пресет или правь флаги")
                .font(CRT.mono(10))
                .foregroundStyle(CRT.label)

            Text("TPWS")
                .font(CRT.mono(10, weight: .bold))
                .foregroundStyle(CRT.amberDim)
            ForEach(ZapretStrategy.allCases) { s in
                profileRow(DPIProfile(backend: .tpws, strategyId: s.rawValue))
            }

            Text("CIADPI")
                .font(CRT.mono(10, weight: .bold))
                .foregroundStyle(CRT.amberDim)
                .padding(.top, 4)
            ForEach(CiadpiStrategy.allCases) { s in
                profileRow(DPIProfile(backend: .ciadpi, strategyId: s.rawValue))
            }

            Text("SPOOFDPI")
                .font(CRT.mono(10, weight: .bold))
                .foregroundStyle(CRT.amberDim)
                .padding(.top, 4)
            ForEach(SpoofDPIStrategy.allCases) { s in
                profileRow(DPIProfile(backend: .spoofdpi, strategyId: s.rawValue))
            }

            Text("TOUCHCORE")
                .font(CRT.mono(10, weight: .bold))
                .foregroundStyle(CRT.amberDim)
                .padding(.top, 4)
            ForEach(TouchCoreStrategy.allCases) { s in
                profileRow(DPIProfile(backend: .touchcore, strategyId: s.rawValue))
            }
        }
    }

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(flagsSectionTitle)

            TextEditor(text: $argsText)
                .font(CRT.mono(10))
                .foregroundStyle(CRT.amber.opacity(0.95))
                .scrollContentBackground(.hidden)
                .frame(height: 72)
                .padding(6)
                .background(CRT.black)
                .overlay { boxStroke }

            Text(flagsHint)
                .font(CRT.mono(9))
                .foregroundStyle(CRT.amberDim)
        }
        .padding(8)
        .background(CRT.black)
        .overlay { boxStroke }
    }

    private var flagsSectionTitle: String {
        switch manualProfile.backend {
        case .tpws: return "TPWS ФЛАГИ"
        case .ciadpi: return "CIADPI ФЛАГИ"
        case .spoofdpi: return "SPOOFDPI ФЛАГИ"
        case .touchcore: return "TOUCHCORE ФЛАГИ"
        }
    }

    private var flagsHint: String {
        switch manualProfile.backend {
        case .tpws: return "--split-pos=1 --tlsrec=midsld"
        case .ciadpi: return "-d 1+s  или  -r 1+s"
        case .spoofdpi: return "--https-chunk-size 1"
        case .touchcore: return "--split-pos sni,midsld --disorder --tlsrec midsld"
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            CRTActionButton(title: "[ SAVE ]", filled: true, disabled: engine.busy) {
                saveAll()
            }
            CRTActionButton(title: "[ BACK ]", disabled: false, action: onBack)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CRT.black)
    }

    private func modeButton(_ m: StrategyMode) -> some View {
        CRTActionButton(
            title: "[ \(m.title.uppercased()) ]",
            filled: mode == m,
            disabled: false
        ) {
            mode = m
            if m == .manual, argsText.isEmpty {
                argsText = manualProfile.argumentsLine
            }
        }
    }

    private func profileRow(_ p: DPIProfile) -> some View {
        CRTActionButton(
            title: manualProfile == p ? "[ \(p.shortTitle) ✓ ]" : "[ \(p.shortTitle) ]",
            filled: manualProfile == p,
            disabled: false
        ) {
            manualProfile = p
            argsText = p.argumentsLine
        }
    }

    private func saveAll() {
        errorText = nil
        var warnings: [String] = []

        TouchSettings.launchAtLogin = launchAtLogin
        TouchSettings.autoConnect = autoConnect
        if launchAtLogin != LoginItem.isEnabled, let err = LoginItem.setEnabled(launchAtLogin) {
            warnings.append(err)
        }

        do {
            if mode == .auto {
                TouchSettings.strategyMode = .auto
                if let saved = TouchSettings.savedProfile() {
                    engine.profile = saved
                }
                if engine.isOn {
                    engine.reconnectIfOn()
                }
            } else {
                try engine.saveStrategySettings(
                    mode: .manual,
                    profile: manualProfile,
                    argsLine: argsText
                )
            }
            if let warning = warnings.first {
                errorText = warning
            }
            flashSaved()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func reloadFromSettings() {
        mode = TouchSettings.strategyMode
        manualProfile = TouchSettings.savedProfile() ?? engine.profile
        let custom = TouchSettings.customStrategyArgs
        argsText = custom.isEmpty ? manualProfile.argumentsLine : custom
        launchAtLogin = TouchSettings.launchAtLogin
        autoConnect = TouchSettings.autoConnect
    }

    private func flashSaved() {
        savedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            savedFlash = false
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(CRT.mono(11, weight: .bold))
            .foregroundStyle(CRT.amber)
    }

    private var boxStroke: some View {
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(CRT.amber.opacity(0.2), lineWidth: 1)
    }
}

// CRT toggle — bracket buttons instead of system switches
struct CRTToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(CRT.mono(10))
                .foregroundStyle(CRT.label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Button {
                isOn.toggle()
            } label: {
                Text(isOn ? "[ ON ]" : "[ OFF ]")
                    .font(CRT.mono(9, weight: .bold))
                    .foregroundStyle(isOn ? CRT.black : CRT.amber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(isOn ? CRT.amber.opacity(0.9) : CRT.black)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(CRT.amber.opacity(isOn ? 1 : 0.55), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
        }
    }
}

// Shared button — main panel + settings
struct CRTActionButton: View {
    let title: String
    var filled: Bool = false
    let disabled: Bool
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(CRT.mono(10, weight: .bold))
                .foregroundStyle(fg)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(bg)
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(border, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hover = $0 }
    }

    private var fg: Color {
        if disabled { return CRT.amberDim.opacity(0.45) }
        if filled { return CRT.black }
        return hover ? CRT.amber : CRT.amber.opacity(0.9)
    }

    private var bg: Color {
        if disabled { return CRT.amber.opacity(0.04) }
        if filled { return CRT.amber.opacity(hover ? 0.95 : 0.85) }
        return hover ? CRT.amber.opacity(0.1) : CRT.black
    }

    private var border: Color {
        if disabled { return CRT.amber.opacity(0.2) }
        return CRT.amber.opacity(filled ? 1 : hover ? 0.75 : 0.55)
    }
}
