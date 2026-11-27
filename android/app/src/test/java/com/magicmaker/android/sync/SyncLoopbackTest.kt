package com.magicmaker.android.sync

import com.google.gson.JsonArray
import com.google.gson.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

// Convergence through the real transport (docs/SYNC_P3_ANDROID_PLAN.md §10.2 SyncLoopbackTest):
// SyncNode + LinkChannel + Fragmenter / Reassembler on both ends of a LoopbackGatt (the transcript's
// MTU, seeded 5–40 ms latency, onFrameSent 1–10 ms after each write, one frame in flight).
//  - two-node: Android <-> the iPhone stand-in, every transcript that has both, with the A and I
//    local ops (hub-only ops dropped) over one I–A link (the transcript's own, else kept up);
//  - three-node: A, I and H on every transcript link with the transcript's own stimuli;
//  - fuzz: 60 virtual seconds of random edits, learns, deletes, presets, new-wand names, heard
//    packets and link flaps across A / I / H with one ATT value in 200 dropped.
// After quiescence every ledger maps key -> (u, o, c, b) like the transcript's final ledger (or,
// in the fuzz, like the other nodes'), no live REC went to its origin, no PAGE_END claimed more
// than was durable, and every session on a link that is up is SYNCED.

class SyncLoopbackTest {
    private fun finalVersions(j: JsonObject, name: String): Map<String, List<String?>> =
        j.obj("final").obj("nodes").obj(name).arr("ledger").objects().associate { e ->
            e.str("key") to listOf(e.long("u").toString(), e.strOrNull("o"), e.long("c").toString(), e.str("b"))
        }

    private fun assertSynced(what: String, d: TranscriptDriver) {
        val up = d.upLinks().toSet()
        for (n in d.nodes.values.filterIsInstance<TranscriptDriver.RealNode>()) {
            for (s in n.node.sessions()) {
                if (s.id in up) assertEquals("$what: ${n.name} on ${s.id}", SessionState.SYNCED, s.state)
            }
        }
    }

    @Test
    fun threeNodeTranscriptsConvergeOverTheRealTransport() {
        var runs = 0
        for ((file, j) in SyncTestData.transcripts()) {
            val scripted = j.obj("nodes").entrySet().any { it.value.asJsonObject.has("scripted") }
            if (scripted) continue
            for (seed in listOf(1L, 2L, 3L)) {
                val d = TranscriptDriver(j, Random(seed)).run(extraMs = 30_000)
                for (name in j.obj("final").obj("nodes").keySet()) {
                    assertEquals("$file seed $seed: $name ledger", finalVersions(j, name), d.versions(name))
                }
                assertTrue("$file seed $seed: ${d.violations}", d.violations.isEmpty())
                assertSynced("$file seed $seed", d)
                runs++
            }
        }
        assertTrue(runs >= 15)
        println("sync loopback: $runs three-node runs converged")
    }

    /** The transcript with only A and I, their local ops, and one I–A link (the transcript's, else up from 0). */
    private fun twoNode(j: JsonObject): JsonObject {
        val c = j.deepCopy()
        val nodes = JsonObject()
        for (n in listOf("A", "I")) nodes.add(n, j.obj("nodes").obj(n))
        c.add("nodes", nodes)
        val steps = JsonArray()
        val hasIA = j.arr("steps").objects().any { it.str("ev") == "link_up" && it.str("link") == "I-A" }
        if (!hasIA) steps.add(jsonOf("i" to 0, "t" to 0, "ev" to "link_up", "link" to "I-A", "gen" to 1, "central" to "I", "peripheral" to "A", "mtu" to 185))
        for (st in j.arr("steps").objects()) {
            when (st.str("ev")) {
                "link_up", "link_down" -> if (st.str("link") == "I-A") steps.add(st)
                "local" -> if (st.str("node") in setOf("A", "I")) steps.add(st)
                "msg" -> if (st.str("from") in setOf("A", "I") && st.str("by") != "script") steps.add(st)
            }
        }
        c.add("steps", steps)
        return c
    }

    @Test
    fun twoNodeAndroidAndIphoneConverge() {
        var runs = 0
        for ((file, j) in SyncTestData.transcripts()) {
            val names = j.obj("nodes").keySet()
            if (!names.containsAll(listOf("A", "I"))) continue
            val tj = twoNode(j)
            val wantIngest = j.arr("steps").objects().filter { it.str("ev") == "ingest" && it.str("node") == "I" && it.str("result") == "ACCEPT" }
                .map { Triple(it.str("origin"), it.long("epoch"), it.long("seq")) }.toSet()
            for (seed in listOf(11L, 12L, 13L)) {
                val d = TranscriptDriver(tj, Random(seed)).run(extraMs = 30_000)
                assertEquals("$file seed $seed: A", finalVersions(j, "A"), d.versions("A"))
                assertEquals("$file seed $seed: I", finalVersions(j, "I"), d.versions("I"))
                assertTrue("$file seed $seed: ${d.violations}", d.violations.isEmpty())
                assertSynced("$file seed $seed", d)
                val ios = d.real("I").role as IosStandInRole
                val got = ios.accepted.map { Triple(it.first.hex(), it.second, it.third) }.toSet()
                assertEquals("$file seed $seed: events the iPhone accepted", wantIngest, got)
                assertEquals("$file seed $seed: each event accepted once", ios.accepted.size, got.size)
                runs++
            }
        }
        assertTrue(runs >= 12)
        println("sync loopback: $runs two-node runs converged")
    }

    // ---- fuzz --------------------------------------------------------------------------------

    private val packets: List<Bytes> by lazy {
        val out = LinkedHashSet<Bytes>()
        for ((_, j) in SyncTestData.transcripts()) {
            for ((_, n) in j.obj("nodes").entrySet()) {
                val o = n.asJsonObject
                if (!o.has("ledger")) continue
                for (e in o.arr("ledger").objects()) out.add(RecordKey.parseKeyString(e.str("key"))!!.packet)
            }
        }
        val rng = Random(99)
        repeat(8) {
            val len = 6 + rng.nextInt(10)
            out.add(Bytes.of(0x83, 0x01) + Bytes.of(*IntArray(len) { rng.nextInt(256) }))
        }
        out.toList()
    }

    private fun randomOp(d: TranscriptDriver, rng: Random, who: String) {
        val n = d.real(who)
        val packet = packets[rng.nextInt(packets.size)]
        val lib = RecordKey(SyncConst.NS_LIB, packet)
        when (rng.nextInt(7)) {
            0, 1 -> d.localEdit(n, RecordClass.USER, RecordBody(lib, 0, n.id, SyncConst.FLAG_USER_EDITED, "name ${rng.nextInt(1000)}",
                rng.nextInt(4), null, listOf("show", "color", "animation", null)[rng.nextInt(4)], 1 + rng.nextInt(4)))
            2 -> d.localLearn(n, packet)
            3 -> if (d.real(who).lib.ledger.get(lib)?.isTombstone != true) d.localEdit(n, RecordClass.TOMBSTONE, RecordBody(lib, 0, n.id, SyncConst.FLAG_DELETED))
            4 -> d.localEdit(n, RecordClass.USER, RecordBody(lib, 0, n.id, SyncConst.FLAG_PRESET or SyncConst.FLAG_USER_EDITED,
                "preset ${rng.nextInt(100)}", SyncConst.CAT_SHOW, "a note", "show", SyncConst.PLACE_PRESETS))
            5 -> {
                val w = RecordKey(SyncConst.NS_NEWWAND, packet)
                val name = if (rng.nextInt(3) == 0) null else "wand ${rng.nextInt(50)}"
                d.localEdit(n, RecordClass.NEWWAND, RecordBody(w, 0, n.id, label = name))
            }
            else -> d.localEdit(n, RecordClass.RESET, RecordBody(lib, 0, n.id, note = if (rng.nextBoolean()) "n${rng.nextInt(9)}" else null))
        }
    }

    @Test
    fun fuzzConvergesWithFlapsAndDroppedFrames() {
        val base = SyncTestData.transcripts().first { it.first == "live_push_forwarding_seenby.json" }.second
        val runMs = 60_000L
        val quietMs = 150_000L
        var dropped = 0
        for (seed in 1L..8L) {
            val j = base.deepCopy()
            j.add("steps", JsonArray())
            j.add("final", jsonOf("t" to runMs + quietMs, "nodes" to JsonObject()))
            val rng = Random(seed)
            val d = TranscriptDriver(j, Random(seed * 7919), dropOneIn = 200, autoRelinkMs = 2_000)
            d.sched.budget = 3_000_000
            d.sched.traceSites = System.getProperty("sync.trace") != null
            val linkDefs = listOf(Triple("I-H", "I", "H"), Triple("A-H", "A", "H"), Triple("I-A", "I", "A"))
            val mtus = mapOf("I-H" to 185, "A-H" to 247, "I-A" to 23 + rng.nextInt(3) * 81)
            for ((k, l) in linkDefs.withIndex()) d.sched.at(k * 300L) { d.linkUp(l.first, l.second, l.third, mtus.getValue(l.first)) }
            var t = 1_000L
            while (t < runMs) {
                val at = t
                when (rng.nextInt(10)) {
                    in 0..5 -> {
                        val who = listOf("A", "I", "H")[rng.nextInt(3)]
                        d.sched.at(at) { randomOp(d, rng, who) }
                    }
                    6, 7 -> d.sched.at(at) { d.heard(d.real("A"), packets[rng.nextInt(packets.size)], -40 - rng.nextInt(50)) }
                    else -> {
                        val l = linkDefs[rng.nextInt(linkDefs.size)]
                        val back = at + 1_000 + rng.nextInt(4_000)
                        d.sched.at(at) { d.linkDown(l.first, TranscriptDriver.SCENARIO_DOWN) }
                        d.sched.at(back) { if (l.first !in d.upLinks()) d.linkUp(l.first, l.second, l.third, mtus.getValue(l.first)) }
                    }
                }
                t += 50 + rng.nextInt(450)
            }
            // Everything back up for the quiet period.
            d.sched.at(runMs + 6_000) {
                for (l in linkDefs) if (l.first !in d.upLinks()) d.linkUp(l.first, l.second, l.third, mtus.getValue(l.first))
            }
            d.run()
            val a = d.versions("A")
            assertEquals("seed $seed: I equals A", a, d.versions("I"))
            assertEquals("seed $seed: H equals A", a, d.versions("H"))
            assertTrue("seed $seed: ${d.violations}", d.violations.isEmpty())
            assertSynced("seed $seed", d)
            dropped += d.droppedFrames
            println("sync fuzz seed $seed: ${a.size} keys converged, ${d.droppedFrames} frames dropped, ${d.relinks} relinks")
        }
        assertTrue("the fuzz dropped frames", dropped > 0)
    }
}
