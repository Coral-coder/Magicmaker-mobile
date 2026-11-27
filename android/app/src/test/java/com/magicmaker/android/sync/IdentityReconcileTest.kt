package com.magicmaker.android.sync

import com.magicmaker.android.sync.IdentityReconcile.Base
import com.magicmaker.android.sync.IdentityReconcile.Facts
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.Random

/** Every row of the load decision table (plan §3.6, spec §5.2 (a)–(c)). */
class IdentityReconcileTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun facts(
        base: Base = Base.INTERNAL,
        present: Boolean = true,
        issued: Long = 10,
        next: Long = 10,
        corrupt: Boolean = false,
        migrated: Boolean = false,
    ) = Facts(base, present, issued, next, corrupt, migrated)

    @Test
    fun baseIsTheInternalFileWheneverItParses() {
        assertEquals(Base.INTERNAL, IdentityReconcile.chooseBase(internalParses = true, externalParses = true))
        assertEquals(Base.INTERNAL, IdentityReconcile.chooseBase(internalParses = true, externalParses = false))
        assertEquals(Base.EXTERNAL, IdentityReconcile.chooseBase(internalParses = false, externalParses = true))
        assertEquals(Base.NONE, IdentityReconcile.chooseBase(internalParses = false, externalParses = false))
    }

    @Test
    fun normalWhenTheStoreIsAtLeastIssued() {
        for (next in listOf(10L, 11L, 500L)) {
            val o = IdentityReconcile.decide(facts(issued = 10, next = next))
            assertFalse(o.newDbId)
            assertFalse(o.newDeviceId)
            assertFalse(o.resetPeers)
            assertNull(o.issuedSeq)
            assertEquals("normal", o.case)
        }
    }

    @Test
    fun firstP3LaunchMigratesWithoutNewIds() {
        val o = IdentityReconcile.decide(facts(issued = 0, next = 42, migrated = true))
        assertEquals("migrate", o.case)
        assertFalse(o.newDbId)
        assertFalse(o.resetPeers)
    }

    @Test
    fun caseCRollbackOrReplacedFileGetsANewDbId() {
        val o = IdentityReconcile.decide(facts(issued = 20, next = 12))
        assertEquals("c", o.case)
        assertTrue(o.newDbId)
        assertTrue(o.resetPeers)
        assertEquals(12L, o.issuedSeq)
        // A pre-P3 file put back after P3 issued seqs: migration starts at 1 -> also a rollback.
        val m = IdentityReconcile.decide(facts(issued = 20, next = 5, migrated = true))
        assertTrue(m.newDbId)
    }

    @Test
    fun caseAMissingIdentityResetsPeersAndKeepsTheLedger() {
        val o = IdentityReconcile.decide(facts(present = false, issued = 0, next = 30))
        assertEquals("a", o.case)
        assertTrue(o.resetPeers)
        assertEquals(30L, o.issuedSeq)
    }

    @Test
    fun externalBaseGetsANewDbId() {
        val o = IdentityReconcile.decide(facts(base = Base.EXTERNAL, issued = 0, next = 9))
        assertEquals("external", o.case)
        assertTrue(o.newDbId)
        assertTrue(o.resetPeers)
        assertEquals(9L, o.issuedSeq)
    }

    @Test
    fun aCorruptLedgerGetsANewDbId() {
        val o = IdentityReconcile.decide(facts(issued = 10, next = 10, corrupt = true))
        assertEquals("corrupt", o.case)
        assertTrue(o.newDbId)
        assertTrue(o.resetPeers)
    }

    @Test
    fun neitherFileParsesSeedsAndARaisedIssuedSeqIsARollback() {
        assertEquals("normal", IdentityReconcile.decide(facts(base = Base.NONE, issued = 0, next = 1)).case)
        assertEquals("normal", IdentityReconcile.decide(facts(base = Base.NONE, issued = 1, next = 1)).case)
        val o = IdentityReconcile.decide(facts(base = Base.NONE, issued = 50, next = 1))
        assertTrue(o.newDbId)
        assertEquals(1L, o.issuedSeq)
    }

    @Test
    fun externalDiffOnlyForAChangedNewerExternalCopyOverAnInternalBase() {
        assertTrue(IdentityReconcile.externalDiff(Base.INTERNAL, externalParses = true, externalChanged = true, externalNewer = true))
        assertFalse(IdentityReconcile.externalDiff(Base.INTERNAL, externalParses = true, externalChanged = true, externalNewer = false))
        assertFalse(IdentityReconcile.externalDiff(Base.INTERNAL, externalParses = true, externalChanged = false, externalNewer = true))
        assertFalse(IdentityReconcile.externalDiff(Base.INTERNAL, externalParses = false, externalChanged = true, externalNewer = true))
        assertFalse(IdentityReconcile.externalDiff(Base.EXTERNAL, externalParses = true, externalChanged = true, externalNewer = true))
        assertFalse(IdentityReconcile.externalDiff(Base.NONE, externalParses = true, externalChanged = true, externalNewer = true))
    }

    @Test
    fun applyResetsEveryPeerAndPersistsTheNewDbId() {
        val f = File(tmp.root, SyncIdentityFile.FILE_NAME)
        val id = SyncIdentityFile.load(f, DataFixtures.T0, Random(1))
        id.ensureIssued(20)
        val dev = id.deviceId
        val db = id.dbId
        val peerDb = Bytes.fromHex("9E859EDAA1D4E6A4")
        val peers = linkedMapOf(
            DataFixtures.PEER to StoredPeer(PeerState(peerDb, 77, true), 123L),
            DataFixtures.PEER2 to StoredPeer(PeerState(Bytes.ZERO8, 3, false), 0L),
        )
        val o = IdentityReconcile.decide(facts(issued = id.issuedSeq, next = 12))
        IdentityReconcile.apply(o, id, peers)
        assertEquals(dev, id.deviceId)
        assertNotEquals(db, id.dbId)
        assertEquals(12L, id.issuedSeq)
        val p = peers.getValue(DataFixtures.PEER)
        assertEquals(peerDb, p.state.dbId)
        assertEquals(0L, p.state.wm)
        assertFalse(p.state.excludeOk)
        assertEquals(123L, p.lastSyncMs)
        assertEquals(0L, peers.getValue(DataFixtures.PEER2).state.wm)
        val back = SyncIdentityFile.load(f, DataFixtures.T0, Random(2))
        assertEquals(id.dbId, back.dbId)
        assertEquals(12L, back.issuedSeq)
    }

    @Test
    fun applyOfANormalOutcomeChangesNothing() {
        val f = File(tmp.root, SyncIdentityFile.FILE_NAME)
        val id = SyncIdentityFile.load(f, DataFixtures.T0, Random(1))
        val db = id.dbId
        val peers = linkedMapOf(DataFixtures.PEER to StoredPeer(PeerState(Bytes.ZERO8, 5, true), 1L))
        IdentityReconcile.apply(IdentityReconcile.decide(facts(issued = 0, next = 3)), id, peers)
        assertEquals(db, id.dbId)
        assertEquals(5L, peers.getValue(DataFixtures.PEER).state.wm)
        assertTrue(peers.getValue(DataFixtures.PEER).state.excludeOk)
    }

    @Test
    fun aMissingIdentityFileProducesFreshIdsThenCaseA() {
        val f = File(tmp.root, SyncIdentityFile.FILE_NAME)
        val id = SyncIdentityFile.load(f, DataFixtures.T0, Random(5))
        assertFalse(id.wasPresent)
        val peers = linkedMapOf(DataFixtures.PEER to StoredPeer(PeerState(Bytes.ZERO8, 5, true), 1L))
        val o = IdentityReconcile.decide(facts(present = id.wasPresent, issued = id.issuedSeq, next = 8))
        IdentityReconcile.apply(o, id, peers)
        assertEquals(8L, id.issuedSeq)
        assertEquals(0L, peers.getValue(DataFixtures.PEER).state.wm)
    }

    @Test
    fun aCorruptLedgerKeepsValidEntriesWithNextSeqAboveThem() {
        val st = LedgerStore()
        st.localLearn(DataFixtures.key(DataHexes.DUAL).packet)
        st.localLearn(DataFixtures.key(DataHexes.E90C).packet)
        val json = SyncStateJson.from(st, emptyMap())
        val bad = json.ledger!!.toMutableMap()
        val k = LibraryRows.libKeyString(DataHexes.DUAL)
        bad[k] = bad.getValue(k).copy(c = 1)
        val r = SyncStateCodec.restore(json.copy(ledger = bad, nextSyncSeq = 40))
        assertTrue(r.corrupt)
        assertEquals(1, r.ledger.size)
        assertEquals(3L, r.ledger.nextSyncSeq) // max(s) + 1 with s = 2
        val o = IdentityReconcile.decide(facts(issued = 40, next = r.ledger.nextSyncSeq, corrupt = r.corrupt))
        assertTrue(o.newDbId)
        assertEquals(3L, o.issuedSeq)
    }
}
