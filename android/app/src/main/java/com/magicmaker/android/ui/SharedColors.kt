package com.magicmaker.android.ui

import androidx.compose.animation.core.Easing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import com.magicmaker.android.core.BandEffectModel
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

// Colour content both themes draw: the band LED animation of BandPreview, the wand glow colour
// and the send pulse timing of StarlightWandView. The standard views and the VFD theme
// (ui/vfd/VFDContext.kt: VFDColors, VFDAnim) call these, so both show the same colours at the
// same moments.

/** The band preview's animation: a 2.4 s loop over the five LED zones of a [BandEffectModel]. */
internal object BandLedAnimation {
    /** One loop, in ms (BandPreview's infinite transition). */
    const val PERIOD_MS: Int = 2400

    /** Zone index of the centre LED (Z3). */
    const val CENTRE_ZONE: Int = 2

    /** Loop phase 0..<1 at [seconds] (any clock, e.g. System.currentTimeMillis() / 1000.0). */
    fun phase(seconds: Double): Float {
        val period: Double = PERIOD_MS / 1000.0
        var p: Double = seconds % period
        if (p < 0) p += period
        val t: Float = (p / period).toFloat()
        return if (t >= 1f) 0f else t
    }

    /** The BUZZ line blinks 6 times per loop: true in the bright half. */
    fun buzzOn(t: Float): Boolean = ((t * 6f) % 1f) < 0.5f

    /** Colour of zone [z] (0..4 = Z1..Z5) at phase [t] in 0..1, or null for off. Pure function of the model. */
    fun color(m: BandEffectModel, z: Int, t: Float): Color? {
        fun pal(idx: Int?) = idx?.let { labSwatchColor(it) }
        val rest = pal(m.perLed.getOrNull(z))
        fun breathe() = 0.75f + 0.25f * sin(2 * PI * t).toFloat()
        return when (m.kind) {
            BandEffectModel.Kind.NONE, BandEffectModel.Kind.PING -> null
            BandEffectModel.Kind.SINGLE, BandEffectModel.Kind.WAND -> rest?.copy(alpha = breathe())
            BandEffectModel.Kind.DUAL, BandEffectModel.Kind.TOGGLE -> {
                if (m.kind == BandEffectModel.Kind.TOGGLE) {
                    // Two distinct colours, swapped every half cycle.
                    val a = m.perLed.firstOrNull { it != null }
                    val b = m.perLed.firstOrNull { it != null && it != a } ?: a
                    return pal(if (((t * 4f) % 1f) < 0.5f) a else b)
                }
                rest
            }
            BandEffectModel.Kind.RAINBOW -> {
                if (m.approximate && m.colors.size == 5 && m.perLed.all { it != null } && m.note.contains("cycle")) {
                    // Hue cycle: rotate the five colours round the zones.
                    val shift = (t * 5).toInt()
                    pal(m.perLed[(z + shift) % 5])
                } else rest
            }
            BandEffectModel.Kind.ROTATE -> {
                // Listener: 750 ms per step through Z2→Z3→Z4→Z5→Z1.
                val order = listOf(1, 2, 3, 4, 0)
                val pos = order.indexOf(z)
                val step = (t * 5 * 2).toInt()
                pal(m.perLed[order[(pos + step) % 5]])
            }
            BandEffectModel.Kind.CROSSFADE -> {
                val a = pal(m.colors.getOrNull(0)) ?: return null
                val b = pal(m.colors.getOrNull(1)) ?: a
                val f = 0.5f - 0.5f * cos(2 * PI * t).toFloat()
                // Centre runs out of phase with the corners.
                if (z == CENTRE_ZONE) lerp(b, a, f) else lerp(a, b, f)
            }
            BandEffectModel.Kind.PULSE_BURST -> {
                // Two 500 ms triangle pulses then 500 ms dark, per 1.5 s.
                val pos = (t * 2.4f) % 1.5f
                if (pos >= 1f) return rest?.copy(alpha = 0.05f)
                val sub = pos % 0.5f
                val bright = if (sub < 0.25f) sub / 0.25f else 1f - (sub - 0.25f) / 0.25f
                rest?.copy(alpha = 0.1f + 0.9f * bright)
            }
            BandEffectModel.Kind.CIRCLE -> {
                // Two comets chasing round the four corners; centre dim.
                if (z == CENTRE_ZONE) return rest?.copy(alpha = 0.15f)
                val corners = listOf(0, 1, 3, 4)          // Z1 Z2 Z4 Z5 = BL TL TR BR, clockwise from BL
                val pos = corners.indexOf(z)
                val head = (t * 8).toInt() % 4
                val d = (pos - head + 4) % 4
                val base = rest ?: labSwatchColor(0x19)
                when (d) { 0, 2 -> base; 1, 3 -> base.copy(alpha = 0.3f); else -> base }
            }
            BandEffectModel.Kind.TWINKLE -> {
                val r = sin(z * 12.9898f + t * 40f) * 43758.5453f
                val v = r - r.toInt()
                if (v > 0.6f) rest else rest?.copy(alpha = 0.12f)
            }
            BandEffectModel.Kind.ALTERNATE -> {
                // 1 s cycle: 500 ms pair A (Z1, Z4), 500 ms pair B (Z2, Z5); centre steady.
                if (z == CENTRE_ZONE) return rest
                val half = ((t * 2.4f) % 1f) < 0.5f
                val isA = z == 0 || z == 3
                if (isA == half) rest else rest?.copy(alpha = 0.08f)
            }
            BandEffectModel.Kind.REPEAT_FADE -> {
                val pos = (t * 2.4f) % 1.25f
                val bright = if (pos < 1f) 1f - pos else 0f
                rest?.copy(alpha = 0.05f + 0.95f * bright)
            }
            BandEffectModel.Kind.LIGHTNING -> {
                val phase = (t * 3f) % 1f
                if (phase < 0.08f || (phase > 0.16f && phase < 0.22f)) Color.White else Color.White.copy(alpha = 0.15f)
            }
            BandEffectModel.Kind.STROBE -> {
                // Listener: yellow 0.5 s, orange 0.5 s, dark 4 s.
                val pos = (t * 5f) % 5f
                when {
                    pos < 0.5f -> labSwatchColor(0x11)
                    pos < 1f -> labSwatchColor(0x13)
                    else -> labSwatchColor(0x13).copy(alpha = 0.05f)
                }
            }
            BandEffectModel.Kind.STEPPER -> {
                val step = ((t * 4.8f).toInt() + z) % m.colors.size.coerceAtLeast(1)
                pal(m.colors.getOrNull(step))
            }
            BandEffectModel.Kind.RGB -> Color(0xFF000000L or (m.rgb ?: 0x9E9E9E).toLong()).copy(alpha = breathe())
            BandEffectModel.Kind.FLICKER -> {
                // Listener: corners and centre flicker independently every ~60 ms.
                val r = sin((z + 1) * 78.233f + (t * 40f).toInt() * 12.9898f) * 43758.5453f
                val v = 0.25f + 0.75f * (r - kotlin.math.floor(r))
                rest?.copy(alpha = v)
            }
            BandEffectModel.Kind.CENTRE_PULSE -> {
                if (z != CENTRE_ZONE) return rest?.copy(alpha = 0.35f)
                rest?.copy(alpha = 0.2f + 0.8f * (0.5f + 0.5f * sin(2 * PI * t).toFloat()))
            }
            BandEffectModel.Kind.COMET -> {
                if (z == CENTRE_ZONE) return rest?.copy(alpha = 0.12f)
                val corners = listOf(0, 1, 3, 4)
                val d = (corners.indexOf(z) - (t * 8).toInt() % 4 + 4) % 4
                when (d) { 0 -> rest; 3 -> rest?.copy(alpha = 0.45f); else -> rest?.copy(alpha = 0.08f) }
            }
            BandEffectModel.Kind.COMPLEX -> {
                val v = 0.5f + 0.5f * sin(2 * PI * t + z * 1.3f).toFloat()
                val a = m.colors.getOrNull(0)?.let { labSwatchColor(it) } ?: rest ?: labSwatchColor(0x15)
                val b = m.colors.getOrNull(1)?.let { labSwatchColor(it) } ?: labSwatchColor(0x0F)
                lerp(a, b, v)
            }
        }
    }
}

/** The wand glow colour of starlight palette index [index] (its low 5 bits), as StarlightWandView
 *  draws it and the VFD theme lights its cells (VFDColors.starlightGlow). */
internal fun starlightGlowColor(index: Int): Color {
    val i = index and 0x1F
    return when (i) {
        0x00, 0x16, 0x17, 0x18 -> Color(0xFF00E5FF)
        0x01, 0x05, 0x07 -> Color(0xFFBB86FC)
        0x02, 0x03, 0x04 -> Color(0xFF448AFF)
        0x06 -> Color(0xFFE1BEE7)
        in 0x08..0x0E -> Color(0xFFFF4081)
        0x0F, 0x11 -> Color(0xFFFFAB40)
        0x10 -> Color(0xFFFFF59D)
        0x12, 0x1A -> Color(0xFFCCFF90)
        0x13, 0x14 -> Color(0xFFFF9800)
        0x15 -> Color(0xFFFF5252)
        0x19 -> Color(0xFF69F0AE)
        0x1B, 0x1C -> Color(0xFFD1F0FF)
        0x1D -> Color(0xFF505050)
        0x1E -> Color(0xFFCE93D8)
        else -> Color(0xFFB388FF)
    }
}

/** The wand's send pulse (StarlightWandView.runTransmitPulse): two aura rings, each animated 0 to
 *  1 over [DURATION_MS] with [easing] (Compose tween's default), the second starting [DELAY_MS]
 *  after the first. A ring at progress p is drawn [SCALE_GAIN] * p larger than the aura with
 *  peak alpha ring peak * (1 - [FADE] * p), and stays drawn at p = 1 until the next send. */
internal object WandPulse {
    const val DURATION_MS: Int = 420
    const val DELAY_MS: Long = 180L
    val easing: Easing = FastOutSlowInEasing
    const val FIRST_RING_PEAK: Float = 0.38f
    const val SECOND_RING_PEAK: Float = 0.24f
    const val SCALE_GAIN: Float = 0.06f
    const val FADE: Float = 0.4f
}
