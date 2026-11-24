package com.magicmaker.android.sync

import com.google.gson.JsonObject
import org.junit.Assert.assertTrue
import org.junit.Test

// SYNC v1 golden transcripts at codec level (tools/sync/README.md "How harnesses use transcripts",
// P1; the Kotlin twin of check_transcript() in tools/sync/check_vectors.py): every message decodes
// to its fields and re-encodes byte for byte, fragments to the recorded frames at the link MTU and
// reassembles to itself, HELLO proofs and session AUTHs verify, and the final ledgers decode.

class SyncTranscriptsTest {
    private data class LinkInfo(val central: String, val peripheral: String, val mtu: Int)

    @Test
    fun transcripts() {
        val all = SyncTestData.transcripts()
        assertTrue("no transcripts found in ${SyncTestData.dir}", all.isNotEmpty())
        val checked = Checked()
        for ((file, j) in all) {
            checkTranscript(file, j, checked)
            checked.ok("transcripts")
        }
        println("sync transcripts: $checked")
    }

    private fun checkTranscript(file: String, j: JsonObject, checked: Checked) {
        val nodes = j.obj("nodes")
        val keys = HashMap<Bytes, Bytes>() // groupId -> groupKey
        val maxMsg = HashMap<String, Int>()
        for ((name, n) in nodes.entrySet()) {
            val o = n.asJsonObject
            o.hexOrNull("groupKey")?.let { keys[o.hex("groupId")] = it }
            maxMsg[name] = o.longOrNull("maxMsg")?.toInt() ?: SyncConst.PHONE_MAXMSG
        }
        val frag = HashMap<Pair<String, String>, Fragmenter>()
        val reasm = HashMap<Pair<String, String>, Reassembler>()
        val helloC = HashMap<String, Hello>()
        val helloP = HashMap<String, Hello>()
        val links = HashMap<String, LinkInfo>()
        for (st in j.arr("steps").objects()) {
            when (st.str("ev")) {
                "link_up" -> {
                    val link = st.str("link")
                    val li = LinkInfo(st.str("central"), st.str("peripheral"), st.int("mtu"))
                    links[link] = li
                    for (who in listOf(li.central, li.peripheral)) {
                        frag[link to who] = Fragmenter()
                        reasm[link to who] = Reassembler(maxMsg.getValue(who))
                    }
                    continue
                }
                "msg" -> {}
                else -> continue
            }
            val link = st.str("link")
            val data = st.hex("hex")
            val what = "$file step ${st.int("i")} ${st.str("type")}"
            val li = links.getValue(link)
            if (st.get("fields").isAbsent()) {
                assertTrue("$what: fields null without decodeError", st.has("decodeError"))
                var failed: SyncException? = null
                try {
                    SyncMsgs.decode(data)
                } catch (e: SyncException) {
                    failed = e
                }
                assertEq("$what decode error", failed?.let { ErrCode.name(it.code) }, "BAD_MSG")
            } else {
                val (mt, f) = MsgCodec.decode(data)
                assertJson(what, SyncJson.fieldsToJson(mt, f!!), st.obj("fields"))
                assertEq("$what re-encode", MsgCodec.encode(mt, f).hex(), st.str("hex"))
                val m = SyncMsgs.decode(data)
                assertEq("$what typed re-encode", m.encode().hex(), st.str("hex"))
                assertEq("$what type name", m.typeName, st.str("type"))
                when {
                    m is Join -> {
                        keys[m.groupId] = m.groupKey
                        assertEq("$what JOIN groupId", SyncCrypto.groupId(m.groupKey), m.groupId)
                    }
                    m is Hello && st.str("from") == li.central -> helloC[link] = m
                    m is Hello && m.proof != null -> {
                        val hc = helloC.getValue(link)
                        val key = keys.getValue(m.groupId)
                        assertEq("$what proofP", m.proof, SyncCrypto.proofP(key, hc.nonce, m.nonce, hc.deviceId, m.deviceId))
                        helloP[link] = m
                        checked.ok("proofP")
                    }
                    m is Auth && helloP.containsKey(link) && st.str("by") == "session" -> {
                        val hc = helloC.getValue(link)
                        val hp = helloP.getValue(link)
                        val key = keys.getValue(hp.groupId)
                        assertEq("$what proofC", m.proof, SyncCrypto.proofC(key, hc.nonce, hp.nonce, hc.deviceId, hp.deviceId))
                        checked.ok("proofC")
                    }
                }
                if (m is Rec && m.bodyFields == null) {
                    assertTrue("$what bad body has an error", m.bodyError != null)
                }
            }
            val frames = frag.getValue(link to st.str("from")).fragment(data, li.mtu).map { it.hex() }
            assertEq("$what frames", frames, st.arr("frames").map { it.asString })
            val got = ArrayList<FrameEvent>()
            for (fr in frames) got += reasm.getValue(link to st.str("to")).feed(Bytes.fromHex(fr))
            assertEq("$what reassembly", got, listOf<FrameEvent>(FrameEvent.Deliver(data)))
            checked.ok("transcript messages")
        }
        for ((name, n) in j.obj("final").obj("nodes").entrySet()) {
            for (e in n.asJsonObject.arr("ledger").objects()) {
                val b = e.hex("b")
                val entry = LedgerEntry.restore(b, e.long("s"), e.hexOrNull("f"))
                assertJson("$file final $name ${e.str("key")}", SyncJson.entryToJson(entry), e)
                checked.ok("final ledger entries")
            }
        }
    }
}
