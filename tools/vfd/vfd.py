#!/usr/bin/env python3
"""VFD core renderer: device table, palette, cell frame buffer and PNG preview output.

This module mirrors, one to one, the drawing API the Swift renderer will get, so it stays plain:
integer cell coordinates, one byte per cell, no smoothing, no floats in the buffer.

Coordinates
    (c, r) = (column, row) in whole cells. c grows right, r grows down. Cell (0, 0) is the top-left
    cell and sits at device pixel (0, 0). Cell (c, r) covers device pixels
    x = c*pitch .. c*pitch + pitch-2 and y = r*pitch .. r*pitch + pitch-2; the last pixel column/row
    of every pitch is the black gap.

Colours
    The buffer only holds palette indices: 0 UNLIT, 1 HIGHLIGHT, 2 TEXT, 3 DIM, 4 ALARM.
    palette_for(base) turns them into RGB at render time, so a base-colour change is a palette swap.
    Indices 5..255 are true colours for colour content (band LEDs, wand glow, colour swatches):
    fb.rgb((r, g, b)) allocates one for the current frame (fb.true_colors, deduplicated, reset by
    clear()); every primitive accepts it like an ink. Text and chrome never use true colours.

Drawing state (FrameBuffer)
    A clip-rectangle stack plus a vertical origin offset. push_clip(c, r, w, h, dy=0) intersects the
    clip with the given rect (given in the current drawing coordinates) and then adds dy to the
    vertical origin: every later draw at row r lands on screen row r + origin_y. pop_clip() restores
    both. A scrolling content region is therefore:
        fb.push_clip(0, top, fb.cols, bottom - top, dy=-scroll); draw_content(); fb.pop_clip()
    Everything outside the current clip is discarded.

Text
    text(c, r, ...) puts the top-left of the first glyph box at (c, r); a glyph box is
    SIZES[size]["w"] x SIZES[size]["h"] cells (h includes the descender rows) and glyphs step by
    SIZES[size]["advance"]. text() returns the end column = c + len(s) * advance (the column after
    the last advance). The "ink width" of a string is len(s) * advance - (advance - w): the cells
    from its first glyph's left edge to its last glyph's right edge.

Glyphs come from tools/vfd/vfd_font.py (imported lazily on first text call).

Run `python3 tools/vfd/vfd.py` to draw every primitive and write tools/vfd/out/core_selftest_*.png.
"""

import contextlib
import math
import os
import sys

# ---------------------------------------------------------------------------------------------
# Palette
# ---------------------------------------------------------------------------------------------

UNLIT, HIGHLIGHT, TEXT, DIM, ALARM = 0, 1, 2, 3, 4
NUM_COLORS = 5
FIRST_TRUE_COLOR = NUM_COLORS      # fb.rgb() hands out indices FIRST_TRUE_COLOR .. 255
MAX_TRUE_COLORS = 256 - FIRST_TRUE_COLOR

BACKGROUND_RGB = (0x00, 0x00, 0x00)
UNLIT_RGB = (0x09, 0x09, 0x09)
ALARM_RGB = (0xFF, 0x50, 0x28)

# The AMBER preset uses exactly these colours (spec, "Look").
AMBER_PALETTE = [
    UNLIT_RGB,
    (0xFF, 0xB0, 0x14),  # highlight
    (0xFF, 0xE8, 0xC4),  # text (warm white)
    (0x96, 0x64, 0x28),  # dim amber
    ALARM_RGB,           # red-orange
]

# Base-colour presets, in the order the BASE COLOUR selector shows them (CUSTOM comes after).
PRESETS = {
    "AMBER": (0xFF, 0xB0, 0x14),
    "GREEN": (0x3C, 0xFF, 0x6E),
    "CYAN": (0x30, 0xE8, 0xFF),
    "BLUE": (0x4C, 0xA0, 0xFF),
    "RED": (0xFF, 0x40, 0x30),
    "WHITE": (0xF0, 0xF0, 0xF0),
}

ALARM_HUE_WINDOW = 25.0  # degrees; a base this close to the alarm hue draws alarms inverted
ELLIPSIS = "…"


def _round(x):
    """Round half away from zero (same as Swift's .rounded())."""
    return int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))


def _clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def _resolve_base(base):
    """base -> (preset name or None, (r, g, b)). Accepts a preset name (any case), an (r, g, b)
    tuple/list of 0..255 ints, or a '#RRGGBB' string."""
    if isinstance(base, str):
        key = base.strip().upper()
        if key in PRESETS:
            return key, PRESETS[key]
        hx = key.lstrip("#")
        if len(hx) == 6:
            try:
                v = int(hx, 16)
            except ValueError:
                v = None
            if v is not None:
                return None, ((v >> 16) & 255, (v >> 8) & 255, v & 255)
        raise ValueError("unknown base colour %r (presets: %s)" % (base, ", ".join(PRESETS)))
    if len(base) != 3:
        raise ValueError("base colour must be a preset name or (r, g, b), got %r" % (base,))
    return None, tuple(_clamp(int(v), 0, 255) for v in base)


def luma(rgb):
    """Rec. 709 luminance of an 0..255 RGB triple (0..255 float)."""
    r, g, b = rgb
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def hue(rgb):
    """HSV hue in degrees [0, 360), or None for a grey (no hue)."""
    r, g, b = (v / 255.0 for v in rgb)
    mx, mn = max(r, g, b), min(r, g, b)
    d = mx - mn
    if d <= 0:
        return None
    if mx == r:
        h = ((g - b) / d) % 6.0
    elif mx == g:
        h = (b - r) / d + 2.0
    else:
        h = (r - g) / d + 4.0
    return (h * 60.0) % 360.0


def palette_for(base="AMBER"):
    """Palette for a base colour: list of 5 RGB tuples indexed by UNLIT, HIGHLIGHT, TEXT, DIM, ALARM.

    AMBER (by name, or a custom RGB equal to it) is the exact spec palette. Any other base:
      highlight = base
      dim       = 0.59 * (0.85 * base + 0.15 * luma(base))   per channel, luma = Rec. 709
      text      = 0.75 * 255 + 0.25 * base                    per channel
      alarm     = #FF5028, unlit = #090909 (never change)
    Channels are rounded half away from zero and clamped to 0..255.
    """
    name, rgb = _resolve_base(base)
    if name == "AMBER" or rgb == PRESETS["AMBER"]:
        return list(AMBER_PALETTE)
    y = luma(rgb)
    dim = tuple(_clamp(_round(0.59 * (0.85 * v + 0.15 * y)), 0, 255) for v in rgb)
    text = tuple(_clamp(_round(0.75 * 255 + 0.25 * v), 0, 255) for v in rgb)
    return [UNLIT_RGB, tuple(rgb), text, dim, ALARM_RGB]


def alarm_inverted(base="AMBER"):
    """True when the base is red-ish (HSV hue within 25 degrees of the alarm colour's hue): alarms
    are then drawn as inverted highlight blocks (blinking at 1 Hz in the app; previews show the
    "on" phase). Greys have no hue and are never red-ish."""
    _, rgb = _resolve_base(base)
    h = hue(rgb)
    if h is None:
        return False
    d = abs(h - hue(ALARM_RGB)) % 360.0
    return min(d, 360.0 - d) <= ALARM_HUE_WINDOW


# ---------------------------------------------------------------------------------------------
# Devices
# ---------------------------------------------------------------------------------------------

def _ceil_div(a, b):
    return -(-a // b)


class Device:
    """One target screen. cols = px_w // pitch, rows = px_h // pitch,
    safe_top / safe_bottom = rows covered by the safe area = ceil(pt * scale / pitch)."""

    def __init__(self, key, name, px_w, px_h, scale, pitch, safe_top_pt, safe_bottom_pt):
        self.key = key
        self.name = name
        self.px_w = px_w
        self.px_h = px_h
        self.scale = scale
        self.pitch = pitch
        self.safe_top_pt = safe_top_pt
        self.safe_bottom_pt = safe_bottom_pt
        self.cols = px_w // pitch
        self.rows = px_h // pitch
        self.safe_top = _ceil_div(safe_top_pt * scale, pitch)        # rows 0 .. safe_top-1 stay empty
        self.safe_bottom = _ceil_div(safe_bottom_pt * scale, pitch)  # last safe_bottom rows stay empty

    def framebuffer(self, base="AMBER"):
        """A blank FrameBuffer of this device's size, set up for the given base colour."""
        fb = FrameBuffer(self.cols, self.rows, alarm_inverted=alarm_inverted(base))
        fb.base = base                         # the base colour (preset name or "#RRGGBB") drawn in
        return fb

    def __repr__(self):
        return "Device(%s %s %dx%dpx pitch %d -> %dx%d cells, safe %d/%d rows)" % (
            self.key, self.name, self.px_w, self.px_h, self.pitch, self.cols, self.rows,
            self.safe_top, self.safe_bottom)


DEVICES = {
    "pro": Device("pro", "iPhone 17 Pro", 1206, 2622, 3, 5, 62, 34),  # 241 x 524, safe 38 / 21
    "x2": Device("x2", "iPhone 11", 828, 1792, 2, 4, 48, 34),         # 207 x 448, safe 24 / 17
}


# ---------------------------------------------------------------------------------------------
# Font access (vfd_font is imported lazily: it is a separate module with its own owner)
# ---------------------------------------------------------------------------------------------

_font_module = None


def _font():
    global _font_module
    if _font_module is None:
        try:
            import vfd_font
        except ImportError:
            here = os.path.dirname(os.path.abspath(__file__))
            if here not in sys.path:
                sys.path.append(here)
            import vfd_font
        _font_module = vfd_font
    return _font_module


def metrics(size="small"):
    """Font metrics dict for a size: w, h (incl. descender), ascent, advance, line."""
    sizes = _font().SIZES
    if size not in sizes:
        raise ValueError("unknown text size %r (sizes: %s)" % (size, ", ".join(sizes)))
    return sizes[size]


NBSP = "\u00a0"


def _glyph_rows(ch, size, m):
    """Row bitmaps for one character (h ints, bit 0 = leftmost). vfd_font.glyph() already falls
    back to a hollow box for unknown characters; this guards against it raising anyway."""
    if ch == NBSP:                     # no-break space: drawn as a space, only wrapping differs
        ch = " "
    try:
        rows = _font().glyph(ch, size)
    except (KeyError, ValueError, IndexError, TypeError):
        rows = None
    if rows is None:
        w, a = m["w"], m["ascent"]
        edge = (1 << w) - 1
        side = 1 | (1 << (w - 1))
        rows = [edge] + [side] * (a - 2) + [edge] + [0] * (m["h"] - a)
    return rows


def text_width(s, size="small"):
    """Ink width of s in cells: len(s) * advance - (advance - w); 0 for an empty string."""
    if not s:
        return 0
    m = metrics(size)
    return len(s) * m["advance"] - (m["advance"] - m["w"])


def max_chars(max_cols, size="small"):
    """Largest number of characters whose ink width fits in max_cols cells."""
    m = metrics(size)
    if max_cols < m["w"]:
        return 0
    return (max_cols + m["advance"] - m["w"]) // m["advance"]


def fit_text(s, max_cols, size="small"):
    """s unchanged if it fits in max_cols cells, else cut and ended with '…' so the result
    (ellipsis included) fits. Trailing spaces before the ellipsis are dropped."""
    n = max_chars(max_cols, size)
    if len(s) <= n:
        return s
    if n <= 0:
        return ""
    return s[:n - 1].rstrip() + ELLIPSIS


#: Separator words wrap_text never puts at the start of a line: a lone "·" falling on a break is
#: dropped (the break separates), a dash stays at the end of the line before it with its word.
WRAP_DOT = "·"
WRAP_DASHES = ("—", "–")


def wrap_text(s, max_cols, size="small"):
    """Word-wrap s into lines that fit max_cols cells. Breaks on plain spaces (runs collapse; a
    U+00A0 no-break space never breaks), hard-breaks words longer than a line, and honours '\\n' as
    a line break (blank lines kept). Separators: a lone ' · ' that falls on a break is dropped, so
    no line starts or ends with '·'; a lone dash (— –) stays at the end of the line, taking the
    word before it along when it would not fit."""
    n = max_chars(max_cols, size)
    if n <= 0 or not s:
        return []
    out = []
    for para in s.split("\n"):
        cur = ""
        for word in para.split(" "):
            if not word:
                continue
            if cur and len(cur) + 1 + len(word) <= n:
                cur += " " + word
                continue
            if word == WRAP_DOT:            # a separator on the break: the break replaces it
                if cur:
                    out.append(cur)
                cur = ""
                continue
            if word in WRAP_DASHES and cur and " " in cur:
                head, last = cur.rsplit(" ", 1)
                if head.endswith(" " + WRAP_DOT):
                    head = head[:-2]
                out.append(head)
                cur = last + " " + word
                continue
            if cur:
                if cur.endswith(" " + WRAP_DOT):
                    cur = cur[:-2]
                out.append(cur)
            while len(word) > n:
                out.append(word[:n])
                word = word[n:]
            cur = word
        if cur.endswith(" " + WRAP_DOT):
            cur = cur[:-2]
        out.append(cur)
    return out


# ---------------------------------------------------------------------------------------------
# Frame buffer
# ---------------------------------------------------------------------------------------------

LED_BAR_H = 6  # rows an led_bar occupies (r .. r+5)


class FrameBuffer:
    """cols x rows cells, one byte per cell = palette index. All drawing is in whole cells and
    goes through the current clip rectangle and vertical origin offset (see module docstring)."""

    def __init__(self, cols, rows, alarm_inverted=False):
        self.cols = cols
        self.rows = rows
        self.cells = bytearray(cols * rows)
        self.taps = []                         # (c, r, w, h, name) in screen cells, last = topmost
        self.scroll_regions = []               # (id, c, r, w, h, content_rows) in screen cells
        self.true_colors = []                  # RGB of index FIRST_TRUE_COLOR + i, this frame only
        self.alarm_inverted = alarm_inverted   # set from vfd.alarm_inverted(base); used by alarm()
        self._clip = (0, 0, cols, rows)        # screen cells: c0, r0, c1, r1 (c1/r1 exclusive)
        self._oy = 0                           # vertical origin offset added to every row
        self._stack = []
        self.base = None                       # base colour; Device.framebuffer() sets it

    # --- state ----------------------------------------------------------------------------------

    @property
    def origin_y(self):
        """Current vertical origin offset (drawing row r lands on screen row r + origin_y)."""
        return self._oy

    @property
    def clip_rect(self):
        """Current clip as (c, r, w, h) in screen cells."""
        c0, r0, c1, r1 = self._clip
        return (c0, r0, c1 - c0, r1 - r0)

    def push_clip(self, c, r, w, h, dy=0):
        """Intersect the clip with rect (c, r, w, h), given in current drawing coordinates, then add
        dy to the vertical origin offset (dy = -scroll for a scrolled content region)."""
        self._stack.append((self._clip, self._oy))
        c0, r0, c1, r1 = self._clip
        r += self._oy
        nc0, nr0 = max(c0, c), max(r0, r)
        nc1, nr1 = min(c1, c + w), min(r1, r + h)
        self._clip = (nc0, nr0, max(nc0, nc1), max(nr0, nr1))
        self._oy += dy

    def pop_clip(self):
        """Restore the clip and origin offset saved by the matching push_clip()."""
        if not self._stack:
            raise IndexError("pop_clip() without a matching push_clip()")
        self._clip, self._oy = self._stack.pop()

    @contextlib.contextmanager
    def clipped(self, c, r, w, h, dy=0):
        """with fb.clipped(...): push_clip on entry, pop_clip on exit."""
        self.push_clip(c, r, w, h, dy)
        try:
            yield self
        finally:
            self.pop_clip()

    def clear(self, color=UNLIT):
        """Set every cell to color (ignores the clip) and forget all tap rectangles, scroll regions
        and true colours."""
        self._check(color)
        self.cells[:] = bytes([color]) * (self.cols * self.rows)
        self.taps = []
        self.scroll_regions = []
        self.true_colors = []

    def get(self, c, r):
        """Palette index at screen cell (c, r), ignoring clip and origin; 0 outside the buffer."""
        if 0 <= c < self.cols and 0 <= r < self.rows:
            return self.cells[r * self.cols + c]
        return UNLIT

    def _check(self, color):
        top = NUM_COLORS + len(self.true_colors)
        if not (isinstance(color, int) and 0 <= color < top):
            raise ValueError("color must be a palette index 0..%d, got %r" % (top - 1, color))

    # --- true colours ---------------------------------------------------------------------------

    def rgb(self, rgb):
        """Cell index for a true colour (r, g, b) (0..255 each, or '#RRGGBB') in this frame:
        FIRST_TRUE_COLOR + its position in fb.true_colors. The same colour gets the same index; once
        all MAX_TRUE_COLORS slots are used, the nearest colour already in the table (smallest squared
        RGB distance, the first one on a tie) is returned instead."""
        if isinstance(rgb, str):
            _, rgb = _resolve_base(rgb if rgb.startswith("#") else "#" + rgb)
        key = tuple(_clamp(int(v), 0, 255) for v in rgb)
        if len(key) != 3:
            raise ValueError("true colour must be (r, g, b), got %r" % (rgb,))
        for i, have in enumerate(self.true_colors):
            if have == key:
                return FIRST_TRUE_COLOR + i
        if len(self.true_colors) < MAX_TRUE_COLORS:
            self.true_colors.append(key)
            return FIRST_TRUE_COLOR + len(self.true_colors) - 1
        best, best_d = 0, None
        for i, (r, g, b) in enumerate(self.true_colors):
            d = (r - key[0]) ** 2 + (g - key[1]) ** 2 + (b - key[2]) ** 2
            if best_d is None or d < best_d:
                best, best_d = i, d
        return FIRST_TRUE_COLOR + best

    # --- primitives -----------------------------------------------------------------------------

    def set(self, c, r, color):
        """Light one cell."""
        self._check(color)
        r += self._oy
        c0, r0, c1, r1 = self._clip
        if c0 <= c < c1 and r0 <= r < r1:
            self.cells[r * self.cols + c] = color

    def fill(self, c, r, w, h, color):
        """Solid w x h rectangle with its top-left cell at (c, r)."""
        self._check(color)
        r += self._oy
        c0, r0, c1, r1 = self._clip
        ca, cb = max(c, c0), min(c + w, c1)
        ra, rb = max(r, r0), min(r + h, r1)
        if ca >= cb or ra >= rb:
            return
        run = bytes([color]) * (cb - ca)
        for y in range(ra, rb):
            i = y * self.cols
            self.cells[i + ca:i + cb] = run

    def hline(self, c, r, length, color, step=1):
        """Horizontal line of length cells from (c, r) to the right; step=2 lights every other
        cell (dotted), starting with (c, r)."""
        if step < 1:
            raise ValueError("step must be >= 1")
        if step == 1:
            self.fill(c, r, length, 1, color)
            return
        for i in range(0, length, step):
            self.set(c + i, r, color)

    def vline(self, c, r, length, color, step=1):
        """Vertical line of length cells from (c, r) downwards; step as for hline."""
        if step < 1:
            raise ValueError("step must be >= 1")
        if step == 1:
            self.fill(c, r, 1, length, color)
            return
        for i in range(0, length, step):
            self.set(c, r + i, color)

    def box(self, c, r, w, h, color):
        """1-cell border of a w x h rectangle whose top-left cell is (c, r)."""
        if w <= 0 or h <= 0:
            return
        self.fill(c, r, w, 1, color)
        self.fill(c, r + h - 1, w, 1, color)
        self.fill(c, r, 1, h, color)
        self.fill(c + w - 1, r, 1, h, color)

    # --- text -----------------------------------------------------------------------------------

    def _blit(self, c, r, rows, w, h, color):
        c0, r0, c1, r1 = self._clip
        cols, cells, oy = self.cols, self.cells, self._oy
        mask = (1 << w) - 1
        for dy in range(min(h, len(rows))):
            bits = rows[dy] & mask
            y = r + dy + oy
            if not bits or y < r0 or y >= r1:
                continue
            base = y * cols
            x = c
            while bits:
                if bits & 1 and c0 <= x < c1:
                    cells[base + x] = color
                bits >>= 1
                x += 1

    def text(self, c, r, s, size="small", color=TEXT):
        """Draw s with the first glyph box's top-left at (c, r). Any character is accepted
        (unknown ones get the font's fallback glyph). Returns the end column c + len(s)*advance."""
        self._check(color)
        m = metrics(size)
        w, h, adv = m["w"], m["h"], m["advance"]
        x = c
        for ch in s:
            self._blit(x, r, _glyph_rows(ch, size, m), w, h, color)
            x += adv
        return x

    def text_right(self, right_c, r, s, size="small", color=TEXT):
        """Draw s so its ink ends exactly on column right_c (inclusive). Returns the start column."""
        start = right_c - text_width(s, size) + 1
        self.text(start, r, s, size, color)
        return start

    def text_fit(self, c, r, s, max_cols, size="small", color=TEXT):
        """Draw s at (c, r), truncated with '…' so its ink fits in max_cols cells. Returns the end
        column (as text())."""
        return self.text(c, r, fit_text(s, max_cols, size), size, color)

    def paragraph(self, c, r, s, max_cols, size="small", color=TEXT, line=None):
        """Word-wrapped text in a column max_cols cells wide; line = row pitch between lines
        (default SIZES[size]["line"]). Returns the next row = r + lines * line."""
        lines = wrap_text(s, max_cols, size)
        step = metrics(size)["line"] if line is None else line
        for i, ln in enumerate(lines):
            self.text(c, r + i * step, ln, size, color)
        return r + len(lines) * step

    def inverted(self, c, r, s, size="small", pad=1, color=HIGHLIGHT):
        """Inverted text: a solid block in color with the glyph cells cut out (left at index 0).
        The text sits where text(c, r, s) would put it; the block covers its ink width x h rows
        (descender included) plus pad cells on every side, i.e. columns c-pad .. c+ink-1+pad and
        rows r-pad .. r+h-1+pad. Returns the column after the block (c + ink width + pad); for
        small text with pad=1 that equals text()'s end column, so the two are interchangeable."""
        tw = text_width(s, size)
        if tw == 0:
            return c
        m = metrics(size)
        self.fill(c - pad, r - pad, tw + 2 * pad, m["h"] + 2 * pad, color)
        self.text(c, r, s, size, UNLIT)
        return c + tw + pad

    def alarm(self, c, r, s, size="small", pad=1):
        """Alarm text. Normally text in ALARM colour; when fb.alarm_inverted (red-ish base) an
        inverted HIGHLIGHT block instead. Same footprint and return value as inverted(), so the
        layout does not change with the base colour."""
        if self.alarm_inverted:
            return self.inverted(c, r, s, size, pad, HIGHLIGHT)
        self.text(c, r, s, size, ALARM)
        tw = text_width(s, size)
        return c + tw + pad if tw else c

    # --- indicators -----------------------------------------------------------------------------

    def led_bar(self, c, r, w, frac, color=HIGHLIGHT, track=DIM, marker=False, zone=None):
        """LED bar, w cells wide, LED_BAR_H (6) rows tall from row r.
        Track: dotted (every other cell from c) on the two middle rows (r+2, r+3), full width.
        marker=False: solid lit zone from c for round(frac * w) cells on rows r+1 .. r+4.
        marker=True: a 3-wide x 6-tall marker centred on column c + round(frac * (w-1)), kept
        inside the bar. zone=(lo, hi) optionally draws a solid target zone (fractions of w) on the
        track rows in color. frac is clamped to 0..1. Returns the next row (r + 6)."""
        if w <= 0:
            return r + LED_BAR_H
        frac = _clamp(float(frac), 0.0, 1.0)
        self.hline(c, r + 2, w, track, step=2)
        self.hline(c, r + 3, w, track, step=2)
        if zone is not None:
            lo = _clamp(float(zone[0]), 0.0, 1.0)
            hi = _clamp(float(zone[1]), 0.0, 1.0)
            a, b = c + _round(lo * w), c + _round(hi * w)
            self.fill(min(a, b), r + 2, abs(b - a), 2, color)
        if marker:
            mw = min(3, w)
            left = c + _round(frac * (w - 1)) - 1
            left = _clamp(left, c, c + w - mw)
            self.fill(left, r, mw, LED_BAR_H, color)
        else:
            self.fill(c, r + 1, _round(frac * w), 4, color)
        return r + LED_BAR_H

    def line_chart(self, c, r, w, h, values, color=HIGHLIGHT, vmin=None, vmax=None, baseline=DIM):
        """Single-cell line chart in the w x h box at (c, r). values are resampled (linear) to one
        value per column and scaled so vmin (default min) sits on the bottom row r+h-1 and vmax
        (default max) on the top row r; a flat series sits on the middle row. Steps of more than
        one row between neighbouring columns are joined vertically (half in each column) so the
        line stays continuous. A None value leaves a gap. The baseline is a dotted dim row on
        r+h-1, drawn first. Returns the next row (r + h)."""
        if w <= 0 or h <= 0:
            return r + max(h, 0)
        if baseline is not None:
            self.hline(c, r + h - 1, w, baseline, step=2)
        vals = _resample(list(values), w)
        present = [v for v in vals if v is not None]
        if not present:
            return r + h
        lo = min(present) if vmin is None else vmin
        hi = max(present) if vmax is None else vmax
        bottom = r + h - 1
        ys = []
        for v in vals:
            if v is None:
                ys.append(None)
            elif hi == lo:
                ys.append(r + (h - 1) // 2)
            else:
                y = bottom - _round((v - lo) / float(hi - lo) * (h - 1))
                ys.append(_clamp(y, r, bottom))
        prev = None
        for i, y in enumerate(ys):
            if y is None:
                prev = None
                continue
            x = c + i
            self.set(x, y, color)
            if prev is not None:
                if y > prev + 1:                # going down: prev column takes the upper half
                    m = (prev + y) // 2
                    self.vline(x - 1, prev, m - prev + 1, color)
                    self.vline(x, m + 1, y - m, color)
                elif y < prev - 1:              # going up: prev column takes the lower half
                    m = (prev + y + 1) // 2
                    self.vline(x - 1, m, prev - m + 1, color)
                    self.vline(x, y, m - y, color)
            prev = y
        return r + h

    # --- interaction ----------------------------------------------------------------------------

    def tap(self, c, r, w, h, name):
        """Record a hit rectangle (drawing coordinates, clipped like drawing) under name. Later
        rectangles are on top. Not drawn; kept so the Swift port has the same call sites."""
        r += self._oy
        c0, r0, c1, r1 = self._clip
        ca, cb = max(c, c0), min(c + w, c1)
        ra, rb = max(r, r0), min(r + h, r1)
        if ca < cb and ra < rb:
            self.taps.append((ca, ra, cb - ca, rb - ra, name))

    def hit(self, c, r):
        """Name of the topmost tap rectangle containing screen cell (c, r), or None."""
        for tc, tr, tw, th, name in reversed(self.taps):
            if tc <= c < tc + tw and tr <= r < tr + th:
                return name
        return None

    def scroll_region(self, region_id, c, r, w, h, content_rows):
        """Record a sub-area that scrolls on its own (a list under pinned rows): drags that start
        inside it scroll it instead of the page. Drawing coordinates, clipped like tap(); content_rows
        is the height of everything it scrolls. Later regions are on top. Not drawn."""
        r += self._oy
        c0, r0, c1, r1 = self._clip
        ca, cb = max(c, c0), min(c + w, c1)
        ra, rb = max(r, r0), min(r + h, r1)
        if ca < cb and ra < rb:
            self.scroll_regions.append((region_id, ca, ra, cb - ca, rb - ra, content_rows))

    def scroll_region_at(self, c, r):
        """Id of the topmost scroll region containing screen cell (c, r), or None."""
        for rid, tc, tr, tw, th, _ in reversed(self.scroll_regions):
            if tc <= c < tc + tw and tr <= r < tr + th:
                return rid
        return None

    # --- debugging ------------------------------------------------------------------------------

    def ascii(self, c=0, r=0, w=None, h=None):
        """Screen region as text, one line per row: '.' unlit, else the palette index digit."""
        w = self.cols - c if w is None else w
        h = self.rows - r if h is None else h
        lines = []
        for y in range(r, r + h):
            lines.append("".join("." if not self.get(x, y) else str(self.get(x, y))
                                 for x in range(c, c + w)))
        return "\n".join(lines)


def _resample(values, w):
    """Linear resample of values (None = gap) to exactly w samples."""
    n = len(values)
    if n == 0 or w <= 0:
        return []
    if n == w:
        return values
    out = []
    for i in range(w):
        t = i * (n - 1) / float(w - 1) if w > 1 else 0.0
        k = int(t)
        f = t - k
        a = values[k]
        if f == 0 or k + 1 >= n:
            out.append(a)
            continue
        b = values[k + 1]
        out.append(None if a is None or b is None else a + (b - a) * f)
    return out


# ---------------------------------------------------------------------------------------------
# PNG output
# ---------------------------------------------------------------------------------------------

def render_image(fb, device, base="AMBER"):
    """The frame buffer as a PIL RGB image of device.px_w x device.px_h: pure black canvas, each
    cell a (pitch-1) x (pitch-1) square at (c*pitch, r*pitch), unlit #090909, lit = palette colour
    (indices 0..4) or true colour (fb.true_colors from index 5); leftover pixels at the right/bottom
    edges stay black."""
    from PIL import Image, ImageDraw

    p = device.pitch
    if p < 2:
        raise ValueError("pitch must be >= 2 (1 px gap)")
    pal = palette_for(base) + list(getattr(fb, "true_colors", []))
    flat = []
    for rgb in pal[:256]:
        flat.extend(rgb)
    flat.extend([0] * (768 - len(flat)))

    cells = Image.frombytes("P", (fb.cols, fb.rows), bytes(fb.cells))
    nearest = getattr(Image, "Resampling", Image).NEAREST
    big = cells.resize((fb.cols * p, fb.rows * p), nearest)
    big.putpalette(flat)
    big = big.convert("RGB")
    draw = ImageDraw.Draw(big)          # the 1 px black gaps, drawn after the palette lookup so
    bw, bh = big.size                   # all 256 indices stay free for cells
    for c in range(fb.cols):
        x = c * p + p - 1
        draw.line([(x, 0), (x, bh - 1)], fill=BACKGROUND_RGB)
    for r in range(fb.rows):
        y = r * p + p - 1
        draw.line([(0, y), (bw - 1, y)], fill=BACKGROUND_RGB)

    canvas = Image.new("RGB", (device.px_w, device.px_h), BACKGROUND_RGB)
    canvas.paste(big.crop((0, 0, min(bw, device.px_w), min(bh, device.px_h))), (0, 0))
    return canvas


def render_png(fb, device, base, path):
    """Render fb for device in the palette of base and save it as a PNG at path. Returns path."""
    img = render_image(fb, device, base)
    folder = os.path.dirname(os.path.abspath(path))
    if not os.path.isdir(folder):
        os.makedirs(folder)
    img.save(path)
    return path


# ---------------------------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------------------------

def draw_selftest(fb, device):
    """Draw every primitive onto fb (a device-sized buffer), keeping out of the safe-area rows."""
    L, R = 3, fb.cols - 4                       # left / right margin columns (inclusive)
    top = device.safe_top + 2
    bottom = fb.rows - device.safe_bottom       # first safe-area row at the bottom
    width = R - L + 1
    half = L + width // 2
    fb.push_clip(0, device.safe_top, fb.cols, bottom - device.safe_top)  # never touch the safe areas

    # header: title (mid), right-aligned info (small), solid + dotted dividers
    fb.text(L, top, "VFD CORE", "mid", HIGHLIGHT)
    fb.text_right(R, top + 4, "%s %dX%d" % (device.key.upper(), fb.cols, fb.rows), "small", DIM)
    y = top + 20
    fb.hline(L, y, width, DIM)
    fb.hline(L, y + 2, width, DIM, step=2)
    y += 6

    # text sizes and colours
    end = fb.text(L, y, "SMALL 5X7 ", "small", DIM)
    fb.text(end, y, "Agjpqy 0123 °µΔ±→✓ €?", "small", TEXT)
    y += 12
    end = fb.text(L, y, "MID ", "mid", DIM)
    fb.text(end, y, "Agjy 42", "mid", TEXT)
    y += 21
    end = fb.text(L, y, "1284", "big", HIGHLIGHT)
    fb.text(end + 2, y + 14, "RX", "small", DIM)
    fb.text_right(R, y, "-3.5", "big", ALARM)
    y += 31

    # palette swatches with labels
    x = L
    for idx, label in ((HIGHLIGHT, "HI"), (TEXT, "TEXT"), (DIM, "DIM"), (ALARM, "ALARM")):
        fb.fill(x, y, 12, 7, idx)
        x = fb.text(x + 14, y, label, "small", idx) + 6
    y += 12

    # boxes, set() checker, dotted vline
    fb.box(L, y, 40, 20, HIGHLIGHT)
    fb.box(L + 2, y + 2, 36, 16, DIM)
    fb.fill(L + 4, y + 4, 32, 12, TEXT)
    fb.box(L + 44, y, 1, 1, HIGHLIGHT)           # degenerate 1x1 box = one cell
    for i in range(8):
        for j in range(8):
            if (i + j) % 2 == 0:
                fb.set(L + 48 + i, y + j, TEXT)
    fb.vline(L + 60, y, 20, DIM, step=2)
    fb.vline(L + 62, y, 20, HIGHLIGHT)
    fb.hline(L + 66, y, 30, DIM, step=3)
    fb.text(L + 66, y + 4, "STEP 3", "small", DIM)
    y += 24

    # inverted highlights (tab-bar style row) + alarm
    x = L + 1
    for i, tab in enumerate(("SCAN", "TX", "WAND", "AUTO")):
        if i == 1:
            x = fb.inverted(x, y, tab, "small") + 3
        else:
            x = fb.text(x, y, tab, "small", TEXT) + 3
    x = fb.alarm(x + 4, y, "RSSI LOW", "small")
    fb.inverted(R - text_width("[CUSTOM]") + 1 - 1, y, "[CUSTOM]", "small", 1, DIM)
    y += 13
    x = fb.inverted(L + 2, y + 2, "OK", "mid", pad=2)
    x = fb.inverted(x + 6, y + 2, "Gj", "mid", pad=1, color=TEXT)
    fb.inverted(x + 6, y + 2, "42", "big", pad=2)
    x = fb.text(half + 20, y + 2, "BTN", "small", TEXT)
    y += 34

    # truncated text: marker box shows the max_cols limit
    for i, n in enumerate((60, 35, 11, 4)):
        fb.vline(L + n, y + i * 11, 9, DIM)
        fb.text_fit(L, y + i * 11, "CA:FE:BA:BE 7F3A9C21 LONG HEX PAYLOAD", n, "small", TEXT)
    fb.text_fit(half, y, "TRUNCATED MID TITLE", R - half + 1, "mid", HIGHLIGHT)
    y += 46

    # paragraph in a dim box
    pw = 140
    ny = fb.paragraph(L + 2, y + 2, "Word wrap on spaces; SUPERCALIFRAGILISTICEXPIALIDOCIOUS words "
                                    "hard-break. Units go in the label row.\nNew line.", pw, "small", TEXT)
    fb.box(L, y, pw + 4, ny - y + 1, DIM)      # box sized from the returned next row
    fb.text(L + pw + 8, y + 2, "NEXT ROW +%d" % (ny - y - 2), "small", DIM)
    y = ny + 5

    # LED bars
    bw = width - 40
    for label, frac, kw in (("0%", 0.0, {}), ("37%", 0.37, {}), ("100%", 1.0, {}),
                            ("MK 0", 0.0, {"marker": True}), ("MK 50", 0.5, {"marker": True}),
                            ("MK 1", 1.0, {"marker": True, "zone": (0.6, 0.85)}),
                            ("ZONE", 0.7, {"marker": True, "zone": (0.55, 0.8)})):
        fb.text(L, y, label, "small", DIM)
        fb.led_bar(L + 40, y, bw, frac, **kw)
        y += 9
    y += 3

    # line charts: smooth wave, steep steps, gaps, fewer points than columns
    ch = 40
    cw = width // 2 - 3
    wave = [math.sin(i / 7.0) * (1 + i / 60.0) for i in range(cw)]
    fb.box(L, y, cw, ch, DIM)
    fb.line_chart(L + 1, y + 1, cw - 2, ch - 2, wave)
    steps = [0, 0, 10, 10, 2, 9, 1, 1, 8, 8, 8, 0, 5, None, None, 6, 7, 3, 3, 10]
    fb.line_chart(half, y, cw, ch, steps, color=TEXT)
    y += ch + 4

    # clip + origin offset: a "scrolled" region showing rows 5.. of a list, clipped to its box
    fb.box(L, y, width, 34, DIM)
    with fb.clipped(L + 1, y + 1, width - 2, 32, dy=-5):
        for i in range(8):
            fb.text(L + 2, y + 2 + i * 11, "SCROLLED ROW %d" % i, "small", TEXT if i % 2 else HIGHLIGHT)
        fb.fill(L - 10, y - 10, 8, 200, ALARM)   # entirely outside the clip: must not appear
        fb.tap(L + 1, y + 1, width - 2, 300, "list")
    fb.text(half, y + 2, "CLIP+DY", "mid", DIM)
    y += 38

    # safe-area guide: last drawable row marked by a dotted alarm line
    fb.hline(L, bottom - 1, width, ALARM, step=4)
    fb.tap(0, 0, fb.cols, fb.rows, "screen")
    fb.pop_clip()
    return y


def selftest(out_dir=None):
    """Draw every primitive on a pro-sized buffer and write core_selftest_AMBER.png and
    core_selftest_GREEN.png. Returns the written paths."""
    if out_dir is None:
        out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
    dev = DEVICES["pro"]
    paths = []
    for base in ("AMBER", "GREEN"):
        fb = dev.framebuffer(base)
        end = draw_selftest(fb, dev)
        if end >= dev.rows - dev.safe_bottom - 2:
            raise AssertionError("self-test layout runs into the bottom safe area (row %d)" % end)
        paths.append(render_png(fb, dev, base, os.path.join(out_dir, "core_selftest_%s.png" % base)))
    return paths


if __name__ == "__main__":
    for written in selftest(sys.argv[1] if len(sys.argv) > 1 else None):
        print(written)
