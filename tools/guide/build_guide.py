#!/usr/bin/env python3
"""Builds docs/ESP32_User_Guide.pdf: the owner's guide to the MagicMaker ESP32 transmitter.

Pure reportlab, local fonts only (Liberation Sans for text, DejaVu Sans Mono for code), no remote
assets. The OLED screen pictures are drawn pixel for pixel with the firmware's own 5x7 font
(firmware/esp32-transmitter/vfd_font_5x7.h) and the page layout of oled_pages.h.

Every statement in the guide comes from the firmware, the iPhone/Android apps, the flashers or
the release workflow in this repository (firmware 1.5). The battery figures (the voltage curve,
the per-state draw seeds, the cutoff levels) are read from firmware/esp32-transmitter/
battery_model.h, so the examples and the runtime table follow the firmware's own model.

    python3 tools/guide/build_guide.py            # writes docs/ESP32_User_Guide.pdf
    python3 tools/guide/build_guide.py out.pdf    # somewhere else
"""

import re
import sys
from pathlib import Path
from xml.sax.saxutils import escape

from reportlab.graphics.shapes import Circle, Drawing, Line, PolyLine, Rect, String
from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_RIGHT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib.fonts import addMapping
from reportlab.platypus import (BaseDocTemplate, Flowable, Frame, KeepTogether,
                                NextPageTemplate, PageBreak, PageTemplate, Spacer,
                                Table, TableStyle)
from reportlab.platypus import Paragraph as _Paragraph

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "docs" / "ESP32_User_Guide.pdf"
FONT_HEADER = ROOT / "firmware" / "esp32-transmitter" / "vfd_font_5x7.h"
BATTERY_HEADER = ROOT / "firmware" / "esp32-transmitter" / "battery_model.h"

FW_VERSION = "1.5"
RELAY_PROTO = 3
DOC_TITLE = "MagicMaker ESP32 Transmitter — User Guide"
ZIP_URL = ("https://github.com/Coral-coder/Magicmaker-mobile/releases/download/esp32-firmware/"
           "MagicMaker-Flasher-Windows.zip")
WEB_FLASHER = "https://coral-coder.github.io/Magicmaker-mobile/flasher/"
RELEASE_URL = "https://github.com/Coral-coder/Magicmaker-mobile/releases/tag/esp32-firmware"

# --------------------------------------------------------------------------------------------
# Fonts
# --------------------------------------------------------------------------------------------
LIB = Path("/usr/share/fonts/truetype/liberation")
DJV = Path("/usr/share/fonts/truetype/dejavu")
pdfmetrics.registerFont(TTFont("Sans", str(LIB / "LiberationSans-Regular.ttf")))
pdfmetrics.registerFont(TTFont("Sans-Bold", str(LIB / "LiberationSans-Bold.ttf")))
pdfmetrics.registerFont(TTFont("Sans-Italic", str(LIB / "LiberationSans-Italic.ttf")))
pdfmetrics.registerFont(TTFont("Sans-BoldItalic", str(LIB / "LiberationSans-BoldItalic.ttf")))
pdfmetrics.registerFont(TTFont("Mono", str(DJV / "DejaVuSansMono.ttf")))
pdfmetrics.registerFont(TTFont("Mono-Bold", str(DJV / "DejaVuSansMono-Bold.ttf")))
pdfmetrics.registerFont(TTFont("Mono-Italic", str(DJV / "DejaVuSansMono-Oblique.ttf")))
pdfmetrics.registerFont(TTFont("Mono-BoldItalic", str(DJV / "DejaVuSansMono-BoldOblique.ttf")))
for fam in ("Sans", "Mono"):
    addMapping(fam, 0, 0, fam)
    addMapping(fam, 1, 0, fam + "-Bold")
    addMapping(fam, 0, 1, fam + "-Italic")
    addMapping(fam, 1, 1, fam + "-BoldItalic")
# Liberation Sans draws "→" small and low on the line, so arrows in running text (SETTINGS →
# BOARD FIRMWARE) come from DejaVu Sans. Monospace text keeps its own arrow.
pdfmetrics.registerFont(TTFont("Arrow", str(DJV / "DejaVuSans.ttf")))
pdfmetrics.registerFont(TTFont("Arrow-Bold", str(DJV / "DejaVuSans-Bold.ttf")))
addMapping("Arrow", 0, 1, "Arrow")
addMapping("Arrow", 1, 1, "Arrow-Bold")
addMapping("Arrow", 0, 0, "Arrow")
addMapping("Arrow", 1, 0, "Arrow-Bold")
_TAG = re.compile(r"(<[^>]*>)")


def _arrows(text, bold=False):
    """Swap each → outside monospace text for the DejaVu one, bold inside <b> or a bold style."""
    out, depth, fonts = [], int(bold), []
    for part in _TAG.split(text):
        tag = part.lower()
        if tag.startswith("<font"):
            fonts.append('name="mono' in tag)
        elif tag == "</font>":
            if fonts:
                fonts.pop()
        elif tag == "<b>":
            depth += 1
        elif tag == "</b>":
            depth -= 1
        elif not tag.startswith("<") and not any(fonts):
            face = "Arrow-Bold" if depth > 0 else "Arrow"
            part = part.replace("→", f'<font name="{face}">→</font>')
        out.append(part)
    return "".join(out)


class Paragraph(_Paragraph):
    """reportlab's Paragraph, with full-size arrows in running text."""

    def __init__(self, text, style=None, *args, **kw):
        if isinstance(text, str):
            text = _arrows(text, bold=getattr(style, "fontName", "").endswith("-Bold"))
        super().__init__(text, style, *args, **kw)


# --------------------------------------------------------------------------------------------
# Colours and page geometry
# --------------------------------------------------------------------------------------------
INK = colors.HexColor("#1B2129")
MUTED = colors.HexColor("#5B6573")
ACCENT = colors.HexColor("#B86400")       # amber, like the app's VFD theme
ACCENT_SOFT = colors.HexColor("#FFF3E0")
TEAL = colors.HexColor("#146C77")
TEAL_SOFT = colors.HexColor("#E6F2F3")
WARN = colors.HexColor("#A3271B")
WARN_SOFT = colors.HexColor("#FBEDEB")
RULE = colors.HexColor("#D3D8DE")
HEAD_BG = colors.HexColor("#25313E")
ZEBRA = colors.HexColor("#F5F6F8")
GROUP_BG = colors.HexColor("#E9EDF2")
CODE_INK = "#7A3E00"

PAGE_W, PAGE_H = A4
MARGIN_X = 20 * mm
MARGIN_TOP = 24 * mm
MARGIN_BOTTOM = 20 * mm
FW = PAGE_W - 2 * MARGIN_X          # frame width
FH = PAGE_H - MARGIN_TOP - MARGIN_BOTTOM

# --------------------------------------------------------------------------------------------
# Paragraph styles
# --------------------------------------------------------------------------------------------
ST = {}
ST["body"] = ParagraphStyle("body", fontName="Sans", bulletFontName="Sans", fontSize=9.6, leading=13.7, textColor=INK,
                            spaceAfter=5.5, allowWidows=0, allowOrphans=0)
ST["lede"] = ParagraphStyle("lede", parent=ST["body"], fontSize=10.6, leading=15,
                            textColor=colors.HexColor("#36404C"), spaceAfter=9)
ST["small"] = ParagraphStyle("small", parent=ST["body"], fontSize=8.4, leading=11.4,
                             textColor=MUTED, spaceAfter=4)
ST["caption"] = ParagraphStyle("caption", parent=ST["body"], fontName="Sans-Italic",
                               fontSize=8.2, leading=11, textColor=MUTED, alignment=TA_CENTER,
                               spaceBefore=3, spaceAfter=10)
ST["bullet"] = ParagraphStyle("bullet", parent=ST["body"], leftIndent=13, bulletIndent=2,
                              spaceAfter=3.2)
ST["h1"] = ParagraphStyle("h1", fontName="Sans-Bold", fontSize=21, leading=25, textColor=INK,
                          spaceAfter=6, keepWithNext=1)
ST["h2"] = ParagraphStyle("h2", fontName="Sans-Bold", fontSize=12.8, leading=16.5,
                          textColor=TEAL, spaceBefore=13, spaceAfter=5, keepWithNext=1)
ST["h3"] = ParagraphStyle("h3", fontName="Sans-Bold", fontSize=10.2, leading=13.5,
                          textColor=INK, spaceBefore=8, spaceAfter=3, keepWithNext=1)
ST["cell"] = ParagraphStyle("cell", fontName="Sans", fontSize=8.5, leading=11.3, textColor=INK)
ST["cellb"] = ParagraphStyle("cellb", parent=ST["cell"], fontName="Sans-Bold")
ST["cellh"] = ParagraphStyle("cellh", parent=ST["cell"], fontName="Sans-Bold",
                             textColor=colors.white)
ST["cellg"] = ParagraphStyle("cellg", parent=ST["cell"], fontName="Sans-Bold", textColor=TEAL,
                             fontSize=8.8)
ST["callout_t"] = ParagraphStyle("callout_t", parent=ST["body"], fontName="Sans-Bold",
                                 fontSize=9.6, spaceAfter=3)
ST["callout"] = ParagraphStyle("callout", parent=ST["body"], spaceAfter=3)
ST["callout_b"] = ParagraphStyle("callout_b", parent=ST["bullet"], spaceAfter=2.2)
ST["stepnum"] = ParagraphStyle("stepnum", fontName="Sans-Bold", fontSize=13, leading=16,
                               textColor=colors.white, alignment=TA_CENTER)
ST["toc0"] = ParagraphStyle("toc0", fontName="Sans-Bold", fontSize=10.2, leading=13,
                            textColor=INK)
ST["toc1"] = ParagraphStyle("toc1", fontName="Sans", fontSize=8.9, leading=11.4,
                            textColor=colors.HexColor("#36404C"), leftIndent=17)
ST["tocn0"] = ParagraphStyle("tocn0", parent=ST["toc0"], alignment=TA_RIGHT)
ST["tocn1"] = ParagraphStyle("tocn1", parent=ST["toc1"], leftIndent=0, alignment=TA_RIGHT)
ST["quote"] = ParagraphStyle("quote", parent=ST["body"], spaceAfter=0, leading=13)


def m(s, size=None):
    """Literal text (on-screen text, messages, files, commands) in the monospace face. Short
    ones never break across lines."""
    sz = f' size="{size}"' if size else ""
    text = escape(s)
    if len(s) <= 22:
        text = text.replace(" ", "&nbsp;")
    return f'<font name="Mono"{sz} color="{CODE_INK}">{text}</font>'


def mc(s):
    """Monospace inside a table cell."""
    return m(s, 7.7)


def mb(s):
    """Monospace inside body text."""
    return m(s, 8.7)


def link(url, size=7.3, break_after=None):
    """A clickable URL in the monospace face, optionally broken onto two lines."""
    if break_after and break_after in url:
        head, tail = url.split(break_after, 1)
        shown = m(head + break_after, size) + "<br/>" + m(tail, size)
    else:
        shown = m(url, size)
    return f'<a href="{escape(url)}">{shown}</a>'


def b(s):
    return f"<b>{escape(s)}</b>"


def P(text, style="body"):
    return Paragraph(text, ST[style])


def bullets(items, style="bullet"):
    return [Paragraph(t, ST[style], bulletText="•") for t in items]


class Heading(Paragraph):
    """A heading that feeds the table of contents and the PDF outline."""

    def __init__(self, text, style, level, plain, key):
        super().__init__(text, ST[style])
        self.toc_level = level
        self.toc_text = plain
        self.toc_key = key


_KEYS = {"n": 0}


def _key():
    _KEYS["n"] += 1
    return f"sec{_KEYS['n']}"


def H1(num, title):
    plain = f"{num}  {title}"
    text = f'<font color="#B86400">{num}</font>&nbsp;&nbsp;{escape(title)}'
    return Heading(text, "h1", 0, plain, _key())


def H2(num, title):
    return Heading(f"{num}&nbsp;&nbsp;{escape(title)}", "h2", 1, f"{num}  {title}", _key())


def H3(title):
    return Paragraph(escape(title), ST["h3"])


def rule(color=ACCENT, width=FW, thickness=1.6, space=8):
    t = Table([[""]], colWidths=[width], rowHeights=[thickness])
    t.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, -1), color),
                           ("TOPPADDING", (0, 0), (-1, -1), 0),
                           ("BOTTOMPADDING", (0, 0), (-1, -1), 0)]))
    t.spaceAfter = space
    return t


def cellify(v, style="cell"):
    if isinstance(v, Flowable):
        return v
    if isinstance(v, (list, tuple)):
        return list(v)
    return Paragraph(str(v), ST[style])


def table(header, rows, widths, first_bold=False, zebra=True, groups=None, font_style="cell"):
    """A data table with wrapping Paragraph cells. widths are fractions of the frame width.
    groups: set of row indexes (into rows) that are full-width group labels; a row with a
    single cell is always one."""
    groups = set(groups or ()) | {i for i, r in enumerate(rows) if len(r) == 1}
    data = []
    if header:
        data.append([cellify(h, "cellh") for h in header])
    for i, r in enumerate(rows):
        if i in groups:
            data.append([cellify(r[0], "cellg")] + [""] * (len(widths) - 1))
            continue
        cells = []
        for j, v in enumerate(r):
            cells.append(cellify(v, "cellb" if (first_bold and j == 0) else font_style))
        data.append(cells)
    t = Table(data, colWidths=[w * FW for w in widths], repeatRows=1 if header else 0,
              hAlign="LEFT")
    style = [
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 5),
        ("RIGHTPADDING", (0, 0), (-1, -1), 5),
        ("TOPPADDING", (0, 0), (-1, -1), 3.6),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4.2),
        ("LINEBELOW", (0, 0), (-1, -1), 0.5, RULE),
    ]
    off = 0
    if header:
        style += [("BACKGROUND", (0, 0), (-1, 0), HEAD_BG),
                  ("LINEBELOW", (0, 0), (-1, 0), 1.2, ACCENT)]
        off = 1
    stripe = 0
    for i in range(len(rows)):
        ri = i + off
        if i in groups:
            style += [("SPAN", (0, ri), (-1, ri)), ("BACKGROUND", (0, ri), (-1, ri), GROUP_BG),
                      ("TOPPADDING", (0, ri), (-1, ri), 5)]
            stripe = 0
            continue
        if zebra and stripe % 2 == 1:
            style.append(("BACKGROUND", (0, ri), (-1, ri), ZEBRA))
        stripe += 1
    # A page break never strands one row: the first two and the last two rows stay together,
    # and a group label stays with the row under it.
    n = len(rows)
    if n >= 2:
        style += [("NOSPLIT", (0, off), (-1, off + 1)),
                  ("NOSPLIT", (0, off + n - 2), (-1, off + n - 1))]
    for i in groups:
        if i + 1 < n:
            style.append(("NOSPLIT", (0, off + i), (-1, off + i + 1)))
    t.setStyle(TableStyle(style))
    t.spaceBefore = 3
    t.spaceAfter = 9
    return t


def callout(kind, title, body):
    """A tinted box with a coloured bar on the left. body: list of strings / flowables."""
    bar, bg = {"tip": (TEAL, TEAL_SOFT), "note": (ACCENT, ACCENT_SOFT),
               "warn": (WARN, WARN_SOFT)}[kind]
    inner = []
    if title:
        inner.append(Paragraph(escape(title), ST["callout_t"]))
    for x in body:
        inner.append(Paragraph(x, ST["callout"]) if isinstance(x, str) else x)
    t = Table([[inner]], colWidths=[FW])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), bg),
        ("LINEBEFORE", (0, 0), (0, -1), 3.2, bar, "butt"),   # flush with the box, no round ends
        ("LEFTPADDING", (0, 0), (-1, -1), 11),
        ("RIGHTPADDING", (0, 0), (-1, -1), 10),
        ("TOPPADDING", (0, 0), (-1, -1), 7),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
    ]))
    t.spaceBefore = 4
    t.spaceAfter = 10
    return t


def steps(items, color=ACCENT, width=FW):
    """Numbered steps: a coloured number cell and the text."""
    data = []
    for i, it in enumerate(items, 1):
        cell = [Paragraph(x, ST["body"]) if isinstance(x, str) else x
                for x in (it if isinstance(it, (list, tuple)) else [it])]
        data.append([Paragraph(str(i), ST["stepnum"]), cell])
    t = Table(data, colWidths=[24, width - 24])
    st = [("VALIGN", (0, 0), (-1, -1), "TOP"),
          ("LEFTPADDING", (1, 0), (1, -1), 10),
          ("LEFTPADDING", (0, 0), (0, -1), 0), ("RIGHTPADDING", (0, 0), (0, -1), 0),
          ("TOPPADDING", (0, 0), (-1, -1), 3), ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
          ("BACKGROUND", (0, 0), (0, -1), color),
          ("LINEBELOW", (0, 0), (0, -1), 2.5, colors.white),
          ("LINEBELOW", (1, 0), (1, -2), 0.5, RULE)]
    t.setStyle(TableStyle(st))
    t.spaceBefore = 2
    t.spaceAfter = 10
    return t


def quote(text):
    """Text exactly as an app or the board shows it, in a light box."""
    t = Table([[Paragraph(m(text, 8.6), ST["quote"])]], colWidths=[FW])
    t.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, -1), ZEBRA),
                           ("BOX", (0, 0), (-1, -1), 0.5, RULE),
                           ("LEFTPADDING", (0, 0), (-1, -1), 9),
                           ("RIGHTPADDING", (0, 0), (-1, -1), 9),
                           ("TOPPADDING", (0, 0), (-1, -1), 5),
                           ("BOTTOMPADDING", (0, 0), (-1, -1), 6)]))
    t.spaceBefore = 2
    t.spaceAfter = 8
    return t


# Table-of-contents entries from the previous pass: (level, text, page, key).
PREV_TOC = []


def toc_table():
    """A two-column table of contents with links, built from the previous pass's headings."""
    entries = PREV_TOC
    if not entries:          # first pass: the headings are not known yet
        return Spacer(1, 12)
    # split before the section that brings the left column closest to half the rows
    best, split, count = None, len(entries), 0
    for i, e in enumerate(entries):
        if e[0] == 0 and i > 0:
            d = abs(count - len(entries) / 2)
            if best is None or d < best:
                best, split = d, i
        count += 1

    col_w = (FW - 22) / 2

    def column(items):
        if not items:
            return ""
        data, style = [], [("VALIGN", (0, 0), (-1, -1), "TOP"),
                           ("LEFTPADDING", (0, 0), (-1, -1), 0),
                           ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                           ("TOPPADDING", (0, 0), (-1, -1), 1.2),
                           ("BOTTOMPADDING", (0, 0), (-1, -1), 1.2)]
        for r, (lvl, text, page, key) in enumerate(items):
            num, _, title = text.partition("  ")
            if lvl == 0:
                label = (f'<a href="#{key}"><font color="#B86400">{escape(num)}</font>'
                         f'&nbsp;&nbsp;{escape(title)}</a>')
                data.append([Paragraph(label, ST["toc0"]),
                             Paragraph(f'<a href="#{key}">{page}</a>', ST["tocn0"])])
                style += [("TOPPADDING", (0, r), (-1, r), 8 if r else 0),
                          ("LINEBELOW", (0, r), (-1, r), 0.5, RULE),
                          ("BOTTOMPADDING", (0, r), (-1, r), 3)]
            else:
                label = (f'<a href="#{key}"><font color="#5B6573">{escape(num)}</font>'
                         f'&nbsp;&nbsp;{escape(title)}</a>')
                data.append([Paragraph(label, ST["toc1"]),
                             Paragraph(f'<a href="#{key}">{page}</a>', ST["tocn1"])])
        t = Table(data, colWidths=[col_w - 24, 24])
        t.setStyle(TableStyle(style))
        return t

    outer = Table([[column(entries[:split]), "", column(entries[split:])]],
                  colWidths=[col_w, 22, col_w])
    outer.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP"),
                               ("LEFTPADDING", (0, 0), (-1, -1), 0),
                               ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                               ("TOPPADDING", (0, 0), (-1, -1), 0),
                               ("BOTTOMPADDING", (0, 0), (-1, -1), 0)]))
    outer.spaceBefore = 4
    outer.spaceAfter = 14
    return outer


def side_by_side(left, right, left_w, gap=14):
    t = Table([[left, right]], colWidths=[left_w, FW - left_w])
    t.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP"),
                           ("LEFTPADDING", (0, 0), (-1, -1), 0),
                           ("RIGHTPADDING", (0, 0), (0, 0), gap),
                           ("RIGHTPADDING", (1, 0), (1, 0), 0),
                           ("TOPPADDING", (0, 0), (-1, -1), 0),
                           ("BOTTOMPADDING", (0, 0), (-1, -1), 0)]))
    t.spaceAfter = 8
    return t


def screen_row(items, scale=1.1, bezel=5):
    """OLED pictures side by side, each over its caption: items = [(screen, caption), ...]."""
    cells = []
    for s, cap in items:
        f = OledFlowable(s, scale, bezel)
        f.hAlign = "CENTER"
        cells.append([f, P(cap, "caption")])
    t = Table([cells], colWidths=[FW / len(items)] * len(items))
    t.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP"),
                           ("ALIGN", (0, 0), (-1, -1), "CENTER"),
                           ("LEFTPADDING", (0, 0), (-1, -1), 4),
                           ("RIGHTPADDING", (0, 0), (-1, -1), 4),
                           ("TOPPADDING", (0, 0), (-1, -1), 0),
                           ("BOTTOMPADDING", (0, 0), (-1, -1), 0)]))
    t.spaceBefore = 2
    t.spaceAfter = 2
    return t


# --------------------------------------------------------------------------------------------
# The OLED: a 128x64 frame buffer drawn with the firmware's own font and layout (oled_pages.h)
# --------------------------------------------------------------------------------------------
def load_font():
    text = FONT_HEADER.read_text()
    body = text.split("VFD5X7_GLYPHS", 1)[1]
    rows = re.findall(r"\{\s*((?:0x[0-9A-Fa-f]{2}\s*,\s*){8}0x[0-9A-Fa-f]{2})\s*\}", body)
    glyphs = [[int(v, 16) for v in r.split(",")] for r in rows]
    if len(glyphs) != 96:
        raise SystemExit(f"unexpected glyph count {len(glyphs)} in {FONT_HEADER}")
    return glyphs


GLYPHS = load_font()


# --------------------------------------------------------------------------------------------
# The battery model (battery_model.h): voltage curve, draw seeds, cutoff levels. The examples
# and the runtime table are computed from these, the way the firmware computes them.
# --------------------------------------------------------------------------------------------
def load_battery_model():
    text = BATTERY_HEADER.read_text()

    def const(name):
        hit = re.search(rf"\b{name}\s*=\s*(-?[0-9.]+)f?\s*;", text)
        if not hit:
            raise SystemExit(f"{name} not found in {BATTERY_HEADER}")
        return float(hit.group(1))

    names = ("DRAW_BASE_MA", "DRAW_ADV_MA", "DRAW_LINK_MA", "DRAW_BEACON_MA", "DRAW_SCREEN_MA",
             "CUT_DEFAULT_MV", "LOW_WARN_BASE_MV", "LOW_WARN_MARGIN_MV", "LOW_WARN_HYST_MV",
             "CUT_READINGS", "CUT_RESET_MARGIN_MV", "CUT_COLLAPSE_MV", "CUT_COLLAPSE_GAP_S",
             "CUT_UNSTABLE_MV", "CUT_STEP_RISE_MV", "CUT_STEP_HOLDOFF_S", "BOOT_MARGIN_MV")
    model = {n: const(n) for n in names}
    curve = re.search(r"kCurve\[11\]\s*=\s*\{([^}]*)\}", text)
    presets = re.search(r"CUT_PRESETS_MV\[\]\s*=\s*\{([^}]*)\}", text)
    if not curve or not presets:
        raise SystemExit(f"voltage curve or cutoff presets not found in {BATTERY_HEADER}")
    model["curve"] = [int(v) for v in curve.group(1).split(",")]
    model["presets"] = [int(v) for v in presets.group(1).split(",")]
    # The guide's prose states these rules in words: stop if the firmware's numbers moved.
    expect = {"CUT_DEFAULT_MV": 3300, "LOW_WARN_BASE_MV": 3300, "LOW_WARN_MARGIN_MV": 100,
              "LOW_WARN_HYST_MV": 50, "CUT_READINGS": 3, "CUT_RESET_MARGIN_MV": 50,
              "CUT_COLLAPSE_MV": 3100, "CUT_COLLAPSE_GAP_S": 5, "CUT_UNSTABLE_MV": 300,
              "CUT_STEP_RISE_MV": 50, "CUT_STEP_HOLDOFF_S": 600, "BOOT_MARGIN_MV": 100}
    for k, v in expect.items():
        if model[k] != v:
            raise SystemExit(f"battery_model.h {k} is {model[k]:g}, the guide says {v}: update it")
    if model["presets"] != [3200, 3300, 3400]:
        raise SystemExit(f"battery_model.h CUT_PRESETS_MV is {model['presets']}: update the guide")
    return model


BM = load_battery_model()


def pct_from_mv(mv):
    """batteryPercentFromMv(): 10 % steps, straight lines in between."""
    c = BM["curve"]
    if mv >= c[0]:
        return 100.0
    for i in range(1, len(c)):
        if mv >= c[i]:
            return 100.0 - 10.0 * i + 10.0 * (mv - c[i]) / (c[i - 1] - c[i])
    return 0.0


def pct_int(mv):
    return int(pct_from_mv(mv) + 0.5)


def volts(mv):
    """scrVolts(): "3.30V" (truncated, like the firmware)."""
    return f"{mv // 1000}.{(mv % 1000) // 10:02d}V"


def vt(mv):
    """A voltage in running text: "3.30 V"."""
    return f"{mv / 1000:.2f} V"


def volt_pct(mv):
    """scrVoltPct(): "3.87V 68%"."""
    return f"{volts(mv)} {pct_int(mv)}%"


def runtime_text(minutes):
    """scrRuntime(): "~9H 40M", "~40M", "~99H+"."""
    minutes = max(0, minutes)
    if minutes >= 99 * 60:
        return "~99H+"
    if minutes >= 60:
        return f"~{minutes // 60}H {minutes % 60}M"
    return f"~{minutes}M"


def runtime_min(mv, cap_mah, draw_ma, cut_mv):
    """BatteryModel::runtimeMin(): the charge above the cutoff over the draw."""
    floor = pct_from_mv(cut_mv) if cut_mv else 0.0
    usable = max(pct_from_mv(mv) - floor, 0.0)
    return int(cap_mah * usable / 100.0 / draw_ma * 60.0 + 0.5)


def ma(x):
    return f"{x:g}"


CUT_MV = int(BM["CUT_DEFAULT_MV"])                       # 3300, the default cutoff
WARN_MV = CUT_MV + int(BM["LOW_WARN_MARGIN_MV"])         # 3400, the LOW warning
DRAW_IDLE = BM["DRAW_BASE_MA"] + BM["DRAW_ADV_MA"]       # no phone, dark, nothing on air
DRAW_LINKED = BM["DRAW_BASE_MA"] + BM["DRAW_LINK_MA"]    # iPhone linked, idle
BEACON_MA = BM["DRAW_BEACON_MA"]
SCREEN_MA = BM["DRAW_SCREEN_MA"]
CAP = 400

# A healthy example (3.87 V, 68 %) and a low one (3.36 V, 15 %: below the 3.40 V warning), with
# the runtime an idle linked board shows for them on 400 mAh with the default cutoff.
EX_MV = 3872
EX_PCT = pct_int(EX_MV)
EX_LEFT = int(CAP * pct_from_mv(EX_MV) / 100 + 0.5)
EX_RUN = runtime_text(runtime_min(EX_MV, CAP, DRAW_LINKED, CUT_MV))
EX_BAT = f"{EX_PCT}% {EX_RUN}"                            # "68% ~6H 2M"
EX_RUN_500 = runtime_text(runtime_min(EX_MV, 500, DRAW_LINKED, CUT_MV))
LOW_MV = 3360
LOW_PCT = pct_int(LOW_MV)
LOW_LEFT = int(CAP * pct_from_mv(LOW_MV) / 100 + 0.5)
LOW_RUN = runtime_text(runtime_min(LOW_MV, CAP, DRAW_LINKED, CUT_MV))
LOW_BAT = f"{LOW_PCT}% LOW {LOW_RUN}"                     # "15% LOW ~31M"
CUT_FRAME_MV = 3280                                       # the reading as the cutoff fires


def cut_left_pct(mv):
    """The LOW BATTERY page's "OFF AT ~10% LEFT"."""
    return int(pct_from_mv(mv) + 0.5)


def hours(mah, draw):
    return f"{mah / draw:.1f}"


SCR_W, SCR_H = 128, 64
ADV = 6
VALUE_X = 4 * ADV
VALUE_COLS = 17
PAGE_COUNT = 5          # STATUS, LAST PACKET, DEVICE, LOW BATTERY, POWER (oled_pages.h)


class Screen:
    def __init__(self):
        self.px = set()

    def pixel(self, x, y, on=True):
        if 0 <= x < SCR_W and 0 <= y < SCR_H:
            (self.px.add if on else self.px.discard)((x, y))

    def box(self, x, y, w, h, on=True):
        for i in range(w):
            for j in range(h):
                self.pixel(x + i, y + j, on)

    def frame(self, x, y, w, h):
        for i in range(w):
            self.pixel(x + i, y)
            self.pixel(x + i, y + h - 1)
        for j in range(h):
            self.pixel(x, y + j)
            self.pixel(x + w - 1, y + j)

    def char(self, x, y, c, on=True):
        if "a" <= c <= "z":
            c = c.upper()
        o = ord(c)
        idx = o - 32 if 32 <= o <= 126 else 95
        for r, bits in enumerate(GLYPHS[idx]):
            for col in range(5):
                if bits & (1 << col):
                    self.pixel(x + col, y + r, on)

    def text(self, x, y, s, on=True):
        for c in s:
            if x + 5 > SCR_W:
                break
            self.char(x, y, c, on)
            x += ADV

    @staticmethod
    def line_y(line):
        return 12 + line * 9

    def label(self, line, s):
        self.text(0, self.line_y(line), s)

    def value(self, line, s):
        self.text(VALUE_X, self.line_y(line), s)

    def value_inverse(self, line, s):
        cols = min(len(s), VALUE_COLS)
        self.box(VALUE_X - 1, self.line_y(line) - 1, cols * ADV + 1, 7 + 2)
        self.text(VALUE_X, self.line_y(line), s, on=False)

    def label_inverse(self, line, s):
        """scrLabelInverse(): a whole line dark on a lit box, from column 0."""
        cols = min(len(s), (SCR_W - 5) // ADV + 1)
        self.box(0, self.line_y(line) - 1, min(cols * ADV + 1, SCR_W), 7 + 2)
        self.text(0, self.line_y(line), s, on=False)

    def header_plain(self, title):
        """scrHeaderPlain(): title and dotted rule, no page dots (the off frames)."""
        self.text(0, 0, title)
        for x in range(0, SCR_W, 2):
            self.pixel(x, 9)

    def header(self, title, page):
        self.header_plain(title)
        for i in range(PAGE_COUNT):
            x = SCR_W - 5 - (PAGE_COUNT - 1 - i) * 8
            if i == page:
                self.box(x, 1, 5, 5)
            else:
                self.frame(x, 1, 5, 5)

    def bar(self, x, y, w, permille):
        self.frame(x, y, w, 7)
        segs = (w - 3) // 3
        lit = min(permille, 1000) * segs // 1000
        for k in range(lit):
            self.box(x + 2 + 3 * k, y + 2, 2, 3)


def screen_status(tx="SEND", permille=560, program="TX LOOP 3S", sent="42 SENT",
                  last="LAST BAND 2S AGO", bat=EX_BAT, low=False):
    # The loop burst on air IS the last packet: 0.52 s wake + 56% of the 4 s command = 2.76 s
    # since it started, so the age reads 2S (relay_engine.h noteStart, oled_pages.h scrAge).
    # low: the warning stage, BAT drawn inverse (scrPageStatus).
    s = Screen()
    s.header("STATUS", 0)
    s.label(0, "BLE")
    s.value(0, "LINKED")
    s.label(1, "TX")
    s.value(1, tx)
    if tx != "IDLE":
        s.bar(VALUE_X + 5 * ADV, s.line_y(1), 72, permille)
    s.value(2, program)
    s.label(3, "PKT")
    s.value(3, sent)
    s.value(4, last)
    s.label(5, "BAT")
    (s.value_inverse if low else s.value)(5, bat)
    return s


def screen_packet():
    s = Screen()
    s.header("LAST PACKET", 1)
    s.label(0, "PING 7B 2000MS")
    for i, byte in enumerate(["83", "01", "CC", "03", "00", "01", "00"]):
        s.text((i % 7) * 3 * ADV, s.line_y(1 + i // 7), byte)
    return s


def screen_device(cap=f"{EX_LEFT} OF {CAP}MAH", highlight=False, run=f"{EX_RUN} LEFT"):
    s = Screen()
    s.header("DEVICE", 2)
    rows = [("BAT", volt_pct(EX_MV)), ("CAP", cap), ("RUN", run), ("UP", "0D 02:14:09"),
            ("BLE", "MM_ESP DD:EE:FF"), ("FW", f"{FW_VERSION} HELTEC V3")]
    for i, (lab, val) in enumerate(rows):
        s.label(i, lab)
        if lab == "CAP" and highlight:
            s.value_inverse(i, val)
        else:
            s.value(i, val)
    return s


def screen_cutoff(cut_mv=CUT_MV, mv=EX_MV, state="OK", highlight=False):
    """LOW BATTERY page (scrPageCutoff)."""
    s = Screen()
    s.header("LOW BATTERY", 3)
    s.label(0, "CUT")
    (s.value_inverse if highlight else s.value)(0, volts(cut_mv) if cut_mv else "OFF")
    s.label(1, "BAT")
    s.value(1, volt_pct(mv))
    s.value(2, state)
    s.label(3, "LOW")
    s.value(3, "BELOW " + volts((cut_mv or int(BM["LOW_WARN_BASE_MV"]))
                                + int(BM["LOW_WARN_MARGIN_MV"])))
    s.value(4, f"OFF AT ~{cut_left_pct(cut_mv)}% LEFT" if cut_mv else "NO AUTO POWER-OFF")
    s.label(5, "HOLD PRG: NEXT LEVEL")
    return s


def screen_power(permille=0, ota=False):
    """POWER page (scrPagePower): the bar is the 2 s hold."""
    s = Screen()
    s.header("POWER", 4)
    if ota:
        s.label(0, "UPDATE RUNNING")
        s.label(1, "POWER OFF WHEN DONE")
    else:
        s.label(0, "HOLD PRG TO POWER OFF")
        s.label(1, "RST TURNS ON")
        s.bar(0, s.line_y(2), SCR_W, permille)
    s.label(4, "CHARGES WHILE OFF")
    s.label(5, "UNPLUG FOR STORAGE")
    return s


def screen_off(stage, mv=LOW_MV):
    """The off frames (scrPageOff): release / going (POWER page, app), low (the cutoff),
    boot_low (refused after RST)."""
    s = Screen()
    if stage in ("release", "going"):
        s.header_plain("POWER")
        s.label(0, "POWERING OFF...")
        if stage == "release":
            s.label_inverse(2, "RELEASE PRG")
        else:
            s.label(3, "PRESS RST TO TURN ON")
        s.label(4, "CHARGES WHILE OFF")
        return s
    s.header_plain("LOW BATTERY")
    s.label(0, "TOO LOW TO START" if stage == "boot_low" else "POWERING OFF...")
    s.label(1, "BAT")
    s.value(1, volt_pct(mv))
    s.label(2, "CHARGE IT, THEN")
    s.label(3, "PRESS RST TO TURN ON")
    if stage == "boot_low":
        s.label(4, "PRG: START ANYWAY")
    return s


def pixel_runs(s):
    """Lit pixels merged into horizontal runs: (x, y, length)."""
    runs = []
    for py in range(SCR_H):
        px = 0
        while px < SCR_W:
            if (px, py) in s.px:
                start = px
                while px < SCR_W and (px, py) in s.px:
                    px += 1
                runs.append((start, py, px - start))
            else:
                px += 1
    return runs


OLED_BG = colors.HexColor("#06080C")
OLED_ON = colors.HexColor("#DDEBFF")
BEZEL = colors.HexColor("#2A3038")


def draw_screen(c, s, x, y, scale, bezel=5):
    """Draw a Screen with its bottom-left corner at (x, y) (bezel included)."""
    w = SCR_W * scale + 2 * bezel
    h = SCR_H * scale + 2 * bezel
    c.saveState()
    c.setFillColor(BEZEL)
    c.roundRect(x, y, w, h, 4, stroke=0, fill=1)
    c.setFillColor(OLED_BG)
    c.rect(x + bezel - 1.2, y + bezel - 1.2, SCR_W * scale + 2.4, SCR_H * scale + 2.4,
           stroke=0, fill=1)
    c.setFillColor(OLED_ON)
    for (px, py, n) in pixel_runs(s):
        c.rect(x + bezel + px * scale, y + bezel + (SCR_H - 1 - py) * scale, n * scale + 0.03,
               scale + 0.03, stroke=0, fill=1)
    c.restoreState()
    return w, h


class OledFlowable(Flowable):
    def __init__(self, screen, scale=1.5, bezel=6):
        super().__init__()
        self.s, self.scale, self.bezel = screen, scale, bezel
        self.width = SCR_W * scale + 2 * bezel
        self.height = SCR_H * scale + 2 * bezel

    def wrap(self, aw, ah):
        return self.width, self.height

    def draw(self):
        draw_screen(self.canv, self.s, 0, 0, self.scale, self.bezel)


# --------------------------------------------------------------------------------------------
# Board diagrams (schematic, not to scale)
# --------------------------------------------------------------------------------------------
PCB = colors.HexColor("#1D3550")
PCB_EDGE = colors.HexColor("#0F2033")
GOLD = colors.HexColor("#C9A646")
METAL = colors.HexColor("#C4C9D0")
LEAD = ACCENT


def _label(d, x, y, lines, anchor="start", size=8, color=INK, bold_first=True):
    for i, ln in enumerate(lines):
        d.add(String(x, y - i * (size + 2), ln, fontName="Sans-Bold" if (i == 0 and bold_first)
                     else "Sans", fontSize=size, fillColor=color if i == 0 else MUTED,
                     textAnchor=anchor))


def _lead(d, pts):
    d.add(PolyLine(pts, strokeColor=LEAD, strokeWidth=0.9))
    d.add(Circle(pts[-1][0], pts[-1][1], 1.7, fillColor=LEAD, strokeColor=None))


def _button(d, x, y, size=14):
    d.add(Rect(x, y, size, size, rx=1.5, ry=1.5, fillColor=colors.HexColor("#D9DCE1"),
               strokeColor=colors.HexColor("#8A9099"), strokeWidth=0.6))
    d.add(Circle(x + size / 2, y + size / 2, size * 0.3, fillColor=colors.HexColor("#30343A"),
                 strokeColor=None))


def _pins(d, x0, x1, y, step=9):
    x = x0
    while x <= x1:
        d.add(Circle(x, y, 2.0, fillColor=GOLD, strokeColor=PCB_EDGE, strokeWidth=0.4))
        d.add(Circle(x, y, 0.8, fillColor=PCB_EDGE, strokeColor=None))
        x += step


def heltec_drawing():
    d = Drawing(FW, 222)
    bx, by, bw, bh = 150, 46, 205, 112
    d.add(Rect(bx, by, bw, bh, rx=8, ry=8, fillColor=PCB, strokeColor=PCB_EDGE, strokeWidth=1.2))
    for (hx, hy) in [(bx + 8, by + 8), (bx + bw - 8, by + 8), (bx + 8, by + bh - 8),
                     (bx + bw - 8, by + bh - 8)]:
        d.add(Circle(hx, hy, 3.6, fillColor=colors.white, strokeColor=GOLD, strokeWidth=1.2))
    _pins(d, bx + 27, bx + bw - 30, by + bh - 7)
    _pins(d, bx + 27, bx + bw - 30, by + 7)
    # USB port on the left edge
    d.add(Rect(bx - 12, by + 41, 20, 30, rx=4, ry=4, fillColor=METAL,
               strokeColor=colors.HexColor("#7D848D"), strokeWidth=0.8))
    d.add(Rect(bx - 7, by + 47, 8, 18, rx=3, ry=3, fillColor=colors.HexColor("#3A3F46"),
               strokeColor=None))
    # PRG (upper) and RST (lower) next to the USB port
    _button(d, bx + 16, by + 77)
    _button(d, bx + 16, by + 21)
    # status LED (centred between two header pins so its leader line misses them)
    d.add(Rect(bx + 37, by + 52, 7, 5, fillColor=colors.HexColor("#F4F1E6"),
               strokeColor=colors.HexColor("#9A9F8C"), strokeWidth=0.5))
    # OLED with the STATUS page on it
    ox, oy, scale = bx + 52, by + 20, 0.94
    d.add(Rect(ox - 4, oy - 4, SCR_W * scale + 8, SCR_H * scale + 8, rx=2, ry=2,
               fillColor=colors.HexColor("#14181E"), strokeColor=colors.HexColor("#4A525C"),
               strokeWidth=0.6))
    d.add(Rect(ox - 1, oy - 1, SCR_W * scale + 2, SCR_H * scale + 2, fillColor=OLED_BG,
               strokeColor=None))
    for (px, py, n) in pixel_runs(screen_status()):
        d.add(Rect(ox + px * scale, oy + (SCR_H - 1 - py) * scale, n * scale + 0.03,
                   scale + 0.03, fillColor=OLED_ON, strokeColor=None))
    # LoRa antenna socket (top right) and battery connector (bottom right)
    d.add(Circle(bx + bw - 10, by + bh - 24, 5, fillColor=GOLD, strokeColor=PCB_EDGE,
                 strokeWidth=0.5))
    d.add(Circle(bx + bw - 10, by + bh - 24, 1.8, fillColor=PCB_EDGE, strokeColor=None))
    d.add(Rect(bx + bw - 21, by + 18, 16, 13, fillColor=colors.HexColor("#EFE6CC"),
               strokeColor=colors.HexColor("#9C916F"), strokeWidth=0.6))
    d.add(Rect(bx + bw - 18, by + 22, 4, 5, fillColor=colors.HexColor("#6B6450"),
               strokeColor=None))
    d.add(Rect(bx + bw - 12, by + 22, 4, 5, fillColor=colors.HexColor("#6B6450"),
               strokeColor=None))

    # labels, left
    _label(d, 130, by + 87, ["PRG button", "screen, power-off, update"], anchor="end")
    _lead(d, [(133, by + 84), (bx + 16, by + 84)])
    _label(d, 130, by + 59, ["USB port", "power, charging, flashing"], anchor="end")
    _lead(d, [(133, by + 56), (bx - 12, by + 56)])
    _label(d, 130, by + 31, ["RST button", "restarts it, turns it on"], anchor="end")
    _lead(d, [(133, by + 28), (bx + 16, by + 28)])
    # labels, top
    # (leader x positions sit in the gaps of the pin header: pins are at bx + 27 + 9n)
    _label(d, bx + 40.5, 208, ["Status LED", "GPIO35"], anchor="middle")
    _lead(d, [(bx + 40.5, 191), (bx + 40.5, by + 57)])
    _label(d, bx + 121.5, 208, ['0.96" OLED screen', "dark until you press PRG"],
           anchor="middle")
    _lead(d, [(bx + 121.5, 191), (bx + 121.5, oy + SCR_H * scale + 4)])
    # labels, right
    _label(d, bx + bw + 18, by + bh - 20, ["LoRa antenna socket", "not used: radio asleep"])
    _lead(d, [(bx + bw + 15, by + bh - 24), (bx + bw - 5, by + bh - 24)])
    _label(d, bx + bw + 18, by + 28, ["Battery connector", "LiPo (yours: 400 mAh)"])
    _lead(d, [(bx + bw + 15, by + 24), (bx + bw - 5, by + 24)])
    d.add(String(FW / 2, 12, "Heltec WiFi LoRa 32 V3 / V3.1 / V3.2  (ESP32-S3)",
                 fontName="Sans-Bold", fontSize=9, fillColor=TEAL, textAnchor="middle"))
    return d


def devkit_drawing():
    d = Drawing(FW, 176)
    bx, by, bw, bh = 150, 46, 205, 82
    d.add(Rect(bx, by, bw, bh, rx=4, ry=4, fillColor=colors.HexColor("#22303C"),
               strokeColor=PCB_EDGE, strokeWidth=1.2))
    _pins(d, bx + 14, bx + bw - 10, by + bh - 6)
    _pins(d, bx + 14, bx + bw - 10, by + 6)
    d.add(Rect(bx - 10, by + 28, 18, 26, rx=3, ry=3, fillColor=METAL,
               strokeColor=colors.HexColor("#7D848D"), strokeWidth=0.8))
    d.add(Rect(bx - 6, by + 35, 7, 12, rx=2, ry=2, fillColor=colors.HexColor("#3A3F46"),
               strokeColor=None))
    _button(d, bx + 14, by + 54, 13)   # EN
    _button(d, bx + 14, by + 15, 13)   # BOOT
    d.add(Rect(bx + 33, by + 38, 7, 5, fillColor=colors.HexColor("#F4F1E6"),
               strokeColor=colors.HexColor("#9A9F8C"), strokeWidth=0.5))
    # ESP32 module: metal shield + PCB antenna
    mx, my, mw, mh = bx + 100, by + 16, 70, 50
    d.add(Rect(mx, my, mw, mh, rx=2, ry=2, fillColor=METAL,
               strokeColor=colors.HexColor("#8D939B"), strokeWidth=0.7))
    d.add(String(mx + mw / 2, my + mh / 2 - 3, "ESP32", fontName="Mono-Bold", fontSize=9,
                 fillColor=colors.HexColor("#4A5059"), textAnchor="middle"))
    d.add(Rect(mx + mw, my, 26, mh, fillColor=colors.HexColor("#2C4560"),
               strokeColor=colors.HexColor("#8D939B"), strokeWidth=0.7))
    zig = []
    for i in range(6):
        yy = my + 8 + i * 7
        zig += [mx + mw + 5, yy, mx + mw + 21, yy] if i % 2 == 0 else [mx + mw + 21, yy,
                                                                       mx + mw + 5, yy]
    d.add(PolyLine(zig, strokeColor=GOLD, strokeWidth=1.2))

    _label(d, 130, by + 78, ["EN / RST button", "restarts it, turns it on"], anchor="end")
    _lead(d, [(133, by + 75), (bx + 4, by + 75), (bx + 14, by + 63)])
    _label(d, 130, by + 44, ["USB port", "power, flashing"], anchor="end")
    _lead(d, [(133, by + 41), (bx - 10, by + 41)])
    _label(d, 130, by + 12, ["BOOT button (GPIO0)", "update, flashing"], anchor="end")
    _lead(d, [(133, by + 9), (bx + 4, by + 9), (bx + 14, by + 19)])
    # (the LED leader runs between two header pins: pins are at bx + 14 + 9n)
    _label(d, bx + 36.5, 164, ["Status LED", "LED_BUILTIN, else GPIO2"], anchor="middle")
    _lead(d, [(bx + 36.5, 147), (bx + 36.5, by + 43)])
    _label(d, bx + bw + 18, by + 45, ["ESP32 module", "no screen, no battery reading"])
    _lead(d, [(bx + bw + 15, by + 41), (mx + mw + 26, by + 41)])
    d.add(String(FW / 2, 12, "Classic ESP32 DevKit / WROOM / WROVER", fontName="Sans-Bold",
                 fontSize=9, fillColor=TEAL, textAnchor="middle"))
    return d


def timing_drawing():
    d = Drawing(FW, 160)     # the top row ends at y = 154: no dead band under the heading
    x0 = 128
    total = 4600.0
    span = FW - x0 - 52
    k = span / total
    wake_c = colors.HexColor("#E09A2B")
    cmd_c = colors.HexColor("#1F7F8A")
    stream_c = colors.HexColor("#F6DDB3")

    def seg(t0, t1, y, col, txt="", tcol=colors.white, h=20):
        d.add(Rect(x0 + t0 * k, y, (t1 - t0) * k, h, fillColor=col, strokeColor=colors.white,
                   strokeWidth=0.8))
        if txt:
            d.add(String(x0 + (t0 + t1) / 2 * k, y + 6.5, txt, fontName="Sans-Bold",
                         fontSize=7.4, fillColor=tcol, textAnchor="middle"))

    def row_label(y, a, bline):
        d.add(String(0, y + 11, a, fontName="Sans-Bold", fontSize=8.6, fillColor=INK))
        d.add(String(0, y + 1, bline, fontName="Sans", fontSize=7.6, fillColor=MUTED))

    y1, y2, y3 = 134, 90, 46
    row_label(y1, "TX MODE: SUSTAINED", "the default")
    seg(0, 520, y1, wake_c, "WAKE")
    seg(520, 4520, y1, cmd_c, "COMMAND  4000 ms")
    d.add(String(x0 + 4520 * k + 6, y1 + 6.5, "4.52 s", fontName="Sans-Bold", fontSize=8,
                 fillColor=INK))

    row_label(y2, "TX MODE: INTERLEAVE", "520 ms slices")
    for i in range(3):
        seg(i * 1040, i * 1040 + 520, y2, wake_c, "W")
        seg(i * 1040 + 520, i * 1040 + 1040, y2, cmd_c, "C")
    d.add(String(x0 + 3120 * k + 6, y2 + 6.5, "3.12 s  (3 pairs fit in 4 s)", fontName="Sans",
                 fontSize=8, fillColor=INK))

    row_label(y3, "KEEP BAND AWAKE on", "no wake phase")
    seg(0, 300, y3, stream_c, "")
    seg(300, 4300, y3, cmd_c, "COMMAND alone  4000 ms")
    seg(4300, 4600, y3, stream_c, "")
    d.add(String(x0 + 4600 * k + 6, y3 + 11, "ping", fontName="Sans", fontSize=7.4,
                 fillColor=MUTED))
    d.add(String(x0 + 4600 * k + 6, y3 + 2, "stream", fontName="Sans", fontSize=7.4,
                 fillColor=MUTED))

    # axis
    ya = 30
    d.add(Line(x0, ya, x0 + total * k, ya, strokeColor=MUTED, strokeWidth=0.6))
    for s in range(0, 5):
        xx = x0 + s * 1000 * k
        d.add(Line(xx, ya - 3, xx, ya + 3, strokeColor=MUTED, strokeWidth=0.6))
        d.add(String(xx, ya - 12, f"{s} s", fontName="Sans", fontSize=7.4, fillColor=MUTED,
                     textAnchor="middle"))
    # legend
    lx = 0
    for col, txt in [(wake_c, "wake ping"), (cmd_c, "your command"),
                     (stream_c, "keep-awake ping stream")]:
        d.add(Rect(lx, 4, 9, 7, fillColor=col, strokeColor=None))
        d.add(String(lx + 13, 4.5, txt, fontName="Sans", fontSize=7.6, fillColor=INK))
        lx += 13 + pdfmetrics.stringWidth(txt, "Sans", 7.6) + 18
    return d


# --------------------------------------------------------------------------------------------
# Document template: cover, running header/footer, TOC + outline
# --------------------------------------------------------------------------------------------
class GuideDoc(BaseDocTemplate):
    def __init__(self, filename, total_pages=None, **kw):
        super().__init__(filename, pagesize=A4, leftMargin=MARGIN_X, rightMargin=MARGIN_X,
                         topMargin=MARGIN_TOP, bottomMargin=MARGIN_BOTTOM,
                         title=DOC_TITLE, author="MagicMaker",
                         subject=f"Using the MagicMaker ESP32 transmitter, firmware {FW_VERSION}",
                         creator="tools/guide/build_guide.py", initialFontName="Sans",
                         initialFontSize=9.6, **kw)
        self.total_pages = total_pages
        self.section = ""
        self.toc_entries = []
        cover = Frame(0, 0, PAGE_W, PAGE_H, id="cover", leftPadding=0, rightPadding=0,
                      topPadding=0, bottomPadding=0)
        body = Frame(MARGIN_X, MARGIN_BOTTOM, FW, FH, id="body", leftPadding=0,
                     rightPadding=0, topPadding=0, bottomPadding=0)
        self.addPageTemplates([
            PageTemplate(id="cover", frames=[cover], onPage=draw_cover),
            PageTemplate(id="body", frames=[body], onPageEnd=draw_header_footer),
        ])

    def afterFlowable(self, f):
        if isinstance(f, Heading):
            key = f.toc_key
            self.canv.bookmarkPage(key)
            self.canv.addOutlineEntry(f.toc_text, key, level=f.toc_level, closed=False)
            self.toc_entries.append((f.toc_level, f.toc_text, self.page, key))
            if f.toc_level == 0:
                self.section = f.toc_text.split("  ", 1)[-1]
        elif isinstance(f, SectionMark):
            self.section = f.name


class SectionMark(Flowable):
    """Zero-size marker that names the running-header section (for unnumbered pages)."""

    def __init__(self, name):
        super().__init__()
        self.name = name

    def wrap(self, aw, ah):
        return 0, 0

    def draw(self):
        pass


def draw_header_footer(c, doc):
    c.saveState()
    top = PAGE_H - 14 * mm
    c.setFont("Sans-Bold", 8)
    c.setFillColor(INK)
    c.drawString(MARGIN_X, top, "MagicMaker ESP32 Transmitter")
    c.setFont("Sans", 8)
    c.setFillColor(MUTED)
    c.drawString(MARGIN_X + pdfmetrics.stringWidth("MagicMaker ESP32 Transmitter ", "Sans-Bold", 8),
                 top, "· User Guide")
    c.drawRightString(PAGE_W - MARGIN_X, top, doc.section)
    c.setStrokeColor(RULE)
    c.setLineWidth(0.6)
    c.line(MARGIN_X, top - 4, PAGE_W - MARGIN_X, top - 4)
    c.setFillColor(ACCENT)
    c.rect(MARGIN_X, top - 4.6, 28, 1.6, stroke=0, fill=1)
    # footer
    fy = 11 * mm
    c.line(MARGIN_X, fy + 9, PAGE_W - MARGIN_X, fy + 9)
    c.setFont("Sans", 7.8)
    c.setFillColor(MUTED)
    c.drawString(MARGIN_X, fy, f"Firmware {FW_VERSION} · Heltec WiFi LoRa 32 V3 and classic ESP32")
    total = doc.total_pages
    label = f"Page {doc.page} of {total}" if total else f"Page {doc.page}"
    c.setFont("Sans-Bold", 7.8)
    c.setFillColor(INK)
    c.drawRightString(PAGE_W - MARGIN_X, fy, label)
    c.restoreState()


def draw_cover(c, doc):
    c.saveState()
    c.showOutline()
    dark = colors.HexColor("#121821")
    c.setFillColor(dark)
    c.rect(0, PAGE_H * 0.40, PAGE_W, PAGE_H * 0.60, stroke=0, fill=1)
    c.setFillColor(ACCENT)
    c.rect(0, PAGE_H * 0.40 - 5, PAGE_W, 5, stroke=0, fill=1)
    x = 22 * mm
    y = PAGE_H - 34 * mm
    c.setFillColor(colors.HexColor("#E8A23A"))
    c.setFont("Sans-Bold", 10)
    c.drawString(x, y, "MAGICMAKER  ·  OWNER'S GUIDE")
    c.setFillColor(colors.white)
    c.setFont("Sans-Bold", 34)
    c.drawString(x, y - 46, "ESP32 Transmitter")
    c.setFont("Sans", 22)
    c.setFillColor(colors.HexColor("#C9D3DF"))
    c.drawString(x, y - 76, "User Guide")
    c.setFont("Sans", 10.5)
    c.setFillColor(colors.HexColor("#AEB9C6"))
    c.drawString(x, y - 102, "Flashing, linking, the screen, the battery, turning it off,")
    c.drawString(x, y - 116, "chip-side programs, timing settings, updates and troubleshooting.")
    # the OLED, large
    scale = 2.55
    sw = SCR_W * scale + 20
    draw_screen(c, screen_status(), (PAGE_W - sw) / 2, PAGE_H * 0.40 + 22 * mm, scale, bezel=10)
    # facts block
    by = PAGE_H * 0.40 - 22 * mm
    rows = [("Firmware", f"{FW_VERSION}  (relay protocol {RELAY_PROTO})"),
            ("Boards", "Heltec WiFi LoRa 32 V3 / V3.1 / V3.2 (ESP32-S3, 0.96\" OLED)"),
            ("", "Classic ESP32 DevKit / WROOM / WROVER (no screen)"),
            ("Bluetooth name", "MM_ESP"),
            ("Phones", "iPhone app (transmits through the board, updates it)"),
            ("", "Android app (reads the board's battery heartbeat)")]
    for i, (k, v) in enumerate(rows):
        yy = by - i * 17
        c.setFont("Sans-Bold", 10)
        c.setFillColor(TEAL)
        c.drawString(x, yy, k)
        c.setFont("Sans", 10.5)
        c.setFillColor(INK)
        c.drawString(x + 38 * mm, yy, v)
    c.setStrokeColor(RULE)
    c.setLineWidth(0.6)
    c.line(x, 30 * mm, PAGE_W - x, 30 * mm)
    c.setFont("Sans", 8.5)
    c.setFillColor(MUTED)
    c.drawString(x, 24 * mm, "Everything in this guide is taken from the firmware and app source code "
                 f"(firmware {FW_VERSION}).")
    c.drawString(x, 24 * mm - 12, "Battery figures are estimates: the board measures voltage, "
                 "not current.")
    c.restoreState()


# --------------------------------------------------------------------------------------------
# Content
# --------------------------------------------------------------------------------------------
def build_story():
    S = []
    S.append(NextPageTemplate("body"))
    S.append(PageBreak())

    # ---------------- Contents ----------------
    S.append(SectionMark("Contents"))
    S.append(Paragraph("Contents", ST["h1"]))
    S.append(rule())
    S.append(toc_table())
    S.append(callout("tip", "How to read this guide", bullets([
        "<b>Bold</b> names are things you press, tap or switch: buttons on the board (PRG, "
        "RST, BOOT) and tabs, buttons and switches in the app (LINK, Retry BLE, KEEP BAND "
        "AWAKE).",
        f"{mb('Monospace')} is text exactly as the board, the app or a flasher shows it, or a "
        "file name.",
        "\u201cThe board\u201d means your ESP32, a Heltec V3 or a classic DevKit. Where they "
        "differ, the guide says so. The battery parts apply to the Heltec only.",
        "Battery figures are estimates: the board measures voltage, not current.",
    ], "callout_b")))

    def section(num, title, lede=None):
        S.append(PageBreak())
        S.append(H1(num, title))
        S.append(rule())
        if lede:
            S.append(P(lede, "lede"))

    # ======================================================================================
    section("1", "Quick start",
            "The ESP32 is a pocket transmitter for the MagicMaker iPhone app. The iPhone links "
            "to it over Bluetooth and tells it what to send. The board broadcasts the band and "
            "wand packets, so the phone stays free to scan. The board itself never scans. It "
            f"shows up in Bluetooth as {mb('MM_ESP')}.")
    S.append(callout("tip", "What you need", bullets([
        "The board: a <b>Heltec WiFi LoRa 32 V3</b> (screen, battery reading) or a <b>classic "
        "ESP32 DevKit</b> (no screen).",
        "A USB <b>data</b> cable. A charge-only cable powers the board but cannot flash it.",
        "For the Heltec: a LiPo on the battery connector (yours is 400 mAh).",
        "An iPhone with MagicMaker. The Android phone is optional; it only reads the board's "
        "battery.",
    ], "callout_b")))
    S.append(H2("1.1", "Five minutes from box to first send"))
    S.append(steps([
        [f"<b>Flash it (once).</b> On a Windows PC, download {mb('MagicMaker-Flasher-Windows.zip')} "
         "from the release page, unzip it, plug the board in and double-click "
         f"{mb('flash.bat')}. It finds the board, works out which one it is and writes the "
         "right firmware. The first run downloads a flashing tool, so it needs internet "
         f"once. It ends with {mb('Done. … is now advertising as MM_ESP')}. "
         "Mac, Linux, browser and over-the-air options are in section 9.",
         P(link(ZIP_URL, 7.3, "/download/"), "small")],
        "<b>Power it.</b> USB or the battery. It always starts idle: nothing on air, no "
        "programs running. The LED gives a short blink <b>once a second</b>: it is waiting "
        "for a phone. The Heltec screen stays dark. Press <b>PRG</b> to look at it.",
        "<b>Link the iPhone.</b> In MagicMaker open the <b>LINK</b> tab, find <b>RELAY / "
        "LINK</b> and set <b>Backend</b> to <b>ESP32</b>. No pairing: it links by itself. "
        f"Once linked, the state reads {mb('ESP32 READY')} and the IPHONE row reads "
        f"{mb('Connected — ready to transmit')}. The LED slows to one blink every "
        f"<b>5 seconds</b>, and the Heltec STATUS page shows {mb('BLE LINKED')}.",
        "<b>Send something.</b> Use the TX, WAND or LAB tabs as usual. Every send now goes "
        "out through the board, with one LED flash per send. With the default settings a band "
        "command is on air for about 4.5 s (0.52 s wake ping, then 4 s of command). Keep the "
        "board near the band.",
        "<b>Optional: let the board work on its own.</b> <b>KEEP BAND AWAKE</b> (LAB tab), a "
        "<b>TX loop</b> (TX tab) or a <b>wand loop</b> (WAND tab) run on the board itself and "
        "keep going if the phone disconnects, locks or closes the app. See section 7.",
    ]))
    S.append(callout("note", "On the day", [
        f"<b>Battery:</b> press <b>PRG</b> once; the bottom line of STATUS ({mb(EX_BAT)}, the "
        "time left to the low-battery cutoff) also shows on the iPhone's LINK tab and top bar. "
        f"Below {vt(WARN_MV)} it reads {mb('LOW')}; at {vt(CUT_MV)} the Heltec turns itself off "
        "to protect the cell (5.7). <b>Done for the day?</b> Hold <b>PRG</b> 2 s on the POWER "
        "page, or tap <b>POWER OFF</b> in SETTINGS → BOARD POWER; <b>RST</b> turns it on again "
        "(4.7).",
    ]))
    S.append(callout("tip", "Carrying the Android phone too?", [
        "It does not link to the board; it only reads the board's battery heartbeat and "
        f"shows it in its top bar. Its Relay tab advises: {mb('STANDALONE keeps this phone off the air as a relay (no BLE GATT advertising) so an iPhone can target the ESP32.')}",
    ]))

    # ======================================================================================
    section("2", "The board at a glance",
            "Both boards run the same firmware with the same name, Bluetooth IDs, timing, "
            "programs and update method. The Heltec adds the screen and battery reading.")
    S.append(H2("2.1", "Heltec WiFi LoRa 32 V3"))
    S.append(heltec_drawing())
    S.append(P("Schematic, not to scale. Parts sit in different places on different board "
               "revisions, so go by the printed labels on your board. The LoRa radio is never "
               "used by MagicMaker; the firmware puts it to sleep at boot to save about 0.6 mA, "
               "and keeps it asleep while the board is off.", "caption"))
    S.append(H2("2.2", "Classic ESP32 DevKit"))
    S.append(devkit_drawing())
    S.append(P("Schematic, not to scale. The reset button is often printed EN. Whether there is "
               "an LED on LED_BUILTIN / GPIO2 depends on your board.", "caption"))
    S.append(H2("2.3", "The buttons"))
    S.append(table(["Button", "What it does"], [
        ["PRG (Heltec)",
         "<b>Press:</b> lights the screen; the first press only wakes it and always opens "
         "STATUS. <b>Next presses:</b> next page. <b>Hold 1 s on DEVICE:</b> next battery "
         "capacity (section 4.5). <b>Hold 1 s on LOW BATTERY:</b> next cutoff level (4.6). "
         "<b>Hold 2 s on POWER:</b> turns the board off (4.7). <b>Every press</b> also opens "
         "the 2-minute window for a Bluetooth firmware update. <b>Held while you tap RST:</b> "
         "flashing (download) mode for a cable flash."],
        ["BOOT (classic)",
         "<b>Every press</b> opens the 2-minute window for a Bluetooth firmware update. Hold it "
         f"while a flasher says {mc('Connecting...')} to get into flashing mode. Nothing else."],
        ["RST (Heltec) / EN (classic)",
         "Hardware reset: the board restarts at once. It is also the <b>only way to turn the "
         "board on</b> after a power-off or a low-battery cutoff. See <i>What a restart "
         "clears</i> below."],
    ], [0.22, 0.78], first_bold=True))
    S.append(P("PRG and BOOT are the same pin (GPIO0). At runtime PRG is just a button: it only "
               "selects flashing mode when you hold it while tapping RST. So keep your finger "
               "off PRG when you press RST to turn the board on.", "small"))
    S.append(callout("note", "What a restart clears (RST, power loss, power-off, firmware update)",
                     bullets([
        "<b>Programs stop.</b> Keep-awake, TX loop and wand loop are kept in memory only; the "
        "board always boots idle.",
        "<b>Chip settings go back to defaults</b> (wake 520 ms, command 4000 ms, wand 500 ms, "
        "power MAX, sustained mode) until the iPhone links again and pushes its own values.",
        "<b>Counters start again:</b> PKT sent, uptime and the last-packet info.",
        "<b>The runtime estimate restarts</b> from its model; give it about 30 minutes before "
        "trusting it again (section 5.2).",
        "<b>Kept</b> (Heltec), also through a Bluetooth update: the battery capacity and the "
        "low-battery cutoff level, if picked more than 3 seconds before the restart (turning "
        "the board off saves them at once). Nothing else is stored on the board.",
    ], "callout_b")))
    S.append(H2("2.4", "Heltec and classic side by side"))
    S.append(table(["", "Heltec WiFi LoRa 32 V3", "Classic ESP32 DevKit"], [
        ["Chip and image", f"ESP32-S3, 8 MB flash, {mc('magicmaker-heltec-v3.bin')}",
         f"ESP32, 4 MB flash, {mc('magicmaker-esp32.bin')}"],
        ["Screen", '0.96" OLED, five pages, lit by PRG', "None"],
        ["Battery %, runtime, charging", "Yes: screen, iPhone LINK tab, Android top bar",
         "No battery reader: no battery anywhere"],
        ["Low-battery warning and cutoff", f"Yes: {mc('LOW')} below {vt(WARN_MV)}, off at "
         f"{vt(CUT_MV)} (or 3.20 / 3.40 V, or never)", "No"],
        ["Turning it off", "Hold PRG 2 s on the POWER page, iPhone POWER OFF, or the cutoff. "
         "About 15–25 µA while off (estimate)",
         "iPhone POWER OFF. The chip sleeps, but most DevKits keep drawing a few mA"],
        ["Status LED", "GPIO35", "LED_BUILTIN, else GPIO2"],
        ["Update / flashing button", "PRG", "BOOT"],
        ["Board label", f"{mc('HELTEC V3')} (DEVICE page FW line, iPhone LINK tab ESP32 row)",
         f"{mc('ESP32')} (iPhone LINK tab ESP32 row)"],
        ["Idle draw", "Roughly 30–45 mA (estimate) without Bluetooth modem sleep; with it "
         "(1.5, images linked with it) an estimated 3–10 mA less",
         "Uses Bluetooth modem sleep; datasheet range ~20–30 mA at 80 MHz"],
    ], [0.22, 0.39, 0.39], first_bold=True))

    # ======================================================================================
    section("3", "Status LED",
            "The LED only ever blinks; it never stays on. It tells you whether a phone is "
            "linked and when a packet goes on air.")
    S.append(table(["What you see", "What it means"], [
        ["A short blink (25 ms) every second", "Waiting for a phone. Nothing is linked."],
        ["A short blink every 5 seconds", "A phone is linked."],
        ["One longer flash (60 ms)",
         "A packet just went on air: one of your sends, a replay step, an MBLE tap or a loop "
         "burst. At most one flash every 0.25 s, so a fast replay still shows as separate "
         "blinks. The next slow blink is counted from this flash."],
        ["No flash while KEEP BAND AWAKE streams",
         "The keep-awake ping stream does not flash the LED. The slow blink carries on as "
         "usual."],
        ["Nothing at all", "The board is off (a power-off or the low-battery cutoff: press "
                           "RST), no power, a flat battery, or no MagicMaker firmware on the "
                           "board."],
    ], [0.36, 0.64], first_bold=True))
    S.append(P("Where the LED is: GPIO35 on the Heltec V3. On a classic board it is the board's "
               "LED_BUILTIN if it defines one, otherwise GPIO2."))
    S.append(callout("note", "What the LED does not show", [
        "There is no special pattern for a firmware update, low battery, charging or errors. "
        "When the board turns itself off the LED simply stops. If your board has another light "
        "(for example a charge light), the firmware does not control it, so this guide cannot "
        "tell you what it means.",
    ]))

    # ======================================================================================
    section("4", "The screen (Heltec V3)",
            "The 0.96\" OLED is off and unpowered unless you are using it. That saves battery, "
            "and it means a dark screen is normal.")
    S.append(H2("4.1", "Lighting it and turning pages"))
    S.append(bullets([
        "<b>Press PRG:</b> the screen powers up and always opens on <b>STATUS</b>. The first "
        "press only wakes it; a press during its ~0.1 s power-up only keeps it lit longer.",
        "<b>Press again:</b> next page, in a cycle: <b>STATUS → LAST PACKET → DEVICE → LOW "
        "BATTERY → POWER → STATUS</b>. On STATUS and LAST PACKET the page turns as the button "
        "goes down. On DEVICE, LOW BATTERY and POWER it turns when you let go, because holding "
        "there changes a setting or turns the board off. A hold only counts on the page where "
        "the press began, so it never carries over to the next page.",
        "<b>It goes dark 10 s</b> after the last press or release.",
        "<b>Nothing else lights it:</b> not power-on (there is no splash screen), not a phone "
        "linking, not a transmit. <b>One exception:</b> after RST with a battery too low to "
        f"start, it shows {mb('TOO LOW TO START')} for 2 s (section 4.7).",
        "Lighting it pauses the board for under 0.1 s. A transmit running at that moment lasts "
        "that much longer.",
        "While lit, it redraws at most 4 times a second, and the battery is read every 5 s "
        "instead of every 60 s.",
        "Each page has its title on the left and five dots on the right (the filled dot is "
        "the page you are on). Text is capitals in a 5×7 dot-matrix font.",
    ]))

    S.append(H2("4.2", "STATUS page"))
    status_rows = table(["Line", "Shows"], [
        ["BLE", f"{mc('LINKED')}, or {mc('WAITING FOR PHONE')}"],
        ["TX", f"{mc('IDLE')}; {mc('WAKE')} + progress bar while the wake ping runs; "
               f"{mc('SEND')} + bar while the packet goes out. Replay steps show SEND. The "
               "keep-awake stream shows IDLE."],
        ["(3rd line)", f"What the board runs by itself: {mc('KEEP AWAKE ON')}, "
                       f"{mc('TX LOOP 3S')}, {mc('WAND LOOP 2.5S')}, or {mc('KEEP AWAKE OFF')} "
                       "(nothing running)"],
        ["PKT", f"{mc('42 SENT')}: packets put on air since boot. The keep-awake stream is not "
                "counted."],
        ["(5th line)", f"{mc('LAST BAND 7S AGO')}: kind (BAND, WAND, PING, RAW) and age in "
                       f"S/M/H/D. {mc('LAST --')} until something is sent."],
        ["BAT", f"{mc(EX_BAT)} (runtime to the cutoff), {mc('68% CHARGING')}, "
                f"{mc('100% USB POWER')}, or {mc('--')} (no reading). Low battery: "
                f"{mc(LOW_BAT)}, highlighted (5.7)."],
    ], [0.21, 0.79])
    S.append(side_by_side([OledFlowable(screen_status(), 1.36, 6),
                           P("STATUS while a TX loop sends a band packet.", "caption")],
                          [_shrink(status_rows, FW - 194)], 194))

    S.append(H2("4.3", "LAST PACKET page"))
    S.append(side_by_side(
        [OledFlowable(screen_packet(), 1.36, 6),
         P("After a wake ping (interrogate).", "caption")],
        [P(f"Shows {mb('NO PACKET YET')} until something is sent. Then:"),
         *bullets([
             f"<b>First line:</b> kind, length in bytes, {mb('WAKE+')} when a wake ping ran "
             "first, then how long the packet streamed in ms (under interleave: the whole "
             f"window). Example: {mb('BAND 23B WAKE+4000MS')}.",
             "<b>Then the packet itself</b> in hex, seven bytes per line, up to five lines.",
             f"{mb('RAW')} means a replay step or an MBLE tap.",
         ])], 194))

    S.append(H2("4.4", "DEVICE page"))
    device_rows = table(["Line", "Shows"], [
        ["BAT", f"Battery voltage and %: {mc(volt_pct(EX_MV))}. {mc('--')} with no plausible "
                "reading."],
        ["CAP", f"Charge left of the capacity: {mc(f'{EX_LEFT} OF {CAP}MAH')} "
                f"({mc('-- OF 400MAH')} with no reading). Highlighted while you change it."],
        ["RUN", f"Time to the low-battery cutoff: {mc(EX_RUN + ' LEFT')}, {mc('~40M LEFT')}, "
                f"{mc('~99H+ LEFT')}; or {mc('CHARGING')}, {mc('USB POWER')}, {mc('--')}"],
        ["UP", f"Time since boot, days + HH:MM:SS: {mc('0D 02:14:09')}"],
        ["BLE", f"Name + last three bytes of the Bluetooth address: {mc('MM_ESP DD:EE:FF')}"],
        ["FW", f"Firmware and board: {mc(FW_VERSION + ' HELTEC V3')}"],
    ], [0.21, 0.79])
    S.append(side_by_side([OledFlowable(screen_device(), 1.36, 6),
                           P("DEVICE on a 400 mAh cell.", "caption")],
                          [_shrink(device_rows, FW - 194)], 194))

    S.append(H2("4.5", "Setting the battery capacity"))
    S.append(P("The capacity turns the battery % into milliamp-hours left and a runtime. The "
               "% itself comes from the voltage and does not depend on it. The default is "
               "<b>400 mAh</b>, which matches your cell, so you only need this if you fit a "
               "different battery."))
    S.append(side_by_side(
        [OledFlowable(screen_device(f"{int(500 * pct_from_mv(EX_MV) / 100 + 0.5)} OF 500MAH",
                                    True, f"{EX_RUN_500} LEFT"), 1.36, 6),
         P("Holding PRG: CAP highlighted, RUN follows the new size.", "caption")],
        [steps([
            "Press <b>PRG</b> until the <b>DEVICE</b> page shows.",
            "<b>Let go, then press and hold PRG.</b> Only a press that starts on DEVICE "
            "counts. After 1 s the CAP line jumps to the next size and turns highlighted.",
            "Keep holding to step again every second (at most one full round, 7 steps, per "
            "hold). Let go on your size.",
            "<b>Wait 3 seconds</b> before you press RST or unplug: the choice is saved 3 s "
            "after the last change. Turning the board off (4.7) saves it at once.",
        ], TEAL, FW - 194)], 194))
    S.append(P(f"Sizes, in order: {mb('400 → 500 → 1000 → 1100 → 2000 → 3000 → 5000 → 400 mAh')}. "
               "A long press never turns the page. The CAP line stays highlighted for 1.5 s "
               "after the last change. The saved size is used at every boot. Apart from a "
               "firmware update, the capacity and the cutoff level (4.6) are the only things "
               "the firmware writes to the board's flash."))

    S.append(H2("4.6", "LOW BATTERY page: the cutoff level"))
    cutoff_rows = table(["Line", "Shows"], [
        ["CUT", f"The cutoff level: {mc(volts(CUT_MV))} or {mc('OFF')}. Highlighted while you "
                "change it."],
        ["BAT", f"Voltage and %, as on DEVICE ({mc('--')} with no reading)."],
        ["(3rd line)", f"{mc('OK')}, {mc('LOW - CHARGE SOON')}, {mc('CHARGING')}, "
                       f"{mc('USB POWER')} or {mc('--')}"],
        ["LOW", f"Where the warning starts: {mc('BELOW ' + volts(WARN_MV))} (cutoff + 0.10 V; "
                f"{vt(WARN_MV)} with the cutoff OFF)"],
        ["(5th line)", f"What the cutoff leaves in the cell: "
                       f"{mc(f'OFF AT ~{cut_left_pct(CUT_MV)}% LEFT')} (~{cut_left_pct(3200)}% at "
                       f"3.20 V, ~{cut_left_pct(3400)}% at 3.40 V), or {mc('NO AUTO POWER-OFF')}"],
        ["(6th line)", f"{mc('HOLD PRG: NEXT LEVEL')}"],
    ], [0.21, 0.79])
    S.append(side_by_side([OledFlowable(screen_cutoff(), 1.36, 6),
                           P("The default level, 3.30 V.", "caption")],
                          [_shrink(cutoff_rows, FW - 194)], 194))
    S.append(P("Changing it works like the capacity on DEVICE: press <b>PRG</b> until <b>LOW "
               "BATTERY</b> shows, let go, then <b>press and hold</b>. After 1 s the CUT line "
               "jumps to the next level and turns highlighted; keep holding to step again every "
               "second, at most one round (4 steps) per hold. Let go on the level you want and "
               "wait 3 s before you press RST or unplug."))
    S.append(P(f"Levels, in order: {mb('3.20V → 3.30V → 3.40V → OFF → 3.20V')}. A short press "
               "turns the page to POWER. The board keeps the level across restarts and Bluetooth "
               "updates; the iPhone can set it too (6.9). What each level does is in section 5.7."))

    S.append(H2("4.7", "Turning the board off and on"))
    power_steps = steps([
        "Press <b>PRG</b> until the <b>POWER</b> page shows (from a dark screen: one press to "
        "wake it, then four more).",
        "<b>Let go, then press and hold PRG.</b> The bar fills over <b>2 seconds</b>.",
        f"The screen says {mb('POWERING OFF...')} and {mb('RELEASE PRG')}: <b>let go</b>.",
        f"It shows {mb('PRESS RST TO TURN ON')} for 1 s, disconnects the phone and turns off. "
        "The screen goes dark and the LED stops.",
    ], TEAL, FW - 194)
    S.append(side_by_side([OledFlowable(screen_power(600), 1.36, 6),
                           P("1.2 s into the hold.", "caption")], [power_steps], 194))
    S.append(bullets([
        "<b>Only a press that starts on the lit POWER page counts.</b> A tap (under 0.4 s) "
        "turns the page to STATUS. Letting go before 2 s cancels: the page stays and the bar "
        "empties.",
        "From a dark screen a power-off takes five separate presses and a 2 s hold, so a "
        "button pressed in a bag only lights STATUS for 10 s.",
        f"While a Bluetooth update is being received the page shows {mb('UPDATE RUNNING')} "
        f"and {mb('POWER OFF WHEN DONE')}, and holding does nothing.",
        "If you keep holding PRG after the board asked you to let go, it turns off anyway "
        "after 10 s.",
        "<b>Other ways to turn it off:</b> <b>POWER OFF</b> on the iPhone (6.9; the screen is "
        "not lit for it) and the low-battery cutoff (5.7). Each of them stops sending at once, "
        "disconnects the phone so it notices straight away, and saves a capacity or cutoff "
        "level picked in the last seconds.",
    ]))
    S.append(H3("Turning it on"))
    S.append(P("Press <b>RST</b>. Nothing else turns it on: not PRG, and not the app (only a "
               "computer that opens the board's serial port can reset it, and so turn it on). "
               "It starts like after any power-up: the screen stays dark, the LED "
               "blinks once a second, the iPhone relinks by itself and pushes its settings. "
               "Keep-awake and the loops are off (the board always boots idle)."))
    S.append(P(f"If the battery is too low to start (below the cutoff + 0.10 V, so "
               f"{vt(WARN_MV)} by default) and the board is not on USB power, the screen "
               f"lights for 2 s with {mb('TOO LOW TO START')} and the board turns off again. "
               "<b>Press PRG during those 2 s to start it anyway.</b> If the battery is below the "
               "cutoff level itself, the cutoff turns the board off again within about a "
               "minute."))
    S.append(screen_row([
        (screen_off("release"), "POWER hold done: let go of PRG."),
        (screen_off("going"), "Then, for 1 s, before it turns off."),
        (screen_off("boot_low"), "After RST with a low battery."),
    ]))
    S.append(callout("warn", "Do not hold PRG while you press RST", [
        "That starts the chip's flashing (download) mode, used for cable flashing (9.5). The "
        "board then looks dead (screen dark, LED off) but keeps draining the battery. Tap RST "
        "again without touching PRG.",
    ]))
    S.append(P("Off is not a full disconnect: it charges while off, and it still draws a little "
               "from the battery. For storage, unplug the battery (section 5.8).", "small"))

    # ======================================================================================
    section("5", "Battery and runtime",
            "Heltec V3 only: a classic ESP32 has no battery reader. The board measures the "
            "battery voltage, never the current, so % is rough and runtime is an estimate. "
            "From firmware 1.5 it also turns itself off before the cell runs flat.")
    S.append(H2("5.1", "How the % is worked out"))
    S.append(P("The battery is read through the board's voltage divider (GPIO1, switched on by "
               "GPIO37 for about 20 ms per reading): 0.1 s after boot, then every 60 s while the "
               "screen is dark and every 5 s while it is lit. Close to empty it reads more often: "
               "every 15 s in the low-battery warning zone (with the cutoff on), and every 5 s "
               "after a reading below 3.10 V."))
    S.append(P("Each reading is 32 samples a quarter of a millisecond apart and keeps the 75th "
               "percentile, so the short dips of the board's own transmit bursts barely move it. "
               "Outside the warning zone a reading waits while the board is transmitting, for at "
               "most 10 s; inside it, it never waits. The voltage is smoothed (3-minute time "
               "constant) and looked up on a LiPo resting-voltage curve, straight lines in "
               "between:"))
    curve = [(f"{mv / 1000:.2f} V", f"{100 - 10 * i}%") for i, mv in enumerate(BM["curve"])]
    ct = Table([[P("<b>Voltage</b>", "cell")] + [P(v, "cell") for v, _ in curve],
                [P("<b>Battery</b>", "cell")] + [P(p, "cell") for _, p in curve]],
               colWidths=[0.12 * FW] + [0.08 * FW] * 11)
    ct.setStyle(TableStyle([("GRID", (0, 0), (-1, -1), 0.5, RULE),
                            ("BACKGROUND", (0, 0), (0, -1), ZEBRA),
                            ("LEFTPADDING", (0, 0), (-1, -1), 4),
                            ("TOPPADDING", (0, 0), (-1, -1), 3),
                            ("BOTTOMPADDING", (0, 0), (-1, -1), 4)]))
    ct.spaceAfter = 8
    S.append(ct)
    S.append(bullets([
        "The % reads high while charging.",
        f"Readings outside 2.5–4.6 V count as <b>no battery</b>: the screen shows {mb('--')} "
        "and the iPhone gets no battery values. With no battery fitted but USB plugged in, the "
        f"board may read the charger's output instead and show {mb('USB POWER')}.",
        "The board works out which way round the divider switch goes (it differs between "
        "V3.0/V3.1 and V3.2) by itself.",
        f"<b>Charge left</b> = capacity × %. On a {CAP} mAh cell at {EX_PCT}% that is "
        f"{EX_LEFT} mAh.",
    ]))

    S.append(H2("5.2", "How the runtime is estimated"))
    S.append(P("Runtime left = the charge <b>above the low-battery cutoff</b> ÷ estimated "
               f"current. So {mb('~0M')} is the moment the cutoff turns the board off; with the "
               "cutoff OFF it counts down to empty. The % and the charge left stay the cell's "
               "own. The board cannot measure current, so it starts from a model: a "
               "time-weighted average over about 15 minutes of what it has been doing:"))
    S.append(table(["State", "Model current"], [
        ["Base: chip at 80 MHz with Bluetooth on, LoRa asleep, screen off",
         f"{ma(BM['DRAW_BASE_MA'])} mA"],
        ["Advertising with no phone linked", f"+{ma(BM['DRAW_ADV_MA'])} mA"],
        ["A phone linked", f"+{ma(BM['DRAW_LINK_MA'])} mA (instead of the "
                           f"{ma(BM['DRAW_ADV_MA'])})"],
        ["Beacon on air: sends, keep-awake stream, loop bursts", f"+{ma(BEACON_MA)} mA"],
        ["Screen lit", f"+{ma(SCREEN_MA)} mA"],
    ], [0.72, 0.28]))
    S.append(P("Once the battery has visibly drained (at least 2% over at least 20 minutes, "
               "counted from 10 minutes after boot or after charging), the <b>measured</b> "
               "drain takes over: the % slope over the last hour, smoothed and kept between "
               "0.5× and 2.5× the model. So after any restart or charge, the runtime relies on "
               "the model alone for at least about half an hour."))
    S.append(P("The model's figures are starting values, not measurements, and they leave out "
               "Bluetooth modem sleep (5.5). If the board draws less, the measured drain shows "
               f"it after that half hour. Runtime is written {mb(EX_RUN)}, {mb('~40M')} under "
               f"an hour, and {mb('~99H+')} from 99 hours."))

    usable = CAP * (100 - pct_from_mv(CUT_MV)) / 100            # 360 mAh to the 3.30 V cutoff
    ka_lo = DRAW_IDLE + BEACON_MA                                 # keep-awake, no phone
    ka_hi = DRAW_LINKED + BEACON_MA                               # keep-awake, iPhone linked
    S.append(KeepTogether([
        H2("5.3", f"What to expect from your {CAP} mAh cell"),
        table(["How you use it", "Model current", f"Full charge to the {vt(CUT_MV)} cutoff",
               "With the cutoff OFF"], [
            ["Idle, no phone, screen dark", f"~{ma(DRAW_IDLE)} mA",
             f"{hours(usable, DRAW_IDLE)} h", f"{hours(CAP, DRAW_IDLE)} h"],
            ["iPhone linked, nothing sending", f"~{ma(DRAW_LINKED)} mA",
             f"{hours(usable, DRAW_LINKED)} h", f"{hours(CAP, DRAW_LINKED)} h"],
            ["KEEP BAND AWAKE on all the time (beacon always on air)",
             f"~{ma(ka_lo)}–{ma(ka_hi)} mA",
             f"{hours(usable, ka_hi)}–{hours(usable, ka_lo)} h",
             f"{hours(CAP, ka_hi)}–{hours(CAP, ka_lo)} h"],
            ["Each moment the screen is lit", f"+{ma(SCREEN_MA)} mA", "—", "—"],
            ["Turned off (4.7)", "~15–25 µA (estimate)", "Over a year by the board's own draw",
             "—"],
        ], [0.36, 0.18, 0.25, 0.21], first_bold=True),
        P(f"These come from the model's starting figures, not from a meter. The "
          f"{vt(CUT_MV)} cutoff leaves about {cut_left_pct(CUT_MV)}% in the cell, so "
          f"{usable:.0f} mAh of the {CAP} are used. The firmware's own notes put real idle draw "
          f"on the Heltec at roughly 30–45 mA without modem sleep (an estimate): about "
          f"{usable / 45:.0f}–{usable / 30:.0f} hours to the cutoff. If modem sleep saves what "
          f"it is expected to (3–10 mA, not yet measured), the same idle use lasts roughly "
          f"{usable / (DRAW_IDLE - 3):.0f}–{usable / (DRAW_IDLE - 10):.0f} hours. Off, the "
          "cell's own self-discharge matters more than the board. The DEVICE page always shows "
          "the live estimate.", "small")]))

    S.append(H2("5.4", "Charging and USB power"))
    S.append(table(["Shown", "When", "Notes"], [
        [f"{mc('CHARGING')}",
         "The smoothed voltage rose at least 15 mV compared with a reading at least 5 minutes "
         "old. Ends when the voltage falls 10 mV below its charging peak (you unplugged).",
         "Because it compares with an older reading, it can take a few minutes to appear "
         "after you plug in."],
        [f"{mc('USB POWER')}", "The smoothed voltage is above 4.25 V, or the board's USB hint "
                               "(below) sees USB.",
         "On the screen USB POWER wins over CHARGING."],
        ["No runtime", "While either is shown.",
         f"No LOW warning and no cutoff either. iPhone: {mc('CHARGING · 4.18V')} and "
         f"{mc('ESP32:CHG')}. Android: {mc('ESP32:CHG')} while charging, otherwise the % alone "
         f"({mc('ESP32:100%')})."],
    ], [0.17, 0.43, 0.40], first_bold=False))
    S.append(P("The board has no USB-sense pin. Firmware 1.5 uses a hint instead: the board's "
               "USB-serial chip (CP2102) only has power from USB, and while it has, it holds one "
               f"of the ESP32's pins high. So on a computer's USB port the board shows "
               f"{mb('USB POWER')} even with a full, idle cell. On a wall charger that chip may "
               "sit idle; the board then goes by the voltage alone, and a full, idle cell can "
               "show a runtime as if it were on battery. That is expected."))
    S.append(P(f"The hint is not yet confirmed on real boards. If yours shows {mb('USB POWER')} "
               f"on battery alone, rebuild with {mb('MM_USB_SENSE=0')} (11.7): a false USB "
               "reading also switches the warning and the cutoff off.", "small"))
    S.append(callout("note", "Low-battery cutoff: on by default", [
        "The board has no over-discharge protection of its own, so from firmware 1.5 it "
        f"protects the cell itself: {mb('LOW')} below {vt(WARN_MV)}, and off at "
        f"{vt(CUT_MV)}. A board updated from 1.4 starts with it on too. Section 5.7 has the "
        "rules and the other levels.",
    ]))

    S.append(H2("5.5", "Power saving that is always on"))
    S.append(bullets([
        "CPU at 80 MHz from the very first line of start-up, about half the draw of 240 MHz "
        "(Bluetooth needs 80 MHz, so this is the floor).",
        "The Disney beacon is on air only while something is being sent, and only then at full "
        "power (your BROADCAST STRENGTH; MAX = +9 dBm by default).",
        "Waiting for a phone: advertising at +3 dBm, quick (every 0.2–0.4 s) for 30 s after boot "
        "or a disconnect, then every 0.55–0.76 s.",
        "Linked: the link runs at +3 dBm, and the board asks the iPhone for a 30–50 ms "
        "interval so the radio idles between events.",
        "The main loop sleeps until its next job (at most 5 s) instead of polling. No Wi-Fi.",
        "Heltec: the LoRa radio is asleep (~0.6 mA saved), the screen and its power rail are off "
        "unless you press PRG, and the battery divider is on for about 20 ms per reading.",
        "<b>Heltec, new in 1.5: the serial pins are let go after start-up.</b> On battery the "
        "USB-serial chip has no power, and the ESP32 would otherwise push current into it (0 to "
        "about 1 mA, not yet measured). There is no serial log after start-up (the firmware "
        "never prints one anyway); cable flashing is not affected.",
        "<b>Heltec, new in 1.5: Bluetooth modem sleep.</b> The Bluetooth radio switches off "
        "between its radio events instead of idling, an estimated 3–10 mA (not yet measured). "
        "Only images linked with a special flag have it: the iPhone's LINK row (6.3) ends in "
        f"{mb('MODEM SLEEP')} when it is on. A build from the Arduino IDE does not have it.",
        "<b>A real off state</b> (4.7) and <b>the low-battery cutoff</b> (5.7), so a forgotten "
        "board neither drains for days nor runs the cell flat.",
    ]))
    S.append(P("What it does not do: no automatic light sleep (that needs a different build "
               "setup), and no CPU below 80 MHz while Bluetooth runs. 1.5 keeps the connection "
               "settings, beacon timing and transmit powers as they were. Each battery reading "
               "pauses the board for about 8 ms, so a send that arrives in that moment goes out "
               "up to 8 ms later.", "small"))

    warn_mah = CAP * (pct_from_mv(WARN_MV) - pct_from_mv(CUT_MV)) / 100
    warn_lo = round(warn_mah / ka_hi * 60, -1)
    warn_hi = round(warn_mah / DRAW_LINKED * 60, -1)
    S.append(H2("5.6", "Tips for a park day"))
    S.append(callout("tip", None, bullets([
        "Charge fully the night before. In the morning, check the RUN line on the DEVICE page.",
        f"Keep the screen dark: every lit moment adds {ma(SCREEN_MA)} mA. It switches off by "
        "itself after 10 s.",
        "<b>KEEP BAND AWAKE is the biggest extra drain</b>: the beacon is on air the whole "
        f"time (+{ma(BEACON_MA)} mA, about "
        f"{round(usable / DRAW_LINKED - usable / ka_hi):.0f} hours less on {CAP} mAh). Turn it "
        "on when you need it, not all day. A loop only puts the beacon on air during its "
        "bursts.",
        "If the band is close, a lower BROADCAST STRENGTH (SETTINGS) saves power, at the cost "
        "of range.",
        "A bigger cell lasts longer. Set its size on the DEVICE page so the runtime is right.",
        "After a restart or a top-up charge, the runtime is model-only for about 30 minutes. "
        "Take it with a pinch of salt until then.",
        f"<b>Watch for {mb('LOW')}</b>: on {CAP} mAh it appears about {warn_lo:.0f}–"
        f"{warn_hi:.0f} minutes before the cutoff (model figures).",
        "<b>Turn it off between rides</b> (hold PRG 2 s on POWER, or POWER OFF on the iPhone). "
        "Off, it draws about 15–25 µA instead of about 35 mA.",
    ], "callout_b")))

    S.append(H2("5.7", "Low-battery cutoff"))
    S.append(P("The board turns itself off before the cell runs flat, and warns before that. "
               "Set the level on the LOW BATTERY page (4.6) or on the iPhone (6.9). The board "
               "keeps it; the iPhone does not push it on link."))
    lvl = [(0, "OFF", "never", "—", f"{vt(int(BM['LOW_WARN_BASE_MV']) + 100)} (warning only)")]
    for mv in BM["presets"]:
        name = vt(mv) + (" (default)" if mv == CUT_MV else "")
        lvl.append((mv, name, vt(mv), f"~{cut_left_pct(mv)}%", vt(mv + 100)))
    S.append(table(["Setting", "Turns off at", "Left in the cell (the firmware's curve)",
                    f"{'LOW'} warning below"],
                   [[n, at, left, w] for _, n, at, left, w in lvl],
                   [0.24, 0.2, 0.32, 0.24], first_bold=True))
    S.append(H3("The warning"))
    S.append(bullets([
        "Starts when the smoothed voltage drops below the warning level in the table, and ends "
        "50 mV above it. Never while charging or on USB power.",
        f"Shows on the STATUS page as a highlighted BAT line ({mb(LOW_BAT)}), as "
        f"{mb('LOW - CHARGE SOON')} on LOW BATTERY, in amber on the iPhone's LINK tab "
        f"({mb(f'LOW · {LOW_PCT}% · {LOW_LEFT}/{CAP} MAH · {LOW_RUN} LEFT')}) and as "
        f"{mb('ESP32:' + LOW_BAT)} in both phones' top bars.",
        "With the cutoff on, the board reads the battery every 15 s in the warning zone.",
    ]))
    S.append(H3("The cutoff"))
    S.append(bullets([
        "<b>Three readings in a row</b> below the level, with the smoothed voltage below it "
        "too: about 30–45 s after the cell gets there (10–15 s with the screen lit). A "
        "collapsing cell is faster: two readings below 3.10 V at least 5 s apart. The count "
        "starts over once a reading is 50 mV above the level.",
        "<b>Never</b> on USB power, while charging, on an unsteady reading (samples or readings "
        "more than 0.3 V apart), or for 10 minutes after the voltage jumps up by 50 mV or more "
        "(a charger plugged in).",
        "When it fires, the board stops at once (a send on air is cut short). A lit screen "
        "shows the LOW BATTERY frame below for 1 s; then the board disconnects the phone and "
        f"turns off. The iPhone says {mb('ESP32 off: battery low — charge it, then press RST')}.",
        "<b>To start again:</b> charge it, then press RST. Below the cutoff + 0.10 V the board "
        f"refuses to start ({mb('TOO LOW TO START')}, 4.7). That check runs after RST and "
        "power-on; it is skipped after the restart that ends a Bluetooth update, after a crash, "
        "and with the cutoff OFF. After a brownout the board turns off again without lighting "
        "the screen.",
    ]))
    S.append(KeepTogether([screen_row([
        (screen_status(bat=LOW_BAT, low=True), "The warning on STATUS."),
        (screen_off("low", CUT_FRAME_MV), "The cutoff firing, screen lit."),
    ], scale=1.36, bezel=6)]))
    S.append(callout("note", "Accuracy and the cell", bullets([
        "Readings differ between boards by roughly ±30–100 mV, so 3.30 V acts somewhere "
        "between about 3.25 and 3.35 V.",
        "This cutoff, plus the cell's own protection circuit if it has one, is the only "
        "over-discharge protection there is. Set it OFF only if your cell has one.",
        "After a cutoff the cell still holds about 20–40 mAh. That lasts weeks while off, but "
        "<b>recharge it within a month</b>.",
    ], "callout_b")))

    S.append(H2("5.8", "Off and storage"))
    S.append(bullets([
        "<b>What off is:</b> the chip in its deepest sleep with no wake-up source; the LED and "
        "the screen's power rail held off, the LoRa radio asleep, the other pins parked. About "
        "15–25 µA at the battery on a V3.2 (an estimate; a V3.0/V3.1 can draw up to about 9 µA "
        "more while the cell is above about 3.8 V), against about 35 mA running.",
        "<b>It is not a full disconnect.</b> The V3 has no battery switch that software can "
        "work, so only unplugging the battery (or a switch in its lead) gets to zero. "
        "<b>Unplug it for storage.</b>",
        "<b>Charging still works while off:</b> the charger runs from USB, not from the chip. "
        "The board stays off until you press RST.",
        "A computer that opens the board's serial port can reset it, and so turn it on.",
        "The board's charger is set to about 500 mA, which is 1.25 C for a 400 mAh cell (board "
        "hardware, not firmware): use a cell rated for that.",
        "<b>Classic DevKit:</b> POWER OFF from the iPhone works the same way, and EN turns it "
        "on. The ESP32 itself drops to about 10 µA, but most DevKits' regulator and USB chip "
        "keep drawing a few mA (5–15 mA is common), so there off mainly stops the radio.",
    ]))

    # ======================================================================================
    section("6", "Linking and the top bar",
            "The iPhone links to the board over Bluetooth and sends everything through it. "
            "The Android phone never links; it just listens for the board's battery heartbeat.")
    S.append(H2("6.1", "Choosing the ESP32 on the iPhone"))
    S.append(P("Open the <b>LINK</b> tab. Under <b>RELAY / LINK</b>, the <b>Backend</b> "
               "selector has three choices: <b>Android BLE</b>, <b>ESP32</b> and <b>WiFi "
               "Hotspot</b>. Pick <b>ESP32</b>. The choice is saved on the phone (the default "
               "is Android BLE). The tab then says:"))
    S.append(quote("Power on the MagicMaker ESP32. iPhone auto-connects and transmits through "
                   "it while you keep scanning. No pairing needed."))
    S.append(P("There is no QR code or IP address to enter; those are for the WiFi backend."))
    S.append(H2("6.2", "How the link works"))
    S.append(bullets([
        f"The iPhone looks for the MagicMaker relay service and links only to a device named "
        f"{mb('MM_ESP')} (or the old name {mb('MagicMaker-ESP32')}). In ESP32 mode it never "
        "links to an Android relay.",
        "The board advertises quickly (every 0.2–0.4 s) for 30 s after boot or after a phone "
        "leaves, so the phone relinks fast; after that it slows to every 0.55–0.76 s.",
        "It stays findable even in the middle of a keep-awake stream or a loop.",
        "<b>One phone at a time:</b> once a phone is linked, the board stops advertising its "
        "relay service. Its battery heartbeat still carries the name MM_ESP but cannot be "
        "linked to, so a second phone cannot link until the first one disconnects.",
        "On link, the iPhone compares its timing, strength and TX mode with the board's and "
        "sends any that differ. The iPhone is in charge of these settings (section 8).",
        "<b>Disconnecting changes nothing on the board.</b> Keep-awake and loops carry on. "
        "Only a firmware update in progress is dropped.",
        "When the board turns itself off (4.7), it ends the link with a “power off” "
        "reason, so the iPhone notices at once instead of after the link times out.",
    ]))

    S.append(H2("6.3", "What the LINK tab shows"))
    S.append(P(f"The state label reads {mb('ESP32 READY')} once linked and "
               f"{mb('ESP32 SEARCHING')} otherwise. Its dot is cyan when commands work, amber "
               "when only the transmit channel is ready, and red when not linked (the VFD theme "
               "shows a solid LED, a hollow ring and an alarm dot)."))
    S.append(table(["Row", "Shows"], [
        ["IPHONE", f"{mc('Connected — ready to transmit')}, {mc('Connecting… (wait a few seconds)')} "
                   f"or {mc('Not connected — tap Retry below')}"],
        ["HINT", f"Only when there is one: {mc('Power on the ESP32 — tap Retry BLE.')}, "
                 f"{mc('Finishing ESP32 link…')}, {mc('The ESP32 is off — press RST on the board, then tap Retry BLE.')} "
                 f"(after POWER OFF from this iPhone), or {mc('Reflash the ESP32 — its firmware has no chip-side loops.')}"],
        ["STATUS", "The transmit engine's status, for example "
                   f"{mc('No relay linked — nothing sent')}"],
        ["EVENT", "The last app message (see 6.4)"],
        ["ESP32", f"{mc(f'FW {FW_VERSION} · HELTEC V3 · UP 2H 14M')} ({mc('UP 5M')} under an "
                  "hour)"],
        ["RADIO", f"What the board runs by itself: {mc('KEEP AWAKE')}, {mc('TX LOOP · 3S')}, "
                  f"{mc('WAND LOOP · 2.5S')} or {mc('IDLE')}"],
        ["BATTERY", f"{mc(f'{EX_PCT}% · {EX_LEFT}/{CAP} MAH · {EX_RUN} LEFT')} or "
                    f"{mc('CHARGING · 4.18V')}; in amber with {mc('LOW · ')} in front while the "
                    "battery is low (5.7). Left out on a classic ESP32 (no battery reader)."],
        ["LINK", f"Firmware 1.5: the Bluetooth link this iPhone actually has with the board, "
                 f"for example {mc('30 MS · LAT 2 · TO 4 S · MODEM SLEEP')}: connection "
                 "interval, latency, timeout, and MODEM SLEEP when the board's Bluetooth modem "
                 "sleep is on (5.5)."],
    ], [0.15, 0.85], first_bold=True))
    S.append(P("The ESP32, RADIO and BATTERY rows need firmware 1.2 or newer, LINK 1.5. Buttons: "
               "<b>Refresh</b> reads the status again; <b>Retry BLE</b> restarts the search. "
               "With the ESP32 backend the ANDROID SCAN / RX panel and the LIVE RX feed are "
               "hidden, because the board only transmits. Scan, auto-response and log commands "
               f"meant for a relay are refused with {mb('The ESP32 does not scan')}; your "
               "iPhone keeps scanning itself."))

    S.append(H2("6.4", "Messages that say “Android”"))
    S.append(P("The iPhone uses the same link code for the ESP32 as for an Android relay, so "
               "some EVENT messages say “Android” while you are on the ESP32. They mean "
               "the board:"))
    S.append(table(["Message", "Means"], [
        [mc("Android linked — discovering services…"), "Linked, setting up"],
        [mc("Android relay ready"), "The ESP32 is ready to send"],
        [mc("Android broadcasting — hold phone near MagicBand"),
         "Shown on every send. The board is the one broadcasting: keep the <b>board</b> near "
         "the band."],
        [mc("Android relay disconnected — reconnecting"), "Link lost; the app is relinking"],
        [mc("Android connect timeout — tap Retry"), "No progress for 15 s; tap Retry BLE"],
        [mc("Turn on Bluetooth — needed for Android relay"), "iPhone Bluetooth is off"],
        [mc("Waiting for MM_ESP — tap Retry in Remote"),
         "There is no Remote tab: the button is <b>Retry BLE</b> on LINK"],
    ], [0.52, 0.48]))

    S.append(H2("6.5", "Staying linked"))
    S.append(bullets([
        "Every 2 seconds the app checks the link, relinks if needed, and reads the board's "
        "status.",
        "When the link drops, the app starts looking for MM_ESP again by itself. A link stuck "
        "for more than 10 s is torn down and retried, so you should not need to restart the "
        "app.",
        "<b>Retry BLE</b> forces a fresh search (it shows "
        f"{mb('Looking for relay…')}). Turning iPhone Bluetooth off drops the link; turning "
        "it on relinks.",
        "If you change keep-awake or a loop while the board is not linked, the app holds the "
        f"newest command of each kind ({mb('ESP32 not linked — sent when it links')}) and "
        "sends them on the next link.",
    ]))

    S.append(H2("6.6", "The phone in your pocket"))
    S.append(bullets([
        "Keep-awake and the ESP32's loops run on the board. The iPhone can be locked or the "
        "app closed, and they keep going. They do not need the iPhone's screen on.",
        "In the background the iPhone keeps looking for the relay service, so a dropped link "
        "can come back.",
        "SETTINGS → BACKGROUND → <b>KEEP RUNNING IN BACKGROUND</b> keeps the app alive (using "
        "location) only while the iPhone itself is sending: a loop it times for an Android "
        "relay, the random show, a replay or a send in progress. ESP32 loops do not count, "
        "and do not need it.",
        "iPhone limit: iOS does not pass band or wand packets to apps in the background, so "
        "the iPhone hears and records nothing new, and auto-responses do not fire, until you "
        "come back to MagicMaker.",
    ]))

    S.append(H2("6.7", "The iPhone top bar"))
    S.append(P("Both themes show one telemetry line at the top. With the ESP32 linked it looks "
               "like this:"))
    S.append(quote(f"MM/RF BLE:SCAN | ESP32:{EX_BAT} | RX:12 | TX-AUTO:3 | SCAN:ON | RELAY:LINK"))
    S.append(P(f"{mb('BLE:')} is the iPhone's own radio ({mb('OFF')}, {mb('SCAN')} while it "
               f"scans, otherwise {mb('LINK')}). {mb('RELAY:LINK')} means it has a relay, here "
               f"the ESP32, to send through. {mb('TX:LOOP')} and {mb('WAND:LOOP')} appear while "
               "a loop runs. When the line is wider than the screen it scrolls sideways like a "
               "ticker."))
    S.append(P(f"The {mb('ESP32:')} battery part shows only with the ESP32 backend, a live link "
               f"and a battery reading: {mb('ESP32:' + EX_BAT)}, {mb('ESP32:' + LOW_BAT)} while "
               f"the battery is low, or {mb('ESP32:CHG')} (charging or USB power). A classic "
               "ESP32 shows none."))

    S.append(H2("6.8", "The Android top bar (battery heartbeat)"))
    S.append(P("The board sends a small battery heartbeat advert while it waits for a phone "
               "and, once linked, every 1–2 s while nothing is on air. The Android app reads it "
               "without connecting and shows it in the same place in its top bar:"))
    S.append(quote(f"MM/RF BLE:SCAN | ESP32:{EX_BAT} | RX:12 | TX-AUTO:3 | SCAN:ON"))
    S.append(table(["Token", "Means"], [
        [mc("ESP32:" + EX_BAT), "% and runtime left (to the cutoff)"],
        [mc("ESP32:" + LOW_BAT), "Low battery (firmware 1.5): it turns itself off soon (5.7)"],
        [mc("ESP32:100%"), "% only: on USB power (no runtime then)"],
        [mc("ESP32:CHG"), "Charging"],
        ["(nothing)", "No heartbeat heard for 2 minutes, no battery reading, or a classic "
                      "ESP32 (it never has one)"],
    ], [0.3, 0.7]))
    S.append(callout("note", "Why the Android battery can disappear", bullets([
        "<b>The board does not send the heartbeat while anything is on air.</b> With "
        "KEEP BAND AWAKE on, something is always on air, so the token drops off after 2 "
        "minutes and stays away until keep-awake is turned off. With a loop it comes back "
        "between bursts.",
        "The Android phone must be scanning. Turning its scan off, or turning on the "
        "<b>Android</b> app's own keep-awake (which pauses its scan), stops the readout. Its "
        "scan still picks the heartbeat up with the screen off.",
        "The % changes only when the reading moves 0.75 points, and the runtime in steps "
        "of 5, 15 or 30 minutes (up to 99 h), so the advert only changes when the battery "
        "does.",
    ], "callout_b")))

    S.append(H2("6.9", "BOARD POWER on the iPhone"))
    S.append(P("SETTINGS → <b>BOARD POWER</b>, right after BOARD FIRMWARE. It is there only "
               "with the ESP32 backend, in both themes, and needs firmware 1.5 on the board."))
    S.append(table(["Part", "What it does"], [
        ["BATTERY", f"The board's battery, as on LINK ({mc(f'{EX_PCT}% · {EX_LEFT}/{CAP} MAH · {EX_RUN} LEFT')}); "
                    "amber (VFD: alarm colour) with LOW while the battery is low."],
        ["LOW-BATTERY CUTOFF", f"Chips {mc('OFF')} {mc('3.20V')} {mc('3.30V')} {mc('3.40V')} "
                               "(VFD theme: LOW CUTOFF). A tap sets the board's level (5.7) at "
                               "once. Only on a Heltec, which reports its level; dimmed and "
                               "ignoring taps while the board is not linked."],
        ["POWER OFF", "Red (VFD: alarm colour), only while linked. Asks first: "
                      "<b>Power off the ESP32?</b> with <b>POWER OFF</b> / <b>CANCEL</b>. Works "
                      "on both boards."],
    ], [0.27, 0.73], first_bold=True))
    S.append(P("The caption under the chips reads:"))
    S.append(quote("Turns the board off at this voltage (about 5 / 10 / 18 % left) so the battery "
                   "is never run flat. Press RST on the board to turn it on again after "
                   "charging."))
    S.append(P("And the POWER OFF question:"))
    S.append(quote("It stops transmitting and disconnects. Press RST (EN on a DevKit) on the board "
                   "to turn it on again. It still charges while off."))
    S.append(table(["Line or EVENT message", "Means"], [
        [mc("ESP32 low-battery cutoff 3.30V") + " / " + mc("ESP32 low-battery cutoff OFF"),
         "The board took the new level."],
        [mc("ESP32 not linked — link it to change its cutoff"),
         "Link first. A level picked while not linked is not kept for later."],
        [mc("ESP32 powering off — press RST on the board to turn it on"),
         "The board is turning off. RST brings it back."],
        [mc("ESP32 is receiving a firmware update — power it off when it is done"),
         "An update is being received: the board refuses until it is done."],
        [mc("POWERED OFF — PRESS RST ON THE BOARD"),
         "Shown under the section until the board links again."],
        [mc("Link the ESP32 to change its low-battery cutoff or turn it off."), "Not linked."],
        [mc("Needs board firmware 1.5 — update it in BOARD FIRMWARE."),
         "The board runs older firmware (9.1)."],
    ], [0.55, 0.45]))
    S.append(P("The board is in charge of the cutoff level: it keeps it in its own memory, the "
               "iPhone shows what the board reports and never pushes a level on link. Changing "
               "it on the board's LOW BATTERY page (4.6) shows up here at the next status "
               "read.", "small"))

    # ======================================================================================
    section("7", "Chip-side programs",
            "Three programs run on the board itself: KEEP AWAKE, TX LOOP and WAND LOOP. Only "
            "one runs at a time, and they keep going with or without the phone.")
    S.append(table(["", "What it does", "Turn it on", "On the board"], [
        ["KEEP AWAKE", "Streams a wake ping whenever nothing else is on air, so the band "
                       "keeps listening", "LAB tab → <b>KEEP BAND AWAKE</b>",
         f"{mc('KEEP AWAKE ON')}, TX reads IDLE; no LED flash"],
        ["TX LOOP", "Sends one packet again and again, with a gap between bursts",
         "TX tab → <b>TX LOOP SETTINGS</b> → <b>LOOP</b>", f"{mc('TX LOOP 3S')}; one flash per burst"],
        ["WAND LOOP", "Sends one wand colour again and again", "WAND tab → <b>LOOP</b>",
         f"{mc('WAND LOOP 2.5S')}; one flash per burst"],
    ], [0.15, 0.35, 0.25, 0.25], first_bold=True))
    S.append(callout("note", "Rules for all three", bullets([
        "<b>One at a time.</b> Turning one on turns the others off.",
        "<b>They survive the phone:</b> disconnect, lock the phone or close the app and the "
        "board keeps going. When the phone relinks, the app reads back what is running and "
        "sets its switches to match.",
        "<b>They do not survive a restart.</b> RST, a power loss, a power-off or a firmware "
        "update stops them: the board always boots idle. Turn them on again from the app.",
        "<b>To stop one:</b> turn its switch off in the app. To stop everything at once with "
        "no phone, tap RST.",
    ], "callout_b")))

    S.append(H2("7.1", "KEEP BAND AWAKE"))
    S.append(bullets([
        "On the LAB tab, in the mode bar: <b>KEEP BAND AWAKE</b>. It can be turned on only "
        "while the board is linked, and can always be turned off.",
        "Once it is on (or with the LAB tab in EXTENDED mode), a <b>PING</b> picker chooses "
        f"what is streamed: {mb('Wake ping (CC03 000100)')} "
        f"(the default, {mb('8301CC03000100')}) or {mb('Beacon ping (CC03 000000)')}.",
        "While it runs, band commands <b>skip the wake phase</b>: the band is already "
        "listening, so the command goes out alone for the COMMAND BURST time. After every send "
        "the stream resumes.",
        "Turning it on: a loop burst already on air finishes, then the stream starts. It also "
        "stops the random show, the TX loop and the wand loop.",
        "Turning it off: the stream stops at once; a send in flight finishes.",
        f"Cost: the beacon is on air the whole time (+{ma(BEACON_MA)} mA), and the Android "
        "phone loses the battery readout (6.8).",
    ]))
    S.append(H2("7.2", "TX loop"))
    S.append(bullets([
        "On the TX tab, tap the <b>TX LOOP SETTINGS</b> header (it reads <b>HIDE TX LOOP</b> "
        "when open). Select a packet first: the <b>LOOP</b> switch is disabled without one.",
        f"The interval slider ({mb('3.0S INTERVAL')}) runs from 0.5 s to 30 s. While the loop "
        f"runs, the header shows {mb('ON · 3.0S · LABEL')}. EVENT: {mb('ESP32 TX loop ON')}.",
        "The board times the bursts itself; the iPhone runs no timer.",
        "<b>The interval is the gap after each burst</b>, measured from the end of the "
        "previous burst. The first burst goes out as soon as the air is free.",
        "Each burst uses the normal timing. A band packet gets wake ping + command, so with "
        "defaults a 3 s loop repeats about every 7.5 s (0.52 + 4 s on air, then 3 s gap).",
    ]))
    S.append(H2("7.3", "Wand loop"))
    S.append(bullets([
        "On the WAND tab, select a colour (the <b>LOOP</b> switch is disabled without one), "
        "then turn on <b>LOOP</b>. The interval slider reads like "
        f"{mb('2.5S | LABEL')} ({mb('NO WAND LIBRARY')} if the library is missing).",
        "Each burst lasts the STARLIGHT WAND time (500 ms by default), then the gap.",
        f"EVENT: {mb('ESP32 wand loop ON')} / {mb('OFF')}.",
    ]))
    S.append(P("If the board's loop packet is not in the iPhone's library (for example after "
               f"you reinstalled the app), the app shows the board's label or {mb('ESP32 loop')}."))

    S.append(H2("7.4", "Who goes first when things overlap"))
    S.append(table(["Job", "What happens"], [
        ["Your send (TX, vibrate, interrogate) or an MBLE tap",
         "Cuts off whatever is on air. The newest wins."],
        ["Replay step (from a log)",
         "Waits behind a replay step already on air (one waiting slot; a newer step replaces "
         "the waiting one). Otherwise it cuts in."],
        ["Loop burst", "Never cuts in: starts only when the air is free. If your send cut a "
                       "burst short, the loop re-arms one interval after your send ends."],
        ["Keep-awake stream", "Fills any quiet time and resumes after every job."],
    ], [0.36, 0.64], first_bold=True))

    S.append(H2("7.5", "Switching the iPhone away from the ESP32"))
    S.append(P("If you switch the Backend away from ESP32 while keep-awake or a loop is "
               "running, the board keeps running it. The app tells you so: "
               f"{mb('Relay: <backend> — the ESP32 keeps running its keep-awake or loop until it relinks or is power-cycled')}. "
               "The iPhone's switches go off and nothing more is sent to the board. To stop it, "
               "switch back to ESP32 and turn it off, or tap RST. Switching <b>to</b> the ESP32 "
               "hands a loop the iPhone was running over to the board."))

    # ======================================================================================
    section("8", "Transmit timing settings",
            "SETTINGS → TRANSMISSION SETTINGS. When the board is linked the section says "
            "“ESP32 LINKED — CHANGES ARE SENT TO IT TOO”: each change goes straight "
            "to the board, and on every new link the iPhone re-sends any the board has "
            "different.")
    S.append(table(["Setting", "Default", "Range", "What it does"], [
        ["TX MODE", "SUSTAINED", "SUSTAINED / INTERLEAVE",
         "<b>Sustained:</b> wake ping for WAKE SLICE, then the command for COMMAND BURST "
         "(“strongest wake”). <b>Interleave:</b> alternating wake and command slices, "
         "each WAKE SLICE long, inside a window of COMMAND BURST (“lighter, good "
         "in-park”)."],
        ["BROADCAST STRENGTH", "MAX", "MIN / LOW / MED / MAX = −12 / −6 / 0 / +9 dBm",
         "Beacon power. Lower = shorter range, fewer nearby bands react."],
        ["WAKE SLICE", "520 ms", "100–3000 ms, step 50",
         "Sustained: length of the wake ping. Interleave: length of each slice."],
        ["COMMAND BURST", "4000 ms", "500–12000 ms, step 50",
         "Sustained: length of the command. Interleave: the whole window. Under keep-awake: "
         "the command alone."],
        ["STARLIGHT WAND", "500 ms", "250–5000 ms, step 250", "Length of each wand burst."],
    ], [0.19, 0.14, 0.22, 0.45], first_bold=True))
    S.append(P("The VFD theme labels the sliders WAKE SLICE MS, COMMAND BURST MS and "
               "STARLIGHT WAND MS. These settings live in the board's memory only: after a "
               "restart it uses the defaults above until the iPhone links and sends its own "
               "values. The SCAN FILTER setting is never sent to the ESP32, because it does not "
               "scan.", "small"))
    S.append(H2("8.1", "What a band send looks like on air"))
    S.append(timing_drawing())
    S.append(P("Default settings. Interleave fits as many wake + command pairs as the window "
               "allows (4000 ÷ 1040 = 3 pairs), at least one.", "caption"))
    S.append(H2("8.2", "Fixed timings"))
    S.append(table(["Job", "On air for"], [
        ["Wand packet", "One burst of STARLIGHT WAND (no wake phase)"],
        ["Ping / interrogate", "2000 ms, one burst (not settable)"],
        ["Replay step from a log", "The step's own length, 60–10000 ms, the packet alone"],
        ["MBLE tap (LAB → MBLE TAP (LIGHTNING LANE) → MBLE ADV)", "5000 ms by default"],
    ], [0.45, 0.55]))

    # ======================================================================================
    section("9", "Updating firmware",
            f"The board runs firmware {FW_VERSION}. You can see the version on the DEVICE page "
            "(FW line), on the iPhone's LINK tab (ESP32 row) and in SETTINGS → BOARD FIRMWARE.")
    S.append(table(["Method", "Needs", "Use it for"], [
        ["iPhone, over Bluetooth", "Board already on firmware 1.2 or newer; the iPhone app",
         "Normal updates. No cable."],
        ["Windows one-click zip", "Windows PC, USB data cable, internet once",
         "First flash, recovery"],
        ["Web flasher", "Chrome or Edge on a computer, or Chrome on Android with USB OTG. "
                        "GitHub Pages must be enabled.", "First flash without installing anything"],
        [f"{mc('flash.sh')}", "macOS or Linux with python3", "First flash, recovery"],
    ], [0.24, 0.46, 0.30], first_bold=True))
    S.append(P("An iPhone cannot flash by cable (no browser on iPhone or iPad can open a USB "
               "serial port), so the very first flash has to come from a computer or an "
               "Android phone."))

    S.append(H2("9.1", "Over the air from the iPhone"))
    S.append(steps([
        "Link the board as usual (LINK → Backend ESP32). Keep the phone close to the board.",
        f"Open SETTINGS → <b>BOARD FIRMWARE</b>. The BOARD row shows the board and its "
        f"version ({mb('HELTEC V3 · v' + FW_VERSION)}); AVAILABLE shows the newest image the "
        f"app holds ({mb('v' + FW_VERSION + ' · BUNDLED')} or&nbsp;{mb('· WEB')}). The app "
        "carries the current firmware for both boards, so this works offline.",
        "Optional: tap <b>CHECK WEB</b> to look for a newer image on GitHub.",
        "Tap the button: <b>UPDATE TO vX</b> (newer), <b>REINSTALL vX</b> (same version) or "
        "<b>INSTALL OLDER vX</b>. The last two ask first (“Install firmware?”).",
        f"A big prompt says {mb('Press PRG on the Heltec now … The update starts by itself.')} "
        "Press <b>PRG</b> once (<b>BOOT</b> on a classic). You can also press the button first "
        "and tap the update button within 2 minutes.",
        f"Wait. The bar shows {mb('NN% · X.X KB/s')}, then {mb('100% · CHECKING')} and "
        f"{mb('100% · RESTARTING')}. Keep this screen open and the phone close; sends are paused "
        "meanwhile.",
        f"Done: {mb('Updated — the HELTEC V3 now runs v' + FW_VERSION + '.')} The board "
        "restarted, so it is idle: turn keep-awake or loops back on if you want them.",
    ]))
    S.append(P("An update keeps the battery capacity and the cutoff level you picked. A board "
               f"updated from 1.4 to {FW_VERSION} starts with the low-battery cutoff on at "
               f"{vt(CUT_MV)} (5.7); switch it OFF on the LOW BATTERY page or in BOARD POWER "
               "if you do not want it."))
    S.append(callout("tip", "Why it is safe", bullets([
        "The board only takes an update for <b>2 minutes after a button press</b>, so nobody "
        "nearby can reflash it without touching it.",
        "The new image goes into a spare slot and is used only after it passes the board's "
        "checks (MD5, the image's own SHA-256, and the chip type, so an ESP32 image cannot land "
        "on the Heltec's ESP32-S3). If anything fails, or the link drops, the board keeps its "
        "current firmware.",
        f"<b>CANCEL</b> works until the last byte. After sending has started it shows "
        f"{mb('Update cancelled — the board keeps its current firmware.')}",
        "<b>Turning off waits for the update:</b> the POWER page and the app's POWER OFF are "
        "refused while an image is being received. If the low-battery cutoff turns the board "
        "off mid-update, it keeps its current firmware. A finished image that was waiting to "
        "restart starts at the next RST instead.",
    ], "callout_b")))
    S.append(H3("Update messages and what to do"))
    S.append(table(["Message", "What to do"], [
        [mc("Link the ESP32 first (LINK tab, ESP32 backend), then tap UPDATE."),
         "Link the board, then try again."],
        [mc("PRG was not pressed — tap UPDATE to try again."),
         "The app waited 180 s for the press. Tap UPDATE and press PRG (BOOT) when asked."],
        [mc("No HELTEC V3 firmware in the app — tap CHECK WEB."), "Tap CHECK WEB."],
        [mc("FIRMWARE BEFORE 1.2") + " / " + mc("This board's firmware has no Bluetooth updates…"),
         "Flash 1.2 or newer once by cable (9.2–9.4). Later updates can come from the iPhone."],
        [mc("The Bluetooth link dropped during the update — the board drops the partial image and keeps its current firmware…"),
         "Move closer, link again, retry."],
        [mc("The board stopped answering during the update — it keeps its current firmware. Try again."),
         "Retry, closer to the board."],
        [mc("The board did not come back after restarting — power-cycle it, then check its version here."),
         "Tap RST or unplug and replug, then look at the BOARD row."],
        [mc("The board is a X, not a Y — nothing sent."),
         "The image is for the other board type. Nothing was written."],
    ], [0.6, 0.4]))

    S.append(H2("9.2", "Windows: the one-click zip"))
    S.append(steps([
        [f"Download {mb('MagicMaker-Flasher-Windows.zip')}:", P(link(ZIP_URL, 7.3, "/download/"), "small")],
        f"Unzip it. The {mb('MagicMaker-Flasher')} folder holds {mb('flash.bat')}, "
        f"{mb('flash.ps1')}, both firmware images and a {mb('README.txt')}.",
        "Plug the board in with a USB <b>data</b> cable.",
        f"Double-click {mb('flash.bat')}. A window titled {mb('MagicMaker ESP32 flasher')} opens. "
        "No PowerShell settings need changing. On the first run it downloads esptool v4.8.1 "
        "once (no Python needed), unless esptool 4 or newer is already installed.",
        "It lists the COM ports, picks the board's USB-serial port, asks the chip what it is "
        "(read-only) and flashes the matching image: <b>ESP32-S3 → Heltec V3</b>, <b>classic "
        "ESP32 → classic</b>. It checks the image matches the board before writing. If 921600 "
        "baud fails it retries once at 460800.",
        f"Success: {mb('Done. The Heltec V3 is now advertising as MM_ESP - pick the ESP32 backend in the app.')} "
        "Press a key to close the window.",
    ]))
    S.append(P(f"It prints {mb('Using prebuilt … from the repo … - git pull keeps it current')} "
               "when run from the zip. That is normal; ignore the git pull part. Extra options "
               f"can be added after {mb('flash.bat')} in a command prompt, for example "
               f"{mb('flash.bat -Port COM5')}, {mb('-Board heltec-v3')} / {mb('-Board esp32')} "
               f"(skip detection), {mb('-Baud 460800')}, {mb('-ListPorts')}."))
    S.append(table(["If it says", "Do this"], [
        [mc("No COM ports found - the board's USB-serial driver is probably missing, or this is a charge-only USB cable…"),
         "Install the Silicon Labs CP210x VCP driver (Heltec V3, most DevKits) or the WCH CH340 "
         "driver, replug, or try another cable. Check Device Manager → Ports (COM &amp; LPT)."],
        [mc("More than one COM port and none obviously the ESP32. Rerun with -Port"),
         f"Run {mc('flash.bat -Port COMx')} with the right port."],
        [mc("Couldn't talk to the board on COMx to see which one it is…"),
         "Put it in download mode (9.5), close Arduino IDE or any serial monitor, try another "
         "cable, then run again."],
        [mc("This board is an <chip>, which this firmware doesn't support…"),
         "An S2, C3, C6, H2 or P4 chip is not supported. Nothing was written. Tap RST (or "
         "replug) to restart it."],
        [mc("Flashing failed. Common fixes:"),
         f"Download mode (9.5), close other programs on the port, or {mc('-Baud 460800')}."],
    ], [0.5, 0.5]))

    S.append(H2("9.3", "Web flasher"))
    S.append(callout("warn", "Needs GitHub Pages switched on first", [
        f"The page at {link(WEB_FLASHER, 8.7)} is published by the repository's Pages workflow. "
        "Until the owner sets <b>Settings → Pages → Build and deployment → Source: GitHub "
        "Actions</b> once, that address does not work. Use the Windows zip meanwhile.",
    ]))
    S.append(steps([
        "Open the page in <b>Chrome or Edge</b> on Windows, macOS, Linux or ChromeOS, or "
        "<b>Chrome on Android</b> with a USB OTG adapter or a USB-C cable to the board. Not "
        "Safari, and no browser on iPhone or iPad.",
        "Plug the board into the computer with a USB data cable.",
        "Click <b>Connect</b> and pick the board's port (CP210x, USB to UART or USB Serial).",
        "Click <b>Install MagicMaker ESP32 transmitter</b>. It asks the chip what it is, erases "
        "the board and writes the matching firmware, in about a minute.",
        "The board restarts as MM_ESP. Choose the ESP32 backend in the app. On a Heltec the "
        "screen stays dark until you press PRG.",
    ]))
    S.append(P("No port in the list: install the CP210x or CH340 driver, replug, or try another "
               "cable. Port busy: close Arduino IDE, flash.ps1 / flash.sh, or another tab with "
               "the page. Linux: add yourself to the dialout group, then log out and in."))

    S.append(H2("9.4", "macOS and Linux: flash.sh"))
    S.append(P(f"In {mb('firmware/esp32-transmitter/')} run {mb('./flash.sh')}. It works like the "
               "Windows flasher: finds the port, detects the board, flashes the matching image. "
               f"It needs {mb('python3')} and, unless esptool 4 or newer is already installed, "
               f"puts esptool 4.8.1 into {mb('.tools/venv')} on the first run. Options: "
               f"{mb('--board auto|esp32|heltec-v3')}, {mb('--port')} "
               f"(for example {mb('/dev/ttyUSB0')}, macOS {mb('/dev/cu.usbserial-0001')}), "
               f"{mb('--baud 460800')}, {mb('--list-ports')}, {mb('--bin')}. Unlike the Windows "
               f"flasher it does not retry slower by itself: add {mb('--baud 460800')} if it "
               "fails. Linux needs serial access (dialout group; Arch: uucp)."))

    S.append(H2("9.5", "Download mode for cable flashing"))
    S.append(table(["Board", "How"], [
        ["Heltec V3", "Hold <b>PRG</b>, tap <b>RST</b>, release <b>PRG</b>. Run the flasher "
                      "again (or click Connect again). After flashing in this mode, tap "
                      "<b>RST</b> once to start the new firmware. (This is why PRG must stay "
                      "untouched when you press RST to turn the board on, 4.7.)"],
        ["Classic ESP32", f"Hold <b>BOOT</b> while the flasher says {mc('Connecting...')}; let "
                          "go once writing starts."],
        ["Both", "Close any serial monitor or Arduino IDE holding the port. Try another USB "
                 "cable: charge-only cables have no data wires."],
    ], [0.2, 0.8], first_bold=True))

    # ======================================================================================
    section("10", "Troubleshooting",
            "Find the symptom, check the likely cause, try the fix. Most problems are a link "
            "that needs a retry, a dark screen that only needs PRG, or a restart that cleared "
            "a program.")
    rows = [
        ["Linking"],
        [f"iPhone stays on {mc('ESP32 SEARCHING')} / {mc('Scanning for MM_ESP…')}",
         "Board turned off or flat; Backend not set to ESP32; iPhone Bluetooth off; another "
         "phone already linked to the board",
         "LED should blink once a second (waiting): if not, press RST. Set Backend to ESP32, "
         "turn Bluetooth on, tap Retry BLE. Unlink the other phone."],
        [f"{mc('POWERED OFF — PRESS RST ON THE BOARD')} (BOARD POWER) or HINT "
         f"{mc('The ESP32 is off…')}", "You turned it off from this iPhone",
         "Press RST on the board, then Retry BLE."],
        ["LED does nothing", "The board is off (POWER page, POWER OFF, low-battery cutoff), no "
                             "power, flat battery, or no MagicMaker firmware",
         "Press RST. If it does not start, charge it and press RST again. If still nothing, "
         "reflash (section 9)."],
        ["Screen dark and LED off right after pressing RST",
         "PRG was held while RST was pressed: flashing (download) mode", "Tap RST again "
         "without touching PRG (4.7)."],
        [f"HINT {mc('Reflash the ESP32 — its firmware has no chip-side loops.')} or EVENT "
         f"{mc('ESP32 firmware is outdated…')}",
         "Firmware older than 1.2", "Flash it once by cable (9.2–9.4)."],
        [f"{mc('No relay linked — nothing sent')} / {mc('Transmit failed — check relay')}",
         "The link is down", "Tap Retry BLE on LINK and wait for ESP32 READY."],
        ["EVENT messages say “Android”", "Shared wording with the Android relay",
         "Nothing to fix: they mean the ESP32 (6.4)."],
        ["Screen and battery"],
        ["Heltec screen is dark", "Normal: only PRG lights it, and it goes dark after 10 s",
         "Press PRG. If it stays dark on battery, the board is off or the cell is flat: press "
         "RST, or charge it first."],
        [f"{mc('TOO LOW TO START')} after RST", "Battery below the cutoff + 0.10 V "
                                                f"({vt(WARN_MV)} by default)",
         "Charge it, then press RST. Or press PRG during the 2 s to start anyway (4.7)."],
        ["The board turned itself off", "The low-battery cutoff (iPhone EVENT: "
                                        f"{mc('ESP32 off: battery low…')})",
         "Charge it, then press RST. Set the cutoff OFF only if the cell has its own "
         "protection (5.7)."],
        ["POWER hold does nothing", "The press started on another page, you let go before "
                                    "2 s, or an update is being received",
         "Let go, press and hold again on the POWER page."],
        [f"BAT line highlighted with {mc('LOW')}", "Low-battery warning: the cutoff is near",
         "Charge soon (5.7)."],
        ["PRG press does not turn the page",
         "The first press only wakes the screen; on DEVICE the page turns when you let go",
         "Press again; on DEVICE, release the button."],
        ["Battery size or cutoff level went back after a restart",
         "Restarted within 3 s of picking it", "Pick it again and wait 3 s (4.5, 4.6)."],
        [f"BAT shows {mc('--')}", "No battery, or a reading outside 2.5–4.6 V",
         "Check the battery connector. A classic ESP32 never shows a battery."],
        ["Runtime jumps around", "Model-only for ~30 min after a restart or charge",
         "Wait half an hour of normal use."],
        ["Shows a runtime while on USB", "The USB hint can miss a wall charger: a full idle cell "
                                         "then looks like a resting battery", "Normal (5.4)."],
        [f"Shows {mc('USB POWER')} on battery alone", "The USB hint misreads on your board "
                                                     "(it also turns the cutoff off)",
         f"Rebuild with {mc('MM_USB_SENSE=0')} (11.7)."],
        [f"{mc('CHARGING')} does not appear at once", "It compares with a reading 5 min old",
         "Give it a few minutes."],
        ["iPhone BATTERY row missing", "Classic ESP32, or no plausible reading",
         "Normal on a classic board; on a Heltec, check the cell."],
        ["Programs and sending"],
        ["Android top bar shows no ESP32 battery",
         "Classic ESP32; ESP32 keep-awake on (no heartbeat while on air); Android scan off or "
         "Android keep-awake on; out of range",
         "Turn ESP32 keep-awake off to see it, turn the Android scan on. The token returns "
         "with the next heartbeat."],
        ["KEEP BAND AWAKE will not turn on", "The board is not linked", "Link first."],
        ["LOOP switch is greyed out", "No packet (TX) or colour (WAND) selected",
         "Select one first."],
        ["A loop or keep-awake keeps running after I closed the app or changed Backend",
         "By design: the board runs it by itself",
         "Switch back to ESP32 and turn it off, or tap RST."],
        ["Loops and keep-awake are gone", "The board restarted (RST, power, power-off, update): "
                                          "it boots idle", "Turn them on again."],
        ["Band does not react", "Out of range, low BROADCAST STRENGTH, or the band is not "
                                "listening", "Keep the board close, use MAX strength, try KEEP "
                                             "BAND AWAKE so the band is already listening."],
        ["Flashing and updates"],
        ["Flasher finds no port", "Missing driver or charge-only cable",
         "Install CP210x or CH340 driver; another cable."],
        ["Flasher cannot talk to the board", "Not in download mode, or the port is busy",
         "Download mode (9.5); close Arduino IDE / serial monitors."],
        ["Board does nothing after a flash", "Flashed in download mode; still in the "
                                             "bootloader", "Tap RST."],
        ["Web flasher address does not open", "GitHub Pages not enabled yet",
         "Enable Pages (9.3) or use the Windows zip."],
        ["Browser says it can't open USB serial ports", "Safari, iPhone/iPad or old Chrome",
         "Use Chrome or Edge on a computer."],
        [f"{mc('PRG was not pressed — tap UPDATE to try again.')}", "No press within 180 s",
         "Tap UPDATE and press PRG (BOOT) when the prompt shows."],
    ]
    S.append(table(["Symptom", "Likely cause", "Fix"], rows, [0.33, 0.32, 0.35]))

    # ======================================================================================
    section("11", "Reference",
            "For the curious: what the board reports, its Bluetooth identity, the battery "
            "heartbeat and the build-time settings.")
    S.append(H2("11.1", "STATUS fields (read by the iPhone)"))
    S.append(P("The STATUS characteristic returns one JSON object of at most 508 bytes, keys in "
               "this order. The iPhone's LINK tab and BOARD POWER are built from it. When it "
               "would be longer, the diagnostics (conn, btSleep, advMaxUs) are left out first, "
               "then the loop's label, then its packet."))
    S.append(table(["Key", "When", "Meaning"], [
        [mc("ok") + ", " + mc("error"), "Always / on failure",
         "Reply to the last command (reset to ok when a phone connects)"],
        [mc("running"), "Always (true)", "Marks a real status (firmware before 1.2 sent a bare "
                                         + mc('{"ok":true}') + ")"],
        [mc("proto") + ", " + mc("fw") + ", " + mc("board"), "Always",
         f"{mc(str(RELAY_PROTO))} (2 before 1.5), {mc(FW_VERSION)}, {mc('HELTEC V3')} or "
         f"{mc('ESP32')}"],
        [mc("keepAwake"), "Always", "KEEP AWAKE runs"],
        [mc("txLoopEnabled") + ", " + mc("txLoopIntervalMs"), "TX LOOP runs", "Loop and interval"],
        [mc("starlightLoopEnabled") + ", " + mc("starlightIntervalMs"), "WAND LOOP runs",
         "Loop and interval"],
        [mc("wakeupPreambleMs") + ", " + mc("commandBurstMs") + ", " + mc("starlightBurstMs")
         + ", " + mc("txPowerLevel") + ", " + mc("txInterleave"), "Always", "Chip settings"],
        [mc("uptimeS") + ", " + mc("sent"), "Always", "Seconds since boot; jobs put on air since "
                                                      "boot"],
        [mc("batMv") + ", " + mc("batPct") + ", " + mc("batMah"), "Heltec with a plausible "
                                                                  "reading",
         "Smoothed battery mV, %, capacity in mAh"],
        [mc("runMin") + " / " + mc("charging"), "With the battery keys",
         "Runtime in minutes to the cutoff, or " + mc("true") + " while charging or on USB "
         "(then no runMin)"],
        [mc("batLow"), "With the battery keys, only when true",
         "Low-battery warning (5.7). Firmware 1.5"],
        [mc("cutMv"), "Heltec, always (also with no reading)",
         "Cutoff level: " + mc("0") + " = off, " + mc("3200") + " / " + mc("3300") + " / "
         + mc("3400") + ". Firmware 1.5"],
        [mc("items"), "After a catalog command", mc("[]") + ": the library lives on the phone"],
        [mc("keepAwakeHex"), "KEEP AWAKE runs", "The streamed packet"],
        [mc("txLoopHex") + ", " + mc("txLoopLabel"), "TX LOOP runs",
         "Its packet and label (label dropped first if the object would be too long)"],
        [mc("starlightLoopHex") + ", " + mc("starlightLoopLabel"), "WAND LOOP runs", "Same"],
        [mc("conn"), "A Bluetooth read (diagnostic)",
         "The reading phone's link: [interval in 1.25 ms units, latency, timeout in 10 ms "
         "units]. Firmware 1.5"],
        [mc("btSleep"), "Modem sleep on (diagnostic)", mc("true") + " (5.5). Firmware 1.5"],
        [mc("advMaxUs"), "Bench builds only", "Longest advertising restart since boot, µs "
                                              "(" + mc("MM_DEBUG_TIMING") + ")"],
    ], [0.36, 0.22, 0.42]))
    S.append(P("Example (Heltec, idle, low battery):", "small"))
    S.append(quote('{"ok":true,"running":true,"proto":3,"fw":"1.5","board":"HELTEC V3",'
                   '"keepAwake":false,"wakeupPreambleMs":520,"commandBurstMs":4000,'
                   '"starlightBurstMs":500,"txPowerLevel":3,"txInterleave":false,"uptimeS":8123,'
                   f'"sent":42,"batMv":{LOW_MV},"batPct":{LOW_PCT},"batMah":{CAP},'
                   f'"runMin":{runtime_min(LOW_MV, CAP, DRAW_LINKED, CUT_MV)},"batLow":true,'
                   f'"cutMv":{CUT_MV},"conn":[24,2,400],"btSleep":true}}'))

    S.append(H2("11.2", "Bluetooth identity"))
    S.append(P(f"Name {mb('MM_ESP')} (older firmware: {mb('MagicMaker-ESP32')}). Every UUID "
               f"ends in {mb('-0000-1000-8000-00805F9B34FB')}. The link runs at +3 dBm; the "
               "board asks the phone for a 30–50 ms interval, latency 2, 4 s timeout and MTU 247 "
               "(STATUS " + mb("conn") + " shows what the phone actually uses)."))
    S.append(table(["Part", "UUID", "Access", "Carries"], [
        ["Relay service", mc("A7830001"), "—", "How the app finds the board"],
        ["TX", mc("A7830002"), "write", mc("{hex}|{durationMs}") + ": a send"],
        ["Command", mc("A7830003"), "write", mc('{"action":…}') + " JSON"],
        ["Status", mc("A7830004"), "read", "One JSON object (11.1)"],
        ["Catalog", mc("A7830005"), "read", mc('{"ok":true,"items":[]}') + ", always empty"],
        ["OTA", mc("A7830007"), "write, notify", "Firmware update over Bluetooth (1.2+)"],
    ], [0.17, 0.17, 0.16, 0.50], first_bold=True))

    S.append(H2("11.3", "What the board advertises"))
    S.append(table(["State", "Advert", "Every", "Power", "Linkable"], [
        ["Waiting for a phone", "Service UUID; scan response: MM_ESP + battery heartbeat",
         "0.2–0.4 s for 30 s, then 0.55–0.76 s", "+3 dBm", "Yes"],
        ["Sending (beacon)", "Disney manufacturer data " + mc("83 01") + " + packet; with no "
         "phone linked, scan response MM_ESP + service UUID", "20–30 ms",
         "BROADCAST STRENGTH (default +9 dBm)", "Yes"],
        ["Linked, nothing on air", "MM_ESP + battery heartbeat", "1–2 s", "+3 dBm", "No"],
    ], [0.17, 0.39, 0.17, 0.16, 0.11], first_bold=True))

    S.append(H2("11.4", "Battery heartbeat format"))
    S.append(P("Manufacturer data, 9 bytes, firmware 1.4 and newer. Company id 0xFFFF is "
               "reserved for testing, so nothing mistakes it for a Disney packet."))
    S.append(table(["Bytes", "Value", "Meaning"], [
        ["0–1", mc("FF FF"), "Company id 0xFFFF"],
        ["2–3", mc("4D 42"), "“MB”"],
        ["4", mc("01"), "Version"],
        ["5", "0–100 or " + mc("FF"), "Battery %, FF = none"],
        ["6", "flags", "bit 0 charging, bit 1 USB power, bit 2 battery reading present, bit 3 "
                       "battery low (firmware 1.5; the version byte stays 1)"],
        ["7–8", "u16 little-endian", "Runtime minutes, " + mc("FF FF") + " = unknown (always "
                                     "while charging or on USB)"],
    ], [0.12, 0.25, 0.63]))
    S.append(P(f"A classic ESP32 always sends {mb('FF')} for %, flags {mb('00')} and runtime "
               f"{mb('FFFF')}."))

    S.append(H2("11.5", "Commands the board accepts"))
    S.append(P("Sent by the app on the Command characteristic. Shown for reference; you never "
               "need to type them."))
    S.append(table(["Action", "What the board does"], [
        [mc("transmit") + ", " + mc("vibrate") + ", " + mc("interrogate"),
         "A send with the board's timing; interrogate sends the wake ping " + mc("8301CC03000100")
         + " for 2000 ms"],
        [mc("keep_awake"), "KEEP AWAKE on/off; " + mc("hex") + " of at least 4 bytes, else the "
                                                               "stored one"],
        [mc("set_tx_loop") + ", " + mc("set_starlight_loop"),
         "TX / WAND LOOP on/off, packet, label (up to 16 characters), interval 500–60000 ms. On "
         "with no packet ever given → " + mc("no packet")],
        [mc("set_wakeup_preamble") + ", " + mc("set_command_burst") + ", "
         + mc("set_starlight_burst") + ", " + mc("set_tx_power") + ", " + mc("set_tx_interleave"),
         "The settings in section 8"],
        [mc("raw_burst"), "A replay step: the packet alone, 60–10000 ms (default 500)"],
        [mc("mble_tap"), "MBLE beacon from a token, 60–10000 ms (default 5000); under 4 hex "
                         "digits → " + mc("bad token")],
        [mc("set_scan") + ", " + mc("set_auto") + ", " + mc("set_recording"),
         "Off → accepted, does nothing. On → " + mc("unsupported") + ": the board never scans"],
        [mc("power_off") + " (" + mc("poweroff") + ", " + mc("shutdown") + ")",
         "Firmware 1.5, both boards: turns the board off (4.7). Needs " + mc('"confirm":true')
         + ", else " + mc("confirm required") + "; " + mc("busy") + " while an update is being "
         "received. STATUS stays readable for 0.75 s (1 s with the screen lit)"],
        [mc("set_low_cutoff") + " (" + mc("low_cutoff") + ", " + mc("set_cutoff") + ")",
         "Firmware 1.5, Heltec: " + mc("mv") + " = " + mc("0") + " (off), " + mc("3200") + ", "
         + mc("3300") + " or " + mc("3400") + "; 3000–3600 goes to the nearest level; else "
         + mc("bad mv") + ". Classic ESP32 → " + mc("unsupported")],
    ], [0.42, 0.58]))
    S.append(P("Error replies: " + ", ".join(mb(e) for e in [
        "bad json", "bad hex", "packet too long", "no packet", "bad token", "unsupported",
        "unknown action", "busy", "confirm required", "bad mv", "powering off"]) + " (busy = the "
        "command queue of 8 is full, or power_off during an update; powering off = every "
        "command once a power-off has begun, and sends are ignored then). Packets are 3–29 "
        f"bytes; {mb('83 01')} is added in front when missing."))

    S.append(H2("11.6", "Bluetooth update status codes"))
    S.append(table(["Code", "The iPhone says"], [
        ["1", "the button window is closed (press PRG on the Heltec, BOOT on a classic ESP32, and "
              "try again)"],
        ["2", "the image size does not fit this board"],
        ["3", "the board could not open its update slot"],
        ["4", "data arrived out of order"],
        ["5", "the board could not write its flash"],
        ["6", "the image failed the board's checks (checksum, format or chip)"],
        ["7", "the board was not expecting that step"],
        ["8", "the board did not understand the request"],
    ], [0.1, 0.9]))

    S.append(H2("11.7", "Build-time settings (need a rebuild)"))
    S.append(P("These are constants in the source. Changing one means building the firmware "
               "yourself in the Arduino IDE (esp32 core 2.0.17, NimBLE-Arduino 1.4.x, plus U8g2 "
               f"for the Heltec) from {mb('firmware/esp32-transmitter/')}. Top of "
               f"{mb('esp32-transmitter.ino')} unless noted. Bluetooth modem sleep also needs "
               f"the linker flag {mb('-Wl,--wrap=esp_bt_controller_init')}, which the Arduino "
               "IDE cannot add, so an IDE build runs without it (PlatformIO: "
               f"{mb('build_flags')} of the Heltec environment)."))
    S.append(table(["Constant", "Default", "What it sets"], [
        [mc("DEFAULT_WAKE_MS"), "520 ms", "Wake ping before a band command (the app's value "
                                          "replaces it)"],
        [mc("DEFAULT_CMD_MS"), "4000 ms", "Band command stream"],
        [mc("DEFAULT_STAR_MS"), "500 ms", "Wand burst"],
        [mc("PING_MS"), "2000 ms", "Standalone ping burst"],
        [mc("DEFAULT_POWER_LEVEL"), "3", "Beacon power 0–3 = −12 / −6 / 0 / +9 dBm"],
        [mc("LOOP_DEFAULT_MS"), "3000 ms", "Loop interval until the app sends one"],
        [mc("BEACON_ADV_MIN/MAX"), "20–30 ms", "Advert interval while sending"],
        [mc("IDLE_ADV_FAST_MIN/MAX") + ", " + mc("IDLE_ADV_SLOW_MIN/MAX"),
         "200–400 ms, 546.25–760 ms", "Waiting for a phone: the first 30 s, then after that"],
        [mc("IDLE_FAST_WINDOW_MS"), "30 s", "Fast advertising after boot or a disconnect"],
        [mc("IDLE_ADV_POWER"), "+3 dBm", "Power while waiting for a phone"],
        [mc("LINK_POWER"), "+3 dBm", "Link power (raise to +9 dBm if the link drops at range)"],
        [mc("HEARTBEAT_ADV_MIN/MAX"), "1–2 s", "Battery heartbeat while linked"],
        [mc("LED_MIN_FLASH_GAP_MS"), "250 ms", "At most one transmit flash per this long"],
        [mc("LOOP_MAX_SLEEP_MS"), "5000 ms", "Longest main-loop sleep"],
        [mc("SCREEN_ON_MS"), "10 s", "Heltec: screen time-out"],
        [mc("BATTERY_MAH"), "400 mAh", "Heltec: capacity until one is picked on the screen"],
        [mc("BUTTON_LONG_MS") + ", " + mc("SCREEN_FRAME_MS") + " (oled_ui.h)", "1000 ms, 250 ms",
         "Long press on DEVICE / LOW BATTERY; fastest screen redraw"],
        [mc("POWER_HOLD_MS") + ", " + mc("POWER_TAP_MS") + " (oled_ui.h)", "2000 ms, 400 ms",
         "POWER page: the hold that turns it off; a shorter press is a tap"],
        [mc("POWER_OFF_NOTICE_MS") + ", " + mc("POWER_OFF_GRACE_MS"), "1000 ms, 750 ms",
         "Power-off: the off frame on a lit screen / the app's last status read, before the "
         "disconnect"],
        [mc("MM_LORA_SLEEP") + " (power.h)", "on", "Put the LoRa radio to sleep at boot"],
        [mc("BAT_PERIOD_NEAR_MS") + " (power.h)", "15 s", "Battery reading period in the "
                                                          "warning zone (cutoff on)"],
        [mc("CUT_DEFAULT_MV") + " (battery_model.h)", f"{CUT_MV} mV",
         "Cutoff level until one is picked"],
        [mc("DRAW_*") + " (battery_model.h)", f"{ma(BM['DRAW_BASE_MA'])} mA base …",
         "Runtime model; tune with a meter in the battery lead (a USB meter on a computer also "
         "counts the USB chip)"],
        [mc("MM_USB_SENSE") + " (build flag)", "1", "The USB hint (5.4); 0 if a board shows USB "
                                                    "POWER on battery alone"],
        [mc("MM_UART_RELEASE") + " (build flag)", "1", "Let go of the serial pins after start-up; "
                                                       "0 brings serial logs back"],
        [mc("MM_BT_MODEM_SLEEP") + " (build flag)", "1", "Modem sleep in builds linked with the "
                                                         "flag above; 0 leaves it off"],
    ], [0.4, 0.17, 0.43]))

    S.append(H2("11.8", "Release files"))
    S.append(P(f"All on the {mb('esp32-firmware')} release: {link(RELEASE_URL, 8.2)}. It is never "
               "marked as the repository's “latest” release, because the Android "
               "app's updater uses that for its APKs."))
    S.append(table(["File", "What it is"], [
        [mc("MagicMaker-Flasher-Windows.zip"), "One-click Windows flasher with both images"],
        [mc("magicmaker-heltec-v3.bin"), "Heltec V3 merged image (flashed at 0x0)"],
        [mc("magicmaker-esp32.bin"), "Classic ESP32 merged image (flashed at 0x0)"],
        [mc("magicmaker-heltec-v3-app.bin"), "Heltec V3 app image (Bluetooth update)"],
        [mc("magicmaker-esp32-app.bin"), "Classic app image (Bluetooth update)"],
        [mc("firmware.json"), "The version, and each image's size, MD5 and SHA-256"],
    ], [0.42, 0.58]))
    flat = []
    for x in S:
        flat.extend(x if isinstance(x, list) else [x])
    return flat


def _shrink(flowable, width):
    """Rescale a table built for the full frame width to fit `width`."""
    if isinstance(flowable, Table):
        total = sum(flowable._colWidths)
        flowable._colWidths = [w * width / total for w in flowable._colWidths]
        flowable._argW = list(flowable._colWidths)
        flowable.spaceBefore = 0
    return flowable


# --------------------------------------------------------------------------------------------
def build():
    """Build until the page count and the table of contents stop changing (two or three
    passes): the footer's "of N" and the contents page both come from the previous pass."""
    OUT.parent.mkdir(parents=True, exist_ok=True)
    total = None
    for _ in range(6):
        _KEYS["n"] = 0
        doc = GuideDoc(str(OUT), total_pages=total)
        doc.build(build_story())
        stable = doc.page == total and doc.toc_entries == PREV_TOC
        total = doc.page
        PREV_TOC[:] = doc.toc_entries
        if stable:
            break
    else:
        raise SystemExit("layout did not settle")
    print(f"wrote {OUT} ({total} pages)")


if __name__ == "__main__":
    build()
