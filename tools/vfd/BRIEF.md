# VFD theme — preview stage brief

The look is specified in `.claude/skills/vfd-theme/SKILL.md` (read it in full; its **Look** section is
non-negotiable). This folder is the **preview stage** the spec asks for: the glyph font, a Python frame-buffer
renderer that mirrors the drawing API the Swift app will get, and preview PNGs of every MagicMaker tab in the
VFD look, made for the user to approve **before** anything in `ios/` changes. Nothing in `ios/` or `android/`
is edited at this stage.

Python 3 + Pillow (10.2) are installed. fontTools is not; TTF output is out of scope for now.
Never run anything with `pip install`. Generated images go to `tools/vfd/out/` (git-ignored).

## Devices (the two layouts every screen must work at)

| key | device | px | scale | pitch (px) | cols × rows | safe top | safe bottom |
|---|---|---|---|---|---|---|---|
| `pro` | iPhone 17 Pro | 1206 × 2622 | 3 | 5 | 241 × 524 | 62 pt → 38 rows | 34 pt → 21 rows |
| `x2` | iPhone 11 | 828 × 1792 | 2 | 4 | 207 × 448 | 48 pt → 24 rows | 34 pt → 17 rows |

cols = px_w // pitch, rows = px_h // pitch, safe rows = ceil(pt × scale / pitch). The safe-area rows stay empty
(unlit grid only). A lit cell is (pitch−1)×(pitch−1) px with a 1 px black gap; an unlit cell is the same square
in #090909; the background is #000. Grid origin is device pixel (0,0).

## Palette

Indices: 0 unlit, 1 highlight, 2 text, 3 dim, 4 alarm. AMBER preset = exactly #FFB014 / #FFE8C4 / #966428 /
#FF5028. Other bases: GREEN #3CFF6E, CYAN #30E8FF, BLUE #4CA0FF, RED #FF4030, WHITE #F0F0F0, or a custom RGB,
derived with the spec's formulas (highlight = base; dim = 0.59 × (0.85 × base + 0.15 × luma(base)) per channel,
luma = Rec. 709 0.2126 R + 0.7152 G + 0.0722 B; text = 0.75 × 255 + 0.25 × base per channel; alarm #FF5028;
red-ish base = hue within 25° of the alarm's hue → alarms drawn as inverted highlight blocks, 1 Hz blink; the
preview shows the "on" phase). Nothing in the app may use any other colour: packet colours (band LEDs, wand
colours) are shown as text (colour names / short codes) or patterns, never as their real RGB.

## Modules and their interfaces (each file has one owner; do not edit a file you do not own)

### `vfd_font.py` (font)
- `SMALL_SRC: dict[str, list[str]]` — the hand-made source: 9 strings of 5 chars each (`#` lit, `.` unlit);
  rows 0–6 are the glyph body, rows 7–8 the descender (blank except g j p q y µ, and comma/semicolon tails if
  wanted). Covers ASCII 32–126 plus ° µ Δ ± · × ÷ – — → ← … ✓ ² ³ Ω ≤ ≥ ≈ ‘ ’ “ ”. Original design.
- `scale2x(rows, w, h)` / `scale3x(rows, w, h)` — EPX/Scale2x and Scale3x on bit rows (bit 0 = leftmost).
- `SIZES = {"small": {w:5, h:9, ascent:7, advance:6, line:11}, "mid": {w:10, h:18, ascent:14, advance:12,
  line:20}, "big": {w:15, h:27, ascent:21, advance:18, line:29}}` (dict of dicts, string keys).
- `GLYPHS = {"small": {codepoint: [row ints]}, "mid": {...}, "big": {...}}` — rows top to bottom, bit 0 = leftmost
  pixel, `h` rows each.
- `glyph(ch, size) -> list[int]` — lowercase letters are real lowercase glyphs; an unknown character falls back to
  a hollow box glyph.
- `python3 tools/vfd/vfd_font.py --sheet OUT.png` renders every glyph at all three sizes (own PIL code).
- `tools/vfd/gen_swift.py OUT.swift` emits the Swift bitmaps: `enum VFDGlyphs { static let small: [UInt32: [UInt32]]
  = [...]; static let mid...; static let big...; }` plus the size metrics. Not added to the app yet.

### `vfd.py` (core renderer — mirrors the future Swift API, so keep it plain and portable)
- `Device` (the table above; `DEVICES = {"pro": ..., "x2": ...}`), `PRESETS`, `palette_for(base) -> list of 5 RGB
  tuples`, `alarm_inverted(base) -> bool`.
- `FrameBuffer(cols, rows)`: one byte per cell (palette index). Clip rectangle push/pop and a vertical origin
  offset for the scrolling content region. Whole-cell drawing only:
  `set(c, r, color)`, `fill(c, r, w, h, color)`, `hline(c, r, length, color, step=1)`, `vline(...)`,
  `box(c, r, w, h, color)`, `text(c, r, s, size="small", color=2) -> end_col` (r = top row of the glyph box),
  `text_right(right_c, r, s, size, color) -> start_col`, `text_fit(c, r, s, max_cols, size, color)` (truncates with
  `…`), `paragraph(c, r, s, max_cols, size, color, line=None) -> next_row` (word wrap),
  `inverted(c, r, s, size, pad=1, color=1) -> end_col` (solid block, the text cells left unlit),
  `led_bar(c, r, w, frac, color=1, track=3, marker=False)` (dotted dim track + lit zone or a 3×6 marker),
  `line_chart(c, r, w, h, values, color=1)` (single-cell line, dotted dim baseline),
  `tap(c, r, w, h, name)` (records a hit rectangle; unused by the PNG but kept for the Swift port).
- `render_png(fb, device, base, path)`.

### `widgets.py` (app chrome on top of `vfd.py`)
- `Layout(device)`: `cols`, `rows`, `left`/`right` margins, `content_top`/`content_bottom`, `x(frac)` for
  proportional columns, and the fixed rows of header, telemetry line and tab bar.
- `header(fb, L, title, back=False, right=None)`, `telemetry(fb, L, text)` (the existing TelemetryBar line,
  e.g. `MM/RF BLE:SCAN | RX:1284 | TX-AUTO:3 | SCAN:ON | LOG:REC | RELAY:LINK`), `tab_bar(fb, L, selected)` for the
  ten tabs SCAN TX WAND AUTO LINK LOGS MAP DIAG LAB SETTINGS (selected tab inverted), plus content widgets:
  `section(...)` (collapsible section header with a count), `toggle(...)` (pixel ON/OFF), `options(...)`
  (`[OPTION]` selectors, selected inverted), `stepper(...)` (`[-] value [+]`), `button(...)`, `slider(...)`
  (the app's SettingSlider: title, value text in the label row, −/+ and an LED bar), `field(...)` (boxed text
  field), `packet_row(...)` (label, hex truncated, subtitle, band tag), `status_line(...)`. Every widget returns
  the next free row (or end column) so screens stack them.
- `frame(fb, L, tab, title, telemetry_text)` draws the whole fixed chrome for one tab.

### `screens/<name>.py` (one per tab)
`draw(fb, L)` draws the content region from module-level mock data that looks like real use (real labels and hex
from `ios/MagicMaker/Core/` catalogs, plausible counts, addresses as the last 8 characters of a CoreBluetooth
UUID). `TITLE` and `TAB` constants. The content shown is the top of the screen (scroll offset 0).

### `render_previews.py`
Renders every screen × device (`pro`, `x2`) × base (`AMBER`, `CYAN`) into `tools/vfd/out/` as
`<tab>_<base>_<device>.png`, plus contact sheets `sheet_<base>_<device>.png` (all ten screens side by side at full
resolution, a few cells of black between them).

## What each screen shows

The real screens are `ios/MagicMaker/Views/<Name>Screen.swift` (ports of the Android tabs). A VFD screen keeps the
same sections, controls, labels and wording, in the same order, re-drawn on the grid. Things a grid cannot show
well are re-expressed, not dropped: colour dots → colour names/codes, the map → a pixel plot of capture points
and transmitter estimates with a scale/legend, the wand picture → pixel art, the band preview → a pixel band
with lit LED zones named by colour. Sliders become LED bars, switches become ON/OFF toggles, pickers become
`[OPTION]` rows, lists become rows of text with dim dividers, swipe actions are not drawn.

SETTINGS gains an **APPEARANCE** section (first section): THEME `[STANDARD] [VFD]` and, under it, BASE COLOUR
`[AMBER] [GREEN] [CYAN] [BLUE] [RED] [WHITE] [CUSTOM]` with the current one inverted.

## Layout rules

- Proportional columns (`L.x(0.62)` etc.) so every screen works at 241 and 207 columns; check both.
- Units go in the label row ("BURST MS"), never after values. Long text is truncated with `…` or wrapped; nothing
  overlaps, nothing is drawn off-grid or into the safe areas, header or tab bar.
- Small text for labels/body, mid for titles and secondary values, big for hero readouts (e.g. RX count).
- Highlight = live readings and selections; text = normal text; dim = labels, units, tracks, borders; alarm = errors.
