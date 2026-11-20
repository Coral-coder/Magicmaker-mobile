"""LAB tab in the VFD look: port of ios/MagicMaker/Views/LabScreen.swift, LabBuilderPanel.swift and
BandPreviewView.swift.

Top to bottom, as on the phone:
    pinned (never scrolls): BAND PREVIEW (band face + BAND PREVIEW / effect kind / note · APPROX. /
      duration / BUZZ) | hairline
    scrolling under it:
      builder group: LabModeBar (STANDARD · KNOWN & TESTED + switch, KEEP BAND AWAKE + switch, the
        PING picker while keep-awake or Extended is on) | hairline | PACKET BUILDER | intro |
        LabBuilderPanel: WHAT DO YOU WANT THE BAND TO DO? + type chips, blurb, load message |
        YOU ARE BUILDING card | the type's fields (COLORS pickers, BUZZ + PATTERN) | FRAMING
        (channel marker, DURATION, wake ping first) | PACKET ANATOMY — TAP A BLOCK | USE IN HEX
        FIELD, LOAD HEX
      edit group: hairline | HEX OUTPUT, LABEL fields, the hex's reject reason (error) | PACKET
        INSPECTOR (classification, colours; open: VIBRATION [-] nn [+], RAW BYTES grid, hint) |
        SEND SAVE TAG, preset message, link warning, TX status line
      extras group: hairline | RANDOM LIGHT SHOW (text, INTERVAL slider + hint, START SHOW) |
        hairline, MY PRESETS (n) rows | MBLE TAP (LIGHTNING LANE) token field, payload, MBLE ADV |
        HAWKEYE THEMES (folded by default; open: hint, categories of theme rows)

Re-expressed for the grid:
    * the band preview's canvas is pixel art: a FACE x FACE rounded square (dim) with five round
      LED zones (Z1 bottom-left, Z2 top-left, Z3 centre, Z4 top-right, Z5 bottom-right, the iOS
      geometry). Packet colours are never drawn as RGB: each distinct colour gets a fill pattern
      (solid, checker, ring, stripes; the same order as the SCAN strip) and an extra legend line
      under the text names them. An unlit zone is a dotted dim ring. The animation is shown at
      rest (the decoded per-LED colours); the 1 Hz BUZZ blink is drawn in its "on" phase.
    * the pinned preview keeps the iOS order of lines but is as tall as its 7 text lines (about
      a fifth of the content instead of a sixth), so nothing is cut at 207 columns.
    * iOS colours map as: cyan -> highlight, cyanDim / textDim -> dim (so the HEX OUTPUT value
      and the RAW BYTES cells are dim), textPrimary -> text, amber cautions (APPROX., experimental
      notes, amber anatomy blocks) -> text, the LINK NOT READY warning and error red (the hex
      reject reason) -> alarm (inverted block on a red-ish base).
    * Toggles are pixel ON/OFF switches. The mode-bar rows keep their switch on the right of the
      title with the description wrapped full width under them; the framing rows keep the iOS
      order (switch on the left, then the title) with the detail wrapped under them.
    * LabPalettePicker (a bordered menu button that opens a sheet) is a dim-bordered button
      "LABEL: VALUE" in highlight with a dim up/down chevron; its colour dot is dropped because the
      value already names the colour (#15 RED). The sheet itself is modal and not drawn.
    * the summary card is a 1-cell box in its tone (known = highlight, unknown = text, invalid =
      alarm); its headline is a mid-size title, broken after the "Kind:" prefix when it is too
      wide; the detail line wraps at its " · " separators.
    * PACKET ANATOMY blocks are dim boxes (hex in the block's tone, title in dim); a colour block
      names its palette colour after the hex instead of the swatch; the selected block is
      inverted and its explanation sits in a dim box under the blocks.
    * the inspector's chevron points down when folded and up when open (as iOS); RAW BYTES is an
      8-column grid of boxed bytes (the LazyVGrid gives 8 columns on both phones).
    * the preset row's trash button is a 7 x 8 pixel bin on the right; SettingSlider moves its
      unit into the title ("INTERVAL MS").
    * a Hawkeye theme row's colour dots become their CMS swatch codes (#RRGGBB, dim) beside the
      title, or on a line under the hex when both do not fit; the hex is highlight, middle-cut.
    * the scrolling part keeps its own scroll indicator (beside the scrolling rows only), and a
      line cut by the window edges is hidden rather than drawn in part.

Mock state: a packet heard on SCAN was sent to the Lab (its LAST LIGHTS packet, Cross-Fade: Red /
Blue with a wake ping, channel marker and a triple buzz) and then saved as a preset; Standard
mode; keep-awake running on the linked relay with the wake ping; the inspector opened and the
"Fade from" anatomy block tapped; the random show stopped at its 3000 ms default; five user
presets; no MBLE token typed; HAWKEYE THEMES folded (the default). Every label, hex, anatomy
caption and band decode is the app's own output for these packets (ios/ParityCheck/vectors.json,
LabPacketBuilder, PacketBuilder and MdeThemeCatalog).
"""

import widgets as W
import vfd
from vfd import UNLIT, HIGHLIGHT, TEXT, DIM, ALARM, text_width, fit_text

chevron_up = W.chevron_up


TAB = "lab"
TITLE = "LAB"

# ---------------------------------------------------------------------------------------------
# Mock state (AppViewModel, MagicStore, TxEngine and the Lab's own @State)
# ---------------------------------------------------------------------------------------------

#: The Lab packet (store.getLabHex) and label: SCAN's LAST LIGHTS packet, loaded with loadInLab.
LAB_HEX = "8301CC03000100E100E911006F0F554258F44882D1460208D06500B3"
LAB_LABEL = "Cross-Fade: Red / Blue"

EXTENDED = False               # @AppStorage("lab_extended")
LINK_READY = True              # vm.remoteLinkReady (telemetry RELAY:LINK)
KEEP_AWAKE = True              # vm.keepAwakeActive
PING_NAME = "Wake ping (CC03 000100)"     # LabModeBar.pingOptions[0]

#: BandEffectModel.from(LAB_HEX) (vectors.json "band"): zones are Z1..Z5 colour names.
PREVIEW = {
    "kind": "crossfade",
    "zones": ["Red", "Red", "Blue", "Red", "Red"],
    "note": "Two-colour fade, centre out of phase",
    "approximate": True,
    "duration_ms": 46500,
    "fade_ms": 2000,
    "always_on": False,
    "buzz": "Triple",
}

#: LabPacketBuilder.LabPacketType in order: (label, blurb, experimental).
TYPES = [
    ("Single Color", "One solid band color.", False),
    ("Dual Color", "Two colors — inner / outer ring.", False),
    ("Crossfade", "Smooth fade from one color to another.", False),
    ("Rainbow / Custom", "Five LED colors — pick every one for your own animation.", False),
    ("Rotating Colors", "Five zone colors that rotate around the band (Figment-style).", False),
    ("Circle Spin", "Rotating ring — seven pattern colours you can change (Figment is this shape).",
     False),
    ("Vibrate Only", "Haptic buzz, no color change.", False),
    ("Park Show", "A real show effect captured in the park — lightning, sparkle, cannon…", False),
    ("Wake Ping", "Wakes nearby bands so they hear the next command.", False),
    ("Raw Hex", "Type any payload by hand for total control.", False),
    ("Custom RGB", "Any colour from red/green/blue sliders (E908, 6 bits each). Untested on a band.",
     True),
    ("Experiments", "Packets that test something we don't know yet. Each says what to watch for.",
     True),
]
SELECTED_TYPE = "Crossfade"    # LabPacketBuilder.decode(LAB_HEX).type
LOAD_MSG = "Loaded Crossfade from received packet"

#: The crossfade's colour slots (slotLabel FROM / TO) as LabBuilderPanel.paletteOptions labels.
COLOR_SLOTS = [("FROM", "#15 Red"), ("TO", "#02 Blue")]
VIB_ENABLED = True
VIB_PATTERN = "Triple"
CHANNEL_MARKER = True
WAKE_PREFIX = True
TIMING = "Default"             # PacketBuilder.Timing.options label

#: LabPacketSummary(LAB_HEX).
SUMMARY = {
    "headline": "Cross-Fade: Red / Blue",
    "colors": "Red / Blue",
    "details": ["wake ping first", "channel 1", "buzz triple", "28 bytes", "fits in BLE"],
    "reject": None,
    "tone": "known",
}

#: HexUtils.legacyAdvertiseRejectReason(LAB_HEX), shown in error red under the LABEL field
#: (LabScreen.packetFields). The same value as SUMMARY["reject"] (the card computes its own copy).
HEX_REJECT = None

#: DisneyTlv.anatomy(LAB_HEX): (hex, title, detail, kind), from vectors.json.
ANATOMY = [
    ("8301", "Disney", "Company ID 0x0183. Every receiver checks this first.", "company"),
    ("CC03000100", "Wake Ping", "Interaction ping. 000100 is the wake ping that makes nearby bands "
     "listen for the next command.", "ping"),
    ("E100", "Channel 1", "Zero-length marker. Every effect in the park capture carries one of these "
     "before its effect record.", "channel"),
    ("E911", "Effect record", "Two-colour fade / pulse burst — 17-byte body. The length is what "
     "picks the effect shape.", "effectHead"),
    ("006F0F", "Header", "Sub-code, then timing byte (on for ~47 s, 2 s fade-out), then flags.",
     "header"),
    ("55", "Fade from", "Low 5 bits = palette #15 Red. High bits are the slot flag.", "color"),
    ("42", "Fade to", "Low 5 bits = palette #02 Blue. High bits are the slot flag.", "color"),
    ("58F44882D1460208D06500", "Data", "Timing / curve bytes for this effect.", "data"),
    ("B3", "Tail · buzz 3", "B0 | vibration pattern (0–15). Only meaningful on the esp32_magicband "
     "shapes; two real park effects end in 01 instead.", "tail"),
]
SELECTED_SEGMENT = 5           # "Fade from" tapped

INSPECTOR_EXPANDED = True
CLASSIFIED = ("Cross-Fade: Red / Blue", "ANIMATION", "Red / Blue")   # label, category, colors

PRESET_MSG = "Saved preset — see TX + Auto tabs"
TX_STATUS = "Keeping band awake"   # TxEngine.status with keep-awake on

RANDOM_SHOW = False
RANDOM_SHOW_LABEL = ""
INTERVAL_MS = 3000             # tx.randomShowIntervalMs (500...30000, step 250)

#: store.customPresets (already sorted by label, ignoring case).
PRESETS = [
    ("Cross-Fade: Red / Blue", "8301CC03000100E100E911006F0F554258F44882D1460208D06500B3"),
    ("Cyan candles", "8301E200E90F00120F40565813488DD2462A1317B0"),
    ("Figment spin", "8301E100E91200030FA2A2A4A4A230D037F4D2460064FCB0"),
    ("Pink comet", "8301E100E91000194897D00E8ED146060F30D04E1FB0"),
    ("Purple/Pink dual", "8301E90600220F8588B0"),
]

MBLE_TOKEN = ""                # the VMMS token hex field
MBLE_PAYLOAD = None            # MbleBeaconBuilder.manufacturerPayload(token) as hex, or None

THEMES_COLLAPSED = True        # @AppStorage("lab_themes_collapsed")
#: MdeThemeCatalog.categories: (title, [(title, swatches, transmitHex)]).
THEMES = [
    ("SOLID COLORS", [
        ("Cyan", ["#00BCE4"], "8301E905002E0EE0B0"),
        ("Blue", ["#0079BC"], "8301E905002E0EE2B0"),
        ("Lavender", ["#B69FCC"], "8301E905002E0EE2B0"),
        ("Purple", ["#6B3FA0"], "8301E905002E0EE2B0"),
        ("Pink", ["#F078A8"], "8301E905002E0EE2B0"),
        ("Red", ["#D02030"], "8301E905002E0EF5B0"),
        ("Orange", ["#F07830"], "8301E905002E0EE2B0"),
        ("Green", ["#78C850"], "8301E905002E0EE2B0"),
        ("White", ["#FFFFFF"], "8301E905002E0EE8B0"),
    ]),
    ("DUAL TONES", [
        ("Yellow-Orange / Blue", ["#F07830", "#0079BC"], "8301E90600220F8F82B0"),
        ("Purple / Pink", ["#6B3FA0", "#F078A8"], "8301E90600220F8588B0"),
        ("Cyan / Green", ["#00BCE4", "#78C850"], "8301E90600220F8099B0"),
    ]),
    ("MULTI-COLOR", [
        ("Guest Rainbow", ["#F07830", "#D02030", "#78C850", "#0079BC", "#6B3FA0"],
         "8301E909002E0FAFB5B9A2A1B0"),
    ]),
]

# ---------------------------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------------------------

_ADV = 6
FACE = 55                 # band face: FACE x FACE cells
LED = 11                  # one round LED zone: LED x LED cells
_LED_AT = (8, 22, 36)     # zone offsets inside the face (left/top, centre, right/bottom)
#: Z1..Z5 as (column, row) in the face's 3 x 3 spots (BandPreviewView's point order).
_ZONE_SPOT = [(0, 2), (0, 0), (1, 1), (2, 0), (2, 2)]
SWATCH = 7                # legend swatch: a 7 x 7 round LED
N_PATTERNS = 5
CHIP_H = 23               # anatomy block: border, 2 pad, caps, 3, caps, 2 pad, border
TRASH_W = 7

#: Anatomy block tone (labSegmentColor): cyan -> highlight, amber -> text, others dim, error alarm.
_TONE = {"company": DIM, "channel": TEXT, "ping": TEXT, "effectHead": HIGHLIGHT, "header": DIM,
         "color": HIGHLIGHT, "data": DIM, "tail": DIM, "wand": HIGHLIGHT, "beacon": DIM,
         "other": DIM, "error": ALARM}


def _up(s):
    return W._upper(s)


def _tap(fb, c, r, w, h, name):
    """Tap rectangle at least W.TAP_ROWS tall, grown evenly around the visual (as widgets do)."""
    if h < W.TAP_ROWS:
        r -= (W.TAP_ROWS - h) // 2
        h = W.TAP_ROWS
    fb.tap(c, r, w, h, name)


def fit_middle(s, max_cols):
    """s, or its head and tail around '…' (SwiftUI .truncationMode(.middle))."""
    n = vfd.max_chars(max_cols)
    if len(s) <= n:
        return s
    if n <= 1:
        return fit_text(s, max_cols)
    keep = n - 1
    head = (keep + 1) // 2
    return s[:head] + vfd.ELLIPSIS + s[len(s) - (keep - head):]


NBSP = " "
#: Unit words that never start a line when they follow a number ("~21 s", "30 bytes").
_UNITS = {"s", "ms", "sec", "min", "b", "byte", "bytes", "bit", "bits", "db", "dbm", "hz", "khz",
          "pt", "px", "%"}


def _is_unit(word):
    return word.rstrip(",.;:)!?").lower() in _UNITS


def wrap(s, max_cols, size="small"):
    """vfd.wrap_text, except that some spaces never break: a no-break space (U+00A0, drawn as a
    space), the space before a lone separator dot (" · ", so no line starts with '·') and the
    space between a number and its unit ("~21 s", "30 bytes")."""
    words = []
    for word in s.replace(NBSP, "\x00").split(" "):
        if not word:
            continue
        if words and (word == "·" or (words[-1][-1:].isdigit() and _is_unit(word))):
            words[-1] += "\x00" + word
        else:
            words.append(word)
    return [ln.replace("\x00", " ") for ln in vfd.wrap_text(" ".join(words), max_cols, size)]


def wrap_lines(s, max_cols, max_lines=None, size="small"):
    """Word-wrapped lines; with max_lines the last kept line ends with … when text was cut."""
    lines = wrap(s, max_cols, size)
    if max_lines and len(lines) > max_lines:
        lines = lines[:max_lines]
        lines[-1] = fit_text(lines[-1] + " " + "W" * 40, max_cols, size)
    return lines


def title_lines(s, max_cols):
    """A title on one line if it fits, else broken before its "(...)" part (or word-wrapped),
    at most 2 lines."""
    if text_width(s) <= max_cols:
        return [s]
    if " (" in s:
        head, tail = s.split(" (", 1)
        if text_width(head) <= max_cols:
            return [head, fit_text("(" + tail, max_cols)]
    return wrap_lines(s, max_cols, 2)


def sep_lines(parts, max_cols, sep=" · "):
    """Join parts with sep, wrapping only between parts (the separator is dropped at a break, as
    every hint and status wraps); a part longer than a line is word-wrapped on its own."""
    lines, cur = [], ""
    for part in parts:
        cand = (cur + sep + part) if cur else part
        if text_width(cand) <= max_cols:
            cur = cand
            continue
        if cur:
            lines.append(cur)
        if text_width(part) > max_cols:
            wrapped = vfd.wrap_text(part, max_cols)
            lines.extend(wrapped[:-1])
            cur = wrapped[-1] if wrapped else ""
        else:
            cur = part
    if cur:
        lines.append(cur)
    return lines


def lines_block(fb, c, y, lines, color):
    """Draw text lines LINE rows apart. Returns the row after the last line (+ GAP)."""
    for ln in lines:
        fb.text(c, y, ln, "small", color)
        y += W.LINE
    return y + W.GAP if lines else y


# ---------------------------------------------------------------------------------------------
# Pixel pieces
# ---------------------------------------------------------------------------------------------


def round_led(fb, x, y, kind, size=LED, color=HIGHLIGHT):
    """A round LED / swatch (W.led, shared with SCAN's LAST LIGHTS strip)."""
    W.led(fb, x, y, kind, size, color)


def zone_patterns(zones):
    """Per zone pattern index (None for unlit) and the legend [(pattern, NAME)], in Z1..Z5
    first-appearance order (as the SCAN strip)."""
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
    """The band's square face (dim, rounded corners) with its five round LED zones."""
    e = FACE - 1
    fb.hline(x + 4, y, FACE - 8, DIM)
    fb.hline(x + 4, y + e, FACE - 8, DIM)
    fb.vline(x, y + 4, FACE - 8, DIM)
    fb.vline(x + e, y + 4, FACE - 8, DIM)
    for dx, dy in ((2, 1), (3, 1), (1, 2), (1, 3)):          # quarter-round corners
        for cx, cy in ((x + dx, y + dy), (x + e - dx, y + dy), (x + dx, y + e - dy),
                       (x + e - dx, y + e - dy)):
            fb.set(cx, cy, DIM)
    for z, (sc, sr) in enumerate(_ZONE_SPOT):
        round_led(fb, x + _LED_AT[sc], y + _LED_AT[sr], kinds[z] if z < len(kinds) else None)


def updown(fb, c, r, color=DIM):
    """chevron.up.chevron.down beside small caps at row r: an up and a down triangle, 5 x 7
    cells with a blank middle row."""
    for i in range(3):
        fb.hline(c + 2 - i, r + i, 1 + 2 * i, color)
        fb.hline(c + 2 - i, r + 6 - i, 1 + 2 * i, color)


_TRASH = ["..###..", "#######", ".#...#.", ".#.#.#.", ".#.#.#.", ".#.#.#.", ".#...#.", ".#####."]


def trash(fb, c, r, color=DIM):
    """The preset row's bin: 7 x 8 cells with its top-left at (c, r)."""
    for j, row in enumerate(_TRASH):
        for i, ch in enumerate(row):
            if ch == "#":
                fb.set(c + i, r + j, color)


# ---------------------------------------------------------------------------------------------
# Lab controls
# ---------------------------------------------------------------------------------------------

def hairline(fb, L, c, y, w):
    """LabScreenDivider: a solid dim rule with 3 empty rows each side. Returns the next row."""
    fb.hline(c, y + 3, w, DIM)
    return y + 7


def picker_at(fb, x, y, max_w, label, value, name=None):
    """LabPalettePicker at (x, y) on a CTRL_H row: a dim-bordered button "LABEL: VALUE"
    (highlight, truncated with …) and a dim up/down chevron, hugging its text. Returns the end
    column."""
    s = "%s: %s" % (_up(label), _up(value))
    s = fit_text(s, max_w - 21)
    bw = 6 + text_width(s) + 4 + 5 + 6
    fb.box(x, y, bw, W.CTRL_H, DIM)
    end = fb.text(x + 6, y + W.CTRL_TEXT, s, "small", HIGHLIGHT)
    updown(fb, end + 3, y + W.CTRL_TEXT, DIM)
    _tap(fb, x, y, bw, W.CTRL_H, name or "picker:" + _up(label))
    return x + bw


def picker(fb, L, c, y, w, label, value, name=None):
    """A picker on its own row. Returns the next free row."""
    picker_at(fb, c, y, w, label, value, name)
    return y + W.CTRL_H + W.GAP


def toggle_block(fb, L, c, y, w, title, on, detail, title_color=TEXT, enabled=True):
    """A Lab switch row: the title (small, title_color) with the ON/OFF switch on the right, the
    description wrapped full width under it in dim (as given). Returns the next free row."""
    y = W.toggle(fb, L, c, y, w, title, on, enabled=enabled, label_color=title_color,
                 name="toggle:" + _up(title))
    y -= W.GAP - 1
    return lines_block(fb, c, y, wrap(detail, w), DIM)


def framing_toggle(fb, L, c, y, w, title, on, detail):
    """framingToggle: the switch first (left), the title (text, uppercased) beside it, the detail
    wrapped full width under them in dim. Returns the next free row."""
    W.toggle(fb, L, c, y, W.SWITCH_W, "", on, name="toggle:" + _up(title))
    tx = c + W.SWITCH_W + 6
    # a title too wide for the row wraps under itself (beside / just under the switch)
    tlines = title_lines(_up(title), c + w - tx)
    for i, ln in enumerate(tlines):
        fb.text(tx, y + W.CTRL_TEXT + i * W.LINE, ln, "small", TEXT)
    _tap(fb, c, y, w, W.CTRL_H, "toggle:" + _up(title))
    y += max(W.CTRL_H + 1, W.CTRL_TEXT + len(tlines) * W.LINE)
    return lines_block(fb, c, y, wrap(detail, w), DIM)


def caption(fb, L, c, y, w, s):
    """A cyanDim caption over the control(s) under it (dim; with the group gap)."""
    return W.label(fb, L, c, y, w, s)


def note(fb, L, c, y, w, s, color=DIM):
    """techLabel(9) text wrapped full width, as given. Returns the next free row."""
    return lines_block(fb, c, y, wrap(s, w), color)


# ---------------------------------------------------------------------------------------------
# Pinned band preview
# ---------------------------------------------------------------------------------------------

def preview_lines(tw):
    """BandPreviewView's text column (non-compact) plus the colour legend: [(kind, payload)]."""
    p = PREVIEW
    out = [("text", "BAND PREVIEW", DIM)]
    if p["kind"] == "none":
        out.append(("text", "NO EFFECT", DIM))
    else:
        names = {"pulseBurst": "PULSE BURST", "repeatFade": "REPEAT FADE",
                 "centrePulse": "CENTRE PULSE"}
        out.append(("text", names.get(p["kind"], p["kind"].upper()), HIGHLIGHT))
    s = _up(p["note"]) + (" · APPROX." if p["approximate"] else "")
    for ln in wrap_lines(s, tw, 2):
        out.append(("text", ln, TEXT if p["approximate"] else DIM))
    if p["duration_ms"] > 0 or p["always_on"]:
        if p["always_on"]:
            dur = "ALWAYS ON"
        else:
            dur = "~%dS" % (p["duration_ms"] // 1000)
            if p["fade_ms"] > 0:
                dur += " · %dS FADE" % (p["fade_ms"] // 1000)
        out.append(("text", dur, DIM))
    if p["buzz"]:
        out.append(("text", "BUZZ · " + _up(p["buzz"]), HIGHLIGHT))   # the blink's "on" phase
    kinds, legend = zone_patterns(p["zones"])
    if p["kind"] not in ("none", "ping") and legend:
        out.append(("legend", legend, None))
    return out, kinds


def band_preview(fb, L, c, y, w):
    """The pinned BandPreviewView: face on the left, centred on the text column, then the
    divider. Returns the divider row."""
    tx = c + FACE + 8
    tw = c + w - tx
    lines, kinds = preview_lines(tw)
    text_h = (len(lines) - 1) * W.LINE + 7
    top = y + 1
    if PREVIEW["kind"] in ("none", "ping"):
        kinds = [None] * 5
    band_face(fb, c, top + (text_h - FACE) // 2, kinds)
    r = top
    for kind, payload, color in lines:
        if kind == "text":
            fb.text_fit(tx, r, payload, tw, "small", color)
        else:
            x = tx
            for pk, name in payload:
                need = SWATCH + 3 + text_width(name)
                if x + need > tx + tw:
                    if x + SWATCH + 3 + text_width(name[:1] + vfd.ELLIPSIS) <= tx + tw:
                        round_led(fb, x, r, pk, SWATCH)
                        fb.text_fit(x + SWATCH + 3, r, name, tx + tw - x - SWATCH - 3, "small", TEXT)
                    break
                round_led(fb, x, r, pk, SWATCH)
                x = fb.text(x + SWATCH + 3, r, name, "small", TEXT if pk is not None else DIM) + 6
        r += W.LINE
    bottom = top + max(text_h, FACE)
    div = bottom + 3
    fb.hline(c, div, w, DIM)
    return div


# ---------------------------------------------------------------------------------------------
# Builder group: mode bar, PACKET BUILDER
# ---------------------------------------------------------------------------------------------

def mode_bar(fb, L, c, y, w):
    """LabModeBar: Standard / Extended, keep-awake, the PING picker."""
    if EXTENDED:
        y = toggle_block(fb, L, c, y, w, "EXTENDED · EXPERIMENTAL", True,
                         "Adds RGB sliders, single-LED masks and the Experiments list. Untested on a "
                         "band.", title_color=TEXT)
    else:
        y = toggle_block(fb, L, c, y, w, "STANDARD · KNOWN & TESTED", False,
                         "Everything here has been seen working.", title_color=HIGHLIGHT)
    detail = ("Relay scanning paused · streaming pings · SEND goes out for the command interval, "
              "then pings resume" if KEEP_AWAKE else
              "The relay pauses scanning and streams wake pings so the band stays listening "
              "between sends.")
    y = toggle_block(fb, L, c, y, w, "KEEP BAND AWAKE", KEEP_AWAKE, detail,
                     title_color=HIGHLIGHT if KEEP_AWAKE else TEXT,
                     enabled=LINK_READY or KEEP_AWAKE)
    if KEEP_AWAKE or EXTENDED:
        y = picker(fb, L, c, y + 1, w, "PING", PING_NAME)
    return y


def type_section(fb, L, c, y, w):
    """WHAT DO YOU WANT THE BAND TO DO?, the type chips (wrapping), the blurb, the load message."""
    y = caption(fb, L, c, y, w, "WHAT DO YOU WANT THE BAND TO DO?")
    visible = [t for t in TYPES if EXTENDED or not t[2]]
    y = W.options(fb, L, c, y, w, [t[0] for t in visible], SELECTED_TYPE, name="type")
    blurb = dict((t[0], t[1]) for t in TYPES)[SELECTED_TYPE]
    y = note(fb, L, c, y + 1, w, blurb)
    if LOAD_MSG:
        y = note(fb, L, c, y - W.GAP, w, LOAD_MSG, HIGHLIGHT)
    return y


def mid_headline(s, max_cols):
    """The summary headline in mid size: one line if it fits, else broken after the 'Kind:'
    prefix (or word-wrapped), at most 2 lines, the last truncated with …."""
    if text_width(s, "mid") <= max_cols:
        return [s]
    if ": " in s:
        head, tail = s.split(": ", 1)
        return [fit_text(head + ":", max_cols, "mid"), fit_text(tail, max_cols, "mid")]
    return wrap_lines(s, max_cols, 2, "mid")


def summary_card(fb, L, c, y, w):
    """LabPacketSummaryCard: a 1-cell box in the tone colour around YOU ARE BUILDING, the
    headline (mid, tone), the colours (dim), the details (dim, wrapped at ' · ') and the reject
    reason (alarm). Returns the next free row."""
    s = SUMMARY
    tone = {"known": HIGHLIGHT, "unknown": TEXT, "invalid": ALARM}[s["tone"]]
    ic, iw = c + 5, w - 10
    y += 1
    r = y + 4
    fb.text(ic, r, "YOU ARE BUILDING", "small", DIM)
    r += W.LINE + 1
    for ln in mid_headline(_up(s["headline"]), iw - 2):
        if tone == ALARM and fb.alarm_inverted:
            # red-ish base: an inverted block 2 cells around the caps (as widgets.badge)
            fb.fill(ic - 2, r - 2, text_width(ln, "mid") + 4, 18, HIGHLIGHT)
            fb.text(ic, r, ln, "mid", UNLIT)
        else:
            fb.text(ic, r, ln, "mid", tone)
        r += 20
    r -= 1
    if s["colors"]:
        fb.text_fit(ic, r, _up(s["colors"]), iw, "small", DIM)
        r += W.LINE
    for ln in sep_lines([_up(d) for d in s["details"]], iw):
        fb.text(ic, r, ln, "small", DIM)
        r += W.LINE
    if s["reject"]:
        for ln in wrap_lines(s["reject"], iw - 4, 2):
            W.alarm_text(fb, ic, r, ln)
            r += W.LINE
    bottom = r - W.LINE + 7 + 4
    border = {HIGHLIGHT: HIGHLIGHT, TEXT: DIM, ALARM: ALARM}[tone]
    if border == ALARM and fb.alarm_inverted:
        border = HIGHLIGHT
    fb.box(c, y, w, bottom - y + 1, border)
    return bottom + 1 + W.GAP


def color_fields(fb, L, c, y, w):
    """standardFields for the crossfade: COLORS caption, one picker per slot, the BUZZ row."""
    y = caption(fb, L, c, y, w, "COLORS" if len(COLOR_SLOTS) > 1 else "COLOR")
    for lab, val in COLOR_SLOTS:
        y = picker(fb, L, c, y, w, lab, val)
    return buzz_row(fb, L, c, y + 1, w)


def buzz_row(fb, L, c, y, w):
    """BUZZ (dim) + switch, then the PATTERN picker while it is on, on one row."""
    fb.text(c, y + W.CTRL_TEXT, "BUZZ", "small", DIM)
    sx = c + text_width("BUZZ") + 6
    W.toggle(fb, L, sx, y, W.SWITCH_W, "", VIB_ENABLED, name="toggle:BUZZ")
    if VIB_ENABLED:
        px = sx + W.SWITCH_W + 6
        picker_at(fb, px, y, c + w - px, "PATTERN", VIB_PATTERN)
    return y + W.CTRL_H + W.GAP


def framing_section(fb, L, c, y, w):
    """FRAMING: channel marker switch, DURATION picker + its note, wake ping switch."""
    y = caption(fb, L, c, y, w, "FRAMING")
    y = framing_toggle(fb, L, c, y, w, "Channel marker (E1 00)", CHANNEL_MARKER,
                       "Every effect recorded in the park carries this before the effect record. "
                       "The esp32 presets never did. Try both — one may work where the other "
                       "doesn't.")
    y = picker(fb, L, c, y + 1, w, "DURATION", TIMING)
    y = note(fb, L, c, y + 1, w, "How long the band holds the effect — the timing byte. Default "
             "keeps the shape's own value (~21 s for the colour presets).")
    return framing_toggle(fb, L, c, y + 1, w, "Wake ping first (CC03 000100)", WAKE_PREFIX,
                          "Tells nearby bands to listen before the effect arrives. The captured "
                          "show packets all start this way.")


def _seg_lines(seg):
    hx, title, detail, kind = seg
    first = hx if hx else "!"
    extra = ""
    if kind == "color":
        name = detail.split("palette #", 1)[1].split(".", 1)[0] if "palette #" in detail else ""
        extra = _up(name.split(" ", 1)[1]) if " " in name else ""
    return first, extra, _up(title)


def anatomy(fb, L, c, y, w):
    """PACKET ANATOMY — TAP A BLOCK: the blocks flowing left to right, then the selected
    block's explanation. Returns the next free row."""
    y = caption(fb, L, c, y, w, "PACKET ANATOMY — TAP A BLOCK")
    x, row = c, y
    for i, seg in enumerate(ANATOMY):
        first, extra, title = _seg_lines(seg)
        line1 = first + (" " + extra if extra else "")
        inner = min(max(text_width(line1), text_width(title)), w - 8)
        bw = inner + 8
        if x > c and x + bw > c + w:
            x, row = c, row + CHIP_H + 4
        tone = _TONE.get(seg[3], DIM)
        sel = i == SELECTED_SEGMENT
        t1, t2 = row + 3, row + 13
        if sel:
            fb.fill(x, row, bw, CHIP_H, HIGHLIGHT)
            fb.text_fit(x + 4, t1, line1, inner, "small", UNLIT)
            fb.text_fit(x + 4, t2, title, inner, "small", UNLIT)
        else:
            fb.box(x, row, bw, CHIP_H, DIM)
            if tone == ALARM:
                W.alarm_text(fb, x + 4, t1, fit_text(line1, inner))
            else:
                end = fb.text_fit(x + 4, t1, first, inner, "small", tone)
                if extra:
                    fb.text_fit(end + _ADV, t1, extra, x + 4 + inner - end - _ADV, "small", TEXT)
            fb.text_fit(x + 4, t2, title, inner, "small", DIM)
        _tap(fb, x, row, bw, CHIP_H, "anatomy:%d" % i)
        x += bw + 4
    y = row + CHIP_H + W.GAP
    if SELECTED_SEGMENT is not None and 0 <= SELECTED_SEGMENT < len(ANATOMY):
        seg = ANATOMY[SELECTED_SEGMENT]
        tone = _TONE.get(seg[3], DIM)
        lines = wrap(seg[2], w - 8)
        h = 4 + (len(lines) - 1) * W.LINE + 7 + 4
        y += 2
        fb.box(c, y, w, h, DIM)
        r = y + 4
        for ln in lines:
            fb.text(c + 4, r, ln, "small", tone if tone != ALARM else ALARM)
            r += W.LINE
        y += h + W.GAP
    return y


def ghost_button(fb, L, c, y, label_text):
    """A cyanDim bordered button: dim border, text label. Returns its end column."""
    s = _up(label_text)
    bw = text_width(s) + 12
    fb.box(c, y, bw, W.CTRL_H, DIM)
    fb.text(c + 6, y + W.CTRL_TEXT, s, "small", TEXT)
    _tap(fb, c, y, bw, W.CTRL_H, "button:" + s)
    return c + bw


def builder_actions(fb, L, c, y, w):
    """USE IN HEX FIELD (bordered, cyan) and LOAD HEX (bordered, cyanDim), sized to their labels."""
    lab = "USE IN HEX FIELD"
    bw = text_width(lab) + 12
    W.button(fb, L, c, y, bw, lab)
    ghost_button(fb, L, c + bw + 4, y, "LOAD HEX")
    return y + W.CTRL_H + W.GAP


def builder_group(fb, L, c, y, w):
    y = mode_bar(fb, L, c, y, w)
    y = hairline(fb, L, c, y - 1, w)
    y = W.section(fb, L, c, y - (W.SECTION_GAP - W.GAP) + 3, w, "PACKET BUILDER")
    y = note(fb, L, c, y, w, "Pick what the band should do, set the colors, and the card below tells "
             "you exactly what you're sending.")
    y = type_section(fb, L, c, y, w)
    y = summary_card(fb, L, c, y + 2, w)
    y = color_fields(fb, L, c, y, w)
    y = framing_section(fb, L, c, y, w)
    y = anatomy(fb, L, c, y, w)
    return builder_actions(fb, L, c, y + 2, w)


# ---------------------------------------------------------------------------------------------
# Edit group: fields, inspector, SEND / SAVE / TAG
# ---------------------------------------------------------------------------------------------

def dim_field(fb, L, c, y, w, label_text, value, placeholder=""):
    """W.field with its value drawn in dim (.labScreenField(MMTheme.cyanDim)). Returns the next
    free row."""
    return W.field(fb, L, c, y, w, label_text, value, placeholder=placeholder, value_color=DIM)


def packet_fields(fb, L, c, y, w):
    """HEX OUTPUT (value in dim, as iOS), LABEL (value in text) and, under them, the hex's BLE
    advertising reject reason in error red (techLabel(9), 6 pt under the field)."""
    y = dim_field(fb, L, c, y, w, "HEX OUTPUT", LAB_HEX, placeholder="HEX (8301…)")
    y = W.field(fb, L, c, y, w, "LABEL", LAB_LABEL, placeholder="LABEL")
    if HEX_REJECT:
        # 4 empty rows under the box; on a red-ish base the alarm block (2 cells around the caps)
        # still leaves 2. The lines keep 2 cells free on the right for that block.
        y += 2
        for ln in wrap_lines(HEX_REJECT, w - 4, 2):
            W.alarm_text(fb, c, y, ln)
            y += W.LINE
    return y


def byte_list(hex_text):
    clean = [ch for ch in hex_text.upper() if ch in "0123456789ABCDEF"]
    return ["".join(clean[i:i + 2]) for i in range(0, len(clean) - 1, 2)]


def inspector(fb, L, c, y, w):
    """LabPacketInspector: the header line (chevron, PACKET INSPECTOR, n B), classification and
    colours; open: the VIBRATION stepper, RAW BYTES — tap to edit, the byte grid, the hint."""
    data = byte_list(LAB_HEX)
    y += 3
    r = y + W.CTRL_TEXT
    if INSPECTOR_EXPANDED:
        chevron_up(fb, c, r, DIM)
    else:
        W.chevron(fb, c, r, False, DIM)
    cnt = "%d B" % len(data)
    fb.text_right(c + w - 1, r, cnt, "small", DIM)
    fb.text_fit(c + 11, r, "PACKET INSPECTOR", w - 11 - text_width(cnt) - 6, "small", HIGHLIGHT)
    _tap(fb, c, y, w, W.CTRL_H, "inspector")
    y += W.CTRL_H
    if CLASSIFIED:
        label, category, colors = CLASSIFIED
        y = lines_block(fb, c, y, wrap_lines(label + " · " + category, w, 2), HIGHLIGHT) - W.GAP
        if colors.strip():
            y = lines_block(fb, c, y, [fit_text("COLORS: " + _up(colors), w)], DIM) - W.GAP
    else:
        y = lines_block(fb, c, y, ["Unclassified / raw payload"], DIM) - W.GAP
    y += W.GAP
    if not INSPECTOR_EXPANDED:
        return y
    vib = int(data[-1], 16) & 0x0F if data and (int(data[-1], 16) & 0xF0) == 0xB0 else None
    if vib is not None:
        y += 1
        fb.text(c, y + W.CTRL_TEXT, "VIBRATION", "small", DIM)
        x = c + text_width("VIBRATION") + 8
        W.step_button(fb, x, y, False, vib > 0, "vibration:-")
        x += W.STEP_W
        val = "%02d" % vib
        vw = text_width(val) + 8
        fb.text(x + 4, y + W.CTRL_TEXT, val, "small", HIGHLIGHT)
        x += vw
        W.step_button(fb, x, y, True, vib < 15, "vibration:+")
        x += W.STEP_W + 8
        fb.text_fit(x, y + W.CTRL_TEXT, "0xB0 | vib", c + w - x, "small", DIM)
        y += W.CTRL_H + W.GAP
    y = caption(fb, L, c, y, w, "RAW BYTES — tap to edit")
    cols = L.split(8, gap=4, c=c, w=w)
    for i, b in enumerate(data):
        col = i % 8
        if col == 0 and i:
            y += W.CTRL_H + W.GAP
        bx, bw = cols[col]
        fb.box(bx, y, bw, W.CTRL_H, DIM)
        # LabByteCell: cyanDim, quieter than the classification line above
        fb.text(W._cx(bx, bw, b), y + W.CTRL_TEXT, b, "small", DIM)
        _tap(fb, bx, y, bw, W.CTRL_H, "byte:%d" % i)
    y += W.CTRL_H + W.GAP + 1
    return note(fb, L, c, y, w, "Color bytes use low 5 bits (00–1F). E0=preset · 80/80=dual · "
                "A0×5=rainbow · 40/40=xfade · tail B0|vib.")


def action_section(fb, L, c, y, w):
    """SEND (primary, fills the row) + SAVE + TAG, the preset message, the link warning and the
    TX status line."""
    save_w = text_width("SAVE") + 12
    tag_w = text_width("TAG") + 12
    send_w = w - save_w - tag_w - 8
    W.button(fb, L, c, y, send_w, "SEND", primary=True)
    W.button(fb, L, c + send_w + 4, y, save_w, "SAVE")
    W.button(fb, L, c + send_w + 4 + save_w + 4, y, tag_w, "TAG")
    y += W.CTRL_H + W.GAP + 2
    if PRESET_MSG:
        y = lines_block(fb, c, y, [fit_text(PRESET_MSG, w)],
                        HIGHLIGHT if PRESET_MSG.startswith("Saved") else DIM) - W.GAP
    if not LINK_READY:
        for ln in vfd.wrap_text("LINK NOT READY — CONNECT A RELAY ON THE LINK TAB TO SEND", w - 4):
            W.alarm_text(fb, c, y, ln)
            y += W.LINE
    return W.status_line(fb, L, c, y, w, TX_STATUS) + W.GAP


def edit_group(fb, L, c, y, w):
    y = hairline(fb, L, c, y, w)
    y = packet_fields(fb, L, c, y, w)
    y = inspector(fb, L, c, y, w)
    return action_section(fb, L, c, y + 2, w)


# ---------------------------------------------------------------------------------------------
# Extras group: random show, presets, MBLE, Hawkeye themes
# ---------------------------------------------------------------------------------------------

def random_show(fb, L, c, y, w):
    y = W.section(fb, L, c, y, w, "RANDOM LIGHT SHOW")
    y = note(fb, L, c, y, w, "Shoots a surprise packet — colors, duals, fades, rainbows, effects — on "
             "a loop until stopped.")
    frac = (INTERVAL_MS - 500) / float(30000 - 500)
    y = W.slider(fb, L, c, y, w, "INTERVAL MS", "%d" % INTERVAL_MS, frac,
                 hint="Pause between packets (each packet also plays for the command burst time).")
    lab = "STOP SHOW" if RANDOM_SHOW else "START SHOW"
    bw = text_width(lab) + 12
    W.button(fb, L, c, y + 1, bw, lab, primary=True)
    if RANDOM_SHOW:
        cur = RANDOM_SHOW_LABEL.strip() or "Rolling the dice…"
        fb.text_fit(c + bw + 8, y + 1 + W.CTRL_TEXT, _up(cur), w - bw - 8, "small", HIGHLIGHT)
    return y + 1 + W.CTRL_H + W.GAP


def preset_row(fb, L, c, r, w, label_text, hex_text):
    """LabPresetRow: label (text, uppercased) and hex (highlight) like a PacketRow, the bin on the
    right (its own tap), a dotted divider. Rows stack directly; returns the next row's r."""
    bin_x = c + w - TRASH_W - 4
    y = r + 3
    fb.text_fit(c + 2, y, _up(label_text), bin_x - 6 - c - 2, "small", TEXT)
    fb.text_fit(c + 2, y + W.LINE, hex_text, bin_x - 6 - c - 2, "small", HIGHLIGHT)
    trash(fb, bin_x, y + 5, DIM)
    end = y + W.LINE + 7 + 3
    fb.hline(c, end, w, DIM, step=2)
    _tap(fb, c, r, bin_x - 4 - c, end - r, "preset:" + _up(label_text))
    _tap(fb, bin_x - 4, r, c + w - bin_x + 4, end - r, "preset:delete:" + _up(label_text))
    return end + 1


def presets_section(fb, L, c, y, w):
    if not PRESETS:
        return y
    y = hairline(fb, L, c, y, w)
    y = W.section(fb, L, c, y - (W.SECTION_GAP - W.GAP) + 3, w, "MY PRESETS (%d)" % len(PRESETS))
    y -= W.GAP + 2
    for lab, hx in PRESETS:
        y = preset_row(fb, L, c, y, w, lab, hx)
    return y + W.GAP


def mble_section(fb, L, c, y, w):
    y = W.section(fb, L, c, y, w, "MBLE TAP (LIGHTNING LANE)")
    y = W.field(fb, L, c, y, w, None, MBLE_TOKEN, placeholder="VMMS token hex")
    if MBLE_TOKEN.strip():
        if MBLE_PAYLOAD:
            y = lines_block(fb, c, y, wrap_lines("PAYLOAD " + MBLE_PAYLOAD, w, 2), DIM)
        else:
            W.alarm_text(fb, c, y, "MBLE token too short")
            y += W.LINE + W.GAP
    W.button(fb, L, c, y + 1, None, "MBLE ADV", enabled=LINK_READY and MBLE_PAYLOAD is not None)
    return y + 1 + W.CTRL_H + W.GAP


def theme_row(fb, L, c, r, w, title, swatches, hex_text):
    """LabThemeRow: a dim box; the title (text, uppercased) with the swatch colours as their
    #RRGGBB codes (dim) right-aligned beside it, or on a line of their own under the hex when
    both do not fit; the transmit hex (highlight, middle-truncated). Returns the next free row."""
    ic, iw = c + 4, w - 8
    y = r + 4
    sw = " ".join(swatches[:5])
    t = _up(title)
    beside = text_width(t) + 8 + text_width(sw) <= iw
    if beside:
        fb.text_right(ic + iw - 1, y, sw, "small", DIM)
    fb.text_fit(ic, y, t, iw, "small", TEXT)
    y += W.LINE
    fb.text(ic, y, fit_middle(hex_text, iw), "small", HIGHLIGHT)
    if not beside:
        y += W.LINE
        fb.text_fit(ic, y, sw, iw, "small", DIM)
    h = y + 7 + 4 - r
    fb.box(c, r, w, h, DIM)
    _tap(fb, c, r, w, h, "theme:" + _up(title))
    return r + h + 2


def themes_section(fb, L, c, y, w):
    y = W.section(fb, L, c, y, w, "HAWKEYE THEMES", collapsed=THEMES_COLLAPSED)
    if THEMES_COLLAPSED:
        return y
    y = lines_block(fb, c, y, ["TAP SENDS · HOLD LOADS IN LAB"], DIM)
    for title, themes in THEMES:
        y = lines_block(fb, c, y + 2, [title], DIM) - W.GAP + 1
        for t, sw, hx in themes:
            y = theme_row(fb, L, c, y, w, t, sw, hx)
    return y + W.GAP


def extras_group(fb, L, c, y, w):
    y = hairline(fb, L, c, y, w)
    y = random_show(fb, L, c, y - (W.SECTION_GAP - W.GAP) + 3, w)
    y = presets_section(fb, L, c, y, w)
    y = mble_section(fb, L, c, y, w)
    return themes_section(fb, L, c, y, w)


def body(fb, L, c, y, w):
    """Everything in the Lab's ScrollView. Returns the next free row."""
    y = builder_group(fb, L, c, y, w)
    y = edit_group(fb, L, c, y, w)
    return extras_group(fb, L, c, y, w)


# ---------------------------------------------------------------------------------------------
# Scrolling under the pinned preview
# ---------------------------------------------------------------------------------------------

def _probe(fb, draw_fn):
    probe = vfd.FrameBuffer(fb.cols, fb.rows)
    probe.push_clip(0, 0, fb.cols, fb.rows, dy=fb.origin_y)
    end = draw_fn(probe)
    probe.pop_clip()
    return probe, end


def snapped_window(fb, top, bottom, draw_fn):
    """Rows (t, b) of the screen window [top, bottom) the scrolling body may use without cutting a
    glyph: draw_fn(target) is run on a scratch buffer, and while some column is lit on both sides
    of an edge (a glyph stroke, a control's side; long vertical rules excepted) the window edge
    moves inward, so a partly scrolled-off line or control is hidden instead of cut."""
    probe, end = _probe(fb, draw_fn)
    cols = fb.cols
    cells = probe.cells

    def lit(x, r):
        return 0 <= r < fb.rows and cells[r * cols + x] != 0

    def run(x, r):
        a = r
        while lit(x, a - 1):
            a -= 1
        b = r
        while lit(x, b + 1):
            b += 1
        return b - a + 1

    def crossed(k):            # the cut between rows k - 1 and k
        for x in range(cols):
            if lit(x, k - 1) and lit(x, k) and run(x, k) < 40:
                return True
        return False

    t, b = top, bottom
    while t < b and crossed(t):
        t += 1
    while b > t and crossed(b):
        b -= 1
    return t, b, end


def list_scrollbar(fb, top, h, total, scroll):
    """Scroll indicator for the scrolling part only, in the last screen column (as
    widgets.scrollbar): a dotted dim track and a solid dim thumb when the body overflows."""
    if total <= h:
        return
    col = fb.cols - 1
    fb.vline(col, top, h, DIM, step=2)
    th = max(6, h * h // total)
    ty = top + (h - th) * max(0, min(scroll, total - h)) // max(1, total - h)
    fb.vline(col, ty, th, DIM)


def draw(fb, L):
    c, w = L.left, L.width
    scroll = -fb.origin_y                   # frame() pushed the content clip with dy = -scroll

    # The band preview is pinned: undo the scroll for it.
    fb.push_clip(0, L.content_top + scroll, fb.cols, L.content_h, dy=scroll)
    div = band_preview(fb, L, c, L.content_top, w)
    fb.pop_clip()

    top = div + 1                           # first screen row of the scrolling part

    def draw_body(target):
        return body(target, L, c, top + 4, w)

    t, b, end = snapped_window(fb, top, L.content_bottom, draw_body)
    n = len(fb.taps)
    fb.push_clip(0, t - fb.origin_y, fb.cols, b - t)
    draw_body(fb)
    fb.pop_clip()
    fb.taps[n:] = [tp for tp in fb.taps[n:] if tp[3] >= W.TAP_ROWS]

    fb.push_clip(0, L.content_top + scroll, fb.cols, L.content_h, dy=scroll)
    list_scrollbar(fb, top, L.content_bottom - top, end - top, scroll)
    fb.pop_clip()
    return None
