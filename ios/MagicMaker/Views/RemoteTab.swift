import SwiftUI

// MARK: - Scan

struct RemoteScanView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var remoteUI: RemoteUIState
    var part: ScanPanelPart = .all

    @State private var viewMode: ScanViewMode = .grouped
    @State private var visibleSections: Set<LivePacketSection> = Set(LivePacketSection.allCases)
    @State private var promoteTarget: AndroidRemotePacket?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if part.includesControls {
                controlRow
                statsBlock
            }
            if part.includesResults {
                liveFeed
            }
        }
        .alert("Packet action", isPresented: promotePresented) {
            Button("Add to TX") {
                if let pkt = promoteTarget {
                    vm.saveAndroidCustomPreset(label: pkt.label, hex: pkt.hex)
                }
                promoteTarget = nil
            }
            Button("Load Lab") {
                if let pkt = promoteTarget { vm.loadAndroidLabHex(pkt.hex) }
                promoteTarget = nil
            }
            Button("Cancel", role: .cancel) { promoteTarget = nil }
        } message: {
            if let pkt = promoteTarget {
                Text(pkt.label.uppercased())
            }
        }
    }

    private var promotePresented: Binding<Bool> {
        Binding(get: { promoteTarget != nil }, set: { if !$0 { promoteTarget = nil } })
    }

    private var controlRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ANDROID SCAN / RX")
                .font(MMTheme.techHeader())
                .foregroundStyle(MMTheme.cyan)

            HStack(spacing: 6) {
                MMCompactButton(
                    title: vm.androidRemote?.scanActive == true ? "Pause" : "Scan",
                    enabled: vm.remoteLinkReady,
                    action: { vm.setAndroidScan(!(vm.androidRemote?.scanActive ?? false)) }
                )
                MMCompactButton(
                    title: vm.androidRemote?.recordSessionActive == true ? "Log Off" : "Log",
                    enabled: vm.remoteLinkReady,
                    action: { vm.setAndroidRecording(!(vm.androidRemote?.recordSessionActive ?? false)) }
                )
                MMCompactButton(title: "Clr", enabled: vm.remoteLinkReady, action: vm.clearAndroidLive)
                MMCompactButton(title: "Vib", enabled: vm.remoteLinkReady, action: vm.vibrateAndroid)
            }

            HStack(spacing: 6) {
                ForEach(ScanViewMode.allCases, id: \.self) { mode in
                    Button(mode.label) { viewMode = mode }
                        .font(MMTheme.techLabel())
                        .buttonStyle(.bordered)
                        .tint(viewMode == mode ? MMTheme.cyan : MMTheme.textDim)
                }
                sectionFilterMenu
            }

            Toggle(isOn: Binding(
                get: { vm.androidRemote?.autoEnabled ?? false },
                set: { vm.setAndroidAuto($0) }
            )) {
                Text("AUTO-RESPONSE")
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textPrimary)
            }
            .tint(MMTheme.cyan)
            .disabled(!vm.remoteLinkReady)

            Text("TAP REPLAY · SWIPE ← TX/TAG · SWIPE → DEL")
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
        }
        .padding(8)
        .background(MMTheme.panel)
        .overlay(RoundedRectangle(cornerRadius: 0).stroke(MMTheme.panelLine, lineWidth: 0.5))
    }

    private var sectionFilterMenu: some View {
        Menu {
            ForEach(LivePacketSection.allCases) { section in
                Button {
                    toggleVisibleSection(section)
                } label: {
                    if visibleSections.contains(section) {
                        Label(section.title, systemImage: "checkmark")
                    } else {
                        Text(section.title)
                    }
                }
            }
        } label: {
            Text("CLASS \(visibleSections.count)/\(LivePacketSection.allCases.count)")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.cyan)
        }
    }

    private var statsBlock: some View {
        Group {
            if let s = vm.androidRemote {
                VStack(alignment: .leading, spacing: 4) {
                    remoteRow(
                        "BUF",
                        viewMode == .raw
                            ? "RAW \(vm.androidLivePackets.count)"
                            : "UNIQUE \(vm.androidUniqueLivePackets.count)"
                    )
                    remoteRow("HEARD", "\(s.packetsHeard) pkts")
                    if !s.lastHeardHex.isEmpty {
                        remoteRow("LAST", "\(s.lastHeardLabel.uppercased()) · \(s.lastHeardHex.prefix(24))…")
                    }
                    if s.recordSessionActive, !s.activeSessionName.isEmpty {
                        remoteRow("LOG", s.activeSessionName)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private var liveFeed: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LIVE RX")
                .font(MMTheme.techHeader())
                .foregroundStyle(MMTheme.cyan)

            if displayPackets.isEmpty {
                Text("LISTEN 0x0183 MANUFACTURER")
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textDim)
                    .padding(.vertical, 12)
            } else if viewMode == .raw {
                ForEach(displayRawPackets) { pkt in
                    scanSwipeRow(pkt)
                }
            } else {
                let grouped = LivePacketSort.groupedLive(displayUniquePackets)
                ForEach(grouped, id: \.0.id) { section, packets in
                    CollapsibleSectionHeader(
                        title: section.title,
                        count: packets.count,
                        collapsed: remoteUI.collapsedScanSections.contains(section),
                        action: { remoteUI.toggleScanSection(section) }
                    )
                    if !remoteUI.collapsedScanSections.contains(section) {
                        ForEach(packets) { pkt in
                            scanSwipeRow(pkt)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func scanSwipeRow(_ pkt: AndroidRemotePacket) -> some View {
        SwipeRemotePacketRow(
            label: pkt.label,
            hex: pkt.hex,
            subtitle: pkt.note.isEmpty ? "RSSI \(pkt.rssi)" : pkt.note,
            onTap: { vm.transmitAndroidHex(pkt.hex) },
            onPromote: { promoteTarget = pkt },
            onDelete: {
                if viewMode == .raw {
                    vm.removeAndroidRawLive(timestampMs: pkt.timestampMs, hex: pkt.hex)
                } else {
                    vm.removeAndroidUniqueLive(dedupeKey: pkt.dedupeKey)
                }
            },
            disabled: !vm.remoteLinkReady
        )
    }

    private var displayRawPackets: [AndroidRemotePacket] {
        vm.androidLivePackets.filter { visibleSections.contains(LivePacketSort.section(of: $0)) }
    }

    private var displayUniquePackets: [AndroidRemotePacket] {
        vm.androidUniqueLivePackets.filter { visibleSections.contains(LivePacketSort.section(of: $0)) }
    }

    private var displayPackets: [AndroidRemotePacket] {
        viewMode == .raw ? displayRawPackets : displayUniquePackets
    }

    private func toggleVisibleSection(_ section: LivePacketSection) {
        if visibleSections.contains(section) {
            visibleSections.remove(section)
        } else {
            visibleSections.insert(section)
        }
    }
}

private enum ScanViewMode: String, CaseIterable {
    case grouped = "GROUPED"
    case raw = "RAW"

    var label: String { rawValue }
}

// MARK: - TX

struct RemoteTxView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var remoteUI: RemoteUIState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    MMCompactButton(title: "Vibrate", enabled: vm.remoteLinkReady, action: vm.vibrateAndroid)
                    MMCompactButton(title: "Interrogate", enabled: vm.remoteLinkReady, action: vm.interrogateAndroid)
                    Spacer()
                    Text("TAP TX")
                        .font(MMTheme.techLabel(9))
                        .foregroundStyle(MMTheme.textDim)
                }

                txLoopExpandBar
                if remoteUI.txLoopSettingsExpanded {
                    txLoopSettingsPanel
                }

                Text("ANDROID TX LIBRARY")
                    .font(MMTheme.techHeader())
                    .foregroundStyle(MMTheme.cyan)

                let presets = vm.androidCatalog?.transmitPresets ?? []
                if presets.isEmpty {
                    Text(txEmptyMessage)
                        .font(MMTheme.techLabel())
                        .foregroundStyle(MMTheme.textDim)
                        .padding(.vertical, 12)
                } else {
                    Text("LIB \(presets.count)")
                        .font(MMTheme.techLabel(9))
                        .foregroundStyle(MMTheme.textDim)
                    let grouped = LivePacketSort.groupedPresets(presets)
                    ForEach(grouped, id: \.0.id) { section, items in
                        CollapsibleSectionHeader(
                            title: section.title,
                            count: items.count,
                            collapsed: remoteUI.collapsedTxSections.contains(section),
                            action: { remoteUI.toggleTxSection(section) }
                        )
                        if !remoteUI.collapsedTxSections.contains(section) {
                            ForEach(items) { pkt in
                                RemotePacketRow(
                                    label: pkt.label,
                                    hex: pkt.hex,
                                    subtitle: txSubtitle(pkt),
                                    highlighted: pkt.id == remoteUI.selectedTxId,
                                    action: {
                                        remoteUI.selectedTxId = pkt.id
                                        vm.transmitAndroidHex(pkt.hex)
                                        if vm.androidRemote?.txLoopEnabled == true {
                                            vm.setAndroidTxLoop(
                                                enabled: true,
                                                packetId: pkt.id,
                                                intervalMs: Int(remoteUI.txIntervalSec * 1000)
                                            )
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
        .scrollDisabled(remoteUI.sliderDragging)
        .background(MMTheme.navy)
    }

    private var txLoopExpandBar: some View {
        Button {
            remoteUI.txLoopSettingsExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: remoteUI.txLoopSettingsExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                Text(remoteUI.txLoopSettingsExpanded ? "HIDE TX LOOP" : "TX LOOP SETTINGS")
                    .font(MMTheme.techLabel(9))
                Spacer(minLength: 4)
                txLoopStatusPills
            }
            .foregroundStyle(MMTheme.cyan)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(MMTheme.panel)
            .overlay(Rectangle().stroke(MMTheme.panelLine, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var txLoopStatusPills: some View {
        HStack(spacing: 8) {
            if vm.androidRemote?.txLoopEnabled == true {
                Text("ON")
                    .font(MMTheme.techLabel(8))
                    .foregroundStyle(MMTheme.cyan)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(MMTheme.cyan.opacity(0.6), lineWidth: 0.5))
                Text(String(format: "%.1fS", remoteUI.txIntervalSec))
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.textDim)
            }
            if let label = vm.androidRemote?.txLoopLabel, !label.isEmpty,
               vm.androidRemote?.txLoopEnabled == true {
                Text(label.uppercased())
                    .font(MMTheme.techLabel(8))
                    .foregroundStyle(MMTheme.textDim)
                    .lineLimit(1)
            }
        }
    }

    private var txLoopSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { vm.androidRemote?.txLoopEnabled ?? false },
                set: { enabled in
                    let id = remoteUI.selectedTxId >= 0
                        ? remoteUI.selectedTxId
                        : vm.androidRemote?.txLoopPacketId
                    vm.setAndroidTxLoop(
                        enabled: enabled,
                        packetId: id,
                        intervalMs: Int(remoteUI.txIntervalSec * 1000)
                    )
                }
            )) {
                Text("LOOP")
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textPrimary)
            }
            .tint(MMTheme.cyan)
            .disabled(!vm.remoteLinkReady || remoteUI.selectedTxId < 0)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("INTERVAL")
                        .font(MMTheme.techLabel())
                        .foregroundStyle(MMTheme.textDim)
                    Spacer()
                    Text(String(format: "%.1fS", remoteUI.txIntervalSec))
                        .font(MMTheme.techLabel())
                        .foregroundStyle(MMTheme.cyan)
                }
                Slider(value: $remoteUI.txIntervalSec, in: 0.5...30, step: 0.5) { editing in
                    remoteUI.sliderDragging = editing
                    if !editing,
                       vm.androidRemote?.txLoopEnabled == true,
                       remoteUI.selectedTxId >= 0 {
                        vm.setAndroidTxLoop(
                            enabled: true,
                            packetId: remoteUI.selectedTxId,
                            intervalMs: Int(remoteUI.txIntervalSec * 1000)
                        )
                    }
                }
                .tint(MMTheme.cyan)
            }

            if let label = vm.androidRemote?.txLoopLabel, !label.isEmpty,
               vm.androidRemote?.txLoopEnabled == true {
                Text("LOOP · \(label.uppercased())")
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.textDim)
            }
        }
        .padding(8)
        .background(MMTheme.panel)
        .overlay(RoundedRectangle(cornerRadius: 0).stroke(MMTheme.panelLine, lineWidth: 0.5))
    }

    private var txEmptyMessage: String {
        if vm.isCatalogSyncInFlight {
            return "SYNCING ANDROID LIBRARY…"
        }
        if vm.relayCommandReady, vm.androidCatalog == nil || vm.androidCatalog?.transmitPresets.isEmpty == true {
            return "SYNCING ANDROID LIBRARY…"
        }
        if !vm.remoteLinkHint.isEmpty {
            return vm.remoteLinkHint
        }
        return "NO TX LIBRARY — open LINK tab, tap Retry BLE"
    }

    private func txSubtitle(_ pkt: AndroidRemotePreset) -> String {
        var parts: [String] = []
        if !pkt.colors.isEmpty { parts.append(pkt.colors) }
        if pkt.userRecorded { parts.append("LEARNED") }
        if pkt.wandVerified { parts.append("WAND OK") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Wand

struct RemoteWandView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var remoteUI: RemoteUIState
    @State private var showNewWand = false
    @State private var editQuick = false
    @State private var quickLabel = ""
    @State private var quickHex = ""

    // New Wand (CF0B) codes are generated locally — they aren't sent over the relay catalog.
    private static let newWandColors: [AndroidRemotePreset] = NewWandCatalog.packets.map {
        AndroidRemotePreset(
            id: $0.id, hex: $0.hex, label: $0.label, category: "COLOR",
            typeInfo: $0.typeInfo, colors: $0.colors, userRecorded: false, wandVerified: false
        )
    }
    // New Wand codes share this signature; used to keep them OUT of the Starlight list.
    private static let newWandSignature = "CF0B00C020224EAC7807866"
    private static func isNewWandHex(_ hex: String) -> Bool {
        hex.uppercased().contains(newWandSignature)
    }

    // Starlight list: drop any New Wand codes that leaked in, and collapse serial-only
    // duplicates so each color appears once (not many variations of the same color).
    private var starlightColors: [AndroidRemotePreset] {
        var seen = Set<Int>()
        var out: [AndroidRemotePreset] = []
        for p in (vm.androidCatalog?.wandColors ?? []) {
            if Self.isNewWandHex(p.hex) { continue }
            let idx = MagicClassifier.starlightColorIndex(p.hex) & 0x1F
            if seen.insert(idx).inserted { out.append(p) }
        }
        return out
    }

    private func transmit(_ color: AndroidRemotePreset) {
        remoteUI.selectedWandId = color.id
        vm.transmitAndroidWandColor(color, intervalMs: Int(remoteUI.wandIntervalSec * 1000))
    }

    private func wandModeButton(_ title: String, isNew: Bool) -> some View {
        Button(title) { showNewWand = isNew }
            .font(MMTheme.techLabel(11))
            .foregroundStyle(showNewWand == isNew ? MMTheme.navy : MMTheme.textDim)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(showNewWand == isNew ? MMTheme.cyan : Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                wandModeButton("STARLIGHT", isNew: false)
                wandModeButton("NEW WAND", isNew: true)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            // Programmable quick button (defaults to the New Wand "Off" code). Tap sends it;
            // press-and-hold to reprogram its label + code. Visible on both wand screens.
            Button {
                vm.transmitWandQuick()
            } label: {
                Text(vm.wandQuickLabel.uppercased())
                    .font(MMTheme.techLabel(11))
                    .foregroundStyle(MMTheme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(!vm.remoteLinkReady)
            .onLongPressGesture {
                quickLabel = vm.wandQuickLabel
                quickHex = vm.wandQuickHex
                editQuick = true
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            if showNewWand {
                NewWandList(
                    colors: Self.newWandColors,
                    enabled: vm.remoteLinkReady,
                    onTransmit: { transmit($0) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                StarlightWandView(
                    colors: starlightColors,
                    displayColorIndex: vm.wandDisplayColorIndex,
                    sendEnabled: vm.remoteLinkReady && !starlightColors.isEmpty,
                    onTransmit: { transmit($0) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { vm.androidRemote?.starlightLoopEnabled ?? false },
                    set: { enabled in
                        let id = remoteUI.selectedWandId >= 0
                            ? remoteUI.selectedWandId
                            : vm.androidRemote?.starlightLoopPacketId
                        vm.setAndroidStarlightLoop(
                            enabled: enabled,
                            packetId: id,
                            intervalMs: Int(remoteUI.wandIntervalSec * 1000)
                        )
                    }
                )) {
                    Text("LOOP")
                        .font(MMTheme.techLabel())
                        .foregroundStyle(MMTheme.textPrimary)
                }
                .tint(MMTheme.cyan)
                .disabled(!vm.remoteLinkReady || remoteUI.selectedWandId < 0)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("INTERVAL")
                            .font(MMTheme.techLabel())
                            .foregroundStyle(MMTheme.textDim)
                        Spacer()
                        Text(String(format: "%.1fS", remoteUI.wandIntervalSec))
                            .font(MMTheme.techLabel())
                            .foregroundStyle(MMTheme.cyan)
                    }
                    Slider(value: $remoteUI.wandIntervalSec, in: 0.5...30, step: 0.5) { editing in
                        remoteUI.sliderDragging = editing
                        if !editing,
                           vm.androidRemote?.starlightLoopEnabled == true,
                           remoteUI.selectedWandId >= 0 {
                            vm.setAndroidStarlightLoop(
                                enabled: true,
                                packetId: remoteUI.selectedWandId,
                                intervalMs: Int(remoteUI.wandIntervalSec * 1000)
                            )
                        }
                    }
                    .tint(MMTheme.cyan)
                }

                if let label = vm.androidRemote?.starlightLoopLabel, !label.isEmpty,
                   vm.androidRemote?.starlightLoopEnabled == true {
                    Text("LOOP · \(label.uppercased())")
                        .font(MMTheme.techLabel(9))
                        .foregroundStyle(MMTheme.textDim)
                }

                HStack {
                    Text("LIB \(vm.androidCatalog?.wandColors.count ?? 0)")
                        .font(MMTheme.techLabel(9))
                        .foregroundStyle(MMTheme.textDim)
                    Spacer()
                    MMCompactButton(
                        title: "Clr Lib",
                        enabled: vm.remoteLinkReady && !(vm.androidCatalog?.wandColors.isEmpty ?? true),
                        action: vm.clearAndroidWandLibrary
                    )
                }
            }
            .padding(8)
            .background(MMTheme.panel)
            .overlay(RoundedRectangle(cornerRadius: 0).stroke(MMTheme.panelLine, lineWidth: 0.5))
        }
        .scrollDisabled(remoteUI.sliderDragging)
        .background(MMTheme.navy)
        .alert("Quick button", isPresented: $editQuick) {
            TextField("Label", text: $quickLabel)
            TextField("Hex (8301…)", text: $quickHex)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
            Button("Save") { vm.setWandQuick(label: quickLabel, hex: quickHex) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tap sends this code; long-press to change it.")
        }
    }
}

// Scrollable, renamable list of New Wand codes. Tap a row to send it; press-and-hold to rename
// it (the color variations are otherwise hard to tell apart). Names persist on the device.
private struct NewWandList: View {
    @EnvironmentObject var vm: AppViewModel
    let colors: [AndroidRemotePreset]
    let enabled: Bool
    let onTransmit: (AndroidRemotePreset) -> Void

    @State private var renameTarget: AndroidRemotePreset?
    @State private var renameText: String = ""

    var body: some View {
        List {
            ForEach(colors) { preset in
                Button {
                    onTransmit(preset)
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(starlightGlowColor(MagicClassifier.starlightColorIndex(preset.hex)))
                            .frame(width: 14, height: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vm.newWandDisplayName(for: preset))
                                .font(MMTheme.techLabel(12))
                                .foregroundStyle(MMTheme.textPrimary)
                            Text(preset.hex.uppercased())
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(MMTheme.textDim)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .listRowBackground(MMTheme.panel)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .contextMenu {
                    Button("Rename") { beginRename(preset) }
                }
                .onLongPressGesture { beginRename(preset) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(MMTheme.navy)
        .alert("Rename code", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let t = renameTarget { vm.setNewWandName(hex: t.hex, name: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text(renameTarget?.hex.uppercased() ?? "")
        }
    }

    private func beginRename(_ preset: AndroidRemotePreset) {
        renameText = vm.newWandDisplayName(for: preset)
        renameTarget = preset
    }
}

// MARK: - Auto

struct RemoteAutoView: View {
    @EnvironmentObject var vm: AppViewModel

    private var rules: [AndroidRemoteAutoRule] {
        vm.androidCatalog?.autoRules ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("AUTO-RULES")
                    .font(MMTheme.techHeader())
                    .foregroundStyle(MMTheme.cyan)

                if let rev = vm.androidRemote?.storeRevision {
                    Text("ANDROID REV \(rev) · \(rules.count) RULES")
                        .font(MMTheme.techLabel(9))
                        .foregroundStyle(MMTheme.textDim)
                }

                Toggle(isOn: Binding(
                    get: { vm.androidRemote?.autoEnabled ?? false },
                    set: { vm.setAndroidAuto($0) }
                )) {
                    Text("AUTO ARMED")
                        .font(MMTheme.techLabel())
                        .foregroundStyle(MMTheme.textPrimary)
                }
                .tint(MMTheme.cyan)
                .disabled(!vm.remoteLinkReady)

                if rules.isEmpty {
                    Text("NO RULES ON ANDROID")
                        .font(MMTheme.techLabel())
                        .foregroundStyle(MMTheme.textDim)
                        .padding(.vertical, 12)
                } else {
                    ForEach(rules) { rule in
                        autoRuleRow(rule)
                    }
                }
            }
            .padding(8)
        }
        .background(MMTheme.navy)
        .onAppear {
            vm.refreshAndroidAutoFromRemote()
        }
        .onChange(of: vm.androidRemote?.storeRevision) { _, _ in
            vm.refreshAndroidCatalog()
        }
    }

    @ViewBuilder
    private func autoRuleRow(_ rule: AndroidRemoteAutoRule) -> some View {
        let ruleId = rule.id
        let enabled = vm.androidCatalog?.autoRules.first(where: { $0.id == ruleId })?.enabled ?? rule.enabled
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name.uppercased())
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textPrimary)
                Text("\(rule.triggerPatternId) → \(rule.responseHexes.count) PKT")
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.textDim)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { enabled },
                set: { vm.setAndroidAutoRuleEnabled(ruleId, enabled: $0) }
            ))
            .labelsHidden()
            .tint(MMTheme.cyan)
            .disabled(!vm.remoteLinkReady)
            Button(role: .destructive) {
                vm.deleteAndroidAutoRule(ruleId)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(MMTheme.error)
            }
            .disabled(!vm.remoteLinkReady)
        }
        .padding(.vertical, 4)
        Rectangle().fill(MMTheme.panelLine).frame(height: 0.5)
    }
}

// MARK: - Lab

struct RemoteLabView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var remoteUI: RemoteUIState
    @State private var mbleToken = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("LAB")
                    .font(MMTheme.techHeader())
                    .foregroundStyle(MMTheme.cyan)

                // The builder never transmits. It only fills the hex field; SEND below is the
                // single thing on this screen that puts a packet on the air.
                LabBuilderPanel(
                    enabled: vm.remoteLinkReady,
                    loadedHex: vm.androidLabHex,
                    onHexBuilt: { vm.androidLabHex = $0 }
                )

                DisclosureGroup(isExpanded: $remoteUI.txSettingsExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        sliderRow(
                            label: "WAKE PREAMBLE",
                            value: $remoteUI.preambleMs,
                            range: 200...1500,
                            step: 20,
                            display: "\(Int(remoteUI.preambleMs))MS",
                            onCommit: { vm.setAndroidWakeupPreamble(Int(remoteUI.preambleMs)) }
                        )
                        sliderRow(
                            label: "COMMAND BURST",
                            value: $remoteUI.commandBurstMs,
                            range: 500...5000,
                            step: 100,
                            display: "\(Int(remoteUI.commandBurstMs))MS",
                            onCommit: { vm.setAndroidCommandBurst(Int(remoteUI.commandBurstMs)) }
                        )
                        sliderRow(
                            label: "STARLIGHT WAND",
                            value: $remoteUI.starlightBurstMs,
                            range: 250...5000,
                            step: 100,
                            display: "\(Int(remoteUI.starlightBurstMs))MS",
                            onCommit: { vm.setAndroidStarlightBurst(Int(remoteUI.starlightBurstMs)) }
                        )
                        Text("GLOBAL ON ANDROID — PREAMBLE, BAND BURST, WAND ON-AIR TIME.")
                            .font(MMTheme.techLabel(9))
                            .foregroundStyle(MMTheme.textDim)
                    }
                    .padding(.top, 4)
                } label: {
                    Text("TRANSMISSION SETTINGS")
                        .font(MMTheme.techHeader())
                        .foregroundStyle(MMTheme.cyan)
                }

                Text("PACKET TO SEND")
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.cyanDim)
                TextField("HEX (8301…)", text: $vm.androidLabHex)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textPrimary)
                    .padding(8)
                    .background(MMTheme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(MMTheme.panelLine, lineWidth: 0.5))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                // The one and only transmit control in the Lab.
                Button {
                    vm.transmitAndroidHex(vm.androidLabHex)
                } label: {
                    Text("SEND")
                        .font(MMTheme.techHeader())
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(MMTheme.cyan)
                .disabled(!vm.remoteLinkReady || vm.androidLabHex.isEmpty
                          || HexUtils.legacyAdvertiseRejectReason(vm.androidLabHex) != nil)
                if !vm.remoteLinkReady {
                    Text("LINK NOT READY — CONNECT A RELAY ON THE LINK TAB TO SEND")
                        .font(MMTheme.techLabel(9))
                        .foregroundStyle(MMTheme.amber)
                }

                labMbleSection
            }
            .padding(8)
        }
        .scrollDisabled(remoteUI.sliderDragging)
        .background(MMTheme.navy)
    }

    private var labMbleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MBLE TAP (LIGHTNING LANE)")
                .font(MMTheme.techHeader())
                .foregroundStyle(MMTheme.cyan)
                .padding(.top, 8)
            TextField("VMMS token hex", text: $mbleToken)
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textPrimary)
                .padding(8)
                .background(MMTheme.panel)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(MMTheme.panelLine, lineWidth: 0.5))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            MMCompactButton(
                title: "MBLE ADV",
                enabled: vm.remoteLinkReady && !mbleToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                action: { vm.mbleTapAndroid(tokenHex: mbleToken) }
            )
        }
    }

    private func sliderRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        display: String,
        onCommit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textDim)
                Spacer()
                Text(display)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.cyan)
            }
            Slider(value: value, in: range, step: step) { editing in
                remoteUI.sliderDragging = editing
                if !editing { onCommit() }
            }
            .tint(MMTheme.cyan)
        }
    }
}

// MARK: - Link

struct RemoteLinkView: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var showQRScanner = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RELAY / LINK")
                .font(MMTheme.techHeader())
                .foregroundStyle(MMTheme.cyan)

            HStack {
                Circle().fill(linkColor).frame(width: 8, height: 8)
                Text(linkLabel)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textPrimary)
            }

            Text("Backend")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
            Picker("Backend", selection: Binding(
                get: { vm.relayBackend },
                set: { vm.setRelayBackend($0) }
            )) {
                ForEach(RelayBackend.allCases) { backend in
                    Text(backend.label).tag(backend)
                }
            }
            .pickerStyle(.segmented)
            .tint(MMTheme.cyan)

            if vm.relayBackend == .androidWifi {
                MMPrimaryButton(title: "Scan Android QR", enabled: true) {
                    showQRScanner = true
                }
                TextField("Android IP (hotspot gateway)", text: Binding(
                    get: { vm.androidRelayIP },
                    set: { vm.saveAndroidRelayIP($0) }
                ))
                .font(MMTheme.techLabel())
                .padding(8)
                .background(MMTheme.panel)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(MMTheme.panelLine, lineWidth: 0.5))
                .keyboardType(.decimalPad)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            } else if vm.relayBackend == .esp32 {
                Text("Power on the MagicMaker ESP32. iPhone auto-connects and transmits through it while you keep scanning. No pairing needed.")
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.textDim)
            } else {
                Text("Put Android in BLE GATT / iPhone mode. iPhone auto-connects to MagicMaker-Android.")
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.textDim)
            }

            remoteRow("IPHONE", vm.relayStatus)
            if vm.isCatalogSyncInFlight || !vm.catalogSyncDiagnostic.isEmpty {
                remoteRow("LIB SYNC", vm.catalogSyncDiagnostic.uppercased())
            }
            if let cat = vm.androidCatalog, !cat.transmitPresets.isEmpty {
                remoteRow("LIB", "\(cat.transmitPresets.count) TX · \(cat.wandColors.count) WAND")
            }
            if let s = vm.androidRemote {
                remoteRow("ANDROID", s.status.isEmpty ? (s.running ? "RUNNING" : "STOPPED") : s.status.uppercased())
                remoteRow("STORE", "REV \(s.storeRevision)")
                if s.relayLinked { remoteRow("GATT", "LINKED") }
            }

            HStack(spacing: 6) {
                MMCompactButton(title: "Refresh") {
                    vm.refreshAndroidRemote()
                    vm.refreshAndroidCatalog()
                    vm.refreshRelayStatus()
                }
                if vm.relayBackend.usesBleRelayLink {
                    MMCompactButton(title: "Retry BLE", action: vm.reconnectRelay)
                }
            }

            Text("Control Android from your pocket: BLE when close, WiFi hotspot + QR when Android is in your backpack.")
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
        }
        .sheet(isPresented: $showQRScanner) {
            PairingQRScannerView(
                onScan: { raw in
                    showQRScanner = false
                    if let info = PairingPayloadParser.parse(raw) {
                        vm.applyPairing(info)
                    } else {
                        vm.statusMessage = "Unrecognized QR — scan Android relay screen"
                    }
                },
                onCancel: { showQRScanner = false }
            )
        }
    }

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
            if vm.relayGattReady, vm.androidRemote?.relayLinked == true { return "GATT LINKED"
            }
            if vm.relayGattReady { return "GATT READY" }
            return "GATT SEARCHING"
        case .androidWifi:
            return vm.remoteLinkReady ? "WIFI LINKED" : "WIFI NOT CONNECTED"
        }
    }
}

struct RemoteLinkTabView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        ScrollView {
            RemoteLinkView()
                .padding(8)
        }
        .background(MMTheme.navy)
    }
}

// MARK: - iScan tab

struct RemoteScanTabView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var remoteUI: RemoteUIState

    var body: some View {
        VStack(spacing: 0) {
            scanExpandBar
            if remoteUI.scanControlsExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        RemoteScanView(part: .controls)
                        Rectangle().fill(MMTheme.panelLine).frame(height: 0.5)
                        ISCanView(part: .controls)
                    }
                    .padding(8)
                }
                .frame(maxHeight: 300)
                Rectangle().fill(MMTheme.panelLine).frame(height: 0.5)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    RemoteScanView(part: .results)
                    Rectangle().fill(MMTheme.panelLine).frame(height: 0.5)
                    ISCanView(part: .results)
                }
                .padding(8)
            }
        }
        .scrollDisabled(remoteUI.sliderDragging)
        .background(MMTheme.navy)
    }

    private var scanExpandBar: some View {
        Button {
            remoteUI.scanControlsExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: remoteUI.scanControlsExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                Text(remoteUI.scanControlsExpanded ? "HIDE SCAN CONTROLS" : "SCAN CONTROLS")
                    .font(MMTheme.techLabel(9))
                Spacer(minLength: 4)
                scanStatusPills
            }
            .foregroundStyle(MMTheme.cyan)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(MMTheme.panel)
            .overlay(Rectangle().stroke(MMTheme.panelLine, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var scanStatusPills: some View {
        HStack(spacing: 8) {
            if vm.androidRemote?.scanActive == true {
                pill("AND", MMTheme.cyan)
            }
            if vm.isLocalListening {
                pill("iOS", MMTheme.amber)
            }
            if vm.isBackupLogging {
                pill("LOG", MMTheme.error)
            }
            if let s = vm.androidRemote {
                Text("\(s.packetsHeard)")
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.textDim)
            }
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(MMTheme.techLabel(8))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(color.opacity(0.6), lineWidth: 0.5))
    }
}

enum ScanPanelPart {
    case all, controls, results

    var includesControls: Bool { self == .all || self == .controls }
    var includesResults: Bool { self == .all || self == .results }
}

// MARK: - More

struct RemoteMoreView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("MORE")
                        .font(MMTheme.techHeader())
                        .foregroundStyle(MMTheme.cyan)
                        .padding(.horizontal, 4)

                    MoreNavLink(title: "ANDROID SCAN / RX", subtitle: "Remote scan, log, auto on Android") {
                        RemoteScanView()
                            .padding(8)
                            .background(MMTheme.navy)
                    }

                    MoreNavLink(title: "MAGIC BAND THEMES", subtitle: "Hawkeye Light Up color themes (MDE mapIdentifier)") {
                        MoreThemesView()
                    }

                    MoreNavLink(title: "LIGHTNING LANE", subtitle: "MBLE VMMS tap tokens + band effects") {
                        MoreLightningLaneView()
                    }

                    moreDivider()

                    RemoteLinkView()
                        .padding(.horizontal, 4)
                }
                .padding(8)
            }
            .background(MMTheme.navy)
            .navigationBarHidden(true)
        }
    }

    private func moreDivider() -> some View {
        Rectangle()
            .fill(MMTheme.panelLine)
            .frame(height: 0.5)
            .padding(.vertical, 4)
    }
}

private struct MoreNavLink<Destination: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.cyan)
                Text(subtitle)
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(MMTheme.panel)
            .overlay(RoundedRectangle(cornerRadius: 0).stroke(MMTheme.panelLine, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

struct MoreThemesView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("HAWKEYE LIGHT UP THEMES")
                    .font(MMTheme.techHeader())
                    .foregroundStyle(MMTheme.cyan)
                Text("MDE Hawkeye mapIdentifier + CMS color swatches → on-air preset via Android. Paste base64 lightSequence in Lab to add captured CMS themes.")
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.textDim)

                ForEach(MdeThemeCatalog.categories, id: \.id) { category in
                    Text(category.title)
                        .font(MMTheme.techHeader())
                        .foregroundStyle(MMTheme.cyan)
                        .padding(.top, 4)
                    ForEach(category.themes) { theme in
                        themeRow(theme)
                    }
                }
            }
            .padding(8)
        }
        .background(MMTheme.navy)
        .navigationTitle("Themes")
    }

    private func themeRow(_ theme: MdeHawkeyeTheme) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ForEach(theme.colors.prefix(5), id: \.self) { hex in
                    Circle()
                        .fill(Color(hexSwatch: hex))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(MMTheme.panelLine, lineWidth: 0.5))
                }
                Spacer()
            }
            RemotePacketRow(
                label: theme.title,
                hex: theme.transmitHex,
                subtitle: "\(theme.mapIdentifier) · ANDROID TX",
                action: { vm.transmitAndroidHex(theme.transmitHex) }
            )
            .disabled(!vm.remoteLinkReady)
        }
    }
}

private extension Color {
    init(hexSwatch: String) {
        let clean = hexSwatch.replacingOccurrences(of: "#", with: "")
        let value = Int(clean, radix: 16) ?? 0
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

struct MoreLightningLaneView: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var mbleToken = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("MBLE / LIGHTNING LANE TAP")
                    .font(MMTheme.techHeader())
                    .foregroundStyle(MMTheme.cyan)
                Text("MDE advertises VMMS tap tokens as AltBeacon on 0x0183 (layout m:2-3=0F11, id 987393). Paste a bleIdentifiers token from MDE/VMMS — Android broadcasts it.")
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.textDim)

                TextField("VMMS token hex (bleIdentifiers)", text: $mbleToken)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textPrimary)
                    .padding(8)
                    .background(MMTheme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(MMTheme.panelLine, lineWidth: 0.5))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                MMPrimaryButton(
                    title: "Start MBLE Tap ADV",
                    enabled: vm.remoteLinkReady && !mbleToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: { vm.mbleTapAndroid(tokenHex: mbleToken) }
                )

                Text("BAND EFFECTS (8301 show packets)")
                    .font(MMTheme.techHeader())
                    .foregroundStyle(MMTheme.cyan)
                    .padding(.top, 8)

                let effects: [(String, String)] = [
                    ("Wakeup Ping", PacketBuilder.wakeupPing),
                    ("Lightning Pulse", "8301CC03000100E100E90C000F0F5D465BF00532374895"),
                    ("Vibrate Response", PresetCatalog.vibratePacket),
                ]
                ForEach(effects, id: \.0) { label, hex in
                    RemotePacketRow(
                        label: label,
                        hex: hex,
                        subtitle: vm.remoteLinkReady ? "ANDROID TX" : "LINK REQUIRED",
                        action: { vm.transmitAndroidHex(hex) }
                    )
                    .disabled(!vm.remoteLinkReady)
                }
            }
            .padding(8)
        }
        .background(MMTheme.navy)
        .navigationTitle("Lightning Lane")
    }
}

struct ISCanView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var remoteUI: RemoteUIState
    var part: ScanPanelPart = .all

    @State private var viewMode: ScanViewMode = .grouped
    @State private var visibleSections: Set<LivePacketSection> = Set(LivePacketSection.allCases)
    @State private var promoteTarget: IScanLivePacket?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if part.includesControls {
                controlRow
                statsBlock
            }
            if part.includesResults {
                liveFeed
            }
        }
        .alert("Packet action", isPresented: promotePresented) {
            if vm.remoteLinkReady {
                Button("Add to TX") {
                    if let pkt = promoteTarget {
                        vm.saveAndroidCustomPreset(label: pkt.label, hex: pkt.hex)
                    }
                    promoteTarget = nil
                }
            }
            Button("Load Lab") {
                if let pkt = promoteTarget { vm.loadAndroidLabHex(pkt.hex) }
                promoteTarget = nil
            }
            Button("Cancel", role: .cancel) { promoteTarget = nil }
        } message: {
            if let pkt = promoteTarget {
                Text(pkt.label.uppercased())
            }
        }
    }

    private var promotePresented: Binding<Bool> {
        Binding(get: { promoteTarget != nil }, set: { if !$0 { promoteTarget = nil } })
    }

    private var controlRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("IPHONE BACKUP SCAN")
                .font(MMTheme.techHeader())
                .foregroundStyle(MMTheme.cyan)

            Text("Independent listener — CSV logs in Files app:")
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
            Text(ISCanBackupLogger.filesAppPath)
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.cyanDim)

            HStack(spacing: 6) {
                MMCompactButton(
                    title: vm.isLocalListening ? "Pause" : "Scan",
                    enabled: true,
                    action: { vm.setLocalListening(!vm.isLocalListening) }
                )
                MMCompactButton(
                    title: vm.isBackupLogging ? "Stop Log" : "Backup Log",
                    enabled: true,
                    action: { vm.setBackupLogging(!vm.isBackupLogging) }
                )
                MMCompactButton(title: "Clr", enabled: !iscanBuffersEmpty, action: vm.clearIscanLive)
                MMCompactButton(title: "Vib", enabled: vm.remoteLinkReady, action: vm.vibrateAndroid)
            }

            HStack(spacing: 6) {
                ForEach(ScanViewMode.allCases, id: \.self) { mode in
                    Button(mode.label) { viewMode = mode }
                        .font(MMTheme.techLabel())
                        .buttonStyle(.bordered)
                        .tint(viewMode == mode ? MMTheme.cyan : MMTheme.textDim)
                }
                Menu {
                    ForEach(LivePacketSection.allCases) { section in
                        Button {
                            toggleVisibleSection(section)
                        } label: {
                            if visibleSections.contains(section) {
                                Label(section.title, systemImage: "checkmark")
                            } else {
                                Text(section.title)
                            }
                        }
                    }
                } label: {
                    Text("CLASS \(visibleSections.count)/\(LivePacketSection.allCases.count)")
                        .font(MMTheme.techLabel())
                        .foregroundStyle(MMTheme.cyan)
                }
            }

            Toggle(isOn: $vm.iscanShowControlOnly) {
                Text("SHOW-CONTROL ONLY (HIDE BAND NOISE)")
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textPrimary)
            }
            .tint(MMTheme.cyan)

            Toggle(isOn: Binding(
                get: { vm.iscanAutoEnabled },
                set: { vm.setIscanAuto($0) }
            )) {
                Text("AUTO-RESPONSE (TX VIA ANDROID)")
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textPrimary)
            }
            .tint(MMTheme.cyan)
            .disabled(!vm.remoteLinkReady)

            Text("TAP REPLAY · SWIPE ← TX/TAG · SWIPE → DEL")
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
        }
        .padding(8)
        .background(MMTheme.panel)
        .overlay(RoundedRectangle(cornerRadius: 0).stroke(MMTheme.panelLine, lineWidth: 0.5))
    }

    private var statsBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            remoteRow(
                "BUF",
                viewMode == .raw
                    ? "RAW \(vm.iscanRawLive.count)"
                    : "UNIQUE \(vm.iscanUniqueLive.count)"
            )
            if let last = vm.iscanRawLive.first {
                remoteRow("LAST", "\(last.label.uppercased()) · \(last.hex.prefix(24))…")
            }
            remoteRow("TX PATH", vm.remoteLinkReady ? "ANDROID RELAY" : "NOT LINKED")
            if vm.isBackupLogging, let name = vm.backupLogFileName {
                remoteRow("FILE", name)
            } else if !vm.backupLogFiles.isEmpty {
                remoteRow("LOGS", "\(vm.backupLogFiles.count) in Files")
            }
            remoteRow("FILES", ISCanBackupLogger.filesAppPath)
        }
        .padding(.horizontal, 4)
    }

    private var liveFeed: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LIVE RX (iPHONE)")
                .font(MMTheme.techHeader())
                .foregroundStyle(MMTheme.cyan)

            if !vm.isLocalListening {
                Text("OFF — TAP SCAN TO LISTEN ON IPHONE RADIO")
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textDim)
                    .padding(.vertical, 12)
            } else if displayPackets.isEmpty {
                Text("LISTEN 0x0183 MANUFACTURER")
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textDim)
                    .padding(.vertical, 12)
            } else if viewMode == .raw {
                ForEach(displayRawPackets) { pkt in
                    iscanSwipeRow(pkt)
                }
            } else {
                let grouped = LivePacketSort.groupedIScan(displayUniquePackets)
                ForEach(grouped, id: \.0.id) { section, packets in
                    CollapsibleSectionHeader(
                        title: section.title,
                        count: packets.count,
                        collapsed: remoteUI.collapsedLocalSections.contains(section),
                        action: { remoteUI.toggleLocalSection(section) }
                    )
                    if !remoteUI.collapsedLocalSections.contains(section) {
                        ForEach(packets) { pkt in
                            iscanSwipeRow(pkt)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func iscanSwipeRow(_ pkt: IScanLivePacket) -> some View {
        SwipeRemotePacketRow(
            label: pkt.label,
            hex: pkt.hex,
            subtitle: "RSSI \(pkt.rssi) · TAP → ANDROID TX",
            onTap: { vm.transmitAndroidHex(pkt.hex) },
            onPromote: { promoteTarget = pkt },
            onDelete: {
                if viewMode == .raw {
                    vm.removeIscanRaw(timestampMs: pkt.timestampMs, hex: pkt.hex)
                } else {
                    vm.removeIscanUnique(dedupeKey: pkt.dedupeKey)
                }
            },
            disabled: !vm.remoteLinkReady
        )
    }

    private var iscanBuffersEmpty: Bool {
        vm.iscanUniqueLive.isEmpty && vm.iscanRawLive.isEmpty
    }

    private var displayPackets: [IScanLivePacket] {
        viewMode == .raw ? displayRawPackets : displayUniquePackets
    }

    private var displayUniquePackets: [IScanLivePacket] {
        vm.iscanUniqueLive.filter { visibleSections.contains(LivePacketSort.section(of: $0)) }
    }

    private var displayRawPackets: [IScanLivePacket] {
        vm.iscanRawLive.filter { visibleSections.contains(LivePacketSort.section(of: $0)) }
    }

    private func toggleVisibleSection(_ section: LivePacketSection) {
        if visibleSections.contains(section) {
            visibleSections.remove(section)
        } else {
            visibleSections.insert(section)
        }
    }
}

// MARK: - Helpers

private func remoteRow(_ key: String, _ value: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
        Text(key)
            .font(MMTheme.techLabel(9))
            .foregroundStyle(MMTheme.textDim)
            .frame(width: 72, alignment: .leading)
        Text(value.uppercased())
            .font(MMTheme.techLabel(9))
            .foregroundStyle(MMTheme.textPrimary)
            .lineLimit(3)
    }
}
