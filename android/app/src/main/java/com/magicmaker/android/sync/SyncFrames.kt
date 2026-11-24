package com.magicmaker.android.sync

/**
 * GATT framing (§9.2): each ATT value is `[ver 2b | START | END | counter 4b][frame seq][chunk]`.
 * One [Fragmenter] per link direction; counter and seq start at 0 at link-up.
 */
class Fragmenter(counter: Int = 0, seq: Int = 0) {
    /** 4-bit message counter of the next message. */
    var counter: Int = counter and 0x0F
        private set

    /** 8-bit frame seq of the next frame. */
    var seq: Int = seq and 0xFF
        private set

    /** Split [msg] into frames for [mtu]; consumes one counter and one seq per frame. */
    fun fragment(msg: Bytes, mtu: Int): List<Bytes> {
        require(msg.size >= 1) { "empty message" }
        val n = SyncFrames.chunkSize(mtu)
        val count = (msg.size + n - 1) / n
        val out = ArrayList<Bytes>(count)
        for (k in 0 until count) {
            var b0 = (SyncConst.FRAME_VERSION shl 6) or counter
            if (k == 0) b0 = b0 or SyncFrames.FR_START
            if (k == count - 1) b0 = b0 or SyncFrames.FR_END
            out.add(Bytes.of(b0, seq) + msg.slice(k * n, minOf(msg.size, (k + 1) * n)))
            seq = (seq + 1) and 0xFF
        }
        counter = (counter + 1) and 0x0F
        return out
    }
}

/** What feeding one frame to a [Reassembler] produced (§9.3). */
sealed class FrameEvent {
    /** A whole message. */
    data class Deliver(val msg: Bytes) : FrameEvent()

    /** Count BAD_FRAME locally; [reason]: short, gap, counter, restart, orphan. */
    data class BadFrame(val reason: String) : FrameEvent()

    /** Send `ERR{TOO_BIG, refType}` ([refType] = first byte of the dropped partial). */
    data class ErrTooBig(val refType: Int) : FrameEvent()

    /** Send `ERR{PROTO}` (first other-version frame on this link). */
    data class ErrProto(val frameVersion: Int) : FrameEvent()
}

/** One per link direction (§9.3). */
class Reassembler(val maxMsg: Int) {
    /** The frame seq expected next (0 at link-up). */
    var expected: Int = 0

    private var buf: ByteWriter? = null
    private var bufFirst: Int = 0
    private var counter: Int = -1
    private var skip: Boolean = false
    private var protoSent: Boolean = false

    fun feed(frame: Bytes): List<FrameEvent> {
        if (frame.size < SyncConst.FRAME_HEADER_LEN + 1) return listOf(FrameEvent.BadFrame("short"))
        val acts = ArrayList<FrameEvent>(2)
        val ver = frame[0] ushr 6
        if (ver != SyncConst.FRAME_VERSION) {
            if (!protoSent) {
                protoSent = true
                acts.add(FrameEvent.ErrProto(ver))
            }
            return acts
        }
        val start = frame[0] and SyncFrames.FR_START != 0
        val end = frame[0] and SyncFrames.FR_END != 0
        val ctr = frame[0] and 0x0F
        val fseq = frame[1]
        val chunk = frame.slice(2)
        if (fseq != expected) {
            acts.add(FrameEvent.BadFrame("gap"))
            buf = null
            skip = true
        }
        expected = (fseq + 1) and 0xFF
        if (start) {
            if (buf != null) acts.add(FrameEvent.BadFrame("restart"))
            buf = ByteWriter(maxOf(64, chunk.size)).bytes(chunk)
            bufFirst = chunk[0] // a frame of >= 3 bytes carries >= 1 chunk byte
            counter = ctr
            skip = false
        } else {
            val b = buf
            if (b == null) {
                if (!skip) acts.add(FrameEvent.BadFrame("orphan"))
                return acts
            }
            if (ctr != counter) {
                acts.add(FrameEvent.BadFrame("counter"))
                buf = null
                skip = true
                return acts
            }
            b.bytes(chunk)
        }
        val b = buf!!
        if (b.size > maxMsg) {
            acts.add(FrameEvent.ErrTooBig(bufFirst))
            buf = null
            skip = true
            return acts
        }
        if (end) {
            acts.add(FrameEvent.Deliver(b.toBytes()))
            buf = null
        }
        return acts
    }
}

object SyncFrames {
    const val FR_START: Int = 0x20
    const val FR_END: Int = 0x10

    /** chunk = MTU − 3 (ATT) − 2 (header); MTU 23..517. */
    fun chunkSize(mtu: Int): Int {
        require(mtu in SyncConst.MTU_MIN..SyncConst.MTU_MAX) { "MTU $mtu out of 23..517" }
        return mtu - SyncConst.ATT_OVERHEAD - SyncConst.FRAME_HEADER_LEN
    }
}
