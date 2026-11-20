#!/usr/bin/env python3
"""VFD app chrome and content widgets, drawn on a vfd.FrameBuffer in whole cells.

Screen layout (top to bottom, see Layout):
    safe-area rows (empty) | header: "< BACK", TITLE (mid), right status | telemetry line (small, dim)
    | dim rule | scrolling content region | dim rule | tab bar (2 rows x 5 cells) | safe-area rows (empty)

Conventions (the Swift port keeps the same call sites):
    * Content widgets take (fb, L, c, r, w, ...): left column, top row and available width in cells, and
      return the NEXT FREE ROW, already including the standard gap below the widget, so a screen stacks
      them:  y = toggle(fb, L, L.left, y, L.width, "LOOP", True)
    * Vertical rhythm:
        - every control row (toggle, options, stepper, button, slider controls) is CTRL_H = 13
          rows tall with its caps at +3; widgets leave GAP = 2 rows after themselves, so plain control
          rows repeat every 15 rows;
        - a widget that starts with a label line (options/field with a label, slider, meter, chart,
          hero, label()) first adds GROUP_GAP = 3 rows, so the label sits with its control (5 empty rows
          above it, 3 below);
        - section() leaves SECTION_GAP = 8 rows of air above itself and 3 under its rule;
        - text lines (status_line, kv, text_block) repeat every LINE = 11 rows.
      None of these extra gaps are added at L.content_top.
    * Tap rectangles: every control registers fb.tap(...) at least TAP_ROWS (15) rows tall (25 pt on 3x,
      30 pt on 2x), padded into the surrounding gap rather than drawn bigger.
    * Colours: HIGHLIGHT live values / selections / buttons, TEXT normal text, DIM labels, units, tracks,
      borders, ALARM errors (drawn with alarm_text() so red-ish bases get an inverted block instead).
    * Inverted = solid block with the text cells left unlit (selected tab, selected option, banners,
      ON/OFF state, primary button, selected packet label): 2 cells of block around the caps.
    * Labels, titles, buttons, options, status lines and packet labels are uppercased (as the app's
      .uppercased() calls do); values, hex, field contents and hints are drawn as given.
"""

import os
import sys

try:
    import vfd
except ImportError:  # imported from elsewhere (e.g. a screen module run directly)
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import vfd

from vfd import UNLIT, HIGHLIGHT, TEXT, DIM, ALARM, text_width, fit_text

# ---------------------------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------------------------

#: The ten tabs in app order: (key, label). Keys are ContentView.MainTab raw values.
TABS = [
    ("scan", "SCAN"), ("tx", "TX"), ("wand", "WAND"), ("auto", "AUTO"), ("link", "LINK"),
    ("logs", "LOGS"), ("map", "MAP"), ("diag", "DIAG"), ("lab", "LAB"), ("settings", "SETTINGS"),
]
#: Short forms used when a label does not fit its tab cell (SETTINGS = 47 cells > 46 / 39).
TAB_SHORT = {"settings": "SETUP"}
TAB_COLS = 5

MARGIN = 3          # empty columns at the left and right screen edges
CTRL_H = 13         # height of every control row
CTRL_TEXT = 3       # caps offset inside a control row
FIELD_H = 14        # a text field box: CTRL_H + 1 so descenders (g j p q y) keep an unlit row
                    # above the bottom border; caps still at +CTRL_TEXT
GAP = 2             # rows between stacked widgets
LINE = 11           # small text line pitch (caps 7 + 4)
LABEL_H = 10        # a small label line sitting above a control (caps 7 + 3)
GROUP_GAP = 3       # extra rows above a widget that starts with a label line
SECTION_GAP = 8     # rows of air above a section header
SECTION_H = 11      # section header: caps 7, 2 rows, 1-row rule, + 1
TAP_ROWS = 15       # minimum tap height in rows (>= 24 pt at 3x)
STEP_W = 13         # [-] / [+] step button: 13 x 13 cells
OPT_GAP = 4         # columns between [OPTION] items
TAB_H = 13          # one tab-bar row
SWITCH_W = 45       # ON/OFF switch width

_ADV = 6            # small text advance


def _upper(s):
    """Uppercase for display, keeping characters whose uppercase the font lacks (µ stays µ, not
    Greek capital mu)."""
    if s is None:
        return ""
    out = []
    for ch in str(s):
        u = ch.upper()
        out.append(u if len(u) == 1 and ch != "µ" else ch)
    return "".join(out)


upper = _upper      # public names for screens (the Swift port has one helper each)


def _group_top(L, r):
    """Row where a labelled widget starts: GROUP_GAP rows lower unless it opens the content."""
    return r + GROUP_GAP if r > L.content_top else r


def _cx(c, w, s, size="small"):
    """Column that centres s (ink) in [c, c + w)."""
    return c + (w - text_width(s, size)) // 2


cx = _cx


def _tap(fb, c, r, w, h, name, min_h=TAP_ROWS):
    """Tap rectangle at least min_h rows tall, grown evenly above and below the visual. When the
    padding would reach past the current clip (a control right at the top or bottom of the content
    region) the rectangle is moved inside it instead of being cut, so it keeps its full height."""
    if not name:
        return
    if h < min_h:
        vis_top, vis_bot = r, r + h
        r -= (min_h - h) // 2
        h = min_h
        oy = fb.origin_y
        _, r0, _, ch = fb.clip_rect
        r1 = r0 + ch
        if r0 <= vis_top + oy and vis_bot + oy <= r1 and h <= ch:   # the control itself is inside
            if r + oy < r0:
                r = r0 - oy
            elif r + h + oy > r1:
                r = r1 - oy - h
    fb.tap(c, r, w, h, name)


tap = _tap


def badge(fb, c, r, s, color=HIGHLIGHT):
    """Inverted text: a solid block 2 cells around the caps (cols c-2 .. c+ink+1, rows r-2 .. r+8)
    with the text cut out, the text where text(c, r, s) would put it. Returns the column after the
    block. Use it for uppercase text (descenders would touch the block edge)."""
    tw = text_width(s)
    if not tw:
        return c
    fb.fill(c - 2, r - 2, tw + 4, 11, color)
    fb.text(c, r, s, "small", UNLIT)
    return c + tw + 2


def alarm_text(fb, c, r, s, right=False):
    """Alarm text (ALARM colour); on a red-ish base (fb.alarm_inverted) an inverted highlight
    block instead (1 row above the caps, 2 below, 2 cells each side: 10 rows, so alarms on
    consecutive LINE-pitch lines keep a 1-row gap), nudged 2 cells inward so the block stays inside
    [c, ...]. right=True: c is the inclusive last column (the text or block ends there). Returns the
    column after it."""
    tw = text_width(s)
    if not tw:
        return c
    if right:
        c = c - tw + 1 - (2 if fb.alarm_inverted else 0)
    if fb.alarm_inverted:
        x = c + (0 if right else 2)
        fb.fill(x - 2, r - 1, tw + 4, 10, HIGHLIGHT)
        fb.text(x, r, s, "small", UNLIT)
        return x + tw + 2
    return fb.text(c, r, s, "small", ALARM) - 1


def tag_box(fb, c, r, s, color=DIM, text_color=TEXT):
    """A boxed tag (BAND, NEW): a 1-cell dim box 2 cells around the caps, same footprint as
    badge(), the text in text colour. Returns the column after the box."""
    s = _upper(s)
    tw = text_width(s)
    if not tw:
        return c
    fb.box(c - 2, r - 2, tw + 4, 11, color)
    fb.text(c, r, s, "small", text_color)
    return c + tw + 2


def chevron(fb, c, r, collapsed, color=DIM):
    """Section chevron next to small caps at row r: a 4 x 7 right-pointing triangle (cols c+1..c+4)
    when collapsed, a 7 x 4 down-pointing one (cols c..c+6, rows r+1..r+4) when open."""
    for i in range(4):
        if collapsed:
            fb.vline(c + 1 + i, r + i, 7 - 2 * i, color)
        else:
            fb.hline(c + i, r + 1 + i, 7 - 2 * i, color)


def chevron_up(fb, c, r, color=DIM):
    """7 x 4 up-pointing chevron next to small caps at row r (rows r+1..r+4), the mirror of
    chevron(collapsed=False): the "HIDE ..." headers of open control panels."""
    for i in range(4):
        fb.hline(c + 3 - i, r + 1 + i, 1 + 2 * i, color)


def step_button(fb, c, r, plus, enabled=True, name=None):
    """A 13 x 13 [-] or [+] button with its top-left at (c, r): highlight border (dim when
    disabled) and a 5-cell minus / plus in text colour. Registers the tap when name is given."""
    border = HIGHLIGHT if enabled else DIM
    icon = TEXT if enabled else DIM
    fb.box(c, r, STEP_W, CTRL_H, border)
    mid_c, mid_r = c + STEP_W // 2, r + CTRL_H // 2
    fb.hline(mid_c - 2, mid_r, 5, icon)
    if plus:
        fb.vline(mid_c, mid_r - 2, 5, icon)
    if enabled:
        _tap(fb, c - 1, r, STEP_W + 2, CTRL_H, name)


# ---------------------------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------------------------

class Layout:
    """Fixed rows and columns of the VFD screen for one device.

    Columns: left / right are the first / last content columns (inclusive), width = right - left + 1.
    x(frac) = left + round(frac * width) gives proportional columns (x(1.0) = right + 1);
    split(n) gives n equal columns.
    Rows: safe_top = first drawable row, safe_end = first row of the bottom safe area.
    header_top / title_row (mid title caps) / header_text_row (small text centred on the title caps),
    telemetry_row, header_rule, content_top .. content_bottom (exclusive; content_h rows), tab_rule,
    tab_rows = (top row of tab row 1, top row of tab row 2).
    """

    def __init__(self, device):
        d = device
        self.device = d
        self.cols, self.rows = d.cols, d.rows
        self.safe_top = d.safe_top
        self.safe_end = d.rows - d.safe_bottom
        self.left = MARGIN
        self.right = d.cols - 1 - MARGIN
        self.width = self.right - self.left + 1
        self.tap_rows = TAP_ROWS

        # header: title caps 14 rows, small text centred on them, telemetry, rule
        self.header_top = self.safe_top + 2
        self.title_row = self.header_top
        self.header_text_row = self.header_top + 4
        self.telemetry_row = self.header_top + 14 + 4
        self.header_rule = self.telemetry_row + 7 + 3
        self.content_top = self.header_rule + 4

        # tab bar: two rows of five cells, 1 spare row between them, 2 rows above the safe area
        self.tab_h = TAB_H
        row2 = self.safe_end - 2 - TAB_H
        row1 = row2 - TAB_H - 1
        self.tab_rows = (row1, row2)
        self.tab_rule = row1 - 3
        self.content_bottom = self.tab_rule - 3
        self.content_h = self.content_bottom - self.content_top

        self.tab_cell_w = (self.width - (TAB_COLS - 1)) // TAB_COLS
        used = self.tab_cell_w * TAB_COLS + (TAB_COLS - 1)
        self.tab_left = self.left + (self.width - used) // 2

    def x(self, frac):
        """Proportional column: left + round(frac * width)."""
        return self.left + vfd._round(frac * self.width)

    def split(self, n, gap=6, c=None, w=None):
        """n equal columns across [c, c + w) (default the full content width) separated by gap
        cells: a list of (c, w). Spare cells go to the last column."""
        c = self.left if c is None else c
        w = self.width if w is None else w
        cw = (w - gap * (n - 1)) // n
        out = []
        for i in range(n):
            ci = c + i * (cw + gap)
            out.append((ci, (c + w - ci) if i == n - 1 else cw))
        return out

    def tab_cell(self, index):
        """(c, r, w, h) of tab cell `index` (0..9)."""
        row, col = divmod(index, TAB_COLS)
        c = self.tab_left + col * (self.tab_cell_w + 1)
        return c, self.tab_rows[row], self.tab_cell_w, self.tab_h

    def tab_label(self, key):
        """Label for a tab key, or its short form when it does not fit the cell with 2 cells of
        padding on each side."""
        lab = dict(TABS)[key]
        if text_width(lab) + 4 > self.tab_cell_w and key in TAB_SHORT:
            return TAB_SHORT[key]
        return lab

    def __repr__(self):
        return ("Layout(%s cols %d..%d content rows %d..%d tabs %s)"
                % (self.device.key, self.left, self.right, self.content_top, self.content_bottom - 1,
                   self.tab_rows))


def tab_key(tab):
    """Normalise a TAB constant ("SCAN", "scan", "Settings", "SETUP") to its key."""
    t = str(tab).strip().lower()
    for key, lab in TABS:
        if t == key or t == lab.lower():
            return key
    for key, short in TAB_SHORT.items():
        if t == short.lower():
            return key
    raise ValueError("unknown tab %r" % (tab,))


# ---------------------------------------------------------------------------------------------
# Chrome
# ---------------------------------------------------------------------------------------------

def header(fb, L, title, back=False, right=None, right_tap=None):
    """Header band: optional "< BACK" (small, highlight) on the left, the title in mid highlight
    (truncated with …), an optional right-aligned short status (small; a string, or (text, colour
    index); ALARM uses alarm_text). right_tap: a tap name that makes the right text a text button
    (e.g. REFRESH), its tap covering the text plus the margin to the screen edge, as tall as the
    "< BACK" tap. Returns L.telemetry_row."""
    x = L.left
    small_r = L.header_text_row
    if back:
        end = fb.text(x, small_r, "< BACK", "small", HIGHLIGHT)
        _tap(fb, 0, L.header_top - 1, end + 3, 16, "back")
        x = end + 6
    limit = L.right
    if right:
        text, color = (right if isinstance(right, tuple) else (right, HIGHLIGHT))
        text = fit_text(_upper(text), L.width // 2)
        start = L.right - text_width(text) + 1
        if color == ALARM:
            start = L.right - text_width(text) + 1 - (2 if fb.alarm_inverted else 0)
            alarm_text(fb, L.right, small_r, text, right=True)
        else:
            fb.text(start, small_r, text, "small", color)
        if right_tap and color != DIM:          # a dim right text is a disabled button
            fb.tap(start - 3, L.header_top - 1, fb.cols - start + 3, 16, right_tap)
        limit = start - 8
    fb.text_fit(x, L.title_row, _upper(title), limit - x + 1, "mid", HIGHLIGHT)
    return L.telemetry_row


def telemetry(fb, L, text):
    """The TelemetryBar line: small dim text; the " | " separators are drawn as a compact 1-cell
    bar (4 empty cells each side, 9 rows tall) so more tokens fit; truncated with … at the right margin. Then
    the dim header rule. Returns L.content_top."""
    r = L.telemetry_row
    tokens = [t for t in _upper(text).split(" | ") if t]
    x = L.left
    limit = L.right + 1                 # exclusive
    for i, tok in enumerate(tokens):
        if i:
            bar = x + 3                 # x is the column after the previous advance (1 gap col)
            nxt = bar + 5               # 4 empty cells each side of the bar
            if nxt + text_width(tok[:1] + "…") > limit:
                if x + text_width("…") <= limit:
                    fb.text(x, r, "…", "small", DIM)
                break
            fb.vline(bar, r - 1, 9, DIM)    # taller than the caps: reads as a divider, not "I"
            x = nxt
        if x + text_width(tok) <= limit:
            x = fb.text(x, r, tok, "small", DIM)
        else:
            fb.text_fit(x, r, tok, limit - x, "small", DIM)
            break
    fb.hline(L.left, L.header_rule, L.width, DIM)
    return L.content_top


def tab_bar(fb, L, selected):
    """Pixel tab bar: a dim rule, then two rows of five equal cells, labels centred, the selected
    tab a solid highlight block (inset 1 cell from the separators) with its label cut out, the
    others dim, 1-cell dim separators between cells. Each cell is a tap "tab:<key>"."""
    sel = tab_key(selected)
    fb.hline(L.left, L.tab_rule, L.width, DIM)
    for i, (key, _) in enumerate(TABS):
        c, r, w, h = L.tab_cell(i)
        lab = L.tab_label(key)
        tx = _cx(c, w, lab)
        if key == sel:
            fb.fill(c + 1, r, w - 2, h, HIGHLIGHT)
            fb.text(tx, r + CTRL_TEXT, lab, "small", UNLIT)
        else:
            fb.text(tx, r + CTRL_TEXT, lab, "small", DIM)
        if i % TAB_COLS != TAB_COLS - 1:
            fb.vline(c + w, r + 2, h - 4, DIM)
        if i < TAB_COLS:                # row 1: 2 rows above it .. the spare row below it (16)
            fb.tap(c, r - 2, w + 1, h + 3, "tab:" + key)
        else:                           # row 2: down to the last drawable row (15)
            fb.tap(c, r, w + 1, h + 2, "tab:" + key)


def frame(fb, L, tab, title, telemetry_text, back=False, right=None, scroll=0, right_tap=None):
    """Whole fixed chrome for one tab (header, telemetry line + rule, tab bar), drawn inside the
    drawable rows only. Leaves the content clip pushed: (0, content_top, cols, content_h) with
    dy = -scroll, so the screen draws at its own rows from L.content_top; call end_frame(fb) (or
    fb.pop_clip()) when the content is done."""
    fb.push_clip(0, L.safe_top, fb.cols, L.safe_end - L.safe_top)
    header(fb, L, title, back=back, right=right, right_tap=right_tap)
    telemetry(fb, L, telemetry_text)
    tab_bar(fb, L, tab)
    fb.pop_clip()
    fb.push_clip(0, L.content_top, fb.cols, L.content_h, dy=-scroll)


def end_frame(fb):
    """Pop the content clip that frame() left set."""
    fb.pop_clip()


def scrollbar(fb, L, content_end, scroll=0):
    """Scroll indicator in the last screen column, only when the content (ending at row
    content_end, exclusive, in content coordinates) is taller than the region: a dotted dim track
    and a solid dim thumb. Draw it after end_frame()."""
    total = content_end - L.content_top
    view = L.content_h
    if total <= view:
        return
    col = fb.cols - 1
    top, h = L.content_top, L.content_h
    fb.vline(col, top, h, DIM, step=2)
    th = max(6, h * view // total)
    ty = top + (h - th) * max(0, min(scroll, total - view)) // max(1, total - view)
    fb.vline(col, ty, th, DIM)


# ---------------------------------------------------------------------------------------------
# Content widgets: (fb, L, c, r, w, ...) -> next free row
# ---------------------------------------------------------------------------------------------

def section(fb, L, c, r, w, title, count=None, collapsed=None, right=None, name=None):
    """Section header (MMListSectionHeader / MMSectionTitle): [chevron] TITLE in small highlight,
    an optional right-aligned count (an int is shown as 3 digits) or right text in dim, and a solid
    dim rule under it. collapsed=None draws no chevron (a plain section title); True/False draws a
    right/down chevron and makes the whole line a tap "section:<TITLE>". Leaves SECTION_GAP rows
    of air above itself (not at the top of the content). Returns the next free row."""
    if r > L.content_top:
        r += SECTION_GAP - GAP
    x = c
    if collapsed is not None:
        chevron(fb, x, r, collapsed, DIM)
        x += 11
    rt = None
    if count is not None:
        rt = "%03d" % count if isinstance(count, int) else str(count)
    elif right:
        rt = _upper(right)
    limit = c + w
    if rt:
        rt = fit_text(rt, w // 2)
        start = c + w - text_width(rt)
        fb.text(start, r, rt, "small", DIM)
        limit = start - 6
    fb.text_fit(x, r, _upper(title), limit - x, "small", HIGHLIGHT)
    fb.hline(c, r + 9, w, DIM)
    if collapsed is not None:
        _tap(fb, c, r - 3, w, 14, name or "section:" + _upper(title))
    return r + SECTION_H + GAP


def label(fb, L, c, r, w, s, color=DIM, group=True):
    """One small label line (dim, uppercased, truncated) introducing the control under it.
    group=True first adds GROUP_GAP rows (not at the top of the content) so the label sits with its
    control. Returns the row for the control (label row + LABEL_H)."""
    if group:
        r = _group_top(L, r)
    fb.text_fit(c, r, _upper(s), w, "small", color)
    return r + LABEL_H


def text_block(fb, L, c, r, w, s, color=TEXT, upper=False):
    """Word-wrapped small text (hints, notes; '\\n' breaks lines), drawn as given unless
    upper=True. Returns the next free row."""
    nxt = fb.paragraph(c, r, _upper(s) if upper else s, w, "small", color, LINE)
    return nxt + GAP if nxt > r else r


def status_line(fb, L, c, r, w, s, color=DIM, banner=False, name=None):
    """StatusLine: one line of small uppercase text truncated with …. color=ALARM draws an alarm
    (an inverted block on a red-ish base). banner=True: a full-width solid block (highlight, or the
    given colour if it is not DIM/TEXT) with the text cut out, for status banners. Returns the next
    free row."""
    s = _upper(s)
    if banner:
        bc = HIGHLIGHT if color in (DIM, TEXT) else color
        fb.fill(c, r, w, 11, bc)
        fb.text_fit(c + 3, r + 2, s, w - 6, "small", UNLIT)
        if name:
            _tap(fb, c, r, w, 11, name)
        return r + 11 + GAP
    if color == ALARM:
        alarm_text(fb, c, r, fit_text(s, w - 4))
    else:
        fb.text_fit(c, r, s, w, "small", color)
    if name:
        _tap(fb, c, r - 2, w, 11, name)
    return r + LINE


def kv(fb, L, c, r, w, key, value, color=HIGHLIGHT, leader=True):
    """Key / value line: key in dim on the left, value right-aligned (highlight by default; ALARM
    via alarm_text) and truncated so they never collide, a dotted dim leader between them. Returns
    r + LINE."""
    key = _upper(key)
    value = "" if value is None else str(value)
    kw = text_width(key)
    value = fit_text(value, max(0, w - kw - 6))
    vw = text_width(value)
    fb.text_fit(c, r, key, w, "small", DIM)
    if value:
        start = c + w - vw
        if color == ALARM:
            start = c + w - vw - (2 if fb.alarm_inverted else 0)
            alarm_text(fb, c + w - 1, r, value, right=True)
        else:
            fb.text(start, r, value, "small", color)
        if leader:
            a, b = c + kw + 3, start - 3
            a += (a - c) % 2          # dots on even offsets so stacked leaders line up
            if b > a:
                fb.hline(a, r + 6, b - a, DIM, step=2)
    return r + LINE


def hero(fb, L, c, r, w, key, value, size="big", color=HIGHLIGHT, sub=None):
    """Big readout (e.g. RX count): a dim label line, then the value in big (or mid) highlight,
    optional small dim sub-text after the value on its baseline. Side-by-side heroes given the same
    r stay aligned. Returns the next free row."""
    r = _group_top(L, r)
    fb.text_fit(c, r, _upper(key), w, "small", DIM)
    m = vfd.metrics(size)
    vr = r + LABEL_H + 1
    end = fb.text_fit(c, vr, str(value), w, size, color)
    if sub:
        sx = end + 4
        if sx < c + w:
            fb.text_fit(sx, vr + m["ascent"] - 7, _upper(sub), c + w - sx, "small", DIM)
    return vr + m["ascent"] + 3 + GAP


def divider(fb, L, c, r, w, dotted=True, color=DIM):
    """A 1-row dim divider (dotted by default). Returns r + 1 + GAP."""
    fb.hline(c, r, w, color, step=2 if dotted else 1)
    return r + 1 + GAP


def panel_inner(c, r, w, title=True):
    """(c, r, w) of the content area inside panel(c, r, w, ..., title)."""
    return c + 4, r + (10 if title else 4), w - 8


def panel(fb, L, c, r, w, h, title=None, color=DIM):
    """A 1-cell border box w x h at (c, r). With a title, the title (small highlight) is set into
    the top border ("-- TITLE ------"); the border then runs at row r + 3, through the caps. Draw
    the content first at panel_inner(c, r, w, title) and end the box 3 rows under it:
        ic, ir, iw = panel_inner(c, y, w); end = kv(fb, L, ic, ir, iw, ...); ...
        y = panel(fb, L, c, y, w, end - y + 1, "RELAY INFO")
    Returns r + h + GAP."""
    if title:
        top = r + 3
        fb.box(c, top, w, h - 3, color)
        t = fit_text(_upper(title), w - 14)
        fb.fill(c + 3, top, text_width(t) + 6, 1, UNLIT)
        fb.text(c + 6, r, t, "small", HIGHLIGHT)
    else:
        fb.box(c, r, w, h, color)
    return r + h + GAP


def toggle(fb, L, c, r, w, label_text, on, enabled=True, name=None, label_color=TEXT):
    """Label on the left, a pixel ON/OFF switch right-aligned (SWITCH_W = 45 cells): a dim 1-cell
    frame split in two; ON = highlight block behind "ON", OFF = dim block behind "OFF", the other
    half dim text. Tap "toggle:<LABEL>" across the whole row. Returns the next free row."""
    seg = (SWITCH_W - 3) // 2                   # 21 = "OFF" + 2 cells each side
    sx = c + w - SWITCH_W
    lc = label_color if enabled else DIM
    fb.text_fit(c, r + CTRL_TEXT, _upper(label_text), sx - c - 6, "small", lc)
    fb.box(sx, r, SWITCH_W, CTRL_H, DIM)
    fb.vline(sx + 1 + seg, r, CTRL_H, DIM)
    on_x, off_x = sx + 1, sx + 2 + seg
    if on:
        fb.fill(on_x, r + 1, seg, CTRL_H - 2, HIGHLIGHT if enabled else DIM)
        fb.text(_cx(on_x, seg, "ON"), r + CTRL_TEXT, "ON", "small", UNLIT)
        fb.text(_cx(off_x, seg, "OFF"), r + CTRL_TEXT, "OFF", "small", DIM)
    else:
        fb.text(_cx(on_x, seg, "ON"), r + CTRL_TEXT, "ON", "small", DIM)
        fb.fill(off_x, r + 1, seg, CTRL_H - 2, DIM)
        fb.text(_cx(off_x, seg, "OFF"), r + CTRL_TEXT, "OFF", "small", UNLIT)
    if enabled:
        _tap(fb, c, r, w, CTRL_H, name or "toggle:" + _upper(label_text))
    return r + CTRL_H + GAP


def options(fb, L, c, r, w, items, selected, label_text=None, enabled=True, name=None, columns=None):
    """[OPTION] selectors (pickers, chips). items: list of names; selected: an index, a name, a
    set/list of names/indices (multi-select chips) or None. Unselected: dim brackets around the name
    in text; selected: a solid highlight block over the bracket footprint (2 cells around the caps)
    with the name cut out. Optional dim label line above (with the group gap). Items flow left to
    right and wrap every CTRL_H + GAP rows; columns=n instead centres each item in one of n equal
    cells (a grid that lines up across rows, like the app's equal-width segmented buttons). Each item is a tap
    "<name or option:LABEL>:<ITEM>". Returns the next free row."""
    if label_text:
        r = label(fb, L, c, r, w, label_text)
    if isinstance(selected, (set, list, tuple, frozenset)):
        sel = set(selected)
    else:
        sel = {selected}
    base = name or "option:" + _upper(label_text or "")
    cells = L.split(columns, gap=OPT_GAP, c=c, w=w) if columns else None
    x, y = c, r
    for i, raw in enumerate(items):
        item = _upper(raw)
        if cells:
            col = i % columns
            if col == 0 and i:
                y += CTRL_H + GAP
            x, ow = cells[col]
        else:
            ow = text_width("[" + item + "]")
            if x > c and x + ow > c + w:
                x, y = c, y + CTRL_H + GAP
            ow = min(ow, c + w - x)
        shown = fit_text(item, ow - 2 * _ADV)
        fw = text_width("[" + shown + "]")         # footprint: the brackets hug the name
        fx = x + (ow - fw) // 2 if cells else x
        ty = y + CTRL_TEXT
        if (i in sel) or (raw in sel) or (item in sel):
            fb.fill(fx, y + 1, fw, CTRL_H - 2, HIGHLIGHT if enabled else DIM)
            fb.text(fx + _ADV, ty, shown, "small", UNLIT)
        else:
            fb.text(fx, ty, "[", "small", DIM)
            fb.text(fx + _ADV, ty, shown, "small", TEXT if enabled else DIM)
            fb.text(fx + fw - 5, ty, "]", "small", DIM)
        if enabled:
            _tap(fb, x - OPT_GAP // 2, y, ow + OPT_GAP, CTRL_H, "%s:%s" % (base, item))
        x += ow + OPT_GAP
    return y + CTRL_H + GAP


def stepper(fb, L, c, r, w, label_text, value, enabled=True, can_dec=True, can_inc=True,
            value_chars=None, name=None):
    """Label on the left; right-aligned [-] value [+]: two 13 x 13 step buttons around the value
    (small highlight, centred in a field value_chars wide, default the value's length). Taps
    "<name or stepper:LABEL>:-" / ":+". Returns the next free row."""
    value = str(value)
    n = max(len(value), value_chars or 0)
    vw = n * _ADV - 1 + 6                       # value field with 3 cells each side
    gx = c + w - (STEP_W + vw + STEP_W)
    base = name or "stepper:" + _upper(label_text)
    fb.text_fit(c, r + CTRL_TEXT, _upper(label_text), gx - c - 6, "small", TEXT if enabled else DIM)
    step_button(fb, gx, r, False, enabled and can_dec, base + ":-")
    fb.text(_cx(gx + STEP_W, vw, value), r + CTRL_TEXT, value, "small", HIGHLIGHT if enabled else DIM)
    step_button(fb, gx + STEP_W + vw, r, True, enabled and can_inc, base + ":+")
    return r + CTRL_H + GAP


def button(fb, L, c, r, w, label_text, primary=False, enabled=True, name=None, alarm=False):
    """A button w cells wide (w=None: the label + 6 cells each side), CTRL_H tall: highlight 1-cell
    border with the label in text (MMCompactButton), or primary=True a solid highlight block with
    the label cut out (MMPrimaryButton); disabled = dim border and dim label. alarm=True is a
    destructive action (DELETE, CLEAR): ALARM border and label, or on a red-ish base a solid
    highlight block with the label cut out, as alarms are drawn there. Tap "button:<LABEL>".
    Returns the next free row."""
    s = _upper(label_text)
    if w is None:
        w = text_width(s) + 12
    s = fit_text(s, w - 4)
    tx, ty = _cx(c, w, s), r + CTRL_TEXT
    if alarm and enabled:
        if fb.alarm_inverted:
            fb.fill(c, r, w, CTRL_H, HIGHLIGHT)
            fb.text(tx, ty, s, "small", UNLIT)
        else:
            fb.box(c, r, w, CTRL_H, ALARM)
            fb.text(tx, ty, s, "small", ALARM)
    elif primary and enabled:
        fb.fill(c, r, w, CTRL_H, HIGHLIGHT)
        fb.text(tx, ty, s, "small", UNLIT)
    else:
        fb.box(c, r, w, CTRL_H, HIGHLIGHT if enabled else DIM)
        fb.text(tx, ty, s, "small", TEXT if enabled else DIM)
    if enabled:
        _tap(fb, c, r, w, CTRL_H, name or "button:" + s)
    return r + CTRL_H + GAP


def buttons(fb, L, c, r, w, labels, primary=None, enabled=None, gap=4, equal=True, alarm=None):
    """A row of buttons. equal=True splits w into equal cells; equal=False sizes each to its label
    (left-aligned, gap cells apart). primary: index (or label) of the primary button; enabled: list
    of bools or None; alarm: index (or label) of a destructive button. Returns the next free row."""
    n = len(labels)
    if not n:
        return r
    en = enabled or [True] * n
    if equal:
        spots = L.split(n, gap=gap, c=c, w=w)
    else:
        spots, x = [], c
        for s in labels:
            bw = text_width(_upper(s)) + 12
            spots.append((x, bw))
            x += bw + gap
    for i, s in enumerate(labels):
        bc, bw = spots[i]
        is_p = primary is not None and (primary == i or primary == s)
        is_a = alarm is not None and (alarm == i or alarm == s)
        button(fb, L, bc, r, bw, s, primary=is_p, enabled=en[i], alarm=is_a)
    return r + CTRL_H + GAP


def slider(fb, L, c, r, w, title, value_text, frac, hint=None, enabled=True, zone=None,
           marker=False, name=None, can_dec=None, can_inc=None):
    """The app's SettingSlider: title (text, uppercased; put the unit in it: "BURST MS") with the
    value right-aligned (highlight) on the label row, then [-] LED bar [+] (the bar vertically
    centred between the 13 x 13 step buttons), then an optional dim wrapped hint (as given).
    can_dec / can_inc (default: frac > 0 / frac < 1) disable − at the range minimum and + at the
    maximum, as SettingSlider does. Taps "<name or slider:TITLE>:-", ":+", ":bar". Returns the
    next free row."""
    if can_dec is None:
        can_dec = frac > 0
    if can_inc is None:
        can_inc = frac < 1
    r = _group_top(L, r)
    title = _upper(title)
    value_text = str(value_text)
    vw = text_width(value_text)
    fb.text(c + w - vw, r, value_text, "small", HIGHLIGHT if enabled else DIM)
    fb.text_fit(c, r, title, w - vw - 6, "small", TEXT if enabled else DIM)
    y = r + LABEL_H
    base = name or "slider:" + title
    step_button(fb, c, y, False, enabled and can_dec, base + ":-")
    step_button(fb, c + w - STEP_W, y, True, enabled and can_inc, base + ":+")
    bx = c + STEP_W + 4
    bw = w - 2 * (STEP_W + 4)
    fb.led_bar(bx, y + (CTRL_H - vfd.LED_BAR_H) // 2 + 1, bw, frac,
               color=HIGHLIGHT if enabled else DIM, marker=marker, zone=zone)
    if enabled:
        _tap(fb, bx - 2, y, bw + 4, CTRL_H, base + ":bar")
    y += CTRL_H + GAP
    if hint:
        y = fb.paragraph(c, y + 1, hint, w, "small", DIM, LINE) + GAP
    return y


def meter(fb, L, c, r, w, title, value_text, frac, zone=None, marker=False, color=HIGHLIGHT):
    """Read-only LED meter: title (dim) with the value right-aligned (highlight; ALARM via
    alarm_text) on the label row, a full-width LED bar under it (marker / zone as vfd.led_bar).
    Returns the next free row."""
    r = _group_top(L, r)
    title = _upper(title)
    value_text = str(value_text)
    vw = text_width(value_text)
    if color == ALARM:
        alarm_text(fb, c + w - 1, r, value_text, right=True)
    else:
        fb.text(c + w - vw, r, value_text, "small", color)
    fb.text_fit(c, r, title, w - vw - 6, "small", DIM)
    fb.led_bar(c, r + LABEL_H, w, frac, color=HIGHLIGHT, marker=marker, zone=zone)
    return r + LABEL_H + vfd.LED_BAR_H + GAP + 1


def field(fb, L, c, r, w, label_text, value, placeholder="", focused=False, name=None,
          value_color=TEXT):
    """Boxed text field: optional dim label line (with the group gap), then a FIELD_H box (dim
    border, highlight when focused; one row taller than CTRL_H so descenders clear the bottom
    border, caps at +CTRL_TEXT like every control) with the value in value_color (as given) or the
    placeholder in dim (uppercased), truncated with …; a focused field shows a 1 x 7 highlight
    cursor after the value (before the placeholder). Tap "field:<LABEL>". Returns the next free
    row."""
    if label_text:
        r = label(fb, L, c, r, w, label_text)
    fb.box(c, r, w, FIELD_H, HIGHLIGHT if focused else DIM)
    ty = r + CTRL_TEXT
    x, inner = c + 3, w - 7
    if value:
        end = fb.text_fit(x, ty, str(value), inner, "small", value_color)
        if focused:
            fb.vline(min(end, c + w - 3), ty, 7, HIGHLIGHT)
    else:
        if focused:
            fb.vline(x, ty, 7, HIGHLIGHT)
            x, inner = x + 3, inner - 3
        if placeholder:
            fb.text_fit(x, ty, _upper(placeholder), inner, "small", DIM)
    _tap(fb, c, r, w, FIELD_H, name or "field:" + _upper(label_text or ""))
    return r + FIELD_H + GAP


def packet_row(fb, L, c, r, w, label_text, hex_text, subtitle="", tag=None, selected=False,
               right=None, name=None, hex_color=HIGHLIGHT):
    """One packet line (PacketRow): the label (text, uppercased; selected = inverted highlight)
    with an optional boxed tag after it (BAND) and an optional right-aligned dim note (age, RSSI),
    the hex truncated with … (hex_color: HIGHLIGHT for live RX, DIM for stored library rows as
    iOS PacketRow's cyanDim), the uppercased subtitle in dim, then a dotted dim divider.
    Lines every LINE rows, 3 empty rows above the first and below the last caps. The whole row is
    one tap "packet:<LABEL>". Rows stack directly: the return value is the next row's r."""
    lab = _upper(label_text)
    y = r + 3
    limit = c + w
    if right:
        rt = fit_text(_upper(right), w // 3)
        start = c + w - text_width(rt)
        fb.text(start, y, rt, "small", DIM)
        limit = start - 6
    x = c + 2
    tag_s = _upper(tag) if tag else ""
    tag_w = text_width(tag_s) + 8 if tag_s else 0
    lab = fit_text(lab, limit - x - 2 - tag_w)
    if selected:
        x = badge(fb, x, y, lab, HIGHLIGHT)
    else:
        x = fb.text(x, y, lab, "small", TEXT) + 1
    if tag_s:
        tag_box(fb, x + 4, y, tag_s)
    if hex_text:
        y += LINE
        fb.text_fit(c + 2, y, str(hex_text), w - 2, "small", hex_color)
    if subtitle:
        y += LINE
        fb.text_fit(c + 2, y, _upper(subtitle), w - 2, "small", DIM)
    y += 7 + 3
    fb.hline(c, y, w, DIM, step=2)
    _tap(fb, c, r, w, y - r, name or "packet:" + _upper(label_text))
    return y + 1


def chart(fb, L, c, r, w, h, title, values, value_text=None, vmin=None, vmax=None, color=HIGHLIGHT):
    """Line chart block: dim title (with the group gap) and an optional right-aligned highlight
    value on the label row, then a dim-framed w x h box with the single-cell line inside (dotted
    baseline, 1 empty cell inside the frame). Returns the next free row."""
    if title or value_text:
        r = _group_top(L, r)
        if value_text:
            fb.text_right(c + w - 1, r, str(value_text), "small", HIGHLIGHT)
        fb.text_fit(c, r, _upper(title), w - text_width(str(value_text or "")) - 6, "small", DIM)
        r += LABEL_H
    fb.box(c, r, w, h, DIM)
    fb.line_chart(c + 2, r + 2, w - 4, h - 4, values, color=color, vmin=vmin, vmax=vmax)
    return r + h + GAP


# ---------------------------------------------------------------------------------------------
# Lists under pinned rows (TX, WAND, LOGS): a scrolling window that never cuts a line
# ---------------------------------------------------------------------------------------------

def snapped_window(fb, top, bottom, draw_fn):
    """Rows (t, b) of the screen window [top, bottom) a scrolling list may use without cutting a
    line of text: draw_fn(target) is run once on a scratch buffer (same origin as fb), and a band
    of lit rows that crosses the top or the bottom edge is left out of the window, so partly
    scrolled-off lines are hidden instead of being cut mid-glyph. A lone lit row (a row divider)
    in the first or last 5 rows of the window is left out too, so it never doubles the solid rule
    (or pinned header rule) the window sits under, or the tab-bar rule it sits over.
    (SCAN keeps an edge-aware variant in screens/scan.py for its bordered controls panel.)"""
    probe = vfd.FrameBuffer(fb.cols, fb.rows)
    probe.push_clip(0, 0, fb.cols, fb.rows, dy=fb.origin_y)
    draw_fn(probe)
    probe.pop_clip()
    cols = fb.cols

    def lit(r):
        return 0 <= r < fb.rows and any(probe.cells[r * cols:(r + 1) * cols])

    def lone(r):
        return lit(r) and not lit(r - 1) and not lit(r + 1)

    t, b = top, bottom
    if lit(t - 1) and lit(t):
        while t < b and lit(t):
            t += 1
    for r in range(t, min(t + 5, b)):
        if lone(r):
            t = r + 1
            break
    if lit(b - 1) and lit(b):
        while b > t and lit(b - 1):
            b -= 1
    for r in range(b - 1, max(b - 6, t - 1), -1):
        if lone(r):
            b = r
            break
    return t, b


def list_scrollbar(fb, top, h, total, scroll):
    """A list's scroll indicator in the last screen column over rows top .. top+h-1 (screen
    rows): a dotted dim track and a solid dim thumb, only when the list is taller than its
    window (as scrollbar(), but for a list under pinned controls)."""
    if total <= h:
        return
    col = fb.cols - 1
    fb.vline(col, top, h, DIM, step=2)
    th = max(6, h * h // total)
    ty = top + (h - th) * max(0, min(scroll, total - h)) // max(1, total - h)
    fb.vline(col, ty, th, DIM)


def token_lines(text, max_cols, sep=" · "):
    """Split a "A · B · C" line into lines that break only between tokens (never leaving a
    dangling "·"); a token that is too long on its own is truncated with …."""
    lines, cur = [], ""
    for tok in text.split(sep):
        cand = tok if not cur else cur + sep + tok
        if text_width(cand) <= max_cols:
            cur = cand
            continue
        if cur:
            lines.append(cur)
        cur = fit_text(tok, max_cols)
    if cur:
        lines.append(cur)
    return lines


# TxIntervalSlider (TX loop and WAND starlight loop): TxLoopInterval's 61 stops over 0.5 ... 30 s.
LOOP_MIN, LOOP_MAX, LOOP_LAST_STOP = 0.5, 30.0, 60


def interval_stop(seconds):
    """TxLoopInterval.stop(forSeconds:)."""
    pos = (seconds - LOOP_MIN) / (LOOP_MAX - LOOP_MIN) * LOOP_LAST_STOP
    return int(min(max(round(pos), 0), LOOP_LAST_STOP))


def interval_text(seconds):
    """TxLoopInterval.text(_:): one decimal, halves rounding up."""
    tenths = int(abs(seconds) * 10 + 0.5)
    return "%d.%d" % (tenths // 10, tenths % 10)


def interval_slider(fb, L, c, r, w, label_text, seconds, name="slider:INTERVAL"):
    """TxIntervalSlider (TX and WAND tabs): one line of text (text colour, truncated) right over a
    full-width 61-stop slider without step buttons: a dotted dim track, the lit part up to the
    thumb and a 3 x 6 thumb (3 rows under the caps). The tap covers the bar and the label (15
    rows). Returns the next free row (5 rows under the bar)."""
    r = r + GROUP_GAP if r > L.content_top else r
    fb.text_fit(c, r, label_text, w, "small", TEXT)
    y = r + LABEL_H
    frac = interval_stop(seconds) / float(LOOP_LAST_STOP)
    fb.led_bar(c, y, w, frac, marker=True, zone=(0.0, frac))
    fb.tap(c, y - 6, w, TAP_ROWS, name + ":bar")
    return y + vfd.LED_BAR_H + 3 + GAP


def menu_button(fb, L, x, y, label_text, enabled=True, name=None):
    """A menu button on a CTRL_H row (SectionFilterMenu "CLASS 8/8 ▾" on SCAN, TX and LINK): a
    button (highlight border, label in text) with a pixel down-chevron after the label. Tap
    "<name or menu:LABEL>". Returns the column after it."""
    label = _upper(label_text)
    w = text_width(label) + 11 + 12
    fb.box(x, y, w, CTRL_H, HIGHLIGHT if enabled else DIM)
    ty = y + CTRL_TEXT
    end = fb.text(x + 6, ty, label, "small", TEXT if enabled else DIM)
    chevron(fb, end + 3, ty + 1, False, TEXT if enabled else DIM)
    if enabled:
        _tap(fb, x - 2, y, w + 4, CTRL_H, name or "menu:" + label)
    return x + w


# ---------------------------------------------------------------------------------------------
# Band LEDs (SCAN's LAST LIGHTS strip and LAB's band preview): in the previews each named colour
# gets a fill pattern and a legend entry with its name; the app fills them with the packet's true
# colour instead (led(..., fill=(r, g, b))), the name text staying beside them.
# ---------------------------------------------------------------------------------------------

N_PATTERNS = 5


def _disc(size):
    """Cells of a round LED size x size (centre distance <= size / 2)."""
    m = (size - 1) / 2.0
    rad = size / 2.0
    return {(i, j) for j in range(size) for i in range(size)
            if (i - m) ** 2 + (j - m) ** 2 <= rad * rad - 0.5}


def led(fb, x, y, kind, size=7, color=HIGHLIGHT, fill=None):
    """A round LED / legend swatch size x size with its top-left at (x, y), filled with pattern
    `kind`: 0 solid, 1 checker, 2 ring with a centre dot, 3 horizontal stripes, 4 vertical stripes;
    None = unlit (a dotted dim ring). fill=(r, g, b): a solid disc in that true colour (fb.rgb)
    instead of the pattern; kind=None still draws the unlit ring."""
    disc = _disc(size)
    edge = {(i, j) for (i, j) in disc
            if any((i + di, j + dj) not in disc for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1)))}
    m = size // 2
    true_col = fb.rgb(fill) if fill is not None and kind is not None else None
    for (i, j) in disc:
        if kind is None:
            on, col = (i, j) in edge and (i + j) % 2 == 0, DIM
        elif true_col is not None:
            on, col = True, true_col
        else:
            k = kind % N_PATTERNS
            col = color
            if k == 0:
                on = True
            elif k == 1:
                on = (i + j) % 2 == 0
            elif k == 2:
                on = (i, j) in edge or (abs(i - m) <= 1 and abs(j - m) <= 1)
            elif k == 3:
                on = j % 2 == 0
            else:
                on = i % 2 == 0
        if on:
            fb.set(x + i, y + j, col)
