package com.magicmaker.android.sync

import com.magicmaker.android.core.HexUtils
import com.magicmaker.android.core.MagicCategory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

// Integration (docs/SYNC_P3_ANDROID_PLAN.md §9.3): the Android SyncNode on part 1's real classes
// (LibrarySync over FakeRows, the real EventOrigin and DeviceRoster, a virtual SaveSink that saves
// 300 ms after a change and at once on a page commit) linked through the loopback transport to the
// iPhone stand-in. Covers what the user sees: a rename on the iPhone renames every Android row, an
// Android delete tombstones the key and blocks re-learn, a bulk change reaches the iPhone through
// the on-change heartbeat, heard packets reach the iPhone, and the card reads ALL IN SYNC.

class SyncIntegrationTest {
    private val group = SyncGroup.fromKey(Bytes.fromHex("B6DDFC8FC47B575D8935C8453BB843EA"))
    private val idI = Bytes.fromHex("A1B2C3D4E5F60718")

    private inner class Rig(seed: Long = 1) {
        val sched = VirtualScheduler(DataFixtures.T0)
        val rows = FakeRows()
        val identity = MemIdentity().also { it.setGroup(group) }
        private var pending = false
        lateinit var sync: LibrarySync

        /** As MagicStore.saveNow: nextSyncSeq and the snapshot under the lock, then the write. */
        private fun store() {
            val seq = synchronized(lock) {
                val s = sync.nextSyncSeq
                sync.snapshot()
                s
            }
            sync.onSaved(seq)
        }
        val saves = SaveSink { urgent ->
            if (urgent) {
                store()
            } else if (!pending) {
                pending = true
                sched.at(sched.now() + 300) {
                    pending = false
                    store()
                }
            }
        }
        val lock = Any()
        val roster = DeviceRoster()
        val role: AndroidRole
        val node: SyncNode

        val iLib: FakeLibraryPort
        val iRole = IosStandInRole()
        val iNode: SyncNode
        private val rng = Random(seed)
        private var gatt: LoopbackGatt? = null
        var upCount = 0

        init {
            sync = LibrarySync(rows, LedgerStore(), identity, saves, lock) { sched.wallMs() }
            role = AndroidRole(EventOrigin(identity.deviceId, DataFixtures.T0 / 1000, 2000))
            node = SyncNode(
                NodeConfig(identity.deviceId, SyncConst.KIND_ANDROID, version = "1.4.0", name = "Pixel 8"), identity, sync, roster, sched, role,
                { SelfStatus(54, 3912, 0, 180, 1, 12, 1000 + sched.now() / 1000) }, NodePolicy.PRODUCTION, { randomNonce() }, 0x2002,
            )
            sync.setListener(node.inlineListener())
            iLib = FakeLibraryPort(SyncConst.KIND_IOS, sched, Ledger(), 0)
            iNode = SyncNode(
                NodeConfig(idI, SyncConst.KIND_IOS, version = "1.4.0", name = "iPhone"), FakeIdentity(idI, Bytes.fromHex("9E859EDAA1D4E6A4"), group),
                iLib, FakeRoster(), sched, iRole, { SelfStatus(81, -1, 0, 290, 0x80, null, 1000) }, NodePolicy.PRODUCTION, { randomNonce() }, 0x1001,
            )
            iLib.setListener(iNode.inlineListener())
        }

        fun randomNonce(): Bytes = Bytes.of(*IntArray(8) { rng.nextInt(256) })

        fun linkUp(mtu: Int = 185) {
            val g = LoopbackGatt(sched, rng, mtu, "ios:AA", "ios:AA") { _ -> linkDown() }
            gatt = g
            val chA = LinkChannel(g.b, sched, SyncConst.PHONE_MAXMSG, onMessage = { node.onMessage("ios:AA", it) })
            val chI = LinkChannel(g.a, sched, SyncConst.PHONE_MAXMSG, onMessage = { iNode.onMessage("ios:AA", it) })
            g.a.channel = chI
            g.b.channel = chA
            node.linkUp(chA, SessionRole.PERIPHERAL, mtu, null)
            iNode.linkUp(chI, SessionRole.CENTRAL, mtu, SyncConst.KIND_ANDROID)
            upCount++
        }

        fun linkDown() {
            gatt?.cut()
            gatt = null
            node.linkDown("ios:AA")
            iNode.linkDown("ios:AA")
        }

        fun run(ms: Long) = sched.run(sched.now() + ms)

        fun versionsA(): Map<String, Long> = synchronized(lock) { sync.ledger.entriesByKey().associate { it.keyString to it.version.updatedAt } }

        fun versionsI(): Map<String, Long> = iLib.ledger.entriesByKey().associate { it.keyString to it.version.updatedAt }

        fun status(): SyncDashboard = SyncStatusBuilder.build(
            StatusInputs(sched.now(), true, node.snapshot(), roster.entries(), sync.stats(), self = SelfBattery(54, 3912, false, 180, false)),
        )
    }

    @Test
    fun anIphoneRenameRenamesEveryAndroidRowOfThatPacket() {
        val r = Rig()
        r.rows.learn(DataHexes.E90C)
        r.rows.userPreset(DataHexes.E90C, "My show")
        r.sync.onLearned(DataHexes.E90C)
        r.linkUp()
        // Saved just after link-up: the on-change HB (at least 5 s after the AUTHED one) makes the iPhone pull.
        r.run(8_000)
        assertNotNull("the PRESENCE reached the iPhone", r.iLib.ledger.get(DataFixtures.key(DataHexes.E90C)))
        // The iPhone renames it (the user said: "I will be renaming on ios").
        r.iLib.localEdit(RecordClass.USER, DataFixtures.key(DataHexes.E90C), idI, label = "Sparkle Trail", category = SyncConst.CAT_ANIMATION,
            kind = "animation", place = SyncConst.PLACE_LIBRARY)
        r.run(5_000)
        val labels = r.rows.rowsWith(DataHexes.E90C).map { it.label }.toSet()
        assertEquals(setOf("Sparkle Trail"), labels)
        assertTrue(r.rows.rowsWith(DataHexes.E90C).all { it.userEdited == true && it.category == MagicCategory.ANIMATION })
        assertEquals(r.versionsI(), r.versionsA())
        assertEquals("ALL IN SYNC", r.status().header)
    }

    @Test
    fun anAndroidDeleteTombstonesTheKeyEverywhereAndBlocksRelearn() {
        val r = Rig(2)
        r.rows.learn(DataHexes.DUAL)
        r.sync.onLearned(DataHexes.DUAL)
        r.linkUp()
        r.run(5_000)
        r.sync.onDelete(listOf(DataHexes.DUAL))
        r.run(5_000)
        val e = r.iLib.ledger.get(DataFixtures.key(DataHexes.DUAL))!!
        assertTrue("the iPhone holds the tombstone", e.isTombstone)
        assertTrue(r.sync.isTombstoned(DataHexes.DUAL))
        assertTrue(r.rows.rowsWith(DataHexes.DUAL).isEmpty())
        assertEquals(null, r.sync.onLearned(DataHexes.DUAL))
        assertEquals(r.versionsI(), r.versionsA())
    }

    @Test
    fun aBulkChangeReachesTheIphoneThroughTheOnChangeHeartbeat() {
        val r = Rig(3)
        r.linkUp()
        r.run(5_000)
        // An import / external diff: bulk, so nothing is pushed live; the durable write triggers an
        // on-change HB whose feedHigh makes the iPhone pull, well before the 60 s heartbeat.
        val hexes = listOf(DataHexes.E90C, DataHexes.FX, DataHexes.DUAL, DataHexes.STAR5)
        for (h in hexes) r.rows.learn(h)
        val ops = hexes.map { LocalEditOp.User(HexUtils.canonicalHex(it), "Imported $it".take(30), SyncConst.CAT_SHOW, "show", null, SyncConst.PLACE_LIBRARY, false, true) }
        r.sync.onDiff(ops)
        r.run(8_000)
        for (h in hexes) assertNotNull(h, r.iLib.ledger.get(DataFixtures.key(h)))
        assertEquals(r.versionsI(), r.versionsA())
        assertEquals("ALL IN SYNC", r.status().header)
    }

    @Test
    fun heardPacketsReachTheIphoneAndCatchUpAfterAnOutage() {
        val r = Rig(4)
        r.linkUp()
        r.run(5_000)
        fun hear(hex: String, t: Long) = r.role.onSighting(
            HeardSighting(Bytes.fromHex(hex), -60, r.sched.wallMs(), t, 283852000, -815639000, 8, Bytes.fromHex("D0C1B2A39400"), false),
        )
        hear(DataHexes.E90C, r.sched.now())
        r.run(100)
        assertEquals(1, r.iRole.accepted.size)
        r.linkDown()
        // Heard while apart: the ring keeps them (the coalescer merges repeats inside 1 s).
        for (k in 0 until 6) {
            hear(if (k % 2 == 0) DataHexes.FX else DataHexes.DUAL, r.sched.now())
            r.run(1_200)
            r.role.onEventsTick()
        }
        r.linkUp()
        r.run(10_000)
        assertEquals(r.role.events!!.seq, r.iRole.accepted.size.toLong())
        assertTrue(r.role.replaysSent > 0)
    }

    @Test
    fun theCardFollowsTheLink() {
        val r = Rig(5)
        r.rows.learn(DataHexes.E90C)
        r.sync.onLearned(DataHexes.E90C)
        assertEquals("NOT LINKED", r.status().header)
        r.linkUp()
        r.run(60)
        val linking = r.status().rows.first { it.label == "IPHONE" }.badge
        assertTrue(linking, linking == "LINKING" || linking.startsWith("SYNCING"))
        r.run(8_000)
        val d = r.status()
        assertEquals("IN SYNC", d.rows.first { it.label == "IPHONE" }.badge)
        assertEquals("DIRECT", d.rows.first { it.label == "IPHONE" }.path)
        assertEquals("81% ~4H", d.rows.first { it.label == "IPHONE" }.battery)
        r.linkDown()
        r.run(1_000)
        // Unlinked: judged from its last heartbeat, which predates its pull.
        val after = r.status().rows.first { it.label == "IPHONE" }
        assertTrue(after.badge, after.badge.startsWith("BEHIND"))
        assertEquals(RowTone.PROBLEM, after.tone)
    }

    @Test
    fun aSmallMtuRouteWidensTheCoalescingWindowTo3s() {
        // Spec §3.2: at MTU 23 (18-byte chunks) Android's event window is 3 s, not 1 s.
        for ((mtu, wide) in listOf(23 to true, 185 to false)) {
            val r = Rig(6)
            r.linkUp(mtu)
            r.run(5_000)
            fun hear() = r.role.onSighting(
                HeardSighting(Bytes.fromHex(DataHexes.E90C), -60, r.sched.wallMs(), r.sched.now(), null, null, null, null, false),
            )
            hear()
            assertEquals("mtu $mtu", wide, r.role.isWide)
            r.run(2_000)
            hear()
            // 1 s: that window is over, so a new event leaves at once. 3 s: still inside, only counted.
            assertEquals("mtu $mtu", if (wide) 1L else 2L, r.role.events!!.seq)
            r.run(1_500)
            r.role.onEventsTick()
            r.run(500)
            assertEquals("mtu $mtu", 2L, r.role.events!!.seq)
            assertEquals("mtu $mtu", 2, r.iRole.accepted.size)
        }
    }

    @Test
    fun aPageCutShortByALinkDropStillReachesTheRows() {
        // Page RECs are projected at their page's commit. When the link drops mid-page they stay in
        // the ledger (a re-pull finds them DUPLICATE), so the link-down save must project them.
        val r = Rig(7)
        val hexes = (0 until 60).map { "8301AABB%04X".format(it) }
        for (h in hexes) {
            r.iLib.localEdit(RecordClass.USER, DataFixtures.key(h), idI, label = "Gate ${h.takeLast(4)}", category = SyncConst.CAT_UNKNOWN,
                kind = "raw", place = SyncConst.PLACE_RAW)
        }
        r.run(1_000)
        r.linkUp(23) // small pages (limit 8): plenty of time inside one
        var cut = false
        for (step in 0 until 20_000) {
            r.run(5)
            val accepted = synchronized(r.lock) { r.sync.ledger.size }
            if (accepted > r.rows.learnedRaw.size) {
                r.linkDown()
                cut = true
                break
            }
        }
        assertTrue("caught a page in flight", cut)
        r.run(1_000)
        val accepted = synchronized(r.lock) { r.sync.ledger.entriesByKey().map { it.key.packet.hex() }.toSet() }
        assertTrue(accepted.size in 1 until hexes.size)
        assertEquals(accepted, r.rows.learnedRaw.map { it.hex }.toSet())
        assertTrue(r.rows.learnedRaw.all { it.label.startsWith("Gate ") && it.userEdited == true })
        // Back together: the rest arrives and nothing is projected twice.
        r.linkUp(185)
        r.run(30_000)
        assertEquals(hexes.toSet(), r.rows.learnedRaw.map { it.hex }.toSet())
        assertEquals(r.versionsI(), r.versionsA())
    }
}
