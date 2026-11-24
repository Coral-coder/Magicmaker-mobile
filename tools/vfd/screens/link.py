"""LINK tab in the VFD look: port of ios/MagicMaker/Views/LinkScreen.swift.

Top to bottom, as on the phone (one List: the relay panel, then, unless the backend is the ESP32,
the Android remote panel and the relay's feed):
    RELAY / LINK | link state (status dot + GATT LINKED ...) | BACKEND [Android BLE] [ESP32]
    [WiFi Hotspot] | backend note (or SCAN ANDROID QR + Android IP field for WiFi) | LinkInfoRows
    IPHONE, HINT, STATUS, EVENT, LIB SYNC, LIB, ANDROID, STORE, GATT | REFRESH, RETRY BLE
    | IMPORT ANDROID LIBRARY + caption | the pocket note
    | ANDROID SCAN / RX panel: PAUSE LOG OFF CLR VIB | GROUPED RAW CLASS n/8 | AUTO-RESPONSE switch
      | gesture hint
    | BUF / HEARD / LAST / LOG rows | LIVE RX | the feed: MMListSectionHeader + PacketRows per
      section (GROUPED) or every advert (RAW); LISTEN 0x0183 MANUFACTURER when empty.

Re-expressed for the grid:
    * the link colour dot is a 7 x 7 pixel LED: solid highlight when linked (cyan on iOS), a hollow
      highlight ring while linking (amber), solid alarm when down (error colour; on a red-ish base an
      inverted highlight block with the centre cut out).
    * the segmented BACKEND picker and the GROUPED / RAW tint buttons are [OPTION] selectors with
      the selected one inverted; at 207 columns the backend options wrap onto a second row.
    * LinkInfoRow keeps its fixed key column (10 character cells: a key of up to 9 characters and at
      least 2 empty cells before the value, as iOS's 72 pt column + 8 pt spacing leaves a clear gap)
      and wraps the uppercased value to at most 3 lines; a word longer than a line is broken (a
      trailing … that lands alone wraps onto its own line, as SwiftUI does, and is only pulled up
      when the value would otherwise be cut past the third line).
    * the ANDROID SCAN / RX block (a bordered panel on iOS) is a dim panel with its title set into
      the top border; the CLASS n/8 menu is a button with a pixel down-chevron, as on SCAN.
    * the one-line gesture hint wraps at its " · " separators.
    * swipe actions, the packet action alert, the QR scanner sheet and confirmations are not drawn.

Mock state: Android BLE backend, the GATT relay linked and taking commands (telemetry RELAY:LINK),
the Android library synced and cached, the Android relay scanning, recording a log and answering
with auto-response. Feed labels and hex are real ones from ios/ParityCheck/vectors.json; the note
is the Android relay's own "Heard" (ServiceState.appendLive), so every row's subtitle reads HEARD.
"""

import widgets as W
import vfd
from vfd import UNLIT, HIGHLIGHT, TEXT, DIM, ALARM, text_width, fit_text

TAB = "link"
TITLE = "LINK"

# ---------------------------------------------------------------------------------------------
# Mock state (AppViewModel / TxEngine / AndroidRemoteStatus / the relay's live feed)
# ---------------------------------------------------------------------------------------------

BACKENDS = ["Android BLE", "ESP32", "WiFi Hotspot"]     # RelayBackend.allCases labels
BACKEND = "Android BLE"
RELAY_GATT_READY = True
RELAY_COMMAND_READY = True              # remoteLinkReady for the BLE backends
ANDROID_RELAY_IP = "192.168.43.1"       # RelaySettings.androidRelayIP default (WiFi only)

RELAY_STATUS = "Connected — ready to transmit"          # AndroidRelayGattClient.statusLabel
TX_STATUS = "Scanning"                                  # TxEngine.status
STATUS_MESSAGE = "Android library synced (212 TX, 31 wand, 4 auto)"
CATALOG_SYNC_IN_FLIGHT = False
CATALOG_SYNC_DIAGNOSTIC = "ok · 212 TX"
CATALOG_TX = 212                        # androidCatalog.transmitPresets.count
CATALOG_WAND = 31                       # androidCatalog.wandColors.count
IMPORT_RESULT = ""                      # empty until IMPORT ANDROID LIBRARY is tapped

#: AndroidRemoteStatus as the relay reports it
ANDROID = {
    "running": True,
    "status": "Scanning",
    "scanActive": True,
    "autoEnabled": True,
    "recordSessionActive": True,
    "activeSessionName": "scan_2026-11-19T21-37-52.csv",
    "packetsHeard": 3912,
    "lastHeardHex": "8301CF0B00C020224EAC7807866E82",
    "lastHeardLabel": "Starlight: Blue (#02)",
    "storeRevision": 1487,
    "relayLinked": True,
}

VIEW_MODE = "GROUPED"                   # GROUPED | RAW
SECTIONS = ["WAND", "COLORS", "ANIMATIONS", "CONTROL", "PING", "INTERROGATE", "SHOWS", "UNKNOWN"]
VISIBLE_SECTIONS = set(SECTIONS)        # CLASS filter (all on)
COLLAPSED = set()                       # LinkScreen starts with nothing folded

NOTE = "Heard"                          # the Android relay's note on every live packet


def _pkt(label, hex_text, rssi):
    return {"label": label, "hex": hex_text, "rssi": rssi, "note": NOTE}


#: androidUniqueLivePackets grouped by LivePacketSort (section order, newest first).
FEED = [
    ("WAND", [
        _pkt("Starlight: Blue (#02)", "8301CF0B00C020224EAC7807866E82", -64),
        _pkt("Starlight: Red (#15)", "8301CF0B00C42922EFD819F22A6215", -71),
        _pkt("Starlight: Purple (#07)", "8301CF0B00C42922EFD819F22A6207", -77),
        _pkt("Starlight: Green (#19)", "8301CF0B00C42922EFD819F22A6219", -83),
    ]),
    ("COLORS", [
        _pkt("Single Color: Cyan", "8301CC03000100E100E90500090E00B0", -58),
        _pkt("Dual Color: Yellow Orange centre / Blue corners", "8301CC03000100E100E90600060F8F82B3", -61),
        _pkt("Single Color: White", "8301CC03000100E90500060EFBB3", -66),
        _pkt("Single Color: Lavender", "8301CC03000100E100E90500090E06B0", -69),
    ]),
    ("ANIMATIONS", [
        _pkt("Cross-Fade: Red / Blue", "8301CC03000100E911006F0F554258F44882D1460208D06500B3", -57),
        _pkt("Effect: Circle", "8301CC03000100E100E90B0B060F5C5D48A5D14532B3", -60),
        _pkt("Rotating Colors (E912)", "8301E100E91200030FA2A2A4A4A230D037F4D2460064FCB9", -64),
        _pkt("Animation: 5-Color Cycle", "8301E100E90C000F0FB1B9B5B1A2307B7DB0", -75),
    ]),
    ("CONTROL", [
        _pkt("Show Control: E907", "8301E200E90700220F434341B0", -59),
    ]),
    ("PING", [
        _pkt("Show Ping (2341)", "8301CC03234100", -66),
        _pkt("Signal Beacon", "8301CC03000000", -72),
    ]),
    ("INTERROGATE", [
        _pkt("Wake Ping", "8301CC03000100", -58),
    ]),
    ("SHOWS", [
        _pkt("Lightning", "8301CC03000100E100E90C000F0F5D465BF00532374895", -62),
    ]),
]

# ---------------------------------------------------------------------------------------------
# Derived text (LinkRelayPanel / LinkScreen computed properties)
# ---------------------------------------------------------------------------------------------

def uses_ble_relay_link():
    return BACKEND in ("Android BLE", "ESP32")


def remote_link_ready():
    if BACKEND == "WiFi Hotspot":
        return bool(ANDROID and ANDROID.get("running"))
    return RELAY_COMMAND_READY


def link_state():
    """(label, dot) for linkLabel / linkColor: dot "ok" (cyan), "wait" (amber), "down" (error)."""
    linked = bool(ANDROID and ANDROID.get("relayLinked"))
    if BACKEND == "ESP32":
        dot = "ok" if RELAY_COMMAND_READY else ("wait" if RELAY_GATT_READY else "down")
        return ("ESP32 READY" if RELAY_GATT_READY else "ESP32 SEARCHING"), dot
    if BACKEND == "Android BLE":
        if RELAY_GATT_READY and linked:
            return "GATT LINKED", "ok"
        if RELAY_GATT_READY:
            return "GATT READY", "wait"
        return "GATT SEARCHING", "down"
    ready = remote_link_ready()
    return ("WIFI LINKED" if ready else "WIFI NOT CONNECTED"), ("ok" if ready else "wait")


def remote_link_hint():
    """AppViewModel.remoteLinkHint for the mock link state."""
    if BACKEND == "ESP32":
        return "" if RELAY_GATT_READY else "Power on the ESP32 — tap Retry BLE."
    if BACKEND == "Android BLE":
        if RELAY_COMMAND_READY:
            return ""
        if RELAY_GATT_READY:
            return "Finishing Android link…"
        return "Open LINK — tap Retry BLE, keep phones close."
    return "" if remote_link_ready() else "Open LINK — scan Android QR or join MagicMaker hotspot."


def backend_note():
    if BACKEND == "ESP32":
        return ("Power on the MagicMaker ESP32. iPhone auto-connects and transmits through it while "
                "you keep scanning. No pairing needed.")
    if BACKEND == "Android BLE":
        return "Put Android in BLE GATT / iPhone mode. iPhone auto-connects to the Android relay."
    return ""


def import_caption():
    return IMPORT_RESULT or "ADDS THE ANDROID PACKETS THE IPHONE LIBRARY DOES NOT HAVE YET"


def catalog_available():
    return CATALOG_TX > 0 or CATALOG_WAND > 0


def visible_feed():
    return [(s, p) for s, p in FEED if s in VISIBLE_SECTIONS and p]


def raw_rows():
    """Every advert, newest first (the mock interleaves the sections)."""
    lists = [list(p) for _, p in visible_feed()]
    out, i = [], 0
    while any(lists):
        k = i % len(lists)
        if lists[k]:
            out.append(lists[k].pop(0))
        i += 1
    return out


def buffer_text():
    if VIEW_MODE == "RAW":
        return "RAW %d" % len(raw_rows())
    return "UNIQUE %d" % sum(len(p) for _, p in FEED)


def row_subtitle(pkt):
    return pkt["note"] if pkt["note"] else "RSSI %d" % pkt["rssi"]


# ---------------------------------------------------------------------------------------------
# Small helpers (Swift: the same names on the VFD screen type)
# ---------------------------------------------------------------------------------------------

KEY_COLS = 10 * 6           # LinkInfoRow key column: 10 character cells (iOS: 72 pt + 8 pt spacing),
                            # so the longest key (LIB SYNC, 8) keeps >= 2 empty cells before the value
VALUE_LINES = 3             # LinkInfoRow value lineLimit
DOT = [
    "..###..",
    ".#####.",
    "#######",
    "#######",
    "#######",
    ".#####.",
    "..###..",
]


def _tap(fb, c, r, w, h, name):
    """Tap rectangle at least W.TAP_ROWS tall, grown evenly around the visual (as widgets do)."""
    if h < W.TAP_ROWS:
        r -= (W.TAP_ROWS - h) // 2
        h = W.TAP_ROWS
    fb.tap(c, r, w, h, name)


def status_dot(fb, x, y, state):
    """The link colour dot as a 7 x 7 pixel LED on caps row y: "ok" solid highlight, "wait" a
    hollow highlight ring, "down" solid alarm; on a red-ish base "down" is an alarm the inverted
    way, a 9 x 9 highlight block with the dot cut out."""
    if state == "down" and fb.alarm_inverted:
        fb.fill(x - 1, y - 1, 9, 9, HIGHLIGHT)
    for j, line in enumerate(DOT):
        for i, ch in enumerate(line):
            if ch != "#":
                continue
            inner = 1 <= i <= 5 and 1 <= j <= 5 and DOT[j - 1][i] == "#" and DOT[j + 1][i] == "#" \
                and line[i - 1] == "#" and line[i + 1] == "#"
            if state == "ok":
                fb.set(x + i, y + j, HIGHLIGHT)
            elif state == "wait":
                if not inner:
                    fb.set(x + i, y + j, HIGHLIGHT)
            elif fb.alarm_inverted:
                fb.set(x + i, y + j, UNLIT)
            else:
                fb.set(x + i, y + j, ALARM)


def wrap_value(s, max_cols, lines=VALUE_LINES):
    """Word-wrap s into at most `lines` lines of max_cols cells: words longer than a line are
    broken (as SwiftUI does) and text past the last line is cut with …. A trailing '…' that wraps
    onto a line of its own stays there (SwiftUI wraps it too, and every character before it is
    kept); only when that line would fall past the last one is it pulled up, replacing the last
    character of the line before."""
    out = vfd.wrap_text(s, max_cols)
    n = vfd.max_chars(max_cols)
    if len(out) > lines and len(out) > 1 and out[-1] == vfd.ELLIPSIS:
        out.pop()
        out[-1] = out[-1][:n - 1] + vfd.ELLIPSIS
    if len(out) > lines:
        last = out[lines - 1]
        out = out[:lines - 1] + [fit_text(last + " " + vfd.ELLIPSIS, max_cols)
                                 if len(last) + 2 <= n else last[:n - 1] + vfd.ELLIPSIS]
    return out


def info_row(fb, L, c, y, w, key, value, color=TEXT):
    """LinkInfoRow: the key (dim) in a KEY_COLS-wide column, the value uppercased (colour as
    given; ALARM via alarm_text) wrapped beside it, up to 3 lines. Returns the next free row."""
    fb.text_fit(c, y, key, KEY_COLS - 6, "small", DIM)
    vx, vw = c + KEY_COLS, w - KEY_COLS
    lines = wrap_value(W._upper(value), vw)
    for i, ln in enumerate(lines or [""]):
        if color == ALARM:
            W.alarm_text(fb, vx, y + i * W.LINE, ln)
        else:
            fb.text(vx, y + i * W.LINE, ln, "small", color)
    return y + max(1, len(lines)) * W.LINE


def hint_lines(fb, L, c, y, w, s, sep=" · "):
    """The gesture hint (one line shrunk to fit on iOS): wrapped only at its ' · ' separators by
    W.token_lines, the separator dropped at a break (as TX and LOGS wrap theirs). Returns the row
    after the last line."""
    for ln in W.token_lines(s, w, sep):
        fb.text(c, y, ln, "small", DIM)
        y += W.LINE
    return y


def note(fb, L, c, y, w, s, color=DIM):
    """noteText: wrapped small dim text, drawn as given (iOS does not uppercase it)."""
    return W.text_block(fb, L, c, y, w, s, color=color)


# ---------------------------------------------------------------------------------------------
# Relay panel
# ---------------------------------------------------------------------------------------------

def link_state_line(fb, L, c, y, w):
    """The dot and linkLabel (text). Returns the next free row."""
    label, dot = link_state()
    r = y + 1
    status_dot(fb, c, r, dot)
    fb.text_fit(c + 7 + 5, r, label, w - 12, "small", TEXT)
    return r + W.LINE + 1


def backend_detail(fb, L, c, y, w):
    """WiFi: SCAN ANDROID QR (primary) and the Android IP field, its iOS placeholder also shown as
    the field's dim caption so a filled-in address stays identified; otherwise the backend note."""
    if BACKEND == "WiFi Hotspot":
        y = W.button(fb, L, c, y + 4, None, "Scan Android QR", primary=True)
        return W.field(fb, L, c, y, w, "Android IP (hotspot gateway)", ANDROID_RELAY_IP,
                       placeholder="Android IP (hotspot gateway)", name="field:ANDROID IP")
    return note(fb, L, c, y + 3, w, backend_note())


def status_rows(fb, L, c, y, w):
    """IPHONE, HINT, STATUS, EVENT, LIB SYNC, LIB, ANDROID, STORE, GATT."""
    y = info_row(fb, L, c, y, w, "IPHONE", RELAY_STATUS)
    hint = remote_link_hint()
    if hint:
        y = info_row(fb, L, c, y, w, "HINT", hint, HIGHLIGHT)
    warn = TX_STATUS in ("No relay linked — nothing sent", "Transmit failed — check relay")
    y = info_row(fb, L, c, y, w, "STATUS", TX_STATUS, ALARM if warn else DIM)
    y = info_row(fb, L, c, y, w, "EVENT", STATUS_MESSAGE)
    if CATALOG_SYNC_IN_FLIGHT or CATALOG_SYNC_DIAGNOSTIC:
        y = info_row(fb, L, c, y, w, "LIB SYNC", CATALOG_SYNC_DIAGNOSTIC.upper())
    if CATALOG_TX:
        y = info_row(fb, L, c, y, w, "LIB", "%d TX · %d WAND" % (CATALOG_TX, CATALOG_WAND))
    if BACKEND != "ESP32" and ANDROID:
        s = ANDROID
        st = s["status"].upper() if s["status"] else ("RUNNING" if s["running"] else "STOPPED")
        y = info_row(fb, L, c, y, w, "ANDROID", st)
        y = info_row(fb, L, c, y, w, "STORE", "REV %d" % s["storeRevision"])
        if s["relayLinked"]:
            y = info_row(fb, L, c, y, w, "GATT", "LINKED")
    return y


def relay_panel(fb, L, c, y, w):
    """LinkRelayPanel, in the app's order. Returns the next free row."""
    y = W.section(fb, L, c, y, w, "RELAY / LINK")
    y = link_state_line(fb, L, c, y, w)
    y = W.options(fb, L, c, y, w, BACKENDS, BACKEND, label_text="Backend")
    y = backend_detail(fb, L, c, y, w)
    y = status_rows(fb, L, c, y + 2, w)
    labels = ["Refresh"] + (["Retry BLE"] if uses_ble_relay_link() else [])
    y = W.buttons(fb, L, c, y + 4, w, labels, equal=False)
    if catalog_available():
        y = W.button(fb, L, c, y + 4, None, "Import Android library", primary=True)
        for ln in wrap_value(import_caption(), w, 2):
            fb.text(c, y + 1, ln, "small", HIGHLIGHT if IMPORT_RESULT else DIM)
            y += W.LINE
        y += W.GAP
    return note(fb, L, c, y + 4, w, "Control Android from your pocket: BLE when close, WiFi "
                "hotspot + QR when Android is in your backpack.")


# ---------------------------------------------------------------------------------------------
# Android remote panel and the relay feed
# ---------------------------------------------------------------------------------------------

def remote_controls(fb, L, c, y, w):
    """ANDROID SCAN / RX: a dim panel with the title in its top border; the remote buttons, the
    GROUPED / RAW selectors with CLASS n/8, the AUTO-RESPONSE switch and the gesture hint."""
    ic, ir, iw = W.panel_inner(c, y, w, True)
    ready = remote_link_ready()
    s = ANDROID or {}
    labels = ["Pause" if s.get("scanActive") else "Scan",
              "Log Off" if s.get("recordSessionActive") else "Log", "Clr", "Vib"]
    r = W.buttons(fb, L, ic, ir + 2, iw, labels, enabled=[ready] * 4, equal=False)
    end = W.options(fb, L, ic, r, iw, ["GROUPED", "RAW"], VIEW_MODE, name="mode")
    x = ic + text_width("[GROUPED]") + W.OPT_GAP + text_width("[RAW]") + W.OPT_GAP
    W.menu_button(fb, L, x, r, "CLASS %d/%d" % (len(VISIBLE_SECTIONS), len(SECTIONS)))
    r = W.toggle(fb, L, ic, end, iw, "AUTO-RESPONSE", bool(s.get("autoEnabled")), enabled=ready)
    r = hint_lines(fb, L, ic, r + 2, iw, "TAP REPLAY · SWIPE ← DEL · SWIPE → TX/TAG")
    return W.panel(fb, L, c, y, w, r + 2 - y, "ANDROID SCAN / RX")


def remote_stats(fb, L, c, y, w):
    """BUF, HEARD, LAST (label · first 24 hex characters …), LOG."""
    s = ANDROID
    y = info_row(fb, L, c, y, w, "BUF", buffer_text())
    y = info_row(fb, L, c, y, w, "HEARD", "%d pkts" % s["packetsHeard"])
    if s["lastHeardHex"]:
        last = s["lastHeardLabel"].upper() + " · " + s["lastHeardHex"][:24] + vfd.ELLIPSIS
        y = info_row(fb, L, c, y, w, "LAST", last)
    if s["recordSessionActive"] and s["activeSessionName"]:
        y = info_row(fb, L, c, y, w, "LOG", s["activeSessionName"])
    return y


def feed(fb, L, c, y, w):
    """GROUPED: a collapsible section header (chevron, title, 3-digit count) per visible section
    and its PacketRows unless folded; RAW: every advert. Returns the next free row."""
    if VIEW_MODE == "RAW":
        rows = raw_rows()
        for pkt in rows:
            y = W.packet_row(fb, L, c, y, w, pkt["label"], pkt["hex"], row_subtitle(pkt))
        return y
    for sec, pkts in visible_feed():
        folded = sec in COLLAPSED
        y = W.section(fb, L, c, y, w, sec, count=len(pkts), collapsed=folded)
        if folded:
            continue
        y -= W.GAP + 1
        for pkt in pkts:
            y = W.packet_row(fb, L, c, y, w, pkt["label"], pkt["hex"], row_subtitle(pkt))
    return y


def remote_section(fb, L, c, y, w):
    """The remote controls, the relay's counters, LIVE RX and the feed (or its empty line)."""
    y = remote_controls(fb, L, c, y, w)
    if ANDROID:
        y = remote_stats(fb, L, c, y + 3, w)
    y = W.section(fb, L, c, y, w, "LIVE RX") - 3     # the first group header sits closer
    empty = not (raw_rows() if VIEW_MODE == "RAW" else visible_feed())
    if empty:
        fb.text_fit(c, y + 9, "LISTEN 0x0183 MANUFACTURER", w, "small", DIM)    # as given: 0x
        return y + 9 + W.LINE + 9
    return feed(fb, L, c, y, w)


def draw(fb, L):
    c, w = L.left, L.width
    y = L.content_top
    y = relay_panel(fb, L, c, y, w)
    if BACKEND != "ESP32":
        y = remote_section(fb, L, c, y + 7, w)
    return y
