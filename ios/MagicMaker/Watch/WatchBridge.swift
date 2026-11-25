import Combine
import Foundation
import UIKit
import WatchConnectivity

/// The iPhone end of the Apple Watch link (docs/WATCH_APP.md sections 3 and 4).
///
/// iPhone -> watch: one application context {v, at, favorites, status, theme, lastSend}, pushed at
/// most every 2 s (trailing edge) and at once when the favourites or the theme change, skipped
/// when nothing the watch shows changed. Watch -> iPhone: `send`, `stop_programs` and `refresh`
/// messages, each answered exactly once within 7 s. A watch send is the iPhone row's own send
/// (`TxEngine.transmit` and the TX / WAND tab loop rules), so burst lengths, wake preambles, the
/// selected relay and queueing are exactly the iPhone's.
///
/// `start()` runs in `MagicMakerApp.init`: iOS hands a message that launched the app only to a
/// session activated during launch. Such a wake may have no screen, so a message builds the
/// app's engines itself (`BootstrapController.shared`).
///
/// The class is not actor-isolated (like `VFDSettings`), so `shared` can be read anywhere; its
/// state is touched on the main actor only, and the WatchConnectivity delegate callbacks (on a
/// background queue) parse what they got and hop to the main actor.
final class WatchBridge: NSObject, ObservableObject, WCSessionDelegate, @unchecked Sendable {
    static let shared: WatchBridge = WatchBridge()

    /// The SETTINGS → APPLE WATCH link line.
    enum LinkState: Equatable {
        /// No WatchConnectivity on this device (iPad).
        case unsupported
        case starting
        case notPaired
        case notInstalled
        /// Installed, the watch app not open.
        case installed
        /// The watch app is open and reachable.
        case live
    }

    @Published private(set) var linkState: LinkState = .starting
    /// When the watch last got the current context (a push, or a check that found it current).
    @Published private(set) var lastPushAt: Date? = nil

    /// The reply budget: every message is answered this long after it arrived, at the latest.
    static let replySeconds: Double = 7
    /// Of that, at most this long waiting for the relay to link.
    static let linkWaitSeconds: Double = 4
    /// Pushes not asked for at once are at most this often.
    static let pushSpacingSeconds: Double = 2
    /// A push whose only change is telemetry (the ESP32's uptime and battery numbers, new on every
    /// 2 s STATUS read; the iPhone's battery, TX line and last heard packet) waits this long since
    /// the last push. Otherwise a linked board would push every 2 s for as long as the app is
    /// open. STATUS on the watch asks for a fresh snapshot every 10 s while it is shown.
    static let telemetrySpacingSeconds: Double = 60
    /// A background wake ends this long after the message at the latest.
    static let backgroundCeilingSeconds: Double = 20

    private var started: Bool = false
    private var viewModel: AppViewModel?
    private var baseSubscriptions: [AnyCancellable] = []
    private var modelSubscriptions: [AnyCancellable] = []
    private var pushTask: Task<Void, Never>?
    private var pushImmediate: Bool = false
    /// Uptime of the last push attempt, for the 2 s spacing.
    private var lastPushUptime: Double = -1_000
    /// Content of the last context the watch got (without `at`), to skip unchanged pushes.
    private var lastDigest: Data?
    /// The same without telemetry, and the uptime of that push (telemetrySpacingSeconds).
    private var lastCoreDigest: Data?
    private var lastSentUptime: Double = -1_000
    /// The final result of the last watch send whose reply went out before it ended.
    private var lastSend: WatchSendResult?
    private var nextOpSerial: Int = 0

    private override init() {
        super.init()
    }

    // MARK: - Start

    /// Activates the session (from `MagicMakerApp.init`, before any scene). Does nothing on a
    /// device without WatchConnectivity.
    func start() {
        guard WCSession.isSupported() else {
            Task { @MainActor [weak self] in
                self?.refreshLink()
            }
            return
        }
        if started { return }
        started = true
        let session: WCSession = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Called when the app's engines exist (BootstrapController.start): the status now has a
    /// source, and its changes drive the pushes.
    @MainActor
    func attach(_ vm: AppViewModel) {
        if viewModel === vm { return }
        viewModel = vm
        UIDevice.current.isBatteryMonitoringEnabled = true
        ensureBaseSubscriptions()
        var subs: [AnyCancellable] = []
        subs.append(vm.objectWillChange.sink { [weak self] _ in
            self?.schedulePush(immediate: false)
        })
        subs.append(vm.tx.objectWillChange.sink { [weak self] _ in
            self?.schedulePush(immediate: false)
        })
        subs.append(vm.scan.objectWillChange.sink { [weak self] _ in
            self?.schedulePush(immediate: false)
        })
        let center: NotificationCenter = NotificationCenter.default
        let names: [Notification.Name] = [
            UIDevice.batteryLevelDidChangeNotification,
            UIDevice.batteryStateDidChangeNotification,
            UIApplication.didBecomeActiveNotification,
            UIApplication.didEnterBackgroundNotification,
        ]
        for name in names {
            subs.append(center.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.schedulePush(immediate: false)
                })
        }
        modelSubscriptions = subs
        schedulePush(immediate: true)
    }

    /// Favourites and the VFD base colour push at once, with or without a view model.
    @MainActor
    private func ensureBaseSubscriptions() {
        if !baseSubscriptions.isEmpty { return }
        var subs: [AnyCancellable] = []
        subs.append(WatchFavoritesStore.shared.objectWillChange.sink { [weak self] _ in
            self?.schedulePush(immediate: true)
        })
        subs.append(VFDSettings.shared.$base
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.schedulePush(immediate: true)
            })
        baseSubscriptions = subs
    }

    /// The app's engines, built now when no screen has built them (a background wake).
    @MainActor
    func ensureViewModel() -> AppViewModel {
        return BootstrapController.shared.start()
    }

    // MARK: - SETTINGS link line

    /// The SETTINGS → APPLE WATCH line for `linkState` (the sync age is counted to `now`).
    func linkText(now: Date) -> String {
        switch linkState {
        case .unsupported:
            return "NOT AVAILABLE ON THIS DEVICE"
        case .starting:
            return "STARTING…"
        case .notPaired:
            return "NO APPLE WATCH PAIRED"
        case .notInstalled:
            return "WATCH APP NOT INSTALLED — WATCH APP ON IPHONE → AVAILABLE APPS"
        case .installed:
            guard let pushed = lastPushAt else { return "WATCH APP INSTALLED · NOT SYNCED YET" }
            return "WATCH APP INSTALLED · SYNCED " + WatchBridge.ageText(now.timeIntervalSince(pushed)) + " AGO"
        case .live:
            return "WATCH APP OPEN · LIVE"
        }
    }

    /// "12S", "4M", "2H 5M"; clock skew reads 0S.
    static func ageText(_ seconds: Double) -> String {
        if !seconds.isFinite || seconds < 0 { return "0S" }
        let s: Int = Int(seconds)
        if s < 60 { return "\(s)S" }
        if s < 3600 { return "\(s / 60)M" }
        return "\(s / 3600)H \((s % 3600) / 60)M"
    }

    @MainActor
    private func refreshLink() {
        let next: LinkState
        if !WCSession.isSupported() {
            next = .unsupported
        } else {
            let session: WCSession = WCSession.default
            if session.activationState != .activated {
                next = .starting
            } else if !session.isPaired {
                next = .notPaired
            } else if !session.isWatchAppInstalled {
                next = .notInstalled
            } else if session.isReachable {
                next = .live
            } else {
                next = .installed
            }
        }
        if linkState != next { linkState = next }
    }

    // MARK: - Pushing the context

    /// immediate: on the next main-actor turn (an `objectWillChange` fires before the change).
    /// Otherwise at most one push per `pushSpacingSeconds`, on the trailing edge.
    @MainActor
    private func schedulePush(immediate: Bool) {
        if immediate {
            if pushTask != nil && pushImmediate { return }
            pushTask?.cancel()
            pushImmediate = true
            pushTask = Task { @MainActor [weak self] in
                if Task.isCancelled { return }
                self?.pushNow()
            }
            return
        }
        if pushTask != nil { return }
        // No watch app to push to (most iPhones): no timer on every change either. Pairing and
        // installing arrive through sessionWatchStateDidChange, which pushes at once.
        if !WatchBridge.watchAppReady() { return }
        let elapsed: Double = ProcessInfo.processInfo.systemUptime - lastPushUptime
        let wait: Double = max(0, WatchBridge.pushSpacingSeconds - elapsed)
        let waitNs: UInt64 = UInt64(wait * 1_000_000_000)
        pushImmediate = false
        pushTask = Task { @MainActor [weak self] in
            if waitNs > 0 {
                try? await Task.sleep(nanoseconds: waitNs)
            }
            if Task.isCancelled { return }
            self?.pushNow()
        }
    }

    /// Sends the context when the watch app is installed and it changed since the last one.
    @MainActor
    private func pushNow() {
        // Called by the scheduled task, or directly (a final send result): either way this push
        // covers whatever was scheduled.
        pushTask?.cancel()
        pushTask = nil
        pushImmediate = false
        lastPushUptime = ProcessInfo.processInfo.systemUptime
        refreshLink()
        guard WatchBridge.watchAppReady() else { return }
        let session: WCSession = WCSession.default
        ensureBaseSubscriptions()
        let context: WatchContext = WatchContextBuilder.full(vm: viewModel, lastSend: lastSend)
        let digest: Data? = WatchBridge.digest(context)
        if let digest, digest == lastDigest {
            lastPushAt = Date()
            return
        }
        let core: Data? = WatchBridge.digest(context, telemetry: false)
        let now: Double = ProcessInfo.processInfo.systemUptime
        if lastDigest != nil, let core, core == lastCoreDigest,
           now - lastSentUptime < WatchBridge.telemetrySpacingSeconds {
            // Only telemetry moved: it goes with the next push.
            return
        }
        do {
            try session.updateApplicationContext(context.dictionary())
            lastDigest = digest
            lastCoreDigest = core
            lastSentUptime = now
            lastPushAt = Date()
        } catch {
            // The next change tries again.
        }
    }

    /// The session is activated and paired, and the watch app is installed.
    private static func watchAppReady() -> Bool {
        guard WCSession.isSupported() else { return false }
        let session: WCSession = WCSession.default
        return session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
    }

    private struct DigestBody: Encodable {
        let favorites: [WatchFavorite]?
        let status: WatchStatus?
        let theme: WatchThemeColors?
        let lastSend: WatchSendResult?
    }

    /// The context without `at`, the last heard packet's time rounded down to 30 s: a park full
    /// of repeating packets then pushes when the heard label changes, not on every packet.
    /// `telemetry: false` also blanks the values that move by themselves (`withoutTelemetry`).
    static func digest(_ context: WatchContext, telemetry: Bool = true) -> Data? {
        var status: WatchStatus? = context.status
        if let heard = status?.phone.lastHeardAt {
            status?.phone.lastHeardAt = (heard / 30).rounded(.down) * 30
        }
        if !telemetry, let full = status {
            status = WatchBridge.withoutTelemetry(full)
        }
        let body = DigestBody(favorites: context.favorites, status: status, theme: context.theme,
                              lastSend: context.lastSend)
        return WatchProtocol.encode(body)
    }

    /// The status with its telemetry blanked: the ESP32's battery numbers and uptime, the
    /// iPhone's battery, TX line and last heard packet, a replay's step. Whether each value is
    /// there stays, so a board that links and first reports its battery still pushes at once,
    /// as do link states, programs, charging, scan and AUTO.
    private static func withoutTelemetry(_ status: WatchStatus) -> WatchStatus {
        var s: WatchStatus = status
        s.esp32.batteryPct = s.esp32.batteryPct.map { (_: Int) -> Int in 0 }
        s.esp32.batteryMv = s.esp32.batteryMv.map { (_: Int) -> Int in 0 }
        s.esp32.runtimeMin = s.esp32.runtimeMin.map { (_: Int) -> Int in 0 }
        s.esp32.uptimeS = s.esp32.uptimeS.map { (_: Int) -> Int in 0 }
        s.phone.batteryPct = s.phone.batteryPct.map { (_: Int) -> Int in 0 }
        s.phone.lastHeardLabel = s.phone.lastHeardLabel.isEmpty ? "" : "*"
        s.phone.lastHeardAt = s.phone.lastHeardAt.map { (_: Double) -> Double in 0 }
        s.phone.txStatus = ""
        s.phone.transmitting = false
        s.phone.programs = s.phone.programs.map { (p: String) -> String in p.hasPrefix("REPLAY") ? "REPLAY" : p }
        s.android.lastHeardLabel = s.android.lastHeardLabel.map { (_: String) -> String in "*" }
        return s
    }

    // MARK: - WCSessionDelegate (any queue)

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        Task { @MainActor [weak self] in
            self?.sessionChanged(resend: false)
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.refreshLink()
        }
    }

    /// The user switched watches: activate again for the new one.
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
        Task { @MainActor [weak self] in
            self?.sessionChanged(resend: true)
        }
    }

    /// Paired, installed (the first install gets data at once) or the watch changed.
    func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.sessionChanged(resend: true)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.refreshLink()
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        let request: WatchRequest? = WatchRequest(dictionary: message)
        let receivedAt: Double = ProcessInfo.processInfo.systemUptime
        // How long it took to get here (a launch of this app, a slow link), on arrival.
        let arrivalAge: Double? = request?.age()
        Task { @MainActor [weak self] in
            guard let self else {
                replyHandler(WatchReply(ok: false, state: WatchProtocol.stateFailed, via: WatchProtocol.viaIphone,
                                        error: "OPEN MAGICMAKER ON IPHONE").dictionary())
                return
            }
            await self.handle(request, receivedAt: receivedAt, arrivalAge: arrivalAge, reply: replyHandler)
        }
    }

    /// A message sent without a reply handler: handled the same, the reply dropped.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let request: WatchRequest? = WatchRequest(dictionary: message)
        let receivedAt: Double = ProcessInfo.processInfo.systemUptime
        let arrivalAge: Double? = request?.age()
        Task { @MainActor [weak self] in
            await self?.handle(request, receivedAt: receivedAt, arrivalAge: arrivalAge, reply: nil)
        }
    }

    @MainActor
    private func sessionChanged(resend: Bool) {
        if resend {
            lastDigest = nil
            lastCoreDigest = nil
        }
        refreshLink()
        ensureBaseSubscriptions()
        schedulePush(immediate: true)
    }

    // MARK: - Requests

    @MainActor
    private func handle(_ request: WatchRequest?, receivedAt: Double, arrivalAge: Double?,
                        reply: (([String: Any]) -> Void)?) async {
        refreshLink()
        nextOpSerial += 1
        let op = WatchOperation(serial: nextOpSerial, receivedAt: receivedAt, reply: reply)
        guard let request else {
            op.reply(failed(WatchBridge.updateText))
            op.finish()
            return
        }
        guard request.version == WatchProtocol.version else {
            op.reply(failed(WatchBridge.updateText, id: request.id))
            op.finish()
            return
        }
        // A wake with no screen has no 2 s relay poll: start the link and a status read now,
        // as ContentView.startRelayLink does on screen.
        let vm: AppViewModel = ensureViewModel()
        if !vm.relayCommandReady {
            vm.ensureRelayLink()
        }
        vm.refreshRelayStatus()
        switch request.op {
        case WatchProtocol.opSend:
            await handleSend(request.id, arrivalAge: arrivalAge, vm: vm, op: op)
        case WatchProtocol.opStopPrograms:
            await handleStopPrograms(vm: vm, op: op)
        case WatchProtocol.opRefresh:
            await handleRefresh(vm: vm, op: op)
        default:
            op.reply(failed(WatchBridge.updateText, id: request.id))
            op.finish()
        }
    }

    static let updateText: String = "UPDATE MAGICMAKER ON IPHONE AND WATCH"

    @MainActor
    private func failed(_ error: String, via: String = WatchProtocol.viaIphone, id: String? = nil,
                        label: String = "", context: WatchContext? = nil) -> WatchReply {
        var snapshot: WatchContext? = context
        if snapshot == nil, let vm = viewModel {
            snapshot = WatchContextBuilder.statusOnly(vm: vm)
        }
        return WatchReply(ok: false, state: WatchProtocol.stateFailed, via: via, error: error, label: label,
                          id: id, context: snapshot)
    }

    /// docs/WATCH_APP.md 4.2.
    @MainActor
    private func handleSend(_ id: String?, arrivalAge: Double?, vm: AppViewModel, op: WatchOperation) async {
        let store: WatchFavoritesStore = WatchFavoritesStore.shared
        guard let id, let favorite = store.favorite(id: id) else {
            // Removed on the iPhone meanwhile: the reply carries the new list.
            op.reply(failed("FAVORITE REMOVED ON IPHONE", id: id,
                            context: WatchContextBuilder.full(vm: vm, lastSend: lastSend)))
            op.finish()
            return
        }
        // Held up on the way (nothing is queued on purpose): the watch has given up on it, or is
        // about to, so a send now would be one nobody expects.
        if let age = arrivalAge, age > WatchProtocol.lateSendSeconds {
            op.reply(failed("ARRIVED LATE — NOT SENT, TAP AGAIN", id: id, label: favorite.label))
            op.finish()
            return
        }
        if vm.firmware.isBusy {
            op.reply(failed("ESP32 FIRMWARE UPDATE RUNNING", id: id, label: favorite.label))
            op.finish()
            return
        }
        // Bluetooth off or not allowed: say so at once. "Bluetooth unavailable" is also what the
        // radio reads until it first reports, as on a launch by this very message, so that one
        // waits for the link like any other.
        let usesBle: Bool = vm.relayBackend.usesBleRelayLink
        let bluetooth: String = vm.scan.bluetoothStatus
        if usesBle && bluetooth != WatchBridge.bluetoothReady && bluetooth != WatchBridge.bluetoothUnknown {
            op.reply(failed(bluetooth.uppercased(), id: id, label: favorite.label))
            op.finish()
            return
        }
        let deadline: Double = op.receivedAt + WatchBridge.replySeconds
        let linked: Bool = await waitForLink(vm, until: min(op.receivedAt + WatchBridge.linkWaitSeconds, deadline))
        // iOS ended the background time during the wait and the watch was told NO REPLY: send
        // nothing it is no longer waiting for.
        if op.replied {
            op.finish()
            return
        }
        if !linked {
            let nowBluetooth: String = vm.scan.bluetoothStatus
            let why: String = usesBle && nowBluetooth != WatchBridge.bluetoothReady
                ? nowBluetooth.uppercased()
                : WatchBridge.notLinkedText(vm)
            op.reply(failed(why, id: id, label: favorite.label))
            op.finish()
            return
        }
        let via: String = WatchContextBuilder.viaName(vm.relayBackend)
        let favoriteId: String = favorite.id
        op.label = favorite.label
        let routed = route(favorite, vm: vm, completion: { [weak self] (failure: String?) -> Void in
            self?.sendFinished(op, id: favoriteId, via: via, failure: failure)
        })
        if routed.loop {
            op.reply(WatchReply(ok: true, state: WatchProtocol.stateLoop, via: via, label: routed.label, id: favoriteId,
                                context: WatchContextBuilder.statusOnly(vm: vm)))
            op.finish()
            return
        }
        op.label = routed.label
        // The packet is on its way: reply with the final result if it comes before the deadline,
        // else ON AIR / QUEUED now and the final result in the next context (`lastSend`).
        let remaining: Double = deadline - ProcessInfo.processInfo.systemUptime
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        if op.replied { return }
        let canonical: String = HexUtils.canonicalHex(routed.hex)
        let onAir: Bool = vm.tx.isTransmitting && vm.tx.lastTransmitHex == canonical
        op.resultPending = true
        op.reply(WatchReply(ok: true, state: onAir ? WatchProtocol.stateOnAir : WatchProtocol.stateQueued, via: via,
                            label: routed.label, id: favoriteId, context: WatchContextBuilder.statusOnly(vm: vm)))
    }

    /// The send of a watch favourite ended (or was dropped before it ran).
    @MainActor
    private func sendFinished(_ op: WatchOperation, id: String, via: String, failure: String?) {
        let ok: Bool = failure == nil
        let error: String = failure.map { (text: String) -> String in WatchBridge.errorText(text) } ?? ""
        if !op.replied {
            var snapshot: WatchContext? = nil
            if let vm = viewModel {
                snapshot = WatchContextBuilder.statusOnly(vm: vm)
            }
            op.reply(WatchReply(ok: ok, state: ok ? WatchProtocol.stateSent : WatchProtocol.stateFailed, via: via,
                                error: error, label: op.label, id: id, context: snapshot))
            op.finish()
            return
        }
        if op.resultPending {
            lastSend = WatchSendResult(id: id, ok: ok, state: ok ? WatchProtocol.stateSent : WatchProtocol.stateFailed,
                                       via: via, error: error, label: op.label, at: Date().timeIntervalSince1970)
            pushNow()
        }
        op.finish()
    }

    /// Sends a favourite as its source row would: the WAND tab's loop rule for wand colours and
    /// codes, the TX tab's for library rows, a plain send for Lab presets and the quick button.
    /// `loop`: the wand loop took the colour instead of a send (no completion follows).
    @MainActor
    private func route(_ favorite: WatchFavorite, vm: AppViewModel,
                       completion: ((String?) -> Void)?) -> (loop: Bool, hex: String, label: String) {
        var hex: String = favorite.hex
        var label: String = favorite.label
        if favorite.source == WatchFavorite.Source.wandQuick {
            // The quick button may have been reprogrammed (or replaced by a library import).
            vm.reloadWandQuickIfChanged()
            WatchFavoritesStore.shared.followQuick(label: vm.wandQuickLabel, hex: vm.wandQuickHex)
            hex = vm.wandQuickHex
            label = vm.wandQuickLabel
        }
        let tx: TxEngine = vm.tx
        switch favorite.source {
        case WatchFavorite.Source.wandColor, WatchFavorite.Source.newWand:
            // WandScreen.transmitColor: while the wand loop runs the colour becomes the loop's
            // (and the loop sends it at once).
            if tx.starlightLoopEnabled, let packetId = WatchBridge.wandPacketId(hex, vm.store) {
                tx.setStarlightLoop(enabled: true, packetId: packetId, intervalMs: nil)
                return (loop: true, hex: hex, label: label)
            }
            tx.transmit(hex: hex, label: label, completion: completion)
        case WatchFavorite.Source.library:
            // TxScreen.selectPacket: send, and while the TX loop runs it becomes the loop's packet.
            tx.transmit(hex: hex, label: label, completion: completion)
            if tx.txLoopEnabled, let packetId = WatchBridge.libraryPacketId(hex, vm.store) {
                tx.setTxLoop(enabled: true, packetId: packetId, intervalMs: nil)
            }
        default:
            // Lab SEND, the quick button (and any source added later): a plain send.
            tx.transmit(hex: hex, label: label, completion: completion)
        }
        return (loop: false, hex: hex, label: label)
    }

    /// SETTINGS → APPLE WATCH row tap: the watch's send path from the iPhone, nothing reported.
    @MainActor
    func sendFromPhone(_ favorite: WatchFavorite) {
        guard let vm = BootstrapController.shared.viewModel ?? viewModel else { return }
        _ = route(favorite, vm: vm, completion: nil)
    }

    /// The learned Starlight colour or New Wand code with this hex (the wand loop's packet id).
    @MainActor
    private static func wandPacketId(_ hex: String, _ store: MagicStore) -> Int64? {
        let canonical: String = HexUtils.canonicalHex(hex)
        for packet in store.learnedStarlightPackets() where HexUtils.canonicalHex(packet.hex) == canonical {
            return packet.id
        }
        for packet in NewWandCatalog.packets where HexUtils.canonicalHex(packet.hex) == canonical {
            return packet.id
        }
        return nil
    }

    /// The TX library row with this hex (the TX loop's packet id); nil when it was deleted.
    @MainActor
    private static func libraryPacketId(_ hex: String, _ store: MagicStore) -> Int64? {
        let canonical: String = HexUtils.canonicalHex(hex)
        for packet in store.allTransmitPackets() where HexUtils.canonicalHex(packet.hex) == canonical {
            return packet.id
        }
        return nil
    }

    /// Waits up to `until` (uptime) for the relay link, nudging it every second as the 2 s
    /// relay poll would (on Wi-Fi the link state comes from the status read).
    @MainActor
    private func waitForLink(_ vm: AppViewModel, until: Double) async -> Bool {
        var lastNudge: Double = ProcessInfo.processInfo.systemUptime
        while !vm.remoteLinkReady {
            let now: Double = ProcessInfo.processInfo.systemUptime
            if now >= until { return false }
            if now - lastNudge >= 1 {
                lastNudge = now
                vm.ensureRelayLink()
                if vm.relayBackend.usesWifiRelay {
                    vm.refreshAndroidRemote()
                }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return true
    }

    /// ScanEngine.bluetoothStatus (BleCentral's texts): ready, and the value before the radio
    /// first reports (also an unsupported or resetting radio).
    static let bluetoothReady: String = "Bluetooth ready"
    static let bluetoothUnknown: String = "Bluetooth unavailable"

    @MainActor
    private static func notLinkedText(_ vm: AppViewModel) -> String {
        let hint: String = vm.remoteLinkHint.trimmingCharacters(in: .whitespacesAndNewlines)
        return hint.isEmpty ? "NO RELAY LINKED" : hint.uppercased()
    }

    /// TxEngine's failure statuses as the watch shows them.
    @MainActor
    static func errorText(_ failure: String) -> String {
        if failure == TxEngine.notLinkedStatus { return "NO RELAY LINKED" }
        if failure == TxEngine.sendFailedStatus { return "RELAY DID NOT SEND IT" }
        // A newer send (from the watch or the iPhone) or a STOP took it out of the queue.
        if failure == TxEngine.droppedStatus { return "REPLACED BY A NEWER SEND OR STOP" }
        let text: String = failure.uppercased()
        if text.count <= 48 { return text }
        return String(text.prefix(47)) + "…"
    }

    /// docs/WATCH_APP.md 4.3: keep-awake, the TX and wand loops, the random show and any replay
    /// (on this iPhone and on the relay). AUTO stays armed: it is not a program.
    @MainActor
    private func handleStopPrograms(vm: AppViewModel, op: WatchOperation) async {
        let linked: Bool = await waitForLink(vm, until: op.receivedAt + WatchBridge.linkWaitSeconds)
        let report: AndroidRemoteStatus? = vm.androidRemote
        let relayRunsLoops: Bool = vm.relayBackend == .esp32
        let txWas: Bool = vm.tx.txLoopEnabled
        let wandWas: Bool = vm.tx.starlightLoopEnabled
        // No STATUS read yet (this message launched the app, or the link just came up, or the
        // ESP32 is away): what the relay runs is unknown, and the ESP32 keeps keep-awake and its
        // loops through iPhone restarts, so each one is told to stop. The ESP32 gets them now or
        // on its next link; an Android relay that is not linked is not asked (it would only fail).
        let unknown: Bool = report == nil && (linked || relayRunsLoops)
        // The iPhone's timers, the show, the replay and the queue; the ESP32 is told about the
        // loops this iPhone knew of.
        vm.tx.stopAll()
        if vm.keepAwakeActive || report?.keepAwake == true || unknown {
            vm.setKeepAwake(false)
        }
        // Also a loop started on the Android phone itself, or an ESP32 loop not adopted yet.
        if (report?.txLoopEnabled == true || unknown) && !(relayRunsLoops && txWas) {
            vm.setAndroidTxLoop(enabled: false)
        }
        if (report?.starlightLoopEnabled == true || unknown) && !(relayRunsLoops && wandWas) {
            vm.setAndroidStarlightLoop(enabled: false)
        }
        var via: String = WatchContextBuilder.viaName(vm.relayBackend)
        var note: String = ""
        if !linked {
            via = WatchProtocol.viaIphone
            note = relayRunsLoops
                ? "ESP32 NOT LINKED — IT STOPS WHEN IT LINKS"
                : "RELAY NOT LINKED — STOPPED ON IPHONE ONLY"
        }
        op.reply(WatchReply(ok: true, state: WatchProtocol.stateStopped, via: via, error: note,
                            context: WatchContextBuilder.statusOnly(vm: vm)))
        op.finish()
        schedulePush(immediate: true)
    }

    /// docs/WATCH_APP.md 4.4: read the relay again, then reply with a full context.
    @MainActor
    private func handleRefresh(vm: AppViewModel, op: WatchOperation) async {
        vm.refreshRelayStatus()
        if !vm.isCatalogSyncInFlight {
            vm.refreshAndroidRemote()
        }
        // One GATT status round trip.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        op.reply(WatchReply(ok: true, state: WatchProtocol.stateRefreshed, via: WatchProtocol.viaIphone,
                            context: WatchContextBuilder.full(vm: vm, lastSend: lastSend)))
        op.finish()
    }
}

/// One watch message on the iPhone: its single reply and the background time it runs in. The
/// background task ends after the reply and any result still due (`resultPending`), and no
/// later than `WatchBridge.backgroundCeilingSeconds` after the message.
@MainActor
private final class WatchOperation {
    let serial: Int
    /// Uptime when the message arrived.
    let receivedAt: Double
    /// The label the packet went out with (the quick button's current one).
    var label: String = ""
    /// The reply went out before the send ended: its result goes out as `lastSend`.
    var resultPending: Bool = false
    private(set) var replied: Bool = false
    private var replyHandler: (([String: Any]) -> Void)?
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var ceiling: Task<Void, Never>?
    private var ended: Bool = false

    init(serial: Int, receivedAt: Double, reply: (([String: Any]) -> Void)?) {
        self.serial = serial
        self.receivedAt = receivedAt
        self.replyHandler = reply
        background = UIApplication.shared.beginBackgroundTask(withName: "watch-op") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timedOut()
            }
        }
        let waitNs: UInt64 = UInt64(WatchBridge.backgroundCeilingSeconds * 1_000_000_000)
        // Holds the operation (strongly) until finish() cancels it, so an operation nothing else
        // keeps any more still replies and ends its background task: the expiration handler's
        // weak reference alone would then find nil and leave the task open (iOS kills the app).
        ceiling = Task { @MainActor in
            try? await Task.sleep(nanoseconds: waitNs)
            if Task.isCancelled { return }
            self.timedOut()
        }
    }

    /// The one reply; later calls do nothing.
    func reply(_ r: WatchReply) {
        if replied { return }
        replied = true
        let handler: (([String: Any]) -> Void)? = replyHandler
        replyHandler = nil
        handler?(r.dictionary())
    }

    /// The ceiling or iOS ended the background time first: reply if nothing was said yet.
    private func timedOut() {
        if !replied {
            reply(WatchReply(ok: false, state: WatchProtocol.stateFailed, via: WatchProtocol.viaIphone,
                             error: "NO REPLY — OPEN MAGICMAKER ON IPHONE"))
        }
        finish()
    }

    /// Ends the background time. A background wake drew nothing, so it cannot have crashed in
    /// the VFD renderer: clear the VFD launch guard `armLaunchGuard` set in App.init, or a wake
    /// suspended before its 6 s timer would flip a VFD user to the standard theme next launch.
    func finish() {
        if ended { return }
        ended = true
        ceiling?.cancel()
        ceiling = nil
        if UIApplication.shared.applicationState == .background {
            UserDefaults.standard.set(false, forKey: VFDSettings.launchGuardKey)
        }
        if background != .invalid {
            let id: UIBackgroundTaskIdentifier = background
            background = .invalid
            UIApplication.shared.endBackgroundTask(id)
        }
    }
}
