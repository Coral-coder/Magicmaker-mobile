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

        if normalized.contains("CC03"), !normalized.contains("E9"), !normalized.contains("CF9B"), !normalized.contains("CF0B") {
            let pingLabel = normalized == "8301CC03000100" ? "Interaction Ping (Fast Mode)" : "Interaction Ping"
            return ClassifiedPacket(hex: normalized, label: pingLabel, category: .show, typeInfo: "ping", colors: "", simKey: "PING:\(normalized)")
        }

        guard let idx = normalized.range(of: "E9")?.lowerBound else { return nil }
        let pos = normalized.distance(from: normalized.startIndex, to: idx)
        let funcCode = String(normalized[normalized.index(normalized.startIndex, offsetBy: pos)..<normalized.index(normalized.startIndex, offsetBy: min(pos + 4, normalized.count))])

        let label: String
        let typeInfo: String
        let colors: String
        let simKey: String

        switch funcCode {
        case "E905":
            let colorIdx = extractE905Color(normalized, pos: pos)
            let name = colorPalette[colorIdx] ?? "Unknown"
            label = name == "Off" ? "Single Color: Off" : "Single Color: \(name)"
            typeInfo = "single"
            colors = name
            simKey = "C1:\(String(format: "%02X", colorIdx))"
        case "E906":
            let c1 = normalized.count >= pos + 12 ? Int(normalized[normalized.index(normalized.startIndex, offsetBy: pos + 10)..<normalized.index(normalized.startIndex, offsetBy: pos + 12)], radix: 16)! & 0x1F : 0
            let c2 = normalized.count >= pos + 14 ? Int(normalized[normalized.index(normalized.startIndex, offsetBy: pos + 12)..<normalized.index(normalized.startIndex, offsetBy: pos + 14)], radix: 16)! & 0x1F : 0
            let n1 = colorPalette[c1] ?? "?"
            let n2 = colorPalette[c2] ?? "?"
            label = "Dual Color: \(n2)/\(n1)"
            typeInfo = "dual"
            colors = "\(n2) / \(n1)"
            simKey = "C2:\(String(format: "%02X", c2)):\(String(format: "%02X", c1))"
        case "E90C":
            label = if normalized.localizedCaseInsensitiveContains("5D465BF00532374895") { "Animation: Lightning Pulse" }
            else if normalized.localizedCaseInsensitiveContains("B1B9B5B1A2307B7DB0") { "Animation: 5-Color Cycle" }
            else if normalized.localizedCaseInsensitiveContains("5D465BF005323748B0") { "Animation: Taste the Rainbow" }
            else { "Animation: Complex (E90C)" }
            typeInfo = "e90c"
            colors = ""
            simKey = if normalized.localizedCaseInsensitiveContains("5D465BF00532374895") { "A:LIGHTNING" }
            else if normalized.localizedCaseInsensitiveContains("5D465BF005323748B0") { "A:RAINBOW" }
            else { "A:E90C:\(String(normalized[normalized.index(normalized.startIndex, offsetBy: pos)..<normalized.index(normalized.startIndex, offsetBy: min(pos + 20, normalized.count))]))" }
        case "E90F":
            label = "Animation: Alternating Strobe"
            typeInfo = "e90f"
            colors = ""
            simKey = "A:E90F:\(String(normalized[normalized.index(normalized.startIndex, offsetBy: pos)..<normalized.index(normalized.startIndex, offsetBy: min(pos + 16, normalized.count))]))"
        case "E911":
            label = normalized.localizedCaseInsensitiveContains("55515BF00F10374894D13D0508B0") ? "Show: Pirate Cannon" : "Animation: Palette Cross-Fade"
            typeInfo = "e911"
            colors = extractFadeColor(normalized)
            simKey = normalized.localizedCaseInsensitiveContains("55515BF00F10374894D13D0508B0") ? "A:PIRATE_CANNON" : "A:E911:\(normalized.suffix(4))"
        case "E90E", "E909", "E908":
            label = "Show Control: \(funcCode)"
            typeInfo = funcCode.lowercased()
            colors = ""
            simKey = "S:\(funcCode)"
        default:
            return nil
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
