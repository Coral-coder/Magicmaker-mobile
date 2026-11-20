"""AUTO tab in the VFD look: port of ios/MagicMaker/Views/AutoScreen.swift.

Top to bottom, as on the phone:
    AutoArmHeader (AUTO-RESPONSE / TRIGGER → STACKED TX / RX:n | TX-AUTO:n, arm switch on the right)
    | RULE NAME field | WHEN I HEAR picker field | ADD RESPONSE TO STACK picker field
    | STACK (n) with "1. <response>" rows and a remove × each (only when the stack is not empty)
    | ADD RULE (primary, disabled while the stack is empty)
    | RULES (n): one row per saved rule (name, "<trigger id> → n pkts", enable switch, delete),
      or NO RULES — CONFIGURE STACK ABOVE.

Re-expressed for the grid:
    * the arm Toggle and each rule's Toggle are pixel ON/OFF switches (widgets.toggle's switch).
    * the picker fields (Android's exposed dropdowns) are boxed fields with a pixel down-chevron
      at the right; the value is truncated with … before it.
    * the xmark remove button is a 7 x 7 dim pixel ×; the trash button is a 9 x 10 pixel trash
      can in the alarm colour (an inverted highlight block on a red-ish base).
    * the counter line's " | " is drawn as the telemetry line draws it (a 9-row bar).
    * the rule list gets dotted dim dividers between rows; the RULES (n) title gets the section rule.
    * a dim rule closes the arm header off from the rule builder (iOS does that with the bolder
      header type), so its dim counter line does not read as the RULE NAME caption's neighbour.
    * the option picker sheet and the delete confirmation are modal and not drawn.

Mock state: auto-response armed (matches the telemetry line RX:1284 | TX-AUTO:3), a rule being
built on the default trigger ("Any starlight wand (any color)") with Vibrate band and Rainbow
finale stacked, and four saved rules. Trigger / response labels and ids are the real system ones
from ios/MagicMaker/Core/PacketPatterns.swift; the learned / preset ids follow PacketPatterns'
"learned_t_<id>" / "preset_t_<id>" form; a rule's subtitle shows the raw trigger id, as the app does.
"""

import widgets as W
import vfd
from vfd import UNLIT, HIGHLIGHT, TEXT, DIM, ALARM, text_width, fit_text

TAB = "auto"
TITLE = "AUTO"

# ---------------------------------------------------------------------------------------------
# Mock state (ScanEngine counters, the builder's @State, MagicStore.autoRules)
# ---------------------------------------------------------------------------------------------

AUTO_ENABLED = True                 # scan.autoEnabled
PACKETS_HEARD = 1284                # scan.packetsHeard (telemetry RX:1284)
AUTO_RESPONSES_SENT = 3             # scan.autoResponsesSent (telemetry TX-AUTO:3)

#: PacketPatterns.systemTriggers (id -> label)
SYSTEM_TRIGGERS = {
    "ping_fast": "Interaction ping (fast mode)",
    "ping_prefix": "Any CC03 ping",
    "starlight": "Any starlight wand (any color)",
    "newwand": "Any New Wand code (CF0B)",
    "e905": "Any single color (E905)",
    "e90c": "Any animation (E90C)",
    "rainbow": "Taste the Rainbow",
    "any_raw": "Any unclassified packet",
}
#: PacketPatterns.systemResponses (id -> label)
SYSTEM_RESPONSES = {
    "resp_wakeup": "Wakeup ping",
    "resp_vibrate": "Vibrate band",
    "resp_rainbow": "Rainbow finale",
    "resp_newwand_random": "New Wand: RANDOM code",
}

RULE_NAME = "Wand buzz"             # ruleName (default "My rule")
TRIGGER_ID = "starlight"            # triggerId (default: systemTriggers[2])
PICK_RESPONSE_ID = "resp_rainbow"   # pickResponseId: the last response picked
RESPONSE_STACK = ["resp_vibrate", "resp_rainbow"]

#: store.autoRules: (name, triggerPatternId, number of response hexes, enabled)
RULES = [
    ("Ping echo", "ping_fast", 1, True),
    ("Rainbow reply", "rainbow", 2, True),
    ("Lightning chaser", "learned_t_57", 3, False),
    ("Swap new wands", "newwand", 1, True),
]

# ---------------------------------------------------------------------------------------------
# Small helpers (Swift: the same names on the VFD screen type)
# ---------------------------------------------------------------------------------------------

#: 9 x 10 trash can (lid with handle, body with three slots)
TRASH = [
    "...###...",
    "#########",
    ".........",
    ".#######.",
    ".#.#.#.#.",
    ".#.#.#.#.",
    ".#.#.#.#.",
    ".#.#.#.#.",
    ".#.#.#.#.",
    ".#######.",
]
ICON_BTN = 13           # square cell a pixel icon button is centred in (as W.STEP_W)


def trigger_label(tid):
    """triggerLabel(): the option's label, or the id itself when no option has it."""
    return SYSTEM_TRIGGERS.get(tid, tid)


def response_label(rid):
    """responseLabel(): the option's label, or the id itself."""
    return SYSTEM_RESPONSES.get(rid, rid)


def describe(trigger_id, n_hexes):
    """AutoRuleRow.describe(): "<trigger id> → n pkt(s)", a stackless rule counting as one."""
    n = max(n_hexes, 1)
    return "%s → %d pkt%s" % (trigger_id, n, "" if n == 1 else "s")


def _tap(fb, c, r, w, h, name):
    """Tap rectangle at least W.TAP_ROWS tall, grown evenly around the visual (as widgets do)."""
    if h < W.TAP_ROWS:
        r -= (W.TAP_ROWS - h) // 2
        h = W.TAP_ROWS
    fb.tap(c, r, w, h, name)


def bitmap(fb, x, y, rows, color):
    """Light the '#' cells of a small pixel-art bitmap with its top-left at (x, y)."""
    for j, line in enumerate(rows):
        for i, ch in enumerate(line):
            if ch == "#":
                fb.set(x + i, y + j, color)


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


def switch(fb, L, x, r, on, name, enabled=True):
    """A bare pixel ON/OFF switch (W.SWITCH_W x W.CTRL_H) with its top-left at (x, r): the
    switch of widgets.toggle with no label. Taps `name`."""
    W.toggle(fb, L, x, r, W.SWITCH_W, "", on, enabled=enabled, name=name)


def remove_x(fb, x, y, name):
    """The stack row's xmark: a 7 x 7 dim ×, centred in an ICON_BTN square at (x, y)."""
    ox, oy = x + (ICON_BTN - 7) // 2, y + (ICON_BTN - 7) // 2
    for i in range(7):
        fb.set(ox + i, oy + i, DIM)
        fb.set(ox + 6 - i, oy + i, DIM)
    _tap(fb, x - 1, y, ICON_BTN + 2, ICON_BTN, name)


def trash_button(fb, x, y, name, tap=None):
    """The rule's delete button: the pixel trash can in the alarm colour, centred in an ICON_BTN
    square at (x, y); on a red-ish base a solid highlight square with the can cut out. `tap` is the
    (c, r, w, h) hit rectangle the caller gives it (rule_row: the whole row height, from just past
    the switch to the screen edge); default the icon square padded 1 column each side."""
    ox, oy = x + (ICON_BTN - 9) // 2, y + (ICON_BTN - 10) // 2
    if fb.alarm_inverted:
        fb.fill(x, y, ICON_BTN, ICON_BTN, HIGHLIGHT)
        bitmap(fb, ox, oy, TRASH, UNLIT)
    else:
        bitmap(fb, ox, oy, TRASH, ALARM)
    _tap(fb, *(tap or (x - 1, y, ICON_BTN + 2, ICON_BTN)), name)


def picker_field(fb, L, c, y, w, caption, value):
    """AutoPickerField: the caption (W.label, dim) and a boxed read-only field with the value in
    text, truncated with …, and a dim down-chevron 2 cells inside the right border. Tapping it
    opens the option list. Returns the next free row."""
    shown = fit_text(value, w - 18)
    y0 = W._group_top(L, y) + W.LABEL_H
    nxt = W.field(fb, L, c, y, w, caption, shown, name="picker:" + W._upper(caption))
    W.chevron(fb, c + w - 10, y0 + W.CTRL_TEXT + 1, False, DIM)
    return nxt


# ---------------------------------------------------------------------------------------------
# Sections of the screen
# ---------------------------------------------------------------------------------------------

def arm_header(fb, L, c, y, w):
    """AutoArmHeader: AUTO-RESPONSE (highlight), TRIGGER → STACKED TX (dim) and the counters
    RX:n | TX-AUTO:n (dim) on three lines, the arm switch right-aligned and centred on them.
    Returns the next free row."""
    sx = c + w - W.SWITCH_W
    tw = sx - 6 - c
    r = y + 1
    fb.text_fit(c, r, "AUTO-RESPONSE", tw, "small", HIGHLIGHT)
    fb.text_fit(c, r + W.LINE, "TRIGGER → STACKED TX", tw, "small", DIM)
    tokens(fb, c, r + 2 * W.LINE, ["RX:%d" % PACKETS_HEARD, "TX-AUTO:%d" % AUTO_RESPONSES_SENT],
           DIM, c + tw)
    block_end = r + 2 * W.LINE + 7                       # last caps row + 1
    sy = r + (block_end - r - W.CTRL_H) // 2
    switch(fb, L, sx, sy, AUTO_ENABLED, "toggle:AUTO-RESPONSE")
    return block_end + W.GAP


def hairline(fb, L, c, y, w):
    """A solid dim rule with 3 empty rows above it, closing the arm header off from the rule
    builder (on iOS the bolder header type does that). Returns the next free row."""
    fb.hline(c, y + 1, w, DIM)
    return y + 2


def stack_block(fb, L, c, y, w):
    """STACK (n): the caption, then one CTRL_H row per stacked response, "n. <label>" in text
    (truncated) with the remove × at the right. Returns the next free row."""
    y = W.label(fb, L, c, y, w, "Stack (%d)" % len(RESPONSE_STACK))
    for i, rid in enumerate(RESPONSE_STACK):
        bx = c + w - ICON_BTN
        fb.text_fit(c, y + W.CTRL_TEXT, "%d. %s" % (i + 1, response_label(rid)), bx - 4 - c,
                    "small", TEXT)
        remove_x(fb, bx, y, "stack:remove:%d" % i)
        y += W.CTRL_H + W.GAP
    return y


def rule_row(fb, L, c, y, w, rule, idx):
    """AutoRuleRow: the name (text) over its description (dim), the enable switch and the trash
    button on the right, both centred on the two lines; a dotted dim divider closes the row.
    The delete tap covers the whole row height (y .. the divider), from 1 column past the switch
    through the empty right margin to the screen edge, as the < BACK tap does on the left: 19 x 25
    cells, i.e. 32 x 42 pt at 3x and 38 x 50 pt at 2x, at least the iOS 32 x 32 pt button.
    Rows stack directly: returns the next row's top."""
    name, trig, n, enabled = rule
    tx_ = c + w - ICON_BTN
    sx = tx_ - 4 - W.SWITCH_W
    tw = sx - 6 - c
    r1, r2 = y + 3, y + 3 + W.LINE
    fb.text_fit(c + 2, r1, name, tw - 2, "small", TEXT)
    fb.text_fit(c + 2, r2, describe(trig, n), tw - 2, "small", DIM)
    mid = (r1 + r2 + 7) // 2                       # centre of the two caps lines
    switch(fb, L, sx, mid - W.CTRL_H // 2, enabled, "rule:toggle:%d" % idx)
    d = r2 + 7 + 3
    tc = sx + W.SWITCH_W + 1
    trash_button(fb, tx_, mid - ICON_BTN // 2, "rule:delete:%d" % idx,
                 tap=(tc, y, fb.cols - tc, d - y + 1))
    fb.hline(c, d, w, DIM, step=2)
    return d + 1


def rules_block(fb, L, c, y, w):
    """RULES (n) and the rule rows, or NO RULES — CONFIGURE STACK ABOVE. Returns the end row."""
    y = W.section(fb, L, c, y, w, "Rules (%d)" % len(RULES))
    if not RULES:
        return W.status_line(fb, L, c, y + 1, w, "NO RULES — CONFIGURE STACK ABOVE")
    y -= W.GAP + 1
    for i, rule in enumerate(RULES):
        y = rule_row(fb, L, c, y, w, rule, i)
    return y


def draw(fb, L):
    c, w = L.left, L.width
    y = L.content_top
    y = arm_header(fb, L, c, y, w)
    y = hairline(fb, L, c, y, w)
    y = W.field(fb, L, c, y, w, "Rule name", RULE_NAME, placeholder="Rule name")
    y = picker_field(fb, L, c, y, w, "When I hear", trigger_label(TRIGGER_ID))
    y = picker_field(fb, L, c, y, w, "Add response to stack", response_label(PICK_RESPONSE_ID))
    if RESPONSE_STACK:
        y = stack_block(fb, L, c, y, w)
    y = W.button(fb, L, c, y + 2, None, "Add rule", primary=True, enabled=bool(RESPONSE_STACK))
    y = rules_block(fb, L, c, y, w)
    return y
