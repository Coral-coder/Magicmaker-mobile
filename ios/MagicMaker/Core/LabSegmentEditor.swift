import Foundation

/// Tap-to-edit model behind the Lab's packet anatomy: where each anatomy block sits in the packet,
/// what it means, the values it may take, and the whole packet after an edit.
///
/// It sits on top of `DisneyTlv.anatomy` without changing it. Every edit is a byte splice on the
/// canonical packet; the only derived field in the grammar is a record's length byte, rewritten
/// when a value changes size. There are no checksums or counters (docs/PROTOCOL.md §8).
/// iOS-only: the Android Lab explains blocks but does not edit them.
enum LabSegmentEditor {
    enum Confidence: String { case proven = "Proven", inferred = "Inferred", disputed = "Disputed", unknown = "Unknown" }

    /// Cheap explanation of one anatomy block (safe to call from VFD draw()).
    struct About: Equatable {
        let title: String          // anatomy title
        let offset: Int?           // abs byte offset; nil = not located → read-only
        let count: Int             // seg.hex.count / 2
        let what: String           // what it is
        let does: String           // what it does to the band / wand
        let valid: String          // one line: valid values
        let confidence: Confidence
        let bits: String           // bit breakdown for 1-byte bit fields, "" otherwise
    }

    enum FieldKind: String {
        case shape, channel, pingValue, subCode, timing, flags, color, colorFlag, rgbChannel, mode,
             dataVariant, tail, wandMarker, wandSerial, wandColor, recordValue
    }

    struct Option: Equatable {
        let bytes: [UInt8]         // what the field becomes
        let label: String          // "B3 · Triple", "#15 Red", "2E · on for ~21 s, 2 s fade-out"
        let note: String           // "" or one line ("Flipper calls this ≈20 s", source name)
        let palette: Int?          // swatch index, nil when not a colour
        let experimental: Bool     // already filtered by `extended`; used only for an EXPERIMENTAL tag
    }

    struct Field: Equatable {
        let kind: FieldKind
        let title: String          // "Timing", "Flags", "LEDs (zone mask)", "Red", "Mode"
        let offset: Int            // abs byte offset
        let count: Int             // bytes replaced
        let lengthByteOffset: Int? // .recordValue only (R+1); nil = size fixed (or whole-record .shape)
        let current: [UInt8]
        let caption: String        // current value in words
        let about: String
        let options: [Option]      // may be empty (manual only)
    }

    struct Action: Equatable {
        let label: String          // "Remove channel marker", "Add wake ping first (CC03 000100)"
        let note: String
        let hex: String            // the whole packet after the action, canonical
        let destructive: Bool
    }

    struct ManualRule: Equatable {
        let offset: Int
        let minBytes: Int
        let maxBytes: Int          // 0 = no manual entry
        let lengthByteOffset: Int?
        let hint: String           // "1 byte (2 hex digits)"
        var allowed: Bool { return maxBytes > 0 }
    }

    struct EditableSegment: Equatable {
        let index: Int             // into DisneyTlv.anatomy(hex)
        let segment: DisneyTlv.Segment
        let about: About
        let fields: [Field]
        let actions: [Action]
        let manual: ManualRule
    }

    enum ManualResult: Equatable { case applied(String), invalid(String) }

    // MARK: - Locating segments

    /// The absolute byte offset of every anatomy segment, in anatomy order. A segment is located
    /// when its hex is exactly what follows the previous located segment; the first one that is
    /// not (and every one after it) is nil, and so is a "Malformed" / "Not a Disney packet" block.
    static func locate(_ hexRaw: String) -> [Int?] {
        let h: String = HexUtils.canonicalHex(hexRaw)
        return alignOffsets(h, DisneyTlv.anatomy(h))
    }

    private static func alignOffsets(_ canonical: String, _ segments: [DisneyTlv.Segment]) -> [Int?] {
        let chars: [Character] = Array(canonical)
        var out: [Int?] = []
        var cursor: Int = 0
        var broken: Bool = false
        for seg in segments {
            if broken || seg.hex.isEmpty || seg.kind == .error {
                out.append(nil)
                continue
            }
            let want: [Character] = Array(seg.hex)
            let end: Int = cursor + want.count
            if end <= chars.count && Array(chars[cursor..<end]) == want {
                out.append(cursor / 2)
                cursor = end
            } else {
                out.append(nil)
                broken = true
            }
        }
        return out
    }

    /// One parse of a packet: its bytes, records, where each record starts, and the anatomy.
    private struct Ctx {
        let hex: String
        let bytes: [UInt8]
        let parsed: DisneyTlv.Parsed?
        let records: [DisneyTlv.Record]
        let starts: [Int]
        let segments: [DisneyTlv.Segment]
        let offsets: [Int?]

        init(_ hexRaw: String) {
            let h: String = HexUtils.canonicalHex(hexRaw)
            let p: DisneyTlv.Parsed? = DisneyTlv.parse(h)
            let recs: [DisneyTlv.Record] = p?.records ?? []
            var s: [Int] = []
            var pos: Int = 2
            for r in recs {
                s.append(pos)
                pos += 2 + r.value.count
            }
            let segs: [DisneyTlv.Segment] = DisneyTlv.anatomy(h)
            hex = h
            bytes = HexUtils.hexToBytes(h)
            parsed = p
            records = recs
            starts = s
            segments = segs
            offsets = LabSegmentEditor.alignOffsets(h, segs)
        }

        func offset(_ index: Int) -> Int? {
            if index < 0 || index >= offsets.count { return nil }
            return offsets[index]
        }

        /// The record whose type, length or value holds byte `offset`.
        func recordIndex(at offset: Int) -> Int? {
            var i: Int = 0
            while i < records.count && i < starts.count {
                let st: Int = starts[i]
                if offset >= st && offset < st + 2 + records[i].value.count { return i }
                i += 1
            }
            return nil
        }

        func byte(_ i: Int) -> Int {
            if i < 0 || i >= bytes.count { return 0 }
            return Int(bytes[i])
        }

        var firstEffectIndex: Int? {
            return records.firstIndex(where: { (r: DisneyTlv.Record) -> Bool in r.type == DisneyTlv.typeEffect })
        }
    }

    // MARK: - Explanations

    static func about(_ hexRaw: String, index: Int) -> About? {
        return aboutFor(Ctx(hexRaw), index)
    }

    private struct Copy {
        let what: String
        let does: String
        let valid: String
        let confidence: Confidence
    }

    private static func aboutFor(_ c: Ctx, _ index: Int) -> About? {
        if index < 0 || index >= c.segments.count { return nil }
        let seg: DisneyTlv.Segment = c.segments[index]
        let off: Int? = c.offset(index)
        var rec: DisneyTlv.Record? = nil
        if let o = off, let ri = c.recordIndex(at: o) {
            rec = c.records[ri]
        }
        let copy: Copy = copyFor(c, seg, rec)
        let bits: String = bitsFor(seg, rec)
        return About(
            title: seg.title, offset: off, count: seg.hex.count / 2,
            what: copy.what, does: copy.does, valid: copy.valid,
            confidence: copy.confidence, bits: bits
        )
    }

    private static let companyWhat = "Disney's Bluetooth company ID 0x0183, sent low byte first (83 01). It's the envelope Bluetooth puts around manufacturer data, not one of Disney's commands."
    private static let companyDoes = "Bands and wands only listen to packets that start with it. It can't be changed — use the actions to add framing after it."
    private static let channelWhat = "A zero-length record (type E1, E2 or E3, length 00) sent just before the effect."
    private static let channelDoes = "Every effect captured in the park has one: E1 in 44, E2 in 10, E3 once (otherwise identical to an E1 packet). What it selects — zone, group, priority — is unknown. The esp32 presets work without it."
    private static let pingWhat = "Interaction ping: type CC, length 03, three value bytes."
    private static let pingDoes = "000100 wakes nearby bands so they hear the next command (captured show packets start with it). 000000 is the beacon ping; 234100 and 203000 were heard during shows. A ping alone never lights a band."
    private static let effectWhat = "Type E9 = band effect. The next byte is how many body bytes follow — and that length picks the effect's shape (E905 single colour, E906 dual, E909 five zones…)."
    private static let effectDoes = "Picking another shape swaps in that shape's template; colours and buzz carry over where the new shape has them. The length byte must always match the body."
    private static let headerWhat = "The first three body bytes of every effect: sub-code, timing, flags."
    private static let headerDoes = "Timing sets how long the band holds the effect and whether it fades. Sub-code and flags aren't understood; changing them is an experiment."
    private static let colorWhat = "One colour byte: low 5 bits = palette colour (00–1F), high 3 bits = a flag."
    private static let colorDoesAll = "Per shape. E905: all five LEDs (or the zone the mask picks). E906/E90F: centre / four corners. E909: one LED each, order disputed (listener: bottom-left, top-left, centre, top-right, bottom-right). E90B: one of seven chase-pattern bytes, which no public decoder reads. E90C: animation colour (motion undecoded). E90E: one twinkle zone. E911: fade from / to. E912: one zone (bytes in zone order Z2 Z3 Z4 Z5 Z1). E913: centre / pair B / pair A."
    private static let dataWhat = "The rest of the effect body: motion, curve and mode bytes we haven't fully decoded."
    private static let dataDoes = "Known bytes are listed with options. Changing others is an experiment — the band may ignore the packet or do something new. Its size is fixed because the E9 length depends on it."
    private static let tailWhat = "The last body byte. This app (esp32_magicband) reads it as B0 + a vibration pattern 0–15."
    private static let tailDoes = "B0 = no buzz; B1–BF buzz with that pattern as the effect starts. Disputed: the Flipper app puts the pattern in the high nibble (5B = fast), and park effects also end in 95 or 01 — treat it as a guess until a band confirms it."
    private static let wandWhat = "Wand record: type CF, 11 value bytes — 00, a 9-byte wand serial, then the colour byte."
    private static let wandDoes = "Sets the colour a wand receiver shows (last byte, low 5 bits). The serial names the wand; any serial replays. CF9B is this app's old Starlight template: it declares 155 bytes and can't fit an advertisement, while the body is the same 11 bytes CF0B declares."
    private static let telemetryWhat = "Broadcast by guests' MagicBands with a rolling payload — 91% of park traffic."
    private static let telemetryDoes = "Nothing to other bands; never an effect. 0F 11 is also the MBLE Lightning Lane tap-beacon layout: 2-byte id, 14-byte token, 1-byte power."
    private static let beaconWhat = "A park infrastructure record (EA, EF, E4, E5…) from fixed devices."
    private static let beaconDoes = "Not decoded. EF 05 01 A6 xx <colour> is a colour cue."
    private static let errorDoes = "Receivers may drop the whole packet. Use a repair action, or fix it in HEX OUTPUT."

    private static let subCodeAbout = "Body byte 0. 00 in every effect captured in the park; the esp32 circle template uses 0B. Meaning unknown."
    private static let timingAbout = "Body byte 1: bit 7 always on · bit 6 unit (3.1 s set / 1.5 s clear) · bits 5–4 fade-out seconds · bits 3–0 count. Lit time = count × unit, then the fade. Always-on stays lit until the next command. Two public decoders agree; not yet timed on a band."
    private static let flagsAbout = "Body byte 2. Usually 0E on single colours, 0F elsewhere. On rotating colours (E912) 0F = rotate, anything else = two-colour toggle. Otherwise unknown."
    private static let colorFieldAbout = "Low 5 bits = palette colour (00–1F). The high 3 bits (the flag) stay as they are."
    private static let zoneMaskAbout = "High 3 bits. E905: zone mask — 7 or 0 all, 3 bottom-left, 4 top-left (agreed); 1, 2, 5, 6 disputed."
    private static let flagBitsAbout = "High 3 bits. Park packets use 010, the Dual builder 100, five-zone/rotate 101; untested whether the band reads it. The palette colour stays as it is."

    private static func copyFor(_ c: Ctx, _ seg: DisneyTlv.Segment, _ rec: DisneyTlv.Record?) -> Copy {
        switch seg.kind {
        case .company:
            return Copy(what: companyWhat, does: companyDoes, valid: "83 01 only", confidence: .proven)
        case .channel:
            return Copy(what: channelWhat, does: channelDoes, valid: "E1 00 · E2 00 · E3 00 (second byte must stay 00)", confidence: .unknown)
        case .ping:
            return Copy(what: pingWhat, does: pingDoes, valid: "000100 · 000000 · 234100 · 203000 (Extended: 132000)", confidence: .proven)
        case .effectHead:
            return Copy(what: effectWhat, does: effectDoes, valid: "E9 + 05 06 09 0B 0C 0E 0F 10 11 12 14 (Extended: 07 08 0A)", confidence: .inferred)
        case .header:
            return Copy(what: headerWhat, does: headerDoes, valid: "3 bytes", confidence: .inferred)
        case .color:
            let shapeLen: Int = rec?.declaredLength ?? -1
            return Copy(what: colorWhat, does: colorDoes(shapeLen), valid: "palette 00–1F · flag 0–7", confidence: .proven)
        case .data:
            let n: Int = seg.hex.count / 2
            return Copy(what: dataWhat, does: dataDoes, valid: "any \(n) bytes, same size", confidence: .unknown)
        case .tail:
            return Copy(what: tailWhat, does: tailDoes, valid: "B0–BF (Extended: Flipper xB, 95, 01)", confidence: .disputed)
        case .wand:
            return Copy(what: wandWhat, does: wandDoes, valid: "CF 0B (or 9B) · 00 · 9-byte serial · colour 00–1F", confidence: .inferred)
        case .beacon:
            let what: String = beaconWhat + beaconNote(rec)
            return Copy(what: what, does: beaconDoes, valid: "any value", confidence: .unknown)
        case .other:
            if seg.title == "MagicBand telemetry" {
                let what: String = telemetryWhat + mbleNote(rec)
                return Copy(what: what, does: telemetryDoes, valid: "any value; length byte follows", confidence: .inferred)
            }
            return Copy(what: "A record type with no name yet.", does: "Unknown.", valid: "any value", confidence: .unknown)
        case .error:
            let what: String
            if c.hex.count % 2 != 0 {
                what = "An odd number of hex digits — every byte needs two."
            } else if c.parsed == nil {
                what = "This isn't a Disney packet: " + seg.detail
            } else {
                what = "The bytes stop matching the type-length-value chain here: " + seg.detail + "."
            }
            return Copy(what: what, does: errorDoes, valid: "—", confidence: .proven)
        }
    }

    private static func colorDoes(_ shapeLen: Int) -> String {
        switch shapeLen {
        case 0x05: return "E905: all five LEDs (or the zone the mask picks)."
        case 0x06, 0x0F: return "E906/E90F: centre / four corners."
        case 0x09: return "E909: one LED each, order disputed (listener: bottom-left, top-left, centre, top-right, bottom-right)."
        case 0x0B: return "E90B: one of seven chase-pattern bytes, which no public decoder reads."
        case 0x0C: return "E90C: animation colour (motion undecoded)."
        case 0x0E: return "E90E: one twinkle zone."
        case 0x11: return "E911: fade from / to."
        case 0x12: return "E912: one zone (bytes in zone order Z2 Z3 Z4 Z5 Z1)."
        case 0x13: return "E913: centre / pair B / pair A."
        default: return colorDoesAll
        }
    }

    private static func beaconNote(_ rec: DisneyTlv.Record?) -> String {
        guard let r = rec else { return "" }
        let head: String = r.headHex()
        if r.type == 0xE4 { return " This one (" + head + ") is a show burst, often chained E409 + E501 + EF05." }
        if r.type == 0xE5 { return " This one (" + head + ") is a sync cue." }
        if r.type == 0xEF && r.declaredLength == 0x08 { return " This one (EF08) is a scene cue." }
        if r.type == 0xEF && r.declaredLength == 0x05 { return " This one (EF05) is a colour cue." }
        if r.type == 0xEA { return " This one is an animation cue (style " + DisneyTlv.hex2(r.declaredLength) + ")." }
        return ""
    }

    private static func mbleNote(_ rec: DisneyTlv.Record?) -> String {
        guard let r = rec, r.type == DisneyTlv.typeBandId, r.value.count == 17 else { return "" }
        let id: String = HexUtils.bytesToHex(Array(r.value[0..<2]))
        let token: String = HexUtils.bytesToHex(Array(r.value[2..<16]))
        let power: String = DisneyTlv.hex2(Int(r.value[16]))
        return " As an MBLE tap beacon this one reads: id " + id + " · token " + token + " · power " + power + "."
    }

    private static func bitsFor(_ seg: DisneyTlv.Segment, _ rec: DisneyTlv.Record?) -> String {
        switch seg.kind {
        case .color:
            guard let v = Int(seg.hex, radix: 16), seg.hex.count == 2 else { return "" }
            return colorBits(v, shapeLen: rec?.declaredLength ?? -1)
        case .tail:
            guard let v = Int(seg.hex, radix: 16), seg.hex.count == 2 else { return "" }
            return tailBits(v)
        case .header:
            let chars: [Character] = Array(seg.hex)
            if chars.count < 4 { return "" }
            guard let t = Int(String(chars[2..<4]), radix: 16) else { return "" }
            return "Timing " + timingBits(t)
        default:
            return ""
        }
    }

    /// `width` low bits of `v` in binary, zero-padded.
    private static func bin(_ v: Int, _ width: Int) -> String {
        let mask: Int = (1 << width) - 1
        var s: String = String(v & mask, radix: 2)
        while s.count < width { s = "0" + s }
        return s
    }

    /// "2E = 0 0 10 1110 → always-on off · unit 1.5 s · fade 2 s · count 14 → on for ~21 s, 2 s fade-out"
    static func timingBits(_ b: Int) -> String {
        let p = timingParts(b)
        let bits: String = bin(b >> 7, 1) + " " + bin(b >> 6, 1) + " " + bin(b >> 4, 2) + " " + bin(b, 4)
        let onWord: String = p.alwaysOn ? "on" : "off"
        let unitWord: String = p.longUnit ? "3.1 s" : "1.5 s"
        let words: String = "always-on " + onWord + " · unit " + unitWord + " · fade \(p.fadeSeconds) s · count \(p.count)"
        let head: String = DisneyTlv.hex2(b) + " = " + bits
        return head + " → " + words + " → " + DisneyTlv.timingCaption(b)
    }

    /// "F5 = 111 10101 → flag 7 (all LEDs) · palette #15 Red"
    static func colorBits(_ v: Int, shapeLen: Int) -> String {
        let high: Int = (v >> 5) & 0x07
        var flagWords: String = "flag \(high)"
        if shapeLen == 0x05 {
            flagWords += " (" + zoneWords(high) + ")"
        }
        let bits: String = bin(v >> 5, 3) + " " + bin(v, 5)
        let palette: String = " · palette " + LabPacketBuilder.labLabel(v & 0x1F)
        let head: String = DisneyTlv.hex2(v) + " = " + bits
        return head + " → " + flagWords + palette
    }

    /// "B3 = 1011 0011 → B0 + pattern 3 (Triple)"
    static func tailBits(_ v: Int) -> String {
        let bits: String = bin(v >> 4, 4) + " " + bin(v, 4)
        let head: String = DisneyTlv.hex2(v) + " = " + bits + " → "
        if (v & 0xF0) != 0xB0 { return head + "not B0–BF, so this app reads no buzz" }
        let n: Int = v & 0x0F
        return head + "B0 + pattern \(n) (" + vibrationName(n) + ")"
    }

    private static func zoneWords(_ mask: Int) -> String {
        switch mask {
        case 7: return "all LEDs"
        case 0: return "all LEDs?"
        case 3: return "bottom-left"
        case 4: return "top-left"
        default: return "disputed"
        }
    }

    private static func vibrationName(_ n: Int) -> String {
        if n == 0 { return "Off" }
        for p in LabPacketBuilder.vibrationPatterns where p.id == n {
            return p.label
        }
        return "Pattern \(n)"
    }

    // MARK: - Editable segments

    /// Everything the editor offers for one anatomy block. Nil only for an index out of range.
    /// Scans the catalogues (through the `static let` tables), so call it on a tap, not per frame.
    static func segment(_ hexRaw: String, index: Int, extended: Bool, savedSerial: String) -> EditableSegment? {
        let c: Ctx = Ctx(hexRaw)
        guard let ab = aboutFor(c, index) else { return nil }
        let seg: DisneyTlv.Segment = c.segments[index]
        var parts: Parts = Parts()
        if seg.kind == .error {
            parts.actions = repairActions(c)
        } else if let off = ab.offset {
            if seg.kind == .company {
                parts.actions = framingActions(c)
            } else if let ri = c.recordIndex(at: off), ri < c.starts.count {
                parts = partsFor(c, seg, ri, off, ab.count, extended, savedSerial)
            }
        }
        return EditableSegment(
            index: index, segment: seg, about: ab,
            fields: parts.fields, actions: parts.actions, manual: parts.manual
        )
    }

    private static let noManual = ManualRule(offset: 0, minBytes: 0, maxBytes: 0, lengthByteOffset: nil, hint: "")

    private struct Parts {
        var fields: [Field] = []
        var actions: [Action] = []
        var manual: ManualRule = LabSegmentEditor.noManual
    }

    private static func partsFor(
        _ c: Ctx, _ seg: DisneyTlv.Segment, _ ri: Int, _ off: Int, _ count: Int,
        _ extended: Bool, _ savedSerial: String
    ) -> Parts {
        let rec: DisneyTlv.Record = c.records[ri]
        let start: Int = c.starts[ri]
        switch seg.kind {
        case .channel:
            return channelParts(c, rec, start)
        case .ping:
            return pingParts(c, rec, start, extended)
        case .effectHead:
            return effectHeadParts(c, ri, start, extended)
        case .header:
            return headerParts(c, rec, off, extended)
        case .color:
            return colorParts(c, rec, off, seg.title)
        case .data:
            return dataParts(c, rec, start, off, count, extended)
        case .tail:
            return tailParts(c, off, extended)
        case .wand:
            return wandParts(c, ri, start, savedSerial)
        case .beacon, .other:
            return valueParts(c, ri, start)
        case .company, .error:
            return Parts()
        }
    }

    private static func manualHint(_ n: Int) -> String {
        if n == 1 { return "1 byte (2 hex digits)" }
        return "\(n) bytes (\(n * 2) hex digits)"
    }

    private static func fixedManual(_ offset: Int, _ n: Int) -> ManualRule {
        return ManualRule(offset: offset, minBytes: n, maxBytes: n, lengthByteOffset: nil, hint: manualHint(n))
    }

    private static func slice(_ b: [UInt8], _ from: Int, _ count: Int) -> [UInt8] {
        if from < 0 || count <= 0 || from >= b.count { return [] }
        let end: Int = min(b.count, from + count)
        return Array(b[from..<end])
    }

    private static func removeRecordAction(_ c: Ctx, _ rec: DisneyTlv.Record, _ start: Int, _ label: String) -> Action? {
        if c.records.count < 2 { return nil }
        let n: Int = 2 + rec.value.count
        guard let h = replacing(c.hex, offset: start, count: n, with: [], lengthByteOffset: nil) else { return nil }
        return Action(label: label, note: "Takes out " + rec.headHex() + " and its \(rec.value.count)-byte value; the other records stay.", hex: h, destructive: true)
    }

    // MARK: Channel, ping, effect head

    private static func channelParts(_ c: Ctx, _ rec: DisneyTlv.Record, _ start: Int) -> Parts {
        var p: Parts = Parts()
        let notes: [String] = ["44 park captures", "10 park captures", "1 park capture"]
        var options: [Option] = []
        for n in 1...3 {
            let t: Int = DisneyTlv.typeChannel1 + n - 1
            let label: String = DisneyTlv.hex2(t) + " 00 · Channel \(n)"
            options.append(Option(bytes: [UInt8(t), 0x00], label: label, note: notes[n - 1], palette: nil, experimental: false))
        }
        let number: Int = rec.type - DisneyTlv.typeChannel1 + 1
        p.fields.append(Field(
            kind: .channel, title: "Channel", offset: start, count: 2, lengthByteOffset: nil,
            current: slice(c.bytes, start, 2), caption: "Channel \(number)", about: channelDoes, options: options
        ))
        if let a = removeRecordAction(c, rec, start, "Remove channel marker") {
            p.actions.append(a)
        }
        p.manual = fixedManual(start, 2)
        return p
    }

    private static let pingValues: [(String, String, Bool)] = [
        ("000100", "Wake Ping", false),
        ("000000", "Signal Beacon", false),
        ("234100", "Show Ping (2341)", false),
        ("203000", "Show Ping (2030)", false),
        ("132000", "'RRC' ping (Flipper; unseen)", true),
    ]

    private static func pingParts(_ c: Ctx, _ rec: DisneyTlv.Record, _ start: Int, _ extended: Bool) -> Parts {
        if rec.value.count != 3 || rec.truncated {
            var other: Parts = valueParts(c, c.recordIndex(at: start) ?? 0, start)
            if let a = removeRecordAction(c, rec, start, "Remove this ping") {
                other.actions = [a]
            }
            return other
        }
        var p: Parts = Parts()
        var options: [Option] = []
        for v in pingValues {
            if v.2 && !extended { continue }
            let note: String = v.0 == "000100" ? "Captured show packets start with it" : ""
            options.append(Option(bytes: HexUtils.hexToBytes(v.0), label: v.0 + " · " + v.1, note: note, palette: nil, experimental: v.2))
        }
        p.fields.append(Field(
            kind: .pingValue, title: "Ping", offset: start + 2, count: 3, lengthByteOffset: nil,
            current: rec.value, caption: DisneyTlv.pingName(rec.valueHex()), about: pingDoes, options: options
        ))
        if let a = removeRecordAction(c, rec, start, "Remove this ping") {
            p.actions.append(a)
        }
        p.manual = fixedManual(start + 2, 3)
        return p
    }

    private static func effectHeadParts(_ c: Ctx, _ ri: Int, _ start: Int, _ extended: Bool) -> Parts {
        var p: Parts = Parts()
        p.fields.append(shapeField(c, ri, start, extended))
        p.actions = framingActions(c)
        p.manual = fixedManual(start, 2)
        return p
    }

    /// One template E9 record per shape the editor can switch to.
    private struct ShapeTemplate {
        let len: Int
        let record: [UInt8]
        let source: String
        let experimental: Bool
    }

    private static func showHex(_ name: String) -> String? {
        for show in LabPacketBuilder.showEffects where show.0 == name {
            return show.1
        }
        return nil
    }

    private static let shapeTemplates: [ShapeTemplate] = {
        var sources: [(String, String, Bool)] = []
        sources.append(("Single Color builder", PacketBuilder.preset(color: PacketBuilder.Color.cyan), false))
        sources.append(("Dual Color builder", PacketBuilder.dual(PacketBuilder.Color.yellowOrange, PacketBuilder.Color.blue), false))
        if let first = LabPacketBuilder.experiments.first {
            sources.append(("experiment " + first.name, first.hex, true))
        }
        sources.append(("Custom RGB builder", PacketBuilder.rgb(63, 20, 0), true))
        sources.append(("Rainbow builder", PacketBuilder.rainbow5(), false))
        for e in LabPacketBuilder.experiments where e.name == "Unseen length E90A" {
            sources.append(("experiment " + e.name, e.hex, true))
        }
        sources.append(("Circle builder", PacketBuilder.circle(), false))
        sources.append(("Rainbow FX", PacketBuilder.rainbowFinale, false))
        let shows: [String] = ["Oct 3 · Cyan/pink twinkle", "Oct 3 · Cyan candles", "Oct 3 · Pink comet"]
        for name in shows {
            if let h = LabSegmentEditor.showHex(name) { sources.append((name, h, false)) }
        }
        sources.append(("Crossfade builder", PacketBuilder.crossfade(), false))
        sources.append(("Rotating Colors builder", PacketBuilder.rotate(0x02, 0x02, 0x02, 0x04, 0x04), false))
        if let h = LabSegmentEditor.showHex("Oct 3 · Repeating fade") {
            sources.append(("Oct 3 · Repeating fade", h, false))
        }
        var out: [ShapeTemplate] = []
        var lens: Set<Int> = []
        for s in sources {
            guard let e = DisneyTlv.parse(s.1)?.effect, !e.truncated else { continue }
            if lens.contains(e.declaredLength) { continue }
            lens.insert(e.declaredLength)
            var record: [UInt8] = [UInt8(DisneyTlv.typeEffect), UInt8(e.declaredLength & 0xFF)]
            record.append(contentsOf: e.value)
            out.append(ShapeTemplate(len: e.declaredLength, record: record, source: s.0, experimental: s.2))
        }
        return out.sorted(by: { (a: ShapeTemplate, b: ShapeTemplate) -> Bool in a.len < b.len })
    }()

    /// The whole E9 record as each shape: the shape's template with this packet's colours (in slot
    /// order) and buzz carried over. The current shape's option is the record as it is.
    private static func shapeField(_ c: Ctx, _ ri: Int, _ start: Int, _ extended: Bool) -> Field {
        let rec: DisneyTlv.Record = c.records[ri]
        let count: Int = 2 + rec.value.count
        let current: [UInt8] = slice(c.bytes, start, count)
        // `withColors` rewrites the first E9 record, so colours carry over only when that is this one.
        let oldColors: [Int] = c.firstEffectIndex == ri ? LabPacketBuilder.slotColors(c.hex) : []
        let oldLast: Int? = rec.value.last.map { (b: UInt8) -> Int in Int(b) }
        var options: [Option] = []
        for t in shapeTemplates {
            if t.experimental && !extended { continue }
            let label: String = "E9" + DisneyTlv.hex2(t.len) + " · " + DisneyTlv.effectName(t.len)
            if t.len == rec.declaredLength && !rec.truncated {
                options.append(Option(bytes: current, label: label, note: "Current shape, kept as it is", palette: nil, experimental: t.experimental))
                continue
            }
            var bytes: [UInt8] = c.bytes
            let end: Int = min(bytes.count, start + count)
            if start < 0 || start > end { continue }
            bytes.replaceSubrange(start..<end, with: t.record)
            var packet: String = HexUtils.bytesToHex(bytes)
            if !oldColors.isEmpty {
                packet = LabPacketBuilder.withColors(packet, oldColors)
            }
            var nb: [UInt8] = HexUtils.hexToBytes(packet)
            let recEnd: Int = start + t.record.count
            if recEnd > nb.count || recEnd < start + 2 { continue }
            let lastIndex: Int = recEnd - 1
            if let ol = oldLast, (ol & 0xF0) == 0xB0, (Int(nb[lastIndex]) & 0xF0) == 0xB0 {
                nb[lastIndex] = UInt8(0xB0 | (ol & 0x0F))
            }
            options.append(Option(
                bytes: Array(nb[start..<recEnd]), label: label, note: "Template: " + t.source,
                palette: nil, experimental: t.experimental
            ))
        }
        let caption: String = "E9" + DisneyTlv.hex2(rec.declaredLength) + " · " + DisneyTlv.effectName(rec.declaredLength)
        return Field(
            kind: .shape, title: "Effect shape", offset: start, count: count, lengthByteOffset: nil,
            current: current, caption: caption, about: effectDoes, options: options
        )
    }

    /// Add the framing the captured show packets carry: a wake ping first, a channel marker before
    /// the effect.
    private static func framingActions(_ c: Ctx) -> [Action] {
        guard let p = c.parsed else { return [] }
        var out: [Action] = []
        if p.records.first?.type != DisneyTlv.typePing {
            let ping: [UInt8] = [0xCC, 0x03, 0x00, 0x01, 0x00]
            if let h = replacing(c.hex, offset: 2, count: 0, with: ping, lengthByteOffset: nil) {
                out.append(Action(
                    label: "Add wake ping first (CC03 000100)",
                    note: "Tells nearby bands to listen before the effect arrives. The captured show packets all start this way.",
                    hex: h, destructive: false
                ))
            }
        }
        if p.channel == nil, let ei = c.firstEffectIndex, ei < c.starts.count {
            let marker: [UInt8] = [0xE1, 0x00]
            if let h = replacing(c.hex, offset: c.starts[ei], count: 0, with: marker, lengthByteOffset: nil) {
                out.append(Action(
                    label: "Add channel marker (E1 00) before the effect",
                    note: "Every effect recorded in the park carries one. The esp32 presets never did.",
                    hex: h, destructive: false
                ))
            }
        }
        return out
    }

    // MARK: Header

    private struct Seen {
        let byte: Int
        var names: [String]
        var experimental: Bool
    }

    private struct SourcePacket {
        let name: String
        let hex: String
        let experimental: Bool
    }

    /// Every packet the app itself knows: the builders' own output, the presets, the captured
    /// shows and (Extended) the experiments.
    private static let sourcePackets: [SourcePacket] = {
        var out: [SourcePacket] = []
        let builderTypes: [LabPacketBuilder.LabPacketType] = [.preset, .dual, .crossfade, .rainbow, .rotate, .circle, .rgb]
        for t in builderTypes {
            let hex: String = LabPacketBuilder.build(type: t, colors: LabPacketBuilder.defaultColors(t), vibEnabled: false, vibPattern: 0)
            out.append(SourcePacket(name: t.label + " builder", hex: hex, experimental: t.experimental))
        }
        for preset in PresetCatalog.all {
            out.append(SourcePacket(name: preset.label, hex: preset.hex, experimental: false))
        }
        for show in LabPacketBuilder.showEffects {
            out.append(SourcePacket(name: show.0, hex: show.1, experimental: false))
        }
        for e in LabPacketBuilder.experiments {
            out.append(SourcePacket(name: e.name, hex: e.hex, experimental: true))
        }
        return out
    }()

    /// Per E9 length, every value body byte `bodyIndex` takes in the known packets.
    private static func seenBytes(_ bodyIndex: Int) -> [Int: [Seen]] {
        var table: [Int: [Seen]] = [:]
        for src in sourcePackets {
            guard let e = DisneyTlv.parse(src.hex)?.effect, !e.truncated, let b = e.byte(bodyIndex) else { continue }
            var list: [Seen] = table[e.declaredLength] ?? []
            if let i = list.firstIndex(where: { (s: Seen) -> Bool in s.byte == b }) {
                if !list[i].names.contains(src.name) { list[i].names.append(src.name) }
                if !src.experimental { list[i].experimental = false }
            } else {
                list.append(Seen(byte: b, names: [src.name], experimental: src.experimental))
            }
            table[e.declaredLength] = list
        }
        return table
    }

    private static let seenTimings: [Int: [Seen]] = LabSegmentEditor.seenBytes(1)
    private static let seenFlags: [Int: [Seen]] = LabSegmentEditor.seenBytes(2)

    private static func seenNames(_ s: Seen) -> String {
        let first: [String] = Array(s.names.prefix(2))
        var text: String = first.joined(separator: ", ")
        if s.names.count > 2 { text += " +\(s.names.count - 2)" }
        return text
    }

    /// Timing presets: the byte, then where it comes from. Captions come from `timingCaption`.
    private static let timingPresets: [(Int, String)] = [
        (0x8F, "Flipper: Always on · experiment Always-on red"),
        (0x09, "Flipper calls this ≈20 s · Ambient shows, Show Off"),
        (0x06, "Flipper calls this ≈10 s"),
        (0x04, "Flipper calls this ≈5 s · Oct 3 twinkle"),
        (0x03, "Flipper calls this ≈3 s · Rotate builder, Pirate Cannon"),
        (0x2E, "Single Color and Rainbow builders"),
        (0x22, "Dual builder, E907"),
        (0x0F, "Circle builder, Lightning / Rainbow FX"),
        (0x6F, "Crossfade builder"),
        (0x0E, "RGB builder"),
        (0x4F, "experiment 46-second red"),
    ]

    private static func headerParts(_ c: Ctx, _ rec: DisneyTlv.Record, _ off: Int, _ extended: Bool) -> Parts {
        var p: Parts = Parts()
        let len: Int = rec.declaredLength
        let sub: Int = c.byte(off)
        let timing: Int = c.byte(off + 1)
        let flags: Int = c.byte(off + 2)

        let subOptions: [Option] = [
            Option(bytes: [0x00], label: "00 · every park effect", note: "", palette: nil, experimental: false),
            Option(bytes: [0x0B], label: "0B · circle template (esp32)", note: "Circle builder", palette: nil, experimental: false),
        ]
        var subCaption: String = DisneyTlv.hex2(sub) + " · meaning unknown"
        if sub == 0x00 { subCaption = "00 · every park effect" }
        if sub == 0x0B { subCaption = "0B · circle template" }
        p.fields.append(Field(
            kind: .subCode, title: "Sub-code", offset: off, count: 1, lengthByteOffset: nil,
            current: [UInt8(sub)], caption: subCaption, about: subCodeAbout, options: subOptions
        ))

        p.fields.append(Field(
            kind: .timing, title: "Timing", offset: off + 1, count: 1, lengthByteOffset: nil,
            current: [UInt8(timing)], caption: DisneyTlv.timingCaption(timing), about: timingAbout,
            options: timingOptions(len, extended)
        ))

        var flagCaption: String = DisneyTlv.hex2(flags)
        if len == 0x12 {
            flagCaption += flags == 0x0F ? " · rotate colours" : " · two-colour toggle"
        }
        p.fields.append(Field(
            kind: .flags, title: "Flags", offset: off + 2, count: 1, lengthByteOffset: nil,
            current: [UInt8(flags)], caption: flagCaption, about: flagsAbout, options: flagOptions(len, extended)
        ))
        p.manual = fixedManual(off, 3)
        return p
    }

    private static func timingOptions(_ len: Int, _ extended: Bool) -> [Option] {
        var out: [Option] = []
        var used: Set<Int> = []
        let seen: [Seen] = seenTimings[len] ?? []
        for preset in timingPresets {
            if used.contains(preset.0) { continue }
            used.insert(preset.0)
            let label: String = DisneyTlv.hex2(preset.0) + " · " + DisneyTlv.timingCaption(preset.0)
            out.append(Option(bytes: [UInt8(preset.0)], label: label, note: preset.1, palette: nil, experimental: false))
        }
        for s in seen {
            if used.contains(s.byte) { continue }
            if s.experimental && !extended { continue }
            used.insert(s.byte)
            let label: String = DisneyTlv.hex2(s.byte) + " · " + DisneyTlv.timingCaption(s.byte)
            out.append(Option(bytes: [UInt8(s.byte)], label: label, note: "Seen in " + seenNames(s), palette: nil, experimental: s.experimental))
        }
        return out
    }

    private static func flagOptions(_ len: Int, _ extended: Bool) -> [Option] {
        var out: [Option] = []
        var used: Set<Int> = []
        if len == 0x12 {
            out.append(Option(bytes: [0x0F], label: "0F · rotate colours", note: "Rotating Colors builder", palette: nil, experimental: false))
            out.append(Option(bytes: [0x0E], label: "0E · two-colour toggle", note: "Any value but 0F toggles two colours", palette: nil, experimental: false))
            used.insert(0x0F)
            used.insert(0x0E)
        }
        for s in seenFlags[len] ?? [] {
            if used.contains(s.byte) { continue }
            if s.experimental && !extended { continue }
            used.insert(s.byte)
            let label: String = DisneyTlv.hex2(s.byte) + " · seen value"
            out.append(Option(bytes: [UInt8(s.byte)], label: label, note: "Seen in " + seenNames(s), palette: nil, experimental: s.experimental))
        }
        let usual: [(Int, String)] = [(0x0E, "0E · usual on single colours"), (0x0F, "0F · usual on other shapes")]
        for u in usual {
            if used.contains(u.0) { continue }
            used.insert(u.0)
            out.append(Option(bytes: [UInt8(u.0)], label: u.1, note: "", palette: nil, experimental: false))
        }
        return out
    }

    // MARK: Colour

    /// All 32 palette colours, each keeping the byte's high 3 bits `high`.
    private static func paletteOptions(_ high: Int) -> [Option] {
        var out: [Option] = []
        for i in 0..<32 {
            let b: Int = ((high & 0x07) << 5) | i
            out.append(Option(bytes: [UInt8(b)], label: LabPacketBuilder.labLabel(i), note: "", palette: i, experimental: false))
        }
        return out
    }

    private static let flagDescriptions: [(Int, String)] = [
        (2, "park duals, fades, E90C/E90F colours"),
        (4, "app Dual builder"),
        (5, "5-zone, rotate, twinkle templates"),
        (7, "single-colour template"),
        (0, "seen only in circle/sparkle bytes, or unseen"),
        (1, "seen only in circle/sparkle bytes, or unseen"),
        (3, "seen only in circle/sparkle bytes, or unseen"),
        (6, "seen only in circle/sparkle bytes, or unseen"),
    ]

    private static func flagDescription(_ flag: Int) -> String {
        for d in flagDescriptions where d.0 == flag {
            return d.1
        }
        return ""
    }

    private static func zoneMaskLabel(_ mask: Int) -> String {
        for m in LabPacketBuilder.ledMasks where m.0 == mask {
            return m.1
        }
        return "Mask \(mask)"
    }

    private static func paletteField(_ title: String, _ offset: Int, _ v: Int, _ about: String) -> Field {
        return Field(
            kind: .color, title: title, offset: offset, count: 1, lengthByteOffset: nil,
            current: [UInt8(v & 0xFF)], caption: LabPacketBuilder.labLabel(v & 0x1F), about: about,
            options: paletteOptions((v >> 5) & 0x07)
        )
    }

    private static func colorParts(_ c: Ctx, _ rec: DisneyTlv.Record, _ off: Int, _ title: String) -> Parts {
        var p: Parts = Parts()
        let v: Int = c.byte(off)
        let idx: Int = v & 0x1F
        let high: Int = (v >> 5) & 0x07
        let fieldTitle: String = title.hasPrefix("Colour") ? "Colour" : title
        p.fields.append(paletteField(fieldTitle, off, v, colorFieldAbout))

        var flagOptionsList: [Option] = []
        let flagTitle: String
        let flagCaption: String
        let flagAbout: String
        if rec.declaredLength == 0x05 {
            flagTitle = "LEDs (zone mask)"
            flagCaption = "\(high) · " + zoneMaskLabel(high)
            flagAbout = zoneMaskAbout
            for m in LabPacketBuilder.ledMasks {
                let b: Int = ((m.0 & 0x07) << 5) | idx
                flagOptionsList.append(Option(bytes: [UInt8(b)], label: "\(m.0) · " + m.1, note: "", palette: nil, experimental: false))
            }
        } else {
            flagTitle = "Flag"
            flagCaption = bin(high, 3) + " · " + flagDescription(high)
            flagAbout = flagBitsAbout
            for d in flagDescriptions {
                let b: Int = ((d.0 & 0x07) << 5) | idx
                flagOptionsList.append(Option(bytes: [UInt8(b)], label: bin(d.0, 3) + " · " + d.1, note: "", palette: nil, experimental: false))
            }
        }
        p.fields.append(Field(
            kind: .colorFlag, title: flagTitle, offset: off, count: 1, lengthByteOffset: nil,
            current: [UInt8(v)], caption: flagCaption, about: flagAbout, options: flagOptionsList
        ))
        p.manual = fixedManual(off, 1)
        return p
    }

    // MARK: Data

    /// One named byte inside an effect's Data run, by body index.
    private struct NamedByte {
        let index: Int
        let kind: FieldKind
        let title: String
        let about: String
        let options: [(Int, String, String, Bool)]   // byte, label, note, experimental
    }

    private static let e907About = "Colour-like byte: E907 has the dual header plus a third colour byte (experiment \"three colours?\"). Low 5 bits read as a palette colour; the high bits stay."
    private static let e90AAbout = "Colour-like byte in an E9 length nobody has captured. Low 5 bits read as a palette colour; the high bits stay."
    private static let rgbAbout = "Six-bit channel 0–63, sent shifted left one bit (byte = value × 2). The band preview reads bytes 4–6; untested on a band."

    private static func namedBytes(_ rec: DisneyTlv.Record) -> [NamedByte] {
        var out: [NamedByte] = []
        let none: [(Int, String, String, Bool)] = []
        switch rec.declaredLength {
        case 0x07:
            for k in 0..<3 {
                out.append(NamedByte(index: 3 + k, kind: .color, title: "Colour \(k + 1)?", about: e907About, options: none))
            }
        case 0x08:
            let constant: [(Int, String, String, Bool)] = [(0x55, "55 · Flipper builder value", "", false)]
            out.append(NamedByte(index: 3, kind: .mode, title: "Byte 3", about: "Always 55 in the Flipper app's RGB builder. Meaning unknown.", options: constant))
            out.append(NamedByte(index: 4, kind: .rgbChannel, title: "Red", about: rgbAbout, options: none))
            out.append(NamedByte(index: 5, kind: .rgbChannel, title: "Green", about: rgbAbout, options: none))
            out.append(NamedByte(index: 6, kind: .rgbChannel, title: "Blue", about: rgbAbout, options: none))
        case 0x0A:
            for k in 0..<6 {
                out.append(NamedByte(index: 3 + k, kind: .color, title: "Colour \(k + 1)?", about: e90AAbout, options: none))
            }
        case 0x0C:
            let sig: [(Int, String, String, Bool)] = [
                (0x5B, "5B · fade / rainbow", "Lightning, Rainbow FX (colours 5D 46)", false),
                (0x5A, "5A · Oct 3 animation", "Oct 3 pink / cyan animations", false),
            ]
            out.append(NamedByte(index: 5, kind: .mode, title: "Signature", about: "Body byte 5. 5B with colour bytes 5D 46 reads as lightning / rainbow fade; 5A shows up in the Oct 3 animations. The rest of the motion is undecoded.", options: sig))
        case 0x0E:
            let modes: [(Int, String, String, Bool)] = [
                (0x02, "02 · twinkle", "Oct 3 capture", false),
                (0x0B, "0B · slow twinkle", "Public listener; experiment", true),
            ]
            out.append(NamedByte(index: 10, kind: .mode, title: "Twinkle mode", about: "Body byte 10. 02 in the Oct 3 twinkles; a public listener reads 0B as a slow twinkle.", options: modes))
        case 0x0F:
            // Only the candle template (flags 0F) has a mode here; in the 0E sparkle / strobe
            // variants this byte is other data.
            if rec.byte(2) == 0x0F {
                let modes: [(Int, String, String, Bool)] = [
                    (0x2A, "2A · candle flicker", "Oct 3 cyan candles", false),
                    (0x02, "02 · centre pulse", "Oct 3 blue centre pulse", false),
                    (0x2B, "2B · experiment", "Candles, mode 2B", true),
                    (0x03, "03 · experiment", "Candles, mode 03", true),
                ]
                out.append(NamedByte(index: 11, kind: .mode, title: "Mode", about: "Body byte 11 of the candle shape (flags 0F): 2A candle flicker, 02 centre pulse.", options: modes))
            }
        case 0x10:
            out.append(NamedByte(index: 6, kind: .color, title: "Comet colour", about: "Body byte 6 of the comet (8E = pink in the Oct 3 capture). Low 5 bits = palette colour; the high bits stay.", options: none))
        case 0x14:
            let modes: [(Int, String, String, Bool)] = [
                (0x02, "02 · colour at byte 8", "Oct 3 repeating fade", false),
                (0x05, "05 · colour at byte 8", "Public listener", false),
            ]
            out.append(NamedByte(index: 7, kind: .mode, title: "Mode", about: "Body byte 7. With 02 or 05 here, byte 8 is the fade's colour.", options: modes))
            let mode: Int = rec.byte(7) ?? -1
            if mode == 0x02 || mode == 0x05 {
                out.append(NamedByte(index: 8, kind: .color, title: "Colour", about: "Body byte 8 (mode 02 / 05). Low 5 bits = palette colour; the high bits stay.", options: none))
            }
        default:
            break
        }
        return out
    }

    private struct Variant {
        let name: String
        let bytes: [UInt8]
        let experimental: Bool
    }

    /// Where an effect's Data run sits in its body (the same split `DisneyTlv.anatomy` makes).
    private static func dataRange(_ rec: DisneyTlv.Record) -> (start: Int, end: Int)? {
        let v: [UInt8] = rec.value
        guard let last = v.last else { return nil }
        let slots: Int = DisneyTlv.colorSlotCount(rec.declaredLength)
        let hasTail: Bool = (Int(last) & 0xF0) == 0xB0
        let end: Int = hasTail ? v.count - 1 : v.count
        let start: Int = (slots > 0 && v.count >= 3 + slots) ? 3 + slots : 3
        if end <= start { return nil }
        return (start: start, end: end)
    }

    private static func variantKey(_ len: Int, _ start: Int, _ count: Int) -> String {
        return "\(len):\(start):\(count)"
    }

    /// Data runs of the known packets, keyed by E9 length + position + size in the body.
    private static let dataVariants: [String: [Variant]] = {
        var table: [String: [Variant]] = [:]
        for src in LabSegmentEditor.sourcePackets {
            guard let e = DisneyTlv.parse(src.hex)?.effect, !e.truncated, let r = LabSegmentEditor.dataRange(e) else { continue }
            let key: String = LabSegmentEditor.variantKey(e.declaredLength, r.start, r.end - r.start)
            let run: [UInt8] = Array(e.value[r.start..<r.end])
            var list: [Variant] = table[key] ?? []
            if let i = list.firstIndex(where: { (x: Variant) -> Bool in x.bytes == run }) {
                if list[i].experimental && !src.experimental {
                    list[i] = Variant(name: src.name, bytes: run, experimental: false)
                }
            } else {
                list.append(Variant(name: src.name, bytes: run, experimental: src.experimental))
            }
            table[key] = list
        }
        return table
    }()

    private static func dataParts(_ c: Ctx, _ rec: DisneyTlv.Record, _ start: Int, _ off: Int, _ count: Int, _ extended: Bool) -> Parts {
        var p: Parts = Parts()
        let bodyBase: Int = start + 2
        let from: Int = off - bodyBase
        let to: Int = from + count
        for nb in namedBytes(rec) {
            if nb.index < from || nb.index >= to || nb.index >= rec.value.count { continue }
            let at: Int = bodyBase + nb.index
            let v: Int = c.byte(at)
            switch nb.kind {
            case .color:
                p.fields.append(paletteField(nb.title, at, v, nb.about))
            case .rgbChannel:
                let level: Int = (v >> 1) & 0x3F
                p.fields.append(Field(
                    kind: .rgbChannel, title: nb.title, offset: at, count: 1, lengthByteOffset: nil,
                    current: [UInt8(v)], caption: "\(level) of 63", about: nb.about, options: []
                ))
            default:
                var options: [Option] = []
                var caption: String = DisneyTlv.hex2(v) + " · unknown value"
                for o in nb.options {
                    if o.0 == v { caption = o.1 }
                    if o.3 && !extended { continue }
                    options.append(Option(bytes: [UInt8(o.0)], label: o.1, note: o.2, palette: nil, experimental: o.3))
                }
                p.fields.append(Field(
                    kind: nb.kind, title: nb.title, offset: at, count: 1, lengthByteOffset: nil,
                    current: [UInt8(v)], caption: caption, about: nb.about, options: options
                ))
            }
        }
        let current: [UInt8] = slice(c.bytes, off, count)
        let known: [Variant] = dataVariants[variantKey(rec.declaredLength, from, count)] ?? []
        var options: [Option] = []
        var caption: String = "not one of the known runs"
        for v in known {
            if v.bytes == current { caption = "as in " + v.name }
            if v.experimental && !extended { continue }
            let label: String = v.name + " · " + HexUtils.bytesToHex(v.bytes)
            options.append(Option(bytes: v.bytes, label: label, note: "", palette: nil, experimental: v.experimental))
        }
        if !options.isEmpty {
            p.fields.append(Field(
                kind: .dataVariant, title: "Known variants", offset: off, count: count, lengthByteOffset: nil,
                current: current, caption: caption,
                about: "The whole Data run as it appears in another known packet of this shape.", options: options
            ))
        }
        p.manual = fixedManual(off, count)
        return p
    }

    // MARK: Tail

    private static let extendedTails: [(Int, String, String)] = [
        (0xAB, "AB · Flipper: short 0.5 s", "Flipper encoding: pattern in the high nibble"),
        (0x7B, "7B · Flipper: long 2 s", "Flipper encoding"),
        (0x5B, "5B · Flipper: fast", "Flipper encoding"),
        (0x6B, "6B · Flipper: complex", "Flipper encoding"),
        (0x8B, "8B · Flipper: rapid", "Flipper encoding"),
        (0x95, "95 · Lightning tail (fade)", "Lightning ends this way"),
        (0x01, "01 · Park E911 ending", "Seen at the end of a park E911"),
    ]

    private static func tailParts(_ c: Ctx, _ off: Int, _ extended: Bool) -> Parts {
        var p: Parts = Parts()
        let v: Int = c.byte(off)
        var options: [Option] = []
        for pattern in LabPacketBuilder.vibrationPatterns {
            let b: Int = 0xB0 | (pattern.id & 0x0F)
            let name: String = pattern.id == 0 ? "Off (no buzz)" : pattern.label
            let note: String = b == 0xBB ? "Flipper reads BB as pulse 1 s" : ""
            options.append(Option(bytes: [UInt8(b)], label: DisneyTlv.hex2(b) + " · " + name, note: note, palette: nil, experimental: false))
        }
        if extended {
            for t in extendedTails {
                let note: String = t.2 + ". The Tail block goes away: outside B0–BF the byte reads as Data."
                options.append(Option(bytes: [UInt8(t.0)], label: t.1, note: note, palette: nil, experimental: true))
            }
        }
        var caption: String = DisneyTlv.hex2(v) + " · not a buzz tail"
        if (v & 0xF0) == 0xB0 {
            let n: Int = v & 0x0F
            caption = n == 0 ? "no buzz" : "buzz \(n) (" + vibrationName(n) + ")"
        }
        p.fields.append(Field(
            kind: .tail, title: "Buzz", offset: off, count: 1, lengthByteOffset: nil,
            current: [UInt8(v)], caption: caption, about: tailDoes, options: options
        ))
        p.manual = fixedManual(off, 1)
        return p
    }

    // MARK: Wand

    private static func wandParts(_ c: Ctx, _ ri: Int, _ start: Int, _ savedSerial: String) -> Parts {
        var p: Parts = Parts()
        let rec: DisneyTlv.Record = c.records[ri]
        let value: [UInt8] = rec.value
        let vs: Int = start + 2
        if value.count == 11 && !rec.truncated {
            // CF9B swallows the rest of the packet, so it may only stand at the end.
            if ri == c.records.count - 1 {
                let marker: Int = c.byte(start + 1)
                let options: [Option] = [
                    Option(bytes: [0x0B], label: "CF0B · New Wand (well-formed)", note: "Declares the 11 bytes that follow", palette: nil, experimental: false),
                    Option(bytes: [0x9B], label: "CF9B · Legacy Starlight template", note: "Declares 155 bytes; kept for old presets", palette: nil, experimental: false),
                ]
                p.fields.append(Field(
                    kind: .wandMarker, title: "Marker", offset: start + 1, count: 1, lengthByteOffset: nil,
                    current: [UInt8(marker)], caption: "CF" + DisneyTlv.hex2(marker), about: wandDoes, options: options
                ))
            }
            let serial: [UInt8] = Array(value[1..<10])
            let defaultSerial: String = String(StarlightSerial.defaultSerial.prefix(18))
            var options: [Option] = [
                Option(bytes: HexUtils.hexToBytes(defaultSerial), label: defaultSerial + " · app default", note: "", palette: nil, experimental: false),
            ]
            let saved: String = savedSerial.uppercased().filter { (ch: Character) -> Bool in "0123456789ABCDEF".contains(ch) }
            if saved.count >= 18 {
                let saved18: String = String(saved.prefix(18))
                if saved18 != defaultSerial {
                    options.append(Option(bytes: HexUtils.hexToBytes(saved18), label: saved18 + " · your saved serial", note: "", palette: nil, experimental: false))
                }
            }
            p.fields.append(Field(
                kind: .wandSerial, title: "Serial", offset: vs + 1, count: 9, lengthByteOffset: nil,
                current: serial, caption: HexUtils.bytesToHex(serial),
                about: "Nine bytes that name the wand. Any serial replays; the receiver only reads the colour.", options: options
            ))
        }
        if let last = value.last {
            let v: Int = Int(last)
            p.fields.append(Field(
                kind: .wandColor, title: "Colour", offset: vs + value.count - 1, count: 1, lengthByteOffset: nil,
                current: [last], caption: LabPacketBuilder.labLabel(v & 0x1F),
                about: "Last byte: the colour the wand receiver shows (low 5 bits). The high 3 bits stay as they are.",
                options: paletteOptions((v >> 5) & 0x07)
            ))
            if !rec.truncated {
                p.manual = fixedManual(vs, value.count)
            }
        }
        return p
    }

    /// New Wand codes run E80–FFF in the last 12 bits, without F20–F7F.
    private static let newWandHexes: Set<String> = Set(NewWandCatalog.packets.map { (packet: MagicPacket) -> String in packet.hex })

    /// A warning for a packet that looks like a New Wand code but is not one the wand answers.
    static func newWandWarning(_ hexRaw: String) -> String? {
        let h: String = HexUtils.canonicalHex(hexRaw)
        if !h.hasPrefix(NewWandCatalog.prefix) { return nil }
        if newWandHexes.contains(h) { return nil }
        return "Not a real New Wand code: real codes end E80–FFF, without F20–F7F."
    }

    // MARK: Telemetry, beacons, unknown records

    private static func valueParts(_ c: Ctx, _ ri: Int, _ start: Int) -> Parts {
        var p: Parts = Parts()
        if ri < 0 || ri >= c.records.count { return p }
        let rec: DisneyTlv.Record = c.records[ri]
        let vs: Int = start + 2
        if !rec.truncated && !rec.legacyStarlight {
            p.fields.append(Field(
                kind: .recordValue, title: "Value", offset: vs, count: rec.value.count, lengthByteOffset: start + 1,
                current: rec.value, caption: "\(rec.value.count) bytes",
                about: "Type any new value in Manual hex; the length byte (now " + rec.lengthHex() + ") is rewritten to match.",
                options: []
            ))
            p.manual = ManualRule(offset: vs, minBytes: 0, maxBytes: 255, lengthByteOffset: start + 1, hint: "0–255 bytes; the length byte follows")
        }
        // EF 05 01 A6 <flag> <palette> <x>: a colour cue.
        if rec.type == 0xEF && rec.value.count == 5 && rec.byte(0) == 0x01 && rec.byte(1) == 0xA6 {
            let v: Int = c.byte(vs + 3)
            p.fields.append(paletteField("Cue colour", vs + 3, v, "Value byte 3 of an EF05 colour cue: the palette colour (low 5 bits). The high bits stay."))
        }
        if let a = removeRecordAction(c, rec, start, "Remove this record") {
            p.actions.append(a)
        }
        return p
    }

    // MARK: Malformed packets

    private static func repairActions(_ c: Ctx) -> [Action] {
        guard let p = c.parsed, p.malformed != nil else { return [] }
        let n: Int = c.bytes.count
        // Where the chain broke: the start of a cut-short last record, else the first byte no
        // record took.
        var pos: Int = 2
        var cutStart: Int? = nil
        var i: Int = 0
        while i < p.records.count {
            let r: DisneyTlv.Record = p.records[i]
            if r.truncated {
                cutStart = pos
                break
            }
            pos += 2 + r.value.count
            i += 1
        }
        let at: Int = cutStart ?? pos
        var out: [Action] = []
        if at < 0 || at >= n { return out }
        if cutStart == nil && n - at == 1 {
            let b: Int = c.byte(at)
            if let h = replacing(c.hex, offset: at, count: 1, with: [], lengthByteOffset: nil) {
                out.append(Action(
                    label: "Drop the trailing byte " + DisneyTlv.hex2(b),
                    note: "A record needs at least a type byte and a length byte.", hex: h, destructive: true
                ))
            }
            return out
        }
        if at + 1 < n {
            let actual: Int = n - (at + 2)
            let declared: Int = c.byte(at + 1)
            if actual >= 0 && actual <= 255 {
                if let h = replacing(c.hex, offset: at + 1, count: 1, with: [UInt8(actual)], lengthByteOffset: nil) {
                    let note: String = "Record " + DisneyTlv.hex2(c.byte(at)) + " declares \(declared) bytes; \(actual) follow."
                    out.append(Action(label: "Set its length to " + DisneyTlv.hex2(actual) + " (what is there)", note: note, hex: h, destructive: false))
                }
            }
            if at > 2, let h = replacing(c.hex, offset: at, count: n - at, with: [], lengthByteOffset: nil) {
                out.append(Action(label: "Drop the cut-off record", note: "Keeps every record before it.", hex: h, destructive: true))
            }
        }
        return out
    }

    // MARK: - Applying edits

    /// Splice `bytes` over `count` bytes at `offset` of the canonical packet. With
    /// `lengthByteOffset` (which must sit before `offset`), that record's length byte grows or
    /// shrinks by the size change. Nil for odd hex, a range outside the packet, or a length that
    /// would leave 0…255.
    static func replacing(_ hexRaw: String, offset: Int, count: Int, with bytes: [UInt8], lengthByteOffset: Int?) -> String? {
        let h: String = HexUtils.canonicalHex(hexRaw)
        if h.count % 2 != 0 { return nil }
        var b: [UInt8] = HexUtils.hexToBytes(h)
        let n: Int = b.count
        if offset < 0 || count < 0 || offset + count > n { return nil }
        b.replaceSubrange(offset..<(offset + count), with: bytes)
        if let lo = lengthByteOffset {
            if lo < 0 || lo >= offset { return nil }
            let newLen: Int = Int(b[lo]) + (bytes.count - count)
            if newLen < 0 || newLen > 255 { return nil }
            b[lo] = UInt8(newLen)
        }
        return HexUtils.bytesToHex(b)
    }

    static func applying(_ hexRaw: String, field: Field, option: Option) -> String? {
        return replacing(hexRaw, offset: field.offset, count: field.count, with: option.bytes, lengthByteOffset: field.lengthByteOffset)
    }

    /// Like `applying`, but onto a packet that may already carry other edits to the same byte: a
    /// palette pick keeps the byte's flag bits as they are in `hexRaw`, a flag pick its palette.
    static func composing(_ hexRaw: String, field: Field, option: Option) -> String? {
        let h: String = HexUtils.canonicalHex(hexRaw)
        let b: [UInt8] = HexUtils.hexToBytes(h)
        var bytes: [UInt8] = option.bytes
        if field.count == 1 && bytes.count == 1 && field.offset >= 0 && field.offset < b.count {
            let cur: UInt8 = b[field.offset]
            switch field.kind {
            case .color, .wandColor:
                bytes = [(cur & 0xE0) | (bytes[0] & 0x1F)]
            case .colorFlag:
                bytes = [(bytes[0] & 0xE0) | (cur & 0x1F)]
            default:
                break
            }
        }
        return replacing(h, offset: field.offset, count: field.count, with: bytes, lengthByteOffset: field.lengthByteOffset)
    }

    /// Whether `option` is what `hexRaw` holds at the field's position (palette picks compare the
    /// palette bits only, flag picks the flag bits only).
    static func isCurrent(_ hexRaw: String, field: Field, option: Option) -> Bool {
        let b: [UInt8] = HexUtils.hexToBytes(HexUtils.canonicalHex(hexRaw))
        let n: Int = option.bytes.count
        if n == 0 || field.offset < 0 || field.offset + n > b.count { return false }
        let here: [UInt8] = Array(b[field.offset..<(field.offset + n)])
        if n == 1 {
            switch field.kind {
            case .color, .wandColor:
                return (here[0] & 0x1F) == (option.bytes[0] & 0x1F)
            case .colorFlag:
                return (here[0] & 0xE0) == (option.bytes[0] & 0xE0)
            default:
                break
            }
        }
        return here == option.bytes
    }

    /// Hex typed by hand: spaces and line breaks are ignored, either case is fine. Nil on any
    /// other character or an odd number of digits.
    static func parseTyped(_ typed: String) -> [UInt8]? {
        var nibbles: [UInt8] = []
        for u in typed.unicodeScalars {
            let v: UInt32 = u.value
            if v == 0x20 || v == 0x09 || v == 0x0A || v == 0x0D || v == 0xA0 { continue }
            if v >= 0x30 && v <= 0x39 {
                nibbles.append(UInt8(v - 0x30))
            } else if v >= 0x41 && v <= 0x46 {
                nibbles.append(UInt8(v - 0x41 + 10))
            } else if v >= 0x61 && v <= 0x66 {
                nibbles.append(UInt8(v - 0x61 + 10))
            } else {
                return nil
            }
        }
        if nibbles.count % 2 != 0 { return nil }
        var out: [UInt8] = []
        var i: Int = 0
        while i + 1 < nibbles.count {
            out.append((nibbles[i] << 4) | nibbles[i + 1])
            i += 2
        }
        return out
    }

    private static let badDigits = "Only hex digits 0–9 and A–F, two per byte."

    private static func sizeProblem(_ minBytes: Int, _ maxBytes: Int, _ typed: Int) -> String? {
        if typed >= minBytes && typed <= maxBytes { return nil }
        if minBytes == maxBytes {
            return "Needs exactly \(minBytes) byte" + (minBytes == 1 ? "" : "s") + " (\(minBytes * 2) hex digits); you typed \(typed)."
        }
        return "Needs \(minBytes)–\(maxBytes) bytes; you typed \(typed)."
    }

    /// Refuses a result that breaks a packet whose record chain was whole.
    private static func checkedChain(_ base: String, _ out: String) -> ManualResult {
        if DisneyTlv.parse(base)?.exact == true {
            let after: DisneyTlv.Parsed? = DisneyTlv.parse(out)
            if after?.exact != true {
                let why: String = after?.malformed ?? "it is no longer a Disney packet"
                return .invalid("That breaks the record chain: " + why)
            }
        }
        return .applied(out)
    }

    static func applyingManual(_ hexRaw: String, segment: EditableSegment, typed: String) -> ManualResult {
        let rule: ManualRule = segment.manual
        if !rule.allowed { return .invalid("This block can't be typed over.") }
        guard let bytes = parseTyped(typed) else { return .invalid(badDigits) }
        if let problem = sizeProblem(rule.minBytes, rule.maxBytes, bytes.count) { return .invalid(problem) }
        let base: String = HexUtils.canonicalHex(hexRaw)
        let c: Ctx = Ctx(base)
        switch segment.segment.kind {
        case .channel:
            if bytes.count >= 2 && bytes[1] != 0x00 {
                return .invalid("The second byte must stay 00 — a channel marker has no body, and any other length would swallow the bytes after it.")
            }
        case .effectHead:
            if let ri = c.recordIndex(at: rule.offset), bytes.count >= 2 {
                let bodyLen: Int = c.records[ri].value.count
                if Int(bytes[1]) != bodyLen {
                    return .invalid("The length byte must stay " + DisneyTlv.hex2(bodyLen) + " — the body is \(bodyLen) bytes. Pick a shape from the list to change it.")
                }
            }
        default:
            break
        }
        var count: Int = rule.maxBytes
        if let lo = rule.lengthByteOffset {
            if lo < 0 || lo >= c.bytes.count { return .invalid("This block has moved; close the editor and tap it again.") }
            count = Int(c.bytes[lo])
        }
        guard let out = replacing(base, offset: rule.offset, count: count, with: bytes, lengthByteOffset: rule.lengthByteOffset) else {
            return .invalid("That does not fit this packet.")
        }
        return checkedChain(base, out)
    }

    static func applyingManual(_ hexRaw: String, field: Field, typed: String) -> ManualResult {
        guard let bytes = parseTyped(typed) else { return .invalid(badDigits) }
        let minBytes: Int = field.lengthByteOffset == nil ? field.count : 0
        let maxBytes: Int = field.lengthByteOffset == nil ? field.count : 255
        if let problem = sizeProblem(minBytes, maxBytes, bytes.count) { return .invalid(problem) }
        switch field.kind {
        case .channel:
            if bytes.count >= 2 && bytes[1] != 0x00 {
                return .invalid("The second byte must stay 00 — a channel marker has no body, and any other length would swallow the bytes after it.")
            }
        case .shape:
            if bytes.count >= 2 && Int(bytes[1]) != bytes.count - 2 {
                return .invalid("The length byte must be " + DisneyTlv.hex2(bytes.count - 2) + " — you typed \(bytes.count - 2) body bytes.")
            }
        default:
            break
        }
        let base: String = HexUtils.canonicalHex(hexRaw)
        guard let out = replacing(base, offset: field.offset, count: field.count, with: bytes, lengthByteOffset: field.lengthByteOffset) else {
            return .invalid("That does not fit this packet.")
        }
        return checkedChain(base, out)
    }

    // MARK: - Timing byte

    static func timingByte(alwaysOn: Bool, longUnit: Bool, fadeSeconds: Int, count: Int) -> Int {
        let a: Int = alwaysOn ? 0x80 : 0
        let l: Int = longUnit ? 0x40 : 0
        return a | l | ((fadeSeconds & 3) << 4) | (count & 0x0F)
    }

    static func timingParts(_ b: Int) -> (alwaysOn: Bool, longUnit: Bool, fadeSeconds: Int, count: Int) {
        return (alwaysOn: (b >> 7) & 1 == 1, longUnit: (b >> 6) & 1 == 1, fadeSeconds: (b >> 4) & 3, count: b & 0x0F)
    }

    // MARK: - Comparing and the builder

    /// The bytes of `after` that differ from `before` (common head and tail trimmed); empty for a
    /// pure deletion, nil when the two are the same.
    static func changedRange(_ before: String, _ after: String) -> Range<Int>? {
        let a: [UInt8] = HexUtils.hexToBytes(HexUtils.canonicalHex(before))
        let b: [UInt8] = HexUtils.hexToBytes(HexUtils.canonicalHex(after))
        if a == b { return nil }
        let m: Int = min(a.count, b.count)
        var p: Int = 0
        while p < m && a[p] == b[p] { p += 1 }
        var s: Int = 0
        while s < m - p && a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        return p..<(b.count - s)
    }

    /// Builder state that rebuilds exactly this packet: the decoded type when building it gives the
    /// same bytes back, otherwise Raw Hex holding the packet byte-for-byte.
    static func builderState(_ hexRaw: String, extended: Bool) -> LabPacketBuilder.Decoded? {
        let h: String = HexUtils.canonicalHex(hexRaw)
        guard let d = LabPacketBuilder.decode(h) else { return nil }
        if extended || !d.type.experimental {
            let colors: [Int] = d.colors.isEmpty ? LabPacketBuilder.defaultColors(d.type) : d.colors
            let rebuilt: String = LabPacketBuilder.build(
                type: d.type, colors: colors, vibEnabled: d.vibEnabled,
                vibPattern: d.vibPattern, rawHex: d.rawHex, framing: d.framing, showIndex: d.showIndex
            )
            if rebuilt == h { return d }
        }
        return LabPacketBuilder.Decoded(type: .raw, colors: [], vibEnabled: d.vibEnabled, vibPattern: d.vibPattern, rawHex: h)
    }
}
