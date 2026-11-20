package com.magicmaker.android.ui.vfd

import com.magicmaker.android.core.LivePacketSection
import com.magicmaker.android.core.LivePacketSort
import com.magicmaker.android.core.MagicCategory
import com.magicmaker.android.core.MagicPacket
import com.magicmaker.android.core.PacketBuilder
import com.magicmaker.android.core.StarlightColors
import com.magicmaker.android.service.MagicMakerForegroundService
import com.magicmaker.android.ui.UiPrefs

/**
 * TX tab in the VFD theme: tools/vfd/screens/tx.py on the real library and the Android TX loop
 * (port of ios/MagicMaker/VFD/VFDTxScreen.swift, behaviour of the standard TransmitTab).
 *
 * Pinned controls ([VIBRATE] [INTERROGATE], the collapsible TX LOOP block with LOOP and the
 * 61-stop interval slider of TxLoopSettingsSection, CLASS n/8, the hint and the status line), a
 * divider, then the library (allTransmitPackets() grouped by LivePacketSort, the selected packet
 * inverted) in its own scroll region with the header of the section at the top pinned under the
 * divider. Rows: tap sends (and moves a running loop to it), hold opens the packet menu, swipe
 * left deletes, swipe right recategorizes, as TxSwipeRow / PacketActionSheet do. The colours
 * named in a row's subtitle get a true-colour swatch before each name.
 */
object VFDTxScreen : VFDScreen {
    override val title: String = "TX"

    const val hint: String = "TAP TX · HOLD MENU · SWIPE ← DEL · SWIPE → RECAT"
    const val emptyText: String = "NO TX LIBRARY — RUN RX SESSION"
    /** Scroll region id of the library list. */
    const val listRegion: String = "list"
    /** A section header block in the list: sectionGap - gap rows of air, then the header line and
     *  its rule (tx.py HEAD_H). */
    val headH: Int = VFDW.sectionGap - VFDW.gap + VFDW.sectionH

    override fun headerRight(ctx: VFDContext): VFDHeaderRight? = null

    override fun draw(ctx: VFDContext): Int? {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val ui: VFDUIState = ctx.ui
        val st: TxState = state(ctx, ui)
        // The controls stay put (the standard tab keeps them above the list): undo any page scroll.
        val scroll: Int = -fb.originY
        fb.pushClip(0, L.contentTop + scroll, fb.cols, L.contentH, dy = scroll)
        val div: Int = drawControls(ctx, ui, st)
        fb.hline(L.left, div, L.width, VFDInk.dim)
        drawList(ctx, ui, st, listTop = div + 1)
        fb.popClip()
        return null
    }

    // MARK: - State (read only; derived from the service state and this tab's UI state)

    /** TransmitTab's in-memory SectionFilterDropdown set (every section until changed). */
    private fun visibleSections(ui: VFDUIState): Set<LivePacketSection> {
        if (!ui.has("visible")) return LivePacketSection.entries.toSet()
        val names: Set<String> = ui.strings("visible")
        return LivePacketSection.entries.filter { it.name in names }.toSet()
    }

    /** TransmitTab.loopOn: remember(state.txLoopEnabled) — the switch's own value until the
     *  service's flag changes. */
    private fun loopOn(ctx: VFDContext, ui: VFDUIState): Boolean {
        val service: Boolean = ctx.state.txLoopEnabled
        if (ui.has("loopOn") && ui.bool("loopOnBase") == service) {
            return ui.bool("loopOn")
        }
        return service
    }

    /** TransmitTab.selectedTxId: remember(state.txLoopPacketId, storeRev) — the last tapped packet
     *  until the loop's packet or the store changes, else the loop's packet; then the
     *  LaunchedEffect(allPackets) fix-up (the first packet when the wanted one is gone). */
    private fun selection(ctx: VFDContext, ui: VFDUIState, library: TxLibrary): Long {
        val loopId: Long = ctx.state.txLoopPacketId
        var wanted: Long = loopId
        if (ui.has("sel") && ui.string("selLoop") == loopId.toString() &&
            ui.int("selRev") == ctx.state.storeRevision) {
            wanted = ui.string("sel").toLongOrNull() ?: loopId
        }
        return library.validSelection(wanted)
    }

    /** TransmitTab.intervalSec: txLoopIntervalMs / 1000f, or the last committed slider value while
     *  the service's interval has not changed since (LaunchedEffect(state.txLoopIntervalMs)). */
    private fun interval(ctx: VFDContext, ui: VFDUIState): Float {
        val ms: Long = ctx.state.txLoopIntervalMs
        if (ui.has("intervalSec") && ui.string("intervalMs") == ms.toString()) {
            return ui.double("intervalSec").toFloat()
        }
        return ms / 1000f
    }

    private fun library(ctx: VFDContext): TxLibrary =
        ctx.cached("tx.library", ctx.state.storeRevision) { TxLibrary.make(ctx.store.allTransmitPackets()) }

    private fun state(ctx: VFDContext, ui: VFDUIState): TxState {
        val library: TxLibrary = library(ctx)
        val collapsed: Set<LivePacketSection> = UiPrefs.loadCollapsedTx(ctx.context)
        val visible: Set<LivePacketSection> = visibleSections(ui)
        val layout: TxLayout = ctx.cached("tx.layout", Triple(ctx.state.storeRevision, collapsed, visible)) {
            TxLayout.build(library, collapsed, visible)
        }
        return TxState(
            library = library,
            layout = layout,
            selectedId = selection(ctx, ui, library),
            intervalSec = interval(ctx, ui),
            loopOn = loopOn(ctx, ui),
            dragging = ui.bool("dragging"),
            dragStop = ui.int("dragStop"),
            collapsed = collapsed,
            visible = visible,
            loopSettingsCollapsed = UiPrefs.isTxLoopSettingsCollapsed(ctx.context),
        )
    }

    /** "%.1f" as the standard tab formats seconds. */
    private fun seconds(v: Float): String = "%.1f".format(v)

    /** TransmitTab's statusLabel: "ON · 3.0S · LABEL" / "ON · 3.0S" while the loop is on. */
    private fun loopStatusLabel(st: TxState): String? {
        if (!st.loopOn) return null
        val label: String? = st.library.labels[st.selectedId]
        if (label != null) {
            return "ON · " + seconds(st.intervalSec) + "S · " + label.uppercase()
        }
        return "ON · " + seconds(st.intervalSec) + "S"
    }

    /** The Material slider's value at stop [stop] of 0.5 .. 30 s with 59 steps (lerp). */
    private fun stopSeconds(stop: Int): Float {
        val clamped: Int = VFDMath.clamp(stop, 0, VFDW.loopLastStop)
        val f: Float = clamped.toFloat() / VFDW.loopLastStop.toFloat()
        return (1f - f) * VFDW.loopMin.toFloat() + f * VFDW.loopMax.toFloat()
    }

    /** SettingSlider.onCommit's (sec * 1000).toLong(). */
    private fun millis(sec: Float): Long = (sec * 1000).toLong()

    // MARK: - Controls

    /** The pinned controls block from L.contentTop. Returns the row of the divider under it. */
    private fun drawControls(ctx: VFDContext, ui: VFDUIState, st: TxState): Int {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val c: Int = L.left
        val w: Int = L.width
        var y: Int = L.contentTop

        // [VIBRATE] [INTERROGATE]
        y = VFDW.buttons(fb, L, c, y, w, listOf("VIBRATE", "INTERROGATE"), equal = false, onSelect = { index ->
            if (index == 0) {
                MagicMakerForegroundService.vibrate(ctx.context)
            } else {
                MagicMakerForegroundService.transmit(ctx.context, PacketBuilder.WAKEUP_PING)
            }
        })

        // Loop header: chevron + "HIDE TX LOOP" / "TX LOOP SETTINGS", loop status right-aligned.
        val folded: Boolean = st.loopSettingsCollapsed
        val headTitle: String = if (folded) "TX LOOP SETTINGS" else "HIDE TX LOOP"
        val ty: Int = y + 3
        if (folded) {
            VFDW.chevron(fb, c, ty, false, VFDInk.dim)
        } else {
            VFDW.chevronUp(fb, c, ty, VFDInk.dim)
        }
        val tend: Int = fb.text(c + 11, ty, headTitle, VFDSize.small, VFDInk.highlight)
        val status: String? = loopStatusLabel(st)
        if (status != null) {
            val room: Int = c + w - (tend - 1 + 7)
            fb.textRight(c + w - 1, ty, VFDText.fit(status, room), VFDSize.small, VFDInk.dim)
        }
        fb.tap(c, y - 1, w, VFDW.tapRows, name = "loop:settings", action = {
            val now: Boolean = UiPrefs.isTxLoopSettingsCollapsed(ctx.context)
            UiPrefs.saveTxLoopSettingsCollapsed(ctx.context, !now)
        })
        y += VFDW.ctrlH + VFDW.gap

        if (!folded) {
            y = VFDW.toggle(fb, L, c, y, w, "LOOP", st.loopOn, enabled = st.selectedId >= 0,
                            labelColor = VFDInk.highlight, action = {
                                setLoop(ctx, ui, !loopOn(ctx, ui))
                            })
            y = intervalSlider(ctx, ui, st, c, y, w)
        }

        // SectionFilterDropdown
        val total: Int = LivePacketSection.entries.size
        VFDW.menuButton(fb, L, c, y, "CLASS ${st.visible.size}/$total", name = "menu:CLASS", action = {
            showFilter(ctx, ui)
        })
        y += VFDW.ctrlH + VFDW.gap

        // Hint, then the status line set apart by the group gap.
        y += VFDW.groupGap
        for (line in VFDW.tokenLines(hint, w)) {
            fb.text(c, y, line, VFDSize.small, VFDInk.dim)
            y += VFDW.line
        }
        y += VFDW.groupGap
        y = VFDW.statusLine(fb, L, c, y, w, ctx.state.status, color = VFDInk.dim)
        return y + 1
    }

    /** TxLoopSettingsSection's SettingSlider: "3.0S INTERVAL" (the live value while dragging) over
     *  the 61-stop bar; the bar's drag follows the thumb and commits on release. */
    private fun intervalSlider(ctx: VFDContext, ui: VFDUIState, st: TxState, c: Int, r: Int, w: Int): Int {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val shown: Float = if (st.dragging) stopSeconds(st.dragStop) else st.intervalSec
        val labelText: String = seconds(shown) + "S INTERVAL"
        val end: Int = VFDW.intervalSlider(fb, L, c, r, w, labelText, shown.toDouble())
        val top: Int = if (r > L.contentTop) r + VFDW.groupGap else r
        val barY: Int = top + VFDW.labelH
        fb.tap(c, barY - 6, w, VFDW.tapRows, name = "slider:INTERVAL:bar", drag = { fraction, ended ->
            val stop: Int = stopAt(fraction)
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

    /** The slider stop under a finger at [fraction] of the bar. */
    private fun stopAt(fraction: Double): Int {
        val clamped: Double = VFDMath.clamp(fraction, 0.0, 1.0)
        return VFDMath.clamp(VFDMath.roundHalfAway(clamped * VFDW.loopLastStop.toDouble()), 0, VFDW.loopLastStop)
    }

    // MARK: - Library list

    /** The library under the divider: section headers and packet rows in a scroll region, the
     *  header of the section at the top pinned under the divider (tx.py draw()). */
    private fun drawList(ctx: VFDContext, ui: VFDUIState, st: TxState, listTop: Int) {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val bottom: Int = L.contentBottom
        val viewH: Int = bottom - listTop
        if (viewH <= 0) return
        if (st.library.groups.isEmpty()) {
            drawEmpty(fb, L, listTop, viewH)
            return
        }
        val layout: TxLayout = st.layout
        val total: Int = layout.height
        val s: Int = ctx.scroll(listRegion, limit = total - viewH)
        // The renderer's drag limit is contentRows minus the region's clipped height: register it
        // so that limit is total - viewH, the one used here.
        val shownRows: Int = clippedRows(fb, listTop, viewH)
        fb.scrollRegion(listRegion, 0, listTop, fb.cols, viewH, contentRows = total - viewH + shownRows)

        // Pinned section header: once a header block has scrolled up to listTop it stays drawn
        // there and the window starts under it; when the next header block moves into the pinned
        // rows, the window starts at that block instead (no header cut or shown twice).
        var pinned: Int = -1
        var top: Int = listTop
        var p: Int = -1
        for ((k, lineIndex) in layout.heads.withIndex()) {
            if (listTop + layout.lines[lineIndex].y - s <= listTop) {
                p = k
            }
        }
        if (p >= 0) {
            val next: Int? = if (p + 1 < layout.heads.size) listTop + layout.lines[layout.heads[p + 1]].y - s else null
            if (next != null && next < listTop + headH) {
                top = next
            } else {
                pinned = layout.heads[p]
                top = listTop + headH
            }
        }

        // The list scrolls inside rows listTop until bottom; lines cut by the window edges are
        // hidden, and so are their (then too short) tap rectangles.
        fb.pushClip(0, listTop, fb.cols, viewH, dy = -s)
        val windowTop: Int = top
        val win: VFDWindow = VFDW.snappedWindow(fb, top = windowTop, bottom = bottom) { target ->
            drawLines(ctx, ui, st, layout, target, listTop, s, windowTop, bottom)
        }
        val firstTap: Int = fb.taps.size
        fb.pushClip(0, win.top - fb.originY, fb.cols, win.bottom - win.top)
        drawLines(ctx, ui, st, layout, fb, listTop, s, windowTop, bottom)
        fb.popClip()
        dropShortTaps(fb, firstTap)
        fb.popClip()

        if (pinned >= 0) {
            // Drawn at its scroll-0 place; the clip takes one row of the window for its 15-row tap.
            val line: TxLine = layout.lines[pinned]
            fb.pushClip(0, listTop, fb.cols, headH + 1)
            drawHeader(ctx, fb, st, line.group, listTop)
            fb.popClip()
        }

        VFDW.listScrollbar(fb, listTop, viewH, total, s)
    }

    /** Drops the taps from index [from] that the window cut below the minimum tap height. */
    private fun dropShortTaps(fb: VFDFrameBuffer, from: Int) {
        val taps: MutableList<VFDHit> = fb.taps
        var i: Int = taps.size - 1
        while (i >= from) {
            if (taps[i].h < VFDW.tapRows) {
                taps.removeAt(i)
            }
            i -= 1
        }
    }

    /** Rows of r until r + h (drawing coordinates) inside the current clip. */
    private fun clippedRows(fb: VFDFrameBuffer, r: Int, h: Int): Int {
        val clip: VFDRect = fb.clipRect
        val t: Int = maxOf(r + fb.originY, clip.r)
        val b: Int = minOf(r + h + fb.originY, clip.r + clip.h)
        return maxOf(0, b - t)
    }

    /** The lines of the list that reach screen rows from - 2 until to + 2, at their unscrolled
     *  rows (the clip's origin applies the scroll). */
    private fun drawLines(ctx: VFDContext, ui: VFDUIState, st: TxState, layout: TxLayout, target: VFDFrameBuffer,
                          listTop: Int, scroll: Int, from: Int, to: Int) {
        // First line that can reach the window (binary search on the sorted line offsets).
        var lo = 0
        var hi: Int = layout.lines.size
        while (lo < hi) {
            val mid: Int = (lo + hi) ushr 1
            val line: TxLine = layout.lines[mid]
            if (listTop + line.y - scroll + line.h < from - 2) lo = mid + 1 else hi = mid
        }
        var i: Int = lo
        while (i < layout.lines.size) {
            val line: TxLine = layout.lines[i]
            val screenTop: Int = listTop + line.y - scroll
            if (screenTop > to + 2) break
            val y: Int = listTop + line.y
            if (line.row < 0) {
                drawHeader(ctx, target, st, line.group, y)
            } else {
                drawRow(ctx, ui, target, st, st.library.groups[line.group].rows[line.row], y)
            }
            i += 1
        }
    }

    /** CollapsibleSectionHeader: chevron, title, 3-digit count; a tap folds or opens the section. */
    private fun drawHeader(ctx: VFDContext, fb: VFDFrameBuffer, st: TxState, groupIndex: Int, y: Int) {
        val L: VFDLayout = ctx.L
        val group: TxGroup = st.library.groups[groupIndex]
        val section: LivePacketSection = group.section
        val folded: Boolean = section in st.collapsed
        VFDW.section(fb, L, L.left, y, L.width, section.title, count = group.rows.size, collapsed = folded,
                     action = {
                         val now: Set<LivePacketSection> = UiPrefs.loadCollapsedTx(ctx.context)
                         UiPrefs.saveCollapsedTx(ctx.context, if (section in now) now - section else now + section)
                     })
    }

    /** TxSwipeRow: label, hex (dim), "CATEGORY · COLOURS" with a true-colour swatch before each
     *  named colour; tap sends, hold opens the menu, swipe left deletes, swipe right
     *  recategorizes. */
    private fun drawRow(ctx: VFDContext, ui: VFDUIState, fb: VFDFrameBuffer, st: TxState, row: TxRow, y: Int) {
        val L: VFDLayout = ctx.L
        val packet: MagicPacket = row.packet
        // The subtitle line is kept (a blank placeholder) and drawn below with its swatches.
        VFDW.packetRow(fb, L, L.left, y, L.width, packet.label, packet.hex, subtitle = " ",
                       selected = packet.id == st.selectedId, hexColor = VFDInk.dim,
                       action = { selectPacket(ctx, ui, packet) },
                       long = { showActions(ctx, ui, packet) },
                       swipeLeft = { askDelete(ctx, packet) },
                       swipeRight = { askRecategorize(ctx, packet) })
        var sy: Int = y + 3 + VFDW.line
        if (packet.hex.isNotEmpty()) sy += VFDW.line
        drawSubtitle(fb, L.left, sy, L.width, row)
    }

    /** The subtitle line as packetRow draws it (dim, uppercase, cut with … at the row's width),
     *  with a 5 x 5 swatch in the colour's true RGB before every palette colour name. */
    private fun drawSubtitle(fb: VFDFrameBuffer, c: Int, y: Int, w: Int, row: TxRow) {
        val limit: Int = c + w
        var x: Int = c + 2
        val segments: List<TxSegment> = row.segments
        for (seg in segments) {
            val text: String = seg.text
            val sw: Int = if (seg.color != null) swatchW else 0
            if (x + sw + VFDText.width(text) > limit) {
                // Cut here: the swatch when it and one character still fit, then the text with "…".
                if (seg.color != null && x + sw + VFDText.width(1) <= limit) {
                    swatch(fb, x, y, seg.color)
                    x += sw
                }
                fb.textFit(x, y, text, limit - x, VFDSize.small, VFDInk.dim)
                return
            }
            if (seg.color != null) {
                swatch(fb, x, y, seg.color)
                x += sw
            }
            x = fb.text(x, y, text, VFDSize.small, VFDInk.dim)
        }
    }

    /** Cells a swatch takes before its name: 5 lit cells and 3 cells of air. */
    private const val swatchW: Int = 8

    /** A 5 x 5 swatch of palette colour [index] (labSwatchColor); "Off" stays an unlit ring. */
    private fun swatch(fb: VFDFrameBuffer, x: Int, y: Int, index: Int) {
        if ((index and 0x1F) == 0x1D) {
            VFDW.led(fb, x, y + 1, null, size = 5)
        } else {
            fb.fill(x, y + 1, 5, 5, fb.rgb(VFDColors.labSwatch(index)))
        }
    }

    /** "NO TX LIBRARY — RUN RX SESSION", centred in the list area. */
    private fun drawEmpty(fb: VFDFrameBuffer, L: VFDLayout, listTop: Int, viewH: Int) {
        val lines: List<String> = VFDText.wrap(emptyText, L.width)
        var y: Int = listTop + VFDMath.floorDiv(viewH - lines.size * VFDW.line, 2)
        for (line in lines) {
            fb.text(VFDW.cx(L.left, L.width, line), y, line, VFDSize.small, VFDInk.dim)
            y += VFDW.line
        }
    }

    // MARK: - Actions (run from taps, never from draw)

    /** SectionFilterDropdown: one row per section (ticked when shown); a pick toggles it and the
     *  menu opens again, as the standard dropdown stays open. */
    private fun showFilter(ctx: VFDContext, ui: VFDUIState) {
        val visible: Set<LivePacketSection> = visibleSections(ui)
        val items = ArrayList<VFDMenuItem>()
        for (section in LivePacketSection.entries) {
            val on: Boolean = section in visible
            val itemLabel: String = section.title.uppercase() + if (on) " ✓" else ""
            items.add(VFDMenuItem(itemLabel) {
                val now: Set<LivePacketSection> = visibleSections(ui)
                val next: Set<LivePacketSection> = if (section in now) now - section else now + section
                ui.setStrings("visible", next.map { it.name }.toSet())
                showFilter(ctx, ui)
            })
        }
        ctx.menu("CLASS ${visible.size}/${LivePacketSection.entries.size}", items)
    }

    /** onSelectPacket: select it, send it, and make it the loop's packet while the loop is on. */
    private fun selectPacket(ctx: VFDContext, ui: VFDUIState, packet: MagicPacket) {
        val loopOn: Boolean = loopOn(ctx, ui)
        val sec: Float = interval(ctx, ui)
        ui.setString("selLoop", ctx.state.txLoopPacketId.toString())
        ui.setInt("selRev", ctx.state.storeRevision)
        ui.setString("sel", packet.id.toString())
        MagicMakerForegroundService.transmit(ctx.context, packet.hex)
        if (loopOn) {
            MagicMakerForegroundService.setTxLoop(ctx.context, enabled = true, packetId = packet.id,
                                                  intervalMs = millis(sec))
        }
    }

    /** onLoopOnChange: the switch, the service started when needed, the loop on the selection. */
    private fun setLoop(ctx: VFDContext, ui: VFDUIState, enabled: Boolean) {
        val packetId: Long = selection(ctx, ui, library(ctx))
        val sec: Float = interval(ctx, ui)
        ui.setBool("loopOnBase", ctx.state.txLoopEnabled)
        ui.setBool("loopOn", enabled)
        if (enabled && !ctx.state.running) MagicMakerForegroundService.start(ctx.context)
        if (packetId >= 0) {
            MagicMakerForegroundService.setTxLoop(ctx.context, enabled = enabled, packetId = packetId,
                                                  intervalMs = millis(sec))
        }
    }

    /** onIntervalCommit: the new interval, and the loop's when it is on. */
    private fun commitInterval(ctx: VFDContext, ui: VFDUIState, sec: Float) {
        val packetId: Long = selection(ctx, ui, library(ctx))
        val loopOn: Boolean = loopOn(ctx, ui)
        ui.setDouble("intervalSec", sec.toDouble())
        ui.setString("intervalMs", ctx.state.txLoopIntervalMs.toString())
        if (loopOn && packetId >= 0) {
            MagicMakerForegroundService.setTxLoop(ctx.context, enabled = true, packetId = packetId,
                                                  intervalMs = millis(sec))
        }
    }

    /** PacketActionSheet: TRANSMIT, LOAD IN LAB, RENAME, RECATEGORIZE, DELETE. */
    private fun showActions(ctx: VFDContext, ui: VFDUIState, packet: MagicPacket) {
        val items: List<VFDMenuItem> = listOf(
            VFDMenuItem("Transmit") { selectPacket(ctx, ui, packet) },
            VFDMenuItem("Load in Lab") { ctx.loadInLab(packet.hex, packet.label) },
            VFDMenuItem("Rename") { askRename(ctx, packet) },
            VFDMenuItem("Recategorize") { askRecategorize(ctx, packet) },
            VFDMenuItem("Delete", destructive = true) { askDelete(ctx, packet) },
        )
        ctx.menu(packet.label, items)
    }

    /** RenameDialog: "Rename packet", the field starts with the label; SAVE needs a non-blank one. */
    private fun askRename(ctx: VFDContext, packet: MagicPacket) {
        val packetId: Long = packet.id
        ctx.prompt("Rename packet", text = packet.label, keyboard = VFDKeyboard.text) { entered ->
            if (entered.isNotBlank()) {
                ctx.store.renamePacket(packetId, entered)
            }
        }
    }

    /** CategoryPickerDialog: one row per MagicCategory. */
    private fun askRecategorize(ctx: VFDContext, packet: MagicPacket) {
        val packetId: Long = packet.id
        val items = ArrayList<VFDMenuItem>()
        for (category in MagicCategory.entries) {
            items.add(VFDMenuItem(category.name) { ctx.store.recategorizePacket(packetId, category) })
        }
        ctx.menu("Recategorize · " + packet.label, items)
    }

    /** ConfirmDeleteDialog "Delete from TX library?": the label uppercased, then the hex. */
    private fun askDelete(ctx: VFDContext, packet: MagicPacket) {
        val packetId: Long = packet.id
        val upperLabel: String = packet.label.uppercase()
        val message: String = if (packet.hex.isEmpty()) upperLabel else upperLabel + "\n" + packet.hex
        ctx.confirm("Delete from TX library?", message, confirmLabel = "DELETE", destructive = true) {
            ctx.store.deletePacketById(packetId)
        }
    }
}

// MARK: - Library snapshot

/** A piece of a row's subtitle: its text (display case) and, for a colour name, its palette index. */
private class TxSegment(val text: String, val color: Int?)

/** One library row with its subtitle pieces ("CATEGORY · colours", or the category alone). */
private class TxRow(val packet: MagicPacket) {
    val segments: List<TxSegment> = TxColorNames.segments(packet.category.name, packet.colors)
}

private class TxGroup(val section: LivePacketSection, val rows: List<TxRow>)

/** The library as TransmitTab groups it (sections in order, labels sorted, empty ones left out). */
private class TxLibrary(
    val groups: List<TxGroup>,
    val ids: Set<Long>,
    /** Each packet's label by id (the first packet with that id). */
    val labels: Map<Long, String>,
    /** The first packet of allTransmitPackets(), or -1 for an empty library. */
    val firstId: Long,
) {
    /** The wanted packet when it is in the library, otherwise the first one. */
    fun validSelection(wanted: Long): Long = if (wanted >= 0 && wanted in ids) wanted else firstId

    companion object {
        fun make(all: List<MagicPacket>): TxLibrary {
            val groups = ArrayList<TxGroup>()
            for ((section, packets) in LivePacketSort.groupedMagicPackets(all)) {
                if (section !in LivePacketSection.entries || packets.isEmpty()) continue
                groups.add(TxGroup(section, packets.map { TxRow(it) }))
            }
            val ids = HashSet<Long>()
            val labels = HashMap<Long, String>()
            for (packet in all) {
                if (ids.add(packet.id)) {
                    labels[packet.id] = packet.label
                }
            }
            return TxLibrary(groups, ids, labels, all.firstOrNull()?.id ?: -1L)
        }
    }
}

/** What one draw of the TX tab reads. */
private class TxState(
    val library: TxLibrary,
    val layout: TxLayout,
    val selectedId: Long,
    val intervalSec: Float,
    val loopOn: Boolean,
    val dragging: Boolean,
    val dragStop: Int,
    val collapsed: Set<LivePacketSection>,
    val visible: Set<LivePacketSection>,
    val loopSettingsCollapsed: Boolean,
)

// MARK: - List layout

/** One line of the list: a section header block (row -1) or a packet row; y and h in rows from
 *  the list's first row. */
private class TxLine(val y: Int, val h: Int, val group: Int, val row: Int)

/** Rows of every header block and packet row of the visible sections, as tx.py draw_library
 *  stacks them (a header block takes sectionGap - gap + sectionH + gap rows when folded; an open
 *  section's first row starts gap rows earlier, right under the rule). */
private class TxLayout(val lines: List<TxLine>, val heads: List<Int>, val height: Int) {
    companion object {
        fun rowHeight(row: TxRow): Int {
            var h = 3
            if (row.packet.hex.isNotEmpty()) h += VFDW.line
            h += VFDW.line                  // the subtitle (the category is never empty)
            return h + 7 + 3 + 1
        }

        fun build(library: TxLibrary, collapsed: Set<LivePacketSection>, visible: Set<LivePacketSection>): TxLayout {
            val lines = ArrayList<TxLine>()
            val heads = ArrayList<Int>()
            val headerBlock: Int = VFDW.sectionGap - VFDW.gap + VFDW.sectionH + VFDW.gap
            var y = 0
            for ((g, group) in library.groups.withIndex()) {
                if (group.section !in visible) continue
                heads.add(lines.size)
                if (group.section in collapsed) {
                    lines.add(TxLine(y, headerBlock, g, -1))
                    y += headerBlock
                    continue
                }
                val openBlock: Int = headerBlock - VFDW.gap
                lines.add(TxLine(y, openBlock, g, -1))
                y += openBlock
                for ((r, row) in group.rows.withIndex()) {
                    val h: Int = rowHeight(row)
                    lines.add(TxLine(y, h, g, r))
                    y += h
                }
            }
            return TxLayout(lines, heads, y)
        }
    }
}

// MARK: - Colour names

/** Palette colour names (StarlightColors, the names MagicClassifier writes into a packet's colours)
 *  to their palette index, and a subtitle split into text and colour-name pieces. */
private object TxColorNames {
    private val byName: Map<String, Int> = HashMap<String, Int>().also { m ->
        for (i in 0..0x1F) {
            val name: String = StarlightColors.palette[i] ?: continue
            m.putIfAbsent(name.lowercase(), i)
        }
    }
    private val separators: List<String> = listOf(" / ", ", ")
    private val suffixes: List<String> = listOf(" centre", " corners")

    /** Palette index of a colour token ("Pink", "Lime corners"), or null. */
    fun index(token: String): Int? {
        var t: String = token.trim().lowercase()
        for (suffix in suffixes) {
            if (t.endsWith(suffix)) t = t.removeSuffix(suffix).trim()
        }
        return byName[t]
    }

    /** "CATEGORY", then " · " and the colours split at " / " and ", " (each colour name with its
     *  palette index), all in display case. */
    fun segments(category: String, colors: String): List<TxSegment> {
        val out = ArrayList<TxSegment>()
        out.add(TxSegment(VFDW.upper(category), null))
        if (colors.isBlank()) return out
        out.add(TxSegment(" · ", null))
        var i = 0
        while (i < colors.length) {
            var at: Int = -1
            var sep = ""
            for (s in separators) {
                val k: Int = colors.indexOf(s, i)
                if (k >= 0 && (at < 0 || k < at)) {
                    at = k
                    sep = s
                }
            }
            val token: String = if (at < 0) colors.substring(i) else colors.substring(i, at)
            if (token.isNotEmpty()) out.add(TxSegment(VFDW.upper(token), index(token)))
            if (at < 0) break
            out.add(TxSegment(sep, null))
            i = at + sep.length
        }
        return out
    }
}
