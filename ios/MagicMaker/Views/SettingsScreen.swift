import SwiftUI

// SETTINGS tab: global transmission tuning, the scan filter and the app version. Port of
// Android `SettingsTabScreen` and `TransmissionSettingsSection` in `LabPacketBuilderPanel.kt`.
// The values live in this phone's preferences; while a relay (Android or ESP32) is linked each
// change is also sent to it, since TX mode and broadcast strength act on the relay's own radio.

/// Broadcast strength levels 0...3, as Android labels them.
private let settingsPowerNames: [String] = ["MIN", "LOW", "MED", "MAX"]

/// Whether the transmission block is folded, under Android's preference name.
private enum SettingsScreenPrefs {
    static let transmissionCollapsedKey = "lab_tx_settings_collapsed"

    static func loadTransmissionCollapsed() -> Bool {
        let value: Any? = UserDefaults.standard.object(forKey: transmissionCollapsedKey)
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return text.lowercased() == "true" }
        return false
    }

    static func saveTransmissionCollapsed(_ collapsed: Bool) {
        UserDefaults.standard.set(collapsed, forKey: transmissionCollapsedKey)
    }
}

/// "v1.3.0 (13)" from the bundle's short version and build number.
private func settingsAppVersionText() -> String {
    let info: [String: Any] = Bundle.main.infoDictionary ?? [:]
    let short: String = (info["CFBundleShortVersionString"] as? String) ?? "?"
    let build: String = (info["CFBundleVersion"] as? String) ?? "?"
    return "v\(short) (\(build))"
}

/// Slider values are whole milliseconds; the slider has already snapped and clamped them.
private func settingsMilliseconds(_ value: Double) -> Int {
    if !value.isFinite { return 0 }
    let bounded: Double = min(max(value, -1_000_000), 1_000_000)
    return Int(bounded)
}

// MARK: - Screen

struct SettingsScreen: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var store: MagicStore

    @State private var collapsed: Bool = SettingsScreenPrefs.loadTransmissionCollapsed()
    @State private var preambleMs: Double = Double(TransmitTiming.defaultWakeupPreludeMs)
    @State private var burstMs: Double = Double(TransmitTiming.commandBurstMs)
    @State private var starlightMs: Double = Double(TransmitTiming.starlightBurstMs)
    @State private var interleave: Bool = false
    @State private var txPower: Int = 3

    init() {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                header
                SettingsAppearanceSection()
                    .padding(.top, 8)
                transmissionSection
                SettingsScanFilterSection(onChange: { on in scanFilterChanged(on) })
                    .padding(.top, 8)
                SettingsBackgroundSection()
                    .padding(.top, 8)
                SettingsWatchSection()
                    .padding(.top, 8)
                SettingsFirmwareSection(updater: vm.firmware)
                    .padding(.top, 8)
                aboutLine
                    .padding(.top, 8)
            }
            .padding(6)
        }
        .background(MMTheme.navy)
        .onAppear {
            reloadFromStore()
        }
        .onChange(of: store.revision) { _, _ in
            reloadFromStore()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SETTINGS")
                .font(MMTheme.techHeader())
                .foregroundStyle(MMTheme.cyan)
            Text("Global transmission tuning — applies to every TX.")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
        }
    }

    // MARK: Transmission settings

    private var transmissionSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            transmissionHeader
            if !collapsed {
                transmissionBody
            }
        }
    }

    private var transmissionHeader: some View {
        Button {
            toggleCollapsed()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MMTheme.textDim)
                    .frame(width: 16)
                Text("TRANSMISSION SETTINGS")
                    .font(MMTheme.techHeader())
                    .foregroundStyle(MMTheme.cyan)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var transmissionBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            relayNote
            txModeRow
            Text(txModeHint)
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            strengthBlock
                .padding(.top, 4)
            preambleSlider
                .padding(.top, 4)
            burstSlider
                .padding(.top, 4)
            starlightSlider
                .padding(.top, 4)
        }
    }

    /// Where the values take effect: TX mode and strength act on the relay's own radio.
    private var relayNote: some View {
        let linked: Bool = relayTakesSettings
        let text: String
        if !linked {
            text = "TX MODE AND STRENGTH APPLY ON THE RELAY (ANDROID OR ESP32)"
        } else if vm.relayBackend == .esp32 {
            text = "ESP32 LINKED — CHANGES ARE SENT TO IT TOO"
        } else {
            text = "ANDROID RELAY LINKED — CHANGES ARE SENT TO IT TOO"
        }
        return Text(text)
            .font(MMTheme.techLabel(9))
            .foregroundStyle(linked ? MMTheme.cyanDim : MMTheme.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var txModeRow: some View {
        HStack(spacing: 6) {
            Text(interleave ? "TX MODE: INTERLEAVE" : "TX MODE: SUSTAINED")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.cyan)
            Spacer(minLength: 4)
            Toggle("", isOn: interleaveBinding)
                .labelsHidden()
                .tint(MMTheme.cyan)
                .accessibilityLabel("TX mode interleave")
        }
    }

    private var txModeHint: String {
        if interleave {
            return "Alternates wake/command slices — lighter, good in-park. WAKE=slice, COMMAND=total window."
        }
        return "Sustained wake stream, then command stream — strongest wake. WAKE=wake length, COMMAND=command length."
    }

    private var interleaveBinding: Binding<Bool> {
        Binding(
            get: { interleave },
            set: { on in setInterleave(on) }
        )
    }

    private var strengthBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("BROADCAST STRENGTH")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
            HStack(spacing: 4) {
                ForEach(0..<settingsPowerNames.count, id: \.self) { level in
                    powerButton(level)
                }
            }
            Text("Lower = shorter range, fewer nearby bands react · default MAX")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func powerButton(_ level: Int) -> some View {
        let name: String = level < settingsPowerNames.count ? settingsPowerNames[level] : "\(level)"
        let selected: Bool = txPower == level
        let lineColor: Color = selected ? MMTheme.cyan : MMTheme.panelLine
        let traits: AccessibilityTraits = selected ? .isSelected : []
        return Button {
            setTxPower(level)
        } label: {
            Text(name)
                .font(MMTheme.techLabel())
                .foregroundStyle(selected ? MMTheme.cyan : MMTheme.textDim)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(lineColor, lineWidth: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(traits)
    }

    private var preambleSlider: some View {
        let low: Double = Double(TransmitTiming.minWakeupPreludeMs)
        let high: Double = Double(TransmitTiming.maxWakeupPreludeMs)
        let hint: String = "Each wake/command slice in the 1:1 interleave · default \(TransmitTiming.defaultWakeupPreludeMs)ms"
        return SettingSlider(
            title: "WAKE SLICE",
            value: $preambleMs,
            range: low...high,
            step: 50,
            unit: "ms",
            hint: hint,
            onCommit: { ms in commitPreamble(ms) }
        )
    }

    private var burstSlider: some View {
        let low: Double = Double(TransmitTiming.minCommandBurstMs)
        let high: Double = Double(TransmitTiming.maxCommandBurstMs)
        let hint: String = "Total wake+command interleave window · default \(TransmitTiming.commandBurstMs)ms · global"
        return SettingSlider(
            title: "COMMAND BURST",
            value: $burstMs,
            range: low...high,
            step: 50,
            unit: "ms",
            hint: hint,
            onCommit: { ms in commitBurst(ms) }
        )
    }

    // Android gives this slider 18 inner stops over 250…5000 ms, which is one stop per 250 ms.
    private var starlightSlider: some View {
        let low: Double = Double(TransmitTiming.minStarlightBurstMs)
        let high: Double = Double(TransmitTiming.maxStarlightBurstMs)
        let hint: String = "On-air time for starlight wand TX · no band wakeup · default \(TransmitTiming.starlightBurstMs)ms"
        return SettingSlider(
            title: "STARLIGHT WAND",
            value: $starlightMs,
            range: low...high,
            step: 250,
            unit: "ms",
            hint: hint,
            onCommit: { ms in commitStarlight(ms) }
        )
    }

    // MARK: About

    private var aboutLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ABOUT")
                .font(MMTheme.techHeader())
                .foregroundStyle(MMTheme.cyan)
            Text("MAGICMAKER " + settingsAppVersionText())
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
                .textSelection(.enabled)
        }
    }

    // MARK: Actions

    /// A relay is linked and takes commands: an Android relay (BLE or WiFi) or the ESP32, which
    /// keeps these settings in its RAM (the iPhone gives them again on every link).
    private var relayTakesSettings: Bool {
        vm.remoteLinkReady
    }

    /// An Android relay (BLE or WiFi) took the change. Otherwise it is noted for the Android
    /// relay's next link, as it was before the ESP32 took settings too.
    private var androidRelayLinked: Bool {
        vm.relayBackend != .esp32 && vm.remoteLinkReady
    }

    private func reloadFromStore() {
        preambleMs = Double(store.getWakeupPreambleMs())
        burstMs = Double(store.getCommandBurstMs())
        starlightMs = Double(store.getStarlightBurstMs())
        interleave = store.getTxInterleave()
        txPower = store.getTxPowerLevel()
    }

    private func toggleCollapsed() {
        let next: Bool = !collapsed
        collapsed = next
        SettingsScreenPrefs.saveTransmissionCollapsed(next)
    }

    private func setInterleave(_ on: Bool) {
        interleave = on
        store.saveTxInterleave(on)
        if relayTakesSettings {
            vm.sendRelaySetting("set_tx_interleave", ["enabled": on])
        }
        if !androidRelayLinked {
            vm.noteRelaySettingPending("tx_interleave")
        }
    }

    private func setTxPower(_ level: Int) {
        txPower = level
        store.saveTxPowerLevel(level)
        if relayTakesSettings {
            vm.sendRelaySetting("set_tx_power", ["level": level])
        }
        if !androidRelayLinked {
            vm.noteRelaySettingPending("tx_power")
        }
    }

    private func commitPreamble(_ value: Double) {
        let ms: Int = settingsMilliseconds(value)
        preambleMs = Double(ms)
        store.saveWakeupPreambleMs(ms)
        if relayTakesSettings {
            vm.setAndroidWakeupPreamble(ms)
        }
        if !androidRelayLinked {
            vm.noteRelaySettingPending("wakeup_preamble")
        }
    }

    private func commitBurst(_ value: Double) {
        let ms: Int = settingsMilliseconds(value)
        burstMs = Double(ms)
        store.saveCommandBurstMs(ms)
        if relayTakesSettings {
            vm.setAndroidCommandBurst(ms)
        }
        if !androidRelayLinked {
            vm.noteRelaySettingPending("command_burst")
        }
    }

    private func commitStarlight(_ value: Double) {
        let ms: Int = settingsMilliseconds(value)
        starlightMs = Double(ms)
        store.saveStarlightBurstMs(ms)
        if relayTakesSettings {
            vm.setAndroidStarlightBurst(ms)
        }
        if !androidRelayLinked {
            vm.noteRelaySettingPending("starlight_burst")
        }
    }

    /// The scan filter is the iPhone's own; a linked Android relay is told too, as its relay
    /// command handler expects from this tab. The ESP32 does not scan.
    private func scanFilterChanged(_ on: Bool) {
        if androidRelayLinked {
            vm.sendRelaySetting("set_show_control_only", ["enabled": on])
        } else {
            vm.noteRelaySettingPending("show_control_only")
        }
    }
}

// MARK: - Appearance

/// THEME (STANDARD / VFD) and, under the VFD theme, its BASE COLOUR: the six presets and CUSTOM
/// with the system colour picker. Both themes read these from `VFDSettings`.
private struct SettingsAppearanceSection: View {
    @ObservedObject private var settings: VFDSettings = VFDSettings.shared

    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("APPEARANCE")
                .font(MMTheme.techHeader())
                .foregroundStyle(MMTheme.cyan)
            Text("THEME")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
            themePicker
            if settings.theme == .vfd {
                baseColourBlock
                    .padding(.top, 4)
            }
        }
    }

    private var themePicker: some View {
        Picker("THEME", selection: $settings.theme) {
            ForEach(VFDTheme.allCases) { theme in
                Text(theme.label).tag(theme)
            }
        }
        .pickerStyle(.segmented)
    }

    private var baseColourBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("BASE COLOUR")
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textDim)
                Spacer(minLength: 4)
                Text(settings.base.rgb.hex)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.cyan)
            }
            LazyVGrid(columns: baseColumns, alignment: .leading, spacing: 4) {
                ForEach(0..<VFDSettings.baseItems.count, id: \.self) { index in
                    baseChip(index)
                }
            }
            if settings.baseIsCustom {
                VFDBaseColorPicker(title: "CUSTOM COLOUR")
                    .padding(.top, 2)
            }
        }
    }

    private var baseColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)
    }

    private func baseChip(_ index: Int) -> some View {
        let items: [String] = VFDSettings.baseItems
        let name: String = index >= 0 && index < items.count ? items[index] : ""
        let selected: Bool = settings.baseIndex == index
        let swatch: Color = VFDSettings.color(settings.itemRGB(index))
        let lineColor: Color = selected ? MMTheme.cyan : MMTheme.panelLine
        let traits: AccessibilityTraits = selected ? .isSelected : []
        return Button {
            settings.selectBase(index: index)
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(swatch)
                    .frame(width: 10, height: 10)
                Text(name)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(selected ? MMTheme.cyan : MMTheme.textDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(lineColor, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(traits)
    }
}

// MARK: - Scan filter

/// Android's SHOW-CTRL / ALL RAW scan filter. Kept apart from the screen so only this part
/// follows the scan engine while packets arrive.
private struct SettingsScanFilterSection: View {
    @EnvironmentObject var scan: ScanEngine
    let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SCAN FILTER")
                .font(MMTheme.techHeader())
                .foregroundStyle(MMTheme.cyan)
            filterRow
            Text("Filter MagicBand/device noise out of the scan (default on); flip to see all raw.")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var filterRow: some View {
        let on: Bool = scan.showControlOnly
        return HStack(spacing: 6) {
            Text(on ? "SHOW-CTRL" : "ALL RAW")
                .font(MMTheme.techLabel())
                .foregroundStyle(on ? MMTheme.cyan : MMTheme.textDim)
            Spacer(minLength: 4)
            Toggle("", isOn: filterBinding)
                .labelsHidden()
                .tint(MMTheme.cyan)
                .accessibilityLabel("Show-control packets only")
        }
    }

    private var filterBinding: Binding<Bool> {
        Binding(
            get: { scan.showControlOnly },
            set: { on in
                scan.showControlOnly = on
                onChange(on)
            }
        )
    }
}

// MARK: - Background

/// Opt-in "Keep running in background": background location keeps the app running while it is
/// not on screen and this iPhone itself sends (its own loops, the show, replays). The state line
/// and the note say honestly what that does and does not do.
private struct SettingsBackgroundSection: View {
    @EnvironmentObject var vm: AppViewModel

    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("BACKGROUND")
                .font(MMTheme.techHeader())
                .foregroundStyle(MMTheme.cyan)
            toggleRow
            Text(vm.backgroundKeepAlive.text)
                .font(MMTheme.techLabel())
                .foregroundStyle(stateColor)
                .fixedSize(horizontal: false, vertical: true)
            Text(AppViewModel.backgroundKeepAliveNote)
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var toggleRow: some View {
        let on: Bool = vm.keepRunningInBackground
        return HStack(spacing: 6) {
            Text("KEEP RUNNING IN BACKGROUND")
                .font(MMTheme.techLabel())
                .foregroundStyle(on ? MMTheme.cyan : MMTheme.textDim)
            Spacer(minLength: 4)
            Toggle("", isOn: keepRunningBinding)
                .labelsHidden()
                .tint(MMTheme.cyan)
                .accessibilityLabel("Keep running in background")
        }
    }

    private var stateColor: Color {
        vm.backgroundKeepAlive == .needsLocation ? MMTheme.amber : MMTheme.textDim
    }

    private var keepRunningBinding: Binding<Bool> {
        Binding(
            get: { vm.keepRunningInBackground },
            set: { on in vm.setKeepRunningInBackground(on) }
        )
    }
}

// MARK: - Board firmware

/// BOARD FIRMWARE: the linked ESP32's board and firmware version, the newest image the app has for
/// it (bundled, or downloaded with CHECK WEB), UPDATE with the press-the-button prompt, the
/// progress (percent, KB/s), the result and CANCEL (FirmwareUpdater). Installing the same or an
/// older version asks first.
private struct SettingsFirmwareSection: View {
    @EnvironmentObject var vm: AppViewModel
    @ObservedObject private var updater: FirmwareUpdater
    @State private var confirmPresented: Bool = false
    @State private var confirmText: String = ""

    init(updater: FirmwareUpdater) {
        _updater = ObservedObject(wrappedValue: updater)
    }

    var body: some View {
        content(updater.summary(linked: vm.esp32Linked))
            .alert("Install firmware?", isPresented: $confirmPresented) {
                Button("INSTALL") {
                    updater.startUpdate()
                }
                Button("CANCEL", role: .cancel) { }
            } message: {
                Text(confirmText)
            }
    }

    private func content(_ s: FirmwareUpdater.Summary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("BOARD FIRMWARE")
                .font(MMTheme.techHeader())
                .foregroundStyle(MMTheme.cyan)
            valueRow("BOARD", s.boardText, color: s.boardAlarm ? MMTheme.amber : MMTheme.cyan)
            ForEach(0..<s.available.count, id: \.self) { index in
                valueRow(s.available[index].key, s.available[index].value, color: MMTheme.cyan)
            }
            if !s.webText.isEmpty {
                Text(s.webText)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !s.instruction.isEmpty {
                Text(s.instruction)
                    .font(MMTheme.techLabel(s.instructionIsPrompt ? 12 : 10))
                    .foregroundStyle(s.instructionIsPrompt ? MMTheme.amber : MMTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            if s.showsProgress {
                ProgressView(value: s.progress)
                    .tint(MMTheme.cyan)
                    .padding(.top, 4)
                Text(s.progressText)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.cyan)
            }
            if !s.resultText.isEmpty {
                Text(s.resultText)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(s.resultIsError ? MMTheme.error : MMTheme.cyan)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            HStack(spacing: 4) {
                if s.canCancel {
                    actionButton("CANCEL", enabled: true, color: MMTheme.error) {
                        updater.cancel()
                    }
                } else {
                    actionButton(s.actionTitle, enabled: s.actionEnabled, color: MMTheme.cyan) {
                        update(s)
                    }
                }
                actionButton(s.checkingWeb ? "CHECKING…" : "CHECK WEB", enabled: !s.checkingWeb && !s.busy,
                             color: MMTheme.cyan) {
                    updater.catalog.checkWeb()
                }
            }
            .padding(.top, 4)
        }
    }

    private func valueRow(_ key: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
            Spacer(minLength: 4)
            Text(value)
                .font(MMTheme.techLabel())
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
        }
    }

    private func actionButton(_ title: String, enabled: Bool, color: Color,
                              action: @escaping () -> Void) -> some View {
        let lineColor: Color = enabled ? color : MMTheme.panelLine
        return Button {
            action()
        } label: {
            Text(title)
                .font(MMTheme.techLabel())
                .foregroundStyle(enabled ? color : MMTheme.textDim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(lineColor, lineWidth: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// The same or an older version asks first.
    private func update(_ s: FirmwareUpdater.Summary) {
        if let message = s.confirmMessage {
            confirmText = message
            confirmPresented = true
            return
        }
        updater.startUpdate()
    }
}
