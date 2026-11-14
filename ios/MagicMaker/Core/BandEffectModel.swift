import Foundation

/// What we expect a packet to do on a MagicBand+, derived from the bytes themselves via
/// `DisneyTlv`. Mirrors Android `BandEffectModel.kt` and drives the Lab's pinned band preview.
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
             alternate, repeatFade, lightning, strobe, stepper, complex, ping, wand, rgb,
             flicker, centrePulse, comet
    }

    let kind: Kind
    /// 5-bit palette indexes in packet slot order.
    let colors: [Int]
    /// Resting colour per zone Z1..Z5, nil = off.
    let perLed: [Int?]
    /// Tail-byte low nibble — the tail byte's meaning is disputed, see PROTOCOL.md.
    let buzz: Int
    /// Duration in ms from the timing byte, 0 = unknown; `alwaysOn` when bit 7 is set.
    let durationMs: Int
    let fadeMs: Int
    let alwaysOn: Bool
    let approximate: Bool
    let note: String
    /// E908 only: the 24-bit colour the packet asks for, scaled from 6-bit channels.
    var rgb: Int? = nil

    /// True when the packet is expected to light the band's LEDs. Wake pings, beacons, wand colours
    /// and show-control records with no known light are false — the Scan strip only follows these.
    var lightsBand: Bool { kind != Kind.none && kind != Kind.ping && kind != Kind.wand }

    static let off: [Int?] = [nil, nil, nil, nil, nil]
    static let empty = BandEffectModel(kind: .none, colors: [], perLed: off, buzz: 0, durationMs: 0, fadeMs: 0, alwaysOn: false, approximate: false, note: "No packet")

    private static func all(_ c: Int?) -> [Int?] { [c, c, c, c, c] }
    /// Centre (Z3) one colour, the four corners another.
    private static func centreCorners(_ centre: Int?, _ corners: Int?) -> [Int?] { [corners, corners, centre, corners, corners] }

    /// Body byte 1: bits 0-3 count, bit 6 ×3.1 s else ×1.5 s, bits 4-5 fade seconds, bit 7 always-on.
    static func timing(_ b: Int?) -> (durationMs: Int, fadeMs: Int, alwaysOn: Bool) {
        guard let b else { return (0, 0, false) }
        let count = b & 0x0F
        // Single-precision on purpose: Android does this in 32-bit floats and truncates, so
        // 3 × 3.1 s comes out as 9299 ms. Doubles would give 9300.
        let unit: Float = ((b >> 6) & 1) == 1 ? 3.1 : 1.5
        let secs: Float = Float(count) * unit
        let durationMs = Int(secs * 1000)
        let fadeMs = ((b >> 4) & 0x03) * 1000
        let alwaysOn = ((b >> 7) & 1) == 1
        return (durationMs, fadeMs, alwaysOn)
    }

    static func from(_ hexRaw: String) -> BandEffectModel {
        let hex = HexUtils.canonicalHex(hexRaw)
        if hex.count < 8 { return .empty }
        guard let parsed = DisneyTlv.parse(hex) else { return .empty }
        guard let first = parsed.records.first else { return .empty }

        guard let e = parsed.effect else {
            if first.type == DisneyTlv.typeWand {
                guard let last = first.byte(first.length - 1) else { return .empty }
                let c = last & 0x1F
                return BandEffectModel(kind: .wand, colors: [c], perLed: all(c), buzz: 0, durationMs: 0, fadeMs: 0, alwaysOn: false, approximate: false, note: "Wand colour")
            }
            if first.type == DisneyTlv.typePing {
                return BandEffectModel(kind: .ping, colors: [], perLed: off, buzz: 0, durationMs: 0, fadeMs: 0, alwaysOn: false, approximate: false, note: "Wake ping — no light")
            }
            return BandEffectModel(kind: .none, colors: [], perLed: off, buzz: 0, durationMs: 0, fadeMs: 0, alwaysOn: false, approximate: false, note: "No band effect known for this packet")
        }

        let tail = Int(e.value.last ?? 0)
        let buzz = (tail & 0xF0) == 0xB0 ? tail & 0x0F : 0
        let t = timing(e.byte(1))
        func pal(_ i: Int) -> Int? {
            guard let b = e.byte(i) else { return nil }
            return b & 0x1F
        }
        // The first `n` colour slots (body[3...]) that are actually present.
        func palette(_ n: Int) -> [Int] {
            var out: [Int] = []
            for i in 0..<n {
                if let c = pal(3 + i) { out.append(c) }
            }
            return out
        }
        func present(_ values: Int?...) -> [Int] { values.compactMap { $0 } }
        let body = e.valueHex()
        func model(_ kind: Kind, _ colors: [Int], _ perLed: [Int?], _ approx: Bool, _ note: String) -> BandEffectModel {
            BandEffectModel(kind: kind, colors: colors, perLed: perLed, buzz: buzz, durationMs: t.durationMs, fadeMs: t.fadeMs, alwaysOn: t.alwaysOn, approximate: approx, note: note)
        }

        switch e.declaredLength {
        case 0x05:
            let c = pal(3)
            // High 3 bits of the colour byte are a zone mask. Both public decoders agree on
            // 0 = all, 3 = bottom-left, 4 = top-left; they disagree on 1 and 2.
            let mask = (e.byte(3) ?? 0xE0) >> 5
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
            let note: String = allZones ? "Solid colour, all LEDs" : "Solid colour, zone mask \(mask) (mapping disputed)"
            return model(.single, present(c), leds, !allZones, note)
        case 0x06:
            return model(.dual, palette(2), centreCorners(pal(3), pal(4)), false, "Centre / corners")
        case 0x08:
            func ch(_ i: Int) -> Int { (((e.byte(i) ?? 0) >> 1) & 0x3F) * 255 / 63 }
            let rgb = (ch(4) << 16) | (ch(5) << 8) | ch(6)
            return BandEffectModel(kind: .rgb, colors: [], perLed: off, buzz: buzz, durationMs: t.durationMs, fadeMs: t.fadeMs,
                                   alwaysOn: t.alwaysOn, approximate: true, note: "Custom RGB — untested on a band", rgb: rgb)
        case 0x09:
            let zones: [Int?] = (0..<5).map { pal(3 + $0) }
            return model(.rainbow, palette(5), zones, true, "Five zone colours — slot→LED order disputed")
        case 0x0B:
            return model(.circle, palette(7), all(0x19), true, "Chase round the corners (\"green double comet\"); no public decoder reads colours from this body")
        case 0x0C:
            if body.contains("5D465B") && tail == 0x95 { return model(.lightning, [0x1B], all(0x1B), true, "White flash / fade") }
            if body.contains("5D465B") { return model(.rainbow, [0x15, 0x0F, 0x19, 0x02, 0x01], [0x15, 0x0F, 0x19, 0x02, 0x01], true, "Rainbow hue cycle") }
            if body.contains("4F4F5B") { return model(.strobe, [0x11, 0x13], all(0x11), true, "Yellow/orange strobe") }
            if body.contains("B1B9B5") { return model(.stepper, [0x15, 0x19, 0x11, 0x02], all(0x15), true, "Random palette stepper") }
            // Unnamed E90C: body[3], body[4] are still colour bytes; the motion is not decoded.
            if ((e.byte(3) ?? 0) >> 5) == 2 {
                let a = pal(3)
                let b = pal(4)
                return model(.complex, present(a, b), centreCorners(a, b), true, "Two-colour animation — motion not decoded")
            }
            return model(.complex, [], off, true, "Complex animation — bytes undecoded")
        case 0x0E:
            let zones: [Int?] = (0..<5).map { pal(3 + $0) }
            return model(.twinkle, palette(5), zones, true, "Per-zone twinkle / flash")
        case 0x0F:
            let centre = pal(3)
            let corners = pal(4)
            let cols = present(centre, corners)
            let mode: Int = e.byte(11) ?? -1
            if mode == 0x2A { return model(.flicker, cols, centreCorners(centre, corners), true, "Candle flicker: centre / corners") }
            if mode == 0x02 { return model(.centrePulse, cols, centreCorners(centre, corners), true, "Centre pulses, corners steady") }
            return model(.complex, cols, centreCorners(centre, corners), true, "E90F variant — mode not decoded")
        case 0x10:
            let c = pal(6)
            return model(.comet, present(c), all(c), true, "Comet chase round the corners")
        case 0x11:
            if body.contains("F44882") { return model(.crossfade, palette(2), centreCorners(pal(4), pal(3)), true, "Two-colour fade, centre out of phase") }
            return model(.pulseBurst, palette(2), centreCorners(pal(3), pal(4)), true, "Pulse burst: centre / corners")
        case 0x12:
            // Colour bytes are in zone order Z2, Z3, Z4, Z5, Z1.
            let leds: [Int?] = [pal(7), pal(3), pal(4), pal(5), pal(6)]
            let rotate = e.byte(2) == 0x0F
            return model(rotate ? .rotate : .toggle, palette(5), leds, true, rotate ? "Colours rotate around the band" : "Two-colour toggle")
        case 0x13:
            let leds: [Int?] = [pal(5), pal(4), pal(3), pal(5), pal(4)]
            return model(.alternate, palette(3), leds, true, "Corner pairs alternate, centre steady")
        case 0x14:
            let c = pal(8)
            return model(.repeatFade, present(c), all(c), true, "Repeating fade, all LEDs")
        default:
            return model(.none, [], off, false, "Show control — no band effect known")
        }
    }
}
