import Foundation

/// Disney MagicBand+ packet builders — mirrors Android `PacketBuilder.kt` / esp32_magicband.
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

    enum Vibration {
        static let off = 0
        static let short = 1
        static let double = 2
        static let triple = 3
        static let burst = 5
        static let long = 8
    }

    static let wakeupPing = "8301CC03000100"
    static let rainbowFinale = "8301CC03000100E100E90C000F0F5D465BF005323748B0"

    private static func pkt(_ bytes: [Int]) -> String {
        bytes.map { String(format: "%02X", $0 & 0xFF) }.joined()
    }

    private static func tail(vib: Int) -> Int { 0xB0 | (vib & 0x0F) }

    static func preset(color: Int, vib: Int = 0) -> String {
        pkt([0x83, 0x01, 0xE9, 0x05, 0x00, 0x2E, 0x0E, 0xE0 | (color & 0x1F), tail(vib: vib)])
    }

    static func vibrateBand(vib: Int = Vibration.burst) -> String {
        preset(color: Color.white, vib: vib)
    }

    static func dual(_ c1: Int, _ c2: Int, vib: Int = 0) -> String {
        pkt([0x83, 0x01, 0xE9, 0x06, 0x00, 0x22, 0x0F, 0x80 | (c1 & 0x1F), 0x80 | (c2 & 0x1F), tail(vib: vib)])
    }

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
    static let circlePattern = [0x5C, 0x5D, 0x48, 0xA5, 0xD1, 0x45, 0x32]

    static func circle(vib: Int = 0) -> String { circle(colors: [], vib: vib) }

    /// Circle with the pattern bytes' palette indexes replaced; each byte keeps its own flag bits.
    static func circle(colors: [Int], vib: Int) -> String {
        let pattern = circlePattern.enumerated().map { i, b in
            colors.indices.contains(i) ? (b & 0xE0) | (colors[i] & 0x1F) : b
        }
        return pkt([0x83, 0x01, 0xE9, 0x0B, 0x0B, 0x0F, 0x0F] + pattern + [tail(vib: vib)])
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
        static let `default` = -1
        static let alwaysOn = 0x8F
        static let options: [(Int, String)] = [(-1, "Default"), (0x8F, "Always on"), (0x09, "~20 s"), (0x06, "~10 s"), (0x04, "~5 s"), (0x03, "~3 s")]
    }

    /// Replace the timing byte (body[1]) of the first E9 record. No-op for `Timing.default`.
    static func withTiming(_ hex: String, _ timing: Int) -> String {
        guard timing != Timing.default else { return hex }
        let h = HexUtils.canonicalHex(hex)
        guard let r = h.range(of: "E9"), h.distance(from: r.upperBound, to: h.endIndex) >= 6 else { return hex }
        // "E9" + len (2) + body[0] (2) → body[1] starts 6 chars after the "E9" start.
        let start = h.index(r.lowerBound, offsetBy: 6)
        let end = h.index(start, offsetBy: 2)
        return h.replacingCharacters(in: start..<end, with: String(format: "%02X", timing & 0xFF))
    }

    static func crossfade(c1: Int = Color.red, c2: Int = Color.blue, vib: Int = 0) -> String {
        pkt([
            0x83, 0x01, 0xE1, 0x00, 0xE9, 0x11, 0x00, 0x6F, 0x0F,
            0x40 | (c1 & 0x1F), 0x40 | (c2 & 0x1F),
            0x58, 0xF4, 0x48, 0x82, 0xD1, 0x46, 0x02, 0x08, 0xD0, 0x65, 0x00,
            tail(vib: vib),
        ])
    }

    static func colorFromName(_ name: String) -> Int {
        let raw = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") {
            return Int(raw.dropFirst(), radix: 16).map { $0 & 0x1F } ?? Color.white
        }
        let hexOnly = raw.replacingOccurrences(of: " ", with: "").uppercased()
        if hexOnly.count == 2, let value = Int(hexOnly, radix: 16) {
            return value & 0x1F
        }
        switch raw.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ") {
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
            if let match = PresetCatalog.starlightColorNames.first(where: { $0.value.caseInsensitiveCompare(raw) == .orderedSame }) {
                return match.key
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
