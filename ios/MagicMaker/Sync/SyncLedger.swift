import Foundation

// The phones' ledger (docs/SYNC_PROTOCOL.md §6): apply rules for remote records, local edits
// with the §5.2 stamp and §5.3 normalisation, the learn check, the tombstone cap; and serving a
// PULL from the durable feed (§15.2). The hub uses the same accept rule over its log. Vectors:
// apply, clock (second form), pages.

enum SyncApplyStatus: String {
    case accept = "ACCEPT"
    case duplicate = "DUPLICATE"
    case stale = "STALE"
    case badMsg = "BAD_MSG"
    case clock = "CLOCK"
}

/// One ledger entry (§6.1): the winning verbatim canonical body and its version, the local feed
/// seq `s` and `syncFrom` `f` (nil for local edits and learns).
struct SyncLedgerEntry {
    let key: SyncKey
    let body: [UInt8]
    let fields: SyncBody
    let version: SyncVersion
    let cls: SyncRecordClass
    let seq: Int64
    let syncFrom: [UInt8]?

    /// A decoded, validated body. Throws when `body` is not a valid canonical body.
    init(body: [UInt8], seq: Int64, syncFrom: [UInt8]?) throws {
        let f: SyncBody = try SyncBodyCodec.decode(body)
        self.key = f.key
        self.body = body
        self.fields = f
        self.version = SyncVersion(body: f, bytes: body)
        self.cls = try SyncBodyCodec.validate(f)
        self.seq = seq
        self.syncFrom = syncFrom
    }

    var keyString: String {
        return key.keyString
    }

    var origin: [UInt8]? {
        return fields.origin
    }

    /// DELETED in either namespace (what the tombstone cap counts).
    var isDeleted: Bool {
        return (fields.flags & SyncFlag.deleted) != 0
    }

    var feedEntry: SyncFeedEntry {
        return SyncFeedEntry(seq: seq, body: body, origin: fields.origin, syncFrom: syncFrom)
    }
}

struct SyncApplyResult {
    let status: SyncApplyStatus
    /// ACCEPT: the stored entry (even when the cap evicted it at once). DUPLICATE / STALE: the
    /// current entry. Rejections: nil.
    let entry: SyncLedgerEntry?
    /// Keys the tombstone cap removed, in removal order.
    let evicted: [String]
}

final class SyncLedger {
    private(set) var entries: [String: SyncLedgerEntry] = [:]
    var nextSyncSeq: Int64
    var lastLocalStamp: Int64 = 0
    let tombstoneCap: Int

    init(tombstoneCap: Int = SyncConst.tombstoneCapPhone, nextSyncSeq: Int64 = 1) {
        self.tombstoneCap = tombstoneCap
        self.nextSyncSeq = nextSyncSeq
    }

    func get(_ key: SyncKey) -> SyncLedgerEntry? {
        return entries[key.keyString]
    }

    /// Puts back an entry read from storage (no seq assigned, no cap applied).
    func restore(_ e: SyncLedgerEntry) {
        entries[e.keyString] = e
    }

    var tombstoneCount: Int {
        var n: Int = 0
        for e in entries.values where e.isDeleted {
            n += 1
        }
        return n
    }

    /// Entries sorted by key string (byte order): the vectors' and transcripts' ledger order.
    var sortedByKey: [SyncLedgerEntry] {
        var out: [SyncLedgerEntry] = Array(entries.values)
        out.sort { Array($0.keyString.utf8).lexicographicallyPrecedes(Array($1.keyString.utf8)) }
        return out
    }

    /// Entries sorted by feed seq.
    var sortedBySeq: [SyncLedgerEntry] {
        var out: [SyncLedgerEntry] = Array(entries.values)
        out.sort { $0.seq < $1.seq }
        return out
    }

    /// The current entries as the feed a PULL is served from.
    var feed: [SyncFeedEntry] {
        var out: [SyncFeedEntry] = []
        for e in entries.values {
            out.append(e.feedEntry)
        }
        return out
    }

    private func store(_ body: [UInt8], syncFrom: [UInt8]?) throws -> (entry: SyncLedgerEntry, evicted: [String]) {
        let e: SyncLedgerEntry = try SyncLedgerEntry(body: body, seq: nextSyncSeq, syncFrom: syncFrom)
        nextSyncSeq += 1
        entries[e.keyString] = e
        var evicted: [String] = []
        if e.isDeleted {
            evicted = evictTombstones()
        }
        return (e, evicted)
    }

    /// Smallest version first; ties: smallest encoded key bytes.
    private static func evictsBefore(_ a: SyncLedgerEntry, _ b: SyncLedgerEntry) -> Bool {
        if a.version != b.version {
            return a.version < b.version
        }
        return a.key.encoded.lexicographicallyPrecedes(b.key.encoded)
    }

    private func evictTombstones() -> [String] {
        var tombs: [SyncLedgerEntry] = []
        for e in entries.values where e.isDeleted {
            tombs.append(e)
        }
        var evicted: [String] = []
        while tombs.count > tombstoneCap {
            var best: Int = 0
            var i: Int = 1
            while i < tombs.count {
                if SyncLedger.evictsBefore(tombs[i], tombs[best]) {
                    best = i
                }
                i += 1
            }
            let oldest: SyncLedgerEntry = tombs.remove(at: best)
            entries.removeValue(forKey: oldest.keyString)
            evicted.append(oldest.keyString)
        }
        return evicted
    }

    /// §6.2 apply of a received record from peer `sender`. `nowMs` nil = the receiver does not
    /// know the time (no future check).
    func applyRemote(_ body: [UInt8], from sender: [UInt8]?, nowMs: Int64?) -> SyncApplyResult {
        let f: SyncBody
        do {
            f = try SyncBodyCodec.decode(body)
            try SyncBodyCodec.checkFuture(f.updatedAt, nowMs: nowMs)
        } catch let e as SyncError {
            let status: SyncApplyStatus = e.code == SyncErrorCode.clock ? .clock : .badMsg
            return SyncApplyResult(status: status, entry: nil, evicted: [])
        } catch {
            return SyncApplyResult(status: .badMsg, entry: nil, evicted: [])
        }
        let v: SyncVersion = SyncVersion(body: f, bytes: body)
        if let cur = get(f.key) {
            let c: Int = SyncVersion.compare(v, cur.version)
            if c == 0 {
                return SyncApplyResult(status: .duplicate, entry: cur, evicted: [])
            }
            if c < 0 {
                return SyncApplyResult(status: .stale, entry: cur, evicted: [])
            }
        }
        guard let stored = try? store(body, syncFrom: sender) else {
            return SyncApplyResult(status: .badMsg, entry: nil, evicted: [])
        }
        return SyncApplyResult(status: .accept, entry: stored.entry, evicted: stored.evicted)
    }

    /// A learn path met a library packet (§6.3): a PRESENCE entry only when the key has no entry at
    /// all (a tombstone or any version blocks it). nil when blocked. Throws for a bad packet.
    func localLearn(packet: [UInt8]) throws -> SyncLedgerEntry? {
        let key: SyncKey = SyncKey(ns: SyncNs.lib, packet: packet)
        if get(key) != nil {
            return nil
        }
        let body: [UInt8] = try SyncBodyCodec.encode(SyncBody(key: key, updatedAt: SyncConst.uPresence))
        return try store(body, syncFrom: nil).entry
    }

    /// A user edit (§5.2, §5.3, §6.4). `cls`: USER (label required; RESET is the caller's choice
    /// for a blank label), RESET (note only), TOMBSTONE, or NEWWAND (a blank label deletes the
    /// name). Text is normalised here. Returns the stored entry (it may have been evicted at once
    /// by the cap: check `evicted`).
    func localEdit(_ cls: SyncRecordClass, key: SyncKey, nowMs: Int64, selfId: [UInt8], label: String? = nil,
                   category: UInt8? = nil, kind: String? = nil, place: UInt8? = nil, note: String? = nil,
                   preset: Bool = false, userEdited: Bool = true) throws -> (entry: SyncLedgerEntry, evicted: [String]) {
        let cur: SyncLedgerEntry? = get(key)
        let u: Int64 = SyncStamp.local(nowMs: nowMs, ledgerUpdatedAt: cur?.version.updatedAt ?? 0,
                                       lastLocalStamp: lastLocalStamp)
        var b: SyncBody = SyncBody(key: key, updatedAt: u, origin: selfId)
        let nlabel: String? = label.flatMap { SyncText.normalizeLabel($0) }
        let nnote: String? = note.flatMap { SyncText.normalizeNote($0) }
        let nkind: String? = kind.flatMap { SyncText.normalizeKind($0) }
        switch cls {
        case .user:
            if key.ns != SyncNs.lib || nlabel == nil {
                throw SyncError.badMsg("edit")
            }
            b.flags = (userEdited ? SyncFlag.userEdited : 0) | (preset ? SyncFlag.preset : 0)
            if b.flags == 0 {
                throw SyncError.badMsg("edit")
            }
            b.label = nlabel
            b.category = category
            b.kind = nkind
            b.place = place
            b.note = nnote
        case .reset:
            if key.ns != SyncNs.lib {
                throw SyncError.badMsg("edit")
            }
            b.note = nnote
        case .tombstone:
            b.flags = SyncFlag.deleted
        case .newWand:
            if key.ns != SyncNs.newWand {
                throw SyncError.badMsg("edit")
            }
            if let l = nlabel {
                b.label = l
                b.note = nnote
            } else {
                b.flags = SyncFlag.deleted
            }
        case .presence:
            throw SyncError.badMsg("edit")
        }
        let body: [UInt8] = try SyncBodyCodec.encode(b)
        lastLocalStamp = u
        return try store(body, syncFrom: nil)
    }
}

/// One current feed entry as a server sees it: seq, verbatim body, the body's origin, syncFrom.
struct SyncFeedEntry {
    let seq: Int64
    let body: [UInt8]
    let origin: [UInt8]?
    let syncFrom: [UInt8]?

    init(seq: Int64, body: [UInt8], origin: [UInt8]?, syncFrom: [UInt8]?) {
        self.seq = seq
        self.body = body
        self.origin = origin
        self.syncFrom = syncFrom
    }
}

/// PAGE_END fields (§11.5).
struct SyncPageEnd: Equatable {
    let reqId: Int64
    let scannedTo: Int64
    let more: Int64
    let feedHigh: Int64
    let count: Int64

    var fields: [String: SyncValue] {
        return ["reqId": .int(reqId), "scannedTo": .int(scannedTo), "more": .int(more),
                "feedHigh": .int(feedHigh), "count": .int(count)]
    }

    func encode() throws -> [UInt8] {
        return try SyncMessageCodec.encode(type: SyncMsgType.pageEnd, fields: fields)
    }
}

enum SyncFeed {
    /// §15.2 durable-only page serving. `entries`: the current entry of each key (superseded ones
    /// absent). Exclusion skips (but still scans) entries whose origin or syncFrom is the puller.
    /// Returns the REC messages to send, in order, then the PAGE_END.
    static func servePage(entries: [SyncFeedEntry], durableHigh: Int64, since: Int64, limit: Int64,
                          maxBytes: Int64, excludeActive: Bool, puller: [UInt8],
                          reqId: Int64) throws -> (recs: [[UInt8]], pageEnd: SyncPageEnd) {
        var recs: [[UInt8]] = []
        var used: Int64 = 0
        var scanned: Int64 = since
        if since < durableHigh {
            var window: [SyncFeedEntry] = []
            for e in entries where e.seq > since && e.seq <= durableHigh {
                window.append(e)
            }
            window.sort { $0.seq < $1.seq }
            for e in window {
                if excludeActive {
                    let fromPuller: Bool = (e.origin != nil && e.origin == puller)
                        || (e.syncFrom != nil && e.syncFrom == puller)
                    if fromPuller {
                        scanned = e.seq
                        continue
                    }
                }
                let msg: [UInt8] = try SyncMessageCodec.rec(seq: e.seq, reqId: reqId, body: e.body)
                if Int64(recs.count) >= limit {
                    break
                }
                if !recs.isEmpty && used + Int64(msg.count) > maxBytes {
                    break
                }
                recs.append(msg)
                used += Int64(msg.count)
                scanned = e.seq
            }
        }
        let more: Int64 = scanned < durableHigh ? 1 : 0
        let pe: SyncPageEnd = SyncPageEnd(reqId: reqId, scannedTo: scanned, more: more, feedHigh: durableHigh,
                                          count: Int64(recs.count))
        return (recs, pe)
    }
}
