import SwiftUI

/// TX tab in the VFD theme: tools/vfd/screens/tx.py on the real library and TxEngine.
///
/// Pinned controls ([VIBRATE] [INTERROGATE], the collapsible TX LOOP block with LOOP and the
/// 61-stop interval slider, CLASS n/8, the hint and the status line), a divider, then the
/// library list (allTransmitPackets() grouped like TxScreen, the loop's packet inverted) in its
/// own scroll region with the header of the section at the top pinned under the divider.
/// Rows: tap sends, hold opens the packet menu, swipe left deletes, swipe right recategorizes,
/// exactly as TxScreen's PacketRow / packetSwipeActions / packetActionSheet do.
@MainActor
enum VFDTxScreen: VFDScreen {
    static let title: String = "TX"

    static let hint: String = "TAP TX · HOLD MENU · SWIPE ← DEL · SWIPE → RECAT"
    static let emptyText: String = "NO TX LIBRARY — RUN RX SESSION"
    /// Scroll region id of the library list.
    static let listRegion: String = "list"
    /// TxScreenPrefs keys (shared with the standard screen).
    static let collapsedSectionsKey: String = "tx_collapsed_sections"
    static let loopSettingsCollapsedKey: String = "tx_loop_settings_collapsed"
    /// A section header block in the list: sectionGap - gap rows of air, then the header line and
    /// its rule (tx.py HEAD_H).
    static let headH: Int = VFDW.sectionGap - VFDW.gap + VFDW.sectionH

    static func headerRight(_ ctx: VFDContext) -> (text: String, action: () -> Void)? {
        return nil
    }

    static func draw(_ ctx: VFDContext) -> Int? {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let ui: VFDUIState = ctx.ui
        let st: VFDTxState = VFDTxScreen.state(ctx, ui)
        // The controls stay put (iOS keeps them above the List): undo any page scroll.
        let scroll: Int = -fb.originY
        fb.pushClip(0, L.contentTop + scroll, fb.cols, L.contentH, dy: scroll)
        let div: Int = VFDTxScreen.drawControls(ctx, ui, st)
        fb.hline(L.left, div, L.width, VFDInk.dim)
        VFDTxScreen.drawList(ctx, ui, st, listTop: div + 1)
        fb.popClip()
        return nil
    }

    // MARK: - State (read only; derived from the engines and this tab's UI state)

    fileprivate static func allTitles() -> Set<String> {
        var out = Set<String>()
        for section in LivePacketSection.allCases {
            out.insert(section.title)
        }
        return out
    }

    /// TxScreenPrefs.loadCollapsedSections, as section titles.
    fileprivate static func collapsedSections(_ ui: VFDUIState) -> Set<String> {
        let names: [String] = ui.storedStrings(VFDTxScreen.collapsedSectionsKey)
        var wanted = Set<String>()
        for name in names {
            wanted.insert(name.uppercased())
        }
        var out = Set<String>()
        for section in LivePacketSection.allCases where wanted.contains(section.title) {
            out.insert(section.title)
        }
        return out
    }

    /// SectionFilterMenu's set (in memory, every section until changed).
    fileprivate static func visibleSections(_ ui: VFDUIState) -> Set<String> {
        if ui.has("visible") {
            return ui.strings("visible")
        }
        return VFDTxScreen.allTitles()
    }

    /// The selected packet as TxScreen keeps it: the loop's packet, or the last tapped one while
    /// the loop's packet has not changed since; then validSelection (the first packet when the
    /// wanted one is not in the library).
    fileprivate static func selection(_ ctx: VFDContext, _ ui: VFDUIState, _ library: VFDTxLibrary) -> Int64 {
        let loopId: Int64 = ctx.tx.txLoopPacketId
        var wanted: Int64 = loopId
        let storedLoop: Int64 = Int64(ui.int("selLoop"))
        if ui.has("sel") && storedLoop == loopId {
            wanted = Int64(ui.int("sel"))
        }
        return library.validSelection(wanted)
    }

    /// TxScreen.intervalSec: follows tx.txLoopIntervalMs, or the last committed slider value
    /// while the engine's interval has not changed since.
    fileprivate static func interval(_ ctx: VFDContext, _ ui: VFDUIState) -> Float {
        let ms: Int = ctx.tx.txLoopIntervalMs
        if ui.has("intervalSec") && ui.int("intervalMs") == ms {
            return Float(ui.double("intervalSec"))
        }
        return TxLoopInterval.seconds(fromMilliseconds: ms)
    }

    fileprivate static func state(_ ctx: VFDContext, _ ui: VFDUIState) -> VFDTxState {
        let library: VFDTxLibrary = VFDTxLibraryCache.current(ctx.store)
        let selected: Int64 = VFDTxScreen.selection(ctx, ui, library)
        let sec: Float = VFDTxScreen.interval(ctx, ui)
        let settingsCollapsed: Bool = ui.storedBool(VFDTxScreen.loopSettingsCollapsedKey, default: true)
        return VFDTxState(
            library: library,
            selectedId: selected,
            intervalSec: sec,
            dragging: ui.bool("dragging"),
            dragStop: ui.int("dragStop"),
            collapsed: VFDTxScreen.collapsedSections(ui),
            visible: VFDTxScreen.visibleSections(ui),
            loopSettingsCollapsed: settingsCollapsed
        )
    }

    /// txStatusLineColor: alarm ink when the last packet did not go out.
    fileprivate static func statusInk(_ status: String) -> UInt8 {
        if status == TxEngine.notLinkedStatus || status == TxEngine.sendFailedStatus {
            return VFDInk.alarm
        }
        return VFDInk.dim
    }

    /// "ON · 3.0S · LABEL" while the loop runs, else nil (TxScreen.loopStatusLabel).
    fileprivate static func loopStatusLabel(_ ctx: VFDContext, _ st: VFDTxState) -> String? {
        if !ctx.tx.txLoopEnabled { return nil }
        let seconds: String = TxLoopInterval.text(st.intervalSec)
        if let label = st.library.labels[st.selectedId] {
            return "ON · " + seconds + "S · " + VFDW.upper(label)
        }
        return "ON · " + seconds + "S"
    }

    // MARK: - Controls

    /// The pinned controls block from L.contentTop. Returns the row of the divider under it.
    fileprivate static func drawControls(_ ctx: VFDContext, _ ui: VFDUIState, _ st: VFDTxState) -> Int {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let tx: TxEngine = ctx.tx
        let c: Int = L.left
        let w: Int = L.width
        var y: Int = L.contentTop

        // [VIBRATE] [INTERROGATE]
        y = VFDW.buttons(fb, L, c, y, w, ["VIBRATE", "INTERROGATE"], equal: false, onSelect: { (index: Int) in
            if index == 0 {
                tx.vibrate()
            } else {
                tx.transmit(hex: PacketBuilder.wakeupPing, label: "Interrogate")
            }
        })

        // Loop header: chevron + "HIDE TX LOOP" / "TX LOOP SETTINGS", loop status right-aligned.
        let folded: Bool = st.loopSettingsCollapsed
        let headTitle: String = folded ? "TX LOOP SETTINGS" : "HIDE TX LOOP"
        let ty: Int = y + 3
        if folded {
            VFDW.chevron(fb, c, ty, false, VFDInk.dim)
        } else {
            VFDW.chevronUp(fb, c, ty, VFDInk.dim)
        }
        let tend: Int = fb.text(c + 11, ty, headTitle, .small, VFDInk.highlight)
        if let status = VFDTxScreen.loopStatusLabel(ctx, st) {
            let room: Int = c + w - (tend - 1 + 7)
            let shown: String = VFDText.fit(status, room)
            fb.textRight(c + w - 1, ty, shown, .small, VFDInk.dim)
        }
        fb.tap(c, y - 1, w, VFDW.tapRows, name: "loop:settings", action: {
            let now: Bool = ui.storedBool(VFDTxScreen.loopSettingsCollapsedKey, default: true)
            ui.setStoredBool(VFDTxScreen.loopSettingsCollapsedKey, !now)
        })
        y += VFDW.ctrlH + VFDW.gap

        if !folded {
            y = VFDW.toggle(fb, L, c, y, w, "LOOP", tx.txLoopEnabled, enabled: st.selectedId >= 0,
                            labelColor: VFDInk.highlight, action: {
                                VFDTxScreen.setLoop(ctx, ui, !tx.txLoopEnabled)
                            })
            y = VFDTxScreen.intervalSlider(ctx, ui, st, c, y, w)
        }

        // SectionFilterMenu
        let total: Int = LivePacketSection.allCases.count
        var shownCount: Int = 0
        for section in LivePacketSection.allCases where st.visible.contains(section.title) {
            shownCount += 1
        }
        VFDW.menuButton(fb, L, c, y, "CLASS \(shownCount)/\(total)", name: "menu:CLASS", action: {
            VFDTxScreen.showFilter(ctx, ui)
        })
        y += VFDW.ctrlH + VFDW.gap

        // Hint, then the status line set apart by the group gap.
        y += VFDW.groupGap
        for line in VFDW.tokenLines(VFDTxScreen.hint, w) {
            fb.text(c, y, line, .small, VFDInk.dim)
            y += VFDW.line
        }
        y += VFDW.groupGap
        y = VFDW.statusLine(fb, L, c, y, w, tx.status, color: VFDTxScreen.statusInk(tx.status))
        return y + 1
    }

    /// TxIntervalSlider: VFDW.intervalSlider draws it (the marker on TxLoopInterval's stop); the
    /// bar's own drag follows the thumb in the label and commits the stop on release.
    fileprivate static func intervalSlider(_ ctx: VFDContext, _ ui: VFDUIState, _ st: VFDTxState,
                               _ c: Int, _ r: Int, _ w: Int) -> Int {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let restStop: Int = TxLoopInterval.stop(forSeconds: st.intervalSec)
        let shownStop: Int = st.dragging ? st.dragStop : restStop
        let shownSeconds: Float = st.dragging ? TxLoopInterval.seconds(forStop: st.dragStop) : st.intervalSec
        let labelText: String = TxLoopInterval.text(shownSeconds) + "S INTERVAL"
        let markerSeconds: Double = Double(TxLoopInterval.seconds(forStop: shownStop))
        let end: Int = VFDW.intervalSlider(fb, L, c, r, w, labelText, markerSeconds)
        let top: Int = r > L.contentTop ? r + VFDW.groupGap : r
        let barY: Int = top + VFDW.labelH
        fb.tap(c, barY - 6, w, VFDW.tapRows, name: "slider:INTERVAL:bar", drag: { (fraction: Double, ended: Bool) in
            let stop: Int = VFDTxScreen.stopAt(fraction)
            if ended {
                ui.setBool("dragging", false)
                VFDTxScreen.commitInterval(ctx, ui, TxLoopInterval.seconds(forStop: stop))
            } else {
                ui.setInt("dragStop", stop)
                ui.setBool("dragging", true)
            }
        })
        return end
    }

    /// The slider position under a finger at `fraction` of the bar (Slider value rounded).
    fileprivate static func stopAt(_ fraction: Double) -> Int {
        let clamped: Double = min(max(fraction, 0.0), 1.0)
        let stop: Int = VFDMath.roundHalfAway(clamped * Double(TxLoopInterval.lastStop))
        return min(max(stop, 0), TxLoopInterval.lastStop)
    }

    // MARK: - Library list

    /// The library under the divider: section headers and packet rows in a scroll region, the
    /// header of the section at the top pinned under the divider (tx.py draw()).
    fileprivate static func drawList(_ ctx: VFDContext, _ ui: VFDUIState, _ st: VFDTxState, listTop: Int) {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let bottom: Int = L.contentBottom
        let viewH: Int = bottom - listTop
        if viewH <= 0 { return }
        if st.library.groups.isEmpty {
            VFDTxScreen.drawEmpty(fb, L, listTop: listTop, viewH: viewH)
            return
        }
        let layout: VFDTxLayout = VFDTxLayout.build(st)
        let total: Int = layout.height
        let s: Int = ctx.scroll(VFDTxScreen.listRegion, limit: total - viewH)
        // The renderer's drag limit is contentRows minus the region's clipped height: register it
        // so that limit is total - viewH, the one used here.
        let shownRows: Int = VFDTxScreen.clippedRows(fb, listTop, viewH)
        fb.scrollRegion(id: VFDTxScreen.listRegion, 0, listTop, fb.cols, viewH,
                        contentRows: total - viewH + shownRows)

        // Pinned section header: once a header block has scrolled up to listTop it stays drawn
        // there and the window starts under it; when the next header block moves into the pinned
        // rows, the window starts at that block instead (no header cut or shown twice).
        var pinned: Int? = nil
        var top: Int = listTop
        var p: Int = -1
        var k: Int = 0
        for lineIndex in layout.heads {
            if listTop + layout.lines[lineIndex].y - s <= listTop {
                p = k
            }
            k += 1
        }
        if p >= 0 {
            var next: Int? = nil
            if p + 1 < layout.heads.count {
                next = listTop + layout.lines[layout.heads[p + 1]].y - s
            }
            if let n = next, n < listTop + VFDTxScreen.headH {
                top = n
            } else {
                pinned = layout.heads[p]
                top = listTop + VFDTxScreen.headH
            }
        }

        // The list scrolls inside rows listTop ..< bottom; lines cut by the window edges are
        // hidden, and so are their (then too short) tap rectangles.
        fb.pushClip(0, listTop, fb.cols, viewH, dy: -s)
        let windowTop: Int = top
        let win = VFDW.snappedWindow(fb, top: windowTop, bottom: bottom, draw: { (target: VFDFrameBuffer) in
            VFDTxScreen.drawLines(ctx, ui, st, layout, target, listTop: listTop, scroll: s,
                                  from: windowTop, to: bottom)
        })
        let firstTap: Int = fb.taps.count
        fb.pushClip(0, win.top - fb.originY, fb.cols, win.bottom - win.top)
        VFDTxScreen.drawLines(ctx, ui, st, layout, fb, listTop: listTop, scroll: s, from: windowTop, to: bottom)
        fb.popClip()
        if fb.taps.count > firstTap {
            var kept: [VFDHit] = Array(fb.taps[0..<firstTap])
            for hit in fb.taps[firstTap...] where hit.h >= VFDW.tapRows {
                kept.append(hit)
            }
            fb.taps = kept
        }
        fb.popClip()

        if let pinnedLine = pinned {
            // Drawn at its scroll-0 place; the clip takes one row of the window for its 15-row tap.
            let line: VFDTxLine = layout.lines[pinnedLine]
            fb.pushClip(0, listTop, fb.cols, VFDTxScreen.headH + 1)
            VFDTxScreen.drawHeader(fb, L, ui, st, line.group, y: listTop)
            fb.popClip()
        }

        VFDW.listScrollbar(fb, listTop, viewH, total, s)
    }

    /// Rows of r ..< r + h (drawing coordinates) inside the current clip.
    fileprivate static func clippedRows(_ fb: VFDFrameBuffer, _ r: Int, _ h: Int) -> Int {
        let clip = fb.clipRect
        let top: Int = max(r + fb.originY, clip.r)
        let bottom: Int = min(r + h + fb.originY, clip.r + clip.h)
        return max(0, bottom - top)
    }

    /// The lines of the list that reach screen rows from - 2 ..< to + 2, at their unscrolled rows
    /// (the clip's origin applies the scroll).
    fileprivate static func drawLines(_ ctx: VFDContext, _ ui: VFDUIState, _ st: VFDTxState, _ layout: VFDTxLayout,
                          _ target: VFDFrameBuffer, listTop: Int, scroll: Int, from: Int, to: Int) {
        for line in layout.lines {
            let screenTop: Int = listTop + line.y - scroll
            if screenTop + line.h < from - 2 { continue }
            if screenTop > to + 2 { break }
            let y: Int = listTop + line.y
            if line.row < 0 {
                VFDTxScreen.drawHeader(target, ctx.L, ui, st, line.group, y: y)
            } else {
                let row: VFDTxRow = st.library.groups[line.group].rows[line.row]
                VFDTxScreen.drawRow(ctx, ui, st, target, row, y: y)
            }
        }
    }

    /// MMListSectionHeader: chevron, title, 3-digit count; a tap folds or opens the section.
    fileprivate static func drawHeader(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ ui: VFDUIState, _ st: VFDTxState,
                           _ groupIndex: Int, y: Int) {
        let group: VFDTxGroup = st.library.groups[groupIndex]
        let sectionTitle: String = group.section.title
        let folded: Bool = st.collapsed.contains(sectionTitle)
        VFDW.section(fb, L, L.left, y, L.width, sectionTitle, count: group.rows.count, collapsed: folded,
                     action: {
                         VFDTxScreen.toggleCollapsed(ui, sectionTitle)
                     })
    }

    /// PacketRow + packetSwipeActions: tap sends, hold opens the menu, swipe left deletes,
    /// swipe right recategorizes.
    fileprivate static func drawRow(_ ctx: VFDContext, _ ui: VFDUIState, _ st: VFDTxState, _ fb: VFDFrameBuffer,
                        _ row: VFDTxRow, y: Int) {
        let L: VFDLayout = ctx.L
        let packet: MagicPacket = row.packet
        let withSwatches: Bool = !row.swatches.isEmpty
        if withSwatches {
            // The subtitle line (VFDW.packetRow's rows): after "CATEGORY · " the true-colour
            // swatches of the named colours, then the names, dim like the rest of the line.
            let hexRows: Int = packet.hex.isEmpty ? 0 : VFDW.line
            let sy: Int = y + 3 + hexRows + VFDW.line
            let x0: Int = L.left + 2 + VFDText.length(VFDW.upper(row.lead)) * VFDW.adv
            VFDTxSwatches.draw(fb, x0, sy, row.swatches, VFDW.upper(row.colorNames), L.left + L.width, VFDInk.dim)
        }
        VFDW.packetRow(fb, L, L.left, y, L.width, packet.label, packet.hex,
                       subtitle: withSwatches ? row.lead : row.subtitle,
                       selected: packet.id == st.selectedId, hexColor: VFDInk.dim,
                       action: {
                           VFDTxScreen.selectPacket(ctx, ui, packet)
                       },
                       long: {
                           VFDTxScreen.showActions(ctx, ui, packet)
                       },
                       swipeLeft: {
                           VFDTxScreen.askDelete(ctx, packet)
                       },
                       swipeRight: {
                           VFDTxScreen.askRecategorize(ctx, packet)
                       })
    }

    /// "NO TX LIBRARY — RUN RX SESSION", centred in the list area.
    fileprivate static func drawEmpty(_ fb: VFDFrameBuffer, _ L: VFDLayout, listTop: Int, viewH: Int) {
        let lines: [String] = VFDText.wrap(VFDTxScreen.emptyText, L.width)
        var y: Int = listTop + VFDMath.floorDiv(viewH - lines.count * VFDW.line, 2)
        for line in lines {
            fb.text(VFDW.cx(L.left, L.width, line), y, line, .small, VFDInk.dim)
            y += VFDW.line
        }
    }

    // MARK: - Actions (run from taps, never from draw)

    fileprivate static func toggleCollapsed(_ ui: VFDUIState, _ sectionTitle: String) {
        var next: Set<String> = VFDTxScreen.collapsedSections(ui)
        if next.contains(sectionTitle) {
            next.remove(sectionTitle)
        } else {
            next.insert(sectionTitle)
        }
        var names: [String] = []
        for section in LivePacketSection.allCases where next.contains(section.title) {
            names.append(section.title)
        }
        ui.setStoredStrings(VFDTxScreen.collapsedSectionsKey, names)
    }

    /// SectionFilterMenu: one row per section (ticked when shown); a pick toggles it and the
    /// menu opens again, as the standard menu stays open.
    fileprivate static func showFilter(_ ctx: VFDContext, _ ui: VFDUIState) {
        let visible: Set<String> = VFDTxScreen.visibleSections(ui)
        var items: [VFDMenuItem] = []
        var shownCount: Int = 0
        for section in LivePacketSection.allCases {
            let sectionTitle: String = section.title
            let on: Bool = visible.contains(sectionTitle)
            if on {
                shownCount += 1
            }
            let itemLabel: String = on ? sectionTitle + " ✓" : sectionTitle
            items.append(VFDMenuItem(itemLabel, action: {
                var next: Set<String> = VFDTxScreen.visibleSections(ui)
                if next.contains(sectionTitle) {
                    next.remove(sectionTitle)
                } else {
                    next.insert(sectionTitle)
                }
                ui.setStrings("visible", next)
                VFDTxScreen.showFilter(ctx, ui)
            }))
        }
        let menuTitle: String = "CLASS \(shownCount)/\(LivePacketSection.allCases.count)"
        ctx.menu(title: menuTitle, items: items)
    }

    /// A tap sends the packet and, while the loop runs, makes it the loop's packet.
    fileprivate static func selectPacket(_ ctx: VFDContext, _ ui: VFDUIState, _ packet: MagicPacket) {
        let tx: TxEngine = ctx.tx
        let ms: Int = TxLoopInterval.milliseconds(VFDTxScreen.interval(ctx, ui))
        tx.transmit(hex: packet.hex, label: packet.label)
        if tx.txLoopEnabled {
            tx.setTxLoop(enabled: true, packetId: packet.id, intervalMs: ms)
        }
        ui.setInt("selLoop", Int(tx.txLoopPacketId))
        ui.setInt("sel", Int(packet.id))
    }

    fileprivate static func setLoop(_ ctx: VFDContext, _ ui: VFDUIState, _ enabled: Bool) {
        let library: VFDTxLibrary = VFDTxLibraryCache.current(ctx.store)
        let packetId: Int64 = VFDTxScreen.selection(ctx, ui, library)
        if packetId < 0 { return }
        let ms: Int = TxLoopInterval.milliseconds(VFDTxScreen.interval(ctx, ui))
        ctx.tx.setTxLoop(enabled: enabled, packetId: packetId, intervalMs: ms)
    }

    /// TxScreen.commitInterval: the new interval, and the loop's when it runs.
    fileprivate static func commitInterval(_ ctx: VFDContext, _ ui: VFDUIState, _ seconds: Float) {
        let tx: TxEngine = ctx.tx
        let library: VFDTxLibrary = VFDTxLibraryCache.current(ctx.store)
        let packetId: Int64 = VFDTxScreen.selection(ctx, ui, library)
        let before: Int = tx.txLoopIntervalMs
        if tx.txLoopEnabled && packetId >= 0 {
            tx.setTxLoop(enabled: true, packetId: packetId, intervalMs: TxLoopInterval.milliseconds(seconds))
        }
        if tx.txLoopIntervalMs != before {
            // TxScreen then takes the engine's interval (onChange of txLoopIntervalMs).
            ui.remove("intervalSec")
        } else {
            ui.setDouble("intervalSec", Double(seconds))
            ui.setInt("intervalMs", tx.txLoopIntervalMs)
        }
    }

    /// The packet menu (PacketActionSheet): TRANSMIT, LOAD IN LAB, RENAME, RECATEGORIZE, DELETE.
    fileprivate static func showActions(_ ctx: VFDContext, _ ui: VFDUIState, _ packet: MagicPacket) {
        let vm: AppViewModel = ctx.vm
        let items: [VFDMenuItem] = [
            VFDMenuItem("Transmit", action: {
                VFDTxScreen.selectPacket(ctx, ui, packet)
            }),
            VFDMenuItem("Load in Lab", action: {
                vm.loadInLab(hex: packet.hex, label: packet.label)
            }),
            VFDMenuItem("Rename", action: {
                VFDTxScreen.askRename(ctx, packet)
            }),
            VFDMenuItem("Recategorize", action: {
                VFDTxScreen.askRecategorize(ctx, packet)
            }),
            VFDMenuItem("Delete", destructive: true, action: {
                VFDTxScreen.askDelete(ctx, packet)
            }),
        ]
        ctx.menu(title: packet.label, items: items)
    }

    /// RenameRequest: "Rename packet", the field starts with the label; a blank one is not saved.
    fileprivate static func askRename(_ ctx: VFDContext, _ packet: MagicPacket) {
        let store: MagicStore = ctx.store
        let packetId: Int64 = packet.id
        ctx.prompt(title: "Rename packet", text: packet.label, keyboard: .text, onDone: { (entered: String) in
            let trimmed: String = entered.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return }
            store.renamePacket(id: packetId, newLabel: entered)
        })
    }

    /// CategoryPickRequest: one row per MagicCategory.
    fileprivate static func askRecategorize(_ ctx: VFDContext, _ packet: MagicPacket) {
        let store: MagicStore = ctx.store
        let packetId: Int64 = packet.id
        var items: [VFDMenuItem] = []
        for category in MagicCategory.allCases {
            let picked: MagicCategory = category
            items.append(VFDMenuItem(category.rawValue, action: {
                store.recategorizePacket(id: packetId, category: picked)
            }))
        }
        ctx.menu(title: "Recategorize · " + packet.label, items: items)
    }

    /// Built-in presets stay, as on Android: the store removes only saved presets and learned
    /// packets.
    fileprivate static func askDelete(_ ctx: VFDContext, _ packet: MagicPacket) {
        let store: MagicStore = ctx.store
        let packetId: Int64 = packet.id
        let message: String = VFDTxScreen.deleteMessage(packet.label, packet.hex)
        ctx.confirm(title: "Delete from TX library?", message: message, confirmLabel: "DELETE", destructive: true,
                    action: {
                        store.deletePacketById(packetId)
                    })
    }

    /// The confirmDelete message: the label uppercased, then the hex.
    fileprivate static func deleteMessage(_ label: String, _ hex: String) -> String {
        let upperLabel: String = label.uppercased()
        if hex.isEmpty { return upperLabel }
        if upperLabel.isEmpty { return hex }
        return upperLabel + "\n" + hex
    }
}

// MARK: - Library snapshot

/// One library row with its subtitle ("CATEGORY · colors", or the category alone).
private struct VFDTxRow {
    let packet: MagicPacket
    let subtitle: String
    /// The subtitle before the colour names ("CATEGORY · "), or the whole subtitle.
    let lead: String
    /// The colour names of the subtitle (packet.colors), "" when it names none.
    let colorNames: String
    /// True colours of the named palette colours, drawn between `lead` and `colorNames`.
    let swatches: [VFDRGB]

    init(packet: MagicPacket) {
        self.packet = packet
        let category: String = packet.category.rawValue
        if packet.colors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.subtitle = category
            self.lead = category
            self.colorNames = ""
            self.swatches = []
        } else {
            self.subtitle = category + " · " + packet.colors
            self.lead = category + " · "
            self.colorNames = packet.colors
            self.swatches = VFDTxSwatches.named(packet.hex, packet.colors)
        }
    }
}

/// Colour names with true-colour swatches beside them (the library rows' subtitles).
private enum VFDTxSwatches {
    /// The true colours behind a classifier's colour names: each distinct palette colour that
    /// BandEffectModel reads from `hex` (a wand code's own colour when it reads none) and whose
    /// name is in `names`, in the order the names first appear there; at most five, OFF left out.
    static func named(_ hex: String, _ names: String) -> [VFDRGB] {
        let text: String = names.lowercased()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        let model: BandEffectModel = BandEffectModel.from(hex)
        var indices: [Int] = model.colors
        for zone in model.perLed {
            if let index = zone {
                indices.append(index)
            }
        }
        if indices.isEmpty {
            let upperHex: String = hex.uppercased()
            if upperHex.contains("CF9B") || upperHex.contains("CF0B") {
                indices.append(MagicClassifier.starlightColorIndex(hex))
            }
        }
        var found: [VFDTxNamedSwatch] = []
        var seen = Set<Int>()
        for raw in indices {
            let index: Int = raw & 0x1F
            if !seen.insert(index).inserted { continue }
            let name: String = StarlightColors.nameFor(index).lowercased()
            if name == "off" { continue }
            guard let range = text.range(of: name) else { continue }
            let pos: Int = text.distance(from: text.startIndex, to: range.lowerBound)
            found.append(VFDTxNamedSwatch(pos: pos, order: found.count, rgb: VFDColors.starlightGlow(index)))
        }
        found.sort(by: { (a: VFDTxNamedSwatch, b: VFDTxNamedSwatch) -> Bool in
            if a.pos != b.pos { return a.pos < b.pos }
            return a.order < b.order
        })
        var out: [VFDRGB] = []
        for item in found.prefix(5) {
            out.append(item.rgb)
        }
        return out
    }

    /// `swatches` as 5 x 5 true-colour squares 7 cells apart from column x0 on text row r, then
    /// `names` 4 cells after the last one, cut to end before `limit` (exclusive); without
    /// swatches (or room for them) just the names at x0. Returns the end column (as fb.text).
    @discardableResult
    static func draw(_ fb: VFDFrameBuffer, _ x0: Int, _ r: Int, _ swatches: [VFDRGB], _ names: String,
                     _ limit: Int, _ color: UInt8) -> Int {
        var n: Int = swatches.count
        // Keep room for at least two characters of the names.
        while n > 0 && x0 + 7 * n + 2 + VFDText.width(count: 2) > limit {
            n -= 1
        }
        var x: Int = x0
        if n > 0 {
            for i in 0..<n {
                fb.fill(x0 + 7 * i, r + 1, 5, 5, fb.rgb(swatches[i]))
            }
            x = x0 + 7 * n + 2
        }
        return fb.textFit(x, r, names, limit - x, .small, color)
    }
}

/// One swatch of `VFDTxSwatches.named`: where its colour's name first appears, and the colour.
private struct VFDTxNamedSwatch {
    let pos: Int
    let order: Int
    let rgb: VFDRGB
}

private struct VFDTxGroup {
    let section: LivePacketSection
    let rows: [VFDTxRow]
}

/// The library as TxScreen's TxLibrarySnapshot holds it.
private struct VFDTxLibrary {
    let groups: [VFDTxGroup]
    let ids: Set<Int64>
    /// Each packet's label by id (the first packet with that id).
    let labels: [Int64: String]
    /// The first packet of allTransmitPackets(), or -1 for an empty library.
    let firstId: Int64

    static func make(_ all: [MagicPacket]) -> VFDTxLibrary {
        let grouped: [(LivePacketSection, [MagicPacket])] = LivePacketSort.groupedMagicPackets(all)
        var groups: [VFDTxGroup] = []
        for entry in grouped {
            let packets: [MagicPacket] = entry.1
            if packets.isEmpty { continue }
            var rows: [VFDTxRow] = []
            rows.reserveCapacity(packets.count)
            for packet in packets {
                rows.append(VFDTxRow(packet: packet))
            }
            groups.append(VFDTxGroup(section: entry.0, rows: rows))
        }
        var ids = Set<Int64>()
        var labels: [Int64: String] = [:]
        for packet in all {
            if ids.insert(packet.id).inserted {
                labels[packet.id] = packet.label
            }
        }
        let firstId: Int64 = all.first?.id ?? -1
        return VFDTxLibrary(groups: groups, ids: ids, labels: labels, firstId: firstId)
    }

    /// The wanted packet when it is in the library, otherwise the first one.
    func validSelection(_ wanted: Int64) -> Int64 {
        if wanted >= 0 && ids.contains(wanted) {
            return wanted
        }
        return firstId
    }
}

/// The grouped library, rebuilt only when the store's revision (or the library's size) changes,
/// as TxScreen reads it again on `store.revision`. A memo: drawing stays free of visible state.
@MainActor
private enum VFDTxLibraryCache {
    static var revision: Int = Int.min
    static var count: Int = -1
    static var cached: VFDTxLibrary? = nil

    static func current(_ store: MagicStore) -> VFDTxLibrary {
        let all: [MagicPacket] = store.allTransmitPackets()
        if let hit = cached, revision == store.revision, count == all.count {
            return hit
        }
        let built: VFDTxLibrary = VFDTxLibrary.make(all)
        cached = built
        revision = store.revision
        count = all.count
        return built
    }
}

/// What one draw of the TX tab reads.
private struct VFDTxState {
    let library: VFDTxLibrary
    let selectedId: Int64
    let intervalSec: Float
    let dragging: Bool
    let dragStop: Int
    /// Folded sections (titles).
    let collapsed: Set<String>
    /// Sections the CLASS filter shows (titles).
    let visible: Set<String>
    let loopSettingsCollapsed: Bool
}

// MARK: - List layout

/// One line of the list: a section header block (row -1) or a packet row.
private struct VFDTxLine {
    /// Rows from the list's first row.
    let y: Int
    /// Rows to the next line.
    let h: Int
    let group: Int
    let row: Int
}

/// Rows of every header block and packet row of the visible sections, as tx.py draw_library
/// stacks them (a header block takes sectionGap - gap + sectionH + gap rows when folded; an open
/// section's first row starts gap rows earlier, right under the rule).
private struct VFDTxLayout {
    var lines: [VFDTxLine] = []
    /// Indices into lines of the header blocks.
    var heads: [Int] = []
    var height: Int = 0

    static func rowHeight(_ row: VFDTxRow) -> Int {
        var h: Int = 3
        if !row.packet.hex.isEmpty {
            h += VFDW.line
        }
        if !row.subtitle.isEmpty {
            h += VFDW.line
        }
        return h + 7 + 3 + 1
    }

    static func build(_ st: VFDTxState) -> VFDTxLayout {
        var out = VFDTxLayout()
        let headerBlock: Int = VFDW.sectionGap - VFDW.gap + VFDW.sectionH + VFDW.gap
        var y: Int = 0
        var g: Int = 0
        for group in st.library.groups {
            defer { g += 1 }
            let sectionTitle: String = group.section.title
            if !st.visible.contains(sectionTitle) { continue }
            out.heads.append(out.lines.count)
            if st.collapsed.contains(sectionTitle) {
                out.lines.append(VFDTxLine(y: y, h: headerBlock, group: g, row: -1))
                y += headerBlock
                continue
            }
            let openBlock: Int = headerBlock - VFDW.gap
            out.lines.append(VFDTxLine(y: y, h: openBlock, group: g, row: -1))
            y += openBlock
            var r: Int = 0
            for row in group.rows {
                let h: Int = VFDTxLayout.rowHeight(row)
                out.lines.append(VFDTxLine(y: y, h: h, group: g, row: r))
                y += h
                r += 1
            }
        }
        out.height = y
        return out
    }
}
