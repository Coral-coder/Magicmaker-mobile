package com.magicmaker.android.ui.vfd

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat
import com.magicmaker.android.core.CrashLog
import com.magicmaker.android.core.RelayControlMode
import com.magicmaker.android.service.ServiceState

/**
 * DIAG tab in the VFD theme: tools/vfd/screens/diag.py on the live service state (port of
 * ios/MagicMaker/VFD/VFDDiagScreen.swift, behaviour of the standard DiagnosticsTab).
 *
 * STATUS (BLUETOOTH, SCAN, LOG, LOCATION | RX, LIGHTS, AUTO, TX-AUTO | RELAY, SERVICE, read live
 * from ServiceState.UiState; LOCATION from the location permission and setting the service's GPS
 * tags need), the crash header (CRASH LOG · CLEAN, or HAS ENTRIES with CLEAR; a tap opens the
 * newest 4000 characters in a box that scrolls on its own), BROADCAST SOURCES · n, then the
 * PRIORITY and OTHER sections (folding headers with counts, PRIORITY open and OTHER folded as
 * DiagnosticsTab starts) with one row per source of UiState.sources. CLEAR asks first.
 */
object VFDDiagScreen : VFDScreen {
    override val title: String = "DIAG"

    /** DiagStatusRow key column: 10 characters of small text. */
    const val keyW: Int = 10 * 6
    /** DiagnosticsTab shows the newest 4000 characters of the crash log. */
    const val crashTail: Int = 4000
    /** Text lines the open crash box shows (heightIn(max = 220.dp)). */
    const val crashBoxLines: Int = 12
    const val crashRegion: String = "crash"
    /** Clause separators a wrapped status value prefers to break after. */
    val valueSeps: List<String> = listOf(" · ", " — ")
    const val valueLines: Int = 2
    const val sourceRowH: Int = 25
    const val noSourcesText: String = "NO SOURCES — START A SCAN"

    // In-memory UI keys (DiagnosticsTab's remember state and defaults).
    private const val kCrashCollapsed: String = "crashCollapsed"
    private const val kPriorityCollapsed: String = "priorityCollapsed"
    private const val kOtherCollapsed: String = "otherCollapsed"
    private const val kCrashTick: String = "crashTick"

    /** The service status while Bluetooth is off. */
    private const val bluetoothOffStatus: String = "Turn on Bluetooth"

    override fun headerRight(ctx: VFDContext): VFDHeaderRight? = null

    override fun draw(ctx: VFDContext): Int? {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val ui: VFDUIState = ctx.ui
        val s: ServiceState.UiState = ctx.state
        val c: Int = L.left
        val w: Int = L.width
        var y: Int = L.contentTop
        y = statusBlock(ctx, c, y, w)
        // DiagnosticsTab: remember(crashTick) { CrashLog.recent(ctx) }, read again each time the tab
        // is opened.
        val crashKey = Pair(ui.int(kCrashTick), VFDDiagVisits.at(ctx.time))
        val crashLog: String = ctx.cached("diag.crashLog", crashKey) { CrashLog.recent(ctx.context) }
        val crashBlank: Boolean = crashLog.isBlank()
        y = crashHeader(ctx, crashBlank, c, y + 2, w)
        if (!ui.bool(kCrashCollapsed, true) && !crashBlank) {
            y = crashBox(ctx, crashLog, c, y, w)
        }
        val sources: List<ServiceState.SourceStat> = s.sources
        y = sourcesHeader(fb, c, y, w, sources.size)
        if (sources.isEmpty()) {
            val x: Int = c + VFDMath.floorDiv(w - VFDText.width(noSourcesText), 2)
            fb.text(x, y + 40, noSourcesText, VFDSize.small, VFDInk.dim)
            return y + 40 + 7 + 40
        }
        val split = ctx.cached("diag.split", sources) { sources.partition { it.priority } }
        val priority: List<ServiceState.SourceStat> = split.first
        val other: List<ServiceState.SourceStat> = split.second
        y = sourceSection(ctx, c, y - 4, w, "PRIORITY", priority,
                          collapsed = ui.bool(kPriorityCollapsed, false), key = kPriorityCollapsed, fallback = false)
        y = sourceSection(ctx, c, y, w, "OTHER", other,
                          collapsed = ui.bool(kOtherCollapsed, true), key = kOtherCollapsed, fallback = true)
        return y
    }

    // MARK: - Status block

    /** The status rows from the service state: (key, value, ink, middle-truncated). */
    private fun statusRows(ctx: VFDContext): List<VFDDiagStatus> {
        val s: ServiceState.UiState = ctx.state
        val rows = ArrayList<VFDDiagStatus>(10)
        val btOff: Boolean = s.status == bluetoothOffStatus
        val bluetooth: String = when {
            s.running -> "BLUETOOTH READY"
            btOff -> "BLUETOOTH OFF"
            else -> "SERVICE NOT RUNNING"
        }
        rows.add(VFDDiagStatus("BLUETOOTH", bluetooth, if (s.running) VFDInk.text else VFDInk.alarm, middle = false))
        rows.add(VFDDiagStatus("SCAN", if (s.scanActive) "ON" else "OFF", onOffColor(s.scanActive), middle = false))
        rows.add(VFDDiagStatus("LOG", logText(s), onOffColor(s.recordSessionActive), middle = true))
        val location: VFDDiagLocation = location(ctx)
        rows.add(VFDDiagStatus("LOCATION", location.text, if (location.ok) VFDInk.text else VFDInk.alarm,
                               middle = false))
        rows.add(VFDDiagStatus("RX", s.packetsHeard.toString(), VFDInk.text, middle = false))
        rows.add(VFDDiagStatus("LIGHTS", s.lightsHeard.toString(), VFDInk.text, middle = false))
        rows.add(VFDDiagStatus("AUTO", if (s.autoEnabled) "ARM" else "OFF", onOffColor(s.autoEnabled), middle = false))
        rows.add(VFDDiagStatus("TX-AUTO", s.autoResponsesSent.toString(), VFDInk.text, middle = false))
        rows.add(relayRow(s))
        val status: String = s.status.ifBlank { "Idle" }
        rows.add(VFDDiagStatus("SERVICE", status.uppercase(), if (btOff) VFDInk.alarm else VFDInk.text,
                               middle = false))
        return rows
    }

    /** onOffColor: cyan (highlight) when on, dim when off. */
    private fun onOffColor(on: Boolean): Int = if (on) VFDInk.highlight else VFDInk.dim

    private fun logText(s: ServiceState.UiState): String {
        if (!s.recordSessionActive) return "OFF"
        if (s.activeSessionName.isEmpty()) return "REC"
        return "REC · " + s.activeSessionName
    }

    /** RELAY as RelayTab names the mode and GattRelayPanel the link: STANDALONE, or the mode with
     *  IPHONE CONNECTED (highlight) / LISTENING (dim, local TX keeps working). */
    private fun relayRow(s: ServiceState.UiState): VFDDiagStatus {
        val mode: String = when (s.relayMode) {
            RelayControlMode.STANDALONE -> return VFDDiagStatus("RELAY", "STANDALONE", VFDInk.text, middle = false)
            RelayControlMode.WIFI_HOTSPOT -> "WIFI"
            RelayControlMode.BLE_GATT -> "BLE GATT"
        }
        val link: String = if (s.relayLinked) "IPHONE CONNECTED" else "LISTENING"
        return VFDDiagStatus("RELAY", "$mode · $link", if (s.relayLinked) VFDInk.highlight else VFDInk.dim,
                             middle = false)
    }

    /** Location for the GPS tags the service writes into every log row: the fine-location
     *  permission and the system location setting, read at most once a second. */
    private fun location(ctx: VFDContext): VFDDiagLocation {
        val second: Long = ctx.time.toLong()
        return ctx.cached("diag.location", second) {
            val context: Context = ctx.context
            val granted: Boolean = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
            val manager: LocationManager? = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            val enabled: Boolean = manager != null && runCatching { LocationManagerCompat.isLocationEnabled(manager) }
                .getOrDefault(false)
            when {
                !granted -> VFDDiagLocation("LOCATION NOT GRANTED", false)
                !enabled -> VFDDiagLocation("LOCATION OFF", false)
                else -> VFDDiagLocation("LOCATION READY", true)
            }
        }
    }

    private fun statusBlock(ctx: VFDContext, c: Int, top: Int, w: Int): Int {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        var y: Int = VFDW.section(fb, L, c, top, w, "STATUS")
        for (row in statusRows(ctx)) {
            y = statusRow(fb, c, y, w, row)
        }
        return y
    }

    /** DiagStatusRow: the key in dim in a fixed column, the value after it, middle-truncated on
     *  one line (the LOG file name) or wrapped to at most valueLines lines. Returns the row after
     *  the last line. */
    private fun statusRow(fb: VFDFrameBuffer, c: Int, top: Int, w: Int, row: VFDDiagStatus): Int {
        var y: Int = top
        fb.textFit(c, y, row.key, keyW - 6, VFDSize.small, VFDInk.dim)
        val vx: Int = c + keyW
        val alarm: Boolean = row.color == VFDInk.alarm
        val vw: Int = c + w - vx - (if (alarm) 4 else 0)
        val lines: List<String> = if (row.middle) listOf(fitMiddle(row.value, vw)) else wrapValue(row.value, vw)
        for (ln in lines) {
            if (alarm && fb.alarmInverted) {
                // 10 rows, so alarm lines one line apart keep a 1-row gap.
                fb.fill(vx, y - 1, VFDText.width(ln) + 4, 10, VFDInk.highlight)
                fb.text(vx + 2, y, ln, VFDSize.small, VFDInk.unlit)
            } else if (alarm) {
                VFDW.alarmText(fb, vx, y, ln)
            } else {
                fb.text(vx, y, ln, VFDSize.small, row.color)
            }
            y += VFDW.line
        }
        return y
    }

    /** s unchanged if it fits in maxCols cells, else its head and tail around "…" (middle
     *  truncation); the head gets the odd character. */
    private fun fitMiddle(s: String, maxCols: Int): String {
        val n: Int = VFDText.maxChars(maxCols)
        val a: IntArray = VFDText.scalars(s)
        if (a.size <= n) return s
        if (n < 3) return VFDText.fit(s, maxCols)
        val keep: Int = n - 1
        val head: Int = VFDMath.floorDiv(keep + 1, 2)
        val tail: Int = keep - head
        val first: IntArray = VFDText.rstrip(a.copyOfRange(0, head))
        var start: Int = a.size - tail
        while (start < a.size && VFDText.isSpace(a[start])) {
            start += 1
        }
        return VFDText.string(first) + VFDText.ellipsis + VFDText.string(a.copyOfRange(start, a.size))
    }

    /** Lines of a status value in a column maxCols cells wide: [s] if it fits; else one break right
     *  after a " · " / " — " separator when both halves fit (the separator ends the first line);
     *  else a word wrap, the lines past valueLines joined onto the last one and cut with …. */
    private fun wrapValue(s: String, maxCols: Int): List<String> {
        val n: Int = VFDText.maxChars(maxCols)
        val a: IntArray = VFDText.scalars(s)
        if (a.size <= n) return listOf(s)
        var bestHead: String? = null
        var bestTail = ""
        var bestLen = -1
        for (sep in valueSeps) {
            val sepS: IntArray = VFDText.scalars(sep)
            val m: Int = sepS.size
            var i = 0
            while (i + m <= a.size) {
                if (a.copyOfRange(i, i + m).contentEquals(sepS)) {
                    val head: String = VFDText.string(a.copyOfRange(0, i)) + " " + VFDText.strip(sep)
                    val tail: String = VFDText.strip(VFDText.string(a.copyOfRange(i + m, a.size)))
                    val headLen: Int = VFDText.length(head)
                    if (headLen <= n && VFDText.length(tail) <= n && headLen > bestLen) {
                        bestHead = head
                        bestTail = tail
                        bestLen = headLen
                    }
                }
                i += 1
            }
        }
        val found: String? = bestHead
        if (found != null && valueLines >= 2) {
            return listOf(found, bestTail)
        }
        val lines: List<String> = VFDText.wrap(s, maxCols)
        if (lines.size > valueLines) {
            val rest: String = lines.subList(valueLines - 1, lines.size).joinToString(" ")
            return lines.subList(0, valueLines - 1) + VFDText.fit(rest, maxCols)
        }
        return lines
    }

    // MARK: - Crash log

    /** CRASH LOG · CLEAN / HAS ENTRIES (a tap opens and closes the log box), CLEAR right-aligned
     *  when the log has entries (under the label when it does not fit beside it). */
    private fun crashHeader(ctx: VFDContext, blank: Boolean, c: Int, y: Int, w: Int): Int {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val label: String = if (blank) "CRASH LOG · CLEAN" else "CRASH LOG · HAS ENTRIES"
        val ty: Int = y + VFDW.ctrlText
        val toggle: () -> Unit = { toggleCrashLog(ctx) }
        if (blank) {
            fb.textFit(c, ty, label, w, VFDSize.small, VFDInk.dim)
            VFDW.tap(fb, c, y, w, VFDW.ctrlH, "crashlog", action = toggle)
            return y + VFDW.ctrlH + VFDW.gap
        }
        val clear = "CLEAR"
        val group: Int = VFDText.width(clear) + 12
        val labelW: Int = VFDText.width(label) + (if (fb.alarmInverted) 4 else 0)
        val oneRow: Boolean = labelW + 6 + group <= w
        val by: Int = if (oneRow) y else y + VFDW.ctrlH + VFDW.gap
        VFDW.button(fb, L, c + w - group, by, group, clear, alarm = true, action = {
            askClearCrashLog(ctx)
        })
        val lw: Int = if (oneRow) w - group - 6 else w
        VFDW.alarmText(fb, c, ty, VFDText.fit(label, lw - 4))
        VFDW.tap(fb, c, y, lw, VFDW.ctrlH, "crashlog", action = toggle)
        return by + VFDW.ctrlH + VFDW.gap
    }

    /** The tail as box lines: the newest crashTail characters, leading and trailing newlines
     *  dropped, every paragraph wrapped (an empty one kept as an empty line). */
    private fun wrapCrashLog(log: String, iw: Int): List<String> {
        val tail: String = log.takeLast(crashTail).trim('\n')
        val lines = ArrayList<String>()
        for (para in tail.split('\n')) {
            val wrapped: List<String> = VFDText.wrap(para, iw)
            if (wrapped.isEmpty()) lines.add("") else lines.addAll(wrapped)
        }
        return lines
    }

    /** The open crash log: a dim box crashBoxLines lines tall with the tail wrapped in dim. When
     *  the tail is longer, the box scrolls on its own by whole lines and a highlight thumb on its
     *  right border shows where. */
    private fun crashBox(ctx: VFDContext, log: String, c: Int, y: Int, w: Int): Int {
        val fb: VFDFrameBuffer = ctx.fb
        val iw: Int = w - 6
        val lines: List<String> = ctx.cached("diag.crashLines", Pair(log, iw)) { wrapCrashLog(log, iw) }
        val shownLines: Int = crashBoxLines
        val h: Int = shownLines * VFDW.line + 3
        fb.box(c, y, w, h, VFDInk.dim)
        val maxFirst: Int = maxOf(0, lines.size - shownLines)
        var first = 0
        if (maxFirst > 0) {
            val limit: Int = maxFirst * VFDW.line
            val s: Int = ctx.scroll(crashRegion, limit = limit)
            first = minOf(maxFirst, VFDMath.floorDiv(s + VFDMath.floorDiv(VFDW.line, 2), VFDW.line))
            // The renderer's drag limit is contentRows minus the region's clipped height.
            val shown: Int = clippedRows(fb, y, h)
            fb.scrollRegion(crashRegion, c, y, w, h, contentRows = limit + shown)
        }
        var i = 0
        while (i < shownLines && first + i < lines.size) {
            fb.text(c + 3, y + 3 + i * VFDW.line, lines[first + i], VFDSize.small, VFDInk.dim)
            i += 1
        }
        if (lines.size > shownLines) {
            val top: Int = y + 2
            val th: Int = h - 4
            val thumb: Int = maxOf(6, VFDMath.floorDiv(th * shownLines, lines.size))
            val ty: Int = top + VFDMath.floorDiv((th - thumb) * first, maxOf(1, maxFirst))
            fb.vline(c + w - 1, ty, thumb, VFDInk.highlight)
        }
        return y + h + VFDW.gap
    }

    /** Rows of r until r + h (drawing coordinates) inside the current clip. */
    private fun clippedRows(fb: VFDFrameBuffer, r: Int, h: Int): Int {
        val clip: VFDRect = fb.clipRect
        val top: Int = maxOf(r + fb.originY, clip.r)
        val bottom: Int = minOf(r + h + fb.originY, clip.r + clip.h)
        return maxOf(0, bottom - top)
    }

    // MARK: - Sources

    /** Divider, BROADCAST SOURCES · n with the rows' unit RSSI DBM right-aligned, PRIORITY = SENT
     *  SHOW/ANIM/COLOR, divider. */
    private fun sourcesHeader(fb: VFDFrameBuffer, c: Int, top: Int, w: Int, count: Int): Int {
        var y: Int = top + VFDW.sectionGap - VFDW.gap
        fb.hline(c, y, w, VFDInk.dim)
        y += 4
        val unitX: Int = fb.textRight(c + w - 1, y, "RSSI DBM", VFDSize.small, VFDInk.dim)
        fb.textFit(c, y, "BROADCAST SOURCES · $count", unitX - 6 - c, VFDSize.small, VFDInk.highlight)
        y += VFDW.line
        fb.textFit(c, y, "PRIORITY = SENT SHOW/ANIM/COLOR", w, VFDSize.small, VFDInk.dim)
        y += 7 + 3
        fb.hline(c, y, w, VFDInk.dim)
        return y + 1 + VFDW.gap
    }

    /** A folding section header with its count, then (open) one row per source. Only the rows that
     *  reach the visible part of the buffer are drawn. */
    private fun sourceSection(ctx: VFDContext, c: Int, top: Int, w: Int, title: String,
                              rows: List<ServiceState.SourceStat>, collapsed: Boolean, key: String,
                              fallback: Boolean): Int {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val ui: VFDUIState = ctx.ui
        var y: Int = VFDW.section(fb, L, c, top, w, title, count = rows.size, collapsed = collapsed, action = {
            ui.toggleBool(key, fallback)
        })
        if (collapsed) return y
        y -= VFDW.gap + 1
        val clip: VFDRect = fb.clipRect
        val visTop: Int = clip.r - fb.originY - 2
        val visBottom: Int = clip.r + clip.h - fb.originY + 2
        for (source in rows) {
            y = if (y + sourceRowH > visTop && y < visBottom) sourceRow(fb, c, y, w, source) else y + sourceRowH
        }
        return y + VFDW.gap
    }

    /** SourceRow: the address (highlight for a priority source, else dim; "(unknown)" when empty)
     *  with BEST n · NOW n right-aligned in dim, "n PKTS · categories" in dim, a dotted divider. The
     *  whole MAC when it fits beside the readings, else its last 8 characters (shortAddress). */
    private fun sourceRow(fb: VFDFrameBuffer, c: Int, r: Int, w: Int, source: ServiceState.SourceStat): Int {
        var y: Int = r + 3
        val rssi = "BEST ${source.bestRssi} · NOW ${source.lastRssi}"
        val rt: String = VFDText.fit(rssi, VFDMath.floorDiv(w * 2, 3))
        val start: Int = c + w - VFDText.width(rt)
        fb.text(start, y, rt, VFDSize.small, VFDInk.dim)
        val room: Int = start - 6 - (c + 2)
        val full: String = source.address
        val address: String = when {
            full.isEmpty() -> "(unknown)"
            VFDText.width(full) <= room -> full
            else -> full.takeLast(8).uppercase()
        }
        val color: Int = if (source.priority) VFDInk.highlight else VFDInk.dim
        fb.textFit(c + 2, y, address, room, VFDSize.small, color)
        y += VFDW.line
        val counts: String = "${source.count} PKTS · " + source.categories.joinToString(" ")
        fb.textFit(c + 2, y, counts, w - 2, VFDSize.small, VFDInk.dim)
        y += 7 + 3
        fb.hline(c, y, w, VFDInk.dim, step = 2)
        return y + 1
    }

    // MARK: - Actions (DiagnosticsTab's)

    /** Opening the log reads it again, so an entry written since the tab appeared shows up. */
    private fun toggleCrashLog(ctx: VFDContext) {
        val ui: VFDUIState = ctx.ui
        val collapsed: Boolean = ui.bool(kCrashCollapsed, true)
        if (collapsed) {
            ui.setInt(kCrashTick, ui.int(kCrashTick) + 1)
            ctx.setScroll(crashRegion, 0)
        }
        ui.setBool(kCrashCollapsed, !collapsed)
    }

    /** CLEAR asks first, then does what DiagnosticsTab does: CrashLog.clear, read it again. */
    private fun askClearCrashLog(ctx: VFDContext) {
        ctx.confirm("Clear crash log?", "CRASH.LOG", confirmLabel = "CLEAR", destructive = true) {
            CrashLog.clear(ctx.context)
            val ui: VFDUIState = ctx.ui
            ui.setInt(kCrashTick, ui.int(kCrashTick) + 1)
        }
    }
}

/** One "KEY  value" line of the status block. */
private class VFDDiagStatus(val key: String, val value: String, val color: Int, val middle: Boolean)

private class VFDDiagLocation(val text: String, val ok: Boolean)

/** Counts the times the tab is opened (a frame gap means it was left; it redraws at least once a
 *  second while shown), so the crash log is read again as DiagnosticsTab does when it is composed.
 *  Both passes of a frame share its time, so they see the same count. */
private object VFDDiagVisits {
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
