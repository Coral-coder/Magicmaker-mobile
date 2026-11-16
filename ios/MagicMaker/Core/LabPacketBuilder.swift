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

    /// Unique label for every 5-bit palette index (0x00–0x1F).
    static func labLabel(_ index: Int) -> String {
        let i = index & 0x1F
        return "#" + DisneyTlv.hex2(i) + " " + StarlightColors.nameFor(i)
    }

    /// Full EMCOT palette for dual / crossfade / rainbow dropdowns.
    static let paletteColors: [PaletteColor] = StarlightColors.palette.keys.sorted().map { (index: Int) -> PaletteColor in
        PaletteColor(id: index, label: LabPacketBuilder.labLabel(index))
    }

    /// Named primaries for quick preset chips (`PacketBuilder.Color` constants).
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
        ("Rainbow FX", PacketBuilder.rainbowFinale),
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

    static let vibrationPatterns: [VibrationPattern] = [
        VibrationPattern(id: 0, label: "Off"),
        VibrationPattern(id: 1, label: "Short"),
        VibrationPattern(id: 2, label: "Double"),
        VibrationPattern(id: 3, label: "Triple"),
        VibrationPattern(id: 4, label: "Quad"),
        VibrationPattern(id: 5, label: "Burst"),
        VibrationPattern(id: 6, label: "Pulse 6"),
        VibrationPattern(id: 7, label: "Pulse 7"),
        VibrationPattern(id: 8, label: "Long"),
        VibrationPattern(id: 9, label: "Pattern 9"),
        VibrationPattern(id: 10, label: "Pattern 10"),
        VibrationPattern(id: 11, label: "Pattern 11"),
        VibrationPattern(id: 12, label: "Pattern 12"),
        VibrationPattern(id: 13, label: "Pattern 13"),
        VibrationPattern(id: 14, label: "Pattern 14"),
        VibrationPattern(id: 15, label: "Pattern 15"),
    ]

    static func vib(enabled: Bool, pattern: Int) -> Int {
        enabled ? max(0, min(15, pattern)) : PacketBuilder.Vibration.off
    }

    static func buildPreset(colorName: String, vibEnabled: Bool, vibPattern: Int) -> String {
        PacketBuilder.preset(color: PacketBuilder.colorFromName(colorName), vib: vib(enabled: vibEnabled, pattern: vibPattern))
    }

    static func buildPresetById(_ colorId: Int, vibEnabled: Bool, vibPattern: Int) -> String {
        PacketBuilder.preset(color: colorId & 0x1F, vib: vib(enabled: vibEnabled, pattern: vibPattern))
    }

    /// Same as `buildPresetById`, under the name the Lab screen already uses.
    static func buildPreset(colorId: Int, vibEnabled: Bool, vibPattern: Int) -> String {
        buildPresetById(colorId, vibEnabled: vibEnabled, vibPattern: vibPattern)
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

    static func buildPing() -> String { PacketBuilder.wakeupPing }

    static func buildRainbowFinale() -> String { PacketBuilder.rainbowFinale }

    static func buildVibrate(vibEnabled: Bool, vibPattern: Int) -> String {
        PacketBuilder.vibrateBand(vib: vib(enabled: vibEnabled, pattern: vibPattern))
    }

    static func paletteLabel(_ id: Int) -> String {
        paletteColors.first(where: { $0.id == (id & 0x1F) })?.label ?? labLabel(id)
    }

    static func paletteId(_ label: String) -> Int {
        let wanted = label.lowercased()
        if let match = paletteColors.first(where: { $0.label.lowercased() == wanted }) {
            return match.id
        }
        return PacketBuilder.colorFromName(label)
    }

    // MARK: - Guided builder model
    // Pick a `LabPacketType` first, then fill only the fields that type uses (colour slots +
    // vibration). `decode` does the reverse: load a received packet and recover its type, colour
    // slots and vibration so the builder fields can be populated for editing.

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

        /// Only offered when the Lab's Extended switch is on.
        var experimental: Bool {
            self == .rgb || self == .experiment
        }
    }

    // MARK: - Extended mode

    /// Only offered when the Lab's Extended switch is on.
    static func isExperimental(_ t: LabPacketType) -> Bool { t.experimental }

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

    /// Default colour slots for a freshly selected type (sensible starting palette).
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
        switch type {
        case .crossfade, .rotate, .rgb: return Framing(channelMarker: true, wakePrefix: false)
        default: return Framing(channelMarker: false, wakePrefix: false)
        }
    }

    /// Types whose framing the user can change. Shows, pings and raw hex are sent exactly as given.
    static func framingApplies(_ type: LabPacketType) -> Bool {
        type != .show && type != .ping && type != .raw && type != .experiment
    }

    private static let channel1Hex = "E100"
    private static let wakePrefixHex = "CC03000100"

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
        func c(_ i: Int, _ fallback: Int) -> Int {
            if i >= 0 && i < colors.count { return colors[i] }
            return fallback
        }
        let base: String
        switch type {
        case .preset:
            base = buildPresetById(c(0, PacketBuilder.Color.cyan), vibEnabled: vibEnabled, vibPattern: vibPattern)
        case .dual:
            base = buildDual(c(0, PacketBuilder.Color.yellowOrange), c(1, PacketBuilder.Color.blue), vibEnabled: vibEnabled, vibPattern: vibPattern)
        case .crossfade:
            base = buildCrossfade(c(0, PacketBuilder.Color.red), c(1, PacketBuilder.Color.blue), vibEnabled: vibEnabled, vibPattern: vibPattern)
        case .rainbow:
            base = buildRainbow(c(0, PacketBuilder.Color.yellowOrange), c(1, PacketBuilder.Color.red), c(2, PacketBuilder.Color.green),
                                c(3, PacketBuilder.Color.blue), c(4, PacketBuilder.Color.purple), vibEnabled: vibEnabled, vibPattern: vibPattern)
        case .circle:
            base = buildCircle(vibEnabled: vibEnabled, vibPattern: vibPattern, colors: colors)
        case .rotate:
            base = PacketBuilder.rotate(c(0, 0x02), c(1, 0x02), c(2, 0x02), c(3, 0x04), c(4, 0x04), vib: vib(enabled: vibEnabled, pattern: vibPattern))
        case .vibrate:
            base = buildVibrate(vibEnabled: vibEnabled, vibPattern: vibPattern)
        case .show:
            let show: String = showEffects.indices.contains(showIndex) ? showEffects[showIndex].1 : showEffects[0].1
            base = colors.isEmpty ? show : withColors(show, colors)
        case .ping:
            base = buildPing()
        case .rgb:
            base = PacketBuilder.rgb(c(0, 63), c(1, 20), c(2, 0), vib: vib(enabled: vibEnabled, pattern: vibPattern))
        case .experiment:
            let e: String = experiments.indices.contains(showIndex) ? experiments[showIndex].hex : experiments[0].hex
            base = colors.isEmpty ? e : withColors(e, colors)
        case .raw:
            base = HexUtils.canonicalHex(rawHex)
        }
        if !framingApplies(type) { return base }
        let f: Framing = framing ?? defaultFraming(type)
        // Strip whatever framing the primitive builder baked in, then apply the requested one.
        var body = base
        if body.hasPrefix("8301") { body.removeFirst(4) }
        if body.hasPrefix(wakePrefixHex) { body.removeFirst(wakePrefixHex.count) }
        if body.hasPrefix(channel1Hex) { body.removeFirst(channel1Hex.count) }
        var framed = "8301"
        if f.wakePrefix { framed += wakePrefixHex }
        if f.channelMarker { framed += channel1Hex }
        framed += body
        return PacketBuilder.withTiming(framed, f.timing)
    }

    // MARK: - Random light show
    // Each call composes one surprise packet — random type, random colours, occasional haptic
    // accent — so a loop of these plays as a varied show rather than a strobe of the same effect.

    /// Palette ids the show can pick — everything except Off so the band never goes dark.
    private static let showPaletteIds: [Int] = LabPacketBuilder.paletteColors
        .map { (c: PaletteColor) -> Int in c.id }
        .filter { (id: Int) -> Bool in id != PacketBuilder.Color.off && id != PacketBuilder.Color.random }

    /// Captured show effects minus the blackout packet, for the same reason.
    private static let randomShowEffects: [(String, String)] = LabPacketBuilder.showEffects.filter { (e: (String, String)) -> Bool in
        e.0 != "Show Off" && !e.0.hasSuffix("Lights off")
    }

    private static func randomShowColor<G: RandomNumberGenerator>(using rng: inout G) -> Int {
        showPaletteIds.randomElement(using: &rng) ?? PacketBuilder.Color.cyan
    }

    /// One random light-show step, with its label. Weighted toward the colourful/animated types;
    /// vibration fires on roughly one packet in five so the buzz stays an accent, not a drone.
    static func buildRandomShowStep<G: RandomNumberGenerator>(using rng: inout G) -> (label: String, hex: String) {
        let vibOn: Bool = Int.random(in: 0..<5, using: &rng) == 0
        var vibPat = 0
        if vibOn { vibPat = Int.random(in: 1..<9, using: &rng) }
        let roll: Int = Int.random(in: 0..<16, using: &rng)
        switch roll {
        case 0...3:
            let c = randomShowColor(using: &rng)
            let label = "Show: " + StarlightColors.nameFor(c)
            return (label: label, hex: buildPresetById(c, vibEnabled: vibOn, vibPattern: vibPat))
        case 4...6:
            let a = randomShowColor(using: &rng)
            let b = randomShowColor(using: &rng)
            let label = "Show: Dual " + StarlightColors.nameFor(a) + "/" + StarlightColors.nameFor(b)
            return (label: label, hex: buildDual(a, b, vibEnabled: vibOn, vibPattern: vibPat))
        case 7...9:
            let a = randomShowColor(using: &rng)
            let b = randomShowColor(using: &rng)
            let label = "Show: Fade " + StarlightColors.nameFor(a) + "→" + StarlightColors.nameFor(b)
            return (label: label, hex: buildCrossfade(a, b, vibEnabled: vibOn, vibPattern: vibPat))
        case 10...12:
            let c1 = randomShowColor(using: &rng)
            let c2 = randomShowColor(using: &rng)
            let c3 = randomShowColor(using: &rng)
            let c4 = randomShowColor(using: &rng)
            let c5 = randomShowColor(using: &rng)
            return (label: "Show: Rainbow mix", hex: buildRainbow(c1, c2, c3, c4, c5, vibEnabled: vibOn, vibPattern: vibPat))
        case 13:
            return (label: "Show: Circle spin", hex: buildCircle(vibEnabled: vibOn, vibPattern: vibPat))
        default:
            guard let pick = randomShowEffects.randomElement(using: &rng) else {
                return (label: "Show: Circle spin", hex: buildCircle(vibEnabled: vibOn, vibPattern: vibPat))
            }
            return (label: "Show: " + pick.0, hex: pick.1)
        }
    }

    static func buildRandomShowStep() -> (label: String, hex: String) {
        var rng = SystemRandomNumberGenerator()
        return buildRandomShowStep(using: &rng)
    }

    /// The hex of one random light-show step; `buildRandomShowStep` also gives its label.
    static func buildRandomShow<G: RandomNumberGenerator>(using rng: inout G) -> String {
        buildRandomShowStep(using: &rng).hex
    }

    static func buildRandomShow() -> String {
        var rng = SystemRandomNumberGenerator()
        return buildRandomShow(using: &rng)
    }

    // MARK: - Editable colour slots
    // What makes Park Shows and loaded packets recolourable. Positions come from docs/PROTOCOL.md
    // §6a/§6b. Only the low 5 bits (the palette index) are rewritten; the high 3 bits (slot flag /
    // zone mask) are kept as captured.

    /// One recolourable byte: its label on the band and its index in the canonical hex string.
    struct ColorSlot { let label: String; let hexIndex: Int }

    private static let zones: [String] = ["BOT-L", "TOP-L", "CENTRE", "TOP-R", "BOT-R"]

    /// Recolourable bytes in any effect packet. Only the low 5 bits are ever rewritten.
    static func editableSlots(_ hexRaw: String) -> [ColorSlot] {
        let h = HexUtils.canonicalHex(hexRaw)
        guard let parsed = DisneyTlv.parse(h) else { return [] }
        var off = 4
        var valueStart = -1
        var rec: DisneyTlv.Record? = nil
        for r in parsed.records {
            if r.type == DisneyTlv.typeEffect {
                valueStart = off + 4
                rec = r
                break
            }
            off += 4 + r.length * 2
        }
        guard let e = rec else { return [] }
        let start = valueStart
        func at(_ i: Int, _ label: String) -> ColorSlot? {
            if i < e.length { return ColorSlot(label: label, hexIndex: start + i * 2) }
            return nil
        }
        var slots: [ColorSlot?] = []
        switch e.declaredLength {
        case 0x05:
            slots = [at(3, "COLOR")]
        case 0x06, 0x0F:
            slots = [at(3, "CENTRE"), at(4, "CORNERS")]
        case 0x09, 0x0E:
            for z in 0..<5 { slots.append(at(3 + z, zones[z])) }
        case 0x0C:
            let flag = (e.byte(3) ?? 0) >> 5
            if flag == 2 { slots = [at(3, "COLOR 1"), at(4, "COLOR 2")] }
        case 0x10:
            slots = [at(6, "COMET")]
        case 0x11:
            let pirateCannon = e.valueHex().contains("55515BF00F10374894D13D0508")
            if !pirateCannon { slots = [at(3, "FROM"), at(4, "TO")] }
        case 0x12:
            // E912 colour bytes are in zone order Z2, Z3, Z4, Z5, Z1.
            let order: [Int] = [1, 2, 3, 4, 0]
            for (i, z) in order.enumerated() { slots.append(at(3 + i, zones[z])) }
        case 0x13:
            slots = [at(3, "CENTRE"), at(4, "PAIR B"), at(5, "PAIR A")]
        case 0x14:
            let mode = e.byte(7) ?? -1
            if mode == 0x02 || mode == 0x05 { slots = [at(8, "COLOR")] }
        default:
            break
        }
        return slots.compactMap { $0 }
    }

    /// The hex byte at `index` of a canonical hex string, or nil when it is out of range.
    private static func hexByte(_ chars: [Character], _ index: Int) -> Int? {
        if index < 0 || index + 2 > chars.count { return nil }
        return Int(String(chars[index..<(index + 2)]), radix: 16)
    }

    static func slotColors(_ hexRaw: String) -> [Int] {
        let h = HexUtils.canonicalHex(hexRaw)
        let chars: [Character] = Array(h)
        return editableSlots(h).map { (s: ColorSlot) -> Int in
            (hexByte(chars, s.hexIndex) ?? 0) & 0x1F
        }
    }

    /// Rewrite each slot's palette index from `colors` (in slot order), keeping its flag bits.
    static func withColors(_ hexRaw: String, _ colors: [Int]) -> String {
        let h = HexUtils.canonicalHex(hexRaw)
        let original: [Character] = Array(h)
        var chars = original
        for (i, s) in editableSlots(h).enumerated() {
            if i >= colors.count { continue }
            guard let old = hexByte(original, s.hexIndex) else { continue }
            let v = DisneyTlv.hex2((old & 0xE0) | (colors[i] & 0x1F))
            chars.replaceSubrange(s.hexIndex..<(s.hexIndex + 2), with: Array(v))
        }
        return String(chars)
    }

    // MARK: - Decode

    /// Recovered builder state from a captured/loaded packet.
    struct Decoded: Equatable {
        let type: LabPacketType
        let colors: [Int]
        let vibEnabled: Bool
        let vibPattern: Int
        let rawHex: String
        let framing: Framing
        let showIndex: Int

        init(
            type: LabPacketType,
            colors: [Int],
            vibEnabled: Bool,
            vibPattern: Int,
            rawHex: String,
            framing: Framing? = nil,
            showIndex: Int = 0
        ) {
            self.type = type
            self.colors = colors
            self.vibEnabled = vibEnabled
            self.vibPattern = vibPattern
            self.rawHex = rawHex
            self.framing = framing ?? LabPacketBuilder.defaultFraming(type)
            self.showIndex = showIndex
        }
    }

    /// Parse a received packet back into editable builder fields by walking its TLV records.
    /// Field-decodes the shapes the builder can rebuild (E905/E906/E909/E90B/E911) and recognises
    /// the captured park shows; anything else comes back as `.raw` with the hex preserved so it
    /// can still be tweaked byte-by-byte. Nil only for an empty packet.
    static func decode(_ hexRaw: String) -> Decoded? {
        let h = HexUtils.canonicalHex(hexRaw)
        if h.count < 4 { return nil }

        let tailVib: Int = LabPacketTools.tailVibration(h) ?? 0
        let vibEnabled: Bool = tailVib > 0
        let vibPattern: Int = tailVib > 0 ? tailVib : PacketBuilder.Vibration.triple

        func raw() -> Decoded {
            Decoded(type: .raw, colors: [], vibEnabled: vibEnabled, vibPattern: vibPattern, rawHex: h)
        }

        // A show heard with different colours still loads as that show, with its colours editable.
        let upperH = h.uppercased()
        let slotCount = editableSlots(h).count
        if slotCount > 0 {
            let masked = withColors(h, [Int](repeating: 0, count: slotCount))
            for (idx, show) in showEffects.enumerated() {
                let s: String = show.1
                if s.count != h.count { continue }
                if s.uppercased() == upperH { continue }
                let zeros = [Int](repeating: 0, count: editableSlots(s).count)
                if withColors(s, zeros) == masked {
                    return Decoded(type: .show, colors: slotColors(h), vibEnabled: false, vibPattern: vibPattern, rawHex: h, showIndex: idx)
                }
            }
        }
        for (idx, show) in showEffects.enumerated() {
            if show.1.uppercased() == upperH {
                return Decoded(type: .show, colors: [], vibEnabled: false, vibPattern: vibPattern, rawHex: h, showIndex: idx)
            }
        }

        guard let parsed = DisneyTlv.parse(h), let first = parsed.records.first else { return raw() }
        guard let effect = parsed.effect else {
            if first.type == DisneyTlv.typePing {
                return Decoded(type: .ping, colors: [], vibEnabled: false, vibPattern: vibPattern, rawHex: h)
            }
            return raw()
        }

        // Report a named timing only when it differs from what the shape's own template carries,
        // so decode(build(x)) gives back x's framing exactly.
        let templateTiming: Int
        switch effect.declaredLength {
        case 0x05, 0x09: templateTiming = 0x2E
        case 0x06: templateTiming = 0x22
        case 0x0B: templateTiming = 0x0F
        case 0x11: templateTiming = 0x6F
        case 0x12: templateTiming = 0x03
        default: templateTiming = -1
        }
        var timing: Int = PacketBuilder.Timing.default
        if let timingByte = effect.byte(1), timingByte != templateTiming {
            let named = PacketBuilder.Timing.options.contains(where: { $0.0 == timingByte })
            if named { timing = timingByte }
        }
        let framing = Framing(
            channelMarker: parsed.channel != nil,
            wakePrefix: first.type == DisneyTlv.typePing,
            timing: timing
        )

        // Palette colours sit at value[3..] of the effect record, low 5 bits.
        func colorsAt(_ n: Int) -> [Int]? {
            if effect.length < 3 + n { return nil }
            var out: [Int] = []
            for i in 0..<n {
                guard let b = effect.byte(3 + i) else { return nil }
                out.append(b & 0x1F)
            }
            return out
        }
        func fields(_ type: LabPacketType, _ colors: [Int]?) -> Decoded {
            guard let c = colors else { return raw() }
            return Decoded(type: type, colors: c, vibEnabled: vibEnabled, vibPattern: vibPattern, rawHex: h, framing: framing)
        }

        switch effect.length {
        case 0x05: return fields(.preset, colorsAt(1))
        case 0x06: return fields(.dual, colorsAt(2))
        case 0x09: return fields(.rainbow, colorsAt(5))
        case 0x0B: return fields(.circle, colorsAt(7))
        case 0x08:
            // E908 custom RGB: six-bit channels shifted left one, at body[4..6].
            var channels: [Int] = []
            for i in 4...6 { channels.append(((effect.byte(i) ?? 0) >> 1) & 0x3F) }
            return fields(.rgb, channels)
        case 0x11: return fields(.crossfade, colorsAt(2))
        case 0x12:
            // E912 colour bytes are in zone order Z2, Z3, Z4, Z5, Z1 — present them as Z1..Z5.
            guard let c = colorsAt(5), c.count == 5 else { return raw() }
            return fields(.rotate, [c[4], c[0], c[1], c[2], c[3]])
        default: return raw()
        }
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

    /// Every real code in the range, low-to-high, as ready-to-transmit packets.
    static let packets: [MagicPacket] = {
        var out: [MagicPacket] = []
        for v in NewWandCatalog.rangeStart...NewWandCatalog.rangeEnd {
            if NewWandCatalog.excluded.contains(v) { continue }
            let code = String(format: "%03X", v)
            let hex = NewWandCatalog.prefix + code
            let colorIndex = (Int(hex.suffix(2), radix: 16) ?? 0) & 0x1F
            out.append(MagicPacket(
                id: NewWandCatalog.idBase + Int64(v - NewWandCatalog.rangeStart),
                hex: hex,
                label: "New Wand " + code,
                category: .color,
                typeInfo: "newwand",
                colors: StarlightColors.nameFor(colorIndex),
                simKey: "NEWWAND:" + hex
            ))
        }
        return out
    }()

    // Ids are not contiguous (excluded range), so look up by id rather than index.
    static func byId(_ id: Int64) -> MagicPacket? { packets.first(where: { $0.id == id }) }
    static func isNewWandId(_ id: Int64) -> Bool { id >= idBase }
    static func randomHex() -> String? { packets.randomElement()?.hex }
}

/// The tap-token beacon as Android `MbleBeaconBuilder.kt` builds it. The enum itself (with
/// `manufacturerId` and `beaconId`) is declared next to the MDE theme catalogue.
extension MbleBeaconBuilder {
    /// AltBeacon layout on manufacturer 0x0183.
    static let beaconLayout = "m:2-3=0F11,i:2-4,i:5-19,p:20-20"

    /// 0F11 prefix + 2-byte id + 14-byte token body + 1-byte power (the token's last byte).
    /// Nil when the token is shorter than two bytes.
    static func manufacturerPayload(_ tokenHex: String) -> [UInt8]? {
        let token = tokenHex.uppercased().filter { "0123456789ABCDEF".contains($0) }
        if token.count < 4 { return nil }
        guard let txPower = UInt8(String(token.suffix(2)), radix: 16) else { return nil }
        var out: [UInt8] = [0x0F, 0x11]
        out.append(contentsOf: hexToFixedBytes(beaconId, 2))
        out.append(contentsOf: hexToFixedBytes(token, 14))
        out.append(txPower)
        return out
    }

    /// The last `byteCount` bytes of `hex`, left-padded with zeros when it is shorter.
    private static func hexToFixedBytes(_ hex: String, _ byteCount: Int) -> [UInt8] {
        let want = byteCount * 2
        var chars: [Character] = Array(hex)
        if chars.count < want {
            chars = [Character](repeating: "0", count: want - chars.count) + chars
        } else if chars.count > want {
            chars = Array(chars[(chars.count - want)...])
        }
        var out: [UInt8] = []
        out.reserveCapacity(byteCount)
        for i in 0..<byteCount {
            out.append(UInt8(String(chars[(i * 2)..<(i * 2 + 2)]), radix: 16) ?? 0)
        }
        return out
    }
}
