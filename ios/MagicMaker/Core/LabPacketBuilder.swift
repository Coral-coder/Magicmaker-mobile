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

    // MARK: - Extended mode

    /// Only offered when the Lab's Extended switch is on.
    static func isExperimental(_ t: LabPacketType) -> Bool { t == .rgb || t == .experiment }

    /// An experimental packet and the question it answers.
    struct Experiment { let name: String; let hex: String; let watch: String }

    static let experiments: [Experiment] = [
        Experiment(name: "E907 · three colours? (red/green/blue)", hex: "8301E200E90700220F555942B0", watch: "E907 has dual's 00 22 0F header plus a third colour. Watch where each colour lands."),
        Experiment(name: "E907 · Flipper sample #1", hex: "8301E200E90700220F434341B0", watch: "Captured by someone else, purpose unknown. Midnight blue ×2 + purple."),
        Experiment(name: "E907 · Flipper sample #2", hex: "8301E200E90700220F444441B0", watch: "Like #1 with blue instead of midnight blue."),
        Experiment(name: "Random colour on every LED", hex: "8301E909002E0FBFBFBFBFBFB0", watch: "Palette 0x1F on all five. Same random colour, or one each?"),
        Experiment(name: "'Unique' colour (0x1E)", hex: "8301E905002E0EFEB0", watch: "The colour your show's Repeating Fade used. Nobody knows what it is."),
        Experiment(name: "Channel 3 (E3) red", hex: "8301E300E905002E0EF5B0", watch: "Same red as a normal preset but on channel 3. Does the band answer every channel?"),
        Experiment(name: "Always-on red (timing 8F)", hex: "8301E905008F0EF5B0", watch: "Bit 7 of the timing byte. Does it stay lit until another command?"),
        Experiment(name: "46-second red (timing 4F)", hex: "8301E905004F0EF5B0", watch: "Bit 6 = ×3.1 s multiplier, 15 × 3.1 ≈ 46 s. Time it."),
        Experiment(name: "Dual, park flags (4x)", hex: "8301E90600220F5542B0", watch: "Red centre, blue corners, colour bytes flagged like real park duals."),
        Experiment(name: "Dual, builder flags (8x)", hex: "8301E90600220F9582B0", watch: "Same colours, flagged like the app's Dual builder. Any difference from 4x?"),
        Experiment(name: "Buzz, other encoding (5B)", hex: "8301E905002E0EF55B", watch: "Red with the tail byte read the Flipper way (pattern in the high nibble)."),
        Experiment(name: "Candles, mode 2B", hex: "8301E200E90F00120F40565813488DD2462B1317B0", watch: "Your Oct 3 candles with mode byte 2A → 2B."),
        Experiment(name: "Candles, mode 03", hex: "8301E200E90F00120F40565813488DD246031317B0", watch: "Mode byte 2A → 03. 02 is centre pulse; is 03 something else?"),
        Experiment(name: "Twinkle, slow mode (0B)", hex: "8301E100E90E00040FB7A8B6ADA059190B48AEB0", watch: "Your Oct 3 twinkle with 02 → 0B near the end: slow twinkle per the listener."),
        Experiment(name: "Unseen length E90A", hex: "8301E90A002E0FB5B9A2A1B5B9B0", watch: "An E9 length nobody has captured, six colour bytes. Probably ignored."),
        Experiment(name: "Pink/cyan anim, 2nd pair changed", hex: "8301E100E90C00010F4D575A941519488BB0", watch: "Your most-played pattern with bytes 07 05 → 15 19. Does a second colour change?"),
        Experiment(name: "'RRC' ping (CC03 132000)", hex: "8301E100CC03132000", watch: "A ping variant from the Flipper list. No light expected — watch for anything."),
    ]

    /// E905 zone-mask options. 3 and 4 are agreed by both public decoders; the rest disagree.
    static let ledMasks: [(Int, String)] = [
        (7, "All LEDs"), (3, "Bottom-left (agreed)"), (4, "Top-left (agreed)"),
        (1, "Mask 1 (top-right or centre?)"), (2, "Mask 2 (bottom-right or top-right?)"),
        (5, "Mask 5 (unknown)"), (6, "Mask 6 (centre?)"), (0, "Mask 0 (all?)"),
    ]

    // MARK: - Editable colour slots (mirrors Android LabPacketBuilder.editableSlots)

    /// One recolourable byte: its label on the band and its index in the canonical hex string.
    struct ColorSlot { let label: String; let hexIndex: Int }

    private static let zones = ["BOT-L", "TOP-L", "CENTRE", "TOP-R", "BOT-R"]

    /// Recolourable bytes in any effect packet. Only the low 5 bits are ever rewritten.
    static func editableSlots(_ hexRaw: String) -> [ColorSlot] {
        let h = HexUtils.canonicalHex(hexRaw)
        let b = HexUtils.hexToBytes(h)
        guard b.count >= 2, b[0] == 0x83, b[1] == 0x01 else { return [] }
        var i = 2
        var vStart = -1, declared = 0, length = 0
        while i + 1 < b.count {
            let type = Int(b[i]), len = Int(b[i + 1])
            if type == 0xE9 { vStart = i + 2; declared = len; length = min(len, b.count - vStart); break }
            if type == 0xCF && len == 0x9B { break }
            i += 2 + len
        }
        guard vStart >= 0 else { return [] }
        func byte(_ k: Int) -> Int? { k < length ? Int(b[vStart + k]) : nil }
        func at(_ k: Int, _ label: String) -> ColorSlot? { k < length ? ColorSlot(label: label, hexIndex: (vStart + k) * 2) : nil }
        let body = HexUtils.bytesToHex(Array(b[vStart..<(vStart + length)]))
        let slots: [ColorSlot?]
        switch declared {
        case 0x05: slots = [at(3, "COLOR")]
        case 0x06, 0x0F: slots = [at(3, "CENTRE"), at(4, "CORNERS")]
        case 0x09, 0x0E: slots = (0..<5).map { at(3 + $0, zones[$0]) }
        case 0x0C: slots = ((byte(3) ?? 0) >> 5) == 2 ? [at(3, "COLOR 1"), at(4, "COLOR 2")] : []
        case 0x10: slots = [at(6, "COMET")]
        case 0x11: slots = body.contains("55515BF00F10374894D13D0508") ? [] : [at(3, "FROM"), at(4, "TO")]
        case 0x12: slots = [1, 2, 3, 4, 0].enumerated().map { at(3 + $0.offset, zones[$0.element]) }
        case 0x13: slots = [at(3, "CENTRE"), at(4, "PAIR B"), at(5, "PAIR A")]
        case 0x14: slots = (byte(7) == 0x02 || byte(7) == 0x05) ? [at(8, "COLOR")] : []
        default: slots = []
        }
        return slots.compactMap { $0 }
    }

    static func slotColors(_ hexRaw: String) -> [Int] {
        let chars = Array(HexUtils.canonicalHex(hexRaw))
        return editableSlots(hexRaw).map { s in (Int(String(chars[s.hexIndex..<(s.hexIndex + 2)]), radix: 16) ?? 0) & 0x1F }
    }

    /// Rewrite each slot's palette index from `colors` (in slot order), keeping its flag bits.
    static func withColors(_ hexRaw: String, _ colors: [Int]) -> String {
        let h = HexUtils.canonicalHex(hexRaw)
        var chars = Array(h)
        for (i, s) in editableSlots(h).enumerated() where i < colors.count {
            guard let old = Int(String(chars[s.hexIndex..<(s.hexIndex + 2)]), radix: 16) else { continue }
            let v = String(format: "%02X", (old & 0xE0) | (colors[i] & 0x1F))
            chars.replaceSubrange(s.hexIndex..<(s.hexIndex + 2), with: Array(v))
        }
        return String(chars)
    }

    static func paletteLabel(_ id: Int) -> String {
        paletteColors.first(where: { $0.id == (id & 0x1F) })?.label ?? labLabel(id)
    }

    // MARK: - Guided builder model (mirrors Android LabPacketBuilder.LabPacketType / Framing / build)

    /// A packet kind the Lab can compose end-to-end. `colorSlots` is how many palette colours the
    /// type carries; `supportsVib` whether the buzz controls apply.
    enum LabPacketType: String, CaseIterable, Identifiable {
        case preset, dual, crossfade, rainbow, rotate, circle, vibrate, show, ping, raw, rgb, experiment
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
            case .rgb: return "Custom RGB"
            case .experiment: return "Experiments"
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
            case .rgb: return "Any colour from red/green/blue sliders (E908, 6 bits each). Untested on a band."
            case .experiment: return "Packets that test something we don't know yet. Each says what to watch for."
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
            case .preset, .dual, .crossfade, .rainbow, .rotate, .circle, .vibrate, .rgb: return true
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
        case .rgb: return [63, 20, 0]
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
        (type == .crossfade || type == .rotate || type == .rgb) ? Framing(channelMarker: true, wakePrefix: false) : Framing(channelMarker: false, wakePrefix: false)
    }

    /// Shows, pings and raw hex are sent exactly as given.
    static func framingApplies(_ type: LabPacketType) -> Bool {
        type != .show && type != .ping && type != .raw && type != .experiment
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
        case .show:
            let show = showEffects.indices.contains(showIndex) ? showEffects[showIndex].1 : showEffects[0].1
            base = colors.isEmpty ? show : withColors(show, colors)
        case .ping: base = PacketBuilder.wakeupPing
        case .rgb: base = PacketBuilder.rgb(c(0, 63), c(1, 20), c(2, 0), vib: vib(enabled: vibEnabled, pattern: vibPattern))
        case .experiment:
            let e = experiments.indices.contains(showIndex) ? experiments[showIndex].hex : experiments[0].hex
            base = colors.isEmpty ? e : withColors(e, colors)
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
