import SwiftUI

private let defaultGlowIndex = 0x1B
private let wandAspect: CGFloat = 600.0 / 750.0
private let upperGlowFraction: CGFloat = 0.94
private let starlightOrange = Color(red: 1, green: 0.6, blue: 0)

func starlightGlowColor(_ index: Int) -> Color {
    let i = index & 0x1F
    switch i {
    case 0x00, 0x16, 0x17, 0x18: return Color(red: 0, green: 0.9, blue: 1)
    case 0x01, 0x05, 0x07: return Color(red: 0.73, green: 0.53, blue: 0.99)
    case 0x02, 0x03, 0x04: return Color(red: 0.27, green: 0.54, blue: 1)
    case 0x06: return Color(red: 0.88, green: 0.75, blue: 0.91)
    case 0x08...0x0E: return Color(red: 1, green: 0.25, blue: 0.51)
    case 0x0F, 0x11: return Color(red: 1, green: 0.67, blue: 0.25)
    case 0x10: return Color(red: 1, green: 0.96, blue: 0.62)
    case 0x12, 0x1A: return Color(red: 0.8, green: 1, blue: 0.56)
    case 0x13, 0x14: return starlightOrange
    case 0x15: return Color(red: 1, green: 0.32, blue: 0.32)
    case 0x19: return Color(red: 0.41, green: 0.94, blue: 0.68)
    case 0x1B, 0x1C: return Color(red: 0.82, green: 0.94, blue: 1)
    case 0x1D: return Color(red: 0.31, green: 0.31, blue: 0.31)
    case 0x1E: return Color(red: 0.81, green: 0.58, blue: 0.85)
    default: return Color(red: 0.7, green: 0.53, blue: 1)
    }
}

private struct WandGlowEnvelope {
    let centerY: CGFloat
    let rx: CGFloat
    let ry: CGFloat
    let peak: CGFloat
}

private let wandAuraEnvelopes: [WandGlowEnvelope] = [
    WandGlowEnvelope(centerY: 0.28, rx: 0.115, ry: 0.30, peak: 0.30),
    WandGlowEnvelope(centerY: 0.28, rx: 0.062, ry: 0.265, peak: 0.55),
]

private let wandTintEnvelope = WandGlowEnvelope(centerY: 0.28, rx: 0.085, ry: 0.275, peak: 0.72)

struct StarlightWandView: View {
    let colors: [AndroidRemotePreset]
    let displayColorIndex: Int
    var sendEnabled: Bool = true
    let onTransmit: (AndroidRemotePreset) -> Void

    @State private var selectedIndex = 0
    @State private var glowColorIndex = defaultGlowIndex
    @State private var pulse1: CGFloat = 0
    @State private var pulse2: CGFloat = 0

    private var glow: Color { starlightGlowColor(glowColorIndex) }
    private var label: String {
        PresetCatalog.starlightColorNames[glowColorIndex] ?? "White"
    }

    private var selectedPreset: AndroidRemotePreset? {
        guard !colors.isEmpty, selectedIndex < colors.count else { return nil }
        return colors[selectedIndex]
    }

    private var selectedHex: String { selectedPreset?.hex.uppercased() ?? "" }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let maxH = geo.size.height
                let maxW = geo.size.width * 0.88
                let wandH = min(maxH, maxW / wandAspect)
                let wandW = wandH * wandAspect
                let wandTop = (geo.size.height - wandH) / 2
                let cx = geo.size.width / 2
                let cy = wandTop + wandH / 2

                ZStack {
                    WandAuraLayer(
                        glow: glow,
                        pulse1: pulse1,
                        pulse2: pulse2,
                        wandWidth: wandW,
                        wandHeight: wandH
                    )
                    .frame(width: wandW, height: wandH)
                    .position(x: cx, y: cy)

                    Image("StarlightWand")
                        .resizable()
                        .scaledToFit()
                        .frame(width: wandW, height: wandH)
                        .position(x: cx, y: cy)

                    WandTintLayer(
                        glow: glow,
                        wandWidth: wandW,
                        wandHeight: wandH
                    )
                    .frame(width: wandW, height: wandH)
                    .position(x: cx, y: cy)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { cycleColor() }
            }

            if colors.isEmpty {
                Text("HEAR A WAND COLOR · OPEN LINK · SYNC LIBRARY")
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            } else {
                // Dropdown to pick the color/command + a Send button to the right — no tapping
                // through every color to reach the one you want.
                HStack(spacing: 8) {
                    Menu {
                        ForEach(Array(colors.enumerated()), id: \.offset) { idx, preset in
                            // Show the name AND the code so you can tell exactly which one you're sending.
                            Button("\(colorName(preset))  ·  \(preset.hex.uppercased())") { select(idx) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(glow).frame(width: 12, height: 12)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(label).font(MMTheme.techLabel(11)).foregroundStyle(.white)
                                Text(selectedHex)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(MMTheme.textDim)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(MMTheme.textDim)
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15)))
                    }

                    MMPrimaryButton(title: "SEND", enabled: sendEnabled) {
                        guard let preset = selectedPreset else { return }
                        runTransmitPulse()
                        onTransmit(preset)
                    }
                    .frame(width: 96)
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 8)
        .onChange(of: displayColorIndex) { _, newIndex in
            syncHeardColor(newIndex)
        }
        .onChange(of: colors.count) { _, _ in
            syncHeardColor(displayColorIndex)
        }
        .onAppear {
            syncHeardColor(displayColorIndex)
        }
    }

    private func cycleColor() {
        guard !colors.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % colors.count
        glowColorIndex = MagicClassifier.starlightColorIndex(colors[selectedIndex].hex)
    }

    private func select(_ idx: Int) {
        guard idx >= 0, idx < colors.count else { return }
        selectedIndex = idx
        glowColorIndex = MagicClassifier.starlightColorIndex(colors[idx].hex)
    }

    private func colorName(_ preset: AndroidRemotePreset) -> String {
        let idx = MagicClassifier.starlightColorIndex(preset.hex) & 0x1F
        if let name = PresetCatalog.starlightColorNames[idx] { return name }
        return preset.label.isEmpty ? String(format: "Color %02X", idx) : preset.label
    }

    private func syncHeardColor(_ index: Int) {
        let heard = index & 0x1F
        glowColorIndex = heard
        guard !colors.isEmpty else { return }
        if let idx = colors.firstIndex(where: { MagicClassifier.starlightColorIndex($0.hex) == heard }) {
            selectedIndex = idx
        }
    }

    private func runTransmitPulse() {
        pulse1 = 0
        pulse2 = 0
        withAnimation(.easeOut(duration: 0.42)) { pulse1 = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.easeOut(duration: 0.42)) { pulse2 = 1 }
        }
    }
}

/// Spills past wand edges so glow is visible against the dark UI background.
private struct WandAuraLayer: View {
    let glow: Color
    let pulse1: CGFloat
    let pulse2: CGFloat
    let wandWidth: CGFloat
    let wandHeight: CGFloat

    var body: some View {
        Canvas { context, size in
            let cx = size.width / 2
            let glowBottom = size.height * upperGlowFraction
            context.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: glowBottom)))

            for env in wandAuraEnvelopes {
                drawSoftAura(
                    context: &context,
                    center: CGPoint(x: cx, y: size.height * env.centerY),
                    rx: size.width * env.rx,
                    ry: size.height * env.ry,
                    glow: glow,
                    peak: env.peak
                )
            }

            for (p, alpha) in [(pulse1, 0.38), (pulse2, 0.24)] where p > 0 {
                let scale = 1 + p * 0.06
                let env = wandAuraEnvelopes[0]
                drawSoftAura(
                    context: &context,
                    center: CGPoint(x: cx, y: size.height * env.centerY),
                    rx: size.width * env.rx * scale,
                    ry: size.height * env.ry * scale,
                    glow: glow,
                    peak: alpha * (1 - p * 0.4)
                )
            }
        }
        .blur(radius: 3.5)
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }

    private func drawSoftAura(
        context: inout GraphicsContext,
        center: CGPoint,
        rx: CGFloat,
        ry: CGFloat,
        glow: Color,
        peak: CGFloat
    ) {
        let radius = max(rx, ry)
        let shading = GraphicsContext.Shading.radialGradient(
            Gradient(stops: [
                .init(color: glow.opacity(peak * 0.45), location: 0),
                .init(color: glow.opacity(peak * 0.82), location: 0.28),
                .init(color: glow.opacity(peak), location: 0.42),
                .init(color: glow.opacity(peak * 0.62), location: 0.58),
                .init(color: glow.opacity(peak * 0.22), location: 0.72),
                .init(color: glow.opacity(peak * 0.05), location: 0.84),
                .init(color: .clear, location: 0.96),
            ]),
            center: center,
            startRadius: radius * 0.12,
            endRadius: radius
        )
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2)),
            with: shading
        )
    }
}

/// Multiply tints white wand parts to the active color (screen blend barely shows on white).
private struct WandTintLayer: View {
    let glow: Color
    let wandWidth: CGFloat
    let wandHeight: CGFloat

    var body: some View {
        Canvas { context, size in
            let cx = size.width / 2
            let glowBottom = size.height * upperGlowFraction
            context.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: glowBottom)))

            let env = wandTintEnvelope
            drawSoftTint(
                context: &context,
                center: CGPoint(x: cx, y: size.height * env.centerY),
                rx: size.width * env.rx,
                ry: size.height * env.ry,
                glow: glow,
                peak: env.peak
            )
        }
        .blur(radius: 1.2)
        .blendMode(.multiply)
        .opacity(0.78)
        .allowsHitTesting(false)
    }

    private func drawSoftTint(
        context: inout GraphicsContext,
        center: CGPoint,
        rx: CGFloat,
        ry: CGFloat,
        glow: Color,
        peak: CGFloat
    ) {
        let radius = max(rx, ry)
        let shading = GraphicsContext.Shading.radialGradient(
            Gradient(stops: [
                .init(color: glow.opacity(peak * 0.55), location: 0),
                .init(color: glow.opacity(peak * 0.85), location: 0.35),
                .init(color: glow.opacity(peak * 0.45), location: 0.58),
                .init(color: glow.opacity(peak * 0.12), location: 0.76),
                .init(color: .clear, location: 0.92),
            ]),
            center: center,
            startRadius: radius * 0.08,
            endRadius: radius
        )
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2)),
            with: shading
        )
    }
}
