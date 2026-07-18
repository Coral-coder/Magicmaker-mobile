import CoreBluetooth
import Foundation

protocol RelayGattScanning: AnyObject {
    func pauseScanForRelayConnect()
    func resumeScanAfterRelayConnect(restartDisneyScan: Bool)
}

/// iPhone → Android BLE GATT relay (MagicMaker-Android foreground service).
final class AndroidRelayGattClient: NSObject {
    static let serviceUUID = CBUUID(string: "A7830001-0000-1000-8000-00805F9B34FB")
    static let transmitUUID = CBUUID(string: "A7830002-0000-1000-8000-00805F9B34FB")
    static let commandUUID = CBUUID(string: "A7830003-0000-1000-8000-00805F9B34FB")
    static let statusUUID = CBUUID(string: "A7830004-0000-1000-8000-00805F9B34FB")
    static let catalogUUID = CBUUID(string: "A7830005-0000-1000-8000-00805F9B34FB")
    static let deviceName = "MagicMaker-Android"
    static let esp32Name = "MagicMaker-ESP32"

    var onStatus: ((String) -> Void)?
    var onCommandReady: (() -> Void)?
    var onCatalogReceived: (([String: Any]?) -> Void)?
    weak var scanCoordinator: RelayGattScanning?

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
        let norm: (CBUUID) -> String = {
            $0.uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        }
        return norm(a) == norm(b)
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

        let connected = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID])
        guard let peripheral = connected.first(where: { isRelayPeripheral($0) }) else { return false }

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
            peripheral.discoverCharacteristics(
                [Self.transmitUUID, Self.commandUUID, Self.statusUUID, Self.catalogUUID],
                for: service
            )
        } else {
            peripheral.discoverServices(nil)
        }
        return true
    }

    func handleDisconnect() {
        markProgress()
        if isBroadcasting {
            txCharacteristic = nil
            connectInProgress = false
            onStatus?("Android broadcasting — hold phone near MagicBand")
            return
        }
        txCharacteristic = nil
        commandCharacteristic = nil
        statusCharacteristic = nil
        catalogCharacteristic = nil
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

    // Match only the device the SELECTED backend targets, by name — the ESP32 and a standalone
    // Android relay advertise the same service UUID, so with both running we must not cross the
    // streams: ESP32 backend links only to MagicMaker-ESP32, Android BLE only to MagicMaker-Android.
    private func nameMatchesBackend(_ name: String?) -> Bool {
        switch RelayBackend.load() {
        case .esp32:
            return name?.hasPrefix(Self.esp32Name) == true
        case .androidBle:
            return name == Self.deviceName || name?.hasPrefix("MagicMaker-Android") == true
        default:
            return false
        }
    }

    func isRelayPeripheral(_ peripheral: CBPeripheral) -> Bool {
        guard RelayBackend.load().usesBleRelayLink else { return false }
        if let lockedRelayId, peripheral.identifier == lockedRelayId { return true }
        if let id = relay?.identifier, peripheral.identifier == id { return true }
        return nameMatchesBackend(peripheral.name)
    }

    func isRelayAdvertisement(_ advertisementData: [String: Any]) -> Bool {
        guard RelayBackend.load().usesBleRelayLink else { return false }

        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let hasService = services.contains(where: { Self.uuidMatches($0, Self.serviceUUID) })

        // Name is authoritative when present (distinguishes ESP32 vs Android).
        if let name, !name.isEmpty { return nameMatchesBackend(name) }
        // Name not yet seen: ESP32 mode waits for the (reliable) scan-response name so it never
        // grabs the Android relay by the shared service UUID. Android mode keeps its legacy
        // service-UUID discovery.
        switch RelayBackend.load() {
        case .androidBle: return hasService
        default: return false
        }
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
                    relay.discoverCharacteristics(
                        [Self.transmitUUID, Self.commandUUID, Self.statusUUID, Self.catalogUUID],
                        for: service
                    )
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
        guard isRelayAdvertisement(advertisementData) else { return false }
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
            txCharacteristic = nil
            relay = nil
            connectInProgress = false
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

    func sendRemoteCommandJson(_ body: [String: Any], onComplete: @escaping ([String: Any]?) -> Void) {
        guard isCommandReady else {
            onComplete(nil)
            return
        }
        enqueueGatt { [weak self] in
            self?.runCommandJson(body) { json in
                onComplete(json)
                self?.completeGattOperation()
            }
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
        guard isReady else {
            onComplete(nil)
            return
        }
        enqueueGatt { [weak self] in
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
    private var gattQueue: [() -> Void] = []
    private var gattBusy = false

    private func enqueueGatt(_ start: @escaping () -> Void) {
        gattQueue.append(start)
        pumpGattQueue()
    }

    private func pumpGattQueue() {
        guard !gattBusy, !gattQueue.isEmpty else { return }
        gattBusy = true
        gattQueue.removeFirst()()
    }

    private func completeGattOperation() {
        gattBusy = false
        pumpGattQueue()
    }

    var hasGattWorkQueued: Bool {
        gattBusy || !gattQueue.isEmpty || pendingJsonCompletion != nil || pendingStatusCompletion != nil
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
        onStatus?("Found MagicMaker-Android — connecting…")
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
        pendingCompletion = onComplete
        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        broadcastingUntil = Date().addingTimeInterval(Double(durationMs) / 1000 + 1.0)
        peripheral.writeValue(data, for: characteristic, type: writeType)
        onStatus?("Android broadcasting — hold phone near MagicBand")
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(durationMs) / 1000 + 0.5) { [weak self] in
            guard let self else { return }
            self.broadcastingUntil = nil
            self.finishPending(success: true, onComplete: onComplete)
            if self.txCharacteristic == nil, self.relay == nil {
                self.scanCoordinator?.resumeScanAfterRelayConnect(restartDisneyScan: false)
            }
        }
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
        peripheral.discoverCharacteristics(
            [Self.transmitUUID, Self.commandUUID, Self.statusUUID, Self.catalogUUID],
            for: service
        )
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
        completeLink()
        onStatus?("Android relay ready — syncing library…")
        // Chunked catalog_sync is the reliable path; skip parallel CATALOG handshake (races GATT queue).
        onCommandReady?()
        if let pendingHex, let onComplete = pendingCompletion {
            send(hex: pendingHex, durationMs: pendingDurationMs, to: peripheral, characteristic: tx, onComplete: onComplete)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
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
        guard error == nil, let data = characteristic.value,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            done?(nil)
            return
        }
        done?(AndroidRemoteStatus.parse(json))
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        if invalidatedServices.contains(where: { Self.uuidMatches($0.uuid, Self.serviceUUID) }) {
            txCharacteristic = nil
            commandCharacteristic = nil
            statusCharacteristic = nil
            catalogCharacteristic = nil
            onStatus?("Android relay reset — reconnecting")
        }
    }
}
