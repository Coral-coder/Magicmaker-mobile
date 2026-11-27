package com.magicmaker.android.sync

import com.google.gson.GsonBuilder
import java.io.File
import java.security.SecureRandom
import java.util.Random

/** On-disk form of `noBackupFilesDir/sync_identity.json` (plan §3.3). Every field nullable: Gson. */
internal data class IdentityJson(
    val v: Int? = null,
    val deviceId: String? = null,
    val dbId: String? = null,
    val issuedSeq: Long? = null,
    val evtEpoch: Long? = null,
    val groupId: String? = null,
    val groupKey: String? = null,
    val hubAddress: String? = null,
    val foreign: List<String>? = null,
    val createdMs: Long? = null,
)

/**
 * The phone's sync identity (spec D15, §5.2; PROTOCOL §2): deviceId, dbId, issuedSeq, event epoch,
 * group key, hub MAC and the foreign-hub list. Lives in `noBackupFilesDir`, so Auto Backup and
 * device transfer never move it and a restored phone gets a new identity (case (a)).
 *
 * Thread-safe: every method takes this object's monitor (a leaf lock) and every change is written
 * atomically and synchronously before it returns. [dbId] changes only during load
 * ([IdentityReconcile]), before any session exists.
 */
class SyncIdentityFile private constructor(
    private val file: File,
    private val rng: Random,
    private var data: IdentityJson,
    /** False when the file was missing or invalid at load (a fresh identity was created). */
    val wasPresent: Boolean,
    private val onError: (Throwable, String) -> Unit,
) : SyncIdentityPort {

    override val deviceId: Bytes get() = synchronized(this) { Bytes.fromHex(data.deviceId!!) }

    override val dbId: Bytes get() = synchronized(this) { Bytes.fromHex(data.dbId!!) }

    override val group: SyncGroup?
        get() = synchronized(this) {
            val k = data.groupKey ?: return null
            SyncGroup(Bytes.fromHex(data.groupId!!), Bytes.fromHex(k))
        }

    val issuedSeq: Long get() = synchronized(this) { data.issuedSeq ?: 0 }

    val evtEpoch: Long get() = synchronized(this) { data.evtEpoch ?: 0 }

    val createdMs: Long get() = synchronized(this) { data.createdMs ?: 0 }

    override val hubAddress: String? get() = synchronized(this) { data.hubAddress }

    fun foreignList(): List<String> = synchronized(this) { data.foreign ?: emptyList() }

    override fun setGroup(group: SyncGroup?) {
        synchronized(this) {
            if (group != null) require(group.isConsistent() && !group.groupId.isAllZero()) { "inconsistent group" }
            update(data.copy(groupId = group?.groupId?.hex(), groupKey = group?.groupKey?.hex()))
        }
    }

    /** issuedSeq = max(issuedSeq, [seq]) on disk; no write when it does not grow (no headroom, §3.7). */
    override fun ensureIssued(seq: Long) {
        synchronized(this) {
            if (seq <= (data.issuedSeq ?: 0)) return
            update(data.copy(issuedSeq = seq))
        }
    }

    /** A store write holding feed seqs below [seqAtSnapshot] completed (§3.5). */
    fun noteWritten(seqAtSnapshot: Long) = ensureIssued(seqAtSnapshot)

    override fun setHubAddress(address: String?) {
        synchronized(this) {
            val a = address?.let { normalizeMac(it) }
            if (a == data.hubAddress) return
            update(data.copy(hubAddress = a))
        }
    }

    override fun isForeign(address: String): Boolean = synchronized(this) { normalizeMac(address) in (data.foreign ?: emptyList()) }

    /** Remember a hub of another group (FOREIGN); at most [FOREIGN_MAX], oldest dropped. */
    override fun markForeign(address: String) {
        synchronized(this) {
            val a = normalizeMac(address)
            val list = (data.foreign ?: emptyList()).filter { it != a } + a
            update(data.copy(foreign = list.takeLast(FOREIGN_MAX)))
        }
    }

    /** One service start (spec §2.8): epoch = max(nowMs / 1000, last + 1), persisted before return. */
    fun startEpoch(nowMs: Long): Long = synchronized(this) {
        val e = maxOf(nowMs / 1000, (data.evtEpoch ?: 0) + 1)
        update(data.copy(evtEpoch = e))
        e
    }

    /** Load-time only ([IdentityReconcile.apply]): new ids and / or issuedSeq, written at once. */
    internal fun reconcile(newDeviceId: Boolean, newDbId: Boolean, issuedSeq: Long?) {
        synchronized(this) {
            var d = data
            if (newDeviceId) d = d.copy(deviceId = randomId(rng).hex())
            if (newDbId || newDeviceId) d = d.copy(dbId = randomId(rng).hex())
            if (issuedSeq != null) d = d.copy(issuedSeq = issuedSeq)
            if (d != data) update(d)
        }
    }

    private fun update(d: IdentityJson) {
        data = d
        write()
    }

    private fun write() {
        val ok = runCatching { AtomicFiles.write(file, GSON.toJson(data).toByteArray(Charsets.UTF_8)) }.getOrDefault(false)
        if (!ok) onError(IllegalStateException("sync identity write failed: ${file.path}"), "SyncIdentity.write")
    }

    override fun toString(): String = synchronized(this) {
        "SyncIdentity(device=${data.deviceId}, db=${data.dbId}, issued=${data.issuedSeq}, epoch=${data.evtEpoch}, group=${data.groupId})"
    }

    companion object {
        const val FILE_NAME: String = "sync_identity.json"
        const val FOREIGN_MAX: Int = 16
        private val GSON = GsonBuilder().create()

        /**
         * Read [file]; a missing, unreadable or invalid file counts as missing and a fresh identity
         * (new deviceId and dbId) is created and written ([wasPresent] = false).
         */
        fun load(
            file: File,
            nowMs: Long,
            rng: Random = SecureRandom(),
            onError: (Throwable, String) -> Unit = { _, _ -> },
        ): SyncIdentityFile {
            val parsed = AtomicFiles.read(file)?.let { bytes ->
                runCatching { GSON.fromJson(String(bytes, Charsets.UTF_8), IdentityJson::class.java) }.getOrNull()
            }?.takeIf { isValid(it) }
            if (parsed != null) return SyncIdentityFile(file, rng, parsed, true, onError)
            val fresh = IdentityJson(
                v = 1,
                deviceId = randomId(rng).hex(),
                dbId = randomId(rng).hex(),
                issuedSeq = 0,
                evtEpoch = 0,
                createdMs = nowMs,
            )
            return SyncIdentityFile(file, rng, fresh, false, onError).also { it.write() }
        }

        /** 8 random bytes, regenerated while all zero (PROTOCOL §2). */
        fun randomId(rng: Random): Bytes {
            while (true) {
                val b = ByteArray(8)
                rng.nextBytes(b)
                val id = Bytes.of(b)
                if (!id.isAllZero()) return id
            }
        }

        /** A new random group key whose groupId is not all zero (PROTOCOL §2). */
        fun newGroup(rng: Random = SecureRandom()): SyncGroup {
            while (true) {
                val k = ByteArray(16)
                rng.nextBytes(k)
                val g = SyncGroup.fromKey(Bytes.of(k))
                if (!g.groupId.isAllZero()) return g
            }
        }

        fun normalizeMac(a: String): String = a.trim().uppercase()

        private fun id8(s: String?): Boolean {
            if (s == null || s.length != 16) return false
            val b = runCatching { Bytes.fromHex(s) }.getOrNull() ?: return false
            return !b.isAllZero()
        }

        internal fun isValid(j: IdentityJson): Boolean {
            if (j.v != 1) return false
            if (!id8(j.deviceId) || !id8(j.dbId)) return false
            if ((j.issuedSeq ?: 0) < 0 || (j.evtEpoch ?: 0) < 0) return false
            if ((j.groupId == null) != (j.groupKey == null)) return false
            if (j.groupKey != null) {
                if (!id8(j.groupId)) return false
                val key = runCatching { Bytes.fromHex(j.groupKey) }.getOrNull() ?: return false
                if (key.size != 16) return false
                if (SyncCrypto.groupId(key) != Bytes.fromHex(j.groupId!!)) return false
            }
            return true
        }
    }
}

/**
 * The load decision table (plan §3.6, spec §5.2 (a)–(c)). Pure: [MagicStore.load] gathers the
 * facts, restores or migrates the ledger, then applies the [Outcome].
 */
object IdentityReconcile {
    /** Which file the rows (and, when present, the ledger) come from. */
    enum class Base { INTERNAL, EXTERNAL, NONE }

    fun chooseBase(internalParses: Boolean, externalParses: Boolean): Base = when {
        internalParses -> Base.INTERNAL
        externalParses -> Base.EXTERNAL
        else -> Base.NONE
    }

    /**
     * The external copy is diffed as user edits only when the internal store is the base, the
     * external file parses, its sidecar does not match (or is missing) and it is newer.
     */
    fun externalDiff(base: Base, externalParses: Boolean, externalChanged: Boolean, externalNewer: Boolean): Boolean =
        base == Base.INTERNAL && externalParses && externalChanged && externalNewer

    /**
     * [nextSyncSeq]: the ledger's after restore / migration; [ledgerCorrupt]: some stored entry was
     * dropped (§3.1); [migrated]: the base had no `sync` section.
     */
    data class Facts(
        val base: Base,
        val identityPresent: Boolean,
        val issuedSeq: Long,
        val nextSyncSeq: Long,
        val ledgerCorrupt: Boolean,
        val migrated: Boolean,
    )

    /** [issuedSeq]: the value to store (null = keep). [case]: which row of the table applied. */
    data class Outcome(
        val newDeviceId: Boolean,
        val newDbId: Boolean,
        val resetPeers: Boolean,
        val issuedSeq: Long?,
        val case: String,
    )

    fun decide(f: Facts): Outcome {
        // (a) backup restore / device transfer: no identity. The loaded file already created a new
        // deviceId and dbId; peers are reset (D-P3-9). The ledger is kept.
        if (!f.identityPresent) return Outcome(newDeviceId = false, newDbId = false, resetPeers = true, issuedSeq = f.nextSyncSeq, case = "a")
        // Store restored from the external copy while no internal store existed.
        if (f.base == Base.EXTERNAL) return Outcome(false, true, true, f.nextSyncSeq, "external")
        // A ledger entry was dropped as corrupt: its seqs may have reached peers.
        if (f.ledgerCorrupt) return Outcome(false, true, true, f.nextSyncSeq, "corrupt")
        // (c) rollback or a replaced file: seqs up to issuedSeq − 1 may have left the phone.
        if (f.nextSyncSeq < f.issuedSeq) return Outcome(false, true, true, f.nextSyncSeq, "c")
        return Outcome(false, false, false, null, if (f.migrated) "migrate" else "normal")
    }

    /** Apply [o] to the identity and the peer table (wm = 0, excludeOk = false; dbId kept). */
    fun apply(o: Outcome, identity: SyncIdentityFile, peers: MutableMap<Bytes, StoredPeer>) {
        identity.reconcile(o.newDeviceId, o.newDbId, o.issuedSeq)
        if (o.resetPeers) {
            for (k in peers.keys.toList()) {
                val p = peers.getValue(k)
                peers[k] = StoredPeer(PeerState(p.state.dbId, 0, false), p.lastSyncMs)
            }
        }
    }
}
