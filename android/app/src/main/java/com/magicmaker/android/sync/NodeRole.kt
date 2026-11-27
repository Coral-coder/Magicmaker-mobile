package com.magicmaker.android.sync

// P3 part 2 (docs/SYNC_P3_ANDROID_PLAN.md §5.1): what the pure SyncNode needs from its surroundings
// (links, a scheduler, self status) and the kind-specific behaviour behind NodeRole. AndroidRole is
// this phone's role (heard-packet events, catch-up, hubAirAgoS); the iPhone and hub stand-ins used
// by the transcript replay live in test sources. Pure Kotlin; everything runs on one thread
// (mm-sync in production, the test's virtual scheduler in tests).

/** One end of a link as the node sees it (a [LinkChannel] in production, a test pipe in tests). */
interface LinkPort {
    val id: String

    /**
     * Queue one whole message. Lane 0 carries everything in FIFO order; lane 1 carries catch-up
     * replays and EVT_GAPs, which leave only while lane 0 is empty (plan §5.3).
     */
    fun send(type: Int, bytes: Bytes, lane: Int)

    /** Close once the queued messages have left (or after a short timeout). [retryMs]: the session's reconnect floor. */
    fun disconnect(reason: String, retryMs: Long?)

    /** Live RECs still queued (the SYNCING N count). */
    fun pendingLive(): Int = 0

    /** The current ATT MTU (status only). */
    fun mtu(): Int = SyncConst.MTU_MIN
}

fun interface SyncCancel {
    fun cancel()
}

/** The node's clock and timer source. mono ms for timers; wall ms for clockMs / ts / updatedAt. */
interface SyncScheduler {
    fun now(): Long

    fun wallMs(): Long

    /** Run [task] at mono time [t] (or as soon as possible when [t] has passed), on the node's thread. */
    fun at(t: Long, task: () -> Unit): SyncCancel
}

/** Fixed per node (plan §5.1). [version] ≤ 16 UTF-8 bytes, [name] ≤ 20 (HELLO / HB). */
data class NodeConfig(
    val deviceId: Bytes,
    val kind: Int,
    val maxMsg: Int = if (kind == SyncConst.KIND_HUB) SyncConst.HUB_MAXMSG else SyncConst.PHONE_MAXMSG,
    val version: String? = null,
    val name: String? = null,
)

/**
 * This device's own HB fields (spec §9.1), read on the node thread each time an HB is built.
 * Battery values use -1 for unknown. [hubAirAgoS]: Android only; 0xFFFF = never heard.
 */
data class SelfStatus(
    val battPct: Int = -1,
    val battMv: Int = -1,
    val charging: Int = -1,
    val runtimeMin: Int = -1,
    val state: Int = 0,
    val hubAirAgoS: Int? = null,
    val uptimeS: Long = 0,
)

/**
 * HB on-change triggers (spec §9.2, plan D-P3-17). PRODUCTION: a session entering or leaving
 * AUTHED+ or SYNCED, [SyncNode.selfChanged] (battery / charging / state bits), and a durable write
 * after a page accept or a bulk change. TRANSCRIPT: only the last one, as the simulation that
 * produced the shared transcripts does.
 */
enum class NodePolicy { PRODUCTION, TRANSCRIPT }

/** Observation hooks (transcript replay, diagnostics). All no-ops by default. */
interface SyncTrace {
    fun state(linkId: String, to: SessionState) {}

    fun apply(linkId: String, key: String?, status: ApplyStatus, live: Boolean) {}

    fun group(linkId: String, groupId: Bytes, rekey: Boolean) {}

    fun foreign(linkId: String) {}

    fun disconnect(linkId: String, reason: String, retryMs: Long?) {}

    fun timer(linkId: String, name: SessionTimer) {}

    /** An Android-originated event left the coalescer: [route] 1 direct, 2 via the hub, 3 ring only. */
    fun heard(evt: Evt, route: Int) {}

    fun note(text: String) {}
}

/** Kind-specific behaviour of a node (the branches of gen_vectors.Node on `self.kind`). */
interface NodeRole {
    /** The iPhone tracks events (SessionConfig.tracksEvents). */
    val tracksEvents: Boolean get() = false

    fun bind(node: SyncNode) {}

    /** False while the hub has not learned the time (HELLO clockMs / HB ts read 0). */
    fun clockKnown(): Boolean = true

    fun onAuthed(s: SyncNode.Session) {}

    /** Add role fields to an HB being built (the iPhone's evtWm). */
    fun hbExtras(hb: Hb): Hb = hb

    /** Every delivered HB; [direct]: hops 0 from the session's own peer. */
    fun onHb(s: SyncNode.Session, hb: Hb, direct: Boolean) {}

    fun onEvt(s: SyncNode.Session, m: Evt) {}

    fun onEvtSince(s: SyncNode.Session, m: EvtSince, raw: Bytes) {}

    fun onEvtGap(s: SyncNode.Session, m: EvtGap, raw: Bytes) {}

    /** NodeRequest.EVT_SINCE (iPhone). */
    fun sendEvtSinceAll(s: SyncNode.Session) {}

    /** A session closed (link down). */
    fun onLinkDown(s: SyncNode.Session) {}
}

/** Lanes of [LinkPort.send]. */
object SyncLane {
    const val MAIN: Int = 0
    const val REPLAY: Int = 1
}

/**
 * Android's role (spec §3.9, §5.7; PROTOCOL §8.5, §16.3): routes this phone's heard-packet events
 * (1 direct to the iPhone, 2 via the hub when its fresh direct HB shows a synced iPhone link, 3 ring
 * only), answers catch-up requests (an EVT_SINCE for this origin, or an iPhone HB whose evtWm for
 * this origin is behind), and widens the coalescer window while a link carries > 20 EVT/s.
 * EVT / EVT_GAP / foreign EVT_SINCE reaching Android are counted and dropped.
 */
class AndroidRole(events: EventOriginPort?) : NodeRole {
    private lateinit var node: SyncNode

    /** This service start's event origin; null while "share heard packets" is off. */
    var events: EventOriginPort? = events
        private set

    /** (mono ms, links) of the hub's last DIRECT HB. */
    private var hubHb: Pair<Long, List<HbLink>>? = null

    /** EVT pacing: sends per link in the current 1 s bucket, and when the rate last stayed low. */
    private var bucketStart = Long.MIN_VALUE / 4
    private val bucket = HashMap<String, Int>()
    private var wide = false
    private var quietSince = Long.MIN_VALUE

    /** The event route's link has MTU < 64 (18-byte chunks): windows last 3 s (spec §3.2, §5.7). */
    private var mtuWide = false

    var evtSent = 0
        private set
    var evtRingOnly = 0
        private set
    var replaysSent = 0
        private set
    var gapsSent = 0
        private set
    var catchUpsSkipped = 0
        private set
    var dropped = 0
        private set

    override fun bind(node: SyncNode) {
        this.node = node
    }

    /** A service restart (tests): new bootId and a fresh origin (new epoch, empty ring). */
    fun serviceRestart(bootId: Int, events: EventOriginPort?) {
        node.bootId = bootId
        this.events = events
        applyWide()
    }

    /** "Share heard packets with iPhone" switched; null stops originating. */
    fun setEvents(events: EventOriginPort?) {
        this.events = events
        applyWide()
    }

    val isWide: Boolean get() = wide || mtuWide

    private fun applyWide() {
        events?.setWideWindow(wide || mtuWide)
    }

    /** Before a sighting opens a window: follow the current route's MTU. */
    private fun updateMtuWide() {
        val r = route()
        val mtu = if (r.route == 3) null else r.target?.let { node.sessionFor(it) }?.link?.mtu()
        val small = mtu != null && mtu < SyncConst.SMALL_MTU_BELOW
        if (small != mtuWide) {
            mtuWide = small
            applyWide()
        }
    }

    /** The current route for an event (§16.3). */
    fun route(): AndroidRoute {
        var ios: RouteSession? = null
        var hub: RouteSession? = null
        for (s in node.authedSessions()) {
            val id = s.peerId ?: continue
            when (s.peerKind) {
                SyncConst.KIND_IOS -> ios = RouteSession(id, s.peerSubs and SyncConst.SUB_EVENTS != 0, true)
                SyncConst.KIND_HUB -> hub = RouteSession(id, true, true)
            }
        }
        val hh = hubHb
        return SyncRouting.androidEventRoute(node.cfg.deviceId, ios, hub, hh?.let { node.sched.now() - it.first }, hh?.second ?: emptyList())
    }

    /** Age (ms) of the hub's last direct HB, or null. */
    fun hubHbAgeMs(): Long? = hubHb?.let { node.sched.now() - it.first }

    /** One event without coalescing (tests, transcript replay). */
    fun originate(packet: Bytes, rssi: Int?, count: Int, lat: Int?, lon: Int?, acc: Int?, addr: Bytes?, flags: Int): Evt? {
        val ev = events ?: return null
        val e = ev.originate(packet, node.wallOrZero(), rssi, count, lat, lon, acc, addr, flags)
        sendEvents(listOf(e))
        return e
    }

    /** A packet that passed handleHeard's filters. */
    fun onSighting(s: HeardSighting) {
        val ev = events ?: return
        updateMtuWide()
        sendEvents(ev.onSighting(s))
    }

    /** Close the coalescer windows that are due. */
    fun onEventsTick() {
        val ev = events ?: return
        sendEvents(ev.tick(node.sched.now()))
    }

    fun nextDueMs(): Long? = events?.nextDueMs()

    private fun sendEvents(list: List<Evt>) {
        for (e in list) {
            val r = route()
            node.trace.heard(e, r.route)
            if (r.route == 3) {
                evtRingOnly++
                continue
            }
            val s = node.sessionFor(r.target!!) ?: continue
            s.link.send(MsgType.EVT, e.copy(seenBy = r.seenBy).encode(), SyncLane.MAIN)
            s.counters.evtSent++
            evtSent++
            pace(s.id)
        }
    }

    /** > 20 EVT/s on a link widens new windows to 3 s; < 10/s for 5 s narrows them again. */
    private fun pace(linkId: String) {
        val now = node.sched.now()
        if (now - bucketStart >= 1000) {
            val peak = bucket.values.maxOrNull() ?: 0
            if (peak >= LOW_RATE && quietSince != Long.MIN_VALUE) quietSince = Long.MIN_VALUE
            if (peak < LOW_RATE && quietSince == Long.MIN_VALUE) quietSince = bucketStart
            bucket.clear()
            bucketStart = now
        }
        val n = (bucket[linkId] ?: 0) + 1
        bucket[linkId] = n
        if (n > HIGH_RATE && !wide) {
            wide = true
            quietSince = Long.MIN_VALUE
            applyWide()
        } else if (wide && quietSince != Long.MIN_VALUE && now - quietSince >= QUIET_MS) {
            wide = false
            applyWide()
        }
    }

    /** Periodic check so a quiet period narrows the window even when no EVT leaves. */
    fun paceTick() {
        val now = node.sched.now()
        if (!wide) return
        if (now - bucketStart >= 1000) {
            val peak = bucket.values.maxOrNull() ?: 0
            if (peak < LOW_RATE && quietSince == Long.MIN_VALUE) quietSince = bucketStart
            bucket.clear()
            bucketStart = now
        }
        if (quietSince != Long.MIN_VALUE && now - quietSince >= QUIET_MS) {
            wide = false
            applyWide()
        }
    }

    /** PROTOCOL §8.5: answer `(requester, epoch, afterSeq)` on the current route, in lane 1. */
    fun catchUp(requester: Bytes, epoch: Long, afterSeq: Long, why: String) {
        val ev = events ?: return
        val items = ev.catchUp(requester, epoch, afterSeq, node.sched.now())
        if (items == null) {
            catchUpsSkipped++
            node.trace.note("${node.cfg.deviceId} skips a repeated catch-up request ($why, epoch $epoch, after $afterSeq)")
            return
        }
        val r = route()
        if (r.route == 3) return
        val s = node.sessionFor(r.target!!) ?: return
        for (item in items) {
            when (item) {
                is CatchUpItem.Replay -> {
                    s.link.send(MsgType.EVT, item.evt.copy(seenBy = r.seenBy).encode(), SyncLane.REPLAY)
                    s.counters.evtReplayed++
                    replaysSent++
                }
                is CatchUpItem.Gap -> {
                    s.link.send(MsgType.EVT_GAP, item.gap.encode(), SyncLane.REPLAY)
                    s.counters.gapsSent++
                    gapsSent++
                }
            }
        }
    }

    override fun onHb(s: SyncNode.Session, hb: Hb, direct: Boolean) {
        if (direct && hb.kind == SyncConst.KIND_HUB) hubHb = node.sched.now() to hb.link
        if (hb.kind != SyncConst.KIND_IOS) return
        val ev = events ?: return
        for (w in hb.evtWm) {
            if (w.origin != node.cfg.deviceId) continue
            if (w.epoch < ev.epoch || (w.epoch == ev.epoch && w.seq < ev.seq)) catchUp(hb.deviceId, w.epoch, w.seq, "hb")
        }
    }

    override fun onEvtSince(s: SyncNode.Session, m: EvtSince, raw: Bytes) {
        if (m.origin == node.cfg.deviceId) catchUp(m.requester, m.epoch, m.afterSeq, "EVT_SINCE") else dropped++
    }

    override fun onEvt(s: SyncNode.Session, m: Evt) {
        dropped++
    }

    override fun onEvtGap(s: SyncNode.Session, m: EvtGap, raw: Bytes) {
        dropped++
    }

    companion object {
        const val HIGH_RATE: Int = 20
        const val LOW_RATE: Int = 10
        const val QUIET_MS: Long = 5000
    }
}
