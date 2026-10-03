package com.magicmaker.android.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.magicmaker.android.core.DisneyTlv
import com.magicmaker.android.core.HexUtils
import com.magicmaker.android.core.LabPacketBuilder
import com.magicmaker.android.core.MagicClassifier

/**
 * The Lab's "what am I building" layer. Everything on this screen answers that question in plain
 * words before it shows a single hex digit:
 *
 *  - [PacketSummaryCard] says what the packet does, in a sentence, and whether it will fit in a
 *    BLE advertisement.
 *  - [PacketAnatomy] lays the bytes out as labelled segments — company ID, channel marker, effect
 *    record, header, each colour byte, tail — so the hex stops being a wall.
 *
 * Both are driven by [DisneyTlv], the same parser the classifier uses, so the Lab never disagrees
 * with the scanner about what a packet is.
 */

/** One-sentence description of the packet plus its size/fit, derived from the classifier + TLV walk. */
@Composable
fun PacketSummaryCard(hex: String, modifier: Modifier = Modifier) {
    val canonical = remember(hex) { HexUtils.canonicalHex(hex) }
    val classified = remember(canonical) { runCatching { MagicClassifier.classify(canonical) }.getOrNull() }
    val parsed = remember(canonical) { DisneyTlv.parse(canonical) }
    val reject = remember(canonical) { HexUtils.legacyAdvertiseRejectReason(canonical) }
    val bytes = remember(canonical) { HexUtils.hexToBytes(canonical).size }

    val headline = classified?.label ?: parsed?.records?.firstOrNull()?.let { r ->
        when {
            r.isChannelMarker() -> "Channel marker only — no effect"
            else -> "Unrecognised packet (type ${r.typeHex()})"
        }
    } ?: "Empty packet"

    val details = buildList {
        parsed?.let { p ->
            if (p.records.firstOrNull()?.type == DisneyTlv.TYPE_PING && p.effect != null) add("wake ping first")
            val ch = p.channel
            if (ch != null) add("channel ${ch.type - DisneyTlv.TYPE_CHANNEL_1 + 1}")
            else if (p.effect != null) add("no channel marker")
            p.effect?.let { e ->
                val tail = e.value.lastOrNull()?.toInt()?.and(0xFF)
                if (tail != null && (tail and 0xF0) == 0xB0) {
                    val vib = tail and 0x0F
                    add(if (vib == 0) "no buzz" else "buzz " + (LabPacketBuilder.vibrationPatterns.firstOrNull { it.id == vib }?.label ?: "#$vib").lowercase())
                }
            }
            if (!p.exact) add("MALFORMED")
        }
        add("$bytes bytes")
        add(if (reject == null) "fits in BLE" else "TOO LONG")
    }

    val tone = when {
        reject != null || parsed?.exact == false -> MaterialTheme.colorScheme.error
        classified != null -> AppColors.Cyan
        else -> AppColors.Amber
    }

    Column(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(6.dp))
            .background(AppColors.Panel)
            .border(1.dp, tone.copy(alpha = 0.5f), RoundedCornerShape(6.dp))
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text("YOU ARE BUILDING", style = techLabel(), color = AppColors.TextDim)
        Text(headline.uppercase(), style = techHeader(), color = tone, maxLines = 2, overflow = TextOverflow.Ellipsis)
        val colors = classified?.colors.orEmpty()
        if (colors.isNotBlank()) Text(colors.uppercase(), style = techLabel(), color = AppColors.CyanDim)
        Text(details.joinToString(" · ").uppercase(), style = techLabel(), color = AppColors.TextDim)
        reject?.let { Text(it, style = techLabel(), color = MaterialTheme.colorScheme.error) }
    }
}

private fun segmentColor(kind: DisneyTlv.SegmentKind): Color = when (kind) {
    DisneyTlv.SegmentKind.COMPANY -> AppColors.TextDim
    DisneyTlv.SegmentKind.CHANNEL -> AppColors.Amber
    DisneyTlv.SegmentKind.PING -> AppColors.Amber
    DisneyTlv.SegmentKind.EFFECT_HEAD -> AppColors.Cyan
    DisneyTlv.SegmentKind.HEADER -> AppColors.CyanDim
    DisneyTlv.SegmentKind.COLOR -> AppColors.Cyan
    DisneyTlv.SegmentKind.DATA -> AppColors.CyanDim
    DisneyTlv.SegmentKind.TAIL -> AppColors.TextDim
    DisneyTlv.SegmentKind.WAND -> AppColors.Cyan
    DisneyTlv.SegmentKind.BEACON -> AppColors.TextDim
    DisneyTlv.SegmentKind.OTHER -> AppColors.TextDim
    DisneyTlv.SegmentKind.ERROR -> Color(0xFFFF5252)
}

/**
 * The packet as labelled byte groups. Tap a segment to read its explanation. Colour-slot
 * segments also show a swatch of the palette colour they encode.
 */
@OptIn(ExperimentalLayoutApi::class, ExperimentalFoundationApi::class)
@Composable
fun PacketAnatomy(hex: String, modifier: Modifier = Modifier) {
    val segments = remember(hex) { runCatching { DisneyTlv.anatomy(hex) }.getOrDefault(emptyList()) }
    var selected by remember(hex) { mutableStateOf<Int?>(null) }

    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("PACKET ANATOMY — TAP A BLOCK", style = techLabel(), color = AppColors.CyanDim)
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            segments.forEachIndexed { i, seg ->
                val tone = segmentColor(seg.kind)
                val isSel = selected == i
                Column(
                    Modifier
                        .clip(RoundedCornerShape(4.dp))
                        .background(if (isSel) tone.copy(alpha = 0.18f) else AppColors.Panel)
                        .border(1.dp, tone.copy(alpha = if (isSel) 1f else 0.45f), RoundedCornerShape(4.dp))
                        .clickable { selected = if (isSel) null else i }
                        .padding(horizontal = 6.dp, vertical = 4.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        if (seg.kind == DisneyTlv.SegmentKind.COLOR) {
                            val idx = seg.hex.toIntOrNull(16)?.and(0x1F) ?: 0
                            Box(Modifier.size(8.dp).clip(RoundedCornerShape(2.dp)).background(labSwatchColor(idx)))
                        }
                        Text(seg.hex.ifEmpty { "!" }, style = techLabel(), color = tone, maxLines = 1)
                    }
                    Text(seg.title.uppercase(), style = techLabel(), color = AppColors.TextDim, maxLines = 1)
                }
            }
        }
        selected?.let { i ->
            segments.getOrNull(i)?.let { seg ->
                Text(
                    seg.detail,
                    style = techLabel(),
                    color = segmentColor(seg.kind),
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(AppColors.Panel, RoundedCornerShape(4.dp))
                        .padding(8.dp),
                )
            }
        }
    }
}

/** Palette-index colour for Lab swatches (same table the wand glow uses). */
fun labSwatchColor(index: Int): Color = when (index and 0x1F) {
    0x00, 0x16, 0x17, 0x18 -> Color(0xFF00E5FF)
    0x01, 0x05, 0x07 -> Color(0xFFBA87FD)
    0x02, 0x03, 0x04 -> Color(0xFF458AFF)
    0x06 -> Color(0xFFE0BFE8)
    in 0x08..0x0E -> Color(0xFFFF4082)
    0x0F, 0x11 -> Color(0xFFFFAB40)
    0x10 -> Color(0xFFFFF59D)
    0x12, 0x1A -> Color(0xFFCCFF90)
    0x13, 0x14 -> Color(0xFFFF9900)
    0x15 -> Color(0xFFFF5252)
    0x19 -> Color(0xFF69F0AE)
    0x1B, 0x1C -> Color(0xFFD1F0FF)
    0x1D -> Color(0xFF4F4F4F)
    0x1E -> Color(0xFFCF93D9)
    else -> Color(0xFFB388FF)
}
