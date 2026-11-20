package com.magicmaker.android.ui.vfd

// VFD app chrome and content widgets on a VFDFrameBuffer, in whole cells.
// Port of tools/vfd/widgets.py (via ios/MagicMaker/VFD/VFDWidgets.swift, same names: same
// geometry, return values, tap names and tap padding) plus the two-pass screen composition of
// tools/vfd/render_previews.py (contentWindow / drawScreen).
// Kotlin stdlib only (no android.*): it also runs in plain JVM unit tests.
//
// Content widgets take (fb, L, c, r, w, ...): left column, top row and available width, and
// return the NEXT FREE ROW with the standard gap included. Where the Python takes a tap name,
// these take the name (null = the default name) and the closures the hit runs.

// MARK: - Small value types (Swift tuples)

/** A column span (c, w): VFDLayout.split cells. */
data class VFDSpan(val c: Int, val w: Int)

/** Screen rows [top, bottom) of a window: snappedWindow / contentWindow. */
data class VFDWindow(val top: Int, val bottom: Int)

/** One tab-bar entry: the tab key (ContentView / MainTab raw value) and the label shown. */
data class VFDTab(val key: String, val label: String)

/** (c, r, w) of the content area inside a panel: VFDW.panelInner. */
data class VFDPanelInner(val c: Int, val r: Int, val w: Int)

// MARK: - Layout

/** Fixed rows and columns of the VFD screen (widgets.Layout). left / right are the first / last
 *  content columns (inclusive); content rows are contentTop until contentBottom. */
class VFDLayout(val cols: Int, val rows: Int, val safeTop: Int, safeBottom: Int) {
    /** First row of the bottom safe area. */
    val safeEnd: Int = rows - safeBottom
    val left: Int = VFDW.margin
    val right: Int = cols - 1 - VFDW.margin
    val width: Int = right - left + 1
    /** Minimum tap height in rows. */
    val tapRows: Int = VFDW.tapRows

    val headerTop: Int = safeTop + 2
    /** Mid title caps row. */
    val titleRow: Int = headerTop
    /** Small text centred on the title caps. */
    val headerTextRow: Int = headerTop + 4
    val telemetryRow: Int = headerTop + 14 + 4
    val headerRule: Int = telemetryRow + 7 + 3
    val contentTop: Int = headerRule + 4

    val tabH: Int = VFDW.tabH
    /** Top rows of tab-bar row 1 and row 2. */
    val tabRows: List<Int>
    val tabRule: Int
    /** Exclusive. */
    val contentBottom: Int
    val contentH: Int
    val tabCellW: Int
    val tabLeft: Int

    init {
        val row2: Int = safeEnd - 2 - VFDW.tabH
        val row1: Int = row2 - VFDW.tabH - 1
        tabRows = listOf(row1, row2)
        tabRule = row1 - 3
        contentBottom = tabRule - 3
        contentH = contentBottom - contentTop
        val cellW: Int = VFDMath.floorDiv(width - (VFDW.tabCols - 1), VFDW.tabCols)
        tabCellW = cellW
        val used: Int = cellW * VFDW.tabCols + (VFDW.tabCols - 1)
        tabLeft = left + VFDMath.floorDiv(width - used, 2)
    }

    constructor(device: VFDDevice) : this(device.cols, device.rows, device.safeTop, device.safeBottom)

    /** Proportional column: left + round(frac * width) (x(1.0) = right + 1). */
    fun x(frac: Double): Int {
        return left + VFDMath.roundHalfAway(frac * width.toDouble())
    }

    /** n equal columns across [c, c + w) (default the content width) gap cells apart; spare cells
     *  go to the last one. */
    fun split(n: Int, gap: Int = 6, c: Int? = null, w: Int? = null): List<VFDSpan> {
        if (n <= 0) return emptyList()
        val c0: Int = c ?: left
        val w0: Int = w ?: width
        val cw: Int = VFDMath.floorDiv(w0 - gap * (n - 1), n)
        val out = ArrayList<VFDSpan>(n)
        for (i in 0 until n) {
            val ci: Int = c0 + i * (cw + gap)
            val wi: Int = if (i == n - 1) (c0 + w0 - ci) else cw
            out.add(VFDSpan(ci, wi))
        }
        return out
    }

    /** Cell of tab `index` (0..9). */
    fun tabCell(index: Int): VFDRect {
        val row: Int = VFDMath.floorDiv(index, VFDW.tabCols)
        val col: Int = VFDMath.floorMod(index, VFDW.tabCols)
        val c: Int = tabLeft + col * (tabCellW + 1)
        val r: Int = if (row <= 0) tabRows[0] else tabRows[1]
        return VFDRect(c, r, tabCellW, tabH)
    }

    /** Label for a tab key, or its short form when it does not fit the cell with 2 cells of
     *  padding each side (SETTINGS -> SETUP). */
    fun tabLabel(key: String): String {
        var label: String? = null
        for (t in VFDW.tabs) {
            if (t.key == key) {
                label = t.label
                break
            }
        }
        val lab: String = label ?: return VFDW.upper(key)
        val short: String? = VFDW.tabShort[key]
        if (VFDText.width(lab) + 4 > tabCellW && short != null) {
            return short
        }
        return lab
    }
}

// MARK: - Widgets

// `L` is part of every content widget's signature (as in widgets.py and VFDWidgets.swift) even where unused.
@Suppress("UNUSED_PARAMETER")
object VFDW {
    // MARK: constants

    /** The ten tabs in app order: MainTab keys and labels (the Android tab bar may pass its own
     *  list, e.g. with RELAY). */
    val tabs: List<VFDTab> = listOf(
        VFDTab("scan", "SCAN"), VFDTab("tx", "TX"), VFDTab("wand", "WAND"),
        VFDTab("auto", "AUTO"), VFDTab("link", "LINK"), VFDTab("logs", "LOGS"),
        VFDTab("map", "MAP"), VFDTab("diag", "DIAG"), VFDTab("lab", "LAB"),
        VFDTab("settings", "SETTINGS"),
    )
    /** Short forms used when a label does not fit its tab cell. */
    val tabShort: Map<String, String> = mapOf("settings" to "SETUP")
    const val tabCols: Int = 5

    /** Empty columns at the left and right screen edges. */
    const val margin: Int = 3
    /** Height of every control row. */
    const val ctrlH: Int = 13
    /** Caps offset inside a control row. */
    const val ctrlText: Int = 3
    /** A text field box (ctrlH + 1 so descenders clear the bottom border). */
    const val fieldH: Int = 14
    /** Rows between stacked widgets. */
    const val gap: Int = 2
    /** Small text line pitch. */
    const val line: Int = 11
    /** A small label line above a control. */
    const val labelH: Int = 10
    /** Extra rows above a widget that starts with a label line. */
    const val groupGap: Int = 3
    /** Rows of air above a section header. */
    const val sectionGap: Int = 8
    const val sectionH: Int = 11
    /** Minimum tap height in rows. */
    const val tapRows: Int = 15
    /** [-] / [+] step button: stepW x ctrlH cells. */
    const val stepW: Int = 13
    /** Columns between [OPTION] items. */
    const val optGap: Int = 4
    /** One tab-bar row. */
    const val tabH: Int = 13
    /** ON/OFF switch width. */
    const val switchW: Int = 45
    /** Small text advance. */
    const val adv: Int = 6
    const val nPatterns: Int = 5

    /** TxIntervalSlider: 61 stops over 0.5 .. 30 s. */
    const val loopMin: Double = 0.5
    const val loopMax: Double = 30.0
    const val loopLastStop: Int = 60

    // MARK: helpers

    /** Display uppercase (widgets._upper): per character, keeping characters whose uppercase is not
     *  a single character, and µ as µ. */
    fun upper(s: String?): String {
        if (s == null) return ""
        var ascii = true
        for (ch in s) {
            if (ch.code >= 0x80) {
                ascii = false
                break
            }
        }
        if (ascii) return s.uppercase()
        val out = StringBuilder(s.length)
        var i = 0
        while (i < s.length) {
            val u: Int = s.codePointAt(i)
            i += Character.charCount(u)
            if (u < 0x80) {
                out.appendCodePoint(if (u in 0x61..0x7A) u - 32 else u)
                continue
            }
            if (u == 0xB5) {
                out.appendCodePoint(u)
                continue
            }
            val up: String = String(Character.toChars(u)).uppercase()
            if (up.codePointCount(0, up.length) == 1) {
                out.append(up)
            } else {
                out.appendCodePoint(u)
            }
        }
        return out.toString()
    }

    /** Row where a labelled widget starts: groupGap rows lower unless it opens the content. */
    fun groupTop(L: VFDLayout, r: Int): Int {
        return if (r > L.contentTop) r + groupGap else r
    }

    /** Column that centres s (ink) in [c, c + w). */
    fun cx(c: Int, w: Int, s: String, size: VFDSize = VFDSize.small): Int {
        return c + VFDMath.floorDiv(w - VFDText.width(s, size), 2)
    }

    /** Indices of the items whose text or upper() is in names (for options' `selected`). */
    fun selection(items: List<String>, names: Set<String>): Set<Int> {
        val out = HashSet<Int>()
        var i = 0
        for (item in items) {
            if (names.contains(item) || names.contains(upper(item))) {
                out.add(i)
            }
            i += 1
        }
        return out
    }

    private fun nonEmpty(s: String?): String? {
        if (s != null && s.isNotEmpty()) return s
        return null
    }

    /** Python `name or fallback`. */
    private fun orDefault(name: String?, fallback: String): String {
        return nonEmpty(name) ?: fallback
    }

    /** "%03d". */
    private fun pad3(n: Int): String {
        var s: String = Math.abs(n.toLong()).toString()
        val width: Int = if (n < 0) 2 else 3
        while (s.length < width) {
            s = "0$s"
        }
        return if (n < 0) "-$s" else s
    }

    /** A tap rectangle at least minH rows tall, grown evenly above and below the visual; when the
     *  padding would reach past the current clip (a control at the top or bottom of the content)
     *  it is moved inside the clip instead of being cut (widgets._tap). No tap without a name. */
    fun tap(fb: VFDFrameBuffer, c: Int, r: Int, w: Int, h: Int, name: String?, minH: Int = tapRows,
            action: (() -> Unit)? = null, long: (() -> Unit)? = null, swipeLeft: (() -> Unit)? = null,
            swipeRight: (() -> Unit)? = null, drag: ((Double, Boolean) -> Unit)? = null) {
        val tapName: String = nonEmpty(name) ?: return
        var top: Int = r
        var height: Int = h
        if (height < minH) {
            val visTop: Int = r
            val visBot: Int = r + h
            top -= VFDMath.floorDiv(minH - h, 2)
            height = minH
            val oy: Int = fb.originY
            val clip: VFDRect = fb.clipRect
            val r0: Int = clip.r
            val ch: Int = clip.h
            val r1: Int = r0 + ch
            if (r0 <= visTop + oy && visBot + oy <= r1 && height <= ch) {
                if (top + oy < r0) {
                    top = r0 - oy
                } else if (top + height + oy > r1) {
                    top = r1 - oy - height
                }
            }
        }
        fb.tap(c, top, w, height, name = tapName, action = action, long = long, swipeLeft = swipeLeft,
               swipeRight = swipeRight, drag = drag)
    }

    // MARK: inline pieces

    /** Inverted text: a solid block 2 cells around the caps with the text cut out. Returns the
     *  column after the block. */
    fun badge(fb: VFDFrameBuffer, c: Int, r: Int, s: String, color: Int = VFDInk.highlight): Int {
        val tw: Int = VFDText.width(s)
        if (tw == 0) return c
        fb.fill(c - 2, r - 2, tw + 4, 11, color)
        fb.text(c, r, s, VFDSize.small, VFDInk.unlit)
        return c + tw + 2
    }

    /** Alarm text (ALARM ink); on a red-ish base an inverted highlight block (10 rows, nudged 2
     *  cells inward). right = true: c is the inclusive last column. Returns the column after it. */
    fun alarmText(fb: VFDFrameBuffer, c: Int, r: Int, s: String, right: Boolean = false): Int {
        val tw: Int = VFDText.width(s)
        if (tw == 0) return c
        var c0: Int = c
        if (right) {
            c0 = c - tw + 1 - (if (fb.alarmInverted) 2 else 0)
        }
        if (fb.alarmInverted) {
            val x: Int = c0 + (if (right) 0 else 2)
            fb.fill(x - 2, r - 1, tw + 4, 10, VFDInk.highlight)
            fb.text(x, r, s, VFDSize.small, VFDInk.unlit)
            return x + tw + 2
        }
        return fb.text(c0, r, s, VFDSize.small, VFDInk.alarm) - 1
    }

    /** A boxed tag (BAND, NEW): a 1-cell box 2 cells around the caps, the text in text colour. */
    fun tagBox(fb: VFDFrameBuffer, c: Int, r: Int, s: String, color: Int = VFDInk.dim,
               textColor: Int = VFDInk.text): Int {
        val su: String = upper(s)
        val tw: Int = VFDText.width(su)
        if (tw == 0) return c
        fb.box(c - 2, r - 2, tw + 4, 11, color)
        fb.text(c, r, su, VFDSize.small, textColor)
        return c + tw + 2
    }

    /** Section chevron next to small caps at row r: right-pointing 4 x 7 when collapsed, down-
     *  pointing 7 x 4 when open. */
    fun chevron(fb: VFDFrameBuffer, c: Int, r: Int, collapsed: Boolean, color: Int = VFDInk.dim) {
        for (i in 0 until 4) {
            if (collapsed) {
                fb.vline(c + 1 + i, r + i, 7 - 2 * i, color)
            } else {
                fb.hline(c + i, r + 1 + i, 7 - 2 * i, color)
            }
        }
    }

    /** 7 x 4 up-pointing chevron (the "HIDE ..." headers of open panels). */
    fun chevronUp(fb: VFDFrameBuffer, c: Int, r: Int, color: Int = VFDInk.dim) {
        for (i in 0 until 4) {
            fb.hline(c + 3 - i, r + 1 + i, 1 + 2 * i, color)
        }
    }

    /** A 13 x 13 [-] or [+] button at (c, r): highlight border (dim when disabled), the icon in
     *  text colour. Registers the tap when enabled and named. */
    fun stepButton(fb: VFDFrameBuffer, c: Int, r: Int, plus: Boolean, enabled: Boolean = true,
                   name: String? = null, action: (() -> Unit)? = null) {
        val border: Int = if (enabled) VFDInk.highlight else VFDInk.dim
        val icon: Int = if (enabled) VFDInk.text else VFDInk.dim
        fb.box(c, r, stepW, ctrlH, border)
        val midC: Int = c + stepW / 2
        val midR: Int = r + ctrlH / 2
        fb.hline(midC - 2, midR, 5, icon)
        if (plus) {
            fb.vline(midC, midR - 2, 5, icon)
        }
        if (enabled) {
            tap(fb, c - 1, r, stepW + 2, ctrlH, name, action = action)
        }
    }

    // MARK: chrome

    /** A tab constant ("SCAN", "scan", "Settings", "SETUP") to its key, or null. */
    fun tabKey(tab: String): String? {
        val t: String = VFDText.strip(tab).lowercase()
        for (entry in tabs) {
            if (t == entry.key || t == entry.label.lowercase()) {
                return entry.key
            }
        }
        for ((key, short) in tabShort) {
            if (t == short.lowercase()) {
                return key
            }
        }
        return null
    }

    /** The ten tabs with the labels that fit this layout (SETTINGS -> SETUP). */
    fun defaultTabs(L: VFDLayout): List<VFDTab> {
        val out = ArrayList<VFDTab>(tabs.size)
        for (t in tabs) {
            out.add(VFDTab(t.key, L.tabLabel(t.key)))
        }
        return out
    }

    /** Header band: optional "< BACK", the mid title (truncated), an optional right-aligned short
     *  status in rightColor (ALARM via alarmText). rightTap (or onRight) makes the right text a
     *  text button; a DIM right text is a disabled one. Returns L.telemetryRow. */
    fun header(fb: VFDFrameBuffer, L: VFDLayout, title: String, back: Boolean = false, right: String? = null,
               rightColor: Int = VFDInk.highlight, rightTap: String? = null, onBack: (() -> Unit)? = null,
               onRight: (() -> Unit)? = null): Int {
        var x: Int = L.left
        val smallR: Int = L.headerTextRow
        if (back) {
            val end: Int = fb.text(x, smallR, "< BACK", VFDSize.small, VFDInk.highlight)
            tap(fb, 0, L.headerTop - 1, end + 3, 16, "back", action = onBack)
            x = end + 6
        }
        var limit: Int = L.right
        val rawRight: String? = nonEmpty(right)
        if (rawRight != null) {
            val text: String = VFDText.fit(upper(rawRight), VFDMath.floorDiv(L.width, 2))
            var start: Int = L.right - VFDText.width(text) + 1
            if (rightColor == VFDInk.alarm) {
                start = L.right - VFDText.width(text) + 1 - (if (fb.alarmInverted) 2 else 0)
                alarmText(fb, L.right, smallR, text, right = true)
            } else {
                fb.text(start, smallR, text, VFDSize.small, rightColor)
            }
            var tapName: String? = nonEmpty(rightTap)
            if (tapName == null && onRight != null) {
                tapName = "right"
            }
            if (tapName != null && rightColor != VFDInk.dim) {
                fb.tap(start - 3, L.headerTop - 1, fb.cols - start + 3, 16, name = tapName, action = onRight)
            }
            limit = start - 8
        }
        fb.textFit(x, L.titleRow, upper(title), limit - x + 1, VFDSize.mid, VFDInk.highlight)
        return L.telemetryRow
    }

    /** The TelemetryBar line: small dim text, " | " drawn as a 1-cell bar, truncated with … at
     *  the right margin; then the dim header rule. Returns L.contentTop. */
    fun telemetry(fb: VFDFrameBuffer, L: VFDLayout, text: String): Int {
        val r: Int = L.telemetryRow
        val sep: IntArray = intArrayOf(' '.code, '|'.code, ' '.code)
        val tokens = ArrayList<IntArray>()
        for (t in VFDText.split(VFDText.scalars(upper(text)), sep)) {
            if (t.isNotEmpty()) tokens.add(t)
        }
        var x: Int = L.left
        val limit: Int = L.right + 1
        val ellW: Int = VFDText.width(VFDText.ellipsis)
        var i = 0
        for (tokScalars in tokens) {
            val tok: String = VFDText.string(tokScalars)
            if (i > 0) {
                val bar: Int = x + 3
                val nxt: Int = bar + 5
                val headCount: Int = if (tokScalars.isEmpty()) 1 else 2
                if (nxt + VFDText.width(count = headCount) > limit) {
                    if (x + ellW <= limit) {
                        fb.text(x, r, VFDText.ellipsis, VFDSize.small, VFDInk.dim)
                    }
                    break
                }
                fb.vline(bar, r - 1, 9, VFDInk.dim)
                x = nxt
            }
            if (x + VFDText.width(tok) <= limit) {
                x = fb.text(x, r, tok, VFDSize.small, VFDInk.dim)
            } else {
                fb.textFit(x, r, tok, limit - x, VFDSize.small, VFDInk.dim)
                break
            }
            i += 1
        }
        fb.hline(L.left, L.headerRule, L.width, VFDInk.dim)
        return L.contentTop
    }

    /** Pixel tab bar: a dim rule, two rows of five equal cells, labels centred, the selected tab
     *  a solid highlight block with its label cut out, the others dim, dim separators. Each cell is
     *  a tap "tab:<key>". tabs = the (key, label) pairs to show (default defaultTabs(L)). */
    fun tabBar(fb: VFDFrameBuffer, L: VFDLayout, selected: String, tabs: List<VFDTab>? = null,
               onSelect: ((String) -> Unit)? = null) {
        val list: List<VFDTab> = tabs ?: defaultTabs(L)
        val sel: String = tabKey(selected) ?: VFDText.strip(selected).lowercase()
        fb.hline(L.left, L.tabRule, L.width, VFDInk.dim)
        val n: Int = minOf(list.size, 2 * tabCols)
        for (i in 0 until n) {
            val key: String = list[i].key
            val lab: String = list[i].label
            val cell: VFDRect = L.tabCell(i)
            val tx: Int = cx(cell.c, cell.w, lab)
            if (key == sel || key.lowercase() == sel) {
                fb.fill(cell.c + 1, cell.r, cell.w - 2, cell.h, VFDInk.highlight)
                fb.text(tx, cell.r + ctrlText, lab, VFDSize.small, VFDInk.unlit)
            } else {
                fb.text(tx, cell.r + ctrlText, lab, VFDSize.small, VFDInk.dim)
            }
            if (i % tabCols != tabCols - 1) {
                fb.vline(cell.c + cell.w, cell.r + 2, cell.h - 4, VFDInk.dim)
            }
            val act: (() -> Unit)? = if (onSelect != null) ({ onSelect(key) }) else null
            if (i < tabCols) {
                fb.tap(cell.c, cell.r - 2, cell.w + 1, cell.h + 3, name = "tab:$key", action = act)
            } else {
                fb.tap(cell.c, cell.r, cell.w + 1, cell.h + 2, name = "tab:$key", action = act)
            }
        }
    }

    /** Whole fixed chrome for one tab (header, telemetry line + rule, tab bar), drawn inside the
     *  drawable rows. Leaves the content clip pushed (0, contentTop, cols, contentH) with
     *  dy = -scroll; call endFrame(fb) when the content is done. */
    fun frame(fb: VFDFrameBuffer, L: VFDLayout, tab: String, title: String, telemetry: String,
              back: Boolean = false, right: String? = null, rightColor: Int = VFDInk.highlight, scroll: Int = 0,
              rightTap: String? = null, tabs: List<VFDTab>? = null, onBack: (() -> Unit)? = null,
              onRight: (() -> Unit)? = null, onTab: ((String) -> Unit)? = null) {
        fb.pushClip(0, L.safeTop, fb.cols, L.safeEnd - L.safeTop)
        header(fb, L, title, back = back, right = right, rightColor = rightColor, rightTap = rightTap,
               onBack = onBack, onRight = onRight)
        VFDW.telemetry(fb, L, telemetry)
        tabBar(fb, L, selected = tab, tabs = tabs, onSelect = onTab)
        fb.popClip()
        fb.pushClip(0, L.contentTop, fb.cols, L.contentH, dy = -scroll)
    }

    /** Pop the content clip frame() left set. */
    fun endFrame(fb: VFDFrameBuffer) {
        fb.popClip()
    }

    /** Scroll indicator in the last screen column, only when the content (ending at row
     *  contentEnd, exclusive, content coordinates) is taller than the region. Draw it after
     *  endFrame(). */
    fun scrollbar(fb: VFDFrameBuffer, L: VFDLayout, contentEnd: Int, scroll: Int = 0) {
        val total: Int = contentEnd - L.contentTop
        val view: Int = L.contentH
        if (total <= view) return
        val col: Int = fb.cols - 1
        val top: Int = L.contentTop
        val h: Int = L.contentH
        fb.vline(col, top, h, VFDInk.dim, step = 2)
        val th: Int = maxOf(6, VFDMath.floorDiv(h * view, total))
        val pos: Int = maxOf(0, minOf(scroll, total - view))
        val ty: Int = top + VFDMath.floorDiv((h - th) * pos, maxOf(1, total - view))
        fb.vline(col, ty, th, VFDInk.dim)
    }

    // MARK: content widgets

    /** Section header: [chevron] TITLE in small highlight, an optional right-aligned count (3
     *  digits) or right text in dim, a dim rule. collapsed != null draws a chevron and makes the line
     *  a tap "section:<TITLE>". sectionGap rows of air above (not at the content top). */
    fun section(fb: VFDFrameBuffer, L: VFDLayout, c: Int, r: Int, w: Int, title: String, count: Int? = null,
                collapsed: Boolean? = null, right: String? = null, name: String? = null,
                action: (() -> Unit)? = null): Int {
        var y: Int = r
        if (y > L.contentTop) {
            y += sectionGap - gap
        }
        var x: Int = c
        if (collapsed != null) {
            chevron(fb, x, y, collapsed, VFDInk.dim)
            x += 11
        }
        var rt: String? = null
        if (count != null) {
            rt = pad3(count)
        } else {
            val rr: String? = nonEmpty(right)
            if (rr != null) rt = upper(rr)
        }
        var limit: Int = c + w
        val t0: String? = nonEmpty(rt)
        if (t0 != null) {
            val t: String = VFDText.fit(t0, VFDMath.floorDiv(w, 2))
            val start: Int = c + w - VFDText.width(t)
            fb.text(start, y, t, VFDSize.small, VFDInk.dim)
            limit = start - 6
        }
        fb.textFit(x, y, upper(title), limit - x, VFDSize.small, VFDInk.highlight)
        fb.hline(c, y + 9, w, VFDInk.dim)
        if (collapsed != null) {
            tap(fb, c, y - 3, w, 14, orDefault(name, "section:" + upper(title)), action = action)
        }
        return y + sectionH + gap
    }

    /** One small label line (uppercased, truncated) above a control; group adds groupGap first.
     *  Returns the row for the control. */
    fun label(fb: VFDFrameBuffer, L: VFDLayout, c: Int, r: Int, w: Int, s: String, color: Int = VFDInk.dim,
              group: Boolean = true): Int {
        val y: Int = if (group) groupTop(L, r) else r
        fb.textFit(c, y, upper(s), w, VFDSize.small, color)
        return y + labelH
    }

    /** Word-wrapped small text ("\n" breaks lines), as given unless upper. Returns the next row. */
    fun textBlock(fb: VFDFrameBuffer, L: VFDLayout, c: Int, r: Int, w: Int, s: String, color: Int = VFDInk.text,
                  upper: Boolean = false): Int {
        val shown: String = if (upper) VFDW.upper(s) else s
        val nxt: Int = fb.paragraph(c, r, shown, w, VFDSize.small, color, line = line)
        return if (nxt > r) nxt + gap else r
    }

    /** StatusLine: one truncated uppercase line (ALARM via alarmText); banner = a full-width solid
     *  block with the text cut out. A tap when named (or given an action). */
    fun statusLine(fb: VFDFrameBuffer, L: VFDLayout, c: Int, r: Int, w: Int, s: String, color: Int = VFDInk.dim,
                   banner: Boolean = false, name: String? = null, action: (() -> Unit)? = null): Int {
        val su: String = upper(s)
        var tapName: String? = nonEmpty(name)
        if (tapName == null && action != null) {
            tapName = "status:$su"
        }
        if (banner) {
            val bc: Int = if (color == VFDInk.dim || color == VFDInk.text) VFDInk.highlight else color
            fb.fill(c, r, w, 11, bc)
            fb.textFit(c + 3, r + 2, su, w - 6, VFDSize.small, VFDInk.unlit)
            if (tapName != null) {
                tap(fb, c, r, w, 11, tapName, action = action)
            }
            return r + 11 + gap
        }
        if (color == VFDInk.alarm) {
            alarmText(fb, c, r, VFDText.fit(su, w - 4))
        } else {
            fb.textFit(c, r, su, w, VFDSize.small, color)
        }
        if (tapName != null) {
            tap(fb, c, r - 2, w, 11, tapName, action = action)
        }
        return r + line
    }

    /** Key / value line: dim key, right-aligned value (ALARM via alarmText), a dotted leader
     *  between them. Returns r + line. */
    fun kv(fb: VFDFrameBuffer, L: VFDLayout, c: Int, r: Int, w: Int, key: String, value: String?,
           color: Int = VFDInk.highlight, leader: Boolean = true): Int {
        val k: String = upper(key)
        val kw: Int = VFDText.width(k)
        val v: String = VFDText.fit(value ?: "", maxOf(0, w - kw - 6))
        val vw: Int = VFDText.width(v)
        fb.textFit(c, r, k, w, VFDSize.small, VFDInk.dim)
        if (v.isNotEmpty()) {
            var start: Int = c + w - vw
            if (color == VFDInk.alarm) {
                start = c + w - vw - (if (fb.alarmInverted) 2 else 0)
                alarmText(fb, c + w - 1, r, v, right = true)
            } else {
                fb.text(start, r, v, VFDSize.small, color)
            }
            if (leader) {
                var a: Int = c + kw + 3
                val b: Int = start - 3
                a += VFDMath.floorMod(a - c, 2)
                if (b > a) {
                    fb.hline(a, r + 6, b - a, VFDInk.dim, step = 2)
                }
            }
        }
        return r + line
    }

    /** Big readout: a dim label line, the value in big (or mid), optional small dim sub-text after
     *  it on its baseline. Returns the next row. */
    fun hero(fb: VFDFrameBuffer, L: VFDLayout, c: Int, r: Int, w: Int, key: String, value: String,
             size: VFDSize = VFDSize.big, color: Int = VFDInk.highlight, sub: String? = null): Int {
        val y: Int = groupTop(L, r)
        fb.textFit(c, y, upper(key), w, VFDSize.small, VFDInk.dim)
        val vr: Int = y + labelH + 1
        val end: Int = fb.textFit(c, vr, value, w, size, color)
        val sb: String? = nonEmpty(sub)
        if (sb != null) {
            val sx: Int = end + 4
            if (sx < c + w) {
                fb.textFit(sx, vr + size.ascent - 7, upper(sb), c + w - sx, VFDSize.small, VFDInk.dim)
            }
        }
        return vr + size.ascent + 3 + gap
    }

    /** A 1-row divider (dotted by default). Returns r + 1 + gap. */
    fun divider(fb: VFDFrameBuffer, L: VFDLayout, c: Int, r: Int, w: Int, dotted: Boolean = true,
                color: Int = VFDInk.dim): Int {
        fb.hline(c, r, w, color, step = if (dotted) 2 else 1)
        return r + 1 + gap
    }

    /** (c, r, w) of the content area inside panel(c, r, w, ..., title). */
    fun panelInner(c: Int, r: Int, w: Int, title: Boolean = true): VFDPanelInner {
        return VFDPanelInner(c + 4, r + (if (title) 10 else 4), w - 8)
    }

    /** A 1-cell border box w x h; with a title, the title (small highlight) is set into the top
     *  border, which then runs at r + 3. Returns r + h + gap. */
    fun panel(fb: VFDFrameBuffer, L: VFDLayout, c: Int, r: Int, w: Int, h: Int, title: String? = null,
              color: Int = VFDInk.dim): Int {
        val t0: String? = nonEmpty(title)
        if (t0 != null) {
            val top: Int = r + 3
            fb.box(c, top, w, h - 3, color)
            val t: String = VFDText.fit(upper(t0), w - 14)
            fb.fill(c + 3, top, VFDText.width(t) + 6, 1, VFDInk.unlit)
            fb.text(c + 6, r, t, VFDSize.small, VFDInk.highlight)
        } else {
            fb.box(c, r, w, h, color)
        }
        return r + h + gap
    }

    /** Label on the left, a pixel ON/OFF switch right-aligned (switchW cells). Tap
     *  "toggle:<LABEL>" across the whole row when enabled. */
    fun toggle(fb: VFDFrameBuffer, L: VFDLayout, c: Int, r: Int, w: Int, labelText: String, on: Boolean,
               enabled: Boolean = true, name: String? = null, labelColor: Int = VFDInk.text,
               action: (() -> Unit)? = null): Int {
        val seg: Int = VFDMath.floorDiv(switchW - 3, 2)
        val sx: Int = c + w - switchW
        val lc: Int = if (enabled) labelColor else VFDInk.dim
        val ty: Int = r + ctrlText
        fb.textFit(c, ty, upper(labelText), sx - c - 6, VFDSize.small, lc)
        fb.box(sx, r, switchW, ctrlH, VFDInk.dim)
        fb.vline(sx + 1 + seg, r, ctrlH, VFDInk.dim)
        val onX: Int = sx + 1
        val offX: Int = sx + 2 + seg
        if (on) {
            fb.fill(onX, r + 1, seg, ctrlH - 2, if (enabled) VFDInk.highlight else VFDInk.dim)
            fb.text(cx(onX, seg, "ON"), ty, "ON", VFDSize.small, VFDInk.unlit)
            fb.text(cx(offX, seg, "OFF"), ty, "OFF", VFDSize.small, VFDInk.dim)
        } else {
            fb.text(cx(onX, seg, "ON"), ty, "ON", VFDSize.small, VFDInk.dim)
            fb.fill(offX, r + 1, seg, ctrlH - 2, VFDInk.dim)
            fb.text(cx(offX, seg, "OFF"), ty, "OFF", VFDSize.small, VFDInk.unlit)
        }
        if (enabled) {
            tap(fb, c, r, w, ctrlH, orDefault(name, "toggle:" + upper(labelText)), action = action)
        }
        return r + ctrlH + gap
    }

    /** [OPTION] selectors: unselected = dim brackets around the name in text, selected = a solid
     *  highlight block with the name cut out. Optional label line above. Items flow and wrap every
     *  ctrlH + gap rows; columns = n centres each in one of n equal cells. Each item is a tap
     *  "<name or option:LABEL>:<ITEM>" calling onSelect(index). */
    fun options(fb: VFDFrameBuffer, L: VFDLayout, c: Int, r: Int, w: Int, items: List<String>, selected: Set<Int>,
                label: String? = null, enabled: Boolean = true, name: String? = null, columns: Int? = null,
                onSelect: ((Int) -> Unit)? = null): Int {
        var top: Int = r
        val lt: String? = nonEmpty(label)
        if (lt != null) {
            top = VFDW.label(fb, L, c, top, w, lt)
        }
        val base: String = orDefault(name, "option:" + upper(label ?: ""))
        var cells: List<VFDSpan> = emptyList()
        var ncols = 0
        if (columns != null && columns > 0) {
            cells = L.split(columns, gap = optGap, c = c, w = w)
            ncols = columns
        }
        var x: Int = c
        var y: Int = top
        var i = 0
        for (raw in items) {
            val item: String = upper(raw)
            var ow: Int
            if (ncols > 0) {
                val col: Int = i % ncols
                if (col == 0 && i > 0) {
                    y += ctrlH + gap
                }
                x = cells[col].c
                ow = cells[col].w
            } else {
                ow = VFDText.width("[$item]")
                if (x > c && x + ow > c + w) {
                    x = c
                    y += ctrlH + gap
                }
                ow = minOf(ow, c + w - x)
            }
            val shown: String = VFDText.fit(item, ow - 2 * adv)
            val fw: Int = VFDText.width("[$shown]")
            val fx: Int = if (ncols > 0) x + VFDMath.floorDiv(ow - fw, 2) else x
            val ty: Int = y + ctrlText
            if (selected.contains(i)) {
                fb.fill(fx, y + 1, fw, ctrlH - 2, if (enabled) VFDInk.highlight else VFDInk.dim)
                fb.text(fx + adv, ty, shown, VFDSize.small, VFDInk.unlit)
            } else {
                fb.text(fx, ty, "[", VFDSize.small, VFDInk.dim)
                fb.text(fx + adv, ty, shown, VFDSize.small, if (enabled) VFDInk.text else VFDInk.dim)
                fb.text(fx + fw - 5, ty, "]", VFDSize.small, VFDInk.dim)
            }
            if (enabled) {
                val index: Int = i
                val act: (() -> Unit)? = if (onSelect != null) ({ onSelect(index) }) else null
                tap(fb, x - VFDMath.floorDiv(optGap, 2), y, ow + optGap, ctrlH, "$base:$item", action = act)
            }
            x += ow + optGap
            i += 1
        }
        return y + ctrlH + gap
    }

    /** options() with one selected index (or none). */
    fun options(fb: VFDFrameBuffer, L: VFDLayout, c: Int, r: Int, w: Int, items: List<String>, selected: Int?,
                label: String? = null, enabled: Boolean = true, name: String? = null, columns: Int? = null,
                onSelect: ((Int) -> Unit)? = null): Int {
        val set: Set<Int> = if (selected != null) setOf(selected) else emptySet()
        return options(fb, L, c, r, w, items, selected = set, label = label, enabled = enabled, name = name,
                       columns = columns, onSelect = onSelect)
    }

    /** Label on the left; right-aligned [-] value [+] (value in small highlight, centred in a field
     *  valueChars wide, default its length). Taps "<name or stepper:LABEL>:-" / ":+". */
    fun stepper(fb: VFDFrameBuffer, L: VFDLayout, c: Int, r: Int, w: Int, labelText: String, value: String,
                enabled: Boolean = true, canDec: Boolean = true, canInc: Boolean = true, valueChars: Int? = null,
                name: String? = null, onDec: (() -> Unit)? = null, onInc: (() -> Unit)? = null): Int {
        val n: Int = maxOf(VFDText.length(value), valueChars ?: 0)
        val vw: Int = n * adv - 1 + 6
        val gx: Int = c + w - (stepW + vw + stepW)
        val base: String = orDefault(name, "stepper:" + upper(labelText))
        val ty: Int = r + ctrlText
        fb.textFit(c, ty, upper(labelText), gx - c - 6, VFDSize.small, if (enabled) VFDInk.text else VFDInk.dim)
        stepButton(fb, gx, r, false, enabled && canDec, "$base:-", action = onDec)
        fb.text(cx(gx + stepW, vw, value), ty, value, VFDSize.small, if (enabled) VFDInk.highlight else VFDInk.dim)
        stepButton(fb, gx + stepW + vw, r, true, enabled && canInc, "$base:+", action = onInc)
        return r + ctrlH + gap
    }

    /** A button w cells wide (null = label + 6 cells each side), ctrlH tall: highlight border with
     *  the label in text, primary = a solid highlight block with the label cut out, disabled = dim,
     *  alarm = a destructive action (ALARM border and label, or an inverted block on a red-ish
     *  base). Tap "button:<LABEL>" when enabled. */
    fun button(fb: VFDFrameBuffer, L: VFDLayout, c: Int, r: Int, w: Int?, labelText: String,
               primary: Boolean = false, enabled: Boolean = true, name: String? = null, alarm: Boolean = false,
               action: (() -> Unit)? = null, long: (() -> Unit)? = null): Int {
        var s: String = upper(labelText)
        val bw: Int = w ?: (VFDText.width(s) + 12)
        s = VFDText.fit(s, bw - 4)
        val tx: Int = cx(c, bw, s)
        val ty: Int = r + ctrlText
        if (alarm && enabled) {
            if (fb.alarmInverted) {
                fb.fill(c, r, bw, ctrlH, VFDInk.highlight)
                fb.text(tx, ty, s, VFDSize.small, VFDInk.unlit)
            } else {
                fb.box(c, r, bw, ctrlH, VFDInk.alarm)
                fb.text(tx, ty, s, VFDSize.small, VFDInk.alarm)
            }
        } else if (primary && enabled) {
            fb.fill(c, r, bw, ctrlH, VFDInk.highlight)
            fb.text(tx, ty, s, VFDSize.small, VFDInk.unlit)
        } else {
            fb.box(c, r, bw, ctrlH, if (enabled) VFDInk.highlight else VFDInk.dim)
            fb.text(tx, ty, s, VFDSize.small, if (enabled) VFDInk.text else VFDInk.dim)
        }
        if (enabled) {
            tap(fb, c, r, bw, ctrlH, orDefault(name, "button:$s"), action = action, long = long)
        }
        return r + ctrlH + gap
    }

    /** A row of buttons: equal cells, or (equal = false) sized to their labels, gap cells apart.
     *  primary / alarm: the index of the primary / destructive button; enabled: per button (null or
     *  empty = all). onSelect(index) on a tap. */
    fun buttons(fb: VFDFrameBuffer, L: VFDLayout, c: Int, r: Int, w: Int, labels: List<String>, primary: Int? = null,
                enabled: List<Boolean>? = null, gap: Int = 4, equal: Boolean = true, alarm: Int? = null,
                onSelect: ((Int) -> Unit)? = null): Int {
        val n: Int = labels.size
        if (n == 0) return r
        val en: List<Boolean> = if (enabled != null && enabled.isNotEmpty()) enabled else List(n) { true }
        val spots: List<VFDSpan>
        if (equal) {
            spots = L.split(n, gap = gap, c = c, w = w)
        } else {
            val list = ArrayList<VFDSpan>(n)
            var x: Int = c
            for (s in labels) {
                val bw: Int = VFDText.width(upper(s)) + 12
                list.add(VFDSpan(x, bw))
                x += bw + gap
            }
            spots = list
        }
        for (i in 0 until n) {
            val spot: VFDSpan = spots[i]
            val isEnabled: Boolean = if (i < en.size) en[i] else true
            val index: Int = i
            val act: (() -> Unit)? = if (onSelect != null) ({ onSelect(index) }) else null
            button(fb, L, spot.c, r, spot.w, labels[i], primary = primary == i, enabled = isEnabled,
                   alarm = alarm == i, action = act)
        }
        return r + ctrlH + VFDW.gap
    }

    /** SettingSlider: title (uppercased, unit in it) with the value right-aligned on the label
     *  row, then [-] LED bar [+], then an optional dim wrapped hint. canDec / canInc default to
     *  frac > 0 / frac < 1. Taps "<name or slider:TITLE>:-", ":+", ":bar"; the bar's drag calls
     *  onSet(fraction of the bar 0..1). */
    fun slider(fb: VFDFrameBuffer, L: VFDLayout, c: Int, r: Int, w: Int, title: String, valueText: String,
               frac: Double, hint: String? = null, enabled: Boolean = true, zone: Pair<Double, Double>? = null,
               marker: Boolean = false, name: String? = null, canDec: Boolean? = null, canInc: Boolean? = null,
               onDec: (() -> Unit)? = null, onInc: (() -> Unit)? = null, onSet: ((Double) -> Unit)? = null): Int {
        val dec: Boolean = canDec ?: (frac > 0)
        val inc: Boolean = canInc ?: (frac < 1)
        val top: Int = groupTop(L, r)
        val t: String = upper(title)
        val vw: Int = VFDText.width(valueText)
        fb.text(c + w - vw, top, valueText, VFDSize.small, if (enabled) VFDInk.highlight else VFDInk.dim)
        fb.textFit(c, top, t, w - vw - 6, VFDSize.small, if (enabled) VFDInk.text else VFDInk.dim)
        var y: Int = top + labelH
        val base: String = orDefault(name, "slider:$t")
        stepButton(fb, c, y, false, enabled && dec, "$base:-", action = onDec)
        stepButton(fb, c + w - stepW, y, true, enabled && inc, "$base:+", action = onInc)
        val bx: Int = c + stepW + 4
        val bw: Int = w - 2 * (stepW + 4)
        val barY: Int = y + VFDMath.floorDiv(ctrlH - VFDFrameBuffer.ledBarH, 2) + 1
        fb.ledBar(bx, barY, bw, frac, color = if (enabled) VFDInk.highlight else VFDInk.dim, marker = marker,
                  zone = zone)
        if (enabled) {
            var drag: ((Double, Boolean) -> Unit)? = null
            if (onSet != null) {
                val span: Double = (bw + 4).toDouble()
                val barW: Double = maxOf(1, bw).toDouble()
                drag = { fraction: Double, _: Boolean ->
                    val v: Double = (fraction * span - 2.0) / barW
                    onSet(minOf(maxOf(v, 0.0), 1.0))
                }
            }
            tap(fb, bx - 2, y, bw + 4, ctrlH, "$base:bar", drag = drag)
        }
        y += ctrlH + gap
        val h: String? = nonEmpty(hint)
        if (h != null) {
            y = fb.paragraph(c, y + 1, h, w, VFDSize.small, VFDInk.dim, line = line) + gap
        }
        return y
    }

    /** Read-only LED meter: dim title and the value right-aligned (ALARM via alarmText) on the
     *  label row, a full-width LED bar under it. */
    fun meter(fb: VFDFrameBuffer, L: VFDLayout, c: Int, r: Int, w: Int, title: String, valueText: String,
              frac: Double, zone: Pair<Double, Double>? = null, marker: Boolean = false,
              color: Int = VFDInk.highlight): Int {
        val top: Int = groupTop(L, r)
        val t: String = upper(title)
        val vw: Int = VFDText.width(valueText)
        if (color == VFDInk.alarm) {
            alarmText(fb, c + w - 1, top, valueText, right = true)
        } else {
            fb.text(c + w - vw, top, valueText, VFDSize.small, color)
        }
        fb.textFit(c, top, t, w - vw - 6, VFDSize.small, VFDInk.dim)
        fb.ledBar(c, top + labelH, w, frac, color = VFDInk.highlight, marker = marker, zone = zone)
        return top + labelH + VFDFrameBuffer.ledBarH + gap + 1
    }

    /** Boxed text field: optional label line, a fieldH box (highlight when focused) with the value
     *  (as given) or the placeholder (dim, uppercased), truncated; a focused field shows a cursor.
     *  Tap "field:<LABEL>". */
    fun field(fb: VFDFrameBuffer, L: VFDLayout, c: Int, r: Int, w: Int, labelText: String?, value: String,
              placeholder: String = "", focused: Boolean = false, name: String? = null,
              valueColor: Int = VFDInk.text, action: (() -> Unit)? = null): Int {
        var top: Int = r
        val lt: String? = nonEmpty(labelText)
        if (lt != null) {
            top = label(fb, L, c, top, w, lt)
        }
        fb.box(c, top, w, fieldH, if (focused) VFDInk.highlight else VFDInk.dim)
        val ty: Int = top + ctrlText
        var x: Int = c + 3
        var inner: Int = w - 7
        if (value.isNotEmpty()) {
            val end: Int = fb.textFit(x, ty, value, inner, VFDSize.small, valueColor)
            if (focused) {
                fb.vline(minOf(end, c + w - 3), ty, 7, VFDInk.highlight)
            }
        } else {
            if (focused) {
                fb.vline(x, ty, 7, VFDInk.highlight)
                x += 3
                inner -= 3
            }
            if (placeholder.isNotEmpty()) {
                fb.textFit(x, ty, upper(placeholder), inner, VFDSize.small, VFDInk.dim)
            }
        }
        tap(fb, c, top, w, fieldH, orDefault(name, "field:" + upper(labelText ?: "")), action = action)
        return top + fieldH + gap
    }

    /** One packet (PacketRow): the label (selected = inverted) with an optional boxed tag and a
     *  right-aligned dim note, the hex truncated (hexColor: HIGHLIGHT live, DIM stored), the dim
     *  subtitle, a dotted divider. The whole row is one tap "packet:<LABEL>". Returns the next
     *  row's r. */
    fun packetRow(fb: VFDFrameBuffer, L: VFDLayout, c: Int, r: Int, w: Int, labelText: String, hexText: String,
                  subtitle: String = "", tag: String? = null, selected: Boolean = false, right: String? = null,
                  name: String? = null, hexColor: Int = VFDInk.highlight, action: (() -> Unit)? = null,
                  long: (() -> Unit)? = null, swipeLeft: (() -> Unit)? = null,
                  swipeRight: (() -> Unit)? = null): Int {
        var lab: String = upper(labelText)
        var y: Int = r + 3
        var limit: Int = c + w
        val rt0: String? = nonEmpty(right)
        if (rt0 != null) {
            val rt: String = VFDText.fit(upper(rt0), VFDMath.floorDiv(w, 3))
            val start: Int = c + w - VFDText.width(rt)
            fb.text(start, y, rt, VFDSize.small, VFDInk.dim)
            limit = start - 6
        }
        var x: Int = c + 2
        var tagS = ""
        val t: String? = nonEmpty(tag)
        if (t != null) {
            tagS = upper(t)
        }
        val tagW: Int = if (tagS.isEmpty()) 0 else VFDText.width(tagS) + 8
        lab = VFDText.fit(lab, limit - x - 2 - tagW)
        x = if (selected) {
            badge(fb, x, y, lab, VFDInk.highlight)
        } else {
            fb.text(x, y, lab, VFDSize.small, VFDInk.text) + 1
        }
        if (tagS.isNotEmpty()) {
            tagBox(fb, x + 4, y, tagS)
        }
        if (hexText.isNotEmpty()) {
            y += line
            fb.textFit(c + 2, y, hexText, w - 2, VFDSize.small, hexColor)
        }
        if (subtitle.isNotEmpty()) {
            y += line
            fb.textFit(c + 2, y, upper(subtitle), w - 2, VFDSize.small, VFDInk.dim)
        }
        y += 7 + 3
        fb.hline(c, y, w, VFDInk.dim, step = 2)
        tap(fb, c, r, w, y - r, orDefault(name, "packet:" + upper(labelText)), action = action, long = long,
            swipeLeft = swipeLeft, swipeRight = swipeRight)
        return y + 1
    }

    /** Line chart block: dim title (group gap) and optional right-aligned highlight value on the
     *  label row, then a dim-framed w x h box with the line inside. */
    fun chart(fb: VFDFrameBuffer, L: VFDLayout, c: Int, r: Int, w: Int, h: Int, title: String?,
              values: List<Double?>, valueText: String? = null, vmin: Double? = null, vmax: Double? = null,
              color: Int = VFDInk.highlight): Int {
        var top: Int = r
        val t: String = title ?: ""
        val vt: String = valueText ?: ""
        if (t.isNotEmpty() || vt.isNotEmpty()) {
            top = groupTop(L, top)
            if (vt.isNotEmpty()) {
                fb.textRight(c + w - 1, top, vt, VFDSize.small, VFDInk.highlight)
            }
            fb.textFit(c, top, upper(t), w - VFDText.width(vt) - 6, VFDSize.small, VFDInk.dim)
            top += labelH
        }
        fb.box(c, top, w, h, VFDInk.dim)
        fb.lineChart(c + 2, top + 2, w - 4, h - 4, values, color = color, vmin = vmin, vmax = vmax)
        return top + h + gap
    }

    // MARK: lists under pinned rows

    /** Rows (top, bottom) of the screen window [top, bottom) a scrolling list may use without
     *  cutting a line: draw runs once on a scratch buffer (same origin as fb); a band of lit rows
     *  crossing an edge is left out, and so is a lone lit row (a divider) in the first or last 5
     *  rows (widgets.snapped_window). */
    fun snappedWindow(fb: VFDFrameBuffer, top: Int, bottom: Int, draw: (VFDFrameBuffer) -> Unit): VFDWindow {
        val probe = VFDFrameBuffer(fb.cols, fb.rows)
        probe.pushClip(0, 0, fb.cols, fb.rows, dy = fb.originY)
        draw(probe)
        probe.popClip()
        return snappedWindow(lit = probe, top = top, bottom = bottom)
    }

    /** The window logic of snappedWindow on an already drawn scratch buffer. */
    fun snappedWindow(lit: VFDFrameBuffer, top: Int, bottom: Int): VFDWindow {
        val cols: Int = lit.cols
        val rows: Int = lit.rows
        val cells: ByteArray = lit.cells
        fun isLit(r: Int): Boolean {
            if (r < 0 || r >= rows) return false
            val start: Int = r * cols
            var i = 0
            while (i < cols) {
                if (cells[start + i].toInt() != 0) return true
                i += 1
            }
            return false
        }
        fun lone(r: Int): Boolean {
            return isLit(r) && !isLit(r - 1) && !isLit(r + 1)
        }
        var t: Int = top
        var b: Int = bottom
        if (isLit(t - 1) && isLit(t)) {
            while (t < b && isLit(t)) {
                t += 1
            }
        }
        var r: Int = t
        while (r < minOf(t + 5, b)) {
            if (lone(r)) {
                t = r + 1
                break
            }
            r += 1
        }
        if (isLit(b - 1) && isLit(b)) {
            while (b > t && isLit(b - 1)) {
                b -= 1
            }
        }
        r = b - 1
        val stop: Int = maxOf(b - 6, t - 1)
        while (r > stop) {
            if (lone(r)) {
                b = r
                break
            }
            r -= 1
        }
        return VFDWindow(t, b)
    }

    /** A list's scroll indicator in the last screen column over rows top until top + h, only when
     *  the list is taller than its window. */
    fun listScrollbar(fb: VFDFrameBuffer, top: Int, h: Int, total: Int, scroll: Int) {
        if (total <= h) return
        val col: Int = fb.cols - 1
        fb.vline(col, top, h, VFDInk.dim, step = 2)
        val th: Int = maxOf(6, VFDMath.floorDiv(h * h, total))
        val pos: Int = maxOf(0, minOf(scroll, total - h))
        val ty: Int = top + VFDMath.floorDiv((h - th) * pos, maxOf(1, total - h))
        fb.vline(col, ty, th, VFDInk.dim)
    }

    /** Split an "A · B · C" line into lines that break only between tokens; a token too long on its
     *  own is truncated with …. */
    fun tokenLines(text: String, maxCols: Int, sep: String = " · "): List<String> {
        val lines = ArrayList<String>()
        var cur: IntArray = IntArray(0)
        val sepS: IntArray = VFDText.scalars(sep)
        for (tok in VFDText.split(VFDText.scalars(text), sepS)) {
            var cand: IntArray = tok
            if (cur.isNotEmpty()) {
                cand = cur + sepS + tok
            }
            if (VFDText.width(count = cand.size) <= maxCols) {
                cur = cand
                continue
            }
            if (cur.isNotEmpty()) {
                lines.add(VFDText.string(cur))
            }
            cur = VFDText.scalars(VFDText.fit(VFDText.string(tok), maxCols))
        }
        if (cur.isNotEmpty()) {
            lines.add(VFDText.string(cur))
        }
        return lines
    }

    // MARK: TxIntervalSlider

    /** TxLoopInterval.stop(forSeconds:): the nearest of the 61 stops (halves to even, as Python). */
    fun intervalStop(seconds: Double): Int {
        val pos: Double = (seconds - loopMin) / (loopMax - loopMin) * loopLastStop.toDouble()
        val n: Int = VFDMath.roundHalfEven(pos)
        return minOf(maxOf(n, 0), loopLastStop)
    }

    /** TxLoopInterval.text(_:): one decimal, halves rounding up. */
    fun intervalText(seconds: Double): String {
        val tenths: Int = VFDMath.truncate(Math.abs(seconds) * 10 + 0.5)
        return "${VFDMath.floorDiv(tenths, 10)}.${VFDMath.floorMod(tenths, 10)}"
    }

    /** TxLoopInterval.seconds(forStop:). */
    fun intervalSeconds(stop: Int): Double {
        val clamped: Int = minOf(maxOf(stop, 0), loopLastStop)
        val f: Double = clamped.toDouble() / loopLastStop.toDouble()
        return (1 - f) * loopMin + f * loopMax
    }

    /** TxIntervalSlider: one line of text over a full-width 61-stop slider (dotted track, the lit
     *  part up to the thumb, a 3 x 6 thumb). The tap covers the bar and the label; its drag calls
     *  onSet(seconds of the nearest stop). */
    fun intervalSlider(fb: VFDFrameBuffer, L: VFDLayout, c: Int, r: Int, w: Int, labelText: String, seconds: Double,
                       name: String = "slider:INTERVAL", onSet: ((Double) -> Unit)? = null): Int {
        val top: Int = if (r > L.contentTop) r + groupGap else r
        fb.textFit(c, top, labelText, w, VFDSize.small, VFDInk.text)
        val y: Int = top + labelH
        val frac: Double = intervalStop(seconds).toDouble() / loopLastStop.toDouble()
        fb.ledBar(c, y, w, frac, marker = true, zone = Pair(0.0, frac))
        var drag: ((Double, Boolean) -> Unit)? = null
        if (onSet != null) {
            drag = { fraction: Double, _: Boolean ->
                val clamped: Double = minOf(maxOf(fraction, 0.0), 1.0)
                val stop: Int = VFDMath.roundHalfAway(clamped * loopLastStop.toDouble())
                onSet(intervalSeconds(stop))
            }
        }
        fb.tap(c, y - 6, w, tapRows, name = "$name:bar", drag = drag)
        return y + VFDFrameBuffer.ledBarH + 3 + gap
    }

    /** SectionFilterMenu ("CLASS 8/8 ▾"): a button with a pixel down-chevron after the label. Tap
     *  "<name or menu:LABEL>". Returns the column after it. */
    fun menuButton(fb: VFDFrameBuffer, L: VFDLayout, x: Int, y: Int, labelText: String, enabled: Boolean = true,
                   name: String? = null, action: (() -> Unit)? = null): Int {
        val lab: String = upper(labelText)
        val w: Int = VFDText.width(lab) + 11 + 12
        fb.box(x, y, w, ctrlH, if (enabled) VFDInk.highlight else VFDInk.dim)
        val ty: Int = y + ctrlText
        val end: Int = fb.text(x + 6, ty, lab, VFDSize.small, if (enabled) VFDInk.text else VFDInk.dim)
        chevron(fb, end + 3, ty + 1, false, if (enabled) VFDInk.text else VFDInk.dim)
        if (enabled) {
            tap(fb, x - 2, y, w + 4, ctrlH, orDefault(name, "menu:$lab"), action = action)
        }
        return x + w
    }

    // MARK: band LEDs

    /** A round LED / legend swatch size x size at (x, y). kind: 0 solid, 1 checker, 2 ring with a
     *  centre dot, 3 horizontal stripes, 4 vertical stripes; null = unlit (a dotted dim ring).
     *  fill: a solid disc in that true colour (fb.rgb) instead of the pattern; kind null still draws
     *  the unlit ring. */
    fun led(fb: VFDFrameBuffer, x: Int, y: Int, kind: Int?, size: Int = 7, color: Int = VFDInk.highlight,
            fill: VFDRGB? = null) {
        // The colour is allocated even for an empty disc, as widgets.led does.
        var trueColor = -1
        if (fill != null && kind != null) {
            trueColor = fb.rgb(fill)
        }
        if (size <= 0) return
        val m: Double = (size - 1).toDouble() / 2.0
        val rad: Double = size.toDouble() / 2.0
        val limit: Double = rad * rad - 0.5
        val disc = BooleanArray(size * size)
        for (j in 0 until size) {
            for (i in 0 until size) {
                val di: Double = i.toDouble() - m
                val dj: Double = j.toDouble() - m
                if (di * di + dj * dj <= limit) {
                    disc[j * size + i] = true
                }
            }
        }
        fun inDisc(i: Int, j: Int): Boolean {
            if (i < 0 || j < 0 || i >= size || j >= size) return false
            return disc[j * size + i]
        }
        val mid: Int = size / 2
        for (j in 0 until size) {
            for (i in 0 until size) {
                if (!inDisc(i, j)) continue
                val edge: Boolean = !inDisc(i + 1, j) || !inDisc(i - 1, j) || !inDisc(i, j + 1) || !inDisc(i, j - 1)
                var on: Boolean
                var col: Int = color
                if (kind != null) {
                    if (trueColor >= 0) {
                        on = true
                        col = trueColor
                    } else {
                        on = when (VFDMath.floorMod(kind, nPatterns)) {
                            0 -> true
                            1 -> (i + j) % 2 == 0
                            2 -> edge || (Math.abs(i - mid) <= 1 && Math.abs(j - mid) <= 1)
                            3 -> j % 2 == 0
                            else -> i % 2 == 0
                        }
                    }
                } else {
                    on = edge && (i + j) % 2 == 0
                    col = VFDInk.dim
                }
                if (on) {
                    fb.set(x + i, y + j, col)
                }
            }
        }
    }

    // MARK: screen composition (render_previews.content_window / draw_screen)

    /** The content rows (top, bottom) a screen may light at this scroll without a line of text
     *  being cut by the content edges: draw runs once on a scratch buffer with the content
     *  unclipped, then the snappedWindow rules apply to [contentTop, contentBottom). probe: a
     *  scratch buffer of the layout's size to reuse (reset here) instead of allocating one. */
    fun contentWindow(L: VFDLayout, scroll: Int, base: VFDBase, alarmInverted: Boolean,
                      probe: VFDFrameBuffer? = null, draw: (VFDFrameBuffer, VFDLayout) -> Int?): VFDWindow {
        val p: VFDFrameBuffer
        if (probe != null && probe.cols == L.cols && probe.rows == L.rows) {
            p = probe
            p.reset()
            p.alarmInverted = alarmInverted
        } else {
            p = VFDFrameBuffer(L.cols, L.rows, alarmInverted)
        }
        p.base = base
        p.pushClip(0, 0, p.cols, p.rows, dy = -scroll)
        val depth: Int = p.clipDepth
        draw(p, L)
        while (p.clipDepth >= depth && p.clipDepth > 0) {
            p.popClip()
        }
        return snappedWindow(lit = p, top = L.contentTop, bottom = L.contentBottom)
    }

    /** Drop the taps from index `from` that a window edge cut to a sliver (shorter than tapRows,
     *  touching a window edge that is not the content edge). */
    fun dropHiddenTaps(fb: VFDFrameBuffer, from: Int, window: VFDWindow, L: VFDLayout) {
        val taps: MutableList<VFDHit> = fb.taps
        if (from < 0 || from >= taps.size) return
        var k: Int = from
        for (i in from until taps.size) {
            val tp: VFDHit = taps[i]
            val tall: Boolean = tp.h >= tapRows
            val atWindowEdge: Boolean = tp.r == window.top || tp.r + tp.h == window.bottom
            val atContentEdge: Boolean = tp.r == L.contentTop || tp.r + tp.h == L.contentBottom
            if (tall || !atWindowEdge || atContentEdge) {
                taps[k] = tp
                k += 1
            }
        }
        while (taps.size > k) {
            taps.removeAt(taps.size - 1)
        }
    }

    /** One whole screen, two-pass like render_previews.draw_screen: the content window is snapped
     *  on a scratch pass, then the chrome (frame), the content clipped to that window, hidden
     *  partial taps dropped and the scrollbar. draw lays the content out from L.contentTop in
     *  content coordinates and returns its end row (or null); it runs twice, so it must be pure.
     *  fb should be freshly cleared. probe: an optional scratch buffer to reuse for the first pass.
     *  Returns draw's end row. */
    fun drawScreen(fb: VFDFrameBuffer, L: VFDLayout, tab: String, title: String, telemetry: String,
                   back: Boolean = false, right: String? = null, rightColor: Int = VFDInk.highlight,
                   rightTap: String? = null, scroll: Int = 0, tabs: List<VFDTab>? = null,
                   onBack: (() -> Unit)? = null, onRight: (() -> Unit)? = null, onTab: ((String) -> Unit)? = null,
                   probe: VFDFrameBuffer? = null, draw: (VFDFrameBuffer, VFDLayout) -> Int?): Int? {
        val win: VFDWindow = contentWindow(L, scroll, fb.base, fb.alarmInverted, probe = probe, draw = draw)
        frame(fb, L, tab = tab, title = title, telemetry = telemetry, back = back, right = right,
              rightColor = rightColor, scroll = scroll, rightTap = rightTap, tabs = tabs, onBack = onBack,
              onRight = onRight, onTab = onTab)
        fb.popClip()
        fb.pushClip(0, win.top, fb.cols, win.bottom - win.top, dy = -scroll)
        val depth: Int = fb.clipDepth
        val nTaps: Int = fb.taps.size
        val end: Int? = draw(fb, L)
        while (fb.clipDepth >= depth && fb.clipDepth > 0) {
            fb.popClip()
        }
        dropHiddenTaps(fb, from = nTaps, window = win, L = L)
        if (end != null) {
            scrollbar(fb, L, end, scroll = scroll)
        }
        return end
    }
}
