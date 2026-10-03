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
import com.magicmaker.android.core.HexUtils
import com.magicmaker.android.core.LabPacketBuilder
import com.magicmaker.android.core.MagicClassifier
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
fun BandPreview(hex: String, modifier: Modifier = Modifier, compact: Boolean = false, title: String = "BAND PREVIEW") {
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
            .padding(horizontal = 12.dp, vertical = if (compact) 2.dp else 6.dp),
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

            // Zones Z1..Z5 = bottom-left, top-left, centre, top-right, bottom-right.
            val inset = w * 0.20f
            val points = listOf(
                Offset(face.left + inset, face.bottom - inset),
                Offset(face.left + inset, face.top + inset),
                Offset(face.center.x, face.center.y),
                Offset(face.right - inset, face.top + inset),
                Offset(face.right - inset, face.bottom - inset),
            )
            points.forEachIndexed { z, p ->
                val c = ledColor(model, z, t) ?: dim
                if (c != dim) drawCircle(c.copy(alpha = 0.30f), radius = ledR * 2.2f, center = p)
                drawCircle(c, radius = ledR, center = p)
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            if (compact) {
                // Scan-page strip: exactly two text rows. Title and classification share the first.
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(title, style = techLabel(), color = AppColors.TextDim)
                    Spacer(Modifier.width(8.dp))
                    Text(
                        (MagicClassifier.classify(hex)?.label ?: model.note).uppercase(),
                        style = techLabel(), color = if (model.kind == BandEffectModel.Kind.NONE) AppColors.TextDim else AppColors.Cyan,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
                Text(HexUtils.canonicalHex(hex), style = techLabel(), color = AppColors.CyanDim, maxLines = 1, overflow = TextOverflow.Ellipsis)
                return@Column
            }
            Text(title, style = techLabel(), color = AppColors.TextDim)
            Text(
                model.kind.name.replace('_', ' ').let { if (it == "NONE") "NO EFFECT" else it },
                style = techHeader(), color = if (model.kind == BandEffectModel.Kind.NONE) AppColors.TextDim else AppColors.Cyan,
            )
            Text(
                model.note.uppercase() + if (model.approximate) " · APPROX." else "",
                style = techLabel(), color = if (model.approximate) AppColors.Amber else AppColors.TextDim,
                maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
            if (model.durationMs > 0 || model.alwaysOn) {
                val dur = if (model.alwaysOn) "ALWAYS ON" else "~${model.durationMs / 1000}S" + if (model.fadeMs > 0) " · ${model.fadeMs / 1000}S FADE" else ""
                Text(dur, style = techLabel(), color = AppColors.TextDim)
            }
            if (model.buzz > 0) {
                val name = LabPacketBuilder.vibrationPatterns.firstOrNull { it.id == model.buzz }?.label ?: "#${model.buzz}"
                val on = ((t * 6f) % 1f) < 0.5f
                Text("BUZZ · ${name.uppercase()}", style = techLabel(), color = if (on) AppColors.Cyan else AppColors.CyanDim)
            }
        }
    }
}

private const val Z3 = 2   // centre zone index in perLed

/** Colour of zone [z] (0..4 = Z1..Z5) at phase [t] in 0..1, or null for off. Pure function of the model. */
private fun ledColor(m: BandEffectModel, z: Int, t: Float): Color? {
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
            if (z == Z3) lerp(b, a, f) else lerp(a, b, f)
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
            if (z == Z3) return rest?.copy(alpha = 0.15f)
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
            if (z == Z3) return rest
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
        BandEffectModel.Kind.RGB -> Color(0xFF9E9E9E).copy(alpha = breathe())
        BandEffectModel.Kind.COMPLEX -> {
            val v = 0.5f + 0.5f * sin(2 * PI * t + z * 1.3f).toFloat()
            lerp(rest ?: labSwatchColor(0x15), labSwatchColor(0x0F), v)
        }
    }
}

/**
 * Scan page: the last packet heard, as the band would show it. Small — one row — and always at
 * the top, so you can watch what is arriving without reading hex.
 */
@Composable
fun LastHeardStrip(hex: String, heard: Int, modifier: Modifier = Modifier) {
    if (hex.isBlank()) {
        Row(
            modifier.fillMaxWidth().height(40.dp).background(AppColors.Navy).padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) { Text("LAST HEARD · NOTHING YET", style = techLabel(), color = AppColors.TextDim) }
        return
    }
    BandPreview(hex, modifier.height(40.dp), compact = true, title = "LAST HEARD · #$heard")
}
