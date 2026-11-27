package com.magicmaker.android.sync

// The relay's connectable advertising, decided in one pure place (docs/SYNC_P3_ANDROID_PLAN.md
// §5.5, spec §3.1, §5.6): primary ADV = flags + the 32-bit service UUID + service data
// "MM_AND" + groupId[0..1] (00 00 while ungrouped), the scan response repeats the service data;
// LOW_LATENCY for 60 s after a start or a disconnect, then BALANCED; off while any central is
// connected; paused for manufacturer bursts / keep-awake; re-advertised when the group changes.

data class AdvSpec(val on: Boolean, val lowLatency: Boolean, val tag: Bytes) {
    companion object {
        val OFF: AdvSpec = AdvSpec(false, false, Bytes.EMPTY)
    }
}

class RelayAdvPolicy {
    private var running = false
    private var connected = 0
    private var paused = false
    private var fastUntil = Long.MIN_VALUE
    private var group: Bytes? = null

    fun start(now: Long) {
        running = true
        fastUntil = now + FAST_MS
    }

    fun stop() {
        running = false
    }

    fun setConnected(count: Int, now: Long) {
        if (count < connected && count == 0) fastUntil = now + FAST_MS
        connected = maxOf(0, count)
    }

    fun setPaused(paused: Boolean) {
        this.paused = paused
    }

    fun setGroup(groupId: Bytes?) {
        group = groupId
    }

    /** What should be on the air now. Re-evaluate on every input and when [nextChangeMs] passes. */
    fun spec(now: Long): AdvSpec {
        if (!running || paused || connected > 0) return AdvSpec.OFF
        return AdvSpec(true, now < fastUntil, tagBytes(group))
    }

    /** The next time the spec changes by itself (LOW_LATENCY -> BALANCED), or null. */
    fun nextChangeMs(now: Long): Long? = if (running && now < fastUntil) fastUntil else null

    companion object {
        const val FAST_MS: Long = 60_000
        const val TAG: String = "MM_AND"

        /** "MM_AND" + the first two bytes of groupId (00 00 while ungrouped). */
        fun tagBytes(groupId: Bytes?): Bytes {
            val g = if (groupId != null && groupId.size >= 2 && !groupId.isAllZero()) groupId.slice(0, 2) else Bytes.zero(2)
            return Bytes.of(*TAG.map { it.code }.toIntArray()) + g
        }

        /** Primary ADV length: flags (3) + 32-bit UUID list (2 + 4) + 32-bit service data (2 + 4 + tag). */
        fun primaryAdvBytes(tag: Bytes): Int = 3 + (2 + 4) + (2 + 4 + tag.size)
    }
}
