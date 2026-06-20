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
        case .androidBle:
            return central.relayStatus
        }
    }

    var androidRelayReady: Bool {
        relayBackend = RelayBackend.load()
        switch relayBackend {
        case .androidBle:
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
        relayBackend = RelayBackend.load()

        switch relayBackend {
        case .androidWifi:
            wifiRelay.transmit(hex: hex, durationMs: durationMs) { [weak self] success in
                if !success {
                    self?.onStatus?("Transmit failed — join Android hotspot, verify IP on LINK")
                }
                onComplete()
            }
        case .androidBle:
            if !central.relayGatt.isReady {
                onStatus?("Waiting for MagicMaker-Android — tap Retry in Remote")
                central.reconnectRelay()
                onComplete()
                return
            }
            // Android MagicTransmitter adds wakeup preamble for band packets.
            central.transmitViaRelayGatt(hex: hex, durationMs: durationMs) { [weak self] success in
                if !success {
                    self?.onStatus?("Transmit failed — check Android relay")
                }
                onComplete()
            }
        }
    }

    /// Band commands: Android handles wakeup prelude when relaying over GATT.
    private func transmitWithWakeup(hex: String, onComplete: @escaping () -> Void) {
        transmit(hex: hex, durationMs: Timing.burstMs, onComplete: onComplete)
    }
}
