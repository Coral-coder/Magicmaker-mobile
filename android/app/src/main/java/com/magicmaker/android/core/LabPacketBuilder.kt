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
}
