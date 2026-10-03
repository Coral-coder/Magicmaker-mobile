import SwiftUI

/// What we expect the packet to look like on the band. A MagicBand+ has five LEDs: one at each
/// corner of the face and one in the centre. Dual colour is centre vs corners, the 5-LED rainbow
/// is one colour per LED, circle chases around the four corners. Pinned above the Lab so it is
/// always visible and follows every change to the packet. Colours are exact; where the motion or
/// the LED order is a guess the model says so and the caption shows APPROX.
struct BandPreviewView: View {
    let hex: String

    private let period: Double = 2.4
    private let center = 4

    var body: some View {
        let model = BandEffectModel.from(hex)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = (context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)) / period
            HStack(spacing: 12) {
                Canvas { ctx, size in
                    let w = min(size.width, size.height)
                    let face = CGRect(x: w * 0.08, y: w * 0.08, width: w * 0.84, height: w * 0.84)
                    let dim = Color(red: 0.08, green: 0.14, blue: 0.23)
                    let ledR = w * 0.085

                    let facePath = Path(roundedRect: face, cornerRadius: w * 0.16)
                    ctx.fill(facePath, with: .color(Color(red: 0.043, green: 0.078, blue: 0.14)))
                    ctx.stroke(facePath, with: .color(MMTheme.panelLine), lineWidth: w * 0.012)

                    // LED 0..3 corners clockwise from top-left; 4 centre.
                    let inset = w * 0.20
                    let points = [
                        CGPoint(x: face.minX + inset, y: face.minY + inset),
                        CGPoint(x: face.maxX - inset, y: face.minY + inset),
                        CGPoint(x: face.maxX - inset, y: face.maxY - inset),
                        CGPoint(x: face.minX + inset, y: face.maxY - inset),
                        CGPoint(x: face.midX, y: face.midY),
                    ]
                    for (i, p) in points.enumerated() {
                        let c = ledColor(model, i, t) ?? dim
                        if c != dim {
                            ctx.fill(Path(ellipseIn: CGRect(x: p.x - ledR * 2.2, y: p.y - ledR * 2.2, width: ledR * 4.4, height: ledR * 4.4)), with: .color(c.opacity(0.30)))
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

    /// Colour of LED `i` (0..3 corners clockwise from top-left, 4 centre) at phase `t`, or nil for off.
    private func ledColor(_ m: BandEffectModel, _ i: Int, _ t: Double) -> Color? {
        func pal(_ idx: Int) -> Color { starlightGlowColor(idx) }
        let breathe = 0.75 + 0.25 * sin(2 * Double.pi * t)
        let isCenter = i == center
        switch m.kind {
        case .none, .ping: return nil
        case .single, .wand: return m.colors.first.map { pal($0).opacity(breathe) }
        case .dual:
            let idx = isCenter ? m.colors.first : (m.colors.count > 1 ? m.colors[1] : nil)
            return idx.map { pal($0) }
        case .rainbow:
            guard !m.colors.isEmpty else { return nil }
            let shift = m.approximate ? Int(t * Double(m.colors.count)) : 0
            return pal(m.colors[(i + shift) % m.colors.count])
        case .crossfade:
            guard let a = m.colors.first else { return nil }
            let b = m.colors.count > 1 ? m.colors[1] : a
            let f = 0.5 - 0.5 * cos(2 * Double.pi * t)
            return blend(pal(a), pal(b), f)
        case .circle:
            guard !m.colors.isEmpty else { return nil }
            if isCenter { return pal(m.colors[0]).opacity(0.6) }
            let step = Int(t * 8)
            let lead = step % 4
            let c = pal(m.colors[(i + step) % m.colors.count])
            return i == lead ? c : c.opacity(0.35)
        case .lightning:
            let phase = (t * 3).truncatingRemainder(dividingBy: 1)
            return (phase < 0.08 || (phase > 0.16 && phase < 0.22)) ? .white : pal(0x02).opacity(0.25)
        case .sparkle:
            let r = sin(Double(i) * 12.9898 + t * 40) * 43758.5453
            let v = r - floor(r)
            let base = m.colors.isEmpty ? Color.white : pal(m.colors[i % m.colors.count])
            return v > 0.55 ? base : base.opacity(0.12)
        case .strobe:
            let half = (t * 8).truncatingRemainder(dividingBy: 1) < 0.5
            let c = m.colors.first.map { pal($0) } ?? .white
            let group = isCenter ? 0 : i % 2
            return ((group == 0) == half) ? c : c.opacity(0.1)
        case .complex:
            let v = 0.5 + 0.5 * sin(2 * Double.pi * t + Double(i) * 1.3)
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
