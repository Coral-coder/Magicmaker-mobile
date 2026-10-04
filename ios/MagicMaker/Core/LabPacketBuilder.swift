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
        // The captured packet is 17 body bytes ending ...0508; the old copy had a spurious trailing B0.
        ("Pirate Cannon", "8301E100E9110003240F55515BF00F10374894D13D0508"),
        ("Show Off", "8301CC03000100E100E90500090E1DB0"),
        // Captured at a show on 2026-10-03, replayed byte-for-byte.
        ("Oct 3 · Pink/cyan animation", "8301E100E90C00010F4D575A940705488BB0"),
        ("Oct 3 · Pink animation", "8301E100E90C00410F4D4E5A940F1B488BB0"),
        ("Oct 3 · Pink comet", "8301E100E91000194897D00E8ED146060F30D04E1FB0"),
        ("Oct 3 · Cyan pulse fade", "8301E100E911002B0F405D58F44882D146040FD0650AB0"),
        ("Oct 3 · Pink/cyan cross-fade", "8301E200E911002F0F4D5758F44882D1460407D06532B0"),
        ("Oct 3 · Cyan/pink twinkle", "8301E100E90E00040FB7A8B6ADA059190248AEB0"),
        ("Oct 3 · White/cyan twinkle", "8301E100E90E00730FBBBBB8BBB859190248AEB0"),
        ("Oct 3 · Yellow twinkle", "8301E100E90E00020FB1B1B1B1B159190248AEB0"),
        ("Oct 3 · White centre, cyan corners", "8301E100E90600220F5C57B0"),
        ("Oct 3 · Yellow/purple/orange", "8301E200E90900210FB1A1B3B3A1B0"),
        ("Oct 3 · Repeating fade", "8301E100E9140054D037F0D23D021E180EF38983510EF10C49B0"),
        ("Oct 3 · Cyan candles", "8301E200E90F00120F40565813488DD2462A1317B0"),
        ("Oct 3 · Blue centre pulse", "8301E100E90F00020F43445801488DD246020100B0"),
        ("Oct 3 · White flash", "8301E200E90500110EFBB0"),
        ("Oct 3 · Lights off", "8301E200E90500010EFDB0"),
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

    static func buildCircle(vibEnabled: Bool, vibPattern: Int, colors: [Int] = []) -> String {
        PacketBuilder.circle(colors: colors, vib: vib(enabled: vibEnabled, pattern: vibPattern))
    }

    static func buildVibrate(vibEnabled: Bool, vibPattern: Int) -> String {
        PacketBuilder.vibrateBand(vib: vib(enabled: vibEnabled, pattern: vibPattern))
    }

    static func paletteLabel(_ id: Int) -> String {
        paletteColors.first(where: { $0.id == (id & 0x1F) })?.label ?? labLabel(id)
    }

    // MARK: - Guided builder model (mirrors Android LabPacketBuilder.LabPacketType / Framing / build)

    /// A packet kind the Lab can compose end-to-end. `colorSlots` is how many palette colours the
    /// type carries; `supportsVib` whether the buzz controls apply.
    enum LabPacketType: String, CaseIterable, Identifiable {
        case preset, dual, crossfade, rainbow, rotate, circle, vibrate, show, ping, raw
        var id: String { rawValue }

        var label: String {
            switch self {
            case .preset: return "Single Color"
            case .dual: return "Dual Color"
            case .crossfade: return "Crossfade"
            case .rainbow: return "Rainbow / Custom"
            case .rotate: return "Rotating Colors"
            case .circle: return "Circle Spin"
            case .vibrate: return "Vibrate Only"
            case .show: return "Park Show"
            case .ping: return "Wake Ping"
            case .raw: return "Raw Hex"
            }
        }

        var blurb: String {
            switch self {
            case .preset: return "One solid band color."
            case .dual: return "Two colors — inner / outer ring."
            case .crossfade: return "Smooth fade from one color to another."
            case .rainbow: return "Five LED colors — pick every one for your own animation."
            case .rotate: return "Five zone colors that rotate around the band (Figment-style)."
            case .circle: return "Rotating ring — seven pattern colours you can change (Figment is this shape)."
            case .vibrate: return "Haptic buzz, no color change."
            case .show: return "A real show effect captured in the park — lightning, sparkle, cannon…"
            case .ping: return "Wakes nearby bands so they hear the next command."
            case .raw: return "Type any payload by hand for total control."
            }
        }

        var colorSlots: Int {
            switch self {
            case .preset: return 1
            case .dual, .crossfade: return 2
            case .rainbow, .rotate: return 5
            case .circle: return 7
            default: return 0
            }
        }

        var supportsVib: Bool {
            switch self {
            case .preset, .dual, .crossfade, .rainbow, .rotate, .circle, .vibrate: return true
            default: return false
            }
        }
    }

    static func defaultColors(_ type: LabPacketType) -> [Int] {
        switch type {
        case .preset: return [PacketBuilder.Color.cyan]
        case .dual: return [PacketBuilder.Color.yellowOrange, PacketBuilder.Color.blue]
        case .crossfade: return [PacketBuilder.Color.red, PacketBuilder.Color.blue]
        case .rainbow:
            return [PacketBuilder.Color.yellowOrange, PacketBuilder.Color.red, PacketBuilder.Color.green,
                    PacketBuilder.Color.blue, PacketBuilder.Color.purple]
        case .circle: return PacketBuilder.circlePattern.map { $0 & 0x1F }
        case .rotate: return [PacketBuilder.Color.blue, PacketBuilder.Color.blue, PacketBuilder.Color.blue, 0x04, 0x04]
        default: return []
        }
    }

    /// How the packet is framed around its effect record. Every effect in the park capture carries
    /// a channel marker (E1 00); the esp32_magicband shapes never did. The wake-ping prefix is what
    /// the captured show packets put in front. See docs/PROTOCOL.md.
    struct Framing: Equatable {
        var channelMarker: Bool
        var wakePrefix: Bool
        /// Timing byte override for the effect body, or `PacketBuilder.Timing.default`.
        var timing: Int = PacketBuilder.Timing.default
    }

    /// Framing that reproduces exactly what each type has always produced.
    static func defaultFraming(_ type: LabPacketType) -> Framing {
        (type == .crossfade || type == .rotate) ? Framing(channelMarker: true, wakePrefix: false) : Framing(channelMarker: false, wakePrefix: false)
    }

    /// Shows, pings and raw hex are sent exactly as given.
    static func framingApplies(_ type: LabPacketType) -> Bool {
        type != .show && type != .ping && type != .raw
    }

    private static let channel1 = "E100"
    private static let wakePrefix = "CC03000100"

    /// Compose the hex for a fully specified builder state. Never transmits.
    static func build(
        type: LabPacketType,
        colors: [Int],
        vibEnabled: Bool,
        vibPattern: Int,
        rawHex: String = "",
        framing: Framing? = nil,
        showIndex: Int = 0
    ) -> String {
        func c(_ i: Int, _ fallback: Int) -> Int { colors.indices.contains(i) ? colors[i] : fallback }
        let base: String
        switch type {
        case .preset: base = buildPreset(colorId: c(0, PacketBuilder.Color.cyan), vibEnabled: vibEnabled, vibPattern: vibPattern)
        case .dual: base = buildDual(c(0, PacketBuilder.Color.yellowOrange), c(1, PacketBuilder.Color.blue), vibEnabled: vibEnabled, vibPattern: vibPattern)
        case .crossfade: base = buildCrossfade(c(0, PacketBuilder.Color.red), c(1, PacketBuilder.Color.blue), vibEnabled: vibEnabled, vibPattern: vibPattern)
        case .rainbow:
            base = buildRainbow(c(0, PacketBuilder.Color.yellowOrange), c(1, PacketBuilder.Color.red), c(2, PacketBuilder.Color.green),
                                c(3, PacketBuilder.Color.blue), c(4, PacketBuilder.Color.purple), vibEnabled: vibEnabled, vibPattern: vibPattern)
        case .circle: base = buildCircle(vibEnabled: vibEnabled, vibPattern: vibPattern, colors: colors)
        case .rotate: base = PacketBuilder.rotate(c(0, 0x02), c(1, 0x02), c(2, 0x02), c(3, 0x04), c(4, 0x04), vib: vib(enabled: vibEnabled, pattern: vibPattern))
        case .vibrate: base = buildVibrate(vibEnabled: vibEnabled, vibPattern: vibPattern)
        case .show: base = showEffects.indices.contains(showIndex) ? showEffects[showIndex].1 : showEffects[0].1
        case .ping: base = PacketBuilder.wakeupPing
        case .raw: return HexUtils.canonicalHex(rawHex)
        }
        guard framingApplies(type) else { return base }
        let f = framing ?? defaultFraming(type)
        // Strip whatever framing the primitive builder baked in, then apply the requested one.
        var body = base
        if body.hasPrefix("8301") { body.removeFirst(4) }
        if body.hasPrefix(wakePrefix) { body.removeFirst(wakePrefix.count) }
        if body.hasPrefix(channel1) { body.removeFirst(channel1.count) }
        return PacketBuilder.withTiming("8301" + (f.wakePrefix ? wakePrefix : "") + (f.channelMarker ? channel1 : "") + body, f.timing)
    }
}

/// Second wand type — the CF0B code range. Mirrors Android `NewWandCatalog.kt`.
/// Generated on demand (not persisted), so it never bloats the saved library.
enum NewWandCatalog {
    static let prefix = "8301CF0B00C020224EAC7807866"
    private static let rangeStart = 0xE80
    private static let rangeEnd = 0xFFF
    // These codes don't actually exist on the wand (last 2 bytes 6F20…6F7F).
    private static let excluded = 0xF20...0xF7F
    /// Synthetic id base, well above real learned-packet ids so the two never collide.
    static let idBase: Int64 = 1_000_000

    static let packets: [MagicPacket] = {
        (rangeStart...rangeEnd).compactMap { v -> MagicPacket? in
            if excluded.contains(v) { return nil }
            let hex = prefix + String(format: "%03X", v)
            let colorIdx = (Int(hex.suffix(2), radix: 16) ?? 0) & 0x1F
            return MagicPacket(
                id: idBase + Int64(v - rangeStart),
                hex: hex,
                label: "New Wand " + String(format: "%03X", v),
                category: .color,
                typeInfo: "newwand",
                colors: PresetCatalog.starlightColorNames[colorIdx] ?? "Color",
                simKey: "NEWWAND:\(hex)"
            )
        }
    }()

    static func byId(_ id: Int64) -> MagicPacket? { packets.first(where: { $0.id == id }) }
    static func isNewWandId(_ id: Int64) -> Bool { id >= idBase }
    static func randomHex() -> String? { packets.randomElement()?.hex }
}
