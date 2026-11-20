#!/usr/bin/env python3
"""Render the VFD preview PNGs of every screen in tools/vfd/screens/.

Each module in screens/ that defines draw(fb, L) and TAB is a screen. Optional module constants:
TITLE (header title, default the tab label), BACK (bool: show "< BACK"), HEADER_RIGHT (short status
string, or (text, colour index)), HEADER_RIGHT_TAP (tap name that makes HEADER_RIGHT a text button,
e.g. "refresh"; no tap while it is DIM = disabled), TELEMETRY (telemetry line; default
DEFAULT_TELEMETRY, the one line every tab shares). draw() may
return the next free row; when that is below the content region a scroll indicator is drawn.

For every screen x device (pro, x2) x base (AMBER, CYAN) it draws the chrome with widgets.frame(),
calls draw() inside the content clip, and writes tools/vfd/out/<tab>_<BASE>_<device>.png, plus the
contact sheets sheet_<BASE>_<device>.png (with --scroll N the names end in _s<N>) (all screens side by side at full resolution, 4 cells of
black between them; only written when no --only filter is given).

    /usr/bin/python3 tools/vfd/render_previews.py                     # everything
    /usr/bin/python3 tools/vfd/render_previews.py --only scan --only tx --device pro --base AMBER
    /usr/bin/python3 tools/vfd/render_previews.py --base GREEN,#FF8800  # any preset or #RRGGBB
    /usr/bin/python3 tools/vfd/render_previews.py --scroll 200         # content scrolled 200 rows
    /usr/bin/python3 tools/vfd/render_previews.py --demo               # widget demo (out/demo_screen.py)

Checks printed as warnings: anything lit in the safe-area rows, tap rectangles in the content region
shorter than widgets.TAP_ROWS rows.
"""

import argparse
import importlib.util
import os
import sys
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
SCREENS_DIR = os.path.join(HERE, "screens")
OUT_DIR = os.path.join(HERE, "out")
DEMO_PATH = os.path.join(OUT_DIR, "demo_screen.py")

DEFAULT_DEVICES = ("pro", "x2")
DEFAULT_BASES = ("AMBER", "CYAN")
# TelemetryBar.line for the one mock app state every tab shares: scanning, auto-response armed (AUTO),
# a log recording, the TX loop running (TX), the relay linked, 37 light packets heard and a replay
# running (LOGS). Only "MM/RF BLE:SCAN | RX:1284 | TX-AUTO:3 | SCAN…" fits, on every tab alike.
DEFAULT_TELEMETRY = ("MM/RF BLE:SCAN | RX:1284 | TX-AUTO:3 | SCAN:ON | AUTO:ARM | LOG:REC | TX:LOOP"
                     " | RELAY:LINK | LIGHTS:37 | REPLAY:214/2433")
SHEET_GAP_CELLS = 4


def _ensure_pil():
    """The default python3 may lack a working Pillow (here /usr/local/bin/python3 is 3.11 without
    one). Re-run this script with an interpreter that has it."""
    try:
        from PIL import Image  # noqa: F401
        return
    except ImportError:
        pass
    import shutil
    if os.environ.get("VFD_PREVIEW_REEXEC"):
        raise SystemExit("render_previews.py: Pillow is not importable")
    for exe in ("/usr/bin/python3", shutil.which("python3.13"), shutil.which("python3.12")):
        if exe and os.path.exists(exe) and os.path.realpath(exe) != os.path.realpath(sys.executable):
            os.environ["VFD_PREVIEW_REEXEC"] = "1"
            os.execv(exe, [exe, os.path.abspath(__file__)] + sys.argv[1:])
    raise SystemExit("render_previews.py: Pillow is not importable")


if HERE not in sys.path:
    sys.path.insert(0, HERE)

import vfd        # noqa: E402
import widgets as W  # noqa: E402


# ---------------------------------------------------------------------------------------------
# Screen discovery
# ---------------------------------------------------------------------------------------------

def _load_module(path, modname):
    spec = importlib.util.spec_from_file_location(modname, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load_screens(folder=SCREENS_DIR):
    """Modules in folder that define draw() and TAB, sorted in tab order. Returns (screens, errors)."""
    screens, errors = [], []
    if not os.path.isdir(folder):
        return screens, errors
    for fn in sorted(os.listdir(folder)):
        if not fn.endswith(".py") or fn.startswith("_"):
            continue
        path = os.path.join(folder, fn)
        try:
            mod = _load_module(path, "vfd_screen_" + fn[:-3])
        except Exception:
            errors.append((fn, traceback.format_exc()))
            continue
        if callable(getattr(mod, "draw", None)) and hasattr(mod, "TAB"):
            try:
                mod._tab_key = W.tab_key(mod.TAB)
            except ValueError as e:
                errors.append((fn, str(e)))
                continue
            screens.append(mod)
    order = [k for k, _ in W.TABS]
    screens.sort(key=lambda m: (order.index(m._tab_key), m.__name__))
    return screens, errors


# ---------------------------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------------------------

def content_window(mod, device, base, L, scroll):
    """The content rows (t, b) the screen may light at this scroll without a line of text being
    cut by the content region's edges: draw() is run once on a scratch buffer with the content
    unclipped, and widgets.snapped_window() leaves out a band of lit rows crossing the top or
    bottom edge (and a lone divider right under the header rule or over the tab-bar rule). Screens
    that pin rows and scroll their own windows (TX, WAND, LOGS, SCAN, LAB, MAP) already snap them,
    so for those this changes nothing. The Swift renderer does the same before painting."""
    probe = device.framebuffer(base)
    probe.push_clip(0, 0, probe.cols, probe.rows, dy=-scroll)
    depth = len(probe._stack)
    try:
        mod.draw(probe, L)
    finally:
        while len(probe._stack) >= depth:
            probe.pop_clip()
    fb_probe = probe

    def draw_fn(target):
        target.cells[:] = fb_probe.cells

    holder = vfd.FrameBuffer(probe.cols, probe.rows)
    return W.snapped_window(holder, L.content_top, L.content_bottom, draw_fn)


def draw_screen(mod, device, base, scroll=0):
    """Frame + content of one screen. Returns (fb, L, content_end_row or None)."""
    L = W.Layout(device)
    fb = device.framebuffer(base)
    title = getattr(mod, "TITLE", None) or dict(W.TABS)[mod._tab_key]
    t, b = content_window(mod, device, base, L, scroll)
    W.frame(fb, L, mod._tab_key, title, getattr(mod, "TELEMETRY", DEFAULT_TELEMETRY),
            back=getattr(mod, "BACK", False), right=getattr(mod, "HEADER_RIGHT", None), scroll=scroll,
            right_tap=getattr(mod, "HEADER_RIGHT_TAP", None))
    fb.pop_clip()                           # the content clip, narrowed to the snapped window
    fb.push_clip(0, t, fb.cols, b - t, dy=-scroll)
    depth = len(fb._stack)
    n_taps = len(fb.taps)
    try:
        end = mod.draw(fb, L)
    finally:
        while len(fb._stack) >= depth:      # pop the content clip and anything the screen left
            fb.pop_clip()
    # A control the window edge hides keeps only a sliver of its tap: drop those slivers.
    fb.taps[n_taps:] = [tp for tp in fb.taps[n_taps:]
                        if tp[3] >= W.TAP_ROWS or not (tp[1] == t or tp[1] + tp[3] == b)
                        or (tp[1] == L.content_top or tp[1] + tp[3] == L.content_bottom)]
    if isinstance(end, int):
        W.scrollbar(fb, L, end, scroll)
    return fb, L, end if isinstance(end, int) else None


def check(fb, L, label):
    """Warnings for lit safe-area rows and short content tap rectangles."""
    warns = []
    cols = fb.cols
    for r in list(range(0, L.safe_top)) + list(range(L.safe_end, fb.rows)):
        row = fb.cells[r * cols:(r + 1) * cols]
        if any(row):
            warns.append("%s: lit cells in safe-area row %d" % (label, r))
            break
    for c, r, w, h, name in fb.taps:
        inside = L.content_top <= r and r + h <= L.content_bottom
        if inside and h < W.TAP_ROWS and r != L.content_top and r + h != L.content_bottom:
            warns.append("%s: tap %r is only %d rows tall (min %d)" % (label, name, h, W.TAP_ROWS))
    return warns


def contact_sheet(images, device):
    """Images side by side at full resolution with SHEET_GAP_CELLS cells of black between them."""
    from PIL import Image
    gap = SHEET_GAP_CELLS * device.pitch
    w = sum(im.size[0] for im in images) + gap * (len(images) - 1)
    h = max(im.size[1] for im in images)
    sheet = Image.new("RGB", (w, h), vfd.BACKGROUND_RGB)
    x = 0
    for im in images:
        sheet.paste(im, (x, 0))
        x += im.size[0] + gap
    return sheet


def _split_args(values):
    out = []
    for v in values or []:
        out.extend(p.strip() for p in v.split(",") if p.strip())
    return out


def _base_slug(base):
    return base.upper().lstrip("#") if not base.startswith("#") else "C" + base.lstrip("#").upper()


def main(argv=None):
    ap = argparse.ArgumentParser(description="Render VFD screen previews.")
    ap.add_argument("--only", action="append", help="tab key or label (repeatable, comma list)")
    ap.add_argument("--base", action="append", help="base colour preset or #RRGGBB (repeatable)")
    ap.add_argument("--device", action="append", help="device key: pro, x2 (repeatable)")
    ap.add_argument("--scroll", type=int, default=0, help="content scroll offset in rows")
    ap.add_argument("--demo", action="store_true", help="render the widget demo out/demo_screen.py")
    ap.add_argument("--out", default=OUT_DIR, help="output folder (default tools/vfd/out)")
    ap.add_argument("--no-sheets", action="store_true", help="skip the contact sheets")
    ap.add_argument("--screens", default=SCREENS_DIR, help="screen module folder (default screens/)")
    args = ap.parse_args(argv)
    _ensure_pil()

    devices = _split_args(args.device) or list(DEFAULT_DEVICES)
    bases = _split_args(args.base) or list(DEFAULT_BASES)
    for d in devices:
        if d not in vfd.DEVICES:
            ap.error("unknown device %r (have: %s)" % (d, ", ".join(vfd.DEVICES)))
    for b in bases:
        vfd.palette_for(b)          # raises on an unknown colour

    if args.demo:
        if not os.path.exists(DEMO_PATH):
            ap.error("no demo screen at %s" % DEMO_PATH)
        mod = _load_module(DEMO_PATH, "vfd_demo_screen")
        mod._tab_key = W.tab_key(getattr(mod, "TAB", "settings"))
        return _render_demo(mod, devices, bases, args.out)

    screens, errors = load_screens(args.screens)
    for fn, err in errors:
        print("ERROR loading screens/%s:\n%s" % (fn, err), file=sys.stderr)
    try:
        only = [W.tab_key(t) for t in _split_args(args.only)]
    except ValueError as e:
        ap.error("%s (tabs: %s)" % (e, " ".join(k for k, _ in W.TABS)))
    if only:
        screens = [m for m in screens if m._tab_key in only]
    if not screens:
        print("no screens to render (screens/ has no module with draw() and TAB%s)"
              % (" matching --only" if only else ""))
        return 1 if errors else 0

    t0 = time.time()
    failed = bool(errors)
    written = []
    for dkey in devices:
        dev = vfd.DEVICES[dkey]
        for base in bases:
            images = []
            for mod in screens:
                label = "%s_%s_%s" % (mod._tab_key, _base_slug(base), dkey)
                if args.scroll:                 # never overwrite the scroll-0 previews
                    label += "_s%d" % args.scroll
                try:
                    fb, L, end = draw_screen(mod, dev, base, args.scroll)
                except Exception:
                    print("ERROR drawing %s:\n%s" % (label, traceback.format_exc()), file=sys.stderr)
                    failed = True
                    continue
                for wmsg in check(fb, L, label):
                    print("WARN " + wmsg)
                img = vfd.render_image(fb, dev, base)
                path = os.path.join(args.out, label + ".png")
                _save(img, path)
                written.append(path)
                images.append(img)
            if images and not only and not args.no_sheets and len(images) > 1:
                path = os.path.join(args.out, "sheet_%s_%s.png" % (_base_slug(base), dkey))
                _save(contact_sheet(images, dev), path)
                written.append(path)
    for p in written:
        print(p)
    print("%d file(s) in %.1f s" % (len(written), time.time() - t0))
    return 1 if failed else 0


def _render_demo(mod, devices, bases, out):
    """The demo screen, page by page (scroll 0, content_h, 2 x content_h, ...) until its end."""
    written = []
    for dkey in devices:
        dev = vfd.DEVICES[dkey]
        for base in bases:
            page, scroll = 1, 0
            while True:
                fb, L, end = draw_screen(mod, dev, base, scroll)
                label = "demo_p%d_%s_%s" % (page, _base_slug(base), dkey)
                for wmsg in check(fb, L, label):
                    print("WARN " + wmsg)
                path = os.path.join(out, label + ".png")
                _save(vfd.render_image(fb, dev, base), path)
                written.append(path)
                if end is None or end <= L.content_top + scroll + L.content_h or page >= 6:
                    break
                scroll += L.content_h - 20
                page += 1
    for p in written:
        print(p)
    return 0


def _save(img, path):
    folder = os.path.dirname(os.path.abspath(path))
    if not os.path.isdir(folder):
        os.makedirs(folder)
    img.save(path)


if __name__ == "__main__":
    sys.exit(main())
