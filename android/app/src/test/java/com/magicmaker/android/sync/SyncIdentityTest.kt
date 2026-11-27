package com.magicmaker.android.sync

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

class SyncIdentityTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun file() = File(tmp.root, SyncIdentityFile.FILE_NAME)

    private fun load(now: Long = DataFixtures.T0, rng: Random = Random(7)) = SyncIdentityFile.load(file(), now, rng)

    @Test
    fun freshIdentityHasNonZeroEightByteIdsAndIsWritten() {
        val id = load()
        assertFalse(id.wasPresent)
        assertEquals(8, id.deviceId.size)
        assertEquals(8, id.dbId.size)
        assertFalse(id.deviceId.isAllZero())
        assertFalse(id.dbId.isAllZero())
        assertNotEquals(id.deviceId, id.dbId)
        assertEquals(0L, id.issuedSeq)
        assertEquals(0L, id.evtEpoch)
        assertNull(id.group)
        assertEquals(DataFixtures.T0, id.createdMs)
        assertTrue(file().isFile)
    }

    @Test
    fun reloadGivesTheSameIdentity() {
        val a = load()
        val b = load(rng = Random(99))
        assertTrue(b.wasPresent)
        assertEquals(a.deviceId, b.deviceId)
        assertEquals(a.dbId, b.dbId)
    }

    @Test
    fun ensureIssuedIsMonotonicAndOnDisk() {
        val id = load()
        id.ensureIssued(5)
        assertEquals(5L, id.issuedSeq)
        id.ensureIssued(3)
        assertEquals(5L, id.issuedSeq)
        assertEquals(5L, load().issuedSeq)
        id.noteWritten(9)
        assertEquals(9L, load().issuedSeq)
        // No write when it does not grow: a deleted file is not recreated.
        file().delete()
        id.ensureIssued(9)
        id.ensureIssued(2)
        assertFalse(file().exists())
        id.ensureIssued(10)
        assertTrue(file().exists())
        assertEquals(10L, load().issuedSeq)
    }

    @Test
    fun groupRoundTripAndConsistency() {
        val id = load()
        val g = SyncIdentityFile.newGroup(Random(3))
        assertTrue(g.isConsistent())
        id.setGroup(g)
        val back = load().group!!
        assertEquals(g.groupId, back.groupId)
        assertEquals(g.groupKey, back.groupKey)
        assertTrue(back.isConsistent())
        id.setGroup(null)
        assertNull(load().group)
    }

    @Test(expected = IllegalArgumentException::class)
    fun anInconsistentGroupIsRefused() {
        load().setGroup(SyncGroup(Bytes.fromHex("0102030405060708"), Bytes.zero(16)))
    }

    @Test
    fun hubAddressAndForeignCap() {
        val id = load()
        id.setHubAddress("aa:bb:cc:dd:ee:ff")
        assertEquals("AA:BB:CC:DD:EE:FF", id.hubAddress)
        for (i in 0 until 20) id.markForeign("11:22:33:44:55:%02x".format(i))
        val list = id.foreignList()
        assertEquals(SyncIdentityFile.FOREIGN_MAX, list.size)
        assertFalse(id.isForeign("11:22:33:44:55:00")) // oldest dropped
        assertTrue(id.isForeign("11:22:33:44:55:13"))
        assertTrue(id.isForeign("11:22:33:44:55:13".uppercase()))
        id.markForeign("11:22:33:44:55:05") // re-marking moves it to the newest end
        assertEquals("11:22:33:44:55:05", load().foreignList().last())
        val back = load()
        assertEquals("AA:BB:CC:DD:EE:FF", back.hubAddress)
        id.setHubAddress(null)
        assertNull(load().hubAddress)
    }

    @Test
    fun aGroupChangeClearsTheForeignHubs() {
        // The iPhone rekeyed while this phone was away: the user's own hub now reads FOREIGN. After
        // "Leave sync group" (or a JOIN into the new group) it must be tried again, or nothing can
        // ever regroup this phone through the hub.
        val id = load()
        val g1 = SyncIdentityFile.newGroup(Random(11))
        val g2 = SyncIdentityFile.newGroup(Random(12))
        id.setGroup(g1)
        id.markForeign("AA:BB:CC:DD:EE:01")
        id.setGroup(g1) // the same group again (a JOIN copy): the list stays
        assertTrue(id.isForeign("AA:BB:CC:DD:EE:01"))
        id.setGroup(null)
        assertFalse(id.isForeign("AA:BB:CC:DD:EE:01"))
        assertTrue(load().foreignList().isEmpty())
        id.markForeign("AA:BB:CC:DD:EE:02")
        id.setGroup(g2)
        assertFalse(load().isForeign("AA:BB:CC:DD:EE:02"))
        assertEquals(g2.groupId, load().group!!.groupId)
    }

    @Test
    fun aCorruptOrInvalidFileCountsAsMissing() {
        val first = load()
        file().writeText("{not json")
        val a = load(rng = Random(11))
        assertFalse(a.wasPresent)
        assertNotEquals(first.deviceId, a.deviceId)

        file().writeText("""{"v":1,"deviceId":"0000000000000000","dbId":"1269208CA2190C2D"}""")
        assertFalse(load().wasPresent)

        file().writeText("""{"v":2,"deviceId":"4A1D0B5E77C2903F","dbId":"1269208CA2190C2D"}""")
        assertFalse(load().wasPresent)

        // groupId that does not match the key.
        file().writeText(
            """{"v":1,"deviceId":"4A1D0B5E77C2903F","dbId":"1269208CA2190C2D","groupId":"0102030405060708",""" +
                """"groupKey":"00000000000000000000000000000000"}""",
        )
        assertFalse(load().wasPresent)

        file().writeText("""{"v":1,"deviceId":"4A1D0B5E77C2903F","dbId":"1269208CA2190C2D","issuedSeq":4}""")
        val ok = load()
        assertTrue(ok.wasPresent)
        assertEquals(DataFixtures.SELF, ok.deviceId)
        assertEquals(4L, ok.issuedSeq)
    }

    @Test
    fun startEpochIsMaxOfNowAndLastPlusOneAndPersisted() {
        val id = load()
        assertEquals(1_796_000_000L, id.startEpoch(1_796_000_000_500L))
        assertEquals(1_796_000_001L, id.startEpoch(1_796_000_000_900L)) // same second: last + 1
        assertEquals(1_796_000_001L, load().evtEpoch)
        assertEquals(1_796_000_500L, id.startEpoch(1_796_000_500_000L))
        // A clock that went backwards still moves forward.
        assertEquals(1_796_000_501L, load().startEpoch(1_700_000_000_000L))
    }

    @Test
    fun randomIdsAreRegeneratedWhileAllZero() {
        val rng = object : Random() {
            var calls = 0
            override fun nextBytes(bytes: ByteArray) {
                calls++
                if (calls > 2) bytes.fill(0x5A)
            }
        }
        val id = SyncIdentityFile.randomId(rng)
        assertEquals(Bytes.fromHex("5A5A5A5A5A5A5A5A"), id)
        assertEquals(3, rng.calls)
    }

    @Test
    fun reconcileWritesNewIdsAtOnce() {
        val id = load()
        val dev = id.deviceId
        val db = id.dbId
        id.reconcile(newDeviceId = false, newDbId = true, issuedSeq = 7)
        assertEquals(dev, id.deviceId)
        assertNotEquals(db, id.dbId)
        val back = load()
        assertEquals(id.dbId, back.dbId)
        assertEquals(7L, back.issuedSeq)
    }
}
