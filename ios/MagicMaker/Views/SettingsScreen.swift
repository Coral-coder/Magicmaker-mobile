import SwiftUI

// SETTINGS tab: global transmission tuning, the scan filter and the app version. Port of
// Android `SettingsTabScreen` and `TransmissionSettingsSection` in `LabPacketBuilderPanel.kt`.
// The values live in this phone's preferences; while an Android relay is linked each change is
// also sent to it, since TX mode and broadcast strength act on the relay's own radio.

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
                transmissionSection
                SettingsScanFilterSection(onChange: { on in scanFilterChanged(on) })
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

    /// Where the values take effect: TX mode and strength only mean something on an Android relay.
    private var relayNote: some View {
        let linked: Bool = androidRelayLinked
        let text: String = linked
            ? "ANDROID RELAY LINKED — CHANGES ARE SENT TO IT TOO"
            : "TX MODE AND STRENGTH APPLY ON AN ANDROID RELAY"
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

    /// An Android relay (BLE or WiFi) is linked and takes commands; the ESP32 takes only packets.
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
        if androidRelayLinked {
            vm.sendRelaySetting("set_tx_interleave", ["enabled": on])
        }
    }

    private func setTxPower(_ level: Int) {
        txPower = level
        store.saveTxPowerLevel(level)
        if androidRelayLinked {
            vm.sendRelaySetting("set_tx_power", ["level": level])
        }
    }

    private func commitPreamble(_ value: Double) {
        let ms: Int = settingsMilliseconds(value)
        preambleMs = Double(ms)
        store.saveWakeupPreambleMs(ms)
        if androidRelayLinked {
            vm.setAndroidWakeupPreamble(ms)
        }
    }

    private func commitBurst(_ value: Double) {
        let ms: Int = settingsMilliseconds(value)
        burstMs = Double(ms)
        store.saveCommandBurstMs(ms)
        if androidRelayLinked {
            vm.setAndroidCommandBurst(ms)
        }
    }

    private func commitStarlight(_ value: Double) {
        let ms: Int = settingsMilliseconds(value)
        starlightMs = Double(ms)
        store.saveStarlightBurstMs(ms)
        if androidRelayLinked {
            vm.setAndroidStarlightBurst(ms)
        }
    }

    /// The scan filter is the iPhone's own; a linked Android relay is told too, as its relay
    /// command handler expects from this tab.
    private func scanFilterChanged(_ on: Bool) {
        if androidRelayLinked {
            vm.sendRelaySetting("set_show_control_only", ["enabled": on])
        }
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
