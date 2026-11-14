import Foundation

struct PacketPattern: Identifiable, Equatable {
    enum MatchKind { case simKey, typeInfo, hexPrefix, exactHex, starlightColor }

    let id: String
    let label: String
    let matchKind: MatchKind
    let matchValue: String
    var defaultHex: String
    var group: String?

    init(id: String, label: String, matchKind: MatchKind, matchValue: String, defaultHex: String = "", group: String? = nil) {
        self.id = id
        self.label = label
        self.matchKind = matchKind
        self.matchValue = matchValue
        self.defaultHex = defaultHex
        self.group = group
    }
}

/// Auto-response triggers and responses. Port of Android `core/PacketPatterns.kt`.
enum PacketPatterns {
    /// Sentinel stored in a rule's response stack; resolved to a fresh random New Wand code
    /// every time the rule fires (see `resolveResponseHexes`) rather than fixed at rule creation.
    static let newWandRandomToken = "RANDOM_NEWWAND"

    private static let rainbowHex = "8301CC03000100E100E90C000F0F5D465BF005323748B0"

    static let systemTriggers: [PacketPattern] = [
        PacketPattern(id: "ping_fast", label: "Interaction ping (fast mode)", matchKind: .exactHex, matchValue: PacketBuilder.wakeupPing, defaultHex: PacketBuilder.wakeupPing),
        PacketPattern(id: "ping_prefix", label: "Any CC03 ping", matchKind: .hexPrefix, matchValue: "8301CC03"),
        PacketPattern(id: "starlight", label: "Any starlight wand (any color)", matchKind: .typeInfo, matchValue: "starlight", group: "Starlight wand"),
        PacketPattern(id: "newwand", label: "Any New Wand code (CF0B)", matchKind: .hexPrefix, matchValue: NewWandCatalog.prefix, group: "New wand"),
        PacketPattern(id: "e905", label: "Any single color (E905)", matchKind: .typeInfo, matchValue: "single"),
        PacketPattern(id: "e90c", label: "Any animation (E90C)", matchKind: .typeInfo, matchValue: "e90c"),
        PacketPattern(id: "rainbow", label: "Taste the Rainbow", matchKind: .simKey, matchValue: "A:RAINBOW", defaultHex: rainbowHex),
        PacketPattern(id: "any_raw", label: "Any unclassified packet", matchKind: .typeInfo, matchValue: "raw"),
    ]

    static let systemResponses: [PacketPattern] = [
        PacketPattern(id: "resp_wakeup", label: "Wakeup ping", matchKind: .exactHex, matchValue: PacketBuilder.wakeupPing, defaultHex: PacketBuilder.wakeupPing),
        PacketPattern(id: "resp_vibrate", label: "Vibrate band", matchKind: .exactHex, matchValue: PacketBuilder.vibrateBand(), defaultHex: PacketBuilder.vibrateBand()),
        PacketPattern(id: "resp_rainbow", label: "Rainbow finale", matchKind: .exactHex, matchValue: rainbowHex, defaultHex: rainbowHex),
        PacketPattern(id: "resp_newwand_random", label: "New Wand: RANDOM code", matchKind: .exactHex, matchValue: newWandRandomToken, defaultHex: newWandRandomToken),
    ]

    static func buildTriggerOptions(userPresets: [MagicPacket] = [], learned: [MagicPacket]) -> [PacketPattern] {
        var out: [PacketPattern] = systemTriggers
        for packet in userPresets { out.append(presetTrigger(packet)) }
        for packet in learned { out.append(learnedTrigger(packet)) }
        return out
    }

    static func buildResponseOptions(userPresets: [MagicPacket] = [], learned: [MagicPacket]) -> [PacketPattern] {
        var out: [PacketPattern] = systemResponses
        for packet in userPresets { out.append(presetResponse(packet)) }
        for packet in learned { out.append(learnedResponse(packet)) }
        for packet in NewWandCatalog.packets { out.append(newWandResponse(packet)) }
        return out
    }

    static func newWandResponse(_ packet: MagicPacket) -> PacketPattern {
        PacketPattern(id: "newwand_r_\(packet.id)", label: "New Wand " + String(packet.hex.suffix(4)), matchKind: .exactHex, matchValue: packet.hex, defaultHex: packet.hex)
    }

    static func presetTrigger(_ packet: MagicPacket) -> PacketPattern {
        PacketPattern(id: "preset_t_\(packet.id)", label: packet.label, matchKind: .simKey, matchValue: packet.simKey, defaultHex: packet.hex, group: packet.category.rawValue)
    }

    static func presetResponse(_ packet: MagicPacket) -> PacketPattern {
        PacketPattern(id: "preset_r_\(packet.id)", label: packet.label, matchKind: .simKey, matchValue: packet.simKey, defaultHex: packet.hex)
    }

    static func learnedTrigger(_ packet: MagicPacket) -> PacketPattern {
        PacketPattern(id: "learned_t_\(packet.id)", label: packet.label, matchKind: .simKey, matchValue: packet.simKey, defaultHex: packet.hex, group: packet.category.rawValue)
    }

    static func learnedResponse(_ packet: MagicPacket) -> PacketPattern {
        PacketPattern(id: "learned_r_\(packet.id)", label: packet.label, matchKind: .simKey, matchValue: packet.simKey, defaultHex: packet.hex)
    }

    static func matches(_ pattern: PacketPattern, classified: ClassifiedPacket, rawHex: String) -> Bool {
        let heardRaw = rawHex.uppercased().filter { "0123456789ABCDEF".contains($0) }
        switch pattern.matchKind {
        case .starlightColor:
            guard classified.typeInfo == "starlight" else { return false }
            let heard = MagicClassifier.starlightColorIndex(heardRaw)
            let want = Int(pattern.matchValue, radix: 16) ?? -1
            return heard == want
        case .simKey:
            return equalsIgnoreCase(classified.simKey, pattern.matchValue)
        case .typeInfo:
            return equalsIgnoreCase(classified.typeInfo, pattern.matchValue)
        case .hexPrefix:
            return heardRaw.hasPrefix(pattern.matchValue.uppercased())
        case .exactHex:
            return heardRaw == pattern.matchValue.uppercased()
        }
    }

    static func matchesTriggerId(
        _ triggerId: String,
        classified: ClassifiedPacket,
        rawHex: String,
        userPresets: [MagicPacket] = [],
        learned: [MagicPacket]
    ) -> Bool {
        if let id = idSuffix(triggerId, prefix: "preset_t_"),
           let preset = userPresets.first(where: { $0.id == id }) {
            if equalsIgnoreCase(classified.simKey, preset.simKey) { return true }
            return HexUtils.canonicalHex(rawHex) == HexUtils.canonicalHex(preset.hex)
        }
        if let id = idSuffix(triggerId, prefix: "learned_t_"),
           let packet = learned.first(where: { $0.id == id }) {
            return equalsIgnoreCase(classified.simKey, packet.simKey)
        }
        // System triggers are the common case. Check that short list before building the full
        // option list, which allocates a pattern for every library packet.
        if let pattern = systemTriggers.first(where: { $0.id == triggerId }) {
            return matches(pattern, classified: classified, rawHex: rawHex)
        }
        let options = buildTriggerOptions(userPresets: userPresets, learned: learned)
        guard let pattern = options.first(where: { $0.id == triggerId }) else { return false }
        return matches(pattern, classified: classified, rawHex: rawHex)
    }

    /// Every packet a rule answers with, in send order.
    static func resolveResponseHexes(rule: AutoResponseRule, userPresets: [MagicPacket] = [], learned: [MagicPacket]) -> [String] {
        // Resolve the random-New-Wand sentinel to a fresh code per fire; canonicalize the rest.
        var stacked: [String] = []
        for raw in rule.responseHexes {
            if raw == newWandRandomToken {
                if let hex = NewWandCatalog.randomHex() { stacked.append(hex) }
            } else {
                let canonical = HexUtils.canonicalHex(raw)
                if !canonical.isEmpty { stacked.append(canonical) }
            }
        }
        if !stacked.isEmpty { return stacked }

        if let id = idSuffix(rule.responsePatternId, prefix: "preset_r_"),
           let preset = userPresets.first(where: { $0.id == id }) {
            return [preset.hex]
        }
        if let id = idSuffix(rule.responsePatternId, prefix: "learned_r_"),
           let packet = learned.first(where: { $0.id == id }) {
            return [packet.hex]
        }
        if let id = idSuffix(rule.responsePatternId, prefix: "newwand_r_"),
           let packet = NewWandCatalog.byId(id) {
            return [packet.hex]
        }
        if let sys = systemResponses.first(where: { $0.id == rule.responsePatternId && !$0.defaultHex.isEmpty }) {
            // A rule saved without a stack still gets a fresh code, never the sentinel text.
            if sys.defaultHex == newWandRandomToken { return randomNewWandStack() }
            return [sys.defaultHex]
        }
        let single = rule.responseHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if single.isEmpty { return [] }
        if single == newWandRandomToken { return randomNewWandStack() }
        return [HexUtils.canonicalHex(single)]
    }

    static func resolveResponseHex(rule: AutoResponseRule, userPresets: [MagicPacket] = [], learned: [MagicPacket]) -> String {
        resolveResponseHexes(rule: rule, userPresets: userPresets, learned: learned).first ?? ""
    }

    private static func randomNewWandStack() -> [String] {
        guard let hex = NewWandCatalog.randomHex() else { return [] }
        return [hex]
    }

    /// The numeric id after `prefix`, or nil when `value` does not start with it or the rest is
    /// not a number.
    private static func idSuffix(_ value: String, prefix: String) -> Int64? {
        guard value.hasPrefix(prefix) else { return nil }
        return Int64(String(value.dropFirst(prefix.count)))
    }

    private static func equalsIgnoreCase(_ a: String, _ b: String) -> Bool {
        a.lowercased() == b.lowercased()
    }
}
