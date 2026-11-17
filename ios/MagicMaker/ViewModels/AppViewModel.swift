import Combine
import Foundation
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    @Published var statusMessage = "Ready"
    @Published var relayStatus = "Not connected"
    @Published var relayBackend = RelayBackend.load()
    @Published var androidRelayIP = RelaySettings.androidRelayIP
    @Published private(set) var isCatalogSyncInFlight = false
    @Published private(set) var catalogSyncDiagnostic = ""
    @Published var androidRemote: AndroidRemoteStatus?
    @Published private(set) var wandDisplayColorIndex = 0x1B
    @Published var androidLivePackets: [AndroidRemotePacket] = []
    @Published var androidCatalog: AndroidRemoteCatalog?
    @Published var androidLabHex = ""
    /// Goes up when a packet is sent to the Lab from another screen, so the Lab reloads it.
    @Published var labLoadTick = 0
    /// A tab another screen asked the root view to show (`labTabId`); the root view clears it.
    @Published var requestedTab: String?
    static let labTabId = "lab"
    private var lastCatalogRevision = -1

    /// The iPhone's own library, preferences and capture logs.
    let store: MagicStore
    let location: LocationTracker
    /// The scan pipeline: live feed, learning, logging and auto-responses.
    let scan: ScanEngine
    /// Everything that sends, through the linked relay.
    let tx: TxEngine

    private lazy var ble: BleCoordinator = {
        let coordinator = BleCoordinator()
        coordinator.store = store
        coordinator.onPacket = { [weak self] hex, rssi, address in
            Task { @MainActor in self?.handlePacket(hex: hex, rssi: rssi, address: address) }
        }
        coordinator.onBluetoothState = { [weak self] state in
            Task { @MainActor in self?.scan.noteBluetoothStatus(state) }
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
    private var catalogFetchInFlight = false
    private var catalogFetchTimeout: DispatchWorkItem?
    private var catalogSyncCooldownUntil = Date.distantPast
    private var keepAwakeChangedAt = Date.distantPast
    /// The ping the relay streams while keep-awake is on.
    private var keepAwakeHex: String = PacketBuilder.wakeupPing
    private var lastRelayWandColorIndex: Int?

    init() {
        let store = MagicStore()
        store.prepareIfNeeded()
        let location = LocationTracker()
        self.store = store
        self.location = location
        self.scan = ScanEngine(store: store, location: location)
        self.tx = TxEngine(store: store)
        wireEngines()
    }

    /// Connects the engines to each other and to the relay link. The engines never talk to
    /// CoreBluetooth themselves.
    private func wireEngines() {
        tx.radioReady = { [weak self] in
            self?.remoteLinkReady ?? false
        }
        tx.radioSend = { [weak self] hex, durationMs, completion in
            guard let self else {
                completion(false)
                return
            }
            self.ble.send(hex: hex, durationMs: durationMs, onComplete: completion)
        }
        tx.onWandColor = { [weak self] index in
            self?.noteWandColor(index)
        }
        tx.scanWanted = { [weak self] in
            self?.scan.scanActive ?? false
        }
        scan.onAutoResponses = { [weak self] hexes, label in
            self?.tx.transmitSequence(hexes, label: label)
        }
        scan.onScanWanted = { [weak self] wanted in
            self?.scanWantedChanged(wanted)
        }
        scan.onWandColorHeard = { [weak self] index in
            self?.noteWandColor(index)
        }
    }

    /// The scan engine's switch changed: the radio starts or stops listening. The engine has
    /// already stored the new value, which `wantsLocalScan` reads.
    private func scanWantedChanged(_ wanted: Bool) {
        syncBleListenModes()
    }

    /// The wand view follows the last colour heard or sent.
    private func noteWandColor(_ index: Int) {
        if wandDisplayColorIndex != (index & 0x1F) {
            applyWandDisplayColorIndex(index)
        }
    }

    /// The relay reports the last wand colour it heard or sent with every status read. It is
    /// taken over only when it changes, so a colour the iPhone itself just heard or sent is
    /// not replaced by the relay's older one a moment later.
    private func adoptRelayWandColor(_ index: Int) {
        if lastRelayWandColorIndex == index { return }
        lastRelayWandColorIndex = index
        if wandDisplayColorIndex != index {
            wandDisplayColorIndex = index
        }
    }

    /// Deferred from init so CoreBluetooth, file I/O, and remote refresh run after UIKit finishes launching.
    // MARK: - New Wand custom names
    // The generated New Wand codes are near-identical color variations, so let the user name
    // them. Names are keyed by the (uppercased) hex. Stored as Android stores them (one JSON
    // object in "newwand_names"), so they travel in the library file both ways.
    @Published private(set) var newWandNames: [String: String] = [:]
    private let newWandNamesKey = "newwand_names"
    /// Where earlier iOS builds kept the names, as a dictionary the library file cannot carry.
    private let legacyNewWandNamesKey = "newwand_names_v1"
    /// The stored text the current names were read from.
    private var newWandNamesText: String? = nil

    func newWandDisplayName(for preset: AndroidRemotePreset) -> String {
        if let n = newWandNames[preset.hex.uppercased()], !n.isEmpty { return n }
        return preset.label
    }

    func setNewWandName(hex: String, name: String) {
        let key = hex.uppercased()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            newWandNames.removeValue(forKey: key)
        } else {
            newWandNames[key] = trimmed
        }
        saveNewWandNames()
    }

    private func saveNewWandNames() {
        var text = "{}"
        if let data = try? JSONSerialization.data(withJSONObject: newWandNames, options: [.sortedKeys]),
           let encoded = String(data: data, encoding: .utf8) {
            text = encoded
        }
        newWandNamesText = text
        UserDefaults.standard.set(text, forKey: newWandNamesKey)
    }

    private func loadNewWandNames() {
        let defaults = UserDefaults.standard
        if let text = defaults.string(forKey: newWandNamesKey) {
            newWandNamesText = text
            newWandNames = Self.parseNewWandNames(text)
            return
        }
        newWandNamesText = nil
        let legacy: [String: String] = (defaults.dictionary(forKey: legacyNewWandNamesKey) as? [String: String]) ?? [:]
        newWandNames = legacy
        if !legacy.isEmpty {
            saveNewWandNames()
            defaults.removeObject(forKey: legacyNewWandNamesKey)
        }
    }

    /// Importing a library file can replace the stored names; re-read them when the text changed.
    func reloadNewWandNamesIfChanged() {
        let text: String? = UserDefaults.standard.string(forKey: newWandNamesKey)
        if text == newWandNamesText { return }
        loadNewWandNames()
    }

    private static func parseNewWandNames(_ text: String) -> [String: String] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var out: [String: String] = [:]
        for (key, value) in object {
            if let name = value as? String {
                out[key.uppercased()] = name
            }
        }
        return out
    }

    // MARK: - Wand quick button (defaults to the New Wand "Off" code 6F1D; reprogrammable)
    static let defaultWandQuickHex = "8301CF0B00C020224EAC7807866F1D"
    @Published private(set) var wandQuickLabel = UserDefaults.standard.string(forKey: "wand_quick_label") ?? "OFF"
    @Published private(set) var wandQuickHex = UserDefaults.standard.string(forKey: "wand_quick_hex") ?? AppViewModel.defaultWandQuickHex

    func setWandQuick(label: String, hex: String) {
        let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
        wandQuickLabel = l.isEmpty ? "OFF" : l
        wandQuickHex = HexUtils.canonicalHex(hex)
        UserDefaults.standard.set(wandQuickLabel, forKey: "wand_quick_label")
        UserDefaults.standard.set(wandQuickHex, forKey: "wand_quick_hex")
    }

    func transmitWandQuick() {
        transmitAndroidHex(wandQuickHex)
    }

    func bootstrapAfterLaunch() {
        _ = ble
        loadNewWandNames()
        loadCachedCatalog()          // reuse the saved library so we don't re-pull it every launch
        ble.activateBluetooth()
        refreshRelayStatus()
        refreshAndroidRemote()
        location.start()             // each captured packet is tagged with where it was heard
        scan.noteBluetoothStatus(ble.bluetoothState)
        syncShowControlFilter()
        scan.start()                 // scanning and logging resume as the user left them (on by default)
        tx.start()
        if scan.scanActive {
            reconnectRelay()
        }
    }

    /// The scan filter switch belongs to the scan engine. A choice made with the older iPhone
    /// scan screen's switch (`iscan_show_control_only`) before the engine had one is kept.
    private func syncShowControlFilter() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "show_control_only") != nil { return }
        if defaults.object(forKey: "iscan_show_control_only") == nil { return }
        scan.showControlOnly = defaults.bool(forKey: "iscan_show_control_only")
    }

    var remoteLinkHint: String {
        switch relayBackend {
        case .esp32:
            if relayGattReady { return "" }
            if ble.bleCentral.relayGatt.isLinkInProgress { return "Finishing ESP32 link…" }
            return "Power on the ESP32 — tap Retry BLE."
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

    private func handlePacket(hex: String, rssi: Int, address: String) {
        if isRelayEcho(hex) { return }
        // The scan engine learns, logs and answers every heard packet.
        scan.handleHeard(hex: hex, rssi: rssi, address: address)
    }

    /// True for a packet the linked relay is broadcasting for this iPhone. An Android phone
    /// never hears its own broadcasts and pauses its scan for a whole replay; here the relay
    /// is a second radio, so its output would be learned, logged and answered as if heard.
    private func isRelayEcho(_ hex: String) -> Bool {
        if tx.replayActive { return true }
        let sending: Bool = tx.isTransmitting
        if !sending && !keepAwakeActive { return false }
        let canonical = HexUtils.canonicalHex(hex)
        if keepAwakeActive && canonical == keepAwakeHex { return true }
        if sending {
            // The packet on air, or the wake ping the relay sends ahead of it.
            return canonical == tx.lastTransmitHex || canonical == PacketBuilder.wakeupPing
        }
        return false
    }

    func ensureRelayLink() {
        ble.ensureRelayLink()
    }

    /// The radio listens while the scan engine wants packets.
    private var wantsLocalScan: Bool {
        scan.scanActive
    }

    private func syncBleListenModes() {
        // Auto-responses come from the scan engine alone, so the coordinator's own responder
        // stays switched off and a packet is never answered twice.
        ble.updateModes(recording: false, auto: false, listening: wantsLocalScan)
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

    /// Sends a packet to the Lab from another screen: it becomes the Lab's packet (with its
    /// label), the Lab reloads, and the root view is asked to show the Lab tab.
    func loadInLab(hex: String, label: String) {
        let canonical = HexUtils.canonicalHex(hex)
        store.loadIntoLab(hex: canonical, label: label)
        androidLabHex = canonical
        labLoadTick += 1
        requestedTab = AppViewModel.labTabId
        statusMessage = "Loaded into Lab"
    }

    /// Adds the packets of the linked Android phone's library that the iPhone does not have
    /// yet. Returns how many were added.
    @discardableResult
    func importAndroidLibrary() -> Int {
        guard let catalog = androidCatalog else {
            statusMessage = "No Android library synced yet — LINK → Refresh"
            return 0
        }
        let added: Int = store.importAndroidCatalog(catalog)
        if added > 0 {
            statusMessage = "Imported \(added) packets from the Android library"
        } else {
            statusMessage = "Android library already imported"
        }
        return added
    }

    func vibrateBand() {
        playHex(PresetCatalog.vibratePacket, label: "Vibrate")
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
        case .androidBle, .esp32:
            return ble.bleCentral.relayGatt.isCommandReady
        case .androidWifi:
            return androidRemote?.running == true
        }
    }

    var remoteLinkReady: Bool {
        switch relayBackend {
        case .androidBle, .esp32:
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
                self?.reconcileKeepAwake(status.keepAwake)
                self?.adoptRelayWandColor(status.wandDisplayColorIndex)
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
        // The ESP32 hosts no catalog, so never try to pull one over it — that would just fail and
        // spin. Rely on the persisted cache (synced once from Android) instead.
        guard relayBackend != .esp32 else { return }
        guard relayCommandReady || relayCatalogReady else { return }
        guard !catalogFetchInFlight else { return }
        guard Date() >= catalogSyncCooldownUntil else { return }
        catalogFetchInFlight = true
        isCatalogSyncInFlight = true
        catalogSyncDiagnostic = "starting…"
        let pauseScanForSync = wantsLocalScan
        if pauseScanForSync {
            ble.updateModes(recording: false, auto: false, listening: false)
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
        persistCatalog(catalog, revision: lastCatalogRevision)
        statusMessage = "Android library synced (\(catalog.transmitPresets.count) TX, \(catalog.wandColors.count) wand, \(catalog.autoRules.count) auto)"
    }

    // MARK: - Catalog persistence
    //
    // Save the synced library (known presets + wand colors, NOT raw/unknown) to disk so the
    // phone doesn't re-pull it over BLE every launch. This is what makes an ESP32-only setup
    // usable: the ESP32 has no catalog, so we sync once from Android, then reuse the cache.

    private let catalogCacheKey = "android_catalog_cache_v2"

    private func persistCatalog(_ catalog: AndroidRemoteCatalog, revision: Int) {
        var trimmed = catalog
        // Keep only known packets — drop raw/unknown so the saved library stays clean.
        trimmed.transmitPresets = catalog.transmitPresets.filter { !isRawOrUnknown($0) }
        trimmed.wandColors = catalog.wandColors.filter { !isRawOrUnknown($0) }
        let payload = CachedCatalog(catalog: trimmed, revision: revision)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: catalogCacheKey)
    }

    private func loadCachedCatalog() {
        guard androidCatalog == nil,
              let data = UserDefaults.standard.data(forKey: catalogCacheKey),
              let payload = try? JSONDecoder().decode(CachedCatalog.self, from: data),
              !payload.catalog.transmitPresets.isEmpty || !payload.catalog.wandColors.isEmpty
        else { return }
        androidCatalog = payload.catalog
        lastCatalogRevision = payload.revision
    }

    private func isRawOrUnknown(_ p: AndroidRemotePreset) -> Bool {
        p.category.uppercased() == "UNKNOWN" || p.typeInfo.lowercased() == "raw"
    }

    private struct CachedCatalog: Codable {
        let catalog: AndroidRemoteCatalog
        let revision: Int
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

    /// Keep-awake runs on the relay (Android or ESP32): it pauses scanning there and streams a
    /// wake/control ping; a send goes out for the command interval with no preamble, then the
    /// pings resume. iOS can't broadcast manufacturer data itself.
    @Published var keepAwakeActive = false

    func setKeepAwake(_ enabled: Bool, hex: String = PacketBuilder.wakeupPing) {
        keepAwakeActive = enabled
        keepAwakeChangedAt = Date()
        let pingHex = HexUtils.canonicalHex(hex)
        // The relay keeps its earlier ping when it is given one too short to be a packet.
        if pingHex.count >= 8 { keepAwakeHex = pingHex }
        remote.sendCommand("keep_awake", params: ["enabled": enabled, "hex": pingHex], central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                if !ok { self?.keepAwakeActive = !enabled }
                self?.statusMessage = ok ? (enabled ? "Keeping band awake" : "Keep-awake off") : "Keep-awake command failed"
            }
        }
    }

    /// The switch follows what the relay reports, so it is right after a relaunch or when the
    /// relay dropped keep-awake by itself. A status read around the time of a tap may predate
    /// it and is ignored.
    private func reconcileKeepAwake(_ reported: Bool?) {
        guard let reported else { return }
        if Date().timeIntervalSince(keepAwakeChangedAt) < 4 { return }
        if keepAwakeActive != reported {
            keepAwakeActive = reported
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

    /// Sends one settings command to the linked Android relay, which applies it to its own radio
    /// or scan filter (`set_tx_power {level}`, `set_tx_interleave {enabled}`,
    /// `set_show_control_only {enabled}`).
    func sendRelaySetting(_ action: String, _ params: [String: Any]) {
        remote.sendCommand(action, params: params, central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "Relay \(action) OK" : "Relay \(action) failed"
                if ok { self?.refreshAndroidRemote() }
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
