import SwiftUI

// LAB tab: compose a packet, read what it does, edit its bytes, send it through the relay and keep
// it as a preset. Port of Android `LabTabScreen`, `LabModeBar`, `PacketInspector` and
// `RandomLightShowSection` (LabPacketBuilderPanel.kt), plus the MBLE tap section the iPhone Lab
// has always had. Transmission timing lives on the Settings tab, as on Android.

struct LabScreen: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var store: MagicStore
    @EnvironmentObject var tx: TxEngine

    /// Standard (known & tested) vs Extended (experimental) Lab.
    @AppStorage("lab_extended") private var extended: Bool = false
    /// The hex field. Persisted (`lab_hex`) on SEND, SAVE, TAG and whenever the builder or the
    /// inspector writes it, as on Android.
    @State private var hex: String = ""
    @State private var label: String = ""
    /// What the preview animates: the builder's live packet, or the hex field when it is edited
    /// directly.
    @State private var previewHex: String = ""
    @State private var presetMsg: String? = nil
    /// The load the builder has been handed; it follows `vm.labLoadTick` once the packet is read.
    @State private var builderLoadTick: Int = 0
    /// The builder appears only after the saved packet has been read, so it decodes the right one.
    @State private var loaded: Bool = false
    @State private var deleteRequest: DeleteRequest? = nil
    /// Apple Watch favourites: the preset stars follow every change.
    @ObservedObject private var favorites: WatchFavoritesStore = WatchFavoritesStore.shared
    @State private var favoritesFull: Bool = false

    init() {}

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Pinned: the top sixth of the screen, always visible, animating the Lab's packet.
                // The Lab scrolls independently beneath it.
                BandPreviewView(hex: previewHex)
                    .frame(height: geo.size.height / 6)
                LabScreenDivider()
                if loaded {
                    labScroll
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
        .background(MMTheme.navy)
        .confirmDelete($deleteRequest)
        .favoritesFullAlert($favoritesFull)
        .onAppear {
            reloadFromStore()
        }
        .onChange(of: vm.labLoadTick) { _, _ in
            reloadFromStore()
        }
    }

    private var labScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                builderGroup
                editGroup
                extrasGroup
            }
            .padding(8)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(MMTheme.navy)
    }

    // MARK: - Groups

    private var builderGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabModeBar(extended: $extended)
            LabScreenDivider()
            MMSectionTitle("PACKET BUILDER")
            Text("Pick what the band should do, set the colors, and the card below tells you exactly what you're sending.")
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            LabBuilderPanel(
                extended: extended,
                loadedHex: hex,
                loadTick: builderLoadTick,
                savedSerial: store.getStarlightSerial(),
                onHexChanged: { built in previewHex = built },
                onHexBuilt: { built in useBuiltHex(built) }
            )
        }
    }

    private var editGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabScreenDivider()
            packetFields
            LabPacketInspector(hex: hex, onHexChange: { edited in inspectorEdited(edited) })
            actionSection
        }
    }

    private var extrasGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabScreenDivider()
            LabRandomShowSection()
            presetSection
            LabMbleSection()
            LabThemesSection()
        }
    }

    // MARK: - Hex and label

    private var packetFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldCaption("HEX OUTPUT")
            TextField("HEX (8301…)", text: hexBinding)
                .labScreenField(MMTheme.cyanDim)
                .textInputAutocapitalization(.characters)
            fieldCaption("LABEL")
            TextField("LABEL", text: $label)
                .labScreenField(MMTheme.textPrimary)
            if let reason = HexUtils.legacyAdvertiseRejectReason(hex) {
                Text(reason)
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.error)
            }
        }
    }

    /// Typing in the hex field also drives the preview.
    private var hexBinding: Binding<String> {
        Binding(
            get: { hex },
            set: { typed in
                let upper: String = typed.uppercased()
                hex = upper
                previewHex = upper
            }
        )
    }

    private func fieldCaption(_ text: String) -> some View {
        Text(text)
            .font(MMTheme.techLabel(9))
            .foregroundStyle(MMTheme.cyanDim)
    }

    // MARK: - SEND / SAVE / TAG

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            actionButtons
            if let msg = presetMsg {
                Text(msg)
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(msg.hasPrefix("Saved") ? MMTheme.cyan : MMTheme.textDim)
            }
            if !vm.remoteLinkReady {
                Text("LINK NOT READY — CONNECT A RELAY ON THE LINK TAB TO SEND")
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.amber)
            }
            StatusLine(tx.status)
        }
    }

    /// SEND is the one control in the Lab that puts a packet on the air.
    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                send()
            } label: {
                Text("SEND")
                    .font(MMTheme.techHeader())
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .tint(MMTheme.cyan)
            Button {
                savePreset()
            } label: {
                Text("SAVE")
                    .font(MMTheme.techLabel())
                    .frame(minHeight: 36)
            }
            .buttonStyle(.bordered)
            .tint(MMTheme.cyan)
            Button {
                tagRaw()
            } label: {
                Text("TAG")
                    .font(MMTheme.techLabel())
                    .frame(minHeight: 36)
            }
            .buttonStyle(.bordered)
            .tint(MMTheme.cyan)
        }
    }

    // MARK: - My presets

    @ViewBuilder
    private var presetSection: some View {
        let presets: [MagicPacket] = sortedPresets
        if !presets.isEmpty {
            LabScreenDivider()
            MMSectionTitle("MY PRESETS (\(presets.count))")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(presets) { preset in
                    LabPresetRow(
                        preset: preset,
                        starred: favorites.isStarred(hex: preset.hex),
                        onLoad: { loadPreset(preset) },
                        onStar: { toggleStar(preset) },
                        onDelete: { askDelete(preset) }
                    )
                }
            }
        }
    }

    /// The user presets by label, ignoring case; equal labels keep the library's order.
    private var sortedPresets: [MagicPacket] {
        _ = store.revision
        let list: [MagicPacket] = store.customPresets
        let lowered: [String] = list.map { (packet: MagicPacket) -> String in packet.label.lowercased() }
        let order: [Int] = Array(list.indices).sorted { (a: Int, b: Int) -> Bool in
            let left: String = lowered[a]
            let right: String = lowered[b]
            if left != right {
                return left.utf16.lexicographicallyPrecedes(right.utf16)
            }
            return a < b
        }
        return order.map { (index: Int) -> MagicPacket in list[index] }
    }

    // MARK: - Actions

    /// Reads the Lab packet and label back from the store, on entry and whenever another screen
    /// sends a packet here.
    private func reloadFromStore() {
        let savedHex: String = store.getLabHex()
        hex = savedHex
        label = store.getLabLabel()
        previewHex = savedHex
        builderLoadTick = vm.labLoadTick
        loaded = true
    }

    private func useBuiltHex(_ built: String) {
        hex = built
        previewHex = built
        store.saveLabHex(built)
    }

    private func inspectorEdited(_ edited: String) {
        hex = edited
        store.saveLabHex(edited)
    }

    private func send() {
        store.saveLabHex(hex)
        store.saveLabLabel(label)
        let trimmed: String = label.trimmingCharacters(in: .whitespacesAndNewlines)
        tx.transmit(hex: hex, label: trimmed.isEmpty ? "Lab" : trimmed)
    }

    private func savePreset() {
        store.saveLabHex(hex)
        store.saveLabLabel(label)
        let refusal: String? = store.saveCustomPreset(label: label, hex: hex)
        presetMsg = refusal ?? "Saved preset — see TX + Auto tabs"
    }

    private func tagRaw() {
        store.saveLabHex(hex)
        store.saveLabLabel(label)
        store.applyLabLabelToMatchingRaw()
        presetMsg = "Raw tag updated"
    }

    private func loadPreset(_ preset: MagicPacket) {
        hex = preset.hex
        label = preset.label
        store.saveLabHex(preset.hex)
        store.saveLabLabel(preset.label)
    }

    /// The preset's watch star: adds it to the Apple Watch favourites, or removes it.
    private func toggleStar(_ preset: MagicPacket) {
        if !favorites.toggle(hex: preset.hex, label: preset.label, source: WatchFavorite.Source.labPreset) {
            favoritesFull = true
        }
    }

    private func askDelete(_ preset: MagicPacket) {
        let id: Int64 = preset.id
        deleteRequest = DeleteRequest(title: "Delete preset?", label: preset.label, hex: preset.hex) {
            store.deleteCustomPreset(id: id)
            presetMsg = "Preset deleted"
        }
    }
}

// MARK: - Mode bar

/// Lab header: Standard / Extended, and the keep-awake transmit mode, which runs on the relay
/// (Android `LabModeBar`).
private struct LabModeBar: View {
    @EnvironmentObject var vm: AppViewModel
    @Binding var extended: Bool
    @State private var pingHex: String = PacketBuilder.wakeupPing

    private static let beaconPingHex: String = "8301CC03000000"
    private static let pingOptions: [(Int, String)] = [
        (0, "Wake ping (CC03 000100)"),
        (1, "Beacon ping (CC03 000000)"),
    ]

    init(extended: Binding<Bool>) {
        self._extended = extended
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            modeRow
            keepAwakeRow
            if vm.keepAwakeActive || extended {
                LabPalettePicker(label: "PING", selection: pingBinding, options: LabModeBar.pingOptions)
            }
        }
    }

    private var modeRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(extended ? "EXTENDED · EXPERIMENTAL" : "STANDARD · KNOWN & TESTED")
                    .font(MMTheme.techHeader())
                    .foregroundStyle(extended ? MMTheme.amber : MMTheme.cyan)
                Text(extended
                     ? "Adds RGB sliders, single-LED masks and the Experiments list. Untested on a band."
                     : "Everything here has been seen working.")
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: $extended)
                .labelsHidden()
                .tint(MMTheme.amber)
        }
    }

    private var keepAwakeRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("KEEP BAND AWAKE")
                    .font(MMTheme.techHeader())
                    .foregroundStyle(vm.keepAwakeActive ? MMTheme.cyan : MMTheme.textPrimary)
                Text(vm.keepAwakeActive
                     ? "Relay scanning paused · streaming pings · SEND goes out for the command interval, then pings resume"
                     : "The relay pauses scanning and streams wake pings so the band stays listening between sends.")
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            // Keep-awake is a relay command; it can always be switched off.
            Toggle("", isOn: keepAwakeBinding)
                .labelsHidden()
                .tint(MMTheme.cyan)
                .disabled(!vm.remoteLinkReady && !vm.keepAwakeActive)
        }
    }

    private var keepAwakeBinding: Binding<Bool> {
        Binding(
            get: { vm.keepAwakeActive },
            set: { on in vm.setKeepAwake(on, hex: pingHex) }
        )
    }

    private var pingBinding: Binding<Int> {
        Binding(
            get: { pingHex == LabModeBar.beaconPingHex ? 1 : 0 },
            set: { picked in
                let next: String = picked == 1 ? LabModeBar.beaconPingHex : PacketBuilder.wakeupPing
                pingHex = next
                if vm.keepAwakeActive {
                    vm.setKeepAwake(true, hex: next)
                }
            }
        )
    }
}

// MARK: - Packet inspector

/// Fine-grained editor for the hex field (Android `PacketInspector`): live classification, the
/// vibration nibble of the tail byte (0–15) and a per-byte hex grid. Collapsed by default.
private struct LabPacketInspector: View {
    let hex: String
    let onHexChange: (String) -> Void

    @State private var expanded: Bool = false

    private static let gridColumns: [GridItem] = [
        GridItem(.adaptive(minimum: 44, maximum: 56), spacing: 4),
    ]

    init(hex: String, onHexChange: @escaping (String) -> Void) {
        self.hex = hex
        self.onHexChange = onHexChange
    }

    var body: some View {
        let classified: ClassifiedPacket? = MagicClassifier.classify(HexUtils.canonicalHex(hex))
        let bytes: [String] = LabPacketTools.toBytes(hex)
        VStack(alignment: .leading, spacing: 4) {
            header(byteCount: bytes.count)
            classificationLines(classified)
            if expanded {
                expandedBody(bytes)
            }
        }
    }

    private func header(byteCount: Int) -> some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MMTheme.textDim)
                    .frame(width: 16)
                Text("PACKET INSPECTOR")
                    .font(MMTheme.techHeader())
                    .foregroundStyle(MMTheme.cyan)
                Spacer(minLength: 4)
                Text("\(byteCount) B")
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textDim)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func classificationLines(_ classified: ClassifiedPacket?) -> some View {
        Text(LabPacketInspector.classificationText(classified))
            .font(MMTheme.techLabel(9))
            .foregroundStyle(classified != nil ? MMTheme.cyan : MMTheme.textDim)
            .lineLimit(2)
        if let colors = LabPacketInspector.colorsText(classified) {
            Text(colors)
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.cyanDim)
        }
    }

    private static func classificationText(_ classified: ClassifiedPacket?) -> String {
        guard let packet = classified else { return "Unclassified / raw payload" }
        return packet.label + " · " + packet.category.rawValue
    }

    private static func colorsText(_ classified: ClassifiedPacket?) -> String? {
        guard let packet = classified else { return nil }
        if packet.colors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return "COLORS: " + packet.colors.uppercased()
    }

    @ViewBuilder
    private func expandedBody(_ bytes: [String]) -> some View {
        if let vib = LabPacketTools.tailVibration(hex) {
            vibrationRow(vib)
        }
        Text("RAW BYTES — tap to edit")
            .font(MMTheme.techLabel(9))
            .foregroundStyle(MMTheme.cyanDim)
        LazyVGrid(columns: LabPacketInspector.gridColumns, alignment: .leading, spacing: 4) {
            ForEach(0..<bytes.count, id: \.self) { index in
                LabByteCell(value: bytes[index], onEdit: { typed in editByte(index, typed, bytes) })
            }
        }
        Text("Color bytes use low 5 bits (00–1F). E0=preset · 80/80=dual · A0×5=rainbow · 40/40=xfade · tail B0|vib.")
            .font(MMTheme.techLabel(9))
            .foregroundStyle(MMTheme.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func vibrationRow(_ vib: Int) -> some View {
        HStack(spacing: 8) {
            Text("VIBRATION")
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
            stepButton("–", label: "Less vibration", enabled: vib > 0) {
                onHexChange(LabPacketTools.withVibration(hex, max(vib - 1, 0)))
            }
            Text(LabPacketInspector.vibrationText(vib))
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.cyan)
            stepButton("+", label: "More vibration", enabled: vib < 15) {
                onHexChange(LabPacketTools.withVibration(hex, min(vib + 1, 15)))
            }
            Text("0xB0 | vib")
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
            Spacer(minLength: 0)
        }
    }

    /// Two digits, as Android pads it.
    private static func vibrationText(_ vib: Int) -> String {
        if vib >= 0 && vib < 10 {
            return "0" + String(vib)
        }
        return String(vib)
    }

    private func stepButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol)
                .font(MMTheme.techHeader(13))
                .foregroundStyle(enabled ? MMTheme.cyan : MMTheme.textDim)
                .frame(width: 28, height: 28)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(MMTheme.panelLine, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    /// One byte typed over: the whole hex is rebuilt from the grid, as on Android.
    private func editByte(_ index: Int, _ typed: String, _ bytes: [String]) {
        if index < 0 || index >= bytes.count { return }
        var updated: [String] = bytes
        updated[index] = typed
        onHexChange(LabPacketTools.fromBytes(updated))
    }
}

/// One byte of the inspector grid: two hex digits, uppercased, anything else dropped. Every
/// accepted keystroke is written back straight away.
private struct LabByteCell: View {
    let value: String
    let onEdit: (String) -> Void

    @State private var text: String

    init(value: String, onEdit: @escaping (String) -> Void) {
        self.value = value
        self.onEdit = onEdit
        self._text = State(initialValue: value)
    }

    var body: some View {
        TextField("", text: $text)
            .font(MMTheme.techLabel(12))
            .foregroundStyle(MMTheme.cyanDim)
            .multilineTextAlignment(.center)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(MMTheme.panel)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(MMTheme.panelLine, lineWidth: 0.5))
            .onChange(of: value) { _, newValue in
                if newValue != text {
                    text = newValue
                }
            }
            .onChange(of: text) { _, typed in
                textChanged(typed)
            }
    }

    private func textChanged(_ typed: String) {
        let cleaned: String = LabByteCell.clean(typed)
        if cleaned != typed {
            // Showing the cleaned text runs this again with it.
            text = cleaned
            return
        }
        if cleaned != value {
            onEdit(cleaned)
        }
    }

    private static func clean(_ typed: String) -> String {
        let digits: String = typed.uppercased().filter { (c: Character) -> Bool in
            "0123456789ABCDEF".contains(c)
        }
        return String(digits.prefix(2))
    }
}

// MARK: - Random light show

/// A surprise packet on a loop until stopped (Android `RandomLightShowSection`). The show runs in
/// `TxEngine`, so it keeps playing across tab switches while the app is open.
private struct LabRandomShowSection: View {
    @EnvironmentObject var tx: TxEngine

    @State private var intervalMs: Double = 3000
    @State private var primed: Bool = false

    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MMSectionTitle("RANDOM LIGHT SHOW")
            Text("Shoots a surprise packet — colors, duals, fades, rainbows, effects — on a loop until stopped.")
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            SettingSlider(
                title: "INTERVAL",
                value: $intervalMs,
                range: 500...30000,
                step: 250,
                unit: "ms",
                hint: "Pause between packets (each packet also plays for the command burst time).",
                onCommit: { ms in intervalCommitted(ms) }
            )
            controlRow
        }
        .onAppear {
            if !primed {
                intervalMs = Double(tx.randomShowIntervalMs)
                primed = true
            }
        }
    }

    private var controlRow: some View {
        HStack(spacing: 8) {
            Button {
                tx.setRandomShow(enabled: !tx.randomShowEnabled, intervalMs: LabRandomShowSection.milliseconds(intervalMs))
            } label: {
                Text(tx.randomShowEnabled ? "STOP SHOW" : "START SHOW")
                    .font(MMTheme.techLabel())
            }
            .buttonStyle(.borderedProminent)
            .tint(MMTheme.cyan)
            if tx.randomShowEnabled {
                Text(showLabelText)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.cyan)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var showLabelText: String {
        let current: String = tx.randomShowLabel
        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Rolling the dice…".uppercased()
        }
        return current.uppercased()
    }

    /// A new pace applies to a running show at once; otherwise it is kept for START.
    private func intervalCommitted(_ ms: Double) {
        intervalMs = ms
        if tx.randomShowEnabled {
            tx.setRandomShow(enabled: true, intervalMs: LabRandomShowSection.milliseconds(ms))
        }
    }

    private static func milliseconds(_ value: Double) -> Int {
        if !value.isFinite { return 3000 }
        let bounded: Double = min(max(value, 0), 3_600_000)
        return Int(bounded)
    }
}

// MARK: - My presets row

/// One user preset: tap to load it into the Lab, the star for the Apple Watch, the bin to delete it.
private struct LabPresetRow: View {
    let preset: MagicPacket
    let starred: Bool
    let onLoad: () -> Void
    let onStar: () -> Void
    let onDelete: () -> Void

    init(preset: MagicPacket, starred: Bool, onLoad: @escaping () -> Void, onStar: @escaping () -> Void,
         onDelete: @escaping () -> Void) {
        self.preset = preset
        self.starred = starred
        self.onLoad = onLoad
        self.onStar = onStar
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: onLoad) {
                    presetText
                }
                .buttonStyle(.plain)
                FavoriteStarButton(on: starred, action: onStar)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(MMTheme.textDim)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete preset")
            }
            LabScreenDivider()
        }
    }

    private var presetText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(preset.label.uppercased())
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textPrimary)
                .lineLimit(1)
            Text(preset.hex)
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.cyanDim)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - MBLE tap

/// Lightning Lane tap token, advertised by an Android relay (`mble_tap`). The token must carry at
/// least two bytes, as Android's `MbleBeaconBuilder` requires; the beacon payload it makes is
/// shown before sending.
private struct LabMbleSection: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var token: String = ""

    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MMSectionTitle("MBLE TAP (LIGHTNING LANE)")
                .padding(.top, 8)
            TextField("VMMS token hex", text: $token)
                .labScreenField(MMTheme.textPrimary)
                .textInputAutocapitalization(.never)
            payloadLine
            MMCompactButton(
                title: "MBLE ADV",
                enabled: vm.remoteLinkReady && payload != nil,
                action: { vm.mbleTapAndroid(tokenHex: token) }
            )
        }
    }

    private var payload: [UInt8]? {
        MbleBeaconBuilder.manufacturerPayload(token)
    }

    @ViewBuilder
    private var payloadLine: some View {
        if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let bytes = payload {
                Text("PAYLOAD " + HexUtils.bytesToHex(bytes))
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.cyanDim)
                    .lineLimit(2)
            } else {
                Text("MBLE token too short")
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.error)
            }
        }
    }
}

// MARK: - Hawkeye themes

/// The Hawkeye Light Up colour themes (MDE `mapIdentifier` + CMS swatches) as on-air presets.
/// Tap sends through the relay; hold loads the packet into the Lab. Folded by default.
private struct LabThemesSection: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var tx: TxEngine
    @AppStorage("lab_themes_collapsed") private var collapsed: Bool = true

    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !collapsed {
                Text("TAP SENDS · HOLD LOADS IN LAB")
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.textDim)
                ForEach(MdeThemeCatalog.categories, id: \.id) { category in
                    LabThemeCategory(title: category.title, themes: category.themes)
                }
            }
        }
    }

    private var header: some View {
        Button {
            collapsed.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MMTheme.cyan)
                Text("HAWKEYE THEMES")
                    .font(MMTheme.techHeader())
                    .foregroundStyle(MMTheme.cyan)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }
}

private struct LabThemeCategory: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var tx: TxEngine
    let title: String
    let themes: [MdeHawkeyeTheme]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
            ForEach(themes) { theme in
                LabThemeRow(theme: theme)
            }
        }
    }
}

private struct LabThemeRow: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var tx: TxEngine
    let theme: MdeHawkeyeTheme

    var body: some View {
        let hex: String = theme.transmitHex
        HStack(spacing: 8) {
            swatches
            VStack(alignment: .leading, spacing: 2) {
                Text(theme.title.uppercased())
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textPrimary)
                Text(hex)
                    .font(MMTheme.techLabel(8))
                    .foregroundStyle(MMTheme.cyanDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(MMTheme.panel)
        .overlay(RoundedRectangle(cornerRadius: 0).stroke(MMTheme.panelLine, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture {
            tx.transmit(hex: hex, label: theme.title)
        }
        .onLongPressGesture(minimumDuration: 0.4) {
            vm.loadInLab(hex: hex, label: theme.title)
        }
    }

    private var swatches: some View {
        HStack(spacing: 3) {
            ForEach(Array(theme.colors.prefix(5).enumerated()), id: \.offset) { item in
                Circle()
                    .fill(labThemeSwatch(item.element))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(MMTheme.panelLine, lineWidth: 0.5))
            }
        }
    }
}

/// "#RRGGBB" to a colour; black when the text is not a colour.
private func labThemeSwatch(_ text: String) -> Color {
    let clean: String = text.replacingOccurrences(of: "#", with: "")
    let value: Int = Int(clean, radix: 16) ?? 0
    let red: Double = Double((value >> 16) & 0xFF) / 255.0
    let green: Double = Double((value >> 8) & 0xFF) / 255.0
    let blue: Double = Double(value & 0xFF) / 255.0
    return Color(red: red, green: green, blue: blue)
}

// MARK: - Small pieces

/// The hairline between Lab sections.
private struct LabScreenDivider: View {
    init() {}

    var body: some View {
        Rectangle()
            .fill(MMTheme.panelLine)
            .frame(height: 0.5)
            .frame(maxWidth: .infinity)
    }
}

private extension View {
    /// The look of a text field on the Lab screen.
    func labScreenField(_ color: Color) -> some View {
        self
            .font(MMTheme.techLabel())
            .foregroundStyle(color)
            .padding(8)
            .background(MMTheme.panel)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(MMTheme.panelLine, lineWidth: 0.5))
            .autocorrectionDisabled()
    }
}
