package com.magicmaker.android.ui

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.magicmaker.android.MagicMakerApp
import com.magicmaker.android.core.HexUtils
import com.magicmaker.android.core.LabPacketBuilder
import com.magicmaker.android.core.LabPacketTools
import com.magicmaker.android.core.MagicClassifier
import com.magicmaker.android.core.PacketBuilder
import com.magicmaker.android.core.TransmitTiming
import com.magicmaker.android.data.MagicStore
import com.magicmaker.android.service.MagicMakerForegroundService
import androidx.compose.ui.platform.LocalContext

@Composable
fun LabTabScreen(app: MagicMakerApp, ctx: Context, storeRev: Int = 0, labLoadTick: Int = 0) {
    var hex by remember(labLoadTick) { mutableStateOf(app.store.getLabHex()) }
    var label by remember(labLoadTick) { mutableStateOf(app.store.getLabLabel()) }
    var presetMsg by remember { mutableStateOf<String?>(null) }
    val scroll = rememberScrollState()
    val myPresets = remember(storeRev) { app.store.customPresets }

    Column(Modifier.fillMaxSize()) {
        Column(
            Modifier
                .weight(1f)
                .verticalScroll(scroll)
                .padding(AppDimens.pad),
            verticalArrangement = Arrangement.spacedBy(AppDimens.gap),
        ) {
        Text("PACKET BUILDER", style = techHeader())
        Text(
            "esp32_magicband payload composer — builds 8301… hex for TX",
            style = techLabel(),
            color = AppColors.TextDim,
        )

        LabPacketBuilderPanel(
            onHexBuilt = { built ->
                hex = built
                app.store.saveLabHex(built)
            },
            onTransmit = { built ->
                hex = built
                app.store.saveLabHex(built)
                MagicMakerForegroundService.transmit(ctx, built)
            },
        )

        HorizontalDivider(color = AppColors.PanelLine, thickness = 0.5.dp)

        OutlinedTextField(
            hex,
            { hex = it.uppercase() },
            label = { Text("HEX OUTPUT", style = techLabel()) },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            textStyle = techLabel().copy(color = AppColors.CyanDim),
        )
        OutlinedTextField(
            label,
            { label = it },
            label = { Text("LABEL", style = techLabel()) },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            textStyle = techLabel(),
        )

        HexUtils.legacyAdvertiseRejectReason(hex)?.let { reason ->
            Text(reason, style = techLabel(), color = MaterialTheme.colorScheme.error)
        }

        PacketInspector(
            hex = hex,
            onHexChange = { built ->
                hex = built
                app.store.saveLabHex(built)
            },
        )

        Row(horizontalArrangement = Arrangement.spacedBy(AppDimens.gap)) {
            Button({
                app.store.saveLabHex(hex)
                app.store.saveLabLabel(label)
                MagicMakerForegroundService.transmit(ctx, hex)
            }) { Text("SEND", style = techLabel()) }
            OutlinedButton({
                app.store.saveLabHex(hex)
                app.store.saveLabLabel(label)
                val err = app.store.saveCustomPreset(label, hex)
                presetMsg = err ?: "Saved preset — see TX + Auto tabs"
            }) { Text("SAVE", style = techLabel()) }
            OutlinedButton({
                app.store.saveLabHex(hex)
                app.store.saveLabLabel(label)
                app.store.applyLabLabelToMatchingRaw()
                presetMsg = "Raw tag updated"
            }) { Text("TAG", style = techLabel()) }
        }

        presetMsg?.let { msg ->
            Text(
                msg,
                style = techLabel(),
                color = if (msg.startsWith("Saved")) AppColors.Cyan else AppColors.TextDim,
            )
        }

        if (myPresets.isNotEmpty()) {
            HorizontalDivider(color = AppColors.PanelLine, thickness = 0.5.dp)
            Text("MY PRESETS (${myPresets.size})", style = techHeader())
            myPresets.sortedBy { it.label.lowercase() }.forEach { preset ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable {
                            hex = preset.hex
                            label = preset.label
                            app.store.saveLabHex(preset.hex)
                            app.store.saveLabLabel(preset.label)
                        },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(preset.label.uppercase(), style = techLabel(), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(
                            preset.hex,
                            style = techLabel(),
                            color = AppColors.CyanDim,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    IconButton(onClick = { app.store.deleteCustomPreset(preset.id); presetMsg = "Preset deleted" }) {
                        Icon(Icons.Default.Delete, contentDescription = "Delete preset", modifier = Modifier.size(16.dp))
                    }
                }
                HorizontalDivider(color = AppColors.PanelLine, thickness = 0.5.dp)
            }
        }
        }
    }
}

/** Dedicated Settings page — global transmission tuning lives here, not scattered in tabs. */
@Composable
fun SettingsTabScreen(app: MagicMakerApp, storeRev: Int = 0) {
    val scroll = rememberScrollState()
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(scroll)
            .padding(AppDimens.pad),
        verticalArrangement = Arrangement.spacedBy(AppDimens.gap),
    ) {
        Text("SETTINGS", style = techHeader())
        Text(
            "Global transmission tuning — applies to every TX.",
            style = techLabel(),
            color = AppColors.TextDim,
        )
        TransmissionSettingsSection(app.store, storeRev = storeRev)
    }
}

@Composable
private fun TransmissionSettingsSection(
    store: MagicStore,
    storeRev: Int = 0,
    modifier: Modifier = Modifier,
) {
    val ctx = LocalContext.current
    var collapsed by remember { mutableStateOf(UiPrefs.isLabTransmissionSettingsCollapsed(ctx)) }
    var preambleMs by remember { mutableFloatStateOf(store.getWakeupPreambleMs().toFloat()) }
    var burstMs by remember { mutableFloatStateOf(store.getCommandBurstMs().toFloat()) }
    var starlightMs by remember { mutableFloatStateOf(store.getStarlightBurstMs().toFloat()) }
    var interleave by remember { mutableStateOf(store.getTxInterleave()) }
    var txPower by remember { mutableIntStateOf(store.getTxPowerLevel()) }

    LaunchedEffect(storeRev) {
        preambleMs = store.getWakeupPreambleMs().toFloat()
        burstMs = store.getCommandBurstMs().toFloat()
        starlightMs = store.getStarlightBurstMs().toFloat()
        interleave = store.getTxInterleave()
        txPower = store.getTxPowerLevel()
    }

    LaunchedEffect(collapsed) { UiPrefs.saveLabTransmissionSettingsCollapsed(ctx, collapsed) }

    Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(
            Modifier
                .fillMaxWidth()
                .clickable { collapsed = !collapsed }
                .padding(vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                if (collapsed) Icons.Default.ExpandMore else Icons.Default.ExpandLess,
                contentDescription = null,
                modifier = Modifier.size(16.dp),
            )
            Text("TRANSMISSION SETTINGS", style = techHeader(), modifier = Modifier.weight(1f).padding(start = 4.dp))
        }
        if (!collapsed) {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    if (interleave) "TX MODE: INTERLEAVE" else "TX MODE: SUSTAINED",
                    style = techLabel(),
                    color = AppColors.Cyan,
                )
                Switch(
                    checked = interleave,
                    onCheckedChange = { interleave = it; store.saveTxInterleave(it) },
                    modifier = Modifier.height(24.dp),
                )
            }
            Text(
                if (interleave) {
                    "Alternates wake/command slices — lighter, good in-park. WAKE=slice, COMMAND=total window."
                } else {
                    "Sustained wake stream, then command stream — strongest wake. WAKE=wake length, COMMAND=command length."
                },
                style = techLabel(),
                color = AppColors.TextDim,
            )
            Spacer(Modifier.height(4.dp))
            Text("BROADCAST STRENGTH", style = techLabel(), color = AppColors.TextDim)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                listOf("MIN", "LOW", "MED", "MAX").forEachIndexed { idx, name ->
                    OutlinedButton(
                        onClick = { txPower = idx; store.saveTxPowerLevel(idx) },
                        modifier = Modifier.weight(1f).height(28.dp),
                        contentPadding = PaddingValues(horizontal = 4.dp, vertical = 0.dp),
                    ) {
                        Text(name, style = techLabel(), color = if (txPower == idx) AppColors.Cyan else AppColors.TextDim)
                    }
                }
            }
            Text(
                "Lower = shorter range, fewer nearby bands react · default MAX",
                style = techLabel(),
                color = AppColors.TextDim,
            )
            Spacer(Modifier.height(4.dp))
            SettingSlider(
                committedValue = preambleMs,
                label = { displayMs ->
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("WAKE SLICE", style = techLabel())
                        Text("${displayMs.toInt()}ms", style = techLabel(), color = AppColors.Cyan)
                    }
                },
                onCommit = { ms ->
                    preambleMs = ms
                    store.saveWakeupPreambleMs(ms.toInt())
                },
                valueRange = TransmitTiming.MIN_WAKEUP_PRELUDE_MS.toFloat()..TransmitTiming.MAX_WAKEUP_PRELUDE_MS.toFloat(),
                step = 50f,
            )
            Text(
                "Each wake/command slice in the 1:1 interleave · default ${TransmitTiming.DEFAULT_WAKEUP_PRELUDE_MS}ms",
                style = techLabel(),
                color = AppColors.TextDim,
            )
            Spacer(Modifier.height(4.dp))
            SettingSlider(
                committedValue = burstMs,
                label = { displayMs ->
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("COMMAND BURST", style = techLabel())
                        Text("${displayMs.toInt()}ms", style = techLabel(), color = AppColors.Cyan)
                    }
                },
                onCommit = { ms ->
                    burstMs = ms
                    store.saveCommandBurstMs(ms.toInt())
                },
                valueRange = TransmitTiming.MIN_COMMAND_BURST_MS.toFloat()..TransmitTiming.MAX_COMMAND_BURST_MS.toFloat(),
                step = 50f,
            )
            Text(
                "Total wake+command interleave window · default ${TransmitTiming.COMMAND_BURST_MS}ms · global",
                style = techLabel(),
                color = AppColors.TextDim,
            )
            Spacer(Modifier.height(4.dp))
            SettingSlider(
                committedValue = starlightMs,
                label = { displayMs ->
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("STARLIGHT WAND", style = techLabel())
                        Text("${displayMs.toInt()}ms", style = techLabel(), color = AppColors.Cyan)
                    }
                },
                onCommit = { ms ->
                    starlightMs = ms
                    store.saveStarlightBurstMs(ms.toInt())
                },
                valueRange = TransmitTiming.MIN_STARLIGHT_BURST_MS.toFloat()..TransmitTiming.MAX_STARLIGHT_BURST_MS.toFloat(),
                steps = 18,
            )
            Text(
                "On-air time for starlight wand TX · no band wakeup · default ${TransmitTiming.STARLIGHT_BURST_MS}ms",
                style = techLabel(),
                color = AppColors.TextDim,
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LabPacketBuilderPanel(
    onHexBuilt: (String) -> Unit,
    onTransmit: (String) -> Unit,
) {
    var vibEnabled by remember { mutableStateOf(true) }
    var vibPattern by remember { mutableIntStateOf(PacketBuilder.Vibration.TRIPLE) }
    var dualC1 by remember { mutableStateOf(PacketBuilder.Color.YELLOW_ORANGE) }
    var dualC2 by remember { mutableStateOf(PacketBuilder.Color.BLUE) }
    var crossC1 by remember { mutableStateOf(PacketBuilder.Color.RED) }
    var crossC2 by remember { mutableStateOf(PacketBuilder.Color.BLUE) }
    var rainbow by remember {
        mutableStateOf(
            listOf(
                PacketBuilder.Color.YELLOW_ORANGE,
                PacketBuilder.Color.RED,
                PacketBuilder.Color.GREEN,
                PacketBuilder.Color.BLUE,
                PacketBuilder.Color.PURPLE,
            ),
        )
    }

    Column(verticalArrangement = Arrangement.spacedBy(AppDimens.gap)) {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(AppDimens.gap),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("VIB", style = techLabel(), color = AppColors.TextDim)
            Switch(vibEnabled, { vibEnabled = it }, modifier = Modifier.height(24.dp))
            PaletteDropdown(
                label = "PAT",
                selectedId = vibPattern,
                options = LabPacketBuilder.vibrationPatterns.map { it.id to it.label },
                onSelect = { vibPattern = it },
                modifier = Modifier.weight(1f),
            )
            OutlinedButton(
                onClick = { onTransmit(LabPacketBuilder.buildPing()) },
                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                modifier = Modifier.height(28.dp),
            ) { Text("WAKE", style = techLabel()) }
        }

        Text("PRESETS", style = techLabel(), color = AppColors.CyanDim)
        Text("PRIMARY", style = techLabel(), color = AppColors.TextDim)
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            LabPacketBuilder.primaryPresetColors.forEach { color ->
                OutlinedButton(
                    onClick = {
                        val built = LabPacketBuilder.buildPresetById(color.id, vibEnabled, vibPattern)
                        onTransmit(built)
                    },
                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                    modifier = Modifier.height(28.dp),
                ) { Text(color.label.uppercase(), style = techLabel()) }
            }
        }
        Text("FULL PALETTE (0x00–0x1F)", style = techLabel(), color = AppColors.TextDim)
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            LabPacketBuilder.paletteColors.forEach { color ->
                OutlinedButton(
                    onClick = {
                        val built = LabPacketBuilder.buildPresetById(color.id, vibEnabled, vibPattern)
                        onTransmit(built)
                    },
                    contentPadding = PaddingValues(horizontal = 6.dp, vertical = 0.dp),
                    modifier = Modifier.height(28.dp),
                ) {
                    Text(
                        color.label,
                        style = techLabel(),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }

        BuilderCard("DUAL COLOR") {
            Row(horizontalArrangement = Arrangement.spacedBy(AppDimens.gap)) {
                PaletteDropdown("IN", dualC1, paletteOptions(), onSelect = { dualC1 = it })
                PaletteDropdown("OUT", dualC2, paletteOptions(), onSelect = { dualC2 = it })
            }
            BuilderSendButton("BUILD DUAL") {
                onHexBuilt(LabPacketBuilder.buildDual(dualC1, dualC2, vibEnabled, vibPattern))
            }
        }

        BuilderCard("CROSSFADE") {
            Row(horizontalArrangement = Arrangement.spacedBy(AppDimens.gap)) {
                PaletteDropdown("A", crossC1, paletteOptions(), onSelect = { crossC1 = it })
                PaletteDropdown("B", crossC2, paletteOptions(), onSelect = { crossC2 = it })
            }
            BuilderSendButton("BUILD XFADE") {
                onHexBuilt(LabPacketBuilder.buildCrossfade(crossC1, crossC2, vibEnabled, vibPattern))
            }
        }

        BuilderCard("RAINBOW ×5") {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                rainbow.forEachIndexed { index, colorId ->
                    PaletteDropdown(
                        label = "${index + 1}",
                        selectedId = colorId,
                        options = paletteOptions(),
                        onSelect = { picked ->
                            rainbow = rainbow.toMutableList().also { it[index] = picked }
                        },
                        modifier = Modifier.widthIn(min = 88.dp),
                    )
                }
            }
            BuilderSendButton("BUILD RAINBOW") {
                onHexBuilt(
                    LabPacketBuilder.buildRainbow(
                        rainbow[0], rainbow[1], rainbow[2], rainbow[3], rainbow[4],
                        vibEnabled, vibPattern,
                    ),
                )
            }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(AppDimens.gap)) {
            BuilderCard("CIRCLE", modifier = Modifier.weight(1f)) {
                BuilderSendButton("BUILD CIRCLE") {
                    onHexBuilt(LabPacketBuilder.buildCircle(vibEnabled, vibPattern))
                }
            }
            BuilderCard("FINALE", modifier = Modifier.weight(1f)) {
                BuilderSendButton("RAINBOW FX") {
                    onHexBuilt(LabPacketBuilder.buildRainbowFinale())
                }
            }
            BuilderCard("VIB ONLY", modifier = Modifier.weight(1f)) {
                BuilderSendButton("VIB BAND") {
                    onTransmit(LabPacketBuilder.buildVibrate(vibEnabled, vibPattern))
                }
            }
        }

        BuilderCard("SHOW FX") {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                LabPacketBuilder.showEffects.forEach { (label, hex) ->
                    OutlinedButton(
                        onClick = { onTransmit(hex) },
                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                        modifier = Modifier.height(28.dp),
                    ) { Text(label.uppercase(), style = techLabel()) }
                }
            }
        }
    }
}

/**
 * Fine-grained editor for whatever hex is currently loaded — live classification, full
 * vibration control (0–15), and a per-byte hex grid so any field can be tweaked. Kept
 * collapsed by default to keep the builder uncluttered.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun PacketInspector(hex: String, onHexChange: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val classified = remember(hex) { runCatching { MagicClassifier.classify(HexUtils.canonicalHex(hex)) }.getOrNull() }
    val bytes = remember(hex) { LabPacketTools.toBytes(hex) }
    val vib = remember(hex) { LabPacketTools.tailVibration(hex) }

    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(
            Modifier.fillMaxWidth().clickable { expanded = !expanded }.padding(vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                contentDescription = null,
                modifier = Modifier.size(16.dp),
            )
            Text("PACKET INSPECTOR", style = techHeader(), modifier = Modifier.weight(1f).padding(start = 4.dp))
            Text("${bytes.size} B", style = techLabel(), color = AppColors.TextDim)
        }

        Text(
            classified?.let { "${it.label} · ${it.category.name}" } ?: "Unclassified / raw payload",
            style = techLabel(),
            color = if (classified != null) AppColors.Cyan else AppColors.TextDim,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        val classColors = classified?.colors
        if (!classColors.isNullOrBlank()) {
            Text("COLORS: ${classColors.uppercase()}", style = techLabel(), color = AppColors.CyanDim)
        }

        if (expanded) {
            if (vib != null) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text("VIBRATION", style = techLabel(), color = AppColors.TextDim)
                    OutlinedButton(
                        onClick = { onHexChange(LabPacketTools.withVibration(hex, (vib - 1).coerceAtLeast(0))) },
                        enabled = vib > 0,
                        contentPadding = PaddingValues(0.dp),
                        modifier = Modifier.size(28.dp),
                    ) { Text("–", style = techLabel()) }
                    Text(vib.toString().padStart(2, '0'), style = techLabel(), color = AppColors.Cyan)
                    OutlinedButton(
                        onClick = { onHexChange(LabPacketTools.withVibration(hex, (vib + 1).coerceAtMost(15))) },
                        enabled = vib < 15,
                        contentPadding = PaddingValues(0.dp),
                        modifier = Modifier.size(28.dp),
                    ) { Text("+", style = techLabel()) }
                    Text("0xB0 | vib", style = techLabel(), color = AppColors.TextDim)
                }
            }

            Text("RAW BYTES — tap to edit", style = techLabel(), color = AppColors.CyanDim)
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                bytes.forEachIndexed { i, b ->
                    OutlinedTextField(
                        value = b,
                        onValueChange = { v ->
                            val nv = v.uppercase().filter { it in "0123456789ABCDEF" }.take(2)
                            val updated = bytes.toMutableList().also { it[i] = nv }
                            onHexChange(LabPacketTools.fromBytes(updated))
                        },
                        singleLine = true,
                        textStyle = techLabel().copy(color = AppColors.CyanDim),
                        modifier = Modifier.width(56.dp),
                    )
                }
            }
            Text(
                "Color bytes use low 5 bits (00–1F). E0=preset · 80/80=dual · A0×5=rainbow · 40/40=xfade · tail B0|vib.",
                style = techLabel(),
                color = AppColors.TextDim,
            )
        }
    }
}

@Composable
private fun BuilderCard(title: String, modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier
            .fillMaxWidth()
            .padding(4.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(title, style = techLabel(), color = AppColors.CyanDim)
        content()
    }
}

@Composable
private fun BuilderSendButton(text: String, onClick: () -> Unit) {
    OutlinedButton(
        onClick = onClick,
        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp),
        modifier = Modifier.height(28.dp),
    ) { Text(text, style = techLabel(), color = AppColors.Cyan) }
}

private fun paletteOptions(): List<Pair<Int, String>> =
    LabPacketBuilder.paletteColors.map { it.id to it.label }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PaletteDropdown(
    label: String,
    selectedId: Int,
    options: List<Pair<Int, String>>,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    var expanded by remember { mutableStateOf(false) }
    val selectedLabel = options.firstOrNull { it.first == selectedId }?.second ?: "?"

    ExposedDropdownMenuBox(expanded, { expanded = it }, modifier = modifier) {
        OutlinedButton(
            onClick = { expanded = true },
            modifier = Modifier.menuAnchor().height(28.dp).fillMaxWidth(),
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
        ) {
            Text("$label: $selectedLabel", style = techLabel(), maxLines = 1)
        }
        ExposedDropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = Modifier.background(AppColors.Panel),
        ) {
            options.forEach { (id, name) ->
                DropdownMenuItem(
                    text = { Text(name, style = techLabel()) },
                    onClick = {
                        onSelect(id)
                        expanded = false
                    },
                )
            }
        }
    }
}
