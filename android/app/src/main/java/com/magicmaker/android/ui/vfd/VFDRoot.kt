package com.magicmaker.android.ui.vfd

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
import android.view.Window
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.DecayAnimationSpec
import androidx.compose.animation.core.calculateTargetValue
import androidx.compose.animation.splineBasedDecay
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.ImageShader
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.hapticfeedback.HapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.PointerEvent
import androidx.compose.ui.input.pointer.PointerId
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.magicmaker.android.MagicMakerApp
import com.magicmaker.android.core.CrashLog
import com.magicmaker.android.service.ServiceState
import com.magicmaker.android.ui.AppColors
import com.magicmaker.android.ui.AutoTab
import com.magicmaker.android.ui.DiagnosticsTab
import com.magicmaker.android.ui.LabTabScreen
import com.magicmaker.android.ui.LogsTab
import com.magicmaker.android.ui.MapTab
import com.magicmaker.android.ui.RelayTab
import com.magicmaker.android.ui.ScanTab
import com.magicmaker.android.ui.SettingsTabScreen
import com.magicmaker.android.ui.TransmitTab
import com.magicmaker.android.ui.WandTab
import com.magicmaker.android.ui.techHeader
import com.magicmaker.android.ui.techLabel
import com.magicmaker.android.ui.telemetryLineText
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlin.coroutines.cancellation.CancellationException
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.roundToInt

// The VFD theme's whole screen: one full-screen Compose Canvas painting the cell frame buffer
// (palette inks and true colours, 1 px black gaps; pixel for pixel what tools/vfd/vfd.py
// render_image makes), the chrome and the current tab drawn in two passes with edge snapping
// (render_previews.draw_screen), touch handling on the cell grid (tap, hold, scroll with a fling,
// slider drags, swipes), the overlays and the animation clock.
// Port of ios/MagicMaker/VFD/VFDRootView.swift.

// MARK: - Host

/** What MagicMakerAppRoot hands the VFD theme besides the service state: the permission state and
 *  launchers it owns, and the "load in Lab" action the SCAN and TX tabs share. */
class VFDHost(
    val coreGranted: Boolean,
    val wifiGranted: Boolean,
    val requestPermissions: () -> Unit,
    val requestWifiPermission: () -> Unit,
    val loadInLab: (String, String) -> Unit,
)

// MARK: - Overlay requests

internal class VFDPromptRequest(
    val title: String,
    val message: String,
    val keyboard: VFDKeyboard,
    val onDone: (String) -> Unit,
)

internal class VFDConfirmRequest(
    val title: String,
    val message: String,
    val confirmLabel: String,
    val destructive: Boolean,
    val action: () -> Unit,
)

internal class VFDMenuRequest(
    val title: String,
    val items: List<VFDMenuItem>,
    /** The current item: drawn as the selected row and scrolled into view on open. */
    val selected: Int? = null,
)

internal class VFDSheetItem(val id: String, val content: @Composable (VFDSheetScope) -> Unit)

internal class VFDColorRequest(val title: String, val initial: VFDRGB, val onPick: (VFDRGB) -> Unit)

/** A prompt or confirm waiting for the dialog on screen to close. */
internal sealed class VFDQueuedAlert {
    class Prompt(val request: VFDPromptRequest, val text: String) : VFDQueuedAlert()
    class Confirm(val request: VFDConfirmRequest) : VFDQueuedAlert()
}

/**
 * The order prompts and confirms show in: one asked for while a dialog is up, while one is
 * closing (from its completion: a prompt's onDone, a confirm's action) or while others already
 * wait, goes to the back of the line; each close lets the next one show once the closed dialog has
 * settled. Pure bookkeeping (the renderer shows, closes and times).
 */
internal class VFDAlertQueue<T> {
    private val waiting: ArrayDeque<T> = ArrayDeque()

    /** A dialog was closed and the next one waits for it to settle. */
    var closing: Boolean = false
        private set

    val size: Int get() = waiting.size

    /** [item] to show now, or null when it was queued ([dialogUp]: a dialog is on screen). */
    fun offer(item: T, dialogUp: Boolean): T? {
        if (dialogUp || closing || waiting.isNotEmpty()) {
            waiting.addLast(item)
            return null
        }
        return item
    }

    /** The dialog on screen closed (before its completion runs). */
    fun closed() {
        closing = true
    }

    /** The closed dialog has settled: the next one to show, if any and none is up. */
    fun settle(dialogUp: Boolean): T? {
        closing = false
        if (dialogUp) return null
        return waiting.removeFirstOrNull()
    }
}

// MARK: - Root

/**
 * The VFD theme: the whole screen is one cell grid drawn by [VFDRenderer]. MagicMakerAppRoot
 * shows it instead of the tab bar and tab content and shares its tab selection: [tab] is the
 * selected tab's key, [onSelectTab] selects another one.
 */
@Composable
fun VFDRoot(
    app: MagicMakerApp,
    state: ServiceState.UiState,
    tab: String,
    onSelectTab: (String) -> Unit,
    host: VFDHost,
) {
    val activity: Context = LocalContext.current
    val density: Density = LocalDensity.current
    val haptic: HapticFeedback = LocalHapticFeedback.current
    val settings: VFDSettings = remember(app) { VFDSettings.shared(app) }
    val renderer: VFDRenderer = remember(app, settings) { VFDRenderer(app, settings) }
    // System bars (and a cutout) become safe rows, and in landscape safe columns: nothing is drawn
    // there.
    val insets: WindowInsets = WindowInsets.systemBars.union(WindowInsets.displayCutout)
    val layoutDirection: LayoutDirection = LocalLayoutDirection.current
    val insetTop: Int = insets.getTop(density)
    val insetBottom: Int = insets.getBottom(density)
    val insetLeft: Int = insets.getLeft(density, layoutDirection)
    val insetRight: Int = insets.getRight(density, layoutDirection)

    SideEffect {
        renderer.setInputs(
            VFDRenderer.Inputs(
                state = state,
                tab = tab,
                host = host,
                onSelectTab = onSelectTab,
                context = activity,
                haptic = haptic,
                density = density,
                insetTop = insetTop,
                insetBottom = insetBottom,
                insetLeft = insetLeft,
                insetRight = insetRight,
            ),
        )
    }

    DisposableEffect(renderer) {
        renderer.attach()
        onDispose { renderer.detach() }
    }

    // Light status / navigation bar content over the black grid (iOS: .preferredColorScheme(.dark)),
    // put back as it was when the standard theme returns.
    val view: View = LocalView.current
    DisposableEffect(view, activity) {
        val window: Window? = findActivity(activity)?.window
        val controller: WindowInsetsControllerCompat? = window?.let { WindowCompat.getInsetsController(it, view) }
        val lightStatus: Boolean = controller?.isAppearanceLightStatusBars ?: false
        val lightNav: Boolean = controller?.isAppearanceLightNavigationBars ?: false
        // Before Android 10 the system draws no contrast scrim of its own: enableEdgeToEdge() paints
        // the navigation bar near-white in light mode, which would hide the light buttons below.
        val navColor: Int? = if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) window?.navigationBarColor else null
        if (navColor != null) {
            window?.navigationBarColor = android.graphics.Color.TRANSPARENT
        }
        controller?.isAppearanceLightStatusBars = false
        controller?.isAppearanceLightNavigationBars = false
        onDispose {
            controller?.isAppearanceLightStatusBars = lightStatus
            controller?.isAppearanceLightNavigationBars = lightNav
            if (navColor != null) {
                window?.navigationBarColor = navColor
            }
        }
    }

    // The clock runs only while the app is on screen: in the background (the foreground service
    // keeps the process alive for hours) nothing ticks; coming back draws a fresh frame at once.
    val lifecycleOwner: LifecycleOwner = LocalLifecycleOwner.current
    LaunchedEffect(renderer, lifecycleOwner) {
        lifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
            renderer.requestRedraw()
            renderer.runClock()
        }
    }

    // The return to the foreground (ON_START after ON_STOP) shows the tab again (VFDScreen.onShow);
    // a pause alone (a permission dialog, the recents screen) does not.
    DisposableEffect(renderer, lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_STOP -> renderer.appStopped()
                Lifecycle.Event.ON_START -> renderer.appStarted()
                else -> {}
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // The system back button closes the menu first, then runs the screen's "< BACK". Dialogs and
    // the sheet close themselves on back.
    BackHandler(enabled = renderer.menuShown) {
        renderer.closeMenu()
    }
    BackHandler(enabled = renderer.backShown && !renderer.menuShown) {
        renderer.goBack()
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        Canvas(
            Modifier
                .fillMaxSize()
                .pointerInput(renderer) { vfdTouches(renderer) },
        ) {
            // Reading the tick here makes every requestRedraw() draw (and compose) a new frame.
            val frame: Int = renderer.tick
            renderer.render(this, frame)
        }
    }

    // Keyed by the request: a queued dialog is a new window (the closed one goes away first),
    // never the old one with new content.
    val prompt: VFDPromptRequest? = renderer.promptRequest
    if (prompt != null) {
        key(prompt) {
            VFDPromptDialog(renderer, prompt)
        }
    }
    val confirm: VFDConfirmRequest? = renderer.confirmRequest
    if (confirm != null) {
        key(confirm) {
            VFDConfirmDialog(renderer, confirm)
        }
    }
    val colour: VFDColorRequest? = renderer.colorRequest
    if (colour != null) {
        key(colour) {
            VFDColorPickerDialog(
                title = colour.title,
                initial = colour.initial,
                onDismiss = { renderer.cancelColorPicker(colour) },
                onPick = { rgb -> renderer.finishColorPicker(colour, rgb) },
            )
        }
    }
    val sheet: VFDSheetItem? = renderer.sheetItem
    if (sheet != null) {
        key(sheet.id) {
            VFDSheetDialog(sheet, VFDSheetScope(app, state, host) { renderer.dismissSheet() })
        }
    }
}

private fun findActivity(context: Context): Activity? {
    var c: Context? = context
    while (c != null) {
        if (c is Activity) return c
        c = (c as? ContextWrapper)?.baseContext
    }
    return null
}

// MARK: - Dialogs

@Composable
private fun VFDPromptDialog(renderer: VFDRenderer, req: VFDPromptRequest) {
    val focus: FocusRequester = remember(req) { FocusRequester() }
    AlertDialog(
        onDismissRequest = { renderer.cancelPrompt(req) },
        title = { Text(req.title, style = techHeader()) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                if (req.message.isNotEmpty()) {
                    Text(req.message, style = techLabel(), color = AppColors.TextDim)
                }
                OutlinedTextField(
                    value = renderer.promptText,
                    onValueChange = { renderer.promptText = it },
                    singleLine = true,
                    textStyle = MaterialTheme.typography.bodyMedium,
                    visualTransformation = if (req.keyboard == VFDKeyboard.password) {
                        PasswordVisualTransformation()
                    } else {
                        VisualTransformation.None
                    },
                    keyboardOptions = KeyboardOptions(
                        capitalization = req.keyboard.capitalization,
                        autoCorrect = false,
                        keyboardType = req.keyboard.keyboardType,
                        imeAction = ImeAction.Done,
                    ),
                    keyboardActions = KeyboardActions(onDone = { renderer.finishPrompt(req) }),
                    modifier = Modifier.fillMaxWidth().focusRequester(focus),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { renderer.finishPrompt(req) }) {
                Text("OK", style = techLabel(), color = AppColors.Cyan)
            }
        },
        dismissButton = {
            TextButton(onClick = { renderer.cancelPrompt(req) }) { Text("CANCEL", style = techLabel()) }
        },
    )
    LaunchedEffect(req) {
        delay(80)
        runCatching { focus.requestFocus() }
    }
}

@Composable
private fun VFDConfirmDialog(renderer: VFDRenderer, req: VFDConfirmRequest) {
    val message: String = req.message
    AlertDialog(
        onDismissRequest = { renderer.cancelConfirm(req) },
        title = { Text(req.title, style = techHeader()) },
        text = if (message.isEmpty()) null else ({ Text(message, style = techLabel()) }),
        confirmButton = {
            TextButton(onClick = { renderer.finishConfirm(req) }) {
                Text(
                    req.confirmLabel.uppercase(),
                    style = techLabel(),
                    color = if (req.destructive) MaterialTheme.colorScheme.error else AppColors.Cyan,
                )
            }
        },
        dismissButton = {
            TextButton(onClick = { renderer.cancelConfirm(req) }) { Text("CANCEL", style = techLabel()) }
        },
    )
}

/** Standard Compose UI full screen over the VFD grid, with a DONE button. */
@Composable
private fun VFDSheetDialog(item: VFDSheetItem, scope: VFDSheetScope) {
    Dialog(
        onDismissRequest = scope.dismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(Modifier.fillMaxSize(), color = AppColors.Navy) {
            Column(Modifier.fillMaxSize()) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick = scope.dismiss) {
                        Text("DONE", style = techHeader(), color = AppColors.Cyan)
                    }
                }
                Box(Modifier.fillMaxWidth().weight(1f)) {
                    item.content(scope)
                }
            }
        }
    }
}

/** The standard Compose screen of a tab, shown in a sheet by VFDContext.openStandard (the same
 *  calls MagicMakerAppRoot makes). */
@Composable
internal fun VFDStandardScreen(tab: String, scope: VFDSheetScope) {
    val app: MagicMakerApp = scope.app
    val state: ServiceState.UiState = scope.state
    val host: VFDHost = scope.host
    when (tab) {
        "scan" -> ScanTab(state, host.loadInLab)
        "tx" -> TransmitTab(app, state, host.loadInLab)
        "wand" -> WandTab(
            app = app,
            storeRevision = state.storeRevision,
            starlightLoopEnabled = state.starlightLoopEnabled,
            starlightLoopPacketId = state.starlightLoopPacketId,
            starlightIntervalMs = state.starlightIntervalMs,
            wandDisplayColorIndex = state.wandDisplayColorIndex,
            running = state.running,
        )
        "auto" -> AutoTab(app, state)
        "relay" -> RelayTab(state, host.coreGranted, host.wifiGranted, host.requestWifiPermission)
        "logs" -> LogsTab(app, state)
        "map" -> MapTab(app, state.storeRevision)
        "diag" -> DiagnosticsTab(state)
        "lab" -> LabTabScreen(app, LocalContext.current, state.storeRevision, state.labLoadTick)
        else -> SettingsTabScreen(app, state.storeRevision)
    }
}

// MARK: - Gestures

/** One pointer drives everything (as the iOS DragGesture(minimumDistance: 0)): the touch down at
 *  once, a hold timed from there, then moves and the release. */
private suspend fun PointerInputScope.vfdTouches(renderer: VFDRenderer) {
    awaitEachGesture {
        val down: PointerInputChange = awaitFirstDown(requireUnconsumed = false)
        down.consume()
        val id: PointerId = down.id
        val tracker = VelocityTracker()
        tracker.addPosition(down.uptimeMillis, down.position)
        val serial: Int = renderer.touchDown(down.position)
        val holdAt: Long = down.uptimeMillis + VFDRenderer.holdMillis
        var done = false
        try {
            while (!done) {
                val event: PointerEvent = if (renderer.holdPending(serial)) {
                    val wait: Long = holdAt - SystemClock.uptimeMillis()
                    val e: PointerEvent? = if (wait > 0) withTimeoutOrNull(wait) { awaitPointerEvent() } else null
                    if (e == null) {
                        renderer.holdFired(serial)
                        continue
                    }
                    e
                } else {
                    awaitPointerEvent()
                }
                val change: PointerInputChange? = event.changes.firstOrNull { it.id == id }
                if (change == null) {
                    renderer.touchCancel(serial)
                    done = true
                    continue
                }
                if (!change.pressed) {
                    if (change.isConsumed) {
                        // A cancelled gesture (the system took the touch, the Canvas left the
                        // screen): Compose reports it as an up that is already consumed. Nothing
                        // runs, as on iOS.
                        renderer.touchCancel(serial)
                    } else {
                        tracker.addPosition(change.uptimeMillis, change.position)
                        change.consume()
                        renderer.touchUp(serial, change.position, tracker.calculateVelocity().y)
                    }
                    done = true
                } else {
                    tracker.addPosition(change.uptimeMillis, change.position)
                    if (change.positionChanged()) {
                        renderer.touchMove(serial, change.position)
                    }
                    change.consume()
                }
            }
        } catch (e: CancellationException) {
            renderer.touchCancel(serial)
            throw e
        }
    }
}

// MARK: - Renderer

private enum class VFDTouchMode {
    /** Down, not moved past the slop yet: a tap on release, a hold after 0.5 s. */
    pending,
    /** The hold fired; the release does nothing. */
    held,
    scroll,
    /** Horizontal drag on a hit with `drag` (sliders). */
    slide,
    /** Horizontal drag on a hit with swipe actions; decided on release. */
    swipe,
    ignored,
}

private enum class VFDScrollKind { page, region, menu }

private class VFDTouch(
    val serial: Int,
    val start: Offset,
    val hit: VFDHit?,
    val region: VFDScrollRegion?,
) {
    var mode: VFDTouchMode = VFDTouchMode.pending
    var kind: VFDScrollKind = VFDScrollKind.page
    var regionId: String = ""
    var scrollStart: Int = 0
    var limit: Int = 0
}

private class VFDFling(
    val tab: String,
    val kind: VFDScrollKind,
    val regionId: String,
    val from: Int,
    val to: Int,
    val start: Double,
    val duration: Double,
)

/** The header of one frame. */
private class VFDChrome(
    val tab: String,
    val title: String,
    val telemetry: String,
    val right: VFDHeaderRight?,
    val rightColor: Int,
    val back: (() -> Unit)?,
)

/**
 * Draws VFD frames and handles touches. Frames are composed on demand (a state change, an
 * action, the clock) into two reused frame buffers and painted from a reused bitmap: the
 * Canvas reads [tick], so every [requestRedraw] composes and paints one new frame in the draw
 * pass (coalesced to one per display frame). Main thread only.
 */
internal class VFDRenderer(val app: MagicMakerApp, val settings: VFDSettings) {
    /** What the composition hands the renderer (refreshed after every recomposition). */
    class Inputs(
        val state: ServiceState.UiState,
        val tab: String,
        val host: VFDHost,
        val onSelectTab: (String) -> Unit,
        val context: Context,
        val haptic: HapticFeedback,
        val density: Density,
        val insetTop: Int,
        val insetBottom: Int,
        /** Physical left / right insets in px (side navigation bar, cutout: landscape). */
        val insetLeft: Int,
        val insetRight: Int,
    )

    companion object {
        /** Movement (dp) before a touch counts as a drag. */
        const val slopDp: Float = 8f
        /** Horizontal travel (dp) for a swipe action. */
        const val swipeDp: Float = 40f
        /** Held still this long for a long press. */
        const val holdMillis: Long = 500L
        /** Scroll region id of the open menu's list. */
        const val menuRegion: String = "vfd.menu"
        /** A queued prompt or confirm shows this long after the last dialog closed, so the closed
         *  window has gone (and its keyboard with it) before the next one opens. */
        const val alertSettleMillis: Long = 200L

        /** Unlit cell colour (#090909) of the safe columns beside the frame buffer. */
        private val unlitColor: Color = Color(VFDPalette.unlitRGB.argb)

        /** The Android tabs in tab-bar order (MagicMakerScreens AppTab). */
        val tabKeys: List<String> = listOf("scan", "tx", "wand", "auto", "relay", "logs", "map", "diag", "lab", "settings")

        fun screen(key: String): VFDScreen = when (key) {
            "scan" -> VFDScanScreen
            "tx" -> VFDTxScreen
            "wand" -> VFDWandScreen
            "auto" -> VFDAutoScreen
            "relay" -> VFDRelayScreen
            "logs" -> VFDLogsScreen
            "map" -> VFDMapScreen
            "diag" -> VFDDiagScreen
            "lab" -> VFDLabScreen
            else -> VFDSettingsScreen
        }

        /** SCAN TX WAND AUTO RELAY / LOGS MAP DIAG LAB SETTINGS (SETUP when it does not fit). */
        fun androidTabs(L: VFDLayout): List<VFDTab> = tabKeys.map { VFDTab(it, L.tabLabel(it)) }

        /** Rows a system bar inset of [px] device pixels covers, rounded up. */
        fun safeRows(px: Int, pitch: Int): Int {
            if (px <= 0 || pitch <= 0) return 0
            return minOf(10_000, (px + pitch - 1) / pitch)
        }

        /** Largest page scroll: content rows past the content region. */
        private fun pageLimit(end: Int?, L: VFDLayout): Int {
            val e: Int = end ?: return 0
            return maxOf(0, e - L.contentTop - L.contentH)
        }

        private fun reset(b: VFDFrameBuffer, base: VFDBase, alarmInverted: Boolean) {
            b.reset()
            b.base = base
            b.alarmInverted = alarmInverted
        }

        /** The list offset (whole rows) that centres row [index] in a window of [shownRows] rows,
         *  as far as the list allows (0 for no or an out-of-range index). */
        fun revealScroll(index: Int, count: Int, shownRows: Int, rowH: Int): Int {
            if (index < 0 || index >= count || shownRows <= 0) return 0
            val first: Int = index - (shownRows - 1) / 2
            val lastFirst: Int = maxOf(0, count - shownRows)
            return maxOf(0, minOf(first, lastFirst)) * rowH
        }

        /** VFDText.fit, except that a trailing " ✓" (the current item's tick) survives the cut. */
        fun fitKeepingTick(s: String, maxCols: Int): String {
            val tick = " ✓"
            if (!s.endsWith(tick) || VFDText.width(s) <= maxCols) {
                return VFDText.fit(s, maxCols)
            }
            val head: String = VFDText.fit(s.dropLast(tick.length), maxCols - 2 * VFDW.adv)
            if (head.isEmpty()) {
                return VFDText.fit("✓", maxCols)
            }
            return head + tick
        }

        /** One menu row, ctrlH tall, at (c, y), w wide. Without `rgb`: VFDW.button (the current row
         *  as the primary block). With it: the same box or block, a 5 x 5 swatch of the true colour
         *  at c + 3 (the first glyph slot), a blank glyph slot, then the label left-aligned at
         *  c + 15; on a block the swatch keeps an unlit 7 x 7 ring and the label is cut out, as on
         *  a selected BASE COLOUR chip. Tap "menu:<LABEL>" when enabled runs [pick]. */
        fun drawMenuRow(fb: VFDFrameBuffer, L: VFDLayout, item: VFDMenuItem, current: Boolean, c: Int, y: Int,
                        w: Int, pick: () -> Unit) {
            val name: String = "menu:" + VFDW.upper(item.label)
            val color: VFDRGB = item.rgb ?: run {
                VFDW.button(fb, L, c, y, w, item.label, primary = current, enabled = item.enabled, name = name,
                            alarm = item.destructive, action = pick)
                return
            }
            val ty: Int = y + VFDW.ctrlText
            val sx: Int = c + 3
            val tx: Int = sx + 2 * VFDW.adv
            val label: String = fitKeepingTick(VFDW.upper(item.label), c + w - 2 - tx)
            var solid = false
            var border: Int = if (item.enabled) VFDInk.highlight else VFDInk.dim
            var ink: Int = if (item.enabled) VFDInk.text else VFDInk.dim
            if (item.enabled && item.destructive) {
                if (fb.alarmInverted) {
                    solid = true
                } else {
                    border = VFDInk.alarm
                    ink = VFDInk.alarm
                }
            } else if (item.enabled && current) {
                solid = true
            }
            if (solid) {
                fb.fill(c, y, w, VFDW.ctrlH, VFDInk.highlight)
                fb.fill(sx - 1, ty, 7, 7, VFDInk.unlit)
                ink = VFDInk.unlit
            } else {
                fb.box(c, y, w, VFDW.ctrlH, border)
            }
            val swatch: Int = fb.rgb(color)
            fb.fill(sx, ty + 1, 5, 5, swatch)
            fb.text(tx, ty, label, VFDSize.small, ink)
            if (item.enabled) {
                VFDW.tap(fb, c, y, w, VFDW.ctrlH, name, action = pick)
            }
        }

        /** A pitch x pitch tile, transparent but for its right column and bottom row in black,
         *  repeated over the grid with nearest sampling: the 1 px gap of every cell in one draw. */
        private fun gapPaint(pitch: Int): Paint {
            val tile: Bitmap = Bitmap.createBitmap(pitch, pitch, Bitmap.Config.ARGB_8888)
            val black: Int = 0xFF000000.toInt()
            for (i in 0 until pitch) {
                tile.setPixel(pitch - 1, i, black)
                tile.setPixel(i, pitch - 1, black)
            }
            val paint: Paint = Paint()
            paint.shader = ImageShader(tile.asImageBitmap(), TileMode.Repeated, TileMode.Repeated)
            paint.filterQuality = FilterQuality.None
            paint.isAntiAlias = false
            return paint
        }
    }

    // MARK: compose-observed state

    /** Bumped to draw again (read by the Canvas). */
    var tick: Int by mutableIntStateOf(0)
        private set
    var promptRequest: VFDPromptRequest? by mutableStateOf(null)
    var promptText: TextFieldValue by mutableStateOf(TextFieldValue(""))
    var confirmRequest: VFDConfirmRequest? by mutableStateOf(null)
    var sheetItem: VFDSheetItem? by mutableStateOf(null)
    var colorRequest: VFDColorRequest? by mutableStateOf(null)
    /** A menu is open (the back button closes it). */
    var menuShown: Boolean by mutableStateOf(false)
        private set
    /** The current screen has a "< BACK" (the back button runs it). */
    var backShown: Boolean by mutableStateOf(false)
        private set
    /** The clock runs at 30 fps while true (written while drawing, so not snapshot state). */
    private val fast: MutableStateFlow<Boolean> = MutableStateFlow(false)

    private val session: VFDSession = VFDSession
    private val main: Handler = Handler(Looper.getMainLooper())
    private val sessionChange: () -> Unit = { requestRedraw() }
    private val onTab: (String) -> Unit = { key -> selectTab(key) }
    private val closeMenuAction: () -> Unit = { closeMenu() }

    var inputs: Inputs? = null
        private set
    val host: VFDHost? get() = inputs?.host
    val activityContext: Context? get() = inputs?.context

    // geometry
    private var pitch: Int = 0
    /** Columns of the frame buffer (the grid minus the safe columns at the sides). */
    private var cols: Int = 0
    private var rows: Int = 0
    /** Columns of the whole painted grid, and the safe columns left of the frame buffer. */
    private var gridCols: Int = 0
    private var originCol: Int = 0
    private var safeTop: Int = -1
    private var safeBottom: Int = -1
    private var layout: VFDLayout? = null
    private var fb: VFDFrameBuffer? = null
    private var probe: VFDFrameBuffer? = null
    private var tabList: List<VFDTab> = emptyList()
    private var bitmap: Bitmap? = null
    private var image: ImageBitmap? = null
    private var pixels: IntArray? = null
    private val lut: IntArray = IntArray(256)
    private var gaps: Paint? = null
    private var decay: DecayAnimationSpec<Float>? = null
    private var decayDensity: Float = 0f

    // frames
    private var context: VFDContext? = null
    private var currentTab: String = ""
    private var pageMax: Int = 0
    private var lastBack: (() -> Unit)? = null
    private var rendering: Boolean = false
    private var redrawAfterRender: Boolean = false
    private var syncPosted: Boolean = false
    private var shownBack: Boolean = false
    private var shownMenu: Boolean = false
    private var lastError: String? = null

    // menu
    private var menu: VFDMenuRequest? = null
    private var menuScroll: Int = 0
    private var menuMax: Int = 0
    /** Row to scroll into view when the open menu is first drawn. */
    private var menuReveal: Int? = null

    // dialogs
    /** Prompts and confirms asked for while a dialog was up or closing, in order. */
    private val alerts: VFDAlertQueue<VFDQueuedAlert> = VFDAlertQueue()
    private var alertSettlePosted: Boolean = false
    private val alertSettle: Runnable = Runnable {
        alertSettlePosted = false
        settleAlerts()
    }

    // tab visibility (VFDScreen.onShow)
    private var showPending: Boolean = false
    private var showPosted: Boolean = false
    private var wentBackground: Boolean = false
    private val showRunnable: Runnable = Runnable {
        showPosted = false
        runPendingShow()
    }

    // touches
    private var touch: VFDTouch? = null
    private var touchSerial: Int = 0
    private var fling: VFDFling? = null

    // MARK: lifecycle

    fun attach() {
        session.appContext = app
        session.onChange = sessionChange
        if (alerts.closing || alerts.size > 0) {
            postAlertSettle()
        }
        if (showPending) {
            postShow()
        }
    }

    fun detach() {
        if (session.onChange === sessionChange) {
            session.onChange = null
        }
        main.removeCallbacksAndMessages(null)
        syncPosted = false
        alertSettlePosted = false
        showPosted = false
    }

    /** New composition inputs: redraw when what a frame shows changed, close what belonged to the
     *  old tab when the tab changed (here or from loadInLab). */
    fun setInputs(next: Inputs) {
        val prev: Inputs? = inputs
        inputs = next
        context?.state = next.state
        val d: Float = next.density.density
        if (decay == null || d != decayDensity) {
            decay = splineBasedDecay(next.density)
            decayDensity = d
        }
        if (prev == null) {
            requestRedraw()
            // First appearance: onShow runs after the first frame.
            tabShown()
            return
        }
        if (prev.tab != next.tab) {
            tabChanged()
            tabShown()
        } else if (!prev.host.coreGranted && next.host.coreGranted) {
            // The tab takes the GRANT panel's place, as the standard tab enters composition then.
            tabShown()
        }
        val changed: Boolean = prev.state !== next.state || prev.tab != next.tab ||
            prev.host.coreGranted != next.host.coreGranted || prev.host.wifiGranted != next.host.wifiGranted ||
            prev.insetTop != next.insetTop || prev.insetBottom != next.insetBottom ||
            prev.insetLeft != next.insetLeft || prev.insetRight != next.insetRight || prev.density.density != d
        if (changed) {
            requestRedraw()
        }
    }

    // MARK: redraw and clock

    /** Draw again (coalesced into the next display frame). */
    fun requestRedraw() {
        if (rendering) {
            redrawAfterRender = true
            return
        }
        tick += 1
    }

    /** 30 fps while the last frame animated (or a fling runs), else once a second (twice on a
     *  red-ish base, for the 1 Hz alarm blink), just after whole (and half) seconds. */
    suspend fun runClock() {
        var lastFast = 0L
        while (true) {
            if (fast.value) {
                val t: Long = withFrameNanos { it }
                if (t - lastFast >= 30_000_000L) {
                    lastFast = t
                    requestRedraw()
                }
            } else {
                val interval: Long = if (VFDPalette.alarmInverted(settings.base)) 500L else 1000L
                val nowMs: Long = System.currentTimeMillis()
                val wait: Long = interval - nowMs % interval + 20L
                val woke: Boolean? = kotlinx.coroutines.withTimeoutOrNull(wait) { fast.first { it } }
                if (woke == null) {
                    requestRedraw()
                }
            }
        }
    }

    /** menuShown / backShown follow the frame, set after the draw pass (the draw pass compares
     *  plain mirrors, so it never reads or writes that snapshot state itself). */
    private fun syncShown() {
        if ((lastBack != null) == shownBack && (menu != null) == shownMenu) return
        if (syncPosted) return
        syncPosted = true
        main.post {
            syncPosted = false
            shownBack = lastBack != null
            shownMenu = menu != null
            backShown = shownBack
            menuShown = shownMenu
        }
    }

    // MARK: overlays

    val menuOpen: Boolean get() = menu != null

    /** A prompt, a confirm or the colour picker is on screen. */
    private val dialogUp: Boolean get() = promptRequest != null || confirmRequest != null || colorRequest != null

    fun presentPrompt(request: VFDPromptRequest, text: String) {
        val now: VFDQueuedAlert = alerts.offer(VFDQueuedAlert.Prompt(request, text), dialogUp) ?: return
        showAlert(now)
    }

    /** OK on the prompt (or the keyboard's Done): the dialog counts as closing before onDone runs,
     *  so a prompt or confirm asked for there waits until this one has gone. */
    fun finishPrompt(request: VFDPromptRequest) {
        if (promptRequest !== request) return
        val text: String = promptText.text
        promptRequest = null
        // A secret is not kept in the renderer once its prompt has gone.
        if (request.keyboard == VFDKeyboard.password) promptText = TextFieldValue("")
        alertClosed()
        runAction("prompt") { request.onDone(text) }
        requestRedraw()
    }

    /** CANCEL, back or a tap outside the prompt. */
    fun cancelPrompt(request: VFDPromptRequest) {
        if (promptRequest !== request) return
        promptRequest = null
        if (request.keyboard == VFDKeyboard.password) promptText = TextFieldValue("")
        alertClosed()
        requestRedraw()
    }

    fun presentConfirm(request: VFDConfirmRequest) {
        val now: VFDQueuedAlert = alerts.offer(VFDQueuedAlert.Confirm(request), dialogUp) ?: return
        showAlert(now)
    }

    fun finishConfirm(request: VFDConfirmRequest) {
        if (confirmRequest !== request) return
        confirmRequest = null
        alertClosed()
        runAction("confirm") { request.action() }
        requestRedraw()
    }

    /** CANCEL, back or a tap outside the confirm. */
    fun cancelConfirm(request: VFDConfirmRequest) {
        if (confirmRequest !== request) return
        confirmRequest = null
        alertClosed()
        requestRedraw()
    }

    private fun showAlert(alert: VFDQueuedAlert) {
        setMenu(null)
        when (alert) {
            is VFDQueuedAlert.Prompt -> {
                val text: String = alert.text
                promptText = TextFieldValue(text, TextRange(text.length))
                promptRequest = alert.request
            }
            is VFDQueuedAlert.Confirm -> confirmRequest = alert.request
        }
        requestRedraw()
    }

    /** A dialog is going away; the next queued one shows once it has settled. */
    private fun alertClosed() {
        alerts.closed()
        postAlertSettle()
    }

    private fun postAlertSettle() {
        if (alertSettlePosted) return
        alertSettlePosted = true
        main.postDelayed(alertSettle, alertSettleMillis)
    }

    private fun settleAlerts() {
        val next: VFDQueuedAlert = alerts.settle(dialogUp) ?: return
        showAlert(next)
    }

    fun presentMenu(request: VFDMenuRequest) {
        setMenu(request)
        menuScroll = 0
        menuMax = 0
        menuReveal = request.selected
        fling = null
        requestRedraw()
    }

    fun closeMenu() {
        setMenu(null)
        requestRedraw()
    }

    private fun setMenu(m: VFDMenuRequest?) {
        menu = m
        if (m == null) {
            menuReveal = null
        }
        shownMenu = m != null
        menuShown = shownMenu
    }

    fun presentSheet(item: VFDSheetItem) {
        setMenu(null)
        sheetItem = item
    }

    /** DONE, back, or VFDContext.dismissSheet: the tab shows again (onShow). */
    fun dismissSheet() {
        val wasOpen: Boolean = sheetItem != null
        sheetItem = null
        if (wasOpen) {
            tabShown()
        }
        requestRedraw()
    }

    fun presentColorPicker(request: VFDColorRequest) {
        setMenu(null)
        colorRequest = request
    }

    fun finishColorPicker(request: VFDColorRequest, rgb: VFDRGB) {
        if (colorRequest !== request) return
        colorRequest = null
        alertClosed()
        runAction("colour") { request.onPick(rgb) }
        requestRedraw()
    }

    /** CANCEL, back or a tap outside the colour picker. */
    fun cancelColorPicker(request: VFDColorRequest) {
        if (colorRequest !== request) return
        colorRequest = null
        alertClosed()
        requestRedraw()
    }

    /** Tab bar tap (or VFDContext.selectTab). The tab already shown scrolls back to the top. */
    fun selectTab(key: String) {
        val inp: Inputs = inputs ?: return
        if (key !in tabKeys) return
        setMenu(null)
        fling = null
        if (key == currentTab) {
            session.setPageScroll(key, 0)
        }
        inp.onSelectTab(key)
        requestRedraw()
    }

    /** The shared tab changed (here or from loadInLab): close what belongs to the old one. */
    private fun tabChanged() {
        setMenu(null)
        fling = null
        touch = null
        if (sheetItem != null) {
            sheetItem = null
        }
        requestRedraw()
    }

    // MARK: tab visibility

    /** The tab on screen became visible: run its screen's onShow on the main thread, outside
     *  drawing, then redraw. Before the first frame there is no context yet; it then runs right
     *  after that frame. Coalesced: several triggers in one turn run it once. */
    private fun tabShown() {
        showPending = true
        postShow()
    }

    private fun postShow() {
        if (showPosted) return
        showPosted = true
        main.post(showRunnable)
    }

    /** ON_STOP: the app went to the background. */
    fun appStopped() {
        wentBackground = true
    }

    /** ON_START: back in the foreground after ON_STOP shows the tab again. */
    fun appStarted() {
        if (!wentBackground) return
        wentBackground = false
        tabShown()
    }

    private fun runPendingShow() {
        if (!showPending) return
        if (rendering) {
            postShow()
            return
        }
        val ctx: VFDContext = context ?: return
        val inp: Inputs = inputs ?: return
        showPending = false
        // The GRANT panel stands in for the tab until the core permissions are granted (setInputs
        // shows the tab then).
        if (!inp.host.coreGranted) return
        val key: String = inp.tab
        ctx.state = inp.state
        ctx.beginShow(key)
        try {
            screen(key).onShow(ctx)
        } catch (e: Exception) {
            noteError(e, "VFD onShow · $key")
        }
        requestRedraw()
    }

    /** The system back button: the screen's "< BACK". */
    fun goBack() {
        val back: (() -> Unit)? = lastBack
        if (back != null) {
            runAction("back") { back() }
            requestRedraw()
        }
    }

    /**
     * Runs a screen's closure: a tap, hold, swipe or slider drag (a menu pick and a header button
     * are taps), a dialog's completion, the back action. These run outside the draw pass, where a
     * throw would crash the app (and, the theme being saved, cost the next launch the VFD): a bug
     * in one is recorded in the crash log and reported in a short toast instead, as a draw error
     * shows the error panel. Every closure that does not throw runs exactly as before. (The
     * closures never suspend, so even a CancellationException from one is a bug of its own;
     * rethrown from the gesture coroutine it would quietly end touch handling.)
     */
    private inline fun runAction(kind: String, block: () -> Unit) {
        try {
            block()
        } catch (e: Exception) {
            noteError(e, "VFD $kind · " + (inputs?.tab ?: ""))
            val context: Context = inputs?.context ?: app
            runCatching {
                Toast.makeText(context, "That did not work (" + e.javaClass.simpleName + ")", Toast.LENGTH_SHORT)
                    .show()
            }
        }
    }

    fun hapticTick() {
        inputs?.haptic?.performHapticFeedback(HapticFeedbackType.TextHandleMove)
    }

    // MARK: frame

    /** Compose a frame for the current state and paint it (the Canvas draw pass). */
    fun render(scope: DrawScope, frame: Int) {
        scope.drawRect(Color.Black)
        val inp: Inputs = inputs ?: return
        if (frame < 0) return
        val w: Int = scope.size.width.toInt()
        val h: Int = scope.size.height.toInt()
        if (!prepare(w, h, inp)) {
            // Too small to lay out (a tiny multi-window size): nothing is drawn, so no hit of the
            // last frame may still fire, and the clock slows down.
            this.fb?.reset()
            touch = null
            fling = null
            if (fast.value) fast.value = false
            return
        }
        val fb: VFDFrameBuffer = this.fb ?: return
        val probe: VFDFrameBuffer = this.probe ?: return
        val L: VFDLayout = this.layout ?: return
        val ctx: VFDContext = this.context ?: return
        val base: VFDBase = settings.base
        ctx.state = inp.state
        ctx.setDisplay(inp.density.density.toDouble(), pitch)
        rendering = true
        try {
            composeSafely(ctx, fb, probe, L, inp, base)
        } finally {
            rendering = false
        }
        paint(scope, fb, base)
        val wantFast: Boolean = fb.wantsAnimation || fling != null
        if (fast.value != wantFast) {
            fast.value = wantFast
        }
        syncShown()
        if (showPending) {
            // A show asked for before the first frame runs right after it.
            postShow()
        }
        if (redrawAfterRender) {
            // A redraw asked for while drawing (a screen should not): one more frame, later.
            redrawAfterRender = false
            main.post { requestRedraw() }
        }
    }

    /** Grid geometry from the screen: pitch = max(4, round(density * 5 / 3)) physical px per cell
     *  including its 1 px gap (the spec's 5 px at 3x and 4 px at 2x; iOS uses the same rule with
     *  its scale), grid cols / rows = whole cells, safe rows = the top / bottom system bar insets
     *  rounded up to whole cells, safe columns likewise for the side insets (landscape: navigation
     *  bar, cutout); the frame buffer covers the grid between the safe columns. Rebuilds the
     *  buffers when it changes. False while the size is too small to lay out. */
    private fun prepare(w: Int, h: Int, inp: Inputs): Boolean {
        if (w <= 0 || h <= 0) return false
        val density: Float = inp.density.density
        val pitch: Int = maxOf(4, Math.round(density * 5f / 3f))
        val gridCols: Int = w / pitch
        val left: Int = safeRows(inp.insetLeft, pitch)
        val right: Int = safeRows(inp.insetRight, pitch)
        val cols: Int = gridCols - left - right
        val rows: Int = h / pitch
        if (cols < 60 || rows < 150) return false
        val top: Int = safeRows(inp.insetTop, pitch)
        val bottom: Int = safeRows(inp.insetBottom, pitch)
        val same: Boolean = cols == this.cols && rows == this.rows && pitch == this.pitch &&
            gridCols == this.gridCols && left == originCol && top == safeTop && bottom == safeBottom
        if (same && fb != null && layout != null && bitmap != null && context != null) {
            return true
        }
        val L = VFDLayout(cols, rows, top, bottom)
        if (L.contentH < 40 || L.width < 60) return false
        this.pitch = pitch
        this.cols = cols
        this.gridCols = gridCols
        this.originCol = left
        this.rows = rows
        this.safeTop = top
        this.safeBottom = bottom
        this.layout = L
        val fb = VFDFrameBuffer(cols, rows)
        this.fb = fb
        this.probe = VFDFrameBuffer(cols, rows)
        this.tabList = androidTabs(L)
        this.pixels = IntArray(cols * rows)
        val bmp: Bitmap = Bitmap.createBitmap(cols, rows, Bitmap.Config.ARGB_8888)
        this.bitmap = bmp
        this.image = bmp.asImageBitmap()
        this.gaps = gapPaint(pitch)
        val ctx: VFDContext? = context
        if (ctx == null) {
            context = VFDContext(app, settings, this, fb, L)
        } else {
            ctx.beginFrame(fb, L, ctx.time, ctx.tab)
        }
        this.touch = null
        return true
    }

    // MARK: compose

    private fun composeSafely(ctx: VFDContext, fb: VFDFrameBuffer, probe: VFDFrameBuffer, L: VFDLayout,
                              inp: Inputs, base: VFDBase) {
        try {
            compose(ctx, fb, probe, L, inp, base)
        } catch (e: Exception) {
            // A screen bug must not crash the app on every launch (the theme is persisted): show
            // the error with a way back to the standard theme.
            noteError(e)
            menu = null
            try {
                composeError(ctx, fb, probe, L, inp, base, e)
            } catch (e2: Exception) {
                fb.reset()
            }
        }
    }

    private fun compose(ctx: VFDContext, fb: VFDFrameBuffer, probe: VFDFrameBuffer, L: VFDLayout,
                        inp: Inputs, base: VFDBase) {
        val now: Double = System.currentTimeMillis() / 1000.0
        val key: String = inp.tab
        if (key != currentTab) {
            currentTab = key
            fling = null
            menu = null
        }
        // Red-ish base: alarms are inverted blocks during the first half of every second.
        val blinkOn: Boolean = now - floor(now) < 0.5
        val alarmInverted: Boolean = blinkOn && VFDPalette.alarmInverted(base)
        ctx.beginFrame(fb, L, now, key)
        advanceFling(now)

        val screen: VFDScreen = screen(key)
        val content: VFDScreen = if (inp.host.coreGranted) screen else VFDPermissionGate
        val chrome = VFDChrome(
            tab = key,
            title = screen.title,
            telemetry = telemetryLineText(inp.state),
            right = content.headerRight(ctx),
            rightColor = content.headerRightColor(ctx),
            back = content.back(ctx),
        )
        lastBack = chrome.back
        var scroll: Int = session.pageScroll(key)
        var end: Int? = drawPasses(content, ctx, chrome, fb, probe, L, scroll, base, alarmInverted)
        val limit: Int = pageLimit(end, L)
        if (scroll > limit) {
            // The content got shorter: clamp and draw again at the new offset.
            scroll = limit
            session.setPageScroll(key, limit)
            end = drawPasses(content, ctx, chrome, fb, probe, L, scroll, base, alarmInverted)
        }
        pageMax = pageLimit(end, L)
        val m: VFDMenuRequest? = menu
        if (m != null) {
            drawMenu(m, fb, L)
        }
    }

    /** render_previews.draw_screen: the content once on the scratch buffer to snap the window,
     *  then the chrome, the content clipped to that window, hidden partial taps dropped, the
     *  scrollbar. Returns the screen's end row. */
    private fun drawPasses(screen: VFDScreen, ctx: VFDContext, chrome: VFDChrome, fb: VFDFrameBuffer,
                           probe: VFDFrameBuffer, L: VFDLayout, scroll: Int, base: VFDBase,
                           alarmInverted: Boolean): Int? {
        reset(fb, base, alarmInverted)
        val right: VFDHeaderRight? = chrome.right
        return VFDW.drawScreen(
            fb, L, tab = chrome.tab, title = chrome.title, telemetry = chrome.telemetry,
            back = chrome.back != null, right = right?.text, rightColor = chrome.rightColor, rightTap = null,
            scroll = scroll, tabs = tabList, onBack = chrome.back, onRight = right?.action, onTab = onTab,
            probe = probe,
        ) { b, _ ->
            ctx.use(b)
            screen.draw(ctx)
        }
    }

    /** The fallback frame when a screen threw: the chrome, the error, STANDARD THEME and the
     *  standard screen of the tab. */
    private fun composeError(ctx: VFDContext, fb: VFDFrameBuffer, probe: VFDFrameBuffer, L: VFDLayout,
                             inp: Inputs, base: VFDBase, error: Exception) {
        val key: String = inp.tab
        val message: String = (error.javaClass.simpleName + ": " + (error.message ?: "")).take(300)
        lastBack = null
        reset(fb, base, false)
        val end: Int? = VFDW.drawScreen(
            fb, L, tab = key, title = screen(key).title, telemetry = telemetryLineText(inp.state),
            scroll = 0, tabs = tabList, onTab = onTab, probe = probe,
        ) { b, l ->
            val c: Int = l.left
            val w: Int = l.width
            var y: Int = l.contentTop
            y = VFDW.statusLine(b, l, c, y, w, "VFD SCREEN ERROR", color = VFDInk.alarm)
            y = VFDW.textBlock(b, l, c, y, w, message, color = VFDInk.dim)
            y += VFDW.groupGap
            y = VFDW.button(b, l, c, y, w, "SWITCH TO STANDARD THEME", primary = true, action = {
                settings.theme = VFDTheme.standard
            })
            y = VFDW.button(b, l, c, y, w, "OPEN STANDARD " + VFDW.upper(l.tabLabel(key)), action = {
                ctx.openStandard(key)
            })
            y
        }
        pageMax = pageLimit(end, L)
        session.setPageScroll(key, 0)
    }

    private fun noteError(e: Exception, origin: String = "VFD draw · " + (inputs?.tab ?: "")) {
        val text: String = e.javaClass.name + ": " + e.message
        if (text == lastError) return
        lastError = text
        CrashLog.record(e, origin)
    }

    // MARK: menu

    /** The open menu over a blanked content region: a highlight panel with the title set into its
     *  top border, one button row per item (a list that scrolls when it does not fit; colour rows
     *  with their swatch, the current item as a solid block, scrolled into view on open), then
     *  CANCEL. A full-screen hit under it closes it on a tap anywhere else. */
    private fun drawMenu(m: VFDMenuRequest, fb: VFDFrameBuffer, L: VFDLayout) {
        while (fb.clipDepth > 0) {
            fb.popClip()
        }
        fb.fill(0, L.contentTop, fb.cols, L.contentH, VFDInk.unlit)
        fb.tap(0, 0, fb.cols, fb.rows, name = "menu:outside", action = closeMenuAction)
        val c: Int = L.left
        val w: Int = L.width
        val hasTitle: Boolean = m.title.isNotEmpty()
        val rowH: Int = VFDW.ctrlH + VFDW.gap
        val head: Int = if (hasTitle) 10 else 4
        val foot: Int = rowH + 2
        val room: Int = L.contentH - 4 - head - foot
        val maxRows: Int = maxOf(1, room / rowH)
        val shownRows: Int = minOf(maxOf(1, m.items.size), maxRows)
        val listH: Int = shownRows * rowH
        val panelH: Int = head + listH + foot
        val top: Int = L.contentTop + maxOf(2, (L.contentH - panelH) / 2)
        val inner: VFDPanelInner = VFDW.panelInner(c, top, w, title = hasTitle)
        val listTop: Int = inner.r
        val contentRows: Int = m.items.size * rowH
        menuMax = maxOf(0, contentRows - listH)
        val reveal: Int? = menuReveal
        if (reveal != null) {
            // First draw of a menu with a current item: open with that row centred in view.
            menuReveal = null
            menuScroll = revealScroll(reveal, m.items.size, shownRows, rowH)
        }
        menuScroll = maxOf(0, minOf(menuScroll, menuMax))
        // Taps on the panel between the rows do nothing (only taps outside it close the menu).
        fb.tap(c, top, w, panelH, name = "menu:panel")

        // Drawn at the nearest whole row, so no button is ever cut by the list edges.
        val offset: Int = minOf(menuMax, ((menuScroll + rowH / 2) / rowH) * rowH)
        fb.pushClip(0, listTop, fb.cols, listH)
        var y: Int = listTop - offset
        for ((index, item) in m.items.withIndex()) {
            if (y + rowH > listTop && y < listTop + listH) {
                val action: () -> Unit = item.action
                drawMenuRow(fb, L, item, m.selected == index, inner.c, y, inner.w, pick = {
                    closeMenu()
                    action()
                })
            }
            y += rowH
        }
        fb.popClip()
        if (menuMax > 0) {
            fb.scrollRegion(menuRegion, inner.c, listTop, inner.w, listH, contentRows)
            VFDW.listScrollbar(fb, listTop, listH, contentRows, offset)
        }
        VFDW.button(fb, L, inner.c, listTop + listH, inner.w, "CANCEL", name = "menu:CANCEL",
                    action = closeMenuAction)
        VFDW.panel(fb, L, c, top, w, panelH, title = if (hasTitle) m.title else null, color = VFDInk.highlight)
    }

    // MARK: paint

    /** The cells as a cols x rows bitmap scaled by whole pixels (nearest neighbour) to
     *  cols * pitch x rows * pitch device pixels (shifted right by the left safe columns, which
     *  like the right ones are plain unlit cells), then the black 1 px gap lines over the whole
     *  grid; the edge strips past the grid stay black. */
    private fun paint(scope: DrawScope, fb: VFDFrameBuffer, base: VFDBase) {
        val bmp: Bitmap = bitmap ?: return
        val img: ImageBitmap = image ?: return
        val px: IntArray = pixels ?: return
        if (fb.cols != cols || fb.rows != rows || px.size != fb.cells.size) return
        fb.argbTable(base, lut)
        fb.argbPixels(base, px, lut)
        bmp.setPixels(px, 0, cols, 0, 0, cols, rows)
        val gw: Int = gridCols * pitch
        val gh: Int = rows * pitch
        if (gridCols > cols) {
            scope.drawRect(unlitColor, topLeft = Offset.Zero, size = Size(gw.toFloat(), gh.toFloat()))
        }
        scope.drawImage(
            image = img,
            srcOffset = IntOffset.Zero,
            srcSize = IntSize(cols, rows),
            dstOffset = IntOffset(originCol * pitch, 0),
            dstSize = IntSize(cols * pitch, gh),
            filterQuality = FilterQuality.None,
        )
        val g: Paint = gaps ?: return
        scope.drawContext.canvas.drawRect(0f, 0f, gw.toFloat(), gh.toFloat(), g)
    }

    // MARK: touches

    private fun slopPx(): Float = slopDp * (inputs?.density?.density ?: 1f)

    private fun swipePx(): Float = swipeDp * (inputs?.density?.density ?: 1f)

    /** A new touch at [p] (px): its hit and scroll region come from the frame on screen. Returns
     *  the touch's serial. */
    fun touchDown(p: Offset): Int {
        fling = null
        touchSerial += 1
        val serial: Int = touchSerial
        val c: Int = cellIndex(p.x) - originCol
        val r: Int = cellIndex(p.y)
        val hit: VFDHit? = fb?.hit(c, r)
        val region: VFDScrollRegion? = fb?.scrollRegionAt(c, r)
        touch = VFDTouch(serial, p, hit, region)
        return serial
    }

    /** Still down, not moved, on a hit with a long action: the gesture times the hold. */
    fun holdPending(serial: Int): Boolean {
        val t: VFDTouch = touch ?: return false
        return t.serial == serial && t.mode == VFDTouchMode.pending && t.hit?.long != null
    }

    /** 0.5 s after touch down: still down and not moved, on a hit with a long action. */
    fun holdFired(serial: Int) {
        val t: VFDTouch = touch ?: return
        if (t.serial != serial || t.mode != VFDTouchMode.pending) return
        val long: () -> Unit = t.hit?.long ?: return
        t.mode = VFDTouchMode.held
        inputs?.haptic?.performHapticFeedback(HapticFeedbackType.LongPress)
        runAction("hold") { long() }
        requestRedraw()
    }

    fun touchMove(serial: Int, p: Offset) {
        val t: VFDTouch = touch ?: return
        if (t.serial != serial) return
        val dx: Float = p.x - t.start.x
        val dy: Float = p.y - t.start.y
        when (t.mode) {
            VFDTouchMode.pending -> {
                val dist: Float = kotlin.math.sqrt(dx * dx + dy * dy)
                if (dist < slopPx()) return
                decideAxis(t, dx, dy)
                if (t.mode == VFDTouchMode.scroll) {
                    scroll(t, p)
                } else if (t.mode == VFDTouchMode.slide) {
                    slide(t, p, false)
                }
            }
            VFDTouchMode.scroll -> scroll(t, p)
            VFDTouchMode.slide -> slide(t, p, false)
            VFDTouchMode.held, VFDTouchMode.swipe, VFDTouchMode.ignored -> {}
        }
    }

    fun touchUp(serial: Int, p: Offset, velocityY: Float) {
        val t: VFDTouch = touch ?: return
        if (t.serial != serial) return
        touch = null
        val dx: Float = p.x - t.start.x
        val dy: Float = p.y - t.start.y
        val dist: Float = kotlin.math.sqrt(dx * dx + dy * dy)
        when (t.mode) {
            VFDTouchMode.pending -> {
                if (dist < slopPx()) {
                    tap(t, p)
                }
            }
            VFDTouchMode.slide -> slide(t, p, true)
            VFDTouchMode.swipe -> {
                val left: (() -> Unit)? = t.hit?.swipeLeft
                val right: (() -> Unit)? = t.hit?.swipeRight
                if (dx <= -swipePx() && left != null) {
                    runAction("swipe") { left() }
                    requestRedraw()
                } else if (dx >= swipePx() && right != null) {
                    runAction("swipe") { right() }
                    requestRedraw()
                }
            }
            VFDTouchMode.scroll -> startFling(t, velocityY)
            VFDTouchMode.held, VFDTouchMode.ignored -> {}
        }
    }

    /** The system cancelled the gesture: forget the touch without running anything. */
    fun touchCancel(serial: Int) {
        val t: VFDTouch = touch ?: return
        if (t.serial == serial) {
            touch = null
        }
    }

    /** Grid cell index (column or row: they share the pitch) of a coordinate in px; a frame
     *  buffer column is this minus [originCol]. */
    private fun cellIndex(v: Float): Int {
        val size: Float = if (pitch > 0) pitch.toFloat() else 1f
        val x: Float = v / size
        if (!x.isFinite()) return -1
        return minOf(maxOf(floor(x.toDouble()), -1.0), 100_000.0).toInt()
    }

    /** Horizontal: a slider drag or a swipe on the hit under the finger. Vertical: scroll the
     *  region under the start point, else the page (only the menu's list while a menu is open). */
    private fun decideAxis(t: VFDTouch, dx: Float, dy: Float) {
        if (abs(dx) > abs(dy)) {
            val h: VFDHit? = t.hit
            t.mode = when {
                h != null && h.drag != null -> VFDTouchMode.slide
                h != null && (h.swipeLeft != null || h.swipeRight != null) -> VFDTouchMode.swipe
                else -> VFDTouchMode.ignored
            }
            return
        }
        if (menu != null) {
            val r: VFDScrollRegion? = t.region
            if (r != null && r.id == menuRegion) {
                t.mode = VFDTouchMode.scroll
                t.kind = VFDScrollKind.menu
                t.scrollStart = menuScroll
                t.limit = menuMax
            } else {
                t.mode = VFDTouchMode.ignored
            }
            return
        }
        t.mode = VFDTouchMode.scroll
        val r: VFDScrollRegion? = t.region
        if (r != null && r.id != menuRegion) {
            t.kind = VFDScrollKind.region
            t.regionId = r.id
            t.scrollStart = session.regionScroll(currentTab, r.id)
            t.limit = maxOf(0, r.contentRows - r.h)
        } else {
            t.kind = VFDScrollKind.page
            t.scrollStart = session.pageScroll(currentTab)
            t.limit = pageMax
        }
    }

    private fun tap(t: VFDTouch, p: Offset) {
        val h: VFDHit = t.hit ?: return
        val action: (() -> Unit)? = h.action
        val drag: ((Double, Boolean) -> Unit)? = h.drag
        if (action != null) {
            runAction("tap") { action() }
        } else if (drag != null) {
            // A tap on a slider bar sets the value there.
            runAction("drag") { drag(fraction(h, p), true) }
        } else {
            return
        }
        requestRedraw()
    }

    private fun slide(t: VFDTouch, p: Offset, ended: Boolean) {
        val h: VFDHit = t.hit ?: return
        val drag: (Double, Boolean) -> Unit = h.drag ?: return
        runAction("drag") { drag(fraction(h, p), ended) }
        requestRedraw()
    }

    /** Finger position across the hit's width, 0..1. */
    private fun fraction(h: VFDHit, p: Offset): Double {
        val size: Double = if (pitch > 0) pitch.toDouble() else 1.0
        val x: Double = p.x / size - originCol.toDouble()
        val w: Double = maxOf(1, h.w).toDouble()
        val f: Double = (x - h.c.toDouble()) / w
        if (!f.isFinite()) return 0.0
        return minOf(maxOf(f, 0.0), 1.0)
    }

    /** Scroll by the finger's travel in whole cells. */
    private fun scroll(t: VFDTouch, p: Offset) {
        val size: Double = if (pitch > 0) pitch.toDouble() else 1.0
        val moved: Double = (t.start.y - p.y) / size
        if (!moved.isFinite()) return
        val rowsMoved: Int = minOf(maxOf(moved, -100_000.0), 100_000.0).roundToInt()
        val value: Int = maxOf(0, minOf(t.scrollStart + rowsMoved, t.limit))
        setScroll(t.kind, t.regionId, value, redraw = true)
    }

    private fun currentScroll(kind: VFDScrollKind, regionId: String): Int = when (kind) {
        VFDScrollKind.page -> session.pageScroll(currentTab)
        VFDScrollKind.region -> session.regionScroll(currentTab, regionId)
        VFDScrollKind.menu -> menuScroll
    }

    private fun setScroll(kind: VFDScrollKind, regionId: String, value: Int, redraw: Boolean) {
        if (currentScroll(kind, regionId) == value) return
        when (kind) {
            VFDScrollKind.page -> session.setPageScroll(currentTab, value)
            VFDScrollKind.region -> session.setRegionScroll(currentTab, regionId, value)
            VFDScrollKind.menu -> menuScroll = value
        }
        if (redraw) {
            requestRedraw()
        }
    }

    /** Keep going after release by Android's own fling distance for the release velocity, in
     *  whole cells, easing out (iOS timing: 0.25 .. 0.6 s). */
    private fun startFling(t: VFDTouch, velocityY: Float) {
        val spec: DecayAnimationSpec<Float> = decay ?: return
        if (!velocityY.isFinite() || pitch <= 0) return
        val extraPx: Float = spec.calculateTargetValue(0f, velocityY)
        val extra: Double = -extraPx.toDouble() / pitch.toDouble()
        if (!extra.isFinite()) return
        val rowsExtra: Int = minOf(maxOf(extra, -100_000.0), 100_000.0).roundToInt()
        if (abs(rowsExtra) < 3) return
        val from: Int = currentScroll(t.kind, t.regionId)
        val to: Int = maxOf(0, minOf(from + rowsExtra, t.limit))
        if (to == from) return
        val distance: Double = abs(to - from).toDouble()
        val duration: Double = minOf(0.6, maxOf(0.25, distance / 900.0))
        fling = VFDFling(currentTab, t.kind, t.regionId, from, to, System.currentTimeMillis() / 1000.0, duration)
        fast.value = true
        requestRedraw()
    }

    /** Move a running fling to where it is at [now] (called while composing). */
    private fun advanceFling(now: Double) {
        val f: VFDFling = fling ?: return
        if (f.tab != currentTab) {
            fling = null
            return
        }
        var p = 1.0
        if (f.duration > 0) {
            p = minOf(1.0, maxOf(0.0, (now - f.start) / f.duration))
        }
        val inv: Double = 1.0 - p
        val eased: Double = 1.0 - inv * inv * inv
        val v: Int = f.from + ((f.to - f.from).toDouble() * eased).roundToInt()
        setScroll(f.kind, f.regionId, v, redraw = false)
        if (p >= 1.0) {
            fling = null
        }
    }
}

// MARK: - Built-in screens

/** In place of every tab's content until the core permissions are granted, like the standard
 *  "PERMS REQUIRED" panel; APPEARANCE under it so the theme can be switched back meanwhile. */
internal object VFDPermissionGate : VFDScreen {
    override val title: String = "PERMISSIONS"

    override fun draw(ctx: VFDContext): Int? {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val c: Int = L.left
        val w: Int = L.width
        var y: Int = L.contentTop
        y = VFDW.statusLine(fb, L, c, y, w, "PERMS REQUIRED: BT · LOC · NOTIFY", color = VFDInk.highlight)
        y += VFDW.gap
        y = VFDW.button(fb, L, c, y, null, "GRANT", primary = true, action = {
            ctx.requestPermissions()
        })
        y = VFDSettingsScreen.appearance(ctx, c, y, w)
        return y
    }
}
