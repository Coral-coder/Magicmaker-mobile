import SwiftUI
import UIKit

/// DIAG tab in the VFD theme: tools/vfd/screens/diag.py on the live engines.
///
/// STATUS (BLUETOOTH, SCAN, LOG, LOCATION | RX, LIGHTS, AUTO, TX-AUTO | RELAY, TX as DiagStatusBlock
/// reads them), the crash header (CRASH LOG · CLEAN, or HAS ENTRIES with SHARE and CLEAR; a tap
/// opens the newest 4000 characters in a box that scrolls on its own), BROADCAST SOURCES · n, then
/// the PRIORITY and OTHER sections (folding headers with counts) with one row per source from
/// scan.sources. CLEAR asks first; SHARE opens the system share sheet in a sheet.
@MainActor
enum VFDDiagScreen: VFDScreen {
    static let title: String = "DIAG"

    /// DiagStatusRow key column: 10 characters of small text.
    static let keyW: Int = 10 * 6
    /// Android shows the newest 4000 characters of the crash log.
    static let crashTail: Int = 4000
    /// Text lines the open crash box shows (220 pt).
    static let crashBoxLines: Int = 12
    static let crashRegion: String = "crash"
    /// Clause separators a wrapped status value prefers to break after.
    static let valueSeps: [String] = [" · ", " — "]
    static let valueLines: Int = 2
    static let sourceRowH: Int = 25
    // In-memory UI keys (DiagScreen's @State defaults).
    static let crashCollapsedKey: String = "crashCollapsed"
    static let priorityCollapsedKey: String = "priorityCollapsed"
    static let otherCollapsedKey: String = "otherCollapsed"

    static func headerRight(_ ctx: VFDContext) -> (text: String, action: () -> Void)? {
        return nil
    }

    /// DiagScreen reads the crash log each time it appears.
    static func onShow(_ ctx: VFDContext) {
        VFDDiagModel.shared.reload()
    }

    static func draw(_ ctx: VFDContext) -> Int? {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let ui: VFDUIState = ctx.ui
        let model: VFDDiagModel = VFDDiagModel.shared
        let c: Int = L.left
        let w: Int = L.width
        var y: Int = L.contentTop
        y = VFDDiagScreen.statusBlock(ctx, c, y, w)
        y = VFDDiagScreen.crashHeader(ctx, model, c, y + 2, w)
        let crashCollapsed: Bool = ui.bool(VFDDiagScreen.crashCollapsedKey, default: true)
        if !crashCollapsed && !model.crashBlank {
            y = VFDDiagScreen.crashBox(ctx, model, c, y, w)
        }
        let sources: [SourceStat] = ctx.scan.sources
        y = VFDDiagScreen.sourcesHeader(fb, c, y, w, sources.count)
        if sources.isEmpty {
            let msg: String = "NO SOURCES — START A SCAN"
            let x: Int = c + VFDMath.floorDiv(w - VFDText.width(msg), 2)
            fb.text(x, y + 40, msg, .small, VFDInk.dim)
            return y + 40 + 7 + 40
        }
        var priority: [SourceStat] = []
        var other: [SourceStat] = []
        for source in sources {
            if source.priority {
                priority.append(source)
            } else {
                other.append(source)
            }
        }
        let priorityCollapsed: Bool = ui.bool(VFDDiagScreen.priorityCollapsedKey, default: false)
        let otherCollapsed: Bool = ui.bool(VFDDiagScreen.otherCollapsedKey, default: true)
        y = VFDDiagScreen.sourceSection(ctx, c, y - 4, w, "PRIORITY", priority, collapsed: priorityCollapsed,
                                        key: VFDDiagScreen.priorityCollapsedKey, fallback: false)
        y = VFDDiagScreen.sourceSection(ctx, c, y, w, "OTHER", other, collapsed: otherCollapsed,
                                        key: VFDDiagScreen.otherCollapsedKey, fallback: true)
        return y
    }

    // MARK: - Status block

    /// The rows of DiagStatusBlock: (key, value, ink, middle-truncated).
    fileprivate static func statusRows(_ ctx: VFDContext) -> [VFDDiagStatus] {
        let scan: ScanEngine = ctx.scan
        let vm: AppViewModel = ctx.vm
        let tx: TxEngine = ctx.tx
        let location: LocationTracker = vm.location
        let btReady: Bool = scan.bluetoothStatus == "Bluetooth ready"
        let txStatus: String = tx.status
        let txBad: Bool = txStatus == TxEngine.notLinkedStatus || txStatus == TxEngine.sendFailedStatus
        let linked: Bool = vm.remoteLinkReady
        let relayState: String = linked ? "LINKED" : "NOT LINKED"
        let relay: String = vm.relayBackend.label.uppercased() + " · " + relayState
        var rows: [VFDDiagStatus] = []
        rows.append(VFDDiagStatus(key: "BLUETOOTH", value: scan.bluetoothStatus.uppercased(),
                                  color: btReady ? VFDInk.text : VFDInk.alarm, middle: false))
        rows.append(VFDDiagStatus(key: "SCAN", value: scan.scanActive ? "ON" : "OFF",
                                  color: onOffColor(scan.scanActive), middle: false))
        rows.append(VFDDiagStatus(key: "LOG", value: logText(ctx),
                                  color: onOffColor(scan.recordSessionActive), middle: true))
        rows.append(VFDDiagStatus(key: "LOCATION", value: location.authorizationDescription.uppercased(),
                                  color: location.isAuthorized ? VFDInk.text : VFDInk.alarm, middle: false))
        rows.append(VFDDiagStatus(key: "RX", value: "\(scan.packetsHeard)", color: VFDInk.text, middle: false))
        rows.append(VFDDiagStatus(key: "LIGHTS", value: "\(scan.lightsHeard)", color: VFDInk.text, middle: false))
        rows.append(VFDDiagStatus(key: "AUTO", value: scan.autoEnabled ? "ARM" : "OFF",
                                  color: onOffColor(scan.autoEnabled), middle: false))
        rows.append(VFDDiagStatus(key: "TX-AUTO", value: "\(scan.autoResponsesSent)", color: VFDInk.text,
                                  middle: false))
        rows.append(VFDDiagStatus(key: "RELAY", value: relay, color: linked ? VFDInk.highlight : VFDInk.alarm,
                                  middle: false))
        rows.append(VFDDiagStatus(key: "TX", value: txStatus.uppercased(), color: txBad ? VFDInk.alarm : VFDInk.text,
                                  middle: false))
        return rows
    }

    /// onOffColor: cyan (highlight) when on, dim when off.
    fileprivate static func onOffColor(_ on: Bool) -> UInt8 {
        return on ? VFDInk.highlight : VFDInk.dim
    }

    /// The file really open; ScanEngine's name can be an old sidecar after a relaunch.
    fileprivate static func logText(_ ctx: VFDContext) -> String {
        if !ctx.scan.recordSessionActive { return "OFF" }
        let name: String = ctx.store.activeSessionName ?? ""
        if name.isEmpty { return "REC" }
        return "REC · " + name
    }

    fileprivate static func statusBlock(_ ctx: VFDContext, _ c: Int, _ top: Int, _ w: Int) -> Int {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        var y: Int = VFDW.section(fb, L, c, top, w, "STATUS")
        for row in VFDDiagScreen.statusRows(ctx) {
            y = VFDDiagScreen.statusRow(fb, c, y, w, row)
        }
        return y
    }

    /// DiagStatusRow: the key in dim in a fixed column, the value after it, middle-truncated on
    /// one line (the LOG file name) or wrapped to at most valueLines lines. Returns the row after
    /// the last line.
    fileprivate static func statusRow(_ fb: VFDFrameBuffer, _ c: Int, _ top: Int, _ w: Int,
                                      _ row: VFDDiagStatus) -> Int {
        var y: Int = top
        let keyW: Int = VFDDiagScreen.keyW
        fb.textFit(c, y, row.key, keyW - 6, .small, VFDInk.dim)
        let vx: Int = c + keyW
        let alarm: Bool = row.color == VFDInk.alarm
        let vw: Int = c + w - vx - (alarm ? 4 : 0)
        var lines: [String] = []
        if row.middle {
            lines = [VFDDiagScreen.fitMiddle(row.value, vw)]
        } else {
            lines = VFDDiagScreen.wrapValue(row.value, vw)
        }
        for ln in lines {
            if alarm && fb.alarmInverted {
                // 10 rows, so alarm lines one line apart keep a 1-row gap.
                fb.fill(vx, y - 1, VFDText.width(ln) + 4, 10, VFDInk.highlight)
                fb.text(vx + 2, y, ln, .small, VFDInk.unlit)
            } else if alarm {
                VFDW.alarmText(fb, vx, y, ln)
            } else {
                fb.text(vx, y, ln, .small, row.color)
            }
            y += VFDW.line
        }
        return y
    }

    /// s unchanged if it fits in maxCols cells, else its head and tail around "…"
    /// (.truncationMode(.middle)); the head gets the odd character.
    fileprivate static func fitMiddle(_ s: String, _ maxCols: Int) -> String {
        let n: Int = VFDText.maxChars(maxCols)
        let a: [Unicode.Scalar] = VFDText.scalars(s)
        if a.count <= n { return s }
        if n < 3 { return VFDText.fit(s, maxCols) }
        let keep: Int = n - 1
        let head: Int = VFDMath.floorDiv(keep + 1, 2)
        let tail: Int = keep - head
        let first: [Unicode.Scalar] = VFDText.rstrip(Array(a[0..<head]))
        var last: [Unicode.Scalar] = Array(a[(a.count - tail)...])
        while let u = last.first, VFDText.isSpace(u) {
            last.removeFirst()
        }
        return VFDText.string(first) + VFDText.ellipsis + VFDText.string(last)
    }

    /// Lines of a status value in a column maxCols cells wide: [s] if it fits; else one break
    /// right after a " · " / " — " separator when both halves fit (the separator ends the first
    /// line); else a word wrap, the lines past valueLines joined onto the last one and cut with ….
    fileprivate static func wrapValue(_ s: String, _ maxCols: Int) -> [String] {
        let n: Int = VFDText.maxChars(maxCols)
        let a: [Unicode.Scalar] = VFDText.scalars(s)
        if a.count <= n { return [s] }
        var bestHead: [Unicode.Scalar] = []
        var bestTail: [Unicode.Scalar] = []
        var found: Bool = false
        let space: Unicode.Scalar = " "
        for sep in VFDDiagScreen.valueSeps {
            let sepS: [Unicode.Scalar] = VFDText.scalars(sep)
            let m: Int = sepS.count
            var i: Int = 0
            while i + m <= a.count {
                if Array(a[i..<(i + m)]) == sepS {
                    var head: [Unicode.Scalar] = Array(a[0..<i])
                    head.append(space)
                    head.append(contentsOf: VFDText.scalars(VFDText.strip(sep)))
                    let tail: [Unicode.Scalar] = VFDText.scalars(VFDText.strip(VFDText.string(Array(a[(i + m)...]))))
                    if head.count <= n && tail.count <= n && (!found || head.count > bestHead.count) {
                        bestHead = head
                        bestTail = tail
                        found = true
                    }
                }
                i += 1
            }
        }
        if found && VFDDiagScreen.valueLines >= 2 {
            return [VFDText.string(bestHead), VFDText.string(bestTail)]
        }
        var lines: [String] = VFDText.wrap(s, maxCols)
        let most: Int = VFDDiagScreen.valueLines
        if lines.count > most {
            let rest: String = lines[(most - 1)...].joined(separator: " ")
            var kept: [String] = Array(lines[0..<(most - 1)])
            kept.append(VFDText.fit(rest, maxCols))
            lines = kept
        }
        return lines
    }

    // MARK: - Crash log

    /// CRASH LOG · CLEAN / HAS ENTRIES (a tap opens and closes the log box), SHARE and CLEAR
    /// right-aligned when the log has entries (under the label when they do not fit beside it).
    fileprivate static func crashHeader(_ ctx: VFDContext, _ model: VFDDiagModel, _ c: Int, _ y: Int,
                                        _ w: Int) -> Int {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let blank: Bool = model.crashBlank
        let label: String = blank ? "CRASH LOG · CLEAN" : "CRASH LOG · HAS ENTRIES"
        let ty: Int = y + VFDW.ctrlText
        let toggle: () -> Void = {
            VFDDiagScreen.toggleCrashLog(ctx)
        }
        if blank {
            fb.textFit(c, ty, label, w, .small, VFDInk.dim)
            VFDW.tap(fb, c, y, w, VFDW.ctrlH, "crashlog", action: toggle)
            return y + VFDW.ctrlH + VFDW.gap
        }
        let shareURL: URL? = CrashLog.fileURL
        var acts: [String] = []
        if shareURL != nil {
            acts.append("SHARE")
        }
        acts.append("CLEAR")
        var widths: [Int] = []
        var group: Int = 0
        let gap: Int = 4
        for a in acts {
            let bw: Int = VFDText.width(a) + 12
            widths.append(bw)
            group += bw
        }
        group += gap * (acts.count - 1)
        let labelW: Int = VFDText.width(label) + (fb.alarmInverted ? 4 : 0)
        let oneRow: Bool = labelW + 6 + group <= w
        let by: Int = oneRow ? y : y + VFDW.ctrlH + VFDW.gap
        var x: Int = c + w - group
        var i: Int = 0
        for a in acts {
            let bw: Int = widths[i]
            if a == "CLEAR" {
                VFDW.button(fb, L, x, by, bw, a, alarm: true, action: {
                    VFDDiagScreen.askClearCrashLog(ctx)
                })
            } else if let url = shareURL {
                VFDW.button(fb, L, x, by, bw, a, action: {
                    VFDDiagScreen.share(ctx, url)
                })
            }
            x += bw + gap
            i += 1
        }
        let lw: Int = oneRow ? (w - group - 6) : w
        let shown: String = VFDText.fit(label, lw - 4)
        VFDW.alarmText(fb, c, ty, shown)
        VFDW.tap(fb, c, y, lw, VFDW.ctrlH, "crashlog", action: toggle)
        return by + VFDW.ctrlH + VFDW.gap
    }

    /// The tail as box lines: the newest crashTail characters, leading newlines dropped, every
    /// paragraph wrapped (an empty one kept as an empty line).
    fileprivate static func wrapCrashLog(_ log: String, _ iw: Int) -> [String] {
        let tail: [Unicode.Scalar] = VFDText.scalars(String(log.suffix(VFDDiagScreen.crashTail)))
        var start: Int = 0
        var end: Int = tail.count
        while start < end && tail[start] == "\n" {
            start += 1
        }
        while end > start && tail[end - 1] == "\n" {
            end -= 1
        }
        let body: [Unicode.Scalar] = Array(tail[start..<end])
        var lines: [String] = []
        let newline: [Unicode.Scalar] = ["\n"]
        for para in VFDText.split(body, newline) {
            let wrapped: [String] = VFDText.wrap(VFDText.string(para), iw)
            if wrapped.isEmpty {
                lines.append("")
            } else {
                lines.append(contentsOf: wrapped)
            }
        }
        return lines
    }

    /// The open crash log: a dim box crashBoxLines lines tall with the tail wrapped in dim. When the
    /// tail is longer, the box scrolls on its own by whole lines and a highlight thumb on its right
    /// border shows where.
    fileprivate static func crashBox(_ ctx: VFDContext, _ model: VFDDiagModel, _ c: Int, _ y: Int, _ w: Int) -> Int {
        let fb: VFDFrameBuffer = ctx.fb
        let iw: Int = w - 6
        let lines: [String] = VFDDiagScreen.wrapCrashLog(model.crashLog, iw)
        let shownLines: Int = VFDDiagScreen.crashBoxLines
        let h: Int = shownLines * VFDW.line + 3
        fb.box(c, y, w, h, VFDInk.dim)
        let maxFirst: Int = max(0, lines.count - shownLines)
        var first: Int = 0
        if maxFirst > 0 {
            let limit: Int = maxFirst * VFDW.line
            let s: Int = ctx.scroll(VFDDiagScreen.crashRegion, limit: limit)
            first = min(maxFirst, VFDMath.floorDiv(s + VFDMath.floorDiv(VFDW.line, 2), VFDW.line))
            // The renderer's drag limit is contentRows minus the region's clipped height.
            let shown: Int = VFDDiagScreen.clippedRows(fb, y, h)
            fb.scrollRegion(id: VFDDiagScreen.crashRegion, c, y, w, h, contentRows: limit + shown)
        }
        var i: Int = 0
        while i < shownLines && first + i < lines.count {
            fb.text(c + 3, y + 3 + i * VFDW.line, lines[first + i], .small, VFDInk.dim)
            i += 1
        }
        if lines.count > shownLines {
            let top: Int = y + 2
            let th: Int = h - 4
            let thumb: Int = max(6, VFDMath.floorDiv(th * shownLines, lines.count))
            let ty: Int = top + VFDMath.floorDiv((th - thumb) * first, max(1, maxFirst))
            fb.vline(c + w - 1, ty, thumb, VFDInk.highlight)
        }
        return y + h + VFDW.gap
    }

    /// Rows of r ..< r + h (drawing coordinates) inside the current clip.
    fileprivate static func clippedRows(_ fb: VFDFrameBuffer, _ r: Int, _ h: Int) -> Int {
        let clip = fb.clipRect
        let top: Int = max(r + fb.originY, clip.r)
        let bottom: Int = min(r + h + fb.originY, clip.r + clip.h)
        return max(0, bottom - top)
    }

    // MARK: - Sources

    /// Divider, BROADCAST SOURCES · n with the rows' unit RSSI DBM right-aligned, PRIORITY = SENT
    /// SHOW/ANIM/COLOR, divider.
    fileprivate static func sourcesHeader(_ fb: VFDFrameBuffer, _ c: Int, _ top: Int, _ w: Int, _ count: Int) -> Int {
        var y: Int = top + VFDW.sectionGap - VFDW.gap
        fb.hline(c, y, w, VFDInk.dim)
        y += 4
        let unitX: Int = fb.textRight(c + w - 1, y, "RSSI DBM", .small, VFDInk.dim)
        fb.textFit(c, y, "BROADCAST SOURCES · \(count)", unitX - 6 - c, .small, VFDInk.highlight)
        y += VFDW.line
        fb.textFit(c, y, "PRIORITY = SENT SHOW/ANIM/COLOR", w, .small, VFDInk.dim)
        y += 7 + 3
        fb.hline(c, y, w, VFDInk.dim)
        return y + 1 + VFDW.gap
    }

    /// A folding section header with its count, then (open) one row per source. Only the rows that
    /// reach the visible part of the buffer are drawn.
    fileprivate static func sourceSection(_ ctx: VFDContext, _ c: Int, _ top: Int, _ w: Int, _ title: String,
                                          _ rows: [SourceStat], collapsed: Bool, key: String,
                                          fallback: Bool) -> Int {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let ui: VFDUIState = ctx.ui
        var y: Int = VFDW.section(fb, L, c, top, w, title, count: rows.count, collapsed: collapsed, action: {
            ui.toggleBool(key, default: fallback)
        })
        if collapsed {
            return y
        }
        y -= VFDW.gap + 1
        let clip = fb.clipRect
        let visTop: Int = clip.r - fb.originY - 2
        let visBottom: Int = clip.r + clip.h - fb.originY + 2
        let rowH: Int = VFDDiagScreen.sourceRowH
        for source in rows {
            if y + rowH > visTop && y < visBottom {
                y = VFDDiagScreen.sourceRow(fb, c, y, w, source)
            } else {
                y += rowH
            }
        }
        return y + VFDW.gap
    }

    /// DiagSourceRow: the address (highlight for a priority source, else dim) with BEST n · NOW n
    /// right-aligned in dim, "n PKTS · categories" in dim, a dotted divider.
    fileprivate static func sourceRow(_ fb: VFDFrameBuffer, _ c: Int, _ r: Int, _ w: Int, _ source: SourceStat) -> Int {
        var y: Int = r + 3
        let rssi: String = "BEST \(source.bestRssi) · NOW \(source.lastRssi)"
        let rt: String = VFDText.fit(rssi, VFDMath.floorDiv(w * 2, 3))
        let start: Int = c + w - VFDText.width(rt)
        fb.text(start, y, rt, .small, VFDInk.dim)
        let tail: String = shortAddress(source.address)
        let address: String = tail.isEmpty ? "(unknown)" : tail
        let color: UInt8 = source.priority ? VFDInk.highlight : VFDInk.dim
        fb.textFit(c + 2, y, address, start - 6 - (c + 2), .small, color)
        y += VFDW.line
        let counts: String = "\(source.count) PKTS · " + source.categories.joined(separator: " ")
        fb.textFit(c + 2, y, counts, w - 2, .small, VFDInk.dim)
        y += 7 + 3
        fb.hline(c, y, w, VFDInk.dim, step: 2)
        return y + 1
    }

    // MARK: - Actions (DiagScreen's)

    /// Opening the log reads it again, so an entry written since the tab appeared shows up.
    fileprivate static func toggleCrashLog(_ ctx: VFDContext) {
        let ui: VFDUIState = ctx.ui
        let collapsed: Bool = ui.bool(VFDDiagScreen.crashCollapsedKey, default: true)
        if collapsed {
            VFDDiagModel.shared.reload()
            ctx.setScroll(VFDDiagScreen.crashRegion, 0)
        }
        ui.setBool(VFDDiagScreen.crashCollapsedKey, !collapsed)
    }

    fileprivate static func askClearCrashLog(_ ctx: VFDContext) {
        ctx.confirm(title: "Clear crash log?", message: CrashLog.fileName.uppercased(), confirmLabel: "CLEAR",
                    destructive: true, action: {
                        CrashLog.clear()
                        VFDDiagModel.shared.reload()
                    })
    }

    /// ShareLink(item: CrashLog.fileURL): the system share sheet.
    fileprivate static func share(_ ctx: VFDContext, _ url: URL) {
        let finish: () -> Void = {
            ctx.dismissSheet()
        }
        let sheet: VFDDiagShareSheet = VFDDiagShareSheet(url: url, onFinish: finish)
        ctx.sheet(id: "diag.share") {
            sheet
        }
    }
}

/// One "KEY  value" line of the status block.
private struct VFDDiagStatus {
    let key: String
    let value: String
    let color: UInt8
    /// The LOG file name keeps the standard row's middle truncation.
    let middle: Bool
}

/// The crash log as DiagScreen holds it: read each time the tab is shown (onShow; DiagScreen
/// reads it on appear), when the box is opened and after CLEAR. The file is small and read on the
/// main thread, as DiagScreen does. Drawing only reads `crashLog`.
@MainActor
private final class VFDDiagModel {
    static let shared: VFDDiagModel = VFDDiagModel()

    private(set) var crashLog: String

    /// Read once when the model is first used, so a first frame drawn before the first onShow
    /// (the VFD view opening on DIAG) already shows the file as it is.
    init() {
        crashLog = CrashLog.read()
    }

    /// Kotlin's isBlank.
    var crashBlank: Bool {
        return crashLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func reload() {
        crashLog = CrashLog.read()
    }
}

// MARK: - System share sheet (sheet fallback)

/// The system share sheet for the crash log file. When sharing finishes or is cancelled it closes
/// itself, so `onFinish` closes the VFD sheet around it.
private struct VFDDiagShareSheet: UIViewControllerRepresentable {
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
