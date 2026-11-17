import SwiftUI
import UIKit
import UniformTypeIdentifiers

// The SCAN tab: what the iPhone's own scanner hears. Port of Android `ScanTab` with
// `BandConfigSection`, `LibraryFileSection`, `liveSubtitle` and `WideScreenColumns`.

// MARK: - File-local pieces

/// GROUPED lists one row per distinct packet under its section; RAW lists every advertisement.
private enum ScanFeedMode: String, CaseIterable, Identifiable {
    case grouped = "GROUPED"
    case raw = "RAW"

    var id: String { rawValue }
    var label: String { rawValue }
}

/// One section of the grouped feed.
private struct ScanFeedGroup: Identifiable {
    let section: LivePacketSection
    let packets: [LivePacket]

    var id: String { section.id }
}

/// What the screen remembers between visits, under the keys Android's `UiPrefs` uses.
private enum ScanUiPrefs {
    private static let collapsedSectionsKey = "scan_collapsed_sections"
    private static let bandMenuKey = "band_menu_collapsed"
    /// iPhone only. The dot keeps it out of the library file, which carries Android's keys.
    private static let controlsKey = "ios.scan_controls_collapsed"

    /// Stored as section names in Android's spelling ("WAND", "COLORS", ...).
    static func collapsedSections() -> Set<LivePacketSection> {
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

    static func bandMenuCollapsed() -> Bool {
        flag(bandMenuKey, fallback: true)
    }

    static func saveBandMenuCollapsed(_ collapsed: Bool) {
        UserDefaults.standard.set(collapsed, forKey: bandMenuKey)
    }

    static func controlsCollapsed() -> Bool {
        flag(controlsKey, fallback: false)
    }

    static func saveControlsCollapsed(_ collapsed: Bool) {
        UserDefaults.standard.set(collapsed, forKey: controlsKey)
    }

    private static func flag(_ key: String, fallback: Bool) -> Bool {
        let value: Any? = UserDefaults.standard.object(forKey: key)
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return text.lowercased() == "true" }
        return fallback
    }
}

/// The natural height of the controls block, so its panel is exactly as tall as it needs.
private struct ScanControlsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The exported library file handed to the share sheet. Every export is a new item, so a
/// sheet that closed itself without clearing the binding never blocks the next one.
private struct ScanShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system share sheet for one file. When sharing finishes or is cancelled the sheet closes
/// itself, which SwiftUI does not always report, so `onFinish` says so.
private struct ScanShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let items: [Any] = [url]
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let finish: () -> Void = onFinish
        controller.completionWithItemsHandler = { _, _, _, _ in
            finish()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private enum ScanChipKind {
    /// A plain button.
    case action
    /// A choice that is switched on.
    case on
    /// A choice that is switched off.
    case off
}

/// A compact outlined button, the size of the CLASS filter next to it.
private struct ScanChip: View {
    let title: String
    let systemImage: String?
    let kind: ScanChipKind
    let action: () -> Void

    init(
        title: String,
        systemImage: String? = nil,
        kind: ScanChipKind = .action,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            chipLabel
        }
        .buttonStyle(.plain)
    }

    private var chipLabel: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(title)
                .font(MMTheme.techLabel())
                .lineLimit(1)
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(fillColor))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(lineColor, lineWidth: 0.5))
        .contentShape(Rectangle())
        .fixedSize()
    }

    private var textColor: Color {
        switch kind {
        case .action, .on:
            return MMTheme.cyan
        case .off:
            return MMTheme.textDim
        }
    }

    private var fillColor: Color {
        switch kind {
        case .on:
            return MMTheme.cyan.opacity(0.18)
        case .action, .off:
            return Color.clear
        }
    }

    private var lineColor: Color {
        switch kind {
        case .on:
            return MMTheme.cyan
        case .action:
            return MMTheme.cyanDim
        case .off:
            return MMTheme.panelLine
        }
    }
}

// MARK: - Screen

struct ScanScreen: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var store: MagicStore
    @EnvironmentObject var scan: ScanEngine
    @EnvironmentObject var tx: TxEngine

    /// From this width the controls sit in a column beside the feed, as on an Android tablet.
    private static let wideLayoutMinWidth: CGFloat = 600
    private static let toastSeconds: Double = 2.5

    @State private var viewMode: ScanFeedMode = .grouped
    @State private var visibleSections: Set<LivePacketSection> = Set(LivePacketSection.allCases)
    @State private var collapsed: Set<LivePacketSection> = ScanUiPrefs.collapsedSections()
    @State private var bandMenuCollapsed: Bool = ScanUiPrefs.bandMenuCollapsed()
    @State private var controlsCollapsed: Bool = ScanUiPrefs.controlsCollapsed()
    @State private var controlsHeight: CGFloat = 0

    @State private var promoteTarget: LivePacket? = nil
    @State private var sheetInfo: PacketSheetInfo? = nil
    @State private var deleteRequest: DeleteRequest? = nil
    @State private var categoryRequest: CategoryPickRequest? = nil
    @State private var confirmDeleteBands: Bool = false
    @State private var importing: Bool = false
    @State private var shareFile: ScanShareFile? = nil
    /// Shown once the share sheet has gone; under the sheet nobody would see it.
    @State private var exportMessage: String = ""
    @State private var toastText: String = ""
    @State private var toastTick: Int = 0

    init() {}

    var body: some View {
        dialogHost
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [UTType.json, UTType.data],
                onCompletion: { result in
                    handleImport(result)
                }
            )
            .sheet(item: $shareFile, onDismiss: { exportSheetClosed() }) { file in
                ScanShareSheet(url: file.url, onFinish: { shareFinished() })
                    .presentationDetents([.medium, .large])
            }
    }

    private var dialogHost: some View {
        alertHost
            .packetActionSheet($sheetInfo)
            .confirmDelete($deleteRequest)
            .categoryPicker($categoryRequest)
    }

    private var alertHost: some View {
        screenLayout
            .alert("Packet action", isPresented: promotePresented, presenting: promoteTarget) { pkt in
                Button("ADD TO TX") {
                    addToTx(pkt)
                }
                Button("RECATEGORIZE") {
                    askRecategorize(hex: pkt.hex, label: pkt.label, afterAlert: true)
                }
                Button("CANCEL", role: .cancel) { }
            } message: { pkt in
                Text(pkt.label)
            }
            .alert("Delete saved band packets?", isPresented: $confirmDeleteBands) {
                Button("DELETE", role: .destructive) {
                    deleteSavedBands()
                }
                Button("CANCEL", role: .cancel) { }
            } message: {
                Text(deleteBandsMessage)
            }
    }

    private var promotePresented: Binding<Bool> {
        Binding(
            get: { promoteTarget != nil },
            set: { shown in
                if !shown { promoteTarget = nil }
            }
        )
    }

    // MARK: - Layout

    private var screenLayout: some View {
        GeometryReader { geo in
            layout(for: geo.size)
        }
        .background(MMTheme.navy)
        .overlay(alignment: .bottom) {
            toastView
        }
    }

    @ViewBuilder
    private func layout(for size: CGSize) -> some View {
        // The engines publish only a revision; reading it keeps the screen in step with them.
        let _ = scan.revision
        let _ = store.revision
        if size.width >= ScanScreen.wideLayoutMinWidth {
            wideLayout(size)
        } else {
            narrowLayout(size)
        }
    }

    private func narrowLayout(_ size: CGSize) -> some View {
        VStack(spacing: 0) {
            lastLightsStrip
            hairline
            controlsBar
            if !controlsCollapsed {
                controlsPanel(maxHeight: size.height * 0.6)
            }
            hairline
            feed
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func wideLayout(_ size: CGSize) -> some View {
        HStack(alignment: .top, spacing: 8) {
            wideControlsColumn
                .frame(width: size.width * 0.34)
            VStack(spacing: 0) {
                hairline
                feed
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var wideControlsColumn: some View {
        VStack(spacing: 0) {
            lastLightsStrip
            hairline
            ScrollView {
                controlsColumn
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(MMTheme.panelLine)
            .frame(height: 0.5)
    }

    // MARK: - Last lights strip

    /// The last heard packet that lights the band, as the band would show it. Pings, beacons
    /// and wand colours never get here: the engine only records light effects for it.
    @ViewBuilder
    private var lastLightsStrip: some View {
        let hex: String = scan.lastLightHex
        if hex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack {
                Text("LAST LIGHTS · NONE HEARD YET")
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textDim)
                Spacer(minLength: 0)
            }
            .frame(height: 40)
            .padding(.horizontal, 12)
            .background(MMTheme.navy)
        } else {
            BandPreviewView(hex: hex, compact: true, title: "LAST LIGHTS · #\(scan.lightsHeard)")
                .frame(height: 40)
        }
    }

    // MARK: - Controls

    /// A phone has little room above the feed, so the controls can be folded away.
    private var controlsBar: some View {
        Button {
            toggleControls()
        } label: {
            controlsBarLabel
        }
        .buttonStyle(.plain)
    }

    private var controlsBarLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: controlsCollapsed ? "chevron.down" : "chevron.up")
                .font(.system(size: 10, weight: .semibold))
            Text(controlsCollapsed ? "SCAN CONTROLS" : "HIDE SCAN CONTROLS")
                .font(MMTheme.techLabel(9))
            Spacer(minLength: 4)
            Text(controlsBarSummary)
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
                .lineLimit(1)
        }
        .foregroundStyle(MMTheme.cyan)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(MMTheme.panel)
        .contentShape(Rectangle())
    }

    private var controlsBarSummary: String {
        var parts: [String] = []
        parts.append(scan.scanActive ? "SCAN:ON" : "SCAN:OFF")
        if scan.recordSessionActive {
            parts.append("LOG:REC")
        }
        parts.append("RX:\(scan.packetsHeard)")
        return parts.joined(separator: " | ")
    }

    /// The controls at their natural height, scrolling inside the panel once they would take
    /// more than `maxHeight` (the band list can grow long).
    private func controlsPanel(maxHeight: CGFloat) -> some View {
        ScrollView {
            controlsColumn
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(controlsHeightReader)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: controlsFrameHeight(maxHeight))
        .onPreferenceChange(ScanControlsHeightKey.self) { [heightBinding = $controlsHeight] height in
            heightBinding.wrappedValue = height
        }
    }

    private var controlsHeightReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: ScanControlsHeightKey.self, value: proxy.size.height)
        }
    }

    private func controlsFrameHeight(_ maxHeight: CGFloat) -> CGFloat {
        let cap: CGFloat = max(maxHeight, 120)
        // Until the first measurement arrives the panel takes a typical height.
        if controlsHeight <= 0 {
            return min(cap, 260)
        }
        return min(controlsHeight, cap)
    }

    /// Android's order: status, the button row, the CLASS filter, My MagicBand, the library
    /// file, the buffer counter with CLR, the gesture hint.
    private var controlsColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusLines
            buttonRow
            SectionFilterMenu(visible: $visibleSections)
            bandSection
            libraryFileSection
            bufferRow
            hintLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusLines: some View {
        VStack(alignment: .leading, spacing: 2) {
            StatusLine(scanStatusText, color: scanStatusColor)
            // The file really open; ScanEngine's name can be an old sidecar after a relaunch.
            if let logName = store.activeSessionName {
                StatusLine("LOG · " + logName)
            }
            // A tap replays through the relay; this says why nothing went out when none is linked.
            StatusLine("STATUS: " + tx.status, color: txStatusColor)
        }
    }

    private var bluetoothReady: Bool {
        scan.bluetoothStatus == "Bluetooth ready"
    }

    /// Android says "Service running · lock screen OK" here. An iPhone hears these adverts only
    /// while the app is open: a background scan must name a service, and they carry none.
    private var scanStatusText: String {
        if !scan.scanActive {
            return "Tap SCAN to start"
        }
        if bluetoothReady {
            return "Scanning · keep app open"
        }
        return "Scan on · " + scan.bluetoothStatus
    }

    private var scanStatusColor: Color {
        if !scan.scanActive {
            return MMTheme.textDim
        }
        return bluetoothReady ? MMTheme.cyan : MMTheme.amber
    }

    private var txStatusColor: Color {
        if tx.status == TxEngine.notLinkedStatus || tx.status == TxEngine.sendFailedStatus {
            return MMTheme.amber
        }
        return MMTheme.textDim
    }

    /// One row, as on Android; it scrolls sideways where the row is wider than its column.
    private var buttonRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                scanChip
                logChip
                ForEach(ScanFeedMode.allCases) { mode in
                    ScanChip(title: mode.label, kind: viewMode == mode ? .on : .off) {
                        viewMode = mode
                    }
                }
                showControlChip
            }
        }
    }

    private var scanChip: some View {
        let active: Bool = scan.scanActive
        return ScanChip(
            title: active ? "PAUSE" : "SCAN",
            systemImage: active ? "pause.fill" : "play.fill"
        ) {
            scan.setScan(!active)
        }
    }

    private var logChip: some View {
        let recording: Bool = scan.recordSessionActive
        return ScanChip(title: recording ? "LOG:ON" : "LOG") {
            scan.setRecording(!recording)
        }
    }

    /// Keeps MagicBand and device noise out of the scan (on by default); off shows all raw.
    private var showControlChip: some View {
        let showControlOnly: Bool = scan.showControlOnly
        return ScanChip(
            title: showControlOnly ? "SHOW-CTRL" : "ALL RAW",
            kind: showControlOnly ? .on : .off
        ) {
            scan.showControlOnly = !showControlOnly
        }
    }

    private var bufferRow: some View {
        HStack(spacing: 6) {
            Text(bufferText)
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
                .lineLimit(1)
            Spacer(minLength: 4)
            textButton("CLR", color: MMTheme.amber) {
                scan.clearLive()
            }
        }
    }

    private var bufferText: String {
        if viewMode == .raw {
            return "BUF RAW \(scan.rawLivePackets.count)"
        }
        return "BUF UNIQUE \(scan.livePackets.count)"
    }

    private var hintLine: some View {
        Text("TAP REPLAY · HOLD MENU · SWIPE ← DEL · SWIPE → TX/TAG")
            .font(MMTheme.techLabel())
            .foregroundStyle(MMTheme.textDim)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func textButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(MMTheme.techLabel())
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - My MagicBand

    private var bandSection: some View {
        let addresses: [String] = store.bandAddressList()
        return VStack(alignment: .leading, spacing: 4) {
            bandHeader(count: addresses.count)
            if !bandMenuCollapsed {
                bandDetails(addresses)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MMTheme.cyan.opacity(0.06))
    }

    private func bandHeader(count: Int) -> some View {
        Button {
            toggleBandMenu()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: bandMenuCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MMTheme.textDim)
                    .frame(width: 12)
                Text("MY MAGICBAND")
                    .font(MMTheme.techHeader())
                    .foregroundStyle(MMTheme.cyan)
                Spacer(minLength: 4)
                Text(String(format: "%03d", count))
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textDim)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func bandDetails(_ addresses: [String]) -> some View {
        if addresses.isEmpty {
            Text("NONE SET — PICK FROM HEARD")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
        } else {
            ForEach(addresses, id: \.self) { address in
                taggedBandRow(address)
            }
        }
        savedBandsRow
        heardList
    }

    private func taggedBandRow(_ address: String) -> some View {
        HStack(spacing: 6) {
            Text(shortAddress(address))
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.cyan)
                .lineLimit(1)
            Spacer(minLength: 4)
            textButton("REMOVE", color: MMTheme.amber) {
                store.removeBandAddress(address)
            }
        }
    }

    private var savedBandsRow: some View {
        let saved: Int = store.savedBandCount()
        return HStack(spacing: 6) {
            Text("SAVED BAND PACKETS: \(saved)")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
                .lineLimit(1)
            Spacer(minLength: 4)
            if saved > 0 {
                textButton("DELETE ALL", color: MMTheme.error) {
                    confirmDeleteBands = true
                }
            }
        }
    }

    /// The sources heard most recently, to pick the band from.
    @ViewBuilder
    private var heardList: some View {
        let seen: [SeenAddress] = Array(scan.seenAddresses.prefix(8))
        if !seen.isEmpty {
            Text("HEARD (TAP TO TAG):")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
            ForEach(seen) { entry in
                heardRow(entry)
            }
        }
    }

    private func heardRow(_ entry: SeenAddress) -> some View {
        let tagged: Bool = store.isBandAddress(entry.address)
        let line: String = "\(shortAddress(entry.address))  \(entry.rssi)dBm ·\(entry.count)"
        return HStack(spacing: 6) {
            Text(line)
                .font(MMTheme.techLabel())
                .foregroundStyle(tagged ? MMTheme.cyan : MMTheme.textDim)
                .lineLimit(1)
            Spacer(minLength: 4)
            textButton(tagged ? "UNTAG" : "TAG", color: MMTheme.cyan) {
                if tagged {
                    store.removeBandAddress(entry.address)
                } else {
                    store.addBandAddress(entry.address)
                }
            }
        }
    }

    private var deleteBandsMessage: String {
        let saved: Int = store.savedBandCount()
        let what: String = "Removes all \(saved) guest-band telemetry packets from your library. "
        let rest: String = "Logs and other packets are untouched. This only runs when you tap Delete."
        return what + rest
    }

    // MARK: - Library file

    private var libraryFileSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LIBRARY FILE (FILES APP · EDITABLE)")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.cyan)
                .lineLimit(1)
            Text(libraryPathText)
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
                .lineLimit(2)
            HStack(spacing: 6) {
                ScanChip(title: "EXPORT") {
                    exportLibrary()
                }
                ScanChip(title: "IMPORT") {
                    importing = true
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MMTheme.cyan.opacity(0.06))
    }

    /// Where the Files app shows the exported file.
    private var libraryPathText: String {
        let name: String = URL(fileURLWithPath: store.libraryFilePath).lastPathComponent
        return "Files app → MagicMaker → " + name
    }

    // MARK: - Live feed

    @ViewBuilder
    private var feed: some View {
        if feedIsEmpty {
            Text("LISTEN 0x0183 MANUFACTURER")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewMode == .raw {
            rawList
        } else {
            groupedList
        }
    }

    /// Like Android, this looks at the whole buffer, not at what the CLASS filter leaves.
    private var feedIsEmpty: Bool {
        if viewMode == .raw {
            return scan.rawLivePackets.isEmpty
        }
        return scan.livePackets.isEmpty
    }

    private var rawPackets: [LivePacket] {
        let visible: Set<LivePacketSection> = visibleSections
        return scan.rawLivePackets.filter { (pkt: LivePacket) -> Bool in
            visible.contains(LivePacketSort.section(of: pkt))
        }
    }

    private var feedGroups: [ScanFeedGroup] {
        let grouped: [(LivePacketSection, [LivePacket])] = LivePacketSort.grouped(scan.livePackets)
        var out: [ScanFeedGroup] = []
        for entry in grouped where visibleSections.contains(entry.0) {
            out.append(ScanFeedGroup(section: entry.0, packets: entry.1))
        }
        return out
    }

    private var rawList: some View {
        List {
            ForEach(rawPackets) { pkt in
                feedRow(pkt, raw: true)
            }
        }
        .mmListStyle()
    }

    private var groupedList: some View {
        List {
            ForEach(feedGroups) { group in
                groupSection(group)
            }
        }
        .mmListStyle()
    }

    private func groupSection(_ group: ScanFeedGroup) -> some View {
        let isCollapsed: Bool = collapsed.contains(group.section)
        return Section {
            if !isCollapsed {
                // Keyed by the dedupe key, so a row keeps its identity (and a swipe or long
                // press in progress) each time its packet is heard again.
                ForEach(group.packets, id: \.dedupeKey) { pkt in
                    feedRow(pkt, raw: false)
                }
            }
        } header: {
            MMListSectionHeader(
                title: group.section.title,
                count: group.packets.count,
                collapsed: isCollapsed
            ) {
                toggleCollapsed(group.section)
            }
        }
    }

    private func feedRow(_ pkt: LivePacket, raw: Bool) -> some View {
        PacketRow(
            label: pkt.label,
            hex: pkt.hex,
            subtitle: liveSubtitle(pkt, includeNote: true),
            selected: pkt.isBand,
            onTap: {
                tx.transmit(hex: pkt.hex, label: pkt.label)
            },
            onLongPress: {
                openActions(pkt, raw: raw)
            }
        )
        .packetSwipeActions(
            onDelete: {
                askDelete(pkt, raw: raw)
            },
            onPromote: {
                promoteTarget = pkt
            }
        )
        .mmListRow()
    }

    /// Port of Android `liveSubtitle`, with the short source id where Android prints the MAC.
    private func liveSubtitle(_ pkt: LivePacket, includeNote: Bool) -> String {
        var text: String = "RSSI \(pkt.rssi)"
        if !pkt.address.isEmpty {
            text += " · " + shortAddress(pkt.address)
        }
        if pkt.isBand {
            text += " · BAND"
        }
        if includeNote && !pkt.note.isEmpty {
            text += " | " + pkt.note
        }
        return text
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastView: some View {
        if !toastText.isEmpty {
            Text(toastText)
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(MMTheme.panel))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(MMTheme.panelLine, lineWidth: 0.5))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .allowsHitTesting(false)
        }
    }

    /// A short message over the bottom of the screen, where Android shows a toast.
    private func showToast(_ text: String) {
        let tick: Int = toastTick + 1
        toastTick = tick
        toastText = text
        DispatchQueue.main.asyncAfter(deadline: .now() + ScanScreen.toastSeconds) {
            // A newer message keeps its own full time.
            if toastTick == tick {
                toastText = ""
            }
        }
    }

    // MARK: - Actions

    private func toggleControls() {
        let next: Bool = !controlsCollapsed
        controlsCollapsed = next
        ScanUiPrefs.saveControlsCollapsed(next)
    }

    private func toggleBandMenu() {
        let next: Bool = !bandMenuCollapsed
        bandMenuCollapsed = next
        ScanUiPrefs.saveBandMenuCollapsed(next)
    }

    private func toggleCollapsed(_ section: LivePacketSection) {
        var next: Set<LivePacketSection> = collapsed
        if next.contains(section) {
            next.remove(section)
        } else {
            next.insert(section)
        }
        collapsed = next
        ScanUiPrefs.saveCollapsedSections(next)
    }

    private func addToTx(_ pkt: LivePacket) {
        store.saveCustomPreset(label: pkt.label, hex: pkt.hex)
    }

    /// Opens the category picker. From the "Packet action" alert it waits for that alert to
    /// finish closing, because a dialog asked for while another closes may not appear.
    private func askRecategorize(hex: String, label: String, afterAlert: Bool) {
        let request = CategoryPickRequest(label: label) { category in
            recategorize(hex: hex, label: label, category: category)
        }
        if afterAlert {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                categoryRequest = request
            }
        } else {
            categoryRequest = request
        }
    }

    /// A heard packet has to be in the library before it can carry a category: it is saved as
    /// a TX preset first, then the library row with the same hex is recategorized.
    private func recategorize(hex: String, label: String, category: MagicCategory) {
        let canonical: String = HexUtils.canonicalHex(hex)
        let presetLabel: String = label.isEmpty ? category.rawValue : label
        store.saveCustomPreset(label: presetLabel, hex: hex)
        let library: [MagicPacket] = store.allTransmitPackets()
        let match: MagicPacket? = library.first(where: { (packet: MagicPacket) -> Bool in
            HexUtils.canonicalHex(packet.hex) == canonical
        })
        if let match {
            store.recategorizePacket(id: match.id, category: category)
        }
    }

    private func askDelete(_ pkt: LivePacket, raw: Bool) {
        deleteRequest = DeleteRequest(
            title: raw ? "Remove raw packet?" : "Remove from scan list?",
            label: pkt.label,
            hex: pkt.hex
        ) {
            if raw {
                scan.removeRawLive(timestampMs: pkt.timestampMs, hex: pkt.hex)
            } else {
                scan.removeLive(dedupeKey: pkt.dedupeKey)
            }
        }
    }

    private func openActions(_ pkt: LivePacket, raw: Bool) {
        let colors: String = MagicClassifier.classify(pkt.hex)?.colors ?? ""
        let actions: [PacketAction] = [
            PacketAction(title: "Transmit") {
                tx.transmit(hex: pkt.hex, label: pkt.label)
            },
            PacketAction(title: "Load in Lab") {
                vm.loadInLab(hex: pkt.hex, label: pkt.label)
            },
            PacketAction(title: "Add to TX library") {
                addToTx(pkt)
            },
            PacketAction(title: "Recategorize") {
                askRecategorize(hex: pkt.hex, label: pkt.label, afterAlert: false)
            },
            PacketAction(title: "Remove", destructive: true) {
                askDelete(pkt, raw: raw)
            },
        ]
        sheetInfo = PacketSheetInfo(
            title: pkt.label,
            hex: pkt.hex,
            colorsLine: colors,
            subtitle: "\(pkt.category.rawValue) · RSSI \(pkt.rssi)",
            actions: actions
        )
    }

    private func deleteSavedBands() {
        let removed: Int = store.deleteSavedBands()
        showToast("Deleted \(removed) band packets")
    }

    private func exportLibrary() {
        guard let url = store.exportLibrary() else {
            showToast("Export failed — library file not written")
            return
        }
        exportMessage = "Exported to " + libraryPathText
        shareFile = ScanShareFile(url: url)
    }

    /// Sharing finished or was cancelled; the activity view closes its sheet by itself.
    private func shareFinished() {
        shareFile = nil
        exportSheetClosed()
    }

    /// Runs once per export, whichever of the sheet's dismissal and `shareFinished` comes first.
    private func exportSheetClosed() {
        let text: String = exportMessage
        if text.isEmpty { return }
        exportMessage = ""
        showToast(text)
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            if store.importLibrary(from: url) {
                // The file brings its own interface settings.
                collapsed = ScanUiPrefs.collapsedSections()
                bandMenuCollapsed = ScanUiPrefs.bandMenuCollapsed()
                showToast("Library imported")
            } else {
                showToast("No file at path (or unreadable)")
            }
        case .failure:
            showToast("No file at path (or unreadable)")
        }
    }
}
