package com.magicmaker.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/** One row in a [PacketActionSheet]. */
data class PacketAction(val label: String, val destructive: Boolean = false, val onClick: () -> Unit)

/**
 * Long-press menu for a packet. Shows the label, hex and (when classified) a colors
 * subtext, then a list of actions — TX, Load in Lab, rename, etc.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PacketActionSheet(
    title: String,
    hex: String,
    subtitle: String?,
    colors: String?,
    actions: List<PacketAction>,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = AppColors.Panel) {
        Column(Modifier.fillMaxWidth().padding(horizontal = AppDimens.pad, vertical = 4.dp)) {
            Text(title.uppercase(), style = techHeader(), maxLines = 2, overflow = TextOverflow.Ellipsis)
            Text(hex, style = techLabel(), color = AppColors.CyanDim, maxLines = 2, overflow = TextOverflow.Ellipsis)
            if (!colors.isNullOrBlank()) {
                Text("COLORS: ${colors.uppercase()}", style = techLabel(), color = AppColors.Cyan, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (!subtitle.isNullOrBlank()) {
                Text(subtitle.uppercase(), style = techLabel(), color = AppColors.TextDim, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            HorizontalDivider(color = AppColors.PanelLine, thickness = 0.5.dp, modifier = Modifier.padding(vertical = 6.dp))
            actions.forEach { action ->
                Text(
                    action.label.uppercase(),
                    style = techLabel(),
                    color = if (action.destructive) androidx.compose.material3.MaterialTheme.colorScheme.error else AppColors.Cyan,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { action.onClick() }
                        .padding(vertical = 12.dp),
                )
            }
            Spacer(Modifier.height(8.dp))
        }
    }
}
