package com.magicmaker.android.sync

// Every decision of the Android -> ESP32 hub link (docs/SYNC_P3_ANDROID_PLAN.md §5.4), pure and
// tested; HubClient only performs the BluetoothGatt calls it returns. Discovery is passive: the
// service forwards relay adverts from the existing scanner (hubSeen). A known hub (identity
// hubAddress) keeps a pending autoConnect and switches to a direct attempt when it is heard; an
// unknown hub is picked as the strongest fresh, non-foreign candidate. Setup order: MTU 247 ->
// discover -> SYNC characteristic -> notify + CCCD -> link up. Firmware without SYNC is dropped at
// once and not probed again for 30 min (firmware 1.2 hides from the iPhone while a phone is linked).

sealed class HubCmd {
    data class Connect(val address: String, val auto: Boolean) : HubCmd()
    object RequestMtu : HubCmd() {
        override fun toString() = "RequestMtu"
    }
    object Discover : HubCmd() {
        override fun toString() = "Discover"
    }
    object EnableNotify : HubCmd() {
        override fun toString() = "EnableNotify"
    }
    data class LinkUp(val address: String, val mtu: Int) : HubCmd()
    data class LinkDown(val address: String) : HubCmd()

    /** gatt.disconnect() + gatt.close(). */
    data class Close(val reason: String) : HubCmd()
}

enum class HubPhase { OFF, IDLE, CONNECTING, MTU, DISCOVER, NOTIFY, UP }

/** What the status view shows about the hub link. */
data class HubLinkInfo(
    val phase: HubPhase,
    val address: String?,
    val autoPending: Boolean,
    /** The ESP32 answered without a SYNC characteristic (firmware < 2.0) within the last 30 min. */
    val noSync: Boolean,
    val noSyncAddress: String?,
    val lastError: String?,
    val failures: Int,
    val nextAttemptInMs: Long,
)

class HubLinkMachine(private val identity: SyncIdentityPort) {
    private class Seen(val name: String?, val rssi: Int, val at: Long)

    var phase: HubPhase = HubPhase.OFF
        private set
    var address: String? = null
        private set
    private var auto = false
    var mtu: Int = SyncConst.MTU_MIN
        private set
    private var opDeadline: Long? = null
    private var nextAttemptAt = 0L
    private var failures = 0
    private val seen = LinkedHashMap<String, Seen>()
    private val noSync = HashMap<String, Long>()
    private var lastError: String? = null
    private var authed = false

    val isUp: Boolean get() = phase == HubPhase.UP

    fun info(now: Long): HubLinkInfo {
        val ns = noSync.entries.filter { now - it.value < NO_SYNC_HOLD_MS }.maxByOrNull { it.value }
        return HubLinkInfo(phase, address, phase == HubPhase.CONNECTING && auto, ns != null, ns?.key, lastError, failures,
            maxOf(0, nextAttemptAt - now))
    }

    fun isNoSync(address: String, now: Long): Boolean = noSync[norm(address)]?.let { now - it < NO_SYNC_HOLD_MS } ?: false

    // ---- inputs ----------------------------------------------------------------------------

    fun start(now: Long): List<HubCmd> {
        if (phase == HubPhase.OFF) phase = HubPhase.IDLE
        return tick(now)
    }

    /** Service stop or Bluetooth off: drop the link, stay off until [start]. */
    fun stop(): List<HubCmd> {
        val out = drop("stop")
        phase = HubPhase.OFF
        return out
    }

    /** A relay advert (name MM_ESP… / MagicMaker-ESP32…) from the main scanner. */
    fun hubSeen(address: String, name: String?, rssi: Int, now: Long): List<HubCmd> {
        val a = norm(address)
        seen[a] = Seen(name, rssi, now)
        while (seen.size > 32) seen.remove(seen.keys.first())
        if (phase == HubPhase.CONNECTING && auto && a == address) {
            // The pending autoConnect is slow to fire: switch to a direct attempt now.
            val out = ArrayList<HubCmd>()
            out.add(HubCmd.Close("direct"))
            auto = false
            out.add(HubCmd.Connect(a, auto = false))
            opDeadline = now + CONNECT_TIMEOUT_MS
            return out
        }
        return tick(now)
    }

    /** Periodic (1 s): op timeouts and connect decisions. */
    fun tick(now: Long): List<HubCmd> {
        opDeadline?.let { d ->
            if (now >= d && phase != HubPhase.UP && !(phase == HubPhase.CONNECTING && auto)) return fail("timeout ${phase.name.lowercase()}", now)
        }
        if (phase != HubPhase.IDLE || now < nextAttemptAt) return emptyList()
        val known = identity.hubAddress?.let { norm(it) }
        if (known != null && !identity.isForeign(known) && !isNoSync(known, now)) {
            val s = seen[known]
            val fresh = s != null && now - s.at <= SEEN_FRESH_MS
            return connect(known, auto = !fresh, now)
        }
        val cand = seen.entries
            .filter { now - it.value.at <= SEEN_FRESH_MS && !identity.isForeign(it.key) && !isNoSync(it.key, now) && it.key != known }
            .maxByOrNull { it.value.rssi } ?: return emptyList()
        return connect(cand.key, auto = false, now)
    }

    fun onConnected(now: Long): List<HubCmd> {
        if (phase != HubPhase.CONNECTING) return emptyList()
        phase = HubPhase.MTU
        opDeadline = now + OP_TIMEOUT_MS
        return listOf(HubCmd.RequestMtu)
    }

    /** onMtuChanged; a failed request continues at the default MTU. */
    fun onMtu(mtu: Int, ok: Boolean, now: Long): List<HubCmd> {
        if (phase != HubPhase.MTU) return emptyList()
        this.mtu = if (ok) mtu.coerceIn(SyncConst.MTU_MIN, SyncConst.MTU_MAX) else SyncConst.MTU_MIN
        phase = HubPhase.DISCOVER
        opDeadline = now + OP_TIMEOUT_MS
        return listOf(HubCmd.Discover)
    }

    /** An MTU change on an established link (the channel uses it from the next message). */
    fun onMtuLater(mtu: Int) {
        if (phase == HubPhase.UP) this.mtu = mtu.coerceIn(SyncConst.MTU_MIN, SyncConst.MTU_MAX)
    }

    fun onServices(hasSync: Boolean, ok: Boolean, now: Long): List<HubCmd> {
        if (phase != HubPhase.DISCOVER) return emptyList()
        if (!ok) return fail("discover", now)
        if (!hasSync) {
            val a = address!!
            noSync[a] = now
            lastError = "no SYNC characteristic"
            val out = drop("no_sync")
            phase = HubPhase.IDLE
            nextAttemptAt = now + BACKOFF_MS[0]
            return out
        }
        phase = HubPhase.NOTIFY
        opDeadline = now + OP_TIMEOUT_MS
        return listOf(HubCmd.EnableNotify)
    }

    /** setCharacteristicNotification + the CCCD write (01 00) completed. */
    fun onNotifyEnabled(ok: Boolean, now: Long): List<HubCmd> {
        if (phase != HubPhase.NOTIFY) return emptyList()
        if (!ok) return fail("cccd", now)
        phase = HubPhase.UP
        opDeadline = null
        noSync.remove(address!!)
        return listOf(HubCmd.LinkUp(address!!, mtu))
    }

    /** onConnectionStateChange DISCONNECTED (or a connect failure, e.g. status 133). */
    fun onDisconnected(status: Int, now: Long): List<HubCmd> {
        if (phase == HubPhase.OFF || phase == HubPhase.IDLE) return emptyList()
        return fail(if (status == 0) "disconnected" else "status $status", now)
    }

    /** The session / channel closed the link ([retryMs]: the session's floor, e.g. page_timeout 30 s). */
    fun onLocalClose(reason: String, retryMs: Long?, now: Long): List<HubCmd> {
        if (phase == HubPhase.OFF || phase == HubPhase.IDLE) return emptyList()
        val out = fail(reason, now)
        if (retryMs != null) nextAttemptAt = maxOf(nextAttemptAt, now + retryMs)
        return out
    }

    /** The hub session reached AUTHED: remember the hub; the link works, so the backoff resets. */
    fun onAuthed() {
        val a = address ?: return
        authed = true
        failures = 0
        lastError = null
        if (identity.hubAddress?.let { norm(it) } != a) identity.setHubAddress(a)
    }

    /**
     * NodeRequest.FOREIGN on the hub link: never auto-connect to that MAC again (until this
     * phone's group changes, [SyncIdentityPort.setGroup]). The link is not closed here: FOREIGN
     * entry queued `ERR{AUTH}` just before this request and its `disconnect foreign` action follows
     * (PROTOCOL §14.5), so the channel flushes the ERR and then closes through [onLocalClose].
     */
    @Suppress("UNUSED_PARAMETER")
    fun onForeign(now: Long): List<HubCmd> {
        val a = address ?: return emptyList()
        identity.markForeign(a)
        if (identity.hubAddress?.let { norm(it) } == a) identity.setHubAddress(null)
        lastError = "other group"
        return emptyList()
    }

    // ---- helpers -------------------------------------------------------------------------------

    private fun connect(a: String, auto: Boolean, now: Long): List<HubCmd> {
        phase = HubPhase.CONNECTING
        address = a
        this.auto = auto
        mtu = SyncConst.MTU_MIN
        authed = false
        opDeadline = if (auto) null else now + CONNECT_TIMEOUT_MS
        return listOf(HubCmd.Connect(a, auto))
    }

    private fun drop(reason: String): List<HubCmd> {
        val out = ArrayList<HubCmd>()
        val a = address
        if (phase == HubPhase.UP && a != null) out.add(HubCmd.LinkDown(a))
        if (phase != HubPhase.OFF && phase != HubPhase.IDLE) out.add(HubCmd.Close(reason))
        opDeadline = null
        auto = false
        return out
    }

    private fun fail(reason: String, now: Long): List<HubCmd> {
        val wasAuthed = authed
        val out = drop(reason)
        phase = HubPhase.IDLE
        if (reason != "foreign") lastError = reason
        if (wasAuthed) failures = 0
        failures++
        nextAttemptAt = now + BACKOFF_MS[minOf(failures - 1, BACKOFF_MS.size - 1)]
        authed = false
        return out
    }

    companion object {
        val BACKOFF_MS: LongArray = longArrayOf(1_000, 2_000, 5_000, 10_000, 30_000)
        const val OP_TIMEOUT_MS: Long = 5_000
        const val CONNECT_TIMEOUT_MS: Long = 10_000
        const val NO_SYNC_HOLD_MS: Long = 30 * 60_000L
        const val SEEN_FRESH_MS: Long = 10_000
        const val REQUEST_MTU: Int = 247

        fun norm(a: String): String = a.trim().uppercase()

        /** Adverts that may be the ESP32 hub (never another Android relay, which carries MM_AND). */
        fun isHubName(name: String?): Boolean =
            name != null && (name.startsWith("MM_ESP") || name.startsWith("MagicMaker-ESP32"))
    }
}
