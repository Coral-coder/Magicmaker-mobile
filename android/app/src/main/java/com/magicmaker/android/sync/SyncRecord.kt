package com.magicmaker.android.sync

import com.magicmaker.android.sync.SyncConst.FLAG_DELETED
import com.magicmaker.android.sync.SyncConst.FLAG_PRESET
import com.magicmaker.android.sync.SyncConst.FLAG_USER_EDITED

/** Record key `ns (u8) ‖ packet (3..29 B)` (§3). */
data class RecordKey(val ns: Int, val packet: Bytes) : Comparable<RecordKey> {
    /** The encoded key bytes `ns ‖ packet` (body tag 0x10, ERR key). */
    fun encode(): Bytes = Bytes.of(ns) + packet

    /** Phones' ledger map key: `"<ns>:<HEX>"`, decimal ns, uppercase hex. */
    val keyString: String get() = "$ns:${packet.hex()}"

    /** The hub's index hash: FNV-1a 64 over the encoded key bytes. */
    fun hubHash(): Long = SyncCrypto.fnv1a64(encode())

    /** Orders by encoded key bytes (the tombstone-eviction tie-break, §6.3). */
    override fun compareTo(other: RecordKey): Int = encode().compareTo(other.encode())

    override fun toString(): String = keyString

    companion object {
        /** Every packet must be 3..29 bytes and start `83 01` (§3). */
        fun checkPacket(packet: Bytes) {
            if (packet.size !in SyncConst.PACKET_MIN..SyncConst.PACKET_MAX) {
                throw SyncException(ErrCode.BAD_MSG, "packet_length")
            }
            if (packet[0] != 0x83 || packet[1] != 0x01) throw SyncException(ErrCode.BAD_MSG, "packet_prefix")
        }

        /** Encoded key bytes -> key; BAD_MSG on a bad length, ns or packet. */
        fun decode(v: Bytes): RecordKey {
            if (v.size !in 1 + SyncConst.PACKET_MIN..1 + SyncConst.PACKET_MAX) {
                throw SyncException(ErrCode.BAD_MSG, "length")
            }
            val ns = v[0]
            if (ns != SyncConst.NS_LIB && ns != SyncConst.NS_NEWWAND) throw SyncException(ErrCode.BAD_MSG, "range")
            val packet = v.slice(1)
            checkPacket(packet)
            return RecordKey(ns, packet)
        }

        /**
         * `"<ns>:<HEX>"` -> key, or null unless [s] is exactly a canonical key string (decimal ns
         * 0 or 1, uppercase hex of a valid packet). Strict, so one key never has two map keys.
         */
        fun parseKeyString(s: String): RecordKey? {
            val i = s.indexOf(':')
            if (i <= 0) return null
            val ns = s.substring(0, i).toIntOrNull() ?: return null
            if (ns !in 0..255) return null // Bytes.of would wrap 256 to ns 0
            val key = try {
                decode(Bytes.of(ns) + Bytes.fromHex(s.substring(i + 1)))
            } catch (e: SyncException) {
                return null
            } catch (e: IllegalArgumentException) {
                return null
            }
            return key.takeIf { it.keyString == s } // rejects "00:", "+0:", lowercase hex
        }
    }
}

/** Record classes (§4.4). */
enum class RecordClass { PRESENCE, USER, RESET, TOMBSTONE, NEWWAND }

/**
 * A record body (§4.1). Absent optional fields are null; [flags] 0 means the flags TLV is absent
 * (a canonical body never carries flags 0). Build with [encode] (which validates) and read with
 * [RecordBody.decode]; a decoded canonical body re-encodes byte for byte.
 */
data class RecordBody(
    val key: RecordKey,
    val updatedAt: Long,
    val origin: Bytes? = null,
    val flags: Int = 0,
    val label: String? = null,
    val category: Int? = null,
    val note: String? = null,
    val kind: String? = null,
    val place: Int? = null,
) {
    val isDeleted: Boolean get() = flags and FLAG_DELETED != 0

    /** The class, after the full class/time validation (throws SyncException like [decode]). */
    fun recordClass(): RecordClass = BodyRules.validate(this)

    /** Canonical bytes. Validates every rule of §4 (SyncException) so it never emits an invalid body. */
    fun encode(): Bytes {
        val w = ByteWriter(64)
        w.tlv(T_KEY, key.encode())
        w.tlv(T_UPDATED, Bytes.le(updatedAt, 8, signed = true))
        origin?.let { w.tlv(T_ORIGIN, it) }
        if (flags != 0) w.tlv(T_FLAGS, Bytes.of(flags))
        label?.let { w.tlv(T_LABEL, Utf8.encode(it)) }
        category?.let { w.tlv(T_CATEGORY, Bytes.of(it)) }
        note?.let { w.tlv(T_NOTE, Utf8.encode(it)) }
        kind?.let { w.tlv(T_KIND, Utf8.encode(it)) }
        place?.let { w.tlv(T_PLACE, Bytes.of(it)) }
        val data = w.toBytes()
        val back = decode(data)
        check(back == this) { "body does not round-trip: $this -> $back" }
        return data
    }

    companion object {
        const val T_KEY: Int = 0x10
        const val T_UPDATED: Int = 0x11
        const val T_ORIGIN: Int = 0x12
        const val T_FLAGS: Int = 0x13
        const val T_LABEL: Int = 0x14
        const val T_CATEGORY: Int = 0x15
        const val T_NOTE: Int = 0x16
        const val T_KIND: Int = 0x17
        const val T_PLACE: Int = 0x18

        /**
         * Canonical body bytes -> body, enforcing §4.2 rules 1-8 in the reference's order:
         * size, TLV framing, per TLV (unknown tag, duplicate, order, value), key/updatedAt present,
         * then the class/time rules. Throws SyncException(BAD_MSG | CLOCK).
         */
        fun decode(data: Bytes): RecordBody {
            if (data.size > SyncConst.BODY_MAX) throw SyncException(ErrCode.BAD_MSG, "oversize")
            val tlvs = TlvParser.parse(data)
            var key: RecordKey? = null
            var updatedAt: Long? = null
            var origin: Bytes? = null
            var flags = 0
            var label: String? = null
            var category: Int? = null
            var note: String? = null
            var kind: String? = null
            var place: Int? = null
            var prev = -1
            for (t in tlvs) {
                val tag = t.tag
                val v = t.value
                if (tag !in T_KEY..T_PLACE) throw SyncException(ErrCode.BAD_MSG, "unknown_tag")
                if (tag == prev) throw SyncException(ErrCode.BAD_MSG, "duplicate")
                if (tag < prev) throw SyncException(ErrCode.BAD_MSG, "order")
                prev = tag
                when (tag) {
                    T_KEY -> key = RecordKey.decode(v)
                    T_UPDATED -> {
                        if (v.size != 8) throw SyncException(ErrCode.BAD_MSG, "length")
                        updatedAt = v.leSigned(0, 8)
                    }
                    T_ORIGIN -> {
                        if (v.size != 8) throw SyncException(ErrCode.BAD_MSG, "length")
                        if (v.isAllZero()) throw SyncException(ErrCode.BAD_MSG, "zero_origin")
                        origin = v
                    }
                    T_FLAGS -> {
                        if (v.size != 1) throw SyncException(ErrCode.BAD_MSG, "length")
                        if (v[0] == 0) throw SyncException(ErrCode.BAD_MSG, "zero_flags")
                        if (v[0] and SyncConst.FLAG_MASK.inv() != 0) throw SyncException(ErrCode.BAD_MSG, "range")
                        flags = v[0]
                    }
                    T_LABEL -> {
                        if (v.size !in 1..SyncConst.LABEL_MAX) throw SyncException(ErrCode.BAD_MSG, "length")
                        label = Utf8.decode(v)
                    }
                    T_CATEGORY -> {
                        if (v.size != 1) throw SyncException(ErrCode.BAD_MSG, "length")
                        if (v[0] > SyncConst.CAT_COLOR) throw SyncException(ErrCode.BAD_MSG, "range")
                        category = v[0]
                    }
                    T_NOTE -> {
                        if (v.size !in 1..SyncConst.NOTE_MAX) throw SyncException(ErrCode.BAD_MSG, "length")
                        note = Utf8.decode(v)
                    }
                    T_KIND -> {
                        if (v.size !in 1..SyncConst.KIND_MAX) throw SyncException(ErrCode.BAD_MSG, "length")
                        for (i in 0 until v.size) {
                            if (v[i] < 0x20 || v[i] > 0x7E) throw SyncException(ErrCode.BAD_MSG, "ascii")
                        }
                        kind = String(v.raw(), Charsets.US_ASCII)
                    }
                    T_PLACE -> {
                        if (v.size != 1) throw SyncException(ErrCode.BAD_MSG, "length")
                        if (v[0] !in SyncConst.PLACE_PRESETS..SyncConst.PLACE_RAW) {
                            throw SyncException(ErrCode.BAD_MSG, "range")
                        }
                        place = v[0]
                    }
                }
            }
            if (key == null || updatedAt == null) throw SyncException(ErrCode.BAD_MSG, "missing")
            val body = RecordBody(key, updatedAt, origin, flags, label, category, note, kind, place)
            BodyRules.validate(body)
            return body
        }

        /**
         * The key to report in `ERR{code, refType 0x03, key}` for a rejected body (§11.4): the
         * 0x10 TLV when it parses, else null.
         */
        fun errKeyOf(body: Bytes): RecordKey? {
            val tlvs = try {
                TlvParser.parse(body)
            } catch (e: SyncException) {
                return null
            }
            var key: RecordKey? = null
            for (t in tlvs) {
                if (t.tag == T_KEY) {
                    key = try {
                        RecordKey.decode(t.value)
                    } catch (e: SyncException) {
                        return key
                    }
                }
            }
            return key
        }
    }
}

/** Class / field / time rules of §4.4. */
internal object BodyRules {
    private fun bad(reason: String) = SyncException(ErrCode.BAD_MSG, reason)

    private fun hasContent(b: RecordBody) =
        b.label != null || b.category != null || b.note != null || b.kind != null || b.place != null

    /** The class implied by ns + flags + origin + content (time not considered). */
    fun shape(b: RecordBody): RecordClass = when {
        b.key.ns == SyncConst.NS_NEWWAND -> RecordClass.NEWWAND
        b.flags and FLAG_DELETED != 0 -> RecordClass.TOMBSTONE
        b.flags and (FLAG_USER_EDITED or FLAG_PRESET) != 0 -> RecordClass.USER
        b.origin == null && !hasContent(b) -> RecordClass.PRESENCE
        else -> RecordClass.RESET
    }

    /** Check order: updatedAt <= 0 -> field presence for the class -> time rule. Returns the class. */
    fun validate(b: RecordBody): RecordClass {
        val u = b.updatedAt
        if (u <= 0) throw bad("time")
        val flags = b.flags
        val shape = shape(b)

        fun need(vararg present: Boolean) {
            for (p in present) if (!p) throw bad("class")
        }

        fun forbid(vararg present: Boolean) {
            for (p in present) if (p) throw bad("class")
        }

        val legacyAllowed: Boolean
        when {
            b.key.ns == SyncConst.NS_NEWWAND -> {
                if (flags and (FLAG_USER_EDITED or FLAG_PRESET) != 0) throw bad("class")
                need(b.origin != null)
                forbid(b.category != null, b.kind != null, b.place != null)
                if (flags and FLAG_DELETED != 0) {
                    forbid(b.label != null, b.note != null)
                    legacyAllowed = false
                } else {
                    need(b.label != null)
                    legacyAllowed = true
                }
            }
            shape == RecordClass.TOMBSTONE -> {
                if (flags != FLAG_DELETED) throw bad("class")
                need(b.origin != null)
                forbid(b.label != null, b.category != null, b.note != null, b.kind != null, b.place != null)
                legacyAllowed = false
            }
            shape == RecordClass.USER -> {
                need(b.origin != null, b.label != null, b.category != null, b.place != null)
                legacyAllowed = true
            }
            shape == RecordClass.PRESENCE -> {
                if (u != SyncConst.U_PRESENCE) throw bad("class")
                return RecordClass.PRESENCE
            }
            else -> { // RESET
                need(b.origin != null)
                forbid(b.label != null, b.category != null, b.kind != null, b.place != null)
                legacyAllowed = false
            }
        }
        if (u == SyncConst.U_PRESENCE) throw bad("class")
        if (u == SyncConst.U_LEGACY_ANDROID || u == SyncConst.U_LEGACY_IOS) {
            if (!legacyAllowed) throw bad("class")
        } else if (u < SyncConst.U_MIN_MS) {
            throw SyncException(ErrCode.CLOCK, "clock_invalid")
        }
        return shape
    }
}

/**
 * A record version (§5.1): `(updatedAt signed, origin as u64 big-endian (0 when absent), bodyCrc
 * u32)`, compared lexicographically. [origin] holds the u64 bits (compared unsigned); [crc] is
 * 0..0xFFFFFFFF.
 */
data class Version(val updatedAt: Long, val origin: Long, val crc: Long) : Comparable<Version> {
    override fun compareTo(other: Version): Int {
        val a = updatedAt.compareTo(other.updatedAt)
        if (a != 0) return Integer.signum(a)
        val b = (origin xor Long.MIN_VALUE).compareTo(other.origin xor Long.MIN_VALUE) // unsigned u64
        if (b != 0) return Integer.signum(b)
        return Integer.signum(crc.compareTo(other.crc))
    }

    companion object {
        fun of(body: RecordBody, bodyBytes: Bytes): Version =
            Version(body.updatedAt, (body.origin ?: Bytes.ZERO8).u64BigEndian(), SyncCrypto.crc32(bodyBytes))
    }
}

object SyncClock {
    /** -1, 0, +1: [a] against [b] (§5.1). */
    fun compareVersions(a: Version, b: Version): Int = a.compareTo(b)

    /** updatedAt for a local edit: max(now, ledger.updatedAt + 1, lastLocalStamp + 1, 1.5e12) (§5.2). */
    fun localStamp(nowMs: Long, ledgerUpdatedAt: Long, lastLocalStamp: Long): Long =
        maxOf(maxOf(nowMs, ledgerUpdatedAt + 1), maxOf(lastLocalStamp + 1, SyncConst.U_MIN_MS))

    /**
     * Receiver future check (§7): CLOCK when updatedAt > now + 24 h. [nowMs] null = the receiver
     * does not know the time (hub before any member clock): no check.
     */
    fun checkFuture(updatedAt: Long, nowMs: Long?) {
        if (nowMs != null && updatedAt > nowMs + SyncConst.FUTURE_BOUND_MS) {
            throw SyncException(ErrCode.CLOCK, "clock_future")
        }
    }
}
