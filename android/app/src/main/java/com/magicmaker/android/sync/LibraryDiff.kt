package com.magicmaker.android.sync

import com.magicmaker.android.core.MagicClassifier
import com.magicmaker.android.core.MagicCategory

/**
 * The external library file (or an import) against the internal store, as local edits (spec
 * §5.2, plan §4.5). Pure. Every op is later stamped now, origin = self, and applied as bulk by
 * [LibrarySync.onDiff].
 *
 * | external vs internal | op |
 * |---|---|
 * | hex in both, user view differs (label, category, note, user preset) | USER (RESET when the new view has no user state) |
 * | hex only internal, syncable | TOMBSTONE |
 * | hex only internal, not syncable | remove rows (built-ins come back through mergeBuiltInPresets) |
 * | hex only external, classifies | learn (PRESENCE) + USER when it carries user state |
 * | hex only external, raw | raw row (+ USER when it carries user state) |
 * | `newwand_names` added / changed / removed | NEWWAND set / set / deleted |
 */
object LibraryDiff {
    /**
     * Diff only when the sidecar does not vouch for the external file and it is newer than the
     * internal one (plan §3.6). An unchanged or older external file is ignored.
     */
    fun shouldDiff(sidecarMatches: Boolean, externalMtimeMs: Long, internalMtimeMs: Long): Boolean =
        !sidecarMatches && externalMtimeMs > internalMtimeMs

    fun diff(internal: LibraryRows, external: LibraryRows, ledger: LedgerStore): List<LocalEditOp> =
        diff(internal, external) { hex -> ledger.get(LibraryRows.libKeyString(hex)) != null }

    fun diff(internal: LibraryRows, external: LibraryRows, isSyncable: (String) -> Boolean): List<LocalEditOp> {
        val ops = ArrayList<LocalEditOp>()
        val iBy = internal.byHex()
        val eBy = external.byHex()
        for ((hex, eRows) in eBy) {
            if (LibraryRows.keyFor(hex) == null && hex !in iBy) continue
            val iRows = iBy[hex]
            val eView = LibraryRows.viewOf(hex, eRows)
            if (iRows != null) {
                val iView = LibraryRows.viewOf(hex, iRows)
                if (iView != eView) ops.add(opFor(hex, eRows, eView))
                continue
            }
            // Only in the external file.
            val learned = eRows.any { it.place == SyncConst.PLACE_COLORS || it.place == SyncConst.PLACE_LIBRARY }
            val classified = MagicClassifier.classify(hex)?.takeIf { it.category != MagicCategory.UNKNOWN }
            when {
                learned && classified != null -> ops.add(LocalEditOp.Learn(hex))
                eRows.any { it.place == SyncConst.PLACE_RAW } -> ops.add(LocalEditOp.AddRaw(hex, eRows.first { it.place == SyncConst.PLACE_RAW }.row.label))
                learned -> ops.add(LocalEditOp.AddRaw(hex, eRows.first().row.label))
            }
            if (eView.label != null) ops.add(opFor(hex, eRows, eView))
        }
        for ((hex, _) in iBy) {
            if (hex in eBy) continue
            ops.add(if (isSyncable(hex)) LocalEditOp.Tombstone(hex) else LocalEditOp.RemoveRows(hex))
        }
        val iNames = internal.newWandNames.mapKeys { LibraryRows.canon(it.key) }.mapValues { SyncText.normalizeLabel(it.value) }
        val eNames = external.newWandNames.mapKeys { LibraryRows.canon(it.key) }.mapValues { SyncText.normalizeLabel(it.value) }
        for ((hex, name) in eNames.entries.sortedBy { it.key }) {
            if (name != null && iNames[hex] != name) ops.add(LocalEditOp.NewWand(hex, name))
        }
        for ((hex, name) in iNames.entries.sortedBy { it.key }) {
            if (name != null && eNames[hex] == null) ops.add(LocalEditOp.NewWand(hex, null))
        }
        return ops
    }

    /** USER with the external file's full state, or RESET when it has no user state. */
    private fun opFor(hex: String, eRows: List<LibraryRows.Placed>, v: LibraryRows.View): LocalEditOp {
        if (v.label == null) return LocalEditOp.Reset(hex, v.note)
        val src = LibraryRows.userSource(hex, eRows) ?: eRows.first()
        val edited = eRows.any { LibraryRows.rowHasUserState(hex, it.row) }
        return LocalEditOp.User(
            hex, v.label, v.category, SyncText.normalizeKind(src.row.typeInfo), v.note,
            if (v.preset) SyncConst.PLACE_PRESETS else src.place, v.preset, userEdited = edited || !v.preset,
        )
    }
}
