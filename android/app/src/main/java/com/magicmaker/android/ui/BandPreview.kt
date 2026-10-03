package com.magicmaker.android.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.magicmaker.android.core.BandEffectModel
import com.magicmaker.android.core.LabPacketBuilder
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * What we expect the packet to look like on the band: a ring of LEDs around the icon disc,
 * animated in a loop from the decoded [BandEffectModel]. Pinned above the Lab so it is always
 * visible and follows every change to the packet. Colours are exact; where the motion is a guess
 * the model says so and the caption shows it.
 */
@Composable
fun BandPreview(hex: String, modifier: Modifier = Modifier) {
    val model = remember(hex) { runCatching { BandEffectModel.from(hex) }.getOrDefault(BandEffectModel.EMPTY) }
    val transition = rememberInfiniteTransition(label = "band")
    val t by transition.animateFloat(
        initialValue = 0f, targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(2400, easing = LinearEasing), RepeatMode.Restart),
        label = "t",
    )
    val leds = 12

    Row(
        modifier
            .fillMaxWidth()
            .background(AppColors.Navy)
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Canvas(Modifier.fillMaxHeight().aspectRatio(1f)) {
            val cx = size.width / 2f
            val cy = size.height / 2f
            val ringR = size.minDimension * 0.40f
            val ledR = size.minDimension * 0.065f
            val dim = Color(0xFF14233A)

            // Icon disc — the band's centre. Dual colour lights it with the inner colour.
            val centre = when (model.kind) {
                BandEffectModel.Kind.DUAL -> model.colors.getOrNull(0)?.let { labSwatchColor(it) } ?: dim
                BandEffectModel.Kind.SINGLE, BandEffectModel.Kind.WAND -> model.colors.firstOrNull()?.let { labSwatchColor(it).copy(alpha = 0.35f) } ?: dim
                else -> dim
            }
            drawCircle(centre, radius = ringR * 0.45f, center = Offset(cx, cy))

            for (i in 0 until leds) {
                val a = (2 * PI * i / leds - PI / 2).toFloat()
                val c = ledColor(model, i, leds, t) ?: dim
                val p = Offset(cx + ringR * cos(a), cy + ringR * sin(a))
                if (c != dim) drawCircle(c.copy(alpha = 0.28f), radius = ledR * 2.1f, center = p)
                drawCircle(c, radius = ledR, center = p)
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text("BAND PREVIEW", style = techLabel(), color = AppColors.TextDim)
            Text(
                model.kind.name.replace('_', ' ').let { if (it == "NONE") "NO EFFECT" else it },
                style = techHeader(), color = if (model.kind == BandEffectModel.Kind.NONE) AppColors.TextDim else AppColors.Cyan,
            )
            Text(
                model.note.uppercase() + if (model.approximate) " · APPROX." else "",
                style = techLabel(), color = if (model.approximate) AppColors.Amber else AppColors.TextDim,
                maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
            if (model.buzz > 0) {
                val name = LabPacketBuilder.vibrationPatterns.firstOrNull { it.id == model.buzz }?.label ?: "#${model.buzz}"
                val on = ((t * 6f) % 1f) < 0.5f
                Text("BUZZ · ${name.uppercase()}", style = techLabel(), color = if (on) AppColors.Cyan else AppColors.CyanDim)
            }
        }
    }
}

/** Colour of LED [i] of [n] at phase [t] in 0..1, or null for off. Pure function of the model. */
private fun ledColor(m: BandEffectModel, i: Int, n: Int, t: Float): Color? {
    fun pal(idx: Int) = labSwatchColor(idx)
    fun breathe() = 0.75f + 0.25f * sin(2 * PI * t).toFloat()
    return when (m.kind) {
        BandEffectModel.Kind.NONE, BandEffectModel.Kind.PING -> null
        BandEffectModel.Kind.SINGLE, BandEffectModel.Kind.WAND ->
            m.colors.firstOrNull()?.let { pal(it).copy(alpha = breathe()) }
        BandEffectModel.Kind.DUAL -> m.colors.getOrNull(1)?.let { pal(it) }   // outer ring = second colour
        BandEffectModel.Kind.RAINBOW -> {
            if (m.colors.isEmpty()) return null
            // Five colours laid around the ring; the captured cycles rotate slowly.
            val shift = if (m.approximate) (t * m.colors.size).toInt() else 0
            pal(m.colors[(i * m.colors.size / n + shift) % m.colors.size])
        }
        BandEffectModel.Kind.CROSSFADE -> {
            val a = m.colors.getOrNull(0)?.let { pal(it) } ?: return null
            val b = m.colors.getOrNull(1)?.let { pal(it) } ?: a
            val f = 0.5f - 0.5f * cos(2 * PI * t).toFloat()   // a -> b -> a
            lerp(a, b, f)
        }
        BandEffectModel.Kind.CIRCLE -> {
            if (m.colors.isEmpty()) return null
            // Seven pattern colours chasing around the ring, one step per ~1/7 of the loop.
            val step = (t * m.colors.size * 2).toInt()
            val idx = ((i + step) % n) * m.colors.size / n
            val c = pal(m.colors[idx % m.colors.size])
            // Lead LED brighter so the rotation reads as motion.
            if ((i + step) % n == 0) c else c.copy(alpha = 0.55f)
        }
        BandEffectModel.Kind.LIGHTNING -> {
            val phase = (t * 3f) % 1f
            if (phase < 0.08f || (phase > 0.16f && phase < 0.22f)) Color.White else pal(0x02).copy(alpha = 0.25f)
        }
        BandEffectModel.Kind.SPARKLE -> {
            val r = sin(i * 12.9898f + t * 40f) * 43758.5453f
            val v = r - r.toInt()
            val base = m.colors.getOrNull(i % maxOf(1, m.colors.size))?.let { pal(it) } ?: Color.White
            if (v > 0.6f) base else base.copy(alpha = 0.12f)
        }
        BandEffectModel.Kind.STROBE -> {
            val half = ((t * 8f) % 1f) < 0.5f
            val c = m.colors.firstOrNull()?.let { pal(it) } ?: Color.White
            if ((i % 2 == 0) == half) c else c.copy(alpha = 0.1f)
        }
        BandEffectModel.Kind.COMPLEX -> {
            val v = 0.5f + 0.5f * sin(2 * PI * t + i * 0.9f).toFloat()
            lerp(pal(0x15), pal(0x0F), v)
        }
    }
}
