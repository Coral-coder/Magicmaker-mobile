package com.magicmaker.android.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// Node-level transcript conformance (docs/SYNC_P3_ANDROID_PLAN.md §10.2): every transcript is
// re-run with SyncNode for each node (Android = AndroidRole, iPhone / hub = the stand-ins) and must
// reproduce the transcript step for step (every message byte for byte, every state, apply, durable,
// timer, group, foreign, disconnect, ingest and gap step, in order) and end in its final state.

class SyncNodeReplayTest {
    private val required = setOf(
        "grouped_hub_two_phones.json", "live_push_forwarding_seenby.json", "reconnect_watermarks.json", "event_catchup.json",
    )

    @Test
    fun everyTranscriptReplaysExactly() {
        val all = SyncTestData.transcripts()
        assertTrue("transcripts missing", all.map { it.first }.containsAll(required))
        for ((file, j) in all) {
            val d = TranscriptDriver(j).run()
            assertNull("$file", d.stepMismatch())
            for ((name, want) in j.obj("final").obj("nodes").entrySet()) {
                assertJson("$file final $name", d.finalJson(name), want)
            }
            println("sync replay: $file ${d.steps.size} steps exact")
        }
    }

    @Test
    fun androidMessagesMatchByteForByte() {
        // The same check narrowed to what the Android node emits, for a readable failure.
        for ((file, j) in SyncTestData.transcripts().filter { it.first in required }) {
            val d = TranscriptDriver(j).run()
            val want = j.arr("steps").objects().filter { it.str("ev") == "msg" && it.str("from") == "A" }.map { it.str("hex") }
            val got = d.steps.filter { it.str("ev") == "msg" && it.str("from") == "A" }.map { it.str("hex") }
            assertEquals("$file: messages from A", want, got)
        }
    }

    @Test
    fun androidRoutePrefersDirectThenHubThenRing() {
        // grouped_hub_two_phones: A has only a hub link -> route 2 once the hub's direct HB shows a
        // synced iPhone link; event_catchup: direct to the iPhone (1), ring only while unlinked (3).
        val routes = HashMap<String, Set<Int>>()
        for ((file, j) in SyncTestData.transcripts().filter { it.first in required }) {
            val d = TranscriptDriver(j).run()
            routes[file] = d.steps.filter { it.str("ev") == "local" && it.str("op") == "heard" }.map { it.int("route") }.toSet()
        }
        assertEquals(setOf(2), routes["grouped_hub_two_phones.json"])
        assertEquals(setOf(1, 3), routes["event_catchup.json"])
    }
}
