#!/usr/bin/env python3
"""Validate the TLV framing hypothesis in docs/PROTOCOL.md against real packets.

After the 8301 Disney company ID, the payload should be a chain of
<type:1><length:1><value:length> records running exactly to the end of the
advertisement -- no leftover bytes, no overruns.

Usage:
    tools/tlv_validate.py                      # check the app's built-in packets
    tools/tlv_validate.py capture.csv          # check a column of hex from a capture
    tools/tlv_validate.py --hex 8301E100E905006F0EF5B0

Exit status is non-zero if anything fails to parse, so this works in CI.
"""

import csv
import re
import sys

HEX_RE = re.compile(r"^[0-9A-Fa-f]+$")


def walk(hexstr):
    """Parse a packet as TLV. Returns a list of (type, length, value_hex).

    Raises ValueError if the chain overruns or leaves trailing bytes.
    """
    b = bytes.fromhex(hexstr)
    if b[:2] != b"\x83\x01":
        raise ValueError("does not start with the Disney company ID 8301")
    i, records = 2, []
    while i < len(b):
        if i + 2 > len(b):
            raise ValueError("trailing byte %02X with no length" % b[i])
        rtype, length = b[i], b[i + 1]
        value = b[i + 2 : i + 2 + length]
        if len(value) != length:
            raise ValueError(
                "record %02X declares %d value bytes but only %d remain"
                % (rtype, length, len(value))
            )
        records.append((rtype, length, value.hex().upper()))
        i += 2 + length
    return records


def describe(records):
    return " | ".join("%02X(%d)" % (t, l) for t, l, _ in records)


def tail(vib):
    return 0xB0 | (vib & 0x0F)


def pkt(*byte_values):
    return bytes(x & 0xFF for x in byte_values).hex().upper()


def builtins():
    """Mirror of PresetCatalog / PacketBuilder -- every packet the app can send.

    Kept in sync by hand. If a transmit packet is added to the app and not here,
    this script simply won't cover it; it will never report a false failure.
    """
    RED, BLUE, PURPLE, GREEN, WHITE, YELLOW_ORANGE = 0x15, 0x02, 0x01, 0x19, 0x1B, 0x0F

    def preset(c, v=0):
        return pkt(0x83, 0x01, 0xE9, 0x05, 0x00, 0x2E, 0x0E, 0xE0 | (c & 0x1F), tail(v))

    def dual(a, b, v=0):
        return pkt(0x83, 0x01, 0xE9, 0x06, 0x00, 0x22, 0x0F,
                   0x80 | (a & 0x1F), 0x80 | (b & 0x1F), tail(v))

    def rainbow5(v=0):
        return pkt(0x83, 0x01, 0xE9, 0x09, 0x00, 0x2E, 0x0F,
                   *[0xA0 | (c & 0x1F) for c in (YELLOW_ORANGE, RED, GREEN, BLUE, PURPLE)],
                   tail(v))

    def circle(v=0):
        return pkt(0x83, 0x01, 0xE9, 0x0B, 0x0B, 0x0F, 0x0F,
                   0x5C, 0x5D, 0x48, 0xA5, 0xD1, 0x45, 0x32, tail(v))

    def crossfade(v=0):
        return pkt(0x83, 0x01, 0xE1, 0x00, 0xE9, 0x11, 0x00, 0x6F, 0x0F,
                   0x40 | (RED & 0x1F), 0x40 | (BLUE & 0x1F),
                   0x58, 0xF4, 0x48, 0x82, 0xD1, 0x46, 0x02, 0x08, 0xD0, 0x65, 0x00,
                   tail(v))

    return [
        ("Ping (wakeup)", "8301CC03000100"),
        ("Vibrate band", preset(WHITE, 5)),
        ("Vibrate (rainbow FX)", "8301CC03000100E100E90C000F0F5D465BF005323748B0"),
        ("Red", preset(RED)),
        ("White", preset(WHITE)),
        ("Dual YO/Blue", dual(YELLOW_ORANGE, BLUE)),
        ("5-LED Rainbow", rainbow5()),
        ("Circle", circle()),
        ("Crossfade R/B", crossfade()),
        ("Lightning", "8301CC03000100E100E90C000F0F5D465BF00532374895"),
        ("New Wand OFF", "8301CF0B00C020224EAC7807866F1D"),
    ]


def hexes_from_csv(path):
    """Pull every 8301... hex string out of a capture CSV, whatever the column order."""
    seen, out = set(), []
    with open(path, newline="", encoding="utf-8", errors="replace") as fh:
        for row in csv.reader(fh):
            for cell in row:
                c = cell.strip().replace(":", "").replace(" ", "").upper()
                if len(c) >= 8 and len(c) % 2 == 0 and HEX_RE.match(c) and c.startswith("8301"):
                    if c not in seen:
                        seen.add(c)
                        out.append(c)
    return out


def check(pairs, show_ok):
    ok = failures = 0
    for name, h in pairs:
        try:
            records = walk(h)
        except ValueError as exc:
            print("FAIL  %-22s %-52s %s" % (name, h, exc))
            failures += 1
            continue
        ok += 1
        if show_ok:
            marker = "" if any(t in (0xE1, 0xE2, 0xE3) for t, _, _ in records) \
                     else "   <- no channel marker"
            print("ok    %-22s %-52s %s%s" % (name, h, describe(records), marker))
    print("\n%d parsed exactly, %d failed, out of %d" % (ok, failures, ok + failures))
    return failures


def main(argv):
    args = [a for a in argv[1:] if a != "--quiet"]
    show_ok = "--quiet" not in argv[1:]

    if args and args[0] == "--hex":
        pairs = [("(cli)", a.replace(":", "").replace(" ", "").upper()) for a in args[1:]]
    elif args:
        pairs = []
        for path in args:
            pairs += [("capture", h) for h in hexes_from_csv(path)]
        print("Found %d distinct 8301... packets\n" % len(pairs))
    else:
        pairs = builtins()

    return 1 if check(pairs, show_ok) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
