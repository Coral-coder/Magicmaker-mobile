import Foundation

/// The Disney BLE payload is type-length-value framed. After the `8301` company ID comes a chain
/// of `<type:1><length:1><value:length>` records running to the end of the advertisement; a
/// record may have length 0 (a bare marker). See docs/PROTOCOL.md.
///
/// Line-for-line port of Android `core/DisneyTlv.kt` — keep the two in step. Everything that used
/// to be a substring heuristic ("does the hex contain E?00E9 somewhere") goes through `parse`
/// instead: the records are the ground truth, and a byte sequence that merely looks like a record
/// type inside some other record's value no longer fools us.
enum DisneyTlv {
    static let companyPrefix = "8301"

    /// Record types we have names for. Values are the on-air type byte.
    static let typePing = 0xCC
    static let typeWand = 0xCF
    static let typeEffect = 0xE9
    static let typeChannel1 = 0xE1
    static let typeChannel2 = 0xE2
    static let typeChannel3 = 0xE3
    static let typeBandTelemetry = 0xC0
    static let typeBandId = 0x0F

    /// The legacy Starlight template uses marker `CF9B`. Read as TLV that is type CF with a
    /// 155-byte body, which cannot fit a 31-byte advertisement; the serial + colour it carries is
    /// what `CF0B` declares. We keep parsing it (consuming the rest of the packet as the value) so
    /// the wand UI keeps working, but flag it so nobody mistakes it for well-formed framing.
    static let legacyStarlightLength = 0x9B

    /// `declaredLength` is the on-air length byte; `length` is how many value bytes are actually
    /// present. They differ only for a `truncated` final record — a packet cut short, which we
    /// still want to classify by its declared shape.
    struct Record: Equatable {
        let type: Int
        let value: [UInt8]
        let declaredLength: Int
        let legacyStarlight: Bool

        init(type: Int, value: [UInt8], declaredLength: Int? = nil, legacyStarlight: Bool = false) {
            self.type = type
            self.value = value
            self.declaredLength = declaredLength ?? value.count
            self.legacyStarlight = legacyStarlight
        }

        var length: Int { value.count }
        var truncated: Bool { !legacyStarlight && declaredLength != value.count }
        func typeHex() -> String { DisneyTlv.hex2(type) }
        func lengthHex() -> String { DisneyTlv.hex2(legacyStarlight ? DisneyTlv.legacyStarlightLength : declaredLength) }
        func valueHex() -> String { HexUtils.bytesToHex(value) }
        /// `type + length` as four hex chars — what the old code called a "function code".
        func headHex() -> String { typeHex() + lengthHex() }
        func isChannelMarker() -> Bool { type >= DisneyTlv.typeChannel1 && type <= DisneyTlv.typeChannel3 && length == 0 }
        /// Unsigned value byte, or nil when the body is shorter than that.
        func byte(_ i: Int) -> Int? { (i >= 0 && i < value.count) ? Int(value[i]) : nil }
    }

    /// `records` are the records that parsed cleanly, in order. `malformed` is nil when the chain
    /// consumed the payload exactly; otherwise it says what went wrong at the end. A packet can be
    /// useful even when malformed — the records before the break are still real.
    struct Parsed: Equatable {
        let hex: String
        let records: [Record]
        let malformed: String?

        var exact: Bool { malformed == nil }
        func first(_ type: Int) -> Record? { records.first { $0.type == type } }
        func has(_ type: Int) -> Bool { records.contains { $0.type == type } }
        var effect: Record? { first(DisneyTlv.typeEffect) }
        var channel: Record? { records.first { $0.isChannelMarker() } }
    }

    /// Two uppercase hex digits for the low byte of `v`.
    static func hex2(_ v: Int) -> String { String(format: "%02X", v & 0xFF) }

    /// Parse canonical or raw hex. Returns nil if this isn't a Disney manufacturer payload at all.
    static func parse(_ hexRaw: String) -> Parsed? {
        let hex = HexUtils.canonicalHex(hexRaw)
        if !hex.hasPrefix(companyPrefix) || hex.count < 4 || hex.count % 2 != 0 { return nil }
        let bytes = HexUtils.hexToBytes(hex)
        var records: [Record] = []
        var i = 2
        var malformed: String? = nil
        while i < bytes.count {
            if i + 1 >= bytes.count {
                malformed = "trailing byte \(hex2(Int(bytes[i]))) with no length"
                break
            }
            let type = Int(bytes[i])
            let len = Int(bytes[i + 1])
            let start = i + 2
            if type == typeWand && len == legacyStarlightLength {
                records.append(Record(type: type, value: Array(bytes[start...]), legacyStarlight: true))
                break
            }
            if start + len > bytes.count {
                let remain = bytes.count - start
                malformed = "record \(hex2(type)) declares \(len) bytes but only \(remain) remain"
                // Keep a cut-short final record (if it has any body at all) so a truncated packet
                // still classifies by its declared shape.
                if remain > 0 {
                    records.append(Record(type: type, value: Array(bytes[start...]), declaredLength: len))
                }
                break
            }
            records.append(Record(type: type, value: Array(bytes[start..<(start + len)])))
            i = start + len
        }
        return Parsed(hex: hex, records: records, malformed: malformed)
    }

    // MARK: - Anatomy
    // The packet explained segment by segment, for the Lab: every byte group gets a caption a
    // person can read.

    enum SegmentKind: String {
        case company, channel, ping, effectHead, header, color, data, tail, wand, beacon, other, error
    }

    struct Segment: Equatable {
        let hex: String
        let title: String
        let detail: String
        let kind: SegmentKind
    }

    static func anatomy(_ hexRaw: String) -> [Segment] {
        guard let parsed = parse(hexRaw) else {
            return [Segment(hex: HexUtils.canonicalHex(hexRaw), title: "Not a Disney packet", detail: "Must start with the 8301 company ID.", kind: .error)]
        }
        var out: [Segment] = []
        out.append(Segment(hex: "8301", title: "Disney", detail: "Company ID 0x0183. Every receiver checks this first.", kind: .company))
        for r in parsed.records {
            out.append(contentsOf: describeRecord(r))
        }
        if let bad = parsed.malformed {
            out.append(Segment(hex: "", title: "Malformed", detail: bad, kind: .error))
        }
        return out
    }

    private static func describeRecord(_ r: Record) -> [Segment] {
        let head = r.headHex()
        if r.isChannelMarker() {
            return [Segment(
                hex: head, title: "Channel \(r.type - typeChannel1 + 1)",
                detail: "Zero-length marker. Every effect in the park capture carries one of these before its effect record.",
                kind: .channel
            )]
        }
        if r.type == typePing {
            return [Segment(
                hex: head + r.valueHex(), title: pingName(r.valueHex()),
                detail: "Interaction ping. 000100 is the wake ping that makes nearby bands listen for the next command.",
                kind: .ping
            )]
        }
        if r.type == typeEffect {
            return describeEffect(r)
        }
        if r.type == typeWand && r.legacyStarlight {
            let last: String = r.value.last.map { hex2(Int($0)) } ?? "?"
            return [Segment(
                hex: head + r.valueHex(), title: "Legacy Starlight code",
                detail: "Marker CF9B declares a 155-byte body, which cannot be right — the body is \(r.length) bytes, "
                    + "which is what CF0B declares. Last byte \(last) is the colour.",
                kind: .wand
            )]
        }
        if r.type == typeWand {
            var tailNote = ""
            if let b = r.byte(r.length - 1) {
                tailNote = "Last byte \(hex2(b)) = \(StarlightColors.nameFor(b))."
            }
            return [Segment(hex: head + r.valueHex(), title: "Wand code", detail: "Serial, then a colour byte. " + tailNote, kind: .wand)]
        }
        if r.type == typeBandTelemetry || r.type == typeBandId {
            return [Segment(hex: head + r.valueHex(), title: "MagicBand telemetry", detail: "Guest-band broadcast with a rolling payload. Never an effect.", kind: .other)]
        }
        if r.type >= 0xE0 && r.type <= 0xEF {
            return [Segment(hex: head + r.valueHex(), title: "Park beacon record (\(head))", detail: "Fixed infrastructure. Not decoded yet.", kind: .beacon)]
        }
        return [Segment(hex: head + r.valueHex(), title: "Unknown record (\(head))", detail: "Type \(r.typeHex()), \(r.length) bytes.", kind: .other)]
    }

    private static func describeEffect(_ r: Record) -> [Segment] {
        var out: [Segment] = []
        let name = effectName(r.declaredLength)
        out.append(Segment(
            hex: r.headHex(), title: "Effect record",
            detail: "\(name) — \(r.declaredLength)-byte body. The length is what picks the effect shape."
                + (r.truncated ? " Only \(r.length) bytes are present: this packet is cut short." : ""),
            kind: .effectHead
        ))
        if r.length == 0 { return out }

        let v = r.value
        func hexOf(_ from: Int, _ to: Int) -> String {
            let end = min(to, v.count)
            if from >= end { return "" }
            return HexUtils.bytesToHex(Array(v[from..<end]))
        }
        let colorSlots = colorSlotCount(r.declaredLength)
        let lastByte = Int(v[v.count - 1])
        let hasTail = (lastByte & 0xF0) == 0xB0

        if colorSlots > 0 && v.count >= 3 + colorSlots {
            out.append(Segment(hex: hexOf(0, 3), title: "Header", detail: headerCaption(v), kind: .header))
            for s in 0..<colorSlots {
                let b = Int(v[3 + s])
                let idx = b & 0x1F
                let high = (b >> 5) & 0x07
                var flagNote = " High bits are the slot flag."
                if r.declaredLength == 0x05 {
                    switch high {
                    case 0, 7: flagNote = " Zone mask \(high) = all LEDs."
                    case 3: flagNote = " Zone mask 3 = bottom-left only."
                    case 4: flagNote = " Zone mask 4 = top-left only."
                    default: flagNote = " Zone mask \(high) (mapping disputed)."
                    }
                }
                out.append(Segment(
                    hex: hex2(b), title: colorSlotTitle(r.declaredLength, s, colorSlots),
                    detail: "Low 5 bits = palette #\(hex2(idx)) \(StarlightColors.nameFor(idx))." + flagNote,
                    kind: .color
                ))
            }
            let rest = 3 + colorSlots
            let dataEnd = hasTail ? v.count - 1 : v.count
            if dataEnd > rest {
                out.append(Segment(hex: hexOf(rest, dataEnd), title: "Data", detail: "Timing / curve bytes for this effect.", kind: .data))
            }
        } else {
            if v.count >= 3 {
                out.append(Segment(hex: hexOf(0, 3), title: "Header", detail: headerCaption(v), kind: .header))
            }
            let dataEnd = hasTail ? v.count - 1 : v.count
            if dataEnd > 3 {
                out.append(Segment(hex: hexOf(3, dataEnd), title: "Data", detail: "Body of an effect we do not decode field-by-field yet.", kind: .data))
            }
        }
        if hasTail {
            let vib = lastByte & 0x0F
            out.append(Segment(
                hex: hex2(lastByte), title: vib == 0 ? "Tail · no buzz" : "Tail · buzz \(vib)",
                detail: "B0 | vibration pattern (0–15). Only meaningful on the esp32_magicband shapes; two real park effects end in 01 instead.",
                kind: .tail
            ))
        }
        return out
    }

    /// Body byte 1 is timing: bits 0-3 count, bit 6 ×3.1 s else ×1.5 s, bits 4-5 fade s, bit 7 always-on.
    static func timingCaption(_ b: Int) -> String {
        if (b >> 7) & 1 == 1 { return "always on" }
        let unit: Float = ((b >> 6) & 1 == 1) ? 3.1 : 1.5
        let secs: Float = Float(b & 0x0F) * unit
        let fade = (b >> 4) & 0x03
        return "on for ~\(roundHalfUp(secs)) s" + (fade > 0 ? ", \(fade) s fade-out" : "")
    }

    /// Kotlin's `"%.0f".format(Float)` rounds the float's shortest decimal form half-up; C's
    /// `%.0f` rounds half-even on the binary value. Mirror Kotlin so both apps print the same.
    static func roundHalfUp(_ value: Float) -> Int {
        let shortest = Double("\(value)") ?? Double(value)
        return Int((shortest + 0.5).rounded(.down))
    }

    private static func headerCaption(_ v: [UInt8]) -> String {
        var timing = ""
        if v.count > 1 {
            timing = " (\(timingCaption(Int(v[1]))))"
        }
        return "Sub-code, then timing byte" + timing + ", then flags."
    }

    static func pingName(_ valueHex: String) -> String {
        switch valueHex {
        case "000000": return "Signal Beacon"
        case "000100": return "Wake Ping"
        case "234100": return "Show Ping (2341)"
        case "203000": return "Show Ping (2030)"
        default: return "Interaction Ping"
        }
    }

    /// Human name for an E9 record by body length — the shape the length implies.
    static func effectName(_ length: Int) -> String {
        switch length {
        case 0x05: return "Single colour"
        case 0x06: return "Dual colour"
        case 0x09: return "5-zone colours"
        case 0x0B: return "Circle spin"
        case 0x0C: return "Complex animation"
        case 0x08: return "Custom RGB colour"
        case 0x0E: return "Per-zone twinkle / flash"
        case 0x0F: return "Candle flicker / centre pulse"
        case 0x10: return "Comet"
        case 0x11: return "Two-colour fade / pulse burst"
        case 0x12: return "Rotating colours"
        case 0x13: return "Corner-pair alternate"
        case 0x14: return "Repeating fade"
        default: return "Show control (E9\(hex2(length)))"
        }
    }

    /// How many palette colour bytes sit at value[3..] for a given body length (0 = not field-decodable).
    static func colorSlotCount(_ length: Int) -> Int {
        switch length {
        case 0x05: return 1
        case 0x06: return 2
        case 0x09: return 5
        case 0x0B: return 7
        case 0x0C: return 2
        case 0x0E: return 5
        case 0x0F: return 2
        case 0x11: return 2
        case 0x12: return 5
        case 0x13: return 3
        default: return 0
        }
    }

    private static func colorSlotTitle(_ length: Int, _ slot: Int, _ slots: Int) -> String {
        switch length {
        case 0x11: return slot == 0 ? "Fade from" : "Fade to"
        case 0x0B: return "Pattern \(slot + 1)"
        case 0x06, 0x0F: return slot == 0 ? "Centre colour" : "Corner colour"
        case 0x0E: return "Zone \(slot + 1)"
        case 0x12:
            let zones = [2, 3, 4, 5, 1]
            return "Zone \(slot < zones.count ? zones[slot] : slot + 1)"
        case 0x13:
            let names = ["Centre", "Pair B", "Pair A"]
            return slot < names.count ? names[slot] : "Colour \(slot + 1)"
        default: return slots == 1 ? "Colour" : "Colour \(slot + 1)"
        }
    }
}
