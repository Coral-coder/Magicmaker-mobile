"""WAND tab on the VFD grid: a port of ios/MagicMaker/Views/WandScreen.swift and
StarlightWandView.swift.

Top to bottom, as on iOS (the library area fills the space, the controls panel sits at the bottom):
    library area
        STARLIGHT mode (default): StarlightWandView
            the wand picture as pixel art, its glow re-expressed as a lit rod with glitter and a
            dotted aura (tap = next colour);
            picker row: [o NAME / 8301CF…F22A6201  ⇕] [SEND]  (the colour dot is a lit 5x5 LED, the
            colour itself is named; the hex is middle-truncated as on iOS so the colour byte shows)
        NEW WAND mode: WandCodeList ("NEW WAND · 288 CODES · TAP SENDS · HOLD RENAMES", then one row per
            code: last 2 bytes in mid size on the left (dim; the selected one inverted), custom name or
            palette colour on the right (dim; the selected one highlight))
    divider
    controls panel
        [STARLIGHT] [NEW WAND]            mode row (selected inverted)
        [            OFF            ]     programmable quick button (vm.wandQuickLabel)
        LOOP                    [ON|OFF]  starlight loop toggle
        5.4S | STARLIGHT: PURPLE (#01)    TxIntervalSlider (text over a 61-stop slider, no step buttons)
        ===o..........................
        LIB 9                  [CLR LIB]  library count (+ clear, Starlight only)
        SCANNING                          StatusLine(tx.status)

Mock data: learned Starlight colours (labels / hex from ios/ParityCheck/vectors.json, one per colour
index, sorted by label as learnedStarlightPackets() does), StarlightColors / PresetCatalog colour
names, the generated New Wand range (NewWandCatalog: 8301CF0B00C020224EAC7807866 + E80..FFF without
F20..F7F = 288 codes).

Set SHOW_NEW_WAND = True to draw the NEW WAND mode instead.
"""

import math

import widgets as W
import vfd
from vfd import UNLIT, HIGHLIGHT, TEXT, DIM, text_width, fit_text

# Shared with TX and LOGS, now in widgets.py.
snapped_window, list_scrollbar = W.snapped_window, W.list_scrollbar
token_lines, interval_slider = W.token_lines, W.interval_slider
interval_stop, interval_text = W.interval_stop, W.interval_text


TAB = "wand"
TITLE = "WAND"

# ---------------------------------------------------------------------------------------------
# Mock state
# ---------------------------------------------------------------------------------------------

SHOW_NEW_WAND = False          # WandScreen.showNewWand
LOOP_ENABLED = False           # tx.starlightLoopEnabled
INTERVAL_SEC = 5.4167          # tx.starlightIntervalMs / 1000 (slider stop 10 -> "5.4")
STATUS = "Scanning"            # tx.status
QUICK_LABEL = "OFF"            # vm.wandQuickLabel (the New Wand "Off" code until reprogrammed)

# StarlightColors palette (PresetCatalog.starlightColorNames)
COLOR_NAMES = {
    0x00: "Cyan", 0x01: "Purple", 0x02: "Blue", 0x03: "Midnight Blue", 0x04: "Blue",
    0x05: "Bright Purple", 0x06: "Lavender", 0x07: "Purple", 0x08: "Pink", 0x09: "Pink",
    0x0A: "Pink", 0x0B: "Pink", 0x0C: "Pink", 0x0D: "Pink", 0x0E: "Pink", 0x0F: "Yellow Orange",
    0x10: "Off Yellow", 0x11: "Yellow", 0x12: "Lime", 0x13: "Orange", 0x14: "Red Orange",
    0x15: "Red", 0x16: "Cyan", 0x17: "Cyan", 0x18: "Cyan", 0x19: "Green", 0x1A: "Lime Green",
    0x1B: "White", 0x1C: "White", 0x1D: "Off", 0x1E: "Unique", 0x1F: "Random",
}

# learnedStarlightPackets() -> WandScreen.starlightColors(): one per colour index, by label.
# (label, hex, colour index)
STARLIGHT = [
    ("Starlight: Blue (#02)", "8301CF9B00C42922EFD819F22A6202", 0x02),
    ("Starlight: Cyan (#00)", "8301CF9B00C42922EFD819F22A6200", 0x00),
    ("Starlight: Green (#19)", "8301CF9B00C42922EFD819F22A6219", 0x19),
    ("Starlight: Midnight Blue (#03)", "8301CF0B00C42922EFD819F22A6203", 0x03),
    ("Starlight: Pink (#0C)", "8301CF0B00C42922EFD819F22A620C", 0x0C),
    ("Starlight: Purple (#01)", "8301CF9B00C42922EFD819F22A6201", 0x01),
    ("Starlight: Red (#15)", "8301CF0B00C42922EFD819F22A6215", 0x15),
    ("Starlight: Unique (#1E)", "8301CF0B00C42922EFD819F22A621E", 0x1E),
    ("Starlight: White (#1B)", "8301CF9B00000000000000000000001BB0", 0x1B),
]
SELECTED_STARLIGHT = 5         # the colour last sent (and heard back): Purple (#01)

NEW_WAND_PREFIX = "8301CF0B00C020224EAC7807866"
NEW_WAND_NAMES = {             # vm.newWandNames (custom names given with a long press)
    NEW_WAND_PREFIX + "E89": "Fireworks pink",
    NEW_WAND_PREFIX + "E99": "Tink green",
}
SELECTED_NEW_WAND = NEW_WAND_PREFIX + "E85"


def new_wand_codes():
    """NewWandCatalog.packets: (label, hex, colour name) for E80..FFF without F20..F7F."""
    out = []
    for v in range(0xE80, 0x1000):
        if 0xF20 <= v <= 0xF7F:
            continue
        code = "%03X" % v
        hx = NEW_WAND_PREFIX + code
        out.append(("New Wand " + code, hx, COLOR_NAMES[int(hx[-2:], 16) & 0x1F]))
    return out


LOOP_MIN, LOOP_MAX, LOOP_LAST_STOP = W.LOOP_MIN, W.LOOP_MAX, W.LOOP_LAST_STOP


# ---------------------------------------------------------------------------------------------
# Small pieces
# ---------------------------------------------------------------------------------------------

def _pt(L, pt):
    """Points -> whole cells on this device."""
    return int(round(pt * L.device.scale / float(L.device.pitch)))


def fit_middle(s, max_cols):
    """Truncate in the middle with … (SwiftUI .truncationMode(.middle)); the tail keeps the extra
    character so the colour byte at the end stays visible."""
    n = vfd.max_chars(max_cols)
    if len(s) <= n:
        return s
    if n <= 1:
        return fit_text(s, max_cols)
    keep = n - 1
    head = keep // 2
    return s[:head] + vfd.ELLIPSIS + s[len(s) - (keep - head):]


def led_dot(fb, c, r, color=HIGHLIGHT):
    """A 5 x 5 round LED (corners unlit) with its top-left at (c, r)."""
    fb.fill(c + 1, r, 3, 5, color)
    fb.fill(c, r + 1, 5, 3, color)


def updown(fb, c, r, color=DIM):
    """chevron.up.chevron.down: a 7 x 4 up chevron over a 7 x 4 down chevron, 2 rows apart
    (rows r .. r+9)."""
    for i in range(4):
        fb.hline(c + 3 - i, r + i, 2 * i + 1, color)
        fb.hline(c + i, r + 6 + i, 7 - 2 * i, color)


# ---------------------------------------------------------------------------------------------
# The Starlight wand as pixel art (proportions measured from StarlightWand.png)
# ---------------------------------------------------------------------------------------------
# t runs from the rod tip (0) to the bottom of the crystal (1) in units of the wand length H;
# half-widths are fractions of H. Rod, handle, collar and crystal are symmetric about the centre
# column; the glove (its finger side rises first), the finger slits and the handle artwork sit
# where they are on the real wand.

# glove outline, left and right half-widths (the finger side, on the right, rises first)
GLOVE_L = [(0.440, 0.028), (0.446, 0.043), (0.455, 0.053), (0.466, 0.061), (0.478, 0.067),
           (0.492, 0.072), (0.510, 0.077), (0.528, 0.081), (0.543, 0.081), (0.556, 0.077),
           (0.568, 0.071), (0.579, 0.064), (0.589, 0.057), (0.596, 0.054), (0.622, 0.054)]
GLOVE_R = [(0.428, 0.028), (0.434, 0.045), (0.444, 0.054), (0.456, 0.060), (0.470, 0.067),
           (0.486, 0.074), (0.505, 0.078), (0.528, 0.082), (0.543, 0.081), (0.556, 0.077),
           (0.568, 0.071), (0.579, 0.063), (0.589, 0.056), (0.596, 0.054), (0.622, 0.054)]
HANDLE = [(0.622, 0.047), (0.634, 0.041), (0.650, 0.038), (0.700, 0.036), (0.760, 0.036),
          (0.800, 0.039), (0.822, 0.043), (0.838, 0.050), (0.846, 0.054)]
GLOVE_TOP, CUFF_T, GLOVE_END = 0.428, 0.594, 0.622
HANDLE_END, COLLAR_END, NECK_END = 0.846, 0.878, 0.890
BALL_T, BALL_R = 0.937, 0.064
ROD_HW, ROD_END = 0.023, 0.45
# finger slits: (top dx, bottom dx, top t, bottom t); they fan out like the glove's fingers, the
# bottoms leaning left, the left one shortest and the right one lowest
SLITS = [(-0.008, -0.010, 0.490, 0.536), (0.026, 0.018, 0.486, 0.552), (0.060, 0.048, 0.506, 0.556)]
# aura (WandAuraLayer envelopes): centre t, rx, ry as fractions of H
AURA = [(0.272, 0.058, 0.272, 2), (0.272, 0.096, 0.312, 3)]


def _interp(points, t):
    if t <= points[0][0]:
        return points[0][1]
    for (t0, v0), (t1, v1) in zip(points, points[1:]):
        if t <= t1:
            return v0 + (v1 - v0) * (t - t0) / (t1 - t0)
    return points[-1][1]


def _hash(a, b):
    """Small deterministic hash for the glitter (same pattern on every render)."""
    h = (a * 374761393 + b * 668265263) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    return h ^ (h >> 16)


def _dotted_ellipse(cells, cx, cy, rx, ry, every):
    """Cells on an ellipse outline, every `every`-th cell along the path."""
    pts, n = [], max(64, int(8 * (rx + ry)))
    for i in range(n):
        a = 2 * math.pi * i / n
        p = (cx + int(round(rx * math.sin(a))), cy - int(round(ry * math.cos(a))))
        if not pts or p != pts[-1]:
            pts.append(p)
    if len(pts) > 1 and pts[0] == pts[-1]:
        pts.pop()
    for i, p in enumerate(pts):
        if i % every == 0:
            cells[p] = DIM


def wand_cells(H):
    """The wand H rows long as {(dx, y): colour}, dx relative to the centre column, y from the
    rod tip (aura rows may be negative)."""
    cells = {}

    def row_hw(points, t):
        return int(round(_interp(points, t) * H))

    # aura: dotted rings around the rod (drawn first, everything else covers it)
    for ct, rx, ry, every in AURA:
        _dotted_ellipse(cells, 0, int(round(ct * H)), max(1, rx * H), ry * H, every)

    # rod: lit in the glow colour, rounded tip, sparse glitter
    rw = max(2, int(round(ROD_HW * H)))
    for y in range(int(round(ROD_END * H))):
        hw = rw - (2 if y == 0 else 1 if y == 1 else 0)
        for dx in range(-hw, hw + 1):
            glint = _hash(dx + 50, y) % 9 == 0 and abs(dx) < hw and y > 2
            cells[(dx, y)] = TEXT if glint else HIGHLIGHT

    # glove: white with a dim outline, finger slits cut out, a crease above the cuff
    g1 = int(round(GLOVE_END * H))
    span = {}
    for y in range(int(round(GLOVE_TOP * H)), g1):
        t = (y + 0.5) / H
        lo = -int(round(_interp(GLOVE_L, t) * H)) if t >= GLOVE_L[0][0] else rw   # beside the rod
        hi = int(round(_interp(GLOVE_R, t) * H))
        span[y] = (lo, hi)
    crease = int(round(CUFF_T * H))
    for y, (lo, hi) in span.items():
        ulo, uhi = span.get(y - 1, (1, -1))
        dlo, dhi = span.get(y + 1, (1, -1))
        for dx in range(lo, hi + 1):
            edge = dx in (lo, hi) or not (ulo <= dx <= uhi) or not (dlo <= dx <= dhi)
            cells[(dx, y)] = DIM if (edge or y == crease) else TEXT
    sw = max(2, int(round(0.012 * H)))
    for dxa, dxb, ta, tb in SLITS:
        ya, yb = int(round(ta * H)), int(round(tb * H))
        for y in range(ya, yb + 1):
            f = (y - ya) / float(max(1, yb - ya))
            x0 = int(round((dxa + (dxb - dxa) * f) * H - sw / 2.0))
            for i in range(sw):
                if sw >= 3 and y in (ya, yb) and i in (0, sw - 1):
                    continue            # rounded slit ends
                cells[(x0 + i, y)] = UNLIT

    # handle: dark (dim) with its decoration in text colour
    h0, h1 = g1, int(round(HANDLE_END * H))
    for y in range(h0, h1):
        hw = row_hw(HANDLE, (y + 0.5) / H)
        for dx in range(-hw, hw + 1):
            cells[(dx, y)] = DIM
    hwm = row_hw(HANDLE, 0.70)

    # handle decoration: two 4-point sparkles (upper left), a dotted ring (upper right) and a
    # dotted swirl curling down to a small spiral (the printed "Disney Starlight" artwork)
    for (sx, st, arm) in ((-0.50, 0.660, 2), (-0.05, 0.648, 1)):
        x, y = int(round(sx * hwm)), int(round(st * H))
        cells[(x, y)] = TEXT
        for k in range(1, arm + 1):
            for ddx, ddy in ((k, 0), (-k, 0), (0, k), (0, -k)):
                cells[(x + ddx, y + ddy)] = TEXT
    ring_r = max(2, int(round(0.016 * H)))
    rcx, rcy = int(round(0.42 * hwm)), int(round(0.676 * H))
    for i in range(8):
        a = 2 * math.pi * i / 8
        cells[(rcx + int(round(ring_r * math.cos(a))), rcy + int(round(ring_r * math.sin(a))))] = TEXT
    path = [(0.55, 0.722), (0.15, 0.736), (-0.40, 0.756), (-0.52, 0.778), (-0.25, 0.800),
            (0.20, 0.812), (0.45, 0.804), (0.30, 0.794), (0.12, 0.800)]
    pts = []
    for (x0f, t0), (x1f, t1) in zip(path, path[1:]):
        for k in range(12):
            f = k / 12.0
            pts.append(((x0f + (x1f - x0f) * f) * hwm, (t0 + (t1 - t0) * f) * H))
    pts.append((path[-1][0] * hwm, path[-1][1] * H))
    dist, last = 0.0, None
    for p in pts:
        if last is not None:
            dist += math.hypot(p[0] - last[0], p[1] - last[1])
        if last is None or dist >= 2.4:
            cells[(int(round(p[0])), int(round(p[1])))] = TEXT
            dist = 0.0
        last = p

    # crystal ball (behind the collar): dim facet lattice, text rim and a small glint
    bc, br = BALL_T * H, BALL_R * H

    def out(a, b):
        return a * a + (b + 0.5 - bc) ** 2 > br * br

    for y in range(int(round(NECK_END * H)) - 2, H):
        for dx in range(-int(br) - 1, int(br) + 2):
            if out(dx, y):
                continue
            rim = out(dx - 1, y) or out(dx + 1, y) or out(dx, y - 1) or out(dx, y + 1)
            lat = (dx + y) % 5 == 0 or (dx - y) % 5 == 0
            cells[(dx, y)] = TEXT if rim else (DIM if lat else UNLIT)
    gx, gy = int(round(-0.35 * br)), int(round(bc - 0.45 * br))
    for p in ((gx, gy), (gx + 1, gy), (gx, gy + 1)):
        cells[p] = TEXT

    # collar ring (with an unlit gap above it) and the neck into the ball
    c0, c1 = h1 + 1, int(round(COLLAR_END * H))
    chw = int(round(0.061 * H))
    for dx in range(-chw, chw + 1):
        cells[(dx, h1)] = UNLIT
    for y in range(c0, c1):
        inset = 1 if y in (c0, c1 - 1) else 0
        for dx in range(-chw + inset, chw - inset + 1):
            cells[(dx, y)] = DIM
    for dx in range(-chw + 1, chw):
        cells[(dx, c0)] = TEXT            # the collar's lit rim
    nhw = int(round(0.040 * H))
    for y in range(c1, int(round(NECK_END * H))):
        for dx in range(-nhw, nhw + 1):
            cells[(dx, y)] = DIM
    return cells


def draw_wand(fb, cx, top, H):
    """Blit the wand pixel art with its rod tip on row `top`, centred on column cx."""
    for (dx, y), color in wand_cells(H).items():
        fb.set(cx + dx, top + y, color)


def wand_extent(H):
    """(first row, last row) the wand art uses relative to the rod tip (the aura reaches above)."""
    ys = [y for (_, y) in wand_cells(H)]
    return min(ys), max(ys)


# ---------------------------------------------------------------------------------------------
# Library area
# ---------------------------------------------------------------------------------------------

def picker_row(fb, L, c, r, w, name, hex_s, send_enabled=True):
    """StarlightWandView.pickerRow: the menu label box (LED dot, colour name, middle-truncated hex,
    up/down chevrons) and the SEND primary button (96 pt wide). Returns the row under them."""
    h = 26
    send_w = _pt(L, 96)
    gap = 6
    bw = w - send_w - gap
    fb.box(c, r, bw, h, DIM)
    led_dot(fb, c + 5, r + 4 + 1)
    tx = c + 5 + 5 + 5
    tw = c + bw - 5 - 7 - 5 - tx
    fb.text_fit(tx, r + 4, name.upper(), tw, "small", TEXT)
    fb.text(tx, r + 15, fit_middle(hex_s.upper(), tw), "small", DIM)
    updown(fb, c + bw - 5 - 7, r + 8)
    fb.tap(c, r, bw, h, "menu:COLOR")
    sx = c + bw + gap
    sw_ = c + w - sx
    if send_enabled:
        fb.fill(sx, r, sw_, h, HIGHLIGHT)
        fb.text(sx + (sw_ - text_width("SEND")) // 2, r + 9, "SEND", "small", UNLIT)
        fb.tap(sx, r, sw_, h, "button:SEND")
    else:
        fb.box(sx, r, sw_, h, DIM)
        fb.text(sx + (sw_ - text_width("SEND")) // 2, r + 9, "SEND", "small", DIM)
    return r + h


def starlight_area(fb, L, top, bottom):
    """StarlightWandView in rows top .. bottom-1: the wand, then the picker row 10 pt above the
    bottom padding."""
    c, w = L.left, L.width
    sel_label, sel_hex, sel_idx = STARLIGHT[SELECTED_STARLIGHT]
    pick_h = 26
    pick_top = bottom - _pt(L, 8) - pick_h
    wand_bottom = pick_top - _pt(L, 10)
    avail = wand_bottom - top
    # largest H whose art (aura included) fits; iOS scales the picture to the available height
    H = avail
    while H > 40:
        a, b = wand_extent(H)
        if b - a + 1 <= avail:
            break
        H -= 1
    a, b = wand_extent(H)
    tip = top + (avail - (b - a + 1)) // 2 - a
    cx = c + w // 2
    draw_wand(fb, cx, tip, H)
    fb.tap(c, top, w, wand_bottom - top, "wand:cycle")
    name = COLOR_NAMES[sel_idx]
    picker_row(fb, L, c, pick_top, w, name, sel_hex)


def new_wand_area(fb, L, top, bottom, scroll=0):
    """WandCodeList in rows top .. bottom-1: the dim header line, a rule, then the code rows,
    which scroll (by `scroll` rows) inside the area under the header, as the iOS ScrollView does."""
    c, w = L.left, L.width
    codes = new_wand_codes()
    y = top + 1
    head = "NEW WAND · %d CODES · TAP SENDS · HOLD RENAMES" % len(codes)
    for line in token_lines(head, w):
        fb.text(c, y, line, "small", DIM)
        y += W.LINE
    fb.hline(c, y, w, DIM)
    list_top = y + 1
    m = vfd.metrics("mid")
    row_h = 4 + m["ascent"] + 4 + 1         # padding, mid caps, padding, dotted divider

    def draw_rows(target):
        yy = list_top - scroll
        for label, hx, colour in codes:
            if yy > bottom:
                break
            if yy + row_h < list_top:
                yy += row_h
                continue
            key = hx.upper()[-4:]
            nm = NEW_WAND_NAMES.get(hx.upper(), colour).upper()
            sel = hx.upper() == SELECTED_NEW_WAND
            kx, ky = c + 2, yy + 4
            # iOS WandCodeRow: the key in cyanDim, the selected one in cyan; here the selected key
            # is the inverted block and its name the only other highlight on the list
            if sel:
                target.fill(kx - 2, ky - 2, text_width(key, "mid") + 4, m["ascent"] + 4, HIGHLIGHT)
                kend = target.text(kx, ky, key, "mid", UNLIT)
            else:
                kend = target.text(kx, ky, key, "mid", DIM)
            nx = kend + 8
            target.text_right(c + w - 1, ky + (m["ascent"] - 7) // 2, fit_text(nm, c + w - nx),
                              "small", HIGHLIGHT if sel else DIM)
            target.hline(c, yy + row_h - 1, w, DIM, step=2)
            target.tap(c, yy, w, row_h, "code:" + key)
            yy += row_h

    t, b = snapped_window(fb, list_top, bottom, draw_rows)
    n = len(fb.taps)
    fb.push_clip(0, t - fb.origin_y, fb.cols, b - t)
    draw_rows(fb)
    fb.pop_clip()
    fb.taps[n:] = [tp for tp in fb.taps[n:] if tp[3] >= W.TAP_ROWS]
    list_scrollbar(fb, list_top, bottom - list_top, len(codes) * row_h, scroll)


# ---------------------------------------------------------------------------------------------
# Controls panel
# ---------------------------------------------------------------------------------------------

def mode_row(fb, L, c, r, w, new_wand):
    """STARLIGHT / NEW WAND (a two-way picker): [OPTION] selectors centred in two equal cells, the
    selected one inverted, as every picker in the theme (W.options with columns=2)."""
    return W.options(fb, L, c, r, w, ["STARLIGHT", "NEW WAND"], 1 if new_wand else 0, columns=2,
                     name="mode")


def quick_button(fb, L, c, r, w, label):
    """The programmable quick button: a full-width W.button (highlight border, label in text; tap
    sends it, a long press reprograms it)."""
    return W.button(fb, L, c, r, w, label, name="button:QUICK")


def controls(fb, L, top):
    """The controls panel from row `top` (the divider). Returns the next free row."""
    c, w = L.left, L.width
    fb.hline(c, top, w, DIM)
    y = top + 4
    y = mode_row(fb, L, c, y, w, SHOW_NEW_WAND)
    y = quick_button(fb, L, c, y, w, QUICK_LABEL)
    y = W.toggle(fb, L, c, y, w, "LOOP", LOOP_ENABLED, label_color=HIGHLIGHT)
    if SHOW_NEW_WAND:
        codes = new_wand_codes()
        lib_n = len(codes)
        sel = [lab for lab, hx, _ in codes if hx == SELECTED_NEW_WAND]
        sel_label = sel[0] if sel else None
    else:
        lib_n = len(STARLIGHT)
        sel_label = STARLIGHT[SELECTED_STARLIGHT][0]
    text = (interval_text(INTERVAL_SEC) + "S | " + sel_label.upper()) if sel_label else "NO WAND LIBRARY"
    y = interval_slider(fb, L, c, y, w, text, INTERVAL_SEC)
    # LIB n ............ [CLR LIB]
    fb.text(c, y + 3, "LIB %d" % lib_n, "small", DIM)
    if not SHOW_NEW_WAND and lib_n:
        bw = text_width("CLR LIB") + 12
        W.button(fb, L, c + w - bw, y, bw, "CLR LIB")
    y += W.CTRL_H + W.GAP
    y = W.status_line(fb, L, c, y, w, STATUS, color=DIM)
    return y


def draw(fb, L):
    # The tab does not scroll as a whole (iOS: the library area fills the space over the pinned
    # controls panel), so the content scroll is undone; in NEW WAND mode it scrolls the code list.
    scroll = -fb.origin_y
    fb.push_clip(0, L.content_top + scroll, fb.cols, L.content_h, dy=scroll)
    # The controls are anchored to the bottom of the content region, the library area fills the
    # rest (iOS: libraryArea .frame(maxHeight: .infinity) over the controls panel).
    probe = vfd.FrameBuffer(fb.cols, fb.rows)
    h = controls(probe, L, L.content_top + 40) - (L.content_top + 40)
    ctop = L.content_bottom - h
    if SHOW_NEW_WAND:
        new_wand_area(fb, L, L.content_top, ctop, scroll)
    else:
        starlight_area(fb, L, L.content_top, ctop)
    controls(fb, L, ctop)
    fb.pop_clip()
    return None
