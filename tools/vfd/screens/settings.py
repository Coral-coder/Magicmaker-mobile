"""SETTINGS tab in the VFD look: port of ios/MagicMaker/Views/SettingsScreen.swift, plus the
APPEARANCE section the VFD theme adds (BRIEF.md, SKILL.md "Base colour").

Top to bottom:
    the screen header: SETTINGS (the chrome title) and "Global transmission tuning — applies to
      every TX."
    | APPEARANCE (new, first section): THEME [STANDARD] [VFD] | BASE COLOUR [AMBER] [GREEN] [CYAN]
      [BLUE] [RED] [WHITE] [CUSTOM] (shown under the VFD theme), the current one inverted
    | TRANSMISSION SETTINGS (folds; chevron down when folded, up when open, as iOS):
        relay note | TX MODE: SUSTAINED / INTERLEAVE + switch | TX mode hint
        | BROADCAST STRENGTH [MIN] [LOW] [MED] [MAX] + hint
        | WAKE SLICE, COMMAND BURST, STARLIGHT WAND SettingSliders, each with its hint
    | SCAN FILTER: SHOW-CTRL / ALL RAW + switch, hint
    | ABOUT: MAGICMAKER v<version> (<build>)

Re-expressed for the grid:
    * the in-content "SETTINGS" header title is the chrome's mid title; its subtitle opens the
      content in dim, as given.
    * the iOS Toggles are pixel ON/OFF switches; the toggle's label keeps the iOS colour logic
      (cyan -> highlight; ALL RAW is textDim -> dim).
    * the four capsule strength buttons (equal width, the selected one outlined in cyan) are an
      equal 4-column [OPTION] grid with the selected level inverted.
    * SettingSlider: title with the unit moved into it ("WAKE SLICE MS"), the value right-aligned
      in highlight, then [-] LED bar [+], then the dim hint (as given, so "default 520ms" stays).
    * the relay note (cyanDim when an Android relay is linked, textDim otherwise) is dim: the VFD dim
      is the dimmed base colour, and the wording carries the linked / not linked difference.
    * THEME and BASE COLOUR are both left-flowing [OPTION] rows (4 cells apart, wrapping), so the
      APPEARANCE section keeps one left edge; BASE COLOUR wraps to a second row at both widths.
    * BASE COLOUR shows the stored colour as #RRGGBB on its label row (the value a CUSTOM choice
      stores; for a preset, the preset's RGB). The base the preview is rendered in is the one
      selected (see current_base()).
    * the system colour picker that CUSTOM opens is modal and not drawn.

Mock state: the VFD theme on; the Android BLE relay linked (the note says changes are sent to
it); sustained TX mode (switch off), strength MAX (the default); a wake slice at its 520 ms
default, the command burst tuned down to 3000 ms and the starlight burst up to 750 ms (valid
50 / 250 ms steps); the scan filter on (SHOW-CTRL, as on SCAN); version 1.3.0 build 14 from
ios/project.yml.
"""

import sys

import widgets as W
import vfd
from vfd import UNLIT, HIGHLIGHT, TEXT, DIM, ALARM, text_width, fit_text

TAB = "settings"
TITLE = "SETTINGS"

# ---------------------------------------------------------------------------------------------
# Mock state (MagicStore preferences, AppViewModel, ScanEngine, the bundle)
# ---------------------------------------------------------------------------------------------

THEMES = ["STANDARD", "VFD"]
THEME = "VFD"
BASE_PRESETS = ["AMBER", "GREEN", "CYAN", "BLUE", "RED", "WHITE"]
BASE_ITEMS = BASE_PRESETS + ["CUSTOM"]
#: The stored base colour: a preset name or "#RRGGBB" (CUSTOM). None = the base this preview is
#: rendered in, so the selector always matches the colours on screen.
BASE_COLOUR = None

TRANSMISSION_COLLAPSED = False                 # lab_tx_settings_collapsed (default false)
RELAY_BACKEND = "androidBle"                   # RelayBackend raw value
REMOTE_LINK_READY = True
INTERLEAVE = False                             # store.getTxInterleave()
TX_POWER = 3                                   # store.getTxPowerLevel(), 0...3
POWER_NAMES = ["MIN", "LOW", "MED", "MAX"]     # settingsPowerNames

# TransmitTiming (Core/TransmitTiming.swift): default, min, max, slider step
WAKE_DEFAULT, WAKE_MIN, WAKE_MAX, WAKE_STEP = 520, 100, 3000, 50
BURST_DEFAULT, BURST_MIN, BURST_MAX, BURST_STEP = 4000, 500, 12000, 50
STAR_DEFAULT, STAR_MIN, STAR_MAX, STAR_STEP = 500, 250, 5000, 250
PREAMBLE_MS = 520                              # store.getWakeupPreambleMs()
BURST_MS = 3000                                # store.getCommandBurstMs()
STARLIGHT_MS = 750                             # store.getStarlightBurstMs()

SHOW_CONTROL_ONLY = True                       # scan.showControlOnly
APP_VERSION, APP_BUILD = "1.3.0", "14"         # MARKETING_VERSION, CURRENT_PROJECT_VERSION

HEADER_NOTE = "Global transmission tuning — applies to every TX."
STRENGTH_HINT = "Lower = shorter range, fewer nearby bands react · default MAX"
FILTER_HINT = "Filter MagicBand/device noise out of the scan (default on); flip to see all raw."

# ---------------------------------------------------------------------------------------------
# App logic (as SettingsScreen.swift computes it)
# ---------------------------------------------------------------------------------------------


def android_relay_linked():
    """An Android relay (BLE or WiFi) is linked and takes commands; the ESP32 takes only packets."""
    return RELAY_BACKEND != "esp32" and REMOTE_LINK_READY


def relay_note():
    if android_relay_linked():
        return "ANDROID RELAY LINKED — CHANGES ARE SENT TO IT TOO"
    return "TX MODE AND STRENGTH APPLY ON AN ANDROID RELAY"


def tx_mode_hint():
    if INTERLEAVE:
        return ("Alternates wake/command slices — lighter, good in-park. WAKE=slice, "
                "COMMAND=total window.")
    return ("Sustained wake stream, then command stream — strongest wake. WAKE=wake length, "
            "COMMAND=command length.")


def app_version_text():
    return "v%s (%s)" % (APP_VERSION, APP_BUILD)


def frac(value, low, high):
    return (value - low) / float(high - low) if high > low else 0.0


def current_base(fb):
    """The base colour to show as selected: BASE_COLOUR if set, else the base the frame buffer is
    rendered in. FrameBuffer does not record its base, so this reads `fb.base` when present and
    otherwise render_previews.draw_screen()'s `base` argument from the call stack."""
    if BASE_COLOUR is not None:
        return BASE_COLOUR
    base = getattr(fb, "base", None)
    f = sys._getframe(1)
    while base is None and f is not None:
        if f.f_code.co_name == "draw_screen" and "base" in f.f_locals:
            base = f.f_locals["base"]
        f = f.f_back
    return base if base is not None else "AMBER"


def resolve_base(base):
    """(selected item, (r, g, b)): a preset name selects that preset; '#RRGGBB' (or an RGB tuple)
    selects CUSTOM."""
    if isinstance(base, str):
        key = base.strip().upper()
        if key in vfd.PRESETS:
            return key, vfd.PRESETS[key]
        v = int(key.lstrip("#"), 16)
        return "CUSTOM", ((v >> 16) & 255, (v >> 8) & 255, v & 255)
    return "CUSTOM", tuple(int(x) for x in base)


# ---------------------------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------------------------


def up_down_chevron(fb, c, r, up, color=DIM):
    """The transmission header's chevron: a 7 x 4 triangle beside small caps at row r (rows
    r+1..r+4, as widgets.chevron), pointing up when the block is open, down when folded."""
    for i in range(4):
        if up:
            fb.hline(c + 3 - i, r + 1 + i, 2 * i + 1, color)
        else:
            fb.hline(c + i, r + 1 + i, 7 - 2 * i, color)


def disclosure_header(fb, L, c, r, w, title, collapsed):
    """TRANSMISSION SETTINGS: section() geometry with the iOS up / down chevron; the whole line is
    the fold tap."""
    if r > L.content_top:
        r += W.SECTION_GAP - W.GAP
    up_down_chevron(fb, c, r, up=not collapsed)
    fb.text_fit(c + 11, r, W._upper(title), w - 11, "small", HIGHLIGHT)
    fb.hline(c, r + 9, w, DIM)
    W._tap(fb, c, r - 3, w, 14, "section:" + W._upper(title))
    return r + W.SECTION_H + W.GAP


SEP = "·"


def wrap_hint(s, max_cols):
    """Word-wrap a hint whose clauses are joined by " · ". A clause that does not fit on the
    current line but fits a line of its own starts the next line; a longer clause is word-wrapped
    from where the line is. A separator is drawn only between two words on the same line, so no
    line starts or ends with "·" (the line break takes its place). Over-long words are
    hard-broken."""
    n = vfd.max_chars(max_cols)
    if n <= 0:
        return []
    lines, cur = [], ""
    for clause in s.split(" %s " % SEP):
        words = [x for x in clause.split(" ") if x]
        if not words:
            continue
        text = " ".join(words)
        if cur and len(cur) + 3 + len(text) <= n:
            cur += " %s " % SEP + text
            continue
        if cur and len(text) <= n:
            lines.append(cur)
            cur = text
            continue
        first = True
        for word in words:
            joint = (" %s " % SEP) if first else " "
            if cur and len(cur) + len(joint) + len(word) <= n:
                cur += joint + word
            else:
                if cur:
                    lines.append(cur)
                while len(word) > n:
                    lines.append(word[:n])
                    word = word[n:]
                cur = word
            first = False
    if cur:
        lines.append(cur)
    return lines


def hint(fb, L, c, y, w, s):
    """A dim wrapped hint under a control (as given), 1 row lower, the geometry of SettingSlider's
    hint (widgets.slider): lines every LINE rows, then GAP. Returns the next free row."""
    lines = wrap_hint(s, w)
    for i, ln in enumerate(lines):
        fb.text(c, y + 1 + i * W.LINE, ln, "small", DIM)
    return y + 1 + len(lines) * W.LINE + W.GAP if lines else y


def slider(fb, L, c, y, w, title, value, low, high, hint_text, name):
    """SettingSlider: widgets.slider (title + value row, [-] LED bar [+]) with the hint wrapped by
    wrap_hint()."""
    y = W.slider(fb, L, c, y, w, title, value, frac(value, low, high), name=name)
    return hint(fb, L, c, y, w, hint_text)


def appearance(fb, L, c, y, w):
    y = W.section(fb, L, c, y, w, "APPEARANCE")
    y = W.options(fb, L, c, y, w, THEMES, THEME, label_text="THEME")
    if THEME != "VFD":
        return y
    selected, rgb = resolve_base(current_base(fb))
    r = W._group_top(L, y)
    hx = "#%02X%02X%02X" % rgb
    vw = text_width(hx)
    fb.text(c + w - vw, r, hx, "small", HIGHLIGHT)
    fb.text_fit(c, r, "BASE COLOUR", w - vw - 6, "small", DIM)
    # left-flowing like THEME (no columns=: a centred grid would indent [AMBER] off the margin
    # that [STANDARD] starts on), so the whole section shares one left edge
    return W.options(fb, L, c, r + W.LABEL_H, w, BASE_ITEMS, selected,
                     name="option:BASE COLOUR")


def transmission(fb, L, c, y, w):
    y = disclosure_header(fb, L, c, y, w, "TRANSMISSION SETTINGS", TRANSMISSION_COLLAPSED)
    if TRANSMISSION_COLLAPSED:
        return y
    y = W.text_block(fb, L, c, y, w, relay_note(), color=DIM)
    mode = "TX MODE: INTERLEAVE" if INTERLEAVE else "TX MODE: SUSTAINED"
    y = W.toggle(fb, L, c, y, w, mode, INTERLEAVE, label_color=HIGHLIGHT, name="toggle:TX MODE")
    y = hint(fb, L, c, y, w, tx_mode_hint())
    y = W.options(fb, L, c, y, w, POWER_NAMES, TX_POWER, label_text="BROADCAST STRENGTH",
                  columns=len(POWER_NAMES))
    y = hint(fb, L, c, y, w, STRENGTH_HINT)
    y = slider(fb, L, c, y, w, "WAKE SLICE MS", PREAMBLE_MS, WAKE_MIN, WAKE_MAX,
               "Each wake/command slice in the 1:1 interleave · default %dms" % WAKE_DEFAULT,
               "slider:WAKE SLICE")
    y = slider(fb, L, c, y, w, "COMMAND BURST MS", BURST_MS, BURST_MIN, BURST_MAX,
               "Total wake+command interleave window · default %dms · global" % BURST_DEFAULT,
               "slider:COMMAND BURST")
    y = slider(fb, L, c, y, w, "STARLIGHT WAND MS", STARLIGHT_MS, STAR_MIN, STAR_MAX,
               "On-air time for starlight wand TX · no band wakeup · default %dms" % STAR_DEFAULT,
               "slider:STARLIGHT WAND")
    return y


def scan_filter(fb, L, c, y, w):
    y = W.section(fb, L, c, y, w, "SCAN FILTER")
    on = SHOW_CONTROL_ONLY
    y = W.toggle(fb, L, c, y, w, "SHOW-CTRL" if on else "ALL RAW", on,
                 label_color=HIGHLIGHT if on else DIM, name="toggle:SCAN FILTER")
    return hint(fb, L, c, y, w, FILTER_HINT)


def about(fb, L, c, y, w):
    y = W.section(fb, L, c, y, w, "ABOUT")
    fb.text_fit(c, y, "MAGICMAKER " + app_version_text(), w, "small", DIM)
    return y + W.LINE


def draw(fb, L):
    c, w = L.left, L.width
    y = L.content_top
    y = W.text_block(fb, L, c, y, w, HEADER_NOTE, color=DIM)
    y = appearance(fb, L, c, y, w)
    y = transmission(fb, L, c, y, w)
    y = scan_filter(fb, L, c, y, w)
    y = about(fb, L, c, y, w)
    return y
