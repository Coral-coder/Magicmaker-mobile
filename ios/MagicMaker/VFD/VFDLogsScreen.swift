import SwiftUI
import UIKit

/// LOGS tab in the VFD theme: tools/vfd/screens/logs.py on the real capture logs.
///
/// Pinned rows (STATUS: <tx status>, the replay banner with STOP while a replay runs, a hairline),
/// then the log list, newest first, in its own scroll region: name (inverted while open, a boxed
/// REC while it is being written) over "<n> PKTS · <kb>KB · <ago> AGO". Under the open log: the
/// type and source filter chips and BAND ONLY, REPLAY / SHARE / DELETE, ANALYZE (HIDE PACKETS) and
/// ADD ALL → LIB, then the distinct packets (tap = TX, NAME = add to the library) or the packet rows
/// in log order (tap = TX), exactly as LogsScreen. Files are listed, read and summarised off the
/// main thread like LogsScreen does; DELETE asks first, NAME prompts, SHARE opens the system share
/// sheet in a sheet, toasts are drawn over the bottom of the list.
@MainActor
enum VFDLogsScreen: VFDScreen {
    static let title: String = "CAPTURE LOGS"

    /// Scroll region id of the log list.
    static let listRegion: String = "list"
    /// The open log's rows: .padding(.leading, 8).
    static let indent: Int = 6
    /// A PacketRow with hex and subtitle.
    static let packetRowH: Int = 36
    /// A LogsFileLabel / LogsAnalyzedRow.
    static let fileRowH: Int = 25
    static let analyzedRowH: Int = 25
    /// Packet rows listed for an open log (LogsScreen logsPacketRowLimit).
    static let packetRowLimit: Int = 1000
    static let toastSeconds: Double = 2.5
    static let stopW: Int = 23 + 12
    static let emptyText: String = "NO LOGS YET — START A SCAN"
    static let loadingText: String = "LOADING…"
    static let allNoiseText: String =
        "EVERYTHING IN THIS FILTER IS BAND TELEMETRY OR PINGS — FLIP THE SWITCH TO SEE IT"
    /// Drawing rows far above everything: the measuring pass draws no list rows.
    static let farAway: Int = -1_000_000

    static func headerRight(_ ctx: VFDContext) -> (text: String, action: () -> Void)? {
        return (text: "REFRESH", action: {
            VFDLogsModel.shared.refresh()
        })
    }

    static func draw(_ ctx: VFDContext) -> Int? {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let model: VFDLogsModel = VFDLogsModel.shared
        model.sync(ctx)
        let c: Int = L.left
        let w: Int = L.width
        // The status line, the banner and the hairline stay put (iOS keeps them above the List).
        let scroll: Int = -fb.originY
        fb.pushClip(0, L.contentTop + scroll, fb.cols, L.contentH, dy: scroll)
        let listTop: Int = VFDLogsScreen.pinned(ctx, c, L.contentTop, w)
        if !model.logsLoaded || model.logs.isEmpty {
            VFDLogsScreen.emptyState(ctx, c, listTop, w, loaded: model.logsLoaded)
        } else {
            VFDLogsScreen.drawList(ctx, model, c, listTop, w)
        }
        VFDLogsScreen.drawToast(ctx, model)
        fb.popClip()
        return nil
    }

    // MARK: - Pinned top

    /// STATUS line, the replay banner, the hairline. Returns the list's first row.
    fileprivate static func pinned(_ ctx: VFDContext, _ c: Int, _ top: Int, _ w: Int) -> Int {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let status: String = ctx.tx.status
        let warn: Bool = status == TxEngine.notLinkedStatus || status == TxEngine.sendFailedStatus
        let color: UInt8 = warn ? VFDInk.alarm : VFDInk.dim
        var y: Int = VFDW.statusLine(fb, L, c, top, w, "STATUS: " + status, color: color)
        y = VFDLogsScreen.replayBanner(ctx, c, y + 1, w) - VFDW.gap
        fb.hline(c, y + 3, w, VFDInk.dim)
        return y + 7
    }

    /// While a replay runs: a solid highlight block with "REPLAYING n/total · file" cut out (two
    /// lines at most, the first beside STOP), STOP a cut-out outline button on the right.
    fileprivate static func replayBanner(_ ctx: VFDContext, _ c: Int, _ y: Int, _ w: Int) -> Int {
        let tx: TxEngine = ctx.tx
        if !tx.replayActive {
            return y
        }
        let fb: VFDFrameBuffer = ctx.fb
        let h: Int = 29
        fb.fill(c, y, w, h, VFDInk.highlight)
        let sw: Int = VFDLogsScreen.stopW
        let sx: Int = c + w - 3 - sw
        fb.box(sx, y + 2, sw, VFDW.ctrlH, VFDInk.unlit)
        fb.text(sx + 6, y + 2 + VFDW.ctrlText, "STOP", .small, VFDInk.unlit)
        VFDLogsText.growTap(fb, sx - 2, y + 2, sw + 4, VFDW.ctrlH, "button:STOP", action: {
            tx.stopReplay()
        })
        let progress: String = "\(tx.replayProgress)/\(tx.replayTotal)"
        let text: String = "REPLAYING " + progress + " · " + tx.replayLabel
        let x: Int = c + 4
        let firstW: Int = sx - 6 - x
        let fullW: Int = c + w - 4 - x
        var words: [String] = VFDLogsText.splitString(text, " ")
        var line1: String = ""
        while !words.isEmpty {
            let cand: String = VFDText.strip(line1 + " " + words[0])
            if VFDText.width(cand) > firstW { break }
            line1 = cand
            words.removeFirst()
        }
        var line2: String = words.joined(separator: " ")
        if !line2.isEmpty {
            let kept: [String] = VFDLogsText.dropDangling([line1, line2])
            line1 = kept.count > 0 ? kept[0] : ""
            line2 = kept.count > 1 ? kept[1] : ""
        }
        fb.text(x, y + 5, line1, .small, VFDInk.unlit)
        if !line2.isEmpty {
            fb.textFit(x, y + 17, line2, fullW, .small, VFDInk.unlit)
        }
        return y + h + VFDW.gap
    }

    /// NO LOGS YET — START A SCAN (or LOADING… before the first listing), centred in the space.
    fileprivate static func emptyState(_ ctx: VFDContext, _ c: Int, _ y: Int, _ w: Int, loaded: Bool) {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let s: String = loaded ? VFDLogsScreen.emptyText : VFDLogsScreen.loadingText
        let lines: [String] = VFDLogsText.captionLines(s, w - 10)
        let half: Int = VFDMath.floorDiv(lines.count * VFDW.line, 2)
        let mid: Int = max(y, VFDMath.floorDiv(y + L.contentBottom, 2) - half)
        var i: Int = 0
        for ln in lines {
            fb.text(VFDW.cx(c, w, ln), mid + i * VFDW.line, ln, .small, VFDInk.dim)
            i += 1
        }
    }

    // MARK: - The list

    /// The list in rows listTop ..< contentBottom: measured (drawn into an empty clip), scrolled by
    /// its own region, drawn inside a window that hides lines cut by the edges, then its
    /// scrollbar.
    fileprivate static func drawList(_ ctx: VFDContext, _ model: VFDLogsModel, _ c: Int, _ listTop: Int, _ w: Int) {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let bottom: Int = L.contentBottom
        let viewH: Int = bottom - listTop
        if viewH <= 0 { return }
        let far: (top: Int, bottom: Int) = (top: VFDLogsScreen.farAway, bottom: VFDLogsScreen.farAway)
        fb.pushClip(0, 0, 0, 0)
        let end: Int = VFDLogsScreen.logList(ctx, model, fb, c, listTop, w, vis: far)
        fb.popClip()
        let total: Int = end - listTop
        let s: Int = ctx.scroll(VFDLogsScreen.listRegion, limit: total - viewH)
        // The renderer's drag limit is contentRows minus the region's clipped height.
        let shownRows: Int = VFDLogsText.clippedRows(fb, listTop, viewH)
        fb.scrollRegion(id: VFDLogsScreen.listRegion, 0, listTop, fb.cols, viewH,
                        contentRows: total - viewH + shownRows)

        fb.pushClip(0, listTop, fb.cols, viewH, dy: -s)
        let vis: (top: Int, bottom: Int) = (top: listTop + s, bottom: bottom + s)
        let win = VFDW.snappedWindow(fb, top: listTop, bottom: bottom, draw: { (target: VFDFrameBuffer) in
            _ = VFDLogsScreen.logList(ctx, model, target, c, listTop, w, vis: vis)
        })
        let firstTap: Int = fb.taps.count
        fb.pushClip(0, win.top - fb.originY, fb.cols, win.bottom - win.top)
        _ = VFDLogsScreen.logList(ctx, model, fb, c, listTop, w, vis: vis)
        fb.popClip()
        if fb.taps.count > firstTap {
            var kept: [VFDHit] = Array(fb.taps[0..<firstTap])
            for hit in fb.taps[firstTap...] where hit.h >= VFDW.tapRows {
                kept.append(hit)
            }
            fb.taps = kept
        }
        fb.popClip()
        VFDW.listScrollbar(fb, listTop, viewH, total, s)
    }

    /// Every log row, the open one followed by its detail rows. Rows outside `vis` (drawing rows)
    /// are only counted. Returns the end row.
    fileprivate static func logList(_ ctx: VFDContext, _ model: VFDLogsModel, _ fb: VFDFrameBuffer, _ c: Int,
                                    _ top: Int, _ w: Int, vis: (top: Int, bottom: Int)) -> Int {
        var y: Int = top
        let rowH: Int = VFDLogsScreen.fileRowH
        for log in model.logs {
            let visible: Bool = y + rowH + 2 > vis.top && y - 2 < vis.bottom
            if visible {
                y = VFDLogsScreen.logRow(ctx, model, fb, c, y, w, log)
            } else {
                y += rowH
            }
            if let open = model.selectedPath, open == log.path {
                y = VFDLogsScreen.detailRows(ctx, model, fb, c, y, w, log, vis: vis)
            }
        }
        return y
    }

    /// LogsFileLabel: the name (text; the open log an inverted block) with a boxed REC while it is
    /// being written, "<n> PKTS · <kb>KB · <ago> AGO" in dim, a dotted divider. Tap opens / closes.
    fileprivate static func logRow(_ ctx: VFDContext, _ model: VFDLogsModel, _ fb: VFDFrameBuffer, _ c: Int,
                                   _ r: Int, _ w: Int, _ log: LogFile) -> Int {
        let selected: Bool = model.selectedPath == log.path
        let active: Bool = VFDLogsScreen.isActiveLog(ctx, log)
        var y: Int = r + 3
        var x: Int = c + 2
        let tagW: Int = active ? VFDText.width("REC") + 8 : 0
        let shown: String = VFDLogsText.fitMiddle(log.name, w - 4 - tagW)
        if selected {
            x = VFDW.badge(fb, x, y, shown, VFDInk.highlight)
        } else {
            x = fb.text(x, y, shown, .small, VFDInk.text) + 1
        }
        if active {
            VFDW.tagBox(fb, x + 4, y, "REC", color: VFDInk.highlight, textColor: VFDInk.highlight)
        }
        let kb: Int64 = log.sizeBytes / 1024
        var detail: String = "\(log.packetCount) PKTS · \(kb)KB"
        let ago: String = VFDLogsText.agoText(log.modifiedMs, now: ctx.time)
        if !ago.isEmpty {
            detail += " · " + ago.uppercased() + " AGO"
        }
        y += VFDW.line
        fb.textFit(c + 2, y, detail, w - 2, .small, VFDInk.dim)
        y += 7 + 3
        fb.hline(c, y, w, VFDInk.dim, step: 2)
        VFDLogsText.growTap(fb, c, r, w, y - r, "log:" + log.name, action: {
            VFDLogsModel.shared.toggleSelection(log)
        })
        return y + 1
    }

    /// The log being written right now.
    fileprivate static func isActiveLog(_ ctx: VFDContext, _ log: LogFile) -> Bool {
        let store: MagicStore = ctx.store
        guard let active = store.activeSessionName else { return false }
        return store.sessionActive && active == log.name
    }

    // MARK: - The open log

    /// Everything under the open log, indented: the filters (once the log has been read), the two
    /// button rows, then LOADING…, the analysis or the packet rows.
    fileprivate static func detailRows(_ ctx: VFDContext, _ model: VFDLogsModel, _ fb: VFDFrameBuffer, _ c0: Int,
                                       _ top: Int, _ w0: Int, _ log: LogFile, vis: (top: Int, bottom: Int)) -> Int {
        let L: VFDLayout = ctx.L
        let c: Int = c0 + VFDLogsScreen.indent
        let w: Int = w0 - VFDLogsScreen.indent
        var y: Int = top
        if let open = model.openLog {
            y = VFDLogsScreen.filterRows(ctx, model, fb, c, y, w, open)
        }
        let tx: TxEngine = ctx.tx
        let replay = VFDLogsButton(label: "REPLAY", color: VFDInk.text, enabled: !tx.replayActive, expand: true,
                                   action: {
                                       VFDLogsScreen.startReplay(ctx, log)
                                   })
        let share = VFDLogsButton(label: "SHARE", color: VFDInk.text, enabled: true, expand: false, action: {
            VFDLogsScreen.share(ctx, log)
        })
        let delete = VFDLogsButton(label: "DELETE", color: VFDInk.alarm, enabled: true, expand: false, action: {
            VFDLogsScreen.askDelete(ctx, log)
        })
        y = VFDLogsText.buttonRow(fb, L, c, y, w, [replay, share, delete])
        let analyzeLabel: String = model.analyzing ? "HIDE PACKETS" : "ANALYZE"
        let analyze = VFDLogsButton(label: analyzeLabel, color: VFDInk.text, enabled: true, expand: true, action: {
            VFDLogsModel.shared.toggleAnalyzing()
        })
        let addAll = VFDLogsButton(label: "ADD ALL → LIB", color: VFDInk.text,
                                   enabled: model.upToDateSummary != nil, expand: true, action: {
                                       VFDLogsScreen.addAllToLibrary(ctx)
                                   })
        y = VFDLogsText.buttonRow(fb, L, c, y, w, [analyze, addAll])
        guard model.openLog != nil, let summary = model.currentSummary else {
            return VFDLogsText.noteLines(fb, c, y + 1, w, VFDLogsScreen.loadingText)
        }
        if model.analyzing {
            return VFDLogsScreen.analyzeRows(ctx, model, fb, c, y, w, summary, vis: vis)
        }
        return VFDLogsScreen.packetRows(ctx, fb, c, y, w, summary, vis: vis)
    }

    /// FILTER TYPES chips, FILTER SOURCE chips (at most LogAnalysis.sourceChipLimit), BAND ONLY.
    fileprivate static func filterRows(_ ctx: VFDContext, _ model: VFDLogsModel, _ fb: VFDFrameBuffer, _ c: Int,
                                       _ top: Int, _ w: Int, _ open: VFDLogsOpenLog) -> Int {
        let L: VFDLayout = ctx.L
        var y: Int = top
        let categories: [String] = open.categories
        if !categories.isEmpty {
            y = VFDLogsText.caption(fb, L, c, y, w, "FILTER TYPES (NONE = ALL)")
            var selected = Set<Int>()
            var i: Int = 0
            for category in categories {
                if model.selectedCats.contains(category) {
                    selected.insert(i)
                }
                i += 1
            }
            y = VFDW.options(fb, L, c, y, w, categories, selected: selected, name: "filter:type",
                             onSelect: { (index: Int) in
                                 if index >= 0 && index < categories.count {
                                     VFDLogsModel.shared.toggleCategory(categories[index])
                                 }
                             })
        }
        if !open.addresses.isEmpty {
            y = VFDLogsText.caption(fb, L, c, y, w, "FILTER SOURCE (TAP = ONLY THAT SOURCE)")
            let addresses: [String] = Array(open.addresses.prefix(LogAnalysis.sourceChipLimit))
            var chips: [String] = []
            var selected = Set<Int>()
            var i: Int = 0
            for address in addresses {
                chips.append(shortAddress(address))
                if address == model.selectedAddr {
                    selected.insert(i)
                }
                i += 1
            }
            y = VFDW.options(fb, L, c, y, w, chips, selected: selected, name: "filter:source",
                             onSelect: { (index: Int) in
                                 if index >= 0 && index < addresses.count {
                                     VFDLogsModel.shared.toggleSource(addresses[index])
                                 }
                             })
        }
        return VFDW.toggle(fb, L, c, y, w, "BAND ONLY", model.bandOnly, labelColor: VFDInk.dim, action: {
            VFDLogsModel.shared.toggleBandOnly()
        })
    }

    /// ANALYZE: HIDE BANDS & PINGS, the hint, one LogsAnalyzedRow per distinct packet (at most
    /// LogAnalysis.analyzedRowLimit), "…and n more".
    fileprivate static func analyzeRows(_ ctx: VFDContext, _ model: VFDLogsModel, _ fb: VFDFrameBuffer, _ c: Int,
                                        _ top: Int, _ w: Int, _ summary: LogSummary,
                                        vis: (top: Int, bottom: Int)) -> Int {
        let L: VFDLayout = ctx.L
        let noiseLabel: String = "HIDE BANDS & PINGS (\(summary.noiseCount) OF \(summary.filtered.count))"
        var y: Int = VFDLogsText.wrappedToggle(fb, L, c, top, w, noiseLabel, model.hideNoise, action: {
            VFDLogsModel.shared.toggleHideNoise()
        })
        let rows: [AnalyzedPacket] = summary.analyzed
        if rows.isEmpty && summary.noiseCount > 0 {
            y = VFDLogsText.noteLines(fb, c, y + 1, w, VFDLogsScreen.allNoiseText, color: VFDInk.highlight)
        } else {
            y = VFDLogsText.noteLines(fb, c, y + 1, w, "\(rows.count) UNIQUE · TAP = TX · NAME = ADD")
        }
        y -= VFDW.gap
        fb.hline(c, y, w, VFDInk.dim, step: 2)
        y += 1
        let limit: Int = LogAnalysis.analyzedRowLimit
        let shown: Int = min(rows.count, limit)
        let rowH: Int = VFDLogsScreen.analyzedRowH
        let first: Int = max(0, VFDMath.floorDiv(vis.top - y, rowH) - 1)
        let last: Int = min(shown, VFDMath.floorDiv(vis.bottom - y, rowH) + 2)
        if last > first {
            for i in first..<last {
                _ = VFDLogsScreen.analyzedRow(ctx, fb, c, y + i * rowH, w, rows[i])
            }
        }
        y += shown * rowH
        if rows.count > limit {
            let hidden: Int = rows.count - limit
            y = VFDLogsText.noteLines(fb, c, y, w, "…and \(hidden) more (showing top \(limit))")
        }
        return y
    }

    /// LogsAnalyzedRow: "×count · LABEL" over the hex (dim), NAME on the right, a dotted divider.
    /// Tap the text = TX, NAME = save to the library under a new name.
    fileprivate static func analyzedRow(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ c: Int, _ r: Int, _ w: Int,
                                        _ row: AnalyzedPacket) -> Int {
        let L: VFDLayout = ctx.L
        let bw: Int = VFDText.width("NAME") + 12
        let bx: Int = c + w - bw
        let tw: Int = bx - 6 - c
        let y: Int = r + 3
        let head: String = VFDW.upper("×\(row.count) · " + row.label)
        fb.textFit(c, y, head, tw, .small, VFDInk.text)
        fb.textFit(c, y + VFDW.line, row.hex, tw, .small, VFDInk.dim)
        VFDW.button(fb, L, bx, r + 5, bw, "NAME", name: "name:" + row.label, action: {
            VFDLogsScreen.askName(ctx, row)
        })
        let end: Int = y + VFDW.line + 7 + 3
        fb.hline(c, end, w, VFDInk.dim, step: 2)
        let tx: TxEngine = ctx.tx
        fb.tap(c, r, bx - 2 - c, end - r, name: "tx:" + row.label, action: {
            tx.transmit(hex: row.hex, label: row.label)
        })
        return end + 1
    }

    /// The filtered rows in log order: the hint, the PacketRows (at most packetRowLimit, only the
    /// ones in view drawn), "…and n more".
    fileprivate static func packetRows(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ c: Int, _ top: Int, _ w: Int,
                                       _ summary: LogSummary, vis: (top: Int, bottom: Int)) -> Int {
        let L: VFDLayout = ctx.L
        let count: Int = summary.filtered.count
        var y: Int = VFDLogsText.noteLines(fb, c, top + 1, w, "\(count) PACKETS · TAP = TX")
        y -= VFDW.gap
        let limit: Int = VFDLogsScreen.packetRowLimit
        let shown: Int = min(count, limit)
        let rowH: Int = VFDLogsScreen.packetRowH
        let first: Int = max(0, VFDMath.floorDiv(vis.top - y, rowH) - 1)
        let last: Int = min(shown, VFDMath.floorDiv(vis.bottom - y, rowH) + 2)
        let tx: TxEngine = ctx.tx
        if last > first {
            for i in first..<last {
                let packet: LoggedPacket = summary.filtered[i]
                let label: String = VFDLogsText.packetLabel(packet)
                let sub: String = VFDLogsText.packetSubtitle(packet, w - 2)
                let tag: String? = packet.isBand ? "BAND" : nil
                VFDW.packetRow(fb, L, c, y + i * rowH, w, label, packet.hex, subtitle: sub, tag: tag,
                               hexColor: VFDInk.dim, action: {
                                   tx.transmit(hex: packet.hex, label: label)
                               })
            }
        }
        y += shown * rowH
        if count > limit {
            let hidden: Int = count - limit
            y = VFDLogsText.noteLines(fb, c, y, w, "…and \(hidden) more (showing first \(limit))")
        }
        return y
    }

    // MARK: - Toast

    /// Where LogsScreen shows a toast: a boxed message over the bottom of the list for 2.5 s.
    fileprivate static func drawToast(_ ctx: VFDContext, _ model: VFDLogsModel) {
        let text: String = model.toastText
        if text.isEmpty { return }
        let age: Double = ctx.time - model.toastAt
        if age < -1.0 || age >= VFDLogsScreen.toastSeconds { return }
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let c: Int = L.left + 8
        let w: Int = L.width - 16
        let lines: [String] = VFDText.wrap(VFDW.upper(text), w - 12)
        if lines.isEmpty { return }
        let h: Int = lines.count * VFDW.line + 8
        let top: Int = L.contentBottom - h - 6
        fb.fill(c - 2, top - 2, w + 4, h + 4, VFDInk.unlit)
        fb.box(c, top, w, h, VFDInk.highlight)
        var r: Int = top + 4
        for ln in lines {
            fb.text(VFDW.cx(c, w, ln), r, ln, .small, VFDInk.text)
            r += VFDW.line
        }
    }

    // MARK: - Actions (LogsScreen's)

    fileprivate static func startReplay(_ ctx: VFDContext, _ log: LogFile) {
        let model: VFDLogsModel = VFDLogsModel.shared
        ctx.tx.startReplay(path: log.path, categories: model.selectedCats, address: model.selectedAddr,
                           bandOnly: model.bandOnly)
    }

    /// ShareLink(item: the log file): the system share sheet.
    fileprivate static func share(_ ctx: VFDContext, _ log: LogFile) {
        let url: URL = URL(fileURLWithPath: log.path)
        let finish: () -> Void = {
            ctx.dismissSheet()
        }
        let sheet: VFDLogsShareSheet = VFDLogsShareSheet(url: url, onFinish: finish)
        ctx.sheet(id: "logs.share") {
            sheet
        }
    }

    fileprivate static func askDelete(_ ctx: VFDContext, _ log: LogFile) {
        ctx.confirm(title: "Delete log?", message: log.name.uppercased(), confirmLabel: "DELETE",
                    destructive: true, action: {
                        ctx.store.deleteLog(path: log.path)
                        let model: VFDLogsModel = VFDLogsModel.shared
                        model.closeLog()
                        model.refresh()
                        model.showToast("Log deleted", at: ctx.now)
                    })
    }

    fileprivate static func addAllToLibrary(_ ctx: VFDContext) {
        let model: VFDLogsModel = VFDLogsModel.shared
        guard let result = model.upToDateSummary else { return }
        var hexes: [String] = []
        hexes.reserveCapacity(result.analyzed.count)
        for row in result.analyzed {
            hexes.append(row.hex)
        }
        let added: Int = ctx.store.importHexesToLibrary(hexes)
        model.refresh()
        model.showToast("Added \(added) to library", at: ctx.now)
    }

    /// RenameRequest(initial: row.label): a blank entry saves nothing.
    fileprivate static func askName(_ ctx: VFDContext, _ row: AnalyzedPacket) {
        ctx.prompt(title: "Rename packet", text: row.label, keyboard: .text, onDone: { (entered: String) in
            let trimmed: String = entered.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return }
            VFDLogsScreen.saveName(ctx, row, newLabel: entered)
        })
    }

    fileprivate static func saveName(_ ctx: VFDContext, _ row: AnalyzedPacket, newLabel: String) {
        let blank: Bool = newLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let label: String = blank ? row.label : newLabel
        let error: String? = ctx.store.saveCustomPreset(label: label, hex: row.hex)
        let model: VFDLogsModel = VFDLogsModel.shared
        model.refresh()
        let done: String = "Added \"" + newLabel + "\" to library"
        model.showToast(error ?? done, at: ctx.now)
    }
}

// MARK: - Screen state

/// One log file as the screen uses it.
private struct VFDLogsOpenLog {
    let path: String
    let packets: [LoggedPacket]
    /// Distinct categories, sorted: the type chips.
    let categories: [String]
    /// Distinct source ids, first heard first: the source chips.
    let addresses: [String]
}

/// The filters a summary was made for.
private struct VFDLogsSummaryKey: Equatable {
    let path: String
    let generation: Int
    let categories: Set<String>
    let address: String
    let bandOnly: Bool
    let hideNoise: Bool
}

/// The rows still queued for the session file are written first, as LogsScreen does.
private func vfdLogsListFiles() -> [LogFile] {
    SessionLogFiles.flushPendingRows()
    return SessionLogFiles.listLogs()
}

private func vfdLogsReadFile(_ path: String) -> VFDLogsOpenLog {
    SessionLogFiles.flushPendingRows()
    let packets: [LoggedPacket] = SessionLogFiles.readLog(path: path)
    return VFDLogsOpenLog(
        path: path,
        packets: packets,
        categories: LogAnalysis.categories(packets),
        addresses: LogAnalysis.addresses(packets)
    )
}

/// LogsScreen's @State, kept while the app runs. The file work runs off the main thread like the
/// standard screen's .task(id:) blocks: `sync` (called at the top of every draw) only notes which
/// listing, read or summary the current state wants and starts it once; the results land later
/// and redraw. Drawing itself never sees a change made during the frame.
@MainActor
private final class VFDLogsModel {
    static let shared: VFDLogsModel = VFDLogsModel()
    /// A frame gap this long means the tab was left and opened again (it redraws at least once a
    /// second while shown): list the logs again, as LogsScreen does when it appears.
    static let revisitGap: Double = 2.5

    private(set) var logs: [LogFile] = []
    private(set) var logsLoaded: Bool = false
    private(set) var selectedPath: String? = nil
    private(set) var loaded: VFDLogsOpenLog? = nil
    private(set) var loadGeneration: Int = 0
    // Per-log filters: they start over whenever another log is opened.
    private(set) var selectedCats: Set<String> = []
    private(set) var selectedAddr: String = ""
    private(set) var bandOnly: Bool = false
    private(set) var analyzing: Bool = false
    private(set) var hideNoise: Bool = true
    private(set) var summary: LogSummary? = nil
    private(set) var summaryKey: VFDLogsSummaryKey? = nil
    private(set) var toastText: String = ""
    private(set) var toastAt: Double = 0

    /// REFRESH, NAME, ADD ALL and DELETE list the logs again and re-read the open one.
    private var refreshTick: Int = 0
    private var visit: Int = 0
    private var lastFrame: Double = 0
    private var listDone: String? = nil
    private var listRunning: String? = nil
    private var readDone: String? = nil
    private var readRunning: String? = nil
    private var summaryRunning: VFDLogsSummaryKey? = nil

    init() {}

    // MARK: derived

    /// The selected log's rows, once they have been read.
    var openLog: VFDLogsOpenLog? {
        guard let open = loaded, let path = selectedPath, open.path == path else { return nil }
        return open
    }

    /// The newest result, possibly for the filters just before the latest change.
    var currentSummary: LogSummary? {
        if openLog == nil { return nil }
        return summary
    }

    /// The result for exactly the current filters, or nil while it is being worked out.
    var upToDateSummary: LogSummary? {
        if openLog == nil { return nil }
        guard let key = currentKey, let done = summaryKey, done == key else { return nil }
        return summary
    }

    var currentKey: VFDLogsSummaryKey? {
        guard let open = loaded else { return nil }
        return VFDLogsSummaryKey(path: open.path, generation: loadGeneration, categories: selectedCats,
                                 address: selectedAddr, bandOnly: bandOnly, hideNoise: hideNoise)
    }

    // MARK: loading

    func sync(_ ctx: VFDContext) {
        let t: Double = ctx.time
        if lastFrame > 0 && t - lastFrame > VFDLogsModel.revisitGap {
            visit += 1
        }
        if t > lastFrame {
            lastFrame = t
        }
        let scan: ScanEngine = ctx.scan
        let rec: String = scan.recordSessionActive ? "1" : "0"
        let listKey: String = "\(refreshTick)|\(visit)|" + rec + "|" + scan.activeSessionName
        if listKey != listDone && listKey != listRunning {
            startList(listKey, ctx)
        }
        if let path = selectedPath {
            let readKey: String = "\(refreshTick)|" + path
            if readKey != readDone && readKey != readRunning {
                startRead(path, readKey, ctx)
            }
        }
        if let key = currentKey, let open = loaded {
            let done: Bool = summaryKey == key
            let running: Bool = summaryRunning == key
            if !done && !running {
                startSummary(key, open.packets, ctx)
            }
        }
    }

    private func startList(_ key: String, _ ctx: VFDContext) {
        listRunning = key
        Task { @MainActor in
            let listed: [LogFile] = await Task.detached(priority: .userInitiated) { () -> [LogFile] in
                vfdLogsListFiles()
            }.value
            self.finishList(listed, key: key, ctx)
        }
    }

    private func finishList(_ listed: [LogFile], key: String, _ ctx: VFDContext) {
        if listRunning != key { return }
        listRunning = nil
        listDone = key
        logs = listed
        logsLoaded = true
        // A log that is no longer there (deleted from Files) is no longer open.
        if let path = selectedPath {
            var found: Bool = false
            for log in listed where log.path == path {
                found = true
                break
            }
            if !found {
                closeLog()
            }
        }
        ctx.redraw()
    }

    private func startRead(_ path: String, _ key: String, _ ctx: VFDContext) {
        readRunning = key
        Task { @MainActor in
            let open: VFDLogsOpenLog = await Task.detached(priority: .userInitiated) { () -> VFDLogsOpenLog in
                vfdLogsReadFile(path)
            }.value
            self.finishRead(open, key: key, ctx)
        }
    }

    private func finishRead(_ open: VFDLogsOpenLog, key: String, _ ctx: VFDContext) {
        if readRunning != key { return }
        readRunning = nil
        readDone = key
        guard let path = selectedPath, path == open.path else { return }
        loaded = open
        loadGeneration += 1
        ctx.redraw()
    }

    private func startSummary(_ key: VFDLogsSummaryKey, _ packets: [LoggedPacket], _ ctx: VFDContext) {
        summaryRunning = key
        Task { @MainActor in
            let result: LogSummary = await Task.detached(priority: .userInitiated) { () -> LogSummary in
                LogAnalysis.summarize(
                    packets,
                    categories: key.categories,
                    address: key.address,
                    bandOnly: key.bandOnly,
                    hideNoise: key.hideNoise
                )
            }.value
            self.finishSummary(result, key: key, ctx)
        }
    }

    private func finishSummary(_ result: LogSummary, key: VFDLogsSummaryKey, _ ctx: VFDContext) {
        guard let running = summaryRunning, running == key else { return }
        summaryRunning = nil
        summary = result
        summaryKey = key
        ctx.redraw()
    }

    // MARK: actions

    func refresh() {
        refreshTick += 1
    }

    func toggleSelection(_ log: LogFile) {
        let next: String? = selectedPath == log.path ? nil : log.path
        forgetOpenLog()
        selectedPath = next
        resetFilters()
    }

    /// No log open (after a delete, or when the open one is gone).
    func closeLog() {
        forgetOpenLog()
        selectedPath = nil
        resetFilters()
    }

    /// Nothing of the previous log may show while another one is read; results still on their
    /// way for it are dropped.
    private func forgetOpenLog() {
        loaded = nil
        summary = nil
        summaryKey = nil
        readDone = nil
        readRunning = nil
        summaryRunning = nil
    }

    private func resetFilters() {
        selectedCats = []
        selectedAddr = ""
        bandOnly = false
        analyzing = false
        hideNoise = true
    }

    func toggleCategory(_ category: String) {
        if selectedCats.contains(category) {
            selectedCats.remove(category)
        } else {
            selectedCats.insert(category)
        }
    }

    /// Single choice: tapping a source shows only that one; tapping it again shows all.
    func toggleSource(_ address: String) {
        selectedAddr = selectedAddr == address ? "" : address
    }

    func toggleBandOnly() {
        bandOnly = !bandOnly
    }

    func toggleAnalyzing() {
        analyzing = !analyzing
    }

    func toggleHideNoise() {
        hideNoise = !hideNoise
    }

    func showToast(_ text: String, at time: Double) {
        toastText = text
        toastAt = time
    }
}

// MARK: - Drawing helpers (logs.py)

/// One outline button of a button row: fixed buttons hug their label, expanding ones share the
/// rest.
private struct VFDLogsButton {
    let label: String
    let color: UInt8
    let enabled: Bool
    let expand: Bool
    let action: () -> Void
}

private enum VFDLogsText {
    static let sep: String = " · "

    /// Time of day on a packet row.
    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    // MARK: strings

    static func splitString(_ s: String, _ sep: String) -> [String] {
        var out: [String] = []
        for part in VFDText.split(VFDText.scalars(s), VFDText.scalars(sep)) {
            out.append(VFDText.string(part))
        }
        return out
    }

    static func rstrip(_ s: String) -> String {
        return VFDText.string(VFDText.rstrip(VFDText.scalars(s)))
    }

    static func lstrip(_ s: String) -> String {
        let a: [Unicode.Scalar] = VFDText.scalars(s)
        var i: Int = 0
        while i < a.count && VFDText.isSpace(a[i]) {
            i += 1
        }
        return VFDText.string(Array(a[i...]))
    }

    /// Without its last scalar.
    static func dropLastScalar(_ s: String) -> String {
        let a: [Unicode.Scalar] = VFDText.scalars(s)
        if a.isEmpty { return s }
        return VFDText.string(Array(a[0..<(a.count - 1)]))
    }

    static func dropFirstScalar(_ s: String) -> String {
        let a: [Unicode.Scalar] = VFDText.scalars(s)
        if a.isEmpty { return s }
        return VFDText.string(Array(a[1...]))
    }

    /// s, or its head and tail around "…" so it fits maxCols (.truncationMode(.middle)).
    static func fitMiddle(_ s: String, _ maxCols: Int) -> String {
        let n: Int = VFDText.maxChars(maxCols)
        let a: [Unicode.Scalar] = VFDText.scalars(s)
        if a.count <= n { return s }
        if n <= 1 { return VFDText.fit(s, maxCols) }
        let keep: Int = n - 1
        let head: Int = VFDMath.floorDiv(keep + 1, 2)
        let tail: Int = keep - head
        let first: String = VFDText.string(Array(a[0..<head]))
        let last: String = VFDText.string(Array(a[(a.count - tail)...]))
        return first + VFDText.ellipsis + last
    }

    /// Wrapped lines without a separator left hanging at a break: a trailing " ·" is cut from every
    /// line but the last and a leading "· " from every line but the first (logs.py drop_dangling).
    static func dropDangling(_ lines: [String]) -> [String] {
        var out: [String] = []
        let n: Int = lines.count
        var i: Int = 0
        for ln in lines {
            var s: String = ln
            if i < n - 1 {
                while true {
                    let r: String = rstrip(s)
                    if r.hasSuffix(" ·") || VFDText.strip(s) == "·" {
                        s = rstrip(dropLastScalar(r))
                    } else {
                        break
                    }
                }
            }
            if i > 0 {
                while true {
                    let l: String = lstrip(s)
                    if l.hasPrefix("· ") {
                        s = lstrip(dropFirstScalar(l))
                    } else {
                        break
                    }
                }
            }
            if !s.isEmpty || ln.isEmpty {
                out.append(s)
            }
            i += 1
        }
        return out
    }

    /// A caption broken into lines of at most w cells: at its " · " separators (dropped at the
    /// break), before a "(…)" aside, then at spaces, then truncated with ….
    static func captionLines(_ s: String, _ w: Int) -> [String] {
        if VFDText.width(s) <= w { return [s] }
        if s.contains(" (") && !s.contains(sep), let range = s.range(of: " (") {
            let head: String = String(s[s.startIndex..<range.lowerBound])
            let tail: String = String(s[range.upperBound...])
            if VFDText.width(head) <= w {
                return [head] + captionLines("(" + tail, w)
            }
        }
        var lines: [String] = []
        var cur: String = ""
        for part in splitString(s, sep) {
            let cand: String = cur.isEmpty ? part : cur + sep + part
            if !cur.isEmpty && VFDText.width(cand) > w {
                lines.append(cur)
                cur = part
            } else {
                cur = cand
            }
        }
        lines.append(cur)
        var out: [String] = []
        for ln in lines {
            if VFDText.width(ln) > w {
                out.append(contentsOf: VFDText.wrap(ln, w))
            } else {
                out.append(ln)
            }
        }
        var fitted: [String] = []
        for ln in dropDangling(out) {
            fitted.append(VFDText.fit(ln, w))
        }
        return fitted
    }

    /// agoText(ms) at the frame's time: 3s, 2m, 1h, 4d; empty for a time never set.
    static func agoText(_ ms: Int64, now: Double) -> String {
        if ms <= 0 { return "" }
        let unix: Double = now + Date.timeIntervalBetween1970AndReferenceDate
        let nowMs: Int64 = Int64(VFDMath.toInt(unix * 1000.0))
        let elapsedMs: Int64 = max(Int64(0), nowMs - ms)
        let seconds: Int64 = elapsedMs / 1000
        if seconds < 60 { return "\(seconds)s" }
        let minutes: Int64 = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours: Int64 = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days: Int64 = hours / 24
        return "\(days)d"
    }

    static func packetLabel(_ packet: LoggedPacket) -> String {
        if packet.label.isEmpty { return MagicClassifier.rawLabel(packet.hex) }
        return packet.label
    }

    /// "<time> · RSSI <n> · <category> · <source>" in at most maxCols cells: the short source is
    /// never cut; when the line is too long the category gives way first (truncated with …, or
    /// left out when fewer than 3 of its characters would show).
    static func packetSubtitle(_ packet: LoggedPacket, _ maxCols: Int) -> String {
        let date: Date = Date(timeIntervalSince1970: Double(packet.timestampMs) / 1000.0)
        let stamp: String = timeFormatter.string(from: date)
        let head: String = stamp + " · RSSI \(packet.rssi)"
        let src: String = shortAddress(packet.sourceAddress)
        let tail: String = src.isEmpty ? "" : " · " + src
        let category: String = packet.category
        let middle: String = category.isEmpty ? "" : " · " + category
        let full: String = head + middle + tail
        if VFDText.width(full) <= maxCols || category.isEmpty {
            return full
        }
        let headLen: Int = VFDText.length(head)
        let tailLen: Int = VFDText.length(tail)
        let room: Int = VFDText.maxChars(maxCols) - headLen - 3 - tailLen
        if room >= 3 {
            let cut: String = VFDText.fit(category, VFDText.width(count: room))
            return head + " · " + cut + tail
        }
        return head + tail
    }

    // MARK: pieces

    /// Rows of r ..< r + h (drawing coordinates) inside the current clip.
    static func clippedRows(_ fb: VFDFrameBuffer, _ r: Int, _ h: Int) -> Int {
        let clip = fb.clipRect
        let top: Int = max(r + fb.originY, clip.r)
        let bottom: Int = min(r + h + fb.originY, clip.r + clip.h)
        return max(0, bottom - top)
    }

    /// A tap at least tapRows tall, grown evenly around the visual (logs.py _tap).
    static func growTap(_ fb: VFDFrameBuffer, _ c: Int, _ r: Int, _ w: Int, _ h: Int, _ name: String,
                        action: (() -> Void)?) {
        var top: Int = r
        var height: Int = h
        if height < VFDW.tapRows {
            top -= VFDMath.floorDiv(VFDW.tapRows - height, 2)
            height = VFDW.tapRows
        }
        fb.tap(c, top, w, height, name: name, action: action)
    }

    /// logsCaption above a control: dim, wrapped. Returns the row for the control under it.
    static func caption(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int, _ s: String,
                        color: UInt8 = VFDInk.dim) -> Int {
        let top: Int = VFDW.groupTop(L, r)
        let lines: [String] = captionLines(s, w)
        var i: Int = 0
        for ln in lines {
            fb.text(c, top + i * VFDW.line, ln, .small, color)
            i += 1
        }
        let extra: Int = max(0, lines.count - 1) * VFDW.line
        return top + extra + VFDW.labelH
    }

    /// A caption line on its own (hint, "…and n more"): wrapped, line apart, the standard gap
    /// after it. Returns the next free row.
    static func noteLines(_ fb: VFDFrameBuffer, _ c: Int, _ r: Int, _ w: Int, _ s: String,
                          color: UInt8 = VFDInk.dim) -> Int {
        var y: Int = r + 2
        for ln in captionLines(s, w) {
            fb.text(c, y, ln, .small, color)
            y += VFDW.line
        }
        return y + VFDW.gap
    }

    /// LogsOutlineButton: highlight border with the label in `color`; alarm = a destructive one
    /// (alarm border and label, a solid block on a red-ish base); disabled = dim, no tap. Returns
    /// the column after it.
    static func outlineButton(_ fb: VFDFrameBuffer, _ x: Int, _ y: Int, _ w: Int, _ spec: VFDLogsButton) -> Int {
        let s: String = VFDText.fit(VFDW.upper(spec.label), w - 4)
        let tx: Int = VFDW.cx(x, w, s)
        let ty: Int = y + VFDW.ctrlText
        if !spec.enabled {
            fb.box(x, y, w, VFDW.ctrlH, VFDInk.dim)
            fb.text(tx, ty, s, .small, VFDInk.dim)
        } else if spec.color == VFDInk.alarm && fb.alarmInverted {
            fb.fill(x, y, w, VFDW.ctrlH, VFDInk.highlight)
            fb.text(tx, ty, s, .small, VFDInk.unlit)
        } else {
            let border: UInt8 = spec.color == VFDInk.alarm ? VFDInk.alarm : VFDInk.highlight
            fb.box(x, y, w, VFDW.ctrlH, border)
            fb.text(tx, ty, s, .small, spec.color)
        }
        if spec.enabled {
            growTap(fb, x, y, w, VFDW.ctrlH, "button:" + s, action: spec.action)
        }
        return x + w
    }

    /// An HStack of outline buttons, optGap apart; the expanding ones share what the fixed ones
    /// leave (the last one takes the spare cells). Returns the next free row.
    static func buttonRow(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int,
                          _ specs: [VFDLogsButton]) -> Int {
        let gap: Int = VFDW.optGap
        var fixed: [Int] = []
        var nExp: Int = 0
        var fixedSum: Int = 0
        for spec in specs {
            let fw: Int = VFDText.width(VFDW.upper(spec.label)) + 12
            fixed.append(fw)
            if spec.expand {
                nExp += 1
            } else {
                fixedSum += fw
            }
        }
        let spare: Int = w - gap * max(0, specs.count - 1) - fixedSum
        let each: Int = nExp > 0 ? VFDMath.floorDiv(spare, nExp) : 0
        var x: Int = c
        var seen: Int = 0
        var i: Int = 0
        for spec in specs {
            var bw: Int = fixed[i]
            if spec.expand {
                seen += 1
                bw = each
                if seen == nExp {
                    bw += spare - each * nExp
                }
            }
            x = outlineButton(fb, x, r, bw, spec) + gap
            i += 1
        }
        return r + VFDW.ctrlH + VFDW.gap
    }

    /// A Toggle whose label is too long for one line beside the switch: the label breaks before
    /// its "(…)" (else at spaces) onto two lines, the switch centred against them.
    static func wrappedToggle(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ r: Int, _ w: Int,
                              _ label: String, _ on: Bool, action: @escaping () -> Void) -> Int {
        let room: Int = w - VFDW.switchW - 6
        let s: String = VFDW.upper(label)
        if VFDText.width(s) <= room {
            return VFDW.toggle(fb, L, c, r, w, s, on, labelColor: VFDInk.dim, action: action)
        }
        var lines: [String] = []
        var split: Bool = false
        if let range = s.range(of: " (") {
            let head: String = String(s[s.startIndex..<range.lowerBound])
            if VFDText.width(head) <= room {
                let tail: String = String(s[s.index(after: range.lowerBound)...])
                lines = [head, tail]
                split = true
            }
        }
        if !split {
            lines = VFDText.wrap(s, room)
        }
        let y: Int = r + 3
        var i: Int = 0
        for ln in lines.prefix(2) {
            fb.text(c, y + i * VFDW.line, VFDText.fit(ln, room), .small, VFDInk.dim)
            i += 1
        }
        let name: String = "toggle:" + s
        VFDW.toggle(fb, L, c, y + 2, w, "", on, name: name, action: action)
        growTap(fb, c, r + 1, w, VFDW.line + 7 + 4, name, action: action)
        return y + VFDW.line + 7 + 3 + VFDW.gap
    }
}

// MARK: - System share sheet (sheet fallback)

/// The system share sheet for a log file, as LogsScreen's ShareLink offers it. When sharing
/// finishes or is cancelled it closes itself, so `onFinish` closes the VFD sheet around it.
private struct VFDLogsShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let items: [Any] = [url]
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let finish: () -> Void = onFinish
        controller.completionWithItemsHandler = { _, _, _, _ in
            finish()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
