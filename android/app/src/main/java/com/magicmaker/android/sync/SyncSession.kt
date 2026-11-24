package com.magicmaker.android.sync

// The per-link session state machine (§14) as a pure function of (state, ctx, input) -> (state',
// actions): no I/O, no clock reads, no randomness. Time is the input's t (ms); nonces come from
// the node through SessionCtx. The node executes the returned actions in order.

enum class SessionRole { CENTRAL, PERIPHERAL }

enum class SessionState {
    IDLE, LINKED, HELLO_X, AUTHED, SYNCING, SYNCED, FOREIGN, NOGROUP, INCOMPATIBLE, CLOSED;

    /** AUTHED, SYNCING or SYNCED ("AUTHED+"). */
    val isAuthed: Boolean get() = this == AUTHED || this == SYNCING || this == SYNCED
}

/** One of each per session (§14.5). */
enum class SessionTimer { HELLO, AUTH, DEADLINE, PAGE, LIVE_PULL, HB, RETRY, BACKOFF }

enum class NodeRequest(val wire: String) {
    /** Build and send this node's HB on the session. */
    SEND_HB("send_hb"),

    /** Send EVT_SINCE for the newest window of each tracked origin (iPhone). */
    EVT_SINCE("evt_since"),

    /** Mark the peer foreign (phones do not auto-reconnect to it). */
    FOREIGN("foreign"),
}

enum class DisconnectReason(val wire: String) {
    FOREIGN("foreign"),
    AUTH_TIMEOUT("auth_timeout"),
    AUTH_DEADLINE("auth_deadline"),
    PAGE_TIMEOUT("page_timeout"),
    LEFT_GROUP("left_group"),
}

/** Inputs (§14.3). */
sealed class SessionInput {
    data class LinkUp(val mtu: Int) : SessionInput()
    object LinkDown : SessionInput()
    data class Rx(val data: Bytes) : SessionInput()

    /** A timer reached its due time; ignored unless that timer is armed for exactly this t. */
    data class Timer(val name: SessionTimer) : SessionInput()

    /** The node joined / left a group on another link or by the user. */
    object GroupChanged : SessionInput()

    /** The node has a new key to spread. */
    object Rekey : SessionInput()

    /** Node-level pull trigger (e.g. the hub's hubFull clearing). */
    object PullNow : SessionInput()
}

/** Actions (§14.4), in emission order. */
sealed class SessionAction {
    data class Send(val type: Int, val bytes: Bytes) : SessionAction()
    data class State(val to: SessionState) : SessionAction()

    /** Hand a decoded message to the node (PULL to serve, REC to apply, HB, EVT..., SUB, ERR). */
    data class Deliver(val type: Int, val msg: SyncMsg) : SessionAction()

    /** A page completed: persist the page's data, then the peer's [wm]. */
    data class Commit(val wm: Long) : SessionAction()

    /** Persist this group key. */
    data class Group(val group: SyncGroup, val rekey: Boolean) : SessionAction()
    data class Node(val what: NodeRequest) : SessionAction()
    data class Disconnect(val reason: DisconnectReason, val retryMs: Long?) : SessionAction()
}

/** Per peer deviceId (§15.1), persisted by the node: the peer's dbId, wm on its feed, excludeOk. */
class PeerState(var dbId: Bytes = Bytes.ZERO8, var wm: Long = 0, var excludeOk: Boolean = false) {
    override fun toString(): String = "PeerState(dbId=$dbId, wm=$wm, excludeOk=$excludeOk)"
}

/** Fixed per session end (§14.2). [peerKind]: central only, known from discovery. */
data class SessionConfig(
    val role: SessionRole,
    val deviceId: Bytes,
    val kind: Int,
    val bootId: Int,
    val maxMsg: Int,
    val caps: Int = SyncConst.capsByKind(kind),
    val version: String? = null,
    val name: String? = null,
    val peerKind: Int? = null,
    val tracksEvents: Boolean = false,
    val isHub: Boolean = kind == SyncConst.KIND_HUB,
)

/**
 * Node-owned values the session reads (§14.2); the node mutates them between inputs. [peers] is
 * the node's peer table, shared by all its sessions. [clock] maps the input time t to clockMs (0 =
 * unknown); [nextNonce] returns a fresh random 8-byte nonce.
 */
class SessionCtx(
    var group: SyncGroup?,
    var dbId: Bytes,
    var feedHigh: Long,
    var clock: (Long) -> Long,
    var nextNonce: () -> Bytes,
    var ready: Boolean = true,
    val peers: MutableMap<Bytes, PeerState> = HashMap(),
)

/** The observable state after an input: state, armed timers (absolute due ms), this peer's entry. */
data class SessionSnapshot(val state: SessionState, val timers: Map<SessionTimer, Long>, val peer: PeerState?)

class SessionCore(val cfg: SessionConfig, val ctx: SessionCtx) {
    private class PullState(val reqId: Int, val since: Long, var recs: Int, val tries: Int)

    private enum class Backoff { HELLO, PULL }

    var state: SessionState = SessionState.IDLE
        private set
    private val timers = HashMap<SessionTimer, Long>()

    /** The peer's HELLO (null until one arrived). */
    var peer: Hello? = null
        private set

    /** What the peer wants to receive on this session (HELLO / SUB). */
    var peerSubs: Int = 0
        private set

    private var alike = false
    private var nonceC: Bytes? = null
    private var nonceP: Bytes? = null
    private var helloTries = 0
    private var lastReply: List<Pair<Int, Bytes>>? = null
    private var reqId = 0
    private var pull: PullState? = null
    private var pendingHigh = -1L
    private var limit = SyncConst.PULL_LIMIT_DEFAULT
    private var maxBytes = SyncConst.PULL_MAXBYTES_DEFAULT
    private var backoff: Backoff? = null
    private var out = ArrayList<SessionAction>()

    private val central: Boolean get() = cfg.role == SessionRole.CENTRAL
    val peerId: Bytes? get() = peer?.deviceId

    /** True while one of this session's pulls is outstanding. */
    val pullOutstanding: Boolean get() = pull != null

    fun timerDue(name: SessionTimer): Long? = timers[name]

    fun snapshot(): SessionSnapshot {
        val ps = peerId?.let { ctx.peers[it] }
        return SessionSnapshot(state, timers.toSortedMap(compareBy { it.name }), ps)
    }

    // -- entry point -------------------------------------------------------------------------

    fun handle(t: Long, input: SessionInput): List<SessionAction> {
        out = ArrayList()
        when (input) {
            is SessionInput.LinkUp -> linkUp(t, input.mtu)
            SessionInput.LinkDown -> {
                timers.clear()
                setState(SessionState.CLOSED)
            }
            is SessionInput.Rx -> rx(t, input.data)
            is SessionInput.Timer -> if (timers[input.name] == t) {
                timers.remove(input.name)
                onTimer(t, input.name)
            }
            SessionInput.GroupChanged -> groupChanged(t)
            SessionInput.Rekey -> rekey(t)
            SessionInput.PullNow -> if (state.isAuthed) triggerPull(t, null)
        }
        return out
    }

    // -- helpers -----------------------------------------------------------------------------

    private fun emit(a: SessionAction) {
        out.add(a)
    }

    private fun send(msg: SyncMsg): Bytes {
        val b = msg.encode()
        emit(SessionAction.Send(msg.type, b))
        return b
    }

    private fun setState(s: SessionState) {
        if (s != state) {
            state = s
            emit(SessionAction.State(s))
        }
    }

    private fun arm(name: SessionTimer, t: Long, ms: Long) {
        timers[name] = t + ms
    }

    private fun cancel(vararg names: SessionTimer) {
        for (n in names) timers.remove(n)
    }

    private fun err(code: Int, ref: Int?, dbId: Bytes? = null, retryMs: Int? = null) {
        send(Err(code, ref, dbId = dbId, retryMs = retryMs))
    }

    private fun peerState(): PeerState = ctx.peers.getOrPut(peerId!!) { PeerState() }

    private fun disconnect(reason: DisconnectReason, retryMs: Long? = null) {
        timers.clear()
        emit(SessionAction.Disconnect(reason, retryMs))
    }

    private val peerCaps: Int get() = peer?.capsOrDefault ?: 0

    // -- link / handshake --------------------------------------------------------------------

    private fun linkUp(t: Long, mtu: Int) {
        if (mtu < SyncConst.SMALL_MTU_BELOW) {
            limit = SyncConst.PULL_LIMIT_SMALL
            maxBytes = SyncConst.PULL_MAXBYTES_SMALL
        } else {
            limit = SyncConst.PULL_LIMIT_DEFAULT
            maxBytes = SyncConst.PULL_MAXBYTES_DEFAULT
        }
        setState(SessionState.LINKED)
        if (central) startHello(t)
        else if (cfg.isHub && ctx.group != null) arm(SessionTimer.DEADLINE, t, SyncConst.T_DEADLINE_MS)
    }

    private fun helloFields(t: Long, nonce: Bytes, proof: Bytes? = null): Hello {
        val peerKind = if (central) cfg.peerKind ?: 0 else peer!!.kind
        return Hello(
            proto = SyncConst.PROTO,
            deviceId = cfg.deviceId,
            kind = cfg.kind,
            dbId = ctx.dbId,
            clockMs = ctx.clock(t),
            feedHigh = ctx.feedHigh,
            subs = SyncRouting.subsFor(cfg.kind, peerKind),
            caps = cfg.caps,
            maxMsg = cfg.maxMsg,
            bootId = cfg.bootId,
            version = cfg.version?.takeIf { it.isNotEmpty() },
            name = cfg.name?.takeIf { it.isNotEmpty() },
            groupId = ctx.group?.groupId ?: Bytes.ZERO8,
            nonce = nonce,
            proof = proof,
        )
    }

    private fun startHello(t: Long) {
        setState(SessionState.LINKED)
        nonceC = ctx.nextNonce()
        helloTries = 1
        send(helloFields(t, nonceC!!))
        arm(SessionTimer.HELLO, t, SyncConst.T_HELLO_MS)
    }

    private fun resendHello(t: Long) {
        send(helloFields(t, nonceC!!))
        arm(SessionTimer.HELLO, t, SyncConst.T_HELLO_MS)
    }

    /** (proofP, proofC) for this handshake (§13.2). */
    private fun proofs(): Pair<Bytes, Bytes> {
        val key = ctx.group!!.groupKey
        val idC = if (central) cfg.deviceId else peerId!!
        val idP = if (central) peerId!! else cfg.deviceId
        return SyncCrypto.proofP(key, nonceC!!, nonceP!!, idC, idP) to SyncCrypto.proofC(key, nonceC!!, nonceP!!, idC, idP)
    }

    private fun theirs(m: Hello): Bytes? = if (m.groupId.isAllZero()) null else m.groupId

    private fun joinMsg(rekey: Boolean): Join {
        val g = ctx.group!!
        return Join(g.groupId, g.groupKey, if (rekey) SyncConst.JOIN_FLAG_REKEY else null)
    }

    private fun centralHello(t: Long, m: Hello) {
        if (state != SessionState.LINKED || nonceC == null || SessionTimer.HELLO !in timers) return
        cancel(SessionTimer.HELLO, SessionTimer.BACKOFF)
        peer = m
        peerSubs = m.subs
        nonceP = m.nonce
        val mine = ctx.group?.groupId
        val theirs = theirs(m)
        when {
            mine != null && theirs != null -> {
                if (mine != theirs) return foreign(MsgType.HELLO)
                val (pp, pc) = proofs()
                if (m.proof == null || !SyncCrypto.constantTimeEquals(m.proof, pp)) return foreign(MsgType.HELLO)
                alike = true
                setState(SessionState.HELLO_X)
                send(Auth(pc))
                authed(t)
            }
            mine != null -> {
                send(joinMsg(rekey = false))
                startHello(t)
            }
            theirs != null -> {
                setState(SessionState.HELLO_X)
                arm(SessionTimer.AUTH, t, SyncConst.T_AUTH_MS)
            }
            else -> setState(SessionState.NOGROUP)
        }
    }

    private fun peripheralHello(t: Long, m: Hello) {
        val last = lastReply
        if (nonceC != null && m.nonce == nonceC && last != null) {
            if (state == SessionState.LINKED || state == SessionState.HELLO_X || state == SessionState.NOGROUP) {
                for ((type, bytes) in last) emit(SessionAction.Send(type, bytes))
            }
            return
        }
        if (!ctx.ready) {
            err(ErrCode.NOT_READY, MsgType.HELLO, retryMs = SyncConst.NOT_READY_RETRY_MS)
            return
        }
        if (state.isAuthed) resetSync()
        cancel(SessionTimer.AUTH)
        peer = m
        peerSubs = m.subs
        nonceC = m.nonce
        nonceP = ctx.nextNonce()
        alike = false
        val mine = ctx.group?.groupId
        val theirs = theirs(m)
        val reply = ArrayList<Pair<Int, Bytes>>()
        when {
            mine != null && theirs != null && mine == theirs -> {
                alike = true
                val (pp, _) = proofs()
                reply.add(MsgType.HELLO to send(helloFields(t, nonceP!!, proof = pp)))
                setState(SessionState.HELLO_X)
                arm(SessionTimer.AUTH, t, SyncConst.T_AUTH_MS)
            }
            mine != null && theirs != null -> {
                send(helloFields(t, nonceP!!))
                lastReply = null
                return foreign(MsgType.HELLO)
            }
            mine != null -> {
                reply.add(MsgType.HELLO to send(helloFields(t, nonceP!!)))
                reply.add(MsgType.JOIN to send(joinMsg(rekey = false)))
                setState(SessionState.LINKED)
            }
            theirs != null -> {
                reply.add(MsgType.HELLO to send(helloFields(t, nonceP!!)))
                setState(SessionState.HELLO_X)
                arm(SessionTimer.AUTH, t, SyncConst.T_AUTH_MS)
            }
            else -> {
                reply.add(MsgType.HELLO to send(helloFields(t, nonceP!!)))
                setState(SessionState.NOGROUP)
            }
        }
        lastReply = reply
    }

    private fun peripheralAuth(t: Long, m: Auth) {
        if (central || state != SessionState.HELLO_X || !alike) return
        val (_, pc) = proofs()
        if (SyncCrypto.constantTimeEquals(m.proof, pc)) {
            cancel(SessionTimer.AUTH)
            authed(t)
        } else {
            foreign(MsgType.AUTH)
        }
    }

    private fun join(t: Long, m: Join) {
        val g = SyncGroup(m.groupId, m.groupKey)
        if (!g.isConsistent()) return foreign(MsgType.JOIN)
        val mine = ctx.group?.groupId
        if (mine == m.groupId) return // already in that group (a rekey that reached us on two links)
        if (m.isRekey) {
            if (!state.isAuthed) return foreign(MsgType.JOIN)
            ctx.group = g
            emit(SessionAction.Group(g, rekey = true))
            return restart(t)
        }
        if (mine == null && (state == SessionState.HELLO_X || state == SessionState.NOGROUP) && peer != null) {
            ctx.group = g
            emit(SessionAction.Group(g, rekey = false))
            return restart(t)
        }
        foreign(MsgType.JOIN)
    }

    private fun restart(t: Long) {
        resetSync()
        cancel(SessionTimer.AUTH, SessionTimer.HELLO, SessionTimer.BACKOFF, SessionTimer.RETRY)
        alike = false
        lastReply = null
        if (central) {
            startHello(t)
        } else {
            nonceC = null
            setState(SessionState.LINKED)
            if (cfg.isHub && ctx.group != null && SessionTimer.DEADLINE !in timers) {
                arm(SessionTimer.DEADLINE, t, SyncConst.T_DEADLINE_MS)
            }
        }
    }

    private fun resetSync() {
        cancel(SessionTimer.PAGE, SessionTimer.LIVE_PULL, SessionTimer.HB, SessionTimer.BACKOFF)
        pull = null
        pendingHigh = -1
    }

    /** FOREIGN entry: ERR AUTH (unless caused by a received ERR AUTH), cancel all, mark, disconnect. */
    private fun foreign(ref: Int?, sendErr: Boolean = true) {
        if (sendErr) err(ErrCode.AUTH, ref)
        timers.clear()
        setState(SessionState.FOREIGN)
        emit(SessionAction.Node(NodeRequest.FOREIGN))
        emit(SessionAction.Disconnect(DisconnectReason.FOREIGN, null))
    }

    /** INCOMPATIBLE entry: cancel all timers but DEADLINE (a grouped hub still drops non-members). */
    private fun incompatible(t: Long, timeout: Boolean) {
        val deadline = timers[SessionTimer.DEADLINE]
        timers.clear()
        if (deadline != null) timers[SessionTimer.DEADLINE] = deadline
        setState(SessionState.INCOMPATIBLE)
        if (timeout && central) arm(SessionTimer.RETRY, t, SyncConst.T_RETRY_INCOMPATIBLE_MS)
    }

    private fun authed(t: Long) {
        val p = peer!!
        setState(SessionState.AUTHED)
        cancel(SessionTimer.AUTH, SessionTimer.DEADLINE, SessionTimer.HELLO, SessionTimer.BACKOFF, SessionTimer.RETRY)
        val ps = peerState()
        if (ps.dbId != p.dbId) {
            ps.dbId = p.dbId
            ps.wm = 0
            ps.excludeOk = false
        }
        pull = null
        pendingHigh = -1
        if (peerCaps and SyncConst.CAP_FEED != 0) {
            sendPull(t, retry = false)
            setState(SessionState.SYNCING)
        } else {
            setState(SessionState.SYNCED)
        }
        if (peerSubs and SyncConst.SUB_HEARTBEATS != 0) {
            emit(SessionAction.Node(NodeRequest.SEND_HB))
            arm(SessionTimer.HB, t, SyncConst.T_HB_MS)
        }
        if (cfg.tracksEvents && (SyncRouting.subsFor(cfg.kind, p.kind) and SyncConst.SUB_EVENTS != 0) &&
            (peerCaps and SyncConst.CAP_EVENTS != 0 || p.kind == SyncConst.KIND_HUB)
        ) {
            emit(SessionAction.Node(NodeRequest.EVT_SINCE))
        }
    }

    private fun groupChanged(t: Long) {
        if (state == SessionState.IDLE || state == SessionState.CLOSED || state == SessionState.FOREIGN ||
            state == SessionState.INCOMPATIBLE
        ) return
        if (ctx.group == null) return disconnect(DisconnectReason.LEFT_GROUP)
        if (state == SessionState.NOGROUP) send(joinMsg(rekey = false))
        restart(t)
    }

    private fun rekey(t: Long) {
        if (state.isAuthed && ctx.group != null) {
            send(joinMsg(rekey = true))
            return restart(t)
        }
        groupChanged(t)
    }

    // -- pulls -------------------------------------------------------------------------------

    private fun sendPull(t: Long, retry: Boolean) {
        reqId = reqId % 255 + 1
        val ps = peerState()
        val cur = pull
        val tries = if (retry && cur != null) cur.tries + 1 else 1
        send(Pull(reqId, ps.wm, limit, maxBytes, ps.dbId, 1))
        pull = PullState(reqId, ps.wm, 0, tries)
        arm(SessionTimer.PAGE, t, SyncConst.T_PAGE_MS)
    }

    /** Trigger a pull (§14.5): remembered (highest feedHigh, null = infinity) while one is outstanding. */
    private fun triggerPull(t: Long, feedHigh: Long?) {
        if (peerCaps and SyncConst.CAP_FEED == 0) return
        if (pull != null || SessionTimer.BACKOFF in timers) {
            pendingHigh = maxOf(pendingHigh, feedHigh ?: 0xFFFFFFFFL)
            return
        }
        sendPull(t, retry = false)
    }

    private fun pageFailed(t: Long) {
        if (pull!!.tries >= SyncConst.PAGE_TRIES) {
            pull = null
            return disconnect(DisconnectReason.PAGE_TIMEOUT, SyncConst.T_PAGE_FAIL_RETRY_MS)
        }
        sendPull(t, retry = true)
    }

    // -- receive -----------------------------------------------------------------------------

    private fun rx(t: Long, data: Bytes) {
        if (state == SessionState.IDLE || state == SessionState.CLOSED || state == SessionState.FOREIGN || data.isEmpty()) {
            return
        }
        val mtype = data[0]
        if (SyncMsgs.isForeignProtoHello(data)) {
            err(ErrCode.PROTO, MsgType.HELLO)
            return incompatible(t, timeout = false)
        }
        val m = try {
            SyncMsgs.decode(data)
        } catch (e: SyncException) {
            if (mtype != MsgType.ERR) err(ErrCode.BAD_MSG, mtype)
            return
        }
        when (m) {
            is SyncMsg.Unknown -> return
            is Hello -> return if (central) centralHello(t, m) else peripheralHello(t, m)
            is Auth -> return peripheralAuth(t, m)
            is Join -> return join(t, m)
            is Err -> return onErr(t, m)
            else -> {}
        }
        if (!state.isAuthed) return
        data(t, m)
    }

    private fun data(t: Long, m: SyncMsg) {
        val ps = peerState()
        when (m) {
            is Pull -> {
                if (m.dbId != ctx.dbId) return err(ErrCode.DB_CHANGED, MsgType.PULL, dbId = ctx.dbId)
                emit(SessionAction.Deliver(m.type, m))
            }
            is Rec -> {
                emit(SessionAction.Deliver(m.type, m))
                val p = pull
                if (m.reqId == 0) {
                    arm(SessionTimer.LIVE_PULL, t, SyncConst.T_LIVE_PULL_MS)
                } else if (p != null && m.reqId == p.reqId) {
                    p.recs += 1
                    arm(SessionTimer.PAGE, t, SyncConst.T_PAGE_MS)
                }
            }
            is PageEnd -> {
                val p = pull
                if (p == null || m.reqId != p.reqId) return
                cancel(SessionTimer.PAGE)
                if (m.count != p.recs) return pageFailed(t)
                ps.wm = maxOf(p.since, m.scannedTo)
                emit(SessionAction.Commit(ps.wm))
                if (m.more != 0) return sendPull(t, retry = false)
                pull = null
                if (state == SessionState.SYNCING) setState(SessionState.SYNCED)
                if (pendingHigh > ps.wm) {
                    pendingHigh = -1
                    sendPull(t, retry = false)
                } else {
                    pendingHigh = -1
                }
            }
            is Hb -> {
                emit(SessionAction.Deliver(m.type, m))
                if (m.hops == 0 && m.deviceId == peerId) {
                    if (m.dbId != ps.dbId) {
                        ps.dbId = m.dbId
                        ps.wm = 0
                        ps.excludeOk = false
                        if (pull != null) {
                            pull = null
                            cancel(SessionTimer.PAGE)
                        }
                        triggerPull(t, m.feedHigh)
                    } else if (m.feedHigh > ps.wm) {
                        triggerPull(t, m.feedHigh)
                    }
                }
            }
            is Sub -> {
                peerSubs = m.subs
                emit(SessionAction.Deliver(m.type, m))
            }
            else -> emit(SessionAction.Deliver(m.type, m)) // EVT, EVT_SINCE, EVT_GAP
        }
    }

    private fun onErr(t: Long, m: Err) {
        emit(SessionAction.Deliver(m.type, m))
        val retry = (m.retryMs ?: SyncConst.DEFAULT_RETRY_MS).toLong()
        when (m.code) {
            ErrCode.AUTH -> return foreign(null, sendErr = false)
            ErrCode.PROTO -> return incompatible(t, timeout = false)
        }
        if (m.code == ErrCode.NOT_READY && central && state == SessionState.LINKED && SessionTimer.HELLO in timers) {
            cancel(SessionTimer.HELLO)
            backoff = Backoff.HELLO
            return arm(SessionTimer.BACKOFF, t, retry)
        }
        if (!state.isAuthed) return
        if ((m.code == ErrCode.NOT_READY || m.code == ErrCode.BUSY) && pull != null && m.refType == MsgType.PULL) {
            cancel(SessionTimer.PAGE)
            pull = null
            backoff = Backoff.PULL
            return arm(SessionTimer.BACKOFF, t, retry)
        }
        if (m.code == ErrCode.TOO_BIG && pull != null) {
            maxBytes = maxOf(SyncConst.PULL_MAXBYTES_MIN, maxBytes / 2)
            return sendPull(t, retry = false)
        }
        if (m.code == ErrCode.DB_CHANGED && m.dbId != null) {
            val ps = peerState()
            ps.dbId = m.dbId
            ps.wm = 0
            ps.excludeOk = false
            pull = null
            cancel(SessionTimer.PAGE)
            if (peerCaps and SyncConst.CAP_FEED != 0) sendPull(t, retry = false)
        }
    }

    // -- timers ------------------------------------------------------------------------------

    private fun onTimer(t: Long, name: SessionTimer) {
        when (name) {
            SessionTimer.HELLO -> {
                if (helloTries >= SyncConst.HELLO_TRIES) return incompatible(t, timeout = true)
                helloTries += 1
                resendHello(t)
            }
            SessionTimer.RETRY -> startHello(t)
            SessionTimer.AUTH -> disconnect(DisconnectReason.AUTH_TIMEOUT)
            SessionTimer.DEADLINE -> disconnect(DisconnectReason.AUTH_DEADLINE)
            SessionTimer.PAGE -> if (pull != null) pageFailed(t)
            SessionTimer.LIVE_PULL -> {
                if (pull != null) arm(SessionTimer.LIVE_PULL, t, SyncConst.T_LIVE_PULL_MS)
                else sendPull(t, retry = false)
            }
            SessionTimer.HB -> {
                emit(SessionAction.Node(NodeRequest.SEND_HB))
                arm(SessionTimer.HB, t, SyncConst.T_HB_MS)
            }
            SessionTimer.BACKOFF -> {
                val what = backoff
                backoff = null
                when (what) {
                    Backoff.HELLO -> {
                        helloTries = 1
                        resendHello(t)
                    }
                    Backoff.PULL -> sendPull(t, retry = false)
                    null -> {}
                }
            }
        }
    }
}
