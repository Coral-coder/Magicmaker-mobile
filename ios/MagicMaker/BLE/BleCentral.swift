import CoreBluetooth
import Foundation

protocol BleCentralDelegate: AnyObject {
    func bleCentral(didReceive hex: String, rssi: Int)
    func bleCentral(didUpdate status: String)
    func bleCentralScanningChanged(_ scanning: Bool)
}

final class BleCentral: NSObject, CBCentralManagerDelegate, RelayGattScanning {
    weak var delegate: BleCentralDelegate?

    private var central: CBCentralManager?
    private(set) var isScanning = false
    private var isRelayScanning = false
    private var pausedDisneyScanForRelay = false
    private var recentKeys: [String: Date] = [:]
    private let dedupeMs: TimeInterval = 1.5
    let relayGatt = AndroidRelayGattClient()
    var disneyScanRequested: (() -> Bool)?

    override init() {
        super.init()
        relayGatt.scanCoordinator = self
    }

    /// Creates CBCentralManager on first use so launch finishes before CoreBluetooth starts.
    @discardableResult
    func activateIfNeeded() -> CBCentralManager? {
        if let central { return central }
        let manager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: nil
        )
        central = manager
        return manager
    }

    var relayStatus: String { relayGatt.statusLabel }

    func pauseScanForRelayConnect() {
        pausedDisneyScanForRelay = isScanning
        central?.stopScan()
        isScanning = false
        isRelayScanning = false
    }

    func resumeScanAfterRelayConnect(restartDisneyScan: Bool) {
        let wantDisney = restartDisneyScan || pausedDisneyScanForRelay || (disneyScanRequested?() ?? false)
        pausedDisneyScanForRelay = false
        if wantDisney {
            startScan()
        } else if !relayGatt.isCommandReady && !relayGatt.isReady && !relayGatt.isLinkInProgress {
            startRelayDiscovery()
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            delegate?.bleCentral(didUpdate: "Bluetooth ready")
            if relayGatt.reclaimConnectedRelay(central: central) {
                return
            }
            startRelayDiscovery()
        case .poweredOff:
            stopScan()
            stopRelayDiscovery()
            delegate?.bleCentral(didUpdate: "Turn on Bluetooth")
        case .unauthorized:
            delegate?.bleCentral(didUpdate: "Allow Bluetooth in Settings")
        default:
            delegate?.bleCentral(didUpdate: "Bluetooth unavailable")
        }
    }

    func startScan() {
        guard let central = activateIfNeeded(), central.state == .poweredOn else { return }
        stopRelayDiscovery()
        guard !isScanning else { return }
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        isScanning = true
        pausedDisneyScanForRelay = false
        delegate?.bleCentralScanningChanged(true)
        delegate?.bleCentral(didUpdate: "Listening for Disney BLE…")
    }

    func stopScan() {
        guard isScanning else { return }
        central?.stopScan()
        isScanning = false
        delegate?.bleCentralScanningChanged(false)
        startRelayDiscovery()
    }

    func restartScan() {
        stopScan()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startScan()
        }
    }

    func reconnectRelay() {
        guard let central = activateIfNeeded(), central.state == .poweredOn else { return }
        guard RelayBackend.load().usesBleRelayLink else { return }
        if relayGatt.isCommandReady { return }
        if relayGatt.ensureLink(central: central) { return }
        if relayGatt.isLinkInProgress { return }
        relayGatt.resetForRetry(central: central)
        pauseScanForRelayConnect()
        startRelayDiscovery()
    }

    func ensureRelayLink() {
        guard let central = activateIfNeeded(), central.state == .poweredOn else { return }
        guard RelayBackend.load().usesBleRelayLink else { return }
        if relayGatt.isCommandReady { return }
        // The link wedged (dropped, or connected but never finished discovery) and never recovered.
        // Force a clean retry so we reconnect on our own instead of needing an app restart.
        if relayGatt.isLinkStuck {
            relayGatt.resetForRetry(central: central)
            startRelayDiscovery()
            return
        }
        if relayGatt.ensureLink(central: central) { return }
        if relayGatt.isLinkInProgress || relayGatt.isReady { return }
        if isScanning {
            // Disney/iScan scan uses nil services — relay ads still arrive via didDiscover → handleDiscovery.
            return
        }
        startRelayDiscovery()
    }

    func startRelayDiscovery() {
        guard let central = activateIfNeeded(), central.state == .poweredOn else { return }
        guard RelayBackend.load().usesBleRelayLink else { return }
        if relayGatt.isCommandReady || relayGatt.isReady { return }
        if relayGatt.isLinkInProgress { return }
        if relayGatt.reclaimConnectedRelay(central: central) { return }
        guard !isRelayScanning else { return }
        if isScanning {
            return
        }
        central.scanForPeripherals(
            withServices: [AndroidRelayGattClient.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        isRelayScanning = true
        delegate?.bleCentral(didUpdate: "Scanning for MagicMaker-Android…")
    }

    func stopRelayDiscovery() {
        guard isRelayScanning else { return }
        if !isScanning {
            central?.stopScan()
        }
        isRelayScanning = false
    }

    func transmitViaRelayGatt(hex: String, durationMs: Double, completion: @escaping (Bool) -> Void) {
        guard let central = activateIfNeeded() else {
            completion(false)
            return
        }
        relayGatt.transmit(hex: hex, durationMs: durationMs, central: central, onComplete: completion)
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // No restore identifier — state restoration disabled for launch stability.
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if relayGatt.handleDiscovery(peripheral, advertisementData: advertisementData, central: central) {
            return
        }

        if relayGatt.isRelayPeripheral(peripheral) {
            return
        }

        guard isScanning else { return }
        guard let hex = extractHex(from: advertisementData) else { return }
        let canonical = HexUtils.canonicalHex(hex)
        guard HexUtils.isDisneyBlePacket(canonical) else { return }

        let dedupeKey: String
        if HexUtils.isStarlightPacket(canonical) {
            dedupeKey = "SL:\(MagicClassifier.starlightColorIndex(canonical))"
        } else if MagicClassifier.classify(canonical) == nil {
            dedupeKey = "RAW:\(canonical)"
        } else {
            dedupeKey = canonical
        }
        let now = Date()
        if let last = recentKeys[dedupeKey], now.timeIntervalSince(last) < dedupeMs { return }
        recentKeys[dedupeKey] = now
        if recentKeys.count > 256 { recentKeys.remove(at: recentKeys.startIndex) }

        delegate?.bleCentral(didReceive: canonical, rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        relayGatt.onCentralDidConnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        relayGatt.onCentralDidFailToConnect(peripheral, central: central, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        relayGatt.onCentralDidDisconnect(peripheral)
        if !relayGatt.isLinkInProgress {
            startRelayDiscovery()
        }
    }

    private func extractHex(from advertisementData: [String: Any]) -> String? {
        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           HexUtils.isDisneyManufacturerData(mfg) {
            return HexUtils.canonicalFromMfgData(mfg)
        }
        if let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
           let hex = HexUtils.hexFromMagicMakerLocalName(name) {
            return hex
        }
        if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            for uuid in uuids {
                if let hex = HexUtils.hexFromAdvertisementUUID(uuid) {
                    return hex
                }
            }
        }
        if let data = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
           let first = data.values.first {
            return HexUtils.extractDisneyPayload(ad: [UInt8](first)).map { HexUtils.canonicalHex($0) }
        }
        return nil
    }
}
