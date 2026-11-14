import Foundation

/// Port of Android `core/MagicClassifier.kt` — keep the two in step.
enum MagicClassifier {
    private static let colorPalette: [Int: String] = PresetCatalog.starlightColorNames
    private static let showHexes: Set<String> = Set(PresetCatalog.showBlocks.values.map { $0.uppercased() })

    private static let classifyCacheMax = 1024

    /// Nil is a meaningful classify() result, so the cache stores it rather than re-deriving it.
    private struct Memo {
        let value: ClassifiedPacket?
    }

    /// Every caller is on the main thread, so the cache is a plain dictionary with no locking.
    /// It is emptied when full instead of evicting one entry at a time.
    private static var classifyCache: [String: Memo] = [:]

    /// classify() is pure: the same hex always yields the same result. It is also the single
    /// hottest function in the app — the scan path, the library writer, the automation matcher
    /// and every list row all call it, and a packet repeats hundreds of times a second while a
    /// wand is broadcasting. Memoize it so the TLV walk and the show-block scan run once per
    /// distinct packet instead of once per sighting.
    static func classify(_ hexRaw: String) -> ClassifiedPacket? {
        if let hit = classifyCache[hexRaw] {
            return hit.value
        }
        let result = classifyUncached(hexRaw)
        if classifyCache.count >= classifyCacheMax {
            classifyCache.removeAll(keepingCapacity: true)
        }
        classifyCache[hexRaw] = Memo(value: result)
        return result
    }

    private static func classifyUncached(_ hexRaw: String) -> ClassifiedPacket? {
        let hex = hexRaw.uppercased().filter { "0123456789ABCDEF".contains($0) }
        if !hex.hasPrefix("8301") && !hex.contains("CF9B") && !hex.contains("CF0B") { return nil }
        let normalized = hex.hasPrefix("8301") ? hex : "8301" + hex
        if normalized.count < 8 || normalized.count % 2 != 0 { return nil }

        if let star = classifyStarlight(normalized) { return star }

        if let entry = PresetCatalog.showBlocks.first(where: { $0.value.uppercased() == normalized }) {
            return ClassifiedPacket(
                hex: normalized, label: entry.key, category: .show,
                typeInfo: "show_block", colors: "", simKey: "SHOW:\(normalized)"
            )
        }

        // Walk the TLV chain instead of pattern-matching the hex. A ping is a CC record with no
        // effect record after it; an effect is an E9 record wherever it sits in the chain (with
        // or without a channel marker, with or without a wake-ping prefix); everything else is
        // judged by its leading record type.
        guard let parsed = DisneyTlv.parse(normalized) else { return nil }
        guard let first = parsed.records.first else { return nil }

        guard let effect = parsed.effect else {
            if first.type == DisneyTlv.typePing {
                let pingLabel = DisneyTlv.pingName(String(first.valueHex().prefix(6)))
                return ClassifiedPacket(
                    hex: normalized, label: pingLabel, category: .show,
                    typeInfo: "ping", colors: "", simKey: "PING:\(normalized)"
                )
            }
            return classifyEffectFamily(normalized, parsed, first)
        }

        return classifyEffect(normalized, effect)
    }

    /// E9 record → the colour / animation / show-control classification.
    private static func classifyEffect(_ normalized: String, _ e: DisneyTlv.Record) -> ClassifiedPacket {
        // "E9" + length byte — the four hex chars the rest of the app has always keyed on.
        let funcCode = e.headHex()
        let body = e.valueHex()
        // The old substring code took its signature windows from the "E9" onward; keep the
        // same windows so existing simKeys (and the automation rules built on them) still match.
        let fromHead = funcCode + body
        func palette(_ i: Int) -> Int { (e.byte(i) ?? 0) & 0x1F }
        func name(_ i: Int) -> String { StarlightColors.nameFor(palette(i)) }
        // The five zone colours at body[3...7].
        func zoneNames() -> String {
            var names: [String] = []
            for i in 3...7 {
                names.append(name(i))
            }
            return names.joined(separator: " / ")
        }

        let label: String
        let typeInfo: String
        let colors: String
        let simKey: String

        switch funcCode {
        case "E905":
            let colorIdx = palette(3)
            let colorName = colorPalette[colorIdx] ?? "Unknown"
            if colorName == "Off" {
                label = "Single Color: Off"
            } else {
                label = "Single Color: \(colorName)"
            }
            typeInfo = "single"
            colors = colorName
            simKey = "C1:" + DisneyTlv.hex2(colorIdx)
        case "E906":
            let c1 = palette(3)
            let c2 = palette(4)
            let n1 = colorPalette[c1] ?? "?"
            let n2 = colorPalette[c2] ?? "?"
            // First colour byte lights the centre LED, second the four corners.
            label = "Dual Color: \(n1) centre / \(n2) corners"
            typeInfo = "dual"
            colors = "\(n1) / \(n2)"
            let h1 = DisneyTlv.hex2(c1)
            let h2 = DisneyTlv.hex2(c2)
            simKey = "C2:\(h2):\(h1)"
        case "E90C":
            let lightning = body.contains("5D465BF00532374895")
            let rainbow = body.contains("5D465BF005323748B0")
            if lightning {
                label = "Animation: Lightning Pulse"
            } else if body.contains("B1B9B5B1A2307B7DB0") {
                label = "Animation: 5-Color Cycle"
            } else if rainbow {
                label = "Animation: Taste the Rainbow"
            } else {
                label = "Animation (E90C)"
            }
            typeInfo = "e90c"
            // body[3], body[4] are colour bytes (flag 010) in every E90C seen, park or public.
            if e.length >= 5 && ((e.byte(3) ?? 0) >> 5) == 2 {
                colors = "\(name(3)) / \(name(4))"
            } else {
                colors = ""
            }
            if lightning {
                simKey = "A:LIGHTNING"
            } else if rainbow {
                simKey = "A:RAINBOW"
            } else {
                simKey = "A:E90C:" + String(fromHead.prefix(20))
            }
        case "E90F":
            // Same template throughout; body[11] picks the mode (public listener: 2A candles,
            // 02 centre pulse). body[3] = centre colour, body[4] = corners.
            let mode: Int = e.byte(11) ?? -1
            if mode == 0x2A {
                label = "Candle Flicker (E90F)"
            } else if mode == 0x02 {
                label = "Centre Pulse (E90F)"
            } else {
                label = "Animation (E90F)"
            }
            typeInfo = "e90f"
            if e.length >= 5 {
                colors = "\(name(3)) centre / \(name(4)) corners"
            } else {
                colors = ""
            }
            simKey = "A:E90F:" + String(fromHead.prefix(16))
        case "E90B":
            label = "Effect: Circle"
            typeInfo = "e90b"
            colors = ""
            simKey = "A:CIRCLE"
        case "E909":
            label = "5-Zone Colors"
            typeInfo = "e909"
            colors = e.length >= 8 ? zoneNames() : ""
            simKey = "A:E909"
        case "E911":
            // The captured Pirate Cannon packet is exactly 17 body bytes and ends ...0508.
            // The old signature had a trailing B0 that no real packet carries.
            let pirate = body.contains("55515BF00F10374894D13D0508")
            // Fade from/to live at value[3]/value[4] — not "the byte before a trailing B0",
            // which two of the nine real E911 packets do not even have.
            let fade = "\(name(3)) / \(name(4))"
            typeInfo = "e911"
            if pirate {
                label = "Show: Pirate Cannon"
                colors = ""
                simKey = "A:PIRATE_CANNON"
            } else {
                label = "Cross-Fade: " + fade
                colors = fade
                simKey = "A:E911:" + String(normalized.suffix(4))
            }
        // Lengths other decoders have named (docs/PROTOCOL.md §6a). typeInfo/simKey stay the
        // same as before so stored library entries and automation rules keep matching.
        case "E908":
            label = "Custom RGB Color"
            typeInfo = "e908"
            colors = ""
            simKey = "S:" + funcCode
        case "E90E":
            label = "Twinkle / Flash (E90E)"
            typeInfo = "e90e"
            colors = e.length >= 8 ? zoneNames() : ""
            simKey = "S:" + funcCode
        // Public listener renders this template as a comet chase; body[6] is its colour.
        case "E910":
            label = "Comet (E910)"
            typeInfo = "e910"
            colors = e.length >= 7 ? name(6) : ""
            simKey = "S:" + funcCode
        case "E912":
            if e.byte(2) == 0x0F {
                label = "Rotating Colors (E912)"
            } else {
                label = "Two-Color Toggle (E912)"
            }
            typeInfo = "e912"
            colors = e.length >= 8 ? zoneNames() : ""
            simKey = "S:" + funcCode
        case "E913":
            label = "Corner Alternate (E913)"
            typeInfo = "e913"
            if e.length >= 6 {
                colors = "\(name(3)) centre, \(name(5)) / \(name(4))"
            } else {
                colors = ""
            }
            simKey = "S:" + funcCode
        case "E914":
            label = "Repeating Fade (E914)"
            typeInfo = "e914"
            colors = e.length >= 9 ? name(8) : ""
            simKey = "S:" + funcCode
        default:
            // A real E9 record whose body length we have no name for yet. It is show control
            // by construction — keep it, never drop it to "unknown".
            label = "Show Control: " + funcCode
            typeInfo = funcCode.lowercased()
            colors = ""
            simKey = "S:" + funcCode
        }

        let category = categorize(normalized, label: label, typeInfo: typeInfo)
        return ClassifiedPacket(
            hex: normalized, label: label, category: category,
            typeInfo: typeInfo, colors: colors, simKey: simKey
        )
    }

    /// No effect record: judge the packet by its leading record. Disney infrastructure uses
    /// 0xEx record types (E4/E5/EA/EF…) for beacons and cues — real transmissions even though we
    /// do not decode the action. Band telemetry (C0 / 0F) is not 0xEx and stays out of here.
    private static func classifyEffectFamily(
        _ normalized: String, _ parsed: DisneyTlv.Parsed, _ first: DisneyTlv.Record
    ) -> ClassifiedPacket? {
        if first.type < 0xE0 || first.type > 0xEF { return nil }
        let type = first.headHex()
        let simKey = "FX:\(normalized)"

        // EMCOT colour cue: an EF record with body 01 A6 <flag> <palette index>.
        func cueColor() -> String? {
            let found: DisneyTlv.Record? = parsed.records.first(where: { (r: DisneyTlv.Record) -> Bool in
                if r.type != 0xEF || r.declaredLength != 5 { return false }
                let b0: Int = r.byte(0) ?? -1
                let b1: Int = r.byte(1) ?? -1
                return b0 == 0x01 && b1 == 0xA6
            })
            guard let record = found, let index = record.byte(3) else { return nil }
            return StarlightColors.nameFor(index)
        }

        if type == "EF05" {
            let cue: String? = cueColor()
            var label = "Color Cue (EF05)"
            if let cue { label = "Color Cue: \(cue)" }
            return ClassifiedPacket(
                hex: normalized, label: label, category: .color,
                typeInfo: "fx_ef05", colors: cue ?? "", simKey: simKey
            )
        }
        if type == "EF08" {
            return ClassifiedPacket(
                hex: normalized, label: "Scene Cue (EF08)", category: .animation,
                typeInfo: "fx_ef08", colors: "", simKey: simKey
            )
        }
        if type == "E409" {
            let cue: String? = cueColor()
            var label = "Show Burst (E409)"
            if let cue { label = "Show Burst: \(cue)" }
            return ClassifiedPacket(
                hex: normalized, label: label, category: .animation,
                typeInfo: "fx_e409", colors: cue ?? "", simKey: simKey
            )
        }
        if type == "E501" {
            return ClassifiedPacket(
                hex: normalized, label: "Sync Cue (E501)", category: .animation,
                typeInfo: "fx_e501", colors: "", simKey: simKey
            )
        }
        if first.type == 0xEA {
            let style = String(type.dropFirst(2))
            return ClassifiedPacket(
                hex: normalized, label: "Animation (style \(style))", category: .animation,
                typeInfo: "fx_ea", colors: "", simKey: simKey
            )
        }
        return ClassifiedPacket(
            hex: normalized, label: "Effect \(type)", category: .animation,
            typeInfo: "effect", colors: "", simKey: simKey
        )
    }

    /// Offset of the Starlight marker — `CF9B` wherever it sits, else `CF0B` — or nil.
    private static func markerPosition(_ h: String) -> Int? {
        guard let found = h.range(of: "CF9B") ?? h.range(of: "CF0B") else { return nil }
        return h.distance(from: h.startIndex, to: found.lowerBound)
    }

    /// `chars[from..<to]` read as hex and masked to the 5-bit palette; 0 when out of range.
    private static func paletteAt(_ chars: [Character], _ from: Int, _ to: Int) -> Int {
        guard from >= 0, from < to, to <= chars.count else { return 0 }
        let value = Int(String(chars[from..<to]), radix: 16) ?? 0
        return value & 0x1F
    }

    /// The last byte as a palette index. A lone trailing nibble still parses; empty input is 0.
    private static func lastPalette(_ chars: [Character]) -> Int {
        paletteAt(chars, max(0, chars.count - 2), chars.count)
    }

    static func starlightColorIndex(_ hex: String) -> Int {
        let h = hex.uppercased().filter { "0123456789ABCDEF".contains($0) }
        let chars: [Character] = Array(h)
        let n = chars.count
        if h.contains("CC03000100CF9B") || h.contains("000000000000") {
            if h.hasSuffix("B0") && n >= 4 {
                return paletteAt(chars, n - 4, n - 2)
            }
            return lastPalette(chars)
        }
        if let markerPos = markerPosition(h) {
            var pos = markerPos + 4
            if pos + 2 <= n && chars[pos] == "0" && chars[pos + 1] == "0" { pos += 2 }
            let colorPos = pos + StarlightSerial.serialHexLen
            if colorPos + 2 <= n {
                return paletteAt(chars, colorPos, colorPos + 2)
            }
            // Truncated ADV: color byte is still the last payload byte.
            if n >= pos + 4 {
                return lastPalette(chars)
            }
        }
        if h.hasSuffix("B0") && n >= 4 {
            return paletteAt(chars, n - 4, n - 2)
        }
        return lastPalette(chars)
    }

    /// Best-effort color index for learning — accepts short ADV when marker + color byte are present.
    static func starlightLearnColorIndex(_ hex: String) -> Int? {
        let h = HexUtils.canonicalHex(hex)
        if !HexUtils.isStarlightPacket(h) { return nil }
        guard let markerPos = markerPosition(h) else { return nil }
        let chars: [Character] = Array(h)
        let n = chars.count
        var pos = markerPos + 4
        if pos + 2 <= n && chars[pos] == "0" && chars[pos + 1] == "0" { pos += 2 }
        if n >= pos + StarlightSerial.serialHexLen + 2 {
            return starlightColorIndex(h)
        }
        if h.contains("CC03000100CF9B") || h.contains("000000000000") {
            return starlightColorIndex(h)
        }
        if n >= pos + 4 {
            return lastPalette(chars)
        }
        return nil
    }

    /// Pick a hex that fits in BLE ADV — use heard payload when valid, else built-in template.
    static func starlightTxHex(_ rawHex: String) -> String {
        let canonical = HexUtils.canonicalHex(rawHex)
        let colorIdx = starlightLearnColorIndex(canonical) ?? starlightColorIndex(canonical)
        if HexUtils.legacyAdvertiseRejectReason(canonical) == nil { return canonical }
        return PresetCatalog.legacyStarlightHex(colorIndex: colorIdx)
    }

    private static func classifyStarlight(_ hex: String) -> ClassifiedPacket? {
        if !hex.contains("CF9B") && !hex.contains("CF0B") { return nil }
        let canonical = HexUtils.canonicalHex(hex)
        let colorIdx = starlightColorIndex(canonical)
        let name = StarlightColors.nameFor(colorIdx)
        let txHex = starlightTxHex(canonical)
        let code = DisneyTlv.hex2(colorIdx)
        return ClassifiedPacket(
            hex: txHex,
            label: "Starlight: \(name) (#\(code))",
            category: .color,
            typeInfo: "starlight",
            colors: name,
            simKey: PresetCatalog.starlightSimKey(colorIdx)
        )
    }

    private static func categorize(_ hex: String, label: String, typeInfo: String) -> MagicCategory {
        if typeInfo == "starlight" || typeInfo == "single" || typeInfo == "dual" { return .color }
        if showHexes.contains(hex) || label.hasPrefix("Show:") || typeInfo.hasPrefix("e90") {
            if typeInfo.hasPrefix("e90") && typeInfo != "e90e" && typeInfo != "e908" && typeInfo != "e909" {
                return .animation
            }
            if label.range(of: "Show Control", options: .caseInsensitive) != nil || showHexes.contains(hex) {
                return .show
            }
            return .animation
        }
        switch typeInfo {
        case "e90c", "e90f", "e911", "e90b", "e909": return .animation
        case "e90e", "e908", "ping": return .show
        default: return .animation
        }
    }

    /// Human label for an unclassified packet — its full hex (distinct packets stay distinct).
    static func rawLabel(_ hexRaw: String) -> String {
        let h = HexUtils.canonicalHex(hexRaw)
        if h.count <= 24 { return "Raw: \(h)" }
        let head = String(h.prefix(18))
        let tail = String(h.suffix(4))
        return "Raw: \(head)…\(tail)"
    }

    /// Identity used to group packets in the library / analyzed view: the full canonical hex,
    /// so every distinct packet is kept separate (classified packets use their normalized hex).
    static func groupKey(_ hexRaw: String) -> String {
        if let c = classify(hexRaw) {
            return HexUtils.canonicalHex(c.hex)
        }
        return HexUtils.canonicalHex(hexRaw)
    }

    /// Display label for `groupKey` — the classification when known, else the raw hex.
    static func groupLabel(_ hexRaw: String) -> String {
        classify(hexRaw)?.label ?? rawLabel(hexRaw)
    }

    /// Packets we never auto-save to the library: guest MagicBand telemetry (8301C0…, every
    /// nearby band broadcasts these with rolling payloads) and interaction/wakeup pings. Both
    /// are high-volume background noise, not controllable effects.
    static func isLibraryNoise(_ hexRaw: String) -> Bool {
        let h = HexUtils.canonicalHex(hexRaw)
        if h.hasPrefix("8301C0") { return true }       // guest MagicBand telemetry
        if h.hasPrefix("83010F11") { return true }     // rolling per-band ID broadcasts
        // Ping is TLV type 0xCC at the head — no need to run a full classify() for it.
        return h.hasPrefix("8301CC03")
    }

    /// Strict "is this a real, band/wand-controllable show-control packet" test: interaction pings,
    /// E9 effect records, Starlight/New Wand, and known show blocks. Deliberately EXCLUDES the
    /// classifyEffectFamily beacon families (EA/EF/E4/E5…) — those are stationary park infrastructure
    /// beacons that never animate a band, so treating them as show control just clutters the library.
    static func isShowControl(_ hexRaw: String) -> Bool {
        let h = HexUtils.canonicalHex(hexRaw)
        if h.hasPrefix("8301CC03") { return true }
        if h.contains("CF9B") || h.contains("CF0B") { return true }
        // An E9 record anywhere in the chain — with or without a channel marker in front of it.
        if let parsed = DisneyTlv.parse(h), parsed.has(DisneyTlv.typeEffect) { return true }
        return showHexes.contains(h)
    }

    static func libraryDedupeKey(_ classified: ClassifiedPacket) -> String {
        switch classified.typeInfo {
        case "starlight", "single", "dual", "show_block": return classified.simKey
        case "ping": return "FUNC:ping"
        case "e90f": return "FUNC:e90f"
        case "e908", "e909", "e90e": return "FUNC:\(classified.typeInfo)"
        case "e90c": return classified.simKey.hasPrefix("A:") ? classified.simKey : "FUNC:e90c"
        case "e911": return classified.simKey.hasPrefix("A:") ? classified.simKey : "FUNC:e911"
        default: return classified.simKey.isEmpty ? "FUNC:\(classified.typeInfo)" : classified.simKey
        }
    }
}
