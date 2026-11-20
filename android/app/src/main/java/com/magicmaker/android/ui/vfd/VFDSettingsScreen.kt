package com.magicmaker.android.ui.vfd

import com.magicmaker.android.BuildConfig
import com.magicmaker.android.core.TransmitTiming
import com.magicmaker.android.data.MagicStore
import com.magicmaker.android.ui.UiPrefs
import kotlin.math.roundToInt

/**
 * SETTINGS tab in the VFD theme, exactly as tools/vfd/screens/settings.py draws it, on the
 * standard SettingsTabScreen's real values and actions: the screen note, APPEARANCE (THEME, then
 * BASE COLOUR with the stored colour's hex on its label row and a true-colour swatch in every
 * chip; CUSTOM opens the colour picker), TRANSMISSION SETTINGS (folds under the standard screen's
 * preference: TX MODE switch, BROADCAST STRENGTH, the WAKE SLICE / COMMAND BURST / STARLIGHT WAND
 * sliders, each with its hint), SCAN FILTER (the store's show-control filter, the same switch as
 * the SCAN tab's SHOW-CTRL / ALL RAW chip) and ABOUT (the installed version).
 * Port of ios/MagicMaker/VFD/VFDSettingsScreen.swift. Android itself transmits, so the iPhone's
 * relay note (changes sent to a linked Android relay) has no counterpart here.
 */
object VFDSettingsScreen : VFDScreen {
    override val title: String = "SETTINGS"

    const val headerNote: String = "Global transmission tuning — applies to every TX."
    val themes: List<String> = listOf("STANDARD", "VFD")

    override fun headerRight(ctx: VFDContext): VFDHeaderRight? = null

    override fun draw(ctx: VFDContext): Int? {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val c: Int = L.left
        val w: Int = L.width
        var y: Int = L.contentTop
        y = VFDW.textBlock(fb, L, c, y, w, headerNote, color = VFDInk.dim)
        y = appearance(ctx, c, y, w)
        y = transmission(ctx, c, y, w)
        y = scanFilter(ctx, c, y, w)
        y = about(ctx, c, y, w)
        return y
    }

    /** APPEARANCE: THEME [STANDARD] [VFD]; under VFD, BASE COLOUR (#RRGGBB right-aligned in
     *  highlight) and the chips, left-flowing like THEME. */
    fun appearance(ctx: VFDContext, c: Int, top: Int, w: Int): Int {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val settings: VFDSettings = ctx.settings
        var y: Int = VFDW.section(fb, L, c, top, w, "APPEARANCE")
        val themeIndex: Int = if (settings.theme == VFDTheme.vfd) 1 else 0
        y = VFDW.options(fb, L, c, y, w, themes, selected = themeIndex, label = "THEME", onSelect = { index ->
            settings.theme = if (index == 0) VFDTheme.standard else VFDTheme.vfd
        })
        if (settings.theme != VFDTheme.vfd) {
            return y
        }
        val r: Int = VFDW.groupTop(L, y)
        val hx: String = settings.base.rgb.hex
        val vw: Int = VFDText.width(hx)
        fb.text(c + w - vw, r, hx, VFDSize.small, VFDInk.highlight)
        fb.textFit(c, r, "BASE COLOUR", w - vw - 6, VFDSize.small, VFDInk.dim)
        return baseChips(ctx, c, r + VFDW.labelH, w)
    }

    /** The BASE COLOUR chips: VFDW.options geometry with one extra glyph slot after "[" holding a
     *  5 x 5 swatch of the chip's own colour (CUSTOM: the stored custom colour). The selected chip
     *  is the solid block with its name cut out and an unlit ring around the swatch. Taps
     *  "option:BASE COLOUR:<ITEM>". */
    fun baseChips(ctx: VFDContext, c: Int, top: Int, w: Int): Int {
        val fb: VFDFrameBuffer = ctx.fb
        val settings: VFDSettings = ctx.settings
        val items: List<String> = VFDSettings.baseItems
        val selected: Int = settings.baseIndex
        val adv: Int = VFDW.adv
        var x: Int = c
        var y: Int = top
        for ((i, item) in items.withIndex()) {
            var ow: Int = VFDText.width(count = VFDText.length(item) + 3)
            if (x > c && x + ow > c + w) {
                x = c
                y += VFDW.ctrlH + VFDW.gap
            }
            ow = minOf(ow, c + w - x)
            val shown: String = VFDText.fit(item, ow - 3 * adv)
            val fw: Int = VFDText.width(count = VFDText.length(shown) + 3)
            val ty: Int = y + VFDW.ctrlText
            if (i == selected) {
                fb.fill(x, y + 1, fw, VFDW.ctrlH - 2, VFDInk.highlight)
                fb.fill(x + adv - 1, ty, 7, 7, VFDInk.unlit)
                fb.text(x + 2 * adv, ty, shown, VFDSize.small, VFDInk.unlit)
            } else {
                fb.text(x, ty, "[", VFDSize.small, VFDInk.dim)
                fb.text(x + 2 * adv, ty, shown, VFDSize.small, VFDInk.text)
                fb.text(x + fw - 5, ty, "]", VFDSize.small, VFDInk.dim)
            }
            val swatch: Int = fb.rgb(settings.itemRGB(i))
            fb.fill(x + adv, ty + 1, 5, 5, swatch)
            val index: Int = i
            VFDW.tap(fb, x - VFDW.optGap / 2, y, ow + VFDW.optGap, VFDW.ctrlH, "option:BASE COLOUR:$item",
                     action = {
                         chooseBase(ctx, index)
                     })
            x += ow + VFDW.optGap
        }
        return y + VFDW.ctrlH + VFDW.gap
    }

    /** A preset applies at once; CUSTOM selects the stored custom colour and opens the picker. */
    fun chooseBase(ctx: VFDContext, index: Int) {
        val settings: VFDSettings = ctx.settings
        settings.selectBase(index)
        if (index >= VFDBase.presets.size) {
            ctx.pickColor("BASE COLOUR · CUSTOM", settings.customRGB) { rgb ->
                settings.selectCustom(rgb)
            }
        }
    }

    // MARK: - Transmission, scan filter, about

    /** settingsPowerNames: broadcast strength levels 0..3 (MagicStore.getTxPowerLevel). */
    private val powerNames: List<String> = listOf("MIN", "LOW", "MED", "MAX")
    private const val interleaveHint: String =
        "Alternates wake/command slices — lighter, good in-park. WAKE=slice, COMMAND=total window."
    private const val sustainedHint: String =
        "Sustained wake stream, then command stream — strongest wake. WAKE=wake length, COMMAND=command length."
    private const val strengthHint: String = "Lower = shorter range, fewer nearby bands react · default MAX"
    private const val filterHint: String =
        "Filter MagicBand/device noise out of the scan (default on); flip to see all raw."
    private const val sep: String = " · "

    /** TRANSMISSION SETTINGS (folds; chevron down when folded, up when open; the standard screen's
     *  UiPrefs flag): TX MODE, BROADCAST STRENGTH, WAKE SLICE / COMMAND BURST / STARLIGHT WAND. */
    private fun transmission(ctx: VFDContext, c: Int, top: Int, w: Int): Int {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val collapsed: Boolean = UiPrefs.isLabTransmissionSettingsCollapsed(ctx.context)
        var y: Int = disclosureHeader(fb, L, c, top, w, "TRANSMISSION SETTINGS", collapsed, action = {
            val folded: Boolean = UiPrefs.isLabTransmissionSettingsCollapsed(ctx.context)
            UiPrefs.saveLabTransmissionSettingsCollapsed(ctx.context, !folded)
            ctx.redraw()
        })
        if (collapsed) {
            return y
        }
        val store: MagicStore = ctx.store

        val interleave: Boolean = store.getTxInterleave()
        val mode: String = if (interleave) "TX MODE: INTERLEAVE" else "TX MODE: SUSTAINED"
        y = VFDW.toggle(fb, L, c, y, w, mode, interleave, name = "toggle:TX MODE", labelColor = VFDInk.highlight,
                        action = {
                            ctx.store.saveTxInterleave(!ctx.store.getTxInterleave())
                        })
        y = hint(fb, c, y, w, if (interleave) interleaveHint else sustainedHint)

        val power: Int = store.getTxPowerLevel()
        y = VFDW.options(fb, L, c, y, w, powerNames, selected = power, label = "BROADCAST STRENGTH",
                         columns = powerNames.size, onSelect = { level ->
                             ctx.store.saveTxPowerLevel(level)
                         })
        y = hint(fb, c, y, w, strengthHint)

        y = timingSlider(ctx, c, y, w, title = "WAKE SLICE MS", name = "slider:WAKE SLICE", key = "wakeSlice",
                         value = store.getWakeupPreambleMs(), low = TransmitTiming.MIN_WAKEUP_PRELUDE_MS,
                         high = TransmitTiming.MAX_WAKEUP_PRELUDE_MS, step = 50,
                         hintText = "Each wake/command slice in the 1:1 interleave · default " +
                             "${TransmitTiming.DEFAULT_WAKEUP_PRELUDE_MS}ms",
                         commit = { ms -> ctx.store.saveWakeupPreambleMs(ms) })
        y = timingSlider(ctx, c, y, w, title = "COMMAND BURST MS", name = "slider:COMMAND BURST",
                         key = "commandBurst", value = store.getCommandBurstMs(),
                         low = TransmitTiming.MIN_COMMAND_BURST_MS, high = TransmitTiming.MAX_COMMAND_BURST_MS,
                         step = 50,
                         hintText = "Total wake+command interleave window · default " +
                             "${TransmitTiming.COMMAND_BURST_MS}ms · global",
                         commit = { ms -> ctx.store.saveCommandBurstMs(ms) })
        // The standard slider has 18 inner stops over 250..5000 ms: one stop per 250 ms.
        y = timingSlider(ctx, c, y, w, title = "STARLIGHT WAND MS", name = "slider:STARLIGHT WAND",
                         key = "starlight", value = store.getStarlightBurstMs(),
                         low = TransmitTiming.MIN_STARLIGHT_BURST_MS, high = TransmitTiming.MAX_STARLIGHT_BURST_MS,
                         step = 250,
                         hintText = "On-air time for starlight wand TX · no band wakeup · default " +
                             "${TransmitTiming.STARLIGHT_BURST_MS}ms",
                         commit = { ms -> ctx.store.saveStarlightBurstMs(ms) })
        return y
    }

    /** SCAN FILTER: SHOW-CTRL / ALL RAW + switch (MagicStore.saveShowControlOnly, as the SCAN
     *  tab's filter chip), then the hint. */
    private fun scanFilter(ctx: VFDContext, c: Int, top: Int, w: Int): Int {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        var y: Int = VFDW.section(fb, L, c, top, w, "SCAN FILTER")
        val on: Boolean = ctx.store.getShowControlOnly()
        y = VFDW.toggle(fb, L, c, y, w, if (on) "SHOW-CTRL" else "ALL RAW", on, name = "toggle:SCAN FILTER",
                        labelColor = if (on) VFDInk.highlight else VFDInk.dim, action = {
                            ctx.store.saveShowControlOnly(!ctx.store.getShowControlOnly())
                        })
        return hint(fb, c, y, w, filterHint)
    }

    /** ABOUT: MAGICMAKER v<version> (<build>). */
    private fun about(ctx: VFDContext, c: Int, top: Int, w: Int): Int {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val y: Int = VFDW.section(fb, L, c, top, w, "ABOUT")
        fb.textFit(c, y, "MAGICMAKER " + appVersionText(), w, VFDSize.small, VFDInk.dim)
        return y + VFDW.line
    }

    /** "v1.3.13 (42)": the APK's version name (release builds carry the tag, already "v...") and
     *  version code. */
    private fun appVersionText(): String {
        val name: String = BuildConfig.VERSION_NAME.trim().ifEmpty { "?" }
        val shown: String = if (name.startsWith("v") || name.startsWith("V")) name else "v$name"
        return "$shown (${BuildConfig.VERSION_CODE})"
    }

    // MARK: drawing pieces

    /** TRANSMISSION SETTINGS: section() geometry with the up / down chevron (up when open); the
     *  whole line is the fold tap. */
    private fun disclosureHeader(fb: VFDFrameBuffer, L: VFDLayout, c: Int, top: Int, w: Int, title: String,
                                 collapsed: Boolean, action: () -> Unit): Int {
        var r: Int = top
        if (r > L.contentTop) {
            r += VFDW.sectionGap - VFDW.gap
        }
        if (collapsed) {
            VFDW.chevron(fb, c, r, false, VFDInk.dim)
        } else {
            VFDW.chevronUp(fb, c, r, VFDInk.dim)
        }
        val upperTitle: String = VFDW.upper(title)
        fb.textFit(c + 11, r, upperTitle, w - 11, VFDSize.small, VFDInk.highlight)
        fb.hline(c, r + 9, w, VFDInk.dim)
        VFDW.tap(fb, c, r - 3, w, 14, "section:$upperTitle", action = action)
        return r + VFDW.sectionH + VFDW.gap
    }

    /** A dim wrapped hint under a control (as given), 1 row lower: lines every `line` rows, then
     *  gap. Returns the next free row. */
    private fun hint(fb: VFDFrameBuffer, c: Int, y: Int, w: Int, s: String): Int {
        val lines: List<String> = wrapHint(s, w)
        if (lines.isEmpty()) return y
        for ((i, ln) in lines.withIndex()) {
            fb.text(c, y + 1 + i * VFDW.line, ln, VFDSize.small, VFDInk.dim)
        }
        return y + 1 + lines.size * VFDW.line + VFDW.gap
    }

    /** Word-wrap a hint whose clauses are joined by " · ": a clause that does not fit on the
     *  current line but fits a line of its own starts the next line; a longer clause is
     *  word-wrapped from where the line is. No line starts or ends with "·"; over-long words are
     *  hard-broken (settings.py wrap_hint). */
    private fun wrapHint(s: String, maxCols: Int): List<String> {
        val n: Int = VFDText.maxChars(maxCols)
        if (n <= 0) return emptyList()
        val sepLen: Int = VFDText.length(sep)
        val lines: MutableList<String> = ArrayList()
        var cur = ""
        for (clause in s.split(sep)) {
            val words: List<String> = clause.split(" ").filter { it.isNotEmpty() }
            if (words.isEmpty()) continue
            val text: String = words.joinToString(" ")
            val curLen: Int = VFDText.length(cur)
            val textLen: Int = VFDText.length(text)
            if (cur.isNotEmpty() && curLen + sepLen + textLen <= n) {
                cur += sep + text
                continue
            }
            if (cur.isNotEmpty() && textLen <= n) {
                lines.add(cur)
                cur = text
                continue
            }
            var first = true
            for (original in words) {
                val joint: String = if (first) sep else " "
                var word: IntArray = VFDText.scalars(original)
                val need: Int = VFDText.length(cur) + VFDText.length(joint) + word.size
                if (cur.isNotEmpty() && need <= n) {
                    cur += joint + original
                } else {
                    if (cur.isNotEmpty()) {
                        lines.add(cur)
                    }
                    while (word.size > n) {
                        lines.add(VFDText.string(word.copyOfRange(0, n)))
                        word = word.copyOfRange(n, word.size)
                    }
                    cur = VFDText.string(word)
                }
                first = false
            }
        }
        if (cur.isNotEmpty()) {
            lines.add(cur)
        }
        return lines
    }

    /** SettingSlider: the title (unit in it) and the value on the label row, [-] LED bar [+], the
     *  wrapped hint. [-] / [+] commit one step from the stored value; dragging the bar shows the
     *  value under the finger and commits it on release (as the standard slider's
     *  onValueChangeFinished). */
    private fun timingSlider(ctx: VFDContext, c: Int, top: Int, w: Int, title: String, name: String, key: String,
                             value: Int, low: Int, high: Int, step: Int, hintText: String,
                             commit: (Int) -> Unit): Int {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val ui: VFDUIState = ctx.uiState("settings")
        val dragKey: String = "$key.dragging"
        val draftKey: String = "$key.draft"
        val lo: Double = low.toDouble()
        val hi: Double = high.toDouble()
        val stepD: Double = step.toDouble()
        val current: Double = value.toDouble()
        val dragging: Boolean = ui.bool(dragKey)
        val raw: Double = if (dragging) ui.double(draftKey, current) else current
        val shown: Double = snap(raw, lo, hi, stepD)
        val span: Double = hi - lo
        val frac: Double = if (span > 0) (shown - lo) / span else 0.0
        val valueText: String = shown.roundToInt().toString()
        val y: Int = VFDW.slider(fb, L, c, top, w, title, valueText, frac, name = name, canDec = current > lo,
                                 canInc = current < hi,
                                 onDec = {
                                     ui.setBool(dragKey, false)
                                     commit(milliseconds(snap(current - stepD, lo, hi, stepD)))
                                 },
                                 onInc = {
                                     ui.setBool(dragKey, false)
                                     commit(milliseconds(snap(current + stepD, lo, hi, stepD)))
                                 })
        // The bar's drag, over the slider's own bar hit.
        val barRow: Int = VFDW.groupTop(L, top) + VFDW.labelH
        val bx: Int = c + VFDW.stepW + 4
        val bw: Int = w - 2 * (VFDW.stepW + 4)
        VFDW.tap(fb, bx - 2, barRow, bw + 4, VFDW.ctrlH, "$name:bar", drag = { fraction: Double, ended: Boolean ->
            val width: Double = (bw + 4).toDouble()
            val barW: Double = maxOf(1, bw).toDouble()
            val pos: Double = (fraction * width - 2.0) / barW
            val f: Double = minOf(maxOf(pos, 0.0), 1.0)
            val ms: Double = lo + f * span
            if (ended) {
                ui.setBool(dragKey, false)
                commit(milliseconds(snap(ms, lo, hi, stepD)))
            } else {
                ui.setDouble(draftKey, ms)
                ui.setBool(dragKey, true)
            }
        })
        return hint(fb, c, y, w, hintText)
    }

    /** SettingSlider.snap: the nearest multiple of step, kept inside the range. */
    private fun snap(v: Double, low: Double, high: Double, step: Double): Double {
        if (!v.isFinite()) return low
        if (step <= 0) return minOf(maxOf(v, low), high)
        val steps: Double = Math.round(v / step).toDouble()
        return minOf(maxOf(steps * step, low), high)
    }

    /** Whole milliseconds (the standard slider commits ms.toInt()). */
    private fun milliseconds(value: Double): Int {
        if (!value.isFinite()) return 0
        return minOf(maxOf(value, -1_000_000.0), 1_000_000.0).toInt()
    }
}
