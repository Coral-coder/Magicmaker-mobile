package com.magicmaker.android.sync

/**
 * One dedupe window (§8.2): [hc] = highest contiguous seq received; bit i of the 64-bit [bits]
 * means seq `hc + 1 + i` was received.
 */
class EvtWindow(val epoch: Long, hc: Long = 0, bits: Long = 0) {
    var hc: Long = hc
        private set
    var bits: Long = bits
        private set

    internal fun normalize() {
        while (bits and 1L != 0L) {
            hc += 1
            bits = bits ushr 1
        }
    }

    /** Move hc up to [floor]; returns how many seqs in (hc, floor] were never received. */
    fun advanceFloor(floor: Long): Long {
        if (floor <= hc) return 0
        val shift = floor - hc
        val got: Int
        if (shift >= SyncConst.EVT_WINDOW_BITS) {
            got = java.lang.Long.bitCount(bits)
            bits = 0
        } else {
            got = java.lang.Long.bitCount(bits and ((1L shl shift.toInt()) - 1))
            bits = bits ushr shift.toInt()
        }
        hc = floor
        normalize()
        return shift - got
    }

    internal fun mark(idx: Int): Boolean {
        val m = 1L shl idx
        if (bits and m != 0L) return false
        bits = bits or m
        normalize()
        return true
    }

    /** The bitmap as 16 uppercase hex digits (vector form). */
    fun bitsHex(): String = "%016X".format(bits)

    override fun toString(): String = "EvtWindow(epoch=$epoch, hc=$hc, bits=${bitsHex()})"
}

enum class EvtResult { ACCEPT, DUPLICATE }

/** [lost]: seqs passed over without being received (window slide). */
data class EvtReceive(val result: EvtResult, val lost: Long)

/** EVT_GAP outcome: [requests] are the `(epoch, afterSeq)` EVT_SINCEs to send. */
data class EvtGapResult(val lost: Long, val requests: List<Pair<Long, Long>>)

/**
 * The iPhone's receiver state per origin (§8.2-§8.4): the windows of the two newest epochs,
 * oldest first.
 */
class EvtDedupe {
    private val byOrigin = LinkedHashMap<Bytes, MutableList<EvtWindow>>()

    fun origins(): Set<Bytes> = byOrigin.keys

    /** That origin's windows, oldest first. */
    fun windows(origin: Bytes): List<EvtWindow> = byOrigin[origin] ?: emptyList()

    fun window(origin: Bytes, epoch: Long): EvtWindow? = byOrigin[origin]?.firstOrNull { it.epoch == epoch }

    fun newest(origin: Bytes): EvtWindow? = byOrigin[origin]?.lastOrNull()

    /** Restore a stored window (P4). */
    fun restore(origin: Bytes, w: EvtWindow) {
        open(origin, w)
    }

    private fun open(origin: Bytes, w: EvtWindow): EvtWindow {
        val ws = byOrigin.getOrPut(origin) { ArrayList() }
        ws.add(w)
        ws.sortBy { it.epoch }
        while (ws.size > SyncConst.EVT_EPOCHS_KEPT) ws.removeAt(0)
        return w
    }

    fun receive(origin: Bytes, epoch: Long, seq: Long): EvtReceive {
        val ws = byOrigin[origin]
        var w = window(origin, epoch)
        if (w == null) {
            w = when {
                ws.isNullOrEmpty() -> open(origin, EvtWindow(epoch, seq - 1))   // first contact: no history
                epoch > ws.last().epoch -> open(origin, EvtWindow(epoch, 0))     // new epoch: from seq 1
                else -> return EvtReceive(EvtResult.DUPLICATE, 0)                // older than the kept epochs
            }
        }
        if (seq <= w.hc) return EvtReceive(EvtResult.DUPLICATE, 0)
        var lost = 0L
        if (seq > w.hc + SyncConst.EVT_WINDOW_BITS) lost = w.advanceFloor(seq - SyncConst.EVT_WINDOW_BITS)
        val idx = (seq - w.hc - 1).toInt()
        return if (w.mark(idx)) EvtReceive(EvtResult.ACCEPT, lost) else EvtReceive(EvtResult.DUPLICATE, lost)
    }

    /** After an ACCEPT, bits != 0 means a seq jump: ask for the holes (§8.3). */
    fun hasHoles(origin: Bytes, epoch: Long): Boolean = window(origin, epoch)?.let { it.bits != 0L } ?: false

    /** EVT_GAP handling (§8.4). */
    fun onGap(origin: Bytes, epoch: Long, firstAvail: Long, lastAvail: Long, curEpoch: Long): EvtGapResult {
        val reqs = ArrayList<Pair<Long, Long>>()
        var lost = 0L
        val w = window(origin, epoch)
        if (firstAvail > 0) {
            if (w != null && firstAvail > w.hc + 1) {
                lost = w.advanceFloor(firstAvail - 1)
                reqs.add(epoch to w.hc)
            }
        } else if (curEpoch > epoch) {
            var wc = window(origin, curEpoch)
            if (wc == null) {
                val newest = newest(origin)
                if (newest == null || curEpoch > newest.epoch) wc = open(origin, EvtWindow(curEpoch, 0))
            }
            if (wc != null) reqs.add(curEpoch to wc.hc)
        }
        return EvtGapResult(lost, reqs)
    }
}

/** One item of Android's catch-up answer (§8.5). */
sealed class ReplayItem {
    data class Replay(val epoch: Long, val seq: Long) : ReplayItem()
    data class Gap(val epoch: Long, val firstAvail: Long, val lastAvail: Long, val curEpoch: Long) : ReplayItem()
}

/** An event id in Android's ring. */
data class RingId(val epoch: Long, val seq: Long)

object SyncEvents {
    /**
     * Android's answer to a catch-up request `(epoch, afterSeq)` (§8.5), in send order. [ring]:
     * the ids held, oldest first.
     */
    fun replayPlan(ring: List<RingId>, curEpoch: Long, curSeq: Long, epoch: Long, afterSeq: Long): List<ReplayItem> {
        fun seqs(ep: Long): List<Long> = ring.filter { it.epoch == ep }.map { it.seq }

        fun planCur(s: Long): List<ReplayItem> {
            if (s >= curSeq) return emptyList()
            val qs = seqs(curEpoch)
            if ((s + 1) in qs) return qs.filter { it > s }.map { ReplayItem.Replay(curEpoch, it) }
            return listOf(ReplayItem.Gap(curEpoch, qs.minOrNull() ?: 0, qs.maxOrNull() ?: 0, curEpoch))
        }

        if (epoch > curEpoch) return emptyList()
        if (epoch == curEpoch) return planCur(afterSeq)
        val qs = seqs(epoch)
        if (qs.isNotEmpty() && (afterSeq + 1) in qs) {
            return qs.filter { it > afterSeq }.map { ReplayItem.Replay(epoch, it) } + planCur(0)
        }
        if (qs.isNotEmpty() && afterSeq >= qs.max()) return planCur(0)
        return listOf(ReplayItem.Gap(epoch, qs.minOrNull() ?: 0, qs.maxOrNull() ?: 0, curEpoch))
    }
}
