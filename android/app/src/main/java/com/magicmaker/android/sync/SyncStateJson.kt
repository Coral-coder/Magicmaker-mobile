package com.magicmaker.android.sync

import java.util.Base64

/**
 * The `sync` section of `magicmaker_store.json` (plan §3.1). Short keys; Gson omits nulls. Every
 * field is nullable because Gson builds these with Unsafe and leaves missing fields null.
 */
data class SyncStateJson(
    val schema: Int? = null,
    val nextSyncSeq: Long? = null,
    val lastLocalStamp: Long? = null,
    val ledger: Map<String, LedgerEntryJson>? = null,
    val peers: Map<String, PeerJson>? = null,
) {
    companion object {
        const val SCHEMA: Int = 1

        /** An empty ledger (first launch with no store, or a seeded store). */
        fun empty(): SyncStateJson = SyncStateJson(SCHEMA, 1, 0, emptyMap(), emptyMap())

        /** Snapshot [store] and [peers] (deep: fresh DTOs, safe to serialize outside the lock). */
        fun from(store: LedgerStore, peers: Map<Bytes, StoredPeer>): SyncStateJson {
            val ledger = LinkedHashMap<String, LedgerEntryJson>()
            for (e in store.entriesBySeq()) ledger[e.keyString] = LedgerEntryJson.of(e)
            val p = LinkedHashMap<String, PeerJson>()
            for ((id, sp) in peers.entries.sortedBy { it.key }) {
                p[id.hex()] = PeerJson(sp.state.dbId.hex(), sp.state.wm, sp.state.excludeOk, sp.lastSyncMs)
            }
            return SyncStateJson(SCHEMA, store.nextSyncSeq, store.lastLocalStamp, ledger, p)
        }
    }
}

/**
 * One ledger entry (PROTOCOL §6.1): `u` updatedAt, `o` origin hex (absent for PRESENCE), `c` bodyCrc,
 * `b` canonical body base64 (absent for PRESENCE: rebuilt), `s` syncSeq, `f` syncFrom hex.
 */
data class LedgerEntryJson(
    val u: Long? = null,
    val o: String? = null,
    val c: Long? = null,
    val b: String? = null,
    val s: Long? = null,
    val f: String? = null,
) {
    companion object {
        fun of(e: LedgerEntry): LedgerEntryJson = LedgerEntryJson(
            u = e.version.updatedAt,
            o = e.origin?.hex(),
            c = e.version.crc,
            b = if (e.recordClass == RecordClass.PRESENCE) null else Base64.getEncoder().encodeToString(e.bodyBytes.toByteArray()),
            s = e.seq,
            f = e.syncFrom?.hex(),
        )
    }
}

/** A persisted peer-table row (PROTOCOL §15.1) plus the last completed pull time. */
data class PeerJson(
    val dbId: String? = null,
    val wm: Long? = null,
    val excludeOk: Boolean? = null,
    val lastSyncMs: Long? = null,
)

/** [corrupt]: at least one stored entry or peer was invalid and dropped (load table, §3.6). */
class RestoredSync(
    val ledger: LedgerStore,
    val peers: LinkedHashMap<Bytes, StoredPeer>,
    val corrupt: Boolean,
    val dropped: List<String>,
)

object SyncStateCodec {
    /**
     * Rebuild the ledger and peer table from [json]. Every entry goes through
     * [LedgerEntry.restore] (decode + validate) and must match its `u`/`o`/`c`/key; a bad entry is
     * dropped and makes the result [RestoredSync.corrupt]. nextSyncSeq stays above every seq.
     */
    fun restore(json: SyncStateJson, tombstoneCap: Int = SyncConst.TOMBSTONE_CAP_PHONE): RestoredSync {
        val dropped = ArrayList<String>()
        val good = ArrayList<LedgerEntry>()
        val seqs = HashSet<Long>()
        val raw = json.ledger ?: emptyMap()
        // Lowest seq first, so a duplicated seq keeps the earlier-stored entry deterministically.
        for ((k, j) in raw.entries.sortedWith(compareBy({ it.value.s ?: Long.MAX_VALUE }, { it.key }))) {
            val e = entryOf(k, j)
            if (e == null || !seqs.add(e.seq)) {
                dropped.add(k)
                continue
            }
            good.add(e)
        }
        val maxSeq = good.maxOfOrNull { it.seq } ?: 0
        var next = json.nextSyncSeq ?: (maxSeq + 1)
        if (next < 1) next = 1
        val store = LedgerStore(tombstoneCap)
        val corruptLedger = dropped.isNotEmpty() || json.nextSyncSeq == null
        // §3.6 row "corrupt ledger": keep the valid entries, nextSyncSeq = max(s) + 1.
        if (corruptLedger) next = maxSeq + 1
        store.restore(good, maxOf(next, maxSeq + 1), json.lastLocalStamp ?: 0)
        val peers = LinkedHashMap<Bytes, StoredPeer>()
        var badPeer = false
        for ((id, p) in json.peers ?: emptyMap()) {
            val sp = peerOf(id, p)
            if (sp == null) {
                badPeer = true
                dropped.add("peer:$id")
            } else {
                peers[sp.first] = sp.second
            }
        }
        return RestoredSync(store, peers, corruptLedger || badPeer, dropped)
    }

    /** Null when [j] is not a valid stored entry for map key [k]. */
    fun entryOf(k: String, j: LedgerEntryJson): LedgerEntry? {
        val key = RecordKey.parseKeyString(k) ?: return null
        val s = j.s ?: return null
        if (s < 1) return null
        val f = j.f?.let { hex8(it) ?: return null }
        val bytes: Bytes = if (j.b == null) {
            if (j.u != SyncConst.U_PRESENCE || j.o != null) return null
            RecordBody(key, SyncConst.U_PRESENCE).encode()
        } else {
            runCatching { Bytes.of(Base64.getDecoder().decode(j.b)) }.getOrNull() ?: return null
        }
        val e = try {
            LedgerEntry.restore(bytes, s, f)
        } catch (x: SyncException) {
            return null
        }
        if (e.keyString != k) return null
        if (e.version.updatedAt != j.u) return null
        if (e.origin?.hex() != j.o) return null
        if (e.version.crc != j.c) return null
        return e
    }

    private fun peerOf(id: String, p: PeerJson): Pair<Bytes, StoredPeer>? {
        val peerId = hex8(id) ?: return null
        val db = p.dbId?.let { hex8(it) } ?: return null
        val wm = p.wm ?: return null
        if (wm < 0) return null
        return peerId to StoredPeer(PeerState(db, wm, p.excludeOk ?: false), p.lastSyncMs ?: 0)
    }

    /** 16 hex digits -> 8 bytes, else null. (dbId may be all zero: "unknown".) */
    private fun hex8(s: String): Bytes? {
        if (s.length != 16) return null
        return runCatching { Bytes.fromHex(s) }.getOrNull()
    }
}
