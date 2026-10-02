package com.magicmaker.android.service

import com.magicmaker.android.core.RelayControlMode
import com.magicmaker.android.core.HexUtils
import com.magicmaker.android.core.MagicCategory
import com.magicmaker.android.core.LivePacketSort
import com.magicmaker.android.core.MagicClassifier
import com.magicmaker.android.core.TransmitTiming
import com.magicmaker.android.relay.RelayCommands
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject

object ServiceState {
    data class LivePacket(
        val hex: String,
        val label: String,
        val rssi: Int,
        val note: String,
        val category: MagicCategory = MagicCategory.UNKNOWN,
        val typeInfo: String = "raw",
        val dedupeKey: String = "",
        val timestampMs: Long = System.currentTimeMillis(),
        val address: String = "",
        val isBand: Boolean = false,
    )

    /** A BLE advertiser address heard during scanning — feeds the "pick my band" UI. */
    data class SeenAddress(
        val address: String,
        val rssi: Int,
        val lastSeenMs: Long,
        val count: Int,
    )

    /** Per-broadcaster diagnostics: one entry per source MAC. */
    data class SourceStat(
        val address: String,
        val count: Int,
        val bestRssi: Int,
        val lastRssi: Int,
        val lastSeenMs: Long,
        val priority: Boolean,        // sent at least one show control / animation / color
        val categories: Set<String>,
    )

    data class UiState(
        val running: Boolean = false,
        val status: String = "Idle",
        val lastHeardHex: String = "",
        val lastHeardLabel: String = "",
        val lastTransmitHex: String = "",
        val scanActive: Boolean = false,
        val recordSessionActive: Boolean = false,
        val activeSessionName: String = "",
        val relayMode: RelayControlMode = RelayControlMode.STANDALONE,
        val hotspotSsid: String = "",
        val hotspotPassword: String = "",
        val relayIp: String = "",
        val httpPort: Int = 8765,
        val autoEnabled: Boolean = true,
        val packetsHeard: Int = 0,
        val autoResponsesSent: Int = 0,
        val storeRevision: Int = 0,
        val livePackets: List<LivePacket> = emptyList(),
        val rawLivePackets: List<LivePacket> = emptyList(),
        val seenAddresses: List<SeenAddress> = emptyList(),
        val sources: List<SourceStat> = emptyList(),
        val starlightLoopEnabled: Boolean = false,
        val starlightLoopPacketId: Long = -1L,
        val starlightIntervalMs: Long = 3000L,
        val starlightLoopLabel: String = "none",
        val txLoopEnabled: Boolean = false,
        val txLoopPacketId: Long = -1L,
        val txLoopIntervalMs: Long = 3000L,
        val txLoopLabel: String = "none",
        val randomShowEnabled: Boolean = false,
        val randomShowIntervalMs: Long = 3000L,
        val randomShowLabel: String = "",
        val wandDisplayColorIndex: Int = 0x1B,
        val wakeupPreambleMs: Int = 520,
        val commandBurstMs: Int = TransmitTiming.COMMAND_BURST_MS,
        val starlightBurstMs: Int = TransmitTiming.STARLIGHT_BURST_MS,
        val relayLinked: Boolean = false,
        val replayActive: Boolean = false,
        val replayProgress: Int = 0,
        val replayTotal: Int = 0,
        val replayLabel: String = "",
        val cloudSyncStatus: String = "",
        val labLoadTick: Int = 0,
    )

    fun setCloudSyncStatus(status: String) {
        update { it.copy(cloudSyncStatus = status) }
    }

    /** Bumped when a packet is sent to the Lab from another screen, so the Lab reloads it. */
    fun requestLabLoad() {
        update { it.copy(labLoadTick = it.labLoadTick + 1) }
    }

    private const val MAX_LIVE = 120
    private const val MAX_ADDRESSES = 80
    private const val MAX_SOURCES = 300
    private const val MAX_SOURCE_STATS = 500

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    private val listeners = mutableSetOf<(UiState) -> Unit>()

    // ServiceState is shared across three threads — the main/UI thread, the service's
    // single-thread packet executor, and BLE binder threads. Every read-modify-write of
    // _state and every listener iteration MUST hold this lock, or concurrent updates race
    // (lost packets → "only one shown") and listeners.forEach throws ConcurrentModification
    // (→ crash, e.g. sending to the Lab while packets stream in). Listeners are invoked
    // outside the lock (on a snapshot) so a listener that calls back into update can't deadlock.
    private val lock = Any()

    fun update(transform: (UiState) -> UiState) {
        val next: UiState
        val snapshot: List<(UiState) -> Unit>
        synchronized(lock) {
            next = transform(_state.value)
            _state.value = next
            snapshot = listeners.toList()
        }
        snapshot.forEach { it(next) }
    }

    fun addListener(listener: (UiState) -> Unit) {
        val current = synchronized(lock) {
            listeners.add(listener)
            _state.value
        }
        listener(current)
    }

    fun removeListener(listener: (UiState) -> Unit) {
        synchronized(lock) { listeners.remove(listener) }
    }

    fun appendLive(hex: String, label: String, rssi: Int, note: String, address: String = "", isBand: Boolean = false) {
        val canonical = HexUtils.canonicalHex(hex)
        val classified = MagicClassifier.classify(canonical)
        val txHex = classified?.hex ?: canonical
        val dedupeKey = LivePacketSort.liveDedupeKey(hex, classified)
        val now = System.currentTimeMillis()
        val packet = LivePacket(
            hex = txHex,
            label = classified?.label ?: label,
            rssi = rssi,
            note = note,
            category = classified?.category ?: MagicCategory.UNKNOWN,
            typeInfo = classified?.typeInfo ?: "raw",
            dedupeKey = dedupeKey,
            timestampMs = now,
            address = address,
            isBand = isBand,
        )
        val sourcesList = synchronized(lock) {
            if (address.isNotEmpty()) {
                val s = sourceStats.getOrPut(address) { MutSource(0, Int.MIN_VALUE, rssi, now, mutableSetOf()) }
                s.count += 1
                s.lastRssi = rssi
                if (rssi > s.bestRssi) s.bestRssi = rssi
                s.lastSeenMs = now
                s.cats.add(packet.category.name)
            }
            sourcesThrottled(now)
        }
        update {
            val withoutDup = it.livePackets.filter { p -> p.dedupeKey != dedupeKey }
            val addresses = if (address.isEmpty()) {
                it.seenAddresses
            } else {
                val prev = it.seenAddresses.firstOrNull { a -> a.address == address }
                val updated = SeenAddress(
                    address = address,
                    rssi = rssi,
                    lastSeenMs = now,
                    count = (prev?.count ?: 0) + 1,
                )
                (listOf(updated) + it.seenAddresses.filter { a -> a.address != address })
                    .sortedByDescending { a -> a.lastSeenMs }
                    .take(MAX_ADDRESSES)
            }
            // NOTE: do NOT bump storeRevision here. This runs on every received packet, and
            // storeRevision drives `remember(storeRev) { store.read() }` across every tab —
            // bumping it per packet forced a full recomposition/store re-read storm near many
            // bands, grinding the UI and starving the packet pipeline. The library data hasn't
            // changed here; only the live feed has, which Compose observes directly.
            it.copy(
                livePackets = (listOf(packet) + withoutDup).take(MAX_LIVE),
                rawLivePackets = (listOf(packet) + it.rawLivePackets).take(MAX_LIVE),
                seenAddresses = addresses,
                sources = sourcesList,
            )
        }
    }

    private data class MutSource(
        var count: Int,
        var bestRssi: Int,
        var lastRssi: Int,
        var lastSeenMs: Long,
        val cats: MutableSet<String>,
    )
    private val sourceStats = LinkedHashMap<String, MutSource>()
    private val priorityCats = setOf("SHOW", "ANIMATION", "COLOR")
    private var cachedSources: List<SourceStat> = emptyList()
    private var lastSourcesBuildMs = 0L

    /** The Sources panel doesn't need per-packet freshness, and rebuilding it per advert is a
     *  sort + allocation storm. Rebuild at most ~2Hz; reuse the last list in between. */
    private fun sourcesThrottled(now: Long): List<SourceStat> {
        if (cachedSources.isNotEmpty() && now - lastSourcesBuildMs < 500) return cachedSources
        lastSourcesBuildMs = now
        trimSourceStats()
        cachedSources = buildSourcesList()
        return cachedSources
    }

    /** Rotating private addresses mean this map grows without bound in a crowd (only the
     *  OUTPUT was capped before) — evict the stalest entries. */
    private fun trimSourceStats() {
        val over = sourceStats.size - MAX_SOURCE_STATS
        if (over <= 0) return
        sourceStats.entries.sortedBy { it.value.lastSeenMs }.take(over).forEach {
            sourceStats.remove(it.key)
        }
    }

    private fun buildSourcesList(): List<SourceStat> =
        sourceStats.entries.map { (addr, s) ->
            SourceStat(
                address = addr,
                count = s.count,
                bestRssi = s.bestRssi,
                lastRssi = s.lastRssi,
                lastSeenMs = s.lastSeenMs,
                priority = s.cats.any { it in priorityCats },
                categories = s.cats.toSortedSet(),
            )
        }.sortedWith(
            compareByDescending<SourceStat> { it.priority }
                .thenByDescending { it.count }
                .thenByDescending { it.bestRssi },
        ).take(MAX_SOURCES)

    fun clearLive() {
        synchronized(lock) { sourceStats.clear() }
        update { it.copy(livePackets = emptyList(), rawLivePackets = emptyList(), sources = emptyList()) }
    }

    fun removeLive(dedupeKey: String) {
        update {
            it.copy(
                livePackets = it.livePackets.filter { p -> p.dedupeKey != dedupeKey },
                rawLivePackets = it.rawLivePackets.filter { p -> p.dedupeKey != dedupeKey },
            )
        }
    }

    fun removeRawLive(timestampMs: Long, hex: String) {
        update {
            it.copy(
                rawLivePackets = it.rawLivePackets.filterNot { p ->
                    p.timestampMs == timestampMs && p.hex == hex
                },
            )
        }
    }

    /** Bumps storeRevision so Compose tabs re-read MagicStore after local edits (auto rules, etc.). */
    fun bumpStoreRevision() {
        update { it.copy(storeRevision = it.storeRevision + 1) }
    }

    fun statusJson(): JSONObject = JSONObject().apply {
        put("running", _state.value.running)
        put("status", _state.value.status)
        put("relayMode", _state.value.relayMode.name)
        put("relayLinked", _state.value.relayLinked)
        put("hotspotSsid", _state.value.hotspotSsid)
        put("hotspotPassword", _state.value.hotspotPassword)
        put("relayIp", _state.value.relayIp)
        put("httpPort", _state.value.httpPort)
        put("scanActive", _state.value.scanActive)
        put("autoEnabled", _state.value.autoEnabled)
        put("recordSessionActive", _state.value.recordSessionActive)
        put("activeSessionName", _state.value.activeSessionName)
        put("packetsHeard", _state.value.packetsHeard)
        put("autoResponsesSent", _state.value.autoResponsesSent)
        put("lastHeardHex", _state.value.lastHeardHex)
        put("lastHeardLabel", _state.value.lastHeardLabel)
        put("lastTransmitHex", _state.value.lastTransmitHex)
        put("starlightLoopEnabled", _state.value.starlightLoopEnabled)
        put("starlightLoopLabel", _state.value.starlightLoopLabel)
        put("starlightLoopPacketId", _state.value.starlightLoopPacketId)
        put("starlightIntervalMs", _state.value.starlightIntervalMs)
        put("txLoopEnabled", _state.value.txLoopEnabled)
        put("txLoopPacketId", _state.value.txLoopPacketId)
        put("txLoopIntervalMs", _state.value.txLoopIntervalMs)
        put("txLoopLabel", _state.value.txLoopLabel)
        put("wandDisplayColorIndex", _state.value.wandDisplayColorIndex)
        put("wakeupPreambleMs", _state.value.wakeupPreambleMs)
        put("commandBurstMs", _state.value.commandBurstMs)
        put("starlightBurstMs", _state.value.starlightBurstMs)
        put("storeRevision", _state.value.storeRevision)
    }

    fun liveJson(): JSONObject = RelayCommands.livePacketsJson(
        _state.value.rawLivePackets.map { p ->
            RelayCommands.LivePacketDto(
                hex = p.hex,
                label = p.label,
                rssi = p.rssi,
                note = p.note,
                category = p.category.name,
                typeInfo = p.typeInfo,
                dedupeKey = p.dedupeKey,
                timestampMs = p.timestampMs,
            )
        },
    )
}
