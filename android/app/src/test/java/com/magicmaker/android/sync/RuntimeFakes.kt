package com.magicmaker.android.sync

import java.util.PriorityQueue

// Part 2 (runtime) test support: docs/SYNC_P3_ANDROID_PLAN.md §10.2. Fakes of the SyncPorts seam,
// so the engine is tested without part 1's classes (TestPorts.real() swaps those in), and the
// virtual scheduler that mirrors gen_vectors.Sim's (t, n) heap.

/** A min-heap of tasks keyed (t, n), like gen_vectors.Sim: equal times run in push order. */
internal class VirtualScheduler(var base: Long = 0) : SyncScheduler {
    private class Item(val t: Long, val n: Long, val task: () -> Unit, val site: String?) {
        var cancelled = false
    }

    /** Fail instead of spinning: at most this many tasks per [run]. */
    var budget: Long = 20_000_000
    var traceSites = false

    private val q = PriorityQueue<Item>(compareBy<Item>({ it.t }, { it.n }))
    private var n = 0L
    var t: Long = 0
        private set

    override fun now(): Long = t

    override fun wallMs(): Long = base + t

    override fun at(t: Long, task: () -> Unit): SyncCancel {
        val site = if (traceSites) Throwable().stackTrace.drop(1).take(4).joinToString(" < ") { "${it.fileName}:${it.lineNumber}" } else null
        val it = Item(t, n++, task, site)
        q.add(it)
        return SyncCancel { it.cancelled = true }
    }

    fun pending(): Int = q.count { !it.cancelled }

    /** Run every task due at or before [until], then set the clock to [until]. */
    fun run(until: Long) {
        var ran = 0L
        val recent = ArrayDeque<String>()
        while (true) {
            val head = q.peek() ?: break
            if (head.t > until) break
            q.poll()
            if (++ran > budget) {
                val hist = recent.groupingBy { it }.eachCount().entries.sortedByDescending { it.value }.take(8)
                throw IllegalStateException("virtual scheduler spinning at t=$t (${q.size} queued): $hist")
            }
            if (traceSites && head.site != null) {
                recent.addLast(head.site)
                if (recent.size > 10_000) recent.removeFirst()
            }
            if (head.t > t) t = head.t
            if (!head.cancelled) head.task()
        }
        if (until > t) t = until
    }
}

/** In-memory [SyncIdentityPort]; [db] is settable for the hub stand-in's library reset. */
internal class FakeIdentity(override val deviceId: Bytes, var db: Bytes, group: SyncGroup? = null) : SyncIdentityPort {
    private var groupValue: SyncGroup? = group
    private var hubValue: String? = null
    var issued = 0L
    val foreign = LinkedHashSet<String>()
    var groupWrites = 0

    override val dbId: Bytes get() = db
    override val group: SyncGroup? get() = groupValue
    override val hubAddress: String? get() = hubValue

    override fun setGroup(group: SyncGroup?) {
        groupValue = group
        groupWrites++
    }

    override fun ensureIssued(seq: Long) {
        if (seq > issued) issued = seq
    }

    override fun setHubAddress(address: String?) {
        hubValue = address
    }

    override fun isForeign(address: String): Boolean = address.uppercase() in foreign

    override fun markForeign(address: String) {
        foreign.add(address.uppercase())
    }
}

/** [DeviceRosterPort] with the §16.4 keep-latest rule. */
internal class FakeRoster : DeviceRosterPort {
    private val map = LinkedHashMap<Bytes, RosterEntry>()

    override fun onHb(hb: Hb, fromPeer: Bytes, monoMs: Long): Boolean {
        val old = map[hb.deviceId]
        val replaced = SyncRouting.hbReplaces(old?.let { HbVersion(it.hb.bootId, it.hb.hbSeq) }, HbVersion(hb.bootId, hb.hbSeq))
        val direct = hb.hops == 0 && hb.deviceId == fromPeer
        val via = LinkedHashMap(old?.lastViaMs ?: emptyMap())
        if (!direct) via[fromPeer] = monoMs
        map[hb.deviceId] = RosterEntry(
            if (replaced || old == null) hb else old.hb,
            monoMs,
            if (direct) monoMs else old?.lastDirectMs,
            via,
        )
        return replaced
    }

    override fun get(deviceId: Bytes): RosterEntry? = map[deviceId]

    override fun entries(): List<RosterEntry> = map.values.toList()

    override fun forget(deviceId: Bytes) {
        map.remove(deviceId)
    }
}

/** A plain event origin: no coalescing (every sighting is one event), a ring and the §8.5 catch-up. */
internal class FakeEventOrigin(override val origin: Bytes, override val epoch: Long, private val ringCap: Int) : EventOriginPort {
    private val ring = ArrayDeque<Evt>()
    private val served = HashMap<Triple<Bytes, Long, Long>, Long>()
    var wide = false

    override var seq: Long = 0
        private set

    fun ringIds(): List<RingId> = ring.map { RingId(it.epoch, it.seq) }

    override fun onSighting(s: HeardSighting): List<Evt> {
        val fix = s.lat != null && s.lon != null && s.accM != null
        return listOf(
            originate(s.packet, s.wallMs, s.rssi, 1, if (fix) s.lat else null, if (fix) s.lon else null, if (fix) s.accM else null, s.addr,
                if (s.taggedOwnBand) SyncConst.EVT_FLAG_TAGGED else 0),
        )
    }

    override fun tick(monoMs: Long): List<Evt> = emptyList()

    override fun nextDueMs(): Long? = null

    override fun setWideWindow(wide: Boolean) {
        this.wide = wide
    }

    override fun originate(packet: Bytes, ts: Long, rssi: Int?, count: Int, lat: Int?, lon: Int?, accM: Int?, addr: Bytes?, flags: Int): Evt {
        seq++
        val e = Evt(origin, epoch, seq, ts, packet, rssi, count.takeIf { it != 1 }, lat, lon, accM, addr, flags.takeIf { it != 0 })
        ring.addLast(e)
        while (ring.size > ringCap) ring.removeFirst()
        return e
    }

    override fun catchUp(requester: Bytes, epoch: Long, afterSeq: Long, monoMs: Long): List<CatchUpItem>? {
        val k = Triple(requester, epoch, afterSeq)
        val last = served[k]
        if (last != null && monoMs - last < SyncConst.EVT_REPLAY_DEDUPE_MS) return null
        served[k] = monoMs
        val byId = ring.associateBy { RingId(it.epoch, it.seq) }
        return SyncEvents.replayPlan(ringIds(), this.epoch, seq, epoch, afterSeq).map { item ->
            when (item) {
                is ReplayItem.Replay -> byId.getValue(RingId(item.epoch, item.seq)).let {
                    CatchUpItem.Replay(it.copy(flags = it.flagsOrDefault or SyncConst.EVT_FLAG_REPLAY, seenBy = emptyList()))
                }
                is ReplayItem.Gap -> CatchUpItem.Gap(EvtGap(origin, item.epoch, item.firstAvail, item.lastAvail, item.curEpoch, requester))
            }
        }
    }
}

/**
 * A node's ledger and saves, as gen_vectors.Node keeps them: any ACCEPT marks the store dirty
 * (phones save 300 ms later, the hub 2,000 ms); a phone's page commit saves at once, the hub's
 * marks dirty when something is unsaved. A save sets durableHigh = nextSyncSeq - 1 and calls
 * onDurable. Listeners are called inline.
 */
internal class FakeLibraryPort(
    val kind: Int,
    private val sched: SyncScheduler,
    var ledger: Ledger,
    durableHigh: Long,
    peers: Map<Bytes, PeerState> = emptyMap(),
    private val onDurableLog: ((Long) -> Unit)? = null,
) : SyncLibraryPort {
    private var durable = durableHigh
    private var savePending = false
    private val peerTable = LinkedHashMap<Bytes, StoredPeer>()
    private var listener: SyncLibraryListener? = null
    var rejected = 0
    var saves = 0

    init {
        for ((k, v) in peers) peerTable[k] = StoredPeer(PeerState(v.dbId, v.wm, v.excludeOk), 0)
    }

    override fun durableHigh(): Long = durable

    override fun recordCount(): Int = ledger.size

    override fun stats(): LibrarySyncStats =
        LibrarySyncStats(ledger.size, ledger.tombstoneCount(), ledger.nextSyncSeq, durable, 0, rejected)

    override fun loadPeers(): Map<Bytes, StoredPeer> =
        peerTable.mapValues { StoredPeer(PeerState(it.value.state.dbId, it.value.state.wm, it.value.state.excludeOk), it.value.lastSyncMs) }

    override fun putPeer(peerId: Bytes, state: PeerState, lastSyncMs: Long?) {
        peerTable[peerId] = StoredPeer(PeerState(state.dbId, state.wm, state.excludeOk), lastSyncMs ?: peerTable[peerId]?.lastSyncMs ?: 0)
    }

    override fun servePage(pull: Pull, excludeOk: Boolean, puller: Bytes): PageResult =
        SyncRouting.servePage(ledger.entriesBySeq(), durable, pull, excludeOk, puller)

    override fun applyRemote(body: Bytes, sender: Bytes, nowMs: Long?, live: Boolean): ApplyResult {
        val r = ledger.applyRemote(body, sender, nowMs)
        if (r.status == ApplyStatus.ACCEPT) markDirty()
        if (r.status == ApplyStatus.BAD_MSG || r.status == ApplyStatus.CLOCK) rejected++
        return r
    }

    override fun commitPage(peerId: Bytes, state: PeerState, lastSyncMs: Long) {
        putPeer(peerId, state, lastSyncMs)
        if (kind == SyncConst.KIND_HUB) {
            if (ledger.nextSyncSeq - 1 > durable) markDirty()
        } else {
            saveNow()
        }
    }

    override fun requestSave() = markDirty()

    override fun setListener(listener: SyncLibraryListener?) {
        this.listener = listener
    }

    fun markDirty() {
        if (savePending) return
        savePending = true
        val delay = if (kind == SyncConst.KIND_HUB) HUB_FLUSH_MS else PHONE_SAVE_DEBOUNCE_MS
        sched.at(sched.now() + delay) { saveNow() }
    }

    fun saveNow() {
        savePending = false
        saves++
        val high = ledger.nextSyncSeq - 1
        if (high != durable) {
            durable = high
            onDurableLog?.invoke(high)
        }
        listener?.onDurable(durable)
    }

    /** A local edit as gen_vectors.Node.local_edit: stamp, store, mark dirty, push. */
    fun localEdit(
        cls: RecordClass,
        key: RecordKey,
        self: Bytes,
        label: String? = null,
        category: Int? = null,
        kind: String? = null,
        place: Int? = null,
        note: String? = null,
        preset: Boolean = false,
        userEdited: Boolean = true,
        before: ((EditResult) -> Unit)? = null,
    ): EditResult {
        val r = ledger.localEdit(cls, key, sched.wallMs(), self, label, category, kind, place, note, preset, userEdited)
        before?.invoke(r)
        markDirty()
        r.entry?.let { listener?.onLocalChanges(listOf(it), false) }
        return r
    }

    /** A learn (gen_vectors.Node.local_learn): PRESENCE iff the key has no entry. */
    fun localLearn(packet: Bytes, before: ((LedgerEntry?) -> Unit)? = null): LedgerEntry? {
        val e = ledger.localLearn(packet)
        before?.invoke(e)
        if (e != null) {
            markDirty()
            listener?.onLocalChanges(listOf(e), false)
        }
        return e
    }

    /** The hub stand-in's sync_reset: an empty library. */
    fun reset() {
        ledger = Ledger(ledger.tombstoneCap)
        durable = 0
        peerTable.clear()
    }

    companion object {
        const val PHONE_SAVE_DEBOUNCE_MS: Long = 300
        const val HUB_FLUSH_MS: Long = 2000
    }
}

/** gen_vectors.Node.gen_nonce: sha256("mm-sync-nonce:" + deviceId + n LE32)[:8], one counter per node. */
internal class DetNonces(private val deviceId: Bytes) {
    private var n = 0L

    fun next(): Bytes {
        val prefix = Bytes.of(*"mm-sync-nonce:".map { it.code }.toIntArray())
        val nb = Bytes.le(n, 4, false)
        n++
        return SyncCrypto.sha256(prefix + deviceId + nb).slice(0, 8)
    }
}

/**
 * Two GATT ends joined in memory (plan §10.2): a seeded latency of 5–40 ms per ATT value with
 * in-order delivery, onFrameSent 1–10 ms after each write, exactly one frame in flight per end
 * (a second write fails the test), the ATT value bound (mtu − 3), and optional frame drops.
 */
internal class LoopbackGatt(
    private val sched: SyncScheduler,
    private val rng: java.util.Random,
    private val mtuValue: Int,
    idA: String,
    idB: String,
    /** Drop one frame in this many (0 = never). */
    private val dropOneIn: Int = 0,
    private val onClosed: (reason: String) -> Unit,
) {
    var closed = false
        private set
    var drops = 0
        private set
    var frames = 0
        private set

    inner class End(override val id: String, override val role: SessionRole) : FrameLink {
        lateinit var channel: LinkChannel
        lateinit var other: End
        private var nextDeliver = 0L
        private var inFlight = false

        override fun mtu(): Int = mtuValue

        override fun writeFrame(frame: ByteArray): Boolean {
            if (closed) return false
            check(!inFlight) { "$id: a second frame while one is in flight" }
            check(frame.size <= mtuValue - SyncConst.ATT_OVERHEAD) { "$id: ATT value ${frame.size} > mtu ${mtuValue} - 3" }
            inFlight = true
            frames++
            val t = maxOf(sched.now() + 5 + rng.nextInt(36), nextDeliver)
            nextDeliver = t
            val drop = dropOneIn > 0 && rng.nextInt(dropOneIn) == 0
            if (drop) drops++
            val copy = frame.copyOf()
            if (!drop) sched.at(t) { if (!closed) other.channel.onFrame(copy) }
            sched.at(sched.now() + 1 + rng.nextInt(10)) {
                inFlight = false
                if (!closed) channel.onFrameSent()
            }
            return true
        }

        override fun close(reason: String) = closeLink(reason)
    }

    val a = End(idA, SessionRole.CENTRAL)
    val b = End(idB, SessionRole.PERIPHERAL)

    init {
        a.other = b
        b.other = a
    }

    /** One end closed the link: both sides see link-down 5 ms later. */
    fun closeLink(reason: String) {
        if (closed) return
        closed = true
        sched.at(sched.now() + 5) { onClosed(reason) }
    }

    /** The radio link is gone (out of range): no flush. */
    fun cut() {
        closed = true
    }
}
