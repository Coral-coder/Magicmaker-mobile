package com.magicmaker.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.unit.dp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SwipePacketRow(
    label: String,
    hex: String,
    subtitle: String? = null,
    selected: Boolean = false,
    onTap: () -> Unit,
    onDelete: () -> Unit,
    onPromote: (() -> Unit)? = null,
    dismissOnDelete: Boolean = false,
) {
    val dismissState = rememberSwipeToDismissBoxState(
        confirmValueChange = { direction ->
            when (direction) {
                SwipeToDismissBoxValue.EndToStart -> {
                    onDelete()
                    dismissOnDelete
                }
                SwipeToDismissBoxValue.StartToEnd -> {
                    onPromote?.invoke()
                    false
                }
                else -> false
            }
        },
    )

    SwipeToDismissBox(
        state = dismissState,
        enableDismissFromStartToEnd = onPromote != null,
        enableDismissFromEndToStart = true,
        backgroundContent = {
            when (dismissState.dismissDirection) {
                SwipeToDismissBoxValue.StartToEnd -> Row(
                    Modifier
                        .fillMaxSize()
                        .background(AppColors.Cyan.copy(alpha = 0.25f))
                        .padding(horizontal = AppDimens.pad),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Default.Add, null, tint = AppColors.Cyan, modifier = Modifier.size(16.dp))
                    Text("TX / TAG", style = techLabel(), color = AppColors.Cyan, modifier = Modifier.padding(start = 4.dp))
                }
                SwipeToDismissBoxValue.EndToStart -> Row(
                    Modifier
                        .fillMaxSize()
                        .background(MaterialTheme.colorScheme.error.copy(alpha = 0.25f))
                        .padding(horizontal = AppDimens.pad),
                    horizontalArrangement = Arrangement.End,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("DELETE", style = techLabel(), color = MaterialTheme.colorScheme.error)
                    Icon(Icons.Default.Delete, null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(16.dp).padding(start = 4.dp))
                }
                else -> Unit
            }
        },
        content = {
            Surface(
                onClick = onTap,
                modifier = Modifier.fillMaxWidth(),
                shape = RectangleShape,
                tonalElevation = 0.dp,
                shadowElevation = 0.dp,
                color = if (selected) {
                    MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.35f)
                } else {
                    MaterialTheme.colorScheme.surface
                },
            ) {
                Column(Modifier.padding(horizontal = AppDimens.cardPad, vertical = 3.dp)) {
                    Text(label.uppercase(), style = techLabel(), maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                    Text(hex, style = techLabel(), color = AppColors.CyanDim, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                    if (!subtitle.isNullOrEmpty()) {
                        Text(subtitle.uppercase(), style = techLabel(), color = AppColors.TextDim, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                    }
                }
            }
            HorizontalDivider(thickness = 0.5.dp, color = AppColors.PanelLine)
        },
    )
}

@Composable
fun isWideLayout(): Boolean {
    val width = androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp
    return width >= 600
}

@Composable
fun WideScreenColumns(
    controls: @Composable () -> Unit,
    content: @Composable () -> Unit,
) {
    if (isWideLayout()) {
        Row(Modifier.fillMaxSize()) {
            Column(
                Modifier
                    .weight(0.34f)
                    .padding(end = AppDimens.pad),
                verticalArrangement = Arrangement.spacedBy(AppDimens.gap),
            ) { controls() }
            Column(Modifier.weight(0.66f)) { content() }
        }
    } else {
        Column(Modifier.fillMaxSize()) {
            controls()
            content()
        }
    }
}
