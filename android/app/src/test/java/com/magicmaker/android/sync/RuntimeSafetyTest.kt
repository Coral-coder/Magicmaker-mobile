package com.magicmaker.android.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

// Runtime review fixes: RelayCentrals (only devices that talk to the relay service are centrals),
// GattServerLinks never re-adding a gone device, lock-free identity reads, and the status view's
// "watched" signal that decides between 1 s and idle refreshes.

class RuntimeSafetyTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val phone = "6C:1A:22:33:44:55"
    private val watch = "F0:0D:00:00:00:01"

    // ---- RelayCentrals -----------------------------------------------------------------------

    @Test
    fun aConnectionAloneIsNotACentral() {
        val c = RelayCentrals()
        // Android reports another app's smartwatch link (or this phone's own hub link) here too.
        c.onConnected(watch)
        assertEquals(emptyList<RelayCentrals.Out>(), c.onMtu(watch, 185))
        assertEquals(0, c.engagedCount())
        assertFalse(c.isEngaged(watch))
        // It goes away without ever having been reported to the SYNC endpoint.
        assertEquals(emptyList<RelayCentrals.Out>(), c.onDisconnected(watch))
    }

    @Test
    fun theFirstRequestEngagesWithTheHeldMtu() {
        val c = RelayCentrals()
        c.onConnected(phone.lowercase())
        assertEquals(emptyList<RelayCentrals.Out>(), c.onMtu(phone, 247))
        assertEquals(
            listOf(RelayCentrals.Out.Connected(phone), RelayCentrals.Out.Mtu(phone, 247)),
            c.onRequest(phone),
        )
        assertEquals(1, c.engagedCount())
        // Later requests change nothing; a later MTU goes straight through.
        assertEquals(emptyList<RelayCentrals.Out>(), c.onRequest(phone))
        assertEquals(listOf(RelayCentrals.Out.Mtu(phone, 517)), c.onMtu(phone, 517))
        assertEquals(listOf(RelayCentrals.Out.Disconnected(phone)), c.onDisconnected(phone))
        assertEquals(0, c.engagedCount())
    }

    @Test
    fun aRequestWithoutAConnectCallbackStillEngages() {
        // After a relay restart the iPhone's link may predate the new server's callbacks.
        val c = RelayCentrals()
        assertEquals(listOf(RelayCentrals.Out.Connected(phone)), c.onRequest(phone))
        assertTrue(c.isEngaged(phone))
    }

    @Test
    fun unengagedLinksAreBoundedAndNeverEvictACentral() {
        val c = RelayCentrals()
        c.onRequest(phone)
        for (i in 0 until 100) c.onConnected("AA:BB:CC:DD:%02X:%02X".format(i / 256, i % 256))
        assertTrue(c.isEngaged(phone))
        assertEquals(1, c.engagedCount())
        assertEquals(listOf(RelayCentrals.Out.Disconnected(phone)), c.onDisconnected(phone))
    }

    @Test
    fun clearForgetsEverything() {
        val c = RelayCentrals()
        c.onRequest(phone)
        c.clear()
        assertEquals(0, c.engagedCount())
        assertEquals(emptyList<RelayCentrals.Out>(), c.onDisconnected(phone))
    }

    // ---- GattServerLinks -----------------------------------------------------------------------

    @Test
    fun aLateCccdOffForAGoneDeviceDoesNotReAddIt() {
        val g = GattServerLinks()
        g.onConnected(phone)
        val up = g.onCccd(phone, byteArrayOf(1, 0))
        assertEquals(1, up.size)
        assertTrue(up[0] is ServerLinkEvent.Up)
        assertEquals(listOf(ServerLinkEvent.Down(phone, "ios:$phone")), g.onDisconnected(phone))
        // ServerLink.close after the disconnect: no phantom central (it kept "UPDATE APP" up).
        assertEquals(emptyList<ServerLinkEvent>(), g.onCccd(phone, null))
        assertEquals(0, g.connectedCount())
    }

    // ---- SyncIdentityFile ----------------------------------------------------------------------

    @Test
    fun identityReadsNeverWaitForAWriter() {
        val file = tmp.newFolder().resolve(SyncIdentityFile.FILE_NAME)
        val id = SyncIdentityFile.load(file, 1_000L)
        id.setHubAddress("aa:bb:cc:dd:ee:01")
        val held = CountDownLatch(1)
        val release = CountDownLatch(1)
        val writer = Executors.newSingleThreadExecutor()
        try {
            // A writer inside the monitor (as during an identity fsync).
            writer.execute {
                synchronized(id) {
                    held.countDown()
                    release.await(10, TimeUnit.SECONDS)
                }
            }
            assertTrue(held.await(5, TimeUnit.SECONDS))
            val reader = Executors.newSingleThreadExecutor()
            try {
                val f = reader.submit<String?> {
                    // The echo filter / own-link / discovery reads: all lock-free.
                    id.isForeign("AA:BB:CC:DD:EE:02")
                    id.group
                    id.deviceId
                    id.hubAddress
                }
                assertEquals("AA:BB:CC:DD:EE:01", f.get(2, TimeUnit.SECONDS))
            } finally {
                reader.shutdownNow()
            }
        } finally {
            release.countDown()
            writer.shutdown()
        }
        // Writes still land on disk.
        id.setHubAddress(null)
        assertNull(SyncIdentityFile.load(file, 2_000L).hubAddress)
    }

    // ---- SyncStatus watched ----------------------------------------------------------------------

    @Test
    fun aVisibleCardIsWatchedAndWakesTheEngineOnce() {
        var wakes = 0
        val prev = SyncStatus.onWatch
        SyncStatus.onWatch = { wakes++ }
        try {
            SyncStatus.watch(true)
            SyncStatus.watch(true)
            assertTrue(SyncStatus.watched())
            assertEquals(1, wakes)
            SyncStatus.watch(false)
            assertTrue(SyncStatus.watched())
            SyncStatus.watch(false)
            // Unbalanced extra "hidden" calls never go negative.
            SyncStatus.watch(false)
            SyncStatus.watch(true)
            assertEquals(2, wakes)
            SyncStatus.watch(false)
            // A VFD frame read counts as watched for a while.
            SyncStatus.read()
            assertTrue(SyncStatus.watched())
        } finally {
            SyncStatus.onWatch = prev
        }
    }
}

class StoreSanitizeTest {
    private val gson = com.google.gson.Gson()

    @Test
    fun brokenRowsAreDroppedOrDefaultedNeverThrown() {
        // What a hand edit of /sdcard/MagicMaker/magicmaker_library.json can produce.
        val json = """{"presets":[null,{"id":1,"label":"no hex"},{"id":2,"hex":"","label":"blank"},""" +
            """{"id":3,"hex":"8301AB","category":"NOT_A_CATEGORY"}],"learnedRaw":[{"id":4,"hex":"8302CD","label":null}],""" +
            """"autoRules":[null]}"""
        val raw = gson.fromJson(json, com.magicmaker.android.data.MagicStore.PersistedState::class.java)
        val s = com.magicmaker.android.data.MagicStore.sanitizedState(raw)
        assertEquals(listOf(3L), s.presets.map { it.id })
        val p = s.presets.single()
        assertEquals("", p.label)
        assertEquals(com.magicmaker.android.core.MagicCategory.UNKNOWN, p.category)
        assertEquals("", p.typeInfo)
        assertEquals("", p.simKey)
        assertEquals(listOf("8302CD"), s.learnedRaw!!.map { it.hex })
        assertEquals(0, s.learnedRaw!!.single().label.length)
        assertEquals(emptyList<Any>(), s.autoRules)
        assertEquals(emptyList<Any>(), s.learnedColors)
    }

    @Test
    fun explicitNullListsBecomeEmpty() {
        val raw = gson.fromJson(
            """{"presets":null,"learnedColors":null,"learnedLibrary":null,"learnedRaw":null,"autoRules":null}""",
            com.magicmaker.android.data.MagicStore.PersistedState::class.java,
        )
        val s = com.magicmaker.android.data.MagicStore.sanitizedState(raw)
        assertEquals(0, s.presets.size + s.learnedColors.size + s.learnedLibrary.size + s.learnedRaw!!.size + s.autoRules.size)
    }

    @Test
    fun aCleanStateKeepsItsLists() {
        val row = com.magicmaker.android.core.MagicPacket(
            id = 7, hex = "8301AB", label = "Red", category = com.magicmaker.android.core.MagicCategory.UNKNOWN,
            typeInfo = "", simKey = "k",
        )
        val clean = com.magicmaker.android.data.MagicStore.PersistedState(presets = listOf(row), learnedRaw = listOf(row))
        val s = com.magicmaker.android.data.MagicStore.sanitizedState(clean)
        assertTrue(s.presets === clean.presets)
        assertTrue(s.learnedRaw === clean.learnedRaw)
        assertEquals(gson.toJson(clean), gson.toJson(s))
    }
}
