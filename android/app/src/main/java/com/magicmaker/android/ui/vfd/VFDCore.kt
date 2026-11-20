package com.magicmaker.android.ui.vfd

// VFD dot-matrix core: inks, base colours and the palette, the cell frame buffer with its drawing
// primitives, text metrics, hit rectangles and scroll regions.
// Port of tools/vfd/vfd.py (via ios/MagicMaker/VFD/VFDCore.swift, same names), cell for cell:
// tools/vfd/golden.py + src/test/.../ui/vfd/VFDGoldenTest.kt check it.
// Kotlin stdlib only (no android.*): it also runs in plain JVM unit tests.
//
// Integer semantics follow Python: floor division / modulo (VFDMath.floorDiv / floorMod),
// vfd._round = half away from zero (VFDMath.roundHalfAway), round() = half to even
// (VFDMath.roundHalfEven), int() = truncation (VFDMath.truncate). Strings are iterated by Unicode
// code points ("scalars"), as Python iterates str.

// MARK: - Inks

/** Cell values. 0..4 are the palette inks; 5..255 are true colours handed out per frame by
 *  [VFDFrameBuffer.rgb]. */
object VFDInk {
    const val unlit: Int = 0
    const val highlight: Int = 1
    const val text: Int = 2
    const val dim: Int = 3
    const val alarm: Int = 4
    /** Number of palette inks. */
    const val count: Int = 5
    /** First cell value used for a true colour. */
    const val firstTrueColor: Int = 5
    /** True-colour slots per frame (5..255). */
    const val maxTrueColors: Int = 251
}

// MARK: - Integer and rounding helpers (Python semantics)

object VFDMath {
    /** vfd._round: half away from zero, computed as floor(|x| + 0.5) like the Python reference. */
    fun roundHalfAway(x: Double): Int {
        if (!x.isFinite()) return 0
        if (x >= 0) {
            return toInt(Math.floor(x + 0.5))
        }
        return -toInt(Math.floor(-x + 0.5))
    }

    /** Python's round(): half to even. */
    fun roundHalfEven(x: Double): Int {
        if (!x.isFinite()) return 0
        return toInt(Math.rint(x))
    }

    /** Python's int(x): truncation toward zero. */
    fun truncate(x: Double): Int {
        if (!x.isFinite()) return 0
        return toInt(if (x < 0) Math.ceil(x) else Math.floor(x))
    }

    /** Double -> Int without failing on huge values (saturates; NaN = 0). */
    fun toInt(x: Double): Int {
        if (x.isNaN()) return 0
        return x.toInt()
    }

    /** Python a // b (rounds toward negative infinity). 0 when b == 0. */
    fun floorDiv(a: Int, b: Int): Int {
        if (b == 0) return 0
        return Math.floorDiv(a, b)
    }

    /** Python a % b (the sign of b). 0 when b == 0. */
    fun floorMod(a: Int, b: Int): Int {
        if (b == 0) return 0
        return Math.floorMod(a, b)
    }

    /** Python -(-a // b). */
    fun ceilDiv(a: Int, b: Int): Int {
        return -floorDiv(-a, b)
    }

    /** Python float a % b (the sign of b). */
    fun pyMod(a: Double, b: Double): Double {
        var m: Double = a % b
        if (m != 0.0 && ((b < 0) != (m < 0))) {
            m += b
        }
        return m
    }

    fun clamp(v: Int, lo: Int, hi: Int): Int {
        if (v < lo) return lo
        if (v > hi) return hi
        return v
    }

    fun clamp(v: Double, lo: Double, hi: Double): Double {
        if (v < lo) return lo
        if (v > hi) return hi
        return v
    }
}

// MARK: - Small value types (Swift tuples)

/** A cell rectangle (c, r, w, h): clip rects, tab cells. */
data class VFDRect(val c: Int, val r: Int, val w: Int, val h: Int)

// MARK: - Colours

/** An sRGB colour, channels 0..255 (clamped on construction). */
class VFDRGB(r: Int, g: Int, b: Int) {
    val r: Int = VFDMath.clamp(r, 0, 255)
    val g: Int = VFDMath.clamp(g, 0, 255)
    val b: Int = VFDMath.clamp(b, 0, 255)

    private constructor(c: VFDRGB) : this(c.r, c.g, c.b)

    /** "#RRGGBB" (or "RRGGBB"); anything else gives black. Use [parse] to tell them apart. */
    constructor(hex: String) : this(parse(hex) ?: black)

    /** Channels 0..1 (e.g. from a colour picker), rounded half away from zero. */
    constructor(unitRed: Double, green: Double, blue: Double) : this(
        VFDMath.roundHalfAway(unitRed * 255.0),
        VFDMath.roundHalfAway(green * 255.0),
        VFDMath.roundHalfAway(blue * 255.0),
    )

    /** 0xRRGGBB. */
    val packed: Int get() = (r shl 16) or (g shl 8) or b

    /** Opaque 0xAARRGGBB (an Android colour int). */
    val argb: Int get() = (0xFF shl 24) or packed

    /** "#RRGGBB", uppercase. */
    val hex: String get() = "#" + hex2(r) + hex2(g) + hex2(b)

    override fun equals(other: Any?): Boolean {
        return other is VFDRGB && other.r == r && other.g == g && other.b == b
    }

    override fun hashCode(): Int = packed

    override fun toString(): String = hex

    companion object {
        private val black: VFDRGB = VFDRGB(0, 0, 0)

        /** "#RRGGBB" / "RRGGBB" (any case, surrounding whitespace and leading "#"s ignored), else null. */
        fun parse(hex: String): VFDRGB? {
            val digits = IntArray(6)
            var n = 0
            var seenDigit = false
            for (u in VFDText.scalars(VFDText.strip(hex))) {
                if (u == '#'.code && !seenDigit) continue
                seenDigit = true
                val d: Int = when (u) {
                    in 0x30..0x39 -> u - 0x30
                    in 0x41..0x46 -> u - 0x41 + 10
                    in 0x61..0x66 -> u - 0x61 + 10
                    else -> return null
                }
                if (n >= 6) return null
                digits[n] = d
                n += 1
            }
            if (n != 6) return null
            return VFDRGB(digits[0] * 16 + digits[1], digits[2] * 16 + digits[3], digits[4] * 16 + digits[5])
        }

        /** From 0xRRGGBB. */
        fun packed(rgb: Int): VFDRGB = VFDRGB((rgb shr 16) and 0xFF, (rgb shr 8) and 0xFF, rgb and 0xFF)

        private fun hex2(v: Int): String {
            val s: String = Integer.toHexString(v).uppercase()
            return if (s.length < 2) "0$s" else s
        }
    }
}

/** A preset base colour (VFDBase.presets entry). */
data class VFDPreset(val name: String, val rgb: VFDRGB)

/** VFDBase.resolved: the preset name (null for a custom colour) and the RGB. */
data class VFDResolvedBase(val name: String?, val rgb: VFDRGB)

/** The base colour the VFD theme is drawn in: a preset name or a custom RGB. Persisted as the
 *  preset name ("AMBER") or "#RRGGBB". Swift `.preset(name)` / `.custom(rgb)` are
 *  [VFDBase.Preset] / [VFDBase.Custom]; Swift `VFDBase(persisted:)` is `VFDBase(persisted = ...)`
 *  (or [VFDBase.fromPersisted]). */
sealed class VFDBase {
    /** The resolved RGB (vfd._resolve_base). */
    abstract val rgb: VFDRGB

    data class Preset(val name: String) : VFDBase() {
        override val rgb: VFDRGB get() = resolved.rgb
    }

    data class Custom(override val rgb: VFDRGB) : VFDBase()

    /** Preset name or "#RRGGBB". */
    val persisted: String
        get() = when (this) {
            is Preset -> VFDText.strip(name).uppercase()
            is Custom -> rgb.hex
        }

    /** (preset name or null, RGB), as vfd._resolve_base. An unknown preset name is read as
     *  "#RRGGBB" if it is one, else AMBER. */
    val resolved: VFDResolvedBase
        get() = when (this) {
            is Custom -> VFDResolvedBase(null, rgb)
            is Preset -> {
                val key: String = VFDText.strip(name).uppercase()
                val p: VFDRGB? = presetRGB(key)
                if (p != null) {
                    VFDResolvedBase(key, p)
                } else {
                    val parsed: VFDRGB? = VFDRGB.parse(key)
                    if (parsed != null) VFDResolvedBase(null, parsed) else VFDResolvedBase("AMBER", amberRGB)
                }
            }
        }

    companion object {
        /** The presets in the order the BASE COLOUR selector shows them (CUSTOM comes after). */
        val presets: List<VFDPreset> = listOf(
            VFDPreset("AMBER", VFDRGB(0xFF, 0xB0, 0x14)),
            VFDPreset("GREEN", VFDRGB(0x3C, 0xFF, 0x6E)),
            VFDPreset("CYAN", VFDRGB(0x30, 0xE8, 0xFF)),
            VFDPreset("BLUE", VFDRGB(0x4C, 0xA0, 0xFF)),
            VFDPreset("RED", VFDRGB(0xFF, 0x40, 0x30)),
            VFDPreset("WHITE", VFDRGB(0xF0, 0xF0, 0xF0)),
        )

        val amberRGB: VFDRGB = VFDRGB(0xFF, 0xB0, 0x14)
        val amber: VFDBase = Preset("AMBER")

        /** RGB of a preset name (uppercase), or null. */
        fun presetRGB(name: String): VFDRGB? {
            for (p in presets) {
                if (p.name == name) return p.rgb
            }
            return null
        }

        /** From the persisted form: a preset name (any case) or "#RRGGBB"; anything else is AMBER. */
        fun fromPersisted(persisted: String): VFDBase {
            val key: String = VFDText.strip(persisted).uppercase()
            if (presetRGB(key) != null) return Preset(key)
            val rgb: VFDRGB? = VFDRGB.parse(key)
            if (rgb != null) return Custom(rgb)
            return Preset("AMBER")
        }

        /** Swift `VFDBase(persisted:)`. */
        operator fun invoke(persisted: String): VFDBase = fromPersisted(persisted)
    }
}

object VFDPalette {
    val background: VFDRGB = VFDRGB(0x00, 0x00, 0x00)
    val unlitRGB: VFDRGB = VFDRGB(0x09, 0x09, 0x09)
    val alarmRGB: VFDRGB = VFDRGB(0xFF, 0x50, 0x28)
    /** Degrees: a base this close to the alarm hue draws alarms as inverted blocks. */
    const val alarmHueWindow: Double = 25.0

    /** The AMBER preset: exactly the spec colours (unlit, highlight, text, dim, alarm). */
    val amber: List<VFDRGB> = listOf(
        VFDRGB(0x09, 0x09, 0x09),
        VFDRGB(0xFF, 0xB0, 0x14),
        VFDRGB(0xFF, 0xE8, 0xC4),
        VFDRGB(0x96, 0x64, 0x28),
        VFDRGB(0xFF, 0x50, 0x28),
    )

    /** Rec. 709 luminance, 0..255. */
    fun luma(c: VFDRGB): Double {
        val r: Double = 0.2126 * c.r.toDouble()
        val g: Double = 0.7152 * c.g.toDouble()
        val b: Double = 0.0722 * c.b.toDouble()
        return r + g + b
    }

    /** HSV hue in degrees [0, 360), or null for a grey. */
    fun hue(c: VFDRGB): Double? {
        val r: Double = c.r.toDouble() / 255.0
        val g: Double = c.g.toDouble() / 255.0
        val b: Double = c.b.toDouble() / 255.0
        val mx: Double = maxOf(r, maxOf(g, b))
        val mn: Double = minOf(r, minOf(g, b))
        val d: Double = mx - mn
        if (d <= 0) return null
        var h: Double = if (mx == r) {
            VFDMath.pyMod((g - b) / d, 6.0)
        } else if (mx == g) {
            (b - r) / d + 2.0
        } else {
            (r - g) / d + 4.0
        }
        h = VFDMath.pyMod(h * 60.0, 360.0)
        return h
    }

    /** The 5 ink colours for a base (vfd.palette_for): AMBER is the spec palette; any other base
     *  gives highlight = base, dim = 0.59 * (0.85 * base + 0.15 * luma), text = 0.75 * 255 +
     *  0.25 * base, alarm #FF5028, unlit #090909. (Swift `colors(for:)`.) */
    fun colors(base: VFDBase): List<VFDRGB> {
        val res: VFDResolvedBase = base.resolved
        if (res.name == "AMBER" || res.rgb == VFDBase.amberRGB) {
            return amber
        }
        val rgb: VFDRGB = res.rgb
        val y: Double = luma(rgb)
        val dim = VFDRGB(dimChannel(rgb.r, y), dimChannel(rgb.g, y), dimChannel(rgb.b, y))
        val text = VFDRGB(textChannel(rgb.r), textChannel(rgb.g), textChannel(rgb.b))
        return listOf(unlitRGB, rgb, text, dim, alarmRGB)
    }

    /** True when the base is red-ish (hue within 25 degrees of the alarm's): alarms are then drawn
     *  as inverted highlight blocks (blinking at 1 Hz in the app). */
    fun alarmInverted(base: VFDBase): Boolean {
        val h: Double = hue(base.resolved.rgb) ?: return false
        val ah: Double = hue(alarmRGB) ?: return false
        val d: Double = VFDMath.pyMod(Math.abs(h - ah), 360.0)
        return minOf(d, 360.0 - d) <= alarmHueWindow
    }

    private fun dimChannel(v: Int, y: Double): Int {
        val x: Double = 0.59 * (0.85 * v.toDouble() + 0.15 * y)
        return VFDMath.clamp(VFDMath.roundHalfAway(x), 0, 255)
    }

    private fun textChannel(v: Int): Int {
        val x: Double = 0.75 * 255.0 + 0.25 * v.toDouble()
        return VFDMath.clamp(VFDMath.roundHalfAway(x), 0, 255)
    }
}

// MARK: - Devices

/** A target screen (vfd.Device): cols = pxW / pitch, rows = pxH / pitch, safe rows =
 *  ceil(pt * scale / pitch). */
data class VFDDevice(
    val key: String,
    val name: String,
    val pxW: Int,
    val pxH: Int,
    val scale: Int,
    val pitch: Int,
    val safeTopPt: Int,
    val safeBottomPt: Int,
) {
    val cols: Int get() = VFDMath.floorDiv(pxW, pitch)
    val rows: Int get() = VFDMath.floorDiv(pxH, pitch)
    val safeTop: Int get() = VFDMath.ceilDiv(safeTopPt * scale, pitch)
    val safeBottom: Int get() = VFDMath.ceilDiv(safeBottomPt * scale, pitch)

    /** A blank frame buffer of this size, set up for the base colour. */
    fun framebuffer(base: VFDBase): VFDFrameBuffer {
        return VFDFrameBuffer(cols, rows, base)
    }

    companion object {
        val pro: VFDDevice = VFDDevice(key = "pro", name = "iPhone 17 Pro", pxW = 1206, pxH = 2622, scale = 3,
                                       pitch = 5, safeTopPt = 62, safeBottomPt = 34)
        val x2: VFDDevice = VFDDevice(key = "x2", name = "iPhone 11", pxW = 828, pxH = 1792, scale = 2,
                                      pitch = 4, safeTopPt = 48, safeBottomPt = 34)

        fun named(key: String): VFDDevice? {
            if (key == pro.key) return pro
            if (key == x2.key) return x2
            return null
        }
    }
}

// MARK: - Text

enum class VFDSize {
    small, mid, big;

    val metrics: VFDGlyphs.Metrics
        get() = when (this) {
            small -> VFDGlyphs.smallMetrics
            mid -> VFDGlyphs.midMetrics
            big -> VFDGlyphs.bigMetrics
        }

    /** Glyph box width in cells. */
    val w: Int get() = metrics.width
    /** Glyph box height in cells (descender included). */
    val h: Int get() = metrics.height
    val ascent: Int get() = metrics.ascent
    val advance: Int get() = metrics.advance
    val line: Int get() = metrics.line

    internal val rowTable: IntArray
        get() = when (this) {
            small -> VFDGlyphs.smallRows
            mid -> VFDGlyphs.midRows
            big -> VFDGlyphs.bigRows
        }

    internal val fallback: IntArray
        get() = when (this) {
            small -> VFDGlyphs.smallFallback
            mid -> VFDGlyphs.midFallback
            big -> VFDGlyphs.bigFallback
        }

    companion object {
        /** "small" / "mid" / "big", else null (Swift `VFDSize(name:)`). */
        fun named(name: String): VFDSize? {
            return when (name) {
                "small" -> small
                "mid" -> mid
                "big" -> big
                else -> null
            }
        }
    }
}

/** Text metrics and wrapping (vfd.text_width, max_chars, fit_text, wrap_text). Lengths count
 *  Unicode code points, as Python counts them. */
object VFDText {
    const val ellipsis: String = "…"
    const val ellipsisScalar: Int = 0x2026
    /** U+00A0: drawn as a space, never a line break. */
    const val nbsp: Int = 0xA0
    /** A lone separator word wrap() never puts at the start or end of a line. */
    const val wrapDot: Int = 0xB7
    /** Dashes wrap() keeps at the end of the line before a break (em dash, en dash). */
    val wrapDashes: IntArray = intArrayOf(0x2014, 0x2013)

    private const val space: Int = 0x20
    private const val newline: Int = 0x0A

    // --- code point helpers ---

    /** The code points of s (Swift `Array(s.unicodeScalars)`). */
    fun scalars(s: String): IntArray {
        val out = IntArray(s.codePointCount(0, s.length))
        var i = 0
        var k = 0
        while (i < s.length) {
            val u: Int = s.codePointAt(i)
            out[k] = u
            k += 1
            i += Character.charCount(u)
        }
        return out
    }

    fun string(a: IntArray): String {
        return String(a, 0, a.size)
    }

    /** Number of code points (Python len()). */
    fun length(s: String): Int {
        return s.codePointCount(0, s.length)
    }

    /** Python str.isspace() for one character. */
    fun isSpace(u: Int): Boolean {
        if (u in 0x09..0x0D) return true
        if (u in 0x1C..0x20) return true
        if (u == 0x85 || u == 0xA0 || u == 0x1680) return true
        if (u in 0x2000..0x200A) return true
        if (u == 0x2028 || u == 0x2029 || u == 0x202F || u == 0x205F || u == 0x3000) return true
        return false
    }

    /** Python rstrip() on code points. */
    fun rstrip(a: IntArray): IntArray {
        var end: Int = a.size
        while (end > 0 && isSpace(a[end - 1])) {
            end -= 1
        }
        return a.copyOfRange(0, end)
    }

    /** Python strip(). */
    fun strip(s: String): String {
        val a: IntArray = scalars(s)
        var start = 0
        var end: Int = a.size
        while (start < end && isSpace(a[start])) {
            start += 1
        }
        while (end > start && isSpace(a[end - 1])) {
            end -= 1
        }
        if (start == 0 && end == a.size) return s
        return String(a, start, end - start)
    }

    /** Python str.split(sep) on code points (sep non-empty): empty pieces kept. */
    fun split(a: IntArray, sep: IntArray): List<IntArray> {
        if (sep.isEmpty()) return listOf(a)
        val out = ArrayList<IntArray>()
        val n: Int = a.size
        val m: Int = sep.size
        var start = 0
        var i = 0
        while (i < n) {
            if (i + m <= n && matches(a, i, sep)) {
                out.add(a.copyOfRange(start, i))
                i += m
                start = i
            } else {
                i += 1
            }
        }
        out.add(a.copyOfRange(start, n))
        return out
    }

    private fun matches(a: IntArray, at: Int, sep: IntArray): Boolean {
        var k = 0
        while (k < sep.size) {
            if (a[at + k] != sep[k]) return false
            k += 1
        }
        return true
    }

    private fun endsWithSpaceDot(a: IntBuf): Boolean {
        val n: Int = a.size
        return n >= 2 && a[n - 2] == space && a[n - 1] == wrapDot
    }

    // --- metrics ---

    /** Rows of one glyph (size.h rows, bit 0 = leftmost); the hollow box for an unknown character. */
    fun glyphRows(u: Int, size: VFDSize): IntArray {
        val h: Int = size.h
        val table: IntArray = size.rowTable
        val start: Int = glyphStart(u, size)
        if (start >= 0) {
            return table.copyOfRange(start, start + h)
        }
        return size.fallback.copyOf()
    }

    /** Index of the first row of u's glyph in size.rowTable, or -1 for the fallback box. */
    internal fun glyphStart(u: Int, size: VFDSize): Int {
        val v: Int = if (u == nbsp) 0x20 else u
        val h: Int = size.h
        val slot: Int = VFDGlyphs.slotIndex(v)
        if (slot >= 0) {
            val start: Int = slot * h
            if (start + h <= size.rowTable.size) {
                return start
            }
        }
        return -1
    }

    /** Ink width of `count` characters: count * advance - (advance - w); 0 for none. */
    fun width(count: Int, size: VFDSize = VFDSize.small): Int {
        if (count <= 0) return 0
        return count * size.advance - (size.advance - size.w)
    }

    /** Ink width of s in cells (vfd.text_width). */
    fun width(s: String, size: VFDSize = VFDSize.small): Int {
        return width(count = length(s), size = size)
    }

    /** Largest number of characters whose ink fits in maxCols cells (vfd.max_chars). */
    fun maxChars(maxCols: Int, size: VFDSize = VFDSize.small): Int {
        if (maxCols < size.w) return 0
        return VFDMath.floorDiv(maxCols + size.advance - size.w, size.advance)
    }

    /** s unchanged if it fits, else cut and ended with "…" (trailing spaces before it dropped)
     *  (vfd.fit_text). */
    fun fit(s: String, maxCols: Int, size: VFDSize = VFDSize.small): String {
        val n: Int = maxChars(maxCols, size)
        if (length(s) <= n) return s
        if (n <= 0) return ""
        val a: IntArray = scalars(s)
        val head: IntArray = rstrip(a.copyOfRange(0, n - 1))
        return string(head) + ellipsis
    }

    /** Word wrap into lines that fit maxCols cells (vfd.wrap_text): breaks on plain spaces (runs
     *  collapse; U+00A0 never breaks), hard-breaks long words, honours "\n" (blank lines kept); a
     *  lone "·" on a break is dropped, a lone dash stays at the end of the line with its word. */
    fun wrap(s: String, maxCols: Int, size: VFDSize = VFDSize.small): List<String> {
        val n: Int = maxChars(maxCols, size)
        val all: IntArray = scalars(s)
        if (n <= 0 || all.isEmpty()) return emptyList()
        val out = ArrayList<String>()
        val spaceSep: IntArray = intArrayOf(space)
        val newlineSep: IntArray = intArrayOf(newline)
        for (para in split(all, newlineSep)) {
            val cur = IntBuf()
            for (piece in split(para, spaceSep)) {
                var word: IntArray = piece
                if (word.isEmpty()) continue
                if (!cur.isEmpty() && cur.size + 1 + word.size <= n) {
                    cur.add(space)
                    cur.addAll(word)
                    continue
                }
                if (word.size == 1 && word[0] == wrapDot) {
                    if (!cur.isEmpty()) {
                        out.add(cur.string())
                    }
                    cur.clear()
                    continue
                }
                val isDash: Boolean = word.size == 1 && wrapDashes.contains(word[0])
                val sp: Int = if (isDash && !cur.isEmpty()) cur.lastIndexOf(space) else -1
                if (sp >= 0) {
                    val head: IntBuf = cur.slice(0, sp)
                    val last: IntBuf = cur.slice(sp + 1, cur.size)
                    if (endsWithSpaceDot(head)) {
                        head.removeLast(2)
                    }
                    out.add(head.string())
                    cur.clear()
                    cur.addAll(last)
                    cur.add(space)
                    cur.addAll(word)
                    continue
                }
                if (!cur.isEmpty()) {
                    if (endsWithSpaceDot(cur)) {
                        cur.removeLast(2)
                    }
                    out.add(cur.string())
                }
                while (word.size > n) {
                    out.add(String(word, 0, n))
                    word = word.copyOfRange(n, word.size)
                }
                cur.clear()
                cur.addAll(word)
            }
            if (endsWithSpaceDot(cur)) {
                cur.removeLast(2)
            }
            out.add(cur.string())
        }
        return out
    }
}

/** A small growable list of code points (no boxing). */
internal class IntBuf(capacity: Int = 16) {
    private var a: IntArray = IntArray(maxOf(4, capacity))
    var size: Int = 0
        private set

    operator fun get(i: Int): Int = a[i]

    fun isEmpty(): Boolean = size == 0

    fun clear() {
        size = 0
    }

    fun add(v: Int) {
        if (size == a.size) a = a.copyOf(a.size * 2)
        a[size] = v
        size += 1
    }

    fun addAll(v: IntArray) {
        for (x in v) add(x)
    }

    fun addAll(v: IntBuf) {
        for (i in 0 until v.size) add(v.a[i])
    }

    fun removeLast(k: Int) {
        size = maxOf(0, size - k)
    }

    fun lastIndexOf(v: Int): Int {
        var i: Int = size - 1
        while (i >= 0) {
            if (a[i] == v) return i
            i -= 1
        }
        return -1
    }

    fun slice(from: Int, to: Int): IntBuf {
        val out = IntBuf(to - from)
        for (i in from until to) out.add(a[i])
        return out
    }

    fun string(): String = String(a, 0, size)
}

// MARK: - Hits and scroll regions

/** A tap rectangle in screen cells (clipped like drawing) with what it does. The renderer runs the
 *  topmost hit's [action] on a tap, [long] on a 0.5 s hold, [swipeLeft] / [swipeRight] on a
 *  horizontal swipe and [drag] (fraction 0..1 across the hit's width, ended) while dragging
 *  horizontally (sliders). */
class VFDHit(
    val c: Int,
    val r: Int,
    val w: Int,
    val h: Int,
    val name: String,
    val action: (() -> Unit)? = null,
    val long: (() -> Unit)? = null,
    val swipeLeft: (() -> Unit)? = null,
    val swipeRight: (() -> Unit)? = null,
    val drag: ((Double, Boolean) -> Unit)? = null,
) {
    fun contains(c: Int, r: Int): Boolean {
        return c >= this.c && c < this.c + w && r >= this.r && r < this.r + h
    }

    override fun toString(): String = "VFDHit($c $r $w $h $name)"
}

/** A sub-area that scrolls on its own (a list under pinned rows), in screen cells. Drags that start
 *  inside it scroll it instead of the page; [contentRows] is the height of everything it scrolls. */
data class VFDScrollRegion(
    val id: String,
    val c: Int,
    val r: Int,
    val w: Int,
    val h: Int,
    val contentRows: Int,
) {
    fun contains(c: Int, r: Int): Boolean {
        return c >= this.c && c < this.c + w && r >= this.r && r < this.r + h
    }
}

// MARK: - Frame buffer

/** cols x rows cells, one byte per cell (an ink or a true-colour index; read them as Int 0..255
 *  with [get] / [cell]). All drawing is in whole cells and goes through the current clip
 *  rectangle and vertical origin offset: pushClip(c, r, w, h, dy) intersects the clip with the
 *  rect (in drawing coordinates) and then adds dy to the origin, so drawing row r lands on screen
 *  row r + originY; popClip() restores both. */
class VFDFrameBuffer(cols: Int, rows: Int, alarmInverted: Boolean = false) {
    val cols: Int = maxOf(0, cols)
    val rows: Int = maxOf(0, rows)
    /** Row-major cell values (unsigned bytes: use [get] / [cell] for 0..255). Never reallocated. */
    val cells: ByteArray = ByteArray(this.cols * this.rows)
    /** Tap rectangles in screen cells, last = topmost. */
    val taps: MutableList<VFDHit> = ArrayList()
    val scrollRegions: MutableList<VFDScrollRegion> = ArrayList()
    /** From VFDPalette.alarmInverted(base): alarms are drawn as inverted highlight blocks. */
    var alarmInverted: Boolean = alarmInverted
    /** The base colour the buffer is drawn in. */
    var base: VFDBase = VFDBase.amber
    /** Set by a screen while something animated is visible (the renderer then redraws at 30 fps). */
    var wantsAnimation: Boolean = false

    private val trueColorList: ArrayList<VFDRGB> = ArrayList()
    /** RGB of cell value firstTrueColor + i, this frame only. */
    val trueColors: List<VFDRGB> get() = trueColorList
    // Open-addressing table packed RGB + 1 -> cell value (no boxing; cleared in place).
    private val slotKeys: IntArray = IntArray(SLOT_TABLE)
    private val slotValues: IntArray = IntArray(SLOT_TABLE)

    private var clipC0: Int = 0
    private var clipR0: Int = 0
    private var clipC1: Int = this.cols
    private var clipR1: Int = this.rows
    private var oy: Int = 0
    // Clip stack: 5 ints per entry (c0, r0, c1, r1, oy).
    private var stack: IntArray = IntArray(5 * 8)
    private var depth: Int = 0

    /** A buffer for a base colour: alarmInverted follows the base. */
    constructor(cols: Int, rows: Int, base: VFDBase) : this(cols, rows, VFDPalette.alarmInverted(base)) {
        this.base = base
    }

    companion object {
        /** Rows an led bar occupies (r .. r + 5). */
        const val ledBarH: Int = 6
        private const val SLOT_TABLE: Int = 512

        /** Linear resample of values (null = gap) to exactly w samples (vfd._resample). */
        fun resample(values: List<Double?>, w: Int): List<Double?> {
            val n: Int = values.size
            if (n == 0 || w <= 0) return emptyList()
            if (n == w) return values
            val out = ArrayList<Double?>(w)
            for (i in 0 until w) {
                val t: Double = if (w > 1) (i * (n - 1)).toDouble() / (w - 1).toDouble() else 0.0
                val k: Int = minOf(maxOf(VFDMath.truncate(t), 0), n - 1)
                val f: Double = t - k.toDouble()
                val a: Double? = values[k]
                if (f == 0.0 || k + 1 >= n) {
                    out.add(a)
                    continue
                }
                val b: Double? = values[k + 1]
                if (a != null && b != null) {
                    out.add(a + (b - a) * f)
                } else {
                    out.add(null)
                }
            }
            return out
        }
    }

    // MARK: state

    /** Current vertical origin offset (drawing row r lands on screen row r + originY). */
    val originY: Int get() = oy

    /** Current clip in screen cells. */
    val clipRect: VFDRect get() = VFDRect(clipC0, clipR0, clipC1 - clipC0, clipR1 - clipR0)

    /** Number of pushClip() calls not popped yet. */
    val clipDepth: Int get() = depth

    /** Intersect the clip with (c, r, w, h), given in drawing coordinates, then add dy to the
     *  origin (dy = -scroll for a scrolled content region). */
    fun pushClip(c: Int, r: Int, w: Int, h: Int, dy: Int = 0) {
        if ((depth + 1) * 5 > stack.size) stack = stack.copyOf(stack.size * 2)
        val k: Int = depth * 5
        stack[k] = clipC0
        stack[k + 1] = clipR0
        stack[k + 2] = clipC1
        stack[k + 3] = clipR1
        stack[k + 4] = oy
        depth += 1
        val rr: Int = r + oy
        val nc0: Int = maxOf(clipC0, c)
        val nr0: Int = maxOf(clipR0, rr)
        val nc1: Int = minOf(clipC1, c + w)
        val nr1: Int = minOf(clipR1, rr + h)
        clipC0 = nc0
        clipR0 = nr0
        clipC1 = maxOf(nc0, nc1)
        clipR1 = maxOf(nr0, nr1)
        oy += dy
    }

    /** Restore the clip and origin saved by the matching pushClip() (no-op without one). */
    fun popClip() {
        if (depth == 0) return
        depth -= 1
        val k: Int = depth * 5
        clipC0 = stack[k]
        clipR0 = stack[k + 1]
        clipC1 = stack[k + 2]
        clipR1 = stack[k + 3]
        oy = stack[k + 4]
    }

    /** pushClip, body, popClip. */
    inline fun clipped(c: Int, r: Int, w: Int, h: Int, dy: Int = 0, body: () -> Unit) {
        pushClip(c, r, w, h, dy)
        body()
        popClip()
    }

    /** Every cell to color (ignores the clip); forgets taps, scroll regions, true colours and
     *  wantsAnimation. The clip stack is kept. Refilled in place (no reallocation): the renderer
     *  clears two buffers per frame at 30 fps. */
    fun clear(color: Int = VFDInk.unlit) {
        cells.fill(color.toByte())
        taps.clear()
        scrollRegions.clear()
        trueColorList.clear()
        slotKeys.fill(0)
        wantsAnimation = false
    }

    /** clear() plus an empty clip stack (full-buffer clip, origin 0): ready for reuse as a fresh
     *  buffer (e.g. the scratch buffer of VFDW.contentWindow). */
    fun reset() {
        clear(VFDInk.unlit)
        depth = 0
        clipC0 = 0
        clipR0 = 0
        clipC1 = cols
        clipR1 = rows
        oy = 0
    }

    /** Cell value at screen cell (c, r), ignoring clip and origin; 0 outside the buffer. */
    fun get(c: Int, r: Int): Int {
        if (c >= 0 && c < cols && r >= 0 && r < rows) {
            return cells[r * cols + c].toInt() and 0xFF
        }
        return VFDInk.unlit
    }

    /** Cell value at row-major index i (0..255). */
    fun cell(i: Int): Int = cells[i].toInt() and 0xFF

    // MARK: true colours

    /** Cell value for a true colour in this frame (firstTrueColor + its slot). The same colour gets
     *  the same value; once all 251 slots are used the nearest colour already in the table
     *  (smallest squared RGB distance, the first one on a tie) is returned. */
    fun rgb(color: VFDRGB): Int {
        val key: Int = color.packed + 1
        var i: Int = slotHash(key)
        while (true) {
            val k: Int = slotKeys[i]
            if (k == key) return slotValues[i]
            if (k == 0) break
            i = (i + 1) and (SLOT_TABLE - 1)
        }
        if (trueColorList.size < VFDInk.maxTrueColors) {
            trueColorList.add(color)
            val value: Int = VFDInk.firstTrueColor + trueColorList.size - 1
            slotKeys[i] = key
            slotValues[i] = value
            return value
        }
        var best = 0
        var bestD: Int = Int.MAX_VALUE
        var j = 0
        for (t in trueColorList) {
            val dr: Int = t.r - color.r
            val dg: Int = t.g - color.g
            val db: Int = t.b - color.b
            val d: Int = dr * dr + dg * dg + db * db
            if (d < bestD) {
                best = j
                bestD = d
            }
            j += 1
        }
        return VFDInk.firstTrueColor + best
    }

    private fun slotHash(key: Int): Int = ((key * -0x61c88647) ushr 23) and (SLOT_TABLE - 1)

    /** 256 colours for the cell values: the 5 inks of the base, the true colours, black after. */
    fun colorTable(base: VFDBase = this.base): List<VFDRGB> {
        val table = ArrayList<VFDRGB>(256)
        table.addAll(VFDPalette.colors(base))
        table.addAll(trueColorList)
        while (table.size < 256) {
            table.add(VFDPalette.background)
        }
        return table
    }

    /** colorTable as 256 opaque ARGB ints (Android colour ints), into `out` when given. */
    fun argbTable(base: VFDBase = this.base, out: IntArray = IntArray(256)): IntArray {
        val inks: List<VFDRGB> = VFDPalette.colors(base)
        val bg: Int = VFDPalette.background.argb
        for (i in 0 until 256) {
            out[i] = bg
        }
        for (i in inks.indices) {
            out[i] = inks[i].argb
        }
        for (i in trueColorList.indices) {
            out[VFDInk.firstTrueColor + i] = trueColorList[i].argb
        }
        return out
    }

    /** One opaque ARGB int per cell, row-major (for Bitmap.setPixels), into `out` when given. */
    fun argbPixels(base: VFDBase = this.base, out: IntArray = IntArray(cells.size),
                   table: IntArray = argbTable(base)): IntArray {
        for (i in cells.indices) {
            out[i] = table[cells[i].toInt() and 0xFF]
        }
        return out
    }

    /** The cells as RGBA bytes, one pixel per cell, row-major (alpha 255). */
    fun rgbaBytes(base: VFDBase = this.base): ByteArray {
        val table: List<VFDRGB> = colorTable(base)
        val out = ByteArray(cells.size * 4)
        var j = 0
        for (v in cells) {
            val c: VFDRGB = table[v.toInt() and 0xFF]
            out[j] = c.r.toByte()
            out[j + 1] = c.g.toByte()
            out[j + 2] = c.b.toByte()
            out[j + 3] = 0xFF.toByte()
            j += 4
        }
        return out
    }

    // MARK: primitives

    /** Light one cell. */
    fun set(c: Int, r: Int, color: Int) {
        val rr: Int = r + oy
        if (c >= clipC0 && c < clipC1 && rr >= clipR0 && rr < clipR1) {
            cells[rr * cols + c] = color.toByte()
        }
    }

    /** Solid w x h rectangle with its top-left cell at (c, r). */
    fun fill(c: Int, r: Int, w: Int, h: Int, color: Int) {
        val rr: Int = r + oy
        val ca: Int = maxOf(c, clipC0)
        val cb: Int = minOf(c + w, clipC1)
        val ra: Int = maxOf(rr, clipR0)
        val rb: Int = minOf(rr + h, clipR1)
        if (ca >= cb || ra >= rb) return
        val v: Byte = color.toByte()
        var y: Int = ra
        while (y < rb) {
            val base: Int = y * cols
            cells.fill(v, base + ca, base + cb)
            y += 1
        }
    }

    /** Horizontal line of length cells from (c, r) to the right; step 2 lights every other cell
     *  (dotted), starting with (c, r). */
    fun hline(c: Int, r: Int, length: Int, color: Int, step: Int = 1) {
        if (step < 1) return
        if (step == 1) {
            fill(c, r, length, 1, color)
            return
        }
        var i = 0
        while (i < length) {
            set(c + i, r, color)
            i += step
        }
    }

    /** Vertical line of length cells from (c, r) downwards; step as for hline. */
    fun vline(c: Int, r: Int, length: Int, color: Int, step: Int = 1) {
        if (step < 1) return
        if (step == 1) {
            fill(c, r, 1, length, color)
            return
        }
        var i = 0
        while (i < length) {
            set(c, r + i, color)
            i += step
        }
    }

    /** 1-cell border of a w x h rectangle whose top-left cell is (c, r). */
    fun box(c: Int, r: Int, w: Int, h: Int, color: Int) {
        if (w <= 0 || h <= 0) return
        fill(c, r, w, 1, color)
        fill(c, r + h - 1, w, 1, color)
        fill(c, r, 1, h, color)
        fill(c + w - 1, r, 1, h, color)
    }

    // MARK: text

    private fun blit(c: Int, r: Int, glyph: IntArray, start: Int, w: Int, h: Int, color: Int) {
        val mask: Int = if (w >= 32) -1 else (1 shl w) - 1
        val n: Int = minOf(h, glyph.size - start)
        val v: Byte = color.toByte()
        var dy = 0
        var index: Int = start
        while (dy < n) {
            var bits: Int = glyph[index] and mask
            val y: Int = r + dy + oy
            if (bits != 0 && y >= clipR0 && y < clipR1) {
                val base: Int = y * cols
                var x: Int = c
                while (bits != 0) {
                    if ((bits and 1) != 0 && x >= clipC0 && x < clipC1) {
                        cells[base + x] = v
                    }
                    bits = bits ushr 1
                    x += 1
                }
            }
            dy += 1
            index += 1
        }
    }

    /** Draw s with the first glyph box's top-left at (c, r). Returns the end column
     *  c + length * advance. */
    fun text(c: Int, r: Int, s: String, size: VFDSize = VFDSize.small, color: Int = VFDInk.text): Int {
        val w: Int = size.w
        val h: Int = size.h
        val adv: Int = size.advance
        val table: IntArray = size.rowTable
        val fallback: IntArray = size.fallback
        var x: Int = c
        var i = 0
        val n: Int = s.length
        while (i < n) {
            val u: Int = s.codePointAt(i)
            i += Character.charCount(u)
            val start: Int = VFDText.glyphStart(u, size)
            if (start >= 0) {
                blit(x, r, table, start, w, h, color)
            } else {
                blit(x, r, fallback, 0, w, h, color)
            }
            x += adv
        }
        return x
    }

    /** Draw s so its ink ends exactly on column rightC (inclusive). Returns the start column. */
    fun textRight(rightC: Int, r: Int, s: String, size: VFDSize = VFDSize.small, color: Int = VFDInk.text): Int {
        val start: Int = rightC - VFDText.width(s, size) + 1
        text(start, r, s, size, color)
        return start
    }

    /** Draw s at (c, r), truncated with "…" so its ink fits in maxCols cells. Returns the end
     *  column (as text()). */
    fun textFit(c: Int, r: Int, s: String, maxCols: Int, size: VFDSize = VFDSize.small,
                color: Int = VFDInk.text): Int {
        return text(c, r, VFDText.fit(s, maxCols, size), size, color)
    }

    /** Word-wrapped text maxCols cells wide; line = row pitch (default size.line). Returns the
     *  next row r + lines * line. */
    fun paragraph(c: Int, r: Int, s: String, maxCols: Int, size: VFDSize = VFDSize.small,
                  color: Int = VFDInk.text, line: Int? = null): Int {
        val lines: List<String> = VFDText.wrap(s, maxCols, size)
        val step: Int = line ?: size.line
        var i = 0
        for (ln in lines) {
            text(c, r + i * step, ln, size, color)
            i += 1
        }
        return r + lines.size * step
    }

    /** Inverted text: a solid block in color (ink width + pad each side, glyph height + pad above
     *  and below) with the glyph cells left unlit. Returns c + ink width + pad (c for ""). */
    fun inverted(c: Int, r: Int, s: String, size: VFDSize = VFDSize.small, pad: Int = 1,
                 color: Int = VFDInk.highlight): Int {
        val tw: Int = VFDText.width(s, size)
        if (tw == 0) return c
        fill(c - pad, r - pad, tw + 2 * pad, size.h + 2 * pad, color)
        text(c, r, s, size, VFDInk.unlit)
        return c + tw + pad
    }

    /** Alarm text: ALARM ink, or an inverted HIGHLIGHT block when alarmInverted. Same footprint
     *  and return value as inverted(). */
    fun alarm(c: Int, r: Int, s: String, size: VFDSize = VFDSize.small, pad: Int = 1): Int {
        if (alarmInverted) {
            return inverted(c, r, s, size, pad = pad, color = VFDInk.highlight)
        }
        text(c, r, s, size, VFDInk.alarm)
        val tw: Int = VFDText.width(s, size)
        return if (tw != 0) c + tw + pad else c
    }

    // MARK: indicators

    /** LED bar w cells wide, 6 rows from r: a dotted track on rows r+2, r+3; marker false = a solid
     *  lit zone of round(frac * w) cells on rows r+1 .. r+4; marker true = a 3 x 6 marker centred
     *  on c + round(frac * (w - 1)), kept inside the bar; zone (lo, hi) = a solid target zone on the
     *  track rows. Returns r + 6. */
    fun ledBar(c: Int, r: Int, w: Int, frac: Double, color: Int = VFDInk.highlight, track: Int = VFDInk.dim,
               marker: Boolean = false, zone: Pair<Double, Double>? = null): Int {
        val barH: Int = ledBarH
        if (w <= 0) return r + barH
        val f: Double = VFDMath.clamp(frac, 0.0, 1.0)
        hline(c, r + 2, w, track, step = 2)
        hline(c, r + 3, w, track, step = 2)
        if (zone != null) {
            val lo: Double = VFDMath.clamp(zone.first, 0.0, 1.0)
            val hi: Double = VFDMath.clamp(zone.second, 0.0, 1.0)
            val a: Int = c + VFDMath.roundHalfAway(lo * w.toDouble())
            val b: Int = c + VFDMath.roundHalfAway(hi * w.toDouble())
            fill(minOf(a, b), r + 2, Math.abs(b - a), 2, color)
        }
        if (marker) {
            val mw: Int = minOf(3, w)
            var left: Int = c + VFDMath.roundHalfAway(f * (w - 1).toDouble()) - 1
            left = VFDMath.clamp(left, c, c + w - mw)
            fill(left, r, mw, barH, color)
        } else {
            fill(c, r + 1, VFDMath.roundHalfAway(f * w.toDouble()), 4, color)
        }
        return r + barH
    }

    /** Single-cell line chart in the w x h box at (c, r): values resampled to one per column,
     *  vmin (default min) on the bottom row, vmax (default max) on the top row, a flat series on
     *  the middle row, steeper steps joined vertically, null = a gap; dotted baseline on the bottom
     *  row first (null = none). Returns r + h. */
    fun lineChart(c: Int, r: Int, w: Int, h: Int, values: List<Double?>, color: Int = VFDInk.highlight,
                  vmin: Double? = null, vmax: Double? = null, baseline: Int? = VFDInk.dim): Int {
        if (w <= 0 || h <= 0) return r + maxOf(h, 0)
        if (baseline != null) {
            hline(c, r + h - 1, w, baseline, step = 2)
        }
        val vals: List<Double?> = resample(values, w)
        var any = false
        var lo = 0.0
        var hi = 0.0
        for (v in vals) {
            if (v == null) continue
            if (!any) {
                lo = v
                hi = v
                any = true
            } else {
                if (v < lo) lo = v
                if (v > hi) hi = v
            }
        }
        if (!any) return r + h
        if (vmin != null) lo = vmin
        if (vmax != null) hi = vmax
        val bottom: Int = r + h - 1
        var prev = 0
        var hasPrev = false
        var i = 0
        for (v in vals) {
            if (v == null) {
                hasPrev = false
                i += 1
                continue
            }
            val y: Int = if (hi == lo) {
                r + VFDMath.floorDiv(h - 1, 2)
            } else {
                val t: Double = (v - lo) / (hi - lo) * (h - 1).toDouble()
                VFDMath.clamp(bottom - VFDMath.roundHalfAway(t), r, bottom)
            }
            val x: Int = c + i
            set(x, y, color)
            if (hasPrev) {
                val p: Int = prev
                if (y > p + 1) {
                    val m: Int = VFDMath.floorDiv(p + y, 2)
                    vline(x - 1, p, m - p + 1, color)
                    vline(x, m + 1, y - m, color)
                } else if (y < p - 1) {
                    val m: Int = VFDMath.floorDiv(p + y + 1, 2)
                    vline(x - 1, m, p - m + 1, color)
                    vline(x, y, m - y, color)
                }
            }
            prev = y
            hasPrev = true
            i += 1
        }
        return r + h
    }

    // MARK: interaction

    /** Record a hit rectangle (drawing coordinates, clipped like drawing). Later ones are on top. */
    fun tap(c: Int, r: Int, w: Int, h: Int, name: String, action: (() -> Unit)? = null,
            long: (() -> Unit)? = null, swipeLeft: (() -> Unit)? = null, swipeRight: (() -> Unit)? = null,
            drag: ((Double, Boolean) -> Unit)? = null) {
        val rr: Int = r + oy
        val ca: Int = maxOf(c, clipC0)
        val cb: Int = minOf(c + w, clipC1)
        val ra: Int = maxOf(rr, clipR0)
        val rb: Int = minOf(rr + h, clipR1)
        if (ca < cb && ra < rb) {
            taps.add(VFDHit(ca, ra, cb - ca, rb - ra, name, action = action, long = long,
                            swipeLeft = swipeLeft, swipeRight = swipeRight, drag = drag))
        }
    }

    /** Topmost hit containing screen cell (c, r). */
    fun hit(c: Int, r: Int): VFDHit? {
        var i: Int = taps.size - 1
        while (i >= 0) {
            if (taps[i].contains(c, r)) return taps[i]
            i -= 1
        }
        return null
    }

    /** Record a sub-area that scrolls on its own (drawing coordinates, clipped like tap()). */
    fun scrollRegion(id: String, c: Int, r: Int, w: Int, h: Int, contentRows: Int) {
        val rr: Int = r + oy
        val ca: Int = maxOf(c, clipC0)
        val cb: Int = minOf(c + w, clipC1)
        val ra: Int = maxOf(rr, clipR0)
        val rb: Int = minOf(rr + h, clipR1)
        if (ca < cb && ra < rb) {
            scrollRegions.add(VFDScrollRegion(id, ca, ra, cb - ca, rb - ra, contentRows))
        }
    }

    /** Topmost scroll region containing screen cell (c, r). */
    fun scrollRegionAt(c: Int, r: Int): VFDScrollRegion? {
        var i: Int = scrollRegions.size - 1
        while (i >= 0) {
            if (scrollRegions[i].contains(c, r)) return scrollRegions[i]
            i -= 1
        }
        return null
    }

    // MARK: debugging

    /** Screen region as text, one line per row: "." unlit, else the cell value. */
    fun ascii(c: Int = 0, r: Int = 0, w: Int? = null, h: Int? = null): String {
        val ww: Int = w ?: (cols - c)
        val hh: Int = h ?: (rows - r)
        val lines = ArrayList<String>()
        for (y in r until r + hh) {
            val sb = StringBuilder()
            for (x in c until c + ww) {
                val v: Int = get(x, y)
                if (v == 0) sb.append('.') else sb.append(v)
            }
            lines.add(sb.toString())
        }
        return lines.joinToString("\n")
    }
}
