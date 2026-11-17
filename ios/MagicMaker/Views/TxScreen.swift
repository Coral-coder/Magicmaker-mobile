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

/// The interval slider of the TX loop and the wand loop. `seconds` is the interval in use (it
/// need not sit on a slider position); `onCommit` gets the interval of the position the user
/// let go on or stepped to.
///
///     TxLoopIntervalSlider(title: "INTERVAL", seconds: intervalSec) { sec in
///         intervalSec = sec
///     }
struct TxLoopIntervalSlider: View {
    let title: String
    let seconds: Float
    let showsValue: Bool
    let onCommit: (Float) -> Void

    init(
        title: String,
        seconds: Float,
        showsValue: Bool = true,
        onCommit: @escaping (Float) -> Void
    ) {
        self.title = title
        self.seconds = seconds
        self.showsValue = showsValue
        self.onCommit = onCommit
    }

    var body: some View {
        SettingSlider(
            title: title,
            value: stopBinding,
            range: 0...Double(TxLoopInterval.lastStop),
            step: 1
        )
        .valueText { stop in
            stopText(stop)
        }
    }

    /// The slider works in positions; the interval is derived from the position.
    private var stopBinding: Binding<Double> {
        Binding(
            get: { Double(TxLoopInterval.stop(forSeconds: seconds)) },
            set: { newStop in
                let index: Int = TxLoopIntervalSlider.stopIndex(newStop)
                onCommit(TxLoopInterval.seconds(forStop: index))
            }
        )
    }

    private static func stopIndex(_ value: Double) -> Int {
        if !value.isFinite { return 0 }
        let last: Double = Double(TxLoopInterval.lastStop)
        let bounded: Double = min(max(value.rounded(), 0), last)
        return Int(bounded)
    }

    private func stopText(_ stop: Double) -> String {
        if !showsValue { return "" }
        let index: Int = TxLoopIntervalSlider.stopIndex(stop)
        let current: Int = TxLoopInterval.stop(forSeconds: seconds)
        // At rest the interval in use is shown, which may lie between two positions.
        let shown: Float = (index == current) ? seconds : TxLoopInterval.seconds(forStop: index)
        return TxLoopInterval.text(shown) + "S"
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

/// What the tab remembers between launches, under Android's preference names.
private enum TxScreenPrefs {
    static let collapsedSectionsKey = "tx_collapsed_sections"
    static let loopSettingsCollapsedKey = "tx_loop_settings_collapsed"

    /// Stored the way Android stores it: the upper-case section names.
    static func loadCollapsedSections() -> Set<LivePacketSection> {
        let names: [String] = UserDefaults.standard.stringArray(forKey: collapsedSectionsKey) ?? []
        var out = Set<LivePacketSection>()
        for name in names {
            let wanted: String = name.uppercased()
            for section in LivePacketSection.allCases where section.title == wanted {
                out.insert(section)
            }
        }
        return out
    }

    static func saveCollapsedSections(_ sections: Set<LivePacketSection>) {
        let names: [String] = sections.map { $0.title }.sorted()
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
    @State private var groups: [TxSectionGroup] = []
    @State private var loaded: Bool = false
    @State private var visibleSections: Set<LivePacketSection> = Set(LivePacketSection.allCases)
    @State private var collapsed: Set<LivePacketSection> = []
    @State private var loopSettingsCollapsed: Bool = true
    @State private var selectedTxId: Int64 = -1
    @State private var intervalSec: Float = 3
    @State private var sheetInfo: PacketSheetInfo? = nil
    @State private var deleteRequest: DeleteRequest? = nil
    @State private var categoryRequest: CategoryPickRequest? = nil
    @State private var renameRequest: RenameRequest? = nil

    init() {}

    var body: some View {
        screen
            .packetActionSheet($sheetInfo)
            .confirmDelete($deleteRequest)
            .categoryPicker($categoryRequest)
            .renamePrompt($renameRequest)
    }

    private var screen: some View {
        layout
            .background(MMTheme.navy)
            .onAppear {
                firstLoad()
            }
            .onChange(of: store.revision) { _, _ in
                reloadLibrary(selecting: selectedTxId)
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
        VStack(alignment: .leading, spacing: 6) {
            buttonRow
            loopSection
            SectionFilterMenu(visible: $visibleSections)
            Text("TAP TX · HOLD MENU · SWIPE ← DEL · SWIPE → RECAT")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            StatusLine(tx.status, color: txStatusLineColor(tx.status))
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var buttonRow: some View {
        HStack(spacing: 6) {
            MMCompactButton(title: "VIBRATE") {
                tx.vibrate()
            }
            MMCompactButton(title: "INTERROGATE") {
                tx.transmit(hex: PacketBuilder.wakeupPing, label: "Interrogate")
            }
        }
    }

    private var loopSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            loopHeader
            if !loopSettingsCollapsed {
                loopToggle
                TxLoopIntervalSlider(title: "INTERVAL", seconds: intervalSec) { sec in
                    commitInterval(sec)
                }
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
                .frame(width: 12)
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
                .foregroundStyle(MMTheme.textPrimary)
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

    /// "ON · 3.0S · LABEL" while the loop runs; nothing otherwise.
    private var loopStatusLabel: String? {
        if !tx.txLoopEnabled { return nil }
        let seconds: String = TxLoopInterval.text(intervalSec)
        let wanted: Int64 = selectedTxId
        if let packet = store.allTransmitPackets().first(where: { $0.id == wanted }) {
            return "ON · \(seconds)S · \(packet.label.uppercased())"
        }
        return "ON · \(seconds)S"
    }

    // MARK: Library list

    @ViewBuilder
    private var content: some View {
        if !loaded {
            Color.clear
        } else if groups.isEmpty {
            Text("NO TX LIBRARY — RUN RX SESSION")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            packetList
        }
    }

    private var visibleGroups: [TxSectionGroup] {
        groups.filter { visibleSections.contains($0.section) }
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

    private func packetRow(_ row: TxRowItem) -> some View {
        PacketRow(
            label: row.packet.label,
            hex: row.packet.hex,
            subtitle: row.subtitle,
            selected: row.packet.id == selectedTxId,
            onTap: { selectPacket(row.packet) },
            onLongPress: { showActions(for: row.packet) }
        )
        .packetSwipeActions(
            onDelete: { askDelete(row.packet) },
            onPromote: { askRecategorize(row.packet) }
        )
        .mmListRow()
    }

    // MARK: Library state

    private func firstLoad() {
        collapsed = TxScreenPrefs.loadCollapsedSections()
        loopSettingsCollapsed = TxScreenPrefs.loadLoopSettingsCollapsed()
        intervalSec = TxLoopInterval.seconds(fromMilliseconds: tx.txLoopIntervalMs)
        reloadLibrary(selecting: tx.txLoopPacketId)
        loaded = true
    }

    /// Reads the library again and keeps the selection on a row that exists: the wanted one,
    /// or else the first packet, so LOOP can be used straight away.
    private func reloadLibrary(selecting wanted: Int64) {
        let all: [MagicPacket] = store.allTransmitPackets()
        let grouped: [(LivePacketSection, [MagicPacket])] = LivePacketSort.groupedMagicPackets(all)
        var built: [TxSectionGroup] = []
        for entry in grouped {
            let packets: [MagicPacket] = entry.1
            if packets.isEmpty { continue }
            var rows: [TxRowItem] = []
            rows.reserveCapacity(packets.count)
            for packet in packets {
                rows.append(TxRowItem(packet: packet))
            }
            built.append(TxSectionGroup(section: entry.0, rows: rows))
        }
        groups = built
        let valid: Int64 = TxScreen.validSelection(wanted, in: all)
        if selectedTxId != valid {
            selectedTxId = valid
        }
    }

    private static func validSelection(_ wanted: Int64, in all: [MagicPacket]) -> Int64 {
        if wanted >= 0 && all.contains(where: { $0.id == wanted }) {
            return wanted
        }
        return all.first?.id ?? -1
    }

    /// The loop's packet is the selected one, whoever set it.
    private func adoptLoopPacket(_ loopId: Int64) {
        let valid: Int64 = TxScreen.validSelection(loopId, in: store.allTransmitPackets())
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

    /// A tap sends the packet and makes it the loop's packet.
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
        categoryRequest = CategoryPickRequest(label: packet.label, current: packet.category) { category in
            store.recategorizePacket(id: packet.id, category: category)
        }
    }

    /// Built-in presets stay: the store only removes saved presets and learned packets.
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
