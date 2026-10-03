package com.magicmaker.android.core

/**
 * What we expect a packet to do on a MagicBand+, derived from the bytes themselves via
 * [DisneyTlv]. This drives the Lab's band preview on both platforms (mirrored in Swift).
 *
 * Honesty rule: [colors] are always exact — they are read from the colour bytes the protocol
 * documents. Motion ([kind]) is exact where the shape implies it (a single colour is a single
 * colour) and a best guess where the timing bytes are undecoded; [approximate] says which.
 * Anything we have no basis to render comes back as [Kind.NONE] with a [note], and the preview
 * shows that rather than inventing an effect.
 */
data class BandEffectModel(
    val kind: Kind,
    /** 5-bit palette indexes, in slot order. */
    val colors: List<Int>,
    /** Vibration pattern 0–15 from the B0|vib tail, 0 when none. */
    val buzz: Int,
    val approximate: Boolean,
    val note: String,
) {
    enum class Kind { NONE, SINGLE, DUAL, RAINBOW, CROSSFADE, CIRCLE, LIGHTNING, SPARKLE, STROBE, COMPLEX, PING, WAND }

    companion object {
        val EMPTY = BandEffectModel(Kind.NONE, emptyList(), 0, false, "No packet")

        fun from(hexRaw: String): BandEffectModel {
            val hex = HexUtils.canonicalHex(hexRaw)
            if (hex.length < 8) return EMPTY
            val parsed = DisneyTlv.parse(hex) ?: return EMPTY
            val first = parsed.records.firstOrNull() ?: return EMPTY
            val e = parsed.effect

            if (e == null) {
                if (first.type == DisneyTlv.TYPE_WAND) {
                    val c = first.byte(first.length - 1)?.and(0x1F) ?: return EMPTY
                    return BandEffectModel(Kind.WAND, listOf(c), 0, false, "Wand colour")
                }
                if (first.type == DisneyTlv.TYPE_PING) return BandEffectModel(Kind.PING, emptyList(), 0, false, "Wake ping — no light")
                return BandEffectModel(Kind.NONE, emptyList(), 0, false, "No band effect known for this packet")
            }

            val tail = e.value.lastOrNull()?.toInt()?.and(0xFF) ?: 0
            val buzz = if ((tail and 0xF0) == 0xB0) tail and 0x0F else 0
            fun palette(n: Int): List<Int> = (0 until n).mapNotNull { e.byte(3 + it)?.and(0x1F) }
            val body = e.valueHex()

            return when (e.declaredLength) {
                0x05 -> BandEffectModel(Kind.SINGLE, palette(1), buzz, false, "Solid colour")
                0x06 -> BandEffectModel(Kind.DUAL, palette(2), buzz, false, "Inner / outer")
                0x09 -> BandEffectModel(Kind.RAINBOW, palette(5), buzz, false, "Five LED colours")
                0x0B -> BandEffectModel(Kind.CIRCLE, palette(7), buzz, true, "Rotation speed/direction approximate")
                0x11 -> if (body.contains("55515BF00F10374894D13D0508")) {
                    BandEffectModel(Kind.COMPLEX, emptyList(), buzz, true, "Pirate Cannon — motion approximate")
                } else {
                    BandEffectModel(Kind.CROSSFADE, palette(2), buzz, true, "Fade timing approximate")
                }
                0x0C -> when {
                    body.contains("5D465BF00532374895") -> BandEffectModel(Kind.LIGHTNING, listOf(0x1B), buzz, true, "Lightning — motion approximate")
                    body.contains("5D465BF005323748B0") -> BandEffectModel(Kind.RAINBOW, listOf(0x15, 0x0F, 0x19, 0x02, 0x01), buzz, true, "Rainbow cycle — approximate")
                    body.contains("B1B9B5B1A2307B7DB0") -> BandEffectModel(Kind.RAINBOW, listOf(0x11, 0x19, 0x15, 0x11, 0x02), buzz, true, "5-colour cycle — approximate")
                    else -> BandEffectModel(Kind.COMPLEX, emptyList(), buzz, true, "Complex animation — bytes undecoded")
                }
                0x0F -> if (body.contains("0219021902") || body.contains("1B151B15")) {
                    BandEffectModel(Kind.SPARKLE, listOf(0x19, 0x02), buzz, true, "Sparkle — motion approximate")
                } else {
                    BandEffectModel(Kind.STROBE, listOf(0x14, 0x14), buzz, true, "Alternating strobe — approximate")
                }
                else -> BandEffectModel(Kind.NONE, emptyList(), buzz, false, "Show control — no band effect known")
            }
        }
    }
}
