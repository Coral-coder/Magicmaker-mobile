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

enum PacketPatterns {
    static let systemTriggers: [PacketPattern] = [
        PacketPattern(id: "ping_fast", label: "Interaction ping (fast mode)", matchKind: .exactHex, matchValue: PresetCatalog.wakeupPing, defaultHex: PresetCatalog.wakeupPing),
        PacketPattern(id: "ping_prefix", label: "Any CC03 ping", matchKind: .hexPrefix, matchValue: "8301CC03"),
        PacketPattern(id: "starlight", label: "Any starlight wand (any color)", matchKind: .typeInfo, matchValue: "starlight", group: "Starlight wand"),
        PacketPattern(id: "e905", label: "Any single color (E905)", matchKind: .typeInfo, matchValue: "single"),
        PacketPattern(id: "e90c", label: "Any animation (E90C)", matchKind: .typeInfo, matchValue: "e90c"),
        PacketPattern(id: "rainbow", label: "Taste the Rainbow", matchKind: .simKey, matchValue: "A:RAINBOW", defaultHex: "8301CC03000100E100E90C000F0F5D465BF005323748B0"),
        PacketPattern(id: "any_raw", label: "Any unclassified packet", matchKind: .typeInfo, matchValue: "raw"),
    ]

    static let systemResponses: [PacketPattern] = [
        PacketPattern(id: "resp_wakeup", label: "Wakeup ping", matchKind: .exactHex, matchValue: PresetCatalog.wakeupPing, defaultHex: PresetCatalog.wakeupPing),
        PacketPattern(id: "resp_vibrate", label: "Vibrate band", matchKind: .exactHex, matchValue: PresetCatalog.vibratePacket, defaultHex: PresetCatalog.vibratePacket),
        PacketPattern(id: "resp_rainbow", label: "Rainbow finale", matchKind: .exactHex, matchValue: "8301CC03000100E100E90C000F0F5D465BF005323748B0", defaultHex: "8301CC03000100E100E90C000F0F5D465BF005323748B0"),
    ]

    static func buildTriggerOptions(learned: [MagicPacket]) -> [PacketPattern] {
        systemTriggers + learned.map { learnedTrigger($0) }
    }

    static func buildResponseOptions(learned: [MagicPacket]) -> [PacketPattern] {
        systemResponses + learned.map { learnedResponse($0) }
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
            return classified.simKey.caseInsensitiveCompare(pattern.matchValue) == .orderedSame
        case .typeInfo:
            return classified.typeInfo.caseInsensitiveCompare(pattern.matchValue) == .orderedSame
        case .hexPrefix:
            return heardRaw.hasPrefix(pattern.matchValue.uppercased())
        case .exactHex:
            return heardRaw == pattern.matchValue.uppercased()
        }
    }

    static func matchesTriggerId(_ triggerId: String, classified: ClassifiedPacket, rawHex: String, learned: [MagicPacket]) -> Bool {
        if triggerId.hasPrefix("learned_t_"), let id = Int64(triggerId.replacingOccurrences(of: "learned_t_", with: "")) {
            if let packet = learned.first(where: { $0.id == id }) {
                return classified.simKey.caseInsensitiveCompare(packet.simKey) == .orderedSame
            }
        }
        let triggers = buildTriggerOptions(learned: learned)
        guard let pattern = triggers.first(where: { $0.id == triggerId }) else { return false }
        return matches(pattern, classified: classified, rawHex: rawHex)
    }

    static func resolveResponseHex(rule: AutoResponseRule, learned: [MagicPacket]) -> String {
        if rule.responsePatternId.hasPrefix("learned_r_"), let id = Int64(rule.responsePatternId.replacingOccurrences(of: "learned_r_", with: "")) {
            if let packet = learned.first(where: { $0.id == id }) {
                return packet.hex
            }
        }
        if let sys = systemResponses.first(where: { $0.id == rule.responsePatternId }), !sys.defaultHex.isEmpty {
            return sys.defaultHex
        }
        return rule.responseHex.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
