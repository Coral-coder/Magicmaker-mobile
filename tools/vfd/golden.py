#!/usr/bin/env python3
"""Golden check of the VFD core: a deterministic list of draw calls and what the Python reference
(vfd.py, widgets.py, render_previews.draw_screen) makes of them. A port (Swift: ios/VFDCheck, later
Kotlin) replays golden/ops.txt with its own core and must reproduce golden/expected.txt line for
line.

    python3 tools/vfd/golden.py                 # write tools/vfd/golden/ops.txt + expected.txt
    python3 tools/vfd/golden.py --check         # exit 1 if the committed files are out of date
    python3 tools/vfd/golden.py --dump DIR      # readable per-page dumps (the golden files untouched)
    python3 tools/vfd/golden.py --out DIR       # write the two files somewhere else

Stdlib and the vfd modules only (no Pillow). The output is the same on every run and Python 3.9+.

File format (both files, UTF-8, LF line ends)
---------------------------------------------
One record per line, fields separated by one TAB. Lines starting with "#" and empty lines are
comments. Field encodings:

    int     decimal, may be negative ("-3")
    float   Python repr() of the float ("0.37", "1.0", "-0.5", "1e-05"); parse it as a double
    bool    "1" or "0"
    str     the text with these escapes: "\\\\" = backslash, "\\t" = TAB, "\\n" = line feed,
            "\\," = comma, "\\e" = nothing (marks an empty list element); any other "\\x" = x.
            Plain string fields never escape commas, but a reader must accept "\\,".
    None    a field that is exactly "\\N" (an optional value that is absent)
    list    elements joined by "," with "," inside an element written "\\,"; split on the commas
            that are not escaped, then decode each element as a str. An empty list is an empty
            field; an empty element is "\\e". In a list of optional numbers an element "\\N" is None.
    color   an ink index (int 0..4 or a true-colour index) or "#RRGGBB": the colour is then
            allocated with fb.rgb() when the op runs, and its index is used
    size    "small", "mid" or "big"
    hex     "#RRGGBB" (uppercase)
    sel     options() selection: "\\N" (none), "i:<int>" (an index), "s:<str>" (a name),
            "I:<list of ints>" or "S:<list of str>" (a set). The item at index i is selected when
            i is in the set, or the item's raw text or its upper() is in it.
    pick    buttons() primary/alarm: "\\N", "i:<int>" (an index) or "s:<str>" (a label; every
            button with that label)

ops.txt
    page <name> <device> <base>     starts a page: a new buffer for the device (pro | x2) drawn in
                                    the base colour (preset name or #RRGGBB), alarm_inverted from
                                    the base, and widgets.Layout(device)
    <op> <fields...>                one call (OPS below lists every op and its fields, in order;
                                    every field is always present, defaults written out)

  Blocks: "window_begin", the ops of a draw function, "window_end top bottom" runs
  widgets.snapped_window(fb, top, bottom, draw_fn) where draw_fn replays the ops on the probe
  buffer. "screen_begin ..." (always the first op of its page), the ops of a screen's draw(fb, L),
  "screen_end <ret>" runs render_previews.draw_screen() with that draw function (called twice: the
  probe pass and the real pass) and makes its buffer the page's buffer; <ret> is what draw()
  returns: "last" (the last int an op inside the block returned), "none", or an int. Ops inside a
  block record no return value; blocks do not nest.

expected.txt, per page in ops order:
    page <name> <device> <base>
    ret <line> <op> <value>         one per op outside blocks (and per block end), <line> = its
                                    1-based line number in ops.txt; "\\N" when it returns None.
                                    ints, strs and lists as above, tuples as lists, bools 1/0.
    colors <n> <list of #RRGGBB>    fb.true_colors after the last op
    hit <c> <r> <w> <h> <name>      every fb.taps entry (screen cells), in order (last = topmost)
    region <id> <c> <r> <w> <h> <content_rows>   every fb.scroll_regions entry, in order
    cells <fnv> <lit>               FNV-1a 64 of the cell bytes (row-major, one byte per cell) as
                                    16 lowercase hex digits, and the number of non-zero cells
    end <name>

  checkpoint returns [cells fnv, number of taps, taps fnv, number of true colours]; the taps fnv is
  FNV-1a 64 of the UTF-8 text made of one "<c> <r> <w> <h> <name>\\n" line per tap.
  state returns [origin_y, clip c, clip r, clip w, clip h, clip stack depth].
  layout returns the Layout fields in LAYOUT_FIELDS order.

--dump DIR writes DIR/NNN_<page>_<device>.txt (NNN = 1-based page number): the page's expected
lines, then "grid <cols> <rows>" and one line per buffer row: the row number in 3 digits, a space
and one character per cell: "." 0, "1".."4" the inks, true colours as letters, index 5 = "a" ...
30 = "z", 31 = "A" ... 56 = "Z", 57 = "a" again (cycling).
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import vfd                      # noqa: E402
import widgets as W             # noqa: E402
import render_previews as RP    # noqa: E402  (no Pillow needed for draw_screen)

from vfd import UNLIT, HIGHLIGHT, TEXT, DIM, ALARM   # noqa: E402

GOLDEN_DIR = os.path.join(HERE, "golden")

LAYOUT_FIELDS = ("cols", "rows", "safe_top", "safe_end", "left", "right", "width", "tap_rows",
                 "header_top", "title_row", "header_text_row", "telemetry_row", "header_rule",
                 "content_top", "tab_rows0", "tab_rows1", "tab_rule", "content_bottom", "content_h",
                 "tab_h", "tab_cell_w", "tab_left")

# The integer constants screens use directly, as the "constants" op returns them.
CONSTANTS = (("widgets", "MARGIN"), ("widgets", "CTRL_H"), ("widgets", "CTRL_TEXT"),
             ("widgets", "FIELD_H"), ("widgets", "GAP"), ("widgets", "LINE"), ("widgets", "LABEL_H"),
             ("widgets", "GROUP_GAP"), ("widgets", "SECTION_GAP"), ("widgets", "SECTION_H"),
             ("widgets", "TAP_ROWS"), ("widgets", "STEP_W"), ("widgets", "OPT_GAP"), ("widgets", "TAB_H"),
             ("widgets", "SWITCH_W"), ("widgets", "_ADV"), ("widgets", "N_PATTERNS"),
             ("widgets", "TAB_COLS"), ("widgets", "LOOP_LAST_STOP"), ("vfd", "LED_BAR_H"),
             ("vfd", "NUM_COLORS"), ("vfd", "FIRST_TRUE_COLOR"), ("vfd", "MAX_TRUE_COLORS"))

# ---------------------------------------------------------------------------------------------
# Op table: name -> field types (see the module docstring). "?" = optional (may be None).
# ---------------------------------------------------------------------------------------------

OPS = {
    # FrameBuffer
    "clear": "color",
    "set": "int int color",
    "get": "int int",
    "fill": "int int int int color",
    "hline": "int int int color int",                  # c r length color step
    "vline": "int int int color int",
    "box": "int int int int color",
    "text": "int int str size color",
    "text_right": "int int str size color",            # right_c r s size color
    "text_fit": "int int str int size color",          # c r s max_cols size color
    "paragraph": "int int str int size color int?",    # c r s max_cols size color line
    "inverted": "int int str size int color",          # c r s size pad color
    "alarm": "int int str size int",                   # c r s size pad
    "led_bar": "int int int float color color bool zone?",   # c r w frac color track marker zone
    "line_chart": "int int int int floats color float? float? color?",  # values color vmin vmax baseline
    "push_clip": "int int int int int",                # c r w h dy
    "pop_clip": "",
    "tap": "int int int int str",
    "hit": "int int",
    "scroll_region": "str int int int int int",        # id c r w h content_rows
    "scroll_region_at": "int int",
    "rgb": "hex",
    "rgb_fill": "int int int int hex",                 # fill(c, r, w, h, rgb(hex)); returns the index
    "state": "",
    "checkpoint": "",
    # text and palette helpers
    "text_width": "str size",
    "max_chars": "int size",
    "fit_text": "str int size",
    "wrap_text": "str int size",
    "round": "float",                                  # vfd._round
    "palette": "str",                                  # palette_for(base) as hex list
    "alarm_inverted": "str",
    "metrics": "size",                                 # [w, h, ascent, advance, line]
    # widgets
    "constants": "",                                   # CONSTANTS values, in order
    "group_top": "int",                                # widgets._group_top(L, r)
    "upper": "str",
    "cx": "int int str size",
    "wtap": "int int int int str? int",                # widgets._tap(c, r, w, h, name, min_h)
    "badge": "int int str color",
    "alarm_text": "int int str bool",                  # c r s right
    "tag_box": "int int str color color",              # c r s color text_color
    "chevron": "int int bool color",
    "chevron_up": "int int color",
    "step_button": "int int bool bool str?",           # c r plus enabled name
    "layout": "",
    "x": "float",
    "split": "int int int? int?",                      # n gap c w
    "tab_cell": "int",
    "tab_label": "str",
    "tab_key": "str",                                  # None when Python raises ValueError
    "header": "str bool str? color str?",              # title back right right_color right_tap
    "telemetry": "str",
    "tab_bar": "str",
    "frame": "str str str bool str? color int str?",   # tab title telemetry back right right_color scroll right_tap
    "end_frame": "",
    "scrollbar": "int int",                            # content_end scroll
    "section": "int int int str int? bool? str? str?",  # c r w title count collapsed right name
    "label": "int int int str color bool",             # c r w s color group
    "text_block": "int int int str color bool",        # c r w s color upper
    "status_line": "int int int str color bool str?",  # c r w s color banner name
    "kv": "int int int str str? color bool",           # c r w key value color leader
    "hero": "int int int str str size color str?",     # c r w key value size color sub
    "divider": "int int int bool color",               # c r w dotted color
    "panel_inner": "int int int bool",                 # c r w title
    "panel": "int int int int str? color",             # c r w h title color
    "toggle": "int int int str bool bool str? color",  # c r w label on enabled name label_color
    "options": "int int int strs sel? str? bool str? int?",  # items selected label_text enabled name columns
    "stepper": "int int int str str bool bool bool int? str?",  # label value enabled can_dec can_inc value_chars name
    "button": "int int int? str bool bool str? bool",  # c r w label primary enabled name alarm
    "buttons": "int int int strs pick? bools? int bool pick?",  # labels primary enabled gap equal alarm
    "slider": "int int int str str float str? bool zone? bool str? bool? bool?",
    # ^ title value_text frac hint enabled zone marker name can_dec can_inc
    "meter": "int int int str str float zone? bool color",  # title value_text frac zone marker color
    "field": "int int int str? str str bool str? color",  # label value placeholder focused name value_color
    "packet_row": "int int int str str str str? bool str? str? color",
    # ^ label hex subtitle tag selected right name hex_color
    "chart": "int int int int str? floats str? float? float? color",
    # ^ c r w h title values value_text vmin vmax color
    "list_scrollbar": "int int int int",               # top h total scroll
    "token_lines": "str int str",                      # text max_cols sep
    "interval_stop": "float",
    "interval_text": "float",
    "interval_slider": "int int int str float str",    # c r w label seconds name
    "menu_button": "int int str bool str?",            # x y label enabled name
    "led": "int int int? int color hex?",              # x y kind size color fill
    # blocks
    "window_begin": "",
    "window_end": "int int",
    "screen_begin": "str str str bool str? color str? int",
    # ^ tab title telemetry back right right_color right_tap scroll
    "screen_end": "str",
}

BLOCK_OPEN = {"window_begin": "window_end", "screen_begin": "screen_end"}

# ---------------------------------------------------------------------------------------------
# Encoding
# ---------------------------------------------------------------------------------------------

NONE = "\\N"


def esc(s):
    s = str(s)
    return s.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")


def esc_elem(s):
    s = esc(s).replace(",", "\\,")
    return s if s else "\\e"


def unesc(s):
    out, i, n = [], 0, len(s)
    while i < n:
        ch = s[i]
        if ch == "\\" and i + 1 < n:
            nx = s[i + 1]
            out.append({"n": "\n", "t": "\t", "e": ""}.get(nx, nx))
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def split_list(field):
    """Raw (still escaped) elements of a list field."""
    if field == "":
        return []
    parts, cur, i, n = [], [], 0, len(field)
    while i < n:
        ch = field[i]
        if ch == "\\" and i + 1 < n:
            cur.append(field[i:i + 2])
            i += 2
            continue
        if ch == ",":
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
        i += 1
    parts.append("".join(cur))
    return parts


def enc_list(items):
    return ",".join(esc_elem(x) for x in items)


def enc_float(x):
    return repr(float(x))


def enc_value(v):
    """Return values: None, bool, int, str, list/tuple of those."""
    if v is None:
        return NONE
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, (list, tuple)):
        return ",".join(NONE if x is None else esc_elem(enc_value(x) if not isinstance(x, str) else x)
                        for x in v)
    return esc(v)


def hex_rgb(rgb):
    return "#%02X%02X%02X" % tuple(rgb)


def enc_field(kind, v):
    opt = kind.endswith("?")
    k = kind.rstrip("?")
    if v is None:
        if not opt:
            raise ValueError("field %s may not be None" % kind)
        return NONE
    if k == "int":
        if isinstance(v, bool) or not isinstance(v, int):
            raise ValueError("int field got %r" % (v,))
        return str(v)
    if k == "float":
        return enc_float(v)
    if k == "bool":
        return "1" if v else "0"
    if k == "str":
        return esc(v)
    if k == "size":
        if v not in ("small", "mid", "big"):
            raise ValueError("size %r" % (v,))
        return v
    if k == "color":
        if isinstance(v, tuple):
            return hex_rgb(v)
        if isinstance(v, str):
            if not v.startswith("#") or len(v) != 7:
                raise ValueError("color %r" % (v,))
            return v.upper()
        return str(int(v))
    if k == "hex":
        return hex_rgb(v) if isinstance(v, tuple) else v.upper()
    if k == "strs":
        return enc_list(v)
    if k == "floats":
        return ",".join(NONE if x is None else enc_float(x) for x in v)
    if k == "bools":
        return ",".join("1" if x else "0" for x in v)
    if k == "zone":
        return ",".join(enc_float(x) for x in v)
    if k == "sel":
        if isinstance(v, int):
            return "i:%d" % v
        if isinstance(v, str):
            return "s:" + esc(v)
        v = sorted(v, key=lambda x: (isinstance(x, str), x))     # sets: a stable order
        if all(isinstance(x, int) for x in v):
            return "I:" + ",".join(str(x) for x in v)
        if all(isinstance(x, str) for x in v):
            return "S:" + enc_list(v)
        raise ValueError("mixed selection %r" % (v,))
    if k == "pick":
        if isinstance(v, int):
            return "i:%d" % v
        return "s:" + esc(v)
    raise ValueError("unknown field kind %r" % kind)


def dec_field(kind, f, fb=None):
    opt = kind.endswith("?")
    k = kind.rstrip("?")
    if opt and f == NONE:
        return None
    if k == "int":
        return int(f)
    if k == "float":
        return float(f)
    if k == "bool":
        return f == "1"
    if k in ("str", "size"):
        return unesc(f)
    if k == "color":
        if f.startswith("#"):
            return fb.rgb(f)
        return int(f)
    if k == "hex":
        v = int(f[1:], 16)
        return ((v >> 16) & 255, (v >> 8) & 255, v & 255)
    if k == "strs":
        return [unesc(x) for x in split_list(f)]
    if k == "floats":
        return [None if x == NONE else float(x) for x in split_list(f)]
    if k == "bools":
        return [x == "1" for x in split_list(f)]
    if k == "zone":
        lo, hi = (float(x) for x in split_list(f))
        return (lo, hi)
    if k in ("sel", "pick"):
        if f == NONE:
            return None
        tag, rest = f[:2], f[2:]
        if tag == "i:":
            return int(rest)
        if tag == "s:":
            return unesc(rest)
        if tag == "I:":
            return set(int(x) for x in split_list(rest))
        if tag == "S:":
            return set(unesc(x) for x in split_list(rest))
    raise ValueError("cannot decode %s field %r" % (kind, f))


def fnv1a64(data):
    h = 0xCBF29CE484222325
    for b in data:
        h ^= b
        h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return "%016x" % h


def taps_text(fb):
    return "".join("%d %d %d %d %s\n" % tp for tp in fb.taps)


# ---------------------------------------------------------------------------------------------
# Executor: runs ops.txt lines against the Python reference
# ---------------------------------------------------------------------------------------------

class Page:
    def __init__(self, name, device_key, base):
        self.name = name
        self.device_key = device_key
        self.device = vfd.DEVICES[device_key]
        self.base = base
        self.fb = self.device.framebuffer(base)
        self.L = W.Layout(self.device)


def _layout_values(L):
    out = []
    for f in LAYOUT_FIELDS:
        if f == "tab_rows0":
            out.append(L.tab_rows[0])
        elif f == "tab_rows1":
            out.append(L.tab_rows[1])
        else:
            out.append(getattr(L, f))
    return out


def run_op(page, fb, op, args):
    """Execute one op on fb (the page buffer or a block's probe). Returns the op's return value."""
    L = page.L
    a = args
    if op == "clear":
        fb.clear(a[0])
    elif op == "set":
        fb.set(*a)
    elif op == "get":
        return fb.get(*a)
    elif op == "fill":
        fb.fill(*a)
    elif op == "hline":
        fb.hline(a[0], a[1], a[2], a[3], step=a[4])
    elif op == "vline":
        fb.vline(a[0], a[1], a[2], a[3], step=a[4])
    elif op == "box":
        fb.box(*a)
    elif op == "text":
        return fb.text(*a)
    elif op == "text_right":
        return fb.text_right(*a)
    elif op == "text_fit":
        return fb.text_fit(*a)
    elif op == "paragraph":
        return fb.paragraph(*a)
    elif op == "inverted":
        return fb.inverted(*a)
    elif op == "alarm":
        return fb.alarm(*a)
    elif op == "led_bar":
        return fb.led_bar(a[0], a[1], a[2], a[3], color=a[4], track=a[5], marker=a[6], zone=a[7])
    elif op == "line_chart":
        return fb.line_chart(a[0], a[1], a[2], a[3], a[4], color=a[5], vmin=a[6], vmax=a[7],
                             baseline=a[8])
    elif op == "push_clip":
        fb.push_clip(*a)
    elif op == "pop_clip":
        fb.pop_clip()
    elif op == "tap":
        fb.tap(*a)
    elif op == "hit":
        return fb.hit(*a)
    elif op == "scroll_region":
        fb.scroll_region(*a)
    elif op == "scroll_region_at":
        return fb.scroll_region_at(*a)
    elif op == "rgb":
        return fb.rgb(a[0])
    elif op == "rgb_fill":
        idx = fb.rgb(a[4])
        fb.fill(a[0], a[1], a[2], a[3], idx)
        return idx
    elif op == "state":
        c, r, w, h = fb.clip_rect
        return [fb.origin_y, c, r, w, h, len(fb._stack)]
    elif op == "checkpoint":
        return [fnv1a64(fb.cells), len(fb.taps), fnv1a64(taps_text(fb).encode("utf-8")),
                len(fb.true_colors)]
    elif op == "text_width":
        return vfd.text_width(*a)
    elif op == "max_chars":
        return vfd.max_chars(*a)
    elif op == "fit_text":
        return vfd.fit_text(*a)
    elif op == "wrap_text":
        return vfd.wrap_text(*a)
    elif op == "round":
        return vfd._round(a[0])
    elif op == "palette":
        return [hex_rgb(c) for c in vfd.palette_for(a[0])]
    elif op == "alarm_inverted":
        return vfd.alarm_inverted(a[0])
    elif op == "metrics":
        m = vfd.metrics(a[0])
        return [m["w"], m["h"], m["ascent"], m["advance"], m["line"]]
    elif op == "constants":
        mods = {"widgets": W, "vfd": vfd}
        return [getattr(mods[mod], name) for mod, name in CONSTANTS] + [len(W.TABS)]
    elif op == "group_top":
        return W._group_top(L, a[0])
    elif op == "upper":
        return W.upper(a[0])
    elif op == "cx":
        return W.cx(*a)
    elif op == "wtap":
        W.tap(fb, a[0], a[1], a[2], a[3], a[4], min_h=a[5])
    elif op == "badge":
        return W.badge(fb, *a)
    elif op == "alarm_text":
        return W.alarm_text(fb, a[0], a[1], a[2], right=a[3])
    elif op == "tag_box":
        return W.tag_box(fb, a[0], a[1], a[2], color=a[3], text_color=a[4])
    elif op == "chevron":
        W.chevron(fb, *a)
    elif op == "chevron_up":
        W.chevron_up(fb, *a)
    elif op == "step_button":
        W.step_button(fb, a[0], a[1], a[2], enabled=a[3], name=a[4])
    elif op == "layout":
        return _layout_values(L)
    elif op == "x":
        return L.x(a[0])
    elif op == "split":
        out = []
        for cc, ww in L.split(a[0], gap=a[1], c=a[2], w=a[3]):
            out += [cc, ww]
        return out
    elif op == "tab_cell":
        return list(L.tab_cell(a[0]))
    elif op == "tab_label":
        return L.tab_label(a[0])
    elif op == "tab_key":
        try:
            return W.tab_key(a[0])
        except ValueError:
            return None
    elif op == "header":
        right = (a[2], a[3]) if a[2] else None
        return W.header(fb, L, a[0], back=a[1], right=right, right_tap=a[4])
    elif op == "telemetry":
        return W.telemetry(fb, L, a[0])
    elif op == "tab_bar":
        W.tab_bar(fb, L, a[0])
    elif op == "frame":
        right = (a[4], a[5]) if a[4] else None
        W.frame(fb, L, a[0], a[1], a[2], back=a[3], right=right, scroll=a[6], right_tap=a[7])
    elif op == "end_frame":
        W.end_frame(fb)
    elif op == "scrollbar":
        W.scrollbar(fb, L, a[0], a[1])
    elif op == "section":
        return W.section(fb, L, a[0], a[1], a[2], a[3], count=a[4], collapsed=a[5], right=a[6],
                         name=a[7])
    elif op == "label":
        return W.label(fb, L, a[0], a[1], a[2], a[3], color=a[4], group=a[5])
    elif op == "text_block":
        return W.text_block(fb, L, a[0], a[1], a[2], a[3], color=a[4], upper=a[5])
    elif op == "status_line":
        return W.status_line(fb, L, a[0], a[1], a[2], a[3], color=a[4], banner=a[5], name=a[6])
    elif op == "kv":
        return W.kv(fb, L, a[0], a[1], a[2], a[3], a[4], color=a[5], leader=a[6])
    elif op == "hero":
        return W.hero(fb, L, a[0], a[1], a[2], a[3], a[4], size=a[5], color=a[6], sub=a[7])
    elif op == "divider":
        return W.divider(fb, L, a[0], a[1], a[2], dotted=a[3], color=a[4])
    elif op == "panel_inner":
        return list(W.panel_inner(a[0], a[1], a[2], title=a[3]))
    elif op == "panel":
        return W.panel(fb, L, a[0], a[1], a[2], a[3], title=a[4], color=a[5])
    elif op == "toggle":
        return W.toggle(fb, L, a[0], a[1], a[2], a[3], a[4], enabled=a[5], name=a[6],
                        label_color=a[7])
    elif op == "options":
        return W.options(fb, L, a[0], a[1], a[2], a[3], a[4], label_text=a[5], enabled=a[6],
                         name=a[7], columns=a[8])
    elif op == "stepper":
        return W.stepper(fb, L, a[0], a[1], a[2], a[3], a[4], enabled=a[5], can_dec=a[6],
                         can_inc=a[7], value_chars=a[8], name=a[9])
    elif op == "button":
        return W.button(fb, L, a[0], a[1], a[2], a[3], primary=a[4], enabled=a[5], name=a[6],
                        alarm=a[7])
    elif op == "buttons":
        return W.buttons(fb, L, a[0], a[1], a[2], a[3], primary=a[4], enabled=a[5], gap=a[6],
                         equal=a[7], alarm=a[8])
    elif op == "slider":
        return W.slider(fb, L, a[0], a[1], a[2], a[3], a[4], a[5], hint=a[6], enabled=a[7],
                        zone=a[8], marker=a[9], name=a[10], can_dec=a[11], can_inc=a[12])
    elif op == "meter":
        return W.meter(fb, L, a[0], a[1], a[2], a[3], a[4], a[5], zone=a[6], marker=a[7],
                       color=a[8])
    elif op == "field":
        return W.field(fb, L, a[0], a[1], a[2], a[3], a[4], placeholder=a[5], focused=a[6],
                       name=a[7], value_color=a[8])
    elif op == "packet_row":
        return W.packet_row(fb, L, a[0], a[1], a[2], a[3], a[4], subtitle=a[5], tag=a[6],
                            selected=a[7], right=a[8], name=a[9], hex_color=a[10])
    elif op == "chart":
        return W.chart(fb, L, a[0], a[1], a[2], a[3], a[4], a[5], value_text=a[6], vmin=a[7],
                       vmax=a[8], color=a[9])
    elif op == "list_scrollbar":
        W.list_scrollbar(fb, *a)
    elif op == "token_lines":
        return W.token_lines(a[0], a[1], sep=a[2])
    elif op == "interval_stop":
        return W.interval_stop(a[0])
    elif op == "interval_text":
        return W.interval_text(a[0])
    elif op == "interval_slider":
        return W.interval_slider(fb, L, a[0], a[1], a[2], a[3], a[4], name=a[5])
    elif op == "menu_button":
        return W.menu_button(fb, L, a[0], a[1], a[2], enabled=a[3], name=a[4])
    elif op == "led":
        W.led(fb, a[0], a[1], a[2], a[3], color=a[4], fill=a[5])
    else:
        raise ValueError("unknown op %r" % op)
    return None


def parse_line(line):
    fields = line.split("\t")
    op = fields[0]
    if op not in OPS:
        raise ValueError("unknown op %r" % op)
    kinds = OPS[op].split()
    if len(fields) - 1 != len(kinds):
        raise ValueError("%s: %d fields, want %d" % (op, len(fields) - 1, len(kinds)))
    return op, kinds, fields[1:]


def decode_args(kinds, raw, fb):
    return [dec_field(k, f, fb) for k, f in zip(kinds, raw)]


def replay(page, fb, block):
    """Run a block's ops on fb; returns the last int an op returned (or None)."""
    last = None
    for _, op, kinds, raw in block:
        v = run_op(page, fb, op, decode_args(kinds, raw, fb))
        if isinstance(v, int) and not isinstance(v, bool):
            last = v
    return last


class _ScreenModule:
    """The minimal screen module render_previews.draw_screen() needs."""

    def __init__(self, page, block, tab, title, telemetry, back, right, right_tap, ret):
        self._page, self._block, self._ret = page, block, ret
        self._tab_key = W.tab_key(tab)
        self.TITLE = title
        self.TELEMETRY = telemetry
        self.BACK = back
        self.HEADER_RIGHT = right
        self.HEADER_RIGHT_TAP = right_tap

    def draw(self, fb, L):
        last = replay(self._page, fb, self._block)
        if self._ret == "last":
            return last
        if self._ret == "none":
            return None
        return int(self._ret)


def execute(lines):
    """Run ops lines (no trailing newlines). Returns (expected lines, pages) where pages is a list
    of (Page, its expected lines) for dumps."""
    out = []
    pages = []
    page = None
    page_lines = []
    block = None            # (open op, args, ops) while inside a block
    started = False

    def finish():
        if page is None:
            return
        fb = page.fb
        tail = ["colors\t%d\t%s" % (len(fb.true_colors), enc_list(hex_rgb(c) for c in fb.true_colors))]
        for c, r, w, h, name in fb.taps:
            tail.append("hit\t%d\t%d\t%d\t%d\t%s" % (c, r, w, h, esc(name)))
        for rid, c, r, w, h, rows in fb.scroll_regions:
            tail.append("region\t%s\t%d\t%d\t%d\t%d\t%d" % (esc(rid), c, r, w, h, rows))
        tail.append("cells\t%s\t%d" % (fnv1a64(fb.cells), len(fb.cells) - fb.cells.count(0)))
        tail.append("end\t%s" % esc(page.name))
        page_lines.extend(tail)
        out.extend(page_lines)
        pages.append((page, list(page_lines)))

    for no, line in enumerate(lines, 1):
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if fields[0] == "page":
            if block is not None:
                raise ValueError("line %d: page inside a block" % no)
            finish()
            page = Page(unesc(fields[1]), fields[2], unesc(fields[3]))
            page_lines = ["page\t%s\t%s\t%s" % (fields[1], fields[2], fields[3])]
            started = False
            continue
        if page is None:
            raise ValueError("line %d: op before the first page" % no)
        op, kinds, raw = parse_line(line)
        if block is not None:
            if op == BLOCK_OPEN[block[0]]:
                opener, oargs, ops = block
                block = None
                if op == "window_end":
                    top, bottom = int(raw[0]), int(raw[1])
                    t, b = W.snapped_window(page.fb, top, bottom,
                                            lambda target, ops=ops: replay(page, target, ops))
                    value = [t, b]
                else:
                    tab, title, tele, back, right, rcol, rtap, scroll = oargs
                    rspec = unesc(raw[0])
                    right_v = (right, rcol) if right else None
                    mod = _ScreenModule(page, ops, tab, title, tele, back, right_v, rtap, rspec)
                    fb, _, end = RP.draw_screen(mod, page.device, page.base, scroll)
                    page.fb = fb
                    value = end
                page_lines.append("ret\t%d\t%s\t%s" % (no, op, enc_value(value)))
            elif op in BLOCK_OPEN or op in BLOCK_OPEN.values():
                raise ValueError("line %d: blocks do not nest" % no)
            else:
                block[2].append((no, op, kinds, raw))
            continue
        if op in BLOCK_OPEN:
            if op == "screen_begin":
                if started:
                    raise ValueError("line %d: screen_begin must be the first op of its page" % no)
                # colours in screen_begin fields are inks only (no fb.rgb before the screen)
                oargs = [dec_field(k, f, None) if k != "color" else int(f) for k, f in zip(kinds, raw)]
            else:
                oargs = []
            block = (op, oargs, [])
            started = True
            continue
        if op in BLOCK_OPEN.values():
            raise ValueError("line %d: %s without its opener" % (no, op))
        started = True
        value = run_op(page, page.fb, op, decode_args(kinds, raw, page.fb))
        page_lines.append("ret\t%d\t%s\t%s" % (no, op, enc_value(value)))
    if block is not None:
        raise ValueError("unterminated block at the end of ops")
    finish()
    return out, pages


# ---------------------------------------------------------------------------------------------
# Generator: the ops, page by page
# ---------------------------------------------------------------------------------------------

DEFAULT_TELEMETRY = RP.DEFAULT_TELEMETRY
DEVICE_KEYS = ("pro", "x2")


class Gen:
    def __init__(self):
        self.lines = []
        self.L = None
        self.dev = None

    def page(self, name, device_key, base="AMBER"):
        self.dev = vfd.DEVICES[device_key]
        self.L = W.Layout(self.dev)
        self.lines.append("page\t%s\t%s\t%s" % (esc(name), device_key, esc(base)))

    def op(self, name, *args):
        kinds = OPS[name].split()
        if len(args) != len(kinds):
            raise ValueError("%s: %d args, want %d" % (name, len(args), len(kinds)))
        if name == "buttons":
            # the ports take one index for primary / alarm: a label must name one button
            for pick in (args[4], args[8]):
                if isinstance(pick, str) and list(args[3]).count(pick) != 1:
                    raise ValueError("buttons: label %r must match exactly one button" % (pick,))
        self.lines.append("\t".join([name] + [enc_field(k, v) for k, v in zip(kinds, args)]))

    def comment(self, s):
        self.lines.append("# " + s)


# Realistic content (labels and hex as the screens use them)
HEX_LIVE = "8301CC03000100E100E911006F0F554258F44882D1460208D06500B3"
HEX_BAND = "CC03000000E9050E11E1E1E1E1E1E1"
HEX_SHORT = "E10E0F"
WRAP_SAMPLES = [
    "Word wrap on spaces; SUPERCALIFRAGILISTICEXPIALIDOCIOUS words hard-break. Units go in the label row.\nNew line.",
    "Tap a row to send · hold for the menu · swipe left to delete · swipe right to edit",
    "Each wake/command slice in the 1:1 interleave · default 30ms",
    "Interleave alternates the wake and the command — sustained sends the command only",
    "A very long sentence – with an en dash – that keeps going until it wraps more than once",
    "No\u00a0break\u00a0here, but here we break and here we break again",
    "  leading  and   repeated   spaces  ",
    "first\n\nthird after a blank line\n",
    "· starts with a dot · then more · and a trailing dot ·",
    "ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    "x · — · y",
    "word —",
    "µ° Δ±·×÷ →← …✓²³Ω ≤≥≈ ‘’“” lower case: gjpqy",
]
FIT_SAMPLES = ["CA:FE:BA:BE 7F3A9C21 LONG HEX PAYLOAD", "SHORT", "", "TRAILING SPACES      CUT",
               "ÄÖÜ é ß µ € 漢字 😀", "A\u00a0\u00a0\u00a0\u00a0B"]
UPPER_SAMPLES = ["scan", "Cross-Fade: Red / Blue", "µs burst", "straße", "café élan", "ǆ ǅ",
                 "Mixed 123 äöü", "", "already UPPER"]
BASES = ["AMBER", "GREEN", "CYAN", "BLUE", "RED", "WHITE", "amber", "#FFB014", "#FF8800",
         "#808080", "#000000", "#FFFFFF", "#FF0000", "#FF0030", "#FF0040", "#FF00FF", "#123456",
         "#3CFF6E", " cyan ", "#ff5028", "#7F7F80"]


def g_primitives(g):
    L, dev = g.L, g.dev
    cols, rows = dev.cols, dev.rows
    g.op("state")
    g.op("fill", 0, 0, 5, 5, HIGHLIGHT)
    g.op("fill", -3, 10, 8, 3, TEXT)                 # off the left edge
    g.op("fill", cols - 4, 10, 10, 3, DIM)           # off the right edge
    g.op("fill", 20, -2, 4, 5, ALARM)                # off the top
    g.op("fill", 30, rows - 2, 4, 6, HIGHLIGHT)      # off the bottom
    g.op("fill", 40, 20, 0, 5, HIGHLIGHT)            # empty
    g.op("fill", 40, 20, -4, 5, HIGHLIGHT)           # negative width
    g.op("fill", -50, -50, cols + 100, 2, DIM)       # wholly outside
    g.op("set", 1, 30, TEXT)
    g.op("set", -1, 30, TEXT)
    g.op("set", cols, 30, TEXT)
    g.op("set", 3, rows, TEXT)
    for i, step in enumerate((1, 2, 3, 4, 7)):
        g.op("hline", 3, 40 + i * 2, 60, DIM if i % 2 else HIGHLIGHT, step)
        g.op("vline", 80 + i * 2, 40, 30, TEXT, step)
    g.op("hline", -5, 52, 12, ALARM, 2)
    g.op("hline", cols - 7, 54, 12, ALARM, 3)
    g.op("vline", 100, -6, 12, ALARM, 2)
    g.op("hline", 3, 56, 0, HIGHLIGHT, 1)
    g.op("hline", 3, 57, -5, HIGHLIGHT, 2)
    g.op("box", 3, 80, 40, 20, HIGHLIGHT)
    g.op("box", 5, 82, 36, 16, DIM)
    g.op("box", 50, 80, 1, 1, HIGHLIGHT)
    g.op("box", 52, 80, 2, 2, TEXT)
    g.op("box", 56, 80, 0, 5, TEXT)
    g.op("box", 56, 80, 5, -1, TEXT)
    g.op("box", -10, 90, 20, 10, ALARM)
    g.op("box", cols - 8, rows - 6, 20, 20, ALARM)
    for i in range(8):
        for j in range(8):
            if (i + j) % 2 == 0:
                g.op("set", 70 + i, 80 + j, TEXT)
    for pc, pr in ((0, 0), (4, 4), (5, 5), (-1, 0), (cols, 0), (0, rows), (cols - 1, 10), (1, 30),
                   (70, 80), (71, 80), (3, 40)):
        g.op("get", pc, pr)
    g.op("checkpoint")
    g.op("clear", DIM)
    g.op("checkpoint")
    g.op("clear", UNLIT)
    g.op("fill", 10, 10, 3, 3, TEXT)
    g.op("tap", 0, 0, 10, 10, "gone after clear")
    g.op("clear", UNLIT)
    g.op("fill", 12, 12, 3, 3, HIGHLIGHT)
    g.op("checkpoint")


def g_text(g):
    L = g.L
    c = L.left
    y = L.safe_top + 2
    g.op("text", c, y, "SMALL 5X7 Agjpqy 0123", "small", TEXT)
    g.op("text", c, y + 11, "°µΔ±·×÷–—→←…✓²³Ω≤≥≈‘’“”", "small", HIGHLIGHT)
    g.op("text", c, y + 22, "unknown: €漢😀\u00a0nbsp|tab\tend", "small", DIM)
    g.op("text", c, y + 33, "MID Agjy 42", "mid", TEXT)
    g.op("text", c, y + 53, "1284 big", "big", HIGHLIGHT)
    g.op("text", -8, y + 84, "OFF THE LEFT EDGE", "small", TEXT)
    g.op("text", L.right - 20, y + 84, "OFF THE RIGHT", "mid", TEXT)
    g.op("text", c, -3, "TOP EDGE gjpq", "small", ALARM)
    g.op("text", c, g.dev.rows - 5, "BOTTOM EDGE gjpq", "small", ALARM)
    g.op("text", c, y + 100, "", "small", TEXT)
    g.op("text_right", L.right, y + 100, "RIGHT ALIGNED", "small", DIM)
    g.op("text_right", L.right, y + 112, "-3.5", "big", ALARM)
    g.op("text_right", L.right, y + 141, "", "mid", ALARM)
    yy = y + 145
    for i, n in enumerate((60, 35, 11, 6, 5, 4, 0, -3)):
        g.op("text_fit", c, yy + i * 11, FIT_SAMPLES[0], n, "small", TEXT)
    yy += 8 * 11
    for i, s in enumerate(FIT_SAMPLES[1:]):
        g.op("text_fit", c, yy + i * 11, s, 50, "small", TEXT)
    yy += 5 * 11
    g.op("text_fit", c, yy, "TRUNCATED MID TITLE THAT IS LONG", L.width // 2, "mid", HIGHLIGHT)
    g.op("text_fit", c, yy + 20, "BIG READOUT 123456", L.width // 2, "big", TEXT)
    g.op("text_fit", c, yy + 50, "EXACT", vfd.text_width("EXACT"), "small", TEXT)
    g.op("text_fit", c, yy + 61, "EXACT", vfd.text_width("EXACT") - 1, "small", TEXT)
    g.op("checkpoint")
    g.op("clear", UNLIT)
    y = L.safe_top + 2
    for i, s in enumerate(WRAP_SAMPLES[:6]):
        g.op("paragraph", c, y, s, 140 - i * 9, "small", TEXT if i % 2 else DIM, None)
        y += 70
    g.op("paragraph", c, y, WRAP_SAMPLES[1], 90, "mid", TEXT, 22)
    g.op("paragraph", c, y + 120, "", 90, "small", TEXT, None)
    g.op("paragraph", c, y + 120, "no room", 3, "small", TEXT, None)
    g.op("paragraph", c, y + 120, "zero pitch overdraw", 40, "small", TEXT, 0)
    g.op("checkpoint")
    g.op("clear", UNLIT)
    y = L.safe_top + 4
    x = 1
    for i, tab in enumerate(("SCAN", "TX", "WAND", "AUTO")):
        g.op("inverted", x, y, tab, "small", 1, HIGHLIGHT if i % 2 else TEXT)
        x += 30
    g.op("inverted", 0, y + 14, "LEFT MARGIN", "small", 1, HIGHLIGHT)
    g.op("inverted", 0, y + 28, "PAD2", "mid", 2, HIGHLIGHT)
    g.op("inverted", 60, y + 28, "Gj", "mid", 0, TEXT)
    g.op("inverted", 100, y + 28, "42", "big", 3, DIM)
    g.op("inverted", 150, y + 28, "", "small", 1, HIGHLIGHT)
    g.op("inverted", L.right - 10, y + 60, "CUT AT RIGHT", "small", 1, HIGHLIGHT)
    g.op("alarm", 3, y + 80, "RSSI LOW", "small", 1)
    g.op("alarm", 3, y + 92, "MID ALARM", "mid", 2)
    g.op("alarm", 3, y + 116, "", "small", 1)
    g.op("alarm", 0, y + 130, "AT EDGE", "small", 1)
    g.op("checkpoint")


def g_indicators(g):
    L = g.L
    c, w = L.left, L.width
    y = L.safe_top + 2
    bw = w - 40
    cases = [(0.0, False, None, HIGHLIGHT, DIM), (0.37, False, None, HIGHLIGHT, DIM),
             (1.0, False, None, TEXT, DIM), (-0.5, False, None, HIGHLIGHT, DIM),
             (1.5, False, None, HIGHLIGHT, DIM), (0.5, False, (0.2, 0.4), HIGHLIGHT, DIM),
             (0.0, True, None, HIGHLIGHT, DIM), (0.5, True, None, HIGHLIGHT, TEXT),
             (1.0, True, (0.6, 0.85), HIGHLIGHT, DIM), (0.7, True, (0.55, 0.8), ALARM, DIM),
             (0.3, True, (0.8, 0.2), HIGHLIGHT, DIM), (0.25, True, (0.0, 0.25), HIGHLIGHT, DIM),
             (0.123456789, False, (-1.0, 2.0), HIGHLIGHT, HIGHLIGHT), (0.999, True, None, TEXT, DIM)]
    for frac, marker, zone, col, track in cases:
        g.op("led_bar", c + 40, y, bw, frac, col, track, marker, zone)
        y += 8
    for wd in (0, 1, 2, 3, 4):
        g.op("led_bar", c + 40 + wd * 10, y, wd, 0.5, HIGHLIGHT, DIM, True, None)
        g.op("led_bar", c + 100 + wd * 10, y, wd, 0.5, HIGHLIGHT, DIM, False, (0.1, 0.9))
    y += 10
    g.op("led_bar", -6, y, 30, 0.5, HIGHLIGHT, DIM, True, None)
    g.op("led_bar", L.right - 10, y, 30, 0.9, HIGHLIGHT, DIM, True, None)
    y += 10
    import math
    cw = w // 2 - 3
    wave = [round(math.sin(i / 7.0) * (1 + i / 60.0), 6) for i in range(cw)]
    g.op("box", c, y, cw, 40, DIM)
    g.op("line_chart", c + 1, y + 1, cw - 2, 38, wave, HIGHLIGHT, None, None, DIM)
    steps = [0, 0, 10, 10, 2, 9, 1, 1, 8, 8, 8, 0, 5, None, None, 6, 7, 3, 3, 10]
    g.op("line_chart", c + cw + 6, y, cw, 40, steps, TEXT, None, None, DIM)
    y += 44
    g.op("line_chart", c, y, 60, 20, [3, 3, 3, 3], HIGHLIGHT, None, None, DIM)
    g.op("line_chart", c + 64, y, 60, 20, [None, None], HIGHLIGHT, None, None, DIM)
    g.op("line_chart", c + 128, y, 60, 20, [], HIGHLIGHT, None, None, None)
    y += 24
    g.op("line_chart", c, y, 60, 20, [5.0], HIGHLIGHT, None, None, DIM)
    g.op("line_chart", c + 64, y, 60, 20, [0, 10, 0, 10, 0, 10, 0, 10, 0, 10], ALARM, 2.0, 8.0, DIM)
    g.op("line_chart", c + 128, y, 30, 20, [-5, 5, -2.5, 7.25, None, 1], HIGHLIGHT, -10.0, None, None)
    y += 24
    g.op("line_chart", c, y, 1, 20, [1, 2, 3], HIGHLIGHT, None, None, DIM)
    g.op("line_chart", c + 4, y, 40, 1, [1, 2, 3], HIGHLIGHT, None, None, DIM)
    g.op("line_chart", c + 48, y, 40, 0, [1, 2, 3], HIGHLIGHT, None, None, DIM)
    g.op("line_chart", c + 92, y, 0, 20, [1, 2, 3], HIGHLIGHT, None, None, DIM)
    g.op("line_chart", c + 96, y, 7, 20, list(range(40)), HIGHLIGHT, None, None, DIM)
    g.op("line_chart", c + 106, y, 50, 20, [1, None, 3, 4, None, None, 2, 9, 0], TEXT, None, None, DIM)
    g.op("line_chart", c + 160, y, 30, 20, [10, 0, 10], HIGHLIGHT, 10.0, 10.0, DIM)
    g.op("checkpoint")


def g_clip(g):
    L, dev = g.L, g.dev
    c, w = L.left, L.width
    y = L.safe_top + 4
    g.op("push_clip", 0, dev.safe_top, dev.cols, dev.rows - dev.safe_top - dev.safe_bottom, 0)
    g.op("state")
    g.op("box", c, y, w, 34, DIM)
    g.op("push_clip", c + 1, y + 1, w - 2, 32, -5)
    g.op("state")
    for i in range(8):
        g.op("text", c + 2, y + 2 + i * 11, "SCROLLED ROW %d" % i, "small", TEXT if i % 2 else HIGHLIGHT)
    g.op("fill", c - 10, y - 10, 8, 200, ALARM)
    g.op("tap", c + 1, y + 1, w - 2, 300, "list")
    g.op("tap", c + 1, y - 40, 20, 10, "above: dropped")
    g.op("scroll_region", "inner list", c + 1, y - 20, w - 2, 200, 640)
    g.op("push_clip", c + 30, y + 10, 40, 50, 3)       # nested, dy accumulates
    g.op("state")
    g.op("fill", c, y, w, 60, TEXT)
    g.op("tap", c, y, w, 60, "nested")
    g.op("pop_clip")
    g.op("pop_clip")
    g.op("state")
    g.op("text", c + w // 2, y + 2, "CLIP+DY", "mid", DIM)
    y += 40
    g.op("push_clip", c, y, 30, 0, 0)                 # empty clip: nothing lands
    g.op("fill", c, y, 30, 10, ALARM)
    g.op("tap", c, y, 30, 10, "empty clip")
    g.op("scroll_region", "empty", c, y, 30, 10, 99)
    g.op("state")
    g.op("pop_clip")
    g.op("push_clip", -20, y, 40, 20, 12)             # starts left of the screen
    g.op("fill", -20, y - 12, 40, 30, HIGHLIGHT)
    g.op("tap", -20, y - 12, 40, 30, "left clipped")
    g.op("pop_clip")
    y += 24
    g.op("tap", 0, 0, dev.cols, dev.rows, "screen")
    g.op("tap", c, y, 40, 15, "a")
    g.op("tap", c + 20, y + 5, 40, 15, "b on top")
    g.op("scroll_region", "outer", 0, y, dev.cols, 100, 300)
    g.op("scroll_region", "inner", c + 10, y + 10, 50, 30, 90)
    for pc, pr in ((c, y), (c + 25, y + 6), (c + 59, y + 19), (c + 60, y + 19), (0, 0), (-1, 5),
                   (dev.cols - 1, dev.rows - 1), (c + 10, y + 10), (c + 60, y + 40), (c + 9, y + 9),
                   (c + 1, L.safe_top + 6)):
        g.op("hit", pc, pr)
        g.op("scroll_region_at", pc, pr)
    g.op("pop_clip")
    g.op("state")
    g.op("checkpoint")


def g_true_colors(g):
    L = g.L
    c = L.left
    y = L.safe_top + 4
    g.op("rgb", (255, 0, 0))
    g.op("rgb", (255, 0, 0))
    g.op("rgb", (0, 0, 255))
    g.op("rgb_fill", c, y, 7, 7, (255, 0, 0))
    g.op("rgb_fill", c + 9, y, 7, 7, (0, 255, 64))
    g.op("rgb_fill", c + 18, y, 5, 5, (0xFF, 0xB0, 0x14))        # amber as a true colour
    g.op("fill", c + 27, y, 5, 5, (12, 34, 56))                    # colour field as #RRGGBB
    g.op("hline", c, y + 9, 40, (255, 255, 255), 2)
    g.op("led_bar", c, y + 12, 60, 0.4, (10, 200, 30), DIM, False, None)
    g.op("text", c + 70, y, "RED", "small", TEXT)
    for i, kind in enumerate((0, 1, 2, 3, 4, None, 5, 0)):
        g.op("led", c + i * 10, y + 22, kind, 7, HIGHLIGHT, None)
    rgbs = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0), None, (128, 0, 128), (1, 2, 3)]
    for i, fill in enumerate(rgbs):
        g.op("led", c + i * 12, y + 32, 0 if i != 4 else None, 9, HIGHLIGHT, fill or (9, 9, 9))
    g.op("led", c + 100, y + 32, None, 11, HIGHLIGHT, (255, 0, 0))   # unlit: the ring, no colour
    g.op("led", c + 114, y + 32, 0, 0, HIGHLIGHT, (77, 0, 0))       # empty disc: colour still taken
    g.op("led", c + 114, y + 32, 3, -2, HIGHLIGHT, (78, 0, 0))
    g.op("led", c + 118, y + 32, -1, 9, TEXT, None)                  # negative kinds: Python modulo
    g.op("led", c + 130, y + 32, -7, 9, HIGHLIGHT, None)
    for i, size in enumerate((1, 2, 3, 4, 5, 6, 8, 10, 13)):
        g.op("led", c + i * 15, y + 46, i % 5, size, TEXT if i % 2 else HIGHLIGHT, None)
        g.op("led", c + i * 15, y + 62, 0, size, HIGHLIGHT, (200, 100 + i, 50))
    g.op("checkpoint")
    # fill the table: 251 slots, then the nearest colour is reused
    for k in range(258):
        g.op("rgb", ((k * 37) % 256, (k * 11) % 256, (k * 3) % 256))
    g.op("rgb", (255, 0, 0))
    g.op("rgb", (250, 5, 3))
    g.op("rgb", (17, 99, 201))
    g.op("rgb", (0, 0, 0))
    g.op("rgb_fill", c, y + 80, 20, 4, (128, 128, 128))
    g.op("checkpoint")


def g_true_colors_reset(g):
    L = g.L
    g.op("rgb_fill", L.left, L.safe_top + 4, 5, 5, (1, 1, 1))
    g.op("rgb", (2, 2, 2))
    g.op("tap", 0, 0, 5, 5, "before clear")
    g.op("scroll_region", "before clear", 0, 0, 5, 5, 10)
    g.op("clear", UNLIT)
    g.op("rgb", (2, 2, 2))
    g.op("rgb_fill", L.left, L.safe_top + 14, 5, 5, (3, 3, 3))


def g_helpers(g):
    L = g.L
    for s in ["", "A", "AB", "HELLO WORLD", "µ°", "😀漢", "tab\there"]:
        for size in ("small", "mid", "big"):
            g.op("text_width", s, size)
    for n in (-5, 0, 4, 5, 6, 10, 11, 12, 17, 18, 100, 235, 201):
        for size in ("small", "mid", "big"):
            g.op("max_chars", n, size)
    for s in FIT_SAMPLES:
        for n in (0, 4, 5, 11, 29, 30, 41, 60, 300):
            g.op("fit_text", s, n, "small")
        g.op("fit_text", s, 50, "mid")
    for s in WRAP_SAMPLES:
        for n in (0, 30, 59, 60, 100, 140, L.width):
            g.op("wrap_text", s, n, "small")
        g.op("wrap_text", s, L.width, "mid")
        g.op("wrap_text", s, L.width, "big")
    for s in ("A · B · C", "SWIPE LEFT TO DELETE · SWIPE RIGHT TO EDIT · HOLD FOR THE MENU · TAP TO SEND",
              "ONE", "", " · LEADING", "A VERY LONG TOKEN THAT DOES NOT FIT ON ITS OWN AT ALL · B"):
        for n in (40, 100, L.width):
            g.op("token_lines", s, n, " · ")
        g.op("token_lines", s, 60, " / ")
    for s in UPPER_SAMPLES:
        g.op("upper", s)
    for cc, ww, s, size in ((0, 46, "SCAN", "small"), (10, 39, "SETUP", "small"), (0, 3, "WIDE", "small"),
                            (5, 100, "MID", "mid"), (-7, 20, "", "big"), (0, 0, "ODD", "small")):
        g.op("cx", cc, ww, s, size)
    for x in (0.0, 0.5, 1.5, 2.5, -0.5, -1.5, -2.5, 0.49999999999999994, 1e-17, -1e-17, 123.4999, 7.0, -7.5):
        g.op("round", x)
    for s in (0.5, 0.4, 0.75, 1.0, 1.25, 3.0, 2.9, 12.34, 29.75, 30.0, 45.0, -1.0, 0.0, 0.7458333):
        g.op("interval_stop", s)
        g.op("interval_text", s)
    g.op("interval_text", 0.05)
    g.op("interval_text", 2.45)
    g.op("interval_text", -3.25)
    for b in BASES:
        g.op("palette", b)
        g.op("alarm_inverted", b)
    for size in ("small", "mid", "big"):
        g.op("metrics", size)
    g.op("constants")
    for r in (-5, 0, L.content_top - 1, L.content_top, L.content_top + 1, L.content_bottom):
        g.op("group_top", r)
    g.op("layout")
    for f in (0.0, 0.1, 0.25, 0.3333, 0.5, 0.62, 0.75, 1.0, -0.1, 1.2):
        g.op("x", f)
    for n, gap, cc, ww in ((1, 6, None, None), (2, 6, None, None), (3, 4, None, None), (4, 4, 10, 100),
                           (5, 0, None, None), (7, 6, 3, 20), (2, 6, 0, 5)):
        g.op("split", n, gap, cc, ww)
    for i in range(10):
        g.op("tab_cell", i)
    for key, _ in W.TABS:
        g.op("tab_label", key)
    for t in ("scan", "SCAN", " Settings ", "SETUP", "setup", "lab", "relay", "", "Tx"):
        g.op("tab_key", t)


def g_chrome(g, tab_cases):
    """frame() for every tab, with header variants; a checkpoint after each, then clear."""
    for tab, title, tele, back, right, rcol, scroll, rtap in tab_cases:
        g.op("frame", tab, title, tele, back, right, rcol, scroll, rtap)
        g.op("state")
        g.op("end_frame")
        g.op("checkpoint")
        g.op("clear", UNLIT)
    # the last state stays for the page record
    g.op("frame", "lab", "LAB", DEFAULT_TELEMETRY, True, "REFRESH", HIGHLIGHT, 0, "refresh")
    g.op("end_frame")


TAB_CASES = [
    ("scan", "SCAN", DEFAULT_TELEMETRY, False, None, HIGHLIGHT, 0, None),
    ("tx", "TX", "MM/RF BLE:OFF | RX:0", False, "LOOP", HIGHLIGHT, 0, None),
    ("WAND", "WAND", DEFAULT_TELEMETRY, True, "SEND", HIGHLIGHT, 0, "send"),
    ("auto", "AUTO-RESPONSE RULES AND STACKS", DEFAULT_TELEMETRY, True, "ARMED", ALARM, 0, None),
    ("Link", "LINK", "", False, "BT OFF", ALARM, 0, "bt"),
    ("logs", "LOGS", "mm/rf ble:scan | lower case | ok", False, "REFRESH", DIM, 0, "refresh"),
    ("map", "MAP", " | | MM/RF | | RX:1 | ", True, None, HIGHLIGHT, 12, None),
    ("diag", "DIAGNOSTICS", "A" * 80, False, "A VERY LONG RIGHT STATUS TEXT", TEXT, 0, "right"),
    ("lab", "LAB", "MM/RF BLE:SCAN | RX:1284 | " + "X" * 30 + " | TAIL", False, "REC", HIGHLIGHT, 0, None),
    ("settings", "SETTINGS", DEFAULT_TELEMETRY, False, None, HIGHLIGHT, 0, None),
    ("SETUP", "settings", DEFAULT_TELEMETRY, True, "v1.3.0", DIM, 0, None),
]


def g_header_bits(g):
    L = g.L
    for title, back, right, rcol, rtap in (("SCAN", False, None, HIGHLIGHT, None),
                                           ("A TITLE MUCH TOO LONG FOR THE HEADER", True, None, HIGHLIGHT, None),
                                           ("WAND", True, "REC", ALARM, "rec"),
                                           ("TX", False, "12:04:33", DIM, "clock"),
                                           ("MAP", False, "FIT", HIGHLIGHT, "fit")):
        g.op("header", title, back, right, rcol, rtap)
        g.op("checkpoint")
        g.op("clear", UNLIT)
    for tele in (DEFAULT_TELEMETRY, "RX:1", "", "A | B", "TOKEN" * 12, "SHORT | " + "Y" * 40,
                 "a | b | c | d | e | f | g | h | i | j | k | l | m | n | o | p | q | r | s | t"):
        g.op("telemetry", tele)
        g.op("checkpoint")
        g.op("clear", UNLIT)
    for key, _ in W.TABS:
        g.op("tab_bar", key)
        g.op("checkpoint")
        g.op("clear", UNLIT)
    g.op("tab_bar", "SETUP")
    g.op("scrollbar", L.content_top + L.content_h, 0)            # fits: nothing drawn
    g.op("scrollbar", L.content_top + L.content_h + 1, 0)
    g.op("checkpoint")
    g.op("clear", UNLIT)
    for end, scroll in ((L.content_top + 2 * L.content_h, 0), (L.content_top + 2 * L.content_h, 100),
                        (L.content_top + 2 * L.content_h, 10000), (L.content_top + 50 * L.content_h, 37),
                        (L.content_top + 3 * L.content_h, -20)):
        g.op("scrollbar", end, scroll)
        g.op("checkpoint")
        g.op("clear", UNLIT)
    for top, h, total, scroll in ((L.content_top, 100, 99, 0), (L.content_top, 100, 101, 0),
                                  (L.content_top + 40, 200, 900, 350), (L.content_top + 40, 200, 900, 5000),
                                  (L.content_top, 50, 10000, 1)):
        g.op("list_scrollbar", top, h, total, scroll)
    g.op("checkpoint")


def g_alarms(g):
    """Everything that draws differently on a red-ish base."""
    L = g.L
    c, w = L.left, L.width
    g.op("header", "DIAG", True, "ERROR", ALARM, "err")
    y = L.content_top
    g.op("alarm", c, y, "ALARM TEXT", "small", 1)
    g.op("alarm", c + 100, y, "MID", "mid", 2)
    y += 24
    g.op("alarm_text", c, y, "LEFT ALARM", False)
    g.op("alarm_text", L.right, y, "RIGHT ALARM", True)
    g.op("alarm_text", c, y + 11, "", False)
    y += 22
    y2 = None
    g.op("status_line", c, y, w, "Bluetooth is off — turn it on", ALARM, False, None)
    g.op("status_line", c, y + 11, w, "status: relay timeout while sending a very long packet list", ALARM, False, "status")
    g.op("status_line", c, y + 22, w, "BANNER ALARM", ALARM, True, "banner")
    g.op("kv", c, y + 36, w, "LAST ERROR", "GATT 133", ALARM, True)
    g.op("kv", c, y + 47, w, "RSSI", "-91 dBm", ALARM, False)
    g.op("meter", c, y + 58, w, "SIGNAL", "WEAK", 0.15, (0.0, 0.3), True, ALARM)
    g.op("button", c, y + 80, None, "DELETE", False, True, None, True)
    g.op("button", c + 60, y + 80, 70, "CLEAR LOG", True, True, None, True)
    g.op("button", c + 140, y + 80, 50, "OFF", False, False, None, True)
    g.op("buttons", c, y + 96, w, ["SAVE", "DELETE", "CANCEL"], "SAVE", None, 4, True, "DELETE")
    g.op("packet_row", c, y + 112, w, "error row", HEX_SHORT, "relay error", None, False, None, None, HIGHLIGHT)


def g_widgets_text(g):
    L = g.L
    c, w = L.left, L.width
    y = L.content_top
    for args in (("LIVE RX", None, None, None, None), ("WAND", 12, True, None, None),
                 ("COLORS", 3, False, None, "fold:COLORS"), ("Rules (3)", None, None, "edit", None),
                 ("A SECTION TITLE THAT IS FAR TOO LONG TO FIT", 1234, False, None, None),
                 ("NEG", -7, None, None, None), ("RIGHT TEXT", None, True, "a long right text value here", None)):
        g.op("section", c, y, w, *args)
        y += 20
    g.op("section", c, L.content_top + 4, w // 2, "HALF", 5, False, None, None)
    g.op("checkpoint")
    g.op("clear", UNLIT)
    y = L.content_top
    g.op("label", c, y, w, "Backend", DIM, True)
    g.op("label", c, y + 20, w, "lower label µs", TEXT, True)
    g.op("label", c, y + 40, w, "no group gap", HIGHLIGHT, False)
    g.op("label", c, y + 60, 30, "TRUNCATED LABEL", DIM, True)
    g.op("text_block", c, y + 80, w, WRAP_SAMPLES[1], TEXT, False)
    g.op("text_block", c, y + 130, w, "upper me · please\nsecond line", DIM, True)
    g.op("text_block", c, y + 170, w, "", TEXT, False)
    g.op("text_block", c, y + 170, 2, "NO ROOM", TEXT, False)
    g.op("status_line", c, y + 180, w, "Scanning", DIM, False, None)
    g.op("status_line", c, y + 191, w, "log · scan_2026-11-19T21-42-07.csv", TEXT, False, "log")
    g.op("status_line", c, y + 202, w, "status: sending", HIGHLIGHT, False, None)
    g.op("status_line", c, y + 213, w, "banner in dim", DIM, True, None)
    g.op("status_line", c, y + 227, w, "banner text", TEXT, True, "b1")
    g.op("status_line", c, y + 241, w, "banner highlight", HIGHLIGHT, True, None)
    g.op("status_line", c, y + 255, w, "banner alarm", ALARM, True, None)
    g.op("status_line", c, y + 269, 40, "narrow banner that is cut", HIGHLIGHT, True, None)
    g.op("checkpoint")
    g.op("clear", UNLIT)
    y = L.content_top
    g.op("kv", c, y, w, "Packets", "1284", HIGHLIGHT, True)
    g.op("kv", c, y + 11, w, "rssi", "-57 dBm", TEXT, True)
    g.op("kv", c, y + 22, w, "address", "A7D3901B", DIM, False)
    g.op("kv", c, y + 33, w, "none", None, HIGHLIGHT, True)
    g.op("kv", c, y + 44, w, "empty", "", HIGHLIGHT, True)
    g.op("kv", c, y + 55, w, "a long key name here", "AND A VERY LONG VALUE THAT MUST BE CUT", HIGHLIGHT, True)
    g.op("kv", c + 1, y + 66, w - 1, "odd start", "7", HIGHLIGHT, True)
    g.op("kv", c, y + 77, 40, "KEY WIDER THAN THE ROW", "V", HIGHLIGHT, True)
    g.op("hero", c, L.content_top, w // 2, "RX", "1284", "big", HIGHLIGHT, "PKTS")
    g.op("hero", c + w // 2, y + 90, w // 2, "lights", "37", "mid", TEXT, None)
    g.op("hero", c, y + 130, w // 3, "narrow", "123456789", "big", HIGHLIGHT, "SUB TEXT CUT")
    g.op("divider", c, y + 180, w, True, DIM)
    g.op("divider", c, y + 184, w, False, HIGHLIGHT)
    g.op("panel_inner", c, y, w, True)
    g.op("panel_inner", c, y, w, False)
    g.op("panel", c, y + 190, w, 40, "RELAY INFO", DIM)
    g.op("panel", c, y + 235, w, 30, None, HIGHLIGHT)
    g.op("panel", c, y + 270, 40, 30, "A PANEL TITLE TOO LONG", DIM)
    g.op("panel", c, y + 305, 10, 10, "X", DIM)
    g.op("checkpoint")


def g_controls(g):
    L = g.L
    c, w = L.left, L.width
    y = L.content_top
    g.op("toggle", c, y, w, "Loop", True, True, None, TEXT)
    g.op("toggle", c, y + 15, w, "auto respond", False, True, None, TEXT)
    g.op("toggle", c, y + 30, w, "TX MODE: INTERLEAVE", True, True, "toggle:TX MODE", HIGHLIGHT)
    g.op("toggle", c, y + 45, w, "disabled on", True, False, None, TEXT)
    g.op("toggle", c, y + 60, w, "disabled off", False, False, None, TEXT)
    g.op("toggle", c, y + 75, 80, "A LABEL TOO LONG FOR A NARROW ROW", True, True, None, TEXT)
    y += 92
    g.op("stepper", c, y, w, "Vibration", "7", True, True, True, None, None)
    g.op("stepper", c, y + 15, w, "count", "0", True, False, True, 3, "count")
    g.op("stepper", c, y + 30, w, "max", "15", True, True, False, None, None)
    g.op("stepper", c, y + 45, w, "disabled", "42", False, True, True, None, None)
    g.op("stepper", c, y + 60, 60, "NARROW STEPPER LABEL", "1000", True, True, True, 2, None)
    y += 77
    g.op("button", c, y, None, "Vibrate", False, True, None, False)
    g.op("button", c + 70, y, None, "send", True, True, "send now", False)
    g.op("button", c + 130, y, 40, "DISABLED", False, False, None, False)
    g.op("button", c, y + 15, w, "full width primary", True, True, None, False)
    g.op("button", c, y + 30, 20, "TOO LONG", False, True, None, False)
    g.op("button", c, y + 45, 60, "PRIMARY OFF", True, False, None, False)
    y += 62
    g.op("buttons", c, y, w, ["VIBRATE", "INTERROGATE"], None, None, 4, False, None)
    g.op("buttons", c, y + 15, w, ["ONE", "TWO", "THREE"], 1, [True, False, True], 4, True, None)
    g.op("buttons", c, y + 30, w, ["A", "B", "C", "D"], "C", [True] * 4, 6, True, 3)
    g.op("buttons", c, y + 45, w, [], None, None, 4, True, None)
    g.op("buttons", c, y + 45, w, ["SOLO"], None, [], 4, True, None)
    g.op("checkpoint")
    g.op("clear", UNLIT)
    y = L.content_top
    themes = ["STANDARD", "VFD"]
    bases = ["AMBER", "GREEN", "CYAN", "BLUE", "RED", "WHITE", "CUSTOM"]
    g.op("options", c, y, w, themes, "VFD", "THEME", True, None, None)
    g.op("options", c, y + 30, w, bases, 2, None, True, "option:BASE COLOUR", None)
    g.op("options", c, y + 75, w, ["Grouped", "raw"], "RAW", None, True, "mode", None)
    g.op("options", c, y + 90, w, ["Low", "Mid", "High", "Max"], "Mid", "broadcast strength", True, None, 4)
    g.op("options", c, y + 130, w, ["STARLIGHT", "NEW WAND"], 1, None, True, None, 2)
    g.op("options", c, y + 145, w, ["WAND", "COLORS", "ANIMATIONS", "CONTROL", "PING", "SHOWS"],
         {"COLORS", "PING"}, "Filter", True, "filter:type", None)
    g.op("options", c, y + 190, w, ["a", "b", "c", "d", "e", "f", "g"], {0, 3, 6}, None, True, None, 3)
    g.op("options", c, y + 240, w, ["DISABLED", "CHOICE"], 0, "off", False, None, None)
    g.op("options", c, y + 270, w, ["A VERY LONG OPTION NAME", "SHORT", "ANOTHER LONG OPTION"], None, None, True, None, 3)
    g.op("options", c, y + 285, 50, ["TOOWIDEFORTHEROW", "X"], "X", None, True, None, None)
    g.op("options", c, y + 315, w, [], 0, "EMPTY", True, None, None)
    g.op("options", c, y + 340, w, ["µs", "ms"], "µs", None, True, None, 2)
    g.op("checkpoint")


def g_sliders(g):
    L = g.L
    c, w = L.left, L.width
    y = L.content_top
    g.op("slider", c, y, w, "Burst ms", "120", 0.3, None, True, None, False, None, None, None)
    g.op("slider", c, y + 30, w, "WAKE SLICE MS", "20", 0.0, "Each wake/command slice in the 1:1 interleave · default 30ms",
         True, None, False, "slider:WAKE SLICE", None, None)
    g.op("slider", c, y + 80, w, "max", "100", 1.0, None, True, (0.6, 0.9), True, None, None, None)
    g.op("slider", c, y + 110, w, "explicit", "5", 0.5, None, True, None, False, None, False, True)
    g.op("slider", c, y + 140, w, "disabled", "OFF", 0.5, "hint while disabled", False, None, True, None, None, None)
    g.op("slider", c, y + 180, 60, "A SLIDER TITLE TOO LONG", "123456", 0.7, None, True, None, False, None, None, None)
    y += 210
    g.op("meter", c, y, w, "Strength", "-57 dBm", 0.6, None, False, HIGHLIGHT)
    g.op("meter", c, y + 22, w, "target", "OK", 0.5, (0.4, 0.6), True, TEXT)
    g.op("meter", c, y + 44, 60, "METER TITLE LONG", "LONG VALUE", 1.2, None, False, HIGHLIGHT)
    y += 66
    g.op("interval_slider", c, y, w, "Loop every 3.0 s", 3.0, "slider:INTERVAL")
    g.op("interval_slider", c, y + 25, w, "min", 0.5, "slider:LOOP")
    g.op("interval_slider", c, y + 50, w, "MAX", 30.0, "slider:LOOP")
    g.op("interval_slider", c, L.content_top, w, "at top", 7.25, "slider:TOP")
    g.op("checkpoint")
    g.op("clear", UNLIT)
    y = L.content_top
    g.op("field", c, y, w, "Rule name", "Wand → Band", "Rule name", False, None, TEXT)
    g.op("field", c, y + 30, w, "Android IP (hotspot gateway)", "", "192.168.43.1", True, None, TEXT)
    g.op("field", c, y + 60, w, None, "8301CC03000100E1", "VMMS token hex", True, "field:TOKEN", DIM)
    g.op("field", c, y + 80, w, None, "", "", False, None, TEXT)
    g.op("field", c, y + 100, w, "", "", "placeholder only", False, "picker:X", TEXT)
    g.op("field", c, y + 120, 60, "narrow", "A VALUE MUCH TOO LONG FOR THE FIELD", "", True, None, TEXT)
    g.op("field", c, y + 150, 60, "narrow", "", "A PLACEHOLDER TOO LONG", True, None, TEXT)
    g.op("menu_button", c, y + 180, "CLASS 8/8", True, None)
    g.op("menu_button", c + 80, y + 180, "class 3/8", False, None)
    g.op("menu_button", c + 150, y + 180, "MENU", True, "menu:CLASS")
    g.op("step_button", c, y + 200, False, True, "step:-")
    g.op("step_button", c + 20, y + 200, True, True, "step:+")
    g.op("step_button", c + 40, y + 200, True, False, "step:off")
    g.op("step_button", c + 60, y + 200, False, True, None)
    g.op("checkpoint")


def g_packets(g):
    L = g.L
    c, w = L.left, L.width
    y = L.content_top
    rows = [
        ("Cross-Fade: Red / Blue", HEX_LIVE, "-57 dBm · 5C0E8B47 · 0.4 s", "band", False, "12s", None, HIGHLIGHT),
        ("Ping", HEX_SHORT, "", None, True, None, None, DIM),
        ("Selected row with a long label that gets cut", HEX_BAND, "subtitle", "NEW", True, "-91", None, HIGHLIGHT),
        ("no hex", "", "only a subtitle", None, False, None, "packet:CUSTOM", DIM),
        ("bare", "", "", None, False, None, None, HIGHLIGHT),
        ("tag only", HEX_BAND * 3, "", "band", False, None, None, DIM),
    ]
    for args in rows:
        g.op("packet_row", c, y, w, *args)
        y += 40
    g.op("packet_row", c, y, 60, "narrow row label", HEX_BAND, "narrow subtitle", "TAG", True, "RIGHT", None, HIGHLIGHT)
    g.op("checkpoint")
    g.op("clear", UNLIT)
    y = L.content_top
    g.op("chart", c, y, w, 40, "RSSI dBm", [-70, -65, -60, None, -58, -80, -90, -55], "-55", None, None, HIGHLIGHT)
    g.op("chart", c, y + 60, w // 2, 30, None, [1, 2, 3, 2, 1], None, None, None, TEXT)
    g.op("chart", c, y + 100, w, 30, "range", [5, 15, 25], None, 0.0, 30.0, HIGHLIGHT)
    g.op("chart", c, y + 150, w, 24, None, [], "123", None, None, HIGHLIGHT)
    g.op("badge", c, y + 200, "NEW", HIGHLIGHT)
    g.op("badge", c + 40, y + 200, "", HIGHLIGHT)
    g.op("badge", c + 60, y + 200, "dim badge", DIM)
    g.op("tag_box", c, y + 215, "band", DIM, TEXT)
    g.op("tag_box", c + 40, y + 215, "", DIM, TEXT)
    g.op("tag_box", c + 60, y + 215, "µs", HIGHLIGHT, DIM)
    g.op("chevron", c, y + 230, True, DIM)
    g.op("chevron", c + 12, y + 230, False, HIGHLIGHT)
    g.op("chevron_up", c + 24, y + 230, DIM)
    g.op("checkpoint")


def g_scrolled(g, scroll):
    """frame() with a scrolled content clip: widgets crossing the content edges, padded taps moved
    inside the clip, then end_frame and the scrollbar."""
    L = g.L
    c, w = L.left, L.width
    g.op("frame", "settings", "SETTINGS", DEFAULT_TELEMETRY, False, None, HIGHLIGHT, scroll, None)
    g.op("state")
    y = L.content_top
    g.op("toggle", c, y, w, "first row at the top", True, True, None, TEXT)
    y = L.content_top + scroll - 4
    g.op("toggle", c, y, w, "crossing the top edge", False, True, None, TEXT)
    g.op("button", c, y + 6, 60, "TOP BTN", False, True, None, False)
    y = L.content_top + scroll + 3
    g.op("button", c + 70, y, 60, "NEAR TOP", False, True, None, False)
    g.op("section", c, y + 20, w, "SECTION", 4, False, None, None)
    y = L.content_top + scroll + L.content_h - 13
    g.op("toggle", c, y, w, "last row at the bottom", True, True, None, TEXT)
    g.op("stepper", c, y + 8, w, "crossing the bottom", "3", True, True, True, None, None)
    g.op("tap", c, L.content_top + scroll + 100, 20, 5, "short direct tap")
    g.op("wtap", c + 30, L.content_top + scroll + 100, 20, 5, "short padded tap", 15)
    g.op("wtap", c + 60, L.content_top + scroll, 20, 5, "padded at top", 15)
    g.op("wtap", c + 90, L.content_top + scroll + L.content_h - 5, 20, 5, "padded at bottom", 15)
    g.op("wtap", c + 120, L.content_top + scroll - 10, 20, 5, "outside: cut", 15)
    g.op("wtap", c + 150, L.content_top + scroll + 50, 20, 5, None, 15)
    g.op("wtap", c + 150, L.content_top + scroll + 50, 20, 5, "", 15)
    g.op("wtap", c + 180, L.content_top + scroll + 50, 20, 5, "tall min", 40)
    g.op("end_frame")
    g.op("state")
    g.op("scrollbar", L.content_top + L.content_h + scroll + 200, scroll)


def g_window(g):
    """snapped_window() on list fragments crossing the window edges."""
    L = g.L
    c, w = L.left, L.width
    top, bottom = L.content_top + 30, L.content_bottom - 20

    def lines_from(start, n, divider=True):
        y = start
        for i in range(n):
            g.op("text", c, y, "LIST ROW %02d gjpq" % i, "small", TEXT)
            if divider:
                g.op("hline", c, y + 10, w, DIM, 2)
            y += 13

    for start in (top - 5, top - 9, top - 10, top - 11, top + 1, top - 3):
        g.op("window_begin")
        lines_from(start, (bottom - start) // 13 + 2)
        g.op("window_end", top, bottom)
    g.op("window_begin")                 # lone dividers near both edges
    g.op("hline", c, top + 2, w, DIM, 1)
    g.op("text", c, top + 20, "MIDDLE", "small", TEXT)
    g.op("hline", c, bottom - 3, w, DIM, 2)
    g.op("window_end", top, bottom)
    g.op("window_begin")                 # nothing drawn
    g.op("window_end", top, bottom)
    g.op("window_begin")                 # a solid block over the whole window
    g.op("fill", c, top - 20, w, bottom - top + 40, HIGHLIGHT)
    g.op("window_end", top, bottom)
    g.op("window_begin")                 # alarms on the probe buffer, true colours too
    g.op("alarm", c, top - 4, "ALARM AT THE TOP", "small", 1)
    g.op("rgb_fill", c, bottom - 3, 7, 7, (255, 0, 0))
    g.op("window_end", top, bottom)
    g.op("push_clip", 0, top, g.dev.cols, bottom - top, -40)   # origin carried into the probe
    g.op("window_begin")
    lines_from(top + 40 - 6, 30)
    g.op("window_end", top, bottom)
    g.op("pop_clip")
    g.op("text", c, top, "page state after the windows", "small", HIGHLIGHT)
    g.op("checkpoint")


def g_screen(g, scroll, kind):
    """A whole screen through render_previews.draw_screen (two passes, snapped content window,
    hidden partial taps dropped, scrollbar)."""
    L = g.L
    c, w = L.left, L.width
    if kind == "settings":
        g.op("screen_begin", "settings", "SETTINGS", DEFAULT_TELEMETRY, False, None, HIGHLIGHT, None, scroll)
        y = L.content_top
        g.op("section", c, y, w, "APPEARANCE", None, None, None, None)
        g.op("options", c, y + 13, w, ["STANDARD", "VFD"], "VFD", "THEME", True, None, None)
        g.op("options", c, y + 51, w, ["AMBER", "GREEN", "CYAN", "BLUE", "RED", "WHITE", "CUSTOM"],
             "AMBER", "BASE COLOUR", True, "option:BASE COLOUR", None)
        y += 110
        for i in range(6):
            g.op("toggle", c, y, w, "setting toggle %d" % i, i % 2 == 0, True, None, TEXT)
            y += 15
        g.op("slider", c, y, w, "Burst ms", "120", 0.3, WRAP_SAMPLES[2], True, None, False, None, None, None)
        y += 50
        g.op("text_block", c, y, w, WRAP_SAMPLES[3], DIM, False)
        y += 40
        for i in range(10):
            g.op("kv", c, y, w, "key %d" % i, "value %d" % (i * 37), HIGHLIGHT, True)
            y += 11
        g.op("section", c, y, w, "ABOUT", None, False, None, None)
        g.op("text_block", c, y + 21, w, "MagicMaker 1.3.0 (14) · VFD theme", DIM, False)
        for i in range(12):
            g.op("button", c, y + 40 + i * 15, w, "button %d" % i, i == 3, i != 5, None, i == 7)
        g.op("divider", c, y + 40 + 12 * 15, w, True, DIM)
        g.op("screen_end", "last")
    else:
        g.op("screen_begin", "logs", "LOGS", DEFAULT_TELEMETRY, True, "REFRESH", HIGHLIGHT, "refresh", scroll)
        y = L.content_top
        g.op("status_line", c, y, w, "STATUS: relay timeout", ALARM, False, None)
        y += 11
        for i in range(14):
            g.op("packet_row", c, y, w, "log row %d" % i, HEX_LIVE if i % 2 else HEX_BAND,
                 "-%d dBm · 0%dX" % (50 + i, i), "band" if i % 3 == 0 else None, i == 2, "%ds" % (i * 7),
                 None, DIM)
            y += 36
        g.op("rgb_fill", c, y, 7, 7, (0, 128, 255))
        g.op("led", c + 10, y, 0, 7, HIGHLIGHT, (255, 64, 0))
        g.op("divider", c, y + 9, w, True, DIM)            # the content end draw() returns
        g.op("screen_end", "last")


def build_ops():
    g = Gen()
    g.lines.append("# VFD golden ops: generated by tools/vfd/golden.py (format in its docstring). "
                   "Do not edit by hand.")
    for dk in DEVICE_KEYS:
        g.page("primitives", dk)
        g_primitives(g)
        g.page("text", dk)
        g_text(g)
        g.page("text_red", dk, "RED")
        g_text(g)
        g.page("indicators", dk)
        g_indicators(g)
        g.page("clip_taps", dk)
        g_clip(g)
        g.page("true_colors", dk)
        g_true_colors(g)
        g.page("true_colors_reset", dk)
        g_true_colors_reset(g)
        g.page("helpers", dk)
        g_helpers(g)
        g.page("chrome", dk)
        g_chrome(g, TAB_CASES)
        g.page("chrome_red", dk, "RED")
        g_chrome(g, TAB_CASES[2:6])
        g.page("header_bits", dk)
        g_header_bits(g)
        for base in ("AMBER", "RED", "#FF8800", "#808080", "CYAN"):
            g.page("alarms", dk, base)
            g_alarms(g)
        g.page("widgets_text", dk)
        g_widgets_text(g)
        g.page("widgets_text_red", dk, "RED")
        g_widgets_text(g)
        g.page("controls", dk)
        g_controls(g)
        g.page("sliders", dk)
        g_sliders(g)
        g.page("packets", dk)
        g_packets(g)
        for scroll in (0, 37):
            g.page("scrolled_%d" % scroll, dk)
            g_scrolled(g, scroll)
        g.page("window", dk)
        g_window(g)
        for scroll in (0, 45, 120, 400):
            g.page("screen_settings_%d" % scroll, dk)
            g_screen(g, scroll, "settings")
        for scroll, base in ((0, "AMBER"), (60, "RED"), (213, "AMBER")):
            g.page("screen_logs_%d" % scroll, dk, base)
            g_screen(g, scroll, "logs")
    return g.lines


# ---------------------------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------------------------

EXPECTED_HEADER = [
    "# VFD golden expected results: generated by tools/vfd/golden.py from vfd.py, widgets.py and",
    "# render_previews.draw_screen (format in golden.py's docstring). Do not edit by hand.",
]

DUMP_ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"


def dump_char(v):
    if v == 0:
        return "."
    if v < 5:
        return str(v)
    return DUMP_ALPHABET[(v - 5) % len(DUMP_ALPHABET)]


def write_dumps(pages, folder):
    os.makedirs(folder, exist_ok=True)
    for i, (page, lines) in enumerate(pages, 1):
        fb = page.fb
        out = list(lines)
        out.append("grid\t%d\t%d" % (fb.cols, fb.rows))
        for r in range(fb.rows):
            row = fb.cells[r * fb.cols:(r + 1) * fb.cols]
            out.append("%03d %s" % (r, "".join(dump_char(v) for v in row)))
        path = os.path.join(folder, "%03d_%s_%s.txt" % (i, page.name, page.device_key))
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(out) + "\n")


def generate():
    ops = build_ops()
    expected, pages = execute(ops)
    return ops, EXPECTED_HEADER + expected, pages


def _text(lines):
    return "\n".join(lines) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description="Write or check the VFD golden files.")
    ap.add_argument("--check", action="store_true", help="fail if the committed files are stale")
    ap.add_argument("--dump", metavar="DIR", help="write readable per-page dumps to DIR only")
    ap.add_argument("--out", default=GOLDEN_DIR, help="folder for ops.txt / expected.txt")
    args = ap.parse_args(argv)

    ops, expected, pages = generate()
    if args.dump:
        write_dumps(pages, args.dump)
        print("wrote %d page dumps to %s" % (len(pages), args.dump))
        return 0
    files = {"ops.txt": _text(ops), "expected.txt": _text(expected)}
    if args.check:
        stale = []
        for name, text in files.items():
            path = os.path.join(args.out, name)
            try:
                with open(path, encoding="utf-8", newline="") as f:
                    have = f.read()
            except OSError:
                have = None
            if have != text:
                stale.append(path)
        for p in stale:
            print("STALE: %s does not match golden.py; run python3 tools/vfd/golden.py" % p)
        return 1 if stale else 0
    os.makedirs(args.out, exist_ok=True)
    for name, text in files.items():
        with open(os.path.join(args.out, name), "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    n_ops = sum(1 for ln in ops if ln and not ln.startswith(("#", "page\t")))
    print("wrote %s: %d pages, %d ops" % (args.out, len(pages), n_ops))
    return 0


if __name__ == "__main__":
    sys.exit(main())
