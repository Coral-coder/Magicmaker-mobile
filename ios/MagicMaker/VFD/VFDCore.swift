import Foundation

// VFD dot-matrix core: inks, base colours and the palette, the cell frame buffer with its drawing
// primitives, text metrics, hit rectangles and scroll regions.
// Port of tools/vfd/vfd.py, cell for cell (tools/vfd/golden.py + ios/VFDCheck check it).
// Foundation only: this file is also compiled with plain swiftc on Linux.

// MARK: - Inks

/// Cell values. 0...4 are the palette inks; 5...255 are true colours handed out per frame by
/// `VFDFrameBuffer.rgb(_:)`.
enum VFDInk {
    static let unlit: UInt8 = 0
    static let highlight: UInt8 = 1
    static let text: UInt8 = 2
    static let dim: UInt8 = 3
    static let alarm: UInt8 = 4
    /// Number of palette inks.
    static let count: Int = 5
    /// First cell value used for a true colour.
    static let firstTrueColor: Int = 5
    /// True-colour slots per frame (5...255).
    static let maxTrueColors: Int = 251
}

// MARK: - Integer and rounding helpers (Python semantics)

enum VFDMath {
    /// vfd._round: half away from zero, computed as floor(|x| + 0.5) like the Python reference.
    static func roundHalfAway(_ x: Double) -> Int {
        if !x.isFinite { return 0 }
        if x >= 0 {
            return toInt((x + 0.5).rounded(.down))
        }
        return -toInt((-x + 0.5).rounded(.down))
    }

    /// Python's round(): half to even.
    static func roundHalfEven(_ x: Double) -> Int {
        if !x.isFinite { return 0 }
        return toInt(x.rounded(.toNearestOrEven))
    }

    /// Python's int(x): truncation toward zero.
    static func truncate(_ x: Double) -> Int {
        if !x.isFinite { return 0 }
        return toInt(x.rounded(.towardZero))
    }

    /// Double -> Int without trapping on huge values.
    static func toInt(_ x: Double) -> Int {
        if x.isNaN { return 0 }
        if x >= 9.0e18 { return Int.max }
        if x <= -9.0e18 { return Int.min }
        return Int(x)
    }

    /// Python a // b (rounds toward negative infinity). 0 when b == 0.
    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        if b == 0 { return 0 }
        let q: Int = a / b
        if (a % b != 0) && ((a < 0) != (b < 0)) {
            return q - 1
        }
        return q
    }

    /// Python a % b (the sign of b). 0 when b == 0.
    static func floorMod(_ a: Int, _ b: Int) -> Int {
        if b == 0 { return 0 }
        return a - floorDiv(a, b) * b
    }

    /// Python -(-a // b).
    static func ceilDiv(_ a: Int, _ b: Int) -> Int {
        return -floorDiv(-a, b)
    }

    /// Python float a % b (the sign of b).
    static func pyMod(_ a: Double, _ b: Double) -> Double {
        var m: Double = a.truncatingRemainder(dividingBy: b)
        if m != 0 && ((b < 0) != (m < 0)) {
            m += b
        }
        return m
    }

    static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        if v < lo { return lo }
        if v > hi { return hi }
        return v
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        if v < lo { return lo }
        if v > hi { return hi }
        return v
    }
}

// MARK: - Colours

struct VFDRGB: Equatable, Hashable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

extension VFDRGB {
    /// Channels clamped to 0...255.
    init(_ r: Int, _ g: Int, _ b: Int) {
        self.init(r: UInt8(VFDMath.clamp(r, 0, 255)),
                  g: UInt8(VFDMath.clamp(g, 0, 255)),
                  b: UInt8(VFDMath.clamp(b, 0, 255)))
    }

    /// Channels 0...1 (e.g. from a colour picker), rounded half away from zero.
    init(unitRed red: Double, green: Double, blue: Double) {
        self.init(VFDMath.roundHalfAway(red * 255.0),
                  VFDMath.roundHalfAway(green * 255.0),
                  VFDMath.roundHalfAway(blue * 255.0))
    }

    /// "#RRGGBB" (or "RRGGBB"); anything else gives black. Use `parse` to tell them apart.
    init(hex: String) {
        self = VFDRGB.parse(hex) ?? VFDRGB(r: 0, g: 0, b: 0)
    }

    /// "#RRGGBB" / "RRGGBB" (any case, surrounding whitespace and leading "#"s ignored), else nil.
    static func parse(_ hex: String) -> VFDRGB? {
        var digits: [UInt32] = []
        var seenDigit = false
        for u in VFDText.scalars(VFDText.strip(hex)) {
            if u == "#" && !seenDigit { continue }
            seenDigit = true
            let v: UInt32 = u.value
            if v >= 0x30 && v <= 0x39 {
                digits.append(v - 0x30)
            } else if v >= 0x41 && v <= 0x46 {
                digits.append(v - 0x41 + 10)
            } else if v >= 0x61 && v <= 0x66 {
                digits.append(v - 0x61 + 10)
            } else {
                return nil
            }
        }
        if digits.count != 6 { return nil }
        let r: UInt32 = digits[0] * 16 + digits[1]
        let g: UInt32 = digits[2] * 16 + digits[3]
        let b: UInt32 = digits[4] * 16 + digits[5]
        return VFDRGB(r: UInt8(r), g: UInt8(g), b: UInt8(b))
    }

    /// "#RRGGBB", uppercase.
    var hex: String {
        return "#" + VFDRGB.hex2(r) + VFDRGB.hex2(g) + VFDRGB.hex2(b)
    }

    private static func hex2(_ v: UInt8) -> String {
        let s: String = String(v, radix: 16, uppercase: true)
        return s.count < 2 ? "0" + s : s
    }
}

/// The base colour the VFD theme is drawn in: a preset name or a custom RGB. Persisted as the
/// preset name ("AMBER") or "#RRGGBB".
enum VFDBase: Equatable {
    case preset(String)
    case custom(VFDRGB)

    /// The presets in the order the BASE COLOUR selector shows them (CUSTOM comes after).
    static let presets: [(name: String, rgb: VFDRGB)] = [
        (name: "AMBER", rgb: VFDRGB(r: 0xFF, g: 0xB0, b: 0x14)),
        (name: "GREEN", rgb: VFDRGB(r: 0x3C, g: 0xFF, b: 0x6E)),
        (name: "CYAN", rgb: VFDRGB(r: 0x30, g: 0xE8, b: 0xFF)),
        (name: "BLUE", rgb: VFDRGB(r: 0x4C, g: 0xA0, b: 0xFF)),
        (name: "RED", rgb: VFDRGB(r: 0xFF, g: 0x40, b: 0x30)),
        (name: "WHITE", rgb: VFDRGB(r: 0xF0, g: 0xF0, b: 0xF0)),
    ]

    static let amber: VFDBase = .preset("AMBER")
    static let amberRGB: VFDRGB = VFDRGB(r: 0xFF, g: 0xB0, b: 0x14)

    /// RGB of a preset name (uppercase), or nil.
    static func presetRGB(_ name: String) -> VFDRGB? {
        for p in presets where p.name == name {
            return p.rgb
        }
        return nil
    }

    /// From the persisted form: a preset name (any case) or "#RRGGBB"; anything else is AMBER.
    init(persisted: String) {
        let key: String = VFDText.strip(persisted).uppercased()
        if VFDBase.presetRGB(key) != nil {
            self = .preset(key)
        } else if let rgb = VFDRGB.parse(key) {
            self = .custom(rgb)
        } else {
            self = .preset("AMBER")
        }
    }

    /// Preset name or "#RRGGBB".
    var persisted: String {
        switch self {
        case .preset(let name):
            return VFDText.strip(name).uppercased()
        case .custom(let rgb):
            return rgb.hex
        }
    }

    /// (preset name or nil, RGB), as vfd._resolve_base. An unknown preset name is read as
    /// "#RRGGBB" if it is one, else AMBER.
    var resolved: (name: String?, rgb: VFDRGB) {
        switch self {
        case .custom(let rgb):
            return (name: nil, rgb: rgb)
        case .preset(let raw):
            let key: String = VFDText.strip(raw).uppercased()
            if let rgb = VFDBase.presetRGB(key) {
                return (name: key, rgb: rgb)
            }
            if let rgb = VFDRGB.parse(key) {
                return (name: nil, rgb: rgb)
            }
            return (name: "AMBER", rgb: VFDBase.amberRGB)
        }
    }

    var rgb: VFDRGB {
        return resolved.rgb
    }
}

enum VFDPalette {
    static let background: VFDRGB = VFDRGB(r: 0x00, g: 0x00, b: 0x00)
    static let unlitRGB: VFDRGB = VFDRGB(r: 0x09, g: 0x09, b: 0x09)
    static let alarmRGB: VFDRGB = VFDRGB(r: 0xFF, g: 0x50, b: 0x28)
    /// Degrees: a base this close to the alarm hue draws alarms as inverted blocks.
    static let alarmHueWindow: Double = 25.0

    /// The AMBER preset: exactly the spec colours (unlit, highlight, text, dim, alarm).
    static let amber: [VFDRGB] = [
        VFDRGB(r: 0x09, g: 0x09, b: 0x09),
        VFDRGB(r: 0xFF, g: 0xB0, b: 0x14),
        VFDRGB(r: 0xFF, g: 0xE8, b: 0xC4),
        VFDRGB(r: 0x96, g: 0x64, b: 0x28),
        VFDRGB(r: 0xFF, g: 0x50, b: 0x28),
    ]

    /// Rec. 709 luminance, 0...255.
    static func luma(_ c: VFDRGB) -> Double {
        let r: Double = 0.2126 * Double(c.r)
        let g: Double = 0.7152 * Double(c.g)
        let b: Double = 0.0722 * Double(c.b)
        return r + g + b
    }

    /// HSV hue in degrees [0, 360), or nil for a grey.
    static func hue(_ c: VFDRGB) -> Double? {
        let r: Double = Double(c.r) / 255.0
        let g: Double = Double(c.g) / 255.0
        let b: Double = Double(c.b) / 255.0
        let mx: Double = max(r, max(g, b))
        let mn: Double = min(r, min(g, b))
        let d: Double = mx - mn
        if d <= 0 { return nil }
        var h: Double
        if mx == r {
            h = VFDMath.pyMod((g - b) / d, 6.0)
        } else if mx == g {
            h = (b - r) / d + 2.0
        } else {
            h = (r - g) / d + 4.0
        }
        h = VFDMath.pyMod(h * 60.0, 360.0)
        return h
    }

    /// The 5 ink colours for a base (vfd.palette_for): AMBER is the spec palette; any other base
    /// gives highlight = base, dim = 0.59 * (0.85 * base + 0.15 * luma), text = 0.75 * 255 +
    /// 0.25 * base, alarm #FF5028, unlit #090909.
    static func colors(for base: VFDBase) -> [VFDRGB] {
        let res = base.resolved
        if res.name == "AMBER" || res.rgb == VFDBase.amberRGB {
            return amber
        }
        let rgb: VFDRGB = res.rgb
        let y: Double = luma(rgb)
        let dim = VFDRGB(r: dimChannel(rgb.r, y), g: dimChannel(rgb.g, y), b: dimChannel(rgb.b, y))
        let text = VFDRGB(r: textChannel(rgb.r), g: textChannel(rgb.g), b: textChannel(rgb.b))
        return [unlitRGB, rgb, text, dim, alarmRGB]
    }

    /// True when the base is red-ish (hue within 25 degrees of the alarm's): alarms are then drawn
    /// as inverted highlight blocks (blinking at 1 Hz in the app).
    static func alarmInverted(_ base: VFDBase) -> Bool {
        guard let h = hue(base.resolved.rgb), let ah = hue(alarmRGB) else { return false }
        let d: Double = VFDMath.pyMod(abs(h - ah), 360.0)
        return min(d, 360.0 - d) <= alarmHueWindow
    }

    private static func dimChannel(_ v: UInt8, _ y: Double) -> UInt8 {
        let x: Double = 0.59 * (0.85 * Double(v) + 0.15 * y)
        return UInt8(VFDMath.clamp(VFDMath.roundHalfAway(x), 0, 255))
    }

    private static func textChannel(_ v: UInt8) -> UInt8 {
        let x: Double = 0.75 * 255.0 + 0.25 * Double(v)
        return UInt8(VFDMath.clamp(VFDMath.roundHalfAway(x), 0, 255))
    }
}

// MARK: - Devices

/// A target screen (vfd.Device): cols = pxW / pitch, rows = pxH / pitch, safe rows =
/// ceil(pt * scale / pitch).
struct VFDDevice: Equatable {
    let key: String
    let name: String
    let pxW: Int
    let pxH: Int
    let scale: Int
    let pitch: Int
    let safeTopPt: Int
    let safeBottomPt: Int

    var cols: Int { return VFDMath.floorDiv(pxW, pitch) }
    var rows: Int { return VFDMath.floorDiv(pxH, pitch) }
    var safeTop: Int { return VFDMath.ceilDiv(safeTopPt * scale, pitch) }
    var safeBottom: Int { return VFDMath.ceilDiv(safeBottomPt * scale, pitch) }

    static let pro = VFDDevice(key: "pro", name: "iPhone 17 Pro", pxW: 1206, pxH: 2622, scale: 3, pitch: 5,
                               safeTopPt: 62, safeBottomPt: 34)
    static let x2 = VFDDevice(key: "x2", name: "iPhone 11", pxW: 828, pxH: 1792, scale: 2, pitch: 4,
                              safeTopPt: 48, safeBottomPt: 34)

    static func named(_ key: String) -> VFDDevice? {
        if key == pro.key { return pro }
        if key == x2.key { return x2 }
        return nil
    }

    /// A blank frame buffer of this size, set up for the base colour.
    func framebuffer(_ base: VFDBase) -> VFDFrameBuffer {
        return VFDFrameBuffer(cols: cols, rows: rows, base: base)
    }
}

// MARK: - Text

enum VFDSize: Equatable {
    case small, mid, big

    var metrics: VFDGlyphs.Metrics {
        switch self {
        case .small: return VFDGlyphs.smallMetrics
        case .mid: return VFDGlyphs.midMetrics
        case .big: return VFDGlyphs.bigMetrics
        }
    }

    /// Glyph box width in cells.
    var w: Int { return metrics.width }
    /// Glyph box height in cells (descender included).
    var h: Int { return metrics.height }
    var ascent: Int { return metrics.ascent }
    var advance: Int { return metrics.advance }
    var line: Int { return metrics.line }

    var name: String {
        switch self {
        case .small: return "small"
        case .mid: return "mid"
        case .big: return "big"
        }
    }

    init?(name: String) {
        switch name {
        case "small": self = .small
        case "mid": self = .mid
        case "big": self = .big
        default: return nil
        }
    }

    fileprivate var rowTable: [UInt32] {
        switch self {
        case .small: return VFDGlyphs.smallRows
        case .mid: return VFDGlyphs.midRows
        case .big: return VFDGlyphs.bigRows
        }
    }

    fileprivate var fallback: [UInt32] {
        switch self {
        case .small: return VFDGlyphs.smallFallback
        case .mid: return VFDGlyphs.midFallback
        case .big: return VFDGlyphs.bigFallback
        }
    }
}

/// Text metrics and wrapping (vfd.text_width, max_chars, fit_text, wrap_text). Lengths count
/// Unicode scalars, as Python counts code points.
enum VFDText {
    static let ellipsis: String = "…"
    static let ellipsisScalar: Unicode.Scalar = "…"
    /// U+00A0: drawn as a space, never a line break.
    static let nbsp: Unicode.Scalar = "\u{00A0}"
    /// A lone separator word wrap() never puts at the start or end of a line.
    static let wrapDot: Unicode.Scalar = "·"
    /// Dashes wrap() keeps at the end of the line before a break.
    static let wrapDashes: [Unicode.Scalar] = ["—", "–"]

    private static let space: Unicode.Scalar = " "

    // --- scalar helpers ---

    static func scalars(_ s: String) -> [Unicode.Scalar] {
        return Array(s.unicodeScalars)
    }

    static func string(_ a: [Unicode.Scalar]) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: a)
        return String(view)
    }

    /// Number of Unicode scalars (Python len()).
    static func length(_ s: String) -> Int {
        return s.unicodeScalars.count
    }

    /// Python str.isspace() for one character.
    static func isSpace(_ u: Unicode.Scalar) -> Bool {
        let v: UInt32 = u.value
        if v >= 0x09 && v <= 0x0D { return true }
        if v >= 0x1C && v <= 0x20 { return true }
        if v == 0x85 || v == 0xA0 || v == 0x1680 { return true }
        if v >= 0x2000 && v <= 0x200A { return true }
        if v == 0x2028 || v == 0x2029 || v == 0x202F || v == 0x205F || v == 0x3000 { return true }
        return false
    }

    /// Python rstrip() on scalars.
    static func rstrip(_ a: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var end: Int = a.count
        while end > 0 && isSpace(a[end - 1]) {
            end -= 1
        }
        return Array(a[0..<end])
    }

    /// Python strip().
    static func strip(_ s: String) -> String {
        let a = scalars(s)
        var start: Int = 0
        var end: Int = a.count
        while start < end && isSpace(a[start]) {
            start += 1
        }
        while end > start && isSpace(a[end - 1]) {
            end -= 1
        }
        return string(Array(a[start..<end]))
    }

    /// Python str.split(sep) on scalars (sep non-empty): empty pieces kept.
    static func split(_ a: [Unicode.Scalar], _ sep: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
        if sep.isEmpty { return [a] }
        var out: [[Unicode.Scalar]] = []
        var cur: [Unicode.Scalar] = []
        let n: Int = a.count
        let m: Int = sep.count
        var i: Int = 0
        while i < n {
            if i + m <= n && matches(a, i, sep) {
                out.append(cur)
                cur = []
                i += m
            } else {
                cur.append(a[i])
                i += 1
            }
        }
        out.append(cur)
        return out
    }

    private static func matches(_ a: [Unicode.Scalar], _ at: Int, _ sep: [Unicode.Scalar]) -> Bool {
        var k: Int = 0
        while k < sep.count {
            if a[at + k] != sep[k] { return false }
            k += 1
        }
        return true
    }

    private static func endsWithSpaceDot(_ a: [Unicode.Scalar]) -> Bool {
        let n: Int = a.count
        return n >= 2 && a[n - 2] == space && a[n - 1] == wrapDot
    }

    // --- metrics ---

    /// Rows of one glyph (size.h rows, bit 0 = leftmost); the hollow box for an unknown character.
    static func glyphRows(_ u: Unicode.Scalar, _ size: VFDSize) -> ArraySlice<UInt32> {
        let v: UInt32 = (u == nbsp) ? 0x20 : u.value
        let h: Int = size.h
        if let slot = VFDGlyphs.slot(v) {
            let table: [UInt32] = size.rowTable
            let start: Int = slot * h
            if start >= 0 && start + h <= table.count {
                return table[start..<(start + h)]
            }
        }
        return size.fallback[...]
    }

    /// Ink width of `count` characters: count * advance - (advance - w); 0 for none.
    static func width(count n: Int, size: VFDSize = .small) -> Int {
        if n <= 0 { return 0 }
        return n * size.advance - (size.advance - size.w)
    }

    /// Ink width of s in cells (vfd.text_width).
    static func width(_ s: String, size: VFDSize = .small) -> Int {
        return width(count: s.unicodeScalars.count, size: size)
    }

    /// Largest number of characters whose ink fits in maxCols cells (vfd.max_chars).
    static func maxChars(_ maxCols: Int, size: VFDSize = .small) -> Int {
        if maxCols < size.w { return 0 }
        return VFDMath.floorDiv(maxCols + size.advance - size.w, size.advance)
    }

    /// s unchanged if it fits, else cut and ended with "…" (trailing spaces before it dropped)
    /// (vfd.fit_text).
    static func fit(_ s: String, _ maxCols: Int, size: VFDSize = .small) -> String {
        let n: Int = maxChars(maxCols, size: size)
        let a = scalars(s)
        if a.count <= n { return s }
        if n <= 0 { return "" }
        let head = rstrip(Array(a[0..<(n - 1)]))
        return string(head) + ellipsis
    }

    /// Word wrap into lines that fit maxCols cells (vfd.wrap_text): breaks on plain spaces (runs
    /// collapse; U+00A0 never breaks), hard-breaks long words, honours "\n" (blank lines kept); a
    /// lone "·" on a break is dropped, a lone dash stays at the end of the line with its word.
    static func wrap(_ s: String, _ maxCols: Int, size: VFDSize = .small) -> [String] {
        let n: Int = maxChars(maxCols, size: size)
        let all = scalars(s)
        if n <= 0 || all.isEmpty { return [] }
        var out: [String] = []
        let spaceSep: [Unicode.Scalar] = [space]
        let newline: [Unicode.Scalar] = ["\n"]
        for para in split(all, newline) {
            var cur: [Unicode.Scalar] = []
            for piece in split(para, spaceSep) {
                var word: [Unicode.Scalar] = piece
                if word.isEmpty { continue }
                if !cur.isEmpty && cur.count + 1 + word.count <= n {
                    cur.append(space)
                    cur.append(contentsOf: word)
                    continue
                }
                if word.count == 1 && word[0] == wrapDot {
                    if !cur.isEmpty {
                        out.append(string(cur))
                    }
                    cur = []
                    continue
                }
                let isDash: Bool = word.count == 1 && wrapDashes.contains(word[0])
                if isDash && !cur.isEmpty, let sp = cur.lastIndex(of: space) {
                    var head: [Unicode.Scalar] = Array(cur[0..<sp])
                    let last: [Unicode.Scalar] = Array(cur[(sp + 1)...])
                    if endsWithSpaceDot(head) {
                        head.removeLast(2)
                    }
                    out.append(string(head))
                    var next: [Unicode.Scalar] = last
                    next.append(space)
                    next.append(contentsOf: word)
                    cur = next
                    continue
                }
                if !cur.isEmpty {
                    if endsWithSpaceDot(cur) {
                        cur.removeLast(2)
                    }
                    out.append(string(cur))
                }
                while word.count > n {
                    out.append(string(Array(word[0..<n])))
                    word = Array(word[n...])
                }
                cur = word
            }
            if endsWithSpaceDot(cur) {
                cur.removeLast(2)
            }
            out.append(string(cur))
        }
        return out
    }
}

// MARK: - Hits and scroll regions

/// A tap rectangle in screen cells (clipped like drawing) with what it does. The renderer runs the
/// topmost hit's `action` on a tap, `long` on a 0.5 s hold, `swipeLeft` / `swipeRight` on a
/// horizontal swipe and `drag(fraction 0...1 across the hit's width, ended)` while dragging
/// horizontally (sliders).
struct VFDHit {
    var c: Int
    var r: Int
    var w: Int
    var h: Int
    var name: String
    var action: (() -> Void)?
    var long: (() -> Void)?
    var swipeLeft: (() -> Void)?
    var swipeRight: (() -> Void)?
    var drag: ((Double, Bool) -> Void)?

    init(c: Int, r: Int, w: Int, h: Int, name: String, action: (() -> Void)? = nil,
         long: (() -> Void)? = nil, swipeLeft: (() -> Void)? = nil, swipeRight: (() -> Void)? = nil,
         drag: ((Double, Bool) -> Void)? = nil) {
        self.c = c
        self.r = r
        self.w = w
        self.h = h
        self.name = name
        self.action = action
        self.long = long
        self.swipeLeft = swipeLeft
        self.swipeRight = swipeRight
        self.drag = drag
    }

    func contains(_ c: Int, _ r: Int) -> Bool {
        return c >= self.c && c < self.c + w && r >= self.r && r < self.r + h
    }
}

/// A sub-area that scrolls on its own (a list under pinned rows), in screen cells. Drags that start
/// inside it scroll it instead of the page; `contentRows` is the height of everything it scrolls.
struct VFDScrollRegion: Equatable {
    var id: String
    var c: Int
    var r: Int
    var w: Int
    var h: Int
    var contentRows: Int

    func contains(_ c: Int, _ r: Int) -> Bool {
        return c >= self.c && c < self.c + w && r >= self.r && r < self.r + h
    }
}

private struct VFDClipState {
    let c0: Int
    let r0: Int
    let c1: Int
    let r1: Int
    let oy: Int
}

// MARK: - Frame buffer

/// cols x rows cells, one byte per cell (an ink or a true-colour index). All drawing is in whole
/// cells and goes through the current clip rectangle and vertical origin offset:
/// pushClip(c, r, w, h, dy:) intersects the clip with the rect (in drawing coordinates) and then
/// adds dy to the origin, so drawing row r lands on screen row r + originY; popClip() restores both.
final class VFDFrameBuffer {
    /// Rows an led bar occupies (r ... r + 5).
    static let ledBarH: Int = 6

    let cols: Int
    let rows: Int
    var cells: [UInt8]
    /// Tap rectangles in screen cells, last = topmost.
    var taps: [VFDHit] = []
    var scrollRegions: [VFDScrollRegion] = []
    /// From VFDPalette.alarmInverted(base): alarms are drawn as inverted highlight blocks.
    var alarmInverted: Bool
    /// The base colour the buffer is drawn in.
    var base: VFDBase = .preset("AMBER")
    /// Set by a screen while something animated is visible (the renderer then redraws at 30 fps).
    var wantsAnimation: Bool = false
    /// RGB of cell value firstTrueColor + i, this frame only.
    private(set) var trueColors: [VFDRGB] = []
    private var trueColorSlots: [VFDRGB: UInt8] = [:]

    private var clipC0: Int = 0
    private var clipR0: Int = 0
    private var clipC1: Int
    private var clipR1: Int
    private var oy: Int = 0
    private var stack: [VFDClipState] = []

    init(cols: Int, rows: Int, alarmInverted: Bool = false) {
        let c: Int = max(0, cols)
        let r: Int = max(0, rows)
        self.cols = c
        self.rows = r
        self.cells = [UInt8](repeating: 0, count: c * r)
        self.alarmInverted = alarmInverted
        self.clipC1 = c
        self.clipR1 = r
    }

    /// A buffer for a base colour: alarmInverted follows the base.
    convenience init(cols: Int, rows: Int, base: VFDBase) {
        self.init(cols: cols, rows: rows, alarmInverted: VFDPalette.alarmInverted(base))
        self.base = base
    }

    // MARK: state

    /// Current vertical origin offset (drawing row r lands on screen row r + originY).
    var originY: Int { return oy }

    /// Current clip in screen cells.
    var clipRect: (c: Int, r: Int, w: Int, h: Int) {
        return (c: clipC0, r: clipR0, w: clipC1 - clipC0, h: clipR1 - clipR0)
    }

    /// Number of pushClip() calls not popped yet.
    var clipDepth: Int { return stack.count }

    /// Intersect the clip with (c, r, w, h), given in drawing coordinates, then add dy to the
    /// origin (dy = -scroll for a scrolled content region).
    func pushClip(_ c: Int, _ r: Int, _ w: Int, _ h: Int, dy: Int = 0) {
        stack.append(VFDClipState(c0: clipC0, r0: clipR0, c1: clipC1, r1: clipR1, oy: oy))
        let rr: Int = r + oy
        let nc0: Int = max(clipC0, c)
        let nr0: Int = max(clipR0, rr)
        let nc1: Int = min(clipC1, c + w)
        let nr1: Int = min(clipR1, rr + h)
        clipC0 = nc0
        clipR0 = nr0
        clipC1 = max(nc0, nc1)
        clipR1 = max(nr0, nr1)
        oy += dy
    }

    /// Restore the clip and origin saved by the matching pushClip() (no-op without one).
    func popClip() {
        guard let s = stack.popLast() else { return }
        clipC0 = s.c0
        clipR0 = s.r0
        clipC1 = s.c1
        clipR1 = s.r1
        oy = s.oy
    }

    /// pushClip, body, popClip.
    func clipped(_ c: Int, _ r: Int, _ w: Int, _ h: Int, dy: Int = 0, _ body: () -> Void) {
        pushClip(c, r, w, h, dy: dy)
        body()
        popClip()
    }

    /// Every cell to color (ignores the clip); forgets taps, scroll regions, true colours and
    /// wantsAnimation. The clip stack is kept.
    func clear(_ color: UInt8 = VFDInk.unlit) {
        // Refilled in place (the renderer clears two buffers per frame at 30 fps).
        let n: Int = cols * rows
        if cells.count == n {
            cells.withUnsafeMutableBufferPointer { (buf: inout UnsafeMutableBufferPointer<UInt8>) in
                for i in 0..<buf.count {
                    buf[i] = color
                }
            }
        } else {
            cells = [UInt8](repeating: color, count: n)
        }
        taps.removeAll(keepingCapacity: true)
        scrollRegions.removeAll(keepingCapacity: true)
        trueColors.removeAll(keepingCapacity: true)
        trueColorSlots.removeAll(keepingCapacity: true)
        wantsAnimation = false
    }

    /// Cell value at screen cell (c, r), ignoring clip and origin; 0 outside the buffer.
    func get(_ c: Int, _ r: Int) -> UInt8 {
        if c >= 0 && c < cols && r >= 0 && r < rows {
            return cells[r * cols + c]
        }
        return VFDInk.unlit
    }

    // MARK: true colours

    /// Cell value for a true colour in this frame (firstTrueColor + its slot). The same colour gets
    /// the same value; once all 251 slots are used the nearest colour already in the table
    /// (smallest squared RGB distance, the first one on a tie) is returned.
    func rgb(_ color: VFDRGB) -> UInt8 {
        if let slot = trueColorSlots[color] {
            return slot
        }
        if trueColors.count < VFDInk.maxTrueColors {
            trueColors.append(color)
            let value: UInt8 = UInt8(VFDInk.firstTrueColor + trueColors.count - 1)
            trueColorSlots[color] = value
            return value
        }
        var best: Int = 0
        var bestD: Int = Int.max
        var i: Int = 0
        for t in trueColors {
            let dr: Int = Int(t.r) - Int(color.r)
            let dg: Int = Int(t.g) - Int(color.g)
            let db: Int = Int(t.b) - Int(color.b)
            let d: Int = dr * dr + dg * dg + db * db
            if d < bestD {
                best = i
                bestD = d
            }
            i += 1
        }
        return UInt8(VFDInk.firstTrueColor + best)
    }

    /// 256 colours for the cell values: the 5 inks of the base, the true colours, black after.
    func colorTable(_ base: VFDBase) -> [VFDRGB] {
        var table: [VFDRGB] = VFDPalette.colors(for: base)
        table.append(contentsOf: trueColors)
        while table.count < 256 {
            table.append(VFDPalette.background)
        }
        return table
    }

    /// The cells as RGBA bytes, one pixel per cell, row-major (alpha 255).
    func rgbaBytes(_ base: VFDBase) -> [UInt8] {
        let table: [VFDRGB] = colorTable(base)
        var out = [UInt8](repeating: 255, count: cells.count * 4)
        var j: Int = 0
        for v in cells {
            let c: VFDRGB = table[Int(v)]
            out[j] = c.r
            out[j + 1] = c.g
            out[j + 2] = c.b
            j += 4
        }
        return out
    }

    // MARK: primitives

    /// Light one cell.
    func set(_ c: Int, _ r: Int, _ color: UInt8) {
        let rr: Int = r + oy
        if c >= clipC0 && c < clipC1 && rr >= clipR0 && rr < clipR1 {
            cells[rr * cols + c] = color
        }
    }

    /// Solid w x h rectangle with its top-left cell at (c, r).
    func fill(_ c: Int, _ r: Int, _ w: Int, _ h: Int, _ color: UInt8) {
        let rr: Int = r + oy
        let ca: Int = max(c, clipC0)
        let cb: Int = min(c + w, clipC1)
        let ra: Int = max(rr, clipR0)
        let rb: Int = min(rr + h, clipR1)
        if ca >= cb || ra >= rb { return }
        var y: Int = ra
        while y < rb {
            let base: Int = y * cols
            var x: Int = ca
            while x < cb {
                cells[base + x] = color
                x += 1
            }
            y += 1
        }
    }

    /// Horizontal line of length cells from (c, r) to the right; step 2 lights every other cell
    /// (dotted), starting with (c, r).
    func hline(_ c: Int, _ r: Int, _ length: Int, _ color: UInt8, step: Int = 1) {
        if step < 1 { return }
        if step == 1 {
            fill(c, r, length, 1, color)
            return
        }
        for i in stride(from: 0, to: length, by: step) {
            self.set(c + i, r, color)
        }
    }

    /// Vertical line of length cells from (c, r) downwards; step as for hline.
    func vline(_ c: Int, _ r: Int, _ length: Int, _ color: UInt8, step: Int = 1) {
        if step < 1 { return }
        if step == 1 {
            fill(c, r, 1, length, color)
            return
        }
        for i in stride(from: 0, to: length, by: step) {
            self.set(c, r + i, color)
        }
    }

    /// 1-cell border of a w x h rectangle whose top-left cell is (c, r).
    func box(_ c: Int, _ r: Int, _ w: Int, _ h: Int, _ color: UInt8) {
        if w <= 0 || h <= 0 { return }
        fill(c, r, w, 1, color)
        fill(c, r + h - 1, w, 1, color)
        fill(c, r, 1, h, color)
        fill(c + w - 1, r, 1, h, color)
    }

    // MARK: text

    private func blit(_ c: Int, _ r: Int, _ glyph: ArraySlice<UInt32>, _ w: Int, _ h: Int, _ color: UInt8) {
        let mask: UInt32 = w >= 32 ? UInt32.max : (UInt32(1) << UInt32(w)) - 1
        let n: Int = min(h, glyph.count)
        var dy: Int = 0
        var index: Int = glyph.startIndex
        while dy < n {
            var bits: UInt32 = glyph[index] & mask
            let y: Int = r + dy + oy
            if bits != 0 && y >= clipR0 && y < clipR1 {
                let base: Int = y * cols
                var x: Int = c
                while bits != 0 {
                    if (bits & 1) != 0 && x >= clipC0 && x < clipC1 {
                        cells[base + x] = color
                    }
                    bits >>= 1
                    x += 1
                }
            }
            dy += 1
            index += 1
        }
    }

    /// Draw s with the first glyph box's top-left at (c, r). Returns the end column
    /// c + length * advance.
    @discardableResult
    func text(_ c: Int, _ r: Int, _ s: String, _ size: VFDSize = .small, _ color: UInt8 = VFDInk.text) -> Int {
        let w: Int = size.w
        let h: Int = size.h
        let adv: Int = size.advance
        var x: Int = c
        for u in s.unicodeScalars {
            blit(x, r, VFDText.glyphRows(u, size), w, h, color)
            x += adv
        }
        return x
    }

    /// Draw s so its ink ends exactly on column rightC (inclusive). Returns the start column.
    @discardableResult
    func textRight(_ rightC: Int, _ r: Int, _ s: String, _ size: VFDSize = .small,
                   _ color: UInt8 = VFDInk.text) -> Int {
        let start: Int = rightC - VFDText.width(s, size: size) + 1
        text(start, r, s, size, color)
        return start
    }

    /// Draw s at (c, r), truncated with "…" so its ink fits in maxCols cells. Returns the end
    /// column (as text()).
    @discardableResult
    func textFit(_ c: Int, _ r: Int, _ s: String, _ maxCols: Int, _ size: VFDSize = .small,
                 _ color: UInt8 = VFDInk.text) -> Int {
        return text(c, r, VFDText.fit(s, maxCols, size: size), size, color)
    }

    /// Word-wrapped text maxCols cells wide; line = row pitch (default size.line). Returns the
    /// next row r + lines * line.
    @discardableResult
    func paragraph(_ c: Int, _ r: Int, _ s: String, _ maxCols: Int, _ size: VFDSize = .small,
                   _ color: UInt8 = VFDInk.text, line: Int? = nil) -> Int {
        let lines: [String] = VFDText.wrap(s, maxCols, size: size)
        let step: Int = line ?? size.line
        var i: Int = 0
        for ln in lines {
            text(c, r + i * step, ln, size, color)
            i += 1
        }
        return r + lines.count * step
    }

    /// Inverted text: a solid block in color (ink width + pad each side, glyph height + pad above
    /// and below) with the glyph cells left unlit. Returns c + ink width + pad (c for "").
    @discardableResult
    func inverted(_ c: Int, _ r: Int, _ s: String, _ size: VFDSize = .small, pad: Int = 1,
                  color: UInt8 = VFDInk.highlight) -> Int {
        let tw: Int = VFDText.width(s, size: size)
        if tw == 0 { return c }
        fill(c - pad, r - pad, tw + 2 * pad, size.h + 2 * pad, color)
        text(c, r, s, size, VFDInk.unlit)
        return c + tw + pad
    }

    /// Alarm text: ALARM ink, or an inverted HIGHLIGHT block when alarmInverted. Same footprint
    /// and return value as inverted().
    @discardableResult
    func alarm(_ c: Int, _ r: Int, _ s: String, _ size: VFDSize = .small, pad: Int = 1) -> Int {
        if alarmInverted {
            return inverted(c, r, s, size, pad: pad, color: VFDInk.highlight)
        }
        text(c, r, s, size, VFDInk.alarm)
        let tw: Int = VFDText.width(s, size: size)
        return tw != 0 ? c + tw + pad : c
    }

    // MARK: indicators

    /// LED bar w cells wide, 6 rows from r: a dotted track on rows r+2, r+3; marker false = a solid
    /// lit zone of round(frac * w) cells on rows r+1 ... r+4; marker true = a 3 x 6 marker centred
    /// on c + round(frac * (w - 1)), kept inside the bar; zone (lo, hi) = a solid target zone on the
    /// track rows. Returns r + 6.
    @discardableResult
    func ledBar(_ c: Int, _ r: Int, _ w: Int, _ frac: Double, color: UInt8 = VFDInk.highlight,
                track: UInt8 = VFDInk.dim, marker: Bool = false, zone: (Double, Double)? = nil) -> Int {
        let barH: Int = VFDFrameBuffer.ledBarH
        if w <= 0 { return r + barH }
        let f: Double = VFDMath.clamp(frac, 0.0, 1.0)
        hline(c, r + 2, w, track, step: 2)
        hline(c, r + 3, w, track, step: 2)
        if let z = zone {
            let lo: Double = VFDMath.clamp(z.0, 0.0, 1.0)
            let hi: Double = VFDMath.clamp(z.1, 0.0, 1.0)
            let a: Int = c + VFDMath.roundHalfAway(lo * Double(w))
            let b: Int = c + VFDMath.roundHalfAway(hi * Double(w))
            fill(min(a, b), r + 2, abs(b - a), 2, color)
        }
        if marker {
            let mw: Int = min(3, w)
            var left: Int = c + VFDMath.roundHalfAway(f * Double(w - 1)) - 1
            left = VFDMath.clamp(left, c, c + w - mw)
            fill(left, r, mw, barH, color)
        } else {
            fill(c, r + 1, VFDMath.roundHalfAway(f * Double(w)), 4, color)
        }
        return r + barH
    }

    /// Single-cell line chart in the w x h box at (c, r): values resampled to one per column,
    /// vmin (default min) on the bottom row, vmax (default max) on the top row, a flat series on
    /// the middle row, steeper steps joined vertically, nil = a gap; dotted baseline on the bottom
    /// row first (nil = none). Returns r + h.
    @discardableResult
    func lineChart(_ c: Int, _ r: Int, _ w: Int, _ h: Int, _ values: [Double?],
                   color: UInt8 = VFDInk.highlight, vmin: Double? = nil, vmax: Double? = nil,
                   baseline: UInt8? = VFDInk.dim) -> Int {
        if w <= 0 || h <= 0 { return r + max(h, 0) }
        if let bl = baseline {
            hline(c, r + h - 1, w, bl, step: 2)
        }
        let vals: [Double?] = VFDFrameBuffer.resample(values, w)
        var present: [Double] = []
        for v in vals {
            if let x = v { present.append(x) }
        }
        if present.isEmpty { return r + h }
        var lo: Double = present[0]
        var hi: Double = present[0]
        for x in present {
            if x < lo { lo = x }
            if x > hi { hi = x }
        }
        if let m = vmin { lo = m }
        if let m = vmax { hi = m }
        let bottom: Int = r + h - 1
        var ys: [Int?] = []
        for v in vals {
            guard let x = v else {
                ys.append(nil)
                continue
            }
            if hi == lo {
                ys.append(r + VFDMath.floorDiv(h - 1, 2))
            } else {
                let t: Double = (x - lo) / (hi - lo) * Double(h - 1)
                let y: Int = bottom - VFDMath.roundHalfAway(t)
                ys.append(VFDMath.clamp(y, r, bottom))
            }
        }
        var prev: Int? = nil
        var i: Int = 0
        for yv in ys {
            defer { i += 1 }
            guard let y = yv else {
                prev = nil
                continue
            }
            let x: Int = c + i
            self.set(x, y, color)
            if let p = prev {
                if y > p + 1 {
                    let m: Int = VFDMath.floorDiv(p + y, 2)
                    vline(x - 1, p, m - p + 1, color)
                    vline(x, m + 1, y - m, color)
                } else if y < p - 1 {
                    let m: Int = VFDMath.floorDiv(p + y + 1, 2)
                    vline(x - 1, m, p - m + 1, color)
                    vline(x, y, m - y, color)
                }
            }
            prev = y
        }
        return r + h
    }

    /// Linear resample of values (nil = gap) to exactly w samples (vfd._resample).
    static func resample(_ values: [Double?], _ w: Int) -> [Double?] {
        let n: Int = values.count
        if n == 0 || w <= 0 { return [] }
        if n == w { return values }
        var out: [Double?] = []
        out.reserveCapacity(w)
        for i in 0..<w {
            let t: Double = w > 1 ? Double(i * (n - 1)) / Double(w - 1) : 0.0
            let k: Int = min(max(VFDMath.truncate(t), 0), n - 1)
            let f: Double = t - Double(k)
            let a: Double? = values[k]
            if f == 0 || k + 1 >= n {
                out.append(a)
                continue
            }
            let b: Double? = values[k + 1]
            if let av = a, let bv = b {
                out.append(av + (bv - av) * f)
            } else {
                out.append(nil)
            }
        }
        return out
    }

    // MARK: interaction

    /// Record a hit rectangle (drawing coordinates, clipped like drawing). Later ones are on top.
    func tap(_ c: Int, _ r: Int, _ w: Int, _ h: Int, name: String, action: (() -> Void)? = nil,
             long: (() -> Void)? = nil, swipeLeft: (() -> Void)? = nil, swipeRight: (() -> Void)? = nil,
             drag: ((Double, Bool) -> Void)? = nil) {
        let rr: Int = r + oy
        let ca: Int = max(c, clipC0)
        let cb: Int = min(c + w, clipC1)
        let ra: Int = max(rr, clipR0)
        let rb: Int = min(rr + h, clipR1)
        if ca < cb && ra < rb {
            let hit = VFDHit(c: ca, r: ra, w: cb - ca, h: rb - ra, name: name, action: action, long: long,
                             swipeLeft: swipeLeft, swipeRight: swipeRight, drag: drag)
            taps.append(hit)
        }
    }

    /// Topmost hit containing screen cell (c, r).
    func hit(_ c: Int, _ r: Int) -> VFDHit? {
        var i: Int = taps.count - 1
        while i >= 0 {
            if taps[i].contains(c, r) { return taps[i] }
            i -= 1
        }
        return nil
    }

    /// Record a sub-area that scrolls on its own (drawing coordinates, clipped like tap()).
    func scrollRegion(id: String, _ c: Int, _ r: Int, _ w: Int, _ h: Int, contentRows: Int) {
        let rr: Int = r + oy
        let ca: Int = max(c, clipC0)
        let cb: Int = min(c + w, clipC1)
        let ra: Int = max(rr, clipR0)
        let rb: Int = min(rr + h, clipR1)
        if ca < cb && ra < rb {
            scrollRegions.append(VFDScrollRegion(id: id, c: ca, r: ra, w: cb - ca, h: rb - ra,
                                                 contentRows: contentRows))
        }
    }

    /// Topmost scroll region containing screen cell (c, r).
    func scrollRegionAt(_ c: Int, _ r: Int) -> VFDScrollRegion? {
        var i: Int = scrollRegions.count - 1
        while i >= 0 {
            if scrollRegions[i].contains(c, r) { return scrollRegions[i] }
            i -= 1
        }
        return nil
    }

    // MARK: debugging

    /// Screen region as text, one line per row: "." unlit, else the cell value.
    func ascii(_ c: Int = 0, _ r: Int = 0, _ w: Int? = nil, _ h: Int? = nil) -> String {
        let ww: Int = w ?? (cols - c)
        let hh: Int = h ?? (rows - r)
        var lines: [String] = []
        for y in stride(from: r, to: r + hh, by: 1) {
            var s: String = ""
            for x in stride(from: c, to: c + ww, by: 1) {
                let v: UInt8 = self.get(x, y)
                s += v == 0 ? "." : String(v)
            }
            lines.append(s)
        }
        return lines.joined(separator: "\n")
    }
}
