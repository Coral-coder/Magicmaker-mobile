import Foundation
import UIKit

/// Builds what the iPhone sends the watch (docs/WATCH_APP.md 4.5): the favourites with their
/// time on air at the current settings, the VFD inks of the iPhone's base colour, and the status
/// of the cluster as this iPhone knows it today (the selected relay backend's link state and
/// STATUS, and the iPhone's own battery, scan, AUTO and last heard packet).
@MainActor
enum WatchContextBuilder {
    /// A full context (favourites, theme, status when a view model exists, `lastSend`).
    static func full(vm: AppViewModel?, lastSend: WatchSendResult?) -> WatchContext {
        var status: WatchStatus? = nil
        if let vm {
            status = WatchContextBuilder.status(vm)
        }
        return WatchContext(
            at: Date().timeIntervalSince1970,
            favorites: favorites(vm),
            status: status,
            theme: theme(),
            lastSend: lastSend
        )
    }

    /// `at` and the status only (the snapshot part of a send or stop reply).
    static func statusOnly(vm: AppViewModel) -> WatchContext {
        return WatchContext(at: Date().timeIntervalSince1970, status: status(vm))
    }

    /// The relay a send goes through.
    static func viaName(_ backend: RelayBackend) -> String {
        switch backend {
        case .esp32: return WatchProtocol.viaEsp32
        case .androidBle: return WatchProtocol.viaAndroidBle
        case .androidWifi: return WatchProtocol.viaAndroidWifi
        }
    }

    // MARK: - Favourites

    /// The stored favourites, the quick button's following the button first, each with the time
    /// on air it gets at the current timing settings (display only).
    static func favorites(_ vm: AppViewModel?) -> [WatchFavorite] {
        let store: WatchFavoritesStore = WatchFavoritesStore.shared
        store.reloadIfNeeded()
        if let vm, store.isQuickStarred {
            vm.reloadWandQuickIfChanged()
            store.followQuick(label: vm.wandQuickLabel, hex: vm.wandQuickHex)
        }
        var out: [WatchFavorite] = store.items
        guard let magic = vm?.store else { return out }
        for index in out.indices {
            switch out[index].burst {
            case WatchFavorite.Burst.starlight:
                out[index].onAirMs = magic.getStarlightBurstMs()
            case WatchFavorite.Burst.ping:
                out[index].onAirMs = TransmitTiming.pingBurstMs
            default:
                out[index].onAirMs = magic.getCommandBurstMs()
            }
        }
        return out
    }

    // MARK: - Theme

    /// The five VFD inks of `VFDSettings.shared.base` (whichever iPhone theme is on: the watch
    /// always uses the VFD look).
    static func theme() -> WatchThemeColors {
        let base: VFDBase = VFDSettings.shared.base
        let p: [VFDRGB] = VFDPalette.colors(for: base)
        if p.count < 5 { return WatchThemeColors.amber }
        return WatchThemeColors(
            highlight: p[1].hex,
            text: p[2].hex,
            dim: p[3].hex,
            alarm: p[4].hex,
            alarmInverted: VFDPalette.alarmInverted(base)
        )
    }

    // MARK: - Status

    static func status(_ vm: AppViewModel) -> WatchStatus {
        let backend: RelayBackend = vm.relayBackend
        let linked: Bool = vm.remoteLinkReady
        let hint: String = vm.remoteLinkHint
        return WatchStatus(
            selected: viaName(backend),
            linked: linked,
            hint: hint.uppercased(),
            esp32: esp32Status(vm, backend: backend, linked: linked, hint: hint),
            android: androidStatus(vm, backend: backend, linked: linked, hint: hint),
            phone: phoneStatus(vm, backend: backend)
        )
    }

    /// LINKED, LINKING (the hint says the link is being finished), NOT LINKED.
    private static func linkState(linked: Bool, hint: String) -> String {
        if linked { return "LINKED" }
        if hint.hasPrefix("Finishing") { return "LINKING" }
        return "NOT LINKED"
    }

    /// The board's numbers only while it is the selected backend and its GATT link is up, as the
    /// telemetry bar's battery token (an unlinked board never shows its old battery).
    private static func esp32Status(_ vm: AppViewModel, backend: RelayBackend, linked: Bool,
                                    hint: String) -> WatchEsp32Status {
        var out = WatchEsp32Status(state: "NOT SELECTED", batteryPct: nil, batteryMv: nil, runtimeMin: nil,
                                   charging: false, program: nil, firmware: nil, board: nil, uptimeS: nil,
                                   outdated: false)
        if backend != .esp32 { return out }
        out.state = linkState(linked: linked, hint: hint)
        out.outdated = vm.esp32FirmwareOutdated
        guard vm.relayGattReady, let report = vm.androidRemote else { return out }
        out.batteryPct = report.batteryPercent
        out.batteryMv = report.batteryMv
        out.runtimeMin = report.runtimeMinutes
        out.charging = report.charging
        out.program = report.esp32ProgramText
        out.firmware = nonEmpty(report.firmware)
        out.board = nonEmpty(report.board)
        out.uptimeS = report.uptimeS
        return out
    }

    private static func androidStatus(_ vm: AppViewModel, backend: RelayBackend, linked: Bool,
                                      hint: String) -> WatchAndroidStatus {
        var out = WatchAndroidStatus(state: "NOT SELECTED", transport: "", scanning: nil, autoArmed: nil,
                                     keepAwake: nil, program: nil, lastHeardLabel: nil)
        switch backend {
        case .esp32:
            return out
        case .androidBle:
            out.transport = "BLE"
        case .androidWifi:
            out.transport = "WIFI"
        }
        out.state = linkState(linked: linked, hint: hint)
        guard linked, let report = vm.androidRemote else { return out }
        out.scanning = report.scanActive
        out.autoArmed = report.autoEnabled
        out.keepAwake = report.keepAwake
        out.program = report.esp32ProgramText
        out.lastHeardLabel = nonEmpty(report.lastHeardLabel)
        return out
    }

    private static func phoneStatus(_ vm: AppViewModel, backend: RelayBackend) -> WatchPhoneStatus {
        let device: UIDevice = UIDevice.current
        let level: Float = device.batteryLevel
        var battery: Int? = nil
        if level >= 0 && level.isFinite {
            battery = Int((level * 100).rounded())
        }
        let charging: Bool = device.batteryState == .charging || device.batteryState == .full
        let scan: ScanEngine = vm.scan
        let tx: TxEngine = vm.tx
        var heardAt: Double? = nil
        if let newest = scan.rawLivePackets.first {
            heardAt = Double(newest.timestampMs) / 1000.0
        }
        var programs: [String] = []
        // The ESP32 runs the TX and wand loops itself: they show under its program.
        if backend != .esp32 {
            if tx.txLoopEnabled {
                programs.append("TX LOOP · " + secondsText(tx.txLoopIntervalMs))
            }
            if tx.starlightLoopEnabled {
                programs.append("WAND LOOP · " + secondsText(tx.starlightIntervalMs))
            }
        }
        if tx.randomShowEnabled {
            programs.append("RANDOM SHOW")
        }
        if tx.replayActive {
            programs.append("REPLAY \(tx.replayProgress)/\(tx.replayTotal)")
        }
        return WatchPhoneStatus(
            batteryPct: battery,
            charging: charging,
            bluetooth: scan.bluetoothStatus.uppercased(),
            scanning: scan.scanActive,
            foreground: UIApplication.shared.applicationState == .active,
            autoArmed: scan.autoEnabled,
            lastHeardLabel: scan.lastHeardLabel,
            lastHeardAt: heardAt,
            txStatus: tx.status.uppercased(),
            transmitting: tx.isTransmitting,
            programs: programs
        )
    }

    /// "3.0S", as the TX and WAND tabs print a loop interval.
    private static func secondsText(_ ms: Int) -> String {
        return TxLoopInterval.text(TxLoopInterval.seconds(fromMilliseconds: ms)) + "S"
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let trimmed: String = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
