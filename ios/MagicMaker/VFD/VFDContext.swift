import SwiftUI
import UIKit

// What a VFD screen gets while it draws (VFDContext), the screen protocol the renderer dispatches
// to, per-tab UI state and scroll offsets that last while the app runs (VFDUIState, VFDSession),
// and the true-colour helpers for colour content (VFDColors, VFDAnim).

// MARK: - Screens

/// One VFD tab, an immediate-mode drawing of the matching standard screen.
///
///     @MainActor
///     enum VFDScanScreen: VFDScreen {
///         static let title: String = "SCAN"
///         static func headerRight(_ ctx: VFDContext) -> (text: String, action: () -> Void)? { nil }
///         static func draw(_ ctx: VFDContext) -> Int? { ... }
///     }
///
/// `draw` lays the content out from `ctx.L.contentTop` in content coordinates into `ctx.fb` and
/// returns the content end row (exclusive), or nil when the screen scrolls nothing as a page. It
/// runs twice per frame (a scratch pass for edge snapping, then the real one), so it must not
/// change any state: read `ctx.vm`, `ctx.scan`, `ctx.tx`, `ctx.ui`, `ctx.scroll(_:)`, and change
/// things only inside the closures it hands to the widgets.
@MainActor
protocol VFDScreen {
    /// Header title (mid size, uppercased by the header).
    static var title: String { get }
    /// Optional right-aligned header text button.
    static func headerRight(_ ctx: VFDContext) -> (text: String, action: () -> Void)?
    /// Content; returns the end row for page scrolling.
    static func draw(_ ctx: VFDContext) -> Int?
    /// Ink of the header's right text (default highlight; dim = shown disabled, no tap).
    static func headerRightColor(_ ctx: VFDContext) -> UInt8
    /// A "< BACK" action in the header (default none).
    static func back(_ ctx: VFDContext) -> (() -> Void)?
}

extension VFDScreen {
    static func headerRightColor(_ ctx: VFDContext) -> UInt8 {
        return VFDInk.highlight
    }

    static func back(_ ctx: VFDContext) -> (() -> Void)? {
        return nil
    }
}

// MARK: - Overlay requests

/// One row of `VFDContext.menu`: the label (uppercased when drawn), destructive rows in alarm
/// ink, disabled rows dim with no tap.
struct VFDMenuItem {
    let label: String
    let destructive: Bool
    let enabled: Bool
    let action: () -> Void

    init(_ label: String, destructive: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.label = label
        self.destructive = destructive
        self.enabled = enabled
        self.action = action
    }
}

/// The keyboard of a `VFDContext.prompt` text field.
enum VFDKeyboard {
    /// Free text (names, labels).
    case text
    /// Digits only.
    case number
    /// Digits and a decimal point.
    case decimal
    /// Digits and punctuation (negative numbers, times).
    case signed
    /// An IP address (digits and dots).
    case ip
    case url
    /// Hex bytes: ASCII keys, typed in capitals.
    case hex

    var uiKeyboardType: UIKeyboardType {
        switch self {
        case .text: return .default
        case .number: return .numberPad
        case .decimal: return .decimalPad
        case .signed: return .numbersAndPunctuation
        case .ip: return .numbersAndPunctuation
        case .url: return .URL
        case .hex: return .asciiCapable
        }
    }

    var capitalization: TextInputAutocapitalization {
        switch self {
        case .text: return .sentences
        case .hex: return .characters
        default: return .never
        }
    }
}

// MARK: - Context

/// What a VFD screen gets: the frame buffer and layout of the frame being drawn, the animation
/// time, the app's engines, its own UI state and scroll offsets, and the overlays (system alerts,
/// a VFD-drawn menu, a sheet with standard SwiftUI). One context lives as long as the VFD view;
/// the renderer points it at each frame.
@MainActor
final class VFDContext {
    let vm: AppViewModel
    let store: MagicStore
    let scan: ScanEngine
    let tx: TxEngine
    let settings: VFDSettings

    /// The buffer to draw into: a scratch buffer on the snapping pass, then the real one.
    private(set) var fb: VFDFrameBuffer
    private(set) var L: VFDLayout
    /// Seconds since the reference date (Date().timeIntervalSinceReferenceDate) for this frame;
    /// the same value on both passes. Animations derive their phase from it.
    private(set) var time: Double = 0
    /// Key of the tab being drawn ("scan" ... "settings").
    private(set) var tab: String = "scan"

    weak var renderer: VFDRenderer?
    private let session: VFDSession

    init(vm: AppViewModel, store: MagicStore, scan: ScanEngine, tx: TxEngine, settings: VFDSettings,
         fb: VFDFrameBuffer, L: VFDLayout) {
        self.vm = vm
        self.store = store
        self.scan = scan
        self.tx = tx
        self.settings = settings
        self.fb = fb
        self.L = L
        self.session = VFDSession.shared
    }

    // MARK: renderer only

    /// Point the context at a new frame (renderer only).
    func beginFrame(fb: VFDFrameBuffer, L: VFDLayout, time: Double, tab: String) {
        self.fb = fb
        self.L = L
        self.time = time
        self.tab = tab
    }

    /// Switch the buffer between the two passes (renderer only).
    func use(_ fb: VFDFrameBuffer) {
        self.fb = fb
    }

    // MARK: state

    /// This tab's UI state (collapsed sections, selections, drafts), kept while the app runs.
    var ui: VFDUIState { return session.ui(tab) }

    /// Another tab's UI state.
    func uiState(for tab: String) -> VFDUIState {
        return session.ui(tab)
    }

    /// The current time, for actions (`time` is the frame's).
    var now: Double { return Date().timeIntervalSinceReferenceDate }

    /// Rows the page content is scrolled by (the renderer applies it; screens rarely need it).
    var pageScroll: Int { return session.pageScroll(tab) }

    func setPageScroll(_ rows: Int) {
        session.setPageScroll(tab, max(0, rows))
        redraw()
    }

    /// Offset in rows of this tab's scroll region `id` (see `VFDFrameBuffer.scrollRegion`).
    func scroll(_ id: String) -> Int {
        return session.regionScroll(tab, id)
    }

    /// `scroll(id)` clamped to 0...limit (limit = content rows - window rows), for a list whose
    /// content may have shrunk since the last drag.
    func scroll(_ id: String, limit: Int) -> Int {
        let v: Int = session.regionScroll(tab, id)
        return max(0, min(v, max(0, limit)))
    }

    /// Set a scroll region's offset (e.g. back to the top after a filter change).
    func setScroll(_ id: String, _ rows: Int) {
        session.setRegionScroll(tab, id, max(0, rows))
        redraw()
    }

    // MARK: overlays

    /// System alert with one text field (numbers, names, IP addresses). `onDone` gets the text as
    /// typed when OK is tapped; nothing happens on CANCEL.
    func prompt(title: String, message: String = "", text: String = "", keyboard: VFDKeyboard = .text,
                onDone: @escaping (String) -> Void) {
        let request = VFDPromptRequest(title: title, message: message, keyboard: keyboard, onDone: onDone)
        renderer?.presentPrompt(request, text: text)
    }

    /// System alert with CANCEL and `confirmLabel` (red when destructive), which runs `action`.
    func confirm(title: String, message: String = "", confirmLabel: String = "OK", destructive: Bool = false,
                 action: @escaping () -> Void) {
        let request = VFDConfirmRequest(title: title, message: message, confirmLabel: confirmLabel,
                                        destructive: destructive, action: action)
        renderer?.presentConfirm(request)
    }

    /// A VFD-drawn modal menu over the content: the title boxed, one row per item, then CANCEL.
    /// While it is open it takes every tap; a tap outside it closes it. Picking an item closes the
    /// menu first, then runs the item's action.
    func menu(title: String, items: [VFDMenuItem]) {
        renderer?.presentMenu(VFDMenuRequest(title: title, items: items))
    }

    var menuOpen: Bool { return renderer?.menuOpen ?? false }

    func closeMenu() {
        renderer?.closeMenu()
    }

    /// Standard SwiftUI in a sheet (QR scanner, share sheet, file import/export, the system
    /// colour picker, anything not drawn on the grid). The sheet gets the app's environment
    /// objects and a DONE button.
    func sheet<Content: View>(id: String, @ViewBuilder content: @escaping () -> Content) {
        let make: () -> AnyView = { AnyView(content()) }
        renderer?.presentSheet(VFDSheetItem(id: id, content: make))
    }

    func dismissSheet() {
        renderer?.dismissSheet()
    }

    /// The standard screen of a tab ("scan" ... "settings") in a sheet.
    func openStandard(_ tab: String) {
        let key: String = tab
        sheet(id: "standard:" + key) {
            VFDStandardScreen(tab: key)
        }
    }

    /// Switch to a tab by key, as the tab bar does.
    func selectTab(_ key: String) {
        renderer?.selectTab(key: key)
    }

    /// Draw again soon (after a change the renderer cannot see, e.g. a finished Task).
    func redraw() {
        renderer?.requestRedraw()
    }
}

// MARK: - UI state

/// Typed key/value UI state of one tab (collapsed sections, selections, drafts), kept in memory
/// while the app runs. The `stored...` accessors read and write UserDefaults under the given key
/// instead, so a screen can share what the standard screen persists (same keys, same values).
/// Setters redraw; call them from actions only, never from `draw`.
final class VFDUIState {
    let tab: String
    private var values: [String: Any] = [:]
    fileprivate var notify: (() -> Void)?

    init(tab: String) {
        self.tab = tab
    }

    private func changed() {
        notify?()
    }

    func has(_ key: String) -> Bool {
        return values[key] != nil
    }

    func remove(_ key: String) {
        values[key] = nil
        changed()
    }

    // MARK: in memory

    func bool(_ key: String, default fallback: Bool = false) -> Bool {
        return (values[key] as? Bool) ?? fallback
    }

    func setBool(_ key: String, _ value: Bool) {
        values[key] = value
        changed()
    }

    /// Flip a Bool (starting from `fallback` when unset).
    func toggleBool(_ key: String, default fallback: Bool = false) {
        setBool(key, !bool(key, default: fallback))
    }

    func int(_ key: String, default fallback: Int = 0) -> Int {
        return (values[key] as? Int) ?? fallback
    }

    func setInt(_ key: String, _ value: Int) {
        values[key] = value
        changed()
    }

    func double(_ key: String, default fallback: Double = 0) -> Double {
        return (values[key] as? Double) ?? fallback
    }

    func setDouble(_ key: String, _ value: Double) {
        values[key] = value
        changed()
    }

    func string(_ key: String, default fallback: String = "") -> String {
        return (values[key] as? String) ?? fallback
    }

    func setString(_ key: String, _ value: String) {
        values[key] = value
        changed()
    }

    /// A string that may be unset (a selected id, an open item).
    func optionalString(_ key: String) -> String? {
        return values[key] as? String
    }

    func setOptionalString(_ key: String, _ value: String?) {
        if let v = value {
            values[key] = v
        } else {
            values[key] = nil
        }
        changed()
    }

    func strings(_ key: String) -> Set<String> {
        return (values[key] as? Set<String>) ?? Set<String>()
    }

    func setStrings(_ key: String, _ value: Set<String>) {
        values[key] = value
        changed()
    }

    /// Add `member` to the set at `key`, or remove it if present.
    func toggleMember(_ key: String, _ member: String) {
        var set: Set<String> = strings(key)
        if set.contains(member) {
            set.remove(member)
        } else {
            set.insert(member)
        }
        setStrings(key, set)
    }

    // MARK: persisted (UserDefaults, shared with the standard screens)

    /// A Bool stored as a number, or as "true"/"false" text (as Android-style imports write it).
    func storedBool(_ key: String, default fallback: Bool) -> Bool {
        let value: Any? = UserDefaults.standard.object(forKey: key)
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return text.lowercased() == "true" }
        return fallback
    }

    func setStoredBool(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
        changed()
    }

    func storedInt(_ key: String, default fallback: Int) -> Int {
        let value: Any? = UserDefaults.standard.object(forKey: key)
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String, let n = Int(text) { return n }
        return fallback
    }

    func setStoredInt(_ key: String, _ value: Int) {
        UserDefaults.standard.set(value, forKey: key)
        changed()
    }

    func storedString(_ key: String, default fallback: String) -> String {
        return UserDefaults.standard.string(forKey: key) ?? fallback
    }

    func setStoredString(_ key: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: key)
        changed()
    }

    func storedStrings(_ key: String) -> [String] {
        return UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func setStoredStrings(_ key: String, _ value: [String]) {
        UserDefaults.standard.set(value, forKey: key)
        changed()
    }
}

/// Per-tab UI state and scroll offsets for the whole run of the app, so they survive tab
/// switches and switching the theme away and back.
final class VFDSession {
    static let shared: VFDSession = VFDSession()

    /// Called after any UI state change (the renderer redraws).
    var onChange: (() -> Void)?

    private var states: [String: VFDUIState] = [:]
    private var pages: [String: Int] = [:]
    private var regions: [String: [String: Int]] = [:]

    init() {}

    func ui(_ tab: String) -> VFDUIState {
        if let s = states[tab] { return s }
        let s = VFDUIState(tab: tab)
        s.notify = { [weak self] in
            self?.onChange?()
        }
        states[tab] = s
        return s
    }

    func pageScroll(_ tab: String) -> Int {
        return pages[tab] ?? 0
    }

    func setPageScroll(_ tab: String, _ rows: Int) {
        pages[tab] = rows
    }

    func regionScroll(_ tab: String, _ id: String) -> Int {
        return regions[tab]?[id] ?? 0
    }

    func setRegionScroll(_ tab: String, _ id: String, _ rows: Int) {
        var map: [String: Int] = regions[tab] ?? [:]
        map[id] = rows
        regions[tab] = map
    }
}

// MARK: - True colours for colour content

/// The real colours of packet content as VFD true colours (`fb.rgb(...)`): band LEDs, the wand
/// glow, palette swatches. Text and chrome never use these.
enum VFDColors {
    /// Unlit cell colour: a faded band LED is mixed toward it, so it never reads darker than the grid.
    static let unlit: VFDRGB = VFDPalette.unlitRGB

    /// sRGB channels 0...1 (clamped).
    static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> VFDRGB {
        return VFDRGB(unitRed: red, green: green, blue: blue)
    }

    /// 0xRRGGBB.
    static func rgb(packed v: Int) -> VFDRGB {
        return VFDRGB((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    }

    /// The wand glow colour of starlight palette index `index` (low 5 bits), as
    /// `starlightGlowColor` draws it.
    static func starlightGlow(_ index: Int) -> VFDRGB {
        let c = starlightGlowRGB(index)
        return VFDRGB(unitRed: c.red, green: c.green, blue: c.blue)
    }

    /// The band preview's loop phase 0..<1 at `time` (seconds since the reference date), the same
    /// phase `BandPreviewView` shows at that moment.
    static func bandPhase(_ time: Double) -> Double {
        return BandLedAnimation.phase(time)
    }

    /// Band LED zone `zone` (0...4 = Z1 bottom-left, Z2 top-left, Z3 centre, Z4 top-right, Z5
    /// bottom-right) of `model` at `time`, as `BandPreviewView` animates it, with its opacity
    /// mixed over the unlit cell colour; nil = off (draw the dim unlit ring:
    /// `VFDW.led(fb, x, y, nil)`, else `VFDW.led(fb, x, y, 0, fill: rgb)`).
    static func bandLED(_ model: BandEffectModel, zone: Int, time: Double) -> VFDRGB? {
        let phase: Double = BandLedAnimation.phase(time)
        guard let led = BandLedAnimation.color(model, zone: zone, phase: phase) else { return nil }
        let bg: Double = Double(unlit.r) / 255.0
        let solid = led.composited(over: bg, bg, bg)
        return VFDRGB(unitRed: solid.red, green: solid.green, blue: solid.blue)
    }

    /// Whether the BUZZ line is in its bright half at `time` (BandPreviewView's 6 Hz blink).
    static func buzzOn(_ time: Double) -> Bool {
        return BandLedAnimation.buzzOn(phase: BandLedAnimation.phase(time))
    }
}

/// Timing helpers that match the standard theme's SwiftUI animations.
enum VFDAnim {
    /// The wand send pulse: each ring runs 0.42 s ease-out, the second starts 0.18 s later.
    static let pulseDuration: Double = 0.42
    static let pulseDelay: Double = 0.18

    /// SwiftUI `.easeOut`: the cubic Bezier (0, 0) (0, 0) (0.58, 1) (1, 1) at x in 0...1.
    static func easeOut(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        // Solve bx(s) = x for s by bisection (bx is increasing), then return by(s).
        var lo: Double = 0
        var hi: Double = 1
        var s: Double = x
        for _ in 0..<24 {
            s = (lo + hi) / 2
            let inv: Double = 1 - s
            let bx: Double = 3 * inv * s * s * 0.58 + s * s * s
            if bx < x {
                lo = s
            } else {
                hi = s
            }
        }
        let inv: Double = 1 - s
        return 3 * inv * s * s + s * s * s
    }

    /// Progress 0...1 of the two pulse rings `elapsed` seconds after a send (1 once done, as the
    /// standard wand keeps them; 0 before the first send: pass a negative elapsed).
    static func wandPulse(elapsed: Double) -> (first: Double, second: Double) {
        if elapsed < 0 { return (first: 0, second: 0) }
        let a: Double = easeOut(elapsed / pulseDuration)
        let b: Double = easeOut((elapsed - pulseDelay) / pulseDuration)
        return (first: a, second: b)
    }
}

// MARK: - Standard screens (stop-gap)

/// The standard SwiftUI screen of a tab, shown in a sheet by `VFDContext.openStandard`.
struct VFDStandardScreen: View {
    let tab: String

    init(tab: String) {
        self.tab = tab
    }

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case "scan": ScanScreen()
        case "tx": TxScreen()
        case "wand": WandScreen()
        case "auto": AutoScreen()
        case "link": LinkScreen()
        case "logs": LogsScreen()
        case "map": MapScreen()
        case "diag": DiagScreen()
        case "lab": LabScreen()
        default: SettingsScreen()
        }
    }
}

/// The placeholder layout of a tab not drawn on the grid yet: a panel with a note and a few live
/// readings, then a button that opens the standard screen in a sheet.
@MainActor
enum VFDStub {
    static let note: String = "THIS TAB IS NOT DRAWN ON THE VFD GRID YET. EVERY CONTROL IS ON THE STANDARD SCREEN."

    /// A reading in display case, "—" when empty.
    static func value(_ s: String) -> String {
        return s.isEmpty ? "—" : VFDW.upper(s)
    }

    /// Draws the placeholder for tab `tab` (its label goes on the button). Returns the end row.
    static func draw(_ ctx: VFDContext, tab: String, label: String, readings: [(key: String, value: String)]) -> Int {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let c: Int = L.left
        let w: Int = L.width
        let top: Int = L.contentTop
        let inner = VFDW.panelInner(c, top, w, title: true)
        var y: Int = inner.r
        y = VFDW.textBlock(fb, L, inner.c, y, inner.w, note, color: VFDInk.text)
        for reading in readings {
            y = VFDW.kv(fb, L, inner.c, y, inner.w, reading.key, reading.value)
        }
        y = VFDW.panel(fb, L, c, top, w, y - top + 2, title: "VFD " + label)
        y += VFDW.groupGap
        let key: String = tab
        y = VFDW.button(fb, L, c, y, w, "OPEN STANDARD " + label, primary: true, action: {
            ctx.openStandard(key)
        })
        return y
    }
}
