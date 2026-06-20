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

    var onPacket: ((String, Int) -> Void)?
    var onStatus: ((String) -> Void)?
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

    func bleCentral(didReceive hex: String, rssi: Int) {
        onPacket?(hex, rssi)
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

    func reconnectRelay() {
        transmitter.reconnectRelay()
        onStatus?("Looking for relay…")
    }

    func ensureRelayLink() {
        central.ensureRelayLink()
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
