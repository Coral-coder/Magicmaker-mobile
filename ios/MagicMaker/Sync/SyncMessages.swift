import Foundation

// Message TLV codec for every SYNC v1 message (docs/SYNC_PROTOCOL.md §10, §11). One spec table
// drives decoding (tag order, repeats, unknown tags, widths, ranges, mandatory sets) and the
// canonical encoding. A decoded message keeps exactly the fields present on the wire (no defaults
// filled in), so decode -> encode normalises explicit defaults and unknown tags away. Vectors:
// messages, messageNonCanonical, messageRejects, messageBadBody, messageIgnored, hbHops.

/// One HB `link` entry: `peerId 8 ‖ peerKind u8 (1..3) ‖ flags u8` (§11.8).
struct SyncHbLink: Equatable {
    let peerId: [UInt8]
    let peerKind: UInt8
    let flags: UInt8
}

/// One HB `evtWm` entry: `origin 8 ‖ epoch u32 ‖ seq u32` (§11.8).
struct SyncEvtWm: Equatable {
    let origin: [UInt8]
    let epoch: Int64
    let seq: Int64
}

/// A decoded field value. Every integer is an Int64 (u32 and i64 both fit).
enum SyncValue: Equatable {
    case int(Int64)
    case bytes([UInt8])
    case text(String)
    case key(SyncKey)
    case link(SyncHbLink)
    case evtWm(SyncEvtWm)
    /// A repeatable tag: the values in wire order.
    case list([SyncValue])

    /// Text compares by its UTF-8 bytes (String == would use canonical equivalence).
    static func == (a: SyncValue, b: SyncValue) -> Bool {
        switch (a, b) {
        case (.int(let x), .int(let y)):
            return x == y
        case (.bytes(let x), .bytes(let y)):
            return x == y
        case (.text(let x), .text(let y)):
            return Array(x.utf8) == Array(y.utf8)
        case (.key(let x), .key(let y)):
            return x == y
        case (.link(let x), .link(let y)):
            return x == y
        case (.evtWm(let x), .evtWm(let y)):
            return x == y
        case (.list(let x), .list(let y)):
            return x == y
        default:
            return false
        }
    }
}

/// One message: its type and the fields present on the wire, by the §11 field names. A REC also
/// carries its verbatim body bytes and, after decoding, the decoded body or why it is invalid.
struct SyncMessage {
    let type: UInt8
    var fields: [String: SyncValue]
    /// REC only: the body TLVs (0x10..0x1F), verbatim, in order of appearance.
    var body: [UInt8]
    /// REC only, after decoding: the body when it is valid.
    var bodyFields: SyncBody?
    /// REC only, after decoding: why the body is invalid (BAD_MSG or CLOCK). The envelope is still
    /// valid, so the REC counts toward its page (§11.4).
    var bodyError: SyncError?

    init(type: UInt8, fields: [String: SyncValue] = [:], body: [UInt8] = []) {
        self.type = type
        self.fields = fields
        self.body = body
        self.bodyFields = nil
        self.bodyError = nil
    }

    var typeName: String {
        return SyncMsgType.name(type)
    }

    func has(_ name: String) -> Bool {
        return fields[name] != nil
    }

    func int(_ name: String) -> Int64? {
        if case .int(let v)? = fields[name] {
            return v
        }
        return nil
    }

    func bytes(_ name: String) -> [UInt8]? {
        if case .bytes(let v)? = fields[name] {
            return v
        }
        return nil
    }

    func text(_ name: String) -> String? {
        if case .text(let v)? = fields[name] {
            return v
        }
        return nil
    }

    func key(_ name: String) -> SyncKey? {
        if case .key(let v)? = fields[name] {
            return v
        }
        return nil
    }

    /// The values of a repeatable field (empty when absent).
    func list(_ name: String) -> [SyncValue] {
        if case .list(let v)? = fields[name] {
            return v
        }
        return []
    }

    /// The byte values of a repeatable byte field (seenBy).
    func bytesList(_ name: String) -> [[UInt8]] {
        var out: [[UInt8]] = []
        for v in list(name) {
            if case .bytes(let b) = v {
                out.append(b)
            }
        }
        return out
    }

    func links() -> [SyncHbLink] {
        var out: [SyncHbLink] = []
        for v in list("link") {
            if case .link(let l) = v {
                out.append(l)
            }
        }
        return out
    }

    func evtWms() -> [SyncEvtWm] {
        var out: [SyncEvtWm] = []
        for v in list("evtWm") {
            if case .evtWm(let w) = v {
                out.append(w)
            }
        }
        return out
    }
}

enum SyncFieldType {
    case u8, u16, u32, i8, i16, i32, i64
    /// Fixed-size byte string (`size` bytes).
    case bytes
    /// UTF-8, 1..`size` bytes.
    case str
    /// 3..29 bytes starting 83 01.
    case packet
    /// ns ‖ packet.
    case key
    case link
    case evtWm

    /// Width of an integer type in bytes; 0 for the others.
    var intWidth: Int {
        switch self {
        case .u8, .i8:
            return 1
        case .u16, .i16:
            return 2
        case .u32, .i32:
            return 4
        case .i64:
            return 8
        default:
            return 0
        }
    }

    var isSigned: Bool {
        switch self {
        case .i8, .i16, .i32, .i64:
            return true
        default:
            return false
        }
    }
}

/// Field spec: tag, name, type, mandatory, repeat max (0 = not repeatable), default, range, size.
struct SyncFieldSpec {
    let tag: UInt8
    let name: String
    let type: SyncFieldType
    let mandatory: Bool
    let repeatMax: Int
    let defaultValue: Int64?
    let lo: Int64?
    let hi: Int64?
    let size: Int

    init(_ tag: UInt8, _ name: String, _ type: SyncFieldType, mand: Bool = false, rep: Int = 0,
         def: Int64? = nil, lo: Int64? = nil, hi: Int64? = nil, size: Int = 0) {
        self.tag = tag
        self.name = name
        self.type = type
        self.mandatory = mand
        self.repeatMax = rep
        self.defaultValue = def
        self.lo = lo
        self.hi = hi
        self.size = size
    }
}

enum SyncMessageCodec {
    static let recBodyTagLo: UInt8 = 0x10
    static let recBodyTagHi: UInt8 = 0x1F
    /// HB tag whose value a forwarder patches (§16.4).
    static let hbHopsTag: UInt8 = 0x0F

    private typealias S = SyncFieldSpec

    /// The §11 field tables, in tag order.
    static let specs: [UInt8: [SyncFieldSpec]] = [
        SyncMsgType.hello: [
            S(0x01, "proto", .u8, mand: true),
            S(0x02, "deviceId", .bytes, mand: true, size: 8),
            S(0x03, "kind", .u8, mand: true, lo: 1, hi: 3),
            S(0x04, "dbId", .bytes, mand: true, size: 8),
            S(0x05, "clockMs", .i64, mand: true, lo: 0),
            S(0x06, "feedHigh", .u32, mand: true),
            S(0x07, "subs", .u8, mand: true),
            S(0x08, "caps", .u16, def: 0),
            S(0x09, "maxMsg", .u16, mand: true, lo: Int64(SyncConst.maxMsgMin)),
            S(0x0A, "bootId", .u16, mand: true),
            S(0x0B, "version", .str, size: 16),
            S(0x0C, "name", .str, size: 20),
            S(0x0D, "groupId", .bytes, mand: true, size: 8),
            S(0x0E, "nonce", .bytes, mand: true, size: 8),
            S(0x0F, "proof", .bytes, size: 16),
        ],
        SyncMsgType.pull: [
            S(0x01, "reqId", .u8, mand: true, lo: 1, hi: 255),
            S(0x02, "since", .u32, mand: true),
            S(0x03, "limit", .u8, def: SyncConst.pullLimitDefault, lo: 1, hi: SyncConst.pullLimitMax),
            S(0x04, "maxBytes", .u16, def: SyncConst.pullMaxBytesDefault, lo: SyncConst.pullMaxBytesMin,
              hi: SyncConst.pullMaxBytesMax),
            S(0x05, "dbId", .bytes, mand: true, size: 8),
            S(0x06, "exclude", .u8, def: 0, lo: 0, hi: 1),
        ],
        SyncMsgType.rec: [
            S(0x01, "seq", .u32, mand: true),
            S(0x02, "reqId", .u8, mand: true),
            S(0x03, "seenBy", .bytes, rep: SyncConst.seenByMax, size: 8),
        ],
        SyncMsgType.pageEnd: [
            S(0x01, "reqId", .u8, mand: true, lo: 1, hi: 255),
            S(0x02, "scannedTo", .u32, mand: true),
            S(0x03, "more", .u8, mand: true, lo: 0, hi: 1),
            S(0x04, "feedHigh", .u32, mand: true),
            S(0x05, "count", .u8, mand: true),
        ],
        SyncMsgType.evt: [
            S(0x01, "origin", .bytes, mand: true, size: 8),
            S(0x02, "epoch", .u32, mand: true, lo: 1),
            S(0x03, "seq", .u32, mand: true, lo: 1),
            S(0x04, "ts", .i64, mand: true, lo: 0),
            S(0x05, "packet", .packet, mand: true),
            S(0x06, "rssi", .i8),
            S(0x07, "count", .u16, def: 1, lo: 1),
            S(0x08, "lat", .i32, lo: -900_000_000, hi: 900_000_000),
            S(0x09, "lon", .i32, lo: -1_800_000_000, hi: 1_800_000_000),
            S(0x0A, "acc", .u16),
            S(0x0B, "addr", .bytes, size: 6),
            S(0x0C, "flags", .u8, def: 0),
            S(0x0D, "seenBy", .bytes, rep: SyncConst.seenByMax, size: 8),
        ],
        SyncMsgType.evtSince: [
            S(0x01, "origin", .bytes, mand: true, size: 8),
            S(0x02, "epoch", .u32, mand: true),
            S(0x03, "afterSeq", .u32, mand: true),
            S(0x04, "requester", .bytes, mand: true, size: 8),
        ],
        SyncMsgType.evtGap: [
            S(0x01, "origin", .bytes, mand: true, size: 8),
            S(0x02, "epoch", .u32, mand: true),
            S(0x03, "firstAvail", .u32, mand: true),
            S(0x04, "lastAvail", .u32, mand: true),
            S(0x05, "curEpoch", .u32, mand: true),
            S(0x06, "requester", .bytes, mand: true, size: 8),
        ],
        SyncMsgType.hb: [
            S(0x01, "deviceId", .bytes, mand: true, size: 8),
            S(0x02, "kind", .u8, mand: true, lo: 1, hi: 3),
            S(0x03, "bootId", .u16, mand: true),
            S(0x04, "hbSeq", .u32, mand: true),
            S(0x05, "ts", .i64, mand: true, lo: 0),
            S(0x06, "uptimeS", .u32, mand: true),
            S(0x07, "battPct", .i8, def: -1, lo: -1, hi: 100),
            S(0x08, "battMv", .i16, def: -1, lo: -1),
            S(0x09, "charging", .i8, def: -1, lo: -1, hi: 1),
            S(0x0A, "runtimeMin", .i16, def: -1, lo: -1, hi: 5999),
            S(0x0B, "version", .str, size: 16),
            S(0x0C, "name", .str, size: 20),
            S(0x0D, "link", .link, rep: SyncConst.hbLinksMax),
            S(0x0E, "state", .u16, def: 0),
            S(0x0F, "hops", .u8, mand: true, lo: 0, hi: 1),
            S(0x10, "feedHigh", .u32, mand: true),
            S(0x11, "dbId", .bytes, mand: true, size: 8),
            S(0x12, "records", .u32, mand: true),
            S(0x13, "hubAirAgoS", .u16),
            S(0x14, "evtWm", .evtWm, rep: SyncConst.hbEvtWmMax),
        ],
        SyncMsgType.sub: [
            S(0x01, "subs", .u8, mand: true),
        ],
        SyncMsgType.err: [
            S(0x01, "code", .u8, mand: true, lo: 1),
            S(0x02, "refType", .u8),
            S(0x03, "key", .key),
            S(0x04, "detail", .str, size: 40),
            S(0x05, "dbId", .bytes, size: 8),
            S(0x06, "retryMs", .u16),
        ],
        SyncMsgType.auth: [
            S(0x01, "proof", .bytes, mand: true, size: 16),
        ],
        SyncMsgType.join: [
            S(0x01, "groupId", .bytes, mand: true, size: 8),
            S(0x02, "groupKey", .bytes, mand: true, size: 16),
            S(0x03, "flags", .u8, def: 0),
        ],
    ]

    static let specByTag: [UInt8: [UInt8: SyncFieldSpec]] = {
        var out: [UInt8: [UInt8: SyncFieldSpec]] = [:]
        for (type, list) in specs {
            var byTag: [UInt8: SyncFieldSpec] = [:]
            for s in list {
                byTag[s.tag] = s
            }
            out[type] = byTag
        }
        return out
    }()

    /// Whether `type` is a v1 message type (others are ignored, §10 rule 2).
    static func isKnownType(_ type: UInt8) -> Bool {
        return specs[type] != nil
    }

    /// The §17 pre-check: a HELLO whose first TLV is `01 01 xx` with xx ≠ proto.
    static func isHelloOtherProto(_ data: [UInt8]) -> Bool {
        return data.count >= 4 && data[0] == SyncMsgType.hello && data[1] == 0x01 && data[2] == 1
            && data[3] != SyncConst.proto
    }

    // MARK: Decoding

    private static func decodeValue(_ spec: SyncFieldSpec, _ v: [UInt8]) throws -> SyncValue {
        let t: SyncFieldType = spec.type
        let width: Int = t.intWidth
        if width > 0 {
            if v.count != width {
                throw SyncError.badMsg("length")
            }
            let n: Int64 = SyncLE.read(v, signed: t.isSigned)
            if let lo = spec.lo, n < lo {
                throw SyncError.badMsg("range")
            }
            if let hi = spec.hi, n > hi {
                throw SyncError.badMsg("range")
            }
            return .int(n)
        }
        switch t {
        case .bytes:
            if v.count != spec.size {
                throw SyncError.badMsg("length")
            }
            return .bytes(v)
        case .str:
            if v.count < 1 || v.count > spec.size {
                throw SyncError.badMsg("length")
            }
            if !SyncUtf8.isValid(v) {
                throw SyncError.badMsg("utf8")
            }
            return .text(SyncUtf8.string(v))
        case .packet:
            if v.count < SyncConst.packetMin || v.count > SyncConst.packetMax {
                throw SyncError.badMsg("length")
            }
            try SyncKey.checkPacket(v)
            return .bytes(v)
        case .key:
            return .key(try SyncKey.decode(v))
        case .link:
            if v.count != 10 {
                throw SyncError.badMsg("length")
            }
            if v[8] < 1 || v[8] > 3 {
                throw SyncError.badMsg("range")
            }
            return .link(SyncHbLink(peerId: Array(v[0..<8]), peerKind: v[8], flags: v[9]))
        case .evtWm:
            if v.count != 16 {
                throw SyncError.badMsg("length")
            }
            let epoch: Int64 = SyncLE.read(Array(v[8..<12]), signed: false)
            let seq: Int64 = SyncLE.read(Array(v[12..<16]), signed: false)
            return .evtWm(SyncEvtWm(origin: Array(v[0..<8]), epoch: epoch, seq: seq))
        default:
            throw SyncError.badMsg("type")
        }
    }

    /// Message bytes -> message. nil for an unknown message type (the caller ignores it, no ERR).
    /// Throws BAD_MSG on any envelope error. A REC whose body is invalid still decodes: see
    /// `bodyError`.
    static func decode(_ data: [UInt8]) throws -> SyncMessage? {
        if data.isEmpty {
            throw SyncError.badMsg("empty")
        }
        let type: UInt8 = data[0]
        guard let list = specs[type], let byTag = specByTag[type] else {
            return nil
        }
        var fields: [String: SyncValue] = [:]
        var body: [UInt8] = []
        var prev: Int = -1
        for t in try SyncTlvCodec.parse(data, from: 1) {
            if type == SyncMsgType.rec && t.tag >= recBodyTagLo && t.tag <= recBodyTagHi {
                body.append(contentsOf: data[t.start..<t.end])
                continue
            }
            let spec: SyncFieldSpec? = byTag[t.tag]
            let tag: Int = Int(t.tag)
            if tag < prev {
                throw SyncError.badMsg("order")
            }
            if tag == prev, let s = spec, s.repeatMax == 0 {
                throw SyncError.badMsg("duplicate")
            }
            prev = tag
            guard let s = spec else {
                continue  // unknown tag: skipped (it still took part in the order rule)
            }
            let value: SyncValue = try decodeValue(s, t.value)
            if s.repeatMax > 0 {
                var items: [SyncValue] = []
                if case .list(let existing)? = fields[s.name] {
                    items = existing
                }
                items.append(value)
                if items.count > s.repeatMax {
                    throw SyncError.badMsg("count")
                }
                fields[s.name] = .list(items)
            } else {
                fields[s.name] = value
            }
        }
        for s in list where s.mandatory && fields[s.name] == nil {
            throw SyncError.badMsg("missing")
        }
        var m: SyncMessage = SyncMessage(type: type, fields: fields)
        if type == SyncMsgType.rec {
            if let reqId = m.int("reqId"), reqId != 0, fields["seenBy"] != nil {
                throw SyncError.badMsg("seenby_on_page")
            }
            m.body = body
            do {
                m.bodyFields = try SyncBodyCodec.decode(body)
            } catch let e as SyncError {
                m.bodyError = e
            }
        }
        if type == SyncMsgType.evt {
            let lat: Bool = fields["lat"] != nil
            let lon: Bool = fields["lon"] != nil
            let acc: Bool = fields["acc"] != nil
            if (lat || lon || acc) && !(lat && lon && acc) {
                throw SyncError.badMsg("fix")
            }
        }
        if type == SyncMsgType.join, let gid = m.bytes("groupId"), gid == SyncConst.zero8 {
            throw SyncError.badMsg("range")
        }
        return m
    }

    // MARK: Encoding

    private static func encodeValue(_ spec: SyncFieldSpec, _ x: SyncValue) throws -> [UInt8] {
        let t: SyncFieldType = spec.type
        let width: Int = t.intWidth
        if width > 0 {
            guard case .int(let n) = x else {
                throw SyncError.badMsg("type")
            }
            if !SyncLE.fits(n, width: width, signed: t.isSigned) {
                throw SyncError.badMsg("range")
            }
            if let lo = spec.lo, n < lo {
                throw SyncError.badMsg("range")
            }
            if let hi = spec.hi, n > hi {
                throw SyncError.badMsg("range")
            }
            return SyncLE.write(n, width: width)
        }
        switch (t, x) {
        case (.bytes, .bytes(let b)):
            if b.count != spec.size {
                throw SyncError.badMsg("length")
            }
            return b
        case (.str, .text(let s)):
            let b: [UInt8] = Array(s.utf8)
            if b.count < 1 || b.count > spec.size {
                throw SyncError.badMsg("length")
            }
            return b
        case (.packet, .bytes(let b)):
            try SyncKey.checkPacket(b)
            return b
        case (.key, .key(let k)):
            return k.encoded
        case (.link, .link(let l)):
            if l.peerId.count != 8 {
                throw SyncError.badMsg("length")
            }
            var out: [UInt8] = l.peerId
            out.append(l.peerKind)
            out.append(l.flags)
            return out
        case (.evtWm, .evtWm(let w)):
            if w.origin.count != 8 {
                throw SyncError.badMsg("length")
            }
            var out: [UInt8] = w.origin
            out.append(contentsOf: SyncLE.write(w.epoch, width: 4))
            out.append(contentsOf: SyncLE.write(w.seq, width: 4))
            return out
        default:
            throw SyncError.badMsg("type")
        }
    }

    /// Canonical encoding (§10): tags ascending, repeatable tags consecutive in list order, an
    /// optional field omitted when absent or equal to its default; REC body bytes verbatim after
    /// the envelope tags. Throws on a missing mandatory field or a value that does not fit.
    static func encode(type: UInt8, fields: [String: SyncValue], body: [UInt8] = []) throws -> [UInt8] {
        guard let list = specs[type] else {
            throw SyncError.badMsg("unknown_type")
        }
        var out: [UInt8] = [type]
        for s in list {
            guard let x = fields[s.name] else {
                if s.mandatory {
                    throw SyncError.badMsg("missing")
                }
                continue
            }
            if s.repeatMax > 0 {
                guard case .list(let items) = x else {
                    throw SyncError.badMsg("type")
                }
                if items.count > s.repeatMax {
                    throw SyncError.badMsg("count")
                }
                for item in items {
                    try SyncTlvCodec.append(&out, tag: s.tag, value: try encodeValue(s, item))
                }
                continue
            }
            if !s.mandatory, let d = s.defaultValue, case .int(let n) = x, n == d {
                continue
            }
            try SyncTlvCodec.append(&out, tag: s.tag, value: try encodeValue(s, x))
        }
        if type == SyncMsgType.rec {
            out.append(contentsOf: body)
        }
        return out
    }

    static func encode(_ m: SyncMessage) throws -> [UInt8] {
        return try encode(type: m.type, fields: m.fields, body: m.body)
    }

    /// A REC carrying `body` verbatim (§11.4). `seenBy` only on live RECs (reqId 0).
    static func rec(seq: Int64, reqId: Int64, seenBy: [[UInt8]] = [], body: [UInt8]) throws -> [UInt8] {
        var fields: [String: SyncValue] = ["seq": .int(seq), "reqId": .int(reqId)]
        if !seenBy.isEmpty {
            var items: [SyncValue] = []
            for id in seenBy {
                items.append(.bytes(id))
            }
            fields["seenBy"] = .list(items)
        }
        return try encode(type: SyncMsgType.rec, fields: fields, body: body)
    }

    /// HB forwarding (§16.4): copy the message and overwrite the 1-byte value of TLV 0x0F in place,
    /// so unknown tags survive. Throws BAD_MSG when the TLVs do not parse or there is no 1-byte hops.
    static func hbSetHops(_ data: [UInt8], hops: UInt8) throws -> [UInt8] {
        var out: [UInt8] = data
        for t in try SyncTlvCodec.parse(data, from: 1) where t.tag == hbHopsTag {
            if t.value.count != 1 {
                throw SyncError.badMsg("length")
            }
            out[t.start + 2] = hops
            return out
        }
        throw SyncError.badMsg("missing")
    }
}
