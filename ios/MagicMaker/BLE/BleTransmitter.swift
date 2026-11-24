import Foundation

@MainActor
final class BleTransmitter {
    var onStatus: ((String) -> Void)?

    private unowned let central: BleCentral
    private let wifiRelay = AndroidWifiRelayClient.shared

    /// esp32_magicband timing: 420ms wakeup prelude, 2s command burst
    private enum Timing {
        static let burstMs = 2_000.0
        static let wakeupGapMs = 420.0
        static let wakeupPreludeMs = 420.0
        static let pingBurstMs = 2_000.0
        static let starlightBurstMs = 500.0
    }

    var relayBackend: RelayBackend = RelayBackend.load() {
        didSet { RelayBackend.save(relayBackend) }
    }

    init(central: BleCentral) {
        self.central = central
        central.relayGatt.onStatus = { [weak self] msg in
            guard RelayBackend.load().usesBleRelayLink else { return }
            self?.onStatus?(msg)
        }
        wifiRelay.onStatus = { [weak self] msg in
            guard RelayBackend.load().usesWifiRelay else { return }
            self?.onStatus?(msg)
        }
    }

    var relayStatus: String {
        switch relayBackend {
        case .androidWifi:
            return wifiRelay.lastStatus
        case .androidBle, .esp32:
            return central.relayStatus
        }
    }

    var androidRelayReady: Bool {
        relayBackend = RelayBackend.load()
        switch relayBackend {
        case .androidBle, .esp32:
            return central.relayGatt.isReady
        case .androidWifi:
            return wifiRelay.lastStatus.contains("Connected")
        }
    }

    func reconnectRelay() {
        relayBackend = RelayBackend.load()
        guard relayBackend.usesBleRelayLink else {
            if relayBackend.usesWifiRelay {
                wifiRelay.refreshStatus()
            }
            return
        }
        central.reconnectRelay()
    }

    func startRelayDiscovery() {
        relayBackend = RelayBackend.load()
        guard relayBackend.usesBleRelayLink else { return }
        central.startRelayDiscovery()
    }

    func transmitPacket(_ packet: MagicPacket, onComplete: @escaping () -> Void) {
        if packet.typeInfo == "starlight" {
            transmit(hex: packet.hex, durationMs: Timing.starlightBurstMs, onComplete: onComplete)
        } else if packet.typeInfo == "ping" || packet.hex.uppercased() == PresetCatalog.wakeupPing.uppercased() {
            transmit(hex: packet.hex, durationMs: Timing.pingBurstMs, onComplete: onComplete)
        } else {
            transmitWithWakeup(hex: packet.hex, onComplete: onComplete)
        }
    }

    func transmit(hex: String, durationMs: Double, onComplete: @escaping () -> Void) {
        transmit(hex: hex, durationMs: durationMs, onResult: { _ in onComplete() })
    }

    /// The same send, reporting whether the relay took the packet.
    func transmit(hex: String, durationMs: Double, onResult: @escaping (Bool) -> Void) {
        relayBackend = RelayBackend.load()

        switch relayBackend {
        case .androidWifi:
            wifiRelay.transmit(hex: hex, durationMs: durationMs) { [weak self] success in
                if !success {
                    self?.onStatus?("Transmit failed — join Android hotspot, verify IP on LINK")
                }
                onResult(success)
            }
        case .androidBle, .esp32:
            if !central.relayGatt.isReady {
                let target = relayBackend == .esp32 ? "MM_ESP" : "MagicMaker-Android"
                onStatus?("Waiting for \(target) — tap Retry in Remote")
                central.reconnectRelay()
                onResult(false)
                return
            }
            // The relay (Android or ESP32 firmware) adds the wakeup preamble for band packets.
            central.transmitViaRelayGatt(hex: hex, durationMs: durationMs) { [weak self] success in
                if !success {
                    self?.onStatus?("Transmit failed — check relay")
                }
                onResult(success)
            }
        }
    }

    /// Band commands: Android handles wakeup prelude when relaying over GATT.
    private func transmitWithWakeup(hex: String, onComplete: @escaping () -> Void) {
        transmit(hex: hex, durationMs: Timing.burstMs, onComplete: onComplete)
    }
}
