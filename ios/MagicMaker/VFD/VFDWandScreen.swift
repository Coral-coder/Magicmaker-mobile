import Foundation
import SwiftUI
import UIKit

/// WAND tab in the VFD theme: tools/vfd/screens/wand.py on the real wand libraries and TxEngine.
///
/// The library area fills the space above the controls panel, which sits at the bottom:
/// - STARLIGHT (StarlightWandView): the wand as pixel art, its rod and aura lit in the true glow
///   colour of the colour last heard or picked, the send pulse (two dotted rings expanding 0.42 s
///   ease-out, the second 0.18 s later, as runTransmitPulse); a tap on the wand steps to the next
///   colour; the picker row (glow swatch, colour name, middle-truncated code, a menu of every
///   colour plus DELETE) and SEND.
/// - NEW WAND (WandCodeList): the 288 generated codes in their own scroll region; tap sends, hold
///   renames.
/// Controls: STARLIGHT / NEW WAND, the programmable quick button (tap sends, hold reprograms), the
/// wand loop, its interval slider, LIB n with CLR LIB (Starlight only) and the status line.
@MainActor
enum VFDWandScreen: VFDScreen {
    static let title: String = "WAND"

    static let emptyText: String = "HEAR A WAND COLOR · SCAN TO LEARN"
    /// Scroll region id of the New Wand code list.
    static let codesRegion: String = "codes"
    /// The picker row's height in cells.
    static let pickH: Int = 26

    static func headerRight(_ ctx: VFDContext) -> (text: String, action: () -> Void)? {
        return nil
    }

    static func draw(_ ctx: VFDContext) -> Int? {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let ui: VFDUIState = ctx.ui
        let st: VFDWandState = VFDWandScreen.state(ctx, ui)
        // The tab does not scroll as a whole: undo any page scroll (the code list scrolls itself).
        let scroll: Int = -fb.originY
        fb.pushClip(0, L.contentTop + scroll, fb.cols, L.contentH, dy: scroll)
        // The controls are anchored to the bottom of the content region; the library area fills
        // the rest (libraryArea .frame(maxHeight: .infinity) over the controls panel).
        let probe: VFDFrameBuffer = VFDFrameBuffer(cols: fb.cols, rows: fb.rows)
        let probeTop: Int = L.contentTop + 40
        let controlsH: Int = VFDWandScreen.drawControls(ctx, ui, st, probe, top: probeTop) - probeTop
        let ctop: Int = L.contentBottom - controlsH
        if st.newWand {
            VFDWandScreen.newWandArea(ctx, ui, st, fb, top: L.contentTop, bottom: ctop)
        } else {
            VFDWandScreen.starlightArea(ctx, ui, st, fb, top: L.contentTop, bottom: ctop)
        }
        _ = VFDWandScreen.drawControls(ctx, ui, st, fb, top: ctop)
        fb.popClip()
        return nil
    }

    // MARK: - State (read only)

    /// The list for the current mode: Starlight colours (one per colour, no New Wand codes) or the
    /// New Wand codes.
    fileprivate static func library(_ store: MagicStore, newWand: Bool) -> [MagicPacket] {
        if newWand {
            return store.newWandPackets()
        }
        return VFDWandScreen.starlightColors(store.learnedStarlightPackets())
    }

    /// WandScreen.starlightColors.
    fileprivate static func starlightColors(_ learned: [MagicPacket]) -> [MagicPacket] {
        var seen = Set<Int>()
        var out: [MagicPacket] = []
        for packet in learned {
            if VFDWandScreen.isNewWandHex(packet.hex) { continue }
            let index: Int = MagicClassifier.starlightColorIndex(packet.hex) & 0x1F
            if seen.insert(index).inserted {
                out.append(packet)
            }
        }
        return out
    }

    fileprivate static func isNewWandHex(_ hex: String) -> Bool {
        return hex.uppercased().contains("CF0B00C020224EAC7807866")
    }

    /// WandScreen.intervalSec: follows tx.starlightIntervalMs, or the last committed slider
    /// value while the engine's interval has not changed since.
    fileprivate static func interval(_ ctx: VFDContext, _ ui: VFDUIState) -> Float {
        let ms: Int = ctx.tx.starlightIntervalMs
        if ui.has("intervalSec") && ui.int("intervalMs") == ms {
            return Float(ui.double("intervalSec"))
        }
        return TxLoopInterval.seconds(fromMilliseconds: ms)
    }

    /// WandScreen.selectedId: the last sent colour while the loop's colour, the list and the mode
    /// have not changed since; else the loop's colour, or the first one (reconcileSelection).
    fileprivate static func selection(_ ctx: VFDContext, _ ui: VFDUIState, _ library: [MagicPacket],
                                      newWand: Bool) -> Int64 {
        let loopId: Int64 = ctx.tx.starlightLoopPacketId
        let firstId: Int64 = library.first?.id ?? -1
        var wanted: Int64 = loopId >= 0 ? loopId : firstId
        let storedLoop: Int64 = Int64(ui.int("selLoop"))
        let sameLoop: Bool = ui.has("sel") && storedLoop == loopId
        let sameList: Bool = ui.int("selCount") == library.count && ui.bool("selNew") == newWand
        if sameLoop && sameList {
            wanted = Int64(ui.int("sel"))
        }
        let candidate: Int64 = wanted
        if candidate >= 0 && !library.contains(where: { (p: MagicPacket) -> Bool in p.id == candidate }) {
            wanted = firstId
        }
        return wanted
    }

    /// The codes of the list in order, joined (StarlightWandView.entryKeys).
    fileprivate static func entryKeys(_ entries: [MagicPacket]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(entries.count)
        for packet in entries {
            parts.append(packet.hex)
        }
        return parts.joined(separator: ",")
    }

    /// StarlightWandView's selectedIndex and glowColorIndex: the colour last picked (tap on the
    /// wand or the menu) while the heard colour and the list have not changed since; otherwise
    /// syncHeardColor: the glow follows vm.wandDisplayColorIndex and the picker its first entry
    /// of that colour (a list of another length starts again from its first entry).
    fileprivate static func picker(_ ctx: VFDContext, _ ui: VFDUIState,
                                   _ entries: [MagicPacket]) -> (index: Int, glow: Int, keys: String) {
        let keys: String = VFDWandScreen.entryKeys(entries)
        let heardRaw: Int = ctx.vm.wandDisplayColorIndex
        let count: Int = entries.count
        let picked: Bool = ui.has("pickIdx")
        if picked && ui.int("pickHeard") == heardRaw && ui.string("pickKeys") == keys {
            let idx: Int = count > 0 ? min(max(ui.int("pickIdx"), 0), count - 1) : 0
            return (index: idx, glow: ui.int("pickGlow"), keys: keys)
        }
        let heard: Int = heardRaw & 0x1F
        var idx: Int = 0
        if picked && ui.int("pickCount") == count {
            idx = ui.int("pickIdx")
        }
        var i: Int = 0
        for packet in entries {
            if MagicClassifier.starlightColorIndex(packet.hex) == heard {
                idx = i
                break
            }
            i += 1
        }
        if count > 0 {
            idx = min(max(idx, 0), count - 1)
        } else {
            idx = 0
        }
        return (index: idx, glow: heard, keys: keys)
    }

    fileprivate static func state(_ ctx: VFDContext, _ ui: VFDUIState) -> VFDWandState {
        let newWand: Bool = ui.bool("newWand")
        let list: [MagicPacket] = VFDWandScreen.library(ctx.store, newWand: newWand)
        let selected: Int64 = VFDWandScreen.selection(ctx, ui, list, newWand: newWand)
        var selectedPacket: MagicPacket? = nil
        for packet in list where packet.id == selected {
            selectedPacket = packet
            break
        }
        var entries: [MagicPacket] = []
        if !newWand {
            entries = list
        }
        let picked = VFDWandScreen.picker(ctx, ui, entries)
        return VFDWandState(
            newWand: newWand,
            library: list,
            selectedId: selected,
            selectedPacket: selectedPacket,
            intervalSec: VFDWandScreen.interval(ctx, ui),
            dragging: ui.bool("dragging"),
            dragStop: ui.int("dragStop"),
            pickIndex: picked.index,
            glowIndex: picked.glow,
            keys: picked.keys
        )
    }

    /// txStatusLineColor: alarm ink when the last packet did not go out.
    fileprivate static func statusInk(_ status: String) -> UInt8 {
        if status == TxEngine.notLinkedStatus || status == TxEngine.sendFailedStatus {
            return VFDInk.alarm
        }
        return VFDInk.dim
    }

    /// The quick button's label as reloadWandQuickIfChanged would read it (a library import may
    /// have replaced it since the view model last read it).
    fileprivate static func quickLabel(_ vm: AppViewModel) -> String {
        return UserDefaults.standard.string(forKey: "wand_quick_label") ?? "OFF"
    }

    /// Points to whole cells on this screen (wand.py _pt) at the renderer's scale and pitch
    /// (5 px at 3x, 4 px at 2x).
    fileprivate static func cells(_ ctx: VFDContext, _ points: Int) -> Int {
        return ctx.cells(points: Double(points))
    }

    // MARK: - Starlight

    /// StarlightWandView in rows top ..< bottom: the wand, then the picker row 10 pt above the
    /// bottom padding (or the empty text in its place).
    fileprivate static func starlightArea(_ ctx: VFDContext, _ ui: VFDUIState, _ st: VFDWandState,
                                          _ fb: VFDFrameBuffer, top: Int, bottom: Int) {
        let L: VFDLayout = ctx.L
        let c: Int = L.left
        let w: Int = L.width
        let pickTop: Int = bottom - VFDWandScreen.cells(ctx, 8) - VFDWandScreen.pickH
        let wandBottom: Int = pickTop - VFDWandScreen.cells(ctx, 10)
        let avail: Int = wandBottom - top
        if avail >= 24 {
            let H: Int = VFDWandArtCache.fit(avail)
            let art: VFDWandArt = VFDWandArtCache.art(H)
            let span: Int = art.bottom - art.top + 1
            let tip: Int = top + VFDMath.floorDiv(avail - span, 2) - art.top
            let cx: Int = c + VFDMath.floorDiv(w, 2)
            let glow: VFDRGB = VFDColors.starlightGlow(st.glowIndex)
            VFDWandScreen.drawPulse(ctx, ui, fb, cx: cx, tip: tip, H: H, glow: glow)
            VFDWandScreen.drawArt(fb, art, cx: cx, tip: tip, glow: glow)
            fb.tap(c, top, w, wandBottom - top, name: "wand:cycle", action: {
                VFDWandScreen.cycleColor(ctx, ui)
            })
        }
        if st.library.isEmpty {
            let lines: [String] = VFDW.tokenLines(VFDWandScreen.emptyText, w)
            var y: Int = pickTop + VFDMath.floorDiv(VFDWandScreen.pickH - lines.count * VFDW.line, 2) + 2
            for line in lines {
                fb.text(VFDW.cx(c, w, line), y, line, .small, VFDInk.dim)
                y += VFDW.line
            }
        } else {
            VFDWandScreen.pickerRow(ctx, ui, st, fb, c, pickTop, w)
        }
    }

    /// The wand cells: rod in the glow colour (glints lighter), the dotted aura rings in the glow
    /// colour (the outer one fainter), the glove, handle, collar and crystal in the palette inks.
    fileprivate static func drawArt(_ fb: VFDFrameBuffer, _ art: VFDWandArt, cx: Int, tip: Int, glow: VFDRGB) {
        let white: VFDRGB = VFDRGB(r: 255, g: 255, b: 255)
        let glowInk: UInt8 = fb.rgb(glow)
        let glintInk: UInt8 = fb.rgb(VFDWandScreen.mix(glow, white, 0.5))
        let outerInk: UInt8 = fb.rgb(VFDWandScreen.mix(glow, VFDColors.unlit, 0.6))
        let n: Int = art.code.count
        var i: Int = 0
        while i < n {
            let v: UInt8 = art.code[i]
            var ink: UInt8 = v
            if v == VFDWandCode.glow || v == VFDWandCode.auraInner {
                ink = glowInk
            } else if v == VFDWandCode.glint {
                ink = glintInk
            } else if v == VFDWandCode.auraOuter {
                ink = outerInk
            }
            fb.set(cx + art.dx[i], tip + art.dy[i], ink)
            i += 1
        }
    }

    /// runTransmitPulse: two dotted rings over the outer aura, growing to 1.06 x ease-out in
    /// 0.42 s (the second 0.18 s later) and fading as WandAuraLayer's do (peak x (1 - 0.4 p));
    /// they stay at their final size once done, as the standard wand keeps them.
    fileprivate static func drawPulse(_ ctx: VFDContext, _ ui: VFDUIState, _ fb: VFDFrameBuffer,
                                      cx: Int, tip: Int, H: Int, glow: VFDRGB) {
        if !ui.has("pulseStart") { return }
        let elapsed: Double = ctx.time - ui.double("pulseStart")
        if elapsed < 0 { return }
        if elapsed < VFDAnim.pulseDelay + VFDAnim.pulseDuration {
            fb.wantsAnimation = true
        }
        let pulse = VFDAnim.wandPulse(elapsed: elapsed)
        let rings: [(p: Double, strength: Double)] = [
            (p: pulse.second, strength: 0.24 / 0.38),
            (p: pulse.first, strength: 1.0),
        ]
        let hd: Double = Double(H)
        let cy: Int = tip + VFDMath.roundHalfEven(0.272 * hd)
        for ring in rings where ring.p > 0 {
            let scale: Double = 1.0 + ring.p * 0.06
            let rx: Double = max(1.0, 0.096 * hd) * scale
            let ry: Double = 0.312 * hd * scale
            let level: Double = min(1.0, ring.strength * (1.0 - ring.p * 0.4))
            let ink: UInt8 = fb.rgb(VFDWandScreen.mix(glow, VFDColors.unlit, level))
            let points: [(x: Int, y: Int)] = VFDWandArt.ellipse(cx: cx, cy: cy, rx: rx, ry: ry, every: 3)
            for pt in points {
                fb.set(pt.x, pt.y, ink)
            }
        }
    }

    /// a x t + b x (1 - t) per channel.
    fileprivate static func mix(_ a: VFDRGB, _ b: VFDRGB, _ t: Double) -> VFDRGB {
        let u: Double = 1.0 - t
        let r: Double = Double(a.r) * t + Double(b.r) * u
        let g: Double = Double(a.g) * t + Double(b.g) * u
        let bl: Double = Double(a.b) * t + Double(b.b) * u
        return VFDRGB(VFDMath.roundHalfAway(r), VFDMath.roundHalfAway(g), VFDMath.roundHalfAway(bl))
    }

    /// StarlightWandView.pickerRow: the menu label box (glow swatch, colour name, middle-truncated
    /// code, up/down chevrons) and SEND (96 pt wide).
    fileprivate static func pickerRow(_ ctx: VFDContext, _ ui: VFDUIState, _ st: VFDWandState,
                                      _ fb: VFDFrameBuffer, _ c: Int, _ r: Int, _ w: Int) {
        let h: Int = VFDWandScreen.pickH
        let sendW: Int = VFDWandScreen.cells(ctx, 96)
        let gap: Int = 6
        let bw: Int = w - sendW - gap
        fb.box(c, r, bw, h, VFDInk.dim)
        let swatch: UInt8 = fb.rgb(VFDColors.starlightGlow(st.glowIndex))
        VFDWandScreen.ledDot(fb, c + 5, r + 4 + 1, swatch)
        let tx: Int = c + 5 + 5 + 5
        let tw: Int = c + bw - 5 - 7 - 5 - tx
        let name: String = VFDW.upper(StarlightColors.nameFor(st.glowIndex))
        fb.textFit(tx, r + 4, name, tw, .small, VFDInk.text)
        var hex: String = ""
        if st.pickIndex >= 0 && st.pickIndex < st.library.count {
            hex = st.library[st.pickIndex].hex.uppercased()
        }
        fb.text(tx, r + 15, VFDWandScreen.fitMiddle(hex, tw), .small, VFDInk.dim)
        VFDWandScreen.updown(fb, c + bw - 5 - 7, r + 8, VFDInk.dim)
        fb.tap(c, r, bw, h, name: "menu:COLOR", action: {
            VFDWandScreen.colorMenu(ctx, ui)
        })
        let sx: Int = c + bw + gap
        let sw: Int = c + w - sx
        let sendX: Int = sx + VFDMath.floorDiv(sw - VFDText.width("SEND"), 2)
        if !st.library.isEmpty {
            fb.fill(sx, r, sw, h, VFDInk.highlight)
            fb.text(sendX, r + 9, "SEND", .small, VFDInk.unlit)
            fb.tap(sx, r, sw, h, name: "button:SEND", action: {
                VFDWandScreen.sendSelected(ctx, ui)
            })
        } else {
            fb.box(sx, r, sw, h, VFDInk.dim)
            fb.text(sendX, r + 9, "SEND", .small, VFDInk.dim)
        }
    }

    /// A 5 x 5 round LED (corners unlit) with its top-left at (c, r).
    fileprivate static func ledDot(_ fb: VFDFrameBuffer, _ c: Int, _ r: Int, _ color: UInt8) {
        fb.fill(c + 1, r, 3, 5, color)
        fb.fill(c, r + 1, 5, 3, color)
    }

    /// chevron.up.chevron.down: a 7 x 4 up chevron over a 7 x 4 down chevron (rows r ... r + 9).
    fileprivate static func updown(_ fb: VFDFrameBuffer, _ c: Int, _ r: Int, _ color: UInt8) {
        for i in 0..<4 {
            fb.hline(c + 3 - i, r + i, 2 * i + 1, color)
            fb.hline(c + i, r + 6 + i, 7 - 2 * i, color)
        }
    }

    /// s cut in the middle with … to at most n characters (SwiftUI .truncationMode(.middle)); the
    /// tail keeps the extra character so the colour byte at the end stays visible.
    fileprivate static func middle(_ s: String, chars n: Int) -> String {
        let a: [Unicode.Scalar] = VFDText.scalars(s)
        if a.count <= n { return s }
        if n <= 1 { return n == 1 ? VFDText.ellipsis : "" }
        let keep: Int = n - 1
        let head: Int = keep / 2
        let tail: Int = keep - head
        let front: [Unicode.Scalar] = Array(a[0..<head])
        let back: [Unicode.Scalar] = Array(a[(a.count - tail)...])
        return VFDText.string(front) + VFDText.ellipsis + VFDText.string(back)
    }

    /// wand.py fit_middle: middle truncation to maxCols cells.
    fileprivate static func fitMiddle(_ s: String, _ maxCols: Int) -> String {
        let n: Int = VFDText.maxChars(maxCols)
        if VFDText.length(s) <= n { return s }
        if n <= 1 { return VFDText.fit(s, maxCols) }
        return VFDWandScreen.middle(s, chars: n)
    }

    // MARK: - New Wand

    /// WandCodeList in rows top ..< bottom: the dim header line, a rule, then the code rows in
    /// their own scroll region.
    fileprivate static func newWandArea(_ ctx: VFDContext, _ ui: VFDUIState, _ st: VFDWandState,
                                        _ fb: VFDFrameBuffer, top: Int, bottom: Int) {
        let L: VFDLayout = ctx.L
        let c: Int = L.left
        let w: Int = L.width
        let codes: [MagicPacket] = st.library
        var y: Int = top + 1
        let head: String = "NEW WAND · \(codes.count) CODES · TAP SENDS · HOLD RENAMES"
        for line in VFDW.tokenLines(head, w) {
            fb.text(c, y, line, .small, VFDInk.dim)
            y += VFDW.line
        }
        fb.hline(c, y, w, VFDInk.dim)
        let listTop: Int = y + 1
        let viewH: Int = bottom - listTop
        if viewH <= 0 { return }
        let rowH: Int = VFDWandScreen.codeRowH
        let total: Int = codes.count * rowH
        let s: Int = ctx.scroll(VFDWandScreen.codesRegion, limit: total - viewH)
        // The renderer's drag limit is contentRows minus the region's clipped height: register it
        // so that limit is total - viewH, the one used here.
        let clip = fb.clipRect
        let shownTop: Int = max(listTop + fb.originY, clip.r)
        let shownBottom: Int = min(listTop + viewH + fb.originY, clip.r + clip.h)
        let shownRows: Int = max(0, shownBottom - shownTop)
        fb.scrollRegion(id: VFDWandScreen.codesRegion, 0, listTop, fb.cols, viewH,
                        contentRows: total - viewH + shownRows)
        let names: [String: String] = VFDWandNames.current(ctx.vm)
        let win = VFDW.snappedWindow(fb, top: listTop, bottom: bottom, draw: { (target: VFDFrameBuffer) in
            VFDWandScreen.drawCodes(ctx, ui, st, target, codes, names, listTop: listTop, bottom: bottom, scroll: s)
        })
        let firstTap: Int = fb.taps.count
        fb.pushClip(0, win.top - fb.originY, fb.cols, win.bottom - win.top)
        VFDWandScreen.drawCodes(ctx, ui, st, fb, codes, names, listTop: listTop, bottom: bottom, scroll: s)
        fb.popClip()
        if fb.taps.count > firstTap {
            var kept: [VFDHit] = Array(fb.taps[0..<firstTap])
            for hit in fb.taps[firstTap...] where hit.h >= VFDW.tapRows {
                kept.append(hit)
            }
            fb.taps = kept
        }
        VFDW.listScrollbar(fb, listTop, viewH, total, s)
    }

    /// One code row: padding, mid caps, padding, dotted divider.
    fileprivate static let codeRowH: Int = 4 + VFDSize.mid.ascent + 4 + 1

    /// A New Wand code's palette index, as NewWandCatalog names it: the last byte's low 5 bits.
    fileprivate static func codeColorIndex(_ hex: String) -> Int {
        let tail: String = String(hex.suffix(2))
        let value: Int = Int(tail, radix: 16) ?? 0
        return value & 0x1F
    }

    /// WandCodeRow for every code whose row reaches the window: the last 2 bytes in mid size
    /// (dim; the selected one inverted), the custom name or palette colour right-aligned (dim;
    /// the selected one highlight) after a 5 x 5 dot in the code's true colour. Tap sends, hold
    /// renames.
    fileprivate static func drawCodes(_ ctx: VFDContext, _ ui: VFDUIState, _ st: VFDWandState,
                                      _ target: VFDFrameBuffer, _ codes: [MagicPacket], _ names: [String: String],
                                      listTop: Int, bottom: Int, scroll: Int) {
        let L: VFDLayout = ctx.L
        let c: Int = L.left
        let w: Int = L.width
        let rowH: Int = VFDWandScreen.codeRowH
        let ascent: Int = VFDSize.mid.ascent
        var i: Int = max(0, VFDMath.floorDiv(scroll - rowH, rowH))
        var yy: Int = listTop - scroll + i * rowH
        while i < codes.count {
            if yy > bottom { break }
            if yy + rowH < listTop {
                yy += rowH
                i += 1
                continue
            }
            let packet: MagicPacket = codes[i]
            let hexUpper: String = packet.hex.uppercased()
            let key: String = String(hexUpper.suffix(4))
            let custom: String? = names[hexUpper]
            let nm: String = VFDW.upper(custom ?? packet.colors)
            let sel: Bool = packet.id == st.selectedId
            let kx: Int = c + 2
            let ky: Int = yy + 4
            var kend: Int = kx
            if sel {
                target.fill(kx - 2, ky - 2, VFDText.width(key, size: .mid) + 4, ascent + 4, VFDInk.highlight)
                kend = target.text(kx, ky, key, .mid, VFDInk.unlit)
            } else {
                kend = target.text(kx, ky, key, .mid, VFDInk.dim)
            }
            let nx: Int = kend + 8
            let nameRow: Int = ky + VFDMath.floorDiv(ascent - 7, 2)
            // The code's palette colour as a 5 x 5 true-colour dot before its name (the name stays).
            let dotRoom: Int = 5 + 4
            let shownName: String = VFDText.fit(nm, c + w - nx - dotRoom)
            let nameInk: UInt8 = sel ? VFDInk.highlight : VFDInk.dim
            let nameStart: Int = target.textRight(c + w - 1, nameRow, shownName, .small, nameInk)
            let dotRGB: VFDRGB = VFDColors.starlightGlow(VFDWandScreen.codeColorIndex(packet.hex))
            VFDWandScreen.ledDot(target, nameStart - dotRoom, nameRow + 1, target.rgb(dotRGB))
            target.hline(c, yy + rowH - 1, w, VFDInk.dim, step: 2)
            target.tap(c, yy, w, rowH, name: "code:" + key, action: {
                VFDWandScreen.transmitColor(ctx, ui, packet)
            }, long: {
                VFDWandScreen.beginRename(ctx, packet)
            })
            yy += rowH
            i += 1
        }
    }

    // MARK: - Controls

    /// The controls panel from row `top` (the divider). Returns the next free row.
    fileprivate static func drawControls(_ ctx: VFDContext, _ ui: VFDUIState, _ st: VFDWandState,
                                         _ fb: VFDFrameBuffer, top: Int) -> Int {
        let L: VFDLayout = ctx.L
        let tx: TxEngine = ctx.tx
        let c: Int = L.left
        let w: Int = L.width
        fb.hline(c, top, w, VFDInk.dim)
        var y: Int = top + 4

        // STARLIGHT / NEW WAND
        let modeSelected: Int? = st.newWand ? 1 : 0
        y = VFDW.options(fb, L, c, y, w, ["STARLIGHT", "NEW WAND"], selected: modeSelected, name: "mode",
                         columns: 2, onSelect: { (index: Int) in
                             VFDWandScreen.setMode(ctx, ui, index == 1)
                         })

        // Programmable quick button: tap sends it, a long press reprograms it.
        y = VFDW.button(fb, L, c, y, w, VFDWandScreen.quickLabel(ctx.vm), name: "button:QUICK", action: {
            VFDWandScreen.sendQuick(ctx)
        }, long: {
            VFDWandScreen.editQuick(ctx)
        })

        // LOOP (disabled without a selected colour)
        y = VFDW.toggle(fb, L, c, y, w, "LOOP", tx.starlightLoopEnabled, enabled: st.selectedId >= 0,
                        labelColor: VFDInk.highlight, action: {
                            VFDWandScreen.setLoop(ctx, ui, !tx.starlightLoopEnabled)
                        })

        // TxIntervalSlider: "3.0S | LABEL" or "NO WAND LIBRARY"
        y = VFDWandScreen.intervalSlider(ctx, ui, st, fb, c, y, w)

        // LIB n ............ [CLR LIB]
        fb.text(c, y + 3, "LIB \(st.library.count)", .small, VFDInk.dim)
        if !st.newWand && !st.library.isEmpty {
            let bw: Int = VFDText.width("CLR LIB") + 12
            VFDW.button(fb, L, c + w - bw, y, bw, "CLR LIB", action: {
                VFDWandScreen.askClearLibrary(ctx, ui)
            })
        }
        y += VFDW.ctrlH + VFDW.gap
        y = VFDW.statusLine(fb, L, c, y, w, tx.status, color: VFDWandScreen.statusInk(tx.status))
        return y
    }

    /// TxIntervalSlider: VFDW.intervalSlider draws it (the marker on TxLoopInterval's stop); the
    /// bar's own drag follows the thumb in the label and commits the stop on release.
    fileprivate static func intervalSlider(_ ctx: VFDContext, _ ui: VFDUIState, _ st: VFDWandState,
                                           _ fb: VFDFrameBuffer, _ c: Int, _ r: Int, _ w: Int) -> Int {
        let L: VFDLayout = ctx.L
        let restStop: Int = TxLoopInterval.stop(forSeconds: st.intervalSec)
        let shownStop: Int = st.dragging ? st.dragStop : restStop
        let shownSeconds: Float = st.dragging ? TxLoopInterval.seconds(forStop: st.dragStop) : st.intervalSec
        var labelText: String = "NO WAND LIBRARY"
        if let packet = st.selectedPacket {
            labelText = TxLoopInterval.text(shownSeconds) + "S | " + VFDW.upper(packet.label)
        }
        let markerSeconds: Double = Double(TxLoopInterval.seconds(forStop: shownStop))
        let end: Int = VFDW.intervalSlider(fb, L, c, r, w, labelText, markerSeconds)
        let top: Int = r > L.contentTop ? r + VFDW.groupGap : r
        let barY: Int = top + VFDW.labelH
        fb.tap(c, barY - 6, w, VFDW.tapRows, name: "slider:INTERVAL:bar", drag: { (fraction: Double, ended: Bool) in
            let clamped: Double = min(max(fraction, 0.0), 1.0)
            let raw: Int = VFDMath.roundHalfAway(clamped * Double(TxLoopInterval.lastStop))
            let stop: Int = min(max(raw, 0), TxLoopInterval.lastStop)
            if ended {
                ui.setBool("dragging", false)
                VFDWandScreen.commitInterval(ctx, ui, TxLoopInterval.seconds(forStop: stop))
            } else {
                ui.setInt("dragStop", stop)
                ui.setBool("dragging", true)
            }
        })
        return end
    }

    // MARK: - Actions (run from taps, never from draw)

    fileprivate static func setMode(_ ctx: VFDContext, _ ui: VFDUIState, _ newWand: Bool) {
        if ui.bool("newWand") == newWand { return }
        ui.setBool("newWand", newWand)
        // A new StarlightWandView starts without pulse rings; the code list is a new ScrollView
        // on iOS and starts at the top.
        ui.remove("pulseStart")
        ui.remove("pickIdx")
        ctx.setScroll(VFDWandScreen.codesRegion, 0)
    }

    fileprivate static func sendQuick(_ ctx: VFDContext) {
        let vm: AppViewModel = ctx.vm
        vm.reloadWandQuickIfChanged()
        ctx.tx.transmit(hex: vm.wandQuickHex, label: vm.wandQuickLabel)
    }

    /// The QUICK BUTTON alert's two fields as two prompts (label, then the hex).
    fileprivate static func editQuick(_ ctx: VFDContext) {
        let vm: AppViewModel = ctx.vm
        vm.reloadWandQuickIfChanged()
        let labelDraft: String = vm.wandQuickLabel
        let hexDraft: String = vm.wandQuickHex
        ctx.prompt(title: "QUICK BUTTON", message: "Label", text: labelDraft, keyboard: .text,
                   onDone: { (label: String) in
                       // The renderer queues the second alert until the first has gone.
                       ctx.prompt(title: "QUICK BUTTON", message: "Hex (8301...)", text: hexDraft,
                                  keyboard: .hex, onDone: { (hex: String) in
                                      vm.setWandQuick(label: label, hex: hex)
                                  })
                   })
    }

    /// RENAME CODE: the field starts with the custom name, or else the code's colour.
    fileprivate static func beginRename(_ ctx: VFDContext, _ packet: MagicPacket) {
        let vm: AppViewModel = ctx.vm
        vm.reloadNewWandNamesIfChanged()
        let custom: String? = vm.newWandNames[packet.hex.uppercased()]
        let initial: String = custom ?? packet.colors
        let hex: String = packet.hex
        ctx.prompt(title: "RENAME CODE", message: hex.uppercased(), text: initial, keyboard: .text,
                   onDone: { (entered: String) in
                       vm.setNewWandName(hex: hex, name: entered)
                   })
    }

    /// WandScreen.transmitColor: sends a colour, or makes it the loop's colour while the loop runs.
    fileprivate static func transmitColor(_ ctx: VFDContext, _ ui: VFDUIState, _ packet: MagicPacket) {
        let tx: TxEngine = ctx.tx
        let newWand: Bool = ui.bool("newWand")
        let count: Int = VFDWandScreen.library(ctx.store, newWand: newWand).count
        let ms: Int = TxLoopInterval.milliseconds(VFDWandScreen.interval(ctx, ui))
        if tx.starlightLoopEnabled {
            tx.setStarlightLoop(enabled: true, packetId: packet.id, intervalMs: ms)
        } else {
            tx.transmit(hex: packet.hex, label: packet.label)
        }
        ui.setInt("selLoop", Int(tx.starlightLoopPacketId))
        ui.setInt("selCount", count)
        ui.setBool("selNew", newWand)
        ui.setInt("sel", Int(packet.id))
    }

    fileprivate static func currentSelection(_ ctx: VFDContext, _ ui: VFDUIState) -> Int64 {
        let newWand: Bool = ui.bool("newWand")
        let list: [MagicPacket] = VFDWandScreen.library(ctx.store, newWand: newWand)
        return VFDWandScreen.selection(ctx, ui, list, newWand: newWand)
    }

    fileprivate static func setLoop(_ ctx: VFDContext, _ ui: VFDUIState, _ enabled: Bool) {
        let packetId: Int64 = VFDWandScreen.currentSelection(ctx, ui)
        if packetId < 0 { return }
        let ms: Int = TxLoopInterval.milliseconds(VFDWandScreen.interval(ctx, ui))
        ctx.tx.setStarlightLoop(enabled: enabled, packetId: packetId, intervalMs: ms)
    }

    /// WandScreen.commitInterval: the new interval, and the loop's when it runs.
    fileprivate static func commitInterval(_ ctx: VFDContext, _ ui: VFDUIState, _ seconds: Float) {
        let tx: TxEngine = ctx.tx
        let packetId: Int64 = VFDWandScreen.currentSelection(ctx, ui)
        let before: Int = tx.starlightIntervalMs
        if tx.starlightLoopEnabled && packetId >= 0 {
            tx.setStarlightLoop(enabled: true, packetId: packetId, intervalMs: TxLoopInterval.milliseconds(seconds))
        }
        if tx.starlightIntervalMs != before {
            // WandScreen then takes the engine's interval (onChange of starlightIntervalMs).
            ui.remove("intervalSec")
        } else {
            ui.setDouble("intervalSec", Double(seconds))
            ui.setInt("intervalMs", tx.starlightIntervalMs)
        }
    }

    /// Remember a colour picked on the wand view (tap on the wand, or the colour menu).
    fileprivate static func pick(_ ctx: VFDContext, _ ui: VFDUIState, _ entries: [MagicPacket], _ index: Int) {
        if index < 0 || index >= entries.count { return }
        ui.setInt("pickGlow", MagicClassifier.starlightColorIndex(entries[index].hex))
        ui.setInt("pickHeard", ctx.vm.wandDisplayColorIndex)
        ui.setString("pickKeys", VFDWandScreen.entryKeys(entries))
        ui.setInt("pickCount", entries.count)
        ui.setInt("pickIdx", index)
    }

    /// StarlightWandView.cycleColor: the next colour.
    fileprivate static func cycleColor(_ ctx: VFDContext, _ ui: VFDUIState) {
        if ui.bool("newWand") { return }
        let entries: [MagicPacket] = VFDWandScreen.library(ctx.store, newWand: false)
        if entries.isEmpty { return }
        let current = VFDWandScreen.picker(ctx, ui, entries)
        let next: Int = (current.index + 1) % entries.count
        VFDWandScreen.pick(ctx, ui, entries, next)
    }

    /// StarlightWandView.sendSelected: the pulse, then WandScreen.transmitColor.
    fileprivate static func sendSelected(_ ctx: VFDContext, _ ui: VFDUIState) {
        let entries: [MagicPacket] = VFDWandScreen.library(ctx.store, newWand: false)
        if entries.isEmpty { return }
        let current = VFDWandScreen.picker(ctx, ui, entries)
        if current.index < 0 || current.index >= entries.count { return }
        ui.setDouble("pulseStart", ctx.now)
        VFDWandScreen.transmitColor(ctx, ui, entries[current.index])
    }

    /// The picker's menu: every colour (its glow swatch, name and code), opened at the colour
    /// shown, then DELETE for that one (with its swatch too).
    fileprivate static func colorMenu(_ ctx: VFDContext, _ ui: VFDUIState) {
        let entries: [MagicPacket] = VFDWandScreen.library(ctx.store, newWand: false)
        let current = VFDWandScreen.picker(ctx, ui, entries)
        // A colour row's label starts after its swatch (content width - 25 cells of room).
        let maxChars: Int = VFDText.maxChars(ctx.L.width - 25)
        var items: [VFDMenuItem] = []
        var i: Int = 0
        for packet in entries {
            let index: Int = i
            let colorIndex: Int = MagicClassifier.starlightColorIndex(packet.hex)
            let name: String = VFDW.upper(StarlightColors.nameFor(colorIndex))
            let prefix: String = name + "  ·  "
            let room: Int = maxChars - VFDText.length(prefix)
            let hexUpper: String = packet.hex.uppercased()
            let shownHex: String = room >= 8 ? VFDWandScreen.middle(hexUpper, chars: room) : hexUpper
            let glow: VFDRGB = VFDColors.starlightGlow(colorIndex)
            items.append(VFDMenuItem(prefix + shownHex, rgb: glow, action: {
                VFDWandScreen.pick(ctx, ui, entries, index)
            }))
            i += 1
        }
        var selected: Int? = nil
        if current.index >= 0 && current.index < entries.count {
            selected = current.index
            let shown: MagicPacket = entries[current.index]
            let shownIndex: Int = MagicClassifier.starlightColorIndex(shown.hex)
            let shownName: String = StarlightColors.nameFor(shownIndex)
            let shownGlow: VFDRGB = VFDColors.starlightGlow(shownIndex)
            items.append(VFDMenuItem("DELETE " + VFDW.upper(shownName), destructive: true, rgb: shownGlow, action: {
                VFDWandScreen.askDeleteColor(ctx, shown)
            }))
        }
        ctx.menu(title: "WAND COLOR", items: items, selected: selected)
    }

    /// Every learned Starlight packet the list shows as this colour.
    fileprivate static func colorGroup(_ store: MagicStore, _ packet: MagicPacket) -> [MagicPacket] {
        let index: Int = MagicClassifier.starlightColorIndex(packet.hex) & 0x1F
        var out: [MagicPacket] = []
        for learned in store.learnedStarlightPackets() {
            if VFDWandScreen.isNewWandHex(learned.hex) { continue }
            if (MagicClassifier.starlightColorIndex(learned.hex) & 0x1F) == index {
                out.append(learned)
            }
        }
        return out
    }

    fileprivate static func askDeleteColor(_ ctx: VFDContext, _ packet: MagicPacket) {
        let group: [MagicPacket] = VFDWandScreen.colorGroup(ctx.store, packet)
        let count: Int = max(group.count, 1)
        let label: String = count > 1 ? "\(packet.label) · \(count) learned codes" : packet.label
        let message: String = label.uppercased() + "\n" + packet.hex
        ctx.confirm(title: "Delete wand color?", message: message, confirmLabel: "DELETE", destructive: true,
                    action: {
                        VFDWandScreen.deleteColor(ctx, packet)
                    })
    }

    /// Deletes the colour (every learned code the list shows as it). When the loop was sending
    /// one of them it moves on to the next learned colour, or stops when none is left.
    fileprivate static func deleteColor(_ ctx: VFDContext, _ packet: MagicPacket) {
        let store: MagicStore = ctx.store
        let tx: TxEngine = ctx.tx
        var ids: [Int64] = []
        for learned in VFDWandScreen.colorGroup(store, packet) {
            ids.append(learned.id)
        }
        if !ids.contains(packet.id) {
            ids.append(packet.id)
        }
        for id in ids {
            store.deleteLearnedColor(id: id)
        }
        let loopId: Int64 = tx.starlightLoopPacketId
        if !tx.starlightLoopEnabled || !ids.contains(loopId) { return }
        if let next = store.learnedStarlightPackets().first {
            tx.setStarlightLoop(enabled: true, packetId: next.id, intervalMs: nil)
        } else {
            tx.setStarlightLoop(enabled: false, packetId: -1, intervalMs: nil)
        }
    }

    fileprivate static func askClearLibrary(_ ctx: VFDContext, _ ui: VFDUIState) {
        let count: Int = VFDWandScreen.library(ctx.store, newWand: false).count
        let label: String = "Remove all \(count) learned colors"
        let store: MagicStore = ctx.store
        let tx: TxEngine = ctx.tx
        ctx.confirm(title: "Clear wand library?", message: label.uppercased(), confirmLabel: "DELETE",
                    destructive: true, action: {
                        store.clearLearnedStarlight()
                        ui.remove("sel")
                        if tx.starlightLoopEnabled {
                            tx.setStarlightLoop(enabled: false, packetId: nil, intervalMs: nil)
                        }
                    })
    }
}

// MARK: - State

/// What one draw of the WAND tab reads.
private struct VFDWandState {
    let newWand: Bool
    /// The list on screen: Starlight colours or New Wand codes.
    let library: [MagicPacket]
    /// WandScreen.selectedId (-1 = none).
    let selectedId: Int64
    let selectedPacket: MagicPacket?
    let intervalSec: Float
    let dragging: Bool
    let dragStop: Int
    /// StarlightWandView.selectedIndex.
    let pickIndex: Int
    /// StarlightWandView.glowColorIndex.
    let glowIndex: Int
    let keys: String
}

/// New Wand custom names as AppViewModel stores them ("newwand_names", one JSON object), read
/// again only when the stored text changes (an import may replace it).
@MainActor
private enum VFDWandNames {
    static let key: String = "newwand_names"
    static var text: String? = nil
    static var names: [String: String] = [:]

    static func current(_ vm: AppViewModel) -> [String: String] {
        guard let stored = UserDefaults.standard.string(forKey: VFDWandNames.key) else {
            return vm.newWandNames
        }
        if let known = text, known == stored {
            return names
        }
        var out: [String: String] = [:]
        if let data = stored.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in object {
                if let name = v as? String {
                    out[k.uppercased()] = name
                }
            }
        }
        text = stored
        names = out
        return out
    }
}

// MARK: - Wand pixel art (wand.py wand_cells)

/// Cell codes of the art: palette inks 0 ... 4 as they are, plus the true-colour parts.
private enum VFDWandCode {
    static let glow: UInt8 = 20
    static let glint: UInt8 = 21
    static let auraInner: UInt8 = 22
    static let auraOuter: UInt8 = 23
    static let empty: UInt8 = 255
}

/// A dense grid of art cells around the rod tip (dx from the centre column, y from the tip).
private struct VFDWandGrid {
    let x0: Int
    let y0: Int
    let w: Int
    let h: Int
    var cells: [UInt8]

    init(H: Int) {
        let xr: Int = H / 4 + 8
        let up: Int = H / 4 + 8
        self.x0 = -xr
        self.y0 = -up
        self.w = 2 * xr + 1
        self.h = up + H + 9
        self.cells = [UInt8](repeating: VFDWandCode.empty, count: (2 * xr + 1) * (up + H + 9))
    }

    func get(_ dx: Int, _ y: Int) -> UInt8 {
        let i: Int = dx - x0
        let j: Int = y - y0
        if i < 0 || j < 0 || i >= w || j >= h { return VFDWandCode.empty }
        return cells[j * w + i]
    }

    mutating func set(_ dx: Int, _ y: Int, _ v: UInt8) {
        let i: Int = dx - x0
        let j: Int = y - y0
        if i < 0 || j < 0 || i >= w || j >= h { return }
        cells[j * w + i] = v
    }
}

/// The Starlight wand H rows long as a list of lit cells (proportions from StarlightWand.png, as
/// wand.py draws it): dotted aura rings, the rod with glitter, the glove with finger slits and a
/// crease, the handle with its sparkles, ring and swirl, the crystal ball, collar and neck.
private struct VFDWandArt {
    let dx: [Int]
    let dy: [Int]
    let code: [UInt8]
    /// First and last row used, relative to the rod tip (the aura reaches above it).
    let top: Int
    let bottom: Int

    static let gloveL: [(Double, Double)] = [
        (0.440, 0.028), (0.446, 0.043), (0.455, 0.053), (0.466, 0.061), (0.478, 0.067),
        (0.492, 0.072), (0.510, 0.077), (0.528, 0.081), (0.543, 0.081), (0.556, 0.077),
        (0.568, 0.071), (0.579, 0.064), (0.589, 0.057), (0.596, 0.054), (0.622, 0.054),
    ]
    static let gloveR: [(Double, Double)] = [
        (0.428, 0.028), (0.434, 0.045), (0.444, 0.054), (0.456, 0.060), (0.470, 0.067),
        (0.486, 0.074), (0.505, 0.078), (0.528, 0.082), (0.543, 0.081), (0.556, 0.077),
        (0.568, 0.071), (0.579, 0.063), (0.589, 0.056), (0.596, 0.054), (0.622, 0.054),
    ]
    static let handle: [(Double, Double)] = [
        (0.622, 0.047), (0.634, 0.041), (0.650, 0.038), (0.700, 0.036), (0.760, 0.036),
        (0.800, 0.039), (0.822, 0.043), (0.838, 0.050), (0.846, 0.054),
    ]
    static let gloveTop: Double = 0.428
    static let cuffT: Double = 0.594
    static let gloveEnd: Double = 0.622
    static let handleEnd: Double = 0.846
    static let collarEnd: Double = 0.878
    static let neckEnd: Double = 0.890
    static let ballT: Double = 0.937
    static let ballR: Double = 0.064
    static let rodHW: Double = 0.023
    static let rodEnd: Double = 0.45
    /// Finger slits: top dx, bottom dx, top t, bottom t.
    static let slits: [(Double, Double, Double, Double)] = [
        (-0.008, -0.010, 0.490, 0.536), (0.026, 0.018, 0.486, 0.552), (0.060, 0.048, 0.506, 0.556),
    ]
    /// Aura rings: centre t, rx, ry (fractions of H), every n-th cell.
    static let aura: [(Double, Double, Double, Int)] = [
        (0.272, 0.058, 0.272, 2), (0.272, 0.096, 0.312, 3),
    ]
    static let swirl: [(Double, Double)] = [
        (0.55, 0.722), (0.15, 0.736), (-0.40, 0.756), (-0.52, 0.778), (-0.25, 0.800),
        (0.20, 0.812), (0.45, 0.804), (0.30, 0.794), (0.12, 0.800),
    ]

    /// Python int(round(x)).
    static func rh(_ x: Double) -> Int {
        return VFDMath.roundHalfEven(x)
    }

    static func interp(_ points: [(Double, Double)], _ t: Double) -> Double {
        if t <= points[0].0 { return points[0].1 }
        var i: Int = 0
        while i + 1 < points.count {
            let t0: Double = points[i].0
            let v0: Double = points[i].1
            let t1: Double = points[i + 1].0
            let v1: Double = points[i + 1].1
            if t <= t1 {
                let num: Double = (v1 - v0) * (t - t0)
                return v0 + num / (t1 - t0)
            }
            i += 1
        }
        return points[points.count - 1].1
    }

    /// Small deterministic hash for the glitter (wand.py _hash).
    static func hash(_ a: Int, _ b: Int) -> Int {
        let mask: UInt64 = 0xFFFF_FFFF
        let ua: UInt64 = UInt64(bitPattern: Int64(a))
        let ub: UInt64 = UInt64(bitPattern: Int64(b))
        let sum: UInt64 = (ua &* 374_761_393) &+ (ub &* 668_265_263)
        var h: UInt64 = sum & mask
        h = ((h ^ (h >> 13)) &* 1_274_126_177) & mask
        return Int(h ^ (h >> 16))
    }

    /// Cells on an ellipse outline, every `every`-th cell along the path (_dotted_ellipse).
    static func ellipse(cx: Int, cy: Int, rx: Double, ry: Double, every: Int) -> [(x: Int, y: Int)] {
        let n: Int = max(64, VFDMath.truncate(8.0 * (rx + ry)))
        var pts: [(x: Int, y: Int)] = []
        for i in 0..<n {
            let a: Double = 2.0 * Double.pi * Double(i) / Double(n)
            let x: Int = cx + VFDWandArt.rh(rx * sin(a))
            let y: Int = cy - VFDWandArt.rh(ry * cos(a))
            if let last = pts.last, last.x == x, last.y == y { continue }
            pts.append((x: x, y: y))
        }
        if pts.count > 1, let first = pts.first, let last = pts.last, first.x == last.x, first.y == last.y {
            pts.removeLast()
        }
        var out: [(x: Int, y: Int)] = []
        var i: Int = 0
        let step: Int = max(1, every)
        for p in pts {
            if i % step == 0 {
                out.append(p)
            }
            i += 1
        }
        return out
    }

    static func build(_ H: Int) -> VFDWandArt {
        var g = VFDWandGrid(H: H)
        let hd: Double = Double(H)
        let dim: UInt8 = VFDInk.dim
        let text: UInt8 = VFDInk.text
        let unlit: UInt8 = VFDInk.unlit

        // Aura: dotted rings around the rod (drawn first, everything else covers it).
        var ringIndex: Int = 0
        for ring in VFDWandArt.aura {
            let code: UInt8 = ringIndex == 0 ? VFDWandCode.auraInner : VFDWandCode.auraOuter
            let cy: Int = VFDWandArt.rh(ring.0 * hd)
            let rx: Double = max(1.0, ring.1 * hd)
            let ry: Double = ring.2 * hd
            for p in VFDWandArt.ellipse(cx: 0, cy: cy, rx: rx, ry: ry, every: ring.3) {
                g.set(p.x, p.y, code)
            }
            ringIndex += 1
        }

        // Rod: lit in the glow colour, rounded tip, sparse glitter.
        let rw: Int = max(2, VFDWandArt.rh(VFDWandArt.rodHW * hd))
        let rodRows: Int = VFDWandArt.rh(VFDWandArt.rodEnd * hd)
        for y in stride(from: 0, to: rodRows, by: 1) {
            let trim: Int = y == 0 ? 2 : (y == 1 ? 1 : 0)
            let hw: Int = rw - trim
            for dx in stride(from: -hw, through: hw, by: 1) {
                let glint: Bool = VFDWandArt.hash(dx + 50, y) % 9 == 0 && abs(dx) < hw && y > 2
                g.set(dx, y, glint ? VFDWandCode.glint : VFDWandCode.glow)
            }
        }

        // Glove: white with a dim outline, finger slits cut out, a crease above the cuff.
        let g1: Int = VFDWandArt.rh(VFDWandArt.gloveEnd * hd)
        let gloveStart: Int = VFDWandArt.rh(VFDWandArt.gloveTop * hd)
        var spanLo: [Int: Int] = [:]
        var spanHi: [Int: Int] = [:]
        var spanRows: [Int] = []
        for y in stride(from: gloveStart, to: g1, by: 1) {
            let t: Double = (Double(y) + 0.5) / hd
            var lo: Int = rw
            if t >= VFDWandArt.gloveL[0].0 {
                lo = -VFDWandArt.rh(VFDWandArt.interp(VFDWandArt.gloveL, t) * hd)
            }
            let hi: Int = VFDWandArt.rh(VFDWandArt.interp(VFDWandArt.gloveR, t) * hd)
            spanLo[y] = lo
            spanHi[y] = hi
            spanRows.append(y)
        }
        let crease: Int = VFDWandArt.rh(VFDWandArt.cuffT * hd)
        for y in spanRows {
            let lo: Int = spanLo[y] ?? 1
            let hi: Int = spanHi[y] ?? -1
            let ulo: Int = spanLo[y - 1] ?? 1
            let uhi: Int = spanHi[y - 1] ?? -1
            let dlo: Int = spanLo[y + 1] ?? 1
            let dhi: Int = spanHi[y + 1] ?? -1
            for dx in stride(from: lo, through: hi, by: 1) {
                let side: Bool = dx == lo || dx == hi
                let above: Bool = ulo <= dx && dx <= uhi
                let below: Bool = dlo <= dx && dx <= dhi
                let edge: Bool = side || !above || !below
                g.set(dx, y, (edge || y == crease) ? dim : text)
            }
        }
        let sw: Int = max(2, VFDWandArt.rh(0.012 * hd))
        for slit in VFDWandArt.slits {
            let ya: Int = VFDWandArt.rh(slit.2 * hd)
            let yb: Int = VFDWandArt.rh(slit.3 * hd)
            for y in stride(from: ya, through: yb, by: 1) {
                let f: Double = Double(y - ya) / Double(max(1, yb - ya))
                let along: Double = (slit.0 + (slit.1 - slit.0) * f) * hd
                let x0: Int = VFDWandArt.rh(along - Double(sw) / 2.0)
                for i in 0..<sw {
                    if sw >= 3 && (y == ya || y == yb) && (i == 0 || i == sw - 1) {
                        continue
                    }
                    g.set(x0 + i, y, unlit)
                }
            }
        }

        // Handle: dark (dim) with its decoration in text colour.
        let h1: Int = VFDWandArt.rh(VFDWandArt.handleEnd * hd)
        for y in stride(from: g1, to: h1, by: 1) {
            let hw: Int = VFDWandArt.rh(VFDWandArt.interp(VFDWandArt.handle, (Double(y) + 0.5) / hd) * hd)
            for dx in stride(from: -hw, through: hw, by: 1) {
                g.set(dx, y, dim)
            }
        }
        let hwm: Int = VFDWandArt.rh(VFDWandArt.interp(VFDWandArt.handle, 0.70) * hd)
        let hwmD: Double = Double(hwm)
        let sparkles: [(Double, Double, Int)] = [(-0.50, 0.660, 2), (-0.05, 0.648, 1)]
        for sp in sparkles {
            let x: Int = VFDWandArt.rh(sp.0 * hwmD)
            let y: Int = VFDWandArt.rh(sp.1 * hd)
            g.set(x, y, text)
            for k in stride(from: 1, through: sp.2, by: 1) {
                g.set(x + k, y, text)
                g.set(x - k, y, text)
                g.set(x, y + k, text)
                g.set(x, y - k, text)
            }
        }
        let ringR: Int = max(2, VFDWandArt.rh(0.016 * hd))
        let rcx: Int = VFDWandArt.rh(0.42 * hwmD)
        let rcy: Int = VFDWandArt.rh(0.676 * hd)
        for i in 0..<8 {
            let a: Double = 2.0 * Double.pi * Double(i) / 8.0
            let ox: Int = VFDWandArt.rh(Double(ringR) * cos(a))
            let oy: Int = VFDWandArt.rh(Double(ringR) * sin(a))
            g.set(rcx + ox, rcy + oy, text)
        }
        var pathX: [Double] = []
        var pathY: [Double] = []
        let swirl: [(Double, Double)] = VFDWandArt.swirl
        for j in 0..<(swirl.count - 1) {
            let x0f: Double = swirl[j].0
            let t0: Double = swirl[j].1
            let x1f: Double = swirl[j + 1].0
            let t1: Double = swirl[j + 1].1
            for k in 0..<12 {
                let f: Double = Double(k) / 12.0
                pathX.append((x0f + (x1f - x0f) * f) * hwmD)
                pathY.append((t0 + (t1 - t0) * f) * hd)
            }
        }
        pathX.append(swirl[swirl.count - 1].0 * hwmD)
        pathY.append(swirl[swirl.count - 1].1 * hd)
        var dist: Double = 0
        var hasLast: Bool = false
        var lastX: Double = 0
        var lastY: Double = 0
        for i in 0..<pathX.count {
            let px: Double = pathX[i]
            let py: Double = pathY[i]
            if hasLast {
                dist += hypot(px - lastX, py - lastY)
            }
            if !hasLast || dist >= 2.4 {
                g.set(VFDWandArt.rh(px), VFDWandArt.rh(py), text)
                dist = 0
            }
            lastX = px
            lastY = py
            hasLast = true
        }

        // Crystal ball (behind the collar): dim facet lattice, text rim and a small glint.
        let bc: Double = VFDWandArt.ballT * hd
        let br: Double = VFDWandArt.ballR * hd
        let br2: Double = br * br
        func outside(_ a: Int, _ b: Int) -> Bool {
            let da: Double = Double(a)
            let db: Double = Double(b) + 0.5 - bc
            return da * da + db * db > br2
        }
        let ibr: Int = VFDMath.truncate(br)
        let neckRow: Int = VFDWandArt.rh(VFDWandArt.neckEnd * hd)
        for y in stride(from: neckRow - 2, to: H, by: 1) {
            for dx in stride(from: -ibr - 1, to: ibr + 2, by: 1) {
                if outside(dx, y) { continue }
                let rimSide: Bool = outside(dx - 1, y) || outside(dx + 1, y)
                let rimEnd: Bool = outside(dx, y - 1) || outside(dx, y + 1)
                let rim: Bool = rimSide || rimEnd
                let latA: Bool = VFDMath.floorMod(dx + y, 5) == 0
                let latB: Bool = VFDMath.floorMod(dx - y, 5) == 0
                let lat: Bool = latA || latB
                g.set(dx, y, rim ? text : (lat ? dim : unlit))
            }
        }
        let gx: Int = VFDWandArt.rh(-0.35 * br)
        let gy: Int = VFDWandArt.rh(bc - 0.45 * br)
        g.set(gx, gy, text)
        g.set(gx + 1, gy, text)
        g.set(gx, gy + 1, text)

        // Collar ring (with an unlit gap above it) and the neck into the ball.
        let c0: Int = h1 + 1
        let c1: Int = VFDWandArt.rh(VFDWandArt.collarEnd * hd)
        let chw: Int = VFDWandArt.rh(0.061 * hd)
        for dx in stride(from: -chw, through: chw, by: 1) {
            g.set(dx, h1, unlit)
        }
        for y in stride(from: c0, to: c1, by: 1) {
            let inset: Int = (y == c0 || y == c1 - 1) ? 1 : 0
            for dx in stride(from: -chw + inset, through: chw - inset, by: 1) {
                g.set(dx, y, dim)
            }
        }
        for dx in stride(from: -chw + 1, to: chw, by: 1) {
            g.set(dx, c0, text)
        }
        let nhw: Int = VFDWandArt.rh(0.040 * hd)
        for y in stride(from: c1, to: neckRow, by: 1) {
            for dx in stride(from: -nhw, through: nhw, by: 1) {
                g.set(dx, y, dim)
            }
        }

        // Collect the cells that were set.
        var xs: [Int] = []
        var ys: [Int] = []
        var codes: [UInt8] = []
        var top: Int = Int.max
        var bottom: Int = Int.min
        for j in 0..<g.h {
            for i in 0..<g.w {
                let v: UInt8 = g.cells[j * g.w + i]
                if v == VFDWandCode.empty { continue }
                let y: Int = j + g.y0
                xs.append(i + g.x0)
                ys.append(y)
                codes.append(v)
                if y < top { top = y }
                if y > bottom { bottom = y }
            }
        }
        if codes.isEmpty {
            top = 0
            bottom = 0
        }
        return VFDWandArt(dx: xs, dy: ys, code: codes, top: top, bottom: bottom)
    }
}

/// Built wands by length, and the largest length whose art (aura included) fits a height (iOS
/// scales the picture to the available height). Memos only: drawing stays free of visible state.
@MainActor
private enum VFDWandArtCache {
    static var arts: [Int: VFDWandArt] = [:]
    static var fits: [Int: Int] = [:]

    static func art(_ H: Int) -> VFDWandArt {
        if let known = arts[H] { return known }
        let built: VFDWandArt = VFDWandArt.build(H)
        if arts.count >= 6 {
            arts.removeAll()
        }
        arts[H] = built
        return built
    }

    static func fit(_ avail: Int) -> Int {
        if let known = fits[avail] { return known }
        var H: Int = avail
        while H > 40 {
            let probe: VFDWandArt = arts[H] ?? VFDWandArt.build(H)
            if probe.bottom - probe.top + 1 <= avail {
                break
            }
            H -= 1
        }
        if fits.count >= 16 {
            fits.removeAll()
        }
        fits[avail] = H
        return H
    }
}
