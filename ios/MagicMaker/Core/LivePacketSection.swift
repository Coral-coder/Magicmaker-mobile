import Foundation

enum LivePacketSection: String, CaseIterable, Identifiable {
    case wand = "Wand"
    case colors = "Colors"
    case animations = "Animations"
    case control = "Control"
    case ping = "Ping"
    case interrogate = "Interrogate"
    case shows = "Shows"
    case unknown = "Unknown"

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }

    var sortOrder: Int {
        switch self {
        case .wand: return 0
        case .colors: return 1
        case .animations: return 2
        case .control: return 3
        case .ping: return 4
        case .interrogate: return 5
        case .shows: return 6
        case .unknown: return 7
        }
    }
}

/// Port of Android `core/LivePacketSort.kt`.
enum LivePacketSort {
    static func liveDedupeKey(hex: String, classified: ClassifiedPacket?) -> String {
        let canonical = HexUtils.canonicalHex(hex)
        if let classified {
            if classified.typeInfo == "starlight" {
                return PresetCatalog.starlightSimKey(MagicClassifier.starlightColorIndex(canonical))
            }
            return MagicClassifier.libraryDedupeKey(classified)
        }
        return "RAW:\(canonical)"
    }

    /// The one rule set behind every `section(of:)` overload. `category` is a `MagicCategory` raw value.
    private static func section(hex hexRaw: String, label: String, typeInfo: String, category: String) -> LivePacketSection {
        let hex = HexUtils.canonicalHex(hexRaw)
        if typeInfo == "starlight" {
            return .wand
        }
        if typeInfo == "single" || typeInfo == "dual" {
            return .colors
        }
        if label.range(of: "Show Control", options: .caseInsensitive) != nil
            || typeInfo == "e90e" || typeInfo == "e908" {
            return .control
        }
        if typeInfo == "ping" && hex == PacketBuilder.wakeupPing {
            return .interrogate
        }
        if typeInfo == "ping" {
            return .ping
        }
        if category == MagicCategory.animation.rawValue {
            return .animations
        }
        if category == MagicCategory.show.rawValue || typeInfo == "show_block" {
            return .shows
        }
        return .unknown
    }

    /// Every section, in display order.
    private static let sectionsInOrder: [LivePacketSection] = LivePacketSection.allCases.sorted { $0.sortOrder < $1.sortOrder }

    /// Kotlin `sortedBy { it.label }`: plain code-unit comparison, equal labels keep their order.
    private static func sortedByLabel<T>(_ rows: [T], label: (T) -> String) -> [T] {
        let keys: [[UInt16]] = rows.map { Array(label($0).utf16) }
        let order: [Int] = Array(rows.indices).sorted { (a: Int, b: Int) -> Bool in
            if keys[a].lexicographicallyPrecedes(keys[b]) { return true }
            if keys[b].lexicographicallyPrecedes(keys[a]) { return false }
            return a < b
        }
        return order.map { rows[$0] }
    }

    static func section(of packet: IScanLivePacket) -> LivePacketSection {
        section(hex: packet.hex, label: packet.label, typeInfo: packet.typeInfo, category: packet.category.rawValue)
    }

    /// Grouped sections (in display order), newest first within each group.
    static func groupedIScan(_ packets: [IScanLivePacket]) -> [(LivePacketSection, [IScanLivePacket])] {
        var groups: [LivePacketSection: [IScanLivePacket]] = [:]
        for packet in packets {
            groups[section(of: packet), default: []].append(packet)
        }
        var out: [(LivePacketSection, [IScanLivePacket])] = []
        for key in sectionsInOrder {
            guard let rows = groups[key] else { continue }
            let newestFirst = rows.sorted { $0.timestampMs > $1.timestampMs }
            out.append((key, newestFirst))
        }
        return out
    }

    static func section(of preset: AndroidRemotePreset) -> LivePacketSection {
        section(hex: preset.hex, label: preset.label, typeInfo: preset.typeInfo, category: preset.category)
    }

    static func section(of packet: AndroidRemotePacket, typeInfo: String = "") -> LivePacketSection {
        section(hex: packet.hex, label: packet.label, typeInfo: typeInfo, category: packet.category)
    }

    static func groupedPresets(_ presets: [AndroidRemotePreset]) -> [(LivePacketSection, [AndroidRemotePreset])] {
        var groups: [LivePacketSection: [AndroidRemotePreset]] = [:]
        for preset in presets {
            groups[section(of: preset), default: []].append(preset)
        }
        var out: [(LivePacketSection, [AndroidRemotePreset])] = []
        for key in sectionsInOrder {
            guard let rows = groups[key] else { continue }
            let byLabel = sortedByLabel(rows, label: { $0.label })
            out.append((key, byLabel))
        }
        return out
    }

    static func section(of packet: AndroidRemotePacket) -> LivePacketSection {
        section(
            of: packet,
            typeInfo: packet.typeInfo
        )
    }

    static func groupedLiveUnique(_ packets: [AndroidRemotePacket]) -> [AndroidRemotePacket] {
        var seen = Set<String>()
        var out: [AndroidRemotePacket] = []
        for packet in packets {
            guard seen.insert(packet.dedupeKey).inserted else { continue }
            out.append(packet)
        }
        return out
    }

    static func groupedLive(_ packets: [AndroidRemotePacket]) -> [(LivePacketSection, [AndroidRemotePacket])] {
        var groups: [LivePacketSection: [AndroidRemotePacket]] = [:]
        for packet in packets {
            groups[section(of: packet), default: []].append(packet)
        }
        var out: [(LivePacketSection, [AndroidRemotePacket])] = []
        for key in sectionsInOrder {
            guard let rows = groups[key] else { continue }
            out.append((key, rows))
        }
        return out
    }

    static func section(of packet: MagicPacket) -> LivePacketSection {
        section(hex: packet.hex, label: packet.label, typeInfo: packet.typeInfo, category: packet.category.rawValue)
    }

    /// Grouped sections (in display order), rows sorted by label within each group.
    static func groupedMagicPackets(_ packets: [MagicPacket]) -> [(LivePacketSection, [MagicPacket])] {
        var groups: [LivePacketSection: [MagicPacket]] = [:]
        for packet in packets {
            groups[section(of: packet), default: []].append(packet)
        }
        var out: [(LivePacketSection, [MagicPacket])] = []
        for key in sectionsInOrder {
            guard let rows = groups[key] else { continue }
            let byLabel = sortedByLabel(rows, label: { $0.label })
            out.append((key, byLabel))
        }
        return out
    }
}
