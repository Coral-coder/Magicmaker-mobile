package com.magicmaker.android.ui

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import com.magicmaker.android.service.ServiceState
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
            loadedHex = hex,
            loadTick = labLoadTick,
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

        HorizontalDivider(color = AppColors.PanelLine, thickness = 0.5.dp)
        RandomLightShowSection(ctx)

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

/**
 * Random light show — the service loops surprise packets (random type + colors, occasional
 * buzz) at a configurable interval until stopped. Runs in the foreground service, so it keeps
 * playing across tab switches and with the screen off.
 */
@Composable
private fun RandomLightShowSection(ctx: Context) {
    val svc by ServiceState.state.collectAsState()
    var intervalMs by remember { mutableFloatStateOf(ServiceState.state.value.randomShowIntervalMs.toFloat()) }

    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("RANDOM LIGHT SHOW", style = techHeader())
        Text(
            "Shoots a surprise packet — colors, duals, fades, rainbows, effects — on a loop until stopped.",
            style = techLabel(),
            color = AppColors.TextDim,
        )
        SettingSlider(
            committedValue = intervalMs,
            label = { displayMs ->
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("INTERVAL", style = techLabel())
                    Text("${displayMs.toInt()}ms", style = techLabel(), color = AppColors.Cyan)
                }
            },
            onCommit = { ms ->
                intervalMs = ms
                // Live-adjust the pace mid-show; otherwise just remembered for START.
                if (svc.randomShowEnabled) {
                    MagicMakerForegroundService.setRandomShow(ctx, true, ms.toLong())
                }
            },
            valueRange = 500f..30_000f,
            step = 250f,
        )
        Text(
            "Pause between packets (each packet also plays for the command burst time).",
            style = techLabel(),
            color = AppColors.TextDim,
        )
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(AppDimens.gap),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Button(
                onClick = {
                    MagicMakerForegroundService.setRandomShow(
                        ctx,
                        enabled = !svc.randomShowEnabled,
                        intervalMs = intervalMs.toLong(),
                    )
                },
                contentPadding = PaddingValues(horizontal = 14.dp, vertical = 0.dp),
                modifier = Modifier.height(32.dp),
            ) { Text(if (svc.randomShowEnabled) "STOP SHOW" else "START SHOW", style = techLabel()) }
            if (svc.randomShowEnabled) {
                Text(
                    svc.randomShowLabel.ifBlank { "Rolling the dice…" }.uppercase(),
                    style = techLabel(),
                    color = AppColors.Cyan,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
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

/**
 * Guided, type-first packet builder. The user starts by choosing ONE [LabPacketType]; only that
 * type's controls (its color slots + vibration) are then shown, so the screen is never cluttered by
 * other packet types' options. Loading a received packet ([loadTick] bump) decodes it straight into
 * these fields so its variables can be tweaked.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LabPacketBuilderPanel(
    loadedHex: String,
    loadTick: Int,
    onHexBuilt: (String) -> Unit,
    onTransmit: (String) -> Unit,
) {
    var selectedType by remember { mutableStateOf<LabPacketBuilder.LabPacketType?>(null) }
    var colors by remember { mutableStateOf(listOf<Int>()) }
    var vibEnabled by remember { mutableStateOf(true) }
    var vibPattern by remember { mutableIntStateOf(PacketBuilder.Vibration.TRIPLE) }
    var rawHex by remember { mutableStateOf("") }
    var loadMsg by remember { mutableStateOf<String?>(null) }

    fun applyDecoded(d: LabPacketBuilder.Decoded) {
        selectedType = d.type
        colors = if (d.colors.isNotEmpty()) d.colors else LabPacketBuilder.defaultColors(d.type)
        vibEnabled = d.vibEnabled
        vibPattern = d.vibPattern
        rawHex = d.rawHex
    }

    // A received packet was just loaded into the Lab — decode it into the fields for editing.
    LaunchedEffect(loadTick) {
        if (loadTick > 0) {
            runCatching { LabPacketBuilder.decode(loadedHex) }.getOrNull()?.let {
                applyDecoded(it)
                loadMsg = "Loaded ${it.type.label} from received packet"
            }
        }
    }

    fun selectType(type: LabPacketBuilder.LabPacketType) {
        selectedType = type
        colors = LabPacketBuilder.defaultColors(type)
        if (type == LabPacketBuilder.LabPacketType.RAW && rawHex.isBlank()) {
            rawHex = loadedHex
        }
        loadMsg = null
    }

    fun currentHex(): String =
        LabPacketBuilder.build(selectedType!!, colors, vibEnabled, vibPattern, rawHex)

    Column(verticalArrangement = Arrangement.spacedBy(AppDimens.gap)) {
        val type = selectedType
        if (type == null) {
            // ---- Step 1: choose a packet type ------------------------------------------------
            Text("STEP 1 · CHOOSE A PACKET TYPE", style = techLabel(), color = AppColors.CyanDim)
            FlowRowTypeGrid(onSelect = { selectType(it) })
            Spacer(Modifier.height(2.dp))
            OutlinedButton(
                onClick = {
                    val decoded = LabPacketBuilder.decode(loadedHex)
                    if (decoded != null) {
                        applyDecoded(decoded)
                        loadMsg = "Loaded ${decoded.type.label} from current hex"
                    } else {
                        loadMsg = "Nothing to load — hex field is empty"
                    }
                },
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp),
                modifier = Modifier.height(28.dp),
            ) { Text("LOAD CURRENT HEX INTO BUILDER", style = techLabel(), color = AppColors.Cyan) }
            loadMsg?.let { Text(it, style = techLabel(), color = AppColors.TextDim) }
        } else {
            // ---- Step 2: configure the chosen type ------------------------------------------
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(AppDimens.gap),
            ) {
                OutlinedButton(
                    onClick = { selectedType = null; loadMsg = null },
                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                    modifier = Modifier.height(28.dp),
                ) { Text("‹ TYPE", style = techLabel()) }
                Column(Modifier.weight(1f)) {
                    Text(type.label.uppercase(), style = techHeader())
                    Text(type.blurb, style = techLabel(), color = AppColors.TextDim, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }

            loadMsg?.let { Text(it, style = techLabel(), color = AppColors.Cyan) }

            when (type) {
                LabPacketBuilder.LabPacketType.RAW -> {
                    OutlinedTextField(
                        rawHex,
                        { rawHex = it.uppercase() },
                        label = { Text("RAW HEX", style = techLabel()) },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                        textStyle = techLabel().copy(color = AppColors.CyanDim),
                    )
                }
                LabPacketBuilder.LabPacketType.PING -> {
                    Text(
                        "No options — this wakes nearby bands. Send it just before a command if a band isn't reacting.",
                        style = techLabel(),
                        color = AppColors.TextDim,
                    )
                }
                else -> {
                    if (type.colorSlots > 0) {
                        Text(
                            if (type.colorSlots == 1) "STEP 2 · PICK A COLOR" else "STEP 2 · PICK ${type.colorSlots} COLORS",
                            style = techLabel(),
                            color = AppColors.CyanDim,
                        )
                        ColorSlots(type, colors, onChange = { colors = it })
                    }
                    if (type.supportsVib) {
                        Text("STEP 3 · VIBRATION", style = techLabel(), color = AppColors.CyanDim)
                        Row(
                            Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(AppDimens.gap),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Switch(vibEnabled, { vibEnabled = it }, modifier = Modifier.height(24.dp))
                            PaletteDropdown(
                                label = "PATTERN",
                                selectedId = vibPattern,
                                options = LabPacketBuilder.vibrationPatterns.map { it.id to it.label },
                                onSelect = { vibPattern = it },
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                }
            }

            // ---- Build / send actions ---------------------------------------------------------
            Row(horizontalArrangement = Arrangement.spacedBy(AppDimens.gap)) {
                Button(
                    onClick = { onTransmit(currentHex()) },
                    contentPadding = PaddingValues(horizontal = 14.dp, vertical = 0.dp),
                    modifier = Modifier.height(32.dp),
                ) { Text("SEND NOW", style = techLabel()) }
                OutlinedButton(
                    onClick = { onHexBuilt(currentHex()) },
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 0.dp),
                    modifier = Modifier.height(32.dp),
                ) { Text("BUILD → HEX", style = techLabel(), color = AppColors.Cyan) }
            }
        }
    }
}

/** The packet-type chooser — one chip per [LabPacketBuilder.LabPacketType]. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun FlowRowTypeGrid(onSelect: (LabPacketBuilder.LabPacketType) -> Unit) {
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        LabPacketBuilder.LabPacketType.entries.forEach { type ->
            OutlinedButton(
                onClick = { onSelect(type) },
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp),
            ) { Text(type.label.uppercase(), style = techLabel(), color = AppColors.Cyan) }
        }
    }
}

/** One palette dropdown per color slot the [type] carries; full palette available for each. */
@Composable
private fun ColorSlots(
    type: LabPacketBuilder.LabPacketType,
    colors: List<Int>,
    onChange: (List<Int>) -> Unit,
) {
    val slotLabels: (Int) -> String = when (type) {
        LabPacketBuilder.LabPacketType.DUAL -> { i -> if (i == 0) "INNER" else "OUTER" }
        LabPacketBuilder.LabPacketType.CROSSFADE -> { i -> if (i == 0) "FROM" else "TO" }
        else -> { i -> "${i + 1}" }
    }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        for (i in 0 until type.colorSlots) {
            PaletteDropdown(
                label = slotLabels(i),
                selectedId = colors.getOrElse(i) { 0 },
                options = paletteOptions(),
                onSelect = { picked -> onChange(colors.toMutableList().also { it[i] = picked }) },
                modifier = Modifier.fillMaxWidth(),
            )
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
