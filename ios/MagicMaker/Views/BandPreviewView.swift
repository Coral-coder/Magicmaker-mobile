import SwiftUI

/// What we expect the packet to look like on the band: a ring of LEDs around the icon disc,
/// animating the decoded `BandEffectModel` in a loop. Pinned above the Lab so it is always
/// visible and follows every change to the packet. Colours are exact; where the motion is a
/// guess the model says so and the caption shows APPROX.
struct BandPreviewView: View {
    let hex: String

    private let leds = 12
    private let period: Double = 2.4

    var body: some View {
        let model = BandEffectModel.from(hex)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = (context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)) / period
            HStack(spacing: 12) {
                Canvas { ctx, size in
                    let cx = size.width / 2, cy = size.height / 2
                    let ringR = min(size.width, size.height) * 0.40
                    let ledR = min(size.width, size.height) * 0.065
                    let dim = Color(red: 0.08, green: 0.14, blue: 0.23)

                    let centre: Color
                    switch model.kind {
                    case .dual: centre = model.colors.first.map { starlightGlowColor($0) } ?? dim
                    case .single, .wand: centre = model.colors.first.map { starlightGlowColor($0).opacity(0.35) } ?? dim
                    default: centre = dim
                    }
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - ringR * 0.45, y: cy - ringR * 0.45, width: ringR * 0.9, height: ringR * 0.9)), with: .color(centre))

                    for i in 0..<leds {
                        let a = 2 * Double.pi * Double(i) / Double(leds) - Double.pi / 2
                        let p = CGPoint(x: cx + ringR * CGFloat(cos(a)), y: cy + ringR * CGFloat(sin(a)))
                        let c = ledColor(model, i, leds, t) ?? dim
                        if c != dim {
                            ctx.fill(Path(ellipseIn: CGRect(x: p.x - ledR * 2.1, y: p.y - ledR * 2.1, width: ledR * 4.2, height: ledR * 4.2)), with: .color(c.opacity(0.28)))
                        }
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - ledR, y: p.y - ledR, width: ledR * 2, height: ledR * 2)), with: .color(c))
                    }
                }
                .aspectRatio(1, contentMode: .fit)

                VStack(alignment: .leading, spacing: 2) {
                    Text("BAND PREVIEW").font(MMTheme.techLabel(9)).foregroundStyle(MMTheme.textDim)
                    Text(model.kind == .none ? "NO EFFECT" : model.kind.rawValue.uppercased())
                        .font(MMTheme.techHeader())
                        .foregroundStyle(model.kind == .none ? MMTheme.textDim : MMTheme.cyan)
                    Text(model.note.uppercased() + (model.approximate ? " · APPROX." : ""))
                        .font(MMTheme.techLabel(9))
                        .foregroundStyle(model.approximate ? MMTheme.amber : MMTheme.textDim)
                        .lineLimit(2)
                    if model.buzz > 0 {
                        let name = LabPacketBuilder.vibrationPatterns.first { $0.id == model.buzz }?.label ?? "#\(model.buzz)"
                        let on = (t * 6).truncatingRemainder(dividingBy: 1) < 0.5
                        Text("BUZZ · \(name.uppercased())")
                            .font(MMTheme.techLabel(9))
                            .foregroundStyle(on ? MMTheme.cyan : MMTheme.cyanDim)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(MMTheme.navy)
    }

    /// Colour of LED `i` of `n` at phase `t` in 0..1, or nil for off. Pure function of the model.
    private func ledColor(_ m: BandEffectModel, _ i: Int, _ n: Int, _ t: Double) -> Color? {
        func pal(_ idx: Int) -> Color { starlightGlowColor(idx) }
        let breathe = 0.75 + 0.25 * sin(2 * Double.pi * t)
        switch m.kind {
        case .none, .ping: return nil
        case .single, .wand: return m.colors.first.map { pal($0).opacity(breathe) }
        case .dual: return m.colors.count > 1 ? pal(m.colors[1]) : nil
        case .rainbow:
            guard !m.colors.isEmpty else { return nil }
            let shift = m.approximate ? Int(t * Double(m.colors.count)) : 0
            return pal(m.colors[(i * m.colors.count / n + shift) % m.colors.count])
        case .crossfade:
            guard let a = m.colors.first else { return nil }
            let b = m.colors.count > 1 ? m.colors[1] : a
            let f = 0.5 - 0.5 * cos(2 * Double.pi * t)
            return blend(pal(a), pal(b), f)
        case .circle:
            guard !m.colors.isEmpty else { return nil }
            let step = Int(t * Double(m.colors.count) * 2)
            let idx = ((i + step) % n) * m.colors.count / n
            let c = pal(m.colors[idx % m.colors.count])
            return (i + step) % n == 0 ? c : c.opacity(0.55)
        case .lightning:
            let phase = (t * 3).truncatingRemainder(dividingBy: 1)
            return (phase < 0.08 || (phase > 0.16 && phase < 0.22)) ? .white : pal(0x02).opacity(0.25)
        case .sparkle:
            let r = sin(Double(i) * 12.9898 + t * 40) * 43758.5453
            let v = r - floor(r)
            let base = m.colors.isEmpty ? Color.white : pal(m.colors[i % m.colors.count])
            return v > 0.6 ? base : base.opacity(0.12)
        case .strobe:
            let half = (t * 8).truncatingRemainder(dividingBy: 1) < 0.5
            let c = m.colors.first.map { pal($0) } ?? .white
            return ((i % 2 == 0) == half) ? c : c.opacity(0.1)
        case .complex:
            let v = 0.5 + 0.5 * sin(2 * Double.pi * t + Double(i) * 0.9)
            return blend(pal(0x15), pal(0x0F), v)
        }
    }

    private func blend(_ a: Color, _ b: Color, _ f: Double) -> Color {
        let ua = UIColor(a), ub = UIColor(b)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        ua.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        ub.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let k = CGFloat(f)
        return Color(red: r1 + (r2 - r1) * k, green: g1 + (g2 - g1) * k, blue: b1 + (b2 - b1) * k)
    }
}
