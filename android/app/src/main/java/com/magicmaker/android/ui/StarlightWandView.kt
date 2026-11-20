package com.magicmaker.android.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.magicmaker.android.R
import com.magicmaker.android.core.MagicClassifier
import com.magicmaker.android.core.MagicPacket
import com.magicmaker.android.core.StarlightColors
import kotlinx.coroutines.launch

private const val DEFAULT_GLOW_INDEX = 0x1B
private const val WAND_ASPECT = 600f / 750f
private const val UPPER_GLOW_FRACTION = 0.94f

private data class WandGlowEnvelope(
    val centerY: Float,
    val rx: Float,
    val ry: Float,
    val peak: Float,
)

private val wandAuraEnvelopes = listOf(
    WandGlowEnvelope(0.28f, 0.115f, 0.30f, 0.30f),
    WandGlowEnvelope(0.28f, 0.062f, 0.265f, 0.55f),
)

private val wandTintEnvelope = WandGlowEnvelope(0.28f, 0.085f, 0.275f, 0.72f)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StarlightWandView(
    colors: List<MagicPacket>,
    displayColorIndex: Int,
    onTransmit: (MagicPacket) -> Unit,
    modifier: Modifier = Modifier,
    sendEnabled: Boolean = true,
) {
    val scope = rememberCoroutineScope()
    val pulse1 = remember { Animatable(0f) }
    val pulse2 = remember { Animatable(0f) }
    var selectedIndex by remember(colors.size) { mutableIntStateOf(0) }
    var glowColorIndex by remember { mutableIntStateOf(DEFAULT_GLOW_INDEX) }

    fun runTransmitPulse() {
        scope.launch {
            pulse1.snapTo(0f)
            pulse2.snapTo(0f)
            launch { pulse1.animateTo(1f, tween(WandPulse.DURATION_MS, easing = WandPulse.easing)) }
            kotlinx.coroutines.delay(WandPulse.DELAY_MS)
            launch { pulse2.animateTo(1f, tween(WandPulse.DURATION_MS, easing = WandPulse.easing)) }
        }
    }

    LaunchedEffect(displayColorIndex, colors) {
        val heard = displayColorIndex and 0x1F
        glowColorIndex = heard
        if (colors.isEmpty()) return@LaunchedEffect
        val heardIdx = colors.indexOfFirst {
            MagicClassifier.starlightColorIndex(it.hex) == heard
        }
        if (heardIdx >= 0) selectedIndex = heardIdx
    }

    val glow = starlightGlowColor(glowColorIndex)
    val label = StarlightColors.nameFor(glowColorIndex)
    val selected = colors.getOrNull(selectedIndex)

    Column(
        modifier = modifier.padding(bottom = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    enabled = colors.isNotEmpty(),
                ) {
                    if (colors.isNotEmpty()) {
                        selectedIndex = (selectedIndex + 1) % colors.size
                        glowColorIndex = MagicClassifier.starlightColorIndex(colors[selectedIndex].hex)
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            BoxWithConstraints(contentAlignment = Alignment.Center) {
                val maxH = maxHeight * 0.92f
                val maxW = maxWidth * 0.72f
                val wandHeight = minOf(maxH, maxW / WAND_ASPECT)
                val wandWidth = wandHeight * WAND_ASPECT

                Canvas(
                    Modifier
                        .width(wandWidth)
                        .height(wandHeight)
                        .blur(3.5.dp),
                ) {
                    drawWandAuraLayer(
                        glow = glow,
                        pulse1 = pulse1.value,
                        pulse2 = pulse2.value,
                    )
                }

                Image(
                    painter = painterResource(R.drawable.starlight_wand),
                    contentDescription = "Starlight wand",
                    modifier = Modifier
                        .width(wandWidth)
                        .height(wandHeight),
                    contentScale = ContentScale.Fit,
                )

                Canvas(
                    Modifier
                        .width(wandWidth)
                        .height(wandHeight)
                        .blur(1.2.dp),
                ) {
                    drawWandTintLayer(glow = glow)
                }
            }
        }

        if (colors.isEmpty()) {
            Text(
                text = "HEAR A WAND COLOR · SCAN TO LEARN",
                style = techLabel(),
                color = AppColors.TextDim,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 12.dp),
            )
        } else {
            // Dropdown to pick the color/command + Send button to the right — no tapping through.
            var expanded by remember { mutableStateOf(false) }
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                ExposedDropdownMenuBox(
                    expanded = expanded,
                    onExpandedChange = { expanded = it },
                    modifier = Modifier.weight(1f),
                ) {
                    OutlinedButton(
                        onClick = { expanded = true },
                        modifier = Modifier.menuAnchor().height(44.dp).fillMaxWidth(),
                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp),
                    ) {
                        // Name on top, the actual code below, so you see exactly which one is armed.
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                label.uppercase(),
                                style = techLabel(),
                                color = AppColors.TextPrimary,
                                maxLines = 1,
                            )
                            Text(
                                selected?.hex?.uppercase() ?: "",
                                style = techLabel(),
                                color = AppColors.TextDim,
                                maxLines = 1,
                            )
                        }
                        Text("▾", style = techLabel(), color = AppColors.TextDim)
                    }
                    ExposedDropdownMenu(
                        expanded = expanded,
                        onDismissRequest = { expanded = false },
                        modifier = Modifier.background(AppColors.Panel),
                    ) {
                        colors.forEachIndexed { idx, packet ->
                            DropdownMenuItem(
                                text = {
                                    Text(
                                        StarlightColors.nameFor(
                                            MagicClassifier.starlightColorIndex(packet.hex),
                                        ).uppercase() + "  ·  " + packet.hex.uppercase(),
                                        style = techLabel(),
                                    )
                                },
                                onClick = {
                                    selectedIndex = idx
                                    glowColorIndex = MagicClassifier.starlightColorIndex(packet.hex)
                                    expanded = false
                                },
                            )
                        }
                    }
                }
                Button(
                    onClick = {
                        val packet = colors.getOrNull(selectedIndex) ?: return@Button
                        runTransmitPulse()
                        onTransmit(packet)
                    },
                    enabled = sendEnabled && selected != null,
                    modifier = Modifier.height(44.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = AppColors.Cyan,
                        contentColor = AppColors.Navy,
                        disabledContainerColor = AppColors.PanelLine,
                        disabledContentColor = AppColors.TextDim,
                    ),
                ) {
                    Text("SEND", style = techHeader())
                }
            }
        }
    }
}

private fun DrawScope.drawWandAuraLayer(
    glow: Color,
    pulse1: Float,
    pulse2: Float,
) {
    val cx = size.width / 2f
    val glowBottom = size.height * UPPER_GLOW_FRACTION

    clipRect(left = 0f, top = 0f, right = size.width, bottom = glowBottom) {
        wandAuraEnvelopes.forEach { env ->
            drawSoftAura(
                glow = glow,
                cx = cx,
                centerY = size.height * env.centerY,
                rx = size.width * env.rx,
                ry = size.height * env.ry,
                peak = env.peak,
            )
        }

        listOf(pulse1 to WandPulse.FIRST_RING_PEAK, pulse2 to WandPulse.SECOND_RING_PEAK).forEach { (p, alpha) ->
            if (p > 0f) {
                val scale = 1f + p * WandPulse.SCALE_GAIN
                val env = wandAuraEnvelopes[0]
                drawSoftAura(
                    glow = glow,
                    cx = cx,
                    centerY = size.height * env.centerY,
                    rx = size.width * env.rx * scale,
                    ry = size.height * env.ry * scale,
                    peak = alpha * (1f - p * WandPulse.FADE),
                )
            }
        }
    }
}

private fun DrawScope.drawSoftAura(
    glow: Color,
    cx: Float,
    centerY: Float,
    rx: Float,
    ry: Float,
    peak: Float,
) {
    val radius = maxOf(rx, ry)
    drawOval(
        brush = Brush.radialGradient(
            colorStops = arrayOf(
                0f to glow.copy(alpha = peak * 0.45f),
                0.28f to glow.copy(alpha = peak * 0.82f),
                0.42f to glow.copy(alpha = peak),
                0.58f to glow.copy(alpha = peak * 0.62f),
                0.72f to glow.copy(alpha = peak * 0.22f),
                0.84f to glow.copy(alpha = peak * 0.05f),
                0.96f to Color.Transparent,
            ),
            center = Offset(cx, centerY),
            radius = radius,
        ),
        topLeft = Offset(cx - rx, centerY - ry),
        size = Size(rx * 2f, ry * 2f),
        blendMode = BlendMode.Plus,
    )
}

private fun DrawScope.drawWandTintLayer(glow: Color) {
    val cx = size.width / 2f
    val glowBottom = size.height * UPPER_GLOW_FRACTION
    val env = wandTintEnvelope

    clipRect(left = 0f, top = 0f, right = size.width, bottom = glowBottom) {
        val centerY = size.height * env.centerY
        val rx = size.width * env.rx
        val ry = size.height * env.ry
        val radius = maxOf(rx, ry)
        drawOval(
            brush = Brush.radialGradient(
                colorStops = arrayOf(
                    0f to glow.copy(alpha = env.peak * 0.55f),
                    0.35f to glow.copy(alpha = env.peak * 0.85f),
                    0.58f to glow.copy(alpha = env.peak * 0.45f),
                    0.76f to glow.copy(alpha = env.peak * 0.12f),
                    0.92f to Color.Transparent,
                ),
                center = Offset(cx, centerY),
                radius = radius,
            ),
            topLeft = Offset(cx - rx, centerY - ry),
            size = Size(rx * 2f, ry * 2f),
            blendMode = BlendMode.Multiply,
            alpha = 0.78f,
        )
    }
}
