import CoreBluetooth
import Foundation

protocol BleCentralDelegate: AnyObject {
    /// `address` identifies the advertiser: its CoreBluetooth identifier as an uppercased UUID
    /// string (iOS never exposes the radio address).
    func bleCentral(didReceive hex: String, rssi: Int, address: String)
    func bleCentral(didUpdate status: String)
    func bleCentralScanningChanged(_ scanning: Bool)
    /// The Bluetooth radio changed state; `description` is `BleCentral.stateDescription`.
    func bleCentralStateChanged(_ description: String)
}

final class BleCentral: NSObject, CBCentralManagerDelegate, RelayGattScanning {
    weak var delegate: BleCentralDelegate?

    private var central: CBCentralManager?
    private(set) var isScanning = false
    private var isRelayScanning = false
    private var pausedDisneyScanForRelay = false
    /// "Bluetooth ready", "Turn on Bluetooth", "Allow Bluetooth in Settings" or
    /// "Bluetooth unavailable" (also the value until the radio first reports).
    private(set) var stateDescription: String = "Bluetooth unavailable"
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
        stateDescription = Self.describe(central.state)
        switch central.state {
        case .poweredOn:
            // Any earlier scan ended when the radio left the powered-on state.
            isScanning = false
            isRelayScanning = false
            reportState()
            if relayGatt.reclaimConnectedRelay(central: central) {
                return
            }
            let wantDisney: Bool = disneyScanRequested?() ?? false
            if wantDisney {
                // Listening was asked for before the radio was ready, or Bluetooth was switched
                // back on. The relay is still found through this scan (see ensureRelayLink).
                startScan()
            } else {
                startRelayDiscovery()
            }
        case .poweredOff:
            stopScan()
            stopRelayDiscovery()
            // No didDisconnectPeripheral arrives when the radio goes down, so drop the relay link
            // here; otherwise it still looks ready and the next power-on never relinks.
            relayGatt.resetForRetry(central: central)
            reportState()
        default:
            relayGatt.resetForRetry(central: central)
            reportState()
        }
    }

    private static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn:
            return "Bluetooth ready"
        case .poweredOff:
            return "Turn on Bluetooth"
        case .unauthorized:
            return "Allow Bluetooth in Settings"
        default:
            return "Bluetooth unavailable"
        }
    }

    private func reportState() {
        delegate?.bleCentralStateChanged(stateDescription)
        delegate?.bleCentral(didUpdate: stateDescription)
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
        let target: String = AndroidRelayGattClient.targetLabel(for: RelayBackend.load())
        delegate?.bleCentral(didUpdate: "Scanning for \(target)…")
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
        // An "MM:<hex>" name is another phone asking a relay to send, not a packet on air.
        if let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
           HexUtils.hexFromMagicMakerLocalName(name) != nil {
            return
        }
        // A relay's own advertisement is never a heard packet, whichever relay is selected.
        if advertisesRelayService(advertisementData) { return }
        guard let hex = extractHex(from: advertisementData) else { return }
        // 127 is CoreBluetooth's reserved 'RSSI not available' value, not a reading.
        if RSSI.intValue == 127 { return }

        // Every advertisement is passed on: counts, logs and signal weighting need them all.
        let address = peripheral.identifier.uuidString.uppercased()
        delegate?.bleCentral(didReceive: hex, rssi: RSSI.intValue, address: address)
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

    /// The relay service UUID, or the relay's service-data tag (the Android relay's "MM_AND").
    private func advertisesRelayService(_ advertisementData: [String: Any]) -> Bool {
        AndroidRelayGattClient.advertisesRelayService(advertisementData)
    }

    /// The best Disney payload in one advertisement, as canonical hex. Every place a payload can
    /// sit is a candidate (manufacturer data, service UUIDs, service data) and the highest-ranked
    /// one wins, as on Android.
    private func extractHex(from advertisementData: [String: Any]) -> String? {
        var manufacturer: [UInt8]? = nil
        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            manufacturer = [UInt8](mfg)
        }

        var serviceData: [[UInt8]] = []
        if let entries = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            // A fixed order, so two equally ranked entries always resolve the same way.
            let keys: [CBUUID] = entries.keys.sorted { $0.uuidString < $1.uuidString }
            for key in keys {
                if let value = entries[key] {
                    serviceData.append([UInt8](value))
                }
            }
        }

        var serviceUUIDs: [[UInt8]] = []
        if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            for uuid in uuids {
                serviceUUIDs.append([UInt8](uuid.data))
            }
        }

        let candidates: [String] = HexUtils.extractDisneyCandidates(
            manufacturerData: manufacturer,
            serviceData: serviceData,
            serviceUUIDBytes: serviceUUIDs,
            localName: nil
        )
        if candidates.isEmpty { return nil }
        return HexUtils.bestDisneyHex(candidates: candidates)
    }
}
