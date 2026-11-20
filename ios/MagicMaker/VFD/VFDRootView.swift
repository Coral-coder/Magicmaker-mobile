import Combine
import QuartzCore
import SwiftUI
import UIKit

// The VFD theme's whole screen: one full-screen UIKit view (VFDDisplayView) showing the cell frame
// buffer as an image scaled up by whole device pixels with the 1 px black gaps over it (pixel for
// pixel what tools/vfd/vfd.py render_image makes), the chrome and the current tab drawn in two
// passes with edge snapping (render_previews.draw_screen), touch handling on the cell grid (tap,
// hold, scroll with a fling, slider drags, swipes), the overlays and the animation clock. The view
// draws when the renderer asks and on its own clock, and takes the touches itself, so neither
// depends on SwiftUI updating it; SwiftUI hosts it and shows the alerts and the sheet.

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

/// What one frame is drawn from: the engines, the theme and the tab.
struct VFDFrameInputs {
    let vm: AppViewModel
    let store: MagicStore
    let scan: ScanEngine
    let tx: TxEngine
    let settings: VFDSettings
    let tab: MainTab
    let selectTab: (MainTab) -> Void
}

/// Where one frame is drawn: the display view's size (points), device pixels per point and the
/// safe-area insets (points) the grid keeps clear as whole rows.
struct VFDDisplayMetrics {
    let size: CGSize
    let scale: CGFloat
    let insetTop: CGFloat
    let insetBottom: CGFloat
}

/// The cell grid on the screen: cols x rows cells of pitch x pitch device pixels from the top-left
/// corner, at `scale` device pixels per point.
struct VFDGridGeometry: Equatable {
    let cols: Int
    let rows: Int
    let pitch: Int
    let scale: CGFloat
}

/// One composed frame: the cols x rows cell image (one pixel per cell), the grid it is shown on and
/// what the clock does next.
struct VFDPaintedFrame {
    let image: CGImage?
    let grid: VFDGridGeometry
    /// Something on screen animates or a fling runs: the clock runs at 30 fps.
    let animating: Bool
    /// Seconds between slow clock ticks: 1, or 0.5 on a red-ish base (the 1 Hz alarm blink).
    let slowInterval: Double
}

// MARK: - View

/// The VFD theme: the whole screen is one cell grid drawn by `VFDRenderer` into a `VFDDisplayView`.
/// ContentView shows it instead of the standard layout and shares its tab selection.
@MainActor
struct VFDRootView: View {
    @Binding var tab: MainTab
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var store: MagicStore
    @EnvironmentObject var scan: ScanEngine
    @EnvironmentObject var tx: TxEngine
    @ObservedObject private var settings: VFDSettings = VFDSettings.shared
    @StateObject private var renderer: VFDRenderer = VFDRenderer()
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

    /// The UIKit display, full screen (the grid keeps the safe-area rows clear itself), with the
    /// prompt alert. It draws when the renderer asks and on its own clock and takes the touches
    /// itself; each update here hands it fresh inputs and draws again.
    private var grid: some View {
        VFDDisplay(renderer: renderer, inputs: frameInputs)
            .ignoresSafeArea()
            .background(Color.black)
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

    private var frameInputs: VFDFrameInputs {
        let binding: Binding<MainTab> = $tab
        return VFDFrameInputs(
            vm: vm,
            store: store,
            scan: scan,
            tx: tx,
            settings: settings,
            tab: tab,
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

// MARK: - Display

/// Hosts the `VFDDisplayView` and hands it the renderer and each fresh set of frame inputs.
@MainActor
struct VFDDisplay: UIViewRepresentable {
    let renderer: VFDRenderer
    let inputs: VFDFrameInputs

    func makeUIView(context: Context) -> VFDDisplayView {
        let view: VFDDisplayView = VFDDisplayView(frame: CGRect.zero)
        view.attach(renderer: renderer, inputs: inputs)
        return view
    }

    /// The engines, the theme, the tab or an overlay changed: draw again from the fresh inputs.
    func updateUIView(_ uiView: VFDDisplayView, context: Context) {
        uiView.attach(renderer: renderer, inputs: inputs)
    }

    static func dismantleUIView(_ uiView: VFDDisplayView, coordinator: ()) {
        uiView.detach()
    }
}

/// One touch sample: when (UITouch.timestamp, seconds) and where (display points).
private struct VFDTouchSample {
    let time: TimeInterval
    let point: CGPoint
}

/// The VFD screen in UIKit. The renderer's cols x rows cell image sits in a layer scaled up by
/// whole device pixels (nearest neighbour, pitch x pitch device pixels per cell); a static shape
/// layer over it blacks out the right column and bottom row of every cell (1 device pixel); the
/// rest of the view is black. It composes and paints when the renderer asks (requestRedraw,
/// coalesced to the next run loop turn) and on its clock: 30 fps while the last frame animated or
/// a fling runs, else just after every whole second (and half second on a red-ish base); no clock
/// while off screen or in the background. Touches go to the renderer in the view's points, which
/// are the image's (origin top-left of the screen).
@MainActor
final class VFDDisplayView: UIView {
    /// The release velocity is measured over the samples of the last this many seconds.
    private static let velocityWindow: TimeInterval = 0.1
    /// Most touch samples kept.
    private static let maxSamples: Int = 64
    /// Slow clock ticks land this long after a whole (or half) second.
    private static let slowTickOffset: Double = 0.02

    private var renderer: VFDRenderer?
    private var inputs: VFDFrameInputs?
    private let imageLayer: CALayer = CALayer()
    private let gapLayer: CAShapeLayer = CAShapeLayer()
    /// The grid the two layers are laid out for.
    private var grid: VFDGridGeometry?
    private var laidOutSize: CGSize = CGSize(width: -1, height: -1)

    // clock
    private lazy var clockProxy: VFDClockProxy = VFDClockProxy(view: self)
    private var displayLink: CADisplayLink?
    private var slowTimer: Timer?
    /// The interval `slowTimer` was set for.
    private var slowTimerInterval: Double = 0
    /// From the last frame.
    private var animating: Bool = false
    private var slowInterval: Double = 1

    /// The app is in the background: nothing is drawn and the clock stops. Read live rather than
    /// cached from a notification, so a view made while the app still reported .background (a
    /// scene connecting at launch, a Bluetooth relaunch brought forward) never stays dark.
    private var inBackground: Bool {
        return UIApplication.shared.applicationState == UIApplication.State.background
    }

    // engines
    private var observed: [ObjectIdentifier] = []
    private var subscriptions: [AnyCancellable] = []

    // touches
    /// The one touch followed (the first finger down); the others are ignored.
    private var tracked: UITouch?
    private var samples: [VFDTouchSample] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        backgroundColor = UIColor.black
        isOpaque = true
        isUserInteractionEnabled = true
        isMultipleTouchEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "VFD display"
        // One element for the whole grid: with VoiceOver on, touches still go straight to it.
        accessibilityTraits = UIAccessibilityTraits.allowsDirectInteraction

        let still: [String: CAAction] = VFDDisplayView.stillActions()
        imageLayer.actions = still
        imageLayer.contentsGravity = CALayerContentsGravity.resize
        imageLayer.magnificationFilter = CALayerContentsFilter.nearest
        imageLayer.minificationFilter = CALayerContentsFilter.nearest
        imageLayer.backgroundColor = UIColor.black.cgColor
        imageLayer.isOpaque = true
        layer.addSublayer(imageLayer)

        gapLayer.actions = still
        gapLayer.fillColor = UIColor.black.cgColor
        gapLayer.strokeColor = nil
        gapLayer.lineWidth = 0
        gapLayer.fillRule = CAShapeLayerFillRule.nonZero
        layer.addSublayer(gapLayer)

        let center: NotificationCenter = NotificationCenter.default
        center.addObserver(self, selector: #selector(VFDDisplayView.appDidEnterBackground(_:)),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(VFDDisplayView.appWillEnterForeground(_:)),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
        center.addObserver(self, selector: #selector(VFDDisplayView.appDidBecomeActive(_:)),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    /// No implicit animation on the layers (a new frame never cross-fades).
    private static func stillActions() -> [String: CAAction] {
        let none: NSNull = NSNull()
        return [
            "contents": none,
            "bounds": none,
            "position": none,
            "frame": none,
            "path": none,
            "contentsScale": none,
            "hidden": none,
        ]
    }

    // MARK: SwiftUI

    /// The renderer and the latest inputs (makeUIView, updateUIView): draw again.
    func attach(renderer: VFDRenderer, inputs: VFDFrameInputs) {
        if let old = self.renderer, old !== renderer {
            old.detach(display: self)
        }
        self.renderer = renderer
        self.inputs = inputs
        renderer.attach(display: self)
        observe(inputs)
        renderer.requestRedraw()
    }

    /// SwiftUI removed the view (dismantleUIView): stop the clock, the observers and any touch.
    func detach() {
        stopClock()
        subscriptions.removeAll()
        observed = []
        cancelTracking()
        renderer?.detach(display: self)
    }

    // MARK: drawing

    /// Compose and paint one frame now (a redraw the renderer asked for, a clock tick). Nothing is
    /// drawn off screen or in the background; coming back draws again.
    func paintNow() {
        guard let renderer = self.renderer, let inputs = self.inputs else { return }
        if window == nil || inBackground {
            stopClock()
            return
        }
        let painted: VFDPaintedFrame? = renderer.renderFrame(metrics: currentMetrics(), inputs: inputs)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let p = painted {
            if grid != p.grid {
                applyGrid(p.grid)
            }
            if let image = p.image {
                imageLayer.contents = image
            } else {
                imageLayer.contents = nil
            }
        } else {
            // Too small to lay the grid out: black, as before.
            imageLayer.contents = nil
        }
        CATransaction.commit()
        animating = painted?.animating ?? false
        slowInterval = painted?.slowInterval ?? 1.0
        updateClock()
    }

    /// The view's size, device pixels per point and safe-area insets. The window's insets come
    /// first (a prompt's keyboard never changes them); the view's own until the window has any.
    private func currentMetrics() -> VFDDisplayMetrics {
        var scale: CGFloat = traitCollection.displayScale
        if !(scale > 0) || !scale.isFinite {
            scale = window?.windowScene?.screen.scale ?? 0
        }
        let own: UIEdgeInsets = safeAreaInsets
        var top: CGFloat = own.top
        var bottom: CGFloat = own.bottom
        if let w = window {
            let insets: UIEdgeInsets = w.safeAreaInsets
            if insets.top > 0 || own.top <= 0 {
                top = insets.top
                bottom = insets.bottom
            }
        }
        return VFDDisplayMetrics(size: bounds.size, scale: scale, insetTop: top, insetBottom: bottom)
    }

    /// Lays the image and the gap lines out for a new grid (inside the paint's transaction).
    private func applyGrid(_ g: VFDGridGeometry) {
        grid = g
        let scale: CGFloat = (g.scale > 0 && g.scale.isFinite) ? g.scale : 1
        let rect: CGRect = CGRect(x: 0, y: 0, width: CGFloat(g.cols * g.pitch) / scale,
                                  height: CGFloat(g.rows * g.pitch) / scale)
        imageLayer.frame = rect
        gapLayer.frame = rect
        gapLayer.contentsScale = scale
        gapLayer.path = VFDDisplayView.makeGapPath(g, scale: scale)
    }

    /// The right column and bottom row of every cell, 1 device pixel wide, in points (as
    /// vfd.render_image: cell c lights device pixels c * pitch ..< c * pitch + pitch - 1, and pixel
    /// c * pitch + pitch - 1 is black).
    private static func makeGapPath(_ g: VFDGridGeometry, scale: CGFloat) -> CGPath {
        let path: CGMutablePath = CGMutablePath()
        let px: CGFloat = 1.0 / scale
        let fullW: CGFloat = CGFloat(g.cols * g.pitch) / scale
        let fullH: CGFloat = CGFloat(g.rows * g.pitch) / scale
        var c: Int = 0
        while c < g.cols {
            let x: CGFloat = CGFloat(c * g.pitch + g.pitch - 1) / scale
            path.addRect(CGRect(x: x, y: 0, width: px, height: fullH))
            c += 1
        }
        var r: Int = 0
        while r < g.rows {
            let y: CGFloat = CGFloat(r * g.pitch + g.pitch - 1) / scale
            path.addRect(CGRect(x: 0, y: y, width: fullW, height: px))
            r += 1
        }
        return path
    }

    // MARK: clock

    /// 30 fps while the last frame animated (or a fling runs), else the slow tick; nothing while
    /// off screen or in the background.
    private func updateClock() {
        if window == nil || inBackground || renderer == nil {
            stopClock()
            return
        }
        if animating {
            stopSlowTimer()
            startDisplayLink()
        } else {
            stopDisplayLink()
            scheduleSlowTick()
        }
    }

    private func startDisplayLink() {
        if displayLink != nil { return }
        let link: CADisplayLink = CADisplayLink(target: clockProxy,
                                                selector: #selector(VFDClockProxy.frameTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        link.add(to: RunLoop.main, forMode: RunLoop.Mode.common)
        displayLink = link
    }

    private func stopDisplayLink() {
        guard let link = displayLink else { return }
        displayLink = nil
        link.invalidate()
    }

    /// Sets the next slow tick, unless one is already set for the current interval.
    private func scheduleSlowTick() {
        if let timer = slowTimer, timer.isValid, slowTimerInterval == slowInterval { return }
        stopSlowTimer()
        let now: Double = Date().timeIntervalSinceReferenceDate
        let next: Double = VFDDisplayView.nextSlowTick(after: now, interval: slowInterval)
        let timer: Timer = Timer(timeInterval: max(0.001, next - now), target: clockProxy,
                                 selector: #selector(VFDClockProxy.slowTick(_:)), userInfo: nil,
                                 repeats: false)
        RunLoop.main.add(timer, forMode: RunLoop.Mode.common)
        slowTimer = timer
        slowTimerInterval = slowInterval
    }

    private func stopSlowTimer() {
        guard let timer = slowTimer else { return }
        slowTimer = nil
        timer.invalidate()
    }

    private func stopClock() {
        stopDisplayLink()
        stopSlowTimer()
    }

    /// A display link frame (from the clock proxy).
    fileprivate func clockFrame() {
        paintNow()
    }

    /// A slow tick (from the clock proxy); that timer has fired and is done.
    fileprivate func clockTick() {
        slowTimer = nil
        paintNow()
    }

    /// The first tick after `now`: `slowTickOffset` past a multiple of `interval` seconds of the
    /// reference date, so clocks and the alarm blink change on time.
    private static func nextSlowTick(after now: Double, interval: Double) -> Double {
        let step: Double = (interval > 0 && interval.isFinite) ? interval : 1
        let k: Double = ((now - slowTickOffset) / step).rounded(.down)
        return (k + 1) * step + slowTickOffset
    }

    // MARK: lifecycle

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != laidOutSize {
            laidOutSize = bounds.size
            renderer?.requestRedraw()
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        renderer?.requestRedraw()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopClock()
            cancelTracking()
        } else {
            renderer?.requestRedraw()
        }
    }

    @objc private func appDidEnterBackground(_ note: Notification) {
        stopClock()
    }

    /// Draws again (which restarts the clock); a draw that still finds the app in the background
    /// is skipped, and the activation below draws once it is in front.
    @objc private func appWillEnterForeground(_ note: Notification) {
        renderer?.requestRedraw()
    }

    @objc private func appDidBecomeActive(_ note: Notification) {
        renderer?.requestRedraw()
    }

    // MARK: engines

    /// Draw again on every change the engines and the theme announce, without waiting for SwiftUI
    /// to update the view. They announce before they change, so the redraw runs on a later turn.
    private func observe(_ inputs: VFDFrameInputs) {
        let ids: [ObjectIdentifier] = [
            ObjectIdentifier(inputs.vm),
            ObjectIdentifier(inputs.store),
            ObjectIdentifier(inputs.scan),
            ObjectIdentifier(inputs.tx),
            ObjectIdentifier(inputs.settings),
        ]
        if ids == observed { return }
        observed = ids
        var subs: [AnyCancellable] = []
        subs.append(watch(inputs.vm.objectWillChange))
        subs.append(watch(inputs.store.objectWillChange))
        subs.append(watch(inputs.scan.objectWillChange))
        subs.append(watch(inputs.tx.objectWillChange))
        subs.append(watch(inputs.settings.objectWillChange))
        subscriptions = subs
    }

    private func watch<P: Publisher>(_ publisher: P) -> AnyCancellable where P.Failure == Never {
        return publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (_: P.Output) -> Void in
                self?.engineChanged()
            }
    }

    private func engineChanged() {
        renderer?.requestRedraw()
    }

    // MARK: touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let old = tracked {
            if VFDDisplayView.isLive(old, event) { return }
            // The last touch never ended here: forget it before the new one starts.
            cancelTracking()
        }
        guard let touch = touches.first, let renderer = self.renderer else { return }
        tracked = touch
        samples.removeAll(keepingCapacity: true)
        let point: CGPoint = touch.location(in: self)
        addSample(touch.timestamp, point)
        renderer.touchBegan(point)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracked, touches.contains(touch) else { return }
        addSamples(touch, event)
        renderer?.touchMoved(touch.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracked, touches.contains(touch) else { return }
        let point: CGPoint = touch.location(in: self)
        addSamples(touch, event)
        let velocity: CGVector = releaseVelocity()
        tracked = nil
        samples.removeAll(keepingCapacity: true)
        renderer?.touchEnded(point, velocity: velocity)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracked, touches.contains(touch) else { return }
        cancelTracking()
    }

    /// Whether `touch` is still down in `event` (one that ended or was cancelled without this view
    /// hearing of it is not).
    private static func isLive(_ touch: UITouch, _ event: UIEvent?) -> Bool {
        if touch.phase == UITouch.Phase.ended || touch.phase == UITouch.Phase.cancelled {
            return false
        }
        guard let all = event?.allTouches else { return false }
        return all.contains(touch)
    }

    /// Drop the followed touch; the renderer forgets it with no tap, swipe or fling.
    private func cancelTracking() {
        if tracked == nil { return }
        tracked = nil
        samples.removeAll(keepingCapacity: true)
        renderer?.touchCancelled()
    }

    /// Every position the touch passed through since the last event (coalesced touches).
    private func addSamples(_ touch: UITouch, _ event: UIEvent?) {
        if let list = event?.coalescedTouches(for: touch), !list.isEmpty {
            for t in list {
                addSample(t.timestamp, t.location(in: self))
            }
        } else {
            addSample(touch.timestamp, touch.location(in: self))
        }
    }

    /// Keeps the samples of the last velocityWindow seconds.
    private func addSample(_ time: TimeInterval, _ point: CGPoint) {
        samples.append(VFDTouchSample(time: time, point: point))
        while samples.count > 1
            && (time - samples[0].time > VFDDisplayView.velocityWindow
                || samples.count > VFDDisplayView.maxSamples) {
            samples.removeFirst()
        }
    }

    /// Points per second from the oldest to the newest sample of the last velocityWindow seconds;
    /// zero when the finger rested before it lifted.
    private func releaseVelocity() -> CGVector {
        guard let first = samples.first, let last = samples.last else { return CGVector(dx: 0, dy: 0) }
        let dt: TimeInterval = last.time - first.time
        if !(dt > 0.004) { return CGVector(dx: 0, dy: 0) }
        let vx: CGFloat = (last.point.x - first.point.x) / CGFloat(dt)
        let vy: CGFloat = (last.point.y - first.point.y) / CGFloat(dt)
        if !vx.isFinite || !vy.isFinite { return CGVector(dx: 0, dy: 0) }
        return CGVector(dx: vx, dy: vy)
    }
}

/// CADisplayLink and Timer keep their target: they get this proxy, which holds the display view
/// weakly, so a scheduled clock never keeps the view alive. A tick after the view has gone stops
/// that clock.
@MainActor
private final class VFDClockProxy: NSObject {
    weak var view: VFDDisplayView?

    init(view: VFDDisplayView) {
        self.view = view
        super.init()
    }

    @objc func frameTick(_ link: CADisplayLink) {
        guard let view = self.view else {
            link.invalidate()
            return
        }
        view.clockFrame()
    }

    @objc func slowTick(_ timer: Timer) {
        guard let view = self.view else {
            timer.invalidate()
            return
        }
        view.clockTick()
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

/// Composes VFD frames and handles touches. Frames are composed on demand (a state change, an
/// action, the display's clock) into two reused frame buffers and turned into a cell image from a
/// reused bitmap; `VFDDisplayView` shows them and feeds the touches in.
@MainActor
final class VFDRenderer: ObservableObject {
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
    /// A fling carries the scroll on by the release velocity times this many seconds (about what
    /// DragGesture's predictedEndLocation added).
    static let flingProjection: Double = 0.25
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
    /// The view the frames are drawn into: requestRedraw makes it compose and paint.
    private weak var display: VFDDisplayView?

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
    private var lut: [UInt32] = [UInt32](repeating: 0, count: 256)
    private var inkBase: VFDBase?
    private var inkPacked: [UInt32] = []

    // frames
    private var context: VFDContext?
    private var inputs: VFDFrameInputs?
    private var currentTab: String = ""
    private var pageMax: Int = 0
    private var redrawPending: Bool = false

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

    // MARK: display and redraw

    /// `view` draws this renderer's frames from now on.
    func attach(display view: VFDDisplayView) {
        display = view
    }

    /// `view` went away: redraws stop going to it (a newer view keeps them).
    func detach(display view: VFDDisplayView) {
        if display === view {
            display = nil
        }
    }

    /// Draw again on the next run loop turn (coalesced): the display view composes and paints.
    func requestRedraw() {
        if redrawPending { return }
        redrawPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // A clock frame since the request has drawn it already.
            if !self.redrawPending { return }
            self.redrawPending = false
            self.display?.paintNow()
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

    /// Compose a frame for the current state on the display view's geometry and turn it into the
    /// cols x rows cell image. Nil while the view is too small to lay the grid out.
    func renderFrame(metrics: VFDDisplayMetrics, inputs: VFDFrameInputs) -> VFDPaintedFrame? {
        // This frame answers every redraw asked for so far.
        redrawPending = false
        guard prepare(metrics) else { return nil }
        guard let fb = self.fb, let probe = self.probe, let L = self.layout else { return nil }
        self.inputs = inputs
        let ctx: VFDContext = contextFor(inputs, fb: fb, L: L)
        ctx.setDisplay(scale: Double(self.scale), pitch: self.pitch)
        let base: VFDBase = inputs.settings.base
        compose(ctx, fb: fb, probe: probe, L: L, inputs: inputs, base: base)
        let image: CGImage? = makeImage(fb, base: base)
        let grid: VFDGridGeometry = VFDGridGeometry(cols: cols, rows: rows, pitch: pitch, scale: scale)
        let animating: Bool = fb.wantsAnimation || fling != nil
        let slowInterval: Double = VFDPalette.alarmInverted(base) ? 0.5 : 1.0
        if pendingShow != nil {
            scheduleShow()
        }
        return VFDPaintedFrame(image: image, grid: grid, animating: animating, slowInterval: slowInterval)
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

    /// Grid geometry from the display view: pitch 5 px at 3x (4 px at 2x), cols / rows = whole
    /// cells, safe rows = the safe-area insets rounded up to whole cells. Rebuilds the buffers when
    /// it changes. False while the size is too small to lay out.
    private func prepare(_ metrics: VFDDisplayMetrics) -> Bool {
        let size: CGSize = metrics.size
        if !size.width.isFinite || !size.height.isFinite || size.width <= 0 || size.height <= 0 {
            return false
        }
        // Int(_:) traps on an infinite or out-of-range Double: keep the scale and the pixel sizes
        // in a sane range (real screens are 1x...3x and a few thousand pixels).
        let scale: CGFloat = (metrics.scale > 0 && metrics.scale.isFinite) ? min(metrics.scale, 16) : 2
        let widthD: Double = (Double(size.width) * Double(scale)).rounded()
        let heightD: Double = (Double(size.height) * Double(scale)).rounded()
        if !(widthD < 1_000_000) || !(heightD < 1_000_000) { return false }
        let pitch: Int = max(4, Int((5.0 * Double(scale) / 3.0).rounded()))
        let widthPx: Int = Int(widthD)
        let heightPx: Int = Int(heightD)
        let cols: Int = widthPx / pitch
        let rows: Int = heightPx / pitch
        if cols < 60 || rows < 150 { return false }
        let top: Int = VFDRenderer.safeRows(metrics.insetTop, scale: scale, pitch: pitch)
        let bottom: Int = VFDRenderer.safeRows(metrics.insetBottom, scale: scale, pitch: pitch)
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
        self.touch = nil
        return bitmap != nil
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
        if let reveal = menuReveal {
            // First draw of a menu with a current item: open with that row in view.
            menuReveal = nil
            menuScroll = VFDRenderer.revealScroll(reveal, count: m.items.count, shownRows: shownRows, rowH: rowH)
        }
        menuScroll = max(0, min(menuScroll, menuMax))
        // Taps on the panel between the rows do nothing (only taps outside it close the menu).
        fb.tap(c, top, w, panelH, name: "menu:panel")

        // Drawn at the nearest whole row, so no button is ever cut by the list edges.
        let offset: Int = min(menuMax, ((menuScroll + rowH / 2) / rowH) * rowH)
        fb.pushClip(0, listTop, fb.cols, listH)
        var y: Int = listTop - offset
        var index: Int = 0
        for item in m.items {
            if y + rowH > listTop && y < listTop + listH {
                let current: Bool = m.selected == index
                drawMenuRow(item, current: current, fb: fb, L: L, c: inner.c, y: y, w: inner.w)
            }
            y += rowH
            index += 1
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

    /// One menu row, ctrlH tall. Without `rgb`: VFDW.button (the current row as the primary
    /// block). With it: the same box or block, a 5 x 5 swatch of the true colour in the first
    /// glyph slot, a blank glyph slot, then the label left-aligned; on a block the swatch keeps an
    /// unlit ring and the label is cut out, as on a selected BASE COLOUR chip. Tap
    /// "menu:<LABEL>" when enabled: it closes the menu, then runs the item's action.
    private func drawMenuRow(_ item: VFDMenuItem, current: Bool, fb: VFDFrameBuffer, L: VFDLayout,
                             c: Int, y: Int, w: Int) {
        let name: String = "menu:" + VFDW.upper(item.label)
        let action: () -> Void = item.action
        let pick: () -> Void = { [weak self] in
            self?.closeMenu()
            action()
        }
        guard let color = item.rgb else {
            VFDW.button(fb, L, c, y, w, item.label, primary: current, enabled: item.enabled, name: name,
                        alarm: item.destructive, action: pick)
            return
        }
        let ty: Int = y + VFDW.ctrlText
        let sx: Int = c + 3
        let tx: Int = sx + 2 * VFDW.adv
        let label: String = VFDRenderer.fitKeepingTick(VFDW.upper(item.label), c + w - 2 - tx)
        var solid: Bool = false
        var border: UInt8 = item.enabled ? VFDInk.highlight : VFDInk.dim
        var ink: UInt8 = item.enabled ? VFDInk.text : VFDInk.dim
        if item.enabled && item.destructive {
            if fb.alarmInverted {
                solid = true
            } else {
                border = VFDInk.alarm
                ink = VFDInk.alarm
            }
        } else if item.enabled && current {
            solid = true
        }
        if solid {
            fb.fill(c, y, w, VFDW.ctrlH, VFDInk.highlight)
            fb.fill(sx - 1, ty, 7, 7, VFDInk.unlit)
            ink = VFDInk.unlit
        } else {
            fb.box(c, y, w, VFDW.ctrlH, border)
        }
        let swatch: UInt8 = fb.rgb(color)
        fb.fill(sx, ty + 1, 5, 5, swatch)
        fb.text(tx, ty, label, .small, ink)
        if item.enabled {
            VFDW.tap(fb, c, y, w, VFDW.ctrlH, name, action: pick)
        }
    }

    /// VFDText.fit, except that a trailing " ✓" (the current item's tick) survives the cut.
    private static func fitKeepingTick(_ s: String, _ maxCols: Int) -> String {
        let tick: String = " ✓"
        if !s.hasSuffix(tick) || VFDText.width(s) <= maxCols {
            return VFDText.fit(s, maxCols)
        }
        let head: String = VFDText.fit(String(s.dropLast(2)), maxCols - 2 * VFDW.adv)
        if head.isEmpty {
            return VFDText.fit("✓", maxCols)
        }
        return head + tick
    }

    /// The list offset (whole rows) that centres row `index` in a window of `shownRows` rows,
    /// as far as the list allows.
    private static func revealScroll(_ index: Int, count: Int, shownRows: Int, rowH: Int) -> Int {
        if index < 0 || index >= count || shownRows <= 0 { return 0 }
        let first: Int = index - (shownRows - 1) / 2
        let lastFirst: Int = max(0, count - shownRows)
        return max(0, min(first, lastFirst)) * rowH
    }

    // MARK: image

    /// The cells as a cols x rows image, one pixel per cell (the display view scales it up by whole
    /// device pixels and draws the gap lines over it).
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

    // MARK: touches

    /// Finger down at `point` (the display view's points, origin top-left of the screen). A hold
    /// is timed from here.
    func touchBegan(_ point: CGPoint) {
        beginTouch(at: point)
    }

    /// The finger moved. Ignored while no touch is down (a tab change or a new grid dropped it).
    func touchMoved(_ point: CGPoint) {
        guard var t = touch else { return }
        let dx: CGFloat = point.x - t.start.x
        let dy: CGFloat = point.y - t.start.y
        switch t.mode {
        case .pending:
            let dist: CGFloat = (dx * dx + dy * dy).squareRoot()
            if dist < VFDRenderer.slop { return }
            decideAxis(&t, dx: dx, dy: dy)
            touch = t
            if t.mode == .scroll {
                scroll(t, to: point)
            } else if t.mode == .slide {
                slide(t, at: point, ended: false)
            }
        case .scroll:
            scroll(t, to: point)
        case .slide:
            slide(t, at: point, ended: false)
        case .held, .swipe, .ignored:
            break
        }
    }

    /// The finger lifted at `point`, moving at `velocity` (points per second).
    func touchEnded(_ point: CGPoint, velocity: CGVector) {
        guard let t = touch else { return }
        touch = nil
        let dx: CGFloat = point.x - t.start.x
        let dy: CGFloat = point.y - t.start.y
        let dist: CGFloat = (dx * dx + dy * dy).squareRoot()
        switch t.mode {
        case .pending:
            if dist < VFDRenderer.slop {
                tap(t, at: point)
            }
        case .slide:
            slide(t, at: point, ended: true)
        case .swipe:
            if dx <= -VFDRenderer.swipeDistance, let left = t.hit?.swipeLeft {
                left()
                requestRedraw()
            } else if dx >= VFDRenderer.swipeDistance, let right = t.hit?.swipeRight {
                right()
                requestRedraw()
            }
        case .scroll:
            startFling(t, velocity: velocity)
        case .held, .ignored:
            break
        }
    }

    /// The system took the touch (an alert or a sheet came up, the app left, the view went away):
    /// forget it with no tap, swipe, slide end or fling.
    func touchCancelled() {
        touch = nil
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

    /// Keep going after release by the distance the release velocity predicts (velocity x
    /// flingProjection, about DragGesture's predictedEndLocation), in whole cells, easing out.
    private func startFling(_ t: VFDTouch, velocity: CGVector) {
        let size: CGFloat = cellPt > 0 ? cellPt : 1
        let extraPt: CGFloat = velocity.dy * CGFloat(VFDRenderer.flingProjection)
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
        // The next frame sees the fling and runs the display's clock at 30 fps until it ends.
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
