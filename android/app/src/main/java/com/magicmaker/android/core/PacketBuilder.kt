package com.magicmaker.android.core

/**
 * Disney MagicBand+ packet builders — ported from
 * [esp32_magicband](https://github.com/xxfunprojectsxx/esp32_magicband/blob/main/src/main.cpp).
 *
 * Tail byte: `0xB0 | (vibration and 0x0F)`.
 */
object PacketBuilder {

    object Color {
        const val CYAN = 0x00
        const val PURPLE = 0x01
        const val BLUE = 0x02
        const val MIDNIGHT_BLUE = 0x03
        const val BRIGHT_PURPLE = 0x05
        const val LAVENDER = 0x06
        const val PINK = 0x08
        const val YELLOW_ORANGE = 0x0F
        const val LIME = 0x12
        const val ORANGE = 0x13
        const val RED = 0x15
        const val GREEN = 0x19
        const val WHITE = 0x1B
        const val OFF = 0x1D
        const val RANDOM = 0x1F
    }

    /** esp32 frontend vibration patterns (0–15). */
    object Vibration {
        const val OFF = 0
        const val SHORT = 1
        const val DOUBLE = 2
        const val TRIPLE = 3
        const val BURST = 5
        const val LONG = 8
    }

    const val WAKEUP_PING = "8301CC03000100"

    private fun pkt(vararg bytes: Int): String =
        HexUtils.bytesToHex(bytes.map { it.and(0xFF).toByte() }.toByteArray())

    private fun tail(vib: Int) = 0xB0 or (vib and 0x0F)

    /** action=preset — single band color + optional vibration. */
    fun preset(color: Int, vib: Int = Vibration.OFF): String = pkt(
        0x83, 0x01, 0xE9, 0x05, 0x00, 0x2E, 0x0E,
        0xE0 or (color and 0x1F),
        tail(vib),
    )

    /** Primary vibrate: white + burst vibration (esp32 preset + vib=5). */
    fun vibrateBand(vib: Int = Vibration.BURST): String = preset(Color.WHITE, vib)

    /** action=dual */
    fun dual(c1: Int, c2: Int, vib: Int = Vibration.OFF): String = pkt(
        0x83, 0x01, 0xE9, 0x06, 0x00, 0x22, 0x0F,
        0x80 or (c1 and 0x1F),
        0x80 or (c2 and 0x1F),
        tail(vib),
    )

    /** action=rainbow — 5-LED palette (E909). */
    fun rainbow5(
        c1: Int = Color.YELLOW_ORANGE,
        c2: Int = Color.RED,
        c3: Int = Color.GREEN,
        c4: Int = Color.BLUE,
        c5: Int = Color.PURPLE,
        vib: Int = Vibration.OFF,
    ): String = pkt(
        0x83, 0x01, 0xE9, 0x09, 0x00, 0x2E, 0x0F,
        0xA0 or (c1 and 0x1F),
        0xA0 or (c2 and 0x1F),
        0xA0 or (c3 and 0x1F),
        0xA0 or (c4 and 0x1F),
        0xA0 or (c5 and 0x1F),
        tail(vib),
    )

    /**
     * The seven pattern bytes of the circle body. Each decodes like every other colour byte in
     * the protocol — low 5 bits a palette index, high bits a slot flag: 5C White, 5D Off, 48 Pink,
     * A5 Bright Purple, D1 Yellow Orange, 45 Bright Purple, 32 Lime. Figment's rotating dual-colour
     * effect classifies as this same shape, so the colours are editable, flags preserved.
     */
    val CIRCLE_PATTERN = intArrayOf(0x5C, 0x5D, 0x48, 0xA5, 0xD1, 0x45, 0x32)

    /** action=circle — rotating ring (E90B), default pattern colours. */
    fun circle(vib: Int = Vibration.OFF): String = circle(emptyList(), vib)

    /** Circle with the pattern bytes' palette indexes replaced; each byte keeps its own flag bits. */
    fun circle(colors: List<Int>, vib: Int): String {
        val pattern = CIRCLE_PATTERN.mapIndexed { i, b ->
            colors.getOrNull(i)?.let { (b and 0xE0) or (it and 0x1F) } ?: b
        }
        return pkt(0x83, 0x01, 0xE9, 0x0B, 0x0B, 0x0F, 0x0F, *pattern.toIntArray(), tail(vib))
    }

    /** action=crossfade */
    fun crossfade(
        c1: Int = Color.RED,
        c2: Int = Color.BLUE,
        vib: Int = Vibration.OFF,
    ): String = pkt(
        0x83, 0x01, 0xE1, 0x00, 0xE9, 0x11, 0x00, 0x6F, 0x0F,
        0x40 or (c1 and 0x1F),
        0x40 or (c2 and 0x1F),
        0x58, 0xF4, 0x48, 0x82, 0xD1, 0x46, 0x02, 0x08, 0xD0, 0x65, 0x00,
        tail(vib),
    )

    /**
     * E912 "rotating colours": five per-zone colours (in zone order Z2, Z3, Z4, Z5, Z1) that
     * the band rotates around its face. Template is the captured variant the Flipper app ships
     * (`E2 00 E9 12 00 03 0F A2 A2 A4 A4 A2 30 D0 37 F4 D2 46 00 64 FC B0`); flag byte 0F selects
     * rotate rather than two-colour toggle. Colours are given here in Z1..Z5 order.
     */
    fun rotate(z1: Int, z2: Int, z3: Int, z4: Int, z5: Int, vib: Int = Vibration.OFF): String = pkt(
        0x83, 0x01, 0xE1, 0x00, 0xE9, 0x12, 0x00, 0x03, 0x0F,
        0xA0 or (z2 and 0x1F), 0xA0 or (z3 and 0x1F), 0xA0 or (z4 and 0x1F), 0xA0 or (z5 and 0x1F), 0xA0 or (z1 and 0x1F),
        0x30, 0xD0, 0x37, 0xF4, 0xD2, 0x46, 0x00, 0x64, 0xFC,
        tail(vib),
    )

    /** Named values for the effect body's timing byte (body[1]). See docs/PROTOCOL.md §6a. */
    object Timing {
        const val DEFAULT = -1          // keep the template's own byte
        const val ALWAYS_ON = 0x8F
        const val S20 = 0x09
        const val S10 = 0x06
        const val S5 = 0x04
        const val S3 = 0x03
        val options: List<Pair<Int, String>> = listOf(
            DEFAULT to "Default", ALWAYS_ON to "Always on", S20 to "~20 s", S10 to "~10 s", S5 to "~5 s", S3 to "~3 s",
        )
    }

    /** Replace the timing byte (body[1]) of the first E9 record in [hex]. No-op for [Timing.DEFAULT]. */
    fun withTiming(hex: String, timing: Int): String {
        if (timing == Timing.DEFAULT) return hex
        val parsed = DisneyTlv.parse(hex) ?: return hex
        val e = parsed.effect ?: return hex
        if (e.length < 2) return hex
        // Locate the record in the hex: "E9" + length byte, then body.
        val head = "E9" + "%02X".format(e.declaredLength)
        val idx = HexUtils.canonicalHex(hex).indexOf(head)
        if (idx < 0) return hex
        val h = HexUtils.canonicalHex(hex)
        val pos = idx + 4 + 2          // after head (4 chars) + body[0] (2 chars)
        return h.substring(0, pos) + "%02X".format(timing and 0xFF) + h.substring(pos + 2)
    }

    /**
     * E908 custom RGB — six bits per channel (0-63), each stored shifted left one bit. From the
     * Flipper app's builder; no captured example exists yet, so this is experimental.
     */
    fun rgb(r6: Int, g6: Int, b6: Int, vib: Int = Vibration.OFF): String = pkt(
        0x83, 0x01, 0xE1, 0x00, 0xE9, 0x08, 0x00, 0x0E, 0xD2, 0x55,
        (r6 and 0x3F) shl 1, (g6 and 0x3F) shl 1, (b6 and 0x3F) shl 1,
        tail(vib),
    )

    /** Set the zone mask (high 3 bits of the single-colour byte) on an E905 packet. */
    fun withZoneMask(hex: String, mask: Int): String {
        val h = HexUtils.canonicalHex(hex)
        val i = h.indexOf("E905")
        if (i < 0 || i + 12 > h.length) return h
        val pos = i + 4 + 6                      // body[3]
        val old = h.substring(pos, pos + 2).toIntOrNull(16) ?: return h
        return h.substring(0, pos) + "%02X".format(((mask and 7) shl 5) or (old and 0x1F)) + h.substring(pos + 2)
    }

    /** Park-captured rainbow finale (CC03 wrapper) — strong haptic show packet. */
    fun rainbowFinale(): String =
        "8301CC03000100E100E90C000F0F5D465BF005323748B0"

    fun colorFromName(name: String): Int {
        val raw = name.trim()
        if (raw.startsWith("#")) {
            return raw.removePrefix("#").toIntOrNull(16)?.and(0x1F) ?: Color.WHITE
        }
        val hexOnly = raw.replace(" ", "").uppercase()
        if (hexOnly.length == 2) {
            hexOnly.toIntOrNull(16)?.let { return it and 0x1F }
        }
        return when (raw.lowercase().replace("-", " ").replace("_", " ")) {
            "red" -> Color.RED
            "blue" -> Color.BLUE
            "cyan" -> Color.CYAN
            "green" -> Color.GREEN
            "purple" -> Color.PURPLE
            "bright purple", "br purple", "brightpurple" -> Color.BRIGHT_PURPLE
            "midnight blue", "mid blue", "midnightblue" -> Color.MIDNIGHT_BLUE
            "lavender" -> Color.LAVENDER
            "pink" -> Color.PINK
            "white" -> Color.WHITE
            "orange" -> Color.ORANGE
            "yellow orange", "y orange", "yellow-orange", "yelloworange" -> Color.YELLOW_ORANGE
            "lime" -> Color.LIME
            "off" -> Color.OFF
            "random" -> Color.RANDOM
            "red orange", "red-orange" -> Color.ORANGE
            else -> {
                StarlightColors.palette.entries
                    .firstOrNull { it.value.equals(raw, ignoreCase = true) }
                    ?.key
                    ?: Color.WHITE
            }
        }
    }

    /** esp32 POST /command — for iPhone HTTP relay compatibility. */
    fun fromCommand(action: String, params: Map<String, String>): String? {
        val vib = params["vib"]?.toIntOrNull()?.coerceIn(0, 15) ?: Vibration.OFF
        return when (action.lowercase()) {
            "ping" -> WAKEUP_PING
            "preset" -> preset(colorFromName(params["color"] ?: "white"), vib)
            "dual" -> dual(
                params["c1"]?.toIntOrNull() ?: Color.YELLOW_ORANGE,
                params["c2"]?.toIntOrNull() ?: Color.BLUE,
                vib,
            )
            "rainbow" -> rainbow5(
                params["c1"]?.toIntOrNull() ?: Color.YELLOW_ORANGE,
                params["c2"]?.toIntOrNull() ?: Color.RED,
                params["c3"]?.toIntOrNull() ?: Color.GREEN,
                params["c4"]?.toIntOrNull() ?: Color.BLUE,
                params["c5"]?.toIntOrNull() ?: Color.PURPLE,
                vib,
            )
            "circle" -> circle(vib)
            "crossfade" -> crossfade(
                params["c1"]?.toIntOrNull() ?: Color.RED,
                params["c2"]?.toIntOrNull() ?: Color.BLUE,
                vib,
            )
            else -> null
        }
    }
}
