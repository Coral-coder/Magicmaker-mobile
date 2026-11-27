package com.magicmaker.android.sync

import com.google.gson.JsonParser
import com.magicmaker.android.core.ClassifiedPacket
import com.magicmaker.android.core.HexUtils
import com.magicmaker.android.core.MagicCategory
import com.magicmaker.android.core.MagicClassifier
import com.magicmaker.android.core.MagicPacket
import com.magicmaker.android.core.PresetCatalog

/**
 * A snapshot of the library rows (plan §4.4, §4.5): the four lists and the New-Wand names. Used by
 * migration and the external diff; the companion holds the pure row rules shared with
 * [LibrarySync] and [com.magicmaker.android.data.MagicStore].
 */
data class LibraryRows(
    val presets: List<MagicPacket> = emptyList(),
    val learnedColors: List<MagicPacket> = emptyList(),
    val learnedLibrary: List<MagicPacket> = emptyList(),
    val learnedRaw: List<MagicPacket> = emptyList(),
    /** `newwand_names`: canonical HEX -> name. */
    val newWandNames: Map<String, String> = emptyMap(),
) {
    /** The lists with their `place` codes, in visit order (presets, colors, library, raw). */
    fun lists(): List<Pair<Int, List<MagicPacket>>> = listOf(
        SyncConst.PLACE_PRESETS to presets,
        SyncConst.PLACE_COLORS to learnedColors,
        SyncConst.PLACE_LIBRARY to learnedLibrary,
        SyncConst.PLACE_RAW to learnedRaw,
    )

    /** Canonical hex -> its rows (place, row), hexes in first-visit order. */
    fun byHex(): LinkedHashMap<String, MutableList<Placed>> {
        val out = LinkedHashMap<String, MutableList<Placed>>()
        for ((place, list) in lists()) {
            for (row in list) out.getOrPut(canon(row.hex)) { ArrayList(2) }.add(Placed(place, row))
        }
        return out
    }

    /** One row with the list it is in. */
    data class Placed(val place: Int, val row: MagicPacket) {
        val isUserPreset: Boolean get() = place == SyncConst.PLACE_PRESETS && row.userRecorded
        val isBuiltIn: Boolean get() = place == SyncConst.PLACE_PRESETS && !row.userRecorded
    }

    /** What a node shows for a hex with no user state (spec §2.6 `derived`). */
    data class Derived(val label: String, val category: MagicCategory)

    /**
     * The user-visible state of one hex (diff / migration): [label] null = no user state (the
     * label is generated, the category is derived and there is no user preset).
     */
    data class View(val label: String?, val category: Int, val note: String?, val preset: Boolean)

    companion object {
        /**
         * [HexUtils.canonicalHex], without allocating when [hex] is already canonical (uppercase hex
         * starting `8301`, as every stored row is): projection and the tombstone check scan every row.
         */
        fun canon(hex: String): String {
            if (hex.length >= 4 && hex.startsWith("8301")) {
                var ok = true
                for (c in hex) if (c !in '0'..'9' && c !in 'A'..'F') { ok = false; break }
                if (ok) return hex
            }
            return HexUtils.canonicalHex(hex)
        }

        /** The generated raw-label forms (`rawLabel`, `rawPacketLabel`) for canonical [h]. */
        fun isRawLabelForm(h: String, label: String): Boolean =
            label == MagicClassifier.rawLabel(h) || label == "Raw: $h" || label == "Raw: ${h.take(16)}…${h.takeLast(4)}"

        /** The record key for [hex] in [ns], or null when the hex is not a valid packet (not syncable). */
        fun keyFor(hex: String, ns: Int = SyncConst.NS_LIB): RecordKey? {
            val h = canon(hex)
            if (h.length % 2 != 0) return null
            val packet = runCatching { Bytes.fromHex(h) }.getOrNull() ?: return null
            return runCatching { RecordKey.checkPacket(packet); RecordKey(ns, packet) }.getOrNull()
        }

        /** The phones' ledger map key for a canonical LIB hex, without building a [RecordKey]. */
        fun libKeyString(canonicalHex: String): String = "${SyncConst.NS_LIB}:$canonicalHex"

        fun categoryCode(c: MagicCategory): Int = when (c) {
            MagicCategory.UNKNOWN -> SyncConst.CAT_UNKNOWN
            MagicCategory.SHOW -> SyncConst.CAT_SHOW
            MagicCategory.ANIMATION -> SyncConst.CAT_ANIMATION
            MagicCategory.COLOR -> SyncConst.CAT_COLOR
        }

        fun categoryOf(code: Int?): MagicCategory = when (code) {
            SyncConst.CAT_SHOW -> MagicCategory.SHOW
            SyncConst.CAT_ANIMATION -> MagicCategory.ANIMATION
            SyncConst.CAT_COLOR -> MagicCategory.COLOR
            else -> MagicCategory.UNKNOWN
        }

        private val builtIns: Map<String, MagicPacket> by lazy {
            val m = LinkedHashMap<String, MagicPacket>()
            for (p in PresetCatalog.asMagicPackets()) m.putIfAbsent(canon(p.hex), p)
            m
        }

        /** The built-in preset for [hex], or null. */
        fun builtIn(hex: String): MagicPacket? = builtIns[canon(hex)]

        /** Built-in preset label/category, else the classifier's, else the raw label / UNKNOWN. */
        fun derived(hex: String): Derived {
            val h = canon(hex)
            builtIns[h]?.let { return Derived(it.label, it.category) }
            MagicClassifier.classify(h)?.let { return Derived(it.label, it.category) }
            return Derived(MagicClassifier.rawLabel(h), MagicCategory.UNKNOWN)
        }

        /**
         * True when [label] was produced by the app, not typed (plan §4.4): blank; a cloud
         * dictionary label (`typeInfo == "imported"`, D-P3-8); a raw-label form; the derived or
         * classifier label. Raw forms are checked first so 20k raw rows rarely reach the classifier.
         */
        fun isGeneratedLabel(hex: String, label: String, typeInfo: String): Boolean {
            val n = SyncText.normalizeLabel(label) ?: return true
            if (typeInfo == "imported") return true
            val h = canon(hex)
            if (isRawLabelForm(h, n)) return true
            if (n == SyncText.normalizeLabel(derived(h).label)) return true
            val c = MagicClassifier.classify(h)
            return c != null && n == SyncText.normalizeLabel(c.label)
        }

        /** True when [category] is what the app would show for [hex] on its own. */
        fun isDerivedCategory(hex: String, category: MagicCategory): Boolean {
            if (category == derived(hex).category) return true
            return MagicClassifier.classify(canon(hex))?.category == category
        }

        /**
         * A row carries user state: it is marked user-edited (a USER projection), or its label was
         * typed, or its category is not the derived one (pre-P3 rows have no mark: the heuristic).
         */
        fun rowHasUserState(hex: String, row: MagicPacket): Boolean {
            if (row.userEdited == true) return true
            val h = canon(hex)
            // Fast path for the (up to 20k) learned raw rows: a raw label on UNKNOWN is the
            // generated raw state, decided without running the classifier.
            if (row.category == MagicCategory.UNKNOWN && isRawLabelForm(h, row.label)) return false
            return !isGeneratedLabel(h, row.label, row.typeInfo) || !isDerivedCategory(h, row.category)
        }

        /** The rows of one hex qualify for a USER record (user preset, typed label or changed category). */
        fun hasUserState(hex: String, rows: List<Placed>): Boolean =
            rows.any { it.isUserPreset || rowHasUserState(hex, it.row) }

        /**
         * The USER body source (plan §4.4): the first qualifying row in list order; the PRESET bit
         * iff a user preset row exists. Null when the hex has no user state.
         */
        fun userSource(hex: String, rows: List<Placed>): Placed? =
            rows.firstOrNull { it.isUserPreset || rowHasUserState(hex, it.row) }

        /** The user view of one hex (null label = no user state), for the external diff. */
        fun viewOf(hex: String, rows: List<Placed>): View {
            val preset = rows.any { it.isUserPreset }
            val src = userSource(hex, rows)
            val note = rows.firstNotNullOfOrNull { it.row.note }?.let { SyncText.normalizeNote(it) }
            if (src == null) return View(null, categoryCode(derived(hex).category), note, false)
            val label = SyncText.normalizeLabel(src.row.label) ?: SyncText.normalizeLabel(derived(hex).label)
            return View(label, categoryCode(src.row.category), note, preset)
        }

        /**
         * Re-hearing a packet that already has a row (spec §5.4): never rewrites `hex`; follows the
         * classifier's label only while the row is not user-edited; a starlight row takes the heard
         * colours and keeps / gains `wandVerified`. Returns [existing] itself when nothing changes.
         */
        fun relabelOnRehear(existing: MagicPacket, heard: MagicPacket, verified: Boolean = false): MagicPacket {
            var out = existing
            if (existing.userEdited != true && existing.label != heard.label) out = out.copy(label = heard.label)
            if (existing.typeInfo == "starlight") {
                val v = verified || existing.wandVerified
                if (out.colors != heard.colors || out.wandVerified != v) out = out.copy(colors = heard.colors, wandVerified = v)
            }
            return out
        }

        fun relabelOnRehear(existing: MagicPacket, classified: ClassifiedPacket): MagicPacket =
            relabelOnRehear(existing, MagicPacket(0, classified.hex, classified.label, classified.category,
                classified.typeInfo, classified.colors, classified.simKey))

        /** `newwand_names` JSON (`{"HEX": "name"}`) -> canonical HEX -> name; bad input -> empty. */
        fun parseNewWandJson(json: String?): Map<String, String> {
            if (json.isNullOrBlank()) return emptyMap()
            return runCatching {
                val o = JsonParser.parseString(json).asJsonObject
                val out = LinkedHashMap<String, String>()
                for ((k, v) in o.entrySet()) if (v.isJsonPrimitive) out[k.uppercase()] = v.asString
                out as Map<String, String>
            }.getOrDefault(emptyMap())
        }
    }
}
