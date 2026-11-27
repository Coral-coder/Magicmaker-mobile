package com.magicmaker.android.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

// The SYNC / DEVICES view (docs/SYNC_P3_ANDROID_PLAN.md §5.8, §10.2): badge rules in order, path
// tokens, LOST at 10 min, the ESP32 advert fallback (AIR), UPDATE APP after 10 s linked without
// SYNC, header, notification token, text lines; plus the view of a real three-node run.

class SyncStatusBuilderTest {
    private val self = Bytes.fromHex("4A1D0B5E77C2903F")
    private val ios = Bytes.fromHex("A1B2C3D4E5F60718")
    private val hub = Bytes.fromHex("0100D0C1B2A39400")
    private val now = 1_000_000L

    private fun session(
        linkId: String,
        peer: Bytes?,
        kind: Int?,
        state: SessionState,
        wm: Long = 10,
        peerFh: Long = 10,
        servedTo: Long = 20,
        pendingLive: Int = 0,
    ) = SessionInfo(linkId, if (linkId.startsWith("hub:")) SessionRole.CENTRAL else SessionRole.PERIPHERAL, state, peer, kind, null, null,
        0, 185, now - 60_000, wm, peerFh, servedTo, pendingLive, false, SessionCounters(), null)

    private fun snap(
        sessions: List<SessionInfo> = emptyList(),
        memos: List<LinkMemo> = emptyList(),
        durable: Long = 20,
        accepted: Map<Bytes, Long> = emptyMap(),
        group: SyncGroup? = SyncGroup.fromKey(Bytes.fromHex("B6DDFC8FC47B575D8935C8453BB843EA")),
    ) = NodeSnapshot(
        now, self, group, Bytes.fromHex("1269208CA2190C2D"), durable, sessions, memos,
        sessions.filter { it.peerId != null }.associate { it.peerId!! to it.peerFeedHigh },
        sessions.filter { it.peerId != null }.associate { it.peerId!! to it.servedTo },
        accepted,
        sessions.filter { it.peerId != null }.associate { it.peerId!! to PeerState(Bytes.ZERO8, it.wm ?: 0, true) },
        5,
    )

    private fun hb(id: Bytes, kind: Int, records: Long, pct: Int = 81, mv: Int = -1, chg: Int = 0, rt: Int = -1, state: Int = 0, link: List<HbLink> = emptyList()) =
        Hb(id, kind, 1, 1, 0, 100, pct, mv, chg, rt, null, null, link, state, 0, 10, Bytes.ZERO8, records)

    private fun stats(records: Int = 7, next: Long = 21, durable: Long = 20) = LibrarySyncStats(records, 0, next, durable, 0, 0)

    private fun inputs(node: NodeSnapshot, roster: List<RosterEntry> = emptyList(), stats: LibrarySyncStats = stats(), hubInfo: HubLinkInfo? = null,
        advert: AdvertBattery? = null, advertAge: Long? = null, central: Long? = null) =
        StatusInputs(now, true, node, roster, stats, hubInfo, advert, advertAge, central, SelfBattery(54, 3900, false, 180, false))

    private fun row(d: SyncDashboard, label: String) = d.rows.first { it.label == label }

    @Test
    fun nothingSeen() {
        val d = SyncStatusBuilder.build(inputs(snap()))
        assertEquals("NEVER", row(d, "IPHONE").badge)
        assertEquals("NEVER", row(d, "ESP32").badge)
        assertFalse(row(d, "IPHONE").seen)
        assertEquals("NOT LINKED", d.header)
        assertEquals("", d.notificationToken)
        assertEquals("GRP E7EF", d.group)
        assertEquals("7 REC", row(d, "THIS").path)
        assertEquals("54% ~3H", row(d, "THIS").battery)
        assertEquals("SYNC OFF", SyncStatusBuilder.build(StatusInputs(now, false, null)).header)
    }

    @Test
    fun syncedDirectIsInSyncAndAllInSync() {
        val s = session("ios:11:22", ios, 3, SessionState.SYNCED)
        val r = RosterEntry(hb(ios, 3, 7, pct = 81, chg = 1), now - 4_000, now - 4_000, emptyMap())
        val d = SyncStatusBuilder.build(inputs(snap(listOf(s)), listOf(r)))
        val ip = row(d, "IPHONE")
        assertEquals("IN SYNC", ip.badge)
        assertEquals("DIRECT", ip.path)
        assertEquals("4S", ip.age)
        assertEquals("81% CHG", ip.battery)
        assertEquals("ALL IN SYNC", d.header)
        assertTrue(d.allInSync)
        assertEquals("IN SYNC", row(d, "THIS").badge)
        assertEquals(" · iPhone ✓ 81%", d.notificationToken)
        assertEquals("IPHONE   81% CHG           4S  DIRECT      IN SYNC", ip.line())
    }

    @Test
    fun syncingCountsWhatEitherSideStillLacks() {
        // Peer has 12 vs our wm 10 (2); we have 20 durable, served to 14 (6), 2 of those came from it; 1 live REC queued.
        val s = session("ios:11:22", ios, 3, SessionState.SYNCED, wm = 10, peerFh = 12, servedTo = 14, pendingLive = 1)
        val d = SyncStatusBuilder.build(inputs(snap(listOf(s), accepted = mapOf(ios to 2L))))
        assertEquals("SYNCING 7", row(d, "IPHONE").badge)
        assertEquals("IPHONE SYNCING 7", d.header)
        assertEquals(" · iPhone ↻", d.notificationToken)
        val d2 = SyncStatusBuilder.build(inputs(snap(listOf(session("ios:11:22", ios, 3, SessionState.SYNCING, servedTo = 20)))))
        assertEquals("SYNCING 0", row(d2, "IPHONE").badge)
        val d3 = SyncStatusBuilder.build(inputs(snap(listOf(session("ios:11:22", ios, 3, SessionState.HELLO_X)))))
        assertEquals("LINKING", row(d3, "IPHONE").badge)
    }

    @Test
    fun linkIssuesComeFirst() {
        fun memo(id: String, kind: Int, st: SessionState) = LinkMemo(id, null, kind, st, now - 1_000, false, null)
        assertEquals("OTHER GROUP", row(SyncStatusBuilder.build(inputs(snap(memos = listOf(memo("hub:AA", 1, SessionState.FOREIGN))))), "ESP32").badge)
        assertEquals("UPDATE FW", row(SyncStatusBuilder.build(inputs(snap(memos = listOf(memo("hub:AA", 1, SessionState.INCOMPATIBLE))))), "ESP32").badge)
        assertEquals("UPDATE APP", row(SyncStatusBuilder.build(inputs(snap(memos = listOf(memo("ios:AA", 3, SessionState.INCOMPATIBLE))))), "IPHONE").badge)
        assertEquals("NO GROUP", row(SyncStatusBuilder.build(inputs(snap(listOf(session("ios:AA", ios, 3, SessionState.NOGROUP))))), "IPHONE").badge)
        // Old iPhone build: connected to the relay, no SYNC session.
        assertEquals("LINKING", row(SyncStatusBuilder.build(inputs(snap(), central = now - 5_000)), "IPHONE").badge)
        assertEquals("UPDATE APP", row(SyncStatusBuilder.build(inputs(snap(), central = now - 11_000)), "IPHONE").badge)
        // Hub full (HB state bit9).
        val full = RosterEntry(hb(hub, 1, 7, state = 1 shl 9), now - 2_000, now - 2_000, emptyMap())
        val d = SyncStatusBuilder.build(inputs(snap(listOf(session("hub:AA", hub, 1, SessionState.SYNCED))), listOf(full)))
        assertEquals("HUB FULL", row(d, "ESP32").badge)
        assertEquals(RowTone.PROBLEM, d.headerTone)
        assertTrue(d.notificationToken.contains("hub !"))
    }

    @Test
    fun esp32WithoutSyncFirmwareFallsBackToItsAdvert() {
        val info = HubLinkInfo(HubPhase.IDLE, null, false, true, "AA:BB", "no SYNC characteristic", 0, 0)
        val d = SyncStatusBuilder.build(inputs(snap(), hubInfo = info, advert = AdvertBattery(68, false, false, true, 300), advertAge = 12_000))
        val e = row(d, "ESP32")
        assertEquals("NO SYNC FW", e.badge)
        assertEquals("AIR", e.path)
        assertEquals("12S", e.age)
        assertEquals("68% ~5H", e.battery)
        assertEquals("ESP32 NO SYNC FW", d.header)
        assertEquals(" · hub ! 68%", d.notificationToken)
    }

    @Test
    fun forwardedHeartbeatsGiveViaPathsAndBehind() {
        val hubS = session("hub:AA", hub, 1, SessionState.SYNCED)
        val hubHb = RosterEntry(hb(hub, 1, 7, pct = 68, mv = 3910, rt = 300), now - 12_000, now - 12_000, emptyMap())
        val viaOk = RosterEntry(hb(ios, 3, 7, link = listOf(HbLink(hub, 1, SyncConst.HB_LINK_SYNCED))), now - 30_000, null, mapOf(hub to now - 30_000))
        val d = SyncStatusBuilder.build(inputs(snap(listOf(hubS)), listOf(hubHb, viaOk)))
        assertEquals("IN SYNC", row(d, "IPHONE").badge)
        assertEquals("VIA ESP32", row(d, "IPHONE").path)
        assertEquals("68% 3.91V ~5H", row(d, "ESP32").battery)
        assertEquals("ALL IN SYNC", d.header)
        val behind = RosterEntry(hb(ios, 3, 4, link = listOf(HbLink(hub, 1, SyncConst.HB_LINK_SYNCED))), now - 30_000, null, mapOf(hub to now - 30_000))
        assertEquals("BEHIND 3", row(SyncStatusBuilder.build(inputs(snap(listOf(hubS)), listOf(hubHb, behind))), "IPHONE").badge)
        val lost = RosterEntry(hb(ios, 3, 7), now - 11 * 60_000L, null, mapOf(hub to now - 11 * 60_000L))
        val dl = SyncStatusBuilder.build(inputs(snap(listOf(hubS)), listOf(hubHb, lost)))
        assertEquals("LOST", row(dl, "IPHONE").age)
        assertEquals("BEHIND", row(dl, "IPHONE").badge)
        assertEquals("--", row(dl, "IPHONE").path)
        // Direct and forwarded copies both fresh.
        val both = RosterEntry(hb(ios, 3, 7), now - 1_000, now - 1_000, mapOf(hub to now - 2_000))
        assertEquals("DIRECT+VIA", row(SyncStatusBuilder.build(inputs(snap(listOf(hubS, session("ios:1", ios, 3, SessionState.SYNCED))), listOf(hubHb, both))), "IPHONE").path)
    }

    @Test
    fun unsavedEditsShowSavingAndOtherDevicesGetRows() {
        val s = session("ios:11:22", ios, 3, SessionState.SYNCED)
        val other = Bytes.fromHex("0909090909090909")
        val r = RosterEntry(hb(other, 2, 7).copy(name = "Pixel 7"), now - 3_000, null, mapOf(ios to now - 3_000))
        val d = SyncStatusBuilder.build(inputs(snap(listOf(s)), listOf(r), stats = stats(next = 25, durable = 20)))
        assertEquals("SAVING", row(d, "THIS").badge)
        assertEquals("ANDROID PIXEL 7", d.rows[2].label)
        assertEquals("VIA IPHONE", d.rows[2].path)
        assertFalse(d.allInSync)
    }

    @Test
    fun textHelpers() {
        assertEquals("--", SyncStatusBuilder.batteryText(-1, null, false, false, -1))
        assertEquals("USB", SyncStatusBuilder.batteryText(-1, null, false, true, -1))
        assertEquals("~45M", SyncStatusBuilder.runtimeText(45))
        assertEquals("~99H+", SyncStatusBuilder.runtimeText(99 * 60))
        assertEquals("59S", SyncStatusBuilder.ageText(59_999))
        assertEquals("9M", SyncStatusBuilder.ageText(9 * 60_000L + 59_000))
        assertEquals("LOST", SyncStatusBuilder.ageText(10 * 60_000L))
        assertEquals("--", SyncStatusBuilder.ageText(null))
    }

    @Test
    fun aRealThreeNodeRunReadsAllInSyncFromAndroid() {
        // grouped_hub_two_phones over the loopback, then long enough for the 60 s heartbeats: Android
        // has a hub session only, so the iPhone is judged from its HB forwarded by the hub.
        val j = SyncTestData.transcripts().first { it.first == "grouped_hub_two_phones.json" }.second
        val d = TranscriptDriver(j, Random(5)).run(extraMs = 130_000)
        val a = d.real("A")
        val snapshot = a.node.snapshot()
        val dash = SyncStatusBuilder.build(
            StatusInputs(d.sched.now(), true, snapshot, a.node.roster.entries(), a.lib.stats(), self = SelfBattery(54, 3912, false, 180, false)),
        )
        assertEquals("ESP32", dash.rows[1].label)
        assertEquals("IN SYNC", dash.rows[1].badge)
        assertEquals("DIRECT", dash.rows[1].path)
        assertEquals("IN SYNC", dash.rows[0].badge)
        assertEquals("VIA ESP32", dash.rows[0].path)
        assertEquals("ALL IN SYNC", dash.header)
        assertEquals(" · iPhone ✓ 81% · hub ✓ 68%", dash.notificationToken)
        for (r in dash.rows) println("sync status: ${r.line()}")
    }
}
