package com.magicmaker.android.sync

import com.magicmaker.android.core.MagicCategory
import com.magicmaker.android.core.MagicClassifier
import com.magicmaker.android.sync.DataFixtures.SELF
import com.magicmaker.android.sync.DataHexes.DUAL
import com.magicmaker.android.sync.DataHexes.E90C
import com.magicmaker.android.sync.DataHexes.FX
import com.magicmaker.android.sync.DataHexes.NEWWAND
import com.magicmaker.android.sync.DataHexes.RAW
import com.magicmaker.android.sync.DataHexes.RAW2
import com.magicmaker.android.sync.DataHexes.RED
import com.magicmaker.android.sync.DataHexes.STAR5
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LibraryMigrationTest {
    @Test
    fun generatedLabelHeuristic() {
        fun gen(hex: String, label: String, typeInfo: String = "x") = LibraryRows.isGeneratedLabel(hex, label, typeInfo)
        assertTrue(gen(RED, "Red"))                                         // built-in label
        assertTrue(gen(RED, MagicClassifier.classify(RED)!!.label))         // the classifier's
        assertTrue(gen(E90C, MagicClassifier.classify(E90C)!!.label))
        assertTrue(gen(RAW, MagicClassifier.rawLabel(RAW)))
        assertTrue(gen(RAW, "Raw: $RAW"))
        val long = "8301" + "AB".repeat(14)
        assertTrue(gen(long, MagicClassifier.rawLabel(long)))
        assertTrue(gen(long, "Raw: ${long.take(16)}…${long.takeLast(4)}"))  // rawPacketLabel
        assertTrue(gen(E90C, "Some cloud name", "imported"))                // D-P3-8
        assertTrue(gen(E90C, "   "))
        assertFalse(gen(E90C, "Main Street Glow"))
        assertFalse(gen(RAW, "Gate beacon", "raw"))
    }

    private fun migrate(rows: FakeRows, ledger: LedgerStore = LedgerStore()): Pair<LibraryMigration.Result, LedgerStore> =
        LibraryMigration.migrate(rows.snapshot(), SELF, ledger) to ledger

    @Test
    fun classesSeqOrderAndLegacyStamp() {
        val r = FakeRows()
        r.userPreset(FX, "My preset")                         // presets: USER|PRESET
        r.learn(STAR5)                                        // colors: PRESENCE
        r.learn(DUAL, label = "Renamed dual")                 // colors: USER
        r.learn(E90C)                                         // library: PRESENCE
        r.raw(RAW)                                            // raw unedited: none
        r.raw(RAW2, "Tagged gate")                            // raw named: USER
        r.newWandNames = mapOf(NEWWAND to "Sparkle")          // NEWWAND
        val (res, ledger) = migrate(r)
        val seqs = res.entries.map { it.keyString to it.seq }
        assertEquals(
            listOf(
                "0:$FX" to 1L, "0:$STAR5" to 2L, "0:$DUAL" to 3L, "0:$E90C" to 4L, "0:$RAW2" to 5L, "1:$NEWWAND" to 6L,
            ),
            seqs,
        )
        assertEquals(7L, ledger.nextSyncSeq)
        val fx = ledger.get("0:$FX")!!
        assertEquals(RecordClass.USER, fx.recordClass)
        assertEquals(SyncConst.U_LEGACY_ANDROID, fx.body.updatedAt)
        assertEquals(SELF, fx.origin)
        assertEquals(SyncConst.FLAG_USER_EDITED or SyncConst.FLAG_PRESET, fx.body.flags)
        assertEquals("My preset", fx.body.label)
        assertEquals(SyncConst.PLACE_PRESETS, fx.body.place)
        assertEquals(RecordClass.PRESENCE, ledger.get("0:$STAR5")!!.recordClass)
        val dual = ledger.get("0:$DUAL")!!
        assertEquals(SyncConst.FLAG_USER_EDITED, dual.body.flags)
        assertEquals("Renamed dual", dual.body.label)
        assertEquals(SyncConst.PLACE_COLORS, dual.body.place)
        assertEquals("dual", dual.body.kind)
        assertEquals(RecordClass.PRESENCE, ledger.get("0:$E90C")!!.recordClass)
        assertNull(ledger.get("0:$RAW"))
        assertEquals(SyncConst.PLACE_RAW, ledger.get("0:$RAW2")!!.body.place)
        val nw = ledger.get("1:$NEWWAND")!!
        assertEquals(RecordClass.NEWWAND, nw.recordClass)
        assertEquals(SyncConst.U_LEGACY_ANDROID, nw.body.updatedAt)
        assertEquals("Sparkle", nw.body.label)
        // Built-in preset rows have no entry.
        assertNull(ledger.get("0:$RED"))
        assertTrue(res.entries.all { it.syncFrom == null })
    }

    @Test
    fun aUserPresetWithAGeneratedLabelIsPresetOnly() {
        val r = FakeRows()
        r.userPreset(DUAL, MagicClassifier.classify(DUAL)!!.label)
        val (_, ledger) = migrate(r)
        assertEquals(SyncConst.FLAG_PRESET, ledger.get("0:$DUAL")!!.body.flags)
    }

    @Test
    fun aChangedCategoryIsAUserEdit() {
        val r = FakeRows()
        val row = r.learn(E90C)
        r.learnedLibrary = listOf(row.copy(category = MagicCategory.SHOW))
        val (_, ledger) = migrate(r)
        val e = ledger.get("0:$E90C")!!
        assertEquals(RecordClass.USER, e.recordClass)
        assertEquals(SyncConst.CAT_SHOW, e.body.category)
        assertEquals(MagicClassifier.classify(E90C)!!.label, e.body.label)
    }

    @Test
    fun aRenamedBuiltInIsAUserEditInPresets() {
        val r = FakeRows()
        r.presets = r.presets.map { if (it.hex == RED) it.copy(label = "Crimson") else it }
        val (_, ledger) = migrate(r)
        val e = ledger.get("0:$RED")!!
        assertEquals("Crimson", e.body.label)
        assertEquals(SyncConst.PLACE_PRESETS, e.body.place)
        assertEquals(SyncConst.FLAG_USER_EDITED, e.body.flags)
    }

    @Test
    fun aHexInSeveralListsGetsOneEntryProjectedOntoAllRows() {
        val r = FakeRows()
        r.userPreset(DUAL, "Preset name")
        r.learn(DUAL) // generated label in colors
        val (res, ledger) = migrate(r)
        assertEquals(1, res.entries.size)
        val e = ledger.get("0:$DUAL")!!
        assertEquals("Preset name", e.body.label)
        val rows = res.rows.presets.filter { it.hex == DUAL } + res.rows.learnedColors.filter { it.hex == DUAL }
        assertEquals(2, rows.size)
        assertTrue(rows.all { it.label == "Preset name" && it.userEdited == true })
        // Rows of hexes without a USER entry are untouched.
        assertEquals(r.presets.filter { !it.userRecorded }, res.rows.presets.filter { !it.userRecorded })
    }

    @Test
    fun runsOnceTheSecondPassAddsNothing() {
        val r = FakeRows()
        r.learn(E90C)
        r.learn(DUAL, "Mine")
        r.newWandNames = mapOf(NEWWAND to "N")
        val ledger = LedgerStore()
        val first = LibraryMigration.migrate(r.snapshot(), SELF, ledger)
        assertEquals(3, first.entries.size)
        val again = LibraryMigration.migrate(first.rows, SELF, ledger)
        assertTrue(again.entries.isEmpty())
        assertEquals(4L, ledger.nextSyncSeq)
    }

    @Test
    fun theImportedCloudLabelIsNotAUserName() {
        val r = FakeRows()
        val c = MagicClassifier.classify(E90C)!!
        r.learnedLibrary = listOf(
            com.magicmaker.android.core.MagicPacket(5, E90C, "Dictionary name", c.category, "imported", c.colors, ""),
        )
        val (_, ledger) = migrate(r)
        assertEquals(RecordClass.PRESENCE, ledger.get("0:$E90C")!!.recordClass)
    }

    @Test
    fun canonMatchesHexUtilsAndKeepsCanonicalStringsAsIs() {
        for (h in listOf(E90C, "8301abcd", "ABCD", "83 01 AB", "CF9B00C4", "", "8301", "8301E1:00")) {
            assertEquals(h, com.magicmaker.android.core.HexUtils.canonicalHex(h), LibraryRows.canon(h))
        }
        assertTrue(LibraryRows.canon(E90C) === E90C)
    }

    @Test
    fun aRawRowWithARawLabelHasNoUserStateEvenIfItNowClassifies() {
        val r = FakeRows()
        r.raw(E90C) // learned as raw by an older classifier; generated raw label, UNKNOWN
        val (res, ledger) = migrate(r)
        assertTrue(res.entries.isEmpty())
        assertNull(ledger.get("0:$E90C"))
    }

    @Test
    fun migratedPresenceIsByteIdenticalWhateverTheRowOrDevice() {
        // D7: an auto-learned row replicates as PRESENCE (u = 1, no origin, no content), so every node
        // that has the packet holds the same bytes. PROTOCOL §4.3's worked example is this packet.
        val expected = Bytes.fromHex("1013008301E100E90C00010F4D575A940705488BB0" + "11080100000000000000")
        fun presenceOf(hexInRow: String, self: Bytes): LedgerEntry {
            val r = FakeRows()
            val row = r.learn(E90C)
            r.learnedLibrary = listOf(row.copy(hex = hexInRow))
            val res = LibraryMigration.migrate(r.snapshot(), self, LedgerStore())
            assertEquals(1, res.entries.size)
            return res.entries.single()
        }
        for (hexInRow in listOf(E90C, E90C.lowercase(), "83 01 e1 00 e9 0c 00 01 0f 4d 57 5a 94 07 05 48 8b b0")) {
            for (self in listOf(SELF, DataFixtures.PEER)) {
                val e = presenceOf(hexInRow, self)
                assertEquals(RecordClass.PRESENCE, e.recordClass)
                assertEquals(expected, e.bodyBytes)
                assertEquals(0xCE6592D2L, e.version.crc)
                assertNull(e.origin)
                assertNull(e.syncFrom)
            }
        }
        // The same bytes as a live learn on any node, and as stored without `b` and rebuilt at load.
        val learned = LedgerStore().localLearn(DataFixtures.key(E90C).packet)!!
        assertEquals(expected, learned.bodyBytes)
        val json = LedgerEntryJson.of(learned)
        assertNull(json.b)
        assertEquals(expected, SyncStateCodec.entryOf("0:$E90C", json)!!.bodyBytes)
        // A colour row (STAR5) too: key + updatedAt only.
        val r = FakeRows()
        r.learn(STAR5)
        val star = LibraryMigration.migrate(r.snapshot(), SELF, LedgerStore()).entries.single()
        assertEquals(RecordBody(RecordKey(SyncConst.NS_LIB, Bytes.fromHex(STAR5)), SyncConst.U_PRESENCE).encode(), star.bodyBytes)
    }

    @Test
    fun migratedBodiesAreValidRecords() {
        val r = FakeRows()
        r.userPreset(E90C, "  Trim me  ")
        r.learn(DUAL, "é".repeat(50))
        val (res, _) = migrate(r)
        for (e in res.entries) {
            assertEquals(e.bodyBytes, RecordBody.decode(e.bodyBytes).encode())
            assertEquals(e.recordClass, e.body.recordClass())
        }
        assertEquals("Trim me", res.entries.first().body.label)
        assertEquals("é".repeat(32), res.entries.last().body.label)
    }
}
