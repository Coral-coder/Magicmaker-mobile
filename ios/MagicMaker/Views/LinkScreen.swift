import SwiftUI

// The LINK tab: the relay this iPhone sends through (an Android phone over BLE or WiFi, or an
// ESP32), pairing, the link status, the Android library import, and the remote panel for an
// Android relay's own scanner. It has no Android twin; it is the iPhone side of Android's RELAY tab.

// MARK: - File-local pieces

/// GROUPED lists one row per distinct packet under its section; RAW lists every advertisement.
private enum LinkFeedMode: String, CaseIterable, Identifiable {
    case grouped = "GROUPED"
    case raw = "RAW"

    var id: String { rawValue }
    var label: String { rawValue }
}

/// One section of the relay's grouped feed.
private struct LinkFeedGroup: Identifiable {
    let section: LivePacketSection
    let packets: [AndroidRemotePacket]

    var id: String { section.id }
}

/// One row of the relay's raw feed. Two adverts with the same hex in the same millisecond share
/// a packet id, so a repeat gets a counter in its row id.
private struct LinkRawRow: Identifiable {
    let id: String
    let packet: AndroidRemotePacket
}

/// A key / value line of the status blocks.
private struct LinkInfoRow: View {
    let key: String
    let value: String
    let color: Color

    init(_ key: String, _ value: String, color: Color = MMTheme.textPrimary) {
        self.key = key
        self.value = value
        self.color = color
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
                .frame(width: 72, alignment: .leading)
            Text(value.uppercased())
                .font(MMTheme.techLabel(9))
                .foregroundStyle(color)
                .lineLimit(3)
        }
    }
}

private extension View {
    /// A block of controls as one `List` row: navy, padded, no separator.
    func linkPanelRow() -> some View {
        self
            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
            .listRowBackground(MMTheme.navy)
            .listRowSeparator(.hidden)
    }
}

// MARK: - Relay panel

/// Relay backend, pairing, link status, refresh / retry, and the Android library import.
private struct LinkRelayPanel: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var tx: TxEngine
    @Binding var showQRScanner: Bool

    /// What the last IMPORT ANDROID LIBRARY did; empty until it is tapped.
    @State private var importResult: String = ""

    init(showQRScanner: Binding<Bool>) {
        self._showQRScanner = showQRScanner
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MMSectionTitle("RELAY / LINK")
            linkState
            backendPicker
            backendDetail
            statusRows
            actionButtons
            importBlock
            noteText("Control Android from your pocket: BLE when close, WiFi hotspot + QR when Android is in your backpack.")
        }
    }

    private var linkState: some View {
        HStack {
            Circle()
                .fill(linkColor)
                .frame(width: 8, height: 8)
            Text(linkLabel)
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textPrimary)
        }
    }

    private var backendPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Backend")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
            Picker("Backend", selection: backendBinding) {
                ForEach(RelayBackend.allCases) { backend in
                    Text(backend.label).tag(backend)
                }
            }
            .pickerStyle(.segmented)
            .tint(MMTheme.cyan)
        }
    }

    private var backendBinding: Binding<RelayBackend> {
        Binding(
            get: { vm.relayBackend },
            set: { backend in vm.setRelayBackend(backend) }
        )
    }

    @ViewBuilder
    private var backendDetail: some View {
        switch vm.relayBackend {
        case .androidWifi:
            wifiPairing
        case .esp32:
            noteText("Power on the MagicMaker ESP32. iPhone auto-connects and transmits through it while you keep scanning. No pairing needed.")
        case .androidBle:
            noteText("Put Android in BLE GATT / iPhone mode. iPhone auto-connects to MagicMaker-Android.")
        }
    }

    private var wifiPairing: some View {
        VStack(alignment: .leading, spacing: 10) {
            MMPrimaryButton(title: "Scan Android QR", enabled: true) {
                showQRScanner = true
            }
            TextField("Android IP (hotspot gateway)", text: ipBinding)
                .font(MMTheme.techLabel())
                .padding(8)
                .background(MMTheme.panel)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(MMTheme.panelLine, lineWidth: 0.5))
                .keyboardType(.decimalPad)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }

    private var ipBinding: Binding<String> {
        Binding(
            get: { vm.androidRelayIP },
            set: { text in vm.saveAndroidRelayIP(text) }
        )
    }

    private var statusRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            LinkInfoRow("IPHONE", vm.relayStatus)
            if !vm.remoteLinkHint.isEmpty {
                LinkInfoRow("HINT", vm.remoteLinkHint, color: MMTheme.amber)
            }
            LinkInfoRow("STATUS", tx.status, color: txStatusLineColor(tx.status))
            LinkInfoRow("EVENT", vm.statusMessage)
            catalogRows
            androidRows
        }
    }

    @ViewBuilder
    private var catalogRows: some View {
        if vm.isCatalogSyncInFlight || !vm.catalogSyncDiagnostic.isEmpty {
            LinkInfoRow("LIB SYNC", vm.catalogSyncDiagnostic.uppercased())
        }
        if let cat = vm.androidCatalog, !cat.transmitPresets.isEmpty {
            LinkInfoRow("LIB", "\(cat.transmitPresets.count) TX · \(cat.wandColors.count) WAND")
        }
    }

    @ViewBuilder
    private var androidRows: some View {
        if let s = vm.androidRemote {
            LinkInfoRow("ANDROID", androidStatusText(s))
            LinkInfoRow("STORE", "REV \(s.storeRevision)")
            if s.relayLinked {
                LinkInfoRow("GATT", "LINKED")
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            MMCompactButton(title: "Refresh") {
                vm.refreshAndroidRemote()
                vm.refreshAndroidCatalog()
                vm.refreshRelayStatus()
            }
            if vm.relayBackend.usesBleRelayLink {
                MMCompactButton(title: "Retry BLE") {
                    vm.reconnectRelay()
                }
            }
        }
    }

    @ViewBuilder
    private var importBlock: some View {
        if catalogAvailable {
            VStack(alignment: .leading, spacing: 4) {
                MMPrimaryButton(title: "Import Android library") {
                    runImport()
                }
                Text(importCaption)
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(importResult.isEmpty ? MMTheme.textDim : MMTheme.cyan)
                    .lineLimit(2)
            }
        }
    }

    private func noteText(_ text: String) -> some View {
        Text(text)
            .font(MMTheme.techLabel(9))
            .foregroundStyle(MMTheme.textDim)
    }

    // MARK: Derived text

    private var linkColor: Color {
        switch vm.relayBackend {
        case .androidBle, .esp32:
            if vm.relayGattReady, vm.androidRemote?.relayLinked == true { return MMTheme.cyan }
            if vm.relayGattReady { return MMTheme.amber }
            return MMTheme.error
        case .androidWifi:
            return vm.remoteLinkReady ? MMTheme.cyan : MMTheme.amber
        }
    }

    private var linkLabel: String {
        switch vm.relayBackend {
        case .esp32:
            return vm.relayGattReady ? "ESP32 READY" : "ESP32 SEARCHING"
        case .androidBle:
            if vm.relayGattReady, vm.androidRemote?.relayLinked == true { return "GATT LINKED" }
            if vm.relayGattReady { return "GATT READY" }
            return "GATT SEARCHING"
        case .androidWifi:
            return vm.remoteLinkReady ? "WIFI LINKED" : "WIFI NOT CONNECTED"
        }
    }

    private func androidStatusText(_ s: AndroidRemoteStatus) -> String {
        if !s.status.isEmpty { return s.status.uppercased() }
        return s.running ? "RUNNING" : "STOPPED"
    }

    /// A synced (or cached) Android catalog with something in it.
    private var catalogAvailable: Bool {
        guard let cat = vm.androidCatalog else { return false }
        return !cat.transmitPresets.isEmpty || !cat.wandColors.isEmpty
    }

    private var importCaption: String {
        if !importResult.isEmpty { return importResult }
        return "ADDS THE ANDROID PACKETS THE IPHONE LIBRARY DOES NOT HAVE YET"
    }

    private func runImport() {
        let added: Int = vm.importAndroidLibrary()
        if added > 0 {
            importResult = "ADDED \(added) PACKETS TO THE IPHONE LIBRARY"
        } else {
            importResult = "ADDED 0 PACKETS · ALREADY IN THE IPHONE LIBRARY"
        }
    }
}

// MARK: - Screen

struct LinkScreen: View {
    @EnvironmentObject var vm: AppViewModel

    @State private var showQRScanner: Bool = false
    @State private var viewMode: LinkFeedMode = .grouped
    @State private var visibleSections: Set<LivePacketSection> = Set(LivePacketSection.allCases)
    @State private var collapsed: Set<LivePacketSection> = []
    @State private var promoteTarget: AndroidRemotePacket? = nil
    @State private var deleteRequest: DeleteRequest? = nil

    init() {}

    var body: some View {
        screenList
            .confirmDelete($deleteRequest)
            .alert("Packet action", isPresented: promotePresented, presenting: promoteTarget) { pkt in
                Button("Add to TX") {
                    addToTx(pkt)
                }
                Button("Load Lab") {
                    vm.loadInLab(hex: pkt.hex, label: pkt.label)
                }
                Button("Cancel", role: .cancel) { }
            } message: { pkt in
                Text(pkt.label.uppercased())
            }
            .sheet(isPresented: $showQRScanner) {
                qrScanner
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

    // One List for the whole screen, so the feed rows swipe and everything scrolls together.
    private var screenList: some View {
        List {
            Section {
                LinkRelayPanel(showQRScanner: $showQRScanner)
                    .linkPanelRow()
            }
            if showsRemotePanel {
                remoteSection
                feedSections
            }
        }
        .mmListStyle()
    }

    /// The ESP32 is only a radio: it has no scanner of its own to show or control.
    private var showsRemotePanel: Bool {
        vm.relayBackend != .esp32
    }

    // MARK: Android remote panel

    private var remoteSection: some View {
        Section {
            remoteControls
                .linkPanelRow()
            if let s = vm.androidRemote {
                remoteStats(s)
                    .linkPanelRow()
            }
            MMSectionTitle("LIVE RX")
                .linkPanelRow()
            if displayIsEmpty {
                Text("LISTEN 0x0183 MANUFACTURER")
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textDim)
                    .padding(.vertical, 12)
                    .linkPanelRow()
            }
        }
    }

    private var remoteControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            MMSectionTitle("ANDROID SCAN / RX")
            remoteButtons
            modeRow
            autoToggle
            Text("TAP REPLAY · SWIPE ← DEL · SWIPE → TX/TAG")
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MMTheme.panel)
        .overlay(Rectangle().stroke(MMTheme.panelLine, lineWidth: 0.5))
    }

    private var remoteButtons: some View {
        HStack(spacing: 6) {
            MMCompactButton(title: remoteScanOn ? "Pause" : "Scan", enabled: vm.remoteLinkReady) {
                vm.setAndroidScan(!remoteScanOn)
            }
            MMCompactButton(title: remoteLogOn ? "Log Off" : "Log", enabled: vm.remoteLinkReady) {
                vm.setAndroidRecording(!remoteLogOn)
            }
            MMCompactButton(title: "Clr", enabled: vm.remoteLinkReady) {
                vm.clearAndroidLive()
            }
            MMCompactButton(title: "Vib", enabled: vm.remoteLinkReady) {
                vm.vibrateAndroid()
            }
        }
    }

    private var modeRow: some View {
        HStack(spacing: 6) {
            ForEach(LinkFeedMode.allCases) { mode in
                modeButton(mode)
            }
            SectionFilterMenu(visible: $visibleSections)
        }
    }

    private func modeButton(_ mode: LinkFeedMode) -> some View {
        Button(mode.label) {
            viewMode = mode
        }
        .font(MMTheme.techLabel())
        .buttonStyle(.bordered)
        .tint(viewMode == mode ? MMTheme.cyan : MMTheme.textDim)
    }

    private var autoToggle: some View {
        Toggle(isOn: remoteAutoBinding) {
            Text("AUTO-RESPONSE")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textPrimary)
        }
        .tint(MMTheme.cyan)
        .disabled(!vm.remoteLinkReady)
    }

    private var remoteAutoBinding: Binding<Bool> {
        Binding(
            get: { vm.androidRemote?.autoEnabled ?? false },
            set: { on in vm.setAndroidAuto(on) }
        )
    }

    private func remoteStats(_ s: AndroidRemoteStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LinkInfoRow("BUF", bufferText)
            LinkInfoRow("HEARD", "\(s.packetsHeard) pkts")
            if !s.lastHeardHex.isEmpty {
                LinkInfoRow("LAST", lastHeardText(s))
            }
            if s.recordSessionActive && !s.activeSessionName.isEmpty {
                LinkInfoRow("LOG", s.activeSessionName)
            }
        }
        .padding(.horizontal, 4)
    }

    private var remoteScanOn: Bool {
        vm.androidRemote?.scanActive ?? false
    }

    private var remoteLogOn: Bool {
        vm.androidRemote?.recordSessionActive ?? false
    }

    private var bufferText: String {
        if viewMode == .raw {
            return "RAW \(vm.androidLivePackets.count)"
        }
        return "UNIQUE \(vm.androidUniqueLivePackets.count)"
    }

    private func lastHeardText(_ s: AndroidRemoteStatus) -> String {
        let head: String = String(s.lastHeardHex.prefix(24))
        return s.lastHeardLabel.uppercased() + " · " + head + "…"
    }

    // MARK: Relay feed

    @ViewBuilder
    private var feedSections: some View {
        if viewMode == .raw {
            Section {
                ForEach(rawRows) { row in
                    feedRow(row.packet, raw: true)
                }
            }
        } else {
            ForEach(feedGroups) { group in
                groupSection(group)
            }
        }
    }

    /// Empty after the CLASS filter, as before.
    private var displayIsEmpty: Bool {
        if viewMode == .raw {
            return rawRows.isEmpty
        }
        return feedGroups.isEmpty
    }

    private func isVisible(_ pkt: AndroidRemotePacket) -> Bool {
        let section: LivePacketSection = LivePacketSort.section(of: pkt, typeInfo: pkt.typeInfo)
        return visibleSections.contains(section)
    }

    private var rawRows: [LinkRawRow] {
        var repeats: [String: Int] = [:]
        var out: [LinkRawRow] = []
        for pkt in vm.androidLivePackets where isVisible(pkt) {
            let seen: Int = repeats[pkt.id] ?? 0
            repeats[pkt.id] = seen + 1
            let rowId: String = seen == 0 ? pkt.id : pkt.id + "#\(seen)"
            out.append(LinkRawRow(id: rowId, packet: pkt))
        }
        return out
    }

    private var feedGroups: [LinkFeedGroup] {
        let unique: [AndroidRemotePacket] = vm.androidUniqueLivePackets
        var visible: [AndroidRemotePacket] = []
        for pkt in unique where isVisible(pkt) {
            visible.append(pkt)
        }
        let grouped: [(LivePacketSection, [AndroidRemotePacket])] = LivePacketSort.groupedLive(visible)
        var out: [LinkFeedGroup] = []
        for entry in grouped {
            out.append(LinkFeedGroup(section: entry.0, packets: entry.1))
        }
        return out
    }

    private func groupSection(_ group: LinkFeedGroup) -> some View {
        let isCollapsed: Bool = collapsed.contains(group.section)
        return Section {
            if !isCollapsed {
                // The unique feed has one row per dedupe key.
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

    private func feedRow(_ pkt: AndroidRemotePacket, raw: Bool) -> some View {
        PacketRow(
            label: pkt.label,
            hex: pkt.hex,
            subtitle: rowSubtitle(pkt),
            onTap: {
                vm.tx.transmit(hex: pkt.hex, label: pkt.label)
            }
        )
        .packetSwipeActions(
            onDelete: {
                askRemove(pkt, raw: raw)
            },
            onPromote: {
                promoteTarget = pkt
            }
        )
        .mmListRow()
    }

    private func rowSubtitle(_ pkt: AndroidRemotePacket) -> String {
        if pkt.note.isEmpty {
            return "RSSI \(pkt.rssi)"
        }
        return pkt.note
    }

    // MARK: Pairing

    private var qrScanner: some View {
        PairingQRScannerView(
            onScan: { raw in
                handleScannedCode(raw)
            },
            onCancel: {
                showQRScanner = false
            }
        )
    }

    // MARK: Actions

    private func handleScannedCode(_ raw: String) {
        showQRScanner = false
        if let info = PairingPayloadParser.parse(raw) {
            vm.applyPairing(info)
        } else {
            vm.statusMessage = "Unrecognized QR — scan Android relay screen"
        }
    }

    /// The TX library is the iPhone's own, so a packet the relay heard is saved here.
    private func addToTx(_ pkt: AndroidRemotePacket) {
        vm.store.saveCustomPreset(label: pkt.label, hex: pkt.hex)
    }

    /// Asks first, with the same titles as the scan list.
    private func askRemove(_ pkt: AndroidRemotePacket, raw: Bool) {
        let title: String = raw ? "Remove raw packet?" : "Remove from scan list?"
        deleteRequest = DeleteRequest(title: title, label: pkt.label, hex: pkt.hex) {
            removeFromFeed(pkt, raw: raw)
        }
    }

    private func removeFromFeed(_ pkt: AndroidRemotePacket, raw: Bool) {
        if raw {
            vm.removeAndroidRawLive(timestampMs: pkt.timestampMs, hex: pkt.hex)
        } else {
            vm.removeAndroidUniqueLive(dedupeKey: pkt.dedupeKey)
        }
    }

    private func toggleCollapsed(_ section: LivePacketSection) {
        if collapsed.contains(section) {
            collapsed.remove(section)
        } else {
            collapsed.insert(section)
        }
    }
}
