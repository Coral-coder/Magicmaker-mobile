package com.magicmaker.android.core

/**
 * A second wand type, distinct from the Starlight wands. Its codes are the CF0B family
 *
 *   8301CF0B00C020224EAC7807866E80 .. 8301CF0B00C020224EAC7807866FFF
 *
 * i.e. a fixed prefix with the trailing 3 nibbles sweeping E80→FFF. The set is fully
 * determined by that range, so it's generated on demand (deterministic, stable ids) rather
 * than persisted — it never bloats the user's saved library or the cloud dictionary.
 */
object NewWandCatalog {
    const val PREFIX = "8301CF0B00C020224EAC7807866"
    private const val RANGE_START = 0xE80
    private const val RANGE_END = 0xFFF
    /** Synthetic id base — well above real learned-packet ids so the two never collide. */
    const val ID_BASE = 1_000_000L

    // Codes that don't actually exist on the wand and must be skipped (last-2-bytes 6F20..6F7F,
    // i.e. the trailing-nibble value 0xF20..0xF7F).
    private val EXCLUDED = 0xF20..0xF7F

    /** Every real code in the range, low-to-high, as ready-to-transmit packets. */
    val packets: List<MagicPacket> by lazy {
        (RANGE_START..RANGE_END).filter { it !in EXCLUDED }.map { v ->
            val hex = PREFIX + "%03X".format(v)
            MagicPacket(
                id = ID_BASE + (v - RANGE_START),
                hex = hex,
                label = "New Wand ${"%03X".format(v)}",
                category = MagicCategory.COLOR,
                typeInfo = "newwand",
                colors = StarlightColors.nameFor(hex.takeLast(2).toInt(16) and 0x1F),
                simKey = "NEWWAND:$hex",
            )
        }
    }

    // ids are no longer contiguous (excluded range), so look up by id rather than index.
    fun byId(id: Long): MagicPacket? = packets.firstOrNull { it.id == id }

    fun isNewWandId(id: Long): Boolean = id >= ID_BASE
}
