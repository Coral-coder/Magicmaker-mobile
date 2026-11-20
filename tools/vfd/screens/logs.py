"""LOGS tab in the VFD look: port of ios/MagicMaker/Views/LogsScreen.swift.

Top to bottom, as on the phone:
    CAPTURE LOGS with REFRESH (the screen title row, here the header) | STATUS: <tx status>
    | the replay banner (REPLAYING n/total · file, STOP) while a replay runs | hairline
    | the log list, newest first: name (+ REC while it is being written) over
      "<n> PKTS · <kb>KB · <ago> AGO"; under the open log:
        FILTER TYPES (NONE = ALL) chips | FILTER SOURCE (TAP = ONLY THAT SOURCE) chips
        | BAND ONLY switch | REPLAY  SHARE  DELETE | ANALYZE (HIDE PACKETS)  ADD ALL → LIB
        | analyzing: HIDE BANDS & PINGS (n OF m) switch, "<n> UNIQUE · TAP = TX · NAME = ADD",
          one row per distinct packet ("×count · LABEL", hex, NAME)
        | otherwise: "<n> PACKETS · TAP = TX" and the PacketRows in log order
          (time · RSSI · category · source), "…and n more (showing first 1000)"
    NO LOGS YET — START A SCAN when there are none.

Re-expressed for the grid:
    * the status line, the replay banner and the hairline stay pinned while the list scrolls (they
      sit above the List on iOS); list lines cut by the window edges are hidden, not cut mid-glyph.
    * the cyan-tinted replay banner is a status banner: a solid highlight block with the text cut
      out; its STOP button is a cut-out outline. The text wraps around STOP, two lines at most.
    * the open log's tinted background and cyan name: its name is an inverted block (as a selected
      PacketRow); REC (amber text and outline on iOS, a live state) is a boxed tag with highlight
      outline and text, not inverted, so it does not read as the open log.
    * filter chips (horizontally scrolling on iOS) are [OPTION]s that wrap, selected = inverted
      (iOS adds a tick); the switches are pixel ON/OFF switches.
    * the outlined capsule buttons are bordered buttons with the label in the iOS colour: REPLAY
      text (dim while a replay runs), SHARE / ADD ALL → LIB highlight (cyan), DELETE alarm.
    * the long HIDE BANDS & PINGS label wraps onto two lines beside its switch; hint captions and
      the replay banner wrap at their " · " separators, the separator dropped at the break.
    * the all-noise hint is guidance in the attention colour (highlight); alarm is kept for the
      not-linked and send-failed statuses.
    * a PacketRow subtitle too long for the row shortens its category first (… or left out), so
      the 8-character source at its end is always whole.
    * file names, the "…and n more" notes and hex are drawn as given (iOS does not uppercase them).
    * the toast, the share sheet, the rename prompt and the delete confirmation are not drawn.

Mock state: scanning and recording tonight's log (matches SCAN: LOG · scan_2026-11-19T21-42-07.csv,
RX:1284), yesterday evening's log open with the ANIMATION and COLOR type chips on, ANALYZE showing
and that log replaying through the linked relay. Labels and hex are real ones from
ios/ParityCheck/vectors.json; sources are the SCAN tab's park transmitters, wands and bands (the last
8 hex characters of CoreBluetooth UUIDs, as shortAddress() prints them).
"""

import widgets as W
import vfd
from vfd import UNLIT, HIGHLIGHT, TEXT, DIM, ALARM, text_width, fit_text

# Shared with TX and WAND, now in widgets.py (it also hides a lone row divider in the first or
# last 5 rows of the window, so a divider never doubles the pinned rule).
snapped_window, list_scrollbar = W.snapped_window, W.list_scrollbar


TAB = "logs"
TITLE = "CAPTURE LOGS"
HEADER_RIGHT = "REFRESH"       # the header row's REFRESH text button
HEADER_RIGHT_TAP = "refresh"

# ---------------------------------------------------------------------------------------------
# Mock state (LogsScreen @State, TxEngine, SessionLogFiles)
# ---------------------------------------------------------------------------------------------

LOGS_LOADED = True
REPLAY_ACTIVE = True
REPLAY_PROGRESS = 214
REPLAY_TOTAL = 2433                    # the open log's rows through its filters
TX_STATUS = "Replaying"                # TxEngine.status while a replay runs

ACTIVE_LOG = "scan_2026-11-19T21-42-07.csv"      # store.activeSessionName (recording)
OPEN_LOG = "scan_2026-11-18T19-05-33.csv"        # selectedPath's file

#: SessionLogFiles.listLogs(), newest first: (name, packetCount, sizeBytes, seconds since modified)
LOGS = [
    ("scan_2026-11-19T21-42-07.csv", 1284, 266_411, 3),
    ("scan_2026-11-18T19-05-33.csv", 6412, 1_342_588, 26 * 3600 + 410),
    ("scan_2026-11-16T14-22-10.csv", 3108, 648_215, 3 * 86400 + 7 * 3600),
    ("scan_2026-11-12T10-48-51.csv", 9875, 2_066_903, 7 * 86400 + 11 * 3600),
    ("scan_2026-11-09T16-03-27.csv", 418, 85_377, 10 * 86400 + 5 * 3600),
    ("scan_2026-10-31T19-30-02.csv", 12940, 2_712_664, 19 * 86400 + 2 * 3600),
]

# CoreBluetooth identifiers (the SCAN tab's park transmitters, wands and band, plus two guest bands)
MY_BAND = "5C0E8B47-2D1A-4F3C-9E06-11B4A7D3901B"
SHOW_A = "0B6F2E91-7C44-4D0A-B8E2-5A90C41E9A07"
SHOW_B = "D2F17A3C-9B05-4E68-A1C7-3E2F7B2D5F13"
SHOW_C = "8A43C6E0-1F7D-4B92-9D35-C8B1E06A3B98"
SHOW_D = "71B9D2E6-3A0F-4E85-B6C4-0D97A1F3E254"
WAND_1 = "4E9D0A72-63B8-4C1F-8A2E-F07D51F8C2D4"
WAND_3 = "19E4B6D3-C870-4A25-93F1-6B2E8F4D17C6"
GUEST_1 = "2F8A61C4-0E37-4B9D-A512-7C3D90E4B6F1"
GUEST_2 = "E5137B0D-84A2-4C6E-9F08-3B1A6D2C58E7"

#: The open log: LogAnalysis.categories (sorted) and addresses (first heard first, ≤ 12 chips).
CATEGORIES = ["ANIMATION", "COLOR", "SHOW", "UNKNOWN"]
ADDRESSES = [SHOW_A, GUEST_1, SHOW_B, WAND_1, MY_BAND, SHOW_C, GUEST_2, WAND_3, SHOW_D]
SOURCE_CHIP_LIMIT = 12                 # LogAnalysis.sourceChipLimit

# Per-log filters
SELECTED_CATS = {"ANIMATION", "COLOR"}
SELECTED_ADDR = ""
BAND_ONLY = False
ANALYZING = True
HIDE_NOISE = True
SUMMARY_UP_TO_DATE = True              # upToDateSummary != nil (ADD ALL → LIB enabled)

ANALYZED_ROW_LIMIT = 300               # LogAnalysis.analyzedRowLimit
PACKET_ROW_LIMIT = 1000                # logsPacketRowLimit

#: LogSummary.analyzed for those filters with bands & pings hidden, most frequent first:
#: (count, label, hex of the group's first row).
ANALYZED = [
    (412, "Cross-Fade: Red / Blue", "8301CC03000100E911006F0F554258F44882D1460208D06500B3"),
    (367, "Single Color: Red", "8301E905002E0EF5B0"),
    (298, "Dual Color: Yellow Orange centre / Blue corners", "8301CC03000100E100E90600060F8F82B3"),
    (241, "Effect: Circle", "8301CC03000100E100E90B0B060F5C5D48A5D14532B3"),
    (187, "Rotating Colors (E912)", "8301E100E91200030FA2A2A4A4A230D037F4D2460064FCB9"),
    (133, "Single Color: Cyan", "8301CC03000100E100E90500090E00B0"),
    (96, "Starlight: Blue (#02)", "8301CF0B00C020224EAC7807866E82"),
    (71, "Comet (E910)", "8301E100E91000194897D00E8ED146060F30D04E1FB0"),
    (57, "Starlight: Pink (#08)", "8301CF0B00C020224EAC7807866FA8"),
    (44, "Candle Flicker (E90F)", "8301E200E90F00120F40565813488DD2462A1317B0"),
    (38, "Single Color: White", "8301E905002E0EFCB0"),
    (29, "Cross-Fade: Pink / Cyan", "8301E100E911006F0F484058F44882D1460208D06500B0"),
    (26, "Show: Pirate Cannon", "8301E100E9110003240F55515BF00F10374894D13D0508"),
    (22, "Starlight: Red (#15)", "8301CF0B00C42922EFD819F22A6215"),
    (19, "Centre Pulse (E90F)", "8301E100E90F00020F43445801488DD246020100B0"),
    (17, "Single Color: Blue", "8301E905002E0EE2B0"),
    (15, "Animation: 5-Color Cycle", "8301E100E90C000F0FB1B9B5B1A2307B7DB0"),
    (12, "Single Color: Pink", "8301E905002E0EEEB0"),
    (11, "Starlight: White (#1B)", "8301CF9B00C42922EFD819F22A621B"),
    (9, "Twinkle / Flash (E90E)", "8301E100E90E00040FB5A2B9AFA159190B48AEB0"),
    (7, "Dual Color: White centre / Cyan corners", "8301E100E90600220F5C57B0"),
    (5, "Starlight: Cyan (#00)", "8301CF0B00C020224EAC7807866F80"),
    (3, "Repeating Fade (E914)", "8301E100E91400030F5D5458F44882D0650AD1460228307B00B0"),
    (2, "Custom RGB Color", "8301CC03000100E908000ED2557E2800B3"),
]
#: Starlight packets heard behind a wake ping (8301CC03…CF9B…) are pings to isLibraryNoise.
NOISE = [("Starlight: Red (#15)", "8301CC03000100CF9B00C42922EFD819F22A6215B0"),
         ("Starlight: White (#1B)", "8301CC03000100CF9B00C42922EFD819F22A621B")]
NOISE_COUNT = 312
FILTERED_COUNT = sum(n for n, _, _ in ANALYZED) + NOISE_COUNT      # 2433

#: Packet rows (ANALYZING off): the filtered rows in log order, made up from a repeating pattern
#: of (ANALYZED index or -1/-2 for a NOISE row, source, RSSI) so every one of the 1000 rows a
#: List would show is drawable without storing them.
_ROW_PATTERN = [
    (0, SHOW_A, -61), (1, SHOW_A, -58), (0, SHOW_A, -60), (2, SHOW_B, -67), (6, WAND_1, -72),
    (1, SHOW_A, -59), (3, SHOW_B, -66), (-1, WAND_1, -74), (0, SHOW_A, -62), (5, SHOW_C, -78),
    (4, SHOW_B, -68), (8, WAND_3, -81), (1, SHOW_A, -57), (2, SHOW_B, -65), (7, SHOW_D, -84),
    (-2, WAND_3, -79), (3, SHOW_B, -69), (0, SHOW_A, -61), (9, SHOW_C, -77), (10, SHOW_D, -83),
]
_ROW_START_S = 19 * 3600 + 5 * 60 + 41     # 19:05:41, the first row's time of day

# ---------------------------------------------------------------------------------------------
# Small helpers (Swift: the same names on the VFD screen type)
# ---------------------------------------------------------------------------------------------

_ADV = 6
IND = 6                 # the open log's rows: .padding(.leading, 8) (≈ 5 cells at 3x, 4 at 2x)
STOP_W = text_width("STOP") + 12


def short_address(address):
    """shortAddress(): the last 8 characters, uppercased; empty stays empty."""
    return address[-8:].upper() if address else ""


def ago_text(seconds):
    """agoText(): 3s, 2m, 1h, 4d."""
    if seconds < 60:
        return "%ds" % seconds
    if seconds < 3600:
        return "%dm" % (seconds // 60)
    if seconds < 86400:
        return "%dh" % (seconds // 3600)
    return "%dd" % (seconds // 86400)


def fit_middle(s, max_cols):
    """s, or its head and tail around '…' so it fits max_cols (SwiftUI .truncationMode(.middle))."""
    n = vfd.max_chars(max_cols)
    if len(s) <= n:
        return s
    if n <= 1:
        return fit_text(s, max_cols)
    keep = n - 1
    head = (keep + 1) // 2
    return s[:head] + vfd.ELLIPSIS + s[len(s) - (keep - head):]


def _tap(fb, c, r, w, h, name):
    """Tap rectangle at least W.TAP_ROWS tall, grown evenly around the visual (as widgets do)."""
    if h < W.TAP_ROWS:
        r -= (W.TAP_ROWS - h) // 2
        h = W.TAP_ROWS
    fb.tap(c, r, w, h, name)


def drop_dangling(lines, mark="·"):
    """Wrapped lines without a separator left hanging at a break: a trailing ' ·' is cut from every
    line but the last and a leading '· ' from every line but the first (a line that was only the
    separator goes)."""
    out = []
    for i, ln in enumerate(lines):
        s = ln
        if i < len(lines) - 1:
            while s.rstrip().endswith(" " + mark) or s.strip() == mark:
                s = s.rstrip()[:-1].rstrip()
        if i > 0:
            while s.lstrip().startswith(mark + " "):
                s = s.lstrip()[1:].lstrip()
        if s or not ln:
            out.append(s)
    return out


def caption_lines(s, w, sep=" · "):
    """A caption broken into lines of at most w cells: at its ' · ' separators (the separator is
    dropped at the break, so no line ends on a stray '·'), before a "(…)" aside, then at spaces,
    then truncated with …."""
    if text_width(s) <= w:
        return [s]
    if " (" in s and sep not in s:
        head, tail = s.split(" (", 1)
        if text_width(head) <= w:
            return [head] + caption_lines("(" + tail, w, sep)
    lines, cur = [], ""
    for part in s.split(sep):
        cand = (cur + sep + part) if cur else part
        if cur and text_width(cand) > w:
            lines.append(cur)
            cur = part
        else:
            cur = cand
    lines.append(cur)
    out = []
    for ln in lines:
        out.extend(vfd.wrap_text(ln, w) if text_width(ln) > w else [ln])
    return [fit_text(ln, w) for ln in drop_dangling(out)]


def caption(fb, L, c, r, w, s, color=DIM, group=True):
    """logsCaption above a control: dim, wrapped (as W.label, but on as many lines as it needs).
    Returns the row for the control under it."""
    if group:
        r = W._group_top(L, r)
    lines = caption_lines(s, w)
    for i, ln in enumerate(lines):
        fb.text(c, r + i * W.LINE, ln, "small", color)
    return r + (len(lines) - 1) * W.LINE + W.LABEL_H


def note_lines(fb, L, c, r, w, s, color=DIM):
    """A caption line on its own (hint, "…and n more"): wrapped, LINE apart, with the standard gap
    after it. Returns the next free row."""
    r += 2
    for ln in caption_lines(s, w):
        fb.text(c, r, ln, "small", color)
        r += W.LINE
    return r + W.GAP


def outline_button(fb, x, y, w, label, color=TEXT, enabled=True, name=None):
    """LogsOutlineButton: a CTRL_H button w cells wide (None: the label + 6 cells each side) with a
    highlight border and the label in TEXT, as every bordered button (W.button); ALARM draws a
    destructive one (alarm border and label; on a red-ish base a solid highlight block with the
    label cut out); disabled = dim border and label. Returns the column after it."""
    s = W._upper(label)
    if w is None:
        w = text_width(s) + 12
    s = fit_text(s, w - 4)
    tx, ty = W._cx(x, w, s), y + W.CTRL_TEXT
    if not enabled:
        fb.box(x, y, w, W.CTRL_H, DIM)
        fb.text(tx, ty, s, "small", DIM)
    elif color == ALARM and fb.alarm_inverted:
        fb.fill(x, y, w, W.CTRL_H, HIGHLIGHT)
        fb.text(tx, ty, s, "small", UNLIT)
    else:
        fb.box(x, y, w, W.CTRL_H, ALARM if color == ALARM else HIGHLIGHT)
        fb.text(tx, ty, s, "small", color)
    if enabled:
        _tap(fb, x, y, w, W.CTRL_H, name or "button:" + s)
    return x + w


def button_row(fb, L, c, r, w, specs, gap=W.OPT_GAP):
    """An HStack of outline buttons: specs = [(label, color, enabled, expand)]. Fixed buttons hug
    their label; the expanding ones share what is left equally (the last one takes the spare cell).
    Returns the next free row."""
    fixed = [text_width(W._upper(s[0])) + 12 for s in specs]
    n_exp = sum(1 for s in specs if s[3])
    spare = w - gap * (len(specs) - 1) - sum(f for f, s in zip(fixed, specs) if not s[3])
    each = spare // n_exp if n_exp else 0
    x, seen = c, 0
    for (label, color, enabled, expand), fw in zip(specs, fixed):
        bw = fw
        if expand:
            seen += 1
            bw = each + (spare - each * n_exp if seen == n_exp else 0)
        x = outline_button(fb, x, r, bw, label, color, enabled) + gap
    return r + W.CTRL_H + W.GAP


def wrapped_toggle(fb, L, c, r, w, label, on, label_color=DIM, name=None):
    """A Toggle whose label is too long for one line beside the switch: the label breaks before
    its "(…)" (else at spaces) onto two lines, the switch centred against them. Returns the next
    free row."""
    room = w - W.SWITCH_W - 6
    s = W._upper(label)
    if text_width(s) <= room:
        return W.toggle(fb, L, c, r, w, s, on, label_color=label_color, name=name)
    if " (" in s and text_width(s[:s.index(" (")]) <= room:
        lines = [s[:s.index(" (")], s[s.index(" (") + 1:]]
    else:
        lines = vfd.wrap_text(s, room)
    lines = [fit_text(ln, room) for ln in lines[:2]]
    y = r + 3                       # a two-line label gets a little more air above it
    for i, ln in enumerate(lines):
        fb.text(c, y + i * W.LINE, ln, "small", label_color)
    name = name or "toggle:" + s
    W.toggle(fb, L, c, y + 2, w, "", on, name=name)     # the switch centred on the two lines
    _tap(fb, c, r + 1, w, W.LINE + 7 + 4, name)
    return y + W.LINE + 7 + 3 + W.GAP


# ---------------------------------------------------------------------------------------------
# Pinned top: status line, replay banner, hairline
# ---------------------------------------------------------------------------------------------

def status_row(fb, L, c, y, w):
    """STATUS: <tx.status>; the not-linked / send-failed messages are warnings (amber on iOS)."""
    warn = TX_STATUS in ("No relay linked — nothing sent", "Transmit failed — check relay")
    return W.status_line(fb, L, c, y, w, "STATUS: " + TX_STATUS, color=ALARM if warn else DIM)


def replay_banner(fb, L, c, y, w):
    """While a replay runs: a solid highlight block, "REPLAYING n/total · file" cut out (two lines
    at most, the first beside STOP, tail-truncated like lineLimit(2)), STOP a cut-out outline
    button on the right. Returns the next free row."""
    if not REPLAY_ACTIVE:
        return y
    h = 29
    fb.fill(c, y, w, h, HIGHLIGHT)
    sx = c + w - 3 - STOP_W
    fb.box(sx, y + 2, STOP_W, W.CTRL_H, UNLIT)
    fb.text(sx + 6, y + 2 + W.CTRL_TEXT, "STOP", "small", UNLIT)
    _tap(fb, sx - 2, y + 2, STOP_W + 4, W.CTRL_H, "button:STOP")
    text = "REPLAYING %d/%d · %s" % (REPLAY_PROGRESS, REPLAY_TOTAL, OPEN_LOG)
    x = c + 4
    first_w = sx - 6 - x
    full_w = c + w - 4 - x
    words = text.split(" ")
    line1 = ""
    while words and text_width((line1 + " " + words[0]).strip()) <= first_w:
        line1 = (line1 + " " + words.pop(0)).strip()
    line2 = " ".join(words)
    if line2:                       # broken at the " · ": no separator left hanging on either line
        line1, line2 = drop_dangling([line1, line2])
    fb.text(x, y + 5, line1, "small", UNLIT)
    if line2:
        fb.text_fit(x, y + 17, line2, full_w, "small", UNLIT)
    return y + h + W.GAP


def hairline(fb, L, c, y, w):
    """The 0.5 pt panel line under the pinned rows: a solid dim rule, 3 empty rows each side."""
    fb.hline(c, y + 3, w, DIM)
    return y + 7


def pinned(fb, L, c, y, w):
    y = status_row(fb, L, c, y, w)
    y = replay_banner(fb, L, c, y + 1, w) - W.GAP
    return hairline(fb, L, c, y, w)


# ---------------------------------------------------------------------------------------------
# The list
# ---------------------------------------------------------------------------------------------

def log_row(fb, L, c, r, w, log):
    """LogsFileLabel: the name (text; the open log an inverted block) with a boxed REC while it is
    being written, then "<n> PKTS · <kb>KB · <ago> AGO" in dim, then a dotted divider. Rows stack
    directly (same metrics as a PacketRow without hex). Returns the next row."""
    name, count, size, age = log
    selected = name == OPEN_LOG
    active = name == ACTIVE_LOG
    y = r + 3
    x = c + 2
    tag_w = text_width("REC") + 8 if active else 0
    shown = fit_middle(name, w - 4 - tag_w)
    if selected:
        x = W.badge(fb, x, y, shown, HIGHLIGHT)
    else:
        x = fb.text(x, y, shown, "small", TEXT) + 1
    if active:                      # live state: highlight outline and text (amber on iOS), not inverted
        W.tag_box(fb, x + 4, y, "REC", color=HIGHLIGHT, text_color=HIGHLIGHT)
    detail = "%d PKTS · %dKB" % (count, size // 1024)
    ago = ago_text(age)
    if ago:
        detail += " · " + ago.upper() + " AGO"
    y += W.LINE
    fb.text_fit(c + 2, y, detail, w - 2, "small", DIM)
    y += 7 + 3
    fb.hline(c, y, w, DIM, step=2)
    _tap(fb, c, r, w, y - r, "log:" + name)
    return y + 1


def analyzed_row(fb, L, c, r, w, row):
    """LogsAnalyzedRow: "×count · LABEL" (text) over the hex (dim, iOS cyanDim), both truncated with …,
    NAME on the right, a dotted divider under it. Tap the text = TX, NAME = save. Returns the next
    row."""
    count, label, hex_text = row
    bw = text_width("NAME") + 12
    bx = c + w - bw
    tw = bx - 6 - c
    y = r + 3
    fb.text_fit(c, y, W._upper("×%d · %s" % (count, label)), tw, "small", TEXT)
    fb.text_fit(c, y + W.LINE, hex_text, tw, "small", DIM)          # cyanDim, as PacketRow
    W.button(fb, L, bx, r + 5, bw, "NAME", name="name:" + label)
    y += W.LINE + 7 + 3
    fb.hline(c, y, w, DIM, step=2)
    fb.tap(c, r, bx - 2 - c, y - r, "tx:" + label)
    return y + 1


def packet_subtitle(stamp, rssi, category, address, max_cols):
    """packetSubtitle(): "<time> · RSSI <n> · <category> · <source>" in at most max_cols cells.
    The short source is the one field that tells rows with the same label apart, so it is never
    cut: when the line is too long the category gives way first (truncated with …, or left out when
    fewer than 3 of its characters would show), and only then is the whole line truncated."""
    head = "%s · RSSI %d" % (stamp, rssi)
    src = short_address(address)
    tail = (" · " + src) if src else ""
    full = head + (" · " + category if category else "") + tail
    if text_width(full) <= max_cols or not category:
        return full
    room = vfd.max_chars(max_cols) - len(head) - len(" · ") - len(tail)
    if room >= 3:
        return head + " · " + fit_text(category, room * _ADV - (_ADV - 5)) + tail
    return head + tail


def packet_item(i, sub_cols):
    """Row i of the filtered log as (label, hex, subtitle), the subtitle fitted to sub_cols."""
    k, src, rssi = _ROW_PATTERN[i % len(_ROW_PATTERN)]
    lap = i // len(_ROW_PATTERN)
    if k < 0:
        label, hex_text = NOISE[-k - 1]
    else:
        _, label, hex_text = ANALYZED[k]
    rssi += (lap * 7) % 5 - 2
    t = _ROW_START_S + (i * 37) // 23
    stamp = "%02d:%02d:%02d" % (t // 3600 % 24, t // 60 % 60, t % 60)
    category = "COLOR" if label.startswith(("Single Color", "Dual Color", "Starlight")) else "ANIMATION"
    return label, hex_text, packet_subtitle(stamp, rssi, category, src, sub_cols)


PACKET_ROW_H = 36        # a W.packet_row with hex and subtitle


def filter_rows(fb, L, c, y, w):
    """Type chips, source chips (≤ 12), BAND ONLY."""
    if CATEGORIES:
        y = caption(fb, L, c, y, w, "FILTER TYPES (NONE = ALL)")
        y = W.options(fb, L, c, y, w, CATEGORIES, SELECTED_CATS, name="filter:type")
    if ADDRESSES:
        y = caption(fb, L, c, y, w, "FILTER SOURCE (TAP = ONLY THAT SOURCE)")
        chips = [short_address(a) for a in ADDRESSES[:SOURCE_CHIP_LIMIT]]
        y = W.options(fb, L, c, y, w, chips, {short_address(SELECTED_ADDR)} if SELECTED_ADDR else set(),
                      name="filter:source")
    return W.toggle(fb, L, c, y, w, "BAND ONLY", BAND_ONLY, label_color=DIM)


def detail_rows(fb, L, c, y, w, vis):
    """Everything under the open log, indented as on iOS. vis = (top, bottom) drawing rows of the
    visible window, so only the packet rows in view are drawn (a List does the same)."""
    c, w = c + IND, w - IND
    y = filter_rows(fb, L, c, y, w)
    y = button_row(fb, L, c, y, w, [("REPLAY", TEXT, not REPLAY_ACTIVE, True),
                                    ("SHARE", TEXT, True, False),
                                    ("DELETE", ALARM, True, False)])
    y = button_row(fb, L, c, y, w, [("HIDE PACKETS" if ANALYZING else "ANALYZE", TEXT, True, True),
                                    ("ADD ALL → LIB", TEXT, SUMMARY_UP_TO_DATE, True)])
    if ANALYZING:
        y = wrapped_toggle(fb, L, c, y, w, "HIDE BANDS & PINGS (%d OF %d)" % (NOISE_COUNT, FILTERED_COUNT),
                           HIDE_NOISE)
        rows = ANALYZED if HIDE_NOISE else ANALYZED + [(1, lab, hx) for lab, hx in NOISE]
        if not rows and NOISE_COUNT > 0:
            # guidance in the attention colour (MMTheme.amber), not an error
            y = note_lines(fb, L, c, y + 1, w, "EVERYTHING IN THIS FILTER IS BAND TELEMETRY OR PINGS — "
                           "FLIP THE SWITCH TO SEE IT", color=HIGHLIGHT)
        else:
            y = note_lines(fb, L, c, y + 1, w, "%d UNIQUE · TAP = TX · NAME = ADD" % len(rows))
        y -= W.GAP
        fb.hline(c, y, w, DIM, step=2)
        y += 1
        for row in rows[:ANALYZED_ROW_LIMIT]:
            y = analyzed_row(fb, L, c, y, w, row)
        if len(rows) > ANALYZED_ROW_LIMIT:
            y = note_lines(fb, L, c, y, w, "…and %d more (showing top %d)"
                           % (len(rows) - ANALYZED_ROW_LIMIT, ANALYZED_ROW_LIMIT))
        return y
    y = note_lines(fb, L, c, y + 1, w, "%d PACKETS · TAP = TX" % FILTERED_COUNT)
    y -= W.GAP
    shown = min(FILTERED_COUNT, PACKET_ROW_LIMIT)
    first = max(0, (vis[0] - y) // PACKET_ROW_H - 1)
    last = min(shown, (vis[1] - y) // PACKET_ROW_H + 2)
    for i in range(first, max(first, last)):
        label, hex_text, sub = packet_item(i, w - 2)      # packet_row draws the subtitle at c + 2
        W.packet_row(fb, L, c, y + i * PACKET_ROW_H, w, label, hex_text, sub, hex_color=DIM)
    y += shown * PACKET_ROW_H
    if FILTERED_COUNT > PACKET_ROW_LIMIT:
        y = note_lines(fb, L, c, y, w, "…and %d more (showing first %d)"
                       % (FILTERED_COUNT - PACKET_ROW_LIMIT, PACKET_ROW_LIMIT))
    return y


def log_list(fb, L, c, y, w, vis):
    """The List: every log row, the open one followed by its detail rows. Returns the end row."""
    for log in LOGS:
        y = log_row(fb, L, c, y, w, log)
        if log[0] == OPEN_LOG:
            y = detail_rows(fb, L, c, y, w, vis)
    return y


def empty_state(fb, L, c, y, w):
    """NO LOGS YET — START A SCAN (or LOADING… before the first listing), centred in the space."""
    s = "NO LOGS YET — START A SCAN" if LOGS_LOADED else "LOADING…"
    lines = caption_lines(s, w - 2 * 16 // 3)
    mid = max(y, (y + L.content_bottom) // 2 - len(lines) * W.LINE // 2)
    for i, ln in enumerate(lines):
        fb.text(W._cx(c, w, ln), mid + i * W.LINE, ln, "small", DIM)
    return mid + len(lines) * W.LINE


# ---------------------------------------------------------------------------------------------
# Screen
# ---------------------------------------------------------------------------------------------

def draw(fb, L):
    c, w = L.left, L.width
    scroll = -fb.origin_y           # frame() pushed the content clip with dy = -scroll

    # Status, banner and hairline stay put (iOS keeps them above the List): undo the scroll.
    fb.push_clip(0, L.content_top + scroll, fb.cols, L.content_h, dy=scroll)
    list_top = pinned(fb, L, c, L.content_top, w)
    if not LOGS_LOADED or not LOGS:
        empty_state(fb, L, c, list_top, w)
        fb.pop_clip()
        return None
    fb.pop_clip()

    vis = (list_top + scroll, L.content_bottom + scroll)

    def draw_list(target):
        return log_list(target, L, c, list_top, w, vis)

    t, b = snapped_window(fb, list_top, L.content_bottom, draw_list)
    n = len(fb.taps)
    fb.push_clip(0, t - fb.origin_y, fb.cols, b - t)
    end = draw_list(fb)
    fb.pop_clip()
    fb.taps[n:] = [tp for tp in fb.taps[n:] if tp[3] >= W.TAP_ROWS]

    # The scroll indicator belongs to the list, not to the whole content region.
    fb.push_clip(0, L.content_top + scroll, fb.cols, L.content_h, dy=scroll)
    list_scrollbar(fb, list_top, L.content_bottom - list_top, end - list_top, scroll)
    fb.pop_clip()
    return None
