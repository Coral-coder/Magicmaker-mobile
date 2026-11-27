package com.magicmaker.android.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceRosterTest {
    private val iphone = Bytes.fromHex("A1B2C3D4E5F60718")
    private val hub = Bytes.fromHex("0100AABBCCDDEEFF")

    private fun hb(device: Bytes, boot: Int, seq: Long, hops: Int = 0, batt: Int = 80) = Hb(
        deviceId = device, kind = if (device == hub) 1 else 3, bootId = boot, hbSeq = seq, ts = DataFixtures.T0, uptimeS = 10,
        battPct = batt, hops = hops, feedHigh = 5, dbId = Bytes.fromHex("1269208CA2190C2D"), records = 12,
    )

    @Test
    fun theKeepLatestRule() {
        val r = DeviceRoster()
        assertTrue(r.onHb(hb(iphone, 1, 10), iphone, 1000))
        assertFalse(r.onHb(hb(iphone, 1, 9, batt = 10), iphone, 2000))   // older hbSeq
        assertEquals(80, r.get(iphone)!!.hb.battPct)
        assertFalse(r.onHb(hb(iphone, 1, 10), iphone, 2500))             // same version
        assertTrue(r.onHb(hb(iphone, 1, 11, batt = 70), iphone, 3000))
        assertEquals(70, r.get(iphone)!!.hb.battPct)
        assertTrue(r.onHb(hb(iphone, 2, 1, batt = 60), iphone, 4000))    // new bootId, lower seq
        assertEquals(60, r.get(iphone)!!.hb.battPct)
    }

    @Test
    fun directAndViaTimes() {
        val r = DeviceRoster()
        r.onHb(hb(iphone, 1, 10), iphone, 1000)                        // direct
        r.onHb(hb(iphone, 1, 10, hops = 1), hub, 1500)                 // the hub forwards the same HB
        val e = r.get(iphone)!!
        assertEquals(1500L, e.lastAnyMs)
        assertEquals(1000L, e.lastDirectMs)
        assertEquals(mapOf(hub to 1500L), e.lastViaMs)
        // A copy that does not replace still updates the path times.
        assertFalse(r.onHb(hb(iphone, 1, 9, hops = 1), hub, 2000))
        assertEquals(2000L, r.get(iphone)!!.lastViaMs[hub])
        assertEquals(2000L, r.get(iphone)!!.lastAnyMs)
        assertFalse(r.onHb(hb(iphone, 1, 9), iphone, 2100))
        assertEquals(2100L, r.get(iphone)!!.lastDirectMs)
    }

    @Test
    fun aViaOnlyDeviceHasNoDirectTime() {
        val r = DeviceRoster()
        r.onHb(hb(hub, 7, 1, hops = 1), iphone, 500)
        val e = r.get(hub)!!
        assertNull(e.lastDirectMs)
        assertEquals(mapOf(iphone to 500L), e.lastViaMs)
        // hops 0 but relayed by someone else is not direct.
        r.onHb(hb(hub, 7, 2, hops = 0), iphone, 600)
        assertNull(r.get(hub)!!.lastDirectMs)
    }

    @Test
    fun entriesAreSnapshotsAndForgetRemoves() {
        val r = DeviceRoster()
        r.onHb(hb(iphone, 1, 1), iphone, 1)
        r.onHb(hb(hub, 1, 1), hub, 2)
        val list = r.entries()
        assertEquals(listOf(iphone, hub), list.map { it.hb.deviceId })
        r.onHb(hb(iphone, 1, 2, hops = 1), hub, 9)
        assertEquals(1L, list[0].lastAnyMs)
        assertTrue(list[0].lastViaMs.isEmpty())
        r.forget(iphone)
        assertNull(r.get(iphone))
        assertEquals(listOf(hub), r.entries().map { it.hb.deviceId })
    }
}
