import Foundation
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    @Published var statusMessage = "Ready"
    @Published var relayStatus = "Not connected"
    @Published var relayBackend = RelayBackend.load()
    @Published var androidRelayIP = RelaySettings.androidRelayIP
    @Published var isRecording = false
    @Published var isAutoEnabled = false
    @Published var isLocalListening = false
    @Published var isBackupLogging = UserDefaults.standard.object(forKey: "backup_logging_enabled") as? Bool ?? true
    @Published var backupLogFileName: String?
    @Published var iscanAutoEnabled = false
    @Published var activeSessionName: String?
    @Published private(set) var isCatalogSyncInFlight = false
    @Published private(set) var catalogSyncDiagnostic = ""
    @Published var livePackets: [Recording] = []
    @Published private(set) var iscanUniqueLive: [IScanLivePacket] = []
    @Published private(set) var iscanRawLive: [IScanLivePacket] = []
    @Published var androidRemote: AndroidRemoteStatus?
    @Published private(set) var wandDisplayColorIndex = 0x1B
    @Published var androidLivePackets: [AndroidRemotePacket] = []
    @Published var androidCatalog: AndroidRemoteCatalog?
    @Published var androidLabHex = ""
    private var lastCatalogRevision = -1

    private var _store: MagicStore?
    var store: MagicStore {
        if let _store { return _store }
        let created = MagicStore()
        created.prepareIfNeeded()
        _store = created
        return created
    }
    private lazy var ble: BleCoordinator = {
        let coordinator = BleCoordinator()
        coordinator.store = store
        coordinator.onPacket = { [weak self] hex, rssi in
            Task { @MainActor in self?.handlePacket(hex: hex, rssi: rssi) }
        }
        coordinator.onStatus = { [weak self] msg in
            Task { @MainActor in
                self?.statusMessage = msg
                self?.refreshRelayStatus()
            }
        }
        coordinator.onAutoResponse = { [weak self] label, _ in
            Task { @MainActor in self?.statusMessage = "Auto-response → \(label)" }
        }
        coordinator.onRelayCommandReady = { [weak self] in
            Task { @MainActor in
                self?.refreshAndroidCatalog()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.refreshAndroidRemote()
                }
            }
        }
        coordinator.onCatalogReceived = { [weak self] json in
            Task { @MainActor in
                self?.applyAndroidCatalog(json)
            }
        }
        return coordinator
    }()
    private let remote = AndroidRemoteClient.shared
    private let maxLive = 200
    private let maxIscanLive = 200
    private var iscanAutoCooldownUntil = Date.distantPast
    private var catalogFetchInFlight = false
    private var catalogFetchTimeout: DispatchWorkItem?
    private var catalogSyncCooldownUntil = Date.distantPast

    init() {}

    /// Deferred from init so CoreBluetooth, file I/O, and remote refresh run after UIKit finishes launching.
    func bootstrapAfterLaunch() {
        _ = ble
        ble.activateBluetooth()
        refreshRelayStatus()
        refreshAndroidRemote()
        if isBackupLogging, backupLogFileName == nil {
            backupLogFileName = ISCanBackupLogger.shared.startSession()
        }
    }

    var telemetryLine: String {
        var parts = ["MM/RF", relayBackend == .androidWifi ? "WIFI" : "BLE"]
        if let s = androidRemote {
            parts.append("RX:\(s.packetsHeard)")
            if s.autoResponsesSent > 0 { parts.append("TX-AUTO:\(s.autoResponsesSent)") }
            if s.scanActive { parts.append("SCAN:ON") }
            if s.autoEnabled { parts.append("AUTO:ARM") }
            if s.recordSessionActive { parts.append("LOG:REC") }
            if s.starlightLoopEnabled { parts.append("WAND:LOOP") }
            if s.txLoopEnabled { parts.append("TX:LOOP") }
            if s.relayLinked { parts.append("IPHONE:LINK") }
        } else if relayCommandReady {
            parts.append("GATT:READY")
        } else if relayGattReady {
            parts.append("GATT:TX")
        } else {
            parts.append("LINK:…")
        }
        if isCatalogSyncInFlight {
            parts.append("LIB:…")
        } else if let cat = androidCatalog, !cat.transmitPresets.isEmpty {
            parts.append("LIB:\(cat.transmitPresets.count)")
        }
        if isLocalListening { parts.append("iSCAN:ON") }
        if isBackupLogging { parts.append("BACKUP:REC") }
        return parts.joined(separator: " | ")
    }

    var remoteLinkHint: String {
        switch relayBackend {
        case .androidBle:
            if relayCommandReady { return "" }
            if relayGattReady || ble.bleCentral.relayGatt.isLinkInProgress {
                return "Finishing Android link…"
            }
            return "Open LINK — tap Retry BLE, keep phones close."
        case .androidWifi:
            if remoteLinkReady { return "" }
            return "Open LINK — scan Android QR or join MagicMaker hotspot."
        }
    }

    private func handlePacket(hex: String, rssi: Int) {
        if isLocalListening {
            appendLocalLivePacket(hex: hex, rssi: rssi)
            if isBackupLogging {
                ISCanBackupLogger.shared.append(hex: hex, rssi: rssi)
            }
            maybeIscanAutoRespond(hex: hex)
            return
        }

        guard isRecording || isAutoEnabled else { return }

        if let event = store.processHeardPacket(hex: hex, rssi: rssi, persistToSession: isRecording) {
            if isRecording {
                statusMessage = event.reason
                let rec = Recording(
                    id: event.packet.id,
                    timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
                    hex: event.packet.hex,
                    rssi: rssi,
                    label: event.packet.label,
                    category: event.packet.category,
                    typeInfo: event.packet.typeInfo,
                    colors: event.packet.colors,
                    libraryNote: event.reason
                )
                livePackets.append(rec)
                if livePackets.count > maxLive { livePackets.removeFirst(livePackets.count - maxLive) }
            } else if event.added {
                statusMessage = event.reason
            }
        }
    }

    private func appendLocalLivePacket(hex: String, rssi: Int) {
        let classified = MagicClassifier.classify(hex)
        let dedupeKey = LivePacketSort.liveDedupeKey(hex: hex, classified: classified)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let packet = IScanLivePacket(
            timestampMs: now,
            hex: classified?.hex ?? HexUtils.canonicalHex(hex),
            label: classified?.label ?? "Raw packet",
            rssi: rssi,
            note: "iPhone RX",
            category: classified?.category ?? .unknown,
            typeInfo: classified?.typeInfo ?? "raw",
            dedupeKey: dedupeKey
        )
        iscanRawLive.insert(packet, at: 0)
        if iscanRawLive.count > maxIscanLive {
            iscanRawLive.removeLast(iscanRawLive.count - maxIscanLive)
        }
        iscanUniqueLive.removeAll { $0.dedupeKey == dedupeKey }
        iscanUniqueLive.insert(packet, at: 0)
        if iscanUniqueLive.count > maxIscanLive {
            iscanUniqueLive.removeLast(iscanUniqueLive.count - maxIscanLive)
        }
    }

    func setIscanAuto(_ enabled: Bool) {
        iscanAutoEnabled = enabled
        statusMessage = enabled ? "iScan auto armed — TX via Android" : "iScan auto off"
    }

    private func maybeIscanAutoRespond(hex: String) {
        guard iscanAutoEnabled, remoteLinkReady else { return }
        guard Date() >= iscanAutoCooldownUntil else { return }
        guard let rules = androidCatalog?.autoRules.filter(\.enabled), !rules.isEmpty else { return }

        let classified: ClassifiedPacket
        if let c = MagicClassifier.classify(hex) {
            classified = c
        } else {
            let canonical = HexUtils.canonicalHex(hex)
            guard HexUtils.isDisneyBlePacket(canonical) else { return }
            classified = ClassifiedPacket(
                hex: canonical,
                label: "Raw packet",
                category: .unknown,
                typeInfo: "raw",
                colors: "",
                simKey: "RAW:\(canonical)"
            )
        }

        for rule in rules {
            guard PacketPatterns.matchesTriggerId(rule.triggerPatternId, classified: classified, rawHex: hex, learned: []) else {
                continue
            }
            let responseHex: String
            if let first = rule.responseHexes.first, !first.isEmpty {
                responseHex = first
            } else {
                let localRule = AutoResponseRule(
                    id: rule.id,
                    name: rule.name,
                    triggerPatternId: rule.triggerPatternId,
                    responsePatternId: rule.responsePatternId,
                    responseHex: rule.responseHexes.first ?? "",
                    enabled: rule.enabled
                )
                responseHex = PacketPatterns.resolveResponseHex(rule: localRule, learned: [])
            }
            guard !responseHex.isEmpty else { continue }
            iscanAutoCooldownUntil = Date().addingTimeInterval(0.8)
            transmitAndroidHex(responseHex)
            statusMessage = "iScan auto → \(classified.label)"
            return
        }
    }

    func setLocalListening(_ enabled: Bool) {
        guard isLocalListening != enabled else { return }
        isLocalListening = enabled
        if enabled {
            clearIscanLive()
        }
        syncBleListenModes()
        if enabled {
            reconnectRelay()
            statusMessage = "iPhone backup scan listening"
            if isBackupLogging && backupLogFileName == nil {
                backupLogFileName = ISCanBackupLogger.shared.startSession()
            }
        } else if !isBackupLogging {
            statusMessage = "Backup scan off"
            ensureRelayLink()
        }
    }

    func ensureRelayLink() {
        ble.ensureRelayLink()
    }

    func setBackupLogging(_ enabled: Bool) {
        guard isBackupLogging != enabled else { return }
        isBackupLogging = enabled
        UserDefaults.standard.set(enabled, forKey: "backup_logging_enabled")
        if enabled {
            backupLogFileName = ISCanBackupLogger.shared.startSession()
            if !isLocalListening {
                setLocalListening(true)
            }
            statusMessage = "Backup log → \(backupLogFileName ?? "file")"
        } else if let name = ISCanBackupLogger.shared.stopSession() {
            backupLogFileName = nil
            statusMessage = "Backup saved: \(name)"
        }
    }

    var backupLogFiles: [URL] {
        ISCanBackupLogger.shared.listSessions()
    }

    private func syncBleListenModes() {
        ble.updateModes(recording: isRecording, auto: isAutoEnabled, listening: isLocalListening)
    }

    func toggleRecording() {
        isRecording.toggle()
        if isRecording {
            activeSessionName = store.beginScanSession().lastPathComponent
            statusMessage = "Recording → \(activeSessionName ?? "")"
        } else {
            if let ended = store.endScanSession() {
                statusMessage = "Saved scan file: \(ended)"
            } else if isAutoEnabled {
                statusMessage = "Recording off — auto still listening"
            } else {
                statusMessage = "Scan stopped"
            }
            activeSessionName = nil
        }
        syncBleListenModes()
    }

    func toggleAuto() {
        setAutoEnabled(!isAutoEnabled)
    }

    func setAutoEnabled(_ enabled: Bool) {
        guard isAutoEnabled != enabled else { return }
        isAutoEnabled = enabled
        statusMessage = enabled ? "Auto-response listening" : (isRecording ? "Auto off — scan still on" : "Auto off")
        syncBleListenModes()
    }

    func play(packet: MagicPacket) {
        ble.play(hex: packet.hex, label: packet.label, typeInfo: packet.typeInfo, category: packet.category)
    }

    func playHex(_ hex: String, label: String = "Packet") {
        guard let c = MagicClassifier.classify(hex) else {
            ble.play(hex: hex, label: label, typeInfo: "raw", category: .unknown)
            return
        }
        ble.play(hex: c.hex, label: label, typeInfo: c.typeInfo, category: c.category)
    }

    func loadIntoLab(hex: String, label: String = "") {
        store.loadIntoLab(hex: hex, label: label)
        statusMessage = "Loaded into Lab"
    }

    func vibrateBand() {
        playHex(PresetCatalog.vibratePacket, label: "Vibrate")
    }

    func clearLive() {
        livePackets.removeAll()
    }

    func clearIscanLive() {
        iscanUniqueLive.removeAll()
        iscanRawLive.removeAll()
    }

    func removeIscanUnique(dedupeKey: String) {
        iscanUniqueLive.removeAll { $0.dedupeKey == dedupeKey }
    }

    func removeIscanRaw(timestampMs: Int64, hex: String) {
        iscanRawLive.removeAll { $0.timestampMs == timestampMs && $0.hex == hex }
    }

    func setRelayBackend(_ backend: RelayBackend) {
        relayBackend = backend
        RelayBackend.save(backend)
        if !backend.usesWifiRelay {
            androidLivePackets = []
        }
        ble.reconnectRelay()
        refreshRelayStatus()
        statusMessage = "Relay: \(backend.label)"
    }

    func saveAndroidRelayIP(_ ip: String) {
        androidRelayIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        RelaySettings.androidRelayIP = androidRelayIP
        refreshRelayStatus()
    }

    var relayGattReady: Bool {
        ble.bleCentral.relayGatt.isReady
    }

    var relayCommandReady: Bool {
        switch relayBackend {
        case .androidBle:
            return ble.bleCentral.relayGatt.isCommandReady
        case .androidWifi:
            return androidRemote?.running == true
        }
    }

    var remoteLinkReady: Bool {
        switch relayBackend {
        case .androidBle:
            return relayCommandReady
        case .androidWifi:
            return androidRemote?.running == true
        }
    }

    func refreshRelayStatus() {
        relayBackend = RelayBackend.load()
        if relayBackend.usesWifiRelay {
            AndroidWifiRelayClient.shared.refreshStatus { [weak self] status in
                self?.relayStatus = status
            }
        } else {
            relayStatus = ble.relayStatus
        }
    }

    func reconnectRelay() {
        ble.reconnectRelay()
        refreshRelayStatus()
    }

    func refreshAndroidRemote() {
        let skipGattPoll = isCatalogSyncInFlight || ble.bleCentral.relayGatt.hasGattWorkQueued
        remote.refreshStatus(central: skipGattPoll ? nil : ble.bleCentral) { [weak self] status in
            Task { @MainActor in
                self?.androidRemote = status
                guard let status else { return }
                self?.wandDisplayColorIndex = status.wandDisplayColorIndex
                let revisionChanged = status.storeRevision != self?.lastCatalogRevision
                let catalogMissing = self?.androidCatalog == nil
                    || self?.androidCatalog?.transmitPresets.isEmpty == true
                if revisionChanged || catalogMissing {
                    self?.refreshAndroidCatalog()
                }
            }
        }
        if skipGattPoll { return }
        remote.fetchLivePackets(central: ble.bleCentral) { [weak self] packets in
            Task { @MainActor in
                self?.androidLivePackets = packets
            }
        }
    }

    func refreshAndroidCatalog() {
        guard relayCommandReady || relayCatalogReady else { return }
        guard !catalogFetchInFlight else { return }
        guard Date() >= catalogSyncCooldownUntil else { return }
        catalogFetchInFlight = true
        isCatalogSyncInFlight = true
        catalogSyncDiagnostic = "starting…"
        let pauseScanForSync = isLocalListening
        if pauseScanForSync {
            ble.updateModes(recording: isRecording, auto: isAutoEnabled, listening: false)
        }
        catalogFetchTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.catalogFetchInFlight else { return }
            self.catalogFetchInFlight = false
            self.isCatalogSyncInFlight = false
            if pauseScanForSync {
                self.syncBleListenModes()
            }
            if self.androidCatalog == nil {
                self.catalogSyncDiagnostic = "timed out"
                self.statusMessage = "Catalog sync timed out (\(self.catalogSyncDiagnostic)) — LINK → Refresh"
            }
        }
        catalogFetchTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: timeout)
        remote.fetchCatalog(central: ble.bleCentral, previousCatalog: androidCatalog, onDiagnostic: { [weak self] msg in
            Task { @MainActor in self?.catalogSyncDiagnostic = msg }
        }) { [weak self] catalog in
            Task { @MainActor in
                self?.catalogFetchTimeout?.cancel()
                if pauseScanForSync {
                    self?.syncBleListenModes()
                }
                defer {
                    self?.catalogFetchInFlight = false
                    self?.isCatalogSyncInFlight = false
                }
                guard let catalog, !catalog.transmitPresets.isEmpty else {
                    self?.catalogSyncCooldownUntil = Date().addingTimeInterval(30)
                    if self?.androidCatalog == nil {
                        let detail = self?.catalogSyncDiagnostic ?? "unknown"
                        self?.statusMessage = "Catalog sync failed (\(detail)) — LINK → Refresh"
                    }
                    return
                }
                self?.catalogSyncCooldownUntil = .distantPast
                self?.catalogSyncDiagnostic = "ok · \(catalog.transmitPresets.count) TX"
                self?.applyAndroidCatalogFromParsed(catalog)
            }
        }
    }

    private var relayCatalogReady: Bool {
        ble.bleCentral.relayGatt.isCatalogReady
    }

    private func applyAndroidCatalog(_ json: [String: Any]?) {
        guard let json, let catalog = AndroidRemoteCatalog.parse(json), !catalog.transmitPresets.isEmpty else { return }
        applyAndroidCatalogFromParsed(catalog)
    }

    private     func applyAndroidCatalogFromParsed(_ catalog: AndroidRemoteCatalog) {
        androidCatalog = catalog
        if let rev = androidRemote?.storeRevision, rev >= 0 {
            lastCatalogRevision = rev
        }
        if androidLabHex.isEmpty {
            androidLabHex = "8301CC03000100"
        }
        statusMessage = "Android library synced (\(catalog.transmitPresets.count) TX, \(catalog.wandColors.count) wand, \(catalog.autoRules.count) auto)"
    }

    func refreshAndroidAutoFromRemote() {
        refreshAndroidRemote()
        refreshAndroidCatalog()
    }

    func mbleTapAndroid(tokenHex: String, durationMs: Int = 5000) {
        remote.sendCommand("mble_tap", params: ["token": tokenHex, "durationMs": durationMs], central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "MBLE tap ADV via Android" : "MBLE tap failed"
            }
        }
    }

    func setAndroidScan(_ enabled: Bool) {
        remote.sendCommand("set_scan", params: ["enabled": enabled], central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "Android scan \(enabled ? "ON" : "OFF")" : "Scan command failed"
                self?.refreshAndroidRemote()
            }
        }
    }

    func transmitAndroidHex(_ hex: String) {
        if let idx = starlightDisplayIndex(for: hex) {
            applyWandDisplayColorIndex(idx)
        }
        remote.sendCommand("transmit", params: ["hex": HexUtils.canonicalHex(hex)], central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "TX → Android" : "Android TX failed"
                self?.refreshAndroidRemote()
            }
        }
    }

    func transmitAndroidWandColor(_ preset: AndroidRemotePreset, intervalMs: Int? = nil) {
        let colorIdx = MagicClassifier.starlightColorIndex(preset.hex) & 0x1F
        applyWandDisplayColorIndex(colorIdx)

        if androidRemote?.starlightLoopEnabled == true {
            setAndroidStarlightLoop(
                enabled: true,
                packetId: preset.id,
                intervalMs: intervalMs ?? Int(androidRemote?.starlightIntervalMs ?? 3000)
            )
            return
        }

        remote.sendCommand("transmit", params: ["hex": HexUtils.canonicalHex(preset.hex)], central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "Wand TX → Android" : "Android TX failed"
                self?.refreshAndroidRemote()
            }
        }
    }

    private func starlightDisplayIndex(for hex: String) -> Int? {
        guard HexUtils.isStarlightPacket(hex) else { return nil }
        return MagicClassifier.starlightColorIndex(hex) & 0x1F
    }

    private func applyWandDisplayColorIndex(_ index: Int) {
        let idx = index & 0x1F
        wandDisplayColorIndex = idx
        if var remote = androidRemote {
            remote.wandDisplayColorIndex = idx
            androidRemote = remote
        }
    }

    func interrogateAndroid() {
        remote.sendCommand("interrogate", central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "Interrogate sent" : "Interrogate failed"
            }
        }
    }

    func setAndroidStarlightLoop(enabled: Bool, packetId: Int64? = nil, intervalMs: Int? = nil) {
        var params: [String: Any] = ["enabled": enabled]
        if let packetId { params["packetId"] = packetId }
        if let intervalMs { params["intervalMs"] = intervalMs }
        remote.sendCommand("set_starlight_loop", params: params, central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "Wand loop \(enabled ? "ON" : "OFF")" : "Wand loop failed"
                self?.refreshAndroidRemote()
                self?.refreshAndroidCatalog()
            }
        }
    }

    func setAndroidTxLoop(enabled: Bool, packetId: Int64? = nil, intervalMs: Int? = nil) {
        var params: [String: Any] = ["enabled": enabled]
        if let packetId { params["packetId"] = packetId }
        if let intervalMs { params["intervalMs"] = intervalMs }
        remote.sendCommand("set_tx_loop", params: params, central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "TX loop \(enabled ? "ON" : "OFF")" : "TX loop failed"
                self?.refreshAndroidRemote()
            }
        }
    }

    func setAndroidWakeupPreamble(_ ms: Int) {
        remote.sendCommand("set_wakeup_preamble", params: ["ms": ms], central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "Preamble \(ms)ms" : "Preamble failed"
                self?.refreshAndroidRemote()
                self?.refreshAndroidCatalog()
            }
        }
    }

    func setAndroidCommandBurst(_ ms: Int) {
        remote.sendCommand("set_command_burst", params: ["ms": ms], central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "Command burst \(ms)ms" : "Burst failed"
                self?.refreshAndroidRemote()
                self?.refreshAndroidCatalog()
            }
        }
    }

    func setAndroidStarlightBurst(_ ms: Int) {
        remote.sendCommand("set_starlight_burst", params: ["ms": ms], central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "Starlight burst \(ms)ms" : "Starlight burst failed"
                self?.refreshAndroidRemote()
                self?.refreshAndroidCatalog()
            }
        }
    }

    func saveAndroidCustomPreset(label: String, hex: String) {
        let canonical = HexUtils.canonicalHex(hex)
        remote.sendCommand(
            "save_custom_preset",
            params: ["label": label, "hex": canonical],
            central: ble.bleCentral
        ) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "Added to Android TX library" : "Save to TX failed"
                if ok { self?.refreshAndroidCatalog() }
            }
        }
    }

    func removeAndroidRawLive(timestampMs: Int64, hex: String) {
        remote.sendCommand(
            "remove_raw_live",
            params: ["timestampMs": timestampMs, "hex": hex],
            central: ble.bleCentral
        ) { [weak self] ok in
            Task { @MainActor in
                if ok {
                    self?.androidLivePackets.removeAll { $0.timestampMs == timestampMs && $0.hex == hex }
                }
                self?.refreshAndroidRemote()
            }
        }
    }

    func removeAndroidUniqueLive(dedupeKey: String) {
        remote.sendCommand("remove_live", params: ["dedupeKey": dedupeKey], central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                if ok {
                    self?.androidLivePackets.removeAll { $0.dedupeKey == dedupeKey }
                }
                self?.refreshAndroidRemote()
            }
        }
    }

    func loadAndroidLabHex(_ hex: String) {
        androidLabHex = HexUtils.canonicalHex(hex)
    }

    var androidUniqueLivePackets: [AndroidRemotePacket] {
        LivePacketSort.groupedLiveUnique(androidLivePackets)
    }

    func deleteAndroidWandColor(_ packetId: Int64) {
        remote.sendCommand("delete_wand_color", params: ["packetId": packetId], central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "Wand color deleted" : "Delete failed"
                self?.refreshAndroidRemote()
                self?.refreshAndroidCatalog()
            }
        }
    }

    func clearAndroidWandLibrary() {
        remote.sendCommand("clear_wand_library", central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "Wand library cleared" : "Clear failed"
                self?.refreshAndroidRemote()
                self?.refreshAndroidCatalog()
            }
        }
    }

    func setAndroidAutoRuleEnabled(_ ruleId: Int64, enabled: Bool) {
        remote.sendCommand("set_auto_rule", params: ["ruleId": ruleId, "enabled": enabled], central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "Rule updated" : "Rule update failed"
                self?.refreshAndroidCatalog()
            }
        }
    }

    func deleteAndroidAutoRule(_ ruleId: Int64) {
        remote.sendCommand("delete_auto_rule", params: ["ruleId": ruleId], central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "Rule deleted" : "Delete failed"
                self?.refreshAndroidCatalog()
            }
        }
    }

    func setAndroidAuto(_ enabled: Bool) {
        remote.sendCommand("set_auto", params: ["enabled": enabled], central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "Android auto \(enabled ? "ON" : "OFF")" : "Android auto command failed"
                self?.refreshAndroidRemote()
            }
        }
    }

    func setAndroidRecording(_ enabled: Bool) {
        remote.sendCommand("set_recording", params: ["enabled": enabled], central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "Android log \(enabled ? "REC" : "OFF")" : "Android log command failed"
                self?.refreshAndroidRemote()
            }
        }
    }

    func clearAndroidLive() {
        remote.sendCommand("clear_live", central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "Android RX cleared" : "Clear failed"
                if ok { self?.androidLivePackets = [] }
                self?.refreshAndroidRemote()
            }
        }
    }

    func applyPairing(_ info: AndroidPairingInfo) {
        setRelayBackend(.androidWifi)
        saveAndroidRelayIP(info.ip.isEmpty ? "192.168.43.1" : info.ip)
        RelaySettings.androidRelayPort = info.port
        statusMessage = "Joining \(info.ssid)…"
        WiFiJoiner.join(ssid: info.ssid, password: info.password) { [weak self] msg in
            self?.statusMessage = msg
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self?.refreshAndroidRemote()
                self?.refreshAndroidCatalog()
                self?.refreshRelayStatus()
            }
        }
    }

    func fetchAndroidPairing(central: BleCentral? = nil) {
        let c = central ?? ble.bleCentral
        remote.fetchPairing(central: c) { [weak self] info in
            Task { @MainActor in
                guard let info else {
                    self?.statusMessage = "Pairing info unavailable"
                    return
                }
                self?.applyPairing(info)
            }
        }
    }

    func vibrateAndroid() {
        remote.sendCommand("vibrate", central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "Vibrate sent to Android" : "Vibrate failed"
            }
        }
    }
}
