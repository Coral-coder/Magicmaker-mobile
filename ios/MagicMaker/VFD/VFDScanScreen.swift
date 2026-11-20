import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// SCAN tab in the VFD theme, laid out like tools/vfd/screens/scan.py (the narrow layout of
/// ScanScreen): the LAST LIGHTS strip (the band face in true colour, animated like BandPreviewView's
/// compact strip), the SCAN CONTROLS bar, the controls panel (status, chips, MY MAGICBAND, LIBRARY
/// FILE, buffer + CLR, gesture hint; capped at 60% of the content and scrolling inside), then the
/// live feed (GROUPED sections or RAW) in its own scrolling window. Every control calls what the
/// standard screen calls; the long-press sheet, swipe actions, CLASS filter and recategorize
/// dialog are VFD menus, deletes ask first, toasts are drawn over the bottom of the feed. EXPORT
/// (share sheet) and IMPORT (document picker) open the system UI in a sheet.
@MainActor
enum VFDScanScreen: VFDScreen {
    static let title: String = "SCAN"

    static func headerRight(_ ctx: VFDContext) -> (text: String, action: () -> Void)? {
        return nil
    }

    /// Only the feed and the controls panel scroll (each in its own region), so the page itself
    /// never does: returns nil.
    static func draw(_ ctx: VFDContext) -> Int? {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let s: VFDScanState = state(ctx)
        let c: Int = L.left
        let w: Int = L.width
        // Back to origin 0 (the page never scrolls; this keeps the windows below in screen rows).
        let pageScroll: Int = -fb.originY
        fb.pushClip(0, L.contentTop + pageScroll, fb.cols, L.contentH, dy: pageScroll)
        var y: Int = lastLightsStrip(ctx, fb, s, c, L.contentTop, w)
        y = hairline(fb, c, y, w)
        y = controlsBar(ctx, fb, s, c, y, w)
        if !s.controlsCollapsed {
            y = controlsPanel(ctx, fb, L, s, c, y, w)
        }
        y = hairline(fb, c, y, w)
        feedWindow(ctx, fb, L, s, c, y - 3, w)
        drawToast(ctx, fb, L)
        fb.popClip()
        return nil
    }
}

// MARK: - Keys and snapshots

/// UserDefaults keys shared with ScanScreen (ScanUiPrefs) and this tab's in-memory UI keys.
private enum VFDScanKeys {
    static let controlsCollapsed: String = "ios.scan_controls_collapsed"
    static let bandMenuCollapsed: String = "band_menu_collapsed"
    static let collapsedSections: String = "scan_collapsed_sections"
    static let viewMode: String = "scan.viewMode"
    static let hiddenSections: String = "scan.hiddenSections"
    static let toast: String = "scan.toast"
    static let toastAt: String = "scan.toastAt"
    static let feedRegion: String = "feed"
    static let controlsRegion: String = "controls"
    static let hint: String = "TAP REPLAY · HOLD MENU · SWIPE ← DEL · SWIPE → TX/TAG"
}

/// What one draw reads from the engines and the UI state.
private struct VFDScanState {
    let lastLightHex: String
    let lightsHeard: Int
    let packetsHeard: Int
    let scanActive: Bool
    let bluetoothReady: Bool
    let bluetoothStatus: String
    let recording: Bool
    let logName: String?
    let txStatus: String
    let raw: Bool
    let showControlOnly: Bool
    let controlsCollapsed: Bool
    let bandMenuCollapsed: Bool
    /// Folded section titles ("WAND", ...).
    let collapsed: Set<String>
    /// Sections the CLASS filter shows.
    let visible: Set<LivePacketSection>
    let bandAddresses: [String]
    let savedBands: Int
    let seen: [SeenAddress]
    let seenTagged: [Bool]
    let libraryName: String
    let uniqueCount: Int
    let rawCount: Int
}

private enum VFDScanChipKind {
    case action
    case on
    case off
}

private struct VFDScanChipSpec {
    let label: String
    let kind: VFDScanChipKind
    let icon: String?
    let chevron: Bool
    let action: () -> Void
}

/// One legend entry under the strip: a true-colour swatch (nil = off ring) and the colour name.
private struct VFDScanLegend {
    let rgb: VFDRGB?
    let name: String
}

/// One feed line: a section header or a packet row, with its rows [top, bottom).
private struct VFDScanFeedEntry {
    let header: LivePacketSection?
    let count: Int
    let folded: Bool
    let packet: LivePacket?
    let top: Int
    let bottom: Int
}

private struct VFDScanFeedLayout {
    let entries: [VFDScanFeedEntry]
    /// Row of the empty-buffer line, when the buffer is empty.
    let emptyRow: Int?
    let raw: Bool
    let end: Int
}

@MainActor
extension VFDScanScreen {
    // MARK: geometry

    /// Band face: face x face cells with five ledSize LED zones.
    private static let face: Int = 37
    private static let ledSize: Int = 7
    /// Zone offsets inside the face (left/top, centre, right/bottom).
    private static let ledAt: [Int] = [4, 15, 26]
    /// Z1..Z5 as (column, row) in the face's 3 x 3 spots: bottom-left, top-left, centre, top-right,
    /// bottom-right (BandPreviewView's point order).
    private static let zoneSpot: [(c: Int, r: Int)] = [(c: 0, r: 2), (c: 0, r: 0), (c: 1, r: 1), (c: 2, r: 0), (c: 2, r: 2)]
    /// Rows of padding at the top of the controls panel (scrolls with it).
    private static let panelPad: Int = 4
    /// controlsPanel never caps under 120 pt (72 cells at 5/3 pt per cell).
    private static let minPanelRows: Int = 72
    /// Rows around a window edge a snapping probe draws.
    private static let probeBand: Int = 48
    private static let toastSeconds: Double = 2.5

    // MARK: state

    private static func scanUI(_ ctx: VFDContext) -> VFDUIState {
        return ctx.uiState(for: "scan")
    }

    private static func state(_ ctx: VFDContext) -> VFDScanState {
        let scan: ScanEngine = ctx.scan
        let store: MagicStore = ctx.store
        let ui: VFDUIState = scanUI(ctx)
        var collapsed: Set<String> = []
        for name in ui.storedStrings(VFDScanKeys.collapsedSections) {
            collapsed.insert(name.uppercased())
        }
        let hidden: Set<String> = ui.strings(VFDScanKeys.hiddenSections)
        var visible: Set<LivePacketSection> = []
        for section in LivePacketSection.allCases where !hidden.contains(section.rawValue) {
            visible.insert(section)
        }
        let seen: [SeenAddress] = Array(scan.seenAddresses.prefix(8))
        var tagged: [Bool] = []
        for entry in seen {
            tagged.append(store.isBandAddress(entry.address))
        }
        let libraryName: String = URL(fileURLWithPath: store.libraryFilePath).lastPathComponent
        let raw: Bool = ui.string(VFDScanKeys.viewMode, default: "GROUPED") == "RAW"
        return VFDScanState(
            lastLightHex: scan.lastLightHex,
            lightsHeard: scan.lightsHeard,
            packetsHeard: scan.packetsHeard,
            scanActive: scan.scanActive,
            bluetoothReady: scan.bluetoothStatus == "Bluetooth ready",
            bluetoothStatus: scan.bluetoothStatus,
            recording: scan.recordSessionActive,
            logName: store.activeSessionName,
            txStatus: ctx.tx.status,
            raw: raw,
            showControlOnly: scan.showControlOnly,
            controlsCollapsed: ui.storedBool(VFDScanKeys.controlsCollapsed, default: false),
            bandMenuCollapsed: ui.storedBool(VFDScanKeys.bandMenuCollapsed, default: true),
            collapsed: collapsed,
            visible: visible,
            bandAddresses: store.bandAddressList(),
            savedBands: store.savedBandCount(),
            seen: seen,
            seenTagged: tagged,
            libraryName: libraryName,
            uniqueCount: scan.livePackets.count,
            rawCount: scan.rawLivePackets.count
        )
    }

    // MARK: small helpers

    /// "%03d".
    private static func pad3(_ n: Int) -> String {
        var t: String = String(n)
        while t.count < 3 {
            t = "0" + t
        }
        return t
    }

    /// A tap at least tapRows tall, grown evenly around the visual (scan.py `_tap`).
    private static func hitRect(_ fb: VFDFrameBuffer, _ c: Int, _ r: Int, _ w: Int, _ h: Int, _ name: String,
                                action: (() -> Void)? = nil) {
        var top: Int = r
        var height: Int = h
        if height < VFDW.tapRows {
            top -= (VFDW.tapRows - height) / 2
            height = VFDW.tapRows
        }
        fb.tap(c, top, w, height, name: name, action: action)
    }

    /// s, or its head and tail around "…" so it fits maxCols (SwiftUI .truncationMode(.middle)).
    private static func fitMiddle(_ s: String, _ maxCols: Int) -> String {
        let n: Int = VFDText.maxChars(maxCols)
        let a: [Unicode.Scalar] = VFDText.scalars(s)
        if a.count <= n { return s }
        if n <= 1 { return VFDText.fit(s, maxCols) }
        let keep: Int = n - 1
        let head: Int = (keep + 1) / 2
        let tail: Int = keep - head
        let headPart: String = VFDText.string(Array(a[0..<head]))
        let tailPart: String = VFDText.string(Array(a[(a.count - tail)...]))
        return headPart + VFDText.ellipsis + tailPart
    }

    /// " | "-separated tokens drawn as the telemetry line draws them (a 9-row bar, 4 empty cells
    /// each side), stopping with … at column `limit` (exclusive). Returns the end column.
    @discardableResult
    private static func tokens(_ fb: VFDFrameBuffer, _ x0: Int, _ r: Int, _ toks: [String], _ color: UInt8,
                               _ limit: Int) -> Int {
        var x: Int = x0
        var i: Int = 0
        for tok in toks {
            let tw: Int = VFDText.width(tok)
            if i > 0 {
                let bar: Int = x + 3
                let nxt: Int = bar + 5
                if nxt + tw > limit {
                    if x + VFDText.width(VFDText.ellipsis) <= limit {
                        x = fb.text(x, r, VFDText.ellipsis, .small, color)
                    }
                    return x
                }
                fb.vline(bar, r - 1, 9, color)
                x = nxt
            }
            if x + tw > limit {
                return fb.textFit(x, r, tok, limit - x, .small, color)
            }
            x = fb.text(x, r, tok, .small, color)
            i += 1
        }
        return x
    }

    private static func chipWidth(_ label: String, icon: Bool, kind: VFDScanChipKind, chevron: Bool) -> Int {
        switch kind {
        case .on, .off:
            return VFDText.width(count: VFDText.length(label) + 2)
        case .action:
            let iconW: Int = icon ? 9 : 0
            let chevW: Int = chevron ? 11 : 0
            return VFDText.width(label) + iconW + chevW + 12
        }
    }

    /// One ScanChip on a ctrlH row at (x, y): a button (highlight border) with an optional pause /
    /// play icon or a menu chevron, an inverted block (on) or [LABEL] (off). Returns the column
    /// after it.
    @discardableResult
    private static func chip(_ fb: VFDFrameBuffer, _ x: Int, _ y: Int, _ rawLabel: String,
                             kind: VFDScanChipKind = .action, icon: String? = nil, chevron: Bool = false,
                             action: (() -> Void)? = nil) -> Int {
        let label: String = VFDW.upper(rawLabel)
        let w: Int = chipWidth(label, icon: icon != nil, kind: kind, chevron: chevron)
        let ty: Int = y + VFDW.ctrlText
        switch kind {
        case .on:
            fb.fill(x, y + 1, w, VFDW.ctrlH - 2, VFDInk.highlight)
            fb.text(x + VFDW.adv, ty, label, .small, VFDInk.unlit)
        case .off:
            fb.text(x, ty, "[", .small, VFDInk.dim)
            fb.text(x + VFDW.adv, ty, label, .small, VFDInk.text)
            fb.text(x + w - 5, ty, "]", .small, VFDInk.dim)
        case .action:
            fb.box(x, y, w, VFDW.ctrlH, VFDInk.highlight)
            var tx: Int = x + 6
            if icon == "pause" {
                fb.fill(tx, ty, 2, 7, VFDInk.text)
                fb.fill(tx + 3, ty, 2, 7, VFDInk.text)
                tx += 9
            } else if icon == "play" {
                for i in 0..<4 {
                    fb.vline(tx + 1 + i, ty + i, 7 - 2 * i, VFDInk.text)
                }
                tx += 9
            }
            let end: Int = fb.text(tx, ty, label, .small, VFDInk.text)
            if chevron {
                VFDW.chevron(fb, end + 3, ty + 1, false, VFDInk.text)
            }
        }
        hitRect(fb, x - 2, y, w + 4, VFDW.ctrlH, "chip:" + label, action: action)
        return x + w
    }

    /// A right-aligned compact button ending on column `right` (inclusive): the app's textButton.
    /// alarm = a destructive one (VFDW.button's alarm look). Returns its left column.
    @discardableResult
    private static func textButton(_ fb: VFDFrameBuffer, _ L: VFDLayout, right: Int, _ y: Int, _ label: String,
                                   alarm: Bool = false, name: String? = nil,
                                   action: @escaping () -> Void) -> Int {
        let lab: String = VFDW.upper(label)
        let bw: Int = VFDText.width(lab) + 12
        let x: Int = right - bw + 1
        let tapName: String = name ?? ("button:" + lab)
        if alarm {
            VFDW.button(fb, L, x, y, bw, lab, name: tapName, alarm: true, action: action)
            return x
        }
        fb.box(x, y, bw, VFDW.ctrlH, VFDInk.highlight)
        fb.text(x + 6, y + VFDW.ctrlText, lab, .small, VFDInk.text)
        hitRect(fb, x, y, bw, VFDW.ctrlH, tapName, action: action)
        return x
    }

    /// The 0.5 pt panel line between blocks: a solid dim rule with 3 empty rows each side.
    private static func hairline(_ fb: VFDFrameBuffer, _ c: Int, _ y: Int, _ w: Int) -> Int {
        fb.hline(c, y + 3, w, VFDInk.dim)
        return y + 7
    }

    // MARK: LAST LIGHTS strip

    /// BandPreviewView(compact: true, title: "LAST LIGHTS · #n"), or LAST LIGHTS · NONE HEARD YET.
    /// The face's LEDs are true colours following BandLedAnimation; a moving effect redraws at
    /// 30 fps. Returns the next free row.
    private static func lastLightsStrip(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ s: VFDScanState,
                                        _ c: Int, _ y: Int, _ w: Int) -> Int {
        let hex: String = s.lastLightHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.isEmpty {
            fb.textFit(c, y + 1, "LAST LIGHTS · NONE HEARD YET", w, .small, VFDInk.dim)
            return y + 1 + VFDW.line
        }
        let model: BandEffectModel = BandEffectModel.from(hex)
        bandFace(fb, c, y + 1, model, time: ctx.time)
        // An open menu blanks the whole content region, the strip included: nothing moves then.
        if animates(model) && !ctx.menuOpen {
            fb.wantsAnimation = true
        }
        let tx: Int = c + face + 7
        let tw: Int = c + w - tx
        var r: Int = y
        fb.textFit(tx, r, "LAST LIGHTS · #\(s.lightsHeard)", tw, .small, VFDInk.dim)
        r += VFDW.line
        let classified: ClassifiedPacket? = MagicClassifier.classify(hex)
        let label: String = classified?.label ?? model.note
        let lit: Bool = model.kind != BandEffectModel.Kind.none
        let labelColor: UInt8 = lit ? VFDInk.highlight : VFDInk.dim
        fb.textFit(tx, r, VFDW.upper(label), tw, .small, labelColor)
        r += VFDW.line
        fb.text(tx, r, fitMiddle(HexUtils.canonicalHex(hex), tw), .small, VFDInk.dim)
        r += VFDW.line
        drawLegend(fb, legend(model), tx, r, c + w)
        return y + face + 2
    }

    /// Whether BandLedAnimation changes this model's LEDs over time (BandPreviewView redraws them
    /// at 30 fps; a still face needs no fast clock).
    private static func animates(_ model: BandEffectModel) -> Bool {
        switch model.kind {
        case .none, .ping, .dual:
            return false
        case .rainbow:
            let full: Bool = model.perLed.allSatisfy({ (v: Int?) -> Bool in v != nil })
            return model.note.contains("cycle") && full
        default:
            return true
        }
    }

    /// The band face: a face x face rounded square (dim) with the five LED zones in their true
    /// colour at `time`; an off zone is a dim dotted ring.
    private static func bandFace(_ fb: VFDFrameBuffer, _ x: Int, _ y: Int, _ model: BandEffectModel, time: Double) {
        let e: Int = face - 1
        fb.hline(x + 2, y, face - 4, VFDInk.dim)
        fb.hline(x + 2, y + e, face - 4, VFDInk.dim)
        fb.vline(x, y + 2, face - 4, VFDInk.dim)
        fb.vline(x + e, y + 2, face - 4, VFDInk.dim)
        fb.set(x + 1, y + 1, VFDInk.dim)
        fb.set(x + e - 1, y + 1, VFDInk.dim)
        fb.set(x + 1, y + e - 1, VFDInk.dim)
        fb.set(x + e - 1, y + e - 1, VFDInk.dim)
        var z: Int = 0
        for spot in zoneSpot {
            let lx: Int = x + ledAt[spot.c]
            let ly: Int = y + ledAt[spot.r]
            if let rgb = VFDColors.bandLED(model, zone: z, time: time) {
                VFDW.led(fb, lx, ly, 0, size: ledSize, fill: rgb)
            } else {
                VFDW.led(fb, lx, ly, nil, size: ledSize)
            }
            z += 1
        }
    }

    /// The colour names of Z1..Z5 (EMCOT palette names, first-appearance order) with their true
    /// colour, then OFF when a zone is unlit. A custom RGB effect names its #RRGGBB.
    private static func legend(_ model: BandEffectModel) -> [VFDScanLegend] {
        if model.kind == BandEffectModel.Kind.rgb {
            let v: Int = model.rgb ?? 0x9E9E9E
            let rgb: VFDRGB = VFDColors.rgb(packed: v)
            return [VFDScanLegend(rgb: rgb, name: rgb.hex)]
        }
        var out: [VFDScanLegend] = []
        var seen: Set<String> = []
        var anyOff: Bool = false
        for z in 0..<5 {
            let index: Int? = z < model.perLed.count ? model.perLed[z] : nil
            guard let idx = index else {
                anyOff = true
                continue
            }
            let name: String = StarlightColors.nameFor(idx)
            if name.lowercased() == "off" {
                anyOff = true
                continue
            }
            let key: String = VFDW.upper(name)
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(VFDScanLegend(rgb: VFDColors.starlightGlow(idx), name: key))
        }
        if anyOff {
            out.append(VFDScanLegend(rgb: nil, name: "OFF"))
        }
        return out
    }

    private static func swatch(_ fb: VFDFrameBuffer, _ x: Int, _ y: Int, _ rgb: VFDRGB?) {
        if let colour = rgb {
            VFDW.led(fb, x, y, 0, size: ledSize, fill: colour)
        } else {
            VFDW.led(fb, x, y, nil, size: ledSize)
        }
    }

    /// Swatch + colour name, as many as fit before `limit` (exclusive).
    private static func drawLegend(_ fb: VFDFrameBuffer, _ items: [VFDScanLegend], _ x0: Int, _ r: Int, _ limit: Int) {
        var x: Int = x0
        for item in items {
            let nameX: Int = x + ledSize + 4
            let need: Int = ledSize + 4 + VFDText.width(item.name)
            if x + need > limit {
                let shortW: Int = VFDText.width(count: min(1, VFDText.length(item.name)) + 1)
                if nameX + shortW <= limit {
                    swatch(fb, x, r, item.rgb)
                    fb.textFit(nameX, r, item.name, limit - nameX, .small, VFDInk.text)
                }
                break
            }
            swatch(fb, x, r, item.rgb)
            let color: UInt8 = item.rgb == nil ? VFDInk.dim : VFDInk.text
            x = fb.text(nameX, r, item.name, .small, color) + 7
        }
    }

    // MARK: controls

    /// The fold bar: chevron + HIDE SCAN CONTROLS / SCAN CONTROLS, the SCAN | LOG | RX summary
    /// under it. Returns the panel's top row when open, else the row for the hairline.
    private static func controlsBar(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ s: VFDScanState,
                                    _ c: Int, _ y: Int, _ w: Int) -> Int {
        let r: Int = y + 2
        let title: String
        if s.controlsCollapsed {
            VFDW.chevron(fb, c, r, false, VFDInk.dim)
            title = "SCAN CONTROLS"
        } else {
            VFDW.chevronUp(fb, c, r, VFDInk.dim)
            title = "HIDE SCAN CONTROLS"
        }
        let x: Int = c + 11
        fb.textFit(x, r, title, c + w - x, .small, VFDInk.highlight)
        var parts: [String] = [s.scanActive ? "SCAN:ON" : "SCAN:OFF"]
        if s.recording {
            parts.append("LOG:REC")
        }
        parts.append("RX:\(s.packetsHeard)")
        tokens(fb, x, r + VFDW.line, parts, VFDInk.dim, c + w)
        let rule: Int = r + VFDW.line + 7 + 3
        let collapsed: Bool = s.controlsCollapsed
        hitRect(fb, c, y, w, rule - y, "controls", action: {
            VFDScanScreen.scanUI(ctx).setStoredBool(VFDScanKeys.controlsCollapsed, !collapsed)
        })
        if collapsed {
            return rule - 3
        }
        fb.hline(c, rule, w, VFDInk.dim, step: 2)
        return rule + 1
    }

    /// controlsPanel(maxHeight: 60% of the content): the controls column at its natural height,
    /// or capped and scrolled inside its own region with its own indicator. Returns the row after
    /// the window (where the hairline goes).
    private static func controlsPanel(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ s: VFDScanState,
                                      _ c: Int, _ top: Int, _ w: Int) -> Int {
        let colTop: Int = top + panelPad
        let measure: VFDFrameBuffer = VFDFrameBuffer(cols: L.cols, rows: 1)
        let natural: Int = controlsColumn(ctx, measure, L, s, c, colTop, w, glue: nil) - top
        let capped: Int = VFDMath.roundHalfAway(0.6 * Double(L.contentH))
        let cap: Int = max(capped, minPanelRows)
        let h: Int = max(0, min(natural, cap))
        if natural <= cap {
            // Uncapped and unscrolled: nothing crosses the window's edges (the column starts
            // panelPad rows down and ends after its last line), so no snapping is needed.
            fb.pushClip(0, top, fb.cols, h)
            _ = controlsColumn(ctx, fb, L, s, c, colTop, w, glue: nil)
            fb.popClip()
            return top + h
        }
        let off: Int = ctx.scroll(VFDScanKeys.controlsRegion, limit: natural - h)
        let interior: (Int, Int) = (c + 2, c + w - 2)
        let win: (top: Int, bottom: Int) = windowed(fb, top: top, h: h, scroll: off, cols: interior,
                                                    draw: { (target: VFDFrameBuffer, edge: String?) -> Void in
            _ = VFDScanScreen.controlsColumn(ctx, target, L, s, c, colTop, w, glue: edge)
        })
        registerRegion(fb, VFDScanKeys.controlsRegion, top: top, h: h, limit: natural - h)
        VFDW.listScrollbar(fb, top, win.bottom - top, natural, off)
        return win.bottom
    }

    /// Status, the chip rows, MY MAGICBAND, LIBRARY FILE, the buffer counter with CLR, the hint.
    /// glue = "top" / "bottom" only on snapping probes. Returns the next free row.
    private static func controlsColumn(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ s: VFDScanState,
                                       _ c: Int, _ y0: Int, _ w: Int, glue: String?) -> Int {
        var y: Int = statusLines(fb, L, s, c, y0, w)
        y = chipRows(ctx, fb, s, c, y + 3, w)
        y = bandSection(ctx, fb, L, s, c, y + 5, w, glue: glue)
        y = librarySection(ctx, fb, L, s, c, y + 4, w, glue: glue)
        y = bufferRow(ctx, fb, L, s, c, y + 1, w)
        return hintLines(fb, c, y + 2, w, VFDScanKeys.hint)
    }

    /// Scan status (highlight when scanning with Bluetooth ready), the open log, the TX status.
    private static func statusLines(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ s: VFDScanState,
                                    _ c: Int, _ y0: Int, _ w: Int) -> Int {
        var text: String = "Tap SCAN to start"
        var color: UInt8 = VFDInk.dim
        if s.scanActive {
            if s.bluetoothReady {
                text = "Scanning · keep app open"
                color = VFDInk.highlight
            } else {
                text = "Scan on · " + s.bluetoothStatus
                color = VFDInk.alarm
            }
        }
        var y: Int = VFDW.statusLine(fb, L, c, y0, w, text, color: color)
        if let logName = s.logName {
            y = VFDW.statusLine(fb, L, c, y, w, "LOG · " + logName)
        }
        let warn: Bool = s.txStatus == TxEngine.notLinkedStatus || s.txStatus == TxEngine.sendFailedStatus
        let txColor: UInt8 = warn ? VFDInk.alarm : VFDInk.dim
        return VFDW.statusLine(fb, L, c, y, w, "STATUS: " + s.txStatus, color: txColor)
    }

    /// PAUSE/SCAN, LOG, GROUPED, RAW, SHOW-CTRL/ALL RAW, then CLASS n/8, flowing and wrapping
    /// (iOS scrolls this row sideways). Returns the next free row.
    private static func chipRows(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ s: VFDScanState,
                                 _ c: Int, _ top: Int, _ w: Int) -> Int {
        let scan: ScanEngine = ctx.scan
        let active: Bool = s.scanActive
        let recording: Bool = s.recording
        let showOnly: Bool = s.showControlOnly
        let total: Int = LivePacketSection.allCases.count
        let classLabel: String = "CLASS \(s.visible.count)/\(total)"
        let scanLabel: String = active ? "PAUSE" : "SCAN"
        let scanIcon: String = active ? "pause" : "play"
        let logLabel: String = recording ? "LOG:ON" : "LOG"
        let groupedKind: VFDScanChipKind = s.raw ? VFDScanChipKind.off : VFDScanChipKind.on
        let rawKind: VFDScanChipKind = s.raw ? VFDScanChipKind.on : VFDScanChipKind.off
        let showLabel: String = showOnly ? "SHOW-CTRL" : "ALL RAW"
        let showKind: VFDScanChipKind = showOnly ? VFDScanChipKind.on : VFDScanChipKind.off
        var specs: [VFDScanChipSpec] = []
        specs.append(VFDScanChipSpec(label: scanLabel, kind: .action, icon: scanIcon, chevron: false, action: {
            scan.setScan(!active)
        }))
        specs.append(VFDScanChipSpec(label: logLabel, kind: .action, icon: nil, chevron: false, action: {
            scan.setRecording(!recording)
        }))
        specs.append(VFDScanChipSpec(label: "GROUPED", kind: groupedKind, icon: nil, chevron: false, action: {
            VFDScanScreen.setViewMode(ctx, raw: false)
        }))
        specs.append(VFDScanChipSpec(label: "RAW", kind: rawKind, icon: nil, chevron: false, action: {
            VFDScanScreen.setViewMode(ctx, raw: true)
        }))
        specs.append(VFDScanChipSpec(label: showLabel, kind: showKind, icon: nil, chevron: false, action: {
            scan.showControlOnly = !showOnly
        }))
        specs.append(VFDScanChipSpec(label: classLabel, kind: .action, icon: nil, chevron: true, action: {
            VFDScanScreen.openClassMenu(ctx)
        }))
        var x: Int = c
        var y: Int = top
        for spec in specs {
            let label: String = VFDW.upper(spec.label)
            let cw: Int = chipWidth(label, icon: spec.icon != nil, kind: spec.kind, chevron: spec.chevron)
            if x > c && x + cw > c + w {
                x = c
                y += VFDW.ctrlH + VFDW.gap
            }
            let end: Int = chip(fb, x, y, label, kind: spec.kind, icon: spec.icon, chevron: spec.chevron,
                                action: spec.action)
            x = end + VFDW.optGap
        }
        return y + VFDW.ctrlH + VFDW.gap
    }

    /// MY MAGICBAND: a dim panel; the header line folds the tagged bands (REMOVE), the saved band
    /// packets (DELETE ALL, asks first) and the heard list (TAG / UNTAG). Returns the next free row.
    private static func bandSection(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ s: VFDScanState,
                                    _ c: Int, _ y: Int, _ w: Int, glue: String?) -> Int {
        let store: MagicStore = ctx.store
        let ic: Int = c + 4
        let iw: Int = w - 8
        let r: Int = y + VFDW.ctrlText
        let folded: Bool = s.bandMenuCollapsed
        VFDW.chevron(fb, ic, r, folded, VFDInk.dim)
        let cnt: String = pad3(s.bandAddresses.count)
        fb.textRight(ic + iw - 1, r, cnt, .small, VFDInk.dim)
        let titleW: Int = iw - 11 - VFDText.width(cnt) - 6
        fb.textFit(ic + 11, r, "MY MAGICBAND", titleW, .small, VFDInk.highlight)
        hitRect(fb, c, y, w, VFDW.ctrlH, "section:MY MAGICBAND", action: {
            VFDScanScreen.scanUI(ctx).setStoredBool(VFDScanKeys.bandMenuCollapsed, !folded)
        })
        var end: Int = y + VFDW.ctrlH
        if !folded {
            var row: Int = end
            let right: Int = ic + iw - 1
            if s.bandAddresses.isEmpty {
                fb.textFit(ic, row + VFDW.ctrlText, "NONE SET — PICK FROM HEARD", iw, .small, VFDInk.dim)
                row += VFDW.line + 4
            }
            for addr in s.bandAddresses {
                let address: String = addr
                let short: String = shortAddress(address)
                let bx: Int = textButton(fb, L, right: right, row, "REMOVE", name: "band:remove:" + short, action: {
                    store.removeBandAddress(address)
                })
                fb.textFit(ic, row + VFDW.ctrlText, short, bx - ic - 6, .small, VFDInk.highlight)
                row += VFDW.ctrlH + VFDW.gap
            }
            let saved: String = "SAVED BAND PACKETS: \(s.savedBands)"
            if s.savedBands > 0 {
                let deleteAll: () -> Void = {
                    VFDScanScreen.confirmDeleteBands(ctx)
                }
                let both: Int = VFDText.width(saved) + 6 + VFDText.width("DELETE ALL") + 12
                if both > iw {
                    // Too narrow for both: the count keeps its line, the button wraps.
                    fb.textFit(ic, row + VFDW.ctrlText, saved, iw, .small, VFDInk.dim)
                    row += VFDW.line + 2
                    textButton(fb, L, right: right, row, "DELETE ALL", alarm: true, action: deleteAll)
                } else {
                    let bx: Int = textButton(fb, L, right: right, row, "DELETE ALL", alarm: true, action: deleteAll)
                    fb.textFit(ic, row + VFDW.ctrlText, saved, bx - 6 - ic, .small, VFDInk.dim)
                }
            } else {
                fb.textFit(ic, row + VFDW.ctrlText, saved, iw, .small, VFDInk.dim)
            }
            row += VFDW.ctrlH + VFDW.gap
            if !s.seen.isEmpty {
                fb.textFit(ic, row + VFDW.ctrlText, "HEARD (TAP TO TAG):", iw, .small, VFDInk.dim)
                row += VFDW.line + 2
                var i: Int = 0
                for entry in s.seen {
                    let tagged: Bool = i < s.seenTagged.count ? s.seenTagged[i] : false
                    i += 1
                    let address: String = entry.address
                    let short: String = shortAddress(address)
                    let toggle: () -> Void = {
                        if tagged {
                            store.removeBandAddress(address)
                        } else {
                            store.addBandAddress(address)
                        }
                    }
                    let bx: Int = textButton(fb, L, right: right, row, tagged ? "UNTAG" : "TAG",
                                             name: "band:tag:" + short, action: toggle)
                    let stats: String = "\(entry.rssi)dBm ·\(entry.count)"
                    let line: String = short + "  " + stats
                    let lineColor: UInt8 = tagged ? VFDInk.highlight : VFDInk.dim
                    fb.textFit(ic, row + VFDW.ctrlText, line, bx - ic - 6, .small, lineColor)
                    row += VFDW.ctrlH + VFDW.gap
                }
            }
            end = row + 1
        }
        fb.box(c, y - 2, w, end - y + 4, VFDInk.dim)
        // Snapping probes (column c + 2 is empty in the box): at the bottom edge the top border goes
        // with the header line, at the top edge the bottom border goes with the last line.
        if glue == "bottom" {
            fb.vline(c + 2, y - 2, 6, VFDInk.dim)
        } else if glue == "top" {
            fb.vline(c + 2, end - 4, 6, VFDInk.dim)
        }
        return end + 2 + VFDW.gap
    }

    /// LIBRARY FILE (FILES APP · EDITABLE): the Files-app path (up to two lines) and EXPORT /
    /// IMPORT. Returns the next free row.
    private static func librarySection(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ s: VFDScanState,
                                       _ c: Int, _ y: Int, _ w: Int, glue: String?) -> Int {
        let inner: (c: Int, r: Int, w: Int) = VFDW.panelInner(c, y, w, title: true)
        let path: String = VFDW.upper("Files app → MagicMaker → " + s.libraryName)
        let wrapped: [String] = VFDText.wrap(path, inner.w)
        var lines: [String] = Array(wrapped.prefix(2))
        if wrapped.count > 2 && lines.count == 2 {
            lines[1] = VFDText.fit(lines[1] + " …", inner.w)
        }
        var r: Int = inner.r + 1
        for ln in lines {
            fb.text(inner.c, r, ln, .small, VFDInk.dim)
            r += VFDW.line
        }
        r += 2
        let exportEnd: Int = chip(fb, inner.c, r, "EXPORT", action: {
            VFDScanScreen.exportLibrary(ctx)
        })
        chip(fb, exportEnd + VFDW.optGap, r, "IMPORT", action: {
            VFDScanScreen.importLibrary(ctx)
        })
        let end: Int = r + VFDW.ctrlH + 2
        if glue == "top" {
            fb.vline(c + 2, end - 2, 3, VFDInk.dim)
        }
        return VFDW.panel(fb, L, c, y, w, end - y + 1, title: "LIBRARY FILE (FILES APP · EDITABLE)")
    }

    /// BUF UNIQUE n (or BUF RAW n) with CLR on the right. Returns the next free row.
    private static func bufferRow(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ s: VFDScanState,
                                  _ c: Int, _ y: Int, _ w: Int) -> Int {
        let scan: ScanEngine = ctx.scan
        let text: String = s.raw ? "BUF RAW \(s.rawCount)" : "BUF UNIQUE \(s.uniqueCount)"
        let bx: Int = textButton(fb, L, right: c + w - 1, y, "CLR", action: {
            scan.clearLive()
        })
        fb.textFit(c, y + VFDW.ctrlText, text, bx - c - 6, .small, VFDInk.dim)
        return y + VFDW.ctrlH + VFDW.gap
    }

    /// The gesture hint, wrapped only at its " · " separators. Returns the row after the last line.
    private static func hintLines(_ fb: VFDFrameBuffer, _ c: Int, _ y0: Int, _ w: Int, _ s: String) -> Int {
        var y: Int = y0
        for ln in VFDW.tokenLines(s, w, sep: " · ") {
            fb.text(c, y, ln, .small, VFDInk.dim)
            y += VFDW.line
        }
        return y
    }

    // MARK: live feed

    /// Packet row height: label, hex (when there is one), the subtitle (always: it starts with
    /// RSSI), the divider (VFDW.packetRow's geometry).
    private static func rowHeight(_ pkt: LivePacket) -> Int {
        let hexLines: Int = pkt.hex.isEmpty ? 0 : VFDW.line
        return 3 + hexLines + VFDW.line + 10 + 1
    }

    /// Where every header and row of the feed goes, from y0: GROUPED = a header per visible
    /// section (newest first inside), its rows unless folded; RAW = every advert the CLASS filter
    /// keeps. An empty buffer gets the LISTEN line, centred in the space left.
    private static func feedLayout(_ ctx: VFDContext, _ L: VFDLayout, _ s: VFDScanState, _ y0: Int) -> VFDScanFeedLayout {
        let scan: ScanEngine = ctx.scan
        let empty: Bool = s.raw ? scan.rawLivePackets.isEmpty : scan.livePackets.isEmpty
        if empty {
            let mid: Int = max(y0, (y0 + L.contentBottom) / 2 - 4)
            return VFDScanFeedLayout(entries: [], emptyRow: mid, raw: s.raw, end: mid + VFDW.line)
        }
        var entries: [VFDScanFeedEntry] = []
        var y: Int = y0
        if s.raw {
            for pkt in scan.rawLivePackets {
                let section: LivePacketSection = LivePacketSort.section(of: pkt)
                if !s.visible.contains(section) { continue }
                let h: Int = rowHeight(pkt)
                entries.append(VFDScanFeedEntry(header: nil, count: 0, folded: false, packet: pkt, top: y, bottom: y + h))
                y += h
            }
            return VFDScanFeedLayout(entries: entries, emptyRow: nil, raw: true, end: y)
        }
        let groups: [(LivePacketSection, [LivePacket])] = LivePacketSort.grouped(scan.livePackets)
        var first: Bool = true
        for group in groups {
            let section: LivePacketSection = group.0
            let packets: [LivePacket] = group.1
            if !s.visible.contains(section) || packets.isEmpty { continue }
            let folded: Bool = s.collapsed.contains(section.title)
            // The first header sits under the hairline, not sectionGap below it.
            let top: Int = first ? y - (VFDW.sectionGap - VFDW.gap) + 2 : y + 1
            let titleRow: Int = top > L.contentTop ? top + VFDW.sectionGap - VFDW.gap : top
            let next: Int = titleRow + VFDW.sectionH + VFDW.gap
            entries.append(VFDScanFeedEntry(header: section, count: packets.count, folded: folded, packet: nil,
                                            top: top, bottom: next))
            y = next
            first = false
            if folded { continue }
            y -= VFDW.gap + 2
            for pkt in packets {
                let h: Int = rowHeight(pkt)
                entries.append(VFDScanFeedEntry(header: nil, count: 0, folded: false, packet: pkt, top: y, bottom: y + h))
                y += h
            }
        }
        return VFDScanFeedLayout(entries: entries, emptyRow: nil, raw: false, end: y)
    }

    /// Draws the feed entries that reach into the current clip. glue (snapping probes only) also
    /// lights column 0 from a section title down to its rule (both edges) and, for the top edge,
    /// from a row's last text line down to its divider, so an edge hides a rule or divider with
    /// the line it belongs to.
    private static func drawFeed(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ layout: VFDScanFeedLayout,
                                 _ c: Int, _ w: Int, glue: String?) {
        if let mid = layout.emptyRow {
            let msg: String = "LISTEN 0x0183 MANUFACTURER"
            fb.text(VFDW.cx(c, w, msg), mid, msg, .small, VFDInk.dim)
            return
        }
        let clip: (c: Int, r: Int, w: Int, h: Int) = fb.clipRect
        let oy: Int = fb.originY
        let clipTop: Int = clip.r - oy
        let clipBottom: Int = clip.r + clip.h - oy
        for entry in layout.entries {
            if entry.bottom <= clipTop || entry.top >= clipBottom { continue }
            if let section = entry.header {
                let key: String = section.title
                let next: Int = VFDW.section(fb, L, c, entry.top, w, section.title, count: entry.count,
                                             collapsed: entry.folded, action: {
                                                 VFDScanScreen.toggleSection(ctx, key)
                                             })
                if glue != nil {
                    fb.vline(0, next - VFDW.sectionH - VFDW.gap, 10, VFDInk.dim)
                }
            } else if let pkt = entry.packet {
                let next: Int = drawRow(ctx, fb, L, pkt, raw: layout.raw, c, entry.top, w)
                if glue == "top" {
                    fb.vline(0, next - VFDW.line, VFDW.line, VFDInk.dim)
                }
            }
        }
    }

    /// One PacketRow: tap = transmit, hold = the packet menu, swipe left = remove (asks first),
    /// swipe right = ADD TO TX / RECATEGORIZE. Band sources are selected rows.
    private static func drawRow(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ pkt: LivePacket,
                                raw: Bool, _ c: Int, _ y: Int, _ w: Int) -> Int {
        let tx: TxEngine = ctx.tx
        let hex: String = pkt.hex
        let label: String = pkt.label
        let subtitle: String = liveSubtitle(pkt)
        return VFDW.packetRow(fb, L, c, y, w, label, hex, subtitle: subtitle, selected: pkt.isBand,
                              action: {
                                  tx.transmit(hex: hex, label: label)
                              },
                              long: {
                                  VFDScanScreen.openActions(ctx, pkt, raw: raw)
                              },
                              swipeLeft: {
                                  VFDScanScreen.askDelete(ctx, pkt, raw: raw)
                              },
                              swipeRight: {
                                  VFDScanScreen.promote(ctx, pkt)
                              })
    }

    /// ScanScreen.liveSubtitle: RSSI, the short source id, BAND for a tagged source, the note.
    private static func liveSubtitle(_ pkt: LivePacket) -> String {
        var text: String = "RSSI \(pkt.rssi)"
        if !pkt.address.isEmpty {
            text += " · " + shortAddress(pkt.address)
        }
        if pkt.isBand {
            text += " · BAND"
        }
        if !pkt.note.isEmpty {
            text += " | " + pkt.note
        }
        return text
    }

    /// The feed in screen rows [top, contentBottom), scrolled by its own region (clamped to the
    /// feed's length, as a List stops at its end), with its scroll indicator.
    private static func feedWindow(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ s: VFDScanState,
                                   _ c: Int, _ top: Int, _ w: Int) {
        let view: Int = L.contentBottom - top
        if view <= 0 { return }
        // The feed's first line keeps its place under the hairline.
        let y0: Int = top + 4
        let layout: VFDScanFeedLayout = feedLayout(ctx, L, s, y0)
        let total: Int = layout.end - top
        let off: Int = ctx.scroll(VFDScanKeys.feedRegion, limit: total - view)
        windowed(fb, top: top, h: view, scroll: off, cols: nil, draw: { (target: VFDFrameBuffer, edge: String?) -> Void in
            VFDScanScreen.drawFeed(ctx, target, L, layout, c, w, glue: edge)
        })
        registerRegion(fb, VFDScanKeys.feedRegion, top: top, h: view, limit: total - view)
        VFDW.listScrollbar(fb, top, view, total, off)
    }

    // MARK: windows

    /// Draw `draw(fb, nil)` scrolled by `scroll` rows inside screen rows [top, top + h), hiding a
    /// line cut by either edge (snappedWindow over `draw(probe, edge)`), and drop the taps the
    /// edges cut shorter than tapRows. fb has origin 0. Returns the rows actually used.
    @discardableResult
    private static func windowed(_ fb: VFDFrameBuffer, top: Int, h: Int, scroll: Int, cols: (Int, Int)?,
                                 draw: (VFDFrameBuffer, String?) -> Void) -> (top: Int, bottom: Int) {
        fb.pushClip(0, top, fb.cols, h, dy: -scroll)
        let win: (top: Int, bottom: Int) = snappedWindow(fb, top: top, bottom: top + h, cols: cols, draw: draw)
        let firstTap: Int = fb.taps.count
        fb.pushClip(0, win.top - fb.originY, fb.cols, win.bottom - win.top)
        draw(fb, nil)
        fb.popClip()
        fb.popClip()
        dropShortTaps(fb, from: firstTap)
        return win
    }

    /// Rows (top, bottom) of the window a scrolling block may use without cutting a line: a band of
    /// lit rows crossing an edge is left out (scan.py snapped_window: one probe per edge, looking
    /// only at columns cols.0 ..< cols.1 when given).
    private static func snappedWindow(_ fb: VFDFrameBuffer, top: Int, bottom: Int, cols: (Int, Int)?,
                                      draw: (VFDFrameBuffer, String?) -> Void) -> (top: Int, bottom: Int) {
        let c0: Int = cols?.0 ?? 0
        let c1: Int = cols?.1 ?? fb.cols
        var t: Int = top
        var b: Int = bottom
        let topProbe: VFDFrameBuffer = probe(fb, edge: "top", from: top - probeBand, to: top + probeBand, draw: draw)
        if probeLit(topProbe, t - 1, c0, c1) && probeLit(topProbe, t, c0, c1) {
            while t < b && probeLit(topProbe, t, c0, c1) {
                t += 1
            }
        }
        let bottomProbe: VFDFrameBuffer = probe(fb, edge: "bottom", from: bottom - probeBand,
                                                to: bottom + probeBand, draw: draw)
        if probeLit(bottomProbe, b - 1, c0, c1) && probeLit(bottomProbe, b, c0, c1) {
            while b > t && probeLit(bottomProbe, b - 1, c0, c1) {
                b -= 1
            }
        }
        return (top: t, bottom: b)
    }

    /// The block drawn unclipped (but for screen rows [from, to)) on a scratch buffer with fb's
    /// origin.
    private static func probe(_ fb: VFDFrameBuffer, edge: String, from r0: Int, to r1: Int,
                              draw: (VFDFrameBuffer, String?) -> Void) -> VFDFrameBuffer {
        let buf: VFDFrameBuffer = VFDFrameBuffer(cols: fb.cols, rows: fb.rows, alarmInverted: fb.alarmInverted)
        let a: Int = max(0, r0)
        let b: Int = min(fb.rows, r1)
        buf.pushClip(0, a, fb.cols, max(0, b - a), dy: fb.originY)
        draw(buf, edge)
        while buf.clipDepth > 0 {
            buf.popClip()
        }
        return buf
    }

    /// A scroll region over screen rows [top, top + h) whose drag limit is `limit` rows, even when
    /// the page window cuts the region shorter (the renderer's limit is contentRows minus the
    /// part of the region that is shown). Nothing when it cannot scroll.
    private static func registerRegion(_ fb: VFDFrameBuffer, _ id: String, top: Int, h: Int, limit: Int) {
        let clip: (c: Int, r: Int, w: Int, h: Int) = fb.clipRect
        let oy: Int = fb.originY
        let r0: Int = max(top + oy, clip.r)
        let r1: Int = min(top + h + oy, clip.r + clip.h)
        let shown: Int = max(0, r1 - r0)
        if shown <= 0 || limit <= 0 { return }
        fb.scrollRegion(id: id, 0, top, fb.cols, h, contentRows: limit + shown)
    }

    private static func probeLit(_ buf: VFDFrameBuffer, _ r: Int, _ c0: Int, _ c1: Int) -> Bool {
        if r < 0 || r >= buf.rows { return false }
        let start: Int = r * buf.cols
        let end: Int = min(buf.cols, c1)
        var c: Int = max(0, c0)
        while c < end {
            if buf.cells[start + c] != 0 { return true }
            c += 1
        }
        return false
    }

    private static func dropShortTaps(_ fb: VFDFrameBuffer, from start: Int) {
        if start < 0 || start >= fb.taps.count { return }
        var kept: [VFDHit] = Array(fb.taps[0..<start])
        for tp in fb.taps[start...] where tp.h >= VFDW.tapRows {
            kept.append(tp)
        }
        fb.taps = kept
    }

    // MARK: toast

    /// Where the standard screen shows a toast: a boxed message over the bottom of the feed for
    /// 2.5 s (no taps; the feed under it still answers).
    private static func drawToast(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout) {
        let ui: VFDUIState = scanUI(ctx)
        let text: String = ui.string(VFDScanKeys.toast)
        if text.isEmpty { return }
        let age: Double = ctx.time - ui.double(VFDScanKeys.toastAt)
        if age < -1.0 || age >= toastSeconds { return }
        let c: Int = L.left + 8
        let w: Int = L.width - 16
        let lines: [String] = VFDText.wrap(VFDW.upper(text), w - 12)
        if lines.isEmpty { return }
        let h: Int = lines.count * VFDW.line + 8
        let top: Int = L.contentBottom - h - 6
        fb.fill(c - 2, top - 2, w + 4, h + 4, VFDInk.unlit)
        fb.box(c, top, w, h, VFDInk.highlight)
        var r: Int = top + 4
        for ln in lines {
            fb.text(VFDW.cx(c, w, ln), r, ln, .small, VFDInk.text)
            r += VFDW.line
        }
    }

    /// Shows `text` for toastSeconds (an action, never called from draw). The redraw scheduled for
    /// the end takes the toast away on time instead of on the next 1 s clock tick.
    private static func showToast(_ ctx: VFDContext, _ text: String) {
        let ui: VFDUIState = scanUI(ctx)
        ui.setDouble(VFDScanKeys.toastAt, ctx.now)
        ui.setString(VFDScanKeys.toast, text)
        let delay: Double = toastSeconds + 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak ctx] in
            ctx?.redraw()
        }
    }

    // MARK: actions

    private static func setViewMode(_ ctx: VFDContext, raw: Bool) {
        let ui: VFDUIState = scanUI(ctx)
        let next: String = raw ? "RAW" : "GROUPED"
        if ui.string(VFDScanKeys.viewMode, default: "GROUPED") == next { return }
        ui.setString(VFDScanKeys.viewMode, next)
        ctx.setScroll(VFDScanKeys.feedRegion, 0)
    }

    /// Folds or unfolds a feed section, saved under ScanUiPrefs' key in section order.
    private static func toggleSection(_ ctx: VFDContext, _ title: String) {
        let ui: VFDUIState = scanUI(ctx)
        var set: Set<String> = []
        for name in ui.storedStrings(VFDScanKeys.collapsedSections) {
            set.insert(name.uppercased())
        }
        if set.contains(title) {
            set.remove(title)
        } else {
            set.insert(title)
        }
        var names: [String] = []
        for section in LivePacketSection.allCases where set.contains(section.title) {
            names.append(section.title)
        }
        ui.setStoredStrings(VFDScanKeys.collapsedSections, names)
    }

    /// SectionFilterMenu: ticks the shown sections; a pick toggles one and the menu stays open.
    private static func openClassMenu(_ ctx: VFDContext) {
        let ui: VFDUIState = scanUI(ctx)
        let hidden: Set<String> = ui.strings(VFDScanKeys.hiddenSections)
        var items: [VFDMenuItem] = []
        var shownCount: Int = 0
        for section in LivePacketSection.allCases {
            let shown: Bool = !hidden.contains(section.rawValue)
            if shown {
                shownCount += 1
            }
            let label: String = shown ? section.title + " ✓" : section.title
            let key: String = section.rawValue
            items.append(VFDMenuItem(label, action: {
                VFDScanScreen.scanUI(ctx).toggleMember(VFDScanKeys.hiddenSections, key)
                VFDScanScreen.openClassMenu(ctx)
            }))
        }
        let total: Int = LivePacketSection.allCases.count
        ctx.menu(title: "CLASS \(shownCount)/\(total)", items: items)
    }

    /// The long-press sheet (PacketSheetInfo) as a menu.
    private static func openActions(_ ctx: VFDContext, _ pkt: LivePacket, raw: Bool) {
        let tx: TxEngine = ctx.tx
        let vm: AppViewModel = ctx.vm
        let store: MagicStore = ctx.store
        let hex: String = pkt.hex
        let label: String = pkt.label
        let items: [VFDMenuItem] = [
            VFDMenuItem("Transmit", action: {
                tx.transmit(hex: hex, label: label)
            }),
            VFDMenuItem("Load in Lab", action: {
                vm.loadInLab(hex: hex, label: label)
            }),
            VFDMenuItem("Add to TX library", action: {
                _ = store.saveCustomPreset(label: label, hex: hex)
            }),
            VFDMenuItem("Recategorize", action: {
                VFDScanScreen.askRecategorize(ctx, hex: hex, label: label)
            }),
            VFDMenuItem("Remove", destructive: true, action: {
                VFDScanScreen.askDelete(ctx, pkt, raw: raw)
            }),
        ]
        ctx.menu(title: label, items: items)
    }

    /// The swipe-right "Packet action" alert: ADD TO TX / RECATEGORIZE.
    private static func promote(_ ctx: VFDContext, _ pkt: LivePacket) {
        let store: MagicStore = ctx.store
        let hex: String = pkt.hex
        let label: String = pkt.label
        let items: [VFDMenuItem] = [
            VFDMenuItem("ADD TO TX", action: {
                _ = store.saveCustomPreset(label: label, hex: hex)
            }),
            VFDMenuItem("RECATEGORIZE", action: {
                VFDScanScreen.askRecategorize(ctx, hex: hex, label: label)
            }),
        ]
        ctx.menu(title: "Packet action · " + label, items: items)
    }

    /// The category picker: SHOW / ANIMATION / COLOR / UNKNOWN.
    private static func askRecategorize(_ ctx: VFDContext, hex: String, label: String) {
        let store: MagicStore = ctx.store
        var items: [VFDMenuItem] = []
        for category in MagicCategory.allCases {
            let picked: MagicCategory = category
            items.append(VFDMenuItem(category.rawValue, action: {
                VFDScanScreen.recategorize(store, hex: hex, label: label, category: picked)
            }))
        }
        let title: String = label.isEmpty ? "Recategorize" : "Recategorize · " + label
        ctx.menu(title: title, items: items)
    }

    /// A heard packet has to be in the library before it can carry a category: it is saved as a
    /// TX preset first, then the library row with the same hex is recategorized.
    private static func recategorize(_ store: MagicStore, hex: String, label: String, category: MagicCategory) {
        let canonical: String = HexUtils.canonicalHex(hex)
        let presetLabel: String = label.isEmpty ? category.rawValue : label
        _ = store.saveCustomPreset(label: presetLabel, hex: hex)
        let library: [MagicPacket] = store.allTransmitPackets()
        let match: MagicPacket? = library.first(where: { (packet: MagicPacket) -> Bool in
            HexUtils.canonicalHex(packet.hex) == canonical
        })
        if let found = match {
            store.recategorizePacket(id: found.id, category: category)
        }
    }

    /// confirmDelete: "Remove from scan list?" (GROUPED) or "Remove raw packet?" (RAW).
    private static func askDelete(_ ctx: VFDContext, _ pkt: LivePacket, raw: Bool) {
        let scan: ScanEngine = ctx.scan
        let title: String = raw ? "Remove raw packet?" : "Remove from scan list?"
        let upperLabel: String = pkt.label.uppercased()
        var message: String = upperLabel
        if !pkt.hex.isEmpty {
            message = upperLabel.isEmpty ? pkt.hex : upperLabel + "\n" + pkt.hex
        }
        let stamp: Int64 = pkt.timestampMs
        let hex: String = pkt.hex
        let key: String = pkt.dedupeKey
        ctx.confirm(title: title, message: message, confirmLabel: "DELETE", destructive: true, action: {
            if raw {
                scan.removeRawLive(timestampMs: stamp, hex: hex)
            } else {
                scan.removeLive(dedupeKey: key)
            }
        })
    }

    /// DELETE ALL saved band packets, only after the same question the standard screen asks.
    private static func confirmDeleteBands(_ ctx: VFDContext) {
        let store: MagicStore = ctx.store
        let saved: Int = store.savedBandCount()
        let what: String = "Removes all \(saved) guest-band telemetry packets from your library. "
        let rest: String = "Logs and other packets are untouched. This only runs when you tap Delete."
        ctx.confirm(title: "Delete saved band packets?", message: what + rest, confirmLabel: "DELETE",
                    destructive: true, action: {
                        let removed: Int = store.deleteSavedBands()
                        VFDScanScreen.showToast(ctx, "Deleted \(removed) band packets")
                    })
    }

    /// Writes the library file and hands it to the system share sheet; the toast follows once the
    /// sheet has gone.
    private static func exportLibrary(_ ctx: VFDContext) {
        let store: MagicStore = ctx.store
        guard let url = store.exportLibrary() else {
            showToast(ctx, "Export failed — library file not written")
            return
        }
        let name: String = URL(fileURLWithPath: store.libraryFilePath).lastPathComponent
        let message: String = "Exported to Files app → MagicMaker → " + name
        // Once per export, whichever of the share sheet's finish and the sheet's disappearance
        // comes first (ScanScreen.exportSheetClosed).
        let toast: VFDScanOnce = VFDScanOnce({
            VFDScanScreen.showToast(ctx, message)
        })
        let finish: () -> Void = {
            ctx.dismissSheet()
            toast.fire()
        }
        let gone: () -> Void = {
            toast.fire()
        }
        let view: VFDScanShareView = VFDScanShareView(url: url, onFinish: finish, onGone: gone)
        ctx.sheet(id: "scan.export") {
            view
        }
    }

    /// The system document picker (fileImporter, JSON or any data) in a sheet.
    private static func importLibrary(_ ctx: VFDContext) {
        let picked: (Result<URL, Error>) -> Void = { (result: Result<URL, Error>) -> Void in
            VFDScanScreen.finishImport(ctx, result)
        }
        let view: VFDScanImportView = VFDScanImportView(onPicked: picked)
        ctx.sheet(id: "scan.import") {
            view
        }
    }

    private static func finishImport(_ ctx: VFDContext, _ result: Result<URL, Error>) {
        let ok: Bool
        switch result {
        case .success(let url):
            ok = ctx.store.importLibrary(from: url)
        case .failure:
            ok = false
        }
        ctx.dismissSheet()
        showToast(ctx, ok ? "Library imported" : "No file at path (or unreadable)")
    }
}

// MARK: - System UI (sheet fallbacks)

/// Runs its action the first time `fire()` is called and never again (the export toast).
private final class VFDScanOnce {
    private var done: Bool = false
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func fire() {
        if done { return }
        done = true
        action()
    }
}

/// The system share sheet for the exported library file. When sharing finishes or is cancelled
/// it closes itself, which SwiftUI does not always report, so `onFinish` says so.
private struct VFDScanShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let items: [Any] = [url]
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let finish: () -> Void = onFinish
        controller.completionWithItemsHandler = { _, _, _, _ in
            finish()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// The share sheet in the VFD sheet; `onGone` runs when it leaves the screen (DONE or finished).
private struct VFDScanShareView: View {
    let url: URL
    let onFinish: () -> Void
    let onGone: () -> Void

    var body: some View {
        VFDScanShareSheet(url: url, onFinish: onFinish)
            .onDisappear {
                onGone()
            }
    }
}

/// Opens the system document picker for a library file as soon as the sheet is up; CHOOSE FILE
/// opens it again after a cancel.
private struct VFDScanImportView: View {
    let onPicked: (Result<URL, Error>) -> Void
    @State private var importing: Bool = false
    @State private var finished: Bool = false

    init(onPicked: @escaping (Result<URL, Error>) -> Void) {
        self.onPicked = onPicked
    }

    var body: some View {
        content
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [UTType.json, UTType.data],
                onCompletion: { result in
                    finished = true
                    onPicked(result)
                }
            )
            .onAppear {
                openSoon()
            }
    }

    private var content: some View {
        VStack(spacing: 14) {
            Text("IMPORT LIBRARY FILE")
                .font(MMTheme.techHeader())
                .foregroundStyle(MMTheme.cyan)
            Button {
                importing = true
            } label: {
                chooseLabel
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var chooseLabel: some View {
        Text("CHOOSE FILE")
            .font(MMTheme.techLabel(12))
            .foregroundStyle(MMTheme.cyan)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(MMTheme.cyan, lineWidth: 0.5))
    }

    /// After the sheet's own presentation has settled, so the picker is not refused.
    private func openSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            if !finished {
                importing = true
            }
        }
    }
}
