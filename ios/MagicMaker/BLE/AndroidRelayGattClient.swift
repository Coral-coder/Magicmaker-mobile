import CoreBluetooth
import Foundation

protocol RelayGattScanning: AnyObject {
    func pauseScanForRelayConnect()
    func resumeScanAfterRelayConnect(restartDisneyScan: Bool)
}

/// iPhone → BLE GATT relay: the Android relay foreground service, or the ESP32 transmitter
/// (same service and characteristics).
final class AndroidRelayGattClient: NSObject {
    static let serviceUUID = CBUUID(string: "A7830001-0000-1000-8000-00805F9B34FB")
    static let transmitUUID = CBUUID(string: "A7830002-0000-1000-8000-00805F9B34FB")
    static let commandUUID = CBUUID(string: "A7830003-0000-1000-8000-00805F9B34FB")
    static let statusUUID = CBUUID(string: "A7830004-0000-1000-8000-00805F9B34FB")
    static let catalogUUID = CBUUID(string: "A7830005-0000-1000-8000-00805F9B34FB")
    /// Firmware updates over Bluetooth (ESP32 firmware 1.2+, firmware/esp32-transmitter/ota.h):
    /// write, write without response, notify. The Android relay has no such characteristic.
    static let otaUUID = CBUUID(string: "A7830007-0000-1000-8000-00805F9B34FB")
    /// Every characteristic the link looks for on the relay service.
    static let relayCharacteristicUUIDs: [CBUUID] = [
        AndroidRelayGattClient.transmitUUID,
        AndroidRelayGattClient.commandUUID,
        AndroidRelayGattClient.statusUUID,
        AndroidRelayGattClient.catalogUUID,
        AndroidRelayGattClient.otaUUID
    ]
    /// The Android relay's tag: ASCII service data on `serviceUUID` in its scan response. It
    /// advertises no name, so the phone's own Bluetooth name is never changed.
    static let androidRelayTag = "MM_AND"
    /// What older Android builds renamed the phone to and advertised; still recognised.
    static let legacyAndroidName = "MagicMaker-Android"
    /// The ESP32 transmitter's advertised name ("MM_ESP"); older firmware used "MagicMaker-ESP32".
    static let esp32Name = "MM_ESP"
    static let esp32Names: [String] = ["MM_ESP", "MagicMaker-ESP32"]

    /// Which relay an advertisement or a name identifies.
    enum RelayKind {
        case android
        case esp32

        /// Whether the selected backend links to this relay.
        func matches(_ backend: RelayBackend) -> Bool {
            switch self {
            case .android: return backend == .androidBle
            case .esp32: return backend == .esp32
            }
        }
    }

    /// How status texts name the device the backend links to ("MM_ESP", or "the Android relay",
    /// which keeps the phone's own name).
    static func targetLabel(for backend: RelayBackend) -> String {
        backend == .esp32 ? esp32Name : "the Android relay"
    }

    static func isEsp32Name(_ name: String) -> Bool {
        esp32Names.contains(where: { (prefix: String) -> Bool in name.hasPrefix(prefix) })
    }

    /// The relay a name identifies: an ESP32 name, or the legacy Android name. Any other name
    /// (the phone's own name included) identifies neither.
    static func relayKind(forName name: String?) -> RelayKind? {
        guard let name, !name.isEmpty else { return nil }
        if isEsp32Name(name) { return .esp32 }
        if name.hasPrefix(legacyAndroidName) { return .android }
        return nil
    }

    /// The relay a service-data tag on `serviceUUID` identifies ("MM_AND" is the Android relay).
    static func relayKind(forTag tag: Data) -> RelayKind? {
        let text: String = String(decoding: tag, as: UTF8.self)
        if text.hasPrefix(androidRelayTag) { return .android }
        if text.hasPrefix(esp32Name) { return .esp32 }
        return nil
    }

    /// The service data an advertisement carries on `serviceUUID`, if any.
    static func relayServiceData(_ advertisementData: [String: Any]) -> Data? {
        guard let entries = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] else {
            return nil
        }
        for (uuid, value) in entries where Self.uuidMatches(uuid, Self.serviceUUID) {
            return value
        }
        return nil
    }

    /// The relay an advertisement identifies: its service-data tag first, then its advertised
    /// name. nil when it carries neither (e.g. a primary advertisement before its scan response).
    static func advertisedRelayKind(_ advertisementData: [String: Any]) -> RelayKind? {
        if let tag = relayServiceData(advertisementData), let kind = relayKind(forTag: tag) {
            return kind
        }
        return relayKind(forName: advertisementData[CBAdvertisementDataLocalNameKey] as? String)
    }

    /// Lists the relay service UUID, or carries service data on it. Every relay advertisement
    /// does one or the other; a Disney packet never does.
    static func advertisesRelayService(_ advertisementData: [String: Any]) -> Bool {
        if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
           uuids.contains(where: { (uuid: CBUUID) -> Bool in Self.uuidMatches(uuid, Self.serviceUUID) }) {
            return true
        }
        return relayServiceData(advertisementData) != nil
    }

    var onStatus: ((String) -> Void)?
    var onCommandReady: (() -> Void)?
    var onCatalogReceived: (([String: Any]?) -> Void)?
    weak var scanCoordinator: RelayGattScanning?

    // MARK: Firmware updates (OTA characteristic, ESP32 firmware 1.2+)

    /// A notification on the OTA characteristic: [0x80 | op][status][u32 value][text].
    var onOtaNotify: ((Data) -> Void)?
    /// The OTA characteristic became usable (true: its notifications are on) or went away (false).
    var onOtaLinkChanged: ((Bool) -> Void)?
    /// CoreBluetooth can take more writes without response.
    var onOtaWriteReady: (() -> Void)?
    /// A write with response to the OTA characteristic finished (nil: accepted).
    var onOtaWriteResult: ((Error?) -> Void)?
    /// A firmware transfer holds the link: transmits, commands and status reads are refused.
    var otaBusy = false
    private var otaCharacteristic: CBCharacteristic?
    private var otaNotifying = false

    /// The linked relay has the OTA characteristic (an ESP32 on firmware 1.2 or newer).
    var hasOtaCharacteristic: Bool {
        relay != nil && otaCharacteristic != nil
    }

    /// The OTA characteristic is found and its notifications are on.
    var isOtaReady: Bool {
        relay?.state == .connected && otaCharacteristic != nil && otaNotifying
    }

    /// Largest write without response this link takes (ATT MTU - 3).
    var otaMaxWriteWithoutResponse: Int {
        relay?.maximumWriteValueLength(for: .withoutResponse) ?? 20
    }

    var otaCanSendWithoutResponse: Bool {
        relay?.canSendWriteWithoutResponse ?? false
    }

    /// One OTA request. Without response it is only written while CoreBluetooth can take it
    /// (false otherwise; `onOtaWriteReady` says when to try again).
    @discardableResult
    func otaWrite(_ data: Data, withResponse: Bool) -> Bool {
        guard let relay, relay.state == .connected, let ota = otaCharacteristic else { return false }
        if withResponse {
            relay.writeValue(data, for: ota, type: .withResponse)
            return true
        }
        guard relay.canSendWriteWithoutResponse else { return false }
        relay.writeValue(data, for: ota, type: .withoutResponse)
        return true
    }

    /// The link dropped or is being rebuilt: the OTA characteristic is gone until rediscovered.
    private func dropOta() {
        let had: Bool = otaCharacteristic != nil || otaNotifying
        otaCharacteristic = nil
        otaNotifying = false
        if had { onOtaLinkChanged?(false) }
    }

    private var relay: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var catalogCharacteristic: CBCharacteristic?
    private var pendingHex: String?
    private var pendingDurationMs = 2_500
    private var linkTimeout: Timer?
    private var pendingCompletion: ((Bool) -> Void)?
    private var connectInProgress = false
    private var lockedRelayId: UUID?
    private weak var activeCentral: CBCentralManager?
    private var broadcastingUntil: Date?
    /// Numbers each TX write, so the end-of-burst timer of a send a newer one replaced does nothing.
    private var txWriteSerial = 0
    // When we last made forward progress (started a connect, linked, or dropped). Used to detect a
    // link that got wedged (e.g. connected but never finished char discovery) so a periodic caller
    // can force a clean retry instead of the user having to kill and reopen the app.
    private var lastProgressAt = Date()
    private func markProgress() { lastProgressAt = Date() }

    /// Not usable, and no forward progress for a while — safe to tear down and rediscover.
    var isLinkStuck: Bool {
        !isCommandReady && Date().timeIntervalSince(lastProgressAt) > 10
    }

    private let connectOptions: [String: Any] = [
        CBConnectPeripheralOptionNotifyOnConnectionKey: true,
        CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
    ]

    var isLinkInProgress: Bool { connectInProgress }

    var isConnected: Bool {
        relay?.state == .connected
    }

    var isReady: Bool {
        relay != nil && txCharacteristic != nil
    }

    var isCommandReady: Bool {
        relay != nil && txCharacteristic != nil && commandCharacteristic != nil && statusCharacteristic != nil
    }

    var isCatalogReady: Bool {
        relay != nil && catalogCharacteristic != nil
    }

    var statusLabel: String {
        if isReady { return "Connected — ready to transmit" }
        if connectInProgress || relay != nil { return "Connecting… (wait a few seconds)" }
        return "Not connected — tap Retry below"
    }

    var relayIdentifier: UUID? {
        relay?.identifier ?? lockedRelayId
    }

    static func uuidMatches(_ a: CBUUID, _ b: CBUUID) -> Bool {
        if a == b { return true }
        return canonicalUUIDHex(a) == canonicalUUIDHex(b)
    }

    /// The Bluetooth Base UUID after its first 32 bits (`-0000-1000-8000-00805F9B34FB`).
    private static let baseUUIDTail: String = "00001000800000805F9B34FB"

    /// A UUID as 32 upper-case hex digits, with 16- and 32-bit short forms expanded on the
    /// Bluetooth Base UUID. The relay service A7830001-0000-1000-8000-00805F9B34FB is base-derived,
    /// so Android advertises it (service UUID and the "MM_AND" service data) in its 32-bit form.
    static func canonicalUUIDHex(_ uuid: CBUUID) -> String {
        let hex: String = uuid.uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        switch hex.count {
        case 4: return "0000" + hex + baseUUIDTail
        case 8: return hex + baseUUIDTail
        default: return hex
        }
    }

    func resetForRetry(central: CBCentralManager) {
        linkTimeout?.invalidate()
        linkTimeout = nil
        connectInProgress = false
        markProgress()
        clearGattState()
        pendingCompletion = nil
        pendingHex = nil
        clearPendingReads()

        disconnectRelay(central: central)
        lockedRelayId = nil
        activeCentral = central
    }

    /// Reuse an existing system connection instead of opening a duplicate connect().
    func reclaimConnectedRelay(central: CBCentralManager) -> Bool {
        guard central.state == .poweredOn else { return false }
        guard !isCommandReady else { return true }
        if connectInProgress, relay != nil { return true }

        let connected: [CBPeripheral] = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID])
        let match: CBPeripheral? = connected.first(where: { isRelayPeripheral($0) })
            ?? connected.first(where: { isConnectedAndroidRelayCandidate($0) })
        guard let peripheral = match else { return false }

        if let relay, relay.identifier != peripheral.identifier {
            disconnectRelay(central: central)
        }

        attachConnected(peripheral)
        activeCentral = central
        connectInProgress = true
        scanCoordinator?.pauseScanForRelayConnect()
        armLinkTimeout()
        onStatus?("Android linked — discovering services…")
        if peripheral.services?.isEmpty != false {
            peripheral.discoverServices(nil)
        } else if let service = peripheral.services?.first(where: { Self.uuidMatches($0.uuid, Self.serviceUUID) }) {
            peripheral.discoverCharacteristics(Self.relayCharacteristicUUIDs, for: service)
        } else {
            peripheral.discoverServices(nil)
        }
        return true
    }

    func handleDisconnect() {
        markProgress()
        // CoreBluetooth never answers a read or write still in flight when the link drops, so
        // fail them here or the GATT queue stays busy after the relay links again.
        dropOta()
        if isBroadcasting {
            txCharacteristic = nil
            connectInProgress = false
            clearPendingReads()
            onStatus?("Android broadcasting — hold phone near MagicBand")
            return
        }
        txCharacteristic = nil
        commandCharacteristic = nil
        statusCharacteristic = nil
        catalogCharacteristic = nil
        clearPendingReads()
        relay = nil
        lockedRelayId = nil
        connectInProgress = false
        linkTimeout?.invalidate()
        linkTimeout = nil
        broadcastingUntil = nil
        onStatus?("Android relay disconnected — reconnecting")
    }

    private var isBroadcasting: Bool {
        if let broadcastingUntil { return Date() < broadcastingUntil }
        return false
    }

    func attachConnected(_ peripheral: CBPeripheral) {
        relay = peripheral
        lockedRelayId = peripheral.identifier
        peripheral.delegate = self
    }

    // Match only the device the SELECTED backend targets — the ESP32 and a standalone Android
    // relay advertise the same service UUID, so with both running we must not cross the streams:
    // ESP32 backend links only to MM_ESP (or the older MagicMaker-ESP32 name), Android BLE only to
    // the Android relay (its "MM_AND" service-data tag, or the legacy MagicMaker-Android name).
    private func nameMatchesBackend(_ name: String?) -> Bool {
        guard let kind = Self.relayKind(forName: name) else { return false }
        return kind.matches(RelayBackend.load())
    }

    func isRelayPeripheral(_ peripheral: CBPeripheral) -> Bool {
        guard RelayBackend.load().usesBleRelayLink else { return false }
        if let lockedRelayId, peripheral.identifier == lockedRelayId { return true }
        if let id = relay?.identifier, peripheral.identifier == id { return true }
        return nameMatchesBackend(peripheral.name)
    }

    /// A system-connected peripheral with the relay service that may be the Android relay. It
    /// advertises no name, so once connected CoreBluetooth knows it by the phone's own name.
    /// Android BLE only, and never a peripheral known by an ESP32 name.
    private func isConnectedAndroidRelayCandidate(_ peripheral: CBPeripheral) -> Bool {
        guard RelayBackend.load() == .androidBle else { return false }
        guard let name = peripheral.name else { return true }
        return !Self.isEsp32Name(name)
    }

    /// `peripheralName` is what CoreBluetooth already calls the advertiser (an earlier scan
    /// response, or its GAP name); it keeps the Android fallback off a known ESP32, and lets the
    /// ESP32 be found from its service UUID alone.
    func isRelayAdvertisement(_ advertisementData: [String: Any], peripheralName: String? = nil) -> Bool {
        let backend: RelayBackend = RelayBackend.load()
        guard backend.usesBleRelayLink else { return false }

        // The tag or a known name is authoritative (tells the ESP32 from the Android relay).
        if let kind = Self.advertisedRelayKind(advertisementData) { return kind.matches(backend) }

        // Any other advertised name is not a relay.
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        if let name, !name.isEmpty { return false }

        if backend == .esp32 {
            // CoreBluetooth keeps the GAP name from an earlier link; with the relay service listed that is
            // enough (a background scan may not get the scan response).
            guard let peripheralName, Self.isEsp32Name(peripheralName) else { return false }
            return Self.advertisesRelayService(advertisementData)
        }

        // Neither tag nor name seen yet: ESP32 mode (above) needs an ESP32 name so it never grabs
        // the Android relay by the shared service UUID. Android mode keeps its
        // legacy service-UUID discovery, but never for an advertiser known by an ESP32 name.
        guard backend == .androidBle else { return false }
        if let peripheralName, Self.isEsp32Name(peripheralName) { return false }
        return Self.advertisesRelayService(advertisementData)
    }

    func ensureLink(central: CBCentralManager) -> Bool {
        guard central.state == .poweredOn else { return false }
        guard RelayBackend.load().usesBleRelayLink else { return false }
        if isCommandReady { return true }
        if connectInProgress { return true }

        if let relay, relay.state == .connected || relay.state == .connecting {
            attachConnected(relay)
            activeCentral = central
            if relay.state == .connected, txCharacteristic == nil || commandCharacteristic == nil {
                connectInProgress = true
                scanCoordinator?.pauseScanForRelayConnect()
                armLinkTimeout()
                onStatus?("Android linked — discovering services…")
                if relay.services?.isEmpty != false {
                    relay.discoverServices(nil)
                } else if let service = relay.services?.first(where: { Self.uuidMatches($0.uuid, Self.serviceUUID) }) {
                    relay.discoverCharacteristics(Self.relayCharacteristicUUIDs, for: service)
                } else {
                    relay.discoverServices(nil)
                }
                return true
            }
            return true
        }

        if reclaimConnectedRelay(central: central) { return true }
        return false
    }

    func handleDiscovery(_ peripheral: CBPeripheral, advertisementData: [String: Any], central: CBCentralManager) -> Bool {
        guard isRelayAdvertisement(advertisementData, peripheralName: peripheral.name) else { return false }
        guard central.state == .poweredOn else { return true }

        if isCommandReady { return true }
        if connectInProgress { return true }

        if let relay, relay.identifier == peripheral.identifier {
            if relay.state == .connecting { return true }
            if relay.state == .connected {
                if txCharacteristic == nil || commandCharacteristic == nil {
                    attachConnected(relay)
                    activeCentral = central
                    beginServiceDiscovery(on: relay)
                }
                return true
            }
        }

        switch peripheral.state {
        case .connected where txCharacteristic == nil || commandCharacteristic == nil:
            attachConnected(peripheral)
            activeCentral = central
            beginServiceDiscovery(on: peripheral)
        case .disconnected:
            beginConnect(to: peripheral, central: central)
        default:
            break
        }
        return true
    }

    func onCentralDidConnect(_ peripheral: CBPeripheral) {
        guard isRelayPeripheral(peripheral) else { return }
        attachConnected(peripheral)
        armLinkTimeout()
        onStatus?("Android linked — discovering services…")
        peripheral.discoverServices(nil)
    }

    func onCentralDidFailToConnect(_ peripheral: CBPeripheral, central: CBCentralManager, error: Error?) {
        guard isRelayPeripheral(peripheral) else { return }
        let detail = error?.localizedDescription ?? "unknown error"
        failLink("Android connect failed: \(detail)")
    }

    func onCentralDidDisconnect(_ peripheral: CBPeripheral) {
        guard isRelayPeripheral(peripheral) else { return }
        markProgress()
        if isBroadcasting {
            dropOta()
            txCharacteristic = nil
            relay = nil
            connectInProgress = false
            clearPendingReads()
            onStatus?("Android broadcasting — hold phone near MagicBand")
            return
        }
        handleDisconnect()
        scanCoordinator?.resumeScanAfterRelayConnect(restartDisneyScan: false)
    }

    func startDiscovery(central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        guard !connectInProgress else { return }
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func transmit(hex: String, durationMs: Double, central: CBCentralManager, onComplete: @escaping (Bool) -> Void) {
        if otaBusy {
            onStatus?("Firmware update running — transmit paused")
            onComplete(false)
            return
        }
        let canonical = HexUtils.canonicalHex(hex)
        pendingHex = canonical
        pendingDurationMs = Int(durationMs)
        activeCentral = central

        guard central.state == .poweredOn else {
            onStatus?("Turn on Bluetooth — needed for Android relay")
            finishPending(success: false, onComplete: onComplete)
            return
        }

        if isReady, let relay, let txCharacteristic {
            send(hex: canonical, durationMs: pendingDurationMs, to: relay, characteristic: txCharacteristic, onComplete: onComplete)
            return
        }

        pendingCompletion = onComplete

        if let relay, relay.state == .connected, txCharacteristic == nil {
            beginServiceDiscovery(on: relay)
            armLinkTimeout()
            return
        }

        if connectInProgress {
            armLinkTimeout()
            return
        }

        if let lockedRelayId,
           let known = central.retrievePeripherals(withIdentifiers: [lockedRelayId]).first {
            beginConnect(to: known, central: central)
            armLinkTimeout()
            return
        }

        startDiscovery(central: central)
        armLinkTimeout()
    }

    func sendRemoteCommand(_ body: [String: Any], onComplete: @escaping (Bool) -> Void) {
        sendRemoteCommandJson(body) { json in
            onComplete(json?["ok"] as? Bool == true)
        }
    }

    /// `coalesceKind`: a command that sets one state outright (an ESP32 loop or keep-awake). While
    /// the last command queued is one of the same kind that has not started, this one replaces its
    /// body instead of queueing a second write and reply read; both callers get this one's reply.
    func sendRemoteCommandJson(
        _ body: [String: Any],
        coalesceKind: String? = nil,
        onComplete: @escaping ([String: Any]?) -> Void
    ) {
        guard isCommandReady, !otaBusy else {
            onComplete(nil)
            return
        }
        if let coalesceKind, let waiting = tailCommand, waiting.kind == coalesceKind, !waiting.started {
            waiting.body = body
            waiting.completions.append(onComplete)
            return
        }
        let command = QueuedCommand(kind: coalesceKind, body: body, completion: onComplete)
        enqueueGatt { [weak self] in
            command.started = true
            guard let self else { return }
            if self.tailCommand === command { self.tailCommand = nil }
            self.runCommandJson(command.body) { [weak self] json in
                for done in command.completions {
                    done(json)
                }
                self?.completeGattOperation()
            }
        }
        // Queued behind other work: a newer command of its kind may still replace it.
        if coalesceKind != nil && !command.started {
            tailCommand = command
        }
    }

    /// A command in the GATT queue, with everyone waiting for its reply.
    private final class QueuedCommand {
        let kind: String?
        var body: [String: Any]
        var completions: [([String: Any]?) -> Void]
        var started = false

        init(kind: String?, body: [String: Any], completion: @escaping ([String: Any]?) -> Void) {
            self.kind = kind
            self.body = body
            self.completions = [completion]
        }
    }

    private func runCommandJson(_ body: [String: Any], onComplete: @escaping ([String: Any]?) -> Void) {
        guard isCommandReady, let relay, let commandCharacteristic else {
            onComplete(nil)
            return
        }
        let action = body["action"] as? String ?? ""
        let readsCatalog = action == "catalog_sync_chunk"
            || action == "catalog_chunk"
            || action == "sync_chunk"
        if readsCatalog {
            guard isCatalogReady else {
                onComplete(nil)
                return
            }
        } else {
            guard statusCharacteristic != nil else {
                onComplete(nil)
                return
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              String(data: data, encoding: .utf8) != nil else {
            onComplete(nil)
            return
        }
        pendingJsonCompletion = onComplete
        pendingCommandCompletion = nil
        pendingCommandReadsCatalog = readsCatalog
        pendingCommandReadAttempt = 0
        pendingCommandReadUseCatalog = false
        let writeType: CBCharacteristicWriteType = commandCharacteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        relay.writeValue(data, for: commandCharacteristic, type: writeType)
        if !commandCharacteristic.properties.contains(.write) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, let relay = self.relay else { return }
                self.readCommandResponse(on: relay)
            }
        }
    }

    private func readCommandResponse(on peripheral: CBPeripheral) {
        if pendingCommandReadUseCatalog, let catalogCharacteristic {
            isStatusReadBlocked = true
            peripheral.readValue(for: catalogCharacteristic)
        } else if let statusCharacteristic {
            peripheral.readValue(for: statusCharacteristic)
        } else if pendingCommandReadsCatalog, let catalogCharacteristic {
            isStatusReadBlocked = true
            peripheral.readValue(for: catalogCharacteristic)
        } else {
            finishPendingCommandJson(nil, success: false)
        }
    }

    private func finishPendingCommandJson(_ json: [String: Any]?, success: Bool) {
        let done = pendingJsonCompletion
        pendingJsonCompletion = nil
        pendingCommandReadsCatalog = false
        pendingCommandReadAttempt = 0
        pendingCommandReadUseCatalog = false
        isStatusReadBlocked = false
        done?(json)
        finishCommand(success: success)
    }

    private func retryPendingCommandRead(on peripheral: CBPeripheral) {
        guard pendingJsonCompletion != nil else { return }
        pendingCommandReadAttempt += 1
        if pendingCommandReadAttempt >= maxCommandReadAttempts {
            finishPendingCommandJson(nil, success: false)
            return
        }
        if pendingCommandReadsCatalog, !pendingCommandReadUseCatalog, isCatalogReady {
            pendingCommandReadUseCatalog = true
            readCommandResponse(on: peripheral)
            return
        }
        pendingCommandReadUseCatalog = false
        let delay = 0.06 * Double(pendingCommandReadAttempt)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.pendingJsonCompletion != nil else { return }
            self.readCommandResponse(on: peripheral)
        }
    }

    private func parseCommandJson(from data: Data?) -> [String: Any]? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    /// Chunk sync expects `{ok, items}` — reject status telemetry that replaced the response buffer.
    private func isCatalogChunkJson(_ json: [String: Any]) -> Bool {
        json["ok"] as? Bool == true && json["items"] != nil
    }

    private func acceptCommandJson(from data: Data?) -> [String: Any]? {
        guard let json = parseCommandJson(from: data) else { return nil }
        if pendingCommandReadsCatalog {
            guard isCatalogChunkJson(json) else { return nil }
        }
        return json
    }

    func readHandshakeCatalog(onComplete: @escaping ([String: Any]?) -> Void) {
        enqueueGatt { [weak self] in
            self?.runCatalogRead(attempt: 0) { json in
                onComplete(json)
                self?.completeGattOperation()
            }
        }
    }

    /// Read full catalog JSON from CATALOG char (may require ATT read-blob on long payloads).
    func readCatalogBlob(attempt: Int = 0, onComplete: @escaping ([String: Any]?) -> Void) {
        guard isCatalogReady, let relay, let catalogCharacteristic else {
            onComplete(nil)
            return
        }
        isStatusReadBlocked = true
        pendingCatalogHandshakeCompletion = onComplete
        pendingCatalogReadAttempt = attempt
        relay.readValue(for: catalogCharacteristic)
    }

    /// Refresh catalog buffer on Android, then read CATALOG char (never STATUS — status truncates at 512 bytes).
    func refreshCatalogFromAndroid(onComplete: @escaping ([String: Any]?) -> Void) {
        guard isCommandReady else {
            onComplete(nil)
            return
        }
        enqueueGatt { [weak self] in
            self?.runCommandJson(["action": "catalog"]) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    self?.runCatalogRead(attempt: 0) { json in
                        onComplete(json)
                        self?.completeGattOperation()
                    }
                }
            }
        }
    }

    private func runCatalogRead(attempt: Int, onComplete: @escaping ([String: Any]?) -> Void) {
        guard isCatalogReady, let relay, let catalogCharacteristic else {
            onComplete(nil)
            return
        }
        isStatusReadBlocked = true
        pendingCatalogHandshakeCompletion = onComplete
        pendingCatalogReadAttempt = attempt
        relay.readValue(for: catalogCharacteristic)
    }

    func readRemoteStatus(onComplete: @escaping (AndroidRemoteStatus?) -> Void) {
        guard isReady, !otaBusy else {
            onComplete(nil)
            return
        }
        enqueueGatt(background: true) { [weak self] in
            self?.runStatusRead { status in
                onComplete(status)
                self?.completeGattOperation()
            }
        }
    }

    private func runStatusRead(onComplete: @escaping (AndroidRemoteStatus?) -> Void) {
        guard isReady, let relay, let statusCharacteristic else {
            onComplete(nil)
            return
        }
        guard !isStatusReadBlocked else {
            onComplete(nil)
            return
        }
        pendingStatusCompletion = onComplete
        relay.readValue(for: statusCharacteristic)
    }

    private var pendingStatusCompletion: ((AndroidRemoteStatus?) -> Void)?
    private var pendingCommandCompletion: ((Bool) -> Void)?
    private var pendingJsonCompletion: (([String: Any]?) -> Void)?
    private var pendingCatalogHandshakeCompletion: (([String: Any]?) -> Void)?
    private var pendingCatalogReadAttempt = 0
    private var pendingCommandReadsCatalog = false
    private var pendingCommandReadAttempt = 0
    private var pendingCommandReadUseCatalog = false
    private var isStatusReadBlocked = false
    private let maxCommandReadAttempts = 5

    /// One GATT operation waiting its turn. A status poll is `background`: any other operation
    /// (a command the user gave, a catalog read) goes ahead of polls still waiting, so a poll
    /// holds it up for at most the read already in flight.
    private struct GattOp {
        let background: Bool
        let start: () -> Void
    }
    private var gattQueue: [GattOp] = []
    private var gattBusy = false
    /// The last command queued that a newer one of its kind may replace (`coalesceKind`); nil
    /// once it starts or anything but a poll is queued after it.
    private var tailCommand: QueuedCommand?

    private func enqueueGatt(background: Bool = false, _ start: @escaping () -> Void) {
        let op = GattOp(background: background, start: start)
        if background {
            gattQueue.append(op)
        } else {
            tailCommand = nil
            if let firstPoll = gattQueue.firstIndex(where: { (queued: GattOp) -> Bool in queued.background }) {
                gattQueue.insert(op, at: firstPoll)
            } else {
                gattQueue.append(op)
            }
        }
        pumpGattQueue()
    }

    private func pumpGattQueue() {
        guard !gattBusy, !gattQueue.isEmpty else { return }
        gattBusy = true
        let op: GattOp = gattQueue.removeFirst()
        op.start()
    }

    private func completeGattOperation() {
        gattBusy = false
        pumpGattQueue()
    }

    var hasGattWorkQueued: Bool {
        otaBusy || gattBusy || !gattQueue.isEmpty || pendingJsonCompletion != nil || pendingStatusCompletion != nil
    }

    private func sendCommand(json: String, onComplete: @escaping (Bool) -> Void) {
        guard isReady, let relay, let commandCharacteristic else {
            onComplete(false)
            return
        }
        guard let data = json.data(using: .utf8) else {
            onComplete(false)
            return
        }
        pendingCommandCompletion = onComplete
        let writeType: CBCharacteristicWriteType = commandCharacteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        relay.writeValue(data, for: commandCharacteristic, type: writeType)
        if !commandCharacteristic.properties.contains(.write) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.finishCommand(success: true)
            }
        }
    }

    private func finishCommand(success: Bool) {
        pendingCommandCompletion?(success)
        pendingCommandCompletion = nil
    }

    private func beginConnect(to peripheral: CBPeripheral, central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        guard !connectInProgress else { return }
        guard peripheral.state == .disconnected else { return }

        if let relay, relay.identifier != peripheral.identifier {
            disconnectRelay(central: central)
        }

        connectInProgress = true
        activeCentral = central
        relay = peripheral
        lockedRelayId = peripheral.identifier
        peripheral.delegate = self
        markProgress()
        scanCoordinator?.pauseScanForRelayConnect()
        armLinkTimeout()
        onStatus?("Found \(Self.targetLabel(for: RelayBackend.load())) — connecting…")
        central.connect(peripheral, options: connectOptions)
    }

    private func beginServiceDiscovery(on peripheral: CBPeripheral) {
        connectInProgress = true
        scanCoordinator?.pauseScanForRelayConnect()
        onStatus?("Android linked — discovering services…")
        peripheral.discoverServices(nil)
    }

    private func armLinkTimeout() {
        linkTimeout?.invalidate()
        linkTimeout = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self, !self.isReady else { return }
            self.failLink("Android connect timeout — tap Retry")
        }
    }

    private func failLink(_ message: String) {
        linkTimeout?.invalidate()
        linkTimeout = nil
        connectInProgress = false
        clearGattState()
        clearPendingReads()

        if let activeCentral {
            disconnectRelay(central: activeCentral)
        }

        lockedRelayId = nil
        onStatus?(message)
        scanCoordinator?.resumeScanAfterRelayConnect(restartDisneyScan: false)
        finishPending(success: false)
    }

    private func clearGattState() {
        txCharacteristic = nil
        commandCharacteristic = nil
        statusCharacteristic = nil
        catalogCharacteristic = nil
        dropOta()
    }

    private func clearPendingReads() {
        if let pendingJsonCompletion {
            pendingJsonCompletion(nil)
        }
        pendingStatusCompletion?(nil)
        pendingCatalogHandshakeCompletion?(nil)
        pendingStatusCompletion = nil
        pendingJsonCompletion = nil
        pendingCommandCompletion = nil
        pendingCatalogHandshakeCompletion = nil
        pendingCatalogReadAttempt = 0
        pendingCommandReadsCatalog = false
        pendingCommandReadAttempt = 0
        pendingCommandReadUseCatalog = false
        isStatusReadBlocked = false
        gattBusy = false
        gattQueue.removeAll()
        tailCommand = nil
    }

    private func disconnectRelay(central: CBCentralManager) {
        guard let relay else { return }
        guard central.state == .poweredOn else {
            self.relay = nil
            return
        }
        switch relay.state {
        case .connecting, .connected:
            central.cancelPeripheralConnection(relay)
        default:
            break
        }
        self.relay = nil
    }

    private func completeLink() {
        linkTimeout?.invalidate()
        linkTimeout = nil
        connectInProgress = false
        markProgress()
        onStatus?("Android relay ready")
        scanCoordinator?.resumeScanAfterRelayConnect(restartDisneyScan: false)
    }

    private func send(
        hex: String,
        durationMs: Int,
        to peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        onComplete: @escaping (Bool) -> Void
    ) {
        let payload = "\(hex)|\(durationMs)"
        guard let data = payload.data(using: .utf8) else {
            finishPending(success: false, onComplete: onComplete)
            return
        }
        txWriteSerial += 1
        let serial: Int = txWriteSerial
        pendingCompletion = onComplete
        let writeType: CBCharacteristicWriteType = transmitWriteType(characteristic, on: peripheral, length: data.count)
        broadcastingUntil = Date().addingTimeInterval(Double(durationMs) / 1000 + 1.0)
        peripheral.writeValue(data, for: characteristic, type: writeType)
        onStatus?("Android broadcasting — hold phone near MagicBand")
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(durationMs) / 1000 + 0.5) { [weak self] in
            guard let self else { return }
            guard self.txWriteSerial == serial else {
                // A newer write replaced this send (the ESP32 takes the newest): only this send's
                // own caller hears that it ended; the newer send's state is left alone.
                onComplete(true)
                return
            }
            self.broadcastingUntil = nil
            self.finishPending(success: true, onComplete: onComplete)
            if self.txCharacteristic == nil, self.relay == nil {
                self.scanCoordinator?.resumeScanAfterRelayConnect(restartDisneyScan: false)
            }
        }
    }

    /// How a TX write goes out. To the ESP32 it is a write without response when the packet fits
    /// one: an ATT command needs no request slot, so it is not held behind a STATUS read in
    /// flight (the 2 s poll, a command's reply; long while a loop runs), as a write request is —
    /// ATT allows one request at a time. The Android relay keeps the write with response.
    private func transmitWriteType(_ characteristic: CBCharacteristic, on peripheral: CBPeripheral, length: Int) -> CBCharacteristicWriteType {
        let properties: CBCharacteristicProperties = characteristic.properties
        if !properties.contains(.write) { return .withoutResponse }
        guard RelayBackend.load() == .esp32,
              properties.contains(.writeWithoutResponse),
              peripheral.canSendWriteWithoutResponse,
              length <= peripheral.maximumWriteValueLength(for: .withoutResponse) else {
            return .withResponse
        }
        return .withoutResponse
    }

    private func finishPending(success: Bool, onComplete: ((Bool) -> Void)? = nil) {
        let done = onComplete ?? pendingCompletion
        pendingCompletion = nil
        done?(success)
    }
}

extension AndroidRelayGattClient: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == relay?.identifier else { return }
        if let error {
            failLink("Android services error: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services, !services.isEmpty else {
            failLink("Android returned no BLE services")
            return
        }
        guard let service = services.first(where: { Self.uuidMatches($0.uuid, Self.serviceUUID) }) else {
            let found = services.map(\.uuid.uuidString).joined(separator: ", ")
            failLink("Android missing relay service (found: \(found))")
            return
        }
        peripheral.discoverCharacteristics(Self.relayCharacteristicUUIDs, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral.identifier == relay?.identifier else { return }
        if let error {
            failLink("Android characteristics error: \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else {
            failLink("Android service has no characteristics")
            return
        }
        guard let tx = chars.first(where: { Self.uuidMatches($0.uuid, Self.transmitUUID) }) else {
            let found = chars.map(\.uuid.uuidString).joined(separator: ", ")
            failLink("Android missing TX characteristic (found: \(found))")
            return
        }
        txCharacteristic = tx
        commandCharacteristic = chars.first(where: { Self.uuidMatches($0.uuid, Self.commandUUID) })
        statusCharacteristic = chars.first(where: { Self.uuidMatches($0.uuid, Self.statusUUID) })
        catalogCharacteristic = chars.first(where: { Self.uuidMatches($0.uuid, Self.catalogUUID) })
        guard commandCharacteristic != nil, statusCharacteristic != nil else {
            let found = chars.map(\.uuid.uuidString).joined(separator: ", ")
            failLink("Android missing command/status (found: \(found))")
            return
        }
        let ota: CBCharacteristic? = chars.first(where: { Self.uuidMatches($0.uuid, Self.otaUUID) })
        if ota == nil { dropOta() }
        otaCharacteristic = ota
        otaNotifying = false
        completeLink()
        if let ota, ota.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: ota)
        }
        onStatus?("Android relay ready — syncing library…")
        // Chunked catalog_sync is the reliable path; skip parallel CATALOG handshake (races GATT queue).
        onCommandReady?()
        if let pendingHex, let onComplete = pendingCompletion {
            send(hex: pendingHex, durationMs: pendingDurationMs, to: peripheral, characteristic: tx, onComplete: onComplete)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if Self.uuidMatches(characteristic.uuid, Self.otaUUID) {
            guard peripheral.identifier == relay?.identifier else { return }
            onOtaWriteResult?(error)
            return
        }
        if Self.uuidMatches(characteristic.uuid, Self.commandUUID) {
            if error != nil {
                finishPendingCommandJson(nil, success: false)
                onStatus?("Android command failed")
                return
            }
            if pendingJsonCompletion != nil || pendingCommandCompletion != nil {
                readCommandResponse(on: peripheral)
                return
            }
            finishCommand(success: true)
            return
        }
        if error != nil {
            onStatus?("Android write failed")
            finishPending(success: false)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if Self.uuidMatches(characteristic.uuid, Self.otaUUID) {
            guard peripheral.identifier == relay?.identifier, error == nil, let value = characteristic.value else { return }
            onOtaNotify?(value)
            return
        }
        if Self.uuidMatches(characteristic.uuid, Self.catalogUUID) {
            if pendingJsonCompletion != nil {
                if error == nil, let json = acceptCommandJson(from: characteristic.value) {
                    finishPendingCommandJson(json, success: json["ok"] as? Bool == true)
                    return
                }
                retryPendingCommandRead(on: peripheral)
                return
            }
            let done = pendingCatalogHandshakeCompletion
            guard error == nil, let data = characteristic.value else {
                pendingCatalogHandshakeCompletion = nil
                isStatusReadBlocked = false
                done?(nil)
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let catalog = AndroidRemoteCatalog.parse(json),
                  !catalog.transmitPresets.isEmpty else {
                let nextAttempt = pendingCatalogReadAttempt + 1
                if nextAttempt < 5, let relay, let catalogCharacteristic {
                    pendingCatalogReadAttempt = nextAttempt
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                        relay.readValue(for: catalogCharacteristic)
                    }
                    return
                }
                pendingCatalogHandshakeCompletion = nil
                pendingCatalogReadAttempt = 0
                isStatusReadBlocked = false
                done?(nil)
                return
            }
            pendingCatalogHandshakeCompletion = nil
            pendingCatalogReadAttempt = 0
            isStatusReadBlocked = false
            done?(json)
            return
        }
        guard Self.uuidMatches(characteristic.uuid, Self.statusUUID) else { return }
        if pendingJsonCompletion != nil {
            if error == nil, let json = acceptCommandJson(from: characteristic.value) {
                finishPendingCommandJson(json, success: json["ok"] as? Bool == true)
                return
            }
            retryPendingCommandRead(on: peripheral)
            return
        }
        if isStatusReadBlocked { return }
        let done = pendingStatusCompletion
        pendingStatusCompletion = nil
        guard error == nil, let data = characteristic.value else {
            done?(nil)
            return
        }
        let whole: Any? = try? JSONSerialization.jsonObject(with: data)
        // Android serves its last command reply (kept up to 30 s for catalog chunks) on STATUS
        // instead of the status object; only a real status carries "running".
        guard let json = (whole as? [String: Any]) ?? Self.leadingFields(ofTruncatedObject: data),
              json["running"] != nil else {
            done?(nil)
            return
        }
        done?(AndroidRemoteStatus.parse(json))
    }

    /// One GATT value carries at most 512 bytes, so a longer status arrives cut off mid-field.
    /// Keeps the complete fields before the cut; the relay sends the short ones first.
    static func leadingFields(ofTruncatedObject data: Data) -> [String: Any]? {
        let bytes = [UInt8](data)
        guard let first = bytes.first, first == 0x7B else { return nil }
        var inString = false
        var escaped = false
        var depth = 0
        var lastComma = -1
        for (index, byte) in bytes.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }
            if byte == 0x22 {
                inString = true
            } else if byte == 0x7B || byte == 0x5B {
                depth += 1
            } else if byte == 0x7D || byte == 0x5D {
                depth -= 1
            } else if byte == 0x2C && depth == 1 {
                lastComma = index
            }
        }
        guard lastComma > 0 else { return nil }
        var repaired: [UInt8] = Array(bytes[0..<lastComma])
        repaired.append(0x7D)
        let object: Any? = try? JSONSerialization.jsonObject(with: Data(repaired))
        return object as? [String: Any]
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == relay?.identifier,
              Self.uuidMatches(characteristic.uuid, Self.otaUUID),
              otaCharacteristic != nil else {
            return
        }
        let on: Bool = error == nil && characteristic.isNotifying
        if on == otaNotifying { return }
        otaNotifying = on
        onOtaLinkChanged?(on)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral.identifier == relay?.identifier else { return }
        onOtaWriteReady?()
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        if invalidatedServices.contains(where: { Self.uuidMatches($0.uuid, Self.serviceUUID) }) {
            txCharacteristic = nil
            commandCharacteristic = nil
            statusCharacteristic = nil
            catalogCharacteristic = nil
            dropOta()
            onStatus?("Android relay reset — reconnecting")
        }
    }
}
