import Foundation

/// Disney MagicBand+ packet builders — mirrors Android `PacketBuilder.kt` / esp32_magicband.
///
/// Tail byte: `0xB0 | (vibration & 0x0F)`.
enum PacketBuilder {
    enum Color {
        static let cyan = 0x00
        static let purple = 0x01
        static let blue = 0x02
        static let midnightBlue = 0x03
        static let brightPurple = 0x05
        static let lavender = 0x06
        static let pink = 0x08
        static let yellowOrange = 0x0F
        static let lime = 0x12
        static let orange = 0x13
        static let red = 0x15
        static let green = 0x19
        static let white = 0x1B
        static let off = 0x1D
        static let random = 0x1F
    }

    /// esp32 frontend vibration patterns (0–15).
    enum Vibration {
        static let off = 0
        static let short = 1
        static let double = 2
        static let triple = 3
        static let burst = 5
        static let long = 8
    }

    static let wakeupPing = "8301CC03000100"
    /// Park-captured rainbow finale (CC03 wrapper) — strong haptic show packet.
    static let rainbowFinale = "8301CC03000100E100E90C000F0F5D465BF005323748B0"

    private static func pkt(_ bytes: [Int]) -> String {
        HexUtils.bytesToHex(bytes.map { UInt8(truncatingIfNeeded: $0) })
    }

    private static func tail(vib: Int) -> Int { 0xB0 | (vib & 0x0F) }

    /// action=preset — single band color + optional vibration.
    static func preset(color: Int, vib: Int = 0) -> String {
        pkt([0x83, 0x01, 0xE9, 0x05, 0x00, 0x2E, 0x0E, 0xE0 | (color & 0x1F), tail(vib: vib)])
    }

    /// Primary vibrate: white + burst vibration (esp32 preset + vib=5).
    static func vibrateBand(vib: Int = Vibration.burst) -> String {
        preset(color: Color.white, vib: vib)
    }

    /// action=dual
    static func dual(_ c1: Int, _ c2: Int, vib: Int = 0) -> String {
        pkt([0x83, 0x01, 0xE9, 0x06, 0x00, 0x22, 0x0F, 0x80 | (c1 & 0x1F), 0x80 | (c2 & 0x1F), tail(vib: vib)])
    }

    /// action=rainbow — 5-LED palette (E909).
    static func rainbow5(
        c1: Int = Color.yellowOrange,
        c2: Int = Color.red,
        c3: Int = Color.green,
        c4: Int = Color.blue,
        c5: Int = Color.purple,
        vib: Int = 0
    ) -> String {
        pkt([
            0x83, 0x01, 0xE9, 0x09, 0x00, 0x2E, 0x0F,
            0xA0 | (c1 & 0x1F), 0xA0 | (c2 & 0x1F), 0xA0 | (c3 & 0x1F),
            0xA0 | (c4 & 0x1F), 0xA0 | (c5 & 0x1F), tail(vib: vib),
        ])
    }

    /// The seven pattern bytes of the circle body. Each decodes like every other colour byte: low
    /// 5 bits a palette index, high bits a slot flag (White, Off, Pink, Bright Purple, Yellow
    /// Orange, Bright Purple, Lime). Figment's rotating two-colour effect is this same shape.
    static let circlePattern: [Int] = [0x5C, 0x5D, 0x48, 0xA5, 0xD1, 0x45, 0x32]

    /// action=circle — rotating ring (E90B), default pattern colours.
    static func circle(vib: Int = 0) -> String { circle(colors: [], vib: vib) }

    /// Circle with the pattern bytes' palette indexes replaced; each byte keeps its own flag bits.
    static func circle(colors: [Int], vib: Int) -> String {
        var bytes: [Int] = [0x83, 0x01, 0xE9, 0x0B, 0x0B, 0x0F, 0x0F]
        for (i, b) in circlePattern.enumerated() {
            if i < colors.count {
                bytes.append((b & 0xE0) | (colors[i] & 0x1F))
            } else {
                bytes.append(b)
            }
        }
        bytes.append(tail(vib: vib))
        return pkt(bytes)
    }

    /// E912 "rotating colours": five per-zone colours the band rotates around its face. Template is
    /// the captured variant in the Flipper app; flag byte 0F selects rotate. Given in Z1..Z5 order;
    /// on air the bytes are Z2, Z3, Z4, Z5, Z1.
    static func rotate(_ z1: Int, _ z2: Int, _ z3: Int, _ z4: Int, _ z5: Int, vib: Int = 0) -> String {
        pkt([0x83, 0x01, 0xE1, 0x00, 0xE9, 0x12, 0x00, 0x03, 0x0F,
             0xA0 | (z2 & 0x1F), 0xA0 | (z3 & 0x1F), 0xA0 | (z4 & 0x1F), 0xA0 | (z5 & 0x1F), 0xA0 | (z1 & 0x1F),
             0x30, 0xD0, 0x37, 0xF4, 0xD2, 0x46, 0x00, 0x64, 0xFC, tail(vib: vib)])
    }

    /// Named values for the effect body's timing byte (body[1]). See docs/PROTOCOL.md §6a.
    enum Timing {
        /// Keep the template's own byte.
        static let `default` = -1
        static let alwaysOn = 0x8F
        static let s20 = 0x09
        static let s10 = 0x06
        static let s5 = 0x04
        static let s3 = 0x03
        static let options: [(Int, String)] = [(-1, "Default"), (0x8F, "Always on"), (0x09, "~20 s"), (0x06, "~10 s"), (0x04, "~5 s"), (0x03, "~3 s")]
    }

    /// Replace the timing byte (body[1]) of the first E9 record. No-op for `Timing.default`.
    static func withTiming(_ hex: String, _ timing: Int) -> String {
        if timing == Timing.default { return hex }
        guard let parsed = DisneyTlv.parse(hex), let e = parsed.effect else { return hex }
        if e.length < 2 { return hex }
        // Locate the record in the hex: "E9" + length byte, then body.
        let head = "E9" + DisneyTlv.hex2(e.declaredLength)
        let h = HexUtils.canonicalHex(hex)
        guard let found = h.range(of: head) else { return hex }
        let idx = h.distance(from: h.startIndex, to: found.lowerBound)
        let pos = idx + 4 + 2          // after head (4 chars) + body[0] (2 chars)
        var chars: [Character] = Array(h)
        if pos + 2 > chars.count { return hex }
        chars.replaceSubrange(pos..<(pos + 2), with: Array(DisneyTlv.hex2(timing)))
        return String(chars)
    }

    /// E908 custom RGB — six bits per channel (0-63), each shifted left one bit. From the Flipper
    /// app's builder; no captured example exists yet, so this is experimental.
    static func rgb(_ r6: Int, _ g6: Int, _ b6: Int, vib: Int = 0) -> String {
        pkt([0x83, 0x01, 0xE1, 0x00, 0xE9, 0x08, 0x00, 0x0E, 0xD2, 0x55,
             (r6 & 0x3F) << 1, (g6 & 0x3F) << 1, (b6 & 0x3F) << 1, tail(vib: vib)])
    }

    /// Set the zone mask (high 3 bits of the single-colour byte) on an E905 packet.
    static func withZoneMask(_ hex: String, _ mask: Int) -> String {
        let h = HexUtils.canonicalHex(hex)
        guard let r = h.range(of: "E905") else { return h }
        let pos = h.distance(from: h.startIndex, to: r.lowerBound) + 4 + 6   // body[3]
        guard pos + 2 <= h.count else { return h }
        var chars: [Character] = Array(h)
        guard let old = Int(String(chars[pos..<(pos + 2)]), radix: 16) else { return h }
        chars.replaceSubrange(pos..<(pos + 2), with: Array(DisneyTlv.hex2(((mask & 7) << 5) | (old & 0x1F))))
        return String(chars)
    }

    /// action=crossfade
    static func crossfade(c1: Int = Color.red, c2: Int = Color.blue, vib: Int = 0) -> String {
        pkt([
            0x83, 0x01, 0xE1, 0x00, 0xE9, 0x11, 0x00, 0x6F, 0x0F,
            0x40 | (c1 & 0x1F), 0x40 | (c2 & 0x1F),
            0x58, 0xF4, 0x48, 0x82, 0xD1, 0x46, 0x02, 0x08, 0xD0, 0x65, 0x00,
            tail(vib: vib),
        ])
    }

    /// Kotlin reads these numbers as 32-bit: anything wider is not a number there.
    private static func int32(fromHex text: String) -> Int? {
        guard let value = Int(text, radix: 16) else { return nil }
        if value < Int(Int32.min) || value > Int(Int32.max) { return nil }
        return value
    }

    /// A palette index from "#1B", a bare two-digit hex index, or a colour name. White when unknown.
    static func colorFromName(_ name: String) -> Int {
        let raw = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") {
            guard let value = int32(fromHex: String(raw.dropFirst())) else { return Color.white }
            return value & 0x1F
        }
        let hexOnly = raw.replacingOccurrences(of: " ", with: "").uppercased()
        if hexOnly.count == 2, let value = Int(hexOnly, radix: 16) {
            return value & 0x1F
        }
        let lowered = raw.lowercased()
        let key = lowered.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        switch key {
        case "red": return Color.red
        case "blue": return Color.blue
        case "cyan": return Color.cyan
        case "green": return Color.green
        case "purple": return Color.purple
        case "bright purple", "br purple", "brightpurple": return Color.brightPurple
        case "midnight blue", "mid blue", "midnightblue": return Color.midnightBlue
        case "lavender": return Color.lavender
        case "pink": return Color.pink
        case "white": return Color.white
        case "orange": return Color.orange
        case "yellow orange", "y orange", "yellow-orange", "yelloworange": return Color.yellowOrange
        case "lime": return Color.lime
        case "off": return Color.off
        case "random": return Color.random
        case "red orange", "red-orange": return Color.orange
        default:
            // Any other palette name; the lowest index wins when a name repeats.
            let palette = StarlightColors.palette
            for index in palette.keys.sorted() {
                if let paletteName = palette[index], paletteName.lowercased() == lowered {
                    return index
                }
            }
            return Color.white
        }
    }

    static func colorIndex(fromHex hex: String) -> Int? {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "").uppercased()
        guard clean.count == 6, let value = Int(clean, radix: 16) else { return nil }
        let r = (value >> 16) & 0xFF, g = (value >> 8) & 0xFF, b = value & 0xFF
        if r > 200 && g < 100 && b < 100 { return Color.red }
        if r < 80 && g < 120 && b > 180 { return Color.blue }
        if r < 80 && g > 180 && b > 180 { return Color.cyan }
        if r > 180 && g > 140 && b < 120 { return Color.yellowOrange }
        if r > 160 && g < 120 && b > 180 { return Color.lavender }
        if r > 180 && g < 100 && b > 180 { return Color.brightPurple }
        if r > 200 && g > 100 && b > 180 { return Color.pink }
        if r > 180 && g > 180 && b > 180 { return Color.white }
        if r > 120 && g > 180 && b < 100 { return Color.green }
        if r > 200 && g > 120 && b < 80 { return Color.orange }
        return Color.blue
    }
}
