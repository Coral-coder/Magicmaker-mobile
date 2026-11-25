import Combine
import Foundation
import WatchConnectivity
import WatchKit

// The watch's side of the WatchConnectivity contract (docs/WATCH_APP.md 3 and 5.2). The watch is
// a remote for the iPhone app: it never talks to a relay itself. The iPhone pushes one application
// context (favourites, status, theme, the last send result); the watch sends three requests
// (send, stop_programs, refresh) only while the iPhone is reachable, and queues nothing.

/// The state of one favourite row (or of the STOP button).
enum WatchRowState: Equatable {
    case idle
    case sending
    /// isFinal == false: on air or queued on the iPhone, and its lastSend is still due.
    case result(ok: Bool, text: String, isFinal: Bool)
}

/// Taptic feedback for sends and stops.
@MainActor
enum WatchHaptic {
    static func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }
}

/// Resumes a waiting refresh exactly once: from WatchConnectivity's handler or from a timeout.
@MainActor
private final class WatchOnce {
    private var done: Bool = false

    func claim() -> Bool {
        if done { return false }
        done = true
        return true
    }
}

@MainActor
final class WatchModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var favorites: [WatchFavorite] = []
    @Published private(set) var status: WatchStatus?
    @Published private(set) var theme: WatchThemeColors = WatchThemeColors.amber
    /// iPhone time of the newest snapshot (context or reply), Unix seconds; 0 = never.
    @Published private(set) var updatedAt: Double = 0
    @Published private(set) var reachable: Bool = false
    @Published private(set) var companionInstalled: Bool = true
    /// Favourite id → its row state. The STOP button is kept here too, under `stopKey`.
    @Published private(set) var rows: [String: WatchRowState] = [:]
    @Published private(set) var refreshing: Bool = false
    /// The app is frontmost (scenePhase .active); the STATUS poll runs only then.
    private(set) var active: Bool = true

    var stopState: WatchRowState {
        rows[WatchModel.stopKey] ?? .idle
    }

    /// Not a UUID, so it never collides with a favourite id.
    private static let stopKey: String = "stop_programs"
    private static let cacheKey: String = "MMWatchSnapshot"
    /// A final result stays on its row this long.
    private static let resultSeconds: UInt64 = 5
    /// An on-air / queued row waits this long for its lastSend.
    private static let pendingSeconds: UInt64 = 60
    /// A request whose handlers were never called is given up after this long.
    private static let noReplySeconds: UInt64 = 30

    /// The iPhone time each snapshot part was last taken from, so a late older one is ignored.
    private var partAt: [String: Double] = [:]
    /// A per-row token: a timer clears a row only if nothing newer was set on it meanwhile.
    private var rowTokens: [String: Int] = [:]
    private var tokenSeq: Int = 0
    /// iPhone time of the reply that left a row on air or queued: only a lastSend taken after it
    /// is that send's result. An older one is an earlier tap's, still in the iPhone's contexts.
    private var pendingSince: [String: Double] = [:]
    /// The newest lastSend per favourite: the context carrying it can overtake the reply that
    /// said on air (they travel separately).
    private var latestSends: [String: WatchSendResult] = [:]

    override init() {
        super.init()
        loadCache()
        if WCSession.isSupported() {
            let session: WCSession = WCSession.default
            session.delegate = self
            session.activate()
        }
    }

    // MARK: - Actions

    /// Sends a favourite through the iPhone and its relay.
    func send(_ favorite: WatchFavorite) {
        let id: String = favorite.id
        if rows[id] == .sending { return }
        guard WatchModel.canSend() else {
            setRow(id, .result(ok: false, text: "✕ IPHONE NOT REACHABLE", isFinal: true))
            WatchHaptic.play(.failure)
            return
        }
        WatchHaptic.play(.click)
        setRow(id, .sending)
        let message: [String: Any] = WatchRequest(op: WatchProtocol.opSend, id: id).dictionary()
        WatchModel.request(message) { (reply: WatchReply?, errorText: String?) -> Void in
            Task { @MainActor in
                self.finish(key: id, reply: reply, errorText: errorText)
            }
        }
    }

    /// Stops keep-awake, the TX and wand loops, the random show and any replay.
    func stopPrograms() {
        let key: String = WatchModel.stopKey
        if rows[key] == .sending { return }
        guard WatchModel.canSend() else {
            setRow(key, .result(ok: false, text: "✕ IPHONE NOT REACHABLE", isFinal: true))
            WatchHaptic.play(.failure)
            return
        }
        WatchHaptic.play(.click)
        setRow(key, .sending)
        let message: [String: Any] = WatchRequest(op: WatchProtocol.opStopPrograms).dictionary()
        WatchModel.request(message) { (reply: WatchReply?, errorText: String?) -> Void in
            Task { @MainActor in
                self.finish(key: key, reply: reply, errorText: errorText)
            }
        }
    }

    /// Asks the iPhone to re-read its relay and send a full snapshot. Returns when it has (or when
    /// the iPhone is not reachable).
    func refresh() async {
        guard WatchModel.canSend(), !refreshing else { return }
        refreshing = true
        let message: [String: Any] = WatchRequest(op: WatchProtocol.opRefresh).dictionary()
        let once: WatchOnce = WatchOnce()
        let reply: WatchReply? = await withCheckedContinuation { (cont: CheckedContinuation<WatchReply?, Never>) -> Void in
            WatchModel.request(message) { (reply: WatchReply?, _: String?) -> Void in
                Task { @MainActor in
                    if once.claim() { cont.resume(returning: reply) }
                }
            }
            // WatchConnectivity calls one of its handlers; this only guards against it never
            // doing so, which would leave `refreshing` set for good.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: WatchModel.noReplySeconds * 1_000_000_000)
                if once.claim() { cont.resume(returning: nil) }
            }
        }
        refreshing = false
        if let context: WatchContext = reply?.context { apply(context) }
    }

    /// WatchRootView calls this on every scene phase change. Becoming active refreshes.
    func setActive(_ on: Bool) {
        let was: Bool = active
        active = on
        if on && !was {
            Task { @MainActor in
                await self.refresh()
            }
        }
    }

    // MARK: - Requests

    nonisolated private static func canSend() -> Bool {
        guard WCSession.isSupported() else { return false }
        let session: WCSession = WCSession.default
        return session.activationState == .activated && session.isReachable
    }

    /// Sends one request. `done` gets the parsed reply, or nil and the error text, on
    /// WatchConnectivity's queue. WatchConnectivity calls exactly one of the two handlers.
    nonisolated private static func request(_ message: [String: Any],
                                            _ done: @escaping @Sendable (WatchReply?, String?) -> Void) {
        WCSession.default.sendMessage(message, replyHandler: { (reply: [String: Any]) -> Void in
            if let parsed: WatchReply = WatchReply(dictionary: reply) {
                done(parsed, nil)
            } else {
                done(nil, "UPDATE MAGICMAKER ON IPHONE AND WATCH")
            }
        }, errorHandler: { (error: Error) -> Void in
            done(nil, WatchModel.errorText(error))
        })
    }

    /// The watch-side error texts of docs/WATCH_APP.md 3.3.
    nonisolated static func errorText(_ error: Error) -> String {
        guard let wc: WCError = error as? WCError else {
            return "IPHONE ERROR \((error as NSError).code)"
        }
        switch wc.code {
        case .messageReplyTimedOut:
            return "NO REPLY — OPEN MAGICMAKER ON IPHONE"
        case .notReachable:
            return "IPHONE NOT REACHABLE"
        case .companionAppNotInstalled:
            return "INSTALL MAGICMAKER ON IPHONE"
        default:
            return "IPHONE ERROR \(wc.code.rawValue)"
        }
    }

    /// A reply (or its absence) for a favourite row or the STOP button.
    private func finish(key: String, reply: WatchReply?, errorText: String?) {
        if let context: WatchContext = reply?.context { apply(context) }
        guard let reply else {
            setRow(key, .result(ok: false, text: "✕ " + (errorText ?? "NO REPLY"), isFinal: true))
            WatchHaptic.play(.failure)
            return
        }
        let via: String = reply.via.isEmpty ? "" : " · VIA " + reply.via
        if !reply.ok || reply.state == WatchProtocol.stateFailed {
            let why: String = reply.error.isEmpty ? "FAILED" : reply.error
            setRow(key, .result(ok: false, text: "✕ " + why, isFinal: true))
            WatchHaptic.play(.failure)
            return
        }
        switch reply.state {
        case WatchProtocol.stateSent:
            setRow(key, .result(ok: true, text: reply.via.isEmpty ? "✓ SENT" : "✓ VIA " + reply.via, isFinal: true))
            WatchHaptic.play(.success)
        case WatchProtocol.stateOnAir:
            setPending(key, "ON AIR" + via, since: reply.context?.at)
        case WatchProtocol.stateQueued:
            setPending(key, "QUEUED" + via, since: reply.context?.at)
        case WatchProtocol.stateLoop:
            setRow(key, .result(ok: true, text: "LOOP" + via, isFinal: true))
            WatchHaptic.play(.success)
        case WatchProtocol.stateStopped:
            // `error` carries a note here, e.g. "ESP32 NOT LINKED — IT STOPS WHEN IT LINKS".
            let note: String = reply.error.isEmpty ? "" : "\n" + reply.error
            setRow(key, .result(ok: true, text: "STOPPED" + via + note, isFinal: true))
            WatchHaptic.play(.success)
        case WatchProtocol.stateRefreshed:
            setRow(key, .idle)
        default:
            // A state added later: show it rather than drop it.
            setRow(key, .result(ok: true, text: "✓ " + reply.state.uppercased() + via, isFinal: true))
            WatchHaptic.play(.success)
        }
    }

    // MARK: - Rows

    /// On air or queued on the iPhone: the final result follows as a lastSend, which may already
    /// have arrived. `since` is the reply's iPhone time.
    private func setPending(_ key: String, _ text: String, since: Double?) {
        setRow(key, .result(ok: true, text: text, isFinal: false))
        pendingSince[key] = since ?? 0
        WatchHaptic.play(.start)
        if let early: WatchSendResult = latestSends[key] {
            applyLastSend(early)
        }
    }

    private func setRow(_ key: String, _ state: WatchRowState) {
        tokenSeq += 1
        let token: Int = tokenSeq
        rowTokens[key] = token
        let delay: UInt64
        switch state {
        case .idle:
            rows[key] = nil
            rowTokens[key] = nil
            return
        case .sending:
            delay = WatchModel.noReplySeconds
        case .result(_, _, let isFinal):
            delay = isFinal ? WatchModel.resultSeconds : WatchModel.pendingSeconds
        }
        rows[key] = state
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            self?.expireRow(key, token: token)
        }
    }

    /// A row's timer ran out: a final or overdue result is cleared; a send that never got a reply
    /// is reported as such.
    private func expireRow(_ key: String, token: Int) {
        guard rowTokens[key] == token, let state: WatchRowState = rows[key] else { return }
        if state == .sending {
            setRow(key, .result(ok: false, text: "✕ NO REPLY — OPEN MAGICMAKER ON IPHONE", isFinal: true))
            WatchHaptic.play(.failure)
        } else {
            setRow(key, .idle)
        }
    }

    // MARK: - Snapshots

    /// Takes each part that is present and not older than the one already shown.
    private func apply(_ c: WatchContext) {
        var changed: Bool = false
        if let favorites: [WatchFavorite] = c.favorites, takePart(WatchProtocol.keyFavorites, at: c.at) {
            self.favorites = favorites
            changed = true
        }
        if let status: WatchStatus = c.status, takePart(WatchProtocol.keyStatus, at: c.at) {
            self.status = status
            changed = true
        }
        if let theme: WatchThemeColors = c.theme, takePart(WatchProtocol.keyTheme, at: c.at) {
            self.theme = theme
            changed = true
        }
        if c.at > updatedAt {
            updatedAt = c.at
        }
        if let result: WatchSendResult = c.lastSend {
            if (latestSends[result.id]?.at ?? -1) < result.at {
                latestSends[result.id] = result
            }
            applyLastSend(result)
        }
        if changed { saveCache() }
    }

    /// A late snapshot (more than 1 s older than the shown one) is ignored.
    private func takePart(_ key: String, at: Double) -> Bool {
        if let shown: Double = partAt[key], at < shown - 1 { return false }
        partAt[key] = at
        return true
    }

    /// The final result of a send whose reply said on air or queued.
    private func applyLastSend(_ r: WatchSendResult) {
        guard case .result(_, _, let isFinal)? = rows[r.id], !isFinal else { return }
        // Taken before this row went on air: the result of an earlier tap of the same favourite.
        guard r.at >= (pendingSince[r.id] ?? 0) else { return }
        guard watchSecondsSince(r.at) < 60 else { return }
        if r.ok {
            setRow(r.id, .result(ok: true, text: r.via.isEmpty ? "✓ SENT" : "✓ VIA " + r.via, isFinal: true))
            WatchHaptic.play(.success)
        } else {
            let why: String = r.error.isEmpty ? "FAILED" : r.error
            setRow(r.id, .result(ok: false, text: "✕ " + why, isFinal: true))
            WatchHaptic.play(.failure)
        }
    }

    /// The last snapshot, so the app opens with favourites while the iPhone is away.
    private func loadCache() {
        guard let saved: [String: Any] = UserDefaults.standard.dictionary(forKey: WatchModel.cacheKey),
              let context: WatchContext = WatchContext(dictionary: saved) else { return }
        apply(WatchContext(at: context.at, favorites: context.favorites, status: context.status, theme: context.theme))
    }

    private func saveCache() {
        let snapshot: WatchContext = WatchContext(at: updatedAt, favorites: favorites, status: status, theme: theme)
        UserDefaults.standard.set(snapshot.dictionary(), forKey: WatchModel.cacheKey)
    }

    // MARK: - WCSessionDelegate (called on WatchConnectivity's queue)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context: WatchContext? = WatchContext(dictionary: session.receivedApplicationContext)
        let activated: Bool = activationState == .activated
        let reachable: Bool = activated && session.isReachable
        let installed: Bool = session.isCompanionAppInstalled
        Task { @MainActor in
            if let context { self.apply(context) }
            self.reachable = reachable
            self.companionInstalled = installed
            if reachable { await self.refresh() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let context: WatchContext = WatchContext(dictionary: applicationContext) else { return }
        Task { @MainActor in
            self.apply(context)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable: Bool = session.activationState == .activated && session.isReachable
        Task { @MainActor in
            let was: Bool = self.reachable
            self.reachable = reachable
            if reachable && !was && self.active { await self.refresh() }
        }
    }

    nonisolated func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        let installed: Bool = session.isCompanionAppInstalled
        Task { @MainActor in
            self.companionInstalled = installed
        }
    }
}
