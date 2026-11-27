package com.magicmaker.android.sync

import com.google.gson.GsonBuilder
import com.google.gson.JsonParser
import com.magicmaker.android.core.MagicCategory
import com.magicmaker.android.core.MagicPacket
import com.magicmaker.android.data.MagicStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class SyncStateJsonTest {
    private val gson = GsonBuilder().create()

    /** A ledger with a PRESENCE, a local USER, a remote TOMBSTONE and a remote NEWWAND. */
    private fun sample(): Pair<LedgerStore, Map<Bytes, StoredPeer>> {
        val st = LedgerStore()
        st.localLearn(DataFixtures.key(DataHexes.DUAL).packet)
        st.localEdit(RecordClass.USER, DataFixtures.key(DataHexes.E90C), DataFixtures.T0, DataFixtures.SELF, label = "Main Street Glow",
            category = SyncConst.CAT_SHOW, kind = "e90c", place = SyncConst.PLACE_LIBRARY, note = "fireworks")
        assertEquals(ApplyStatus.ACCEPT, st.applyRemote(DataFixtures.tombstoneBody(DataHexes.FX, DataFixtures.T0 + 5), DataFixtures.PEER, DataFixtures.T0).status)
        assertEquals(ApplyStatus.ACCEPT,
            st.applyRemote(DataFixtures.newWandBody(DataHexes.NEWWAND, DataFixtures.T0 + 6, "Sparkle"), DataFixtures.PEER, DataFixtures.T0).status)
        val peers = mapOf(
            DataFixtures.PEER to StoredPeer(PeerState(Bytes.fromHex("9E859EDAA1D4E6A4"), 4, true), DataFixtures.T0 + 1000),
        )
        return st to peers
    }

    private fun assertSameLedger(a: LedgerStore, b: LedgerStore) {
        assertEquals(a.size, b.size)
        assertEquals(a.nextSyncSeq, b.nextSyncSeq)
        assertEquals(a.lastLocalStamp, b.lastLocalStamp)
        val x = a.entriesBySeq()
        val y = b.entriesBySeq()
        for (i in x.indices) {
            assertEquals(x[i].keyString, y[i].keyString)
            assertEquals(x[i].seq, y[i].seq)
            assertEquals(x[i].bodyBytes, y[i].bodyBytes)
            assertEquals(x[i].syncFrom, y[i].syncFrom)
        }
        assertEquals(a.feedIndex(), b.feedIndex())
    }

    @Test
    fun gsonRoundTripThroughThePersistedState() {
        val (st, peers) = sample()
        val state = MagicStore.PersistedState(sync = SyncStateJson.from(st, peers))
        val json = gson.toJson(state)
        val back = gson.fromJson(json, MagicStore.PersistedState::class.java)
        val r = SyncStateCodec.restore(back.sync!!)
        assertFalse(r.corrupt)
        assertSameLedger(st, r.ledger)
        val p = r.peers.getValue(DataFixtures.PEER)
        assertEquals(Bytes.fromHex("9E859EDAA1D4E6A4"), p.state.dbId)
        assertEquals(4L, p.state.wm)
        assertTrue(p.state.excludeOk)
        assertEquals(DataFixtures.T0 + 1000, p.lastSyncMs)
    }

    @Test
    fun shortKeysAndPresenceBodyOmitted() {
        val (st, peers) = sample()
        val o = JsonParser.parseString(gson.toJson(SyncStateJson.from(st, peers))).asJsonObject
        assertEquals(1, o["schema"].asInt)
        assertEquals(st.nextSyncSeq, o["nextSyncSeq"].asLong)
        val led = o["ledger"].asJsonObject
        val presence = led[LibraryRows.libKeyString(DataHexes.DUAL)].asJsonObject
        assertEquals(setOf("u", "c", "s"), presence.keySet())
        assertEquals(1L, presence["u"].asLong)
        val user = led[LibraryRows.libKeyString(DataHexes.E90C)].asJsonObject
        assertEquals(setOf("u", "o", "c", "b", "s"), user.keySet())
        assertEquals(DataFixtures.SELF.hex(), user["o"].asString)
        val tomb = led[LibraryRows.libKeyString(DataHexes.FX)].asJsonObject
        assertEquals(DataFixtures.PEER.hex(), tomb["f"].asString)
        // c is the u32 CRC as a plain JSON number.
        val e = st.get(LibraryRows.libKeyString(DataHexes.E90C))!!
        assertEquals(SyncCrypto.crc32(e.bodyBytes), user["c"].asLong)
        assertEquals(e.bodyBytes, Bytes.of(Base64.getDecoder().decode(user["b"].asString)))
        // The rebuilt PRESENCE equals the stored one byte for byte.
        val back = SyncStateCodec.restore(gson.fromJson(o, SyncStateJson::class.java))
        assertEquals(st.get(LibraryRows.libKeyString(DataHexes.DUAL))!!.bodyBytes, back.ledger.get(LibraryRows.libKeyString(DataHexes.DUAL))!!.bodyBytes)
    }

    @Test
    fun anOldFileWithoutSyncNoteOrUserEditedLoadsAsNulls() {
        val old = """{"presets":[{"id":1,"hex":"8301E905002E0EF5B0","label":"Red","category":"COLOR","typeInfo":"color",""" +
            """"colors":"","simKey":"P:Red","userRecorded":false,"wandVerified":false}],"learnedColors":[],"learnedLibrary":[],""" +
            """"nextPacketId":2,"nextRecordingId":1,"nextRuleId":1}"""
        val s = gson.fromJson(old, MagicStore.PersistedState::class.java)
        assertNull(s.sync)
        assertNull(s.learnedRaw)
        val p = s.presets.single()
        assertNull(p.note)
        assertNull(p.userEdited)
        assertEquals("Red", p.label)
    }

    @Test
    fun rowsWithoutTheNewFieldsSerializeExactlyAsBefore() {
        val row = MagicPacket(7, DataHexes.RAW, "Raw: 8301AABBCCDDEEFF", MagicCategory.UNKNOWN, "raw", simKey = "RAW:${DataHexes.RAW}")
        assertEquals(
            """{"id":7,"hex":"8301AABBCCDDEEFF","label":"Raw: 8301AABBCCDDEEFF","category":"UNKNOWN","typeInfo":"raw",""" +
                """"colors":"","simKey":"RAW:8301AABBCCDDEEFF","userRecorded":false,"wandVerified":false}""",
            gson.toJson(row),
        )
        val edited = row.copy(note = "n", userEdited = true)
        val o = JsonParser.parseString(gson.toJson(edited)).asJsonObject
        assertEquals("n", o["note"].asString)
        assertTrue(o["userEdited"].asBoolean)
        // A state without sync carries no "sync" key at all.
        assertFalse(JsonParser.parseString(gson.toJson(MagicStore.PersistedState())).asJsonObject.has("sync"))
    }

    @Test
    fun aBadEntryIsCorruptionAndTheValidOnesAreKept() {
        val (st, peers) = sample()
        val good = SyncStateJson.from(st, peers)
        val kUser = LibraryRows.libKeyString(DataHexes.E90C)
        val kPres = LibraryRows.libKeyString(DataHexes.DUAL)
        val kTomb = LibraryRows.libKeyString(DataHexes.FX)
        fun mutate(f: (MutableMap<String, LedgerEntryJson>) -> Unit): RestoredSync {
            val m = good.ledger!!.toMutableMap()
            f(m)
            return SyncStateCodec.restore(good.copy(ledger = m))
        }
        assertFalse(SyncStateCodec.restore(good).corrupt)
        val cases = listOf<(MutableMap<String, LedgerEntryJson>) -> Unit>(
            { it[kUser] = it.getValue(kUser).copy(c = 12345) },                    // CRC mismatch
            { it[kUser] = it.getValue(kUser).copy(b = "!!notbase64") },            // bad base64
            { it[kUser] = it.getValue(kUser).copy(u = 1) },                        // u mismatch
            { it[kUser] = it.getValue(kUser).copy(o = DataFixtures.PEER.hex()) },  // origin mismatch
            { it[kPres] = it.getValue(kPres).copy(u = 5) },                        // PRESENCE without b, u != 1
            { it["0:" + DataHexes.RAW] = it.getValue(kUser) },                     // body of another key
            { it["0:8301ZZ"] = it.getValue(kPres) },                               // unparseable key
            { it[kTomb] = it.getValue(kTomb).copy(s = it.getValue(kUser).s) },     // duplicate seq
            { it[kTomb] = it.getValue(kTomb).copy(s = null) },                     // missing seq
            { it[kTomb] = it.getValue(kTomb).copy(b = Base64.getEncoder().encodeToString(byteArrayOf(0x10, 0x01))) }, // invalid body
        )
        for ((i, c) in cases.withIndex()) {
            val r = mutate(c)
            assertTrue("case $i", r.corrupt)
            assertTrue("case $i keeps the rest", r.ledger.size >= 2)
            val maxS = r.ledger.entriesBySeq().maxOf { it.seq }
            assertEquals("case $i nextSyncSeq", maxS + 1, r.ledger.nextSyncSeq)
        }
    }

    @Test
    fun aBadPeerRowIsDroppedAsCorruption() {
        val (st, _) = sample()
        val j = SyncStateJson.from(st, emptyMap()).copy(peers = mapOf("XYZ" to PeerJson("1269208CA2190C2D", 1, true, 0)))
        val r = SyncStateCodec.restore(j)
        assertTrue(r.corrupt)
        assertTrue(r.peers.isEmpty())
    }

    @Test
    fun nextSyncSeqAboveTheEntriesIsKept() {
        val (st, peers) = sample()
        val j = SyncStateJson.from(st, peers).copy(nextSyncSeq = 99, lastLocalStamp = DataFixtures.T0 + 77)
        val r = SyncStateCodec.restore(j)
        assertFalse(r.corrupt)
        assertEquals(99L, r.ledger.nextSyncSeq)
        assertEquals(DataFixtures.T0 + 77, r.ledger.lastLocalStamp)
        assertEquals(1, SyncStateCodec.restore(SyncStateJson.empty()).ledger.nextSyncSeq)
    }
}
