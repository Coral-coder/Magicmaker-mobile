package com.magicmaker.android.core

/** Built-in transmit presets (esp32_magicband + park captures). */
object PresetCatalog {

    data class Preset(val label: String, val hex: String, val kind: Kind) {
        enum class Kind { PING, VIBRATE, COLOR, EFFECT }
    }

    val all: List<Preset> = listOf(
        Preset("Ping (wakeup)", PacketBuilder.WAKEUP_PING, Preset.Kind.PING),
        Preset("Vibrate band", PacketBuilder.vibrateBand(), Preset.Kind.VIBRATE),
        Preset("Vibrate (rainbow FX)", PacketBuilder.rainbowFinale(), Preset.Kind.VIBRATE),
        Preset("Red", PacketBuilder.preset(PacketBuilder.Color.RED), Preset.Kind.COLOR),
        Preset("Blue", PacketBuilder.preset(PacketBuilder.Color.BLUE), Preset.Kind.COLOR),
        Preset("Cyan", PacketBuilder.preset(PacketBuilder.Color.CYAN), Preset.Kind.COLOR),
        Preset("Green", PacketBuilder.preset(PacketBuilder.Color.GREEN), Preset.Kind.COLOR),
        Preset("Purple", PacketBuilder.preset(PacketBuilder.Color.BRIGHT_PURPLE), Preset.Kind.COLOR),
        Preset("Pink", PacketBuilder.preset(PacketBuilder.Color.PINK), Preset.Kind.COLOR),
        Preset("White", PacketBuilder.preset(PacketBuilder.Color.WHITE), Preset.Kind.COLOR),
        Preset("Orange", PacketBuilder.preset(PacketBuilder.Color.ORANGE), Preset.Kind.COLOR),
        Preset("Dual YO/Blue", PacketBuilder.dual(PacketBuilder.Color.YELLOW_ORANGE, PacketBuilder.Color.BLUE), Preset.Kind.EFFECT),
        Preset("5-LED Rainbow", PacketBuilder.rainbow5(), Preset.Kind.EFFECT),
        Preset("Circle", PacketBuilder.circle(), Preset.Kind.EFFECT),
        Preset("Crossfade R/B", PacketBuilder.crossfade(), Preset.Kind.EFFECT),
        Preset("Lightning", "8301CC03000100E100E90C000F0F5D465BF00532374895", Preset.Kind.EFFECT),
    )

    /** EMCOT 5-bit palette — see [StarlightColors]. */
    val starlightColorNames: Map<Int, String> = StarlightColors.palette

    val showBlocks: Map<String, String> = mapOf(
        "Lightning" to "8301CC03000100E100E90C000F0F5D465BF00532374895",
        "Rainbow FX" to PacketBuilder.rainbowFinale(),
    )

    fun starlightSimKey(colorIndex: Int) = "SL:${"%02X".format(colorIndex and 0x1F)}"

    fun legacyStarlightHex(colorIndex: Int, serial: String = StarlightSerial.DEFAULT_SERIAL): String =
        StarlightSerial.buildHex(serial, colorIndex)

    fun asMagicPackets(): List<MagicPacket> = all.mapIndexed { i, p ->
        MagicPacket(
            id = i + 1L,
            hex = p.hex,
            label = p.label,
            category = when (p.kind) {
                Preset.Kind.COLOR -> MagicCategory.COLOR
                Preset.Kind.EFFECT, Preset.Kind.VIBRATE -> MagicCategory.ANIMATION
                Preset.Kind.PING -> MagicCategory.SHOW
            },
            typeInfo = p.kind.name.lowercase(),
            simKey = "P:${p.label}",
        )
    }

    @Deprecated("Use asMagicPackets()", ReplaceWith("asMagicPackets()"))
    fun allPresets(): List<MagicPacket> = asMagicPackets()
}
