import SwiftUI

/// LAB tab in the VFD theme: tools/vfd/screens/lab.py drawn from the standard LabScreen's real
/// state (LabScreen, LabModeBar, LabBuilderPanel, LabPacketInspector, LabRandomShowSection,
/// LabMbleSection, LabThemesSection).
///
/// The band preview is pinned under the header: the face's five LEDs in their true colours,
/// animated by BandLedAnimation exactly as BandPreviewView does (30 fps while something moves),
/// the BUZZ line blinking, and a legend of true-colour swatches with the colour names. Everything
/// under it scrolls in its own region (the page itself never scrolls): the mode bar, PACKET
/// BUILDER (type chips, summary card, the type's fields, FRAMING, PACKET ANATOMY, USE IN HEX
/// FIELD / LOAD HEX), the HEX OUTPUT and LABEL fields, the PACKET INSPECTOR, SEND / SAVE / TAG,
/// RANDOM LIGHT SHOW, MY PRESETS, MBLE TAP and HAWKEYE THEMES.
///
/// The standard screens keep their working state in @State; here it lives in this tab's
/// VFDUIState (see VFDLabState), synced from the store on first entry and whenever another screen
/// sends a packet to the Lab (vm.labLoadTick), as LabScreen.reloadFromStore and
/// LabBuilderPanel.decodeLoaded do. Pickers open a VFD menu; text entry is a system prompt.
@MainActor
enum VFDLabScreen: VFDScreen {
    static let title: String = "LAB"

    static func headerRight(_ ctx: VFDContext) -> (text: String, action: () -> Void)? {
        return nil
    }

    /// The band preview is pinned and the body scrolls in its own region, so the page never
    /// scrolls: returns nil.
    static func draw(_ ctx: VFDContext) -> Int? {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let c: Int = L.left
        let w: Int = L.width
        // Back to origin 0 (the page never scrolls; this keeps the rows below in screen rows).
        let pageScroll: Int = -fb.originY
        fb.pushClip(0, L.contentTop + pageScroll, fb.cols, L.contentH, dy: pageScroll)
        let m: VFDLabModel = VFDLabScreen.makeModel(ctx)
        let div: Int = VFDLabScreen.bandPreview(ctx, fb, c, L.contentTop, w, m.state.preview)
        let top: Int = div + 1
        let view: Int = L.contentBottom - top
        if view > 0 {
            VFDLabScreen.bodyWindow(ctx, fb, L, m, c, top, view, w)
        }
        fb.popClip()
        return nil
    }
}

// MARK: - State

/// Keys of the LAB tab's VFDUIState (in memory) and the standard screen's UserDefaults keys.
private enum VFDLabKeys {
    static let tab: String = "lab"
    static let region: String = "lab.body"
    /// vm.labLoadTick the working state was last synced to (absent: never synced).
    static let sync: String = "sync"
    static let hex: String = "hex"
    static let label: String = "label"
    static let preview: String = "preview"
    static let presetMsg: String = "presetMsg"
    static let packetType: String = "packetType"
    static let colors: String = "colors"
    static let vibOn: String = "vibOn"
    static let vibPattern: String = "vibPattern"
    static let rawHex: String = "rawHex"
    static let channel: String = "channelMarker"
    static let wake: String = "wakePrefix"
    static let timing: String = "timing"
    static let show: String = "showIndex"
    static let mask: String = "ledMask"
    static let loadMsg: String = "loadMsg"
    static let ping: String = "pingHex"
    static let inspector: String = "inspectorOpen"
    static let segment: String = "segment"
    static let segmentHex: String = "segmentHex"
    /// The selected block's box shows its full explanation (ABOUT).
    static let segmentAbout: String = "segmentAbout"
    /// ABOUT THIS FIELD: the field's title and explanation, shown in that box.
    static let segmentFieldTitle: String = "segmentFieldTitle"
    static let segmentFieldAbout: String = "segmentFieldAbout"
    /// The builder's packet before the last block edit, and the packet that edit made (UNDO EDIT).
    static let segmentUndo: String = "segmentUndo"
    static let segmentUndoTo: String = "segmentUndoTo"
    static let interval: String = "intervalMs"
    static let intervalDrag: String = "intervalDrag"
    static let intervalDraft: String = "intervalDraft"
    static let token: String = "mbleToken"
    /// @AppStorage("lab_extended") of LabScreen.
    static let extended: String = "lab_extended"
    /// @AppStorage("lab_themes_collapsed") of LabThemesSection.
    static let themesCollapsed: String = "lab_themes_collapsed"
}

/// The standard Lab's working state: LabScreen's hex, label, preview packet and preset message
/// plus LabBuilderPanel's fields.
private struct VFDLabState {
    var hex: String
    var label: String
    var preview: String
    var presetMsg: String?
    var type: LabPacketBuilder.LabPacketType
    var colors: [Int]
    var vibEnabled: Bool
    var vibPattern: Int
    var rawHex: String
    var framing: LabPacketBuilder.Framing
    var showIndex: Int
    var ledMask: Int
    var loadMsg: String?

    /// LabBuilderPanel.builtHex: what the builder currently describes.
    var built: String {
        let base: String = LabPacketBuilder.build(type: type, colors: colors, vibEnabled: vibEnabled,
                                                  vibPattern: vibPattern, rawHex: rawHex, framing: framing,
                                                  showIndex: showIndex)
        if type == LabPacketBuilder.LabPacketType.preset && ledMask != 7 {
            return PacketBuilder.withZoneMask(base, ledMask)
        }
        return base
    }
}

/// Everything one frame draws from, computed once per draw call (the body is drawn twice).
private struct VFDLabModel {
    let ui: VFDUIState
    let state: VFDLabState
    let built: String
    let extended: Bool
    let summary: LabPacketSummary
    let segments: [DisneyTlv.Segment]
    let selectedSegment: Int?
    /// The selected block's explanation (LabSegmentEditor.about: parse + anatomy only).
    let segmentAbout: LabSegmentEditor.About?
    let aboutOpen: Bool
    /// ABOUT THIS FIELD's field title and text ("" when none was asked for).
    let fieldAboutTitle: String
    let fieldAbout: String
    /// UNDO EDIT applies: the builder still holds the packet the last block edit made.
    let undoAvailable: Bool
    let classified: ClassifiedPacket?
    let bytes: [String]
    let reject: String?
    let presets: [MagicPacket]
    let pingHex: String
    let inspectorOpen: Bool
    let themesCollapsed: Bool
    let intervalMs: Double
    let intervalDragging: Bool
    let intervalDraft: Double
    let token: String
}

/// One legend entry under the preview text: a true-colour swatch (nil = off ring) and the name.
private struct VFDLabLegend {
    let rgb: VFDRGB?
    let name: String
}

/// One line of the preview's text column: text in an ink, or the colour legend.
private struct VFDLabLine {
    let text: String
    let color: UInt8
    let legend: [VFDLabLegend]
    let isLegend: Bool
}

// MARK: - Geometry, wording, option lists

private enum VFDLabGeo {
    /// Band face: face x face cells.
    static let face: Int = 55
    /// One round LED zone: led x led cells.
    static let led: Int = 11
    /// Zone offsets inside the face (left/top, centre, right/bottom).
    static let ledAt: [Int] = [8, 22, 36]
    /// Z1..Z5 as (column, row) in the face's 3 x 3 spots (BandPreviewView's point order).
    static let zoneSpot: [(c: Int, r: Int)] = [(c: 0, r: 2), (c: 0, r: 0), (c: 1, r: 1), (c: 2, r: 0), (c: 2, r: 2)]
    /// Legend swatch: a 7 x 7 round LED.
    static let swatch: Int = 7
    /// Anatomy block: border, 2 pad, caps, 3, caps, 2 pad, border.
    static let chipH: Int = 23
    static let trashW: Int = 7
    static let adv: Int = 6
    /// The preset row's bin, 7 x 8 cells.
    static let trash: [String] = ["..###..", "#######", ".#...#.", ".#.#.#.", ".#.#.#.", ".#.#.#.", ".#...#.", ".#####."]
}

private enum VFDLabCopy {
    static let standardDetail: String = "Everything here has been seen working."
    static let extendedDetail: String = "Adds RGB sliders, single-LED masks and the Experiments list. Untested on a band."
    static let awakeOnDetail: String = "Relay scanning paused · streaming pings · SEND goes out for the command interval, then pings resume"
    static let awakeOffDetail: String = "The relay pauses scanning and streams wake pings so the band stays listening between sends."
    static let builderIntro: String = "Pick what the band should do, set the colors, and the card below tells you exactly what you're sending."
    static let pingFields: String = "Nothing to set. Send this just before a command if a band isn't reacting."
    static let showNote: String = "Recorded in the park. Change any colour below; everything else is replayed byte-for-byte."
    static let ledNote: String = "Experimental: the top 3 bits of the colour byte pick which LEDs light. Two values are agreed; tell me what the rest do."
    static let channelTitle: String = "Channel marker (E1 00)"
    static let channelDetail: String = "Every effect recorded in the park carries this before the effect record. The esp32 presets never did. Try both — one may work where the other doesn't."
    static let durationNote: String = "How long the band holds the effect — the timing byte. Default keeps the shape's own value (~21 s for the colour presets)."
    static let wakeTitle: String = "Wake ping first (CC03 000100)"
    static let wakeDetail: String = "Tells nearby bands to listen before the effect arrives. The captured show packets all start this way."
    static let byteHint: String = "Color bytes use low 5 bits (00–1F). E0=preset · 80/80=dual · A0×5=rainbow · 40/40=xfade · tail B0|vib."
    static let linkWarning: String = "LINK NOT READY — CONNECT A RELAY ON THE LINK TAB TO SEND"
    static let showText: String = "Shoots a surprise packet — colors, duals, fades, rainbows, effects — on a loop until stopped."
    static let intervalHint: String = "Pause between packets (each packet also plays for the command burst time)."
    static let savedMsg: String = "Saved preset — see TX + Auto tabs"
    static let rgbNames: [String] = ["RED", "GREEN", "BLUE"]
    static let zoneLabels: [String] = ["BOT-L", "TOP-L", "CENTRE", "TOP-R", "BOT-R"]
}

/// The pickers' option lists, as LabBuilderPanel and LabModeBar build them.
private enum VFDLabOptions {
    static let palette: [(Int, String)] = LabPacketBuilder.paletteColors.map {
        (color: LabPacketBuilder.PaletteColor) -> (Int, String) in (color.id, color.label)
    }
    static let vibration: [(Int, String)] = LabPacketBuilder.vibrationPatterns.map {
        (pattern: LabPacketBuilder.VibrationPattern) -> (Int, String) in (pattern.id, pattern.label)
    }
    static let shows: [(Int, String)] = VFDLabOptions.indexed(LabPacketBuilder.showEffects.map {
        (show: (String, String)) -> String in show.0
    })
    static let experiments: [(Int, String)] = VFDLabOptions.indexed(LabPacketBuilder.experiments.map {
        (experiment: LabPacketBuilder.Experiment) -> String in experiment.name
    })
    static let pings: [(Int, String)] = [(0, "Wake ping (CC03 000100)"), (1, "Beacon ping (CC03 000000)")]
    static let beaconPingHex: String = "8301CC03000000"

    static func indexed(_ names: [String]) -> [(Int, String)] {
        var out: [(Int, String)] = []
        var index: Int = 0
        for name in names {
            out.append((index, name))
            index += 1
        }
        return out
    }

    /// The option's name for `id`, "?" when it is not in the list (LabPalettePicker.currentName).
    static func name(_ options: [(Int, String)], _ id: Int) -> String {
        for option in options where option.0 == id {
            return option.1
        }
        return "?"
    }

    /// A palette option ("#15 Red") as its true colour; nil for anything else.
    static func swatch(_ optionLabel: String) -> VFDRGB? {
        guard optionLabel.hasPrefix("#"), optionLabel.count >= 3 else { return nil }
        let digits: String = String(optionLabel.dropFirst().prefix(2))
        guard let index = Int(digits, radix: 16) else { return nil }
        return VFDColors.starlightGlow(index)
    }
}

// MARK: - Text helpers (lab.py)

private enum VFDLabText {
    static let nbsp: String = "\u{00A0}"
    /// Unit words that never start a line when they follow a number ("~21 s", "30 bytes").
    static let units: Set<String> = ["s", "ms", "sec", "min", "b", "byte", "bytes", "bit", "bits", "db", "dbm",
                                     "hz", "khz", "pt", "px", "%"]
    static let digits: String = "0123456789"

    static func isUnit(_ word: String) -> Bool {
        let trailing: String = ",.;:)!?"
        var s: String = word
        while let last = s.last, trailing.contains(last) {
            s.removeLast()
        }
        return units.contains(s.lowercased())
    }

    /// VFDText.wrap, except that the space before a lone "·" and the space between a number and
    /// its unit never break (lab.py wrap).
    static func wrap(_ s: String, _ maxCols: Int, size: VFDSize = .small) -> [String] {
        var words: [String] = []
        for piece in s.components(separatedBy: " ") {
            if piece.isEmpty { continue }
            if let prev = words.last {
                var prevDigit: Bool = false
                if let ch = prev.last {
                    prevDigit = digits.contains(ch)
                }
                if piece == "·" || (prevDigit && isUnit(piece)) {
                    words[words.count - 1] = prev + nbsp + piece
                    continue
                }
            }
            words.append(piece)
        }
        let joined: String = words.joined(separator: " ")
        let lines: [String] = VFDText.wrap(joined, maxCols, size: size)
        return lines.map { (ln: String) -> String in ln.replacingOccurrences(of: nbsp, with: " ") }
    }

    /// Word-wrapped lines; with maxLines the last kept line ends with … when text was cut.
    static func wrapLines(_ s: String, _ maxCols: Int, maxLines: Int = 0, size: VFDSize = .small) -> [String] {
        var lines: [String] = wrap(s, maxCols, size: size)
        if maxLines > 0 && lines.count > maxLines {
            lines = Array(lines[0..<maxLines])
            let padded: String = lines[maxLines - 1] + " " + String(repeating: "W", count: 40)
            lines[maxLines - 1] = VFDText.fit(padded, maxCols, size: size)
        }
        return lines
    }

    /// A title on one line if it fits, else broken before its "(...)" part (or word-wrapped), at
    /// most 2 lines.
    static func titleLines(_ s: String, _ maxCols: Int) -> [String] {
        if VFDText.width(s) <= maxCols { return [s] }
        if let range = s.range(of: " (") {
            let head: String = String(s[s.startIndex..<range.lowerBound])
            let tail: String = String(s[range.upperBound...])
            if VFDText.width(head) <= maxCols {
                return [head, VFDText.fit("(" + tail, maxCols)]
            }
        }
        return wrapLines(s, maxCols, maxLines: 2)
    }

    /// The summary headline in mid size: one line if it fits, else broken after the "Kind:"
    /// prefix (or word-wrapped), at most 2 lines.
    static func midHeadline(_ s: String, _ maxCols: Int) -> [String] {
        if VFDText.width(s, size: .mid) <= maxCols { return [s] }
        if let range = s.range(of: ": ") {
            let head: String = String(s[s.startIndex..<range.lowerBound]) + ":"
            let tail: String = String(s[range.upperBound...])
            return [VFDText.fit(head, maxCols, size: .mid), VFDText.fit(tail, maxCols, size: .mid)]
        }
        return wrapLines(s, maxCols, maxLines: 2, size: .mid)
    }

    /// Parts joined with " · ", wrapping only between parts; a part longer than a line is
    /// word-wrapped on its own.
    static func sepLines(_ parts: [String], _ maxCols: Int) -> [String] {
        let sep: String = " · "
        var lines: [String] = []
        var cur: String = ""
        for part in parts {
            let cand: String = cur.isEmpty ? part : cur + sep + part
            if VFDText.width(cand) <= maxCols {
                cur = cand
                continue
            }
            if !cur.isEmpty {
                lines.append(cur)
            }
            if VFDText.width(part) > maxCols {
                let wrapped: [String] = VFDText.wrap(part, maxCols)
                if wrapped.count > 1 {
                    lines.append(contentsOf: wrapped[0..<(wrapped.count - 1)])
                }
                cur = wrapped.last ?? ""
            } else {
                cur = part
            }
        }
        if !cur.isEmpty {
            lines.append(cur)
        }
        return lines
    }

    /// s, or its head and tail around "…" (SwiftUI .truncationMode(.middle)).
    static func fitMiddle(_ s: String, _ maxCols: Int) -> String {
        let n: Int = VFDText.maxChars(maxCols)
        let a: [Unicode.Scalar] = VFDText.scalars(s)
        if a.count <= n { return s }
        if n <= 1 { return VFDText.fit(s, maxCols) }
        let keep: Int = n - 1
        let head: Int = (keep + 1) / 2
        let tailCount: Int = keep - head
        let headPart: String = VFDText.string(Array(a[0..<head]))
        let tailPart: String = VFDText.string(Array(a[(a.count - tailCount)...]))
        return headPart + VFDText.ellipsis + tailPart
    }

    static func encodeInts(_ values: [Int]) -> String {
        let parts: [String] = values.map { (v: Int) -> String in String(v) }
        return parts.joined(separator: ",")
    }

    static func decodeInts(_ s: String) -> [Int] {
        return s.split(separator: ",").compactMap { (part: Substring) -> Int? in Int(part) }
    }
}

// MARK: - State sync and actions

extension VFDLabScreen {
    fileprivate static func labUI(_ ctx: VFDContext) -> VFDUIState {
        return ctx.uiState(for: VFDLabKeys.tab)
    }

    fileprivate static func extendedOn(_ ui: VFDUIState) -> Bool {
        return ui.storedBool(VFDLabKeys.extended, default: false)
    }

    /// The working state as stored (defaults: a fresh LabBuilderPanel).
    fileprivate static func storedState(_ ui: VFDUIState) -> VFDLabState {
        let preset: LabPacketBuilder.LabPacketType = LabPacketBuilder.LabPacketType.preset
        let raw: String = ui.string(VFDLabKeys.packetType, default: preset.rawValue)
        let type: LabPacketBuilder.LabPacketType = LabPacketBuilder.LabPacketType(rawValue: raw) ?? preset
        var colors: [Int] = LabPacketBuilder.defaultColors(preset)
        if ui.has(VFDLabKeys.colors) {
            colors = VFDLabText.decodeInts(ui.string(VFDLabKeys.colors))
        }
        let fallback: LabPacketBuilder.Framing = LabPacketBuilder.defaultFraming(preset)
        let channel: Bool = ui.bool(VFDLabKeys.channel, default: fallback.channelMarker)
        let wake: Bool = ui.bool(VFDLabKeys.wake, default: fallback.wakePrefix)
        let timing: Int = ui.int(VFDLabKeys.timing, default: PacketBuilder.Timing.default)
        let framing: LabPacketBuilder.Framing = LabPacketBuilder.Framing(channelMarker: channel, wakePrefix: wake,
                                                                          timing: timing)
        return VFDLabState(
            hex: ui.string(VFDLabKeys.hex),
            label: ui.string(VFDLabKeys.label),
            preview: ui.string(VFDLabKeys.preview),
            presetMsg: ui.optionalString(VFDLabKeys.presetMsg),
            type: type,
            colors: colors,
            vibEnabled: ui.bool(VFDLabKeys.vibOn, default: false),
            vibPattern: ui.int(VFDLabKeys.vibPattern, default: PacketBuilder.Vibration.triple),
            rawHex: ui.string(VFDLabKeys.rawHex),
            framing: framing,
            showIndex: ui.int(VFDLabKeys.show, default: 0),
            ledMask: ui.int(VFDLabKeys.mask, default: 7),
            loadMsg: ui.optionalString(VFDLabKeys.loadMsg)
        )
    }

    /// The working state as the standard Lab would show it now (pure): on first entry the store's
    /// packet decoded into the builder (LabScreen.reloadFromStore + LabBuilderPanel.appeared);
    /// after another screen sent a packet here (vm.labLoadTick moved) the store's packet reloaded
    /// and decoded (onChange(of: labLoadTick) + decodeLoaded).
    fileprivate static func resolve(_ ctx: VFDContext) -> VFDLabState {
        let ui: VFDUIState = labUI(ctx)
        let tick: Int = ctx.vm.labLoadTick
        var st: VFDLabState = storedState(ui)
        if !ui.has(VFDLabKeys.sync) {
            let saved: String = ctx.store.getLabHex()
            st.hex = saved
            st.label = ctx.store.getLabLabel()
            st.preview = saved
            if tick > 0 {
                decodeInto(&st, saved, from: "received packet", extended: extendedOn(ui))
            }
            applyExtended(&st, extendedOn(ui))
            let current: String = st.built
            if !current.isEmpty {
                st.preview = current
            }
        } else if ui.int(VFDLabKeys.sync, default: 0) != tick {
            let before: String = st.built
            let saved: String = ctx.store.getLabHex()
            st.hex = saved
            st.label = ctx.store.getLabLabel()
            st.preview = saved
            if tick > 0 {
                let decoded: Bool = decodeInto(&st, saved, from: "received packet", extended: extendedOn(ui))
                let after: String = st.built
                if decoded && after != before && !after.isEmpty {
                    st.preview = after
                }
            }
        }
        // Extended switched off elsewhere (the standard theme): the Standard / Extended rule, as
        // the builder applies it when it appears.
        if !extendedOn(ui) && (st.type.experimental || st.ledMask != 7) {
            let before: String = st.built
            applyExtended(&st, false)
            let after: String = st.built
            if after != before && !after.isEmpty {
                st.preview = after
            }
        }
        return st
    }

    fileprivate static func saveState(_ ctx: VFDContext, _ st: VFDLabState) {
        let ui: VFDUIState = labUI(ctx)
        ui.setString(VFDLabKeys.hex, st.hex)
        ui.setString(VFDLabKeys.label, st.label)
        ui.setString(VFDLabKeys.preview, st.preview)
        ui.setOptionalString(VFDLabKeys.presetMsg, st.presetMsg)
        ui.setString(VFDLabKeys.packetType, st.type.rawValue)
        ui.setString(VFDLabKeys.colors, VFDLabText.encodeInts(st.colors))
        ui.setBool(VFDLabKeys.vibOn, st.vibEnabled)
        ui.setInt(VFDLabKeys.vibPattern, st.vibPattern)
        ui.setString(VFDLabKeys.rawHex, st.rawHex)
        ui.setBool(VFDLabKeys.channel, st.framing.channelMarker)
        ui.setBool(VFDLabKeys.wake, st.framing.wakePrefix)
        ui.setInt(VFDLabKeys.timing, st.framing.timing)
        ui.setInt(VFDLabKeys.show, st.showIndex)
        ui.setInt(VFDLabKeys.mask, st.ledMask)
        ui.setOptionalString(VFDLabKeys.loadMsg, st.loadMsg)
        ui.setInt(VFDLabKeys.sync, ctx.vm.labLoadTick)
    }

    /// LabBuilderPanel.decodeLoaded / loadFromHexField: the builder state that rebuilds exactly
    /// this packet (Raw Hex, byte-for-byte, when no builder type makes those bytes), the LED mask
    /// back to all, and the load message. False when there is nothing to decode.
    @discardableResult
    fileprivate static func decodeInto(_ st: inout VFDLabState, _ hex: String, from source: String,
                                       extended: Bool) -> Bool {
        guard let decoded = LabSegmentEditor.builderState(hex, extended: extended) else { return false }
        applyDecoded(&st, decoded)
        st.ledMask = 7
        if decoded.type == LabPacketBuilder.LabPacketType.raw {
            st.loadMsg = "Loaded Raw Hex from " + source + " (kept byte-for-byte)"
        } else {
            st.loadMsg = "Loaded " + decoded.type.label + " from " + source
        }
        return true
    }

    /// LabBuilderPanel.applyDecoded.
    fileprivate static func applyDecoded(_ st: inout VFDLabState, _ decoded: LabPacketBuilder.Decoded) {
        st.type = decoded.type
        st.colors = decoded.colors.isEmpty ? LabPacketBuilder.defaultColors(decoded.type) : decoded.colors
        st.vibEnabled = decoded.vibEnabled
        st.vibPattern = decoded.vibPattern
        st.rawHex = decoded.rawHex
        st.framing = decoded.framing
        st.showIndex = decoded.showIndex
    }

    /// LabBuilderPanel.select.
    fileprivate static func selectType(_ st: inout VFDLabState, _ type: LabPacketBuilder.LabPacketType) {
        if type == st.type { return }
        st.type = type
        st.colors = LabPacketBuilder.defaultColors(type)
        st.framing = LabPacketBuilder.defaultFraming(type)
        let trimmed: String = st.rawHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if type == LabPacketBuilder.LabPacketType.raw && trimmed.isEmpty {
            st.rawHex = st.hex
        }
        st.loadMsg = nil
    }

    /// LabBuilderPanel.applyExtended: leaving Extended drops back to a Standard type.
    fileprivate static func applyExtended(_ st: inout VFDLabState, _ on: Bool) {
        if !on && st.type.experimental {
            selectType(&st, LabPacketBuilder.LabPacketType.preset)
        }
        if !on {
            st.ledMask = 7
        }
    }

    /// A change the user made in the builder: the preview and the hex field follow the new packet
    /// (LabBuilderPanel.builderHexChanged -> LabScreen.useBuiltHex).
    fileprivate static func userEdit(_ ctx: VFDContext, _ change: (inout VFDLabState) -> Void) {
        var st: VFDLabState = resolve(ctx)
        let before: String = st.built
        change(&st)
        let after: String = st.built
        if after != before && !after.isEmpty {
            st.preview = after
            st.hex = after
            ctx.store.saveLabHex(after)
        }
        saveState(ctx, st)
    }

    /// The Standard / Extended switch (LabBuilderPanel onChange(of: extended)): applyExtended, and
    /// only the preview follows the builder; the hex field keeps its packet (holdBuiltHex).
    fileprivate static func toggleExtended(_ ctx: VFDContext) {
        let ui: VFDUIState = labUI(ctx)
        var st: VFDLabState = resolve(ctx)
        let before: String = st.built
        let on: Bool = !extendedOn(ui)
        ui.setStoredBool(VFDLabKeys.extended, on)
        applyExtended(&st, on)
        let after: String = st.built
        if after != before && !after.isEmpty {
            st.preview = after
        }
        saveState(ctx, st)
    }

    fileprivate static func toggleKeepAwake(_ ctx: VFDContext) {
        let ping: String = labUI(ctx).string(VFDLabKeys.ping, default: PacketBuilder.wakeupPing)
        let next: Bool = !ctx.vm.keepAwakeActive
        ctx.vm.setKeepAwake(next, hex: ping)
    }

    fileprivate static func pickPing(_ ctx: VFDContext, _ picked: Int) {
        let next: String = picked == 1 ? VFDLabOptions.beaconPingHex : PacketBuilder.wakeupPing
        labUI(ctx).setString(VFDLabKeys.ping, next)
        if ctx.vm.keepAwakeActive {
            ctx.vm.setKeepAwake(true, hex: next)
        }
    }

    /// USE IN HEX FIELD (LabScreen.useBuiltHex).
    fileprivate static func useBuilt(_ ctx: VFDContext) {
        var st: VFDLabState = resolve(ctx)
        let current: String = st.built
        if current.isEmpty { return }
        st.hex = current
        st.preview = current
        ctx.store.saveLabHex(current)
        saveState(ctx, st)
    }

    /// LOAD HEX (LabBuilderPanel.loadFromHexField).
    fileprivate static func loadFromHexField(_ ctx: VFDContext) {
        var st: VFDLabState = resolve(ctx)
        let before: String = st.built
        if decodeInto(&st, st.hex, from: "hex field", extended: extendedOn(labUI(ctx))) {
            let after: String = st.built
            if after != before && !after.isEmpty {
                st.preview = after
            }
        } else {
            st.loadMsg = "Hex field is empty"
        }
        saveState(ctx, st)
    }

    /// Typing in the hex field also drives the preview (LabScreen.hexBinding).
    fileprivate static func setHexField(_ ctx: VFDContext, _ typed: String) {
        var st: VFDLabState = resolve(ctx)
        let upper: String = typed.uppercased()
        st.hex = upper
        st.preview = upper
        saveState(ctx, st)
    }

    fileprivate static func setLabelField(_ ctx: VFDContext, _ typed: String) {
        var st: VFDLabState = resolve(ctx)
        st.label = typed
        saveState(ctx, st)
    }

    /// LabScreen.inspectorEdited: the hex field and the store, not the preview.
    fileprivate static func inspectorEdited(_ ctx: VFDContext, _ edited: String) {
        var st: VFDLabState = resolve(ctx)
        st.hex = edited
        ctx.store.saveLabHex(edited)
        saveState(ctx, st)
    }

    fileprivate static func stepVibration(_ ctx: VFDContext, _ delta: Int) {
        let st: VFDLabState = resolve(ctx)
        guard let vib = LabPacketTools.tailVibration(st.hex) else { return }
        let next: Int = min(max(vib + delta, 0), 15)
        inspectorEdited(ctx, LabPacketTools.withVibration(st.hex, next))
    }

    /// One byte typed over (LabByteCell): two hex digits, uppercased, anything else dropped; the
    /// whole hex is rebuilt from the grid.
    fileprivate static func editByte(_ ctx: VFDContext, _ index: Int, _ typed: String) {
        let st: VFDLabState = resolve(ctx)
        var bytes: [String] = LabPacketTools.toBytes(st.hex)
        if index < 0 || index >= bytes.count { return }
        let allowed: String = "0123456789ABCDEF"
        let digits: String = typed.uppercased().filter { (ch: Character) -> Bool in allowed.contains(ch) }
        let cleaned: String = String(digits.prefix(2))
        if cleaned == bytes[index] { return }
        bytes[index] = cleaned
        inspectorEdited(ctx, LabPacketTools.fromBytes(bytes))
    }

    fileprivate static func promptByte(_ ctx: VFDContext, _ index: Int, _ value: String, _ count: Int) {
        let title: String = "BYTE \(index + 1) OF \(count)"
        ctx.prompt(title: title, text: value, keyboard: .hex) { (typed: String) -> Void in
            VFDLabScreen.editByte(ctx, index, typed)
        }
    }

    /// The tapped anatomy block, while the packet it belongs to is still the builder's.
    fileprivate static func selectedSegment(_ ui: VFDUIState, _ built: String) -> Int? {
        if ui.string(VFDLabKeys.segmentHex) != built { return nil }
        let v: Int = ui.int(VFDLabKeys.segment, default: -1)
        return v >= 0 ? v : nil
    }

    // MARK: SEND / SAVE / TAG, presets

    fileprivate static func sendPacket(_ ctx: VFDContext) {
        let st: VFDLabState = resolve(ctx)
        ctx.store.saveLabHex(st.hex)
        ctx.store.saveLabLabel(st.label)
        let trimmed: String = st.label.trimmingCharacters(in: .whitespacesAndNewlines)
        ctx.tx.transmit(hex: st.hex, label: trimmed.isEmpty ? "Lab" : trimmed)
    }

    fileprivate static func savePreset(_ ctx: VFDContext) {
        var st: VFDLabState = resolve(ctx)
        ctx.store.saveLabHex(st.hex)
        ctx.store.saveLabLabel(st.label)
        let refusal: String? = ctx.store.saveCustomPreset(label: st.label, hex: st.hex)
        st.presetMsg = refusal ?? VFDLabCopy.savedMsg
        saveState(ctx, st)
    }

    fileprivate static func tagRaw(_ ctx: VFDContext) {
        var st: VFDLabState = resolve(ctx)
        ctx.store.saveLabHex(st.hex)
        ctx.store.saveLabLabel(st.label)
        ctx.store.applyLabLabelToMatchingRaw()
        st.presetMsg = "Raw tag updated"
        saveState(ctx, st)
    }

    fileprivate static func loadPreset(_ ctx: VFDContext, _ preset: MagicPacket) {
        var st: VFDLabState = resolve(ctx)
        st.hex = preset.hex
        st.label = preset.label
        ctx.store.saveLabHex(preset.hex)
        ctx.store.saveLabLabel(preset.label)
        saveState(ctx, st)
    }

    /// The trash button: "Delete preset?" with the label and hex, DELETE / CANCEL.
    fileprivate static func askDelete(_ ctx: VFDContext, _ preset: MagicPacket) {
        let id: Int64 = preset.id
        let label: String = preset.label.uppercased()
        var message: String = label
        if !preset.hex.isEmpty {
            message = label.isEmpty ? preset.hex : label + "\n" + preset.hex
        }
        ctx.confirm(title: "Delete preset?", message: message, confirmLabel: "DELETE", destructive: true) {
            ctx.store.deleteCustomPreset(id: id)
            var st: VFDLabState = VFDLabScreen.resolve(ctx)
            st.presetMsg = "Preset deleted"
            VFDLabScreen.saveState(ctx, st)
        }
    }

    /// HOLD on a preset: its two actions.
    fileprivate static func presetMenu(_ ctx: VFDContext, _ preset: MagicPacket) {
        let item: MagicPacket = preset
        let items: [VFDMenuItem] = [
            VFDMenuItem("LOAD IN LAB", action: { VFDLabScreen.loadPreset(ctx, item) }),
            VFDMenuItem("DELETE", destructive: true, action: { VFDLabScreen.askDelete(ctx, item) }),
        ]
        ctx.menu(title: preset.label, items: items)
    }

    // MARK: random show

    fileprivate static func intervalValue(_ ctx: VFDContext) -> Double {
        let ui: VFDUIState = labUI(ctx)
        if ui.has(VFDLabKeys.interval) {
            return ui.double(VFDLabKeys.interval, default: 3000)
        }
        return Double(ctx.tx.randomShowIntervalMs)
    }

    /// LabRandomShowSection.intervalCommitted: a new pace applies to a running show at once.
    fileprivate static func commitInterval(_ ctx: VFDContext, _ ms: Double) {
        labUI(ctx).setDouble(VFDLabKeys.interval, ms)
        if ctx.tx.randomShowEnabled {
            ctx.tx.setRandomShow(enabled: true, intervalMs: showMilliseconds(ms))
        }
    }

    fileprivate static func toggleShow(_ ctx: VFDContext) {
        let next: Bool = !ctx.tx.randomShowEnabled
        ctx.tx.setRandomShow(enabled: next, intervalMs: showMilliseconds(intervalValue(ctx)))
    }

    fileprivate static func showMilliseconds(_ value: Double) -> Int {
        if !value.isFinite { return 3000 }
        let bounded: Double = min(max(value, 0), 3_600_000)
        return Int(bounded)
    }

    /// SettingSlider.snap: the nearest multiple of step (halves up), kept inside the range.
    fileprivate static func snap(_ v: Double, _ low: Double, _ high: Double, _ step: Double) -> Double {
        if !v.isFinite { return low }
        if step <= 0 { return min(max(v, low), high) }
        let steps: Double = (v / step + 0.5).rounded(.down)
        return min(max(steps * step, low), high)
    }

    // MARK: pickers

    /// LabPalettePicker's sheet as a VFD menu: one row per option, the current one ticked and
    /// drawn as the selected row, the list opened at it; a palette option ("#15 Red") starts with
    /// a swatch of its true colour, as the sheet's rows do.
    fileprivate static func openPicker(_ ctx: VFDContext, _ title: String, _ options: [(Int, String)],
                                       _ selected: Int, _ pick: @escaping (Int) -> Void) {
        if options.isEmpty { return }
        var items: [VFDMenuItem] = []
        var current: Int? = nil
        var row: Int = 0
        for option in options {
            let id: Int = option.0
            let isCurrent: Bool = id == selected
            if isCurrent && current == nil {
                current = row
            }
            let shown: String = isCurrent ? option.1 + " ✓" : option.1
            let swatch: VFDRGB? = VFDLabOptions.swatch(option.1)
            items.append(VFDMenuItem(shown, rgb: swatch, action: { pick(id) }))
            row += 1
        }
        ctx.menu(title: title, items: items, selected: current)
    }

    // MARK: colour names with their swatches

    /// The true colours behind a classifier's colour names: each distinct palette colour that
    /// BandEffectModel reads from `hex` (a wand code's own colour when it reads none) and whose
    /// name is in `names`, in the order the names first appear there; at most five, OFF left out.
    fileprivate static func namedSwatches(_ hex: String, _ names: String) -> [VFDRGB] {
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
        var found: [VFDLabNamedSwatch] = []
        var seen = Set<Int>()
        for raw in indices {
            let index: Int = raw & 0x1F
            if !seen.insert(index).inserted { continue }
            let name: String = StarlightColors.nameFor(index).lowercased()
            if name == "off" { continue }
            guard let range = text.range(of: name) else { continue }
            let pos: Int = text.distance(from: text.startIndex, to: range.lowerBound)
            found.append(VFDLabNamedSwatch(pos: pos, order: found.count, rgb: VFDColors.starlightGlow(index)))
        }
        found.sort(by: { (a: VFDLabNamedSwatch, b: VFDLabNamedSwatch) -> Bool in
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
    fileprivate static func swatchNames(_ fb: VFDFrameBuffer, _ x0: Int, _ r: Int, _ swatches: [VFDRGB],
                                        _ names: String, _ limit: Int, _ color: UInt8) -> Int {
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

/// One swatch of `namedSwatches`: where its colour's name first appears, and the colour.
private struct VFDLabNamedSwatch {
    let pos: Int
    let order: Int
    let rgb: VFDRGB
}

// MARK: - Segment editor (tap an anatomy block)

/// Rows of a field's menu and which of them is the current value (an index into `items`).
private struct VFDLabMenuRows {
    let items: [VFDMenuItem]
    let current: Int?
}

extension VFDLabScreen {
    /// A tapped anatomy block: select it, then open its editor menu on the packet as it is now;
    /// a block nothing can change (located nowhere, or the company ID with no framing to add)
    /// opens its explanation instead. LabSegmentEditor.segment scans the catalogues, so it runs
    /// here, never while drawing.
    fileprivate static func openSegment(_ ctx: VFDContext, _ index: Int, _ built: String) {
        let ui: VFDUIState = labUI(ctx)
        ui.setString(VFDLabKeys.segmentHex, built)
        ui.setInt(VFDLabKeys.segment, index)
        ui.setBool(VFDLabKeys.segmentAbout, false)
        clearFieldAbout(ui)
        let base: String = HexUtils.canonicalHex(built)
        guard let seg = editable(ctx, base, index) else { return }
        if seg.fields.isEmpty && seg.actions.isEmpty && !seg.manual.allowed {
            ui.setBool(VFDLabKeys.segmentAbout, true)
            return
        }
        segmentMenu(ctx, seg, base)
    }

    fileprivate static func editable(_ ctx: VFDContext, _ base: String,
                                     _ index: Int) -> LabSegmentEditor.EditableSegment? {
        let extended: Bool = extendedOn(labUI(ctx))
        let serial: String = ctx.store.getStarlightSerial()
        return LabSegmentEditor.segment(base, index: index, extended: extended, savedSerial: serial)
    }

    /// × on the block's box: nothing selected, the explanation folded.
    fileprivate static func closeSegment(_ ui: VFDUIState) {
        ui.setInt(VFDLabKeys.segment, -1)
        ui.setBool(VFDLabKeys.segmentAbout, false)
        clearFieldAbout(ui)
    }

    fileprivate static func clearFieldAbout(_ ui: VFDUIState) {
        if ui.has(VFDLabKeys.segmentFieldTitle) {
            ui.remove(VFDLabKeys.segmentFieldTitle)
        }
        if ui.has(VFDLabKeys.segmentFieldAbout) {
            ui.remove(VFDLabKeys.segmentFieldAbout)
        }
    }

    /// ABOUT THIS BLOCK / ABOUT THIS FIELD: unfold the box under the chips (with the field's own
    /// explanation when one is given).
    fileprivate static func showAbout(_ ctx: VFDContext, _ field: LabSegmentEditor.Field?) {
        let ui: VFDUIState = labUI(ctx)
        if let f = field {
            ui.setString(VFDLabKeys.segmentFieldTitle, f.title)
            ui.setString(VFDLabKeys.segmentFieldAbout, f.about)
        } else {
            clearFieldAbout(ui)
        }
        ui.setBool(VFDLabKeys.segmentAbout, true)
    }

    /// The block's menu: what it holds now; its values (one field) or one row per field (several);
    /// the packet-level actions; MANUAL HEX; ABOUT THIS BLOCK. Opened at the current value.
    fileprivate static func segmentMenu(_ ctx: VFDContext, _ seg: LabSegmentEditor.EditableSegment,
                                        _ base: String) {
        let title: String = seg.segment.title
        let index: Int = seg.index
        var items: [VFDMenuItem] = []
        var selected: Int? = nil
        let only: LabSegmentEditor.Field? = seg.fields.count == 1 ? seg.fields.first : nil
        let nowCaption: String = only?.caption ?? ""
        items.append(nowItem(ctx, seg.segment.hex, nowCaption))
        if let field = only {
            let rows: VFDLabMenuRows = fieldRows(ctx, seg, field, base)
            if let cur = rows.current {
                selected = items.count + cur
            }
            items.append(contentsOf: rows.items)
        } else {
            for field in seg.fields {
                items.append(fieldItem(ctx, seg, field, base))
            }
        }
        for step in seg.actions {
            let after: String = step.hex
            let label: String = menuLabel(ctx, step.label, "")
            items.append(VFDMenuItem(label, destructive: step.destructive, action: {
                VFDLabScreen.applySegmentEdit(ctx, after, title, index, base)
            }))
        }
        if seg.manual.allowed {
            let rule: LabSegmentEditor.ManualRule = seg.manual
            let words: String = sizeWords(rule.minBytes, rule.maxBytes)
            items.append(VFDMenuItem(menuLabel(ctx, "MANUAL HEX… (" + words + ")", ""), action: {
                let now: String = VFDLabScreen.manualCurrent(base, rule)
                VFDLabScreen.promptManual(ctx, seg, nil, base, now)
            }))
        }
        items.append(VFDMenuItem("ABOUT THIS BLOCK", action: {
            VFDLabScreen.showAbout(ctx, only)
        }))
        ctx.menu(title: VFDW.upper(title), items: items, selected: selected)
    }

    /// One field's menu: what it holds now, its values (the timing byte's bit controls first),
    /// MANUAL HEX sized to the field, ABOUT THIS FIELD, ← BACK to the block's menu.
    fileprivate static func fieldMenu(_ ctx: VFDContext, _ seg: LabSegmentEditor.EditableSegment,
                                      _ field: LabSegmentEditor.Field, _ base: String) {
        let index: Int = seg.index
        var items: [VFDMenuItem] = []
        var selected: Int? = nil
        items.append(nowItem(ctx, HexUtils.bytesToHex(field.current), field.caption))
        let rows: VFDLabMenuRows = fieldRows(ctx, seg, field, base)
        if let cur = rows.current {
            selected = items.count + cur
        }
        items.append(contentsOf: rows.items)
        let words: String = field.lengthByteOffset == nil ? sizeWords(field.count, field.count) : sizeWords(0, 255)
        items.append(VFDMenuItem(menuLabel(ctx, "MANUAL HEX… (" + words + ")", ""), action: {
            let now: String = HexUtils.bytesToHex(field.current)
            VFDLabScreen.promptManual(ctx, seg, field, base, now)
        }))
        items.append(VFDMenuItem("ABOUT THIS FIELD", action: {
            VFDLabScreen.showAbout(ctx, field)
        }))
        items.append(VFDMenuItem("← BACK", action: {
            VFDLabScreen.reopenSegment(ctx, index)
        }))
        let title: String = seg.segment.title + " · " + field.title
        ctx.menu(title: VFDW.upper(title), items: items, selected: selected)
    }

    /// A field's value rows: the timing byte's bit controls, then its options (a colour with its
    /// true-colour swatch, the current one ticked); a 6-bit RGB channel gets level rows instead.
    fileprivate static func fieldRows(_ ctx: VFDContext, _ seg: LabSegmentEditor.EditableSegment,
                                      _ field: LabSegmentEditor.Field, _ base: String) -> VFDLabMenuRows {
        if field.kind == LabSegmentEditor.FieldKind.rgbChannel {
            return rgbRows(ctx, seg, field, base)
        }
        let title: String = seg.segment.title
        let index: Int = seg.index
        var items: [VFDMenuItem] = []
        var current: Int? = nil
        if field.kind == LabSegmentEditor.FieldKind.timing {
            items.append(contentsOf: timingRows(ctx, seg, field, base))
        }
        for option in field.options {
            let isCurrent: Bool = LabSegmentEditor.isCurrent(base, field: field, option: option)
            if isCurrent && current == nil {
                current = items.count
            }
            var swatch: VFDRGB? = nil
            if let p = option.palette {
                swatch = VFDColors.starlightGlow(p)
            }
            let tick: String = isCurrent ? " ✓" : ""
            let label: String = menuLabel(ctx, compactCaption(option.label), tick, swatch: swatch != nil)
            let picked: LabSegmentEditor.Option = option
            items.append(VFDMenuItem(label, rgb: swatch, action: {
                let edited: String? = LabSegmentEditor.applying(base, field: field, option: picked)
                VFDLabScreen.applySegmentEdit(ctx, edited, title, index, base)
            }))
        }
        return VFDLabMenuRows(items: items, current: current)
    }

    /// A block's menu row for one of its fields: "TITLE: HEX · CAPTION →" (a colour with its
    /// swatch), opening the field's menu.
    fileprivate static func fieldItem(_ ctx: VFDContext, _ seg: LabSegmentEditor.EditableSegment,
                                      _ field: LabSegmentEditor.Field, _ base: String) -> VFDMenuItem {
        let hex: String = HexUtils.bytesToHex(field.current)
        let caption: String = compactCaption(field.caption)
        var head: String = field.title + ": " + hex + " · " + caption
        if field.count > 3 || hex.isEmpty {
            head = field.title + ": " + caption
        } else if caption.isEmpty || caption == hex {
            head = field.title + ": " + hex
        }
        var swatch: VFDRGB? = nil
        let isPalette: Bool = field.kind == LabSegmentEditor.FieldKind.color
        let isWand: Bool = field.kind == LabSegmentEditor.FieldKind.wandColor
        let colour: Bool = isPalette || isWand
        if colour, let b = field.current.first {
            swatch = VFDColors.starlightGlow(Int(b) & 0x1F)
        }
        let label: String = menuLabel(ctx, head, " →", swatch: swatch != nil)
        return VFDMenuItem(label, rgb: swatch, action: {
            VFDLabScreen.fieldMenu(ctx, seg, field, base)
        })
    }

    /// The disabled first row: "NOW <hex> · <caption>".
    fileprivate static func nowItem(_ ctx: VFDContext, _ hex: String, _ caption: String) -> VFDMenuItem {
        let shown: String = hex.isEmpty ? "—" : hex
        let words: String = compactCaption(caption)
        var head: String = "NOW " + shown
        if !words.isEmpty && words != hex {
            head += " · " + words
        }
        return VFDMenuItem(menuLabel(ctx, head, ""), enabled: false, action: {})
    }

    /// The timing byte's bit controls: ALWAYS ON and UNIT flip one bit; FADE (0–3 s) and COUNT
    /// (0–15) open a list. Each change applies at once and reopens the field's menu.
    fileprivate static func timingRows(_ ctx: VFDContext, _ seg: LabSegmentEditor.EditableSegment,
                                       _ field: LabSegmentEditor.Field, _ base: String) -> [VFDMenuItem] {
        let b: Int = firstByte(field)
        let p: (alwaysOn: Bool, longUnit: Bool, fadeSeconds: Int, count: Int) = LabSegmentEditor.timingParts(b)
        let flipAlways: Int = LabSegmentEditor.timingByte(alwaysOn: !p.alwaysOn, longUnit: p.longUnit,
                                                         fadeSeconds: p.fadeSeconds, count: p.count)
        let flipUnit: Int = LabSegmentEditor.timingByte(alwaysOn: p.alwaysOn, longUnit: !p.longUnit,
                                                       fadeSeconds: p.fadeSeconds, count: p.count)
        let alwaysText: String = p.alwaysOn ? "ALWAYS ON: ON → OFF" : "ALWAYS ON: OFF → ON"
        let unitText: String = p.longUnit ? "UNIT: ×3.1 S → ×1.5 S" : "UNIT: ×1.5 S → ×3.1 S"
        var items: [VFDMenuItem] = []
        items.append(VFDMenuItem(alwaysText, action: {
            VFDLabScreen.composeTiming(ctx, seg, field, base, flipAlways)
        }))
        items.append(VFDMenuItem(unitText, action: {
            VFDLabScreen.composeTiming(ctx, seg, field, base, flipUnit)
        }))
        items.append(VFDMenuItem("FADE: \(p.fadeSeconds) S →", action: {
            VFDLabScreen.timingPartMenu(ctx, seg, field, base, fade: true)
        }))
        items.append(VFDMenuItem("COUNT: \(p.count) →", action: {
            VFDLabScreen.timingPartMenu(ctx, seg, field, base, fade: false)
        }))
        return items
    }

    /// FADE (0–3 s) or COUNT (0–15) of the timing byte, the other bits kept.
    fileprivate static func timingPartMenu(_ ctx: VFDContext, _ seg: LabSegmentEditor.EditableSegment,
                                           _ field: LabSegmentEditor.Field, _ base: String, fade: Bool) {
        let p: (alwaysOn: Bool, longUnit: Bool, fadeSeconds: Int, count: Int) = LabSegmentEditor.timingParts(firstByte(field))
        let top: Int = fade ? 3 : 15
        var items: [VFDMenuItem] = []
        var selected: Int? = nil
        for v in 0...top {
            let byte: Int
            let isCurrent: Bool
            let name: String
            if fade {
                byte = LabSegmentEditor.timingByte(alwaysOn: p.alwaysOn, longUnit: p.longUnit,
                                                   fadeSeconds: v, count: p.count)
                isCurrent = v == p.fadeSeconds
                name = "FADE \(v) S"
            } else {
                byte = LabSegmentEditor.timingByte(alwaysOn: p.alwaysOn, longUnit: p.longUnit,
                                                   fadeSeconds: p.fadeSeconds, count: v)
                isCurrent = v == p.count
                name = "COUNT \(v)"
            }
            if isCurrent {
                selected = items.count
            }
            let caption: String = compactCaption(DisneyTlv.timingCaption(byte))
            let head: String = name + " · " + DisneyTlv.hex2(byte) + " · " + caption
            let label: String = menuLabel(ctx, head, isCurrent ? " ✓" : "")
            items.append(VFDMenuItem(label, action: {
                VFDLabScreen.composeTiming(ctx, seg, field, base, byte)
            }))
        }
        items.append(VFDMenuItem("← BACK", action: {
            VFDLabScreen.fieldMenu(ctx, seg, field, base)
        }))
        let title: String = seg.segment.title + " · " + (fade ? "Fade-out" : "Count")
        ctx.menu(title: VFDW.upper(title), items: items, selected: selected)
    }

    /// One composed timing byte: applied, then the timing menu again on the new packet so the
    /// next bit can be set.
    fileprivate static func composeTiming(_ ctx: VFDContext, _ seg: LabSegmentEditor.EditableSegment,
                                          _ field: LabSegmentEditor.Field, _ base: String, _ byte: Int) {
        let bytes: [UInt8] = [UInt8(byte & 0xFF)]
        let edited: String? = LabSegmentEditor.replacing(base, offset: field.offset, count: 1, with: bytes,
                                                         lengthByteOffset: nil)
        applySegmentEdit(ctx, edited, seg.segment.title, seg.index, base)
        reopenField(ctx, seg.index, field)
    }

    /// A 6-bit RGB channel (byte = level × 2): levels 0, 8 … 56, 63, each with a swatch of the
    /// colour it makes with the other two channels; then MANUAL VALUE.
    fileprivate static func rgbRows(_ ctx: VFDContext, _ seg: LabSegmentEditor.EditableSegment,
                                    _ field: LabSegmentEditor.Field, _ base: String) -> VFDLabMenuRows {
        let title: String = seg.segment.title
        let index: Int = seg.index
        let level: Int = channelLevel(field)
        var levels: [Int] = []
        var position: Int = -1
        for f in seg.fields where f.kind == LabSegmentEditor.FieldKind.rgbChannel {
            if f.offset == field.offset {
                position = levels.count
            }
            levels.append(channelLevel(f))
        }
        let steps: [Int] = [0, 8, 16, 24, 32, 40, 48, 56, 63]
        var items: [VFDMenuItem] = []
        var current: Int? = nil
        for v in steps {
            let byte: UInt8 = UInt8((v << 1) & 0xFE)
            let isCurrent: Bool = v == level
            if isCurrent && current == nil {
                current = items.count
            }
            var swatch: VFDRGB? = nil
            if levels.count == 3 && position >= 0 && position < 3 {
                var mix: [Int] = levels
                mix[position] = v
                swatch = VFDRGB(mix[0] * 255 / 63, mix[1] * 255 / 63, mix[2] * 255 / 63)
            }
            let head: String = "\(v) of 63 · " + DisneyTlv.hex2(Int(byte))
            let label: String = menuLabel(ctx, head, isCurrent ? " ✓" : "", swatch: swatch != nil)
            items.append(VFDMenuItem(label, rgb: swatch, action: {
                let edited: String? = LabSegmentEditor.replacing(base, offset: field.offset, count: 1, with: [byte],
                                                                 lengthByteOffset: nil)
                VFDLabScreen.applySegmentEdit(ctx, edited, title, index, base)
            }))
        }
        items.append(VFDMenuItem("MANUAL VALUE (0–63)…", action: {
            VFDLabScreen.promptLevel(ctx, seg, field, base, String(level))
        }))
        return VFDLabMenuRows(items: items, current: current)
    }

    /// MANUAL VALUE: a channel level typed as a number 0–63.
    fileprivate static func promptLevel(_ ctx: VFDContext, _ seg: LabSegmentEditor.EditableSegment,
                                        _ field: LabSegmentEditor.Field, _ base: String, _ text: String) {
        let title: String = seg.segment.title
        let index: Int = seg.index
        let message: String = "0–63. The byte sent is the value × 2. Now \(channelLevel(field))."
        ctx.prompt(title: "MANUAL VALUE · " + VFDW.upper(field.title), message: message, text: text,
                   keyboard: .number) { (typed: String) -> Void in
            let trimmed: String = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let v = Int(trimmed), v >= 0, v <= 63 else {
                ctx.confirm(title: "NOT APPLIED", message: "Type a whole number from 0 to 63.",
                            confirmLabel: "TRY AGAIN") {
                    VFDLabScreen.promptLevel(ctx, seg, field, base, typed)
                }
                return
            }
            let bytes: [UInt8] = [UInt8((v << 1) & 0xFE)]
            let edited: String? = LabSegmentEditor.replacing(base, offset: field.offset, count: 1, with: bytes,
                                                             lengthByteOffset: nil)
            VFDLabScreen.applySegmentEdit(ctx, edited, title, index, base)
        }
    }

    /// MANUAL HEX for the whole block (field nil) or one field, checked by LabSegmentEditor: the
    /// right size, the chain still whole. A refusal says why and offers the prompt again with
    /// what was typed.
    fileprivate static func promptManual(_ ctx: VFDContext, _ seg: LabSegmentEditor.EditableSegment,
                                         _ field: LabSegmentEditor.Field?, _ base: String, _ text: String) {
        let title: String = seg.segment.title
        let index: Int = seg.index
        var name: String = title
        var hint: String = seg.manual.hint
        var now: String = manualCurrent(base, seg.manual)
        if let f = field {
            name = title + " · " + f.title
            hint = fieldHint(f)
            now = HexUtils.bytesToHex(f.current)
        }
        let message: String = hint + ". Now " + (now.isEmpty ? "empty" : now) + "."
        ctx.prompt(title: "MANUAL HEX · " + VFDW.upper(name), message: message, text: text,
                   keyboard: .hex) { (typed: String) -> Void in
            let result: LabSegmentEditor.ManualResult
            if let f = field {
                result = LabSegmentEditor.applyingManual(base, field: f, typed: typed)
            } else {
                result = LabSegmentEditor.applyingManual(base, segment: seg, typed: typed)
            }
            switch result {
            case .applied(let edited):
                VFDLabScreen.applySegmentEdit(ctx, edited, title, index, base)
            case .invalid(let why):
                ctx.confirm(title: "NOT APPLIED", message: why, confirmLabel: "TRY AGAIN") {
                    VFDLabScreen.promptManual(ctx, seg, field, base, typed)
                }
            }
        }
    }

    /// The bytes a block's MANUAL HEX replaces, as they are in `base` (a record value as long as
    /// its length byte says).
    fileprivate static func manualCurrent(_ base: String, _ rule: LabSegmentEditor.ManualRule) -> String {
        let b: [UInt8] = HexUtils.hexToBytes(base)
        var n: Int = rule.maxBytes
        if let lo = rule.lengthByteOffset {
            if lo < 0 || lo >= b.count { return "" }
            n = Int(b[lo])
        }
        let start: Int = rule.offset
        if start < 0 || start > b.count || n <= 0 { return "" }
        let end: Int = min(b.count, start + n)
        return HexUtils.bytesToHex(Array(b[start..<end]))
    }

    fileprivate static func fieldHint(_ field: LabSegmentEditor.Field) -> String {
        if field.lengthByteOffset != nil { return "0–255 bytes; the length byte follows" }
        if field.count == 1 { return "1 byte (2 hex digits)" }
        return "\(field.count) bytes (\(field.count * 2) hex digits)"
    }

    /// "1 BYTE", "3 BYTES", "0–255 BYTES".
    fileprivate static func sizeWords(_ minBytes: Int, _ maxBytes: Int) -> String {
        if minBytes != maxBytes { return "\(minBytes)–\(maxBytes) BYTES" }
        return minBytes == 1 ? "1 BYTE" : "\(minBytes) BYTES"
    }

    fileprivate static func firstByte(_ field: LabSegmentEditor.Field) -> Int {
        guard let b = field.current.first else { return 0 }
        return Int(b)
    }

    /// A 6-bit RGB channel's level (the byte is the level shifted left one bit).
    fileprivate static func channelLevel(_ field: LabSegmentEditor.Field) -> Int {
        return (firstByte(field) >> 1) & 0x3F
    }

    /// Timing captions in menu rows: "on for ~21 s, 2 s fade-out" -> "~21 s, 2 s fade".
    fileprivate static func compactCaption(_ s: String) -> String {
        let shorter: String = s.replacingOccurrences(of: "on for ~", with: "~")
        return shorter.replacingOccurrences(of: " fade-out", with: " fade")
    }

    /// A menu label in capitals that keeps `tail` (" →", " ✓") when the row is too narrow for all
    /// of it: the head is cut with "…" instead. `swatch`: the row starts with a colour swatch.
    /// Widths follow the menu's rows (VFDW.panelInner, VFDW.button, the swatch row's label).
    fileprivate static func menuLabel(_ ctx: VFDContext, _ head: String, _ tail: String,
                                      swatch: Bool = false) -> String {
        let inner: Int = ctx.L.width - 8
        let room: Int = swatch ? inner - 5 - 2 * VFDW.adv : inner - 4
        let upperHead: String = VFDW.upper(head)
        let whole: String = upperHead + tail
        if VFDText.width(whole) <= room { return whole }
        let headRoom: Int = room - VFDText.width(tail) - 1
        return VFDText.fit(upperHead, max(0, headRoom)) + tail
    }

    /// ← BACK: the block's menu again, on the builder's packet as it is now.
    fileprivate static func reopenSegment(_ ctx: VFDContext, _ index: Int) {
        let base: String = HexUtils.canonicalHex(resolve(ctx).built)
        if base.isEmpty { return }
        guard let seg = editable(ctx, base, index) else { return }
        segmentMenu(ctx, seg, base)
    }

    /// The field's menu again after an edit, found by kind and position in the new packet.
    fileprivate static func reopenField(_ ctx: VFDContext, _ index: Int, _ field: LabSegmentEditor.Field) {
        let base: String = HexUtils.canonicalHex(resolve(ctx).built)
        if base.isEmpty { return }
        guard let seg = editable(ctx, base, index) else { return }
        for f in seg.fields where f.kind == field.kind && f.offset == field.offset {
            fieldMenu(ctx, seg, f, base)
            return
        }
    }

    /// A block edit (LabBuilderPanel.applySegmentEdit): the builder takes the edited packet as its
    /// own state (Raw Hex, byte-for-byte, when no builder type makes it), and the usual change
    /// path puts it in the preview, the hex field and the store. Ignored when the builder's packet
    /// is no longer the one the menu was opened on. The block stays selected while the anatomy
    /// keeps its shape; UNDO EDIT remembers the packet before.
    fileprivate static func applySegmentEdit(_ ctx: VFDContext, _ edited: String?, _ title: String, _ index: Int,
                                             _ base: String) {
        guard let next = edited else { return }
        let target: String = HexUtils.canonicalHex(next)
        if target == base || target.isEmpty { return }
        let ui: VFDUIState = labUI(ctx)
        let current: String = HexUtils.canonicalHex(resolve(ctx).built)
        if current != base { return }
        guard let decoded = LabSegmentEditor.builderState(target, extended: extendedOn(ui)) else { return }
        let oldSegments: [DisneyTlv.Segment] = DisneyTlv.anatomy(base)
        let oldCount: Int = oldSegments.count
        // The block's title in the edited packet ("Tail · buzz 3" after picking B3 on "Tail · no
        // buzz"), or the old one when the edit changed the block layout.
        var shown: String = title
        let newSegments: [DisneyTlv.Segment] = DisneyTlv.anatomy(target)
        if newSegments.count == oldCount && index >= 0 && index < oldCount
            && newSegments[index].kind == oldSegments[index].kind {
            shown = newSegments[index].title
        }
        let named: String = shown
        userEdit(ctx) { (s: inout VFDLabState) -> Void in
            let before: LabPacketBuilder.LabPacketType = s.type
            VFDLabScreen.applyDecoded(&s, decoded)
            s.ledMask = 7
            if decoded.type == before {
                s.loadMsg = "Edited " + named
            } else {
                s.loadMsg = "Edited " + named + " — builder now " + decoded.type.label + " (keeps every byte)"
            }
        }
        let after: String = resolve(ctx).built
        ui.setString(VFDLabKeys.segmentUndo, base)
        ui.setString(VFDLabKeys.segmentUndoTo, after)
        reselect(ui, index, after, oldCount)
    }

    /// UNDO EDIT: the packet before the last block edit, back in the builder the same way.
    fileprivate static func undoSegmentEdit(_ ctx: VFDContext) {
        let ui: VFDUIState = labUI(ctx)
        let previous: String = ui.string(VFDLabKeys.segmentUndo)
        let edited: String = ui.string(VFDLabKeys.segmentUndoTo)
        ui.remove(VFDLabKeys.segmentUndo)
        ui.remove(VFDLabKeys.segmentUndoTo)
        let current: String = resolve(ctx).built
        if previous.isEmpty || current.isEmpty || current != edited { return }
        guard let decoded = LabSegmentEditor.builderState(previous, extended: extendedOn(ui)) else { return }
        let selected: Int? = selectedSegment(ui, current)
        let oldCount: Int = DisneyTlv.anatomy(current).count
        userEdit(ctx) { (s: inout VFDLabState) -> Void in
            VFDLabScreen.applyDecoded(&s, decoded)
            s.ledMask = 7
            s.loadMsg = "Undid the last block edit"
        }
        let after: String = resolve(ctx).built
        if let index = selected {
            reselect(ui, index, after, oldCount)
        }
    }

    /// Keep block `index` selected on the new packet when its anatomy has as many blocks as
    /// before; otherwise nothing is selected.
    fileprivate static func reselect(_ ui: VFDUIState, _ index: Int, _ after: String, _ oldCount: Int) {
        clearFieldAbout(ui)
        ui.setString(VFDLabKeys.segmentHex, after)
        if !after.isEmpty && DisneyTlv.anatomy(after).count == oldCount {
            ui.setInt(VFDLabKeys.segment, index)
        } else {
            ui.setInt(VFDLabKeys.segment, -1)
            ui.setBool(VFDLabKeys.segmentAbout, false)
        }
    }
}

// MARK: - Model

extension VFDLabScreen {
    fileprivate static func makeModel(_ ctx: VFDContext) -> VFDLabModel {
        let ui: VFDUIState = labUI(ctx)
        let st: VFDLabState = resolve(ctx)
        let built: String = st.built
        let segments: [DisneyTlv.Segment] = built.isEmpty ? [] : DisneyTlv.anatomy(built)
        let selected: Int? = selectedSegment(ui, built)
        var about: LabSegmentEditor.About? = nil
        if let sel = selected, sel < segments.count {
            about = LabSegmentEditor.about(built, index: sel)
        }
        let undoTo: String = ui.string(VFDLabKeys.segmentUndoTo)
        let undoAvailable: Bool = ui.has(VFDLabKeys.segmentUndo) && !undoTo.isEmpty && undoTo == built
        let classified: ClassifiedPacket? = MagicClassifier.classify(HexUtils.canonicalHex(st.hex))
        let intervalDragging: Bool = ui.bool(VFDLabKeys.intervalDrag)
        let interval: Double = intervalValue(ctx)
        return VFDLabModel(
            ui: ui,
            state: st,
            built: built,
            extended: extendedOn(ui),
            summary: LabPacketSummary(built),
            segments: segments,
            selectedSegment: selected,
            segmentAbout: about,
            aboutOpen: ui.bool(VFDLabKeys.segmentAbout),
            fieldAboutTitle: ui.string(VFDLabKeys.segmentFieldTitle),
            fieldAbout: ui.string(VFDLabKeys.segmentFieldAbout),
            undoAvailable: undoAvailable,
            classified: classified,
            bytes: LabPacketTools.toBytes(st.hex),
            reject: HexUtils.legacyAdvertiseRejectReason(st.hex),
            presets: sortedPresets(ctx.store),
            pingHex: ui.string(VFDLabKeys.ping, default: PacketBuilder.wakeupPing),
            inspectorOpen: ui.bool(VFDLabKeys.inspector),
            themesCollapsed: ui.storedBool(VFDLabKeys.themesCollapsed, default: true),
            intervalMs: interval,
            intervalDragging: intervalDragging,
            intervalDraft: ui.double(VFDLabKeys.intervalDraft, default: interval),
            token: ui.string(VFDLabKeys.token)
        )
    }

    /// The user presets by label, ignoring case; equal labels keep the library's order. The Lab
    /// draws twice per frame at 30 fps while its preview animates, so the order is sorted again
    /// only when the presets differ from the last ones sorted (a memo; nothing is redrawn).
    fileprivate static func sortedPresets(_ store: MagicStore) -> [MagicPacket] {
        let list: [MagicPacket] = store.customPresets
        let memo: VFDLabPresetOrder = VFDLabPresetOrder.shared
        if memo.valid && memo.source == list {
            return memo.sorted
        }
        let lowered: [String] = list.map { (packet: MagicPacket) -> String in packet.label.lowercased() }
        let order: [Int] = Array(list.indices).sorted { (a: Int, b: Int) -> Bool in
            let left: String = lowered[a]
            let right: String = lowered[b]
            if left != right {
                return left.utf16.lexicographicallyPrecedes(right.utf16)
            }
            return a < b
        }
        let sorted: [MagicPacket] = order.map { (index: Int) -> MagicPacket in list[index] }
        memo.source = list
        memo.sorted = sorted
        memo.valid = true
        return sorted
    }
}

/// The last `sortedPresets` result and the presets it was sorted from.
@MainActor
private final class VFDLabPresetOrder {
    static let shared: VFDLabPresetOrder = VFDLabPresetOrder()

    var source: [MagicPacket] = []
    var sorted: [MagicPacket] = []
    var valid: Bool = false

    init() {}
}

// MARK: - Pinned band preview

extension VFDLabScreen {
    /// BandPreviewView: the face on the left with its LEDs in true colour at ctx.time, the text
    /// column beside it (the shorter of the two centred on the other), then the divider. Returns
    /// the divider row.
    fileprivate static func bandPreview(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ c: Int, _ y: Int, _ w: Int,
                                        _ hex: String) -> Int {
        let model: BandEffectModel = BandEffectModel.from(hex)
        let face: Int = VFDLabGeo.face
        let tx: Int = c + face + 8
        let tw: Int = c + w - tx
        let lines: [VFDLabLine] = previewLines(model, tw, ctx.time)
        let textH: Int = (lines.count - 1) * VFDW.line + 7
        let top: Int = y + 1
        let faceTop: Int = top + max(0, VFDMath.floorDiv(textH - face, 2))
        let textTop: Int = top + max(0, VFDMath.floorDiv(face - textH, 2))
        bandFace(fb, c, faceTop, model, ctx.time)
        if animates(model) {
            fb.wantsAnimation = true
        }
        var r: Int = textTop
        for line in lines {
            if line.isLegend {
                drawLegend(fb, line.legend, tx, r, tw)
            } else {
                fb.textFit(tx, r, line.text, tw, .small, line.color)
            }
            r += VFDW.line
        }
        let bottom: Int = top + max(textH, face)
        let div: Int = bottom + 3
        fb.hline(c, div, w, VFDInk.dim)
        return div
    }

    /// BandPreviewView's text column (non-compact) plus the colour legend.
    fileprivate static func previewLines(_ model: BandEffectModel, _ tw: Int, _ time: Double) -> [VFDLabLine] {
        var out: [VFDLabLine] = []
        out.append(VFDLabLine(text: "BAND PREVIEW", color: VFDInk.dim, legend: [], isLegend: false))
        let none: Bool = model.kind == BandEffectModel.Kind.none
        if none {
            out.append(VFDLabLine(text: "NO EFFECT", color: VFDInk.dim, legend: [], isLegend: false))
        } else {
            let kind: String = BandLedAnimation.kindName(model.kind)
            out.append(VFDLabLine(text: kind, color: VFDInk.highlight, legend: [], isLegend: false))
        }
        let suffix: String = model.approximate ? " · APPROX." : ""
        let noteText: String = VFDW.upper(model.note) + suffix
        let noteColor: UInt8 = model.approximate ? VFDInk.text : VFDInk.dim
        for ln in VFDLabText.wrapLines(noteText, tw, maxLines: 2) {
            out.append(VFDLabLine(text: ln, color: noteColor, legend: [], isLegend: false))
        }
        if model.durationMs > 0 || model.alwaysOn {
            var dur: String = "ALWAYS ON"
            if !model.alwaysOn {
                dur = "~" + String(model.durationMs / 1000) + "S"
                if model.fadeMs > 0 {
                    dur += " · " + String(model.fadeMs / 1000) + "S FADE"
                }
            }
            out.append(VFDLabLine(text: dur, color: VFDInk.dim, legend: [], isLegend: false))
        }
        if model.buzz > 0 {
            var name: String = "#" + String(model.buzz)
            for pattern in LabPacketBuilder.vibrationPatterns where pattern.id == model.buzz {
                name = pattern.label
                break
            }
            let on: Bool = VFDColors.buzzOn(time)
            let text: String = "BUZZ · " + VFDW.upper(name)
            out.append(VFDLabLine(text: text, color: on ? VFDInk.highlight : VFDInk.dim, legend: [], isLegend: false))
        }
        if !none && model.kind != BandEffectModel.Kind.ping {
            let items: [VFDLabLegend] = legend(model)
            if !items.isEmpty {
                out.append(VFDLabLine(text: "", color: VFDInk.text, legend: items, isLegend: true))
            }
        }
        return out
    }

    /// Whether the preview changes over time (BandLedAnimation moves the LEDs, or BUZZ blinks).
    fileprivate static func animates(_ model: BandEffectModel) -> Bool {
        if model.buzz > 0 { return true }
        switch model.kind {
        case .none, .ping, .dual:
            return false
        case .rainbow:
            let full: Bool = model.perLed.allSatisfy({ (v: Int?) -> Bool in v != nil })
            return model.note.contains("cycle") && full
        default:
            return true
        }
    }

    /// The band's square face (dim, rounded corners) with its five round LED zones in their true
    /// colour at `time`; an off zone is a dotted dim ring.
    fileprivate static func bandFace(_ fb: VFDFrameBuffer, _ x: Int, _ y: Int, _ model: BandEffectModel,
                                     _ time: Double) {
        let face: Int = VFDLabGeo.face
        let e: Int = face - 1
        fb.hline(x + 4, y, face - 8, VFDInk.dim)
        fb.hline(x + 4, y + e, face - 8, VFDInk.dim)
        fb.vline(x, y + 4, face - 8, VFDInk.dim)
        fb.vline(x + e, y + 4, face - 8, VFDInk.dim)
        let corners: [(Int, Int)] = [(2, 1), (3, 1), (1, 2), (1, 3)]
        for corner in corners {
            let dx: Int = corner.0
            let dy: Int = corner.1
            fb.set(x + dx, y + dy, VFDInk.dim)
            fb.set(x + e - dx, y + dy, VFDInk.dim)
            fb.set(x + dx, y + e - dy, VFDInk.dim)
            fb.set(x + e - dx, y + e - dy, VFDInk.dim)
        }
        let size: Int = VFDLabGeo.led
        var z: Int = 0
        for spot in VFDLabGeo.zoneSpot {
            let lx: Int = x + VFDLabGeo.ledAt[spot.c]
            let ly: Int = y + VFDLabGeo.ledAt[spot.r]
            if let rgb = VFDColors.bandLED(model, zone: z, time: time) {
                VFDW.led(fb, lx, ly, 0, size: size, fill: rgb)
            } else {
                VFDW.led(fb, lx, ly, nil, size: size)
            }
            z += 1
        }
    }

    /// The colour names of Z1..Z5 (palette names, first-appearance order) with their true colour,
    /// then OFF when a zone is unlit. A custom RGB effect names its #RRGGBB.
    fileprivate static func legend(_ model: BandEffectModel) -> [VFDLabLegend] {
        if model.kind == BandEffectModel.Kind.rgb {
            let v: Int = model.rgb ?? 0x9E9E9E
            let rgb: VFDRGB = VFDColors.rgb(packed: v)
            return [VFDLabLegend(rgb: rgb, name: rgb.hex)]
        }
        var out: [VFDLabLegend] = []
        var seen: Set<String> = []
        var anyOff: Bool = false
        for z in 0..<5 {
            let index: Int? = z < model.perLed.count ? model.perLed[z] : nil
            guard let idx = index else {
                anyOff = true
                continue
            }
            let name: String = StarlightColors.nameFor(idx)
            if name.lowercased() == "off" {
                anyOff = true
                continue
            }
            let key: String = VFDW.upper(name)
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(VFDLabLegend(rgb: VFDColors.starlightGlow(idx), name: key))
        }
        if anyOff {
            out.append(VFDLabLegend(rgb: nil, name: "OFF"))
        }
        return out
    }

    fileprivate static func swatchLED(_ fb: VFDFrameBuffer, _ x: Int, _ y: Int, _ rgb: VFDRGB?) {
        if let colour = rgb {
            VFDW.led(fb, x, y, 0, size: VFDLabGeo.swatch, fill: colour)
        } else {
            VFDW.led(fb, x, y, nil, size: VFDLabGeo.swatch)
        }
    }

    /// Swatch + colour name, as many as fit in [tx, tx + tw).
    fileprivate static func drawLegend(_ fb: VFDFrameBuffer, _ items: [VFDLabLegend], _ tx: Int, _ r: Int,
                                       _ tw: Int) {
        let sw: Int = VFDLabGeo.swatch
        let limit: Int = tx + tw
        var x: Int = tx
        for item in items {
            let need: Int = sw + 3 + VFDText.width(item.name)
            if x + need > limit {
                let short: String = String(item.name.prefix(1)) + VFDText.ellipsis
                if x + sw + 3 + VFDText.width(short) <= limit {
                    swatchLED(fb, x, r, item.rgb)
                    fb.textFit(x + sw + 3, r, item.name, limit - x - sw - 3, .small, VFDInk.text)
                }
                break
            }
            swatchLED(fb, x, r, item.rgb)
            let color: UInt8 = item.rgb == nil ? VFDInk.dim : VFDInk.text
            x = fb.text(x + sw + 3, r, item.name, .small, color) + 6
        }
    }
}

// MARK: - Scrolling body

extension VFDLabScreen {
    /// The body in screen rows [top, top + view), scrolled by its own region, a line cut by either
    /// edge hidden (lab.py snapped_window), the taps the edges cut dropped, its scroll indicator.
    fileprivate static func bodyWindow(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ m: VFDLabModel,
                                       _ c: Int, _ top: Int, _ view: Int, _ w: Int) {
        let y0: Int = top + 4
        var off: Int = max(0, ctx.scroll(VFDLabKeys.region))
        var probe: (buf: VFDFrameBuffer, end: Int) = probeBody(ctx, fb, L, m, c, y0, w, off)
        let total: Int = probe.end - top
        let limit: Int = max(0, total - view)
        if off > limit {
            off = limit
            probe = probeBody(ctx, fb, L, m, c, y0, w, off)
        }
        let win: (top: Int, bottom: Int) = snapWindow(probe.buf, top: top, bottom: top + view)
        fb.pushClip(0, top, fb.cols, view, dy: -off)
        fb.pushClip(0, win.top - fb.originY, fb.cols, max(0, win.bottom - win.top))
        let firstTap: Int = fb.taps.count
        _ = body(ctx, fb, L, m, c, y0, w)
        fb.popClip()
        fb.popClip()
        dropShortTaps(fb, from: firstTap)
        registerRegion(fb, VFDLabKeys.region, top: top, h: view, limit: limit)
        VFDW.listScrollbar(fb, top, view, total, off)
    }

    /// The body drawn unclipped on a scratch buffer scrolled by `off`. Returns it and the end row.
    fileprivate static func probeBody(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ m: VFDLabModel,
                                      _ c: Int, _ y0: Int, _ w: Int, _ off: Int) -> (buf: VFDFrameBuffer, end: Int) {
        let buf: VFDFrameBuffer = VFDFrameBuffer(cols: fb.cols, rows: fb.rows, alarmInverted: fb.alarmInverted)
        buf.base = fb.base
        buf.pushClip(0, 0, fb.cols, fb.rows, dy: fb.originY - off)
        let end: Int = body(ctx, buf, L, m, c, y0, w)
        while buf.clipDepth > 0 {
            buf.popClip()
        }
        return (buf: buf, end: end)
    }

    /// Rows (top, bottom) the body may use: while some column is lit on both sides of an edge (a
    /// glyph stroke, a control's side; runs of 40 rows or more excepted) the edge moves inward.
    fileprivate static func snapWindow(_ probe: VFDFrameBuffer, top: Int, bottom: Int) -> (top: Int, bottom: Int) {
        let cols: Int = probe.cols
        let rows: Int = probe.rows
        let cells: [UInt8] = probe.cells
        func lit(_ x: Int, _ r: Int) -> Bool {
            if r < 0 || r >= rows { return false }
            return cells[r * cols + x] != 0
        }
        func run(_ x: Int, _ r: Int) -> Int {
            var a: Int = r
            while lit(x, a - 1) {
                a -= 1
            }
            var b: Int = r
            while lit(x, b + 1) {
                b += 1
            }
            return b - a + 1
        }
        func crossed(_ k: Int) -> Bool {
            var x: Int = 0
            while x < cols {
                if lit(x, k - 1) && lit(x, k) && run(x, k) < 40 {
                    return true
                }
                x += 1
            }
            return false
        }
        var t: Int = top
        var b: Int = bottom
        while t < b && crossed(t) {
            t += 1
        }
        while b > t && crossed(b) {
            b -= 1
        }
        return (top: t, bottom: b)
    }

    fileprivate static func dropShortTaps(_ fb: VFDFrameBuffer, from start: Int) {
        if start < 0 || start >= fb.taps.count { return }
        var kept: [VFDHit] = Array(fb.taps[0..<start])
        for tp in fb.taps[start...] where tp.h >= VFDW.tapRows {
            kept.append(tp)
        }
        fb.taps = kept
    }

    /// A scroll region over screen rows [top, top + h) whose drag limit is `limit` rows, even when
    /// the page window cuts the region shorter. Nothing when it cannot scroll.
    fileprivate static func registerRegion(_ fb: VFDFrameBuffer, _ id: String, top: Int, h: Int, limit: Int) {
        let clip: (c: Int, r: Int, w: Int, h: Int) = fb.clipRect
        let oy: Int = fb.originY
        let r0: Int = max(top + oy, clip.r)
        let r1: Int = min(top + h + oy, clip.r + clip.h)
        let shown: Int = max(0, r1 - r0)
        if shown <= 0 || limit <= 0 { return }
        fb.scrollRegion(id: id, 0, top, fb.cols, h, contentRows: limit + shown)
    }

    /// Everything in the Lab's ScrollView. Returns the next free row.
    fileprivate static func body(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ m: VFDLabModel,
                                 _ c: Int, _ y: Int, _ w: Int) -> Int {
        var r: Int = builderGroup(ctx, fb, L, m, c, y, w)
        r = editGroup(ctx, fb, L, m, c, r, w)
        return extrasGroup(ctx, fb, L, m, c, r, w)
    }
}

// MARK: - Pieces

extension VFDLabScreen {
    /// LabScreenDivider: a solid dim rule with 3 empty rows each side. Returns the next row.
    fileprivate static func hairline(_ fb: VFDFrameBuffer, _ c: Int, _ y: Int, _ w: Int) -> Int {
        fb.hline(c, y + 3, w, VFDInk.dim)
        return y + 7
    }

    /// Text lines `line` rows apart. Returns the row after the last line (+ gap).
    fileprivate static func linesBlock(_ fb: VFDFrameBuffer, _ c: Int, _ y: Int, _ lines: [String],
                                       _ color: UInt8) -> Int {
        var r: Int = y
        for ln in lines {
            fb.text(c, r, ln, .small, color)
            r += VFDW.line
        }
        return lines.isEmpty ? r : r + VFDW.gap
    }

    /// techLabel(9) text wrapped full width, as given. Returns the next free row.
    fileprivate static func note(_ fb: VFDFrameBuffer, _ c: Int, _ y: Int, _ w: Int, _ s: String,
                                 _ color: UInt8 = VFDInk.dim) -> Int {
        return linesBlock(fb, c, y, VFDLabText.wrap(s, w), color)
    }

    /// chevron.up.chevron.down beside small caps at row r: 5 x 7 cells.
    fileprivate static func updown(_ fb: VFDFrameBuffer, _ c: Int, _ r: Int, _ color: UInt8) {
        for i in 0..<3 {
            fb.hline(c + 2 - i, r + i, 1 + 2 * i, color)
            fb.hline(c + 2 - i, r + 6 - i, 1 + 2 * i, color)
        }
    }

    fileprivate static func trash(_ fb: VFDFrameBuffer, _ c: Int, _ r: Int, _ color: UInt8) {
        var j: Int = 0
        for row in VFDLabGeo.trash {
            var i: Int = 0
            for ch in row {
                if ch == "#" {
                    fb.set(c + i, r + j, color)
                }
                i += 1
            }
            j += 1
        }
    }

    /// LabPalettePicker at (x, y): a dim-bordered button "LABEL: VALUE" in highlight (a palette
    /// value with its true-colour swatch first) and a dim up/down chevron, hugging its text; a tap
    /// opens the options. Returns the end column.
    @discardableResult
    fileprivate static func pickerAt(_ fb: VFDFrameBuffer, _ x: Int, _ y: Int, _ maxW: Int, _ label: String,
                                     _ value: String, enabled: Bool = true, action: @escaping () -> Void) -> Int {
        let swatch: VFDRGB? = VFDLabOptions.swatch(value)
        let sw: Int = swatch != nil ? 9 : 0
        var s: String = VFDW.upper(label) + ": " + VFDW.upper(value)
        s = VFDText.fit(s, maxW - 21 - sw)
        let bw: Int = 6 + sw + VFDText.width(s) + 4 + 5 + 6
        fb.box(x, y, bw, VFDW.ctrlH, VFDInk.dim)
        if let rgb = swatch {
            fb.fill(x + 6, y + VFDW.ctrlText + 1, 5, 5, fb.rgb(rgb))
        }
        let ink: UInt8 = enabled ? VFDInk.highlight : VFDInk.dim
        let end: Int = fb.text(x + 6 + sw, y + VFDW.ctrlText, s, .small, ink)
        updown(fb, end + 3, y + VFDW.ctrlText, VFDInk.dim)
        if enabled {
            VFDW.tap(fb, x, y, bw, VFDW.ctrlH, "picker:" + VFDW.upper(label), action: action)
        }
        return x + bw
    }

    /// A picker on its own row. Returns the next free row.
    fileprivate static func pickerRow(_ fb: VFDFrameBuffer, _ c: Int, _ y: Int, _ w: Int, _ label: String,
                                      _ value: String, action: @escaping () -> Void) -> Int {
        pickerAt(fb, c, y, w, label, value, action: action)
        return y + VFDW.ctrlH + VFDW.gap
    }

    /// A Lab switch row: the title with the ON/OFF switch on the right, the description wrapped
    /// full width under it in dim. Returns the next free row.
    fileprivate static func toggleBlock(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ y: Int, _ w: Int,
                                        _ title: String, _ on: Bool, _ detail: String, titleColor: UInt8,
                                        enabled: Bool, action: @escaping () -> Void) -> Int {
        var r: Int = VFDW.toggle(fb, L, c, y, w, title, on, enabled: enabled, name: "toggle:" + VFDW.upper(title),
                                 labelColor: titleColor, action: action)
        r -= VFDW.gap - 1
        return linesBlock(fb, c, r, VFDLabText.wrap(detail, w), VFDInk.dim)
    }

    /// framingToggle: the switch first (left), the title beside it, the detail wrapped full width
    /// under them in dim. Returns the next free row.
    fileprivate static func framingToggle(_ fb: VFDFrameBuffer, _ L: VFDLayout, _ c: Int, _ y: Int, _ w: Int,
                                          _ title: String, _ on: Bool, _ detail: String,
                                          action: @escaping () -> Void) -> Int {
        let name: String = "toggle:" + VFDW.upper(title)
        VFDW.toggle(fb, L, c, y, VFDW.switchW, "", on, name: name, action: action)
        let tx: Int = c + VFDW.switchW + 6
        let tlines: [String] = VFDLabText.titleLines(VFDW.upper(title), c + w - tx)
        var i: Int = 0
        for ln in tlines {
            fb.text(tx, y + VFDW.ctrlText + i * VFDW.line, ln, .small, VFDInk.text)
            i += 1
        }
        VFDW.tap(fb, c, y, w, VFDW.ctrlH, name, action: action)
        let textRows: Int = VFDW.ctrlText + tlines.count * VFDW.line
        let r: Int = y + max(VFDW.ctrlH + 1, textRows)
        return linesBlock(fb, c, r, VFDLabText.wrap(detail, w), VFDInk.dim)
    }

    /// A cyanDim bordered button: dim border, text label. Returns its end column.
    @discardableResult
    fileprivate static func ghostButton(_ fb: VFDFrameBuffer, _ c: Int, _ y: Int, _ label: String,
                                        action: @escaping () -> Void) -> Int {
        let s: String = VFDW.upper(label)
        let bw: Int = VFDText.width(s) + 12
        fb.box(c, y, bw, VFDW.ctrlH, VFDInk.dim)
        fb.text(c + 6, y + VFDW.ctrlText, s, .small, VFDInk.text)
        VFDW.tap(fb, c, y, bw, VFDW.ctrlH, "button:" + s, action: action)
        return c + bw
    }

    /// Anatomy block tone (labSegmentColor): cyan -> highlight, amber -> text, others dim, red alarm.
    fileprivate static func segmentInk(_ kind: DisneyTlv.SegmentKind) -> UInt8 {
        switch kind {
        case .company: return VFDInk.dim
        case .channel: return VFDInk.text
        case .ping: return VFDInk.text
        case .effectHead: return VFDInk.highlight
        case .header: return VFDInk.dim
        case .color: return VFDInk.highlight
        case .data: return VFDInk.dim
        case .tail: return VFDInk.dim
        case .wand: return VFDInk.highlight
        case .beacon: return VFDInk.dim
        case .other: return VFDInk.dim
        case .error: return VFDInk.alarm
        }
    }

    fileprivate static func paletteIndex(_ segmentHex: String) -> Int {
        return (Int(segmentHex, radix: 16) ?? 0) & 0x1F
    }
}

// MARK: - Builder group

extension VFDLabScreen {
    fileprivate static func builderGroup(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ m: VFDLabModel,
                                         _ c: Int, _ top: Int, _ w: Int) -> Int {
        var y: Int = modeBar(ctx, fb, L, m, c, top, w)
        y = hairline(fb, c, y - 1, w)
        y = VFDW.section(fb, L, c, y - (VFDW.sectionGap - VFDW.gap) + 3, w, "PACKET BUILDER")
        y = note(fb, c, y, w, VFDLabCopy.builderIntro)
        y = typeSection(ctx, fb, L, m, c, y, w)
        y = summaryCard(fb, m.summary, c, y + 2, w, hex: m.built)
        y = typeFields(ctx, fb, L, m, c, y, w)
        if LabPacketBuilder.framingApplies(m.state.type) {
            y = framingSection(ctx, fb, L, m, c, y, w)
        }
        if !m.built.isEmpty {
            y = anatomy(ctx, fb, L, m, c, y, w)
        }
        return builderActions(ctx, fb, L, m, c, y + 2, w)
    }

    /// LabModeBar: Standard / Extended, keep-awake, the PING picker.
    fileprivate static func modeBar(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ m: VFDLabModel,
                                    _ c: Int, _ top: Int, _ w: Int) -> Int {
        var y: Int = top
        let toggleMode: () -> Void = { VFDLabScreen.toggleExtended(ctx) }
        if m.extended {
            y = toggleBlock(fb, L, c, y, w, "EXTENDED · EXPERIMENTAL", true, VFDLabCopy.extendedDetail,
                            titleColor: VFDInk.text, enabled: true, action: toggleMode)
        } else {
            y = toggleBlock(fb, L, c, y, w, "STANDARD · KNOWN & TESTED", false, VFDLabCopy.standardDetail,
                            titleColor: VFDInk.highlight, enabled: true, action: toggleMode)
        }
        let awake: Bool = ctx.vm.keepAwakeActive
        let detail: String = awake ? VFDLabCopy.awakeOnDetail : VFDLabCopy.awakeOffDetail
        let canToggle: Bool = ctx.vm.remoteLinkReady || awake
        y = toggleBlock(fb, L, c, y, w, "KEEP BAND AWAKE", awake, detail,
                        titleColor: awake ? VFDInk.highlight : VFDInk.text, enabled: canToggle,
                        action: { VFDLabScreen.toggleKeepAwake(ctx) })
        if awake || m.extended {
            let selected: Int = m.pingHex == VFDLabOptions.beaconPingHex ? 1 : 0
            let value: String = VFDLabOptions.name(VFDLabOptions.pings, selected)
            y = pickerRow(fb, c, y + 1, w, "PING", value, action: {
                VFDLabScreen.openPicker(ctx, "PING", VFDLabOptions.pings, selected, { (picked: Int) -> Void in
                    VFDLabScreen.pickPing(ctx, picked)
                })
            })
        }
        return y
    }

    /// WHAT DO YOU WANT THE BAND TO DO?, the type chips (wrapping), the blurb, the load message.
    fileprivate static func typeSection(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ m: VFDLabModel,
                                        _ c: Int, _ top: Int, _ w: Int) -> Int {
        var y: Int = VFDW.label(fb, L, c, top, w, "WHAT DO YOU WANT THE BAND TO DO?")
        let extended: Bool = m.extended
        let visible: [LabPacketBuilder.LabPacketType] = LabPacketBuilder.LabPacketType.allCases.filter {
            (type: LabPacketBuilder.LabPacketType) -> Bool in extended || !type.experimental
        }
        let labels: [String] = visible.map { (type: LabPacketBuilder.LabPacketType) -> String in type.label }
        let selected: Int? = visible.firstIndex(of: m.state.type)
        y = VFDW.options(fb, L, c, y, w, labels, selected: selected, name: "type", onSelect: { (index: Int) -> Void in
            if index < 0 || index >= visible.count { return }
            let picked: LabPacketBuilder.LabPacketType = visible[index]
            VFDLabScreen.userEdit(ctx) { (st: inout VFDLabState) -> Void in
                VFDLabScreen.selectType(&st, picked)
            }
        })
        y = note(fb, c, y + 1, w, m.state.type.blurb)
        if let msg = m.state.loadMsg {
            y = note(fb, c, y - VFDW.gap, w, msg, VFDInk.highlight)
        }
        return y
    }

    /// LabPacketSummaryCard: a 1-cell box in the tone colour around YOU ARE BUILDING, the headline
    /// (mid, tone), the colours (after true-colour swatches of the colours of `hex`, the packet
    /// the summary describes), the details (wrapped at " · ") and the reject reason (alarm).
    fileprivate static func summaryCard(_ fb: VFDFrameBuffer, _ s: LabPacketSummary, _ c: Int, _ top: Int,
                                        _ w: Int, hex: String) -> Int {
        var tone: UInt8 = VFDInk.highlight
        switch s.tone {
        case .known:
            tone = VFDInk.highlight
        case .unknown:
            tone = VFDInk.text
        case .invalid:
            tone = VFDInk.alarm
        }
        let ic: Int = c + 5
        let iw: Int = w - 10
        let y: Int = top + 1
        var r: Int = y + 4
        fb.text(ic, r, "YOU ARE BUILDING", .small, VFDInk.dim)
        r += VFDW.line + 1
        for ln in VFDLabText.midHeadline(VFDW.upper(s.headline), iw - 2) {
            if tone == VFDInk.alarm && fb.alarmInverted {
                let bw: Int = VFDText.width(ln, size: .mid) + 4
                fb.fill(ic - 2, r - 2, bw, 18, VFDInk.highlight)
                fb.text(ic, r, ln, .mid, VFDInk.unlit)
            } else {
                fb.text(ic, r, ln, .mid, tone)
            }
            r += 20
        }
        r -= 1
        if !s.colors.isEmpty {
            let swatches: [VFDRGB] = namedSwatches(hex, s.colors)
            swatchNames(fb, ic, r, swatches, VFDW.upper(s.colors), ic + iw, VFDInk.dim)
            r += VFDW.line
        }
        let parts: [String] = s.details.map { (d: String) -> String in VFDW.upper(d) }
        for ln in VFDLabText.sepLines(parts, iw) {
            fb.text(ic, r, ln, .small, VFDInk.dim)
            r += VFDW.line
        }
        if let reject = s.reject {
            for ln in VFDLabText.wrapLines(reject, iw - 4, maxLines: 2) {
                VFDW.alarmText(fb, ic, r, ln)
                r += VFDW.line
            }
        }
        let bottom: Int = r - VFDW.line + 7 + 4
        var border: UInt8 = VFDInk.highlight
        if tone == VFDInk.text {
            border = VFDInk.dim
        } else if tone == VFDInk.alarm {
            border = fb.alarmInverted ? VFDInk.highlight : VFDInk.alarm
        }
        fb.box(c, y, w, bottom - y + 1, border)
        return bottom + 1 + VFDW.gap
    }

    /// The fields of the chosen type (LabBuilderPanel.typeFields).
    fileprivate static func typeFields(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ m: VFDLabModel,
                                       _ c: Int, _ top: Int, _ w: Int) -> Int {
        switch m.state.type {
        case .raw:
            return rawFields(ctx, fb, L, m, c, top, w)
        case .ping:
            return note(fb, c, VFDW.groupTop(L, top), w, VFDLabCopy.pingFields)
        case .rgb:
            let y: Int = rgbFields(ctx, fb, L, m, c, top, w)
            return buzzRow(ctx, fb, L, m, c, y + 1, w)
        case .experiment:
            return experimentFields(ctx, fb, L, m, c, top, w)
        case .show:
            return showFields(ctx, fb, L, m, c, top, w)
        default:
            return standardFields(ctx, fb, L, m, c, top, w)
        }
    }

    /// LEDS (Extended single colour), the colour slots, the BUZZ row.
    fileprivate static func standardFields(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout,
                                           _ m: VFDLabModel, _ c: Int, _ top: Int, _ w: Int) -> Int {
        let st: VFDLabState = m.state
        var y: Int = top
        if m.extended && st.type == LabPacketBuilder.LabPacketType.preset {
            let mask: Int = st.ledMask
            let value: String = VFDLabOptions.name(LabPacketBuilder.ledMasks, mask)
            y = pickerRow(fb, c, VFDW.groupTop(L, y), w, "LEDS", value, action: {
                VFDLabScreen.openPicker(ctx, "LEDS", LabPacketBuilder.ledMasks, mask, { (picked: Int) -> Void in
                    VFDLabScreen.userEdit(ctx) { (s: inout VFDLabState) -> Void in
                        s.ledMask = picked
                    }
                })
            })
            y = note(fb, c, y + 1, w, VFDLabCopy.ledNote, VFDInk.text)
        }
        let slots: Int = st.type.colorSlots
        if slots > 0 {
            y = VFDW.label(fb, L, c, y, w, slots == 1 ? "COLOR" : "COLORS")
            for index in 0..<slots {
                let current: Int = index < st.colors.count ? st.colors[index] : 0
                let value: String = VFDLabOptions.name(VFDLabOptions.palette, current)
                let slotName: String = slotLabel(st.type, index)
                y = pickerRow(fb, c, y, w, slotName, value, action: {
                    VFDLabScreen.openPicker(ctx, slotName, VFDLabOptions.palette, current, { (picked: Int) -> Void in
                        VFDLabScreen.userEdit(ctx) { (s: inout VFDLabState) -> Void in
                            var next: [Int] = s.colors
                            while next.count <= index {
                                next.append(0)
                            }
                            next[index] = picked
                            s.colors = next
                        }
                    })
                })
            }
        }
        if st.type.supportsVib {
            y = buzzRow(ctx, fb, L, m, c, y + 1, w)
        }
        return y
    }

    /// LabBuilderPanel.slotLabel.
    fileprivate static func slotLabel(_ type: LabPacketBuilder.LabPacketType, _ index: Int) -> String {
        switch type {
        case .dual:
            return index == 0 ? "INNER" : "OUTER"
        case .crossfade:
            return index == 0 ? "FROM" : "TO"
        case .circle:
            return "P\(index + 1)"
        case .rainbow, .rotate:
            let zones: [String] = VFDLabCopy.zoneLabels
            return (index >= 0 && index < zones.count) ? zones[index] : "\(index + 1)"
        default:
            return "\(index + 1)"
        }
    }

    /// BUZZ (dim) + switch, then the PATTERN picker while it is on, on one row.
    fileprivate static func buzzRow(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ m: VFDLabModel,
                                    _ c: Int, _ y: Int, _ w: Int) -> Int {
        let st: VFDLabState = m.state
        fb.text(c, y + VFDW.ctrlText, "BUZZ", .small, VFDInk.dim)
        let sx: Int = c + VFDText.width("BUZZ") + 6
        VFDW.toggle(fb, L, sx, y, VFDW.switchW, "", st.vibEnabled, name: "toggle:BUZZ", action: {
            VFDLabScreen.userEdit(ctx) { (s: inout VFDLabState) -> Void in
                s.vibEnabled = !s.vibEnabled
            }
        })
        if st.vibEnabled {
            let px: Int = sx + VFDW.switchW + 6
            let pattern: Int = st.vibPattern
            let value: String = VFDLabOptions.name(VFDLabOptions.vibration, pattern)
            pickerAt(fb, px, y, c + w - px, "PATTERN", value, action: {
                VFDLabScreen.openPicker(ctx, "PATTERN", VFDLabOptions.vibration, pattern, { (picked: Int) -> Void in
                    VFDLabScreen.userEdit(ctx) { (s: inout VFDLabState) -> Void in
                        s.vibPattern = picked
                    }
                })
            })
        }
        return y + VFDW.ctrlH + VFDW.gap
    }

    /// RAW HEX field and the colour pickers of whatever recolourable bytes it carries.
    fileprivate static func rawFields(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ m: VFDLabModel,
                                      _ c: Int, _ top: Int, _ w: Int) -> Int {
        let raw: String = m.state.rawHex
        var y: Int = VFDW.field(fb, L, c, top, w, "RAW HEX (8301…)", raw, placeholder: "RAW HEX (8301…)",
                                name: "field:RAW HEX", valueColor: VFDInk.dim, action: {
                                    ctx.prompt(title: "RAW HEX (8301…)", text: raw, keyboard: .hex) { (typed: String) -> Void in
                                        VFDLabScreen.userEdit(ctx) { (s: inout VFDLabState) -> Void in
                                            s.rawHex = typed.uppercased()
                                        }
                                    }
                                })
        y = slotPickers(ctx, fb, L, m.built, c, y, w, apply: { (s: inout VFDLabState, next: [Int]) -> Void in
            s.rawHex = LabPacketBuilder.withColors(s.rawHex, next)
        })
        return y
    }

    /// TEST picker, WATCH FOR, the experiment's colours.
    fileprivate static func experimentFields(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout,
                                             _ m: VFDLabModel, _ c: Int, _ top: Int, _ w: Int) -> Int {
        let index: Int = m.state.showIndex
        let list: [LabPacketBuilder.Experiment] = LabPacketBuilder.experiments
        var watch: String = ""
        if index >= 0 && index < list.count {
            watch = list[index].watch
        } else if let first = list.first {
            watch = first.watch
        }
        let value: String = VFDLabOptions.name(VFDLabOptions.experiments, index)
        var y: Int = pickerRow(fb, c, VFDW.groupTop(L, top), w, "TEST", value, action: {
            VFDLabScreen.openPicker(ctx, "TEST", VFDLabOptions.experiments, index, { (picked: Int) -> Void in
                VFDLabScreen.pickShow(ctx, picked)
            })
        })
        y = note(fb, c, y + 1, w, "WATCH FOR: " + watch, VFDInk.text)
        y = slotPickers(ctx, fb, L, m.built, c, y, w, apply: { (s: inout VFDLabState, next: [Int]) -> Void in
            s.colors = next
        })
        return y
    }

    /// SHOW picker, its note, the show's colours.
    fileprivate static func showFields(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ m: VFDLabModel,
                                       _ c: Int, _ top: Int, _ w: Int) -> Int {
        let index: Int = m.state.showIndex
        let value: String = VFDLabOptions.name(VFDLabOptions.shows, index)
        var y: Int = pickerRow(fb, c, VFDW.groupTop(L, top), w, "SHOW", value, action: {
            VFDLabScreen.openPicker(ctx, "SHOW", VFDLabOptions.shows, index, { (picked: Int) -> Void in
                VFDLabScreen.pickShow(ctx, picked)
            })
        })
        y = note(fb, c, y + 1, w, VFDLabCopy.showNote)
        y = slotPickers(ctx, fb, L, m.built, c, y, w, apply: { (s: inout VFDLabState, next: [Int]) -> Void in
            s.colors = next
        })
        return y
    }

    /// Picking a show or an experiment starts from its captured colours.
    fileprivate static func pickShow(_ ctx: VFDContext, _ picked: Int) {
        userEdit(ctx) { (s: inout VFDLabState) -> Void in
            s.showIndex = picked
            s.colors = []
        }
    }

    /// COLORS and one palette picker per recolourable byte of `hex`, labelled by where it lands.
    fileprivate static func slotPickers(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ hex: String,
                                        _ c: Int, _ top: Int, _ w: Int,
                                        apply: @escaping (inout VFDLabState, [Int]) -> Void) -> Int {
        let slots: [LabPacketBuilder.ColorSlot] = LabPacketBuilder.editableSlots(hex)
        let values: [Int] = LabPacketBuilder.slotColors(hex)
        if slots.isEmpty || values.count != slots.count { return top }
        var y: Int = VFDW.label(fb, L, c, top, w, "COLORS")
        for index in 0..<slots.count {
            let current: Int = values[index]
            let slotName: String = slots[index].label
            let value: String = VFDLabOptions.name(VFDLabOptions.palette, current)
            y = pickerRow(fb, c, y, w, slotName, value, action: {
                VFDLabScreen.openPicker(ctx, slotName, VFDLabOptions.palette, current, { (picked: Int) -> Void in
                    var next: [Int] = values
                    next[index] = picked
                    VFDLabScreen.userEdit(ctx) { (s: inout VFDLabState) -> Void in
                        apply(&s, next)
                    }
                })
            })
        }
        return y
    }

    /// Custom RGB: a true-colour swatch with its R · G · B (#RRGGBB) caption, then RED / GREEN /
    /// BLUE sliders 0-63 (E908 is six bits per channel).
    fileprivate static func rgbFields(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ m: VFDLabModel,
                                      _ c: Int, _ top: Int, _ w: Int) -> Int {
        let rgb: [Int] = rgbChannels(m.state.colors)
        let r8: Int = rgb[0] * 255 / 63
        let g8: Int = rgb[1] * 255 / 63
        let b8: Int = rgb[2] * 255 / 63
        let colour: VFDRGB = VFDRGB(r8, g8, b8)
        let hexText: String = "#" + DisneyTlv.hex2(r8) + DisneyTlv.hex2(g8) + DisneyTlv.hex2(b8)
        let caption: String = "R \(rgb[0]) · G \(rgb[1]) · B \(rgb[2])  (" + hexText + ")"
        var y: Int = VFDW.groupTop(L, top)
        fb.fill(c, y, 11, 11, fb.rgb(colour))
        fb.textFit(c + 11 + 6, y + 2, caption, w - 17, .small, VFDInk.dim)
        y += 11 + VFDW.gap
        for index in 0..<3 {
            let v: Int = rgb[index]
            let name: String = VFDLabCopy.rgbNames[index]
            let frac: Double = Double(v) / 63.0
            y = VFDW.slider(fb, L, c, y, w, name, String(v), frac, name: "slider:" + name, canDec: v > 0, canInc: v < 63,
                            onDec: { VFDLabScreen.setChannel(ctx, index, v - 1) },
                            onInc: { VFDLabScreen.setChannel(ctx, index, v + 1) },
                            onSet: { (f: Double) -> Void in
                                let picked: Int = Int((f * 63.0).rounded())
                                VFDLabScreen.setChannel(ctx, index, picked)
                            })
        }
        return y
    }

    /// Always three channels, each clamped to 0...63.
    fileprivate static func rgbChannels(_ values: [Int]) -> [Int] {
        var out: [Int] = []
        for index in 0..<3 {
            let value: Int = index < values.count ? values[index] : 0
            out.append(min(max(value, 0), 63))
        }
        return out
    }

    fileprivate static func setChannel(_ ctx: VFDContext, _ index: Int, _ value: Int) {
        if index < 0 || index > 2 { return }
        userEdit(ctx) { (s: inout VFDLabState) -> Void in
            var next: [Int] = VFDLabScreen.rgbChannels(s.colors)
            next[index] = min(max(value, 0), 63)
            s.colors = next
        }
    }

    /// FRAMING: channel marker switch, DURATION picker + its note, wake ping switch.
    fileprivate static func framingSection(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout,
                                           _ m: VFDLabModel, _ c: Int, _ top: Int, _ w: Int) -> Int {
        let framing: LabPacketBuilder.Framing = m.state.framing
        var y: Int = VFDW.label(fb, L, c, top, w, "FRAMING")
        y = framingToggle(fb, L, c, y, w, VFDLabCopy.channelTitle, framing.channelMarker, VFDLabCopy.channelDetail,
                          action: {
                              VFDLabScreen.userEdit(ctx) { (s: inout VFDLabState) -> Void in
                                  s.framing.channelMarker = !s.framing.channelMarker
                              }
                          })
        let timing: Int = framing.timing
        let value: String = VFDLabOptions.name(PacketBuilder.Timing.options, timing)
        y = pickerRow(fb, c, y + 1, w, "DURATION", value, action: {
            VFDLabScreen.openPicker(ctx, "DURATION", PacketBuilder.Timing.options, timing, { (picked: Int) -> Void in
                VFDLabScreen.userEdit(ctx) { (s: inout VFDLabState) -> Void in
                    s.framing.timing = picked
                }
            })
        })
        y = note(fb, c, y + 1, w, VFDLabCopy.durationNote)
        y = framingToggle(fb, L, c, y + 1, w, VFDLabCopy.wakeTitle, framing.wakePrefix, VFDLabCopy.wakeDetail,
                          action: {
                              VFDLabScreen.userEdit(ctx) { (s: inout VFDLabState) -> Void in
                                  s.framing.wakePrefix = !s.framing.wakePrefix
                              }
                          })
        return y
    }

    /// PACKET ANATOMY — TAP A BLOCK TO EDIT: the blocks flowing left to right (a colour block with
    /// its true-colour swatch and colour name), then the selected block's box. A tap on a block
    /// selects it and opens its editor (`openSegment`).
    fileprivate static func anatomy(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ m: VFDLabModel,
                                    _ c: Int, _ top: Int, _ w: Int) -> Int {
        let segments: [DisneyTlv.Segment] = m.segments
        let built: String = m.built
        let adv: Int = VFDLabGeo.adv
        let chipH: Int = VFDLabGeo.chipH
        let longCaption: String = "PACKET ANATOMY — TAP A BLOCK TO EDIT"
        let caption: String = VFDText.width(longCaption) <= w ? longCaption : "PACKET ANATOMY — TAP TO EDIT"
        var y: Int = VFDW.label(fb, L, c, top, w, caption)
        var x: Int = c
        var row: Int = y
        for i in 0..<segments.count {
            let seg: DisneyTlv.Segment = segments[i]
            let first: String = seg.hex.isEmpty ? "!" : seg.hex
            var extra: String = ""
            var swatch: VFDRGB? = nil
            if seg.kind == DisneyTlv.SegmentKind.color {
                let idx: Int = paletteIndex(seg.hex)
                extra = VFDW.upper(StarlightColors.nameFor(idx))
                swatch = VFDColors.starlightGlow(idx)
            }
            let sw: Int = swatch != nil ? 8 : 0
            let line1: String = extra.isEmpty ? first : first + " " + extra
            let title: String = VFDW.upper(seg.title)
            let wide: Int = max(sw + VFDText.width(line1), VFDText.width(title))
            let inner: Int = min(wide, w - 8)
            let bw: Int = inner + 8
            if x > c && x + bw > c + w {
                x = c
                row += chipH + 4
            }
            let tone: UInt8 = segmentInk(seg.kind)
            let selected: Bool = m.selectedSegment == i
            let t1: Int = row + 3
            let t2: Int = row + 13
            let tx: Int = x + 4 + sw
            let tInner: Int = inner - sw
            if selected {
                fb.fill(x, row, bw, chipH, VFDInk.highlight)
                if let rgb = swatch {
                    fb.fill(x + 3, t1, 7, 7, VFDInk.unlit)
                    fb.fill(x + 4, t1 + 1, 5, 5, fb.rgb(rgb))
                }
                fb.textFit(tx, t1, line1, tInner, .small, VFDInk.unlit)
                fb.textFit(x + 4, t2, title, inner, .small, VFDInk.unlit)
            } else {
                fb.box(x, row, bw, chipH, VFDInk.dim)
                if let rgb = swatch {
                    fb.fill(x + 4, t1 + 1, 5, 5, fb.rgb(rgb))
                }
                if tone == VFDInk.alarm {
                    VFDW.alarmText(fb, tx, t1, VFDText.fit(line1, tInner))
                } else {
                    let end: Int = fb.textFit(tx, t1, first, tInner, .small, tone)
                    if !extra.isEmpty {
                        fb.textFit(end + adv, t1, extra, tx + tInner - end - adv, .small, VFDInk.text)
                    }
                }
                fb.textFit(x + 4, t2, title, inner, .small, VFDInk.dim)
            }
            let index: Int = i
            VFDW.tap(fb, x, row, bw, chipH, "anatomy:\(i)", action: {
                VFDLabScreen.openSegment(ctx, index, built)
            })
            x += bw + 4
        }
        y = row + chipH + VFDW.gap
        if let sel = m.selectedSegment, sel >= 0, sel < segments.count {
            y = segmentBox(fb, m, segments[sel], c, y, w)
        }
        return y
    }

    /// The selected block's box under the chips: where its bytes sit, its anatomy detail and,
    /// while ABOUT is open, what it is and does, a field's explanation (ABOUT THIS FIELD), its
    /// valid values, its bits and how sure that is; then the footer. A tap on the box toggles
    /// ABOUT; × in its top-right corner deselects the block. Returns the next free row.
    fileprivate static func segmentBox(_ fb: VFDFrameBuffer, _ m: VFDLabModel, _ seg: DisneyTlv.Segment,
                                       _ c: Int, _ top: Int, _ w: Int) -> Int {
        let tone: UInt8 = segmentInk(seg.kind)
        let tw: Int = w - 8
        let close: String = "×"
        let closeW: Int = VFDText.width(close) + 8
        var lines: [VFDLabLine] = []
        for ln in VFDLabText.sepLines(segmentPlace(m, seg), tw - closeW) {
            lines.append(boxLine(ln, VFDInk.dim))
        }
        for ln in VFDLabText.wrap(seg.detail, tw) {
            lines.append(boxLine(ln, tone))
        }
        if m.aboutOpen, let about = m.segmentAbout {
            lines.append(contentsOf: aboutLines(m, about, tw))
        }
        let more: String = m.aboutOpen ? "TAP HERE: LESS" : "TAP HERE: ABOUT"
        for ln in VFDLabText.sepLines(["TAP BLOCK: EDIT", more], tw) {
            lines.append(boxLine(ln, VFDInk.dim))
        }
        let h: Int = 4 + (lines.count - 1) * VFDW.line + 7 + 4
        let y: Int = top + 2
        fb.box(c, y, w, h, VFDInk.dim)
        var r: Int = y + 4
        for line in lines {
            if line.color == VFDInk.alarm {
                VFDW.alarmText(fb, c + 4, r, line.text)
            } else {
                fb.text(c + 4, r, line.text, .small, line.color)
            }
            r += VFDW.line
        }
        fb.text(c + w - 4 - VFDText.width(close), y + 4, close, .small, VFDInk.text)
        let ui: VFDUIState = m.ui
        VFDW.tap(fb, c, y, w, h, "anatomy:about", action: {
            ui.toggleBool(VFDLabKeys.segmentAbout)
        })
        VFDW.tap(fb, c + w - closeW - 4, y, closeW + 4, VFDW.ctrlH, "anatomy:close", action: {
            VFDLabScreen.closeSegment(ui)
        })
        return y + h + VFDW.gap
    }

    /// The box's first line, as parts: "BYTES a–b OF n" (1-based, like the inspector's BYTE i OF
    /// n) and the block's hex; a block that could not be located in the packet is read-only.
    fileprivate static func segmentPlace(_ m: VFDLabModel, _ seg: DisneyTlv.Segment) -> [String] {
        let total: Int = HexUtils.canonicalHex(m.built).count / 2
        guard let about = m.segmentAbout, let off = about.offset, about.count > 0 else {
            if seg.hex.isEmpty || seg.kind == DisneyTlv.SegmentKind.error {
                return ["WHERE THE RECORD CHAIN BREAKS"]
            }
            return ["NOT LOCATED · READ-ONLY", seg.hex]
        }
        let first: Int = off + 1
        let last: Int = off + about.count
        var place: String = "BYTES \(first)–\(last) OF \(total)"
        if about.count == 1 {
            place = "BYTE \(first) OF \(total)"
        }
        return [place, seg.hex]
    }

    /// ABOUT: what the block is and does, the field asked about, valid values, bits, confidence.
    fileprivate static func aboutLines(_ m: VFDLabModel, _ about: LabSegmentEditor.About, _ tw: Int) -> [VFDLabLine] {
        var out: [VFDLabLine] = []
        appendWrapped(&out, "WHAT IT IS: " + about.what, tw, VFDInk.text)
        appendWrapped(&out, "WHAT IT DOES: " + about.does, tw, VFDInk.text)
        if !m.fieldAbout.isEmpty && m.fieldAbout != about.does {
            let fieldTitle: String = VFDW.upper(m.fieldAboutTitle)
            appendWrapped(&out, fieldTitle + ": " + m.fieldAbout, tw, VFDInk.text)
        }
        appendWrapped(&out, "VALID: " + about.valid, tw, VFDInk.dim)
        if !about.bits.isEmpty {
            appendWrapped(&out, "BITS: " + about.bits, tw, VFDInk.dim)
        }
        let proven: Bool = about.confidence == LabSegmentEditor.Confidence.proven
        let confidence: String = "CONFIDENCE: " + VFDW.upper(about.confidence.rawValue)
        appendWrapped(&out, confidence, tw, proven ? VFDInk.highlight : VFDInk.text)
        return out
    }

    fileprivate static func appendWrapped(_ out: inout [VFDLabLine], _ text: String, _ tw: Int, _ color: UInt8) {
        for ln in VFDLabText.wrap(text, tw) {
            out.append(boxLine(ln, color))
        }
    }

    fileprivate static func boxLine(_ text: String, _ color: UInt8) -> VFDLabLine {
        return VFDLabLine(text: text, color: color, legend: [], isLegend: false)
    }

    /// USE IN HEX FIELD (bordered, cyan) and LOAD HEX (bordered, cyanDim), sized to their labels;
    /// after a block edit, UNDO EDIT beside them (or under them when the row is full).
    fileprivate static func builderActions(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout,
                                           _ m: VFDLabModel, _ c: Int, _ y: Int, _ w: Int) -> Int {
        let lab: String = "USE IN HEX FIELD"
        let bw: Int = VFDText.width(lab) + 12
        VFDW.button(fb, L, c, y, bw, lab, enabled: !m.built.isEmpty, action: {
            VFDLabScreen.useBuilt(ctx)
        })
        let loadEnd: Int = ghostButton(fb, c + bw + 4, y, "LOAD HEX", action: {
            VFDLabScreen.loadFromHexField(ctx)
        })
        var next: Int = y + VFDW.ctrlH + VFDW.gap
        if m.undoAvailable {
            let undo: String = "UNDO EDIT"
            let undoW: Int = VFDText.width(undo) + 12
            let undoAction: () -> Void = { VFDLabScreen.undoSegmentEdit(ctx) }
            if loadEnd + 4 + undoW <= c + w {
                ghostButton(fb, loadEnd + 4, y, undo, action: undoAction)
            } else {
                ghostButton(fb, c, next, undo, action: undoAction)
                next += VFDW.ctrlH + VFDW.gap
            }
        }
        return next
    }
}

// MARK: - Edit group

extension VFDLabScreen {
    fileprivate static func editGroup(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ m: VFDLabModel,
                                      _ c: Int, _ top: Int, _ w: Int) -> Int {
        var y: Int = hairline(fb, c, top, w)
        y = packetFields(ctx, fb, L, m, c, y, w)
        y = inspector(ctx, fb, L, m, c, y, w)
        return actionSection(ctx, fb, L, m, c, y + 2, w)
    }

    /// HEX OUTPUT (value in dim), LABEL and, under them, the hex's BLE advertising reject reason.
    fileprivate static func packetFields(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ m: VFDLabModel,
                                         _ c: Int, _ top: Int, _ w: Int) -> Int {
        let hex: String = m.state.hex
        let label: String = m.state.label
        var y: Int = VFDW.field(fb, L, c, top, w, "HEX OUTPUT", hex, placeholder: "HEX (8301…)",
                                name: "field:HEX OUTPUT", valueColor: VFDInk.dim, action: {
                                    ctx.prompt(title: "HEX OUTPUT", text: hex, keyboard: .hex) { (typed: String) -> Void in
                                        VFDLabScreen.setHexField(ctx, typed)
                                    }
                                })
        y = VFDW.field(fb, L, c, y, w, "LABEL", label, placeholder: "LABEL", name: "field:LABEL", action: {
            ctx.prompt(title: "LABEL", text: label, keyboard: .text) { (typed: String) -> Void in
                VFDLabScreen.setLabelField(ctx, typed)
            }
        })
        if let reason = m.reject {
            y += 2
            for ln in VFDLabText.wrapLines(reason, w - 4, maxLines: 2) {
                VFDW.alarmText(fb, c, y, ln)
                y += VFDW.line
            }
        }
        return y
    }

    /// LabPacketInspector: the header line, classification and colours; open: the VIBRATION
    /// stepper, RAW BYTES — tap to edit, the byte grid, the hint.
    fileprivate static func inspector(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ m: VFDLabModel,
                                      _ c: Int, _ top: Int, _ w: Int) -> Int {
        let data: [String] = m.bytes
        let isOpen: Bool = m.inspectorOpen
        let ui: VFDUIState = m.ui
        var y: Int = top + 3
        let r: Int = y + VFDW.ctrlText
        if isOpen {
            VFDW.chevronUp(fb, c, r, VFDInk.dim)
        } else {
            VFDW.chevron(fb, c, r, false, VFDInk.dim)
        }
        let cnt: String = "\(data.count) B"
        fb.textRight(c + w - 1, r, cnt, .small, VFDInk.dim)
        fb.textFit(c + 11, r, "PACKET INSPECTOR", w - 11 - VFDText.width(cnt) - 6, .small, VFDInk.highlight)
        VFDW.tap(fb, c, y, w, VFDW.ctrlH, "inspector", action: {
            ui.toggleBool(VFDLabKeys.inspector)
        })
        y += VFDW.ctrlH
        if let classified = m.classified {
            let text: String = classified.label + " · " + classified.category.rawValue
            y = linesBlock(fb, c, y, VFDLabText.wrapLines(text, w, maxLines: 2), VFDInk.highlight) - VFDW.gap
            let colours: String = classified.colors.trimmingCharacters(in: .whitespacesAndNewlines)
            if !colours.isEmpty {
                let swatches: [VFDRGB] = namedSwatches(m.state.hex, classified.colors)
                if swatches.isEmpty {
                    let line: String = VFDText.fit("COLORS: " + VFDW.upper(classified.colors), w)
                    y = linesBlock(fb, c, y, [line], VFDInk.dim) - VFDW.gap
                } else {
                    // "COLORS:", the colours' true-colour swatches, then their names.
                    let x0: Int = fb.text(c, y, "COLORS: ", .small, VFDInk.dim)
                    swatchNames(fb, x0, y, swatches, VFDW.upper(classified.colors), c + w, VFDInk.dim)
                    y += VFDW.line
                }
            }
        } else {
            y = linesBlock(fb, c, y, ["Unclassified / raw payload"], VFDInk.dim) - VFDW.gap
        }
        y += VFDW.gap
        if !isOpen { return y }
        if let vib = LabPacketTools.tailVibration(m.state.hex) {
            y += 1
            fb.text(c, y + VFDW.ctrlText, "VIBRATION", .small, VFDInk.dim)
            var x: Int = c + VFDText.width("VIBRATION") + 8
            VFDW.stepButton(fb, x, y, false, vib > 0, "vibration:-", action: {
                VFDLabScreen.stepVibration(ctx, -1)
            })
            x += VFDW.stepW
            let val: String = vib < 10 ? "0" + String(vib) : String(vib)
            let vw: Int = VFDText.width(val) + 8
            fb.text(x + 4, y + VFDW.ctrlText, val, .small, VFDInk.highlight)
            x += vw
            VFDW.stepButton(fb, x, y, true, vib < 15, "vibration:+", action: {
                VFDLabScreen.stepVibration(ctx, 1)
            })
            x += VFDW.stepW + 8
            fb.textFit(x, y + VFDW.ctrlText, "0xB0 | vib", c + w - x, .small, VFDInk.dim)
            y += VFDW.ctrlH + VFDW.gap
        }
        y = VFDW.label(fb, L, c, y, w, "RAW BYTES — tap to edit")
        let cells: [(c: Int, w: Int)] = L.split(8, gap: 4, c: c, w: w)
        let count: Int = data.count
        for i in 0..<count {
            let col: Int = i % 8
            if col == 0 && i > 0 {
                y += VFDW.ctrlH + VFDW.gap
            }
            let cell: (c: Int, w: Int) = cells[col]
            let b: String = data[i]
            fb.box(cell.c, y, cell.w, VFDW.ctrlH, VFDInk.dim)
            fb.text(VFDW.cx(cell.c, cell.w, b), y + VFDW.ctrlText, b, .small, VFDInk.dim)
            let index: Int = i
            VFDW.tap(fb, cell.c, y, cell.w, VFDW.ctrlH, "byte:\(i)", action: {
                VFDLabScreen.promptByte(ctx, index, b, count)
            })
        }
        if count > 0 {
            y += VFDW.ctrlH + VFDW.gap
        }
        y += 1
        return note(fb, c, y, w, VFDLabCopy.byteHint)
    }

    /// SEND (primary, fills the row) + SAVE + TAG, the preset message, the link warning, the TX
    /// status line.
    fileprivate static func actionSection(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout,
                                          _ m: VFDLabModel, _ c: Int, _ top: Int, _ w: Int) -> Int {
        let saveW: Int = VFDText.width("SAVE") + 12
        let tagW: Int = VFDText.width("TAG") + 12
        let sendW: Int = w - saveW - tagW - 8
        VFDW.button(fb, L, c, top, sendW, "SEND", primary: true, action: {
            VFDLabScreen.sendPacket(ctx)
        })
        VFDW.button(fb, L, c + sendW + 4, top, saveW, "SAVE", action: {
            VFDLabScreen.savePreset(ctx)
        })
        VFDW.button(fb, L, c + sendW + 4 + saveW + 4, top, tagW, "TAG", action: {
            VFDLabScreen.tagRaw(ctx)
        })
        var y: Int = top + VFDW.ctrlH + VFDW.gap + 2
        if let msg = m.state.presetMsg {
            let color: UInt8 = msg.hasPrefix("Saved") ? VFDInk.highlight : VFDInk.dim
            y = linesBlock(fb, c, y, [VFDText.fit(msg, w)], color) - VFDW.gap
        }
        if !ctx.vm.remoteLinkReady {
            for ln in VFDText.wrap(VFDLabCopy.linkWarning, w - 4) {
                VFDW.alarmText(fb, c, y, ln)
                y += VFDW.line
            }
        }
        return VFDW.statusLine(fb, L, c, y, w, ctx.tx.status) + VFDW.gap
    }
}

// MARK: - Extras group

extension VFDLabScreen {
    fileprivate static func extrasGroup(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ m: VFDLabModel,
                                        _ c: Int, _ top: Int, _ w: Int) -> Int {
        var y: Int = hairline(fb, c, top, w)
        y = randomShow(ctx, fb, L, m, c, y - (VFDW.sectionGap - VFDW.gap) + 3, w)
        y = presetsSection(ctx, fb, L, m, c, y, w)
        y = mbleSection(ctx, fb, L, m, c, y, w)
        return themesSection(ctx, fb, L, m, c, y, w)
    }

    /// RANDOM LIGHT SHOW: the text, INTERVAL MS (SettingSlider 500...30000 step 250, committed on
    /// release), START / STOP SHOW and the current packet's label while it runs.
    fileprivate static func randomShow(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ m: VFDLabModel,
                                       _ c: Int, _ top: Int, _ w: Int) -> Int {
        var y: Int = VFDW.section(fb, L, c, top, w, "RANDOM LIGHT SHOW")
        y = note(fb, c, y, w, VFDLabCopy.showText)
        y = intervalSlider(ctx, fb, L, m, c, y, w)
        let running: Bool = ctx.tx.randomShowEnabled
        let lab: String = running ? "STOP SHOW" : "START SHOW"
        let bw: Int = VFDText.width(lab) + 12
        VFDW.button(fb, L, c, y + 1, bw, lab, primary: true, action: {
            VFDLabScreen.toggleShow(ctx)
        })
        if running {
            let current: String = ctx.tx.randomShowLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let shown: String = current.isEmpty ? "Rolling the dice…" : ctx.tx.randomShowLabel
            fb.textFit(c + bw + 8, y + 1 + VFDW.ctrlText, VFDW.upper(shown), w - bw - 8, .small, VFDInk.highlight)
        }
        return y + 1 + VFDW.ctrlH + VFDW.gap
    }

    fileprivate static func intervalSlider(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout,
                                           _ m: VFDLabModel, _ c: Int, _ top: Int, _ w: Int) -> Int {
        let ui: VFDUIState = m.ui
        let low: Double = 500
        let high: Double = 30000
        let step: Double = 250
        let value: Double = m.intervalMs
        let raw: Double = m.intervalDragging ? m.intervalDraft : value
        let shown: Double = snap(raw, low, high, step)
        let frac: Double = (shown - low) / (high - low)
        let valueText: String = String(Int(shown.rounded()))
        let end: Int = VFDW.slider(fb, L, c, top, w, "INTERVAL MS", valueText, frac, hint: VFDLabCopy.intervalHint,
                                   name: "slider:INTERVAL", canDec: value > low, canInc: value < high,
                                   onDec: {
                                       ui.setBool(VFDLabKeys.intervalDrag, false)
                                       let next: Double = VFDLabScreen.snap(value - step, low, high, step)
                                       VFDLabScreen.commitInterval(ctx, next)
                                   },
                                   onInc: {
                                       ui.setBool(VFDLabKeys.intervalDrag, false)
                                       let next: Double = VFDLabScreen.snap(value + step, low, high, step)
                                       VFDLabScreen.commitInterval(ctx, next)
                                   })
        // The bar's drag: the value follows the finger and is committed on release.
        let barRow: Int = VFDW.groupTop(L, top) + VFDW.labelH
        let bx: Int = c + VFDW.stepW + 4
        let bw: Int = w - 2 * (VFDW.stepW + 4)
        VFDW.tap(fb, bx - 2, barRow, bw + 4, VFDW.ctrlH, "slider:INTERVAL:bar",
                 drag: { (fraction: Double, ended: Bool) -> Void in
                     let span: Double = Double(bw + 4)
                     let barW: Double = Double(max(1, bw))
                     let pos: Double = (fraction * span - 2.0) / barW
                     let f: Double = min(max(pos, 0.0), 1.0)
                     let ms: Double = low + f * (high - low)
                     if ended {
                         ui.setBool(VFDLabKeys.intervalDrag, false)
                         VFDLabScreen.commitInterval(ctx, VFDLabScreen.snap(ms, low, high, step))
                     } else {
                         ui.setDouble(VFDLabKeys.intervalDraft, ms)
                         ui.setBool(VFDLabKeys.intervalDrag, true)
                     }
                 })
        return end
    }

    /// MY PRESETS (n): one row per user preset (tap loads it, the bin deletes it after a confirm,
    /// HOLD offers both). Nothing when there are none.
    fileprivate static func presetsSection(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout,
                                           _ m: VFDLabModel, _ c: Int, _ top: Int, _ w: Int) -> Int {
        let presets: [MagicPacket] = m.presets
        if presets.isEmpty { return top }
        var y: Int = hairline(fb, c, top, w)
        y = VFDW.section(fb, L, c, y - (VFDW.sectionGap - VFDW.gap) + 3, w, "MY PRESETS (\(presets.count))")
        y -= VFDW.gap + 2
        for preset in presets {
            y = presetRow(ctx, fb, preset, c, y, w)
        }
        return y + VFDW.gap
    }

    /// LabPresetRow: label (text, uppercased) and hex, the Apple Watch star and the bin on the
    /// right (each its own tap), a dotted divider. Returns the next row's r.
    fileprivate static func presetRow(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ preset: MagicPacket,
                                      _ c: Int, _ r: Int, _ w: Int) -> Int {
        let binX: Int = c + w - VFDLabGeo.trashW - 4
        let starX: Int = binX - 4 - VFDStar.size - 8
        let y: Int = r + 3
        let end: Int = y + VFDW.line + 7 + 3
        if !rowVisible(fb, r, end + 1 - r) {
            return end + 1
        }
        let limit: Int = starX - 6 - c - 2
        let upperLabel: String = VFDW.upper(preset.label)
        fb.textFit(c + 2, y, upperLabel, limit, .small, VFDInk.text)
        fb.textFit(c + 2, y + VFDW.line, preset.hex, limit, .small, VFDInk.highlight)
        VFDStar.draw(fb, starX, y + 5, on: WatchFavoritesStore.shared.isStarred(hex: preset.hex))
        trash(fb, binX, y + 5, VFDInk.dim)
        fb.hline(c, end, w, VFDInk.dim, step: 2)
        let item: MagicPacket = preset
        VFDW.tap(fb, c, r, starX - 4 - c, end - r, "preset:" + upperLabel,
                 action: { VFDLabScreen.loadPreset(ctx, item) },
                 long: { VFDLabScreen.presetMenu(ctx, item) })
        VFDW.tap(fb, starX - 4, r, binX - starX, end - r, "preset:star:" + upperLabel,
                 action: {
                     VFDWatchSection.toggleStar(ctx, hex: item.hex, label: item.label,
                                                source: WatchFavorite.Source.labPreset)
                 })
        VFDW.tap(fb, binX - 4, r, c + w - binX + 4, end - r, "preset:delete:" + upperLabel,
                 action: { VFDLabScreen.askDelete(ctx, item) })
        return end + 1
    }

    /// MBLE TAP (LIGHTNING LANE): the token field, its payload (or why it is refused), MBLE ADV.
    fileprivate static func mbleSection(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout, _ m: VFDLabModel,
                                        _ c: Int, _ top: Int, _ w: Int) -> Int {
        let ui: VFDUIState = m.ui
        let token: String = m.token
        var y: Int = VFDW.section(fb, L, c, top, w, "MBLE TAP (LIGHTNING LANE)")
        y = VFDW.field(fb, L, c, y, w, nil, token, placeholder: "VMMS token hex", name: "field:MBLE TOKEN", action: {
            ctx.prompt(title: "VMMS TOKEN HEX", text: token, keyboard: .hex) { (typed: String) -> Void in
                ui.setString(VFDLabKeys.token, typed)
            }
        })
        let payload: [UInt8]? = MbleBeaconBuilder.manufacturerPayload(token)
        let trimmed: String = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if let bytes = payload {
                let text: String = "PAYLOAD " + HexUtils.bytesToHex(bytes)
                y = linesBlock(fb, c, y, VFDLabText.wrapLines(text, w, maxLines: 2), VFDInk.dim)
            } else {
                VFDW.alarmText(fb, c, y, "MBLE token too short")
                y += VFDW.line + VFDW.gap
            }
        }
        let canSend: Bool = ctx.vm.remoteLinkReady && payload != nil
        VFDW.button(fb, L, c, y + 1, nil, "MBLE ADV", enabled: canSend, action: {
            ctx.vm.mbleTapAndroid(tokenHex: ui.string(VFDLabKeys.token))
        })
        return y + 1 + VFDW.ctrlH + VFDW.gap
    }

    /// HAWKEYE THEMES (folded by default): the hint, then each category's theme rows.
    fileprivate static func themesSection(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ L: VFDLayout,
                                          _ m: VFDLabModel, _ c: Int, _ top: Int, _ w: Int) -> Int {
        let ui: VFDUIState = m.ui
        let collapsed: Bool = m.themesCollapsed
        var y: Int = VFDW.section(fb, L, c, top, w, "HAWKEYE THEMES", collapsed: collapsed, action: {
            let folded: Bool = ui.storedBool(VFDLabKeys.themesCollapsed, default: true)
            ui.setStoredBool(VFDLabKeys.themesCollapsed, !folded)
        })
        if collapsed { return y }
        y = linesBlock(fb, c, y, ["TAP SENDS · HOLD LOADS IN LAB"], VFDInk.dim)
        for category in MdeThemeCatalog.categories {
            y = linesBlock(fb, c, y + 2, [category.title], VFDInk.dim) - VFDW.gap + 1
            for theme in category.themes {
                y = themeRow(ctx, fb, theme, c, y, w)
            }
        }
        return y + VFDW.gap
    }

    /// LabThemeRow: a dim box; the title (text, uppercased) with the theme's colours as their
    /// #RRGGBB codes (dim), each after a 5 x 5 true-colour swatch, right-aligned beside it, or on a
    /// line of their own under the hex when both do not fit; the transmit hex (highlight,
    /// middle-cut). Tap sends it, HOLD loads it in the Lab. A row outside the clip is only measured.
    fileprivate static func themeRow(_ ctx: VFDContext, _ fb: VFDFrameBuffer, _ theme: MdeHawkeyeTheme,
                                     _ c: Int, _ r: Int, _ w: Int) -> Int {
        let ic: Int = c + 4
        let iw: Int = w - 8
        let codes: [String] = Array(theme.colors.prefix(5))
        let codesW: Int = swatchCodesWidth(codes)
        let themeTitle: String = theme.title
        let t: String = VFDW.upper(themeTitle)
        let beside: Bool = VFDText.width(t) + 8 + codesW <= iw
        let rows: Int = beside ? 1 : 2
        let h: Int = 4 + rows * VFDW.line + 7 + 4
        if !rowVisible(fb, r, h) {
            return r + h + 2
        }
        var y: Int = r + 4
        if beside {
            drawSwatchCodes(fb, codes, ic + iw - codesW, y, ic + iw)
        }
        fb.textFit(ic, y, t, iw, .small, VFDInk.text)
        y += VFDW.line
        let hex: String = theme.transmitHex
        fb.text(ic, y, VFDLabText.fitMiddle(hex, iw), .small, VFDInk.highlight)
        if !beside {
            y += VFDW.line
            drawSwatchCodes(fb, codes, ic, y, ic + iw)
        }
        fb.box(c, r, w, h, VFDInk.dim)
        VFDW.tap(fb, c, r, w, h, "theme:" + t,
                 action: { ctx.tx.transmit(hex: hex, label: themeTitle) },
                 long: { ctx.vm.loadInLab(hex: hex, label: themeTitle) })
        return r + h + 2
    }

    /// Width of the swatch codes: per colour a 5 x 5 swatch, 2 cells, "#RRGGBB"; 7 cells apart
    /// (the spacing of the codes joined by a space).
    fileprivate static func swatchCodesWidth(_ codes: [String]) -> Int {
        var total: Int = 0
        var i: Int = 0
        for code in codes {
            if i > 0 {
                total += 7
            }
            total += 7 + VFDText.width(code)
            i += 1
        }
        return total
    }

    /// The swatch codes from column x0 while they fit before `limit`; the first one that does not
    /// is cut with "…" (when its swatch and a character still fit), then the rest are dropped.
    fileprivate static func drawSwatchCodes(_ fb: VFDFrameBuffer, _ codes: [String], _ x0: Int, _ y: Int,
                                            _ limit: Int) {
        var x: Int = x0
        var i: Int = 0
        for code in codes {
            if i > 0 {
                x += 7
            }
            let textW: Int = VFDText.width(code)
            let room: Int = limit - x - 7
            if textW <= room {
                fb.fill(x, y + 1, 5, 5, fb.rgb(themeRGB(code)))
                fb.text(x + 7, y, code, .small, VFDInk.dim)
                x += 7 + textW
                i += 1
                continue
            }
            let short: String = String(code.prefix(1)) + VFDText.ellipsis
            if VFDText.width(short) <= room {
                fb.fill(x, y + 1, 5, 5, fb.rgb(themeRGB(code)))
                fb.textFit(x + 7, y, code, room, .small, VFDInk.dim)
            }
            break
        }
    }

    /// Whether rows [r, r + h) (drawing rows) reach the current clip; rows outside it are skipped
    /// cheaply (they would draw nothing).
    fileprivate static func rowVisible(_ fb: VFDFrameBuffer, _ r: Int, _ h: Int) -> Bool {
        let clip: (c: Int, r: Int, w: Int, h: Int) = fb.clipRect
        let top: Int = r + fb.originY
        let bottom: Int = top + h
        return bottom > clip.r && top < clip.r + clip.h
    }

    /// "#RRGGBB" as a true colour; black when the text is not a colour (labThemeSwatch).
    fileprivate static func themeRGB(_ text: String) -> VFDRGB {
        let clean: String = text.replacingOccurrences(of: "#", with: "")
        let value: Int = Int(clean, radix: 16) ?? 0
        return VFDColors.rgb(packed: value)
    }
}
