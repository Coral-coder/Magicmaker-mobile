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
        val starlightLoopEnabled: Boolean = false,
        val starlightLoopPacketId: Long = -1L,
        val starlightIntervalMs: Long = 3000L,
        val starlightLoopLabel: String = "none",
        val txLoopEnabled: Boolean = false,
        val txLoopPacketId: Long = -1L,
        val txLoopIntervalMs: Long = 3000L,
        val txLoopLabel: String = "none",
        val wandDisplayColorIndex: Int = 0x1B,
        val wakeupPreambleMs: Int = 520,
        val commandBurstMs: Int = TransmitTiming.COMMAND_BURST_MS,
        val starlightBurstMs: Int = TransmitTiming.STARLIGHT_BURST_MS,
        val relayLinked: Boolean = false,
    )

    private const val MAX_LIVE = 120

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    private val listeners = mutableSetOf<(UiState) -> Unit>()

    fun update(transform: (UiState) -> UiState) {
        val next = transform(_state.value)
        _state.value = next
        listeners.forEach { it(next) }
    }

    fun addListener(listener: (UiState) -> Unit) {
        listener(_state.value)
        listeners.add(listener)
    }

    fun removeListener(listener: (UiState) -> Unit) {
        listeners.remove(listener)
    }

    fun appendLive(hex: String, label: String, rssi: Int, note: String) {
        val canonical = HexUtils.canonicalHex(hex)
        val classified = MagicClassifier.classify(canonical)
        val txHex = classified?.hex ?: canonical
        val dedupeKey = LivePacketSort.liveDedupeKey(hex, classified)
        val packet = LivePacket(
            hex = txHex,
            label = classified?.label ?: label,
            rssi = rssi,
            note = note,
            category = classified?.category ?: MagicCategory.UNKNOWN,
            typeInfo = classified?.typeInfo ?: "raw",
            dedupeKey = dedupeKey,
        )
        update {
            val withoutDup = it.livePackets.filter { p -> p.dedupeKey != dedupeKey }
            it.copy(
                livePackets = (listOf(packet) + withoutDup).take(MAX_LIVE),
                rawLivePackets = (listOf(packet) + it.rawLivePackets).take(MAX_LIVE),
                storeRevision = it.storeRevision + 1,
            )
        }
    }

    fun clearLive() {
        update { it.copy(livePackets = emptyList(), rawLivePackets = emptyList()) }
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
