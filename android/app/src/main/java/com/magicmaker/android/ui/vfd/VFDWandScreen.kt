package com.magicmaker.android.ui.vfd

import android.content.Context
import android.content.SharedPreferences
import com.magicmaker.android.core.HexUtils
import com.magicmaker.android.core.MagicClassifier
import com.magicmaker.android.core.MagicPacket
import com.magicmaker.android.core.StarlightColors
import com.magicmaker.android.service.MagicMakerForegroundService
import com.magicmaker.android.ui.DEFAULT_WAND_QUICK_HEX
import com.magicmaker.android.ui.isNewWandHex
import com.magicmaker.android.ui.loadNewWandNames
import com.magicmaker.android.ui.saveNewWandName
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin

/**
 * WAND tab in the VFD theme: tools/vfd/screens/wand.py on the real wand libraries and the
 * Android service (port of ios/MagicMaker/VFD/VFDWandScreen.swift, behaviour of the standard
 * WandTab, StarlightWandView and NewWandList).
 *
 * The library area fills the space above the controls panel, which sits at the bottom:
 * - STARLIGHT (StarlightWandView): the wand as pixel art, its rod and aura lit in the true glow
 *   colour (starlightGlowColor) of the colour last heard or picked, the send pulse (two dotted
 *   rings growing for 0.42 s FastOutSlowIn, the second 0.18 s later, as runTransmitPulse); a tap
 *   on the wand steps to the next colour; the picker row (glow swatch, colour name, middle-cut
 *   code, the colour menu) and SEND; the empty text without a library.
 * - NEW WAND (NewWandList): the generated codes in their own scroll region, a true-colour dot
 *   before each name; tap sends, hold renames.
 * Controls: STARLIGHT / NEW WAND, the programmable quick button (tap sends, hold reprograms), the
 * wand loop, its interval slider, LIB n with CLR LIB (Starlight only, as the standard tab) and the
 * status line.
 */
object VFDWandScreen : VFDScreen {
    override val title: String = "WAND"

    const val emptyText: String = "HEAR A WAND COLOR · SCAN TO LEARN"
    /** Scroll region id of the New Wand code list. */
    const val codesRegion: String = "codes"
    /** The picker row's height in cells. */
    const val pickH: Int = 26
    /** UI state key of the last SEND's time (epoch seconds): the pulse runs from it. */
    const val sentAtKey: String = "wand.sentAt"

    override fun headerRight(ctx: VFDContext): VFDHeaderRight? = null

    override fun draw(ctx: VFDContext): Int? {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val ui: VFDUIState = ctx.ui
        val st: WandState = state(ctx, ui)
        // The tab does not scroll as a whole: undo any page scroll (the code list scrolls itself).
        val scroll: Int = -fb.originY
        fb.pushClip(0, L.contentTop + scroll, fb.cols, L.contentH, dy = scroll)
        // The controls are anchored to the bottom of the content region; the library area fills
        // the rest (the standard view's weight(1f) over the controls column).
        val probe: VFDFrameBuffer = WandScratch.buffer(fb.cols, fb.rows)
        val probeTop: Int = L.contentTop + 40
        val controlsH: Int = drawControls(ctx, ui, st, probe, probeTop) - probeTop
        val ctop: Int = L.contentBottom - controlsH
        if (st.newWand) {
            newWandArea(ctx, ui, st, fb, L.contentTop, ctop)
        } else {
            starlightArea(ctx, ui, st, fb, L.contentTop, ctop)
        }
        drawControls(ctx, ui, st, fb, ctop)
        fb.popClip()
        return null
    }

    // MARK: - State (read only)

    /** WandTab.learned for Starlight: the learned colours without New Wand codes, one per colour. */
    private fun starlight(ctx: VFDContext): WandList =
        ctx.cached("wand.starlight", ctx.state.storeRevision) {
            val list: List<MagicPacket> = ctx.store.learnedStarlightPackets()
                .filterNot { isNewWandHex(it.hex) }
                .distinctBy { MagicClassifier.starlightColorIndex(it.hex) and 0x1F }
            WandList(list, list.hashCode())
        }

    /** The list for the current mode: Starlight colours or the New Wand codes. */
    private fun library(ctx: VFDContext, newWand: Boolean): List<MagicPacket> =
        if (newWand) ctx.store.newWandPackets() else starlight(ctx).packets

    /** Goes up each time a draw or a tap sees one of the values below change. */
    private var epochSeq: Int = 0

    /** The last heard-colour sync (see [sync]); a memo, not screen state. */
    private var lastSync: WandSync? = null

    /** The keys of WandTab's remember(...) / LaunchedEffect(...): a number that stays the same
     *  until [value] changes, and is new after every change (also a change back to an earlier
     *  value). A memo (ctx.cached), so draw stays free of visible state. */
    private fun epoch(ctx: VFDContext, key: String, value: Any?): Int =
        ctx.cached(key, value) {
            epochSeq += 1
            epochSeq
        }

    private fun loopEpoch(ctx: VFDContext): Int = epoch(ctx, "wand.epoch.loop", ctx.state.starlightLoopEnabled)

    private fun intervalEpoch(ctx: VFDContext): Int =
        epoch(ctx, "wand.epoch.interval", ctx.state.starlightIntervalMs)

    /** remember(starlightLoopPacketId, learned.size) of the list on screen. */
    private fun selEpoch(ctx: VFDContext, newWand: Boolean, size: Int): Int =
        epoch(ctx, "wand.epoch.sel", Triple(ctx.state.starlightLoopPacketId, size, newWand))

    /** WandTab.loopOn: remember(starlightLoopEnabled) — the switch's own value until the service's
     *  flag changes. */
    private fun loopOn(ctx: VFDContext, ui: VFDUIState): Boolean {
        if (ui.has("loopOn") && ui.int("loopEpoch") == loopEpoch(ctx)) {
            return ui.bool("loopOn")
        }
        return ctx.state.starlightLoopEnabled
    }

    /** WandTab.intervalSec: starlightIntervalMs / 1000f, or the last committed slider value until
     *  the service's interval changes (LaunchedEffect(starlightIntervalMs)). */
    private fun interval(ctx: VFDContext, ui: VFDUIState): Float {
        if (ui.has("intervalSec") && ui.int("intervalEpoch") == intervalEpoch(ctx)) {
            return ui.double("intervalSec").toFloat()
        }
        return ctx.state.starlightIntervalMs / 1000f
    }

    /** WandTab.selectedId: remember(starlightLoopPacketId, learned.size) — the last sent colour
     *  until the loop's colour or the list changes, else the loop's colour or the first; then the
     *  LaunchedEffect(learned) fix-up (the first when the wanted one is gone). */
    private fun selection(ctx: VFDContext, ui: VFDUIState, newWand: Boolean, library: List<MagicPacket>): Long {
        val loopId: Long = ctx.state.starlightLoopPacketId
        val firstId: Long = library.firstOrNull()?.id ?: -1L
        var wanted: Long = if (loopId >= 0) loopId else firstId
        if (ui.has("sel") && ui.int("selEpoch") == selEpoch(ctx, newWand, library.size)) {
            wanted = ui.string("sel").toLongOrNull() ?: wanted
        }
        if (wanted >= 0 && library.none { it.id == wanted }) {
            wanted = firstId
        }
        return wanted
    }

    /** StarlightWandView's LaunchedEffect(displayColorIndex, colors), run once each time the heard
     *  colour, the list or the view (a mode switch makes a new StarlightWandView) changes: the
     *  glow takes the heard colour and selectedIndex its entry of that colour, or else stays where
     *  it was (the colour picked by hand since the last sync, or that sync's own entry; 0 for a
     *  new view or a list of another size, as remember(colors.size) restarts it). */
    private fun sync(ctx: VFDContext, ui: VFDUIState, list: WandList): WandSync {
        val heardRaw: Int = ctx.state.wandDisplayColorIndex
        val gen: Int = ui.int("viewGen")
        return ctx.cached("wand.sync", Triple(heardRaw, list.key, gen)) {
            val entries: List<MagicPacket> = list.packets
            val count: Int = entries.size
            val prev: WandSync? = lastSync
            var idx = 0
            if (prev != null && prev.gen == gen && prev.count == count) {
                idx = if (ui.has("pickIdx") && ui.int("pickEpoch") == prev.epoch) ui.int("pickIdx") else prev.index
            }
            val heard: Int = heardRaw and 0x1F
            val heardIdx: Int = entries.indexOfFirst { MagicClassifier.starlightColorIndex(it.hex) == heard }
            if (heardIdx >= 0) idx = heardIdx
            idx = if (count > 0) VFDMath.clamp(idx, 0, count - 1) else 0
            epochSeq += 1
            val made = WandSync(epochSeq, gen, count, idx, heard)
            lastSync = made
            made
        }
    }

    /** StarlightWandView's selectedIndex and glowColorIndex: the colour picked by hand (a tap on
     *  the wand or the menu) since the last sync, else the sync's. */
    private fun picker(ctx: VFDContext, ui: VFDUIState, list: WandList): WandPick {
        val s: WandSync = sync(ctx, ui, list)
        if (ui.has("pickIdx") && ui.int("pickEpoch") == s.epoch) {
            val count: Int = list.packets.size
            val idx: Int = if (count > 0) VFDMath.clamp(ui.int("pickIdx"), 0, count - 1) else 0
            return WandPick(idx, ui.int("pickGlow"))
        }
        return WandPick(s.index, s.glow)
    }

    private fun state(ctx: VFDContext, ui: VFDUIState): WandState {
        val newWand: Boolean = ui.bool("newWand")
        val list: List<MagicPacket> = library(ctx, newWand)
        val selected: Long = selection(ctx, ui, newWand, list)
        val pick: WandPick = picker(ctx, ui, starlight(ctx))
        return WandState(
            newWand = newWand,
            library = list,
            selectedId = selected,
            selectedPacket = list.firstOrNull { it.id == selected },
            intervalSec = interval(ctx, ui),
            loopOn = loopOn(ctx, ui),
            dragging = ui.bool("dragging"),
            dragStop = ui.int("dragStop"),
            pickIndex = pick.index,
            glowIndex = pick.glow,
        )
    }

    /** "magicmaker", where WandTab keeps the quick button and the New Wand names. */
    private fun prefs(ctx: VFDContext): SharedPreferences =
        ctx.context.getSharedPreferences(VFDUIState.mainPrefs, Context.MODE_PRIVATE)

    /** loadNewWandNames, read again only when the stored text changes. */
    private fun newWandNames(ctx: VFDContext): Map<String, String> {
        val raw: String = ctx.ui.storedString("newwand_names", "", prefs = VFDUIState.mainPrefs)
        return ctx.cached("wand.newWandNames", raw) { loadNewWandNames(prefs(ctx)) }
    }

    /** Points (dp) to whole cells on this screen (wand.py _pt): px / pitch, the renderer's pitch. */
    private fun cells(ctx: VFDContext, dp: Int): Int {
        val density: Float = ctx.context.resources.displayMetrics.density
        val pitch: Int = maxOf(4, Math.round(density * 5f / 3f))
        return VFDMath.roundHalfEven(dp.toDouble() * density.toDouble() / pitch.toDouble())
    }

    /** "%.1f" as the standard tab formats seconds. */
    private fun seconds(v: Float): String = "%.1f".format(v)

    /** The Material slider's value at stop [stop] of 0.5 .. 30 s with 59 steps (lerp). */
    private fun stopSeconds(stop: Int): Float {
        val clamped: Int = VFDMath.clamp(stop, 0, VFDW.loopLastStop)
        val f: Float = clamped.toFloat() / VFDW.loopLastStop.toFloat()
        return (1f - f) * VFDW.loopMin.toFloat() + f * VFDW.loopMax.toFloat()
    }

    /** SettingSlider.onCommit's (sec * 1000).toLong(). */
    private fun millis(sec: Float): Long = (sec * 1000).toLong()

    // MARK: - Starlight

    /** StarlightWandView in rows top until bottom: the wand, then the picker row 10 dp above the
     *  8 dp bottom padding (or the empty text in its place). */
    private fun starlightArea(ctx: VFDContext, ui: VFDUIState, st: WandState, fb: VFDFrameBuffer,
                              top: Int, bottom: Int) {
        val L: VFDLayout = ctx.L
        val c: Int = L.left
        val w: Int = L.width
        val entries: List<MagicPacket> = st.library
        val pickTop: Int = bottom - cells(ctx, 8) - pickH
        val wandBottom: Int = pickTop - cells(ctx, 10)
        val avail: Int = wandBottom - top
        if (avail >= 24) {
            val h: Int = ctx.cached("wand.fit", avail) { WandArt.fit(avail) }
            val art: WandArt = ctx.cached("wand.art", h) { WandArt.build(h) }
            val span: Int = art.bottom - art.top + 1
            val tip: Int = top + VFDMath.floorDiv(avail - span, 2) - art.top
            val cx: Int = c + VFDMath.floorDiv(w, 2)
            val glow: VFDRGB = VFDColors.starlightGlow(st.glowIndex)
            drawPulse(ctx, ui, fb, cx, tip, h, glow)
            drawArt(fb, art, cx, tip, glow)
            if (entries.isNotEmpty()) {
                fb.tap(c, top, w, wandBottom - top, name = "wand:cycle", action = { cycleColor(ctx, ui) })
            }
        }
        if (entries.isEmpty()) {
            val lines: List<String> = VFDW.tokenLines(emptyText, w)
            var y: Int = pickTop + VFDMath.floorDiv(pickH - lines.size * VFDW.line, 2) + 2
            for (line in lines) {
                fb.text(VFDW.cx(c, w, line), y, line, VFDSize.small, VFDInk.dim)
                y += VFDW.line
            }
        } else {
            pickerRow(ctx, ui, st, fb, c, pickTop, w)
        }
    }

    /** The wand cells: the rod in the glow colour (glints lighter), the dotted aura rings in the
     *  glow colour (the outer one fainter), the glove, handle, collar and crystal in the inks. */
    private fun drawArt(fb: VFDFrameBuffer, art: WandArt, cx: Int, tip: Int, glow: VFDRGB) {
        val white = VFDRGB(255, 255, 255)
        val glowInk: Int = fb.rgb(glow)
        val glintInk: Int = fb.rgb(mix(glow, white, 0.5))
        val outerInk: Int = fb.rgb(mix(glow, VFDColors.unlit, 0.6))
        val n: Int = art.code.size
        var i = 0
        while (i < n) {
            val v: Int = art.code[i]
            val ink: Int = when (v) {
                WandCode.glow, WandCode.auraInner -> glowInk
                WandCode.glint -> glintInk
                WandCode.auraOuter -> outerInk
                else -> v
            }
            fb.set(cx + art.dx[i], tip + art.dy[i], ink)
            i += 1
        }
    }

    /** runTransmitPulse: two dotted rings over the outer aura, 1 + 0.06 p times its size and
     *  faded to ring peak x (1 - 0.4 p) (WandPulse); they stay at p = 1 once done, as the standard
     *  wand keeps them until the next send. */
    private fun drawPulse(ctx: VFDContext, ui: VFDUIState, fb: VFDFrameBuffer, cx: Int, tip: Int, h: Int,
                          glow: VFDRGB) {
        if (!ui.has(sentAtKey)) return
        val elapsed: Double = ctx.time - ui.double(sentAtKey)
        if (elapsed < 0) return
        if (VFDAnim.pulseRunning(elapsed)) fb.wantsAnimation = true
        val pulse: VFDPulse = VFDAnim.wandPulse(elapsed)
        val peaks: List<Double> = VFDAnim.ringPeaks
        // The second ring first, so the first (brighter) one wins where they meet.
        val rings: List<Pair<Double, Double>> = listOf(
            pulse.second to peaks[1] / peaks[0],
            pulse.first to 1.0,
        )
        val hd: Double = h.toDouble()
        val cy: Int = tip + VFDMath.roundHalfEven(WandArt.aura[1].t * hd)
        for ((p, strength) in rings) {
            if (p <= 0.0) continue
            val scale: Double = 1.0 + p * VFDAnim.pulseScaleGain
            val rx: Double = maxOf(1.0, WandArt.aura[1].rx * hd) * scale
            val ry: Double = WandArt.aura[1].ry * hd * scale
            val level: Double = minOf(1.0, strength * (1.0 - p * VFDAnim.pulseFade))
            val ink: Int = fb.rgb(mix(glow, VFDColors.unlit, level))
            val pts: IntArray = WandArt.ellipse(cx, cy, rx, ry, 3)
            var k = 0
            while (k < pts.size) {
                fb.set(pts[k], pts[k + 1], ink)
                k += 2
            }
        }
    }

    /** a x t + b x (1 - t) per channel. */
    private fun mix(a: VFDRGB, b: VFDRGB, t: Double): VFDRGB {
        val u: Double = 1.0 - t
        return VFDRGB(
            VFDMath.roundHalfAway(a.r * t + b.r * u),
            VFDMath.roundHalfAway(a.g * t + b.g * u),
            VFDMath.roundHalfAway(a.b * t + b.b * u),
        )
    }

    /** StarlightWandView's picker row: the menu button (glow swatch, colour name, middle-cut code,
     *  up/down chevrons) and SEND (96 dp wide). */
    private fun pickerRow(ctx: VFDContext, ui: VFDUIState, st: WandState, fb: VFDFrameBuffer, c: Int, r: Int,
                          w: Int) {
        val h: Int = pickH
        val sendW: Int = cells(ctx, 96)
        val gap = 6
        val bw: Int = w - sendW - gap
        fb.box(c, r, bw, h, VFDInk.dim)
        ledDot(fb, c + 5, r + 4 + 1, fb.rgb(VFDColors.starlightGlow(st.glowIndex)))
        val tx: Int = c + 5 + 5 + 5
        val tw: Int = c + bw - 5 - 7 - 5 - tx
        val name: String = StarlightColors.nameFor(st.glowIndex).uppercase()
        fb.textFit(tx, r + 4, name, tw, VFDSize.small, VFDInk.text)
        val selected: MagicPacket? = st.library.getOrNull(st.pickIndex)
        val hex: String = selected?.hex?.uppercase() ?: ""
        fb.text(tx, r + 15, fitMiddle(hex, tw), VFDSize.small, VFDInk.dim)
        updown(fb, c + bw - 5 - 7, r + 8, VFDInk.dim)
        fb.tap(c, r, bw, h, name = "menu:COLOR", action = { colorMenu(ctx, ui) })
        val sx: Int = c + bw + gap
        val sw: Int = c + w - sx
        val sendX: Int = sx + VFDMath.floorDiv(sw - VFDText.width("SEND"), 2)
        if (selected != null) {
            fb.fill(sx, r, sw, h, VFDInk.highlight)
            fb.text(sendX, r + 9, "SEND", VFDSize.small, VFDInk.unlit)
            fb.tap(sx, r, sw, h, name = "button:SEND", action = { sendSelected(ctx, ui) })
        } else {
            fb.box(sx, r, sw, h, VFDInk.dim)
            fb.text(sendX, r + 9, "SEND", VFDSize.small, VFDInk.dim)
        }
    }

    /** A 5 x 5 round LED (corners unlit) with its top-left at (c, r). */
    private fun ledDot(fb: VFDFrameBuffer, c: Int, r: Int, color: Int) {
        fb.fill(c + 1, r, 3, 5, color)
        fb.fill(c, r + 1, 5, 3, color)
    }

    /** An up chevron over a down chevron, 7 x 4 each (rows r .. r + 9). */
    private fun updown(fb: VFDFrameBuffer, c: Int, r: Int, color: Int) {
        for (i in 0 until 4) {
            fb.hline(c + 3 - i, r + i, 2 * i + 1, color)
            fb.hline(c + i, r + 6 + i, 7 - 2 * i, color)
        }
    }

    /** s cut in the middle with … to at most n characters; the tail keeps the extra character so
     *  the colour byte at the end stays visible. */
    private fun middle(s: String, n: Int): String {
        val a: IntArray = VFDText.scalars(s)
        if (a.size <= n) return s
        if (n <= 1) return if (n == 1) VFDText.ellipsis else ""
        val keep: Int = n - 1
        val head: Int = keep / 2
        val tail: Int = keep - head
        return VFDText.string(a.copyOfRange(0, head)) + VFDText.ellipsis +
            VFDText.string(a.copyOfRange(a.size - tail, a.size))
    }

    /** wand.py fit_middle: middle truncation to maxCols cells. */
    private fun fitMiddle(s: String, maxCols: Int): String {
        val n: Int = VFDText.maxChars(maxCols)
        if (VFDText.length(s) <= n) return s
        if (n <= 1) return VFDText.fit(s, maxCols)
        return middle(s, n)
    }

    // MARK: - New Wand

    /** One code row: padding, mid caps, padding, dotted divider. */
    private val codeRowH: Int get() = 4 + VFDSize.mid.ascent + 4 + 1

    /** NewWandList in rows top until bottom: the dim header line, a rule, then the code rows in
     *  their own scroll region. */
    private fun newWandArea(ctx: VFDContext, ui: VFDUIState, st: WandState, fb: VFDFrameBuffer, top: Int,
                            bottom: Int) {
        val L: VFDLayout = ctx.L
        val c: Int = L.left
        val w: Int = L.width
        val codes: List<MagicPacket> = st.library
        var y: Int = top + 1
        val head = "NEW WAND · ${codes.size} CODES · TAP SENDS · HOLD RENAMES"
        for (line in VFDW.tokenLines(head, w)) {
            fb.text(c, y, line, VFDSize.small, VFDInk.dim)
            y += VFDW.line
        }
        fb.hline(c, y, w, VFDInk.dim)
        val listTop: Int = y + 1
        val viewH: Int = bottom - listTop
        if (viewH <= 0) return
        val rowH: Int = codeRowH
        val total: Int = codes.size * rowH
        val s: Int = ctx.scroll(codesRegion, limit = total - viewH)
        // The renderer's drag limit is contentRows minus the region's clipped height: register it
        // so that limit is total - viewH, the one used here.
        val clip: VFDRect = fb.clipRect
        val shownTop: Int = maxOf(listTop + fb.originY, clip.r)
        val shownBottom: Int = minOf(listTop + viewH + fb.originY, clip.r + clip.h)
        val shownRows: Int = maxOf(0, shownBottom - shownTop)
        fb.scrollRegion(codesRegion, 0, listTop, fb.cols, viewH, contentRows = total - viewH + shownRows)
        val names: Map<String, String> = newWandNames(ctx)
        val win: VFDWindow = VFDW.snappedWindow(fb, top = listTop, bottom = bottom) { target ->
            drawCodes(ctx, ui, st, target, codes, names, listTop, bottom, s)
        }
        val firstTap: Int = fb.taps.size
        fb.pushClip(0, win.top - fb.originY, fb.cols, win.bottom - win.top)
        drawCodes(ctx, ui, st, fb, codes, names, listTop, bottom, s)
        fb.popClip()
        val taps: MutableList<VFDHit> = fb.taps
        var i: Int = taps.size - 1
        while (i >= firstTap) {
            if (taps[i].h < VFDW.tapRows) taps.removeAt(i)
            i -= 1
        }
        VFDW.listScrollbar(fb, listTop, viewH, total, s)
    }

    /** A New Wand code's palette index, as NewWandCatalog names it: the last byte's low 5 bits. */
    private fun codeColorIndex(hex: String): Int = (hex.takeLast(2).toIntOrNull(16) ?: 0) and 0x1F

    /** NewWandList rows reaching the window: the last 2 bytes in mid size (dim; the selected one
     *  inverted), the custom name or palette colour right-aligned (dim; the selected one
     *  highlight) after a 5 x 5 dot in the code's true colour. Tap sends, hold renames. */
    private fun drawCodes(ctx: VFDContext, ui: VFDUIState, st: WandState, target: VFDFrameBuffer,
                          codes: List<MagicPacket>, names: Map<String, String>, listTop: Int, bottom: Int,
                          scroll: Int) {
        val L: VFDLayout = ctx.L
        val c: Int = L.left
        val w: Int = L.width
        val rowH: Int = codeRowH
        val ascent: Int = VFDSize.mid.ascent
        var i: Int = maxOf(0, VFDMath.floorDiv(scroll - rowH, rowH))
        var yy: Int = listTop - scroll + i * rowH
        while (i < codes.size) {
            if (yy > bottom) break
            if (yy + rowH < listTop) {
                yy += rowH
                i += 1
                continue
            }
            val packet: MagicPacket = codes[i]
            val hexUpper: String = packet.hex.uppercase()
            val key: String = hexUpper.takeLast(4)
            val nm: String = (names[hexUpper] ?: packet.colors).uppercase()
            val sel: Boolean = packet.id == st.selectedId
            val kx: Int = c + 2
            val ky: Int = yy + 4
            val kend: Int = if (sel) {
                target.fill(kx - 2, ky - 2, VFDText.width(key, VFDSize.mid) + 4, ascent + 4, VFDInk.highlight)
                target.text(kx, ky, key, VFDSize.mid, VFDInk.unlit)
            } else {
                target.text(kx, ky, key, VFDSize.mid, VFDInk.dim)
            }
            val nx: Int = kend + 8
            val nameRow: Int = ky + VFDMath.floorDiv(ascent - 7, 2)
            // The code's palette colour as a 5 x 5 true-colour dot before its name (the name stays).
            val dotRoom: Int = 5 + 4
            val shownName: String = VFDText.fit(nm, c + w - nx - dotRoom)
            val nameInk: Int = if (sel) VFDInk.highlight else VFDInk.dim
            val nameStart: Int = target.textRight(c + w - 1, nameRow, shownName, VFDSize.small, nameInk)
            val dot: VFDRGB = VFDColors.starlightGlow(codeColorIndex(packet.hex))
            ledDot(target, nameStart - dotRoom, nameRow + 1, target.rgb(dot))
            target.hline(c, yy + rowH - 1, w, VFDInk.dim, step = 2)
            target.tap(c, yy, w, rowH, name = "code:$key", action = {
                transmitColor(ctx, ui, packet)
            }, long = {
                beginRename(ctx, packet)
            })
            yy += rowH
            i += 1
        }
    }

    // MARK: - Controls

    /** The controls panel from row [top] (the divider). Returns the next free row. */
    private fun drawControls(ctx: VFDContext, ui: VFDUIState, st: WandState, fb: VFDFrameBuffer, top: Int): Int {
        val L: VFDLayout = ctx.L
        val c: Int = L.left
        val w: Int = L.width
        fb.hline(c, top, w, VFDInk.dim)
        var y: Int = top + 4

        // STARLIGHT / NEW WAND
        y = VFDW.options(fb, L, c, y, w, listOf("STARLIGHT", "NEW WAND"), selected = if (st.newWand) 1 else 0,
                         name = "mode", columns = 2, onSelect = { index -> setMode(ctx, ui, index == 1) })

        // Programmable quick button: tap sends it, a long press reprograms it.
        val quickLabel: String = ui.storedString("wand_quick_label", "OFF", prefs = VFDUIState.mainPrefs)
        y = VFDW.button(fb, L, c, y, w, quickLabel.uppercase(), name = "button:QUICK", action = {
            sendQuick(ctx)
        }, long = {
            editQuick(ctx)
        })

        // LOOP (disabled without a selected colour)
        y = VFDW.toggle(fb, L, c, y, w, "LOOP", st.loopOn, enabled = st.selectedId >= 0,
                        labelColor = VFDInk.highlight, action = {
                            setLoop(ctx, ui, !loopOn(ctx, ui))
                        })

        // SettingSlider: "3.0S | LABEL" or "NO WAND LIBRARY"
        y = intervalSlider(ctx, ui, st, fb, c, y, w)

        // LIB n ............ [CLR LIB]
        fb.text(c, y + 3, "LIB ${st.library.size}", VFDSize.small, VFDInk.dim)
        if (!st.newWand && st.library.isNotEmpty()) {
            val bw: Int = VFDText.width("CLR LIB") + 12
            VFDW.button(fb, L, c + w - bw, y, bw, "CLR LIB", action = { askClearLibrary(ctx, ui) })
        }
        y += VFDW.ctrlH + VFDW.gap
        y = VFDW.statusLine(fb, L, c, y, w, ctx.state.status, color = VFDInk.dim)
        return y
    }

    /** The wand SettingSlider over the 61-stop bar; the bar's drag follows the thumb in the label
     *  and commits on release. */
    private fun intervalSlider(ctx: VFDContext, ui: VFDUIState, st: WandState, fb: VFDFrameBuffer, c: Int, r: Int,
                               w: Int): Int {
        val L: VFDLayout = ctx.L
        val shown: Float = if (st.dragging) stopSeconds(st.dragStop) else st.intervalSec
        val packet: MagicPacket? = st.selectedPacket
        val labelText: String = if (packet != null) {
            seconds(shown) + "S | " + packet.label.uppercase()
        } else {
            "NO WAND LIBRARY"
        }
        val end: Int = VFDW.intervalSlider(fb, L, c, r, w, labelText, shown.toDouble())
        val top: Int = if (r > L.contentTop) r + VFDW.groupGap else r
        val barY: Int = top + VFDW.labelH
        fb.tap(c, barY - 6, w, VFDW.tapRows, name = "slider:INTERVAL:bar", drag = { fraction, ended ->
            val clamped: Double = VFDMath.clamp(fraction, 0.0, 1.0)
            val stop: Int = VFDMath.clamp(VFDMath.roundHalfAway(clamped * VFDW.loopLastStop.toDouble()), 0,
                                          VFDW.loopLastStop)
            if (ended) {
                ui.setBool("dragging", false)
                commitInterval(ctx, ui, stopSeconds(stop))
            } else {
                ui.setInt("dragStop", stop)
                ui.setBool("dragging", true)
            }
        })
        return end
    }

    // MARK: - Actions (run from taps, never from draw)

    private fun setMode(ctx: VFDContext, ui: VFDUIState, newWand: Boolean) {
        if (ui.bool("newWand") == newWand) return
        ui.setBool("newWand", newWand)
        // A new StarlightWandView starts without pulse rings and syncs to the heard colour afresh;
        // the code list is a new LazyColumn and starts at the top.
        ui.setInt("viewGen", ui.int("viewGen") + 1)
        ui.remove(sentAtKey)
        ui.remove("pickIdx")
        ctx.setScroll(codesRegion, 0)
    }

    /** The quick button: MagicMakerForegroundService.transmit of the stored code. */
    private fun sendQuick(ctx: VFDContext) {
        val hex: String = ctx.ui.storedString("wand_quick_hex", DEFAULT_WAND_QUICK_HEX, prefs = VFDUIState.mainPrefs)
        MagicMakerForegroundService.transmit(ctx.context, hex)
    }

    /** The QUICK BUTTON dialog's two fields as two prompts (label, then the hex); SAVE stores the
     *  trimmed label ("OFF" when blank) and the canonical hex. */
    private fun editQuick(ctx: VFDContext) {
        val ui: VFDUIState = ctx.ui
        val labelDraft: String = ui.storedString("wand_quick_label", "OFF", prefs = VFDUIState.mainPrefs)
        val hexDraft: String = ui.storedString("wand_quick_hex", DEFAULT_WAND_QUICK_HEX, prefs = VFDUIState.mainPrefs)
        ctx.prompt("QUICK BUTTON", message = "Label", text = labelDraft, keyboard = VFDKeyboard.text) { label ->
            ctx.prompt("QUICK BUTTON", message = "Hex (8301...)", text = hexDraft, keyboard = VFDKeyboard.hex) { hx ->
                val newLabel: String = label.trim().ifEmpty { "OFF" }
                val newHex: String = HexUtils.canonicalHex(hx)
                prefs(ctx).edit()
                    .putString("wand_quick_label", newLabel)
                    .putString("wand_quick_hex", newHex)
                    .apply()
                ctx.redraw()
            }
        }
    }

    /** RENAME CODE: the field starts with the custom name, or else the code's colour; SAVE stores
     *  it (a blank one removes the custom name). */
    private fun beginRename(ctx: VFDContext, packet: MagicPacket) {
        val initial: String = newWandNames(ctx)[packet.hex.uppercase()] ?: packet.colors
        val hex: String = packet.hex
        ctx.prompt("RENAME CODE", message = hex.uppercase(), text = initial, keyboard = VFDKeyboard.text) { entered ->
            saveNewWandName(prefs(ctx), hex, entered)
            ctx.redraw()
        }
    }

    /** WandTab.transmitColor: select the colour; make it the loop's colour while the loop is on,
     *  else send it. */
    private fun transmitColor(ctx: VFDContext, ui: VFDUIState, packet: MagicPacket) {
        val loopOn: Boolean = loopOn(ctx, ui)
        val sec: Float = interval(ctx, ui)
        val newWand: Boolean = ui.bool("newWand")
        ui.setInt("selEpoch", selEpoch(ctx, newWand, library(ctx, newWand).size))
        ui.setString("sel", packet.id.toString())
        if (loopOn) {
            MagicMakerForegroundService.setStarlightLoop(ctx.context, enabled = true, packetId = packet.id,
                                                         intervalMs = millis(sec))
        } else {
            MagicMakerForegroundService.transmit(ctx.context, packet.hex)
        }
    }

    private fun currentSelection(ctx: VFDContext, ui: VFDUIState): Long {
        val newWand: Boolean = ui.bool("newWand")
        return selection(ctx, ui, newWand, library(ctx, newWand))
    }

    /** The LOOP switch: its own value, the service started when needed, the loop on the selection. */
    private fun setLoop(ctx: VFDContext, ui: VFDUIState, enabled: Boolean) {
        val packetId: Long = currentSelection(ctx, ui)
        val sec: Float = interval(ctx, ui)
        ui.setInt("loopEpoch", loopEpoch(ctx))
        ui.setBool("loopOn", enabled)
        if (enabled && !ctx.state.running) MagicMakerForegroundService.start(ctx.context)
        if (packetId >= 0) {
            MagicMakerForegroundService.setStarlightLoop(ctx.context, enabled = enabled, packetId = packetId,
                                                         intervalMs = millis(sec))
        }
    }

    /** SettingSlider.onCommit: the new interval, and the loop's when it is on. */
    private fun commitInterval(ctx: VFDContext, ui: VFDUIState, sec: Float) {
        val packetId: Long = currentSelection(ctx, ui)
        val loopOn: Boolean = loopOn(ctx, ui)
        ui.setInt("intervalEpoch", intervalEpoch(ctx))
        ui.setDouble("intervalSec", sec.toDouble())
        if (loopOn && packetId >= 0) {
            MagicMakerForegroundService.setStarlightLoop(ctx.context, enabled = true, packetId = packetId,
                                                         intervalMs = millis(sec))
        }
    }

    /** Remember a colour picked on the wand view (a tap on the wand, or the colour menu). */
    private fun pick(ctx: VFDContext, ui: VFDUIState, list: WandList, index: Int) {
        val entries: List<MagicPacket> = list.packets
        if (index < 0 || index >= entries.size) return
        ui.setInt("pickGlow", MagicClassifier.starlightColorIndex(entries[index].hex))
        ui.setInt("pickEpoch", sync(ctx, ui, list).epoch)
        ui.setInt("pickIdx", index)
    }

    /** StarlightWandView's wand tap: the next colour. */
    private fun cycleColor(ctx: VFDContext, ui: VFDUIState) {
        if (ui.bool("newWand")) return
        val list: WandList = starlight(ctx)
        if (list.packets.isEmpty()) return
        val current: WandPick = picker(ctx, ui, list)
        pick(ctx, ui, list, (current.index + 1) % list.packets.size)
    }

    /** StarlightWandView's SEND: the pulse, then WandTab.transmitColor. */
    private fun sendSelected(ctx: VFDContext, ui: VFDUIState) {
        val list: WandList = starlight(ctx)
        val current: WandPick = picker(ctx, ui, list)
        val packet: MagicPacket = list.packets.getOrNull(current.index) ?: return
        ui.setDouble(sentAtKey, ctx.now)
        transmitColor(ctx, ui, packet)
    }

    /** The picker's dropdown: every colour as "NAME  ·  CODE" (the code cut in the middle to fit
     *  the menu row); a pick shows that colour. */
    private fun colorMenu(ctx: VFDContext, ui: VFDUIState) {
        val list: WandList = starlight(ctx)
        // A menu row's label fits in the panel's button (the panel inner width - 4 cells).
        val maxChars: Int = VFDText.maxChars(VFDW.panelInner(ctx.L.left, 0, ctx.L.width).w - 4)
        val items = ArrayList<VFDMenuItem>()
        for ((index, packet) in list.packets.withIndex()) {
            val name: String = StarlightColors.nameFor(MagicClassifier.starlightColorIndex(packet.hex)).uppercase()
            val prefix = "$name  ·  "
            val room: Int = maxChars - VFDText.length(prefix)
            val hexUpper: String = packet.hex.uppercase()
            val shownHex: String = if (room >= 8) middle(hexUpper, room) else hexUpper
            items.add(VFDMenuItem(prefix + shownHex) { pick(ctx, ui, list, index) })
        }
        ctx.menu("WAND COLOR", items)
    }

    /** CLR LIB: "Clear wand library?" — clearLearnedStarlight(), the selection dropped and a
     *  running wand loop stopped, as the standard tab does. */
    private fun askClearLibrary(ctx: VFDContext, ui: VFDUIState) {
        val count: Int = starlight(ctx).packets.size
        val message: String = "Remove all $count learned colors".uppercase()
        ctx.confirm("Clear wand library?", message, confirmLabel = "DELETE", destructive = true) {
            ctx.store.clearLearnedStarlight()
            ui.remove("sel")
            if (loopOn(ctx, ui)) {
                ui.setInt("loopEpoch", loopEpoch(ctx))
                ui.setBool("loopOn", false)
                MagicMakerForegroundService.setStarlightLoop(ctx.context, enabled = false)
            }
        }
    }
}

// MARK: - State

/** The Starlight list and a key of its contents (LaunchedEffect compares the list by value). */
private class WandList(val packets: List<MagicPacket>, val key: Int)

/** StarlightWandView's selectedIndex and glowColorIndex. */
private class WandPick(val index: Int, val glow: Int)

/** One heard-colour sync: its epoch, the view generation and list size it ran on, and the entry
 *  and glow it set. */
private class WandSync(val epoch: Int, val gen: Int, val count: Int, val index: Int, val glow: Int)

/** What one draw of the WAND tab reads. */
private class WandState(
    val newWand: Boolean,
    /** The list on screen: Starlight colours or New Wand codes. */
    val library: List<MagicPacket>,
    /** WandTab.selectedId (-1 = none). */
    val selectedId: Long,
    val selectedPacket: MagicPacket?,
    val intervalSec: Float,
    val loopOn: Boolean,
    val dragging: Boolean,
    val dragStop: Int,
    /** StarlightWandView.selectedIndex. */
    val pickIndex: Int,
    /** StarlightWandView.glowColorIndex. */
    val glowIndex: Int,
)

/** A scratch buffer to measure the controls panel on (a memo, not screen state). */
private object WandScratch {
    private var fb: VFDFrameBuffer? = null

    fun buffer(cols: Int, rows: Int): VFDFrameBuffer {
        val known: VFDFrameBuffer? = fb
        val b: VFDFrameBuffer = if (known != null && known.cols == cols && known.rows == rows) known
        else VFDFrameBuffer(cols, rows)
        fb = b
        b.reset()
        return b
    }
}

// MARK: - Wand pixel art (wand.py wand_cells)

/** Cell codes of the art: the palette inks 0 .. 4 as they are, plus the true-colour parts. */
private object WandCode {
    const val glow: Int = 20
    const val glint: Int = 21
    const val auraInner: Int = 22
    const val auraOuter: Int = 23
    const val empty: Int = 255
}

/** A dense grid of art cells around the rod tip (dx from the centre column, y from the tip). */
private class WandGrid(length: Int) {
    val x0: Int = -(length / 4 + 8)
    val y0: Int = -(length / 4 + 8)
    val w: Int = 2 * (length / 4 + 8) + 1
    val h: Int = (length / 4 + 8) + length + 9
    val cells: IntArray = IntArray(w * h) { WandCode.empty }

    fun set(dx: Int, y: Int, v: Int) {
        val i: Int = dx - x0
        val j: Int = y - y0
        if (i < 0 || j < 0 || i >= w || j >= h) return
        cells[j * w + i] = v
    }
}

/** One aura ring: centre t, rx, ry (fractions of the wand length), every n-th cell. */
private class WandAura(val t: Double, val rx: Double, val ry: Double, val every: Int)

/** The Starlight wand H rows long as a list of lit cells (proportions from StarlightWand.png, as
 *  wand.py draws it): dotted aura rings, the rod with glitter, the glove with finger slits and a
 *  crease, the handle with its sparkles, ring and swirl, the crystal ball, collar and neck. */
private class WandArt(
    val dx: IntArray,
    val dy: IntArray,
    val code: IntArray,
    /** First and last row used, relative to the rod tip (the aura reaches above it). */
    val top: Int,
    val bottom: Int,
) {
    companion object {
        private val gloveL: List<Pair<Double, Double>> = listOf(
            0.440 to 0.028, 0.446 to 0.043, 0.455 to 0.053, 0.466 to 0.061, 0.478 to 0.067,
            0.492 to 0.072, 0.510 to 0.077, 0.528 to 0.081, 0.543 to 0.081, 0.556 to 0.077,
            0.568 to 0.071, 0.579 to 0.064, 0.589 to 0.057, 0.596 to 0.054, 0.622 to 0.054,
        )
        private val gloveR: List<Pair<Double, Double>> = listOf(
            0.428 to 0.028, 0.434 to 0.045, 0.444 to 0.054, 0.456 to 0.060, 0.470 to 0.067,
            0.486 to 0.074, 0.505 to 0.078, 0.528 to 0.082, 0.543 to 0.081, 0.556 to 0.077,
            0.568 to 0.071, 0.579 to 0.063, 0.589 to 0.056, 0.596 to 0.054, 0.622 to 0.054,
        )
        private val handle: List<Pair<Double, Double>> = listOf(
            0.622 to 0.047, 0.634 to 0.041, 0.650 to 0.038, 0.700 to 0.036, 0.760 to 0.036,
            0.800 to 0.039, 0.822 to 0.043, 0.838 to 0.050, 0.846 to 0.054,
        )
        private const val gloveTop: Double = 0.428
        private const val cuffT: Double = 0.594
        private const val gloveEnd: Double = 0.622
        private const val handleEnd: Double = 0.846
        private const val collarEnd: Double = 0.878
        private const val neckEnd: Double = 0.890
        private const val ballT: Double = 0.937
        private const val ballR: Double = 0.064
        private const val rodHW: Double = 0.023
        private const val rodEnd: Double = 0.45
        /** Finger slits: top dx, bottom dx, top t, bottom t. */
        private val slits: List<DoubleArray> = listOf(
            doubleArrayOf(-0.008, -0.010, 0.490, 0.536),
            doubleArrayOf(0.026, 0.018, 0.486, 0.552),
            doubleArrayOf(0.060, 0.048, 0.506, 0.556),
        )
        /** Aura rings (WandAuraLayer envelopes): the inner one, then the outer one. */
        val aura: List<WandAura> = listOf(
            WandAura(0.272, 0.058, 0.272, 2),
            WandAura(0.272, 0.096, 0.312, 3),
        )
        private val swirl: List<Pair<Double, Double>> = listOf(
            0.55 to 0.722, 0.15 to 0.736, -0.40 to 0.756, -0.52 to 0.778, -0.25 to 0.800,
            0.20 to 0.812, 0.45 to 0.804, 0.30 to 0.794, 0.12 to 0.800,
        )

        /** Python int(round(x)). */
        private fun rh(x: Double): Int = VFDMath.roundHalfEven(x)

        private fun interp(points: List<Pair<Double, Double>>, t: Double): Double {
            if (t <= points[0].first) return points[0].second
            var i = 0
            while (i + 1 < points.size) {
                val (t0, v0) = points[i]
                val (t1, v1) = points[i + 1]
                if (t <= t1) {
                    return v0 + (v1 - v0) * (t - t0) / (t1 - t0)
                }
                i += 1
            }
            return points[points.size - 1].second
        }

        /** Small deterministic hash for the glitter (wand.py _hash). */
        private fun hash(a: Int, b: Int): Long {
            val mask = 0xFFFFFFFFL
            var h: Long = (a.toLong() * 374761393L + b.toLong() * 668265263L) and mask
            h = ((h xor (h ushr 13)) * 1274126177L) and mask
            return h xor (h ushr 16)
        }

        /** Cells on an ellipse outline, every [every]-th cell along the path (_dotted_ellipse), as
         *  x, y pairs. */
        fun ellipse(cx: Int, cy: Int, rx: Double, ry: Double, every: Int): IntArray {
            val n: Int = maxOf(64, VFDMath.truncate(8.0 * (rx + ry)))
            val xs = ArrayList<Int>(n)
            val ys = ArrayList<Int>(n)
            for (i in 0 until n) {
                val a: Double = 2.0 * Math.PI * i.toDouble() / n.toDouble()
                val x: Int = cx + rh(rx * sin(a))
                val y: Int = cy - rh(ry * cos(a))
                if (xs.isNotEmpty() && xs[xs.size - 1] == x && ys[ys.size - 1] == y) continue
                xs.add(x)
                ys.add(y)
            }
            if (xs.size > 1 && xs[0] == xs[xs.size - 1] && ys[0] == ys[ys.size - 1]) {
                xs.removeAt(xs.size - 1)
                ys.removeAt(ys.size - 1)
            }
            val step: Int = maxOf(1, every)
            val out = ArrayList<Int>()
            for (i in xs.indices) {
                if (i % step == 0) {
                    out.add(xs[i])
                    out.add(ys[i])
                }
            }
            return out.toIntArray()
        }

        /** The largest length whose art (aura included) fits [avail] rows (the standard view scales
         *  the picture to the available height). */
        fun fit(avail: Int): Int {
            var h: Int = avail
            while (h > 40) {
                val probe: WandArt = build(h)
                if (probe.bottom - probe.top + 1 <= avail) break
                h -= 1
            }
            return h
        }

        fun build(H: Int): WandArt {
            val g = WandGrid(H)
            val hd: Double = H.toDouble()
            val dim: Int = VFDInk.dim
            val text: Int = VFDInk.text
            val unlit: Int = VFDInk.unlit

            // Aura: dotted rings around the rod (drawn first, everything else covers it).
            for ((ringIndex, ring) in aura.withIndex()) {
                val code: Int = if (ringIndex == 0) WandCode.auraInner else WandCode.auraOuter
                val pts: IntArray = ellipse(0, rh(ring.t * hd), maxOf(1.0, ring.rx * hd), ring.ry * hd, ring.every)
                var k = 0
                while (k < pts.size) {
                    g.set(pts[k], pts[k + 1], code)
                    k += 2
                }
            }

            // Rod: lit in the glow colour, rounded tip, sparse glitter.
            val rw: Int = maxOf(2, rh(rodHW * hd))
            val rodRows: Int = rh(rodEnd * hd)
            for (y in 0 until rodRows) {
                val trim: Int = if (y == 0) 2 else if (y == 1) 1 else 0
                val hw: Int = rw - trim
                for (dx in -hw..hw) {
                    val glint: Boolean = hash(dx + 50, y) % 9L == 0L && abs(dx) < hw && y > 2
                    g.set(dx, y, if (glint) WandCode.glint else WandCode.glow)
                }
            }

            // Glove: white with a dim outline, finger slits cut out, a crease above the cuff.
            val g1: Int = rh(gloveEnd * hd)
            val gloveStart: Int = rh(gloveTop * hd)
            val spanLo = HashMap<Int, Int>()
            val spanHi = HashMap<Int, Int>()
            val spanRows = ArrayList<Int>()
            for (y in gloveStart until g1) {
                val t: Double = (y.toDouble() + 0.5) / hd
                val lo: Int = if (t >= gloveL[0].first) -rh(interp(gloveL, t) * hd) else rw
                val hi: Int = rh(interp(gloveR, t) * hd)
                spanLo[y] = lo
                spanHi[y] = hi
                spanRows.add(y)
            }
            val crease: Int = rh(cuffT * hd)
            for (y in spanRows) {
                val lo: Int = spanLo[y] ?: 1
                val hi: Int = spanHi[y] ?: -1
                val ulo: Int = spanLo[y - 1] ?: 1
                val uhi: Int = spanHi[y - 1] ?: -1
                val dlo: Int = spanLo[y + 1] ?: 1
                val dhi: Int = spanHi[y + 1] ?: -1
                for (dx in lo..hi) {
                    val side: Boolean = dx == lo || dx == hi
                    val above: Boolean = dx in ulo..uhi
                    val below: Boolean = dx in dlo..dhi
                    val edge: Boolean = side || !above || !below
                    g.set(dx, y, if (edge || y == crease) dim else text)
                }
            }
            val sw: Int = maxOf(2, rh(0.012 * hd))
            for (slit in slits) {
                val ya: Int = rh(slit[2] * hd)
                val yb: Int = rh(slit[3] * hd)
                for (y in ya..yb) {
                    val f: Double = (y - ya).toDouble() / maxOf(1, yb - ya).toDouble()
                    val along: Double = (slit[0] + (slit[1] - slit[0]) * f) * hd
                    val x0: Int = rh(along - sw.toDouble() / 2.0)
                    for (i in 0 until sw) {
                        if (sw >= 3 && (y == ya || y == yb) && (i == 0 || i == sw - 1)) continue
                        g.set(x0 + i, y, unlit)
                    }
                }
            }

            // Handle: dark (dim) with its decoration in text colour.
            val h1: Int = rh(handleEnd * hd)
            for (y in g1 until h1) {
                val hw: Int = rh(interp(handle, (y.toDouble() + 0.5) / hd) * hd)
                for (dx in -hw..hw) {
                    g.set(dx, y, dim)
                }
            }
            val hwm: Int = rh(interp(handle, 0.70) * hd)
            val hwmD: Double = hwm.toDouble()
            val sparkles: List<Triple<Double, Double, Int>> = listOf(
                Triple(-0.50, 0.660, 2),
                Triple(-0.05, 0.648, 1),
            )
            for ((sx, stT, arm) in sparkles) {
                val x: Int = rh(sx * hwmD)
                val y: Int = rh(stT * hd)
                g.set(x, y, text)
                for (k in 1..arm) {
                    g.set(x + k, y, text)
                    g.set(x - k, y, text)
                    g.set(x, y + k, text)
                    g.set(x, y - k, text)
                }
            }
            val ringR: Int = maxOf(2, rh(0.016 * hd))
            val rcx: Int = rh(0.42 * hwmD)
            val rcy: Int = rh(0.676 * hd)
            for (i in 0 until 8) {
                val a: Double = 2.0 * Math.PI * i.toDouble() / 8.0
                g.set(rcx + rh(ringR.toDouble() * cos(a)), rcy + rh(ringR.toDouble() * sin(a)), text)
            }
            val pathX = ArrayList<Double>()
            val pathY = ArrayList<Double>()
            for (j in 0 until swirl.size - 1) {
                val (x0f, t0) = swirl[j]
                val (x1f, t1) = swirl[j + 1]
                for (k in 0 until 12) {
                    val f: Double = k.toDouble() / 12.0
                    pathX.add((x0f + (x1f - x0f) * f) * hwmD)
                    pathY.add((t0 + (t1 - t0) * f) * hd)
                }
            }
            pathX.add(swirl[swirl.size - 1].first * hwmD)
            pathY.add(swirl[swirl.size - 1].second * hd)
            var dist = 0.0
            var hasLast = false
            var lastX = 0.0
            var lastY = 0.0
            for (i in pathX.indices) {
                val px: Double = pathX[i]
                val py: Double = pathY[i]
                if (hasLast) {
                    dist += hypot(px - lastX, py - lastY)
                }
                if (!hasLast || dist >= 2.4) {
                    g.set(rh(px), rh(py), text)
                    dist = 0.0
                }
                lastX = px
                lastY = py
                hasLast = true
            }

            // Crystal ball (behind the collar): dim facet lattice, text rim and a small glint.
            val bc: Double = ballT * hd
            val br: Double = ballR * hd
            val br2: Double = br * br
            fun outside(a: Int, b: Int): Boolean {
                val da: Double = a.toDouble()
                val db: Double = b.toDouble() + 0.5 - bc
                return da * da + db * db > br2
            }
            val ibr: Int = VFDMath.truncate(br)
            val neckRow: Int = rh(neckEnd * hd)
            for (y in (neckRow - 2) until H) {
                for (dx in (-ibr - 1) until (ibr + 2)) {
                    if (outside(dx, y)) continue
                    val rim: Boolean = outside(dx - 1, y) || outside(dx + 1, y) ||
                        outside(dx, y - 1) || outside(dx, y + 1)
                    val lat: Boolean = VFDMath.floorMod(dx + y, 5) == 0 || VFDMath.floorMod(dx - y, 5) == 0
                    g.set(dx, y, if (rim) text else if (lat) dim else unlit)
                }
            }
            val gx: Int = rh(-0.35 * br)
            val gy: Int = rh(bc - 0.45 * br)
            g.set(gx, gy, text)
            g.set(gx + 1, gy, text)
            g.set(gx, gy + 1, text)

            // Collar ring (with an unlit gap above it) and the neck into the ball.
            val c0: Int = h1 + 1
            val c1: Int = rh(collarEnd * hd)
            val chw: Int = rh(0.061 * hd)
            for (dx in -chw..chw) {
                g.set(dx, h1, unlit)
            }
            for (y in c0 until c1) {
                val inset: Int = if (y == c0 || y == c1 - 1) 1 else 0
                for (dx in (-chw + inset)..(chw - inset)) {
                    g.set(dx, y, dim)
                }
            }
            for (dx in (-chw + 1) until chw) {
                g.set(dx, c0, text)
            }
            val nhw: Int = rh(0.040 * hd)
            for (y in c1 until neckRow) {
                for (dx in -nhw..nhw) {
                    g.set(dx, y, dim)
                }
            }

            // Collect the cells that were set.
            var count = 0
            for (v in g.cells) if (v != WandCode.empty) count += 1
            val xs = IntArray(count)
            val ys = IntArray(count)
            val codes = IntArray(count)
            var top: Int = Int.MAX_VALUE
            var bottom: Int = Int.MIN_VALUE
            var k = 0
            for (j in 0 until g.h) {
                for (i in 0 until g.w) {
                    val v: Int = g.cells[j * g.w + i]
                    if (v == WandCode.empty) continue
                    val y: Int = j + g.y0
                    xs[k] = i + g.x0
                    ys[k] = y
                    codes[k] = v
                    if (y < top) top = y
                    if (y > bottom) bottom = y
                    k += 1
                }
            }
            if (count == 0) {
                top = 0
                bottom = 0
            }
            return WandArt(xs, ys, codes, top, bottom)
        }
    }
}
