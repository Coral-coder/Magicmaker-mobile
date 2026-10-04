package com.magicmaker.android.core

/**
 * The Disney BLE payload is type-length-value framed. After the `8301` company ID comes a
 * chain of `<type:1><length:1><value:length>` records running to the end of the
 * advertisement; a record may have length 0 (a bare marker). See docs/PROTOCOL.md — this was
 * validated against every distinct packet in a 45k-advertisement park capture and against
 * every packet this app can transmit.
 *
 * Everything that used to be a substring heuristic ("does the hex contain E?00E9 somewhere")
 * should go through [parse] instead: the records are the ground truth, and a byte sequence
 * that merely *looks* like a record type inside some other record's value no longer fools us.
 */
object DisneyTlv {
    const val COMPANY_PREFIX = "8301"

    /** Record types we have names for. Values are the on-air type byte. */
    const val TYPE_PING = 0xCC
    const val TYPE_WAND = 0xCF
    const val TYPE_EFFECT = 0xE9
    const val TYPE_CHANNEL_1 = 0xE1
    const val TYPE_CHANNEL_2 = 0xE2
    const val TYPE_CHANNEL_3 = 0xE3
    const val TYPE_BAND_TELEMETRY = 0xC0
    const val TYPE_BAND_ID = 0x0F

    /**
     * The legacy Starlight template in this codebase uses marker `CF9B`. Read as TLV that is
     * type CF with a 155-byte body, which cannot fit a 31-byte advertisement; the 9-byte
     * default serial + colour it carries is exactly 11 bytes, i.e. what `CF0B` declares. We
     * keep parsing it (consuming the rest of the packet as the value) so the wand UI keeps
     * working, but flag it so nobody mistakes it for well-formed framing.
     */
    const val LEGACY_STARLIGHT_LENGTH = 0x9B

    /**
     * [declaredLength] is the on-air length byte; [length] is how many value bytes are actually
     * present. They differ only for a [truncated] final record — a packet cut short (the iOS
     * UUID-slice scan path can do this), which we still want to classify by its declared shape.
     */
    class Record(
        val type: Int,
        val value: ByteArray,
        val declaredLength: Int = value.size,
        val legacyStarlight: Boolean = false,
    ) {
        val length: Int get() = value.size
        val truncated: Boolean get() = !legacyStarlight && declaredLength != value.size
        fun typeHex(): String = "%02X".format(type)
        fun lengthHex(): String = "%02X".format(if (legacyStarlight) LEGACY_STARLIGHT_LENGTH else declaredLength)
        fun valueHex(): String = HexUtils.bytesToHex(value)
        /** `type + length` as four hex chars — what the old code called a "function code". */
        fun headHex(): String = typeHex() + lengthHex()
        fun isChannelMarker(): Boolean = type in TYPE_CHANNEL_1..TYPE_CHANNEL_3 && length == 0
        /** Unsigned value byte, or null when the body is shorter than that. */
        fun byte(i: Int): Int? = value.getOrNull(i)?.let { it.toInt() and 0xFF }
    }

    /**
     * [records] are the records that parsed cleanly, in order. [malformed] is null when the
     * chain consumed the payload exactly; otherwise it says what went wrong at the end
     * (overrun or a dangling type byte). A packet can be useful even when malformed — the
     * records before the break are still real.
     */
    class Parsed(val hex: String, val records: List<Record>, val malformed: String?) {
        val exact: Boolean get() = malformed == null
        fun first(type: Int): Record? = records.firstOrNull { it.type == type }
        fun has(type: Int): Boolean = records.any { it.type == type }
        val effect: Record? get() = first(TYPE_EFFECT)
        val channel: Record? get() = records.firstOrNull { it.isChannelMarker() }
    }

    /** Parse canonical or raw hex. Returns null if this isn't a Disney manufacturer payload at all. */
    fun parse(hexRaw: String): Parsed? {
        val hex = HexUtils.canonicalHex(hexRaw)
        if (!hex.startsWith(COMPANY_PREFIX) || hex.length < 4 || hex.length % 2 != 0) return null
        val bytes = HexUtils.hexToBytes(hex)
        val records = ArrayList<Record>(4)
        var i = 2
        var malformed: String? = null
        while (i < bytes.size) {
            if (i + 1 >= bytes.size) {
                malformed = "trailing byte %02X with no length".format(bytes[i].toInt() and 0xFF)
                break
            }
            val type = bytes[i].toInt() and 0xFF
            val len = bytes[i + 1].toInt() and 0xFF
            val start = i + 2
            if (type == TYPE_WAND && len == LEGACY_STARLIGHT_LENGTH) {
                records += Record(type, bytes.copyOfRange(start, bytes.size), legacyStarlight = true)
                break
            }
            if (start + len > bytes.size) {
                val remain = bytes.size - start
                malformed = "record %02X declares %d bytes but only %d remain".format(type, len, remain)
                // Keep a cut-short final record (if it has any body at all) so a truncated packet
                // still classifies by its declared shape, as the old substring code allowed.
                if (remain > 0) records += Record(type, bytes.copyOfRange(start, bytes.size), declaredLength = len)
                break
            }
            records += Record(type, bytes.copyOfRange(start, start + len))
            i = start + len
        }
        return Parsed(hex, records, malformed)
    }

    // ---------------------------------------------------------------------------------------------
    // Anatomy — the packet explained segment by segment, for the Lab. This is the "what am I
    // actually building" view: every byte group gets a caption a person can read.
    // ---------------------------------------------------------------------------------------------

    enum class SegmentKind { COMPANY, CHANNEL, PING, EFFECT_HEAD, HEADER, COLOR, DATA, TAIL, WAND, BEACON, OTHER, ERROR }

    class Segment(val hex: String, val title: String, val detail: String, val kind: SegmentKind)

    fun anatomy(hexRaw: String): List<Segment> {
        val parsed = parse(hexRaw) ?: return listOf(
            Segment(HexUtils.canonicalHex(hexRaw), "Not a Disney packet", "Must start with the 8301 company ID.", SegmentKind.ERROR),
        )
        val out = ArrayList<Segment>()
        out += Segment("8301", "Disney", "Company ID 0x0183. Every receiver checks this first.", SegmentKind.COMPANY)
        parsed.records.forEach { r -> out += describeRecord(r) }
        parsed.malformed?.let { out += Segment("", "Malformed", it, SegmentKind.ERROR) }
        return out
    }

    private fun describeRecord(r: Record): List<Segment> {
        val head = r.headHex()
        return when {
            r.isChannelMarker() -> listOf(
                Segment(
                    head, "Channel ${r.type - TYPE_CHANNEL_1 + 1}",
                    "Zero-length marker. Every effect in the park capture carries one of these before its effect record.",
                    SegmentKind.CHANNEL,
                ),
            )
            r.type == TYPE_PING -> listOf(
                Segment(
                    head + r.valueHex(), pingName(r.valueHex()),
                    "Interaction ping. 000100 is the wake ping that makes nearby bands listen for the next command.",
                    SegmentKind.PING,
                ),
            )
            r.type == TYPE_EFFECT -> describeEffect(r)
            r.type == TYPE_WAND && r.legacyStarlight -> listOf(
                Segment(
                    head + r.valueHex(), "Legacy Starlight code",
                    "Marker CF9B declares a 155-byte body, which cannot be right — the body is ${r.length} bytes, " +
                        "which is what CF0B declares. Last byte ${r.value.lastOrNull()?.let { "%02X".format(it.toInt() and 0xFF) } ?: "?"} is the colour.",
                    SegmentKind.WAND,
                ),
            )
            r.type == TYPE_WAND -> listOf(
                Segment(
                    head + r.valueHex(), "Wand code",
                    "Serial, then a colour byte. ${r.byte(r.length - 1)?.let { "Last byte %02X = %s.".format(it, StarlightColors.nameFor(it)) } ?: ""}",
                    SegmentKind.WAND,
                ),
            )
            r.type == TYPE_BAND_TELEMETRY || r.type == TYPE_BAND_ID -> listOf(
                Segment(head + r.valueHex(), "MagicBand telemetry", "Guest-band broadcast with a rolling payload. Never an effect.", SegmentKind.OTHER),
            )
            r.type in 0xE0..0xEF -> listOf(
                Segment(head + r.valueHex(), "Park beacon record ($head)", "Fixed infrastructure. Not decoded yet.", SegmentKind.BEACON),
            )
            else -> listOf(
                Segment(head + r.valueHex(), "Unknown record ($head)", "Type ${r.typeHex()}, ${r.length} bytes.", SegmentKind.OTHER),
            )
        }
    }

    private fun describeEffect(r: Record): List<Segment> {
        val out = ArrayList<Segment>()
        val name = effectName(r.declaredLength)
        out += Segment(
            r.headHex(), "Effect record",
            "$name — ${r.declaredLength}-byte body. The length is what picks the effect shape." +
                if (r.truncated) " Only ${r.length} bytes are present: this packet is cut short." else "",
            SegmentKind.EFFECT_HEAD,
        )
        if (r.length == 0) return out

        val v = r.value
        val hexOf = { from: Int, to: Int -> HexUtils.bytesToHex(v.copyOfRange(from, minOf(to, v.size))) }
        val colorSlots = colorSlotCount(r.declaredLength)
        val hasTail = (v.last().toInt() and 0xF0) == 0xB0

        if (colorSlots > 0 && v.size >= 3 + colorSlots) {
            out += Segment(hexOf(0, 3), "Header", headerCaption(v), SegmentKind.HEADER)
            for (s in 0 until colorSlots) {
                val b = v[3 + s].toInt() and 0xFF
                val idx = b and 0x1F
                val high = (b shr 5) and 0x07
                val flagNote = if (r.declaredLength == 0x05) {
                    when (high) { 0, 7 -> " Zone mask $high = all LEDs."; 3 -> " Zone mask 3 = bottom-left only."; 4 -> " Zone mask 4 = top-left only."; else -> " Zone mask $high (mapping disputed)." }
                } else " High bits are the slot flag."
                out += Segment(
                    "%02X".format(b), colorSlotTitle(r.declaredLength, s, colorSlots),
                    "Low 5 bits = palette #%02X %s.".format(idx, StarlightColors.nameFor(idx)) + flagNote,
                    SegmentKind.COLOR,
                )
            }
            val rest = 3 + colorSlots
            val dataEnd = if (hasTail) v.size - 1 else v.size
            if (dataEnd > rest) out += Segment(hexOf(rest, dataEnd), "Data", "Timing / curve bytes for this effect.", SegmentKind.DATA)
        } else {
            if (v.size >= 3) out += Segment(hexOf(0, 3), "Header", headerCaption(v), SegmentKind.HEADER)
            val dataEnd = if (hasTail) v.size - 1 else v.size
            if (dataEnd > 3) out += Segment(hexOf(3, dataEnd), "Data", "Body of an effect we do not decode field-by-field yet.", SegmentKind.DATA)
        }
        if (hasTail) {
            val vib = v.last().toInt() and 0x0F
            out += Segment(
                "%02X".format(v.last().toInt() and 0xFF), if (vib == 0) "Tail · no buzz" else "Tail · buzz $vib",
                "B0 | vibration pattern (0–15). Only meaningful on the esp32_magicband shapes; two real park effects end in 01 instead.",
                SegmentKind.TAIL,
            )
        }
        return out
    }

    /** Body byte 1 is timing: bits 0-3 count, bit 6 ×3.1 s else ×1.5 s, bits 4-5 fade s, bit 7 always-on. */
    fun timingCaption(b: Int): String {
        if ((b shr 7) and 1 == 1) return "always on"
        val secs = (b and 0x0F) * if ((b shr 6) and 1 == 1) 3.1f else 1.5f
        val fade = (b shr 4) and 0x03
        return "on for ~${"%.0f".format(secs)} s" + if (fade > 0) ", ${fade} s fade-out" else ""
    }

    private fun headerCaption(v: ByteArray): String {
        val t = v.getOrNull(1)?.toInt()?.and(0xFF)
        return "Sub-code, then timing byte" + (t?.let { " (${timingCaption(it)})" } ?: "") + ", then flags."
    }

    fun pingName(valueHex: String): String = when (valueHex) {
        "000000" -> "Signal Beacon"
        "000100" -> "Wake Ping"
        "234100" -> "Show Ping (2341)"
        "203000" -> "Show Ping (2030)"
        else -> "Interaction Ping"
    }

    /** Human name for an E9 record by body length — the shape the length implies. */
    fun effectName(length: Int): String = when (length) {
        0x05 -> "Single colour"
        0x06 -> "Dual colour"
        0x09 -> "5-zone colours"
        0x0B -> "Circle spin"
        0x0C -> "Complex animation"
        0x08 -> "Custom RGB colour"
        0x0E -> "Per-zone twinkle / flash"
        0x0F -> "Candle flicker / centre pulse"
        0x10 -> "Comet"
        0x11 -> "Two-colour fade / pulse burst"
        0x12 -> "Rotating colours"
        0x13 -> "Corner-pair alternate"
        0x14 -> "Repeating fade"
        else -> "Show control (E9%02X)".format(length)
    }

    /** How many palette colour bytes sit at value[3..] for a given body length (0 = not field-decodable). */
    fun colorSlotCount(length: Int): Int = when (length) {
        0x05 -> 1
        0x06 -> 2
        0x09 -> 5
        0x0B -> 7
        0x0C -> 2
        0x0E -> 5
        0x0F -> 2
        0x11 -> 2
        0x12 -> 5
        0x13 -> 3
        else -> 0
    }

    private fun colorSlotTitle(length: Int, slot: Int, slots: Int): String = when (length) {
        0x11 -> if (slot == 0) "Fade from" else "Fade to"
        0x0B -> "Pattern ${slot + 1}"
        0x06, 0x0F -> if (slot == 0) "Centre colour" else "Corner colour"
        0x0E -> "Zone ${slot + 1}"
        0x12 -> "Zone ${listOf(2, 3, 4, 5, 1)[slot]}"
        0x13 -> listOf("Centre", "Pair B", "Pair A")[slot]
        else -> if (slots == 1) "Colour" else "Colour ${slot + 1}"
    }
}
