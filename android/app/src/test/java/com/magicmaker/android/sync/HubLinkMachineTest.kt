package com.magicmaker.android.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// HubLinkMachine (docs/SYNC_P3_ANDROID_PLAN.md §5.4, §10.2), GattServerLinks (§5.5) and
// RelayAdvPolicy (§5.5).

class HubLinkMachineTest {
    private val hub = "AA:BB:CC:DD:EE:01"
    private val other = "AA:BB:CC:DD:EE:02"

    private fun ident() = FakeIdentity(Bytes.fromHex("4A1D0B5E77C2903F"), Bytes.fromHex("1269208CA2190C2D"))

    /** Drive a machine from hubSeen to LinkUp. */
    private fun upTo(m: HubLinkMachine, now: Long, address: String = hub): List<HubCmd> {
        val out = ArrayList<HubCmd>()
        out += m.hubSeen(address, "MM_ESP", -50, now)
        out += m.onConnected(now + 100)
        out += m.onMtu(247, true, now + 200)
        out += m.onServices(true, true, now + 300)
        out += m.onNotifyEnabled(true, now + 400)
        return out
    }

    @Test
    fun setupOrderMtuDiscoverNotifyThenLinkUp() {
        val m = HubLinkMachine(ident())
        assertEquals(emptyList<HubCmd>(), m.start(0))
        val cmds = upTo(m, 1000)
        assertEquals(
            listOf(HubCmd.Connect(hub, false), HubCmd.RequestMtu, HubCmd.Discover, HubCmd.EnableNotify, HubCmd.LinkUp(hub, 247)),
            cmds,
        )
        assertTrue(m.isUp)
    }

    @Test
    fun firmwareWithoutSyncIsDroppedAndNotProbedFor30Min() {
        val m = HubLinkMachine(ident())
        m.start(0)
        m.hubSeen(hub, "MM_ESP", -50, 0)
        m.onConnected(10)
        m.onMtu(247, true, 20)
        assertEquals(listOf<HubCmd>(HubCmd.Close("no_sync")), m.onServices(false, true, 30))
        assertTrue(m.info(40).noSync)
        assertEquals(emptyList<HubCmd>(), m.hubSeen(hub, "MM_ESP", -50, 60_000))
        assertEquals(emptyList<HubCmd>(), m.tick(29 * 60_000L))
        assertEquals(listOf<HubCmd>(HubCmd.Connect(hub, false)), m.hubSeen(hub, "MM_ESP", -50, 31 * 60_000L))
    }

    @Test
    fun failuresBackOff1_2_5_10_30() {
        val m = HubLinkMachine(ident())
        m.start(0)
        var now = 0L
        val waits = ArrayList<Long>()
        repeat(6) {
            m.hubSeen(hub, "MM_ESP", -50, now)
            assertEquals(HubPhase.CONNECTING, m.phase)
            val out = m.onDisconnected(133, now + 10)
            assertTrue(out.contains(HubCmd.Close("status 133")))
            waits.add(m.info(now + 10).nextAttemptInMs)
            now += 10 + waits.last()
        }
        assertEquals(listOf(1_000L, 2_000L, 5_000L, 10_000L, 30_000L, 30_000L), waits)
        // A working session resets it.
        upTo(m, now)
        m.onAuthed()
        m.onDisconnected(0, now + 1000)
        assertEquals(1_000L, m.info(now + 1000).nextAttemptInMs)
    }

    @Test
    fun theSessionRetryFloorHolds() {
        val m = HubLinkMachine(ident())
        m.start(0)
        upTo(m, 0)
        m.onAuthed()
        val out = m.onLocalClose("page_timeout", 30_000, 5_000)
        assertEquals(listOf(HubCmd.LinkDown(hub), HubCmd.Close("page_timeout")), out)
        assertEquals(emptyList<HubCmd>(), m.hubSeen(hub, "MM_ESP", -50, 20_000))
        assertEquals(listOf<HubCmd>(HubCmd.Connect(hub, false)), m.hubSeen(hub, "MM_ESP", -50, 35_001))
    }

    @Test
    fun foreignHubIsForgottenAndNeverAutoConnected() {
        val id = ident()
        val m = HubLinkMachine(id)
        m.start(0)
        upTo(m, 0)
        m.onAuthed()
        assertEquals(hub, id.hubAddress)
        // The link stays up until the session's own disconnect, so its ERR AUTH leaves first.
        assertEquals(emptyList<HubCmd>(), m.onForeign(1_000))
        assertTrue(m.isUp)
        assertNull(id.hubAddress)
        assertTrue(id.isForeign(hub))
        assertEquals(listOf(HubCmd.LinkDown(hub), HubCmd.Close("foreign")), m.onLocalClose("foreign", null, 1_050))
        assertEquals("other group", m.info(1_050).lastError)
        assertEquals(emptyList<HubCmd>(), m.hubSeen(hub, "MM_ESP", -40, 100_000))
        // Another hub is still found.
        assertEquals(listOf<HubCmd>(HubCmd.Connect(other, false)), m.hubSeen(other, "MM_ESP", -70, 100_100))
    }

    @Test
    fun firstAuthedRemembersTheHubThenAutoConnectUntilHeard() {
        val id = ident()
        val m = HubLinkMachine(id)
        m.start(0)
        upTo(m, 0)
        assertNull(id.hubAddress)
        m.onAuthed()
        assertEquals(hub, id.hubAddress)
        m.onDisconnected(8, 10_000)
        // Not heard lately: a pending autoConnect, no timeout.
        assertEquals(listOf<HubCmd>(HubCmd.Connect(hub, true)), m.tick(40_000))
        assertTrue(m.info(40_000).autoPending)
        assertEquals(emptyList<HubCmd>(), m.tick(500_000))
        // Heard: switch to a direct attempt.
        assertEquals(listOf(HubCmd.Close("direct"), HubCmd.Connect(hub, false)), m.hubSeen(hub, "MM_ESP", -60, 500_100))
        // Other hubs are ignored while one is known.
        m.onDisconnected(133, 500_200)
        assertEquals(listOf<HubCmd>(HubCmd.Connect(hub, true)), m.hubSeen(other, "MM_ESP", -30, 600_000))
    }

    @Test
    fun aStuckOperationTimesOutAfter5s() {
        val m = HubLinkMachine(ident())
        m.start(0)
        m.hubSeen(hub, "MM_ESP", -50, 0)
        m.onConnected(100)
        assertEquals(emptyList<HubCmd>(), m.tick(5_000))
        assertEquals(listOf<HubCmd>(HubCmd.Close("timeout mtu")), m.tick(5_100))
        assertEquals(HubPhase.IDLE, m.phase)
    }

    @Test
    fun strongestFreshCandidateWinsAndRelayNamesAreFiltered() {
        val m = HubLinkMachine(ident())
        assertTrue(HubLinkMachine.isHubName("MM_ESP"))
        assertTrue(HubLinkMachine.isHubName("MagicMaker-ESP32"))
        assertFalse(HubLinkMachine.isHubName("MM_AND"))
        assertFalse(HubLinkMachine.isHubName(null))
        m.start(0)
        m.stop()
        assertEquals(emptyList<HubCmd>(), m.hubSeen(other, "MM_ESP", -80, 0)) // off: only remembered
        assertEquals(emptyList<HubCmd>(), m.hubSeen(hub, "MM_ESP", -40, 10))
        assertEquals(listOf<HubCmd>(HubCmd.Connect(hub, false)), m.start(20))
        // A stale advert is not a candidate.
        val m2 = HubLinkMachine(ident())
        m2.hubSeen(hub, "MM_ESP", -40, 0)
        assertEquals(emptyList<HubCmd>(), m2.start(HubLinkMachine.SEEN_FRESH_MS + 1))
    }

    // ---- GattServerLinks -----------------------------------------------------------------------

    @Test
    fun serverLinksFollowTheCccd() {
        val g = GattServerLinks()
        val a = "11:22:33:44:55:66"
        assertEquals(emptyList<ServerLinkEvent>(), g.onConnected(a))
        assertEquals(1, g.connectedCount())
        assertEquals(emptyList<ServerLinkEvent>(), g.onWrite(a, byteArrayOf(1, 2, 3))) // CCCD off: dropped
        g.onMtu(a, 185)
        val up = g.onCccd(a, byteArrayOf(1, 0))
        assertEquals(listOf<ServerLinkEvent>(ServerLinkEvent.Up(a, "ios:$a", 185)), up)
        assertEquals(listOf<ServerLinkEvent>(ServerLinkEvent.Mtu("ios:$a", 247)), g.onMtu(a, 247))
        val w = g.onWrite(a, byteArrayOf(7)) as List<*>
        assertEquals(1, w.size)
        assertEquals(listOf<ServerLinkEvent>(ServerLinkEvent.Sent("ios:$a")), g.onNotificationSent(a))
        assertEquals(1, g.cccdValue(a)[0].toInt())
        assertEquals(listOf<ServerLinkEvent>(ServerLinkEvent.Down(a, "ios:$a")), g.onCccd(a, byteArrayOf(0, 0)))
        assertEquals(emptyList<ServerLinkEvent>(), g.onDisconnected(a))
        assertEquals(0, g.connectedCount())
    }

    @Test
    fun serverLinksMtuBeforeCccdDefaultsTo23AndCentralsAreIsolated() {
        val g = GattServerLinks()
        val a = "11:22:33:44:55:66"
        val b = "11:22:33:44:55:77"
        g.onConnected(a)
        g.onConnected(b)
        assertEquals(listOf<ServerLinkEvent>(ServerLinkEvent.Up(a, "ios:$a", 23)), g.onCccd(a, byteArrayOf(1, 0)))
        g.onMtu(b, 100)
        assertEquals(listOf<ServerLinkEvent>(ServerLinkEvent.Up(b, "ios:$b", 100)), g.onCccd(b, byteArrayOf(1, 0)))
        assertEquals(listOf<ServerLinkEvent>(ServerLinkEvent.Down(a, "ios:$a")), g.onDisconnected(a))
        assertEquals("ios:$b", g.linkFor(b))
        assertEquals(listOf<ServerLinkEvent>(ServerLinkEvent.Down(b, "ios:$b")), g.clear())
    }

    // ---- RelayAdvPolicy ------------------------------------------------------------------------

    @Test
    fun advertisingPolicy() {
        val p = RelayAdvPolicy()
        assertFalse(p.spec(0).on)
        p.start(0)
        val s0 = p.spec(0)
        assertTrue(s0.on && s0.lowLatency)
        assertEquals("MM_AND", String(s0.tag.toByteArray().copyOf(6), Charsets.US_ASCII))
        assertEquals(Bytes.zero(2), s0.tag.slice(6))
        assertEquals(60_000L, p.nextChangeMs(0))
        assertFalse(p.spec(60_000).lowLatency)
        assertTrue(p.spec(60_000).on)
        // Off while connected; a disconnect restarts the fast period.
        p.setConnected(1, 70_000)
        assertFalse(p.spec(70_000).on)
        p.setPaused(true)
        p.setPaused(false)
        assertFalse("resume never re-enables while connected", p.spec(70_001).on)
        p.setConnected(0, 80_000)
        assertTrue(p.spec(80_000).lowLatency)
        p.setPaused(true)
        assertFalse(p.spec(80_001).on)
        p.setPaused(false)
        assertTrue(p.spec(80_002).on)
        // Group tag and the ADV budget.
        p.setGroup(Bytes.fromHex("2A2F4A688371E7EF"))
        val tag = p.spec(80_003).tag
        assertEquals(Bytes.fromHex("4D4D5F414E442A2F"), tag)
        assertEquals(23, RelayAdvPolicy.primaryAdvBytes(tag))
        assertTrue(RelayAdvPolicy.primaryAdvBytes(tag) <= 31)
        p.stop()
        assertFalse(p.spec(90_000).on)
    }
}
