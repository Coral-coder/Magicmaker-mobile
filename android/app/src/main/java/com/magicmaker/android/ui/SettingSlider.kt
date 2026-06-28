package com.magicmaker.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

/**
 * Slider that keeps drag state internal so parent composables are not recomposed mid-gesture
 * (parent recomposition cancels Compose Slider drags after one step). The label receives the
 * live draft value as the thumb moves, but [onCommit] runs only when the thumb is released.
 *
 * When [step] is set, the value snaps to that increment, and − / + buttons flank the slider for
 * precise single-step adjustments. Otherwise the legacy [steps] tick count is used.
 */
@Composable
fun SettingSlider(
    committedValue: Float,
    onCommit: (Float) -> Unit,
    valueRange: ClosedFloatingPointRange<Float>,
    steps: Int = 0,
    step: Float? = null,
    modifier: Modifier = Modifier,
    label: (@Composable (displayValue: Float) -> Unit)? = null,
) {
    var dragging by remember { mutableStateOf(false) }
    var draft by remember { mutableFloatStateOf(committedValue) }

    LaunchedEffect(committedValue) {
        if (!dragging) draft = committedValue
    }

    fun snap(v: Float): Float {
        val s = step ?: return v.coerceIn(valueRange.start, valueRange.endInclusive)
        return ((v / s).roundToInt() * s).coerceIn(valueRange.start, valueRange.endInclusive)
    }

    val sliderColors = SliderDefaults.colors(
        thumbColor = AppColors.Cyan,
        activeTrackColor = AppColors.Cyan,
        inactiveTrackColor = AppColors.PanelLine,
    )

    Column(modifier) {
        label?.invoke(if (step != null) snap(draft) else draft)
        if (step != null) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                OutlinedButton(
                    onClick = { onCommit(snap(committedValue - step)) },
                    enabled = committedValue > valueRange.start,
                    contentPadding = PaddingValues(0.dp),
                    modifier = Modifier.size(40.dp),
                ) { Text("–", style = techLabel(), color = AppColors.Cyan) }
                Slider(
                    value = draft,
                    onValueChange = { next ->
                        dragging = true
                        draft = next
                    },
                    onValueChangeFinished = {
                        dragging = false
                        onCommit(snap(draft))
                    },
                    valueRange = valueRange,
                    modifier = Modifier
                        .weight(1f)
                        .height(48.dp),
                    colors = sliderColors,
                )
                OutlinedButton(
                    onClick = { onCommit(snap(committedValue + step)) },
                    enabled = committedValue < valueRange.endInclusive,
                    contentPadding = PaddingValues(0.dp),
                    modifier = Modifier.size(40.dp),
                ) { Text("+", style = techLabel(), color = AppColors.Cyan) }
            }
        } else {
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
                colors = sliderColors,
            )
        }
    }
}
