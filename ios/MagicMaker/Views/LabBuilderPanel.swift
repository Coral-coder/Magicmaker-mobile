import SwiftUI

struct LabBuilderPanel: View {
    let enabled: Bool
    let onHexBuilt: (String) -> Void
    let onTransmit: (String) -> Void

    @State private var vibEnabled = true
    @State private var vibPattern = 3
    @State private var dualC1 = PacketBuilder.Color.yellowOrange
    @State private var dualC2 = PacketBuilder.Color.blue
    @State private var crossC1 = PacketBuilder.Color.red
    @State private var crossC2 = PacketBuilder.Color.blue
    @State private var rainbow: [Int] = [
        PacketBuilder.Color.yellowOrange,
        PacketBuilder.Color.red,
        PacketBuilder.Color.green,
        PacketBuilder.Color.blue,
        PacketBuilder.Color.purple,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("VIB")
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textDim)
                Toggle("", isOn: $vibEnabled)
                    .labelsHidden()
                    .tint(MMTheme.cyan)
                LabPalettePicker(label: "PAT", selection: $vibPattern, options: LabPacketBuilder.vibrationPatterns.map { ($0.id, $0.label) })
                MMCompactButton(title: "Wake", enabled: enabled) {
                    onTransmit(PacketBuilder.wakeupPing)
                }
            }

            labSection("PRIMARY") {
                chipRow(LabPacketBuilder.primaryPresetColors) { color in
                    onTransmit(LabPacketBuilder.buildPreset(colorId: color.id, vibEnabled: vibEnabled, vibPattern: vibPattern))
                }
            }

            labSection("FULL PALETTE (0x00–0x1F)") {
                chipRow(LabPacketBuilder.paletteColors) { color in
                    onTransmit(LabPacketBuilder.buildPreset(colorId: color.id, vibEnabled: vibEnabled, vibPattern: vibPattern))
                }
            }

            labMode("DUAL COLOR") {
                HStack(spacing: 8) {
                    LabPalettePicker(label: "IN", selection: $dualC1, options: paletteOptions)
                    LabPalettePicker(label: "OUT", selection: $dualC2, options: paletteOptions)
                }
                MMCompactButton(title: "Build Dual", enabled: enabled) {
                    onHexBuilt(LabPacketBuilder.buildDual(dualC1, dualC2, vibEnabled: vibEnabled, vibPattern: vibPattern))
                }
            }

            labMode("CROSSFADE") {
                HStack(spacing: 8) {
                    LabPalettePicker(label: "A", selection: $crossC1, options: paletteOptions)
                    LabPalettePicker(label: "B", selection: $crossC2, options: paletteOptions)
                }
                MMCompactButton(title: "Build Xfade", enabled: enabled) {
                    onHexBuilt(LabPacketBuilder.buildCrossfade(crossC1, crossC2, vibEnabled: vibEnabled, vibPattern: vibPattern))
                }
            }

            labMode("RAINBOW ×5") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(0..<5, id: \.self) { index in
                            LabPalettePicker(
                                label: "\(index + 1)",
                                selection: binding(for: index),
                                options: paletteOptions
                            )
                        }
                    }
                }
                MMCompactButton(title: "Build Rainbow", enabled: enabled) {
                    onHexBuilt(LabPacketBuilder.buildRainbow(
                        rainbow[0], rainbow[1], rainbow[2], rainbow[3], rainbow[4],
                        vibEnabled: vibEnabled, vibPattern: vibPattern
                    ))
                }
            }

            HStack(spacing: 8) {
                labMode("CIRCLE") {
                    MMCompactButton(title: "Build Circle", enabled: enabled) {
                        onHexBuilt(LabPacketBuilder.buildCircle(vibEnabled: vibEnabled, vibPattern: vibPattern))
                    }
                }
                labMode("FINALE") {
                    MMCompactButton(title: "Rainbow FX", enabled: enabled) {
                        onHexBuilt(PacketBuilder.rainbowFinale)
                    }
                }
                labMode("VIB ONLY") {
                    MMCompactButton(title: "Vib Band", enabled: enabled) {
                        onTransmit(LabPacketBuilder.buildVibrate(vibEnabled: vibEnabled, vibPattern: vibPattern))
                    }
                }
            }

            labMode("SHOW FX") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(LabPacketBuilder.showEffects, id: \.0) { label, hex in
                            Button(label.uppercased()) { onTransmit(hex) }
                                .font(MMTheme.techLabel())
                                .buttonStyle(.bordered)
                                .tint(MMTheme.cyan)
                                .disabled(!enabled)
                        }
                    }
                }
            }
        }
    }

    private var paletteOptions: [(Int, String)] {
        LabPacketBuilder.paletteColors.map { ($0.id, $0.label) }
    }

    private func binding(for index: Int) -> Binding<Int> {
        Binding(
            get: { rainbow[index] },
            set: { rainbow[index] = $0 }
        )
    }

    @ViewBuilder
    private func labSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
            content()
        }
    }

    @ViewBuilder
    private func labMode(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.cyanDim)
            content()
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MMTheme.panel.opacity(0.35))
        .overlay(RoundedRectangle(cornerRadius: 0).stroke(MMTheme.panelLine, lineWidth: 0.5))
    }

    @ViewBuilder
    private func chipRow(_ colors: [LabPacketBuilder.PaletteColor], action: @escaping (LabPacketBuilder.PaletteColor) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(colors) { color in
                    Button(color.label) { action(color) }
                        .font(MMTheme.techLabel(9))
                        .buttonStyle(.bordered)
                        .tint(MMTheme.cyan)
                        .disabled(!enabled)
                }
            }
        }
    }
}

private struct LabPalettePicker: View {
    let label: String
    @Binding var selection: Int
    let options: [(Int, String)]

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { id, name in
                Button(name) { selection = id }
            }
        } label: {
            Text("\(label): \(options.first(where: { $0.0 == selection })?.1 ?? "?")")
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.cyan)
                .lineLimit(1)
        }
        .disabled(options.isEmpty)
    }
}
