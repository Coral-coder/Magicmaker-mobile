package com.magicmaker.android.sync

/** One stored feed entry, as page serving sees it (§15.2). */
interface FeedEntry {
    /** Local feed seq (`syncSeq`). */
    val seq: Long

    /** The verbatim canonical body bytes. */
    val bodyBytes: Bytes

    /** The body's origin (null for PRESENCE). */
    val origin: Bytes?

    /** `syncFrom`: the peer it was accepted from (null for local edits / learns). */
    val syncFrom: Bytes?
}

/**
 * A ledger entry (§6.1): the winning verbatim canonical body of one key with its version, local
 * feed seq [seq] (`s`) and [syncFrom] (`f`).
 */
class LedgerEntry(val body: RecordBody, override val bodyBytes: Bytes, override val seq: Long, override val syncFrom: Bytes?) :
    FeedEntry {
    val key: RecordKey get() = body.key
    val version: Version = Version.of(body, bodyBytes)
    val recordClass: RecordClass = body.recordClass()
    override val origin: Bytes? get() = body.origin
    val keyString: String get() = body.key.keyString

    /** "Tombstone" for the cap: any entry with the DELETED flag, in either namespace (§6.3). */
    val isTombstone: Boolean get() = body.isDeleted

    override fun toString(): String = "LedgerEntry($keyString u=${version.updatedAt} s=$seq)"

    companion object {
        /** Rebuild an entry from storage (P3/P4): decodes and validates the body. */
        fun restore(bodyBytes: Bytes, seq: Long, syncFrom: Bytes?): LedgerEntry =
            LedgerEntry(RecordBody.decode(bodyBytes), bodyBytes, seq, syncFrom)
    }
}

/** Results of [Ledger.applyRemote] (§6.2). */
enum class ApplyStatus { ACCEPT, DUPLICATE, STALE, BAD_MSG, CLOCK }

/**
 * [entry]: the stored entry on ACCEPT, the current entry on DUPLICATE / STALE, null on a reject.
 * [evicted]: key strings removed by the tombstone cap. [error]: the failure on BAD_MSG / CLOCK.
 */
class ApplyResult(val status: ApplyStatus, val entry: LedgerEntry?, val evicted: List<String>, val error: SyncException? = null)

/** [entry] is null when the new entry was evicted at once by the tombstone cap. */
class EditResult(val bodyBytes: Bytes, val body: RecordBody, val entry: LedgerEntry?, val evicted: List<String>)

/**
 * The replicated per-key state (§6): phones' ledger; the hub applies the same accept rule over its
 * log. Pure in-memory logic: persistence (one atomic write with the peer table) is the node's job.
 */
class Ledger(var tombstoneCap: Int = SyncConst.TOMBSTONE_CAP_PHONE, nextSyncSeq: Long = 1) {
    private val map = HashMap<String, LedgerEntry>()

    var nextSyncSeq: Long = nextSyncSeq
        private set

    /** The last local edit stamp (persisted with the ledger, §5.2). */
    var lastLocalStamp: Long = 0

    val size: Int get() = map.size

    fun get(key: RecordKey): LedgerEntry? = map[key.keyString]

    fun get(keyString: String): LedgerEntry? = map[keyString]

    /** Entries ordered by key string (the vectors' order). */
    fun entriesByKey(): List<LedgerEntry> = map.values.sortedBy { it.keyString }

    /** Entries in ascending feed seq (page-serving order). */
    fun entriesBySeq(): List<LedgerEntry> = map.values.sortedBy { it.seq }

    fun tombstoneCount(): Int = map.values.count { it.isTombstone }

    /** Load a stored entry as is (P3/P4 storage); keeps [nextSyncSeq] above every seq. */
    fun restore(entry: LedgerEntry) {
        map[entry.keyString] = entry
        if (entry.seq >= nextSyncSeq) nextSyncSeq = entry.seq + 1
    }

    private fun store(body: RecordBody, bytes: Bytes, syncFrom: Bytes?): Pair<LedgerEntry, List<String>> {
        val e = LedgerEntry(body, bytes, nextSyncSeq, syncFrom)
        nextSyncSeq++
        map[e.keyString] = e
        val evicted = if (e.isTombstone) evictTombstones() else emptyList()
        return e to evicted
    }

    /** Remove the smallest-version tombstone (ties: smallest key bytes) until the count is at the cap. */
    private fun evictTombstones(): List<String> {
        val tombs = map.values.filter { it.isTombstone }.toMutableList()
        if (tombs.size <= tombstoneCap) return emptyList()
        tombs.sortWith(compareBy<LedgerEntry> { it.version }.thenBy { it.key.encode() })
        val out = ArrayList<String>()
        var i = 0
        while (tombs.size - i > tombstoneCap) {
            val victim = tombs[i++]
            map.remove(victim.keyString)
            out.add(victim.keyString)
        }
        return out
    }

    /**
     * Apply a received record from [sender] (§6.2). [nowMs] null = receiver clock unknown (no
     * future check). Ledger unchanged unless ACCEPT.
     */
    fun applyRemote(bodyBytes: Bytes, sender: Bytes?, nowMs: Long?): ApplyResult {
        val body = try {
            val b = RecordBody.decode(bodyBytes)
            SyncClock.checkFuture(b.updatedAt, nowMs)
            b
        } catch (e: SyncException) {
            val st = if (e.code == ErrCode.CLOCK) ApplyStatus.CLOCK else ApplyStatus.BAD_MSG
            return ApplyResult(st, null, emptyList(), e)
        }
        val cur = get(body.key)
        if (cur != null) {
            val c = Version.of(body, bodyBytes).compareTo(cur.version)
            if (c == 0) return ApplyResult(ApplyStatus.DUPLICATE, cur, emptyList())
            if (c < 0) return ApplyResult(ApplyStatus.STALE, cur, emptyList())
        }
        val (e, ev) = store(body, bodyBytes, sender)
        return ApplyResult(ApplyStatus.ACCEPT, e, ev)
    }

    /**
     * A learn path met a library packet (§6.3): creates a PRESENCE entry only when the key has no
     * entry at all (a tombstone or any version blocks it). Returns the new entry or null.
     */
    fun localLearn(packet: Bytes): LedgerEntry? {
        val key = RecordKey(SyncConst.NS_LIB, packet)
        if (get(key) != null) return null
        val body = RecordBody(key, SyncConst.U_PRESENCE)
        return store(body, body.encode(), null).first
    }

    /**
     * A user edit (§5.2, §5.3, §6.4). [cls]: USER (rename / recategorise / note / save preset;
     * label required), RESET (the label was cleared; note only), TOMBSTONE (delete) or NEWWAND
     * (a blank / null label writes the deleted form). Text is normalised here. Stamps
     * `origin = self` and `updatedAt` per §5.2.
     */
    fun localEdit(
        cls: RecordClass,
        key: RecordKey,
        nowMs: Long,
        self: Bytes,
        label: String? = null,
        category: Int? = null,
        kind: String? = null,
        place: Int? = null,
        note: String? = null,
        preset: Boolean = false,
        userEdited: Boolean = true,
    ): EditResult {
        val cur = get(key)
        val u = SyncClock.localStamp(nowMs, cur?.version?.updatedAt ?: 0, lastLocalStamp)
        val nLabel = label?.let { SyncText.normalizeLabel(it) }
        val nNote = note?.let { SyncText.normalizeNote(it) }
        val nKind = kind?.let { SyncText.normalizeKind(it) }
        val body = when (cls) {
            RecordClass.USER -> {
                require(key.ns == SyncConst.NS_LIB) { "USER is a LIB record" }
                requireNotNull(nLabel) { "USER needs a non-blank label (a cleared label is RESET)" }
                val flags = (if (userEdited) SyncConst.FLAG_USER_EDITED else 0) or (if (preset) SyncConst.FLAG_PRESET else 0)
                require(flags != 0) { "USER needs USER_EDITED and/or PRESET" }
                RecordBody(key, u, self, flags, nLabel, category, nNote, nKind, place)
            }
            RecordClass.RESET -> {
                require(key.ns == SyncConst.NS_LIB) { "RESET is a LIB record" }
                RecordBody(key, u, self, note = nNote)
            }
            RecordClass.TOMBSTONE -> RecordBody(key, u, self, SyncConst.FLAG_DELETED)
            RecordClass.NEWWAND -> {
                require(key.ns == SyncConst.NS_NEWWAND) { "NEWWAND needs ns 1" }
                if (nLabel == null) RecordBody(key, u, self, SyncConst.FLAG_DELETED)
                else RecordBody(key, u, self, label = nLabel, note = nNote)
            }
            RecordClass.PRESENCE -> throw IllegalArgumentException("PRESENCE is written by localLearn")
        }
        val bytes = body.encode()
        lastLocalStamp = u
        val (e, ev) = store(body, bytes, null)
        return EditResult(bytes, body, if (map[e.keyString] === e) e else null, ev)
    }
}
