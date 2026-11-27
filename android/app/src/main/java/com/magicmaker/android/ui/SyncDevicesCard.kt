package com.magicmaker.android.ui

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.magicmaker.android.sync.DeviceRow
import com.magicmaker.android.sync.RowTone
import com.magicmaker.android.sync.SyncEngine
import com.magicmaker.android.sync.SyncStatus

/**
 * The compact SYNC / DEVICES card (docs/SYNC_P3_ANDROID_PLAN.md §5.8, spec §9.7) at the top of the
 * Relay tab: one line per device (IPHONE, ESP32, THIS phone, and any other device seen in a
 * heartbeat) with battery, heartbeat age, link path and sync badge, under a header that reads ALL
 * IN SYNC or the first problem. DETAILS shows the per-session diagnostics; LEAVE SYNC GROUP (with a
 * confirm) forgets the group key on this phone.
 */
@Composable
internal fun SyncDevicesCard() {
    val d by SyncStatus.state.collectAsState()
    // While the card is on a visible screen the engine refreshes it every second (ages); hidden or
    // in the background it refreshes on changes only (SyncStatus.watched).
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        var on = false
        fun set(v: Boolean) {
            if (v == on) return
            on = v
            SyncStatus.watch(v)
        }
        val obs = LifecycleEventObserver { src, _ -> set(src.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) }
        owner.lifecycle.addObserver(obs)
        onDispose {
            owner.lifecycle.removeObserver(obs)
            set(false)
        }
    }
    var details by rememberSaveable { mutableStateOf(false) }
    var askLeave by remember { mutableStateOf(false) }
    val mono = techLabel().copy(fontFamily = FontFamily.Monospace)
    Column(
        Modifier
            .fillMaxWidth()
            .border(0.5.dp, if (d.allInSync) AppColors.CyanDim else AppColors.PanelLine, RoundedCornerShape(6.dp))
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("SYNC / DEVICES", style = techHeader())
            Spacer(Modifier.weight(1f))
            Text(d.group, style = mono, color = if (d.grouped) AppColors.CyanDim else AppColors.TextDim)
        }
        Text(d.header, style = techLabel(), color = toneColor(d.headerTone))
        for (r in d.rows) DeviceLine(r, mono)
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = { details = !details }) {
                Text(if (details) "HIDE DETAILS" else "DETAILS", style = techLabel(), color = AppColors.CyanDim)
            }
            Spacer(Modifier.weight(1f))
            if (d.grouped) {
                TextButton(onClick = { askLeave = true }) {
                    Text("LEAVE SYNC GROUP", style = techLabel(), color = AppColors.Amber)
                }
            }
        }
        if (details) {
            if (d.diag.isEmpty()) Text("No sync sessions.", style = mono, color = AppColors.TextDim)
            for (line in d.diag) Text(line, style = mono, color = AppColors.TextDim)
        }
    }
    if (askLeave) {
        AlertDialog(
            onDismissRequest = { askLeave = false },
            title = { Text("Leave sync group?", style = techHeader()) },
            text = {
                Text(
                    "This phone forgets the group key and drops its sync links. It rejoins on its own " +
                        "the next time it meets a grouped iPhone or ESP32. The library stays on this phone.",
                    style = techLabel(),
                    color = AppColors.TextDim,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    SyncEngine.current?.leaveGroup()
                    askLeave = false
                }) { Text("LEAVE", style = techLabel(), color = AppColors.Amber) }
            },
            dismissButton = {
                TextButton(onClick = { askLeave = false }) { Text("CANCEL", style = techLabel(), color = AppColors.TextDim) }
            },
        )
    }
}

@Composable
private fun DeviceLine(r: DeviceRow, mono: androidx.compose.ui.text.TextStyle) {
    val ink = if (r.seen) AppColors.TextPrimary else AppColors.TextDim
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(r.label.take(10), Modifier.width(72.dp), style = mono, color = if (r.seen) AppColors.Cyan else AppColors.TextDim,
            maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(r.battery, Modifier.weight(1.3f), style = mono, color = ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(r.age, Modifier.width(36.dp), style = mono, color = ink, maxLines = 1, textAlign = TextAlign.End)
        Text(r.path, Modifier.weight(1.1f).padding(start = 6.dp), style = mono, color = ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(r.badge, Modifier.weight(1.1f), style = mono, color = toneColor(r.tone), maxLines = 1, textAlign = TextAlign.End,
            overflow = TextOverflow.Ellipsis)
    }
}

private fun toneColor(t: RowTone): Color = when (t) {
    RowTone.OK -> AppColors.Cyan
    RowTone.BUSY -> AppColors.CyanDim
    RowTone.PROBLEM -> AppColors.Amber
    RowTone.IDLE -> AppColors.TextDim
}
