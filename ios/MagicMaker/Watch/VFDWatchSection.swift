import Foundation

// The Apple Watch favourites in the VFD theme (docs/WATCH_APP.md 2.4 and 2.5): the star glyph the
// TX, WAND and LAB rows draw, the star actions with the FAVORITES FULL confirm, and SETTINGS →
// APPLE WATCH (link line, then the favourites: tap sends, hold renames, up / down reorder, the
// star removes after a confirm). VFDWidgets.swift is not changed: no golden output moves. The ★
// character is not in the VFD font, so VFD text says "STAR".

/// The watch star on the VFD grid: a 7 x 7 glyph, highlight when starred, dim otherwise.
enum VFDStar {
    static let glyph: [String] = ["...#...", "..###..", "#######", ".#####.", "..###..", ".##.##.", ".#...#."]
    static let size: Int = 7
    /// Cells a star column takes at a row's right edge: 3 air, glyph, 4 air.
    static let colW: Int = 14
    /// A boxed star cell (WAND picker row, quick button): this wide.
    static let boxW: Int = 19

    static func draw(_ fb: VFDFrameBuffer, _ x: Int, _ y: Int, on: Bool) {
        let ink: UInt8 = on ? VFDInk.highlight : VFDInk.dim
        var j: Int = 0
        for row in glyph {
            var i: Int = 0
            for ch in row {
                if ch == "#" { fb.set(x + i, y + j, ink) }
                i += 1
            }
            j += 1
        }
    }

    /// A star box w x h at (x, y): border highlight when starred, dim otherwise, the glyph centred.
    static func box(_ fb: VFDFrameBuffer, _ x: Int, _ y: Int, _ w: Int, _ h: Int, on: Bool) {
        fb.box(x, y, w, h, on ? VFDInk.highlight : VFDInk.dim)
        draw(fb, x + VFDMath.floorDiv(w - size, 2), y + VFDMath.floorDiv(h - size, 2), on: on)
    }
}

@MainActor
enum VFDWatchSection {
    static let title: String = "APPLE WATCH"
    static let emptyText: String = "Star a packet on TX, WAND (colours, codes, quick button) or LAB (MY PRESETS) to add it here. The watch sends through this iPhone and its relay."
    static let hint: String = "TAP SENDS · HOLD RENAMES"
    /// One control column at a list row's right edge (up, down, star).
    static let controlW: Int = 13

    // MARK: - Star actions (run from taps, never from draw)

    /// A packet row's star: adds it to the watch favourites or removes it; FULL when refused.
    static func toggleStar(_ ctx: VFDContext, hex: String, label: String, source: String) {
        if !WatchFavoritesStore.shared.toggle(hex: hex, label: label, source: source) {
            showFull(ctx)
        }
    }

    /// The WAND quick button's star (its favourite follows the button).
    static func toggleQuickStar(_ ctx: VFDContext) {
        let vm: AppViewModel = ctx.vm
        vm.reloadWandQuickIfChanged()
        if !WatchFavoritesStore.shared.toggleQuick(label: vm.wandQuickLabel, hex: vm.wandQuickHex) {
            showFull(ctx)
        }
    }

    static func showFull(_ ctx: VFDContext) {
        ctx.confirm(title: WatchFavoritesStore.fullTitle, message: WatchFavoritesStore.fullMessage,
                    confirmLabel: "OK") {
        }
    }

    // MARK: - SETTINGS → APPLE WATCH

    /// The section from row `top`; returns the next free row (read-only: changes happen in the
    /// tap closures).
    static func draw(_ ctx: VFDContext, _ c: Int, _ top: Int, _ w: Int) -> Int {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let items: [WatchFavorite] = WatchFavoritesStore.shared.items
        let bridge: WatchBridge = WatchBridge.shared
        var y: Int = VFDW.section(fb, L, c, top, w, title,
                                  right: "\(items.count)/\(WatchProtocol.maxFavorites)")
        // The frame's clock (ctx.time), so both passes of a draw read the same "SYNCED ..S AGO".
        let now: Date = Date(timeIntervalSinceReferenceDate: ctx.time)
        y = linkLine(fb, L, c, y, w, bridge.linkText(now: now), linkInk(bridge.linkState))
        if items.isEmpty {
            return VFDW.textBlock(fb, L, c, y, w, emptyText, color: VFDInk.dim)
        }
        y = VFDW.textBlock(fb, L, c, y, w, hint, color: VFDInk.dim)
        var index: Int = 0
        for favorite in items {
            y = row(ctx, favorite, index: index, count: items.count, c, y, w)
            index += 1
        }
        return y + VFDW.gap
    }

    private static func linkInk(_ state: WatchBridge.LinkState) -> UInt8 {
        switch state {
        case .notInstalled: return VFDInk.alarm
        case .live: return VFDInk.highlight
        default: return VFDInk.dim
        }
    }

    /// The link line, word-wrapped. ALARM lines go through VFDW.alarmText (as VFDLinkScreen's
    /// infoRow does), so a red-ish base draws them as inverted blocks like every other VFD alarm.
    private static func linkLine(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int,
                                 _ text: String, _ ink: UInt8) -> Int {
        if ink != VFDInk.alarm {
            return VFDW.textBlock(fb, L, c, r, w, text, color: ink)
        }
        let lines: [String] = VFDText.wrap(text, w - 4)
        if lines.isEmpty { return r }
        var y: Int = r
        for ln in lines {
            VFDW.alarmText(fb, c, y, ln)
            y += VFDW.line
        }
        return y + VFDW.gap
    }

    /// Line 1: the label (text ink) and a QUICK tag for the quick button's favourite. Line 2: a
    /// true-colour dot for a wand colour, then BAND / WAND / PING · hex (dim). Right: up, down and
    /// the filled star, each its own tap (up is dim with no tap on the first row, down on the
    /// last). A dotted divider. Returns the next row's r.
    private static func row(_ ctx: VFDContext, _ favorite: WatchFavorite, index: Int, count: Int,
                            _ c: Int, _ r: Int, _ w: Int) -> Int {
        let fb: VFDFrameBuffer = ctx.fb
        let y: Int = r + 3
        let end: Int = y + VFDW.line + 7 + 3
        let ctrlX: Int = c + w - 3 * controlW
        let textLimit: Int = ctrlX - 4 - (c + 2)
        let label: String = VFDW.upper(favorite.label)
        let tag: String = favorite.phoneIsQuick ? "QUICK" : ""
        let tagW: Int = tag.isEmpty ? 0 : VFDText.width(tag) + 8
        let labelEnd: Int = fb.textFit(c + 2, y, label, textLimit - tagW, .small, VFDInk.text)
        if !tag.isEmpty {
            VFDW.tagBox(fb, labelEnd + 5, y, tag)
        }
        var detailX: Int = c + 2
        if let rgb = favorite.phoneSwatchRGB {
            let dot: UInt8 = fb.rgb(rgb)
            fb.fill(detailX + 1, y + VFDW.line + 1, 3, 5, dot)
            fb.fill(detailX, y + VFDW.line + 2, 5, 3, dot)
            detailX += 5 + 4
        }
        fb.textFit(detailX, y + VFDW.line, favorite.phoneDetailText, ctrlX - 4 - detailX, .small, VFDInk.dim)
        fb.hline(c, end, w, VFDInk.dim, step: 2)

        // Up, down, star: three columns, the glyphs centred on the row.
        let mid: Int = r + VFDMath.floorDiv(end - r, 2)
        let canUp: Bool = index > 0
        let canDown: Bool = index < count - 1
        let upX: Int = ctrlX
        let downX: Int = ctrlX + controlW
        let starX: Int = ctrlX + 2 * controlW
        VFDW.chevronUp(fb, upX + 3, mid - 3, canUp ? VFDInk.highlight : VFDInk.dim)
        VFDW.chevron(fb, downX + 3, mid - 3, false, canDown ? VFDInk.highlight : VFDInk.dim)
        VFDStar.draw(fb, starX + 3, mid - 3, on: true)

        let item: WatchFavorite = favorite
        let id: String = favorite.id
        VFDW.tap(fb, c, r, ctrlX - c, end - r, "favorite:" + label,
                 action: { WatchBridge.shared.sendFromPhone(item) },
                 long: { askRename(ctx, item) })
        if canUp {
            VFDW.tap(fb, upX, r, controlW, end - r, "favorite:up:" + label,
                     action: { WatchFavoritesStore.shared.move(id: id, by: -1) })
        }
        if canDown {
            VFDW.tap(fb, downX, r, controlW, end - r, "favorite:down:" + label,
                     action: { WatchFavoritesStore.shared.move(id: id, by: 1) })
        }
        VFDW.tap(fb, starX, r, c + w - starX, end - r, "favorite:star:" + label,
                 action: { askRemove(ctx, item) })
        return end + 1
    }

    private static func askRename(_ ctx: VFDContext, _ favorite: WatchFavorite) {
        let id: String = favorite.id
        ctx.prompt(title: "RENAME FAVORITE", text: favorite.label, keyboard: .text) { (typed: String) in
            WatchFavoritesStore.shared.rename(id: id, label: typed)
        }
    }

    private static func askRemove(_ ctx: VFDContext, _ favorite: WatchFavorite) {
        let id: String = favorite.id
        let message: String = VFDW.upper(favorite.label) + "\n" + favorite.hex
        ctx.confirm(title: "Remove from watch favorites?", message: message, confirmLabel: "REMOVE",
                    destructive: true) {
            WatchFavoritesStore.shared.remove(id: id)
        }
    }
}
