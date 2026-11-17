import SwiftUI

// DIAG tab: the iPhone's own radio, scan and link state, the crash log, and every broadcaster
// heard with its packet count and signal. Port of Android `DiagnosticsTab` and `SourceRow` in
// `MagicMakerScreens.kt`; the status block stands in for Android's telemetry line.

/// Android shows the newest 4000 characters of the crash log.
private let diagCrashTailLength: Int = 4000

struct DiagScreen: View {
    @EnvironmentObject var scan: ScanEngine

    @State private var priorityCollapsed: Bool = false
    @State private var otherCollapsed: Bool = true
    @State private var crashCollapsed: Bool = true
    @State private var crashLog: String = ""
    @State private var deleteRequest: DeleteRequest? = nil

    init() {}

    var body: some View {
        sourceList
            .confirmDelete($deleteRequest)
            .onAppear {
                reloadCrashLog()
            }
    }

    /// Sorted by the engine: priority first, then packet count, then best signal.
    private var currentSources: [SourceStat] {
        _ = scan.revision
        return scan.sources
    }

    private var sourceList: some View {
        let sources: [SourceStat] = currentSources
        let priority: [SourceStat] = sources.filter { $0.priority }
        let other: [SourceStat] = sources.filter { !$0.priority }
        return List {
            topRows(sourceCount: sources.count)
            if sources.isEmpty {
                emptyRow
            } else {
                prioritySection(priority)
                otherSection(other)
            }
        }
        .mmListStyle()
    }

    @ViewBuilder
    private func topRows(sourceCount: Int) -> some View {
        DiagStatusBlock()
            .mmListRow()
        crashHeaderRow
            .mmListRow()
        if !crashCollapsed && !crashBlank {
            crashTextBox
                .mmListRow()
        }
        sourcesHeader(count: sourceCount)
            .mmListRow()
    }

    // MARK: Crash log

    /// Kotlin's `isBlank`.
    private var crashBlank: Bool {
        crashLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var crashHeaderRow: some View {
        HStack(spacing: 8) {
            Button {
                toggleCrashLog()
            } label: {
                Text(crashBlank ? "CRASH LOG · CLEAN" : "CRASH LOG · HAS ENTRIES")
                    .font(MMTheme.techLabel())
                    .foregroundStyle(crashBlank ? MMTheme.textDim : MMTheme.amber)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            if !crashBlank {
                crashActions
            }
        }
    }

    @ViewBuilder
    private var crashActions: some View {
        if let url = CrashLog.fileURL {
            ShareLink(item: url) {
                Text("SHARE")
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.cyan)
            }
            .buttonStyle(.borderless)
        }
        Button {
            askClearCrashLog()
        } label: {
            Text("CLEAR")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.amber)
        }
        .buttonStyle(.borderless)
    }

    private var crashTextBox: some View {
        let tail: String = String(crashLog.suffix(diagCrashTailLength))
        return ScrollView {
            Text(tail)
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(height: 220)
        .padding(.bottom, 4)
    }

    // MARK: Sources

    private func sourcesHeader(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            diagDivider
            Text("BROADCAST SOURCES · \(count)")
                .font(MMTheme.techHeader())
                .foregroundStyle(MMTheme.cyan)
            Text("PRIORITY = SENT SHOW/ANIM/COLOR")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
            diagDivider
        }
    }

    private var diagDivider: some View {
        Rectangle()
            .fill(MMTheme.panelLine)
            .frame(height: 0.5)
            .padding(.vertical, 2)
    }

    private var emptyRow: some View {
        Text("NO SOURCES — START A SCAN")
            .font(MMTheme.techLabel())
            .foregroundStyle(MMTheme.textDim)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 48)
            .mmListRow()
    }

    private func prioritySection(_ rows: [SourceStat]) -> some View {
        Section {
            if !priorityCollapsed {
                ForEach(rows) { source in
                    DiagSourceRow(source: source)
                        .mmListRow()
                }
            }
        } header: {
            MMListSectionHeader(title: "Priority", count: rows.count, collapsed: priorityCollapsed) {
                priorityCollapsed.toggle()
            }
        }
    }

    private func otherSection(_ rows: [SourceStat]) -> some View {
        Section {
            if !otherCollapsed {
                ForEach(rows) { source in
                    DiagSourceRow(source: source)
                        .mmListRow()
                }
            }
        } header: {
            MMListSectionHeader(title: "Other", count: rows.count, collapsed: otherCollapsed) {
                otherCollapsed.toggle()
            }
        }
    }

    // MARK: Actions

    private func reloadCrashLog() {
        crashLog = CrashLog.read()
    }

    /// Opening the log reads it again, so an entry written since the tab appeared shows up.
    private func toggleCrashLog() {
        if crashCollapsed {
            reloadCrashLog()
        }
        crashCollapsed.toggle()
    }

    private func askClearCrashLog() {
        deleteRequest = DeleteRequest(
            title: "Clear crash log?",
            label: CrashLog.fileName,
            confirmLabel: "CLEAR"
        ) {
            CrashLog.clear()
            reloadCrashLog()
        }
    }
}

// MARK: - Status block

/// The phone's own radio, scan, counters, relay link and location at a glance.
private struct DiagStatusBlock: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var store: MagicStore
    @EnvironmentObject var scan: ScanEngine
    @EnvironmentObject var tx: TxEngine

    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MMSectionTitle("STATUS")
            radioRows
            counterRows
            linkRows
        }
        .padding(.vertical, 4)
    }

    private var radioRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            DiagStatusRow(key: "BLUETOOTH", value: scan.bluetoothStatus.uppercased(), color: bluetoothColor)
            DiagStatusRow(key: "SCAN", value: scan.scanActive ? "ON" : "OFF", color: onOffColor(scan.scanActive))
            DiagStatusRow(key: "LOG", value: logText, color: onOffColor(scan.recordSessionActive))
            DiagLocationRow(location: vm.location)
        }
    }

    private var counterRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            DiagStatusRow(key: "RX", value: "\(scan.packetsHeard)", color: MMTheme.textPrimary)
            DiagStatusRow(key: "LIGHTS", value: "\(scan.lightsHeard)", color: MMTheme.textPrimary)
            DiagStatusRow(key: "AUTO", value: scan.autoEnabled ? "ARM" : "OFF", color: onOffColor(scan.autoEnabled))
            DiagStatusRow(key: "TX-AUTO", value: "\(scan.autoResponsesSent)", color: MMTheme.textPrimary)
        }
    }

    private var linkRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            DiagStatusRow(key: "RELAY", value: relayText, color: vm.remoteLinkReady ? MMTheme.cyan : MMTheme.amber)
            DiagStatusRow(key: "TX", value: tx.status.uppercased(), color: txColor)
        }
    }

    private var logText: String {
        if !scan.recordSessionActive { return "OFF" }
        // The file really open; ScanEngine's name can be an old sidecar after a relaunch.
        let name: String = store.activeSessionName ?? ""
        if name.isEmpty { return "REC" }
        return "REC · " + name
    }

    private var relayText: String {
        let backend: String = vm.relayBackend.label.uppercased()
        let state: String = vm.remoteLinkReady ? "LINKED" : "NOT LINKED"
        return backend + " · " + state
    }

    private var bluetoothColor: Color {
        scan.bluetoothStatus == "Bluetooth ready" ? MMTheme.textPrimary : MMTheme.amber
    }

    private var txColor: Color {
        let status: String = tx.status
        if status == TxEngine.notLinkedStatus || status == TxEngine.sendFailedStatus {
            return MMTheme.amber
        }
        return MMTheme.textPrimary
    }

    private func onOffColor(_ on: Bool) -> Color {
        on ? MMTheme.cyan : MMTheme.textDim
    }
}

/// The location permission; follows the tracker so a change in Settings shows at once.
private struct DiagLocationRow: View {
    @ObservedObject var location: LocationTracker

    init(location: LocationTracker) {
        self._location = ObservedObject(wrappedValue: location)
    }

    var body: some View {
        DiagStatusRow(
            key: "LOCATION",
            value: location.authorizationDescription.uppercased(),
            color: location.isAuthorized ? MMTheme.textPrimary : MMTheme.amber
        )
    }
}

/// One "KEY  value" line of the status block.
private struct DiagStatusRow: View {
    let key: String
    let value: String
    let color: Color

    init(key: String, value: String, color: Color) {
        self.key = key
        self.value = value
        self.color = color
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(key)
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(MMTheme.techLabel())
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Source row

/// Port of Android `SourceRow`: the source id (cyan when it sent show, animation or colour
/// packets), best and current signal, then the packet count and the categories heard.
private struct DiagSourceRow: View {
    let source: SourceStat

    init(source: SourceStat) {
        self.source = source
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(addressText)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(source.priority ? MMTheme.cyan : MMTheme.textDim)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("BEST \(source.bestRssi) · NOW \(source.lastRssi) dBm")
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textDim)
                    .lineLimit(1)
            }
            Text(countsText)
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MMTheme.panelLine)
                .frame(height: 0.5)
        }
    }

    /// The last 8 characters of the peripheral id stand in for Android's MAC.
    private var addressText: String {
        let tail: String = shortAddress(source.address)
        return tail.isEmpty ? "(unknown)" : tail
    }

    private var countsText: String {
        let categories: String = source.categories.joined(separator: " ")
        return "\(source.count) PKTS · \(categories)"
    }
}
