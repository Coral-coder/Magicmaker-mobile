package com.magicmaker.android.sync

/**
 * The runtime estimator of spec §9.4 (plan §4.9). One sample `(t, pct)` per >= 60 s, kept for 60
 * min, reset on a charging change. While discharging with a drop of >= 3 points over >= 10 min:
 * the least-squares slope gives `rate` (points per minute) and `runtimeMin = pct / rate`, clamped
 * to 0..5999. Otherwise -1. Pure; mm-sync only.
 */
class RuntimeEstimator : RuntimeEstimatorPort {
    private class Sample(val t: Long, val pct: Int)

    private val samples = ArrayDeque<Sample>()
    private var lastCharging: Boolean? = null

    /** Samples held (tests). */
    val sampleCount: Int get() = samples.size

    override fun sample(monoMs: Long, pct: Int, charging: Boolean): Int {
        if (lastCharging != null && lastCharging != charging) samples.clear()
        lastCharging = charging
        if (pct !in 0..100) return -1
        if (samples.isEmpty() || monoMs - samples.last().t >= SAMPLE_MS) samples.addLast(Sample(monoMs, pct))
        while (samples.isNotEmpty() && monoMs - samples.first().t > HORIZON_MS) samples.removeFirst()
        if (charging || samples.size < 2) return -1
        val first = samples.first()
        val last = samples.last()
        if (first.pct - last.pct < MIN_DROP_PCT || last.t - first.t < MIN_SPAN_MS) return -1
        val n = samples.size.toDouble()
        val mt = samples.sumOf { (it.t - first.t) / 60_000.0 } / n
        val mp = samples.sumOf { it.pct.toDouble() } / n
        var num = 0.0
        var den = 0.0
        for (s in samples) {
            val dt = (s.t - first.t) / 60_000.0 - mt
            num += dt * (s.pct - mp)
            den += dt * dt
        }
        if (den <= 0.0) return -1
        val rate = -num / den
        if (rate <= 0.0) return -1
        return (pct / rate).toLong().coerceIn(0, MAX_RUNTIME_MIN.toLong()).toInt()
    }

    companion object {
        const val SAMPLE_MS: Long = 60_000
        const val HORIZON_MS: Long = 3_600_000
        const val MIN_SPAN_MS: Long = 600_000
        const val MIN_DROP_PCT: Int = 3
        const val MAX_RUNTIME_MIN: Int = 5999
    }
}

/**
 * The latest HB of every device and when it was last heard by path (PROTOCOL §16.4; plan §4.9).
 * A copy replaces the stored HB per [SyncRouting.hbReplaces]; every copy, replaced or not, updates
 * `lastAnyMs` and either `lastDirectMs` (hops 0 from the described device itself) or
 * `lastViaMs[fromPeer]`. Pure; mm-sync only.
 */
class DeviceRoster : DeviceRosterPort {
    private class Rec(var hb: Hb, var lastAnyMs: Long, var lastDirectMs: Long?, val via: LinkedHashMap<Bytes, Long>) {
        fun snapshot() = RosterEntry(hb, lastAnyMs, lastDirectMs, LinkedHashMap(via))
    }

    private val map = LinkedHashMap<Bytes, Rec>()

    override fun onHb(hb: Hb, fromPeer: Bytes, monoMs: Long): Boolean {
        val direct = hb.hops == 0 && hb.deviceId == fromPeer
        val r = map[hb.deviceId]
        val replaced = SyncRouting.hbReplaces(r?.let { HbVersion(it.hb.bootId, it.hb.hbSeq) }, HbVersion(hb.bootId, hb.hbSeq))
        val rec = r ?: Rec(hb, monoMs, null, LinkedHashMap()).also { map[hb.deviceId] = it }
        if (replaced) rec.hb = hb
        rec.lastAnyMs = maxOf(rec.lastAnyMs, monoMs)
        if (direct) rec.lastDirectMs = maxOf(rec.lastDirectMs ?: monoMs, monoMs) else rec.via[fromPeer] = monoMs
        return replaced
    }

    override fun get(deviceId: Bytes): RosterEntry? = map[deviceId]?.snapshot()

    override fun entries(): List<RosterEntry> = map.values.map { it.snapshot() }

    override fun forget(deviceId: Bytes) {
        map.remove(deviceId)
    }
}
