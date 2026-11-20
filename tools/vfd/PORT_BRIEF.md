# VFD theme — app port brief (iOS first, Android after)

The user approved the preview look (`tools/vfd/out/*.png`, made by `render_previews.py` from
`screens/*.py`) and asked for two changes on top of it, which **override** the spec's "nothing else"
palette rule for packet content:

1. **Real colours for colour content.** Band LEDs, the wand glow, pattern/effect colours and colour
   swatches are drawn in their true RGB, like the standard theme does. Everything else (text, chrome,
   borders, labels, values, controls) stays in the 5-ink palette.
2. **Animation.** The band preview (LAB), the LAST LIGHTS strip (SCAN) and the wand (send pulse, glow)
   animate exactly like the standard screens do.

Order of work: **the iPhone app first** (ship to TestFlight), then Android with the same design.

Read first: `.claude/skills/vfd-theme/SKILL.md` (the look; still binding except for the two overrides
above), `tools/vfd/BRIEF.md` (preview-stage rules), `tools/vfd/README.md`, and for Swift
`.claude/ios-parity/IOS_PORT_RULES.md` (iOS 17, Swift 5.9 language mode, Xcode 26 in CI only — there
is **no Swift compiler on this machine**; write code that compiles first time: no guessing at APIs,
explicit types where inference is shaky, no `@Observable` macro, no Swift 6-only syntax).

The Python files are the **layout reference**: `vfd.py` (frame buffer), `widgets.py` (chrome and
widgets, exact geometry), `screens/<tab>.py` (each screen's layout with mock data),
`render_previews.py` (`content_window` / `draw_screen`: the two-pass edge snapping). The Swift port
reproduces them cell for cell. The standard SwiftUI screens (`ios/MagicMaker/Views/*Screen.swift`) are
the **behaviour reference**: every control, its action, its wording and its data source.

## Files (iOS) — `ios/MagicMaker/VFD/`

The coordinator registers new files in the Xcode project (a `VFD` group); agents never edit
`project.pbxproj`. Never commit or push; the coordinator does that.

| file | contents | imports |
|---|---|---|
| `VFDGlyphs.swift` | generated: `python3 tools/vfd/gen_swift.py ios/MagicMaker/VFD/VFDGlyphs.swift` | Foundation |
| `VFDCore.swift` | ink constants, `VFDRGB`, `VFDBase`, palette maths, `VFDFrameBuffer`, text metrics, hits, scroll regions | Foundation only |
| `VFDWidgets.swift` | `VFDLayout` + every function of `widgets.py` (same geometry), edge-snap helpers | Foundation only |
| `VFDSettings.swift` | `final class VFDSettings: ObservableObject` (shared): theme + base colour, UserDefaults | SwiftUI |
| `VFDContext.swift` | `final class VFDContext`: what a screen gets (see below) | SwiftUI |
| `VFDRootView.swift` | the full-screen Canvas renderer, gestures, chrome, overlays, animation clock, tab dispatch | SwiftUI |
| `VFD<Tab>Screen.swift` | one per tab: Scan, Tx, Wand, Auto, Link, Logs, Map, Diag, Lab, Settings | SwiftUI |
| `ios/VFDCheck/main.swift` | golden check of the Foundation-only core (runs on Linux in CI) | Foundation |

`VFDCore.swift`, `VFDWidgets.swift` and `VFDGlyphs.swift` must compile with plain `swiftc` on Linux
(Foundation only: no SwiftUI, UIKit, CoreGraphics, `CGFloat`, `os_log`).

## Core API (Swift names; Kotlin later mirrors them)

Ink indices (`UInt8`): `VFDInk.unlit = 0, .highlight = 1, .text = 2, .dim = 3, .alarm = 4`. Indices
`5...255` are **true colours** allocated per frame by `fb.rgb(_:)`.

- `struct VFDRGB: Equatable, Hashable { var r, g, b: UInt8 }` with `init(hex: "#RRGGBB")`, `.hex`.
- `enum VFDBase: Equatable { case preset(String); case custom(VFDRGB) }` — persisted as the preset
  name (`"AMBER"`) or `"#RRGGBB"`; `VFDBase.presets` = AMBER GREEN CYAN BLUE RED WHITE (order and RGB as
  `vfd.PRESETS`); `VFDPalette.colors(for:) -> [VFDRGB]` (5 entries, exactly `vfd.palette_for`,
  rounding half away from zero) and `VFDPalette.alarmInverted(_:) -> Bool` (exactly
  `vfd.alarm_inverted`).
- `enum VFDSize { case small, mid, big }` with the metrics of `vfd_font.SIZES`.
- `final class VFDFrameBuffer` (mirrors `vfd.FrameBuffer` one to one, camelCase names):
  `cols, rows, cells: [UInt8], alarmInverted, base`; `clear()`, `get`, `set`, `fill`,
  `hline(step:)`, `vline(step:)`, `box`, `text(...) -> Int`, `textRight(...) -> Int`, `textFit`,
  `paragraph(...) -> Int`, `inverted(...) -> Int`, `alarm(...) -> Int`, `ledBar(...)`,
  `lineChart(...)`, `pushClip(c, r, w, h, dy:)`, `popClip()`, `originY`, `clipRect`;
  plus
  - `trueColors: [VFDRGB]` and `rgb(_ c: VFDRGB) -> UInt8` (dedups within a frame; reset by
    `clear()`; when all 251 slots are used it returns the nearest existing one);
  - hits: `tap(c, r, w, h, name: String, action: (() -> Void)? = nil, long: (() -> Void)? = nil,
    swipeLeft: (() -> Void)? = nil, swipeRight: (() -> Void)? = nil,
    drag: ((Double, Bool) -> Void)? = nil)` records a `VFDHit` in **screen** cells clipped to the
    current clip (same rules as Python `fb.tap` / `widgets._tap`); `hit(c, r) -> VFDHit?` = topmost;
  - `scrollRegion(id: String, c, r, w, h, contentRows: Int)` — a sub-area that scrolls on its own
    (TX library, LOGS list...); drags that start inside it scroll it instead of the page;
  - `wantsAnimation: Bool` — a screen sets it while something animated is visible.
- Text helpers: `VFDText.width(_:size:)`, `maxChars`, `fit`, `wrap` (= `vfd.text_width`, `max_chars`,
  `fit_text`, `wrap_text`, including the `·` / dash wrapping rules).

`VFDWidgets.swift`: `struct VFDLayout` (= `widgets.Layout`, built from `cols, rows, safeTop,
safeBottom`, plus `x(_ frac:)`, `split`, `tabCell`) and `enum VFDW` with every function of
`widgets.py` (header, telemetry, tabBar, frame, endFrame, scrollbar, section, label, textBlock,
statusLine, kv, hero, divider, panel, toggle, options, stepper, button, buttons, slider, meter,
field, packetRow, chart, snappedWindow, listScrollbar, tokenLines, intervalStop/Text/Slider,
menuButton, led, badge, alarmText, tagBox, chevron, chevronUp, stepButton, …) with the **same
geometry and return values**. Where Python takes a tap `name`, Swift takes the name **and** optional
closures (`action`, `onSelect: (Int) -> Void`, `onDec/onInc`, `onSet: (Double) -> Void` for sliders
— also wired as the hit's `drag`, `long`, `swipeLeft/Right` for packet rows). `tabBar` takes the
labels to show (iOS: `SCAN TX WAND AUTO LINK / LOGS MAP DIAG LAB SETUP`; Android will pass RELAY).
`led(...)` gains an optional true-colour fill (`fill: VFDRGB?`).

## Golden check (proves the Swift core = the Python reference)

- `tools/vfd/golden.py` (Python, stdlib + the vfd modules, no Pillow) writes
  `tools/vfd/golden/ops.txt` — a deterministic list of draw calls, one per line, fields separated by
  TAB: `page <name> <device pro|x2> <base>` starts a page (new buffer, `VFDLayout` for that device), then
  ops named after the API (`fill`, `hline`, `text`, `inverted`, `alarm`, `led_bar`, `line_chart`,
  `push_clip`, `pop_clip`, `rgb_fill`, `header`, `telemetry`, `tab_bar`, `section`, `toggle`,
  `options`, `stepper`, `button`, `slider`, `field`, `packet_row`, `led`, `kv`, `status_line`,
  `paragraph`, `text_fit`, … — cover every widget the screens use, both devices, AMBER and RED bases,
  clipping and scrolled origins), and `tools/vfd/golden/expected.txt`: per page the FNV-1a 64 hash of
  the cells, the true-colour table and the hit list (`c r w h name`), plus each op's return value.
  `golden.py --dump DIR` writes readable per-page dumps for diffing.
- `ios/VFDCheck/main.swift` reads `ops.txt`, replays it with the Swift core, compares with
  `expected.txt`, prints the first mismatches (and `--dump DIR` writes the same dump format), exits 1
  on any mismatch.
- `.github/workflows/ios-core-parity.yml` gets a second job "VFD core matches the Python reference":
  compile the three Foundation-only VFD files + `ios/VFDCheck/main.swift` with `swiftc`, run it
  against `tools/vfd/golden`, and on failure run `python3 tools/vfd/golden.py --dump` and annotate the
  first differing lines (reuse the job's annotate helper). Add `ios/MagicMaker/VFD/**`,
  `ios/VFDCheck/**` and `tools/vfd/**` to the `paths` filter.

## Renderer and interaction (`VFDRootView`)

- One full-screen `Canvas`, `.ignoresSafeArea()`, origin = screen (0,0). `pitchPx = scale >= 3 ? 5 : 4`
  (generally `max(4, Int((5 * scale / 3).rounded()))`), `cellPt = pitchPx / scale`,
  `cols = floor(widthPx / pitchPx)`, `rows = floor(heightPx / pitchPx)`, safe rows =
  `ceil(insetPt * scale / pitchPx)` from the real safe-area insets.
- Paint: build a `cols × rows` RGBA bitmap from the cells (5 palette inks + `trueColors`), draw it
  with `.interpolation(.none)` into `cols*cellPt × rows*cellPt`, then fill the 1-px black gap lines
  (right column and bottom row of every pitch) and the leftover edge area in black. The result must be
  pixel-identical to `vfd.render_image`. Unlit = #090909, background #000.
- Chrome = `widgets.frame` (header with the tab's title and optional right action, telemetry line —
  the **same text as the standard `TelemetryBar`**, reuse its builder — rules, tab bar). Tab bar taps
  switch tabs (shared with ContentView's tab state so `vm.requestedTab` still works).
- Content: two-pass like `render_previews.draw_screen` — draw once on a scratch buffer, snap the window
  with `snappedWindow`, draw for real, drop hidden partial taps, then the scrollbar. **Screen draw
  functions must be pure** (no state mutation; they run twice a frame).
- Gestures (one `DragGesture(minimumDistance: 0)` + timing): press-and-release without moving
  (< ~8 pt) = tap → topmost hit's `action`; held ≥ 0.5 s without moving = `long`; a drag decides its
  axis after ~8 pt: vertical scrolls the scroll region under the start point (else the page) in whole
  cells with a short fling; horizontal on a hit with `drag` → continuous `drag(fraction 0...1,
  ended)` across the hit's width (sliders); horizontal ≥ 40 pt on a hit with `swipeLeft/Right` → that
  action on release. Page scroll is clamped to `[0, contentEnd − viewport]`; scroll offsets and
  per-region offsets persist per tab while the app runs.
- Redraw: on any `vm` / `scan` / `tx` / `VFDSettings` change (observe them like the standard screens
  do), after every action, and on a clock: `TimelineView` at 30 fps while the last frame had
  `wantsAnimation`, else every 1 s (alarm blink on red-ish bases, clocks, ages).
- Overlays provided by the context (all drawn VFD-style except where the system UI is needed):
  - `ctx.prompt(title:message:text:keyboard:onDone:)` — system alert with a `TextField` (number and
    text entry, renames, IP addresses);
  - `ctx.confirm(title:message:confirmLabel:destructive:action:)` — system alert;
  - `ctx.menu(title:items:)` — a VFD-drawn modal panel over the content (boxed title, one row per
    item, destructive items in alarm ink, CANCEL); while open it takes all taps; replaces the
    standard context menus / action sheets (the packet "HOLD MENU");
  - `ctx.sheet(id:content:)` — the stop-gap: presents standard SwiftUI UI in a sheet (QR camera
    scanner, share sheet, file importer/exporter, the system `ColorPicker` for CUSTOM base colour,
    anything not converted). Keep these few.
- `VFDContext` gives a screen: `fb`, `L`, `time` (seconds, for animation), `vm`, `scan`, `tx`,
  `settings`, `ui` (per-tab UI state: collapsed sections, selections, drafts — typed get/set; reuse
  the standard screen's UserDefaults/@AppStorage keys wherever it persists something, so both themes
  share it), `scroll(id)` offsets, and the overlay functions above.

## True colours and animation (the user's request)

- Where the standard screen shows a packet/effect/wand colour — band LEDs, the band face preview, the
  LAST LIGHTS strip, the wand glow, colour dots/swatches next to colour names (Lab builder colour
  slots, MDE themes, wand colour list, new-wand list…), colour pickers — the VFD screen shows that
  colour in true RGB via `fb.rgb(...)`, as whole cells: filled LED discs (`VFDW.led` with `fill`),
  small solid swatches (e.g. 5×5 or 7×7 cells) before the colour name, the wand glow as cells in the
  glow colour (a dotted outer ring may suggest the aura; no alpha, no blur). The colour **name text
  stays** (in text ink) — the swatch is added, not swapped. Text and chrome never use true colours.
  Off/unlit LEDs stay a dim ring.
- The SETTINGS → APPEARANCE base colour chips each show a small swatch of their own colour (CUSTOM
  shows the stored RGB).
- Animation: band LEDs follow `BandEffectModel` exactly as `BandPreviewView` does (2.4 s loop, same
  per-zone colour function — move `ledColor` into a shared non-View helper both views call, returning
  RGB), including the buzz blink; the SCAN strip animates the same way. The wand plays the standard
  send pulse (two expanding rings, 0.42 s ease-out, the second 0.18 s later) in the glow colour and
  cycles colour on tap like `StarlightWandView`. Set `fb.wantsAnimation = true` while any of these is
  on screen.

## Theme setting and switching

- `VFDSettings.shared`: `theme` (`.standard` / `.vfd`, UserDefaults `MMUITheme` = "standard"/"vfd",
  default standard) and `base` (`MMVFDBase`, default "AMBER").
- `ContentView`: keep every existing modifier (relay poll timer, onChange hooks, requestedTab) and
  swap only the body content: VFD → `VFDRootView(tab: $tab)`, standard → today's layout.
  `.preferredColorScheme(.dark)` in VFD.
- Standard `SettingsScreen` gets an **APPEARANCE** section at the top: THEME picker (STANDARD / VFD)
  and, when VFD is chosen, the BASE COLOUR presets plus CUSTOM (system `ColorPicker`). The VFD SETTINGS
  screen draws APPEARANCE first exactly like `screens/settings.py`; THEME [STANDARD] switches back
  immediately.

## Screens

`enum VFD<Tab>Screen { static let title: String; static func headerRight(_ ctx: VFDContext) ->
(text: String, action: () -> Void)?; static func draw(_ ctx: VFDContext) -> Int? }` — `draw` lays out
from `L.contentTop` in content coordinates exactly like `screens/<tab>.py` (same widgets, rows,
proportional columns, wording, uppercase rules) but from **real app state**, and wires every control to
the same action the standard screen calls. Return the content end row (for scrolling). Lists show the
real data (all rows; only the visible ones need drawing — skip rows outside the clip cheaply). Things
the preview shows as hints only (swipe actions) work as swipes and are also in the HOLD menu. Empty
states, disabled states and error/alarm states come from the standard screen. A screen part that
cannot reasonably be drawn may open the standard UI through `ctx.sheet` — say so in the report.
