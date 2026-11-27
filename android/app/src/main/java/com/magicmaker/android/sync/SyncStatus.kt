package com.magicmaker.android.sync

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.atomic.AtomicInteger

// The SYNC / DEVICES view model (docs/SYNC_P3_ANDROID_PLAN.md §5.8, spec §9.7): one row per device
// (IPHONE, ESP32, THIS phone, plus any other device seen in a heartbeat) with battery, heartbeat
// age, link path and a sync badge, a header ("ALL IN SYNC" or the first problem), the group short
// id, the notification token and per-session diagnostics. SyncStatusBuilder is pure and tested;
// SyncEngine publishes the result on mm-sync into SyncStatus.state.

enum class RowTone { OK, BUSY, PROBLEM, IDLE }

data class DeviceRow(
    /** "IPHONE", "ESP32", "THIS", or another seen device ("ANDROID PIXEL"). */
    val label: String,
    val kind: Int,
    val battery: String,
    val age: String,
    val path: String,
    val badge: String,
    val tone: RowTone,
    /** Shown at all (a device never seen shows NEVER; THIS always shows). */
    val seen: Boolean,
    val battPct: Int?,
) {
    /** One monospace line, spec §9.7: `IPHONE   81% CHG     4S  DIRECT+VIA   IN SYNC`. */
    fun line(): String = label.take(8).padEnd(8) + " " + battery.padEnd(15) + " " + age.padStart(4) + "  " + path.padEnd(11) + " " + badge
}

data class SyncDashboard(
    val running: Boolean = false,
    val header: String = "SYNC OFF",
    val headerTone: RowTone = RowTone.IDLE,
    /** "GRP 9F3E" or "NO GROUP". */
    val group: String = "NO GROUP",
    val grouped: Boolean = false,
    val rows: List<DeviceRow> = emptyList(),
    /** Per-session diagnostics (DETAILS). */
    val diag: List<String> = emptyList(),
    /** Appended to the foreground notification: " · hub ✓ · iPhone ✓ 81%" (empty when nothing seen). */
    val notificationToken: String = "",
    val records: Int = 0,
    val allInSync: Boolean = false,
)

object SyncStatus {
    /** A VFD frame read within this long ago counts as the card being on screen. */
    const val WATCH_MS: Long = 3000

    private val flow = MutableStateFlow(SyncDashboard())
    val state: StateFlow<SyncDashboard> = flow.asStateFlow()
    private val watchers = AtomicInteger(0)
    @Volatile private var lastReadNs: Long? = null

    /** Set by the running engine: refresh soon (the card came on screen after a quiet spell). */
    @Volatile var onWatch: (() -> Unit)? = null

    fun publish(d: SyncDashboard) {
        flow.value = d
    }

    /** For a drawing pass that does not collect [state] (the VFD frame): also marks the card watched. */
    fun read(): SyncDashboard {
        val was = watched()
        lastReadNs = System.nanoTime()
        if (!was) onWatch?.invoke()
        return flow.value
    }

    /** A screen showing the card became visible ([on]) or hidden / left again (Compose card). */
    fun watch(on: Boolean) {
        if (on) {
            if (watchers.incrementAndGet() == 1) onWatch?.invoke()
        } else {
            watchers.updateAndGet { maxOf(0, it - 1) }
        }
    }

    /**
     * The card is on screen now: the engine refreshes it every second (heartbeat ages). Otherwise
     * it refreshes on every sync change and every 10 s, which is all the notification needs.
     */
    fun watched(): Boolean {
        if (watchers.get() > 0) return true
        val r = lastReadNs ?: return false
        return System.nanoTime() - r <= WATCH_MS * 1_000_000L
    }
}

/** The ESP32's battery from its advert heartbeat (firmware 1.4+), read-only. */
data class AdvertBattery(val pct: Int, val charging: Boolean, val onUsb: Boolean, val hasBattery: Boolean, val runtimeMin: Int)

/** This phone's battery (BatteryInfo + estimator). */
data class SelfBattery(val pct: Int, val mv: Int, val charging: Boolean?, val runtimeMin: Int, val powerSave: Boolean)

data class StatusInputs(
    val now: Long,
    val running: Boolean,
    val node: NodeSnapshot?,
    val roster: List<RosterEntry> = emptyList(),
    val stats: LibrarySyncStats? = null,
    val hub: HubLinkInfo? = null,
    val esp32Advert: AdvertBattery? = null,
    val esp32AdvertAgeMs: Long? = null,
    /** When a central connected to the relay GATT server (mono ms), null = none connected. */
    val relayCentralSinceMs: Long? = null,
    val self: SelfBattery? = null,
    val linkStats: Map<String, LinkStats> = emptyMap(),
    val eventsLine: String? = null,
)

object SyncStatusBuilder {
    const val FRESH_MS: Long = SyncConst.T_PATH_FRESH_MS
    const val LOST_MS: Long = 10 * 60_000L
    const val UPDATE_APP_AFTER_MS: Long = 10_000
    const val ISSUE_HOLD_MS: Long = 10 * 60_000L
    private const val HB_STATE_HUB_FULL = 1 shl 9

    private class Peer(
        val kind: Int,
        val session: SessionInfo?,
        val roster: RosterEntry?,
        val memo: LinkMemo?,
    ) {
        val deviceId: Bytes? get() = session?.peerId ?: roster?.hb?.deviceId ?: memo?.peerId
    }

    fun build(i: StatusInputs): SyncDashboard {
        val node = i.node
        if (!i.running || node == null) return SyncDashboard(running = false, header = "SYNC OFF", rows = listOf(thisRow(i, emptyList())))
        val selfId = node.deviceId
        val used = HashSet<Bytes>()
        val iphone = pick(i, SyncConst.KIND_IOS, "ios:", used)
        val hub = pick(i, SyncConst.KIND_HUB, "hub:", used)
        val rows = ArrayList<DeviceRow>()
        rows.add(peerRow(i, "IPHONE", iphone))
        rows.add(peerRow(i, "ESP32", hub))
        // Any other device seen in a heartbeat (another Android, a second iPhone or hub).
        for (r in i.roster.sortedBy { it.hb.deviceId.hex() }) {
            val id = r.hb.deviceId
            if (id == selfId || id in used) continue
            val label = kindName(r.hb.kind) + (r.hb.name?.let { " " + it.uppercase().take(8) } ?: "")
            val s = node.sessions.firstOrNull { it.peerId == id }
            rows.add(peerRow(i, label, Peer(r.hb.kind, s, r, null)))
        }
        val peersRows = rows.toList()
        rows.add(thisRow(i, peersRows))
        val unsaved = i.stats?.let { it.nextSyncSeq - 1 > it.durableHigh } ?: false
        val seenPeers = peersRows.filter { it.seen }
        val allInSync = seenPeers.isNotEmpty() && seenPeers.all { it.badge == "IN SYNC" } && !unsaved
        val problem = peersRows.firstOrNull { it.seen && it.tone == RowTone.PROBLEM }
            ?: peersRows.firstOrNull { it.seen && it.badge != "IN SYNC" }
        val (header, tone) = when {
            allInSync -> "ALL IN SYNC" to RowTone.OK
            seenPeers.isEmpty() -> "NOT LINKED" to RowTone.IDLE
            problem != null -> "${problem.label} ${problem.badge}" to (if (problem.tone == RowTone.BUSY) RowTone.BUSY else RowTone.PROBLEM)
            unsaved -> "SAVING" to RowTone.BUSY
            else -> "NOT LINKED" to RowTone.IDLE
        }
        val g = node.group
        return SyncDashboard(
            running = true,
            header = header,
            headerTone = tone,
            group = if (g != null) "GRP " + g.groupId.hex().takeLast(4) else "NO GROUP",
            grouped = g != null,
            rows = rows,
            diag = diag(i),
            notificationToken = notificationToken(peersRows),
            records = i.stats?.records ?: 0,
            allInSync = allInSync,
        )
    }

    // ---- per device ----------------------------------------------------------------------------

    private fun stateRank(s: SessionState): Int = when (s) {
        SessionState.SYNCED -> 9
        SessionState.SYNCING -> 8
        SessionState.AUTHED -> 7
        SessionState.HELLO_X -> 6
        SessionState.LINKED -> 5
        SessionState.FOREIGN, SessionState.INCOMPATIBLE, SessionState.NOGROUP -> 4
        else -> 0
    }

    private fun pick(i: StatusInputs, kind: Int, prefix: String, used: MutableSet<Bytes>): Peer {
        val node = i.node!!
        val s = node.sessions.filter { it.peerKind == kind || (it.peerKind == null && it.linkId.startsWith(prefix)) }
            .maxByOrNull { stateRank(it.state) }
        val r = (s?.peerId?.let { id -> i.roster.firstOrNull { it.hb.deviceId == id } })
            ?: i.roster.filter { it.hb.kind == kind && it.hb.deviceId != node.deviceId }.maxByOrNull { it.lastAnyMs }
        val m = node.memos.filter { (it.peerKind == kind || (it.peerKind == null && it.linkId.startsWith(prefix))) && i.now - it.atMs <= ISSUE_HOLD_MS }
            .maxByOrNull { it.atMs }
        val p = Peer(kind, s, r, m)
        p.deviceId?.let { used.add(it) }
        r?.hb?.deviceId?.let { used.add(it) }
        return p
    }

    private fun peerRow(i: StatusInputs, label: String, p: Peer): DeviceRow {
        val node = i.node!!
        val hb = p.roster?.hb
        val isHub = p.kind == SyncConst.KIND_HUB
        val advert = if (isHub && hb == null) i.esp32Advert else null
        val advertFresh = isHub && i.esp32AdvertAgeMs != null && i.esp32AdvertAgeMs <= FRESH_MS
        val relayCentral = p.kind == SyncConst.KIND_IOS && i.relayCentralSinceMs != null
        val hubInfo = if (isHub) i.hub else null
        val seen = p.session != null || hb != null || p.memo != null || (isHub && (i.esp32AdvertAgeMs != null || hubInfo?.noSync == true)) ||
            relayCentral
        val battery = when {
            hb != null -> batteryText(hb.battPctOrDefault, hb.battMvOrDefault.takeIf { isHub }, hb.chargingOrDefault == 1, false, hb.runtimeMinOrDefault)
            advert != null && advert.hasBattery -> batteryText(advert.pct, null, advert.charging, advert.onUsb, advert.runtimeMin)
            else -> "--"
        }
        val ageMs = p.roster?.let { i.now - it.lastAnyMs } ?: if (isHub) i.esp32AdvertAgeMs else null
        val age = ageText(ageMs)
        val path = pathText(i, p, advertFresh)
        val (badge, tone) = badge(i, p, hubInfo, relayCentral, seen)
        return DeviceRow(label, p.kind, battery, age, path, badge, tone, seen, hb?.battPctOrDefault?.takeIf { it >= 0 } ?: advert?.pct?.takeIf { it >= 0 })
    }

    private fun badge(i: StatusInputs, p: Peer, hubInfo: HubLinkInfo?, relayCentral: Boolean, seen: Boolean): Pair<String, RowTone> {
        val node = i.node!!
        val s = p.session
        val st = s?.state
        val issue = when {
            st == SessionState.FOREIGN || (st == null && p.memo?.lastState == SessionState.FOREIGN) -> "OTHER GROUP"
            st == SessionState.INCOMPATIBLE || (st == null && p.memo?.lastState == SessionState.INCOMPATIBLE) ->
                if (p.kind == SyncConst.KIND_HUB) "UPDATE FW" else "UPDATE APP"
            st == SessionState.NOGROUP || (st == null && p.memo?.lastState == SessionState.NOGROUP) -> "NO GROUP"
            hubInfo?.noSync == true && (st == null || !st.isAuthed) -> "NO SYNC FW"
            relayCentral && s == null && i.now - i.relayCentralSinceMs!! >= UPDATE_APP_AFTER_MS -> "UPDATE APP"
            p.roster?.hb?.let { it.stateOrDefault and HB_STATE_HUB_FULL != 0 } == true -> "HUB FULL"
            else -> null
        }
        if (issue != null) return issue to RowTone.PROBLEM
        if (st == SessionState.LINKED || st == SessionState.HELLO_X || st == SessionState.IDLE) return "LINKING" to RowTone.BUSY
        if (relayCentral && s == null && p.roster == null) return "LINKING" to RowTone.BUSY
        if (s != null && st != null && st.isAuthed) {
            val n = pending(i, s)
            if (st == SessionState.SYNCED && n == 0L) return "IN SYNC" to RowTone.OK
            return "SYNCING $n" to RowTone.BUSY
        }
        // No session: judge from the device's latest heartbeat (forwarded through another device).
        val r = p.roster
        val ours = i.stats?.records?.toLong()
        if (r != null && i.now - r.lastAnyMs <= FRESH_MS) {
            val forwarders = r.lastViaMs.filter { i.now - it.value <= FRESH_MS }.keys
            val syncedVia = r.hb.link.any { it.flags and SyncConst.HB_LINK_SYNCED != 0 && it.peerId in forwarders && forwarderSynced(node, it.peerId) }
            if (ours != null && r.hb.records == ours && syncedVia) return "IN SYNC" to RowTone.OK
            if (ours != null && r.hb.records != ours) return "BEHIND ${kotlin.math.abs(r.hb.records - ours)}" to RowTone.PROBLEM
            return "BEHIND" to RowTone.PROBLEM
        }
        val everSynced = p.memo?.everSynced == true || (p.deviceId?.let { node.peers[it]?.wm ?: 0 } ?: 0) > 0
        if (seen || everSynced) return "BEHIND" to RowTone.PROBLEM
        return "NEVER" to RowTone.IDLE
    }

    private fun forwarderSynced(node: NodeSnapshot, forwarder: Bytes): Boolean =
        node.sessions.any { it.peerId == forwarder && it.state == SessionState.SYNCED }

    /** SYNCING N: what the peer has that we have not pulled, what we have that it has not, and live RECs queued. */
    fun pending(i: StatusInputs, s: SessionInfo): Long {
        val node = i.node!!
        val id = s.peerId ?: return 0
        val fh = maxOf(s.peerFeedHigh, node.peerFeedHigh[id] ?: -1)
        val wm = s.wm ?: node.peers[id]?.wm ?: 0
        val theirs = if (fh >= 0) maxOf(0, fh - wm) else 0
        val served = maxOf(0, node.servedTo[id] ?: s.servedTo)
        val owed = maxOf(0, node.durableHigh - served - (node.acceptedSinceServe[id] ?: 0))
        return theirs + owed + s.pendingLive
    }

    private fun pathText(i: StatusInputs, p: Peer, advertFresh: Boolean): String {
        val node = i.node!!
        val r = p.roster
        val direct = (p.session?.state?.isAuthed == true) || (r?.lastDirectMs?.let { i.now - it <= FRESH_MS } == true)
        val via = r?.lastViaMs?.filter { i.now - it.value <= FRESH_MS }?.keys?.firstOrNull()
        val viaName = via?.let { f ->
            val k = node.sessions.firstOrNull { it.peerId == f }?.peerKind ?: i.roster.firstOrNull { it.hb.deviceId == f }?.hb?.kind
            "VIA " + (k?.let { kindName(it) } ?: f.hex().takeLast(4))
        }
        return when {
            direct && viaName != null -> "DIRECT+VIA"
            direct -> "DIRECT"
            viaName != null -> viaName
            p.kind == SyncConst.KIND_HUB && advertFresh -> "AIR"
            p.session != null -> "LINK"
            else -> "--"
        }
    }

    private fun thisRow(i: StatusInputs, peers: List<DeviceRow>): DeviceRow {
        val b = i.self
        val battery = if (b == null) "--" else batteryText(b.pct, null, b.charging == true, false, b.runtimeMin)
        val stats = i.stats
        val unsaved = stats?.let { it.nextSyncSeq - 1 > it.durableHigh } ?: false
        val seenPeers = peers.filter { it.seen }
        val badge = when {
            !i.running -> "OFF"
            unsaved -> "SAVING"
            seenPeers.isNotEmpty() && seenPeers.all { it.badge == "IN SYNC" } -> "IN SYNC"
            seenPeers.isEmpty() -> "LOCAL"
            else -> "SAVED"
        }
        val tone = when (badge) {
            "IN SYNC" -> RowTone.OK
            "SAVING" -> RowTone.BUSY
            else -> RowTone.IDLE
        }
        return DeviceRow("THIS", SyncConst.KIND_ANDROID, battery, "", "${stats?.records ?: 0} REC", badge, tone, true, b?.pct?.takeIf { it >= 0 })
    }

    // ---- text ----------------------------------------------------------------------------------

    fun kindName(kind: Int): String = when (kind) {
        SyncConst.KIND_HUB -> "ESP32"
        SyncConst.KIND_ANDROID -> "ANDROID"
        SyncConst.KIND_IOS -> "IPHONE"
        else -> "DEVICE"
    }

    /** "81%", "81% CHG", "68% 3.91V ~5H", "USB", or "--". */
    fun batteryText(pct: Int, mv: Int?, charging: Boolean, onUsb: Boolean, runtimeMin: Int): String {
        val parts = ArrayList<String>()
        if (pct >= 0) parts.add("$pct%")
        if (charging) parts.add("CHG") else if (onUsb && pct < 0) parts.add("USB")
        if (mv != null && mv > 0) parts.add("%.2fV".format(java.util.Locale.US, mv / 1000.0))
        if (!charging && !onUsb && runtimeMin >= 0) parts.add(runtimeText(runtimeMin))
        return if (parts.isEmpty()) "--" else parts.joinToString(" ")
    }

    /** "~45M", "~5H", "~99H+". */
    fun runtimeText(minutes: Int): String = when {
        minutes >= 99 * 60 -> "~99H+"
        minutes < 60 -> "~${maxOf(0, minutes)}M"
        else -> "~${minutes / 60}H"
    }

    /** "4S", "12S", "3M", "LOST" after 10 min, "--" never. */
    fun ageText(ms: Long?): String = when {
        ms == null -> "--"
        ms >= LOST_MS -> "LOST"
        ms < 60_000 -> "${maxOf(0, ms / 1000)}S"
        else -> "${ms / 60_000}M"
    }

    /** " · hub ✓ · iPhone ✓ 81%": ✓ in sync, ↻ syncing / linking, ! otherwise; never-seen devices are omitted. */
    fun notificationToken(rows: List<DeviceRow>): String {
        val sb = StringBuilder()
        for (r in rows) {
            if (!r.seen) continue
            val name = when (r.label) {
                "ESP32" -> "hub"
                "IPHONE" -> "iPhone"
                else -> r.label.lowercase().replaceFirstChar { it.uppercase() }
            }
            val mark = when {
                r.badge == "IN SYNC" -> "✓"
                r.tone == RowTone.BUSY -> "↻"
                else -> "!"
            }
            sb.append(" · ").append(name).append(' ').append(mark)
            r.battPct?.let { sb.append(' ').append(it).append('%') }
        }
        return sb.toString()
    }

    private fun diag(i: StatusInputs): List<String> {
        val node = i.node ?: return emptyList()
        val out = ArrayList<String>()
        out.add("DB ${node.dbId.hex().takeLast(8)} · DUR ${node.durableHigh} · HB ${node.hbSeq}" +
            (i.stats?.let { " · REC ${it.records} TOMB ${it.tombstones} SKIP ${it.skippedPresence} REJ ${it.rejected}" } ?: ""))
        for (s in node.sessions) {
            val c = s.counters
            val ls = i.linkStats[s.linkId]
            val up = ageText(i.now - s.upAtMs).let { if (it == "LOST") "${(i.now - s.upAtMs) / 60_000}M" else it }
            out.add(
                "${s.linkId.substringBefore(':').uppercase()} ${if (s.role == SessionRole.CENTRAL) "C" else "P"} ${s.state} MTU ${s.mtu} " +
                    "WM ${s.wm ?: 0}/${s.peerFeedHigh.coerceAtLeast(0)} DUR ${node.durableHigh} " +
                    "PG ${c.pagesPulled}/${c.pagesServed} ACC ${c.accepted} DUP ${c.duplicates} STALE ${c.stale} REJ ${c.rejected} " +
                    "BAD ${ls?.badFrames ?: 0} EVT ${c.evtSent}/${c.evtReplayed}/${c.gapsSent} " +
                    "ERR ${s.lastErr ?: "-"} UP $up",
            )
        }
        i.hub?.let { h ->
            out.add("HUB ${h.phase}${h.address?.let { " $it" } ?: ""}${if (h.autoPending) " AUTO" else ""}" +
                "${if (h.noSync) " NO-SYNC ${h.noSyncAddress}" else ""}${h.lastError?.let { " LAST $it" } ?: ""}" +
                (if (h.failures > 0) " RETRY ${h.nextAttemptInMs / 1000}S" else ""))
        }
        i.eventsLine?.let { out.add(it) }
        return out
    }
}
