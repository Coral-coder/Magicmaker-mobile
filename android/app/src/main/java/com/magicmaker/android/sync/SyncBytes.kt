package com.magicmaker.android.sync

// SYNC v1 codec (docs/SYNC_PROTOCOL.md): byte strings, hex, strict UTF-8. Pure Kotlin, no Android
// APIs, so the JVM unit tests (src/test/.../sync) run it against tools/sync/vectors.json.

/**
 * Immutable byte string with value equality, unsigned lexicographic ordering (a shorter prefix
 * sorts first, like Python `bytes`) and uppercase-hex text. Used for every id, nonce, key, packet
 * and encoded message so data classes compare by content.
 */
class Bytes private constructor(private val b: ByteArray) : Comparable<Bytes> {
    val size: Int get() = b.size

    fun isEmpty(): Boolean = b.isEmpty()

    /** Unsigned byte at [i] (0..255). */
    operator fun get(i: Int): Int = b[i].toInt() and 0xFF

    fun toByteArray(): ByteArray = b.copyOf()

    fun slice(from: Int, to: Int = size): Bytes = Bytes(b.copyOfRange(from, to))

    operator fun plus(other: Bytes): Bytes = Bytes(b + other.b)

    fun isAllZero(): Boolean {
        for (x in b) if (x.toInt() != 0) return false
        return true
    }

    /** Uppercase hex, most significant nibble first, bytes in order ("8301" = 83 01). */
    fun hex(): String {
        val out = CharArray(b.size * 2)
        for (i in b.indices) {
            val v = b[i].toInt() and 0xFF
            out[2 * i] = HEX[v ushr 4]
            out[2 * i + 1] = HEX[v and 0x0F]
        }
        return String(out)
    }

    /** The 8 bytes read as a big-endian u64 (two's-complement bits in a Long). */
    fun u64BigEndian(): Long {
        require(b.size == 8) { "u64 needs 8 bytes, got ${b.size}" }
        var v = 0L
        for (x in b) v = (v shl 8) or (x.toLong() and 0xFF)
        return v
    }

    /** Little-endian unsigned integer of [width] bytes starting at [from]. */
    fun leUnsigned(from: Int, width: Int): Long {
        var v = 0L
        for (i in width - 1 downTo 0) v = (v shl 8) or (b[from + i].toLong() and 0xFF)
        return v
    }

    /** Little-endian two's-complement integer of [width] bytes starting at [from]. */
    fun leSigned(from: Int, width: Int): Long {
        val u = leUnsigned(from, width)
        if (width >= 8) return u
        val bits = width * 8
        return (u shl (64 - bits)) shr (64 - bits)
    }

    /** No-copy read access for this package (callers must not mutate the array). */
    internal fun raw(): ByteArray = b

    override fun equals(other: Any?): Boolean = other is Bytes && b.contentEquals(other.b)

    override fun hashCode(): Int = b.contentHashCode()

    override fun toString(): String = hex()

    override fun compareTo(other: Bytes): Int {
        val n = minOf(b.size, other.b.size)
        for (i in 0 until n) {
            val x = b[i].toInt() and 0xFF
            val y = other.b[i].toInt() and 0xFF
            if (x != y) return if (x < y) -1 else 1
        }
        return b.size.compareTo(other.b.size).coerceIn(-1, 1)
    }

    companion object {
        private val HEX = "0123456789ABCDEF".toCharArray()

        val EMPTY: Bytes = Bytes(ByteArray(0))

        /** Eight zero bytes: "absent" origin, "ungrouped" groupId. */
        val ZERO8: Bytes = zero(8)

        fun of(a: ByteArray): Bytes = Bytes(a.copyOf())

        fun of(vararg v: Int): Bytes = Bytes(ByteArray(v.size) { v[it].toByte() })

        fun zero(n: Int): Bytes = Bytes(ByteArray(n))

        /** Hex (either case, no separators) -> bytes. */
        fun fromHex(s: String): Bytes {
            require(s.length % 2 == 0) { "odd hex length" }
            val out = ByteArray(s.length / 2)
            for (i in out.indices) {
                val hi = Character.digit(s[2 * i], 16)
                val lo = Character.digit(s[2 * i + 1], 16)
                require(hi >= 0 && lo >= 0) { "bad hex digit in \"$s\"" }
                out[i] = ((hi shl 4) or lo).toByte()
            }
            return Bytes(out)
        }

        /** A big-endian u64 as 8 bytes. */
        fun u64BigEndian(v: Long): Bytes = Bytes(ByteArray(8) { (v ushr (56 - 8 * it)).toByte() })

        /** Little-endian [width]-byte encoding of [v]; [v] must fit (signed or unsigned per [signed]). */
        fun le(v: Long, width: Int, signed: Boolean): Bytes {
            require(fitsWidth(v, width, signed)) { "$v does not fit ${if (signed) "i" else "u"}${width * 8}" }
            return Bytes(ByteArray(width) { (v ushr (8 * it)).toByte() })
        }

        internal fun fitsWidth(v: Long, width: Int, signed: Boolean): Boolean {
            if (width >= 8) return signed || v >= 0
            val bits = width * 8
            return if (signed) v >= -(1L shl (bits - 1)) && v < (1L shl (bits - 1))
            else v >= 0 && v < (1L shl bits)
        }

        internal fun wrap(a: ByteArray): Bytes = Bytes(a)
    }
}

/** Growable output buffer for TLV encoders. */
internal class ByteWriter(capacity: Int = 64) {
    private var buf = ByteArray(capacity)
    var size: Int = 0
        private set

    private fun ensure(extra: Int) {
        if (size + extra > buf.size) buf = buf.copyOf(maxOf(buf.size * 2, size + extra))
    }

    fun u8(v: Int): ByteWriter {
        ensure(1)
        buf[size++] = v.toByte()
        return this
    }

    fun bytes(v: Bytes): ByteWriter {
        ensure(v.size)
        System.arraycopy(v.raw(), 0, buf, size, v.size)
        size += v.size
        return this
    }

    /** [tag u8][len u8][value]. */
    fun tlv(tag: Int, value: Bytes): ByteWriter {
        require(tag in 0..255) { "tag $tag" }
        require(value.size <= 255) { "TLV value of ${value.size} bytes" }
        return u8(tag).u8(value.size).bytes(value)
    }

    fun toBytes(): Bytes = Bytes.wrap(buf.copyOf(size))
}

/** One parsed TLV: tag, value and the raw `tag len value` bytes. */
internal class Tlv(val tag: Int, val value: Bytes, val raw: Bytes)

internal object TlvParser {
    /** All TLVs of [data] from [start]; BAD_MSG `truncated` when one overruns the end. */
    fun parse(data: Bytes, start: Int = 0): List<Tlv> {
        val out = ArrayList<Tlv>()
        var i = start
        while (i < data.size) {
            if (i + 2 > data.size) throw SyncException(ErrCode.BAD_MSG, "truncated")
            val tag = data[i]
            val ln = data[i + 1]
            if (i + 2 + ln > data.size) throw SyncException(ErrCode.BAD_MSG, "truncated")
            out.add(Tlv(tag, data.slice(i + 2, i + 2 + ln), data.slice(i, i + 2 + ln)))
            i += 2 + ln
        }
        return out
    }
}

/** Strict UTF-8 (RFC 3629): no overlong forms, no surrogates, nothing above U+10FFFF, no truncation. */
object Utf8 {
    fun isValid(b: Bytes): Boolean {
        var i = 0
        val n = b.size
        while (i < n) {
            val c = b[i]
            if (c < 0x80) {
                i++
                continue
            }
            val extra: Int
            var cp: Int
            val min: Int
            when (c) {
                in 0xC2..0xDF -> { extra = 1; cp = c and 0x1F; min = 0x80 }
                in 0xE0..0xEF -> { extra = 2; cp = c and 0x0F; min = 0x800 }
                in 0xF0..0xF4 -> { extra = 3; cp = c and 0x07; min = 0x10000 }
                else -> return false
            }
            if (i + extra >= n) return false
            for (k in 1..extra) {
                val cc = b[i + k]
                if (cc and 0xC0 != 0x80) return false
                cp = (cp shl 6) or (cc and 0x3F)
            }
            if (cp < min || cp in 0xD800..0xDFFF || cp > 0x10FFFF) return false
            i += extra + 1
        }
        return true
    }

    /** Valid UTF-8 bytes -> String; BAD_MSG [reason] otherwise. */
    fun decode(b: Bytes, reason: String = "utf8"): String {
        if (!isValid(b)) throw SyncException(ErrCode.BAD_MSG, reason)
        return String(b.raw(), Charsets.UTF_8)
    }

    /** String -> UTF-8. A lone UTF-16 surrogate is not a Unicode scalar: IllegalArgumentException. */
    fun encode(s: String): Bytes {
        val w = ByteWriter(s.length + 8)
        var i = 0
        while (i < s.length) {
            val cp = s.codePointAt(i)
            require(cp !in 0xD800..0xDFFF) { "lone surrogate in string" }
            i += Character.charCount(cp)
            when {
                cp < 0x80 -> w.u8(cp)
                cp < 0x800 -> w.u8(0xC0 or (cp shr 6)).u8(0x80 or (cp and 0x3F))
                cp < 0x10000 -> w.u8(0xE0 or (cp shr 12)).u8(0x80 or ((cp shr 6) and 0x3F)).u8(0x80 or (cp and 0x3F))
                else -> w.u8(0xF0 or (cp shr 18)).u8(0x80 or ((cp shr 12) and 0x3F))
                    .u8(0x80 or ((cp shr 6) and 0x3F)).u8(0x80 or (cp and 0x3F))
            }
        }
        return w.toBytes()
    }

    /** UTF-8 width of one code point. */
    fun width(cp: Int): Int = when {
        cp < 0x80 -> 1
        cp < 0x800 -> 2
        cp < 0x10000 -> 3
        else -> 4
    }
}
