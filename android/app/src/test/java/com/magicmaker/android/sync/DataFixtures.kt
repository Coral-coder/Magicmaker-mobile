package com.magicmaker.android.sync

import com.magicmaker.android.core.HexUtils
import com.magicmaker.android.core.MagicCategory
import com.magicmaker.android.core.MagicClassifier
import com.magicmaker.android.core.MagicPacket
import com.magicmaker.android.core.PresetCatalog
import com.magicmaker.android.core.toClassified
import com.magicmaker.android.core.toPacket

// Part 1 (data layer) test support: docs/SYNC_P3_ANDROID_PLAN.md §9.1, §10.1. Names are prefixed
// or nested so they never collide with part 2's test support in the same package.

/** Packets with known classifications (checked in [DataFixtures] users). */
internal object DataHexes {
    /** Built-in preset "Red" (classifier: "Single Color: Red", COLOR). */
    const val RED = "8301E905002E0EF5B0"

    /** A learned colour that is not a built-in duplicate (dual, C2:17:1C). */
    const val DUAL = "8301E100E90600220F5C57B0"

    /** An animation (e90c) -> library. */
    const val E90C = "8301E100E90C00010F4D575A940705488BB0"

    /** Another animation (fx_ea) -> library. */
    const val FX = "8301EA0A000E0F0102"

    /** Starlight wand codes -> colors (typeInfo "starlight"). */
    const val STAR5 = "8301CF9B00C42922EFD819F22A6205"
    const val STAR9 = "8301CF9B00C42922EFD819F22A6209"

    /** Unclassified -> raw. */
    const val RAW = "8301AABBCCDDEEFF"
    const val RAW2 = "8301AABBCCDDEE00"

    /** Guest-band telemetry: library noise with no row, so the learn routine declines it. */
    const val NOISE = "8301C0AABBCCDD"

    /** A New-Wand code. */
    const val NEWWAND = "8301CF0B00C020224EAC7807866E80"
}

/**
 * [RowsAccess] over plain lists, with a learn routine that mirrors MagicStore's `fromSync` path:
 * colours (not built-in duplicates) -> colors, shows / animations -> library; pings, noise, raw and
 * hexes that already have a row decline.
 */
internal class FakeRows(
    override var presets: List<MagicPacket> = PresetCatalog.asMagicPackets(),
    override var learnedColors: List<MagicPacket> = emptyList(),
    override var learnedLibrary: List<MagicPacket> = emptyList(),
    override var learnedRaw: List<MagicPacket> = emptyList(),
    override var newWandNames: Map<String, String> = emptyMap(),
) : RowsAccess {
    var nextId = 1000L
    var revisions = 0
    var rawRebuilds = 0
    val syncLearns = ArrayList<String>()

    override fun allocId(): Long = nextId++

    override fun learnFromSync(hex: String): Boolean {
        val h = HexUtils.canonicalHex(hex)
        syncLearns.add(h)
        if (MagicClassifier.isLibraryNoise(h)) return false
        val c = MagicClassifier.classify(h) ?: return false
        if (c.category == MagicCategory.UNKNOWN || c.typeInfo == "ping") return false
        if (all().any { HexUtils.canonicalHex(it.hex) == h }) return false
        when (c.category) {
            MagicCategory.COLOR -> {
                if (c.typeInfo != "starlight") {
                    val key = MagicClassifier.libraryDedupeKey(c)
                    if (presets.any { MagicClassifier.libraryDedupeKey(it.toClassified()) == key }) return false
                }
                learnedColors = learnedColors + c.toPacket(userRecorded = true).copy(id = allocId())
            }
            else -> learnedLibrary = (learnedLibrary + c.toPacket(userRecorded = true).copy(id = allocId())).sortedBy { it.label.lowercase() }
        }
        return true
    }

    override fun bumpRevision() {
        revisions++
    }

    override fun rebuildRawIndex() {
        rawRebuilds++
    }

    fun all(): List<MagicPacket> = presets + learnedColors + learnedLibrary + learnedRaw

    fun rowsWith(hex: String): List<MagicPacket> = all().filter { HexUtils.canonicalHex(it.hex) == HexUtils.canonicalHex(hex) }

    fun snapshot(): LibraryRows = LibraryRows(presets, learnedColors, learnedLibrary, learnedRaw, newWandNames)

    /** Add a learned row the way the store's learn routine would (classified) or a raw row. */
    fun learn(hex: String, label: String? = null): MagicPacket {
        val h = HexUtils.canonicalHex(hex)
        val c = MagicClassifier.classify(h)
        return when {
            c == null || c.category == MagicCategory.UNKNOWN -> raw(h, label ?: MagicClassifier.rawLabel(h))
            c.category == MagicCategory.COLOR -> c.toPacket(userRecorded = true).copy(id = allocId(), label = label ?: c.label)
                .also { learnedColors = learnedColors + it }
            else -> c.toPacket(userRecorded = true).copy(id = allocId(), label = label ?: c.label)
                .also { learnedLibrary = learnedLibrary + it }
        }
    }

    fun raw(hex: String, label: String = MagicClassifier.rawLabel(hex)): MagicPacket {
        val h = HexUtils.canonicalHex(hex)
        return MagicPacket(id = allocId(), hex = h, label = label, category = MagicCategory.UNKNOWN, typeInfo = "raw", simKey = "RAW:$h")
            .also { learnedRaw = learnedRaw + it }
    }

    /** A user preset row as saveCustomPreset builds it. */
    fun userPreset(hex: String, label: String): MagicPacket {
        val h = HexUtils.canonicalHex(hex)
        val c = MagicClassifier.classify(h)
        val p = c?.toPacket(userRecorded = true)?.copy(id = allocId(), label = label, userRecorded = true)
            ?: MagicPacket(id = allocId(), hex = h, label = label, category = MagicCategory.UNKNOWN, typeInfo = "raw", simKey = "USER:$h", userRecorded = true)
        presets = presets.filter { !(it.userRecorded && HexUtils.canonicalHex(it.hex) == h) } + p
        return p
    }
}

/** In-memory [SyncIdentityPort]. */
internal class MemIdentity(override val deviceId: Bytes = DataFixtures.SELF, override val dbId: Bytes = Bytes.fromHex("1269208CA2190C2D")) :
    SyncIdentityPort {
    // Backing fields: a `var group` setter would clash with setGroup() on the JVM.
    private var groupValue: SyncGroup? = null
    private var hubValue: String? = null
    override val group: SyncGroup? get() = groupValue
    override val hubAddress: String? get() = hubValue
    var issued = 0L
    val issuedCalls = ArrayList<Long>()
    val foreign = LinkedHashSet<String>()

    override fun setGroup(group: SyncGroup?) {
        groupValue = group
    }

    override fun ensureIssued(seq: Long) {
        issuedCalls.add(seq)
        if (seq > issued) issued = seq
    }

    override fun setHubAddress(address: String?) {
        hubValue = address
    }

    override fun isForeign(address: String): Boolean = address.uppercase() in foreign

    override fun markForeign(address: String) {
        foreign.add(address.uppercase())
    }
}

internal class RecListener : SyncLibraryListener {
    val local = ArrayList<Pair<List<LedgerEntry>, Boolean>>()
    val durable = ArrayList<Long>()

    override fun onLocalChanges(entries: List<LedgerEntry>, bulk: Boolean) {
        local.add(entries to bulk)
    }

    override fun onDurable(durableHigh: Long) {
        durable.add(durableHigh)
    }
}

internal class RecSaves : SaveSink {
    val calls = ArrayList<Boolean>()

    override fun requestSave(urgent: Boolean) {
        calls.add(urgent)
    }
}

/** A [LibrarySync] over [FakeRows] with a settable wall clock. */
internal class DataHarness(
    val rows: FakeRows = FakeRows(),
    val ledger: LedgerStore = LedgerStore(),
    val identity: MemIdentity = MemIdentity(),
) {
    var now: Long = DataFixtures.T0
    val saves = RecSaves()
    val listener = RecListener()
    val lock = Any()
    val sync = LibrarySync(rows, ledger, identity, saves, lock) { now }.also { it.setListener(listener) }

    fun entry(hex: String, ns: Int = SyncConst.NS_LIB): LedgerEntry? = ledger.get(LibraryRows.keyFor(hex, ns)!!)

    /** Everything stored so far is on disk. */
    fun saveAll() = sync.onSaved(sync.nextSyncSeq)
}

internal object DataFixtures {
    val SELF: Bytes = Bytes.fromHex("4A1D0B5E77C2903F")
    val PEER: Bytes = Bytes.fromHex("A1B2C3D4E5F60718")
    val PEER2: Bytes = Bytes.fromHex("9F3E0011AABBCCDD")
    const val T0: Long = 1_796_000_000_000L

    fun key(hex: String, ns: Int = SyncConst.NS_LIB): RecordKey = LibraryRows.keyFor(hex, ns)!!

    fun userBody(
        hex: String,
        u: Long,
        label: String,
        category: Int,
        place: Int,
        origin: Bytes = PEER,
        preset: Boolean = false,
        edited: Boolean = true,
        kind: String? = null,
        note: String? = null,
    ): Bytes {
        val flags = (if (edited) SyncConst.FLAG_USER_EDITED else 0) or (if (preset) SyncConst.FLAG_PRESET else 0)
        return RecordBody(key(hex), u, origin, flags, label, category, note, kind, place).encode()
    }

    fun tombstoneBody(hex: String, u: Long, origin: Bytes = PEER): Bytes =
        RecordBody(key(hex), u, origin, SyncConst.FLAG_DELETED).encode()

    fun resetBody(hex: String, u: Long, note: String? = null, origin: Bytes = PEER): Bytes =
        RecordBody(key(hex), u, origin, note = note).encode()

    fun presenceBody(hex: String): Bytes = RecordBody(key(hex), SyncConst.U_PRESENCE).encode()

    fun newWandBody(hex: String, u: Long, name: String?, origin: Bytes = PEER): Bytes =
        if (name == null) RecordBody(key(hex, SyncConst.NS_NEWWAND), u, origin, SyncConst.FLAG_DELETED).encode()
        else RecordBody(key(hex, SyncConst.NS_NEWWAND), u, origin, label = name).encode()
}
