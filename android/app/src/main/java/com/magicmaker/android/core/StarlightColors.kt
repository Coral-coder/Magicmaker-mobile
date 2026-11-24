package com.magicmaker.android.core

/**
 * Starlight wand + MagicBand+ 5-bit color palette.
 * @see [EMCOT color table](https://emcot.world/Disney_MagicBand%2B_Bluetooth_Codes)
 * @see [Starlight wand format](https://emcot.world/Disney%27s_Starlight_Wand) — last byte = palette index
 */
object StarlightColors {
    data class Entry(
        val index: Int,
        val name: String,
        val hex: String,
    )

    /** Full EMCOT 5-bit palette (0x00–0x1F). */
    val palette: Map<Int, String> = mapOf(
        0x00 to "Cyan",
        0x01 to "Purple",
        0x02 to "Blue",
        0x03 to "Midnight Blue",
        0x04 to "Blue",
        0x05 to "Bright Purple",
        0x06 to "Lavender",
        0x07 to "Purple",
        0x08 to "Pink",
        0x09 to "Pink",
        0x0A to "Pink",
        0x0B to "Pink",
        0x0C to "Pink",
        0x0D to "Pink",
        0x0E to "Pink",
        0x0F to "Yellow Orange",
        0x10 to "Off Yellow",
        0x11 to "Yellow",
        0x12 to "Lime",
        0x13 to "Orange",
        0x14 to "Red Orange",
        0x15 to "Red",
        0x16 to "Cyan",
        0x17 to "Cyan",
        0x18 to "Cyan",
        0x19 to "Green",
        0x1A to "Lime Green",
        0x1B to "White",
        0x1C to "White",
        0x1D to "Off",
        0x1E to "Unique",
        0x1F to "Random",
    )

    fun nameFor(index: Int): String =
        palette[index and 0x1F] ?: "Unknown (#${"%02X".format(index and 0x1F)})"

    fun broadcastHex(colorIndex: Int, serial: String = StarlightSerial.DEFAULT_SERIAL): String =
        StarlightSerial.buildHex(serial, colorIndex)

    /** All wand colors for UI — uses stored serial when looping. */
    fun entries(serial: String = StarlightSerial.DEFAULT_SERIAL): List<Entry> =
        palette.keys.sorted().map { idx ->
            Entry(idx, nameFor(idx), broadcastHex(idx, serial))
        }

    // MARK: - Starlight wand colour list (WAND tab, standard and VFD)

    /** New Wand codes carry this signature; the Starlight colour list leaves them out. */
    const val NEW_WAND_SIGNATURE: String = "CF0B00C020224EAC7807866"

    fun isNewWandHex(hex: String): Boolean = hex.uppercase().contains(NEW_WAND_SIGNATURE)

    /**
     * The colour a Starlight code is listed as: the palette name of the colour index it decodes
     * to. Indexes the palette names alike (Pink 0x08–0x0E, Cyan 0x00/0x16–0x18, Blue 0x02/0x04,
     * Purple 0x01/0x07, White 0x1B/0x1C) are one colour. Same as iOS `wandColorKey`.
     */
    fun wandColorKey(index: Int): String = nameFor(index)

    /** [wandColorKey] of a code; one that cannot be read (empty) is index 0, as on iOS. */
    fun wandColorKey(hex: String): String =
        nameFor(runCatching { MagicClassifier.starlightColorIndex(hex) }.getOrDefault(0))

    /**
     * The Starlight wand colour list: one entry per colour ([wandColorKey]), each the most
     * recently learned code of that colour — the highest packet id, as the store numbers packets
     * in the order they are learned (equal ids keep the first) — ordered by colour name. New Wand
     * codes are left out. Same rule as iOS `StarlightColors.wandColors`.
     */
    fun wandColors(learned: List<MagicPacket>): List<MagicPacket> {
        val newest = HashMap<String, MagicPacket>()
        for (packet in learned) {
            if (isNewWandHex(packet.hex)) continue
            val key: String = wandColorKey(packet.hex)
            val kept: MagicPacket? = newest[key]
            if (kept != null && kept.id >= packet.id) continue
            newest[key] = packet
        }
        return newest.keys.sorted().map { newest.getValue(it) }
    }

    /** Every learned code the list shows as colour [key] (not only the one it sends), New Wand
     *  codes left out. */
    fun wandColorGroup(learned: List<MagicPacket>, key: String): List<MagicPacket> =
        learned.filter { !isNewWandHex(it.hex) && wandColorKey(it.hex) == key }

    /** "Pink · removes 3 learned codes": the delete confirmation's line for a colour row. */
    fun wandDeleteLabel(key: String, count: Int): String {
        val noun: String = if (count == 1) "code" else "codes"
        return "$key · removes $count learned $noun"
    }
}
