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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.magicmaker.android.core.BandEffectModel
import com.magicmaker.android.core.HexUtils
import com.magicmaker.android.core.LabPacketBuilder
import com.magicmaker.android.core.MagicClassifier

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
        animationSpec = infiniteRepeatable(tween(BandLedAnimation.PERIOD_MS, easing = LinearEasing), RepeatMode.Restart),
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
                val c = BandLedAnimation.color(model, z, t) ?: dim
                if (c != dim) drawCircle(c.copy(alpha = 0.30f), radius = ledR * 2.2f, center = p)
                drawCircle(c, radius = ledR, center = p)
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            // No early returns inside composable lambdas: the Compose compiler can emit
            // unbalanced composition groups for them and crash at runtime, not compile time.
            if (compact) {
                // Scan-page strip: exactly two text rows. Title and classification share the first.
                val label = remember(hex) {
                    runCatching { MagicClassifier.classify(hex)?.label }.getOrNull() ?: model.note
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(title, style = techLabel(), color = AppColors.TextDim)
                    Spacer(Modifier.width(8.dp))
                    Text(
                        label.uppercase(),
                        style = techLabel(), color = if (model.kind == BandEffectModel.Kind.NONE) AppColors.TextDim else AppColors.Cyan,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
                Text(HexUtils.canonicalHex(hex), style = techLabel(), color = AppColors.CyanDim, maxLines = 1, overflow = TextOverflow.Ellipsis)
            } else {
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
                    val on = BandLedAnimation.buzzOn(t)
                    Text("BUZZ · ${name.uppercase()}", style = techLabel(), color = if (on) AppColors.Cyan else AppColors.CyanDim)
                }
            }
        }
    }
}

/**
 * Scan page: the last heard packet that lights the band, as the band would show it. Small — one
 * row — and always at the top. Pings, beacons and wand colours never appear here; [hex] is
 * `UiState.lastLightHex`, which only light effects update, so the strip holds the last real
 * effect while keep-alive traffic keeps arriving.
 */
@Composable
fun LastHeardStrip(hex: String, lights: Int, modifier: Modifier = Modifier) {
    if (hex.isBlank()) {
        Row(
            modifier.fillMaxWidth().height(40.dp).background(AppColors.Navy).padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) { Text("LAST LIGHTS · NONE HEARD YET", style = techLabel(), color = AppColors.TextDim) }
    } else {
        BandPreview(hex, modifier.height(40.dp), compact = true, title = "LAST LIGHTS · #$lights")
    }
}
