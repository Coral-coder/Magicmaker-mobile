import SwiftUI

/// What we expect the packet to look like on the band: the square face with its five LEDs
/// (four corners and the centre), animating the decoded `BandEffectModel` in a loop. Pinned above
/// the Lab so it is always visible and follows every change to the packet. Colours are exact;
/// where the motion or LED order is reproduced from other decoders the caption shows APPROX.
struct BandPreviewView: View {
    let hex: String
    var compact: Bool = false
    var title: String = "BAND PREVIEW"

    private let period: Double = 2.4
    private let z3 = 2   // centre zone index

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
                        let c = ledColor(model, z, t) ?? dim
                        if c != dim {
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
                    Text(model.kind == .none ? "NO EFFECT" : kindName(model.kind))
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
                        let on = (t * 6).truncatingRemainder(dividingBy: 1) < 0.5
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

    private func kindName(_ k: BandEffectModel.Kind) -> String {
        switch k {
        case .pulseBurst: return "PULSE BURST"
        case .repeatFade: return "REPEAT FADE"
        case .centrePulse: return "CENTRE PULSE"
        default: return k.rawValue.uppercased()
        }
    }

    /// Colour of zone `z` (0..4 = Z1..Z5) at phase `t` in 0..1, or nil for off.
    private func ledColor(_ m: BandEffectModel, _ z: Int, _ t: Double) -> Color? {
        func pal(_ idx: Int?) -> Color? { idx.map { starlightGlowColor($0) } }
        let rest = pal(m.perLed.indices.contains(z) ? m.perLed[z] : nil)
        let breathe = 0.75 + 0.25 * sin(2 * Double.pi * t)
        switch m.kind {
        case .none, .ping: return nil
        case .single, .wand: return rest?.opacity(breathe)
        case .dual: return rest
        case .toggle:
            let a = m.perLed.compactMap { $0 }.first
            let b = m.perLed.compactMap { $0 }.first { $0 != a } ?? a
            return pal((t * 4).truncatingRemainder(dividingBy: 1) < 0.5 ? a : b)
        case .rainbow:
            if m.note.contains("cycle"), m.perLed.allSatisfy({ $0 != nil }) {
                let shift = Int(t * 5)
                return pal(m.perLed[(z + shift) % 5])
            }
            return rest
        case .rotate:
            let order = [1, 2, 3, 4, 0]
            let pos = order.firstIndex(of: z) ?? 0
            let step = Int(t * 10)
            return pal(m.perLed[order[(pos + step) % 5]])
        case .crossfade:
            guard let a = pal(m.colors.first) else { return nil }
            let b = pal(m.colors.count > 1 ? m.colors[1] : m.colors[0]) ?? a
            let f = 0.5 - 0.5 * cos(2 * Double.pi * t)
            return z == z3 ? blend(b, a, f) : blend(a, b, f)
        case .pulseBurst:
            let pos = (t * 2.4).truncatingRemainder(dividingBy: 1.5)
            if pos >= 1 { return rest?.opacity(0.05) }
            let sub = pos.truncatingRemainder(dividingBy: 0.5)
            let bright = sub < 0.25 ? sub / 0.25 : 1 - (sub - 0.25) / 0.25
            return rest?.opacity(0.1 + 0.9 * bright)
        case .circle:
            if z == z3 { return rest?.opacity(0.15) }
            let corners = [0, 1, 3, 4]
            let pos = corners.firstIndex(of: z) ?? 0
            let head = Int(t * 8) % 4
            let d = (pos - head + 4) % 4
            let base = rest ?? starlightGlowColor(0x19)
            return (d == 0 || d == 2) ? base : base.opacity(0.3)
        case .twinkle:
            let r = sin(Double(z) * 12.9898 + t * 40) * 43758.5453
            let v = r - floor(r)
            return v > 0.6 ? rest : rest?.opacity(0.12)
        case .alternate:
            if z == z3 { return rest }
            let half = (t * 2.4).truncatingRemainder(dividingBy: 1) < 0.5
            let isA = z == 0 || z == 3
            return isA == half ? rest : rest?.opacity(0.08)
        case .repeatFade:
            let pos = (t * 2.4).truncatingRemainder(dividingBy: 1.25)
            let bright = pos < 1 ? 1 - pos : 0
            return rest?.opacity(0.05 + 0.95 * bright)
        case .lightning:
            let phase = (t * 3).truncatingRemainder(dividingBy: 1)
            return (phase < 0.08 || (phase > 0.16 && phase < 0.22)) ? .white : Color.white.opacity(0.15)
        case .strobe:
            let pos = (t * 5).truncatingRemainder(dividingBy: 5)
            if pos < 0.5 { return starlightGlowColor(0x11) }
            if pos < 1 { return starlightGlowColor(0x13) }
            return starlightGlowColor(0x13).opacity(0.05)
        case .stepper:
            guard !m.colors.isEmpty else { return rest }
            let step = (Int(t * 4.8) + z) % m.colors.count
            return pal(m.colors[step])
        case .rgb:
            let v = m.rgb ?? 0x9E9E9E
            return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255).opacity(breathe)
        case .flicker:
            let r = sin(Double(z + 1) * 78.233 + Double(Int(t * 40)) * 12.9898) * 43758.5453
            return rest?.opacity(0.25 + 0.75 * (r - floor(r)))
        case .centrePulse:
            if z != z3 { return rest?.opacity(0.35) }
            return rest?.opacity(0.2 + 0.8 * (0.5 + 0.5 * sin(2 * Double.pi * t)))
        case .comet:
            if z == z3 { return rest?.opacity(0.12) }
            let corners = [0, 1, 3, 4]
            let d = ((corners.firstIndex(of: z) ?? 0) - Int(t * 8) % 4 + 4) % 4
            return d == 0 ? rest : (d == 3 ? rest?.opacity(0.45) : rest?.opacity(0.08))
        case .complex:
            let v = 0.5 + 0.5 * sin(2 * Double.pi * t + Double(z) * 1.3)
            let a = m.colors.first.map { starlightGlowColor($0) } ?? rest ?? starlightGlowColor(0x15)
            let b = m.colors.count > 1 ? starlightGlowColor(m.colors[1]) : starlightGlowColor(0x0F)
            return blend(a, b, v)
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

/// Scan page: the last packet heard (from the phone's own scan or the Android relay), as the band
/// would show it. One row, always at the top.
struct LastHeardStrip: View {
    @EnvironmentObject var vm: AppViewModel

    private var last: (hex: String, count: Int)? {
        let local = vm.livePackets.max(by: { $0.timestampMs < $1.timestampMs })
        let relay = vm.androidLivePackets.max(by: { $0.timestampMs < $1.timestampMs })
        let count = vm.livePackets.count + vm.androidLivePackets.count
        switch (local, relay) {
        case let (l?, r?): return (l.timestampMs >= r.timestampMs ? l.hex : r.hex, count)
        case let (l?, nil): return (l.hex, count)
        case let (nil, r?): return (r.hex, count)
        default: return nil
        }
    }

    var body: some View {
        if let last {
            BandPreviewView(hex: last.hex, compact: true, title: "LAST HEARD · \(last.count) LIVE")
                .frame(height: 40)
        } else {
            HStack {
                Text("LAST HEARD · NOTHING YET").font(MMTheme.techLabel(9)).foregroundStyle(MMTheme.textDim)
                Spacer()
            }
            .frame(height: 40)
            .padding(.horizontal, 12)
            .background(MMTheme.navy)
        }
    }
}
