package com.magicmaker.android.ui.vfd

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.colorspace.ColorSpaces
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.magicmaker.android.ui.AppColors
import com.magicmaker.android.ui.techHeader
import com.magicmaker.android.ui.techLabel
import kotlin.math.roundToInt

// The theme setting both themes share: which look the app shows (the standard Compose screens or
// the VFD dot-matrix display) and the VFD base colour, persisted side by side in the
// "magicmaker_ui" SharedPreferences (so a library export / import carries them like the other UI
// preferences). Port of ios/MagicMaker/VFD/VFDSettings.swift.

/** The app's look. */
enum class VFDTheme(val raw: String, val label: String) {
    standard("standard", "STANDARD"),
    vfd("vfd", "VFD");

    companion object {
        /** "standard" / "vfd" (any case), else null. */
        fun fromRaw(raw: String?): VFDTheme? {
            val key: String = raw?.trim()?.lowercase() ?: return null
            for (t in entries) {
                if (t.raw == key) return t
            }
            return null
        }
    }
}

/**
 * Theme and VFD base colour ([VFDSettings.shared]), as Compose state: reading [theme], [base] or
 * [customRGB] in a composable (or in a VFD screen's draw) follows changes. SharedPreferences
 * "magicmaker_ui": "ui_theme" = "standard" / "vfd" (default standard); "vfd_base" = a preset name
 * ("AMBER", the default) or "#RRGGBB"; "vfd_custom_base" = the last custom colour as "#RRGGBB"
 * (what CUSTOM shows and selects). Changes written by anything else (a library import restoring
 * the UI preferences) are picked up too. Main thread only.
 */
class VFDSettings private constructor(context: Context) {
    companion object {
        const val prefsName: String = "magicmaker_ui"
        const val themeKey: String = "ui_theme"
        const val baseKey: String = "vfd_base"
        const val customKey: String = "vfd_custom_base"
        /** CUSTOM before a colour was ever picked. */
        val defaultCustomRGB: VFDRGB = VFDRGB(0xFF, 0x88, 0x00)
        const val customLabel: String = "CUSTOM"

        @Volatile
        private var instance: VFDSettings? = null

        /** The one instance (Swift `VFDSettings.shared`). */
        fun shared(context: Context): VFDSettings {
            val existing: VFDSettings? = instance
            if (existing != null) return existing
            synchronized(this) {
                val again: VFDSettings? = instance
                if (again != null) return again
                val made = VFDSettings(context.applicationContext)
                instance = made
                return made
            }
        }

        /** The BASE COLOUR selector's items: the presets in order, then CUSTOM. */
        val baseItems: List<String> = VFDBase.presets.map { it.name } + customLabel

        /** A Compose colour for an RGB. */
        fun color(rgb: VFDRGB): Color = Color(rgb.argb)

        /** The colour's sRGB channels, clamped to 0..255 (alpha ignored). */
        fun rgb(color: Color): VFDRGB {
            val c: Color = if (color.colorSpace == ColorSpaces.Srgb) color else color.convert(ColorSpaces.Srgb)
            return VFDRGB(unitRed = c.red.toDouble(), green = c.green.toDouble(), blue = c.blue.toDouble())
        }

        private fun loadTheme(p: SharedPreferences): VFDTheme =
            VFDTheme.fromRaw(readString(p, themeKey)) ?: VFDTheme.standard

        private fun loadBase(p: SharedPreferences): VFDBase {
            val raw: String = readString(p, baseKey) ?: return VFDBase.amber
            return VFDBase.fromPersisted(raw)
        }

        private fun loadCustom(p: SharedPreferences): VFDRGB {
            val raw: String? = readString(p, customKey)
            if (raw != null) {
                val rgb: VFDRGB? = VFDRGB.parse(raw)
                if (rgb != null) return rgb
            }
            val base: VFDBase = loadBase(p)
            if (base is VFDBase.Custom) return base.rgb
            return defaultCustomRGB
        }

        private fun readString(p: SharedPreferences, key: String): String? {
            return try {
                p.getString(key, null)
            } catch (e: ClassCastException) {
                null
            }
        }
    }

    private val prefs: SharedPreferences = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)

    private var themeState: VFDTheme by mutableStateOf(loadTheme(prefs))
    private var baseState: VFDBase by mutableStateOf(loadBase(prefs))
    private var customState: VFDRGB by mutableStateOf(loadCustom(prefs))

    // SharedPreferences keeps listeners weakly: this field holds it for the app's lifetime.
    private val listener = SharedPreferences.OnSharedPreferenceChangeListener { p, key ->
        if (key == null || key == themeKey) {
            val t: VFDTheme = loadTheme(p)
            if (t != themeState) themeState = t
        }
        if (key == null || key == baseKey) {
            val b: VFDBase = loadBase(p)
            if (b != baseState) baseState = b
        }
        if (key == null || key == customKey) {
            val c: VFDRGB = loadCustom(p)
            if (c != customState) customState = c
        }
    }

    init {
        prefs.registerOnSharedPreferenceChangeListener(listener)
    }

    /** STANDARD or VFD. Setting it switches the app's look at once. */
    var theme: VFDTheme
        get() = themeState
        set(value) {
            if (value != themeState) {
                themeState = value
                prefs.edit().putString(themeKey, value.raw).apply()
            }
        }

    /** The base colour the VFD theme is drawn in. Choosing a custom one also remembers it as
     *  [customRGB]. */
    var base: VFDBase
        get() = baseState
        set(value) {
            if (value != baseState) {
                baseState = value
                prefs.edit().putString(baseKey, value.persisted).apply()
            }
            if (value is VFDBase.Custom && value.rgb != customState) {
                customRGB = value.rgb
            }
        }

    /** The colour CUSTOM stands for, kept while a preset is selected. */
    var customRGB: VFDRGB
        get() = customState
        set(value) {
            if (value != customState) {
                customState = value
                prefs.edit().putString(customKey, value.hex).apply()
            }
        }

    // MARK: reading

    val isVFD: Boolean get() = theme == VFDTheme.vfd

    /** The 5 ink colours of the current base. */
    val palette: List<VFDRGB> get() = VFDPalette.colors(base)

    /** Index in [baseItems] of the current base: its preset, or CUSTOM (the last item). */
    val baseIndex: Int
        get() {
            val name: String? = base.resolved.name
            if (name != null) {
                for ((i, preset) in VFDBase.presets.withIndex()) {
                    if (preset.name == name) return i
                }
            }
            return VFDBase.presets.size
        }

    val baseIsCustom: Boolean get() = baseIndex == VFDBase.presets.size

    /** RGB of item [index] of [baseItems] (CUSTOM = [customRGB]). */
    fun itemRGB(index: Int): VFDRGB {
        if (index >= 0 && index < VFDBase.presets.size) {
            return VFDBase.presets[index].rgb
        }
        return customRGB
    }

    // MARK: changing

    /** Select item [index] of [baseItems]: a preset, or CUSTOM with [customRGB]. */
    fun selectBase(index: Int) {
        base = if (index >= 0 && index < VFDBase.presets.size) {
            VFDBase.Preset(VFDBase.presets[index].name)
        } else {
            VFDBase.Custom(customRGB)
        }
    }

    /** Pick a custom base colour and select it. */
    fun selectCustom(rgb: VFDRGB) {
        customRGB = rgb
        base = VFDBase.Custom(rgb)
    }
}

// MARK: - Colour picker (Compose has none)

/**
 * A small HSV / RGB colour picker: a preview swatch with its hex, hue / saturation / brightness
 * sliders, red / green / blue sliders (both sets edit the same colour) and a hex field. [onPick]
 * gets the colour on USE COLOUR; CANCEL or a tap outside calls [onDismiss]. Used for the CUSTOM
 * base colour by both SETTINGS screens and by VFDContext.pickColor.
 */
@Composable
fun VFDColorPickerDialog(
    title: String,
    initial: VFDRGB,
    onDismiss: () -> Unit,
    onPick: (VFDRGB) -> Unit,
) {
    val start: FloatArray = remember(initial) { hsvOf(initial) }
    var rgb: VFDRGB by remember(initial) { mutableStateOf(initial) }
    var hue: Float by remember(initial) { mutableFloatStateOf(start[0]) }
    var sat: Float by remember(initial) { mutableFloatStateOf(start[1]) }
    var bright: Float by remember(initial) { mutableFloatStateOf(start[2]) }
    var hexText: String by remember(initial) { mutableStateOf(initial.hex) }

    fun takeRGB(c: VFDRGB, updateHex: Boolean) {
        rgb = c
        if (updateHex) hexText = c.hex
        val hsv: FloatArray = hsvOf(c)
        // Grey and black have no hue (and black no saturation): keep the sliders where they are.
        if (hsv[1] > 0f && hsv[2] > 0f) hue = hsv[0]
        if (hsv[2] > 0f) sat = hsv[1]
        bright = hsv[2]
    }

    fun takeHSV(h: Float, s: Float, v: Float) {
        hue = h
        sat = s
        bright = v
        val packed: Int = android.graphics.Color.HSVToColor(floatArrayOf(h, s, v))
        rgb = VFDRGB.packed(packed and 0xFFFFFF)
        hexText = rgb.hex
    }

    val hueStrip: Brush = remember {
        Brush.horizontalGradient(
            listOf(0f, 60f, 120f, 180f, 240f, 300f, 360f).map { h ->
                Color(android.graphics.Color.HSVToColor(floatArrayOf(h % 360f, 1f, 1f)))
            },
        )
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title, style = techHeader()) },
        text = {
            Column(
                Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        Modifier
                            .size(44.dp)
                            .clip(RoundedCornerShape(4.dp))
                            .background(VFDSettings.color(rgb))
                            .border(0.5.dp, AppColors.PanelLine, RoundedCornerShape(4.dp)),
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(rgb.hex, style = techHeader(), color = AppColors.TextPrimary)
                }
                Spacer(Modifier.height(4.dp))
                Text("HUE ${hue.roundToInt()}°", style = techLabel(), color = AppColors.TextDim)
                Box(Modifier.fillMaxWidth().height(6.dp).clip(RoundedCornerShape(3.dp)).background(hueStrip))
                Slider(value = hue, onValueChange = { takeHSV(it, sat, bright) }, valueRange = 0f..360f)
                Text("SATURATION ${(sat * 100).roundToInt()}%", style = techLabel(), color = AppColors.TextDim)
                Slider(value = sat, onValueChange = { takeHSV(hue, it, bright) }, valueRange = 0f..1f)
                Text("BRIGHTNESS ${(bright * 100).roundToInt()}%", style = techLabel(), color = AppColors.TextDim)
                Slider(value = bright, onValueChange = { takeHSV(hue, sat, it) }, valueRange = 0f..1f)
                Text("RED ${rgb.r}", style = techLabel(), color = AppColors.TextDim)
                Slider(
                    value = rgb.r.toFloat(),
                    onValueChange = { takeRGB(VFDRGB(it.roundToInt(), rgb.g, rgb.b), true) },
                    valueRange = 0f..255f,
                )
                Text("GREEN ${rgb.g}", style = techLabel(), color = AppColors.TextDim)
                Slider(
                    value = rgb.g.toFloat(),
                    onValueChange = { takeRGB(VFDRGB(rgb.r, it.roundToInt(), rgb.b), true) },
                    valueRange = 0f..255f,
                )
                Text("BLUE ${rgb.b}", style = techLabel(), color = AppColors.TextDim)
                Slider(
                    value = rgb.b.toFloat(),
                    onValueChange = { takeRGB(VFDRGB(rgb.r, rgb.g, it.roundToInt()), true) },
                    valueRange = 0f..255f,
                )
                OutlinedTextField(
                    value = hexText,
                    onValueChange = { text ->
                        hexText = text
                        val parsed: VFDRGB? = VFDRGB.parse(text)
                        if (parsed != null) takeRGB(parsed, false)
                    },
                    singleLine = true,
                    textStyle = techLabel(),
                    label = { Text("HEX #RRGGBB", style = techLabel()) },
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.Characters,
                        autoCorrect = false,
                        keyboardType = KeyboardType.Ascii,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onPick(rgb) }) { Text("USE COLOUR", style = techLabel(), color = AppColors.Cyan) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("CANCEL", style = techLabel()) }
        },
    )
}

private fun hsvOf(c: VFDRGB): FloatArray {
    val hsv = FloatArray(3)
    android.graphics.Color.RGBToHSV(c.r, c.g, c.b, hsv)
    return hsv
}
