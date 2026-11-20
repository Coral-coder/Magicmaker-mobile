import Foundation

// VFD core golden check: replays tools/vfd/golden/ops.txt with VFDCore / VFDWidgets and compares
// every result line with tools/vfd/golden/expected.txt, which tools/vfd/golden.py writes from the
// Python reference (the file format is documented at the top of golden.py).
//
//   VFDCheck [GOLDEN_DIR] [--dump DIR]
//
// Prints "MISMATCH ..." for the first differing lines and a "VFD:" summary; exits 1 on any
// mismatch. --dump DIR writes the same per-page dumps as `golden.py --dump DIR`, for diffing.

let noneField: String = "\\N"

// MARK: - Field encoding (golden.py esc / unesc / split_list)

func scalarString(_ a: [Unicode.Scalar]) -> String {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: a)
    return String(view)
}

func sameText(_ a: String, _ b: String) -> Bool {
    return a.unicodeScalars.elementsEqual(b.unicodeScalars)
}

func splitOn(_ s: String, _ sep: Unicode.Scalar) -> [String] {
    var parts: [String] = []
    var cur: [Unicode.Scalar] = []
    for u in s.unicodeScalars {
        if u == sep {
            parts.append(scalarString(cur))
            cur = []
        } else {
            cur.append(u)
        }
    }
    parts.append(scalarString(cur))
    return parts
}

func esc(_ s: String) -> String {
    var out: [Unicode.Scalar] = []
    for u in s.unicodeScalars {
        if u == "\\" {
            out.append("\\")
            out.append("\\")
        } else if u == "\t" {
            out.append("\\")
            out.append("t")
        } else if u == "\n" {
            out.append("\\")
            out.append("n")
        } else {
            out.append(u)
        }
    }
    return scalarString(out)
}

func escElem(_ s: String) -> String {
    var out: [Unicode.Scalar] = []
    for u in esc(s).unicodeScalars {
        if u == "," {
            out.append("\\")
        }
        out.append(u)
    }
    return out.isEmpty ? "\\e" : scalarString(out)
}

func unesc(_ s: String) -> String {
    let a: [Unicode.Scalar] = Array(s.unicodeScalars)
    var out: [Unicode.Scalar] = []
    var i: Int = 0
    while i < a.count {
        let ch: Unicode.Scalar = a[i]
        if ch == "\\" && i + 1 < a.count {
            let nx: Unicode.Scalar = a[i + 1]
            if nx == "n" {
                out.append("\n")
            } else if nx == "t" {
                out.append("\t")
            } else if nx == "e" {
                // an empty list element: nothing
            } else {
                out.append(nx)
            }
            i += 2
            continue
        }
        out.append(ch)
        i += 1
    }
    return scalarString(out)
}

/// Raw (still escaped) elements of a list field.
func splitList(_ field: String) -> [String] {
    if field.unicodeScalars.isEmpty { return [] }
    let a: [Unicode.Scalar] = Array(field.unicodeScalars)
    var parts: [String] = []
    var cur: [Unicode.Scalar] = []
    var i: Int = 0
    while i < a.count {
        let ch: Unicode.Scalar = a[i]
        if ch == "\\" && i + 1 < a.count {
            cur.append(ch)
            cur.append(a[i + 1])
            i += 2
            continue
        }
        if ch == "," {
            parts.append(scalarString(cur))
            cur = []
        } else {
            cur.append(ch)
        }
        i += 1
    }
    parts.append(scalarString(cur))
    return parts
}

func encInts(_ values: [Int]) -> String {
    var parts: [String] = []
    for v in values {
        parts.append(String(v))
    }
    return parts.joined(separator: ",")
}

func encStrs(_ values: [String]) -> String {
    var parts: [String] = []
    for v in values {
        parts.append(escElem(v))
    }
    return parts.joined(separator: ",")
}

func zeroPad3(_ n: Int) -> String {
    var s: String = String(n)
    while s.count < 3 {
        s = "0" + s
    }
    return s
}

func fnv1a64(_ bytes: [UInt8]) -> String {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    let prime: UInt64 = 0x0000_0100_0000_01B3
    for b in bytes {
        h = (h ^ UInt64(b)) &* prime
    }
    let s: String = String(h, radix: 16)
    return String(repeating: "0", count: max(0, 16 - s.count)) + s
}

func tapsText(_ fb: VFDFrameBuffer) -> String {
    var s: String = ""
    for t in fb.taps {
        s += "\(t.c) \(t.r) \(t.w) \(t.h) " + t.name + "\n"
    }
    return s
}

/// What an op returned.
enum Ret {
    case none
    case int(Int)
    /// Already encoded (strings, lists, bools).
    case text(String)

    var encoded: String {
        switch self {
        case .none: return noneField
        case .int(let n): return String(n)
        case .text(let s): return s
        }
    }
}

func retStr(_ s: String?) -> Ret {
    if let v = s { return .text(esc(v)) }
    return .none
}

// MARK: - Op arguments

struct Args {
    let f: [String]
    let fb: VFDFrameBuffer

    func raw(_ i: Int) -> String { return i < f.count ? f[i] : "" }
    func isNone(_ i: Int) -> Bool { return raw(i) == noneField }
    func int(_ i: Int) -> Int { return Int(raw(i)) ?? 0 }
    func optInt(_ i: Int) -> Int? { return isNone(i) ? nil : int(i) }
    func dbl(_ i: Int) -> Double { return Double(raw(i)) ?? 0 }
    func optDbl(_ i: Int) -> Double? { return isNone(i) ? nil : dbl(i) }
    func bool(_ i: Int) -> Bool { return raw(i) == "1" }
    func optBool(_ i: Int) -> Bool? { return isNone(i) ? nil : bool(i) }
    func str(_ i: Int) -> String { return unesc(raw(i)) }
    func optStr(_ i: Int) -> String? { return isNone(i) ? nil : str(i) }
    func size(_ i: Int) -> VFDSize { return VFDSize(name: raw(i)) ?? .small }

    /// An ink index, or "#RRGGBB" allocated with fb.rgb() now.
    func color(_ i: Int) -> UInt8 {
        let s: String = raw(i)
        if s.hasPrefix("#") {
            return fb.rgb(VFDRGB(hex: s))
        }
        return UInt8(clamping: Int(s) ?? 0)
    }

    func optColor(_ i: Int) -> UInt8? { return isNone(i) ? nil : color(i) }
    func rgb(_ i: Int) -> VFDRGB { return VFDRGB(hex: raw(i)) }
    func optRGB(_ i: Int) -> VFDRGB? { return isNone(i) ? nil : rgb(i) }

    func strs(_ i: Int) -> [String] {
        var out: [String] = []
        for e in splitList(raw(i)) {
            out.append(unesc(e))
        }
        return out
    }

    func dbls(_ i: Int) -> [Double?] {
        var out: [Double?] = []
        for e in splitList(raw(i)) {
            if e == noneField {
                out.append(nil)
            } else {
                out.append(Double(e) ?? 0)
            }
        }
        return out
    }

    func optBools(_ i: Int) -> [Bool]? {
        if isNone(i) { return nil }
        var out: [Bool] = []
        for e in splitList(raw(i)) {
            out.append(e == "1")
        }
        return out
    }

    func zone(_ i: Int) -> (Double, Double)? {
        if isNone(i) { return nil }
        let parts: [String] = splitList(raw(i))
        if parts.count != 2 { return nil }
        return (Double(parts[0]) ?? 0, Double(parts[1]) ?? 0)
    }

    private func tagged(_ i: Int) -> (tag: String, rest: String)? {
        let a: [Unicode.Scalar] = Array(raw(i).unicodeScalars)
        if a.count < 2 { return nil }
        return (tag: scalarString(Array(a[0..<2])), rest: scalarString(Array(a[2...])))
    }

    /// options() selection: the item at index k is selected when k is in the set, or its raw text
    /// or upper() is.
    func sel(_ i: Int, items: [String]) -> Set<Int> {
        var out = Set<Int>()
        if isNone(i) { return out }
        guard let t = tagged(i) else { return out }
        var names: [String] = []
        if t.tag == "i:" {
            if let n = Int(t.rest) { out.insert(n) }
            return out
        } else if t.tag == "I:" {
            for e in splitList(t.rest) {
                if let n = Int(e) { out.insert(n) }
            }
            return out
        } else if t.tag == "s:" {
            names = [unesc(t.rest)]
        } else if t.tag == "S:" {
            for e in splitList(t.rest) {
                names.append(unesc(e))
            }
        }
        var k: Int = 0
        for item in items {
            let up: String = VFDW.upper(item)
            for nm in names where sameText(item, nm) || sameText(up, nm) {
                out.insert(k)
            }
            k += 1
        }
        return out
    }

    /// buttons() primary / alarm: an index, or the index of the first button with that label.
    func pick(_ i: Int, labels: [String]) -> Int? {
        if isNone(i) { return nil }
        guard let t = tagged(i) else { return nil }
        if t.tag == "i:" { return Int(t.rest) }
        if t.tag == "s:" {
            let name: String = unesc(t.rest)
            var k: Int = 0
            for lab in labels {
                if sameText(lab, name) { return k }
                k += 1
            }
        }
        return nil
    }
}

// MARK: - Pages and blocks

final class Page {
    let name: String
    let deviceKey: String
    let device: VFDDevice
    let base: VFDBase
    let L: VFDLayout
    var fb: VFDFrameBuffer
    var lines: [String] = []

    init(name: String, deviceKey: String, device: VFDDevice, base: VFDBase, header: String) {
        self.name = name
        self.deviceKey = deviceKey
        self.device = device
        self.base = base
        self.L = VFDLayout(device: device)
        self.fb = device.framebuffer(base)
        self.lines = [header]
    }
}

struct BlockOp {
    let line: Int
    let op: String
    let fields: [String]
}

final class Block {
    let open: String
    let fields: [String]
    var ops: [BlockOp] = []

    init(open: String, fields: [String]) {
        self.open = open
        self.fields = fields
    }
}

func layoutValues(_ L: VFDLayout) -> [Int] {
    var v: [Int] = [L.cols, L.rows, L.safeTop, L.safeEnd, L.left, L.right, L.width, L.tapRows]
    v += [L.headerTop, L.titleRow, L.headerTextRow, L.telemetryRow, L.headerRule, L.contentTop]
    v += [L.tabRows[0], L.tabRows[1], L.tabRule, L.contentBottom, L.contentH, L.tabH, L.tabCellW, L.tabLeft]
    return v
}

/// golden.CONSTANTS in order, then the number of tabs.
func constantValues() -> [Int] {
    var v: [Int] = [VFDW.margin, VFDW.ctrlH, VFDW.ctrlText, VFDW.fieldH, VFDW.gap, VFDW.line]
    v += [VFDW.labelH, VFDW.groupGap, VFDW.sectionGap, VFDW.sectionH, VFDW.tapRows, VFDW.stepW]
    v += [VFDW.optGap, VFDW.tabH, VFDW.switchW, VFDW.adv, VFDW.nPatterns, VFDW.tabCols]
    v += [VFDW.loopLastStop, VFDFrameBuffer.ledBarH, VFDInk.count, VFDInk.firstTrueColor]
    v += [VFDInk.maxTrueColors, VFDW.tabs.count]
    return v
}

// MARK: - Replay

final class Checker {
    var out: [String] = []
    var pages: [Page] = []
    var errors: [String] = []
    var opCount: Int = 0
    var page: Page? = nil
    var block: Block? = nil

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func runOp(_ op: String, _ a: Args, _ p: Page) -> Ret {
        let fb: VFDFrameBuffer = a.fb
        let L: VFDLayout = p.L
        switch op {
        // FrameBuffer
        case "clear":
            fb.clear(a.color(0))
        case "set":
            let k: UInt8 = a.color(2)
            fb.set(a.int(0), a.int(1), k)
        case "get":
            return .int(Int(fb.get(a.int(0), a.int(1))))
        case "fill":
            let k: UInt8 = a.color(4)
            fb.fill(a.int(0), a.int(1), a.int(2), a.int(3), k)
        case "hline":
            let k: UInt8 = a.color(3)
            fb.hline(a.int(0), a.int(1), a.int(2), k, step: a.int(4))
        case "vline":
            let k: UInt8 = a.color(3)
            fb.vline(a.int(0), a.int(1), a.int(2), k, step: a.int(4))
        case "box":
            let k: UInt8 = a.color(4)
            fb.box(a.int(0), a.int(1), a.int(2), a.int(3), k)
        case "text":
            let k: UInt8 = a.color(4)
            return .int(fb.text(a.int(0), a.int(1), a.str(2), a.size(3), k))
        case "text_right":
            let k: UInt8 = a.color(4)
            return .int(fb.textRight(a.int(0), a.int(1), a.str(2), a.size(3), k))
        case "text_fit":
            let k: UInt8 = a.color(5)
            return .int(fb.textFit(a.int(0), a.int(1), a.str(2), a.int(3), a.size(4), k))
        case "paragraph":
            let k: UInt8 = a.color(5)
            return .int(fb.paragraph(a.int(0), a.int(1), a.str(2), a.int(3), a.size(4), k, line: a.optInt(6)))
        case "inverted":
            let k: UInt8 = a.color(5)
            return .int(fb.inverted(a.int(0), a.int(1), a.str(2), a.size(3), pad: a.int(4), color: k))
        case "alarm":
            return .int(fb.alarm(a.int(0), a.int(1), a.str(2), a.size(3), pad: a.int(4)))
        case "led_bar":
            let k: UInt8 = a.color(4)
            let track: UInt8 = a.color(5)
            return .int(fb.ledBar(a.int(0), a.int(1), a.int(2), a.dbl(3), color: k, track: track,
                                  marker: a.bool(6), zone: a.zone(7)))
        case "line_chart":
            let values: [Double?] = a.dbls(4)
            let k: UInt8 = a.color(5)
            let vmin: Double? = a.optDbl(6)
            let vmax: Double? = a.optDbl(7)
            let baseline: UInt8? = a.optColor(8)
            return .int(fb.lineChart(a.int(0), a.int(1), a.int(2), a.int(3), values, color: k, vmin: vmin,
                                     vmax: vmax, baseline: baseline))
        case "push_clip":
            fb.pushClip(a.int(0), a.int(1), a.int(2), a.int(3), dy: a.int(4))
        case "pop_clip":
            fb.popClip()
        case "tap":
            fb.tap(a.int(0), a.int(1), a.int(2), a.int(3), name: a.str(4))
        case "hit":
            return retStr(fb.hit(a.int(0), a.int(1))?.name)
        case "scroll_region":
            fb.scrollRegion(id: a.str(0), a.int(1), a.int(2), a.int(3), a.int(4), contentRows: a.int(5))
        case "scroll_region_at":
            return retStr(fb.scrollRegionAt(a.int(0), a.int(1))?.id)
        case "rgb":
            return .int(Int(fb.rgb(a.rgb(0))))
        case "rgb_fill":
            let index: UInt8 = fb.rgb(a.rgb(4))
            fb.fill(a.int(0), a.int(1), a.int(2), a.int(3), index)
            return .int(Int(index))
        case "state":
            let clip = fb.clipRect
            return .text(encInts([fb.originY, clip.c, clip.r, clip.w, clip.h, fb.clipDepth]))
        case "checkpoint":
            let cells: String = fnv1a64(fb.cells)
            let taps: String = fnv1a64(Array(tapsText(fb).utf8))
            return .text(cells + ",\(fb.taps.count)," + taps + ",\(fb.trueColors.count)")

        // text and palette helpers
        case "text_width":
            return .int(VFDText.width(a.str(0), size: a.size(1)))
        case "max_chars":
            return .int(VFDText.maxChars(a.int(0), size: a.size(1)))
        case "fit_text":
            return .text(esc(VFDText.fit(a.str(0), a.int(1), size: a.size(2))))
        case "wrap_text":
            return .text(encStrs(VFDText.wrap(a.str(0), a.int(1), size: a.size(2))))
        case "round":
            return .int(VFDMath.roundHalfAway(a.dbl(0)))
        case "palette":
            var hexes: [String] = []
            for c in VFDPalette.colors(for: VFDBase(persisted: a.str(0))) {
                hexes.append(c.hex)
            }
            return .text(encStrs(hexes))
        case "alarm_inverted":
            return .text(VFDPalette.alarmInverted(VFDBase(persisted: a.str(0))) ? "1" : "0")
        case "metrics":
            let s: VFDSize = a.size(0)
            return .text(encInts([s.w, s.h, s.ascent, s.advance, s.line]))

        // widgets
        case "constants":
            return .text(encInts(constantValues()))
        case "group_top":
            return .int(VFDW.groupTop(L, a.int(0)))
        case "upper":
            return .text(esc(VFDW.upper(a.str(0))))
        case "cx":
            return .int(VFDW.cx(a.int(0), a.int(1), a.str(2), a.size(3)))
        case "wtap":
            VFDW.tap(fb, a.int(0), a.int(1), a.int(2), a.int(3), a.optStr(4), minH: a.int(5))
        case "badge":
            let k: UInt8 = a.color(3)
            return .int(VFDW.badge(fb, a.int(0), a.int(1), a.str(2), k))
        case "alarm_text":
            return .int(VFDW.alarmText(fb, a.int(0), a.int(1), a.str(2), right: a.bool(3)))
        case "tag_box":
            let k: UInt8 = a.color(3)
            let tk: UInt8 = a.color(4)
            return .int(VFDW.tagBox(fb, a.int(0), a.int(1), a.str(2), color: k, textColor: tk))
        case "chevron":
            let k: UInt8 = a.color(3)
            VFDW.chevron(fb, a.int(0), a.int(1), a.bool(2), k)
        case "chevron_up":
            let k: UInt8 = a.color(2)
            VFDW.chevronUp(fb, a.int(0), a.int(1), k)
        case "step_button":
            VFDW.stepButton(fb, a.int(0), a.int(1), a.bool(2), a.bool(3), a.optStr(4))
        case "layout":
            return .text(encInts(layoutValues(L)))
        case "x":
            return .int(L.x(a.dbl(0)))
        case "split":
            var flat: [Int] = []
            for s in L.split(a.int(0), gap: a.int(1), c: a.optInt(2), w: a.optInt(3)) {
                flat.append(s.c)
                flat.append(s.w)
            }
            return .text(encInts(flat))
        case "tab_cell":
            let t = L.tabCell(a.int(0))
            return .text(encInts([t.c, t.r, t.w, t.h]))
        case "tab_label":
            return .text(esc(L.tabLabel(a.str(0))))
        case "tab_key":
            return retStr(VFDW.tabKey(a.str(0)))
        case "header":
            let k: UInt8 = a.color(3)
            return .int(VFDW.header(fb, L, a.str(0), back: a.bool(1), right: a.optStr(2), rightColor: k,
                                    rightTap: a.optStr(4)))
        case "telemetry":
            return .int(VFDW.telemetry(fb, L, a.str(0)))
        case "tab_bar":
            VFDW.tabBar(fb, L, selected: a.str(0))
        case "frame":
            let k: UInt8 = a.color(5)
            VFDW.frame(fb, L, tab: a.str(0), title: a.str(1), telemetry: a.str(2), back: a.bool(3),
                       right: a.optStr(4), rightColor: k, scroll: a.int(6), rightTap: a.optStr(7))
        case "end_frame":
            VFDW.endFrame(fb)
        case "scrollbar":
            VFDW.scrollbar(fb, L, a.int(0), scroll: a.int(1))
        case "section":
            return .int(VFDW.section(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), count: a.optInt(4),
                                     collapsed: a.optBool(5), right: a.optStr(6), name: a.optStr(7)))
        case "label":
            let k: UInt8 = a.color(4)
            return .int(VFDW.label(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), color: k, group: a.bool(5)))
        case "text_block":
            let k: UInt8 = a.color(4)
            return .int(VFDW.textBlock(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), color: k, upper: a.bool(5)))
        case "status_line":
            let k: UInt8 = a.color(4)
            return .int(VFDW.statusLine(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), color: k,
                                        banner: a.bool(5), name: a.optStr(6)))
        case "kv":
            let k: UInt8 = a.color(5)
            return .int(VFDW.kv(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), a.optStr(4), color: k,
                                leader: a.bool(6)))
        case "hero":
            let k: UInt8 = a.color(6)
            return .int(VFDW.hero(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), a.str(4), size: a.size(5),
                                  color: k, sub: a.optStr(7)))
        case "divider":
            let k: UInt8 = a.color(4)
            return .int(VFDW.divider(fb, L, a.int(0), a.int(1), a.int(2), dotted: a.bool(3), color: k))
        case "panel_inner":
            let pi = VFDW.panelInner(a.int(0), a.int(1), a.int(2), title: a.bool(3))
            return .text(encInts([pi.c, pi.r, pi.w]))
        case "panel":
            let k: UInt8 = a.color(5)
            return .int(VFDW.panel(fb, L, a.int(0), a.int(1), a.int(2), a.int(3), title: a.optStr(4), color: k))
        case "toggle":
            let k: UInt8 = a.color(7)
            return .int(VFDW.toggle(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), a.bool(4), enabled: a.bool(5),
                                    name: a.optStr(6), labelColor: k))
        case "options":
            let items: [String] = a.strs(3)
            let selected: Set<Int> = a.sel(4, items: items)
            return .int(VFDW.options(fb, L, a.int(0), a.int(1), a.int(2), items, selected: selected,
                                     label: a.optStr(5), enabled: a.bool(6), name: a.optStr(7),
                                     columns: a.optInt(8)))
        case "stepper":
            return .int(VFDW.stepper(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), a.str(4), enabled: a.bool(5),
                                     canDec: a.bool(6), canInc: a.bool(7), valueChars: a.optInt(8),
                                     name: a.optStr(9)))
        case "button":
            return .int(VFDW.button(fb, L, a.int(0), a.int(1), a.optInt(2), a.str(3), primary: a.bool(4),
                                    enabled: a.bool(5), name: a.optStr(6), alarm: a.bool(7)))
        case "buttons":
            let labels: [String] = a.strs(3)
            let primary: Int? = a.pick(4, labels: labels)
            let enabled: [Bool]? = a.optBools(5)
            let alarm: Int? = a.pick(8, labels: labels)
            return .int(VFDW.buttons(fb, L, a.int(0), a.int(1), a.int(2), labels, primary: primary,
                                     enabled: enabled, gap: a.int(6), equal: a.bool(7), alarm: alarm))
        case "slider":
            return .int(VFDW.slider(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), a.str(4), a.dbl(5),
                                    hint: a.optStr(6), enabled: a.bool(7), zone: a.zone(8), marker: a.bool(9),
                                    name: a.optStr(10), canDec: a.optBool(11), canInc: a.optBool(12)))
        case "meter":
            let k: UInt8 = a.color(8)
            return .int(VFDW.meter(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), a.str(4), a.dbl(5),
                                   zone: a.zone(6), marker: a.bool(7), color: k))
        case "field":
            let k: UInt8 = a.color(8)
            return .int(VFDW.field(fb, L, a.int(0), a.int(1), a.int(2), a.optStr(3), a.str(4),
                                   placeholder: a.str(5), focused: a.bool(6), name: a.optStr(7), valueColor: k))
        case "packet_row":
            let k: UInt8 = a.color(10)
            return .int(VFDW.packetRow(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), a.str(4),
                                       subtitle: a.str(5), tag: a.optStr(6), selected: a.bool(7),
                                       right: a.optStr(8), name: a.optStr(9), hexColor: k))
        case "chart":
            let values: [Double?] = a.dbls(5)
            let k: UInt8 = a.color(9)
            return .int(VFDW.chart(fb, L, a.int(0), a.int(1), a.int(2), a.int(3), a.optStr(4), values,
                                   valueText: a.optStr(6), vmin: a.optDbl(7), vmax: a.optDbl(8), color: k))
        case "list_scrollbar":
            VFDW.listScrollbar(fb, a.int(0), a.int(1), a.int(2), a.int(3))
        case "token_lines":
            return .text(encStrs(VFDW.tokenLines(a.str(0), a.int(1), sep: a.str(2))))
        case "interval_stop":
            return .int(VFDW.intervalStop(a.dbl(0)))
        case "interval_text":
            return .text(esc(VFDW.intervalText(a.dbl(0))))
        case "interval_slider":
            return .int(VFDW.intervalSlider(fb, L, a.int(0), a.int(1), a.int(2), a.str(3), a.dbl(4),
                                            name: a.str(5)))
        case "menu_button":
            return .int(VFDW.menuButton(fb, L, a.int(0), a.int(1), a.str(2), enabled: a.bool(3),
                                        name: a.optStr(4)))
        case "led":
            let k: UInt8 = a.color(4)
            VFDW.led(fb, a.int(0), a.int(1), a.optInt(2), size: a.int(3), color: k, fill: a.optRGB(5))
        default:
            errors.append("unknown op \(op)")
            return .text("ERROR unknown op " + op)
        }
        return .none
    }

    /// Run a block's ops on target; returns the last int an op returned.
    func replay(_ ops: [BlockOp], on target: VFDFrameBuffer, page p: Page) -> Int? {
        var last: Int? = nil
        for o in ops {
            let r: Ret = runOp(o.op, Args(f: o.fields, fb: target), p)
            if case .int(let n) = r {
                last = n
            }
        }
        return last
    }

    func closeBlock(_ b: Block, _ op: String, _ raw: [String], _ p: Page) -> Ret {
        if op == "window_end" {
            let ends = Args(f: raw, fb: p.fb)
            let win = VFDW.snappedWindow(p.fb, top: ends.int(0), bottom: ends.int(1),
                                         draw: { (target: VFDFrameBuffer) -> Void in
                                             _ = self.replay(b.ops, on: target, page: p)
                                         })
            return .text(encInts([win.top, win.bottom]))
        }
        // screen_end: render_previews.draw_screen with the block as the screen's draw()
        let a = Args(f: b.fields, fb: p.fb)
        let tabRaw: String = a.str(0)
        let tab: String = VFDW.tabKey(tabRaw) ?? tabRaw
        var title: String = a.str(1)
        if title.isEmpty {
            for t in VFDW.tabs where t.key == tab {
                title = t.label
            }
        }
        let rightColor: UInt8 = UInt8(clamping: Int(a.raw(5)) ?? 0)
        let spec: String = unesc(raw.first ?? "none")
        let fb: VFDFrameBuffer = p.device.framebuffer(p.base)
        let end: Int? = VFDW.drawScreen(fb, p.L, tab: tab, title: title, telemetry: a.str(2), back: a.bool(3),
                                        right: a.optStr(4), rightColor: rightColor, rightTap: a.optStr(6),
                                        scroll: a.int(7),
                                        draw: { (target: VFDFrameBuffer, layout: VFDLayout) -> Int? in
                                            let last: Int? = self.replay(b.ops, on: target, page: p)
                                            if spec == "last" { return last }
                                            if spec == "none" { return nil }
                                            return Int(spec)
                                        })
        p.fb = fb
        if let e = end {
            return .int(e)
        }
        return .none
    }

    func finish() {
        guard let p = page else { return }
        let fb: VFDFrameBuffer = p.fb
        var hexes: [String] = []
        for c in fb.trueColors {
            hexes.append(c.hex)
        }
        p.lines.append("colors\t\(fb.trueColors.count)\t" + encStrs(hexes))
        for t in fb.taps {
            p.lines.append("hit\t\(t.c)\t\(t.r)\t\(t.w)\t\(t.h)\t" + esc(t.name))
        }
        for g in fb.scrollRegions {
            p.lines.append("region\t" + esc(g.id) + "\t\(g.c)\t\(g.r)\t\(g.w)\t\(g.h)\t\(g.contentRows)")
        }
        var lit: Int = 0
        for v in fb.cells where v != 0 {
            lit += 1
        }
        p.lines.append("cells\t" + fnv1a64(fb.cells) + "\t\(lit)")
        p.lines.append("end\t" + esc(p.name))
        out.append(contentsOf: p.lines)
        pages.append(p)
        page = nil
    }

    func run(_ lines: [String]) {
        var no: Int = 0
        for line in lines {
            no += 1
            if line.unicodeScalars.isEmpty || line.hasPrefix("#") { continue }
            let fields: [String] = splitOn(line, "\t")
            let op: String = fields[0]
            if op == "page" {
                if block != nil {
                    errors.append("line \(no): page inside a block")
                    block = nil
                }
                finish()
                let name: String = fields.count > 1 ? unesc(fields[1]) : ""
                let devKey: String = fields.count > 2 ? fields[2] : ""
                let baseRaw: String = fields.count > 3 ? fields[3] : "AMBER"
                guard let dev = VFDDevice.named(devKey) else {
                    errors.append("line \(no): unknown device \(devKey)")
                    continue
                }
                let rawName: String = fields.count > 1 ? fields[1] : ""
                let header: String = ["page", rawName, devKey, baseRaw].joined(separator: "\t")
                page = Page(name: name, deviceKey: devKey, device: dev, base: VFDBase(persisted: unesc(baseRaw)),
                            header: header)
                continue
            }
            guard let p = page else {
                errors.append("line \(no): op before the first page")
                continue
            }
            let raw: [String] = Array(fields.dropFirst())
            if let b = block {
                let closes: Bool = (b.open == "window_begin" && op == "window_end")
                    || (b.open == "screen_begin" && op == "screen_end")
                if closes {
                    block = nil
                    let value: Ret = closeBlock(b, op, raw, p)
                    p.lines.append("ret\t\(no)\t" + op + "\t" + value.encoded)
                } else {
                    b.ops.append(BlockOp(line: no, op: op, fields: raw))
                }
                continue
            }
            if op == "window_begin" || op == "screen_begin" {
                block = Block(open: op, fields: raw)
                continue
            }
            opCount += 1
            let value: Ret = runOp(op, Args(f: raw, fb: p.fb), p)
            p.lines.append("ret\t\(no)\t" + op + "\t" + value.encoded)
        }
        if block != nil {
            errors.append("unterminated block at the end of ops.txt")
        }
        finish()
    }

    func writeDumps(_ folder: String) {
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                    attributes: nil)
        } catch {
            print("NOTE: cannot create \(folder): \(error)")
            return
        }
        let alphabet: [UInt8] = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        var index: Int = 0
        for p in pages {
            index += 1
            let fb: VFDFrameBuffer = p.fb
            var text: String = p.lines.joined(separator: "\n") + "\n"
            text += "grid\t\(fb.cols)\t\(fb.rows)\n"
            for r in 0..<fb.rows {
                var row: [UInt8] = Array((zeroPad3(r) + " ").utf8)
                for c in 0..<fb.cols {
                    let v: UInt8 = fb.cells[r * fb.cols + c]
                    if v == 0 {
                        row.append(0x2E)
                    } else if v < 5 {
                        row.append(0x30 + v)
                    } else {
                        row.append(alphabet[(Int(v) - 5) % alphabet.count])
                    }
                }
                row.append(0x0A)
                text += String(decoding: row, as: UTF8.self)
            }
            let path: String = folder + "/" + zeroPad3(index) + "_" + p.name + "_" + p.deviceKey + ".txt"
            do {
                try text.write(toFile: path, atomically: true, encoding: .utf8)
            } catch {
                print("NOTE: cannot write \(path): \(error)")
            }
        }
        print("NOTE: wrote \(pages.count) page dumps to \(folder)")
    }
}

// MARK: - Main

func clipText(_ s: String, _ n: Int) -> String {
    let a: [Unicode.Scalar] = Array(s.unicodeScalars)
    if a.count <= n { return s }
    return scalarString(Array(a[0..<n])) + "…"
}

var vfdGoldenDir: String = "tools/vfd/golden"
var vfdDumpDir: String? = nil
let vfdArgs: [String] = CommandLine.arguments
var vfdArgIndex: Int = 1
while vfdArgIndex < vfdArgs.count {
    let arg: String = vfdArgs[vfdArgIndex]
    if arg == "--dump" && vfdArgIndex + 1 < vfdArgs.count {
        vfdDumpDir = vfdArgs[vfdArgIndex + 1]
        vfdArgIndex += 2
        continue
    }
    vfdGoldenDir = arg
    vfdArgIndex += 1
}

guard let vfdOpsText = try? String(contentsOfFile: vfdGoldenDir + "/ops.txt", encoding: .utf8),
      let vfdExpectedText = try? String(contentsOfFile: vfdGoldenDir + "/expected.txt", encoding: .utf8) else {
    print("VFD: cannot read \(vfdGoldenDir)/ops.txt and expected.txt")
    exit(1)
}

let vfdChecker = Checker()
vfdChecker.run(splitOn(vfdOpsText, "\n"))
if let dir = vfdDumpDir {
    vfdChecker.writeDumps(dir)
}

var vfdWant: [(no: Int, text: String)] = []
var vfdLineNo: Int = 0
for l in splitOn(vfdExpectedText, "\n") {
    vfdLineNo += 1
    if l.unicodeScalars.isEmpty || l.hasPrefix("#") { continue }
    vfdWant.append((no: vfdLineNo, text: l))
}

let vfdGot: [String] = vfdChecker.out
var vfdMismatches: Int = 0
var vfdCurrentPage: String = ""
let vfdTotal: Int = max(vfdWant.count, vfdGot.count)
var vfdIndex: Int = 0
while vfdIndex < vfdTotal {
    let w: String = vfdIndex < vfdWant.count ? vfdWant[vfdIndex].text : "<missing>"
    let g: String = vfdIndex < vfdGot.count ? vfdGot[vfdIndex] : "<missing>"
    if w.hasPrefix("page\t") {
        vfdCurrentPage = w.replacingOccurrences(of: "\t", with: " ")
    }
    if !sameText(w, g) {
        vfdMismatches += 1
        if vfdMismatches <= 30 {
            let at: Int = vfdIndex < vfdWant.count ? vfdWant[vfdIndex].no : 0
            print("MISMATCH expected.txt:\(at) [\(vfdCurrentPage)] want: \(clipText(w, 240)) | got: \(clipText(g, 240))")
        }
    }
    vfdIndex += 1
}
for e in vfdChecker.errors.prefix(20) {
    print("MISMATCH error: \(e)")
}
let vfdSummary: String = "VFD: \(vfdChecker.pages.count) pages, \(vfdChecker.opCount) ops, "
    + "\(vfdWant.count) expected lines, \(vfdMismatches) mismatching"
print(vfdSummary)
if vfdMismatches > 0 || !vfdChecker.errors.isEmpty || vfdWant.isEmpty {
    exit(1)
}
exit(0)
