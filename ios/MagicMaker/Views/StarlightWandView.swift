import SwiftUI

private let defaultGlowIndex = 0x1B
private let wandAspect: CGFloat = 600.0 / 750.0
private let upperGlowFraction: CGFloat = 0.94

/// The wand glow colour of starlight palette index `index` (its low 5 bits) as sRGB channels 0...1.
/// `starlightGlowColor` draws it; the VFD theme lights cells in it (`VFDColors.starlightGlow`).
func starlightGlowRGB(_ index: Int) -> (red: Double, green: Double, blue: Double) {
    let i = index & 0x1F
    switch i {
    case 0x00, 0x16, 0x17, 0x18: return (red: 0, green: 0.9, blue: 1)
    case 0x01, 0x05, 0x07: return (red: 0.73, green: 0.53, blue: 0.99)
    case 0x02, 0x03, 0x04: return (red: 0.27, green: 0.54, blue: 1)
    case 0x06: return (red: 0.88, green: 0.75, blue: 0.91)
    case 0x08...0x0E: return (red: 1, green: 0.25, blue: 0.51)
    case 0x0F, 0x11: return (red: 1, green: 0.67, blue: 0.25)
    case 0x10: return (red: 1, green: 0.96, blue: 0.62)
    case 0x12, 0x1A: return (red: 0.8, green: 1, blue: 0.56)
    case 0x13, 0x14: return (red: 1, green: 0.6, blue: 0)
    case 0x15: return (red: 1, green: 0.32, blue: 0.32)
    case 0x19: return (red: 0.41, green: 0.94, blue: 0.68)
    case 0x1B, 0x1C: return (red: 0.82, green: 0.94, blue: 1)
    case 0x1D: return (red: 0.31, green: 0.31, blue: 0.31)
    case 0x1E: return (red: 0.81, green: 0.58, blue: 0.85)
    default: return (red: 0.7, green: 0.53, blue: 1)
    }
}

func starlightGlowColor(_ index: Int) -> Color {
    let c = starlightGlowRGB(index)
    return Color(red: c.red, green: c.green, blue: c.blue)
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

/// One colour the wand view offers.
private struct StarlightWandEntry: Equatable {
    let id: Int64
    let hex: String
}

/// The Starlight wand: the wand image glowing in the colour last heard or sent, a picker with
/// each colour's name and code, and SEND. Tapping the wand steps to the next colour.
/// Port of Android `StarlightWandView.kt`.
///
///     StarlightWandView(
///         packets: colors,
///         displayColorIndex: vm.wandDisplayColorIndex,
///         onDelete: { packet in askDelete(packet) },
///         onTransmit: { packet in send(packet) }
///     )
struct StarlightWandView: View {
    private let entries: [StarlightWandEntry]
    let displayColorIndex: Int
    let sendEnabled: Bool
    private let emptyText: String
    private let sendAt: (Int) -> Void
    private let deleteAt: ((Int) -> Void)?
    /// The Apple Watch star of the colour the picker shows (the iPhone's own colours only).
    private let starredAt: ((Int) -> Bool)?
    private let starAt: ((Int) -> Void)?
    /// The star follows every favourites change.
    @ObservedObject private var favorites: WatchFavoritesStore = WatchFavoritesStore.shared

    @State private var selectedIndex = 0
    @State private var glowColorIndex = defaultGlowIndex
    @State private var pulse1: CGFloat = 0
    @State private var pulse2: CGFloat = 0

    /// The wand colours of a linked Android phone's library.
    init(
        colors: [AndroidRemotePreset],
        displayColorIndex: Int,
        sendEnabled: Bool = true,
        onTransmit: @escaping (AndroidRemotePreset) -> Void
    ) {
        var list: [StarlightWandEntry] = []
        list.reserveCapacity(colors.count)
        for preset in colors {
            list.append(StarlightWandEntry(id: preset.id, hex: preset.hex))
        }
        let presets: [AndroidRemotePreset] = colors
        self.entries = list
        self.displayColorIndex = displayColorIndex
        self.sendEnabled = sendEnabled
        self.emptyText = "HEAR A WAND COLOR · OPEN LINK · SYNC LIBRARY"
        self.sendAt = { index in
            if index >= 0 && index < presets.count {
                onTransmit(presets[index])
            }
        }
        self.deleteAt = nil
        self.starredAt = nil
        self.starAt = nil
    }

    /// The iPhone's own learned colours. With `onDelete` the picker also offers to delete the
    /// colour it shows; with `onStar` it shows the Apple Watch star of that colour.
    init(
        packets: [MagicPacket],
        displayColorIndex: Int,
        sendEnabled: Bool = true,
        onDelete: ((MagicPacket) -> Void)? = nil,
        isStarred: ((MagicPacket) -> Bool)? = nil,
        onStar: ((MagicPacket) -> Void)? = nil,
        onTransmit: @escaping (MagicPacket) -> Void
    ) {
        var list: [StarlightWandEntry] = []
        list.reserveCapacity(packets.count)
        for packet in packets {
            list.append(StarlightWandEntry(id: packet.id, hex: packet.hex))
        }
        let all: [MagicPacket] = packets
        self.entries = list
        self.displayColorIndex = displayColorIndex
        self.sendEnabled = sendEnabled
        self.emptyText = "HEAR A WAND COLOR · SCAN TO LEARN"
        self.sendAt = { index in
            if index >= 0 && index < all.count {
                onTransmit(all[index])
            }
        }
        if let deleteHandler = onDelete {
            self.deleteAt = { index in
                if index >= 0 && index < all.count {
                    deleteHandler(all[index])
                }
            }
        } else {
            self.deleteAt = nil
        }
        if let starredHandler = isStarred {
            self.starredAt = { index in
                if index >= 0 && index < all.count {
                    return starredHandler(all[index])
                }
                return false
            }
        } else {
            self.starredAt = nil
        }
        if let starHandler = onStar {
            self.starAt = { index in
                if index >= 0 && index < all.count {
                    starHandler(all[index])
                }
            }
        } else {
            self.starAt = nil
        }
    }

    private var glow: Color { starlightGlowColor(glowColorIndex) }

    /// The name of the colour the wand glows in.
    private var label: String {
        StarlightColors.nameFor(glowColorIndex).uppercased()
    }

    private var selectedEntry: StarlightWandEntry? {
        guard selectedIndex >= 0, selectedIndex < entries.count else { return nil }
        return entries[selectedIndex]
    }

    private var selectedHex: String { selectedEntry?.hex.uppercased() ?? "" }

    /// The codes on offer, in order; a change means the list changed.
    private var entryKeys: [String] {
        entries.map { $0.hex }
    }

    var body: some View {
        VStack(spacing: 10) {
            wandArea
            if entries.isEmpty {
                Text(emptyText)
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            } else {
                pickerRow
            }
        }
        .padding(.bottom, 8)
        .onChange(of: displayColorIndex) { _, newIndex in
            syncHeardColor(newIndex)
        }
        .onChange(of: entryKeys) { oldKeys, newKeys in
            // A list of another length starts again from its first colour, then follows the
            // colour last heard or sent.
            if oldKeys.count != newKeys.count {
                selectedIndex = 0
            }
            syncHeardColor(displayColorIndex)
        }
        .onAppear {
            syncHeardColor(displayColorIndex)
        }
    }

    private var wandArea: some View {
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
    }

    // Dropdown to pick the color/command + a Send button to the right — no tapping
    // through every color to reach the one you want.
    private var pickerRow: some View {
        HStack(spacing: 8) {
            Menu {
                menuItems
            } label: {
                pickerLabel
            }

            if let starAt, selectedEntry != nil {
                FavoriteStarButton(on: starredAt?(selectedIndex) ?? false) {
                    starAt(selectedIndex)
                }
            }

            MMPrimaryButton(title: "SEND", enabled: sendEnabled && selectedEntry != nil) {
                sendSelected()
            }
            .frame(width: 96)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var menuItems: some View {
        // The name AND the code, so you can tell exactly which one you are sending.
        ForEach(Array(entries.enumerated()), id: \.offset) { idx, entry in
            Button(menuTitle(entry)) { select(idx) }
        }
        if deleteAt != nil, let entry = selectedEntry {
            Divider()
            Button(role: .destructive) {
                deleteSelected()
            } label: {
                Label("DELETE " + colorName(entry.hex).uppercased(), systemImage: "trash")
            }
        }
    }

    private var pickerLabel: some View {
        HStack(spacing: 6) {
            Circle().fill(glow).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(MMTheme.techLabel(11))
                    .foregroundStyle(MMTheme.textPrimary)
                    .lineLimit(1)
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

    private func menuTitle(_ entry: StarlightWandEntry) -> String {
        colorName(entry.hex).uppercased() + "  ·  " + entry.hex.uppercased()
    }

    private func colorName(_ hex: String) -> String {
        StarlightColors.nameFor(MagicClassifier.starlightColorIndex(hex))
    }

    private func sendSelected() {
        if selectedEntry == nil { return }
        runTransmitPulse()
        sendAt(selectedIndex)
    }

    private func deleteSelected() {
        if selectedEntry == nil { return }
        guard let action = self.deleteAt else { return }
        action(selectedIndex)
    }

    private func cycleColor() {
        guard !entries.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % entries.count
        glowColorIndex = MagicClassifier.starlightColorIndex(entries[selectedIndex].hex)
    }

    private func select(_ idx: Int) {
        guard idx >= 0, idx < entries.count else { return }
        selectedIndex = idx
        glowColorIndex = MagicClassifier.starlightColorIndex(entries[idx].hex)
    }

    /// The glow takes the heard colour; the picker its entry of that colour (the list has one per
    /// colour name, which may be another index of that name than the one heard).
    private func syncHeardColor(_ index: Int) {
        let heard = index & 0x1F
        glowColorIndex = heard
        guard !entries.isEmpty else { return }
        let key: String = StarlightColors.wandColorKey(index: heard)
        if let idx = entries.firstIndex(where: { StarlightColors.wandColorKey(hex: $0.hex) == key }) {
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
