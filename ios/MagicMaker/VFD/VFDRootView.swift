import SwiftUI
import UIKit

// The VFD theme's whole screen: one full-screen Canvas painting the cell frame buffer (palette
// inks and true colours, 1 px black gaps; pixel for pixel what tools/vfd/vfd.py render_image
// makes), the chrome and the current tab drawn in two passes with edge snapping
// (render_previews.draw_screen), touch handling on the cell grid (tap, hold, scroll with a
// fling, slider drags, swipes), the overlays and the animation clock.

// MARK: - Overlay requests

struct VFDPromptRequest {
    let title: String
    let message: String
    let keyboard: VFDKeyboard
    let onDone: (String) -> Void
}

struct VFDConfirmRequest {
    let title: String
    let message: String
    let confirmLabel: String
    let destructive: Bool
    let action: () -> Void

    var role: ButtonRole? {
        return destructive ? ButtonRole.destructive : nil
    }
}

struct VFDMenuRequest {
    let title: String
    let items: [VFDMenuItem]
    /// The current item: drawn as the selected row and scrolled into view on open.
    let selected: Int?
}

/// A prompt or confirm waiting for the alert on screen to go away.
private enum VFDQueuedAlert {
    case prompt(VFDPromptRequest, String)
    case confirm(VFDConfirmRequest)
}

struct VFDSheetItem: Identifiable {
    let id: String
    let content: () -> AnyView
}

/// What one frame is drawn from: the engines, the theme, the tab and the screen's safe area.
struct VFDFrameInputs {
    let vm: AppViewModel
    let store: MagicStore
    let scan: ScanEngine
    let tx: TxEngine
    let settings: VFDSettings
    let tab: MainTab
    let scale: CGFloat
    let insetTop: CGFloat
    let insetBottom: CGFloat
    let selectTab: (MainTab) -> Void
}

// MARK: - View

/// The VFD theme: the whole screen is one cell grid drawn by `VFDRenderer`. ContentView shows it
/// instead of the standard layout and shares its tab selection.
@MainActor
struct VFDRootView: View {
    @Binding var tab: MainTab
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var store: MagicStore
    @EnvironmentObject var scan: ScanEngine
    @EnvironmentObject var tx: TxEngine
    @ObservedObject private var settings: VFDSettings = VFDSettings.shared
    @StateObject private var renderer: VFDRenderer = VFDRenderer()
    @Environment(\.displayScale) private var displayScale: CGFloat
    @Environment(\.scenePhase) private var scenePhase: ScenePhase

    init(tab: Binding<MainTab>) {
        self._tab = tab
    }

    /// The tab's `onShow` runs on first appearance, on every tab change, on the return from the
    /// background and when a VFD sheet closes.
    var body: some View {
        overlays
            .onAppear {
                renderer.tabShown(tab)
            }
            .onChange(of: tab) { _, next in
                renderer.tabChanged()
                renderer.tabShown(next)
            }
            .onChange(of: scenePhase) { _, phase in
                renderer.scenePhaseChanged(phase, tab: tab)
            }
            .onChange(of: store.revision) { _, _ in
                storeRevisionChanged()
            }
    }

    /// The grid with the confirm alert and the VFD's sheet (the prompt alert sits on the grid).
    private var overlays: some View {
        grid
            .alert(confirmTitle, isPresented: confirmPresented, presenting: renderer.confirmRequest) { req in
                Button(req.confirmLabel, role: req.role) {
                    renderer.finishConfirm(req)
                }
                Button("CANCEL", role: .cancel) { }
            } message: { req in
                Text(req.message)
            }
            .sheet(item: $renderer.sheetItem, onDismiss: {
                sheetDismissed()
            }) { item in
                sheetContent(item)
            }
    }

    private func sheetDismissed() {
        renderer.tabShown(tab)
    }

    /// WandScreen's onChange(of: store.revision): a library import can replace the new-wand names
    /// and the quick button, so re-read them while WAND is the visible tab.
    private func storeRevisionChanged() {
        if tab != .wand { return }
        vm.reloadNewWandNamesIfChanged()
        vm.reloadWandQuickIfChanged()
        renderer.requestRedraw()
    }

    /// The gesture sits on this stable full-screen view, not on the Canvas, so a clock change
    /// (which swaps the TimelineView) never cancels a drag in progress. Its local coordinates are
    /// screen points, like the Canvas's.
    private var grid: some View {
        GeometryReader { proxy in
            clock(proxy)
        }
        .ignoresSafeArea()
        .background(Color.black)
        .contentShape(Rectangle())
        .gesture(touchGesture)
        .alert(promptTitle, isPresented: promptPresented, presenting: renderer.promptRequest) { req in
            TextField("", text: $renderer.promptText)
                .keyboardType(req.keyboard.uiKeyboardType)
                .textInputAutocapitalization(req.keyboard.capitalization)
                .autocorrectionDisabled()
            Button("CANCEL", role: .cancel) { }
            Button("OK") {
                renderer.finishPrompt(req)
            }
        } message: { req in
            Text(req.message)
        }
    }

    /// 30 fps while the last frame animated (or a fling runs), else once a second (twice on a
    /// red-ish base, for the 1 Hz alarm blink).
    @ViewBuilder
    private func clock(_ proxy: GeometryProxy) -> some View {
        let inputs: VFDFrameInputs = frameInputs(proxy)
        if renderer.fastClock {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                canvas(inputs, timeline.date)
            }
        } else {
            TimelineView(.periodic(from: slowClockStart, by: slowClockInterval)) { timeline in
                canvas(inputs, timeline.date)
            }
        }
    }

    /// Rebuilt on every tick and state change, so each one draws a fresh frame.
    private func canvas(_ inputs: VFDFrameInputs, _ date: Date) -> some View {
        let renderer: VFDRenderer = self.renderer
        return Canvas(opaque: true) { gc, size in
            renderer.render(&gc, size: size, inputs: inputs)
        }
    }

    private var touchGesture: some Gesture {
        let renderer: VFDRenderer = self.renderer
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                renderer.touchChanged(value)
            }
            .onEnded { value in
                renderer.touchEnded(value)
            }
    }

    /// Ticks land just after whole (and half) seconds, so clocks and the alarm blink change on time.
    private var slowClockStart: Date {
        let now: Double = Date().timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: now.rounded(.down) + 0.02)
    }

    private var slowClockInterval: Double {
        return VFDPalette.alarmInverted(settings.base) ? 0.5 : 1.0
    }

    private func frameInputs(_ proxy: GeometryProxy) -> VFDFrameInputs {
        let binding: Binding<MainTab> = $tab
        let insets: EdgeInsets = proxy.safeAreaInsets
        return VFDFrameInputs(
            vm: vm,
            store: store,
            scan: scan,
            tx: tx,
            settings: settings,
            tab: tab,
            scale: displayScale,
            insetTop: insets.top,
            insetBottom: insets.bottom,
            selectTab: { next in binding.wrappedValue = next }
        )
    }

    private func sheetContent(_ item: VFDSheetItem) -> some View {
        VFDSheetContainer(content: item.content)
            .environmentObject(vm)
            .environmentObject(store)
            .environmentObject(scan)
            .environmentObject(tx)
            .preferredColorScheme(.dark)
    }

    private var promptTitle: String {
        return renderer.promptRequest?.title ?? ""
    }

    private var promptPresented: Binding<Bool> {
        let renderer: VFDRenderer = self.renderer
        return Binding(
            get: { renderer.promptRequest != nil },
            set: { shown in
                if !shown { renderer.promptDismissed() }
            }
        )
    }

    private var confirmTitle: String {
        return renderer.confirmRequest?.title ?? ""
    }

    private var confirmPresented: Binding<Bool> {
        let renderer: VFDRenderer = self.renderer
        return Binding(
            get: { renderer.confirmRequest != nil },
            set: { shown in
                if !shown { renderer.confirmDismissed() }
            }
        )
    }
}

/// Standard SwiftUI in a sheet over the VFD screen, with a DONE button.
private struct VFDSheetContainer: View {
    private let content: () -> AnyView
    @Environment(\.dismiss) private var dismiss

    init(content: @escaping () -> AnyView) {
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button {
                    dismiss()
                } label: {
                    Text("DONE")
                        .font(MMTheme.techHeader())
                        .foregroundStyle(MMTheme.cyan)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MMTheme.navy)
    }
}

// MARK: - Renderer state

private enum VFDTouchMode {
    /// Down, not moved past the slop yet: a tap on release, a hold after 0.5 s.
    case pending
    /// The hold fired; the release does nothing.
    case held
    case scroll
    /// Horizontal drag on a hit with `drag` (sliders).
    case slide
    /// Horizontal drag on a hit with swipe actions; decided on release.
    case swipe
    case ignored
}

private enum VFDScrollTarget: Equatable {
    case page
    case region(String)
    case menu
}

private struct VFDTouch {
    let serial: Int
    let start: CGPoint
    let hit: VFDHit?
    let region: VFDScrollRegion?
    var mode: VFDTouchMode
    var target: VFDScrollTarget
    var scrollStart: Int
    var limit: Int
}

private struct VFDFling {
    let tab: String
    let target: VFDScrollTarget
    let from: Int
    let to: Int
    let start: Double
    let duration: Double
}

/// The header of one frame.
private struct VFDChrome {
    let tab: String
    let title: String
    let telemetry: String
    let right: (text: String, action: () -> Void)?
    let rightColor: UInt8
    let back: (() -> Void)?
}

// MARK: - Renderer

/// Draws VFD frames and handles touches. Frames are composed on demand (a state change, an
/// action, the clock) into two reused frame buffers and painted from a reused bitmap.
@MainActor
final class VFDRenderer: ObservableObject {
    /// Bumped to draw again.
    @Published private(set) var tick: Int = 0
    /// The clock runs at 30 fps while true.
    @Published private(set) var fastClock: Bool = false
    @Published var promptRequest: VFDPromptRequest?
    @Published var promptText: String = ""
    @Published var confirmRequest: VFDConfirmRequest?
    @Published var sheetItem: VFDSheetItem?

    /// Movement (pt) before a touch counts as a drag.
    static let slop: CGFloat = 8
    /// Horizontal travel (pt) for a swipe action.
    static let swipeDistance: CGFloat = 40
    /// Seconds held still for a long press.
    static let holdSeconds: Double = 0.5
    /// Scroll region id of the open menu's list.
    static let menuRegion: String = "vfd.menu"
    /// A queued alert shows no sooner than this many seconds after the last one closed, and only
    /// once no alert controller is on screen any more (checked every alertPoll seconds, for at
    /// most alertMaxWait seconds).
    static let alertSettle: Double = 0.3
    static let alertPoll: Double = 0.05
    static let alertMaxWait: Double = 2.0

    private static let black: UInt32 = 0xFF00_0000

    private let session: VFDSession = VFDSession.shared

    // geometry
    private var scale: CGFloat = 0
    private var pitch: Int = 0
    private var cellPt: CGFloat = 1
    private var cols: Int = 0
    private var rows: Int = 0
    private var safeTop: Int = -1
    private var safeBottom: Int = -1
    private var layout: VFDLayout?
    private var fb: VFDFrameBuffer?
    private var probe: VFDFrameBuffer?
    private var tabList: [(key: String, label: String)] = []
    private var bitmap: CGContext?
    private var gapPath: Path = Path()
    private var lut: [UInt32] = [UInt32](repeating: 0, count: 256)
    private var inkBase: VFDBase?
    private var inkPacked: [UInt32] = []
    private var windowInsets: UIEdgeInsets?
    private var insetsSize: CGSize = .zero

    // frames
    private var context: VFDContext?
    private var inputs: VFDFrameInputs?
    private var currentTab: String = ""
    private var pageMax: Int = 0
    private var redrawPending: Bool = false
    private var clockPending: Bool = false
    private var wantFast: Bool = false

    // menu
    private var menu: VFDMenuRequest?
    private var menuScroll: Int = 0
    private var menuMax: Int = 0
    /// Row to scroll into view when the open menu is first drawn.
    private var menuReveal: Int?

    // alerts
    /// Prompts and confirms asked for while an alert was up or still going away, in order.
    private var alertQueue: [VFDQueuedAlert] = []
    /// An alert was closed and may still be on screen (animating away).
    private var alertClosing: Bool = false
    private var alertClosedAt: Double = 0
    private var alertCheckScheduled: Bool = false

    // tab visibility (VFDScreen.onShow)
    private var pendingShow: MainTab?
    private var showScheduled: Bool = false
    private var wentBackground: Bool = false

    // touches
    private var touch: VFDTouch?
    private var touchSerial: Int = 0
    private var fling: VFDFling?

    init() {
        session.onChange = { [weak self] in
            self?.requestRedraw()
        }
    }

    // MARK: screens

    static func screen(for tab: MainTab) -> any VFDScreen.Type {
        switch tab {
        case .scan: return VFDScanScreen.self
        case .tx: return VFDTxScreen.self
        case .wand: return VFDWandScreen.self
        case .auto: return VFDAutoScreen.self
        case .link: return VFDLinkScreen.self
        case .logs: return VFDLogsScreen.self
        case .map: return VFDMapScreen.self
        case .diag: return VFDDiagScreen.self
        case .lab: return VFDLabScreen.self
        case .settings: return VFDSettingsScreen.self
        }
    }

    // MARK: redraw and clock

    /// Draw again on the next run loop turn (coalesced).
    func requestRedraw() {
        if redrawPending { return }
        redrawPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.redrawPending = false
            self.tick &+= 1
        }
    }

    private func noteClock(_ fast: Bool) {
        wantFast = fast
        if fast == fastClock || clockPending { return }
        clockPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.clockPending = false
            if self.fastClock != self.wantFast {
                self.fastClock = self.wantFast
            }
        }
    }

    // MARK: overlays

    var menuOpen: Bool { return menu != nil }

    /// An alert is up, or one closed and may still be animating away: new ones wait in the queue.
    private var alertBusy: Bool {
        return promptRequest != nil || confirmRequest != nil || alertClosing
    }

    func presentPrompt(_ request: VFDPromptRequest, text: String) {
        if alertBusy {
            alertQueue.append(VFDQueuedAlert.prompt(request, text))
            return
        }
        showPrompt(request, text: text)
    }

    private func showPrompt(_ request: VFDPromptRequest, text: String) {
        menu = nil
        promptText = text
        promptRequest = request
    }

    /// OK on the prompt: the alert counts as closing before `onDone` runs, so a prompt or confirm
    /// asked for there is queued until this one has gone.
    func finishPrompt(_ request: VFDPromptRequest) {
        let text: String = promptText
        promptRequest = nil
        alertWillClose()
        request.onDone(text)
        requestRedraw()
    }

    /// The prompt alert was dismissed (CANCEL, or SwiftUI after OK).
    func promptDismissed() {
        if promptRequest != nil {
            promptRequest = nil
        }
        alertWillClose()
    }

    func presentConfirm(_ request: VFDConfirmRequest) {
        if alertBusy {
            alertQueue.append(VFDQueuedAlert.confirm(request))
            return
        }
        showConfirm(request)
    }

    private func showConfirm(_ request: VFDConfirmRequest) {
        menu = nil
        confirmRequest = request
    }

    func finishConfirm(_ request: VFDConfirmRequest) {
        confirmRequest = nil
        alertWillClose()
        request.action()
        requestRedraw()
    }

    /// The confirm alert was dismissed (CANCEL, or SwiftUI after the confirm button).
    func confirmDismissed() {
        if confirmRequest != nil {
            confirmRequest = nil
        }
        alertWillClose()
    }

    /// An alert is going away; the next queued one shows once it has fully gone.
    private func alertWillClose() {
        if !alertClosing {
            alertClosing = true
            alertClosedAt = Date().timeIntervalSinceReferenceDate
        }
        scheduleAlertCheck(after: VFDRenderer.alertSettle)
    }

    private func scheduleAlertCheck(after delay: Double) {
        if alertCheckScheduled { return }
        alertCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.alertCheckScheduled = false
            self.checkAlertGone()
        }
    }

    /// Presenting while the last alert is still on screen would be dropped by SwiftUI, so wait
    /// until no alert controller is presented (or alertMaxWait has passed), then show the next.
    private func checkAlertGone() {
        if !alertClosing { return }
        let waited: Double = Date().timeIntervalSinceReferenceDate - alertClosedAt
        if waited < VFDRenderer.alertMaxWait && VFDRenderer.alertOnScreen() {
            scheduleAlertCheck(after: VFDRenderer.alertPoll)
            return
        }
        alertClosing = false
        if promptRequest != nil || confirmRequest != nil { return }
        if alertQueue.isEmpty { return }
        let next: VFDQueuedAlert = alertQueue.removeFirst()
        switch next {
        case .prompt(let request, let text):
            showPrompt(request, text: text)
        case .confirm(let request):
            showConfirm(request)
        }
        requestRedraw()
    }

    /// Whether any window still presents an alert controller (SwiftUI alerts are presented as
    /// one, and stay in the chain until their dismissal animation has finished).
    private static func alertOnScreen() -> Bool {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                var next: UIViewController? = window.rootViewController
                var depth: Int = 0
                while let vc = next, depth < 32 {
                    if vc is UIAlertController { return true }
                    next = vc.presentedViewController
                    depth += 1
                }
            }
        }
        return false
    }

    func presentMenu(_ request: VFDMenuRequest) {
        menu = request
        menuScroll = 0
        menuMax = 0
        menuReveal = request.selected
        fling = nil
        requestRedraw()
    }

    func closeMenu() {
        menu = nil
        menuReveal = nil
        requestRedraw()
    }

    func presentSheet(_ item: VFDSheetItem) {
        menu = nil
        sheetItem = item
    }

    func dismissSheet() {
        sheetItem = nil
    }

    /// Tab bar tap (or `VFDContext.selectTab`). The tab already shown scrolls back to the top.
    func selectTab(key: String) {
        guard let next = MainTab(rawValue: key), let inputs = self.inputs else { return }
        menu = nil
        fling = nil
        if key == currentTab {
            session.setPageScroll(key, 0)
        }
        inputs.selectTab(next)
        requestRedraw()
    }

    /// The shared tab changed (here or from `vm.requestedTab`): close what belongs to the old one.
    func tabChanged() {
        menu = nil
        fling = nil
        touch = nil
        if sheetItem != nil {
            sheetItem = nil
        }
        requestRedraw()
    }

    // MARK: tab visibility

    /// `tab` became visible: run its screen's `onShow` (never inside drawing), then redraw. Before
    /// the first frame there is no context yet; it then runs right after that frame.
    func tabShown(_ tab: MainTab) {
        pendingShow = tab
        runPendingShow()
    }

    /// The return from the background (active after background) shows the tab again; going
    /// inactive and back (Control Center, a system alert) does not.
    func scenePhaseChanged(_ phase: ScenePhase, tab: MainTab) {
        if phase == .background {
            wentBackground = true
        } else if phase == .active && wentBackground {
            wentBackground = false
            tabShown(tab)
        }
    }

    private func runPendingShow() {
        guard let shown = pendingShow, let ctx = context else { return }
        pendingShow = nil
        ctx.beginShow(tab: shown.rawValue)
        if shown == .wand {
            // WandScreen.screenAppeared: an import made on another tab may have replaced these.
            ctx.vm.reloadNewWandNamesIfChanged()
            ctx.vm.reloadWandQuickIfChanged()
        }
        let screen: any VFDScreen.Type = VFDRenderer.screen(for: shown)
        screen.onShow(ctx)
        requestRedraw()
    }

    /// A show that came before the first frame runs on the next run loop turn after it.
    private func scheduleShow() {
        if showScheduled { return }
        showScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.showScheduled = false
            self.runPendingShow()
        }
    }

    // MARK: frame

    /// Compose a frame for the current state and paint it.
    func render(_ gc: inout GraphicsContext, size: CGSize, inputs: VFDFrameInputs) {
        gc.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.black))
        guard prepare(size: size, inputs: inputs) else { return }
        guard let fb = self.fb, let probe = self.probe, let L = self.layout else { return }
        self.inputs = inputs
        let ctx: VFDContext = contextFor(inputs, fb: fb, L: L)
        ctx.setDisplay(scale: Double(self.scale), pitch: self.pitch)
        let base: VFDBase = inputs.settings.base
        compose(ctx, fb: fb, probe: probe, L: L, inputs: inputs, base: base)
        paint(&gc, fb: fb, base: base)
        noteClock(fb.wantsAnimation || fling != nil)
        if pendingShow != nil {
            scheduleShow()
        }
    }

    private func contextFor(_ inputs: VFDFrameInputs, fb: VFDFrameBuffer, L: VFDLayout) -> VFDContext {
        if let ctx = context, ctx.vm === inputs.vm, ctx.scan === inputs.scan, ctx.tx === inputs.tx,
           ctx.store === inputs.store {
            return ctx
        }
        let ctx = VFDContext(vm: inputs.vm, store: inputs.store, scan: inputs.scan, tx: inputs.tx,
                             settings: inputs.settings, fb: fb, L: L)
        ctx.renderer = self
        context = ctx
        return ctx
    }

    /// Grid geometry from the screen: pitch 5 px at 3x (4 px at 2x), cols / rows = whole cells,
    /// safe rows = the safe-area insets rounded up to whole cells. Rebuilds the buffers when it
    /// changes. False while the size is too small to lay out.
    private func prepare(size: CGSize, inputs: VFDFrameInputs) -> Bool {
        if !size.width.isFinite || !size.height.isFinite || size.width <= 0 || size.height <= 0 {
            return false
        }
        let scale: CGFloat = inputs.scale > 0 ? inputs.scale : 2
        let pitch: Int = max(4, Int((5.0 * Double(scale) / 3.0).rounded()))
        let widthPx: Int = Int((Double(size.width) * Double(scale)).rounded())
        let heightPx: Int = Int((Double(size.height) * Double(scale)).rounded())
        let cols: Int = widthPx / pitch
        let rows: Int = heightPx / pitch
        if cols < 60 || rows < 150 { return false }
        let insets: (top: CGFloat, bottom: CGFloat) = safeInsets(size: size, inputs: inputs)
        let top: Int = VFDRenderer.safeRows(insets.top, scale: scale, pitch: pitch)
        let bottom: Int = VFDRenderer.safeRows(insets.bottom, scale: scale, pitch: pitch)
        let same: Bool = cols == self.cols && rows == self.rows && pitch == self.pitch
            && scale == self.scale && top == safeTop && bottom == safeBottom
        if same && fb != nil && layout != nil && bitmap != nil {
            return true
        }
        let L = VFDLayout(cols: cols, rows: rows, safeTop: top, safeBottom: bottom)
        if L.contentH < 40 || L.width < 60 { return false }
        self.scale = scale
        self.pitch = pitch
        self.cellPt = CGFloat(pitch) / scale
        self.cols = cols
        self.rows = rows
        self.safeTop = top
        self.safeBottom = bottom
        self.layout = L
        self.fb = VFDFrameBuffer(cols: cols, rows: rows)
        self.probe = VFDFrameBuffer(cols: cols, rows: rows)
        self.tabList = VFDW.defaultTabs(L)
        self.bitmap = VFDRenderer.makeBitmap(cols: cols, rows: rows)
        self.gapPath = VFDRenderer.makeGapPath(cols: cols, rows: rows, pitch: pitch, scale: scale)
        self.touch = nil
        return bitmap != nil
    }

    /// The window's safe-area insets (they ignore the keyboard of a prompt); the view's own
    /// until the window has laid out.
    private func safeInsets(size: CGSize, inputs: VFDFrameInputs) -> (top: CGFloat, bottom: CGFloat) {
        let known: CGFloat = windowInsets?.top ?? 0
        if windowInsets == nil || size != insetsSize || known <= 0 {
            windowInsets = VFDRenderer.windowSafeInsets()
            insetsSize = size
        }
        if let w = windowInsets, w.top > 0 || inputs.insetTop <= 0 {
            return (top: max(0, w.top), bottom: max(0, w.bottom))
        }
        return (top: max(0, inputs.insetTop), bottom: max(0, inputs.insetBottom))
    }

    private static func windowSafeInsets() -> UIEdgeInsets? {
        var fallback: UIWindow? = nil
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                if window.isKeyWindow { return window.safeAreaInsets }
                if fallback == nil { fallback = window }
            }
        }
        return fallback?.safeAreaInsets
    }

    private static func safeRows(_ inset: CGFloat, scale: CGFloat, pitch: Int) -> Int {
        let px: Double = Double(inset) * Double(scale)
        if !px.isFinite || px <= 0 || pitch <= 0 { return 0 }
        let cells: Double = (px / Double(pitch) - 1e-6).rounded(.up)
        if cells <= 0 { return 0 }
        if cells >= 10_000 { return 10_000 }
        return Int(cells)
    }

    // MARK: compose

    private func compose(_ ctx: VFDContext, fb: VFDFrameBuffer, probe: VFDFrameBuffer, L: VFDLayout,
                         inputs: VFDFrameInputs, base: VFDBase) {
        let now: Double = Date().timeIntervalSinceReferenceDate
        let key: String = inputs.tab.rawValue
        if key != currentTab {
            currentTab = key
            fling = nil
            menu = nil
        }
        // Red-ish base: alarms are inverted blocks during the first half of every second.
        let blinkOn: Bool = now - now.rounded(.down) < 0.5
        let alarmInverted: Bool = blinkOn && VFDPalette.alarmInverted(base)
        ctx.beginFrame(fb: fb, L: L, time: now, tab: key)
        advanceFling(now)

        let screen: any VFDScreen.Type = VFDRenderer.screen(for: inputs.tab)
        let telemetry: String = TelemetryBar.telemetryLine(vm: inputs.vm, scan: inputs.scan, tx: inputs.tx)
        let chrome = VFDChrome(tab: key, title: screen.title, telemetry: telemetry,
                               right: screen.headerRight(ctx), rightColor: screen.headerRightColor(ctx),
                               back: screen.back(ctx))
        var scroll: Int = session.pageScroll(key)
        var end: Int? = drawPasses(screen, ctx, chrome: chrome, fb: fb, probe: probe, L: L, scroll: scroll,
                                   base: base, alarmInverted: alarmInverted)
        let limit: Int = VFDRenderer.pageLimit(end, L)
        if scroll > limit {
            // The content got shorter: clamp and draw again at the new offset.
            scroll = limit
            session.setPageScroll(key, limit)
            end = drawPasses(screen, ctx, chrome: chrome, fb: fb, probe: probe, L: L, scroll: scroll,
                             base: base, alarmInverted: alarmInverted)
        }
        pageMax = VFDRenderer.pageLimit(end, L)
        if let m = menu {
            drawMenu(m, fb: fb, L: L)
        }
    }

    /// render_previews.draw_screen: the content once on the scratch buffer to snap the window,
    /// then the chrome, the content clipped to that window, hidden partial taps dropped, the
    /// scrollbar. Returns the screen's end row.
    private func drawPasses(_ screen: any VFDScreen.Type, _ ctx: VFDContext, chrome: VFDChrome,
                            fb: VFDFrameBuffer, probe: VFDFrameBuffer, L: VFDLayout, scroll: Int,
                            base: VFDBase, alarmInverted: Bool) -> Int? {
        VFDRenderer.reset(probe, base: base, alarmInverted: alarmInverted)
        probe.pushClip(0, 0, probe.cols, probe.rows, dy: -scroll)
        let probeDepth: Int = probe.clipDepth
        ctx.use(probe)
        _ = screen.draw(ctx)
        VFDRenderer.popClips(probe, to: probeDepth)
        let win = VFDW.snappedWindow(lit: probe, top: L.contentTop, bottom: L.contentBottom)

        VFDRenderer.reset(fb, base: base, alarmInverted: alarmInverted)
        let back: (() -> Void)? = chrome.back
        let rightText: String? = chrome.right?.text
        let rightAction: (() -> Void)? = chrome.right?.action
        let onTab: (String) -> Void = { [weak self] key in
            self?.selectTab(key: key)
        }
        VFDW.frame(fb, L, tab: chrome.tab, title: chrome.title, telemetry: chrome.telemetry,
                   back: back != nil, right: rightText, rightColor: chrome.rightColor, scroll: scroll,
                   rightTap: nil, tabs: tabList, onBack: back, onRight: rightAction, onTab: onTab)
        fb.popClip()
        fb.pushClip(0, win.top, fb.cols, win.bottom - win.top, dy: -scroll)
        let depth: Int = fb.clipDepth
        let firstTap: Int = fb.taps.count
        ctx.use(fb)
        let end: Int? = screen.draw(ctx)
        VFDRenderer.popClips(fb, to: depth)
        VFDW.dropHiddenTaps(fb, from: firstTap, window: win, L)
        if let e = end {
            VFDW.scrollbar(fb, L, e, scroll: scroll)
        }
        return end
    }

    private static func reset(_ b: VFDFrameBuffer, base: VFDBase, alarmInverted: Bool) {
        while b.clipDepth > 0 {
            b.popClip()
        }
        b.clear()
        b.base = base
        b.alarmInverted = alarmInverted
    }

    private static func popClips(_ b: VFDFrameBuffer, to depth: Int) {
        while b.clipDepth >= depth && b.clipDepth > 0 {
            b.popClip()
        }
    }

    /// Largest page scroll: content rows past the content region.
    private static func pageLimit(_ end: Int?, _ L: VFDLayout) -> Int {
        guard let e = end else { return 0 }
        return max(0, e - L.contentTop - L.contentH)
    }

    // MARK: menu

    /// The open menu over a blanked content region: a highlight panel with the title set into
    /// its top border, one button row per item (a list that scrolls when it does not fit), then
    /// CANCEL. A full-screen hit under it closes it on a tap anywhere else.
    private func drawMenu(_ m: VFDMenuRequest, fb: VFDFrameBuffer, L: VFDLayout) {
        while fb.clipDepth > 0 {
            fb.popClip()
        }
        fb.fill(0, L.contentTop, fb.cols, L.contentH, VFDInk.unlit)
        fb.tap(0, 0, fb.cols, fb.rows, name: "menu:outside", action: { [weak self] in
            self?.closeMenu()
        })
        let c: Int = L.left
        let w: Int = L.width
        let hasTitle: Bool = !m.title.isEmpty
        let rowH: Int = VFDW.ctrlH + VFDW.gap
        let head: Int = hasTitle ? 10 : 4
        let foot: Int = rowH + 2
        let room: Int = L.contentH - 4 - head - foot
        let maxRows: Int = max(1, room / rowH)
        let shownRows: Int = min(max(1, m.items.count), maxRows)
        let listH: Int = shownRows * rowH
        let panelH: Int = head + listH + foot
        let top: Int = L.contentTop + max(2, (L.contentH - panelH) / 2)
        let inner = VFDW.panelInner(c, top, w, title: hasTitle)
        let listTop: Int = inner.r
        let contentRows: Int = m.items.count * rowH
        menuMax = max(0, contentRows - listH)
        menuScroll = max(0, min(menuScroll, menuMax))
        // Taps on the panel between the rows do nothing (only taps outside it close the menu).
        fb.tap(c, top, w, panelH, name: "menu:panel")

        // Drawn at the nearest whole row, so no button is ever cut by the list edges.
        let offset: Int = min(menuMax, ((menuScroll + rowH / 2) / rowH) * rowH)
        fb.pushClip(0, listTop, fb.cols, listH)
        var y: Int = listTop - offset
        for item in m.items {
            if y + rowH > listTop && y < listTop + listH {
                let action: () -> Void = item.action
                VFDW.button(fb, L, inner.c, y, inner.w, item.label, enabled: item.enabled,
                            name: "menu:" + VFDW.upper(item.label), alarm: item.destructive,
                            action: { [weak self] in
                                self?.closeMenu()
                                action()
                            })
            }
            y += rowH
        }
        fb.popClip()
        if menuMax > 0 {
            fb.scrollRegion(id: VFDRenderer.menuRegion, inner.c, listTop, inner.w, listH, contentRows: contentRows)
            VFDW.listScrollbar(fb, listTop, listH, contentRows, offset)
        }
        VFDW.button(fb, L, inner.c, listTop + listH, inner.w, "CANCEL", name: "menu:CANCEL",
                    action: { [weak self] in
                        self?.closeMenu()
                    })
        VFDW.panel(fb, L, c, top, w, panelH, title: hasTitle ? m.title : nil, color: VFDInk.highlight)
    }

    // MARK: paint

    /// The cells as a cols x rows bitmap scaled by whole pixels (nearest neighbour) to
    /// cols * pitch x rows * pitch device pixels, then the black 1 px gap lines; the edge strips
    /// past the grid stay black.
    private func paint(_ gc: inout GraphicsContext, fb: VFDFrameBuffer, base: VFDBase) {
        guard let image = makeImage(fb, base: base) else { return }
        let w: CGFloat = CGFloat(cols * pitch) / scale
        let h: CGFloat = CGFloat(rows * pitch) / scale
        let picture: Image = Image(decorative: image, scale: 1.0).interpolation(.none).antialiased(false)
        gc.draw(picture, in: CGRect(x: 0, y: 0, width: w, height: h))
        gc.fill(gapPath, with: .color(Color.black), style: FillStyle(eoFill: false, antialiased: false))
    }

    private func makeImage(_ fb: VFDFrameBuffer, base: VFDBase) -> CGImage? {
        guard let bitmap = self.bitmap, let raw = bitmap.data else { return nil }
        let width: Int = cols
        let height: Int = rows
        if fb.cols != width || fb.rows != height || fb.cells.count < width * height { return nil }
        let rowWords: Int = bitmap.bytesPerRow / 4
        if rowWords < width { return nil }
        fillLUT(fb, base: base)
        let pixels: UnsafeMutablePointer<UInt32> = raw.bindMemory(to: UInt32.self, capacity: rowWords * height)
        let table: [UInt32] = lut
        table.withUnsafeBufferPointer { (colors: UnsafeBufferPointer<UInt32>) -> Void in
            fb.cells.withUnsafeBufferPointer { (cells: UnsafeBufferPointer<UInt8>) -> Void in
                var r: Int = 0
                while r < height {
                    let src: Int = r * width
                    let dst: Int = r * rowWords
                    var c: Int = 0
                    while c < width {
                        pixels[dst + c] = colors[Int(cells[src + c])]
                        c += 1
                    }
                    r += 1
                }
            }
        }
        // The image gets its own copy of the pixels: the next frame writes straight into the
        // bitmap's memory, which a makeImage() image may still share while it is on screen.
        let byteCount: Int = bitmap.bytesPerRow * height
        let copy: Data = Data(bytes: UnsafeRawPointer(raw), count: byteCount)
        guard let provider = CGDataProvider(data: copy as CFData) else { return nil }
        let space: CGColorSpace = bitmap.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let info: CGBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bitmap.bytesPerRow, space: space, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Cell value -> packed pixel: the 5 inks of the base, this frame's true colours, black.
    private func fillLUT(_ fb: VFDFrameBuffer, base: VFDBase) {
        if inkBase != base || inkPacked.count != VFDInk.count {
            var packed: [UInt32] = []
            for c in VFDPalette.colors(for: base) {
                packed.append(VFDRenderer.pack(c))
            }
            inkPacked = packed
            inkBase = base
        }
        var i: Int = 0
        for v in inkPacked {
            if i >= 256 { break }
            lut[i] = v
            i += 1
        }
        for c in fb.trueColors {
            if i >= 256 { break }
            lut[i] = VFDRenderer.pack(c)
            i += 1
        }
        while i < 256 {
            lut[i] = VFDRenderer.black
            i += 1
        }
    }

    /// RGBX bytes in memory order (little-endian word), alpha byte opaque.
    private static func pack(_ c: VFDRGB) -> UInt32 {
        let r: UInt32 = UInt32(c.r)
        let g: UInt32 = UInt32(c.g) << 8
        let b: UInt32 = UInt32(c.b) << 16
        return r | g | b | black
    }

    private static func makeBitmap(cols: Int, rows: Int) -> CGContext? {
        let space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    /// The right column and bottom row of every cell pitch, 1 device pixel wide.
    private static func makeGapPath(cols: Int, rows: Int, pitch: Int, scale: CGFloat) -> Path {
        var path = Path()
        let px: CGFloat = 1.0 / scale
        let fullW: CGFloat = CGFloat(cols * pitch) / scale
        let fullH: CGFloat = CGFloat(rows * pitch) / scale
        var c: Int = 0
        while c < cols {
            let x: CGFloat = CGFloat(c * pitch + pitch - 1) / scale
            path.addRect(CGRect(x: x, y: 0, width: px, height: fullH))
            c += 1
        }
        var r: Int = 0
        while r < rows {
            let y: CGFloat = CGFloat(r * pitch + pitch - 1) / scale
            path.addRect(CGRect(x: 0, y: y, width: fullW, height: px))
            r += 1
        }
        return path
    }

    // MARK: touches

    /// One DragGesture(minimumDistance: 0) drives everything: it reports the touch down at
    /// once, so a hold is timed from there.
    func touchChanged(_ value: DragGesture.Value) {
        guard var t = currentTouch(value) else { return }
        let dx: CGFloat = value.location.x - t.start.x
        let dy: CGFloat = value.location.y - t.start.y
        switch t.mode {
        case .pending:
            let dist: CGFloat = (dx * dx + dy * dy).squareRoot()
            if dist < VFDRenderer.slop { return }
            decideAxis(&t, dx: dx, dy: dy)
            touch = t
            if t.mode == .scroll {
                scroll(t, to: value.location)
            } else if t.mode == .slide {
                slide(t, at: value.location, ended: false)
            }
        case .scroll:
            scroll(t, to: value.location)
        case .slide:
            slide(t, at: value.location, ended: false)
        case .held, .swipe, .ignored:
            break
        }
    }

    func touchEnded(_ value: DragGesture.Value) {
        guard let t = currentTouch(value) else { return }
        touch = nil
        let dx: CGFloat = value.location.x - t.start.x
        let dy: CGFloat = value.location.y - t.start.y
        let dist: CGFloat = (dx * dx + dy * dy).squareRoot()
        switch t.mode {
        case .pending:
            if dist < VFDRenderer.slop {
                tap(t, at: value.location)
            }
        case .slide:
            slide(t, at: value.location, ended: true)
        case .swipe:
            if dx <= -VFDRenderer.swipeDistance, let left = t.hit?.swipeLeft {
                left()
                requestRedraw()
            } else if dx >= VFDRenderer.swipeDistance, let right = t.hit?.swipeRight {
                right()
                requestRedraw()
            }
        case .scroll:
            startFling(t, value)
        case .held, .ignored:
            break
        }
    }

    /// The touch this gesture belongs to, told apart by its start point: a new one when none is
    /// down or when the last one never ended (SwiftUI does not call onEnded for a cancelled
    /// gesture, e.g. when a hold opened an alert or a sheet).
    private func currentTouch(_ value: DragGesture.Value) -> VFDTouch? {
        if let t = touch, t.start == value.startLocation {
            return t
        }
        beginTouch(at: value.startLocation)
        return touch
    }

    private func beginTouch(at point: CGPoint) {
        fling = nil
        touchSerial &+= 1
        let serial: Int = touchSerial
        let cell = cellAt(point)
        let hit: VFDHit? = fb?.hit(cell.c, cell.r)
        let region: VFDScrollRegion? = fb?.scrollRegionAt(cell.c, cell.r)
        touch = VFDTouch(serial: serial, start: point, hit: hit, region: region, mode: .pending,
                         target: .page, scrollStart: 0, limit: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + VFDRenderer.holdSeconds) { [weak self] in
            self?.holdFired(serial)
        }
    }

    /// 0.5 s after touch down: still down and not moved, on a hit with a long action.
    private func holdFired(_ serial: Int) {
        guard var t = touch, t.serial == serial, t.mode == .pending else { return }
        guard let long = t.hit?.long else { return }
        t.mode = .held
        touch = t
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        long()
        requestRedraw()
    }

    private func cellAt(_ p: CGPoint) -> (c: Int, r: Int) {
        let size: CGFloat = cellPt > 0 ? cellPt : 1
        let x: Double = Double(p.x / size)
        let y: Double = Double(p.y / size)
        if !x.isFinite || !y.isFinite { return (c: -1, r: -1) }
        let c: Double = min(max(x.rounded(.down), -1), 100_000)
        let r: Double = min(max(y.rounded(.down), -1), 100_000)
        return (c: Int(c), r: Int(r))
    }

    /// Horizontal: a slider drag or a swipe on the hit under the finger. Vertical: scroll the
    /// region under the start point, else the page (only the menu's list while a menu is open).
    private func decideAxis(_ t: inout VFDTouch, dx: CGFloat, dy: CGFloat) {
        if abs(dx) > abs(dy) {
            if let h = t.hit, h.drag != nil {
                t.mode = .slide
            } else if let h = t.hit, h.swipeLeft != nil || h.swipeRight != nil {
                t.mode = .swipe
            } else {
                t.mode = .ignored
            }
            return
        }
        if menu != nil {
            if let r = t.region, r.id == VFDRenderer.menuRegion {
                t.mode = .scroll
                t.target = .menu
                t.scrollStart = menuScroll
                t.limit = menuMax
            } else {
                t.mode = .ignored
            }
            return
        }
        t.mode = .scroll
        if let r = t.region, r.id != VFDRenderer.menuRegion {
            t.target = .region(r.id)
            t.scrollStart = session.regionScroll(currentTab, r.id)
            t.limit = max(0, r.contentRows - r.h)
        } else {
            t.target = .page
            t.scrollStart = session.pageScroll(currentTab)
            t.limit = pageMax
        }
    }

    private func tap(_ t: VFDTouch, at point: CGPoint) {
        guard let h = t.hit else { return }
        if let action = h.action {
            action()
        } else if let drag = h.drag {
            // A tap on a slider bar sets the value there.
            drag(fraction(h, point), true)
        } else {
            return
        }
        requestRedraw()
    }

    private func slide(_ t: VFDTouch, at point: CGPoint, ended: Bool) {
        guard let h = t.hit, let drag = h.drag else { return }
        drag(fraction(h, point), ended)
        requestRedraw()
    }

    /// Finger position across the hit's width, 0...1.
    private func fraction(_ h: VFDHit, _ point: CGPoint) -> Double {
        let size: CGFloat = cellPt > 0 ? cellPt : 1
        let x: Double = Double(point.x / size)
        let w: Double = Double(max(1, h.w))
        let f: Double = (x - Double(h.c)) / w
        if !f.isFinite { return 0 }
        return min(max(f, 0), 1)
    }

    /// Scroll by the finger's travel in whole cells.
    private func scroll(_ t: VFDTouch, to point: CGPoint) {
        let size: CGFloat = cellPt > 0 ? cellPt : 1
        let moved: Double = Double((t.start.y - point.y) / size)
        if !moved.isFinite { return }
        let rowsMoved: Int = Int(min(max(moved, -100_000), 100_000).rounded())
        let value: Int = max(0, min(t.scrollStart + rowsMoved, t.limit))
        setScroll(t.target, value, redraw: true)
    }

    private func currentScroll(_ target: VFDScrollTarget) -> Int {
        switch target {
        case .page:
            return session.pageScroll(currentTab)
        case .region(let id):
            return session.regionScroll(currentTab, id)
        case .menu:
            return menuScroll
        }
    }

    private func setScroll(_ target: VFDScrollTarget, _ value: Int, redraw: Bool) {
        if currentScroll(target) == value { return }
        switch target {
        case .page:
            session.setPageScroll(currentTab, value)
        case .region(let id):
            session.setRegionScroll(currentTab, id, value)
        case .menu:
            menuScroll = value
        }
        if redraw {
            requestRedraw()
        }
    }

    /// Keep going after release by the distance the gesture predicts, in whole cells, easing out.
    private func startFling(_ t: VFDTouch, _ value: DragGesture.Value) {
        let size: CGFloat = cellPt > 0 ? cellPt : 1
        let extraPt: CGFloat = value.predictedEndLocation.y - value.location.y
        let extra: Double = Double(-extraPt / size)
        if !extra.isFinite { return }
        let rowsExtra: Int = Int(min(max(extra, -100_000), 100_000).rounded())
        if abs(rowsExtra) < 3 { return }
        let from: Int = currentScroll(t.target)
        let to: Int = max(0, min(from + rowsExtra, t.limit))
        if to == from { return }
        let distance: Double = Double(abs(to - from))
        let duration: Double = min(0.6, max(0.25, distance / 900.0))
        fling = VFDFling(tab: currentTab, target: t.target, from: from, to: to,
                         start: Date().timeIntervalSinceReferenceDate, duration: duration)
        wantFast = true
        if !fastClock {
            fastClock = true
        }
        requestRedraw()
    }

    /// Move a running fling to where it is at `now` (called while composing).
    private func advanceFling(_ now: Double) {
        guard let f = fling else { return }
        if f.tab != currentTab {
            fling = nil
            return
        }
        var p: Double = 1
        if f.duration > 0 {
            p = min(1, max(0, (now - f.start) / f.duration))
        }
        let inv: Double = 1 - p
        let eased: Double = 1 - inv * inv * inv
        let v: Int = f.from + Int((Double(f.to - f.from) * eased).rounded())
        setScroll(f.target, v, redraw: false)
        if p >= 1 {
            fling = nil
        }
    }
}
