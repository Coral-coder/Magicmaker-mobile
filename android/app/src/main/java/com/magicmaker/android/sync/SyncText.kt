package com.magicmaker.android.sync

/**
 * Text normalisation for local edits (§5.3). Works on Unicode scalars (code points), never on
 * UTF-16 units or graphemes, and trims exactly the Unicode White_Space set (not Kotlin's trim()).
 * Receivers never re-normalise; they only validate (§4).
 */
object SyncText {
    /** Unicode White_Space (the exact trim set of §5.3). U+200B is deliberately not in it. */
    fun isWhiteSpace(cp: Int): Boolean = when (cp) {
        in 0x09..0x0D, 0x20, 0x85, 0xA0, 0x1680, in 0x2000..0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 -> true
        else -> false
    }

    /** Code points of [s]; a lone surrogate (not a Unicode scalar) becomes U+FFFD. */
    private fun codePoints(s: String): IntArray {
        val out = IntArray(s.codePointCount(0, s.length))
        var i = 0
        var k = 0
        while (i < s.length) {
            val cp = s.codePointAt(i)
            i += Character.charCount(cp)
            out[k++] = if (cp in 0xD800..0xDFFF) 0xFFFD else cp
        }
        return out
    }

    private fun trim(cps: IntArray, from: Int, to: Int): IntRange {
        var a = from
        var b = to
        while (a < b && isWhiteSpace(cps[a])) a++
        while (b > a && isWhiteSpace(cps[b - 1])) b--
        return a until b
    }

    /**
     * trim -> keep the longest prefix of whole code points whose UTF-8 length is <= [maxBytes] ->
     * trim again. Returns null when the result is empty (the field is then absent).
     */
    fun normalize(s: String, maxBytes: Int): String? {
        val cps = codePoints(s)
        val r = trim(cps, 0, cps.size)
        var end = r.first
        var n = 0
        while (end <= r.last) {
            val w = Utf8.width(cps[end])
            if (n + w > maxBytes) break
            n += w
            end++
        }
        val r2 = trim(cps, r.first, end)
        if (r2.isEmpty()) return null
        val sb = StringBuilder()
        for (i in r2) sb.appendCodePoint(cps[i])
        return sb.toString()
    }

    /** typeInfo -> kind: code points outside 0x20..0x7E become '?', then normalize(16). */
    fun normalizeKind(s: String): String? {
        val sb = StringBuilder()
        for (cp in codePoints(s)) sb.append(if (cp in 0x20..0x7E) cp.toChar() else '?')
        return normalize(sb.toString(), SyncConst.KIND_MAX)
    }

    fun normalizeLabel(s: String): String? = normalize(s, SyncConst.LABEL_MAX)

    fun normalizeNote(s: String): String? = normalize(s, SyncConst.NOTE_MAX)
}
