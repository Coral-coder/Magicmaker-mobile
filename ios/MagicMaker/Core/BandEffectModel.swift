import Foundation

/// What we expect a packet to do on a MagicBand+, derived from the bytes. Mirrors Android
/// `BandEffectModel.kt` and drives the Lab's pinned band preview.
///
/// The band has five LEDs — one at each corner of its square face and one in the centre. Zones
/// follow the numbering the public ESP32 listener uses (docs/PROTOCOL.md §6a):
/// Z1 bottom-left · Z2 top-left · Z3 centre · Z4 top-right · Z5 bottom-right.
///
/// `perLed` is the resting colour of each zone (index 0 = Z1 … 4 = Z5), nil = off. Colours are
/// exact; motion and some LED orders are reproduced from other people's decoders and marked
/// `approximate`. Anything with no basis is `.none` with a note — never an invented effect.
struct BandEffectModel: Equatable {
    enum Kind: String {
        case none, single, dual, rainbow, crossfade, pulseBurst, circle, rotate, toggle, twinkle,
             alternate, repeatFade, lightning, strobe, stepper, complex, ping, wand, rgb
    }

    let kind: Kind
    /// 5-bit palette indexes in packet slot order.
    let colors: [Int]
    /// Resting colour per zone Z1..Z5, nil = off.
    let perLed: [Int?]
    /// Tail-byte low nibble — the tail byte's meaning is disputed, see PROTOCOL.md.
    let buzz: Int
    let durationMs: Int
    let fadeMs: Int
    let alwaysOn: Bool
    let approximate: Bool
    let note: String

    static let off: [Int?] = [nil, nil, nil, nil, nil]
    static let empty = BandEffectModel(kind: .none, colors: [], perLed: off, buzz: 0, durationMs: 0, fadeMs: 0, alwaysOn: false, approximate: false, note: "No packet")

    private static func all(_ c: Int?) -> [Int?] { [c, c, c, c, c] }
    private static func centreCorners(_ centre: Int?, _ corners: Int?) -> [Int?] { [corners, corners, centre, corners, corners] }

    /// Minimal TLV walk: records after the 8301 company ID as (type, declaredLength, value).
    private static func records(_ bytes: [UInt8]) -> [(type: Int, declared: Int, value: [UInt8])] {
        guard bytes.count >= 2, bytes[0] == 0x83, bytes[1] == 0x01 else { return [] }
        var out: [(Int, Int, [UInt8])] = []
        var i = 2
        while i + 1 < bytes.count {
            let type = Int(bytes[i]), len = Int(bytes[i + 1])
            let start = i + 2
            if type == 0xCF && len == 0x9B { out.append((type, len, Array(bytes[start...]))); break }
            let end = min(start + len, bytes.count)
            out.append((type, len, Array(bytes[start..<end])))
            if start + len > bytes.count { break }
            i = start + len
        }
        return out
    }

    /// Body byte 1: bits 0-3 count, bit 6 ×3.1 s else ×1.5 s, bits 4-5 fade seconds, bit 7 always-on.
    static func timing(_ b: Int?) -> (durationMs: Int, fadeMs: Int, alwaysOn: Bool) {
        guard let b else { return (0, 0, false) }
        let secs = Double(b & 0x0F) * (((b >> 6) & 1) == 1 ? 3.1 : 1.5)
        return (Int(secs * 1000), ((b >> 4) & 0x03) * 1000, ((b >> 7) & 1) == 1)
    }

    static func from(_ hexRaw: String) -> BandEffectModel {
        let hex = HexUtils.canonicalHex(hexRaw)
        guard hex.count >= 8 else { return .empty }
        let recs = records(HexUtils.hexToBytes(hex))
        guard let first = recs.first else { return .empty }
        let e = recs.first { $0.type == 0xE9 }

        guard let e else {
            if first.type == 0xCF, let last = first.value.last {
                let c = Int(last) & 0x1F
                return BandEffectModel(kind: .wand, colors: [c], perLed: all(c), buzz: 0, durationMs: 0, fadeMs: 0, alwaysOn: false, approximate: false, note: "Wand colour")
            }
            if first.type == 0xCC { return BandEffectModel(kind: .ping, colors: [], perLed: off, buzz: 0, durationMs: 0, fadeMs: 0, alwaysOn: false, approximate: false, note: "Wake ping — no light") }
            return BandEffectModel(kind: .none, colors: [], perLed: off, buzz: 0, durationMs: 0, fadeMs: 0, alwaysOn: false, approximate: false, note: "No band effect known for this packet")
        }

        let tail = Int(e.value.last ?? 0)
        let buzz = (tail & 0xF0) == 0xB0 ? tail & 0x0F : 0
        let t = timing(e.value.count > 1 ? Int(e.value[1]) : nil)
        func pal(_ i: Int) -> Int? { e.value.indices.contains(i) ? Int(e.value[i]) & 0x1F : nil }
        func palette(_ n: Int) -> [Int] { (0..<n).compactMap { pal(3 + $0) } }
        let body = HexUtils.bytesToHex(e.value)
        func model(_ kind: Kind, _ colors: [Int], _ perLed: [Int?], _ approx: Bool, _ note: String) -> BandEffectModel {
            BandEffectModel(kind: kind, colors: colors, perLed: perLed, buzz: buzz, durationMs: t.durationMs, fadeMs: t.fadeMs, alwaysOn: t.alwaysOn, approximate: approx, note: note)
        }

        switch e.declared {
        case 0x05:
            let c = pal(3)
            let mask = (e.value.count > 3 ? Int(e.value[3]) : 0xE0) >> 5
            let leds: [Int?]
            switch mask {
            case 0, 5, 7: leds = all(c)
            case 3: leds = [c, nil, nil, nil, nil]
            case 4: leds = [nil, c, nil, nil, nil]
            case 1, 6: leds = [nil, nil, c, nil, nil]
            case 2: leds = [nil, nil, nil, c, nil]
            default: leds = all(c)
            }
            let allZones = mask == 0 || mask == 7
            return model(.single, c.map { [$0] } ?? [], leds, !allZones, allZones ? "Solid colour, all LEDs" : "Solid colour, zone mask \(mask) (mapping disputed)")
        case 0x06: return model(.dual, palette(2), centreCorners(pal(3), pal(4)), false, "Centre / corners")
        case 0x08: return model(.rgb, [], off, true, "Custom RGB (6-bit per channel) — colour shown approximately")
        case 0x09: return model(.rainbow, palette(5), (0..<5).map { pal(3 + $0) }, true, "One colour per LED — slot→LED order disputed")
        case 0x0B: return model(.circle, palette(7), all(0x19), true, "Chase round the corners (\"green double comet\"); no public decoder reads colours from this body")
        case 0x0C:
            if body.contains("5D465B") && tail == 0x95 { return model(.lightning, [0x1B], all(0x1B), true, "White flash / fade") }
            if body.contains("5D465B") { return model(.rainbow, [0x15, 0x0F, 0x19, 0x02, 0x01], [0x15, 0x0F, 0x19, 0x02, 0x01], true, "Rainbow hue cycle") }
            if body.contains("4F4F5B") { return model(.strobe, [0x11, 0x13], all(0x11), true, "Yellow/orange strobe") }
            if body.contains("B1B9B5") { return model(.stepper, [0x15, 0x19, 0x11, 0x02], all(0x15), true, "Random palette stepper") }
            return model(.complex, [], off, true, "Complex animation — bytes undecoded")
        case 0x0E: return model(.twinkle, palette(5), (0..<5).map { pal(3 + $0) }, true, "Per-zone twinkle / flash")
        case 0x0F: return model(.complex, [], all(0x02), true, "Candles / centre pulse — signature-matched")
        case 0x10: return model(.complex, [], all(0x13), true, "Alternating — signature-matched")
        case 0x11:
            if body.contains("F44882") { return model(.crossfade, palette(2), centreCorners(pal(4), pal(3)), true, "Two-colour fade, centre out of phase") }
            return model(.pulseBurst, palette(2), centreCorners(pal(3), pal(4)), true, "Pulse burst: centre / corners")
        case 0x12:
            let raw = (0..<5).map { pal(3 + $0) }
            let leds = [raw[4], raw[0], raw[1], raw[2], raw[3]]
            let rotate = e.value.count > 2 && e.value[2] == 0x0F
            return model(rotate ? .rotate : .toggle, palette(5), leds, true, rotate ? "Colours rotate around the band" : "Two-colour toggle")
        case 0x13: return model(.alternate, palette(3), [pal(5), pal(4), pal(3), pal(5), pal(4)], true, "Corner pairs alternate, centre steady")
        case 0x14:
            let c = pal(8)
            return model(.repeatFade, c.map { [$0] } ?? [], all(c), true, "Repeating fade, all LEDs")
        default:
            return model(.none, [], off, false, "Show control — no band effect known")
        }
    }
}
