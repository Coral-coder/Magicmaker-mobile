# tools/vfd: VFD theme preview stage

This folder holds the preview stage of the "Amber VFD" theme: a vacuum-fluorescent dot-matrix look in which the
whole screen is one grid of identical cells. The spec is `.claude/skills/vfd-theme/SKILL.md`, and the module
interfaces are in `BRIEF.md`.

Everything here is Python and Pillow. It mirrors the drawing API that the Swift app will get, so screens can be
laid out and approved as PNGs before anything in `ios/` changes. Generated files go to `out/`, which git ignores.

| file | what it is |
|---|---|
| `vfd_font.py` | 5×7 bitmap font plus the Scale2x/Scale3x mid and big sizes (`--sheet OUT.png`, `--check`) |
| `gen_swift.py` | writes the glyph tables as Swift (`VFDGlyphs.swift`) |
| `vfd.py` | core renderer: devices, palette, `FrameBuffer` drawing primitives (`fb.base` = the base colour it is drawn in), `render_png` (`python vfd.py` runs a self-test) |
| `widgets.py` | app chrome (header, telemetry line, tab bar) and content widgets, built on `vfd.py` |
| `screens/<tab>.py` | one module per tab: `TAB`, `TITLE`, `draw(fb, L)` |
| `render_previews.py` | renders every screen × device × base colour, plus contact sheets |

## Rendering previews

Use `/usr/bin/python3`. The plain `python3` on PATH has no working Pillow; `render_previews.py` re-runs itself
under `/usr/bin/python3` if it needs to.

```
/usr/bin/python3 tools/vfd/render_previews.py                       # all screens, pro + x2, AMBER + CYAN, sheets
/usr/bin/python3 tools/vfd/render_previews.py --only scan --device pro --base AMBER
/usr/bin/python3 tools/vfd/render_previews.py --base RED,#FF8800    # any preset or #RRGGBB
/usr/bin/python3 tools/vfd/render_previews.py --scroll 300          # content scrolled down 300 rows
```

- Output files are `out/<tab>_<BASE>_<device>.png`; with `--scroll N` they end in `_s<N>`, so the scroll-0
  previews are never overwritten.
- Contact sheets are `out/sheet_<BASE>_<device>.png`: all screens side by side at full size. They are skipped
  when `--only` is used.
- `--only`, `--base` and `--device` can be repeated or given comma lists. `--screens DIR` renders another folder.
- The script prints a warning for anything lit in the safe-area rows, and for any content tap rectangle shorter
  than 15 rows.
- If a screen fails, its traceback is printed, the other screens still render, and the exit code is 1.

To view a preview, crop it at native resolution, because a full 1206×2622 image gets scaled down:

```
/usr/bin/python3 -c "from PIL import Image; Image.open('tools/vfd/out/scan_AMBER_pro.png').crop((0,180,1206,700)).save('tools/vfd/out/crops/x.png')"
```

## Screen modules (`screens/<tab>.py`)

```python
import widgets as W
from vfd import HIGHLIGHT, TEXT, DIM, ALARM

TAB = "scan"                 # tab key or label: scan tx wand auto link logs map diag lab settings
TITLE = "SCAN"               # header title (mid size)
# optional: BACK = True (shows "< BACK"), HEADER_RIGHT = "REC" or ("BT OFF", ALARM),
#           HEADER_RIGHT_TAP = "refresh" (makes HEADER_RIGHT a text button; no tap while it is DIM),
#           TELEMETRY = "MM/RF ..." (leave it out: every tab shares DEFAULT_TELEMETRY)

def draw(fb, L):
    c, w = L.left, L.width
    y = L.content_top
    y = W.section(fb, L, c, y, w, "LIVE RX", count=12, collapsed=False)
    y = W.toggle(fb, L, c, y, w, "LOOP", True)
    return y                 # optional: the content end; a scroll indicator is drawn when it overflows
```

- `render_previews.py` calls `W.frame(...)` first. That draws the chrome and leaves the content region clipped.
  Draw from `L.content_top` down; anything past `L.content_bottom` is clipped, as it is under a scroll.
- The content clip is **snapped**: `draw()` runs once on a scratch buffer, and `W.snapped_window()` narrows the
  clip so a line of text crossing the top or bottom edge is hidden instead of cut mid-glyph, and a lone row
  divider never sits within 5 rows of the header rule or the tab-bar rule. Taps of hidden controls are
  dropped. The Swift renderer must do the same. Screens that pin rows and scroll their own list (TX, WAND,
  LOGS, SCAN, LAB, MAP) snap their windows themselves with the same helper (SCAN with an edge-aware copy).
- `draw()` may therefore run twice per render; keep it free of side effects.
- **Telemetry:** one mock app state for the whole app, so the line is `DEFAULT_TELEMETRY` on every tab
  (`MM/RF BLE:SCAN | RX:1284 | TX-AUTO:3 | SCAN:ON | AUTO:ARM | LOG:REC | TX:LOOP | RELAY:LINK | LIGHTS:37 |
  REPLAY:214/2433`, in TelemetryBar's order). SCAN builds the same line from its state with `telemetry_line()`.
- The `sys.path` already holds `tools/vfd`, so `import vfd` and `import widgets` just work.
- Columns:
  - Use `L.left`, `L.width` and `L.right` (inclusive).
  - For proportional columns use `L.x(0.62)`; for n equal columns use `L.split(n, gap=6)`.
  - Check every screen at both widths: `pro` is 241 columns (235 usable) and `x2` is 207 (201 usable).
- Put units in the label ("BURST MS"). Long text is truncated with … by the widgets.

## Layout and rhythm (`L = W.Layout(device)`)

**Chrome**, top to bottom:

1. Safe-area rows (empty).
2. Header: optional `< BACK`, the title in mid highlight, optional right-aligned status.
3. Telemetry line: small and dim. The ` | ` separators are drawn as a tall 1-cell bar, and the line is truncated
   with ….
4. Dim rule.
5. Content region: rows `L.content_top` to `L.content_bottom - 1`.
   - pro: rows 72..467 (396 rows)
   - x2: rows 58..395 (338 rows)
6. Dim rule.
7. Tab bar: two rows of five equal cells.
   - Labels are centred. The selected tab is a solid highlight block with its label cut out; the others are dim,
     with 1-cell dim separators.
   - SETTINGS (47 cells) does not fit a cell (46 on pro, 39 on x2), so it shows as **SETUP**. This is a
     deliberate re-expression of the iOS "Settings" tab label; the header title still reads SETTINGS.
8. Safe-area rows (empty).

**Margins:** 3 empty columns on each side.

**Vertical rhythm.** Widgets add these gaps themselves; none are added at `L.content_top`.

- Every control row (toggle, options, stepper, button, slider controls) is `CTRL_H` = 13 rows tall, with its
  caps at +3. A text field box is `FIELD_H` = 14 rows (caps still at +3) so descenders keep an unlit row above
  its bottom border.
- Each widget leaves `GAP` = 2 rows after itself, so plain control rows repeat every 15 rows.
- A widget that starts with a label line first adds `GROUP_GAP` = 3 rows. That gives 5 empty rows above the
  label and 3 between the label and its control. These widgets are `options`/`field` with a label, `slider`,
  `meter`, `chart`, `hero` and `label`.
- `section()` leaves 8 rows of air above itself and 3 rows under its rule.
- Text lines (`status_line`, `kv`, `text_block`) repeat every `LINE` = 11 rows.

**Tap targets:**

- Every control registers `fb.tap(...)` at least 15 rows tall: 25 pt on 3x, 30 pt on 2x. The tap rectangle is
  padded into the gaps; the control is not drawn bigger. A control right at the content top or bottom gets its
  padded rectangle moved inside the clip rather than cut. Controls stack every 15 rows, so 15 is the most the
  previews can give; the Swift port should grow taps toward 44 pt wherever the gaps allow.
- `[OPTION]` grids (`columns=n`) already tap the whole column cell.
- Tap names are `toggle:LABEL`, `option:LABEL:ITEM`, `stepper:LABEL:-`/`:+`, `slider:TITLE:-`/`:+`/`:bar`,
  `button:LABEL`, `field:LABEL`, `packet:LABEL`, `section:TITLE`, `tab:<key>` and `back`.

**Colours** (iOS → VFD: `MMTheme.cyan` → HIGHLIGHT, `textPrimary` → TEXT, `textDim`/`cyanDim` → DIM,
`MMTheme.error` and TxEngine's warning statuses → ALARM):

- `HIGHLIGHT`: live values, selections, button borders and section titles. Live RX hex (SCAN, LINK's Android
  feed) is highlight; stored hex (TX library, LOGS rows: PacketRow's `cyanDim`) is dim (`hex_color=DIM`).
- `TEXT`: normal text and every bordered button's label.
- `DIM`: labels, units, tracks, borders and fold chevrons.
- `ALARM`: errors and destructive buttons (`button(..., alarm=True)`: DELETE, CLEAR). Widgets draw alarms with
  `alarm_text`, which becomes a 10-row inverted block on a red-ish base (so alarms on consecutive lines keep a
  1-row gap).

**Fold headers** (`section(collapsed=...)`, SCAN's HIDE SCAN CONTROLS, TX's HIDE TX LOOP, SETTINGS'
TRANSMISSION SETTINGS, LAB's inspector): dim chevron, highlight title.

**Pickers** are `[OPTION]` rows (WAND's STARLIGHT / NEW WAND included); SectionFilterMenu is `menu_button`
(CLASS 8/8 ▾) on SCAN, TX and LINK alike.

**Wrapping:** `vfd.wrap_text` (and so `paragraph`, `text_block`, slider hints) never starts or ends a line with a
lone `·` (the break replaces it) and keeps a lone dash at the end of the line before the break. A U+00A0
no-break space never breaks and is drawn as a space. Gesture hints wrap at their ` · ` separators with
`token_lines`, the separator dropped at the break.

**Case:** labels, titles, buttons, options, status lines and packet labels are uppercased for you, as the app's
`.uppercased()` calls do. µ is kept as µ. Values, hex, field contents and hints are drawn exactly as given.

## Widgets (`widgets.py`)

Content widgets take `(fb, L, c, r, w, ...)`: the left column, the top row and the available width. They return
the **next free row**, with the standard gap already included.

| widget | what it draws |
|---|---|
| `frame(fb, L, tab, title, telemetry_text, back=False, right=None, scroll=0, right_tap=None)` | Whole chrome. Leaves the content clip pushed (`end_frame(fb)` pops it). |
| `header(fb, L, title, back=False, right=None, right_tap=None)` | `< BACK`, the mid title (truncated) and the right status (`str` or `(text, colour)`); `right_tap` makes it a text button. |
| `telemetry(fb, L, text)` | The TelemetryBar line plus the rule under it. |
| `tab_bar(fb, L, selected)` | The 2×5 pixel tab bar, with the selected tab inverted. |
| `scrollbar(fb, L, content_end, scroll=0)` | Dotted track and thumb in the last column, shown only when content overflows. |
| `section(..., title, count=None, collapsed=None, right=None)` | Section header: chevron (if `collapsed` is not None), highlight title, `012` count or right text, dim rule. |
| `label(..., s, color=DIM)` | Dim label line above a control (adds the group gap). |
| `text_block(..., s, color=TEXT, upper=False)` | Word-wrapped text (hints and notes, where `\n` breaks a line). |
| `status_line(..., s, color=DIM, banner=False)` | One truncated status line. `color=ALARM` draws an alarm; `banner=True` draws a full-width inverted block. |
| `kv(..., key, value, color=HIGHLIGHT)` | Dim key, right-aligned value and a dotted leader between them. |
| `hero(..., key, value, size="big", sub=None)` | Dim label and a big (or mid) highlight readout, with optional small sub-text. |
| `meter(..., title, value_text, frac, zone=None, marker=False)` | Read-only LED bar, with the label and value on the row above. |
| `slider(..., title, value_text, frac, hint=None, can_dec=None, can_inc=None)` | SettingSlider: title and value row, then `[-]` LED bar `[+]` (− disabled at the minimum, + at the maximum), then an optional dim hint. |
| `toggle(..., label, on, enabled=True, label_color=TEXT)` | Label plus a pixel ON/OFF switch, right-aligned (45 cells). |
| `options(..., items, selected, label_text=None, columns=None)` | `[OPTION]` selectors with the selected one inverted. They wrap; `columns=n` gives an equal grid; `selected` may be a set (chips). |
| `stepper(..., label, value, can_dec=True, can_inc=True, value_chars=None)` | Label plus a right-aligned `[-] value [+]`. |
| `button(..., label, primary=False, enabled=True, alarm=False)` | Bordered button, a solid primary one, or a destructive one in alarm colour. `w=None` sizes it to the label. |
| `buttons(..., labels, primary=None, enabled=None, equal=True, alarm=None)` | A row of buttons: equal cells, or sized to their labels. |
| `field(..., label, value, placeholder="", focused=False, value_color=TEXT)` | Optional label plus a boxed text field, `FIELD_H` tall (cursor when focused). |
| `packet_row(..., label, hex, subtitle="", tag=None, selected=False, right=None, hex_color=HIGHLIGHT)` | PacketRow. See the note below the table. |
| `chart(..., h, title, values, value_text=None)` | Label row plus a framed single-cell line chart. |
| `divider(..., dotted=True)` | 1-row dim divider. |
| `panel(..., h, title=None)` / `panel_inner(c, r, w, title)` | 1-cell dim box with an optional title set into the top border. Draw the content at `panel_inner(...)` first, then `panel(..., h=end - r + 1)`. |
| `badge(fb, c, r, s, color)` / `tag_box(fb, c, r, s)` / `alarm_text(fb, c, r, s)` | Inline pieces: an inverted block 2 cells around the caps, a boxed tag, and alarm text. |
| `chevron(fb, c, r, collapsed)` / `chevron_up(fb, c, r)` / `step_button(fb, c, r, plus)` | Pixel icons: the section chevron (right / down), the up chevron of open "HIDE …" panels, and a 13×13 `[-]`/`[+]`. |
| `menu_button(fb, L, x, y, label)` | SectionFilterMenu: a button with a down chevron after the label. Returns the end column. |
| `led(fb, x, y, kind, size)` | A round band LED / legend swatch with fill pattern `kind` (SCAN's LAST LIGHTS and LAB's band preview). |
| `snapped_window(fb, top, bottom, draw_fn)` / `list_scrollbar(fb, top, h, total, scroll)` | A list scrolling under pinned rows: the window rows that cut no line, and its own scroll indicator. |
| `token_lines(text, max_cols)` / `interval_slider(...)` | Wrap an "A · B · C" line between tokens; TxIntervalSlider (TX and WAND). |
| `upper(s)` / `cx(c, w, s)` / `tap(fb, c, r, w, h, name)` | Public helpers: display uppercase (µ kept), centring column, padded tap. |

**`packet_row`:**

- First line: the label. A selected row shows the label as an inverted block. A tag (for example BAND) sits in a
  dim box after the label, and an optional dim note (age or RSSI) is right-aligned.
- Second line: the hex, truncated with …: highlight for live RX, `hex_color=DIM` for stored library or log rows.
- Third line: the subtitle in dim.
- A dotted divider closes the row. Rows stack directly.

**`Layout` also provides:**

- `L.x(frac)`, `L.split(n, gap, c, w)`
- `L.tab_cell(i)`, `L.tab_label(key)`
- `L.title_row`, `L.header_text_row`, `L.telemetry_row`, `L.header_rule`, `L.tab_rule`, `L.tab_rows`

**Module constants:** `TABS`, `TAB_SHORT`, `MARGIN`, `CTRL_H`, `FIELD_H`, `GAP`, `LINE`, `LABEL_H`,
`GROUP_GAP`, `SECTION_GAP`, `TAP_ROWS`, `STEP_W`, `SWITCH_W`, `N_PATTERNS`.

**Practical limits at x2 (201 columns):**

- A full-width small line holds 33 characters.
- A mid title holds 16 characters, or 13 with `< BACK`.
- Three equal buttons give each label about 10 characters before it is cut with ….
