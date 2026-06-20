package com.magicmaker.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Slider that keeps drag state internal so parent composables are not recomposed mid-gesture
 * (parent recomposition cancels Compose Slider drags after one step).
 * [onCommit] runs only when the thumb is released.
 */
@Composable
fun SettingSlider(
    committedValue: Float,
    onCommit: (Float) -> Unit,
    valueRange: ClosedFloatingPointRange<Float>,
    steps: Int,
    modifier: Modifier = Modifier,
    label: (@Composable (displayValue: Float) -> Unit)? = null,
) {
    var dragging by remember { mutableStateOf(false) }
    var draft by remember { mutableFloatStateOf(committedValue) }

    LaunchedEffect(committedValue) {
        if (!dragging) draft = committedValue
    }

    Column(modifier) {
        label?.invoke(draft)
        Slider(
            value = draft,
            onValueChange = { next ->
                dragging = true
                draft = next
            },
            onValueChangeFinished = {
                dragging = false
                onCommit(draft)
            },
            valueRange = valueRange,
            steps = steps,
            modifier = Modifier
                .fillMaxWidth()
                .height(48.dp),
            colors = SliderDefaults.colors(
                thumbColor = AppColors.Cyan,
                activeTrackColor = AppColors.Cyan,
                inactiveTrackColor = AppColors.PanelLine,
            ),
        )
    }
}
