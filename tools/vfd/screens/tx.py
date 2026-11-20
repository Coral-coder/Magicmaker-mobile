"""TX tab on the VFD grid: a port of ios/MagicMaker/Views/TxScreen.swift (narrow layout).

Top to bottom, as on iOS:
    controls (pinned: the list scrolls under them, as the iOS VStack keeps them fixed)
        [VIBRATE] [INTERROGATE]                              MMCompactButton row (label-sized)
        ^ HIDE TX LOOP ............ ON · 3.0S · <LABEL>      loop header (collapsible; up chevron = open)
        LOOP                                     [ON|OFF]    loop toggle (techHeader = highlight label)
        3.0S INTERVAL                                        TxIntervalSlider: one text line over a
        ==o.........................................         61-stop slider, no step buttons
        [CLASS 8/8 v]                                        SectionFilterMenu
        TAP TX · HOLD MENU · SWIPE ← DEL · SWIPE → RECAT     hint (wrapped at the " · " tokens)
        TX LOOP                                              StatusLine(tx.status)
    divider
    library list: MMListSectionHeader per section (chevron, title, 3-digit count), then PacketRows
        (label, hex, "CATEGORY · COLOURS"); the selected row (the loop's packet) is inverted.
        While it scrolls, the header of the section at the top stays pinned under the divider
        (the iOS List is plain-style).

Mock library = store.allTransmitPackets(): the 16 built-in presets (PresetCatalog.swift) plus learned
packets whose labels and hex come from ios/ParityCheck/vectors.json, grouped with the same rules as
LivePacketSort.section(...) and sorted by label inside each section, exactly as the app does.
"""

import widgets as W
import vfd
from vfd import HIGHLIGHT, TEXT, DIM, text_width, fit_text

# Shared with WAND and LOGS, now in widgets.py.
snapped_window, list_scrollbar = W.snapped_window, W.list_scrollbar
token_lines, interval_slider = W.token_lines, W.interval_slider
interval_stop, interval_text, chevron_up = W.interval_stop, W.interval_text, W.chevron_up


TAB = "tx"
TITLE = "TX"

# ---------------------------------------------------------------------------------------------
# Mock state (what TxScreen reads from TxEngine / MagicStore / UserDefaults)
# ---------------------------------------------------------------------------------------------

WAKEUP_PING = "8301CC03000100"

# PresetCatalog.asMagicPackets(): (label, hex, category, typeInfo, colors)
PRESETS = [
    ("Ping (wakeup)", WAKEUP_PING, "SHOW", "ping", ""),
    ("Vibrate band", "8301E905002E0EFBB5", "ANIMATION", "vibrate", ""),
    ("Vibrate (rainbow FX)", "8301CC03000100E100E90C000F0F5D465BF005323748B0", "ANIMATION", "vibrate", ""),
    ("Red", "8301E905002E0EF5B0", "COLOR", "color", ""),
    ("Blue", "8301E905002E0EE2B0", "COLOR", "color", ""),
    ("Cyan", "8301E905002E0EE0B0", "COLOR", "color", ""),
    ("Green", "8301E905002E0EF9B0", "COLOR", "color", ""),
    ("Purple", "8301E905002E0EE5B0", "COLOR", "color", ""),
    ("Pink", "8301E905002E0EE8B0", "COLOR", "color", ""),
    ("White", "8301E905002E0EFBB0", "COLOR", "color", ""),
    ("Orange", "8301E905002E0EF3B0", "COLOR", "color", ""),
    ("Dual YO/Blue", "8301E90600220F8F82B0", "ANIMATION", "effect", ""),
    ("5-LED Rainbow", "8301E909002E0FAFB5B9A2A1B0", "ANIMATION", "effect", ""),
    ("Circle", "8301E90B0B0F0F5C5D48A5D14532B0", "ANIMATION", "effect", ""),
    ("Crossfade R/B", "8301E100E911006F0F554258F44882D1460208D06500B0", "ANIMATION", "effect", ""),
    ("Lightning", "8301CC03000100E100E90C000F0F5D465BF00532374895", "ANIMATION", "effect", ""),
]

# Learned colours / library / raw (labels, hex and colours as MagicClassifier gives them in
# vectors.json). Hex that equals a preset's is left out: allTransmitPackets() dedupes by hex.
LEARNED = [
    # Starlight wand colours -> WAND
    ("Starlight: Blue (#02)", "8301CF9B00C42922EFD819F22A6202", "COLOR", "starlight", "Blue"),
    ("Starlight: Cyan (#00)", "8301CF9B00C42922EFD819F22A6200", "COLOR", "starlight", "Cyan"),
    ("Starlight: Green (#19)", "8301CF9B00C42922EFD819F22A6219", "COLOR", "starlight", "Green"),
    ("Starlight: Midnight Blue (#03)", "8301CF0B00C42922EFD819F22A6203", "COLOR", "starlight",
     "Midnight Blue"),
    ("Starlight: Pink (#0C)", "8301CF0B00C42922EFD819F22A620C", "COLOR", "starlight", "Pink"),
    ("Starlight: Purple (#01)", "8301CF9B00C42922EFD819F22A6201", "COLOR", "starlight", "Purple"),
    ("Starlight: Red (#15)", "8301CF0B00C42922EFD819F22A6215", "COLOR", "starlight", "Red"),
    ("Starlight: Unique (#1E)", "8301CF0B00C42922EFD819F22A621E", "COLOR", "starlight", "Unique"),
    ("Starlight: White (#1B)", "8301CF9B00000000000000000000001BB0", "COLOR", "starlight", "White"),
    # single / dual colours -> COLORS
    ("Dual Color: Pink centre / Lime corners", "8301E90600220F8892B2", "COLOR", "dual", "Pink / Lime"),
    ("Dual Color: Red centre / Blue corners", "8301E90600220F5542B0", "COLOR", "dual", "Red / Blue"),
    ("Dual Color: Yellow Orange centre / Blue corners", "8301E100E906008F0F8F82B3", "COLOR", "dual",
     "Yellow Orange / Blue"),
    ("Single Color: Cyan", "8301CC03000100E100E90500090E00B0", "COLOR", "single", "Cyan"),
    ("Single Color: Lavender", "8301E905002E0EE6B0", "COLOR", "single", "Lavender"),
    ("Single Color: Lime Green", "8301E905002E0EFAB0", "COLOR", "single", "Lime Green"),
    ("Single Color: Midnight Blue", "8301E905002E0EE3B0", "COLOR", "single", "Midnight Blue"),
    ("Single Color: Off", "8301E200E90500010EFDB0", "COLOR", "single", "Off"),
    ("Single Color: Red", "8301E100E905002E0EF5B0", "COLOR", "single", "Red"),
    ("Single Color: White", "8301CC03000100E90500060EFBB3", "COLOR", "single", "White"),
    ("Single Color: Yellow", "8301E905002E0EF1B0", "COLOR", "single", "Yellow"),
    # effects -> ANIMATIONS
    ("5-Zone Colors", "8301E100E909008F0FAFB5B9A2A1B3", "ANIMATION", "e909",
     "Yellow Orange / Red / Green / Blue / Purple"),
    ("Candle Flicker (E90F)", "8301E200E90F00120F40565813488DD2462A1317B0", "ANIMATION", "e90f",
     "Cyan centre / Cyan corners"),
    ("Centre Pulse (E90F)", "8301E100E90F00020F43445801488DD246020100B0", "ANIMATION", "e90f",
     "Midnight Blue centre / Blue corners"),
    ("Comet (E910)", "8301E100E91000194897D00E8ED146060F30D04E1FB0", "ANIMATION", "e910", "Pink"),
    ("Cross-Fade: Cyan / Off", "8301E100E911002B0F405D58F44882D146040FD0650AB0", "ANIMATION", "e911",
     "Cyan / Off"),
    ("Cross-Fade: Pink / Cyan", "8301E100E911006F0F484058F44882D1460208D06500B0", "ANIMATION", "e911",
     "Pink / Cyan"),
    ("Effect: Circle", "8301E90B0B0F0F5F5F40A5D14532B8", "ANIMATION", "e90b", ""),
    ("Repeating Fade (E914)", "8301E100E91400030F5D5458F44882D0650AD1460228307B00B0", "ANIMATION",
     "e914", "Blue"),
    ("Rotating Colors (E912)", "8301E100E91200030FA2A2A4A4A230D037F4D2460064FCB9", "ANIMATION", "e912",
     "Blue / Blue / Blue / Blue / Blue"),
    ("Show: Pirate Cannon", "8301E100E9110003240F55515BF00F10374894D13D0508", "ANIMATION", "e911", ""),
    # show control -> CONTROL
    ("Custom RGB Color", "8301E100E908000ED2557E2800B3", "ANIMATION", "e908", ""),
    ("Show Control: E907", "8301E90700220F555942B0", "ANIMATION", "e907", ""),
    ("Show Control: E90A", "8301E90A002E0FB5B9A2A1B5B9", "ANIMATION", "e90a", ""),
    ("Twinkle / Flash (E90E)", "8301E100E90E00040FB5A2B9AFA159190B48AEB0", "ANIMATION", "e90e",
     "Red / Blue / Green / Yellow Orange / Purple"),
    # pings -> PING
    ("Interaction Ping", "8301CC030001", "SHOW", "ping", ""),
    ("Show Ping (2030)", "8301CC03203000", "SHOW", "ping", ""),
    ("Show Ping (2341)", "8301CC03234100", "SHOW", "ping", ""),
    ("Signal Beacon", "8301CC03000000", "SHOW", "ping", ""),
    # colour cues -> UNKNOWN
    ("Color Cue: Red", "8301EF0501A6001500", "COLOR", "fx_ef05", "Red"),
    ("Color Cue: White", "8301EF0501A6E01B00", "COLOR", "fx_ef05", "White"),
]

SECTIONS = ["WAND", "COLORS", "ANIMATIONS", "CONTROL", "PING", "INTERROGATE", "SHOWS", "UNKNOWN"]
VISIBLE_SECTIONS = set(SECTIONS)           # SectionFilterMenu: every class shown (CLASS 8/8)
COLLAPSED = {"WAND"}                        # tx_collapsed_sections
LOOP_SETTINGS_COLLAPSED = False             # tx_loop_settings_collapsed: open, so its controls show
LOOP_ENABLED = True                         # tx.txLoopEnabled
INTERVAL_SEC = 3.0                          # tx.txLoopIntervalMs / 1000
SELECTED_LABEL = "Dual Color: Red centre / Blue corners"   # tx.txLoopPacketId
STATUS = "TX loop"                          # tx.status after a loop burst

HINT = "TAP TX · HOLD MENU · SWIPE ← DEL · SWIPE → RECAT"


# ---------------------------------------------------------------------------------------------
# App logic ports (LivePacketSort.section, TxLoopInterval)
# ---------------------------------------------------------------------------------------------

def section_of(label, hex_s, category, type_info):
    """LivePacketSort.section(hex:label:typeInfo:category:)."""
    if type_info == "starlight":
        return "WAND"
    if type_info in ("single", "dual"):
        return "COLORS"
    if "show control" in label.lower() or type_info in ("e90e", "e908"):
        return "CONTROL"
    if type_info == "ping" and hex_s == WAKEUP_PING:
        return "INTERROGATE"
    if type_info == "ping":
        return "PING"
    if category == "ANIMATION":
        return "ANIMATIONS"
    if category == "SHOW" or type_info == "show_block":
        return "SHOWS"
    return "UNKNOWN"


def library_groups():
    """allTransmitPackets() (presets first, deduped by hex) grouped in section order, each group
    sorted by label (code-unit order, stable): [(section, [(label, hex, subtitle), ...]), ...]."""
    seen, rows = set(), []
    for label, hex_s, cat, ti, colors in PRESETS + LEARNED:
        if hex_s in seen:
            continue
        seen.add(hex_s)
        subtitle = cat if not colors.strip() else "%s · %s" % (cat, colors)
        rows.append((section_of(label, hex_s, cat, ti), label, hex_s, subtitle))
    out = []
    for sec in SECTIONS:
        items = sorted([r for r in rows if r[0] == sec], key=lambda r: r[1])
        if items:
            out.append((sec, [(lab, hx, sub) for _, lab, hx, sub in items]))
    return out


LOOP_MIN, LOOP_MAX, LOOP_LAST_STOP = W.LOOP_MIN, W.LOOP_MAX, W.LOOP_LAST_STOP


# ---------------------------------------------------------------------------------------------
# Small pieces this screen needs that widgets.py does not have
# ---------------------------------------------------------------------------------------------


# ---------------------------------------------------------------------------------------------
# Screen
# ---------------------------------------------------------------------------------------------

def loop_status_label(groups):
    """"ON · 3.0S · LABEL" while the loop runs, else None."""
    if not LOOP_ENABLED:
        return None
    sec = interval_text(INTERVAL_SEC)
    labels = {lab for _, rows in groups for lab, _, _ in rows}
    if SELECTED_LABEL in labels:
        return "ON · %sS · %s" % (sec, SELECTED_LABEL.upper())
    return "ON · %sS" % sec


def draw_controls(fb, L, groups):
    """The pinned controls block, from L.content_top. Returns the row of the divider under it."""
    c, w = L.left, L.width
    y = L.content_top

    # [VIBRATE] [INTERROGATE]
    y = W.buttons(fb, L, c, y, w, ["VIBRATE", "INTERROGATE"], equal=False)

    # loop header: chevron + "HIDE TX LOOP" / "TX LOOP SETTINGS", loop status right-aligned (dim)
    title = "TX LOOP SETTINGS" if LOOP_SETTINGS_COLLAPSED else "HIDE TX LOOP"
    ty = y + 3
    if LOOP_SETTINGS_COLLAPSED:                 # fold header: dim chevron, highlight title (as
        W.chevron(fb, c, ty, False, DIM)        # W.section and SCAN's HIDE SCAN CONTROLS)
    else:
        chevron_up(fb, c, ty, DIM)
    tx = c + 11
    tend = fb.text(tx, ty, title, "small", HIGHLIGHT)
    status = loop_status_label(groups)
    if status:
        room = c + w - (tend - 1 + 7)
        s = fit_text(status, room)
        fb.text_right(c + w - 1, ty, s, "small", DIM)
    fb.tap(c, y - 1, w, W.TAP_ROWS, "loop:settings")
    y += W.CTRL_H + W.GAP

    if not LOOP_SETTINGS_COLLAPSED:
        y = W.toggle(fb, L, c, y, w, "LOOP", LOOP_ENABLED, label_color=HIGHLIGHT)
        y = interval_slider(fb, L, c, y, w, interval_text(INTERVAL_SEC) + "S INTERVAL", INTERVAL_SEC)

    # SectionFilterMenu
    W.menu_button(fb, L, c, y, "CLASS %d/%d" % (len(VISIBLE_SECTIONS), len(SECTIONS)), name="menu:CLASS")
    y += W.CTRL_H + W.GAP

    # hint, then the status line: it gets the group gap above it (as the iOS VStack spacing sets it
    # apart from the hint), so it reads as its own line, not a third hint line
    y += W.GROUP_GAP
    for line in token_lines(HINT, w):
        fb.text(c, y, line, "small", DIM)
        y += W.LINE
    y += W.GROUP_GAP
    y = W.status_line(fb, L, c, y, w, STATUS, color=DIM)
    return y + 1


# A section header block in the list: SECTION_GAP - GAP rows of air, then the header line and its
# rule (SECTION_H); an open section's first row starts right under it.
HEAD_H = W.SECTION_GAP - W.GAP + W.SECTION_H


def draw_library(fb, L, y, groups, heads=None):
    """The packet list from row y: section headers and PacketRows. Appends (top row, section,
    count, collapsed) of every header block to `heads` if given. Returns the end row."""
    c, w = L.left, L.width
    for sec, rows in groups:
        if sec not in VISIBLE_SECTIONS:
            continue
        collapsed = sec in COLLAPSED
        if heads is not None:
            heads.append((y, sec, len(rows), collapsed))
        y = W.section(fb, L, c, y, w, sec, count=len(rows), collapsed=collapsed)
        if collapsed:
            continue
        y -= W.GAP          # rows sit right under the header rule, as in the List
        for lab, hx, sub in rows:
            y = W.packet_row(fb, L, c, y, w, lab, hx, subtitle=sub, selected=(lab == SELECTED_LABEL),
                             hex_color=DIM)          # stored library hex: PacketRow cyanDim
    return y


def draw(fb, L):
    groups = library_groups()
    scroll = -fb.origin_y           # frame() pushed the content clip with dy = -scroll

    # Controls stay put (iOS keeps them above the List): undo the scroll for them.
    fb.push_clip(0, L.content_top + scroll, fb.cols, L.content_h, dy=scroll)
    div = draw_controls(fb, L, groups)
    fb.hline(L.left, div, L.width, DIM)
    fb.pop_clip()

    # The list scrolls in the rows under the divider; lines cut by the window edges are hidden,
    # and so are their (then too short) tap rectangles.
    list_top = div + 1

    def draw_list(target, heads=None):
        return draw_library(target, L, list_top, groups, heads)

    # Pinned section header (the iOS List is plain-style, so it pins the header of the section
    # at the top): once a header block has scrolled up to list_top it stays drawn there and the
    # list window starts under it. When the next header block moves into the pinned rows (iOS
    # pushes the pinned header out), the pinned one is dropped and the window starts at the next
    # header block instead, so a header is never cut or shown twice.
    heads = []
    draw_list(vfd.FrameBuffer(fb.cols, fb.rows), heads)        # header positions only
    pinned, top = None, list_top
    above = [i for i, hd in enumerate(heads) if hd[0] - scroll <= list_top]
    if above:
        p = above[-1]
        nxt = heads[p + 1][0] - scroll if p + 1 < len(heads) else None
        if nxt is not None and nxt < list_top + HEAD_H:
            top = nxt
        else:
            pinned, top = heads[p], list_top + HEAD_H

    t, b = snapped_window(fb, top, L.content_bottom, draw_list)
    n = len(fb.taps)
    fb.push_clip(0, t - fb.origin_y, fb.cols, b - t)
    end = draw_list(fb)
    fb.pop_clip()
    fb.taps[n:] = [tp for tp in fb.taps[n:] if tp[3] >= W.TAP_ROWS]

    if pinned:
        # drawn at its scroll-0 place; the clip takes one row of the window for its 15-row tap
        # (W.section draws nothing in that row)
        _, sec, count, collapsed = pinned
        fb.push_clip(0, L.content_top + scroll, fb.cols, L.content_h, dy=scroll)
        fb.push_clip(0, list_top, fb.cols, HEAD_H + 1)
        W.section(fb, L, L.left, list_top, L.width, sec, count=count, collapsed=collapsed)
        fb.pop_clip()
        fb.pop_clip()

    # The scroll indicator belongs to the list, not to the whole content region.
    fb.push_clip(0, L.content_top + scroll, fb.cols, L.content_h, dy=scroll)
    list_scrollbar(fb, list_top, L.content_bottom - list_top, end - list_top, scroll)
    fb.pop_clip()
    return None
