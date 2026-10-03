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
 * What we expect the packet to look like on the band. A MagicBand+ has five LEDs: one at each
 * corner of the face and one in the centre. Dual colour is centre vs corners, the 5-LED rainbow
 * is one colour per LED, circle chases around the four corners. Pinned above the Lab so it is
 * always visible and follows every change to the packet. Colours are exact; where the motion or
 * the LED order is a guess the model says so and the caption shows it.
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

    Row(
        modifier
            .fillMaxWidth()
            .background(AppColors.Navy)
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Canvas(Modifier.fillMaxHeight().aspectRatio(1f)) {
            val w = size.minDimension
            val face = androidx.compose.ui.geometry.Rect(w * 0.08f, w * 0.08f, w * 0.92f, w * 0.92f)
            val dim = Color(0xFF14233A)
            val ledR = w * 0.085f

            // The band face.
            drawRoundRect(
                Color(0xFF0B1424), topLeft = face.topLeft, size = face.size,
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(w * 0.07f),
            )
            drawRoundRect(
                Color(0xFF1E3A5F), topLeft = face.topLeft, size = face.size,
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(w * 0.07f),
                style = androidx.compose.ui.graphics.drawscope.Stroke(width = w * 0.012f),
            )

            // LED 0..3 are the corners clockwise from top-left; LED 4 is the centre.
            val inset = w * 0.20f
            val points = listOf(
                Offset(face.left + inset, face.top + inset),
                Offset(face.right - inset, face.top + inset),
                Offset(face.right - inset, face.bottom - inset),
                Offset(face.left + inset, face.bottom - inset),
                Offset(face.center.x, face.center.y),
            )
            points.forEachIndexed { i, p ->
                val c = ledColor(model, i, t) ?: dim
                if (c != dim) drawCircle(c.copy(alpha = 0.30f), radius = ledR * 2.2f, center = p)
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

private const val CENTER = 4

/** Colour of LED [i] (0..3 corners clockwise from top-left, 4 centre) at phase [t] in 0..1, or null for off. */
private fun ledColor(m: BandEffectModel, i: Int, t: Float): Color? {
    fun pal(idx: Int) = labSwatchColor(idx)
    fun breathe() = 0.75f + 0.25f * sin(2 * PI * t).toFloat()
    val isCenter = i == CENTER
    return when (m.kind) {
        BandEffectModel.Kind.NONE, BandEffectModel.Kind.PING -> null
        BandEffectModel.Kind.SINGLE, BandEffectModel.Kind.WAND ->
            m.colors.firstOrNull()?.let { pal(it).copy(alpha = breathe()) }
        // Dual: inner = centre LED, outer = the four corners.
        BandEffectModel.Kind.DUAL -> (if (isCenter) m.colors.getOrNull(0) else m.colors.getOrNull(1))?.let { pal(it) }
        // Rainbow: one colour per LED, slots 1-4 on the corners, slot 5 in the centre.
        BandEffectModel.Kind.RAINBOW -> {
            if (m.colors.isEmpty()) return null
            val shift = if (m.approximate) (t * m.colors.size).toInt() else 0
            pal(m.colors[(i + shift) % m.colors.size])
        }
        BandEffectModel.Kind.CROSSFADE -> {
            val a = m.colors.getOrNull(0)?.let { pal(it) } ?: return null
            val b = m.colors.getOrNull(1)?.let { pal(it) } ?: a
            val f = 0.5f - 0.5f * cos(2 * PI * t).toFloat()   // a -> b -> a
            lerp(a, b, f)
        }
        // Circle: the pattern chases around the four corners; the centre holds the first colour.
        BandEffectModel.Kind.CIRCLE -> {
            if (m.colors.isEmpty()) return null
            if (isCenter) return pal(m.colors[0]).copy(alpha = 0.6f)
            val step = (t * 8f).toInt()                      // one corner per 1/8 of the loop
            val lead = step % 4
            val c = pal(m.colors[(i + step) % m.colors.size])
            if (i == lead) c else c.copy(alpha = 0.35f)
        }
        BandEffectModel.Kind.LIGHTNING -> {
            val phase = (t * 3f) % 1f
            if (phase < 0.08f || (phase > 0.16f && phase < 0.22f)) Color.White else pal(0x02).copy(alpha = 0.25f)
        }
        BandEffectModel.Kind.SPARKLE -> {
            val r = sin(i * 12.9898f + t * 40f) * 43758.5453f
            val v = r - r.toInt()
            val base = m.colors.getOrNull(i % maxOf(1, m.colors.size))?.let { pal(it) } ?: Color.White
            if (v > 0.55f) base else base.copy(alpha = 0.12f)
        }
        // Strobe: opposite corners alternate; centre follows the first pair.
        BandEffectModel.Kind.STROBE -> {
            val half = ((t * 8f) % 1f) < 0.5f
            val c = m.colors.firstOrNull()?.let { pal(it) } ?: Color.White
            val group = if (isCenter) 0 else i % 2
            if ((group == 0) == half) c else c.copy(alpha = 0.1f)
        }
        BandEffectModel.Kind.COMPLEX -> {
            val v = 0.5f + 0.5f * sin(2 * PI * t + i * 1.3f).toFloat()
            lerp(pal(0x15), pal(0x0F), v)
        }
    }
}
