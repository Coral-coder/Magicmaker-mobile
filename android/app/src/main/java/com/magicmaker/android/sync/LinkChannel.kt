package com.magicmaker.android.sync

// One link's transport (docs/SYNC_P3_ANDROID_PLAN.md §5.3; PROTOCOL §9, §16.3): framing (one
// Fragmenter for TX, one Reassembler for RX, counters at 0 at link-up), a two-lane outbox of whole
// messages with exactly one ATT frame in flight, replay pacing, stall detection and bounds. Pure
// Kotlin on the node's thread: GATT callbacks post to mm-sync before calling onFrame / onFrameSent.

/** The GATT side of one link: HubClient (central), the GATT server endpoint (peripheral), test pipes. */
interface FrameLink {
    /** "hub:AA:BB:CC:DD:EE:FF" / "ios:<address>". */
    val id: String
    val role: SessionRole

    /** The negotiated ATT MTU (23..517). */
    fun mtu(): Int

    /** Send one ATT value (≤ mtu − 3 bytes). At most one outstanding; completion arrives as [LinkChannel.onFrameSent]. False = not accepted now. */
    fun writeFrame(frame: ByteArray): Boolean

    /** Drop the link; the owner then reports link-down to the node. */
    fun close(reason: String)

    /** [close] with the session's reconnect floor ([retryMs], e.g. 30 s after page_timeout). */
    fun close(reason: String, retryMs: Long?) = close(reason)
}

/** Transport counters (diagnostics). */
data class LinkStats(
    val framesSent: Int,
    val framesReceived: Int,
    val messagesSent: Int,
    val messagesReceived: Int,
    val badFrames: Int,
    val lane0: Int,
    val lane1: Int,
    val replayDropped: Int,
    val lastBadFrame: String?,
)

class LinkChannel(
    private val link: FrameLink,
    private val sched: SyncScheduler,
    maxMsg: Int = SyncConst.PHONE_MAXMSG,
    private val onMessage: (Bytes) -> Unit,
    private val onClose: ((reason: String) -> Unit)? = null,
) : LinkPort {
    private class Out(val type: Int, val bytes: Bytes, val live: Boolean)

    private val fragmenter = Fragmenter()
    private val reassembler = Reassembler(maxMsg)
    private val lane0 = ArrayDeque<Out>()
    private val lane1 = ArrayDeque<Out>()
    private val frames = ArrayDeque<Bytes>()
    private var current: Out? = null
    private var inFlight = false
    private var stall: SyncCancel? = null
    private var retry: SyncCancel? = null
    private var closing: String? = null
    private var closeRetryMs: Long? = null
    private var closeTimer: SyncCancel? = null
    var closed = false
        private set

    private var secStart = Long.MIN_VALUE / 4
    private var evtThisSec = 0

    private var framesSent = 0
    private var framesReceived = 0
    private var messagesSent = 0
    private var messagesReceived = 0
    private var badFrames = 0
    private var replayDropped = 0
    private var lastBadFrame: String? = null
    private var lastBadFrameErr = Long.MIN_VALUE / 4

    override val id: String get() = link.id

    val role: SessionRole get() = link.role

    override fun mtu(): Int = link.mtu()

    fun stats(): LinkStats =
        LinkStats(framesSent, framesReceived, messagesSent, messagesReceived, badFrames, lane0.size, lane1.size, replayDropped, lastBadFrame)

    // ---- outbound ----------------------------------------------------------------------------

    override fun send(type: Int, bytes: Bytes, lane: Int) {
        if (closed || closing != null) return
        val out = Out(type, bytes, type == MsgType.REC && isLiveRec(bytes))
        if (lane == SyncLane.REPLAY) {
            lane1.addLast(out)
            while (lane1.size > LANE1_CAP) {
                lane1.removeFirst()
                replayDropped++
            }
        } else {
            lane0.addLast(out)
            if (lane0.size > LANE0_CAP) {
                closeNow("outbox")
                return
            }
        }
        pump()
    }

    override fun pendingLive(): Int = lane0.count { it.live } + (if (current?.live == true) 1 else 0)

    override fun disconnect(reason: String, retryMs: Long?) {
        if (closed || closing != null) return
        closing = reason
        closeRetryMs = retryMs
        lane1.clear()
        closeTimer = sched.at(sched.now() + CLOSE_FLUSH_MS) { closeNow(reason) }
        pump()
    }

    /** The FrameLink finished the frame in flight (onCharacteristicWrite / onNotificationSent). */
    fun onFrameSent() {
        if (closed) return
        inFlight = false
        stall?.cancel()
        stall = null
        pump()
    }

    /** The MTU changed; the next message uses the new chunk size (the session's pull profile stays). */
    fun onMtu() {
        pump()
    }

    /** The link went away under us (no ERR, no flush). */
    fun linkLost() {
        if (closed) return
        closed = true
        cancelTimers()
    }

    private fun pump() {
        if (closed || inFlight) return
        if (frames.isEmpty()) {
            current = null
            val next = nextMessage() ?: run {
                closing?.let { closeNow(it) }
                return
            }
            current = next
            val mtu = link.mtu().coerceIn(SyncConst.MTU_MIN, SyncConst.MTU_MAX)
            frames.addAll(fragmenter.fragment(next.bytes, mtu))
            messagesSent++
        }
        val f = frames.first()
        inFlight = true
        val ok = try {
            link.writeFrame(f.toByteArray())
        } catch (e: RuntimeException) {
            false
        }
        if (stall == null) stall = sched.at(sched.now() + STALL_MS) { closeNow("stall") }
        if (!ok) {
            inFlight = false
            if (retry == null) {
                retry = sched.at(sched.now() + BUSY_RETRY_MS) {
                    retry = null
                    pump()
                }
            }
            return
        }
        frames.removeFirst()
        framesSent++
    }

    /** Lane 0 first; lane 1 only when lane 0 is empty and the replay budget of this second allows. */
    private fun nextMessage(): Out? {
        val now = sched.now()
        if (now - secStart >= 1000) {
            secStart = now
            evtThisSec = 0
        }
        lane0.removeFirstOrNull()?.let {
            if (it.type == MsgType.EVT) evtThisSec++
            return it
        }
        if (lane1.isEmpty()) return null
        if (evtThisSec >= REPLAY_PER_SEC) {
            if (retry == null) {
                retry = sched.at(secStart + 1000) {
                    retry = null
                    pump()
                }
            }
            return null
        }
        evtThisSec++
        return lane1.removeFirst()
    }

    private fun closeNow(reason: String) {
        if (closed) return
        closed = true
        cancelTimers()
        lane0.clear()
        lane1.clear()
        frames.clear()
        link.close(reason, closeRetryMs)
        onClose?.invoke(reason)
    }

    private fun cancelTimers() {
        stall?.cancel()
        stall = null
        retry?.cancel()
        retry = null
        closeTimer?.cancel()
        closeTimer = null
    }

    // ---- inbound -------------------------------------------------------------------------------

    /** One received ATT value (a copy). */
    fun onFrame(frame: ByteArray) {
        if (closed) return
        framesReceived++
        for (ev in reassembler.feed(Bytes.of(frame))) {
            when (ev) {
                is FrameEvent.Deliver -> {
                    messagesReceived++
                    onMessage(ev.msg)
                    if (closed) return
                }
                is FrameEvent.BadFrame -> {
                    badFrames++
                    lastBadFrame = ev.reason
                    val now = sched.now()
                    if (now - lastBadFrameErr >= BAD_FRAME_ERR_MS) {
                        lastBadFrameErr = now
                        send(MsgType.ERR, Err(ErrCode.BAD_FRAME).encode(), SyncLane.MAIN)
                    }
                }
                is FrameEvent.ErrTooBig -> send(MsgType.ERR, Err(ErrCode.TOO_BIG, ev.refType.takeIf { it in 1..255 }).encode(), SyncLane.MAIN)
                is FrameEvent.ErrProto -> send(MsgType.ERR, Err(ErrCode.PROTO).encode(), SyncLane.MAIN)
            }
        }
    }

    companion object {
        const val STALL_MS: Long = 5000
        const val BUSY_RETRY_MS: Long = 20
        const val CLOSE_FLUSH_MS: Long = 1000
        const val LANE0_CAP: Int = 256
        const val LANE1_CAP: Int = 2000
        const val REPLAY_PER_SEC: Int = 20
        const val BAD_FRAME_ERR_MS: Long = 10_000

        /** A REC whose reqId TLV (0x02) is 0. */
        fun isLiveRec(b: Bytes): Boolean {
            if (b.size < 1 || b[0] != MsgType.REC) return false
            var i = 1
            while (i + 1 < b.size) {
                val tag = b[i]
                val len = b[i + 1]
                if (tag == 0x02) return len == 1 && i + 2 < b.size && b[i + 2] == 0
                if (tag > 0x02) return false
                i += 2 + len
            }
            return false
        }
    }
}
