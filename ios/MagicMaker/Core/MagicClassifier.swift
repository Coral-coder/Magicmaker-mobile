import Foundation

enum MagicClassifier {
    private static let colorPalette = PresetCatalog.starlightColorNames
    private static let showHexes = Set(PresetCatalog.showBlocks.values.map { $0.uppercased() })

    static func classify(_ hexRaw: String) -> ClassifiedPacket? {
        let hex = hexRaw.uppercased().filter { "0123456789ABCDEF".contains($0) }
        guard hex.hasPrefix("8301") || hex.contains("CF9B") || hex.contains("CF0B") else { return nil }
        let normalized = hex.hasPrefix("8301") ? hex : "8301" + hex
        guard normalized.count >= 8, normalized.count % 2 == 0 else { return nil }

        if let star = classifyStarlight(normalized) { return star }

        if let entry = PresetCatalog.showBlocks.first(where: { $0.value.uppercased() == normalized }) {
            return ClassifiedPacket(hex: normalized, label: entry.key, category: .show, typeInfo: "show_block", colors: "", simKey: "SHOW:\(normalized)")
        }

        if normalized.hasPrefix("8301CC03") {
            let pingLabel = normalized == "8301CC03000100" ? "Interaction Ping (Fast Mode)" : "Interaction Ping"
            return ClassifiedPacket(hex: normalized, label: pingLabel, category: .show, typeInfo: "ping", colors: "", simKey: "PING:\(normalized)")
        }

        // Effect/show commands carry an E?00E9xx prelude (a channel byte, then 00, then the E9
        // function code). Requiring this structure rejects MagicBand/device telemetry that merely
        // contains a stray "E9" byte — the source of most bogus "unknown" and misclassified packets.
        guard let prelude = normalized.range(of: "E[0-9A-F]00E9", options: .regularExpression) else { return nil }
        let pos = normalized.distance(from: normalized.startIndex, to: prelude.upperBound) - 2
        let funcCode = String(normalized[normalized.index(normalized.startIndex, offsetBy: pos)..<normalized.index(normalized.startIndex, offsetBy: min(pos + 4, normalized.count))])

        let label: String
        let typeInfo: String
        let colors: String
        let simKey: String

        // Body byte i of the E9 record sits 4 + 2i hex chars after the "E9" + length head.
        func bodyByte(_ i: Int) -> Int? {
            let o = pos + 4 + i * 2
            guard o + 2 <= normalized.count else { return nil }
            let a = normalized.index(normalized.startIndex, offsetBy: o)
            return Int(normalized[a..<normalized.index(a, offsetBy: 2)], radix: 16)
        }
        func name(_ i: Int) -> String { colorPalette[(bodyByte(i) ?? 0) & 0x1F] ?? "?" }
        let head = String(normalized[normalized.index(normalized.startIndex, offsetBy: pos)...])

        switch funcCode {
        case "E905":
            let colorIdx = (bodyByte(3) ?? 0) & 0x1F
            let n = colorPalette[colorIdx] ?? "Unknown"
            label = n == "Off" ? "Single Color: Off" : "Single Color: \(n)"
            typeInfo = "single"
            colors = n
            simKey = "C1:\(String(format: "%02X", colorIdx))"
        case "E906":
            // First colour byte lights the centre LED, second the four corners.
            let c1 = (bodyByte(3) ?? 0) & 0x1F, c2 = (bodyByte(4) ?? 0) & 0x1F
            label = "Dual Color: \(name(3)) centre / \(name(4)) corners"
            typeInfo = "dual"
            colors = "\(name(3)) / \(name(4))"
            simKey = "C2:\(String(format: "%02X", c2)):\(String(format: "%02X", c1))"
        case "E90C":
            if head.contains("5D465BF00532374895") { label = "Animation: Lightning Pulse" }
            else if head.contains("B1B9B5B1A2307B7DB0") { label = "Animation: 5-Color Cycle" }
            else if head.contains("5D465BF005323748B0") { label = "Animation: Taste the Rainbow" }
            else { label = "Animation (E90C)" }
            typeInfo = "e90c"
            colors = ((bodyByte(3) ?? 0) >> 5) == 2 ? "\(name(3)) / \(name(4))" : ""
            simKey = head.contains("5D465BF00532374895") ? "A:LIGHTNING"
                : head.contains("5D465BF005323748B0") ? "A:RAINBOW" : "A:E90C:\(head.prefix(20))"
        case "E90F":
            switch bodyByte(11) ?? -1 {
            case 0x2A: label = "Candle Flicker (E90F)"
            case 0x02: label = "Centre Pulse (E90F)"
            default: label = "Animation (E90F)"
            }
            typeInfo = "e90f"
            colors = "\(name(3)) centre / \(name(4)) corners"
            simKey = "A:E90F:\(head.prefix(16))"
        case "E90B":
            label = "Effect: Circle"; typeInfo = "e90b"; colors = ""; simKey = "A:CIRCLE"
        case "E909":
            label = "5-Zone Colors"; typeInfo = "e909"
            colors = (3...7).map { name($0) }.joined(separator: " / ")
            simKey = "A:E909"
        case "E910":
            label = "Comet (E910)"; typeInfo = "e910"; colors = name(6); simKey = "S:\(funcCode)"
        case "E911":
            let pirate = head.contains("55515BF00F10374894D13D0508")
            label = pirate ? "Show: Pirate Cannon" : "Cross-Fade: \(name(3)) / \(name(4))"
            typeInfo = "e911"
            colors = pirate ? "" : "\(name(3)) / \(name(4))"
            simKey = pirate ? "A:PIRATE_CANNON" : "A:E911:\(normalized.suffix(4))"
        case "E90E":
            label = "Twinkle / Flash (E90E)"; typeInfo = "e90e"
            colors = (3...7).map { name($0) }.joined(separator: " / ")
            simKey = "S:\(funcCode)"
        case "E912":
            label = bodyByte(2) == 0x0F ? "Rotating Colors (E912)" : "Two-Color Toggle (E912)"
            typeInfo = "e912"; colors = (3...7).map { name($0) }.joined(separator: " / "); simKey = "S:\(funcCode)"
        case "E913":
            label = "Corner Alternate (E913)"; typeInfo = "e913"
            colors = "\(name(3)) centre, \(name(5)) / \(name(4))"; simKey = "S:\(funcCode)"
        case "E914":
            label = "Repeating Fade (E914)"; typeInfo = "e914"; colors = name(8); simKey = "S:\(funcCode)"
        case "E908":
            label = "Custom RGB Color"; typeInfo = "e908"; colors = ""; simKey = "S:\(funcCode)"
        default:
            // A real E9 record with a length we have no name for yet. Keep it as show control
            // instead of dropping it to "unknown".
            label = "Show Control: \(funcCode)"
            typeInfo = funcCode.lowercased()
            colors = ""
            simKey = "S:\(funcCode)"
        }

        let category = categorize(normalized, label: label, typeInfo: typeInfo)
        return ClassifiedPacket(hex: normalized, label: label, category: category, typeInfo: typeInfo, colors: colors, simKey: simKey)
    }

    /** Best-effort color index for learning — accepts short ADV when marker + color byte are present. */
    static func starlightLearnColorIndex(_ hex: String) -> Int? {
        let h = HexUtils.canonicalHex(hex)
        guard HexUtils.isStarlightPacket(h) else { return nil }
        guard let cf9bPos = h.range(of: "CF9B")?.lowerBound ?? h.range(of: "CF0B")?.lowerBound else { return nil }
        var pos = h.distance(from: h.startIndex, to: cf9bPos) + 4
        let chars = Array(h)
        if pos + 2 <= chars.count, String(chars[pos..<(pos + 2)]) == "00" { pos += 2 }
        if pos + StarlightSerial.serialHexLen + 2 <= chars.count {
            return starlightColorIndex(h)
        }
        if h.contains("CC03000100CF9B") || h.contains("000000000000") {
            return starlightColorIndex(h)
        }
        if chars.count >= pos + 4 {
            return Int(String(chars.suffix(2)), radix: 16).map { $0 & 0x1F }
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

    static func starlightColorIndex(_ hex: String) -> Int {
        let h = hex.uppercased().filter { "0123456789ABCDEF".contains($0) }
        if h.contains("CC03000100CF9B") || h.contains("000000000000") {
            if h.hasSuffix("B0"), h.count >= 4 {
                return Int(h[h.index(h.endIndex, offsetBy: -4)..<h.index(h.endIndex, offsetBy: -2)], radix: 16)! & 0x1F
            }
            return Int(h.suffix(2), radix: 16)! & 0x1F
        }
        if let cf9bPos = h.range(of: "CF9B")?.lowerBound ?? h.range(of: "CF0B")?.lowerBound {
            var pos = h.distance(from: h.startIndex, to: cf9bPos) + 4
            let chars = Array(h)
            if pos + 2 <= chars.count, String(chars[pos..<(pos + 2)]) == "00" { pos += 2 }
            if pos + 24 <= chars.count {
                return Int(String(chars[(pos + 22)..<(pos + 24)]), radix: 16)! & 0x1F
            }
            if chars.count >= pos + 4 {
                return Int(String(chars.suffix(2)), radix: 16)! & 0x1F
            }
        }
        if h.hasSuffix("B0"), h.count >= 4 {
            return Int(h[h.index(h.endIndex, offsetBy: -4)..<h.index(h.endIndex, offsetBy: -2)], radix: 16)! & 0x1F
        }
        return Int(h.suffix(2), radix: 16)! & 0x1F
    }

    private static func classifyStarlight(_ hex: String) -> ClassifiedPacket? {
        guard hex.contains("CF9B") || hex.contains("CF0B") else { return nil }
        let colorIdx = starlightColorIndex(hex)
        let name = colorPalette[colorIdx] ?? "Unknown"
        let replayHex = starlightTxHex(hex)
        return ClassifiedPacket(
            hex: replayHex,
            label: "Starlight: \(name) (#\(String(format: "%02X", colorIdx)))",
            category: .color,
            typeInfo: "starlight",
            colors: name,
            simKey: PresetCatalog.starlightSimKey(colorIdx)
        )
    }

    private static func extractE905Color(_ hex: String, pos: Int) -> Int {
        if hex.hasSuffix("B0"), hex.count >= 4 {
            return Int(hex[hex.index(hex.endIndex, offsetBy: -4)..<hex.index(hex.endIndex, offsetBy: -2)], radix: 16)! & 0x1F
        }
        if hex.count >= pos + 12 {
            return Int(hex[hex.index(hex.startIndex, offsetBy: pos + 10)..<hex.index(hex.startIndex, offsetBy: pos + 12)], radix: 16)! & 0x1F
        }
        return 0
    }

    private static func extractFadeColor(_ hex: String) -> String {
        guard hex.hasSuffix("B0"), hex.count >= 4 else { return "" }
        let byte = Int(hex[hex.index(hex.endIndex, offsetBy: -4)..<hex.index(hex.endIndex, offsetBy: -2)], radix: 16)! & 0x1F
        return colorPalette[byte] ?? ""
    }

    private static func categorize(_ hex: String, label: String, typeInfo: String) -> MagicCategory {
        if ["starlight", "single", "dual"].contains(typeInfo) { return .color }
        if showHexes.contains(hex) || label.hasPrefix("Show:") || typeInfo.hasPrefix("e90") {
            if typeInfo.hasPrefix("e90"), !["e90e", "e908", "e909"].contains(typeInfo) {
                return .animation
            }
            if label.localizedCaseInsensitiveContains("Show Control") || showHexes.contains(hex) {
                return .show
            }
            return .animation
        }
        switch typeInfo {
        case "e90c", "e90f", "e911": return .animation
        case "e90e", "e908", "e909", "ping": return .show
        default: return .animation
        }
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
