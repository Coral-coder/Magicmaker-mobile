package com.magicmaker.android.sync

/** A served page: the REC messages in order, their feed seqs, and the closing PAGE_END (§15.2). */
class PageResult(val recs: List<Bytes>, val recSeqs: List<Long>, val pageEnd: PageEnd)

/** Routing inputs: one session as a router sees it. [subscribed]: the peer's subs bit for this
 *  kind of traffic; [up]: AUTHED+ (or "member" for the hub's tables). */
data class RouteSession(val peer: Bytes, val subscribed: Boolean, val up: Boolean)

/** Live push targets and the seenBy list to send with them (§16.2, §16.3). */
data class Route(val targets: List<Bytes>, val seenBy: List<Bytes>)

/** Android's per-event route (§16.3): 1 direct to the iPhone, 2 via the hub, 3 ring only. */
data class AndroidRoute(val route: Int, val target: Bytes?, val seenBy: List<Bytes>)

/** The HB replacement key (§16.4). */
data class HbVersion(val bootId: Int, val hbSeq: Long)

object SyncRouting {
    /**
     * Serve a PULL durable-only (§15.2). [entries]: the server's CURRENT entries (one per key);
     * [excludeActive] = `pull.exclude == 1 && excludeOk[puller]`.
     */
    fun servePage(
        entries: Iterable<FeedEntry>,
        durableHigh: Long,
        since: Long,
        limit: Int,
        maxBytes: Int,
        excludeActive: Boolean,
        puller: Bytes,
        reqId: Int,
    ): PageResult {
        val recs = ArrayList<Bytes>()
        val seqs = ArrayList<Long>()
        var used = 0
        var scanned = since
        if (since < durableHigh) {
            for (e in entries.filter { since < it.seq && it.seq <= durableHigh }.sortedBy { it.seq }) {
                if (excludeActive && (e.origin == puller || e.syncFrom == puller)) {
                    scanned = e.seq
                    continue
                }
                val msg = Rec(e.seq, reqId, emptyList(), e.bodyBytes).encode()
                if (recs.size >= limit) break
                if (recs.isNotEmpty() && used + msg.size > maxBytes) break
                recs.add(msg)
                seqs.add(e.seq)
                used += msg.size
                scanned = e.seq
            }
        }
        val more = if (scanned < durableHigh) 1 else 0
        return PageResult(recs, seqs, PageEnd(reqId, scanned, more, durableHigh, recs.size))
    }

    /** [servePage] for a decoded PULL; exclusion iff `pull.exclude == 1 && excludeOk`. */
    fun servePage(entries: Iterable<FeedEntry>, durableHigh: Long, pull: Pull, excludeOk: Boolean, puller: Bytes): PageResult =
        servePage(entries, durableHigh, pull.since, pull.limitOrDefault, pull.maxBytesOrDefault,
            pull.excludeOrDefault == 1 && excludeOk, puller, pull.reqId)

    /** seenBy merge: the existing list in order, then new ids not yet present, first 4 kept. */
    fun mergeSeen(base: List<Bytes>, extra: List<Bytes>): List<Bytes> {
        val out = ArrayList<Bytes>()
        for (x in base + extra) if (x !in out) out.add(x)
        return if (out.size > SyncConst.SEENBY_MAX) out.subList(0, SyncConst.SEENBY_MAX).toList() else out
    }

    /** Local change push (§16.2): every AUTHED+ records-subscribed session; seenBy = [self] + targets. */
    fun routeLocalRec(self: Bytes, sessions: List<RouteSession>): Route {
        val targets = sessions.filter { it.up && it.subscribed }.map { it.peer }
        return Route(targets, mergeSeen(emptyList(), listOf(self) + targets))
    }

    /** First accept of a live REC from [sender] (§16.2). [origin] null / zero = PRESENCE. */
    fun routeLiveRec(self: Bytes, sender: Bytes, origin: Bytes?, seenBy: List<Bytes>, sessions: List<RouteSession>): Route {
        val excl = HashSet<Bytes>(seenBy)
        excl.add(sender)
        if (origin != null && !origin.isAllZero()) excl.add(origin)
        val targets = sessions.filter { it.up && it.subscribed && it.peer !in excl && it.peer != self }.map { it.peer }
        if (targets.isEmpty()) return Route(emptyList(), seenBy.toList())
        return Route(targets, mergeSeen(seenBy, listOf(self) + targets))
    }

    /** Hub relay of an EVT from [sender] (§16.3). */
    fun routeEvtRelay(self: Bytes, sender: Bytes, origin: Bytes, seenBy: List<Bytes>, sessions: List<RouteSession>): Route {
        val excl = HashSet<Bytes>(seenBy)
        excl.add(sender)
        excl.add(origin)
        val targets = sessions.filter { it.up && it.subscribed && it.peer !in excl && it.peer != self }.map { it.peer }
        if (targets.isEmpty()) return Route(emptyList(), seenBy.toList())
        return Route(targets, mergeSeen(seenBy, listOf(self) + targets))
    }

    /**
     * Android's route for an event / replay / EVT_GAP (§16.3). [ios]: the A–I session (up =
     * AUTHED+, subscribed = the iPhone's events bit) or null; [hub]: the A–H session or null;
     * [hubHbAgeMs] / [hubHbLinks]: the hub's latest DIRECT HB (null age = none yet).
     */
    fun androidEventRoute(self: Bytes, ios: RouteSession?, hub: RouteSession?, hubHbAgeMs: Long?, hubHbLinks: List<HbLink>): AndroidRoute {
        if (ios != null && ios.up && ios.subscribed) return AndroidRoute(1, ios.peer, listOf(self, ios.peer))
        if (hub != null && hub.up && hubHbAgeMs != null && hubHbAgeMs <= SyncConst.T_PATH_FRESH_MS) {
            if (hubHbLinks.any { it.peerKind == SyncConst.KIND_IOS && it.flags and SyncConst.HB_LINK_SYNCED != 0 }) {
                return AndroidRoute(2, hub.peer, listOf(self, hub.peer))
            }
        }
        return AndroidRoute(3, null, emptyList())
    }

    /** HB forwarding (§16.4): only hops-0 HBs, once, to sessions whose peer is neither the sender nor the described device. */
    fun routeHb(self: Bytes, sender: Bytes, described: Bytes, hops: Int, sessions: List<RouteSession>): List<Bytes> {
        if (hops != 0) return emptyList()
        return sessions.filter { it.up && it.subscribed && it.peer != sender && it.peer != described && it.peer != self }
            .map { it.peer }
    }

    /** Keep-latest rule (§16.4): replace iff nothing stored, bootId differs, or hbSeq is greater. */
    fun hbReplaces(stored: HbVersion?, incoming: HbVersion): Boolean {
        if (stored == null) return true
        if (incoming.bootId != stored.bootId) return true
        return incoming.hbSeq > stored.hbSeq
    }

    /** The subs a node of [selfKind] sends in HELLO / SUB (§16.1); [peerKind] is not used in v1. */
    @Suppress("UNUSED_PARAMETER")
    fun subsFor(selfKind: Int, peerKind: Int): Int = when (selfKind) {
        SyncConst.KIND_HUB, SyncConst.KIND_IOS -> SyncConst.SUB_RECORDS or SyncConst.SUB_EVENTS or SyncConst.SUB_HEARTBEATS
        SyncConst.KIND_ANDROID -> SyncConst.SUB_RECORDS or SyncConst.SUB_HEARTBEATS
        else -> throw IllegalArgumentException("kind $selfKind")
    }
}
