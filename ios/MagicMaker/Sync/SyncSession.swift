import Foundation

// The per-link session state machine (docs/SYNC_PROTOCOL.md §14) as a pure function of
// (state, ctx, input) -> (state', actions): no I/O, no clock reads (time is the input's `t`, ms),
// no randomness (nonces come from the context). It builds HELLO, AUTH, JOIN, PULL and ERR itself;
// everything else is handed to the node (`deliver`, `node`). Vectors: sessions. The emitted
// action order and the timer snapshots are normative: this follows tools/sync/sync_ref.py
// SessionCore line for line.

enum SyncSessionState: String {
    case idle = "IDLE"
    case linked = "LINKED"
    case helloX = "HELLO_X"
    case authed = "AUTHED"
    case syncing = "SYNCING"
    case synced = "SYNCED"
    case foreign = "FOREIGN"
    case noGroup = "NOGROUP"
    case incompatible = "INCOMPATIBLE"
    case closed = "CLOSED"

    /// AUTHED, SYNCING or SYNCED.
    var isAuthedPlus: Bool {
        return self == .authed || self == .syncing || self == .synced
    }
}

/// Session timers (one of each per session).
enum SyncTimer: String, CaseIterable {
    case hello = "HELLO"
    case auth = "AUTH"
    case deadline = "DEADLINE"
    case page = "PAGE"
    case livePull = "LIVE_PULL"
    case hb = "HB"
    case retry = "RETRY"
    case backoff = "BACKOFF"
}

enum SyncRole: String {
    case central
    case peripheral
}

/// What the session asks the node to do.
enum SyncNodeRequest: String {
    /// Build and send this node's HB on this session.
    case sendHb = "send_hb"
    /// iPhone: send EVT_SINCE for the newest window of each tracked origin (§8.3).
    case evtSince = "evt_since"
    /// Mark the peer foreign (phones stop auto-reconnecting to it).
    case foreign = "foreign"
}

enum SyncDisconnectReason: String {
    case foreign = "foreign"
    case authTimeout = "auth_timeout"
    case authDeadline = "auth_deadline"
    case pageTimeout = "page_timeout"
    case leftGroup = "left_group"
}

enum SyncSessionInput {
    case linkUp(mtu: Int)
    case linkDown
    case rx([UInt8])
    /// A timer at its due time (ignored unless it is still armed for exactly that time).
    case timer(SyncTimer)
    /// The node joined or left a group on another link or by the user.
    case groupChanged
    /// The node has a new key to spread.
    case rekey
    /// Node-level pull trigger (e.g. the hub's hubFull clearing).
    case pullNow
}

/// Actions, in emission order (§14.4).
enum SyncSessionAction {
    case send(type: UInt8, bytes: [UInt8])
    case state(SyncSessionState)
    /// Hand a decoded message to the node.
    case deliver(SyncMessage)
    /// A page completed: persist the page's data, then `wm`.
    case commit(wm: Int64)
    /// Persist this group key.
    case group(SyncGroup, rekey: Bool)
    case node(SyncNodeRequest)
    case disconnect(SyncDisconnectReason, retryMs: Int64?)
}

struct SyncSessionConfig {
    let role: SyncRole
    let deviceId: [UInt8]
    let kind: UInt8
    let bootId: Int64
    let maxMsg: Int64
    let caps: Int64
    let version: String?
    let name: String?
    /// Central only: the peer's kind, known from discovery.
    let peerKind: UInt8?
    /// iPhone: this node tracks heard-packet events.
    let tracksEvents: Bool
    let isHub: Bool

    init(role: SyncRole, deviceId: [UInt8], kind: UInt8, bootId: Int64, maxMsg: Int64, caps: Int64? = nil,
         version: String? = nil, name: String? = nil, peerKind: UInt8? = nil, tracksEvents: Bool = false,
         isHub: Bool? = nil) {
        self.role = role
        self.deviceId = deviceId
        self.kind = kind
        self.bootId = bootId
        self.maxMsg = maxMsg
        self.caps = caps ?? SyncCaps.forKind(kind)
        self.version = version
        self.name = name
        self.peerKind = peerKind
        self.tracksEvents = tracksEvents
        self.isHub = isHub ?? (kind == SyncKind.hub)
    }
}

/// Per peer deviceId (§15.1): the peer's dbId that `wm` refers to, the watermark on the peer's
/// feed (puller side) and whether the peer may be served with exclusion (server side).
final class SyncPeerState {
    var dbId: [UInt8]
    var wm: Int64
    var excludeOk: Bool

    init(dbId: [UInt8] = SyncConst.zero8, wm: Int64 = 0, excludeOk: Bool = false) {
        self.dbId = dbId
        self.wm = wm
        self.excludeOk = excludeOk
    }
}

/// The node's peer table, shared by all its sessions; keyed by the uppercase hex deviceId.
final class SyncPeerTable {
    var byId: [String: SyncPeerState] = [:]

    init() {}

    func get(_ deviceId: [UInt8]) -> SyncPeerState? {
        return byId[SyncHex.encode(deviceId)]
    }

    func getOrCreate(_ deviceId: [UInt8]) -> SyncPeerState {
        let k: String = SyncHex.encode(deviceId)
        if let p = byId[k] {
            return p
        }
        let p: SyncPeerState = SyncPeerState()
        byId[k] = p
        return p
    }
}

/// Node-owned values the session reads; the node mutates them between inputs (§14.2).
final class SyncSessionContext {
    var group: SyncGroup?
    var dbId: [UInt8]
    /// durableHigh.
    var feedHigh: Int64
    /// t -> clockMs (0 = unknown).
    var clock: (Int64) -> Int64
    /// Hub: index built.
    var ready: Bool
    /// One fresh 8-byte nonce per call.
    var nextNonce: () -> [UInt8]
    let peers: SyncPeerTable

    init(group: SyncGroup? = nil, dbId: [UInt8], feedHigh: Int64 = 0, clock: @escaping (Int64) -> Int64 = { _ in 0 },
         ready: Bool = true, nextNonce: @escaping () -> [UInt8] = { SyncRandom.nonZeroBytes(8) },
         peers: SyncPeerTable = SyncPeerTable()) {
        self.group = group
        self.dbId = dbId
        self.feedHigh = feedHigh
        self.clock = clock
        self.ready = ready
        self.nextNonce = nextNonce
        self.peers = peers
    }
}

/// One end of one link.
final class SyncSession {
    let config: SyncSessionConfig
    let ctx: SyncSessionContext

    private(set) var state: SyncSessionState = .idle
    /// Armed timers -> absolute due time (ms).
    private(set) var timers: [SyncTimer: Int64] = [:]
    /// The peer's decoded HELLO (once one was accepted).
    private(set) var peer: SyncMessage?
    /// What the peer wants to receive on this session (HELLO / SUB subs).
    private(set) var peerSubs: Int64 = 0
    /// Messages the session could not encode (always 0 unless a context value is out of range,
    /// e.g. a feedHigh above u32).
    private(set) var encodeFailures: Int = 0

    private var alike: Bool = false
    private var nonceC: [UInt8]?
    private var nonceP: [UInt8]?
    private var helloTries: Int = 0
    private var lastReply: [(type: UInt8, bytes: [UInt8])]?
    private var reqId: Int64 = 0
    private var pull: PullState?
    private var pendingHigh: Int64 = -1
    private(set) var limit: Int64 = SyncConst.pullLimitDefault
    private(set) var maxBytes: Int64 = SyncConst.pullMaxBytesDefault
    private var backoff: Backoff?
    private var out: [SyncSessionAction] = []

    private struct PullState {
        let reqId: Int64
        let since: Int64
        var recs: Int64
        let tries: Int
    }

    private enum Backoff {
        case hello
        case pull
    }

    init(config: SyncSessionConfig, ctx: SyncSessionContext) {
        self.config = config
        self.ctx = ctx
    }

    // MARK: Observable state

    var isCentral: Bool {
        return config.role == .central
    }

    var peerId: [UInt8]? {
        return peer?.bytes("deviceId")
    }

    /// The peer-table entry of this session's peer, once one exists.
    var peerState: SyncPeerState? {
        guard let pid = peerId else {
            return nil
        }
        return ctx.peers.get(pid)
    }

    /// The reqId of the outstanding pull, if any.
    var outstandingReqId: Int64? {
        return pull?.reqId
    }

    // MARK: Entry point

    func handle(t: Int64, _ input: SyncSessionInput) -> [SyncSessionAction] {
        out = []
        switch input {
        case .linkUp(let mtu):
            linkUp(t, mtu)
        case .linkDown:
            cancelAll()
            setState(.closed)
        case .rx(let data):
            rx(t, data)
        case .timer(let name):
            if let due = timers[name], due == t {
                timers.removeValue(forKey: name)
                onTimer(t, name)
            }
        case .groupChanged:
            groupChanged(t)
        case .rekey:
            rekey(t)
        case .pullNow:
            if state.isAuthedPlus {
                triggerPull(t, nil)
            }
        }
        let result: [SyncSessionAction] = out
        out = []
        return result
    }

    // MARK: Helpers

    private func emit(_ a: SyncSessionAction) {
        out.append(a)
    }

    @discardableResult
    private func send(_ type: UInt8, _ fields: [String: SyncValue]) -> [UInt8] {
        guard let b = try? SyncMessageCodec.encode(type: type, fields: fields) else {
            encodeFailures += 1  // a bug (a field out of range): nothing is sent
            return []
        }
        emit(.send(type: type, bytes: b))
        return b
    }

    private func setState(_ s: SyncSessionState) {
        if s != state {
            state = s
            emit(.state(s))
        }
    }

    private func arm(_ name: SyncTimer, _ t: Int64, _ ms: Int64) {
        timers[name] = t + ms
    }

    private func cancel(_ names: SyncTimer...) {
        for n in names {
            timers.removeValue(forKey: n)
        }
    }

    private func cancelAll() {
        timers = [:]
    }

    private func sendErr(_ code: UInt8, _ ref: UInt8?, extra: [String: SyncValue] = [:]) {
        var f: [String: SyncValue] = ["code": .int(Int64(code))]
        if let r = ref {
            f["refType"] = .int(Int64(r))
        }
        for (k, v) in extra {
            f[k] = v
        }
        send(SyncMsgType.err, f)
    }

    private func currentPeerState() -> SyncPeerState {
        return ctx.peers.getOrCreate(peerId ?? SyncConst.zero8)
    }

    private func disconnect(_ reason: SyncDisconnectReason, _ retryMs: Int64? = nil) {
        cancelAll()
        emit(.disconnect(reason, retryMs: retryMs))
    }

    private var peerCaps: Int64 {
        return peer?.int("caps") ?? 0
    }

    private var peerKindValue: UInt8 {
        return UInt8(truncatingIfNeeded: peer?.int("kind") ?? 0)
    }

    // MARK: Link / handshake

    private func linkUp(_ t: Int64, _ mtu: Int) {
        if mtu < SyncConst.smallMtuBelow {
            limit = SyncConst.pullLimitSmall
            maxBytes = SyncConst.pullMaxBytesSmall
        } else {
            limit = SyncConst.pullLimitDefault
            maxBytes = SyncConst.pullMaxBytesDefault
        }
        setState(.linked)
        if isCentral {
            startHello(t)
        } else if config.isHub && ctx.group != nil {
            arm(.deadline, t, SyncConst.memberDeadlineMs)
        }
    }

    private func helloFields(_ t: Int64, nonce: [UInt8], proof: [UInt8]? = nil) -> [String: SyncValue] {
        let pk: UInt8 = isCentral ? (config.peerKind ?? 0) : peerKindValue
        var f: [String: SyncValue] = [
            "proto": .int(Int64(SyncConst.proto)),
            "deviceId": .bytes(config.deviceId),
            "kind": .int(Int64(config.kind)),
            "dbId": .bytes(ctx.dbId),
            "clockMs": .int(ctx.clock(t)),
            "feedHigh": .int(ctx.feedHigh),
            "subs": .int(SyncRouting.subsFor(selfKind: config.kind, peerKind: pk)),
            "caps": .int(config.caps),
            "maxMsg": .int(config.maxMsg),
            "bootId": .int(config.bootId),
            "groupId": .bytes(ctx.group?.groupId ?? SyncConst.zero8),
            "nonce": .bytes(nonce),
        ]
        if let v = config.version, !v.isEmpty {
            f["version"] = .text(v)
        }
        if let n = config.name, !n.isEmpty {
            f["name"] = .text(n)
        }
        if let p = proof {
            f["proof"] = .bytes(p)
        }
        return f
    }

    private func startHello(_ t: Int64) {
        setState(.linked)
        let n: [UInt8] = ctx.nextNonce()
        nonceC = n
        helloTries = 1
        send(SyncMsgType.hello, helloFields(t, nonce: n))
        arm(.hello, t, SyncConst.helloTimeoutMs)
    }

    private func resendHello(_ t: Int64) {
        send(SyncMsgType.hello, helloFields(t, nonce: nonceC ?? SyncConst.zero8))
        arm(.hello, t, SyncConst.helloTimeoutMs)
    }

    /// (proofP, proofC) for the current handshake with the current group key.
    private func proofs() -> (p: [UInt8], c: [UInt8])? {
        guard let key = ctx.group?.groupKey, let nc = nonceC, let np = nonceP, let pid = peerId else {
            return nil
        }
        let idC: [UInt8] = isCentral ? config.deviceId : pid
        let idP: [UInt8] = isCentral ? pid : config.deviceId
        let p: [UInt8] = SyncGroupAuth.proofP(key: key, nonceC: nc, nonceP: np, idC: idC, idP: idP)
        let c: [UInt8] = SyncGroupAuth.proofC(key: key, nonceC: nc, nonceP: np, idC: idC, idP: idP)
        return (p, c)
    }

    /// (mine, theirs): the two groupIds, nil = ungrouped.
    private func groups(_ m: SyncMessage) -> (mine: [UInt8]?, theirs: [UInt8]?) {
        let mine: [UInt8]? = ctx.group?.groupId
        var theirs: [UInt8]? = m.bytes("groupId")
        if theirs == SyncConst.zero8 {
            theirs = nil
        }
        return (mine, theirs)
    }

    private func joinFields(rekey: Bool) -> [String: SyncValue] {
        var f: [String: SyncValue] = [
            "groupId": .bytes(ctx.group?.groupId ?? SyncConst.zero8),
            "groupKey": .bytes(ctx.group?.groupKey ?? [UInt8](repeating: 0, count: 16)),
        ]
        if rekey {
            f["flags"] = .int(SyncMsgFlag.joinRekey)
        }
        return f
    }

    private func centralHello(_ t: Int64, _ m: SyncMessage) {
        if state != .linked || nonceC == nil || timers[.hello] == nil {
            return  // late duplicate, or not waiting
        }
        cancel(.hello, .backoff)
        peer = m
        peerSubs = m.int("subs") ?? 0
        nonceP = m.bytes("nonce")
        let g = groups(m)
        if let mine = g.mine, let theirs = g.theirs {
            if mine != theirs {
                foreign(t, SyncMsgType.hello)
                return
            }
            guard let pr = proofs(), let got = m.bytes("proof"), SyncGroupAuth.constantTimeEqual(got, pr.p) else {
                foreign(t, SyncMsgType.hello)
                return
            }
            alike = true
            setState(.helloX)
            send(SyncMsgType.auth, ["proof": .bytes(pr.c)])
            authed(t)
        } else if g.mine != nil {
            send(SyncMsgType.join, joinFields(rekey: false))
            startHello(t)
        } else if g.theirs != nil {
            setState(.helloX)
            arm(.auth, t, SyncConst.authTimeoutMs)
        } else {
            setState(.noGroup)
        }
    }

    private func peripheralHello(_ t: Int64, _ m: SyncMessage) {
        if let nc = nonceC, let reply = lastReply, m.bytes("nonce") == nc {
            if state == .linked || state == .helloX || state == .noGroup {
                for r in reply {
                    emit(.send(type: r.type, bytes: r.bytes))
                }
            }
            return
        }
        if !ctx.ready {
            sendErr(SyncErrorCode.notReady, SyncMsgType.hello,
                    extra: ["retryMs": .int(SyncConst.notReadyRetryMs)])
            return
        }
        if state.isAuthedPlus {
            resetSync()
        }
        cancel(.auth)
        peer = m
        peerSubs = m.int("subs") ?? 0
        nonceC = m.bytes("nonce")
        let np: [UInt8] = ctx.nextNonce()
        nonceP = np
        alike = false
        let g = groups(m)
        var reply: [(type: UInt8, bytes: [UInt8])] = []
        if let mine = g.mine, let theirs = g.theirs, mine == theirs {
            alike = true
            let pp: [UInt8]? = proofs()?.p
            let b: [UInt8] = send(SyncMsgType.hello, helloFields(t, nonce: np, proof: pp))
            reply.append((SyncMsgType.hello, b))
            setState(.helloX)
            arm(.auth, t, SyncConst.authTimeoutMs)
        } else if g.mine != nil && g.theirs != nil {
            send(SyncMsgType.hello, helloFields(t, nonce: np))
            lastReply = nil
            foreign(t, SyncMsgType.hello)
            return
        } else if g.mine != nil {
            let b: [UInt8] = send(SyncMsgType.hello, helloFields(t, nonce: np))
            reply.append((SyncMsgType.hello, b))
            let j: [UInt8] = send(SyncMsgType.join, joinFields(rekey: false))
            reply.append((SyncMsgType.join, j))
            setState(.linked)
        } else if g.theirs != nil {
            let b: [UInt8] = send(SyncMsgType.hello, helloFields(t, nonce: np))
            reply.append((SyncMsgType.hello, b))
            setState(.helloX)
            arm(.auth, t, SyncConst.authTimeoutMs)
        } else {
            let b: [UInt8] = send(SyncMsgType.hello, helloFields(t, nonce: np))
            reply.append((SyncMsgType.hello, b))
            setState(.noGroup)
        }
        lastReply = reply
    }

    private func peripheralAuth(_ t: Int64, _ m: SyncMessage) {
        if isCentral || state != .helloX || !alike {
            return
        }
        if ctx.group == nil {
            // The node left its group without telling this session (group_changed): do what
            // group_changed would have done instead of judging the proof (sync_ref.py has no key
            // here; no vector covers it).
            disconnect(.leftGroup)
            return
        }
        if let pr = proofs(), let got = m.bytes("proof"), SyncGroupAuth.constantTimeEqual(got, pr.c) {
            cancel(.auth)
            authed(t)
        } else {
            foreign(t, SyncMsgType.auth)
        }
    }

    private func join(_ t: Int64, _ m: SyncMessage) {
        guard let gid = m.bytes("groupId"), let key = m.bytes("groupKey") else {
            return
        }
        let rekeyFlag: Bool = ((m.int("flags") ?? 0) & SyncMsgFlag.joinRekey) != 0
        if SyncGroupAuth.groupId(key: key) != gid {
            foreign(t, SyncMsgType.join)
            return
        }
        let mine: [UInt8]? = ctx.group?.groupId
        if mine == gid {
            return  // already in that group (e.g. a rekey that reached us on two links)
        }
        if rekeyFlag {
            if !state.isAuthedPlus {
                foreign(t, SyncMsgType.join)
                return
            }
            let g: SyncGroup = SyncGroup(groupId: gid, groupKey: key)
            ctx.group = g
            emit(.group(g, rekey: true))
            restart(t)
            return
        }
        if mine == nil && (state == .helloX || state == .noGroup) && peer != nil {
            let g: SyncGroup = SyncGroup(groupId: gid, groupKey: key)
            ctx.group = g
            emit(.group(g, rekey: false))
            restart(t)
            return
        }
        foreign(t, SyncMsgType.join)
    }

    private func restart(_ t: Int64) {
        resetSync()
        cancel(.auth, .hello, .backoff, .retry)
        alike = false
        lastReply = nil
        if isCentral {
            startHello(t)
        } else {
            nonceC = nil
            setState(.linked)
            if config.isHub && ctx.group != nil && timers[.deadline] == nil {
                arm(.deadline, t, SyncConst.memberDeadlineMs)
            }
        }
    }

    private func resetSync() {
        cancel(.page, .livePull, .hb, .backoff)
        pull = nil
        pendingHigh = -1
    }

    private func foreign(_ t: Int64, _ ref: UInt8?, sendErr sendError: Bool = true) {
        if sendError {
            sendErr(SyncErrorCode.auth, ref)
        }
        cancelAll()
        setState(.foreign)
        emit(.node(.foreign))
        emit(.disconnect(.foreign, retryMs: nil))
    }

    private func incompatible(_ t: Int64, timeout: Bool) {
        let deadline: Int64? = timers[.deadline]
        cancelAll()
        if let d = deadline {
            timers[.deadline] = d  // a grouped hub still drops non-members at 10 s
        }
        setState(.incompatible)
        if timeout && isCentral {
            arm(.retry, t, SyncConst.incompatibleRetryMs)
        }
    }

    private func authed(_ t: Int64) {
        setState(.authed)
        cancel(.auth, .deadline, .hello, .backoff, .retry)
        let ps: SyncPeerState = currentPeerState()
        let peerDb: [UInt8] = peer?.bytes("dbId") ?? SyncConst.zero8
        if ps.dbId != peerDb {
            ps.dbId = peerDb
            ps.wm = 0
            ps.excludeOk = false
        }
        pull = nil
        pendingHigh = -1
        if (peerCaps & SyncCaps.feed) != 0 {
            sendPull(t, retry: false)
            setState(.syncing)
        } else {
            setState(.synced)
        }
        if (peerSubs & SyncSubs.heartbeats) != 0 {
            emit(.node(.sendHb))
            arm(.hb, t, SyncConst.hbIntervalMs)
        }
        let ownSubs: Int64 = SyncRouting.subsFor(selfKind: config.kind, peerKind: peerKindValue)
        if config.tracksEvents && (ownSubs & SyncSubs.events) != 0
            && ((peerCaps & SyncCaps.events) != 0 || peerKindValue == SyncKind.hub) {
            emit(.node(.evtSince))
        }
    }

    private func groupChanged(_ t: Int64) {
        if state == .idle || state == .closed || state == .foreign || state == .incompatible {
            return
        }
        if ctx.group == nil {
            disconnect(.leftGroup)
            return
        }
        if state == .noGroup {
            send(SyncMsgType.join, joinFields(rekey: false))
        }
        restart(t)
    }

    private func rekey(_ t: Int64) {
        if state.isAuthedPlus && ctx.group != nil {
            send(SyncMsgType.join, joinFields(rekey: true))
            restart(t)
            return
        }
        groupChanged(t)
    }

    // MARK: Pulls

    private func sendPull(_ t: Int64, retry: Bool) {
        reqId = reqId % 255 + 1
        let ps: SyncPeerState = currentPeerState()
        var tries: Int = 1
        if retry, let p = pull {
            tries = p.tries + 1
        }
        send(SyncMsgType.pull, [
            "reqId": .int(reqId), "since": .int(ps.wm), "limit": .int(limit), "maxBytes": .int(maxBytes),
            "dbId": .bytes(ps.dbId), "exclude": .int(1),
        ])
        pull = PullState(reqId: reqId, since: ps.wm, recs: 0, tries: tries)
        arm(.page, t, SyncConst.pageTimeoutMs)
    }

    /// `feedHigh` nil = pull_now (∞).
    private func triggerPull(_ t: Int64, _ feedHigh: Int64?) {
        if (peerCaps & SyncCaps.feed) == 0 {
            return
        }
        if pull != nil || timers[.backoff] != nil {
            pendingHigh = max(pendingHigh, feedHigh ?? 0xFFFF_FFFF)
            return
        }
        sendPull(t, retry: false)
    }

    private func pageFailed(_ t: Int64) {
        guard let p = pull else {
            return
        }
        if p.tries >= SyncConst.pageTries {
            pull = nil
            disconnect(.pageTimeout, SyncConst.pageFailRetryMs)
            return
        }
        sendPull(t, retry: true)
    }

    // MARK: Receive

    private func rx(_ t: Int64, _ data: [UInt8]) {
        if state == .idle || state == .closed || state == .foreign || data.isEmpty {
            return
        }
        let rawType: UInt8 = data[0]
        if SyncMessageCodec.isHelloOtherProto(data) {
            sendErr(SyncErrorCode.proto, SyncMsgType.hello)
            incompatible(t, timeout: false)
            return
        }
        let decoded: SyncMessage?
        do {
            decoded = try SyncMessageCodec.decode(data)
        } catch {
            if rawType != SyncMsgType.err {
                sendErr(SyncErrorCode.badMsg, rawType)
            }
            return
        }
        guard let m = decoded else {
            return  // unknown message type: ignored
        }
        switch m.type {
        case SyncMsgType.hello:
            if isCentral {
                centralHello(t, m)
            } else {
                peripheralHello(t, m)
            }
            return
        case SyncMsgType.auth:
            peripheralAuth(t, m)
            return
        case SyncMsgType.join:
            join(t, m)
            return
        case SyncMsgType.err:
            onErr(t, m)
            return
        default:
            break
        }
        if !state.isAuthedPlus {
            return
        }
        onData(t, m)
    }

    private func onData(_ t: Int64, _ m: SyncMessage) {
        let ps: SyncPeerState = currentPeerState()
        switch m.type {
        case SyncMsgType.pull:
            if m.bytes("dbId") != ctx.dbId {
                sendErr(SyncErrorCode.dbChanged, SyncMsgType.pull, extra: ["dbId": .bytes(ctx.dbId)])
                return
            }
            emit(.deliver(m))
        case SyncMsgType.rec:
            emit(.deliver(m))
            let rid: Int64 = m.int("reqId") ?? 0
            if rid == 0 {
                arm(.livePull, t, SyncConst.livePullMs)
            } else if var p = pull, rid == p.reqId {
                p.recs += 1
                pull = p
                arm(.page, t, SyncConst.pageTimeoutMs)
            }
        case SyncMsgType.pageEnd:
            guard let p = pull, m.int("reqId") == p.reqId else {
                return  // stale
            }
            cancel(.page)
            if (m.int("count") ?? -1) != p.recs {
                pageFailed(t)
                return
            }
            ps.wm = max(p.since, m.int("scannedTo") ?? 0)
            emit(.commit(wm: ps.wm))
            if (m.int("more") ?? 0) != 0 {
                sendPull(t, retry: false)
                return
            }
            pull = nil
            if state == .syncing {
                setState(.synced)
            }
            if pendingHigh > ps.wm {
                pendingHigh = -1
                sendPull(t, retry: false)
            } else {
                pendingHigh = -1
            }
        case SyncMsgType.hb:
            emit(.deliver(m))
            if m.int("hops") == 0, let did = m.bytes("deviceId"), did == peerId {
                let fh: Int64 = m.int("feedHigh") ?? 0
                let db: [UInt8] = m.bytes("dbId") ?? SyncConst.zero8
                if db != ps.dbId {
                    ps.dbId = db
                    ps.wm = 0
                    ps.excludeOk = false
                    if pull != nil {
                        pull = nil
                        cancel(.page)
                    }
                    triggerPull(t, fh)
                } else if fh > ps.wm {
                    triggerPull(t, fh)
                }
            }
        case SyncMsgType.sub:
            peerSubs = m.int("subs") ?? peerSubs
            emit(.deliver(m))
        default:
            // EVT, EVT_SINCE, EVT_GAP
            emit(.deliver(m))
        }
    }

    private func onErr(_ t: Int64, _ m: SyncMessage) {
        emit(.deliver(m))
        let code: Int64 = m.int("code") ?? 0
        let retry: Int64 = m.int("retryMs") ?? SyncConst.defaultRetryMs
        if code == Int64(SyncErrorCode.auth) {
            foreign(t, nil, sendErr: false)
            return
        }
        if code == Int64(SyncErrorCode.proto) {
            incompatible(t, timeout: false)
            return
        }
        if code == Int64(SyncErrorCode.notReady) && isCentral && state == .linked && timers[.hello] != nil {
            cancel(.hello)
            backoff = .hello
            arm(.backoff, t, retry)
            return
        }
        if !state.isAuthedPlus {
            return
        }
        if (code == Int64(SyncErrorCode.notReady) || code == Int64(SyncErrorCode.busy)) && pull != nil
            && m.int("refType") == Int64(SyncMsgType.pull) {
            cancel(.page)
            pull = nil
            backoff = .pull
            arm(.backoff, t, retry)
            return
        }
        if code == Int64(SyncErrorCode.tooBig) && pull != nil {
            maxBytes = max(SyncConst.pullMaxBytesMin, maxBytes / 2)
            sendPull(t, retry: false)
            return
        }
        if code == Int64(SyncErrorCode.dbChanged), let db = m.bytes("dbId") {
            let ps: SyncPeerState = currentPeerState()
            ps.dbId = db
            ps.wm = 0
            ps.excludeOk = false
            pull = nil
            cancel(.page)
            if (peerCaps & SyncCaps.feed) != 0 {
                sendPull(t, retry: false)
            }
        }
    }

    // MARK: Timers

    private func onTimer(_ t: Int64, _ name: SyncTimer) {
        switch name {
        case .hello:
            if helloTries >= SyncConst.helloTries {
                incompatible(t, timeout: true)
                return
            }
            helloTries += 1
            resendHello(t)
        case .retry:
            startHello(t)
        case .auth:
            disconnect(.authTimeout)
        case .deadline:
            disconnect(.authDeadline)
        case .page:
            if pull != nil {
                pageFailed(t)
            }
        case .livePull:
            if pull != nil {
                arm(.livePull, t, SyncConst.livePullMs)
                return
            }
            sendPull(t, retry: false)
        case .hb:
            emit(.node(.sendHb))
            arm(.hb, t, SyncConst.hbIntervalMs)
        case .backoff:
            let what: Backoff? = backoff
            backoff = nil
            if what == .hello {
                helloTries = 1
                resendHello(t)
            } else if what == .pull {
                sendPull(t, retry: false)
            }
        }
    }
}
