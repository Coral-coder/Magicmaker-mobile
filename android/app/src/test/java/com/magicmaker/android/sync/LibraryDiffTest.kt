package com.magicmaker.android.sync

import com.magicmaker.android.core.MagicCategory
import com.magicmaker.android.core.MagicClassifier
import com.magicmaker.android.sync.DataHexes.DUAL
import com.magicmaker.android.sync.DataHexes.E90C
import com.magicmaker.android.sync.DataHexes.FX
import com.magicmaker.android.sync.DataHexes.NEWWAND
import com.magicmaker.android.sync.DataHexes.RAW
import com.magicmaker.android.sync.DataHexes.RAW2
import com.magicmaker.android.sync.DataHexes.STAR5
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Every row of the external-diff table (plan §4.5). */
class LibraryDiffTest {
    private fun base(): FakeRows = FakeRows().also {
        it.learn(DUAL)
        it.learn(E90C)
        it.raw(RAW)
    }

    /** A copy of [r] (the external file starts equal to the internal store). */
    private fun copyOf(r: FakeRows) = FakeRows(r.presets, r.learnedColors, r.learnedLibrary, r.learnedRaw, r.newWandNames).also { it.nextId = 5000 }

    private fun diff(i: FakeRows, e: FakeRows, syncable: Set<String> = emptySet()) =
        LibraryDiff.diff(i.snapshot(), e.snapshot()) { it in syncable }

    @Test
    fun identicalFilesGiveNoOps() {
        val i = base()
        assertTrue(diff(i, copyOf(i)).isEmpty())
    }

    @Test
    fun onlyAnUnchangedNewerFileIsDiffed() {
        assertTrue(LibraryDiff.shouldDiff(sidecarMatches = false, externalMtimeMs = 2000, internalMtimeMs = 1000))
        assertFalse(LibraryDiff.shouldDiff(sidecarMatches = false, externalMtimeMs = 1000, internalMtimeMs = 2000)) // older
        assertFalse(LibraryDiff.shouldDiff(sidecarMatches = false, externalMtimeMs = 1000, internalMtimeMs = 1000))
        assertFalse(LibraryDiff.shouldDiff(sidecarMatches = true, externalMtimeMs = 2000, internalMtimeMs = 1000))
    }

    @Test
    fun aLabelChangeIsUserAndAGeneratedOrBlankLabelIsReset() {
        val i = base()
        val e = copyOf(i)
        e.learnedLibrary = e.learnedLibrary.map { it.copy(label = "Castle show") }
        val ops = diff(i, e)
        val u = ops.single() as LocalEditOp.User
        assertEquals(E90C, u.hex)
        assertEquals("Castle show", u.label)
        assertEquals(SyncConst.PLACE_LIBRARY, u.place)
        assertEquals("e90c", u.kind)
        assertFalse(u.preset)
        assertTrue(u.userEdited)

        // Internal was renamed; the file has the generated label back -> RESET.
        val i2 = base()
        i2.learnedLibrary = i2.learnedLibrary.map { it.copy(label = "Castle show", userEdited = true) }
        val e2 = copyOf(base())
        assertEquals(listOf(LocalEditOp.Reset(E90C, null)), diff(i2, e2))
        val e3 = copyOf(i2)
        e3.learnedLibrary = e3.learnedLibrary.map { it.copy(label = "  ", userEdited = null) }
        assertEquals(listOf(LocalEditOp.Reset(E90C, null)), diff(i2, e3))
    }

    @Test
    fun categoryAndNoteChanges() {
        val i = base()
        val e = copyOf(i)
        e.learnedLibrary = e.learnedLibrary.map { it.copy(category = MagicCategory.SHOW) }
        val u = diff(i, e).single() as LocalEditOp.User
        assertEquals(SyncConst.CAT_SHOW, u.category)
        assertEquals(MagicClassifier.classify(E90C)!!.label, u.label)
        // A note on a row without user state: RESET carrying the note.
        val e2 = copyOf(i)
        e2.learnedColors = e2.learnedColors.map { it.copy(note = " remember ") }
        assertEquals(listOf(LocalEditOp.Reset(DUAL, "remember")), diff(i, e2))
    }

    @Test
    fun aUserPresetAddedOrRemoved() {
        val i = base()
        val e = copyOf(i)
        e.userPreset(DUAL, "Fav")
        val add = diff(i, e).single() as LocalEditOp.User
        assertTrue(add.preset)
        assertEquals("Fav", add.label)
        assertEquals(SyncConst.PLACE_PRESETS, add.place)
        val removed = diff(e, copyOf(i).also { it.learnedColors = it.learnedColors.map { r -> r.copy(label = "Fav", userEdited = true) } })
        val rm = removed.single() as LocalEditOp.User
        assertFalse(rm.preset)
        assertEquals("Fav", rm.label)
        assertEquals(SyncConst.PLACE_COLORS, rm.place)
    }

    @Test
    fun onlyInternalIsATombstoneWhenSyncableElseRowsGo() {
        val i = base()
        val e = copyOf(i)
        e.learnedColors = emptyList()
        e.learnedRaw = emptyList()
        val ops = diff(i, e, syncable = setOf(DUAL))
        assertEquals(listOf(LocalEditOp.Tombstone(DUAL), LocalEditOp.RemoveRows(RAW)), ops)
    }

    @Test
    fun onlyExternalLearnsOrAddsRawPlusUserWhenNamed() {
        val i = base()
        val e = copyOf(i)
        e.learn(FX)
        e.learn(STAR5, label = "My wand")
        e.raw(RAW2)
        val ops = diff(i, e)
        assertEquals(LocalEditOp.Learn(STAR5), ops[0])
        val u = ops[1] as LocalEditOp.User
        assertEquals(STAR5, u.hex)
        assertEquals("My wand", u.label)
        assertEquals(LocalEditOp.Learn(FX), ops[2])
        assertEquals(LocalEditOp.AddRaw(RAW2, MagicClassifier.rawLabel(RAW2)), ops[3])
        assertEquals(4, ops.size)
        val e2 = copyOf(i)
        e2.raw(RAW2, "Named gate")
        val ops2 = diff(i, e2)
        assertEquals(LocalEditOp.AddRaw(RAW2, "Named gate"), ops2[0])
        assertEquals("Named gate", (ops2[1] as LocalEditOp.User).label)
        assertEquals(SyncConst.PLACE_RAW, (ops2[1] as LocalEditOp.User).place)
    }

    @Test
    fun newWandNamesAddedChangedRemoved() {
        val other = "8301CF0B00C020224EAC7807866E81"
        val i = base().also { it.newWandNames = mapOf(NEWWAND to "Old", other to "Gone") }
        val e = copyOf(i).also { it.newWandNames = mapOf(NEWWAND to "New", "8301CF0B00C020224EAC7807866E82" to "Added") }
        assertEquals(
            listOf(
                LocalEditOp.NewWand(NEWWAND, "New"),
                LocalEditOp.NewWand("8301CF0B00C020224EAC7807866E82", "Added"),
                LocalEditOp.NewWand(other, null),
            ),
            diff(i, e),
        )
    }

    @Test
    fun applyingTheOpsMakesTheInternalViewMatchTheFile() {
        val x = DataHarness(rows = base())
        x.sync.onLearnedAll(listOf(DUAL, E90C))
        val e = copyOf(x.rows)
        e.learnedLibrary = e.learnedLibrary.map { it.copy(label = "Castle show") }
        e.learnedColors = emptyList()
        e.learn(FX)
        e.userPreset(FX, "Fav fx")
        e.newWandNames = mapOf(NEWWAND to "Spark")
        val ops = LibraryDiff.diff(x.rows.snapshot(), e.snapshot(), x.ledger)
        val entries = x.sync.onDiff(ops)
        assertEquals(listOf(entries to true), x.listener.local.takeLast(1))
        val iBy = x.rows.snapshot().byHex()
        val eBy = e.snapshot().byHex()
        for (hex in eBy.keys) assertEquals(hex, LibraryRows.viewOf(hex, eBy.getValue(hex)), LibraryRows.viewOf(hex, iBy.getValue(hex)))
        assertTrue(x.rows.rowsWith(DUAL).isEmpty())
        assertTrue(x.sync.isTombstoned(DUAL))
        assertEquals(mapOf(NEWWAND to "Spark"), x.rows.newWandNames)
        assertTrue(entries.all { it.syncFrom == null && (it.origin == null || it.origin == DataFixtures.SELF) })
        // A second diff of the same file is empty.
        assertTrue(LibraryDiff.diff(x.rows.snapshot(), e.snapshot(), x.ledger).isEmpty())
    }
}
