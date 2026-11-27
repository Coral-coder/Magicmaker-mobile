package com.magicmaker.android.sync

import com.magicmaker.android.core.MagicCategory
import com.magicmaker.android.core.MagicClassifier
import com.magicmaker.android.core.PresetCatalog
import com.magicmaker.android.sync.DataFixtures.PEER
import com.magicmaker.android.sync.DataFixtures.SELF
import com.magicmaker.android.sync.DataFixtures.T0
import com.magicmaker.android.sync.DataHexes.DUAL
import com.magicmaker.android.sync.DataHexes.E90C
import com.magicmaker.android.sync.DataHexes.FX
import com.magicmaker.android.sync.DataHexes.NEWWAND
import com.magicmaker.android.sync.DataHexes.NOISE
import com.magicmaker.android.sync.DataHexes.RAW
import com.magicmaker.android.sync.DataHexes.RED
import com.magicmaker.android.sync.DataHexes.STAR5
import com.magicmaker.android.sync.DataHexes.STAR9
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LibrarySyncTest {
    private fun h() = DataHarness()

    private fun body(e: LedgerEntry) = e.body

    // ---- local edits -----------------------------------------------------------------------

    @Test
    fun renameAppliesToAllRowsAndWritesFullStateUser() {
        val x = h()
        x.rows.learn(DUAL)
        x.rows.userPreset(DUAL, "Saved dual")
        val e = x.sync.onUserEdit(DUAL, label = "  My Glow ", category = null, note = null)!!
        val rows = x.rows.rowsWith(DUAL)
        assertEquals(2, rows.size)
        assertTrue(rows.all { it.label == "My Glow" && it.userEdited == true })
        val b = body(e)
        assertEquals(RecordClass.USER, e.recordClass)
        assertEquals("My Glow", b.label)
        assertEquals(SyncConst.CAT_COLOR, b.category)
        assertEquals("dual", b.kind)
        assertEquals(SyncConst.PLACE_PRESETS, b.place) // the user preset is the first row
        assertEquals(SyncConst.FLAG_USER_EDITED or SyncConst.FLAG_PRESET, b.flags)
        assertEquals(SELF, b.origin)
        assertEquals(T0, b.updatedAt)
        assertNull(e.syncFrom)
        assertEquals(listOf(listOf(e) to false), x.listener.local)
        assertTrue(x.saves.calls.isNotEmpty())
    }

    @Test
    fun aBlankRenameIsResetToTheDerivedLabel() {
        val x = h()
        x.rows.learn(E90C)
        x.sync.onUserEdit(E90C, "Castle", null, null)
        x.now += 10
        val e = x.sync.onUserEdit(E90C, "   ", null, null)!!
        assertEquals(RecordClass.RESET, e.recordClass)
        val row = x.rows.rowsWith(E90C).single()
        assertEquals(MagicClassifier.classify(E90C)!!.label, row.label)
        assertNull(row.userEdited)
        // A built-in resets to the built-in label, not the classifier's.
        x.sync.onUserEdit(RED, "Crimson", null, null)
        x.sync.onUserEdit(RED, "", null, null)
        assertEquals("Red", x.rows.rowsWith(RED).single().label)
    }

    @Test
    fun recategorizeIsAUserEditWithTheCurrentLabel() {
        val x = h()
        x.rows.learn(E90C)
        val e = x.sync.onUserEdit(E90C, null, SyncConst.CAT_SHOW, null)!!
        val row = x.rows.rowsWith(E90C).single()
        assertEquals(MagicCategory.SHOW, row.category)
        assertEquals(SyncConst.CAT_SHOW, e.body.category)
        assertEquals(MagicClassifier.classify(E90C)!!.label, e.body.label)
        assertEquals(SyncConst.PLACE_LIBRARY, e.body.place)
        assertEquals(SyncConst.FLAG_USER_EDITED, e.body.flags)
    }

    @Test
    fun notesAreUserOnEditedRowsElseReset() {
        val x = h()
        x.rows.learn(E90C)
        val r = x.sync.onNote(E90C, "  seen at the castle ")!!
        assertEquals(RecordClass.RESET, r.recordClass)
        assertEquals("seen at the castle", r.body.note)
        assertEquals("seen at the castle", x.rows.rowsWith(E90C).single().note)
        x.sync.onUserEdit(E90C, "Castle", null, null).let { assertEquals("seen at the castle", it!!.body.note) }
        val u = x.sync.onNote(E90C, "new note")!!
        assertEquals(RecordClass.USER, u.recordClass)
        assertEquals("Castle", u.body.label)
        assertEquals("new note", u.body.note)
        val cleared = x.sync.onNote(E90C, "")!!
        assertNull(cleared.body.note)
        assertNull(x.rows.rowsWith(E90C).single().note)
    }

    @Test
    fun savePresetIsUserPresetAndBeatsATombstone() {
        val x = h()
        x.rows.learn(E90C)
        x.sync.onLearned(E90C)
        val t = x.sync.onDelete(listOf(E90C)).single()
        assertEquals(RecordClass.TOMBSTONE, t.recordClass)
        assertTrue(x.rows.rowsWith(E90C).isEmpty())
        assertTrue(x.sync.isTombstoned(E90C))
        x.rows.userPreset(E90C, "My show")
        val e = x.sync.onSavePreset(E90C, "My show", userTyped = true)!!
        assertEquals(RecordClass.USER, e.recordClass)
        assertTrue(e.version > t.version)
        assertEquals(SyncConst.FLAG_USER_EDITED or SyncConst.FLAG_PRESET, e.body.flags)
        assertEquals(SyncConst.PLACE_PRESETS, e.body.place)
        assertFalse(x.sync.isTombstoned(E90C))
        assertEquals("My show", x.rows.rowsWith(E90C).single().label)
    }

    @Test
    fun aPresetSavedWithoutATypedLabelIsPresetOnlyAndKeepsARename() {
        val x = h()
        x.rows.learn(DUAL)
        x.rows.userPreset(DUAL, MagicClassifier.classify(DUAL)!!.label)
        val e = x.sync.onSavePreset(DUAL, MagicClassifier.classify(DUAL)!!.label, userTyped = false)!!
        assertEquals(SyncConst.FLAG_PRESET, e.body.flags)
        // A renamed row: the preset keeps the user's name instead of reverting it.
        val y = h()
        y.rows.learn(FX)
        y.sync.onUserEdit(FX, "Fountain", null, null)
        y.rows.userPreset(FX, MagicClassifier.classify(FX)!!.label)
        val f = y.sync.onSavePreset(FX, MagicClassifier.classify(FX)!!.label, userTyped = false)!!
        assertEquals("Fountain", f.body.label)
        assertTrue(y.rows.rowsWith(FX).all { it.label == "Fountain" })
    }

    @Test
    fun deleteTombstonesRemovesEveryLearnedRowAndUserPresetAndResetsABuiltIn() {
        val x = h()
        x.rows.learn(DUAL)
        x.rows.userPreset(DUAL, "Mine")
        x.sync.onSavePreset(DUAL, "Mine", true)
        val t = x.sync.onDelete(listOf(DUAL)).single()
        assertEquals(RecordClass.TOMBSTONE, t.recordClass)
        assertTrue(x.rows.rowsWith(DUAL).isEmpty()) // D-P3-6: the learned row goes too
        // Built-in: edited then deleted -> reset, not removed.
        x.sync.onUserEdit(RED, "Crimson", null, null)
        x.sync.onDelete(listOf(RED))
        val red = x.rows.rowsWith(RED).single()
        assertEquals("Red", red.label)
        assertEquals(MagicCategory.COLOR, red.category)
        assertNull(red.userEdited)
        assertNull(red.note)
        assertEquals(PresetCatalog.asMagicPackets().size, x.rows.presets.size)
    }

    @Test
    fun anUneditedRawRowGetsNoEntryAndADeleteMakesNoTombstone() {
        val x = h()
        x.rows.raw(RAW) // learn paths create no entry for a new raw row
        assertTrue(x.sync.onDelete(listOf(RAW)).isEmpty())
        assertTrue(x.rows.learnedRaw.isEmpty())
        assertNull(x.entry(RAW))
        assertFalse(x.sync.isTombstoned(RAW))
        assertTrue(x.rows.rawRebuilds > 0)
    }

    @Test
    fun anEditedRawRowIsTombstonedAndBlocksRelearn() {
        val x = h()
        x.rows.raw(RAW)
        val u = x.sync.onUserEdit(RAW, "Gate beacon", null, null)!!
        assertEquals(SyncConst.PLACE_RAW, u.body.place)
        assertEquals("raw", u.body.kind)
        x.sync.onDelete(listOf(RAW))
        assertTrue(x.sync.isTombstoned(RAW))
        assertTrue(x.rows.learnedRaw.isEmpty())
    }

    @Test
    fun clearingStarlightIsABulkTombstoneBatch() {
        val x = h()
        x.rows.learn(STAR5)
        x.rows.learn(STAR9)
        x.sync.onLearnedAll(listOf(STAR5, STAR9))
        x.listener.local.clear()
        val out = x.sync.onDelete(listOf(STAR5, STAR9), bulk = true)
        assertEquals(2, out.size)
        assertTrue(out.all { it.recordClass == RecordClass.TOMBSTONE })
        assertTrue(x.rows.learnedColors.isEmpty())
        assertEquals(listOf(out to true), x.listener.local)
    }

    @Test
    fun learnIsPresenceOnlyWhenTheKeyHasNoEntry() {
        val x = h()
        x.rows.learn(DUAL)
        val p = x.sync.onLearned(DUAL)!!
        assertEquals(RecordClass.PRESENCE, p.recordClass)
        assertEquals(SyncConst.U_PRESENCE, p.body.updatedAt)
        assertNull(p.origin)
        assertNull(x.sync.onLearned(DUAL))
        x.rows.learn(E90C)
        x.sync.onUserEdit(E90C, "Named", null, null)
        assertNull(x.sync.onLearned(E90C))
        assertEquals(listOf(listOf(p) to false), x.listener.local.take(1))
    }

    @Test
    fun aLearnedBatchIsOneBulkNotification() {
        val x = h()
        x.rows.learn(DUAL)
        x.rows.learn(E90C)
        val out = x.sync.onLearnedAll(listOf(DUAL, E90C, DUAL))
        assertEquals(2, out.size)
        assertEquals(listOf(out to true), x.listener.local)
    }

    @Test
    fun labelsAndNotesAreNormalizedBeforeStoring() {
        val x = h()
        x.rows.learn(E90C)
        val long = " " + "é".repeat(40) + " "          // 80 UTF-8 bytes, em-space in front
        val note = "x".repeat(150) + "€€€€"                // 162 bytes: the last € does not fit
        val e = x.sync.onUserEdit(E90C, long, null, note)!!
        assertEquals("é".repeat(32), e.body.label)
        assertEquals("x".repeat(150) + "€€€", e.body.note)
        val row = x.rows.rowsWith(E90C).single()
        assertEquals(e.body.label, row.label)
        assertEquals(e.body.note, row.note)
    }

    @Test
    fun newWandNamesAreRecordsAndPrefs() {
        val x = h()
        val m = x.sync.onNewWandName(NEWWAND.lowercase(), "  Sparkle ")
        assertEquals(mapOf(NEWWAND to "Sparkle"), m)
        assertEquals(m, x.rows.newWandNames)
        val e = x.entry(NEWWAND, SyncConst.NS_NEWWAND)!!
        assertEquals(RecordClass.NEWWAND, e.recordClass)
        assertEquals("Sparkle", e.body.label)
        x.now += 5
        assertEquals(emptyMap<String, String>(), x.sync.onNewWandName(NEWWAND, " "))
        val d = x.entry(NEWWAND, SyncConst.NS_NEWWAND)!!
        assertTrue(d.isTombstone)
        assertEquals(emptyMap<String, String>(), x.rows.newWandNames)
    }

    // ---- remote records --------------------------------------------------------------------

    @Test
    fun remoteTombstoneRemovesRowsAndResetsBuiltIns() {
        val x = h()
        x.rows.learn(DUAL)
        x.rows.userPreset(DUAL, "Mine")
        val r = x.sync.applyRemote(DataFixtures.tombstoneBody(DUAL, T0 + 1), PEER, T0, live = true)
        assertEquals(ApplyStatus.ACCEPT, r.status)
        assertEquals(PEER, r.entry!!.syncFrom)
        assertTrue(x.rows.rowsWith(DUAL).isEmpty())
        x.sync.onUserEdit(RED, "Crimson", null, null)
        x.sync.applyRemote(DataFixtures.tombstoneBody(RED, T0 + 5), PEER, T0, live = true)
        assertEquals("Red", x.rows.rowsWith(RED).single().label)
        assertEquals(2, x.rows.revisions)
    }

    @Test
    fun remoteUserSetsAllRowsAndAddsOrRemovesTheUserPreset() {
        val x = h()
        x.rows.learn(DUAL)
        val add = DataFixtures.userBody(DUAL, T0 + 1, "From iPhone", SyncConst.CAT_COLOR, SyncConst.PLACE_COLORS, preset = true, kind = "dual", note = "n1")
        assertEquals(ApplyStatus.ACCEPT, x.sync.applyRemote(add, PEER, T0, live = true).status)
        val rows = x.rows.rowsWith(DUAL)
        assertEquals(2, rows.size)
        assertTrue(rows.all { it.label == "From iPhone" && it.note == "n1" && it.userEdited == true })
        val preset = x.rows.presets.single { it.userRecorded }
        assertEquals(MagicClassifier.classify(DUAL)!!.simKey, preset.simKey)
        val clear = DataFixtures.userBody(DUAL, T0 + 2, "From iPhone", SyncConst.CAT_COLOR, SyncConst.PLACE_COLORS, preset = false)
        x.sync.applyRemote(clear, PEER, T0, live = true)
        assertTrue(x.rows.presets.none { it.userRecorded })
        assertEquals(1, x.rows.rowsWith(DUAL).size)
        assertNull(x.rows.rowsWith(DUAL).single().note)
    }

    @Test
    fun remoteUserWithNoRowCreatesOneInPlace() {
        val x = h()
        x.sync.applyRemote(DataFixtures.userBody(E90C, T0, "Parade", SyncConst.CAT_SHOW, SyncConst.PLACE_LIBRARY, kind = "e90c"), PEER, T0, true)
        val lib = x.rows.learnedLibrary.single()
        assertEquals("Parade", lib.label)
        assertEquals(MagicCategory.SHOW, lib.category)
        assertEquals("e90c", lib.typeInfo)
        assertEquals(MagicClassifier.classify(E90C)!!.simKey, lib.simKey)
        assertEquals(true, lib.userEdited)
        x.sync.applyRemote(DataFixtures.userBody(RAW, T0, "Gate", SyncConst.CAT_UNKNOWN, SyncConst.PLACE_RAW), PEER, T0, true)
        val raw = x.rows.learnedRaw.single()
        assertEquals("RAW:$RAW", raw.simKey)
        assertEquals("raw", raw.typeInfo)
        x.sync.applyRemote(DataFixtures.userBody(DUAL, T0, "Glow", SyncConst.CAT_COLOR, SyncConst.PLACE_COLORS), PEER, T0, true)
        assertEquals("Glow", x.rows.learnedColors.single().label)
        assertTrue(x.rows.rawRebuilds > 0)
    }

    @Test
    fun remoteResetDerivesTheLabel() {
        val x = h()
        x.rows.learn(E90C, label = "Old name")
        x.sync.applyRemote(DataFixtures.resetBody(E90C, T0, note = "kept"), PEER, T0, true)
        val row = x.rows.rowsWith(E90C).single()
        assertEquals(MagicClassifier.classify(E90C)!!.label, row.label)
        assertEquals("kept", row.note)
        assertNull(row.userEdited)
        // No row: as PRESENCE (the learn routine).
        x.sync.applyRemote(DataFixtures.resetBody(FX, T0), PEER, T0, true)
        assertEquals(1, x.rows.rowsWith(FX).size)
    }

    @Test
    fun remotePresenceLearnsOrIsSkipped() {
        val x = h()
        assertEquals(ApplyStatus.ACCEPT, x.sync.applyRemote(DataFixtures.presenceBody(DUAL), PEER, T0, true).status)
        assertEquals(1, x.rows.rowsWith(DUAL).size)
        assertEquals(PEER, x.entry(DUAL)!!.syncFrom)
        // The learn routine declines (band noise): the entry stays, no row, counted.
        x.sync.applyRemote(DataFixtures.presenceBody(NOISE), PEER, T0, true)
        assertTrue(x.rows.rowsWith(NOISE).isEmpty())
        assertNotNull(x.entry(NOISE))
        assertEquals(1, x.sync.stats().skippedPresence)
        // A row already there: nothing to do.
        x.rows.raw(RAW)
        x.sync.applyRemote(DataFixtures.presenceBody(RAW), PEER, T0, true)
        assertEquals(1, x.rows.rowsWith(RAW).size)
        assertEquals(listOf(DUAL, NOISE), x.rows.syncLearns)
    }

    @Test
    fun remoteNewWandSetsAndRemovesTheName() {
        val x = h()
        x.sync.applyRemote(DataFixtures.newWandBody(NEWWAND, T0, "Blue spark"), PEER, T0, true)
        assertEquals(mapOf(NEWWAND to "Blue spark"), x.rows.newWandNames)
        x.sync.applyRemote(DataFixtures.newWandBody(NEWWAND, T0 + 1, null), PEER, T0, true)
        assertEquals(emptyMap<String, String>(), x.rows.newWandNames)
    }

    @Test
    fun pageRecordsAreProjectedOnlyAtCommitWithOneRevisionBump() {
        val x = h()
        x.rows.learn(E90C)
        x.sync.applyRemote(DataFixtures.userBody(E90C, T0, "Paged", SyncConst.CAT_SHOW, SyncConst.PLACE_LIBRARY), PEER, T0, live = false)
        x.sync.applyRemote(DataFixtures.presenceBody(DUAL), PEER, T0, live = false)
        x.sync.applyRemote(DataFixtures.tombstoneBody(FX, T0), PEER, T0, live = false)
        assertEquals(MagicClassifier.classify(E90C)!!.label, x.rows.rowsWith(E90C).single().label)
        assertTrue(x.rows.rowsWith(DUAL).isEmpty())
        assertEquals(0, x.rows.revisions)
        assertTrue(x.saves.calls.isEmpty())
        val ps = PeerState(Bytes.fromHex("9E859EDAA1D4E6A4"), 3, false)
        x.sync.commitPage(PEER, ps, T0 + 9)
        assertEquals("Paged", x.rows.rowsWith(E90C).single().label)
        assertEquals(1, x.rows.rowsWith(DUAL).size)
        assertEquals(1, x.rows.revisions)
        assertEquals(listOf(true), x.saves.calls)
        val stored = x.sync.loadPeers().getValue(PEER)
        assertEquals(3L, stored.state.wm)
        assertEquals(T0 + 9, stored.lastSyncMs)
        // A commit with nothing pending still stores the peer and saves at once.
        x.sync.commitPage(PEER, PeerState(ps.dbId, 4, true), T0 + 10)
        assertEquals(1, x.rows.revisions)
        assertEquals(4L, x.sync.loadPeers().getValue(PEER).state.wm)
        assertTrue(x.listener.local.isEmpty()) // remote changes are not local changes
    }

    @Test
    fun rejectsAreCountedAndLeaveTheLedgerAlone() {
        val x = h()
        val bad = Bytes.fromHex("1001")
        assertEquals(ApplyStatus.BAD_MSG, x.sync.applyRemote(bad, PEER, T0, true).status)
        val future = DataFixtures.userBody(E90C, T0 + 2 * SyncConst.FUTURE_BOUND_MS, "Future", 1, 3)
        assertEquals(ApplyStatus.CLOCK, x.sync.applyRemote(future, PEER, T0, true).status)
        assertEquals(2, x.sync.stats().rejected)
        assertEquals(0, x.sync.recordCount())
        val ok = DataFixtures.userBody(E90C, T0, "A", 1, 3)
        x.sync.applyRemote(ok, PEER, T0, true)
        assertEquals(ApplyStatus.DUPLICATE, x.sync.applyRemote(ok, PEER, T0, true).status)
        assertEquals(ApplyStatus.STALE, x.sync.applyRemote(DataFixtures.userBody(E90C, T0 - 1, "B", 1, 3), PEER, T0, true).status)
        assertEquals("A", x.rows.rowsWith(E90C).single().label)
    }

    @Test
    fun aLocalAndARemoteChangeOfOneKeyLeaveIdenticalRows() {
        val a = h()
        val b = h()
        for (x in listOf(a, b)) {
            x.rows.learn(DUAL)
            x.rows.learn(E90C)
        }
        val e = a.sync.onUserEdit(DUAL, "Shared", SyncConst.CAT_ANIMATION, "note")!!
        b.sync.applyRemote(e.bodyBytes, SELF, T0, live = true)
        assertEquals(a.rows.rowsWith(DUAL).map { it.copy(id = 0) }, b.rows.rowsWith(DUAL).map { it.copy(id = 0) })
        a.sync.onLearned(E90C)
        val t = a.sync.onDelete(listOf(E90C)).single()
        b.sync.applyRemote(t.bodyBytes, SELF, T0, live = true)
        assertEquals(a.rows.all().map { it.copy(id = 0) }, b.rows.all().map { it.copy(id = 0) })
    }

    // ---- port plumbing ---------------------------------------------------------------------

    @Test
    fun onSavedRaisesDurableThenIssuedThenNotifies() {
        val x = h()
        x.rows.learn(DUAL)
        x.rows.learn(E90C)
        x.sync.onLearnedAll(listOf(DUAL, E90C))
        assertEquals(0L, x.sync.durableHigh())
        val pull = Pull(1, 0, null, null, Bytes.ZERO8, null)
        assertTrue(x.sync.servePage(pull, false, PEER).recs.isEmpty())
        val seq = x.sync.nextSyncSeq
        x.sync.onSaved(seq)
        assertEquals(seq - 1, x.sync.durableHigh())
        assertEquals(seq, x.identity.issued)
        assertEquals(listOf(seq - 1), x.listener.durable)
        assertEquals(2, x.sync.servePage(pull, false, PEER).recs.size)
        assertEquals(2L, x.sync.servePage(pull, false, PEER).pageEnd.feedHigh)
        // An older snapshot never lowers it.
        x.sync.onSaved(1)
        assertEquals(seq - 1, x.sync.durableHigh())
        val s = x.sync.stats()
        assertEquals(LibrarySyncStats(2, 0, seq, seq - 1, 0, 0), s)
    }

    @Test
    fun peersAreStoredAsCopies() {
        val x = h()
        val ps = PeerState(Bytes.fromHex("9E859EDAA1D4E6A4"), 5, true)
        x.sync.putPeer(PEER, ps, null)
        ps.wm = 99
        assertEquals(5L, x.sync.loadPeers().getValue(PEER).state.wm)
        x.sync.loadPeers().getValue(PEER).state.wm = 77
        assertEquals(5L, x.sync.loadPeers().getValue(PEER).state.wm)
        x.sync.putPeer(PEER, PeerState(ps.dbId, 6, true), 1234)
        x.sync.putPeer(PEER, PeerState(ps.dbId, 7, true), null)
        assertEquals(1234L, x.sync.loadPeers().getValue(PEER).lastSyncMs) // kept when null
        assertEquals(7L, x.sync.snapshot().peers!!.getValue(PEER.hex()).wm)
        assertEquals(listOf(false, false, false), x.saves.calls)
    }

    @Test
    fun bulkFlags() {
        val x = h()
        x.rows.learn(DUAL)
        x.rows.learn(E90C)
        x.sync.onUserEdit(DUAL, "One", null, null)
        x.sync.onDelete(listOf(DUAL, E90C))
        x.sync.onDiff(listOf(LocalEditOp.NewWand(NEWWAND, "N")))
        assertEquals(listOf(false, true, true), x.listener.local.map { it.second })
    }
}
