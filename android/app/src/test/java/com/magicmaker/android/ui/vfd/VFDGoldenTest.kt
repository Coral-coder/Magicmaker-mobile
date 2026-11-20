package com.magicmaker.android.ui.vfd

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

// VFD core golden check (the Kotlin twin of ios/VFDCheck/main.swift): replays
// tools/vfd/golden/ops.txt with VFDCore / VFDWidgets and compares every result line with
// tools/vfd/golden/expected.txt, which tools/vfd/golden.py writes from the Python reference (the
// file format is documented at the top of golden.py).
//
//   ./gradlew testDebugUnitTest --tests 'com.magicmaker.android.ui.vfd.*'
//
// The golden folder is found relative to the Gradle module (android/app -> ../../tools/vfd/golden),
// else by searching upward; -Dvfd.golden=DIR or VFD_GOLDEN_DIR=DIR overrides it. VFD_DUMP_DIR=DIR
// (or -Dvfd.dump=DIR) writes the same per-page dumps as `golden.py --dump DIR`, for diffing.

private const val NONE_FIELD: String = "\\N"

// MARK: - Field encoding (golden.py esc / unesc / split_list)

private fun esc(s: String): String {
    val out = StringBuilder(s.length)
    for (ch in s) {
        when (ch) {
            '\\' -> out.append("\\\\")
            '\t' -> out.append("\\t")
            '\n' -> out.append("\\n")
            else -> out.append(ch)
        }
    }
    return out.toString()
}

private fun escElem(s: String): String {
    val out = StringBuilder()
    for (ch in esc(s)) {
        if (ch == ',') out.append('\\')
        out.append(ch)
    }
    return if (out.isEmpty()) "\\e" else out.toString()
}

private fun unesc(s: String): String {
    val a: IntArray = VFDText.scalars(s)
    val out = StringBuilder(s.length)
    var i = 0
    while (i < a.size) {
        val ch: Int = a[i]
        if (ch == '\\'.code && i + 1 < a.size) {
            when (val nx: Int = a[i + 1]) {
                'n'.code -> out.append('\n')
                't'.code -> out.append('\t')
                'e'.code -> {} // an empty list element: nothing
                else -> out.appendCodePoint(nx)
            }
            i += 2
            continue
        }
        out.appendCodePoint(ch)
        i += 1
    }
    return out.toString()
}

/** Raw (still escaped) elements of a list field. */
private fun splitList(field: String): List<String> {
    if (field.isEmpty()) return emptyList()
    val a: IntArray = VFDText.scalars(field)
    val parts = ArrayList<String>()
    val cur = StringBuilder()
    var i = 0
    while (i < a.size) {
        val ch: Int = a[i]
        if (ch == '\\'.code && i + 1 < a.size) {
            cur.appendCodePoint(ch)
            cur.appendCodePoint(a[i + 1])
            i += 2
            continue
        }
        if (ch == ','.code) {
            parts.add(cur.toString())
            cur.setLength(0)
        } else {
            cur.appendCodePoint(ch)
        }
        i += 1
    }
    parts.add(cur.toString())
    return parts
}

/** s split on every sep character, empty pieces kept (Swift splitOn / Python str.split). */
private fun splitOn(s: String, sep: Char): List<String> {
    val parts = ArrayList<String>()
    var start = 0
    while (true) {
        val i: Int = s.indexOf(sep, start)
        if (i < 0) break
        parts.add(s.substring(start, i))
        start = i + 1
    }
    parts.add(s.substring(start))
    return parts
}

private fun encInts(values: List<Int>): String = values.joinToString(",")

private fun encStrs(values: List<String>): String = values.joinToString(",") { escElem(it) }

private fun zeroPad3(n: Int): String = n.toString().padStart(3, '0')

private fun fnv1a64(bytes: ByteArray): String {
    var h: Long = 0xCBF29CE484222325uL.toLong()
    val prime: Long = 0x100000001B3L
    for (b in bytes) {
        h = (h xor (b.toLong() and 0xFF)) * prime
    }
    return java.lang.Long.toUnsignedString(h, 16).padStart(16, '0')
}

private fun tapsText(fb: VFDFrameBuffer): String {
    val sb = StringBuilder()
    for (t in fb.taps) {
        sb.append(t.c).append(' ').append(t.r).append(' ').append(t.w).append(' ').append(t.h).append(' ')
            .append(t.name).append('\n')
    }
    return sb.toString()
}

/** What an op returned. */
private sealed class Ret {
    object None : Ret()
    class IntV(val n: Int) : Ret()
    /** Already encoded (strings, lists, bools). */
    class Text(val s: String) : Ret()

    val encoded: String
        get() = when (this) {
            is None -> NONE_FIELD
            is IntV -> n.toString()
            is Text -> s
        }
}

private fun retStr(s: String?): Ret = if (s != null) Ret.Text(esc(s)) else Ret.None

// MARK: - Op arguments

private class Args(val f: List<String>, val fb: VFDFrameBuffer) {
    fun raw(i: Int): String = if (i < f.size) f[i] else ""
    fun isNone(i: Int): Boolean = raw(i) == NONE_FIELD
    fun int(i: Int): Int = raw(i).toIntOrNull() ?: 0
    fun optInt(i: Int): Int? = if (isNone(i)) null else int(i)
    fun dbl(i: Int): Double = raw(i).toDoubleOrNull() ?: 0.0
    fun optDbl(i: Int): Double? = if (isNone(i)) null else dbl(i)
    fun bool(i: Int): Boolean = raw(i) == "1"
    fun optBool(i: Int): Boolean? = if (isNone(i)) null else bool(i)
    fun str(i: Int): String = unesc(raw(i))
    fun optStr(i: Int): String? = if (isNone(i)) null else str(i)
    fun size(i: Int): VFDSize = VFDSize.named(raw(i)) ?: VFDSize.small

    /** An ink index, or "#RRGGBB" allocated with fb.rgb() now. */
    fun color(i: Int): Int {
        val s: String = raw(i)
        if (s.startsWith("#")) {
            return fb.rgb(VFDRGB(hex = s))
        }
        return VFDMath.clamp(s.toIntOrNull() ?: 0, 0, 255)
    }

    fun optColor(i: Int): Int? = if (isNone(i)) null else color(i)
    fun rgb(i: Int): VFDRGB = VFDRGB(hex = raw(i))
    fun optRGB(i: Int): VFDRGB? = if (isNone(i)) null else rgb(i)

    fun strs(i: Int): List<String> = splitList(raw(i)).map { unesc(it) }

    fun dbls(i: Int): List<Double?> = splitList(raw(i)).map { e ->
        if (e == NONE_FIELD) null else (e.toDoubleOrNull() ?: 0.0)
    }

    fun optBools(i: Int): List<Boolean>? {
        if (isNone(i)) return null
        return splitList(raw(i)).map { it == "1" }
    }

    fun zone(i: Int): Pair<Double, Double>? {
        if (isNone(i)) return null
        val parts: List<String> = splitList(raw(i))
        if (parts.size != 2) return null
        return Pair(parts[0].toDoubleOrNull() ?: 0.0, parts[1].toDoubleOrNull() ?: 0.0)
    }

    private fun tagged(i: Int): Pair<String, String>? {
        val a: IntArray = VFDText.scalars(raw(i))
        if (a.size < 2) return null
        return Pair(String(a, 0, 2), String(a, 2, a.size - 2))
    }

    /** options() selection: the item at index k is selected when k is in the set, or its raw text
     *  or upper() is. */
    fun sel(i: Int, items: List<String>): Set<Int> {
        val out = HashSet<Int>()
        if (isNone(i)) return out
        val t: Pair<String, String> = tagged(i) ?: return out
        val names = ArrayList<String>()
        when (t.first) {
            "i:" -> {
                t.second.toIntOrNull()?.let { out.add(it) }
                return out
            }
            "I:" -> {
                for (e in splitList(t.second)) {
                    e.toIntOrNull()?.let { out.add(it) }
                }
                return out
            }
            "s:" -> names.add(unesc(t.second))
            "S:" -> for (e in splitList(t.second)) names.add(unesc(e))
        }
        var k = 0
        for (item in items) {
            val up: String = VFDW.upper(item)
            for (nm in names) {
                if (item == nm || up == nm) out.add(k)
            }
            k += 1
        }
        return out
    }

    /** buttons() primary / alarm: an index, or the index of the first button with that label. */
    fun pick(i: Int, labels: List<String>): Int? {
        if (isNone(i)) return null
        val t: Pair<String, String> = tagged(i) ?: return null
        if (t.first == "i:") return t.second.toIntOrNull()
        if (t.first == "s:") {
            val name: String = unesc(t.second)
            var k = 0
            for (lab in labels) {
                if (lab == name) return k
                k += 1
            }
        }
        return null
    }
}

// MARK: - Pages and blocks

private class Page(val name: String, val deviceKey: String, val device: VFDDevice, val base: VFDBase, header: String) {
    val L: VFDLayout = VFDLayout(device)
    var fb: VFDFrameBuffer = device.framebuffer(base)
    val lines: MutableList<String> = mutableListOf(header)
}

private class BlockOp(val line: Int, val op: String, val fields: List<String>)

private class Block(val open: String, val fields: List<String>) {
    val ops: MutableList<BlockOp> = ArrayList()
}

private fun layoutValues(L: VFDLayout): List<Int> {
    return listOf(
        L.cols, L.rows, L.safeTop, L.safeEnd, L.left, L.right, L.width, L.tapRows,
        L.headerTop, L.titleRow, L.headerTextRow, L.telemetryRow, L.headerRule, L.contentTop,
        L.tabRows[0], L.tabRows[1], L.tabRule, L.contentBottom, L.contentH, L.tabH, L.tabCellW, L.tabLeft,
    )
}

/** golden.CONSTANTS in order, then the number of tabs. */
private fun constantValues(): List<Int> {
    return listOf(
        VFDW.margin, VFDW.ctrlH, VFDW.ctrlText, VFDW.fieldH, VFDW.gap, VFDW.line,
        VFDW.labelH, VFDW.groupGap, VFDW.sectionGap, VFDW.sectionH, VFDW.tapRows, VFDW.stepW,
        VFDW.optGap, VFDW.tabH, VFDW.switchW, VFDW.adv, VFDW.nPatterns, VFDW.tabCols,
        VFDW.loopLastStop, VFDFrameBuffer.ledBarH, VFDInk.count, VFDInk.firstTrueColor,
        VFDInk.maxTrueColors, VFDW.tabs.size,
    )
}

// MARK: - Replay

private class Checker {
    val out: MutableList<String> = ArrayList()
    val pages: MutableList<Page> = ArrayList()
    val errors: MutableList<String> = ArrayList()
    var opCount: Int = 0
    var page: Page? = null
    var block: Block? = null

    fun runOp(op: String, a: Args, p: Page): Ret {
        val fb: VFDFrameBuffer = a.fb
        val L: VFDLayout = p.L
        when (op) {
            // FrameBuffer
            "clear" -> fb.clear(a.color(0))
            "set" -> {
                val k: Int = a.color(2)
                fb.set(a.int(0), a.int(1), k)
            }
            "get" -> return Ret.IntV(fb.get(a.int(0), a.int(1)))
            "fill" -> {
                val k: Int = a.color(4)
                fb.fill(a.int(0), a.int(1), a.int(2), a.int(3), k)
            }
            "hline" -> {
                val k: Int = a.color(3)
                fb.hline(a.int(0), a.int(1), a.int(2), k, step = a.int(4))
            }
            "vline" -> {
                val k: Int = a.color(3)
                fb.vline(a.int(0), a.int(1), a.int(2), k, step = a.int(4))
            }
            "box" -> {
                val k: Int = a.color(4)
                fb.box(a.int(0), a.int(1), a.int(2), a.int(3), k)
            }
            "text" -> {
                val k: Int = a.color(4)
                return Ret.IntV(fb.text(a.int(0), a.int(1), a.str(2), a.size(3), k))
            }
            "text_right" -> {
                val k: Int = a.color(4)
                return Ret.IntV(fb.textRight(a.int(0), a.int(1), a.str(2), a.size(3), k))
            }
            "text_fit" -> {
                val k: Int = a.color(5)
                return Ret.IntV(fb.textFit(a.int(0), a.int(1), a.str(2), a.int(3), a.size(4), k))
            }
            "paragraph" -> {
                val k: Int = a.color(5)
                return Ret.IntV(fb.paragraph(a.int(0), a.int(1), a.str(2), a.int(3), a.size(4), k, line = a.optInt(6)))
            }
            "inverted" -> {
                val k: Int = a.color(5)
                return Ret.IntV(fb.inverted(a.int(0), a.int(1), a.str(2), a.size(3), pad = a.int(4), color = k))
            }
            "alarm" -> return Ret.IntV(fb.alarm(a.int(0), a.int(1), a.str(2), a.size(3), pad = a.int(4)))
            "led_bar" -> {
                val k: Int = a.color(4)
                val track: Int = a.color(5)
                return Ret.IntV(fb.ledBar(a.int(0), a.int(1), a.int(2), a.dbl(3), color = k, track = track,
                                          marker = a.bool(6), zone = a.zone(7)))
            }
            "line_chart" -> {
                val values: List<Double?> = a.dbls(4)
                val k: Int = a.color(5)
                val vmin: Double? = a.optDbl(6)
                val vmax: Double? = a.optDbl(7)
                val baseline: Int? = a.optColor(8)
                return Ret.IntV(fb.lineChart(a.int(0), a.int(1), a.int(2), a.int(3), values, color = k, vmin = vmin,
                                             vmax = vmax, baseline = baseline))
            }
            "push_clip" -> fb.pushClip(a.int(0), a.int(1), a.int(2), a.int(3), dy = a.int(4))
            "pop_clip" -> fb.popClip()
            "tap" -> fb.tap(a.int(0), a.int(1), a.int(2), a.int(3), name = a.str(4))
            "hit" -> return retStr(fb.hit(a.int(0), a.int(1))?.name)
            "scroll_region" -> fb.scrollRegion(id = a.str(0), c = a.int(1), r = a.int(2), w = a.int(3), h = a.int(4),
                                               contentRows = a.int(5))
            "scroll_region_at" -> return retStr(fb.scrollRegionAt(a.int(0), a.int(1))?.id)
            "rgb" -> return Ret.IntV(fb.rgb(a.rgb(0)))
            "rgb_fill" -> {
                val index: Int = fb.rgb(a.rgb(4))
                fb.fill(a.int(0), a.int(1), a.int(2), a.int(3), index)
                return Ret.IntV(index)
            }
            "state" -> {
                val clip: VFDRect = fb.clipRect
                return Ret.Text(encInts(listOf(fb.originY, clip.c, clip.r, clip.w, clip.h, fb.clipDepth)))
            }
            "checkpoint" -> {
                val cells: String = fnv1a64(fb.cells)
                val taps: String = fnv1a64(tapsText(fb).toByteArray(Charsets.UTF_8))
                return Ret.Text(cells + "," + fb.taps.size + "," + taps + "," + fb.trueColors.size)
            }

            // text and palette helpers
            "text_width" -> return Ret.IntV(VFDText.width(a.str(0), size = a.size(1)))
            "max_chars" -> return Ret.IntV(VFDText.maxChars(a.int(0), size = a.size(1)))
            "fit_text" -> return Ret.Text(esc(VFDText.fit(a.str(0), a.int(1), size = a.size(2))))
            "wrap_text" -> return Ret.Text(encStrs(VFDText.wrap(a.str(0), a.int(1), size = a.size(2))))
            "round" -> return Ret.IntV(VFDMath.roundHalfAway(a.dbl(0)))
            "palette" -> {
                val hexes: List<String> = VFDPalette.colors(VFDBase(persisted = a.str(0))).map { it.hex }
                return Ret.Text(encStrs(hexes))
            }
            "alarm_inverted" -> return Ret.Text(if (VFDPalette.alarmInverted(VFDBase(persisted = a.str(0)))) "1" else "0")
            "metrics" -> {
                val s: VFDSize = a.size(0)
                return Ret.Text(encInts(listOf(s.w, s.h, s.ascent, s.advance, s.line)))
            }

            // widgets
            "constants" -> return Ret.Text(encInts(constantValues()))
            "group_top" -> return Ret.IntV(VFDW.groupTop(L, a.int(0)))
            "upper" -> return Ret.Text(esc(VFDW.upper(a.str(0))))
            "cx" -> return Ret.IntV(VFDW.cx(a.int(0), a.int(1), a.str(2), a.size(3)))
            "wtap" -> VFDW.tap(fb, a.int(0), a.int(1), a.int(2), a.int(3), a.optStr(4), minH = a.int(5))
            "badge" -> {
                val k: Int = a.color(3)
                return Ret.IntV(VFDW.badge(fb, a.int(0), a.int(1), a.str(2), k))
            }
            "alarm_text" -> return Ret.IntV(VFDW.alarmText(fb, a.int(0), a.int(1), a.str(2), right = a.bool(3)))
            "tag_box" -> {
                val k: Int = a.color(3)
                val tk: Int = a.color(4)
                return Ret.IntV(VFDW.tagBox(fb, a.int(0), a.int(1), a.str(2), color = k, textColor = tk))
            }
            "chevron" -> {
                val k: Int = a.color(3)
                VFDW.chevron(fb, a.int(0), a.int(1), a.bool(2), k)
            }
            "chevron_up" -> {
                val k: Int = a.color(2)
                VFDW.chevronUp(fb, a.int(0), a.int(1), k)
            }
            "step_button" -> VFDW.stepButton(fb, a.int(0), a.int(1), a.bool(2), a.bool(3), a.optStr(4))
            "layout" -> return Ret.Text(encInts(layoutValues(L)))
            "x" -> return Ret.IntV(L.x(a.dbl(0)))
            "split" -> {
                val flat = ArrayList<Int>()
                for (s in L.split(a.int(0), gap = a.int(1), c = a.optInt(2), w = a.optInt(3))) {
                    flat.add(s.c)
                    flat.add(s.w)
                }
                return Ret.Text(encInts(flat))
            }
            "tab_cell" -> {
                val t: VFDRect = L.tabCell(a.int(0))
                return Ret.Text(encInts(listOf(t.c, t.r, t.w, t.h)))
            }
            "tab_label" -> return Ret.Text(esc(L.tabLabel(a.str(0))))
            "tab_key" -> return retStr(VFDW.tabKey(a.str(0)))
            "header" -> {
                val k: Int = a.color(3)
                return Ret.IntV(VFDW.header(fb, L, a.str(0), back = a.bool(1), right = a.optStr(2), rightColor = k,
                                            rightTap = a.optStr(4)))
            }
            "telemetry" -> return Ret.IntV(VFDW.telemetry(fb, L, a.str(0)))
            "tab_bar" -> VFDW.tabBar(fb, L, selected = a.str(0))
            "frame" -> {
                val k: Int = a.color(5)
                VFDW.frame(fb, L, tab = a.str(0), title = a.str(1), telemetry = a.str(2), back = a.bool(3),
                           right = a.optStr(4), rightColor = k, scroll = a.int(6), rightTap = a.optStr(7))
            }
            "end_frame" -> VFDW.endFrame(fb)
            "scrollbar" -> VFDW.scrollbar(fb, L, a.int(0), scroll = a.int(1))
            "section" -> return Ret.IntV(VFDW.section(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), count = a.optInt(4),
                                                      collapsed = a.optBool(5), right = a.optStr(6),
                                                      name = a.optStr(7)))
            "label" -> {
                val k: Int = a.color(4)
                return Ret.IntV(VFDW.label(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), color = k, group = a.bool(5)))
            }
            "text_block" -> {
                val k: Int = a.color(4)
                return Ret.IntV(VFDW.textBlock(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), color = k,
                                               upper = a.bool(5)))
            }
            "status_line" -> {
                val k: Int = a.color(4)
                return Ret.IntV(VFDW.statusLine(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), color = k,
                                                banner = a.bool(5), name = a.optStr(6)))
            }
            "kv" -> {
                val k: Int = a.color(5)
                return Ret.IntV(VFDW.kv(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), a.optStr(4), color = k,
                                        leader = a.bool(6)))
            }
            "hero" -> {
                val k: Int = a.color(6)
                return Ret.IntV(VFDW.hero(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), a.str(4), size = a.size(5),
                                          color = k, sub = a.optStr(7)))
            }
            "divider" -> {
                val k: Int = a.color(4)
                return Ret.IntV(VFDW.divider(fb, L, a.int(0), a.int(1), a.int(2), dotted = a.bool(3), color = k))
            }
            "panel_inner" -> {
                val pi: VFDPanelInner = VFDW.panelInner(a.int(0), a.int(1), a.int(2), title = a.bool(3))
                return Ret.Text(encInts(listOf(pi.c, pi.r, pi.w)))
            }
            "panel" -> {
                val k: Int = a.color(5)
                return Ret.IntV(VFDW.panel(fb, L, a.int(0), a.int(1), a.int(2), a.int(3), title = a.optStr(4), color = k))
            }
            "toggle" -> {
                val k: Int = a.color(7)
                return Ret.IntV(VFDW.toggle(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), a.bool(4),
                                            enabled = a.bool(5), name = a.optStr(6), labelColor = k))
            }
            "options" -> {
                val items: List<String> = a.strs(3)
                val selected: Set<Int> = a.sel(4, items)
                return Ret.IntV(VFDW.options(fb, L, a.int(0), a.int(1), a.int(2), items, selected = selected,
                                             label = a.optStr(5), enabled = a.bool(6), name = a.optStr(7),
                                             columns = a.optInt(8)))
            }
            "stepper" -> return Ret.IntV(VFDW.stepper(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), a.str(4),
                                                      enabled = a.bool(5), canDec = a.bool(6), canInc = a.bool(7),
                                                      valueChars = a.optInt(8), name = a.optStr(9)))
            "button" -> return Ret.IntV(VFDW.button(fb, L, a.int(0), a.int(1), a.optInt(2), a.str(3),
                                                    primary = a.bool(4), enabled = a.bool(5), name = a.optStr(6),
                                                    alarm = a.bool(7)))
            "buttons" -> {
                val labels: List<String> = a.strs(3)
                val primary: Int? = a.pick(4, labels)
                val enabled: List<Boolean>? = a.optBools(5)
                val alarm: Int? = a.pick(8, labels)
                return Ret.IntV(VFDW.buttons(fb, L, a.int(0), a.int(1), a.int(2), labels, primary = primary,
                                             enabled = enabled, gap = a.int(6), equal = a.bool(7), alarm = alarm))
            }
            "slider" -> return Ret.IntV(VFDW.slider(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), a.str(4), a.dbl(5),
                                                    hint = a.optStr(6), enabled = a.bool(7), zone = a.zone(8),
                                                    marker = a.bool(9), name = a.optStr(10), canDec = a.optBool(11),
                                                    canInc = a.optBool(12)))
            "meter" -> {
                val k: Int = a.color(8)
                return Ret.IntV(VFDW.meter(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), a.str(4), a.dbl(5),
                                           zone = a.zone(6), marker = a.bool(7), color = k))
            }
            "field" -> {
                val k: Int = a.color(8)
                return Ret.IntV(VFDW.field(fb, L, a.int(0), a.int(1), a.int(2), a.optStr(3), a.str(4),
                                           placeholder = a.str(5), focused = a.bool(6), name = a.optStr(7),
                                           valueColor = k))
            }
            "packet_row" -> {
                val k: Int = a.color(10)
                return Ret.IntV(VFDW.packetRow(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), a.str(4),
                                               subtitle = a.str(5), tag = a.optStr(6), selected = a.bool(7),
                                               right = a.optStr(8), name = a.optStr(9), hexColor = k))
            }
            "chart" -> {
                val values: List<Double?> = a.dbls(5)
                val k: Int = a.color(9)
                return Ret.IntV(VFDW.chart(fb, L, a.int(0), a.int(1), a.int(2), a.int(3), a.optStr(4), values,
                                           valueText = a.optStr(6), vmin = a.optDbl(7), vmax = a.optDbl(8), color = k))
            }
            "list_scrollbar" -> VFDW.listScrollbar(fb, a.int(0), a.int(1), a.int(2), a.int(3))
            "token_lines" -> return Ret.Text(encStrs(VFDW.tokenLines(a.str(0), a.int(1), sep = a.str(2))))
            "interval_stop" -> return Ret.IntV(VFDW.intervalStop(a.dbl(0)))
            "interval_text" -> return Ret.Text(esc(VFDW.intervalText(a.dbl(0))))
            "interval_slider" -> return Ret.IntV(VFDW.intervalSlider(fb, L, a.int(0), a.int(1), a.int(2), a.str(3),
                                                                     a.dbl(4), name = a.str(5)))
            "menu_button" -> return Ret.IntV(VFDW.menuButton(fb, L, a.int(0), a.int(1), a.str(2), enabled = a.bool(3),
                                                             name = a.optStr(4)))
            "led" -> {
                val k: Int = a.color(4)
                VFDW.led(fb, a.int(0), a.int(1), a.optInt(2), size = a.int(3), color = k, fill = a.optRGB(5))
            }
            else -> {
                errors.add("unknown op $op")
                return Ret.Text("ERROR unknown op $op")
            }
        }
        return Ret.None
    }

    /** Run a block's ops on target; returns the last int an op returned. */
    fun replay(ops: List<BlockOp>, target: VFDFrameBuffer, p: Page): Int? {
        var last: Int? = null
        for (o in ops) {
            val r: Ret = runOp(o.op, Args(o.fields, target), p)
            if (r is Ret.IntV) {
                last = r.n
            }
        }
        return last
    }

    fun closeBlock(b: Block, op: String, raw: List<String>, p: Page): Ret {
        if (op == "window_end") {
            val ends = Args(raw, p.fb)
            val win: VFDWindow = VFDW.snappedWindow(p.fb, top = ends.int(0), bottom = ends.int(1)) { target ->
                replay(b.ops, target, p)
            }
            return Ret.Text(encInts(listOf(win.top, win.bottom)))
        }
        // screen_end: render_previews.draw_screen with the block as the screen's draw()
        val a = Args(b.fields, p.fb)
        val tabRaw: String = a.str(0)
        val tab: String = VFDW.tabKey(tabRaw) ?: tabRaw
        var title: String = a.str(1)
        if (title.isEmpty()) {
            for (t in VFDW.tabs) {
                if (t.key == tab) title = t.label
            }
        }
        val rightColor: Int = VFDMath.clamp(a.raw(5).toIntOrNull() ?: 0, 0, 255)
        val spec: String = unesc(raw.firstOrNull() ?: "none")
        val fb: VFDFrameBuffer = p.device.framebuffer(p.base)
        val end: Int? = VFDW.drawScreen(fb, p.L, tab = tab, title = title, telemetry = a.str(2), back = a.bool(3),
                                        right = a.optStr(4), rightColor = rightColor, rightTap = a.optStr(6),
                                        scroll = a.int(7)) { target, _ ->
            val last: Int? = replay(b.ops, target, p)
            when (spec) {
                "last" -> last
                "none" -> null
                else -> spec.toIntOrNull()
            }
        }
        p.fb = fb
        return if (end != null) Ret.IntV(end) else Ret.None
    }

    fun finish() {
        val p: Page = page ?: return
        val fb: VFDFrameBuffer = p.fb
        val hexes: List<String> = fb.trueColors.map { it.hex }
        p.lines.add("colors\t" + fb.trueColors.size + "\t" + encStrs(hexes))
        for (t in fb.taps) {
            p.lines.add("hit\t${t.c}\t${t.r}\t${t.w}\t${t.h}\t" + esc(t.name))
        }
        for (g in fb.scrollRegions) {
            p.lines.add("region\t" + esc(g.id) + "\t${g.c}\t${g.r}\t${g.w}\t${g.h}\t${g.contentRows}")
        }
        var lit = 0
        for (v in fb.cells) {
            if (v.toInt() != 0) lit += 1
        }
        p.lines.add("cells\t" + fnv1a64(fb.cells) + "\t" + lit)
        p.lines.add("end\t" + esc(p.name))
        out.addAll(p.lines)
        pages.add(p)
        page = null
    }

    fun run(lines: List<String>) {
        var no = 0
        for (line in lines) {
            no += 1
            if (line.isEmpty() || line.startsWith("#")) continue
            val fields: List<String> = splitOn(line, '\t')
            val op: String = fields[0]
            if (op == "page") {
                if (block != null) {
                    errors.add("line $no: page inside a block")
                    block = null
                }
                finish()
                val name: String = if (fields.size > 1) unesc(fields[1]) else ""
                val devKey: String = if (fields.size > 2) fields[2] else ""
                val baseRaw: String = if (fields.size > 3) fields[3] else "AMBER"
                val dev: VFDDevice? = VFDDevice.named(devKey)
                if (dev == null) {
                    errors.add("line $no: unknown device $devKey")
                    continue
                }
                val rawName: String = if (fields.size > 1) fields[1] else ""
                val header: String = listOf("page", rawName, devKey, baseRaw).joinToString("\t")
                page = Page(name, devKey, dev, VFDBase(persisted = unesc(baseRaw)), header)
                continue
            }
            val p: Page? = page
            if (p == null) {
                errors.add("line $no: op before the first page")
                continue
            }
            val raw: List<String> = fields.drop(1)
            val b: Block? = block
            if (b != null) {
                val closes: Boolean = (b.open == "window_begin" && op == "window_end") ||
                    (b.open == "screen_begin" && op == "screen_end")
                if (closes) {
                    block = null
                    val value: Ret = closeBlock(b, op, raw, p)
                    p.lines.add("ret\t$no\t$op\t" + value.encoded)
                } else {
                    b.ops.add(BlockOp(no, op, raw))
                }
                continue
            }
            if (op == "window_begin" || op == "screen_begin") {
                block = Block(op, raw)
                continue
            }
            opCount += 1
            val value: Ret = runOp(op, Args(raw, p.fb), p)
            p.lines.add("ret\t$no\t$op\t" + value.encoded)
        }
        if (block != null) {
            errors.add("unterminated block at the end of ops.txt")
        }
        finish()
    }

    fun writeDumps(folder: File) {
        if (!folder.isDirectory && !folder.mkdirs()) {
            println("NOTE: cannot create $folder")
            return
        }
        val alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        var index = 0
        for (p in pages) {
            index += 1
            val fb: VFDFrameBuffer = p.fb
            val text = StringBuilder()
            text.append(p.lines.joinToString("\n")).append("\n")
            text.append("grid\t${fb.cols}\t${fb.rows}\n")
            for (r in 0 until fb.rows) {
                text.append(zeroPad3(r)).append(' ')
                for (c in 0 until fb.cols) {
                    val v: Int = fb.get(c, r)
                    when {
                        v == 0 -> text.append('.')
                        v < 5 -> text.append(('0'.code + v).toChar())
                        else -> text.append(alphabet[(v - 5) % alphabet.length])
                    }
                }
                text.append('\n')
            }
            val file = File(folder, zeroPad3(index) + "_" + p.name + "_" + p.deviceKey + ".txt")
            file.writeText(text.toString(), Charsets.UTF_8)
        }
        println("NOTE: wrote ${pages.size} page dumps to $folder")
    }
}

// MARK: - Locating the golden files

private fun goldenDir(): File {
    val override: String? = System.getProperty("vfd.golden") ?: System.getenv("VFD_GOLDEN_DIR")
    if (!override.isNullOrEmpty()) return File(override)
    val direct = File("../../tools/vfd/golden")
    if (File(direct, "ops.txt").isFile) return direct
    var dir: File? = File("").absoluteFile
    while (dir != null) {
        val candidate = File(dir, "tools/vfd/golden")
        if (File(candidate, "ops.txt").isFile && File(candidate, "expected.txt").isFile) return candidate
        dir = dir.parentFile
    }
    return direct
}

private fun clipText(s: String, n: Int): String {
    val a: IntArray = VFDText.scalars(s)
    if (a.size <= n) return s
    return String(a, 0, n) + "…"
}

class VFDGoldenTest {
    @Test
    fun coreMatchesPythonReference() {
        val dir: File = goldenDir()
        val opsFile = File(dir, "ops.txt")
        val expectedFile = File(dir, "expected.txt")
        assertTrue("VFD: cannot read ${opsFile.absolutePath} (run from android/app or set VFD_GOLDEN_DIR)",
                   opsFile.isFile)
        assertTrue("VFD: cannot read ${expectedFile.absolutePath}", expectedFile.isFile)
        val opsText: String = opsFile.readText(Charsets.UTF_8)
        val expectedText: String = expectedFile.readText(Charsets.UTF_8)

        val checker = Checker()
        checker.run(splitOn(opsText, '\n'))
        val dump: String? = System.getProperty("vfd.dump") ?: System.getenv("VFD_DUMP_DIR")
        if (!dump.isNullOrEmpty()) {
            checker.writeDumps(File(dump))
        }

        val want = ArrayList<Pair<Int, String>>()
        var lineNo = 0
        for (l in splitOn(expectedText, '\n')) {
            lineNo += 1
            if (l.isEmpty() || l.startsWith("#")) continue
            want.add(Pair(lineNo, l))
        }

        val got: List<String> = checker.out
        val report = StringBuilder()
        var mismatches = 0
        var currentPage = ""
        val total: Int = maxOf(want.size, got.size)
        for (i in 0 until total) {
            val w: String = if (i < want.size) want[i].second else "<missing>"
            val g: String = if (i < got.size) got[i] else "<missing>"
            if (w.startsWith("page\t")) {
                currentPage = w.replace("\t", " ")
            }
            if (w != g) {
                mismatches += 1
                if (mismatches <= 30) {
                    val at: Int = if (i < want.size) want[i].first else 0
                    report.append("MISMATCH expected.txt:$at [$currentPage] want: ${clipText(w, 240)} | got: ")
                        .append(clipText(g, 240)).append('\n')
                }
            }
        }
        for (e in checker.errors.take(20)) {
            report.append("MISMATCH error: ").append(e).append('\n')
        }
        val summary = "VFD: ${checker.pages.size} pages, ${checker.opCount} ops, ${want.size} expected lines, " +
            "$mismatches mismatching, ${checker.errors.size} errors"
        println(summary)
        if (mismatches > 0 || checker.errors.isNotEmpty() || want.isEmpty()) {
            fail(summary + "\n" + report.toString())
        }
    }

    @Test
    fun clearRefillsInPlace() {
        val fb = VFDDevice.pro.framebuffer(VFDBase.amber)
        val cells: ByteArray = fb.cells
        fb.fill(0, 0, 10, 10, VFDInk.highlight)
        fb.rgb(VFDRGB(1, 2, 3))
        fb.tap(0, 0, 5, 5, name = "x")
        fb.wantsAnimation = true
        fb.clear()
        assertSame(cells, fb.cells)
        assertEquals(0, fb.get(3, 3))
        assertEquals(0, fb.taps.size)
        assertEquals(0, fb.trueColors.size)
        assertEquals(false, fb.wantsAnimation)
        assertEquals(VFDInk.firstTrueColor, fb.rgb(VFDRGB(9, 9, 9)))
        fb.clear(VFDInk.dim)
        assertEquals(VFDInk.dim, fb.get(fb.cols - 1, fb.rows - 1))
    }

    @Test
    fun trueColoursDedupeAndSaturate() {
        val fb = VFDFrameBuffer(10, 10)
        val first: Int = fb.rgb(VFDRGB(hex = "#FF0000"))
        assertEquals(VFDInk.firstTrueColor, first)
        assertEquals(first, fb.rgb(VFDRGB(255, 0, 0)))
        for (i in 1 until VFDInk.maxTrueColors) {
            fb.rgb(VFDRGB(0, i, 0))
        }
        assertEquals(VFDInk.maxTrueColors, fb.trueColors.size)
        assertEquals(255, fb.rgb(VFDRGB(0, VFDInk.maxTrueColors - 1, 0)))
        // Table full: the nearest existing colour (pure red) is returned for a near-red.
        assertEquals(first, fb.rgb(VFDRGB(250, 3, 3)))
        assertEquals(VFDInk.maxTrueColors, fb.trueColors.size)
    }

    @Test
    fun drawScreenWithReusedProbeMatchesFreshProbe() {
        val device: VFDDevice = VFDDevice.x2
        val base: VFDBase = VFDBase.Preset("RED")
        val L = VFDLayout(device)
        var taps = 0
        val draw: (VFDFrameBuffer, VFDLayout) -> Int? = { fb, lay ->
            var r: Int = VFDW.section(fb, lay, lay.left, lay.contentTop, lay.width, "Devices", count = 7)
            for (i in 0 until 30) {
                r = VFDW.packetRow(fb, lay, lay.left, r, lay.width, "Band $i", "A1 B2 C3 $i", subtitle = "rssi -6$i",
                                   tag = if (i % 3 == 0) "new" else null, action = { taps += 1 })
            }
            VFDW.led(fb, lay.left, r, 0, size = 9, fill = VFDRGB(0x20, 0x80, 0xFF))
            VFDW.button(fb, lay, lay.left, r + 12, null, "Delete", alarm = true)
        }
        val fresh: VFDFrameBuffer = device.framebuffer(base)
        val endFresh: Int? = VFDW.drawScreen(fresh, L, tab = "scan", title = "SCAN", telemetry = "BLE ON | 3 BANDS",
                                             scroll = 37, draw = draw)
        val probe = VFDFrameBuffer(L.cols, L.rows)
        probe.fill(0, 0, 50, 50, VFDInk.alarm)
        probe.pushClip(3, 3, 10, 10, dy = 5)
        probe.tap(0, 0, 4, 4, name = "stale")
        val reused: VFDFrameBuffer = device.framebuffer(base)
        val endReused: Int? = VFDW.drawScreen(reused, L, tab = "scan", title = "SCAN", telemetry = "BLE ON | 3 BANDS",
                                              scroll = 37, probe = probe, draw = draw)
        assertEquals(endFresh, endReused)
        assertTrue(fresh.cells.contentEquals(reused.cells))
        assertEquals(fresh.taps.map { it.toString() }, reused.taps.map { it.toString() })
        assertEquals(fresh.trueColors, reused.trueColors)
        assertEquals(0, reused.clipDepth)
        // The topmost hit under a visible packet row runs its action.
        val row: VFDHit = reused.taps.first { it.name.startsWith("packet:") }
        reused.hit(row.c + 1, row.r + 1)?.action?.invoke()
        assertEquals(1, taps)
    }

    @Test
    fun argbExportUsesPaletteAndTrueColours() {
        val fb = VFDFrameBuffer(4, 2, VFDBase.Preset("CYAN"))
        fb.set(0, 0, VFDInk.highlight)
        fb.set(1, 0, VFDInk.dim)
        val tc: Int = fb.rgb(VFDRGB(unitRed = 1.0, green = 0.5, blue = 0.0))
        fb.set(2, 0, tc)
        val inks: List<VFDRGB> = VFDPalette.colors(fb.base)
        val px: IntArray = fb.argbPixels()
        assertEquals(inks[VFDInk.highlight].argb, px[0])
        assertEquals(inks[VFDInk.dim].argb, px[1])
        assertEquals(VFDRGB(255, 128, 0).argb, px[2])
        assertEquals(inks[VFDInk.unlit].argb, px[3])
        val rgba: ByteArray = fb.rgbaBytes()
        assertEquals(255, rgba[8].toInt() and 0xFF)
        assertEquals(128, rgba[9].toInt() and 0xFF)
        assertEquals(VFDInk.firstTrueColor, tc)
        assertEquals("135.\n....", fb.ascii())
        assertEquals(VFDText.width("AB", VFDSize.mid), 22)
        assertEquals(VFDSize.small.h, VFDText.glyphRows('A'.code, VFDSize.small).size)
        assertTrue(VFDText.glyphRows(0x1F600, VFDSize.big).contentEquals(VFDGlyphs.bigFallback))
    }

    @Test
    fun baseColourPersistence() {
        assertEquals(VFDBase.Preset("GREEN"), VFDBase(persisted = " green "))
        assertEquals(VFDBase.Custom(VFDRGB(0x12, 0x34, 0x56)), VFDBase.fromPersisted("#123456"))
        assertEquals(VFDBase.amber, VFDBase(persisted = "nonsense"))
        assertEquals("#123456", VFDBase.Custom(VFDRGB(hex = "123456")).persisted)
        assertEquals(VFDPalette.amber, VFDPalette.colors(VFDBase.amber))
        assertTrue(VFDPalette.alarmInverted(VFDBase.Preset("RED")))
        assertEquals(0xFFFFB014.toInt(), VFDBase.amberRGB.argb)
    }
}
