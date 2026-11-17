import SwiftUI

/// The Lab's packet composer. Port of Android `LabPacketBuilderPanel`, `PacketSummaryCard` and
/// `PacketAnatomy`: pick what the band should do, set its colours, read in words what the packet
/// does and how its bytes break down.
///
/// Nothing in here transmits. Every change the user makes in the builder lands in the hex field
/// (`onHexBuilt`), and the Lab screen's one SEND button is the only thing that puts a packet on
/// the air. A packet sent to the Lab from another screen (`loadTick`) or LOAD HEX is decoded back
/// into these fields without being written over the hex field, so the loaded packet is still
/// what SEND sends until the user changes something here.
struct LabBuilderPanel: View {
    let enabled: Bool
    let extended: Bool
    /// The Lab's hex field.
    let loadedHex: String
    /// Above zero once a packet has been sent to the Lab; each change decodes `loadedHex` again.
    let loadTick: Int
    /// The builder's live packet, for the band preview.
    let onHexChanged: (String) -> Void
    /// Puts a packet in the hex field.
    let onHexBuilt: (String) -> Void

    @State private var selectedType: LabPacketBuilder.LabPacketType = .preset
    @State private var colors: [Int] = LabPacketBuilder.defaultColors(.preset)
    @State private var vibEnabled: Bool = false
    @State private var vibPattern: Int = PacketBuilder.Vibration.triple
    @State private var rawHex: String = ""
    @State private var framing: LabPacketBuilder.Framing = LabPacketBuilder.defaultFraming(.preset)
    @State private var showIndex: Int = 0
    /// Extended only: E905 zone mask (high 3 bits of the colour byte). 7 = all LEDs.
    @State private var ledMask: Int = 7
    @State private var loadMsg: String? = nil
    /// The builder packet a load produced. It describes the loaded packet, so it is not written
    /// over the hex field; the next change the user makes is.
    @State private var heldHex: String? = nil

    init(
        enabled: Bool = true,
        extended: Bool = false,
        loadedHex: String,
        loadTick: Int = 0,
        onHexChanged: @escaping (String) -> Void = { _ in },
        onHexBuilt: @escaping (String) -> Void
    ) {
        self.enabled = enabled
        self.extended = extended
        self.loadedHex = loadedHex
        self.loadTick = loadTick
        self.onHexChanged = onHexChanged
        self.onHexBuilt = onHexBuilt
    }

    /// What the builder currently describes (Android `currentHex`).
    private var builtHex: String {
        let base: String = LabPacketBuilder.build(
            type: selectedType,
            colors: colors,
            vibEnabled: vibEnabled,
            vibPattern: vibPattern,
            rawHex: rawHex,
            framing: framing,
            showIndex: showIndex
        )
        // ledMask is only off 7 while Extended is on (applyExtended resets it), so this does not
        // read `extended`: the switch itself must not change the packet before it is held.
        if selectedType == .preset && ledMask != 7 {
            return PacketBuilder.withZoneMask(base, ledMask)
        }
        return base
    }

    var body: some View {
        let current: String = builtHex
        VStack(alignment: .leading, spacing: 8) {
            typeSection
            LabPacketSummaryCard(hex: current)
            typeFields
            framingSection
            if !current.isEmpty {
                LabPacketAnatomyView(hex: current)
            }
            actionRow(current)
        }
        .onAppear { appeared() }
        .onChange(of: current) { _, newHex in
            builderHexChanged(newHex)
        }
        .onChange(of: loadTick) { _, tick in
            if tick > 0 { decodeLoaded() }
        }
        .onChange(of: extended) { _, on in
            applyExtended(on)
            holdBuiltHex()
        }
    }

    // MARK: - Type

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WHAT DO YOU WANT THE BAND TO DO?")
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.cyanDim)
            typeChips
            dimText(selectedType.blurb)
            if let loadMsg {
                Text(loadMsg)
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.cyan)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Always-visible type chips, wrapped onto as many rows as they need; the selected one is filled.
    private var typeChips: some View {
        let flow = LabFlowLayout(spacing: 6)
        return flow {
            ForEach(visibleTypes) { type in
                typeChip(type)
            }
        }
    }

    private var visibleTypes: [LabPacketBuilder.LabPacketType] {
        LabPacketBuilder.LabPacketType.allCases.filter { (type: LabPacketBuilder.LabPacketType) -> Bool in
            extended || !type.experimental
        }
    }

    @ViewBuilder
    private func typeChip(_ type: LabPacketBuilder.LabPacketType) -> some View {
        if type == selectedType {
            Button {
                select(type)
            } label: {
                Text(type.label.uppercased())
                    .font(MMTheme.techLabel(9))
            }
            .buttonStyle(.borderedProminent)
            .tint(MMTheme.cyan)
        } else {
            Button {
                select(type)
            } label: {
                Text(type.label.uppercased())
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.cyan)
            }
            .buttonStyle(.bordered)
            .tint(MMTheme.cyan)
        }
    }

    // MARK: - Fields for the chosen type

    @ViewBuilder
    private var typeFields: some View {
        switch selectedType {
        case .raw:
            rawFields
        case .ping:
            dimText("Nothing to set. Send this just before a command if a band isn't reacting.")
        case .rgb:
            rgbSliders
            buzzRow
        case .experiment:
            experimentFields
        case .show:
            showFields
        default:
            standardFields
        }
    }

    private var rawFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RAW HEX (8301…)")
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.cyanDim)
            TextField("RAW HEX (8301…)", text: rawHexBinding)
                .labBuilderField()
            // Any loaded packet whose shape we understand gets its colours as pickers too.
            slotPickers(for: builtHex) { picked in
                rawHex = LabPacketBuilder.withColors(rawHex, picked)
            }
        }
    }

    private var rawHexBinding: Binding<String> {
        Binding(
            get: { rawHex },
            set: { typed in rawHex = typed.uppercased() }
        )
    }

    private var experimentFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabPalettePicker(label: "TEST", selection: showBinding, options: LabBuilderPanel.experimentOptions)
            Text("WATCH FOR: " + currentExperiment.watch)
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.amber)
                .fixedSize(horizontal: false, vertical: true)
            slotPickers(for: builtHex) { picked in
                colors = picked
            }
        }
    }

    private var showFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabPalettePicker(label: "SHOW", selection: showBinding, options: LabBuilderPanel.showOptions)
            dimText("Recorded in the park. Change any colour below; everything else is replayed byte-for-byte.")
            slotPickers(for: builtHex) { picked in
                colors = picked
            }
        }
    }

    /// Picking a show or an experiment starts from its captured colours.
    private var showBinding: Binding<Int> {
        Binding(
            get: { showIndex },
            set: { picked in
                showIndex = picked
                colors = []
            }
        )
    }

    private var currentExperiment: LabPacketBuilder.Experiment {
        let list: [LabPacketBuilder.Experiment] = LabPacketBuilder.experiments
        if showIndex >= 0 && showIndex < list.count {
            return list[showIndex]
        }
        return list.first ?? LabPacketBuilder.Experiment(name: "", hex: "", watch: "")
    }

    private var standardFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            if extended && selectedType == .preset {
                LabPalettePicker(label: "LEDS", selection: $ledMask, options: LabPacketBuilder.ledMasks)
                Text("Experimental: the top 3 bits of the colour byte pick which LEDs light. Two values are agreed; tell me what the rest do.")
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if selectedType.colorSlots > 0 {
                Text(selectedType.colorSlots == 1 ? "COLOR" : "COLORS")
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.cyanDim)
                colorSlots
            }
            if selectedType.supportsVib {
                buzzRow
            }
        }
    }

    private var buzzRow: some View {
        HStack(spacing: 8) {
            Text("BUZZ")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.cyanDim)
            Toggle("", isOn: $vibEnabled)
                .labelsHidden()
                .tint(MMTheme.cyan)
            if vibEnabled {
                LabPalettePicker(label: "PATTERN", selection: $vibPattern, options: LabBuilderPanel.vibrationOptions)
            }
            Spacer(minLength: 0)
        }
    }

    /// One palette picker per colour slot the type carries; the full palette for each.
    private var colorSlots: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<selectedType.colorSlots, id: \.self) { index in
                LabPalettePicker(
                    label: slotLabel(index),
                    selection: colorBinding(index),
                    options: LabBuilderPanel.paletteOptions
                )
            }
        }
    }

    private func colorBinding(_ index: Int) -> Binding<Int> {
        Binding(
            get: { (index >= 0 && index < colors.count) ? colors[index] : 0 },
            set: { picked in
                if index < 0 { return }
                var next: [Int] = colors
                while next.count <= index { next.append(0) }
                next[index] = picked
                colors = next
            }
        )
    }

    private func slotLabel(_ index: Int) -> String {
        switch selectedType {
        case .dual:
            return index == 0 ? "INNER" : "OUTER"
        case .crossfade:
            return index == 0 ? "FROM" : "TO"
        case .circle:
            return "P\(index + 1)"
        case .rainbow, .rotate:
            // Five LEDs: Z1 bottom-left, Z2 top-left, Z3 centre, Z4 top-right, Z5 bottom-right.
            let zones: [String] = ["BOT-L", "TOP-L", "CENTRE", "TOP-R", "BOT-R"]
            return (index >= 0 && index < zones.count) ? zones[index] : "\(index + 1)"
        default:
            return "\(index + 1)"
        }
    }

    /// Colour pickers for whatever recolourable bytes `hex` carries, labelled by where they land
    /// on the band. `onChange` gets the full list in slot order.
    @ViewBuilder
    private func slotPickers(for hex: String, onChange: @escaping ([Int]) -> Void) -> some View {
        let slots: [LabPacketBuilder.ColorSlot] = LabPacketBuilder.editableSlots(hex)
        let values: [Int] = LabPacketBuilder.slotColors(hex)
        if !slots.isEmpty && values.count == slots.count {
            Text("COLORS")
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.cyanDim)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<slots.count, id: \.self) { index in
                    LabPalettePicker(
                        label: slots[index].label,
                        selection: slotBinding(values, index, onChange),
                        options: LabBuilderPanel.paletteOptions
                    )
                }
            }
        }
    }

    private func slotBinding(_ values: [Int], _ index: Int, _ onChange: @escaping ([Int]) -> Void) -> Binding<Int> {
        Binding(
            get: { (index >= 0 && index < values.count) ? values[index] : 0 },
            set: { picked in
                if index < 0 || index >= values.count { return }
                var next: [Int] = values
                next[index] = picked
                onChange(next)
            }
        )
    }

    // MARK: - Custom RGB

    private static let rgbNames: [String] = ["RED", "GREEN", "BLUE"]
    private static let rgbTints: [Color] = [
        Color(red: 1.0, green: 82.0 / 255.0, blue: 82.0 / 255.0),
        Color(red: 105.0 / 255.0, green: 240.0 / 255.0, blue: 174.0 / 255.0),
        Color(red: 68.0 / 255.0, green: 138.0 / 255.0, blue: 1.0),
    ]

    /// Red / green / blue sliders, 0-63 each (E908 is six bits per channel), with a live swatch.
    private var rgbSliders: some View {
        let rgb: [Int] = LabBuilderPanel.rgbChannels(colors)
        return VStack(alignment: .leading, spacing: 4) {
            rgbSwatchRow(rgb)
            ForEach(0..<3, id: \.self) { index in
                rgbSliderRow(index, rgb)
            }
        }
    }

    /// Always three channels, each clamped to 0...63.
    private static func rgbChannels(_ values: [Int]) -> [Int] {
        var out: [Int] = []
        for index in 0..<3 {
            let value: Int = index < values.count ? values[index] : 0
            out.append(min(max(value, 0), 63))
        }
        return out
    }

    private func rgbSwatchRow(_ rgb: [Int]) -> some View {
        let r8: Int = rgb[0] * 255 / 63
        let g8: Int = rgb[1] * 255 / 63
        let b8: Int = rgb[2] * 255 / 63
        let swatch: Color = Color(red: Double(r8) / 255.0, green: Double(g8) / 255.0, blue: Double(b8) / 255.0)
        let hexText: String = "#" + DisneyTlv.hex2(r8) + DisneyTlv.hex2(g8) + DisneyTlv.hex2(b8)
        let caption: String = "R \(rgb[0]) · G \(rgb[1]) · B \(rgb[2])  (\(hexText))"
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(swatch)
                .frame(width: 28, height: 28)
            Text(caption)
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
        }
    }

    private func rgbSliderRow(_ index: Int, _ rgb: [Int]) -> some View {
        let tint: Color = index < LabBuilderPanel.rgbTints.count ? LabBuilderPanel.rgbTints[index] : MMTheme.cyan
        let name: String = index < LabBuilderPanel.rgbNames.count ? LabBuilderPanel.rgbNames[index] : ""
        return HStack(spacing: 6) {
            Text(name)
                .font(MMTheme.techLabel(9))
                .foregroundStyle(tint)
                .frame(width: 52, alignment: .leading)
            Slider(value: rgbBinding(index, rgb), in: 0...63, step: 1)
                .tint(tint)
        }
    }

    private func rgbBinding(_ index: Int, _ rgb: [Int]) -> Binding<Double> {
        Binding(
            get: { (index >= 0 && index < rgb.count) ? Double(rgb[index]) : 0 },
            set: { value in
                if index < 0 || index >= rgb.count || !value.isFinite { return }
                var next: [Int] = rgb
                next[index] = min(max(Int(value.rounded()), 0), 63)
                colors = next
            }
        )
    }

    // MARK: - Framing

    @ViewBuilder
    private var framingSection: some View {
        if LabPacketBuilder.framingApplies(selectedType) {
            VStack(alignment: .leading, spacing: 6) {
                Text("FRAMING")
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.cyanDim)
                framingToggle(
                    "Channel marker (E1 00)",
                    detail: "Every effect recorded in the park carries this before the effect record. The esp32 presets never did. Try both — one may work where the other doesn't.",
                    isOn: channelMarkerBinding
                )
                LabPalettePicker(label: "DURATION", selection: timingBinding, options: PacketBuilder.Timing.options)
                dimText("How long the band holds the effect — the timing byte. Default keeps the shape's own value (~21 s for the colour presets).")
                framingToggle(
                    "Wake ping first (CC03 000100)",
                    detail: "Tells nearby bands to listen before the effect arrives. The captured show packets all start this way.",
                    isOn: wakePrefixBinding
                )
            }
        }
    }

    private var channelMarkerBinding: Binding<Bool> {
        Binding(
            get: { framing.channelMarker },
            set: { on in
                var next: LabPacketBuilder.Framing = framing
                next.channelMarker = on
                framing = next
            }
        )
    }

    private var wakePrefixBinding: Binding<Bool> {
        Binding(
            get: { framing.wakePrefix },
            set: { on in
                var next: LabPacketBuilder.Framing = framing
                next.wakePrefix = on
                framing = next
            }
        )
    }

    private var timingBinding: Binding<Int> {
        Binding(
            get: { framing.timing },
            set: { picked in
                var next: LabPacketBuilder.Framing = framing
                next.timing = picked
                framing = next
            }
        )
    }

    private func framingToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(MMTheme.cyan)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased())
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textPrimary)
                dimText(detail)
            }
        }
    }

    // MARK: - Actions

    private func actionRow(_ current: String) -> some View {
        HStack(spacing: 8) {
            Button {
                if !current.isEmpty { onHexBuilt(current) }
            } label: {
                Text("USE IN HEX FIELD")
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.cyan)
            }
            .buttonStyle(.bordered)
            .tint(MMTheme.cyan)
            .disabled(current.isEmpty)
            Button {
                loadFromHexField()
            } label: {
                Text("LOAD HEX")
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.cyanDim)
            }
            .buttonStyle(.bordered)
            .tint(MMTheme.cyanDim)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Behaviour

    private func select(_ type: LabPacketBuilder.LabPacketType) {
        if type == selectedType { return }
        selectedType = type
        colors = LabPacketBuilder.defaultColors(type)
        framing = LabPacketBuilder.defaultFraming(type)
        if type == .raw && rawHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rawHex = loadedHex
        }
        loadMsg = nil
    }

    private func applyDecoded(_ decoded: LabPacketBuilder.Decoded) {
        selectedType = decoded.type
        colors = decoded.colors.isEmpty ? LabPacketBuilder.defaultColors(decoded.type) : decoded.colors
        vibEnabled = decoded.vibEnabled
        vibPattern = decoded.vibPattern
        rawHex = decoded.rawHex
        framing = decoded.framing
        showIndex = decoded.showIndex
    }

    /// The packet the builder holds right now came from a load or the Standard / Extended switch,
    /// not from the user: keep it out of the hex field.
    private func holdBuiltHex() {
        heldHex = builtHex
    }

    /// A packet was sent to the Lab: decode it into the fields for editing.
    private func decodeLoaded() {
        guard let decoded = LabPacketBuilder.decode(loadedHex) else { return }
        applyDecoded(decoded)
        loadMsg = "Loaded \(decoded.type.label) from received packet"
        holdBuiltHex()
    }

    private func loadFromHexField() {
        guard let decoded = LabPacketBuilder.decode(loadedHex) else {
            loadMsg = "Hex field is empty"
            return
        }
        applyDecoded(decoded)
        loadMsg = "Loaded \(decoded.type.label) from hex field"
        holdBuiltHex()
    }

    /// Leaving Extended drops back to a Standard type rather than keep building an experiment.
    private func applyExtended(_ on: Bool) {
        if !on && selectedType.experimental {
            select(.preset)
        }
        if !on {
            ledMask = 7
        }
    }

    /// Entering the Lab: decode the packet sent to it (if any), apply the Standard / Extended
    /// rule, and show the builder's packet in the preview. None of it touches the hex field.
    private func appeared() {
        if loadTick > 0 {
            decodeLoaded()
        }
        applyExtended(extended)
        holdBuiltHex()
        let current: String = builtHex
        if !current.isEmpty {
            onHexChanged(current)
        }
    }

    /// The preview follows every builder packet; the hex field follows the ones the user made.
    private func builderHexChanged(_ newHex: String) {
        let fromLoad: Bool = heldHex == newHex
        heldHex = nil
        if newHex.isEmpty { return }
        onHexChanged(newHex)
        if !fromLoad {
            onHexBuilt(newHex)
        }
    }

    private func dimText(_ text: String) -> some View {
        Text(text)
            .font(MMTheme.techLabel(9))
            .foregroundStyle(MMTheme.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Option lists

    private static let experimentOptions: [(Int, String)] = labIndexedNames(
        LabPacketBuilder.experiments.map { (experiment: LabPacketBuilder.Experiment) -> String in experiment.name }
    )

    private static let showOptions: [(Int, String)] = labIndexedNames(
        LabPacketBuilder.showEffects.map { (show: (String, String)) -> String in show.0 }
    )

    private static let paletteOptions: [(Int, String)] = LabPacketBuilder.paletteColors.map {
        (color: LabPacketBuilder.PaletteColor) -> (Int, String) in (color.id, color.label)
    }

    private static let vibrationOptions: [(Int, String)] = LabPacketBuilder.vibrationPatterns.map {
        (pattern: LabPacketBuilder.VibrationPattern) -> (Int, String) in (pattern.id, pattern.label)
    }
}

// MARK: - Summary card

/// One-sentence description of the packet plus its size and fit, from the classifier and the TLV
/// walk (Android `PacketSummaryCard`).
private struct LabPacketSummaryCard: View {
    let hex: String

    init(hex: String) {
        self.hex = hex
    }

    var body: some View {
        let summary: LabPacketSummary = LabPacketSummary(hex)
        let tone: Color = summary.toneColor
        VStack(alignment: .leading, spacing: 2) {
            Text("YOU ARE BUILDING")
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
            Text(summary.headline.uppercased())
                .font(MMTheme.techHeader())
                .foregroundStyle(tone)
                .lineLimit(2)
            if !summary.colors.isEmpty {
                Text(summary.colors.uppercased())
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.cyanDim)
            }
            Text(summary.details.joined(separator: " · ").uppercased())
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            if let reject = summary.reject {
                Text(reject)
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.error)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MMTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(tone.opacity(0.5), lineWidth: 1))
    }
}

/// What the summary card says about a packet; every line comes from the packet itself.
private struct LabPacketSummary {
    enum Tone {
        case invalid
        case known
        case unknown
    }

    let headline: String
    let colors: String
    let details: [String]
    let reject: String?
    let tone: Tone

    init(_ hex: String) {
        let canonical: String = HexUtils.canonicalHex(hex)
        let classified: ClassifiedPacket? = MagicClassifier.classify(canonical)
        let parsed: DisneyTlv.Parsed? = DisneyTlv.parse(canonical)
        let rejectReason: String? = HexUtils.legacyAdvertiseRejectReason(canonical)
        let byteCount: Int = HexUtils.hexToBytes(canonical).count

        headline = LabPacketSummary.headlineText(classified, parsed)
        let classColors: String = classified?.colors ?? ""
        colors = classColors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : classColors
        details = LabPacketSummary.detailLines(parsed, byteCount: byteCount, reject: rejectReason)
        reject = rejectReason
        if rejectReason != nil || parsed?.exact == false {
            tone = .invalid
        } else if classified != nil {
            tone = .known
        } else {
            tone = .unknown
        }
    }

    var toneColor: Color {
        switch tone {
        case .invalid: return MMTheme.error
        case .known: return MMTheme.cyan
        case .unknown: return MMTheme.amber
        }
    }

    private static func headlineText(_ classified: ClassifiedPacket?, _ parsed: DisneyTlv.Parsed?) -> String {
        if let classified {
            return classified.label
        }
        guard let first = parsed?.records.first else {
            return "Empty packet"
        }
        if first.isChannelMarker() {
            return "Channel marker only — no effect"
        }
        return "Unrecognised packet (type \(first.typeHex()))"
    }

    private static func detailLines(_ parsed: DisneyTlv.Parsed?, byteCount: Int, reject: String?) -> [String] {
        var out: [String] = []
        if let p = parsed {
            let effect: DisneyTlv.Record? = p.effect
            if p.records.first?.type == DisneyTlv.typePing && effect != nil {
                out.append("wake ping first")
            }
            if let channel = p.channel {
                out.append("channel \(channel.type - DisneyTlv.typeChannel1 + 1)")
            } else if effect != nil {
                out.append("no channel marker")
            }
            if let e = effect, let last = e.value.last {
                let tail: Int = Int(last)
                if (tail & 0xF0) == 0xB0 {
                    out.append(buzzText(tail & 0x0F))
                }
            }
            if !p.exact {
                out.append("MALFORMED")
            }
        }
        out.append("\(byteCount) bytes")
        out.append(reject == nil ? "fits in BLE" : "TOO LONG")
        return out
    }

    private static func buzzText(_ vib: Int) -> String {
        if vib == 0 { return "no buzz" }
        let match: LabPacketBuilder.VibrationPattern? = LabPacketBuilder.vibrationPatterns.first(where: {
            (pattern: LabPacketBuilder.VibrationPattern) -> Bool in pattern.id == vib
        })
        let name: String = match?.label ?? "#\(vib)"
        return "buzz " + name.lowercased()
    }
}

// MARK: - Packet anatomy

/// The packet as labelled byte groups (Android `PacketAnatomy`). Tap a block to read its
/// explanation; colour blocks also show a swatch of the palette colour they encode.
private struct LabPacketAnatomyView: View {
    let hex: String

    @State private var selected: Int? = nil

    init(hex: String) {
        self.hex = hex
    }

    var body: some View {
        let segments: [DisneyTlv.Segment] = DisneyTlv.anatomy(hex)
        VStack(alignment: .leading, spacing: 4) {
            Text("PACKET ANATOMY — TAP A BLOCK")
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.cyanDim)
            segmentChips(segments)
            if let index = selected, index >= 0, index < segments.count {
                segmentDetail(segments[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: hex) { _, _ in
            selected = nil
        }
    }

    private func segmentChips(_ segments: [DisneyTlv.Segment]) -> some View {
        let flow = LabFlowLayout(spacing: 4)
        return flow {
            ForEach(0..<segments.count, id: \.self) { index in
                segmentChip(segments[index], index: index)
            }
        }
    }

    private func segmentChip(_ segment: DisneyTlv.Segment, index: Int) -> some View {
        let tone: Color = labSegmentColor(segment.kind)
        let isSelected: Bool = selected == index
        return VStack(spacing: 1) {
            HStack(spacing: 4) {
                if segment.kind == .color {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(starlightGlowColor(LabPacketAnatomyView.paletteIndex(segment.hex)))
                        .frame(width: 8, height: 8)
                }
                Text(segment.hex.isEmpty ? "!" : segment.hex)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(tone)
                    .lineLimit(1)
            }
            Text(segment.title.uppercased())
                .font(MMTheme.techLabel(8))
                .foregroundStyle(MMTheme.textDim)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(isSelected ? tone.opacity(0.18) : MMTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(tone.opacity(isSelected ? 1.0 : 0.45), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            selected = isSelected ? nil : index
        }
    }

    private func segmentDetail(_ segment: DisneyTlv.Segment) -> some View {
        Text(segment.detail)
            .font(MMTheme.techLabel(9))
            .foregroundStyle(labSegmentColor(segment.kind))
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MMTheme.panel, in: RoundedRectangle(cornerRadius: 4))
    }

    private static func paletteIndex(_ segmentHex: String) -> Int {
        (Int(segmentHex, radix: 16) ?? 0) & 0x1F
    }
}

private func labSegmentColor(_ kind: DisneyTlv.SegmentKind) -> Color {
    switch kind {
    case .company: return MMTheme.textDim
    case .channel: return MMTheme.amber
    case .ping: return MMTheme.amber
    case .effectHead: return MMTheme.cyan
    case .header: return MMTheme.cyanDim
    case .color: return MMTheme.cyan
    case .data: return MMTheme.cyanDim
    case .tail: return MMTheme.textDim
    case .wand: return MMTheme.cyan
    case .beacon: return MMTheme.textDim
    case .other: return MMTheme.textDim
    case .error: return Color(red: 1.0, green: 82.0 / 255.0, blue: 82.0 / 255.0)
    }
}

// MARK: - Small pieces

/// Option list for a picker whose ids are list positions.
private func labIndexedNames(_ names: [String]) -> [(Int, String)] {
    var out: [(Int, String)] = []
    for (index, name) in names.enumerated() {
        out.append((index, name))
    }
    return out
}

private extension View {
    /// The look of a hex text field in the builder.
    func labBuilderField() -> some View {
        self
            .font(MMTheme.techLabel())
            .foregroundStyle(MMTheme.cyanDim)
            .padding(8)
            .background(MMTheme.panel)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(MMTheme.panelLine, lineWidth: 0.5))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.characters)
    }
}

/// Lays its children out left to right and starts a new row when the next one does not fit
/// (Compose's `FlowRow`). A child wider than a whole row is given the row's width.
private struct LabFlowLayout: Layout {
    let spacing: CGFloat

    init(spacing: CGFloat) {
        self.spacing = spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit: CGFloat = proposal.width ?? CGFloat.infinity
        return arrange(subviews, limit: limit).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placement: LabFlowPlacement = arrange(subviews, limit: bounds.width)
        var index: Int = 0
        for subview in subviews {
            if index < placement.frames.count {
                let frame: CGRect = placement.frames[index]
                subview.place(
                    at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: frame.width, height: frame.height)
                )
            }
            index += 1
        }
    }

    private func arrange(_ subviews: LayoutSubviews, limit: CGFloat) -> LabFlowPlacement {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            var size: CGSize = subview.sizeThatFits(ProposedViewSize.unspecified)
            if limit.isFinite && size.width > limit {
                size = subview.sizeThatFits(ProposedViewSize(width: limit, height: nil))
                size.width = min(size.width, limit)
            }
            if x > 0 && x + size.width > limit {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        // Take the whole proposed width, so placement wraps exactly as measured.
        let width: CGFloat = limit.isFinite ? limit : widest
        return LabFlowPlacement(frames: frames, size: CGSize(width: width, height: y + rowHeight))
    }
}

private struct LabFlowPlacement {
    let frames: [CGRect]
    let size: CGSize
}

// MARK: - Palette picker

/// Picker for palette colours, buzz patterns, shows and the keep-awake ping. A presented sheet
/// with its own List, not a `Menu`: the Lab re-renders on every relay status poll and every heard
/// packet, and each re-render rebuilt an open menu and threw its scroll back to the top. The
/// sheet's list owns its scroll position, opens at the current selection, shows a swatch for
/// palette rows and gives 32 options rows a thumb can hit.
struct LabPalettePicker: View {
    let label: String
    @Binding var selection: Int
    let options: [(Int, String)]

    @State private var open: Bool = false

    init(label: String, selection: Binding<Int>, options: [(Int, String)]) {
        self.label = label
        self._selection = selection
        self.options = options
    }

    var body: some View {
        Button {
            open = true
        } label: {
            pickerLabel
        }
        .buttonStyle(.bordered)
        .tint(MMTheme.cyanDim)
        .disabled(options.isEmpty)
        .sheet(isPresented: $open) {
            pickerSheet
        }
    }

    private var pickerLabel: some View {
        HStack(spacing: 4) {
            if let c = swatch(for: currentName) {
                Circle().fill(c).frame(width: 9, height: 9)
            }
            Text("\(label): \(currentName)")
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.cyan)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8))
                .foregroundStyle(MMTheme.textDim)
        }
    }

    private var pickerSheet: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(options, id: \.0) { id, name in
                        optionRow(id: id, name: name)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(MMTheme.navy)
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
            .navigationTitle(label.uppercased())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { open = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func optionRow(id: Int, name: String) -> some View {
        Button {
            selection = id
            open = false
        } label: {
            HStack(spacing: 10) {
                if let c = swatch(for: name) {
                    RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 16, height: 16)
                }
                Text(name)
                    .font(MMTheme.techLabel(12))
                    .foregroundStyle(id == selection ? MMTheme.cyan : MMTheme.textPrimary)
                Spacer()
                if id == selection {
                    Image(systemName: "checkmark").foregroundStyle(MMTheme.cyan)
                }
            }
            .padding(.vertical, 4)
        }
        .id(id)
        .listRowBackground(id == selection ? MMTheme.cyan.opacity(0.12) : MMTheme.panel)
    }

    private var currentName: String {
        options.first(where: { $0.0 == selection })?.1 ?? "?"
    }

    /// Palette labels are "#1B White" — pull the index out for a swatch; nil for non-colours.
    private func swatch(for optionLabel: String) -> Color? {
        guard optionLabel.hasPrefix("#"), optionLabel.count >= 3 else { return nil }
        let hex = optionLabel.dropFirst().prefix(2)
        guard let idx = Int(hex, radix: 16) else { return nil }
        return starlightGlowColor(idx)
    }
}
