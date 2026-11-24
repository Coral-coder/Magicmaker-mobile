import Combine
import Foundation
import SwiftUI
import UIKit

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
    /// Firmware updates for the linked ESP32 over Bluetooth (SETTINGS → BOARD FIRMWARE).
    let firmware: FirmwareUpdater
    /// Every firmware-update change is announced as this model's, so both themes' SETTINGS follow.
    private var firmwareChanges: AnyCancellable?

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
                // A new link may be to an updated relay.
                self?.relayLacksRawBurst = false
                // The ESP32 keeps its settings in RAM only: they are checked again on every link.
                self?.esp32SettingsPushed = false
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
    /// When the last catalog sync finished; revision-driven re-syncs wait a minute after it.
    private var lastCatalogSyncAt = Date.distantPast
    /// Tags each catalog sync, so a late result of one that timed out changes nothing.
    private var catalogSyncToken = 0
    /// The iPhone's TX settings were given to the Android relay on this link.
    private var relaySettingsPushed = false
    /// The relay refused raw_burst on this link (an older build), so replay steps use plain sends.
    private var relayLacksRawBurst = false
    private var keepAwakeChangedAt = Date.distantPast
    /// The ping the relay streams while keep-awake is on.
    private var keepAwakeHex: String = PacketBuilder.wakeupPing
    private var lastRelayWandColorIndex: Int?
    /// The linked ESP32's STATUS is a bare {"ok":true}: firmware before 1.2, no chip-side loops.
    @Published private(set) var esp32FirmwareOutdated = false
    private var esp32StatusMisses = 0
    private var esp32SettingsPushed = false
    /// Keep-awake and loop changes made while the ESP32 was not linked; sent in order when it links.
    private var pendingEsp32Commands: [(action: String, params: [String: Any])] = []

    /// Opt-in "Keep running in background" (SETTINGS). Device-only: capitalised key, kept out of library exports.
    private static let keepRunningInBackgroundKey = "MMKeepRunningInBackground"
    @Published private(set) var keepRunningInBackground: Bool = UserDefaults.standard.bool(forKey: "MMKeepRunningInBackground")
    @Published private(set) var backgroundKeepAlive: BackgroundKeepAlive = .off
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// What "Keep running in background" is doing right now (SETTINGS → BACKGROUND).
    enum BackgroundKeepAlive: Equatable {
        case off, needsLocation, idle, running

        var text: String {
            switch self {
            case .off: return "OFF — iOS suspends MagicMaker soon after you leave it."
            case .needsLocation: return "NEEDS LOCATION — allow Location “While Using” for MagicMaker in iOS Settings."
            case .idle: return "ON — no loop, show or replay is running on this iPhone, so iOS may suspend the app."
            case .running: return "ON — MagicMaker keeps running in the background (blue location indicator)."
            }
        }
    }

    static let backgroundKeepAliveNote: String = "Uses background location to keep MagicMaker running while you use other apps or lock the phone — only while this iPhone is sending something itself: a TX or wand loop it times for an Android relay, the random show, a replay or a send in progress. Scanning and logging don't count: iPhone limit — iOS does not pass band or wand packets to apps in the background, so this iPhone hears and records nothing new, and auto-responses don't fire, until you come back to MagicMaker. Keep-awake and the ESP32's loops run on the relay by themselves, and an Android relay keeps scanning on its own. Uses extra battery."

    init() {
        let store = MagicStore()
        store.prepareIfNeeded()
        let location = LocationTracker()
        self.store = store
        self.location = location
        self.scan = ScanEngine(store: store, location: location)
        self.tx = TxEngine(store: store)
        self.firmware = FirmwareUpdater()
        wireEngines()
        firmwareChanges = firmware.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Connects the engines to each other and to the relay link. The engines never talk to
    /// CoreBluetooth themselves.
    private func wireEngines() {
        tx.radioReady = { [weak self] in
            self?.remoteLinkReady ?? false
        }
        tx.keepAwakeOn = { [weak self] in
            self?.keepAwakeActive ?? false
        }
        tx.radioSend = { [weak self] hex, durationMs, completion in
            guard let self else {
                completion(false)
                return
            }
            // The ESP32 clamps a TX write to 60...12000 ms (0 means its default for the packet).
            let onAirMs: Int = self.relayBackend == .esp32 ? max(durationMs, 60) : durationMs
            self.ble.send(hex: hex, durationMs: onAirMs, onComplete: completion)
        }
        tx.radioBurst = { [weak self] hex, durationMs, completion in
            guard let self else {
                completion(false)
                return
            }
            self.sendRawBurst(hex: hex, durationMs: durationMs, completion: completion)
        }
        tx.onWandColor = { [weak self] index in
            self?.noteWandColor(index)
        }
        tx.scanWanted = { [weak self] in
            self?.scan.scanActive ?? false
        }
        tx.relayRunsLoops = { [weak self] in
            self?.relayBackend == .esp32
        }
        tx.relayLoopChanged = { [weak self] loop, enabled, hex, label, intervalMs in
            self?.relayLoopChanged(loop, enabled: enabled, hex: hex, label: label, intervalMs: intervalMs)
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
        // A firmware transfer has the radio to itself (the local scan pauses) and keeps the
        // screen on through the TX engine's idle-timer hold.
        firmware.onBusyChanged = { [weak self] _ in
            self?.syncBleListenModes()
        }
        tx.screenHoldWanted = { [weak self] in
            self?.firmware.holdsScreen ?? false
        }
        firmware.onScreenHoldChanged = { [weak self] in
            self?.tx.refreshIdleTimer()
        }
    }

    /// A replay step through the relay: the packet alone for exactly durationMs, no wake. An older
    /// Android relay refuses raw_burst, and ESP32 firmware before 1.2 acknowledges it without
    /// sending; both get the step as an ordinary send instead.
    private func sendRawBurst(hex: String, durationMs: Int, completion: @escaping (Bool) -> Void) {
        if relayLacksRawBurst || (relayBackend == .esp32 && esp32FirmwareOutdated) {
            tx.radioSend(hex, durationMs, completion)
            return
        }
        let ms: Int = min(max(durationMs, 60), 10_000)
        let params: [String: Any] = ["hex": hex, "durationMs": ms]
        remote.sendCommand("raw_burst", params: params, central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                guard let self else {
                    completion(false)
                    return
                }
                if ok {
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) {
                        completion(true)
                    }
                } else {
                    // Only an older Android relay lacks raw_burst. The ESP32 (1.2+) always takes it,
                    // so a refusal there (a full command queue, a bad packet) costs this step alone
                    // instead of sending the rest of the replay with a wake preamble.
                    if self.relayBackend != .esp32 { self.relayLacksRawBurst = true }
                    self.tx.radioSend(hex, durationMs, completion)
                }
            }
        }
    }

    /// The scan engine's switch changed: the radio starts or stops listening. The engine has
    /// already stored the new value, which `wantsLocalScan` reads.
    private func scanWantedChanged(_ wanted: Bool) {
        syncBleListenModes()
        tx.refreshIdleTimer()
        updateBackgroundKeepAlive()
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
        // A library import may have replaced the stored names; edit those, not older ones.
        reloadNewWandNamesIfChanged()
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

    /// Importing a library file can replace the stored quick button; re-read it.
    func reloadWandQuickIfChanged() {
        let defaults = UserDefaults.standard
        let label: String = defaults.string(forKey: "wand_quick_label") ?? "OFF"
        let hex: String = defaults.string(forKey: "wand_quick_hex") ?? AppViewModel.defaultWandQuickHex
        if wandQuickLabel != label { wandQuickLabel = label }
        if wandQuickHex != hex { wandQuickHex = hex }
    }

    func transmitWandQuick() {
        transmitAndroidHex(wandQuickHex)
    }

    func bootstrapAfterLaunch() {
        _ = ble
        // Before Bluetooth starts, so the first link's OTA characteristic is seen.
        firmware.attach(to: ble.bleCentral.relayGatt)
        firmware.catalog.loadIfNeeded()
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
        observeAppLifecycle()
        updateBackgroundKeepAlive()
    }

    // MARK: - Keep running in background

    func setKeepRunningInBackground(_ on: Bool) {
        if keepRunningInBackground != on { keepRunningInBackground = on }
        UserDefaults.standard.set(on, forKey: Self.keepRunningInBackgroundKey)
        // Asks for the permission when it was never asked; a refusal shows NEEDS LOCATION.
        if on && !location.isAuthorized { location.start() }
        updateBackgroundKeepAlive()
    }

    /// This iPhone itself is sending something that would stop if iOS suspended the app: a TX or
    /// wand loop it times (every relay but the ESP32, which runs its loops on the chip), the random
    /// show, a replay or a send in progress. Scanning and logging are not counted: in the background
    /// the scan only looks for the relay (BleCentral.startScan) and iOS passes no band or wand
    /// packets, so they would only keep location on (scan is on by default). Keep-awake streams on
    /// the relay, and the relay link holds through `bluetooth-central` without this.
    private var backgroundWorkActive: Bool {
        let phoneLoops: Bool = relayBackend != .esp32 && (tx.txLoopEnabled || tx.starlightLoopEnabled)
        return phoneLoops || tx.randomShowEnabled || tx.replayActive || tx.isTransmitting
    }

    /// Background location runs only while the setting is on and there is work; otherwise iOS may
    /// suspend the app as usual. Idempotent: the 2 s relay poll calls it too.
    func updateBackgroundKeepAlive() {
        let work: Bool = backgroundWorkActive
        location.setBackgroundKeepAlive(keepRunningInBackground && work)
        let next: BackgroundKeepAlive
        if !keepRunningInBackground {
            next = .off
        } else if !location.isAuthorized {
            next = .needsLocation
        } else if !work {
            next = .idle
        } else {
            next = .running
        }
        if backgroundKeepAlive != next { backgroundKeepAlive = next }
    }

    private func observeAppLifecycle() {
        if !lifecycleObservers.isEmpty { return }
        let center: NotificationCenter = NotificationCenter.default
        let toBackground: NSObjectProtocol = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.appLifecycleChanged(background: true)
            }
        }
        let toForeground: NSObjectProtocol = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.appLifecycleChanged(background: false)
            }
        }
        lifecycleObservers = [toBackground, toForeground]
    }

    /// Decided with the work running right now before the tracker hears about the move, so
    /// updates that should keep the app alive are never stopped on the way to the background.
    private func appLifecycleChanged(background: Bool) {
        updateBackgroundKeepAlive()
        location.setAppInBackground(background)
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
            if esp32FirmwareOutdated { return "Reflash the ESP32 — its firmware has no chip-side loops." }
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

    /// The radio listens while the scan engine wants packets, except during a firmware transfer.
    private var wantsLocalScan: Bool {
        scan.scanActive && !firmware.isBusy
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
        // Read before saving: afterwards both hold the new value.
        let previous: RelayBackend = RelayBackend.load()
        let changed: Bool = backend != previous
        // The ESP32 keeps running a keep-awake stream or loop by itself after the switch.
        let esp32LeftRunning: Bool = changed && previous == .esp32
            && (keepAwakeActive || tx.txLoopEnabled || tx.starlightLoopEnabled)
        relayBackend = backend
        RelayBackend.save(backend)
        if changed {
            androidRemote = nil
            relaySettingsPushed = false
            relayLacksRawBurst = false
            pendingEsp32Commands = []
            esp32SettingsPushed = false
            esp32FirmwareOutdated = false
            esp32StatusMisses = 0
            if keepAwakeActive { keepAwakeActive = false }
            // A link to the other relay would keep taking every send and command: drop it so
            // discovery starts over for the selected backend.
            if let manager = ble.bleCentral.activateIfNeeded() {
                ble.bleCentral.relayGatt.resetForRetry(central: manager)
            }
            // The ESP32 runs the TX and wand loops itself; every other relay takes them from
            // this iPhone's timers.
            if previous == .esp32 { tx.clearRelayLoops() }
            if backend == .esp32 { tx.handOverLoopsToRelay() }
        }
        if !backend.usesWifiRelay {
            androidLivePackets = []
        }
        ble.reconnectRelay()
        refreshRelayStatus()
        statusMessage = esp32LeftRunning
            ? "Relay: \(backend.label) — the ESP32 keeps running its keep-awake or loop until it relinks or is power-cycled"
            : "Relay: \(backend.label)"
        updateBackgroundKeepAlive()
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

    /// The ESP32 is the selected backend and its relay link takes commands (BOARD FIRMWARE).
    var esp32Linked: Bool {
        relayBackend == .esp32 && relayCommandReady
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
        // A skipped GATT poll reads nothing, so the last status stays on LINK until the next one.
        if skipGattPoll && !relayBackend.usesWifiRelay { return }
        remote.refreshStatus(central: skipGattPoll ? nil : ble.bleCentral) { [weak self] status in
            Task { @MainActor in
                // STATUS can serve a command reply instead of the status (nil here); keep the
                // last status while the BLE link is up. WiFi, or a link that is down, clears it.
                if let status {
                    self?.androidRemote = status
                } else if self?.relayBackend == .androidWifi || self?.relayGattReady != true {
                    self?.androidRemote = nil
                }
                // Only a link that is really down resets this: a skipped GATT poll also gives nil.
                if self?.remoteLinkReady != true {
                    self?.relaySettingsPushed = false
                    self?.esp32SettingsPushed = false
                }
                if let self, self.relayBackend == .esp32 {
                    self.esp32StatusRead(status)
                    return
                }
                guard let status else { return }
                self?.pushRelaySettingsIfNeeded()
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
        // The ESP32 does not scan, so it has no live feed.
        if skipGattPoll || relayBackend == .esp32 { return }
        remote.fetchLivePackets(central: ble.bleCentral) { [weak self] packets in
            Task { @MainActor in
                self?.androidLivePackets = packets
            }
        }
    }

    /// Settings changed on the iPhone while no Android relay took commands. The relay sends with
    /// its own stored values, so these are given to it on the next link; untouched settings are
    /// never pushed, so the Android keeps its own tuning. Capitalised: kept out of library exports.
    private static let pendingRelaySettingsKey = "MMRelayPendingSettings"

    /// SETTINGS calls this when a TX setting changes with no Android relay linked.
    func noteRelaySettingPending(_ name: String) {
        let defaults = UserDefaults.standard
        var pending: [String] = defaults.stringArray(forKey: Self.pendingRelaySettingsKey) ?? []
        if !pending.contains(name) { pending.append(name) }
        defaults.set(pending, forKey: Self.pendingRelaySettingsKey)
    }

    /// Once per link, sends the settings changed on the iPhone while the relay was away.
    private func pushRelaySettingsIfNeeded() {
        guard relayBackend != .esp32, remoteLinkReady, !relaySettingsPushed else { return }
        relaySettingsPushed = true
        let defaults = UserDefaults.standard
        let pending: [String] = defaults.stringArray(forKey: Self.pendingRelaySettingsKey) ?? []
        if pending.isEmpty { return }
        defaults.removeObject(forKey: Self.pendingRelaySettingsKey)
        for name in pending {
            switch name {
            case "tx_power":
                sendRelaySetting("set_tx_power", ["level": store.getTxPowerLevel()])
            case "tx_interleave":
                sendRelaySetting("set_tx_interleave", ["enabled": store.getTxInterleave()])
            case "show_control_only":
                sendRelaySetting("set_show_control_only", ["enabled": store.getShowControlOnly()])
            case "wakeup_preamble":
                setAndroidWakeupPreamble(store.getWakeupPreambleMs())
            case "command_burst":
                setAndroidCommandBurst(store.getCommandBurstMs())
            case "starlight_burst":
                setAndroidStarlightBurst(store.getStarlightBurstMs())
            default:
                break
            }
        }
    }

    // MARK: - ESP32 chip-side programs

    /// One ESP32 status poll: a real status (firmware 1.2+) is reconciled; three polls in a row
    /// without one on a live link mean older firmware, which answers STATUS with a bare {"ok":true}.
    private func esp32StatusRead(_ status: AndroidRemoteStatus?) {
        if let status {
            esp32StatusMisses = 0
            if esp32FirmwareOutdated { esp32FirmwareOutdated = false }
            reconcileEsp32(status)
            return
        }
        // Counted on a finished link only (STATUS found), so a link still being set up is no miss.
        guard relayCommandReady else {
            esp32StatusMisses = 0
            return
        }
        esp32StatusMisses += 1
        if esp32StatusMisses >= 3 && !esp32FirmwareOutdated {
            esp32FirmwareOutdated = true
            statusMessage = "ESP32 firmware is outdated — reflash it (firmware/esp32-transmitter)"
        }
    }

    /// The iPhone is the authority for the ESP32's settings (held in its RAM only), and the chip
    /// for what it runs: settings that differ are pushed once per link, changes made while it was
    /// away go out next, and otherwise the switches follow what the chip reports.
    private func reconcileEsp32(_ s: AndroidRemoteStatus) {
        if !esp32SettingsPushed {
            esp32SettingsPushed = true
            let preambleMs: Int = store.getWakeupPreambleMs()
            if s.wakeupPreambleMs != preambleMs { setAndroidWakeupPreamble(preambleMs) }
            let burstMs: Int = store.getCommandBurstMs()
            if s.commandBurstMs != burstMs { setAndroidCommandBurst(burstMs) }
            let starlightMs: Int = store.getStarlightBurstMs()
            if s.starlightBurstMs != starlightMs { setAndroidStarlightBurst(starlightMs) }
            let level: Int = store.getTxPowerLevel()
            if let reported = s.txPowerLevel, reported != level {
                sendRelaySetting("set_tx_power", ["level": level])
            }
            let interleave: Bool = store.getTxInterleave()
            if let reported = s.txInterleave, reported != interleave {
                sendRelaySetting("set_tx_interleave", ["enabled": interleave])
            }
        }
        if !pendingEsp32Commands.isEmpty {
            let pending = pendingEsp32Commands
            pendingEsp32Commands = []
            keepAwakeChangedAt = Date()
            for item in pending {
                sendEsp32Program(item.action, item.params)
            }
            // This status predates them; the next one shows the result.
            return
        }
        // A status read around the time of a change may predate it.
        if Date().timeIntervalSince(keepAwakeChangedAt) < 4 { return }
        let awake: Bool = s.keepAwake ?? false
        if keepAwakeActive != awake { keepAwakeActive = awake }
        if awake, let hex = s.keepAwakeHex, !hex.isEmpty {
            keepAwakeHex = HexUtils.canonicalHex(hex)
        }
        tx.adoptRelayLoops(
            txOn: s.txLoopEnabled,
            txHex: s.txLoopHex,
            txLabel: s.txLoopLabel,
            txIntervalMs: Int(clamping: s.txLoopIntervalMs),
            wandOn: s.starlightLoopEnabled,
            wandHex: s.starlightLoopHex,
            wandLabel: s.starlightLoopLabel,
            wandIntervalMs: Int(clamping: s.starlightIntervalMs)
        )
    }

    /// The TX engine changed a loop the ESP32 runs: the chip is told (now, or when it links).
    private func relayLoopChanged(_ loop: TxEngine.RelayLoop, enabled: Bool, hex: String?, label: String, intervalMs: Int) {
        let action: String
        switch loop {
        case .tx: action = "set_tx_loop"
        case .wand: action = "set_starlight_loop"
        }
        var params: [String: Any] = ["enabled": enabled]
        if enabled {
            guard let hex else { return }
            params["hex"] = HexUtils.canonicalHex(hex)
            params["intervalMs"] = intervalMs
            if !label.isEmpty { params["label"] = label }
            // The chip runs one program at a time: a loop ends its keep-awake stream.
            if keepAwakeActive { keepAwakeActive = false }
        }
        keepAwakeChangedAt = Date()
        sendEsp32Program(action, params)
    }

    /// set_tx_loop / set_starlight_loop for the ESP32: the packet itself and its label, no `packetId`.
    private func esp32LoopParams(enabled: Bool, intervalMs: Int?, hex: String?, label: String?) -> [String: Any] {
        var params: [String: Any] = ["enabled": enabled]
        if let hex, !hex.isEmpty { params["hex"] = HexUtils.canonicalHex(hex) }
        if let label, !label.isEmpty { params["label"] = label }
        if let intervalMs { params["intervalMs"] = intervalMs }
        return params
    }

    /// Sends a keep-awake or loop command to the ESP32. While it is not linked the newest command
    /// of each kind waits, and they go out in order on the next link.
    private func sendEsp32Program(_ action: String, _ params: [String: Any]) {
        guard remoteLinkReady else {
            pendingEsp32Commands.removeAll { $0.action == action }
            pendingEsp32Commands.append((action: action, params: params))
            statusMessage = "ESP32 not linked — sent when it links"
            return
        }
        let name: String
        switch action {
        case "keep_awake": name = "keep-awake"
        case "set_tx_loop": name = "TX loop"
        case "set_starlight_loop": name = "wand loop"
        default: name = action
        }
        let on: Bool = params["enabled"] as? Bool ?? false
        remote.sendCommand(action, params: params, central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "ESP32 \(name) \(on ? "ON" : "OFF")" : "ESP32 \(action) failed"
                self?.refreshAndroidRemote()
            }
        }
    }

    /// `force` (LINK → Refresh) skips the wait between re-syncs.
    func refreshAndroidCatalog(force: Bool = false) {
        // The ESP32 hosts no catalog, so never try to pull one over it — that would just fail and
        // spin. Rely on the persisted cache (synced once from Android) instead.
        guard relayBackend != .esp32 else { return }
        guard relayCommandReady || relayCatalogReady else { return }
        guard !catalogFetchInFlight else { return }
        guard Date() >= catalogSyncCooldownUntil else { return }
        // A scanning relay changes its library every few seconds. With a catalog in hand,
        // re-syncs wait a minute and the local scan keeps running during them.
        let haveCatalog: Bool = !(androidCatalog?.transmitPresets.isEmpty ?? true)
        let sinceLastSync: TimeInterval = Date().timeIntervalSince(lastCatalogSyncAt)
        if !force && haveCatalog && sinceLastSync < 60 { return }
        catalogSyncToken += 1
        let token: Int = catalogSyncToken
        catalogFetchInFlight = true
        isCatalogSyncInFlight = true
        catalogSyncDiagnostic = "starting…"
        let pauseScanForSync: Bool = wantsLocalScan && !haveCatalog
        if pauseScanForSync {
            ble.updateModes(recording: false, auto: false, listening: false)
        }
        catalogFetchTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.catalogSyncToken == token, self.catalogFetchInFlight else { return }
            // The chunk transfer cannot be cancelled: its late result is ignored (new token), and
            // the cooldown keeps the next poll from queueing a second transfer behind it.
            self.catalogSyncToken += 1
            self.catalogSyncCooldownUntil = Date().addingTimeInterval(30)
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
                // A sync that timed out changes nothing: no timer, no scan, no flags.
                guard let self, self.catalogSyncToken == token else { return }
                timeout.cancel()
                if pauseScanForSync {
                    self.syncBleListenModes()
                }
                defer {
                    self.catalogFetchInFlight = false
                    self.isCatalogSyncInFlight = false
                }
                guard let catalog, !catalog.transmitPresets.isEmpty else {
                    self.catalogSyncCooldownUntil = Date().addingTimeInterval(30)
                    if self.androidCatalog == nil {
                        let detail: String = self.catalogSyncDiagnostic
                        self.statusMessage = "Catalog sync failed (\(detail)) — LINK → Refresh"
                    }
                    return
                }
                self.catalogSyncCooldownUntil = .distantPast
                self.lastCatalogSyncAt = Date()
                self.catalogSyncDiagnostic = "ok · \(catalog.transmitPresets.count) TX"
                self.applyAndroidCatalogFromParsed(catalog)
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
        let via: String = relayBackend == .esp32 ? "ESP32" : "Android"
        remote.sendCommand("mble_tap", params: ["token": tokenHex, "durationMs": durationMs], central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "MBLE tap ADV via \(via)" : "MBLE tap failed"
            }
        }
    }

    func setAndroidScan(_ enabled: Bool) {
        guard relayBackend != .esp32 else {
            statusMessage = "The ESP32 does not scan"
            return
        }
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
        let turningOn: Bool = enabled && !keepAwakeActive
        keepAwakeActive = enabled
        keepAwakeChangedAt = Date()
        if turningOn {
            // One transmit loop at a time: the others would fight keep-awake for the radio.
            if tx.randomShowEnabled { tx.setRandomShow(enabled: false, intervalMs: nil) }
            if tx.txLoopEnabled { tx.setTxLoop(enabled: false, packetId: nil, intervalMs: nil) }
            if tx.starlightLoopEnabled { tx.setStarlightLoop(enabled: false, packetId: nil, intervalMs: nil) }
        }
        let pingHex = HexUtils.canonicalHex(hex)
        // The relay keeps its earlier ping when it is given one too short to be a packet.
        if pingHex.count >= 8 { keepAwakeHex = pingHex }
        updateBackgroundKeepAlive()
        if relayBackend == .esp32 {
            // The ESP32 streams by itself, through phone disconnects; a refused command is put
            // right by the next status read.
            sendEsp32Program("keep_awake", ["enabled": enabled, "hex": pingHex])
            return
        }
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
                intervalMs: intervalMs ?? Int(androidRemote?.starlightIntervalMs ?? 3000),
                hex: preset.hex,
                label: preset.label
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

    /// `hex` / `label` are for the ESP32, which has no library: it gets the packet, never a `packetId`.
    func setAndroidStarlightLoop(
        enabled: Bool,
        packetId: Int64? = nil,
        intervalMs: Int? = nil,
        hex: String? = nil,
        label: String? = nil
    ) {
        if relayBackend == .esp32 {
            sendEsp32Program("set_starlight_loop", esp32LoopParams(enabled: enabled, intervalMs: intervalMs, hex: hex, label: label))
            return
        }
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

    func setAndroidTxLoop(
        enabled: Bool,
        packetId: Int64? = nil,
        intervalMs: Int? = nil,
        hex: String? = nil,
        label: String? = nil
    ) {
        if relayBackend == .esp32 {
            sendEsp32Program("set_tx_loop", esp32LoopParams(enabled: enabled, intervalMs: intervalMs, hex: hex, label: label))
            return
        }
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
            }
        }
    }

    func setAndroidCommandBurst(_ ms: Int) {
        remote.sendCommand("set_command_burst", params: ["ms": ms], central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "Command burst \(ms)ms" : "Burst failed"
                self?.refreshAndroidRemote()
            }
        }
    }

    func setAndroidStarlightBurst(_ ms: Int) {
        remote.sendCommand("set_starlight_burst", params: ["ms": ms], central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "Starlight burst \(ms)ms" : "Starlight burst failed"
                self?.refreshAndroidRemote()
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
        guard relayBackend != .esp32 else {
            statusMessage = "The ESP32 does not scan"
            return
        }
        remote.sendCommand("set_auto", params: ["enabled": enabled], central: ble.bleCentral) { [weak self] ok in
            Task { @MainActor in
                self?.statusMessage = ok ? "Android auto \(enabled ? "ON" : "OFF")" : "Android auto command failed"
                self?.refreshAndroidRemote()
            }
        }
    }

    func setAndroidRecording(_ enabled: Bool) {
        guard relayBackend != .esp32 else {
            statusMessage = "The ESP32 does not scan"
            return
        }
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
