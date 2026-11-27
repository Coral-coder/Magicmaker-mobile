package com.magicmaker.android.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

class LedgerStoreTest {
    private val t0 = DataFixtures.T0
    private val peer = DataFixtures.PEER

    private fun lib(i: Int): String = "8301E100E9%02X".format(i)

    private fun pull(since: Long, limit: Int? = null, maxBytes: Int? = null, exclude: Int? = null) =
        Pull(7, since, limit, maxBytes, Bytes.fromHex("1269208CA2190C2D"), exclude)

    @Test
    fun theFeedIndexHoldsOnlyCurrentSeqs() {
        val st = LedgerStore()
        st.localLearn(DataFixtures.key(lib(1)).packet)                       // s1
        st.localLearn(DataFixtures.key(lib(2)).packet)                       // s2
        st.applyRemote(DataFixtures.userBody(lib(1), t0, "One", 1, 3), peer, t0) // s3 replaces s1
        st.localEdit(RecordClass.TOMBSTONE, DataFixtures.key(lib(2)), t0, DataFixtures.SELF) // s4 replaces s2
        assertEquals(mapOf(3L to "0:${lib(1)}", 4L to "0:${lib(2)}"), st.feedIndex())
        assertEquals(listOf(3L, 4L), st.entriesBySeq().map { it.seq })
        assertEquals(5L, st.nextSyncSeq)
        // A duplicate / stale apply does not move anything.
        assertEquals(ApplyStatus.DUPLICATE, st.applyRemote(DataFixtures.userBody(lib(1), t0, "One", 1, 3), peer, t0).status)
        assertEquals(ApplyStatus.STALE, st.applyRemote(DataFixtures.userBody(lib(1), t0 - 1, "Old", 1, 3), peer, t0).status)
        assertEquals(mapOf(3L to "0:${lib(1)}", 4L to "0:${lib(2)}"), st.feedIndex())
    }

    @Test
    fun pagesNeverServeAboveDurableHighAndReportIt() {
        val st = LedgerStore()
        for (i in 1..6) st.localLearn(DataFixtures.key(lib(i)).packet)
        val r = st.servePage(pull(0), excludeOk = false, puller = peer, durableHigh = 4)
        assertEquals(listOf(1L, 2L, 3L, 4L), r.recSeqs)
        assertEquals(4L, r.pageEnd.feedHigh)
        assertEquals(4L, r.pageEnd.scannedTo)
        assertEquals(0, r.pageEnd.more)
        val none = st.servePage(pull(0), false, peer, durableHigh = 0)
        assertTrue(none.recs.isEmpty())
        assertEquals(0L, none.pageEnd.feedHigh)
        val beyond = st.servePage(pull(9), false, peer, durableHigh = 4)
        assertTrue(beyond.recs.isEmpty())
        assertEquals(9L, beyond.pageEnd.scannedTo)
        val limited = st.servePage(pull(1, limit = 2), false, peer, durableHigh = 6)
        assertEquals(listOf(2L, 3L), limited.recSeqs)
        assertEquals(1, limited.pageEnd.more)
    }

    @Test
    fun exclusionByOriginAndSyncFrom() {
        val st = LedgerStore()
        st.applyRemote(DataFixtures.userBody(lib(1), t0, "From peer", 1, 3, origin = peer), DataFixtures.PEER2, t0) // origin = puller
        st.applyRemote(DataFixtures.presenceBody(lib(2)), peer, t0)                                                  // syncFrom = puller
        st.localLearn(DataFixtures.key(lib(3)).packet)
        val on = st.servePage(pull(0, exclude = 1), excludeOk = true, puller = peer, durableHigh = 3)
        assertEquals(listOf(3L), on.recSeqs)
        assertEquals(3L, on.pageEnd.scannedTo)
        val notOk = st.servePage(pull(0, exclude = 1), excludeOk = false, puller = peer, durableHigh = 3)
        assertEquals(listOf(1L, 2L, 3L), notOk.recSeqs)
        val notAsked = st.servePage(pull(0), excludeOk = true, puller = peer, durableHigh = 3)
        assertEquals(listOf(1L, 2L, 3L), notAsked.recSeqs)
    }

    @Test
    fun tombstoneCapEvictionUpdatesTheIndex() {
        val st = LedgerStore(tombstoneCap = 2)
        for (i in 1..3) st.applyRemote(DataFixtures.tombstoneBody(lib(i), t0 + i), peer, t0)
        assertEquals(2, st.tombstoneCount())
        assertNull(st.get("0:${lib(1)}")) // the smallest version went
        assertEquals(mapOf(2L to "0:${lib(2)}", 3L to "0:${lib(3)}"), st.feedIndex())
        // A local delete evicted at once (it is the smallest version) leaves no index entry.
        val r = st.localEdit(RecordClass.TOMBSTONE, DataFixtures.key(lib(9)), 1_600_000_000_000L, DataFixtures.SELF)
        assertNull(r.entry)
        assertEquals(mapOf(2L to "0:${lib(2)}", 3L to "0:${lib(3)}"), st.feedIndex())
        assertEquals(st.size, st.feedIndex().size)
    }

    @Test
    fun servePageEqualsTheP1RouterOverTheSameEntries() {
        val rnd = Random(42)
        val st = LedgerStore()
        for (n in 0 until 300) {
            val hex = lib(rnd.nextInt(40))
            when (rnd.nextInt(4)) {
                0 -> st.localLearn(DataFixtures.key(hex).packet)
                1 -> st.applyRemote(DataFixtures.userBody(hex, t0 + n, "L$n", 2, 3, origin = if (rnd.nextBoolean()) peer else DataFixtures.PEER2), peer, t0 + n)
                2 -> st.localEdit(RecordClass.USER, DataFixtures.key(hex), t0 + n, DataFixtures.SELF, label = "Me$n", category = 1, place = 3)
                else -> st.applyRemote(DataFixtures.tombstoneBody(hex, t0 + n, origin = DataFixtures.PEER2), DataFixtures.PEER2, t0 + n)
            }
        }
        val all = st.entriesByKey()
        assertEquals(st.size, st.feedIndex().size)
        for (k in 0 until 50) {
            val durable = rnd.nextInt(st.nextSyncSeq.toInt() + 2).toLong()
            val p = pull(rnd.nextInt(st.nextSyncSeq.toInt()).toLong(), limit = 1 + rnd.nextInt(30), maxBytes = 256 + rnd.nextInt(2000), exclude = rnd.nextInt(2))
            val ok = rnd.nextBoolean()
            val a = st.servePage(p, ok, peer, durable)
            val b = SyncRouting.servePage(all, durable, p, ok, peer)
            assertEquals(b.recSeqs, a.recSeqs)
            assertEquals(b.recs, a.recs)
            assertEquals(b.pageEnd, a.pageEnd)
        }
    }

    @Test
    fun theSharedPagesVectors() {
        var n = 0
        for (c in SyncTestData.vectors.arr("pages").objects()) {
            val name = c.str("name")
            val entries = c.arr("entries").objects().map { LedgerEntry.restore(it.hex("bodyHex"), it.long("seq"), it.hexOrNull("syncFrom")) }
            val st = LedgerStore()
            st.restore(entries, (entries.maxOfOrNull { it.seq } ?: 0) + 1, 0)
            val p = SyncMsgs.decode(c.hex("pullHex")) as Pull
            val r = st.servePage(p, c.bool("excludeOk"), c.hex("puller"), c.long("durableHigh"))
            val exp = c.obj("expect")
            assertEquals(name, exp.arr("recSeqs").map { it.asLong }, r.recSeqs)
            assertEquals(name, exp.arr("recs").map { it.asString }, r.recs.map { it.hex() })
            assertEquals(name, exp.str("pageEndHex"), r.pageEnd.encode().hex())
            n++
        }
        assertTrue(n >= 10)
    }

    @Test
    fun restoreAndInsertLocal() {
        val st = LedgerStore()
        val body = RecordBody(DataFixtures.key(lib(1)), SyncConst.U_LEGACY_ANDROID, DataFixtures.SELF, SyncConst.FLAG_USER_EDITED,
            "Legacy", 1, null, null, 3)
        val e = st.insertLocal(body)!!
        assertEquals(1L, e.seq)
        assertNull(e.syncFrom)
        assertNull(st.insertLocal(body)) // already has an entry
        assertEquals(2L, st.nextSyncSeq)
        val copy = LedgerStore()
        copy.restore(st.entriesBySeq(), 10, 55)
        assertEquals(10L, copy.nextSyncSeq)
        assertEquals(55L, copy.lastLocalStamp)
        assertEquals(st.feedIndex(), copy.feedIndex())
        // A local edit after legacy u = 2 is stamped by the clock.
        val r = copy.localEdit(RecordClass.USER, DataFixtures.key(lib(1)), t0, DataFixtures.SELF, label = "New", category = 1, place = 3)
        assertEquals(t0, r.body.updatedAt)
        assertEquals(10L, r.entry!!.seq)
        assertEquals(mapOf(10L to "0:${lib(1)}"), copy.feedIndex())
    }
}
