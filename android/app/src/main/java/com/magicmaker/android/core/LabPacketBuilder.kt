package com.magicmaker.android.core

/** esp32_magicband frontend — build Disney payloads from Lab controls. */
object LabPacketBuilder {

    data class PaletteColor(val label: String, val id: Int)

    /** Unique label for every 5-bit palette index (0x00–0x1F). */
    fun labLabel(index: Int): String {
        val i = index and 0x1F
        return "#${"%02X".format(i)} ${StarlightColors.nameFor(i)}"
    }

    /** Full EMCOT palette for dual / crossfade / rainbow dropdowns. */
    val paletteColors: List<PaletteColor> =
        StarlightColors.palette.keys.sorted().map { PaletteColor(labLabel(it), it) }

    /** Named primaries for quick preset chips (PacketBuilder.Color constants). */
    val primaryPresetColors: List<PaletteColor> = listOf(
        PaletteColor("Cyan", PacketBuilder.Color.CYAN),
        PaletteColor("Purple", PacketBuilder.Color.PURPLE),
        PaletteColor("Blue", PacketBuilder.Color.BLUE),
        PaletteColor("Mid Blue", PacketBuilder.Color.MIDNIGHT_BLUE),
        PaletteColor("Br Purple", PacketBuilder.Color.BRIGHT_PURPLE),
        PaletteColor("Lavender", PacketBuilder.Color.LAVENDER),
        PaletteColor("Pink", PacketBuilder.Color.PINK),
        PaletteColor("Y-Orange", PacketBuilder.Color.YELLOW_ORANGE),
        PaletteColor("Lime", PacketBuilder.Color.LIME),
        PaletteColor("Orange", PacketBuilder.Color.ORANGE),
        PaletteColor("Red", PacketBuilder.Color.RED),
        PaletteColor("Green", PacketBuilder.Color.GREEN),
        PaletteColor("White", PacketBuilder.Color.WHITE),
        PaletteColor("Off", PacketBuilder.Color.OFF),
        PaletteColor("Random", PacketBuilder.Color.RANDOM),
    )

    val showEffects: List<Pair<String, String>> = listOf(
        "Lightning" to "8301CC03000100E100E90C000F0F5D465BF00532374895",
        "Rainbow FX" to PacketBuilder.rainbowFinale(),
        "Ambient Blue" to "8301CC03000100E100E90500090E02B0",
        "Ambient Lavender" to "8301CC03000100E100E90500090E06B0",
        "Ambient Cyan" to "8301CC03000100E100E90500090E00B0",
        "Alt Strobe" to "8301CC03000100E100E90F00110EF17AEC5C012814281448ABB0",
        "Slow Sparkle" to "8301E100E90F00520EF17AEC5C021902190248ABB0",
        "Fast Sparkle" to "8301E100E90F00520EF17AEC5C021B151B1548ABB0",
        "Pirate Cannon" to "8301E100E9110003240F55515BF00F10374894D13D0508B0",
        "Show Off" to "8301CC03000100E100E90500090E1DB0",
    )

    data class VibrationPattern(val label: String, val id: Int)

    val vibrationPatterns: List<VibrationPattern> = listOf(
        VibrationPattern("Off", 0),
        VibrationPattern("Short", 1),
        VibrationPattern("Double", 2),
        VibrationPattern("Triple", 3),
        VibrationPattern("Quad", 4),
        VibrationPattern("Burst", 5),
        VibrationPattern("Pulse 6", 6),
        VibrationPattern("Pulse 7", 7),
        VibrationPattern("Long", 8),
        VibrationPattern("Pattern 9", 9),
        VibrationPattern("Pattern 10", 10),
        VibrationPattern("Pattern 11", 11),
        VibrationPattern("Pattern 12", 12),
        VibrationPattern("Pattern 13", 13),
        VibrationPattern("Pattern 14", 14),
        VibrationPattern("Pattern 15", 15),
    )

    fun vib(vibEnabled: Boolean, vibPattern: Int): Int =
        if (vibEnabled) vibPattern.coerceIn(0, 15) else PacketBuilder.Vibration.OFF

    fun buildPreset(colorName: String, vibEnabled: Boolean, vibPattern: Int): String =
        PacketBuilder.preset(PacketBuilder.colorFromName(colorName), vib(vibEnabled, vibPattern))

    fun buildPresetById(colorId: Int, vibEnabled: Boolean, vibPattern: Int): String =
        PacketBuilder.preset(colorId and 0x1F, vib(vibEnabled, vibPattern))

    fun buildDual(c1: Int, c2: Int, vibEnabled: Boolean, vibPattern: Int): String =
        PacketBuilder.dual(c1, c2, vib(vibEnabled, vibPattern))

    fun buildCrossfade(c1: Int, c2: Int, vibEnabled: Boolean, vibPattern: Int): String =
        PacketBuilder.crossfade(c1, c2, vib(vibEnabled, vibPattern))

    fun buildRainbow(c1: Int, c2: Int, c3: Int, c4: Int, c5: Int, vibEnabled: Boolean, vibPattern: Int): String =
        PacketBuilder.rainbow5(c1, c2, c3, c4, c5, vib(vibEnabled, vibPattern))

    fun buildCircle(vibEnabled: Boolean, vibPattern: Int): String =
        PacketBuilder.circle(vib(vibEnabled, vibPattern))

    fun buildPing(): String = PacketBuilder.WAKEUP_PING

    fun buildRainbowFinale(): String = PacketBuilder.rainbowFinale()

    fun buildVibrate(vibEnabled: Boolean, vibPattern: Int): String =
        PacketBuilder.vibrateBand(vib(vibEnabled, vibPattern))

    fun paletteLabel(id: Int): String =
        paletteColors.firstOrNull { it.id == (id and 0x1F) }?.label ?: labLabel(id)

    fun paletteId(label: String): Int =
        paletteColors.firstOrNull { it.label.equals(label, ignoreCase = true) }?.id
            ?: PacketBuilder.colorFromName(label)

    // ---------------------------------------------------------------------------------------------
    // Guided, type-first builder model. Pick a [LabPacketType] first, then fill only the fields that
    // type uses (color slots + vibration). [decode] does the reverse: load a received packet and
    // recover its type + color slots + vibration so the builder fields can be populated for editing.
    // ---------------------------------------------------------------------------------------------

    /**
     * A packet kind the guided builder can compose end-to-end. [colorSlots] is how many palette
     * colors the type carries (so the UI shows exactly that many dropdowns), [supportsVib] whether
     * the vibration controls apply.
     */
    enum class LabPacketType(
        val label: String,
        val blurb: String,
        val colorSlots: Int,
        val supportsVib: Boolean,
    ) {
        PRESET("Single Color", "One solid band color.", 1, true),
        DUAL("Dual Color", "Two colors — inner / outer ring.", 2, true),
        CROSSFADE("Crossfade", "Smooth fade from one color to another.", 2, true),
        RAINBOW("Rainbow / Custom", "Five LED colors — pick every one for your own animation.", 5, true),
        CIRCLE("Circle Spin", "Rotating ring animation.", 0, true),
        VIBRATE("Vibrate Only", "Haptic buzz, no color change.", 0, true),
        PING("Wake Ping", "Wakes nearby bands so they hear the next command.", 0, false),
        RAW("Raw Hex", "Type any payload by hand for total control.", 0, false),
    }

    /** Default color slots for a freshly selected type (sensible starting palette). */
    fun defaultColors(type: LabPacketType): List<Int> = when (type) {
        LabPacketType.PRESET -> listOf(PacketBuilder.Color.CYAN)
        LabPacketType.DUAL -> listOf(PacketBuilder.Color.YELLOW_ORANGE, PacketBuilder.Color.BLUE)
        LabPacketType.CROSSFADE -> listOf(PacketBuilder.Color.RED, PacketBuilder.Color.BLUE)
        LabPacketType.RAINBOW -> listOf(
            PacketBuilder.Color.YELLOW_ORANGE,
            PacketBuilder.Color.RED,
            PacketBuilder.Color.GREEN,
            PacketBuilder.Color.BLUE,
            PacketBuilder.Color.PURPLE,
        )
        else -> emptyList()
    }

    /** Compose the hex for a fully specified builder state. */
    fun build(
        type: LabPacketType,
        colors: List<Int>,
        vibEnabled: Boolean,
        vibPattern: Int,
        rawHex: String = "",
    ): String {
        fun c(i: Int, fallback: Int) = colors.getOrElse(i) { fallback }
        return when (type) {
            LabPacketType.PRESET -> buildPresetById(c(0, PacketBuilder.Color.CYAN), vibEnabled, vibPattern)
            LabPacketType.DUAL -> buildDual(
                c(0, PacketBuilder.Color.YELLOW_ORANGE), c(1, PacketBuilder.Color.BLUE), vibEnabled, vibPattern,
            )
            LabPacketType.CROSSFADE -> buildCrossfade(
                c(0, PacketBuilder.Color.RED), c(1, PacketBuilder.Color.BLUE), vibEnabled, vibPattern,
            )
            LabPacketType.RAINBOW -> buildRainbow(
                c(0, PacketBuilder.Color.YELLOW_ORANGE),
                c(1, PacketBuilder.Color.RED),
                c(2, PacketBuilder.Color.GREEN),
                c(3, PacketBuilder.Color.BLUE),
                c(4, PacketBuilder.Color.PURPLE),
                vibEnabled, vibPattern,
            )
            LabPacketType.CIRCLE -> buildCircle(vibEnabled, vibPattern)
            LabPacketType.VIBRATE -> buildVibrate(vibEnabled, vibPattern)
            LabPacketType.PING -> buildPing()
            LabPacketType.RAW -> HexUtils.canonicalHex(rawHex)
        }
    }

    /** Recovered builder state from a captured/loaded packet. */
    data class Decoded(
        val type: LabPacketType,
        val colors: List<Int>,
        val vibEnabled: Boolean,
        val vibPattern: Int,
        val rawHex: String,
    )

    /**
     * Parse a received packet back into editable builder fields. Field-decodes the color command
     * families (E905/E906/E909/E90B/E911); anything we can't safely take apart (complex animations,
     * unknown effect families) comes back as [LabPacketType.RAW] with the hex preserved so it can
     * still be tweaked byte-by-byte. Never throws.
     */
    fun decode(hexRaw: String): Decoded? {
        val h = HexUtils.canonicalHex(hexRaw)
        if (h.length < 4) return null

        val tailVib = LabPacketTools.tailVibration(h)
        val vibEnabled = tailVib != null && tailVib > 0
        val vibPattern = if (tailVib != null && tailVib > 0) tailVib else PacketBuilder.Vibration.TRIPLE

        fun raw() = Decoded(LabPacketType.RAW, emptyList(), vibEnabled, vibPattern, h)

        // Wake/show pings: 8301CC03… with no effect payload.
        if (h.startsWith("8301CC03") && !h.contains("E9")) {
            return Decoded(LabPacketType.PING, emptyList(), false, vibPattern, h)
        }

        val pos = h.indexOf("E9")
        if (pos < 0 || pos + 4 > h.length) return raw()

        // Color slots live at funcCode + 3 header bytes (pos+10), masked to the low 5 bits.
        fun colorsAt(n: Int): List<Int>? {
            val out = ArrayList<Int>(n)
            for (slot in 0 until n) {
                val s = pos + 10 + slot * 2
                if (s + 2 > h.length) return null
                out += (h.substring(s, s + 2).toIntOrNull(16) ?: return null) and 0x1F
            }
            return out
        }

        return when (h.substring(pos, pos + 4)) {
            "E905" -> colorsAt(1)?.let { Decoded(LabPacketType.PRESET, it, vibEnabled, vibPattern, h) } ?: raw()
            "E906" -> colorsAt(2)?.let { Decoded(LabPacketType.DUAL, it, vibEnabled, vibPattern, h) } ?: raw()
            "E909" -> colorsAt(5)?.let { Decoded(LabPacketType.RAINBOW, it, vibEnabled, vibPattern, h) } ?: raw()
            "E90B" -> Decoded(LabPacketType.CIRCLE, emptyList(), vibEnabled, vibPattern, h)
            "E911" -> if (h.contains("55515BF00F10374894D13D0508B0")) {
                raw() // Pirate Cannon show packet — not a plain crossfade.
            } else {
                colorsAt(2)?.let { Decoded(LabPacketType.CROSSFADE, it, vibEnabled, vibPattern, h) } ?: raw()
            }
            else -> raw()
        }
    }
}
