package com.magicmaker.android.sync

// The pure sync engine of one device (docs/SYNC_P3_ANDROID_PLAN.md §5.1-§5.2): a Kotlin port of
// tools/sync/gen_vectors.py `class Node`, the executable model that produced the shared transcripts.
// It owns one P1 SessionCore per link, executes their actions, serves and applies records through
// SyncLibraryPort, routes live records and heartbeats, and builds this device's HB. Kind-specific
// behaviour (events, the hub's relays) is behind NodeRole. Single-threaded: every input arrives on
// the node's thread (mm-sync in production; the virtual scheduler in tests), no I/O of its own.

/** Per-session counters (plan §5.8 diagnostics). */
class SessionCounters {
    var pagesPulled = 0
    var pagesServed = 0
    var recsServed = 0
    var accepted = 0
    var duplicates = 0
    var stale = 0
    var rejected = 0
    var errsReceived = 0
    var evtSent = 0
    var evtReplayed = 0
    var gapsSent = 0
    var badFrames = 0

    fun copy(): SessionCounters = SessionCounters().also {
        it.pagesPulled = pagesPulled
        it.pagesServed = pagesServed
        it.recsServed = recsServed
        it.accepted = accepted
        it.duplicates = duplicates
        it.stale = stale
        it.rejected = rejected
        it.errsReceived = errsReceived
        it.evtSent = evtSent
        it.evtReplayed = evtReplayed
        it.gapsSent = gapsSent
        it.badFrames = badFrames
    }
}

/** One session as the status view sees it. */
data class SessionInfo(
    val linkId: String,
    val role: SessionRole,
    val state: SessionState,
    val peerId: Bytes?,
    val peerKind: Int?,
    val peerName: String?,
    val peerVersion: String?,
    val peerCaps: Int,
    val mtu: Int,
    val upAtMs: Long,
    val wm: Long?,
    val peerFeedHigh: Long,
    val servedTo: Long,
    val pendingLive: Int,
    val pullOutstanding: Boolean,
    val counters: SessionCounters,
    val lastErr: String?,
)

/** What is remembered about a link after its session closed (status: OTHER GROUP, UPDATE APP, ever synced). */
data class LinkMemo(
    val linkId: String,
    val peerId: Bytes?,
    val peerKind: Int?,
    val lastState: SessionState,
    val atMs: Long,
    val everSynced: Boolean,
    val lastSyncedMs: Long?,
)

data class NodeSnapshot(
    val nowMs: Long,
    val deviceId: Bytes,
    val group: SyncGroup?,
    val dbId: Bytes,
    val durableHigh: Long,
    val sessions: List<SessionInfo>,
    val memos: List<LinkMemo>,
    /** Peer deviceId -> the highest feedHigh it reported (HELLO, PAGE_END, direct HB). */
    val peerFeedHigh: Map<Bytes, Long>,
    /** Peer deviceId -> the scannedTo of the last page served to it. */
    val servedTo: Map<Bytes, Long>,
    /** Peer deviceId -> records accepted FROM it with seq in (servedTo, durableHigh]: it has those already. */
    val acceptedSinceServe: Map<Bytes, Long>,
    val peers: Map<Bytes, PeerState>,
    val hbSeq: Long,
)

class SyncNode(
    val cfg: NodeConfig,
    val identity: SyncIdentityPort,
    val library: SyncLibraryPort,
    val roster: DeviceRosterPort,
    val sched: SyncScheduler,
    val role: NodeRole,
    private val self: () -> SelfStatus,
    val policy: NodePolicy = NodePolicy.PRODUCTION,
    private val nonces: (linkId: String) -> Bytes,
    var bootId: Int,
) {
    /** One link's session (created at link-up, dropped at link-down). */
    inner class Session internal constructor(
        val link: LinkPort,
        val sessionRole: SessionRole,
        val core: SessionCore,
        internal val ctx: SessionCtx,
        val mtuAtUp: Int,
        val upAtMs: Long,
    ) {
        val id: String get() = link.id
        val state: SessionState get() = core.state
        val peerId: Bytes? get() = core.peerId
        val peerKind: Int? get() = core.peer?.kind
        val peerSubs: Int get() = core.peerSubs
        val peerCaps: Int get() = core.peer?.capsOrDefault ?: 0
        val counters = SessionCounters()
        var lastErr: String? = null
            internal set
        internal val scheduled = HashSet<Pair<SessionTimer, Long>>()
        internal var wasAuthed = false
        internal var wasSynced = false
    }

    private val sessions = LinkedHashMap<String, Session>()

    /** The node's one peer table (§15.1), shared by every session's SessionCtx. */
    private val peers: MutableMap<Bytes, PeerState> = HashMap()
    private val persisted = HashMap<Bytes, Triple<Bytes, Long, Boolean>>()
    private val peerFeedHigh = HashMap<Bytes, Long>()
    private val servedTo = HashMap<Bytes, Long>()
    private val fromPeerSeqs = HashMap<Bytes, java.util.TreeSet<Long>>()
    private val memos = LinkedHashMap<String, LinkMemo>()

    /** The raw bytes of the message being handled (HB forwarding, EVT_SINCE / EVT_GAP relays). */
    private var rxRaw: Bytes? = null

    private var hbSeq = 0L
    private var lastHbT = Long.MIN_VALUE / 4
    private var hbRoundPending = false
    private var pageAccepted = false
    private var bulkPending = false
    private val recentLocal = ArrayDeque<Long>()

    var trace: SyncTrace = object : SyncTrace {}

    /** A Group action or leaveGroup(): re-advertise with the new tag. */
    var onGroupChanged: ((SyncGroup?) -> Unit)? = null

    /** NodeRequest.FOREIGN on [linkId] (HubClient: forget that MAC). */
    var onForeign: ((linkId: String) -> Unit)? = null

    /** A session reached AUTHED (HubClient: remember the hub's address). */
    var onAuthed: ((Session) -> Unit)? = null

    /** Anything the status view shows may have changed. */
    var onChanged: (() -> Unit)? = null

    init {
        for ((k, v) in library.loadPeers()) {
            peers[k] = PeerState(v.state.dbId, v.state.wm, v.state.excludeOk)
            persisted[k] = Triple(v.state.dbId, v.state.wm, v.state.excludeOk)
        }
        role.bind(this)
    }

    // ---- small accessors -----------------------------------------------------------------

    /** Wall clock, or null while it is unknown (the hub before it learns the time). */
    fun wall(): Long? = if (role.clockKnown()) sched.wallMs() else null

    fun wallOrZero(): Long = wall() ?: 0L

    fun sessions(): List<Session> = sessions.values.toList()

    fun session(linkId: String): Session? = sessions[linkId]

    fun authedSessions(): List<Session> = sessions.values.filter { it.core.state.isAuthed }

    /** The first AUTHED+ session whose peer is [peerId] (gen_vectors.Node.lid_for). */
    fun sessionFor(peerId: Bytes): Session? = sessions.values.firstOrNull { it.core.peerId == peerId && it.core.state.isAuthed }

    /** The peer table as it is now (tests; copies). */
    fun peerTable(): Map<Bytes, PeerState> = peers.mapValues { PeerState(it.value.dbId, it.value.wm, it.value.excludeOk) }

    /** A listener that calls straight into this node (tests; production posts first). */
    fun inlineListener(): SyncLibraryListener = object : SyncLibraryListener {
        override fun onLocalChanges(entries: List<LedgerEntry>, bulk: Boolean) = this@SyncNode.onLocalChanges(entries, bulk)

        override fun onDurable(durableHigh: Long) = this@SyncNode.onDurable(durableHigh)
    }

    // ---- inputs --------------------------------------------------------------------------

    /** A link is up (central: [peerKindHint] from discovery). Creates the session and feeds LinkUp. */
    fun linkUp(link: LinkPort, role: SessionRole, mtu: Int, peerKindHint: Int?): Session {
        sessions[link.id]?.let { linkDown(link.id) }
        val scfg = SessionConfig(
            role = role,
            deviceId = cfg.deviceId,
            kind = cfg.kind,
            bootId = bootId,
            maxMsg = cfg.maxMsg,
            version = cfg.version,
            name = cfg.name,
            peerKind = if (role == SessionRole.CENTRAL) peerKindHint else null,
            tracksEvents = this.role.tracksEvents,
        )
        val ctx = SessionCtx(
            group = identity.group,
            dbId = identity.dbId,
            feedHigh = library.durableHigh(),
            clock = { _ -> wallOrZero() },
            nextNonce = { nonces(link.id) },
            ready = true,
            peers = peers,
        )
        val s = Session(link, role, SessionCore(scfg, ctx), ctx, mtu, sched.now())
        sessions[link.id] = s
        input(s, SessionInput.LinkUp(mtu))
        return s
    }

    fun linkDown(linkId: String) {
        val s = sessions[linkId] ?: return
        input(s, SessionInput.LinkDown)
        remember(s)
        sessions.remove(linkId)
        role.onLinkDown(s)
        changed()
    }

    /** One reassembled message from [linkId]. */
    fun onMessage(linkId: String, bytes: Bytes) {
        val s = sessions[linkId] ?: return
        if (bytes.size > 0 && bytes[0] == MsgType.PAGE_END) notePageEnd(s, bytes)
        rxRaw = bytes
        input(s, SessionInput.Rx(bytes))
    }

    /** Local edits / learns, in seq order (SyncLibraryListener). */
    fun onLocalChanges(entries: List<LedgerEntry>, bulk: Boolean) {
        if (entries.isEmpty()) return
        val now = sched.now()
        if (!bulk) {
            repeat(entries.size) { recentLocal.addLast(now) }
            while (recentLocal.isNotEmpty() && now - recentLocal.first() >= BULK_WINDOW_MS) recentLocal.removeFirst()
        }
        if (bulk || recentLocal.size > BULK_MAX_LIVE) {
            bulkPending = true
        } else {
            var pushed = true
            for (e in entries) pushed = pushLocal(e) && pushed
            // Production: a change no session took live (none was up yet) is announced by the
            // on-change HB after its write, like a bulk change, instead of waiting for the 60 s HB.
            if (!pushed && policy == NodePolicy.PRODUCTION) bulkPending = true
        }
        changed()
    }

    /** A store write completed (SyncLibraryListener). */
    fun onDurable(@Suppress("UNUSED_PARAMETER") durableHigh: Long) {
        if (pageAccepted || bulkPending) {
            pageAccepted = false
            bulkPending = false
            requestHb()
        }
        changed()
    }

    /** Battery, charging or state bits changed (production on-change HB). */
    fun selfChanged() {
        if (policy == NodePolicy.PRODUCTION) requestHb()
        changed()
    }

    /** "Leave sync group": forget the key; every session disconnects `left_group`; re-advertise untagged. */
    fun leaveGroup() {
        identity.setGroup(null)
        for (s in sessions.values.toList()) if (sessions[s.id] === s) input(s, SessionInput.GroupChanged)
        onGroupChanged?.invoke(null)
        changed()
    }

    /** A node-level pull trigger on every session (e.g. after a long pause). */
    fun pullNow() {
        for (s in authedSessions()) input(s, SessionInput.PullNow)
    }

    /**
     * Test stand-in for a hub library reset (gen_vectors.Node.sync_reset): the caller has already
     * replaced the dbId and emptied the library. Clears the peer table and closes every session.
     */
    fun dbReset(reason: String) {
        peers.clear()
        persisted.clear()
        for (s in sessions.values.toList()) {
            trace.disconnect(s.id, reason, null)
            s.link.disconnect(reason, null)
        }
    }

    // ---- session plumbing (plan §5.2) -----------------------------------------------------

    private fun refresh(s: Session) {
        s.ctx.group = identity.group
        s.ctx.dbId = identity.dbId
        s.ctx.feedHigh = library.durableHigh()
        s.ctx.ready = true
    }

    /** Feed [inp] to [s]'s core and execute the actions. Timers carry t = due (D-P3-2). */
    private fun input(s: Session, inp: SessionInput, t: Long = sched.now()) {
        if (sessions[s.id] !== s) return
        refresh(s)
        val acts = s.core.handle(t, inp)
        val deferred = ArrayList<SessionAction.Group>()
        for (a in acts) {
            when (a) {
                is SessionAction.Send -> s.link.send(a.type, a.bytes, SyncLane.MAIN)
                is SessionAction.State -> onState(s, a.to)
                is SessionAction.Deliver -> deliver(s, a.msg)
                is SessionAction.Commit -> commit(s)
                is SessionAction.Group -> {
                    identity.setGroup(a.group)
                    trace.group(s.id, a.group.groupId, a.rekey)
                    deferred.add(a)
                }
                is SessionAction.Node -> when (a.what) {
                    NodeRequest.SEND_HB -> sendHb(listOf(s))
                    NodeRequest.EVT_SINCE -> role.sendEvtSinceAll(s)
                    NodeRequest.FOREIGN -> {
                        trace.foreign(s.id)
                        onForeign?.invoke(s.id)
                    }
                }
                is SessionAction.Disconnect -> {
                    trace.disconnect(s.id, a.reason.wire, a.retryMs)
                    s.link.disconnect(a.reason.wire, a.retryMs)
                }
            }
        }
        if (sessions[s.id] === s) syncTimers(s)
        for (g in deferred) {
            for (o in sessions.values.toList()) {
                if (o.id == s.id || sessions[o.id] !== o) continue
                if (g.rekey && o.core.state.isAuthed) input(o, SessionInput.Rekey) else input(o, SessionInput.GroupChanged)
            }
            onGroupChanged?.invoke(g.group)
        }
        persistPeers()
        changed()
    }

    private fun syncTimers(s: Session) {
        val now = sched.now()
        s.scheduled.removeAll { it.second < now }
        for ((name, due) in s.core.snapshot().timers) {
            if (!s.scheduled.add(name to due)) continue
            sched.at(due) {
                if (sessions[s.id] === s && s.core.timerDue(name) == due) {
                    trace.timer(s.id, name)
                    input(s, SessionInput.Timer(name), due)
                }
            }
        }
    }

    private fun onState(s: Session, to: SessionState) {
        trace.state(s.id, to)
        if (to == SessionState.AUTHED) {
            role.onAuthed(s)
            onAuthed?.invoke(s)
        }
        val authed = to.isAuthed
        val synced = to == SessionState.SYNCED
        if (synced) remember(s, synced = true)
        if (to == SessionState.FOREIGN || to == SessionState.INCOMPATIBLE || to == SessionState.NOGROUP) remember(s)
        val changedEdge = authed != s.wasAuthed || synced != s.wasSynced
        s.wasAuthed = authed
        s.wasSynced = synced
        if (changedEdge && policy == NodePolicy.PRODUCTION) requestHb()
        s.core.peer?.let { p -> peerFeedHigh[p.deviceId] = maxOf(peerFeedHigh[p.deviceId] ?: -1, p.feedHigh) }
    }

    private fun remember(s: Session, synced: Boolean = false) {
        val old = memos[s.id]
        val now = sched.now()
        val ever = synced || old?.everSynced == true || s.core.state == SessionState.SYNCED
        memos[s.id] = LinkMemo(
            linkId = s.id,
            peerId = s.peerId ?: old?.peerId,
            peerKind = s.peerKind ?: old?.peerKind,
            lastState = if (s.core.state == SessionState.CLOSED && old != null && old.lastState != SessionState.SYNCED &&
                old.lastState != SessionState.CLOSED
            ) old.lastState else s.core.state,
            atMs = now,
            everSynced = ever,
            lastSyncedMs = if (synced || s.core.state == SessionState.SYNCED) now else old?.lastSyncedMs,
        )
        while (memos.size > 16) memos.remove(memos.keys.first())
    }

    private fun persistPeers() {
        for ((k, ps) in peers) {
            val cur = Triple(ps.dbId, ps.wm, ps.excludeOk)
            if (persisted[k] != cur) {
                persisted[k] = cur
                library.putPeer(k, ps, null)
            }
        }
    }

    private fun changed() {
        onChanged?.invoke()
    }

    // ---- delivered messages ----------------------------------------------------------------

    private fun deliver(s: Session, m: SyncMsg) {
        when (m) {
            is Pull -> servePull(s, m)
            is Rec -> onRec(s, m)
            is Hb -> onHb(s, m)
            is Evt -> role.onEvt(s, m)
            is EvtSince -> role.onEvtSince(s, m, rxRaw ?: m.encode())
            is EvtGap -> role.onEvtGap(s, m, rxRaw ?: m.encode())
            is Err -> {
                s.counters.errsReceived++
                s.lastErr = m.codeName + (m.refType?.let { " ref " + MsgType.name(it) } ?: "")
            }
            else -> Unit // SUB: the core keeps peerSubs
        }
    }

    private fun servePull(s: Session, m: Pull) {
        val peer = s.peerId ?: return
        val ps = peers.getOrPut(peer) { PeerState() }
        val page = library.servePage(m, ps.excludeOk, peer)
        for (r in page.recs) s.link.send(MsgType.REC, r, SyncLane.MAIN)
        s.link.send(MsgType.PAGE_END, page.pageEnd.encode(), SyncLane.MAIN)
        s.counters.pagesServed++
        s.counters.recsServed += page.recs.size
        servedTo[peer] = maxOf(servedTo[peer] ?: -1, page.pageEnd.scannedTo)
        fromPeerSeqs[peer]?.headSet(page.pageEnd.scannedTo, true)?.clear()
        if (page.pageEnd.more == 0) ps.excludeOk = true
    }

    private fun onRec(s: Session, m: Rec) {
        val peer = s.peerId ?: return
        val live = m.reqId == 0
        val bodyErr = m.bodyError
        if (bodyErr != null) {
            val st = if (bodyErr.code == ErrCode.CLOCK) ApplyStatus.CLOCK else ApplyStatus.BAD_MSG
            trace.apply(s.id, null, st, live)
            s.counters.rejected++
            s.link.send(MsgType.ERR, Err(bodyErr.code, MsgType.REC, key = m.errKey).encode(), SyncLane.MAIN)
            return
        }
        val key = m.bodyFields!!.key
        val r = library.applyRemote(m.body, peer, wall(), live)
        trace.apply(s.id, key.keyString, r.status, live)
        when (r.status) {
            ApplyStatus.BAD_MSG, ApplyStatus.CLOCK -> {
                s.counters.rejected++
                val code = if (r.status == ApplyStatus.CLOCK) ErrCode.CLOCK else ErrCode.BAD_MSG
                s.link.send(MsgType.ERR, Err(code, MsgType.REC, key = key).encode(), SyncLane.MAIN)
            }
            ApplyStatus.DUPLICATE -> s.counters.duplicates++
            ApplyStatus.STALE -> s.counters.stale++
            ApplyStatus.ACCEPT -> {
                s.counters.accepted++
                r.entry?.let { e ->
                    val set = fromPeerSeqs.getOrPut(peer) { java.util.TreeSet() }
                    set.add(e.seq)
                    while (set.size > FROM_PEER_CAP) set.pollFirst()
                }
                if (!live) {
                    pageAccepted = true
                    return
                }
                val e = r.entry ?: return
                val sess = authedSessions().map { RouteSession(it.peerId!!, it.peerSubs and SyncConst.SUB_RECORDS != 0, true) }
                val route = SyncRouting.routeLiveRec(cfg.deviceId, peer, e.origin, m.seenBy, sess)
                if (route.targets.isEmpty()) return
                identity.ensureIssued(e.seq + 1)
                val msg = Rec(e.seq, 0, route.seenBy, e.bodyBytes).encode()
                for (tgt in route.targets) sessionFor(tgt)?.link?.send(MsgType.REC, msg, SyncLane.MAIN)
            }
        }
    }

    private fun commit(s: Session) {
        val peer = s.peerId ?: return
        val ps = peers[peer] ?: return
        s.counters.pagesPulled++
        persisted[peer] = Triple(ps.dbId, ps.wm, ps.excludeOk)
        library.commitPage(peer, ps, sched.wallMs())
    }

    private fun notePageEnd(s: Session, bytes: Bytes) {
        val peer = s.peerId ?: return
        val pe = try {
            SyncMsgs.decode(bytes) as? PageEnd
        } catch (e: SyncException) {
            null
        } ?: return
        peerFeedHigh[peer] = maxOf(peerFeedHigh[peer] ?: -1, pe.feedHigh)
    }

    private fun onHb(s: Session, hb: Hb) {
        val peer = s.peerId ?: return
        roster.onHb(hb, peer, sched.now())
        val direct = hb.hops == 0 && hb.deviceId == peer
        if (direct) {
            peerFeedHigh[peer] = maxOf(peerFeedHigh[peer] ?: -1, hb.feedHigh)
            val raw = rxRaw
            if (raw != null) {
                val sess = authedSessions().map { RouteSession(it.peerId!!, it.peerSubs and SyncConst.SUB_HEARTBEATS != 0, true) }
                val targets = SyncRouting.routeHb(cfg.deviceId, peer, hb.deviceId, 0, sess)
                if (targets.isNotEmpty()) {
                    val fwd = try {
                        SyncMsgs.hbSetHops(raw, 1)
                    } catch (e: RuntimeException) {
                        null
                    }
                    if (fwd != null) for (tgt in targets) sessionFor(tgt)?.link?.send(MsgType.HB, fwd, SyncLane.MAIN)
                }
            }
        }
        role.onHb(s, hb, direct)
    }

    // ---- local changes -----------------------------------------------------------------------

    /** Push one local entry live; false when no session took it. */
    private fun pushLocal(e: LedgerEntry): Boolean {
        val sess = authedSessions().map { RouteSession(it.peerId!!, it.peerSubs and SyncConst.SUB_RECORDS != 0, true) }
        val route = SyncRouting.routeLocalRec(cfg.deviceId, sess)
        if (route.targets.isEmpty()) return false
        identity.ensureIssued(e.seq + 1)
        val msg = Rec(e.seq, 0, route.seenBy, e.bodyBytes).encode()
        for (tgt in route.targets) sessionFor(tgt)?.link?.send(MsgType.REC, msg, SyncLane.MAIN)
        return true
    }

    // ---- heartbeats ----------------------------------------------------------------------------

    /** One on-change HB round at max(now, last HB + 5 s) to every AUTHED+ session subscribed to HBs. */
    fun requestHb() {
        if (hbRoundPending) return
        hbRoundPending = true
        val due = maxOf(sched.now(), lastHbT + SyncConst.T_HB_SPACING_MS)
        sched.at(due) { hbRound() }
    }

    private fun hbRound() {
        hbRoundPending = false
        val targets = authedSessions().filter { it.peerSubs and SyncConst.SUB_HEARTBEATS != 0 }
        if (targets.isNotEmpty()) sendHb(targets)
    }

    /** This device's HB (spec §9.1); consumes one hbSeq. */
    fun buildHb(): Hb {
        hbSeq++
        val links = authedSessions().mapNotNull { s ->
            val p = s.core.peer ?: return@mapNotNull null
            val fl = (if (s.core.state == SessionState.SYNCED) SyncConst.HB_LINK_SYNCED else 0) or
                (if (p.capsOrDefault and SyncConst.CAP_TRANSMITTER != 0) SyncConst.HB_LINK_TX_READY else 0)
            HbLink(p.deviceId, p.kind, fl)
        }.take(SyncConst.HB_LINKS_MAX)
        val st = self()
        val hb = Hb(
            deviceId = cfg.deviceId,
            kind = cfg.kind,
            bootId = bootId,
            hbSeq = hbSeq and 0xFFFF_FFFFL,
            ts = wallOrZero(),
            uptimeS = st.uptimeS.coerceIn(0, 0xFFFF_FFFFL),
            battPct = st.battPct.coerceIn(-1, 100),
            battMv = st.battMv.coerceIn(-1, 0x7FFF),
            charging = st.charging.coerceIn(-1, 1),
            runtimeMin = st.runtimeMin.coerceIn(-1, 5999),
            version = cfg.version,
            name = cfg.name,
            link = links,
            state = st.state and 0xFFFF,
            hops = 0,
            feedHigh = library.durableHigh(),
            dbId = identity.dbId,
            records = library.recordCount().toLong(),
            hubAirAgoS = if (cfg.kind == SyncConst.KIND_ANDROID) st.hubAirAgoS?.coerceIn(0, 0xFFFF) else null,
        )
        return role.hbExtras(hb)
    }

    private fun sendHb(targets: List<Session>) {
        val hb = buildHb()
        lastHbT = sched.now()
        val bytes = try {
            hb.encode()
        } catch (e: IllegalArgumentException) {
            trace.note("HB does not encode: ${e.message}")
            return
        }
        for (s in targets) s.link.send(MsgType.HB, bytes, SyncLane.MAIN)
    }

    // ---- status ------------------------------------------------------------------------------

    fun snapshot(): NodeSnapshot = NodeSnapshot(
        nowMs = sched.now(),
        deviceId = cfg.deviceId,
        group = identity.group,
        dbId = identity.dbId,
        durableHigh = library.durableHigh(),
        sessions = sessions.values.map { s ->
            val p = s.core.peer
            SessionInfo(
                linkId = s.id,
                role = s.sessionRole,
                state = s.core.state,
                peerId = p?.deviceId,
                peerKind = p?.kind,
                peerName = p?.name,
                peerVersion = p?.version,
                peerCaps = p?.capsOrDefault ?: 0,
                mtu = s.link.mtu(),
                upAtMs = s.upAtMs,
                wm = p?.let { peers[it.deviceId]?.wm },
                peerFeedHigh = p?.let { peerFeedHigh[it.deviceId] } ?: -1,
                servedTo = p?.let { servedTo[it.deviceId] } ?: -1,
                pendingLive = s.link.pendingLive(),
                pullOutstanding = s.core.pullOutstanding,
                counters = s.counters.copy(),
                lastErr = s.lastErr,
            )
        },
        memos = memos.values.toList(),
        peerFeedHigh = HashMap(peerFeedHigh),
        servedTo = HashMap(servedTo),
        acceptedSinceServe = fromPeerSeqs.mapValues { (k, set) ->
            val lo = servedTo[k] ?: -1
            val hi = library.durableHigh()
            if (hi <= lo) 0L else set.subSet(lo, false, hi, true).size.toLong()
        },
        peers = peerTable(),
        hbSeq = hbSeq,
    )

    companion object {
        /** Live pushes per trailing second before local changes count as bulk (spec §3.8). */
        const val BULK_MAX_LIVE: Int = 4
        const val BULK_WINDOW_MS: Long = 1000
        private const val FROM_PEER_CAP = 5000
    }
}
