import Foundation

// Record key, record body TLV codec (canonical form, class rules, clock rules), versions, the
// comparator and the local edit stamp (docs/SYNC_PROTOCOL.md §3-§5, §7). Vectors: keys, bodies,
// bodyRejects, clock, comparator, localStamp.

/// key = ns (u8) ‖ packet (3..29 bytes, starts 83 01).
struct SyncKey: Hashable {
    let ns: UInt8
    let packet: [UInt8]

    init(ns: UInt8, packet: [UInt8]) {
        self.ns = ns
        self.packet = packet
    }

    /// The encoded key bytes (body TLV 0x10, ERR 0x03).
    var encoded: [UInt8] {
        var out: [UInt8] = [ns]
        out.append(contentsOf: packet)
        return out
    }

    /// Phones' ledger map key: "<ns>:<HEX>" (decimal ns, uppercase hex).
    var keyString: String {
        return String(ns) + ":" + SyncHex.encode(packet)
    }

    /// The hub's index hash: FNV-1a 64 over the encoded key bytes.
    var hubHash: UInt64 {
        return SyncFnv1a64.hash(encoded)
    }

    static func checkPacket(_ packet: [UInt8]) throws {
        if packet.count < SyncConst.packetMin || packet.count > SyncConst.packetMax {
            throw SyncError.badMsg("packet_length")
        }
        if packet[0] != 0x83 || packet[1] != 0x01 {
            throw SyncError.badMsg("packet_prefix")
        }
    }

    /// Encoded key bytes -> key; BAD_MSG on a bad length, namespace or packet.
    static func decode(_ v: [UInt8]) throws -> SyncKey {
        if v.count < 1 + SyncConst.packetMin || v.count > 1 + SyncConst.packetMax {
            throw SyncError.badMsg("length")
        }
        let ns: UInt8 = v[0]
        if ns != SyncNs.lib && ns != SyncNs.newWand {
            throw SyncError.badMsg("range")
        }
        let packet: [UInt8] = Array(v[1..<v.count])
        try checkPacket(packet)
        return SyncKey(ns: ns, packet: packet)
    }

    /// "<ns>:<HEX>" -> key (nil if malformed).
    static func parse(keyString: String) -> SyncKey? {
        let parts: [Substring] = keyString.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count != 2 {
            return nil
        }
        guard let ns = UInt8(String(parts[0])), let packet = SyncHex.decode(String(parts[1])) else {
            return nil
        }
        guard let key = try? decode([ns] + packet) else {
            return nil
        }
        return key
    }
}

/// Record body tags (§4.1).
enum SyncBodyTag {
    static let key: UInt8 = 0x10
    static let updatedAt: UInt8 = 0x11
    static let origin: UInt8 = 0x12
    static let flags: UInt8 = 0x13
    static let label: UInt8 = 0x14
    static let category: UInt8 = 0x15
    static let note: UInt8 = 0x16
    static let kind: UInt8 = 0x17
    static let place: UInt8 = 0x18
}

enum SyncRecordClass: String {
    case presence = "PRESENCE"
    case user = "USER"
    case reset = "RESET"
    case tombstone = "TOMBSTONE"
    case newWand = "NEWWAND"
}

/// A decoded record body. Absent fields are nil (flags: 0). Text fields hold valid UTF-8 whose
/// `utf8` view is exactly the wire bytes; compare them as bytes, not with String ==.
struct SyncBody {
    var key: SyncKey
    var updatedAt: Int64
    var origin: [UInt8]?
    var flags: UInt8
    var label: String?
    var category: UInt8?
    var note: String?
    var kind: String?
    var place: UInt8?

    init(key: SyncKey, updatedAt: Int64, origin: [UInt8]? = nil, flags: UInt8 = 0, label: String? = nil,
         category: UInt8? = nil, note: String? = nil, kind: String? = nil, place: UInt8? = nil) {
        self.key = key
        self.updatedAt = updatedAt
        self.origin = origin
        self.flags = flags
        self.label = label
        self.category = category
        self.note = note
        self.kind = kind
        self.place = place
    }

    var isDeleted: Bool {
        return (flags & SyncFlag.deleted) != 0
    }

    /// Any of label, category, note, kind, place present.
    var hasContent: Bool {
        return label != nil || category != nil || note != nil || kind != nil || place != nil
    }
}

enum SyncBodyCodec {
    /// Canonical body bytes -> body. Throws BAD_MSG or CLOCK (§4.2, §4.4).
    static func decode(_ data: [UInt8]) throws -> SyncBody {
        if data.count > SyncConst.bodyMax {
            throw SyncError.badMsg("oversize")
        }
        let tlvs: [SyncTlv] = try SyncTlvCodec.parse(data)
        var key: SyncKey? = nil
        var updatedAt: Int64? = nil
        var origin: [UInt8]? = nil
        var flags: UInt8 = 0
        var label: String? = nil
        var category: UInt8? = nil
        var note: String? = nil
        var kind: String? = nil
        var place: UInt8? = nil
        var prev: Int = -1
        for t in tlvs {
            let tag: Int = Int(t.tag)
            if tag < Int(SyncBodyTag.key) || tag > Int(SyncBodyTag.place) {
                throw SyncError.badMsg("unknown_tag")
            }
            if tag == prev {
                throw SyncError.badMsg("duplicate")
            }
            if tag < prev {
                throw SyncError.badMsg("order")
            }
            prev = tag
            let v: [UInt8] = t.value
            switch t.tag {
            case SyncBodyTag.key:
                key = try SyncKey.decode(v)
            case SyncBodyTag.updatedAt:
                if v.count != 8 {
                    throw SyncError.badMsg("length")
                }
                updatedAt = SyncLE.read(v, signed: true)
            case SyncBodyTag.origin:
                if v.count != 8 {
                    throw SyncError.badMsg("length")
                }
                if v == SyncConst.zero8 {
                    throw SyncError.badMsg("zero_origin")
                }
                origin = v
            case SyncBodyTag.flags:
                if v.count != 1 {
                    throw SyncError.badMsg("length")
                }
                if v[0] == 0 {
                    throw SyncError.badMsg("zero_flags")
                }
                if (v[0] & ~SyncFlag.mask) != 0 {
                    throw SyncError.badMsg("range")
                }
                flags = v[0]
            case SyncBodyTag.label:
                if v.count < 1 || v.count > SyncConst.labelMax {
                    throw SyncError.badMsg("length")
                }
                if !SyncUtf8.isValid(v) {
                    throw SyncError.badMsg("utf8")
                }
                label = SyncUtf8.string(v)
            case SyncBodyTag.category:
                if v.count != 1 {
                    throw SyncError.badMsg("length")
                }
                if v[0] > SyncCategory.color {
                    throw SyncError.badMsg("range")
                }
                category = v[0]
            case SyncBodyTag.note:
                if v.count < 1 || v.count > SyncConst.noteMax {
                    throw SyncError.badMsg("length")
                }
                if !SyncUtf8.isValid(v) {
                    throw SyncError.badMsg("utf8")
                }
                note = SyncUtf8.string(v)
            case SyncBodyTag.kind:
                if v.count < 1 || v.count > SyncConst.kindMax {
                    throw SyncError.badMsg("length")
                }
                if !SyncUtf8.isPrintableAscii(v) {
                    throw SyncError.badMsg("ascii")
                }
                kind = SyncUtf8.string(v)
            default:
                // SyncBodyTag.place (the range check above leaves nothing else).
                if v.count != 1 {
                    throw SyncError.badMsg("length")
                }
                if v[0] < SyncPlace.presets || v[0] > SyncPlace.raw {
                    throw SyncError.badMsg("range")
                }
                place = v[0]
            }
        }
        guard let k = key, let u = updatedAt else {
            throw SyncError.badMsg("missing")
        }
        let body: SyncBody = SyncBody(key: k, updatedAt: u, origin: origin, flags: flags, label: label,
                                      category: category, note: note, kind: kind, place: place)
        _ = try validate(body)
        return body
    }

    /// Body -> canonical bytes. Validates every rule (throws), so it never emits an invalid body.
    static func encode(_ b: SyncBody) throws -> [UInt8] {
        var out: [UInt8] = []
        try SyncTlvCodec.append(&out, tag: SyncBodyTag.key, value: b.key.encoded)
        try SyncTlvCodec.append(&out, tag: SyncBodyTag.updatedAt, value: SyncLE.write(b.updatedAt, width: 8))
        if let o = b.origin {
            try SyncTlvCodec.append(&out, tag: SyncBodyTag.origin, value: o)
        }
        if b.flags != 0 {
            try SyncTlvCodec.append(&out, tag: SyncBodyTag.flags, value: [b.flags])
        }
        if let l = b.label {
            try SyncTlvCodec.append(&out, tag: SyncBodyTag.label, value: Array(l.utf8))
        }
        if let c = b.category {
            try SyncTlvCodec.append(&out, tag: SyncBodyTag.category, value: [c])
        }
        if let n = b.note {
            try SyncTlvCodec.append(&out, tag: SyncBodyTag.note, value: Array(n.utf8))
        }
        if let k = b.kind {
            try SyncTlvCodec.append(&out, tag: SyncBodyTag.kind, value: Array(k.utf8))
        }
        if let p = b.place {
            try SyncTlvCodec.append(&out, tag: SyncBodyTag.place, value: [p])
        }
        _ = try decode(out)
        return out
    }

    /// Class implied by ns, flags, origin and content (time not considered).
    static func shape(_ b: SyncBody) -> SyncRecordClass {
        if b.key.ns == SyncNs.newWand {
            return .newWand
        }
        if (b.flags & SyncFlag.deleted) != 0 {
            return .tombstone
        }
        if (b.flags & (SyncFlag.userEdited | SyncFlag.preset)) != 0 {
            return .user
        }
        if b.origin == nil && !b.hasContent {
            return .presence
        }
        return .reset
    }

    /// Class / field / time rules (§4.4), in the normative check order: updatedAt <= 0 -> fields
    /// for the class -> time rule. Returns the class.
    @discardableResult
    static func validate(_ b: SyncBody) throws -> SyncRecordClass {
        let u: Int64 = b.updatedAt
        if u <= 0 {
            throw SyncError.badMsg("time")
        }
        let flags: UInt8 = b.flags
        let cls: SyncRecordClass = shape(b)
        var legacyAllowed: Bool = false
        if b.key.ns == SyncNs.newWand {
            if (flags & (SyncFlag.userEdited | SyncFlag.preset)) != 0 {
                throw SyncError.badMsg("class")
            }
            if b.origin == nil {
                throw SyncError.badMsg("class")
            }
            if b.category != nil || b.kind != nil || b.place != nil {
                throw SyncError.badMsg("class")
            }
            if (flags & SyncFlag.deleted) != 0 {
                if b.label != nil || b.note != nil {
                    throw SyncError.badMsg("class")
                }
            } else {
                if b.label == nil {
                    throw SyncError.badMsg("class")
                }
                legacyAllowed = true
            }
        } else if cls == .tombstone {
            if flags != SyncFlag.deleted {
                throw SyncError.badMsg("class")
            }
            if b.origin == nil || b.hasContent {
                throw SyncError.badMsg("class")
            }
        } else if cls == .user {
            if b.origin == nil || b.label == nil || b.category == nil || b.place == nil {
                throw SyncError.badMsg("class")
            }
            legacyAllowed = true
        } else if cls == .presence {
            if u != SyncConst.uPresence {
                throw SyncError.badMsg("class")
            }
            return .presence
        } else {
            // RESET
            if b.origin == nil {
                throw SyncError.badMsg("class")
            }
            if b.label != nil || b.category != nil || b.kind != nil || b.place != nil {
                throw SyncError.badMsg("class")
            }
        }
        if u == SyncConst.uPresence {
            throw SyncError.badMsg("class")
        }
        if u == SyncConst.uLegacyAndroid || u == SyncConst.uLegacyIos {
            if !legacyAllowed {
                throw SyncError.badMsg("class")
            }
        } else if u < SyncConst.uMinMs {
            throw SyncError(SyncErrorCode.clock, "clock_invalid")
        }
        return cls
    }

    /// The receiver clock rule (§7): CLOCK when updatedAt > now + 24 h. `nowMs` nil = the
    /// receiver does not know the time (hub before any member clock): no check.
    static func checkFuture(_ updatedAt: Int64, nowMs: Int64?) throws {
        guard let now = nowMs else {
            return
        }
        let bound: (partialValue: Int64, overflow: Bool) = now.addingReportingOverflow(SyncConst.futureBoundMs)
        if !bound.overflow && updatedAt > bound.partialValue {
            throw SyncError(SyncErrorCode.clock, "clock_future")
        }
    }

    /// The key to put in ERR{BAD_MSG|CLOCK, refType 3, key} for a rejected body: the last key TLV
    /// that decodes, scanning the TLVs in order (nil when they do not parse or none decodes).
    static func errKey(_ body: [UInt8]) -> SyncKey? {
        guard let tlvs = try? SyncTlvCodec.parse(body) else {
            return nil
        }
        var key: SyncKey? = nil
        for t in tlvs where t.tag == SyncBodyTag.key {
            guard let k = try? SyncKey.decode(t.value) else {
                break
            }
            key = k
        }
        return key
    }
}

/// version = (updatedAt signed, origin as u64 big-endian (0 when absent), bodyCrc u32), compared
/// lexicographically (§5.1).
struct SyncVersion: Equatable, Comparable {
    let updatedAt: Int64
    let origin: UInt64
    let crc: UInt32

    init(updatedAt: Int64, origin: UInt64, crc: UInt32) {
        self.updatedAt = updatedAt
        self.origin = origin
        self.crc = crc
    }

    init(body: SyncBody, bytes: [UInt8]) {
        self.updatedAt = body.updatedAt
        self.origin = SyncVersion.originValue(body.origin)
        self.crc = SyncCrc32.checksum(bytes)
    }

    /// The 8 origin bytes as a big-endian unsigned number; 0 when absent.
    static func originValue(_ origin: [UInt8]?) -> UInt64 {
        guard let o = origin else {
            return 0
        }
        var v: UInt64 = 0
        for b in o.prefix(8) {
            v = (v << 8) | UInt64(b)
        }
        return v
    }

    static func < (a: SyncVersion, b: SyncVersion) -> Bool {
        if a.updatedAt != b.updatedAt {
            return a.updatedAt < b.updatedAt
        }
        if a.origin != b.origin {
            return a.origin < b.origin
        }
        return a.crc < b.crc
    }

    /// -1, 0 or +1.
    static func compare(_ a: SyncVersion, _ b: SyncVersion) -> Int {
        if a < b {
            return -1
        }
        if b < a {
            return 1
        }
        return 0
    }
}

enum SyncStamp {
    /// updatedAt for a local edit (§5.2):
    /// max(now, ledger.updatedAt + 1, lastLocalStamp + 1, 1_500_000_000_000).
    static func local(nowMs: Int64, ledgerUpdatedAt: Int64, lastLocalStamp: Int64) -> Int64 {
        let a: Int64 = max(nowMs, plusOne(ledgerUpdatedAt))
        let b: Int64 = max(plusOne(lastLocalStamp), SyncConst.uMinMs)
        return max(a, b)
    }

    private static func plusOne(_ x: Int64) -> Int64 {
        return x == Int64.max ? x : x + 1
    }
}
