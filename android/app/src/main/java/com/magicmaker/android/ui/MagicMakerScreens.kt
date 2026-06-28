package com.magicmaker.android.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.magicmaker.android.MagicMakerApp
import com.magicmaker.android.core.*
import com.magicmaker.android.service.AllFilesAccess
import com.magicmaker.android.service.BatteryOptimization
import com.magicmaker.android.service.MagicMakerForegroundService
import com.magicmaker.android.service.ServiceState
import com.magicmaker.android.relay.RelayPairingPayload
import com.magicmaker.android.relay.RelayProtocol
import kotlinx.coroutines.launch

private enum class AppTab(val label: String) {
    Scan("SCAN"),
    Transmit("TX"),
    Wand("WAND"),
    Auto("AUTO"),
    Relay("RELAY"),
    Logs("LOGS"),
    Map("MAP"),
    Diagnostics("DIAG"),
    Lab("LAB"),
}

private fun tabIcon(t: AppTab): ImageVector = when (t) {
    AppTab.Scan -> Icons.Default.BluetoothSearching
    AppTab.Transmit -> Icons.Default.Send
    AppTab.Wand -> Icons.Default.AutoAwesome
    AppTab.Auto -> Icons.Default.AutoMode
    AppTab.Relay -> Icons.Default.Wifi
    AppTab.Logs -> Icons.Default.History
    AppTab.Map -> Icons.Default.Place
    AppTab.Diagnostics -> Icons.Default.Insights
    AppTab.Lab -> Icons.Default.Science
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MagicMakerAppRoot() {
    val context = LocalContext.current
    val app = context.applicationContext as MagicMakerApp
    var state by remember { mutableStateOf(ServiceState.state.value) }
    var tab by remember { mutableStateOf(AppTab.Scan) }

    DisposableEffect(Unit) {
        val l: (ServiceState.UiState) -> Unit = { state = it }
        ServiceState.addListener(l)
        onDispose { ServiceState.removeListener(l) }
    }

    val corePerms = remember {
        buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                add(Manifest.permission.BLUETOOTH_SCAN)
                add(Manifest.permission.BLUETOOTH_ADVERTISE)
                add(Manifest.permission.BLUETOOTH_CONNECT)
            }
            add(Manifest.permission.ACCESS_FINE_LOCATION)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
    }
    val wifiPerms = remember {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            listOf(Manifest.permission.NEARBY_WIFI_DEVICES)
        } else {
            emptyList()
        }
    }
    val allPerms = remember { corePerms + wifiPerms }
    var coreGranted by remember {
        mutableStateOf(corePerms.all { ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED })
    }
    var wifiGranted by remember {
        mutableStateOf(
            wifiPerms.isEmpty() || wifiPerms.all {
                ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
            },
        )
    }
    val permLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { r ->
        coreGranted = corePerms.all { r[it] == true || ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED }
        wifiGranted = wifiPerms.isEmpty() || wifiPerms.all {
            ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
        }
        if (coreGranted) MagicMakerForegroundService.start(context)
    }
    val wifiPermLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { _ ->
        wifiGranted = wifiPerms.isEmpty() || wifiPerms.all {
            ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
        }
        if (wifiGranted && state.relayMode == RelayControlMode.WIFI_HOTSPOT) {
            MagicMakerForegroundService.send(context, MagicMakerForegroundService.ACTION_SET_RELAY) {
                putExtra(MagicMakerForegroundService.EXTRA_RELAY_MODE, RelayControlMode.WIFI_HOTSPOT.name)
            }
        }
    }
    LaunchedEffect(coreGranted) {
        if (coreGranted && !state.running) MagicMakerForegroundService.start(context)
        if (coreGranted && !BatteryOptimization.isIgnored(context)) {
            context.startActivity(BatteryOptimization.requestIgnoreIntent(context))
        }
    }

    Scaffold(
        containerColor = AppColors.Navy,
        topBar = {
            Column {
                TopAppBar(
                    title = { Text("MAGICMAKER · ${tab.label}", style = techHeader()) },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = AppColors.Panel,
                        titleContentColor = AppColors.Cyan,
                    ),
                )
                ScrollableTabRow(
                    selectedTabIndex = AppTab.entries.indexOf(tab).coerceAtLeast(0),
                    containerColor = AppColors.Panel,
                    contentColor = AppColors.Cyan,
                    edgePadding = 4.dp,
                    divider = { HorizontalDivider(color = AppColors.PanelLine, thickness = 0.5.dp) },
                ) {
                    AppTab.entries.forEach { t ->
                        LeadingIconTab(
                            selected = tab == t,
                            onClick = { tab = t },
                            selectedContentColor = AppColors.Cyan,
                            unselectedContentColor = AppColors.TextDim,
                            icon = {
                                Icon(tabIcon(t), contentDescription = t.label, modifier = Modifier.size(AppDimens.icon))
                            },
                            text = { Text(t.label, style = techLabel(), maxLines = 1) },
                        )
                    }
                }
            }
        },
    ) { pad ->
        Column(Modifier.padding(pad).fillMaxSize()) {
            TelemetryLine(state)
            if (!coreGranted) {
                Column(Modifier.padding(AppDimens.pad)) {
                    Text("PERMS REQUIRED: BT · LOC · NOTIFY", style = techLabel(), color = AppColors.Amber)
                    Spacer(Modifier.height(AppDimens.gap))
                    OutlinedButton({ permLauncher.launch(allPerms.toTypedArray()) }) { Text("GRANT", style = techLabel()) }
                }
            } else {
                val loadInLab: (String, String) -> Unit = { hex, label ->
                    app.store.saveLabHex(HexUtils.canonicalHex(hex))
                    app.store.saveLabLabel(label)
                    ServiceState.requestLabLoad()
                    tab = AppTab.Lab
                }
                when (tab) {
                    AppTab.Scan -> ScanTab(state, loadInLab)
                    AppTab.Transmit -> TransmitTab(app, state, loadInLab)
                    AppTab.Wand -> WandTab(
                        app = app,
                        storeRevision = state.storeRevision,
                        starlightLoopEnabled = state.starlightLoopEnabled,
                        starlightLoopPacketId = state.starlightLoopPacketId,
                        starlightIntervalMs = state.starlightIntervalMs,
                        wandDisplayColorIndex = state.wandDisplayColorIndex,
                        running = state.running,
                    )
                    AppTab.Auto -> AutoTab(app, state)
                    AppTab.Relay -> RelayTab(state, coreGranted, wifiGranted) { wifiPermLauncher.launch(wifiPerms.toTypedArray()) }
                    AppTab.Logs -> LogsTab(app, state)
                    AppTab.Map -> MapTab(app, state.storeRevision)
                    AppTab.Diagnostics -> DiagnosticsTab(state)
                    AppTab.Lab -> LabTabScreen(app, LocalContext.current, state.storeRevision, state.labLoadTick)
                }
            }
        }
    }
}

@Composable
private fun TelemetryLine(state: ServiceState.UiState) {
    val ble = when {
        !state.running -> "BLE:OFF"
        state.scanActive -> "BLE:SCAN"
        else -> "BLE:LINK"
    }
    Column(Modifier.fillMaxWidth()) {
        Text(
            buildString {
                append("MM/RF ")
                append(ble)
                append(" | RX:")
                append(state.packetsHeard)
                append(" | TX-AUTO:")
                append(state.autoResponsesSent)
                if (state.scanActive) append(" | SCAN:ON")
                if (state.autoEnabled) append(" | AUTO:ARM")
                if (state.recordSessionActive) append(" | LOG:REC")
                if (state.starlightLoopEnabled) append(" | WAND:LOOP")
                if (state.txLoopEnabled) append(" | TX:LOOP")
                if (state.relayLinked) append(" | IPHONE:LINK")
            },
            style = techLabel(),
            color = AppColors.TextDim,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(horizontal = AppDimens.pad, vertical = 2.dp),
        )
        HorizontalDivider(color = AppColors.PanelLine, thickness = 1.dp)
    }
}

private enum class ScanViewMode(val label: String) {
    GROUPED("GROUPED"),
    RAW("RAW"),
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SectionFilterDropdown(
    visible: Set<LivePacketSection>,
    onToggle: (LivePacketSection) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val summary = "CLASS ${visible.size}/${LivePacketSection.entries.size}"
    ExposedDropdownMenuBox(expanded, { expanded = it }) {
        OutlinedButton(
            onClick = { expanded = true },
            modifier = Modifier.menuAnchor().height(28.dp),
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
        ) {
            Text(summary, style = techLabel(), color = AppColors.Cyan)
            Icon(Icons.Default.ArrowDropDown, null, Modifier.size(14.dp), tint = AppColors.Cyan)
        }
        ExposedDropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = Modifier.background(AppColors.Panel),
        ) {
            LivePacketSection.entries.forEach { section ->
                DropdownMenuItem(
                    text = {
                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                            Checkbox(
                                checked = section in visible,
                                onCheckedChange = null,
                                modifier = Modifier.size(32.dp),
                                colors = CheckboxDefaults.colors(
                                    checkedColor = AppColors.Cyan,
                                    checkmarkColor = AppColors.Navy,
                                ),
                            )
                            Text(section.title.uppercase(), style = techLabel(), modifier = Modifier.weight(1f))
                        }
                    },
                    onClick = { onToggle(section) },
                )
            }
        }
    }
}

@Composable
private fun TxLoopSettingsSection(
    collapsed: Boolean,
    onToggleCollapsed: () -> Unit,
    loopOn: Boolean,
    onLoopOnChange: (Boolean) -> Unit,
    loopEnabled: Boolean,
    intervalSec: Float,
    onIntervalCommit: (Float) -> Unit,
    statusLabel: String?,
) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(
            Modifier
                .fillMaxWidth()
                .clickable(onClick = onToggleCollapsed)
                .padding(vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                if (collapsed) Icons.Default.ExpandMore else Icons.Default.ExpandLess,
                contentDescription = null,
                modifier = Modifier.size(16.dp),
            )
            Text(
                if (collapsed) "TX LOOP SETTINGS" else "HIDE TX LOOP",
                style = techLabel(),
                modifier = Modifier.padding(start = 4.dp),
            )
            Spacer(Modifier.weight(1f))
            statusLabel?.let {
                Text(it, style = techLabel(), color = AppColors.TextDim, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        if (!collapsed) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("LOOP", Modifier.weight(1f), style = techHeader())
                Switch(
                    loopOn,
                    onLoopOnChange,
                    enabled = loopEnabled,
                    modifier = Modifier.height(32.dp),
                )
            }
            SettingSlider(
                committedValue = intervalSec,
                label = { displaySec ->
                    Text(
                        "${"%.1f".format(displaySec)}S INTERVAL",
                        style = techLabel(),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                },
                onCommit = onIntervalCommit,
                valueRange = 0.5f..30f,
                steps = 59,
            )
        }
    }
}

@Composable
private fun CollapsibleSectionHeader(
    title: String,
    count: Int,
    collapsed: Boolean,
    onClick: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            if (collapsed) Icons.Default.ExpandMore else Icons.Default.ExpandLess,
            contentDescription = null,
            modifier = Modifier.size(16.dp),
        )
        Text(title.uppercase(), style = techHeader(), modifier = Modifier.weight(1f).padding(start = 4.dp))
        Text(String.format("%03d", count), style = techLabel(), color = AppColors.TextDim)
    }
}

private data class ScanDeleteRequest(
    val packet: ServiceState.LivePacket,
    val raw: Boolean,
)

@Composable
private fun ConfirmDeleteDialog(
    title: String,
    label: String,
    hex: String? = null,
    confirmLabel: String = "DELETE",
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title, style = techLabel()) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(label.uppercase(), style = techLabel())
                if (!hex.isNullOrEmpty()) {
                    Text(hex, style = techLabel(), color = AppColors.CyanDim, maxLines = 2)
                }
            }
        },
        confirmButton = {
            TextButton(onConfirm) {
                Text(confirmLabel, style = techLabel(), color = MaterialTheme.colorScheme.error)
            }
        },
        dismissButton = {
            TextButton(onDismiss) { Text("CANCEL", style = techLabel()) }
        },
    )
}

private fun liveSubtitle(pkt: ServiceState.LivePacket, includeNote: Boolean): String {
    val sb = StringBuilder("RSSI ${pkt.rssi}")
    if (pkt.address.isNotEmpty()) sb.append(" · ${pkt.address}")
    if (pkt.isBand) sb.append(" · BAND")
    if (includeNote && pkt.note.isNotEmpty()) sb.append(" | ${pkt.note}")
    return sb.toString()
}

@Composable
private fun BandConfigSection(app: MagicMakerApp, state: ServiceState.UiState) {
    val ctx = LocalContext.current
    val storeRev = state.storeRevision
    val bandAddrs = remember(storeRev) { app.store.bandAddresses() }
    val savedBands = remember(storeRev) { app.store.savedBandCount() }
    var manual by remember { mutableStateOf("") }
    var collapsed by remember { mutableStateOf(UiPrefs.isBandMenuCollapsed(ctx)) }
    var confirmDeleteBands by remember { mutableStateOf(false) }

    Surface(color = AppColors.Cyan.copy(alpha = 0.06f), shape = RectangleShape) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            CollapsibleSectionHeader("My MagicBand", bandAddrs.size, collapsed) {
                collapsed = !collapsed
                UiPrefs.saveBandMenuCollapsed(ctx, collapsed)
            }
            if (collapsed) return@Column
            if (bandAddrs.isEmpty()) {
                Text("NONE SET — PICK FROM HEARD OR ENTER MAC", style = techLabel(), color = AppColors.TextDim)
            } else {
                bandAddrs.forEach { addr ->
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(addr, style = techLabel(), color = AppColors.Cyan)
                        TextButton(
                            onClick = { app.store.removeBandAddress(addr) },
                            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                        ) { Text("REMOVE", style = techLabel(), color = AppColors.Amber) }
                    }
                }
            }
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(AppDimens.gap),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                OutlinedTextField(
                    value = manual,
                    onValueChange = { manual = it },
                    singleLine = true,
                    textStyle = techLabel(),
                    placeholder = { Text("AA:BB:CC:DD:EE:FF", style = techLabel(), color = AppColors.TextDim) },
                    modifier = Modifier.weight(1f),
                )
                OutlinedButton(
                    onClick = { if (manual.isNotBlank()) { app.store.addBandAddress(manual); manual = "" } },
                    modifier = Modifier.height(28.dp),
                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                ) { Text("ADD", style = techLabel()) }
            }
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("SAVED BAND PACKETS: $savedBands", style = techLabel(), color = AppColors.TextDim)
                if (savedBands > 0) {
                    TextButton(
                        onClick = { confirmDeleteBands = true },
                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                    ) { Text("DELETE ALL", style = techLabel(), color = MaterialTheme.colorScheme.error) }
                }
            }
            if (state.seenAddresses.isNotEmpty()) {
                Text("HEARD (TAP TO TAG):", style = techLabel(), color = AppColors.TextDim)
                state.seenAddresses.take(8).forEach { seen ->
                    val isBand = seen.address.uppercase() in bandAddrs
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            "${seen.address}  ${seen.rssi}dBm ·${seen.count}",
                            style = techLabel(),
                            color = if (isBand) AppColors.Cyan else AppColors.TextDim,
                        )
                        TextButton(
                            onClick = {
                                if (isBand) app.store.removeBandAddress(seen.address)
                                else app.store.addBandAddress(seen.address)
                            },
                            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                        ) { Text(if (isBand) "UNTAG" else "TAG", style = techLabel(), color = AppColors.Cyan) }
                    }
                }
            }
        }
    }

    if (confirmDeleteBands) {
        AlertDialog(
            onDismissRequest = { confirmDeleteBands = false },
            title = { Text("Delete saved band packets?", style = techLabel()) },
            text = {
                Text(
                    "Removes all $savedBands guest-band telemetry packets from your library. " +
                        "Logs and other packets are untouched. This only runs when you tap Delete.",
                    style = techLabel(),
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    val n = app.store.deleteSavedBands()
                    confirmDeleteBands = false
                    Toast.makeText(ctx, "Deleted $n band packets", Toast.LENGTH_SHORT).show()
                }) { Text("DELETE", style = techLabel(), color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { confirmDeleteBands = false }) { Text("CANCEL", style = techLabel()) }
            },
        )
    }
}

@Composable
private fun LibraryFileSection(app: MagicMakerApp, state: ServiceState.UiState) {
    val ctx = LocalContext.current
    var granted by remember { mutableStateOf(AllFilesAccess.granted(ctx)) }

    // Re-check access whenever the screen recomposes after returning from Settings.
    LaunchedEffect(state.storeRevision) { granted = AllFilesAccess.granted(ctx) }

    val writePermLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { ok -> granted = ok || AllFilesAccess.granted(ctx) }

    Surface(color = AppColors.Cyan.copy(alpha = 0.06f), shape = RectangleShape) {
        Column(Modifier.fillMaxWidth().padding(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("LIBRARY FILE (SD · EDITABLE)", style = techLabel(), color = AppColors.Cyan)
            Text(app.store.libraryFilePath, style = techLabel(), color = AppColors.TextDim, maxLines = 2)
            if (!granted) {
                Text("ACCESS NOT GRANTED", style = techLabel(), color = AppColors.Amber)
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(AppDimens.gap)) {
                if (!granted) {
                    OutlinedButton(
                        onClick = {
                            val intent = AllFilesAccess.requestIntent(ctx)
                            if (intent != null) ctx.startActivity(intent)
                            else writePermLauncher.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE)
                        },
                        modifier = Modifier.height(28.dp),
                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                    ) { Text("GRANT ACCESS", style = techLabel()) }
                }
                OutlinedButton(
                    onClick = {
                        val path = app.store.exportLibrary()
                        Toast.makeText(
                            ctx,
                            if (path != null) "Exported to $path" else "Grant storage access first",
                            Toast.LENGTH_SHORT,
                        ).show()
                    },
                    modifier = Modifier.height(28.dp),
                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                ) { Text("EXPORT", style = techLabel()) }
                OutlinedButton(
                    onClick = {
                        val ok = app.store.importLibrary()
                        Toast.makeText(
                            ctx,
                            if (ok) "Library imported" else "No file at path (or unreadable)",
                            Toast.LENGTH_SHORT,
                        ).show()
                    },
                    modifier = Modifier.height(28.dp),
                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                ) { Text("IMPORT", style = techLabel()) }
            }
        }
    }
}

@Composable
private fun DiagnosticsTab(state: ServiceState.UiState) {
    var priorityCollapsed by remember { mutableStateOf(false) }
    var otherCollapsed by remember { mutableStateOf(true) }
    val priority = remember(state.sources) { state.sources.filter { it.priority } }
    val other = remember(state.sources) { state.sources.filter { !it.priority } }

    Column(Modifier.fillMaxSize().padding(horizontal = AppDimens.pad)) {
        Text("BROADCAST SOURCES · ${state.sources.size}", style = techHeader())
        Text("PRIORITY = SENT SHOW/ANIM/COLOR", style = techLabel(), color = AppColors.TextDim)
        HorizontalDivider(color = AppColors.PanelLine, thickness = 0.5.dp)
        if (state.sources.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("NO SOURCES — START A SCAN", style = techLabel(), color = AppColors.TextDim)
            }
            return
        }
        LazyColumn {
            item(key = "diag-prio-hdr") {
                CollapsibleSectionHeader("Priority", priority.size, priorityCollapsed) {
                    priorityCollapsed = !priorityCollapsed
                }
            }
            if (!priorityCollapsed) items(priority, key = { "p-${it.address}" }) { SourceRow(it) }
            item(key = "diag-other-hdr") {
                CollapsibleSectionHeader("Other", other.size, otherCollapsed) {
                    otherCollapsed = !otherCollapsed
                }
            }
            if (!otherCollapsed) items(other, key = { "o-${it.address}" }) { SourceRow(it) }
        }
    }
}

@Composable
private fun SourceRow(s: ServiceState.SourceStat) {
    Column(Modifier.fillMaxWidth().padding(vertical = 3.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(
                s.address.ifEmpty { "(unknown)" },
                style = techLabel(),
                color = if (s.priority) AppColors.Cyan else AppColors.TextDim,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text("BEST ${s.bestRssi} · NOW ${s.lastRssi} dBm", style = techLabel(), color = AppColors.TextDim)
        }
        Text(
            "${s.count} PKTS · ${s.categories.joinToString(" ")}",
            style = techLabel(),
            color = AppColors.TextDim,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
    HorizontalDivider(thickness = 0.5.dp, color = AppColors.PanelLine)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LogsTab(app: MagicMakerApp, state: ServiceState.UiState) {
    val ctx = LocalContext.current
    var refreshTick by remember { mutableIntStateOf(0) }
    val logs = remember(refreshTick, state.recordSessionActive) { app.store.listLogs() }
    var selectedPath by remember { mutableStateOf<String?>(null) }

    val packets = remember(selectedPath, refreshTick) {
        selectedPath?.let { app.store.readLog(it) } ?: emptyList()
    }
    val categories = remember(packets) {
        packets.map { it.category }.filter { it.isNotEmpty() }.distinct().sorted()
    }
    val addresses = remember(packets) {
        packets.map { it.sourceAddress }.filter { it.isNotEmpty() }.distinct()
    }
    var selectedCats by remember(selectedPath) { mutableStateOf(setOf<String>()) }
    var selectedAddr by remember(selectedPath) { mutableStateOf("") }
    var bandOnly by remember(selectedPath) { mutableStateOf(false) }
    var analyzing by remember(selectedPath) { mutableStateOf(false) }
    var namingTarget by remember { mutableStateOf<AnalyzedPacket?>(null) }
    val analyzed = remember(packets, selectedCats, selectedAddr, bandOnly) {
        packets.asSequence()
            .filter { selectedCats.isEmpty() || it.category in selectedCats }
            .filter { selectedAddr.isEmpty() || it.sourceAddress == selectedAddr }
            .filter { !bandOnly || it.isBand }
            // Hide guest-band telemetry and pings — they're high-volume noise, not effects.
            .filter { !MagicClassifier.isLibraryNoise(it.hex) }
            .groupBy { MagicClassifier.groupKey(it.hex) }
            .map { (_, list) ->
                val sample = list.first()
                AnalyzedPacket(sample.hex, MagicClassifier.groupLabel(sample.hex), sample.category, list.size)
            }
            .sortedByDescending { it.count }
    }

    Column(Modifier.fillMaxSize().padding(horizontal = AppDimens.pad)) {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("CAPTURE LOGS", style = techHeader())
            TextButton(onClick = { refreshTick++ }, contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp)) {
                Text("REFRESH", style = techLabel(), color = AppColors.Cyan)
            }
        }
        if (app.store.cloudSyncConfigured()) {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "CLOUD: ${state.cloudSyncStatus.ifBlank { "idle" }}",
                    style = techLabel(),
                    color = AppColors.TextDim,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                TextButton(
                    onClick = { app.store.cloudSync(force = true) },
                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                ) {
                    Text("SYNC NOW", style = techLabel(), color = AppColors.Cyan)
                }
            }
        }
        if (state.replayActive) {
            Surface(color = AppColors.Cyan.copy(alpha = 0.12f), shape = RectangleShape) {
                Row(
                    Modifier.fillMaxWidth().padding(8.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "REPLAYING ${state.replayProgress}/${state.replayTotal} · ${state.replayLabel}",
                        style = techLabel(),
                        color = AppColors.Cyan,
                        modifier = Modifier.weight(1f),
                    )
                    OutlinedButton(
                        onClick = { MagicMakerForegroundService.stopReplay(ctx) },
                        modifier = Modifier.height(28.dp),
                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                    ) { Text("STOP", style = techLabel(), color = AppColors.Amber) }
                }
            }
        }
        HorizontalDivider(color = AppColors.PanelLine, thickness = 0.5.dp)
        if (logs.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("NO LOGS YET — START A SCAN", style = techLabel(), color = AppColors.TextDim)
            }
            return
        }
        LazyColumn {
            items(logs, key = { it.path }) { log ->
                val isSel = selectedPath == log.path
                Surface(
                    onClick = { selectedPath = if (isSel) null else log.path },
                    modifier = Modifier.fillMaxWidth(),
                    shape = RectangleShape,
                    color = if (isSel) MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.35f) else MaterialTheme.colorScheme.surface,
                ) {
                    Column(Modifier.padding(vertical = 4.dp)) {
                        Text(log.name, style = techLabel(), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(
                            "${log.packetCount} PKTS · ${log.sizeBytes / 1024}KB",
                            style = techLabel(),
                            color = AppColors.TextDim,
                        )
                    }
                }
                if (isSel) {
                    Column(
                        Modifier.fillMaxWidth().padding(start = 8.dp, bottom = 6.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        if (categories.isNotEmpty()) {
                            Text("FILTER TYPES (NONE = ALL)", style = techLabel(), color = AppColors.TextDim)
                            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                categories.forEach { cat ->
                                    FilterChip(
                                        selected = cat in selectedCats,
                                        onClick = {
                                            selectedCats = if (cat in selectedCats) selectedCats - cat else selectedCats + cat
                                        },
                                        label = { Text(cat, style = techLabel()) },
                                        modifier = Modifier.height(28.dp),
                                    )
                                }
                            }
                        }
                        if (addresses.isNotEmpty()) {
                            Text("FILTER SOURCE (TAP = ONLY THAT MAC)", style = techLabel(), color = AppColors.TextDim)
                            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                addresses.take(12).forEach { addr ->
                                    FilterChip(
                                        selected = selectedAddr == addr,
                                        onClick = { selectedAddr = if (selectedAddr == addr) "" else addr },
                                        label = { Text(addr, style = techLabel()) },
                                        modifier = Modifier.height(28.dp),
                                    )
                                }
                            }
                        }
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                            Text("BAND ONLY", style = techLabel(), color = AppColors.TextDim)
                            Switch(checked = bandOnly, onCheckedChange = { bandOnly = it })
                        }
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(AppDimens.gap)) {
                            OutlinedButton(
                                onClick = {
                                    MagicMakerForegroundService.replay(ctx, log.path, selectedCats.toList(), selectedAddr, bandOnly)
                                },
                                enabled = !state.replayActive,
                                modifier = Modifier.height(30.dp).weight(1f),
                                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                            ) { Text("REPLAY", style = techLabel()) }
                            OutlinedButton(
                                onClick = {
                                    app.store.deleteLog(log.path)
                                    selectedPath = null
                                    refreshTick++
                                    Toast.makeText(ctx, "Log deleted", Toast.LENGTH_SHORT).show()
                                },
                                modifier = Modifier.height(30.dp),
                                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                            ) { Text("DELETE", style = techLabel(), color = MaterialTheme.colorScheme.error) }
                        }
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(AppDimens.gap)) {
                            OutlinedButton(
                                onClick = { analyzing = !analyzing },
                                modifier = Modifier.height(30.dp).weight(1f),
                                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                            ) { Text(if (analyzing) "HIDE PACKETS" else "ANALYZE", style = techLabel()) }
                            OutlinedButton(
                                onClick = {
                                    val n = app.store.importHexesToLibrary(analyzed.map { it.hex })
                                    refreshTick++
                                    Toast.makeText(ctx, "Added $n to library", Toast.LENGTH_SHORT).show()
                                },
                                modifier = Modifier.height(30.dp).weight(1f),
                                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                            ) { Text("ADD ALL → LIB", style = techLabel(), color = AppColors.Cyan) }
                        }
                        if (analyzing) {
                            Text(
                                "${analyzed.size} UNIQUE (pings & other bands hidden) · TAP = TX · NAME = ADD",
                                style = techLabel(),
                                color = AppColors.TextDim,
                            )
                            analyzed.take(300).forEach { row ->
                                Row(
                                    Modifier.fillMaxWidth(),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Column(
                                        Modifier.weight(1f).clickable {
                                            MagicMakerForegroundService.transmit(ctx, row.hex)
                                        },
                                    ) {
                                        Text(
                                            "×${row.count} · ${row.label}",
                                            style = techLabel(),
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                        Text(
                                            row.hex,
                                            style = techLabel(),
                                            color = AppColors.CyanDim,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                    }
                                    TextButton(
                                        onClick = { namingTarget = row },
                                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                                    ) { Text("NAME", style = techLabel(), color = AppColors.Cyan) }
                                }
                                HorizontalDivider(thickness = 0.5.dp, color = AppColors.PanelLine)
                            }
                            if (analyzed.size > 300) {
                                Text("…and ${analyzed.size - 300} more (showing top 300)", style = techLabel(), color = AppColors.TextDim)
                            }
                        }
                    }
                }
                HorizontalDivider(thickness = 0.5.dp, color = AppColors.PanelLine)
            }
        }
    }

    namingTarget?.let { row ->
        RenameDialog(
            currentLabel = row.label,
            onDismiss = { namingTarget = null },
            onConfirm = { newLabel ->
                val err = app.store.saveCustomPreset(newLabel.ifBlank { row.label }, row.hex)
                refreshTick++
                Toast.makeText(ctx, err ?: "Added \"$newLabel\" to library", Toast.LENGTH_SHORT).show()
                namingTarget = null
            },
        )
    }
}

/** A distinct packet from a log, with how many times it appeared. */
private data class AnalyzedPacket(val hex: String, val label: String, val category: String, val count: Int)

@Composable
private fun ScanTab(state: ServiceState.UiState, onLoadInLab: (String, String) -> Unit) {
    val ctx = LocalContext.current
    val app = ctx.applicationContext as MagicMakerApp
    var recording by remember(state.recordSessionActive) { mutableStateOf(state.recordSessionActive) }
    var viewMode by remember { mutableStateOf(ScanViewMode.GROUPED) }
    var visibleSections by remember { mutableStateOf(LivePacketSection.entries.toSet()) }
    var collapsed by remember { mutableStateOf(UiPrefs.loadCollapsedScan(ctx)) }
    var promoteTarget by remember { mutableStateOf<ServiceState.LivePacket?>(null) }
    var recategorizeTarget by remember { mutableStateOf<Pair<String, String>?>(null) } // hex, label
    var deleteScanRequest by remember { mutableStateOf<ScanDeleteRequest?>(null) }
    var actionTarget by remember { mutableStateOf<Pair<ServiceState.LivePacket, Boolean>?>(null) } // packet, raw
    val wide = isWideLayout()
    var batteryOk by remember { mutableStateOf(BatteryOptimization.isIgnored(ctx)) }
    var startOnBoot by remember {
        mutableStateOf(
            ctx.getSharedPreferences("magicmaker", Context.MODE_PRIVATE)
                .getBoolean(MagicMakerForegroundService.PREF_START_ON_BOOT, true),
        )
    }

    LaunchedEffect(state.running) {
        batteryOk = BatteryOptimization.isIgnored(ctx)
    }

    LaunchedEffect(collapsed) { UiPrefs.saveCollapsedScan(ctx, collapsed) }

    WideScreenColumns(
        controls = {
            if (!batteryOk) {
                Surface(color = AppColors.Amber.copy(alpha = 0.12f), shape = RectangleShape) {
                    Row(
                        Modifier.fillMaxWidth().padding(8.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            "Unrestricted battery required for screen-off scan.",
                            style = techLabel(),
                            color = AppColors.Amber,
                            modifier = Modifier.weight(1f),
                        )
                        OutlinedButton(
                            onClick = {
                                ctx.startActivity(BatteryOptimization.requestIgnoreIntent(ctx))
                                batteryOk = BatteryOptimization.isIgnored(ctx)
                            },
                            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                            modifier = Modifier.height(28.dp),
                        ) { Text("OPT OUT", style = techLabel()) }
                    }
                }
                Spacer(Modifier.height(6.dp))
            }
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("RUN IN BACKGROUND", style = techLabel(), color = AppColors.TextDim)
                Switch(
                    checked = startOnBoot,
                    onCheckedChange = { enabled ->
                        startOnBoot = enabled
                        ctx.getSharedPreferences("magicmaker", Context.MODE_PRIVATE).edit()
                            .putBoolean(MagicMakerForegroundService.PREF_START_ON_BOOT, enabled)
                            .apply()
                    },
                )
            }
            Text(
                if (state.running) "Service running · lock screen OK" else "Tap SCAN to start",
                style = techLabel(),
                color = if (state.running) AppColors.Cyan else AppColors.TextDim,
            )
            Spacer(Modifier.height(4.dp))
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(AppDimens.gap),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                OutlinedButton(
                    onClick = {
                        if (!state.running) MagicMakerForegroundService.start(ctx)
                        val next = !state.scanActive
                        MagicMakerForegroundService.send(ctx, MagicMakerForegroundService.ACTION_SET_SCAN) {
                            putExtra(MagicMakerForegroundService.EXTRA_SCAN, next)
                        }
                    },
                    modifier = Modifier.height(28.dp),
                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                ) {
                    Icon(
                        if (state.scanActive) Icons.Default.Pause else Icons.Default.PlayArrow,
                        null,
                        Modifier.size(14.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(if (state.scanActive) "PAUSE" else "SCAN", style = techLabel())
                }
                OutlinedButton(
                    onClick = {
                        recording = !recording
                        MagicMakerForegroundService.send(ctx, MagicMakerForegroundService.ACTION_SET_RECORDING) {
                            putExtra(MagicMakerForegroundService.EXTRA_RECORDING, recording)
                        }
                    },
                    modifier = Modifier.height(28.dp),
                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                ) { Text(if (recording) "LOG:ON" else "LOG", style = techLabel()) }
                ScanViewMode.entries.forEach { mode ->
                    FilterChip(
                        selected = viewMode == mode,
                        onClick = { viewMode = mode },
                        label = { Text(mode.label, style = techLabel()) },
                        modifier = Modifier.height(28.dp),
                    )
                }
            }
            SectionFilterDropdown(visibleSections) { section ->
                visibleSections = if (section in visibleSections) visibleSections - section else visibleSections + section
            }
            BandConfigSection(app, state)
            LibraryFileSection(app, state)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Text(
                    if (viewMode == ScanViewMode.RAW) "BUF RAW ${state.rawLivePackets.size}" else "BUF UNIQUE ${state.livePackets.size}",
                    style = techLabel(),
                    color = AppColors.TextDim,
                )
                TextButton(
                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                    onClick = {
                        MagicMakerForegroundService.send(ctx, MagicMakerForegroundService.ACTION_CLEAR_LIVE)
                    },
                ) { Text("CLR", style = techLabel(), color = AppColors.Amber) }
            }
            Text("TAP REPLAY · HOLD MENU · SWIPE ← DEL · SWIPE → TX/TAG", style = techLabel(), color = AppColors.TextDim)
        },
        content = {
            HorizontalDivider(color = AppColors.PanelLine, thickness = 0.5.dp)
            val displayEmpty = when (viewMode) {
                ScanViewMode.GROUPED -> state.livePackets.isEmpty()
                ScanViewMode.RAW -> state.rawLivePackets.isEmpty()
            }
            if (displayEmpty) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("LISTEN 0x0183 MANUFACTURER", style = techLabel(), color = AppColors.TextDim)
                }
            } else when (viewMode) {
                ScanViewMode.RAW -> {
                    val raw = remember(state.rawLivePackets, visibleSections) {
                        state.rawLivePackets.filter { LivePacketSort.sectionOf(it) in visibleSections }
                    }
                    ScanPacketList(raw, wide = wide) { pkt ->
                        SwipePacketRow(
                            label = pkt.label,
                            hex = pkt.hex,
                            subtitle = liveSubtitle(pkt, includeNote = true),
                            selected = pkt.isBand,
                            onTap = { MagicMakerForegroundService.transmit(ctx, pkt.hex) },
                            onDelete = { deleteScanRequest = ScanDeleteRequest(pkt, raw = true) },
                            onPromote = { promoteTarget = pkt },
                            onLongPress = { actionTarget = pkt to true },
                            dismissOnDelete = false,
                        )
                    }
                }
                ScanViewMode.GROUPED -> {
                    val grouped = remember(state.livePackets, visibleSections) {
                        LivePacketSort.grouped(state.livePackets)
                            .filter { (section, _) -> section in visibleSections }
                    }
                    LazyColumn(contentPadding = PaddingValues(horizontal = AppDimens.pad)) {
                        grouped.forEach { (section, packets) ->
                            val isCollapsed = section in collapsed
                            item(key = "hdr-${section.name}") {
                                CollapsibleSectionHeader(section.title, packets.size, isCollapsed) {
                                    collapsed = if (isCollapsed) collapsed - section else collapsed + section
                                }
                            }
                            if (!isCollapsed) {
                                if (wide) {
                                    items(packets.chunked(2), key = { row -> "${section.name}-${row.first().dedupeKey}" }) { row ->
                                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(AppDimens.gap)) {
                                            row.forEach { pkt ->
                                                Box(Modifier.weight(1f)) {
                                                    SwipePacketRow(
                                                        label = pkt.label,
                                                        hex = pkt.hex,
                                                        subtitle = liveSubtitle(pkt, includeNote = false),
                                                        selected = pkt.isBand,
                                                        onTap = { MagicMakerForegroundService.transmit(ctx, pkt.hex) },
                                                        onDelete = { deleteScanRequest = ScanDeleteRequest(pkt, raw = false) },
                                                        onPromote = { promoteTarget = pkt },
                                                        onLongPress = { actionTarget = pkt to false },
                                                        dismissOnDelete = false,
                                                    )
                                                }
                                            }
                                            if (row.size == 1) Spacer(Modifier.weight(1f))
                                        }
                                    }
                                } else {
                                    items(packets, key = { "${section.name}-${it.dedupeKey}" }) { pkt ->
                                        SwipePacketRow(
                                            label = pkt.label,
                                            hex = pkt.hex,
                                            subtitle = liveSubtitle(pkt, includeNote = true),
                                            selected = pkt.isBand,
                                            onTap = { MagicMakerForegroundService.transmit(ctx, pkt.hex) },
                                            onDelete = { deleteScanRequest = ScanDeleteRequest(pkt, raw = false) },
                                            onPromote = { promoteTarget = pkt },
                                            onLongPress = { actionTarget = pkt to false },
                                            dismissOnDelete = false,
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        },
    )

    promoteTarget?.let { pkt ->
        AlertDialog(
            onDismissRequest = { promoteTarget = null },
            title = { Text("Packet action", style = techLabel()) },
            text = { Text(pkt.label, style = techLabel()) },
            confirmButton = {
                TextButton({
                    app.store.saveCustomPreset(pkt.label, pkt.hex)
                    promoteTarget = null
                }) { Text("ADD TO TX", style = techLabel()) }
            },
            dismissButton = {
                TextButton({
                    recategorizeTarget = pkt.hex to pkt.label
                    promoteTarget = null
                }) { Text("RECATEGORIZE", style = techLabel()) }
            },
        )
    }

    recategorizeTarget?.let { (hex, label) ->
        CategoryPickerDialog(
            label = label,
            onDismiss = { recategorizeTarget = null },
            onPick = { category ->
                val canonical = HexUtils.canonicalHex(hex)
                app.store.saveCustomPreset(label.ifEmpty { category.name }, hex)
                app.store.allTransmitPackets().firstOrNull {
                    HexUtils.canonicalHex(it.hex) == canonical
                }?.let { app.store.recategorizePacket(it.id, category) }
                recategorizeTarget = null
            },
        )
    }

    deleteScanRequest?.let { request ->
        ConfirmDeleteDialog(
            title = if (request.raw) "Remove raw packet?" else "Remove from scan list?",
            label = request.packet.label,
            hex = request.packet.hex,
            onDismiss = { deleteScanRequest = null },
            onConfirm = {
                if (request.raw) {
                    ServiceState.removeRawLive(request.packet.timestampMs, request.packet.hex)
                } else {
                    ServiceState.removeLive(request.packet.dedupeKey)
                }
                deleteScanRequest = null
            },
        )
    }

    actionTarget?.let { (pkt, raw) ->
        val colors = MagicClassifier.classify(pkt.hex)?.colors
        PacketActionSheet(
            title = pkt.label,
            hex = pkt.hex,
            subtitle = "${pkt.category.name} · RSSI ${pkt.rssi}",
            colors = colors,
            actions = listOf(
                PacketAction("Transmit") { MagicMakerForegroundService.transmit(ctx, pkt.hex); actionTarget = null },
                PacketAction("Load in Lab") { onLoadInLab(pkt.hex, pkt.label); actionTarget = null },
                PacketAction("Add to TX library") { app.store.saveCustomPreset(pkt.label, pkt.hex); actionTarget = null },
                PacketAction("Recategorize") { recategorizeTarget = pkt.hex to pkt.label; actionTarget = null },
                PacketAction("Remove", destructive = true) { deleteScanRequest = ScanDeleteRequest(pkt, raw = raw); actionTarget = null },
            ),
            onDismiss = { actionTarget = null },
        )
    }
}

@Composable
private fun ScanPacketList(
    packets: List<ServiceState.LivePacket>,
    wide: Boolean,
    row: @Composable (ServiceState.LivePacket) -> Unit,
) {
    if (wide) {
        LazyVerticalGrid(
            columns = GridCells.Fixed(2),
            contentPadding = PaddingValues(horizontal = AppDimens.pad),
            horizontalArrangement = Arrangement.spacedBy(AppDimens.gap),
        ) {
            items(packets, key = { "${it.timestampMs}-${it.hex}" }) { pkt -> row(pkt) }
        }
    } else {
        LazyColumn(contentPadding = PaddingValues(horizontal = AppDimens.pad)) {
            items(packets, key = { "${it.timestampMs}-${it.hex}" }) { pkt -> row(pkt) }
        }
    }
}

@Composable
private fun CategoryPickerDialog(
    label: String,
    onDismiss: () -> Unit,
    onPick: (MagicCategory) -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Recategorize", style = techLabel()) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(AppDimens.gap)) {
                Text(label, style = techLabel(), color = AppColors.TextDim)
                MagicCategory.entries.forEach { cat ->
                    TextButton({ onPick(cat) }, modifier = Modifier.fillMaxWidth()) {
                        Text(cat.name, style = techLabel())
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onDismiss) { Text("CANCEL", style = techLabel()) }
        },
    )
}

@Composable
private fun RenameDialog(
    currentLabel: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var text by remember { mutableStateOf(currentLabel) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Rename packet", style = techLabel()) },
        text = {
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                singleLine = true,
                textStyle = techLabel(),
                modifier = Modifier.fillMaxWidth(),
            )
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(text) },
                enabled = text.isNotBlank(),
            ) { Text("SAVE", style = techLabel()) }
        },
        dismissButton = {
            TextButton(onDismiss) { Text("CANCEL", style = techLabel()) }
        },
    )
}

@Composable
private fun WandTab(
    app: MagicMakerApp,
    storeRevision: Int,
    starlightLoopEnabled: Boolean,
    starlightLoopPacketId: Long,
    starlightIntervalMs: Long,
    wandDisplayColorIndex: Int,
    running: Boolean,
) {
    val ctx = LocalContext.current
    val storeRev = storeRevision
    val learned = remember(storeRev) { app.store.learnedStarlightPackets() }
    var loopOn by remember(starlightLoopEnabled) { mutableStateOf(starlightLoopEnabled) }
    var selectedId by remember(starlightLoopPacketId, learned.size) {
        mutableLongStateOf(
            when {
                starlightLoopPacketId >= 0 -> starlightLoopPacketId
                learned.isNotEmpty() -> learned.first().id
                else -> -1L
            },
        )
    }
    var intervalSec by remember { mutableFloatStateOf(starlightIntervalMs / 1000f) }
    var clearLibConfirm by remember { mutableStateOf(false) }
    val selected = learned.firstOrNull { it.id == selectedId }

    LaunchedEffect(starlightIntervalMs) {
        intervalSec = starlightIntervalMs / 1000f
    }

    LaunchedEffect(learned) {
        if (selectedId >= 0 && learned.none { it.id == selectedId }) {
            selectedId = learned.firstOrNull()?.id ?: -1L
        }
    }

    fun transmitColor(packet: MagicPacket) {
        selectedId = packet.id
        if (loopOn) {
            MagicMakerForegroundService.setStarlightLoop(
                ctx, enabled = true, packetId = packet.id, intervalMs = (intervalSec * 1000).toLong(),
            )
        } else {
            MagicMakerForegroundService.transmit(ctx, packet.hex)
        }
    }

    Column(Modifier.fillMaxSize()) {
        StarlightWandView(
            colors = learned,
            displayColorIndex = wandDisplayColorIndex,
            onTransmit = { transmitColor(it) },
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
        )
        Column(Modifier.padding(AppDimens.pad), verticalArrangement = Arrangement.spacedBy(AppDimens.gap)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("LOOP", Modifier.weight(1f), style = techHeader())
                Switch(
                    loopOn,
                    {
                        loopOn = it
                        if (it && !running) MagicMakerForegroundService.start(ctx)
                        if (selectedId >= 0) {
                            MagicMakerForegroundService.setStarlightLoop(
                                ctx, enabled = it, packetId = selectedId, intervalMs = (intervalSec * 1000).toLong(),
                            )
                        }
                    },
                    enabled = selectedId >= 0,
                    modifier = Modifier.height(32.dp),
                )
            }
            SettingSlider(
                committedValue = intervalSec,
                label = { displaySec ->
                    Text(
                        if (selected != null) "${"%.1f".format(displaySec)}S | ${selected.label.uppercase()}"
                        else "NO WAND LIBRARY",
                        style = techLabel(),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                },
                onCommit = { sec ->
                    intervalSec = sec
                    if (loopOn && selectedId >= 0) {
                        MagicMakerForegroundService.setStarlightLoop(
                            ctx, enabled = true, packetId = selectedId, intervalMs = (sec * 1000).toLong(),
                        )
                    }
                },
                valueRange = 0.5f..30f,
                steps = 59,
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Text("LIB ${learned.size}", style = techLabel(), color = AppColors.TextDim)
                if (learned.isNotEmpty()) {
                    TextButton(
                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                        onClick = { clearLibConfirm = true },
                    ) { Text("CLR LIB", style = techLabel(), color = AppColors.Amber) }
                }
            }
        }
    }

    if (clearLibConfirm) {
        ConfirmDeleteDialog(
            title = "Clear wand library?",
            label = "Remove all ${learned.size} learned colors",
            onDismiss = { clearLibConfirm = false },
            onConfirm = {
                app.store.clearLearnedStarlight()
                selectedId = -1L
                if (loopOn) {
                    loopOn = false
                    MagicMakerForegroundService.setStarlightLoop(ctx, enabled = false)
                }
                clearLibConfirm = false
            },
        )
    }
}

@Composable
private fun TransmitTab(app: MagicMakerApp, state: ServiceState.UiState, onLoadInLab: (String, String) -> Unit) {
    val ctx = LocalContext.current
    val storeRev = state.storeRevision
    var visibleSections by remember { mutableStateOf(LivePacketSection.entries.toSet()) }
    var collapsed by remember { mutableStateOf(UiPrefs.loadCollapsedTx(ctx)) }
    var recategorizePacket by remember { mutableStateOf<MagicPacket?>(null) }
    var renameTarget by remember { mutableStateOf<MagicPacket?>(null) }
    var deleteTarget by remember { mutableStateOf<MagicPacket?>(null) }
    var actionTarget by remember { mutableStateOf<MagicPacket?>(null) }
    var loopOn by remember(state.txLoopEnabled) { mutableStateOf(state.txLoopEnabled) }
    var txLoopSettingsCollapsed by remember { mutableStateOf(UiPrefs.isTxLoopSettingsCollapsed(ctx)) }
    var selectedTxId by remember(state.txLoopPacketId, storeRev) {
        mutableLongStateOf(state.txLoopPacketId)
    }
    var intervalSec by remember { mutableFloatStateOf(state.txLoopIntervalMs / 1000f) }
    val wide = isWideLayout()
    val allPackets = remember(storeRev) { app.store.allTransmitPackets() }
    val selectedPacket = allPackets.firstOrNull { it.id == selectedTxId }

    LaunchedEffect(state.txLoopIntervalMs) {
        intervalSec = state.txLoopIntervalMs / 1000f
    }

    LaunchedEffect(allPackets) {
        if (selectedTxId >= 0 && allPackets.none { it.id == selectedTxId }) {
            selectedTxId = allPackets.firstOrNull()?.id ?: -1L
        } else if (selectedTxId < 0 && allPackets.isNotEmpty()) {
            selectedTxId = allPackets.first().id
        }
    }

    LaunchedEffect(collapsed) { UiPrefs.saveCollapsedTx(ctx, collapsed) }
    LaunchedEffect(txLoopSettingsCollapsed) { UiPrefs.saveTxLoopSettingsCollapsed(ctx, txLoopSettingsCollapsed) }

    fun onSelectPacket(packet: MagicPacket) {
        selectedTxId = packet.id
        MagicMakerForegroundService.transmit(ctx, packet.hex)
        if (loopOn) {
            MagicMakerForegroundService.setTxLoop(
                ctx, enabled = true, packetId = packet.id, intervalMs = (intervalSec * 1000).toLong(),
            )
        }
    }

    val grouped = remember(storeRev) {
        LivePacketSort.groupedMagicPackets(allPackets)
            .filter { (section, list) -> section in LivePacketSection.entries && list.isNotEmpty() }
    }

    WideScreenColumns(
        controls = {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(AppDimens.gap)) {
                OutlinedButton(
                    onClick = { MagicMakerForegroundService.vibrate(ctx) },
                    modifier = Modifier.height(28.dp),
                    contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp),
                ) { Text("VIBRATE", style = techLabel()) }
                OutlinedButton(
                    onClick = { MagicMakerForegroundService.transmit(ctx, PacketBuilder.WAKEUP_PING) },
                    modifier = Modifier.height(28.dp),
                    contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp),
                ) { Text("INTERROGATE", style = techLabel()) }
            }
            TxLoopSettingsSection(
                collapsed = txLoopSettingsCollapsed,
                onToggleCollapsed = { txLoopSettingsCollapsed = !txLoopSettingsCollapsed },
                loopOn = loopOn,
                onLoopOnChange = { enabled ->
                    loopOn = enabled
                    if (enabled && !state.running) MagicMakerForegroundService.start(ctx)
                    if (selectedTxId >= 0) {
                        MagicMakerForegroundService.setTxLoop(
                            ctx,
                            enabled = enabled,
                            packetId = selectedTxId,
                            intervalMs = (intervalSec * 1000).toLong(),
                        )
                    }
                },
                loopEnabled = selectedTxId >= 0,
                intervalSec = intervalSec,
                onIntervalCommit = { sec ->
                    intervalSec = sec
                    if (loopOn && selectedTxId >= 0) {
                        MagicMakerForegroundService.setTxLoop(
                            ctx, enabled = true, packetId = selectedTxId, intervalMs = (sec * 1000).toLong(),
                        )
                    }
                },
                statusLabel = when {
                    loopOn && selectedPacket != null ->
                        "ON · ${"%.1f".format(intervalSec)}S · ${selectedPacket.label.uppercase()}"
                    loopOn -> "ON · ${"%.1f".format(intervalSec)}S"
                    else -> null
                },
            )
            SectionFilterDropdown(visibleSections) { section ->
                visibleSections = if (section in visibleSections) visibleSections - section else visibleSections + section
            }
            Text("TAP TX · HOLD MENU · SWIPE ← DEL · SWIPE → RECAT", style = techLabel(), color = AppColors.TextDim)
        },
        content = {
            HorizontalDivider(color = AppColors.PanelLine, thickness = 0.5.dp)
            if (grouped.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("NO TX LIBRARY — RUN RX SESSION", style = techLabel(), color = AppColors.TextDim)
                }
            } else {
                LazyColumn(contentPadding = PaddingValues(horizontal = AppDimens.pad)) {
                    grouped.filter { (section, _) -> section in visibleSections }.forEach { (section, packets) ->
                        val isCollapsed = section in collapsed
                        item(key = "tx-${section.name}") {
                            CollapsibleSectionHeader(section.title, packets.size, isCollapsed) {
                                collapsed = if (isCollapsed) collapsed - section else collapsed + section
                            }
                        }
                        if (!isCollapsed) {
                            if (wide) {
                                items(packets.chunked(2), key = { row -> "tx-${section.name}-${row.first().id}" }) { row ->
                                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(AppDimens.gap)) {
                                        row.forEach { packet ->
                                            Box(Modifier.weight(1f)) {
                                                TxSwipeRow(
                                                    app, packet, ctx,
                                                    selected = packet.id == selectedTxId,
                                                    onTap = { onSelectPacket(packet) },
                                                    onRecategorize = { recategorizePacket = packet },
                                                    onDelete = { deleteTarget = packet },
                                                    onLongPress = { actionTarget = packet },
                                                )
                                            }
                                        }
                                        if (row.size == 1) Spacer(Modifier.weight(1f))
                                    }
                                }
                            } else {
                                items(packets, key = { "tx-${section.name}-${it.id}-${it.hex}" }) { packet ->
                                    TxSwipeRow(
                                        app, packet, ctx,
                                        selected = packet.id == selectedTxId,
                                        onTap = { onSelectPacket(packet) },
                                        onRecategorize = { recategorizePacket = packet },
                                        onDelete = { deleteTarget = packet },
                                        onLongPress = { actionTarget = packet },
                                    )
                                }
                            }
                        }
                    }
                }
            }
        },
    )

    recategorizePacket?.let { packet ->
        CategoryPickerDialog(
            label = packet.label,
            onDismiss = { recategorizePacket = null },
            onPick = { category ->
                app.store.recategorizePacket(packet.id, category)
                recategorizePacket = null
            },
        )
    }

    renameTarget?.let { packet ->
        RenameDialog(
            currentLabel = packet.label,
            onDismiss = { renameTarget = null },
            onConfirm = { newLabel ->
                app.store.renamePacket(packet.id, newLabel)
                renameTarget = null
            },
        )
    }

    deleteTarget?.let { packet ->
        ConfirmDeleteDialog(
            title = "Delete from TX library?",
            label = packet.label,
            hex = packet.hex,
            onDismiss = { deleteTarget = null },
            onConfirm = {
                app.store.deletePacketById(packet.id)
                deleteTarget = null
            },
        )
    }

    actionTarget?.let { packet ->
        val colors = packet.colors.ifBlank { MagicClassifier.classify(packet.hex)?.colors.orEmpty() }
        PacketActionSheet(
            title = packet.label,
            hex = packet.hex,
            subtitle = packet.category.name,
            colors = colors,
            actions = listOf(
                PacketAction("Transmit") { onSelectPacket(packet); actionTarget = null },
                PacketAction("Load in Lab") { onLoadInLab(packet.hex, packet.label); actionTarget = null },
                PacketAction("Rename") { renameTarget = packet; actionTarget = null },
                PacketAction("Recategorize") { recategorizePacket = packet; actionTarget = null },
                PacketAction("Delete", destructive = true) { deleteTarget = packet; actionTarget = null },
            ),
            onDismiss = { actionTarget = null },
        )
    }
}

@Composable
private fun TxSwipeRow(
    app: MagicMakerApp,
    packet: MagicPacket,
    ctx: android.content.Context,
    selected: Boolean = false,
    onTap: () -> Unit,
    onRecategorize: () -> Unit,
    onDelete: () -> Unit,
    onLongPress: () -> Unit,
) {
    val subtitle = if (packet.colors.isNotBlank()) {
        "${packet.category.name} · ${packet.colors}"
    } else {
        packet.category.name
    }
    SwipePacketRow(
        label = packet.label,
        hex = packet.hex,
        subtitle = subtitle,
        selected = selected,
        onTap = onTap,
        onDelete = onDelete,
        onPromote = onRecategorize,
        onLongPress = onLongPress,
        dismissOnDelete = false,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AutoTab(app: MagicMakerApp, state: ServiceState.UiState) {
    val ctx = LocalContext.current
    var auto by remember(state.autoEnabled) { mutableStateOf(state.autoEnabled) }
    var ruleName by remember { mutableStateOf("My rule") }
    var triggerId by remember { mutableStateOf(PacketPatterns.systemTriggers[2].id) }
    var pickResponseId by remember { mutableStateOf(PacketPatterns.systemResponses[1].id) }
    var responseStack by remember { mutableStateOf(listOf<String>()) }
    val storeRev = state.storeRevision
    val learned = remember(storeRev) { app.store.allLearnedPackets }
    val userPresets = remember(storeRev) { app.store.customPresets }
    val triggers = remember(storeRev) { PacketPatterns.buildTriggerOptions(userPresets, learned) }
    val responses = remember(storeRev) { PacketPatterns.buildResponseOptions(userPresets, learned) }
    val autoRules = remember(storeRev) { app.store.autoRules }

    LazyColumn(
        contentPadding = PaddingValues(AppDimens.pad),
        verticalArrangement = Arrangement.spacedBy(AppDimens.gap),
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("AUTO-RESPONSE", style = techHeader())
                    Text("TRIGGER → STACKED TX", style = techLabel(), color = AppColors.TextDim)
                }
                Switch(
                    auto,
                    {
                        auto = it
                        MagicMakerForegroundService.send(ctx, MagicMakerForegroundService.ACTION_SET_AUTO) {
                            putExtra(MagicMakerForegroundService.EXTRA_AUTO, it)
                        }
                    },
                    modifier = Modifier.height(32.dp),
                )
            }
        }
        item {
            OutlinedTextField(
                value = ruleName,
                onValueChange = { ruleName = it },
                label = { Text("Rule name", style = MaterialTheme.typography.labelSmall) },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                textStyle = MaterialTheme.typography.labelMedium,
            )
        }
        item {
            var triggerExpanded by remember { mutableStateOf(false) }
            ExposedDropdownMenuBox(triggerExpanded, { triggerExpanded = it }) {
                OutlinedTextField(
                    triggers.firstOrNull { it.id == triggerId }?.label ?: triggerId,
                    {},
                    readOnly = true,
                    label = { Text("When I hear", style = MaterialTheme.typography.labelSmall) },
                    textStyle = MaterialTheme.typography.labelMedium,
                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(triggerExpanded) },
                    modifier = Modifier.menuAnchor().fillMaxWidth(),
                )
                ExposedDropdownMenu(triggerExpanded, { triggerExpanded = false }) {
                    triggers.forEach { opt ->
                        DropdownMenuItem(
                            text = { Text(opt.label, maxLines = 2, overflow = TextOverflow.Ellipsis) },
                            onClick = { triggerId = opt.id; triggerExpanded = false },
                        )
                    }
                }
            }
        }
        item {
            var responseExpanded by remember { mutableStateOf(false) }
            ExposedDropdownMenuBox(responseExpanded, { responseExpanded = it }) {
                OutlinedTextField(
                    responses.firstOrNull { it.id == pickResponseId }?.label ?: pickResponseId,
                    {},
                    readOnly = true,
                    label = { Text("Add response to stack", style = MaterialTheme.typography.labelSmall) },
                    textStyle = MaterialTheme.typography.labelMedium,
                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(responseExpanded) },
                    modifier = Modifier.menuAnchor().fillMaxWidth(),
                )
                ExposedDropdownMenu(responseExpanded, { responseExpanded = false }) {
                    responses.forEach { opt ->
                        DropdownMenuItem(
                            text = { Text(opt.label, maxLines = 2, overflow = TextOverflow.Ellipsis) },
                            onClick = {
                                pickResponseId = opt.id
                                if (opt.id !in responseStack) responseStack = responseStack + opt.id
                                responseExpanded = false
                            },
                        )
                    }
                }
            }
        }
        if (responseStack.isNotEmpty()) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text("Stack (${responseStack.size})", style = MaterialTheme.typography.labelSmall)
                    responseStack.forEachIndexed { index, id ->
                        val label = responses.firstOrNull { it.id == id }?.label ?: id
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                "${index + 1}. $label",
                                style = MaterialTheme.typography.labelSmall,
                                modifier = Modifier.weight(1f),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            IconButton(
                                onClick = { responseStack = responseStack.filterIndexed { i, _ -> i != index } },
                                modifier = Modifier.size(24.dp),
                            ) {
                                Icon(Icons.Default.Close, contentDescription = "Remove", modifier = Modifier.size(14.dp))
                            }
                        }
                    }
                }
            }
        }
        item {
            Button(
                enabled = responseStack.isNotEmpty(),
                onClick = {
                    val hexes = responseStack.mapNotNull { id ->
                        responses.firstOrNull { it.id == id }?.defaultHex?.takeIf { it.isNotEmpty() }
                    }
                    app.store.addAutoRule(ruleName, triggerId, responseStack, hexes)
                    responseStack = emptyList()
                },
            ) { Text("Add rule") }
        }
        item {
                    Text("Rules (${autoRules.size})", style = techHeader())
        }
        if (autoRules.isEmpty()) {
            item {
                Text("NO RULES — CONFIGURE STACK ABOVE", style = techLabel(), color = AppColors.TextDim)
            }
        }
        items(autoRules, key = { it.id }) { rule ->
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(rule.name, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelMedium)
                    val stackSize = rule.responseHexes.size.coerceAtLeast(1)
                    Text(
                        "${rule.triggerPatternId} → $stackSize pkt${if (stackSize == 1) "" else "s"}",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Switch(rule.enabled, { app.store.setAutoRuleEnabled(rule.id, it) }, modifier = Modifier.height(32.dp))
                IconButton(onClick = { app.store.deleteAutoRule(rule.id) }, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Default.Delete, contentDescription = "Delete", modifier = Modifier.size(16.dp))
                }
            }
        }
    }
}

@Composable
private fun GattRelayPanel(state: ServiceState.UiState, bleGranted: Boolean) {
    if (!bleGranted) {
        Text("Bluetooth permissions required for GATT remote.", style = techLabel(), color = AppColors.Amber)
    } else if (!state.running) {
        Text("Service not running — grant permissions and reopen app.", style = techLabel(), color = AppColors.Amber)
    }
    Text("ADV NAME: ${RelayProtocol.DEVICE_NAME}", style = techLabel(), color = AppColors.CyanDim)
    Text(
        if (state.relayLinked) "LINK: IPHONE CONNECTED (remote active)" else "LINK: GATT LISTENING (local OK)",
        style = techLabel(),
        color = if (state.relayLinked) AppColors.Cyan else AppColors.TextDim,
    )
    if (state.status.isNotEmpty()) {
        Text("STATUS: ${state.status}", style = techLabel(), color = AppColors.TextDim)
    }
    Text("Local scan/TX/wand keep working — iPhone connects as remote.", style = techLabel(), color = AppColors.TextDim)
}

@Composable
private fun RelayTab(state: ServiceState.UiState, bleGranted: Boolean, wifiGranted: Boolean, onRequestWifiPerm: () -> Unit) {
    val ctx = LocalContext.current
    Column(Modifier.padding(AppDimens.pad), verticalArrangement = Arrangement.spacedBy(AppDimens.gap)) {
        Text("RELAY / REMOTE", style = techHeader())
        Text(
            "GATT remote is always on while the service runs. WiFi hotspot is optional.",
            style = techLabel(),
            color = AppColors.TextDim,
        )
        RelayControlMode.entries.forEach { mode ->
            FilterChip(
                selected = state.relayMode == mode,
                onClick = {
                    ctx.getSharedPreferences("magicmaker", Context.MODE_PRIVATE)
                        .edit().putString("relay_mode", mode.name).apply()
                    MagicMakerForegroundService.send(ctx, MagicMakerForegroundService.ACTION_SET_RELAY) {
                        putExtra(MagicMakerForegroundService.EXTRA_RELAY_MODE, mode.name)
                    }
                },
                label = {
                    Text(
                        when (mode) {
                            RelayControlMode.STANDALONE -> "STANDALONE"
                            RelayControlMode.WIFI_HOTSPOT -> "WIFI / IPHONE"
                            RelayControlMode.BLE_GATT -> "BLE GATT / IPHONE"
                        },
                        style = techLabel(),
                    )
                },
            )
        }
        when (state.relayMode) {
            RelayControlMode.STANDALONE, RelayControlMode.BLE_GATT -> GattRelayPanel(state, bleGranted)
            RelayControlMode.WIFI_HOTSPOT -> {
                if (!wifiGranted) {
                    Text("NEARBY DEVICES permission required for WiFi hotspot.", style = techLabel(), color = AppColors.Amber)
                    OutlinedButton(onClick = onRequestWifiPerm) {
                        Text("GRANT NEARBY", style = techLabel())
                    }
                }
                if (state.hotspotSsid.isNotEmpty()) {
                    Text("SSID: ${state.hotspotSsid}", style = techLabel(), color = AppColors.Cyan)
                    if (state.hotspotPassword.isNotEmpty()) {
                        Text("PASS: ${state.hotspotPassword}", style = techLabel(), color = AppColors.Amber)
                    }
                    Text("GW: ${state.relayIp}:${state.httpPort}", style = techLabel(), color = AppColors.CyanDim)
                    val pairingJson = RelayPairingPayload.json(
                        ssid = state.hotspotSsid,
                        password = state.hotspotPassword,
                        gatewayIp = state.relayIp,
                        httpPort = state.httpPort,
                    ).toString()
                    Text("SCAN WITH IPHONE REMOTE", style = techHeader(), color = AppColors.Cyan)
                    RelayQrImage(content = pairingJson)
                    Text("Or join WiFi manually, then open iPhone LINK tab.", style = techLabel(), color = AppColors.TextDim)
                } else {
                    Text("Expected AP: MagicMaker / magic123", style = techLabel(), color = AppColors.TextDim)
                }
                Text("POST /control  POST /transmit  GET /status  GET /live", style = techLabel(), color = AppColors.TextDim)
                GattRelayPanel(state, bleGranted)
            }
        }
        OutlinedButton({
            ctx.startActivity(BatteryOptimization.requestIgnoreIntent(ctx))
        }) { Text("BATTERY OPT-OUT", style = techLabel()) }
    }
}
