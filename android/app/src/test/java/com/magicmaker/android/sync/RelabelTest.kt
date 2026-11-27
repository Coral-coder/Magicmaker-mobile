package com.magicmaker.android.sync

import com.magicmaker.android.core.MagicClassifier
import com.magicmaker.android.core.MagicPacket
import com.magicmaker.android.core.toPacket
import com.magicmaker.android.sync.DataHexes.E90C
import com.magicmaker.android.sync.DataHexes.STAR5
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** Spec §5.4: re-hearing a packet never undoes a user's name and never rewrites a row's hex. */
class RelabelTest {
    private val show = MagicClassifier.classify(E90C)!!

    @Test
    fun aRenamedShowRowKeepsItsLabelOnRehear() {
        val row = show.toPacket(userRecorded = true).copy(id = 3, label = "Castle show", userEdited = true)
        assertSame(row, LibraryRows.relabelOnRehear(row, show))
    }

    @Test
    fun anUneditedRowStillFollowsTheClassifier() {
        val row = show.toPacket(userRecorded = true).copy(id = 3, label = "Old classifier name")
        val out = LibraryRows.relabelOnRehear(row, show)
        assertEquals(show.label, out.label)
        assertEquals(row.hex, out.hex)
        // Nothing changes when the label already matches (no save storm on repeats).
        assertSame(out, LibraryRows.relabelOnRehear(out, show))
    }

    @Test
    fun theHexIsNeverRewritten() {
        val row = show.toPacket(userRecorded = true).copy(id = 3, hex = E90C.lowercase(), label = "x")
        val heard = show.copy(hex = E90C)
        assertEquals(E90C.lowercase(), LibraryRows.relabelOnRehear(row, heard).hex)
    }

    @Test
    fun starlightVerifyKeepsHexAndNameAndGainsVerified() {
        val c = MagicClassifier.classify(STAR5)!!
        val stored = MagicPacket(7, STAR5, "My wand", c.category, "starlight", c.colors, c.simKey, true, userEdited = true)
        val heard = MagicPacket(0, STAR5, c.label, c.category, "starlight", c.colors, c.simKey, true, wandVerified = true)
        val out = LibraryRows.relabelOnRehear(stored, heard, verified = true)
        assertEquals("My wand", out.label)
        assertEquals(STAR5, out.hex)
        assertTrue(out.wandVerified)
        // verified once stays verified.
        assertTrue(LibraryRows.relabelOnRehear(out, heard, verified = false).wandVerified)
        // An unedited starlight row follows the classifier label.
        val plain = stored.copy(label = "stale", userEdited = null)
        assertEquals(c.label, LibraryRows.relabelOnRehear(plain, heard, verified = true).label)
    }

    @Test
    fun aRemoteRenameSurvivesALaterLearnedRehearThroughTheProjection() {
        val x = DataHarness()
        x.rows.learn(E90C)
        x.sync.applyRemote(DataFixtures.userBody(E90C, DataFixtures.T0, "From iPhone", SyncConst.CAT_ANIMATION, SyncConst.PLACE_LIBRARY),
            DataFixtures.PEER, DataFixtures.T0, live = true)
        val row = x.rows.learnedLibrary.single()
        assertEquals(true, row.userEdited)
        assertSame(row, LibraryRows.relabelOnRehear(row, show))
    }
}
