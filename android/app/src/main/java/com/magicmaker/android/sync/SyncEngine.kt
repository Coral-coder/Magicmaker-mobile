package com.magicmaker.android.sync

import android.bluetooth.BluetoothManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import com.magicmaker.android.BuildConfig
import com.magicmaker.android.core.CrashLog
import com.magicmaker.android.core.HexUtils
import com.magicmaker.android.service.ServiceState
import java.security.SecureRandom

/** mm-sync timers on a Handler: mono = uptimeMillis (the service holds a partial wake lock). */
class HandlerScheduler(private val handler: Handler) : SyncScheduler {
    override fun now(): Long = SystemClock.uptimeMillis()

    override fun wallMs(): Long = System.currentTimeMillis()

    override fun at(t: Long, task: () -> Unit): SyncCancel {
        val r = Runnable {
            try {
                task()
            } catch (t: Throwable) {
                // A sync bug must never take the app down with the mm-sync thread.
                CrashLog.record(t, "mm-sync task")
            }
        }
        handler.postAtTime(r, t)
        return SyncCancel { handler.removeCallbacks(r) }
    }
}

/**
 * The relay GATT server's SYNC characteristic, as SyncEngine sees it. RelayGattServer calls these
 * from binder threads with copied values; every implementation only posts to mm-sync.
 */
interface SyncServerEndpoint {
    fun onCentralConnected(address: String)

    fun onCentralDisconnected(address: String)

    fun onMtu(address: String, mtu: Int)

    fun onCccd(address: String, value: ByteArray?)

    fun onSyncWrite(address: String, value: ByteArray)

    fun onNotificationSent(address: String, status: Int)

    /** The server stopped (relay restart, Bluetooth off): every SYNC link is gone. */
    fun onServerStopped()

    /** The live server to send notifications through (null while none runs). */
    fun attach(notifier: SyncNotifier?)
}

/** What SyncEngine needs from the running GATT server (called on mm-sync only). */
interface SyncNotifier {
    /** One SYNC notification; false = busy / failed (the channel retries in 20 ms). */
    fun notifySync(address: String, value: ByteArray): Boolean

    /** Drop that central (cancelConnection). */
    fun disconnect(address: String)
}

/**
 * The Android sync runtime (docs/SYNC_P3_ANDROID_PLAN.md §5.6): one HandlerThread "mm-sync" that
 * owns the pure SyncNode, a LinkChannel per link, the HubClient (central to the ESP32), the server
 * endpoint (the iPhone's direct link through RelayGattServer), BatteryInfo and the SyncStatus
 * publisher. Every public method is thread-safe and only posts; nothing here ever blocks the
 * scanner, the transmitter or a binder thread.
 */
class SyncEngine(
    private val ctx: Context,
    private val data: SyncData,
    private val txBusy: () -> Boolean = { false },
) {
    private val thread = HandlerThread("mm-sync")
    private lateinit var handler: Handler
    private lateinit var sched: HandlerScheduler
    private var node: SyncNode? = null
    private var role: AndroidRole? = null
    private var roster: DeviceRosterPort? = null
    private var battery: BatteryInfo? = null
    @Volatile private var hubClient: HubClient? = null
    private val channels = HashMap<String, LinkChannel>()
    private val serverLinks = GattServerLinks()
    @Volatile private var notifier: SyncNotifier? = null
    private val rng = SecureRandom()
    private var startedAt = 0L
    private var hubAirAt: Long? = null
    private var hubAdvertAt: Long? = null
    private var relayCentralSince: Long? = null
    private var lastBits = -1
    private var lastBattSample = 0L
    private var eventsArmed: Long? = null
    private var eventsTask: SyncCancel? = null
    private var tickTask: SyncCancel? = null
    private var statusTask: SyncCancel? = null
    private var lastToken = ""
    private var lastHeader = ""
    private var lastPublishAt = Long.MIN_VALUE / 4
    @Volatile private var started = false

    /** Re-advertise with this tag (the group changed). Called on mm-sync. */
    @Volatile var onGroupTag: ((ByteArray) -> Unit)? = null

    /** The notification token or header changed (the service refreshes its notification). */
    @Volatile var onStatusChanged: (() -> Unit)? = null

    /** The tag the relay should advertise now: "MM_AND" + groupId[0..1]. */
    fun groupTag(): ByteArray = RelayAdvPolicy.tagBytes(data.identity.group?.groupId).toByteArray()

    /** The sync group id for the advert tag (null while ungrouped). Thread-safe. */
    fun groupId(): ByteArray? = data.identity.group?.groupId?.toByteArray()

    /** The remembered hub MAC (the service's echo filter). Thread-safe. */
    fun hubAddress(): String? = data.identity.hubAddress

    /** [address] is this phone's own client link to the ESP32 (not a central of the relay). Thread-safe. */
    fun isHubLink(address: String): Boolean =
        hubClient?.currentAddress.equals(address, ignoreCase = true) || data.identity.hubAddress.equals(address, ignoreCase = true)

    /** No hub known yet: the scanner adds the relay service filter while the screen is off. */
    fun wantsHubDiscovery(): Boolean = data.identity.hubAddress == null

    fun start() {
        if (started) return
        thread.start()
        handler = Handler(thread.looper)
        sched = HandlerScheduler(handler)
        // Volatile write after the handler exists: post() from any thread checks [started] first.
        started = true
        current = this
        handler.post { guarded("start") { startOnThread() } }
    }

    fun stop() {
        if (!started) return
        started = false
        if (current === this) current = null
        handler.post {
            guarded("stop") {
                hubClient?.stop()
                hubClient = null
                for (id in channels.keys.toList()) {
                    channels.remove(id)?.linkLost()
                    node?.linkDown(id)
                }
                serverLinks.clear()
                battery?.stop()
                data.library.setListener(null)
                tickTask?.cancel()
                eventsTask?.cancel()
                statusTask?.cancel()
                node = null
                if (SyncStatus.onWatch === watchHook) SyncStatus.onWatch = null
                SyncStatus.publish(SyncDashboard())
            }
            thread.quitSafely()
        }
    }

    private fun post(what: String, block: () -> Unit) {
        if (!started) return
        handler.post { guarded(what, block) }
    }

    private inline fun guarded(what: String, block: () -> Unit) {
        try {
            block()
        } catch (t: Throwable) {
            CrashLog.record(t, "SyncEngine $what")
        }
    }

    // ---- start ------------------------------------------------------------------------------

    private fun startOnThread() {
        startedAt = sched.now()
        val id = data.identity
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val events = if (prefs.getBoolean(PREF_SHARE_HEARD, true)) data.startEventOrigin(System.currentTimeMillis(), SyncConst.ANDROID_EVT_RING) else null
        val r = AndroidRole(events)
        role = r
        val ros = data.newRoster()
        roster = ros
        val est = data.newRuntimeEstimator()
        val b = BatteryInfo(ctx, handler, est, { sched.now() }) { node?.selfChanged() }
        battery = b
        val n = SyncNode(
            cfg = NodeConfig(
                deviceId = id.deviceId,
                kind = SyncConst.KIND_ANDROID,
                maxMsg = SyncConst.PHONE_MAXMSG,
                version = SyncText.normalize(BuildConfig.VERSION_NAME, 16),
                name = SyncText.normalize(Build.MODEL ?: "Android", 20),
            ),
            identity = id,
            library = data.library,
            roster = ros,
            sched = sched,
            role = r,
            self = { selfStatus() },
            policy = NodePolicy.PRODUCTION,
            nonces = { randomNonce() },
            bootId = rng.nextInt(0x10000),
        )
        n.onGroupChanged = { g ->
            val tag = RelayAdvPolicy.tagBytes(g?.groupId).toByteArray()
            onGroupTag?.invoke(tag)
        }
        n.onForeign = { linkId -> if (linkId.startsWith("hub:")) hubClient?.onForeign() }
        n.onAuthed = { s -> if (s.id.startsWith("hub:")) hubClient?.onAuthed() }
        n.onChanged = { markDirty() }
        node = n
        data.library.setListener(object : SyncLibraryListener {
            override fun onLocalChanges(entries: List<LedgerEntry>, bulk: Boolean) {
                post("local") { node?.onLocalChanges(entries, bulk) }
            }

            override fun onDurable(durableHigh: Long) {
                post("durable") { node?.onDurable(durableHigh) }
            }
        })
        b.start()
        val bt = ctx.getSystemService(BluetoothManager::class.java)
        if (bt != null) {
            hubClient = HubClient(ctx, bt, handler, sched, HubLinkMachine(id), hubListener).also {
                if (bt.adapter?.isEnabled == true) it.start()
            }
        }
        lastBits = stateBits()
        SyncStatus.onWatch = watchHook
        scheduleTick()
        markDirty()
    }

    /** The card came on screen: refresh it now rather than at the next 10 s idle refresh. */
    private val watchHook: () -> Unit = { post("watch") { markDirty() } }

    private fun randomNonce(): Bytes {
        val a = ByteArray(8)
        rng.nextBytes(a)
        return Bytes.of(a)
    }

    // ---- self status ----------------------------------------------------------------------------

    private fun stateBits(): Int {
        val st = ServiceState.state.value
        var bits = 0
        if (st.scanActive) bits = bits or 0x0001
        if (st.keepAwakeActive) bits = bits or 0x0002
        if (st.txLoopEnabled) bits = bits or 0x0004
        if (st.starlightLoopEnabled) bits = bits or 0x0008
        if (st.randomShowEnabled) bits = bits or 0x0010
        if (battery?.powerSave == true) bits = bits or 0x0020
        if (runCatching { txBusy() }.getOrDefault(false)) bits = bits or 0x0040
        return bits
    }

    private fun selfStatus(): SelfStatus {
        val b = battery
        val now = sched.now()
        return SelfStatus(
            battPct = b?.pct ?: -1,
            battMv = b?.mv ?: -1,
            charging = when (b?.charging) {
                true -> 1
                false -> 0
                null -> -1
            },
            runtimeMin = b?.runtimeMin ?: -1,
            state = stateBits(),
            hubAirAgoS = hubAirAt?.let { ((now - it) / 1000).coerceIn(0, 0xFFFE).toInt() } ?: 0xFFFF,
            uptimeS = (now - startedAt) / 1000,
        )
    }

    // ---- periodic -----------------------------------------------------------------------------

    private fun scheduleTick() {
        tickTask = sched.at(sched.now() + 1000) {
            guarded("tick") { tick() }
            if (started) scheduleTick()
        }
    }

    private fun tick() {
        val now = sched.now()
        role?.paceTick()
        if (now - lastBattSample >= 60_000) {
            lastBattSample = now
            battery?.sample()
        }
        val bits = stateBits()
        if (bits != lastBits) {
            lastBits = bits
            node?.selfChanged()
        }
        // Every sync change already marks the status dirty. The clock only matters for ages and
        // time-based badges: every second while the card is on screen, else every 10 s (the
        // notification token), so a phone in a pocket does not rebuild the view (and take the
        // store lock for library stats) 86,400 times a day.
        if (SyncStatus.watched() || now - lastPublishAt >= STATUS_IDLE_MS) markDirty()
    }

    private fun armEvents() {
        val due = role?.nextDueMs() ?: return
        val armed = eventsArmed
        if (armed != null && armed <= due) return
        eventsTask?.cancel()
        eventsArmed = due
        eventsTask = sched.at(due) {
            eventsArmed = null
            eventsTask = null
            guarded("events") {
                role?.onEventsTick()
                armEvents()
            }
        }
    }

    // ---- status ---------------------------------------------------------------------------------

    private fun markDirty() {
        if (statusTask != null) return
        statusTask = sched.at(sched.now() + STATUS_MIN_MS) {
            statusTask = null
            guarded("status") { publishStatus() }
        }
    }

    private fun publishStatus() {
        val n = node ?: return
        val now = sched.now()
        lastPublishAt = now
        val adv = ServiceState.state.value.esp32Battery
        val d = SyncStatusBuilder.build(
            StatusInputs(
                now = now,
                running = true,
                node = n.snapshot(),
                roster = roster?.entries() ?: emptyList(),
                stats = runCatching { data.library.stats() }.getOrNull(),
                hub = hubClient?.info(),
                esp32Advert = adv?.let { AdvertBattery(it.percent, it.charging, it.onUsb, it.hasBattery, it.runtimeMinutes) },
                esp32AdvertAgeMs = hubAdvertAt?.let { now - it },
                relayCentralSinceMs = relayCentralSince,
                self = battery?.snapshot(),
                linkStats = channels.mapValues { it.value.stats() },
                eventsLine = role?.let {
                    val ev = it.events
                    if (ev == null) "EVT OFF" else "EVT ${ev.epoch}/${ev.seq} SENT ${it.evtSent} RING ${it.evtRingOnly} REPLAY ${it.replaysSent} GAP ${it.gapsSent}" +
                        (if (it.isWide) " WIDE" else "")
                },
            ),
        )
        SyncStatus.publish(d)
        if (d.notificationToken != lastToken || d.header != lastHeader) {
            lastToken = d.notificationToken
            lastHeader = d.header
            onStatusChanged?.invoke()
        }
    }

    // ---- inputs from the service (any thread; post only) ------------------------------------------

    /** A packet that passed handleHeard's filters (packet executor). */
    fun onHeard(hex: String, rssi: Int, address: String, latDeg: Double, lonDeg: Double, accM: Float, isBand: Boolean) {
        val wall = System.currentTimeMillis()
        val mono = SystemClock.uptimeMillis()
        post("heard") {
            val r = role ?: return@post
            if (r.events == null) return@post
            val packet = runCatching { Bytes.fromHex(HexUtils.canonicalHex(hex)) }.getOrNull() ?: return@post
            if (runCatching { RecordKey.checkPacket(packet) }.isFailure) return@post
            val lat = EventOrigin.e7(latDeg)
            val lon = EventOrigin.e7(lonDeg)
            val fix = lat != null && lon != null && accM >= 0f && lat in -900_000_000..900_000_000 && lon in -1_800_000_000..1_800_000_000
            r.onSighting(
                HeardSighting(
                    packet = packet,
                    rssi = rssi.takeIf { it in -128..127 },
                    wallMs = wall,
                    monoMs = mono,
                    lat = if (fix) lat else null,
                    lon = if (fix) lon else null,
                    accM = if (fix) accM.toInt().coerceIn(0, 0xFFFF) else null,
                    addr = EventOrigin.addrBytes(address),
                    taggedOwnBand = isBand,
                ),
            )
            armEvents()
        }
    }

    /** The hub's own beacon was heard on air (echo filter): hubAirAgoS. */
    fun onHubAir(address: String) {
        if (!throttle("air:$address", 500)) return
        post("hubAir") {
            val hub = data.identity.hubAddress
            if (hub == null || hub.equals(address, ignoreCase = true) || hubClient?.machine?.address.equals(address, ignoreCase = true)) {
                hubAirAt = sched.now()
            }
        }
    }

    /** The ESP32's advert heartbeat (battery) was heard. */
    fun onHubAdvert(address: String) {
        if (!throttle("adv:$address", 500)) return
        post("hubAdvert") { hubAdvertAt = sched.now() }
    }

    private val lastPost = java.util.concurrent.ConcurrentHashMap<String, Long>()

    /** Scanner callbacks arrive many times a second; one post per [ms] per key is plenty. */
    private fun throttle(key: String, ms: Long): Boolean {
        val now = SystemClock.uptimeMillis()
        val last = lastPost[key]
        if (last != null && now - last < ms) return false
        if (lastPost.size > 64) lastPost.clear()
        lastPost[key] = now
        return true
    }

    /** A relay advert from the scanner (name MM_ESP… for the hub; MM_AND relays are not reported). */
    fun hubSeen(address: String, name: String?, rssi: Int) {
        if (!HubLinkMachine.isHubName(name)) return
        if (!throttle("seen:$address", 1000)) return
        post("hubSeen") {
            hubAdvertAt = sched.now()
            hubClient?.hubSeen(address, name, rssi)
        }
    }

    fun leaveGroup() = post("leave") { node?.leaveGroup() }

    fun setShareHeard(on: Boolean) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(PREF_SHARE_HEARD, on).apply()
        post("share") {
            val r = role ?: return@post
            if (on && r.events == null) r.setEvents(data.startEventOrigin(System.currentTimeMillis(), SyncConst.ANDROID_EVT_RING))
            if (!on) r.setEvents(null)
            markDirty()
        }
    }

    fun bluetoothOff() = post("btOff") {
        hubClient?.stop()
        for (ev in serverLinks.clear()) execServer(ev)
        relayCentralSince = null
        markDirty()
    }

    fun bluetoothOn() = post("btOn") {
        hubClient?.start()
        markDirty()
    }

    // ---- hub link ------------------------------------------------------------------------------------

    private val hubListener = object : HubClient.Listener {
        override fun onHubUp(link: FrameLink, mtu: Int) {
            val n = node ?: return
            val ch = LinkChannel(link, sched, SyncConst.PHONE_MAXMSG, onMessage = { m -> node?.onMessage(link.id, m) })
            channels[link.id] = ch
            n.linkUp(ch, SessionRole.CENTRAL, mtu, SyncConst.KIND_HUB)
        }

        override fun onHubDown(linkId: String) {
            channels.remove(linkId)?.linkLost()
            node?.linkDown(linkId)
        }

        override fun onHubFrame(linkId: String, value: ByteArray) {
            channels[linkId]?.onFrame(value)
        }

        override fun onHubFrameSent(linkId: String) {
            channels[linkId]?.onFrameSent()
        }

        override fun onHubMtu(linkId: String, mtu: Int) {
            channels[linkId]?.onMtu()
        }
    }

    // ---- server endpoint (the iPhone's direct link) ---------------------------------------------------

    private inner class ServerLink(private val address: String, override val id: String) : FrameLink {
        override val role: SessionRole get() = SessionRole.PERIPHERAL

        override fun mtu(): Int = serverLinks.mtuOf(address)

        override fun writeFrame(frame: ByteArray): Boolean = notifier?.notifySync(address, frame) ?: false

        override fun close(reason: String) {
            notifier?.disconnect(address)
            // The disconnect callback brings the link down; if it never comes, do it now.
            for (ev in serverLinks.onCccd(address, null)) execServer(ev)
        }
    }

    val serverEndpoint: SyncServerEndpoint = object : SyncServerEndpoint {
        override fun onCentralConnected(address: String) = post("srvConn") {
            if (relayCentralSince == null) relayCentralSince = sched.now()
            for (ev in serverLinks.onConnected(address)) execServer(ev)
            markDirty()
        }

        override fun onCentralDisconnected(address: String) = post("srvDisc") {
            for (ev in serverLinks.onDisconnected(address)) execServer(ev)
            if (serverLinks.connectedCount() == 0) relayCentralSince = null
            markDirty()
        }

        override fun onMtu(address: String, mtu: Int) = post("srvMtu") {
            for (ev in serverLinks.onMtu(address, mtu)) execServer(ev)
        }

        override fun onCccd(address: String, value: ByteArray?) {
            val v = value?.copyOf()
            post("srvCccd") { for (ev in serverLinks.onCccd(address, v)) execServer(ev) }
        }

        override fun onSyncWrite(address: String, value: ByteArray) {
            val v = value.copyOf()
            post("srvWrite") { for (ev in serverLinks.onWrite(address, v)) execServer(ev) }
        }

        override fun onNotificationSent(address: String, status: Int) = post("srvSent") {
            for (ev in serverLinks.onNotificationSent(address)) execServer(ev)
        }

        override fun onServerStopped() = post("srvStop") {
            for (ev in serverLinks.clear()) execServer(ev)
            relayCentralSince = null
            markDirty()
        }

        override fun attach(notifier: SyncNotifier?) {
            this@SyncEngine.notifier = notifier
        }
    }

    private fun execServer(ev: ServerLinkEvent) {
        val n = node ?: return
        when (ev) {
            is ServerLinkEvent.Up -> {
                val link = ServerLink(ev.address, ev.linkId)
                val ch = LinkChannel(link, sched, SyncConst.PHONE_MAXMSG, onMessage = { m -> node?.onMessage(ev.linkId, m) })
                channels[ev.linkId] = ch
                n.linkUp(ch, SessionRole.PERIPHERAL, ev.mtu, null)
            }
            is ServerLinkEvent.Down -> {
                channels.remove(ev.linkId)?.linkLost()
                n.linkDown(ev.linkId)
            }
            is ServerLinkEvent.Mtu -> channels[ev.linkId]?.onMtu()
            is ServerLinkEvent.Frame -> channels[ev.linkId]?.onFrame(ev.bytes)
            is ServerLinkEvent.Sent -> channels[ev.linkId]?.onFrameSent()
        }
    }

    companion object {
        /** The running engine (the UI's "Leave sync group"); null while the service is down. */
        @Volatile var current: SyncEngine? = null
            private set

        const val PREFS: String = "magicmaker"
        const val PREF_SHARE_HEARD: String = "sync_share_heard"
        private const val STATUS_MIN_MS: Long = 250
        private const val STATUS_IDLE_MS: Long = 10_000
    }
}
