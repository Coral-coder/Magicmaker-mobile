package com.magicmaker.android.sync

import com.magicmaker.android.core.MagicClassifier
import com.magicmaker.android.core.MagicPacket

/**
 * The library rows as [LibrarySync] sees them (MagicStore in production, a fake in tests). Called
 * only with the store lock held.
 */
interface RowsAccess {
    var presets: List<MagicPacket>
    var learnedColors: List<MagicPacket>
    var learnedLibrary: List<MagicPacket>
    var learnedRaw: List<MagicPacket>

    /** The `newwand_names` pref: canonical HEX -> name. */
    var newWandNames: Map<String, String>

    /** A new device-local row id (`nextPacketId++`). */
    fun allocId(): Long

    /**
     * The store's learn routine with `fromSync = true` (plan §4.3): no ledger entry, no cloud push,
     * no serial pref, no rssi, no recording. False when it declines (ping, built-in duplicate, raw /
     * unclassified, noise, tombstoned).
     */
    fun learnFromSync(hex: String): Boolean

    fun bumpRevision()

    fun rebuildRawIndex()
}

/** MagicStore's save path. [urgent]: write at once (page commit, load), else coalesced. */
fun interface SaveSink {
    fun requestSave(urgent: Boolean)
}

/** One local change from the external-file diff or an import (plan §4.5). Hexes are canonical. */
sealed class LocalEditOp {
    abstract val hex: String

    /** Full state (PROTOCOL §4.5). [userEdited]: USER_EDITED flag (else PRESET only). */
    data class User(
        override val hex: String,
        val label: String,
        val category: Int,
        val kind: String?,
        val note: String?,
        val place: Int,
        val preset: Boolean,
        val userEdited: Boolean = true,
    ) : LocalEditOp()

    data class Reset(override val hex: String, val note: String?) : LocalEditOp()

    /** Delete: TOMBSTONE iff the key is syncable, rows removed either way. */
    data class Tombstone(override val hex: String) : LocalEditOp()

    /** A non-syncable hex vanished: remove its rows, no record. */
    data class RemoveRows(override val hex: String) : LocalEditOp()

    /** A classified hex appeared: the learn path (PRESENCE when it creates a row). */
    data class Learn(override val hex: String) : LocalEditOp()

    /** An unclassified hex appeared: a raw row, no record. */
    data class AddRaw(override val hex: String, val label: String?) : LocalEditOp()

    /** New-Wand name set ([name] non-null) or removed. */
    data class NewWand(override val hex: String, val name: String?) : LocalEditOp()
}

/**
 * The phone's ledger bound to its rows (plan §4.2, §4.3): implements [SyncLibraryPort] for the
 * runtime and the local-edit hooks MagicStore calls from its synchronized mutators. Every public
 * method runs `synchronized(lock)` (the MagicStore instance). Listener callbacks may run with the
 * lock held; listeners only post (§8).
 *
 * Invariant: the rows are the projection of the ledger. Local edits apply the same projection as
 * the matching remote class, so a local and a remote change of one key leave identical rows.
 */
class LibrarySync(
    private val rows: RowsAccess,
    ledger: LedgerStore,
    private val identity: SyncIdentityPort,
    private val saves: SaveSink,
    private val lock: Any,
    private val clock: () -> Long,
) : SyncLibraryPort {
    private var store: LedgerStore = ledger
    private val peers = LinkedHashMap<Bytes, StoredPeer>()
    private val pendingProjection = LinkedHashSet<String>()

    @Volatile private var durable: Long = 0

    @Volatile private var listener: SyncLibraryListener? = null

    private var skippedPresence = 0
    private var rejected = 0

    /** Load-time: the restored / migrated ledger, the peer table and what is already on disk. */
    fun install(ledger: LedgerStore, peerTable: Map<Bytes, StoredPeer>, durableHigh: Long) {
        synchronized(lock) {
            store = ledger
            peers.clear()
            for ((k, v) in peerTable) peers[k] = copyOf(v)
            pendingProjection.clear()
            durable = durableHigh
        }
    }

    /** The ledger (callers hold the lock). */
    internal val ledger: LedgerStore get() = store

    val nextSyncSeq: Long get() = synchronized(lock) { store.nextSyncSeq }

    /**
     * Deep snapshot for the store write, taken under the lock (§3.5). Page records still waiting
     * for their page's commit (the link dropped mid-page) are projected first: a re-pull of that
     * page finds them DUPLICATE, so this write is the last chance to keep rows = projection(ledger)
     * on disk. MagicStore reads the rows after this returns, under the same lock.
     */
    fun snapshot(): SyncStateJson = synchronized(lock) {
        projectPending()
        SyncStateJson.from(store, peers)
    }

    /** Project the page records accepted since the last commit, with one revision bump. Lock held. */
    private fun projectPending() {
        if (pendingProjection.isEmpty()) return
        val entries = pendingProjection.mapNotNull { store.get(it) }
        pendingProjection.clear()
        projectEntries(entries, remote = true)
        rows.bumpRevision()
    }

    /**
     * A store write holding every seq below [seqAtSnapshot] completed (§3.5): durableHigh, then
     * issuedSeq, then onDurable. Runs on the save thread without the store lock.
     */
    fun onSaved(seqAtSnapshot: Long) {
        val high: Long
        synchronized(this) {
            if (seqAtSnapshot - 1 > durable) durable = seqAtSnapshot - 1
            high = durable
        }
        identity.ensureIssued(seqAtSnapshot)
        listener?.onDurable(high)
    }

    // ---- SyncLibraryPort -------------------------------------------------------------------

    override fun durableHigh(): Long = durable

    override fun recordCount(): Int = synchronized(lock) { store.size }

    override fun stats(): LibrarySyncStats = synchronized(lock) {
        LibrarySyncStats(store.size, store.tombstoneCount(), store.nextSyncSeq, durable, skippedPresence, rejected)
    }

    override fun loadPeers(): Map<Bytes, StoredPeer> = synchronized(lock) {
        LinkedHashMap<Bytes, StoredPeer>().also { m -> for ((k, v) in peers) m[k] = copyOf(v) }
    }

    override fun putPeer(peerId: Bytes, state: PeerState, lastSyncMs: Long?) {
        synchronized(lock) {
            val old = peers[peerId]
            peers[peerId] = StoredPeer(PeerState(state.dbId, state.wm, state.excludeOk), lastSyncMs ?: old?.lastSyncMs ?: 0)
        }
        saves.requestSave(false)
    }

    override fun servePage(pull: Pull, excludeOk: Boolean, puller: Bytes): PageResult = synchronized(lock) {
        store.servePage(pull, excludeOk, puller, durable)
    }

    override fun applyRemote(body: Bytes, sender: Bytes, nowMs: Long?, live: Boolean): ApplyResult {
        val r: ApplyResult
        synchronized(lock) {
            r = store.applyRemote(body, sender, nowMs)
            when (r.status) {
                ApplyStatus.ACCEPT -> {
                    val e = r.entry!!
                    if (live) {
                        projectEntries(listOf(e), remote = true)
                        rows.bumpRevision()
                    } else {
                        pendingProjection.add(e.keyString)
                    }
                }
                ApplyStatus.BAD_MSG, ApplyStatus.CLOCK -> rejected++
                ApplyStatus.DUPLICATE, ApplyStatus.STALE -> Unit
            }
        }
        if (r.status == ApplyStatus.ACCEPT && live) saves.requestSave(false)
        return r
    }

    override fun commitPage(peerId: Bytes, state: PeerState, lastSyncMs: Long) {
        synchronized(lock) {
            projectPending()
            peers[peerId] = StoredPeer(PeerState(state.dbId, state.wm, state.excludeOk), lastSyncMs)
        }
        saves.requestSave(true)
    }

    override fun requestSave() = saves.requestSave(false)

    override fun setListener(listener: SyncLibraryListener?) {
        this.listener = listener
    }

    // ---- local-edit hooks (called by MagicStore with its lock held) -------------------------

    /** The hex has a ledger entry (spec §2.4). */
    fun isSyncable(hex: String): Boolean = synchronized(lock) { store.get(LibraryRows.libKeyString(LibraryRows.canon(hex))) != null }

    /** Learn paths skip a tombstoned hex (spec §2.7). Hot path: one hash lookup. */
    fun isTombstoned(hex: String): Boolean = synchronized(lock) {
        store.get(LibraryRows.libKeyString(LibraryRows.canon(hex)))?.isTombstone == true
    }

    /**
     * Rename / recategorise / note (spec §5.3): applied to **all** rows with the hex. [label],
     * [category], [note]: null = unchanged; a blank [label] = RESET (D-P3-7); a blank [note] clears
     * it. Returns the stored entry (null when the hex has no row or is not syncable).
     */
    fun onUserEdit(hex: String, label: String?, category: Int?, note: String?): LedgerEntry? = synchronized(lock) {
        val h = LibraryRows.canon(hex)
        val placed = rowsOf(h)
        if (placed.isEmpty()) return null
        val newNote = if (note != null) SyncText.normalizeNote(note) else currentNote(placed)
        val e = if (label != null && SyncText.normalizeLabel(label) == null) {
            localReset(h, newNote)
        } else {
            val first = placed.first()
            val newLabel = SyncText.normalizeLabel(label ?: first.row.label) ?: SyncText.normalizeLabel(LibraryRows.derived(h).label)!!
            localUser(
                LocalEditOp.User(
                    h, newLabel, category ?: LibraryRows.categoryCode(first.row.category), SyncText.normalizeKind(first.row.typeInfo),
                    newNote, first.place, placed.any { it.isUserPreset }, userEdited = true,
                ),
            )
        }
        finishLocal(listOfNotNull(e), bulk = false)
        e
    }

    /** setNote (spec §5.3): USER if the row is user-edited, else RESET carrying the note. */
    fun onNote(hex: String, note: String?): LedgerEntry? = synchronized(lock) {
        val h = LibraryRows.canon(hex)
        val placed = rowsOf(h)
        if (placed.isEmpty()) return null
        if (placed.any { it.row.userEdited == true }) return onUserEdit(h, null, null, note ?: "")
        val e = localReset(h, note?.let { SyncText.normalizeNote(it) })
        finishLocal(listOfNotNull(e), bulk = false)
        e
    }

    /**
     * saveCustomPreset (USER|PRESET; beats a tombstone). Call after the user preset row is in
     * `presets`. [userTyped] sets USER_EDITED. A preset saved without a typed label keeps the label
     * of a row the user already renamed, so the projection never undoes that rename.
     */
    fun onSavePreset(hex: String, label: String, userTyped: Boolean): LedgerEntry? = synchronized(lock) {
        val h = LibraryRows.canon(hex)
        val placed = rowsOf(h)
        val preset = placed.firstOrNull { it.isUserPreset } ?: return null
        var useLabel = label
        var edited = userTyped
        if (!userTyped) {
            placed.firstOrNull { !it.isUserPreset && it.row.userEdited == true }?.let {
                useLabel = it.row.label
                edited = true
            }
        }
        val nLabel = SyncText.normalizeLabel(useLabel) ?: SyncText.normalizeLabel(LibraryRows.derived(h).label)!!
        val e = localUser(
            LocalEditOp.User(
                h, nLabel, LibraryRows.categoryCode(preset.row.category), SyncText.normalizeKind(preset.row.typeInfo),
                currentNote(placed), SyncConst.PLACE_PRESETS, true, edited,
            ),
        )
        finishLocal(listOfNotNull(e), bulk = false)
        e
    }

    /**
     * Deletes (spec §2.7, D-P3-6): every learned row and user preset with each hex goes, built-ins
     * reset; a TOMBSTONE for each syncable key. Multi-key deletes are bulk.
     */
    fun onDelete(hexes: List<String>, bulk: Boolean = false): List<LedgerEntry> = synchronized(lock) {
        val out = ArrayList<LedgerEntry>()
        val projs = LinkedHashMap<String, Proj>()
        for (hex in hexes) {
            val h = LibraryRows.canon(hex)
            if (h in projs) continue
            projs[h] = Proj.Tombstone(h)
            tombstoneRecord(h)?.let { out.add(it) }
        }
        projectLib(projs, remote = false)
        finishLocal(out, bulk || hexes.size > 1)
        out
    }

    /** A learn path created a row in presets (user) / colors / library: PRESENCE iff no entry. */
    fun onLearned(hex: String): LedgerEntry? = synchronized(lock) {
        val e = presenceRecord(LibraryRows.canon(hex))
        finishLocal(listOfNotNull(e), bulk = false)
        e
    }

    /** [onLearned] for a batch (imports): one bulk notification. */
    fun onLearnedAll(hexes: Collection<String>): List<LedgerEntry> = synchronized(lock) {
        val out = hexes.mapNotNull { presenceRecord(LibraryRows.canon(it)) }
        finishLocal(out, bulk = true)
        out
    }

    /**
     * New-Wand name (NEWWAND; blank = DELETED). Updates `newwand_names` and returns the new map.
     * A hex that is not a valid packet only changes the pref.
     */
    fun onNewWandName(hex: String, name: String): Map<String, String> = synchronized(lock) {
        val (map, e) = newWandEdit(LibraryRows.canon(hex), name)
        finishLocal(listOfNotNull(e), bulk = false)
        map
    }

    /** External-file diff / import (plan §4.5): every op stamped now, origin self, bulk. */
    fun onDiff(edits: List<LocalEditOp>): List<LedgerEntry> = synchronized(lock) {
        val out = ArrayList<LedgerEntry>()
        for (op in edits) {
            val h = LibraryRows.canon(op.hex)
            when (op) {
                is LocalEditOp.User -> localUser(op.copy(hex = h))?.let { out.add(it) }
                is LocalEditOp.Reset -> localReset(h, op.note?.let { SyncText.normalizeNote(it) })?.let { out.add(it) }
                is LocalEditOp.Tombstone -> {
                    tombstoneRecord(h)?.let { out.add(it) }
                    projectLib(mapOf(h to Proj.Tombstone(h)), remote = false)
                }
                is LocalEditOp.RemoveRows -> removeRows(h)
                is LocalEditOp.Learn -> if (!isTombstoned(h) && rowsOf(h).isEmpty() && rows.learnFromSync(h)) {
                    presenceRecord(h)?.let { out.add(it) }
                }
                is LocalEditOp.AddRaw -> if (!isTombstoned(h) && rowsOf(h).isEmpty()) addRawRow(h, op.label)
                is LocalEditOp.NewWand -> newWandEdit(h, op.name ?: "").second?.let { out.add(it) }
            }
        }
        finishLocal(out, bulk = true)
        out
    }

    // ---- record building -------------------------------------------------------------------

    private fun self(): Bytes = identity.deviceId

    /** USER record (when the key is valid) + its projection on every row with the hex. */
    private fun localUser(op: LocalEditOp.User): LedgerEntry? {
        val key = LibraryRows.keyFor(op.hex)
        val label = SyncText.normalizeLabel(op.label) ?: SyncText.normalizeLabel(LibraryRows.derived(op.hex).label)!!
        var proj = Proj.User(op.hex, label, op.category, op.kind?.let { SyncText.normalizeKind(it) },
            op.note?.let { SyncText.normalizeNote(it) }, op.place, op.preset)
        var entry: LedgerEntry? = null
        if (key != null) {
            val r = store.localEdit(
                RecordClass.USER, key, clock(), self(), label = proj.label, category = proj.category, kind = proj.kind,
                place = proj.place, note = proj.note, preset = proj.preset, userEdited = op.userEdited || !op.preset,
            )
            entry = r.entry
            proj = projOf(r.body) as Proj.User
        }
        projectLib(mapOf(op.hex to proj), remote = false)
        return entry
    }

    private fun localReset(h: String, note: String?): LedgerEntry? {
        val key = LibraryRows.keyFor(h)
        var proj = Proj.Reset(h, note)
        var entry: LedgerEntry? = null
        if (key != null) {
            val r = store.localEdit(RecordClass.RESET, key, clock(), self(), note = note)
            entry = r.entry
            proj = projOf(r.body) as Proj.Reset
        }
        projectLib(mapOf(h to proj), remote = false)
        return entry
    }

    /** TOMBSTONE iff the key has a live (non-deleted) entry; null otherwise. No projection. */
    private fun tombstoneRecord(h: String): LedgerEntry? {
        val key = LibraryRows.keyFor(h) ?: return null
        val cur = store.get(key) ?: return null
        if (cur.isTombstone) return null
        return store.localEdit(RecordClass.TOMBSTONE, key, clock(), self()).entry
    }

    private fun presenceRecord(h: String): LedgerEntry? {
        val key = LibraryRows.keyFor(h) ?: return null
        return store.localLearn(key.packet)
    }

    private fun newWandEdit(h: String, name: String): Pair<Map<String, String>, LedgerEntry?> {
        val n = SyncText.normalizeLabel(name)
        val key = LibraryRows.keyFor(h, SyncConst.NS_NEWWAND)
        val entry = if (key != null) store.localEdit(RecordClass.NEWWAND, key, clock(), self(), label = n).entry else null
        val m = LinkedHashMap(rows.newWandNames)
        if (n == null) m.remove(h) else m[h] = n
        rows.newWandNames = m
        return m to entry
    }

    private fun finishLocal(entries: List<LedgerEntry>, bulk: Boolean) {
        if (entries.isEmpty()) return
        listener?.onLocalChanges(entries, bulk)
        saves.requestSave(false)
    }

    // ---- projection (spec §2.6, plan §4.3) -------------------------------------------------

    internal sealed class Proj {
        abstract val hex: String

        data class Tombstone(override val hex: String) : Proj()

        data class User(
            override val hex: String,
            val label: String,
            val category: Int,
            val kind: String?,
            val note: String?,
            val place: Int,
            val preset: Boolean,
        ) : Proj()

        data class Reset(override val hex: String, val note: String?) : Proj()

        data class Presence(override val hex: String) : Proj()
    }

    private fun projOf(b: RecordBody): Proj {
        val h = b.key.packet.hex()
        return when (b.recordClass()) {
            RecordClass.TOMBSTONE -> Proj.Tombstone(h)
            RecordClass.USER -> Proj.User(h, b.label!!, b.category!!, b.kind, b.note, b.place!!, b.flags and SyncConst.FLAG_PRESET != 0)
            RecordClass.RESET -> Proj.Reset(h, b.note)
            RecordClass.PRESENCE -> Proj.Presence(h)
            RecordClass.NEWWAND -> throw IllegalArgumentException("NEWWAND is not a LIB projection")
        }
    }

    /** Project current entries: LIB in one pass per list, NEWWAND onto `newwand_names`. */
    private fun projectEntries(entries: Collection<LedgerEntry>, remote: Boolean) {
        val lib = LinkedHashMap<String, Proj>()
        var names: LinkedHashMap<String, String>? = null
        for (e in entries) {
            if (e.key.ns == SyncConst.NS_NEWWAND) {
                val m = names ?: LinkedHashMap(rows.newWandNames).also { names = it }
                val h = e.key.packet.hex()
                val label = e.body.label
                if (e.isTombstone || label == null) m.remove(h) else m[h] = label
            } else {
                lib[e.key.packet.hex()] = projOf(e.body)
            }
        }
        names?.let { if (it != rows.newWandNames) rows.newWandNames = it }
        projectLib(lib, remote)
    }

    /** Apply [projs] (canonical hex -> projection) to the rows: one pass per list, then the adds. */
    private fun projectLib(projs: Map<String, Proj>, remote: Boolean) {
        if (projs.isEmpty()) return
        val present = HashSet<String>()
        val userPreset = HashSet<String>()
        val touched = BooleanArray(5)
        fun scan(place: Int, list: List<MagicPacket>) {
            for (r in list) {
                val h = LibraryRows.canon(r.hex)
                if (h !in projs) continue
                present.add(h)
                touched[place] = true
                if (place == SyncConst.PLACE_PRESETS && r.userRecorded) userPreset.add(h)
            }
        }
        scan(SyncConst.PLACE_PRESETS, rows.presets)
        scan(SyncConst.PLACE_COLORS, rows.learnedColors)
        scan(SyncConst.PLACE_LIBRARY, rows.learnedLibrary)
        scan(SyncConst.PLACE_RAW, rows.learnedRaw)
        // Hexes that still have a row after the passes: a USER without PRESET removes the user
        // preset row, and when that was the hex's only row the record's `place` gets one (spec §2.6
        // "if no row exists, create one in place"), so the packet never vanishes from this phone
        // while it shows on the peer.
        val kept = HashSet<String>()

        if (touched[SyncConst.PLACE_PRESETS]) {
            rows.presets = rows.presets.mapNotNull { r ->
                val h = LibraryRows.canon(r.hex)
                when (val p = projs[h]) {
                    null -> r
                    is Proj.Tombstone -> if (r.userRecorded) null else resetBuiltIn(r)
                    is Proj.User -> if (r.userRecorded && !p.preset) null else applyUser(r, p)
                    is Proj.Reset -> applyReset(r, p)
                    is Proj.Presence -> r
                }?.also { if (h in projs) kept.add(h) }
            }
        }
        fun learned(list: List<MagicPacket>): List<MagicPacket> = list.mapNotNull { r ->
            val h = LibraryRows.canon(r.hex)
            when (val p = projs[h]) {
                null -> r
                is Proj.Tombstone -> null
                is Proj.User -> applyUser(r, p)
                is Proj.Reset -> applyReset(r, p)
                is Proj.Presence -> r
            }?.also { if (h in projs) kept.add(h) }
        }
        if (touched[SyncConst.PLACE_COLORS]) rows.learnedColors = learned(rows.learnedColors)
        if (touched[SyncConst.PLACE_LIBRARY]) rows.learnedLibrary = learned(rows.learnedLibrary)
        var rawChanged = false
        if (touched[SyncConst.PLACE_RAW]) {
            val before = rows.learnedRaw
            rows.learnedRaw = learned(before)
            rawChanged = rows.learnedRaw.size != before.size
        }

        // Adds: a PRESET without a user preset row; a USER / PRESENCE / RESET with no row at all.
        var libraryAdded = false
        for (p in projs.values) {
            when (p) {
                is Proj.Tombstone -> Unit
                is Proj.User -> when {
                    p.preset && p.hex !in userPreset -> rows.presets = rows.presets + newRow(p, SyncConst.PLACE_PRESETS)
                    !p.preset && p.hex !in kept -> {
                        val place = if (p.place == SyncConst.PLACE_PRESETS) SyncConst.PLACE_LIBRARY else p.place
                        val row = newRow(p, place)
                        when (place) {
                            SyncConst.PLACE_COLORS -> rows.learnedColors = rows.learnedColors + row
                            SyncConst.PLACE_RAW -> {
                                rows.learnedRaw = rows.learnedRaw + row
                                rawChanged = true
                            }
                            else -> {
                                rows.learnedLibrary = rows.learnedLibrary + row
                                libraryAdded = true
                            }
                        }
                    }
                }
                is Proj.Reset, is Proj.Presence -> if (p.hex !in present) {
                    if (!rows.learnFromSync(p.hex) && remote) skippedPresence++
                }
            }
        }
        if (libraryAdded) rows.learnedLibrary = rows.learnedLibrary.sortedBy { it.label.lowercase() }
        if (rawChanged) rows.rebuildRawIndex()
    }

    private fun applyUser(r: MagicPacket, p: Proj.User): MagicPacket {
        val cat = LibraryRows.categoryOf(p.category)
        val kind = p.kind ?: r.typeInfo
        if (r.label == p.label && r.category == cat && r.typeInfo == kind && r.note == p.note && r.userEdited == true) return r
        return r.copy(label = p.label, category = cat, typeInfo = kind, note = p.note, userEdited = true)
    }

    private fun applyReset(r: MagicPacket, p: Proj.Reset): MagicPacket {
        val d = LibraryRows.derived(r.hex)
        if (r.label == d.label && r.category == d.category && r.userEdited == null && r.note == p.note) return r
        return r.copy(label = d.label, category = d.category, userEdited = null, note = p.note)
    }

    private fun resetBuiltIn(r: MagicPacket): MagicPacket {
        val b = LibraryRows.builtIn(r.hex) ?: return r.copy(userEdited = null, note = null)
        return r.copy(label = b.label, category = b.category, typeInfo = b.typeInfo, userEdited = null, note = null)
    }

    /** A row created by a USER projection (spec §2.6): classifier colours / simKey when known. */
    private fun newRow(p: Proj.User, place: Int): MagicPacket {
        val c = MagicClassifier.classify(p.hex)
        val cat = LibraryRows.categoryOf(p.category)
        return when (place) {
            SyncConst.PLACE_RAW -> MagicPacket(
                id = rows.allocId(), hex = p.hex, label = p.label, category = cat, typeInfo = p.kind ?: "raw",
                colors = "", simKey = "RAW:${p.hex}", userRecorded = false, note = p.note, userEdited = true,
            )
            SyncConst.PLACE_PRESETS -> MagicPacket(
                id = rows.allocId(), hex = p.hex, label = p.label, category = cat, typeInfo = p.kind ?: c?.typeInfo ?: "raw",
                colors = c?.colors ?: "", simKey = c?.simKey ?: "USER:${p.hex}", userRecorded = true, note = p.note,
                userEdited = true,
            )
            else -> MagicPacket(
                id = rows.allocId(), hex = p.hex, label = p.label, category = cat, typeInfo = p.kind ?: c?.typeInfo ?: "raw",
                colors = c?.colors ?: "", simKey = c?.simKey ?: "USER:${p.hex}", userRecorded = true, note = p.note,
                userEdited = true,
            )
        }
    }

    private fun addRawRow(h: String, label: String?) {
        val row = MagicPacket(
            id = rows.allocId(), hex = h, label = label?.let { SyncText.normalizeLabel(it) } ?: MagicClassifier.rawLabel(h),
            category = com.magicmaker.android.core.MagicCategory.UNKNOWN, typeInfo = "raw", simKey = "RAW:$h",
            userRecorded = true,
        )
        rows.learnedRaw = rows.learnedRaw + row
        rows.rebuildRawIndex()
    }

    private fun removeRows(h: String) {
        fun drop(list: List<MagicPacket>) = list.filterNot { LibraryRows.canon(it.hex) == h }
        rows.presets = drop(rows.presets)
        rows.learnedColors = drop(rows.learnedColors)
        rows.learnedLibrary = drop(rows.learnedLibrary)
        val raw = drop(rows.learnedRaw)
        if (raw.size != rows.learnedRaw.size) {
            rows.learnedRaw = raw
            rows.rebuildRawIndex()
        }
    }

    /** The rows of [h] in list order (presets, colors, library, raw). */
    private fun rowsOf(h: String): List<LibraryRows.Placed> {
        val out = ArrayList<LibraryRows.Placed>(2)
        for (r in rows.presets) if (LibraryRows.canon(r.hex) == h) out.add(LibraryRows.Placed(SyncConst.PLACE_PRESETS, r))
        for (r in rows.learnedColors) if (LibraryRows.canon(r.hex) == h) out.add(LibraryRows.Placed(SyncConst.PLACE_COLORS, r))
        for (r in rows.learnedLibrary) if (LibraryRows.canon(r.hex) == h) out.add(LibraryRows.Placed(SyncConst.PLACE_LIBRARY, r))
        for (r in rows.learnedRaw) if (LibraryRows.canon(r.hex) == h) out.add(LibraryRows.Placed(SyncConst.PLACE_RAW, r))
        return out
    }

    private fun currentNote(placed: List<LibraryRows.Placed>): String? =
        placed.firstNotNullOfOrNull { it.row.note }?.let { SyncText.normalizeNote(it) }

    private fun copyOf(p: StoredPeer) = StoredPeer(PeerState(p.state.dbId, p.state.wm, p.state.excludeOk), p.lastSyncMs)
}
