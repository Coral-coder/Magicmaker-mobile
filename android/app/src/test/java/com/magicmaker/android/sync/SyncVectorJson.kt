package com.magicmaker.android.sync

import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonNull
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.google.gson.JsonPrimitive
import org.junit.Assert.fail
import java.io.File

// Shared test data for the SYNC v1 codec: tools/sync/vectors.json and tools/sync/transcripts/*.json
// (schema: tools/sync/README.md). Gradle runs unit tests with the module dir (android/app) as the
// working directory, so the repo root is found by walking up from user.dir until
// tools/sync/vectors.json exists; -Dsync.vectors.dir=DIR or SYNC_VECTORS_DIR=DIR (the tools/sync
// folder) overrides it. Gson is already on the test classpath (an app dependency); Android's
// org.json is only a stub in JVM unit tests.

internal object SyncTestData {
    val dir: File by lazy {
        val override: String? = System.getProperty("sync.vectors.dir") ?: System.getenv("SYNC_VECTORS_DIR")
        if (!override.isNullOrEmpty()) return@lazy File(override)
        var d: File? = File(System.getProperty("user.dir")).absoluteFile
        while (d != null) {
            val c = File(d, "tools/sync")
            if (File(c, "vectors.json").isFile) return@lazy c
            d = d.parentFile
        }
        throw IllegalStateException("tools/sync/vectors.json not found above ${System.getProperty("user.dir")}")
    }

    val vectors: JsonObject by lazy { parse(File(dir, "vectors.json")) }

    fun transcripts(): List<Pair<String, JsonObject>> =
        (File(dir, "transcripts").listFiles { f -> f.name.endsWith(".json") } ?: emptyArray())
            .sortedBy { it.name }
            .map { it.name to parse(it) }

    private fun parse(f: File): JsonObject = JsonParser.parseString(f.readText(Charsets.UTF_8)).asJsonObject
}

// -- JSON accessors --------------------------------------------------------------------------

internal fun JsonElement?.isAbsent(): Boolean = this == null || this.isJsonNull

internal fun JsonObject.str(k: String): String = get(k).asString
internal fun JsonObject.strOrNull(k: String): String? = get(k).takeUnless { it.isAbsent() }?.asString
internal fun JsonObject.long(k: String): Long = get(k).asLong
internal fun JsonObject.longOrNull(k: String): Long? = get(k).takeUnless { it.isAbsent() }?.asLong
internal fun JsonObject.int(k: String): Int = get(k).asInt
internal fun JsonObject.bool(k: String): Boolean = get(k).asBoolean
internal fun JsonObject.obj(k: String): JsonObject = getAsJsonObject(k)
internal fun JsonObject.objOrNull(k: String): JsonObject? = get(k).takeUnless { it.isAbsent() }?.asJsonObject
internal fun JsonObject.arr(k: String): JsonArray = getAsJsonArray(k)
internal fun JsonObject.hex(k: String): Bytes = Bytes.fromHex(str(k))
internal fun JsonObject.hexOrNull(k: String): Bytes? = strOrNull(k)?.let { Bytes.fromHex(it) }
internal fun JsonArray.objects(): List<JsonObject> = map { it.asJsonObject }
internal fun JsonArray.hexList(): List<Bytes> = map { Bytes.fromHex(it.asString) }

internal fun jsonOf(vararg kv: Pair<String, Any?>): JsonObject {
    val o = JsonObject()
    for ((k, v) in kv) o.add(k, toJson(v))
    return o
}

internal fun toJson(v: Any?): JsonElement = when (v) {
    null -> JsonNull.INSTANCE
    is JsonElement -> v
    is Boolean -> JsonPrimitive(v)
    is Number -> JsonPrimitive(v.toLong())
    is String -> JsonPrimitive(v)
    is Bytes -> JsonPrimitive(v.hex())
    is List<*> -> JsonArray().also { a -> v.forEach { a.add(toJson(it)) } }
    else -> throw IllegalArgumentException("no JSON for ${v::class}")
}

/** Structural JSON equality; numbers compare by value (Gson keeps them lazily parsed). */
internal fun jsonEq(a: JsonElement?, b: JsonElement?): Boolean {
    if (a.isAbsent() || b.isAbsent()) return a.isAbsent() && b.isAbsent()
    a!!
    b!!
    return when {
        a.isJsonObject && b.isJsonObject -> {
            val x = a.asJsonObject
            val y = b.asJsonObject
            x.keySet() == y.keySet() && x.keySet().all { jsonEq(x.get(it), y.get(it)) }
        }
        a.isJsonArray && b.isJsonArray -> {
            val x = a.asJsonArray
            val y = b.asJsonArray
            x.size() == y.size() && (0 until x.size()).all { jsonEq(x[it], y[it]) }
        }
        a.isJsonPrimitive && b.isJsonPrimitive -> {
            val x = a.asJsonPrimitive
            val y = b.asJsonPrimitive
            when {
                x.isNumber && y.isNumber -> x.asBigDecimal.compareTo(y.asBigDecimal) == 0
                x.isBoolean && y.isBoolean -> x.asBoolean == y.asBoolean
                x.isString && y.isString -> x.asString == y.asString
                else -> false
            }
        }
        else -> false
    }
}

internal fun assertJson(what: String, got: JsonElement?, want: JsonElement?) {
    if (!jsonEq(got, want)) fail("$what\n  got:  $got\n  want: $want")
}

internal fun <T> assertEq(what: String, got: T, want: T) {
    if (got != want) fail("$what\n  got:  $got\n  want: $want")
}

/** Counts checks per group; the summary is printed by each test class. */
internal class Checked {
    private val counts = LinkedHashMap<String, Int>()
    fun ok(group: String) {
        counts[group] = (counts[group] ?: 0) + 1
    }

    fun count(group: String): Int = counts[group] ?: 0
    override fun toString(): String = counts.entries.joinToString(", ") { "${it.key} ${it.value}" }
}

// -- body / message / ledger JSON (README "Conventions used in all JSON") ---------------------

internal object SyncJson {
    fun keyToJson(k: RecordKey): JsonObject = jsonOf("ns" to k.ns, "packet" to k.packet)

    fun keyFromJson(j: JsonObject): RecordKey = RecordKey(j.int("ns"), j.hex("packet"))

    fun bodyToJson(b: RecordBody): JsonObject {
        val j = jsonOf("key" to keyToJson(b.key), "updatedAt" to b.updatedAt)
        b.origin?.let { j.add("origin", toJson(it)) }
        if (b.flags != 0) j.add("flags", toJson(b.flags))
        b.label?.let { j.add("label", toJson(it)) }
        b.category?.let { j.add("category", toJson(it)) }
        b.note?.let { j.add("note", toJson(it)) }
        b.kind?.let { j.add("kind", toJson(it)) }
        b.place?.let { j.add("place", toJson(it)) }
        return j
    }

    fun bodyFromJson(j: JsonObject): RecordBody = RecordBody(
        key = keyFromJson(j.obj("key")),
        updatedAt = j.long("updatedAt"),
        origin = j.hexOrNull("origin"),
        flags = j.longOrNull("flags")?.toInt() ?: 0,
        label = j.strOrNull("label"),
        category = j.longOrNull("category")?.toInt(),
        note = j.strOrNull("note"),
        kind = j.strOrNull("kind"),
        place = j.longOrNull("place")?.toInt(),
    )

    fun entryToJson(e: LedgerEntry): JsonObject = jsonOf(
        "key" to e.keyString, "u" to e.version.updatedAt, "o" to e.origin, "c" to e.version.crc,
        "class" to e.recordClass.name, "b" to e.bodyBytes, "s" to e.seq, "f" to e.syncFrom,
    )

    fun ledgerToJson(l: Ledger): JsonArray = JsonArray().also { a -> l.entriesByKey().forEach { a.add(entryToJson(it)) } }

    private fun valToJson(spec: FSpec, x: Any): JsonElement = when (spec.type) {
        FType.BYTES, FType.PACKET -> toJson(x as Bytes)
        FType.KEY -> keyToJson(x as RecordKey)
        FType.LINK -> (x as HbLink).let { jsonOf("peerId" to it.peerId, "peerKind" to it.peerKind, "flags" to it.flags) }
        FType.EVTWM -> (x as EvtWm).let { jsonOf("origin" to it.origin, "epoch" to it.epoch, "seq" to it.seq) }
        FType.STR -> toJson(x as String)
        else -> toJson(x as Long)
    }

    private fun valFromJson(spec: FSpec, x: JsonElement): Any = when (spec.type) {
        FType.BYTES, FType.PACKET -> Bytes.fromHex(x.asString)
        FType.KEY -> keyFromJson(x.asJsonObject)
        FType.LINK -> x.asJsonObject.let { HbLink(it.hex("peerId"), it.int("peerKind"), it.int("flags")) }
        FType.EVTWM -> x.asJsonObject.let { EvtWm(it.hex("origin"), it.long("epoch"), it.long("seq")) }
        FType.STR -> x.asString
        else -> x.asLong
    }

    /** Generic decoded fields -> the vectors' `fields` object (REC: bodyHex + body | bodyError). */
    fun fieldsToJson(mtype: Int, f: Map<String, Any>): JsonObject {
        val j = JsonObject()
        for (spec in MsgCodec.SPECS.getValue(mtype)) {
            val x = f[spec.name] ?: continue
            if (spec.rep > 0) {
                j.add(spec.name, JsonArray().also { a -> (x as List<*>).forEach { a.add(valToJson(spec, it!!)) } })
            } else {
                j.add(spec.name, valToJson(spec, x))
            }
        }
        if (mtype == MsgType.REC) {
            val body = f[MsgCodec.BODY] as Bytes
            j.addProperty("bodyHex", body.hex())
            try {
                j.add("body", bodyToJson(RecordBody.decode(body)))
            } catch (e: SyncException) {
                j.addProperty("bodyError", ErrCode.name(e.code))
            }
        }
        return j
    }

    /** The vectors' `fields` object -> generic fields (REC: seq, reqId, seenBy + verbatim bodyHex). */
    fun fieldsFromJson(mtype: Int, j: JsonObject): Map<String, Any> {
        val f = LinkedHashMap<String, Any>()
        for (spec in MsgCodec.SPECS.getValue(mtype)) {
            val x = j.get(spec.name)
            if (x.isAbsent()) continue
            f[spec.name] = if (spec.rep > 0) x.asJsonArray.map { valFromJson(spec, it) } else valFromJson(spec, x)
        }
        if (mtype == MsgType.REC) f[MsgCodec.BODY] = j.hex("bodyHex")
        return f
    }

    /** A typed message's field map without the absent (null) entries. */
    fun typedFields(m: SyncMsg): Map<String, Any> {
        val out = LinkedHashMap<String, Any>()
        for ((k, v) in m.toFields()) if (v != null) out[k] = v
        return out
    }
}
