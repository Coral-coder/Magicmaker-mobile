package com.magicmaker.android.sync

import java.util.TreeMap

/**
 * The phone's ledger (plan §4.1): the P1 [Ledger] (unchanged) plus the feed index `seq -> key`
 * that always holds the **current** seq of each key, so a page is a range scan. Pure and not
 * thread-safe: [LibrarySync] calls it under the store lock.
 */
class LedgerStore(private val tombstoneCap: Int = SyncConst.TOMBSTONE_CAP_PHONE, nextSyncSeq: Long = 1) {
    private var ledger = Ledger(tombstoneCap, nextSyncSeq)
    private val feed = TreeMap<Long, String>()
    private val seqOf = HashMap<String, Long>()

    val size: Int get() = ledger.size
    val nextSyncSeq: Long get() = ledger.nextSyncSeq
    val lastLocalStamp: Long get() = ledger.lastLocalStamp

    fun get(key: RecordKey): LedgerEntry? = ledger.get(key)

    fun get(keyString: String): LedgerEntry? = ledger.get(keyString)

    fun tombstoneCount(): Int = ledger.tombstoneCount()

    fun entriesBySeq(): List<LedgerEntry> = feed.values.map { ledger.get(it)!! }

    fun entriesByKey(): List<LedgerEntry> = ledger.entriesByKey()

    /** The feed index as seq -> key string (tests). */
    fun feedIndex(): Map<Long, String> = TreeMap(feed)

    /** Replace the content with stored entries (§3.1). nextSyncSeq stays above every seq. */
    fun restore(entries: Collection<LedgerEntry>, nextSyncSeq: Long, lastLocalStamp: Long) {
        ledger = Ledger(tombstoneCap, maxOf(1, nextSyncSeq))
        feed.clear()
        seqOf.clear()
        for (e in entries) {
            ledger.get(e.keyString)?.let { unindex(it.keyString) }
            ledger.restore(e)
            index(e)
        }
        ledger.lastLocalStamp = lastLocalStamp
    }

    /** §6.2. On ACCEPT the feed moves the key to its new seq and drops evicted keys. */
    fun applyRemote(bodyBytes: Bytes, sender: Bytes?, nowMs: Long?): ApplyResult {
        val r = ledger.applyRemote(bodyBytes, sender, nowMs)
        if (r.status == ApplyStatus.ACCEPT) track(r.entry, r.evicted)
        return r
    }

    /** A learn met a library packet: PRESENCE iff the key has no entry (§6.3). */
    fun localLearn(packet: Bytes): LedgerEntry? {
        val e = ledger.localLearn(packet) ?: return null
        track(e, emptyList())
        return e
    }

    /** A user edit (§6.4); see [Ledger.localEdit]. */
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
        val r = ledger.localEdit(cls, key, nowMs, self, label, category, kind, place, note, preset, userEdited)
        if (r.entry != null) {
            track(r.entry, r.evicted)
        } else {
            // The new entry was evicted at once by the tombstone cap: drop the old seq too.
            unindex(key.keyString)
            for (k in r.evicted) unindex(k)
        }
        return r
    }

    /**
     * Migration only (plan §4.4): store a ready body (a legacy USER / NEWWAND, u = 2) at the next
     * seq, as a local entry. Returns null when the key already has an entry.
     */
    fun insertLocal(body: RecordBody): LedgerEntry? {
        if (ledger.get(body.key) != null) return null
        val bytes = body.encode()
        val e = LedgerEntry(body, bytes, ledger.nextSyncSeq, null)
        ledger.restore(e)
        index(e)
        return e
    }

    /** The store's `sync` section for this ledger and [peers] (plan §3.1); see [SyncStateJson.from]. */
    fun toJson(peers: Map<Bytes, StoredPeer> = emptyMap()): SyncStateJson = SyncStateJson.from(this, peers)

    /** Serve a PULL durable-only (PROTOCOL §15.2): only entries with `seq <= durableHigh`. */
    fun servePage(pull: Pull, excludeOk: Boolean, puller: Bytes, durableHigh: Long): PageResult {
        val entries: List<FeedEntry> = if (pull.since >= durableHigh) {
            emptyList()
        } else {
            feed.subMap(pull.since + 1, true, durableHigh, true).values.map { ledger.get(it)!! }
        }
        return SyncRouting.servePage(entries, durableHigh, pull, excludeOk, puller)
    }

    companion object {
        /** Rebuild from a stored `sync` section (validated); see [SyncStateCodec.restore]. */
        fun fromJson(json: SyncStateJson, tombstoneCap: Int = SyncConst.TOMBSTONE_CAP_PHONE): RestoredSync =
            SyncStateCodec.restore(json, tombstoneCap)
    }

    private fun track(e: LedgerEntry?, evicted: List<String>) {
        if (e != null) {
            unindex(e.keyString)
            index(e)
        }
        for (k in evicted) unindex(k)
    }

    private fun index(e: LedgerEntry) {
        feed[e.seq] = e.keyString
        seqOf[e.keyString] = e.seq
    }

    private fun unindex(keyString: String) {
        val s = seqOf.remove(keyString) ?: return
        if (feed[s] == keyString) feed.remove(s)
    }
}
