import Foundation
import UIKit

@MainActor
final class BleCoordinator: NSObject, BleCentralDelegate {
    private let central = BleCentral()
    private lazy var transmitter: BleTransmitter = {
        let t = BleTransmitter(central: central)
        t.onStatus = { [weak self] msg in
            Task { @MainActor in self?.onStatus?(msg) }
        }
        return t
    }()
    private var autoCooldownUntil = Date.distantPast
    private var isTransmitting = false
    // Each `send` gets a number, so a result the relay link reports twice is acted on once.
    private var sendSerial = 0
    private var activeSendSerial = 0

    /// hex, RSSI, source id (the advertiser's CoreBluetooth identifier, uppercased).
    var onPacket: ((String, Int, String) -> Void)?
    var onStatus: ((String) -> Void)?
    /// "Bluetooth ready", "Turn on Bluetooth", "Allow Bluetooth in Settings" or "Bluetooth unavailable".
    var onBluetoothState: ((String) -> Void)?
    var onAutoResponse: ((String, String) -> Void)?
    var onRelayCommandReady: (() -> Void)?
    var onCatalogReceived: (([String: Any]?) -> Void)?

    var store: MagicStore?
    var isRecording = false
    var isAutoEnabled = false
    var isLocalListening = false

    private var shouldListenForDisney: Bool {
        isRecording || isAutoEnabled || isLocalListening
    }

    override init() {
        super.init()
        central.delegate = self
        central.disneyScanRequested = { [weak self] in
            self?.shouldListenForDisney ?? false
        }
        central.relayGatt.onCommandReady = { [weak self] in
            Task { @MainActor in self?.onRelayCommandReady?() }
        }
        central.relayGatt.onCatalogReceived = { [weak self] json in
            Task { @MainActor in self?.onCatalogReceived?(json) }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenLocked),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenUnlocked),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    /// Deferred from init — starts CoreBluetooth after UIKit finishes launching.
    func activateBluetooth() {
        central.activateIfNeeded()
        transmitter.startRelayDiscovery()
    }

    func updateModes(recording: Bool, auto: Bool, listening: Bool = false) {
        isRecording = recording
        isAutoEnabled = auto
        isLocalListening = listening
        if shouldListenForDisney {
            central.startScan()
        } else {
            central.stopScan()
            onStatus?("BLE idle")
        }
    }

    func play(hex: String, label: String, typeInfo: String, category: MagicCategory, onComplete: (() -> Void)? = nil) {
        if isTransmitting {
            onStatus?("Wait — still transmitting")
            onComplete?()
            return
        }
        if HexUtils.legacyAdvertiseRejectReason(hex) != nil && !transmitter.androidRelayReady {
            onStatus?("Link Android relay on LINK tab — iPhone cannot TX locally")
            onComplete?()
            return
        }
        isTransmitting = true
        let shouldPause = shouldListenForDisney
        if shouldPause { central.stopScan() }
        onStatus?("Transmitting \(label)")

        let packet = MagicPacket(hex: hex, label: label, category: category, typeInfo: typeInfo, colors: "", simKey: "")
        transmitter.transmitPacket(packet) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isTransmitting = false
                if shouldPause { self.central.startScan() }
                onComplete?()
            }
        }
    }

    /// One packet on air for exactly `durationMs` through the linked relay, with the local scan
    /// paused meanwhile as in `play`. Reports false when no relay is ready (nothing is sent),
    /// when another send is still on air, or when the relay did not take the packet.
    func send(hex: String, durationMs: Int, onComplete: @escaping (Bool) -> Void) {
        if isTransmitting {
            onStatus?("Wait — still transmitting")
            onComplete(false)
            return
        }
        guard relayReadyToSend else {
            onComplete(false)
            return
        }
        isTransmitting = true
        let shouldPause = shouldListenForDisney
        if shouldPause { central.stopScan() }

        sendSerial += 1
        let serial = sendSerial
        activeSendSerial = serial
        let startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
        transmitter.transmit(hex: hex, durationMs: Double(durationMs), onResult: { [weak self] success in
            Task { @MainActor in
                guard let self else { return }
                guard self.activeSendSerial == serial else { return }
                self.activeSendSerial = 0
                if success {
                    // The BLE link answers once the burst is over, the WiFi relay as soon as it
                    // has queued the packet. Either way the send ends when durationMs has passed.
                    let elapsed: TimeInterval = ProcessInfo.processInfo.systemUptime - startedAt
                    let elapsedMs = Int(elapsed * 1000)
                    var remainingMs = durationMs - elapsedMs
                    if remainingMs > durationMs { remainingMs = durationMs }
                    if remainingMs > 600_000 { remainingMs = 600_000 }
                    if remainingMs > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(remainingMs) * 1_000_000)
                    }
                }
                self.isTransmitting = false
                if shouldPause { self.central.startScan() }
                onComplete(success)
            }
        })
    }

    /// A relay that can take a packet right now. The WiFi relay keeps no link to check; its
    /// answer to the request decides.
    private var relayReadyToSend: Bool {
        switch RelayBackend.load() {
        case .androidBle, .esp32:
            return central.relayGatt.isReady
        case .androidWifi:
            return true
        }
    }

    func bleCentral(didReceive hex: String, rssi: Int, address: String) {
        onPacket?(hex, rssi, address)
        guard isAutoEnabled, !isTransmitting else { return }
        guard Date() >= autoCooldownUntil else { return }
        guard let store else { return }

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

        guard let responseHex = store.findAutoResponse(classified: classified, rawHex: hex) else { return }

        autoCooldownUntil = Date().addingTimeInterval(0.8)
        onAutoResponse?(classified.label, responseHex)
        if let responseClassified = MagicClassifier.classify(responseHex) {
            play(hex: responseHex, label: "Auto → \(classified.label)", typeInfo: responseClassified.typeInfo, category: responseClassified.category)
        } else {
            play(hex: responseHex, label: "Auto → \(classified.label)", typeInfo: "raw", category: .unknown)
        }
    }

    func bleCentral(didUpdate status: String) {
        onStatus?(status)
    }

    func bleCentralScanningChanged(_ scanning: Bool) {
        if scanning, shouldListenForDisney {
            onStatus?("Listening (background OK)")
        }
    }

    func bleCentralStateChanged(_ description: String) {
        onBluetoothState?(description)
    }

    /// The Bluetooth radio's state right now, in the words `onBluetoothState` reports.
    var bluetoothState: String {
        central.stateDescription
    }

    func reconnectRelay() {
        transmitter.reconnectRelay()
        onStatus?("Looking for relay…")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.resumeListeningIfDropped()
        }
    }

    func ensureRelayLink() {
        central.ensureRelayLink()
        resumeListeningIfDropped()
    }

    /// A relay retry stops the Disney scan until the relay links. With no relay in range that
    /// never happens, so listening is picked up again once no link attempt is running; the
    /// relay is still found through that scan.
    private func resumeListeningIfDropped() {
        guard shouldListenForDisney, !isTransmitting else { return }
        guard !central.isScanning, !central.relayGatt.isLinkInProgress else { return }
        central.startScan()
    }

    var relayStatus: String {
        transmitter.relayStatus
    }

    var bleCentral: BleCentral { central }

    @objc private func screenLocked() {
        guard shouldListenForDisney else { return }
        central.restartScan()
    }

    @objc private func screenUnlocked() {
        guard shouldListenForDisney else { return }
        central.restartScan()
    }
}
