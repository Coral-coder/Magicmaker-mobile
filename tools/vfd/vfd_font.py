#!/usr/bin/env python3
"""VFD bitmap font: an original 5x7 dot-matrix face (+2 descender rows) and its
Scale2x / Scale3x enlargements.

Interface (see tools/vfd/BRIEF.md):
    SMALL_SRC   dict[str, list[str]]  9 rows x 5 chars, "#" lit, "." unlit
    SIZES       {"small"|"mid"|"big": {"w","h","ascent","advance","line"}}
    GLYPHS      {"small"|"mid"|"big": {codepoint: [row ints]}}  bit 0 = leftmost
    scale2x(rows, w, h) / scale3x(rows, w, h)
    glyph(ch, size) -> list[int]   (hollow box for unknown characters)

    python3 tools/vfd/vfd_font.py --sheet OUT.png   renders every glyph at all sizes
    python3 tools/vfd/vfd_font.py --strip OUT.png   legibility strip of MagicMaker strings
    python3 tools/vfd/vfd_font.py --check           validates the source and the scaled sets

Metrics: rows 0-6 are the body (capitals and digits use all 7 rows, the
lowercase x-height is rows 2-6, ascenders start at row 0), rows 7-8 are the
descender (only g j p q y µ , ; reach it). Column 5 of the 6-cell advance is
always the gap. Strokes and dots are one pixel, so every size keeps an even
stroke weight after scaling.

Design rules (a technical, DIN-flavoured face drawn for this app):
- Pinched junction: B, P, R and K share one construction, a short bar from the
  stem met by the bowl or arm on a diagonal (`#..#.` / `###..` / `#..#.`).
- Open apertures with flat terminals: C, G, c, e, f and s end in horizontal
  strokes instead of curling back.
- Digits: dotted 0, flagged 1 with a foot, deep-bowl 2 with a short diagonal,
  round 3, open-top 4, 5 sharing 3's lower bowl, 6 and 9 on straight diagonal
  stems.
- Pointed A; W is an inverted M (vertex at row 4); i and l share a curled foot;
  t has a full ascender and a flat foot.
- Confusables are kept apart by structure, never by a single corner pixel,
  because Scale2x/Scale3x cut every convex square corner: 0 dotted / O plain /
  D straight back with a stepped curve / Q with a tail; 8 round on both sides /
  B straight back with a pinched waist; 1 / I / l / |; 2 / Z; 5 / S; 6 / G / b;
  9 / g / q; A / 4.
- Forms a 5x7 grid allows only one way (H I L N O T U V X Y Z, + = < > ( ) ^ _ |,
  a o v x z) inevitably match other 5x7 faces; every glyph with a real design
  choice follows the rules above.

Scaler behaviour to expect: X crossings and V vertices (X x × * M W m w & ³ and
the Q tail) stay joined corner-to-corner, and where strokes cross (+ ± t f # *)
the inside corners are filled, which gives a small diamond hub at big size.
Both are the algorithms' normal output; check() guards against real defects
(broken or merged strokes, lost or extra counters, 1-cell notches).
"""

import sys

# ---------------------------------------------------------------------------
# Source glyphs. Each entry lists the body rows top to bottom; missing rows at
# the bottom (normally the two descender rows) are blank.
# ---------------------------------------------------------------------------

_RAW = {
    # ---- punctuation & symbols (ASCII 32-47) ----
    " ": """
.....
""",
    "!": """
..#..
..#..
..#..
..#..
..#..
.....
..#..
""",
    '"': """
.#.#.
.#.#.
""",
    "#": """
.....
.#.#.
#####
.#.#.
.#.#.
#####
.#.#.
""",
    "$": """
..#..
.####
#....
.###.
....#
####.
..#..
""",
    "%": """
##..#
##.#.
...#.
..#..
.#...
.#.##
#..##
""",
    "&": """
.##..
#..#.
#.#..
.#...
#.#..
#..#.
.##.#
""",
    "'": """
..#..
..#..
""",
    "(": """
...#.
..#..
.#...
.#...
.#...
..#..
...#.
""",
    ")": """
.#...
..#..
...#.
...#.
...#.
..#..
.#...
""",
    "*": """
..#..
#.#.#
.###.
#.#.#
..#..
""",
    "+": """
.....
..#..
..#..
#####
..#..
..#..
.....
""",
    ",": """
.....
.....
.....
.....
.....
..#..
..#..
.#...
""",
    "-": """
.....
.....
.....
.###.
""",
    ".": """
.....
.....
.....
.....
.....
.....
..#..
""",
    "/": """
....#
...#.
...#.
..#..
.#...
.#...
#....
""",
    # ---- digits ----
    "0": """
.###.
#...#
#...#
#.#.#
#...#
#...#
.###.
""",
    "1": """
..#..
.##..
#.#..
..#..
..#..
..#..
.###.
""",
    "2": """
.###.
#...#
....#
....#
...#.
..#..
#####
""",
    "3": """
.###.
#...#
....#
..##.
....#
#...#
.###.
""",
    "4": """
#..#.
#..#.
#..#.
#..#.
#####
...#.
...#.
""",
    "5": """
#####
#....
#....
####.
....#
#...#
.###.
""",
    "6": """
...#.
..#..
.#...
####.
#...#
#...#
.###.
""",
    "7": """
#####
....#
...#.
..#..
..#..
..#..
..#..
""",
    "8": """
.###.
#...#
#...#
.###.
#...#
#...#
.###.
""",
    "9": """
.###.
#...#
#...#
.####
...#.
..#..
.#...
""",
    # ---- ASCII 58-64 ----
    ":": """
.....
.....
..#..
.....
.....
..#..
.....
""",
    ";": """
.....
.....
..#..
.....
.....
..#..
..#..
.#...
""",
    "<": """
...#.
..#..
.#...
#....
.#...
..#..
...#.
""",
    "=": """
.....
.....
#####
.....
#####
.....
.....
""",
    ">": """
.#...
..#..
...#.
....#
...#.
..#..
.#...
""",
    "?": """
.###.
#...#
....#
..##.
..#..
.....
..#..
""",
    "@": """
.###.
#...#
#.###
#.#.#
#.##.
#....
.####
""",
    # ---- capitals ----
    "A": """
..#..
.#.#.
#...#
#...#
#####
#...#
#...#
""",
    "B": """
####.
#...#
#..#.
###..
#..#.
#...#
####.
""",
    "C": """
.####
#....
#....
#....
#....
#....
.####
""",
    "D": """
###..
#..#.
#...#
#...#
#...#
#..#.
###..
""",
    "E": """
#####
#....
#....
###..
#....
#....
#####
""",
    "F": """
#####
#....
#....
###..
#....
#....
#....
""",
    "G": """
.####
#....
#....
#..##
#...#
#...#
.###.
""",
    "H": """
#...#
#...#
#...#
#####
#...#
#...#
#...#
""",
    "I": """
.###.
..#..
..#..
..#..
..#..
..#..
.###.
""",
    "J": """
..###
....#
....#
....#
....#
#...#
.###.
""",
    "K": """
#...#
#...#
#..#.
###..
#..#.
#...#
#...#
""",
    "L": """
#....
#....
#....
#....
#....
#....
#####
""",
    "M": """
#...#
##.##
#.#.#
#...#
#...#
#...#
#...#
""",
    "N": """
#...#
#...#
##..#
#.#.#
#..##
#...#
#...#
""",
    "O": """
.###.
#...#
#...#
#...#
#...#
#...#
.###.
""",
    "P": """
####.
#...#
#...#
#..#.
###..
#....
#....
""",
    "Q": """
.###.
#...#
#...#
#...#
#.#.#
#..#.
.##.#
""",
    "R": """
####.
#...#
#..#.
###..
#..#.
#...#
#...#
""",
    "S": """
.###.
#...#
#....
.###.
....#
#...#
.###.
""",
    "T": """
#####
..#..
..#..
..#..
..#..
..#..
..#..
""",
    "U": """
#...#
#...#
#...#
#...#
#...#
#...#
.###.
""",
    "V": """
#...#
#...#
#...#
#...#
#...#
.#.#.
..#..
""",
    "W": """
#...#
#...#
#...#
#...#
#.#.#
##.##
#...#
""",
    "X": """
#...#
#...#
.#.#.
..#..
.#.#.
#...#
#...#
""",
    "Y": """
#...#
#...#
.#.#.
..#..
..#..
..#..
..#..
""",
    "Z": """
#####
....#
...#.
..#..
.#...
#....
#####
""",
    # ---- ASCII 91-96 ----
    "[": """
.###.
.#...
.#...
.#...
.#...
.#...
.###.
""",
    "\\": """
#....
.#...
.#...
..#..
...#.
...#.
....#
""",
    "]": """
.###.
...#.
...#.
...#.
...#.
...#.
.###.
""",
    "^": """
..#..
.#.#.
#...#
""",
    "_": """
.....
.....
.....
.....
.....
.....
#####
""",
    "`": """
.#...
..#..
""",
    # ---- lowercase ----
    "a": """
.....
.....
.###.
....#
.####
#...#
.####
""",
    "b": """
#....
#....
####.
#...#
#...#
#...#
####.
""",
    "c": """
.....
.....
.####
#....
#....
#....
.####
""",
    "d": """
....#
....#
.####
#...#
#...#
#...#
.####
""",
    "e": """
.....
.....
.###.
#...#
#####
#....
.####
""",
    "f": """
..###
.#...
####.
.#...
.#...
.#...
.#...
""",
    "g": """
.....
.....
.####
#...#
#...#
#...#
.####
....#
.###.
""",
    "h": """
#....
#....
####.
#...#
#...#
#...#
#...#
""",
    "i": """
..#..
.....
.##..
..#..
..#..
..#..
...##
""",
    "j": """
...#.
.....
..##.
...#.
...#.
...#.
...#.
#..#.
.##..
""",
    "k": """
#....
#....
#...#
#..#.
###..
#..#.
#...#
""",
    "l": """
.##..
..#..
..#..
..#..
..#..
..#..
...##
""",
    "m": """
.....
.....
##.#.
#.#.#
#.#.#
#.#.#
#.#.#
""",
    "n": """
.....
.....
####.
#...#
#...#
#...#
#...#
""",
    "o": """
.....
.....
.###.
#...#
#...#
#...#
.###.
""",
    "p": """
.....
.....
####.
#...#
#...#
#...#
####.
#....
#....
""",
    "q": """
.....
.....
.####
#...#
#...#
#...#
.####
....#
....#
""",
    "r": """
.....
.....
#.###
##...
#....
#....
#....
""",
    "s": """
.....
.....
.####
#....
.###.
....#
####.
""",
    "t": """
.#...
.#...
####.
.#...
.#...
.#...
..##.
""",
    "u": """
.....
.....
#...#
#...#
#...#
#...#
.####
""",
    "v": """
.....
.....
#...#
#...#
#...#
.#.#.
..#..
""",
    "w": """
.....
.....
#...#
#...#
#...#
#.#.#
.#.#.
""",
    "x": """
.....
.....
#...#
.#.#.
..#..
.#.#.
#...#
""",
    "y": """
.....
.....
#...#
#...#
#...#
#...#
.####
....#
.###.
""",
    "z": """
.....
.....
#####
...#.
..#..
.#...
#####
""",
    # ---- ASCII 123-126 ----
    "{": """
...##
..#..
..#..
.#...
..#..
..#..
...##
""",
    "|": """
..#..
..#..
..#..
..#..
..#..
..#..
..#..
""",
    "}": """
##...
..#..
..#..
...#.
..#..
..#..
##...
""",
    "~": """
.....
.....
.##.#
#..#.
""",
    # ---- extras ----
    "°": """
.##..
#..#.
#..#.
.##..
""",
    "µ": """
.....
.....
#...#
#...#
#...#
#...#
####.
#....
#....
""",
    "Δ": """
.....
.....
..#..
.#.#.
#...#
#...#
#####
""",
    "±": """
..#..
..#..
#####
..#..
..#..
.....
#####
""",
    "·": """
.....
.....
.....
..#..
""",
    "×": """
.....
#...#
.#.#.
..#..
.#.#.
#...#
.....
""",
    "÷": """
.....
..#..
.....
#####
.....
..#..
.....
""",
    "–": """
.....
.....
.....
#####
""",
    "—": """
.....
.....
.....
#####
""",
    "→": """
.....
..#..
...#.
#####
...#.
..#..
.....
""",
    "←": """
.....
..#..
.#...
#####
.#...
..#..
.....
""",
    "…": """
.....
.....
.....
.....
.....
.....
#.#.#
""",
    "✓": """
.....
.....
....#
...#.
#.#..
.#...
.....
""",
    "²": """
.##..
...#.
..#..
.#...
.###.
""",
    "³": """
.##..
...#.
..#..
...#.
.##..
""",
    "Ω": """
.###.
#...#
#...#
#...#
.#.#.
.#.#.
##.##
""",
    "≤": """
...#.
..#..
.#...
..#..
...#.
.....
.###.
""",
    "≥": """
.#...
..#..
...#.
..#..
.#...
.....
.###.
""",
    "≈": """
.....
.##.#
#..#.
.....
.##.#
#..#.
.....
""",
    "‘": """
...#.
..#..
..#..
""",
    "’": """
..#..
..#..
.#...
""",
    "“": """
.#..#
#..#.
#..#.
""",
    "”": """
.#..#
.#..#
#..#.
""",
}

_FALLBACK_RAW = """
#####
#...#
#...#
#...#
#...#
#...#
#####
"""

SRC_W, SRC_H, SRC_ASCENT = 5, 9, 7

# Characters allowed to use the descender rows 7-8.
DESCENDERS = set("gjpqyµ,;")


def _parse(raw):
    lines = [ln.strip() for ln in raw.strip("\n").split("\n")]
    if len(lines) > SRC_H:
        raise ValueError("too many rows")
    lines += ["." * SRC_W] * (SRC_H - len(lines))
    for ln in lines:
        if len(ln) != SRC_W or set(ln) - set("#."):
            raise ValueError("bad row %r" % ln)
    return lines


SMALL_SRC = {ch: _parse(raw) for ch, raw in _RAW.items()}
_FALLBACK_SRC = _parse(_FALLBACK_RAW)

SIZES = {
    "small": {"w": 5, "h": 9, "ascent": 7, "advance": 6, "line": 11},
    "mid": {"w": 10, "h": 18, "ascent": 14, "advance": 12, "line": 20},
    "big": {"w": 15, "h": 27, "ascent": 21, "advance": 18, "line": 29},
}


def src_to_rows(src):
    """'#'/'.' strings -> row ints, bit 0 = leftmost pixel."""
    out = []
    for ln in src:
        v = 0
        for x, c in enumerate(ln):
            if c == "#":
                v |= 1 << x
        out.append(v)
    return out


# ---------------------------------------------------------------------------
# Pixel-art scalers on bit rows (bit 0 = leftmost). Pixels outside the glyph
# box count as unlit.
# ---------------------------------------------------------------------------

def _getter(rows, w, h):
    def px(x, y):
        if 0 <= x < w and 0 <= y < h:
            return (rows[y] >> x) & 1
        return 0
    return px


def scale2x(rows, w, h):
    """Scale2x / EPX (AdvMAME2x). Returns 2*h rows of width 2*w.

        B          E0 E1
      D E F   ->   E2 E3
        H
    """
    px = _getter(rows, w, h)
    out = [0] * (2 * h)
    for y in range(h):
        for x in range(w):
            E = px(x, y)
            B, D, F, H = px(x, y - 1), px(x - 1, y), px(x + 1, y), px(x, y + 1)
            if B != H and D != F:
                e0 = D if D == B else E
                e1 = F if B == F else E
                e2 = D if D == H else E
                e3 = F if H == F else E
            else:
                e0 = e1 = e2 = e3 = E
            ox, oy = 2 * x, 2 * y
            out[oy] |= (e0 << ox) | (e1 << (ox + 1))
            out[oy + 1] |= (e2 << ox) | (e3 << (ox + 1))
    return out


def scale3x(rows, w, h):
    """Scale3x (AdvMAME3x). Returns 3*h rows of width 3*w.

      A B C        E0 E1 E2
      D E F   ->   E3 E4 E5
      G H I        E6 E7 E8
    """
    px = _getter(rows, w, h)
    out = [0] * (3 * h)
    for y in range(h):
        for x in range(w):
            A, B, C = px(x - 1, y - 1), px(x, y - 1), px(x + 1, y - 1)
            D, E, F = px(x - 1, y), px(x, y), px(x + 1, y)
            G, H, I = px(x - 1, y + 1), px(x, y + 1), px(x + 1, y + 1)
            if B != H and D != F:
                e0 = D if D == B else E
                e1 = B if (D == B and E != C) or (B == F and E != A) else E
                e2 = F if B == F else E
                e3 = D if (D == B and E != G) or (D == H and E != A) else E
                e4 = E
                e5 = F if (B == F and E != I) or (H == F and E != C) else E
                e6 = D if D == H else E
                e7 = H if (D == H and E != I) or (H == F and E != G) else E
                e8 = F if H == F else E
            else:
                e0 = e1 = e2 = e3 = e4 = e5 = e6 = e7 = e8 = E
            ox, oy = 3 * x, 3 * y
            out[oy] |= (e0 << ox) | (e1 << (ox + 1)) | (e2 << (ox + 2))
            out[oy + 1] |= (e3 << ox) | (e4 << (ox + 1)) | (e5 << (ox + 2))
            out[oy + 2] |= (e6 << ox) | (e7 << (ox + 1)) | (e8 << (ox + 2))
    return out


def _build(src_rows):
    return {
        "small": list(src_rows),
        "mid": scale2x(src_rows, SRC_W, SRC_H),
        "big": scale3x(src_rows, SRC_W, SRC_H),
    }


def _build_all():
    glyphs = {"small": {}, "mid": {}, "big": {}}
    for ch in sorted(SMALL_SRC, key=ord):
        for size, rows in _build(src_to_rows(SMALL_SRC[ch])).items():
            glyphs[size][ord(ch)] = rows
    return glyphs


GLYPHS = _build_all()
FALLBACK = _build(src_to_rows(_FALLBACK_SRC))


def glyph(ch, size="small"):
    """Rows (top to bottom, bit 0 = leftmost) for one character at a size.
    `ch` may be a 1-char string or a codepoint. Unknown -> hollow box."""
    cp = ch if isinstance(ch, int) else ord(ch)
    rows = GLYPHS[size].get(cp)
    return list(rows) if rows is not None else list(FALLBACK[size])


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

REQUIRED = [chr(c) for c in range(32, 127)] + list("°µΔ±·×÷–—→←…✓²³Ω≤≥≈‘’“”")


def _padded(rows, w, h):
    """0/1 grid of a bitmap with one unlit cell of padding on every side."""
    g = [[0] * (w + 2)]
    for y in range(h):
        g.append([0] + [(rows[y] >> x) & 1 for x in range(w)] + [0])
    g.append([0] * (w + 2))
    return g


def _count_regions(g, val, diag):
    """Number of connected regions of cells equal to val (8- or 4-connected)."""
    h, w = len(g), len(g[0])
    steps = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    if diag:
        steps += [(1, 1), (1, -1), (-1, 1), (-1, -1)]
    seen = [[False] * w for _ in range(h)]
    n = 0
    for y0 in range(h):
        for x0 in range(w):
            if g[y0][x0] != val or seen[y0][x0]:
                continue
            n += 1
            seen[y0][x0] = True
            stack = [(x0, y0)]
            while stack:
                x, y = stack.pop()
                for dx, dy in steps:
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h and g[ny][nx] == val and not seen[ny][nx]:
                        seen[ny][nx] = True
                        stack.append((nx, ny))
    return n


def structure(rows, w, h):
    """(strokes, counters): 8-connected lit regions and enclosed unlit regions."""
    g = _padded(rows, w, h)
    return _count_regions(g, 1, True), _count_regions(g, 0, False) - 1


def notches(rows, w, h):
    """Unlit cells inside the box that are not part of any unlit 2x2 square,
    i.e. 1-cell slits or pinholes. Normal at small size, a defect after scaling."""
    g = _padded(rows, w, h)
    n = 0
    for y in range(1, h + 1):
        for x in range(1, w + 1):
            if g[y][x]:
                continue
            if not any(all(g[y + oy + dy][x + ox + dx] == 0 for dx in (0, 1) for dy in (0, 1))
                       for ox in (-1, 0) for oy in (-1, 0)):
                n += 1
    return n


def check():
    """Return a list of problems with the source table and the scaled sets (empty = OK)."""
    probs = []
    for ch in REQUIRED:
        if ch not in SMALL_SRC:
            probs.append("missing %r" % ch)
    full = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    xh = set("acemnorsuvwxz")
    asc = set("bdfhkl")
    for ch, src in SMALL_SRC.items():
        if len(src) != SRC_H or any(len(ln) != SRC_W or set(ln) - set("#.") for ln in src):
            probs.append("%r is not %d rows of %d '#'/'.' cells" % (ch, SRC_H, SRC_W))
            continue
        rows = src_to_rows(src)
        if any(rows[7:]) and ch not in DESCENDERS:
            probs.append("%r uses descender rows" % ch)
        if ch in "gjpqyµ" and not (rows[7] and rows[8]):
            probs.append("%r lacks a two-row descender" % ch)
        if ch in full and not (rows[0] and rows[6]):
            probs.append("%r does not span rows 0-6" % ch)
        if ch in xh and (rows[0] or rows[1] or not rows[2] or not rows[6]):
            probs.append("%r is not x-height (rows 2-6)" % ch)
        if ch in asc and not rows[0]:
            probs.append("%r lacks an ascender" % ch)
    for size, table in GLYPHS.items():
        w, h = SIZES[size]["w"], SIZES[size]["h"]
        for cp, rows in table.items():
            if len(rows) != h or any(r >> w for r in rows):
                probs.append("%s U+%04X wrong box" % (size, cp))
    # Scaled sets must keep the small glyph's topology and gain no slits.
    for cp, rows in GLYPHS["small"].items():
        want = structure(rows, SRC_W, SRC_H)
        for size in ("mid", "big"):
            w, h = SIZES[size]["w"], SIZES[size]["h"]
            got = structure(GLYPHS[size][cp], w, h)
            if got != want:
                probs.append("%s U+%04X %r: strokes/counters %s -> %s" % (size, cp, chr(cp), want, got))
            n = notches(GLYPHS[size][cp], w, h)
            if n:
                probs.append("%s U+%04X %r: %d one-cell notch(es) after scaling" % (size, cp, chr(cp), n))
    return probs


# ---------------------------------------------------------------------------
# Font sheet (own PIL code: 5 px pitch, 4x4 lit squares, 1 px black gap)
# ---------------------------------------------------------------------------

SHEET_COLORS = [
    (0x09, 0x09, 0x09),  # 0 unlit
    (0xFF, 0xB0, 0x14),  # 1 amber
    (0xFF, 0xE8, 0xC4),  # 2 warm white
    (0x96, 0x64, 0x28),  # 3 dim amber
]


class _Cells:
    def __init__(self, cols, rows):
        self.cols, self.rows = cols, rows
        self.buf = bytearray(cols * rows)

    def set(self, c, r, color):
        if 0 <= c < self.cols and 0 <= r < self.rows:
            self.buf[r * self.cols + c] = color

    def draw_glyph(self, c, r, rows, w, color):
        for y, bits in enumerate(rows):
            for x in range(w):
                if (bits >> x) & 1:
                    self.set(c + x, r + y, color)

    def text(self, c, r, s, size="small", color=2):
        m = SIZES[size]
        for ch in s:
            self.draw_glyph(c, r, glyph(ch, size), m["w"], color)
            c += m["advance"]
        return c

    def to_image(self, pitch=5):
        from PIL import Image
        small = Image.frombytes("P", (self.cols, self.rows), bytes(self.buf))
        pal = []
        for rgb in SHEET_COLORS:
            pal.extend(rgb)
        pal.extend([0, 0, 0])  # 4 = gap black
        pal.extend([0, 0, 0] * (256 - len(pal) // 3))
        small.putpalette(pal)
        big = small.resize((self.cols * pitch, self.rows * pitch), Image.NEAREST)
        px = big.load()
        W, H = big.size
        gap = len(SHEET_COLORS)
        for x in range(pitch - 1, W, pitch):
            for y in range(H):
                px[x, y] = gap
        for y in range(pitch - 1, H, pitch):
            for x in range(W):
                px[x, y] = gap
        return big.convert("RGB")


SAMPLES = {
    "small": [
        "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG 0123456789",
        "the quick brown fox jumps over the lazy dog. Sphinx of black quartz!",
        "SUCTION PSI 12.5 ±0.3 → 25°C 4.7µA 10kΩ ΔT≤3 x² ≈ OK✓",
        "0O D Q 8B 1lI| 5S 2Z 6Gb 9gq A4 0x3FA9 0xBEEF C0FFEE 7E:41:0A",
        "MM/RF BLE:SCAN | RX:1284 | TX-AUTO:3 | SCAN:ON | LOG:REC",
        "‘single’ “double” (a+b)*c=d/e [x] {y} <z> #$%&@^_`~ a;b, … – — × ÷ ·",
    ],
    "mid": [
        "RX 1284  TX 3  12:45",
        "B7F3A1C9  -72 dBm",
        "0O D 8B 1lI 5S gjpqy",
    ],
    "big": [
        "1284 ±12.5°",
        "RX:0x3F dBm",
    ],
}

# Strings a MagicMaker screen shows, for the legibility strip:
# (size, text, palette index, inverted)
STRIP = [
    ("small", "8301CC0300010 0E9 0C 0F0F5D", 2, False),
    ("small", "RX:1284 | TX-AUTO:3", 2, False),
    ("small", "Rainbow FX · 5-LED", 2, False),
    ("small", "BURST MS 2000", 2, False),
    ("small", "WAND LOOP ON", 2, False),
    ("small", "-72 dBm", 2, False),
    ("small", "B7F3A1C9", 1, False),
    ("small", "MM/RF BLE:SCAN | RX:1284 | TX-AUTO:3 | SCAN:ON", 3, False),
    ("small", "0O D Q 8B 1lI| 5S 2Z 6Gb 9gq A4", 1, False),
    ("small", "WAND LOOP ON", 1, True),
    ("small", "RX:1284 | TX-AUTO:3", 1, True),
    ("mid", "BURST MS 2000", 2, False),
    ("mid", "-72 dBm B7F3A1C9", 1, False),
    ("mid", "0O D 8B 1lI 5S 6G", 2, False),
    ("big", "1284", 1, False),
    ("big", "-72 dBm", 2, False),
]


def render_strip(path):
    """The STRIP strings on a VFD-look strip (5 px pitch), one per line, with a
    dim size label in the margin. Inverted lines are a solid block with the
    glyph cells left unlit, padded one cell above and one below the baseline."""
    margin, label_w = 4, 4 * SIZES["small"]["advance"]
    x0 = margin + label_w
    cols = x0 + max(len(t) * SIZES[z]["advance"] for z, t, _, _ in STRIP) + margin
    rows = margin + sum(SIZES[z]["line"] + 3 for z, _, _, _ in STRIP) + margin
    cells = _Cells(cols, rows)
    r = margin
    for size, text, color, inverted in STRIP:
        m = SIZES[size]
        cells.text(margin, r + m["ascent"] - SIZES["small"]["ascent"], size[0].upper(), "small", 3)
        if inverted:
            for y in range(r - 1, r + m["ascent"] + 1):
                for x in range(x0 - 1, x0 + len(text) * m["advance"]):
                    cells.set(x, y, color)
            c = x0
            for ch in text:
                for y, bits in enumerate(glyph(ch, size)):
                    for x in range(m["w"]):
                        if (bits >> x) & 1:
                            cells.set(c + x, r + y, 0)
                c += m["advance"]
        else:
            cells.text(x0, r, text, size, color)
        r += m["line"] + 3
    img = cells.to_image(5)
    img.save(path)
    return img.size


def render_sheet(path):
    pitch = 5
    margin = 4
    label_w = 8 * SIZES["small"]["advance"]  # "U+0000  "
    per_row = {"small": 32, "mid": 16, "big": 12}
    slot_gap = {"small": 2, "mid": 3, "big": 4}
    cps = sorted(GLYPHS["small"])

    def slot(size):
        return SIZES[size]["advance"] + slot_gap[size]

    content_w = max(per_row[s] * slot(s) for s in SIZES)
    sample_w = max(len(t) * SIZES[s]["advance"] for s in SAMPLES for t in SAMPLES[s])
    cols = margin * 2 + label_w + max(content_w, sample_w)

    # layout pass to measure height
    def layout(cells):
        r = margin
        if cells:
            cells.text(margin, r, "VFD FONT · SMALL 5x9 · MID 10x18 SCALE2X · BIG 15x27 SCALE3X · %d GLYPHS" % len(cps), "small", 2)
        r += SIZES["small"]["line"] + 3
        for size in ("small", "mid", "big"):
            m = SIZES[size]
            if cells:
                cells.text(margin, r, "%s  %dx%d  ASCENT %d  ADVANCE %d  LINE %d" % (
                    size.upper(), m["w"], m["h"], m["ascent"], m["advance"], m["line"]), "small", 1)
            r += SIZES["small"]["line"] + 2
            n = per_row[size]
            for i in range(0, len(cps), n):
                chunk = cps[i:i + n]
                if cells:
                    cells.text(margin, r, "U+%04X" % chunk[0], "small", 3)
                    c = margin + label_w
                    for cp in chunk:
                        # dim baseline tick under each slot
                        cells.set(c - 1, r + m["ascent"] - 1, 3)
                        cells.draw_glyph(c, r, GLYPHS[size][cp], m["w"], 2)
                        c += slot(size)
                r += m["h"] + max(2, slot_gap[size])
            r += 2
            for t in SAMPLES[size]:
                if cells:
                    cells.text(margin + label_w, r, t, size, 1)
                r += m["line"]
            r += 6
        return r + margin

    rows = layout(None)
    cells = _Cells(cols, rows)
    layout(cells)
    img = cells.to_image(pitch)
    img.save(path)
    return img.size


def _ensure_pil():
    """The default `python3` may lack a working Pillow (e.g. 3.11 next to a
    3.12 Pillow build). Re-run this script with an interpreter that has it."""
    try:
        from PIL import Image  # noqa: F401
        return
    except ImportError:
        pass
    import os
    import shutil
    if os.environ.get("VFD_FONT_REEXEC"):
        raise SystemExit("vfd_font.py: Pillow is not importable")
    for name in ("python3.12", "python3.13", "python3"):
        exe = shutil.which(name)
        if exe and os.path.realpath(exe) != os.path.realpath(sys.executable):
            os.environ["VFD_FONT_REEXEC"] = "1"
            os.execv(exe, [exe, os.path.abspath(__file__)] + sys.argv[1:])
    raise SystemExit("vfd_font.py: Pillow is not importable")


def main(argv):
    if "--check" in argv:
        probs = check()
        for p in probs:
            print(p)
        print("OK" if not probs else "%d problem(s)" % len(probs))
        return 1 if probs else 0
    for flag, render in (("--sheet", render_sheet), ("--strip", render_strip)):
        if flag in argv:
            i = argv.index(flag)
            if i + 1 >= len(argv):
                print("usage: vfd_font.py %s OUT.png" % flag, file=sys.stderr)
                return 2
            out = argv[i + 1]
            _ensure_pil()
            for p in check():
                print("warning:", p, file=sys.stderr)
            size = render(out)
            print("wrote %s (%dx%d)" % (out, size[0], size[1]))
            return 0
    print(__doc__)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
