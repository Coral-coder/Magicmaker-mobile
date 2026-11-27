package com.magicmaker.android.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.Random

class EventOriginTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val self = DataFixtures.SELF
    private val epoch = 1_796_000_000L
    private val iphone = Bytes.fromHex("A1B2C3D4E5F60718")
    private val p1 = Bytes.fromHex(DataHexes.E90C)
    private val p2 = Bytes.fromHex(DataHexes.DUAL)
    private val addrA = EventOrigin.addrBytes("D0:C1:B2:A3:94:00")
    private val addrB = EventOrigin.addrBytes("d0:c1:b2:a3:94:01")

    private fun s(packet: Bytes, mono: Long, rssi: Int? = -60, wall: Long = DataFixtures.T0 + mono, fix: Boolean = true, addr: Bytes? = addrA, tagged: Boolean = false) =
        HeardSighting(packet, rssi, wall, mono, if (fix) 283852000 else null, if (fix) -815639000 else null, if (fix) 8 else null, addr, tagged)

    @Test
    fun theFirstSightingEmitsAtOnce() {
        val o = EventOrigin(self, epoch, 2000)
        val out = o.onSighting(s(p1, 100, rssi = -70))
        val e = out.single()
        assertEquals(self, e.origin)
        assertEquals(epoch, e.epoch)
        assertEquals(1L, e.seq)
        assertEquals(1, e.countOrDefault)
        assertEquals(-70, e.rssi)
        assertEquals(DataFixtures.T0 + 100, e.ts)
        assertEquals(283852000, e.lat)
        assertEquals(addrA, e.addr)
        assertTrue(e.seenBy.isEmpty())
        assertEquals(1L, o.seq)
        assertEquals(1100L, o.nextDueMs())
        assertEquals(listOf(RingId(epoch, 1)), o.ringIds())
        // The encoded EVT is valid (field ranges).
        assertEquals(e.encode(), SyncMsgs.decode(e.encode()).encode())
    }

    @Test
    fun theWindowEndCarriesCountMaxRssiAndTheLastSighting() {
        val o = EventOrigin(self, epoch, 2000)
        o.onSighting(s(p1, 0))
        assertTrue(o.onSighting(s(p1, 200, rssi = -80)).isEmpty())
        assertTrue(o.onSighting(s(p1, 500, rssi = -55, addr = addrB)).isEmpty())
        assertTrue(o.onSighting(s(p1, 900, rssi = -90, fix = false, addr = null, tagged = true)).isEmpty())
        assertTrue(o.tick(999).isEmpty())
        val e = o.tick(1000).single()
        assertEquals(2L, e.seq)
        assertEquals(3, e.count)
        assertEquals(-55, e.rssi)
        assertEquals(DataFixtures.T0 + 900, e.ts)
        assertEquals(283852000, e.lat) // the last fix (the last sighting had none)
        assertEquals(addrB, e.addr)    // the last address (the last sighting had none)
        assertEquals(SyncConst.EVT_FLAG_TAGGED, e.flags)
        assertNull(o.nextDueMs())
        // Next sighting opens a new window and emits at once.
        val n = o.onSighting(s(p1, 1500)).single()
        assertEquals(3L, n.seq)
        assertEquals(1, n.countOrDefault)
    }

    @Test
    fun aWindowWithNoRepeatsClosesSilently() {
        val o = EventOrigin(self, epoch, 2000)
        o.onSighting(s(p1, 0))
        assertTrue(o.tick(5000).isEmpty())
        assertEquals(0, o.openWindows())
    }

    @Test
    fun aSightingAfterAnUntickedWindowFlushesItFirst() {
        val o = EventOrigin(self, epoch, 2000)
        o.onSighting(s(p1, 0))
        o.onSighting(s(p1, 300))
        val out = o.onSighting(s(p1, 1200))
        assertEquals(listOf(2L, 3L), out.map { it.seq })
        assertEquals(1, out[0].count)
        assertEquals(DataFixtures.T0 + 300, out[0].ts)
        assertEquals(1, out[1].countOrDefault)
    }

    @Test
    fun windowsArePerPacket() {
        val o = EventOrigin(self, epoch, 2000)
        assertEquals(1, o.onSighting(s(p1, 0)).size)
        assertEquals(1, o.onSighting(s(p2, 10)).size)
        o.onSighting(s(p1, 20))
        o.onSighting(s(p2, 30))
        o.onSighting(s(p2, 40))
        val out = o.tick(1010)
        assertEquals(listOf(1, 2), out.map { it.count })
        assertEquals(listOf(p1, p2), out.map { it.packet })
    }

    @Test
    fun atMost256WindowsAndEvictingOneFlushesIt() {
        val o = EventOrigin(self, epoch, 5000)
        val first = Bytes.fromHex("8301E100E9000000")
        o.onSighting(s(first, 0))
        o.onSighting(s(first, 1)) // pending
        for (i in 1..EventOrigin.MAX_WINDOWS - 1) o.onSighting(s(Bytes.fromHex("8301E100E9%06X".format(i)), 2L + i))
        assertEquals(EventOrigin.MAX_WINDOWS, o.openWindows())
        val out = o.onSighting(s(Bytes.fromHex("8301E100E9FFFFFF"), 400))
        assertEquals(2, out.size)
        val flushed = out.single { it.packet == first }
        assertEquals(1, flushed.count)
        assertEquals(EventOrigin.MAX_WINDOWS, o.openWindows())
    }

    @Test
    fun theWideWindowLastsThreeSeconds() {
        val o = EventOrigin(self, epoch, 2000)
        o.setWideWindow(true)
        o.onSighting(s(p1, 0))
        assertEquals(3000L, o.nextDueMs())
        assertTrue(o.onSighting(s(p1, 2500)).isEmpty())
        assertEquals(1, o.tick(3000).single().count)
        o.setWideWindow(false)
        o.onSighting(s(p1, 4000))
        assertEquals(5000L, o.nextDueMs())
    }

    @Test
    fun aFixIsAllOrNone() {
        val o = EventOrigin(self, epoch, 2000)
        val e = o.onSighting(HeardSighting(p1, -60, DataFixtures.T0, 0, 283852000, -815639000, null, null, false)).single()
        assertNull(e.lat)
        assertNull(e.lon)
        assertNull(e.acc)
        assertNull(e.addr)
        assertNull(e.flags)
        assertNotNull(e.encode())
    }

    @Test
    fun theRingIsCappedOldestFirst() {
        val o = EventOrigin(self, epoch, 5)
        for (i in 1..7) o.originate(p1, DataFixtures.T0 + i, -60, 1, null, null, null, null, 0)
        assertEquals((3L..7L).map { RingId(epoch, it) }, o.ringIds())
        assertEquals(7L, o.seq)
    }

    @Test
    fun epochRuleAndPersistenceThroughTheDataModule() {
        val f = File(tmp.root, SyncIdentityFile.FILE_NAME)
        val id = SyncIdentityFile.load(f, DataFixtures.T0, Random(1))
        val m = SyncDataModule(id, DataHarness().sync)
        val a = m.startEventOrigin(1_796_000_000_400L, 2000)
        assertEquals(1_796_000_000L, a.epoch)
        assertEquals(id.deviceId, a.origin)
        a.onSighting(s(p1, 0))
        assertEquals(1L, a.seq)
        val b = m.startEventOrigin(1_796_000_000_900L, 2000) // a restart within the same second
        assertEquals(1_796_000_001L, b.epoch)
        assertEquals(0L, b.seq) // seq restarts per epoch
        assertEquals(1L, b.onSighting(s(p1, 0)).single().seq)
        assertEquals(1_796_000_001L, SyncIdentityFile.load(f, DataFixtures.T0).evtEpoch) // persisted before return
        assertTrue(m.newRoster() is DeviceRoster)
        assertTrue(m.newRuntimeEstimator() is RuntimeEstimator)
    }

    @Test
    fun catchUpFollowsTheReplayPlanVectors() {
        var checked = 0
        for (c in SyncTestData.vectors.arr("replayPlan").objects()) {
            val cur = c.long("curEpoch")
            val curSeq = c.long("curSeq")
            val ring = c.arr("ring").map { RingId(it.asJsonArray[0].asLong, it.asJsonArray[1].asLong) }
            // Only a ring this origin can actually hold: the current epoch, contiguous up to curSeq.
            val buildable = ring.all { it.epoch == cur } && ring.map { it.seq } == ((curSeq - ring.size + 1)..curSeq).toList() &&
                (ring.isNotEmpty() || curSeq == 0L)
            if (!buildable) continue
            val o = EventOrigin(self, cur, maxOf(1, ring.size))
            for (i in 1..curSeq) o.originate(p1, DataFixtures.T0 + i, -60, 1, null, null, null, null, if (i % 2 == 0L) 1 else 0)
            assertEquals(c.str("name"), ring, o.ringIds())
            val got = o.catchUp(iphone, c.long("epoch"), c.long("afterSeq"), 0)!!
            val exp = c.arr("expect").objects()
            assertEquals(c.str("name"), exp.size, got.size)
            for ((k, item) in got.withIndex()) {
                val x = exp[k]
                when (item) {
                    is CatchUpItem.Replay -> {
                        val r = x.obj("replay")
                        assertEquals(r.long("epoch"), item.evt.epoch)
                        assertEquals(r.long("seq"), item.evt.seq)
                        assertTrue(item.evt.isReplay)
                        assertTrue(item.evt.seenBy.isEmpty())
                        // The tagged bit of the stored event survives.
                        assertEquals(item.evt.seq % 2 == 0L, item.evt.flagsOrDefault and SyncConst.EVT_FLAG_TAGGED != 0)
                    }
                    is CatchUpItem.Gap -> {
                        val g = x.obj("gap")
                        assertEquals(EvtGap(self, g.long("epoch"), g.long("firstAvail"), g.long("lastAvail"), g.long("curEpoch"), iphone), item.gap)
                    }
                }
            }
            checked++
        }
        assertTrue("replayPlan vectors usable: $checked", checked >= 3)
    }

    @Test
    fun aRepeatedRequestWithinFiveSecondsIsSkipped() {
        val o = EventOrigin(self, epoch, 10)
        for (i in 1..5) o.originate(p1, DataFixtures.T0 + i, -60, 1, null, null, null, null, 0)
        assertEquals(3, o.catchUp(iphone, epoch, 2, 1000)!!.size)
        assertNull(o.catchUp(iphone, epoch, 2, 5999))
        assertNotNull(o.catchUp(iphone, epoch, 3, 5999))                  // a different afterSeq
        assertNotNull(o.catchUp(DataFixtures.PEER2, epoch, 2, 5999))      // a different requester
        assertEquals(3, o.catchUp(iphone, epoch, 2, 6000)!!.size)         // 5 s later
        // The ring keeps the original (non-replay) events.
        assertTrue(o.catchUp(iphone, epoch, 0, 20_000)!!.all { it is CatchUpItem.Replay })
        assertEquals(0, o.ringIds().size - 5)
    }

    @Test
    fun originateTakesTheNextSeqWithoutCoalescing() {
        val o = EventOrigin(self, epoch, 10)
        val a = o.originate(p1, DataFixtures.T0, -61, 4, 1, 2, 3, addrA, SyncConst.EVT_FLAG_TAGGED)
        val b = o.originate(p1, DataFixtures.T0, -61, 1, null, null, null, null, 0)
        assertEquals(1L, a.seq)
        assertEquals(2L, b.seq)
        assertEquals(4, a.count)
        assertEquals(1, a.lat)
        assertEquals(SyncConst.EVT_FLAG_TAGGED, a.flags)
        assertNull(b.flags)
        assertEquals(EventOrigin.addrBytes("D0C1B2A39400"), addrA)
        assertNull(EventOrigin.addrBytes("nope"))
        assertEquals(283852000, EventOrigin.e7(28.3852))
        assertNull(EventOrigin.e7(Double.NaN))
    }
}
