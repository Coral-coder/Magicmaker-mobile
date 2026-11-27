package com.magicmaker.android.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

// LinkChannel (docs/SYNC_P3_ANDROID_PLAN.md §5.3, §10.2): framing round trips through the
// loopback, one frame in flight, lane order and replay pacing, no interleaving, counters from 0 at
// link-up, ERR answers for bad frames, stall / outbox closes, MTU changes on the next message.

class LinkChannelTest {
    /** A FrameLink that records frames; frames complete only when [ack] runs (or at once with [autoAckMs]). */
    private class ManualLink(private val sched: VirtualScheduler, var mtuValue: Int = 185, private val autoAckMs: Long? = 2) : FrameLink {
        override val id: String = "test:1"
        override val role: SessionRole = SessionRole.CENTRAL
        val frames = ArrayList<Bytes>()
        val times = ArrayList<Long>()
        var inFlight = false
        var closedReason: String? = null
        var refuse = false
        lateinit var channel: LinkChannel

        override fun mtu(): Int = mtuValue

        override fun writeFrame(frame: ByteArray): Boolean {
            if (refuse) return false
            assertFalse("a second frame while one is in flight", inFlight)
            assertTrue(frame.size <= mtuValue - 3)
            inFlight = true
            frames.add(Bytes.of(frame))
            times.add(sched.now())
            autoAckMs?.let { d -> sched.at(sched.now() + d) { ack() } }
            return true
        }

        fun ack() {
            inFlight = false
            channel.onFrameSent()
        }

        override fun close(reason: String) {
            closedReason = reason
        }

        /** Reassemble what was written (one Reassembler, as the peer would). */
        fun messages(maxMsg: Int = 4096): List<Bytes> {
            val r = Reassembler(maxMsg)
            return frames.flatMap { r.feed(it) }.map { (it as FrameEvent.Deliver).msg }
        }
    }

    private fun channel(link: ManualLink, sched: VirtualScheduler, received: MutableList<Bytes> = ArrayList()): LinkChannel =
        LinkChannel(link, sched, SyncConst.PHONE_MAXMSG, onMessage = { received.add(it) }).also { link.channel = it }

    private fun msg(type: Int, size: Int, fill: Int): Bytes = Bytes.of(type) + Bytes.of(*IntArray(size - 1) { (fill + it) and 0xFF })

    @Test
    fun roundTripThroughLoopbackAtEveryMtu() {
        for (mtu in listOf(23, 185, 247)) {
            val sched = VirtualScheduler()
            val rng = Random(mtu.toLong())
            val gotA = ArrayList<Bytes>()
            val gotB = ArrayList<Bytes>()
            val g = LoopbackGatt(sched, rng, mtu, "x", "x") { }
            val a = LinkChannel(g.a, sched, SyncConst.PHONE_MAXMSG, onMessage = { gotA.add(it) })
            val b = LinkChannel(g.b, sched, SyncConst.PHONE_MAXMSG, onMessage = { gotB.add(it) })
            g.a.channel = a
            g.b.channel = b
            val sentA = (1..30).map { msg(MsgType.REC, 1 + rng.nextInt(1000), it) }
            val sentB = (1..30).map { msg(MsgType.HB, 1 + rng.nextInt(1000), it * 3) }
            for (m in sentA) a.send(MsgType.REC, m, SyncLane.MAIN)
            for (m in sentB) b.send(MsgType.HB, m, SyncLane.MAIN)
            sched.run(600_000)
            assertEquals("mtu $mtu a->b", sentA, gotB)
            assertEquals("mtu $mtu b->a", sentB, gotA)
            assertEquals(0, a.stats().badFrames + b.stats().badFrames)
        }
    }

    @Test
    fun framesOfDifferentMessagesNeverInterleaveAndCountersStartAtZero() {
        val sched = VirtualScheduler()
        val link = ManualLink(sched, mtuValue = 23)
        val ch = channel(link, sched)
        val sent = (1..5).map { msg(MsgType.REC, 50 + it * 10, it) }
        for (m in sent) ch.send(MsgType.REC, m, SyncLane.MAIN)
        sched.run(10_000)
        assertEquals(0, link.frames.first()[0] and 0x0F)
        assertEquals(0, link.frames.first()[1])
        var open: Int? = null
        for (f in link.frames) {
            val start = f[0] and SyncFrames.FR_START != 0
            val end = f[0] and SyncFrames.FR_END != 0
            val ctr = f[0] and 0x0F
            if (start) {
                assertEquals("a message started inside another", null, open)
                open = ctr
            } else {
                assertEquals(open, ctr)
            }
            if (end) open = null
        }
        assertEquals(sent, link.messages())
    }

    @Test
    fun lane0GoesBeforeLane1AndReplaysArePaced() {
        val sched = VirtualScheduler()
        val link = ManualLink(sched, mtuValue = 247, autoAckMs = 1)
        val ch = channel(link, sched)
        val replays = (1..50).map { msg(MsgType.EVT, 30, it) }
        for (m in replays) ch.send(MsgType.EVT, m, SyncLane.REPLAY)
        val live = (1..3).map { msg(MsgType.REC, 40, 100 + it) }
        for (m in live) ch.send(MsgType.REC, m, SyncLane.MAIN)
        sched.run(10_000)
        val got = link.messages()
        assertEquals(53, got.size)
        // The first replay had started before the lane-0 messages were queued; then lane 0 wins.
        assertEquals(replays[0], got[0])
        assertEquals(live, got.subList(1, 4))
        assertEquals(replays.drop(1), got.drop(4))
        // At most 20 EVT in each 1 s budget window (the first window opens at t = 0).
        val starts = link.frames.indices.filter { link.frames[it][0] and SyncFrames.FR_START != 0 }.map { link.times[it] }
        val replayStarts = starts.filterIndexed { i, _ -> got[i][0] == MsgType.EVT }
        val perWindow = replayStarts.groupingBy { it / 1000 }.eachCount()
        assertTrue("$perWindow", perWindow.values.all { it <= LinkChannel.REPLAY_PER_SEC })
        assertTrue("paced over several seconds: $perWindow", perWindow.size >= 3)
    }

    @Test
    fun badFramesAreCountedAndAnsweredOncePer10s() {
        val sched = VirtualScheduler()
        val link = ManualLink(sched)
        val got = ArrayList<Bytes>()
        val ch = channel(link, sched, got)
        val frag = Fragmenter()
        val frames = frag.fragment(msg(MsgType.REC, 300, 1), 23)
        ch.onFrame(frames[0].toByteArray())
        ch.onFrame(frames[2].toByteArray()) // gap
        ch.onFrame(frames[4].toByteArray()) // another gap
        sched.run(100)
        assertEquals(2, ch.stats().badFrames)
        val errs = link.messages().map { SyncMsgs.decode(it) as Err }
        assertEquals(listOf(ErrCode.BAD_FRAME), errs.map { it.code })
        sched.run(11_000)
        ch.onFrame(frames[1].toByteArray())
        sched.run(11_100)
        assertEquals(2, link.messages().size)
        assertTrue(got.isEmpty())
    }

    @Test
    fun tooBigAndOtherVersionFramesAreAnswered() {
        val sched = VirtualScheduler()
        val link = ManualLink(sched)
        val ch = channel(link, sched)
        for (f in Fragmenter().fragment(msg(MsgType.REC, 1500, 7), 185)) ch.onFrame(f.toByteArray())
        ch.onFrame(byteArrayOf(0xB0.toByte(), 0, 1, 2))
        sched.run(100)
        val errs = link.messages().map { SyncMsgs.decode(it) as Err }
        assertEquals(listOf(ErrCode.TOO_BIG, ErrCode.PROTO), errs.map { it.code })
        assertEquals(MsgType.REC, errs[0].refType)
    }

    @Test
    fun aStalledFrameClosesTheLink() {
        val sched = VirtualScheduler()
        val link = ManualLink(sched, autoAckMs = null)
        val ch = channel(link, sched)
        ch.send(MsgType.HB, msg(MsgType.HB, 20, 0), SyncLane.MAIN)
        sched.run(4_999)
        assertEquals(null, link.closedReason)
        sched.run(5_001)
        assertEquals("stall", link.closedReason)
        assertTrue(ch.closed)
    }

    @Test
    fun lane0OverflowClosesAndBusyWritesRetry() {
        val sched = VirtualScheduler()
        val link = ManualLink(sched, autoAckMs = null)
        val ch = channel(link, sched)
        repeat(LinkChannel.LANE0_CAP + 2) { ch.send(MsgType.REC, msg(MsgType.REC, 10, it), SyncLane.MAIN) }
        assertEquals("outbox", link.closedReason)

        val s2 = VirtualScheduler()
        val l2 = ManualLink(s2)
        val c2 = channel(l2, s2)
        l2.refuse = true
        c2.send(MsgType.HB, msg(MsgType.HB, 10, 1), SyncLane.MAIN)
        s2.run(100)
        assertEquals(0, l2.frames.size)
        l2.refuse = false
        s2.run(200)
        assertEquals(1, l2.messages().size)
        assertFalse(c2.closed)
    }

    @Test
    fun anMtuChangeAppliesFromTheNextMessage() {
        val sched = VirtualScheduler()
        val link = ManualLink(sched, mtuValue = 23, autoAckMs = null)
        val ch = channel(link, sched)
        ch.send(MsgType.REC, msg(MsgType.REC, 100, 1), SyncLane.MAIN)
        ch.send(MsgType.REC, msg(MsgType.REC, 100, 2), SyncLane.MAIN)
        link.mtuValue = 185
        ch.onMtu()
        repeat(20) {
            if (link.inFlight) link.ack()
            sched.run(sched.now() + 1)
        }
        val sizes = link.frames.map { it.size }
        assertEquals(List(5) { 20 } + listOf(2 + 100 - 18 * 5, 102), sizes)
    }

    @Test
    fun disconnectFlushesThenCloses() {
        val sched = VirtualScheduler()
        val link = ManualLink(sched)
        val ch = channel(link, sched)
        ch.send(MsgType.ERR, Err(ErrCode.AUTH).encode(), SyncLane.MAIN)
        ch.send(MsgType.EVT, msg(MsgType.EVT, 30, 1), SyncLane.REPLAY)
        ch.disconnect("foreign", null)
        ch.send(MsgType.HB, msg(MsgType.HB, 30, 1), SyncLane.MAIN) // dropped: closing
        sched.run(50)
        assertEquals("foreign", link.closedReason)
        assertEquals(1, link.messages().size)
    }

    @Test
    fun pendingLiveCountsQueuedLiveRecsOnly() {
        val sched = VirtualScheduler()
        val link = ManualLink(sched, autoAckMs = null)
        val ch = channel(link, sched)
        val body = RecordBody(RecordKey(0, Bytes.fromHex("8301E100E90C00010F4D575A940705488BB0")), 1).encode()
        ch.send(MsgType.REC, Rec(5, 0, emptyList(), body).encode(), SyncLane.MAIN)
        ch.send(MsgType.REC, Rec(6, 3, emptyList(), body).encode(), SyncLane.MAIN)
        ch.send(MsgType.REC, Rec(7, 0, listOf(Bytes.fromHex("0102030405060708")), body).encode(), SyncLane.MAIN)
        assertEquals(2, ch.pendingLive())
        assertTrue(LinkChannel.isLiveRec(Rec(9, 0, emptyList(), body).encode()))
        assertFalse(LinkChannel.isLiveRec(Rec(9, 1, emptyList(), body).encode()))
    }
}
