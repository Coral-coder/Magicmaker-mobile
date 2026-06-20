import Foundation

/// Lab packet builder — mirrors Android `LabPacketBuilder.kt`.
enum LabPacketBuilder {
    struct PaletteColor: Identifiable {
        let id: Int
        let label: String
        var paletteId: Int { id }
    }

    struct VibrationPattern: Identifiable {
        let id: Int
        let label: String
    }

    static func labLabel(_ index: Int) -> String {
        let i = index & 0x1F
        let name = PresetCatalog.starlightColorNames[i] ?? "Unknown"
        return String(format: "#%02X %@", i, name)
    }

    static var paletteColors: [PaletteColor] {
        PresetCatalog.starlightColorNames.keys.sorted().map { PaletteColor(id: $0, label: labLabel($0)) }
    }

    static let primaryPresetColors: [PaletteColor] = [
        PaletteColor(id: PacketBuilder.Color.cyan, label: "Cyan"),
        PaletteColor(id: PacketBuilder.Color.purple, label: "Purple"),
        PaletteColor(id: PacketBuilder.Color.blue, label: "Blue"),
        PaletteColor(id: PacketBuilder.Color.midnightBlue, label: "Mid Blue"),
        PaletteColor(id: PacketBuilder.Color.brightPurple, label: "Br Purple"),
        PaletteColor(id: PacketBuilder.Color.lavender, label: "Lavender"),
        PaletteColor(id: PacketBuilder.Color.pink, label: "Pink"),
        PaletteColor(id: PacketBuilder.Color.yellowOrange, label: "Y-Orange"),
        PaletteColor(id: PacketBuilder.Color.lime, label: "Lime"),
        PaletteColor(id: PacketBuilder.Color.orange, label: "Orange"),
        PaletteColor(id: PacketBuilder.Color.red, label: "Red"),
        PaletteColor(id: PacketBuilder.Color.green, label: "Green"),
        PaletteColor(id: PacketBuilder.Color.white, label: "White"),
        PaletteColor(id: PacketBuilder.Color.off, label: "Off"),
        PaletteColor(id: PacketBuilder.Color.random, label: "Random"),
    ]

    static let showEffects: [(String, String)] = [
        ("Lightning", "8301CC03000100E100E90C000F0F5D465BF00532374895"),
        ("Rainbow FX", "8301CC03000100E100E90C000F0F5D465BF005323748B0"),
        ("Ambient Blue", "8301CC03000100E100E90500090E02B0"),
        ("Ambient Lavender", "8301CC03000100E100E90500090E06B0"),
        ("Ambient Cyan", "8301CC03000100E100E90500090E00B0"),
        ("Alt Strobe", "8301CC03000100E100E90F00110EF17AEC5C012814281448ABB0"),
        ("Slow Sparkle", "8301E100E90F00520EF17AEC5C021902190248ABB0"),
        ("Fast Sparkle", "8301E100E90F00520EF17AEC5C021B151B1548ABB0"),
        ("Pirate Cannon", "8301E100E9110003240F55515BF00F10374894D13D0508B0"),
        ("Show Off", "8301CC03000100E100E90500090E1DB0"),
    ]

    static let vibrationPatterns: [VibrationPattern] = (0...15).map { id in
        let label: String
        switch id {
        case 0: label = "Off"
        case 1: label = "Short"
        case 2: label = "Double"
        case 3: label = "Triple"
        case 4: label = "Quad"
        case 5: label = "Burst"
        case 6: label = "Pulse 6"
        case 7: label = "Pulse 7"
        case 8: label = "Long"
        default: label = "Pattern \(id)"
        }
        return VibrationPattern(id: id, label: label)
    }

    static func vib(enabled: Bool, pattern: Int) -> Int {
        enabled ? max(0, min(15, pattern)) : 0
    }

    static func buildPreset(colorId: Int, vibEnabled: Bool, vibPattern: Int) -> String {
        PacketBuilder.preset(color: colorId & 0x1F, vib: vib(enabled: vibEnabled, pattern: vibPattern))
    }

    static func buildDual(_ c1: Int, _ c2: Int, vibEnabled: Bool, vibPattern: Int) -> String {
        PacketBuilder.dual(c1, c2, vib: vib(enabled: vibEnabled, pattern: vibPattern))
    }

    static func buildCrossfade(_ c1: Int, _ c2: Int, vibEnabled: Bool, vibPattern: Int) -> String {
        PacketBuilder.crossfade(c1: c1, c2: c2, vib: vib(enabled: vibEnabled, pattern: vibPattern))
    }

    static func buildRainbow(_ c1: Int, _ c2: Int, _ c3: Int, _ c4: Int, _ c5: Int, vibEnabled: Bool, vibPattern: Int) -> String {
        PacketBuilder.rainbow5(c1: c1, c2: c2, c3: c3, c4: c4, c5: c5, vib: vib(enabled: vibEnabled, pattern: vibPattern))
    }

    static func buildCircle(vibEnabled: Bool, vibPattern: Int) -> String {
        PacketBuilder.circle(vib: vib(enabled: vibEnabled, pattern: vibPattern))
    }

    static func buildVibrate(vibEnabled: Bool, vibPattern: Int) -> String {
        PacketBuilder.vibrateBand(vib: vib(enabled: vibEnabled, pattern: vibPattern))
    }

    static func paletteLabel(_ id: Int) -> String {
        paletteColors.first(where: { $0.id == (id & 0x1F) })?.label ?? labLabel(id)
    }
}
