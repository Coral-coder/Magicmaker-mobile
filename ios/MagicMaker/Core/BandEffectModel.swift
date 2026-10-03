import Foundation

/// What we expect a packet to do on a MagicBand+, derived from the bytes. Mirrors Android
/// `BandEffectModel.kt` and drives the Lab's pinned band preview.
///
/// Honesty rule: `colors` are always exact — read from the colour bytes the protocol documents
/// (docs/PROTOCOL.md). Motion is exact where the shape implies it and a best guess where the
/// timing bytes are undecoded; `approximate` says which. Anything with no basis to render is
/// `.none` with a note, and the preview shows that rather than inventing an effect.
struct BandEffectModel: Equatable {
    enum Kind: String { case none, single, dual, rainbow, crossfade, circle, lightning, sparkle, strobe, complex, ping, wand }

    let kind: Kind
    /// 5-bit palette indexes, in slot order.
    let colors: [Int]
    /// Vibration pattern 0–15 from the B0|vib tail, 0 when none.
    let buzz: Int
    let approximate: Bool
    let note: String

    static let empty = BandEffectModel(kind: .none, colors: [], buzz: 0, approximate: false, note: "No packet")

    /// Minimal TLV walk: records after the 8301 company ID as (type, declaredLength, value).
    private static func records(_ bytes: [UInt8]) -> [(type: Int, declared: Int, value: [UInt8])] {
        guard bytes.count >= 2, bytes[0] == 0x83, bytes[1] == 0x01 else { return [] }
        var out: [(Int, Int, [UInt8])] = []
        var i = 2
        while i + 1 < bytes.count {
            let type = Int(bytes[i]), len = Int(bytes[i + 1])
            let start = i + 2
            if type == 0xCF && len == 0x9B {                        // legacy Starlight marker
                out.append((type, len, Array(bytes[start...]))); break
            }
            let end = min(start + len, bytes.count)
            out.append((type, len, Array(bytes[start..<end])))
            if start + len > bytes.count { break }                   // truncated final record
            i = start + len
        }
        return out
    }

    static func from(_ hexRaw: String) -> BandEffectModel {
        let hex = HexUtils.canonicalHex(hexRaw)
        guard hex.count >= 8 else { return .empty }
        let recs = records(HexUtils.hexToBytes(hex))
        guard let first = recs.first else { return .empty }
        let e = recs.first { $0.type == 0xE9 }

        guard let e else {
            if first.type == 0xCF, let last = first.value.last {
                return BandEffectModel(kind: .wand, colors: [Int(last) & 0x1F], buzz: 0, approximate: false, note: "Wand colour")
            }
            if first.type == 0xCC { return BandEffectModel(kind: .ping, colors: [], buzz: 0, approximate: false, note: "Wake ping — no light") }
            return BandEffectModel(kind: .none, colors: [], buzz: 0, approximate: false, note: "No band effect known for this packet")
        }

        let tail = Int(e.value.last ?? 0)
        let buzz = (tail & 0xF0) == 0xB0 ? tail & 0x0F : 0
        func palette(_ n: Int) -> [Int] { (0..<n).compactMap { e.value.indices.contains(3 + $0) ? Int(e.value[3 + $0]) & 0x1F : nil } }
        let body = HexUtils.bytesToHex(e.value)

        switch e.declared {
        case 0x05: return BandEffectModel(kind: .single, colors: palette(1), buzz: buzz, approximate: false, note: "Solid colour")
        case 0x06: return BandEffectModel(kind: .dual, colors: palette(2), buzz: buzz, approximate: false, note: "Inner / outer")
        case 0x09: return BandEffectModel(kind: .rainbow, colors: palette(5), buzz: buzz, approximate: false, note: "Five LED colours")
        case 0x0B: return BandEffectModel(kind: .circle, colors: palette(7), buzz: buzz, approximate: true, note: "Rotation speed/direction approximate")
        case 0x11:
            if body.contains("55515BF00F10374894D13D0508") {
                return BandEffectModel(kind: .complex, colors: [], buzz: buzz, approximate: true, note: "Pirate Cannon — motion approximate")
            }
            return BandEffectModel(kind: .crossfade, colors: palette(2), buzz: buzz, approximate: true, note: "Fade timing approximate")
        case 0x0C:
            if body.contains("5D465BF00532374895") { return BandEffectModel(kind: .lightning, colors: [0x1B], buzz: buzz, approximate: true, note: "Lightning — motion approximate") }
            if body.contains("5D465BF005323748B0") { return BandEffectModel(kind: .rainbow, colors: [0x15, 0x0F, 0x19, 0x02, 0x01], buzz: buzz, approximate: true, note: "Rainbow cycle — approximate") }
            if body.contains("B1B9B5B1A2307B7DB0") { return BandEffectModel(kind: .rainbow, colors: [0x11, 0x19, 0x15, 0x11, 0x02], buzz: buzz, approximate: true, note: "5-colour cycle — approximate") }
            return BandEffectModel(kind: .complex, colors: [], buzz: buzz, approximate: true, note: "Complex animation — bytes undecoded")
        case 0x0F:
            if body.contains("0219021902") || body.contains("1B151B15") {
                return BandEffectModel(kind: .sparkle, colors: [0x19, 0x02], buzz: buzz, approximate: true, note: "Sparkle — motion approximate")
            }
            return BandEffectModel(kind: .strobe, colors: [0x14, 0x14], buzz: buzz, approximate: true, note: "Alternating strobe — approximate")
        default:
            return BandEffectModel(kind: .none, colors: [], buzz: buzz, approximate: false, note: "Show control — no band effect known")
        }
    }
}
