package com.magicmaker.android.data

import android.content.Context
import com.google.gson.Gson
import com.google.gson.GsonBuilder
import com.magicmaker.android.core.*
import com.magicmaker.android.service.MagicMakerForegroundService
import com.magicmaker.android.service.ServiceState
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class ScanSessionFile(val path: String, val name: String)

class MagicStore(context: Context) {
    private val appContext = context.applicationContext
    private val gson: Gson = GsonBuilder().setPrettyPrinting().create()
    private val prefs = appContext.getSharedPreferences("magicmaker", Context.MODE_PRIVATE)

    private val documentsDir = appContext.filesDir
    private val sessionsDir = File(documentsDir, "scan_sessions").also { it.mkdirs() }
    private val storeFile = File(documentsDir, "magicmaker_store.json")

    var presets: List<MagicPacket> = emptyList()
        private set
    var learnedColors: List<MagicPacket> = emptyList()
        private set
    var learnedLibrary: List<MagicPacket> = emptyList()
        private set
    var learnedRaw: List<MagicPacket> = emptyList()
        private set
    var recordings: List<Recording> = emptyList()
        private set
    var autoRules: List<AutoResponseRule> = emptyList()
        private set
    var scanSessions: List<ScanSessionFile> = emptyList()
        private set

    private var nextPacketId = 1L
    private var nextRecordingId = 1L
    private var nextRuleId = 1L
    private var activeSessionFile: File? = null

    val allLearnedPackets: List<MagicPacket>
        get() = learnedColors + learnedLibrary + learnedRaw

    val customPresets: List<MagicPacket>
        get() = presets.filter { it.userRecorded }

    /** Presets + learned library, deduped by canonical hex (presets win). */
    fun allTransmitPackets(): List<MagicPacket> {
        val seen = LinkedHashSet<String>()
        val out = mutableListOf<MagicPacket>()
        for (packet in presets + allLearnedPackets) {
            val key = HexUtils.canonicalHex(packet.hex)
            if (seen.add(key)) out.add(packet)
        }
        return out
    }

    data class PersistedState(
        val presets: List<MagicPacket> = emptyList(),
        val learnedColors: List<MagicPacket> = emptyList(),
        val learnedLibrary: List<MagicPacket> = emptyList(),
        val learnedRaw: List<MagicPacket>? = null,
        val recordings: List<Recording> = emptyList(),
        val autoRules: List<AutoResponseRule> = emptyList(),
        val nextPacketId: Long = 1,
        val nextRecordingId: Long = 1,
        val nextRuleId: Long = 1,
        val starlightSerial: String = StarlightSerial.DEFAULT_SERIAL,
        val labHex: String = PacketBuilder.WAKEUP_PING,
        val labLabel: String = "",
    )

    init {
        load()
        if (presets.isEmpty()) {
            presets = PresetCatalog.asMagicPackets().mapIndexed { index, packet ->
                packet.copy(id = index + 1L)
            }
            nextPacketId = presets.size + 1L
            save()
        } else {
            mergeBuiltInPresets()
        }
        refreshSessions()
    }

    private fun mergeBuiltInPresets() {
        val built = PresetCatalog.asMagicPackets()
        val knownHex = presets.map { it.hex.uppercase() }.toSet()
        val additions = built.filter { it.hex.uppercase() !in knownHex }
        if (additions.isEmpty()) return
        presets = presets + additions.map { p ->
            p.copy(id = nextPacketId++)
        }
        save()
    }

    fun load() {
        if (!storeFile.exists()) return
        runCatching {
            gson.fromJson(storeFile.readText(), PersistedState::class.java)
        }.onSuccess { state ->
            presets = state.presets
            learnedColors = state.learnedColors
            learnedLibrary = state.learnedLibrary
            learnedRaw = state.learnedRaw ?: emptyList()
            recordings = state.recordings
            autoRules = state.autoRules
            nextPacketId = state.nextPacketId
            nextRecordingId = state.nextRecordingId
            nextRuleId = state.nextRuleId
            prefs.edit()
                .putString("starlight_serial", state.starlightSerial)
                .putString("lab_hex", state.labHex)
                .putString("lab_label", state.labLabel)
                .apply()
        }
    }

    @Synchronized
    fun save() {
        val state = PersistedState(
            presets, learnedColors, learnedLibrary, learnedRaw, recordings, autoRules,
            nextPacketId, nextRecordingId, nextRuleId,
            getStarlightSerial(), getLabHex(), getLabLabel(),
        )
        storeFile.writeText(gson.toJson(state))
    }

    fun packetsFor(category: MagicCategory): List<MagicPacket> = when (category) {
        MagicCategory.COLOR -> learnedColors
        MagicCategory.SHOW -> presets.filter { it.category == MagicCategory.SHOW } +
            learnedLibrary.filter { it.category == MagicCategory.SHOW }
        MagicCategory.ANIMATION -> presets.filter { it.category == MagicCategory.ANIMATION } +
            learnedLibrary.filter { it.category == MagicCategory.ANIMATION }
        MagicCategory.UNKNOWN -> learnedRaw
    }

    fun getStarlightSerial() = prefs.getString("starlight_serial", StarlightSerial.DEFAULT_SERIAL)!!

    fun learnedStarlightPackets(): List<MagicPacket> =
        learnedColors.filter { it.typeInfo == "starlight" }.sortedBy { it.label }

    fun findLearnedStarlight(id: Long): MagicPacket? =
        learnedColors.firstOrNull { it.id == id && it.typeInfo == "starlight" }

    fun findTransmitPacket(id: Long): MagicPacket? =
        allTransmitPackets().firstOrNull { it.id == id }
    fun getLabHex() = prefs.getString("lab_hex", PacketBuilder.WAKEUP_PING)!!
    fun getLabLabel() = prefs.getString("lab_label", "") ?: ""

    fun getWakeupPreambleMs(): Int =
        prefs.getInt("wakeup_preamble_ms", TransmitTiming.DEFAULT_WAKEUP_PRELUDE_MS)
            .coerceIn(200, 1500)

    fun saveWakeupPreambleMs(ms: Int) {
        prefs.edit().putInt("wakeup_preamble_ms", ms.coerceIn(200, 1500)).apply()
    }

    fun getCommandBurstMs(): Int =
        prefs.getInt("command_burst_ms", TransmitTiming.COMMAND_BURST_MS)
            .coerceIn(TransmitTiming.MIN_COMMAND_BURST_MS, TransmitTiming.MAX_COMMAND_BURST_MS)

    fun saveCommandBurstMs(ms: Int) {
        prefs.edit().putInt(
            "command_burst_ms",
            ms.coerceIn(TransmitTiming.MIN_COMMAND_BURST_MS, TransmitTiming.MAX_COMMAND_BURST_MS),
        ).apply()
    }

    fun getStarlightBurstMs(): Int =
        prefs.getInt("starlight_burst_ms", TransmitTiming.STARLIGHT_BURST_MS)
            .coerceIn(TransmitTiming.MIN_STARLIGHT_BURST_MS, TransmitTiming.MAX_STARLIGHT_BURST_MS)

    fun saveStarlightBurstMs(ms: Int) {
        prefs.edit().putInt(
            "starlight_burst_ms",
            ms.coerceIn(TransmitTiming.MIN_STARLIGHT_BURST_MS, TransmitTiming.MAX_STARLIGHT_BURST_MS),
        ).apply()
    }

    fun applyLabLabelToMatchingRaw() {
        val hex = HexUtils.canonicalHex(getLabHex())
        val tag = getLabLabel().trim()
        if (tag.isEmpty()) return
        val idx = learnedRaw.indexOfFirst { HexUtils.canonicalHex(it.hex) == hex }
        if (idx < 0) return
        learnedRaw = learnedRaw.toMutableList().also { it[idx] = it[idx].copy(label = tag) }
        save()
        ServiceState.bumpStoreRevision()
    }

    /** Save lab hex as a user preset — available in TX tab and Auto response stack. */
    @Synchronized
    fun saveCustomPreset(label: String, hex: String): String? {
        val canonical = HexUtils.canonicalHex(hex)
        HexUtils.legacyAdvertiseRejectReason(canonical)?.let { return it }
        if (!HexUtils.isDisneyBlePacket(canonical)) return "Invalid Disney packet"

        val displayLabel = label.trim().ifEmpty {
            MagicClassifier.classify(canonical)?.label ?: rawPacketLabel(canonical)
        }
        val classified = MagicClassifier.classify(canonical)
        val packet = if (classified != null) {
            classified.toPacket(userRecorded = true).copy(
                id = nextPacketId++,
                label = displayLabel,
                userRecorded = true,
            )
        } else {
            MagicPacket(
                id = nextPacketId++,
                hex = canonical,
                label = displayLabel,
                category = MagicCategory.UNKNOWN,
                typeInfo = "raw",
                colors = "",
                simKey = "USER:$canonical",
                userRecorded = true,
            )
        }

        presets = presets.filter { !(it.userRecorded && HexUtils.canonicalHex(it.hex) == canonical) } + packet
        saveLabHex(canonical)
        saveLabLabel(displayLabel)
        save()
        ServiceState.bumpStoreRevision()
        return null
    }

    @Synchronized
    fun deleteCustomPreset(id: Long) {
        val target = presets.firstOrNull { it.id == id && it.userRecorded } ?: return
        presets = presets.filter { it.id != target.id }
        save()
        ServiceState.bumpStoreRevision()
    }

    @Synchronized
    fun recategorizePacket(id: Long, category: MagicCategory) {
        fun updateList(list: List<MagicPacket>): List<MagicPacket> =
            list.map { if (it.id == id) it.copy(category = category) else it }

        when {
            learnedColors.any { it.id == id } -> learnedColors = updateList(learnedColors)
            learnedLibrary.any { it.id == id } -> learnedLibrary = updateList(learnedLibrary)
            learnedRaw.any { it.id == id } -> learnedRaw = updateList(learnedRaw)
            presets.any { it.id == id } -> presets = updateList(presets)
            else -> return
        }
        save()
        ServiceState.bumpStoreRevision()
    }

    @Synchronized
    fun deletePacketById(id: Long) {
        when {
            presets.any { it.id == id && it.userRecorded } -> deleteCustomPreset(id)
            learnedColors.any { it.id == id } -> deleteLearnedColor(id)
            learnedLibrary.any { it.id == id } -> deleteLearnedLibrary(id)
            learnedRaw.any { it.id == id } -> deleteLearnedRaw(id)
        }
    }

    fun saveLabHex(hex: String) {
        prefs.edit().putString("lab_hex", hex.uppercase()).apply()
        save()
    }

    fun saveLabLabel(label: String) {
        prefs.edit().putString("lab_label", label).apply()
        save()
    }

    fun loadIntoLab(hex: String, label: String = "") {
        saveLabHex(hex)
        saveLabLabel(label)
    }

    @Synchronized
    fun processHeardPacket(hex: String, rssi: Int, persistToSession: Boolean): RecordEvent? {
        val canonical = HexUtils.canonicalHex(hex)
        if (!HexUtils.isDisneyBlePacket(canonical)) return null

        val classified = MagicClassifier.classify(canonical)
        val event = if (classified != null) {
            addClassifiedToLibrary(classified, rawHex = hex, rssi = rssi).also {
                if (persistToSession) persistRecording(classified, rssi, it.reason)
            }
        } else {
            hearRawPacket(canonical, rssi).also {
                if (persistToSession) {
                    persistRecording(
                        ClassifiedPacket(canonical, it.packet.label, MagicCategory.UNKNOWN, "raw", "", it.packet.simKey),
                        rssi, it.reason,
                    )
                }
            }
        }
        return event
    }

    private fun addClassifiedToLibrary(classified: ClassifiedPacket, rawHex: String, rssi: Int): RecordEvent =
        when (classified.category) {
            MagicCategory.COLOR -> if (classified.typeInfo == "starlight") {
                addStarlightToLibrary(classified, rssi, rawHex)
            } else {
                addColorToLibrary(classified, rssi)
            }
            MagicCategory.SHOW, MagicCategory.ANIMATION -> addShowAnimToLibrary(classified, rssi)
            MagicCategory.UNKNOWN -> hearRawPacket(classified.hex, rssi, classified.label)
        }

    /** Raw / unclassified packets appear in scan and record sessions only — not the library. */
    private fun hearRawPacket(hex: String, rssi: Int, label: String? = null): RecordEvent {
        val canonical = HexUtils.canonicalHex(hex)
        val packet = MagicPacket(
            id = 0,
            hex = canonical,
            label = label ?: rawPacketLabel(canonical),
            category = MagicCategory.UNKNOWN,
            typeInfo = "raw",
            simKey = "RAW:$canonical",
            userRecorded = false,
            rssi = rssi,
        )
        return RecordEvent(packet, false, "Heard raw (not saved to library)")
    }

    private fun addStarlightToLibrary(classified: ClassifiedPacket, rssi: Int, rawHex: String): RecordEvent {
        val canonical = HexUtils.canonicalHex(rawHex)
        val colorIdx = MagicClassifier.starlightLearnColorIndex(canonical)
        if (colorIdx == null) {
            val preview = libraryPacketFrom(classified, rawHex)
            return RecordEvent(preview, false, "Heard ${preview.colors} (unrecognized wand format)")
        }
        val stored = libraryPacketFrom(classified, rawHex)
        val key = stored.simKey
        if (learnedColors.any { it.typeInfo == "starlight" && it.simKey == key }) {
            updateLearnedColor(stored, verified = true)
            return RecordEvent(stored, false, "Verified ${stored.colors}")
        }
        val packet = stored.copy(id = nextPacketId++)
        learnedColors = learnedColors + packet
        save()
        ServiceState.bumpStoreRevision()
        return RecordEvent(packet, true, "Learned ${packet.colors} → Wand")
    }

    private fun addColorToLibrary(classified: ClassifiedPacket, rssi: Int): RecordEvent {
        if (isDuplicateOfPreset(classified)) {
            return RecordEvent(classified.toPacket(), false, "Recorded (built-in color)")
        }
        val key = MagicClassifier.libraryDedupeKey(classified)
        learnedColors.firstOrNull { MagicClassifier.libraryDedupeKey(it.toClassified()) == key }?.let {
            return RecordEvent(it, false, "Verified ${classified.colors}")
        }
        val packet = classified.toPacket(userRecorded = true).copy(id = nextPacketId++)
        learnedColors = learnedColors + packet
        save()
        return RecordEvent(packet, true, "Learned ${packet.colors} → Colors")
    }

    private fun addShowAnimToLibrary(classified: ClassifiedPacket, rssi: Int): RecordEvent {
        val key = MagicClassifier.libraryDedupeKey(classified)
        learnedLibrary.firstOrNull { MagicClassifier.libraryDedupeKey(it.toClassified()) == key }?.let { existing ->
            val updated = existing.copy(hex = classified.hex, label = classified.label)
            if (updated != existing) {
                learnedLibrary = learnedLibrary.map { if (it.id == existing.id) updated else it }
                    .sortedBy { it.label.lowercase() }
                save()
                ServiceState.bumpStoreRevision()
            }
            return RecordEvent(updated, false, "Verified ${classified.label}")
        }
        val packet = classified.toPacket(userRecorded = true).copy(id = nextPacketId++)
        learnedLibrary = (learnedLibrary + packet).sortedBy { it.label.lowercase() }
        save()
        ServiceState.bumpStoreRevision()
        val section = when {
            classified.label.contains("Show Control", ignoreCase = true) -> "Control"
            classified.category == MagicCategory.SHOW -> "Shows"
            else -> "Anim"
        }
        val note = if (isDuplicateOfPreset(classified)) {
            "Learned ${classified.label} → $section (heard confirmed)"
        } else {
            "Learned ${classified.label} → $section"
        }
        return RecordEvent(packet, true, note)
    }

    private fun rawPacketLabel(hex: String): String {
        val h = HexUtils.canonicalHex(hex)
        return if (h.length <= 20) "Raw: $h" else "Raw: ${h.take(16)}…${h.takeLast(4)}"
    }

    private fun isDuplicateOfPreset(classified: ClassifiedPacket): Boolean {
        val key = MagicClassifier.libraryDedupeKey(classified)
        return presets.any { MagicClassifier.libraryDedupeKey(it.toClassified()) == key }
    }

    private fun libraryPacketFrom(classified: ClassifiedPacket, rawHex: String): MagicPacket {
        if (classified.typeInfo == "starlight") {
            val canonical = HexUtils.canonicalHex(rawHex)
            StarlightSerial.extractSerial(canonical)?.let { heard ->
                StarlightSerial.normalizeSerial(heard)?.let { valid ->
                    prefs.edit().putString("starlight_serial", valid).apply()
                }
            }
            return MagicPacket(
                hex = classified.hex,
                label = classified.label,
                category = MagicCategory.COLOR,
                typeInfo = "starlight",
                colors = classified.colors,
                simKey = classified.simKey,
                userRecorded = true,
                wandVerified = StarlightSerial.extractSerial(canonical) != null,
            )
        }
        return classified.toPacket(userRecorded = true)
    }

    private fun updateLearnedColor(packet: MagicPacket, verified: Boolean) {
        val idx = learnedColors.indexOfFirst { it.typeInfo == "starlight" && it.simKey == packet.simKey }
        if (idx >= 0) {
            learnedColors = learnedColors.toMutableList().also {
                it[idx] = it[idx].copy(
                    hex = packet.hex,
                    label = packet.label,
                    colors = packet.colors,
                    wandVerified = verified || it[idx].wandVerified,
                )
            }
            save()
            ServiceState.bumpStoreRevision()
        }
    }

    private fun persistRecording(classified: ClassifiedPacket, rssi: Int, note: String) {
        if (activeSessionFile == null) beginScanSession()
        val rec = Recording(
            id = nextRecordingId++,
            timestampMs = System.currentTimeMillis(),
            hex = classified.hex,
            rssi = rssi,
            label = classified.label,
            category = classified.category,
            typeInfo = classified.typeInfo,
            colors = classified.colors,
            libraryNote = note,
        )
        recordings = listOf(rec) + recordings
        appendToSession(rec)
        save()
    }

    fun findAutoResponses(classified: ClassifiedPacket, rawHex: String): List<String>? {
        val learned = allLearnedPackets
        val userPresets = customPresets
        for (rule in autoRules.filter { it.enabled }) {
            if (PacketPatterns.matchesTriggerId(rule.triggerPatternId, classified, rawHex, userPresets, learned)) {
                val hexes = PacketPatterns.resolveResponseHexes(rule, userPresets, learned)
                if (hexes.isNotEmpty()) return hexes
            }
        }
        return null
    }

    @Synchronized
    fun addAutoRule(
        name: String,
        triggerId: String,
        responseIds: List<String>,
        responseHexes: List<String>,
    ) {
        val ids = responseIds.ifEmpty { listOf("resp_vibrate") }
        val hexes = responseHexes.ifEmpty { listOf(PacketBuilder.vibrateBand()) }
        autoRules = autoRules + AutoResponseRule(
            nextRuleId++,
            name,
            triggerId,
            ids.first(),
            hexes.first(),
            hexes,
            true,
        )
        save()
        ServiceState.bumpStoreRevision()
        MagicMakerForegroundService.refreshRelayCache(appContext)
    }

    @Synchronized
    fun setAutoRuleEnabled(id: Long, enabled: Boolean) {
        val idx = autoRules.indexOfFirst { it.id == id }
        if (idx < 0 || autoRules[idx].enabled == enabled) return
        autoRules = autoRules.toMutableList().also { it[idx] = it[idx].copy(enabled = enabled) }
        save()
        ServiceState.bumpStoreRevision()
        MagicMakerForegroundService.refreshRelayCache(appContext)
    }

    @Synchronized
    fun deleteAutoRule(id: Long) {
        autoRules = autoRules.filter { it.id != id }
        save()
        ServiceState.bumpStoreRevision()
        MagicMakerForegroundService.refreshRelayCache(appContext)
    }

    @Synchronized
    fun deleteLearnedColor(id: Long) {
        learnedColors = learnedColors.filter { it.id != id }
        save()
        ServiceState.bumpStoreRevision()
    }

    @Synchronized
    fun deleteLearnedLibrary(id: Long) {
        learnedLibrary = learnedLibrary.filter { it.id != id }
        save()
        ServiceState.bumpStoreRevision()
    }

    @Synchronized
    fun deleteLearnedRaw(id: Long) {
        learnedRaw = learnedRaw.filter { it.id != id }
        save()
        ServiceState.bumpStoreRevision()
    }

    @Synchronized
    fun clearLearnedStarlight() {
        learnedColors = learnedColors.filter { it.typeInfo != "starlight" }
        save()
        ServiceState.bumpStoreRevision()
    }

    @Synchronized
    fun beginScanSession(): File {
        val name = "scan_${SimpleDateFormat("yyyy-MM-dd'T'HH-mm-ss", Locale.US).format(Date())}.csv"
        val file = File(sessionsDir, name)
        file.writeText("timestamp_ms,hex,rssi,label,category,type_info,colors,note\n")
        activeSessionFile = file
        refreshSessions()
        return file
    }

    @Synchronized
    fun endScanSession(): String? {
        val name = activeSessionFile?.name
        activeSessionFile = null
        refreshSessions()
        return name
    }

    fun refreshSessions() {
        scanSessions = sessionsDir.listFiles()
            ?.filter { it.extension == "csv" }
            ?.sortedByDescending { it.name }
            ?.map { ScanSessionFile(it.absolutePath, it.name) }
            ?: emptyList()
    }

    private fun appendToSession(rec: Recording) {
        val file = activeSessionFile ?: return
        file.appendText(
            "${rec.timestampMs},${rec.hex},${rec.rssi},${rec.label},${rec.category.name}," +
                "${rec.typeInfo},${rec.colors},${rec.libraryNote}\n",
        )
    }
}
