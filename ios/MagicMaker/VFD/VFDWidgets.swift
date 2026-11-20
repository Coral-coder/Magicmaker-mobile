import Foundation

// VFD app chrome and content widgets on a VFDFrameBuffer, in whole cells.
// Port of tools/vfd/widgets.py (same geometry, return values, tap names and tap padding) plus the
// two-pass screen composition of tools/vfd/render_previews.py (contentWindow / drawScreen).
// Foundation only: this file is also compiled with plain swiftc on Linux.
//
// Content widgets take (fb, L, c, r, w, ...): left column, top row and available width, and
// return the NEXT FREE ROW with the standard gap included. Where the Python takes a tap name,
// these take the name (nil = the default name) and the closures the hit runs.

// MARK: - Layout

/// Fixed rows and columns of the VFD screen (widgets.Layout). left / right are the first / last
/// content columns (inclusive); content rows are contentTop ..< contentBottom.
struct VFDLayout {
    let cols: Int
    let rows: Int
    /// First drawable row.
    let safeTop: Int
    /// First row of the bottom safe area.
    let safeEnd: Int
    let left: Int
    let right: Int
    let width: Int
    let tapRows: Int
    let headerTop: Int
    /// Mid title caps row.
    let titleRow: Int
    /// Small text centred on the title caps.
    let headerTextRow: Int
    let telemetryRow: Int
    let headerRule: Int
    let contentTop: Int
    let tabH: Int
    /// Top rows of tab-bar row 1 and row 2.
    let tabRows: [Int]
    let tabRule: Int
    /// Exclusive.
    let contentBottom: Int
    let contentH: Int
    let tabCellW: Int
    let tabLeft: Int

    init(cols: Int, rows: Int, safeTop: Int, safeBottom: Int) {
        self.cols = cols
        self.rows = rows
        self.safeTop = safeTop
        let safeEnd: Int = rows - safeBottom
        self.safeEnd = safeEnd
        let left: Int = VFDW.margin
        let right: Int = cols - 1 - VFDW.margin
        let width: Int = right - left + 1
        self.left = left
        self.right = right
        self.width = width
        self.tapRows = VFDW.tapRows

        let headerTop: Int = safeTop + 2
        self.headerTop = headerTop
        self.titleRow = headerTop
        self.headerTextRow = headerTop + 4
        let telemetryRow: Int = headerTop + 14 + 4
        self.telemetryRow = telemetryRow
        let headerRule: Int = telemetryRow + 7 + 3
        self.headerRule = headerRule
        let contentTop: Int = headerRule + 4
        self.contentTop = contentTop

        self.tabH = VFDW.tabH
        let row2: Int = safeEnd - 2 - VFDW.tabH
        let row1: Int = row2 - VFDW.tabH - 1
        self.tabRows = [row1, row2]
        let tabRule: Int = row1 - 3
        self.tabRule = tabRule
        let contentBottom: Int = tabRule - 3
        self.contentBottom = contentBottom
        self.contentH = contentBottom - contentTop

        let cellW: Int = VFDMath.floorDiv(width - (VFDW.tabCols - 1), VFDW.tabCols)
        self.tabCellW = cellW
        let used: Int = cellW * VFDW.tabCols + (VFDW.tabCols - 1)
        self.tabLeft = left + VFDMath.floorDiv(width - used, 2)
    }

    init(device: VFDDevice) {
        self.init(cols: device.cols, rows: device.rows, safeTop: device.safeTop, safeBottom: device.safeBottom)
    }

    /// Proportional column: left + round(frac * width) (x(1.0) = right + 1).
    func x(_ frac: Double) -> Int {
        return left + VFDMath.roundHalfAway(frac * Double(width))
    }

    /// n equal columns across [c, c + w) (default the content width) gap cells apart; spare cells
    /// go to the last one.
    func split(_ n: Int, gap: Int = 6, c: Int? = nil, w: Int? = nil) -> [(c: Int, w: Int)] {
        if n <= 0 { return [] }
        let c0: Int = c ?? left
        let w0: Int = w ?? width
        let cw: Int = VFDMath.floorDiv(w0 - gap * (n - 1), n)
        var out: [(c: Int, w: Int)] = []
        for i in 0..<n {
            let ci: Int = c0 + i * (cw + gap)
            let wi: Int = (i == n - 1) ? (c0 + w0 - ci) : cw
            out.append((c: ci, w: wi))
        }
        return out
    }

    /// Cell of tab `index` (0...9).
    func tabCell(_ index: Int) -> (c: Int, r: Int, w: Int, h: Int) {
        let row: Int = VFDMath.floorDiv(index, VFDW.tabCols)
        let col: Int = VFDMath.floorMod(index, VFDW.tabCols)
        let c: Int = tabLeft + col * (tabCellW + 1)
        let r: Int = row <= 0 ? tabRows[0] : tabRows[1]
        return (c: c, r: r, w: tabCellW, h: tabH)
    }

    /// Label for a tab key, or its short form when it does not fit the cell with 2 cells of
    /// padding each side (SETTINGS -> SETUP).
    func tabLabel(_ key: String) -> String {
        var label: String? = nil
        for t in VFDW.tabs where t.key == key {
            label = t.label
            break
        }
        guard let lab = label else { return VFDW.upper(key) }
        if VFDText.width(lab) + 4 > tabCellW, let short = VFDW.tabShort[key] {
            return short
        }
        return lab
    }
}

// MARK: - Widgets

enum VFDW {
    // MARK: constants

    /// The ten tabs in app order: ContentView.MainTab raw values and labels.
    static let tabs: [(key: String, label: String)] = [
        (key: "scan", label: "SCAN"), (key: "tx", label: "TX"), (key: "wand", label: "WAND"),
        (key: "auto", label: "AUTO"), (key: "link", label: "LINK"), (key: "logs", label: "LOGS"),
        (key: "map", label: "MAP"), (key: "diag", label: "DIAG"), (key: "lab", label: "LAB"),
        (key: "settings", label: "SETTINGS"),
    ]
    /// Short forms used when a label does not fit its tab cell.
    static let tabShort: [String: String] = ["settings": "SETUP"]
    static let tabCols: Int = 5

    /// Empty columns at the left and right screen edges.
    static let margin: Int = 3
    /// Height of every control row.
    static let ctrlH: Int = 13
    /// Caps offset inside a control row.
    static let ctrlText: Int = 3
    /// A text field box (ctrlH + 1 so descenders clear the bottom border).
    static let fieldH: Int = 14
    /// Rows between stacked widgets.
    static let gap: Int = 2
    /// Small text line pitch.
    static let line: Int = 11
    /// A small label line above a control.
    static let labelH: Int = 10
    /// Extra rows above a widget that starts with a label line.
    static let groupGap: Int = 3
    /// Rows of air above a section header.
    static let sectionGap: Int = 8
    static let sectionH: Int = 11
    /// Minimum tap height in rows.
    static let tapRows: Int = 15
    /// [-] / [+] step button: stepW x ctrlH cells.
    static let stepW: Int = 13
    /// Columns between [OPTION] items.
    static let optGap: Int = 4
    /// One tab-bar row.
    static let tabH: Int = 13
    /// ON/OFF switch width.
    static let switchW: Int = 45
    /// Small text advance.
    static let adv: Int = 6
    static let nPatterns: Int = 5

    /// TxIntervalSlider: 61 stops over 0.5 ... 30 s.
    static let loopMin: Double = 0.5
    static let loopMax: Double = 30.0
    static let loopLastStop: Int = 60

    // MARK: helpers

    /// Display uppercase (widgets._upper): per character, keeping characters whose uppercase is not
    /// a single character, and µ as µ.
    static func upper(_ s: String?) -> String {
        guard let s = s else { return "" }
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            let v: UInt32 = u.value
            if v < 0x80 {
                if v >= 0x61 && v <= 0x7A {
                    out.append(Unicode.Scalar(UInt8(v - 32)))
                } else {
                    out.append(u)
                }
                continue
            }
            if v == 0xB5 {
                out.append(u)
                continue
            }
            let up: [Unicode.Scalar] = Array(String(Character(u)).uppercased().unicodeScalars)
            if up.count == 1 {
                out.append(up[0])
            } else {
                out.append(u)
            }
        }
        return String(out)
    }

    /// Row where a labelled widget starts: groupGap rows lower unless it opens the content.
    static func groupTop(_ L: VFDLayout, _ r: Int) -> Int {
        return r > L.contentTop ? r + VFDW.groupGap : r
    }

    /// Column that centres s (ink) in [c, c + w).
    static func cx(_ c: Int, _ w: Int, _ s: String, _ size: VFDSize = .small) -> Int {
        return c + VFDMath.floorDiv(w - VFDText.width(s, size: size), 2)
    }

    /// Indices of the items whose text or upper() is in names (for options' `selected`).
    static func selection(_ items: [String], names: Set<String>) -> Set<Int> {
        var out = Set<Int>()
        var i: Int = 0
        for item in items {
            if names.contains(item) || names.contains(upper(item)) {
                out.insert(i)
            }
            i += 1
        }
        return out
    }

    private static func nonEmpty(_ s: String?) -> String? {
        if let v = s, !v.isEmpty { return v }
        return nil
    }

    /// Python `name or fallback`.
    private static func orDefault(_ name: String?, _ fallback: String) -> String {
        return nonEmpty(name) ?? fallback
    }

    /// "%03d".
    private static func pad3(_ n: Int) -> String {
        var s: String = String(n.magnitude)
        let width: Int = n < 0 ? 2 : 3
        while s.count < width {
            s = "0" + s
        }
        return n < 0 ? "-" + s : s
    }

    /// A tap rectangle at least minH rows tall, grown evenly above and below the visual; when the
    /// padding would reach past the current clip (a control at the top or bottom of the content)
    /// it is moved inside the clip instead of being cut (widgets._tap). No tap without a name.
    static func tap(_ fb: VFDFrameBuffer, _ c: Int, _ r: Int, _ w: Int, _ h: Int, _ name: String?,
                    minH: Int = VFDW.tapRows, action: (() -> Void)? = nil, long: (() -> Void)? = nil,
                    swipeLeft: (() -> Void)? = nil, swipeRight: (() -> Void)? = nil,
                    drag: ((Double, Bool) -> Void)? = nil) {
        guard let tapName = nonEmpty(name) else { return }
        var top: Int = r
        var height: Int = h
        if height < minH {
            let visTop: Int = r
            let visBot: Int = r + h
            top -= VFDMath.floorDiv(minH - h, 2)
            height = minH
            let oy: Int = fb.originY
            let clip = fb.clipRect
            let r0: Int = clip.r
            let ch: Int = clip.h
            let r1: Int = r0 + ch
            if r0 <= visTop + oy && visBot + oy <= r1 && height <= ch {
                if top + oy < r0 {
                    top = r0 - oy
                } else if top + height + oy > r1 {
                    top = r1 - oy - height
                }
            }
        }
        fb.tap(c, top, w, height, name: tapName, action: action, long: long, swipeLeft: swipeLeft,
               swipeRight: swipeRight, drag: drag)
    }

    // MARK: inline pieces

    /// Inverted text: a solid block 2 cells around the caps with the text cut out. Returns the
    /// column after the block.
    @discardableResult
    static func badge(_ fb: VFDFrameBuffer, _ c: Int, _ r: Int, _ s: String,
                      _ color: UInt8 = VFDInk.highlight) -> Int {
        let tw: Int = VFDText.width(s)
        if tw == 0 { return c }
        fb.fill(c - 2, r - 2, tw + 4, 11, color)
        fb.text(c, r, s, .small, VFDInk.unlit)
        return c + tw + 2
    }

    /// Alarm text (ALARM ink); on a red-ish base an inverted highlight block (10 rows, nudged 2
    /// cells inward). right = true: c is the inclusive last column. Returns the column after it.
    @discardableResult
    static func alarmText(_ fb: VFDFrameBuffer, _ c: Int, _ r: Int, _ s: String, right: Bool = false) -> Int {
        let tw: Int = VFDText.width(s)
        if tw == 0 { return c }
        var c0: Int = c
        if right {
            c0 = c - tw + 1 - (fb.alarmInverted ? 2 : 0)
        }
        if fb.alarmInverted {
            let x: Int = c0 + (right ? 0 : 2)
            fb.fill(x - 2, r - 1, tw + 4, 10, VFDInk.highlight)
            fb.text(x, r, s, .small, VFDInk.unlit)
            return x + tw + 2
        }
        return fb.text(c0, r, s, .small, VFDInk.alarm) - 1
    }

    /// A boxed tag (BAND, NEW): a 1-cell box 2 cells around the caps, the text in text colour.
    @discardableResult
    static func tagBox(_ fb: VFDFrameBuffer, _ c: Int, _ r: Int, _ s: String, color: UInt8 = VFDInk.dim,
                       textColor: UInt8 = VFDInk.text) -> Int {
        let su: String = upper(s)
        let tw: Int = VFDText.width(su)
        if tw == 0 { return c }
        fb.box(c - 2, r - 2, tw + 4, 11, color)
        fb.text(c, r, su, .small, textColor)
        return c + tw + 2
    }

    /// Section chevron next to small caps at row r: right-pointing 4 x 7 when collapsed, down-
    /// pointing 7 x 4 when open.
    static func chevron(_ fb: VFDFrameBuffer, _ c: Int, _ r: Int, _ collapsed: Bool, _ color: UInt8 = VFDInk.dim) {
        for i in 0..<4 {
            if collapsed {
                fb.vline(c + 1 + i, r + i, 7 - 2 * i, color)
            } else {
                fb.hline(c + i, r + 1 + i, 7 - 2 * i, color)
            }
        }
    }

    /// 7 x 4 up-pointing chevron (the "HIDE ..." headers of open panels).
    static func chevronUp(_ fb: VFDFrameBuffer, _ c: Int, _ r: Int, _ color: UInt8 = VFDInk.dim) {
        for i in 0..<4 {
            fb.hline(c + 3 - i, r + 1 + i, 1 + 2 * i, color)
        }
    }

    /// A 13 x 13 [-] or [+] button at (c, r): highlight border (dim when disabled), the icon in
    /// text colour. Registers the tap when enabled and named.
    static func stepButton(_ fb: VFDFrameBuffer, _ c: Int, _ r: Int, _ plus: Bool, _ enabled: Bool = true,
                           _ name: String? = nil, action: (() -> Void)? = nil) {
        let border: UInt8 = enabled ? VFDInk.highlight : VFDInk.dim
        let icon: UInt8 = enabled ? VFDInk.text : VFDInk.dim
        fb.box(c, r, VFDW.stepW, VFDW.ctrlH, border)
        let midC: Int = c + VFDW.stepW / 2
        let midR: Int = r + VFDW.ctrlH / 2
        fb.hline(midC - 2, midR, 5, icon)
        if plus {
            fb.vline(midC, midR - 2, 5, icon)
        }
        if enabled {
            tap(fb, c - 1, r, VFDW.stepW + 2, VFDW.ctrlH, name, action: action)
        }
    }

    // MARK: chrome

    /// A tab constant ("SCAN", "scan", "Settings", "SETUP") to its key, or nil.
    static func tabKey(_ tab: String) -> String? {
        let t: String = VFDText.strip(tab).lowercased()
        for entry in VFDW.tabs {
            if t == entry.key || t == entry.label.lowercased() {
                return entry.key
            }
        }
        for (key, short) in VFDW.tabShort {
            if t == short.lowercased() {
                return key
            }
        }
        return nil
    }

    /// The ten tabs with the labels that fit this layout (SETTINGS -> SETUP).
    static func defaultTabs(_ L: VFDLayout) -> [(key: String, label: String)] {
        var out: [(key: String, label: String)] = []
        for t in VFDW.tabs {
            out.append((key: t.key, label: L.tabLabel(t.key)))
        }
        return out
    }

    /// Header band: optional "< BACK", the mid title (truncated), an optional right-aligned short
    /// status in rightColor (ALARM via alarmText). rightTap (or onRight) makes the right text a
    /// text button; a DIM right text is a disabled one. Returns L.telemetryRow.
    @discardableResult
    static func header(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ title: String, back: Bool = false,
                       right: String? = nil, rightColor: UInt8 = VFDInk.highlight, rightTap: String? = nil,
                       onBack: (() -> Void)? = nil, onRight: (() -> Void)? = nil) -> Int {
        var x: Int = L.left
        let smallR: Int = L.headerTextRow
        if back {
            let end: Int = fb.text(x, smallR, "< BACK", .small, VFDInk.highlight)
            tap(fb, 0, L.headerTop - 1, end + 3, 16, "back", action: onBack)
            x = end + 6
        }
        var limit: Int = L.right
        if let rawRight = nonEmpty(right) {
            let text: String = VFDText.fit(upper(rawRight), VFDMath.floorDiv(L.width, 2))
            var start: Int = L.right - VFDText.width(text) + 1
            if rightColor == VFDInk.alarm {
                start = L.right - VFDText.width(text) + 1 - (fb.alarmInverted ? 2 : 0)
                alarmText(fb, L.right, smallR, text, right: true)
            } else {
                fb.text(start, smallR, text, .small, rightColor)
            }
            var tapName: String? = nonEmpty(rightTap)
            if tapName == nil && onRight != nil {
                tapName = "right"
            }
            if let tn = tapName, rightColor != VFDInk.dim {
                fb.tap(start - 3, L.headerTop - 1, fb.cols - start + 3, 16, name: tn, action: onRight)
            }
            limit = start - 8
        }
        fb.textFit(x, L.titleRow, upper(title), limit - x + 1, .mid, VFDInk.highlight)
        return L.telemetryRow
    }

    /// The TelemetryBar line: small dim text, " | " drawn as a 1-cell bar, truncated with … at
    /// the right margin; then the dim header rule. Returns L.contentTop.
    @discardableResult
    static func telemetry(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ text: String) -> Int {
        let r: Int = L.telemetryRow
        let sep: [Unicode.Scalar] = [" ", "|", " "]
        var tokens: [[Unicode.Scalar]] = []
        for t in VFDText.split(VFDText.scalars(upper(text)), sep) where !t.isEmpty {
            tokens.append(t)
        }
        var x: Int = L.left
        let limit: Int = L.right + 1
        let ellW: Int = VFDText.width(VFDText.ellipsis)
        var i: Int = 0
        for tokScalars in tokens {
            let tok: String = VFDText.string(tokScalars)
            if i > 0 {
                let bar: Int = x + 3
                let nxt: Int = bar + 5
                let headCount: Int = tokScalars.isEmpty ? 1 : 2
                if nxt + VFDText.width(count: headCount) > limit {
                    if x + ellW <= limit {
                        fb.text(x, r, VFDText.ellipsis, .small, VFDInk.dim)
                    }
                    break
                }
                fb.vline(bar, r - 1, 9, VFDInk.dim)
                x = nxt
            }
            if x + VFDText.width(tok) <= limit {
                x = fb.text(x, r, tok, .small, VFDInk.dim)
            } else {
                fb.textFit(x, r, tok, limit - x, .small, VFDInk.dim)
                break
            }
            i += 1
        }
        fb.hline(L.left, L.headerRule, L.width, VFDInk.dim)
        return L.contentTop
    }

    /// Pixel tab bar: a dim rule, two rows of five equal cells, labels centred, the selected tab
    /// a solid highlight block with its label cut out, the others dim, dim separators. Each cell is
    /// a tap "tab:<key>". tabs = the (key, label) pairs to show (default defaultTabs(L)).
    static func tabBar(_ fb: VFDFrameBuffer, _ L: VFDLayout, selected: String,
                       tabs: [(key: String, label: String)]? = nil, onSelect: ((String) -> Void)? = nil) {
        let list: [(key: String, label: String)] = tabs ?? defaultTabs(L)
        let sel: String = tabKey(selected) ?? VFDText.strip(selected).lowercased()
        fb.hline(L.left, L.tabRule, L.width, VFDInk.dim)
        let n: Int = min(list.count, 2 * VFDW.tabCols)
        for i in 0..<n {
            let key: String = list[i].key
            let lab: String = list[i].label
            let cell = L.tabCell(i)
            let tx: Int = cx(cell.c, cell.w, lab)
            if key == sel || key.lowercased() == sel {
                fb.fill(cell.c + 1, cell.r, cell.w - 2, cell.h, VFDInk.highlight)
                fb.text(tx, cell.r + VFDW.ctrlText, lab, .small, VFDInk.unlit)
            } else {
                fb.text(tx, cell.r + VFDW.ctrlText, lab, .small, VFDInk.dim)
            }
            if i % VFDW.tabCols != VFDW.tabCols - 1 {
                fb.vline(cell.c + cell.w, cell.r + 2, cell.h - 4, VFDInk.dim)
            }
            var act: (() -> Void)? = nil
            if let f = onSelect {
                act = { f(key) }
            }
            if i < VFDW.tabCols {
                fb.tap(cell.c, cell.r - 2, cell.w + 1, cell.h + 3, name: "tab:" + key, action: act)
            } else {
                fb.tap(cell.c, cell.r, cell.w + 1, cell.h + 2, name: "tab:" + key, action: act)
            }
        }
    }

    /// Whole fixed chrome for one tab (header, telemetry line + rule, tab bar), drawn inside the
    /// drawable rows. Leaves the content clip pushed (0, contentTop, cols, contentH) with
    /// dy = -scroll; call endFrame(fb) when the content is done.
    static func frame(_ fb: VFDFrameBuffer, _ L: VFDLayout, tab: String, title: String,
                      telemetry telemetryText: String, back: Bool = false, right: String? = nil,
                      rightColor: UInt8 = VFDInk.highlight, scroll: Int = 0, rightTap: String? = nil,
                      tabs: [(key: String, label: String)]? = nil, onBack: (() -> Void)? = nil,
                      onRight: (() -> Void)? = nil, onTab: ((String) -> Void)? = nil) {
        fb.pushClip(0, L.safeTop, fb.cols, L.safeEnd - L.safeTop)
        header(fb, L, title, back: back, right: right, rightColor: rightColor, rightTap: rightTap,
               onBack: onBack, onRight: onRight)
        telemetry(fb, L, telemetryText)
        tabBar(fb, L, selected: tab, tabs: tabs, onSelect: onTab)
        fb.popClip()
        fb.pushClip(0, L.contentTop, fb.cols, L.contentH, dy: -scroll)
    }

    /// Pop the content clip frame() left set.
    static func endFrame(_ fb: VFDFrameBuffer) {
        fb.popClip()
    }

    /// Scroll indicator in the last screen column, only when the content (ending at row
    /// contentEnd, exclusive, content coordinates) is taller than the region. Draw it after
    /// endFrame().
    static func scrollbar(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ contentEnd: Int, scroll: Int = 0) {
        let total: Int = contentEnd - L.contentTop
        let view: Int = L.contentH
        if total <= view { return }
        let col: Int = fb.cols - 1
        let top: Int = L.contentTop
        let h: Int = L.contentH
        fb.vline(col, top, h, VFDInk.dim, step: 2)
        let th: Int = max(6, VFDMath.floorDiv(h * view, total))
        let pos: Int = max(0, min(scroll, total - view))
        let ty: Int = top + VFDMath.floorDiv((h - th) * pos, max(1, total - view))
        fb.vline(col, ty, th, VFDInk.dim)
    }

    // MARK: content widgets

    /// Section header: [chevron] TITLE in small highlight, an optional right-aligned count (3
    /// digits) or right text in dim, a dim rule. collapsed != nil draws a chevron and makes the line
    /// a tap "section:<TITLE>". sectionGap rows of air above (not at the content top).
    @discardableResult
    static func section(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int, _ title: String,
                        count: Int? = nil, collapsed: Bool? = nil, right: String? = nil, name: String? = nil,
                        action: (() -> Void)? = nil) -> Int {
        var y: Int = r
        if y > L.contentTop {
            y += VFDW.sectionGap - VFDW.gap
        }
        var x: Int = c
        if let folded = collapsed {
            chevron(fb, x, y, folded, VFDInk.dim)
            x += 11
        }
        var rt: String? = nil
        if let n = count {
            rt = pad3(n)
        } else if let rr = nonEmpty(right) {
            rt = upper(rr)
        }
        var limit: Int = c + w
        if let t0 = nonEmpty(rt) {
            let t: String = VFDText.fit(t0, VFDMath.floorDiv(w, 2))
            let start: Int = c + w - VFDText.width(t)
            fb.text(start, y, t, .small, VFDInk.dim)
            limit = start - 6
        }
        fb.textFit(x, y, upper(title), limit - x, .small, VFDInk.highlight)
        fb.hline(c, y + 9, w, VFDInk.dim)
        if collapsed != nil {
            tap(fb, c, y - 3, w, 14, orDefault(name, "section:" + upper(title)), action: action)
        }
        return y + VFDW.sectionH + VFDW.gap
    }

    /// One small label line (uppercased, truncated) above a control; group adds groupGap first.
    /// Returns the row for the control.
    @discardableResult
    static func label(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int, _ s: String,
                      color: UInt8 = VFDInk.dim, group: Bool = true) -> Int {
        let y: Int = group ? groupTop(L, r) : r
        fb.textFit(c, y, upper(s), w, .small, color)
        return y + VFDW.labelH
    }

    /// Word-wrapped small text ("\n" breaks lines), as given unless upper. Returns the next row.
    @discardableResult
    static func textBlock(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int, _ s: String,
                          color: UInt8 = VFDInk.text, upper doUpper: Bool = false) -> Int {
        let shown: String = doUpper ? upper(s) : s
        let nxt: Int = fb.paragraph(c, r, shown, w, .small, color, line: VFDW.line)
        return nxt > r ? nxt + VFDW.gap : r
    }

    /// StatusLine: one truncated uppercase line (ALARM via alarmText); banner = a full-width solid
    /// block with the text cut out. A tap when named (or given an action).
    @discardableResult
    static func statusLine(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int, _ s: String,
                           color: UInt8 = VFDInk.dim, banner: Bool = false, name: String? = nil,
                           action: (() -> Void)? = nil) -> Int {
        let su: String = upper(s)
        var tapName: String? = nonEmpty(name)
        if tapName == nil && action != nil {
            tapName = "status:" + su
        }
        if banner {
            let bc: UInt8 = (color == VFDInk.dim || color == VFDInk.text) ? VFDInk.highlight : color
            fb.fill(c, r, w, 11, bc)
            fb.textFit(c + 3, r + 2, su, w - 6, .small, VFDInk.unlit)
            if tapName != nil {
                tap(fb, c, r, w, 11, tapName, action: action)
            }
            return r + 11 + VFDW.gap
        }
        if color == VFDInk.alarm {
            alarmText(fb, c, r, VFDText.fit(su, w - 4))
        } else {
            fb.textFit(c, r, su, w, .small, color)
        }
        if tapName != nil {
            tap(fb, c, r - 2, w, 11, tapName, action: action)
        }
        return r + VFDW.line
    }

    /// Key / value line: dim key, right-aligned value (ALARM via alarmText), a dotted leader
    /// between them. Returns r + line.
    @discardableResult
    static func kv(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int, _ key: String,
                   _ value: String?, color: UInt8 = VFDInk.highlight, leader: Bool = true) -> Int {
        let k: String = upper(key)
        let kw: Int = VFDText.width(k)
        let v: String = VFDText.fit(value ?? "", max(0, w - kw - 6))
        let vw: Int = VFDText.width(v)
        fb.textFit(c, r, k, w, .small, VFDInk.dim)
        if !v.isEmpty {
            var start: Int = c + w - vw
            if color == VFDInk.alarm {
                start = c + w - vw - (fb.alarmInverted ? 2 : 0)
                alarmText(fb, c + w - 1, r, v, right: true)
            } else {
                fb.text(start, r, v, .small, color)
            }
            if leader {
                var a: Int = c + kw + 3
                let b: Int = start - 3
                a += VFDMath.floorMod(a - c, 2)
                if b > a {
                    fb.hline(a, r + 6, b - a, VFDInk.dim, step: 2)
                }
            }
        }
        return r + VFDW.line
    }

    /// Big readout: a dim label line, the value in big (or mid), optional small dim sub-text after
    /// it on its baseline. Returns the next row.
    @discardableResult
    static func hero(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int, _ key: String,
                     _ value: String, size: VFDSize = .big, color: UInt8 = VFDInk.highlight,
                     sub: String? = nil) -> Int {
        let y: Int = groupTop(L, r)
        fb.textFit(c, y, upper(key), w, .small, VFDInk.dim)
        let vr: Int = y + VFDW.labelH + 1
        let end: Int = fb.textFit(c, vr, value, w, size, color)
        if let sb = nonEmpty(sub) {
            let sx: Int = end + 4
            if sx < c + w {
                fb.textFit(sx, vr + size.ascent - 7, upper(sb), c + w - sx, .small, VFDInk.dim)
            }
        }
        return vr + size.ascent + 3 + VFDW.gap
    }

    /// A 1-row divider (dotted by default). Returns r + 1 + gap.
    @discardableResult
    static func divider(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int,
                        dotted: Bool = true, color: UInt8 = VFDInk.dim) -> Int {
        fb.hline(c, r, w, color, step: dotted ? 2 : 1)
        return r + 1 + VFDW.gap
    }

    /// (c, r, w) of the content area inside panel(c, r, w, ..., title).
    static func panelInner(_ c: Int, _ r: Int, _ w: Int, title: Bool = true) -> (c: Int, r: Int, w: Int) {
        return (c: c + 4, r: r + (title ? 10 : 4), w: w - 8)
    }

    /// A 1-cell border box w x h; with a title, the title (small highlight) is set into the top
    /// border, which then runs at r + 3. Returns r + h + gap.
    @discardableResult
    static func panel(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int, _ h: Int,
                      title: String? = nil, color: UInt8 = VFDInk.dim) -> Int {
        if let t0 = nonEmpty(title) {
            let top: Int = r + 3
            fb.box(c, top, w, h - 3, color)
            let t: String = VFDText.fit(upper(t0), w - 14)
            fb.fill(c + 3, top, VFDText.width(t) + 6, 1, VFDInk.unlit)
            fb.text(c + 6, r, t, .small, VFDInk.highlight)
        } else {
            fb.box(c, r, w, h, color)
        }
        return r + h + VFDW.gap
    }

    /// Label on the left, a pixel ON/OFF switch right-aligned (switchW cells). Tap
    /// "toggle:<LABEL>" across the whole row when enabled.
    @discardableResult
    static func toggle(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int, _ labelText: String,
                       _ on: Bool, enabled: Bool = true, name: String? = nil, labelColor: UInt8 = VFDInk.text,
                       action: (() -> Void)? = nil) -> Int {
        let seg: Int = VFDMath.floorDiv(VFDW.switchW - 3, 2)
        let sx: Int = c + w - VFDW.switchW
        let lc: UInt8 = enabled ? labelColor : VFDInk.dim
        let ty: Int = r + VFDW.ctrlText
        fb.textFit(c, ty, upper(labelText), sx - c - 6, .small, lc)
        fb.box(sx, r, VFDW.switchW, VFDW.ctrlH, VFDInk.dim)
        fb.vline(sx + 1 + seg, r, VFDW.ctrlH, VFDInk.dim)
        let onX: Int = sx + 1
        let offX: Int = sx + 2 + seg
        if on {
            fb.fill(onX, r + 1, seg, VFDW.ctrlH - 2, enabled ? VFDInk.highlight : VFDInk.dim)
            fb.text(cx(onX, seg, "ON"), ty, "ON", .small, VFDInk.unlit)
            fb.text(cx(offX, seg, "OFF"), ty, "OFF", .small, VFDInk.dim)
        } else {
            fb.text(cx(onX, seg, "ON"), ty, "ON", .small, VFDInk.dim)
            fb.fill(offX, r + 1, seg, VFDW.ctrlH - 2, VFDInk.dim)
            fb.text(cx(offX, seg, "OFF"), ty, "OFF", .small, VFDInk.unlit)
        }
        if enabled {
            tap(fb, c, r, w, VFDW.ctrlH, orDefault(name, "toggle:" + upper(labelText)), action: action)
        }
        return r + VFDW.ctrlH + VFDW.gap
    }

    /// [OPTION] selectors: unselected = dim brackets around the name in text, selected = a solid
    /// highlight block with the name cut out. Optional label line above. Items flow and wrap every
    /// ctrlH + gap rows; columns = n centres each in one of n equal cells. Each item is a tap
    /// "<name or option:LABEL>:<ITEM>" calling onSelect(index).
    @discardableResult
    static func options(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int, _ items: [String],
                        selected: Set<Int>, label labelText: String? = nil, enabled: Bool = true,
                        name: String? = nil, columns: Int? = nil, onSelect: ((Int) -> Void)? = nil) -> Int {
        var top: Int = r
        if let lt = nonEmpty(labelText) {
            top = label(fb, L, c, top, w, lt)
        }
        let base: String = orDefault(name, "option:" + upper(labelText ?? ""))
        var cells: [(c: Int, w: Int)] = []
        var ncols: Int = 0
        if let n = columns, n > 0 {
            cells = L.split(n, gap: VFDW.optGap, c: c, w: w)
            ncols = n
        }
        var x: Int = c
        var y: Int = top
        var i: Int = 0
        for raw in items {
            let item: String = upper(raw)
            var ow: Int = 0
            if ncols > 0 {
                let col: Int = i % ncols
                if col == 0 && i > 0 {
                    y += VFDW.ctrlH + VFDW.gap
                }
                x = cells[col].c
                ow = cells[col].w
            } else {
                ow = VFDText.width("[" + item + "]")
                if x > c && x + ow > c + w {
                    x = c
                    y += VFDW.ctrlH + VFDW.gap
                }
                ow = min(ow, c + w - x)
            }
            let shown: String = VFDText.fit(item, ow - 2 * VFDW.adv)
            let fw: Int = VFDText.width("[" + shown + "]")
            let fx: Int = ncols > 0 ? x + VFDMath.floorDiv(ow - fw, 2) : x
            let ty: Int = y + VFDW.ctrlText
            if selected.contains(i) {
                fb.fill(fx, y + 1, fw, VFDW.ctrlH - 2, enabled ? VFDInk.highlight : VFDInk.dim)
                fb.text(fx + VFDW.adv, ty, shown, .small, VFDInk.unlit)
            } else {
                fb.text(fx, ty, "[", .small, VFDInk.dim)
                fb.text(fx + VFDW.adv, ty, shown, .small, enabled ? VFDInk.text : VFDInk.dim)
                fb.text(fx + fw - 5, ty, "]", .small, VFDInk.dim)
            }
            if enabled {
                var act: (() -> Void)? = nil
                if let f = onSelect {
                    let index: Int = i
                    act = { f(index) }
                }
                tap(fb, x - VFDMath.floorDiv(VFDW.optGap, 2), y, ow + VFDW.optGap, VFDW.ctrlH,
                    base + ":" + item, action: act)
            }
            x += ow + VFDW.optGap
            i += 1
        }
        return y + VFDW.ctrlH + VFDW.gap
    }

    /// options() with one selected index (or none).
    @discardableResult
    static func options(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int, _ items: [String],
                        selected: Int?, label labelText: String? = nil, enabled: Bool = true,
                        name: String? = nil, columns: Int? = nil, onSelect: ((Int) -> Void)? = nil) -> Int {
        var set = Set<Int>()
        if let s = selected {
            set.insert(s)
        }
        return options(fb, L, c, r, w, items, selected: set, label: labelText, enabled: enabled, name: name,
                       columns: columns, onSelect: onSelect)
    }

    /// Label on the left; right-aligned [-] value [+] (value in small highlight, centred in a field
    /// valueChars wide, default its length). Taps "<name or stepper:LABEL>:-" / ":+".
    @discardableResult
    static func stepper(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int, _ labelText: String,
                        _ value: String, enabled: Bool = true, canDec: Bool = true, canInc: Bool = true,
                        valueChars: Int? = nil, name: String? = nil, onDec: (() -> Void)? = nil,
                        onInc: (() -> Void)? = nil) -> Int {
        let n: Int = max(VFDText.length(value), valueChars ?? 0)
        let vw: Int = n * VFDW.adv - 1 + 6
        let gx: Int = c + w - (VFDW.stepW + vw + VFDW.stepW)
        let base: String = orDefault(name, "stepper:" + upper(labelText))
        let ty: Int = r + VFDW.ctrlText
        fb.textFit(c, ty, upper(labelText), gx - c - 6, .small, enabled ? VFDInk.text : VFDInk.dim)
        stepButton(fb, gx, r, false, enabled && canDec, base + ":-", action: onDec)
        fb.text(cx(gx + VFDW.stepW, vw, value), ty, value, .small, enabled ? VFDInk.highlight : VFDInk.dim)
        stepButton(fb, gx + VFDW.stepW + vw, r, true, enabled && canInc, base + ":+", action: onInc)
        return r + VFDW.ctrlH + VFDW.gap
    }

    /// A button w cells wide (nil = label + 6 cells each side), ctrlH tall: highlight border with
    /// the label in text, primary = a solid highlight block with the label cut out, disabled = dim,
    /// alarm = a destructive action (ALARM border and label, or an inverted block on a red-ish
    /// base). Tap "button:<LABEL>" when enabled.
    @discardableResult
    static func button(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int?, _ labelText: String,
                       primary: Bool = false, enabled: Bool = true, name: String? = nil, alarm: Bool = false,
                       action: (() -> Void)? = nil, long: (() -> Void)? = nil) -> Int {
        var s: String = upper(labelText)
        let bw: Int = w ?? (VFDText.width(s) + 12)
        s = VFDText.fit(s, bw - 4)
        let tx: Int = cx(c, bw, s)
        let ty: Int = r + VFDW.ctrlText
        if alarm && enabled {
            if fb.alarmInverted {
                fb.fill(c, r, bw, VFDW.ctrlH, VFDInk.highlight)
                fb.text(tx, ty, s, .small, VFDInk.unlit)
            } else {
                fb.box(c, r, bw, VFDW.ctrlH, VFDInk.alarm)
                fb.text(tx, ty, s, .small, VFDInk.alarm)
            }
        } else if primary && enabled {
            fb.fill(c, r, bw, VFDW.ctrlH, VFDInk.highlight)
            fb.text(tx, ty, s, .small, VFDInk.unlit)
        } else {
            fb.box(c, r, bw, VFDW.ctrlH, enabled ? VFDInk.highlight : VFDInk.dim)
            fb.text(tx, ty, s, .small, enabled ? VFDInk.text : VFDInk.dim)
        }
        if enabled {
            tap(fb, c, r, bw, VFDW.ctrlH, orDefault(name, "button:" + s), action: action, long: long)
        }
        return r + VFDW.ctrlH + VFDW.gap
    }

    /// A row of buttons: equal cells, or (equal = false) sized to their labels, gap cells apart.
    /// primary / alarm: the index of the primary / destructive button; enabled: per button (nil or
    /// empty = all). onSelect(index) on a tap.
    @discardableResult
    static func buttons(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int, _ labels: [String],
                        primary: Int? = nil, enabled: [Bool]? = nil, gap: Int = 4, equal: Bool = true,
                        alarm: Int? = nil, onSelect: ((Int) -> Void)? = nil) -> Int {
        let n: Int = labels.count
        if n == 0 { return r }
        var en: [Bool] = [Bool](repeating: true, count: n)
        if let e = enabled, !e.isEmpty {
            en = e
        }
        var spots: [(c: Int, w: Int)] = []
        if equal {
            spots = L.split(n, gap: gap, c: c, w: w)
        } else {
            var x: Int = c
            for s in labels {
                let bw: Int = VFDText.width(upper(s)) + 12
                spots.append((c: x, w: bw))
                x += bw + gap
            }
        }
        for i in 0..<n {
            let spot = spots[i]
            let isEnabled: Bool = i < en.count ? en[i] : true
            var act: (() -> Void)? = nil
            if let f = onSelect {
                let index: Int = i
                act = { f(index) }
            }
            button(fb, L, spot.c, r, spot.w, labels[i], primary: primary == i, enabled: isEnabled,
                   alarm: alarm == i, action: act)
        }
        return r + VFDW.ctrlH + VFDW.gap
    }

    /// SettingSlider: title (uppercased, unit in it) with the value right-aligned on the label
    /// row, then [-] LED bar [+], then an optional dim wrapped hint. canDec / canInc default to
    /// frac > 0 / frac < 1. Taps "<name or slider:TITLE>:-", ":+", ":bar"; the bar's drag calls
    /// onSet(fraction of the bar 0...1).
    @discardableResult
    static func slider(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int, _ title: String,
                       _ valueText: String, _ frac: Double, hint: String? = nil, enabled: Bool = true,
                       zone: (Double, Double)? = nil, marker: Bool = false, name: String? = nil,
                       canDec: Bool? = nil, canInc: Bool? = nil, onDec: (() -> Void)? = nil,
                       onInc: (() -> Void)? = nil, onSet: ((Double) -> Void)? = nil) -> Int {
        let dec: Bool = canDec ?? (frac > 0)
        let inc: Bool = canInc ?? (frac < 1)
        let top: Int = groupTop(L, r)
        let t: String = upper(title)
        let vw: Int = VFDText.width(valueText)
        fb.text(c + w - vw, top, valueText, .small, enabled ? VFDInk.highlight : VFDInk.dim)
        fb.textFit(c, top, t, w - vw - 6, .small, enabled ? VFDInk.text : VFDInk.dim)
        var y: Int = top + VFDW.labelH
        let base: String = orDefault(name, "slider:" + t)
        stepButton(fb, c, y, false, enabled && dec, base + ":-", action: onDec)
        stepButton(fb, c + w - VFDW.stepW, y, true, enabled && inc, base + ":+", action: onInc)
        let bx: Int = c + VFDW.stepW + 4
        let bw: Int = w - 2 * (VFDW.stepW + 4)
        let barY: Int = y + VFDMath.floorDiv(VFDW.ctrlH - VFDFrameBuffer.ledBarH, 2) + 1
        fb.ledBar(bx, barY, bw, frac, color: enabled ? VFDInk.highlight : VFDInk.dim, marker: marker, zone: zone)
        if enabled {
            var drag: ((Double, Bool) -> Void)? = nil
            if let f = onSet {
                let span: Double = Double(bw + 4)
                let barW: Double = Double(max(1, bw))
                drag = { (fraction: Double, ended: Bool) in
                    let v: Double = (fraction * span - 2.0) / barW
                    f(min(max(v, 0.0), 1.0))
                }
            }
            tap(fb, bx - 2, y, bw + 4, VFDW.ctrlH, base + ":bar", drag: drag)
        }
        y += VFDW.ctrlH + VFDW.gap
        if let h = nonEmpty(hint) {
            y = fb.paragraph(c, y + 1, h, w, .small, VFDInk.dim, line: VFDW.line) + VFDW.gap
        }
        return y
    }

    /// Read-only LED meter: dim title and the value right-aligned (ALARM via alarmText) on the
    /// label row, a full-width LED bar under it.
    @discardableResult
    static func meter(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int, _ title: String,
                      _ valueText: String, _ frac: Double, zone: (Double, Double)? = nil, marker: Bool = false,
                      color: UInt8 = VFDInk.highlight) -> Int {
        let top: Int = groupTop(L, r)
        let t: String = upper(title)
        let vw: Int = VFDText.width(valueText)
        if color == VFDInk.alarm {
            alarmText(fb, c + w - 1, top, valueText, right: true)
        } else {
            fb.text(c + w - vw, top, valueText, .small, color)
        }
        fb.textFit(c, top, t, w - vw - 6, .small, VFDInk.dim)
        fb.ledBar(c, top + VFDW.labelH, w, frac, color: VFDInk.highlight, marker: marker, zone: zone)
        return top + VFDW.labelH + VFDFrameBuffer.ledBarH + VFDW.gap + 1
    }

    /// Boxed text field: optional label line, a fieldH box (highlight when focused) with the value
    /// (as given) or the placeholder (dim, uppercased), truncated; a focused field shows a cursor.
    /// Tap "field:<LABEL>".
    @discardableResult
    static func field(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int, _ labelText: String?,
                      _ value: String, placeholder: String = "", focused: Bool = false, name: String? = nil,
                      valueColor: UInt8 = VFDInk.text, action: (() -> Void)? = nil) -> Int {
        var top: Int = r
        if let lt = nonEmpty(labelText) {
            top = label(fb, L, c, top, w, lt)
        }
        fb.box(c, top, w, VFDW.fieldH, focused ? VFDInk.highlight : VFDInk.dim)
        let ty: Int = top + VFDW.ctrlText
        var x: Int = c + 3
        var inner: Int = w - 7
        if !value.isEmpty {
            let end: Int = fb.textFit(x, ty, value, inner, .small, valueColor)
            if focused {
                fb.vline(min(end, c + w - 3), ty, 7, VFDInk.highlight)
            }
        } else {
            if focused {
                fb.vline(x, ty, 7, VFDInk.highlight)
                x += 3
                inner -= 3
            }
            if !placeholder.isEmpty {
                fb.textFit(x, ty, upper(placeholder), inner, .small, VFDInk.dim)
            }
        }
        tap(fb, c, top, w, VFDW.fieldH, orDefault(name, "field:" + upper(labelText ?? "")), action: action)
        return top + VFDW.fieldH + VFDW.gap
    }

    /// One packet (PacketRow): the label (selected = inverted) with an optional boxed tag and a
    /// right-aligned dim note, the hex truncated (hexColor: HIGHLIGHT live, DIM stored), the dim
    /// subtitle, a dotted divider. The whole row is one tap "packet:<LABEL>". Returns the next
    /// row's r.
    @discardableResult
    static func packetRow(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int, _ labelText: String,
                          _ hexText: String, subtitle: String = "", tag: String? = nil, selected: Bool = false,
                          right: String? = nil, name: String? = nil, hexColor: UInt8 = VFDInk.highlight,
                          action: (() -> Void)? = nil, long: (() -> Void)? = nil,
                          swipeLeft: (() -> Void)? = nil, swipeRight: (() -> Void)? = nil) -> Int {
        var lab: String = upper(labelText)
        var y: Int = r + 3
        var limit: Int = c + w
        if let rt0 = nonEmpty(right) {
            let rt: String = VFDText.fit(upper(rt0), VFDMath.floorDiv(w, 3))
            let start: Int = c + w - VFDText.width(rt)
            fb.text(start, y, rt, .small, VFDInk.dim)
            limit = start - 6
        }
        var x: Int = c + 2
        var tagS: String = ""
        if let t = nonEmpty(tag) {
            tagS = upper(t)
        }
        let tagW: Int = tagS.isEmpty ? 0 : VFDText.width(tagS) + 8
        lab = VFDText.fit(lab, limit - x - 2 - tagW)
        if selected {
            x = badge(fb, x, y, lab, VFDInk.highlight)
        } else {
            x = fb.text(x, y, lab, .small, VFDInk.text) + 1
        }
        if !tagS.isEmpty {
            tagBox(fb, x + 4, y, tagS)
        }
        if !hexText.isEmpty {
            y += VFDW.line
            fb.textFit(c + 2, y, hexText, w - 2, .small, hexColor)
        }
        if !subtitle.isEmpty {
            y += VFDW.line
            fb.textFit(c + 2, y, upper(subtitle), w - 2, .small, VFDInk.dim)
        }
        y += 7 + 3
        fb.hline(c, y, w, VFDInk.dim, step: 2)
        tap(fb, c, r, w, y - r, orDefault(name, "packet:" + upper(labelText)), action: action, long: long,
            swipeLeft: swipeLeft, swipeRight: swipeRight)
        return y + 1
    }

    /// Line chart block: dim title (group gap) and optional right-aligned highlight value on the
    /// label row, then a dim-framed w x h box with the line inside.
    @discardableResult
    static func chart(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int, _ h: Int,
                      _ title: String?, _ values: [Double?], valueText: String? = nil, vmin: Double? = nil,
                      vmax: Double? = nil, color: UInt8 = VFDInk.highlight) -> Int {
        var top: Int = r
        let t: String = title ?? ""
        let vt: String = valueText ?? ""
        if !t.isEmpty || !vt.isEmpty {
            top = groupTop(L, top)
            if !vt.isEmpty {
                fb.textRight(c + w - 1, top, vt, .small, VFDInk.highlight)
            }
            fb.textFit(c, top, upper(t), w - VFDText.width(vt) - 6, .small, VFDInk.dim)
            top += VFDW.labelH
        }
        fb.box(c, top, w, h, VFDInk.dim)
        fb.lineChart(c + 2, top + 2, w - 4, h - 4, values, color: color, vmin: vmin, vmax: vmax)
        return top + h + VFDW.gap
    }

    // MARK: lists under pinned rows

    /// Rows (top, bottom) of the screen window [top, bottom) a scrolling list may use without
    /// cutting a line: draw runs once on a scratch buffer (same origin as fb); a band of lit rows
    /// crossing an edge is left out, and so is a lone lit row (a divider) in the first or last 5
    /// rows (widgets.snapped_window).
    static func snappedWindow(_ fb: VFDFrameBuffer, top: Int, bottom: Int,
                              draw: (VFDFrameBuffer) -> Void) -> (top: Int, bottom: Int) {
        let probe = VFDFrameBuffer(cols: fb.cols, rows: fb.rows)
        probe.pushClip(0, 0, fb.cols, fb.rows, dy: fb.originY)
        draw(probe)
        probe.popClip()
        return snappedWindow(lit: probe, top: top, bottom: bottom)
    }

    /// The window logic of snappedWindow on an already drawn scratch buffer.
    static func snappedWindow(lit probe: VFDFrameBuffer, top: Int, bottom: Int) -> (top: Int, bottom: Int) {
        let cols: Int = probe.cols
        let rows: Int = probe.rows
        let cells: [UInt8] = probe.cells
        func lit(_ r: Int) -> Bool {
            if r < 0 || r >= rows { return false }
            let start: Int = r * cols
            var i: Int = 0
            while i < cols {
                if cells[start + i] != 0 { return true }
                i += 1
            }
            return false
        }
        func lone(_ r: Int) -> Bool {
            return lit(r) && !lit(r - 1) && !lit(r + 1)
        }
        var t: Int = top
        var b: Int = bottom
        if lit(t - 1) && lit(t) {
            while t < b && lit(t) {
                t += 1
            }
        }
        for r in stride(from: t, to: min(t + 5, b), by: 1) {
            if lone(r) {
                t = r + 1
                break
            }
        }
        if lit(b - 1) && lit(b) {
            while b > t && lit(b - 1) {
                b -= 1
            }
        }
        for r in stride(from: b - 1, to: max(b - 6, t - 1), by: -1) {
            if lone(r) {
                b = r
                break
            }
        }
        return (top: t, bottom: b)
    }

    /// A list's scroll indicator in the last screen column over rows top ..< top + h, only when the
    /// list is taller than its window.
    static func listScrollbar(_ fb: VFDFrameBuffer, _ top: Int, _ h: Int, _ total: Int, _ scroll: Int) {
        if total <= h { return }
        let col: Int = fb.cols - 1
        fb.vline(col, top, h, VFDInk.dim, step: 2)
        let th: Int = max(6, VFDMath.floorDiv(h * h, total))
        let pos: Int = max(0, min(scroll, total - h))
        let ty: Int = top + VFDMath.floorDiv((h - th) * pos, max(1, total - h))
        fb.vline(col, ty, th, VFDInk.dim)
    }

    /// Split an "A · B · C" line into lines that break only between tokens; a token too long on its
    /// own is truncated with ….
    static func tokenLines(_ text: String, _ maxCols: Int, sep: String = " · ") -> [String] {
        var lines: [String] = []
        var cur: [Unicode.Scalar] = []
        let sepS: [Unicode.Scalar] = VFDText.scalars(sep)
        for tok in VFDText.split(VFDText.scalars(text), sepS) {
            var cand: [Unicode.Scalar] = tok
            if !cur.isEmpty {
                cand = cur
                cand.append(contentsOf: sepS)
                cand.append(contentsOf: tok)
            }
            if VFDText.width(count: cand.count) <= maxCols {
                cur = cand
                continue
            }
            if !cur.isEmpty {
                lines.append(VFDText.string(cur))
            }
            cur = VFDText.scalars(VFDText.fit(VFDText.string(tok), maxCols))
        }
        if !cur.isEmpty {
            lines.append(VFDText.string(cur))
        }
        return lines
    }

    // MARK: TxIntervalSlider

    /// TxLoopInterval.stop(forSeconds:): the nearest of the 61 stops (halves to even, as Python).
    static func intervalStop(_ seconds: Double) -> Int {
        let pos: Double = (seconds - VFDW.loopMin) / (VFDW.loopMax - VFDW.loopMin) * Double(VFDW.loopLastStop)
        let n: Int = VFDMath.roundHalfEven(pos)
        return min(max(n, 0), VFDW.loopLastStop)
    }

    /// TxLoopInterval.text(_:): one decimal, halves rounding up.
    static func intervalText(_ seconds: Double) -> String {
        let tenths: Int = VFDMath.truncate(abs(seconds) * 10 + 0.5)
        return "\(VFDMath.floorDiv(tenths, 10)).\(VFDMath.floorMod(tenths, 10))"
    }

    /// TxLoopInterval.seconds(forStop:).
    static func intervalSeconds(stop: Int) -> Double {
        let clamped: Int = min(max(stop, 0), VFDW.loopLastStop)
        let f: Double = Double(clamped) / Double(VFDW.loopLastStop)
        return (1 - f) * VFDW.loopMin + f * VFDW.loopMax
    }

    /// TxIntervalSlider: one line of text over a full-width 61-stop slider (dotted track, the lit
    /// part up to the thumb, a 3 x 6 thumb). The tap covers the bar and the label; its drag calls
    /// onSet(seconds of the nearest stop).
    @discardableResult
    static func intervalSlider(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int,
                               _ labelText: String, _ seconds: Double, name: String = "slider:INTERVAL",
                               onSet: ((Double) -> Void)? = nil) -> Int {
        let top: Int = r > L.contentTop ? r + VFDW.groupGap : r
        fb.textFit(c, top, labelText, w, .small, VFDInk.text)
        let y: Int = top + VFDW.labelH
        let frac: Double = Double(intervalStop(seconds)) / Double(VFDW.loopLastStop)
        fb.ledBar(c, y, w, frac, marker: true, zone: (0.0, frac))
        var drag: ((Double, Bool) -> Void)? = nil
        if let f = onSet {
            drag = { (fraction: Double, ended: Bool) in
                let clamped: Double = min(max(fraction, 0.0), 1.0)
                let stop: Int = VFDMath.roundHalfAway(clamped * Double(VFDW.loopLastStop))
                f(VFDW.intervalSeconds(stop: stop))
            }
        }
        fb.tap(c, y - 6, w, VFDW.tapRows, name: name + ":bar", drag: drag)
        return y + VFDFrameBuffer.ledBarH + 3 + VFDW.gap
    }

    /// SectionFilterMenu ("CLASS 8/8 ▾"): a button with a pixel down-chevron after the label. Tap
    /// "<name or menu:LABEL>". Returns the column after it.
    @discardableResult
    static func menuButton(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ x: Int, _ y: Int, _ labelText: String,
                           enabled: Bool = true, name: String? = nil, action: (() -> Void)? = nil) -> Int {
        let lab: String = upper(labelText)
        let w: Int = VFDText.width(lab) + 11 + 12
        fb.box(x, y, w, VFDW.ctrlH, enabled ? VFDInk.highlight : VFDInk.dim)
        let ty: Int = y + VFDW.ctrlText
        let end: Int = fb.text(x + 6, ty, lab, .small, enabled ? VFDInk.text : VFDInk.dim)
        chevron(fb, end + 3, ty + 1, false, enabled ? VFDInk.text : VFDInk.dim)
        if enabled {
            tap(fb, x - 2, y, w + 4, VFDW.ctrlH, orDefault(name, "menu:" + lab), action: action)
        }
        return x + w
    }

    // MARK: band LEDs

    /// A round LED / legend swatch size x size at (x, y). kind: 0 solid, 1 checker, 2 ring with a
    /// centre dot, 3 horizontal stripes, 4 vertical stripes; nil = unlit (a dotted dim ring).
    /// fill: a solid disc in that true colour (fb.rgb) instead of the pattern; kind nil still draws
    /// the unlit ring.
    static func led(_ fb: VFDFrameBuffer, _ x: Int, _ y: Int, _ kind: Int?, size: Int = 7,
                    color: UInt8 = VFDInk.highlight, fill: VFDRGB? = nil) {
        // The colour is allocated even for an empty disc, as widgets.led does.
        var trueColor: UInt8? = nil
        if let rgb = fill, kind != nil {
            trueColor = fb.rgb(rgb)
        }
        if size <= 0 { return }
        let m: Double = Double(size - 1) / 2.0
        let rad: Double = Double(size) / 2.0
        let limit: Double = rad * rad - 0.5
        var grid: [Bool] = [Bool](repeating: false, count: size * size)
        for j in 0..<size {
            for i in 0..<size {
                let di: Double = Double(i) - m
                let dj: Double = Double(j) - m
                if di * di + dj * dj <= limit {
                    grid[j * size + i] = true
                }
            }
        }
        let disc: [Bool] = grid
        func inDisc(_ i: Int, _ j: Int) -> Bool {
            if i < 0 || j < 0 || i >= size || j >= size { return false }
            return disc[j * size + i]
        }
        let mid: Int = size / 2
        for j in 0..<size {
            for i in 0..<size {
                if !inDisc(i, j) { continue }
                let edge: Bool = !inDisc(i + 1, j) || !inDisc(i - 1, j) || !inDisc(i, j + 1) || !inDisc(i, j - 1)
                var on: Bool = false
                var col: UInt8 = color
                if let k0 = kind {
                    if let tc = trueColor {
                        on = true
                        col = tc
                    } else {
                        switch VFDMath.floorMod(k0, VFDW.nPatterns) {
                        case 0:
                            on = true
                        case 1:
                            on = (i + j) % 2 == 0
                        case 2:
                            on = edge || (abs(i - mid) <= 1 && abs(j - mid) <= 1)
                        case 3:
                            on = j % 2 == 0
                        default:
                            on = i % 2 == 0
                        }
                    }
                } else {
                    on = edge && (i + j) % 2 == 0
                    col = VFDInk.dim
                }
                if on {
                    fb.set(x + i, y + j, col)
                }
            }
        }
    }

    // MARK: screen composition (render_previews.content_window / draw_screen)

    /// The content rows (top, bottom) a screen may light at this scroll without a line of text
    /// being cut by the content edges: draw runs once on a scratch buffer with the content
    /// unclipped, then the snappedWindow rules apply to [contentTop, contentBottom).
    static func contentWindow(_ L: VFDLayout, scroll: Int, base: VFDBase, alarmInverted: Bool,
                              draw: (VFDFrameBuffer, VFDLayout) -> Int?) -> (top: Int, bottom: Int) {
        let probe = VFDFrameBuffer(cols: L.cols, rows: L.rows, alarmInverted: alarmInverted)
        probe.base = base
        probe.pushClip(0, 0, probe.cols, probe.rows, dy: -scroll)
        let depth: Int = probe.clipDepth
        _ = draw(probe, L)
        while probe.clipDepth >= depth && probe.clipDepth > 0 {
            probe.popClip()
        }
        return snappedWindow(lit: probe, top: L.contentTop, bottom: L.contentBottom)
    }

    /// Drop the taps from index `start` that a window edge cut to a sliver (shorter than tapRows,
    /// touching a window edge that is not the content edge).
    static func dropHiddenTaps(_ fb: VFDFrameBuffer, from start: Int, window: (top: Int, bottom: Int),
                               _ L: VFDLayout) {
        if start < 0 || start >= fb.taps.count { return }
        var kept: [VFDHit] = Array(fb.taps[0..<start])
        for tp in fb.taps[start...] {
            let tall: Bool = tp.h >= VFDW.tapRows
            let atWindowEdge: Bool = tp.r == window.top || tp.r + tp.h == window.bottom
            let atContentEdge: Bool = tp.r == L.contentTop || tp.r + tp.h == L.contentBottom
            if tall || !atWindowEdge || atContentEdge {
                kept.append(tp)
            }
        }
        fb.taps = kept
    }

    /// One whole screen, two-pass like render_previews.draw_screen: the content window is snapped
    /// on a scratch pass, then the chrome (frame), the content clipped to that window, hidden
    /// partial taps dropped and the scrollbar. draw lays the content out from L.contentTop in
    /// content coordinates and returns its end row (or nil); it runs twice, so it must be pure.
    /// fb should be freshly cleared. Returns draw's end row.
    @discardableResult
    static func drawScreen(_ fb: VFDFrameBuffer, _ L: VFDLayout, tab: String, title: String, telemetry: String,
                           back: Bool = false, right: String? = nil, rightColor: UInt8 = VFDInk.highlight,
                           rightTap: String? = nil, scroll: Int = 0, tabs: [(key: String, label: String)]? = nil,
                           onBack: (() -> Void)? = nil, onRight: (() -> Void)? = nil,
                           onTab: ((String) -> Void)? = nil,
                           draw: (VFDFrameBuffer, VFDLayout) -> Int?) -> Int? {
        let win = contentWindow(L, scroll: scroll, base: fb.base, alarmInverted: fb.alarmInverted, draw: draw)
        frame(fb, L, tab: tab, title: title, telemetry: telemetry, back: back, right: right,
              rightColor: rightColor, scroll: scroll, rightTap: rightTap, tabs: tabs, onBack: onBack,
              onRight: onRight, onTab: onTab)
        fb.popClip()
        fb.pushClip(0, win.top, fb.cols, win.bottom - win.top, dy: -scroll)
        let depth: Int = fb.clipDepth
        let nTaps: Int = fb.taps.count
        let end: Int? = draw(fb, L)
        while fb.clipDepth >= depth && fb.clipDepth > 0 {
            fb.popClip()
        }
        dropHiddenTaps(fb, from: nTaps, window: win, L)
        if let e = end {
            scrollbar(fb, L, e, scroll: scroll)
        }
        return end
    }
}
