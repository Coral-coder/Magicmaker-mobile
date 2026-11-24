import Foundation

// GATT framing (docs/SYNC_PROTOCOL.md §9.2, §9.3): a 2-byte header plus a chunk of the message
// per ATT value, and the per-direction reassembler. Vectors: frames, reassembly.

enum SyncFrames {
    /// Header byte 0 bit 5: first frame of a message.
    static let startBit: UInt8 = 0x20
    /// Header byte 0 bit 4: last frame of a message.
    static let endBit: UInt8 = 0x10

    /// chunk = MTU − 3 (ATT) − 2 (header). On iOS use
    /// `maximumWriteValueLength(for: .withoutResponse) − 2` with `fragment(_:chunk:)` instead.
    static func chunkSize(mtu: Int) -> Int {
        let m: Int = min(max(mtu, SyncConst.mtuMin), SyncConst.mtuMax)
        return m - SyncConst.attOverhead - SyncConst.frameHeaderLen
    }
}

/// One per link direction. `counter`: the 4-bit message counter, 0 for the first message after
/// link-up. `seq`: the 8-bit frame sequence, 0 for the first frame after link-up.
struct SyncFragmenter {
    private(set) var counter: UInt8
    private(set) var seq: UInt8

    init(counter: Int = 0, seq: Int = 0) {
        self.counter = UInt8(truncatingIfNeeded: counter) & 0x0F
        self.seq = UInt8(truncatingIfNeeded: seq)
    }

    mutating func fragment(_ msg: [UInt8], mtu: Int) -> [[UInt8]] {
        return fragment(msg, chunk: SyncFrames.chunkSize(mtu: mtu))
    }

    /// The frames of one message (`msg` non-empty), in send order.
    mutating func fragment(_ msg: [UInt8], chunk: Int) -> [[UInt8]] {
        if msg.isEmpty {
            return []
        }
        let n: Int = max(chunk, 1)
        var frames: [[UInt8]] = []
        var i: Int = 0
        while i < msg.count {
            let end: Int = min(i + n, msg.count)
            var b0: UInt8 = (SyncConst.frameVersion << 6) | counter
            if i == 0 {
                b0 |= SyncFrames.startBit
            }
            if end == msg.count {
                b0 |= SyncFrames.endBit
            }
            var frame: [UInt8] = [b0, seq]
            frame.append(contentsOf: msg[i..<end])
            frames.append(frame)
            seq = seq &+ 1
            i = end
        }
        counter = (counter &+ 1) & 0x0F
        return frames
    }
}

/// What feeding one frame to a reassembler produced.
enum SyncFrameEvent: Equatable {
    /// A complete message.
    case deliver([UInt8])
    /// Count BAD_FRAME locally (reasons: short, gap, counter, restart, orphan).
    case badFrame(String)
    /// Send ERR{TOO_BIG, refType}.
    case errTooBig(UInt8)
    /// Send ERR{PROTO} (at most once per link).
    case errProto(UInt8)
}

/// One per link direction (§9.3).
struct SyncReassembler {
    let maxMsg: Int
    /// The frame seq expected next (0 at link-up).
    var expected: UInt8
    private var buf: [UInt8]?
    private var counter: UInt8
    private var skip: Bool
    private var protoSent: Bool

    init(maxMsg: Int, expected: Int = 0) {
        self.maxMsg = maxMsg
        self.expected = UInt8(truncatingIfNeeded: expected)
        self.buf = nil
        self.counter = 0
        self.skip = false
        self.protoSent = false
    }

    mutating func feed(_ frame: [UInt8]) -> [SyncFrameEvent] {
        var acts: [SyncFrameEvent] = []
        if frame.count < SyncConst.frameHeaderLen + 1 {
            return [.badFrame("short")]
        }
        let version: UInt8 = frame[0] >> 6
        if version != SyncConst.frameVersion {
            if !protoSent {
                protoSent = true
                acts.append(.errProto(version))
            }
            return acts
        }
        let start: Bool = (frame[0] & SyncFrames.startBit) != 0
        let end: Bool = (frame[0] & SyncFrames.endBit) != 0
        let ctr: UInt8 = frame[0] & 0x0F
        let fseq: UInt8 = frame[1]
        let chunk: ArraySlice<UInt8> = frame[2..<frame.count]
        if fseq != expected {
            acts.append(.badFrame("gap"))
            buf = nil
            skip = true
        }
        expected = fseq &+ 1
        var partial: [UInt8]
        if start {
            if buf != nil {
                acts.append(.badFrame("restart"))
            }
            partial = Array(chunk)
            counter = ctr
            skip = false
        } else {
            guard let existing = buf else {
                if !skip {
                    acts.append(.badFrame("orphan"))
                }
                return acts
            }
            if ctr != counter {
                acts.append(.badFrame("counter"))
                buf = nil
                skip = true
                return acts
            }
            partial = existing
            partial.append(contentsOf: chunk)
        }
        if partial.count > maxMsg {
            acts.append(.errTooBig(partial[0]))
            buf = nil
            skip = true
            return acts
        }
        if end {
            acts.append(.deliver(partial))
            buf = nil
        } else {
            buf = partial
        }
        return acts
    }
}
