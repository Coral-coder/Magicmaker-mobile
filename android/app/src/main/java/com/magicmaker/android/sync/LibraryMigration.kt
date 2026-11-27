package com.magicmaker.android.sync

import com.magicmaker.android.core.MagicPacket

/**
 * Schema 0 -> 1, once (spec §5.2, plan §4.4): turns the existing rows into ledger entries. Pure.
 *
 * Per canonical hex, in first-visit order (presets, colors, library, raw, then `newwand_names`):
 * - a user preset, or any row with a typed label / changed category: USER, u = 2
 *   (`LEGACY_USER_ANDROID`), origin = self, body from the first qualifying row, PRESET iff a user
 *   preset row exists; the body is projected onto every row with the hex;
 * - else a row in colors or library: PRESENCE;
 * - raw rows with generated labels and built-in preset rows: no entry;
 * - `newwand_names`: NEWWAND, u = 2.
 * syncSeq 1..N in that order. Bulk (pulled by peers, not pushed live).
 */
object LibraryMigration {
    class Result(val rows: LibraryRows, val entries: List<LedgerEntry>)

    fun migrate(rows: LibraryRows, self: Bytes, ledger: LedgerStore): Result {
        val entries = ArrayList<LedgerEntry>()
        val projected = HashMap<String, RecordBody>()
        for ((hex, placed) in rows.byHex()) {
            val key = LibraryRows.keyFor(hex) ?: continue
            val src = LibraryRows.userSource(hex, placed)
            if (src != null) {
                val preset = placed.any { it.isUserPreset }
                val edited = placed.any { LibraryRows.rowHasUserState(hex, it.row) }
                val label = SyncText.normalizeLabel(src.row.label) ?: SyncText.normalizeLabel(LibraryRows.derived(hex).label)!!
                var flags = 0
                if (edited || !preset) flags = flags or SyncConst.FLAG_USER_EDITED
                if (preset) flags = flags or SyncConst.FLAG_PRESET
                val body = RecordBody(
                    key, SyncConst.U_LEGACY_ANDROID, self, flags, label, LibraryRows.categoryCode(src.row.category),
                    src.row.note?.let { SyncText.normalizeNote(it) }, SyncText.normalizeKind(src.row.typeInfo), src.place,
                )
                ledger.insertLocal(body)?.let {
                    entries.add(it)
                    projected[hex] = body
                }
            } else if (placed.any { it.place == SyncConst.PLACE_COLORS || it.place == SyncConst.PLACE_LIBRARY }) {
                ledger.localLearn(key.packet)?.let { entries.add(it) }
            }
        }
        for ((hex, name) in rows.newWandNames.entries.sortedBy { LibraryRows.canon(it.key) }) {
            val h = LibraryRows.canon(hex)
            val key = LibraryRows.keyFor(h, SyncConst.NS_NEWWAND) ?: continue
            val label = SyncText.normalizeLabel(name) ?: continue
            ledger.insertLocal(RecordBody(key, SyncConst.U_LEGACY_ANDROID, self, label = label))?.let { entries.add(it) }
        }

        // Every row with a USER hex shows the same label, category and note, marked user-edited.
        fun project(list: List<MagicPacket>): List<MagicPacket> = list.map { r ->
            val b = projected[LibraryRows.canon(r.hex)] ?: return@map r
            r.copy(label = b.label!!, category = LibraryRows.categoryOf(b.category), note = b.note, userEdited = true)
        }
        val names = LinkedHashMap<String, String>()
        for ((k, v) in rows.newWandNames) SyncText.normalizeLabel(v)?.let { names[LibraryRows.canon(k)] = it }
        val out = if (projected.isEmpty()) {
            rows.copy(newWandNames = names)
        } else {
            LibraryRows(project(rows.presets), project(rows.learnedColors), project(rows.learnedLibrary), project(rows.learnedRaw), names)
        }
        return Result(out, entries)
    }
}
