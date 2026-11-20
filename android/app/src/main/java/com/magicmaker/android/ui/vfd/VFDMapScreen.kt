package com.magicmaker.android.ui.vfd

import android.os.Handler
import android.os.Looper
import com.magicmaker.android.data.MagicStore
import com.magicmaker.android.ui.CapturePoint
import com.magicmaker.android.ui.MapData
import com.magicmaker.android.ui.TxEstimate
import com.magicmaker.android.ui.loadMapData
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * MAP tab in the VFD theme: tools/vfd/screens/map.py on the real capture locations (port of
 * ios/MagicMaker/VFD/VFDMapScreen.swift, behaviour of the standard MapTab).
 *
 * CAPTURES / TRANSMITTERS / BOTH (MapTab starts on CAPTURES), then a pixel plot of every logged
 * position (MapTab's own loadMapData: clustered capture points and RSSI-weighted transmitter
 * estimates, loaded off the main thread like MapTab does, again when the store changes, on
 * REFRESH and when the tab is opened again), north up, centred on the mean of everything plotted
 * as MapTab centres the map, about 1000 m across, with a reseau cross every 100 m, the counts and
 * a 100 M scale bar in the top border and a legend in the bottom border. Every pin is selectable:
 * the info panel shows what the osmdroid marker's balloon shows (× or the bare map closes it).
 * The street map itself (OpenStreetMap tiles, pan, zoom) cannot be drawn on the grid: HOLD anywhere
 * on the plot opens a menu with OPEN STREET MAP, which shows the standard MAP screen in a sheet
 * (the plot runs to the bottom of the content, as map.py and the iPhone port lay it out).
 */
object VFDMapScreen : VFDScreen {
    override val title: String = "CAPTURE MAP"

    val modes: List<String> = listOf("CAPTURES", "TRANSMITTERS", "BOTH")
    const val emptyText: String = "NO GPS-TAGGED CAPTURES YET — RECORD A SESSION WITH LOCATION ON"
    const val loadingText: String = "LOADING…"
    const val streetMapLabel: String = "OPEN STREET MAP"
    /** About what the standard map first shows across (zoom 16). */
    const val spanMeters: Double = 1000.0
    /** Reseau and scale bar step, metres. */
    const val gridMeters: Int = 100
    /** Capture tap bins: at least this many cells each way (tapRows). */
    const val captureBin: Int = 15
    const val captureTag: String = "c|"
    const val txTag: String = "t|"
    /** 7 x 7 transmitter pin: a ring with a centre dot. */
    val txRing: List<String> = listOf(
        "..###..",
        ".#...#.",
        "#.....#",
        "#..#..#",
        "#.....#",
        ".#...#.",
        "..###..",
    )

    // In-memory UI keys (MapTab's remember state).
    private const val kMode: String = "mode"
    private const val kRefresh: String = "refreshTick"
    private const val kSelection: String = "selection"
    private const val kSelectionLoad: String = "selectionLoad"

    /** REFRESH loads the map again (shown disabled while it loads). */
    override fun headerRight(ctx: VFDContext): VFDHeaderRight? = VFDHeaderRight("REFRESH") {
        if (!VFDMapLoader.busy) {
            val ui: VFDUIState = ctx.ui
            ui.setInt(kRefresh, ui.int(kRefresh) + 1)
        }
    }

    override fun headerRightColor(ctx: VFDContext): Int = if (VFDMapLoader.busy) VFDInk.dim else VFDInk.highlight

    override fun draw(ctx: VFDContext): Int? {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val ui: VFDUIState = ctx.ui
        // MapTab: LaunchedEffect(storeRev) each time it is composed; REFRESH. The loader starts a
        // load once per key (both passes of a frame pass the same one) and redraws when it lands.
        val key = Triple(ctx.state.storeRevision, ui.int(kRefresh), VFDMapVisits.at(ctx.time))
        VFDMapLoader.ensure(ctx, key)
        val c: Int = L.left
        val w: Int = L.width
        // The map does not scroll with the content: undo the scroll offset.
        val scroll: Int = -fb.originY
        fb.pushClip(0, L.contentTop + scroll, fb.cols, L.contentH, dy = scroll)
        val mode: Int = VFDMath.clamp(ui.int(kMode, 0), 0, 2)
        val y: Int = VFDW.options(fb, L, c, L.contentTop, w, modes, selected = mode, name = "mode",
                                  onSelect = { index -> setMode(ctx, index) })
        val load: VFDMapLoad? = VFDMapLoader.load
        val error: String? = VFDMapLoader.error
        if (load == null && error != null) {
            centredNote(fb, L, c, y, w, "MAP LOAD FAILED: $error", alarm = true)
        } else if (load == null) {
            centredNote(fb, L, c, y, w, loadingText)
        } else if (load.data.captures.isEmpty()) {
            centredNote(fb, L, c, y, w, emptyText)
        } else {
            plot(ctx, load, mode, c, y + 1, w, bottom = L.contentBottom)
        }
        fb.popClip()
        return null
    }

    // MARK: - Actions

    private fun setMode(ctx: VFDContext, index: Int) {
        if (index < 0 || index > 2) return
        val ui: VFDUIState = ctx.ui
        ui.setInt(kMode, index)
        ui.setOptionalString(kSelection, null)
    }

    /** Select a pin (null: none) of load [generation] (a capture index belongs to the load it was
     *  drawn from; a selection made on an earlier load shows nothing). */
    private fun select(ctx: VFDContext, tag: String?, generation: Int = VFDMapLoader.generation) {
        val ui: VFDUIState = ctx.ui
        ui.setInt(kSelectionLoad, generation)
        ui.setOptionalString(kSelection, tag)
    }

    /** HOLD on the plot: the street map cannot be drawn on the grid, so it opens the standard MAP
     *  screen (osmdroid) in a sheet. */
    private fun streetMapMenu(ctx: VFDContext) {
        ctx.menu(title, listOf(VFDMenuItem(streetMapLabel) { ctx.openStandard("map") }))
    }

    // MARK: - Texts (the osmdroid markers' titles and details)

    private fun captureTitle(p: CapturePoint): String = if (p.count > 1) "${p.label} ×${p.count}" else p.label

    private fun txTitle(t: TxEstimate): String = "${t.address} · est. TX"

    private fun txDetail(t: TxEstimate): String =
        "${t.count} obs · best ${t.bestRssi} dBm · ±${t.radiusM.roundToInt()}m · ${t.label}"

    /** What the info panel shows for the tapped pin, with its position (metres from the centre);
     *  a selection made on an earlier load is none. */
    private fun selectedInfo(ctx: VFDContext, load: VFDMapLoad): VFDMapInfo? {
        val ui: VFDUIState = ctx.ui
        val tag: String = ui.optionalString(kSelection) ?: return null
        if (ui.int(kSelectionLoad, -1) != VFDMapLoader.generation) return null
        val data: MapData = load.data
        if (tag.startsWith(captureTag)) {
            val i: Int = tag.substring(captureTag.length).toIntOrNull() ?: return null
            if (i < 0 || i >= data.captures.size || i >= load.capX.size) return null
            val p: CapturePoint = data.captures[i]
            return VFDMapInfo(captureTitle(p), p.category, load.capX[i], load.capY[i], isTx = false)
        }
        if (tag.startsWith(txTag)) {
            val address: String = tag.substring(txTag.length)
            for ((i, t) in data.transmitters.withIndex()) {
                if (t.address == address && i < load.txX.size) {
                    return VFDMapInfo(txTitle(t), txDetail(t), load.txX[i], load.txY[i], isTx = true)
                }
            }
        }
        return null
    }

    // MARK: - Line breaking

    /** s broken into lines of at most w cells at its " · " separators (dropped at a break); a
     *  segment longer than a line breaks at spaces. Past maxLines the last line takes the rest
     *  (separators kept), cut with …. */
    private fun segmentLines(s: String, w: Int, maxLines: Int): List<String> {
        val sep = " · "
        val lines = ArrayList<String>()
        val joins = ArrayList<String>()
        var cur = ""
        for (segScalars in VFDText.split(VFDText.scalars(s), VFDText.scalars(sep))) {
            val seg: String = VFDText.string(segScalars)
            val cand: String = if (cur.isEmpty()) seg else cur + sep + seg
            if (VFDText.width(cand) <= w) {
                cur = cand
                continue
            }
            if (cur.isNotEmpty()) {
                lines.add(cur)
                joins.add(sep)
            }
            var words: List<String> = VFDText.wrap(seg, w)
            if (words.isEmpty()) words = listOf("")
            for (k in 0 until words.size - 1) {
                lines.add(words[k])
                joins.add(" ")
            }
            cur = words[words.size - 1]
        }
        lines.add(cur)
        joins.add("")
        if (maxLines > 0 && lines.size > maxLines) {
            val rest = StringBuilder()
            for (k in maxLines - 1 until lines.size) {
                rest.append(lines[k]).append(joins[k])
            }
            val out = ArrayList<String>(lines.subList(0, maxLines - 1))
            out.add(VFDText.fit(rest.toString(), w))
            return out
        }
        return lines
    }

    /** Word wrap in as few lines as w allows, then as narrow as that many lines allow, so a
     *  centred note does not end on a lone word. */
    private fun balancedWrap(s: String, w: Int): List<String> {
        val lines: List<String> = VFDText.wrap(s, w)
        var best: List<String> = lines
        var ww: Int = w - 1
        while (ww > 0) {
            val trial: List<String> = VFDText.wrap(s, ww)
            if (trial.size > lines.size) break
            if (trial.any { VFDText.width(it) > ww }) break
            best = trial
            ww -= 1
        }
        return best
    }

    /** Centred text in the space left (the empty state, LOADING…, or the load error in alarm). */
    private fun centredNote(fb: VFDFrameBuffer, L: VFDLayout, c: Int, y: Int, w: Int, s: String,
                            alarm: Boolean = false) {
        val lines: List<String> = balancedWrap(s, w - 12)
        val half: Int = VFDMath.floorDiv(lines.size * VFDW.line, 2)
        val mid: Int = maxOf(y, VFDMath.floorDiv(y + L.contentBottom, 2) - half)
        for ((i, ln) in lines.withIndex()) {
            val x: Int = VFDW.cx(c, w, ln)
            if (alarm) {
                VFDW.alarmText(fb, x, mid + i * VFDW.line, ln)
            } else {
                fb.text(x, mid + i * VFDW.line, ln, VFDSize.small, VFDInk.dim)
            }
        }
    }

    // MARK: - Pieces

    private fun bitmap(fb: VFDFrameBuffer, c: Int, r: Int, rows: List<String>, color: Int) {
        for ((j, line) in rows.withIndex()) {
            for ((i, ch) in line.withIndex()) {
                if (ch == '#') fb.set(c + i, r + j, color)
            }
        }
    }

    /** The transmitter pin centred on (x, y). */
    private fun txPin(fb: VFDFrameBuffer, x: Int, y: Int) {
        bitmap(fb, x - 3, y - 3, txRing, VFDInk.highlight)
    }

    /** A capture pin: 2 x 2 cells, top-left on the point. */
    private fun captureDot(fb: VFDFrameBuffer, x: Int, y: Int) {
        fb.fill(x, y, 2, 2, VFDInk.text)
    }

    /** Dotted circle of `radius` cells round (x, y): perimeter cells in angle order, every other
     *  one lit; under 2 cells it is left out (the pin covers it). */
    private fun halo(fb: VFDFrameBuffer, x: Int, y: Int, radius: Double) {
        if (!(radius >= 2.0)) return
        val r: Double = minOf(radius, 10_000.0)
        val n: Int = maxOf(16, VFDMath.truncate(2.0 * PI * r * 1.5))
        val ringC = IntArray(n)
        val ringR = IntArray(n)
        var count = 0
        for (k in 0 until n) {
            val a: Double = 2.0 * PI * k.toDouble() / n.toDouble()
            val cc: Int = x + VFDMath.roundHalfAway(r * cos(a))
            val rr: Int = y - VFDMath.roundHalfAway(r * sin(a))
            if (count > 0 && ringC[count - 1] == cc && ringR[count - 1] == rr) continue
            ringC[count] = cc
            ringR[count] = rr
            count += 1
        }
        if (count > 1 && ringC[0] == ringC[count - 1] && ringR[0] == ringR[count - 1]) {
            count -= 1
        }
        var i = 0
        while (i < count) {
            fb.set(ringC[i], ringR[i], VFDInk.dim)
            i += 2
        }
    }

    /** Selection: four L-shaped corners of a (2 * half + 1)-cell square round (x, y). */
    private fun brackets(fb: VFDFrameBuffer, x: Int, y: Int, half: Int) {
        val arm = 3
        for (sx in intArrayOf(-1, 1)) {
            for (sy in intArrayOf(-1, 1)) {
                val cx: Int = x + sx * half
                val cy: Int = y + sy * half
                fb.hline(minOf(cx, cx - sx * (arm - 1)), cy, arm, VFDInk.highlight)
                fb.vline(cx, minOf(cy, cy - sy * (arm - 1)), arm, VFDInk.highlight)
            }
        }
    }

    /** A 3 x 3 cross where two 100 m grid lines meet. */
    private fun reseau(fb: VFDFrameBuffer, x: Int, y: Int) {
        fb.set(x, y, VFDInk.dim)
        fb.set(x - 1, y, VFDInk.dim)
        fb.set(x + 1, y, VFDInk.dim)
        fb.set(x, y - 1, VFDInk.dim)
        fb.set(x, y + 1, VFDInk.dim)
    }

    /** N over a 5-wide up arrow, top-left at (x, y), on a cleared patch. */
    private fun northArrow(fb: VFDFrameBuffer, x: Int, y: Int) {
        fb.fill(x - 2, y - 2, 9, 20, VFDInk.unlit)
        fb.text(x, y, "N", VFDSize.small, VFDInk.dim)
        for (i in 0 until 3) {
            fb.hline(x + 2 - i, y + 9 + i, 1 + 2 * i, VFDInk.dim)
        }
        fb.vline(x + 2, y + 12, 4, VFDInk.dim)
    }

    /** Text set into a horizontal border whose line runs at row + 3. Returns the column after the
     *  cleared gap. */
    private fun borderText(fb: VFDFrameBuffer, x: Int, row: Int, s: String, color: Int): Int {
        val tw: Int = VFDText.width(s)
        fb.fill(x - 3, row + 3, tw + 6, 1, VFDInk.unlit)
        fb.text(x, row, s, VFDSize.small, color)
        return x + tw + 3
    }

    /** A scale bar set into the top border, ending at column `right`: a text-ink bar with end
     *  ticks across the caps, the label after it. */
    private fun scaleBar(fb: VFDFrameBuffer, right: Int, row: Int, cells: Int, label: String) {
        val lw: Int = VFDText.width(label)
        val x: Int = right - lw - 4 - cells
        fb.fill(x - 3, row + 3, cells + lw + 4 + 6, 1, VFDInk.unlit)
        fb.hline(x, row + 3, cells, VFDInk.text)
        fb.vline(x, row + 1, 5, VFDInk.text)
        fb.vline(x + cells - 1, row + 1, 5, VFDInk.text)
        fb.text(x + cells + 4, row, label, VFDSize.small, VFDInk.text)
    }

    /** Legend for the layers shown, set into the bottom border (its line at row + 3). */
    private fun legend(fb: VFDFrameBuffer, x: Int, row: Int, limit: Int, showCaptures: Boolean, showTx: Boolean) {
        val kinds = ArrayList<Int>()
        val labels = ArrayList<String>()
        if (showCaptures) {
            kinds.add(0)
            labels.add("CAPTURE")
        }
        if (showTx) {
            kinds.add(1)
            labels.add("EST. TX")
            kinds.add(2)
            labels.add("±RADIUS")
        }
        val spotX = ArrayList<Int>()
        var end: Int = x
        for (i in kinds.indices) {
            val need: Int = 7 + 4 + VFDText.width(labels[i])
            if (end + need > limit) break
            spotX.add(end)
            end += need + 9
        }
        if (spotX.isEmpty()) return
        end -= 9
        fb.fill(x - 3, row + 3, end - x + 6, 1, VFDInk.unlit)
        val haloDots: Array<IntArray> = arrayOf(
            intArrayOf(2, 0), intArrayOf(4, 0), intArrayOf(0, 2), intArrayOf(6, 2),
            intArrayOf(0, 4), intArrayOf(6, 4), intArrayOf(2, 6), intArrayOf(4, 6),
        )
        for ((k, sx) in spotX.withIndex()) {
            when (kinds[k]) {
                0 -> captureDot(fb, sx + 2, row + 2)
                1 -> txPin(fb, sx + 3, row + 3)
                else -> for (d in haloDots) fb.set(sx + d[0], row + d[1], VFDInk.dim)
            }
            fb.text(sx + 11, row, labels[k], VFDSize.small, VFDInk.dim)
        }
    }

    /** The info panel's lines and box. */
    private fun infoLayout(x0: Int, x1: Int, bottom: Int, info: VFDMapInfo): VFDMapInfoLayout {
        val iw: Int = x1 - x0 + 1 - 8
        val tw: Int = iw - 5 - 6
        val tlines: List<String> = segmentLines(info.title, tw, maxLines = 2)
        val dlines: List<String> = if (info.detail.isNotEmpty()) segmentLines(info.detail, iw, maxLines = 3) else emptyList()
        var h: Int = 4 + tlines.size * VFDW.line + 2
        if (dlines.isNotEmpty()) {
            h += 3 + dlines.size * VFDW.line
        }
        return VFDMapInfoLayout(tlines, dlines, bottom - h + 1, h)
    }

    /** The info panel over the bottom of the plot (columns x0..x1, last row `bottom`): cleared,
     *  dim border, the title (highlight) and details (dim), a pixel × that closes it. */
    private fun infoPanel(ctx: VFDContext, fb: VFDFrameBuffer, x0: Int, x1: Int, bottom: Int, info: VFDMapInfo) {
        val pw: Int = x1 - x0 + 1
        val ix: Int = x0 + 4
        val lay: VFDMapInfoLayout = infoLayout(x0, x1, bottom, info)
        val top: Int = lay.top
        val h: Int = lay.h
        fb.fill(x0 - 2, top - 2, pw + 4, h + 4, VFDInk.unlit)
        fb.box(x0, top, pw, h, VFDInk.dim)
        var y: Int = top + 4
        for (ln in lay.title) {
            fb.text(ix, y, ln, VFDSize.small, VFDInk.highlight)
            y += VFDW.line
        }
        if (lay.detail.isNotEmpty()) {
            y += 3
            for (ln in lay.detail) {
                fb.text(ix, y, ln, VFDSize.small, VFDInk.dim)
                y += VFDW.line
            }
        }
        val cx: Int = x1 - 4 - 4
        val cy: Int = top + 5
        for (i in 0 until 5) {
            fb.set(cx + i, cy + i, VFDInk.dim)
            fb.set(cx + 4 - i, cy + i, VFDInk.dim)
        }
        // Taps on the panel itself do nothing (they do not reach the map under it).
        fb.tap(x0, top, pw - 15, h, name = "info")
        fb.tap(cx - 5, top, 15, 15, name = "info:close", action = { select(ctx, null) })
    }

    // MARK: - The plot

    /** The map box from row `top` down to `bottom`: top border with the counts and the scale bar,
     *  the reseau, halos, pins, selection, info panel, legend in the bottom border. */
    private fun plot(ctx: VFDContext, load: VFDMapLoad, mode: Int, c: Int, top: Int, w: Int, bottom: Int) {
        val fb: VFDFrameBuffer = ctx.fb
        val data: MapData = load.data
        val capRow: Int = top
        val legRow: Int = bottom - 8
        val boxTop: Int = capRow + 3
        val boxBot: Int = legRow + 3
        if (boxBot - boxTop < 40) return
        fb.box(c, boxTop, w, boxBot - boxTop + 1, VFDInk.dim)
        val ix0: Int = c + 1
        val ix1: Int = c + w - 2
        val iy0: Int = boxTop + 1
        val iy1: Int = boxBot - 1
        val iw: Int = ix1 - ix0 + 1
        val ih: Int = iy1 - iy0 + 1
        val mpc: Int = maxOf(1, VFDMath.roundHalfAway(spanMeters / iw.toDouble()))
        val proj = VFDMapProjection(ix0 + VFDMath.floorDiv(iw, 2), VFDMath.floorDiv(iy0 + iy1, 2), mpc)
        val showCaptures: Boolean = mode != 1
        val showTx: Boolean = mode != 0
        val info: VFDMapInfo? = selectedInfo(ctx, load)

        // Cells the north arrow, the info panel and the transmitter pins clear later: capture dots
        // there take no tap.
        val northC: Int = ix1 - 3 - 5
        val northR: Int = iy0 + 7
        val hidden = VFDMapMask(ix0, iy0, iw, ih)
        hidden.cover(northC - 2, northR - 2, 9, 20)
        if (info != null) {
            val lay: VFDMapInfoLayout = infoLayout(ix0 + 3, ix1 - 3, iy1 - 5, info)
            hidden.cover(ix0 + 1, lay.top - 2, iw - 2, lay.h + 4)
        }
        val txCells = ArrayList<IntArray>()
        if (showTx) {
            var i = 0
            while (i < data.transmitters.size && i < load.txX.size) {
                val p: IntArray = proj.at(load.txX[i], load.txY[i])
                txCells.add(p)
                hidden.cover(p[0] - 3, p[1] - 3, 7, 7)
                i += 1
            }
        }

        // Taps, bottom to top: the bare map (clears the selection), the capture bins, the
        // transmitter pins, then the info panel. A hold on any of the first three opens the
        // street-map menu.
        val hold: () -> Unit = { streetMapMenu(ctx) }
        fb.tap(ix0, iy0, iw, ih, name = "map", action = { select(ctx, null) }, long = hold)
        fb.pushClip(ix0, iy0, iw, ih)
        drawReseau(fb, proj, ix0, ix1, iy0, iy1)
        if (showCaptures) {
            val capCells = ArrayList<IntArray>(data.captures.size)
            var i = 0
            while (i < data.captures.size && i < load.capX.size) {
                val p: IntArray = proj.at(load.capX[i], load.capY[i])
                capCells.add(p)
                captureDot(fb, p[0], p[1])
                i += 1
            }
            captureTaps(ctx, fb, ix0, iy0, iw, ih, capCells, hidden, hold)
        }
        if (showTx) {
            for ((i, p) in txCells.withIndex()) {
                halo(fb, p[0], p[1], data.transmitters[i].radiusM / mpc.toDouble())
            }
            for ((i, p) in txCells.withIndex()) {
                fb.fill(p[0] - 3, p[1] - 3, 7, 7, VFDInk.unlit)
                txPin(fb, p[0], p[1])
                val address: String = data.transmitters[i].address
                fb.tap(p[0] - 7, p[1] - 7, 15, 15, name = "marker:t|" + VFDMapText.shortAddress(address),
                       action = { select(ctx, txTag + address) }, long = hold)
            }
        }
        if (info != null) {
            val p: IntArray = proj.at(info.x, info.y)
            brackets(fb, p[0], p[1], half = if (info.isTx) 6 else 5)
        }
        northArrow(fb, northC, northR)
        if (info != null) {
            infoPanel(ctx, fb, ix0 + 3, ix1 - 3, iy1 - 5, info)
        }
        fb.popClip()

        val counts = "${data.captures.size} PTS · ${data.transmitters.size} TX"
        val end: Int = borderText(fb, c + 6, capRow, counts, VFDInk.dim)
        val bar: Int = gridMeters / mpc
        val scaleLabel = "$gridMeters M"
        val need: Int = end + 6 + bar + 4 + VFDText.width(scaleLabel) + 6
        if (need <= c + w - 3) {
            scaleBar(fb, c + w - 7, capRow, bar, scaleLabel)
        }
        legend(fb, c + 6, legRow, c + w - 6, showCaptures, showTx)
    }

    /** A reseau cross every 100 m (whole multiples of 100 m from the centre), inside the plot. */
    private fun drawReseau(fb: VFDFrameBuffer, proj: VFDMapProjection, ix0: Int, ix1: Int, iy0: Int, iy1: Int) {
        val grid: Double = gridMeters.toDouble()
        val m: Double = proj.mpc.toDouble()
        val left: Double = -(proj.ccol - ix0).toDouble() * m
        val below: Double = -(iy1 - proj.crow).toDouble() * m
        val right: Double = (ix1 - proj.ccol).toDouble() * m + grid
        val above: Double = (proj.crow - iy0).toDouble() * m + grid
        val gx0: Double = floor(left / grid) * grid
        val gy0: Double = floor(below / grid) * grid
        var gx: Double = gx0
        var guardX = 0
        while (gx <= right && guardX < 1000) {
            var gy: Double = gy0
            var guardY = 0
            while (gy <= above && guardY < 1000) {
                val p: IntArray = proj.at(gx, gy)
                if (ix0 + 2 <= p[0] && p[0] <= ix1 - 2 && iy0 + 2 <= p[1] && p[1] <= iy1 - 2) {
                    reseau(fb, p[0], p[1])
                }
                gy += grid
                guardY += 1
            }
            gx += grid
            guardX += 1
        }
    }

    /** One tap per capture bin (the plot split into equal bins at least captureBin cells each
     *  way): a bin holding visible capture dots selects its highest-count capture (the list is in
     *  count order, so the first one met), as the topmost marker would be. Registered before the
     *  transmitter pins, so the pins stay on top. */
    private fun captureTaps(ctx: VFDContext, fb: VFDFrameBuffer, x0: Int, y0: Int, w: Int, h: Int,
                            cells: List<IntArray>, hidden: VFDMapMask, long: () -> Unit) {
        val nx: Int = maxOf(1, w / captureBin)
        val ny: Int = maxOf(1, h / captureBin)
        val xs = IntArray(nx + 1) { k -> x0 + VFDMath.floorDiv(w * k, nx) }
        val ys = IntArray(ny + 1) { k -> y0 + VFDMath.floorDiv(h * k, ny) }
        val picked = IntArray(nx * ny) { -1 }
        val generation: Int = VFDMapLoader.generation
        val offsets: Array<IntArray> = arrayOf(intArrayOf(0, 0), intArrayOf(1, 0), intArrayOf(0, 1), intArrayOf(1, 1))
        for ((i, p) in cells.withIndex()) {
            for (d in offsets) {
                val qx: Int = p[0] + d[0]
                val qy: Int = p[1] + d[1]
                if (qx < x0 || qx >= x0 + w || qy < y0 || qy >= y0 + h) continue
                if (hidden.covered(qx, qy)) continue
                val bx: Int = binOf(xs, nx, w, x0, qx)
                val by: Int = binOf(ys, ny, h, y0, qy)
                val key: Int = by * nx + bx
                if (picked[key] < 0) picked[key] = i
            }
        }
        for (key in picked.indices) {
            val index: Int = picked[key]
            if (index < 0) continue
            val bx: Int = key % nx
            val by: Int = key / nx
            fb.tap(xs[bx], ys[by], xs[bx + 1] - xs[bx], ys[by + 1] - ys[by], name = "marker:c|$index",
                   action = { select(ctx, captureTag + index, generation) }, long = long)
        }
    }

    /** The bin of v among integer edges (settled exactly). */
    private fun binOf(edges: IntArray, n: Int, size: Int, origin: Int, v: Int): Int {
        var k: Int = VFDMath.floorDiv((v - origin) * n, maxOf(1, size))
        k = minOf(maxOf(k, 0), n - 1)
        while (k + 1 < n && edges[k + 1] <= v) {
            k += 1
        }
        return k
    }
}

// MARK: - Plot geometry

/** Metres (east, north of the centre) to plot cells. */
private class VFDMapProjection(val ccol: Int, val crow: Int, val mpc: Int) {
    /** [column, row] of the cell. */
    fun at(x: Double, y: Double): IntArray {
        val m: Double = maxOf(1, mpc).toDouble()
        return intArrayOf(ccol + VFDMath.roundHalfAway(x / m), crow - VFDMath.roundHalfAway(y / m))
    }
}

/** Plot cells that something drawn later clears. */
private class VFDMapMask(val x0: Int, val y0: Int, w: Int, h: Int) {
    val w: Int = maxOf(0, w)
    val h: Int = maxOf(0, h)
    private val cells = BooleanArray(this.w * this.h)

    fun cover(c: Int, r: Int, cw: Int, ch: Int) {
        val a: Int = maxOf(c, x0)
        val b: Int = minOf(c + cw, x0 + w)
        val top: Int = maxOf(r, y0)
        val bot: Int = minOf(r + ch, y0 + h)
        if (a >= b || top >= bot) return
        for (y in top until bot) {
            val base: Int = (y - y0) * w
            for (x in a until b) {
                cells[base + x - x0] = true
            }
        }
    }

    fun covered(c: Int, r: Int): Boolean {
        if (c < x0 || c >= x0 + w || r < y0 || r >= y0 + h) return false
        return cells[(r - y0) * w + (c - x0)]
    }
}

/** The tapped pin: what the info panel shows and where the pin is (metres from the centre). */
private class VFDMapInfo(val title: String, val detail: String, val x: Double, val y: Double, val isTx: Boolean)

private class VFDMapInfoLayout(val title: List<String>, val detail: List<String>, val top: Int, val h: Int)

/** One load: MapTab's points, and every point's position in metres east / north of the mean of
 *  everything plotted (where MapTab centres the map). */
private class VFDMapLoad(
    val data: MapData,
    val capX: DoubleArray,
    val capY: DoubleArray,
    val txX: DoubleArray,
    val txY: DoubleArray,
)

private object VFDMapText {
    /** shortAddress(): the last 8 characters, uppercased; empty stays empty. */
    fun shortAddress(address: String): String = if (address.isEmpty()) "" else address.takeLast(8).uppercase()
}

/** Counts the times the tab is opened (a frame gap means it was left; it redraws at least once a
 *  second while shown), so the map loads again as MapTab does each time it is composed. Both
 *  passes of a frame share its time, so they see the same count. */
private object VFDMapVisits {
    private const val revisitGap: Double = 2.5
    private var lastFrame: Double = 0.0
    private var visit: Int = 0

    fun at(time: Double): Int {
        if (lastFrame > 0 && time - lastFrame > revisitGap) {
            visit += 1
        }
        if (time > lastFrame) {
            lastFrame = time
        }
        return visit
    }
}

/**
 * MapTab's load (LaunchedEffect + Dispatchers.IO + runCatching) for the grid: [ensure] starts
 * loadMapData on a worker thread once per key (a later key waits for the running load, then
 * starts on the redraw that load's result triggers); the result lands on the main thread and
 * redraws. Until the first result the screen shows LOADING…; later loads keep the last map
 * shown, with REFRESH dim, until they land. Main thread only, apart from the worker body.
 */
private object VFDMapLoader {
    var load: VFDMapLoad? = null
        private set
    var error: String? = null
        private set
    /** Bumped with every result (a selection belongs to the load it was made on). */
    var generation: Int = 0
        private set
    private var doneKey: Any? = null
    private var runningKey: Any? = null
    private val main: Handler = Handler(Looper.getMainLooper())
    private val worker: ExecutorService by lazy {
        Executors.newSingleThreadExecutor { r -> Thread(r, "vfd-map-load").apply { isDaemon = true } }
    }

    /** A load is running, or none has landed yet. */
    val busy: Boolean get() = runningKey != null || (load == null && error == null)

    fun ensure(ctx: VFDContext, key: Any) {
        if (key == doneKey || runningKey != null) return
        runningKey = key
        val store: MagicStore = ctx.store
        worker.execute {
            val result: Result<VFDMapLoad> = runCatching { project(loadMapData(store)) }
            main.post { finish(ctx, key, result) }
        }
    }

    private fun finish(ctx: VFDContext, key: Any, result: Result<VFDMapLoad>) {
        runningKey = null
        doneKey = key
        result.onSuccess {
            load = it
            error = null
        }
        result.onFailure {
            load = null
            error = it.message ?: it.javaClass.simpleName
        }
        generation += 1
        ctx.redraw()
    }

    /** Positions in metres from the mean of every capture and transmitter (MapTab's centre). */
    private fun project(data: MapData): VFDMapLoad {
        val n: Int = data.captures.size + data.transmitters.size
        if (n == 0) {
            return VFDMapLoad(data, DoubleArray(0), DoubleArray(0), DoubleArray(0), DoubleArray(0))
        }
        var sumLat = 0.0
        var sumLng = 0.0
        for (p in data.captures) {
            sumLat += p.lat
            sumLng += p.lng
        }
        for (t in data.transmitters) {
            sumLat += t.lat
            sumLng += t.lng
        }
        val cLat: Double = sumLat / n
        val cLng: Double = sumLng / n
        val mLat = 111_320.0
        val mLng: Double = 111_320.0 * cos(Math.toRadians(cLat))
        val capX = DoubleArray(data.captures.size) { i -> (data.captures[i].lng - cLng) * mLng }
        val capY = DoubleArray(data.captures.size) { i -> (data.captures[i].lat - cLat) * mLat }
        val txX = DoubleArray(data.transmitters.size) { i -> (data.transmitters[i].lng - cLng) * mLng }
        val txY = DoubleArray(data.transmitters.size) { i -> (data.transmitters[i].lat - cLat) * mLat }
        return VFDMapLoad(data, capX, capY, txX, txY)
    }
}
