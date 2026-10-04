import SwiftUI

/// The Lab's packet composer. Nothing in here transmits. Every control only changes the packet
/// that is loaded into the hex field below it (via `onHexBuilt`); the one SEND button on the Lab
/// screen is the only thing that puts a packet on the air. Mirrors the Android Lab: pick what the
/// band should do, set the colours, read the summary, then send when you are ready.
struct LabBuilderPanel: View {
    let enabled: Bool
    let loadedHex: String
    let onHexBuilt: (String) -> Void

    @State private var type: LabPacketBuilder.LabPacketType = .preset
    @State private var colors: [Int] = LabPacketBuilder.defaultColors(.preset)
    @State private var vibEnabled = false
    @State private var vibPattern = PacketBuilder.Vibration.triple
    @State private var framing: LabPacketBuilder.Framing = LabPacketBuilder.defaultFraming(.preset)
    @State private var showIndex = 0

    private var builtHex: String {
        LabPacketBuilder.build(
            type: type, colors: colors, vibEnabled: vibEnabled, vibPattern: vibPattern,
            rawHex: loadedHex, framing: framing, showIndex: showIndex
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT DO YOU WANT THE BAND TO DO?")
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.cyanDim)
            typeChips
            Text(type.blurb)
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)

            summaryCard

            switch type {
            case .raw:
                Text("Edit the hex field below directly. The summary updates as you type.")
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.textDim)
                // Any loaded packet whose shape we understand gets its colours as pickers too.
                slotPickers(for: HexUtils.canonicalHex(loadedHex)) { onHexBuilt(LabPacketBuilder.withColors(loadedHex, $0)) }
            case .ping:
                Text("Nothing to set. Send this just before a command if a band isn't reacting.")
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.textDim)
            case .show:
                LabPalettePicker(
                    label: "SHOW",
                    selection: $showIndex,
                    options: LabPacketBuilder.showEffects.enumerated().map { ($0.offset, $0.element.0) }
                )
                Text("Recorded in the park. Change any colour below; everything else is replayed byte-for-byte.")
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.textDim)
                slotPickers(for: builtHex) { colors = $0 }
            default:
                if type.colorSlots > 0 {
                    labSection(type.colorSlots == 1 ? "COLOR" : "COLORS") {
                        colorSlots
                    }
                }
                if type.supportsVib {
                    HStack(spacing: 8) {
                        Text("BUZZ")
                            .font(MMTheme.techLabel())
                            .foregroundStyle(MMTheme.cyanDim)
                        Toggle("", isOn: $vibEnabled)
                            .labelsHidden()
                            .tint(MMTheme.cyan)
                        if vibEnabled {
                            LabPalettePicker(
                                label: "PATTERN",
                                selection: $vibPattern,
                                options: LabPacketBuilder.vibrationPatterns.map { ($0.id, $0.label) }
                            )
                        }
                        Spacer()
                    }
                }
            }

            if LabPacketBuilder.framingApplies(type) {
                labSection("FRAMING") {
                    framingToggle(
                        "Channel marker (E1 00)",
                        detail: "Every effect recorded in the park carries this. The esp32 presets never did. Try both.",
                        isOn: Binding(get: { framing.channelMarker }, set: { framing.channelMarker = $0 })
                    )
                    LabPalettePicker(
                        label: "DURATION",
                        selection: Binding(get: { framing.timing }, set: { framing.timing = $0 }),
                        options: PacketBuilder.Timing.options
                    )
                    Text("How long the band holds the effect — the timing byte. Default keeps the shape's own value (~21 s for the colour presets).")
                        .font(MMTheme.techLabel(9)).foregroundStyle(MMTheme.textDim)
                    framingToggle(
                        "Wake ping first (CC03 000100)",
                        detail: "Tells nearby bands to listen before the effect arrives.",
                        isOn: Binding(get: { framing.wakePrefix }, set: { framing.wakePrefix = $0 })
                    )
                }
            }
        }
        // The builder's only output: whatever it currently describes goes into the hex field.
        .onChange(of: builtHex) { _, hex in if type != .raw { onHexBuilt(hex) } }
        // A different show starts from its captured colours.
        .onChange(of: showIndex) { _, _ in if type == .show { colors = [] } }
        // A packet loaded from outside (Scan → "to Lab", a library row) must not be clobbered by
        // the builder's defaults: switch to Raw Hex so the loaded packet is what gets sent.
        .onChange(of: loadedHex) { _, hex in
            if type != .raw, !hex.isEmpty, HexUtils.canonicalHex(hex) != builtHex { type = .raw }
        }
        .onAppear {
            if !loadedHex.isEmpty, HexUtils.canonicalHex(loadedHex) != builtHex {
                type = .raw
            } else if type != .raw {
                onHexBuilt(builtHex)
            }
        }
    }

    // MARK: - Pieces

    private var typeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(LabPacketBuilder.LabPacketType.allCases) { t in
                    Button(t.label.uppercased()) { select(t) }
                        .font(MMTheme.techLabel(9))
                        .buttonStyle(.bordered)
                        .tint(t == type ? MMTheme.cyan : MMTheme.cyanDim)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(t == type ? MMTheme.cyan : .clear, lineWidth: 1)
                        )
                }
            }
        }
    }

    private func select(_ t: LabPacketBuilder.LabPacketType) {
        guard t != type else { return }
        type = t
        colors = LabPacketBuilder.defaultColors(t)
        framing = LabPacketBuilder.defaultFraming(t)
    }

    /// What the current settings will put on the air, in words — before any hex.
    private var summaryCard: some View {
        let hex = type == .raw ? HexUtils.canonicalHex(loadedHex) : builtHex
        let classified = MagicClassifier.classify(hex)
        let reject = HexUtils.legacyAdvertiseRejectReason(hex)
        let bytes = HexUtils.hexToBytes(hex).count
        let tone: Color = reject != nil ? MMTheme.error : (classified != nil ? MMTheme.cyan : MMTheme.amber)
        var details: [String] = []
        if LabPacketBuilder.framingApplies(type) {
            details.append(framing.wakePrefix ? "wake ping first" : "no wake ping")
            details.append(framing.channelMarker ? "channel 1" : "no channel marker")
        }
        if type.supportsVib {
            details.append(vibEnabled
                ? "buzz " + (LabPacketBuilder.vibrationPatterns.first { $0.id == vibPattern }?.label.lowercased() ?? "#\(vibPattern)")
                : "no buzz")
        }
        details.append("\(bytes) bytes")
        details.append(reject == nil ? "fits in BLE" : "TOO LONG")

        return VStack(alignment: .leading, spacing: 2) {
            Text("YOU ARE BUILDING")
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
            Text((classified?.label ?? (hex.isEmpty ? "Nothing yet" : "Unrecognised packet")).uppercased())
                .font(MMTheme.techHeader())
                .foregroundStyle(tone)
                .lineLimit(2)
            if let c = classified, !c.colors.isEmpty {
                Text(c.colors.uppercased())
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.cyanDim)
            }
            Text(details.joined(separator: " · ").uppercased())
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
            if let reject { Text(reject).font(MMTheme.techLabel(9)).foregroundStyle(MMTheme.error) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MMTheme.panel)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(tone.opacity(0.5), lineWidth: 1))
    }

    private var colorSlots: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<type.colorSlots, id: \.self) { i in
                HStack(spacing: 6) {
                    Circle()
                        .fill(starlightGlowColor(colors.indices.contains(i) ? colors[i] : 0))
                        .frame(width: 10, height: 10)
                    LabPalettePicker(
                        label: slotLabel(i),
                        selection: Binding(
                            get: { colors.indices.contains(i) ? colors[i] : 0 },
                            set: { v in
                                var c = colors
                                while c.count <= i { c.append(0) }
                                c[i] = v
                                colors = c
                            }
                        ),
                        options: LabPacketBuilder.paletteColors.map { ($0.id, $0.label) }
                    )
                    Spacer()
                }
            }
        }
    }

    /// Colour pickers for whatever recolourable bytes `hex` carries, labelled by where they land.
    @ViewBuilder
    private func slotPickers(for hex: String, onChange: @escaping ([Int]) -> Void) -> some View {
        let slots = LabPacketBuilder.editableSlots(hex)
        let values = LabPacketBuilder.slotColors(hex)
        if !slots.isEmpty && values.count == slots.count {
            labSection("COLORS") {
                ForEach(Array(slots.enumerated()), id: \.offset) { i, slot in
                    HStack(spacing: 6) {
                        Circle().fill(starlightGlowColor(values[i])).frame(width: 10, height: 10)
                        LabPalettePicker(
                            label: slot.label,
                            selection: Binding(get: { values[i] }, set: { v in var nv = values; nv[i] = v; onChange(nv) }),
                            options: LabPacketBuilder.paletteColors.map { ($0.id, $0.label) }
                        )
                        Spacer()
                    }
                }
            }
        }
    }

    private func slotLabel(_ i: Int) -> String {
        switch type {
        case .dual: return i == 0 ? "INNER" : "OUTER"
        case .crossfade: return i == 0 ? "FROM" : "TO"
        case .circle: return "P\(i + 1)"
        // Five LEDs: Z1 bottom-left, Z2 top-left, Z3 centre, Z4 top-right, Z5 bottom-right.
        case .rainbow, .rotate: return ["BOT-L", "TOP-L", "CENTRE", "TOP-R", "BOT-R"][i]
        default: return type.colorSlots == 1 ? "COLOR" : "\(i + 1)"
        }
    }

    private func framingToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: isOn).labelsHidden().tint(MMTheme.cyan)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased()).font(MMTheme.techLabel())
                Text(detail).font(MMTheme.techLabel(9)).foregroundStyle(MMTheme.textDim)
            }
        }
    }

    @ViewBuilder
    private func labSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.cyanDim)
            content()
        }
    }
}

/// Picker for palette colours, buzz patterns and shows. A presented sheet with its own List, not
/// a `Menu`: the Lab view re-renders every 2 s (relay status poll) and on every heard packet, and
/// each re-render rebuilt the open menu and threw its scroll back to the top. The sheet's list
/// owns its scroll position, opens at the current selection, shows a swatch for palette rows and
/// gives 32 options rows a thumb can hit.
private struct LabPalettePicker: View {
    let label: String
    @Binding var selection: Int
    let options: [(Int, String)]

    @State private var open = false

    var body: some View {
        Button {
            open = true
        } label: {
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
        .buttonStyle(.bordered)
        .tint(MMTheme.cyanDim)
        .disabled(options.isEmpty)
        .sheet(isPresented: $open) {
            NavigationStack {
                ScrollViewReader { proxy in
                    List {
                        ForEach(options, id: \.0) { id, name in
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
