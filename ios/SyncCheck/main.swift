import Foundation

// Checks the Swift SYNC codec (ios/MagicMaker/Sync) against the shared vectors and golden
// transcripts written by tools/sync/gen_vectors.py (schema: tools/sync/README.md).
//
//   swiftc -O -swift-version 5 -o /tmp/synccheck ios/MagicMaker/Sync/*.swift ios/SyncCheck/main.swift
//   /tmp/synccheck tools/sync
//
// It is not part of the app target. It runs on Linux in CI (job "sync" in
// .github/workflows/ios-core-parity.yml), so it uses Foundation only, and it parses the JSON with
// its own small parser so integers, booleans and string bytes are read exactly the same everywhere.
// Every vector item and every transcript message is one check; a failing check prints a MISMATCH
// line. The last line is the summary ("SYNC: ..."); the exit status is 1 when anything failed.

// MARK: - JSON

enum JV {
    case null
    case bool(Bool)
    case int(Int64)
    case num(Double)
    case str(String)
    case arr([JV])
    case obj([String: JV])

    subscript(_ key: String) -> JV {
        if case .obj(let d) = self, let v = d[key] {
            return v
        }
        return .null
    }

    func has(_ key: String) -> Bool {
        if case .obj(let d) = self {
            return d[key] != nil
        }
        return false
    }

    var isNull: Bool {
        if case .null = self {
            return true
        }
        return false
    }

    var s: String {
        if case .str(let v) = self {
            return v
        }
        return ""
    }

    var optS: String? {
        if case .str(let v) = self {
            return v
        }
        return nil
    }

    var i: Int64 {
        if case .int(let v) = self {
            return v
        }
        return 0
    }

    var optI: Int64? {
        if case .int(let v) = self {
            return v
        }
        return nil
    }

    var b: Bool {
        if case .bool(let v) = self {
            return v
        }
        return false
    }

    var a: [JV] {
        if case .arr(let v) = self {
            return v
        }
        return []
    }

    var o: [String: JV] {
        if case .obj(let v) = self {
            return v
        }
        return [:]
    }
}

/// Deep equality; strings compare by their UTF-8 bytes, objects ignore key order.
func jvEqual(_ x: JV, _ y: JV) -> Bool {
    switch (x, y) {
    case (.null, .null):
        return true
    case (.bool(let p), .bool(let q)):
        return p == q
    case (.int(let p), .int(let q)):
        return p == q
    case (.num(let p), .num(let q)):
        return p == q
    case (.str(let p), .str(let q)):
        return Array(p.utf8) == Array(q.utf8)
    case (.arr(let p), .arr(let q)):
        if p.count != q.count {
            return false
        }
        var k: Int = 0
        while k < p.count {
            if !jvEqual(p[k], q[k]) {
                return false
            }
            k += 1
        }
        return true
    case (.obj(let p), .obj(let q)):
        if p.count != q.count {
            return false
        }
        for (key, pv) in p {
            guard let qv = q[key] else {
                return false
            }
            if !jvEqual(pv, qv) {
                return false
            }
        }
        return true
    default:
        return false
    }
}

func jvEscape(_ s: String) -> String {
    var out: String = "\""
    for u in s.unicodeScalars {
        switch u.value {
        case 0x22:
            out += "\\\""
        case 0x5C:
            out += "\\\\"
        case 0x0A:
            out += "\\n"
        case 0x0D:
            out += "\\r"
        case 0x09:
            out += "\\t"
        case 0x00..<0x20:
            let h: String = String(u.value, radix: 16, uppercase: false)
            out += "\\u" + String(repeating: "0", count: 4 - h.count) + h
        default:
            out.unicodeScalars.append(u)
        }
    }
    return out + "\""
}

/// Compact JSON text with sorted keys (for MISMATCH lines).
func jvText(_ v: JV) -> String {
    switch v {
    case .null:
        return "null"
    case .bool(let x):
        return x ? "true" : "false"
    case .int(let x):
        return String(x)
    case .num(let x):
        return String(x)
    case .str(let x):
        return jvEscape(x)
    case .arr(let xs):
        var parts: [String] = []
        for x in xs {
            parts.append(jvText(x))
        }
        return "[" + parts.joined(separator: ",") + "]"
    case .obj(let d):
        var parts: [String] = []
        for k in d.keys.sorted() {
            parts.append(jvEscape(k) + ":" + jvText(d[k] ?? .null))
        }
        return "{" + parts.joined(separator: ",") + "}"
    }
}

struct JSONFailure: Error {
    let message: String
}

/// A small strict JSON parser over UTF-8 bytes.
struct JSONParser {
    private let bytes: [UInt8]
    private var pos: Int = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    static func parse(_ bytes: [UInt8]) throws -> JV {
        var p: JSONParser = JSONParser(bytes)
        p.skipSpace()
        let v: JV = try p.value()
        p.skipSpace()
        if p.pos != p.bytes.count {
            throw JSONFailure(message: "trailing data at \(p.pos)")
        }
        return v
    }

    private mutating func skipSpace() {
        while pos < bytes.count {
            let c: UInt8 = bytes[pos]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                pos += 1
            } else {
                break
            }
        }
    }

    private func fail(_ what: String) -> JSONFailure {
        return JSONFailure(message: what + " at byte \(pos)")
    }

    private mutating func literal(_ word: String, _ v: JV) throws -> JV {
        let w: [UInt8] = Array(word.utf8)
        if pos + w.count > bytes.count || Array(bytes[pos..<(pos + w.count)]) != w {
            throw fail("bad literal")
        }
        pos += w.count
        return v
    }

    private mutating func value() throws -> JV {
        if pos >= bytes.count {
            throw fail("unexpected end")
        }
        let c: UInt8 = bytes[pos]
        switch c {
        case 0x7B:  // {
            pos += 1
            var d: [String: JV] = [:]
            skipSpace()
            if pos < bytes.count && bytes[pos] == 0x7D {
                pos += 1
                return .obj(d)
            }
            while true {
                skipSpace()
                if pos >= bytes.count || bytes[pos] != 0x22 {
                    throw fail("expected key")
                }
                let k: String = try string()
                skipSpace()
                if pos >= bytes.count || bytes[pos] != 0x3A {
                    throw fail("expected ':'")
                }
                pos += 1
                skipSpace()
                d[k] = try value()
                skipSpace()
                if pos < bytes.count && bytes[pos] == 0x2C {
                    pos += 1
                    continue
                }
                if pos < bytes.count && bytes[pos] == 0x7D {
                    pos += 1
                    return .obj(d)
                }
                throw fail("expected ',' or '}'")
            }
        case 0x5B:  // [
            pos += 1
            var items: [JV] = []
            skipSpace()
            if pos < bytes.count && bytes[pos] == 0x5D {
                pos += 1
                return .arr(items)
            }
            while true {
                skipSpace()
                items.append(try value())
                skipSpace()
                if pos < bytes.count && bytes[pos] == 0x2C {
                    pos += 1
                    continue
                }
                if pos < bytes.count && bytes[pos] == 0x5D {
                    pos += 1
                    return .arr(items)
                }
                throw fail("expected ',' or ']'")
            }
        case 0x22:
            return .str(try string())
        case 0x74:
            return try literal("true", .bool(true))
        case 0x66:
            return try literal("false", .bool(false))
        case 0x6E:
            return try literal("null", .null)
        default:
            return try number()
        }
    }

    private mutating func number() throws -> JV {
        let start: Int = pos
        var isInt: Bool = true
        if pos < bytes.count && bytes[pos] == 0x2D {
            pos += 1
        }
        while pos < bytes.count {
            let c: UInt8 = bytes[pos]
            if c >= 0x30 && c <= 0x39 {
                pos += 1
            } else if c == 0x2E || c == 0x65 || c == 0x45 || c == 0x2B || c == 0x2D {
                isInt = false
                pos += 1
            } else {
                break
            }
        }
        let text: String = String(decoding: bytes[start..<pos], as: UTF8.self)
        if text.isEmpty || text == "-" {
            throw fail("bad value")
        }
        if isInt {
            guard let v = Int64(text) else {
                throw fail("integer out of range")
            }
            return .int(v)
        }
        guard let d = Double(text) else {
            throw fail("bad number")
        }
        return .num(d)
    }

    private mutating func hex4() throws -> UInt32 {
        if pos + 4 > bytes.count {
            throw fail("short \\u escape")
        }
        var v: UInt32 = 0
        for k in 0..<4 {
            let c: UInt8 = bytes[pos + k]
            var d: UInt32 = 0
            if c >= 0x30 && c <= 0x39 {
                d = UInt32(c - 0x30)
            } else if c >= 0x41 && c <= 0x46 {
                d = UInt32(c - 0x41 + 10)
            } else if c >= 0x61 && c <= 0x66 {
                d = UInt32(c - 0x61 + 10)
            } else {
                throw fail("bad \\u escape")
            }
            v = v * 16 + d
        }
        pos += 4
        return v
    }

    private static func appendUtf8(_ out: inout [UInt8], _ cp: UInt32) {
        if cp < 0x80 {
            out.append(UInt8(cp))
        } else if cp < 0x800 {
            out.append(UInt8(0xC0 | (cp >> 6)))
            out.append(UInt8(0x80 | (cp & 0x3F)))
        } else if cp < 0x1_0000 {
            out.append(UInt8(0xE0 | (cp >> 12)))
            out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
            out.append(UInt8(0x80 | (cp & 0x3F)))
        } else {
            out.append(UInt8(0xF0 | (cp >> 18)))
            out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
            out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
            out.append(UInt8(0x80 | (cp & 0x3F)))
        }
    }

    private mutating func string() throws -> String {
        pos += 1  // opening quote
        var out: [UInt8] = []
        while true {
            if pos >= bytes.count {
                throw fail("unterminated string")
            }
            let c: UInt8 = bytes[pos]
            if c == 0x22 {
                pos += 1
                break
            }
            if c != 0x5C {
                out.append(c)
                pos += 1
                continue
            }
            pos += 1
            if pos >= bytes.count {
                throw fail("bad escape")
            }
            let e: UInt8 = bytes[pos]
            pos += 1
            switch e {
            case 0x22: out.append(0x22)
            case 0x5C: out.append(0x5C)
            case 0x2F: out.append(0x2F)
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x6E: out.append(0x0A)
            case 0x72: out.append(0x0D)
            case 0x74: out.append(0x09)
            case 0x75:
                var cp: UInt32 = try hex4()
                if cp >= 0xD800 && cp <= 0xDBFF && pos + 6 <= bytes.count && bytes[pos] == 0x5C
                    && bytes[pos + 1] == 0x75 {
                    pos += 2
                    let lo: UInt32 = try hex4()
                    if lo >= 0xDC00 && lo <= 0xDFFF {
                        cp = 0x1_0000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                    } else {
                        throw fail("unpaired surrogate")
                    }
                } else if cp >= 0xD800 && cp <= 0xDFFF {
                    throw fail("unpaired surrogate")
                }
                JSONParser.appendUtf8(&out, cp)
            default:
                throw fail("bad escape")
            }
        }
        if !SyncUtf8.isValid(out) {
            throw fail("invalid UTF-8 in string")
        }
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: - Results

final class Report {
    var passes: [String: Int] = [:]
    var fails: [String: Int] = [:]
    var groupOrder: [String] = []
    var notes: [String] = []
    var printed: Int = 0
    let maxPrinted: Int = 200

    func touch(_ group: String) {
        if passes[group] == nil && fails[group] == nil {
            groupOrder.append(group)
        }
    }

    func pass(_ group: String) {
        touch(group)
        passes[group] = (passes[group] ?? 0) + 1
    }

    func fail(_ group: String, _ name: String, _ problems: [String]) {
        touch(group)
        fails[group] = (fails[group] ?? 0) + 1
        if printed < maxPrinted {
            printed += 1
            print("MISMATCH \(group): \(name): " + problems.prefix(3).joined(separator: " | "))
        }
    }

    func note(_ text: String) {
        notes.append(text)
    }

    var totalPasses: Int {
        return passes.values.reduce(0, +)
    }

    var totalFails: Int {
        return fails.values.reduce(0, +)
    }
}

let report: Report = Report()

func clip(_ s: String) -> String {
    if s.count <= 600 {
        return s
    }
    return String(s.prefix(600)) + "...(+\(s.count - 600) chars)"
}

/// One vector item (or transcript message): collects its problems, then passes or fails once.
final class Case {
    let group: String
    let name: String
    var problems: [String] = []

    init(_ group: String, _ name: String) {
        self.group = group
        self.name = name
    }

    func ok(_ cond: Bool, _ what: String) {
        if !cond {
            problems.append(what)
        }
    }

    func eq(_ got: JV, _ want: JV, _ what: String) {
        if !jvEqual(got, want) {
            problems.append(clip("\(what): got \(jvText(got)) want \(jvText(want))"))
        }
    }

    func done() {
        if problems.isEmpty {
            report.pass(group)
        } else {
            report.fail(group, name, problems)
        }
    }
}

// MARK: - Conversions

func hexOf(_ j: JV) -> [UInt8] {
    return SyncHex.decode(j.s) ?? []
}

func optHexOf(_ j: JV) -> [UInt8]? {
    if j.isNull {
        return nil
    }
    return SyncHex.decode(j.s)
}

func jHex(_ b: [UInt8]?) -> JV {
    guard let x = b else {
        return .null
    }
    return .str(SyncHex.encode(x))
}

func jInt(_ v: Int64?) -> JV {
    guard let x = v else {
        return .null
    }
    return .int(x)
}

func hex64(_ v: UInt64) -> String {
    var b: [UInt8] = []
    var shift: Int = 56
    while shift >= 0 {
        b.append(UInt8(truncatingIfNeeded: v >> UInt64(shift)))
        shift -= 8
    }
    return SyncHex.encode(b)
}

func originValueOf(_ hex: String) -> UInt64 {
    return SyncVersion.originValue(SyncHex.decode(hex) ?? [])
}

func jKey(_ k: SyncKey) -> JV {
    return .obj(["ns": .int(Int64(k.ns)), "packet": jHex(k.packet)])
}

func keyOf(_ j: JV) -> SyncKey {
    return SyncKey(ns: UInt8(truncatingIfNeeded: j["ns"].i), packet: hexOf(j["packet"]))
}

func jBody(_ f: SyncBody) -> JV {
    var d: [String: JV] = ["key": jKey(f.key), "updatedAt": .int(f.updatedAt)]
    if let o = f.origin {
        d["origin"] = jHex(o)
    }
    if f.flags != 0 {
        d["flags"] = .int(Int64(f.flags))
    }
    if let l = f.label {
        d["label"] = .str(l)
    }
    if let c = f.category {
        d["category"] = .int(Int64(c))
    }
    if let n = f.note {
        d["note"] = .str(n)
    }
    if let k = f.kind {
        d["kind"] = .str(k)
    }
    if let p = f.place {
        d["place"] = .int(Int64(p))
    }
    return .obj(d)
}

func u8Opt(_ j: JV) -> UInt8? {
    guard let v = j.optI else {
        return nil
    }
    return UInt8(truncatingIfNeeded: v)
}

func bodyOf(_ j: JV) -> SyncBody {
    return SyncBody(key: keyOf(j["key"]), updatedAt: j["updatedAt"].i, origin: optHexOf(j["origin"]),
                    flags: u8Opt(j["flags"]) ?? 0, label: j["label"].optS, category: u8Opt(j["category"]),
                    note: j["note"].optS, kind: j["kind"].optS, place: u8Opt(j["place"]))
}

func jValue(_ v: SyncValue) -> JV {
    switch v {
    case .int(let x):
        return .int(x)
    case .bytes(let b):
        return jHex(b)
    case .text(let s):
        return .str(s)
    case .key(let k):
        return jKey(k)
    case .link(let l):
        return .obj(["peerId": jHex(l.peerId), "peerKind": .int(Int64(l.peerKind)), "flags": .int(Int64(l.flags))])
    case .evtWm(let w):
        return .obj(["origin": jHex(w.origin), "epoch": .int(w.epoch), "seq": .int(w.seq)])
    case .list(let xs):
        var out: [JV] = []
        for x in xs {
            out.append(jValue(x))
        }
        return .arr(out)
    }
}

func valueOf(_ spec: SyncFieldSpec, _ j: JV) -> SyncValue {
    switch spec.type {
    case .u8, .u16, .u32, .i8, .i16, .i32, .i64:
        return .int(j.i)
    case .bytes, .packet:
        return .bytes(hexOf(j))
    case .str:
        return .text(j.s)
    case .key:
        return .key(keyOf(j))
    case .link:
        return .link(SyncHbLink(peerId: hexOf(j["peerId"]), peerKind: UInt8(truncatingIfNeeded: j["peerKind"].i),
                                flags: UInt8(truncatingIfNeeded: j["flags"].i)))
    case .evtWm:
        return .evtWm(SyncEvtWm(origin: hexOf(j["origin"]), epoch: j["epoch"].i, seq: j["seq"].i))
    }
}

/// A decoded message -> the vectors' `fields` object.
func jFields(_ m: SyncMessage) -> JV {
    var d: [String: JV] = [:]
    for s in SyncMessageCodec.specs[m.type] ?? [] {
        if let v = m.fields[s.name] {
            d[s.name] = jValue(v)
        }
    }
    if m.type == SyncMsgType.rec {
        d["bodyHex"] = jHex(m.body)
        if let f = m.bodyFields {
            d["body"] = jBody(f)
        }
        if let e = m.bodyError {
            d["bodyError"] = .str(e.name)
        }
    }
    return .obj(d)
}

/// The vectors' `fields` object -> a message to encode (REC: `bodyHex` verbatim).
func messageOf(_ type: UInt8, _ j: JV) -> SyncMessage {
    var fields: [String: SyncValue] = [:]
    for s in SyncMessageCodec.specs[type] ?? [] {
        if !j.has(s.name) {
            continue
        }
        let x: JV = j[s.name]
        if s.repeatMax > 0 {
            var items: [SyncValue] = []
            for item in x.a {
                items.append(valueOf(s, item))
            }
            fields[s.name] = .list(items)
        } else {
            fields[s.name] = valueOf(s, x)
        }
    }
    var body: [UInt8] = []
    if type == SyncMsgType.rec {
        body = hexOf(j["bodyHex"])
    }
    return SyncMessage(type: type, fields: fields, body: body)
}

func jEntry(_ e: SyncLedgerEntry) -> JV {
    return .obj([
        "key": .str(e.keyString), "u": .int(e.version.updatedAt), "o": jHex(e.origin),
        "c": .int(Int64(e.version.crc)), "class": .str(e.cls.rawValue), "b": jHex(e.body), "s": .int(e.seq),
        "f": jHex(e.syncFrom),
    ])
}

func jLedger(_ led: SyncLedger) -> JV {
    var out: [JV] = []
    for e in led.sortedByKey {
        out.append(jEntry(e))
    }
    return .arr(out)
}

func jStrs(_ xs: [String]) -> JV {
    var out: [JV] = []
    for x in xs {
        out.append(.str(x))
    }
    return .arr(out)
}

func jHexList(_ xs: [[UInt8]]) -> JV {
    var out: [JV] = []
    for x in xs {
        out.append(jHex(x))
    }
    return .arr(out)
}

func hexList(_ j: JV) -> [[UInt8]] {
    var out: [[UInt8]] = []
    for x in j.a {
        out.append(hexOf(x))
    }
    return out
}

func errName(_ body: () throws -> Void) -> String? {
    do {
        try body()
    } catch let e as SyncError {
        return e.name
    } catch {
        return "OTHER"
    }
    return nil
}

func errReason(_ body: () throws -> Void) -> String? {
    do {
        try body()
    } catch let e as SyncError {
        return e.reason
    } catch {
        return nil
    }
    return nil
}

// MARK: - Groups

func checkConstants(_ v: JV) {
    let c: Case = Case("constants", "constants")
    let k: JV = v["constants"]
    let ints: [(String, Int64)] = [
        ("proto", Int64(SyncConst.proto)), ("frameVersion", Int64(SyncConst.frameVersion)),
        ("frameHeaderLen", Int64(SyncConst.frameHeaderLen)), ("attOverhead", Int64(SyncConst.attOverhead)),
        ("mtuMin", Int64(SyncConst.mtuMin)), ("smallMtuBelow", Int64(SyncConst.smallMtuBelow)),
        ("maxMsgMin", Int64(SyncConst.maxMsgMin)), ("hubMaxMsg", Int64(SyncConst.hubMaxMsg)),
        ("phoneMaxMsg", Int64(SyncConst.phoneMaxMsg)), ("packetMin", Int64(SyncConst.packetMin)),
        ("packetMax", Int64(SyncConst.packetMax)), ("labelMax", Int64(SyncConst.labelMax)),
        ("noteMax", Int64(SyncConst.noteMax)), ("kindMax", Int64(SyncConst.kindMax)),
        ("bodyMax", Int64(SyncConst.bodyMax)), ("seenByMax", Int64(SyncConst.seenByMax)),
        ("hbLinksMax", Int64(SyncConst.hbLinksMax)), ("hbEvtWmMax", Int64(SyncConst.hbEvtWmMax)),
        ("uPresence", SyncConst.uPresence), ("uLegacyAndroid", SyncConst.uLegacyAndroid),
        ("uLegacyIos", SyncConst.uLegacyIos), ("uMinMs", SyncConst.uMinMs), ("futureBoundMs", SyncConst.futureBoundMs),
        ("pullLimitDefault", SyncConst.pullLimitDefault), ("pullMaxBytesDefault", SyncConst.pullMaxBytesDefault),
        ("pullLimitSmall", SyncConst.pullLimitSmall), ("pullMaxBytesSmall", SyncConst.pullMaxBytesSmall),
        ("pullMaxBytesMin", SyncConst.pullMaxBytesMin), ("helloTimeoutMs", SyncConst.helloTimeoutMs),
        ("helloTries", Int64(SyncConst.helloTries)), ("incompatibleRetryMs", SyncConst.incompatibleRetryMs),
        ("authTimeoutMs", SyncConst.authTimeoutMs), ("memberDeadlineMs", SyncConst.memberDeadlineMs),
        ("pageTimeoutMs", SyncConst.pageTimeoutMs), ("pageTries", Int64(SyncConst.pageTries)),
        ("pageFailRetryMs", SyncConst.pageFailRetryMs), ("livePullMs", SyncConst.livePullMs),
        ("hbIntervalMs", SyncConst.hbIntervalMs), ("hbSpacingMs", SyncConst.hbSpacingMs),
        ("pathFreshMs", SyncConst.pathFreshMs), ("notReadyRetryMs", SyncConst.notReadyRetryMs),
        ("busyRetryMs", SyncConst.busyRetryMs), ("defaultRetryMs", SyncConst.defaultRetryMs),
        ("evtWindowBits", SyncConst.evtWindowBits), ("evtEpochsKept", Int64(SyncConst.evtEpochsKept)),
        ("evtReplayDedupeMs", SyncConst.evtReplayDedupeMs), ("tombstoneCapPhone", Int64(SyncConst.tombstoneCapPhone)),
    ]
    for (name, mine) in ints {
        c.eq(.int(mine), k[name], name)
    }
    c.eq(.str(hex64(SyncConst.fnv64Offset)), k["fnv64Offset"], "fnv64Offset")
    c.eq(.str(hex64(SyncConst.fnv64Prime)), k["fnv64Prime"], "fnv64Prime")
    c.eq(jHex(SyncGroupAuth.groupIdPrefix), k["groupIdPrefix"], "groupIdPrefix")
    c.eq(jHex(SyncGroupAuth.proofPPrefix), k["proofPPrefix"], "proofPPrefix")
    c.eq(jHex(SyncGroupAuth.proofCPrefix), k["proofCPrefix"], "proofCPrefix")
    for (name, code) in k["messageTypes"].o {
        c.eq(jInt(SyncMsgType.code(name).map { Int64($0) }), code, "messageTypes." + name)
    }
    for (name, code) in k["errorCodes"].o {
        c.eq(.str(SyncErrorCode.name(UInt8(truncatingIfNeeded: code.i))), .str(name), "errorCodes." + name)
    }
    c.done()
}

func checkPrimitives(_ v: JV) {
    for x in v["crc32"].a {
        let c: Case = Case("crc32", x["name"].s)
        c.eq(.int(Int64(SyncCrc32.checksum(hexOf(x["hex"])))), x["crc"], "crc")
        c.done()
    }
    for x in v["fnv1a64"].a {
        let c: Case = Case("fnv1a64", x["name"].s)
        c.eq(.str(hex64(SyncFnv1a64.hash(hexOf(x["hex"])))), x["hash"], "hash")
        c.done()
    }
    for x in v["sha256"].a {
        let c: Case = Case("sha256", x["name"].s)
        c.eq(jHex(SyncSha256.hash(hexOf(x["hex"]))), x["digest"], "digest")
        c.done()
    }
    for x in v["hmacSha256"].a {
        let c: Case = Case("hmacSha256", x["name"].s)
        let mac: [UInt8] = SyncHmac.sha256(key: hexOf(x["keyHex"]), data: hexOf(x["dataHex"]))
        c.eq(jHex(mac), x["macHex"], "mac")
        if x.has("trunc16Hex") {
            c.eq(jHex(Array(mac.prefix(16))), x["trunc16Hex"], "trunc16")
        }
        c.done()
    }
    for x in v["groupIds"].a {
        let c: Case = Case("groupIds", x["name"].s)
        let g: [UInt8] = SyncGroupAuth.groupId(key: hexOf(x["keyHex"]))
        c.eq(jHex(g), x["groupId"], "groupId")
        c.eq(jHex(SyncGroupAuth.advertTag(groupId: g)), x["advertTag"], "advertTag")
        c.done()
    }
    for x in v["proofs"].a {
        let c: Case = Case("proofs", x["name"].s)
        let key: [UInt8] = hexOf(x["keyHex"])
        let nc: [UInt8] = hexOf(x["nonceC"])
        let np: [UInt8] = hexOf(x["nonceP"])
        let ic: [UInt8] = hexOf(x["idC"])
        let ip: [UInt8] = hexOf(x["idP"])
        c.eq(jHex(SyncGroupAuth.groupId(key: key)), x["groupId"], "groupId")
        c.eq(jHex(SyncGroupAuth.transcript(nonceC: nc, nonceP: np, idC: ic, idP: ip)), x["transcriptHex"], "T")
        c.eq(jHex(SyncGroupAuth.macInput(prefix: SyncGroupAuth.proofPPrefix, nonceC: nc, nonceP: np, idC: ic, idP: ip)),
             x["macInputPHex"], "macInputP")
        c.eq(jHex(SyncGroupAuth.macInput(prefix: SyncGroupAuth.proofCPrefix, nonceC: nc, nonceP: np, idC: ic, idP: ip)),
             x["macInputCHex"], "macInputC")
        let pp: [UInt8] = SyncGroupAuth.proofP(key: key, nonceC: nc, nonceP: np, idC: ic, idP: ip)
        let pc: [UInt8] = SyncGroupAuth.proofC(key: key, nonceC: nc, nonceP: np, idC: ic, idP: ip)
        c.eq(jHex(pp), x["proofP"], "proofP")
        c.eq(jHex(pc), x["proofC"], "proofC")
        c.ok(SyncGroupAuth.constantTimeEqual(pp, hexOf(x["proofP"])), "constantTimeEqual(proofP)")
        c.ok(!SyncGroupAuth.constantTimeEqual(pp, pc), "proofP must differ from proofC")
        c.done()
    }
    for x in v["textNormalize"].a {
        let c: Case = Case("textNormalize", x["name"].s)
        let input: [UInt8] = hexOf(x["inputHex"])
        let s: String = String(decoding: input, as: UTF8.self)
        c.eq(.str(s), x["input"], "input bytes")
        let outText: String?
        if x["fn"].s == "text" {
            outText = SyncText.normalize(s, maxBytes: Int(x["maxBytes"].i))
        } else {
            outText = SyncText.normalizeKind(s)
        }
        c.eq(outText.map { JV.str($0) } ?? .null, x["output"], "output")
        c.eq(outText.map { jHex(Array($0.utf8)) } ?? .null, x["outputHex"], "outputHex")
        if let o = outText {
            // normalize is idempotent.
            let again: String? = x["fn"].s == "text" ? SyncText.normalize(o, maxBytes: Int(x["maxBytes"].i))
                : SyncText.normalizeKind(o)
            c.eq(again.map { JV.str($0) } ?? .null, .str(o), "idempotent")
        }
        c.done()
    }
    for x in v["keys"].a {
        let c: Case = Case("keys", x["keyString"].s)
        let k: SyncKey = SyncKey(ns: UInt8(truncatingIfNeeded: x["ns"].i), packet: hexOf(x["packet"]))
        c.eq(jHex(k.encoded), x["keyHex"], "keyHex")
        c.eq(.str(k.keyString), x["keyString"], "keyString")
        c.eq(.str(hex64(k.hubHash)), x["fnv1a64"], "hub hash")
        if let back = SyncKey.parse(keyString: x["keyString"].s) {
            c.ok(back == k, "parse(keyString)")
        } else {
            c.ok(false, "parse(keyString) failed")
        }
        if let d = try? SyncKey.decode(hexOf(x["keyHex"])) {
            c.ok(d == k, "decode(keyHex)")
        } else {
            c.ok(false, "decode(keyHex) failed")
        }
        c.done()
    }
}

func jVersion(_ v: SyncVersion) -> JV {
    return .obj(["updatedAt": .int(v.updatedAt), "origin": .str(hex64(v.origin)), "crc": .int(Int64(v.crc))])
}

func checkBodies(_ v: JV) {
    for x in v["bodies"].a {
        let c: Case = Case("bodies", x["name"].s)
        let hex: [UInt8] = hexOf(x["hex"])
        do {
            let enc: [UInt8] = try SyncBodyCodec.encode(bodyOf(x["body"]))
            c.eq(jHex(enc), x["hex"], "encode")
            c.eq(.int(Int64(enc.count)), x["len"], "len")
        } catch {
            c.ok(false, "encode threw \(error)")
        }
        do {
            let back: SyncBody = try SyncBodyCodec.decode(hex)
            c.eq(jBody(back), x["body"], "decode")
            c.eq(.str(try SyncBodyCodec.validate(back).rawValue), x["class"], "class")
            c.eq(jVersion(SyncVersion(body: back, bytes: hex)), x["version"], "version")
        } catch {
            c.ok(false, "decode threw \(error)")
        }
        c.eq(.int(Int64(SyncCrc32.checksum(hex))), x["crc"], "crc")
        c.done()
    }
    for x in v["bodyRejects"].a {
        let c: Case = Case("bodyRejects", x["name"].s)
        let hex: [UInt8] = hexOf(x["hex"])
        let e: String? = errName { _ = try SyncBodyCodec.decode(hex) }
        c.eq(jStrOpt(e), x["error"], "error")
        let r: String? = errReason { _ = try SyncBodyCodec.decode(hex) }
        if let want = x["reason"].optS, r != want {
            report.note("bodyRejects \(x["name"].s): reason \(r ?? "none") (vector: \(want))")
        }
        c.done()
    }
    for x in v["clock"].a {
        let c: Case = Case("clock", x["name"].s)
        if x.has("bodyHex") {
            let led: SyncLedger = SyncLedger()
            let r: SyncApplyResult = led.applyRemote(hexOf(x["bodyHex"]), from: SyncConst.zero8, nowMs: x["now"].optI)
            c.eq(.str(r.status.rawValue), x["result"], "apply")
        } else {
            let e: String? = errName { try SyncBodyCodec.checkFuture(x["updatedAt"].i, nowMs: x["now"].optI) }
            c.eq(.str(e ?? "OK"), x["result"], "checkFuture")
        }
        c.done()
    }
    for x in v["comparator"].a {
        let c: Case = Case("comparator", x["name"].s)
        let a: SyncVersion = SyncVersion(updatedAt: x["a"]["updatedAt"].i, origin: originValueOf(x["a"]["origin"].s),
                                         crc: UInt32(truncatingIfNeeded: x["a"]["crc"].i))
        let b: SyncVersion = SyncVersion(updatedAt: x["b"]["updatedAt"].i, origin: originValueOf(x["b"]["origin"].s),
                                         crc: UInt32(truncatingIfNeeded: x["b"]["crc"].i))
        c.eq(.int(Int64(SyncVersion.compare(a, b))), x["expect"], "compare(a, b)")
        c.eq(.int(Int64(-SyncVersion.compare(b, a))), x["expect"], "-compare(b, a)")
        c.done()
    }
    for x in v["localStamp"].a {
        let c: Case = Case("localStamp", x["name"].s)
        let u: Int64 = SyncStamp.local(nowMs: x["now"].i, ledgerUpdatedAt: x["ledgerUpdatedAt"].i,
                                       lastLocalStamp: x["lastLocalStamp"].i)
        c.eq(.int(u), x["expect"], "stamp")
        c.done()
    }
}

func jStrOpt(_ s: String?) -> JV {
    guard let x = s else {
        return .null
    }
    return .str(x)
}

func recordClassOf(_ name: String) -> SyncRecordClass? {
    return SyncRecordClass(rawValue: name)
}

func checkApply(_ v: JV) {
    for sc in v["apply"].a {
        let c: Case = Case("apply", sc["name"].s)
        let led: SyncLedger = SyncLedger(tombstoneCap: Int(sc["tombstoneCap"].i), nextSyncSeq: sc["nextSyncSeq"].i)
        var idx: Int = 0
        for st in sc["steps"].a {
            let what: String = "step \(idx) (\(st["op"].s))"
            idx += 1
            let want: JV = st["expect"]
            switch st["op"].s {
            case "remote":
                let r: SyncApplyResult = led.applyRemote(hexOf(st["bodyHex"]), from: optHexOf(st["from"]),
                                                         nowMs: st["now"].optI)
                c.eq(.str(r.status.rawValue), want["status"], what + " status")
                c.eq(jStrs(r.evicted), want["evicted"], what + " evicted")
                var entry: JV = .null
                if r.status == .accept, let e = r.entry {
                    entry = jEntry(e)
                }
                c.eq(entry, want["entry"], what + " entry")
            case "edit":
                guard let cls = recordClassOf(st["class"].s) else {
                    c.ok(false, what + " unknown class")
                    continue
                }
                do {
                    let r: (entry: SyncLedgerEntry, evicted: [String]) = try led.localEdit(
                        cls, key: keyOf(st["key"]), nowMs: st["now"].i, selfId: hexOf(st["self"]),
                        label: st["label"].optS, category: u8Opt(st["category"]), kind: st["kind"].optS,
                        place: u8Opt(st["place"]), note: st["note"].optS,
                        preset: st.has("preset") ? st["preset"].b : false,
                        userEdited: st.has("userEdited") ? st["userEdited"].b : true)
                    c.eq(jHex(r.entry.body), want["bodyHex"], what + " body")
                    c.eq(.int(r.entry.version.updatedAt), want["updatedAt"], what + " updatedAt")
                    c.eq(jStrs(r.evicted), want["evicted"], what + " evicted")
                    if want.has("entry") {
                        let still: Bool = led.get(r.entry.key) != nil
                        c.eq(still ? jEntry(r.entry) : .null, want["entry"], what + " entry")
                    }
                } catch {
                    c.ok(false, what + " threw \(error)")
                }
            case "learn":
                do {
                    let e: SyncLedgerEntry? = try led.localLearn(packet: hexOf(st["packet"]))
                    c.eq(.bool(e != nil), want["created"], what + " created")
                    if want.has("entry") {
                        c.eq(e.map { jEntry($0) } ?? .null, want["entry"], what + " entry")
                    }
                } catch {
                    c.ok(false, what + " threw \(error)")
                }
            default:
                c.ok(false, what + " unknown op")
            }
        }
        let fin: JV = sc["final"]
        c.eq(.int(led.nextSyncSeq), fin["nextSyncSeq"], "final nextSyncSeq")
        c.eq(.int(led.lastLocalStamp), fin["lastLocalStamp"], "final lastLocalStamp")
        c.eq(.int(Int64(led.tombstoneCount)), fin["tombstones"], "final tombstones")
        c.eq(jLedger(led), fin["entries"], "final entries")
        c.done()
    }
}

func checkMessages(_ v: JV) {
    for x in v["messages"].a {
        let c: Case = Case("messages", x["name"].s)
        guard let type = SyncMsgType.code(x["type"].s) else {
            c.ok(false, "unknown type name " + x["type"].s)
            c.done()
            continue
        }
        c.eq(.int(Int64(type)), x["typeCode"], "typeCode")
        let hex: [UInt8] = hexOf(x["hex"])
        c.eq(.int(Int64(hex.count)), x["len"], "len")
        do {
            let enc: [UInt8] = try SyncMessageCodec.encode(messageOf(type, x["fields"]))
            c.eq(jHex(enc), x["hex"], "encode")
        } catch {
            c.ok(false, "encode threw \(error)")
        }
        do {
            if let m = try SyncMessageCodec.decode(hex) {
                c.eq(.int(Int64(m.type)), .int(Int64(type)), "decoded type")
                c.eq(jFields(m), x["fields"], "decode")
                c.eq(jHex(try SyncMessageCodec.encode(m)), x["hex"], "re-encode")
            } else {
                c.ok(false, "decode ignored the message")
            }
        } catch {
            c.ok(false, "decode threw \(error)")
        }
        c.done()
    }
    for x in v["messageNonCanonical"].a {
        let c: Case = Case("messageNonCanonical", x["name"].s)
        do {
            if let m = try SyncMessageCodec.decode(hexOf(x["hex"])) {
                c.eq(.str(m.typeName), x["type"], "type")
                c.eq(jFields(m), x["fields"], "decode")
                c.eq(jHex(try SyncMessageCodec.encode(m)), x["canonicalHex"], "canonical")
            } else {
                c.ok(false, "decode ignored the message")
            }
        } catch {
            c.ok(false, "decode threw \(error)")
        }
        c.done()
    }
    for x in v["messageRejects"].a {
        let c: Case = Case("messageRejects", x["name"].s)
        let hex: [UInt8] = hexOf(x["hex"])
        let e: String? = errName { _ = try SyncMessageCodec.decode(hex) }
        c.eq(jStrOpt(e), x["error"], "error")
        let r: String? = errReason { _ = try SyncMessageCodec.decode(hex) }
        if let want = x["reason"].optS, r != want {
            report.note("messageRejects \(x["name"].s): reason \(r ?? "none") (vector: \(want))")
        }
        c.done()
    }
    for x in v["messageBadBody"].a {
        let c: Case = Case("messageBadBody", x["name"].s)
        do {
            if let m = try SyncMessageCodec.decode(hexOf(x["hex"])) {
                c.eq(jStrOpt(m.bodyError?.name), x["bodyError"], "bodyError")
                c.eq(jFields(m), x["fields"], "fields")
                c.eq(SyncBodyCodec.errKey(m.body).map { jKey($0) } ?? .null, x["errKey"], "errKey")
            } else {
                c.ok(false, "decode ignored the message")
            }
        } catch {
            c.ok(false, "decode threw \(error)")
        }
        c.done()
    }
    for x in v["messageIgnored"].a {
        let c: Case = Case("messageIgnored", x["name"].s)
        do {
            let m: SyncMessage? = try SyncMessageCodec.decode(hexOf(x["hex"]))
            c.ok(m == nil, "decoded an unknown type")
        } catch {
            c.ok(false, "decode threw \(error)")
        }
        c.done()
    }
    for x in v["hbHops"].a {
        let c: Case = Case("hbHops", x["name"].s)
        do {
            let out: [UInt8] = try SyncMessageCodec.hbSetHops(hexOf(x["inHex"]), hops: 1)
            c.eq(jHex(out), x["outHex"], "patched")
            if let m = try SyncMessageCodec.decode(out) {
                c.eq(jInt(m.int("hops")), .int(1), "hops after patch")
            }
        } catch {
            c.ok(false, "threw \(error)")
        }
        c.done()
    }
}

func jFrameEvent(_ e: SyncFrameEvent) -> JV {
    switch e {
    case .deliver(let b):
        return .obj(["deliver": jHex(b)])
    case .badFrame(let r):
        return .obj(["badFrame": .str(r)])
    case .errTooBig(let t):
        return .obj(["errTooBig": .int(Int64(t))])
    case .errProto(let ver):
        return .obj(["errProto": .int(Int64(ver))])
    }
}

func checkFrames(_ v: JV) {
    for x in v["frames"].a {
        let c: Case = Case("frames", x["name"].s)
        let mtu: Int = Int(x["mtu"].i)
        var fr: SyncFragmenter = SyncFragmenter(counter: Int(x["startCounter"].i), seq: Int(x["startSeq"].i))
        var frames: [[UInt8]] = []
        var perMessage: [JV] = []
        for m in x["messages"].a {
            let part: [[UInt8]] = fr.fragment(hexOf(m), mtu: mtu)
            perMessage.append(.int(Int64(part.count)))
            frames.append(contentsOf: part)
        }
        c.eq(jHexList(frames), x["frames"], "frames")
        c.eq(.int(Int64(SyncFrames.chunkSize(mtu: mtu))), x["chunk"], "chunk")
        if x.has("framesPerMessage") {
            c.eq(.arr(perMessage), x["framesPerMessage"], "framesPerMessage")
        }
        c.done()
    }
    for x in v["reassembly"].a {
        let c: Case = Case("reassembly", x["name"].s)
        var ra: SyncReassembler = SyncReassembler(maxMsg: Int(x["maxMsg"].i),
                                                  expected: Int(x["startExpectedSeq"].optI ?? 0))
        var got: [JV] = []
        for f in x["frames"].a {
            for e in ra.feed(hexOf(f)) {
                got.append(jFrameEvent(e))
            }
        }
        c.eq(.arr(got), x["expect"], "actions")
        c.done()
    }
}

func checkPages(_ v: JV) {
    for x in v["pages"].a {
        let c: Case = Case("pages", x["name"].s)
        let pull: SyncMessage = messageOf(SyncMsgType.pull, x["pull"])
        do {
            c.eq(jHex(try SyncMessageCodec.encode(pull)), x["pullHex"], "pullHex")
        } catch {
            c.ok(false, "PULL encode threw \(error)")
        }
        var entries: [SyncFeedEntry] = []
        for e in x["entries"].a {
            let body: [UInt8] = hexOf(e["bodyHex"])
            let origin: [UInt8]? = (try? SyncBodyCodec.decode(body))?.origin
            entries.append(SyncFeedEntry(seq: e["seq"].i, body: body, origin: origin, syncFrom: optHexOf(e["syncFrom"])))
        }
        let excl: Bool = (pull.int("exclude") ?? 0) == 1 && x["excludeOk"].b
        do {
            let r: (recs: [[UInt8]], pageEnd: SyncPageEnd) = try SyncFeed.servePage(
                entries: entries, durableHigh: x["durableHigh"].i, since: pull.int("since") ?? 0,
                limit: pull.int("limit") ?? SyncConst.pullLimitDefault,
                maxBytes: pull.int("maxBytes") ?? SyncConst.pullMaxBytesDefault, excludeActive: excl,
                puller: hexOf(x["puller"]), reqId: pull.int("reqId") ?? 0)
            let want: JV = x["expect"]
            c.eq(jHexList(r.recs), want["recs"], "recs")
            var seqs: [JV] = []
            for m in r.recs {
                let decoded: SyncMessage? = (try? SyncMessageCodec.decode(m)) ?? nil
                seqs.append(jInt(decoded?.int("seq")))
            }
            c.eq(.arr(seqs), want["recSeqs"], "recSeqs")
            var pe: [String: JV] = [:]
            for (k, val) in r.pageEnd.fields {
                pe[k] = jValue(val)
            }
            c.eq(.obj(pe), want["pageEnd"], "pageEnd")
            c.eq(jHex(try r.pageEnd.encode()), want["pageEndHex"], "pageEndHex")
        } catch {
            c.ok(false, "servePage threw \(error)")
        }
        c.done()
    }
}

func routeSessions(_ j: JV, sub: String, up: String) -> [SyncRouteSession] {
    var out: [SyncRouteSession] = []
    for s in j.a {
        out.append(SyncRouteSession(peer: hexOf(s["peer"]), subscribed: s[sub].b, up: s[up].b))
    }
    return out
}

func jRoute(_ r: SyncRoute) -> JV {
    return .obj(["targets": jHexList(r.targets), "seenBy": jHexList(r.seenBy)])
}

func checkRouting(_ v: JV) {
    let r: JV = v["routing"]
    for x in r["localRec"].a {
        let c: Case = Case("routing.localRec", x["name"].s)
        let got: SyncRoute = SyncRouting.localRec(selfId: hexOf(x["self"]),
                                                  sessions: routeSessions(x["sessions"], sub: "subRecords", up: "authed"))
        c.eq(jRoute(got), x["expect"], "route")
        c.done()
    }
    for x in r["liveRec"].a {
        let c: Case = Case("routing.liveRec", x["name"].s)
        let got: SyncRoute = SyncRouting.liveRec(selfId: hexOf(x["self"]), sender: hexOf(x["sender"]),
                                                 origin: optHexOf(x["origin"]), seenBy: hexList(x["seenBy"]),
                                                 sessions: routeSessions(x["sessions"], sub: "subRecords", up: "authed"))
        c.eq(jRoute(got), x["expect"], "route")
        c.done()
    }
    for x in r["evtRelay"].a {
        let c: Case = Case("routing.evtRelay", x["name"].s)
        let got: SyncRoute = SyncRouting.evtRelay(selfId: hexOf(x["self"]), sender: hexOf(x["sender"]),
                                                  origin: hexOf(x["origin"]), seenBy: hexList(x["seenBy"]),
                                                  sessions: routeSessions(x["sessions"], sub: "subEvents", up: "member"))
        c.eq(jRoute(got), x["expect"], "route")
        c.done()
    }
    for x in r["androidRoute"].a {
        let c: Case = Case("routing.androidRoute", x["name"].s)
        var ios: SyncRouteSession? = nil
        if !x["ios"].isNull {
            ios = SyncRouteSession(peer: hexOf(x["ios"]["peer"]), subscribed: x["ios"]["subEvents"].b,
                                   up: x["ios"]["up"].b)
        }
        var hub: SyncRouteSession? = nil
        if !x["hub"].isNull {
            hub = SyncRouteSession(peer: hexOf(x["hub"]["peer"]), subscribed: false, up: x["hub"]["up"].b)
        }
        var links: [SyncHbLink] = []
        for l in x["hubHbLinks"].a {
            links.append(SyncHbLink(peerId: hexOf(l["peerId"]), peerKind: UInt8(truncatingIfNeeded: l["peerKind"].i),
                                    flags: UInt8(truncatingIfNeeded: l["flags"].i)))
        }
        let got: SyncAndroidRoute = SyncRouting.androidRoute(selfId: hexOf(x["self"]), ios: ios, hub: hub,
                                                             hubHbAgeMs: x["hubHbAgeMs"].optI, hubHbLinks: links)
        c.eq(.obj(["route": .int(Int64(got.route)), "target": jHex(got.target), "seenBy": jHexList(got.seenBy)]),
             x["expect"], "route")
        c.done()
    }
    for x in r["hbForward"].a {
        let c: Case = Case("routing.hbForward", x["name"].s)
        let got: [[UInt8]] = SyncRouting.hbForward(selfId: hexOf(x["self"]), sender: hexOf(x["sender"]),
                                                   deviceId: hexOf(x["deviceId"]), hops: x["hops"].i,
                                                   sessions: routeSessions(x["sessions"], sub: "subHeartbeats", up: "member"))
        c.eq(.obj(["targets": jHexList(got)]), x["expect"], "targets")
        c.done()
    }
    for x in r["hbReplace"].a {
        let c: Case = Case("routing.hbReplace", x["name"].s)
        var stored: SyncHbStamp? = nil
        if !x["stored"].isNull {
            stored = SyncHbStamp(bootId: x["stored"]["bootId"].i, hbSeq: x["stored"]["hbSeq"].i)
        }
        let incoming: SyncHbStamp = SyncHbStamp(bootId: x["incoming"]["bootId"].i, hbSeq: x["incoming"]["hbSeq"].i)
        c.eq(.bool(SyncRouting.hbReplaces(stored: stored, incoming: incoming)), x["expect"], "replaces")
        c.done()
    }
    for x in r["subs"].a {
        let c: Case = Case("routing.subs", "\(x["selfKind"].i)->\(x["peerKind"].i)")
        let got: Int64 = SyncRouting.subsFor(selfKind: UInt8(truncatingIfNeeded: x["selfKind"].i),
                                             peerKind: UInt8(truncatingIfNeeded: x["peerKind"].i))
        c.eq(.int(got), x["subs"], "subs")
        c.done()
    }
    for x in r["caps"].a {
        let c: Case = Case("routing.caps", "kind \(x["kind"].i)")
        c.eq(.int(SyncCaps.forKind(UInt8(truncatingIfNeeded: x["kind"].i))), x["caps"], "caps")
        c.done()
    }
}

func jWindows(_ ws: [SyncEvtWindow]) -> JV {
    var out: [JV] = []
    for w in ws {
        out.append(.obj(["epoch": .int(w.epoch), "hc": .int(w.hc), "bits": .str(hex64(w.bits))]))
    }
    return .arr(out)
}

func checkEvents(_ v: JV) {
    for sc in v["eventDedupe"].a {
        let c: Case = Case("eventDedupe", sc["name"].s)
        let d: SyncEvtDedupe = SyncEvtDedupe()
        var idx: Int = 0
        for st in sc["steps"].a {
            let o: [UInt8] = hexOf(st["origin"])
            let epoch: Int64 = st["epoch"].i
            let got: JV
            if st["op"].s == "evt" {
                let r: (result: SyncEvtResult, lost: Int64) = d.receive(origin: o, epoch: epoch, seq: st["seq"].i)
                got = .obj(["result": .str(r.result.rawValue), "lost": .int(r.lost),
                            "holes": .bool(d.hasHoles(origin: o, epoch: epoch)), "windows": jWindows(d.windows(o))])
            } else {
                let r: (lost: Int64, requests: [SyncEvtSinceRequest]) = d.onGap(
                    origin: o, epoch: epoch, firstAvail: st["firstAvail"].i, lastAvail: st["lastAvail"].i,
                    curEpoch: st["curEpoch"].i)
                var reqs: [JV] = []
                for q in r.requests {
                    reqs.append(.obj(["epoch": .int(q.epoch), "afterSeq": .int(q.afterSeq)]))
                }
                got = .obj(["lost": .int(r.lost), "requests": .arr(reqs), "windows": jWindows(d.windows(o))])
            }
            c.eq(got, st["expect"], "step \(idx) (\(st["op"].s))")
            idx += 1
        }
        c.done()
    }
    for x in v["replayPlan"].a {
        let c: Case = Case("replayPlan", x["name"].s)
        var ring: [(epoch: Int64, seq: Int64)] = []
        for item in x["ring"].a {
            let pair: [JV] = item.a
            if pair.count == 2 {
                ring.append((epoch: pair[0].i, seq: pair[1].i))
            }
        }
        let plan: [SyncReplayStep] = SyncReplay.plan(ring: ring, curEpoch: x["curEpoch"].i, curSeq: x["curSeq"].i,
                                                     epoch: x["epoch"].i, afterSeq: x["afterSeq"].i)
        var got: [JV] = []
        for p in plan {
            switch p {
            case .replay(let e, let s):
                got.append(.obj(["replay": .obj(["epoch": .int(e), "seq": .int(s)])]))
            case .gap(let e, let first, let last, let cur):
                got.append(.obj(["gap": .obj(["epoch": .int(e), "firstAvail": .int(first), "lastAvail": .int(last),
                                              "curEpoch": .int(cur)])]))
            }
        }
        c.eq(.arr(got), x["expect"], "plan")
        c.done()
    }
}

// MARK: - Sessions

final class NonceQueue {
    var items: [[UInt8]]
    var exhausted: Bool = false

    init(_ items: [[UInt8]]) {
        self.items = items
    }

    func next() -> [UInt8] {
        if items.isEmpty {
            exhausted = true
            return SyncConst.zero8
        }
        return items.removeFirst()
    }
}

func groupOf(_ idHex: JV, _ keyHex: JV) -> SyncGroup? {
    if idHex.isNull {
        return nil
    }
    return SyncGroup(groupId: hexOf(idHex), groupKey: hexOf(keyHex))
}

func jAction(_ a: SyncSessionAction) -> JV {
    switch a {
    case .send(let type, let bytes):
        return .obj(["a": .str("send"), "type": .str(SyncMsgType.name(type)), "hex": jHex(bytes)])
    case .state(let s):
        return .obj(["a": .str("state"), "to": .str(s.rawValue)])
    case .deliver(let m):
        return .obj(["a": .str("deliver"), "type": .str(m.typeName)])
    case .commit(let wm):
        return .obj(["a": .str("commit"), "wm": .int(wm)])
    case .group(let g, let rekey):
        return .obj(["a": .str("group"), "groupId": jHex(g.groupId), "groupKey": jHex(g.groupKey), "rekey": .bool(rekey)])
    case .node(let what):
        return .obj(["a": .str("node"), "what": .str(what.rawValue)])
    case .disconnect(let reason, let retryMs):
        return .obj(["a": .str("disconnect"), "reason": .str(reason.rawValue), "retryMs": jInt(retryMs)])
    }
}

func jSnapshot(_ s: SyncSession) -> JV {
    var timers: [String: JV] = [:]
    for (name, due) in s.timers {
        timers[name.rawValue] = .int(due)
    }
    var d: [String: JV] = ["state": .str(s.state.rawValue), "timers": .obj(timers)]
    if let ps = s.peerState {
        d["peer"] = .obj(["dbId": jHex(ps.dbId), "wm": .int(ps.wm), "excludeOk": .bool(ps.excludeOk)])
    }
    return .obj(d)
}

func inputOf(_ j: JV) -> SyncSessionInput? {
    switch j["in"].s {
    case "link_up":
        return .linkUp(mtu: Int(j["mtu"].optI ?? 185))
    case "link_down":
        return .linkDown
    case "rx":
        return .rx(hexOf(j["hex"]))
    case "timer":
        guard let t = SyncTimer(rawValue: j["name"].s) else {
            return nil
        }
        return .timer(t)
    case "group_changed":
        return .groupChanged
    case "rekey":
        return .rekey
    case "pull_now":
        return .pullNow
    default:
        return nil
    }
}

func checkSessions(_ v: JV) {
    for sc in v["sessions"].a {
        let c: Case = Case("sessions", sc["name"].s)
        let cfg: JV = sc["config"]
        let ctxJ: JV = sc["ctx"]
        let config: SyncSessionConfig = SyncSessionConfig(
            role: cfg["role"].s == "central" ? .central : .peripheral, deviceId: hexOf(cfg["deviceId"]),
            kind: UInt8(truncatingIfNeeded: cfg["kind"].i), bootId: cfg["bootId"].i, maxMsg: cfg["maxMsg"].i,
            caps: cfg["caps"].optI, version: cfg["version"].optS, name: cfg["name"].optS,
            peerKind: u8Opt(cfg["peerKind"]), tracksEvents: cfg["tracksEvents"].b, isHub: cfg["isHub"].b)
        let peers: SyncPeerTable = SyncPeerTable()
        for (k, p) in ctxJ["peers"].o {
            peers.byId[k] = SyncPeerState(dbId: hexOf(p["dbId"]), wm: p["wm"].i, excludeOk: p["excludeOk"].b)
        }
        let nonces: NonceQueue = NonceQueue(hexList(ctxJ["nonces"]))
        let base: Int64? = ctxJ["clockBaseMs"].optI
        let clock: (Int64) -> Int64
        if let b = base {
            clock = { t in b + t }
        } else {
            clock = { _ in 0 }
        }
        let ctx: SyncSessionContext = SyncSessionContext(
            group: groupOf(ctxJ["groupId"], ctxJ["groupKey"]), dbId: hexOf(ctxJ["dbId"]), feedHigh: ctxJ["feedHigh"].i,
            clock: clock, ready: ctxJ["ready"].b, nextNonce: { nonces.next() }, peers: peers)
        let session: SyncSession = SyncSession(config: config, ctx: ctx)
        var idx: Int = 0
        for st in sc["steps"].a {
            if st.has("ctx") {
                let x: JV = st["ctx"]
                ctx.group = groupOf(x["groupId"], x["groupKey"])
                ctx.dbId = hexOf(x["dbId"])
                ctx.feedHigh = x["feedHigh"].i
                ctx.ready = x["ready"].b
            }
            let what: String = "step \(idx) (\(st["in"]["in"].s))"
            idx += 1
            var acts: [JV] = []
            if let input = inputOf(st["in"]) {
                for a in session.handle(t: st["t"].i, input) {
                    acts.append(jAction(a))
                }
            } else if st["in"]["in"].s != "timer" {
                c.ok(false, what + ": unknown input")
            }
            c.eq(.arr(acts), st["out"], what + " actions")
            c.eq(jSnapshot(session), st["after"], what + " snapshot")
        }
        c.ok(!nonces.exhausted, "ran out of nonces")
        c.ok(session.encodeFailures == 0, "the session failed to encode \(session.encodeFailures) message(s)")
        c.done()
    }
}

// MARK: - Transcripts

func checkTranscript(_ path: String, _ j: JV) {
    let file: String = path.split(separator: "/").last.map { String($0) } ?? path
    var keys: [String: [UInt8]] = [:]
    var maxMsg: [String: Int] = [:]
    for (name, n) in j["nodes"].o {
        if let k = n["groupKey"].optS, let g = n["groupId"].optS {
            keys[g] = SyncHex.decode(k) ?? []
        }
        maxMsg[name] = Int(n["maxMsg"].optI ?? Int64(SyncConst.phoneMaxMsg))
    }
    var frag: [String: SyncFragmenter] = [:]
    var reasm: [String: SyncReassembler] = [:]
    var links: [String: (central: String, peripheral: String, mtu: Int)] = [:]
    var helloC: [String: SyncMessage] = [:]
    var helloP: [String: SyncMessage] = [:]
    for st in j["steps"].a {
        let ev: String = st["ev"].s
        let link: String = st["link"].s
        if ev == "link_up" {
            let central: String = st["central"].s
            let peripheral: String = st["peripheral"].s
            links[link] = (central, peripheral, Int(st["mtu"].i))
            for who in [central, peripheral] {
                frag[link + "|" + who] = SyncFragmenter()
                reasm[link + "|" + who] = SyncReassembler(maxMsg: maxMsg[who] ?? SyncConst.phoneMaxMsg)
            }
            continue
        }
        if ev != "msg" {
            continue
        }
        let c: Case = Case("transcript messages", "\(file) step \(st["i"].i) \(st["type"].s)")
        let data: [UInt8] = hexOf(st["hex"])
        let from: String = st["from"].s
        let to: String = st["to"].s
        c.eq(.str(data.isEmpty ? "" : SyncMsgType.name(data[0])), st["type"], "type")
        if st["fields"].isNull {
            c.ok(st.has("decodeError"), "fields null without decodeError")
            let e: String? = errName { _ = try SyncMessageCodec.decode(data) }
            c.eq(jStrOpt(e), .str("BAD_MSG"), "decode error")
        } else {
            do {
                if let m = try SyncMessageCodec.decode(data) {
                    c.eq(jFields(m), st["fields"], "decode")
                    c.eq(jHex(try SyncMessageCodec.encode(m)), st["hex"], "re-encode")
                    if m.type == SyncMsgType.join, let gid = m.bytes("groupId"), let key = m.bytes("groupKey") {
                        keys[SyncHex.encode(gid)] = key
                        c.ok(SyncGroupAuth.groupId(key: key) == gid, "JOIN groupId does not match its key")
                    }
                    let central: String = links[link]?.central ?? ""
                    if m.type == SyncMsgType.hello && from == central {
                        helloC[link] = m
                    } else if m.type == SyncMsgType.hello, let proof = m.bytes("proof") {
                        if let hc = helloC[link], let gid = m.bytes("groupId"), let key = keys[SyncHex.encode(gid)],
                           let nc = hc.bytes("nonce"), let np = m.bytes("nonce"), let ic = hc.bytes("deviceId"),
                           let ip = m.bytes("deviceId") {
                            let want: [UInt8] = SyncGroupAuth.proofP(key: key, nonceC: nc, nonceP: np, idC: ic, idP: ip)
                            c.eq(jHex(proof), jHex(want), "proofP")
                        } else {
                            c.ok(false, "proofP: no central HELLO or key")
                        }
                        helloP[link] = m
                    } else if m.type == SyncMsgType.auth, let hp = helloP[link], st["by"].s == "session" {
                        if let hc = helloC[link], let gid = hp.bytes("groupId"), let key = keys[SyncHex.encode(gid)],
                           let nc = hc.bytes("nonce"), let np = hp.bytes("nonce"), let ic = hc.bytes("deviceId"),
                           let ip = hp.bytes("deviceId"), let proof = m.bytes("proof") {
                            let want: [UInt8] = SyncGroupAuth.proofC(key: key, nonceC: nc, nonceP: np, idC: ic, idP: ip)
                            c.eq(jHex(proof), jHex(want), "proofC")
                        } else {
                            c.ok(false, "proofC: no HELLOs or key")
                        }
                    }
                } else {
                    c.ok(false, "decode ignored the message")
                }
            } catch {
                c.ok(false, "decode threw \(error)")
            }
        }
        let fk: String = link + "|" + from
        let rk: String = link + "|" + to
        if var f = frag[fk], var r = reasm[rk], let l = links[link] {
            let frames: [[UInt8]] = f.fragment(data, mtu: l.mtu)
            frag[fk] = f
            c.eq(jHexList(frames), st["frames"], "frames")
            var got: [JV] = []
            for fr in frames {
                for e in r.feed(fr) {
                    got.append(jFrameEvent(e))
                }
            }
            reasm[rk] = r
            c.eq(.arr(got), .arr([jFrameEvent(.deliver(data))]), "reassembly")
        } else {
            c.ok(false, "message on a link that is not up")
        }
        c.done()
    }
    let c: Case = Case("transcripts", file)
    for (name, n) in j["final"]["nodes"].o {
        for e in n["ledger"].a {
            do {
                let entry: SyncLedgerEntry = try SyncLedgerEntry(body: hexOf(e["b"]), seq: e["s"].i, syncFrom: optHexOf(e["f"]))
                c.eq(jEntry(entry), e, "final \(name) \(e["key"].s)")
            } catch {
                c.ok(false, "final \(name) \(e["key"].s): body does not decode: \(error)")
            }
        }
    }
    c.done()
}

// MARK: - Main

func readJSON(_ path: String) -> JV? {
    guard let data = FileManager.default.contents(atPath: path) else {
        print("SYNC: cannot read \(path)")
        return nil
    }
    do {
        return try JSONParser.parse([UInt8](data))
    } catch let e as JSONFailure {
        print("SYNC: \(path) is not valid JSON: \(e.message)")
    } catch {
        print("SYNC: \(path) is not valid JSON")
    }
    return nil
}

let args: [String] = CommandLine.arguments
let dir: String = args.count > 1 ? args[1] : "tools/sync"

guard let vectors = readJSON(dir + "/vectors.json") else {
    exit(2)
}
if vectors["schema"].i != 1 || vectors["proto"].i != Int64(SyncConst.proto) {
    print("SYNC: unexpected schema \(vectors["schema"].i) / proto \(vectors["proto"].i)")
    exit(2)
}

checkConstants(vectors)
checkPrimitives(vectors)
checkBodies(vectors)
checkApply(vectors)
checkMessages(vectors)
checkFrames(vectors)
checkPages(vectors)
checkRouting(vectors)
checkEvents(vectors)
checkSessions(vectors)

let transcriptDir: String = dir + "/transcripts"
var transcriptFiles: [String] = []
do {
    transcriptFiles = try FileManager.default.contentsOfDirectory(atPath: transcriptDir)
        .filter { $0.hasSuffix(".json") }
        .sorted()
} catch {
    print("SYNC: cannot list \(transcriptDir)")
    exit(2)
}
if transcriptFiles.isEmpty {
    print("SYNC: no transcripts in \(transcriptDir)")
    exit(2)
}
for f in transcriptFiles {
    let path: String = transcriptDir + "/" + f
    guard let t = readJSON(path) else {
        exit(2)
    }
    checkTranscript(path, t)
}

for n in report.notes.prefix(20) {
    print("NOTE: " + n)
}

var parts: [String] = []
for g in report.groupOrder {
    let p: Int = report.passes[g] ?? 0
    let f: Int = report.fails[g] ?? 0
    parts.append(f == 0 ? "\(g) \(p)" : "\(g) \(p)/\(p + f) (\(f) FAILED)")
}
let total: Int = report.totalPasses + report.totalFails
if report.totalFails == 0 {
    print("SYNC: all \(total) checks pass (\(report.notes.count) informative reason notes): " + parts.joined(separator: ", "))
    exit(0)
}
print("SYNC: \(report.totalFails) of \(total) checks FAILED: " + parts.joined(separator: ", "))
exit(1)
