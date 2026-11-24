package com.magicmaker.android.ui.vfd

import com.magicmaker.android.core.MagicCategory
import com.magicmaker.android.core.MagicPacket
import com.magicmaker.android.core.NewWandCatalog
import com.magicmaker.android.core.StarlightColors
import com.magicmaker.android.core.StarlightSerial
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Starlight wand colour list both WAND tabs (standard and VFD) show: StarlightColors.wandColors
 *  (the iPhone uses the same rule in StarlightColors.swift). */
class VFDWandColorsTest {
    private val serialA = "0123456789ABCDEF012345"
    private val serialB = "FEDCBA9876543210FEDCBA"

    private fun code(id: Long, index: Int, serial: String): MagicPacket = MagicPacket(
        id = id,
        hex = StarlightSerial.buildHex(serial, index),
        label = "Starlight: ${StarlightColors.nameFor(index)} (#${"%02X".format(index)})",
        category = MagicCategory.COLOR,
        typeInfo = "starlight",
        colors = StarlightColors.nameFor(index),
        simKey = "SL:${"%02X".format(index)}",
    )

    @Test
    fun oneEntryPerColourNameTheNewestCodeInNameOrder() {
        val learned: List<MagicPacket> = listOf(
            code(10, 0x15, serialA), // Red
            code(11, 0x08, serialA), // Pink
            code(12, 0x0A, serialB), // Pink (another index of the same name)
            code(13, 0x15, serialB), // Red, learned later
            code(14, 0x00, serialA), // Cyan
            code(15, 0x16, serialB), // Cyan (another index)
            code(9, 0x08, serialB), // Pink, learned earliest
            NewWandCatalog.packets.first().copy(id = 20, typeInfo = "starlight"),
        )
        val list: List<MagicPacket> = StarlightColors.wandColors(learned)
        assertEquals(listOf("Cyan", "Pink", "Red"), list.map { StarlightColors.wandColorKey(it.hex) })
        assertEquals(listOf(15L, 12L, 13L), list.map { it.id })
        // Order does not depend on the input order.
        assertEquals(list, StarlightColors.wandColors(learned.reversed()))
    }

    @Test
    fun aColourGroupIsEveryCodeOfThatColourOnly() {
        val learned: List<MagicPacket> = listOf(
            code(1, 0x08, serialA),
            code(2, 0x0C, serialB),
            code(3, 0x15, serialA),
            NewWandCatalog.packets.first().copy(id = 4, typeInfo = "starlight"),
        )
        val pink: List<MagicPacket> = StarlightColors.wandColorGroup(learned, "Pink")
        assertEquals(listOf(1L, 2L), pink.map { it.id })
        assertTrue(StarlightColors.wandColorGroup(learned, "Blue").isEmpty())
        assertEquals("Pink · removes 2 learned codes", StarlightColors.wandDeleteLabel("Pink", pink.size))
        assertEquals("Red · removes 1 learned code", StarlightColors.wandDeleteLabel("Red", 1))
    }

    @Test
    fun aCodeThatCannotBeReadIsIndexZero() {
        assertEquals(StarlightColors.nameFor(0), StarlightColors.wandColorKey(""))
        assertEquals("Pink", StarlightColors.wandColorKey(0x0E))
    }
}
