import Foundation

/// Built-in transmit presets (esp32_magicband + park captures). Port of Android `core/PresetCatalog.kt`.
enum PresetCatalog {
    struct Preset: Equatable {
        let label: String
        let hex: String
        let kind: Kind

        /// The raw value doubles as the preset's `typeInfo`.
        enum Kind: String { case ping, vibrate, color, effect }
    }

    static let wakeupPing = "8301CC03000100"
    /// "Vibrate band": white with the burst vibration pattern.
    static let vibratePacket: String = PacketBuilder.vibrateBand()

    private static let lightningHex = "8301CC03000100E100E90C000F0F5D465BF00532374895"

    static let all: [Preset] = [
        Preset(label: "Ping (wakeup)", hex: PacketBuilder.wakeupPing, kind: .ping),
        Preset(label: "Vibrate band", hex: PacketBuilder.vibrateBand(), kind: .vibrate),
        Preset(label: "Vibrate (rainbow FX)", hex: PacketBuilder.rainbowFinale, kind: .vibrate),
        Preset(label: "Red", hex: PacketBuilder.preset(color: PacketBuilder.Color.red), kind: .color),
        Preset(label: "Blue", hex: PacketBuilder.preset(color: PacketBuilder.Color.blue), kind: .color),
        Preset(label: "Cyan", hex: PacketBuilder.preset(color: PacketBuilder.Color.cyan), kind: .color),
        Preset(label: "Green", hex: PacketBuilder.preset(color: PacketBuilder.Color.green), kind: .color),
        Preset(label: "Purple", hex: PacketBuilder.preset(color: PacketBuilder.Color.brightPurple), kind: .color),
        Preset(label: "Pink", hex: PacketBuilder.preset(color: PacketBuilder.Color.pink), kind: .color),
        Preset(label: "White", hex: PacketBuilder.preset(color: PacketBuilder.Color.white), kind: .color),
        Preset(label: "Orange", hex: PacketBuilder.preset(color: PacketBuilder.Color.orange), kind: .color),
        Preset(label: "Dual YO/Blue", hex: PacketBuilder.dual(PacketBuilder.Color.yellowOrange, PacketBuilder.Color.blue), kind: .effect),
        Preset(label: "5-LED Rainbow", hex: PacketBuilder.rainbow5(), kind: .effect),
        Preset(label: "Circle", hex: PacketBuilder.circle(), kind: .effect),
        Preset(label: "Crossfade R/B", hex: PacketBuilder.crossfade(), kind: .effect),
        Preset(label: "Lightning", hex: lightningHex, kind: .effect),
    ]

    /// EMCOT 5-bit palette. The table lives here; `StarlightColors.palette` reads it.
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

    static let showBlocks: [String: String] = [
        "Lightning": lightningHex,
        "Rainbow FX": PacketBuilder.rainbowFinale,
    ]

    static func starlightSimKey(_ colorIndex: Int) -> String {
        "SL:\(String(format: "%02X", colorIndex & 0x1F))"
    }

    static func legacyStarlightHex(colorIndex: Int, serial: String = StarlightSerial.defaultSerial) -> String {
        StarlightSerial.buildHex(serial: serial, colorIndex: colorIndex)
    }

    static func asMagicPackets() -> [MagicPacket] {
        var out: [MagicPacket] = []
        out.reserveCapacity(all.count)
        for (i, p) in all.enumerated() {
            let category: MagicCategory
            switch p.kind {
            case .color: category = .color
            case .effect, .vibrate: category = .animation
            case .ping: category = .show
            }
            out.append(MagicPacket(
                id: Int64(i + 1),
                hex: p.hex,
                label: p.label,
                category: category,
                typeInfo: p.kind.rawValue,
                colors: "",
                simKey: "P:\(p.label)"
            ))
        }
        return out
    }

    /// Older name for `asMagicPackets()`.
    static func allPresets() -> [MagicPacket] { asMagicPackets() }
}
