import Foundation

// Checks the Swift core against the Android core.
//
// `vectors.json` (next to this file) is written by tools/parity from the Android Kotlin sources:
// for a fixed set of packets it holds what every core function returns on Android. This program
// recomputes each value with the Swift core and prints the ones that differ.
//
//   swiftc -O -swift-version 5 -o /tmp/parity ios/MagicMaker/Core/*.swift ios/ParityCheck/main.swift
//   /tmp/parity ios/ParityCheck/vectors.json
//
// It is not part of the app target. It runs on Linux in CI (.github/workflows/ios-core-parity.yml),
// so it uses Foundation only.

// MARK: - Values computed by the Swift core

/// A JSON-shaped value built from Swift results, compared against the parsed vectors.
enum J {
    case null
    case bool(Bool)
    case int(Int)
    case str(String)
    case arr([J])
    case obj([String: J])
}

func jOptStr(_ value: String?) -> J {
    if let v = value { return J.str(v) }
    return J.null
}

func jOptInt(_ value: Int?) -> J {
    if let v = value { return J.int(v) }
    return J.null
}

func jInts(_ values: [Int]) -> J {
    var out: [J] = []
    for v in values { out.append(J.int(v)) }
    return J.arr(out)
}

func jOptInts(_ values: [Int?]) -> J {
    var out: [J] = []
    for v in values { out.append(jOptInt(v)) }
    return J.arr(out)
}

func jStrs(_ values: [String]) -> J {
    var out: [J] = []
    for v in values { out.append(J.str(v)) }
    return J.arr(out)
}

// MARK: - Reading the vectors

func asDict(_ value: Any?) -> [String: Any] {
    guard let v = value else { return [:] }
    if let d = v as? [String: Any] { return d }
    return [:]
}

func asList(_ value: Any?) -> [Any] {
    guard let v = value else { return [] }
    if let a = v as? [Any] { return a }
    return []
}

func asString(_ value: Any?) -> String? {
    guard let v = value else { return nil }
    return v as? String
}

func asInt(_ value: Any?) -> Int? {
    guard let v = value else { return nil }
    if v is String { return nil }
    if v is NSNull { return nil }
    if let i = v as? Int { return i }
    if let n = v as? NSNumber { return n.intValue }
    return nil
}

func asBool(_ value: Any?) -> Bool? {
    guard let v = value else { return nil }
    if v is String { return nil }
    if v is NSNull { return nil }
    if let b = v as? Bool { return b }
    if let n = v as? NSNumber { return n.boolValue }
    return nil
}

/// `list[index]`, or nil when the list is shorter than that.
func listItem(_ list: [Any], _ index: Int) -> Any? {
    if index >= 0 && index < list.count { return list[index] }
    return nil
}

func intList(_ value: Any?) -> [Int] {
    var out: [Int] = []
    for item in asList(value) {
        out.append(asInt(item) ?? 0)
    }
    return out
}

func stringList(_ value: Any?) -> [String] {
    var out: [String] = []
    for item in asList(value) {
        out.append(asString(item) ?? "")
    }
    return out
}

// MARK: - Comparing

/// Kotlin enum names are written `CENTRE_PULSE`; Swift raw values are `centrePulse`.
func norm(_ s: String) -> String {
    return s.lowercased().replacingOccurrences(of: "_", with: "")
}

/// Fields that hold an enum name, compared through `norm`.
let enumKeys: Set<String> = ["kind", "category", "type", "matchKind"]

/// What Android records for a call that throws. Swift returns a value there, so it is not compared.
let throwsMarker = "THROWS"

let maxPrinted = 400
let clipLimit = 280

var checks = 0
var mismatches = 0
var skipped = 0
var printedLines = 0

func clip(_ s: String) -> String {
    if s.count <= clipLimit { return s }
    let more = s.count - clipLimit
    return String(s.prefix(clipLimit)) + "...(+\(more) chars)"
}

func showAny(_ value: Any?) -> String {
    guard let v = value else { return "<missing>" }
    if v is NSNull { return "null" }
    if let s = v as? String { return "\"" + s + "\"" }
    if let a = v as? [Any] {
        var parts: [String] = []
        for item in a { parts.append(showAny(item)) }
        return "[" + parts.joined(separator: ",") + "]"
    }
    if let d = v as? [String: Any] {
        var parts: [String] = []
        for key in d.keys.sorted() { parts.append(key + ":" + showAny(d[key])) }
        return "{" + parts.joined(separator: ",") + "}"
    }
    return "\(v)"
}

func showJ(_ value: J) -> String {
    switch value {
    case .null:
        return "null"
    case .bool(let b):
        return b ? "true" : "false"
    case .int(let i):
        return String(i)
    case .str(let s):
        return "\"" + s + "\""
    case .arr(let items):
        var parts: [String] = []
        for item in items { parts.append(showJ(item)) }
        return "[" + parts.joined(separator: ",") + "]"
    case .obj(let fields):
        var parts: [String] = []
        for key in fields.keys.sorted() {
            parts.append(key + ":" + showJ(fields[key] ?? J.null))
        }
        return "{" + parts.joined(separator: ",") + "}"
    }
}

/// The first place two values differ: where, and what each side has there.
struct Difference {
    let path: String
    let android: String
    let ios: String
}

func difference(_ expected: Any?, _ actual: J, _ key: String, _ path: String) -> Difference? {
    guard let e = expected else {
        return Difference(path: path, android: "<missing>", ios: clip(showJ(actual)))
    }
    func whole() -> Difference {
        return Difference(path: path, android: clip(showAny(e)), ios: clip(showJ(actual)))
    }
    switch actual {
    case .null:
        if e is NSNull { return nil }
        return whole()
    case .bool(let b):
        if let eb = asBool(e), eb == b { return nil }
        return whole()
    case .int(let i):
        if let ei = asInt(e), ei == i { return nil }
        return whole()
    case .str(let s):
        guard let es = e as? String else { return whole() }
        if es == s { return nil }
        if enumKeys.contains(key) && norm(es) == norm(s) { return nil }
        return whole()
    case .arr(let items):
        guard let ea = e as? [Any] else { return whole() }
        if ea.count != items.count {
            let counts = "(android has \(ea.count) items, ios has \(items.count)) "
            return Difference(path: path, android: counts + clip(showAny(e)), ios: clip(showJ(actual)))
        }
        var i = 0
        while i < items.count {
            if let d = difference(ea[i], items[i], key, path + "[\(i)]") { return d }
            i += 1
        }
        return nil
    case .obj(let fields):
        guard let eo = e as? [String: Any] else { return whole() }
        for k in fields.keys.sorted() {
            let field: J = fields[k] ?? J.null
            if let d = difference(eo[k], field, k, path + "." + k) { return d }
        }
        for k in eo.keys.sorted() {
            if fields[k] == nil {
                return Difference(path: path + "." + k, android: clip(showAny(eo[k])), ios: "<not computed>")
            }
        }
        return nil
    }
}

func fail(_ function: String, _ subject: String, _ android: String, _ ios: String) {
    mismatches += 1
    if printedLines < maxPrinted {
        printedLines += 1
        let name = subject.isEmpty ? "<empty>" : subject
        print("MISMATCH \(function) \(name): android=\(android) ios=\(ios)")
    }
}

/// One comparison. `subject` is the packet hex, or whatever else identifies the case.
func check(_ function: String, _ subject: String, _ expected: Any?, _ actual: J) {
    if let s = expected as? String, s == throwsMarker {
        skipped += 1
        return
    }
    checks += 1
    if let d = difference(expected, actual, function, "") {
        fail(function + d.path, subject, d.android, d.ios)
    }
}

/// Element-by-element comparison of a list, so one bad row does not hide the others.
func checkList(_ function: String, _ expected: Any?, _ actual: [J]) {
    guard let ea = expected as? [Any] else {
        check(function, "-", expected, J.arr(actual))
        return
    }
    if ea.count != actual.count {
        checks += 1
        fail(function, "-", "\(ea.count) items", "\(actual.count) items")
        return
    }
    var i = 0
    while i < actual.count {
        check(function, "#\(i)", ea[i], actual[i])
        i += 1
    }
}

/// One object of the vectors file. Any key the checker never asks for is reported, so the
/// checker cannot silently fall behind the generator.
final class Section {
    let name: String
    let dict: [String: Any]
    var used: Set<String> = []

    init(_ name: String, _ value: Any?) {
        self.name = name
        self.dict = asDict(value)
    }

    func get(_ key: String) -> Any? {
        used.insert(key)
        return dict[key]
    }

    func finish() {
        if dict.isEmpty {
            checks += 1
            fail(name, "-", "<missing or empty>", "<nothing to compare>")
        }
        for key in dict.keys.sorted() {
            if !used.contains(key) {
                checks += 1
                fail(name + "." + key, "-", "<present in vectors.json>", "<not checked by ios/ParityCheck/main.swift>")
            }
        }
    }
}

// MARK: - Shapes shared by several sections

func classifiedJ(_ value: ClassifiedPacket?) -> J {
    guard let c = value else { return J.null }
    var d: [String: J] = [:]
    d["hex"] = J.str(c.hex)
    d["label"] = J.str(c.label)
    d["category"] = J.str(c.category.rawValue)
    d["typeInfo"] = J.str(c.typeInfo)
    d["colors"] = J.str(c.colors)
    d["simKey"] = J.str(c.simKey)
    return J.obj(d)
}

func packetJ(_ value: MagicPacket?) -> J {
    guard let p = value else { return J.null }
    var d: [String: J] = [:]
    d["id"] = J.int(Int(p.id))
    d["hex"] = J.str(p.hex)
    d["label"] = J.str(p.label)
    d["category"] = J.str(p.category.rawValue)
    d["typeInfo"] = J.str(p.typeInfo)
    d["colors"] = J.str(p.colors)
    d["simKey"] = J.str(p.simKey)
    d["userRecorded"] = J.bool(p.userRecorded)
    d["rssi"] = jOptInt(p.rssi)
    d["wandVerified"] = J.bool(p.wandVerified)
    return J.obj(d)
}

func packetsJ(_ packets: [MagicPacket]) -> [J] {
    var out: [J] = []
    for p in packets { out.append(packetJ(p)) }
    return out
}

func patternJ(_ p: PacketPattern) -> J {
    var d: [String: J] = [:]
    d["id"] = J.str(p.id)
    d["label"] = J.str(p.label)
    d["matchKind"] = J.str(String(describing: p.matchKind))
    d["matchValue"] = J.str(p.matchValue)
    d["defaultHex"] = J.str(p.defaultHex)
    d["group"] = jOptStr(p.group)
    return J.obj(d)
}

func patternsJ(_ patterns: [PacketPattern]) -> [J] {
    var out: [J] = []
    for p in patterns { out.append(patternJ(p)) }
    return out
}

func framingJ(_ f: LabPacketBuilder.Framing) -> J {
    var d: [String: J] = [:]
    d["channelMarker"] = J.bool(f.channelMarker)
    d["wakePrefix"] = J.bool(f.wakePrefix)
    d["timing"] = J.int(f.timing)
    return J.obj(d)
}

func categoryNamed(_ name: String) -> MagicCategory {
    for c in MagicCategory.allCases {
        if norm(c.rawValue) == norm(name) { return c }
    }
    return MagicCategory.unknown
}

func packetFromVectors(_ value: Any?) -> MagicPacket {
    let d = asDict(value)
    let id: Int = asInt(d["id"]) ?? 0
    return MagicPacket(
        id: Int64(id),
        hex: asString(d["hex"]) ?? "",
        label: asString(d["label"]) ?? "",
        category: categoryNamed(asString(d["category"]) ?? ""),
        typeInfo: asString(d["typeInfo"]) ?? "",
        colors: asString(d["colors"]) ?? "",
        simKey: asString(d["simKey"]) ?? "",
        userRecorded: asBool(d["userRecorded"]) ?? false,
        rssi: asInt(d["rssi"]),
        wandVerified: asBool(d["wandVerified"]) ?? false
    )
}

func packetsFromVectors(_ value: Any?) -> [MagicPacket] {
    var out: [MagicPacket] = []
    for item in asList(value) { out.append(packetFromVectors(item)) }
    return out
}

func classifiedFromVectors(_ value: Any?) -> ClassifiedPacket {
    let d = asDict(value)
    return ClassifiedPacket(
        hex: asString(d["hex"]) ?? "",
        label: asString(d["label"]) ?? "",
        category: categoryNamed(asString(d["category"]) ?? ""),
        typeInfo: asString(d["typeInfo"]) ?? "",
        colors: asString(d["colors"]) ?? "",
        simKey: asString(d["simKey"]) ?? ""
    )
}

/// What the app stores for a packet the classifier does not know (same as the generator).
func classifiedOrRaw(_ hex: String) -> ClassifiedPacket {
    if let c = MagicClassifier.classify(hex) { return c }
    let canonical = HexUtils.canonicalHex(hex)
    return ClassifiedPacket(
        hex: canonical, label: "Raw packet", category: MagicCategory.unknown,
        typeInfo: "raw", colors: "", simKey: "RAW:" + canonical
    )
}

func labType(named name: String) -> LabPacketBuilder.LabPacketType? {
    let wanted = norm(name)
    for t in LabPacketBuilder.LabPacketType.allCases {
        if norm(t.rawValue) == wanted { return t }
    }
    return nil
}

// MARK: - Per-packet values

/// Colours handed to `withColors` for every packet (same list as the generator).
let recolour: [Int] = [0x15, 0x02, 0x19, 0x0F, 0x01, 0x08, 0x1B]

func tlvJ(_ hex: String) -> J {
    guard let parsed = DisneyTlv.parse(hex) else { return J.null }
    var records: [J] = []
    for r in parsed.records {
        var d: [String: J] = [:]
        d["type"] = J.int(r.type)
        d["declaredLength"] = J.int(r.declaredLength)
        d["length"] = J.int(r.length)
        d["headHex"] = J.str(r.headHex())
        d["valueHex"] = J.str(r.valueHex())
        d["legacyStarlight"] = J.bool(r.legacyStarlight)
        d["truncated"] = J.bool(r.truncated)
        records.append(J.obj(d))
    }
    var out: [String: J] = [:]
    out["hex"] = J.str(parsed.hex)
    out["records"] = J.arr(records)
    out["malformed"] = jOptStr(parsed.malformed)
    return J.obj(out)
}

func anatomyJ(_ hex: String) -> J {
    var out: [J] = []
    for s in DisneyTlv.anatomy(hex) {
        var d: [String: J] = [:]
        d["hex"] = J.str(s.hex)
        d["title"] = J.str(s.title)
        d["detail"] = J.str(s.detail)
        d["kind"] = J.str(s.kind.rawValue)
        out.append(J.obj(d))
    }
    return J.arr(out)
}

func bandJ(_ hex: String) -> J {
    let m = BandEffectModel.from(hex)
    var d: [String: J] = [:]
    d["kind"] = J.str(m.kind.rawValue)
    d["colors"] = jInts(m.colors)
    d["perLed"] = jOptInts(m.perLed)
    d["buzz"] = J.int(m.buzz)
    d["durationMs"] = J.int(m.durationMs)
    d["fadeMs"] = J.int(m.fadeMs)
    d["alwaysOn"] = J.bool(m.alwaysOn)
    d["approximate"] = J.bool(m.approximate)
    d["note"] = J.str(m.note)
    d["rgb"] = jOptInt(m.rgb)
    d["lightsBand"] = J.bool(m.lightsBand)
    return J.obj(d)
}

func decodeJ(_ hex: String) -> J {
    guard let decoded = LabPacketBuilder.decode(hex) else { return J.null }
    var d: [String: J] = [:]
    d["type"] = J.str(decoded.type.rawValue)
    d["colors"] = jInts(decoded.colors)
    d["vibEnabled"] = J.bool(decoded.vibEnabled)
    d["vibPattern"] = J.int(decoded.vibPattern)
    d["rawHex"] = J.str(decoded.rawHex)
    d["channelMarker"] = J.bool(decoded.framing.channelMarker)
    d["wakePrefix"] = J.bool(decoded.framing.wakePrefix)
    d["timing"] = J.int(decoded.framing.timing)
    d["showIndex"] = J.int(decoded.showIndex)
    return J.obj(d)
}

func editableSlotsJ(_ hex: String) -> J {
    var out: [J] = []
    for slot in LabPacketBuilder.editableSlots(hex) {
        var d: [String: J] = [:]
        d["label"] = J.str(slot.label)
        d["hexIndex"] = J.int(slot.hexIndex)
        out.append(J.obj(d))
    }
    return J.arr(out)
}

let knownPacketKeys: Set<String> = [
    "hex", "canonicalHex", "isDisneyBlePacket", "isStarlightPacket", "legacyAdvertiseRejectReason",
    "hasCompleteStarlightPayload", "disneyHexScore", "extractSerial", "markerFrom", "isStoredFormat",
    "classify", "isShowControl", "isLibraryNoise", "rawLabel", "groupKey", "groupLabel",
    "libraryDedupeKey", "starlightColorIndex", "starlightLearnColorIndex", "starlightTxHex",
    "tlv", "anatomy", "band", "decode", "tailVibration", "withVibration3", "withTiming06",
    "withZoneMask3", "editableSlots", "slotColors", "withColors",
]

var unknownPacketKeys: Set<String> = []

func checkPacket(_ index: Int, _ value: Any) {
    let rec = asDict(value)
    guard let hex = asString(rec["hex"]) else {
        checks += 1
        fail("packets", "#\(index)", "<a record with a hex>", "<unreadable record>")
        return
    }

    check("canonicalHex", hex, rec["canonicalHex"], J.str(HexUtils.canonicalHex(hex)))
    check("isDisneyBlePacket", hex, rec["isDisneyBlePacket"], J.bool(HexUtils.isDisneyBlePacket(hex)))
    check("isStarlightPacket", hex, rec["isStarlightPacket"], J.bool(HexUtils.isStarlightPacket(hex)))
    check("legacyAdvertiseRejectReason", hex, rec["legacyAdvertiseRejectReason"], jOptStr(HexUtils.legacyAdvertiseRejectReason(hex)))
    check("hasCompleteStarlightPayload", hex, rec["hasCompleteStarlightPayload"], J.bool(HexUtils.hasCompleteStarlightPayload(hex)))
    check("disneyHexScore", hex, rec["disneyHexScore"], J.int(HexUtils.disneyHexScore(hex)))
    check("extractSerial", hex, rec["extractSerial"], jOptStr(StarlightSerial.extractSerial(hex)))
    check("markerFrom", hex, rec["markerFrom"], J.str(StarlightSerial.marker(from: hex)))
    check("isStoredFormat", hex, rec["isStoredFormat"], J.bool(StarlightSerial.isStoredFormat(hex)))

    let classified: ClassifiedPacket? = MagicClassifier.classify(hex)
    check("classify", hex, rec["classify"], classifiedJ(classified))
    check("isShowControl", hex, rec["isShowControl"], J.bool(MagicClassifier.isShowControl(hex)))
    check("isLibraryNoise", hex, rec["isLibraryNoise"], J.bool(MagicClassifier.isLibraryNoise(hex)))
    check("rawLabel", hex, rec["rawLabel"], J.str(MagicClassifier.rawLabel(hex)))
    check("groupKey", hex, rec["groupKey"], J.str(MagicClassifier.groupKey(hex)))
    check("groupLabel", hex, rec["groupLabel"], J.str(MagicClassifier.groupLabel(hex)))

    // Android records this only for a packet it classified.
    if rec["libraryDedupeKey"] != nil || classified != nil {
        var dedupe: J = J.null
        if let c = classified { dedupe = J.str(MagicClassifier.libraryDedupeKey(c)) }
        check("libraryDedupeKey", hex, rec["libraryDedupeKey"], dedupe)
    }

    check("starlightColorIndex", hex, rec["starlightColorIndex"], J.int(MagicClassifier.starlightColorIndex(hex)))
    check("starlightLearnColorIndex", hex, rec["starlightLearnColorIndex"], jOptInt(MagicClassifier.starlightLearnColorIndex(hex)))

    // Android records this only for a Starlight packet.
    let isStarlight: Bool = HexUtils.isStarlightPacket(hex)
    if rec["starlightTxHex"] != nil || isStarlight {
        var tx: J = J.null
        if isStarlight { tx = J.str(MagicClassifier.starlightTxHex(hex)) }
        check("starlightTxHex", hex, rec["starlightTxHex"], tx)
    }

    check("tlv", hex, rec["tlv"], tlvJ(hex))
    check("anatomy", hex, rec["anatomy"], anatomyJ(hex))
    check("band", hex, rec["band"], bandJ(hex))
    check("decode", hex, rec["decode"], decodeJ(hex))

    check("tailVibration", hex, rec["tailVibration"], jOptInt(LabPacketTools.tailVibration(hex)))
    check("withVibration3", hex, rec["withVibration3"], J.str(LabPacketTools.withVibration(hex, 3)))
    check("withTiming06", hex, rec["withTiming06"], J.str(PacketBuilder.withTiming(hex, 0x06)))
    check("withZoneMask3", hex, rec["withZoneMask3"], J.str(PacketBuilder.withZoneMask(hex, 3)))

    check("editableSlots", hex, rec["editableSlots"], editableSlotsJ(hex))
    check("slotColors", hex, rec["slotColors"], jInts(LabPacketBuilder.slotColors(hex)))
    check("withColors", hex, rec["withColors"], J.str(LabPacketBuilder.withColors(hex, recolour)))

    for key in rec.keys {
        if !knownPacketKeys.contains(key) { unknownPacketKeys.insert(key) }
    }
}

// MARK: - Builders

/// Replays one recorded `PacketBuilder` call. Nil when the function name is not known here.
func runPacketBuilder(_ function: String, _ a: [Int]) -> String? {
    func arg(_ i: Int) -> Int {
        if i >= 0 && i < a.count { return a[i] }
        return 0
    }
    switch function {
    case "preset":
        return PacketBuilder.preset(color: arg(0), vib: arg(1))
    case "vibrateBand":
        return PacketBuilder.vibrateBand(vib: arg(0))
    case "dual":
        return PacketBuilder.dual(arg(0), arg(1), vib: arg(2))
    case "rainbow5":
        return PacketBuilder.rainbow5(c1: arg(0), c2: arg(1), c3: arg(2), c4: arg(3), c5: arg(4), vib: arg(5))
    case "circle":
        // The colours, then the vibration last.
        if a.isEmpty { return nil }
        let colors: [Int] = Array(a[0..<(a.count - 1)])
        return PacketBuilder.circle(colors: colors, vib: a[a.count - 1])
    case "crossfade":
        return PacketBuilder.crossfade(c1: arg(0), c2: arg(1), vib: arg(2))
    case "rotate":
        return PacketBuilder.rotate(arg(0), arg(1), arg(2), arg(3), arg(4), vib: arg(5))
    case "rgb":
        return PacketBuilder.rgb(arg(0), arg(1), arg(2), vib: arg(3))
    default:
        return nil
    }
}

func checkPacketBuilder(_ index: Int, _ value: Any) {
    let rec = asDict(value)
    let function: String = asString(rec["fn"]) ?? ""
    let args: [Int] = intList(rec["args"])
    var argText: [String] = []
    for a in args { argText.append(String(a)) }
    let subject = "(" + argText.joined(separator: ",") + ")"
    check("PacketBuilder." + function, subject, rec["hex"], jOptStr(runPacketBuilder(function, args)))
}

func checkLabBuild(_ index: Int, _ value: Any) {
    let rec = asDict(value)
    let typeName: String = asString(rec["type"]) ?? ""
    let subject = "#\(index) \(typeName)"
    guard let type = labType(named: typeName) else {
        check("LabPacketBuilder.build", subject, rec["hex"], J.null)
        return
    }
    let colors: [Int] = intList(rec["colors"])
    let vibEnabled: Bool = asBool(rec["vibEnabled"]) ?? false
    let vibPattern: Int = asInt(rec["vibPattern"]) ?? 0
    let rawHex: String = asString(rec["rawHex"]) ?? ""
    let showIndex: Int = asInt(rec["showIndex"]) ?? 0

    // A null framing in the vectors means the argument was left out on Android.
    var framing: LabPacketBuilder.Framing? = nil
    if let f = rec["framing"] as? [String: Any] {
        let channelMarker: Bool = asBool(f["channelMarker"]) ?? false
        let wakePrefix: Bool = asBool(f["wakePrefix"]) ?? false
        let timing: Int = asInt(f["timing"]) ?? PacketBuilder.Timing.default
        framing = LabPacketBuilder.Framing(channelMarker: channelMarker, wakePrefix: wakePrefix, timing: timing)
    }

    let hex: String = LabPacketBuilder.build(
        type: type, colors: colors, vibEnabled: vibEnabled, vibPattern: vibPattern,
        rawHex: rawHex, framing: framing, showIndex: showIndex
    )
    check("LabPacketBuilder.build", subject, rec["hex"], J.str(hex))
}

// MARK: - Tables

func checkConstants(_ value: Any?) {
    let expected = asDict(value)
    var actual: [String: J] = [:]
    actual["HexUtils.DISNEY_COMPANY_ID"] = J.int(Int(HexUtils.disneyCompanyId))
    actual["HexUtils.MAX_MFG_PAYLOAD_BYTES"] = J.int(HexUtils.maxMfgPayloadBytes)
    actual["HexUtils.MAGIC_MAKER_LOCAL_NAME_PREFIX"] = J.str(HexUtils.magicMakerLocalNamePrefix)
    actual["StarlightSerial.SERIAL_HEX_LEN"] = J.int(StarlightSerial.serialHexLen)
    actual["StarlightSerial.DEFAULT_SERIAL"] = J.str(StarlightSerial.defaultSerial)
    actual["DisneyTlv.COMPANY_PREFIX"] = J.str(DisneyTlv.companyPrefix)
    actual["DisneyTlv.TYPE_PING"] = J.int(DisneyTlv.typePing)
    actual["DisneyTlv.TYPE_WAND"] = J.int(DisneyTlv.typeWand)
    actual["DisneyTlv.TYPE_EFFECT"] = J.int(DisneyTlv.typeEffect)
    actual["DisneyTlv.TYPE_CHANNEL_1"] = J.int(DisneyTlv.typeChannel1)
    actual["DisneyTlv.TYPE_CHANNEL_2"] = J.int(DisneyTlv.typeChannel2)
    actual["DisneyTlv.TYPE_CHANNEL_3"] = J.int(DisneyTlv.typeChannel3)
    actual["DisneyTlv.TYPE_BAND_TELEMETRY"] = J.int(DisneyTlv.typeBandTelemetry)
    actual["DisneyTlv.TYPE_BAND_ID"] = J.int(DisneyTlv.typeBandId)
    actual["DisneyTlv.LEGACY_STARLIGHT_LENGTH"] = J.int(DisneyTlv.legacyStarlightLength)
    actual["PacketBuilder.WAKEUP_PING"] = J.str(PacketBuilder.wakeupPing)
    actual["PacketBuilder.rainbowFinale"] = J.str(PacketBuilder.rainbowFinale)
    actual["PacketBuilder.vibrateBand"] = J.str(PacketBuilder.vibrateBand())
    actual["PacketBuilder.rainbow5"] = J.str(PacketBuilder.rainbow5())
    actual["PacketBuilder.circle"] = J.str(PacketBuilder.circle())
    actual["PacketBuilder.crossfade"] = J.str(PacketBuilder.crossfade())
    actual["PacketBuilder.CIRCLE_PATTERN"] = jInts(PacketBuilder.circlePattern)
    actual["PacketBuilder.Color.CYAN"] = J.int(PacketBuilder.Color.cyan)
    actual["PacketBuilder.Color.PURPLE"] = J.int(PacketBuilder.Color.purple)
    actual["PacketBuilder.Color.BLUE"] = J.int(PacketBuilder.Color.blue)
    actual["PacketBuilder.Color.MIDNIGHT_BLUE"] = J.int(PacketBuilder.Color.midnightBlue)
    actual["PacketBuilder.Color.BRIGHT_PURPLE"] = J.int(PacketBuilder.Color.brightPurple)
    actual["PacketBuilder.Color.LAVENDER"] = J.int(PacketBuilder.Color.lavender)
    actual["PacketBuilder.Color.PINK"] = J.int(PacketBuilder.Color.pink)
    actual["PacketBuilder.Color.YELLOW_ORANGE"] = J.int(PacketBuilder.Color.yellowOrange)
    actual["PacketBuilder.Color.LIME"] = J.int(PacketBuilder.Color.lime)
    actual["PacketBuilder.Color.ORANGE"] = J.int(PacketBuilder.Color.orange)
    actual["PacketBuilder.Color.RED"] = J.int(PacketBuilder.Color.red)
    actual["PacketBuilder.Color.GREEN"] = J.int(PacketBuilder.Color.green)
    actual["PacketBuilder.Color.WHITE"] = J.int(PacketBuilder.Color.white)
    actual["PacketBuilder.Color.OFF"] = J.int(PacketBuilder.Color.off)
    actual["PacketBuilder.Color.RANDOM"] = J.int(PacketBuilder.Color.random)
    actual["PacketBuilder.Vibration.OFF"] = J.int(PacketBuilder.Vibration.off)
    actual["PacketBuilder.Vibration.SHORT"] = J.int(PacketBuilder.Vibration.short)
    actual["PacketBuilder.Vibration.DOUBLE"] = J.int(PacketBuilder.Vibration.double)
    actual["PacketBuilder.Vibration.TRIPLE"] = J.int(PacketBuilder.Vibration.triple)
    actual["PacketBuilder.Vibration.BURST"] = J.int(PacketBuilder.Vibration.burst)
    actual["PacketBuilder.Vibration.LONG"] = J.int(PacketBuilder.Vibration.long)
    actual["PacketBuilder.Timing.DEFAULT"] = J.int(PacketBuilder.Timing.default)
    actual["PacketBuilder.Timing.ALWAYS_ON"] = J.int(PacketBuilder.Timing.alwaysOn)
    actual["PacketBuilder.Timing.S20"] = J.int(PacketBuilder.Timing.s20)
    actual["PacketBuilder.Timing.S10"] = J.int(PacketBuilder.Timing.s10)
    actual["PacketBuilder.Timing.S5"] = J.int(PacketBuilder.Timing.s5)
    actual["PacketBuilder.Timing.S3"] = J.int(PacketBuilder.Timing.s3)
    actual["NewWandCatalog.PREFIX"] = J.str(NewWandCatalog.prefix)
    actual["NewWandCatalog.ID_BASE"] = J.int(Int(NewWandCatalog.idBase))
    actual["PacketPatterns.NEWWAND_RANDOM_TOKEN"] = J.str(PacketPatterns.newWandRandomToken)
    actual["MbleBeaconBuilder.MANUFACTURER_ID"] = J.int(MbleBeaconBuilder.manufacturerId)
    actual["MbleBeaconBuilder.BEACON_LAYOUT"] = J.str(MbleBeaconBuilder.beaconLayout)
    actual["MbleBeaconBuilder.BEACON_ID"] = J.str(MbleBeaconBuilder.beaconId)
    actual["LabPacketBuilder.buildPing"] = J.str(LabPacketBuilder.buildPing())
    actual["LabPacketBuilder.buildRainbowFinale"] = J.str(LabPacketBuilder.buildRainbowFinale())

    if expected.isEmpty {
        checks += 1
        fail("tables.constants", "-", "<missing or empty>", "<nothing to compare>")
    }
    for key in expected.keys.sorted() {
        if let computed = actual[key] {
            check("tables.constants", key, expected[key], computed)
        } else {
            checks += 1
            fail("tables.constants", key, clip(showAny(expected[key])), "<not checked by ios/ParityCheck/main.swift>")
        }
    }
}

func paletteJ(_ palette: [Int: String]) -> [J] {
    var out: [J] = []
    for index in palette.keys.sorted() {
        var d: [String: J] = [:]
        d["index"] = J.int(index)
        d["name"] = J.str(palette[index] ?? "")
        out.append(J.obj(d))
    }
    return out
}

func entriesJ(_ entries: [StarlightColors.Entry]) -> [J] {
    var out: [J] = []
    for e in entries {
        var d: [String: J] = [:]
        d["index"] = J.int(e.index)
        d["name"] = J.str(e.name)
        d["hex"] = J.str(e.hex)
        out.append(J.obj(d))
    }
    return out
}

func labelledIdsJ(_ colors: [LabPacketBuilder.PaletteColor]) -> [J] {
    var out: [J] = []
    for c in colors {
        var d: [String: J] = [:]
        d["label"] = J.str(c.label)
        d["id"] = J.int(c.id)
        out.append(J.obj(d))
    }
    return out
}

func checkNewWand(_ value: Any?) {
    let section = Section("tables.newWand", value)
    let wands: [MagicPacket] = NewWandCatalog.packets

    check("tables.newWand.count", "-", section.get("count"), J.int(wands.count))
    checkList("tables.newWand.first5", section.get("first5"), packetsJ(Array(wands.prefix(5))))
    checkList("tables.newWand.last5", section.get("last5"), packetsJ(Array(wands.suffix(5))))

    var ids: [Int] = []
    var hexes: [String] = []
    for w in wands {
        ids.append(Int(w.id))
        hexes.append(w.hex)
    }
    check("tables.newWand.ids", "-", section.get("ids"), jInts(ids))
    check("tables.newWand.hexes", "-", section.get("hexes"), jStrs(hexes))

    let lookupIds: [Int] = intList(section.get("lookupIds"))
    var byId: [J] = []
    var isNewWand: [J] = []
    for id in lookupIds {
        byId.append(packetJ(NewWandCatalog.byId(Int64(id))))
        isNewWand.append(J.bool(NewWandCatalog.isNewWandId(Int64(id))))
    }
    checkList("tables.newWand.byId", section.get("byId"), byId)
    checkList("tables.newWand.isNewWandId", section.get("isNewWandId"), isNewWand)
    section.finish()
}

func checkLabTables(_ value: Any?) {
    let section = Section("tables.lab", value)

    var types: [J] = []
    for t in LabPacketBuilder.LabPacketType.allCases {
        var d: [String: J] = [:]
        d["type"] = J.str(t.rawValue)
        d["label"] = J.str(t.label)
        d["blurb"] = J.str(t.blurb)
        d["colorSlots"] = J.int(t.colorSlots)
        d["supportsVib"] = J.bool(t.supportsVib)
        d["experimental"] = J.bool(t.experimental)
        d["defaultColors"] = jInts(LabPacketBuilder.defaultColors(t))
        d["defaultFraming"] = framingJ(LabPacketBuilder.defaultFraming(t))
        d["framingApplies"] = J.bool(LabPacketBuilder.framingApplies(t))
        types.append(J.obj(d))
    }
    checkList("tables.lab.types", section.get("types"), types)

    var shows: [J] = []
    for show in LabPacketBuilder.showEffects {
        var d: [String: J] = [:]
        d["name"] = J.str(show.0)
        d["hex"] = J.str(show.1)
        shows.append(J.obj(d))
    }
    checkList("tables.lab.showEffects", section.get("showEffects"), shows)

    var experiments: [J] = []
    for e in LabPacketBuilder.experiments {
        var d: [String: J] = [:]
        d["name"] = J.str(e.name)
        d["hex"] = J.str(e.hex)
        d["watch"] = J.str(e.watch)
        experiments.append(J.obj(d))
    }
    checkList("tables.lab.experiments", section.get("experiments"), experiments)

    var vibrations: [J] = []
    for v in LabPacketBuilder.vibrationPatterns {
        var d: [String: J] = [:]
        d["label"] = J.str(v.label)
        d["id"] = J.int(v.id)
        vibrations.append(J.obj(d))
    }
    checkList("tables.lab.vibrationPatterns", section.get("vibrationPatterns"), vibrations)

    checkList("tables.lab.paletteColors", section.get("paletteColors"), labelledIdsJ(LabPacketBuilder.paletteColors))
    checkList("tables.lab.primaryPresetColors", section.get("primaryPresetColors"), labelledIdsJ(LabPacketBuilder.primaryPresetColors))

    var masks: [J] = []
    for m in LabPacketBuilder.ledMasks {
        var d: [String: J] = [:]
        d["mask"] = J.int(m.0)
        d["label"] = J.str(m.1)
        masks.append(J.obj(d))
    }
    checkList("tables.lab.ledMasks", section.get("ledMasks"), masks)

    var timings: [J] = []
    for choice in PacketBuilder.Timing.options {
        var d: [String: J] = [:]
        d["value"] = J.int(choice.0)
        d["label"] = J.str(choice.1)
        timings.append(J.obj(d))
    }
    checkList("tables.lab.timingOptions", section.get("timingOptions"), timings)

    // Each entry is [enabled as 0/1, pattern].
    var vibs: [J] = []
    for item in asList(section.get("vibArgs")) {
        let pair: [Int] = intList(item)
        let enabled: Bool = pair.count > 0 && pair[0] != 0
        let pattern: Int = pair.count > 1 ? pair[1] : 0
        vibs.append(J.int(LabPacketBuilder.vib(enabled: enabled, pattern: pattern)))
    }
    checkList("tables.lab.vib", section.get("vib"), vibs)

    let colorNames: [String] = stringList(section.get("colorNames"))
    let expectedColorIds: [Any] = asList(section.get("colorFromName"))
    let expectedPresets: [Any] = asList(section.get("buildPresetByName"))
    var i = 0
    while i < colorNames.count {
        let name = colorNames[i]
        check("PacketBuilder.colorFromName", name, listItem(expectedColorIds, i), J.int(PacketBuilder.colorFromName(name)))
        let hex: String = LabPacketBuilder.buildPreset(colorName: name, vibEnabled: true, vibPattern: 2)
        check("LabPacketBuilder.buildPreset(colorName:)", name, listItem(expectedPresets, i), J.str(hex))
        i += 1
    }

    let paletteLabels: [String] = stringList(section.get("paletteLabels"))
    let expectedPaletteIds: [Any] = asList(section.get("paletteId"))
    i = 0
    while i < paletteLabels.count {
        let label = paletteLabels[i]
        check("LabPacketBuilder.paletteId", label, listItem(expectedPaletteIds, i), J.int(LabPacketBuilder.paletteId(label)))
        i += 1
    }
    section.finish()
}

func checkPatternTables(_ value: Any?, _ userPresets: [MagicPacket], _ learned: [MagicPacket]) {
    let section = Section("tables.patterns", value)
    checkList("tables.patterns.systemTriggers", section.get("systemTriggers"), patternsJ(PacketPatterns.systemTriggers))
    checkList("tables.patterns.systemResponses", section.get("systemResponses"), patternsJ(PacketPatterns.systemResponses))

    let triggers: [PacketPattern] = PacketPatterns.buildTriggerOptions(userPresets: userPresets, learned: learned)
    checkList("tables.patterns.triggerOptions", section.get("triggerOptions"), patternsJ(triggers))

    let responses: [PacketPattern] = PacketPatterns.buildResponseOptions(userPresets: userPresets, learned: learned)
    check("tables.patterns.responseOptionCount", "-", section.get("responseOptionCount"), J.int(responses.count))
    checkList("tables.patterns.responseOptionsHead", section.get("responseOptionsHead"), patternsJ(Array(responses.prefix(40))))
    checkList("tables.patterns.responseOptionsTail", section.get("responseOptionsTail"), patternsJ(Array(responses.suffix(4))))
    section.finish()
}

func checkTlvTables(_ value: Any?) {
    let section = Section("tables.tlv", value)

    var captions: [J] = []
    for b in 0...255 { captions.append(J.str(DisneyTlv.timingCaption(b))) }
    checkList("DisneyTlv.timingCaption", section.get("timingCaption"), captions)

    var names: [J] = []
    var slots: [J] = []
    for length in 0...32 {
        names.append(J.str(DisneyTlv.effectName(length)))
        slots.append(J.int(DisneyTlv.colorSlotCount(length)))
    }
    checkList("DisneyTlv.effectName", section.get("effectName"), names)
    checkList("DisneyTlv.colorSlotCount", section.get("colorSlotCount"), slots)

    var pings: [J] = []
    for v in stringList(section.get("pingValues")) { pings.append(J.str(DisneyTlv.pingName(v))) }
    checkList("DisneyTlv.pingName", section.get("pingName"), pings)
    section.finish()
}

func checkBeaconTables(_ value: Any?) {
    let section = Section("tables.beacon", value)
    var payloads: [J] = []
    for token in stringList(section.get("tokens")) {
        // Android throws for a token shorter than two bytes; Swift returns nil.
        if let bytes = MbleBeaconBuilder.manufacturerPayload(token) {
            payloads.append(J.str(HexUtils.bytesToHex(bytes)))
        } else {
            payloads.append(J.null)
        }
    }
    checkList("MbleBeaconBuilder.manufacturerPayload", section.get("manufacturerPayload"), payloads)
    section.finish()
}

func checkTables(_ value: Any?, _ userPresets: [MagicPacket], _ learned: [MagicPacket]) {
    let section = Section("tables", value)

    checkConstants(section.get("constants"))

    var presets: [J] = []
    for p in PresetCatalog.all {
        var d: [String: J] = [:]
        d["label"] = J.str(p.label)
        d["hex"] = J.str(p.hex)
        d["kind"] = J.str(p.kind.rawValue)
        presets.append(J.obj(d))
    }
    checkList("PresetCatalog.all", section.get("presets"), presets)
    checkList("PresetCatalog.asMagicPackets", section.get("asMagicPackets"), packetsJ(PresetCatalog.asMagicPackets()))

    var blocks: [J] = []
    for name in PresetCatalog.showBlocks.keys.sorted() {
        var d: [String: J] = [:]
        d["name"] = J.str(name)
        d["hex"] = J.str(PresetCatalog.showBlocks[name] ?? "")
        blocks.append(J.obj(d))
    }
    checkList("PresetCatalog.showBlocks", section.get("showBlocks"), blocks)

    checkList("StarlightColors.palette", section.get("palette"), paletteJ(StarlightColors.palette))
    checkList("PresetCatalog.starlightColorNames", section.get("starlightColorNames"), paletteJ(PresetCatalog.starlightColorNames))
    checkList("StarlightColors.entries", section.get("starlightEntries"), entriesJ(StarlightColors.entries()))
    let longSerialEntries: [StarlightColors.Entry] = StarlightColors.entries(serial: "0123456789ABCDEF012345")
    checkList("StarlightColors.entries(serial:)", section.get("starlightEntriesLongSerial"), entriesJ(longSerialEntries))

    let indexes: [Int] = intList(section.get("indexes"))
    var nameFor: [J] = []
    var simKeys: [J] = []
    var legacyHexes: [J] = []
    var labLabels: [J] = []
    var paletteLabels: [J] = []
    for index in indexes {
        nameFor.append(J.str(StarlightColors.nameFor(index)))
        simKeys.append(J.str(PresetCatalog.starlightSimKey(index)))
        legacyHexes.append(J.str(PresetCatalog.legacyStarlightHex(colorIndex: index)))
        labLabels.append(J.str(LabPacketBuilder.labLabel(index)))
        paletteLabels.append(J.str(LabPacketBuilder.paletteLabel(index)))
    }
    checkList("StarlightColors.nameFor", section.get("nameFor"), nameFor)
    checkList("PresetCatalog.starlightSimKey", section.get("starlightSimKey"), simKeys)
    checkList("PresetCatalog.legacyStarlightHex", section.get("legacyStarlightHex"), legacyHexes)
    checkList("LabPacketBuilder.labLabel", section.get("labLabel"), labLabels)
    checkList("LabPacketBuilder.paletteLabel", section.get("paletteLabel"), paletteLabels)

    let serials: [String] = stringList(section.get("serials"))
    var normalized: [J] = []
    var validated: [J] = []
    var cf9b: [J] = []
    var cf0b: [J] = []
    var otherMarker: [J] = []
    for serial in serials {
        normalized.append(jOptStr(StarlightSerial.normalizeSerial(serial)))
        validated.append(J.str(StarlightSerial.validatedSerial(serial)))
        cf9b.append(J.str(StarlightSerial.buildHex(serial: serial, colorIndex: 0x15)))
        cf0b.append(J.str(StarlightSerial.buildHex(serial: serial, colorIndex: 0x3B, marker: "CF0B")))
        otherMarker.append(J.str(StarlightSerial.buildHex(serial: serial, colorIndex: -1, marker: "cf0b")))
    }
    checkList("StarlightSerial.normalizeSerial", section.get("normalizeSerial"), normalized)
    checkList("StarlightSerial.validatedSerial", section.get("validatedSerial"), validated)
    check("StarlightSerial.validatedSerial", "nil", section.get("validatedSerialNull"), J.str(StarlightSerial.validatedSerial(nil)))
    checkList("StarlightSerial.buildHex", section.get("buildHexCF9B"), cf9b)
    checkList("StarlightSerial.buildHex(marker: CF0B)", section.get("buildHexCF0B"), cf0b)
    checkList("StarlightSerial.buildHex(marker: cf0b)", section.get("buildHexOtherMarker"), otherMarker)

    checkNewWand(section.get("newWand"))
    checkLabTables(section.get("lab"))
    checkPatternTables(section.get("patterns"), userPresets, learned)
    checkTlvTables(section.get("tlv"))
    checkBeaconTables(section.get("beacon"))
    section.finish()
}

// MARK: - Auto-response rules

func checkRules(_ value: Any?, _ userPresets: [MagicPacket], _ learned: [MagicPacket]) {
    let section = Section("rules", value)

    // The two libraries the rules run against are read from the vectors; check that Swift
    // derives the same packets before using them.
    checkList("rules.userPresets", section.get("userPresets"), packetsJ(PresetCatalog.asMagicPackets()))
    var derived: [MagicPacket] = []
    for p in learned {
        var packet: MagicPacket = classifiedOrRaw(p.hex).toPacket(userRecorded: true)
        packet.id = p.id
        derived.append(packet)
    }
    checkList("rules.learned", section.get("learned"), packetsJ(derived))

    let triggerIds: [String] = stringList(section.get("triggerIds"))
    let noPresets: [MagicPacket] = []
    for item in asList(section.get("packets")) {
        let rec = asDict(item)
        let hex: String = asString(rec["hex"]) ?? ""
        let classified: ClassifiedPacket = classifiedFromVectors(rec["classified"])
        check("rules.classified", hex, rec["classified"], classifiedJ(classifiedOrRaw(hex)))

        let expected: [Any] = asList(rec["matches"])
        let expectedNoPresets: [Any] = asList(rec["matchesNoPresets"])
        var i = 0
        while i < triggerIds.count {
            let id = triggerIds[i]
            let subject = "trigger=\(id) hex=\(hex)"
            let hit: Bool = PacketPatterns.matchesTriggerId(id, classified: classified, rawHex: hex, userPresets: userPresets, learned: learned)
            check("PacketPatterns.matchesTriggerId", subject, listItem(expected, i), J.bool(hit))

            let hitNoPresets: Bool = PacketPatterns.matchesTriggerId(id, classified: classified, rawHex: hex, userPresets: noPresets, learned: learned)
            check("PacketPatterns.matchesTriggerId(no presets)", subject, listItem(expectedNoPresets, i), J.bool(hitNoPresets))
            i += 1
        }
    }

    for item in asList(section.get("rules")) {
        let rec = asDict(item)
        let id: Int = asInt(rec["id"]) ?? 0
        let name: String = asString(rec["name"]) ?? ""
        let rule = AutoResponseRule(
            id: Int64(id),
            name: name,
            triggerPatternId: asString(rec["triggerPatternId"]) ?? "",
            responsePatternId: asString(rec["responsePatternId"]) ?? "",
            responseHex: asString(rec["responseHex"]) ?? "",
            responseHexes: stringList(rec["responseHexes"]),
            enabled: asBool(rec["enabled"]) ?? true
        )
        let subject = "rule \(id) (\(name))"
        let resolved: [String] = PacketPatterns.resolveResponseHexes(rule: rule, userPresets: userPresets, learned: learned)
        check("PacketPatterns.resolveResponseHexes", subject, rec["resolved"], jStrs(resolved))
        let first: String = PacketPatterns.resolveResponseHex(rule: rule, userPresets: userPresets, learned: learned)
        check("PacketPatterns.resolveResponseHex", subject, rec["resolvedFirst"], J.str(first))
        let bare: [String] = PacketPatterns.resolveResponseHexes(rule: rule, userPresets: noPresets, learned: noPresets)
        check("PacketPatterns.resolveResponseHexes(empty library)", subject, rec["resolvedNoLibrary"], jStrs(bare))
    }
    section.finish()
}

// MARK: - Run

func stop(_ message: String) -> Never {
    print("PARITY: " + message)
    exit(2)
}

// Line-buffered, so what was already printed survives if a core function traps.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments: [String] = CommandLine.arguments
if arguments.count < 2 {
    stop("usage: parity <path to vectors.json>")
}
let vectorsPath: String = arguments[1]

guard let vectorsData = FileManager.default.contents(atPath: vectorsPath) else {
    stop("cannot read \(vectorsPath)")
}
guard let parsedVectors = try? JSONSerialization.jsonObject(with: vectorsData, options: []) else {
    stop("\(vectorsPath) is not valid JSON")
}
guard let rootDict = parsedVectors as? [String: Any] else {
    stop("\(vectorsPath) is not a JSON object")
}

let root = Section("vectors", rootDict)
_ = root.get("version")
_ = root.get("note")

let rulesDict: [String: Any] = asDict(root.get("rules"))
let userPresets: [MagicPacket] = packetsFromVectors(rulesDict["userPresets"])
let learnedPackets: [MagicPacket] = packetsFromVectors(rulesDict["learned"])

let packetRecords: [Any] = asList(root.get("packets"))
if packetRecords.isEmpty {
    checks += 1
    fail("packets", "-", "<a list of packets>", "<none found in vectors.json>")
}
var packetIndex = 0
for record in packetRecords {
    checkPacket(packetIndex, record)
    packetIndex += 1
}
for key in unknownPacketKeys.sorted() {
    checks += 1
    fail("packets." + key, "-", "<present in vectors.json>", "<not checked by ios/ParityCheck/main.swift>")
}

let builderRecords: [Any] = asList(root.get("packetBuilder"))
if builderRecords.isEmpty {
    checks += 1
    fail("packetBuilder", "-", "<a list of builder calls>", "<none found in vectors.json>")
}
var builderIndex = 0
for record in builderRecords {
    checkPacketBuilder(builderIndex, record)
    builderIndex += 1
}

let labBuildRecords: [Any] = asList(root.get("labBuilds"))
if labBuildRecords.isEmpty {
    checks += 1
    fail("labBuilds", "-", "<a list of Lab builds>", "<none found in vectors.json>")
}
var labBuildIndex = 0
for record in labBuildRecords {
    checkLabBuild(labBuildIndex, record)
    labBuildIndex += 1
}

checkTables(root.get("tables"), userPresets, learnedPackets)
checkRules(rulesDict, userPresets, learnedPackets)
root.finish()

if mismatches > printedLines {
    print("... \(mismatches - printedLines) more mismatches not shown")
}
print("NOTE: \(packetRecords.count) packets; \(skipped) values not compared because the Android call throws there")
print("PARITY: \(checks) checks, \(mismatches) mismatches")
exit(mismatches > 0 ? 1 : 0)
