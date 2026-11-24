import SwiftUI

/// LINK tab in the VFD theme, laid out like tools/vfd/screens/link.py: RELAY / LINK (the link
/// state dot and label, the BACKEND selectors, the backend note or, for WiFi, SCAN ANDROID QR and
/// the Android IP field, the IPHONE / HINT / STATUS / EVENT / LIB SYNC / LIB / ANDROID / STORE /
/// GATT rows, REFRESH and RETRY BLE, IMPORT ANDROID LIBRARY with its caption, the pocket note),
/// then, unless the backend is the ESP32, the ANDROID SCAN / RX panel (PAUSE/SCAN, LOG/LOG OFF,
/// CLR, VIB, GROUPED / RAW, CLASS n/8, AUTO-RESPONSE, the gesture hint), BUF / HEARD / LAST / LOG,
/// LIVE RX and the relay's feed (collapsible GROUPED sections or every RAW advert; LISTEN 0x0183
/// MANUFACTURER when empty). Every control calls what LinkScreen calls on AppViewModel / TxEngine.
/// Feed rows: tap = transmit, swipe left = remove (asks first), swipe right = the "Packet action"
/// menu (ADD TO TX / LOAD LAB), hold = a menu with all of these. The CLASS filter and the packet
/// action alert are VFD menus; the IP field is a text prompt; the QR scanner (camera) opens
/// PairingQRScannerView in a sheet.
@MainActor
enum VFDLinkScreen: VFDScreen {
    static let title: String = "LINK"

    static func headerRight(_ ctx: VFDContext) -> (text: String, action: () -> Void)? {
        return nil
    }

    static func draw(_ ctx: VFDContext) -> Int? {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let c: Int = L.left
        let w: Int = L.width
        var y: Int = L.contentTop
        y = relayPanel(ctx, fb, L, c, y, w)
        // The ESP32 is only a radio: it has no scanner of its own to show or control.
        if ctx.vm.relayBackend != .esp32 {
            y = remoteSection(ctx, fb, L, c, y + 7, w)
        }
        return y
    }
}

// MARK: - Keys and snapshots

/// This tab's in-memory UI keys (LinkScreen's @State) and its fixed texts.
private enum VFDLinkKeys {
    static let tab: String = "link"
    static let viewMode: String = "link.viewMode"
    /// LivePacketSection raw values the CLASS filter hides.
    static let hiddenSections: String = "link.hiddenSections"
    /// Folded section titles ("WAND", ...).
    static let collapsed: String = "link.collapsed"
    /// What the last IMPORT ANDROID LIBRARY did; empty until it is tapped.
    static let importResult: String = "link.importResult"

    static let hint: String = "TAP REPLAY · SWIPE ← DEL · SWIPE → TX/TAG"
    static let pocketNote: String = "Control Android from your pocket: BLE when close, WiFi hotspot + QR when Android is in your backpack."
    static let esp32Note: String = "Power on the MagicMaker ESP32. iPhone auto-connects and transmits through it while you keep scanning. No pairing needed."
    static let bleNote: String = "Put Android in BLE GATT / iPhone mode. iPhone auto-connects to the Android relay."
    static let importCaption: String = "ADDS THE ANDROID PACKETS THE IPHONE LIBRARY DOES NOT HAVE YET"
    static let listen: String = "LISTEN 0x0183 MANUFACTURER"
    static let ipLabel: String = "Android IP (hotspot gateway)"

    /// LinkInfoRow key column: 10 character cells.
    static let keyCols: Int = 60
    /// LinkInfoRow value lineLimit.
    static let valueLines: Int = 3
}

/// The link colour dot: cyan (linked), amber (linking), error (down).
private enum VFDLinkDot {
    case ok
    case wait
    case down
}

/// One section of the relay's grouped feed.
private struct VFDLinkGroup {
    let section: LivePacketSection
    let packets: [AndroidRemotePacket]
}

/// The relay's feed as one draw reads it.
private struct VFDLinkFeed {
    let raw: Bool
    /// RAW: every advert the CLASS filter keeps, newest first.
    let rawRows: [AndroidRemotePacket]
    /// GROUPED: the unique feed the CLASS filter keeps, by section.
    let groups: [VFDLinkGroup]
    let collapsed: Set<String>
    /// Sections the CLASS filter shows.
    let shownSections: Int
    let bufferText: String

    var isEmpty: Bool {
        return raw ? rawRows.isEmpty : groups.isEmpty
    }
}

@MainActor
extension VFDLinkScreen {
    // MARK: state

    private static func linkUI(_ ctx: VFDContext) -> VFDUIState {
        return ctx.uiState(for: VFDLinkKeys.tab)
    }

    private static func isVisible(_ pkt: AndroidRemotePacket, _ hidden: Set<String>) -> Bool {
        let section: LivePacketSection = LivePacketSort.section(of: pkt, typeInfo: pkt.typeInfo)
        return !hidden.contains(section.rawValue)
    }

    private static func feed(_ ctx: VFDContext) -> VFDLinkFeed {
        let vm: AppViewModel = ctx.vm
        let ui: VFDUIState = linkUI(ctx)
        let hidden: Set<String> = ui.strings(VFDLinkKeys.hiddenSections)
        let raw: Bool = ui.string(VFDLinkKeys.viewMode, default: "GROUPED") == "RAW"
        var shown: Int = 0
        for section in LivePacketSection.allCases where !hidden.contains(section.rawValue) {
            shown += 1
        }
        var rawRows: [AndroidRemotePacket] = []
        var groups: [VFDLinkGroup] = []
        var bufferText: String = ""
        if raw {
            let all: [AndroidRemotePacket] = vm.androidLivePackets
            for pkt in all where isVisible(pkt, hidden) {
                rawRows.append(pkt)
            }
            bufferText = "RAW " + String(all.count)
        } else {
            let unique: [AndroidRemotePacket] = vm.androidUniqueLivePackets
            var visible: [AndroidRemotePacket] = []
            for pkt in unique where isVisible(pkt, hidden) {
                visible.append(pkt)
            }
            let grouped: [(LivePacketSection, [AndroidRemotePacket])] = LivePacketSort.groupedLive(visible)
            for entry in grouped {
                groups.append(VFDLinkGroup(section: entry.0, packets: entry.1))
            }
            bufferText = "UNIQUE " + String(unique.count)
        }
        return VFDLinkFeed(raw: raw, rawRows: rawRows, groups: groups,
                           collapsed: ui.strings(VFDLinkKeys.collapsed), shownSections: shown,
                           bufferText: bufferText)
    }

    /// LinkRelayPanel.linkLabel / linkColor.
    private static func linkState(_ vm: AppViewModel) -> (label: String, dot: VFDLinkDot) {
        let gatt: Bool = vm.relayGattReady
        let linked: Bool = vm.androidRemote?.relayLinked == true
        switch vm.relayBackend {
        case .esp32:
            let label: String = gatt ? "ESP32 READY" : "ESP32 SEARCHING"
            if vm.relayCommandReady { return (label: label, dot: .ok) }
            if gatt { return (label: label, dot: .wait) }
            return (label: label, dot: .down)
        case .androidBle:
            if gatt && linked { return (label: "GATT LINKED", dot: .ok) }
            if gatt { return (label: "GATT READY", dot: .wait) }
            return (label: "GATT SEARCHING", dot: .down)
        case .androidWifi:
            let ready: Bool = vm.remoteLinkReady
            if ready { return (label: "WIFI LINKED", dot: .ok) }
            return (label: "WIFI NOT CONNECTED", dot: .wait)
        }
    }

    /// A synced (or cached) Android catalog with something in it.
    private static func catalogAvailable(_ vm: AppViewModel) -> Bool {
        guard let cat = vm.androidCatalog else { return false }
        return !cat.transmitPresets.isEmpty || !cat.wandColors.isEmpty
    }

    private static func rowSubtitle(_ pkt: AndroidRemotePacket) -> String {
        if pkt.note.isEmpty {
            return "RSSI " + String(pkt.rssi)
        }
        return pkt.note
    }

    // MARK: small helpers

    /// Content rows [top, bottom) the current clip shows (rows outside it need no drawing).
    private static func visibleRows(_ fb: VFDFrameBuffer) -> (top: Int, bottom: Int) {
        let clip: (c: Int, r: Int, w: Int, h: Int) = fb.clipRect
        let oy: Int = fb.originY
        return (top: clip.r - oy, bottom: clip.r + clip.h - oy)
    }

    /// The first `count` characters of a.
    private static func head(_ a: [Unicode.Scalar], _ count: Int) -> String {
        let n: Int = max(0, min(count, a.count))
        return VFDText.string(Array(a[0..<n]))
    }

    /// Word-wrap s into at most `lines` lines of maxCols cells: words longer than a line are
    /// broken and text past the last line is cut with …. A trailing '…' that wraps onto a line of
    /// its own stays there; only when that line would fall past the last one is it pulled up,
    /// replacing the last character of the line before (link.py wrap_value).
    private static func wrapValue(_ s: String, _ maxCols: Int, lines: Int) -> [String] {
        var out: [String] = VFDText.wrap(s, maxCols)
        let n: Int = VFDText.maxChars(maxCols)
        if out.count > lines && out.count > 1 && out[out.count - 1] == VFDText.ellipsis {
            out.removeLast()
            let prev: [Unicode.Scalar] = VFDText.scalars(out[out.count - 1])
            out[out.count - 1] = head(prev, n - 1) + VFDText.ellipsis
        }
        if out.count > lines && lines > 0 {
            let last: String = out[lines - 1]
            var tail: String = ""
            if VFDText.length(last) + 2 <= n {
                tail = VFDText.fit(last + " " + VFDText.ellipsis, maxCols)
            } else {
                tail = head(VFDText.scalars(last), n - 1) + VFDText.ellipsis
            }
            var kept: [String] = Array(out[0..<(lines - 1)])
            kept.append(tail)
            out = kept
        }
        return out
    }

    /// LinkInfoRow: the key (dim) in a keyCols-wide column, the value uppercased (colour as given;
    /// ALARM via alarmText) wrapped beside it, up to 3 lines. Returns the next free row.
    @discardableResult
    private static func infoRow(_ fb: VFDFrameBuffer, _ c: Int, _ y: Int, _ w: Int, _ key: String, _ value: String,
                                color: UInt8 = VFDInk.text) -> Int {
        fb.textFit(c, y, key, VFDLinkKeys.keyCols - 6, .small, VFDInk.dim)
        let vx: Int = c + VFDLinkKeys.keyCols
        let vw: Int = w - VFDLinkKeys.keyCols
        let lines: [String] = wrapValue(VFDW.upper(value), vw, lines: VFDLinkKeys.valueLines)
        let shown: [String] = lines.isEmpty ? [""] : lines
        var i: Int = 0
        for ln in shown {
            let r: Int = y + i * VFDW.line
            if color == VFDInk.alarm {
                VFDW.alarmText(fb, vx, r, ln)
            } else {
                fb.text(vx, r, ln, .small, color)
            }
            i += 1
        }
        return y + max(1, lines.count) * VFDW.line
    }

    /// The gesture hint, wrapped only at its " · " separators. Returns the row after the last line.
    private static func hintLines(_ fb: VFDFrameBuffer, _ c: Int, _ y0: Int, _ w: Int, _ s: String) -> Int {
        var y: Int = y0
        for ln in VFDW.tokenLines(s, w, sep: " · ") {
            fb.text(c, y, ln, .small, VFDInk.dim)
            y += VFDW.line
        }
        return y
    }

    /// noteText: wrapped small dim text, drawn as given.
    private static func note(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ y: Int, _ w: Int, _ s: String) -> Int {
        return VFDW.textBlock(fb, L, c, y, w, s, color: VFDInk.dim)
    }

    private static func dotCell(_ i: Int, _ j: Int) -> Bool {
        let rows: [String] = ["..###..", ".#####.", "#######", "#######", "#######", ".#####.", "..###.."]
        if j < 0 || j >= rows.count { return false }
        let line: [Unicode.Scalar] = Array(rows[j].unicodeScalars)
        if i < 0 || i >= line.count { return false }
        return line[i] == "#"
    }

    /// The link colour dot as a 7 x 7 pixel LED on caps row y: ok = solid highlight, wait = a
    /// hollow highlight ring, down = solid alarm (on a red-ish base a 9 x 9 highlight block with
    /// the dot cut out).
    private static func statusDot(_ fb: VFDFrameBuffer, _ x: Int, _ y: Int, _ state: VFDLinkDot) {
        if state == .down && fb.alarmInverted {
            fb.fill(x - 1, y - 1, 9, 9, VFDInk.highlight)
        }
        for j in 0..<7 {
            for i in 0..<7 {
                if !dotCell(i, j) { continue }
                let inRange: Bool = i >= 1 && i <= 5 && j >= 1 && j <= 5
                let vertical: Bool = dotCell(i, j - 1) && dotCell(i, j + 1)
                let horizontal: Bool = dotCell(i - 1, j) && dotCell(i + 1, j)
                let inner: Bool = inRange && vertical && horizontal
                switch state {
                case .ok:
                    fb.set(x + i, y + j, VFDInk.highlight)
                case .wait:
                    if !inner {
                        fb.set(x + i, y + j, VFDInk.highlight)
                    }
                case .down:
                    fb.set(x + i, y + j, fb.alarmInverted ? VFDInk.unlit : VFDInk.alarm)
                }
            }
        }
    }

    // MARK: relay panel

    /// LinkRelayPanel, in the app's order. Returns the next free row.
    private static func relayPanel(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ top: Int,
                                   _ w: Int) -> Int {
        let vm: AppViewModel = ctx.vm
        var y: Int = VFDW.section(fb, L, c, top, w, "RELAY / LINK")
        y = linkStateLine(ctx, fb, c, y, w)
        let backends: [RelayBackend] = RelayBackend.allCases
        var labels: [String] = []
        var selected: Int = 0
        var i: Int = 0
        for backend in backends {
            labels.append(backend.label)
            if backend == vm.relayBackend {
                selected = i
            }
            i += 1
        }
        y = VFDW.options(fb, L, c, y, w, labels, selected: selected, label: "Backend",
                         onSelect: { (index: Int) -> Void in
                             if index < 0 || index >= backends.count { return }
                             let picked: RelayBackend = backends[index]
                             if picked != vm.relayBackend {
                                 vm.setRelayBackend(picked)
                             }
                         })
        y = backendDetail(ctx, fb, L, c, y, w)
        y = statusRows(ctx, fb, c, y + 2, w)
        var actionLabels: [String] = ["Refresh"]
        if vm.relayBackend.usesBleRelayLink {
            actionLabels.append("Retry BLE")
        }
        y = VFDW.buttons(fb, L, c, y + 4, w, actionLabels, equal: false, onSelect: { (index: Int) -> Void in
            if index == 0 {
                vm.refreshAndroidRemote()
                vm.refreshAndroidCatalog(force: true)
                vm.refreshRelayStatus()
            } else {
                vm.reconnectRelay()
            }
        })
        if catalogAvailable(vm) {
            y = VFDW.button(fb, L, c, y + 4, nil, "Import Android library", primary: true, action: {
                VFDLinkScreen.runImport(ctx)
            })
            let result: String = linkUI(ctx).string(VFDLinkKeys.importResult, default: "")
            let caption: String = result.isEmpty ? VFDLinkKeys.importCaption : result
            let color: UInt8 = result.isEmpty ? VFDInk.dim : VFDInk.highlight
            for ln in wrapValue(caption, w, lines: 2) {
                fb.text(c, y + 1, ln, .small, color)
                y += VFDW.line
            }
            y += VFDW.gap
        }
        return note(fb, L, c, y + 4, w, VFDLinkKeys.pocketNote)
    }

    /// The dot and the link label (text). Returns the next free row.
    private static func linkStateLine(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ c: Int, _ y: Int, _ w: Int) -> Int {
        let state: (label: String, dot: VFDLinkDot) = linkState(ctx.vm)
        let r: Int = y + 1
        statusDot(fb, c, r, state.dot)
        fb.textFit(c + 7 + 5, r, state.label, w - 12, .small, VFDInk.text)
        return r + VFDW.line + 1
    }

    /// WiFi: SCAN ANDROID QR (primary) and the Android IP field; otherwise the backend note.
    private static func backendDetail(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ y: Int,
                                      _ w: Int) -> Int {
        let vm: AppViewModel = ctx.vm
        switch vm.relayBackend {
        case .androidWifi:
            let next: Int = VFDW.button(fb, L, c, y + 4, nil, "Scan Android QR", primary: true, action: {
                VFDLinkScreen.openScanner(ctx)
            })
            return VFDW.field(fb, L, c, next, w, VFDLinkKeys.ipLabel, vm.androidRelayIP,
                              placeholder: VFDLinkKeys.ipLabel, name: "field:ANDROID IP", action: {
                                  VFDLinkScreen.editIP(ctx)
                              })
        case .esp32:
            return note(fb, L, c, y + 3, w, VFDLinkKeys.esp32Note)
        case .androidBle:
            return note(fb, L, c, y + 3, w, VFDLinkKeys.bleNote)
        }
    }

    /// IPHONE, HINT, STATUS, EVENT, LIB SYNC, LIB, ANDROID, STORE, GATT.
    private static func statusRows(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ c: Int, _ top: Int, _ w: Int) -> Int {
        let vm: AppViewModel = ctx.vm
        let txStatus: String = ctx.tx.status
        var y: Int = infoRow(fb, c, top, w, "IPHONE", vm.relayStatus)
        let hint: String = vm.remoteLinkHint
        if !hint.isEmpty {
            y = infoRow(fb, c, y, w, "HINT", hint, color: VFDInk.highlight)
        }
        let warn: Bool = txStatus == TxEngine.notLinkedStatus || txStatus == TxEngine.sendFailedStatus
        let statusColor: UInt8 = warn ? VFDInk.alarm : VFDInk.dim
        y = infoRow(fb, c, y, w, "STATUS", txStatus, color: statusColor)
        y = infoRow(fb, c, y, w, "EVENT", vm.statusMessage)
        if vm.isCatalogSyncInFlight || !vm.catalogSyncDiagnostic.isEmpty {
            y = infoRow(fb, c, y, w, "LIB SYNC", vm.catalogSyncDiagnostic.uppercased())
        }
        if let cat = vm.androidCatalog, !cat.transmitPresets.isEmpty {
            let txCount: String = String(cat.transmitPresets.count)
            let wandCount: String = String(cat.wandColors.count)
            y = infoRow(fb, c, y, w, "LIB", txCount + " TX · " + wandCount + " WAND")
        }
        // The ESP32 answers STATUS with a bare {"ok":true}, which is not an Android status.
        if vm.relayBackend != .esp32, let s = vm.androidRemote {
            var text: String = s.status.uppercased()
            if s.status.isEmpty {
                text = s.running ? "RUNNING" : "STOPPED"
            }
            y = infoRow(fb, c, y, w, "ANDROID", text)
            y = infoRow(fb, c, y, w, "STORE", "REV " + String(s.storeRevision))
            if s.relayLinked {
                y = infoRow(fb, c, y, w, "GATT", "LINKED")
            }
        }
        return y
    }

    // MARK: Android remote panel and the relay feed

    /// The remote controls, the relay's counters, LIVE RX and the feed (or its empty line).
    private static func remoteSection(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ top: Int,
                                      _ w: Int) -> Int {
        let f: VFDLinkFeed = feed(ctx)
        var y: Int = remoteControls(ctx, fb, L, f, c, top, w)
        if let s = ctx.vm.androidRemote {
            y = remoteStats(fb, f, s, c, y + 3, w)
        }
        // The first group header sits closer.
        y = VFDW.section(fb, L, c, y, w, "LIVE RX") - 3
        if f.isEmpty {
            fb.textFit(c, y + 9, VFDLinkKeys.listen, w, .small, VFDInk.dim)
            return y + 9 + VFDW.line + 9
        }
        return drawFeed(ctx, fb, L, f, c, y, w)
    }

    /// ANDROID SCAN / RX: a dim panel with the title in its top border; the remote buttons, the
    /// GROUPED / RAW selectors with CLASS n/8, the AUTO-RESPONSE switch and the gesture hint.
    private static func remoteControls(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ f: VFDLinkFeed,
                                       _ c: Int, _ top: Int, _ w: Int) -> Int {
        let vm: AppViewModel = ctx.vm
        let inner: (c: Int, r: Int, w: Int) = VFDW.panelInner(c, top, w, title: true)
        let ic: Int = inner.c
        let iw: Int = inner.w
        let ready: Bool = vm.remoteLinkReady
        let status: AndroidRemoteStatus? = vm.androidRemote
        let scanOn: Bool = status?.scanActive ?? false
        let logOn: Bool = status?.recordSessionActive ?? false
        let autoOn: Bool = status?.autoEnabled ?? false
        let labels: [String] = [scanOn ? "Pause" : "Scan", logOn ? "Log Off" : "Log", "Clr", "Vib"]
        let enabled: [Bool] = [ready, ready, ready, ready]
        var r: Int = VFDW.buttons(fb, L, ic, inner.r + 2, iw, labels, enabled: enabled, equal: false,
                                  onSelect: { (index: Int) -> Void in
                                      VFDLinkScreen.remoteButton(ctx, index)
                                  })
        let modeIndex: Int = f.raw ? 1 : 0
        let modes: [String] = ["GROUPED", "RAW"]
        let end: Int = VFDW.options(fb, L, ic, r, iw, modes, selected: modeIndex, name: "mode",
                                    onSelect: { (index: Int) -> Void in
                                        VFDLinkScreen.setViewMode(ctx, raw: index == 1)
                                    })
        let groupedW: Int = VFDText.width("[GROUPED]")
        let rawW: Int = VFDText.width("[RAW]")
        let x: Int = ic + groupedW + VFDW.optGap + rawW + VFDW.optGap
        let total: Int = LivePacketSection.allCases.count
        let classLabel: String = "CLASS " + String(f.shownSections) + "/" + String(total)
        VFDW.menuButton(fb, L, x, r, classLabel, action: {
            VFDLinkScreen.openClassMenu(ctx)
        })
        r = VFDW.toggle(fb, L, ic, end, iw, "AUTO-RESPONSE", autoOn, enabled: ready, action: {
            let on: Bool = vm.androidRemote?.autoEnabled ?? false
            vm.setAndroidAuto(!on)
        })
        r = hintLines(fb, ic, r + 2, iw, VFDLinkKeys.hint)
        return VFDW.panel(fb, L, c, top, w, r + 2 - top, title: "ANDROID SCAN / RX")
    }

    /// BUF, HEARD, LAST (label · first 24 hex characters …), LOG.
    private static func remoteStats(_ fb: VFDFrameBuffer, _ f: VFDLinkFeed, _ s: AndroidRemoteStatus, _ c: Int,
                                    _ top: Int, _ w: Int) -> Int {
        var y: Int = infoRow(fb, c, top, w, "BUF", f.bufferText)
        y = infoRow(fb, c, y, w, "HEARD", String(s.packetsHeard) + " pkts")
        if !s.lastHeardHex.isEmpty {
            let headHex: String = String(s.lastHeardHex.prefix(24))
            let last: String = s.lastHeardLabel.uppercased() + " · " + headHex + VFDText.ellipsis
            y = infoRow(fb, c, y, w, "LAST", last)
        }
        if s.recordSessionActive && !s.activeSessionName.isEmpty {
            y = infoRow(fb, c, y, w, "LOG", s.activeSessionName)
        }
        return y
    }

    /// Packet row height (VFDW.packetRow's geometry): label, hex when there is one, the subtitle,
    /// the divider.
    private static func rowHeight(_ pkt: AndroidRemotePacket) -> Int {
        let hexRows: Int = pkt.hex.isEmpty ? 0 : VFDW.line
        let subRows: Int = rowSubtitle(pkt).isEmpty ? 0 : VFDW.line
        return 3 + hexRows + subRows + 10 + 1
    }

    /// GROUPED: a collapsible section header (chevron, title, 3-digit count) per visible section and
    /// its rows unless folded; RAW: every advert. Only rows inside the clip are drawn.
    private static func drawFeed(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ f: VFDLinkFeed, _ c: Int,
                                 _ top: Int, _ w: Int) -> Int {
        let view: (top: Int, bottom: Int) = visibleRows(fb)
        var y: Int = top
        if f.raw {
            for pkt in f.rawRows {
                let h: Int = rowHeight(pkt)
                if y + h <= view.top || y >= view.bottom {
                    y += h
                    continue
                }
                y = feedRow(ctx, fb, L, pkt, raw: true, c, y, w)
            }
            return y
        }
        for group in f.groups {
            let title: String = group.section.title
            let folded: Bool = f.collapsed.contains(title)
            y = VFDW.section(fb, L, c, y, w, title, count: group.packets.count, collapsed: folded, action: {
                VFDLinkScreen.toggleSection(ctx, title)
            })
            if folded { continue }
            y -= VFDW.gap + 1
            for pkt in group.packets {
                let h: Int = rowHeight(pkt)
                if y + h <= view.top || y >= view.bottom {
                    y += h
                    continue
                }
                y = feedRow(ctx, fb, L, pkt, raw: false, c, y, w)
            }
        }
        return y
    }

    /// One PacketRow: tap = transmit, hold = the packet menu, swipe left = remove (asks first),
    /// swipe right = the "Packet action" menu.
    private static func feedRow(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ pkt: AndroidRemotePacket,
                                raw: Bool, _ c: Int, _ y: Int, _ w: Int) -> Int {
        let tx: TxEngine = ctx.vm.tx
        let hex: String = pkt.hex
        let label: String = pkt.label
        return VFDW.packetRow(fb, L, c, y, w, label, hex, subtitle: rowSubtitle(pkt),
                              action: {
                                  tx.transmit(hex: hex, label: label)
                              },
                              long: {
                                  VFDLinkScreen.openActions(ctx, pkt, raw: raw)
                              },
                              swipeLeft: {
                                  VFDLinkScreen.askRemove(ctx, pkt, raw: raw)
                              },
                              swipeRight: {
                                  VFDLinkScreen.promote(ctx, pkt)
                              })
    }

    // MARK: actions

    /// PAUSE/SCAN, LOG/LOG OFF, CLR, VIB, as LinkScreen.remoteButtons.
    private static func remoteButton(_ ctx: VFDContext, _ index: Int) {
        let vm: AppViewModel = ctx.vm
        switch index {
        case 0:
            let scanOn: Bool = vm.androidRemote?.scanActive ?? false
            vm.setAndroidScan(!scanOn)
        case 1:
            let logOn: Bool = vm.androidRemote?.recordSessionActive ?? false
            vm.setAndroidRecording(!logOn)
        case 2:
            vm.clearAndroidLive()
        default:
            vm.vibrateAndroid()
        }
    }

    private static func setViewMode(_ ctx: VFDContext, raw: Bool) {
        let ui: VFDUIState = linkUI(ctx)
        ui.setString(VFDLinkKeys.viewMode, raw ? "RAW" : "GROUPED")
    }

    private static func toggleSection(_ ctx: VFDContext, _ title: String) {
        linkUI(ctx).toggleMember(VFDLinkKeys.collapsed, title)
    }

    /// SectionFilterMenu: ticks the shown sections; a pick toggles one and the menu stays open.
    private static func openClassMenu(_ ctx: VFDContext) {
        let ui: VFDUIState = linkUI(ctx)
        let hidden: Set<String> = ui.strings(VFDLinkKeys.hiddenSections)
        var items: [VFDMenuItem] = []
        var shownCount: Int = 0
        for section in LivePacketSection.allCases {
            let shown: Bool = !hidden.contains(section.rawValue)
            if shown {
                shownCount += 1
            }
            let label: String = shown ? section.title + " ✓" : section.title
            let key: String = section.rawValue
            items.append(VFDMenuItem(label, action: {
                VFDLinkScreen.linkUI(ctx).toggleMember(VFDLinkKeys.hiddenSections, key)
                VFDLinkScreen.openClassMenu(ctx)
            }))
        }
        let total: Int = LivePacketSection.allCases.count
        ctx.menu(title: "CLASS " + String(shownCount) + "/" + String(total), items: items)
    }

    /// The hold menu of a feed row: the tap action and both swipe actions.
    private static func openActions(_ ctx: VFDContext, _ pkt: AndroidRemotePacket, raw: Bool) {
        let vm: AppViewModel = ctx.vm
        let tx: TxEngine = vm.tx
        let store: MagicStore = vm.store
        let hex: String = pkt.hex
        let label: String = pkt.label
        let items: [VFDMenuItem] = [
            VFDMenuItem("Transmit", action: {
                tx.transmit(hex: hex, label: label)
            }),
            VFDMenuItem("Add to TX", action: {
                _ = store.saveCustomPreset(label: label, hex: hex)
            }),
            VFDMenuItem("Load Lab", action: {
                vm.loadInLab(hex: hex, label: label)
            }),
            VFDMenuItem("Delete", destructive: true, action: {
                VFDLinkScreen.askRemove(ctx, pkt, raw: raw)
            }),
        ]
        ctx.menu(title: label, items: items)
    }

    /// The swipe-right "Packet action" alert: ADD TO TX (the iPhone's own TX library) / LOAD LAB.
    private static func promote(_ ctx: VFDContext, _ pkt: AndroidRemotePacket) {
        let vm: AppViewModel = ctx.vm
        let store: MagicStore = vm.store
        let hex: String = pkt.hex
        let label: String = pkt.label
        let items: [VFDMenuItem] = [
            VFDMenuItem("Add to TX", action: {
                _ = store.saveCustomPreset(label: label, hex: hex)
            }),
            VFDMenuItem("Load Lab", action: {
                vm.loadInLab(hex: hex, label: label)
            }),
        ]
        ctx.menu(title: "Packet action · " + label, items: items)
    }

    /// confirmDelete with the scan list's titles: "Remove raw packet?" (RAW) or "Remove from scan
    /// list?" (GROUPED); the label and hex as the message.
    private static func askRemove(_ ctx: VFDContext, _ pkt: AndroidRemotePacket, raw: Bool) {
        let vm: AppViewModel = ctx.vm
        let title: String = raw ? "Remove raw packet?" : "Remove from scan list?"
        let upperLabel: String = pkt.label.uppercased()
        var message: String = upperLabel
        if !pkt.hex.isEmpty {
            message = upperLabel.isEmpty ? pkt.hex : upperLabel + "\n" + pkt.hex
        }
        let stamp: Int64 = pkt.timestampMs
        let hex: String = pkt.hex
        let key: String = pkt.dedupeKey
        ctx.confirm(title: title, message: message, confirmLabel: "DELETE", destructive: true, action: {
            if raw {
                vm.removeAndroidRawLive(timestampMs: stamp, hex: hex)
            } else {
                vm.removeAndroidUniqueLive(dedupeKey: key)
            }
        })
    }

    /// IMPORT ANDROID LIBRARY and its result line.
    private static func runImport(_ ctx: VFDContext) {
        let added: Int = ctx.vm.importAndroidLibrary()
        let text: String
        if added > 0 {
            text = "ADDED " + String(added) + " PACKETS TO THE IPHONE LIBRARY"
        } else {
            text = "ADDED 0 PACKETS · ALREADY IN THE IPHONE LIBRARY"
        }
        linkUI(ctx).setString(VFDLinkKeys.importResult, text)
    }

    /// The Android IP TextField as a prompt with the IP keyboard.
    private static func editIP(_ ctx: VFDContext) {
        let vm: AppViewModel = ctx.vm
        ctx.prompt(title: VFDLinkKeys.ipLabel, text: vm.androidRelayIP, keyboard: .ip,
                   onDone: { (text: String) -> Void in
                       vm.saveAndroidRelayIP(text)
                   })
    }

    /// SCAN ANDROID QR: the camera scanner (PairingQRScannerView) in a sheet.
    private static func openScanner(_ ctx: VFDContext) {
        let scanned: (String) -> Void = { (raw: String) -> Void in
            VFDLinkScreen.handleScannedCode(ctx, raw)
        }
        let cancel: () -> Void = {
            ctx.dismissSheet()
        }
        let view: PairingQRScannerView = PairingQRScannerView(onScan: scanned, onCancel: cancel)
        ctx.sheet(id: "link.qr") {
            view
        }
    }

    /// LinkScreen.handleScannedCode.
    private static func handleScannedCode(_ ctx: VFDContext, _ raw: String) {
        ctx.dismissSheet()
        let vm: AppViewModel = ctx.vm
        if let info = PairingPayloadParser.parse(raw) {
            vm.applyPairing(info)
        } else {
            vm.statusMessage = "Unrecognized QR — scan Android relay screen"
        }
        ctx.redraw()
    }
}
