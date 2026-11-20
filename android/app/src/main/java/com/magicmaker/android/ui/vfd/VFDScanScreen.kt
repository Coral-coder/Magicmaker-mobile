package com.magicmaker.android.ui.vfd

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import androidx.core.app.ActivityCompat
import com.magicmaker.android.core.BandEffectModel
import com.magicmaker.android.core.HexUtils
import com.magicmaker.android.core.LivePacketSection
import com.magicmaker.android.core.LivePacketSort
import com.magicmaker.android.core.MagicCategory
import com.magicmaker.android.core.MagicClassifier
import com.magicmaker.android.core.StarlightColors
import com.magicmaker.android.data.MagicStore
import com.magicmaker.android.service.AllFilesAccess
import com.magicmaker.android.service.BatteryOptimization
import com.magicmaker.android.service.MagicMakerForegroundService
import com.magicmaker.android.service.ServiceState
import com.magicmaker.android.ui.liveSubtitle
import kotlin.math.ceil
import kotlin.math.floor

/**
 * SCAN tab in the VFD theme, laid out like tools/vfd/screens/scan.py (the narrow layout) and its
 * iPhone port ios/MagicMaker/VFD/VFDScanScreen.swift, on the Android ScanTab's real data:
 *
 * - the LAST LIGHTS strip: the band face of `UiState.lastLightHex` in true colour, animated by
 *   BandLedAnimation exactly like LastHeardStrip / BandPreview, with the colour legend;
 * - the SCAN CONTROLS fold bar, then the controls panel (capped at 60% of the content and
 *   scrolling inside its own region): the battery warning with OPT OUT and RUN IN BACKGROUND
 *   (Android only), the status lines, the chip rows (PAUSE/SCAN, LOG, GROUPED, RAW,
 *   SHOW-CTRL/ALL RAW, CLASS n/8), MY MAGICBAND (tagged bands, manual MAC entry, saved band
 *   packets, the heard list), LIBRARY FILE (GRANT ACCESS, EXPORT, IMPORT), the buffer with CLR,
 *   the gesture hint;
 * - the live feed (GROUPED sections or RAW) in its own scrolling window, every row of
 *   `UiState.livePackets` / `rawLivePackets`, only the visible ones drawn.
 *
 * Every control sends what ScanTab sends. The long-press PacketActionSheet, the swipe-right
 * "Packet action" dialog, the CLASS filter and the category picker are VFD menus; deletes ask
 * with the standard wording; results are the standard toasts. The page itself never scrolls
 * (draw returns null).
 */
object VFDScanScreen : VFDScreen {
    override val title: String = "SCAN"

    override fun headerRight(ctx: VFDContext): VFDHeaderRight? = null

    override fun draw(ctx: VFDContext): Int? {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val s: Snapshot = snapshot(ctx)
        val c: Int = L.left
        val w: Int = L.width
        // Back to origin 0 (the page never scrolls; this keeps the windows below in screen rows).
        val pageScroll: Int = -fb.originY
        fb.pushClip(0, L.contentTop + pageScroll, fb.cols, L.contentH, dy = pageScroll)
        var y: Int = lastLightsStrip(ctx, fb, s, c, L.contentTop, w)
        y = hairline(fb, c, y, w)
        y = controlsBar(ctx, fb, s, c, y, w)
        if (!s.controlsCollapsed) {
            y = controlsPanel(ctx, fb, L, s, c, y, w)
        }
        y = hairline(fb, c, y, w)
        feedWindow(ctx, fb, L, s, c, y - 3, w)
        fb.popClip()
        return null
    }

    // MARK: - Keys and constants

    /** SharedPreferences keys shared with ScanTab / UiPrefs, and this tab's in-memory UI keys. */
    private object Keys {
        /** UiPrefs: folded feed sections (LivePacketSection names). */
        const val collapsedSections: String = "scan_collapsed_sections"
        /** UiPrefs: MY MAGICBAND folded (default true). */
        const val bandMenuCollapsed: String = "band_menu_collapsed"
        /** The VFD fold bar of the controls (the standard screen always shows them). */
        const val controlsCollapsed: String = "vfd_scan_controls_collapsed"
        /** In memory, like ScanTab's remembered state. */
        const val viewMode: String = "scan.viewMode"
        const val hiddenSections: String = "scan.hiddenSections"
        const val manualMac: String = "scan.manualMac"
        const val feedRegion: String = "feed"
        const val controlsRegion: String = "controls"
    }

    private const val HINT: String = "TAP REPLAY · HOLD MENU · SWIPE ← DEL · SWIPE → TX/TAG"
    private const val BATTERY_NOTE: String = "Unrestricted battery required for screen-off scan."

    /** Band face: FACE x FACE cells with five LED x LED zones. */
    private const val FACE: Int = 37
    private const val LED: Int = 7
    /** Zone offsets inside the face (left/top, centre, right/bottom). */
    private val ledAt: IntArray = intArrayOf(4, 15, 26)
    /** Z1..Z5 as (column, row) in the face's 3 x 3 spots: bottom-left, top-left, centre, top-right,
     *  bottom-right (BandPreview's point order). */
    private val zoneSpotC: IntArray = intArrayOf(0, 0, 1, 2, 2)
    private val zoneSpotR: IntArray = intArrayOf(2, 0, 1, 0, 2)
    /** Rows of padding at the top of the controls panel (scrolls with it). */
    private const val PANEL_PAD: Int = 4
    /** Rows around a window edge a snapping probe draws. */
    private const val PROBE_BAND: Int = 48
    /** ActivityCompat request code of the legacy storage permission (API < 30). */
    private const val STORAGE_REQUEST: Int = 0x5CA

    // MARK: - Snapshot

    /** What one draw reads from the service state, the store and the UI state. */
    private class Snapshot(
        val lastLightHex: String,
        val lightsHeard: Int,
        val packetsHeard: Int,
        val running: Boolean,
        val scanActive: Boolean,
        val recording: Boolean,
        val logName: String,
        val status: String,
        val raw: Boolean,
        val showControlOnly: Boolean,
        val controlsCollapsed: Boolean,
        val bandMenuCollapsed: Boolean,
        /** Folded feed sections. */
        val collapsed: Set<LivePacketSection>,
        /** Sections the CLASS filter shows. */
        val visible: Set<LivePacketSection>,
        val bandAddresses: List<String>,
        val savedBands: Int,
        val seen: List<ServiceState.SeenAddress>,
        val seenTagged: List<Boolean>,
        val manualMac: String,
        val libraryPath: String,
        val storageGranted: Boolean,
        val batteryOk: Boolean,
        val runInBackground: Boolean,
        val livePackets: List<ServiceState.LivePacket>,
        val rawPackets: List<ServiceState.LivePacket>,
    )

    private fun scanUI(ctx: VFDContext): VFDUIState = ctx.uiState("scan")

    private fun snapshot(ctx: VFDContext): Snapshot {
        val st: ServiceState.UiState = ctx.state
        val ui: VFDUIState = scanUI(ctx)
        val rev: Int = st.storeRevision
        val stored: Set<String> = ui.storedStringSet(Keys.collapsedSections)
        val collapsed: Set<LivePacketSection> = LivePacketSection.entries.filter { it.name in stored }.toSet()
        val hidden: Set<String> = ui.strings(Keys.hiddenSections)
        val visible: Set<LivePacketSection> = LivePacketSection.entries.filter { it.name !in hidden }.toSet()
        val bands: Set<String> = ctx.cached("scan.bandAddresses", rev) { ctx.store.bandAddresses() }
        val saved: Int = ctx.cached("scan.savedBands", rev) { ctx.store.savedBandCount() }
        val seen: List<ServiceState.SeenAddress> = st.seenAddresses.take(8)
        val tagged: List<Boolean> = seen.map { it.address.uppercase() in bands }
        // ScanTab re-checks these on its own triggers (returning from Settings recomposes it);
        // here once a second is enough and keeps the system calls out of every frame.
        val second: Long = floor(ctx.time).toLong()
        val granted: Boolean = ctx.cached("scan.storageGranted", Pair(rev, second)) {
            runCatching { AllFilesAccess.granted(ctx.context) }.getOrDefault(false)
        }
        val batteryOk: Boolean = ctx.cached("scan.batteryOk", Pair(st.running, second)) {
            runCatching { BatteryOptimization.isIgnored(ctx.context) }.getOrDefault(false)
        }
        return Snapshot(
            lastLightHex = st.lastLightHex,
            lightsHeard = st.lightsHeard,
            packetsHeard = st.packetsHeard,
            running = st.running,
            scanActive = st.scanActive,
            recording = st.recordSessionActive,
            logName = st.activeSessionName,
            status = st.status,
            raw = ui.string(Keys.viewMode, "GROUPED") == "RAW",
            showControlOnly = ctx.store.getShowControlOnly(),
            controlsCollapsed = ui.storedBool(Keys.controlsCollapsed, false),
            bandMenuCollapsed = ui.storedBool(Keys.bandMenuCollapsed, true),
            collapsed = collapsed,
            visible = visible,
            bandAddresses = bands.toList(),
            savedBands = saved,
            seen = seen,
            seenTagged = tagged,
            manualMac = ui.string(Keys.manualMac),
            libraryPath = ctx.store.libraryFilePath,
            storageGranted = granted,
            batteryOk = batteryOk,
            runInBackground = ui.storedBool(MagicMakerForegroundService.PREF_START_ON_BOOT, true,
                                            prefs = VFDUIState.mainPrefs),
            livePackets = st.livePackets,
            rawPackets = st.rawLivePackets,
        )
    }

    // MARK: - Small helpers

    /** "%03d". */
    private fun pad3(n: Int): String {
        var t: String = n.toString()
        while (t.length < 3) {
            t = "0$t"
        }
        return t
    }

    /** s, or its head and tail around "…" so it fits maxCols (truncation in the middle). */
    private fun fitMiddle(s: String, maxCols: Int): String {
        val n: Int = VFDText.maxChars(maxCols)
        val a: IntArray = VFDText.scalars(s)
        if (a.size <= n) return s
        if (n <= 1) return VFDText.fit(s, maxCols)
        val keep: Int = n - 1
        val head: Int = (keep + 1) / 2
        val tail: Int = keep - head
        return VFDText.string(a.copyOfRange(0, head)) + VFDText.ellipsis +
            VFDText.string(a.copyOfRange(a.size - tail, a.size))
    }

    /** " | "-separated tokens drawn as the telemetry line draws them (a 9-row bar, 4 empty cells
     *  each side), stopping with … at column [limit] (exclusive). Returns the end column. */
    private fun tokens(fb: VFDFrameBuffer, x0: Int, r: Int, toks: List<String>, color: Int, limit: Int): Int {
        var x: Int = x0
        for ((i, tok) in toks.withIndex()) {
            val tw: Int = VFDText.width(tok)
            if (i > 0) {
                val bar: Int = x + 3
                val nxt: Int = bar + 5
                if (nxt + tw > limit) {
                    if (x + VFDText.width(VFDText.ellipsis) <= limit) {
                        x = fb.text(x, r, VFDText.ellipsis, VFDSize.small, color)
                    }
                    return x
                }
                fb.vline(bar, r - 1, 9, color)
                x = nxt
            }
            if (x + tw > limit) {
                return fb.textFit(x, r, tok, limit - x, VFDSize.small, color)
            }
            x = fb.text(x, r, tok, VFDSize.small, color)
        }
        return x
    }

    private enum class ChipKind { action, on, off }

    private class ChipSpec(
        val label: String,
        val kind: ChipKind,
        val icon: String?,
        val chevron: Boolean,
        val action: () -> Unit,
    )

    private fun chipWidth(label: String, icon: Boolean, kind: ChipKind, chevron: Boolean): Int = when (kind) {
        ChipKind.on, ChipKind.off -> VFDText.width(count = VFDText.length(label) + 2)
        ChipKind.action -> VFDText.width(label) + (if (icon) 9 else 0) + (if (chevron) 11 else 0) + 12
    }

    /** One ScanChip on a ctrlH row at (x, y): a button (highlight border) with an optional pause /
     *  play icon or a menu chevron, an inverted block (on) or [LABEL] (off). Returns the column
     *  after it. */
    private fun chip(fb: VFDFrameBuffer, x: Int, y: Int, rawLabel: String, kind: ChipKind = ChipKind.action,
                     icon: String? = null, chevron: Boolean = false, action: (() -> Unit)? = null): Int {
        val label: String = VFDW.upper(rawLabel)
        val w: Int = chipWidth(label, icon != null, kind, chevron)
        val ty: Int = y + VFDW.ctrlText
        when (kind) {
            ChipKind.on -> {
                fb.fill(x, y + 1, w, VFDW.ctrlH - 2, VFDInk.highlight)
                fb.text(x + VFDW.adv, ty, label, VFDSize.small, VFDInk.unlit)
            }
            ChipKind.off -> {
                fb.text(x, ty, "[", VFDSize.small, VFDInk.dim)
                fb.text(x + VFDW.adv, ty, label, VFDSize.small, VFDInk.text)
                fb.text(x + w - 5, ty, "]", VFDSize.small, VFDInk.dim)
            }
            ChipKind.action -> {
                fb.box(x, y, w, VFDW.ctrlH, VFDInk.highlight)
                var tx: Int = x + 6
                if (icon == "pause") {
                    fb.fill(tx, ty, 2, 7, VFDInk.text)
                    fb.fill(tx + 3, ty, 2, 7, VFDInk.text)
                    tx += 9
                } else if (icon == "play") {
                    for (i in 0 until 4) {
                        fb.vline(tx + 1 + i, ty + i, 7 - 2 * i, VFDInk.text)
                    }
                    tx += 9
                }
                val end: Int = fb.text(tx, ty, label, VFDSize.small, VFDInk.text)
                if (chevron) {
                    VFDW.chevron(fb, end + 3, ty + 1, false, VFDInk.text)
                }
            }
        }
        VFDW.tap(fb, x - 2, y, w + 4, VFDW.ctrlH, "chip:$label", action = action)
        return x + w
    }

    /** Action chips flowing left to right from (c, top), wrapping inside w. Returns the next free
     *  row. */
    private fun chipFlow(fb: VFDFrameBuffer, specs: List<ChipSpec>, c: Int, top: Int, w: Int): Int {
        var x: Int = c
        var y: Int = top
        for (spec in specs) {
            val label: String = VFDW.upper(spec.label)
            val cw: Int = chipWidth(label, spec.icon != null, spec.kind, spec.chevron)
            if (x > c && x + cw > c + w) {
                x = c
                y += VFDW.ctrlH + VFDW.gap
            }
            x = chip(fb, x, y, label, spec.kind, spec.icon, spec.chevron, spec.action) + VFDW.optGap
        }
        return y + VFDW.ctrlH + VFDW.gap
    }

    /** A right-aligned compact button ending on column [right] (inclusive): the standard
     *  TextButton (REMOVE, TAG, CLR, ADD, OPT OUT, DELETE ALL). alarm = a destructive one
     *  (VFDW.button's alarm look). Returns its left column. */
    private fun textButton(fb: VFDFrameBuffer, L: VFDLayout, right: Int, y: Int, label: String,
                           alarm: Boolean = false, name: String? = null, action: () -> Unit): Int {
        val lab: String = VFDW.upper(label)
        val bw: Int = VFDText.width(lab) + 12
        val x: Int = right - bw + 1
        val tapName: String = name ?: "button:$lab"
        if (alarm) {
            VFDW.button(fb, L, x, y, bw, lab, name = tapName, alarm = true, action = action)
            return x
        }
        fb.box(x, y, bw, VFDW.ctrlH, VFDInk.highlight)
        fb.text(x + 6, y + VFDW.ctrlText, lab, VFDSize.small, VFDInk.text)
        VFDW.tap(fb, x, y, bw, VFDW.ctrlH, tapName, action = action)
        return x
    }

    /** The 0.5 dp panel line between blocks: a solid dim rule with 3 empty rows each side. */
    private fun hairline(fb: VFDFrameBuffer, c: Int, y: Int, w: Int): Int {
        fb.hline(c, y + 3, w, VFDInk.dim)
        return y + 7
    }

    /** Starts a system screen from the VFD (the Activity context, as ScanTab's LocalContext). */
    private fun startActivity(ctx: VFDContext, intent: Intent) {
        val context: Context = ctx.context
        if (context !is Activity) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            context.startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            ctx.toast("This settings screen is not available on this device")
        }
    }

    // MARK: - LAST LIGHTS strip

    /** LastHeardStrip: BandPreview(compact, title "LAST LIGHTS · #n") or LAST LIGHTS · NONE HEARD
     *  YET. The face's LEDs are true colours following BandLedAnimation; a moving effect redraws at
     *  30 fps. Returns the next free row. */
    private fun lastLightsStrip(ctx: VFDContext, fb: VFDFrameBuffer, s: Snapshot, c: Int, y: Int, w: Int): Int {
        val hexRaw: String = s.lastLightHex
        if (hexRaw.isBlank()) {
            fb.textFit(c, y + 1, "LAST LIGHTS · NONE HEARD YET", w, VFDSize.small, VFDInk.dim)
            return y + 1 + VFDW.line
        }
        val model: BandEffectModel = VFDColors.bandModel(hexRaw)
        bandFace(fb, c, y + 1, model, ctx.time)
        // An open menu blanks the whole content region, the strip included: nothing moves then.
        if (animates(model) && !ctx.menuOpen) {
            fb.wantsAnimation = true
        }
        val tx: Int = c + FACE + 7
        val tw: Int = c + w - tx
        var r: Int = y
        fb.textFit(tx, r, "LAST LIGHTS · #${s.lightsHeard}", tw, VFDSize.small, VFDInk.dim)
        r += VFDW.line
        val label: String = ctx.cached("scan.lastLightLabel", hexRaw) {
            runCatching { MagicClassifier.classify(hexRaw)?.label }.getOrNull() ?: model.note
        }
        val lit: Boolean = model.kind != BandEffectModel.Kind.NONE
        fb.textFit(tx, r, VFDW.upper(label), tw, VFDSize.small, if (lit) VFDInk.highlight else VFDInk.dim)
        r += VFDW.line
        fb.text(tx, r, fitMiddle(HexUtils.canonicalHex(hexRaw), tw), VFDSize.small, VFDInk.dim)
        r += VFDW.line
        drawLegend(fb, legend(model), tx, r, c + w)
        return y + FACE + 2
    }

    /** Whether BandLedAnimation changes this model's LEDs over time (BandPreview redraws them every
     *  frame; a still face needs no fast clock). */
    private fun animates(model: BandEffectModel): Boolean = when (model.kind) {
        BandEffectModel.Kind.NONE, BandEffectModel.Kind.PING, BandEffectModel.Kind.DUAL -> false
        BandEffectModel.Kind.RAINBOW -> model.approximate && model.colors.size == 5 &&
            model.perLed.all { it != null } && model.note.contains("cycle")
        else -> true
    }

    /** The band face: a FACE x FACE rounded square (dim) with the five LED zones in their true
     *  colour at [time]; an off zone is a dim dotted ring. */
    private fun bandFace(fb: VFDFrameBuffer, x: Int, y: Int, model: BandEffectModel, time: Double) {
        val e: Int = FACE - 1
        fb.hline(x + 2, y, FACE - 4, VFDInk.dim)
        fb.hline(x + 2, y + e, FACE - 4, VFDInk.dim)
        fb.vline(x, y + 2, FACE - 4, VFDInk.dim)
        fb.vline(x + e, y + 2, FACE - 4, VFDInk.dim)
        fb.set(x + 1, y + 1, VFDInk.dim)
        fb.set(x + e - 1, y + 1, VFDInk.dim)
        fb.set(x + 1, y + e - 1, VFDInk.dim)
        fb.set(x + e - 1, y + e - 1, VFDInk.dim)
        for (z in 0 until 5) {
            val lx: Int = x + ledAt[zoneSpotC[z]]
            val ly: Int = y + ledAt[zoneSpotR[z]]
            val rgb: VFDRGB? = VFDColors.bandLED(model, z, time)
            if (rgb != null) {
                VFDW.led(fb, lx, ly, 0, size = LED, fill = rgb)
            } else {
                VFDW.led(fb, lx, ly, null, size = LED)
            }
        }
    }

    /** One legend entry under the strip: a true-colour swatch (null = off ring) and the colour name. */
    private class LegendItem(val rgb: VFDRGB?, val name: String)

    /** The colour names of Z1..Z5 (EMCOT palette names, first-appearance order) with the colour
     *  BandPreview lights them in (labSwatchColor), then OFF when a zone is unlit. A custom RGB
     *  effect names its #RRGGBB. */
    private fun legend(model: BandEffectModel): List<LegendItem> {
        if (model.kind == BandEffectModel.Kind.RGB) {
            val rgb: VFDRGB = VFDColors.rgb(model.rgb ?: 0x9E9E9E)
            return listOf(LegendItem(rgb, rgb.hex))
        }
        val out = ArrayList<LegendItem>()
        val seen = HashSet<String>()
        var anyOff = false
        for (z in 0 until 5) {
            val idx: Int? = model.perLed.getOrNull(z)
            if (idx == null) {
                anyOff = true
                continue
            }
            val name: String = StarlightColors.nameFor(idx)
            if (name.lowercase() == "off") {
                anyOff = true
                continue
            }
            val key: String = VFDW.upper(name)
            if (!seen.add(key)) continue
            out.add(LegendItem(VFDColors.labSwatch(idx), key))
        }
        if (anyOff) {
            out.add(LegendItem(null, "OFF"))
        }
        return out
    }

    private fun swatch(fb: VFDFrameBuffer, x: Int, y: Int, rgb: VFDRGB?) {
        if (rgb != null) {
            VFDW.led(fb, x, y, 0, size = LED, fill = rgb)
        } else {
            VFDW.led(fb, x, y, null, size = LED)
        }
    }

    /** Swatch + colour name, as many as fit before [limit] (exclusive). */
    private fun drawLegend(fb: VFDFrameBuffer, items: List<LegendItem>, x0: Int, r: Int, limit: Int) {
        var x: Int = x0
        for (item in items) {
            val nameX: Int = x + LED + 4
            val need: Int = LED + 4 + VFDText.width(item.name)
            if (x + need > limit) {
                val shortW: Int = VFDText.width(count = minOf(1, VFDText.length(item.name)) + 1)
                if (nameX + shortW <= limit) {
                    swatch(fb, x, r, item.rgb)
                    fb.textFit(nameX, r, item.name, limit - nameX, VFDSize.small, VFDInk.text)
                }
                break
            }
            swatch(fb, x, r, item.rgb)
            val color: Int = if (item.rgb == null) VFDInk.dim else VFDInk.text
            x = fb.text(nameX, r, item.name, VFDSize.small, color) + 7
        }
    }

    // MARK: - Controls

    /** The fold bar: chevron + HIDE SCAN CONTROLS / SCAN CONTROLS, the SCAN | LOG | RX summary
     *  under it. Returns the panel's top row when open, else the row for the hairline. */
    private fun controlsBar(ctx: VFDContext, fb: VFDFrameBuffer, s: Snapshot, c: Int, y: Int, w: Int): Int {
        val r: Int = y + 2
        val title: String
        if (s.controlsCollapsed) {
            VFDW.chevron(fb, c, r, false, VFDInk.dim)
            title = "SCAN CONTROLS"
        } else {
            VFDW.chevronUp(fb, c, r, VFDInk.dim)
            title = "HIDE SCAN CONTROLS"
        }
        val x: Int = c + 11
        fb.textFit(x, r, title, c + w - x, VFDSize.small, VFDInk.highlight)
        val parts = ArrayList<String>()
        parts.add(if (s.scanActive) "SCAN:ON" else "SCAN:OFF")
        if (s.recording) {
            parts.add("LOG:REC")
        }
        parts.add("RX:${s.packetsHeard}")
        tokens(fb, x, r + VFDW.line, parts, VFDInk.dim, c + w)
        val rule: Int = r + VFDW.line + 7 + 3
        val collapsed: Boolean = s.controlsCollapsed
        VFDW.tap(fb, c, y, w, rule - y, "controls", action = {
            scanUI(ctx).setStoredBool(Keys.controlsCollapsed, !collapsed)
        })
        if (collapsed) {
            return rule - 3
        }
        fb.hline(c, rule, w, VFDInk.dim, step = 2)
        return rule + 1
    }

    /** controlsPanel(maxHeight = 60% of the content): the controls column at its natural height,
     *  or capped and scrolled inside its own region with its own indicator. Returns the row after
     *  the window (where the hairline goes). */
    private fun controlsPanel(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, s: Snapshot, c: Int, top: Int,
                              w: Int): Int {
        val colTop: Int = top + PANEL_PAD
        val meter: VFDFrameBuffer = measureBuffer(fb)
        val natural: Int = controlsColumn(ctx, meter, L, s, c, colTop, w, null) - top
        meter.reset()
        val capped: Int = VFDMath.roundHalfAway(0.6 * L.contentH.toDouble())
        val cap: Int = maxOf(capped, minPanelRows(ctx))
        val h: Int = maxOf(0, minOf(natural, cap))
        if (natural <= cap) {
            // Uncapped and unscrolled: nothing crosses the window's edges (the column starts
            // PANEL_PAD rows down and ends after its last line), so no snapping is needed.
            fb.pushClip(0, top, fb.cols, h)
            controlsColumn(ctx, fb, L, s, c, colTop, w, null)
            fb.popClip()
            return top + h
        }
        val off: Int = ctx.scroll(Keys.controlsRegion, limit = natural - h)
        val win: VFDWindow = windowed(fb, top, h, off, c + 2, c + w - 2) { target, edge ->
            controlsColumn(ctx, target, L, s, c, colTop, w, edge)
        }
        registerRegion(fb, Keys.controlsRegion, top, h, natural - h)
        VFDW.listScrollbar(fb, top, win.bottom - top, natural, off)
        return win.bottom
    }

    /** The panel never caps under 120 dp (ScanScreen's minimum), in whole grid rows at the
     *  renderer's pitch. */
    private fun minPanelRows(ctx: VFDContext): Int {
        val density: Float = ctx.context.resources.displayMetrics.density
        val pitch: Int = maxOf(4, Math.round(density * 5f / 3f))
        return ceil(120.0 * density.toDouble() / pitch.toDouble()).toInt()
    }

    /** ScanTab's control column in the VFD layout: the battery warning and RUN IN BACKGROUND, the
     *  status lines, the chip rows, MY MAGICBAND, LIBRARY FILE, the buffer counter with CLR, the
     *  hint. glue = "top" / "bottom" only on snapping probes. Returns the next free row. */
    private fun controlsColumn(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, s: Snapshot, c: Int, y0: Int,
                               w: Int, glue: String?): Int {
        var y: Int = y0
        if (!s.batteryOk) {
            y = batteryRow(ctx, fb, L, c, y, w) + 3
        }
        y = VFDW.toggle(fb, L, c, y, w, "RUN IN BACKGROUND", on = s.runInBackground, labelColor = VFDInk.dim,
                        action = {
                            val ui: VFDUIState = scanUI(ctx)
                            val key: String = MagicMakerForegroundService.PREF_START_ON_BOOT
                            val now: Boolean = ui.storedBool(key, true, prefs = VFDUIState.mainPrefs)
                            ui.setStoredBool(key, !now, prefs = VFDUIState.mainPrefs)
                        })
        y = statusLines(fb, L, s, c, y, w)
        y = chipRows(ctx, fb, s, c, y + 3, w)
        y = bandSection(ctx, fb, L, s, c, y + 5, w, glue)
        y = librarySection(ctx, fb, L, s, c, y + 4, w, glue)
        y = bufferRow(ctx, fb, L, s, c, y + 1, w)
        return hintLines(fb, c, y + 2, w, HINT)
    }

    /** "Unrestricted battery required for screen-off scan." (amber on the standard screen, alarm
     *  here) with OPT OUT on the right, which opens the system battery-optimisation request.
     *  Returns the next free row. */
    private fun batteryRow(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, c: Int, y: Int, w: Int): Int {
        val bx: Int = textButton(fb, L, c + w - 1, y, "OPT OUT", action = {
            startActivity(ctx, BatteryOptimization.requestIgnoreIntent(ctx.context))
        })
        val lines: List<String> = VFDText.wrap(VFDW.upper(BATTERY_NOTE), bx - 6 - c - 4)
        var r: Int = y + VFDW.ctrlText
        for (ln in lines) {
            VFDW.alarmText(fb, c, r, ln)
            r += VFDW.line
        }
        val textEnd: Int = y + VFDW.ctrlText + lines.size * VFDW.line - 1
        return maxOf(y + VFDW.ctrlH, textEnd) + VFDW.gap
    }

    /** The service status (highlight while it runs, as ScanTab's cyan line), the open log, the
     *  service's status text (alarm when it reports a failure). */
    private fun statusLines(fb: VFDFrameBuffer, L: VFDLayout, s: Snapshot, c: Int, y0: Int, w: Int): Int {
        val text: String = if (s.running) "Service running · lock screen OK" else "Tap SCAN to start"
        val color: Int = if (s.running) VFDInk.highlight else VFDInk.dim
        var y: Int = VFDW.statusLine(fb, L, c, y0, w, text, color = color)
        if (s.recording && s.logName.isNotEmpty()) {
            y = VFDW.statusLine(fb, L, c, y, w, "LOG · " + s.logName)
        }
        val st: String = s.status.lowercase()
        val warn: Boolean = st.contains("failed") || st.contains("error") || st.contains("unavailable") ||
            st.startsWith("turn on bluetooth")
        return VFDW.statusLine(fb, L, c, y, w, "STATUS: " + s.status, color = if (warn) VFDInk.alarm else VFDInk.dim)
    }

    /** PAUSE/SCAN, LOG, GROUPED, RAW, SHOW-CTRL/ALL RAW, then CLASS n/8 (SectionFilterDropdown),
     *  flowing and wrapping. Returns the next free row. */
    private fun chipRows(ctx: VFDContext, fb: VFDFrameBuffer, s: Snapshot, c: Int, top: Int, w: Int): Int {
        val total: Int = LivePacketSection.entries.size
        val specs = ArrayList<ChipSpec>()
        specs.add(ChipSpec(if (s.scanActive) "PAUSE" else "SCAN", ChipKind.action,
                           if (s.scanActive) "pause" else "play", false) {
            val context: Context = ctx.context
            if (!ctx.state.running) {
                MagicMakerForegroundService.start(context)
            }
            val next: Boolean = !ctx.state.scanActive
            MagicMakerForegroundService.send(context, MagicMakerForegroundService.ACTION_SET_SCAN) {
                putExtra(MagicMakerForegroundService.EXTRA_SCAN, next)
            }
        })
        specs.add(ChipSpec(if (s.recording) "LOG:ON" else "LOG", ChipKind.action, null, false) {
            val next: Boolean = !ctx.state.recordSessionActive
            MagicMakerForegroundService.send(ctx.context, MagicMakerForegroundService.ACTION_SET_RECORDING) {
                putExtra(MagicMakerForegroundService.EXTRA_RECORDING, next)
            }
        })
        specs.add(ChipSpec("GROUPED", if (s.raw) ChipKind.off else ChipKind.on, null, false) {
            setViewMode(ctx, raw = false)
        })
        specs.add(ChipSpec("RAW", if (s.raw) ChipKind.on else ChipKind.off, null, false) {
            setViewMode(ctx, raw = true)
        })
        specs.add(ChipSpec(if (s.showControlOnly) "SHOW-CTRL" else "ALL RAW",
                           if (s.showControlOnly) ChipKind.on else ChipKind.off, null, false) {
            val store: MagicStore = ctx.store
            store.saveShowControlOnly(!store.getShowControlOnly())
        })
        specs.add(ChipSpec("CLASS ${s.visible.size}/$total", ChipKind.action, null, true) {
            openClassMenu(ctx)
        })
        return chipFlow(fb, specs, c, top, w)
    }

    /** BandConfigSection: a dim panel; the header line folds the tagged bands (REMOVE), the manual
     *  MAC entry (ADD), the saved band packets (DELETE ALL, asks first) and the heard list (TAG /
     *  UNTAG). Returns the next free row. */
    private fun bandSection(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, s: Snapshot, c: Int, y: Int, w: Int,
                            glue: String?): Int {
        val store: MagicStore = ctx.store
        val ic: Int = c + 4
        val iw: Int = w - 8
        val r: Int = y + VFDW.ctrlText
        val folded: Boolean = s.bandMenuCollapsed
        VFDW.chevron(fb, ic, r, folded, VFDInk.dim)
        val cnt: String = pad3(s.bandAddresses.size)
        fb.textRight(ic + iw - 1, r, cnt, VFDSize.small, VFDInk.dim)
        fb.textFit(ic + 11, r, "MY MAGICBAND", iw - 11 - VFDText.width(cnt) - 6, VFDSize.small, VFDInk.highlight)
        VFDW.tap(fb, c, y, w, VFDW.ctrlH, "section:MY MAGICBAND", action = {
            scanUI(ctx).setStoredBool(Keys.bandMenuCollapsed, !folded)
        })
        var end: Int = y + VFDW.ctrlH
        if (!folded) {
            var row: Int = end
            val right: Int = ic + iw - 1
            if (s.bandAddresses.isEmpty()) {
                for (ln in VFDText.wrap("NONE SET — PICK FROM HEARD OR ENTER MAC", iw)) {
                    fb.text(ic, row + VFDW.ctrlText, ln, VFDSize.small, VFDInk.dim)
                    row += VFDW.line
                }
                row += 4
            }
            for (addr in s.bandAddresses) {
                val address: String = addr
                val bx: Int = textButton(fb, L, right, row, "REMOVE", name = "band:remove:$address", action = {
                    store.removeBandAddress(address)
                })
                fb.textFit(ic, row + VFDW.ctrlText, address, bx - ic - 6, VFDSize.small, VFDInk.highlight)
                row += VFDW.ctrlH + VFDW.gap
            }
            row = manualRow(ctx, fb, L, s, ic, row, iw)
            val saved: String = "SAVED BAND PACKETS: ${s.savedBands}"
            if (s.savedBands > 0) {
                val deleteAll: () -> Unit = { confirmDeleteBands(ctx) }
                val both: Int = VFDText.width(saved) + 6 + VFDText.width("DELETE ALL") + 12
                if (both > iw) {
                    // Too narrow for both: the count keeps its line, the button wraps.
                    fb.textFit(ic, row + VFDW.ctrlText, saved, iw, VFDSize.small, VFDInk.dim)
                    row += VFDW.line + 2
                    textButton(fb, L, right, row, "DELETE ALL", alarm = true, action = deleteAll)
                } else {
                    val bx: Int = textButton(fb, L, right, row, "DELETE ALL", alarm = true, action = deleteAll)
                    fb.textFit(ic, row + VFDW.ctrlText, saved, bx - 6 - ic, VFDSize.small, VFDInk.dim)
                }
            } else {
                fb.textFit(ic, row + VFDW.ctrlText, saved, iw, VFDSize.small, VFDInk.dim)
            }
            row += VFDW.ctrlH + VFDW.gap
            if (s.seen.isNotEmpty()) {
                fb.textFit(ic, row + VFDW.ctrlText, "HEARD (TAP TO TAG):", iw, VFDSize.small, VFDInk.dim)
                row += VFDW.line + 2
                for ((i, entry) in s.seen.withIndex()) {
                    val tagged: Boolean = s.seenTagged.getOrElse(i) { false }
                    val address: String = entry.address
                    val bx: Int = textButton(fb, L, right, row, if (tagged) "UNTAG" else "TAG",
                                             name = "band:tag:$address", action = {
                        if (tagged) store.removeBandAddress(address) else store.addBandAddress(address)
                    })
                    val line: String = "$address  ${entry.rssi}dBm ·${entry.count}"
                    val lineColor: Int = if (tagged) VFDInk.highlight else VFDInk.dim
                    fb.textFit(ic, row + VFDW.ctrlText, line, bx - ic - 6, VFDSize.small, lineColor)
                    row += VFDW.ctrlH + VFDW.gap
                }
            }
            end = row + 1
        }
        fb.box(c, y - 2, w, end - y + 4, VFDInk.dim)
        // Snapping probes (column c + 2 is empty in the box): at the bottom edge the top border goes
        // with the header line, at the top edge the bottom border goes with the last line.
        if (glue == "bottom") {
            fb.vline(c + 2, y - 2, 6, VFDInk.dim)
        } else if (glue == "top") {
            fb.vline(c + 2, end - 4, 6, VFDInk.dim)
        }
        return end + 2 + VFDW.gap
    }

    /** The manual entry row: the MAC field (tap to type) and ADD, as BandConfigSection's text
     *  field and ADD button. Returns the next free row. */
    private fun manualRow(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, s: Snapshot, ic: Int, row: Int,
                          iw: Int): Int {
        val bx: Int = textButton(fb, L, ic + iw - 1, row, "ADD", name = "band:add", action = {
            addManualBand(ctx)
        })
        return VFDW.field(fb, L, ic, row, bx - 4 - ic, null, s.manualMac, placeholder = "AA:BB:CC:DD:EE:FF",
                          name = "field:BAND MAC", action = { editManualBand(ctx, thenAdd = false) })
    }

    /** LibraryFileSection: LIBRARY FILE (SD · EDITABLE), the file's path (up to two lines), ACCESS
     *  NOT GRANTED and GRANT ACCESS while storage access is missing, EXPORT / IMPORT. Returns the
     *  next free row. */
    private fun librarySection(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, s: Snapshot, c: Int, y: Int,
                               w: Int, glue: String?): Int {
        val inner: VFDPanelInner = VFDW.panelInner(c, y, w, title = true)
        // Uppercased like every other line here (the LOG line uppercases its file name too).
        val path: String = VFDW.upper(s.libraryPath)
        val wrapped: List<String> = VFDText.wrap(path, inner.w)
        val lines: MutableList<String> = wrapped.take(2).toMutableList()
        if (wrapped.size > 2 && lines.size == 2) {
            lines[1] = VFDText.fit(lines[1] + " …", inner.w)
        }
        var r: Int = inner.r + 1
        for (ln in lines) {
            fb.text(inner.c, r, ln, VFDSize.small, VFDInk.dim)
            r += VFDW.line
        }
        if (!s.storageGranted) {
            r = VFDW.statusLine(fb, L, inner.c, r, inner.w, "ACCESS NOT GRANTED", color = VFDInk.alarm)
        }
        r += 2
        val specs = ArrayList<ChipSpec>()
        if (!s.storageGranted) {
            specs.add(ChipSpec("GRANT ACCESS", ChipKind.action, null, false) { grantStorage(ctx) })
        }
        specs.add(ChipSpec("EXPORT", ChipKind.action, null, false) {
            val out: String? = ctx.store.exportLibrary()
            ctx.toast(if (out != null) "Exported to $out" else "Grant storage access first")
        })
        specs.add(ChipSpec("IMPORT", ChipKind.action, null, false) {
            val ok: Boolean = ctx.store.importLibrary()
            ctx.toast(if (ok) "Library imported" else "No file at path (or unreadable)")
        })
        val end: Int = chipFlow(fb, specs, inner.c, r, inner.w) - VFDW.gap + 2
        if (glue == "top") {
            fb.vline(c + 2, end - 2, 3, VFDInk.dim)
        }
        return VFDW.panel(fb, L, c, y, w, end - y + 1, title = "LIBRARY FILE (SD · EDITABLE)")
    }

    /** BUF UNIQUE n (or BUF RAW n) with CLR on the right. Returns the next free row. */
    private fun bufferRow(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, s: Snapshot, c: Int, y: Int, w: Int): Int {
        val text: String = if (s.raw) "BUF RAW ${s.rawPackets.size}" else "BUF UNIQUE ${s.livePackets.size}"
        val bx: Int = textButton(fb, L, c + w - 1, y, "CLR", action = {
            MagicMakerForegroundService.send(ctx.context, MagicMakerForegroundService.ACTION_CLEAR_LIVE)
        })
        fb.textFit(c, y + VFDW.ctrlText, text, bx - c - 6, VFDSize.small, VFDInk.dim)
        return y + VFDW.ctrlH + VFDW.gap
    }

    /** The gesture hint, wrapped only at its " · " separators. Returns the row after the last line. */
    private fun hintLines(fb: VFDFrameBuffer, c: Int, y0: Int, w: Int, s: String): Int {
        var y: Int = y0
        for (ln in VFDW.tokenLines(s, w, sep = " · ")) {
            fb.text(c, y, ln, VFDSize.small, VFDInk.dim)
            y += VFDW.line
        }
        return y
    }

    // MARK: - Live feed

    /** One feed line: a section header or a packet row, with its rows [top, bottom). */
    private class FeedEntry(
        val header: LivePacketSection?,
        val count: Int,
        val folded: Boolean,
        val packet: ServiceState.LivePacket?,
        val top: Int,
        val bottom: Int,
    )

    private class FeedLayout(
        val entries: List<FeedEntry>,
        /** Row of the empty-buffer line, when the buffer is empty. */
        val emptyRow: Int?,
        val raw: Boolean,
        val end: Int,
    )

    /** Packet row height: label, hex (when there is one), the subtitle (always: it starts with
     *  RSSI), the divider (VFDW.packetRow's geometry). */
    private fun rowHeight(pkt: ServiceState.LivePacket): Int {
        val hexLines: Int = if (pkt.hex.isEmpty()) 0 else VFDW.line
        return 3 + hexLines + VFDW.line + 10 + 1
    }

    /** Where every header and row of the feed goes, from y0: GROUPED = a header per visible
     *  section (LivePacketSort.grouped: section order, newest first inside), its rows unless
     *  folded; RAW = every advert the CLASS filter keeps. An empty buffer gets the LISTEN line,
     *  centred in the space left. */
    private fun feedLayout(ctx: VFDContext, L: VFDLayout, s: Snapshot, y0: Int): FeedLayout {
        val empty: Boolean = if (s.raw) s.rawPackets.isEmpty() else s.livePackets.isEmpty()
        if (empty) {
            val mid: Int = maxOf(y0, (y0 + L.contentBottom) / 2 - 4)
            return FeedLayout(emptyList(), mid, s.raw, mid + VFDW.line)
        }
        val entries = ArrayList<FeedEntry>()
        var y: Int = y0
        if (s.raw) {
            val packets: List<ServiceState.LivePacket> = s.rawPackets
            val sections: List<LivePacketSection> = ctx.cached("scan.rawSections", packets) {
                packets.map { LivePacketSort.sectionOf(it) }
            }
            for ((i, pkt) in packets.withIndex()) {
                val section: LivePacketSection = sections.getOrElse(i) { LivePacketSort.sectionOf(pkt) }
                if (section !in s.visible) continue
                val h: Int = rowHeight(pkt)
                entries.add(FeedEntry(null, 0, false, pkt, y, y + h))
                y += h
            }
            return FeedLayout(entries, null, true, y)
        }
        val live: List<ServiceState.LivePacket> = s.livePackets
        val groups: List<Pair<LivePacketSection, List<ServiceState.LivePacket>>> =
            ctx.cached("scan.grouped", live) { LivePacketSort.grouped(live) }
        var first = true
        for ((section, packets) in groups) {
            if (section !in s.visible || packets.isEmpty()) continue
            val folded: Boolean = section in s.collapsed
            // The first header sits under the hairline, not sectionGap below it.
            val top: Int = if (first) y - (VFDW.sectionGap - VFDW.gap) + 2 else y + 1
            val titleRow: Int = if (top > L.contentTop) top + VFDW.sectionGap - VFDW.gap else top
            val next: Int = titleRow + VFDW.sectionH + VFDW.gap
            entries.add(FeedEntry(section, packets.size, folded, null, top, next))
            y = next
            first = false
            if (folded) continue
            y -= VFDW.gap + 2
            for (pkt in packets) {
                val h: Int = rowHeight(pkt)
                entries.add(FeedEntry(null, 0, false, pkt, y, y + h))
                y += h
            }
        }
        return FeedLayout(entries, null, false, y)
    }

    /** Draws the feed entries that reach into the current clip. glue (snapping probes only) also
     *  lights column 0 from a section title down to its rule (both edges) and, for the top edge,
     *  from a row's last text line down to its divider, so an edge hides a rule or divider with
     *  the line it belongs to. */
    private fun drawFeed(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, layout: FeedLayout, c: Int, w: Int,
                         glue: String?) {
        val mid: Int? = layout.emptyRow
        if (mid != null) {
            val msg = "LISTEN 0x0183 MANUFACTURER"
            fb.text(VFDW.cx(c, w, msg), mid, msg, VFDSize.small, VFDInk.dim)
            return
        }
        val clip: VFDRect = fb.clipRect
        val oy: Int = fb.originY
        val clipTop: Int = clip.r - oy
        val clipBottom: Int = clip.r + clip.h - oy
        for (entry in layout.entries) {
            if (entry.bottom <= clipTop || entry.top >= clipBottom) continue
            val section: LivePacketSection? = entry.header
            val pkt: ServiceState.LivePacket? = entry.packet
            if (section != null) {
                val sec: LivePacketSection = section
                val next: Int = VFDW.section(fb, L, c, entry.top, w, sec.title.uppercase(), count = entry.count,
                                             collapsed = entry.folded, action = { toggleSection(ctx, sec) })
                if (glue != null) {
                    fb.vline(0, next - VFDW.sectionH - VFDW.gap, 10, VFDInk.dim)
                }
            } else if (pkt != null) {
                val next: Int = drawRow(ctx, fb, L, pkt, layout.raw, c, entry.top, w)
                if (glue == "top") {
                    fb.vline(0, next - VFDW.line, VFDW.line, VFDInk.dim)
                }
            }
        }
    }

    /** One SwipePacketRow: tap = transmit, hold = the PacketActionSheet menu, swipe left = remove
     *  (asks first), swipe right = ADD TO TX / RECATEGORIZE. Band sources are selected rows. */
    private fun drawRow(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, pkt: ServiceState.LivePacket,
                        raw: Boolean, c: Int, y: Int, w: Int): Int {
        val hex: String = pkt.hex
        return VFDW.packetRow(fb, L, c, y, w, pkt.label, hex, subtitle = liveSubtitle(pkt, includeNote = true),
                              selected = pkt.isBand,
                              action = { MagicMakerForegroundService.transmit(ctx.context, hex) },
                              long = { openActions(ctx, pkt, raw) },
                              swipeLeft = { askDelete(ctx, pkt, raw) },
                              swipeRight = { promote(ctx, pkt) })
    }

    /** The feed in screen rows [top, contentBottom), scrolled by its own region (clamped to the
     *  feed's length, as a list stops at its end), with its scroll indicator. */
    private fun feedWindow(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, s: Snapshot, c: Int, top: Int, w: Int) {
        val view: Int = L.contentBottom - top
        if (view <= 0) return
        // The feed's first line keeps its place under the hairline.
        val y0: Int = top + 4
        val layout: FeedLayout = feedLayout(ctx, L, s, y0)
        val total: Int = layout.end - top
        val off: Int = ctx.scroll(Keys.feedRegion, limit = total - view)
        windowed(fb, top, view, off, null, null) { target, edge ->
            drawFeed(ctx, target, L, layout, c, w, edge)
        }
        registerRegion(fb, Keys.feedRegion, top, view, total - view)
        VFDW.listScrollbar(fb, top, view, total, off)
    }

    // MARK: - Windows

    /** Scratch buffers for the snapping probes and the controls' measuring pass, reused across
     *  frames (draw runs on the main thread only) instead of allocating several per frame. */
    private var scratch: VFDFrameBuffer? = null
    private var measure: VFDFrameBuffer? = null

    private fun scratchBuffer(fb: VFDFrameBuffer): VFDFrameBuffer {
        val b: VFDFrameBuffer? = scratch
        val buf: VFDFrameBuffer = if (b != null && b.cols == fb.cols && b.rows == fb.rows) {
            b.reset()
            b
        } else {
            VFDFrameBuffer(fb.cols, fb.rows).also { scratch = it }
        }
        buf.alarmInverted = fb.alarmInverted
        return buf
    }

    /** A one-row buffer: drawing on it only measures (everything is clipped away). */
    private fun measureBuffer(fb: VFDFrameBuffer): VFDFrameBuffer {
        val b: VFDFrameBuffer? = measure
        val buf: VFDFrameBuffer = if (b != null && b.cols == fb.cols) {
            b.reset()
            b
        } else {
            VFDFrameBuffer(fb.cols, 1).also { measure = it }
        }
        buf.alarmInverted = fb.alarmInverted
        return buf
    }

    /** Draw `draw(fb, null)` scrolled by [scroll] rows inside screen rows [top, top + h), hiding a
     *  line cut by either edge (snappedWindow over `draw(probe, edge)`, looking only at columns
     *  c0 until c1 when given), and drop the taps the edges cut shorter than tapRows. fb has
     *  origin 0. Returns the rows actually used. */
    private fun windowed(fb: VFDFrameBuffer, top: Int, h: Int, scroll: Int, c0: Int?, c1: Int?,
                         draw: (VFDFrameBuffer, String?) -> Unit): VFDWindow {
        fb.pushClip(0, top, fb.cols, h, dy = -scroll)
        val win: VFDWindow = snappedWindow(fb, top, top + h, c0 ?: 0, c1 ?: fb.cols, draw)
        val firstTap: Int = fb.taps.size
        fb.pushClip(0, win.top - fb.originY, fb.cols, win.bottom - win.top)
        draw(fb, null)
        fb.popClip()
        fb.popClip()
        dropShortTaps(fb, firstTap)
        return win
    }

    /** Rows (top, bottom) of the window a scrolling block may use without cutting a line: a band of
     *  lit rows crossing an edge is left out (scan.py snapped_window: one probe per edge, looking
     *  only at columns c0 until c1). */
    private fun snappedWindow(fb: VFDFrameBuffer, top: Int, bottom: Int, c0: Int, c1: Int,
                              draw: (VFDFrameBuffer, String?) -> Unit): VFDWindow {
        var t: Int = top
        var b: Int = bottom
        val topProbe: VFDFrameBuffer = probe(fb, "top", top - PROBE_BAND, top + PROBE_BAND, draw)
        if (probeLit(topProbe, t - 1, c0, c1) && probeLit(topProbe, t, c0, c1)) {
            while (t < b && probeLit(topProbe, t, c0, c1)) {
                t += 1
            }
        }
        // The same scratch buffer again: the top probe is done with.
        val bottomProbe: VFDFrameBuffer = probe(fb, "bottom", bottom - PROBE_BAND, bottom + PROBE_BAND, draw)
        if (probeLit(bottomProbe, b - 1, c0, c1) && probeLit(bottomProbe, b, c0, c1)) {
            while (b > t && probeLit(bottomProbe, b - 1, c0, c1)) {
                b -= 1
            }
        }
        return VFDWindow(t, b)
    }

    /** The block drawn unclipped (but for screen rows [r0, r1)) on the scratch buffer with fb's
     *  origin. */
    private fun probe(fb: VFDFrameBuffer, edge: String, r0: Int, r1: Int,
                      draw: (VFDFrameBuffer, String?) -> Unit): VFDFrameBuffer {
        val buf: VFDFrameBuffer = scratchBuffer(fb)
        val a: Int = maxOf(0, r0)
        val b: Int = minOf(fb.rows, r1)
        buf.pushClip(0, a, fb.cols, maxOf(0, b - a), dy = fb.originY)
        draw(buf, edge)
        while (buf.clipDepth > 0) {
            buf.popClip()
        }
        return buf
    }

    private fun probeLit(buf: VFDFrameBuffer, r: Int, c0: Int, c1: Int): Boolean {
        if (r < 0 || r >= buf.rows) return false
        val start: Int = r * buf.cols
        val end: Int = minOf(buf.cols, c1)
        var c: Int = maxOf(0, c0)
        while (c < end) {
            if (buf.cells[start + c].toInt() != 0) return true
            c += 1
        }
        return false
    }

    /** A scroll region over screen rows [top, top + h) whose drag limit is [limit] rows, even when
     *  the page window cuts the region shorter (the renderer's limit is contentRows minus the part
     *  of the region that is shown). Nothing when it cannot scroll. */
    private fun registerRegion(fb: VFDFrameBuffer, id: String, top: Int, h: Int, limit: Int) {
        val clip: VFDRect = fb.clipRect
        val oy: Int = fb.originY
        val r0: Int = maxOf(top + oy, clip.r)
        val r1: Int = minOf(top + h + oy, clip.r + clip.h)
        val shown: Int = maxOf(0, r1 - r0)
        if (shown <= 0 || limit <= 0) return
        fb.scrollRegion(id, 0, top, fb.cols, h, limit + shown)
    }

    private fun dropShortTaps(fb: VFDFrameBuffer, start: Int) {
        val taps: MutableList<VFDHit> = fb.taps
        if (start < 0 || start >= taps.size) return
        var k: Int = start
        for (i in start until taps.size) {
            val tp: VFDHit = taps[i]
            if (tp.h >= VFDW.tapRows) {
                taps[k] = tp
                k += 1
            }
        }
        while (taps.size > k) {
            taps.removeAt(taps.size - 1)
        }
    }

    // MARK: - Actions (closures only; never called from draw)

    private fun setViewMode(ctx: VFDContext, raw: Boolean) {
        val ui: VFDUIState = scanUI(ctx)
        val next: String = if (raw) "RAW" else "GROUPED"
        if (ui.string(Keys.viewMode, "GROUPED") == next) return
        ui.setString(Keys.viewMode, next)
        ctx.setScroll(Keys.feedRegion, 0)
    }

    /** Folds or unfolds a feed section, saved under UiPrefs' key (LivePacketSection names). */
    private fun toggleSection(ctx: VFDContext, section: LivePacketSection) {
        val ui: VFDUIState = scanUI(ctx)
        val set = HashSet<String>(ui.storedStringSet(Keys.collapsedSections))
        if (!set.remove(section.name)) {
            set.add(section.name)
        }
        ui.setStoredStringSet(Keys.collapsedSections, set)
    }

    /** SectionFilterDropdown: ticks the shown sections; a pick toggles one and the menu stays open. */
    private fun openClassMenu(ctx: VFDContext) {
        val ui: VFDUIState = scanUI(ctx)
        val hidden: Set<String> = ui.strings(Keys.hiddenSections)
        val items = ArrayList<VFDMenuItem>()
        var shown = 0
        for (section in LivePacketSection.entries) {
            val on: Boolean = section.name !in hidden
            if (on) shown += 1
            val label: String = section.title.uppercase() + if (on) " ✓" else ""
            val key: String = section.name
            items.add(VFDMenuItem(label) {
                scanUI(ctx).toggleMember(Keys.hiddenSections, key)
                openClassMenu(ctx)
            })
        }
        ctx.menu("CLASS $shown/${LivePacketSection.entries.size}", items)
    }

    /** The long-press PacketActionSheet as a menu. */
    private fun openActions(ctx: VFDContext, pkt: ServiceState.LivePacket, raw: Boolean) {
        val hex: String = pkt.hex
        val label: String = pkt.label
        ctx.menu(label, listOf(
            VFDMenuItem("Transmit") { MagicMakerForegroundService.transmit(ctx.context, hex) },
            VFDMenuItem("Load in Lab") { ctx.loadInLab(hex, label) },
            VFDMenuItem("Add to TX library") { ctx.store.saveCustomPreset(label, hex) },
            VFDMenuItem("Recategorize") { askRecategorize(ctx, hex, label) },
            VFDMenuItem("Remove", destructive = true) { askDelete(ctx, pkt, raw) },
        ))
    }

    /** The swipe-right "Packet action" dialog: ADD TO TX / RECATEGORIZE. */
    private fun promote(ctx: VFDContext, pkt: ServiceState.LivePacket) {
        val hex: String = pkt.hex
        val label: String = pkt.label
        ctx.menu("Packet action · $label", listOf(
            VFDMenuItem("ADD TO TX") { ctx.store.saveCustomPreset(label, hex) },
            VFDMenuItem("RECATEGORIZE") { askRecategorize(ctx, hex, label) },
        ))
    }

    /** CategoryPickerDialog: SHOW / ANIMATION / COLOR / UNKNOWN. */
    private fun askRecategorize(ctx: VFDContext, hex: String, label: String) {
        val items: List<VFDMenuItem> = MagicCategory.entries.map { category ->
            VFDMenuItem(category.name) { recategorize(ctx.store, hex, label, category) }
        }
        ctx.menu(if (label.isEmpty()) "Recategorize" else "Recategorize · $label", items)
    }

    /** ScanTab's onPick: the heard packet is saved as a TX preset first, then the library row with
     *  the same hex gets the category. */
    private fun recategorize(store: MagicStore, hex: String, label: String, category: MagicCategory) {
        val canonical: String = HexUtils.canonicalHex(hex)
        store.saveCustomPreset(label.ifEmpty { category.name }, hex)
        store.allTransmitPackets().firstOrNull { HexUtils.canonicalHex(it.hex) == canonical }?.let {
            store.recategorizePacket(it.id, category)
        }
    }

    /** ConfirmDeleteDialog: "Remove from scan list?" (GROUPED) or "Remove raw packet?" (RAW), the
     *  label and the hex. */
    private fun askDelete(ctx: VFDContext, pkt: ServiceState.LivePacket, raw: Boolean) {
        val title: String = if (raw) "Remove raw packet?" else "Remove from scan list?"
        val upperLabel: String = pkt.label.uppercase()
        val message: String = when {
            pkt.hex.isEmpty() -> upperLabel
            upperLabel.isEmpty() -> pkt.hex
            else -> upperLabel + "\n" + pkt.hex
        }
        val stamp: Long = pkt.timestampMs
        val hex: String = pkt.hex
        val key: String = pkt.dedupeKey
        ctx.confirm(title, message, confirmLabel = "DELETE", destructive = true) {
            if (raw) {
                ServiceState.removeRawLive(stamp, hex)
            } else {
                ServiceState.removeLive(key)
            }
        }
    }

    /** DELETE ALL saved band packets, only after the question BandConfigSection asks. */
    private fun confirmDeleteBands(ctx: VFDContext) {
        val saved: Int = ctx.store.savedBandCount()
        val message: String = "Removes all $saved guest-band telemetry packets from your library. " +
            "Logs and other packets are untouched. This only runs when you tap Delete."
        ctx.confirm("Delete saved band packets?", message, confirmLabel = "DELETE", destructive = true) {
            val n: Int = ctx.store.deleteSavedBands()
            ctx.toast("Deleted $n band packets")
        }
    }

    /** The MAC text field: a prompt with the draft; OK keeps it in the field (thenAdd = false) or
     *  adds it straight away (ADD on an empty field). */
    private fun editManualBand(ctx: VFDContext, thenAdd: Boolean) {
        val ui: VFDUIState = scanUI(ctx)
        ctx.prompt("MY MAGICBAND", "Band MAC address (AA:BB:CC:DD:EE:FF)", ui.string(Keys.manualMac),
                   keyboard = VFDKeyboard.hex) { text ->
            if (thenAdd) {
                if (text.isNotBlank()) {
                    ctx.store.addBandAddress(text)
                    scanUI(ctx).setString(Keys.manualMac, "")
                }
            } else {
                scanUI(ctx).setString(Keys.manualMac, text)
            }
        }
    }

    /** ADD: adds the typed MAC (as BandConfigSection's ADD) and clears the field; with nothing typed
     *  it asks for one first. */
    private fun addManualBand(ctx: VFDContext) {
        val ui: VFDUIState = scanUI(ctx)
        val draft: String = ui.string(Keys.manualMac)
        if (draft.isNotBlank()) {
            ctx.store.addBandAddress(draft)
            ui.setString(Keys.manualMac, "")
        } else {
            editManualBand(ctx, thenAdd = true)
        }
    }

    /** GRANT ACCESS: the all-files-access settings screen (API 30+), else the legacy storage
     *  permission dialog. */
    private fun grantStorage(ctx: VFDContext) {
        val context: Context = ctx.context
        val intent: Intent? = AllFilesAccess.requestIntent(context)
        if (intent != null) {
            startActivity(ctx, intent)
            return
        }
        val activity: Activity = context as? Activity ?: return
        ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                                          STORAGE_REQUEST)
    }
}
