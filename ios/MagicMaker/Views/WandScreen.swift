import SwiftUI

// WAND tab: the Starlight wand with the learned colours, or the generated New Wand code list,
// the programmable quick button and the wand loop. Port of Android `WandTab`, `NewWandList`
// and the New Wand name helpers in `MagicMakerScreens.kt`.

/// New Wand codes share this signature; it keeps them out of the Starlight list.
private let wandNewWandSignature = "CF0B00C020224EAC7807866"

private func wandIsNewWandHex(_ hex: String) -> Bool {
    hex.uppercased().contains(wandNewWandSignature)
}

// MARK: - New Wand list

/// One New Wand code: its last 2 bytes on the left, its custom name or colour on the right.
private struct WandCodeRow: View {
    let key: String
    let name: String
    let selected: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void

    init(
        key: String,
        name: String,
        selected: Bool,
        onTap: @escaping () -> Void,
        onLongPress: @escaping () -> Void
    ) {
        self.key = key
        self.name = name
        self.selected = selected
        self.onTap = onTap
        self.onLongPress = onLongPress
    }

    var body: some View {
        rowBody
            .onTapGesture {
                onTap()
            }
            .onLongPressGesture(minimumDuration: 0.4) {
                onLongPress()
            }
    }

    private var rowBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(key)
                    .font(MMTheme.techHeader())
                    .foregroundStyle(selected ? MMTheme.cyan : MMTheme.cyanDim)
                Spacer(minLength: 8)
                Text(name)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(selected ? MMTheme.cyan : MMTheme.textDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.vertical, 8)
            Rectangle()
                .fill(MMTheme.panelLine)
                .frame(height: 0.5)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Android `NewWandList`: the scrollable New Wand codes, each keyed by its last 2 bytes. Tap
/// sends; a long press renames.
private struct WandCodeList: View {
    let packets: [MagicPacket]
    let selectedId: Int64
    let names: [String: String]
    let onSelect: (MagicPacket) -> Void
    let onLongPress: (MagicPacket) -> Void

    init(
        packets: [MagicPacket],
        selectedId: Int64,
        names: [String: String],
        onSelect: @escaping (MagicPacket) -> Void,
        onLongPress: @escaping (MagicPacket) -> Void
    ) {
        self.packets = packets
        self.selectedId = selectedId
        self.names = names
        self.onSelect = onSelect
        self.onLongPress = onLongPress
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("NEW WAND · \(packets.count) CODES · TAP SENDS · HOLD RENAMES")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle()
                .fill(MMTheme.panelLine)
                .frame(height: 0.5)
            codeScroller
        }
    }

    private var codeScroller: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(packets) { packet in
                    codeRow(packet)
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private func codeRow(_ packet: MagicPacket) -> some View {
        WandCodeRow(
            key: WandCodeList.key(packet.hex),
            name: displayName(packet),
            selected: packet.id == selectedId,
            onTap: { onSelect(packet) },
            onLongPress: { onLongPress(packet) }
        )
    }

    /// The last 4 hex digits (2 bytes), e.g. 6E80.
    static func key(_ hex: String) -> String {
        String(hex.uppercased().suffix(4))
    }

    /// The custom name, or the code's palette colour.
    private func displayName(_ packet: MagicPacket) -> String {
        let custom: String? = names[packet.hex.uppercased()]
        if let custom {
            return custom.uppercased()
        }
        return packet.colors.uppercased()
    }
}

// MARK: - Screen

struct WandScreen: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var store: MagicStore
    @EnvironmentObject var tx: TxEngine

    /// Two separate wand libraries: the learned Starlight colours and the generated New Wand
    /// codes. The toggle picks which one drives the list and the loop.
    @State private var showNewWand: Bool = false
    /// The list on screen: Starlight colours (one per colour) or the New Wand codes.
    @State private var library: [MagicPacket] = []
    @State private var loaded: Bool = false
    @State private var selectedId: Int64 = -1
    @State private var intervalSec: Float = 3
    @State private var burstMs: Double = Double(TransmitTiming.starlightBurstMs)
    @State private var deleteRequest: DeleteRequest? = nil
    @State private var renameTarget: MagicPacket? = nil
    @State private var renameText: String = ""
    @State private var editQuick: Bool = false
    @State private var quickLabelDraft: String = ""
    @State private var quickHexDraft: String = ""

    init() {}

    var body: some View {
        screen
            .confirmDelete($deleteRequest)
    }

    private var screen: some View {
        VStack(spacing: 0) {
            libraryArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle()
                .fill(MMTheme.panelLine)
                .frame(height: 0.5)
            controlsPanel
        }
        .background(MMTheme.navy)
        .onAppear {
            screenAppeared()
        }
        .onChange(of: store.revision) { _, _ in
            reloadLibrary(resetToLoop: false)
            burstMs = Double(store.getStarlightBurstMs())
        }
        .onChange(of: showNewWand) { _, _ in
            reloadLibrary(resetToLoop: false)
        }
        .onChange(of: tx.starlightLoopPacketId) { _, _ in
            reconcileSelection(resetToLoop: true)
        }
        .onChange(of: tx.starlightIntervalMs) { _, newMs in
            intervalSec = TxLoopInterval.seconds(fromMilliseconds: newMs)
        }
    }

    // MARK: Library area

    @ViewBuilder
    private var libraryArea: some View {
        if showNewWand {
            // New Wand is a long code range: a scrollable list keyed by the last 2 bytes is far
            // more usable than the Starlight wand image.
            newWandList
        } else {
            StarlightWandView(
                packets: library,
                displayColorIndex: vm.wandDisplayColorIndex,
                onDelete: { packet in askDeleteColor(packet) },
                onTransmit: { packet in transmitColor(packet) }
            )
        }
    }

    private var newWandList: some View {
        WandCodeList(
            packets: library,
            selectedId: selectedId,
            names: vm.newWandNames,
            onSelect: { packet in transmitColor(packet) },
            onLongPress: { packet in beginRename(packet) }
        )
        .alert("RENAME CODE", isPresented: renamePresented, presenting: renameTarget) { target in
            TextField("Name", text: $renameText)
                .autocorrectionDisabled()
            Button("SAVE") {
                vm.setNewWandName(hex: target.hex, name: renameText)
            }
            Button("CANCEL", role: .cancel) { }
        } message: { target in
            Text(target.hex.uppercased())
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { shown in
                if !shown { renameTarget = nil }
            }
        )
    }

    // MARK: Controls

    private var controlsPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            modeRow
            quickButton
            loopToggle
            TxIntervalSlider(
                seconds: intervalSec,
                label: { sec in intervalText(sec) },
                onCommit: { sec in commitInterval(sec) }
            )
            burstSlider
            libraryRow
            StatusLine(tx.status, color: txStatusLineColor(tx.status))
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("QUICK BUTTON", isPresented: $editQuick) {
            TextField("Label", text: $quickLabelDraft)
            TextField("Hex (8301...)", text: $quickHexDraft)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
            Button("SAVE") {
                vm.setWandQuick(label: quickLabelDraft, hex: quickHexDraft)
            }
            Button("CANCEL", role: .cancel) { }
        }
    }

    private var modeRow: some View {
        HStack(spacing: 4) {
            modeButton("STARLIGHT", isNew: false)
            modeButton("NEW WAND", isNew: true)
        }
    }

    private func modeButton(_ title: String, isNew: Bool) -> some View {
        Button {
            showNewWand = isNew
        } label: {
            Text(title)
                .font(MMTheme.techLabel())
                .foregroundStyle(showNewWand == isNew ? MMTheme.cyan : MMTheme.textDim)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(MMTheme.panelLine, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Programmable quick button (the New Wand "Off" code until reprogrammed), shown in both
    /// wand modes. Tap sends it; a long press reprograms its label and code.
    private var quickButton: some View {
        Text(vm.wandQuickLabel.uppercased())
            .font(MMTheme.techLabel())
            .foregroundStyle(MMTheme.textPrimary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(MMTheme.panelLine, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture {
                tx.transmit(hex: vm.wandQuickHex, label: vm.wandQuickLabel)
            }
            .onLongPressGesture(minimumDuration: 0.4) {
                beginEditQuick()
            }
            .accessibilityAddTraits(.isButton)
    }

    private var loopToggle: some View {
        Toggle(isOn: loopBinding) {
            Text("LOOP")
                .font(MMTheme.techHeader())
                .foregroundStyle(MMTheme.cyan)
        }
        .tint(MMTheme.cyan)
        .disabled(selectedId < 0)
    }

    private var loopBinding: Binding<Bool> {
        Binding(
            get: { tx.starlightLoopEnabled },
            set: { enabled in
                setLoop(enabled)
            }
        )
    }

    /// On-air time of a wand colour (Android's STARLIGHT WAND setting).
    private var burstSlider: some View {
        SettingSlider(
            title: "STARLIGHT WAND",
            value: $burstMs,
            range: Double(TransmitTiming.minStarlightBurstMs)...Double(TransmitTiming.maxStarlightBurstMs),
            step: 250,
            unit: "ms",
            hint: "On-air time for starlight wand TX · no band wakeup · default \(TransmitTiming.starlightBurstMs)ms",
            onCommit: { ms in
                store.saveStarlightBurstMs(Int(ms))
            }
        )
    }

    private var libraryRow: some View {
        HStack(spacing: 4) {
            Text("LIB \(library.count)")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
            Spacer(minLength: 4)
            // New Wand is a generated range: nothing to clear. Only Starlight is learned.
            if !showNewWand && !library.isEmpty {
                Button {
                    askClearLibrary()
                } label: {
                    Text("CLR LIB")
                        .font(MMTheme.techLabel())
                        .foregroundStyle(MMTheme.amber)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: 24)
    }

    // MARK: Labels

    private var selectedPacket: MagicPacket? {
        let wanted: Int64 = selectedId
        return library.first(where: { $0.id == wanted })
    }

    /// "3.0S | LABEL" for the selected colour, or "NO WAND LIBRARY".
    private func intervalText(_ seconds: Float) -> String {
        guard let packet = selectedPacket else { return "NO WAND LIBRARY" }
        return TxLoopInterval.text(seconds) + "S | " + packet.label.uppercased()
    }

    // MARK: Library state

    /// Each visit starts as Android's tab does: the loop's colour selected, the loop's interval.
    private func screenAppeared() {
        intervalSec = TxLoopInterval.seconds(fromMilliseconds: tx.starlightIntervalMs)
        burstMs = Double(store.getStarlightBurstMs())
        reloadLibrary(resetToLoop: true)
        loaded = true
    }

    /// Reads the list for the current mode. As on Android, a list of another length selects
    /// the loop's colour again (or the first one); otherwise the selection stays if it exists.
    private func reloadLibrary(resetToLoop: Bool) {
        let next: [MagicPacket]
        if showNewWand {
            next = store.newWandPackets()
        } else {
            next = WandScreen.starlightColors(store.learnedStarlightPackets())
        }
        let lengthChanged: Bool = next.count != library.count
        library = next
        reconcileSelection(resetToLoop: resetToLoop || lengthChanged || !loaded)
    }

    /// Starlight: no New Wand codes, and one entry per colour, so serial-only variations of
    /// the same colour do not fill the list.
    private static func starlightColors(_ learned: [MagicPacket]) -> [MagicPacket] {
        var seen = Set<Int>()
        var out: [MagicPacket] = []
        for packet in learned {
            if wandIsNewWandHex(packet.hex) { continue }
            let index: Int = MagicClassifier.starlightColorIndex(packet.hex) & 0x1F
            if seen.insert(index).inserted {
                out.append(packet)
            }
        }
        return out
    }

    private func reconcileSelection(resetToLoop: Bool) {
        var wanted: Int64 = selectedId
        if resetToLoop {
            let loopId: Int64 = tx.starlightLoopPacketId
            if loopId >= 0 {
                wanted = loopId
            } else {
                wanted = library.first?.id ?? -1
            }
        }
        let candidate: Int64 = wanted
        if candidate >= 0 && !library.contains(where: { $0.id == candidate }) {
            wanted = library.first?.id ?? -1
        }
        if selectedId != wanted {
            selectedId = wanted
        }
    }

    // MARK: Sending

    /// Sends a colour, or makes it the loop's colour while the loop runs (the loop sends it at
    /// once).
    private func transmitColor(_ packet: MagicPacket) {
        selectedId = packet.id
        if tx.starlightLoopEnabled {
            tx.setStarlightLoop(
                enabled: true,
                packetId: packet.id,
                intervalMs: TxLoopInterval.milliseconds(intervalSec)
            )
        } else {
            tx.transmit(hex: packet.hex, label: packet.label)
        }
    }

    private func setLoop(_ enabled: Bool) {
        let packetId: Int64 = selectedId
        if packetId < 0 { return }
        tx.setStarlightLoop(
            enabled: enabled,
            packetId: packetId,
            intervalMs: TxLoopInterval.milliseconds(intervalSec)
        )
    }

    private func commitInterval(_ seconds: Float) {
        intervalSec = seconds
        let packetId: Int64 = selectedId
        if tx.starlightLoopEnabled && packetId >= 0 {
            tx.setStarlightLoop(
                enabled: true,
                packetId: packetId,
                intervalMs: TxLoopInterval.milliseconds(seconds)
            )
        }
    }

    // MARK: Editing

    private func beginEditQuick() {
        quickLabelDraft = vm.wandQuickLabel
        quickHexDraft = vm.wandQuickHex
        editQuick = true
    }

    /// The field starts with the custom name, or else the code's colour.
    private func beginRename(_ packet: MagicPacket) {
        let custom: String? = vm.newWandNames[packet.hex.uppercased()]
        renameText = custom ?? packet.colors
        renameTarget = packet
    }

    private func askClearLibrary() {
        let count: Int = library.count
        deleteRequest = DeleteRequest(
            title: "Clear wand library?",
            label: "Remove all \(count) learned colors"
        ) {
            clearLibrary()
        }
    }

    private func clearLibrary() {
        store.clearLearnedStarlight()
        selectedId = -1
        if tx.starlightLoopEnabled {
            tx.setStarlightLoop(enabled: false, packetId: nil, intervalMs: nil)
        }
    }

    /// Every learned Starlight packet the list shows as this colour.
    private func colorGroup(_ packet: MagicPacket) -> [MagicPacket] {
        let index: Int = MagicClassifier.starlightColorIndex(packet.hex) & 0x1F
        var out: [MagicPacket] = []
        for learned in store.learnedStarlightPackets() {
            if wandIsNewWandHex(learned.hex) { continue }
            if (MagicClassifier.starlightColorIndex(learned.hex) & 0x1F) == index {
                out.append(learned)
            }
        }
        return out
    }

    private func askDeleteColor(_ packet: MagicPacket) {
        let group: [MagicPacket] = colorGroup(packet)
        let count: Int = max(group.count, 1)
        let label: String = count > 1 ? "\(packet.label) · \(count) learned codes" : packet.label
        deleteRequest = DeleteRequest(
            title: "Delete wand color?",
            label: label,
            hex: packet.hex
        ) {
            deleteColor(packet)
        }
    }

    /// Deletes the colour (every learned code the list shows as it). When the loop was sending
    /// one of them it moves on to the next learned colour, or stops when none is left, as
    /// Android's service does.
    private func deleteColor(_ packet: MagicPacket) {
        var ids: [Int64] = []
        for learned in colorGroup(packet) {
            ids.append(learned.id)
        }
        if !ids.contains(packet.id) {
            ids.append(packet.id)
        }
        for id in ids {
            store.deleteLearnedColor(id: id)
        }
        let loopId: Int64 = tx.starlightLoopPacketId
        if !tx.starlightLoopEnabled || !ids.contains(loopId) { return }
        if let next = store.learnedStarlightPackets().first {
            tx.setStarlightLoop(enabled: true, packetId: next.id, intervalMs: nil)
        } else {
            tx.setStarlightLoop(enabled: false, packetId: -1, intervalMs: nil)
        }
    }
}
