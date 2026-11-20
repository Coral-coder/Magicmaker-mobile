"""SCAN tab in the VFD look: port of ios/MagicMaker/Views/ScanScreen.swift (narrow layout).

Top to bottom, as on the phone:
    LAST LIGHTS strip (BandPreviewView compact) | hairline | SCAN CONTROLS bar | controls
    (status lines, chip row, CLASS filter, MY MAGICBAND, LIBRARY FILE, buffer + CLR, gesture hint)
    | hairline | live feed (GROUPED sections of PacketRows, or RAW).

Scrolling, as narrowLayout's VStack does it: only the feed takes the screen's scroll (clamped to
its end); the strip, the bar and the controls stay put. The controls panel keeps its natural
height up to 60% of the content region (controlsPanel(maxHeight: size.height * 0.6)), and past
that it scrolls inside its own window (CONTROLS_SCROLL) with its own scroll indicator. Both windows
hide a line that crosses their edge instead of cutting it (snapped_window).

Re-expressed for the grid:
    * the band face is pixel art: a rounded square with five 7x7 LED zones (Z1 bottom-left, Z2
      top-left, Z3 centre, Z4 top-right, Z5 bottom-right); each distinct colour gets a fill pattern
      (solid, checker, ring, stripes) and a legend line names the colours, since packet colours are
      never drawn as real RGB. Unlit zones are a dim dotted outline.
    * the compact strip's two text rows become four (title, classification, hex, colour legend) so
      nothing is cut to a few characters at 207 columns; the hex keeps its middle truncation.
    * the horizontally scrolling chip row wraps onto a second row, which the CLASS n/8 menu button
      shares; switch-like chips are [OPTION]s (selected inverted), plain chips are buttons.
    * the controls bar summary goes on a second line under "HIDE SCAN CONTROLS".
    * the tinted MY MAGICBAND and LIBRARY FILE blocks become dim-bordered panels.
    * the one-line gesture hint (shrunk to fit on iOS) wraps instead.
    * swipe actions, the long-press sheet, alerts and toasts are not drawn.

Mock state: scanning with Bluetooth ready, a log recording, the relay linked (TELEMETRY is built
from this state by telemetry_line(), a port of TelemetryBar.line; for the default state it equals
render_previews.DEFAULT_TELEMETRY, the line every tab shares; a state variant reassigns
TELEMETRY = telemetry_line()),
controls open and MY MAGICBAND folded (the app's defaults),
WAND folded in the feed. Labels and hex are real ones from tools/parity vectors
(ios/ParityCheck/vectors.json) and PresetCatalog; addresses are the last 8 hex characters of
CoreBluetooth UUIDs, as shortAddress() prints them.
"""

import widgets as W
import vfd
from vfd import UNLIT, HIGHLIGHT, TEXT, DIM, ALARM, text_width, fit_text

chevron_up = W.chevron_up


TAB = "scan"
TITLE = "SCAN"

# ---------------------------------------------------------------------------------------------
# Mock state (what ScanEngine / MagicStore / TxEngine would publish)
# ---------------------------------------------------------------------------------------------

SCAN_ACTIVE = True
BLUETOOTH_STATUS = "Bluetooth ready"
RECORDING = True
LOG_NAME = "scan_2026-11-19T21-42-07.csv"        # SessionLog.fileName(for:)
TX_STATUS = "Scanning"                             # TxEngine.status while the scan runs
PACKETS_HEARD = 1284                               # same as the telemetry line's RX:1284
LIGHTS_HEARD = 37

#: scan.lastLightHex and its decode: the newest packet that lights the band (here the newest
#: ANIMATIONS row). zones = colour names of Z1..Z5 (BandEffectModel.perLed through the EMCOT
#: palette names; None = unlit).
LAST_LIGHT = {
    "hex": "8301CC03000100E100E911006F0F554258F44882D1460208D06500B3",
    "label": "Cross-Fade: Red / Blue",                 # MagicClassifier.classify(hex).label
    "zones": ["Red", "Red", "Blue", "Red", "Red"],    # perLed [0x15, 0x15, 0x02, 0x15, 0x15]
}

VIEW_MODE = "GROUPED"              # GROUPED | RAW
SHOW_CONTROL_ONLY = True           # chip shows SHOW-CTRL (on) / ALL RAW (off)
CONTROLS_COLLAPSED = False         # ios.scan_controls_collapsed (default false)
CONTROLS_CAP = 0.6                 # controlsPanel(maxHeight: size.height * 0.6)
CONTROLS_SCROLL = 0                # the controls panel's own scroll offset in rows (when capped)
BAND_MENU_COLLAPSED = True         # band_menu_collapsed (default true)
COLLAPSED_SECTIONS = {"WAND"}      # scan_collapsed_sections

SECTIONS = ["WAND", "COLORS", "ANIMATIONS", "CONTROL", "PING", "INTERROGATE", "SHOWS", "UNKNOWN"]
VISIBLE_SECTIONS = set(SECTIONS)   # CLASS filter

MY_BAND = "5C0E8B47-2D1A-4F3C-9E06-11B4A7D3901B"
BAND_ADDRESSES = [MY_BAND]
SAVED_BAND_PACKETS = 14
LIBRARY_FILE = "magicmaker_library.json"

# Park transmitters and guests' wands (CoreBluetooth identifiers).
SHOW_A = "0B6F2E91-7C44-4D0A-B8E2-5A90C41E9A07"
SHOW_B = "D2F17A3C-9B05-4E68-A1C7-3E2F7B2D5F13"
SHOW_C = "8A43C6E0-1F7D-4B92-9D35-C8B1E06A3B98"
WAND_1 = "4E9D0A72-63B8-4C1F-8A2E-F07D51F8C2D4"
WAND_2 = "B71C5E08-2A96-47D3-BE41-9D6A3C70E85A"
WAND_3 = "19E4B6D3-C870-4A25-93F1-6B2E8F4D17C6"

#: Recently heard sources for "HEARD (TAP TO TAG):" (address, rssi, count), newest first; iOS
#: lists up to 8 (prefix(8)). Every source in FEED is here.
SEEN = [
    (MY_BAND, -41, 212),
    (SHOW_A, -58, 389),
    (SHOW_B, -66, 241),
    (WAND_1, -71, 57),
    (WAND_3, -74, 31),
    (SHOW_C, -77, 133),
    (WAND_2, -83, 12),
]

# The rest of what TelemetryBar reads (scan.autoResponsesSent, scan.autoEnabled, the loops, the relay).
AUTO_RESPONSES_SENT = 3
AUTO_ENABLED = True                # the AUTO tab's rule engine is armed
WAND_LOOP = False
TX_LOOP = True                     # the TX tab's loop is running
RELAY_LINKED = True
REPLAY = (214, 2433)               # (progress, total) while a replay runs (the LOGS tab's replay)


def telemetry_line():
    """Port of TelemetryBar.line from the mock state above, so a state variant keeps the header in
    step with the screen (e.g. SCAN:OFF). Assign the result to TELEMETRY after changing state."""
    if BLUETOOTH_STATUS != "Bluetooth ready":
        radio = "BLE:OFF"
    elif SCAN_ACTIVE:
        radio = "BLE:SCAN"
    else:
        radio = "BLE:LINK"
    parts = ["MM/RF " + radio, "RX:%d" % PACKETS_HEARD, "TX-AUTO:%d" % AUTO_RESPONSES_SENT]
    for on, tok in ((SCAN_ACTIVE, "SCAN:ON"), (AUTO_ENABLED, "AUTO:ARM"), (RECORDING, "LOG:REC"),
                    (WAND_LOOP, "WAND:LOOP"), (TX_LOOP, "TX:LOOP"), (RELAY_LINKED, "RELAY:LINK"),
                    (LIGHTS_HEARD > 0, "LIGHTS:%d" % LIGHTS_HEARD)):
        if on:
            parts.append(tok)
    if REPLAY:
        parts.append("REPLAY:%d/%d" % REPLAY)
    return " | ".join(parts)


TELEMETRY = telemetry_line()


def _pkt(label, hex_text, rssi, address, band=False):
    return {"label": label, "hex": hex_text, "rssi": rssi, "address": address, "band": band,
            "note": "Heard"}


#: livePackets grouped by LivePacketSort (section order, newest first within a section).
FEED = [
    ("WAND", [
        _pkt("Starlight: Random (#1F)", "8301CF0B00C020224EAC7807866F1F", -71, WAND_1),
        _pkt("Starlight: Pink (#08)", "8301CF0B00C42922EFD819F22A6208", -83, WAND_2),
        _pkt("Starlight: White (#1B)", "8301CF0B00C42922EFD819F22A621B", -74, WAND_3),
        _pkt("Starlight: Blue (#02)", "8301CF0B00C020224EAC7807866E82", -71, WAND_1),
        _pkt("Starlight: Red (#15)", "8301CF0B00C42922EFD819F22A6215", -79, WAND_3),
        _pkt("Starlight: Cyan (#00)", "8301CF0B00C020224EAC7807866F80", -86, WAND_2),
    ]),
    ("COLORS", [
        _pkt("Single Color: Red", "8301CC03000100E100E90500090E15B0", -58, SHOW_A),
        _pkt("Dual Color: Yellow Orange centre / Blue corners", "8301CC03000100E100E90600060F8F82B3",
             -61, SHOW_A),
        _pkt("Single Color: White", "8301CC03000100E100E90500060EFBB3", -66, SHOW_B),
        _pkt("Single Color: Cyan", "8301CC03000100E100E90500090E00B0", -59, SHOW_A),
        _pkt("Single Color: Blue", "8301CC03000100E100E90500090E02B0", -67, SHOW_B),
        _pkt("Single Color: Pink", "8301E905002E0EE8B0", -77, SHOW_C),
    ]),
    ("ANIMATIONS", [
        _pkt("Cross-Fade: Red / Blue", LAST_LIGHT["hex"], -57, SHOW_A),
        _pkt("Rotating Colors (E912)", "8301CC03000100E100E91200060FA2A2A4A4A230D037F4D2460064FCB3",
             -64, SHOW_B),
        _pkt("Effect: Circle", "8301CC03000100E100E90B0B060F5C5D48A5D14532B3", -60, SHOW_A),
        _pkt("5-Zone Colors", "8301CC03000100E100E90900060FAFB5B9A2A1B3", -76, SHOW_C),
        _pkt("Repeating Fade (E914)", "8301E100E91400030F5D5458F44882D0650AD1460228307B00B0", -68, SHOW_B),
    ]),
    ("CONTROL", [
        _pkt("Twinkle / Flash (E90E)", "8301E100E90E00040FB5A2B9AFA159190B48AEB0", -63, SHOW_B),
        _pkt("Show Control: E907", "8301E200E90700220F555942B0", -59, SHOW_A),
        _pkt("Custom RGB Color", "8301CC03000100E100E908000ED2557E2800B3", -78, SHOW_C),
    ]),
    ("PING", [
        _pkt("Signal Beacon", "8301CC03000000", -41, MY_BAND, band=True),
        _pkt("Show Ping (2341)", "8301CC03234100", -66, SHOW_B),
        _pkt("Interaction Ping", "8301CC030000", -43, MY_BAND, band=True),
    ]),
    ("INTERROGATE", [
        _pkt("Wake Ping", "8301CC03000100", -58, SHOW_A),
    ]),
    ("SHOWS", [
        _pkt("Lightning", "8301CC03000100E100E90C000F0F5D465BF00532374895", -62, SHOW_A),
    ]),
]

# ---------------------------------------------------------------------------------------------
# Small helpers (Swift: the same names on the VFD screen type)
# ---------------------------------------------------------------------------------------------

_ADV = 6
FACE = 37                 # band face: FACE x FACE cells
LED = 7                   # one LED zone: LED x LED cells
_LED_AT = (4, 15, 26)     # zone offsets inside the face (left/top, centre, right/bottom)
#: Z1..Z5 as (column, row) in the face's 3 x 3 spots: bottom-left, top-left, centre, top-right,
#: bottom-right (BandPreviewView's point order).
_ZONE_SPOT = [(0, 2), (0, 0), (1, 1), (2, 0), (2, 2)]
N_PATTERNS = 5


def short_address(address):
    """shortAddress(): the last 8 characters, uppercased; empty stays empty."""
    return address[-8:].upper() if address else ""


def live_subtitle(pkt, include_note=True):
    """Port of liveSubtitle(): RSSI, the short source id, BAND for a tagged source, then the note."""
    text = "RSSI %d" % pkt["rssi"]
    if pkt["address"]:
        text += " · " + short_address(pkt["address"])
    if pkt["band"]:
        text += " · BAND"
    if include_note and pkt["note"]:
        text += " | " + pkt["note"]
    return text


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


def pattern(fb, x, y, kind, size=LED, color=HIGHLIGHT):
    """A round size x size LED / legend swatch filled with pattern `kind` (W.led, shared with
    LAB's band preview): 0 solid, 1 checker, 2 ring with a centre dot, 3 horizontal stripes,
    4 vertical stripes; None = unlit (a dotted dim ring)."""
    W.led(fb, x, y, kind, size, color)


def zone_patterns(zones):
    """Per zone pattern index (None for unlit) and the legend [(pattern, NAME)], in Z1..Z5
    first-appearance order."""
    kinds, legend, seen = [], [], {}
    for name in zones:
        if not name or name.lower() == "off":
            kinds.append(None)
            continue
        key = name.upper()
        if key not in seen:
            seen[key] = len(seen)
            legend.append((seen[key], key))
        kinds.append(seen[key])
    if any(k is None for k in kinds):
        legend.append((None, "OFF"))
    return kinds, legend


def band_face(fb, x, y, kinds):
    """Pixel band face: a FACE x FACE rounded square (dim) with the five LED zones."""
    e = FACE - 1
    fb.hline(x + 2, y, FACE - 4, DIM)
    fb.hline(x + 2, y + e, FACE - 4, DIM)
    fb.vline(x, y + 2, FACE - 4, DIM)
    fb.vline(x + e, y + 2, FACE - 4, DIM)
    for dx, dy in ((1, 1), (e - 1, 1), (1, e - 1), (e - 1, e - 1)):
        fb.set(x + dx, y + dy, DIM)
    for z, (sc, sr) in enumerate(_ZONE_SPOT):
        pattern(fb, x + _LED_AT[sc], y + _LED_AT[sr], kinds[z] if z < len(kinds) else None)


def tokens(fb, x, r, toks, color, limit):
    """' | '-separated tokens drawn as the telemetry line draws them (a 9-row bar, 4 empty cells
    each side), stopping with … at column `limit` (exclusive). Returns the end column."""
    for i, tok in enumerate(toks):
        if i:
            bar = x + 3
            nxt = bar + 5
            if nxt + text_width(tok) > limit:
                if x + text_width(vfd.ELLIPSIS) <= limit:
                    x = fb.text(x, r, vfd.ELLIPSIS, "small", color)
                return x
            fb.vline(bar, r - 1, 9, color)
            x = nxt
        if x + text_width(tok) > limit:
            return fb.text_fit(x, r, tok, limit - x, "small", color)
        x = fb.text(x, r, tok, "small", color)
    return x


def _tap(fb, c, r, w, h, name):
    """Tap rectangle at least W.TAP_ROWS tall, grown evenly around the visual (as widgets do)."""
    if h < W.TAP_ROWS:
        r -= (W.TAP_ROWS - h) // 2
        h = W.TAP_ROWS
    fb.tap(c, r, w, h, name)


def snapped_window(fb, top, bottom, draw_fn, cols=None):
    """Rows (t, b) of the screen window [top, bottom) a scrolling block may use without cutting a
    line of text: the block is drawn once on a scratch buffer (same origin as fb), and a band of
    lit rows that crosses the top or the bottom edge is left out, so a part-scrolled line is
    hidden instead of being cut mid-glyph. draw_fn(target, edge) is called with edge "top" and
    "bottom" (one probe per edge, so a probe may join a rule to the line it belongs to for one
    edge only). cols = (c0, c1) looks only at those columns, so the sides of a box running past the
    edge do not count as one tall band. (tx.py / logs.py have the same helper without edges and
    cols; the reviewer asked for one public copy in widgets.py.)"""
    c0, c1 = cols or (0, fb.cols)

    def probe(edge):
        buf = vfd.FrameBuffer(fb.cols, fb.rows)
        buf.push_clip(0, 0, fb.cols, fb.rows, dy=fb.origin_y)
        draw_fn(buf, edge)
        buf.pop_clip()
        return lambda r: 0 <= r < fb.rows and any(buf.cells[r * fb.cols + c0:r * fb.cols + c1])

    t, b = top, bottom
    lit = probe("top")
    if lit(t - 1) and lit(t):
        while t < b and lit(t):
            t += 1
    lit = probe("bottom")
    if lit(b - 1) and lit(b):
        while b > t and lit(b - 1):
            b -= 1
    return t, b


def list_scrollbar(fb, top, h, total, scroll):
    """A scroll indicator in the last screen column over screen rows top .. top+h-1: a dotted dim
    track and a solid dim thumb, only when the block is taller than its window (widgets.scrollbar
    for one window of the screen; same as tx.py / logs.py)."""
    if total <= h:
        return
    col = fb.cols - 1
    fb.vline(col, top, h, DIM, step=2)
    th = max(6, h * h // total)
    ty = top + (h - th) * max(0, min(scroll, total - h)) // max(1, total - h)
    fb.vline(col, ty, th, DIM)


def windowed(fb, top, h, scroll, draw_fn, cols=None, probe_fn=None):
    """Draw draw_fn(fb) scrolled by `scroll` rows inside the screen rows [top, top + h), hiding
    lines cut by either edge (snapped_window, which looks at probe_fn(target, edge) when given,
    else at draw_fn) and dropping the taps that end up shorter than W.TAP_ROWS. fb must have
    origin 0 (screen rows). Returns (t, b), the rows actually used."""
    fb.push_clip(0, top, fb.cols, h, dy=-scroll)
    t, b = snapped_window(fb, top, top + h, probe_fn or (lambda target, edge: draw_fn(target)), cols)
    n = len(fb.taps)
    fb.push_clip(0, t - fb.origin_y, fb.cols, b - t)
    draw_fn(fb)
    fb.pop_clip()
    fb.pop_clip()
    fb.taps[n:] = [tp for tp in fb.taps[n:] if tp[3] >= W.TAP_ROWS]
    return t, b


def chip_width(label, icon=False, kind="action", chevron=False):
    """Width of a chip: buttons pad 6 cells each side of their ink, options hug [LABEL]."""
    if kind in ("on", "off"):
        return text_width("[" + label + "]")
    return text_width(label) + (9 if icon else 0) + (11 if chevron else 0) + 12


def chip(fb, x, y, label, kind="action", icon=None, chevron=False, enabled=True):
    """One ScanChip on a CTRL_H row at (x, y). kind "action": a button (highlight border, text
    label) with an optional 5 x 7 icon ("pause" / "play") before the label or a down chevron after
    it (menu); "on": an inverted block (selected option); "off": [LABEL] with dim brackets.
    Returns the column after it."""
    label = label.upper()
    w = chip_width(label, icon is not None, kind, chevron)
    ty = y + W.CTRL_TEXT
    if kind == "on":
        fb.fill(x, y + 1, w, W.CTRL_H - 2, HIGHLIGHT)
        fb.text(x + _ADV, ty, label, "small", UNLIT)
    elif kind == "off":
        fb.text(x, ty, "[", "small", DIM)
        fb.text(x + _ADV, ty, label, "small", TEXT)
        fb.text(x + w - 5, ty, "]", "small", DIM)
    else:
        fb.box(x, y, w, W.CTRL_H, HIGHLIGHT if enabled else DIM)
        tx = x + 6
        if icon == "pause":
            fb.fill(tx, ty, 2, 7, TEXT)
            fb.fill(tx + 3, ty, 2, 7, TEXT)
            tx += 9
        elif icon == "play":
            for i in range(4):
                fb.vline(tx + 1 + i, ty + i, 7 - 2 * i, TEXT)
            tx += 9
        end = fb.text(tx, ty, label, "small", TEXT if enabled else DIM)
        if chevron:
            W.chevron(fb, end + 3, ty + 1, False, TEXT)
    _tap(fb, x - 2, y, w + 4, W.CTRL_H, "chip:" + label)
    return x + w


def text_button(fb, L, right, y, label, color=HIGHLIGHT, name=None):
    """A right-aligned compact button ending on column `right` (inclusive) on a CTRL_H row: the
    app's textButton (REMOVE, TAG, CLR, DELETE ALL). color=ALARM draws a destructive one (alarm
    border and label; on a red-ish base a solid highlight block with the label cut out).
    Returns its left column."""
    label = label.upper()
    w = text_width(label) + 12
    x = right - w + 1
    ty = y + W.CTRL_TEXT
    if color == ALARM:
        W.button(fb, L, x, y, w, label, alarm=True, name=name or "button:" + label)
        return x
    else:
        fb.box(x, y, w, W.CTRL_H, color)
        fb.text(x + 6, ty, label, "small", TEXT)
    _tap(fb, x, y, w, W.CTRL_H, name or "button:" + label)
    return x


# ---------------------------------------------------------------------------------------------
# Sections of the screen
# ---------------------------------------------------------------------------------------------

def last_lights_strip(fb, L, c, y, w):
    """BandPreviewView(compact: true, title: "LAST LIGHTS · #n") or LAST LIGHTS · NONE HEARD YET.
    Returns the next free row."""
    hex_text = (LAST_LIGHT or {}).get("hex", "").strip()
    if not hex_text:
        fb.text_fit(c, y + 1, "LAST LIGHTS · NONE HEARD YET", w, "small", DIM)
        return y + 1 + W.LINE
    kinds, legend = zone_patterns(LAST_LIGHT.get("zones", []))
    band_face(fb, c, y + 1, kinds)
    tx = c + FACE + 7
    tw = c + w - tx
    r = y
    fb.text_fit(tx, r, "LAST LIGHTS · #%d" % LIGHTS_HEARD, tw, "small", DIM)
    r += W.LINE
    lit = any(k is not None for k in kinds)
    fb.text_fit(tx, r, W._upper(LAST_LIGHT.get("label", "")), tw, "small", HIGHLIGHT if lit else DIM)
    r += W.LINE
    fb.text(tx, r, fit_middle(hex_text, tw), "small", DIM)
    r += W.LINE
    # colour legend: pattern swatch + colour name, as many as fit
    x = tx
    for i, (kind, name) in enumerate(legend):
        need = LED + 4 + text_width(name)
        if x + need > c + w:
            if x + LED + 4 + text_width(name[:1] + vfd.ELLIPSIS) <= c + w:
                pattern(fb, x, r, kind)
                fb.text_fit(x + LED + 4, r, name, c + w - x - LED - 4, "small", TEXT)
            break
        pattern(fb, x, r, kind)
        x = fb.text(x + LED + 4, r, name, "small", TEXT if kind is not None else DIM) + 7
    return y + FACE + 2                         # no tap: the iOS strip has no action


def hairline(fb, L, c, y, w):
    """The 0.5 pt panel line between blocks: a solid dim rule with 3 empty rows each side."""
    fb.hline(c, y + 3, w, DIM)
    return y + 7


def controls_bar(fb, L, c, y, w):
    """The fold bar: chevron + HIDE SCAN CONTROLS / SCAN CONTROLS (highlight), the summary
    SCAN:ON | LOG:REC | RX:n (dim) on the line under it. Returns the next free row: the top row of
    the controls panel window when open (right under the bar's dotted edge), else the row for the
    hairline."""
    r = y + 2
    if CONTROLS_COLLAPSED:
        W.chevron(fb, c, r, False, DIM)        # fold chevrons are dim, as W.section's
        title = "SCAN CONTROLS"
    else:
        chevron_up(fb, c, r)
        title = "HIDE SCAN CONTROLS"
    x = c + 11
    fb.text_fit(x, r, title, c + w - x, "small", HIGHLIGHT)
    parts = ["SCAN:ON" if SCAN_ACTIVE else "SCAN:OFF"]
    if RECORDING:
        parts.append("LOG:REC")
    parts.append("RX:%d" % PACKETS_HEARD)
    tokens(fb, x, r + W.LINE, parts, DIM, c + w)
    rule = r + W.LINE + 7 + 3
    _tap(fb, c, y, w, rule - y, "controls")
    if CONTROLS_COLLAPSED:
        return rule - 3                         # the hairline under the bar follows directly
    fb.hline(c, rule, w, DIM, step=2)           # the bar's panel edge over the open controls
    return rule + 1


def status_lines(fb, L, c, y, w):
    """Scan status (highlight when scanning with Bluetooth ready), the open log, the TX status."""
    if not SCAN_ACTIVE:
        text, color = "Tap SCAN to start", DIM
    elif BLUETOOTH_STATUS == "Bluetooth ready":
        text, color = "Scanning · keep app open", HIGHLIGHT
    else:
        text, color = "Scan on · " + BLUETOOTH_STATUS, ALARM
    y = W.status_line(fb, L, c, y, w, text, color=color)
    if RECORDING and LOG_NAME:
        y = W.status_line(fb, L, c, y, w, "LOG · " + LOG_NAME)
    warn = TX_STATUS in ("No relay linked — nothing sent", "Transmit failed — check relay")
    return W.status_line(fb, L, c, y, w, "STATUS: " + TX_STATUS, color=ALARM if warn else DIM)


def chip_rows(fb, L, c, y, w):
    """PAUSE/SCAN, LOG, GROUPED, RAW, SHOW-CTRL/ALL RAW, then the CLASS n/8 menu button, flowing
    left to right and wrapping (iOS scrolls this row sideways). Returns the next free row."""
    items = [
        ("PAUSE" if SCAN_ACTIVE else "SCAN", "action", "pause" if SCAN_ACTIVE else "play", False),
        ("LOG:ON" if RECORDING else "LOG", "action", None, False),
        ("GROUPED", "on" if VIEW_MODE == "GROUPED" else "off", None, False),
        ("RAW", "on" if VIEW_MODE == "RAW" else "off", None, False),
        ("SHOW-CTRL" if SHOW_CONTROL_ONLY else "ALL RAW", "on" if SHOW_CONTROL_ONLY else "off", None,
         False),
        ("CLASS %d/%d" % (len(VISIBLE_SECTIONS), len(SECTIONS)), "action", None, True),
    ]
    x = c
    for label, kind, icon, chev in items:
        cw = chip_width(label, icon is not None, kind, chev)
        if x > c and x + cw > c + w:
            x, y = c, y + W.CTRL_H + W.GAP
        x = chip(fb, x, y, label, kind, icon, chev) + W.OPT_GAP
    return y + W.CTRL_H + W.GAP


def band_section(fb, L, c, y, w, glue=None):
    """MY MAGICBAND: a dim panel; the header line (chevron, title, 3-digit count) folds the
    details: tagged bands with REMOVE, saved band packets with DELETE ALL, the heard list with
    TAG / UNTAG. Returns the next free row."""
    ic, iw = c + 4, w - 8
    r = y + W.CTRL_TEXT
    W.chevron(fb, ic, r, BAND_MENU_COLLAPSED, DIM)
    cnt = "%03d" % len(BAND_ADDRESSES)
    fb.text_right(ic + iw - 1, r, cnt, "small", DIM)
    fb.text_fit(ic + 11, r, "MY MAGICBAND", iw - 11 - text_width(cnt) - 6, "small", HIGHLIGHT)
    _tap(fb, c, y, w, W.CTRL_H, "section:MY MAGICBAND")
    end = y + W.CTRL_H
    if not BAND_MENU_COLLAPSED:
        row = end
        right = ic + iw - 1
        if not BAND_ADDRESSES:
            fb.text_fit(ic, row + W.CTRL_TEXT, "NONE SET — PICK FROM HEARD", iw, "small", DIM)
            row += W.LINE + 4
        for addr in BAND_ADDRESSES:
            bx = text_button(fb, L, right, row, "REMOVE", name="band:remove:" + short_address(addr))
            fb.text_fit(ic, row + W.CTRL_TEXT, short_address(addr), bx - ic - 6, "small", HIGHLIGHT)
            row += W.CTRL_H + W.GAP
        saved = "SAVED BAND PACKETS: %d" % SAVED_BAND_PACKETS
        if SAVED_BAND_PACKETS > 0:
            if text_width(saved) + 6 + text_width("DELETE ALL") + 12 > iw:
                # too narrow for both (207 columns): the count keeps its line, the button wraps
                fb.text_fit(ic, row + W.CTRL_TEXT, saved, iw, "small", DIM)
                row += W.LINE + 2
                text_button(fb, L, right, row, "DELETE ALL", color=ALARM)
            else:
                lim = text_button(fb, L, right, row, "DELETE ALL", color=ALARM) - 6
                fb.text_fit(ic, row + W.CTRL_TEXT, saved, lim - ic, "small", DIM)
        else:
            fb.text_fit(ic, row + W.CTRL_TEXT, saved, iw, "small", DIM)
        row += W.CTRL_H + W.GAP
        seen = SEEN[:8]
        if seen:
            fb.text_fit(ic, row + W.CTRL_TEXT, "HEARD (TAP TO TAG):", iw, "small", DIM)
            row += W.LINE + 2
            for addr, rssi, count in seen:
                tagged = addr in BAND_ADDRESSES
                bx = text_button(fb, L, right, row, "UNTAG" if tagged else "TAG",
                                 name="band:tag:" + short_address(addr))
                line = "%s  %ddBm ·%d" % (short_address(addr), rssi, count)
                fb.text_fit(ic, row + W.CTRL_TEXT, line, bx - ic - 6, "small",
                            HIGHLIGHT if tagged else DIM)
                row += W.CTRL_H + W.GAP
        end = row + 1
    fb.box(c, y - 2, w, end - y + 4, DIM)
    # snapping probes (column c + 2 is empty in the box): at the bottom edge the top border
    # goes with the header line, at the top edge the bottom border goes with the last line
    if glue == "bottom":
        fb.vline(c + 2, y - 2, 6, DIM)
    elif glue == "top":
        fb.vline(c + 2, end - 4, 6, DIM)
    return end + 2 + W.GAP


def library_section(fb, L, c, y, w, glue=None):
    """LIBRARY FILE (FILES APP · EDITABLE): a titled dim panel with the Files-app path (up to
    two lines) and EXPORT / IMPORT. Returns the next free row."""
    ic, ir, iw = W.panel_inner(c, y, w, True)
    # uppercased like every other line here (the LOG line uppercases its file name too)
    path = W._upper("Files app → MagicMaker → " + LIBRARY_FILE)
    lines = vfd.wrap_text(path, iw)[:2]
    if len(vfd.wrap_text(path, iw)) > 2:
        lines[1] = fit_text(lines[1] + " …", iw)
    r = ir + 1
    for ln in lines:
        fb.text(ic, r, ln, "small", DIM)
        r += W.LINE
    r += 2
    x = ic
    for lab in ("EXPORT", "IMPORT"):
        x = chip(fb, x, r, lab) + W.OPT_GAP
    end = r + W.CTRL_H + 2
    if glue == "top":                           # snapping probe: bottom border with the chips
        fb.vline(c + 2, end - 2, 3, DIM)
    return W.panel(fb, L, c, y, w, end - y + 1, "LIBRARY FILE (FILES APP · EDITABLE)")


def buffer_row(fb, L, c, y, w):
    """BUF UNIQUE n (or BUF RAW n) with CLR on the right. Returns the next free row."""
    n = sum(len(p) for _, p in FEED) if VIEW_MODE == "GROUPED" else len(_raw_packets(False))
    text = ("BUF RAW %d" if VIEW_MODE == "RAW" else "BUF UNIQUE %d") % n
    bx = text_button(fb, L, c + w - 1, y, "CLR")
    fb.text_fit(c, y + W.CTRL_TEXT, text, bx - c - 6, "small", DIM)
    return y + W.CTRL_H + W.GAP


def controls_column(fb, L, c, y, w, glue=None):
    """Android's order: status, the button row, the CLASS filter, My MagicBand, the library file,
    the buffer counter with CLR, the gesture hint."""
    y = status_lines(fb, L, c, y, w)
    y = chip_rows(fb, L, c, y + 3, w)
    y = band_section(fb, L, c, y + 5, w, glue)
    y = library_section(fb, L, c, y + 4, w, glue)
    y = buffer_row(fb, L, c, y + 1, w)
    return hint_lines(fb, L, c, y + 2, w, "TAP REPLAY · HOLD MENU · SWIPE ← DEL · SWIPE → TX/TAG")


def hint_lines(fb, L, c, y, w, s, sep=" · "):
    """The gesture hint (one line shrunk to fit on iOS): wrapped only at its ' · ' separators by
    W.token_lines, the separator dropped at a break (as TX and LOGS wrap theirs). Returns the row
    after the last line."""
    for ln in W.token_lines(s, w, sep):
        fb.text(c, y, ln, "small", DIM)
        y += W.LINE
    return y


def _raw_packets(filtered=True):
    """Every advertisement newest first (the mock interleaves the sections)."""
    out = []
    lists = [list(p) for _, p in FEED]
    secs = [s for s, _ in FEED]
    i = 0
    while any(lists):
        k = i % len(lists)
        if lists[k]:
            pkt = lists[k].pop(0)
            if not filtered or secs[k] in VISIBLE_SECTIONS:
                out.append(pkt)
        i += 1
    return out


def feed(fb, L, c, y, w, glue=None):
    """GROUPED: MMListSectionHeader (chevron, title, 3-digit count) per visible section, its
    PacketRows unless folded; RAW: every advert. Band sources are selected rows. Empty buffer:
    LISTEN 0x0183 MANUFACTURER, centred in the space left. Returns the next free row.
    glue = "top" / "bottom" (snapping probes only) also lights column 0 from a section title down
    to its rule (both edges) and, for the top edge, from a row's last text line down to its
    divider, so a window edge hides a rule or divider together with the line it belongs to
    instead of leaving it alone under the hairline (a row may still end at the bottom edge
    without its divider)."""
    def row(y, pkt):
        nxt = W.packet_row(fb, L, c, y, w, pkt["label"], pkt["hex"], live_subtitle(pkt),
                           selected=pkt["band"])
        if glue == "top":
            fb.vline(0, nxt - W.LINE, W.LINE, DIM)          # subtitle caps .. divider
        return nxt

    total = sum(len(p) for _, p in FEED)
    if total == 0:
        s = "LISTEN 0x0183 MANUFACTURER"
        mid = max(y, (y + L.content_bottom) // 2 - 4)
        fb.text(W._cx(c, w, s), mid, s, "small", DIM)
        return mid + W.LINE
    if VIEW_MODE == "RAW":
        for pkt in _raw_packets():
            y = row(y, pkt)
        return y
    first = True
    for sec, pkts in FEED:
        if sec not in VISIBLE_SECTIONS or not pkts:
            continue
        folded = sec in COLLAPSED_SECTIONS
        # the first header sits under the hairline, not SECTION_GAP below it
        top = y - (W.SECTION_GAP - W.GAP) + 2 if first else y + 1
        y = W.section(fb, L, c, top, w, sec, count=len(pkts), collapsed=folded)
        if glue:
            fb.vline(0, y - W.SECTION_H - W.GAP, 10, DIM)    # title caps .. rule
        first = False
        if folded:
            continue
        y -= W.GAP + 2
        for pkt in pkts:
            y = row(y, pkt)
    return y


PANEL_PAD = 4             # rows of padding at the top of the controls panel (scrolls with it)


def _end_row(draw_fn, L):
    """The row draw_fn returns, drawn on a throwaway buffer (its natural end)."""
    return draw_fn(vfd.FrameBuffer(L.cols, L.rows))


def controls_panel(fb, L, c, top, w):
    """controlsPanel(maxHeight: size.height * 0.6): the controls column at its natural height, or
    capped at 60% of the content region (never under 120 pt) and scrolled by CONTROLS_SCROLL
    inside that window, with its own scroll indicator. fb has origin 0. Returns the row after the
    window (where the hairline goes)."""
    def draw_col(target):
        return controls_column(target, L, c, top + PANEL_PAD, w)

    def probe_col(target, edge):
        return controls_column(target, L, c, top + PANEL_PAD, w, glue=edge)

    natural = _end_row(draw_col, L) - top
    dev = L.device
    cap = max(vfd._round(CONTROLS_CAP * L.content_h), -(-120 * dev.scale // dev.pitch))
    h = min(natural, cap)
    off = max(0, min(CONTROLS_SCROLL, natural - h))
    # look between the panel borders, so the MY MAGICBAND / LIBRARY FILE box sides do not make
    # each box one tall band; the probes keep a box border with the line next to it
    t, b = windowed(fb, top, h, off, draw_col, cols=(c + 2, c + w - 2), probe_fn=probe_col)
    list_scrollbar(fb, top, b - top, natural, off)
    return b


def feed_window(fb, L, c, top, w, scroll):
    """The live feed in screen rows [top, L.content_bottom), scrolled by `scroll` (clamped to the
    feed's length, as a List stops at its end), with its scroll indicator. fb has origin 0."""
    y0 = top + 4              # the feed's first line keeps its old place under the hairline

    def draw_feed(target):
        return feed(target, L, c, y0, w)

    def probe_feed(target, edge):
        return feed(target, L, c, y0, w, glue=edge)

    view = L.content_bottom - top
    total = _end_row(draw_feed, L) - top
    off = max(0, min(scroll, total - view))
    windowed(fb, top, view, off, draw_feed, probe_fn=probe_feed)
    list_scrollbar(fb, top, view, total, off)


def draw(fb, L):
    """narrowLayout: a VStack of lastLightsStrip, hairline, controlsBar, controlsPanel (capped,
    scrolls inside), hairline and the feed. Only the feed takes the screen's scroll; everything
    above it stays put, as TX and LOGS pin their controls."""
    c, w = L.left, L.width
    scroll = -fb.origin_y           # frame() pushed the content clip with dy = -scroll
    fb.push_clip(0, L.content_top + scroll, fb.cols, L.content_h, dy=scroll)   # origin 0 again
    y = last_lights_strip(fb, L, c, L.content_top, w)
    y = hairline(fb, L, c, y, w)
    y = controls_bar(fb, L, c, y, w)
    if not CONTROLS_COLLAPSED:
        y = controls_panel(fb, L, c, y, w)
    y = hairline(fb, L, c, y, w)
    feed_window(fb, L, c, y - 3, w, scroll)     # the window starts right under the hairline
    fb.pop_clip()
    return None                     # no full-height scrollbar: the windows draw their own
