"""DIAG tab in the VFD look: port of ios/MagicMaker/Views/DiagScreen.swift.

Top to bottom, as on the phone (one List):
    STATUS (MMSectionTitle) | DiagStatusRow "KEY  value" lines: BLUETOOTH, SCAN, LOG, LOCATION
      | RX, LIGHTS, AUTO, TX-AUTO | RELAY, TX
    | the crash header: CRASH LOG · CLEAN (dim) or CRASH LOG · HAS ENTRIES with SHARE and CLEAR
      | the crash text box (the newest 4000 characters) while it is open
    | divider, BROADCAST SOURCES · n, PRIORITY = SENT SHOW/ANIM/COLOR, divider
    | PRIORITY (n) section with one DiagSourceRow per source | OTHER (n) section (folded by default)
      | or NO SOURCES — START A SCAN when nothing has been heard.

Re-expressed for the grid:
    * DiagStatusRow keeps its fixed key column (10 cells of text, the longest key BLUETOOTH plus a
      space). iOS gives the value about 280 pt, so every real value shows in full there; the grid's
      value column is narrower (28 characters at 241 columns, 22 at 207), so a value that does not
      fit wraps to a second line in the value column (breaking after a " · " / " — " separator when
      that fits, else between words; only a third line is cut with …). The LOG file name alone keeps
      iOS's middle truncation (.truncationMode(.middle)), so its timestamp tail stays visible.
      iOS colours map as: textPrimary -> text, cyan (on / linked) -> highlight, textDim -> dim,
      amber (not ready, not linked, send failed) -> alarm (an inverted block per line on a red-ish
      base, with the 1-row gap between lines kept).
    * the crash header's text buttons SHARE (cyan on iOS) / CLEAR (amber on iOS) are compact
      bordered buttons, right-aligned: SHARE in the normal highlight border, CLEAR (destructive) in
      the alarm colour, as the amber HAS ENTRIES (a solid block, label cut out, on a red-ish base).
      When the label and both buttons do not fit one row (at 207 columns) the buttons drop to a
      row of their own under the label. HAS ENTRIES is drawn as an alarm.
    * the crash text box (a 220 pt scrolling Text) is a dim 1-cell box CRASH_LINES lines tall with
      the log tail wrapped in dim; when the tail is longer than the box, its scroll thumb is drawn
      in highlight on the box's right border (no separate track inside the box).
    * the MMListSectionHeaders are section() headers with a chevron and a 3-digit count.
    * DiagSourceRow: the address (highlight for a priority source, cyan on iOS; dim otherwise) with
      BEST n · NOW n right-aligned in dim, then n PKTS · <categories> in dim, then a dotted dim
      divider (the hairline). The unit moves to the label row: RSSI DBM is right-aligned in dim on
      the BROADCAST SOURCES · n line, above the readings.
    * the delete confirmation and the share sheet are modal and not drawn.

Mock state: Bluetooth ready, scanning and recording a log (the same file as SCAN), auto-response
armed, the Android BLE relay linked; the counters match the telemetry line (RX:1284, TX-AUTO:3,
LIGHTS:37). The crash log holds two entries (a store save error and a fatal signal) and is folded,
the iOS default. Sources are the park transmitters, the guest wands and the user's own band from
SCAN (same CoreBluetooth identifiers, counts and current RSSI as its HEARD row), priority ones
first then by packet count, plus 16 unclassified sources in the folded OTHER section. Category
names are MagicCategory raw values (pings classify as SHOW, starlight wands as COLOR).
"""

import widgets as W
import vfd
from vfd import UNLIT, HIGHLIGHT, TEXT, DIM, ALARM, text_width, fit_text

TAB = "diag"
TITLE = "DIAG"
# TELEMETRY: render_previews.DEFAULT_TELEMETRY, the one line every tab shares.

# ---------------------------------------------------------------------------------------------
# Mock state (ScanEngine, TxEngine, AppViewModel, LocationTracker, MagicStore, CrashLog)
# ---------------------------------------------------------------------------------------------

BLUETOOTH_STATUS = "Bluetooth ready"           # BleCentral.stateDescription
SCAN_ACTIVE = True
RECORDING = True                               # scan.recordSessionActive
ACTIVE_SESSION = "scan_2026-11-19T21-42-07.csv"  # store.activeSessionName (SessionLog.fileName)
LOCATION_STATUS = "Location ready"             # LocationTracker.authorizationDescription
LOCATION_AUTHORIZED = True
PACKETS_HEARD = 1284                           # telemetry RX:1284
LIGHTS_HEARD = 37                              # telemetry LIGHTS:37
AUTO_ENABLED = True
AUTO_RESPONSES_SENT = 3                        # telemetry TX-AUTO:3
RELAY_BACKEND = "Android BLE"                  # RelayBackend.label
REMOTE_LINK_READY = True
TX_STATUS = "Scanning"                         # TxEngine.status
TX_NOT_LINKED = "No relay linked — nothing sent"
TX_SEND_FAILED = "Transmit failed — check relay"

#: Documents/crash_log.txt as CrashLog writes it ("\n===== MM-dd HH:mm:ss · tag =====\n" + body).
CRASH_LOG = (
    "\n===== 11-18 23:07:41 · MagicStore.save =====\n"
    "CocoaError: The file “magicmaker_store.json” couldn’t be saved because there isn’t enough"
    " space.\n"
    "Error Domain=NSCocoaErrorDomain Code=640 \"The file “magicmaker_store.json” couldn’t be saved"
    " because there isn’t enough space.\" UserInfo={NSUnderlyingError=0x283e1c5a0 {Error"
    " Domain=NSPOSIXErrorDomain Code=28 \"No space left on device\"}}\n"
    "\n===== 11-19 20:58:12 · SIGNAL SIGTRAP =====\n"
    "The app was stopped by a fatal signal.\n"
)
CRASH_TAIL = 4000                              # diagCrashTailLength
CRASH_COLLAPSED = True                         # @State crashCollapsed (default true)
CRASH_LINES = 12                               # text lines the open box shows (220 pt ~ 12 lines)

PRIORITY_COLLAPSED = False                     # @State priorityCollapsed (default false)
OTHER_COLLAPSED = True                         # @State otherCollapsed (default true)

# The same CoreBluetooth identifiers as SCAN (park show transmitters, guests' wands, my band).
SHOW_A = "0B6F2E91-7C44-4D0A-B8E2-5A90C41E9A07"
SHOW_B = "D2F17A3C-9B05-4E68-A1C7-3E2F7B2D5F13"
SHOW_C = "8A43C6E0-1F7D-4B92-9D35-C8B1E06A3B98"
WAND_1 = "4E9D0A72-63B8-4C1F-8A2E-F07D51F8C2D4"
WAND_2 = "B71C5E08-2A96-47D3-BE41-9D6A3C70E85A"
WAND_3 = "19E4B6D3-C870-4A25-93F1-6B2E8F4D17C6"
MY_BAND = "5C0E8B47-2D1A-4F3C-9E06-11B4A7D3901B"


def _src(address, count, best, last, categories):
    cats = sorted(categories)
    prio = any(cat in ("SHOW", "ANIMATION", "COLOR") for cat in cats)
    return {"address": address, "count": count, "bestRssi": best, "lastRssi": last,
            "priority": prio, "categories": cats}


#: scan.sources, already sorted by the engine: priority first, then packet count, then best RSSI.
SOURCES = [
    _src(SHOW_A, 389, -52, -58, ["SHOW", "COLOR", "ANIMATION"]),
    _src(SHOW_B, 241, -61, -66, ["SHOW", "COLOR", "ANIMATION"]),
    _src(MY_BAND, 212, -38, -41, ["SHOW"]),
    _src(SHOW_C, 133, -70, -77, ["COLOR", "ANIMATION"]),
    _src(WAND_1, 57, -64, -71, ["COLOR"]),
    _src(WAND_3, 31, -69, -74, ["COLOR"]),
    _src(WAND_2, 12, -79, -83, ["COLOR"]),
    # rotating private addresses that only sent unclassified 0x0183 adverts
    _src("1D84C2F0-E2A7-41C9-B3D0-6F1A92C4E70B", 96, -72, -81, ["UNKNOWN"]),
    _src("9A3E7B15-7C31-4A8E-9F25-D04B6E1385AF", 71, -75, -79, ["UNKNOWN"]),
    _src("F062D84C-3B9F-4E02-A6C7-58D1F3A90C26", 44, -77, -88, ["UNKNOWN"]),
    _src("2C7B1E93-A05D-47B3-8E61-C2F9047BD851", 38, -80, -84, ["UNKNOWN"]),
    _src("85E0A4D7-6E48-4F1D-B279-0AC53D8E6F14", 27, -78, -90, ["UNKNOWN"]),
    _src("4F19C6B2-D917-42A0-9C8B-E6F21B07A3C9", 19, -83, -86, ["UNKNOWN"]),
    _src("B8D3507E-0F6C-4B85-A3E2-791DC48B25E0", 15, -81, -92, ["UNKNOWN"]),
    _src("6A2F91C8-B4E2-4C76-8D19-F5A03E6C9D72", 11, -85, -89, ["UNKNOWN"]),
    _src("E31B7D46-58A1-4D3F-B6C0-2E97F1B04A6D", 9, -84, -91, ["UNKNOWN"]),
    _src("0C95A2F3-C7D3-4E91-A25B-03F8D6E21C47", 7, -87, -93, ["UNKNOWN"]),
    _src("73E4C8B1-2F90-41A6-9E3D-B85C04A7F913", 6, -86, -88, ["UNKNOWN"]),
    _src("D5A80F62-91B6-4C0E-87F2-D3A15E9C60B8", 4, -88, -94, ["UNKNOWN"]),
    _src("28C6E3A9-E5C8-4A27-B0D6-1F43C8A9E25D", 3, -90, -92, ["UNKNOWN"]),
    _src("9F0B4D17-4AD0-4F63-9B1E-C72E50D83F19", 2, -91, -95, ["UNKNOWN"]),
    _src("5B71E2C0-7E15-4B98-A4C3-E0F69B2D41A7", 2, -89, -96, ["UNKNOWN"]),
    _src("A4E93F58-C03B-4D52-8F7A-196E2B5C08D4", 1, -93, -93, ["UNKNOWN"]),
]

KEY_W = 10 * 6          # DiagStatusRow key column: 10 characters of small text (76 pt on iOS)

# ---------------------------------------------------------------------------------------------
# App logic (DiagStatusBlock / DiagSourceRow, as Swift computes them)
# ---------------------------------------------------------------------------------------------


def on_off_color(on):
    """onOffColor: cyan when on, textDim when off."""
    return HIGHLIGHT if on else DIM


def log_text():
    if not RECORDING:
        return "OFF"
    if not ACTIVE_SESSION:
        return "REC"
    return "REC · " + ACTIVE_SESSION


def relay_text():
    return RELAY_BACKEND.upper() + " · " + ("LINKED" if REMOTE_LINK_READY else "NOT LINKED")


def status_rows():
    """(key, value, colour, middle) in DiagStatusBlock order: radio, counters, link. middle=True
    (the LOG file name only) keeps iOS's middle truncation; every other value wraps."""
    bt_ok = BLUETOOTH_STATUS == "Bluetooth ready"
    tx_bad = TX_STATUS in (TX_NOT_LINKED, TX_SEND_FAILED)
    return [
        ("BLUETOOTH", BLUETOOTH_STATUS.upper(), TEXT if bt_ok else ALARM, False),
        ("SCAN", "ON" if SCAN_ACTIVE else "OFF", on_off_color(SCAN_ACTIVE), False),
        ("LOG", log_text(), on_off_color(RECORDING), True),
        ("LOCATION", LOCATION_STATUS.upper(), TEXT if LOCATION_AUTHORIZED else ALARM, False),
        ("RX", str(PACKETS_HEARD), TEXT, False),
        ("LIGHTS", str(LIGHTS_HEARD), TEXT, False),
        ("AUTO", "ARM" if AUTO_ENABLED else "OFF", on_off_color(AUTO_ENABLED), False),
        ("TX-AUTO", str(AUTO_RESPONSES_SENT), TEXT, False),
        ("RELAY", relay_text(), HIGHLIGHT if REMOTE_LINK_READY else ALARM, False),
        ("TX", TX_STATUS.upper(), ALARM if tx_bad else TEXT, False),
    ]


def crash_blank():
    return not CRASH_LOG.strip()


def short_address(address):
    """shortAddress: the last 8 characters, uppercased."""
    return address[-8:].upper() if address else ""


def address_text(src):
    tail = short_address(src["address"])
    return tail if tail else "(unknown)"


def rssi_text(src):
    """The readings only; the unit is in the label row (RSSI DBM on the sources header)."""
    return "BEST %d · NOW %d" % (src["bestRssi"], src["lastRssi"])


def counts_text(src):
    return "%d PKTS · %s" % (src["count"], " ".join(src["categories"]))


# ---------------------------------------------------------------------------------------------
# Drawing helpers
# ---------------------------------------------------------------------------------------------


def fit_middle(s, max_cols):
    """s unchanged if it fits in max_cols cells, else its head and tail around a '…' (SwiftUI's
    .truncationMode(.middle)); the head gets the odd character."""
    n = vfd.max_chars(max_cols)
    if len(s) <= n:
        return s
    if n < 3:
        return fit_text(s, max_cols)
    keep = n - 1
    head = (keep + 1) // 2
    tail = keep - head
    return s[:head].rstrip() + vfd.ELLIPSIS + s[len(s) - tail:].lstrip()


#: Clause separators a wrapped status value prefers to break after (kept at the line end).
VALUE_SEPS = (" · ", " — ")
VALUE_LINES = 2                 # most lines a status value wraps to; the last one is cut with …


def wrap_value(s, max_cols, max_lines=VALUE_LINES):
    """Lines of a status value in a column max_cols cells wide: [s] if it fits; else, when one
    break right after a " · " / " — " separator gives two lines that fit, that break (the separator
    ends the first line, so "ANDROID BLE ·" / "NOT LINKED" stays one reading); else a word wrap
    (vfd.wrap_text). Past max_lines the rest is joined onto the last line and cut with …."""
    n = vfd.max_chars(max_cols)
    if len(s) <= n:
        return [s]
    best = None
    for sep in VALUE_SEPS:
        i = s.find(sep)
        while i >= 0:
            head = s[:i] + " " + sep.strip()
            tail = s[i + len(sep):].strip()
            if len(head) <= n and len(tail) <= n and (best is None or len(head) > len(best[0])):
                best = (head, tail)
            i = s.find(sep, i + 1)
    if best and max_lines >= 2:
        return list(best)
    lines = vfd.wrap_text(s, max_cols)
    if len(lines) > max_lines:
        lines = lines[:max_lines - 1] + [fit_text(" ".join(lines[max_lines - 1:]), max_cols)]
    return lines


def status_row(fb, L, c, y, w, key, value, color, middle=False):
    """DiagStatusRow: the key in dim in a fixed column, the value after it: middle-truncated on
    one line when middle=True (the LOG file name), else wrapped to at most VALUE_LINES lines in the
    value column (wrap_value). Returns the row after the last line (y + lines * LINE)."""
    fb.text_fit(c, y, key, KEY_W - 6, "small", DIM)
    vx = c + KEY_W
    alarm = color == ALARM
    vw = c + w - vx - (4 if alarm else 0)          # an alarm block takes 2 cells each side
    lines = [fit_middle(value, vw)] if middle else wrap_value(value, vw)
    for ln in lines:
        if alarm and fb.alarm_inverted:
            # inverted block 1 row above the caps and 2 below (10 rows), so alarm lines one LINE
            # apart (a wrapped value, or RELAY then TX) keep a 1-row gap instead of merging
            fb.fill(vx, y - 1, text_width(ln) + 4, 10, HIGHLIGHT)
            fb.text(vx + 2, y, ln, "small", UNLIT)
        elif alarm:
            W.alarm_text(fb, vx, y, ln)
        else:
            fb.text(vx, y, ln, "small", color)
        y += W.LINE
    return y


def status_block(fb, L, c, y, w):
    y = W.section(fb, L, c, y, w, "STATUS")
    for key, value, color, middle in status_rows():
        y = status_row(fb, L, c, y, w, key, value, color, middle)
    return y


def alarm_button(fb, L, c, r, w, label):
    """A destructive compact button (CLEAR, amber on iOS): W.button()'s footprint with the border
    and label in the alarm colour; on a red-ish base (alarms are inverted blocks there) a solid
    highlight block with the label cut out. Tap "button:<LABEL>". Returns the next free row."""
    return W.button(fb, L, c, r, w, label, alarm=True)


def crash_header(fb, L, c, y, w):
    """The crash header row: CRASH LOG · CLEAN / HAS ENTRIES (a tap that opens and closes the log
    box), with SHARE and CLEAR right-aligned when the log has entries. Returns the next free row."""
    blank = crash_blank()
    label = "CRASH LOG · CLEAN" if blank else "CRASH LOG · HAS ENTRIES"
    ty = y + W.CTRL_TEXT
    if blank:
        fb.text_fit(c, ty, label, w, "small", DIM)
        W._tap(fb, c, y, w, W.CTRL_H, "crashlog")
        return y + W.CTRL_H + W.GAP
    acts = ["SHARE", "CLEAR"]
    bws = [text_width(a) + 12 for a in acts]
    gap = 4
    group = sum(bws) + gap
    label_w = text_width(label) + (4 if fb.alarm_inverted else 0)
    one_row = label_w + 6 + group <= w
    by = y if one_row else y + W.CTRL_H + W.GAP
    x = c + w - group
    for a, bw in zip(acts, bws):
        if a == "CLEAR":
            alarm_button(fb, L, x, by, bw, a)
        else:
            W.button(fb, L, x, by, bw, a)
        x += bw + gap
    lw = (w - group - 6) if one_row else w
    shown = fit_text(label, lw - 4)
    W.alarm_text(fb, c, ty, shown)
    W._tap(fb, c, y, lw, W.CTRL_H, "crashlog")
    return by + W.CTRL_H + W.GAP


def crash_box(fb, L, c, y, w):
    """The open crash log: a dim box CRASH_LINES lines tall holding the wrapped tail of the log in
    dim; when the tail is longer than the box, a highlight scroll thumb on the box's right border
    (at the top: the box opens scrolled to the start of the tail)."""
    tail = CRASH_LOG[-CRASH_TAIL:].lstrip("\n")
    iw = w - 6                           # the border and 2 empty cells on each side
    lines = []
    for para in tail.rstrip("\n").split("\n"):
        lines.extend(vfd.wrap_text(para, iw) or [""])
    h = CRASH_LINES * W.LINE + 3        # 2 rows above the first caps, 3 under the last
    fb.box(c, y, w, h, DIM)
    for i, ln in enumerate(lines[:CRASH_LINES]):
        fb.text(c + 3, y + 3 + i * W.LINE, ln, "small", DIM)
    if len(lines) > CRASH_LINES:
        top, th = y + 2, h - 4           # inside the corners, as the text rows
        thumb = max(6, th * CRASH_LINES // len(lines))
        fb.vline(c + w - 1, top, thumb, HIGHLIGHT)
    return y + h + W.GAP


def sources_header(fb, L, c, y, w, count):
    """divider, BROADCAST SOURCES · n (highlight) with the rows' unit RSSI DBM right-aligned in dim
    above the readings, PRIORITY = SENT SHOW/ANIM/COLOR (dim), divider."""
    y += W.SECTION_GAP - W.GAP
    fb.hline(c, y, w, DIM)
    y += 4
    unit_x = fb.text_right(c + w - 1, y, "RSSI DBM", "small", DIM)
    fb.text_fit(c, y, "BROADCAST SOURCES · %d" % count, unit_x - 6 - c, "small", HIGHLIGHT)
    y += W.LINE
    fb.text_fit(c, y, "PRIORITY = SENT SHOW/ANIM/COLOR", w, "small", DIM)
    y += 7 + 3
    fb.hline(c, y, w, DIM)
    return y + 1 + W.GAP


def source_row(fb, L, c, r, w, src):
    """DiagSourceRow: address (highlight when priority, else dim) with BEST · NOW right-aligned
    in dim, then n PKTS · categories in dim, then a dotted divider. Rows stack directly; returns the
    next row's r."""
    y = r + 3
    rt = fit_text(rssi_text(src), w * 2 // 3)
    start = c + w - text_width(rt)
    fb.text(start, y, rt, "small", DIM)
    fb.text_fit(c + 2, y, address_text(src), start - 6 - (c + 2), "small",
                HIGHLIGHT if src["priority"] else DIM)
    y += W.LINE
    fb.text_fit(c + 2, y, counts_text(src), w - 2, "small", DIM)
    y += 7 + 3
    fb.hline(c, y, w, DIM, step=2)
    return y + 1


def source_section(fb, L, c, y, w, title, rows, collapsed):
    y = W.section(fb, L, c, y, w, title, count=len(rows), collapsed=collapsed)
    if not collapsed:
        y -= W.GAP + 1                   # rows open with their own 3 rows of air
        for src in rows:
            y = source_row(fb, L, c, y, w, src)
        y += W.GAP
    return y


# ---------------------------------------------------------------------------------------------
# Screen
# ---------------------------------------------------------------------------------------------


def draw(fb, L):
    c, w = L.left, L.width
    y = L.content_top
    y = status_block(fb, L, c, y, w)
    y = crash_header(fb, L, c, y + 2, w)
    if not CRASH_COLLAPSED and not crash_blank():
        y = crash_box(fb, L, c, y, w)
    y = sources_header(fb, L, c, y, w, len(SOURCES))
    if not SOURCES:
        msg = "NO SOURCES — START A SCAN"
        fb.text(c + (w - text_width(msg)) // 2, y + 40, msg, "small", DIM)
        return y + 40 + 7 + 40
    priority = [s for s in SOURCES if s["priority"]]
    other = [s for s in SOURCES if not s["priority"]]
    y = source_section(fb, L, c, y - 4, w, "PRIORITY", priority, PRIORITY_COLLAPSED)
    y = source_section(fb, L, c, y, w, "OTHER", other, OTHER_COLLAPSED)
    return y
