import com.magicmaker.android.core.AutoResponseRule
import com.magicmaker.android.core.BandEffectModel
import com.magicmaker.android.core.ClassifiedPacket
import com.magicmaker.android.core.DisneyTlv
import com.magicmaker.android.core.HexUtils
import com.magicmaker.android.core.LabPacketBuilder
import com.magicmaker.android.core.LabPacketBuilder.LabPacketType
import com.magicmaker.android.core.LabPacketTools
import com.magicmaker.android.core.MagicCategory
import com.magicmaker.android.core.MagicClassifier
import com.magicmaker.android.core.MagicPacket
import com.magicmaker.android.core.MbleBeaconBuilder
import com.magicmaker.android.core.NewWandCatalog
import com.magicmaker.android.core.PacketBuilder
import com.magicmaker.android.core.PacketPattern
import com.magicmaker.android.core.PacketPatterns
import com.magicmaker.android.core.PresetCatalog
import com.magicmaker.android.core.StarlightColors
import com.magicmaker.android.core.StarlightSerial
import com.magicmaker.android.core.toPacket
import java.io.File

// Generates ios/ParityCheck/vectors.json from the Android core. The Swift core is checked
// against this file by ios/ParityCheck/main.swift, so every value here is "what Android does".
//
// A call that throws is recorded as the string THROWS. The Swift core never traps on bad input,
// so the checker skips those instead of comparing them.

private const val THROWS = "THROWS"

private fun safe(block: () -> Any?): Any? = try {
    block()
} catch (e: Throwable) {
    THROWS
}

// ---------------------------------------------------------------------------------------------
// JSON: objects, arrays, strings, integers, booleans and null only. Keys keep insertion order,
// so the file is byte-for-byte stable from run to run.
// ---------------------------------------------------------------------------------------------

private fun obj(vararg pairs: Pair<String, Any?>): Map<String, Any?> = linkedMapOf(*pairs)

private fun jsonString(s: String): String {
    val sb = StringBuilder(s.length + 2)
    sb.append('"')
    for (ch in s) {
        when {
            ch == '"' -> sb.append("\\\"")
            ch == '\\' -> sb.append("\\\\")
            ch == '\n' -> sb.append("\\n")
            ch == '\r' -> sb.append("\\r")
            ch == '\t' -> sb.append("\\t")
            ch.code < 0x20 -> sb.append("\\u%04x".format(ch.code))
            else -> sb.append(ch)
        }
    }
    sb.append('"')
    return sb.toString()
}

private fun json(v: Any?): String = when (v) {
    null -> "null"
    is String -> jsonString(v)
    is Boolean -> v.toString()
    is Int -> v.toString()
    is Long -> v.toString()
    is Map<*, *> -> v.entries.joinToString(",", "{", "}") { jsonString(it.key as String) + ":" + json(it.value) }
    is List<*> -> v.joinToString(",", "[", "]") { json(it) }
    else -> error("Not a plain JSON value: ${v::class}")
}

// ---------------------------------------------------------------------------------------------
// Shapes shared by several sections
// ---------------------------------------------------------------------------------------------

private fun classifiedMap(c: ClassifiedPacket): Map<String, Any?> = obj(
    "hex" to c.hex,
    "label" to c.label,
    "category" to c.category.name,
    "typeInfo" to c.typeInfo,
    "colors" to c.colors,
    "simKey" to c.simKey,
)

private fun packetMap(p: MagicPacket): Map<String, Any?> = obj(
    "id" to p.id,
    "hex" to p.hex,
    "label" to p.label,
    "category" to p.category.name,
    "typeInfo" to p.typeInfo,
    "colors" to p.colors,
    "simKey" to p.simKey,
    "userRecorded" to p.userRecorded,
    "rssi" to p.rssi,
    "wandVerified" to p.wandVerified,
)

private fun patternMap(p: PacketPattern): Map<String, Any?> = obj(
    "id" to p.id,
    "label" to p.label,
    "matchKind" to p.matchKind.name,
    "matchValue" to p.matchValue,
    "defaultHex" to p.defaultHex,
    "group" to p.group,
)

private fun framingMap(f: LabPacketBuilder.Framing): Map<String, Any?> = obj(
    "channelMarker" to f.channelMarker,
    "wakePrefix" to f.wakePrefix,
    "timing" to f.timing,
)

/** What the app stores for a packet the classifier does not know. */
private fun classifiedOrRaw(hex: String): ClassifiedPacket {
    MagicClassifier.classify(hex)?.let { return it }
    val canonical = HexUtils.canonicalHex(hex)
    return ClassifiedPacket(canonical, "Raw packet", MagicCategory.UNKNOWN, "raw", "", "RAW:$canonical")
}

// ---------------------------------------------------------------------------------------------
// One record per input packet
// ---------------------------------------------------------------------------------------------

/** Colours handed to withColors for every packet: seven, so the widest shape is covered. */
private val RECOLOUR = listOf(0x15, 0x02, 0x19, 0x0F, 0x01, 0x08, 0x1B)

private fun tlvValue(hex: String): Any? {
    val p = DisneyTlv.parse(hex) ?: return null
    return obj(
        "hex" to p.hex,
        "records" to p.records.map { r ->
            obj(
                "type" to r.type,
                "declaredLength" to r.declaredLength,
                "length" to r.length,
                "headHex" to r.headHex(),
                "valueHex" to r.valueHex(),
                "legacyStarlight" to r.legacyStarlight,
                "truncated" to r.truncated,
            )
        },
        "malformed" to p.malformed,
    )
}

private fun bandValue(hex: String): Any? {
    val m = BandEffectModel.from(hex)
    return obj(
        "kind" to m.kind.name,
        "colors" to m.colors,
        "perLed" to m.perLed,
        "buzz" to m.buzz,
        "durationMs" to m.durationMs,
        "fadeMs" to m.fadeMs,
        "alwaysOn" to m.alwaysOn,
        "approximate" to m.approximate,
        "note" to m.note,
        "rgb" to m.rgb,
        "lightsBand" to m.lightsBand,
    )
}

private fun decodeValue(hex: String): Any? {
    val d = LabPacketBuilder.decode(hex) ?: return null
    return obj(
        "type" to d.type.name,
        "colors" to d.colors,
        "vibEnabled" to d.vibEnabled,
        "vibPattern" to d.vibPattern,
        "rawHex" to d.rawHex,
        "channelMarker" to d.framing.channelMarker,
        "wakePrefix" to d.framing.wakePrefix,
        "timing" to d.framing.timing,
        "showIndex" to d.showIndex,
    )
}

private fun packetRecord(hex: String): Map<String, Any?> {
    val out = LinkedHashMap<String, Any?>()
    out["hex"] = hex

    out["canonicalHex"] = safe { HexUtils.canonicalHex(hex) }
    out["isDisneyBlePacket"] = safe { HexUtils.isDisneyBlePacket(hex) }
    out["isStarlightPacket"] = safe { HexUtils.isStarlightPacket(hex) }
    out["legacyAdvertiseRejectReason"] = safe { HexUtils.legacyAdvertiseRejectReason(hex) }
    out["hasCompleteStarlightPayload"] = safe { HexUtils.hasCompleteStarlightPayload(hex) }
    out["disneyHexScore"] = safe { HexUtils.disneyHexScore(hex) }
    out["extractSerial"] = safe { StarlightSerial.extractSerial(hex) }
    out["markerFrom"] = safe { StarlightSerial.markerFrom(hex) }
    out["isStoredFormat"] = safe { StarlightSerial.isStoredFormat(hex) }

    val classified: ClassifiedPacket? = try {
        MagicClassifier.classify(hex)
    } catch (e: Throwable) {
        null
    }
    out["classify"] = safe { MagicClassifier.classify(hex)?.let { classifiedMap(it) } }
    out["isShowControl"] = safe { MagicClassifier.isShowControl(hex) }
    out["isLibraryNoise"] = safe { MagicClassifier.isLibraryNoise(hex) }
    out["rawLabel"] = safe { MagicClassifier.rawLabel(hex) }
    out["groupKey"] = safe { MagicClassifier.groupKey(hex) }
    out["groupLabel"] = safe { MagicClassifier.groupLabel(hex) }
    if (classified != null) {
        out["libraryDedupeKey"] = safe { MagicClassifier.libraryDedupeKey(classified) }
    }
    out["starlightColorIndex"] = safe { MagicClassifier.starlightColorIndex(hex) }
    out["starlightLearnColorIndex"] = safe { MagicClassifier.starlightLearnColorIndex(hex) }
    if (HexUtils.isStarlightPacket(hex)) {
        out["starlightTxHex"] = safe { MagicClassifier.starlightTxHex(hex) }
    }

    out["tlv"] = safe { tlvValue(hex) }
    out["anatomy"] = safe {
        DisneyTlv.anatomy(hex).map { s ->
            obj("hex" to s.hex, "title" to s.title, "detail" to s.detail, "kind" to s.kind.name)
        }
    }
    out["band"] = safe { bandValue(hex) }
    out["decode"] = safe { decodeValue(hex) }

    out["tailVibration"] = safe { LabPacketTools.tailVibration(hex) }
    out["withVibration3"] = safe { LabPacketTools.withVibration(hex, 3) }
    out["withTiming06"] = safe { PacketBuilder.withTiming(hex, 0x06) }
    out["withZoneMask3"] = safe { PacketBuilder.withZoneMask(hex, 3) }

    out["editableSlots"] = safe {
        LabPacketBuilder.editableSlots(hex).map { obj("label" to it.label, "hexIndex" to it.hexIndex) }
    }
    out["slotColors"] = safe { LabPacketBuilder.slotColors(hex) }
    out["withColors"] = safe { LabPacketBuilder.withColors(hex, RECOLOUR) }
    return out
}

// ---------------------------------------------------------------------------------------------
// Builder calls: each is recorded with its arguments so the Swift builders can be replayed, and
// every hex they produce also joins the packet corpus.
// ---------------------------------------------------------------------------------------------

private class BuilderCalls {
    val calls = ArrayList<Map<String, Any?>>()
    val hexes = ArrayList<String>()

    fun add(fn: String, args: List<Int>, hex: String) {
        calls += obj("fn" to fn, "args" to args, "hex" to hex)
        hexes += hex
    }
}

private fun packetBuilderCalls(): BuilderCalls {
    val b = BuilderCalls()
    val c = PacketBuilder.Color

    for (color in 0..0x1F) b.add("preset", listOf(color, 0), PacketBuilder.preset(color, 0))
    for (color in listOf(c.RED, c.WHITE, c.BLUE)) {
        for (vib in listOf(1, 5, 15)) b.add("preset", listOf(color, vib), PacketBuilder.preset(color, vib))
    }
    // Out-of-range arguments are masked, not rejected.
    for ((color, vib) in listOf(0x20 to 0x10, 0x3B to 0x1F, -1 to -1, 0x115 to 0x103)) {
        b.add("preset", listOf(color, vib), PacketBuilder.preset(color, vib))
    }
    for (vib in 0..15) b.add("vibrateBand", listOf(vib), PacketBuilder.vibrateBand(vib))

    val dualColors = listOf(c.YELLOW_ORANGE, c.BLUE, c.RED, c.WHITE, c.OFF)
    for (c1 in dualColors) for (c2 in dualColors) b.add("dual", listOf(c1, c2, 0), PacketBuilder.dual(c1, c2, 0))
    b.add("dual", listOf(c.CYAN, c.GREEN, 8), PacketBuilder.dual(c.CYAN, c.GREEN, 8))
    b.add("dual", listOf(c.PINK, c.LIME, 2), PacketBuilder.dual(c.PINK, c.LIME, 2))
    b.add("dual", listOf(0x3F, -2, 0x1A), PacketBuilder.dual(0x3F, -2, 0x1A))

    val rainbows = listOf(
        listOf(c.YELLOW_ORANGE, c.RED, c.GREEN, c.BLUE, c.PURPLE, 0),
        listOf(c.RED, c.RED, c.RED, c.RED, c.RED, 3),
        listOf(c.CYAN, c.PURPLE, c.BLUE, c.MIDNIGHT_BLUE, c.BRIGHT_PURPLE, 5),
        listOf(c.RANDOM, c.RANDOM, c.RANDOM, c.RANDOM, c.RANDOM, 0),
        listOf(c.OFF, c.WHITE, c.OFF, c.WHITE, c.OFF, 15),
        listOf(0x1E, 0x1A, 0x14, 0x11, 0x10, 1),
    )
    for (r in rainbows) b.add("rainbow5", r, PacketBuilder.rainbow5(r[0], r[1], r[2], r[3], r[4], r[5]))

    // circle: the colours, then the vibration last.
    val circles = listOf(
        listOf(0),
        listOf(5),
        listOf(c.RED, c.BLUE, 0),
        listOf(c.RED, c.BLUE, c.GREEN, c.WHITE, c.PINK, c.LIME, c.CYAN, 2),
        listOf(1, 2, 3, 4, 5, 6, 7, 8, 9, 15),
        listOf(0x3F, -1, 0x20, 8),
    )
    for (a in circles) b.add("circle", a, PacketBuilder.circle(a.dropLast(1), a.last()))

    val fades = listOf(c.RED to c.BLUE, c.BLUE to c.RED, c.PINK to c.CYAN, c.WHITE to c.OFF, c.GREEN to c.GREEN, c.LAVENDER to c.ORANGE)
    for ((c1, c2) in fades) b.add("crossfade", listOf(c1, c2, 0), PacketBuilder.crossfade(c1, c2, 0))
    b.add("crossfade", listOf(c.RED, c.BLUE, 5), PacketBuilder.crossfade(c.RED, c.BLUE, 5))
    b.add("crossfade", listOf(0x35, 0x22, 0x1F), PacketBuilder.crossfade(0x35, 0x22, 0x1F))

    val rotations = listOf(
        listOf(c.BLUE, c.BLUE, c.BLUE, 0x04, 0x04, 0),
        listOf(c.RED, c.ORANGE, c.YELLOW_ORANGE, c.GREEN, c.BLUE, 0),
        listOf(c.WHITE, c.OFF, c.WHITE, c.OFF, c.WHITE, 3),
        listOf(c.PINK, c.PINK, c.CYAN, c.CYAN, c.PURPLE, 8),
        listOf(0x21, 0x42, 0x63, 0x84, 0xA5, 0x16),
    )
    for (z in rotations) b.add("rotate", z, PacketBuilder.rotate(z[0], z[1], z[2], z[3], z[4], z[5]))

    val rgbs = listOf(
        listOf(63, 20, 0, 0),
        listOf(0, 0, 0, 0),
        listOf(63, 63, 63, 0),
        listOf(0, 63, 0, 5),
        listOf(1, 2, 3, 1),
        listOf(31, 32, 33, 15),
        listOf(64, 127, -1, 16),
    )
    for (v in rgbs) b.add("rgb", v, PacketBuilder.rgb(v[0], v[1], v[2], v[3]))
    return b
}

private class LabBuilds {
    val builds = ArrayList<Map<String, Any?>>()
    val hexes = ArrayList<String>()

    /** [framing] null means "leave the argument out", i.e. the type's own default framing. */
    fun add(
        type: LabPacketType,
        colors: List<Int>,
        vibEnabled: Boolean,
        vibPattern: Int,
        rawHex: String = "",
        framing: LabPacketBuilder.Framing? = null,
        showIndex: Int = 0,
    ) {
        val hex = if (framing == null) {
            LabPacketBuilder.build(type, colors, vibEnabled, vibPattern, rawHex, showIndex = showIndex)
        } else {
            LabPacketBuilder.build(type, colors, vibEnabled, vibPattern, rawHex, framing, showIndex)
        }
        builds += obj(
            "type" to type.name,
            "colors" to colors,
            "vibEnabled" to vibEnabled,
            "vibPattern" to vibPattern,
            "rawHex" to rawHex,
            "framing" to framing?.let { framingMap(it) },
            "showIndex" to showIndex,
            "hex" to hex,
        )
        hexes += hex
    }
}

private fun labBuilds(): LabBuilds {
    val b = LabBuilds()
    val rawSample = "e905002e0ef5b0"
    val timings = listOf(PacketBuilder.Timing.DEFAULT, PacketBuilder.Timing.ALWAYS_ON, PacketBuilder.Timing.S10)

    for (type in LabPacketType.values()) {
        val colors = LabPacketBuilder.defaultColors(type)
        b.add(type, colors, false, 0, rawSample)
        b.add(type, colors, true, 5, rawSample)
        for (channel in listOf(false, true)) {
            for (wake in listOf(false, true)) {
                for (timing in timings) {
                    b.add(type, colors, true, 3, rawSample, LabPacketBuilder.Framing(channel, wake, timing))
                }
            }
        }
        // No colours at all, and too few: every missing slot falls back to the type's default.
        b.add(type, emptyList(), false, 0, rawSample)
        if (colors.size > 1) b.add(type, colors.take(1), true, 9, rawSample)
        // Too many, and out of range: extra colours are ignored and each is masked to 5 bits.
        b.add(type, listOf(0x3F, -1, 0x20, 0x7B, 0x115, 0x02, 0x19, 0x08, 0x0F), true, 99, rawSample)
    }

    // Every park show and experiment as shipped, then recoloured.
    for (i in LabPacketBuilder.showEffects.indices) {
        b.add(LabPacketType.SHOW, emptyList(), false, 0, showIndex = i)
        b.add(LabPacketType.SHOW, RECOLOUR, false, 0, showIndex = i)
    }
    for (i in LabPacketBuilder.experiments.indices) {
        b.add(LabPacketType.EXPERIMENT, emptyList(), false, 0, showIndex = i)
        b.add(LabPacketType.EXPERIMENT, RECOLOUR, false, 0, showIndex = i)
    }
    // An index off either end falls back to the first entry.
    for (i in listOf(-1, 999)) {
        b.add(LabPacketType.SHOW, emptyList(), false, 0, showIndex = i)
        b.add(LabPacketType.EXPERIMENT, emptyList(), false, 0, showIndex = i)
    }
    for (raw in listOf("", "8301CC03000100", "cf9b00c42922efd819f22a621b", "E1 00 E9 05 00 2E 0E F5 B0", "zz")) {
        b.add(LabPacketType.RAW, emptyList(), false, 0, raw)
    }
    return b
}

// ---------------------------------------------------------------------------------------------
// The packet corpus
// ---------------------------------------------------------------------------------------------

private fun corpus(repoRoot: File, builderHexes: List<String>, labHexes: List<String>): List<String> {
    val base = LinkedHashSet<String>()

    PresetCatalog.all.forEach { base += it.hex }
    base += PacketBuilder.WAKEUP_PING
    base += PacketBuilder.rainbowFinale()
    base += builderHexes
    base += labHexes
    LabPacketBuilder.showEffects.forEach { base += it.second }
    LabPacketBuilder.experiments.forEach { base += it.hex }

    // Every packet written out in the protocol notes, prefixes included.
    val protocol = File(repoRoot, "docs/PROTOCOL.md").readText(Charsets.UTF_8)
    Regex("8301[0-9A-Fa-f]+").findAll(protocol).forEach { base += it.value }

    // Pings: the named ones, then arbitrary bodies and odd framings.
    base += listOf(
        "8301CC03000000", "8301CC03000100", "8301CC03234100", "8301CC03203000", "8301CC03132000",
        "8301CC03FFFFFF", "8301CC03123456", "8301CC03000101", "8301CC0400010000", "8301CC020001",
        "8301CC00", "8301CC03000100CC03234100", "8301E100CC03000100", "8301CC030001", "8301CC03000100E100",
        "8301CC03000100E200E90500110EFBB0",
    )

    // Beacon families: a first record of type E0..EF other than E9.
    base += listOf(
        "8301EF0501A6001500", "8301EF0501A6E01B00", "8301EF0501A6000200", "8301EF0501A6FF3F7F",
        "8301EF050203040506", "8301EF0501A7001500", "8301EF0501A6", "8301EF05",
        "8301EF080102030405060708", "8301EF0801A6001500000000", "8301EF08010203",
        "8301E409010203040506070809", "8301E409010203040506070809EF0501A6000800",
        "8301E409010203040506070809E501AAEF0501A6001900", "8301E409010203040506070809E501AA",
        "8301E40901020304", "8301E501AA", "8301E50100", "8301E5020001",
        "8301EA0C0102030405060708090A0B0C", "8301EA0C000000000000000000000000", "8301EA03010203", "8301EA00",
        "8301E000", "8301E60400010203", "8301EB021234", "8301EC00ED00", "8301EE0155",
        "8301E100", "8301E200", "8301E300", "8301E100E200", "8301E10100", "8301E400E90500110EFBB0",
        "8301EF0501A6001500E90500110EFBB0",
    )

    // Guest-band telemetry: never an effect.
    base += listOf(
        "8301C00F0102030405060708090A0B0C0D0E0F",
        "8301C00F000000000000000000000000000000",
        "8301C013000102030405060708090A0B0C0D0E0F101112",
        "8301C013FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
        "8301C00F0102030405",
        "8301C000",
        "83010F1100112233445566778899AABBCCDDEEFF00",
        "83010F11FFEEDDCCBBAA99887766554433221100FF",
        "83010F1100112233",
        "83010F00",
        "8301C1020304",
        "8301D00401020304",
        "8301000000",
    )

    // Starlight: both markers in every colour, with the default and a full-length serial.
    val longSerial = "0123456789ABCDEF012345"
    for (color in 0..0x1F) {
        base += StarlightColors.broadcastHex(color)
        base += StarlightSerial.buildHex(StarlightSerial.DEFAULT_SERIAL, color, "CF0B")
    }
    for (color in listOf(0x00, 0x08, 0x15, 0x1B, 0x1F)) {
        base += StarlightSerial.buildHex(longSerial, color, "CF9B")
        base += StarlightSerial.buildHex(longSerial, color, "CF0B")
    }
    val wands = NewWandCatalog.packets
    for (i in listOf(0, 1, 2, 31, 80, 159, 160, 161, 200, 255, wands.size - 2, wands.size - 1)) {
        wands.getOrNull(i)?.let { base += it.hex }
    }
    base += listOf(
        // Wake prefix in front, the template's zero run, short and cut-off payloads.
        "8301CC03000100CF9B00C42922EFD819F22A621B",
        "8301CC03000100CF9B00C42922EFD819F22A6215B0",
        "8301CF9B000000000000000000000015",
        "8301CF9B00000000000000000000001BB0",
        "8301CF0B000000000000000000000008",
        "8301CF9B", "8301CF0B", "8301CF9B00", "8301CF9B0015", "8301CF9B1B", "8301CF0B00C0",
        "8301CF9B00C42922EFD819F2", "8301CF0B00C020224EAC78",
        "8301CF0B0102030405060708090A0B",
        "8301CF0B0102030405060708090A0B0C0D",
        "8301CF0C0102030405060708090A0B0C",
        "8301CF9BCF0B00C42922EFD819F22A6205",
        "8301CF0BCF9B00C42922EFD819F22A6205",
        "8301E100CF9B00C42922EFD819F22A6202",
        "8301E905002E0ECF9BB0",
        "8301CF9B00C42922EFD819F22A62190102030405060708090A0B0C0D0E0F10",
        "CF9B00C42922EFD819F22A621B", "CF0B00C020224EAC7807866E80", "C020224EAC7807866E80",
    )

    // Effect records with unusual lengths, flags and tails.
    base += listOf(
        "8301E900", "8301E90100", "8301E9020001", "8301E903000102", "8301E90400010203",
        "8301E905", "8301E90500", "8301E905002E", "8301E905002E0E", "8301E905002E0EF5",
        "8301E905002E0E15B0", "8301E905002E0E35B0", "8301E905002E0E55B0", "8301E905002E0E75B0",
        "8301E905002E0E95B0", "8301E905002E0EB5B0", "8301E905002E0ED5B0", "8301E905002E0EF5BF",
        "8301E905002E0EF501", "8301E90500FF0EF5B0", "8301E90500000EF5B0", "8301E90500790EF5B0",
        "8301E100E905002E0EF5B0E905002E0EE2B0",
        "8301E90700220F555942B0", "8301E90A002E0FB5B9A2A1B5B9B0", "8301E90D000102030405060708090A0BB0",
        "8301E915000102030405060708090A0B0C0D0E0F10111213B0",
        "8301E100E9130001024142430405060708090A0B0C0D0E0FB0",
        "8301E100E913000102414243",
        "8301E100E912000300A2A2A4A4A230D037F4D2460064FCB0",
        "8301E100E9140054D037F0D23D051E180EF38983510EF10C49B0",
        "8301E100E9140054D037F0D23D031E180EF38983510EF10C49B0",
        "8301E100E90C000F0F4F4F5B0102030405B0", "8301E100E90C000F0FB1B9B5B1A2307B7DB0",
        "8301E100E90C000F0F8182030405060708B0", "8301E100E90C00010F4D57",
        "8301E100E9100019489700000000000000000000001FB0",
        "8301E100E908000ED2557E2800B0",
        "8301E100E90800",
        "8301E100E90B0B0F0F5C5D48A5D14532",
        "8301E3FFE905002E0EF5B0",
    )

    // A sample of the above, damaged the ways a scan or a text field damages packets.
    val sorted = base.filter { it.isNotEmpty() }.sorted()
    val all = LinkedHashSet<String>(base)
    sorted.forEachIndexed { i, h ->
        if (i % 9 != 0) return@forEachIndexed
        all += h.dropLast(2)                        // last byte dropped
        all += h.dropLast(1)                        // last nibble dropped: odd length
        all += h + "7F"                             // an extra trailing byte
        all += h.lowercase()
        all += h.chunked(2).joinToString(" ")
        all += h.removePrefix("8301")
    }

    all += listOf("", "00", "ZZ", "8301", "83", "8301E9", "8301E905", "0", "8", "830", "83018", "not hex at all", "  8301 e905 002e 0ef5 b0  ")
    return all.sorted()
}

// ---------------------------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------------------------

/** The E905 zone-mask list lives in the Lab screen, not in core; read it from the source. */
private fun ledMasks(repoRoot: File): List<Map<String, Any?>> {
    val file = File(repoRoot, "android/app/src/main/java/com/magicmaker/android/ui/LabPacketBuilderPanel.kt")
    val text = file.readText(Charsets.UTF_8)
    val start = text.indexOf("private val LED_MASKS")
    check(start >= 0) { "LED_MASKS not found in ${file.path}" }
    val end = text.indexOf("\n)", start)
    check(end > start) { "LED_MASKS: end of list not found in ${file.path}" }
    val masks = Regex("""(\d+)\s+to\s+"([^"]*)"""").findAll(text.substring(start, end))
        .map { obj("mask" to it.groupValues[1].toInt(), "label" to it.groupValues[2]) }
        .toList()
    check(masks.isNotEmpty()) { "LED_MASKS: no entries parsed from ${file.path}" }
    return masks
}

private fun tables(repoRoot: File, userPresets: List<MagicPacket>, learned: List<MagicPacket>): Map<String, Any?> {
    val c = PacketBuilder.Color
    val v = PacketBuilder.Vibration
    val t = PacketBuilder.Timing

    val constants = obj(
        "HexUtils.DISNEY_COMPANY_ID" to HexUtils.DISNEY_COMPANY_ID,
        "HexUtils.MAX_MFG_PAYLOAD_BYTES" to HexUtils.MAX_MFG_PAYLOAD_BYTES,
        "HexUtils.MAGIC_MAKER_LOCAL_NAME_PREFIX" to HexUtils.MAGIC_MAKER_LOCAL_NAME_PREFIX,
        "StarlightSerial.SERIAL_HEX_LEN" to StarlightSerial.SERIAL_HEX_LEN,
        "StarlightSerial.DEFAULT_SERIAL" to StarlightSerial.DEFAULT_SERIAL,
        "DisneyTlv.COMPANY_PREFIX" to DisneyTlv.COMPANY_PREFIX,
        "DisneyTlv.TYPE_PING" to DisneyTlv.TYPE_PING,
        "DisneyTlv.TYPE_WAND" to DisneyTlv.TYPE_WAND,
        "DisneyTlv.TYPE_EFFECT" to DisneyTlv.TYPE_EFFECT,
        "DisneyTlv.TYPE_CHANNEL_1" to DisneyTlv.TYPE_CHANNEL_1,
        "DisneyTlv.TYPE_CHANNEL_2" to DisneyTlv.TYPE_CHANNEL_2,
        "DisneyTlv.TYPE_CHANNEL_3" to DisneyTlv.TYPE_CHANNEL_3,
        "DisneyTlv.TYPE_BAND_TELEMETRY" to DisneyTlv.TYPE_BAND_TELEMETRY,
        "DisneyTlv.TYPE_BAND_ID" to DisneyTlv.TYPE_BAND_ID,
        "DisneyTlv.LEGACY_STARLIGHT_LENGTH" to DisneyTlv.LEGACY_STARLIGHT_LENGTH,
        "PacketBuilder.WAKEUP_PING" to PacketBuilder.WAKEUP_PING,
        "PacketBuilder.rainbowFinale" to PacketBuilder.rainbowFinale(),
        "PacketBuilder.vibrateBand" to PacketBuilder.vibrateBand(),
        "PacketBuilder.rainbow5" to PacketBuilder.rainbow5(),
        "PacketBuilder.circle" to PacketBuilder.circle(),
        "PacketBuilder.crossfade" to PacketBuilder.crossfade(),
        "PacketBuilder.CIRCLE_PATTERN" to PacketBuilder.CIRCLE_PATTERN.toList(),
        "PacketBuilder.Color.CYAN" to c.CYAN,
        "PacketBuilder.Color.PURPLE" to c.PURPLE,
        "PacketBuilder.Color.BLUE" to c.BLUE,
        "PacketBuilder.Color.MIDNIGHT_BLUE" to c.MIDNIGHT_BLUE,
        "PacketBuilder.Color.BRIGHT_PURPLE" to c.BRIGHT_PURPLE,
        "PacketBuilder.Color.LAVENDER" to c.LAVENDER,
        "PacketBuilder.Color.PINK" to c.PINK,
        "PacketBuilder.Color.YELLOW_ORANGE" to c.YELLOW_ORANGE,
        "PacketBuilder.Color.LIME" to c.LIME,
        "PacketBuilder.Color.ORANGE" to c.ORANGE,
        "PacketBuilder.Color.RED" to c.RED,
        "PacketBuilder.Color.GREEN" to c.GREEN,
        "PacketBuilder.Color.WHITE" to c.WHITE,
        "PacketBuilder.Color.OFF" to c.OFF,
        "PacketBuilder.Color.RANDOM" to c.RANDOM,
        "PacketBuilder.Vibration.OFF" to v.OFF,
        "PacketBuilder.Vibration.SHORT" to v.SHORT,
        "PacketBuilder.Vibration.DOUBLE" to v.DOUBLE,
        "PacketBuilder.Vibration.TRIPLE" to v.TRIPLE,
        "PacketBuilder.Vibration.BURST" to v.BURST,
        "PacketBuilder.Vibration.LONG" to v.LONG,
        "PacketBuilder.Timing.DEFAULT" to t.DEFAULT,
        "PacketBuilder.Timing.ALWAYS_ON" to t.ALWAYS_ON,
        "PacketBuilder.Timing.S20" to t.S20,
        "PacketBuilder.Timing.S10" to t.S10,
        "PacketBuilder.Timing.S5" to t.S5,
        "PacketBuilder.Timing.S3" to t.S3,
        "NewWandCatalog.PREFIX" to NewWandCatalog.PREFIX,
        "NewWandCatalog.ID_BASE" to NewWandCatalog.ID_BASE,
        "PacketPatterns.NEWWAND_RANDOM_TOKEN" to PacketPatterns.NEWWAND_RANDOM_TOKEN,
        "MbleBeaconBuilder.MANUFACTURER_ID" to MbleBeaconBuilder.MANUFACTURER_ID,
        "MbleBeaconBuilder.BEACON_LAYOUT" to MbleBeaconBuilder.BEACON_LAYOUT,
        "MbleBeaconBuilder.BEACON_ID" to MbleBeaconBuilder.BEACON_ID,
        "LabPacketBuilder.buildPing" to LabPacketBuilder.buildPing(),
        "LabPacketBuilder.buildRainbowFinale" to LabPacketBuilder.buildRainbowFinale(),
    )

    val wands = NewWandCatalog.packets
    val indexes = (-2..40).toList()
    val colorNames = listOf(
        "red", "Blue", " cyan ", "GREEN", "purple", "bright purple", "br-purple", "brightpurple",
        "midnight_blue", "mid blue", "lavender", "pink", "white", "orange", "yellow orange", "y-orange",
        "yelloworange", "lime", "off", "random", "red orange", "red-orange", "#1B", "#ff", "#zz", "#",
        "# 1B", "1b", "0F", "zz", "1 B", "Unique", "lime green", "Off Yellow", "yellow", "Midnight Blue",
        "Red Orange", "", "nothing", "#123456789",
    )
    val paletteLabels = listOf("#1B White", "#1b white", "#00 Cyan", "#1F Random", "White", "red", "#15", "15", "nope", "")
    val serials = listOf(
        "", "C42922EFD819F22A62", "0123456789ABCDEF012345", "0123456789abcdef0123456789",
        "01 23 45 67 89 AB CD EF 01 23 45", "zz", "0123456789ABCDEF01234",
    )
    val tokens = listOf(
        "", "AB", "ABCD", "0123456789ABCDEF0123456789ABCDEF", "00112233445566778899AABBCCDDEEFF0011",
        "a1b2c3d4e5f6", "zz11zz22", "FF",
    )
    val wandIds = listOf(1_000_000L, 1_000_001L, 1_000_159L, 1_000_160L, 1_000_255L, 1_000_256L, 1_000_383L, 1_000_384L, 5L, 0L, -1L, 999_999L)

    return obj(
        "constants" to constants,
        "presets" to PresetCatalog.all.map { obj("label" to it.label, "hex" to it.hex, "kind" to it.kind.name) },
        "asMagicPackets" to PresetCatalog.asMagicPackets().map { packetMap(it) },
        "showBlocks" to PresetCatalog.showBlocks.entries.sortedBy { it.key }.map { obj("name" to it.key, "hex" to it.value) },
        "palette" to StarlightColors.palette.entries.sortedBy { it.key }.map { obj("index" to it.key, "name" to it.value) },
        "starlightColorNames" to PresetCatalog.starlightColorNames.entries.sortedBy { it.key }.map { obj("index" to it.key, "name" to it.value) },
        "starlightEntries" to StarlightColors.entries().map { obj("index" to it.index, "name" to it.name, "hex" to it.hex) },
        "starlightEntriesLongSerial" to StarlightColors.entries("0123456789ABCDEF012345").map { obj("index" to it.index, "name" to it.name, "hex" to it.hex) },
        "indexes" to indexes,
        "nameFor" to indexes.map { StarlightColors.nameFor(it) },
        "starlightSimKey" to indexes.map { PresetCatalog.starlightSimKey(it) },
        "legacyStarlightHex" to indexes.map { PresetCatalog.legacyStarlightHex(it) },
        "labLabel" to indexes.map { LabPacketBuilder.labLabel(it) },
        "paletteLabel" to indexes.map { LabPacketBuilder.paletteLabel(it) },
        "serials" to serials,
        "normalizeSerial" to serials.map { safe { StarlightSerial.normalizeSerial(it) } },
        "validatedSerial" to serials.map { safe { StarlightSerial.validatedSerial(it) } },
        "validatedSerialNull" to StarlightSerial.validatedSerial(null),
        "buildHexCF9B" to serials.map { safe { StarlightSerial.buildHex(it, 0x15) } },
        "buildHexCF0B" to serials.map { safe { StarlightSerial.buildHex(it, 0x3B, "CF0B") } },
        "buildHexOtherMarker" to serials.map { safe { StarlightSerial.buildHex(it, -1, "cf0b") } },
        "newWand" to obj(
            "count" to wands.size,
            "first5" to wands.take(5).map { packetMap(it) },
            "last5" to wands.takeLast(5).map { packetMap(it) },
            "ids" to wands.map { it.id },
            "hexes" to wands.map { it.hex },
            "lookupIds" to wandIds,
            "byId" to wandIds.map { id -> NewWandCatalog.byId(id)?.let { packetMap(it) } },
            "isNewWandId" to wandIds.map { NewWandCatalog.isNewWandId(it) },
        ),
        "lab" to obj(
            "types" to LabPacketType.values().map { type ->
                obj(
                    "type" to type.name,
                    "label" to type.label,
                    "blurb" to type.blurb,
                    "colorSlots" to type.colorSlots,
                    "supportsVib" to type.supportsVib,
                    "experimental" to type.experimental,
                    "defaultColors" to LabPacketBuilder.defaultColors(type),
                    "defaultFraming" to framingMap(LabPacketBuilder.defaultFraming(type)),
                    "framingApplies" to LabPacketBuilder.framingApplies(type),
                )
            },
            "showEffects" to LabPacketBuilder.showEffects.map { obj("name" to it.first, "hex" to it.second) },
            "experiments" to LabPacketBuilder.experiments.map { obj("name" to it.name, "hex" to it.hex, "watch" to it.watch) },
            "vibrationPatterns" to LabPacketBuilder.vibrationPatterns.map { obj("label" to it.label, "id" to it.id) },
            "paletteColors" to LabPacketBuilder.paletteColors.map { obj("label" to it.label, "id" to it.id) },
            "primaryPresetColors" to LabPacketBuilder.primaryPresetColors.map { obj("label" to it.label, "id" to it.id) },
            "ledMasks" to ledMasks(repoRoot),
            "timingOptions" to PacketBuilder.Timing.options.map { obj("value" to it.first, "label" to it.second) },
            "vibArgs" to listOf(listOf(1, -1), listOf(1, 0), listOf(1, 7), listOf(1, 15), listOf(1, 16), listOf(1, 99), listOf(0, 9), listOf(0, -4)),
            "vib" to listOf(
                LabPacketBuilder.vib(true, -1), LabPacketBuilder.vib(true, 0), LabPacketBuilder.vib(true, 7),
                LabPacketBuilder.vib(true, 15), LabPacketBuilder.vib(true, 16), LabPacketBuilder.vib(true, 99),
                LabPacketBuilder.vib(false, 9), LabPacketBuilder.vib(false, -4),
            ),
            "colorNames" to colorNames,
            "colorFromName" to colorNames.map { safe { PacketBuilder.colorFromName(it) } },
            "paletteLabels" to paletteLabels,
            "paletteId" to paletteLabels.map { safe { LabPacketBuilder.paletteId(it) } },
            "buildPresetByName" to colorNames.map { safe { LabPacketBuilder.buildPreset(it, true, 2) } },
        ),
        "patterns" to obj(
            "systemTriggers" to PacketPatterns.systemTriggers.map { patternMap(it) },
            "systemResponses" to PacketPatterns.systemResponses.map { patternMap(it) },
            "triggerOptions" to PacketPatterns.buildTriggerOptions(userPresets, learned).map { patternMap(it) },
            "responseOptionCount" to PacketPatterns.buildResponseOptions(userPresets, learned).size,
            "responseOptionsHead" to PacketPatterns.buildResponseOptions(userPresets, learned).take(40).map { patternMap(it) },
            "responseOptionsTail" to PacketPatterns.buildResponseOptions(userPresets, learned).takeLast(4).map { patternMap(it) },
        ),
        "tlv" to obj(
            "timingCaption" to (0..255).map { DisneyTlv.timingCaption(it) },
            "effectName" to (0..32).map { DisneyTlv.effectName(it) },
            "colorSlotCount" to (0..32).map { DisneyTlv.colorSlotCount(it) },
            "pingValues" to listOf("000000", "000100", "234100", "203000", "132000", "", "0001", "00010000", "FFFFFF", "000100 "),
            "pingName" to listOf("000000", "000100", "234100", "203000", "132000", "", "0001", "00010000", "FFFFFF", "000100 ").map { DisneyTlv.pingName(it) },
        ),
        "beacon" to obj(
            "tokens" to tokens,
            "manufacturerPayload" to tokens.map { token -> safe { HexUtils.bytesToHex(MbleBeaconBuilder.manufacturerPayload(token)) } },
        ),
    )
}

// ---------------------------------------------------------------------------------------------
// Auto-response rules
// ---------------------------------------------------------------------------------------------

private fun learnedPackets(): List<MagicPacket> {
    val hexes = listOf(
        "8301E100E905002E0EF5B0",
        "8301CF9B000123456789ABCDEF0123451B",
        "8301E90600220F8F82B0",
        "8301CC03000100E100E90C000F0F5D465BF005323748B0",
        "8301C10203",
    )
    return hexes.mapIndexed { i, h -> classifiedOrRaw(h).toPacket(userRecorded = true).copy(id = 40L + i) }
}

private fun rules(userPresets: List<MagicPacket>, learned: List<MagicPacket>): Map<String, Any?> {
    val triggerIds = listOf(
        "ping_fast", "ping_prefix", "starlight", "newwand", "e905", "e90c", "rainbow", "any_raw",
        "preset_t_1", "preset_t_2", "preset_t_4", "preset_t_12", "preset_t_16", "preset_t_99", "preset_t_x", "preset_t_",
        "learned_t_40", "learned_t_41", "learned_t_42", "learned_t_43", "learned_t_44", "learned_t_7", "learned_t_",
        "nope", "", "PING_FAST",
    )
    val heard = listOf(
        PacketBuilder.WAKEUP_PING,
        "83 01 cc 03 00 01 00",
        "8301CC03234100",
        PacketBuilder.preset(PacketBuilder.Color.RED),
        "e905002e0ef5b0",
        "8301E100E905002E0EF5B0",
        PacketBuilder.rainbowFinale(),
        "8301CC03000100E100E90C000F0F5D465BF00532374895",
        StarlightColors.broadcastHex(0x1B),
        "8301CF9B000123456789ABCDEF01234515",
        NewWandCatalog.packets.first().hex,
        PacketBuilder.dual(PacketBuilder.Color.YELLOW_ORANGE, PacketBuilder.Color.BLUE),
        "8301E100E90C00010F4D575A940705488BB0",
        "8301C00F0102030405060708090A0B0C0D0E0F",
        "8301EF0501A6001500",
        PacketBuilder.crossfade(),
        "8301C10203",
    )
    // No rule uses the RANDOM_NEWWAND token: it resolves to a different code on every call.
    val ruleList = listOf(
        AutoResponseRule(1, "wake", "ping_fast", "resp_wakeup", "", emptyList(), true),
        AutoResponseRule(2, "vibrate", "starlight", "resp_vibrate", "8301E905002E0EF5B0", emptyList(), true),
        AutoResponseRule(3, "rainbow", "e905", "resp_rainbow", "", emptyList(), false),
        AutoResponseRule(4, "preset red", "newwand", "preset_r_4", "", emptyList(), true),
        AutoResponseRule(5, "preset gone", "any_raw", "preset_r_99", "e905002e0ef5b0", emptyList(), true),
        AutoResponseRule(6, "learned wand", "rainbow", "learned_r_41", "", emptyList(), true),
        AutoResponseRule(7, "learned gone", "e90c", "learned_r_7", "", emptyList(), true),
        AutoResponseRule(8, "new wand first", "starlight", "newwand_r_1000000", "", emptyList(), true),
        AutoResponseRule(9, "new wand excluded", "starlight", "newwand_r_1000160", "  8301cc03000100 ", emptyList(), true),
        AutoResponseRule(10, "stack", "starlight", "", "", listOf("8301E905002E0EF5B0", "e905 002e 0efb b5", "", "zz", "CF9B00C42922EFD819F22A621B"), true),
        AutoResponseRule(11, "stack beats pattern", "ping_prefix", "resp_wakeup", "8301E905002E0EF5B0", listOf("8301E90600220F8F82B0", "8301CC03000100"), true),
        AutoResponseRule(12, "custom hex", "ping_prefix", "custom", "8301E90600220F8F82B0", emptyList(), true),
        AutoResponseRule(13, "bad preset id", "ping_prefix", "preset_r_x", "", emptyList(), true),
        AutoResponseRule(14, "empty stack entries only", "ping_prefix", "preset_r_1", "", listOf("", "zz", "  "), true),
        AutoResponseRule(15, "nothing", "ping_prefix", "", "   ", emptyList(), true),
        AutoResponseRule(16, "learned raw", "ping_prefix", "learned_r_44", "", emptyList(), true),
    )

    return obj(
        "userPresets" to userPresets.map { packetMap(it) },
        "learned" to learned.map { packetMap(it) },
        "triggerIds" to triggerIds,
        "packets" to heard.map { hex ->
            val classified = classifiedOrRaw(hex)
            obj(
                "hex" to hex,
                "classified" to classifiedMap(classified),
                "matches" to triggerIds.map { id -> safe { PacketPatterns.matchesTriggerId(id, classified, hex, userPresets, learned) } },
                "matchesNoPresets" to triggerIds.map { id -> safe { PacketPatterns.matchesTriggerId(id, classified, hex, emptyList(), learned) } },
            )
        },
        "rules" to ruleList.map { rule ->
            obj(
                "id" to rule.id,
                "name" to rule.name,
                "triggerPatternId" to rule.triggerPatternId,
                "responsePatternId" to rule.responsePatternId,
                "responseHex" to rule.responseHex,
                "responseHexes" to rule.responseHexes,
                "enabled" to rule.enabled,
                "resolved" to safe { PacketPatterns.resolveResponseHexes(rule, userPresets, learned) },
                "resolvedFirst" to safe { PacketPatterns.resolveResponseHex(rule, userPresets, learned) },
                "resolvedNoLibrary" to safe { PacketPatterns.resolveResponseHexes(rule, emptyList(), emptyList()) },
            )
        },
    )
}

// ---------------------------------------------------------------------------------------------

fun main(args: Array<String>) {
    val repoRoot = File(args.firstOrNull() ?: "../..").canonicalFile
    check(File(repoRoot, "docs/PROTOCOL.md").isFile) { "Not the repository root: $repoRoot" }

    val builderCalls = packetBuilderCalls()
    val lab = labBuilds()
    val hexes = corpus(repoRoot, builderCalls.hexes, lab.hexes)
    val userPresets = PresetCatalog.asMagicPackets()
    val learned = learnedPackets()

    val sb = StringBuilder()
    sb.append("{\n")
    sb.append("\"version\":1,\n")
    sb.append("\"note\":").append(jsonString("Generated by tools/parity from the Android core. Do not edit; regenerate.")).append(",\n")

    // One packet per line keeps diffs readable.
    sb.append("\"packets\":[\n")
    hexes.forEachIndexed { i, hex ->
        sb.append(json(packetRecord(hex)))
        sb.append(if (i == hexes.size - 1) "\n" else ",\n")
    }
    sb.append("],\n")

    sb.append("\"packetBuilder\":[\n")
    builderCalls.calls.forEachIndexed { i, call ->
        sb.append(json(call)).append(if (i == builderCalls.calls.size - 1) "\n" else ",\n")
    }
    sb.append("],\n")

    sb.append("\"labBuilds\":[\n")
    lab.builds.forEachIndexed { i, build ->
        sb.append(json(build)).append(if (i == lab.builds.size - 1) "\n" else ",\n")
    }
    sb.append("],\n")

    sb.append("\"tables\":{\n")
    val tableEntries = tables(repoRoot, userPresets, learned).entries.toList()
    tableEntries.forEachIndexed { i, (key, value) ->
        sb.append(jsonString(key)).append(":").append(json(value))
        sb.append(if (i == tableEntries.size - 1) "\n" else ",\n")
    }
    sb.append("},\n")

    sb.append("\"rules\":{\n")
    val ruleEntries = rules(userPresets, learned).entries.toList()
    ruleEntries.forEachIndexed { i, (key, value) ->
        sb.append(jsonString(key)).append(":").append(json(value))
        sb.append(if (i == ruleEntries.size - 1) "\n" else ",\n")
    }
    sb.append("}\n")
    sb.append("}\n")

    val out = File(repoRoot, "ios/ParityCheck/vectors.json")
    out.parentFile.mkdirs()
    out.writeText(sb.toString(), Charsets.UTF_8)
    println("${hexes.size} packets, ${builderCalls.calls.size} builder calls, ${lab.builds.size} lab builds -> ${out.path}")
}
