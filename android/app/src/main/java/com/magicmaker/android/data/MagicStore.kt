package com.magicmaker.android.data

import android.content.Context
import android.os.Environment
import com.google.gson.Gson
import com.google.gson.GsonBuilder
import com.magicmaker.android.core.*
import com.magicmaker.android.service.AllFilesAccess
import com.magicmaker.android.service.MagicMakerForegroundService
import com.magicmaker.android.service.ServiceState
import com.magicmaker.android.sync.AtomicFiles
import com.magicmaker.android.sync.Bytes
import com.magicmaker.android.sync.IdentityReconcile
import com.magicmaker.android.sync.LedgerStore
import com.magicmaker.android.sync.LibraryDiff
import com.magicmaker.android.sync.LibraryMigration
import com.magicmaker.android.sync.LibraryRows
import com.magicmaker.android.sync.LibrarySync
import com.magicmaker.android.sync.PacketSync
import com.magicmaker.android.sync.RowsAccess
import com.magicmaker.android.sync.SaveSink
import com.magicmaker.android.sync.StoredPeer
import com.magicmaker.android.sync.SyncIdentityFile
import com.magicmaker.android.sync.SyncLibraryPort
import com.magicmaker.android.sync.SyncStateCodec
import com.magicmaker.android.sync.SyncStateJson
import java.io.File
import java.util.zip.CRC32
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

data class ScanSessionFile(val path: String, val name: String)

class MagicStore(context: Context) {
    private val appContext = context.applicationContext
    private val gson: Gson = GsonBuilder().create()
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
    // Size / mtime / CRC of the external copy as last written by this app (plan §3.4): a fast
    // "the user has not edited it" check, so a multi-MB file is not parsed at every launch.
    private val externalSidecarFile = File(appContext.filesDir, "magicmaker_library.ext.json")

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
        // The sync ledger + peer table (plan §3.1), in the same write as the rows. Null in files
        // written before P3: load() then migrates the rows (§4.4).
        val sync: SyncStateJson? = null,
    )

    /** A single SharedPreferences value, type-tagged for lossless JSON round-trip. */
    data class PrefEntry(
        val type: String,
        val value: String? = null,
        val set: List<String>? = null,
    )

    // ---- sync (docs/SYNC_P3_ANDROID_PLAN.md §3–§4) ------------------------------------------

    /** The sync identity in noBackupFilesDir (plan §3.3). Loaded before the store: load() needs it. */
    internal val syncIdentity: SyncIdentityFile = SyncIdentityFile.load(
        File(appContext.noBackupFilesDir, SyncIdentityFile.FILE_NAME),
        System.currentTimeMillis(),
        onError = { t, tag -> CrashLog.record(t, tag) },
    )

    /** LibrarySync's view of the rows. Every call happens with this store's monitor held. */
    private val rowsAccess = object : RowsAccess {
        override var presets: List<MagicPacket>
            get() = this@MagicStore.presets
            set(value) { this@MagicStore.presets = value }
        override var learnedColors: List<MagicPacket>
            get() = this@MagicStore.learnedColors
            set(value) { this@MagicStore.learnedColors = value }
        override var learnedLibrary: List<MagicPacket>
            get() = this@MagicStore.learnedLibrary
            set(value) { this@MagicStore.learnedLibrary = value }
        override var learnedRaw: List<MagicPacket>
            get() = this@MagicStore.learnedRaw
            set(value) { this@MagicStore.learnedRaw = value }
        override var newWandNames: Map<String, String>
            get() = loadNewWandNamesPref()
            set(value) { writeNewWandNamesPref(value) }

        override fun allocId(): Long = nextPacketId++

        override fun learnFromSync(hex: String): Boolean = learnFromSyncRow(hex)

        override fun bumpRevision() = ServiceState.bumpStoreRevision()

        override fun rebuildRawIndex() = this@MagicStore.rebuildRawIndex()
    }

    private val librarySync = LibrarySync(
        rowsAccess, LedgerStore(), syncIdentity, SaveSink { save() }, this, { System.currentTimeMillis() },
    )

    /** The phone's ledger and rows for the sync runtime (SyncPorts.data.library). */
    val sync: SyncLibraryPort get() = librarySync

    /** Serializes the internal + external writes (saveNow, exportLibrary); never the store monitor. */
    private val writeLock = Any()

    /** While importHexesToLibrary runs: learned hexes collect here for one bulk PRESENCE batch. */
    private var learnBatch: MutableList<String>? = null

    private fun loadNewWandNamesPref(): Map<String, String> =
        LibraryRows.parseNewWandJson(prefs.getString("newwand_names", null))

    private fun writeNewWandNamesPref(names: Map<String, String>) {
        val o = org.json.JSONObject()
        names.forEach { (k, v) -> o.put(k, v) }
        prefs.edit().putString("newwand_names", o.toString()).apply()
    }

    /** PRESENCE projection (plan §4.3): the learn routine without ledger, cloud, serial or rssi. */
    private fun learnFromSyncRow(hex: String): Boolean {
        val canonical = HexUtils.canonicalHex(hex)
        if (MagicClassifier.isLibraryNoise(canonical)) return false
        val classified = MagicClassifier.classify(canonical) ?: return false
        if (classified.category == MagicCategory.UNKNOWN || classified.typeInfo == "ping") return false
        return addClassifiedToLibrary(classified, rawHex = canonical, rssi = 0, fromSync = true).added
    }

    /** A learn path created a row in colors / library: PRESENCE, unless it came from sync. */
    private fun learnedRow(hex: String, fromSync: Boolean) {
        if (fromSync) return
        val batch = learnBatch
        if (batch != null) batch.add(hex) else librarySync.onLearned(hex)
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
    @Volatile private var externalAuthoritative = false

    /** {"size", "mtimeMs", "crc"} of the external copy this app last wrote (plan §3.4). */
    private data class ExtSidecar(val size: Long? = null, val mtimeMs: Long? = null, val crc: Long? = null)

    private fun parseState(bytes: ByteArray?): PersistedState? =
        bytes?.let { b -> runCatching { gson.fromJson(String(b, Charsets.UTF_8), PersistedState::class.java) }.getOrNull() }
            ?.let { runCatching { sanitizedState(it) }.getOrNull() }

    private fun crc32(bytes: ByteArray): Long = CRC32().also { it.update(bytes) }.value

    private fun readSidecar(): ExtSidecar? =
        AtomicFiles.read(externalSidecarFile)?.let { b ->
            runCatching { gson.fromJson(String(b, Charsets.UTF_8), ExtSidecar::class.java) }.getOrNull()
        }

    private fun writeSidecar(bytes: ByteArray) {
        val f = externalLibraryFile
        val sc = ExtSidecar(f.length(), f.lastModified(), crc32(bytes))
        AtomicFiles.write(externalSidecarFile, gson.toJson(sc).toByteArray(Charsets.UTF_8))
    }

    /**
     * Load (plan §3.6). The internal store is always the base when it parses. The external copy is
     * the base only when no internal store exists, and is otherwise diffed as user edits when it
     * changed since this app wrote it (sidecar) and is newer. The ledger is restored, or migrated
     * from the rows once, then the identity is reconciled (rollback / restore / corruption).
     */
    fun load() {
        val internal = parseState(AtomicFiles.read(storeFile))
        // A store that exists but cannot be read or parsed (a truncated pre-P3 write, a disk error,
        // OOM on a huge file) is moved aside first: the save below must never overwrite it.
        if (internal == null) keepUnreadableStore()
        val granted = AllFilesAccess.granted(appContext)
        if (granted) AtomicFiles.recover(externalLibraryFile)
        val extExists = runCatching { externalLibraryFile.isFile }.getOrDefault(false)
        var external: PersistedState? = null
        var externalChanged = false
        var externalNewer = false
        if (extExists) {
            if (internal == null) {
                external = parseState(runCatching { externalLibraryFile.readBytes() }.getOrNull())
            } else {
                externalNewer = externalLibraryFile.lastModified() > storeFile.lastModified()
                val sc = readSidecar()
                val quickMatch = sc != null && sc.size == externalLibraryFile.length() &&
                    sc.mtimeMs == externalLibraryFile.lastModified()
                if (externalNewer && !quickMatch) {
                    val bytes = runCatching { externalLibraryFile.readBytes() }.getOrNull()
                    if (bytes != null && (sc == null || sc.crc != crc32(bytes))) {
                        externalChanged = true
                        external = parseState(bytes)
                    }
                }
            }
        }
        val base = IdentityReconcile.chooseBase(internal != null, external != null)
        val baseState = when (base) {
            IdentityReconcile.Base.INTERNAL -> internal
            IdentityReconcile.Base.EXTERNAL -> external
            IdentityReconcile.Base.NONE -> null
        }
        baseState?.let { applyState(it) }

        // Ledger: restore the stored section, or migrate the rows (schema 0 -> 1, once).
        val stored = baseState?.sync
        var ledger = LedgerStore()
        var peers = LinkedHashMap<Bytes, StoredPeer>()
        var corrupt = false
        var migrated = false
        if (stored != null) {
            val r = SyncStateCodec.restore(stored)
            ledger = r.ledger
            peers = r.peers
            corrupt = r.corrupt
            if (corrupt) CrashLog.record(IllegalStateException("sync ledger: dropped ${r.dropped.take(8)}"), "MagicStore.load")
        } else if (baseState != null) {
            val res = LibraryMigration.migrate(currentRows(), syncIdentity.deviceId, ledger)
            presets = res.rows.presets
            learnedColors = res.rows.learnedColors
            learnedLibrary = res.rows.learnedLibrary
            learnedRaw = res.rows.learnedRaw
            rebuildRawIndex()
            if (res.rows.newWandNames != loadNewWandNamesPref()) writeNewWandNamesPref(res.rows.newWandNames)
            migrated = true
        }
        // What is already on the internal disk: everything below the stored nextSyncSeq.
        val durable = if (base == IdentityReconcile.Base.INTERNAL && stored != null) ledger.nextSyncSeq - 1 else 0
        val outcome = IdentityReconcile.decide(
            IdentityReconcile.Facts(base, syncIdentity.wasPresent, syncIdentity.issuedSeq, ledger.nextSyncSeq, corrupt, migrated),
        )
        IdentityReconcile.apply(outcome, syncIdentity, peers)
        librarySync.install(ledger, peers, durable)

        var diffed = false
        if (IdentityReconcile.externalDiff(base, external != null, externalChanged, externalNewer)) {
            // A diff that throws (an odd hand edit) must not crash every launch: the internal
            // library stays as loaded, the SD-card file is kept as .rejected before a save
            // rewrites it.
            diffed = runCatching { applyExternalDiff(external!!) }
                .onFailure { t ->
                    CrashLog.record(t, "MagicStore.load external diff")
                    runCatching {
                        externalLibraryFile.copyTo(File(externalLibraryDir, externalLibraryFile.name + ".rejected"), overwrite = true)
                    }
                }.isSuccess
        }
        // When access is granted we can see the real external state, so internal and external
        // are reconciled above: it's safe to treat external as writable (and to seed it if
        // missing). When NOT granted we stay non-authoritative so a later save can't clobber a
        // real external library we simply couldn't read on a fresh install.
        if (granted) externalAuthoritative = true
        if (migrated || diffed || base != IdentityReconcile.Base.INTERNAL || outcome.newDbId || (granted && !extExists)) {
            save()
        }
    }

    /**
     * Rename an unreadable internal store to `magicmaker_store.json.corrupt-<ms>` (the newest
     * [KEEP_CORRUPT] are kept) so a recovery from it stays possible; the library then loads from
     * the external copy when there is one.
     */
    private fun keepUnreadableStore() {
        runCatching {
            if (!storeFile.isFile || storeFile.length() == 0L) return
            val prefix = storeFile.name + ".corrupt-"
            val kept = File(storeFile.parentFile, prefix + System.currentTimeMillis())
            if (!storeFile.renameTo(kept)) return
            CrashLog.record(IllegalStateException("library store unreadable; kept as ${kept.name}"), "MagicStore.load")
            storeFile.parentFile?.listFiles { f -> f.name.startsWith(prefix) }
                ?.sortedByDescending { it.name.removePrefix(prefix).toLongOrNull() ?: 0L }
                ?.drop(KEEP_CORRUPT)
                ?.forEach { it.delete() }
        }
    }

    /** The rows as one value (migration / diff input). Callers hold the monitor or run in init. */
    private fun currentRows(): LibraryRows =
        LibraryRows(presets, learnedColors, learnedLibrary, learnedRaw, loadNewWandNamesPref())

    /**
     * The external file as user edits (spec §5.2, plan §4.5): its rows are diffed by canonical hex
     * into ledger edits (its own sync section is ignored); its other state (auto rules, prefs,
     * lab, starlight serial) is applied as before.
     */
    private fun applyExternalDiff(e: PersistedState) {
        val internalRows = currentRows()
        @Suppress("USELESS_ELVIS")
        val externalRows = LibraryRows(
            e.presets ?: emptyList(), e.learnedColors ?: emptyList(), e.learnedLibrary ?: emptyList(),
            e.learnedRaw ?: emptyList(), LibraryRows.parseNewWandJson(e.settings?.get("newwand_names")?.value),
        )
        val ops = LibraryDiff.diff(internalRows, externalRows) { hex -> librarySync.isSyncable(hex) }
        applyNonLibraryState(e)
        librarySync.onDiff(ops)
    }

    @Suppress("USELESS_ELVIS")
    private fun applyState(state: PersistedState) {
        presets = state.presets ?: emptyList()
        learnedColors = state.learnedColors ?: emptyList()
        learnedLibrary = state.learnedLibrary ?: emptyList()
        learnedRaw = state.learnedRaw ?: emptyList()
        rebuildRawIndex()
        recordings = state.recordings ?: emptyList()
        nextPacketId = state.nextPacketId
        applyNonLibraryState(state)
    }

    /** Everything but the library rows (also used by the external diff). */
    @Suppress("USELESS_ELVIS")
    private fun applyNonLibraryState(state: PersistedState) {
        autoRules = state.autoRules ?: emptyList()
        nextPacketId = maxOf(nextPacketId, state.nextPacketId)
        nextRecordingId = maxOf(nextRecordingId, state.nextRecordingId)
        nextRuleId = maxOf(nextRuleId, state.nextRuleId)
        // Restore explicit fields first (covers older files without the settings maps),
        // then the full prefs snapshots which override and fill in everything else.
        prefs.edit()
            .putString("starlight_serial", state.starlightSerial ?: StarlightSerial.DEFAULT_SERIAL)
            .putString("lab_hex", state.labHex ?: PacketBuilder.WAKEUP_PING)
            .putString("lab_label", state.labLabel ?: "")
            .apply()
        state.settings?.let { restorePrefs(PREFS_MAIN, it) }
        state.uiSettings?.let { restorePrefs(PREFS_UI, it) }
    }

    // Recordings are not written to the library file. The CSV session log is their durable
    // record, and a recording made without a GPS fix carries NaN lat/lng, which Gson refuses
    // to serialise — one such row in memory made every library save and export fail.
    private fun buildState(sync: SyncStateJson?): PersistedState = PersistedState(
        presets, learnedColors, learnedLibrary, learnedRaw, emptyList(), autoRules,
        nextPacketId, nextRecordingId, nextRuleId,
        getStarlightSerial(), getLabHex(), getLabLabel(),
        settings = snapshotPrefs(PREFS_MAIN),
        uiSettings = snapshotPrefs(PREFS_UI),
        sync = sync,
    )

    /** One store write's input, taken under the monitor; [seqAtSnapshot] = nextSyncSeq then. */
    private class Snapshot(val state: PersistedState, val seqAtSnapshot: Long)

    // The lists are captured by reference: rows are never mutated in place (every writer uses
    // copy() and replaces the list), so serializing them outside the monitor is safe (§3.5).
    @Synchronized
    private fun buildSnapshot(): Snapshot {
        val seq = librarySync.nextSyncSeq
        return Snapshot(buildState(librarySync.snapshot()), seq)
    }

    private fun snapshotPrefs(name: String): Map<String, PrefEntry> {
        val p = appContext.getSharedPreferences(name, Context.MODE_PRIVATE)
        val out = LinkedHashMap<String, PrefEntry>()
        for ((k, v) in p.all) {
            // Per-launch crash-guard mark of the VFD theme: device state, never exported.
            if (k == "vfd_launch_pending") continue
            // The cloud dictionary token lives in its own prefs file (PacketSync.TOKEN_PREFS); never
            // let it reach the library file or an EXPORT even if it ever lands in these files.
            if (k == PacketSync.TOKEN_KEY) continue
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

    // Persisting the whole store is expensive (serialize every list + two disk writes). It used
    // to run synchronously on whatever thread called save() — the main thread on UI edits (ANRs,
    // and a crash if serialize/disk threw) and the packet executor on every learned packet
    // (blocking the pipeline → dropped packets). Now save() just marks state dirty and a single
    // background thread coalesces bursts into one write, off the caller's thread, crash-guarded.
    private val saveExecutor = Executors.newSingleThreadExecutor()
    private val saveScheduled = AtomicBoolean(false)

    fun save() {
        if (saveScheduled.compareAndSet(false, true)) {
            runCatching {
                saveExecutor.execute {
                    saveScheduled.set(false) // allow the next burst to coalesce a fresh write
                    runCatching { saveNow() }.onFailure { CrashLog.record(it, "MagicStore.save") }
                }
            }.onFailure {
                // Executor rejected (shutting down) — fall back to a guarded inline write.
                saveScheduled.set(false)
                runCatching { saveNow() }.onFailure { e -> CrashLog.record(e, "MagicStore.save inline") }
            }
        }
    }

    /**
     * One store write (plan §3.5): snapshot under the monitor, then serialize and write the
     * internal file atomically (and the external copy + sidecar) outside it, then durableHigh,
     * issuedSeq and onDurable via [LibrarySync.onSaved]. The monitor is never held during I/O.
     */
    private fun saveNow() {
        val snap = buildSnapshot()
        synchronized(writeLock) {
            val bytes = gson.toJson(snap.state).toByteArray(Charsets.UTF_8)
            if (!AtomicFiles.write(storeFile, bytes)) {
                CrashLog.record(IllegalStateException("store write failed"), "MagicStore.saveNow")
                return
            }
            writeExternal(bytes)
        }
        librarySync.onSaved(snap.seqAtSnapshot)
    }

    /** The same bytes as the internal file, atomically, then the sidecar. Caller holds writeLock. */
    private fun writeExternal(bytes: ByteArray) {
        if (!AllFilesAccess.granted(appContext)) return
        runCatching {
            // Don't overwrite an existing external library we haven't imported/loaded yet.
            if (!externalAuthoritative && externalLibraryFile.exists()) return@runCatching
            if (AtomicFiles.write(externalLibraryFile, bytes)) {
                externalAuthoritative = true
                writeSidecar(bytes)
            }
        }
    }

    /** Force-write the current library to the SD-card file. Returns the path, or null if it failed. */
    fun exportLibrary(): String? = runCatching {
        val snap = buildSnapshot()
        synchronized(writeLock) {
            val bytes = gson.toJson(snap.state).toByteArray(Charsets.UTF_8)
            if (!AtomicFiles.write(externalLibraryFile, bytes)) return@runCatching null
            writeSidecar(bytes)
        }
        externalAuthoritative = true
        externalLibraryFile.absolutePath
    }.getOrNull()

    /**
     * Merge the SD-card file into the library as user edits (plan §4.5): a diff by canonical hex,
     * not a replace, so every change becomes a record version. The identity is not reset.
     */
    fun importLibrary(): Boolean = runCatching {
        if (!externalLibraryFile.exists()) return false
        val state = parseState(externalLibraryFile.readBytes()) ?: return false
        synchronized(this) {
            applyExternalDiff(state)
            externalAuthoritative = true
            mergeBuiltInPresets()
        }
        save()
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

    /** The second, generated wand type (CF0B code range) — kept separate from Starlight. */
    fun newWandPackets(): List<MagicPacket> = NewWandCatalog.packets

    fun findLearnedStarlight(id: Long): MagicPacket? =
        if (NewWandCatalog.isNewWandId(id)) NewWandCatalog.byId(id)
        else learnedColors.firstOrNull { it.id == id && it.typeInfo == "starlight" }

    fun findTransmitPacket(id: Long): MagicPacket? =
        allTransmitPackets().firstOrNull { it.id == id }
    fun getLabHex() = prefs.getString("lab_hex", PacketBuilder.WAKEUP_PING)!!
    fun getLabLabel() = prefs.getString("lab_label", "") ?: ""

    fun getWakeupPreambleMs(): Int =
        prefs.getInt("wakeup_preamble_ms", TransmitTiming.DEFAULT_WAKEUP_PRELUDE_MS)
            .coerceIn(TransmitTiming.MIN_WAKEUP_PRELUDE_MS, TransmitTiming.MAX_WAKEUP_PRELUDE_MS)

    fun saveWakeupPreambleMs(ms: Int) {
        prefs.edit().putInt(
            "wakeup_preamble_ms",
            ms.coerceIn(TransmitTiming.MIN_WAKEUP_PRELUDE_MS, TransmitTiming.MAX_WAKEUP_PRELUDE_MS),
        ).apply()
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

    /** Broadcast strength 0..3 = ULTRA_LOW/LOW/MEDIUM/HIGH advertise TX power. Lower = shorter
     * range (fewer nearby bands react). Default HIGH (3). */
    fun getTxPowerLevel(): Int = prefs.getInt("tx_power_level", 3).coerceIn(0, 3)

    fun saveTxPowerLevel(level: Int) {
        prefs.edit().putInt("tx_power_level", level.coerceIn(0, 3)).apply()
        ServiceState.bumpStoreRevision()
    }

    /** TX mode: true = 1:1 wake/command interleave (lighter, good in-park); false = sustained
     * wake stream then command stream (stronger wake). Default sustained. */
    fun getTxInterleave(): Boolean = prefs.getBoolean("tx_interleave", false)

    fun saveTxInterleave(on: Boolean) {
        prefs.edit().putBoolean("tx_interleave", on).apply()
        ServiceState.bumpStoreRevision()
    }

    /** Scan filter: true = only surface real show-control packets (pings / E?00E9 effects /
     * starlight / show blocks), dropping MagicBand + device noise. Default on. */
    fun getShowControlOnly(): Boolean = prefs.getBoolean("show_control_only", true)

    fun saveShowControlOnly(on: Boolean) {
        prefs.edit().putBoolean("show_control_only", on).apply()
        ServiceState.bumpStoreRevision()
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

    /** The Lab tag names the matching raw row: a USER edit applied to every row with that hex. */
    @Synchronized
    fun applyLabLabelToMatchingRaw() {
        val hex = HexUtils.canonicalHex(getLabHex())
        val tag = getLabLabel().trim()
        if (tag.isEmpty()) return
        if (learnedRaw.none { HexUtils.canonicalHex(it.hex) == hex }) return
        librarySync.onUserEdit(hex, label = tag, category = null, note = null)
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
        // USER|PRESET (beats a tombstone); the projection gives every row with the hex this state.
        librarySync.onSavePreset(packet.hex, displayLabel, userTyped = label.isNotBlank())
        saveLabHex(canonical)
        saveLabLabel(displayLabel)
        save()
        ServiceState.bumpStoreRevision()
        return null
    }

    /** Deleting a user preset tombstones its hex: every learned row with that packet goes too (D-P3-6). */
    @Synchronized
    fun deleteCustomPreset(id: Long) {
        val target = presets.firstOrNull { it.id == id && it.userRecorded } ?: return
        librarySync.onDelete(listOf(target.hex))
        save()
        ServiceState.bumpStoreRevision()
    }

    /** The first row with [id] in the order colors, library, raw, presets. */
    private fun rowById(id: Long): MagicPacket? =
        learnedColors.firstOrNull { it.id == id } ?: learnedLibrary.firstOrNull { it.id == id }
            ?: learnedRaw.firstOrNull { it.id == id } ?: presets.firstOrNull { it.id == id }

    /** Recategorize: a USER edit, applied to every row with that packet's hex. */
    @Synchronized
    fun recategorizePacket(id: Long, category: MagicCategory) {
        val row = rowById(id) ?: return
        librarySync.onUserEdit(row.hex, label = null, category = LibraryRows.categoryCode(category), note = null)
        save()
        ServiceState.bumpStoreRevision()
    }

    /**
     * Rename: a USER edit applied to every row with that packet's hex. A blank name clears the
     * user's name (RESET: the generated label comes back, D-P3-7).
     */
    @Synchronized
    fun renamePacket(id: Long, newLabel: String) {
        val row = rowById(id) ?: return
        librarySync.onUserEdit(row.hex, label = newLabel, category = null, note = null)
        save()
        ServiceState.bumpStoreRevision()
    }

    /** A row's note (no UI in P3; the iPhone sets notes): USER if user-edited, else RESET + note. */
    @Synchronized
    fun setNote(id: Long, note: String) {
        val row = rowById(id) ?: return
        librarySync.onNote(row.hex, note)
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

    /** How many guest-band telemetry packets (8301C0… / 83010F11…) are sitting in the library. */
    fun savedBandCount(): Int = learnedRaw.count { MagicClassifier.isLibraryNoise(it.hex) }

    /** Manual bulk cleanup: remove all guest-band telemetry from the library. Returns count removed. */
    @Synchronized
    fun deleteSavedBands(): Int {
        val before = learnedRaw.size
        learnedRaw = learnedRaw.filterNot { MagicClassifier.isLibraryNoise(it.hex) }
        val removed = before - learnedRaw.size
        if (removed > 0) {
            rebuildRawIndex()
            save()
            ServiceState.bumpStoreRevision()
        }
        return removed
    }

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

    // The Lab scratch hex/label live in SharedPreferences only. They used to call save() too,
    // which rewrote the whole library to disk on every byte the user edited in the inspector.
    fun saveLabHex(hex: String) {
        prefs.edit().putString("lab_hex", hex.uppercase()).apply()
    }

    fun saveLabLabel(label: String) {
        prefs.edit().putString("lab_label", label).apply()
    }

    fun loadIntoLab(hex: String, label: String = "") {
        saveLabHex(hex)
        saveLabLabel(label)
    }

    /** A New-Wand code's custom name (blank removes it); returns the new map. P3: also a NEWWAND record. */
    @Synchronized
    fun setNewWandName(hex: String, name: String): Map<String, String> {
        // The NEWWAND record (blank = deleted) and the `newwand_names` pref, with the name
        // normalized (trimmed, at most 64 UTF-8 bytes) exactly as the record carries it.
        val current = librarySync.onNewWandName(hex, name)
        ServiceState.bumpStoreRevision()
        return current
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

    fun cloudSyncConfigured(): Boolean = PacketSync.configured(appContext)

    /** Reconcile the on-device known packets with the shared cloud dictionary. */
    fun cloudSync(force: Boolean) {
        if (!PacketSync.configured(appContext)) return
        PacketSync.sync(
            context = appContext,
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
            if (librarySync.isTombstoned(hex)) continue // deleted means deleted (spec §2.7)
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
            // PRESENCE per added row (they land in the library).
            if (additions.size == 1) librarySync.onLearned(additions[0].hex) else librarySync.onLearnedAll(additions.map { it.hex })
            save()
            ServiceState.bumpStoreRevision()
        }
    }

    /**
     * [fromSync]: the PRESENCE projection of a received record (plan §4.3): no ledger entry (it
     * exists), no cloud push, no `starlight_serial` pref write, no rssi, no recording.
     */
    private fun addClassifiedToLibrary(
        classified: ClassifiedPacket,
        rawHex: String,
        rssi: Int,
        fromSync: Boolean = false,
    ): RecordEvent {
        // Pings are background noise — keep them live/in logs, but never in the library.
        if (classified.typeInfo == "ping") {
            return RecordEvent(classified.toPacket(), false, "Ping (not saved)")
        }
        return addClassifiedToLibraryInner(classified, rawHex, rssi, fromSync)
    }

    private fun addClassifiedToLibraryInner(
        classified: ClassifiedPacket,
        rawHex: String,
        rssi: Int,
        fromSync: Boolean = false,
    ): RecordEvent =
        when (classified.category) {
            MagicCategory.COLOR -> if (classified.typeInfo == "starlight") {
                addStarlightToLibrary(classified, rssi, rawHex, fromSync)
            } else {
                addColorToLibrary(classified, rssi, fromSync)
            }
            MagicCategory.SHOW, MagicCategory.ANIMATION -> addShowAnimToLibrary(classified, rssi, fromSync)
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
        // A named raw row the user deleted is tombstoned; it is not re-learned (spec §2.7).
        if (librarySync.isTombstoned(canonical)) {
            return RecordEvent(rawPreview(canonical, displayLabel, rssi), false, "Deleted (not re-learned)")
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
        val batch = ArrayList<String>()
        learnBatch = batch
        try {
            return importHexesInner(hexes)
        } finally {
            learnBatch = null
            // Classified rows went through the learn path: one bulk PRESENCE batch (raw: no entry).
            if (batch.isNotEmpty()) librarySync.onLearnedAll(batch)
        }
    }

    private fun importHexesInner(hexes: List<String>): Int {
        val existingRaw = learnedRaw.mapTo(HashSet()) { HexUtils.canonicalHex(it.hex) }
        val newRaw = ArrayList<MagicPacket>()
        var added = 0
        for (h in hexes) {
            val canonical = HexUtils.canonicalHex(h)
            if (canonical.isEmpty()) continue
            if (MagicClassifier.isLibraryNoise(canonical)) continue
            if (librarySync.isTombstoned(canonical)) continue
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

    private fun addStarlightToLibrary(
        classified: ClassifiedPacket,
        rssi: Int,
        rawHex: String,
        fromSync: Boolean = false,
    ): RecordEvent {
        val canonical = HexUtils.canonicalHex(rawHex)
        val colorIdx = MagicClassifier.starlightLearnColorIndex(canonical)
        if (colorIdx == null) {
            val preview = libraryPacketFrom(classified, rawHex, fromSync)
            return RecordEvent(preview, false, "Heard ${preview.colors} (unrecognized wand format)")
        }
        val stored = libraryPacketFrom(classified, rawHex, fromSync)
        val key = HexUtils.canonicalHex(stored.hex)
        if (learnedColors.any { it.typeInfo == "starlight" && HexUtils.canonicalHex(it.hex) == key }) {
            updateLearnedColor(stored, verified = true)
            return RecordEvent(stored, false, "Verified ${stored.colors}")
        }
        if (librarySync.isTombstoned(key)) return RecordEvent(stored, false, "Deleted (not re-learned)")
        val packet = stored.copy(id = nextPacketId++)
        learnedColors = learnedColors + packet
        learnedRow(packet.hex, fromSync)
        save()
        ServiceState.bumpStoreRevision()
        return RecordEvent(packet, true, "Learned ${packet.colors} → Wand")
    }

    private fun addColorToLibrary(classified: ClassifiedPacket, rssi: Int, fromSync: Boolean = false): RecordEvent {
        if (isDuplicateOfPreset(classified)) {
            return RecordEvent(classified.toPacket(), false, "Recorded (built-in color)")
        }
        val key = HexUtils.canonicalHex(classified.hex)
        learnedColors.firstOrNull { HexUtils.canonicalHex(it.hex) == key }?.let {
            return RecordEvent(it, false, "Verified ${classified.colors}")
        }
        if (librarySync.isTombstoned(key)) return RecordEvent(classified.toPacket(), false, "Deleted (not re-learned)")
        val packet = classified.toPacket(userRecorded = true).copy(id = nextPacketId++)
        learnedColors = learnedColors + packet
        learnedRow(packet.hex, fromSync)
        save()
        return RecordEvent(packet, true, "Learned ${packet.colors} → Colors")
    }

    private fun addShowAnimToLibrary(classified: ClassifiedPacket, rssi: Int, fromSync: Boolean = false): RecordEvent {
        // Per-distinct: keep every identified packet whose exact hex we haven't seen,
        // rather than collapsing by function code.
        val key = HexUtils.canonicalHex(classified.hex)
        learnedLibrary.firstOrNull { HexUtils.canonicalHex(it.hex) == key }?.let { existing ->
            // Re-hearing never rewrites hex and never undoes a user's name (spec §5.4).
            val updated = LibraryRows.relabelOnRehear(existing, classified)
            if (updated != existing) {
                learnedLibrary = learnedLibrary.map { if (it.id == existing.id) updated else it }
                    .sortedBy { it.label.lowercase() }
                save()
                ServiceState.bumpStoreRevision()
            }
            return RecordEvent(updated, false, "Verified ${classified.label}")
        }
        if (librarySync.isTombstoned(key)) return RecordEvent(classified.toPacket(), false, "Deleted (not re-learned)")
        val packet = classified.toPacket(userRecorded = true).copy(id = nextPacketId++)
        learnedLibrary = (learnedLibrary + packet).sortedBy { it.label.lowercase() }
        learnedRow(packet.hex, fromSync)
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

    private fun libraryPacketFrom(classified: ClassifiedPacket, rawHex: String, fromSync: Boolean = false): MagicPacket {
        if (classified.typeInfo == "starlight") {
            val canonical = HexUtils.canonicalHex(rawHex)
            // A record from a peer is not a wand heard here: it never changes this phone's serial.
            if (!fromSync) {
                StarlightSerial.extractSerial(canonical)?.let { heard ->
                    StarlightSerial.normalizeSerial(heard)?.let { valid ->
                        prefs.edit().putString("starlight_serial", valid).apply()
                    }
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
        // Matched by canonical hex (not simKey, which many wand codes share) and never rewrites hex
        // or a user's name (spec §5.4): the row's key stays stable.
        val key = HexUtils.canonicalHex(packet.hex)
        val idx = learnedColors.indexOfFirst { it.typeInfo == "starlight" && HexUtils.canonicalHex(it.hex) == key }
        if (idx >= 0) {
            val existing = learnedColors[idx]
            val updated = LibraryRows.relabelOnRehear(existing, packet, verified)
            // A wand broadcasts the same packet continuously; without this guard every repeat
            // rewrote the entire library to internal storage AND the SD card.
            if (updated != existing) {
                learnedColors = learnedColors.toMutableList().also { it[idx] = updated }
                save()
                ServiceState.bumpStoreRevision()
            }
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
        // The CSV session log is the durable record, so the in-memory list only feeds the UI:
        // cap it, and do NOT save() here. An uncapped list plus a full-library JSON rewrite per
        // packet is an O(n^2) write storm that ANRs a long session.
        recordings = (listOf(rec) + recordings).take(MAX_RECORDINGS)
        appendToSession(rec)                 // full chronological log (replay source)
        if (band) appendToBandSession(rec)   // band-only log
        accumulateUnique(rec)                // dedup tally, written at session end
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

    // Deletes tombstone the hex when it is syncable and remove every learned row and user preset
    // with it (the TOMBSTONE projection, D-P3-6); a learn path then never brings it back.

    @Synchronized
    fun deleteLearnedColor(id: Long) {
        val row = learnedColors.firstOrNull { it.id == id } ?: return
        librarySync.onDelete(listOf(row.hex))
        save()
        ServiceState.bumpStoreRevision()
    }

    @Synchronized
    fun deleteLearnedLibrary(id: Long) {
        val row = learnedLibrary.firstOrNull { it.id == id } ?: return
        librarySync.onDelete(listOf(row.hex))
        save()
        ServiceState.bumpStoreRevision()
    }

    @Synchronized
    fun deleteLearnedRaw(id: Long) {
        val row = learnedRaw.firstOrNull { it.id == id } ?: return
        librarySync.onDelete(listOf(row.hex))
        save()
        ServiceState.bumpStoreRevision()
    }

    @Synchronized
    fun clearLearnedStarlight() {
        val hexes = learnedColors.filter { it.typeInfo == "starlight" }.map { it.hex }
        if (hexes.isEmpty()) return
        librarySync.onDelete(hexes, bulk = true)
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

    // Kept after every property: Kotlin runs initializers in textual order, and load() / save()
    // use the save executor, the sync state and externalAuthoritative declared above.
    init {
        load()
        if (presets.isEmpty()) {
            presets = PresetCatalog.asMagicPackets().mapIndexed { index, packet ->
                packet.copy(id = index + 1L)
            }
            nextPacketId = maxOf(nextPacketId, presets.size + 1L)
            save()
        } else {
            mergeBuiltInPresets()
        }
        refreshSessions()
    }

    companion object {
        /**
         * Gson fills a missing or mistyped row field with null whatever the Kotlin type says (a
         * hand-edited SD-card copy, an unknown category name). Such a row would throw in load(),
         * inside the app's onCreate, on every launch. Rows without a hex are dropped; the other
         * fields get their defaults. Clean files come back unchanged (same lists).
         */
        @Suppress("SENSELESS_COMPARISON", "USELESS_ELVIS")
        internal fun sanitizedState(s: PersistedState): PersistedState {
            fun clean(list: List<MagicPacket>?): List<MagicPacket> {
                if (list == null) return emptyList()
                var dirty = false
                val out = ArrayList<MagicPacket>(list.size)
                for (r in list) {
                    if (r == null || r.hex == null || r.hex.isBlank()) {
                        dirty = true
                        continue
                    }
                    if (r.label == null || r.category == null || r.typeInfo == null || r.colors == null || r.simKey == null) {
                        dirty = true
                        out.add(
                            r.copy(
                                label = r.label ?: "", category = r.category ?: MagicCategory.UNKNOWN,
                                typeInfo = r.typeInfo ?: "", colors = r.colors ?: "", simKey = r.simKey ?: "",
                            ),
                        )
                    } else {
                        out.add(r)
                    }
                }
                return if (dirty) out else list
            }
            return s.copy(
                presets = clean(s.presets), learnedColors = clean(s.learnedColors),
                learnedLibrary = clean(s.learnedLibrary), learnedRaw = clean(s.learnedRaw),
                autoRules = s.autoRules?.filterNotNull() ?: emptyList(),
            )
        }

        /** Safety cap on auto-learned raw packets so a relentless flood can't OOM/ANR the app. */
        private const val MAX_RAW_LIBRARY = 20000
        /** In-memory only (the CSV log is the durable record) — keeps saves bounded. */
        private const val MAX_RECORDINGS = 500
        /** Unreadable store files kept aside at load (keepUnreadableStore). */
        private const val KEEP_CORRUPT = 3
        private const val SESSION_HEADER =
            "timestamp_ms,hex,rssi,label,category,type_info,colors,note,source_address,is_band,lat,lng,accuracy\n"
        private const val PREFS_MAIN = "magicmaker"
        private const val PREFS_UI = "magicmaker_ui"
    }
}
