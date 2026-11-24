import Foundation

// Heard-packet events (docs/SYNC_PROTOCOL.md §8): the iPhone's per-origin dedupe windows and
// EVT_GAP handling, and Android's replay plan. Vectors: eventDedupe, replayPlan.

enum SyncEvtResult: String {
    case accept = "ACCEPT"
    case duplicate = "DUPLICATE"
}

/// `{epoch, hc, bits}`: hc = highest contiguous seq received; bit i of `bits` = seq hc + 1 + i
/// received (§8.2). A class, so the dedupe table mutates windows in place.
final class SyncEvtWindow {
    let epoch: Int64
    private(set) var hc: Int64
    private(set) var bits: UInt64

    init(epoch: Int64, hc: Int64 = 0, bits: UInt64 = 0) {
        self.epoch = epoch
        self.hc = hc
        self.bits = bits
    }

    /// While bit 0 is set: hc += 1, bits >>= 1.
    func normalize() {
        while (bits & 1) != 0 {
            hc += 1
            bits >>= 1
        }
    }

    /// Moves hc up to `floor`; returns how many seqs in (hc, floor] were never received.
    @discardableResult
    func advanceFloor(_ floor: Int64) -> Int64 {
        if floor <= hc {
            return 0
        }
        let shift: Int64 = floor - hc
        let got: Int64
        if shift >= SyncConst.evtWindowBits {
            got = Int64(bits.nonzeroBitCount)
            bits = 0
        } else {
            let mask: UInt64 = (UInt64(1) << UInt64(shift)) &- 1
            got = Int64((bits & mask).nonzeroBitCount)
            bits >>= UInt64(shift)
        }
        hc = floor
        normalize()
        return shift - got
    }

    /// Marks seq received if it is new. `seq` must be in hc + 1 ... hc + 64.
    fileprivate func mark(_ seq: Int64) -> Bool {
        let offset: Int64 = seq - hc - 1
        if offset < 0 || offset >= SyncConst.evtWindowBits {
            return false
        }
        let idx: UInt64 = UInt64(offset)
        if ((bits >> idx) & 1) != 0 {
            return false
        }
        bits |= UInt64(1) << idx
        normalize()
        return true
    }
}

/// One EVT_SINCE the iPhone should send: `{origin, epoch, afterSeq}`.
struct SyncEvtSinceRequest: Equatable {
    let epoch: Int64
    let afterSeq: Int64
}

/// The iPhone's receiver state: per origin, the windows of the two newest epochs (§8.2).
final class SyncEvtDedupe {
    private(set) var byOrigin: [[UInt8]: [SyncEvtWindow]] = [:]

    init() {}

    /// That origin's windows, oldest first.
    func windows(_ origin: [UInt8]) -> [SyncEvtWindow] {
        return byOrigin[origin] ?? []
    }

    func window(_ origin: [UInt8], epoch: Int64) -> SyncEvtWindow? {
        for w in windows(origin) where w.epoch == epoch {
            return w
        }
        return nil
    }

    /// The newest window of an origin (the one EVT_SINCE and HB evtWm describe, §8.3).
    func newest(_ origin: [UInt8]) -> SyncEvtWindow? {
        return windows(origin).last
    }

    /// Origins with at least one window, in byte order.
    var origins: [[UInt8]] {
        var out: [[UInt8]] = Array(byOrigin.keys)
        out.sort { $0.lexicographicallyPrecedes($1) }
        return out
    }

    @discardableResult
    private func open(_ origin: [UInt8], epoch: Int64, hc: Int64) -> SyncEvtWindow {
        var ws: [SyncEvtWindow] = byOrigin[origin] ?? []
        let w: SyncEvtWindow = SyncEvtWindow(epoch: epoch, hc: hc)
        ws.append(w)
        ws.sort { $0.epoch < $1.epoch }
        while ws.count > SyncConst.evtEpochsKept {
            ws.removeFirst()
        }
        byOrigin[origin] = ws
        return w
    }

    /// §8.2 receive: ACCEPT or DUPLICATE, plus the seqs counted lost by a slide.
    func receive(origin: [UInt8], epoch: Int64, seq: Int64) -> (result: SyncEvtResult, lost: Int64) {
        let ws: [SyncEvtWindow] = windows(origin)
        var found: SyncEvtWindow? = window(origin, epoch: epoch)
        if found == nil {
            if ws.isEmpty {
                found = open(origin, epoch: epoch, hc: seq - 1)  // first contact: no history
            } else if let last = ws.last, epoch > last.epoch {
                found = open(origin, epoch: epoch, hc: 0)  // new epoch: from seq 1
            } else {
                return (.duplicate, 0)  // older than the kept epochs
            }
        }
        guard let w = found else {
            return (.duplicate, 0)
        }
        if seq <= w.hc {
            return (.duplicate, 0)
        }
        var lost: Int64 = 0
        if seq > w.hc + SyncConst.evtWindowBits {
            lost = w.advanceFloor(seq - SyncConst.evtWindowBits)
        }
        if !w.mark(seq) {
            return (.duplicate, lost)
        }
        return (.accept, lost)
    }

    /// After an ACCEPT: bits ≠ 0 means a seq jump (holes).
    func hasHoles(origin: [UInt8], epoch: Int64) -> Bool {
        guard let w = window(origin, epoch: epoch) else {
            return false
        }
        return w.bits != 0
    }

    /// §8.4 EVT_GAP handling: the seqs counted lost and the EVT_SINCE requests to send.
    func onGap(origin: [UInt8], epoch: Int64, firstAvail: Int64, lastAvail: Int64,
               curEpoch: Int64) -> (lost: Int64, requests: [SyncEvtSinceRequest]) {
        var reqs: [SyncEvtSinceRequest] = []
        var lost: Int64 = 0
        let w: SyncEvtWindow? = window(origin, epoch: epoch)
        if firstAvail > 0 {
            if let win = w, firstAvail > win.hc + 1 {
                lost = win.advanceFloor(firstAvail - 1)
                reqs.append(SyncEvtSinceRequest(epoch: epoch, afterSeq: win.hc))
            }
        } else if curEpoch > epoch {
            var wc: SyncEvtWindow? = window(origin, epoch: curEpoch)
            if wc == nil {
                let newestWindow: SyncEvtWindow? = newest(origin)
                if newestWindow == nil || curEpoch > (newestWindow?.epoch ?? 0) {
                    wc = open(origin, epoch: curEpoch, hc: 0)
                }
            }
            if let c = wc {
                reqs.append(SyncEvtSinceRequest(epoch: curEpoch, afterSeq: c.hc))
            }
        }
        return (lost, reqs)
    }
}

/// One item of Android's answer to a catch-up request, in send order (§8.5).
enum SyncReplayStep: Equatable {
    /// Re-send the ring's EVT (epoch, seq) with flags.replay.
    case replay(epoch: Int64, seq: Int64)
    /// Send EVT_GAP.
    case gap(epoch: Int64, firstAvail: Int64, lastAvail: Int64, curEpoch: Int64)
}

enum SyncReplay {
    /// Android's plan for a catch-up request `(epoch, afterSeq)` (EVT_SINCE, or an iPhone HB evtWm
    /// entry that is behind). `ring` = the (epoch, seq) of the stored EVTs, oldest first.
    static func plan(ring: [(epoch: Int64, seq: Int64)], curEpoch: Int64, curSeq: Int64, epoch: Int64,
                     afterSeq: Int64) -> [SyncReplayStep] {
        func seqs(_ ep: Int64) -> [Int64] {
            var out: [Int64] = []
            for item in ring where item.epoch == ep {
                out.append(item.seq)
            }
            return out
        }

        func gapStep(_ ep: Int64, _ qs: [Int64]) -> SyncReplayStep {
            return .gap(epoch: ep, firstAvail: qs.min() ?? 0, lastAvail: qs.max() ?? 0, curEpoch: curEpoch)
        }

        func planCur(_ s: Int64) -> [SyncReplayStep] {
            if s >= curSeq {
                return []
            }
            let qs: [Int64] = seqs(curEpoch)
            if qs.contains(s + 1) {
                var out: [SyncReplayStep] = []
                for q in qs where q > s {
                    out.append(.replay(epoch: curEpoch, seq: q))
                }
                return out
            }
            return [gapStep(curEpoch, qs)]
        }

        if epoch > curEpoch {
            return []
        }
        if epoch == curEpoch {
            return planCur(afterSeq)
        }
        let qs: [Int64] = seqs(epoch)
        if !qs.isEmpty && qs.contains(afterSeq + 1) {
            var out: [SyncReplayStep] = []
            for q in qs where q > afterSeq {
                out.append(.replay(epoch: epoch, seq: q))
            }
            out.append(contentsOf: planCur(0))
            return out
        }
        if let top = qs.max(), afterSeq >= top {
            return planCur(0)
        }
        return [gapStep(epoch, qs)]
    }
}
