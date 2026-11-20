package com.magicmaker.android.ui.vfd

import android.content.Context
import android.content.SharedPreferences
import android.widget.Toast
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.colorspace.ColorSpaces
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import com.magicmaker.android.MagicMakerApp
import com.magicmaker.android.core.BandEffectModel
import com.magicmaker.android.data.MagicStore
import com.magicmaker.android.service.ServiceState
import com.magicmaker.android.ui.BandLedAnimation
import com.magicmaker.android.ui.WandPulse
import com.magicmaker.android.ui.labSwatchColor
import com.magicmaker.android.ui.starlightGlowColor

// What a VFD screen gets while it draws (VFDContext), the screen interface the renderer
// dispatches to, per-tab UI state and scroll offsets that last while the app runs (VFDUIState,
// VFDSession), and the true-colour helpers for colour content (VFDColors, VFDAnim).
// Port of ios/MagicMaker/VFD/VFDContext.swift.

// MARK: - Screens

/** A screen's right-aligned header text button (Swift `(text: String, action: () -> Void)`). */
class VFDHeaderRight(val text: String, val action: () -> Unit)

/**
 * One VFD tab, an immediate-mode drawing of the matching standard screen.
 *
 *     object VFDScanScreen : VFDScreen {
 *         override val title: String = "SCAN"
 *         override fun draw(ctx: VFDContext): Int? { ... }
 *     }
 *
 * [draw] lays the content out from `ctx.L.contentTop` in content coordinates into `ctx.fb` and
 * returns the content end row (exclusive), or null when the screen scrolls nothing as a page. It
 * runs twice per frame (a scratch pass for edge snapping, then the real one), so it must not
 * change any state: read `ctx.state`, `ctx.app`, `ctx.ui`, `ctx.scroll(id)`, and change things
 * only inside the closures it hands to the widgets, or in [onShow].
 */
interface VFDScreen {
    /** Header title (mid size, uppercased by the header). */
    val title: String

    /** Optional right-aligned header text button. */
    fun headerRight(ctx: VFDContext): VFDHeaderRight? = null

    /** Content; returns the end row for page scrolling. */
    fun draw(ctx: VFDContext): Int?

    /** Ink of the header's right text (default highlight; dim = shown disabled, no tap). */
    fun headerRightColor(ctx: VFDContext): Int = VFDInk.highlight

    /** A "< BACK" action in the header (default none); the system back button runs it too. */
    fun back(ctx: VFDContext): (() -> Unit)? = null

    /**
     * The tab became visible: the VFD root's first appearance (after its first frame), every tab
     * change, the app's return to the foreground (ON_START after ON_STOP), the core permissions
     * being granted (the tab replaces the GRANT panel), a sheet opened by the VFD closing. Runs on
     * the main thread outside [draw], so it may change state (reload what the standard tab loads
     * when it enters composition); `ctx.tab` is the shown tab, `ctx.time` now, and a redraw
     * follows. It can run more than once per visit, so keep it idempotent (default none).
     */
    fun onShow(ctx: VFDContext) {}
}

// MARK: - Overlay requests

/** One row of [VFDContext.menu]: the label (uppercased when drawn), destructive rows in alarm
 *  ink, disabled rows dim with no tap. [rgb]: a colour row (a wand colour, a palette entry): a
 *  5 x 5 swatch of that true colour starts the row, then a blank glyph and the label,
 *  left-aligned (a trailing " ✓" survives when the label is cut).
 *
 *      VFDMenuItem(name, rgb = VFDColors.starlightGlow(index)) { pick(index) } */
class VFDMenuItem(
    val label: String,
    val destructive: Boolean = false,
    val enabled: Boolean = true,
    val rgb: VFDRGB? = null,
    val action: () -> Unit,
)

/** The keyboard of a [VFDContext.prompt] text field. */
enum class VFDKeyboard {
    /** Free text (names, labels). */
    text,
    /** Digits only. */
    number,
    /** Digits and a decimal point. */
    decimal,
    /** Digits and punctuation (negative numbers, times). */
    signed,
    /** An IP address (digits and dots). */
    ip,
    url,
    /** Hex bytes: ASCII keys, typed in capitals. */
    hex;

    val keyboardType: KeyboardType
        get() = when (this) {
            text -> KeyboardType.Text
            number -> KeyboardType.Number
            decimal -> KeyboardType.Decimal
            signed -> KeyboardType.Phone
            ip -> KeyboardType.Phone
            url -> KeyboardType.Uri
            hex -> KeyboardType.Ascii
        }

    val capitalization: KeyboardCapitalization
        get() = when (this) {
            text -> KeyboardCapitalization.Sentences
            hex -> KeyboardCapitalization.Characters
            else -> KeyboardCapitalization.None
        }
}

/** What a [VFDContext.sheet] gets while it shows: the live app state (it recomposes on every
 *  change), the host's permission state and actions, and [dismiss]. */
class VFDSheetScope(
    val app: MagicMakerApp,
    val state: ServiceState.UiState,
    val host: VFDHost,
    val dismiss: () -> Unit,
)

// MARK: - Context

/**
 * What a VFD screen gets: the frame buffer and layout of the frame being drawn, the animation
 * time, the app (store, service state), its own UI state and scroll offsets, and the overlays
 * (Material dialogs, a VFD-drawn menu, a full-screen dialog with standard Compose UI). One
 * context lives as long as the VFD root; the renderer points it at each frame.
 */
class VFDContext internal constructor(
    val app: MagicMakerApp,
    val settings: VFDSettings,
    private val renderer: VFDRenderer,
    fb: VFDFrameBuffer,
    L: VFDLayout,
) {
    private val session: VFDSession = VFDSession

    /** The library, logs and preferences (`app.store`). */
    val store: MagicStore get() = app.store

    /** The Activity's context: service intents (MagicMakerForegroundService.send), startActivity,
     *  toasts. */
    val context: Context get() = renderer.activityContext ?: app

    /** The service state this frame is drawn from (ServiceState.UiState; the same snapshot the
     *  standard screens get). Closures read it at tap time and get the latest one. */
    var state: ServiceState.UiState = ServiceState.state.value
        internal set

    /** Bluetooth / location / notification permissions granted (else the tabs show GRANT). */
    val coreGranted: Boolean get() = renderer.host?.coreGranted ?: false

    /** NEARBY_WIFI_DEVICES granted (always true before Android 13). */
    val wifiGranted: Boolean get() = renderer.host?.wifiGranted ?: false

    /** The buffer to draw into: a scratch buffer on the snapping pass, then the real one. */
    var fb: VFDFrameBuffer = fb
        private set
    var L: VFDLayout = L
        private set
    /** Seconds since the epoch (System.currentTimeMillis() / 1000) for this frame; the same value
     *  on both passes. Animations derive their phase from it. */
    var time: Double = 0.0
        private set
    /** Key of the tab being drawn: "scan" "tx" "wand" "auto" "relay" "logs" "map" "diag" "lab"
     *  "settings". */
    var tab: String = "scan"
        private set
    /** Physical pixels per dp (LocalDensity's density, e.g. 2.625 or 3), as the renderer lays the
     *  grid out (iOS: displayScale). */
    var displayScale: Double = 3.0
        private set
    /** Physical pixels per cell including its 1 px gap: max(4, round(density * 5 / 3)). */
    var cellPitch: Int = 5
        private set

    // MARK: renderer only

    /** Point the context at a new frame (renderer only). */
    internal fun beginFrame(fb: VFDFrameBuffer, L: VFDLayout, time: Double, tab: String) {
        this.fb = fb
        this.L = L
        this.time = time
        this.tab = tab
    }

    /** Switch the buffer between the two passes (renderer only). */
    internal fun use(fb: VFDFrameBuffer) {
        this.fb = fb
    }

    /** The grid's geometry on this screen (renderer only). */
    internal fun setDisplay(scale: Double, pitch: Int) {
        if (scale.isFinite() && scale > 0.0) {
            displayScale = scale
        }
        if (pitch > 0) {
            cellPitch = pitch
        }
    }

    /** Point the context at a tab about to show, between frames, for its onShow (renderer only). */
    internal fun beginShow(tab: String) {
        this.tab = tab
        this.time = System.currentTimeMillis() / 1000.0
    }

    // MARK: geometry

    /** Dp as whole cells at the renderer's pitch, rounded half to even (Python round(), as the
     *  layouts' point sizes are converted; iOS cells(points:)): e.g. a standard view's 48 dp. */
    fun cells(dp: Double): Int = cellsAt(dp, displayScale, cellPitch)

    /** [cells] for a whole number of dp. */
    fun cells(dp: Int): Int = cells(dp.toDouble())

    // MARK: state

    /** This tab's UI state (collapsed sections, selections, drafts), kept while the app runs. */
    val ui: VFDUIState get() = session.ui(tab)

    /** Another tab's UI state. */
    fun uiState(tab: String): VFDUIState = session.ui(tab)

    /** The current time in epoch seconds, for actions ([time] is the frame's). */
    val now: Double get() = System.currentTimeMillis() / 1000.0

    /** Rows the page content is scrolled by (the renderer applies it; screens rarely need it). */
    val pageScroll: Int get() = session.pageScroll(tab)

    fun setPageScroll(rows: Int) {
        session.setPageScroll(tab, maxOf(0, rows))
        redraw()
    }

    /** Offset in rows of this tab's scroll region [id] (see VFDFrameBuffer.scrollRegion). */
    fun scroll(id: String): Int = session.regionScroll(tab, id)

    /** scroll(id) clamped to 0..limit (limit = content rows - window rows), for a list whose
     *  content may have shrunk since the last drag. */
    fun scroll(id: String, limit: Int): Int {
        val v: Int = session.regionScroll(tab, id)
        return maxOf(0, minOf(v, maxOf(0, limit)))
    }

    /** Set a scroll region's offset (e.g. back to the top after a filter change). */
    fun setScroll(id: String, rows: Int) {
        session.setRegionScroll(tab, id, maxOf(0, rows))
        redraw()
    }

    /** A value computed once per [revision] (e.g. `state.storeRevision`) and kept until the
     *  revision changes: store reads and decoding that should not run twice a frame. Keys are
     *  global (prefix them with the tab). Safe to call from draw. */
    fun <T> cached(key: String, revision: Any?, compute: () -> T): T = session.cached(key, revision, compute)

    // MARK: overlays

    /** Material alert with one text field (numbers, names, IP addresses). [onDone] gets the text as
     *  typed when OK is tapped; nothing happens on CANCEL. Asked for while another dialog is up
     *  (a prompt, a confirm, the colour picker) or from one's completion (another prompt's
     *  [onDone], a confirm's action), it waits and shows once that one has closed, in order, so
     *  chained prompts need no delay; it never replaces the dialog on screen. */
    fun prompt(title: String, message: String = "", text: String = "", keyboard: VFDKeyboard = VFDKeyboard.text,
               onDone: (String) -> Unit) {
        renderer.presentPrompt(VFDPromptRequest(title, message, keyboard, onDone), text)
    }

    /** Material alert with CANCEL and [confirmLabel] (red when destructive), which runs [action].
     *  Queues like [prompt]: safe to call from another dialog's completion. */
    fun confirm(title: String, message: String = "", confirmLabel: String = "OK", destructive: Boolean = false,
                action: () -> Unit) {
        renderer.presentConfirm(VFDConfirmRequest(title, message, confirmLabel, destructive, action))
    }

    /** A VFD-drawn modal menu over the content: the title boxed, one row per item, then CANCEL.
     *  While it is open it takes every tap; a tap outside it (or the back button) closes it.
     *  Picking an item closes the menu first, then runs the item's action. [selected]: index of
     *  the current item; it is drawn as the selected row (a solid block, label cut out, like a
     *  selected [OPTION]) and a long list opens scrolled so that row is centred (as far as the
     *  list allows). */
    fun menu(title: String, items: List<VFDMenuItem>, selected: Int? = null) {
        renderer.presentMenu(VFDMenuRequest(title, items, selected))
    }

    val menuOpen: Boolean get() = renderer.menuOpen

    fun closeMenu() {
        renderer.closeMenu()
    }

    /** Standard Compose UI in a full-screen dialog with a DONE button (QR, file pickers, anything
     *  not drawn on the grid). [content] gets the live state through [VFDSheetScope]. */
    fun sheet(id: String, content: @Composable (VFDSheetScope) -> Unit) {
        renderer.presentSheet(VFDSheetItem(id, content))
    }

    fun dismissSheet() {
        renderer.dismissSheet()
    }

    /** The standard screen of a tab ("scan" ... "settings") in a sheet. */
    fun openStandard(tab: String) {
        val key: String = tab
        sheet("standard:$key") { scope ->
            VFDStandardScreen(key, scope)
        }
    }

    /** The HSV / RGB colour picker dialog; [onPick] gets the chosen colour. */
    fun pickColor(title: String, initial: VFDRGB, onPick: (VFDRGB) -> Unit) {
        renderer.presentColorPicker(VFDColorRequest(title, initial, onPick))
    }

    /** Switch to a tab by key, as the tab bar does. */
    fun selectTab(key: String) {
        renderer.selectTab(key)
    }

    /** Draw again soon (after a change the renderer cannot see, e.g. a finished background job). */
    fun redraw() {
        renderer.requestRedraw()
    }

    /** A short system toast (the standard screens report many results this way). */
    fun toast(text: String, long: Boolean = false) {
        Toast.makeText(context, text, if (long) Toast.LENGTH_LONG else Toast.LENGTH_SHORT).show()
    }

    /** A haptic tick (the hold gesture already gives one). */
    fun haptic() {
        renderer.hapticTick()
    }

    // MARK: host (MagicMakerAppRoot)

    /** Ask for the Bluetooth / location / notification permissions (the standard GRANT button). */
    fun requestPermissions() {
        renderer.host?.requestPermissions?.invoke()
    }

    /** Ask for NEARBY_WIFI_DEVICES (RELAY's GRANT NEARBY). */
    fun requestWifiPermission() {
        renderer.host?.requestWifiPermission?.invoke()
    }

    /** Load a packet into the Lab and switch to LAB (the standard "load in Lab" actions). */
    fun loadInLab(hex: String, label: String) {
        renderer.host?.loadInLab?.invoke(hex, label)
    }

    internal companion object {
        /** [dp] at [scale] px per dp as whole cells of [pitch] px, rounded half to even. */
        fun cellsAt(dp: Double, scale: Double, pitch: Int): Int {
            val p: Int = maxOf(1, pitch)
            return VFDMath.roundHalfEven(dp * scale / p.toDouble())
        }
    }
}

// MARK: - UI state

/**
 * Typed key/value UI state of one tab (collapsed sections, selections, drafts), kept in memory
 * while the app runs. The `stored...` accessors read and write SharedPreferences instead (default
 * "magicmaker_ui", the file UiPrefs and the Lab use; pass [mainPrefs] for "magicmaker"), so a
 * screen can share what the standard screen persists (same keys, same value types). Setters
 * redraw; call them from actions only, never from draw.
 */
class VFDUIState(val tab: String) {
    companion object {
        /** UiPrefs' file: collapsed sections, lab_extended, ... */
        const val uiPrefs: String = "magicmaker_ui"
        /** MagicStore's preferences file (prefer MagicStore's own getters and setters). */
        const val mainPrefs: String = "magicmaker"
    }

    private val values: HashMap<String, Any> = HashMap()
    internal var notify: (() -> Unit)? = null

    private fun changed() {
        notify?.invoke()
    }

    fun has(key: String): Boolean = values.containsKey(key)

    fun remove(key: String) {
        values.remove(key)
        changed()
    }

    // MARK: in memory

    fun bool(key: String, default: Boolean = false): Boolean = (values[key] as? Boolean) ?: default

    fun setBool(key: String, value: Boolean) {
        values[key] = value
        changed()
    }

    /** Flip a Bool (starting from [default] when unset). */
    fun toggleBool(key: String, default: Boolean = false) {
        setBool(key, !bool(key, default))
    }

    fun int(key: String, default: Int = 0): Int = (values[key] as? Int) ?: default

    fun setInt(key: String, value: Int) {
        values[key] = value
        changed()
    }

    fun double(key: String, default: Double = 0.0): Double = (values[key] as? Double) ?: default

    fun setDouble(key: String, value: Double) {
        values[key] = value
        changed()
    }

    fun string(key: String, default: String = ""): String = (values[key] as? String) ?: default

    fun setString(key: String, value: String) {
        values[key] = value
        changed()
    }

    /** A string that may be unset (a selected id, an open item). */
    fun optionalString(key: String): String? = values[key] as? String

    fun setOptionalString(key: String, value: String?) {
        if (value != null) {
            values[key] = value
        } else {
            values.remove(key)
        }
        changed()
    }

    @Suppress("UNCHECKED_CAST")
    fun strings(key: String): Set<String> = (values[key] as? Set<String>) ?: emptySet()

    fun setStrings(key: String, value: Set<String>) {
        values[key] = HashSet(value)
        changed()
    }

    /** Add [member] to the set at [key], or remove it if present. */
    fun toggleMember(key: String, member: String) {
        val set = HashSet(strings(key))
        if (!set.remove(member)) set.add(member)
        setStrings(key, set)
    }

    // MARK: persisted (SharedPreferences, shared with the standard screens)

    private fun openPrefs(name: String): SharedPreferences? =
        VFDSession.appContext?.getSharedPreferences(name, Context.MODE_PRIVATE)

    /** A Boolean, or "true"/"false" text. */
    fun storedBool(key: String, default: Boolean, prefs: String = uiPrefs): Boolean {
        val p: SharedPreferences = openPrefs(prefs) ?: return default
        return try {
            p.getBoolean(key, default)
        } catch (e: ClassCastException) {
            val text: String? = try { p.getString(key, null) } catch (e2: ClassCastException) { null }
            if (text != null) text.trim().lowercase() == "true" else default
        }
    }

    fun setStoredBool(key: String, value: Boolean, prefs: String = uiPrefs) {
        openPrefs(prefs)?.edit()?.putBoolean(key, value)?.apply()
        changed()
    }

    /** An Int (a Long in range, or a number as text). */
    fun storedInt(key: String, default: Int, prefs: String = uiPrefs): Int {
        val p: SharedPreferences = openPrefs(prefs) ?: return default
        return try {
            p.getInt(key, default)
        } catch (e: ClassCastException) {
            val long: Long? = try { p.getLong(key, 0L) } catch (e2: ClassCastException) { null }
            if (long != null && long >= Int.MIN_VALUE && long <= Int.MAX_VALUE) {
                long.toInt()
            } else {
                val text: String? = try { p.getString(key, null) } catch (e3: ClassCastException) { null }
                text?.trim()?.toIntOrNull() ?: default
            }
        }
    }

    fun setStoredInt(key: String, value: Int, prefs: String = uiPrefs) {
        openPrefs(prefs)?.edit()?.putInt(key, value)?.apply()
        changed()
    }

    fun storedLong(key: String, default: Long, prefs: String = uiPrefs): Long {
        val p: SharedPreferences = openPrefs(prefs) ?: return default
        return try {
            p.getLong(key, default)
        } catch (e: ClassCastException) {
            val int: Int? = try { p.getInt(key, 0) } catch (e2: ClassCastException) { null }
            int?.toLong() ?: default
        }
    }

    fun setStoredLong(key: String, value: Long, prefs: String = uiPrefs) {
        openPrefs(prefs)?.edit()?.putLong(key, value)?.apply()
        changed()
    }

    fun storedFloat(key: String, default: Float, prefs: String = uiPrefs): Float {
        val p: SharedPreferences = openPrefs(prefs) ?: return default
        return try {
            p.getFloat(key, default)
        } catch (e: ClassCastException) {
            default
        }
    }

    fun setStoredFloat(key: String, value: Float, prefs: String = uiPrefs) {
        openPrefs(prefs)?.edit()?.putFloat(key, value)?.apply()
        changed()
    }

    fun storedString(key: String, default: String, prefs: String = uiPrefs): String {
        val p: SharedPreferences = openPrefs(prefs) ?: return default
        return try {
            p.getString(key, null) ?: default
        } catch (e: ClassCastException) {
            default
        }
    }

    fun setStoredString(key: String, value: String, prefs: String = uiPrefs) {
        openPrefs(prefs)?.edit()?.putString(key, value)?.apply()
        changed()
    }

    /** A string set (UiPrefs' collapsed sections are stored this way). */
    fun storedStringSet(key: String, prefs: String = uiPrefs): Set<String> {
        val p: SharedPreferences = openPrefs(prefs) ?: return emptySet()
        return try {
            p.getStringSet(key, null)?.toSet() ?: emptySet()
        } catch (e: ClassCastException) {
            emptySet()
        }
    }

    fun setStoredStringSet(key: String, value: Set<String>, prefs: String = uiPrefs) {
        openPrefs(prefs)?.edit()?.putStringSet(key, HashSet(value))?.apply()
        changed()
    }
}

/** Per-tab UI state and scroll offsets for the whole run of the app, so they survive tab
 *  switches and switching the theme away and back. Main thread only. */
object VFDSession {
    /** Called after any UI state change (the renderer redraws). */
    internal var onChange: (() -> Unit)? = null
    /** For the stored UI state accessors (set by the renderer). */
    internal var appContext: Context? = null

    private val states: HashMap<String, VFDUIState> = HashMap()
    private val pages: HashMap<String, Int> = HashMap()
    private val regions: HashMap<String, HashMap<String, Int>> = HashMap()
    private val memo: HashMap<String, Memo> = HashMap()

    private class Memo(val revision: Any?, val value: Any?)

    fun ui(tab: String): VFDUIState {
        val existing: VFDUIState? = states[tab]
        if (existing != null) return existing
        val s = VFDUIState(tab)
        s.notify = { onChange?.invoke() }
        states[tab] = s
        return s
    }

    fun pageScroll(tab: String): Int = pages[tab] ?: 0

    fun setPageScroll(tab: String, rows: Int) {
        pages[tab] = rows
    }

    fun regionScroll(tab: String, id: String): Int = regions[tab]?.get(id) ?: 0

    fun setRegionScroll(tab: String, id: String, rows: Int) {
        val map: HashMap<String, Int> = regions.getOrPut(tab) { HashMap() }
        map[id] = rows
    }

    @Suppress("UNCHECKED_CAST")
    fun <T> cached(key: String, revision: Any?, compute: () -> T): T {
        val m: Memo? = memo[key]
        if (m != null && m.revision == revision) return m.value as T
        val v: T = compute()
        memo[key] = Memo(revision, v)
        return v
    }
}

// MARK: - True colours for colour content

/** The real colours of packet content as VFD true colours (`fb.rgb(...)`): band LEDs, the wand
 *  glow, palette swatches. Text and chrome never use these. */
object VFDColors {
    /** Unlit cell colour: a faded band LED is mixed toward it, so it never reads darker than the grid. */
    val unlit: VFDRGB = VFDPalette.unlitRGB

    /** sRGB channels 0..1 (clamped). */
    fun rgb(red: Double, green: Double, blue: Double): VFDRGB = VFDRGB(unitRed = red, green = green, blue = blue)

    /** 0xRRGGBB (Swift `rgb(packed:)`). */
    fun rgb(packed: Int): VFDRGB = VFDRGB.packed(packed)

    /** A Compose colour as an opaque RGB, its alpha mixed over [over] (default the unlit cell). */
    fun rgb(color: Color, over: VFDRGB = unlit): VFDRGB {
        val c: Color = if (color.colorSpace == ColorSpaces.Srgb) color else color.convert(ColorSpaces.Srgb)
        val a: Double = minOf(maxOf(c.alpha.toDouble(), 0.0), 1.0)
        val r: Double = c.red * a + over.r / 255.0 * (1.0 - a)
        val g: Double = c.green * a + over.g / 255.0 * (1.0 - a)
        val b: Double = c.blue * a + over.b / 255.0 * (1.0 - a)
        return VFDRGB(unitRed = r, green = g, blue = b)
    }

    /** The wand glow colour of starlight palette index [index] (low 5 bits), as StarlightWandView
     *  draws it. */
    fun starlightGlow(index: Int): VFDRGB = rgb(starlightGlowColor(index))

    /** The Lab palette swatch of 5-bit colour index [index] (labSwatchColor: Lab colour slots,
     *  palette dropdowns, the band preview's LED colours). */
    fun labSwatch(index: Int): VFDRGB = rgb(labSwatchColor(index))

    /** The decoded band effect of a packet, as BandPreview decodes it (EMPTY when it cannot be
     *  decoded). The last few are kept, so calling it every frame is cheap. */
    fun bandModel(hex: String): BandEffectModel {
        for (e in modelCache) {
            if (e.first == hex) return e.second
        }
        val m: BandEffectModel = runCatching { BandEffectModel.from(hex) }.getOrDefault(BandEffectModel.EMPTY)
        modelCache.add(0, hex to m)
        while (modelCache.size > 8) modelCache.removeAt(modelCache.size - 1)
        return m
    }

    private val modelCache: ArrayList<Pair<String, BandEffectModel>> = ArrayList()

    /** The band preview's loop phase 0..<1 at [time] (epoch seconds, ctx.time). */
    fun bandPhase(time: Double): Float = BandLedAnimation.phase(time)

    /** Band LED zone [zone] (0..4 = Z1 bottom-left, Z2 top-left, Z3 centre, Z4 top-right, Z5
     *  bottom-right) of [model] at [time], as BandPreview animates it, with its opacity mixed over
     *  the unlit cell colour; null = off (draw the dim unlit ring: `VFDW.led(fb, x, y, null)`,
     *  else `VFDW.led(fb, x, y, 0, fill = rgb)`). */
    fun bandLED(model: BandEffectModel, zone: Int, time: Double): VFDRGB? {
        val led: Color = BandLedAnimation.color(model, zone, BandLedAnimation.phase(time)) ?: return null
        return rgb(led, unlit)
    }

    /** Whether the BUZZ line is in its bright half at [time] (BandPreview's 6-per-loop blink). */
    fun buzzOn(time: Double): Boolean = BandLedAnimation.buzzOn(BandLedAnimation.phase(time))
}

/** Progress 0..1 of the wand's two send-pulse rings. */
data class VFDPulse(val first: Double, val second: Double)

/** Timing helpers that match the standard theme's Compose animations. */
object VFDAnim {
    /** The wand send pulse (StarlightWandView): each ring runs 0.42 s, FastOutSlowIn (the default
     *  tween easing), the second starts 0.18 s later. */
    val pulseDuration: Double = WandPulse.DURATION_MS / 1000.0
    val pulseDelay: Double = WandPulse.DELAY_MS / 1000.0
    /** A ring at progress p is drawn 1 + pulseScaleGain * p times the aura size ... */
    val pulseScaleGain: Double = WandPulse.SCALE_GAIN.toDouble()
    /** ... with peak alpha ringPeak * (1 - pulseFade * p). */
    val pulseFade: Double = WandPulse.FADE.toDouble()
    val ringPeaks: List<Double> = listOf(WandPulse.FIRST_RING_PEAK.toDouble(), WandPulse.SECOND_RING_PEAK.toDouble())

    /** Compose's FastOutSlowInEasing (the default tween easing) at x in 0..1. */
    fun easing(x: Double): Double {
        if (x <= 0.0) return 0.0
        if (x >= 1.0) return 1.0
        return WandPulse.easing.transform(x.toFloat()).toDouble()
    }

    /** Progress 0..1 of the two pulse rings [elapsed] seconds after a send (1 once done, as the
     *  standard wand keeps them; 0 before the first send: pass a negative elapsed). */
    fun wandPulse(elapsed: Double): VFDPulse {
        if (elapsed < 0.0) return VFDPulse(0.0, 0.0)
        val a: Double = easing(elapsed / pulseDuration)
        val b: Double = easing((elapsed - pulseDelay) / pulseDuration)
        return VFDPulse(a, b)
    }

    /** True while a pulse started [elapsed] seconds ago is still moving. */
    fun pulseRunning(elapsed: Double): Boolean = elapsed >= 0.0 && elapsed < pulseDelay + pulseDuration
}

// MARK: - Placeholder screens

/** The placeholder layout of a tab not drawn on the grid yet: a panel with a note and a few live
 *  readings, then a button that opens the standard screen in a sheet. */
object VFDStub {
    const val note: String = "THIS TAB IS NOT DRAWN ON THE VFD GRID YET. EVERY CONTROL IS ON THE STANDARD SCREEN."

    /** A reading in display case, "—" when empty. */
    fun value(s: String): String = if (s.isEmpty()) "—" else VFDW.upper(s)

    /** Draws the placeholder for tab [tab] (its label goes on the button). Returns the end row. */
    fun draw(ctx: VFDContext, tab: String, label: String, readings: List<Pair<String, String>>): Int {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val c: Int = L.left
        val w: Int = L.width
        val top: Int = L.contentTop
        val inner: VFDPanelInner = VFDW.panelInner(c, top, w, title = true)
        var y: Int = inner.r
        y = VFDW.textBlock(fb, L, inner.c, y, inner.w, note, color = VFDInk.text)
        for ((key, value) in readings) {
            y = VFDW.kv(fb, L, inner.c, y, inner.w, key, value)
        }
        y = VFDW.panel(fb, L, c, top, w, y - top + 2, title = "VFD $label")
        y += VFDW.groupGap
        val key: String = tab
        y = VFDW.button(fb, L, c, y, w, "OPEN STANDARD $label", primary = true, action = {
            ctx.openStandard(key)
        })
        return y
    }
}
