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

    static func section(of packet: IScanLivePacket) -> LivePacketSection {
        section(
            of: AndroidRemotePacket(
                id: packet.dedupeKey,
                hex: packet.hex,
                label: packet.label,
                rssi: packet.rssi,
                note: packet.note,
                category: packet.category.rawValue,
                typeInfo: packet.typeInfo,
                dedupeKey: packet.dedupeKey,
                timestampMs: packet.timestampMs
            ),
            typeInfo: packet.typeInfo
        )
    }

    static func groupedIScan(_ packets: [IScanLivePacket]) -> [(LivePacketSection, [IScanLivePacket])] {
        packets
            .reduce(into: [LivePacketSection: [IScanLivePacket]]()) { dict, packet in
                dict[section(of: packet), default: []].append(packet)
            }
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { ($0.key, $0.value.sorted { $0.timestampMs > $1.timestampMs }) }
    }

    static func section(of preset: AndroidRemotePreset) -> LivePacketSection {
        let hex = HexUtils.canonicalHex(preset.hex)
        switch preset.typeInfo {
        case "starlight":
            return .wand
        case "single", "dual":
            return .colors
        default:
            break
        }
        if preset.label.localizedCaseInsensitiveContains("Show Control")
            || preset.typeInfo == "e90e" || preset.typeInfo == "e908" {
            return .control
        }
        if preset.typeInfo == "ping", hex == PresetCatalog.wakeupPing {
            return .interrogate
        }
        if preset.typeInfo == "ping" {
            return .ping
        }
        if preset.category == MagicCategory.animation.rawValue {
            return .animations
        }
        if preset.category == MagicCategory.show.rawValue || preset.typeInfo == "show_block" {
            return .shows
        }
        return .unknown
    }

    static func section(of packet: AndroidRemotePacket, typeInfo: String = "") -> LivePacketSection {
        let hex = HexUtils.canonicalHex(packet.hex)
        if typeInfo == "starlight" {
            return .wand
        }
        if typeInfo == "single" || typeInfo == "dual" {
            return .colors
        }
        if packet.label.localizedCaseInsensitiveContains("Show Control")
            || typeInfo == "e90e" || typeInfo == "e908" {
            return .control
        }
        if typeInfo == "ping", hex == PresetCatalog.wakeupPing {
            return .interrogate
        }
        if typeInfo == "ping" {
            return .ping
        }
        if packet.category == MagicCategory.animation.rawValue {
            return .animations
        }
        if packet.category == MagicCategory.show.rawValue || typeInfo == "show_block" {
            return .shows
        }
        return .unknown
    }

    static func groupedPresets(_ presets: [AndroidRemotePreset]) -> [(LivePacketSection, [AndroidRemotePreset])] {
        presets
            .reduce(into: [LivePacketSection: [AndroidRemotePreset]]()) { dict, preset in
                let section = section(of: preset)
                dict[section, default: []].append(preset)
            }
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { ($0.key, $0.value.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }) }
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
        packets
            .reduce(into: [LivePacketSection: [AndroidRemotePacket]]()) { dict, packet in
                let section = section(of: packet)
                dict[section, default: []].append(packet)
            }
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { ($0.key, $0.value) }
    }
}
