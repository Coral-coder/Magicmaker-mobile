import SwiftUI

/// What we expect the packet to look like on the band: the square face with its five LEDs
/// (four corners and the centre), animating the decoded `BandEffectModel` in a loop. Pinned above
/// the Lab so it is always visible and follows every change to the packet. Colours are exact;
/// where the motion or LED order is reproduced from other decoders the caption shows APPROX.
struct BandPreviewView: View {
    let hex: String
    var compact: Bool = false
    var title: String = "BAND PREVIEW"

    var body: some View {
        let model = BandEffectModel.from(hex)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = BandLedAnimation.phase(context.date.timeIntervalSinceReferenceDate)
            HStack(spacing: 12) {
                Canvas { ctx, size in
                    let w = min(size.width, size.height)
                    let face = CGRect(x: w * 0.08, y: w * 0.08, width: w * 0.84, height: w * 0.84)
                    let dim = Color(red: 0.08, green: 0.14, blue: 0.23)
                    let ledR = w * 0.085

                    let facePath = Path(roundedRect: face, cornerRadius: w * 0.07)
                    ctx.fill(facePath, with: .color(Color(red: 0.043, green: 0.078, blue: 0.14)))
                    ctx.stroke(facePath, with: .color(MMTheme.panelLine), lineWidth: w * 0.012)

                    // Zones Z1..Z5 = bottom-left, top-left, centre, top-right, bottom-right.
                    let inset = w * 0.20
                    let points = [
                        CGPoint(x: face.minX + inset, y: face.maxY - inset),
                        CGPoint(x: face.minX + inset, y: face.minY + inset),
                        CGPoint(x: face.midX, y: face.midY),
                        CGPoint(x: face.maxX - inset, y: face.minY + inset),
                        CGPoint(x: face.maxX - inset, y: face.maxY - inset),
                    ]
                    for (z, p) in points.enumerated() {
                        let lit: Color? = BandLedAnimation.color(model, zone: z, phase: t)?.color
                        let c = lit ?? dim
                        if lit != nil {
                            ctx.fill(Path(ellipseIn: CGRect(x: p.x - ledR * 2.2, y: p.y - ledR * 2.2, width: ledR * 4.4, height: ledR * 4.4)), with: .color(c.opacity(0.30)))
                        }
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - ledR, y: p.y - ledR, width: ledR * 2, height: ledR * 2)), with: .color(c))
                    }
                }
                .aspectRatio(1, contentMode: .fit)

                VStack(alignment: .leading, spacing: 1) {
                    if compact {
                        // Scan-page strip: exactly two text rows. Title and classification share the first.
                        HStack(spacing: 8) {
                            Text(title).font(MMTheme.techLabel(9)).foregroundStyle(MMTheme.textDim)
                            Text((MagicClassifier.classify(hex)?.label ?? model.note).uppercased())
                                .font(MMTheme.techLabel(9))
                                .foregroundStyle(model.kind == .none ? MMTheme.textDim : MMTheme.cyan)
                                .lineLimit(1)
                        }
                        Text(HexUtils.canonicalHex(hex))
                            .font(MMTheme.techLabel(9))
                            .foregroundStyle(MMTheme.cyanDim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                    Text(title).font(MMTheme.techLabel(9)).foregroundStyle(MMTheme.textDim)
                    Text(model.kind == .none ? "NO EFFECT" : BandLedAnimation.kindName(model.kind))
                        .font(MMTheme.techHeader())
                        .foregroundStyle(model.kind == .none ? MMTheme.textDim : MMTheme.cyan)
                    Text(model.note.uppercased() + (model.approximate ? " · APPROX." : ""))
                        .font(MMTheme.techLabel(9))
                        .foregroundStyle(model.approximate ? MMTheme.amber : MMTheme.textDim)
                        .lineLimit(2)
                    if model.durationMs > 0 || model.alwaysOn {
                        let dur = model.alwaysOn ? "ALWAYS ON" : "~\(model.durationMs / 1000)S" + (model.fadeMs > 0 ? " · \(model.fadeMs / 1000)S FADE" : "")
                        Text(dur).font(MMTheme.techLabel(9)).foregroundStyle(MMTheme.textDim)
                    }
                    if model.buzz > 0 {
                        let name = LabPacketBuilder.vibrationPatterns.first { $0.id == model.buzz }?.label ?? "#\(model.buzz)"
                        let on = BandLedAnimation.buzzOn(phase: t)
                        Text("BUZZ · \(name.uppercased())")
                            .font(MMTheme.techLabel(9))
                            .foregroundStyle(on ? MMTheme.cyan : MMTheme.cyanDim)
                    }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, compact ? 2 : 6)
        }
        .background(MMTheme.navy)
    }
}

// MARK: - Band LED animation (shared with the VFD theme)

/// One band LED's colour as the band preview draws it: sRGB channels 0...1 and an opacity over the
/// dark band face. `color` is what `BandPreviewView` paints; `composited(over:_:_:)` gives the solid
/// colour it shows as over a background, which is what the VFD theme lights its cells in.
struct BandLedColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double

    init(red: Double, green: Double, blue: Double, opacity: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    /// Starlight palette colour `index` (low 5 bits), opaque.
    static func palette(_ index: Int) -> BandLedColor {
        let c = starlightGlowRGB(index)
        return BandLedColor(red: c.red, green: c.green, blue: c.blue)
    }

    static let white = BandLedColor(red: 1, green: 1, blue: 1)

    /// This colour with its opacity multiplied by `amount` (SwiftUI `Color.opacity`).
    func opacity(_ amount: Double) -> BandLedColor {
        return BandLedColor(red: red, green: green, blue: blue, opacity: opacity * amount)
    }

    var color: Color {
        let solid = Color(red: red, green: green, blue: blue)
        return opacity >= 1.0 ? solid : solid.opacity(opacity)
    }

    /// The solid colour this LED shows as over the background (red, green, blue in 0...1).
    func composited(over bgRed: Double, _ bgGreen: Double, _ bgBlue: Double) -> (red: Double, green: Double, blue: Double) {
        let a: Double = min(max(opacity, 0.0), 1.0)
        let r: Double = red * a + bgRed * (1.0 - a)
        let g: Double = green * a + bgGreen * (1.0 - a)
        let b: Double = blue * a + bgBlue * (1.0 - a)
        return (red: r, green: g, blue: b)
    }

    /// Straight per-channel mix from a to b (opaque), as the preview's crossfades blend.
    static func blend(_ a: BandLedColor, _ b: BandLedColor, _ f: Double) -> BandLedColor {
        let r: Double = a.red + (b.red - a.red) * f
        let g: Double = a.green + (b.green - a.green) * f
        let bl: Double = a.blue + (b.blue - a.blue) * f
        return BandLedColor(red: r, green: g, blue: bl)
    }
}

/// The band preview's animation: a 2.4 s loop over the five zones of a decoded `BandEffectModel`.
/// `BandPreviewView` and the VFD theme (band preview, SCAN's LAST LIGHTS strip) both draw from it.
enum BandLedAnimation {
    /// Seconds per loop.
    static let period: Double = 2.4
    /// Zone index of the centre LED (Z3).
    static let centreZone: Int = 2

    /// Loop phase 0..<1 at `seconds` since the reference date.
    static func phase(_ seconds: Double) -> Double {
        // Always in 0..<1, so the colour lookups never index with a negative or NaN position
        // (a clock before 2001 gives negative seconds).
        guard seconds.isFinite else { return 0 }
        var r: Double = seconds.truncatingRemainder(dividingBy: period)
        if r < 0 { r += period }
        let t: Double = r / period
        return t < 1 ? t : 0
    }

    /// The BUZZ line blinks at 6 per loop: true in the bright half.
    static func buzzOn(phase t: Double) -> Bool {
        return (t * 6).truncatingRemainder(dividingBy: 1) < 0.5
    }

    /// The effect name the preview shows for a kind.
    static func kindName(_ k: BandEffectModel.Kind) -> String {
        switch k {
        case .pulseBurst: return "PULSE BURST"
        case .repeatFade: return "REPEAT FADE"
        case .centrePulse: return "CENTRE PULSE"
        default: return k.rawValue.uppercased()
        }
    }

    /// Colour of zone `z` (0...4 = Z1...Z5) at phase `t` in 0..<1, or nil for off.
    static func color(_ m: BandEffectModel, zone z: Int, phase t: Double) -> BandLedColor? {
        func pal(_ idx: Int?) -> BandLedColor? {
            guard let i = idx else { return nil }
            return BandLedColor.palette(i)
        }
        func led(_ i: Int) -> Int? {
            return (i >= 0 && i < m.perLed.count) ? m.perLed[i] : nil
        }
        let z3: Int = centreZone
        let rest: BandLedColor? = pal(led(z))
        let breathe: Double = 0.75 + 0.25 * sin(2 * Double.pi * t)
        switch m.kind {
        case .none, .ping:
            return nil
        case .single, .wand:
            return rest?.opacity(breathe)
        case .dual:
            return rest
        case .toggle:
            let lit: [Int] = m.perLed.compactMap { $0 }
            let a: Int? = lit.first
            let b: Int? = lit.first(where: { $0 != a }) ?? a
            return pal((t * 4).truncatingRemainder(dividingBy: 1) < 0.5 ? a : b)
        case .rainbow:
            if m.note.contains("cycle"), m.perLed.allSatisfy({ $0 != nil }) {
                let shift: Int = Int(t * 5)
                return pal(led((z + shift) % 5))
            }
            return rest
        case .rotate:
            let order: [Int] = [1, 2, 3, 4, 0]
            let pos: Int = order.firstIndex(of: z) ?? 0
            let step: Int = Int(t * 10)
            return pal(led(order[(pos + step) % 5]))
        case .crossfade:
            guard let a = pal(m.colors.first) else { return nil }
            let second: Int? = m.colors.count > 1 ? m.colors[1] : m.colors.first
            let b: BandLedColor = pal(second) ?? a
            let f: Double = 0.5 - 0.5 * cos(2 * Double.pi * t)
            return z == z3 ? BandLedColor.blend(b, a, f) : BandLedColor.blend(a, b, f)
        case .pulseBurst:
            let pos: Double = (t * 2.4).truncatingRemainder(dividingBy: 1.5)
            if pos >= 1 { return rest?.opacity(0.05) }
            let sub: Double = pos.truncatingRemainder(dividingBy: 0.5)
            let bright: Double = sub < 0.25 ? sub / 0.25 : 1 - (sub - 0.25) / 0.25
            return rest?.opacity(0.1 + 0.9 * bright)
        case .circle:
            if z == z3 { return rest?.opacity(0.15) }
            let corners: [Int] = [0, 1, 3, 4]
            let pos: Int = corners.firstIndex(of: z) ?? 0
            let head: Int = Int(t * 8) % 4
            let d: Int = (pos - head + 4) % 4
            let base: BandLedColor = rest ?? BandLedColor.palette(0x19)
            return (d == 0 || d == 2) ? base : base.opacity(0.3)
        case .twinkle:
            let r: Double = sin(Double(z) * 12.9898 + t * 40) * 43758.5453
            let v: Double = r - floor(r)
            return v > 0.6 ? rest : rest?.opacity(0.12)
        case .alternate:
            if z == z3 { return rest }
            let half: Bool = (t * 2.4).truncatingRemainder(dividingBy: 1) < 0.5
            let isA: Bool = z == 0 || z == 3
            return isA == half ? rest : rest?.opacity(0.08)
        case .repeatFade:
            let pos: Double = (t * 2.4).truncatingRemainder(dividingBy: 1.25)
            let bright: Double = pos < 1 ? 1 - pos : 0
            return rest?.opacity(0.05 + 0.95 * bright)
        case .lightning:
            let phase: Double = (t * 3).truncatingRemainder(dividingBy: 1)
            let flash: Bool = phase < 0.08 || (phase > 0.16 && phase < 0.22)
            return flash ? BandLedColor.white : BandLedColor.white.opacity(0.15)
        case .strobe:
            let pos: Double = (t * 5).truncatingRemainder(dividingBy: 5)
            if pos < 0.5 { return BandLedColor.palette(0x11) }
            if pos < 1 { return BandLedColor.palette(0x13) }
            return BandLedColor.palette(0x13).opacity(0.05)
        case .stepper:
            guard !m.colors.isEmpty else { return rest }
            let step: Int = (Int(t * 4.8) + z) % m.colors.count
            return pal(m.colors[step])
        case .rgb:
            let v: Int = m.rgb ?? 0x9E9E9E
            let r: Double = Double((v >> 16) & 0xFF) / 255
            let g: Double = Double((v >> 8) & 0xFF) / 255
            let b: Double = Double(v & 0xFF) / 255
            return BandLedColor(red: r, green: g, blue: b).opacity(breathe)
        case .flicker:
            let r: Double = sin(Double(z + 1) * 78.233 + Double(Int(t * 40)) * 12.9898) * 43758.5453
            return rest?.opacity(0.25 + 0.75 * (r - floor(r)))
        case .centrePulse:
            if z != z3 { return rest?.opacity(0.35) }
            return rest?.opacity(0.2 + 0.8 * (0.5 + 0.5 * sin(2 * Double.pi * t)))
        case .comet:
            if z == z3 { return rest?.opacity(0.12) }
            let corners: [Int] = [0, 1, 3, 4]
            let d: Int = ((corners.firstIndex(of: z) ?? 0) - Int(t * 8) % 4 + 4) % 4
            if d == 0 { return rest }
            return d == 3 ? rest?.opacity(0.45) : rest?.opacity(0.08)
        case .complex:
            let v: Double = 0.5 + 0.5 * sin(2 * Double.pi * t + Double(z) * 1.3)
            let first: BandLedColor? = m.colors.first.map { BandLedColor.palette($0) }
            let a: BandLedColor = first ?? rest ?? BandLedColor.palette(0x15)
            let b: BandLedColor = m.colors.count > 1 ? BandLedColor.palette(m.colors[1]) : BandLedColor.palette(0x0F)
            return BandLedColor.blend(a, b, v)
        }
    }
}
