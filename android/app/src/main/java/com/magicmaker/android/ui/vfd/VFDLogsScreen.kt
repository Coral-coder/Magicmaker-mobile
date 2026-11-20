package com.magicmaker.android.ui.vfd

import com.magicmaker.android.core.MagicClassifier
import com.magicmaker.android.data.MagicStore
import com.magicmaker.android.service.MagicMakerForegroundService
import com.magicmaker.android.service.ServiceState
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * LOGS tab in the VFD theme: tools/vfd/screens/logs.py on the real capture logs (port of
 * ios/MagicMaker/VFD/VFDLogsScreen.swift, behaviour of the standard LogsTab).
 *
 * Pinned rows (STATUS: <service status>, the CLOUD line with SYNC NOW when cloud sync is set up,
 * the replay banner with STOP while a replay runs, a hairline), then the log list, newest first,
 * in its own scroll region: name (inverted while open, a boxed REC while it is being written) over
 * "<n> PKTS · <kb>KB · <ago> AGO". Under the open log: the type and source filter chips and BAND
 * ONLY, REPLAY / DELETE, ANALYZE (HIDE PACKETS) and ADD ALL → LIB, then the distinct packets (tap =
 * TX, NAME = add to the library) or the packet rows in log order (tap = TX). The logs are listed
 * and read the way LogsTab does it (MagicStore.listLogs / readLog, again on REFRESH, when a
 * recording starts or stops and when the tab is opened again); DELETE asks first, NAME prompts,
 * results are system toasts as on the standard screen.
 */
object VFDLogsScreen : VFDScreen {
    override val title: String = "CAPTURE LOGS"

    /** Scroll region id of the log list. */
    const val listRegion: String = "list"
    /** The open log's rows: .padding(start = 8.dp). */
    const val indent: Int = 6
    /** A PacketRow with hex and subtitle. */
    const val packetRowH: Int = 36
    /** A log row / an analysed row. */
    const val fileRowH: Int = 25
    const val analyzedRowH: Int = 25
    /** Packet rows listed for an open log. */
    const val packetRowLimit: Int = 1000
    /** LogsTab: analyzed.take(300). */
    const val analyzedRowLimit: Int = 300
    /** LogsTab: addresses.take(12). */
    const val sourceChipLimit: Int = 12
    val stopW: Int = VFDText.width("STOP") + 12
    const val emptyText: String = "NO LOGS YET — START A SCAN"
    const val allNoiseText: String =
        "EVERYTHING IN THIS FILTER IS BAND TELEMETRY OR PINGS — FLIP THE SWITCH TO SEE IT"
    /** Drawing rows far above everything: the measuring pass draws no list rows. */
    const val farAway: Int = -1_000_000

    // In-memory UI keys (LogsTab's remember state).
    private const val kRefresh: String = "refreshTick"
    private const val kOpen: String = "selectedPath"
    private const val kCats: String = "selectedCats"
    private const val kAddr: String = "selectedAddr"
    private const val kBandOnly: String = "bandOnly"
    private const val kAnalyzing: String = "analyzing"
    private const val kHideNoise: String = "hideNoise"

    /** REFRESH, as LogsTab's header: lists the logs again and re-reads the open one. */
    override fun headerRight(ctx: VFDContext): VFDHeaderRight? = VFDHeaderRight("REFRESH") {
        refresh(ctx)
    }

    override fun draw(ctx: VFDContext): Int? {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val c: Int = L.left
        val w: Int = L.width
        val view: VFDLogsView = view(ctx)
        // The status line, the banner and the hairline stay put (above the LazyColumn).
        val scroll: Int = -fb.originY
        fb.pushClip(0, L.contentTop + scroll, fb.cols, L.contentH, dy = scroll)
        val listTop: Int = pinned(ctx, c, L.contentTop, w)
        if (view.logs.isEmpty()) {
            emptyState(ctx, c, listTop, w)
        } else {
            drawList(ctx, view, c, listTop, w)
        }
        fb.popClip()
        return null
    }

    // MARK: - State (read only)

    /** Everything a frame shows, from the store (cached per revision) and this tab's UI state. */
    private fun view(ctx: VFDContext): VFDLogsView {
        val ui: VFDUIState = ctx.ui
        val s: ServiceState.UiState = ctx.state
        val tick: Int = ui.int(kRefresh)
        val visit: Int = VFDLogsVisits.at(ctx.time)
        // LogsTab: remember(refreshTick, state.recordSessionActive) { listLogs() }, and again each
        // time the tab is opened.
        val logs: List<MagicStore.LogFile> = ctx.cached("logs.list", Triple(tick, s.recordSessionActive, visit)) {
            runCatching { ctx.store.listLogs() }.getOrDefault(emptyList())
        }
        val path: String? = ui.optionalString(kOpen)
        val listed: String? = if (path != null && logs.any { it.path == path }) path else null
        // remember(selectedPath, refreshTick) { readLog(it) }
        val open: VFDLogsOpen? = ctx.cached("logs.open", Pair(listed, tick)) {
            if (listed == null) null else readOpen(ctx.store, listed)
        }
        val cats: Set<String> = ui.strings(kCats)
        val addr: String = ui.string(kAddr)
        val bandOnly: Boolean = ui.bool(kBandOnly)
        val analyzing: Boolean = ui.bool(kAnalyzing)
        val hideNoise: Boolean = ui.bool(kHideNoise, true)
        var filtered: VFDLogsFiltered? = null
        var analysis: VFDLogsAnalysis? = null
        if (open != null) {
            val f: VFDLogsFiltered = filtered(ctx, open, cats, addr, bandOnly)
            filtered = f
            if (analyzing) {
                analysis = analysis(ctx, f, hideNoise)
            }
        } else {
            // Nothing open: let go of the last log's filtered rows and analysis.
            ctx.cached<Any?>("logs.filtered", null) { null }
            ctx.cached<Any?>("logs.analysis", null) { null }
        }
        return VFDLogsView(logs, path, open, cats, addr, bandOnly, analyzing, hideNoise, filtered, analysis)
    }

    private fun readOpen(store: MagicStore, path: String): VFDLogsOpen {
        val packets: List<MagicStore.LoggedPacket> = store.readLog(path)
        val categories: List<String> = packets.map { it.category }.filter { it.isNotEmpty() }.distinct().sorted()
        val addresses: List<String> = packets.map { it.sourceAddress }.filter { it.isNotEmpty() }.distinct()
        return VFDLogsOpen(path, packets, categories, addresses)
    }

    /** LogsTab's `filtered`: type chips (none = all), the one source, BAND ONLY. */
    private fun filtered(ctx: VFDContext, open: VFDLogsOpen, cats: Set<String>, addr: String,
                         bandOnly: Boolean): VFDLogsFiltered {
        return ctx.cached("logs.filtered", VFDLogsFilterKey(open, cats, addr, bandOnly)) {
            val rows: List<MagicStore.LoggedPacket> = open.packets
                .filter { cats.isEmpty() || it.category in cats }
                .filter { addr.isEmpty() || it.sourceAddress == addr }
                .filter { !bandOnly || it.isBand }
            VFDLogsFiltered(rows)
        }
    }

    /** LogsTab's `noiseCount` and `analyzed`: one row per groupKey (noise hidden unless the switch
     *  is off), labelled by one classify() per group, most frequent first. */
    private fun analysis(ctx: VFDContext, f: VFDLogsFiltered, hideNoise: Boolean): VFDLogsAnalysis {
        return ctx.cached("logs.analysis", Pair(f, hideNoise)) {
            val noise: Int = f.rows.count { MagicClassifier.isLibraryNoise(it.hex) }
            val rows: List<VFDLogsAnalyzed> = f.rows.asSequence()
                .filter { !hideNoise || !MagicClassifier.isLibraryNoise(it.hex) }
                .groupBy { MagicClassifier.groupKey(it.hex) }
                .map { (_, list) ->
                    val sample: MagicStore.LoggedPacket = list.first()
                    val classified = MagicClassifier.classify(sample.hex)
                    val label: String = classified?.label ?: MagicClassifier.rawLabel(sample.hex)
                    VFDLogsAnalyzed(sample.hex, label, sample.category, list.size)
                }
                .sortedByDescending { it.count }
            VFDLogsAnalysis(rows, noise)
        }
    }

    /** The log being written right now. */
    private fun isActiveLog(s: ServiceState.UiState, log: MagicStore.LogFile): Boolean {
        return s.recordSessionActive && s.activeSessionName.isNotEmpty() && s.activeSessionName == log.name
    }

    // MARK: - Pinned top

    /** STATUS line, the CLOUD line, the replay banner, the hairline. Returns the list's first row. */
    private fun pinned(ctx: VFDContext, c: Int, top: Int, w: Int): Int {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val s: ServiceState.UiState = ctx.state
        val warn: Boolean = isWarningStatus(s.status)
        val color: Int = if (warn) VFDInk.alarm else VFDInk.dim
        var y: Int = VFDW.statusLine(fb, L, c, top, w, "STATUS: " + s.status, color = color)
        if (ctx.cached("logs.cloud", 0) { ctx.store.cloudSyncConfigured() }) {
            y = cloudRow(ctx, c, y, w)
        }
        y = replayBanner(ctx, c, y + 1, w) - VFDW.gap
        fb.hline(c, y + 3, w, VFDInk.dim)
        return y + 7
    }

    /** The service statuses that are warnings (the iPhone's not-linked / send-failed): Bluetooth
     *  off or missing, and the scan / relay errors and failures the service reports. */
    private fun isWarningStatus(status: String): Boolean =
        status == "Turn on Bluetooth" || status == "Bluetooth unavailable" ||
            status.contains("error", ignoreCase = true) || status.contains("failed", ignoreCase = true)

    /** LogsTab's cloud row (Android only): CLOUD: <status> with SYNC NOW (cyan text button). */
    private fun cloudRow(ctx: VFDContext, c: Int, y: Int, w: Int): Int {
        val fb: VFDFrameBuffer = ctx.fb
        val status: String = ctx.state.cloudSyncStatus.ifBlank { "idle" }
        val button: String = "SYNC NOW"
        val bw: Int = VFDText.width(button)
        val bx: Int = c + w - bw
        fb.text(bx, y, button, VFDSize.small, VFDInk.highlight)
        fb.textFit(c, y, VFDW.upper("CLOUD: $status"), bx - 6 - c, VFDSize.small, VFDInk.dim)
        VFDW.tap(fb, bx - 3, y - 2, bw + 6, 11, "button:$button", action = {
            ctx.store.cloudSync(force = true)
        })
        return y + VFDW.line
    }

    /** While a replay runs: a solid highlight block with "REPLAYING n/total · label" cut out (two
     *  lines at most, the first beside STOP), STOP a cut-out outline button on the right. */
    private fun replayBanner(ctx: VFDContext, c: Int, y: Int, w: Int): Int {
        val s: ServiceState.UiState = ctx.state
        if (!s.replayActive) return y
        val fb: VFDFrameBuffer = ctx.fb
        val h = 29
        fb.fill(c, y, w, h, VFDInk.highlight)
        val sx: Int = c + w - 3 - stopW
        fb.box(sx, y + 2, stopW, VFDW.ctrlH, VFDInk.unlit)
        fb.text(sx + 6, y + 2 + VFDW.ctrlText, "STOP", VFDSize.small, VFDInk.unlit)
        VFDLogsText.growTap(fb, sx - 2, y + 2, stopW + 4, VFDW.ctrlH, "button:STOP", action = {
            MagicMakerForegroundService.stopReplay(ctx.context)
        })
        val text: String = "REPLAYING ${s.replayProgress}/${s.replayTotal} · ${s.replayLabel}"
        val x: Int = c + 4
        val firstW: Int = sx - 6 - x
        val fullW: Int = c + w - 4 - x
        val words: ArrayList<String> = ArrayList(VFDLogsText.splitString(text, " "))
        var line1 = ""
        while (words.isNotEmpty()) {
            val cand: String = VFDText.strip(line1 + " " + words[0])
            if (VFDText.width(cand) > firstW) break
            line1 = cand
            words.removeAt(0)
        }
        var line2: String = words.joinToString(" ")
        if (line2.isNotEmpty()) {
            val kept: List<String> = VFDLogsText.dropDangling(listOf(line1, line2))
            line1 = if (kept.isNotEmpty()) kept[0] else ""
            line2 = if (kept.size > 1) kept[1] else ""
        }
        fb.text(x, y + 5, line1, VFDSize.small, VFDInk.unlit)
        if (line2.isNotEmpty()) {
            fb.textFit(x, y + 17, line2, fullW, VFDSize.small, VFDInk.unlit)
        }
        return y + h + VFDW.gap
    }

    /** NO LOGS YET — START A SCAN, centred in the space. */
    private fun emptyState(ctx: VFDContext, c: Int, y: Int, w: Int) {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val lines: List<String> = VFDLogsText.captionLines(emptyText, w - 10)
        val half: Int = VFDMath.floorDiv(lines.size * VFDW.line, 2)
        val mid: Int = maxOf(y, VFDMath.floorDiv(y + L.contentBottom, 2) - half)
        for ((i, ln) in lines.withIndex()) {
            fb.text(VFDW.cx(c, w, ln), mid + i * VFDW.line, ln, VFDSize.small, VFDInk.dim)
        }
    }

    // MARK: - The list

    /** The list in rows listTop until contentBottom: measured (drawn into an empty clip), scrolled
     *  by its own region, drawn inside a window that hides lines cut by the edges, then its
     *  scrollbar. */
    private fun drawList(ctx: VFDContext, v: VFDLogsView, c: Int, listTop: Int, w: Int) {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val bottom: Int = L.contentBottom
        val viewH: Int = bottom - listTop
        if (viewH <= 0) return
        val far = VFDWindow(farAway, farAway)
        fb.pushClip(0, 0, 0, 0)
        val end: Int = logList(ctx, v, fb, c, listTop, w, far)
        fb.popClip()
        val total: Int = end - listTop
        val s: Int = ctx.scroll(listRegion, limit = total - viewH)
        // The renderer's drag limit is contentRows minus the region's clipped height.
        val shownRows: Int = VFDLogsText.clippedRows(fb, listTop, viewH)
        fb.scrollRegion(listRegion, 0, listTop, fb.cols, viewH, contentRows = total - viewH + shownRows)

        fb.pushClip(0, listTop, fb.cols, viewH, dy = -s)
        val vis = VFDWindow(listTop + s, bottom + s)
        val win: VFDWindow = VFDW.snappedWindow(fb, top = listTop, bottom = bottom) { target ->
            logList(ctx, v, target, c, listTop, w, vis)
        }
        val firstTap: Int = fb.taps.size
        fb.pushClip(0, win.top - fb.originY, fb.cols, win.bottom - win.top)
        logList(ctx, v, fb, c, listTop, w, vis)
        fb.popClip()
        VFDLogsText.dropShortTaps(fb, firstTap)
        fb.popClip()
        VFDW.listScrollbar(fb, listTop, viewH, total, s)
    }

    /** Every log row, the open one followed by its detail rows. Rows outside `vis` (drawing rows)
     *  are only counted. Returns the end row. */
    private fun logList(ctx: VFDContext, v: VFDLogsView, fb: VFDFrameBuffer, c: Int, top: Int, w: Int,
                        vis: VFDWindow): Int {
        var y: Int = top
        for (log in v.logs) {
            val visible: Boolean = y + fileRowH + 2 > vis.top && y - 2 < vis.bottom
            y = if (visible) logRow(ctx, v, fb, c, y, w, log) else y + fileRowH
            if (v.selectedPath == log.path && v.open != null) {
                y = detailRows(ctx, v, v.open, fb, c, y, w, log, vis)
            }
        }
        return y
    }

    /** The name (text; the open log an inverted block) with a boxed REC while it is being written,
     *  "<n> PKTS · <kb>KB · <ago> AGO" in dim, a dotted divider. Tap opens / closes it. */
    private fun logRow(ctx: VFDContext, v: VFDLogsView, fb: VFDFrameBuffer, c: Int, r: Int, w: Int,
                       log: MagicStore.LogFile): Int {
        val selected: Boolean = v.selectedPath == log.path
        val active: Boolean = isActiveLog(ctx.state, log)
        var y: Int = r + 3
        var x: Int = c + 2
        val tagW: Int = if (active) VFDText.width("REC") + 8 else 0
        val shown: String = VFDLogsText.fitMiddle(log.name, w - 4 - tagW)
        x = if (selected) {
            VFDW.badge(fb, x, y, shown, VFDInk.highlight)
        } else {
            fb.text(x, y, shown, VFDSize.small, VFDInk.text) + 1
        }
        if (active) {
            VFDW.tagBox(fb, x + 4, y, "REC", color = VFDInk.highlight, textColor = VFDInk.highlight)
        }
        var detail = "${log.packetCount} PKTS · ${log.sizeBytes / 1024}KB"
        val ago: String = VFDLogsText.agoText(log.modifiedMs, ctx.time)
        if (ago.isNotEmpty()) {
            detail += " · " + ago.uppercase() + " AGO"
        }
        y += VFDW.line
        fb.textFit(c + 2, y, detail, w - 2, VFDSize.small, VFDInk.dim)
        y += 7 + 3
        fb.hline(c, y, w, VFDInk.dim, step = 2)
        val path: String = log.path
        VFDLogsText.growTap(fb, c, r, w, y - r, "log:" + log.name, action = {
            toggleSelection(ctx, path)
        })
        return y + 1
    }

    // MARK: - The open log

    /** Everything under the open log, indented: the filters, the two button rows, then the
     *  analysis or the packet rows. */
    private fun detailRows(ctx: VFDContext, v: VFDLogsView, open: VFDLogsOpen, fb: VFDFrameBuffer, c0: Int,
                           top: Int, w0: Int, log: MagicStore.LogFile, vis: VFDWindow): Int {
        val c: Int = c0 + indent
        val w: Int = w0 - indent
        var y: Int = filterRows(ctx, v, open, fb, c, top, w)
        val path: String = log.path
        val name: String = log.name
        val replay = VFDLogsButton("REPLAY", VFDInk.text, enabled = !ctx.state.replayActive, expand = true) {
            startReplay(ctx, path)
        }
        val delete = VFDLogsButton("DELETE", VFDInk.alarm, enabled = true, expand = false) {
            askDelete(ctx, path, name)
        }
        y = VFDLogsText.buttonRow(fb, c, y, w, listOf(replay, delete))
        val analyzeLabel: String = if (v.analyzing) "HIDE PACKETS" else "ANALYZE"
        val analyze = VFDLogsButton(analyzeLabel, VFDInk.text, enabled = true, expand = true) {
            ctx.ui.toggleBool(kAnalyzing)
        }
        val filtered: VFDLogsFiltered? = v.filtered
        val hideNoise: Boolean = v.hideNoise
        val addAll = VFDLogsButton("ADD ALL → LIB", VFDInk.text, enabled = filtered != null, expand = true) {
            if (filtered != null) {
                addAllToLibrary(ctx, analysis(ctx, filtered, hideNoise))
            }
        }
        y = VFDLogsText.buttonRow(fb, c, y, w, listOf(analyze, addAll))
        if (filtered == null) return y
        val analysis: VFDLogsAnalysis? = v.analysis
        if (v.analyzing && analysis != null) {
            return analyzeRows(ctx, v, fb, c, y, w, filtered, analysis, vis)
        }
        return packetRows(ctx, fb, c, y, w, filtered, vis)
    }

    /** FILTER TYPES chips, FILTER SOURCE chips (at most 12), BAND ONLY. */
    private fun filterRows(ctx: VFDContext, v: VFDLogsView, open: VFDLogsOpen, fb: VFDFrameBuffer, c: Int,
                           top: Int, w: Int): Int {
        val L: VFDLayout = ctx.L
        val ui: VFDUIState = ctx.ui
        var y: Int = top
        val categories: List<String> = open.categories
        if (categories.isNotEmpty()) {
            y = VFDLogsText.caption(fb, L, c, y, w, "FILTER TYPES (NONE = ALL)")
            val selected = HashSet<Int>()
            for ((i, category) in categories.withIndex()) {
                if (category in v.cats) selected.add(i)
            }
            y = VFDW.options(fb, L, c, y, w, categories, selected = selected, name = "filter:type",
                             onSelect = { index ->
                                 if (index >= 0 && index < categories.size) {
                                     ui.toggleMember(kCats, categories[index])
                                 }
                             })
        }
        if (open.addresses.isNotEmpty()) {
            y = VFDLogsText.caption(fb, L, c, y, w, "FILTER SOURCE (TAP = ONLY THAT SOURCE)")
            val addresses: List<String> = open.addresses.take(sourceChipLimit)
            val chips = ArrayList<String>(addresses.size)
            val selected = HashSet<Int>()
            for ((i, address) in addresses.withIndex()) {
                chips.add(VFDLogsText.shortAddress(address))
                if (address == v.addr) selected.add(i)
            }
            y = VFDW.options(fb, L, c, y, w, chips, selected = selected, name = "filter:source",
                             onSelect = { index ->
                                 if (index >= 0 && index < addresses.size) {
                                     val a: String = addresses[index]
                                     ui.setString(kAddr, if (ui.string(kAddr) == a) "" else a)
                                 }
                             })
        }
        return VFDW.toggle(fb, L, c, y, w, "BAND ONLY", v.bandOnly, labelColor = VFDInk.dim, action = {
            ui.toggleBool(kBandOnly)
        })
    }

    /** ANALYZE: HIDE BANDS & PINGS, the hint, one analysed row per distinct packet (at most 300),
     *  "…and n more". */
    private fun analyzeRows(ctx: VFDContext, v: VFDLogsView, fb: VFDFrameBuffer, c: Int, top: Int, w: Int,
                            filtered: VFDLogsFiltered, analysis: VFDLogsAnalysis, vis: VFDWindow): Int {
        val L: VFDLayout = ctx.L
        val ui: VFDUIState = ctx.ui
        val noiseLabel = "HIDE BANDS & PINGS (${analysis.noiseCount} OF ${filtered.rows.size})"
        var y: Int = VFDLogsText.wrappedToggle(fb, L, c, top, w, noiseLabel, v.hideNoise, action = {
            ui.toggleBool(kHideNoise, true)
        })
        val rows: List<VFDLogsAnalyzed> = analysis.rows
        y = if (rows.isEmpty() && analysis.noiseCount > 0) {
            VFDLogsText.noteLines(fb, c, y + 1, w, allNoiseText, color = VFDInk.highlight)
        } else {
            VFDLogsText.noteLines(fb, c, y + 1, w, "${rows.size} UNIQUE · TAP = TX · NAME = ADD")
        }
        y -= VFDW.gap
        fb.hline(c, y, w, VFDInk.dim, step = 2)
        y += 1
        val shown: Int = minOf(rows.size, analyzedRowLimit)
        val rowH: Int = analyzedRowH
        val first: Int = maxOf(0, VFDMath.floorDiv(vis.top - y, rowH) - 1)
        val last: Int = minOf(shown, VFDMath.floorDiv(vis.bottom - y, rowH) + 2)
        for (i in first until last) {
            analyzedRow(ctx, fb, c, y + i * rowH, w, rows[i])
        }
        y += shown * rowH
        if (rows.size > analyzedRowLimit) {
            val hidden: Int = rows.size - analyzedRowLimit
            y = VFDLogsText.noteLines(fb, c, y, w, "…and $hidden more (showing top $analyzedRowLimit)")
        }
        return y
    }

    /** "×count · LABEL" over the hex (dim), NAME on the right, a dotted divider. Tap the text = TX,
     *  NAME = save to the library under a new name. */
    private fun analyzedRow(ctx: VFDContext, fb: VFDFrameBuffer, c: Int, r: Int, w: Int,
                            row: VFDLogsAnalyzed): Int {
        val L: VFDLayout = ctx.L
        val bw: Int = VFDText.width("NAME") + 12
        val bx: Int = c + w - bw
        val tw: Int = bx - 6 - c
        val y: Int = r + 3
        fb.textFit(c, y, VFDW.upper("×${row.count} · " + row.label), tw, VFDSize.small, VFDInk.text)
        fb.textFit(c, y + VFDW.line, row.hex, tw, VFDSize.small, VFDInk.dim)
        VFDW.button(fb, L, bx, r + 5, bw, "NAME", name = "name:" + row.label, action = {
            askName(ctx, row)
        })
        val end: Int = y + VFDW.line + 7 + 3
        fb.hline(c, end, w, VFDInk.dim, step = 2)
        val hex: String = row.hex
        fb.tap(c, r, bx - 2 - c, end - r, name = "tx:" + row.label, action = {
            MagicMakerForegroundService.transmit(ctx.context, hex)
        })
        return end + 1
    }

    /** The filtered rows in log order: the hint, the PacketRows (at most 1000, only the ones in
     *  view drawn), "…and n more". */
    private fun packetRows(ctx: VFDContext, fb: VFDFrameBuffer, c: Int, top: Int, w: Int,
                           filtered: VFDLogsFiltered, vis: VFDWindow): Int {
        val L: VFDLayout = ctx.L
        val count: Int = filtered.rows.size
        var y: Int = VFDLogsText.noteLines(fb, c, top + 1, w, "$count PACKETS · TAP = TX")
        y -= VFDW.gap
        val shown: Int = minOf(count, packetRowLimit)
        val rowH: Int = packetRowH
        val first: Int = maxOf(0, VFDMath.floorDiv(vis.top - y, rowH) - 1)
        val last: Int = minOf(shown, VFDMath.floorDiv(vis.bottom - y, rowH) + 2)
        for (i in first until last) {
            val packet: MagicStore.LoggedPacket = filtered.rows[i]
            val label: String = VFDLogsText.packetLabel(packet)
            val sub: String = VFDLogsText.packetSubtitle(packet, w - 2)
            val tag: String? = if (packet.isBand) "BAND" else null
            val hex: String = packet.hex
            VFDW.packetRow(fb, L, c, y + i * rowH, w, label, hex, subtitle = sub, tag = tag,
                           hexColor = VFDInk.dim, action = {
                               MagicMakerForegroundService.transmit(ctx.context, hex)
                           })
        }
        y += shown * rowH
        if (count > packetRowLimit) {
            val hidden: Int = count - packetRowLimit
            y = VFDLogsText.noteLines(fb, c, y, w, "…and $hidden more (showing first $packetRowLimit)")
        }
        return y
    }

    // MARK: - Actions (LogsTab's)

    private fun refresh(ctx: VFDContext) {
        val ui: VFDUIState = ctx.ui
        ui.setInt(kRefresh, ui.int(kRefresh) + 1)
    }

    /** Tap a log: open it, or close it when it is the open one; the filters start over. */
    private fun toggleSelection(ctx: VFDContext, path: String) {
        val ui: VFDUIState = ctx.ui
        val next: String? = if (ui.optionalString(kOpen) == path) null else path
        ui.setOptionalString(kOpen, next)
        resetFilters(ui)
    }

    /** LogsTab's remember(selectedPath) state starts over with every selection. */
    private fun resetFilters(ui: VFDUIState) {
        ui.setStrings(kCats, emptySet())
        ui.setString(kAddr, "")
        ui.setBool(kBandOnly, false)
        ui.setBool(kAnalyzing, false)
        ui.setBool(kHideNoise, true)
    }

    private fun startReplay(ctx: VFDContext, path: String) {
        val ui: VFDUIState = ctx.ui
        MagicMakerForegroundService.replay(ctx.context, path, ui.strings(kCats).toList(), ui.string(kAddr),
                                           ui.bool(kBandOnly))
    }

    /** DELETE asks first, then does what LogsTab does: deleteLog, nothing open, list again. */
    private fun askDelete(ctx: VFDContext, path: String, name: String) {
        ctx.confirm("Delete log?", name, confirmLabel = "DELETE", destructive = true) {
            ctx.store.deleteLog(path)
            val ui: VFDUIState = ctx.ui
            if (ui.optionalString(kOpen) == path) {
                ui.setOptionalString(kOpen, null)
                resetFilters(ui)
            }
            refresh(ctx)
            ctx.toast("Log deleted")
        }
    }

    private fun addAllToLibrary(ctx: VFDContext, analysis: VFDLogsAnalysis) {
        val added: Int = ctx.store.importHexesToLibrary(analysis.rows.map { it.hex })
        refresh(ctx)
        ctx.toast("Added $added to library")
    }

    /** RenameDialog(currentLabel = row.label): SAVE is disabled while blank. */
    private fun askName(ctx: VFDContext, row: VFDLogsAnalyzed) {
        ctx.prompt("Rename packet", text = row.label, keyboard = VFDKeyboard.text) { entered ->
            if (entered.isBlank()) return@prompt
            val error: String? = ctx.store.saveCustomPreset(entered.ifBlank { row.label }, row.hex)
            refresh(ctx)
            ctx.toast(error ?: "Added \"$entered\" to library")
        }
    }
}

// MARK: - Screen state

/** One frame's data: the listed logs, the open one (read), its filters and their results. */
private class VFDLogsView(
    val logs: List<MagicStore.LogFile>,
    val selectedPath: String?,
    val open: VFDLogsOpen?,
    val cats: Set<String>,
    val addr: String,
    val bandOnly: Boolean,
    val analyzing: Boolean,
    val hideNoise: Boolean,
    val filtered: VFDLogsFiltered?,
    val analysis: VFDLogsAnalysis?,
)

/** The open log's rows, with its type chips (sorted) and source chips (first heard first). */
private class VFDLogsOpen(
    val path: String,
    val packets: List<MagicStore.LoggedPacket>,
    val categories: List<String>,
    val addresses: List<String>,
)

private data class VFDLogsFilterKey(val open: VFDLogsOpen, val cats: Set<String>, val addr: String,
                                    val bandOnly: Boolean)

private class VFDLogsFiltered(val rows: List<MagicStore.LoggedPacket>)

private class VFDLogsAnalysis(val rows: List<VFDLogsAnalyzed>, val noiseCount: Int)

/** A distinct packet from a log, with how many times it appeared (LogsTab's AnalyzedPacket). */
private class VFDLogsAnalyzed(val hex: String, val label: String, val category: String, val count: Int)

/** One outline button of a button row: fixed buttons hug their label, expanding ones share the
 *  rest. */
private class VFDLogsButton(
    val label: String,
    val color: Int,
    val enabled: Boolean,
    val expand: Boolean,
    val action: () -> Unit,
)

/** Counts the times the tab is opened (a frame gap means it was left; it redraws at least once a
 *  second while shown), so the logs are listed again as LogsTab does when it is composed. Both
 *  passes of a frame share its time, so they see the same count. */
private object VFDLogsVisits {
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

// MARK: - Drawing helpers (logs.py)

private object VFDLogsText {
    const val sep: String = " · "

    /** Time of day on a packet row (main thread only). */
    private val timeFormatter: SimpleDateFormat = SimpleDateFormat("HH:mm:ss", Locale.US)

    // MARK: strings

    fun splitString(s: String, sep: String): List<String> =
        VFDText.split(VFDText.scalars(s), VFDText.scalars(sep)).map { VFDText.string(it) }

    fun rstrip(s: String): String = VFDText.string(VFDText.rstrip(VFDText.scalars(s)))

    fun lstrip(s: String): String {
        val a: IntArray = VFDText.scalars(s)
        var i = 0
        while (i < a.size && VFDText.isSpace(a[i])) {
            i += 1
        }
        return VFDText.string(a.copyOfRange(i, a.size))
    }

    private fun dropLastScalar(s: String): String {
        val a: IntArray = VFDText.scalars(s)
        if (a.isEmpty()) return s
        return VFDText.string(a.copyOfRange(0, a.size - 1))
    }

    private fun dropFirstScalar(s: String): String {
        val a: IntArray = VFDText.scalars(s)
        if (a.isEmpty()) return s
        return VFDText.string(a.copyOfRange(1, a.size))
    }

    /** shortAddress(): the last 8 characters, uppercased; empty stays empty. */
    fun shortAddress(address: String): String = if (address.isEmpty()) "" else address.takeLast(8).uppercase()

    /** s, or its head and tail around "…" so it fits maxCols (middle truncation). */
    fun fitMiddle(s: String, maxCols: Int): String {
        val n: Int = VFDText.maxChars(maxCols)
        val a: IntArray = VFDText.scalars(s)
        if (a.size <= n) return s
        if (n <= 1) return VFDText.fit(s, maxCols)
        val keep: Int = n - 1
        val head: Int = VFDMath.floorDiv(keep + 1, 2)
        val tail: Int = keep - head
        return VFDText.string(a.copyOfRange(0, head)) + VFDText.ellipsis +
            VFDText.string(a.copyOfRange(a.size - tail, a.size))
    }

    /** Wrapped lines without a separator left hanging at a break: a trailing " ·" is cut from every
     *  line but the last and a leading "· " from every line but the first (logs.py drop_dangling). */
    fun dropDangling(lines: List<String>): List<String> {
        val out = ArrayList<String>()
        val n: Int = lines.size
        for ((i, ln) in lines.withIndex()) {
            var s: String = ln
            if (i < n - 1) {
                while (true) {
                    val r: String = rstrip(s)
                    if (r.endsWith(" ·") || VFDText.strip(s) == "·") {
                        s = rstrip(dropLastScalar(r))
                    } else {
                        break
                    }
                }
            }
            if (i > 0) {
                while (true) {
                    val l: String = lstrip(s)
                    if (l.startsWith("· ")) {
                        s = lstrip(dropFirstScalar(l))
                    } else {
                        break
                    }
                }
            }
            if (s.isNotEmpty() || ln.isEmpty()) {
                out.add(s)
            }
        }
        return out
    }

    /** A caption broken into lines of at most w cells: at its " · " separators (dropped at the
     *  break), before a "(…)" aside, then at spaces, then truncated with …. */
    fun captionLines(s: String, w: Int): List<String> {
        if (VFDText.width(s) <= w) return listOf(s)
        val paren: Int = s.indexOf(" (")
        if (paren >= 0 && !s.contains(sep)) {
            val head: String = s.substring(0, paren)
            val tail: String = s.substring(paren + 2)
            if (VFDText.width(head) <= w) {
                return listOf(head) + captionLines("($tail", w)
            }
        }
        val lines = ArrayList<String>()
        var cur = ""
        for (part in splitString(s, sep)) {
            val cand: String = if (cur.isEmpty()) part else cur + sep + part
            if (cur.isNotEmpty() && VFDText.width(cand) > w) {
                lines.add(cur)
                cur = part
            } else {
                cur = cand
            }
        }
        lines.add(cur)
        val out = ArrayList<String>()
        for (ln in lines) {
            if (VFDText.width(ln) > w) {
                out.addAll(VFDText.wrap(ln, w))
            } else {
                out.add(ln)
            }
        }
        return dropDangling(out).map { VFDText.fit(it, w) }
    }

    /** agoText(ms) at the frame's time (epoch seconds): 3s, 2m, 1h, 4d; empty for a time never
     *  set. */
    fun agoText(ms: Long, now: Double): String {
        if (ms <= 0L) return ""
        val nowMs: Long = (now * 1000.0).toLong()
        val seconds: Long = maxOf(0L, nowMs - ms) / 1000L
        if (seconds < 60) return "${seconds}s"
        val minutes: Long = seconds / 60
        if (minutes < 60) return "${minutes}m"
        val hours: Long = minutes / 60
        if (hours < 24) return "${hours}h"
        return "${hours / 24}d"
    }

    fun packetLabel(packet: MagicStore.LoggedPacket): String {
        if (packet.label.isEmpty()) return MagicClassifier.rawLabel(packet.hex)
        return packet.label
    }

    /** "<time> · RSSI <n> · <category> · <source>" in at most maxCols cells: the short source is
     *  never cut; when the line is too long the category gives way first (truncated with …, or
     *  left out when fewer than 3 of its characters would show). */
    fun packetSubtitle(packet: MagicStore.LoggedPacket, maxCols: Int): String {
        val stamp: String = timeFormatter.format(Date(packet.timestampMs))
        val head = "$stamp · RSSI ${packet.rssi}"
        val src: String = shortAddress(packet.sourceAddress)
        val tail: String = if (src.isEmpty()) "" else " · $src"
        val category: String = packet.category
        val middle: String = if (category.isEmpty()) "" else " · $category"
        val full: String = head + middle + tail
        if (VFDText.width(full) <= maxCols || category.isEmpty()) return full
        val room: Int = VFDText.maxChars(maxCols) - VFDText.length(head) - 3 - VFDText.length(tail)
        if (room >= 3) {
            return head + " · " + VFDText.fit(category, VFDText.width(count = room)) + tail
        }
        return head + tail
    }

    // MARK: pieces

    /** Rows of r until r + h (drawing coordinates) inside the current clip. */
    fun clippedRows(fb: VFDFrameBuffer, r: Int, h: Int): Int {
        val clip: VFDRect = fb.clipRect
        val top: Int = maxOf(r + fb.originY, clip.r)
        val bottom: Int = minOf(r + h + fb.originY, clip.r + clip.h)
        return maxOf(0, bottom - top)
    }

    /** Drops the taps from index [from] that the window cut below the minimum tap height. */
    fun dropShortTaps(fb: VFDFrameBuffer, from: Int) {
        val taps: MutableList<VFDHit> = fb.taps
        var i: Int = taps.size - 1
        while (i >= from) {
            if (taps[i].h < VFDW.tapRows) {
                taps.removeAt(i)
            }
            i -= 1
        }
    }

    /** A tap at least tapRows tall, grown evenly around the visual (logs.py _tap). */
    fun growTap(fb: VFDFrameBuffer, c: Int, r: Int, w: Int, h: Int, name: String, action: (() -> Unit)?) {
        var top: Int = r
        var height: Int = h
        if (height < VFDW.tapRows) {
            top -= VFDMath.floorDiv(VFDW.tapRows - height, 2)
            height = VFDW.tapRows
        }
        fb.tap(c, top, w, height, name = name, action = action)
    }

    /** logsCaption above a control: dim, wrapped. Returns the row for the control under it. */
    fun caption(fb: VFDFrameBuffer, L: VFDLayout, c: Int, r: Int, w: Int, s: String,
                color: Int = VFDInk.dim): Int {
        val top: Int = VFDW.groupTop(L, r)
        val lines: List<String> = captionLines(s, w)
        for ((i, ln) in lines.withIndex()) {
            fb.text(c, top + i * VFDW.line, ln, VFDSize.small, color)
        }
        val extra: Int = maxOf(0, lines.size - 1) * VFDW.line
        return top + extra + VFDW.labelH
    }

    /** A caption line on its own (hint, "…and n more"): wrapped, a line apart, the standard gap
     *  after it. Returns the next free row. */
    fun noteLines(fb: VFDFrameBuffer, c: Int, r: Int, w: Int, s: String, color: Int = VFDInk.dim): Int {
        var y: Int = r + 2
        for (ln in captionLines(s, w)) {
            fb.text(c, y, ln, VFDSize.small, color)
            y += VFDW.line
        }
        return y + VFDW.gap
    }

    /** An outline button: highlight border with the label in its colour; alarm = a destructive one
     *  (alarm border and label, a solid block on a red-ish base); disabled = dim, no tap. Returns
     *  the column after it. */
    private fun outlineButton(fb: VFDFrameBuffer, x: Int, y: Int, w: Int, spec: VFDLogsButton): Int {
        val s: String = VFDText.fit(VFDW.upper(spec.label), w - 4)
        val tx: Int = VFDW.cx(x, w, s)
        val ty: Int = y + VFDW.ctrlText
        if (!spec.enabled) {
            fb.box(x, y, w, VFDW.ctrlH, VFDInk.dim)
            fb.text(tx, ty, s, VFDSize.small, VFDInk.dim)
        } else if (spec.color == VFDInk.alarm && fb.alarmInverted) {
            fb.fill(x, y, w, VFDW.ctrlH, VFDInk.highlight)
            fb.text(tx, ty, s, VFDSize.small, VFDInk.unlit)
        } else {
            val border: Int = if (spec.color == VFDInk.alarm) VFDInk.alarm else VFDInk.highlight
            fb.box(x, y, w, VFDW.ctrlH, border)
            fb.text(tx, ty, s, VFDSize.small, spec.color)
        }
        if (spec.enabled) {
            growTap(fb, x, y, w, VFDW.ctrlH, "button:$s", action = spec.action)
        }
        return x + w
    }

    /** A row of outline buttons, optGap apart; the expanding ones share what the fixed ones leave
     *  (the last one takes the spare cells). Returns the next free row. */
    fun buttonRow(fb: VFDFrameBuffer, c: Int, r: Int, w: Int, specs: List<VFDLogsButton>): Int {
        val gap: Int = VFDW.optGap
        val fixed = IntArray(specs.size)
        var nExp = 0
        var fixedSum = 0
        for ((i, spec) in specs.withIndex()) {
            val fw: Int = VFDText.width(VFDW.upper(spec.label)) + 12
            fixed[i] = fw
            if (spec.expand) nExp += 1 else fixedSum += fw
        }
        val spare: Int = w - gap * maxOf(0, specs.size - 1) - fixedSum
        val each: Int = if (nExp > 0) VFDMath.floorDiv(spare, nExp) else 0
        var x: Int = c
        var seen = 0
        for ((i, spec) in specs.withIndex()) {
            var bw: Int = fixed[i]
            if (spec.expand) {
                seen += 1
                bw = each
                if (seen == nExp) {
                    bw += spare - each * nExp
                }
            }
            x = outlineButton(fb, x, r, bw, spec) + gap
        }
        return r + VFDW.ctrlH + VFDW.gap
    }

    /** A toggle whose label is too long for one line beside the switch: the label breaks before
     *  its "(…)" (else at spaces) onto two lines, the switch centred against them. */
    fun wrappedToggle(fb: VFDFrameBuffer, L: VFDLayout, c: Int, r: Int, w: Int, label: String, on: Boolean,
                      action: () -> Unit): Int {
        val room: Int = w - VFDW.switchW - 6
        val s: String = VFDW.upper(label)
        if (VFDText.width(s) <= room) {
            return VFDW.toggle(fb, L, c, r, w, s, on, labelColor = VFDInk.dim, action = action)
        }
        var lines: List<String> = emptyList()
        var split = false
        val paren: Int = s.indexOf(" (")
        if (paren >= 0) {
            val head: String = s.substring(0, paren)
            if (VFDText.width(head) <= room) {
                lines = listOf(head, s.substring(paren + 1))
                split = true
            }
        }
        if (!split) {
            lines = VFDText.wrap(s, room)
        }
        val y: Int = r + 3
        for ((i, ln) in lines.take(2).withIndex()) {
            fb.text(c, y + i * VFDW.line, VFDText.fit(ln, room), VFDSize.small, VFDInk.dim)
        }
        val name = "toggle:$s"
        VFDW.toggle(fb, L, c, y + 2, w, "", on, name = name, action = action)
        growTap(fb, c, r + 1, w, VFDW.line + 7 + 4, name, action = action)
        return y + VFDW.line + 7 + 3 + VFDW.gap
    }
}
