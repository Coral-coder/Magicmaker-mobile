package com.magicmaker.android.sync

// The iPhone's and the hub's node behaviour (gen_vectors.Node's KIND_IOS / KIND_HUB branches) as
// NodeRoles, so the transcript replay and the loopback tests can run them as SyncNode peers of the
// Android engine. Test sources only: P2 (firmware) and P4 (iPhone) carry their own.

/** gen_vectors.Node with kind 3: tracks events, dedupes, asks for holes, puts evtWm in its HB. */
internal class IosStandInRole(private val onIngest: ((linkId: String, m: Evt, r: EvtReceive) -> Unit)? = null) : NodeRole {
    private lateinit var node: SyncNode
    val dedupe = EvtDedupe()
    private val sinceSent = HashMap<Pair<Bytes, Long>, Long>()
    var onGap: ((linkId: String, m: EvtGap, r: EvtGapResult) -> Unit)? = null

    /** Every accepted event id, in order (loopback assertions). */
    val accepted = ArrayList<Triple<Bytes, Long, Long>>()

    override val tracksEvents: Boolean get() = true

    override fun bind(node: SyncNode) {
        this.node = node
    }

    override fun hbExtras(hb: Hb): Hb {
        val wms = dedupe.origins().mapNotNull { o -> dedupe.newest(o)?.let { EvtWm(o, it.epoch, it.hc) } }
        return if (wms.isEmpty()) hb else hb.copy(evtWm = wms.take(SyncConst.HB_EVTWM_MAX))
    }

    override fun onEvt(s: SyncNode.Session, m: Evt) {
        val r = dedupe.receive(m.origin, m.epoch, m.seq)
        onIngest?.invoke(s.id, m, r)
        if (r.result == EvtResult.ACCEPT) accepted.add(Triple(m.origin, m.epoch, m.seq))
        if (r.result == EvtResult.ACCEPT && dedupe.hasHoles(m.origin, m.epoch)) {
            val w = dedupe.window(m.origin, m.epoch)!!
            sendSince(s, m.origin, m.epoch, w.hc)
        }
    }

    private fun sendSince(s: SyncNode.Session, origin: Bytes, epoch: Long, after: Long) {
        val key = origin to epoch
        if (sinceSent[key] == after) return
        sinceSent[key] = after
        s.link.send(MsgType.EVT_SINCE, EvtSince(origin, epoch, after, node.cfg.deviceId).encode(), SyncLane.MAIN)
    }

    override fun sendEvtSinceAll(s: SyncNode.Session) {
        for (o in dedupe.origins().toList()) {
            val w = dedupe.newest(o) ?: continue
            sinceSent.remove(o to w.epoch)
            sendSince(s, o, w.epoch, w.hc)
        }
    }

    override fun onEvtGap(s: SyncNode.Session, m: EvtGap, raw: Bytes) {
        val r = dedupe.onGap(m.origin, m.epoch, m.firstAvail, m.lastAvail, m.curEpoch)
        onGap?.invoke(s.id, m, r)
        for ((e, q) in r.requests) sendSince(s, m.origin, e, q)
    }
}

/** gen_vectors.Node with kind 1: learns the time from a peer, relays EVT / EVT_SINCE / EVT_GAP. */
internal class HubStandInRole(var known: Boolean) : NodeRole {
    private lateinit var node: SyncNode

    override fun bind(node: SyncNode) {
        this.node = node
    }

    override fun clockKnown(): Boolean = known

    override fun onAuthed(s: SyncNode.Session) {
        val p = s.core.peer ?: return
        if (p.clockMs > 0 && !known) {
            known = true
            node.trace.note("hub learns the time from ${s.id}'s HELLO clockMs")
        }
    }

    override fun onHb(s: SyncNode.Session, hb: Hb, direct: Boolean) {
        if (direct && hb.kind != SyncConst.KIND_HUB && hb.ts > 0 && !known) known = true
    }

    override fun onEvt(s: SyncNode.Session, m: Evt) {
        val peer = s.peerId ?: return
        val sess = node.authedSessions().map { RouteSession(it.peerId!!, it.peerSubs and SyncConst.SUB_EVENTS != 0, true) }
        val r = SyncRouting.routeEvtRelay(node.cfg.deviceId, peer, m.origin, m.seenBy, sess)
        if (r.targets.isEmpty()) return
        val b = m.copy(seenBy = r.seenBy).encode()
        for (tgt in r.targets) node.sessionFor(tgt)?.link?.send(MsgType.EVT, b, SyncLane.MAIN)
    }

    override fun onEvtSince(s: SyncNode.Session, m: EvtSince, raw: Bytes) {
        val t = node.sessionFor(m.origin) ?: return
        if (t.id != s.id) t.link.send(MsgType.EVT_SINCE, raw, SyncLane.MAIN)
    }

    override fun onEvtGap(s: SyncNode.Session, m: EvtGap, raw: Bytes) {
        val t = node.sessionFor(m.requester) ?: return
        if (t.id != s.id) t.link.send(MsgType.EVT_GAP, raw, SyncLane.MAIN)
    }
}
