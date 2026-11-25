import SwiftUI

// TX tab: the transmit library (built-in presets and everything learned), its section filter
// and the TX loop. Port of Android `TransmitTab`, `TxSwipeRow` and `TxLoopSettingsSection`.

/// Android lays the tab out in two columns from this width up.
private let txWideLayoutMinWidth: CGFloat = 600

// MARK: - Loop interval

/// The loop interval of the TX and WAND tabs. Android's slider runs from 0.5 s to 30 s with 59
/// inner stops, which makes 61 positions about 0.49 s apart; the same positions are used here.
/// Seconds are `Float` and milliseconds are cut off, as on Android, so both apps store the same
/// interval for the same position.
enum TxLoopInterval {
    static let minSeconds: Float = 0.5
    static let maxSeconds: Float = 30
    /// Index of the last slider position; the first is 0.
    static let lastStop: Int = 60

    static func seconds(forStop stop: Int) -> Float {
        let clamped: Int = min(max(stop, 0), lastStop)
        let fraction: Float = Float(clamped) / Float(lastStop)
        return (1 - fraction) * minSeconds + fraction * maxSeconds
    }

    /// The slider position nearest to an interval.
    static func stop(forSeconds seconds: Float) -> Int {
        if !seconds.isFinite { return 0 }
        let span: Float = maxSeconds - minSeconds
        let position: Float = (seconds - minSeconds) / span * Float(lastStop)
        let nearest: Float = position.rounded()
        let bounded: Float = min(max(nearest, 0), Float(lastStop))
        return Int(bounded)
    }

    static func seconds(fromMilliseconds ms: Int) -> Float {
        Float(ms) / 1000
    }

    static func milliseconds(_ seconds: Float) -> Int {
        let ms: Float = seconds * 1000
        if !ms.isFinite { return 3000 }
        let bounded: Float = min(max(ms, 0), 3_600_000)
        return Int(bounded)
    }

    /// One decimal with halves rounding up, as Kotlin's `"%.1f".format` prints a Float
    /// (C's `%.1f` would print 15.25 as 15.2).
    static func text(_ seconds: Float) -> String {
        let value: Double = Double(seconds)
        if !value.isFinite { return "0.0" }
        let magnitude: Double = min(abs(value), 1_000_000)
        let tenths: Int = Int((magnitude * 10 + 0.5).rounded(.down))
        let whole: Int = tenths / 10
        let fraction: Int = tenths % 10
        let sign: String = (value < 0 && tenths > 0) ? "-" : ""
        return "\(sign)\(whole).\(fraction)"
    }
}

/// The loop interval slider of the TX and WAND tabs: Android `SettingSlider` with `steps`, one
/// line of text over a slider with the 61 positions of `TxLoopInterval` and no step buttons.
/// The text follows the thumb while it is dragged; `onCommit` gets the interval of the position
/// the user let go on. `seconds` is the interval in use and need not sit on a position.
///
///     TxIntervalSlider(seconds: intervalSec, label: { sec in TxLoopInterval.text(sec) + "S INTERVAL" }) { sec in
///         intervalSec = sec
///     }
struct TxIntervalSlider: View {
    let seconds: Float
    let label: (Float) -> String
    let onCommit: (Float) -> Void

    @State private var draftStop: Double = 0
    @State private var dragging: Bool = false

    init(
        seconds: Float,
        label: @escaping (Float) -> String,
        onCommit: @escaping (Float) -> Void
    ) {
        self.seconds = seconds
        self.label = label
        self.onCommit = onCommit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label(shownSeconds))
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            slider
        }
    }

    private var slider: some View {
        Slider(value: stopBinding, in: 0...TxIntervalSlider.lastStopValue, step: 1) { editing in
            editingChanged(editing)
        }
        .tint(MMTheme.cyan)
        .accessibilityValue(Text(TxLoopInterval.text(shownSeconds) + "S"))
    }

    private static let lastStopValue: Double = Double(TxLoopInterval.lastStop)

    /// While dragging, the interval under the thumb; at rest, the interval in use.
    private var shownSeconds: Float {
        if dragging {
            return TxLoopInterval.seconds(forStop: TxIntervalSlider.stopIndex(draftStop))
        }
        return seconds
    }

    private var stopBinding: Binding<Double> {
        Binding(
            get: { dragging ? draftStop : Double(TxLoopInterval.stop(forSeconds: seconds)) },
            set: { newValue in
                moved(newValue)
            }
        )
    }

    private func moved(_ newValue: Double) {
        draftStop = newValue
        // A change with no drag in progress (an accessibility adjustment) is complete as it is.
        if !dragging {
            commit(newValue)
        }
    }

    private func editingChanged(_ editing: Bool) {
        if editing {
            draftStop = Double(TxLoopInterval.stop(forSeconds: seconds))
            dragging = true
        } else if dragging {
            dragging = false
            commit(draftStop)
        }
    }

    private func commit(_ stop: Double) {
        let index: Int = TxIntervalSlider.stopIndex(stop)
        onCommit(TxLoopInterval.seconds(forStop: index))
    }

    private static func stopIndex(_ value: Double) -> Int {
        if !value.isFinite { return 0 }
        let last: Double = Double(TxLoopInterval.lastStop)
        let bounded: Double = min(max(value.rounded(), 0), last)
        return Int(bounded)
    }
}

/// Colour for a line that shows `tx.status`: amber when the last packet did not go out.
@MainActor
func txStatusLineColor(_ status: String) -> Color {
    if status == TxEngine.notLinkedStatus || status == TxEngine.sendFailedStatus {
        return MMTheme.amber
    }
    return MMTheme.textDim
}

// MARK: - Rows and saved state

/// One library row, prepared when the library is read so the list does not rebuild its ids
/// and subtitles on every refresh.
private struct TxRowItem: Identifiable {
    let id: String
    let packet: MagicPacket
    let subtitle: String

    init(packet: MagicPacket) {
        self.id = "\(packet.id)-\(packet.hex)"
        self.packet = packet
        // Android `TxSwipeRow`: "CATEGORY · colors", or the category alone.
        let category: String = packet.category.rawValue
        if packet.colors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.subtitle = category
        } else {
            self.subtitle = "\(category) · \(packet.colors)"
        }
    }
}

private struct TxSectionGroup: Identifiable {
    let section: LivePacketSection
    let rows: [TxRowItem]

    var id: String { section.id }
}

/// The library as the list shows it, with what the selection rules need.
private struct TxLibrarySnapshot {
    let groups: [TxSectionGroup]
    let ids: Set<Int64>
    /// Each packet's label by id (the first packet with that id, as Android's `firstOrNull`).
    let labels: [Int64: String]
    /// The first packet of `allTransmitPackets()`, or -1 for an empty library.
    let firstId: Int64

    static let empty = TxLibrarySnapshot(groups: [], ids: [], labels: [:], firstId: -1)

    /// The wanted packet when it is in the library, otherwise the first one (Android selects
    /// the first packet so LOOP can be used straight away).
    func validSelection(_ wanted: Int64) -> Int64 {
        if wanted >= 0 && ids.contains(wanted) {
            return wanted
        }
        return firstId
    }
}

/// Groups the library off the main thread: it can hold thousands of learned packets.
private func txBuildSnapshot(_ all: [MagicPacket]) -> TxLibrarySnapshot {
    let grouped: [(LivePacketSection, [MagicPacket])] = LivePacketSort.groupedMagicPackets(all)
    var groups: [TxSectionGroup] = []
    for entry in grouped {
        let packets: [MagicPacket] = entry.1
        if packets.isEmpty { continue }
        var rows: [TxRowItem] = []
        rows.reserveCapacity(packets.count)
        for packet in packets {
            rows.append(TxRowItem(packet: packet))
        }
        groups.append(TxSectionGroup(section: entry.0, rows: rows))
    }
    var ids = Set<Int64>()
    ids.reserveCapacity(all.count)
    var labels: [Int64: String] = [:]
    labels.reserveCapacity(all.count)
    for packet in all {
        if ids.insert(packet.id).inserted {
            labels[packet.id] = packet.label
        }
    }
    let firstId: Int64 = all.first?.id ?? -1
    return TxLibrarySnapshot(groups: groups, ids: ids, labels: labels, firstId: firstId)
}

/// What the tab remembers between launches, under the keys of Android's `UiPrefs`.
private enum TxScreenPrefs {
    static let collapsedSectionsKey = "tx_collapsed_sections"
    static let loopSettingsCollapsedKey = "tx_loop_settings_collapsed"

    /// Stored the way Android stores it: the section names ("WAND", "COLORS", ...).
    static func loadCollapsedSections() -> Set<LivePacketSection> {
        let names: [String] = UserDefaults.standard.stringArray(forKey: collapsedSectionsKey) ?? []
        var wanted = Set<String>()
        for name in names {
            wanted.insert(name.uppercased())
        }
        var out = Set<LivePacketSection>()
        for section in LivePacketSection.allCases where wanted.contains(section.title) {
            out.insert(section)
        }
        return out
    }

    static func saveCollapsedSections(_ sections: Set<LivePacketSection>) {
        var names: [String] = []
        for section in LivePacketSection.allCases where sections.contains(section) {
            names.append(section.title)
        }
        UserDefaults.standard.set(names, forKey: collapsedSectionsKey)
    }

    static func loadLoopSettingsCollapsed() -> Bool {
        let value: Any? = UserDefaults.standard.object(forKey: loopSettingsCollapsedKey)
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return text.lowercased() == "true" }
        return true
    }

    static func saveLoopSettingsCollapsed(_ collapsed: Bool) {
        UserDefaults.standard.set(collapsed, forKey: loopSettingsCollapsedKey)
    }
}

// MARK: - Screen

struct TxScreen: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var store: MagicStore
    @EnvironmentObject var tx: TxEngine

    /// The library grouped into sections; read again whenever the store's revision changes.
    @State private var library: TxLibrarySnapshot = TxLibrarySnapshot.empty
    @State private var loaded: Bool = false
    /// Bumped by every read of the library, so only the newest read is shown.
    @State private var readGeneration: Int = 0
    @State private var visibleSections: Set<LivePacketSection> = Set(LivePacketSection.allCases)
    @State private var collapsed: Set<LivePacketSection> = []
    @State private var loopSettingsCollapsed: Bool = true
    @State private var selectedTxId: Int64 = -1
    @State private var intervalSec: Float = 3
    @State private var sheetInfo: PacketSheetInfo? = nil
    @State private var deleteRequest: DeleteRequest? = nil
    @State private var categoryRequest: CategoryPickRequest? = nil
    @State private var renameRequest: RenameRequest? = nil
    /// Apple Watch favourites: the row stars follow every change.
    @ObservedObject private var favorites: WatchFavoritesStore = WatchFavoritesStore.shared
    @State private var favoritesFull: Bool = false

    init() {}

    var body: some View {
        screen
            .packetActionSheet($sheetInfo)
            .confirmDelete($deleteRequest)
            .categoryPicker($categoryRequest)
            .renamePrompt($renameRequest)
            .favoritesFullAlert($favoritesFull)
    }

    private var screen: some View {
        layout
            .background(MMTheme.navy)
            .onAppear {
                screenAppeared()
            }
            .onChange(of: store.revision) { _, _ in
                reloadLibrary()
            }
            .onChange(of: tx.txLoopPacketId) { _, newId in
                adoptLoopPacket(newId)
            }
            .onChange(of: tx.txLoopIntervalMs) { _, newMs in
                intervalSec = TxLoopInterval.seconds(fromMilliseconds: newMs)
            }
    }

    // MARK: Layout

    private var layout: some View {
        GeometryReader { geo in
            if geo.size.width >= txWideLayoutMinWidth {
                wideLayout(width: geo.size.width)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            } else {
                narrowLayout
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
        }
    }

    private var narrowLayout: some View {
        VStack(spacing: 0) {
            controls
            divider
            content
        }
    }

    /// Android `WideScreenColumns`: the controls in a third of the width, the library beside it.
    private func wideLayout(width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            controls
                .frame(width: width * 0.34, alignment: .topLeading)
            VStack(spacing: 0) {
                divider
                content
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(MMTheme.panelLine)
            .frame(height: 0.5)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 4) {
            buttonRow
            loopSection
            SectionFilterMenu(visible: $visibleSections)
            Text("TAP TX · HOLD MENU · SWIPE ← DEL · SWIPE → RECAT")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            // Android shows the service status in its notification; here the line says what
            // the relay did with the last send.
            StatusLine(tx.status, color: txStatusLineColor(tx.status))
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var buttonRow: some View {
        HStack(spacing: 4) {
            MMCompactButton(title: "VIBRATE") {
                tx.vibrate()
            }
            MMCompactButton(title: "INTERROGATE") {
                tx.transmit(hex: PacketBuilder.wakeupPing, label: "Interrogate")
            }
        }
    }

    /// Android `TxLoopSettingsSection`.
    private var loopSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            loopHeader
            if !loopSettingsCollapsed {
                loopToggle
                TxIntervalSlider(
                    seconds: intervalSec,
                    label: { sec in TxLoopInterval.text(sec) + "S INTERVAL" },
                    onCommit: { sec in commitInterval(sec) }
                )
            }
        }
    }

    private var loopHeader: some View {
        Button {
            toggleLoopSettings()
        } label: {
            loopHeaderLine
        }
        .buttonStyle(.plain)
    }

    private var loopHeaderLine: some View {
        HStack(spacing: 4) {
            Image(systemName: loopSettingsCollapsed ? "chevron.down" : "chevron.up")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(MMTheme.textPrimary)
                .frame(width: 16)
            Text(loopSettingsCollapsed ? "TX LOOP SETTINGS" : "HIDE TX LOOP")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let status = loopStatusLabel {
                Text(status)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var loopToggle: some View {
        Toggle(isOn: loopBinding) {
            Text("LOOP")
                .font(MMTheme.techHeader())
                .foregroundStyle(MMTheme.cyan)
        }
        .tint(MMTheme.cyan)
        .disabled(selectedTxId < 0)
    }

    private var loopBinding: Binding<Bool> {
        Binding(
            get: { tx.txLoopEnabled },
            set: { enabled in
                setLoop(enabled)
            }
        )
    }

    /// "ON · 3.0S · LABEL" while the loop runs (the label of the selected packet, which the
    /// loop repeats), nothing otherwise.
    private var loopStatusLabel: String? {
        if !tx.txLoopEnabled { return nil }
        let seconds: String = TxLoopInterval.text(intervalSec)
        if let selectedLabel = library.labels[selectedTxId] {
            return "ON · \(seconds)S · \(selectedLabel.uppercased())"
        }
        return "ON · \(seconds)S"
    }

    // MARK: Library list

    @ViewBuilder
    private var content: some View {
        if !loaded {
            Color.clear
        } else if library.groups.isEmpty {
            Text("NO TX LIBRARY — RUN RX SESSION")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            packetList
        }
    }

    private var visibleGroups: [TxSectionGroup] {
        library.groups.filter { visibleSections.contains($0.section) }
    }

    private var packetList: some View {
        List {
            ForEach(visibleGroups) { group in
                Section {
                    if !collapsed.contains(group.section) {
                        ForEach(group.rows) { row in
                            packetRow(row)
                        }
                    }
                } header: {
                    sectionHeader(group)
                }
            }
        }
        .mmListStyle()
    }

    private func sectionHeader(_ group: TxSectionGroup) -> some View {
        MMListSectionHeader(
            title: group.section.title,
            count: group.rows.count,
            collapsed: collapsed.contains(group.section)
        ) {
            toggleCollapsed(group.section)
        }
    }

    /// Android `TxSwipeRow`: tap sends, hold opens the menu, swipe left deletes, swipe right
    /// recategorizes.
    private func packetRow(_ row: TxRowItem) -> some View {
        PacketRow(
            label: row.packet.label,
            hex: row.packet.hex,
            subtitle: row.subtitle,
            selected: row.packet.id == selectedTxId,
            onTap: { selectPacket(row.packet) },
            onLongPress: { showActions(for: row.packet) },
            star: PacketRowStar(on: favorites.isStarred(hex: row.packet.hex)) {
                toggleStar(row.packet)
            }
        )
        .packetSwipeActions(
            onDelete: { askDelete(row.packet) },
            onPromote: { askRecategorize(row.packet) }
        )
        .mmListRow()
    }

    // MARK: Library state

    /// Each visit starts as Android's tab does: saved collapse states, the loop's packet
    /// selected, the loop's interval.
    private func screenAppeared() {
        collapsed = TxScreenPrefs.loadCollapsedSections()
        loopSettingsCollapsed = TxScreenPrefs.loadLoopSettingsCollapsed()
        intervalSec = TxLoopInterval.seconds(fromMilliseconds: tx.txLoopIntervalMs)
        selectedTxId = tx.txLoopPacketId
        reloadLibrary()
    }

    /// Reads the library again and keeps the selection on a packet that exists: the selected
    /// one, or else the first packet.
    private func reloadLibrary() {
        let all: [MagicPacket] = store.allTransmitPackets()
        readGeneration += 1
        let generation: Int = readGeneration
        Task { @MainActor in
            let snapshot: TxLibrarySnapshot = await Task.detached(priority: .userInitiated) { () -> TxLibrarySnapshot in
                txBuildSnapshot(all)
            }.value
            applyLibrary(snapshot, generation: generation)
        }
    }

    private func applyLibrary(_ snapshot: TxLibrarySnapshot, generation: Int) {
        // A newer read is on its way; this one is already out of date.
        if generation != readGeneration { return }
        library = snapshot
        loaded = true
        let valid: Int64 = snapshot.validSelection(selectedTxId)
        if selectedTxId != valid {
            selectedTxId = valid
        }
    }

    /// The loop's packet is the selected one, whoever set it.
    private func adoptLoopPacket(_ loopId: Int64) {
        if !loaded { return }
        let valid: Int64 = library.validSelection(loopId)
        if selectedTxId != valid {
            selectedTxId = valid
        }
    }

    private func toggleCollapsed(_ section: LivePacketSection) {
        var next: Set<LivePacketSection> = collapsed
        if next.contains(section) {
            next.remove(section)
        } else {
            next.insert(section)
        }
        collapsed = next
        TxScreenPrefs.saveCollapsedSections(next)
    }

    private func toggleLoopSettings() {
        let next: Bool = !loopSettingsCollapsed
        loopSettingsCollapsed = next
        TxScreenPrefs.saveLoopSettingsCollapsed(next)
    }

    // MARK: Sending

    /// A tap sends the packet and, while the loop runs, makes it the loop's packet.
    private func selectPacket(_ packet: MagicPacket) {
        selectedTxId = packet.id
        tx.transmit(hex: packet.hex, label: packet.label)
        if tx.txLoopEnabled {
            tx.setTxLoop(
                enabled: true,
                packetId: packet.id,
                intervalMs: TxLoopInterval.milliseconds(intervalSec)
            )
        }
    }

    private func setLoop(_ enabled: Bool) {
        let packetId: Int64 = selectedTxId
        if packetId < 0 { return }
        tx.setTxLoop(
            enabled: enabled,
            packetId: packetId,
            intervalMs: TxLoopInterval.milliseconds(intervalSec)
        )
    }

    private func commitInterval(_ seconds: Float) {
        intervalSec = seconds
        let packetId: Int64 = selectedTxId
        if tx.txLoopEnabled && packetId >= 0 {
            tx.setTxLoop(
                enabled: true,
                packetId: packetId,
                intervalMs: TxLoopInterval.milliseconds(seconds)
            )
        }
    }

    // MARK: Row actions

    /// The row's watch star: adds the packet to the Apple Watch favourites, or removes it.
    private func toggleStar(_ packet: MagicPacket) {
        if !favorites.toggle(hex: packet.hex, label: packet.label, source: WatchFavorite.Source.library) {
            favoritesFull = true
        }
    }

    /// Android `PacketActionSheet` for a library packet.
    private func showActions(for packet: MagicPacket) {
        var colors: String = packet.colors
        if colors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            colors = MagicClassifier.classify(packet.hex)?.colors ?? ""
        }
        let actions: [PacketAction] = [
            PacketAction(title: "Transmit") { selectPacket(packet) },
            PacketAction(title: "Load in Lab") { vm.loadInLab(hex: packet.hex, label: packet.label) },
            PacketAction(title: "Rename") { askRename(packet) },
            PacketAction(title: "Recategorize") { askRecategorize(packet) },
            PacketAction(title: "Delete", destructive: true) { askDelete(packet) },
        ]
        sheetInfo = PacketSheetInfo(
            title: packet.label,
            hex: packet.hex,
            colorsLine: colors,
            subtitle: packet.category.rawValue,
            actions: actions
        )
    }

    private func askRename(_ packet: MagicPacket) {
        renameRequest = RenameRequest(initial: packet.label) { newLabel in
            store.renamePacket(id: packet.id, newLabel: newLabel)
        }
    }

    private func askRecategorize(_ packet: MagicPacket) {
        categoryRequest = CategoryPickRequest(label: packet.label) { category in
            store.recategorizePacket(id: packet.id, category: category)
        }
    }

    /// Built-in presets stay, as on Android: the store removes only saved presets and learned
    /// packets.
    private func askDelete(_ packet: MagicPacket) {
        deleteRequest = DeleteRequest(
            title: "Delete from TX library?",
            label: packet.label,
            hex: packet.hex
        ) {
            store.deletePacketById(packet.id)
        }
    }
}
