package com.magicmaker.android.ui.vfd

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.ui.graphics.Color
import com.magicmaker.android.core.BandEffectModel
import com.magicmaker.android.ui.BandLedAnimation
import com.magicmaker.android.ui.WandPulse
import com.magicmaker.android.ui.labSwatchColor
import com.magicmaker.android.ui.starlightGlowColor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The true-colour and animation helpers the VFD screens use match what the standard views draw. */
class VFDColorsAnimTest {
    @Test
    fun wandPulseFollowsTheStandardTween() {
        // StarlightWandView: tween(420) (FastOutSlowInEasing), the second ring 180 ms later.
        assertEquals(420, WandPulse.DURATION_MS)
        assertEquals(180L, WandPulse.DELAY_MS)
        assertEquals(VFDPulse(0.0, 0.0), VFDAnim.wandPulse(-1.0))
        assertEquals(VFDPulse(1.0, 1.0), VFDAnim.wandPulse(5.0))
        val at: Double = 0.30
        val p: VFDPulse = VFDAnim.wandPulse(at)
        assertEquals(FastOutSlowInEasing.transform((at / 0.42).toFloat()).toDouble(), p.first, 1e-6)
        assertEquals(FastOutSlowInEasing.transform(((at - 0.18) / 0.42).toFloat()).toDouble(), p.second, 1e-6)
        assertEquals(0.0, VFDAnim.wandPulse(0.1).second, 0.0)
        assertTrue(VFDAnim.pulseRunning(0.5))
        assertFalse(VFDAnim.pulseRunning(0.61))
    }

    @Test
    fun bandPhaseLoopsEvery2400ms() {
        assertEquals(0.5f, BandLedAnimation.phase(2.4 * 1000.0 + 1.2), 1e-4f)
        assertEquals(0.25f, VFDColors.bandPhase(0.6), 1e-4f)
        val t: Float = BandLedAnimation.phase(1_763_600_000.123)
        assertTrue(t >= 0f && t < 1f)
        // BUZZ blinks 6 times per loop.
        assertTrue(BandLedAnimation.buzzOn(0.0f))
        assertFalse(BandLedAnimation.buzzOn(0.1f))
    }

    @Test
    fun coloursAreOpaqueAndMixedOverTheUnlitCell() {
        assertEquals(VFDRGB(0x33, 0x66, 0x99), VFDColors.rgb(Color(0xFF336699)))
        // Half white over #090909: 0.5 * 255 + 0.5 * 9 = 132.
        assertEquals(VFDRGB(132, 132, 132), VFDColors.rgb(Color.White.copy(alpha = 0.5f)))
        assertEquals(VFDColors.rgb(starlightGlowColor(0x15)), VFDColors.starlightGlow(0x15))
        assertEquals(VFDRGB(0xFF, 0x52, 0x52), VFDColors.starlightGlow(0x15))
        assertEquals(VFDColors.rgb(labSwatchColor(0x19)), VFDColors.labSwatch(0x19))
        assertEquals(VFDRGB(0xFF, 0x88, 0x00), VFDColors.rgb(0xFF8800))
    }

    @Test
    fun bandLedIsTheBandPreviewColour() {
        assertNull(VFDColors.bandLED(BandEffectModel.EMPTY, 0, 0.0))
        val model: BandEffectModel = BandEffectModel.EMPTY.copy(
            kind = BandEffectModel.Kind.DUAL,
            perLed = listOf(0x19, 0x19, 0x15, 0x19, 0x19),
        )
        val time = 12.0
        for (z in 0 until 5) {
            val expected: Color? = BandLedAnimation.color(model, z, BandLedAnimation.phase(time))
            assertEquals(expected?.let { VFDColors.rgb(it) }, VFDColors.bandLED(model, z, time))
        }
        assertEquals(VFDColors.labSwatch(0x15), VFDColors.bandLED(model, 2, time))
    }

    @Test
    fun uiStateKeepsTypedValues() {
        val ui = VFDUIState("test")
        var changes = 0
        ui.notify = { changes += 1 }
        assertFalse(ui.bool("open"))
        ui.toggleBool("open")
        assertTrue(ui.bool("open"))
        ui.setInt("row", 7)
        assertEquals(7, ui.int("row"))
        ui.toggleMember("sel", "A")
        ui.toggleMember("sel", "B")
        ui.toggleMember("sel", "A")
        assertEquals(setOf("B"), ui.strings("sel"))
        ui.setOptionalString("id", "x")
        ui.setOptionalString("id", null)
        assertNull(ui.optionalString("id"))
        assertEquals(7, changes)
    }
}
