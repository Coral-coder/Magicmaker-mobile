package com.magicmaker.android.sync

import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.Random

// Robustness (not a vector group): bytes from a peer are untrusted, so the codec may only fail with
// SyncException, a decoded message must re-encode to a canonical form that decodes to the same
// fields, and neither the session core nor the reassembler may throw on garbage. Deterministic
// (fixed seeds); mutations of the vectors' own messages, bodies and frames.

class SyncFuzzTest {
    private val v get() = SyncTestData.vectors

    private fun mutate(r: Random, b: Bytes): Bytes {
        val a = b.toByteArray().toMutableList()
        when (r.nextInt(6)) {
            0 -> if (a.isNotEmpty()) a[r.nextInt(a.size)] = r.nextInt(256).toByte()
            1 -> if (a.isNotEmpty()) repeat(r.nextInt(a.size) + 1) { a.removeAt(a.size - 1) }
            2 -> a.add(if (a.isEmpty()) 0 else r.nextInt(a.size + 1), r.nextInt(256).toByte())
            3 -> if (a.size > 2) a[1 + r.nextInt(a.size - 1)] = (a[1 + r.nextInt(a.size - 1)].toInt() xor (1 shl r.nextInt(8))).toByte()
            4 -> if (a.size > 3) { val i = 1 + r.nextInt(a.size - 2); val t = a[i]; a[i] = a[i + 1]; a[i + 1] = t }
            else -> repeat(r.nextInt(4) + 1) { a.add(r.nextInt(256).toByte()) }
        }
        return Bytes.of(a.toByteArray())
    }

    private fun pool(): List<Bytes> {
        val out = ArrayList<Bytes>()
        for (k in listOf("messages", "messageRejects", "messageNonCanonical", "messageBadBody", "messageIgnored")) {
            for (c in v.arr(k).objects()) out.add(c.hex("hex"))
        }
        for (c in v.arr("hbHops").objects()) out.add(c.hex("inHex"))
        return out
    }

    @Test
    fun messageDecodeFailsOnlyWithSyncException() {
        val r = Random(0x5EED)
        val msgs = pool()
        var decoded = 0
        repeat(20_000) {
            val m = mutate(r, msgs[r.nextInt(msgs.size)])
            val msg = try {
                SyncMsgs.decode(m)
            } catch (e: SyncException) {
                return@repeat
            } catch (e: Throwable) {
                fail("decode(${m.hex()}) threw $e")
                return@repeat
            }
            if (msg is SyncMsg.Unknown) return@repeat
            val canon = try {
                msg.encode()
            } catch (e: Throwable) {
                fail("re-encode of ${m.hex()} threw $e")
                return@repeat
            }
            // decode keeps explicit defaults (messageNonCanonical), so compare canonical forms
            val again = SyncMsgs.decode(canon)
            assertEq("canonical is a fixed point for ${m.hex()}", again.encode(), canon)
            assertEq("canonical decode is stable for ${m.hex()}", SyncMsgs.decode(again.encode()), again)
            if (msg is Rec) {
                msg.bodyFields?.let { assertEq("REC body re-encodes", it.encode(), msg.body) }
                msg.errKey
            }
            decoded++
        }
        assertTrue("fuzz decoded nothing", decoded > 100)
    }

    @Test
    fun bodyDecodeAndApplyNeverThrowOtherwise() {
        val r = Random(0xB0D1)
        val bodies = v.arr("bodies").objects().map { it.hex("hex") } + v.arr("bodyRejects").objects().map { it.hex("hex") }
        val led = Ledger(tombstoneCap = 3)
        repeat(20_000) {
            val b = mutate(r, bodies[r.nextInt(bodies.size)])
            try {
                val f = RecordBody.decode(b)
                assertEq("canonical body ${b.hex()}", f.encode(), b)
            } catch (e: SyncException) {
                // expected
            } catch (e: Throwable) {
                fail("decodeBody(${b.hex()}) threw $e")
            }
            RecordBody.errKeyOf(b)
            led.applyRemote(b, Bytes.fromHex("4A1D0B5E77C2903F"), if (r.nextBoolean()) 1_796_000_000_000L else null)
        }
        assertTrue(led.tombstoneCount() <= 3)
    }

    @Test
    fun reassemblerNeverThrows() {
        val r = Random(0xF4A3)
        val frames = v.arr("frames").objects().flatMap { it.arr("frames").hexList() } +
            v.arr("reassembly").objects().flatMap { it.arr("frames").hexList() }
        val ra = Reassembler(512)
        repeat(20_000) {
            val f = if (r.nextInt(4) == 0) mutate(r, frames[r.nextInt(frames.size)]) else frames[r.nextInt(frames.size)]
            for (e in ra.feed(f)) if (e is FrameEvent.Deliver) assertTrue(e.msg.size <= 512)
        }
    }

    @Test
    fun sessionCoreNeverThrowsOnGarbage() {
        val r = Random(0x5E55)
        val msgs = pool() + v.arr("sessions").objects().flatMap { sc ->
            sc.arr("steps").objects().filter { it.obj("in").str("in") == "rx" }.map { it.obj("in").hex("hex") }
        }
        for (sc in v.arr("sessions").objects()) {
            repeat(20) { round ->
                val core = SyncSessionHarness.coreFromJson(sc.obj("config"), sc.obj("ctx"))
                var n = 0L
                core.ctx.nextNonce = { Bytes.u64BigEndian(0x1000L + n++) }
                var t = 0L
                try {
                    // replay the scripted prefix so the session sits in an interesting state
                    for (st in sc.arr("steps").objects().take(round % (sc.arr("steps").size() + 1))) {
                        st.objOrNull("ctx")?.let { SyncSessionHarness.applyCtx(core.ctx, it) }
                        t = st.long("t")
                        core.handle(t, SyncSessionHarness.inputFromJson(st.obj("in")))
                    }
                    repeat(200) {
                        t += r.nextInt(3000)
                        val inp = when (r.nextInt(10)) {
                            0 -> SessionInput.Timer(SessionTimer.values()[r.nextInt(SessionTimer.values().size)])
                            1 -> core.snapshot().timers.entries.firstOrNull()?.let { (k, due) -> t = maxOf(t, due); SessionInput.Timer(k) }
                                ?: SessionInput.PullNow
                            2 -> listOf(SessionInput.GroupChanged, SessionInput.Rekey, SessionInput.PullNow)[r.nextInt(3)]
                            else -> {
                                val m = msgs[r.nextInt(msgs.size)]
                                SessionInput.Rx(if (r.nextBoolean()) mutate(r, m) else m)
                            }
                        }
                        for (a in core.handle(t, inp)) {
                            if (a is SessionAction.Send) SyncMsgs.decode(a.bytes) // everything sent decodes
                        }
                    }
                } catch (e: Throwable) {
                    throw AssertionError("session ${sc.str("name")} round $round threw at t=$t", e)
                }
            }
        }
    }
}
