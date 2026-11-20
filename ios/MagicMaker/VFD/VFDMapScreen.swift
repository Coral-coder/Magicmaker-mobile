import Foundation
import SwiftUI

/// MAP tab in the VFD theme: tools/vfd/screens/map.py on the real capture locations.
///
/// CAPTURES / TRANSMITTERS / BOTH, then a pixel plot of every logged position (MapMath's capture
/// points and transmitter estimates, loaded off the main thread like MapScreen does), north up,
/// centred on the mean of everything plotted and about 1000 m across, with a reseau cross every
/// 100 m, a scale bar and the counts in the top border and a legend in the bottom border. Every
/// pin is selectable (the info panel shows what MapScreen's does; × or the bare map closes it).
/// MapKit's street map (pan, zoom) cannot be drawn on the grid: HOLD anywhere on the plot opens a
/// menu with OPEN STREET MAP, which shows the standard MAP screen in a sheet. REFRESH reloads (dim
/// while loading).
@MainActor
enum VFDMapScreen: VFDScreen {
    static let title: String = "CAPTURE MAP"

    static let modes: [String] = ["CAPTURES", "TRANSMITTERS", "BOTH"]
    static let emptyText: String = "NO GPS-TAGGED CAPTURES YET — RECORD A SESSION WITH LOCATION ON"
    /// mapInitialSpanMeters: about what the standard map first shows across.
    static let spanMeters: Double = 1000
    /// Reseau and scale bar step, metres.
    static let gridMeters: Int = 100
    /// Capture tap bins: at least this many cells each way (tapRows).
    static let captureBin: Int = 15
    static let captureTag: String = "c|"
    static let txTag: String = "t|"
    /// 7 x 7 transmitter pin: a ring with a centre dot.
    static let txRing: [String] = [
        "..###..",
        ".#...#.",
        "#.....#",
        "#..#..#",
        "#.....#",
        ".#...#.",
        "..###..",
    ]

    static func headerRight(_ ctx: VFDContext) -> (text: String, action: () -> Void)? {
        return (text: "REFRESH", action: {
            VFDMapModel.shared.refresh()
        })
    }

    /// REFRESH is shown disabled while the map loads.
    static func headerRightColor(_ ctx: VFDContext) -> UInt8 {
        return VFDMapModel.shared.data == nil ? VFDInk.dim : VFDInk.highlight
    }

    static func draw(_ ctx: VFDContext) -> Int? {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let model: VFDMapModel = VFDMapModel.shared
        model.sync(ctx)
        let c: Int = L.left
        let w: Int = L.width
        // The map does not scroll with the content: undo the scroll offset.
        let scroll: Int = -fb.originY
        fb.pushClip(0, L.contentTop + scroll, fb.cols, L.contentH, dy: scroll)
        let y: Int = VFDW.options(fb, L, c, L.contentTop, w, VFDMapScreen.modes, selected: model.mode, name: "mode",
                                  onSelect: { (index: Int) in
                                      VFDMapModel.shared.setMode(index)
                                  })
        if let data = model.data, let loaded = model.load {
            if !data.captures.isEmpty || model.centeredOnPhone {
                VFDMapScreen.plot(ctx, model, data, loaded, c, y + 1, w, bottom: L.contentBottom)
            } else {
                VFDMapScreen.centredNote(fb, L, c, y, w, VFDMapScreen.emptyText)
            }
        } else {
            VFDMapScreen.centredNote(fb, L, c, y, w, "LOADING…")
        }
        fb.popClip()
        return nil
    }

    /// HOLD on the plot: MapKit's street map cannot be drawn on the grid, so it opens the standard
    /// MAP screen in a sheet.
    fileprivate static func streetMapMenu(_ ctx: VFDContext) {
        let streetMap: VFDMenuItem = VFDMenuItem("OPEN STREET MAP", action: {
            ctx.openStandard("map")
        })
        ctx.menu(title: VFDMapScreen.title, items: [streetMap])
    }

    // MARK: - Texts (MapScreen's marker titles and details)

    fileprivate static func captureTitle(_ point: CapturePoint) -> String {
        if point.count > 1 { return point.label + " ×\(point.count)" }
        return point.label
    }

    fileprivate static func txTitle(_ estimate: TxEstimate) -> String {
        return shortAddress(estimate.address) + " · est. TX"
    }

    fileprivate static func txDetail(_ estimate: TxEstimate) -> String {
        // The label falls back to the source id when the strongest row had none.
        let label: String = estimate.label == estimate.address ? shortAddress(estimate.address) : estimate.label
        let radius: Int = MapMath.roundToInt(estimate.radiusM)
        let head: String = "\(estimate.count) obs · best \(estimate.bestRssi) dBm"
        return head + " · ±\(radius)m · " + label
    }

    /// What the info panel shows for the tapped pin, with its position (metres from the centre).
    fileprivate static func selectedInfo(_ model: VFDMapModel, _ data: CaptureMapData,
                                         _ loaded: VFDMapLoad) -> VFDMapInfo? {
        guard let tag = model.selection else { return nil }
        if tag.hasPrefix(VFDMapScreen.captureTag) {
            let key: String = String(tag.dropFirst(VFDMapScreen.captureTag.count))
            var i: Int = 0
            for point in data.captures {
                if point.key == key && i < loaded.capX.count && i < loaded.capY.count {
                    return VFDMapInfo(title: captureTitle(point), detail: point.category,
                                      x: loaded.capX[i], y: loaded.capY[i], isTx: false)
                }
                i += 1
            }
            return nil
        }
        if tag.hasPrefix(VFDMapScreen.txTag) {
            let address: String = String(tag.dropFirst(VFDMapScreen.txTag.count))
            var i: Int = 0
            for estimate in data.transmitters {
                if estimate.address == address && i < loaded.txX.count && i < loaded.txY.count {
                    return VFDMapInfo(title: txTitle(estimate), detail: txDetail(estimate),
                                      x: loaded.txX[i], y: loaded.txY[i], isTx: true)
                }
                i += 1
            }
        }
        return nil
    }

    // MARK: - Line breaking

    /// s broken into lines of at most w cells at its " · " separators (dropped at a break); a
    /// segment longer than a line breaks at spaces. Past maxLines the last line takes the rest
    /// (separators kept), cut with ….
    fileprivate static func segmentLines(_ s: String, _ w: Int, maxLines: Int) -> [String] {
        let sep: String = " · "
        var lines: [String] = []
        var joins: [String] = []
        var cur: String = ""
        for segScalars in VFDText.split(VFDText.scalars(s), VFDText.scalars(sep)) {
            let seg: String = VFDText.string(segScalars)
            let cand: String = cur.isEmpty ? seg : cur + sep + seg
            if VFDText.width(cand) <= w {
                cur = cand
                continue
            }
            if !cur.isEmpty {
                lines.append(cur)
                joins.append(sep)
            }
            var words: [String] = VFDText.wrap(seg, w)
            if words.isEmpty {
                words = [""]
            }
            var k: Int = 0
            while k < words.count - 1 {
                lines.append(words[k])
                joins.append(" ")
                k += 1
            }
            cur = words[words.count - 1]
        }
        lines.append(cur)
        joins.append("")
        if maxLines > 0 && lines.count > maxLines {
            var rest: String = ""
            var k: Int = maxLines - 1
            while k < lines.count {
                rest += lines[k] + joins[k]
                k += 1
            }
            var out: [String] = Array(lines[0..<(maxLines - 1)])
            out.append(VFDText.fit(rest, w))
            return out
        }
        return lines
    }

    /// Word wrap in as few lines as w allows, then as narrow as that many lines allow, so a
    /// centred note does not end on a lone word.
    fileprivate static func balancedWrap(_ s: String, _ w: Int) -> [String] {
        let lines: [String] = VFDText.wrap(s, w)
        var best: [String] = lines
        var ww: Int = w - 1
        while ww > 0 {
            let trial: [String] = VFDText.wrap(s, ww)
            if trial.count > lines.count { break }
            var tooWide: Bool = false
            for ln in trial where VFDText.width(ln) > ww {
                tooWide = true
                break
            }
            if tooWide { break }
            best = trial
            ww -= 1
        }
        return best
    }

    /// Centred dim text in the space left (the empty state, or LOADING…).
    fileprivate static func centredNote(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ y: Int, _ w: Int,
                                        _ s: String) {
        let lines: [String] = balancedWrap(s, w - 12)
        let half: Int = VFDMath.floorDiv(lines.count * VFDW.line, 2)
        let mid: Int = max(y, VFDMath.floorDiv(y + L.contentBottom, 2) - half)
        var i: Int = 0
        for ln in lines {
            fb.text(VFDW.cx(c, w, ln), mid + i * VFDW.line, ln, .small, VFDInk.dim)
            i += 1
        }
    }

    // MARK: - Pieces

    fileprivate static func bitmap(_ fb: VFDFrameBuffer, _ c: Int, _ r: Int, _ rows: [String], _ color: UInt8) {
        var j: Int = 0
        for line in rows {
            var i: Int = 0
            for ch in line.unicodeScalars {
                if ch == "#" {
                    fb.set(c + i, r + j, color)
                }
                i += 1
            }
            j += 1
        }
    }

    /// The transmitter pin centred on (x, y).
    fileprivate static func txPin(_ fb: VFDFrameBuffer, _ x: Int, _ y: Int) {
        bitmap(fb, x - 3, y - 3, VFDMapScreen.txRing, VFDInk.highlight)
    }

    /// A capture pin: 2 x 2 cells, top-left on the point.
    fileprivate static func captureDot(_ fb: VFDFrameBuffer, _ x: Int, _ y: Int) {
        fb.fill(x, y, 2, 2, VFDInk.text)
    }

    /// Dotted circle of `radius` cells round (x, y): perimeter cells in angle order, every other
    /// one lit; under 2 cells it is left out (the pin covers it).
    fileprivate static func halo(_ fb: VFDFrameBuffer, _ x: Int, _ y: Int, _ radius: Double) {
        if !(radius >= 2) { return }
        let r: Double = min(radius, 10_000)
        let n: Int = max(16, VFDMath.truncate(2.0 * Double.pi * r * 1.5))
        var ringC: [Int] = []
        var ringR: [Int] = []
        ringC.reserveCapacity(n)
        ringR.reserveCapacity(n)
        for k in 0..<n {
            let a: Double = 2.0 * Double.pi * Double(k) / Double(n)
            let cc: Int = x + VFDMath.roundHalfAway(r * cos(a))
            let rr: Int = y - VFDMath.roundHalfAway(r * sin(a))
            if let lc = ringC.last, let lr = ringR.last, lc == cc && lr == rr {
                continue
            }
            ringC.append(cc)
            ringR.append(rr)
        }
        if ringC.count > 1, let lc = ringC.last, let lr = ringR.last, ringC[0] == lc && ringR[0] == lr {
            ringC.removeLast()
            ringR.removeLast()
        }
        var i: Int = 0
        while i < ringC.count {
            fb.set(ringC[i], ringR[i], VFDInk.dim)
            i += 2
        }
    }

    /// Selection: four L-shaped corners of a (2 * half + 1)-cell square round (x, y).
    fileprivate static func brackets(_ fb: VFDFrameBuffer, _ x: Int, _ y: Int, half: Int) {
        let arm: Int = 3
        let signs: [Int] = [-1, 1]
        for sx in signs {
            for sy in signs {
                let cx: Int = x + sx * half
                let cy: Int = y + sy * half
                fb.hline(min(cx, cx - sx * (arm - 1)), cy, arm, VFDInk.highlight)
                fb.vline(cx, min(cy, cy - sy * (arm - 1)), arm, VFDInk.highlight)
            }
        }
    }

    /// A 3 x 3 cross where two 100 m grid lines meet.
    fileprivate static func reseau(_ fb: VFDFrameBuffer, _ x: Int, _ y: Int) {
        fb.set(x, y, VFDInk.dim)
        fb.set(x - 1, y, VFDInk.dim)
        fb.set(x + 1, y, VFDInk.dim)
        fb.set(x, y - 1, VFDInk.dim)
        fb.set(x, y + 1, VFDInk.dim)
    }

    /// N over a 5-wide up arrow, top-left at (x, y), on a cleared patch.
    fileprivate static func northArrow(_ fb: VFDFrameBuffer, _ x: Int, _ y: Int) {
        fb.fill(x - 2, y - 2, 9, 20, VFDInk.unlit)
        fb.text(x, y, "N", .small, VFDInk.dim)
        for i in 0..<3 {
            fb.hline(x + 2 - i, y + 9 + i, 1 + 2 * i, VFDInk.dim)
        }
        fb.vline(x + 2, y + 12, 4, VFDInk.dim)
    }

    /// Text set into a horizontal border whose line runs at row + 3. Returns the column after the
    /// cleared gap.
    fileprivate static func borderText(_ fb: VFDFrameBuffer, _ x: Int, _ row: Int, _ s: String,
                                       _ color: UInt8) -> Int {
        let tw: Int = VFDText.width(s)
        fb.fill(x - 3, row + 3, tw + 6, 1, VFDInk.unlit)
        fb.text(x, row, s, .small, color)
        return x + tw + 3
    }

    /// A scale bar set into the top border, ending at column `right`: a text-ink bar with end
    /// ticks across the caps, the label after it.
    fileprivate static func scaleBar(_ fb: VFDFrameBuffer, _ right: Int, _ row: Int, _ cells: Int, _ label: String) {
        let lw: Int = VFDText.width(label)
        let x: Int = right - lw - 4 - cells
        fb.fill(x - 3, row + 3, cells + lw + 4 + 6, 1, VFDInk.unlit)
        fb.hline(x, row + 3, cells, VFDInk.text)
        fb.vline(x, row + 1, 5, VFDInk.text)
        fb.vline(x + cells - 1, row + 1, 5, VFDInk.text)
        fb.text(x + cells + 4, row, label, .small, VFDInk.text)
    }

    /// Legend for the layers shown, set into the bottom border (its line at row + 3).
    fileprivate static func legend(_ fb: VFDFrameBuffer, _ x: Int, _ row: Int, _ limit: Int,
                                   showCaptures: Bool, showTx: Bool) {
        var kinds: [Int] = []
        var labels: [String] = []
        if showCaptures {
            kinds.append(0)
            labels.append("CAPTURE")
        }
        if showTx {
            kinds.append(1)
            labels.append("EST. TX")
            kinds.append(2)
            labels.append("±RADIUS")
        }
        var spotX: [Int] = []
        var end: Int = x
        var i: Int = 0
        while i < kinds.count {
            let need: Int = 7 + 4 + VFDText.width(labels[i])
            if end + need > limit { break }
            spotX.append(end)
            end += need + 9
            i += 1
        }
        if spotX.isEmpty { return }
        end -= 9
        fb.fill(x - 3, row + 3, end - x + 6, 1, VFDInk.unlit)
        let haloDots: [(Int, Int)] = [(2, 0), (4, 0), (0, 2), (6, 2), (0, 4), (6, 4), (2, 6), (4, 6)]
        var k: Int = 0
        for sx in spotX {
            let kind: Int = kinds[k]
            if kind == 0 {
                captureDot(fb, sx + 2, row + 2)
            } else if kind == 1 {
                txPin(fb, sx + 3, row + 3)
            } else {
                for d in haloDots {
                    fb.set(sx + d.0, row + d.1, VFDInk.dim)
                }
            }
            fb.text(sx + 11, row, labels[k], .small, VFDInk.dim)
            k += 1
        }
    }

    /// The info panel's lines and box: (title lines, detail lines, top row, height).
    fileprivate static func infoLayout(_ x0: Int, _ x1: Int, _ bottom: Int,
                                       _ info: VFDMapInfo) -> (title: [String], detail: [String], top: Int, h: Int) {
        let iw: Int = x1 - x0 + 1 - 8
        let tw: Int = iw - 5 - 6
        let tlines: [String] = segmentLines(info.title, tw, maxLines: 2)
        var dlines: [String] = []
        if !info.detail.isEmpty {
            dlines = segmentLines(info.detail, iw, maxLines: 3)
        }
        var h: Int = 4 + tlines.count * VFDW.line + 2
        if !dlines.isEmpty {
            h += 3 + dlines.count * VFDW.line
        }
        return (title: tlines, detail: dlines, top: bottom - h + 1, h: h)
    }

    /// MapScreenInfoPanel over the bottom of the plot (columns x0...x1, last row `bottom`):
    /// cleared, dim border, the title (highlight) and details (dim), a pixel ×.
    fileprivate static func infoPanel(_ fb: VFDFrameBuffer, _ x0: Int, _ x1: Int, _ bottom: Int,
                                      _ info: VFDMapInfo) {
        let pw: Int = x1 - x0 + 1
        let ix: Int = x0 + 4
        let lay = infoLayout(x0, x1, bottom, info)
        let top: Int = lay.top
        let h: Int = lay.h
        fb.fill(x0 - 2, top - 2, pw + 4, h + 4, VFDInk.unlit)
        fb.box(x0, top, pw, h, VFDInk.dim)
        var y: Int = top + 4
        for ln in lay.title {
            fb.text(ix, y, ln, .small, VFDInk.highlight)
            y += VFDW.line
        }
        if !lay.detail.isEmpty {
            y += 3
            for ln in lay.detail {
                fb.text(ix, y, ln, .small, VFDInk.dim)
                y += VFDW.line
            }
        }
        let cx: Int = x1 - 4 - 4
        let cy: Int = top + 5
        for i in 0..<5 {
            fb.set(cx + i, cy + i, VFDInk.dim)
            fb.set(cx + 4 - i, cy + i, VFDInk.dim)
        }
        // Taps on the panel itself do nothing (they do not reach the map under it).
        fb.tap(x0, top, pw - 15, h, name: "info")
        fb.tap(cx - 5, top, 15, 15, name: "info:close", action: {
            VFDMapModel.shared.select(nil)
        })
    }

    /// The empty-state note over the top of the map (nothing logged; centred on the phone).
    fileprivate static func emptyBanner(_ fb: VFDFrameBuffer, _ x0: Int, _ x1: Int, _ top: Int) {
        let pw: Int = x1 - x0 + 1
        let lines: [String] = balancedWrap(VFDMapScreen.emptyText, pw - 8)
        let h: Int = 4 + lines.count * VFDW.line + 2
        fb.fill(x0, top, pw, h, VFDInk.unlit)
        fb.box(x0, top, pw, h, VFDInk.dim)
        var i: Int = 0
        for ln in lines {
            fb.text(VFDW.cx(x0, pw, ln), top + 4 + i * VFDW.line, ln, .small, VFDInk.dim)
            i += 1
        }
    }

    // MARK: - The plot

    /// The map box from row `top` down to `bottom`: top border with the counts and the scale
    /// bar, the reseau, halos, pins, selection, info panel, legend in the bottom border.
    fileprivate static func plot(_ ctx: VFDContext, _ model: VFDMapModel, _ data: CaptureMapData,
                                 _ loaded: VFDMapLoad, _ c: Int, _ top: Int, _ w: Int, bottom: Int) {
        let fb: VFDFrameBuffer = ctx.fb
        let capRow: Int = top
        let legRow: Int = bottom - 8
        let boxTop: Int = capRow + 3
        let boxBot: Int = legRow + 3
        if boxBot - boxTop < 40 { return }
        fb.box(c, boxTop, w, boxBot - boxTop + 1, VFDInk.dim)
        let ix0: Int = c + 1
        let ix1: Int = c + w - 2
        let iy0: Int = boxTop + 1
        let iy1: Int = boxBot - 1
        let iw: Int = ix1 - ix0 + 1
        let ih: Int = iy1 - iy0 + 1
        let mpc: Int = max(1, VFDMath.roundHalfAway(VFDMapScreen.spanMeters / Double(iw)))
        let proj = VFDMapProjection(ccol: ix0 + VFDMath.floorDiv(iw, 2), crow: VFDMath.floorDiv(iy0 + iy1, 2),
                                    mpc: mpc)
        let showCaptures: Bool = model.mode != 1
        let showTx: Bool = model.mode != 0
        let info: VFDMapInfo? = VFDMapScreen.selectedInfo(model, data, loaded)

        // Cells the north arrow, the info panel and the transmitter pins clear later: capture
        // dots there take no tap.
        let north: (c: Int, r: Int) = (c: ix1 - 3 - 5, r: iy0 + 7)
        var hidden = VFDMapMask(x0: ix0, y0: iy0, w: iw, h: ih)
        hidden.cover(north.c - 2, north.r - 2, 9, 20)
        if let shown = info {
            let lay = infoLayout(ix0 + 3, ix1 - 3, iy1 - 5, shown)
            hidden.cover(ix0 + 1, lay.top - 2, iw - 2, lay.h + 4)
        }
        var txCells: [(c: Int, r: Int)] = []
        if showTx {
            var i: Int = 0
            while i < data.transmitters.count && i < loaded.txX.count && i < loaded.txY.count {
                let p = proj.at(loaded.txX[i], loaded.txY[i])
                txCells.append(p)
                hidden.cover(p.c - 3, p.r - 3, 7, 7)
                i += 1
            }
        }

        // Taps, bottom to top: the bare map (clears the selection), the capture bins, the
        // transmitter pins, then the info panel. A hold on any of the first three opens the
        // street-map menu.
        let hold: () -> Void = {
            VFDMapScreen.streetMapMenu(ctx)
        }
        fb.tap(ix0, iy0, iw, ih, name: "map", action: {
            VFDMapModel.shared.select(nil)
        }, long: hold)
        fb.pushClip(ix0, iy0, iw, ih)
        VFDMapScreen.drawReseau(fb, proj, ix0, ix1, iy0, iy1)
        if showCaptures {
            var capCells: [(c: Int, r: Int)] = []
            var i: Int = 0
            while i < data.captures.count && i < loaded.capX.count && i < loaded.capY.count {
                let p = proj.at(loaded.capX[i], loaded.capY[i])
                capCells.append(p)
                captureDot(fb, p.c, p.r)
                i += 1
            }
            VFDMapScreen.captureTaps(fb, ix0, iy0, iw, ih, capCells, hidden, data.captures, long: hold)
        }
        if showTx {
            var i: Int = 0
            for p in txCells {
                halo(fb, p.c, p.r, data.transmitters[i].radiusM / Double(mpc))
                i += 1
            }
            i = 0
            for p in txCells {
                fb.fill(p.c - 3, p.r - 3, 7, 7, VFDInk.unlit)
                txPin(fb, p.c, p.r)
                let address: String = data.transmitters[i].address
                fb.tap(p.c - 7, p.r - 7, 15, 15, name: "marker:t|" + shortAddress(address), action: {
                    VFDMapModel.shared.select(VFDMapScreen.txTag + address)
                }, long: hold)
                i += 1
            }
        }
        if let shown = info {
            let p = proj.at(shown.x, shown.y)
            brackets(fb, p.c, p.r, half: shown.isTx ? 6 : 5)
        }
        northArrow(fb, north.c, north.r)
        if data.captures.isEmpty {
            emptyBanner(fb, ix0 + 3, ix1 - 3, iy0 + 4)
        }
        if let shown = info {
            infoPanel(fb, ix0 + 3, ix1 - 3, iy1 - 5, shown)
        }
        fb.popClip()

        let counts: String = "\(data.captures.count) PTS · \(data.transmitters.count) TX"
        let end: Int = borderText(fb, c + 6, capRow, counts, VFDInk.dim)
        let bar: Int = VFDMapScreen.gridMeters / mpc
        let scaleLabel: String = "\(VFDMapScreen.gridMeters) M"
        let need: Int = end + 6 + bar + 4 + VFDText.width(scaleLabel) + 6
        if need <= c + w - 3 {
            scaleBar(fb, c + w - 7, capRow, bar, scaleLabel)
        }
        legend(fb, c + 6, legRow, c + w - 6, showCaptures: showCaptures, showTx: showTx)
    }

    /// A reseau cross every 100 m (whole multiples of 100 m from the centre), inside the plot.
    fileprivate static func drawReseau(_ fb: VFDFrameBuffer, _ proj: VFDMapProjection, _ ix0: Int, _ ix1: Int,
                                       _ iy0: Int, _ iy1: Int) {
        let grid: Double = Double(VFDMapScreen.gridMeters)
        let m: Double = Double(proj.mpc)
        let left: Double = -Double(proj.ccol - ix0) * m
        let below: Double = -Double(iy1 - proj.crow) * m
        let right: Double = Double(ix1 - proj.ccol) * m + grid
        let above: Double = Double(proj.crow - iy0) * m + grid
        let gx0: Double = (left / grid).rounded(.down) * grid
        let gy0: Double = (below / grid).rounded(.down) * grid
        var gx: Double = gx0
        var guardX: Int = 0
        while gx <= right && guardX < 1000 {
            var gy: Double = gy0
            var guardY: Int = 0
            while gy <= above && guardY < 1000 {
                let p = proj.at(gx, gy)
                if ix0 + 2 <= p.c && p.c <= ix1 - 2 && iy0 + 2 <= p.r && p.r <= iy1 - 2 {
                    reseau(fb, p.c, p.r)
                }
                gy += grid
                guardY += 1
            }
            gx += grid
            guardX += 1
        }
    }

    /// One tap per capture bin (the plot split into equal bins at least captureBin cells each
    /// way): a bin holding visible capture dots selects its highest-count capture (the list is in
    /// count order, so the first one met), as MapKit picks the frontmost marker. Registered
    /// before the transmitter pins, so the pins stay on top.
    fileprivate static func captureTaps(_ fb: VFDFrameBuffer, _ x0: Int, _ y0: Int, _ w: Int, _ h: Int,
                                        _ cells: [(c: Int, r: Int)], _ hidden: VFDMapMask,
                                        _ captures: [CapturePoint], long: (() -> Void)?) {
        let bin: Int = VFDMapScreen.captureBin
        let nx: Int = max(1, w / bin)
        let ny: Int = max(1, h / bin)
        var xs: [Int] = []
        for k in 0...nx {
            xs.append(x0 + VFDMath.floorDiv(w * k, nx))
        }
        var ys: [Int] = []
        for k in 0...ny {
            ys.append(y0 + VFDMath.floorDiv(h * k, ny))
        }
        var picked: [Int: Int] = [:]
        var i: Int = 0
        let offsets: [(Int, Int)] = [(0, 0), (1, 0), (0, 1), (1, 1)]
        for p in cells {
            for d in offsets {
                let qx: Int = p.c + d.0
                let qy: Int = p.r + d.1
                if qx < x0 || qx >= x0 + w || qy < y0 || qy >= y0 + h { continue }
                if hidden.covered(qx, qy) { continue }
                let bx: Int = VFDMapScreen.binOf(xs, nx, w, x0, qx)
                let by: Int = VFDMapScreen.binOf(ys, ny, h, y0, qy)
                let key: Int = by * nx + bx
                if picked[key] == nil {
                    picked[key] = i
                }
            }
            i += 1
        }
        for key in picked.keys.sorted() {
            guard let index = picked[key], index < captures.count else { continue }
            let bx: Int = key % nx
            let by: Int = key / nx
            let tagKey: String = captures[index].key
            let tapW: Int = xs[bx + 1] - xs[bx]
            let tapH: Int = ys[by + 1] - ys[by]
            fb.tap(xs[bx], ys[by], tapW, tapH, name: "marker:c|\(index)", action: {
                VFDMapModel.shared.select(VFDMapScreen.captureTag + tagKey)
            }, long: long)
        }
    }

    /// The bin of v among integer edges (settled exactly).
    fileprivate static func binOf(_ edges: [Int], _ n: Int, _ size: Int, _ origin: Int, _ v: Int) -> Int {
        var k: Int = VFDMath.floorDiv((v - origin) * n, max(1, size))
        k = min(max(k, 0), n - 1)
        while k + 1 < n && edges[k + 1] <= v {
            k += 1
        }
        return k
    }
}

// MARK: - Plot geometry

/// Metres (east, north of the centre) to plot cells.
private struct VFDMapProjection {
    let ccol: Int
    let crow: Int
    let mpc: Int

    func at(_ x: Double, _ y: Double) -> (c: Int, r: Int) {
        let m: Double = Double(max(1, mpc))
        let dc: Int = VFDMath.roundHalfAway(x / m)
        let dr: Int = VFDMath.roundHalfAway(y / m)
        return (c: ccol + dc, r: crow - dr)
    }
}

/// Plot cells that something drawn later clears.
private struct VFDMapMask {
    let x0: Int
    let y0: Int
    let w: Int
    let h: Int
    private var cells: [Bool]

    init(x0: Int, y0: Int, w: Int, h: Int) {
        self.x0 = x0
        self.y0 = y0
        self.w = max(0, w)
        self.h = max(0, h)
        self.cells = [Bool](repeating: false, count: max(0, w) * max(0, h))
    }

    mutating func cover(_ c: Int, _ r: Int, _ cw: Int, _ ch: Int) {
        let a: Int = max(c, x0)
        let b: Int = min(c + cw, x0 + w)
        let top: Int = max(r, y0)
        let bot: Int = min(r + ch, y0 + h)
        if a >= b || top >= bot { return }
        var y: Int = top
        while y < bot {
            let base: Int = (y - y0) * w
            var x: Int = a
            while x < b {
                cells[base + x - x0] = true
                x += 1
            }
            y += 1
        }
    }

    func covered(_ c: Int, _ r: Int) -> Bool {
        if c < x0 || c >= x0 + w || r < y0 || r >= y0 + h { return false }
        return cells[(r - y0) * w + (c - x0)]
    }
}

/// The tapped pin: what the info panel shows and where the pin is (metres from the centre).
private struct VFDMapInfo {
    let title: String
    let detail: String
    let x: Double
    let y: Double
    let isTx: Bool
}

/// One load: MapMath's points, the mean of everything plotted (nil when there is nothing), and
/// every point's position in metres east / north of that centre.
private struct VFDMapLoad {
    let data: CaptureMapData
    let center: (lat: Double, lng: Double)?
    let capX: [Double]
    let capY: [Double]
    let txX: [Double]
    let txY: [Double]
}

/// Streams every logged position off the main thread and turns them into map points, after the
/// rows still queued for the session file have been written (as MapScreen does).
private func vfdMapLoadData() -> VFDMapLoad {
    SessionLogFiles.flushPendingRows()
    var builder = MapMath.Builder()
    SessionLogFiles.forEachLoggedLocation { lat, lng, rssi, address, label, category in
        builder.add(lat: lat, lng: lng, rssi: rssi, address: address, label: label, category: category)
    }
    let data: CaptureMapData = builder.build()
    guard let center = MapMath.center(of: data) else {
        return VFDMapLoad(data: data, center: nil, capX: [], capY: [], txX: [], txY: [])
    }
    let mLat: Double = MapMath.metersPerDegree
    let mLng: Double = MapMath.metersPerDegree * cos(center.lat / 180.0 * Double.pi)
    var capX: [Double] = []
    var capY: [Double] = []
    for point in data.captures {
        capX.append((point.lng - center.lng) * mLng)
        capY.append((point.lat - center.lat) * mLat)
    }
    var txX: [Double] = []
    var txY: [Double] = []
    for estimate in data.transmitters {
        txX.append((estimate.lng - center.lng) * mLng)
        txY.append((estimate.lat - center.lat) * mLat)
    }
    return VFDMapLoad(data: data, center: center, capX: capX, capY: capY, txX: txX, txY: txY)
}

// MARK: - Screen state

/// MapScreen's @State, kept while the app runs. `sync` (called at the top of every draw) starts
/// a load when none has been made for the current REFRESH count or tab visit (MapScreen loads
/// each time it appears); the load runs off the main thread and lands later with a redraw.
@MainActor
private final class VFDMapModel {
    static let shared: VFDMapModel = VFDMapModel()
    /// A frame gap this long means the tab was left and opened again.
    static let revisitGap: Double = 2.5

    private(set) var data: CaptureMapData? = nil
    private(set) var load: VFDMapLoad? = nil
    /// Nothing to plot, so the map was centred on the phone's last fix instead.
    private(set) var centeredOnPhone: Bool = false
    /// 0 CAPTURES, 1 TRANSMITTERS, 2 BOTH (MapScreen starts on CAPTURES).
    private(set) var mode: Int = 0
    /// Tag of the tapped pin ("c|<cell>" or "t|<source>").
    private(set) var selection: String? = nil

    private var loadTick: Int = 0
    private var visit: Int = 0
    private var lastFrame: Double = 0
    private var loadDone: String? = nil
    private var loadRunning: String? = nil

    init() {}

    func sync(_ ctx: VFDContext) {
        let t: Double = ctx.time
        if lastFrame > 0 && t - lastFrame > VFDMapModel.revisitGap {
            visit += 1
        }
        if t > lastFrame {
            lastFrame = t
        }
        let key: String = "\(loadTick)|\(visit)"
        if key != loadDone && key != loadRunning {
            start(key, ctx)
        }
    }

    private func start(_ key: String, _ ctx: VFDContext) {
        loadRunning = key
        Task { @MainActor in
            self.data = nil
            self.load = nil
            self.selection = nil
            ctx.redraw()
            let result: VFDMapLoad = await Task.detached(priority: .userInitiated) { () -> VFDMapLoad in
                vfdMapLoadData()
            }.value
            self.finish(result, key: key, ctx)
        }
    }

    /// Centres once per load on the mean of everything plotted; with nothing to plot, on the
    /// phone's last fix when there is one.
    private func finish(_ result: VFDMapLoad, key: String, _ ctx: VFDContext) {
        guard let running = loadRunning, running == key else { return }
        loadRunning = nil
        loadDone = key
        var onPhone: Bool = false
        if result.center == nil, ctx.vm.location.latest != nil {
            onPhone = true
        }
        centeredOnPhone = onPhone
        data = result.data
        load = result
        ctx.redraw()
    }

    /// REFRESH (disabled while loading).
    func refresh() {
        if data == nil { return }
        loadTick += 1
    }

    func setMode(_ index: Int) {
        if index < 0 || index > 2 { return }
        mode = index
        selection = nil
    }

    func select(_ tag: String?) {
        selection = tag
    }
}
