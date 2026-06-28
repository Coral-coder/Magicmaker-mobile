package com.magicmaker.android.data

import android.content.Context
import android.os.Environment
import com.google.gson.Gson
import com.google.gson.GsonBuilder
import com.magicmaker.android.core.*
import com.magicmaker.android.service.AllFilesAccess
import com.magicmaker.android.service.MagicMakerForegroundService
import com.magicmaker.android.service.ServiceState
import com.magicmaker.android.sync.PacketSync
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class ScanSessionFile(val path: String, val name: String)

class MagicStore(context: Context) {
    private val appContext = context.applicationContext
    private val gson: Gson = GsonBuilder().setPrettyPrinting().create()
    private val prefs = appContext.getSharedPreferences(PREFS_MAIN, Context.MODE_PRIVATE)

    // Where NEW capture logs are written. Prefer the user-accessible SD location
    // (/sdcard/MagicMaker/logs) when all-files access is granted (survives uninstall,
    // browsable on a computer), otherwise the app's external files dir.
    private fun logsDir(): File {
        if (AllFilesAccess.granted(appContext)) {
            val sd = File(Environment.getExternalStorageDirectory(), "MagicMaker/logs")
            if (sd.exists() || sd.mkdirs()) return sd
        }
        return (appContext.getExternalFilesDir("scan_sessions")
            ?: File(appContext.filesDir, "scan_sessions")).also { it.mkdirs() }
    }

    /**
     * Every place logs have ever been written, so old captures are never lost when
     * the storage location changes: SD (new), app external files (band-tagging era),
     * and internal files (oldest).
     */
    private fun allLogDirs(): List<File> = buildList {
        if (AllFilesAccess.granted(appContext)) {
            add(File(Environment.getExternalStorageDirectory(), "MagicMaker/logs"))
        }
        appContext.getExternalFilesDir("scan_sessions")?.let { add(it) }
        add(File(appContext.filesDir, "scan_sessions"))
    }.distinctBy { it.absolutePath }
    // The app's own state stays in private internal storage (fast, always writable).
    private val storeFile = File(appContext.filesDir, "magicmaker_store.json")
    // Canonical, user-editable copy on shared storage: survives uninstall, editable
    // over USB, and auto-loaded on launch. Requires all-files access (see AllFilesAccess).
    private val externalLibraryDir = File(Environment.getExternalStorageDirectory(), "MagicMaker")
    private val externalLibraryFile = File(externalLibraryDir, "magicmaker_library.json")
    val libraryFilePath: String get() = externalLibraryFile.absolutePath

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
    private var activeBandFile: File? = null

    /** Per-session de-dupe accumulator: canonical hex -> running tally for the unique-list export. */
    private data class UniqueAgg(
        var count: Int,
        val firstMs: Long,
        var lastMs: Long,
        val label: String,
        val category: MagicCategory,
        val addresses: MutableSet<String>,
    )
    private val sessionUnique = LinkedHashMap<String, UniqueAgg>()

    /** Fast membership index for learnedRaw (canonical hex) — O(1) dedup on the hot scan path. */
    private val rawHexIndex = HashSet<String>()

    @Volatile private var lastRawSaveMs = 0L

    private fun rebuildRawIndex() {
        rawHexIndex.clear()
        learnedRaw.forEach { rawHexIndex.add(HexUtils.canonicalHex(it.hex)) }
    }

    /** Coalesce the high-volume raw-learn saves so a packet flood can't trigger an IO storm. */
    private fun coalesceRawSave(): Boolean {
        val now = System.currentTimeMillis()
        if (now - lastRawSaveMs < 2500) return false
        lastRawSaveMs = now
        save()
        return true
    }

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
        // All app settings (both SharedPreferences files), type-tagged so a reinstall
        // can restore everything: band addresses, timings, UI collapse state, etc.
        val settings: Map<String, PrefEntry>? = null,
        val uiSettings: Map<String, PrefEntry>? = null,
    )

    /** A single SharedPreferences value, type-tagged for lossless JSON round-trip. */
    data class PrefEntry(
        val type: String,
        val value: String? = null,
        val set: List<String>? = null,
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

    // True once the external file is the loaded/imported source of truth. Until then
    // we never overwrite an existing external library (avoids clobbering real data
    // with freshly-seeded defaults before the user imports it).
    private var externalAuthoritative = false

    fun load() {
        readBestState()?.let { applyState(it.first) }
        // When access is granted we can see the real external state, so internal and
        // external are reconciled (readBestState already loaded the newer of the two):
        // it's safe to treat external as writable, and to seed it if missing.
        // When NOT granted we stay non-authoritative so a later save can't clobber a
        // real external library we simply couldn't read on a fresh install.
        if (AllFilesAccess.granted(appContext)) {
            externalAuthoritative = true
            if (!externalLibraryFile.exists()) writeExternal(gson.toJson(buildState()))
        }
    }

    /** Loads from the SD-card library if it's present and at least as new as the internal copy. */
    private fun readBestState(): Pair<PersistedState, Boolean>? {
        val extExists = runCatching { externalLibraryFile.exists() }.getOrDefault(false)
        val useExternal = extExists &&
            (!storeFile.exists() || externalLibraryFile.lastModified() >= storeFile.lastModified())
        val file = when {
            useExternal -> externalLibraryFile
            storeFile.exists() -> storeFile
            else -> return null
        }
        val state = runCatching { gson.fromJson(file.readText(), PersistedState::class.java) }.getOrNull()
            ?: return null
        return state to useExternal
    }

    private fun applyState(state: PersistedState) {
        presets = state.presets
        learnedColors = state.learnedColors
        learnedLibrary = state.learnedLibrary
        learnedRaw = state.learnedRaw ?: emptyList()
        rebuildRawIndex()
        recordings = state.recordings
        autoRules = state.autoRules
        nextPacketId = state.nextPacketId
        nextRecordingId = state.nextRecordingId
        nextRuleId = state.nextRuleId
        // Restore explicit fields first (covers older files without the settings maps),
        // then the full prefs snapshots which override and fill in everything else.
        prefs.edit()
            .putString("starlight_serial", state.starlightSerial)
            .putString("lab_hex", state.labHex)
            .putString("lab_label", state.labLabel)
            .apply()
        state.settings?.let { restorePrefs(PREFS_MAIN, it) }
        state.uiSettings?.let { restorePrefs(PREFS_UI, it) }
    }

    private fun buildState(): PersistedState = PersistedState(
        presets, learnedColors, learnedLibrary, learnedRaw, recordings, autoRules,
        nextPacketId, nextRecordingId, nextRuleId,
        getStarlightSerial(), getLabHex(), getLabLabel(),
        settings = snapshotPrefs(PREFS_MAIN),
        uiSettings = snapshotPrefs(PREFS_UI),
    )

    private fun snapshotPrefs(name: String): Map<String, PrefEntry> {
        val p = appContext.getSharedPreferences(name, Context.MODE_PRIVATE)
        val out = LinkedHashMap<String, PrefEntry>()
        for ((k, v) in p.all) {
            out[k] = when (v) {
                is Boolean -> PrefEntry("b", v.toString())
                is Int -> PrefEntry("i", v.toString())
                is Long -> PrefEntry("l", v.toString())
                is Float -> PrefEntry("f", v.toString())
                is String -> PrefEntry("s", v)
                is Set<*> -> PrefEntry("ss", set = v.filterIsInstance<String>())
                else -> continue
            }
        }
        return out
    }

    private fun restorePrefs(name: String, entries: Map<String, PrefEntry>) {
        val e = appContext.getSharedPreferences(name, Context.MODE_PRIVATE).edit()
        for ((k, pe) in entries) {
            when (pe.type) {
                "b" -> e.putBoolean(k, pe.value.toBoolean())
                "i" -> pe.value?.toIntOrNull()?.let { e.putInt(k, it) }
                "l" -> pe.value?.toLongOrNull()?.let { e.putLong(k, it) }
                "f" -> pe.value?.toFloatOrNull()?.let { e.putFloat(k, it) }
                "s" -> e.putString(k, pe.value)
                "ss" -> e.putStringSet(k, (pe.set ?: emptyList()).toSet())
            }
        }
        e.apply()
    }

    @Synchronized
    fun save() {
        val json = gson.toJson(buildState())
        storeFile.writeText(json)
        writeExternal(json)
    }

    private fun writeExternal(json: String) {
        if (!AllFilesAccess.granted(appContext)) return
        runCatching {
            // Don't overwrite an existing external library we haven't imported/loaded yet.
            if (!externalAuthoritative && externalLibraryFile.exists()) return@runCatching
            externalLibraryDir.mkdirs()
            externalLibraryFile.writeText(json)
            externalAuthoritative = true
        }
    }

    /** Force-write the current library to the SD-card file. Returns the path, or null if it failed. */
    @Synchronized
    fun exportLibrary(): String? = runCatching {
        externalLibraryDir.mkdirs()
        externalLibraryFile.writeText(gson.toJson(buildState()))
        externalAuthoritative = true
        externalLibraryFile.absolutePath
    }.getOrNull()

    /** Replace the in-memory + internal library from the SD-card file. Returns true on success. */
    @Synchronized
    fun importLibrary(): Boolean = runCatching {
        if (!externalLibraryFile.exists()) return false
        val state = gson.fromJson(externalLibraryFile.readText(), PersistedState::class.java)
            ?: return false
        applyState(state)
        externalAuthoritative = true
        save()
        mergeBuiltInPresets()
        ServiceState.bumpStoreRevision()
        true
    }.getOrElse { false }

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

    /** Rename a captured/library packet. Only touches the label field. */
    @Synchronized
    fun renamePacket(id: Long, newLabel: String) {
        val label = newLabel.trim()
        if (label.isEmpty()) return

        fun updateList(list: List<MagicPacket>): List<MagicPacket> =
            list.map { if (it.id == id) it.copy(label = label) else it }

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

    // ---- MagicBand identity (source-address tagging) -------------------------
    // Note: a phone only hears broadcast advertisements, which carry a *source*
    // address (the advertiser), never a destination. So we can tag packets FROM a
    // chosen address, not "to" it. The band's address is also usually a rotating
    // private address, so the user may need to re-pick it from the seen list.

    private fun normalizeAddress(a: String): String = a.trim().uppercase()

    fun bandAddresses(): Set<String> =
        prefs.getString("band_addresses", "")
            ?.split(",")
            ?.map { it.trim() }
            ?.filter { it.isNotEmpty() }
            ?.toSet()
            ?: emptySet()

    fun isBandAddress(address: String): Boolean =
        address.isNotEmpty() && normalizeAddress(address) in bandAddresses()

    @Synchronized
    fun addBandAddress(address: String) {
        val a = normalizeAddress(address)
        if (a.isEmpty()) return
        prefs.edit().putString("band_addresses", (bandAddresses() + a).joinToString(",")).apply()
        ServiceState.bumpStoreRevision()
    }

    @Synchronized
    fun removeBandAddress(address: String) {
        val a = normalizeAddress(address)
        prefs.edit().putString("band_addresses", (bandAddresses() - a).joinToString(",")).apply()
        ServiceState.bumpStoreRevision()
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
    fun processHeardPacket(
        hex: String,
        rssi: Int,
        persistToSession: Boolean,
        address: String = "",
        lat: Double = Double.NaN,
        lng: Double = Double.NaN,
        accuracy: Float = -1f,
    ): RecordEvent? {
        val canonical = HexUtils.canonicalHex(hex)
        if (!HexUtils.isDisneyBlePacket(canonical)) return null

        val classified = MagicClassifier.classify(canonical)
        val event = if (classified != null) {
            addClassifiedToLibrary(classified, rawHex = hex, rssi = rssi).also {
                if (persistToSession) persistRecording(classified, rssi, it.reason, address, lat, lng, accuracy)
            }
        } else {
            // Telemetry from a MAC the user tagged as their own band is whitelisted (saved);
            // every other guest band stays filtered out.
            hearRawPacket(canonical, rssi, allowNoise = isBandAddress(address)).also {
                if (persistToSession) {
                    persistRecording(
                        ClassifiedPacket(canonical, it.packet.label, MagicCategory.UNKNOWN, "raw", "", it.packet.simKey),
                        rssi, it.reason, address, lat, lng, accuracy,
                    )
                }
            }
        }
        // A new known-function packet was learned -> push it to the shared dictionary
        // (throttled; offline-safe since the library is the durable source).
        if (classified != null && event.added) cloudSync(force = false)
        return event
    }

    // ---- Cloud packet dictionary (shared packets.csv on a dedicated GitHub repo) ----

    fun cloudSyncConfigured(): Boolean = PacketSync.configured()

    /** Reconcile the on-device known packets with the shared cloud dictionary. */
    fun cloudSync(force: Boolean) {
        if (!PacketSync.configured()) return
        PacketSync.sync(
            local = cloudKnownEntries(),
            force = force,
            onRemoteAdded = { importCloudEntries(it) },
            onStatus = { ServiceState.setCloudSyncStatus(it) },
        )
    }

    /** Every packet whose function we know (presets + learned), de-duped by hex. */
    private fun cloudKnownEntries(): List<PacketSync.Entry> {
        val seen = HashSet<String>()
        val out = ArrayList<PacketSync.Entry>()
        for (p in presets + learnedColors + learnedLibrary) {
            if (p.category == MagicCategory.UNKNOWN) continue
            val hex = HexUtils.canonicalHex(p.hex)
            if (hex.isNotEmpty() && seen.add(hex)) {
                out.add(PacketSync.Entry(hex, p.label, p.category.name, p.colors))
            }
        }
        return out
    }

    /** Add packets pulled from the cloud that we don't already have. */
    @Synchronized
    private fun importCloudEntries(entries: List<PacketSync.Entry>) {
        val known = (presets + allLearnedPackets).map { HexUtils.canonicalHex(it.hex) }.toHashSet()
        var added = 0
        val additions = ArrayList<MagicPacket>()
        for (e in entries) {
            val hex = HexUtils.canonicalHex(e.hex)
            if (hex.isEmpty() || !known.add(hex)) continue
            val category = runCatching { MagicCategory.valueOf(e.category) }.getOrDefault(MagicCategory.UNKNOWN)
            additions.add(
                MagicPacket(
                    id = nextPacketId++,
                    hex = hex,
                    label = e.function.ifBlank { "Imported" },
                    category = category,
                    typeInfo = "imported",
                    colors = e.colors,
                    simKey = "",
                    userRecorded = false,
                ),
            )
            added++
        }
        if (added > 0) {
            learnedLibrary = (learnedLibrary + additions).sortedBy { it.label.lowercase() }
            save()
            ServiceState.bumpStoreRevision()
        }
    }

    private fun addClassifiedToLibrary(classified: ClassifiedPacket, rawHex: String, rssi: Int): RecordEvent {
        // Pings are background noise — keep them live/in logs, but never in the library.
        if (classified.typeInfo == "ping") {
            return RecordEvent(classified.toPacket(), false, "Ping (not saved)")
        }
        return addClassifiedToLibraryInner(classified, rawHex, rssi)
    }

    private fun addClassifiedToLibraryInner(classified: ClassifiedPacket, rawHex: String, rssi: Int): RecordEvent =
        when (classified.category) {
            MagicCategory.COLOR -> if (classified.typeInfo == "starlight") {
                addStarlightToLibrary(classified, rssi, rawHex)
            } else {
                addColorToLibrary(classified, rssi)
            }
            MagicCategory.SHOW, MagicCategory.ANIMATION -> addShowAnimToLibrary(classified, rssi)
            MagicCategory.UNKNOWN -> hearRawPacket(classified.hex, rssi, classified.label)
        }

    /**
     * Raw / unclassified packets are saved by full hex — every distinct packet is kept (deduped
     * only against the exact same hex). Learned on first sight; repeats are O(1) no-ops. Saves
     * are coalesced and the count is capped so a packet flood can't stall the app.
     */
    private fun hearRawPacket(hex: String, rssi: Int, label: String? = null, allowNoise: Boolean = false): RecordEvent {
        val canonical = HexUtils.canonicalHex(hex)
        val displayLabel = label ?: MagicClassifier.rawLabel(canonical)
        if (!allowNoise && MagicClassifier.isLibraryNoise(canonical)) {
            return RecordEvent(rawPreview(canonical, displayLabel, rssi), false, "Band/ping (not saved)")
        }
        if (canonical in rawHexIndex) {
            return RecordEvent(rawPreview(canonical, displayLabel, rssi), false, "Known raw")
        }
        if (learnedRaw.size >= MAX_RAW_LIBRARY) {
            return RecordEvent(rawPreview(canonical, displayLabel, rssi), false, "Raw library full ($MAX_RAW_LIBRARY)")
        }
        val packet = MagicPacket(
            id = nextPacketId++,
            hex = canonical,
            label = displayLabel,
            category = MagicCategory.UNKNOWN,
            typeInfo = "raw",
            simKey = "RAW:$canonical",
            userRecorded = false,
            rssi = rssi,
        )
        learnedRaw = learnedRaw + packet
        rawHexIndex.add(canonical)
        if (coalesceRawSave()) ServiceState.bumpStoreRevision()
        return RecordEvent(packet, true, "Learned raw → Unknown")
    }

    private fun rawPreview(canonical: String, label: String, rssi: Int) = MagicPacket(
        id = 0,
        hex = canonical,
        label = label,
        category = MagicCategory.UNKNOWN,
        typeInfo = "raw",
        simKey = "RAW:$canonical",
        userRecorded = false,
        rssi = rssi,
    )

    /**
     * Bulk-import hexes (e.g. every distinct packet from a saved log) into the library:
     * classified packets go to their proper section, everything else to Unknown. Batches the
     * raw additions (one sort, one save) so importing thousands of distinct packets is cheap.
     * Returns the number of new entries added.
     */
    @Synchronized
    fun importHexesToLibrary(hexes: List<String>): Int {
        val existingRaw = learnedRaw.mapTo(HashSet()) { HexUtils.canonicalHex(it.hex) }
        val newRaw = ArrayList<MagicPacket>()
        var added = 0
        for (h in hexes) {
            val canonical = HexUtils.canonicalHex(h)
            if (canonical.isEmpty()) continue
            if (MagicClassifier.isLibraryNoise(canonical)) continue
            val classified = MagicClassifier.classify(canonical)
            if (classified != null && classified.category != MagicCategory.UNKNOWN) {
                if (addClassifiedToLibrary(classified, canonical, 0).added) added++
            } else if (existingRaw.add(canonical)) {
                newRaw.add(
                    MagicPacket(
                        id = nextPacketId++,
                        hex = canonical,
                        label = MagicClassifier.rawLabel(canonical),
                        category = MagicCategory.UNKNOWN,
                        typeInfo = "raw",
                        simKey = "RAW:$canonical",
                        userRecorded = true,
                    ),
                )
                added++
            }
        }
        if (newRaw.isNotEmpty()) learnedRaw = learnedRaw + newRaw
        if (added > 0) {
            rebuildRawIndex()
            save()
            ServiceState.bumpStoreRevision()
        }
        return added
    }

    private fun addStarlightToLibrary(classified: ClassifiedPacket, rssi: Int, rawHex: String): RecordEvent {
        val canonical = HexUtils.canonicalHex(rawHex)
        val colorIdx = MagicClassifier.starlightLearnColorIndex(canonical)
        if (colorIdx == null) {
            val preview = libraryPacketFrom(classified, rawHex)
            return RecordEvent(preview, false, "Heard ${preview.colors} (unrecognized wand format)")
        }
        val stored = libraryPacketFrom(classified, rawHex)
        val key = HexUtils.canonicalHex(stored.hex)
        if (learnedColors.any { it.typeInfo == "starlight" && HexUtils.canonicalHex(it.hex) == key }) {
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
        val key = HexUtils.canonicalHex(classified.hex)
        learnedColors.firstOrNull { HexUtils.canonicalHex(it.hex) == key }?.let {
            return RecordEvent(it, false, "Verified ${classified.colors}")
        }
        val packet = classified.toPacket(userRecorded = true).copy(id = nextPacketId++)
        learnedColors = learnedColors + packet
        save()
        return RecordEvent(packet, true, "Learned ${packet.colors} → Colors")
    }

    private fun addShowAnimToLibrary(classified: ClassifiedPacket, rssi: Int): RecordEvent {
        // Per-distinct: keep every identified packet whose exact hex we haven't seen,
        // rather than collapsing by function code.
        val key = HexUtils.canonicalHex(classified.hex)
        learnedLibrary.firstOrNull { HexUtils.canonicalHex(it.hex) == key }?.let { existing ->
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

    private fun persistRecording(
        classified: ClassifiedPacket,
        rssi: Int,
        note: String,
        address: String,
        lat: Double = Double.NaN,
        lng: Double = Double.NaN,
        accuracy: Float = -1f,
    ) {
        if (activeSessionFile == null) beginScanSession()
        val band = isBandAddress(address)
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
            sourceAddress = address,
            isBand = band,
            lat = lat,
            lng = lng,
            accuracy = accuracy,
        )
        recordings = listOf(rec) + recordings
        appendToSession(rec)                 // full chronological log (replay source)
        if (band) appendToBandSession(rec)   // band-only log
        accumulateUnique(rec)                // dedup tally, written at session end
        save()
    }

    /** Adds/updates the per-session unique tally used to generate the deduped export. */
    private fun accumulateUnique(rec: Recording) {
        val key = HexUtils.canonicalHex(rec.hex)
        val agg = sessionUnique[key]
        if (agg == null) {
            sessionUnique[key] = UniqueAgg(
                count = 1,
                firstMs = rec.timestampMs,
                lastMs = rec.timestampMs,
                label = rec.label,
                category = rec.category,
                addresses = mutableSetOf<String>().apply { if (rec.sourceAddress.isNotEmpty()) add(rec.sourceAddress) },
            )
        } else {
            agg.count += 1
            agg.lastMs = rec.timestampMs
            if (rec.sourceAddress.isNotEmpty()) agg.addresses.add(rec.sourceAddress)
        }
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
        rebuildRawIndex()
        save()
        ServiceState.bumpStoreRevision()
    }

    @Synchronized
    fun clearLearnedStarlight() {
        learnedColors = learnedColors.filter { it.typeInfo != "starlight" }
        save()
        ServiceState.bumpStoreRevision()
    }

    val sessionActive: Boolean get() = activeSessionFile != null

    @Synchronized
    fun beginScanSession(): File {
        val dir = logsDir()
        val stamp = SimpleDateFormat("yyyy-MM-dd'T'HH-mm-ss", Locale.US).format(Date())
        val file = File(dir, "scan_$stamp.csv")
        file.writeText(SESSION_HEADER)
        activeSessionFile = file
        // Band-only log shares the timestamp so the trio sorts together.
        activeBandFile = File(dir, "scan_${stamp}_band.csv")
        sessionUnique.clear()
        refreshSessions()
        return file
    }

    @Synchronized
    fun endScanSession(): String? {
        val name = activeSessionFile?.name
        writeUniqueExport()
        activeSessionFile = null
        activeBandFile = null
        sessionUnique.clear()
        refreshSessions()
        return name
    }

    fun refreshSessions() {
        scanSessions = allLogDirs()
            .flatMap { it.listFiles()?.toList() ?: emptyList() }
            .filter { it.extension == "csv" }
            .sortedByDescending { it.lastModified() }
            .map { ScanSessionFile(it.absolutePath, it.name) }
    }

    /** A capture log on disk (chronological session file), for the Logs tab. */
    data class LogFile(
        val path: String,
        val name: String,
        val sizeBytes: Long,
        val modifiedMs: Long,
        val packetCount: Int,
    )

    /** A single recorded packet parsed from a chronological log file. */
    data class LoggedPacket(
        val timestampMs: Long,
        val hex: String,
        val rssi: Int,
        val label: String,
        val category: String,
        val typeInfo: String,
        val sourceAddress: String,
        val isBand: Boolean,
        val lat: Double = Double.NaN,
        val lng: Double = Double.NaN,
        val accuracy: Float = -1f,
    )

    /**
     * Chronological session logs from every storage location (so old captures stay
     * accessible), excluding the _band / _unique sidecars, newest first.
     */
    fun listLogs(): List<LogFile> =
        allLogDirs()
            .flatMap { it.listFiles()?.toList() ?: emptyList() }
            .filter { it.extension == "csv" && !it.name.endsWith("_band.csv") && !it.name.endsWith("_unique.csv") }
            .sortedByDescending { it.lastModified() }
            .map { f ->
                val lines = runCatching { f.readLines().size - 1 }.getOrDefault(0).coerceAtLeast(0)
                LogFile(f.absolutePath, f.name, f.length(), f.lastModified(), lines)
            }

    /**
     * Streams GPS-tagged observations from every chronological log without loading whole
     * files or building packet objects — for the map, which only needs lat/lng/rssi/addr.
     * Rows without a parseable lat/lng are skipped cheaply.
     */
    fun forEachLoggedLocation(
        action: (lat: Double, lng: Double, rssi: Int, address: String, label: String, category: String) -> Unit,
    ) {
        val files = allLogDirs()
            .flatMap { it.listFiles()?.toList() ?: emptyList() }
            .filter { it.extension == "csv" && !it.name.endsWith("_band.csv") && !it.name.endsWith("_unique.csv") }
        for (f in files) {
            runCatching {
                f.useLines { seq ->
                    seq.drop(1).forEach { line ->
                        val c = line.split(",")
                        if (c.size < 12) return@forEach
                        val lat = c[10].toDoubleOrNull() ?: return@forEach
                        val lng = c[11].toDoubleOrNull() ?: return@forEach
                        action(lat, lng, c[2].toIntOrNull() ?: 0, c[8], c[3], c[4])
                    }
                }
            }
        }
    }

    fun readLog(path: String): List<LoggedPacket> = runCatching {
        File(path).readLines().drop(1).mapNotNull { line ->
            val c = line.split(",")
            if (c.size < 6) return@mapNotNull null
            LoggedPacket(
                timestampMs = c.getOrNull(0)?.toLongOrNull() ?: return@mapNotNull null,
                hex = c.getOrNull(1).orEmpty(),
                rssi = c.getOrNull(2)?.toIntOrNull() ?: 0,
                label = c.getOrNull(3).orEmpty(),
                category = c.getOrNull(4).orEmpty(),
                typeInfo = c.getOrNull(5).orEmpty(),
                sourceAddress = c.getOrNull(8).orEmpty(),
                isBand = c.getOrNull(9)?.toBoolean() ?: false,
                lat = c.getOrNull(10)?.toDoubleOrNull() ?: Double.NaN,
                lng = c.getOrNull(11)?.toDoubleOrNull() ?: Double.NaN,
                accuracy = c.getOrNull(12)?.toFloatOrNull() ?: -1f,
            )
        }
    }.getOrDefault(emptyList())

    @Synchronized
    fun deleteLog(path: String): Boolean {
        val f = File(path)
        val base = f.name.removeSuffix(".csv")
        val ok = runCatching { f.delete() }.getOrDefault(false)
        // Remove sidecars too.
        runCatching { File(f.parentFile, "${base}_band.csv").delete() }
        runCatching { File(f.parentFile, "${base}_unique.csv").delete() }
        refreshSessions()
        return ok
    }

    private fun csvField(value: String): String = value.replace(",", " ").replace("\n", " ")

    private fun sessionRow(rec: Recording): String {
        val lat = if (rec.lat.isNaN()) "" else rec.lat.toString()
        val lng = if (rec.lng.isNaN()) "" else rec.lng.toString()
        val acc = if (rec.accuracy < 0f) "" else rec.accuracy.toString()
        return "${rec.timestampMs},${rec.hex},${rec.rssi},${csvField(rec.label)},${rec.category.name}," +
            "${rec.typeInfo},${csvField(rec.colors)},${csvField(rec.libraryNote)}," +
            "${rec.sourceAddress},${rec.isBand},$lat,$lng,$acc\n"
    }

    private fun appendToSession(rec: Recording) {
        activeSessionFile?.appendText(sessionRow(rec))
    }

    private fun appendToBandSession(rec: Recording) {
        val file = activeBandFile ?: return
        if (!file.exists()) file.writeText(SESSION_HEADER)
        file.appendText(sessionRow(rec))
    }

    /** Writes the deduped unique-packet list for the session (one row per distinct hex). */
    private fun writeUniqueExport() {
        if (sessionUnique.isEmpty()) return
        val active = activeSessionFile ?: return
        val base = active.name.removeSuffix(".csv")
        val file = File(active.parentFile, "${base}_unique.csv")
        val sb = StringBuilder("hex,count,first_ms,last_ms,label,category,addresses\n")
        for ((hex, agg) in sessionUnique) {
            sb.append(
                "$hex,${agg.count},${agg.firstMs},${agg.lastMs},${csvField(agg.label)}," +
                    "${agg.category.name},${agg.addresses.joinToString(" ")}\n",
            )
        }
        file.writeText(sb.toString())
    }

    companion object {
        /** Safety cap on auto-learned raw packets so a relentless flood can't OOM/ANR the app. */
        private const val MAX_RAW_LIBRARY = 20000
        private const val SESSION_HEADER =
            "timestamp_ms,hex,rssi,label,category,type_info,colors,note,source_address,is_band,lat,lng,accuracy\n"
        private const val PREFS_MAIN = "magicmaker"
        private const val PREFS_UI = "magicmaker_ui"
    }
}
