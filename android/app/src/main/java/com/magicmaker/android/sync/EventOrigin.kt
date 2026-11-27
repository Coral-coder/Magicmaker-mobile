package com.magicmaker.android.sync

/**
 * Android's heard-packet event origin for one service start (spec §2.8, §5.7; PROTOCOL §8.5;
 * plan §4.8). Pure and single-threaded (mm-sync only).
 *
 * Coalescer, per packet: the first sighting with no open window emits at once (count 1) and opens
 * a window of [WINDOW_MS] ([WIDE_WINDOW_MS] while wide). Sightings inside it are counted; at its end
 * one event carries `count = n`, `rssi = max`, and the last ts / fix / address. At most
 * [MAX_WINDOWS] windows stay open (LRU; evicting one flushes it). Every emitted event takes the next
 * seq and is appended to the ring (capacity [ringCap]) before it is returned.
 */
class EventOrigin(
    override val origin: Bytes,
    override val epoch: Long,
    private val ringCap: Int = SyncConst.ANDROID_EVT_RING,
) : EventOriginPort {
    init {
        require(origin.size == 8 && !origin.isAllZero()) { "origin must be 8 bytes, not all zero" }
        require(epoch in 1..0xFFFF_FFFFL) { "epoch must be u32 >= 1" }
        require(ringCap >= 1) { "ringCap" }
    }

    private class Window(val packet: Bytes, val endMs: Long) {
        var n = 0
        var maxRssi: Int? = null
        var lastWallMs = 0L
        var lat: Int? = null
        var lon: Int? = null
        var acc: Int? = null
        var addr: Bytes? = null
        var tagged = false
    }

    /** Access-ordered: the eldest entry is the least recently sighted packet (LRU). */
    private val windows = LinkedHashMap<Bytes, Window>(64, 0.75f, true)
    private val ring = ArrayDeque<Evt>()
    private val served = HashMap<Triple<Bytes, Long, Long>, Long>()
    private var wide = false

    override var seq: Long = 0
        private set

    /** The ring's ids, oldest first (tests). */
    fun ringIds(): List<RingId> = ring.map { RingId(it.epoch, it.seq) }

    fun openWindows(): Int = windows.size

    override fun onSighting(s: HeardSighting): List<Evt> {
        val out = ArrayList<Evt>(1)
        val w = windows[s.packet]
        if (w != null && s.monoMs < w.endMs) {
            w.n++
            if (s.rssi != null) w.maxRssi = maxOf(w.maxRssi ?: s.rssi, s.rssi)
            w.lastWallMs = s.wallMs
            setFix(w, s)
            if (s.addr != null) w.addr = s.addr
            w.tagged = w.tagged || s.taggedOwnBand
            return out
        }
        if (w != null) {
            windows.remove(s.packet)
            flush(w)?.let { out.add(it) }
        }
        out.add(emit(s.packet, s.wallMs, s.rssi, 1, fix(s), s.addr, s.taggedOwnBand))
        windows[s.packet] = Window(s.packet, s.monoMs + if (wide) WIDE_WINDOW_MS else WINDOW_MS)
        while (windows.size > MAX_WINDOWS) {
            val eldest = windows.entries.iterator().next()
            windows.remove(eldest.key)
            flush(eldest.value)?.let { out.add(it) }
        }
        return out
    }

    override fun tick(monoMs: Long): List<Evt> {
        val due = windows.values.filter { it.endMs <= monoMs }.sortedBy { it.endMs }
        if (due.isEmpty()) return emptyList()
        val out = ArrayList<Evt>(due.size)
        for (w in due) {
            windows.remove(w.packet)
            flush(w)?.let { out.add(it) }
        }
        return out
    }

    override fun nextDueMs(): Long? = windows.values.minOfOrNull { it.endMs }

    override fun setWideWindow(wide: Boolean) {
        this.wide = wide
    }

    override fun originate(
        packet: Bytes,
        ts: Long,
        rssi: Int?,
        count: Int,
        lat: Int?,
        lon: Int?,
        accM: Int?,
        addr: Bytes?,
        flags: Int,
    ): Evt {
        val f = if (lat != null && lon != null && accM != null) Triple(lat, lon, accM) else null
        return emit(packet, ts, rssi, count, f, addr, flags and SyncConst.EVT_FLAG_TAGGED != 0, flags)
    }

    override fun catchUp(requester: Bytes, epoch: Long, afterSeq: Long, monoMs: Long): List<CatchUpItem>? {
        served.entries.removeAll { monoMs - it.value >= SyncConst.EVT_REPLAY_DEDUPE_MS }
        val k = Triple(requester, epoch, afterSeq)
        val last = served[k]
        if (last != null && monoMs - last < SyncConst.EVT_REPLAY_DEDUPE_MS) return null
        served[k] = monoMs
        val byId = ring.associateBy { RingId(it.epoch, it.seq) }
        return SyncEvents.replayPlan(ringIds(), this.epoch, seq, epoch, afterSeq).map { item ->
            when (item) {
                is ReplayItem.Replay -> {
                    val e = byId.getValue(RingId(item.epoch, item.seq))
                    CatchUpItem.Replay(e.copy(flags = e.flagsOrDefault or SyncConst.EVT_FLAG_REPLAY, seenBy = emptyList()))
                }
                is ReplayItem.Gap -> CatchUpItem.Gap(EvtGap(origin, item.epoch, item.firstAvail, item.lastAvail, item.curEpoch, requester))
            }
        }
    }

    private fun setFix(w: Window, s: HeardSighting) {
        val f = fix(s) ?: return
        w.lat = f.first
        w.lon = f.second
        w.acc = f.third
    }

    private fun fix(s: HeardSighting): Triple<Int, Int, Int>? =
        if (s.lat != null && s.lon != null && s.accM != null) Triple(s.lat, s.lon, s.accM) else null

    private fun flush(w: Window): Evt? {
        if (w.n < 1) return null
        val f = if (w.lat != null) Triple(w.lat!!, w.lon!!, w.acc!!) else null
        return emit(w.packet, w.lastWallMs, w.maxRssi, w.n, f, w.addr, w.tagged)
    }

    private fun emit(
        packet: Bytes,
        ts: Long,
        rssi: Int?,
        count: Int,
        f: Triple<Int, Int, Int>?,
        addr: Bytes?,
        tagged: Boolean,
        rawFlags: Int? = null,
    ): Evt {
        seq++
        val flags = (rawFlags ?: 0) or (if (tagged) SyncConst.EVT_FLAG_TAGGED else 0)
        val e = Evt(
            origin = origin,
            epoch = epoch,
            seq = seq,
            ts = maxOf(0L, ts),
            packet = packet,
            rssi = rssi?.coerceIn(-128, 127),
            count = count.coerceIn(1, 0xFFFF),
            lat = f?.first?.coerceIn(-900_000_000, 900_000_000),
            lon = f?.second?.coerceIn(-1_800_000_000, 1_800_000_000),
            acc = f?.third?.coerceIn(0, 0xFFFF),
            addr = addr?.takeIf { it.size == 6 },
            flags = flags.takeIf { it != 0 },
        )
        ring.addLast(e)
        while (ring.size > ringCap) ring.removeFirst()
        return e
    }

    companion object {
        const val WINDOW_MS: Long = 1_000
        const val WIDE_WINDOW_MS: Long = 3_000
        const val MAX_WINDOWS: Int = 256

        /** `"AA:BB:CC:DD:EE:FF"` -> 6 bytes, or null. */
        fun addrBytes(address: String?): Bytes? {
            val h = address?.replace(":", "")?.replace("-", "")?.trim() ?: return null
            if (h.length != 12) return null
            return runCatching { Bytes.fromHex(h) }.getOrNull()
        }

        /** Degrees -> 1e-7 degree units (the EVT fix), or null when not finite. */
        fun e7(deg: Double): Int? = if (deg.isFinite()) Math.round(deg * 1e7).toInt() else null
    }
}
