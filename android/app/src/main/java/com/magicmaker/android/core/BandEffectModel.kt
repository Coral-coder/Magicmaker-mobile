package com.magicmaker.android.core

/**
 * What we expect a packet to do on a MagicBand+, derived from the bytes themselves via
 * [DisneyTlv]. Drives the Lab's band preview on both platforms (mirrored in Swift).
 *
 * The band has five LEDs — one at each corner of its square face and one in the centre. Zones
 * follow the numbering the public ESP32 listener uses (docs/PROTOCOL.md §6a):
 *
 *   Z1 bottom-left · Z2 top-left · Z3 centre · Z4 top-right · Z5 bottom-right
 *
 * [perLed] is the resting colour of each zone (index 0 = Z1 … 4 = Z5), null = off. [kind]
 * says how they move. Colours are read from the documented colour bytes and are exact; motion
 * and the LED order of some shapes are reproduced from other people's decoders and marked
 * [approximate]. Anything with no basis is [Kind.NONE] with a [note] — never an invented effect.
 */
data class BandEffectModel(
    val kind: Kind,
    /** 5-bit palette indexes in packet slot order (what the builder edits). */
    val colors: List<Int>,
    /** Resting colour per zone Z1..Z5, null = off. */
    val perLed: List<Int?>,
    /** Vibration/tail byte low nibble — the tail byte's meaning is disputed, see PROTOCOL.md. */
    val buzz: Int,
    /** Duration in ms from the timing byte, 0 = unknown; [alwaysOn] when bit 7 is set. */
    val durationMs: Int,
    val fadeMs: Int,
    val alwaysOn: Boolean,
    val approximate: Boolean,
    val note: String,
) {
    enum class Kind {
        NONE, SINGLE, DUAL, RAINBOW, CROSSFADE, PULSE_BURST, CIRCLE, ROTATE, TOGGLE, TWINKLE,
        ALTERNATE, REPEAT_FADE, LIGHTNING, STROBE, STEPPER, COMPLEX, PING, WAND, RGB,
        FLICKER, CENTRE_PULSE, COMET,
    }

    companion object {
        private val OFF = listOf<Int?>(null, null, null, null, null)
        val EMPTY = BandEffectModel(Kind.NONE, emptyList(), OFF, 0, 0, 0, false, false, "No packet")

        private fun all(c: Int?): List<Int?> = listOf(c, c, c, c, c)
        /** Centre (Z3) one colour, the four corners another. */
        private fun centreCorners(centre: Int?, corners: Int?): List<Int?> = listOf(corners, corners, centre, corners, corners)

        /** Body byte 1: bits 0-3 count, bit 6 ×3.1 s else ×1.5 s, bits 4-5 fade seconds, bit 7 always-on. */
        private data class Timing(val durationMs: Int, val fadeMs: Int, val alwaysOn: Boolean)
        private fun timing(b: Int?): Timing {
            if (b == null) return Timing(0, 0, false)
            val count = b and 0x0F
            val secs = count * if ((b shr 6) and 1 == 1) 3.1f else 1.5f
            return Timing((secs * 1000).toInt(), ((b shr 4) and 0x03) * 1000, (b shr 7) and 1 == 1)
        }

        fun from(hexRaw: String): BandEffectModel {
            val hex = HexUtils.canonicalHex(hexRaw)
            if (hex.length < 8) return EMPTY
            val parsed = DisneyTlv.parse(hex) ?: return EMPTY
            val first = parsed.records.firstOrNull() ?: return EMPTY
            val e = parsed.effect

            if (e == null) {
                if (first.type == DisneyTlv.TYPE_WAND) {
                    val c = first.byte(first.length - 1)?.and(0x1F) ?: return EMPTY
                    return BandEffectModel(Kind.WAND, listOf(c), all(c), 0, 0, 0, false, false, "Wand colour")
                }
                if (first.type == DisneyTlv.TYPE_PING) return BandEffectModel(Kind.PING, emptyList(), OFF, 0, 0, 0, false, false, "Wake ping — no light")
                return BandEffectModel(Kind.NONE, emptyList(), OFF, 0, 0, 0, false, false, "No band effect known for this packet")
            }

            val tail = e.value.lastOrNull()?.toInt()?.and(0xFF) ?: 0
            val buzz = if ((tail and 0xF0) == 0xB0) tail and 0x0F else 0
            val t = timing(e.byte(1))
            fun pal(i: Int): Int? = e.byte(i)?.and(0x1F)
            fun palette(n: Int): List<Int> = (0 until n).mapNotNull { pal(3 + it) }
            val body = e.valueHex()
            fun model(kind: Kind, colors: List<Int>, perLed: List<Int?>, approx: Boolean, note: String) =
                BandEffectModel(kind, colors, perLed, buzz, t.durationMs, t.fadeMs, t.alwaysOn, approx, note)

            return when (e.declaredLength) {
                0x05 -> {
                    val c = pal(3)
                    // High 3 bits of the colour byte are a zone mask. Both public decoders agree on
                    // 0 = all, 3 = bottom-left, 4 = top-left; they disagree on 1 and 2.
                    val mask = (e.byte(3) ?: 0xE0) shr 5
                    val leds: List<Int?> = when (mask) {
                        0, 5, 7 -> all(c)
                        3 -> listOf(c, null, null, null, null)
                        4 -> listOf(null, c, null, null, null)
                        1, 6 -> listOf(null, null, c, null, null)
                        2 -> listOf(null, null, null, c, null)
                        else -> all(c)
                    }
                    model(Kind.SINGLE, listOfNotNull(c), leds, mask !in listOf(0, 7), if (mask in listOf(0, 7)) "Solid colour, all LEDs" else "Solid colour, zone mask $mask (mapping disputed)")
                }
                0x06 -> model(Kind.DUAL, palette(2), centreCorners(pal(3), pal(4)), false, "Centre / corners")
                0x08 -> model(Kind.RGB, emptyList(), OFF, true, "Custom RGB (6-bit per channel) — colour shown approximately")
                0x09 -> model(Kind.RAINBOW, palette(5), (0 until 5).map { pal(3 + it) }, true, "Five zone colours — slot→LED order disputed")
                0x0B -> model(Kind.CIRCLE, palette(7), all(0x19), true, "Chase round the corners (\"green double comet\"); no public decoder reads colours from this body")
                0x0C -> when {
                    body.contains("5D465B") && tail == 0x95 -> model(Kind.LIGHTNING, listOf(0x1B), all(0x1B), true, "White flash / fade")
                    body.contains("5D465B") -> model(Kind.RAINBOW, listOf(0x15, 0x0F, 0x19, 0x02, 0x01), listOf(0x15, 0x0F, 0x19, 0x02, 0x01), true, "Rainbow hue cycle")
                    body.contains("4F4F5B") -> model(Kind.STROBE, listOf(0x11, 0x13), all(0x11), true, "Yellow/orange strobe")
                    body.contains("B1B9B5") -> model(Kind.STEPPER, listOf(0x15, 0x19, 0x11, 0x02), all(0x15), true, "Random palette stepper")
                    // Unnamed E90C: body[3], body[4] are still colour bytes; the motion is not decoded.
                    (e.byte(3) ?: 0) shr 5 == 2 -> {
                        val a = pal(3); val b = pal(4)
                        model(Kind.COMPLEX, listOfNotNull(a, b), centreCorners(a, b), true, "Two-colour animation — motion not decoded")
                    }
                    else -> model(Kind.COMPLEX, emptyList(), OFF, true, "Complex animation — bytes undecoded")
                }
                0x0E -> model(Kind.TWINKLE, palette(5), (0 until 5).map { pal(3 + it) }, true, "Per-zone twinkle / flash")
                0x0F -> {
                    val centre = pal(3); val corners = pal(4)
                    when (e.byte(11)) {
                        0x2A -> model(Kind.FLICKER, listOfNotNull(centre, corners), centreCorners(centre, corners), true, "Candle flicker: centre / corners")
                        0x02 -> model(Kind.CENTRE_PULSE, listOfNotNull(centre, corners), centreCorners(centre, corners), true, "Centre pulses, corners steady")
                        else -> model(Kind.COMPLEX, listOfNotNull(centre, corners), centreCorners(centre, corners), true, "E90F variant — mode not decoded")
                    }
                }
                0x10 -> {
                    val c = pal(6)
                    model(Kind.COMET, listOfNotNull(c), all(c), true, "Comet chase round the corners")
                }
                0x11 -> if (body.contains("F44882")) {
                    model(Kind.CROSSFADE, palette(2), centreCorners(pal(4), pal(3)), true, "Two-colour fade, centre out of phase")
                } else {
                    model(Kind.PULSE_BURST, palette(2), centreCorners(pal(3), pal(4)), true, "Pulse burst: centre / corners")
                }
                0x12 -> {
                    // Colour bytes are in zone order Z2, Z3, Z4, Z5, Z1.
                    val raw = (0 until 5).map { pal(3 + it) }
                    val leds = listOf(raw[4], raw[0], raw[1], raw[2], raw[3])
                    val rotate = e.byte(2) == 0x0F
                    model(if (rotate) Kind.ROTATE else Kind.TOGGLE, palette(5), leds, true, if (rotate) "Colours rotate around the band" else "Two-colour toggle")
                }
                0x13 -> model(Kind.ALTERNATE, palette(3), listOf(pal(5), pal(4), pal(3), pal(5), pal(4)), true, "Corner pairs alternate, centre steady")
                0x14 -> {
                    val c = pal(8)
                    model(Kind.REPEAT_FADE, listOfNotNull(c), all(c), true, "Repeating fade, all LEDs")
                }
                else -> model(Kind.NONE, emptyList(), OFF, false, "Show control — no band effect known")
            }
        }
    }
}
