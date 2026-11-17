import SwiftUI

// LOGS tab: the capture logs on this iPhone, newest first. Open one to filter it by type, source
// and band, list its packets, ANALYZE it into distinct packets, add them to the library, name
// one, replay it through the relay, share the file or delete it. Port of Android `LogsTab` in
// `MagicMakerScreens.kt`; the grouping and counting live in `Core/LogAnalysis.swift`.

/// Packet rows listed for an open log; a capture can hold far more than a list should lay out.
private let logsPacketRowLimit: Int = 1000
private let logsToastSeconds: Double = 2.5

/// Time of day on a packet row.
private let logsTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()

// MARK: - File work off the main thread

/// One log file as the screen uses it.
private struct LogsOpenLog {
    let path: String
    let packets: [LoggedPacket]
    /// Distinct categories, sorted: the type chips.
    let categories: [String]
    /// Distinct source ids, first heard first: the source chips.
    let addresses: [String]
}

// The store's listLogs / readLog are tied to the main actor; these do the same file work from a
// background task, after the rows still queued for the session file have been written.

private func logsListFiles() -> [LogFile] {
    SessionLogFiles.flushPendingRows()
    return SessionLogFiles.listLogs()
}

private func logsReadFile(path: String) -> LogsOpenLog {
    SessionLogFiles.flushPendingRows()
    let packets: [LoggedPacket] = SessionLogFiles.readLog(path: path)
    return LogsOpenLog(
        path: path,
        packets: packets,
        categories: LogAnalysis.categories(packets),
        addresses: LogAnalysis.addresses(packets)
    )
}

// MARK: - Task keys

private struct LogsListKey: Hashable {
    let tick: Int
    let session: Int
}

private struct LogsReadKey: Hashable {
    let path: String?
    let tick: Int
}

private struct LogsSummaryKey: Hashable {
    let path: String?
    let generation: Int
    let categories: Set<String>
    let address: String
    let bandOnly: Bool
    let hideNoise: Bool
}

private struct LogsPacketItem: Identifiable {
    let id: Int
    let packet: LoggedPacket
}

// MARK: - Screen

struct LogsScreen: View {
    @EnvironmentObject var store: MagicStore
    @EnvironmentObject var tx: TxEngine

    @State private var logs: [LogFile] = []
    @State private var logsLoaded: Bool = false
    /// Android's refreshTick: REFRESH, NAME and ADD ALL re-list the logs and re-read the open one.
    @State private var refreshTick: Int = 0
    /// Bumped when recording starts or stops; re-lists the logs only.
    @State private var sessionTick: Int = 0
    @State private var selectedPath: String? = nil
    @State private var loadedLog: LogsOpenLog? = nil
    @State private var loadGeneration: Int = 0
    // Per-log filters: they start over whenever another log is opened.
    @State private var selectedCats: Set<String> = []
    @State private var selectedAddr: String = ""
    @State private var bandOnly: Bool = false
    @State private var analyzing: Bool = false
    /// Guest-band telemetry and pings are most of any park capture, so they start hidden.
    @State private var hideNoise: Bool = true
    @State private var summary: LogSummary? = nil
    @State private var summaryKey: LogsSummaryKey? = nil
    @State private var renameRequest: RenameRequest? = nil
    @State private var deleteRequest: DeleteRequest? = nil
    @State private var toastText: String = ""
    @State private var toastTick: Int = 0

    init() {}

    var body: some View {
        screenLayout
            .renamePrompt($renameRequest)
            .confirmDelete($deleteRequest)
            .background {
                LogsSessionWatcher(onChange: { sessionTick += 1 })
            }
            .task(id: LogsListKey(tick: refreshTick, session: sessionTick)) {
                await reloadLogs()
            }
            .task(id: LogsReadKey(path: selectedPath, tick: refreshTick)) {
                await readSelectedLog()
            }
            .task(id: currentSummaryKey) {
                await summarize()
            }
    }

    // MARK: Layout

    private var screenLayout: some View {
        VStack(spacing: 0) {
            headerRow
            statusRow
            replayBanner
            hairline
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MMTheme.navy)
        .overlay(alignment: .bottom) {
            toastView
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            MMSectionTitle("CAPTURE LOGS")
            Spacer(minLength: 8)
            Button {
                refreshTick += 1
            } label: {
                Text("REFRESH")
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.cyan)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    /// The send status Android shows in its telemetry line: why a tap or a replay sent nothing.
    private var statusRow: some View {
        StatusLine("STATUS: " + tx.status, color: statusColor)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
    }

    private var statusColor: Color {
        let status: String = tx.status
        if status == TxEngine.notLinkedStatus || status == TxEngine.sendFailedStatus {
            return MMTheme.amber
        }
        return MMTheme.textDim
    }

    @ViewBuilder
    private var replayBanner: some View {
        if tx.replayActive {
            HStack(spacing: 8) {
                Text(replayText)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.cyan)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                LogsOutlineButton(title: "STOP", color: MMTheme.amber, height: 28) {
                    tx.stopReplay()
                }
            }
            .padding(8)
            .background(MMTheme.cyan.opacity(0.12))
        }
    }

    private var replayText: String {
        "REPLAYING \(tx.replayProgress)/\(tx.replayTotal) · \(tx.replayLabel)"
    }

    private var hairline: some View {
        Rectangle()
            .fill(MMTheme.panelLine)
            .frame(height: 0.5)
    }

    @ViewBuilder
    private var mainContent: some View {
        if !logsLoaded {
            ProgressView()
                .tint(MMTheme.cyan)
        } else if logs.isEmpty {
            Text("NO LOGS YET — START A SCAN")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
                .multilineTextAlignment(.center)
                .padding(16)
        } else {
            logList
        }
    }

    private var logList: some View {
        List {
            ForEach(logs) { log in
                logRow(log)
                    .mmListRow()
                if selectedPath == log.path {
                    detailRows(log)
                }
            }
        }
        .mmListStyle()
    }

    private func logRow(_ log: LogFile) -> some View {
        let selected: Bool = selectedPath == log.path
        let active: Bool = isActiveLog(log)
        return Button {
            toggleSelection(log)
        } label: {
            LogsFileLabel(log: log, selected: selected, active: active)
        }
        .buttonStyle(.plain)
    }

    /// The log being written right now.
    private func isActiveLog(_ log: LogFile) -> Bool {
        guard let active = store.activeSessionName else { return false }
        return store.sessionActive && active == log.name
    }

    // MARK: Open log

    @ViewBuilder
    private func detailRows(_ log: LogFile) -> some View {
        if let open = openLog {
            filterRows(open)
        }
        replayRow(log)
            .mmListRow()
        analyzeButtonsRow
            .mmListRow()
        if openLog == nil || currentSummary == nil {
            loadingRow
        } else if analyzing {
            analyzeRows
        } else {
            packetRows
        }
    }

    @ViewBuilder
    private func filterRows(_ open: LogsOpenLog) -> some View {
        if !open.categories.isEmpty {
            typeFilterRow(open.categories)
                .mmListRow()
        }
        if !open.addresses.isEmpty {
            sourceFilterRow(Array(open.addresses.prefix(LogAnalysis.sourceChipLimit)))
                .mmListRow()
        }
        Toggle(isOn: $bandOnly) {
            logsCaption("BAND ONLY")
        }
        .tint(MMTheme.cyan)
        .padding(.leading, 8)
        .mmListRow()
    }

    private func typeFilterRow(_ categories: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            logsCaption("FILTER TYPES (NONE = ALL)")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(categories, id: \.self) { category in
                        LogsFilterChip(title: category, selected: selectedCats.contains(category)) {
                            toggleCategory(category)
                        }
                    }
                }
            }
        }
        .padding(.leading, 8)
        .padding(.top, 4)
    }

    /// Single choice: tapping a source shows only that one; tapping it again shows all.
    private func sourceFilterRow(_ addresses: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            logsCaption("FILTER SOURCE (TAP = ONLY THAT SOURCE)")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(addresses, id: \.self) { address in
                        LogsFilterChip(title: shortAddress(address), selected: selectedAddr == address) {
                            toggleSource(address)
                        }
                    }
                }
            }
        }
        .padding(.leading, 8)
    }

    private func replayRow(_ log: LogFile) -> some View {
        HStack(spacing: 6) {
            LogsOutlineButton(title: "REPLAY", color: MMTheme.textPrimary, enabled: !tx.replayActive, expand: true) {
                startReplay(log)
            }
            ShareLink(item: URL(fileURLWithPath: log.path)) {
                LogsOutlineLabel(title: "SHARE", color: MMTheme.cyan)
            }
            .buttonStyle(.borderless)
            LogsOutlineButton(title: "DELETE", color: MMTheme.error) {
                askDelete(log)
            }
        }
        .padding(.leading, 8)
    }

    private var analyzeButtonsRow: some View {
        HStack(spacing: 6) {
            LogsOutlineButton(title: analyzing ? "HIDE PACKETS" : "ANALYZE", color: MMTheme.textPrimary, expand: true) {
                analyzing.toggle()
            }
            LogsOutlineButton(title: "ADD ALL → LIB", color: MMTheme.cyan, enabled: upToDateSummary != nil, expand: true) {
                addAllToLibrary()
            }
        }
        .padding(.leading, 8)
        .padding(.bottom, 2)
    }

    private var loadingRow: some View {
        logsCaption("LOADING…")
            .padding(.leading, 8)
            .mmListRow()
    }

    // MARK: Analyze

    @ViewBuilder
    private var analyzeRows: some View {
        if let result = currentSummary {
            hideNoiseRow(result)
                .mmListRow()
            analyzeHintRow(result)
                .mmListRow()
            ForEach(Array(result.analyzed.prefix(LogAnalysis.analyzedRowLimit))) { row in
                LogsAnalyzedRow(
                    row: row,
                    onTransmit: { transmit(row) },
                    onName: { askName(row) }
                )
                .mmListRow()
            }
            if result.analyzed.count > LogAnalysis.analyzedRowLimit {
                analyzeMoreRow(result.analyzed.count)
                    .mmListRow()
            }
        }
    }

    private func hideNoiseRow(_ result: LogSummary) -> some View {
        Toggle(isOn: $hideNoise) {
            logsCaption("HIDE BANDS & PINGS (\(result.noiseCount) OF \(result.filtered.count))")
        }
        .tint(MMTheme.cyan)
        .padding(.leading, 8)
    }

    private func analyzeHintRow(_ result: LogSummary) -> some View {
        let allNoise: Bool = result.analyzed.isEmpty && result.noiseCount > 0
        let text: String = allNoise
            ? "EVERYTHING IN THIS FILTER IS BAND TELEMETRY OR PINGS — FLIP THE SWITCH TO SEE IT"
            : "\(result.analyzed.count) UNIQUE · TAP = TX · NAME = ADD"
        let color: Color = allNoise ? MMTheme.amber : MMTheme.textDim
        return logsCaption(text, color: color)
            .padding(.leading, 8)
    }

    private func analyzeMoreRow(_ total: Int) -> some View {
        let hidden: Int = total - LogAnalysis.analyzedRowLimit
        return logsCaption("…and \(hidden) more (showing top \(LogAnalysis.analyzedRowLimit))")
            .padding(.leading, 8)
    }

    // MARK: Packet rows

    /// The filtered rows in the order they were logged.
    @ViewBuilder
    private var packetRows: some View {
        if let result = currentSummary {
            logsCaption("\(result.filtered.count) PACKETS · TAP = TX")
                .padding(.leading, 8)
                .mmListRow()
            ForEach(packetItems(result)) { item in
                PacketRow(
                    label: packetLabel(item.packet),
                    hex: item.packet.hex,
                    subtitle: packetSubtitle(item.packet),
                    tag: item.packet.isBand ? "BAND" : nil,
                    onTap: { transmitLogged(item.packet) }
                )
                .padding(.leading, 8)
                .mmListRow()
            }
            if result.filtered.count > logsPacketRowLimit {
                packetMoreRow(result.filtered.count)
                    .mmListRow()
            }
        }
    }

    private func packetItems(_ result: LogSummary) -> [LogsPacketItem] {
        let shown: Int = min(result.filtered.count, logsPacketRowLimit)
        var items: [LogsPacketItem] = []
        items.reserveCapacity(shown)
        for index in 0..<shown {
            items.append(LogsPacketItem(id: index, packet: result.filtered[index]))
        }
        return items
    }

    private func packetMoreRow(_ total: Int) -> some View {
        let hidden: Int = total - logsPacketRowLimit
        return logsCaption("…and \(hidden) more (showing first \(logsPacketRowLimit))")
            .padding(.leading, 8)
    }

    private func packetLabel(_ packet: LoggedPacket) -> String {
        if packet.label.isEmpty { return MagicClassifier.rawLabel(packet.hex) }
        return packet.label
    }

    private func packetSubtitle(_ packet: LoggedPacket) -> String {
        let date = Date(timeIntervalSince1970: Double(packet.timestampMs) / 1000.0)
        var text: String = logsTimeFormatter.string(from: date) + " · RSSI \(packet.rssi)"
        if !packet.category.isEmpty {
            text += " · " + packet.category
        }
        if !packet.sourceAddress.isEmpty {
            text += " · " + shortAddress(packet.sourceAddress)
        }
        return text
    }

    private func logsCaption(_ text: String, color: Color = MMTheme.textDim) -> some View {
        Text(text)
            .font(MMTheme.techLabel())
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }

    // MARK: Toast

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
        DispatchQueue.main.asyncAfter(deadline: .now() + logsToastSeconds) {
            // A newer message keeps its own full time.
            if toastTick == tick {
                toastText = ""
            }
        }
    }

    // MARK: Derived state

    /// The selected log's rows, once they have been read.
    private var openLog: LogsOpenLog? {
        guard let loaded = loadedLog, loaded.path == selectedPath else { return nil }
        return loaded
    }

    /// What the open log shows: the newest result, possibly from the filters just before the
    /// latest change while that one is worked out.
    private var currentSummary: LogSummary? {
        if openLog == nil { return nil }
        return summary
    }

    /// The result for exactly the current filters, or nil while it is being worked out.
    private var upToDateSummary: LogSummary? {
        if openLog == nil { return nil }
        if summaryKey != currentSummaryKey { return nil }
        return summary
    }

    private var currentSummaryKey: LogsSummaryKey {
        LogsSummaryKey(
            path: loadedLog?.path,
            generation: loadGeneration,
            categories: selectedCats,
            address: selectedAddr,
            bandOnly: bandOnly,
            hideNoise: hideNoise
        )
    }

    // MARK: Loading

    @MainActor
    private func reloadLogs() async {
        let listed: [LogFile] = await Task.detached(priority: .userInitiated) { () -> [LogFile] in
            logsListFiles()
        }.value
        if Task.isCancelled { return }
        logs = listed
        logsLoaded = true
        // A log that is no longer there (deleted from Files) is no longer open.
        if let path = selectedPath, !listed.contains(where: { $0.path == path }) {
            selectedPath = nil
            resetFilters()
        }
    }

    @MainActor
    private func readSelectedLog() async {
        guard let path = selectedPath else {
            loadedLog = nil
            summary = nil
            summaryKey = nil
            return
        }
        if loadedLog?.path != path {
            // Another log: nothing of the previous one may show while this one is read.
            loadedLog = nil
            summary = nil
            summaryKey = nil
        }
        let loaded: LogsOpenLog = await Task.detached(priority: .userInitiated) { () -> LogsOpenLog in
            logsReadFile(path: path)
        }.value
        if Task.isCancelled || selectedPath != path { return }
        loadedLog = loaded
        loadGeneration += 1
    }

    @MainActor
    private func summarize() async {
        let key: LogsSummaryKey = currentSummaryKey
        guard let loaded = loadedLog, key.path == loaded.path else { return }
        let packets: [LoggedPacket] = loaded.packets
        let result: LogSummary = await Task.detached(priority: .userInitiated) { () -> LogSummary in
            LogAnalysis.summarize(
                packets,
                categories: key.categories,
                address: key.address,
                bandOnly: key.bandOnly,
                hideNoise: key.hideNoise
            )
        }.value
        if Task.isCancelled { return }
        summary = result
        summaryKey = key
    }

    // MARK: Actions

    private func toggleSelection(_ log: LogFile) {
        if selectedPath == log.path {
            selectedPath = nil
        } else {
            selectedPath = log.path
        }
        resetFilters()
    }

    private func resetFilters() {
        selectedCats = []
        selectedAddr = ""
        bandOnly = false
        analyzing = false
        hideNoise = true
    }

    private func toggleCategory(_ category: String) {
        if selectedCats.contains(category) {
            selectedCats.remove(category)
        } else {
            selectedCats.insert(category)
        }
    }

    private func toggleSource(_ address: String) {
        selectedAddr = selectedAddr == address ? "" : address
    }

    private func startReplay(_ log: LogFile) {
        tx.startReplay(path: log.path, categories: selectedCats, address: selectedAddr, bandOnly: bandOnly)
    }

    private func askDelete(_ log: LogFile) {
        deleteRequest = DeleteRequest(title: "Delete log?", label: log.name) {
            deleteLog(log)
        }
    }

    private func deleteLog(_ log: LogFile) {
        store.deleteLog(path: log.path)
        selectedPath = nil
        resetFilters()
        refreshTick += 1
        showToast("Log deleted")
    }

    private func addAllToLibrary() {
        guard let result = upToDateSummary else { return }
        var hexes: [String] = []
        hexes.reserveCapacity(result.analyzed.count)
        for row in result.analyzed {
            hexes.append(row.hex)
        }
        let added: Int = store.importHexesToLibrary(hexes)
        refreshTick += 1
        showToast("Added \(added) to library")
    }

    private func transmit(_ row: AnalyzedPacket) {
        tx.transmit(hex: row.hex, label: row.label)
    }

    private func transmitLogged(_ packet: LoggedPacket) {
        tx.transmit(hex: packet.hex, label: packetLabel(packet))
    }

    private func askName(_ row: AnalyzedPacket) {
        renameRequest = RenameRequest(initial: row.label) { newLabel in
            saveName(row, newLabel: newLabel)
        }
    }

    private func saveName(_ row: AnalyzedPacket, newLabel: String) {
        let blank: Bool = newLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let label: String = blank ? row.label : newLabel
        let error: String? = store.saveCustomPreset(label: label, hex: row.hex)
        refreshTick += 1
        showToast(error ?? "Added \"\(newLabel)\" to library")
    }
}

// MARK: - Pieces

/// One log in the list: its name (with REC while it is being written), then packets, size and
/// how long ago it last changed.
private struct LogsFileLabel: View {
    let log: LogFile
    let selected: Bool
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            nameLine
            Text(detailText)
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .background(selected ? MMTheme.cyan.opacity(0.12) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MMTheme.panelLine)
                .frame(height: 0.5)
        }
        .contentShape(Rectangle())
    }

    private var nameLine: some View {
        HStack(spacing: 6) {
            Text(log.name)
                .font(MMTheme.techLabel())
                .foregroundStyle(selected ? MMTheme.cyan : MMTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if active {
                Text("REC")
                    .font(MMTheme.techLabel(8))
                    .foregroundStyle(MMTheme.amber)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(MMTheme.amber, lineWidth: 0.5))
                    .fixedSize()
            }
        }
    }

    private var detailText: String {
        var text: String = "\(log.packetCount) PKTS · \(log.sizeBytes / 1024)KB"
        let ago: String = agoText(log.modifiedMs)
        if !ago.isEmpty {
            text += " · " + ago.uppercased() + " AGO"
        }
        return text
    }
}

/// One distinct packet of the analysis: tap the text to transmit it, NAME to save it.
private struct LogsAnalyzedRow: View {
    let row: AnalyzedPacket
    let onTransmit: () -> Void
    let onName: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onTransmit) {
                texts
            }
            .buttonStyle(.borderless)
            Button(action: onName) {
                Text("NAME")
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.cyan)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderless)
        }
        .padding(.leading, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MMTheme.panelLine)
                .frame(height: 0.5)
        }
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("×\(row.count) · \(row.label)".uppercased())
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textPrimary)
                .lineLimit(1)
            Text(row.hex)
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.cyanDim)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

/// A filter chip (Android `FilterChip`): a tick and cyan outline when selected.
private struct LogsFilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                }
                Text(title)
                    .font(MMTheme.techLabel())
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? MMTheme.cyan : MMTheme.textDim)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? MMTheme.cyan.opacity(0.18) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? MMTheme.cyan : MMTheme.panelLine, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}

/// Outlined label used by the log buttons (Android `OutlinedButton`, 30 dp high).
private struct LogsOutlineLabel: View {
    let title: String
    let color: Color
    var expand: Bool = false
    var height: CGFloat = 30

    var body: some View {
        let maxWidth: CGFloat? = expand ? CGFloat.infinity : nil
        return Text(title)
            .font(MMTheme.techLabel())
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(maxWidth: maxWidth)
            .frame(height: height)
            .overlay(RoundedRectangle(cornerRadius: height / 2).stroke(MMTheme.panelLine, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

private struct LogsOutlineButton: View {
    let title: String
    let color: Color
    var enabled: Bool = true
    var expand: Bool = false
    var height: CGFloat = 30
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LogsOutlineLabel(
                title: title,
                color: enabled ? color : MMTheme.textDim,
                expand: expand,
                height: height
            )
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
    }
}

/// Re-lists the logs when recording starts or stops, as Android keys its list on
/// `recordSessionActive`. A separate view, so the list does not redraw on every scan update.
private struct LogsSessionWatcher: View {
    @EnvironmentObject var scan: ScanEngine
    let onChange: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: scan.recordSessionActive) { _, _ in
                onChange()
            }
            .onChange(of: scan.activeSessionName) { _, _ in
                onChange()
            }
    }
}
