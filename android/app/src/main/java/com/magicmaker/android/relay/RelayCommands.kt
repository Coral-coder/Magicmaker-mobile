package com.magicmaker.android.relay

import com.magicmaker.android.core.AutoResponseRule
import com.magicmaker.android.core.HexUtils
import com.magicmaker.android.core.MagicPacket
import com.magicmaker.android.core.PacketBuilder
import com.magicmaker.android.core.PresetCatalog
import org.json.JSONArray
import org.json.JSONObject

/** Shared JSON command protocol for iPhone → Android remote control (HTTP + BLE GATT). */
object RelayCommands {
    data class Handlers(
        val transmit: (hex: String) -> Unit,
        val vibrate: () -> Unit,
        val interrogate: () -> Unit,
        val setScan: (Boolean) -> Unit,
        val setAuto: (Boolean) -> Unit,
        val setRecording: (Boolean) -> Unit,
        val clearLive: () -> Unit,
        val setStarlightLoop: (enabled: Boolean, packetId: Long?, intervalMs: Long?) -> Unit,
        val setTxLoop: (enabled: Boolean, packetId: Long?, intervalMs: Long?) -> Unit,
        val setWakeupPreamble: (Int) -> Unit,
        val setCommandBurst: (Int) -> Unit,
        val setStarlightBurst: (Int) -> Unit,
        val saveCustomPreset: (String, String) -> Unit,
        val removeLive: (String) -> Unit,
        val removeRawLive: (Long, String) -> Unit,
        val deleteWandColor: (Long) -> Unit,
        val clearWandLibrary: () -> Unit,
        val addAutoRule: (name: String, triggerId: String, responseIds: List<String>, responseHexes: List<String>) -> Unit,
        val deleteAutoRule: (Long) -> Unit,
        val setAutoRuleEnabled: (Long, Boolean) -> Unit,
        val catalogJson: () -> JSONObject,
        val statusJson: () -> JSONObject,
        val liveJson: () -> JSONObject,
        val pairingJson: () -> JSONObject,
        val mbleTap: (tokenHex: String, durationMs: Int) -> Unit,
        /** Keep-awake: pause scanning, stream a wake ping, sends go out without a preamble. */
        val setKeepAwake: (enabled: Boolean, hex: String?) -> Unit = { _, _ -> },
        /** Radio and scan-filter settings the iPhone's Settings tab drives on this phone. */
        val setTxPower: (level: Int) -> Unit = { },
        val setTxInterleave: (Boolean) -> Unit = { },
        val setShowControlOnly: (Boolean) -> Unit = { },
    )

    fun execute(body: JSONObject, handlers: Handlers): JSONObject {
        return try {
            when (body.optString("action", "").lowercase()) {
                "transmit", "tx" -> {
                    val hex = body.getString("hex")
                    handlers.transmit(hex)
                    ok().put("hex", hex)
                }
                "keep_awake", "keepawake" -> {
                    val enabled = body.optBoolean("enabled", false)
                    val hex = body.optString("hex", "").ifBlank { null }
                    handlers.setKeepAwake(enabled, hex)
                    ok().put("enabled", enabled)
                }
                "vibrate", "vib" -> {
                    handlers.vibrate()
                    ok()
                }
                "interrogate", "ping", "wakeup" -> {
                    handlers.interrogate()
                    ok().put("hex", PacketBuilder.WAKEUP_PING)
                }
                "set_scan", "scan" -> {
                    val enabled = body.optBoolean("enabled", true)
                    handlers.setScan(enabled)
                    ok().put("enabled", enabled)
                }
                "set_auto", "auto" -> {
                    handlers.setAuto(body.optBoolean("enabled", true))
                    ok().put("enabled", body.optBoolean("enabled", true))
                }
                "set_recording", "record", "log" -> {
                    handlers.setRecording(body.optBoolean("enabled", true))
                    ok().put("enabled", body.optBoolean("enabled", true))
                }
                "clear_live", "clear" -> {
                    handlers.clearLive()
                    ok()
                }
                "set_starlight_loop", "wand_loop" -> {
                    val enabled = body.optBoolean("enabled", false)
                    val packetId = if (body.has("packetId")) body.getLong("packetId") else null
                    val intervalMs = if (body.has("intervalMs")) body.getLong("intervalMs") else null
                    handlers.setStarlightLoop(enabled, packetId, intervalMs)
                    ok().put("enabled", enabled)
                }
                "set_tx_loop", "tx_loop", "repeat_tx" -> {
                    val enabled = body.optBoolean("enabled", false)
                    val packetId = if (body.has("packetId")) body.getLong("packetId") else null
                    val intervalMs = if (body.has("intervalMs")) body.getLong("intervalMs") else null
                    handlers.setTxLoop(enabled, packetId, intervalMs)
                    ok().put("enabled", enabled)
                }
                "set_wakeup_preamble", "preamble" -> {
                    val ms = body.optInt("ms", body.optInt("preambleMs", 520))
                    handlers.setWakeupPreamble(ms)
                    ok().put("ms", ms)
                }
                "set_command_burst", "command_burst", "burst" -> {
                    val ms = body.optInt("ms", body.optInt("burstMs", 2000))
                    handlers.setCommandBurst(ms)
                    ok().put("ms", ms)
                }
                "set_starlight_burst", "starlight_burst", "wand_burst" -> {
                    val ms = body.optInt("ms", body.optInt("burstMs", com.magicmaker.android.core.TransmitTiming.STARLIGHT_BURST_MS))
                    handlers.setStarlightBurst(ms)
                    ok().put("ms", ms)
                }
                "set_tx_power", "tx_power" -> {
                    val level = body.optInt("level", 3).coerceIn(0, 3)
                    handlers.setTxPower(level)
                    ok().put("level", level)
                }
                "set_tx_interleave", "tx_interleave" -> {
                    val enabled = body.optBoolean("enabled", false)
                    handlers.setTxInterleave(enabled)
                    ok().put("enabled", enabled)
                }
                "set_show_control_only", "show_control_only" -> {
                    val enabled = body.optBoolean("enabled", true)
                    handlers.setShowControlOnly(enabled)
                    ok().put("enabled", enabled)
                }
                "save_custom_preset", "add_tx_preset", "save_preset" -> {
                    val label = body.optString("label", "Remote preset")
                    val hex = body.getString("hex")
                    handlers.saveCustomPreset(label, hex)
                    ok().put("label", label).put("hex", hex)
                }
                "remove_live" -> {
                    val dedupeKey = body.getString("dedupeKey")
                    handlers.removeLive(dedupeKey)
                    ok().put("dedupeKey", dedupeKey)
                }
                "remove_raw_live" -> {
                    val timestampMs = body.getLong("timestampMs")
                    val hex = body.getString("hex")
                    handlers.removeRawLive(timestampMs, hex)
                    ok().put("timestampMs", timestampMs).put("hex", hex)
                }
                "delete_wand_color", "delete_wand" -> {
                    handlers.deleteWandColor(body.getLong("packetId"))
                    ok()
                }
                "clear_wand_library", "clear_wand" -> {
                    handlers.clearWandLibrary()
                    ok()
                }
                "add_auto_rule" -> {
                    val name = body.optString("name", "Remote rule")
                    val triggerId = body.getString("triggerPatternId")
                    val responseIds = jsonStringList(body.optJSONArray("responsePatternIds"))
                    val responseHexes = jsonStringList(body.optJSONArray("responseHexes"))
                    handlers.addAutoRule(name, triggerId, responseIds, responseHexes)
                    ok()
                }
                "delete_auto_rule" -> {
                    handlers.deleteAutoRule(body.getLong("ruleId"))
                    ok()
                }
                "set_auto_rule", "auto_rule" -> {
                    handlers.setAutoRuleEnabled(body.getLong("ruleId"), body.optBoolean("enabled", true))
                    ok().put("enabled", body.optBoolean("enabled", true))
                }
                "catalog" -> handlers.catalogJson().put("ok", true)
                "catalog_sync_begin", "catalog_begin", "sync_begin" -> {
                    val cat = handlers.catalogJson()
                    CatalogSync.buildBegin(cat, handlers.statusJson().optInt("storeRevision", 0))
                }
                "catalog_sync_chunk", "catalog_chunk", "sync_chunk" -> {
                    val section = body.optString("section", "tx")
                    val index = body.optInt("index", 0)
                    CatalogSync.buildChunk(handlers.catalogJson(), section, index)
                }
                "status" -> handlers.statusJson().put("ok", true)
                "live" -> handlers.liveJson().put("ok", true)
                "pairing", "pairing_info" -> handlers.pairingJson().put("ok", true)
                "mble_tap", "mble", "tap" -> {
                    val token = body.getString("token")
                    val duration = body.optInt("durationMs", 5000)
                    handlers.mbleTap(token, duration)
                    ok().put("token", token).put("durationMs", duration)
                }
                else -> error("Unknown action: ${body.optString("action")}")
            }
        } catch (e: Exception) {
            error(e.message ?: "Command failed")
        }
    }

    fun buildCatalog(
        transmitPresets: List<MagicPacket>,
        wandColors: List<MagicPacket>,
        autoRules: List<AutoResponseRule>,
        wakeupPreambleMs: Int,
        commandBurstMs: Int,
        starlightBurstMs: Int = com.magicmaker.android.core.TransmitTiming.STARLIGHT_BURST_MS,
    ): JSONObject = JSONObject().apply {
        val mergedTx = mergedTransmitPresets(transmitPresets)
        put("wakeupPreambleMs", wakeupPreambleMs)
        put("commandBurstMs", commandBurstMs)
        put("starlightBurstMs", starlightBurstMs)
        put("presetCount", mergedTx.size)
        put("transmitPresets", JSONArray().apply { mergedTx.forEach { put(packetJson(it)) } })
        put("wandColors", JSONArray().apply { wandColors.forEach { put(packetJson(it)) } })
        put("autoRules", JSONArray().apply { autoRules.forEach { put(ruleJson(it)) } })
    }

    /** Store packets first; always include built-in PresetCatalog entries missing from store. */
    private fun mergedTransmitPresets(storePackets: List<MagicPacket>): List<MagicPacket> {
        val seen = LinkedHashSet<String>()
        val out = mutableListOf<MagicPacket>()
        for (packet in storePackets) {
            val key = HexUtils.canonicalHex(packet.hex)
            if (seen.add(key)) out.add(packet)
        }
        for (packet in PresetCatalog.asMagicPackets()) {
            val key = HexUtils.canonicalHex(packet.hex)
            if (seen.add(key)) out.add(packet)
        }
        return out
    }

    fun packetJson(p: MagicPacket): JSONObject = JSONObject()
        .put("id", p.id)
        .put("hex", p.hex)
        .put("label", p.label)
        .put("category", p.category.name)
        .put("typeInfo", p.typeInfo)
        .put("colors", p.colors)
        .put("userRecorded", p.userRecorded)
        .put("wandVerified", p.wandVerified)

    fun ruleJson(r: AutoResponseRule): JSONObject = JSONObject().apply {
        put("id", r.id)
        put("name", r.name)
        put("triggerPatternId", r.triggerPatternId)
        put("responsePatternId", r.responsePatternId)
        put("enabled", r.enabled)
        put("responseHexes", JSONArray().apply { r.responseHexes.forEach { put(it) } })
    }

    fun parseBody(text: String): JSONObject? {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return null
        return if (trimmed.startsWith("{")) JSONObject(trimmed) else null
    }

    private fun jsonStringList(arr: JSONArray?): List<String> {
        if (arr == null) return emptyList()
        return buildList {
            for (i in 0 until arr.length()) {
                arr.optString(i)?.takeIf { it.isNotEmpty() }?.let { add(it) }
            }
        }
    }

    private fun ok() = JSONObject().put("ok", true)

    private fun error(msg: String?) = JSONObject().put("ok", false).put("error", msg ?: "error")

    fun livePacketsJson(packets: List<LivePacketDto>): JSONObject =
        JSONObject().put(
            "packets",
            JSONArray().apply {
                packets.forEach { p ->
                    put(
                        JSONObject()
                            .put("hex", p.hex)
                            .put("label", p.label)
                            .put("rssi", p.rssi)
                            .put("note", p.note)
                            .put("category", p.category)
                            .put("typeInfo", p.typeInfo)
                            .put("dedupeKey", p.dedupeKey)
                            .put("timestampMs", p.timestampMs),
                    )
                }
            },
        )

    data class LivePacketDto(
        val hex: String,
        val label: String,
        val rssi: Int,
        val note: String,
        val category: String,
        val typeInfo: String,
        val dedupeKey: String,
        val timestampMs: Long,
    )
}
