import Foundation

enum PresetCatalog {
    static let wakeupPing = "8301CC03000100"
    static let vibratePacket = "8301CC03000100E100E90C000F0F5D465BF005323748B0"

    static let showBlocks: [String: String] = [
        "Show: Wakeup Ping": wakeupPing,
        "Show: Ambient Blue": "8301CC03000100E100E90500090E02B0",
        "Show: Ambient Lavender": "8301CC03000100E100E90500090E06B0",
        "Show: Ambient Cyan": "8301CC03000100E100E90500090E00B0",
        "Show: Lightning Burst": "8301CC03000100E100E90C000F0F5D465BF00532374895",
        "Show: Rainbow Finale": "8301CC03000100E100E90C000F0F5D465BF005323748B0",
        "Show: Fast Alt Response": "8301CC03000100E100E90F00110EF17AEC5C012814281448ABB0",
        "Show: Outro / Off": "8301CC03000100E100E90500090E1DB0",
        "Show: Pirate Cannon": "8301E100E9110003240F55515BF00F10374894D13D0508B0",
        "Show: Slow Sparkle": "8301E100E90F00520EF17AEC5C021902190248ABB0",
        "Show: Fast Sparkle": "8301E100E90F00520EF17AEC5C021B151B1548ABB0",
    ]

    static let starlightColorNames: [Int: String] = [
        0x00: "Cyan", 0x01: "Purple", 0x02: "Blue", 0x03: "Midnight Blue",
        0x04: "Blue", 0x05: "Bright Purple", 0x06: "Lavender", 0x07: "Purple",
        0x08: "Pink", 0x09: "Pink", 0x0A: "Pink", 0x0B: "Pink", 0x0C: "Pink",
        0x0D: "Pink", 0x0E: "Pink", 0x0F: "Yellow Orange", 0x10: "Off Yellow",
        0x11: "Yellow", 0x12: "Lime", 0x13: "Orange", 0x14: "Red Orange",
        0x15: "Red", 0x16: "Cyan", 0x17: "Cyan", 0x18: "Cyan", 0x19: "Green",
        0x1A: "Lime Green", 0x1B: "White", 0x1C: "White", 0x1D: "Off",
        0x1E: "Unique", 0x1F: "Random",
    ]

    static func legacyStarlightHex(colorIndex: Int, serial: String = StarlightSerial.defaultSerial) -> String {
        StarlightSerial.buildHex(serial: serial, colorIndex: colorIndex)
    }

    static func starlightSimKey(_ colorIndex: Int) -> String {
        "SL:\(String(format: "%02X", colorIndex & 0x1F))"
    }

    static func animationPresets() -> [(String, String)] {
        [
            ("Animation: Lightning Pulse", "8301CC03000100E100E90C000F0F5D465BF00532374895"),
            ("Animation: Taste the Rainbow", "8301CC03000100E100E90C000F0F5D465BF005323748B0"),
            ("Animation: Alternating Strobe", "8301CC03000100E100E90F00110EF17AEC5C012814281448ABB0"),
            ("Animation: Slow Sparkle", "8301E100E90F00520EF17AEC5C021902190248ABB0"),
            ("Single Color: Blue", "8301CC03000100E100E90500090E02B0"),
            ("Single Color: Lavender", "8301CC03000100E100E90500090E06B0"),
        ]
    }

    static func allPresets() -> [MagicPacket] {
        var out: [MagicPacket] = []
        for (label, hex) in showBlocks {
            if let c = MagicClassifier.classify(hex) {
                out.append(MagicPacket(hex: c.hex, label: label, category: .show, typeInfo: c.typeInfo, colors: c.colors, simKey: c.simKey))
            }
        }
        for (label, hex) in animationPresets() {
            if let c = MagicClassifier.classify(hex) {
                out.append(MagicPacket(hex: c.hex, label: label, category: .animation, typeInfo: c.typeInfo, colors: c.colors, simKey: c.simKey))
            }
        }
        return Array(Dictionary(grouping: out, by: \.simKey).compactMap(\.value.first).sorted { $0.label < $1.label })
    }
}
