"""MAP tab in the VFD look: port of ios/MagicMaker/Views/MapScreen.swift.

Top to bottom, as on the phone:
    CAPTURE MAP with "<n> PTS · <n> TX" and REFRESH (the screen title row) | the mode bar
    CAPTURES / TRANSMITTERS / BOTH | hairline | the map: a pin per capture point (where the phone
    was when it heard packets), and per transmitter estimate a pin with its uncertainty halo; the
    tapped pin's title and details in a panel over the bottom of the map (× closes it).
    NO GPS-TAGGED CAPTURES YET — RECORD A SESSION WITH LOCATION ON when there is nothing to plot.

Re-expressed for the grid:
    * MapKit's street map becomes a pixel plot, north up, centred like the iOS camera on the mean of
      everything plotted, about 1000 m across (a whole number of metres per cell: 4 on 241 columns,
      5 on 207), with a dim reseau cross every 100 m in place of the streets.
    * capture pins (cyan) are 2 x 2 text-colour dots; transmitter pins (orange) are 7 x 7 highlight
      rings with a centre dot; the orange halo is a dotted dim circle of the estimate's radius at
      the plot's scale; the tapped pin gets highlight corner brackets.
    * the header row's counts sit in the map's top border, with a 100 M scale bar on the right of it;
      a legend for the layers shown is set into the bottom border, and a small N arrow marks north.
    * the CAPTURES / TRANSMITTERS / BOTH text buttons are [OPTION] selectors, selected inverted;
      REFRESH stays in the header (dim while loading).
    * the info panel is a dim box that clears the plot under it: title in highlight (cyan
      techHeader on iOS; small here so it fits on one line), details dim, wrapped at their " · "
      separators (the separator dropped at the break) to 3 lines, a pixel ×.
    * every pin is selectable, as every Marker is on iOS. Taps, bottom to top: the bare map ("map",
      clears the selection); the captures, one tap per 15 x 15-cell bin of the plot holding visible
      dots ("marker:c|<i>", i = the bin's highest-count capture, as MapKit picks the frontmost
      marker); each transmitter pin, 15 x 15 centred on it ("marker:t|<source>"), above the bins;
      then the info panel ("info", "info:close").
    * panning, zooming and pin balloons are not drawn; the map does not scroll with the content.

Mock state: last night's session walked through the park (arrival up the main street, round the
hub, a ride queue's switchbacks in the west, a parade watched from the curb, the north and east
areas and back), BOTH layers shown, the castle show transmitter's estimate tapped. Positions are
metres east / north of an arbitrary origin (what MapKit would project from lat / lng); labels are
real ones from ios/ParityCheck/vectors.json, sources are the SCAN tab's park transmitters, wands and
band (last 8 hex characters of CoreBluetooth UUIDs, as shortAddress() prints them).
"""

import math
import random

import widgets as W
import vfd
from vfd import UNLIT, HIGHLIGHT, TEXT, DIM, text_width, fit_text

TAB = "map"
TITLE = "CAPTURE MAP"

# ---------------------------------------------------------------------------------------------
# Mock state (MapScreen @State and the CaptureMapData MapMath.Builder made from the logs)
# ---------------------------------------------------------------------------------------------

LOADED = True                       # data != nil
HEADER_RIGHT = "REFRESH" if LOADED else ("REFRESH", DIM)   # disabled while loading
HEADER_RIGHT_TAP = "refresh"                                 # widgets.header: no tap while DIM
MODES = ["CAPTURES", "TRANSMITTERS", "BOTH"]
MODE = "BOTH"
CENTERED_ON_PHONE = False           # nothing to plot, map centred on the phone's last fix
PHONE_FIX = (0.0, -120.0)           # vm.location.latest (metres), used only then
INITIAL_SPAN_M = 1000.0             # mapInitialSpanMeters
GRID_M = 100                        # reseau / scale bar step

MY_BAND = "5C0E8B47-2D1A-4F3C-9E06-11B4A7D3901B"
SHOW_A = "0B6F2E91-7C44-4D0A-B8E2-5A90C41E9A07"
SHOW_B = "D2F17A3C-9B05-4E68-A1C7-3E2F7B2D5F13"
SHOW_C = "8A43C6E0-1F7D-4B92-9D35-C8B1E06A3B98"
SHOW_D = "71B9D2E6-3A0F-4E85-B6C4-0D97A1F3E254"
WAND_1 = "4E9D0A72-63B8-4C1F-8A2E-F07D51F8C2D4"
WAND_3 = "19E4B6D3-C870-4A25-93F1-6B2E8F4D17C6"
GUEST_1 = "2F8A61C4-0E37-4B9D-A512-7C3D90E4B6F1"
GUEST_2 = "E5137B0D-84A2-4C6E-9F08-3B1A6D2C58E7"

#: TxEstimate list (count order, most first): address, x, y (m), count, bestRssi, radiusM, label.
TRANSMITTERS = [
    (SHOW_A, -4.0, 12.0, 389, -58, 41.6, "Single Color: Red"),
    (SHOW_B, 46.0, -248.0, 241, -63, 60.7, "Cross-Fade: Red / Blue"),
    (MY_BAND, 36.0, -52.0, 212, -41, 183.2, "Signal Beacon"),
    (SHOW_C, -262.0, 8.0, 133, -71, 26.8, "Effect: Circle"),
    (SHOW_D, -44.0, 352.0, 118, -66, 35.4, "Rotating Colors (E912)"),
    (WAND_1, -318.0, 66.0, 57, -72, 9.3, "Starlight: Blue (#02)"),
    (GUEST_1, -168.0, -58.0, 31, -74, 22.1, "Raw: 8301C00F0102030405"),
    (WAND_3, 176.0, 352.0, 12, -79, 17.6, "Starlight: Pink (#08)"),
    (GUEST_2, 6.0, -470.0, 9, -81, 73.9, "Raw: 8301C00F01020304057F"),
]

#: The tapped marker's tag ("c|<index into CAPTURES>" or "t|<address>"), or None.
SELECTED = "t|" + SHOW_A

# Labels of the first row heard in a capture cell (mostly guest-band telemetry in a park).
_CELL_LABELS = [
    ("Raw: 8301C00F0102030405", "UNKNOWN"), ("Signal Beacon", "SHOW"),
    ("Raw: 8301C00F01020304057F", "UNKNOWN"), ("Single Color: Red", "COLOR"),
    ("Cross-Fade: Red / Blue", "ANIMATION"), ("Show Ping (2341)", "SHOW"),
    ("Starlight: Blue (#02)", "COLOR"), ("Effect: Circle", "ANIMATION"),
]


def _route():
    """CapturePoint list (count order, most first, at most MapMath.maxMarkers): dicts with x, y (m),
    count, label, category. Built from the walk below, one point every few metres with GPS jitter,
    plus the queue and the parade curb where the phone stood still."""
    rnd = random.Random(1118)
    pts = []

    def walk(path, step=8.0, jitter=2.0, counts=(1, 3)):
        for (x0, y0), (x1, y1) in zip(path, path[1:]):
            n = max(1, int(math.hypot(x1 - x0, y1 - y0) / step))
            for i in range(n):
                t = i / float(n)
                pts.append([x0 + (x1 - x0) * t + rnd.uniform(-jitter, jitter),
                            y0 + (y1 - y0) * t + rnd.uniform(-jitter, jitter),
                            rnd.randint(*counts)])

    def arc(cx, cy, r, a0, a1, step=4.0):
        n = max(2, int(abs(a1 - a0) * r / step))
        return [(cx + r * math.cos(a0 + (a1 - a0) * i / n), cy + r * math.sin(a0 + (a1 - a0) * i / n))
                for i in range(n + 1)]

    walk([(0, -600), (-2, -380), (0, -150)])                                   # main street
    walk(arc(0, -92, 55, -math.pi / 2, -math.pi * 1.5))                        # hub, west side
    walk([(-55, -92), (-130, -80), (-200, -50), (-252, -8), (-282, 38)])       # to the west area
    for k in range(4):                                                         # queue switchbacks
        y = 40 + k * 15
        a, b = (-282, -342) if k % 2 == 0 else (-342, -282)
        walk([(a, y), (b, y)], step=3.0, jitter=0.8, counts=(3, 14))
    walk([(-282, 85), (-300, 150), (-196, 196), (-70, 236)])                   # exit, to the north
    walk([(-70, 236), (-40, 360), (40, 440), (150, 400), (188, 290)])          # north loop
    walk([(188, 290), (226, 160), (230, 40), (182, -40), (112, -82), (55, -92)])  # east, to the hub
    walk(arc(0, -92, 55, math.pi / 2, -math.pi / 2))                          # hub, east side
    walk([(0, -37), (0, 40)])                                                  # castle walk-through
    for _ in range(26):                                                        # parade, curb
        pts.append([38 + rnd.uniform(-5, 5), -262 + rnd.uniform(-4, 4), rnd.randint(20, 140),
                    ("Cross-Fade: Red / Blue", "ANIMATION")])
    pts.sort(key=lambda p: -p[2])
    out = []
    for i, p in enumerate(pts[:1000]):
        x, y, n = p[:3]
        label, cat = p[3] if len(p) > 3 else _CELL_LABELS[(i * 5 + int(abs(x))) % len(_CELL_LABELS)]
        out.append({"x": x, "y": y, "count": n, "label": label, "category": cat})
    return out


CAPTURES = _route()

# ---------------------------------------------------------------------------------------------
# Helpers (Swift: the same names on the VFD screen type)
# ---------------------------------------------------------------------------------------------

TX_RING = [            # 7 x 7 transmitter pin: a ring with a centre dot
    "..###..",
    ".#...#.",
    "#.....#",
    "#..#..#",
    "#.....#",
    ".#...#.",
    "..###..",
]
EMPTY_TEXT = "NO GPS-TAGGED CAPTURES YET — RECORD A SESSION WITH LOCATION ON"


def short_address(address):
    """shortAddress(): the last 8 characters, uppercased; empty stays empty."""
    return address[-8:].upper() if address else ""


def capture_title(p):
    """mapCaptureTitle: the label, with ×count when the cell was heard more than once."""
    return "%s ×%d" % (p["label"], p["count"]) if p["count"] > 1 else p["label"]


def tx_title(t):
    """mapTxTitle: "<short source> · est. TX"."""
    return short_address(t[0]) + " · est. TX"


def tx_detail(t):
    """mapTxDetail: "<n> obs · best <rssi> dBm · ±<r>m · <label>" (label falls back to the source)."""
    address, _, _, count, best, radius, label = t
    label = short_address(address) if label == address else label
    return "%d obs · best %d dBm · ±%dm · %s" % (count, best, int(math.floor(radius + 0.5)), label)


def counts_text():
    if not LOADED:
        return "LOADING…"
    return "%d PTS · %d TX" % (len(CAPTURES), len(TRANSMITTERS))


def center_of():
    """MapMath.center: the mean of every capture point and transmitter; None when there are none."""
    xs = [p["x"] for p in CAPTURES] + [t[1] for t in TRANSMITTERS]
    ys = [p["y"] for p in CAPTURES] + [t[2] for t in TRANSMITTERS]
    if not xs:
        return None
    return sum(xs) / len(xs), sum(ys) / len(ys)


def selected_info():
    """(title, detail, kind, item) for SELECTED, or None (selectedInfo)."""
    if not SELECTED:
        return None
    if SELECTED.startswith("c|"):
        i = int(SELECTED[2:])
        if 0 <= i < len(CAPTURES):
            p = CAPTURES[i]
            return capture_title(p), p["category"], "c", p
        return None
    for t in TRANSMITTERS:
        if SELECTED == "t|" + t[0]:
            return tx_title(t), tx_detail(t), "t", t
    return None


def segment_lines(s, w, max_lines=None, sep=" · "):
    """s broken into lines of at most w cells at its ' · ' separators, the separator dropped at a
    break so no line ends on a stray '·'; a segment longer than a line breaks at spaces. With
    max_lines the last line takes the rest (separators kept), tail-truncated with …."""
    pieces, cur = [], ""                     # (line, what joined it to the next one)
    for seg in s.split(sep):
        cand = cur + sep + seg if cur else seg
        if text_width(cand) <= w:
            cur = cand
            continue
        if cur:
            pieces.append((cur, sep))
        words = vfd.wrap_text(seg, w) or [""]
        pieces.extend((ln, " ") for ln in words[:-1])
        cur = words[-1]
    pieces.append((cur, ""))
    if max_lines and len(pieces) > max_lines:
        rest = "".join(ln + j for ln, j in pieces[max_lines - 1:])
        return [ln for ln, _ in pieces[:max_lines - 1]] + [fit_text(rest, w)]
    return [ln for ln, _ in pieces]


def balanced_wrap(s, w):
    """Word wrap in as few lines as w allows, then as narrow as that many lines allow, so a
    centred note does not end on a lone word."""
    lines = vfd.wrap_text(s, w)
    best = lines
    ww = w - 1
    while ww > 0:
        trial = vfd.wrap_text(s, ww)
        if len(trial) > len(lines) or any(text_width(ln) > ww for ln in trial):
            break
        best = trial
        ww -= 1
    return best


CAPTURE_BIN = 15         # capture tap bins: at least 15 x 15 cells (W.TAP_ROWS)


def capture_taps(fb, x0, y0, w, h, at, hidden=()):
    """One tap per capture bin, so every capture can be selected as a Marker is on iOS. The plot
    interior (x0, y0, w, h) is split into equal bins at least CAPTURE_BIN cells each way; a bin
    holding visible capture dots gets one tap over the whole bin, "marker:c|<i>", where i is the
    bin's highest-count capture (CAPTURES is in count order, so the first one met), as MapKit picks
    the frontmost marker. Dots that a transmitter pin, the north arrow or the info panel clear
    (`hidden` rects) are not counted. Register these before the transmitter pins so the pins stay
    topmost; a capture whose dots sit inside a pin's 15 x 15 tap is still reached from the rest of
    its bin."""
    nx, ny = max(1, w // CAPTURE_BIN), max(1, h // CAPTURE_BIN)
    xs = [x0 + w * k // nx for k in range(nx + 1)]
    ys = [y0 + h * k // ny for k in range(ny + 1)]

    def bin_of(edges, n, size, origin, v):
        k = (v - origin) * n // size
        while edges[k + 1] <= v:             # integer edges: settle the bin exactly
            k += 1
        return k

    picked = {}
    for i, p in enumerate(CAPTURES):
        px, py = at(p["x"], p["y"])          # the dot's top-left cell (2 x 2)
        for qx, qy in ((px, py), (px + 1, py), (px, py + 1), (px + 1, py + 1)):
            # every visible cell of the dot claims its bin, so a dot across a bin edge is
            # tappable on both sides of it
            if not (x0 <= qx < x0 + w and y0 <= qy < y0 + h):
                continue
            if any(hx <= qx < hx + hw and hy <= qy < hy + hh for hx, hy, hw, hh in hidden):
                continue
            picked.setdefault((bin_of(xs, nx, w, x0, qx), bin_of(ys, ny, h, y0, qy)), i)
    for (bx, by), i in sorted(picked.items(), key=lambda kv: (kv[0][1], kv[0][0])):
        fb.tap(xs[bx], ys[by], xs[bx + 1] - xs[bx], ys[by + 1] - ys[by], "marker:c|%d" % i)


def _tap(fb, c, r, w, h, name):
    if h < W.TAP_ROWS:
        r -= (W.TAP_ROWS - h) // 2
        h = W.TAP_ROWS
    fb.tap(c, r, w, h, name)


def bitmap(fb, c, r, rows, color):
    for j, line in enumerate(rows):
        for i, ch in enumerate(line):
            if ch == "#":
                fb.set(c + i, r + j, color)


def tx_pin(fb, x, y, color=HIGHLIGHT):
    """The transmitter pin centred on (x, y)."""
    bitmap(fb, x - 3, y - 3, TX_RING, color)


def capture_dot(fb, x, y, color=TEXT):
    """A capture pin at (x, y): 2 x 2 cells (top-left on the point)."""
    fb.fill(x, y, 2, 2, color)


def halo(fb, x, y, radius, color=DIM):
    """Dotted circle of `radius` cells round (x, y): perimeter cells in angle order, every other one
    lit; a radius under 2 cells is left out (the pin covers it)."""
    if radius < 2:
        return
    n = max(16, int(2 * math.pi * radius * 1.5))
    ring = []
    for k in range(n):
        a = 2 * math.pi * k / n
        cell = (x + vfd._round(radius * math.cos(a)), y - vfd._round(radius * math.sin(a)))
        if not ring or cell != ring[-1]:
            ring.append(cell)
    if len(ring) > 1 and ring[0] == ring[-1]:
        ring.pop()
    for i, (cx, cy) in enumerate(ring):
        if i % 2 == 0:
            fb.set(cx, cy, color)


def brackets(fb, x, y, half=6, arm=3, color=HIGHLIGHT):
    """Selection: four L-shaped corners of a (2*half+1)-cell square round (x, y)."""
    for sx in (-1, 1):
        for sy in (-1, 1):
            cx, cy = x + sx * half, y + sy * half
            fb.hline(min(cx, cx - sx * (arm - 1)), cy, arm, color)
            fb.vline(cx, min(cy, cy - sy * (arm - 1)), arm, color)


def reseau(fb, x, y, color=DIM):
    """A 3 x 3 cross where two 100 m grid lines meet."""
    fb.set(x, y, color)
    fb.set(x - 1, y, color)
    fb.set(x + 1, y, color)
    fb.set(x, y - 1, color)
    fb.set(x, y + 1, color)


def north_arrow(fb, x, y, color=DIM):
    """N over a 5-wide up arrow, top-left at (x, y); 5 x 16 cells, on a cleared patch."""
    fb.fill(x - 2, y - 2, 9, 20, UNLIT)
    fb.text(x, y, "N", "small", color)
    for i in range(3):
        fb.hline(x + 2 - i, y + 9 + i, 1 + 2 * i, color)
    fb.vline(x + 2, y + 12, 4, color)


def border_text(fb, x, row, s, color):
    """Text set into a horizontal border whose line runs at row + 3: the border is cleared 3 cells
    round the ink. Returns the column after the cleared gap."""
    tw = text_width(s)
    fb.fill(x - 3, row + 3, tw + 6, 1, UNLIT)
    fb.text(x, row, s, "small", color)
    return x + tw + 3


def scale_bar(fb, right, row, cells, label):
    """A scale bar set into the top border, ending at column `right`: "├────┤ 100 M" (TEXT bar with
    end ticks across the caps, the label after it). Returns its first column."""
    lw = text_width(label)
    x = right - lw - 4 - cells
    fb.fill(x - 3, row + 3, cells + lw + 4 + 6, 1, UNLIT)
    fb.hline(x, row + 3, cells, TEXT)
    fb.vline(x, row + 1, 5, TEXT)
    fb.vline(x + cells - 1, row + 1, 5, TEXT)
    fb.text(x + cells + 4, row, label, "small", TEXT)
    return x


# ---------------------------------------------------------------------------------------------
# Screen parts
# ---------------------------------------------------------------------------------------------

def mode_bar(fb, L, c, y, w):
    """CAPTURES / TRANSMITTERS / BOTH (selected inverted). Returns the next free row."""
    return W.options(fb, L, c, y, w, MODES, MODE, name="mode")


def legend(fb, x, row, limit, show_c, show_t):
    """Legend for the layers shown, set into the bottom border (its line at row + 3) from column x:
    a capture dot, a transmitter pin and a dotted halo, each with its dim label, the border cleared
    in one run under them. Returns the column after the last item."""
    items = []
    if show_c:
        items.append(("c", "CAPTURE"))
    if show_t:
        items += [("t", "EST. TX"), ("h", "±RADIUS")]
    spots, end = [], x
    for kind, label in items:
        need = 7 + 4 + text_width(label)
        if end + need > limit:
            break
        spots.append((end, kind, label))
        end += need + 9
    if not spots:
        return x
    end -= 9
    fb.fill(x - 3, row + 3, end - x + 6, 1, UNLIT)
    for sx, kind, label in spots:
        if kind == "c":
            capture_dot(fb, sx + 2, row + 2)
        elif kind == "t":
            tx_pin(fb, sx + 3, row + 3)
        else:
            for dx, dy in ((2, 0), (4, 0), (0, 2), (6, 2), (0, 4), (6, 4), (2, 6), (4, 6)):
                fb.set(sx + dx, row + dy, DIM)
        fb.text(sx + 11, row, label, "small", DIM)
    return end


def info_layout(x0, x1, bottom, info):
    """The info panel's lines and box: (title lines, detail lines, top row, height). The panel
    clears (x0 - 2, top - 2, width + 4, h + 4)."""
    title, detail = info[0], info[1]
    iw = x1 - x0 + 1 - 8
    tw = iw - 5 - 6                                   # title beside the close ×
    tlines = segment_lines(title, tw, max_lines=2)    # both wrap at their " · " separators
    dlines = segment_lines(detail, iw, max_lines=3) if detail else []
    h = 4 + len(tlines) * W.LINE + (3 + len(dlines) * W.LINE if dlines else 0) + 2
    return tlines, dlines, bottom - h + 1, h


def info_panel(fb, L, x0, x1, bottom, info):
    """MapScreenInfoPanel over the bottom of the plot (columns x0..x1 inclusive, last row
    `bottom`): cleared, dim border, the title (highlight) and details (dim, ≤ 3 lines), a pixel ×.
    Returns its top row."""
    pw = x1 - x0 + 1
    ix = x0 + 4
    tlines, dlines, top, h = info_layout(x0, x1, bottom, info)
    fb.fill(x0 - 2, top - 2, pw + 4, h + 4, UNLIT)        # no half-covered pin or cross round it
    fb.box(x0, top, pw, h, DIM)
    y = top + 4
    for ln in tlines:
        fb.text(ix, y, ln, "small", HIGHLIGHT)
        y += W.LINE
    if dlines:
        y += 3
        for ln in dlines:
            fb.text(ix, y, ln, "small", DIM)
            y += W.LINE
    # the close ×: a 5 x 5 pixel cross in the top-right corner
    cx, cy = x1 - 4 - 4, top + 5
    for i in range(5):
        fb.set(cx + i, cy + i, DIM)
        fb.set(cx + 4 - i, cy + i, DIM)
    fb.tap(x0, top, pw - 15, h, "info")
    _tap(fb, cx - 5, top, 15, 15, "info:close")
    return top


def empty_banner(fb, L, x0, x1, top):
    """The empty-state note over the top of the map: cleared, dim border, centred dim lines."""
    pw = x1 - x0 + 1
    lines = balanced_wrap(EMPTY_TEXT, pw - 8)
    h = 4 + len(lines) * W.LINE + 2
    fb.fill(x0, top, pw, h, UNLIT)
    fb.box(x0, top, pw, h, DIM)
    for i, ln in enumerate(lines):
        fb.text(W._cx(x0, pw, ln), top + 4 + i * W.LINE, ln, "small", DIM)


def centred_note(fb, L, c, y, w, s):
    """Centred dim text in the space left (the empty state with no map, or LOADING…)."""
    lines = balanced_wrap(s, w - 12)
    mid = max(y, (y + L.content_bottom) // 2 - len(lines) * W.LINE // 2)
    for i, ln in enumerate(lines):
        fb.text(W._cx(c, w, ln), mid + i * W.LINE, ln, "small", DIM)


def plot(fb, L, c, y, w):
    """The map box from row y to the bottom of the content: top border with the counts and the
    scale bar, the reseau, halos, pins, selection, info panel, legend in the bottom border."""
    cap_row = y                              # caps of the top-border text; the border at +3
    leg_row = L.content_bottom - 8           # caps of the bottom-border legend; the border at +3
    top, bot = cap_row + 3, leg_row + 3
    fb.box(c, top, w, bot - top + 1, DIM)
    ix0, ix1 = c + 1, c + w - 2              # inner columns (inclusive)
    iy0, iy1 = top + 1, bot - 1
    iw = ix1 - ix0 + 1
    mpc = max(1, vfd._round(INITIAL_SPAN_M / iw))       # metres per cell
    cxm, cym = center_of() or (PHONE_FIX if CENTERED_ON_PHONE else (0.0, 0.0))
    ccol, crow = ix0 + iw // 2, (iy0 + iy1) // 2

    def at(xm, ym):
        return ccol + vfd._round((xm - cxm) / mpc), crow - vfd._round((ym - cym) / mpc)

    show_c = MODE != "TRANSMITTERS"
    show_t = MODE != "CAPTURES"
    info = selected_info()
    ih = iy1 - iy0 + 1
    north = (ix1 - 3 - 5, iy0 + 7)                     # the N arrow's top-left (drawn last)
    covered = [(north[0] - 2, north[1] - 2, 9, 20)]      # cleared later: their dots take no tap
    if info:
        _, _, ptop, ph = info_layout(ix0 + 3, ix1 - 3, iy1 - 5, info)
        covered.append((ix0 + 1, ptop - 2, iw - 2, ph + 4))
    if show_t:                                         # each pin clears 7 x 7 under it
        covered += [(px - 3, py - 3, 7, 7) for px, py in (at(t[1], t[2]) for t in TRANSMITTERS)]
    # Taps, bottom to top (later = topmost): the empty map ("map": clears the selection, as tapping
    # bare MapKit map does), the capture bins, the transmitter pins, then the info panel.
    fb.tap(ix0, iy0, iw, ih, "map")

    fb.push_clip(ix0, iy0, iw, iy1 - iy0 + 1)
    # reseau every GRID_M metres (whole multiples of GRID_M in the map frame)
    gx0 = int(math.floor((cxm - (ccol - ix0) * mpc) / GRID_M)) * GRID_M
    gy0 = int(math.floor((cym - (iy1 - crow) * mpc) / GRID_M)) * GRID_M
    gxm = gx0
    while gxm <= cxm + (ix1 - ccol) * mpc + GRID_M:
        gym = gy0
        while gym <= cym + (crow - iy0) * mpc + GRID_M:
            gc, gr = at(gxm, gym)
            if ix0 + 2 <= gc <= ix1 - 2 and iy0 + 2 <= gr <= iy1 - 2:
                reseau(fb, gc, gr)
            gym += GRID_M
        gxm += GRID_M
    if show_c:
        for p in CAPTURES:
            capture_dot(fb, *at(p["x"], p["y"]))
        # capture taps: one per 15 x 15 bin, "marker:c|<i>" (i = the bin's highest-count capture)
        capture_taps(fb, ix0, iy0, iw, ih, at, hidden=covered)
    if show_t:
        for t in TRANSMITTERS:
            px, py = at(t[1], t[2])
            halo(fb, px, py, t[5] / mpc)
        for t in TRANSMITTERS:
            px, py = at(t[1], t[2])
            fb.fill(px - 3, py - 3, 7, 7, UNLIT)          # the pin sits on what is under it
            tx_pin(fb, px, py)
            # transmitter taps: 15 x 15 centred on the pin, registered after the capture bins so a
            # pin wins over the captures round it (MapKit's frontmost marker)
            fb.tap(px - 7, py - 7, 15, 15, "marker:t|" + short_address(t[0]))
    if info:
        if info[2] == "t":
            brackets(fb, *at(info[3][1], info[3][2]))
        else:
            x, y2 = at(info[3]["x"], info[3]["y"])
            brackets(fb, x, y2, half=5)
    north_arrow(fb, *north)
    if not CAPTURES:
        empty_banner(fb, L, ix0 + 3, ix1 - 3, iy0 + 4)
    if info:
        info_panel(fb, L, ix0 + 3, ix1 - 3, iy1 - 5, info)     # same box as `covered` above
    fb.pop_clip()

    # top border: counts (left), 100 M scale bar (right); bottom border: legend
    end = border_text(fb, c + 6, cap_row, counts_text(), DIM)
    bar = GRID_M // mpc
    if end + 6 + bar + 4 + text_width("100 M") + 6 <= c + w - 3:
        scale_bar(fb, c + w - 7, cap_row, bar, "%d M" % GRID_M)
    legend(fb, c + 6, leg_row, c + w - 6, show_c, show_t)
    return bot + 1


def draw(fb, L):
    c, w = L.left, L.width
    scroll = -fb.origin_y
    # The map does not scroll with the content: undo the scroll offset.
    fb.push_clip(0, L.content_top + scroll, fb.cols, L.content_h, dy=scroll)
    y = mode_bar(fb, L, c, L.content_top, w)
    if not LOADED:
        centred_note(fb, L, c, y, w, "LOADING…")
    elif CAPTURES or CENTERED_ON_PHONE:
        plot(fb, L, c, y + 1, w)
    else:
        centred_note(fb, L, c, y, w, EMPTY_TEXT)
    fb.pop_clip()
    return None
