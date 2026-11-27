package com.magicmaker.android.sync

// P3 seam between the data layer (part 1: identity, ledger, rows, events and heartbeat models) and
// the runtime (part 2: SyncNode, transports, UI). docs/SYNC_P3_ANDROID_PLAN.md §8. Pure Kotlin.
// Frozen: change only by amending that plan.

/** The data layer. Installed once by MagicMakerApp.onCreate (part 1); read by part 2. */
object SyncPorts {
    @Volatile
    private var current: SyncData? = null

    fun install(data: SyncData) {
        current = data
    }

    /** Null until installed (part 1 not merged, or a unit test). */
    val data: SyncData? get() = current
}

interface SyncData {
    val identity: SyncIdentityPort
    val library: SyncLibraryPort

    /** Once per service start: epoch = max(nowMs / 1000, lastEpoch + 1), persisted before return (§2.8). */
    fun startEventOrigin(nowMs: Long, ringCap: Int): EventOriginPort

    fun newRuntimeEstimator(): RuntimeEstimatorPort

    fun newRoster(): DeviceRosterPort
}

/**
 * noBackupFilesDir/sync_identity.json. Thread-safe; every write is atomic and synchronous.
 * [dbId] is fixed for the process lifetime (rollback is decided at load).
 */
interface SyncIdentityPort {
    val deviceId: Bytes
    val dbId: Bytes
    val group: SyncGroup?

    /** Persist the group (a JOIN was accepted) or null (leave). Returns once the file is on disk. */
    fun setGroup(group: SyncGroup?)

    /** PROTOCOL §15.4: issuedSeq >= [seq] on disk before a live REC carrying feed seq (seq - 1) is sent. */
    fun ensureIssued(seq: Long)

    /** The ESP32 hub's BLE address, remembered after the first AUTHED hub session. */
    val hubAddress: String?

    fun setHubAddress(address: String?)

    fun isForeign(address: String): Boolean

    fun markForeign(address: String)
}

/** A persisted peer-table row (§15.1) plus when this phone last completed a pull from it (0 = never). */
class StoredPeer(val state: PeerState, val lastSyncMs: Long)

data class LibrarySyncStats(
    val records: Int,
    val tombstones: Int,
    val nextSyncSeq: Long,
    val durableHigh: Long,
    val skippedPresence: Int,
    val rejected: Int,
)

/**
 * Called on whatever thread made the change (main, packet executor, save executor), possibly while
 * the store lock is held. Implementations MUST only post (no locks, no I/O, no store calls).
 */
interface SyncLibraryListener {
    /** Local edits / new learns, in seq order. [bulk]: migration, import, diff, multi-key delete. */
    fun onLocalChanges(entries: List<LedgerEntry>, bulk: Boolean)

    /** A store write completed; [durableHigh] is the new served / reported ceiling. */
    fun onDurable(durableHigh: Long)
}

/** The phone's ledger and rows. Thread-safe (the store lock); called from mm-sync. */
interface SyncLibraryPort {
    fun durableHigh(): Long

    fun recordCount(): Int

    fun stats(): LibrarySyncStats

    /** Fresh copies of the persisted peer table. */
    fun loadPeers(): Map<Bytes, StoredPeer>

    /** Store a copy of [state] (and [lastSyncMs] when non-null); written with the next save. */
    fun putPeer(peerId: Bytes, state: PeerState, lastSyncMs: Long?)

    /** Serve a PULL durable-only (§15.2). Does not touch the peer table. */
    fun servePage(pull: Pull, excludeOk: Boolean, puller: Bytes): PageResult

    /**
     * Apply one received REC body from [sender] (§6.2). [nowMs] null = clock unknown. live = true:
     * projected onto the rows at once and saved soon; false: projected at [commitPage].
     */
    fun applyRemote(body: Bytes, sender: Bytes, nowMs: Long?, live: Boolean): ApplyResult

    /** A page completed (SessionAction.Commit): project pending records, store the peer, save now. */
    fun commitPage(peerId: Bytes, state: PeerState, lastSyncMs: Long)

    fun requestSave()

    fun setListener(listener: SyncLibraryListener?)
}

/** One packet that passed handleHeard's filters (§5.7). lat/lon 1e-7 degrees; lat, lon, accM all or none. */
data class HeardSighting(
    val packet: Bytes,
    val rssi: Int?,
    val wallMs: Long,
    val monoMs: Long,
    val lat: Int?,
    val lon: Int?,
    val accM: Int?,
    val addr: Bytes?,
    val taggedOwnBand: Boolean,
)

sealed class CatchUpItem {
    /** A ring event to resend: flags carry REPLAY, seenBy is empty (the router sets it). */
    data class Replay(val evt: Evt) : CatchUpItem()

    /** Sent as is (requester set). */
    data class Gap(val gap: EvtGap) : CatchUpItem()
}

/** Android's event origin for one service start (§2.8, §5.7, PROTOCOL §8.5). mm-sync only. */
interface EventOriginPort {
    val origin: Bytes
    val epoch: Long

    /** The last seq issued in [epoch] (0 = none). */
    val seq: Long

    /** Coalesce one sighting; returns the events to send now (already in the ring, seenBy empty). */
    fun onSighting(s: HeardSighting): List<Evt>

    /** Close the windows due at or before [monoMs]; returns their events (already in the ring). */
    fun tick(monoMs: Long): List<Evt>

    /** The earliest open window's end, or null. */
    fun nextDueMs(): Long?

    /** While true (a link carries > 20 EVT/s), new windows last 3 s instead of 1 s. */
    fun setWideWindow(wide: Boolean)

    /** Issue one event without coalescing (tests, transcript replay); it goes into the ring. */
    fun originate(
        packet: Bytes,
        ts: Long,
        rssi: Int?,
        count: Int,
        lat: Int?,
        lon: Int?,
        accM: Int?,
        addr: Bytes?,
        flags: Int,
    ): Evt

    /** null: the same (requester, epoch, afterSeq) was answered less than 5 s before [monoMs]. */
    fun catchUp(requester: Bytes, epoch: Long, afterSeq: Long, monoMs: Long): List<CatchUpItem>?
}

/** §9.4. Returns runtimeMin (0..5999) or -1. */
interface RuntimeEstimatorPort {
    fun sample(monoMs: Long, pct: Int, charging: Boolean): Int
}

/** The latest HB of one device and when it was last heard, by path (§16.4). */
class RosterEntry(
    val hb: Hb,
    val lastAnyMs: Long,
    /** The last HB with hops 0 received from the described device itself. */
    val lastDirectMs: Long?,
    /** Forwarder deviceId -> the last time a copy of this device's HB arrived through it. */
    val lastViaMs: Map<Bytes, Long>,
)

/** mm-sync only. */
interface DeviceRosterPort {
    /** Record [hb] received on the session whose peer is [fromPeer]; true when it replaced the stored HB. */
    fun onHb(hb: Hb, fromPeer: Bytes, monoMs: Long): Boolean

    fun get(deviceId: Bytes): RosterEntry?

    fun entries(): List<RosterEntry>

    fun forget(deviceId: Bytes)
}
