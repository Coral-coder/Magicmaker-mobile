package com.magicmaker.android.sync

// Message TLV codec (§10, §11). One spec table drives decoding (tag order, repeats, unknown tags,
// widths, ranges, mandatory sets) and canonical encoding for every message type; typed classes
// (Hello, Pull, ...) convert to and from the spec's field maps. A decoded optional field keeps its
// presence (null = absent on the wire), so decode -> encode normalises explicit defaults away.

/** One HB `link` entry: `peerId 8 ‖ peerKind u8 (1..3) ‖ flags u8` (§11.8). */
data class HbLink(val peerId: Bytes, val peerKind: Int, val flags: Int)

/** One HB `evtWm` entry: `origin 8 ‖ epoch u32 ‖ seq u32` (§11.8). */
data class EvtWm(val origin: Bytes, val epoch: Long, val seq: Long)

internal enum class FType(val width: Int, val signed: Boolean) {
    U8(1, false), U16(2, false), U32(4, false), I8(1, true), I16(2, true), I32(4, true), I64(8, true),
    BYTES(0, false), STR(0, false), PACKET(0, false), KEY(0, false), LINK(0, false), EVTWM(0, false);

    val isInt: Boolean get() = width > 0
}

/** Field spec: tag, name, type, mandatory, repeat max (0 = not repeatable), default, range, size. */
internal class FSpec(
    val tag: Int,
    val name: String,
    val type: FType,
    val mand: Boolean = false,
    val rep: Int = 0,
    val default: Long? = null,
    val lo: Long? = null,
    val hi: Long? = null,
    val size: Int = 0,
)

/**
 * Spec-driven codec over generic field maps. Values: Long (every integer), Bytes (fixed byte
 * fields, packet), String, RecordKey (ERR key), HbLink, EvtWm, and List<...> for repeatable tags.
 * REC carries its verbatim body bytes under [BODY].
 */
internal object MsgCodec {
    const val BODY: String = "body"
    private const val REC_BODY_TAG_LO = 0x10
    private const val REC_BODY_TAG_HI = 0x1F

    private fun u8(tag: Int, name: String, mand: Boolean = false, default: Long? = null, lo: Long? = null, hi: Long? = null) =
        FSpec(tag, name, FType.U8, mand, default = default, lo = lo, hi = hi)

    private fun b(tag: Int, name: String, size: Int, mand: Boolean = false, rep: Int = 0) =
        FSpec(tag, name, FType.BYTES, mand, rep = rep, size = size)

    private fun str(tag: Int, name: String, max: Int) = FSpec(tag, name, FType.STR, size = max)

    val SPECS: Map<Int, List<FSpec>> = mapOf(
        MsgType.HELLO to listOf(
            u8(0x01, "proto", true),
            b(0x02, "deviceId", 8, true),
            u8(0x03, "kind", true, lo = 1, hi = 3),
            b(0x04, "dbId", 8, true),
            FSpec(0x05, "clockMs", FType.I64, true, lo = 0),
            FSpec(0x06, "feedHigh", FType.U32, true),
            u8(0x07, "subs", true),
            FSpec(0x08, "caps", FType.U16, default = 0),
            FSpec(0x09, "maxMsg", FType.U16, true, lo = SyncConst.MAXMSG_MIN.toLong()),
            FSpec(0x0A, "bootId", FType.U16, true),
            str(0x0B, "version", 16),
            str(0x0C, "name", 20),
            b(0x0D, "groupId", 8, true),
            b(0x0E, "nonce", 8, true),
            b(0x0F, "proof", 16),
        ),
        MsgType.PULL to listOf(
            u8(0x01, "reqId", true, lo = 1, hi = 255),
            FSpec(0x02, "since", FType.U32, true),
            u8(0x03, "limit", default = SyncConst.PULL_LIMIT_DEFAULT.toLong(), lo = 1, hi = 32),
            FSpec(0x04, "maxBytes", FType.U16, default = SyncConst.PULL_MAXBYTES_DEFAULT.toLong(),
                lo = SyncConst.PULL_MAXBYTES_MIN.toLong(), hi = 1536),
            b(0x05, "dbId", 8, true),
            u8(0x06, "exclude", default = 0, lo = 0, hi = 1),
        ),
        MsgType.REC to listOf(
            FSpec(0x01, "seq", FType.U32, true),
            u8(0x02, "reqId", true),
            b(0x03, "seenBy", 8, rep = SyncConst.SEENBY_MAX),
        ),
        MsgType.PAGE_END to listOf(
            u8(0x01, "reqId", true, lo = 1, hi = 255),
            FSpec(0x02, "scannedTo", FType.U32, true),
            u8(0x03, "more", true, lo = 0, hi = 1),
            FSpec(0x04, "feedHigh", FType.U32, true),
            u8(0x05, "count", true),
        ),
        MsgType.EVT to listOf(
            b(0x01, "origin", 8, true),
            FSpec(0x02, "epoch", FType.U32, true, lo = 1),
            FSpec(0x03, "seq", FType.U32, true, lo = 1),
            FSpec(0x04, "ts", FType.I64, true, lo = 0),
            FSpec(0x05, "packet", FType.PACKET, true),
            FSpec(0x06, "rssi", FType.I8),
            FSpec(0x07, "count", FType.U16, default = 1, lo = 1),
            FSpec(0x08, "lat", FType.I32, lo = -900_000_000, hi = 900_000_000),
            FSpec(0x09, "lon", FType.I32, lo = -1_800_000_000, hi = 1_800_000_000),
            FSpec(0x0A, "acc", FType.U16),
            b(0x0B, "addr", 6),
            u8(0x0C, "flags", default = 0),
            b(0x0D, "seenBy", 8, rep = SyncConst.SEENBY_MAX),
        ),
        MsgType.EVT_SINCE to listOf(
            b(0x01, "origin", 8, true),
            FSpec(0x02, "epoch", FType.U32, true),
            FSpec(0x03, "afterSeq", FType.U32, true),
            b(0x04, "requester", 8, true),
        ),
        MsgType.EVT_GAP to listOf(
            b(0x01, "origin", 8, true),
            FSpec(0x02, "epoch", FType.U32, true),
            FSpec(0x03, "firstAvail", FType.U32, true),
            FSpec(0x04, "lastAvail", FType.U32, true),
            FSpec(0x05, "curEpoch", FType.U32, true),
            b(0x06, "requester", 8, true),
        ),
        MsgType.HB to listOf(
            b(0x01, "deviceId", 8, true),
            u8(0x02, "kind", true, lo = 1, hi = 3),
            FSpec(0x03, "bootId", FType.U16, true),
            FSpec(0x04, "hbSeq", FType.U32, true),
            FSpec(0x05, "ts", FType.I64, true, lo = 0),
            FSpec(0x06, "uptimeS", FType.U32, true),
            FSpec(0x07, "battPct", FType.I8, default = -1, lo = -1, hi = 100),
            FSpec(0x08, "battMv", FType.I16, default = -1, lo = -1),
            FSpec(0x09, "charging", FType.I8, default = -1, lo = -1, hi = 1),
            FSpec(0x0A, "runtimeMin", FType.I16, default = -1, lo = -1, hi = 5999),
            str(0x0B, "version", 16),
            str(0x0C, "name", 20),
            FSpec(0x0D, "link", FType.LINK, rep = SyncConst.HB_LINKS_MAX),
            FSpec(0x0E, "state", FType.U16, default = 0),
            u8(0x0F, "hops", true, lo = 0, hi = 1),
            FSpec(0x10, "feedHigh", FType.U32, true),
            b(0x11, "dbId", 8, true),
            FSpec(0x12, "records", FType.U32, true),
            FSpec(0x13, "hubAirAgoS", FType.U16),
            FSpec(0x14, "evtWm", FType.EVTWM, rep = SyncConst.HB_EVTWM_MAX),
        ),
        MsgType.SUB to listOf(
            u8(0x01, "subs", true),
        ),
        MsgType.ERR to listOf(
            u8(0x01, "code", true, lo = 1),
            u8(0x02, "refType"),
            FSpec(0x03, "key", FType.KEY),
            str(0x04, "detail", 40),
            b(0x05, "dbId", 8),
            FSpec(0x06, "retryMs", FType.U16),
        ),
        MsgType.AUTH to listOf(
            b(0x01, "proof", 16, true),
        ),
        MsgType.JOIN to listOf(
            b(0x01, "groupId", 8, true),
            b(0x02, "groupKey", 16, true),
            u8(0x03, "flags", default = 0),
        ),
    )

    private val BY_TAG: Map<Int, Map<Int, FSpec>> = SPECS.mapValues { (_, l) -> l.associateBy { it.tag } }

    private fun bad(reason: String) = SyncException(ErrCode.BAD_MSG, reason)

    private fun decodeValue(spec: FSpec, v: Bytes): Any {
        val t = spec.type
        if (t.isInt) {
            if (v.size != t.width) throw bad("length")
            val n = if (t.signed) v.leSigned(0, t.width) else v.leUnsigned(0, t.width)
            if ((spec.lo != null && n < spec.lo) || (spec.hi != null && n > spec.hi)) throw bad("range")
            return n
        }
        return when (t) {
            FType.BYTES -> {
                if (v.size != spec.size) throw bad("length")
                v
            }
            FType.STR -> {
                if (v.size !in 1..spec.size) throw bad("length")
                Utf8.decode(v)
            }
            FType.PACKET -> {
                if (v.size !in SyncConst.PACKET_MIN..SyncConst.PACKET_MAX) throw bad("length")
                RecordKey.checkPacket(v)
                v
            }
            FType.KEY -> RecordKey.decode(v)
            FType.LINK -> {
                if (v.size != 10) throw bad("length")
                if (v[8] !in 1..3) throw bad("range")
                HbLink(v.slice(0, 8), v[8], v[9])
            }
            FType.EVTWM -> {
                if (v.size != 16) throw bad("length")
                EvtWm(v.slice(0, 8), v.leUnsigned(8, 4), v.leUnsigned(12, 4))
            }
            else -> throw AssertionError(t)
        }
    }

    private fun encodeValue(spec: FSpec, x: Any): Bytes {
        val t = spec.type
        if (t.isInt) return Bytes.le((x as Number).toLong(), t.width, t.signed)
        return when (t) {
            FType.BYTES -> {
                val v = x as Bytes
                require(v.size == spec.size) { "${spec.name} must be ${spec.size} bytes, got ${v.size}" }
                v
            }
            FType.STR -> {
                val v = Utf8.encode(x as String)
                require(v.size in 1..spec.size) { "${spec.name} must be 1..${spec.size} UTF-8 bytes" }
                v
            }
            FType.PACKET -> x as Bytes
            FType.KEY -> (x as RecordKey).encode()
            FType.LINK -> {
                val l = x as HbLink
                l.peerId + Bytes.of(l.peerKind, l.flags)
            }
            FType.EVTWM -> {
                val w = x as EvtWm
                w.origin + Bytes.le(w.epoch, 4, false) + Bytes.le(w.seq, 4, false)
            }
            else -> throw AssertionError(t)
        }
    }

    /**
     * bytes -> (type, fields), or (type, null) for an unknown message type (ignored, §10 rule 2).
     * Throws SyncException(BAD_MSG). A REC's invalid body does not fail the envelope.
     */
    fun decode(data: Bytes): Pair<Int, Map<String, Any>?> {
        if (data.size < 1) throw bad("empty")
        val mtype = data[0]
        val specs = BY_TAG[mtype] ?: return mtype to null
        val fields = LinkedHashMap<String, Any>()
        val body = ByteWriter(64)
        var prev = -1
        for (t in TlvParser.parse(data, 1)) {
            val tag = t.tag
            if (mtype == MsgType.REC && tag in REC_BODY_TAG_LO..REC_BODY_TAG_HI) {
                body.bytes(t.raw)
                continue
            }
            val spec = specs[tag]
            if (tag < prev) throw bad("order")
            if (tag == prev && spec != null && spec.rep == 0) throw bad("duplicate")
            prev = tag
            if (spec == null) continue // unknown tag: skipped (still ordered)
            val value = decodeValue(spec, t.value)
            if (spec.rep > 0) {
                @Suppress("UNCHECKED_CAST")
                val list = fields.getOrPut(spec.name) { ArrayList<Any>() } as MutableList<Any>
                list.add(value)
                if (list.size > spec.rep) throw bad("count")
            } else {
                fields[spec.name] = value
            }
        }
        for (spec in SPECS.getValue(mtype)) {
            if (spec.mand && spec.name !in fields) throw bad("missing")
        }
        if (mtype == MsgType.REC) {
            if (fields["reqId"] != 0L && "seenBy" in fields) throw bad("seenby_on_page")
            fields[BODY] = body.toBytes()
        }
        if (mtype == MsgType.EVT) {
            val n = listOf("lat", "lon", "acc").count { it in fields }
            if (n != 0 && n != 3) throw bad("fix")
        }
        if (mtype == MsgType.JOIN && (fields["groupId"] as Bytes).isAllZero()) throw bad("range")
        return mtype to fields
    }

    /**
     * Canonical encoding: tags ascending, repeatable tags consecutive in list order, an optional
     * field omitted when absent or equal to its default; REC body bytes verbatim after the envelope.
     */
    fun encode(mtype: Int, fields: Map<String, Any?>): Bytes {
        val specs = SPECS[mtype] ?: throw IllegalArgumentException("unknown message type $mtype")
        val w = ByteWriter(64)
        w.u8(mtype)
        for (spec in specs) {
            val x = fields[spec.name]
            if (x == null) {
                require(!spec.mand) { "missing ${MsgType.name(mtype)}.${spec.name}" }
                continue
            }
            if (spec.rep > 0) {
                val list = x as List<*>
                require(list.size <= spec.rep) { "${spec.name}: at most ${spec.rep}" }
                for (item in list) w.tlv(spec.tag, encodeValue(spec, item!!))
                continue
            }
            if (!spec.mand && spec.default != null && (x as Number).toLong() == spec.default) continue
            w.tlv(spec.tag, encodeValue(spec, x))
        }
        if (mtype == MsgType.REC) w.bytes(fields[BODY] as Bytes)
        return w.toBytes()
    }
}

/**
 * A SYNC v1 message (§11). Optional fields are null when absent on the wire; `...OrDefault`
 * accessors give the protocol default. [SyncMsgs.decode] / [SyncMsgs.encode] are the codec.
 */
sealed class SyncMsg {
    abstract val type: Int
    val typeName: String get() = MsgType.name(type)

    /** The generic field map of this message (what the spec-driven codec encodes). */
    internal abstract fun toFields(): Map<String, Any?>

    /** Canonical encoding (§10). */
    fun encode(): Bytes = MsgCodec.encode(type, toFields())

    /** A message type v1 does not know: ignored silently (counted), never answered. */
    data class Unknown(override val type: Int) : SyncMsg() {
        override fun toFields(): Map<String, Any?> = throw UnsupportedOperationException("unknown type $type")
    }
}

data class Hello(
    val proto: Int,
    val deviceId: Bytes,
    val kind: Int,
    val dbId: Bytes,
    val clockMs: Long,
    val feedHigh: Long,
    val subs: Int,
    val caps: Int? = null,
    val maxMsg: Int,
    val bootId: Int,
    val version: String? = null,
    val name: String? = null,
    val groupId: Bytes,
    val nonce: Bytes,
    val proof: Bytes? = null,
) : SyncMsg() {
    override val type: Int get() = MsgType.HELLO
    val capsOrDefault: Int get() = caps ?: 0

    override fun toFields(): Map<String, Any?> = mapOf(
        "proto" to proto.toLong(), "deviceId" to deviceId, "kind" to kind.toLong(), "dbId" to dbId,
        "clockMs" to clockMs, "feedHigh" to feedHigh, "subs" to subs.toLong(), "caps" to caps?.toLong(),
        "maxMsg" to maxMsg.toLong(), "bootId" to bootId.toLong(), "version" to version, "name" to name,
        "groupId" to groupId, "nonce" to nonce, "proof" to proof,
    )
}

data class Pull(
    val reqId: Int,
    val since: Long,
    val limit: Int? = null,
    val maxBytes: Int? = null,
    val dbId: Bytes,
    val exclude: Int? = null,
) : SyncMsg() {
    override val type: Int get() = MsgType.PULL
    val limitOrDefault: Int get() = limit ?: SyncConst.PULL_LIMIT_DEFAULT
    val maxBytesOrDefault: Int get() = maxBytes ?: SyncConst.PULL_MAXBYTES_DEFAULT
    val excludeOrDefault: Int get() = exclude ?: 0

    override fun toFields(): Map<String, Any?> = mapOf(
        "reqId" to reqId.toLong(), "since" to since, "limit" to limit?.toLong(), "maxBytes" to maxBytes?.toLong(),
        "dbId" to dbId, "exclude" to exclude?.toLong(),
    )
}

/**
 * REC (§11.4). [body] is the verbatim body (tags 0x10..0x1F in order of appearance). The envelope
 * decodes even when the body is invalid: then [bodyFields] is null and [bodyError] says why.
 */
data class Rec(val seq: Long, val reqId: Int, val seenBy: List<Bytes> = emptyList(), val body: Bytes) : SyncMsg() {
    override val type: Int get() = MsgType.REC

    private val decoded: Pair<RecordBody?, SyncException?> by lazy(LazyThreadSafetyMode.PUBLICATION) {
        try {
            RecordBody.decode(body) to null
        } catch (e: SyncException) {
            null to e
        }
    }

    val bodyFields: RecordBody? get() = decoded.first
    val bodyError: SyncException? get() = decoded.second

    /** The key for `ERR{code, refType 0x03, key}` when the body is rejected. */
    val errKey: RecordKey? get() = bodyFields?.key ?: RecordBody.errKeyOf(body)

    val isLive: Boolean get() = reqId == 0

    override fun toFields(): Map<String, Any?> = mapOf(
        "seq" to seq, "reqId" to reqId.toLong(), "seenBy" to seenBy.ifEmpty { null }, MsgCodec.BODY to body,
    )
}

data class PageEnd(val reqId: Int, val scannedTo: Long, val more: Int, val feedHigh: Long, val count: Int) : SyncMsg() {
    override val type: Int get() = MsgType.PAGE_END

    override fun toFields(): Map<String, Any?> = mapOf(
        "reqId" to reqId.toLong(), "scannedTo" to scannedTo, "more" to more.toLong(), "feedHigh" to feedHigh,
        "count" to count.toLong(),
    )
}

data class Evt(
    val origin: Bytes,
    val epoch: Long,
    val seq: Long,
    val ts: Long,
    val packet: Bytes,
    val rssi: Int? = null,
    val count: Int? = null,
    val lat: Int? = null,
    val lon: Int? = null,
    val acc: Int? = null,
    val addr: Bytes? = null,
    val flags: Int? = null,
    val seenBy: List<Bytes> = emptyList(),
) : SyncMsg() {
    override val type: Int get() = MsgType.EVT
    val countOrDefault: Int get() = count ?: 1
    val flagsOrDefault: Int get() = flags ?: 0
    val isReplay: Boolean get() = flagsOrDefault and SyncConst.EVT_FLAG_REPLAY != 0

    override fun toFields(): Map<String, Any?> = mapOf(
        "origin" to origin, "epoch" to epoch, "seq" to seq, "ts" to ts, "packet" to packet,
        "rssi" to rssi?.toLong(), "count" to count?.toLong(), "lat" to lat?.toLong(), "lon" to lon?.toLong(),
        "acc" to acc?.toLong(), "addr" to addr, "flags" to flags?.toLong(), "seenBy" to seenBy.ifEmpty { null },
    )
}

data class EvtSince(val origin: Bytes, val epoch: Long, val afterSeq: Long, val requester: Bytes) : SyncMsg() {
    override val type: Int get() = MsgType.EVT_SINCE

    override fun toFields(): Map<String, Any?> =
        mapOf("origin" to origin, "epoch" to epoch, "afterSeq" to afterSeq, "requester" to requester)
}

data class EvtGap(
    val origin: Bytes,
    val epoch: Long,
    val firstAvail: Long,
    val lastAvail: Long,
    val curEpoch: Long,
    val requester: Bytes,
) : SyncMsg() {
    override val type: Int get() = MsgType.EVT_GAP

    override fun toFields(): Map<String, Any?> = mapOf(
        "origin" to origin, "epoch" to epoch, "firstAvail" to firstAvail, "lastAvail" to lastAvail,
        "curEpoch" to curEpoch, "requester" to requester,
    )
}

data class Hb(
    val deviceId: Bytes,
    val kind: Int,
    val bootId: Int,
    val hbSeq: Long,
    val ts: Long,
    val uptimeS: Long,
    val battPct: Int? = null,
    val battMv: Int? = null,
    val charging: Int? = null,
    val runtimeMin: Int? = null,
    val version: String? = null,
    val name: String? = null,
    val link: List<HbLink> = emptyList(),
    val state: Int? = null,
    val hops: Int,
    val feedHigh: Long,
    val dbId: Bytes,
    val records: Long,
    val hubAirAgoS: Int? = null,
    val evtWm: List<EvtWm> = emptyList(),
) : SyncMsg() {
    override val type: Int get() = MsgType.HB
    val battPctOrDefault: Int get() = battPct ?: -1
    val battMvOrDefault: Int get() = battMv ?: -1
    val chargingOrDefault: Int get() = charging ?: -1
    val runtimeMinOrDefault: Int get() = runtimeMin ?: -1
    val stateOrDefault: Int get() = state ?: 0

    override fun toFields(): Map<String, Any?> = mapOf(
        "deviceId" to deviceId, "kind" to kind.toLong(), "bootId" to bootId.toLong(), "hbSeq" to hbSeq, "ts" to ts,
        "uptimeS" to uptimeS, "battPct" to battPct?.toLong(), "battMv" to battMv?.toLong(),
        "charging" to charging?.toLong(), "runtimeMin" to runtimeMin?.toLong(), "version" to version, "name" to name,
        "link" to link.ifEmpty { null }, "state" to state?.toLong(), "hops" to hops.toLong(), "feedHigh" to feedHigh,
        "dbId" to dbId, "records" to records, "hubAirAgoS" to hubAirAgoS?.toLong(), "evtWm" to evtWm.ifEmpty { null },
    )
}

data class Sub(val subs: Int) : SyncMsg() {
    override val type: Int get() = MsgType.SUB

    override fun toFields(): Map<String, Any?> = mapOf("subs" to subs.toLong())
}

data class Err(
    val code: Int,
    val refType: Int? = null,
    val key: RecordKey? = null,
    val detail: String? = null,
    val dbId: Bytes? = null,
    val retryMs: Int? = null,
) : SyncMsg() {
    override val type: Int get() = MsgType.ERR
    val codeName: String get() = ErrCode.name(code)

    override fun toFields(): Map<String, Any?> = mapOf(
        "code" to code.toLong(), "refType" to refType?.toLong(), "key" to key, "detail" to detail, "dbId" to dbId,
        "retryMs" to retryMs?.toLong(),
    )
}

data class Auth(val proof: Bytes) : SyncMsg() {
    override val type: Int get() = MsgType.AUTH

    override fun toFields(): Map<String, Any?> = mapOf("proof" to proof)
}

data class Join(val groupId: Bytes, val groupKey: Bytes, val flags: Int? = null) : SyncMsg() {
    override val type: Int get() = MsgType.JOIN
    val isRekey: Boolean get() = (flags ?: 0) and SyncConst.JOIN_FLAG_REKEY != 0

    override fun toFields(): Map<String, Any?> = mapOf("groupId" to groupId, "groupKey" to groupKey, "flags" to flags?.toLong())
}

/** Codec entry points. */
object SyncMsgs {
    /**
     * bytes -> message. Unknown type -> [SyncMsg.Unknown] (ignore it). Throws SyncException
     * (BAD_MSG) on any decode failure; answer that with `ERR{BAD_MSG, refType = data[0]}` unless
     * it was an ERR.
     */
    fun decode(data: Bytes): SyncMsg {
        val (mtype, f) = MsgCodec.decode(data)
        return if (f == null) SyncMsg.Unknown(mtype) else fromFields(mtype, f)
    }

    fun encode(msg: SyncMsg): Bytes = msg.encode()

    private fun Map<String, Any>.long(k: String): Long = get(k) as Long
    private fun Map<String, Any>.int(k: String): Int = (get(k) as Long).toInt()
    private fun Map<String, Any>.intOrNull(k: String): Int? = (get(k) as Long?)?.toInt()
    private fun Map<String, Any>.bytes(k: String): Bytes = get(k) as Bytes
    private fun Map<String, Any>.bytesOrNull(k: String): Bytes? = get(k) as Bytes?
    private fun Map<String, Any>.str(k: String): String? = get(k) as String?

    @Suppress("UNCHECKED_CAST")
    private fun <T> Map<String, Any>.list(k: String): List<T> = (get(k) as List<T>?) ?: emptyList()

    /** Generic fields (as [MsgCodec.decode] produces them) -> typed message. */
    internal fun fromFields(mtype: Int, f: Map<String, Any>): SyncMsg = when (mtype) {
        MsgType.HELLO -> Hello(
            f.int("proto"), f.bytes("deviceId"), f.int("kind"), f.bytes("dbId"), f.long("clockMs"), f.long("feedHigh"),
            f.int("subs"), f.intOrNull("caps"), f.int("maxMsg"), f.int("bootId"), f.str("version"), f.str("name"),
            f.bytes("groupId"), f.bytes("nonce"), f.bytesOrNull("proof"),
        )
        MsgType.PULL -> Pull(
            f.int("reqId"), f.long("since"), f.intOrNull("limit"), f.intOrNull("maxBytes"), f.bytes("dbId"),
            f.intOrNull("exclude"),
        )
        MsgType.REC -> Rec(f.long("seq"), f.int("reqId"), f.list("seenBy"), f.bytes(MsgCodec.BODY))
        MsgType.PAGE_END -> PageEnd(f.int("reqId"), f.long("scannedTo"), f.int("more"), f.long("feedHigh"), f.int("count"))
        MsgType.EVT -> Evt(
            f.bytes("origin"), f.long("epoch"), f.long("seq"), f.long("ts"), f.bytes("packet"), f.intOrNull("rssi"),
            f.intOrNull("count"), f.intOrNull("lat"), f.intOrNull("lon"), f.intOrNull("acc"), f.bytesOrNull("addr"),
            f.intOrNull("flags"), f.list("seenBy"),
        )
        MsgType.EVT_SINCE -> EvtSince(f.bytes("origin"), f.long("epoch"), f.long("afterSeq"), f.bytes("requester"))
        MsgType.EVT_GAP -> EvtGap(
            f.bytes("origin"), f.long("epoch"), f.long("firstAvail"), f.long("lastAvail"), f.long("curEpoch"),
            f.bytes("requester"),
        )
        MsgType.HB -> Hb(
            f.bytes("deviceId"), f.int("kind"), f.int("bootId"), f.long("hbSeq"), f.long("ts"), f.long("uptimeS"),
            f.intOrNull("battPct"), f.intOrNull("battMv"), f.intOrNull("charging"), f.intOrNull("runtimeMin"),
            f.str("version"), f.str("name"), f.list("link"), f.intOrNull("state"), f.int("hops"), f.long("feedHigh"),
            f.bytes("dbId"), f.long("records"), f.intOrNull("hubAirAgoS"), f.list("evtWm"),
        )
        MsgType.SUB -> Sub(f.int("subs"))
        MsgType.ERR -> Err(
            f.int("code"), f.intOrNull("refType"), f["key"] as RecordKey?, f.str("detail"), f.bytesOrNull("dbId"),
            f.intOrNull("retryMs"),
        )
        MsgType.AUTH -> Auth(f.bytes("proof"))
        MsgType.JOIN -> Join(f.bytes("groupId"), f.bytes("groupKey"), f.intOrNull("flags"))
        else -> SyncMsg.Unknown(mtype)
    }

    /**
     * Forwarders change nothing but hops (§16.4): patch the 1-byte value of TLV 0x0F in place, so
     * unknown tags survive. Throws SyncException(BAD_MSG) when the HB TLVs do not parse.
     */
    fun hbSetHops(data: Bytes, hops: Int): Bytes {
        val tlvs = TlvParser.parse(data, 1)
        val out = data.toByteArray()
        var i = 1
        for (t in tlvs) {
            if (t.tag == 0x0F) {
                require(t.value.size == 1) { "HB hops must be 1 byte" }
                out[i + 2] = hops.toByte()
                return Bytes.wrap(out)
            }
            i += t.raw.size
        }
        throw IllegalArgumentException("HB without hops")
    }

    /** True when [data] is a HELLO whose first TLV is `01 01 xx` with xx != 1 (answer ERR PROTO, §17). */
    fun isForeignProtoHello(data: Bytes): Boolean =
        data.size >= 4 && data[0] == MsgType.HELLO && data[1] == 0x01 && data[2] == 1 && data[3] != SyncConst.PROTO
}
