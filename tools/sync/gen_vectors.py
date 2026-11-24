#!/usr/bin/env python3
"""Writes the MagicMaker SYNC v1 shared test vectors and golden session transcripts.

    python3 tools/sync/gen_vectors.py           # (re)write tools/sync/vectors.json + transcripts/
    python3 tools/sync/gen_vectors.py --check   # exit 1 if the committed files are not current

Python 3 stdlib only. Fully deterministic: fixed keys, nonces, ids and clocks; no randomness, no
wall-clock reads. The reference implementation lives in sync_ref.py; the JSON schema is in
README.md; the protocol is docs/SYNC_PROTOCOL.md.
"""

import heapq
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import sync_ref as R  # noqa: E402
from sync_ref import hexu, unhex  # noqa: E402

SCHEMA = 1
JS_SAFE = (1 << 53) - 1


# ---------------------------------------------------------------------------------------------
# Fixtures (all derived deterministically)
# ---------------------------------------------------------------------------------------------

def det(label, n):
    """Deterministic 'random' bytes: SHA-256("mm-sync-vectors:" + label)[0..n]."""
    return R.sha256(b"mm-sync-vectors:" + label.encode())[:n]


BASE_MS = 1_796_000_000_000          # sim time 0 = this epoch ms (2026-11-30T...Z)
GROUP_KEY_1 = det("group-key-1", 16)
GROUP_KEY_2 = det("group-key-2", 16)  # the stranger's group
GID1 = R.group_id(GROUP_KEY_1)
GID2 = R.group_id(GROUP_KEY_2)

ID_I = bytes.fromhex("A1B2C3D4E5F60718")
ID_A = bytes.fromhex("4A1D0B5E77C2903F")
ID_H = bytes.fromhex("0100246F28AE52C6")   # [01][00][MAC 24:6F:28:AE:52:C6]
ID_S = bytes.fromhex("5E1F00C0FFEE0001")
ID_X = bytes.fromhex("BADC0FFEE0DDF00D")

P_SHOW = bytes.fromhex("8301E100E90C00010F4D575A940705488BB0")
P_SHOW2 = bytes.fromhex("8301E100E90E00040FB7A8B6ADA059190248AEB0")
P_ANIM = bytes.fromhex("8301E100E90600220F5C57B0")
P_COLOR = bytes.fromhex("8301CC03000100E100E90500090E02B0")
P_COLOR2 = bytes.fromhex("8301CC03000100E100E90500090E06B0")
P_RAW = bytes.fromhex("8301CC03000000")
P_PING = bytes.fromhex("8301CC03000100")
P_WAND = bytes.fromhex("8301CF0B00C020224EAC7807866F1D")   # a New-Wand code
P_MIN = bytes.fromhex("830101")
P_MAX = bytes.fromhex("8301") + bytes(range(1, 28))
P_EV1 = bytes.fromhex("8301E100E90E00730FBBBBB8BBB859190248AEB0")
P_EV2 = bytes.fromhex("8301E100E90C00410F4D4E5A940F1B488BB0")


# ---------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------

def body(ns, packet, u, origin=None, flags=0, **kw):
    f = {"ns": ns, "packet": packet, "updatedAt": u}
    if origin is not None:
        f["origin"] = origin
    if flags:
        f["flags"] = flags
    for k, v in kw.items():
        if v is not None:
            f[k] = v
    return f


def raw_body(*tlvs):
    return b"".join(R.tlv(t, v) for t, v in tlvs)


def le(n, w, signed=False):
    return int(n).to_bytes(w, "little", signed=signed)


def check_js_safe(obj, path="$"):
    if isinstance(obj, bool) or obj is None:
        return
    if isinstance(obj, int):
        assert -JS_SAFE <= obj <= JS_SAFE, (path, obj)
    elif isinstance(obj, dict):
        for k, v in obj.items():
            check_js_safe(v, path + "." + str(k))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            check_js_safe(v, "%s[%d]" % (path, i))


def expect_error(fn, *args):
    try:
        fn(*args)
    except R.SyncError as e:
        return e
    raise AssertionError("expected SyncError from %s%r" % (fn.__name__, args))


# ---------------------------------------------------------------------------------------------
# Primitive vectors
# ---------------------------------------------------------------------------------------------

def v_crc32():
    cases = [("empty", b""), ("check-123456789", b"123456789"),
             ("presence-body", R.encode_body(body(0, P_SHOW, 1)))]
    out = [{"name": n, "hex": hexu(d), "crc": R.crc32(d)} for n, d in cases]
    assert out[1]["crc"] == 0xCBF43926
    return out


def v_fnv():
    cases = [("empty", b""), ("a", b"a"), ("foobar", b"foobar"),
             ("key-lib", R.encode_key(0, P_SHOW)), ("key-newwand", R.encode_key(1, P_WAND))]
    out = [{"name": n, "hex": hexu(d), "hash": "%016X" % R.fnv1a64(d)} for n, d in cases]
    assert out[0]["hash"] == "CBF29CE484222325" and out[1]["hash"] == "AF63DC4C8601EC8C"
    assert out[2]["hash"] == "85944171F73967E8"
    return out


def v_sha256():
    cases = [("empty", b""), ("abc", b"abc"),
             ("448-bit", b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
             ("groupid-input", R.GROUP_ID_PREFIX + GROUP_KEY_1)]
    out = [{"name": n, "hex": hexu(d), "digest": hexu(R.sha256(d))} for n, d in cases]
    assert out[1]["digest"] == "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"
    return out


def v_hmac():
    rfc = [
        ("RFC4231 TC1", b"\x0b" * 20, b"Hi There",
         "B0344C61D8DB38535CA8AFCEAF0BF12B881DC200C9833DA726E9376C2E32CFF7"),
        ("RFC4231 TC2", b"Jefe", b"what do ya want for nothing?",
         "5BDCC146BF60754E6A042426089575C75A003F089D2739839DEC58B964EC3843"),
        ("RFC4231 TC3", b"\xaa" * 20, b"\xdd" * 50,
         "773EA91E36800E46854DB8EBD09181A72959098B3EF8C122D9635514CED565FE"),
        ("RFC4231 TC4", bytes(range(1, 26)), b"\xcd" * 50,
         "82558A389A443C0EA4CC819899F2083A85F0FAA3E578F8077A2E3FF46729665B"),
        ("RFC4231 TC6", b"\xaa" * 131, b"Test Using Larger Than Block-Size Key - Hash Key First",
         "60E431591EE0B67F0D8A26AACBF5B77F8E0BC6213728C5140546040F0EE37F54"),
        ("RFC4231 TC7", b"\xaa" * 131,
         b"This is a test using a larger than block-size key and a larger than block-size data."
         b" The key needs to be hashed before being used by the HMAC algorithm.",
         "9B09FFA71B942FCB27635FBCD5B0E944BFDC63644F0713938A7F51535C3A35E2"),
    ]
    out = []
    for name, k, d, want in rfc:
        got = hexu(R.hmac_sha256(k, d))
        assert got == want, name
        out.append({"name": name, "keyHex": hexu(k), "dataHex": hexu(d), "macHex": got})
    # TC5: truncation to 128 bits (the proofs truncate the same way)
    k, d = b"\x0c" * 20, b"Test With Truncation"
    full = R.hmac_sha256(k, d)
    assert hexu(full[:16]) == "A3B6167473100EE06E0C796C2955552B"
    out.append({"name": "RFC4231 TC5 (first 16 bytes)", "keyHex": hexu(k), "dataHex": hexu(d),
                "macHex": hexu(full), "trunc16Hex": hexu(full[:16])})
    return out


def v_group_ids():
    keys = [("group-key-1", GROUP_KEY_1), ("group-key-2", GROUP_KEY_2),
            ("zero-key", bytes(16)), ("counting", bytes(range(16)))]
    return [{"name": n, "keyHex": hexu(k), "groupId": hexu(R.group_id(k)),
             "advertTag": hexu(R.group_id(k)[:2])} for n, k in keys]


def v_proofs():
    out = []
    cases = [
        ("I central to H", GROUP_KEY_1, det("nonce-c-1", 8), det("nonce-p-1", 8), ID_I, ID_H),
        ("A central to H", GROUP_KEY_1, det("nonce-c-2", 8), det("nonce-p-2", 8), ID_A, ID_H),
        ("I central to A", GROUP_KEY_1, det("nonce-c-3", 8), det("nonce-p-3", 8), ID_I, ID_A),
        ("counting bytes", bytes(range(16)), bytes(range(8)), bytes(range(8, 16)),
         bytes(range(16, 24)), bytes(range(24, 32))),
    ]
    for name, k, nc, np_, ic, ip in cases:
        t = R.auth_transcript(nc, np_, ic, ip)
        out.append({"name": name, "keyHex": hexu(k), "groupId": hexu(R.group_id(k)),
                    "nonceC": hexu(nc), "nonceP": hexu(np_), "idC": hexu(ic), "idP": hexu(ip),
                    "transcriptHex": hexu(t),
                    "macInputPHex": hexu(R.PROOF_P_PREFIX + t),
                    "macInputCHex": hexu(R.PROOF_C_PREFIX + t),
                    "proofP": hexu(R.proof_p(k, nc, np_, ic, ip)),
                    "proofC": hexu(R.proof_c(k, nc, np_, ic, ip))})
    return out


def v_text():
    cases = [
        ("trim ascii", "  Hello  ", 64),
        ("trim tabs newlines", "\t\nMain Street\r\n", 64),
        ("trim nbsp + ideographic space", " 　Castle ", 64),
        ("inner spaces kept", "Big  Thunder", 64),
        ("zero-width space is not white space", "​X​", 64),
        ("ascii truncate 70 -> 64", "A" * 70, 64),
        ("2-byte truncate at boundary", "é" * 40, 64),
        ("4-byte exact 64", "\U0001F600" * 16, 64),
        ("4-byte boundary a+16 emoji", "a" + "\U0001F600" * 16, 64),
        ("trailing space after truncation", "x" * 63 + " y", 64),
        ("only white space", " \t  ", 64),
        ("empty", "", 64),
        ("note 160", "n" * 200, 160),
        ("CJK 3-byte boundary", "文" * 60, 160),
    ]
    out = []
    for name, s, mx in cases:
        r = R.normalize_text(s, mx)
        out.append({"name": name, "fn": "text", "input": s, "inputHex": hexu(s.encode("utf-8")),
                    "maxBytes": mx, "output": r,
                    "outputHex": hexu(r.encode("utf-8")) if r is not None else None})
    for name, s in [("kind plain", "starlight"), ("kind non-ascii", "bänd"),
                    ("kind long", "imported-library-entry"), ("kind control", "a\tb"),
                    ("kind blank", "   ")]:
        r = R.normalize_kind(s)
        out.append({"name": name, "fn": "kind", "input": s, "inputHex": hexu(s.encode("utf-8")),
                    "maxBytes": R.KIND_MAX, "output": r,
                    "outputHex": hexu(r.encode("ascii")) if r is not None else None})
    return out


def v_keys():
    out = []
    for ns, p in [(0, P_SHOW), (0, P_MIN), (0, P_MAX), (1, P_WAND)]:
        k = R.encode_key(ns, p)
        out.append({"ns": ns, "packet": hexu(p), "keyHex": hexu(k), "keyString": R.key_string(ns, p),
                    "fnv1a64": "%016X" % R.fnv1a64(k)})
    return out


# ---------------------------------------------------------------------------------------------
# Record bodies
# ---------------------------------------------------------------------------------------------

T0 = 1_790_000_000_000


def valid_bodies():
    return [
        ("presence", body(0, P_SHOW, 1)),
        ("presence min packet", body(0, P_MIN, 1)),
        ("presence max packet", body(0, P_MAX, 1)),
        ("user rename android", body(0, P_SHOW, T0, ID_A, R.FLAG_USER_EDITED, label="Main Street Glow",
                                     category=R.CAT_SHOW, kind="show", place=R.PLACE_LIBRARY)),
        ("user preset with note", body(0, P_ANIM, T0 + 5, ID_I, R.FLAG_USER_EDITED | R.FLAG_PRESET,
                                       label="Sparkle ✨", category=R.CAT_ANIMATION,
                                       note="from the parade", kind="animation", place=R.PLACE_PRESETS)),
        ("user preset only (not user edited)", body(0, P_COLOR, T0, ID_I, R.FLAG_PRESET,
                                                    label="Blue", category=R.CAT_COLOR,
                                                    place=R.PLACE_PRESETS)),
        ("user category unknown, raw place", body(0, P_RAW, T0, ID_A, R.FLAG_USER_EDITED,
                                                  label="Band noise?", category=R.CAT_UNKNOWN,
                                                  place=R.PLACE_RAW)),
        ("user legacy android (u=2)", body(0, P_COLOR2, 2, ID_A, R.FLAG_USER_EDITED, label="Old name",
                                           category=R.CAT_COLOR, kind="color", place=R.PLACE_COLORS)),
        ("user legacy ios (u=3)", body(0, P_SHOW2, 3, ID_I, R.FLAG_USER_EDITED, label="Kiss Goodnight",
                                       category=R.CAT_SHOW, place=R.PLACE_LIBRARY)),
        ("user max fields", body(0, P_MAX, T0, ID_I, R.FLAG_USER_EDITED | R.FLAG_PRESET,
                                 label="L" * 64, category=R.CAT_SHOW, note="N" * 160,
                                 kind="K" * 16, place=R.PLACE_LIBRARY)),
        ("reset", body(0, P_SHOW, T0 + 10, ID_I)),
        ("reset with note", body(0, P_SHOW, T0 + 11, ID_I, note="name cleared")),
        ("tombstone", body(0, P_ANIM, T0 + 20, ID_A, R.FLAG_DELETED)),
        ("newwand name", body(1, P_WAND, T0, ID_I, label="Off")),
        ("newwand legacy (u=3) with note", body(1, P_WAND, 3, ID_I, label="Purple", note="my wand")),
        ("newwand deleted", body(1, P_WAND, T0 + 30, ID_I, R.FLAG_DELETED)),
        ("updatedAt exactly 1.5e12", body(0, P_SHOW, R.U_MIN_MS, ID_A)),
    ]


def v_bodies():
    out = []
    for name, f in valid_bodies():
        b = R.encode_body(f)
        back = R.decode_body(b)
        assert R.body_to_json(back) == R.body_to_json(f)
        out.append({"name": name, "body": R.body_to_json(f), "hex": hexu(b), "len": len(b),
                    "crc": R.crc32(b), "class": R.body_class(back),
                    "version": {"updatedAt": f["updatedAt"], "origin": hexu(f.get("origin") or R.ZERO8),
                                "crc": R.crc32(b)}})
    assert max(x["len"] for x in out) <= R.BODY_MAX
    return out


def v_body_rejects():
    k = R.encode_key(0, P_SHOW)
    u = le(T0, 8, True)
    one = le(1, 8, True)
    org = ID_A
    good_user = [(0x10, k), (0x11, u), (0x12, org), (0x13, b"\x02"), (0x14, b"Name"), (0x15, b"\x01"),
                 (0x18, b"\x03")]
    cases = [
        ("order: updatedAt before key", raw_body((0x11, one), (0x10, k)), "BAD_MSG", "order"),
        ("order: label before flags", raw_body((0x10, k), (0x11, u), (0x12, org), (0x14, b"N"),
                                               (0x13, b"\x02"), (0x15, b"\x01"), (0x18, b"\x03")),
         "BAD_MSG", "order"),
        ("duplicate updatedAt", raw_body((0x10, k), (0x11, one), (0x11, one)), "BAD_MSG", "duplicate"),
        ("duplicate label", raw_body((0x10, k), (0x11, u), (0x12, org), (0x13, b"\x02"),
                                     (0x14, b"A"), (0x14, b"B"), (0x15, b"\x01"), (0x18, b"\x03")),
         "BAD_MSG", "duplicate"),
        ("unknown tag 0x19", raw_body(*(good_user + [(0x19, b"\x00")])), "BAD_MSG", "unknown_tag"),
        ("unknown tag 0x01", raw_body((0x01, b"\x00"), (0x10, k), (0x11, one)), "BAD_MSG", "unknown_tag"),
        ("missing key", raw_body((0x11, one)), "BAD_MSG", "missing"),
        ("missing updatedAt", raw_body((0x10, k)), "BAD_MSG", "missing"),
        ("empty body", b"", "BAD_MSG", "missing"),
        ("truncated TLV", raw_body((0x10, k), (0x11, one))[:-3], "BAD_MSG", "truncated"),
        ("lone tag byte", raw_body((0x10, k), (0x11, one)) + b"\x12", "BAD_MSG", "truncated"),
        ("updatedAt 4 bytes", raw_body((0x10, k), (0x11, le(1, 4))), "BAD_MSG", "length"),
        ("origin 7 bytes", raw_body((0x10, k), (0x11, u), (0x12, org[:7])), "BAD_MSG", "length"),
        ("flags 2 bytes", raw_body((0x10, k), (0x11, u), (0x12, org), (0x13, b"\x01\x00")),
         "BAD_MSG", "length"),
        ("key packet too short", raw_body((0x10, b"\x00\x83\x01"), (0x11, one)), "BAD_MSG", "length"),
        ("key packet too long", raw_body((0x10, b"\x00" + P_MAX + b"\x00"), (0x11, one)),
         "BAD_MSG", "length"),
        ("key bad ns", raw_body((0x10, b"\x02" + P_SHOW), (0x11, one)), "BAD_MSG", "range"),
        ("key packet without 8301", raw_body((0x10, b"\x00\xCF\x0B\x00\xC0"), (0x11, one)),
         "BAD_MSG", "packet_prefix"),
        ("label empty", raw_body((0x10, k), (0x11, u), (0x12, org), (0x13, b"\x02"), (0x14, b""),
                                 (0x15, b"\x01"), (0x18, b"\x03")), "BAD_MSG", "length"),
        ("label 65 bytes", raw_body((0x10, k), (0x11, u), (0x12, org), (0x13, b"\x02"),
                                    (0x14, b"L" * 65), (0x15, b"\x01"), (0x18, b"\x03")),
         "BAD_MSG", "length"),
        ("label invalid utf-8", raw_body((0x10, k), (0x11, u), (0x12, org), (0x13, b"\x02"),
                                         (0x14, b"\xC3\x28"), (0x15, b"\x01"), (0x18, b"\x03")),
         "BAD_MSG", "utf8"),
        ("label overlong utf-8", raw_body((0x10, k), (0x11, u), (0x12, org), (0x13, b"\x02"),
                                          (0x14, b"\xC0\xAF"), (0x15, b"\x01"), (0x18, b"\x03")),
         "BAD_MSG", "utf8"),
        ("label utf-16 surrogate", raw_body((0x10, k), (0x11, u), (0x12, org), (0x13, b"\x02"),
                                            (0x14, b"\xED\xA0\x80"), (0x15, b"\x01"), (0x18, b"\x03")),
         "BAD_MSG", "utf8"),
        ("note 161 bytes", raw_body((0x10, k), (0x11, u), (0x12, org), (0x16, b"n" * 161)),
         "BAD_MSG", "length"),
        ("kind non-ascii", raw_body((0x10, k), (0x11, u), (0x12, org), (0x13, b"\x02"), (0x14, b"N"),
                                    (0x15, b"\x01"), (0x17, "bänd".encode()), (0x18, b"\x03")),
         "BAD_MSG", "ascii"),
        ("kind 17 bytes", raw_body((0x10, k), (0x11, u), (0x12, org), (0x13, b"\x02"), (0x14, b"N"),
                                   (0x15, b"\x01"), (0x17, b"k" * 17), (0x18, b"\x03")),
         "BAD_MSG", "length"),
        ("category 4", raw_body((0x10, k), (0x11, u), (0x12, org), (0x13, b"\x02"), (0x14, b"N"),
                                (0x15, b"\x04"), (0x18, b"\x03")), "BAD_MSG", "range"),
        ("place 0", raw_body((0x10, k), (0x11, u), (0x12, org), (0x13, b"\x02"), (0x14, b"N"),
                             (0x15, b"\x01"), (0x18, b"\x00")), "BAD_MSG", "range"),
        ("place 5", raw_body((0x10, k), (0x11, u), (0x12, org), (0x13, b"\x02"), (0x14, b"N"),
                             (0x15, b"\x01"), (0x18, b"\x05")), "BAD_MSG", "range"),
        ("non-canonical: zero origin present", raw_body((0x10, k), (0x11, one), (0x12, R.ZERO8)),
         "BAD_MSG", "zero_origin"),
        ("non-canonical: zero flags present", raw_body((0x10, k), (0x11, one), (0x13, b"\x00")),
         "BAD_MSG", "zero_flags"),
        ("flags reserved bit", raw_body((0x10, k), (0x11, u), (0x12, org), (0x13, b"\x08")),
         "BAD_MSG", "range"),
        ("oversize 361 bytes", raw_body((0x10, k), (0x11, u), (0x12, org)) + b"\x16\xff" + b"n" * 255
         + b"\x16\x41" + b"n" * 65, "BAD_MSG", "oversize"),
        ("updatedAt 0", raw_body((0x10, k), (0x11, le(0, 8))), "BAD_MSG", "time"),
        ("updatedAt negative", raw_body((0x10, k), (0x11, le(-5, 8, True)), (0x12, org)),
         "BAD_MSG", "time"),
        ("presence with origin (u=1)", raw_body((0x10, k), (0x11, one), (0x12, org)), "BAD_MSG", "class"),
        ("presence with label", raw_body((0x10, k), (0x11, one), (0x14, b"X")), "BAD_MSG", "class"),
        ("presence with note", raw_body((0x10, k), (0x11, one), (0x16, b"X")), "BAD_MSG", "class"),
        ("presence shape at ms time", raw_body((0x10, k), (0x11, u)), "BAD_MSG", "class"),
        ("presence for newwand", raw_body((0x10, R.encode_key(1, P_WAND)), (0x11, one)),
         "BAD_MSG", "class"),
        ("user without label", raw_body((0x10, k), (0x11, u), (0x12, org), (0x13, b"\x02"),
                                        (0x15, b"\x01"), (0x18, b"\x03")), "BAD_MSG", "class"),
        ("user without category", raw_body((0x10, k), (0x11, u), (0x12, org), (0x13, b"\x02"),
                                           (0x14, b"N"), (0x18, b"\x03")), "BAD_MSG", "class"),
        ("user without place", raw_body((0x10, k), (0x11, u), (0x12, org), (0x13, b"\x02"),
                                        (0x14, b"N"), (0x15, b"\x01")), "BAD_MSG", "class"),
        ("user without origin", raw_body((0x10, k), (0x11, u), (0x13, b"\x02"), (0x14, b"N"),
                                         (0x15, b"\x01"), (0x18, b"\x03")), "BAD_MSG", "class"),
        ("user at u=1", raw_body((0x10, k), (0x11, one), (0x12, org), (0x13, b"\x02"), (0x14, b"N"),
                                 (0x15, b"\x01"), (0x18, b"\x03")), "BAD_MSG", "class"),
        ("user at u=4 (invalid range)", raw_body((0x10, k), (0x11, le(4, 8)), (0x12, org),
                                                 (0x13, b"\x02"), (0x14, b"N"), (0x15, b"\x01"),
                                                 (0x18, b"\x03")), "CLOCK", "clock_invalid"),
        ("user at 1.5e12-1", raw_body((0x10, k), (0x11, le(R.U_MIN_MS - 1, 8)), (0x12, org),
                                      (0x13, b"\x02"), (0x14, b"N"), (0x15, b"\x01"), (0x18, b"\x03")),
         "CLOCK", "clock_invalid"),
        ("reset at u=2", raw_body((0x10, k), (0x11, le(2, 8)), (0x12, org)), "BAD_MSG", "class"),
        ("reset with label", raw_body((0x10, k), (0x11, u), (0x12, org), (0x14, b"N")), "BAD_MSG", "class"),
        ("reset with category", raw_body((0x10, k), (0x11, u), (0x12, org), (0x15, b"\x01")),
         "BAD_MSG", "class"),
        ("reset invalid time", raw_body((0x10, k), (0x11, le(1_000_000_000_000, 8)), (0x12, org)),
         "CLOCK", "clock_invalid"),
        ("tombstone with label", raw_body((0x10, k), (0x11, u), (0x12, org), (0x13, b"\x01"), (0x14, b"N")),
         "BAD_MSG", "class"),
        ("tombstone with note", raw_body((0x10, k), (0x11, u), (0x12, org), (0x13, b"\x01"), (0x16, b"N")),
         "BAD_MSG", "class"),
        ("tombstone + user edited", raw_body((0x10, k), (0x11, u), (0x12, org), (0x13, b"\x03"),
                                             (0x14, b"N"), (0x15, b"\x01"), (0x18, b"\x03")),
         "BAD_MSG", "class"),
        ("tombstone without origin", raw_body((0x10, k), (0x11, u), (0x13, b"\x01")), "BAD_MSG", "class"),
        ("tombstone at u=3", raw_body((0x10, k), (0x11, le(3, 8)), (0x12, org), (0x13, b"\x01")),
         "BAD_MSG", "class"),
        ("tombstone with label at invalid time (class wins)",
         raw_body((0x10, k), (0x11, le(99, 8)), (0x12, org), (0x13, b"\x01"), (0x14, b"N")),
         "BAD_MSG", "class"),
        ("newwand without label", raw_body((0x10, R.encode_key(1, P_WAND)), (0x11, u), (0x12, org)),
         "BAD_MSG", "class"),
        ("newwand with category", raw_body((0x10, R.encode_key(1, P_WAND)), (0x11, u), (0x12, org),
                                           (0x14, b"N"), (0x15, b"\x03")), "BAD_MSG", "class"),
        ("newwand user-edited flag", raw_body((0x10, R.encode_key(1, P_WAND)), (0x11, u), (0x12, org),
                                              (0x13, b"\x02"), (0x14, b"N")), "BAD_MSG", "class"),
        ("newwand deleted at u=2", raw_body((0x10, R.encode_key(1, P_WAND)), (0x11, le(2, 8)), (0x12, org),
                                            (0x13, b"\x01")), "BAD_MSG", "class"),
        ("newwand deleted with label", raw_body((0x10, R.encode_key(1, P_WAND)), (0x11, u), (0x12, org),
                                                (0x13, b"\x01"), (0x14, b"N")), "BAD_MSG", "class"),
    ]
    out = []
    for name, data, err, reason in cases:
        e = expect_error(R.decode_body, data)
        assert R.ERR_NAMES[e.code] == err and e.reason == reason, (name, e.code, e.reason)
        out.append({"name": name, "hex": hexu(data), "error": err, "reason": reason})
    return out


def v_clock():
    now = BASE_MS
    out = []
    for name, u, n, res in [
        ("exactly now+24h accepted", now + R.FUTURE_BOUND_MS, now, "OK"),
        ("now+24h+1 rejected", now + R.FUTURE_BOUND_MS + 1, now, "CLOCK"),
        ("past accepted", now - 1, now, "OK"),
        ("presence never future", 1, now, "OK"),
        ("unknown receiver clock: no future check", now + 10 * R.FUTURE_BOUND_MS, None, "OK"),
    ]:
        try:
            R.check_future(u, n)
            got = "OK"
        except R.SyncError as e:
            got = R.ERR_NAMES[e.code]
        assert got == res, name
        out.append({"name": name, "updatedAt": u, "now": n, "result": res})
    # whole-record future check through the apply rule
    led = R.Ledger()
    b = R.encode_body(body(0, P_SHOW, now + R.FUTURE_BOUND_MS + 1, ID_A, R.FLAG_USER_EDITED,
                           label="Future", category=1, place=3))
    st, _, _ = led.apply_remote(b, ID_A, now)
    assert st == "CLOCK"
    out.append({"name": "apply: future USER record", "bodyHex": hexu(b), "now": now, "result": "CLOCK"})
    return out


def v_comparator():
    o_lo = bytes.fromhex("0000000000000001")
    o_hi = bytes.fromhex("8000000000000000")   # big-endian unsigned: larger than 0x7F...
    o_mid = bytes.fromhex("7FFFFFFFFFFFFFFF")
    cases = [
        ("presence < legacy android", (1, R.ZERO8, 5), (2, ID_A, 1), -1),
        ("legacy android < legacy ios", (2, ID_A, 9), (3, ID_I, 1), -1),
        ("legacy ios < ms", (3, ID_I, 0xFFFFFFFF), (R.U_MIN_MS, ID_A, 0), -1),
        ("later ms wins", (T0 + 1, o_lo, 0), (T0, o_hi, 0xFFFFFFFF), 1),
        ("origin tie-break unsigned big-endian", (T0, o_hi, 0), (T0, o_mid, 0xFFFFFFFF), 1),
        ("origin tie-break low", (T0, o_lo, 7), (T0, o_mid, 7), -1),
        ("crc tie-break", (T0, ID_A, 0x00000002), (T0, ID_A, 0xFFFFFFFE), -1),
        ("crc unsigned", (T0, ID_A, 0x80000000), (T0, ID_A, 0x7FFFFFFF), 1),
        ("equal = duplicate", (T0, ID_A, 1234), (T0, ID_A, 1234), 0),
        ("presence equal", (1, R.ZERO8, 77), (1, R.ZERO8, 77), 0),
    ]
    out = []
    for name, a, b, want in cases:
        va = (a[0], int.from_bytes(a[1], "big"), a[2])
        vb = (b[0], int.from_bytes(b[1], "big"), b[2])
        assert R.compare_versions(va, vb) == want, name
        out.append({"name": name,
                    "a": {"updatedAt": a[0], "origin": hexu(a[1]), "crc": a[2]},
                    "b": {"updatedAt": b[0], "origin": hexu(b[1]), "crc": b[2]}, "expect": want})
    return out


def v_local_stamp():
    cases = [
        ("now dominates", BASE_MS, 1, 0),
        ("ledger ahead of clock", BASE_MS, BASE_MS + 5000, 0),
        ("two edits same ms", BASE_MS, 1, BASE_MS),
        ("clock before 2017 floored", 1_000_000_000_000, 3, 0),
        ("legacy ledger entry", BASE_MS, 2, 0),
        ("future ledger entry beats now", BASE_MS, BASE_MS + R.FUTURE_BOUND_MS, BASE_MS + 10),
    ]
    out = []
    for name, now, lu, last in cases:
        out.append({"name": name, "now": now, "ledgerUpdatedAt": lu, "lastLocalStamp": last,
                    "expect": R.local_stamp(now, lu, last)})
    return out


# ---------------------------------------------------------------------------------------------
# Apply sequences
# ---------------------------------------------------------------------------------------------

class ApplyScript(object):
    def __init__(self, name, tomb_cap=R.TOMBSTONE_CAP_PHONE, next_seq=1, note=None):
        self.name = name
        self.led = R.Ledger(tombstone_cap=tomb_cap, next_sync_seq=next_seq)
        self.steps = []
        self.tomb_cap, self.next_seq = tomb_cap, next_seq
        self.note = note

    def remote(self, b, frm, now, want=None):
        if isinstance(b, dict):
            b = R.encode_body(b)
        st, e, ev = self.led.apply_remote(b, frm, now)
        if want is not None:
            assert st == want, (self.name, st, want)
        self.steps.append({"op": "remote", "bodyHex": hexu(b), "from": hexu(frm), "now": now,
                           "expect": {"status": st, "evicted": ev,
                                      "entry": e.to_json() if (e is not None and st == "ACCEPT") else None}})
        return st

    def edit(self, cls, ns, packet, now, self_id, **kw):
        e, ev = self.led.local_edit(cls, ns, packet, now, self_id, **kw)
        step = {"op": "edit", "class": cls, "key": {"ns": ns, "packet": hexu(packet)}, "now": now,
                "self": hexu(self_id)}
        for k in ("label", "category", "kind", "place", "note"):
            if kw.get(k) is not None:
                step[k] = kw[k]
        if cls == R.CLASS_USER:
            step["preset"] = bool(kw.get("preset", False))
            step["userEdited"] = bool(kw.get("user_edited", True))
        step["expect"] = {"bodyHex": hexu(e.body), "updatedAt": e.version[0], "evicted": ev,
                          "entry": e.to_json() if e.key_string in self.led.entries else None}
        self.steps.append(step)
        return e

    def learn(self, packet, want):
        e = self.led.local_learn(packet)
        assert (e is not None) == want, self.name
        self.steps.append({"op": "learn", "packet": hexu(packet),
                           "expect": {"created": e is not None, "entry": e.to_json() if e else None}})

    def to_json(self):
        j = {"name": self.name, "tombstoneCap": self.tomb_cap, "nextSyncSeq": self.next_seq,
             "steps": self.steps,
             "final": {"nextSyncSeq": self.led.next_sync_seq, "lastLocalStamp": self.led.last_local_stamp,
                       "tombstones": self.led.tombstone_count(), "entries": self.led.to_json()}}
        if self.note:
            j["note"] = self.note
        return j


def v_apply():
    out = []
    now = BASE_MS

    s = ApplyScript("presence then user then duplicate then stale")
    s.remote(body(0, P_SHOW, 1), ID_A, now, "ACCEPT")
    s.remote(body(0, P_SHOW, 1), ID_H, now, "DUPLICATE")
    u1 = body(0, P_SHOW, T0, ID_I, R.FLAG_USER_EDITED, label="Glow", category=1, place=3)
    s.remote(u1, ID_H, now, "ACCEPT")
    s.remote(u1, ID_A, now, "DUPLICATE")
    s.remote(body(0, P_SHOW, T0 - 1, ID_A, R.FLAG_USER_EDITED, label="Older", category=1, place=3),
             ID_A, now, "STALE")
    s.remote(body(0, P_SHOW, 1), ID_A, now, "STALE")
    out.append(s.to_json())

    s = ApplyScript("same updatedAt: origin then crc decide (order independent)")
    a = body(0, P_ANIM, T0, ID_A, R.FLAG_USER_EDITED, label="From Android", category=2, place=3)
    i = body(0, P_ANIM, T0, ID_I, R.FLAG_USER_EDITED, label="From iPhone", category=2, place=3)
    win = a if ID_A > ID_I else i
    lose = i if win is a else a
    s.remote(lose, ID_H, now, "ACCEPT")
    s.remote(win, ID_H, now, "ACCEPT")
    s.remote(lose, ID_H, now, "STALE")
    c1 = body(0, P_COLOR, T0, ID_I, R.FLAG_USER_EDITED, label="Red", category=3, place=2)
    c2 = body(0, P_COLOR, T0, ID_I, R.FLAG_USER_EDITED, label="Green", category=3, place=2)
    b1, b2 = R.encode_body(c1), R.encode_body(c2)
    hi, lo = (b1, b2) if R.crc32(b1) > R.crc32(b2) else (b2, b1)
    s.remote(hi, ID_A, now, "ACCEPT")
    s.remote(lo, ID_A, now, "STALE")
    out.append(s.to_json())

    s = ApplyScript("reverse order converges to the same ledger")
    s.remote(win, ID_H, now, "ACCEPT")
    s.remote(lose, ID_H, now, "STALE")
    s.remote(lo, ID_A, now, "ACCEPT")
    s.remote(hi, ID_A, now, "ACCEPT")
    out.append(s.to_json())
    assert out[-1]["final"]["entries"][0]["b"] == out[-2]["final"]["entries"][0]["b"]

    s = ApplyScript("local edits: rename beats any version, re-stamp rules")
    s.remote(body(0, P_SHOW, 1), ID_A, now, "ACCEPT")
    s.edit(R.CLASS_USER, 0, P_SHOW, now, ID_I, label="  Main St  ", category=1, kind="show", place=3)
    s.edit(R.CLASS_USER, 0, P_SHOW, now, ID_I, label="Main Street", category=1, kind="show", place=3)
    s.remote(body(0, P_SHOW, now + 3_600_000, ID_A, R.FLAG_USER_EDITED, label="Skewed clock", category=1,
                  place=3), ID_A, now, "ACCEPT")
    s.edit(R.CLASS_USER, 0, P_SHOW, now + 10, ID_I, label="Wins anyway", category=1, place=3)
    s.edit(R.CLASS_RESET, 0, P_SHOW, now + 20, ID_I, note="back to the generated name")
    s.learn(P_SHOW, False)
    out.append(s.to_json())

    s = ApplyScript("tombstone blocks learn; save-as-preset beats tombstone")
    s.learn(P_ANIM, True)
    s.edit(R.CLASS_TOMBSTONE, 0, P_ANIM, now, ID_A)
    s.learn(P_ANIM, False)
    s.remote(body(0, P_ANIM, 1), ID_H, now, "STALE")
    s.edit(R.CLASS_USER, 0, P_ANIM, now + 1000, ID_A, label="Saved again", category=2, kind="animation",
           place=1, preset=True)
    s.remote(body(0, P_ANIM, now + 500, ID_I, R.FLAG_DELETED), ID_I, now, "STALE")
    out.append(s.to_json())

    s = ApplyScript("PRESET clear is full state", note="a newer USER without PRESET replaces one with it")
    s.remote(body(0, P_COLOR, T0, ID_I, R.FLAG_USER_EDITED | R.FLAG_PRESET, label="Blue", category=3,
                  place=1), ID_I, now, "ACCEPT")
    s.remote(body(0, P_COLOR, T0 + 1, ID_A, R.FLAG_USER_EDITED, label="Blue", category=3, place=2),
             ID_A, now, "ACCEPT")
    out.append(s.to_json())

    s = ApplyScript("newwand set, rename, delete")
    s.edit(R.CLASS_NEWWAND, 1, P_WAND, now, ID_I, label="Off")
    s.remote(body(1, P_WAND, 3, ID_A, label="Legacy name"), ID_A, now, "STALE")
    s.edit(R.CLASS_NEWWAND, 1, P_WAND, now + 1, ID_I, label="Lights out", note="end of night")
    s.edit(R.CLASS_NEWWAND, 1, P_WAND, now + 2, ID_I, label="   ")
    out.append(s.to_json())

    s = ApplyScript("rejections leave the ledger unchanged")
    s.remote(unhex("10140083" + "01E100"), ID_A, now, "BAD_MSG")
    s.remote(body(0, P_SHOW, now + R.FUTURE_BOUND_MS + 1, ID_A, R.FLAG_DELETED), ID_A, now, "CLOCK")
    s.remote(raw_body((0x10, R.encode_key(0, P_SHOW)), (0x11, le(4, 8)), (0x12, ID_A)), ID_A, now, "CLOCK")
    s.remote(body(0, P_SHOW, now + R.FUTURE_BOUND_MS + 1, ID_A, R.FLAG_DELETED), ID_A, None, "ACCEPT")
    out.append(s.to_json())

    s = ApplyScript("tombstone cap 3: oldest version evicted", tomb_cap=3, next_seq=100)
    pk = [bytes.fromhex("830101%02X" % n) for n in range(1, 6)]
    s.remote(body(0, pk[0], T0 + 40, ID_A, R.FLAG_DELETED), ID_A, now, "ACCEPT")
    s.remote(body(0, pk[1], T0 + 10, ID_A, R.FLAG_DELETED), ID_A, now, "ACCEPT")
    s.remote(body(0, pk[2], T0 + 30, ID_A, R.FLAG_DELETED), ID_A, now, "ACCEPT")
    s.remote(body(0, pk[3], T0 + 20, ID_A, R.FLAG_DELETED), ID_A, now, "ACCEPT")   # evicts pk[1]
    s.remote(body(0, pk[1], 1), ID_H, now, "ACCEPT")                               # key had no entry
    s.remote(body(0, pk[4], T0 + 5, ID_A, R.FLAG_DELETED), ID_A, now, "ACCEPT")    # evicted at once
    out.append(s.to_json())
    return out


# ---------------------------------------------------------------------------------------------
# Messages
# ---------------------------------------------------------------------------------------------

def hello_fields(**over):
    f = {"proto": 1, "deviceId": ID_I, "kind": R.KIND_IOS, "dbId": det("db-I", 8), "clockMs": BASE_MS,
         "feedHigh": 1234, "subs": 0x07, "caps": 0x0001, "maxMsg": 1024, "bootId": 0x1001,
         "version": "1.4.0", "name": "iPhone", "groupId": GID1, "nonce": det("nonce-c-1", 8)}
    f.update(over)
    return {k: v for k, v in f.items() if v is not None}


def hb_fields(**over):
    f = {"deviceId": ID_H, "kind": R.KIND_HUB, "bootId": 0x3003, "hbSeq": 17, "ts": BASE_MS,
         "uptimeS": 3600, "battPct": 81, "battMv": 3987, "charging": 0, "runtimeMin": 300,
         "version": "2.0 heltec-v3", "name": "MM_ESP",
         "link": [{"peerId": ID_I, "peerKind": 3, "flags": 0x01},
                  {"peerId": ID_A, "peerKind": 2, "flags": 0x03}],
         "state": 0x0080, "hops": 0, "feedHigh": 5670, "dbId": det("db-H", 8), "records": 1234}
    f.update(over)
    return {k: v for k, v in f.items() if v is not None}


def valid_messages():
    rec_body = R.encode_body(body(0, P_SHOW, T0, ID_I, R.FLAG_USER_EDITED, label="Main Street Glow",
                                  category=1, kind="show", place=3))
    big_body = R.encode_body(body(0, P_MAX, T0, ID_I, R.FLAG_USER_EDITED | R.FLAG_PRESET,
                                  label="L" * 64, category=1, note="N" * 160, kind="K" * 16, place=3))
    return [
        ("HELLO central, grouped", R.HELLO, hello_fields()),
        ("HELLO peripheral reply with proof", R.HELLO,
         hello_fields(deviceId=ID_H, kind=R.KIND_HUB, dbId=det("db-H", 8), clockMs=0, feedHigh=0,
                      caps=0x0039, maxMsg=512, bootId=0x3003, version="2.0 esp32", name="MM_ESP",
                      nonce=det("nonce-p-1", 8),
                      proof=R.proof_p(GROUP_KEY_1, det("nonce-c-1", 8), det("nonce-p-1", 8), ID_I, ID_H))),
        ("HELLO minimal ungrouped (optional tags absent, caps 0)", R.HELLO,
         hello_fields(caps=0, version=None, name=None, groupId=R.ZERO8, feedHigh=0, clockMs=0)),
        ("AUTH", R.AUTH, {"proof": R.proof_c(GROUP_KEY_1, det("nonce-c-1", 8), det("nonce-p-1", 8),
                                             ID_I, ID_H)}),
        ("JOIN", R.JOIN, {"groupId": GID1, "groupKey": GROUP_KEY_1}),
        ("JOIN rekey", R.JOIN, {"groupId": GID2, "groupKey": GROUP_KEY_2, "flags": 1}),
        ("PULL defaults (limit/maxBytes/exclude omitted)", R.PULL,
         {"reqId": 1, "since": 0, "dbId": det("db-H", 8)}),
        ("PULL small MTU, exclude", R.PULL,
         {"reqId": 255, "since": 5600, "limit": 8, "maxBytes": 512, "dbId": det("db-H", 8), "exclude": 1}),
        ("REC page", R.REC, {"seq": 42, "reqId": 3, "body": rec_body}),
        ("REC live with seenBy", R.REC, {"seq": 43, "reqId": 0, "seenBy": [ID_I, ID_H, ID_A],
                                         "body": rec_body}),
        ("REC live presence, 4 seenBy (max), max body", R.REC,
         {"seq": 0xFFFFFFFF, "reqId": 0, "seenBy": [ID_I, ID_H, ID_A, ID_S], "body": big_body}),
        ("PAGE_END", R.PAGE_END, {"reqId": 3, "scannedTo": 5670, "more": 1, "feedHigh": 5678, "count": 24}),
        ("PAGE_END empty", R.PAGE_END, {"reqId": 1, "scannedTo": 0, "more": 0, "feedHigh": 0, "count": 0}),
        ("EVT full", R.EVT, {"origin": ID_A, "epoch": 1796000000, "seq": 1, "ts": BASE_MS + 123,
                             "packet": P_EV1, "rssi": -67, "count": 3, "lat": 283852000, "lon": -815639000,
                             "acc": 12, "addr": bytes.fromhex("C0FFEE123456"), "flags": 0x01,
                             "seenBy": [ID_A, ID_I]}),
        ("EVT minimal (no rssi, count 1, no fix)", R.EVT,
         {"origin": ID_A, "epoch": 1796000000, "seq": 2, "ts": BASE_MS, "packet": P_EV2}),
        ("EVT replay via hub", R.EVT, {"origin": ID_A, "epoch": 7, "seq": 9, "ts": BASE_MS, "packet": P_EV2,
                                       "rssi": -90, "flags": 0x02, "seenBy": [ID_A, ID_H, ID_I]}),
        ("EVT_SINCE", R.EVT_SINCE, {"origin": ID_A, "epoch": 1796000000, "afterSeq": 41, "requester": ID_I}),
        ("EVT_GAP", R.EVT_GAP, {"origin": ID_A, "epoch": 1796000000, "firstAvail": 100, "lastAvail": 2099,
                                "curEpoch": 1796000500, "requester": ID_I}),
        ("EVT_GAP none available", R.EVT_GAP, {"origin": ID_A, "epoch": 5, "firstAvail": 0, "lastAvail": 0,
                                               "curEpoch": 6, "requester": ID_I}),
        ("HB hub full", R.HB, hb_fields()),
        ("HB android (hubAirAgoS, defaults omitted)", R.HB,
         hb_fields(deviceId=ID_A, kind=2, bootId=0x2002, battMv=-1, runtimeMin=-1, version="1.4.0",
                   name="Pixel 8", link=[{"peerId": ID_H, "peerKind": 1, "flags": 0x03}], state=0x0001,
                   hubAirAgoS=12, dbId=det("db-A", 8))),
        ("HB iphone forwarded (hops 1) with evtWm", R.HB,
         hb_fields(deviceId=ID_I, kind=3, bootId=0x1001, battMv=-1, charging=1, version="1.4.0",
                   name="iPhone", link=[], state=0x0080, hops=1, dbId=det("db-I", 8),
                   evtWm=[{"origin": ID_A, "epoch": 1796000000, "seq": 41}])),
        ("HELLO largest (all optional tags, 136 bytes)", R.HELLO,
         hello_fields(kind=R.KIND_ANDROID, deviceId=ID_A, caps=0x003B, version="V" * 16, name="N" * 20,
                      proof=bytes(range(16)))),
        ("HB largest (4 links, 4 evtWm, 247 bytes)", R.HB,
         hb_fields(deviceId=ID_A, kind=2, version="V" * 16, name="N" * 20, hubAirAgoS=0xFFFF, state=0x0FFF,
                   link=[{"peerId": x, "peerKind": k, "flags": 7} for x, k in
                         ((ID_H, 1), (ID_I, 3), (ID_S, 3), (ID_X, 1))],
                   evtWm=[{"origin": x, "epoch": 1796000000 + n, "seq": n} for n, x in
                          enumerate((ID_A, ID_S, ID_X, ID_H))])),
        ("HB minimal (all optional absent)", R.HB,
         {"deviceId": ID_H, "kind": 1, "bootId": 1, "hbSeq": 1, "ts": 0, "uptimeS": 5, "hops": 0,
          "feedHigh": 0, "dbId": det("db-H", 8), "records": 0}),
        ("SUB", R.SUB, {"subs": 0x05}),
        ("ERR DB_CHANGED", R.ERR, {"code": R.E_DB_CHANGED, "refType": R.PULL, "dbId": det("db-H2", 8)}),
        ("ERR CLOCK with key", R.ERR, {"code": R.E_CLOCK, "refType": R.REC,
                                       "key": {"ns": 0, "packet": P_SHOW}, "detail": "future +25h"}),
        ("ERR BUSY retry", R.ERR, {"code": R.E_BUSY, "refType": R.REC, "retryMs": 1000}),
        ("ERR AUTH bare", R.ERR, {"code": R.E_AUTH}),
    ]


def v_messages():
    out = []
    for name, mt, f in valid_messages():
        b = R.encode_msg(mt, f)
        t2, back = R.decode_msg(b)
        assert t2 == mt
        assert R.encode_msg(mt, back) == b, name
        j = R.msg_fields_to_json(mt, back)
        assert R.encode_msg(mt, R.msg_fields_from_json(mt, j)) == b
        assert len(b) <= R.MAXMSG_MIN, (name, len(b))
        out.append({"name": name, "type": R.MSG_NAMES[mt], "typeCode": mt, "fields": j, "hex": hexu(b),
                    "len": len(b)})
    return out


def v_message_noncanonical():
    """Accepted by decoders; re-encoding gives canonicalHex."""
    pull = R.encode_msg(R.PULL, {"reqId": 1, "since": 0, "dbId": det("db-H", 8)})
    cases = [
        ("PULL explicit defaults", bytes([R.PULL]) + R.tlv(1, b"\x01") + R.tlv(2, le(0, 4)) +
         R.tlv(3, b"\x18") + R.tlv(4, le(1536, 2)) + R.tlv(5, det("db-H", 8)) + R.tlv(6, b"\x00")),
        ("PULL unknown tags skipped (0x07 and 0x99)", pull + R.tlv(0x07, b"abc") + R.tlv(0x99, b"")),
        ("PULL repeated unknown tag", pull + R.tlv(0x40, b"\x01") + R.tlv(0x40, b"\x02")),
        ("SUB unknown subs bits kept", bytes([R.SUB]) + R.tlv(1, b"\xF5")),
        ("HB unknown tag 0x30 between known", bytes([R.HB]) + b"".join(
            R.tlv(t, v) for t, v in [(1, ID_H), (2, b"\x01"), (3, le(1, 2)), (4, le(1, 4)), (5, le(0, 8)),
                                     (6, le(5, 4)), (0x0F, b"\x00"), (0x10, le(0, 4)), (0x11, det("db-H", 8)),
                                     (0x12, le(0, 4)), (0x30, b"future")])),
        ("REC body tags before envelope tags", bytes([R.REC]) + R.encode_body(body(0, P_SHOW, 1)) +
         R.tlv(1, le(7, 4)) + R.tlv(2, b"\x00")),
        ("ERR unknown code", bytes([R.ERR]) + R.tlv(1, b"\xC8")),
    ]
    out = []
    for name, data in cases:
        mt, f = R.decode_msg(data)
        canon = R.encode_msg(mt, f)
        out.append({"name": name, "type": R.MSG_NAMES[mt], "hex": hexu(data),
                    "fields": R.msg_fields_to_json(mt, f), "canonicalHex": hexu(canon)})
    return out


def v_message_rejects():
    hello = R.encode_msg(R.HELLO, hello_fields())
    pull = R.encode_msg(R.PULL, {"reqId": 1, "since": 0, "dbId": det("db-H", 8)})
    body_tlvs = R.encode_body(body(0, P_SHOW, 1))

    def strip(data, tag):
        out = bytearray(data[:1])
        for t, v, raw in R.parse_tlvs(data, 1):
            if t != tag:
                out += raw
        return bytes(out)

    def msg(mt, *pairs):
        return bytes([mt]) + b"".join(R.tlv(t, v) for t, v in pairs)

    cases = [
        ("empty message", b"", "empty"),
        ("HELLO missing nonce", strip(hello, 0x0E), "missing"),
        ("HELLO missing groupId", strip(hello, 0x0D), "missing"),
        ("HELLO kind 4", hello.replace(R.tlv(3, b"\x03"), R.tlv(3, b"\x04")), "range"),
        ("HELLO maxMsg 511", hello.replace(R.tlv(9, le(1024, 2)), R.tlv(9, le(511, 2))), "range"),
        ("HELLO deviceId 7 bytes", hello.replace(R.tlv(2, ID_I), R.tlv(2, ID_I[:7])), "length"),
        ("HELLO duplicate nonce", hello + R.tlv(0x0E, det("x", 8)), "duplicate"),
        ("HELLO groupId after nonce", hello + R.tlv(0x0D, GID1), "order"),
        ("HELLO name 21 bytes", hello.replace(R.tlv(0x0C, b"iPhone"), R.tlv(0x0C, b"N" * 21)), "length"),
        ("HELLO empty name", hello.replace(R.tlv(0x0C, b"iPhone"), R.tlv(0x0C, b"")), "length"),
        ("HELLO version invalid utf-8", hello.replace(R.tlv(0x0B, b"1.4.0"), R.tlv(0x0B, b"\xff")), "utf8"),
        ("HELLO clockMs negative", hello.replace(R.tlv(5, le(BASE_MS, 8)), R.tlv(5, le(-1, 8, True))),
         "range"),
        ("tags out of order", msg(R.PULL, (2, le(0, 4)), (1, b"\x01"), (5, det("db-H", 8))), "order"),
        ("non-repeatable tag twice", msg(R.PULL, (1, b"\x01"), (1, b"\x02"), (2, le(0, 4)),
                                         (5, det("db-H", 8))), "duplicate"),
        ("TLV overrun", pull[:-1], "truncated"),
        ("lone tag byte", pull + b"\x07", "truncated"),
        ("PULL reqId 0", msg(R.PULL, (1, b"\x00"), (2, le(0, 4)), (5, det("db-H", 8))), "range"),
        ("PULL limit 33", msg(R.PULL, (1, b"\x01"), (2, le(0, 4)), (3, b"\x21"), (5, det("db-H", 8))), "range"),
        ("PULL limit 0", msg(R.PULL, (1, b"\x01"), (2, le(0, 4)), (3, b"\x00"), (5, det("db-H", 8))), "range"),
        ("PULL maxBytes 255", msg(R.PULL, (1, b"\x01"), (2, le(0, 4)), (4, le(255, 2)),
                                  (5, det("db-H", 8))), "range"),
        ("PULL maxBytes 1537", msg(R.PULL, (1, b"\x01"), (2, le(0, 4)), (4, le(1537, 2)),
                                   (5, det("db-H", 8))), "range"),
        ("PULL exclude 2", msg(R.PULL, (1, b"\x01"), (2, le(0, 4)), (5, det("db-H", 8)), (6, b"\x02")), "range"),
        ("PULL since 3 bytes", msg(R.PULL, (1, b"\x01"), (2, le(0, 3)), (5, det("db-H", 8))), "length"),
        ("REC missing seq", msg(R.REC, (2, b"\x00")) + body_tlvs, "missing"),
        ("REC 5 seenBy", msg(R.REC, (1, le(1, 4)), (2, b"\x00"), (3, ID_I), (3, ID_H), (3, ID_A), (3, ID_S),
                             (3, ID_X)) + body_tlvs, "count"),
        ("REC seenBy on a page record", msg(R.REC, (1, le(1, 4)), (2, b"\x05"), (3, ID_I)) + body_tlvs,
         "seenby_on_page"),
        ("PAGE_END more 2", msg(R.PAGE_END, (1, b"\x01"), (2, le(0, 4)), (3, b"\x02"), (4, le(0, 4)),
                                (5, b"\x00")), "range"),
        ("PAGE_END missing count", msg(R.PAGE_END, (1, b"\x01"), (2, le(0, 4)), (3, b"\x00"), (4, le(0, 4))),
         "missing"),
        ("EVT seq 0", msg(R.EVT, (1, ID_A), (2, le(1, 4)), (3, le(0, 4)), (4, le(0, 8)), (5, P_EV1)), "range"),
        ("EVT epoch 0", msg(R.EVT, (1, ID_A), (2, le(0, 4)), (3, le(1, 4)), (4, le(0, 8)), (5, P_EV1)), "range"),
        ("EVT packet without 8301", msg(R.EVT, (1, ID_A), (2, le(1, 4)), (3, le(1, 4)), (4, le(0, 8)),
                                        (5, bytes.fromhex("CF0B00C0"))), "packet_prefix"),
        ("EVT packet 2 bytes", msg(R.EVT, (1, ID_A), (2, le(1, 4)), (3, le(1, 4)), (4, le(0, 8)),
                                   (5, b"\x83\x01")), "length"),
        ("EVT lat without lon/acc", msg(R.EVT, (1, ID_A), (2, le(1, 4)), (3, le(1, 4)), (4, le(0, 8)),
                                        (5, P_EV1), (8, le(1, 4, True))), "fix"),
        ("EVT lat out of range", msg(R.EVT, (1, ID_A), (2, le(1, 4)), (3, le(1, 4)), (4, le(0, 8)),
                                     (5, P_EV1), (8, le(900000001, 4, True)), (9, le(0, 4, True)),
                                     (0x0A, le(5, 2))), "range"),
        ("EVT count 0", msg(R.EVT, (1, ID_A), (2, le(1, 4)), (3, le(1, 4)), (4, le(0, 8)), (5, P_EV1),
                            (7, le(0, 2))), "range"),
        ("HB battPct 101", R.encode_msg(R.HB, hb_fields()).replace(R.tlv(7, le(81, 1, True)),
                                                                     R.tlv(7, le(101, 1, True))), "range"),
        ("HB hops 2", R.encode_msg(R.HB, hb_fields()).replace(R.tlv(0x0F, b"\x00"), R.tlv(0x0F, b"\x02")),
         "range"),
        ("HB link 9 bytes", R.encode_msg(R.HB, hb_fields(link=[])).replace(
            R.tlv(0x0E, le(0x80, 2)), R.tlv(0x0D, ID_I + b"\x03") + R.tlv(0x0E, le(0x80, 2))), "length"),
        ("HB missing hops", strip(R.encode_msg(R.HB, hb_fields()), 0x0F), "missing"),
        ("JOIN zero groupId", msg(R.JOIN, (1, R.ZERO8), (2, GROUP_KEY_1)), "range"),
        ("JOIN key 15 bytes", msg(R.JOIN, (1, GID1), (2, GROUP_KEY_1[:15])), "length"),
        ("AUTH proof 15 bytes", msg(R.AUTH, (1, b"\x00" * 15)), "length"),
        ("ERR code 0", msg(R.ERR, (1, b"\x00")), "range"),
        ("ERR detail 41 bytes", msg(R.ERR, (1, b"\x03"), (4, b"d" * 41)), "length"),
        ("ERR key bad ns", msg(R.ERR, (1, b"\x07"), (3, b"\x05" + P_SHOW)), "range"),
    ]
    out = []
    for name, data, reason in cases:
        e = expect_error(R.decode_msg, data)
        assert e.code == R.E_BAD_MSG and e.reason == reason, (name, e.reason)
        out.append({"name": name, "hex": hexu(data), "error": "BAD_MSG", "reason": reason})
    return out


def v_message_bad_body():
    """REC whose envelope is fine but whose body is not: the message is accepted (it counts for
    the page) and the record is rejected with ERR{code, refType 3, key}."""
    out = []
    for name, data, err in [
        ("REC body non-canonical order", raw_body((0x11, le(1, 8)), (0x10, R.encode_key(0, P_SHOW))), "BAD_MSG"),
        ("REC body invalid time", raw_body((0x10, R.encode_key(0, P_SHOW)), (0x11, le(99, 8)),
                                           (0x12, ID_A)), "CLOCK"),
        ("REC body unknown tag 0x1A", R.encode_body(body(0, P_SHOW, 1)) + R.tlv(0x1A, b"\x00"), "BAD_MSG"),
        ("REC without body", b"", "BAD_MSG"),
    ]:
        m = bytes([R.REC]) + R.tlv(1, le(9, 4)) + R.tlv(2, b"\x02") + data
        mt, f = R.decode_msg(m)
        assert R.ERR_NAMES[f["bodyError"].code] == err
        key = None
        try:
            for t, v, _ in R.parse_tlvs(data):
                if t == 0x10:
                    ns, p = R.decode_key(v)
                    key = {"ns": ns, "packet": hexu(p)}
        except R.SyncError:
            pass
        out.append({"name": name, "hex": hexu(m), "fields": R.msg_fields_to_json(mt, f), "bodyError": err,
                    "errKey": key})
    return out


def v_message_ignored():
    return [{"name": "unknown type 0x0D", "hex": "0D0101FF"},
            {"name": "unknown type 0xF0 with garbage", "hex": "F0FFFF"},
            {"name": "type 0x00", "hex": "00"}]


def v_hb_hops():
    out = []
    for name, f in [("hub HB", hb_fields()),
                    ("HB with unknown tag kept", None)]:
        if f is not None:
            data = R.encode_msg(R.HB, f)
        else:
            data = R.encode_msg(R.HB, hb_fields(link=[])) + R.tlv(0x30, b"keep me")
        fw = R.hb_set_hops(data, 1)
        assert R.decode_msg(fw)[1]["hops"] == 1
        out.append({"name": name, "inHex": hexu(data), "outHex": hexu(fw)})
    return out


# ---------------------------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------------------------

def v_frames():
    msgs = valid_messages()
    small = R.encode_msg(R.SUB, {"subs": 5})
    hello = R.encode_msg(*[(m, f) for n, m, f in msgs if n == "HELLO central, grouped"][0])
    rec = R.encode_msg(*[(m, f) for n, m, f in msgs if n.startswith("REC live presence, 4 seenBy")][0])
    hb = R.encode_msg(R.HB, hb_fields())
    out = []
    for mtu in (23, 185, 247):
        for name, seq_msgs, c0, s0 in [
            ("single small message", [small], 0, 0),
            ("HELLO", [hello], 0, 0),
            ("max REC", [rec], 0, 0),
            ("HB then SUB", [hb, small], 0, 0),
            ("counter wraps 15->0 and seq wraps 255->0", [small, hello], 15, 254),
        ]:
            fr = R.Fragmenter(c0, s0)
            frames = []
            per = []
            for m in seq_msgs:
                f = fr.fragment(m, mtu)
                frames += f
                per.append(len(f))
            # self-check: reassembly gives the messages back
            ra = R.Reassembler(4096)
            ra.expected = s0
            got = []
            for f in frames:
                for a in ra.feed(f):
                    assert a[0] == "deliver", a
                    got.append(a[1])
            assert got == seq_msgs
            for f in frames:
                assert len(f) <= mtu - R.ATT_OVERHEAD
            out.append({"name": "%s @MTU %d" % (name, mtu), "mtu": mtu, "chunk": R.chunk_size(mtu),
                        "startCounter": c0, "startSeq": s0, "messages": [hexu(m) for m in seq_msgs],
                        "framesPerMessage": per, "frames": [hexu(f) for f in frames]})
    return out


def v_reassembly():
    hello = R.encode_msg(R.HELLO, hello_fields())
    sub = R.encode_msg(R.SUB, {"subs": 5})
    hb = R.encode_msg(R.HB, hb_fields())

    def frames(msgs, mtu=23, c0=0, s0=0):
        fr = R.Fragmenter(c0, s0)
        out = []
        for m in msgs:
            out.append(fr.fragment(m, mtu))
        return out

    cases = []
    f = frames([hello, sub])
    cases.append(("normal multi-frame then single", 1024, f[0] + f[1]))
    f = frames([hello, sub])
    cases.append(("frame-seq gap mid-message drops it; next message delivered", 1024,
                  f[0][:2] + f[0][3:] + f[1]))
    f = frames([hello, sub, sub])
    cases.append(("whole single-frame message lost (gap between messages)", 1024, f[0] + f[2]))
    f = frames([hello, sub])
    bad = bytearray(f[0][1])
    bad[0] = (bad[0] & 0xF0) | ((bad[0] + 1) & 0x0F)
    cases.append(("counter change without START drops the partial", 1024,
                  [f[0][0], bytes(bad)] + f[0][2:] + f[1]))
    f = frames([hello, sub])
    cases.append(("START while a partial is open", 1024, [f[0][0], f[0][1]] +
                  [bytes([f[1][0][0], f[0][2][1]]) + f[1][0][2:]]))
    f = frames([hb, sub], mtu=185)
    cases.append(("message larger than maxMsg -> TOO_BIG, rest skipped", 120, f[0] + f[1]))
    f = frames([sub, sub])
    v2 = bytes([0x80 | (f[0][0][0] & 0x3F)]) + f[0][0][1:]
    cases.append(("frame version 2 dropped, ERR PROTO once; the seq it used then shows as a gap", 1024,
                  [v2, v2] + f[1]))
    cases.append(("short frame", 1024, [b"\x70\x00"]))
    f = frames([sub, sub])
    orphan = bytes([0x40 | 0x10 | 0x00, 0x00]) + b"\x09"
    cases.append(("orphan continuation frame", 1024, [orphan] + [bytes([f[1][0][0], 0x01]) + f[1][0][2:]]))
    f = frames([sub, hello], c0=15, s0=255)
    cases.append(("seq wrap 255->0 is not a gap", 1024, f[0] + f[1]))
    out = []
    for name, mx, fl in cases:
        ra = R.Reassembler(mx)
        if name.startswith("seq wrap"):
            ra.expected = 255
        exp = []
        for fr in fl:
            for a in ra.feed(fr):
                if a[0] == "deliver":
                    exp.append({"deliver": hexu(a[1])})
                elif a[0] == "bad_frame":
                    exp.append({"badFrame": a[1]})
                elif a[0] == "err_too_big":
                    exp.append({"errTooBig": a[1]})
                elif a[0] == "err_proto":
                    exp.append({"errProto": a[1]})
        item = {"name": name, "maxMsg": mx, "frames": [hexu(x) for x in fl], "expect": exp}
        if name.startswith("seq wrap"):
            item["startExpectedSeq"] = 255
        out.append(item)
    return out


# ---------------------------------------------------------------------------------------------
# Pages
# ---------------------------------------------------------------------------------------------

class FeedEntry(object):
    def __init__(self, s, b, sync_from):
        self.s, self.body, self.f = s, b, sync_from
        self.origin = R.decode_body(b).get("origin")


def v_pages():
    bodies = []
    for n in range(1, 13):
        p = bytes.fromhex("8301E100E9%02X" % n)
        if n % 3 == 0:
            f = body(0, p, T0 + n, ID_I, R.FLAG_USER_EDITED, label="Record %d" % n, category=1, place=3,
                     note="x" * 150)
        elif n % 3 == 1:
            f = body(0, p, 1)
        else:
            f = body(0, p, T0 + n, ID_A, R.FLAG_USER_EDITED, label="Rec %d" % n, category=2, place=3)
        bodies.append(R.encode_body(f))
    # seqs with holes (superseded entries are simply absent from the current set)
    feed = []
    seqs = [1, 2, 4, 5, 7, 8, 9, 11, 12, 13, 15, 16]
    for k, (s, b) in enumerate(zip(seqs, bodies)):
        frm = ID_I if k in (4, 6) else (ID_A if k == 9 else None)
        feed.append(FeedEntry(s, b, frm))
    dbh = det("db-H", 8)
    cases = [
        ("full feed, defaults, nothing durable beyond 16", 16, 0, {}, ID_A, True),
        ("limit 3", 16, 0, {"limit": 3}, ID_A, True),
        ("since mid-feed", 16, 7, {}, ID_A, True),
        ("durable-only: durableHigh 9 hides seqs 11..16", 9, 0, {}, ID_A, True),
        ("maxBytes 256: first REC always fits, second does not", 16, 2, {"maxBytes": 256}, ID_A, True),
        ("maxBytes 512 small profile", 16, 0, {"limit": 8, "maxBytes": 512}, ID_A, True),
        ("exclude active: skips origin==puller and syncFrom==puller", 16, 0, {"exclude": 1}, ID_I, True),
        ("exclude requested but excludeOk false", 16, 0, {"exclude": 1}, ID_I, False),
        ("exclude skips extend scannedTo after the limit", 16, 0, {"exclude": 1, "limit": 4}, ID_I, True),
        ("since == durableHigh: empty page", 16, 16, {}, ID_A, True),
        ("since beyond durableHigh (should not happen): scannedTo = since", 9, 12, {}, ID_A, True),
        ("empty feed", 0, 0, {}, ID_A, True),
    ]
    out = []
    for name, dh, since, extra, puller, xok in cases:
        pull = {"reqId": 7, "since": since, "dbId": dbh}
        pull.update(extra)
        entries = feed if dh else []
        excl = pull.get("exclude", 0) == 1 and xok
        recs, pe = R.serve_page(entries, dh, since, pull.get("limit", 24), pull.get("maxBytes", 1536), excl,
                                puller, 7)
        out.append({
            "name": name, "puller": hexu(puller), "excludeOk": xok, "durableHigh": dh,
            "entries": [{"seq": e.s, "bodyHex": hexu(e.body), "syncFrom": hexu(e.f)} for e in entries],
            "pull": R.msg_fields_to_json(R.PULL, pull), "pullHex": hexu(R.encode_msg(R.PULL, pull)),
            "expect": {"recSeqs": [R.decode_msg(r)[1]["seq"] for r in recs], "recs": [hexu(r) for r in recs],
                       "pageEnd": pe, "pageEndHex": hexu(R.encode_msg(R.PAGE_END, pe))}})
    return out


# ---------------------------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------------------------

def v_routing():
    I, A, H, S = ID_I, ID_A, ID_H, ID_S
    hx = lambda xs: [hexu(x) for x in xs]
    out = {"localRec": [], "liveRec": [], "evtRelay": [], "androidRoute": [], "hbForward": [],
           "hbReplace": []}
    # local change
    for name, self_id, sess in [
        ("iPhone triangle", I, [(H, True, True), (A, True, True)]),
        ("iPhone hub only", I, [(H, True, True)]),
        ("Android: hub not authed yet", A, [(H, True, False), (I, True, True)]),
        ("Android: iPhone not subscribed to records", A, [(H, True, True), (I, False, True)]),
        ("no sessions", A, []),
    ]:
        t, s = R.route_local_rec(self_id, sess)
        out["localRec"].append({"name": name, "self": hexu(self_id),
                                "sessions": [{"peer": hexu(p), "subRecords": sb, "authed": ok} for p, sb, ok in sess],
                                "expect": {"targets": hx(t), "seenBy": hx(s)}})
    # first accept of a live REC
    for name, self_id, sender, origin, seen, sess in [
        ("hub: iPhone edit, forward to Android", H, I, I, [I, H], [(I, True, True), (A, True, True)]),
        ("android: from hub, nothing left", A, H, I, [I, H, A], [(H, True, True)]),
        ("triangle: nobody forwards (hub)", H, I, I, [I, H, A], [(I, True, True), (A, True, True)]),
        ("triangle: nobody forwards (android)", A, I, I, [I, H, A], [(I, True, True), (H, True, True)]),
        ("partial I-H + I-A: iPhone forwards Android edit to hub", I, A, A, [A, I],
         [(H, True, True), (A, True, True)]),
        ("partial A-H + I-A: Android forwards iPhone edit to hub", A, I, I, [I, A],
         [(I, True, True), (H, True, True)]),
        ("presence (no origin) relayed by hub", H, A, None, [A, H], [(I, True, True), (A, True, True)]),
        ("never back to sender even if seenBy is short", H, A, A, [], [(A, True, True), (I, True, True)]),
        ("target not subscribed", H, I, I, [I, H], [(A, False, True)]),
        ("seenBy truncated to 4", H, I, I, [I, S, ID_X], [(A, True, True), (bytes(range(8)), True, True)]),
    ]:
        t, s = R.route_live_rec(self_id, sender, origin, seen, sess)
        out["liveRec"].append({"name": name, "self": hexu(self_id), "sender": hexu(sender),
                               "origin": hexu(origin), "seenBy": hx(seen),
                               "sessions": [{"peer": hexu(p), "subRecords": sb, "authed": ok} for p, sb, ok in sess],
                               "expect": {"targets": hx(t), "seenBy": hx(s)}})
    # hub event relay
    for name, sender, origin, seen, sess in [
        ("route 2: A -> H -> I", A, A, [A, H], [(I, True, True), (A, False, True)]),
        ("I already in seenBy", A, A, [A, H, I], [(I, True, True)]),
        ("I not a member yet", A, A, [A, H], [(I, True, False)]),
        ("I not subscribed to events", A, A, [A, H], [(I, False, True)]),
    ]:
        t, s = R.route_evt_relay(H, sender, origin, seen, sess)
        out["evtRelay"].append({"name": name, "self": hexu(H), "sender": hexu(sender), "origin": hexu(origin),
                                "seenBy": hx(seen),
                                "sessions": [{"peer": hexu(p), "subEvents": sb, "member": ok} for p, sb, ok in sess],
                                "expect": {"targets": hx(t), "seenBy": hx(s)}})
    # android route choice
    links_ok = [{"peerId": I, "peerKind": 3, "flags": 1}]
    links_unsynced = [{"peerId": I, "peerKind": 3, "flags": 2}]
    for name, ios, hub, age, links in [
        ("route 1 direct", (I, True, True), (H, True), 1000, links_ok),
        ("route 1 needs iPhone events subscription", (I, True, False), (H, True), 1000, links_ok),
        ("route 2 via hub", None, (H, True), 1000, links_ok),
        ("route 2 needs synced flag on hub's iPhone link", None, (H, True), 1000, links_unsynced),
        ("route 2 needs a fresh direct hub HB (90 s)", None, (H, True), 90001, links_ok),
        ("route 2 at exactly 90 s", None, (H, True), 90000, links_ok),
        ("route 3 ring only", (I, False, True), (H, False), 10, links_ok),
        ("route 3 no hub HB", None, (H, True), None, []),
    ]:
        r, tgt, seen = R.android_event_route(A, ios, hub, age, links)
        out["androidRoute"].append({
            "name": name, "self": hexu(A),
            "ios": None if ios is None else {"peer": hexu(ios[0]), "up": ios[1], "subEvents": ios[2]},
            "hub": None if hub is None else {"peer": hexu(hub[0]), "up": hub[1]},
            "hubHbAgeMs": age,
            "hubHbLinks": [{"peerId": hexu(l["peerId"]), "peerKind": l["peerKind"], "flags": l["flags"]}
                           for l in links],
            "expect": {"route": r, "target": hexu(tgt), "seenBy": hx(seen)}})
    # HB forwarding
    for name, self_id, sender, described, hops, sess in [
        ("hub forwards iPhone HB to Android", H, I, I, 0, [(I, True, True), (A, True, True)]),
        ("forwarded HB is not forwarded again", A, H, I, 1, [(H, True, True), (I, True, True)]),
        ("triangle: iPhone forwards Android HB to hub", I, A, A, 0, [(H, True, True), (A, True, True)]),
        ("not to non-members", H, A, A, 0, [(A, True, True), (I, True, False)]),
        ("not to unsubscribed", H, A, A, 0, [(A, True, True), (I, False, True)]),
    ]:
        t = R.route_hb(self_id, sender, described, hops, sess)
        out["hbForward"].append({"name": name, "self": hexu(self_id), "sender": hexu(sender),
                                 "deviceId": hexu(described), "hops": hops,
                                 "sessions": [{"peer": hexu(p), "subHeartbeats": sb, "member": ok}
                                              for p, sb, ok in sess],
                                 "expect": {"targets": hx(t)}})
    for name, st, inc in [
        ("nothing stored", None, {"bootId": 1, "hbSeq": 1}),
        ("greater hbSeq", {"bootId": 1, "hbSeq": 5}, {"bootId": 1, "hbSeq": 6}),
        ("same hbSeq (second path) does not replace", {"bootId": 1, "hbSeq": 5}, {"bootId": 1, "hbSeq": 5}),
        ("older hbSeq", {"bootId": 1, "hbSeq": 5}, {"bootId": 1, "hbSeq": 4}),
        ("new bootId replaces even with lower hbSeq", {"bootId": 1, "hbSeq": 500}, {"bootId": 2, "hbSeq": 1}),
    ]:
        out["hbReplace"].append({"name": name, "stored": st, "incoming": inc,
                                 "expect": R.hb_replaces(st, inc)})
    out["subs"] = [{"selfKind": a, "peerKind": b, "subs": R.subs_for(a, b)}
                   for a in (1, 2, 3) for b in (1, 2, 3) if a != b]
    out["caps"] = [{"kind": k, "caps": v} for k, v in sorted(R.CAPS_BY_KIND.items())]
    return out


# ---------------------------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------------------------

def v_event_dedupe():
    out = []

    def run(name, ops):
        d = R.EvtDedupe()
        steps = []
        for op in ops:
            if op[0] == "evt":
                _, o, e, q = op
                res, lost = d.receive(o, e, q)
                steps.append({"op": "evt", "origin": hexu(o), "epoch": e, "seq": q,
                              "expect": {"result": res, "lost": lost, "holes": d.has_holes(o, e),
                                         "windows": [w.to_json() for w in d.windows(o)]}})
            else:
                _, o, e, fa, la, ce = op
                lost, reqs = d.on_gap(o, e, fa, la, ce)
                steps.append({"op": "gap", "origin": hexu(o), "epoch": e, "firstAvail": fa, "lastAvail": la,
                              "curEpoch": ce,
                              "expect": {"lost": lost, "requests": [{"epoch": a, "afterSeq": b} for a, b in reqs],
                                         "windows": [w.to_json() for w in d.windows(o)]}})
        out.append({"name": name, "steps": steps})

    A = ID_A
    E = 1796000000
    run("first contact starts at the first seq seen", [("evt", A, E, 40), ("evt", A, E, 41), ("evt", A, E, 40),
                                                      ("evt", A, E, 39)])
    run("in-order, duplicate, out of order fill", [("evt", A, E, 1), ("evt", A, E, 2), ("evt", A, E, 2),
                                                  ("evt", A, E, 5), ("evt", A, E, 4), ("evt", A, E, 3),
                                                  ("evt", A, E, 5)])
    run("jump beyond the 64-bit window slides the floor", [("evt", A, E, 1), ("evt", A, E, 3), ("evt", A, E, 70),
                                                          ("evt", A, E, 2), ("evt", A, E, 6), ("evt", A, E, 7)])
    run("window edge: hc+64 fits, hc+65 slides", [("evt", A, E, 1), ("evt", A, E, 65), ("evt", A, E, 66)])
    run("two epochs kept, third evicts the oldest", [("evt", A, E, 1), ("evt", A, E + 10, 1),
                                                     ("evt", A, E, 2), ("evt", A, E + 20, 1),
                                                     ("evt", A, E, 3), ("evt", A, E + 10, 2),
                                                     ("evt", A, E + 5, 1)])
    run("EVT_GAP: floor advances to firstAvail-1", [("evt", A, E, 1), ("evt", A, E, 2),
                                                   ("gap", A, E, 6, 10, E), ("evt", A, E, 6)])
    run("EVT_GAP: epoch gone, ask the current epoch", [("evt", A, E, 1), ("gap", A, E, 0, 0, E + 100),
                                                      ("evt", A, E + 100, 1)])
    run("EVT_GAP: nothing to do when already past firstAvail", [("evt", A, E, 1), ("evt", A, E, 2),
                                                               ("gap", A, E, 2, 9, E)])
    run("per-origin windows are independent", [("evt", A, E, 7), ("evt", ID_S, E, 7), ("evt", A, E, 9),
                                              ("evt", ID_S, E, 8)])
    return out


def v_replay_plan():
    E, E2 = 1796000000, 1796000100
    cases = [
        ("current epoch, covered", [(E, q) for q in range(4, 9)], E, 8, E, 3),
        ("current epoch, up to date", [(E, q) for q in range(4, 9)], E, 8, E, 8),
        ("current epoch, ring overflowed", [(E, q) for q in range(12, 17)], E, 16, E, 8),
        ("old epoch covered, then current from 1", [(E, 5), (E, 6), (E2, 1), (E2, 2)], E2, 2, E, 4),
        ("old epoch complete, current from 1", [(E, 5), (E, 6), (E2, 1), (E2, 2)], E2, 2, E, 6),
        ("old epoch not in ring", [(E2, 1), (E2, 2)], E2, 2, E, 16),
        ("old epoch partly rolled off", [(E, 9), (E, 10), (E2, 1)], E2, 1, E, 4),
        ("requester ahead (ignored)", [(E, 1)], E, 1, E2, 0),
        ("current epoch nothing sent yet", [], E2, 0, E2, 0),
    ]
    out = []
    for name, ring, ce, cs, e, s in cases:
        plan = R.replay_plan(ring, ce, cs, e, s)
        exp = []
        for p in plan:
            if p[0] == "replay":
                exp.append({"replay": {"epoch": p[1], "seq": p[2]}})
            else:
                exp.append({"gap": {"epoch": p[1], "firstAvail": p[2], "lastAvail": p[3], "curEpoch": p[4]}})
        out.append({"name": name, "ring": [[a, b] for a, b in ring], "curEpoch": ce, "curSeq": cs,
                    "epoch": e, "afterSeq": s, "expect": exp})
    return out


# ---------------------------------------------------------------------------------------------
# Session state machine vectors (one session end, scripted inputs)
# ---------------------------------------------------------------------------------------------

def nonce_list(label, n=8):
    return [det("%s-nonce-%d" % (label, k), 8) for k in range(n)]


def make_core(role, dev, kind, boot, maxmsg, group, db, feed_high, label, peer_kind=None, peers=None,
              ready=True, version=None, name=None, tracks=False, clock_base=BASE_MS):
    cfg = R.SessionConfig(role, dev, kind, boot, maxmsg, version=version, name=name, peer_kind=peer_kind,
                          tracks_events=tracks)
    ctx = R.SessionCtx(group=group, db_id=db, feed_high=feed_high,
                       clock=(lambda t: clock_base + t) if clock_base else (lambda t: 0),
                       nonces=nonce_list(label), ready=ready, peers=peers or {})
    return R.SessionCore(cfg, ctx)


def cfg_json(core, label):
    c, x = core.cfg, core.ctx
    j = {"role": c.role, "deviceId": hexu(c.device_id), "kind": c.kind, "bootId": c.boot_id,
         "maxMsg": c.max_msg, "caps": c.caps, "version": c.version, "name": c.name, "peerKind": c.peer_kind,
         "tracksEvents": c.tracks_events, "isHub": c.is_hub}
    ctx = {"groupId": hexu(x.group[0]) if x.group else None, "groupKey": hexu(x.group[1]) if x.group else None,
           "dbId": hexu(x.db_id), "feedHigh": x.feed_high, "clockBaseMs": None, "ready": x.ready,
           "nonces": [hexu(n) for n in x.nonces],
           "peers": {k: v.to_json() for k, v in x.peers.items()}}
    return j, ctx


class SessionScript(object):
    """Drives one SessionCore ("subject") and records inputs, actions and snapshots."""

    def __init__(self, name, core, clock_base, note=None):
        self.name, self.core, self.note = name, core, note
        self.cfg, self.ctx = cfg_json(core, name)
        self.ctx["clockBaseMs"] = clock_base
        self.steps = []

    def do(self, t, inp, mutate=None):
        if mutate:
            mutate(self.core.ctx)
        acts = self.core.handle(t, inp)
        step = {"t": t, "in": dict(inp)}
        if mutate:
            step["ctx"] = {"groupId": hexu(self.core.ctx.group[0]) if self.core.ctx.group else None,
                           "groupKey": hexu(self.core.ctx.group[1]) if self.core.ctx.group else None,
                           "dbId": hexu(self.core.ctx.db_id), "feedHigh": self.core.ctx.feed_high,
                           "ready": self.core.ctx.ready}
        step["out"] = R.public_actions(acts)
        step["after"] = self.core.snapshot()
        self.steps.append(step)
        return [a for a in acts if a["a"] == "send"]

    def rx(self, t, data):
        return self.do(t, {"in": "rx", "hex": hexu(data)})

    def to_json(self):
        j = {"name": self.name, "config": self.cfg, "ctx": self.ctx, "steps": self.steps}
        if self.note:
            j["note"] = self.note
        return j


def sends(acts, typ=None):
    return [unhex(a["hex"]) for a in acts if a["a"] == "send" and (typ is None or a["type"] == typ)]


def v_sessions():
    out = []
    G1 = (GID1, GROUP_KEY_1)
    G2 = (GID2, GROUP_KEY_2)
    dbI, dbH, dbA = det("db-I", 8), det("db-H", 8), det("db-A", 8)

    def pair(name, c_group, p_group, c_kind=R.KIND_IOS, p_kind=R.KIND_HUB, c_peers=None, p_peers=None,
             p_ready=True, c_feed=3, p_feed=0, mtu=185):
        c = make_core("central", ID_I if c_kind == 3 else ID_A, c_kind, 0x1001, 1024, c_group,
                      dbI if c_kind == 3 else dbA, c_feed, name + "-C", peer_kind=p_kind, peers=c_peers,
                      version="1.4.0", name="iPhone" if c_kind == 3 else "Pixel", tracks=(c_kind == 3))
        p = make_core("peripheral", ID_H if p_kind == 1 else ID_A, p_kind, 0x3003,
                      512 if p_kind == 1 else 1024, p_group, dbH if p_kind == 1 else dbA, p_feed,
                      name + "-P", peers=p_peers, ready=p_ready, version="2.0 esp32", name="MM_ESP",
                      clock_base=BASE_MS)
        return c, p

    # 1. central, both grouped alike -> AUTHED -> SYNCING -> SYNCED
    c, p = pair("central handshake grouped alike", G1, G1)
    s = SessionScript("central: grouped alike, full handshake and first pull", c, BASE_MS)
    hello = sends(s.do(0, {"in": "link_up", "mtu": 185}))[0]
    p.handle(0, {"in": "link_up", "mtu": 185})
    reply = sends(p.handle(15, {"in": "rx", "hex": hexu(hello)}))
    s.rx(30, reply[0])
    pe = R.encode_msg(R.PAGE_END, {"reqId": 1, "scannedTo": 0, "more": 0, "feedHigh": 0, "count": 0})
    s.rx(60, pe)
    s.do(60000 + 30, {"in": "timer", "name": "HB"})
    s.do(70000, {"in": "link_down"})
    out.append(s.to_json())

    # 2. peripheral (hub), both grouped -> AUTH verified
    c, p = pair("peripheral handshake grouped alike", G1, G1)
    s = SessionScript("peripheral hub: grouped alike, deadline armed, AUTH verified", p, BASE_MS)
    s.do(0, {"in": "link_up", "mtu": 185})
    hello = sends(c.handle(0, {"in": "link_up", "mtu": 185}))[0]
    s.rx(15, hello)
    rep = s.steps[-1]["out"]
    auth_etc = sends(c.handle(30, {"in": "rx", "hex": [a for a in rep if a["a"] == "send"][0]["hex"]}))
    s.rx(45, auth_etc[0])                      # AUTH
    s.rx(45, auth_etc[1])                      # PULL from the central
    s.rx(50, R.encode_msg(R.PULL, {"reqId": 9, "since": 0, "dbId": det("old-db", 8)}))  # stale dbId
    s.rx(60, R.encode_msg(R.PAGE_END, {"reqId": 1, "scannedTo": 3, "more": 1, "feedHigh": 5, "count": 0}))
    out.append(s.to_json())

    # 3. HELLO timeouts x3 -> INCOMPATIBLE -> RETRY 60 s
    c, _ = pair("hello timeout", G1, G1)
    s = SessionScript("central: HELLO timeout x3, INCOMPATIBLE, retry after 60 s", c, BASE_MS)
    s.do(0, {"in": "link_up", "mtu": 185})
    s.do(5000, {"in": "timer", "name": "HELLO"})
    s.do(10000, {"in": "timer", "name": "HELLO"})
    s.do(15000, {"in": "timer", "name": "HELLO"})
    s.do(20000, {"in": "timer", "name": "HELLO"})   # stale timer input: ignored
    s.do(75000, {"in": "timer", "name": "RETRY"})
    out.append(s.to_json())

    # 4. central gets a bad proof -> FOREIGN
    c, p = pair("bad proof", G1, G1)
    s = SessionScript("central: peripheral proof wrong -> ERR AUTH, FOREIGN", c, BASE_MS)
    hello = sends(s.do(0, {"in": "link_up", "mtu": 185}))[0]
    p.handle(0, {"in": "link_up", "mtu": 185})
    rep = sends(p.handle(15, {"in": "rx", "hex": hexu(hello)}))[0]
    _, f = R.decode_msg(rep)
    f["proof"] = bytes(16)
    s.rx(30, R.encode_msg(R.HELLO, f))
    s.rx(40, R.encode_msg(R.SUB, {"subs": 7}))   # dropped in FOREIGN
    out.append(s.to_json())

    # 5. peripheral gets a bad AUTH -> FOREIGN
    c, p = pair("bad auth", G1, G1)
    s = SessionScript("peripheral: AUTH proof wrong -> ERR AUTH, FOREIGN, disconnect", p, BASE_MS)
    s.do(0, {"in": "link_up", "mtu": 185})
    hello = sends(c.handle(0, {"in": "link_up", "mtu": 185}))[0]
    s.rx(15, hello)
    s.rx(30, R.encode_msg(R.AUTH, {"proof": bytes(16)}))
    out.append(s.to_json())

    # 6. group mismatch at the peripheral
    c, p = pair("mismatch", G2, G1)
    s = SessionScript("peripheral: other group -> HELLO, ERR AUTH, FOREIGN", p, BASE_MS)
    s.do(0, {"in": "link_up", "mtu": 185})
    hello = sends(c.handle(0, {"in": "link_up", "mtu": 185}))[0]
    s.rx(15, hello)
    out.append(s.to_json())
    c, p = pair("mismatch c", G2, G1)
    s = SessionScript("central: other group in reply -> ERR AUTH, FOREIGN", c, BASE_MS)
    hello = sends(s.do(0, {"in": "link_up", "mtu": 185}))[0]
    p.handle(0, {"in": "link_up", "mtu": 185})
    rep = sends(p.handle(15, {"in": "rx", "hex": hexu(hello)}))
    s.rx(30, rep[0])
    s.rx(30, rep[1])   # the peripheral's ERR AUTH: already FOREIGN, dropped
    out.append(s.to_json())

    # 7. central grouped, hub ungrouped -> JOIN + new HELLO -> AUTHED
    c, p = pair("join from central", G1, None)
    s = SessionScript("central: hub ungrouped -> JOIN, new HELLO, proof, AUTHED", c, BASE_MS)
    hello = sends(s.do(0, {"in": "link_up", "mtu": 185}))[0]
    p.handle(0, {"in": "link_up", "mtu": 185})
    rep = sends(p.handle(15, {"in": "rx", "hex": hexu(hello)}))
    acts = s.rx(30, rep[0])
    join, hello2 = sends(acts)[0], sends(acts)[1]
    p.handle(45, {"in": "rx", "hex": hexu(join)})
    rep2 = sends(p.handle(45, {"in": "rx", "hex": hexu(hello2)}))
    s.rx(60, rep2[0])
    out.append(s.to_json())
    # the same exchange from the hub's side, with fresh cores
    c, p = pair("join from central (hub side)", G1, None)
    s = SessionScript("peripheral hub: ungrouped -> receives JOIN, deadline armed, then proof", p, BASE_MS)
    s.do(0, {"in": "link_up", "mtu": 185})
    hello = sends(c.handle(0, {"in": "link_up", "mtu": 185}))[0]
    rep = sends(s.rx(15, hello))
    acts = c.handle(30, {"in": "rx", "hex": hexu(rep[0])})
    join, hello2 = sends(acts)[0], sends(acts)[1]
    s.rx(45, join)
    s.rx(45, hello2)
    s.rx(46, hello2)   # duplicate HELLO (same nonce): identical reply re-sent
    s.do(5045, {"in": "timer", "name": "AUTH"})
    out.append(s.to_json())

    # 8. hub grouped, Android ungrouped -> hub JOINs Android
    c, p = pair("hub joins android", None, G1, c_kind=R.KIND_ANDROID)
    s = SessionScript("central android: ungrouped, hub hands over the key (JOIN)", c, BASE_MS)
    hello = sends(s.do(0, {"in": "link_up", "mtu": 247}))[0]
    p.handle(0, {"in": "link_up", "mtu": 247})
    rep = sends(p.handle(15, {"in": "rx", "hex": hexu(hello)}))
    s.rx(30, rep[0])
    acts = s.rx(30, rep[1])
    hello2 = sends(acts)[0]
    rep2 = sends(p.handle(45, {"in": "rx", "hex": hexu(hello2)}))
    s.rx(60, rep2[0])
    out.append(s.to_json())

    # 9. both ungrouped -> NOGROUP; later the central gets a group
    c, p = pair("nogroup", None, None, c_kind=R.KIND_ANDROID)
    s = SessionScript("central: both ungrouped -> NOGROUP; group_changed -> JOIN + HELLO", c, BASE_MS)
    hello = sends(s.do(0, {"in": "link_up", "mtu": 247}))[0]
    p.handle(0, {"in": "link_up", "mtu": 247})
    rep = sends(p.handle(15, {"in": "rx", "hex": hexu(hello)}))
    s.rx(30, rep[0])
    s.rx(40, R.encode_msg(R.PULL, {"reqId": 1, "since": 0, "dbId": dbA}))   # data dropped in NOGROUP
    s.do(9000, {"in": "group_changed"}, mutate=lambda x: setattr(x, "group", G1))
    out.append(s.to_json())

    # 10. proto mismatch
    c, p = pair("proto", G1, G1)
    s = SessionScript("peripheral: HELLO proto 2 -> ERR PROTO, INCOMPATIBLE", p, BASE_MS)
    s.do(0, {"in": "link_up", "mtu": 185})
    h2 = bytes([R.HELLO]) + R.tlv(1, b"\x02") + R.tlv(0x40, b"v2 fields")
    s.rx(15, h2)
    s.rx(20, R.encode_msg(R.PULL, {"reqId": 1, "since": 0, "dbId": dbH}))
    out.append(s.to_json())
    c, _ = pair("proto c", G1, G1)
    s = SessionScript("central: ERR PROTO -> INCOMPATIBLE (no retry)", c, BASE_MS)
    s.do(0, {"in": "link_up", "mtu": 185})
    s.rx(15, R.encode_msg(R.ERR, {"code": R.E_PROTO, "refType": R.HELLO}))
    out.append(s.to_json())

    # 11. pull loop: more=1, count mismatch, page timeouts
    peersI = {hexu(ID_H): R.PeerState(dbH, 10, True)}
    c, p = pair("pull loop", G1, G1, c_peers=peersI, mtu=23)
    s = SessionScript("central: pull loop at MTU 23 (stored wm 10), more=1, count mismatch, timeouts", c,
                      BASE_MS)
    hello = sends(s.do(0, {"in": "link_up", "mtu": 23}))[0]
    p.handle(0, {"in": "link_up", "mtu": 23})
    rep = sends(p.handle(15, {"in": "rx", "hex": hexu(hello)}))
    s.rx(30, rep[0])
    rb = R.encode_body(body(0, P_SHOW, 1))
    s.rx(50, R.encode_msg(R.REC, {"seq": 11, "reqId": 1, "body": rb}))
    s.rx(55, R.encode_msg(R.PAGE_END, {"reqId": 1, "scannedTo": 14, "more": 1, "feedHigh": 30, "count": 1}))
    s.rx(70, R.encode_msg(R.REC, {"seq": 15, "reqId": 2, "body": rb}))
    s.rx(75, R.encode_msg(R.PAGE_END, {"reqId": 2, "scannedTo": 22, "more": 1, "feedHigh": 30, "count": 2}))
    s.rx(80, R.encode_msg(R.PAGE_END, {"reqId": 1, "scannedTo": 99, "more": 0, "feedHigh": 99, "count": 0}))
    s.do(10075, {"in": "timer", "name": "PAGE"})
    s.do(20075, {"in": "timer", "name": "PAGE"})
    out.append(s.to_json())

    # 12. DB_CHANGED, TOO_BIG, BUSY during a pull
    peersI = {hexu(ID_H): R.PeerState(dbH, 50, True)}
    c, p = pair("db changed", G1, G1, c_peers=peersI)
    s = SessionScript("central: ERR DB_CHANGED -> wm 0, new dbId, re-PULL; TOO_BIG; BUSY backoff", c, BASE_MS)
    hello = sends(s.do(0, {"in": "link_up", "mtu": 185}))[0]
    p.handle(0, {"in": "link_up", "mtu": 185})
    rep = sends(p.handle(15, {"in": "rx", "hex": hexu(hello)}))
    s.rx(30, rep[0])
    s.rx(45, R.encode_msg(R.ERR, {"code": R.E_DB_CHANGED, "refType": R.PULL, "dbId": det("db-H2", 8)}))
    s.rx(60, R.encode_msg(R.ERR, {"code": R.E_TOO_BIG, "refType": R.REC}))
    s.rx(75, R.encode_msg(R.ERR, {"code": R.E_BUSY, "refType": R.PULL, "retryMs": 1000}))
    s.do(1075, {"in": "timer", "name": "BACKOFF"})
    s.rx(1100, R.encode_msg(R.ERR, {"code": R.E_FULL, "refType": R.REC, "key": {"ns": 0, "packet": P_SHOW}}))
    out.append(s.to_json())

    # 13. NOT_READY on HELLO
    c, p = pair("not ready", G1, G1, p_ready=False)
    s = SessionScript("central: hub index not ready -> backoff 500 ms, HELLO again", c, BASE_MS)
    hello = sends(s.do(0, {"in": "link_up", "mtu": 185}))[0]
    p.handle(0, {"in": "link_up", "mtu": 185})
    rep = sends(p.handle(15, {"in": "rx", "hex": hexu(hello)}))
    s.rx(30, rep[0])
    s.do(530, {"in": "timer", "name": "BACKOFF"})
    out.append(s.to_json())

    # 14. live REC -> LIVE_PULL; direct HB trigger; pending while pulling; SUB
    peersI = {hexu(ID_H): R.PeerState(dbH, 7, True)}
    c, p = pair("live", G1, G1, c_peers=peersI)
    s = SessionScript("central: live REC arms LIVE_PULL; direct HB feedHigh > wm pulls; forwarded HB does not",
                      c, BASE_MS)
    hello = sends(s.do(0, {"in": "link_up", "mtu": 185}))[0]
    p.handle(0, {"in": "link_up", "mtu": 185})
    rep = sends(p.handle(15, {"in": "rx", "hex": hexu(hello)}))
    s.rx(30, rep[0])
    s.rx(50, R.encode_msg(R.PAGE_END, {"reqId": 1, "scannedTo": 7, "more": 0, "feedHigh": 7, "count": 0}))
    rb = R.encode_body(body(0, P_SHOW, T0, ID_A, R.FLAG_USER_EDITED, label="Live", category=1, place=3))
    s.rx(1000, R.encode_msg(R.REC, {"seq": 8, "reqId": 0, "seenBy": [ID_A, ID_H, ID_I], "body": rb}))
    s.rx(1500, R.encode_msg(R.REC, {"seq": 9, "reqId": 0, "seenBy": [ID_A, ID_H, ID_I], "body": rb}))
    s.do(3500, {"in": "timer", "name": "LIVE_PULL"})
    hbh = hb_fields(feedHigh=12, dbId=dbH, hbSeq=2, link=[])
    s.rx(3600, R.encode_msg(R.HB, hbh))                                  # pull outstanding: pending
    s.rx(3700, R.encode_msg(R.PAGE_END, {"reqId": 2, "scannedTo": 9, "more": 0, "feedHigh": 9, "count": 0}))
    s.rx(3800, R.encode_msg(R.PAGE_END, {"reqId": 3, "scannedTo": 12, "more": 0, "feedHigh": 12, "count": 0}))
    s.rx(4000, R.encode_msg(R.HB, hb_fields(deviceId=ID_A, kind=2, feedHigh=999, hops=1, link=[])))
    s.rx(4100, R.encode_msg(R.HB, hb_fields(feedHigh=12, dbId=dbH, hbSeq=3, link=[])))
    s.rx(4200, R.encode_msg(R.SUB, {"subs": 0x01}))
    s.rx(4300, R.encode_msg(R.HB, hb_fields(feedHigh=3, dbId=det("db-H2", 8), hbSeq=4, link=[])))
    out.append(s.to_json())

    # 15. hub deadline and data before AUTHED
    c, p = pair("deadline", G1, G1)
    s = SessionScript("peripheral hub: silent connection disconnected at 10 s; data before AUTH dropped", p,
                      BASE_MS)
    s.do(0, {"in": "link_up", "mtu": 185})
    s.rx(100, R.encode_msg(R.PULL, {"reqId": 1, "since": 0, "dbId": dbH}))
    s.rx(200, b"\x02\x01")   # malformed -> ERR BAD_MSG
    s.do(10000, {"in": "timer", "name": "DEADLINE"})
    out.append(s.to_json())

    # 16. rekey on an AUTHED session (both directions)
    c, p = pair("rekey", G1, G1)
    s = SessionScript("central iPhone: New sync group -> JOIN rekey, restart with the new group", c, BASE_MS)
    hello = sends(s.do(0, {"in": "link_up", "mtu": 185}))[0]
    p.handle(0, {"in": "link_up", "mtu": 185})
    rep = sends(p.handle(15, {"in": "rx", "hex": hexu(hello)}))
    s.rx(30, rep[0])
    s.do(5000, {"in": "rekey"}, mutate=lambda x: setattr(x, "group", G2))
    out.append(s.to_json())
    c, p = pair("rekey p", G1, G1)
    s = SessionScript("peripheral hub: JOIN rekey accepted only when AUTHED", p, BASE_MS)
    s.do(0, {"in": "link_up", "mtu": 185})
    hello = sends(c.handle(0, {"in": "link_up", "mtu": 185}))[0]
    s.rx(15, hello)
    rep = [a for a in s.steps[-1]["out"] if a["a"] == "send"]
    acts = c.handle(30, {"in": "rx", "hex": rep[0]["hex"]})
    s.rx(45, sends(acts)[0])
    s.rx(5000, R.encode_msg(R.JOIN, {"groupId": GID2, "groupKey": GROUP_KEY_2, "flags": 1}))
    s.rx(5050, R.encode_msg(R.JOIN, {"groupId": GID2, "groupKey": GROUP_KEY_2, "flags": 1}))  # same group: ignored
    s.rx(5100, R.encode_msg(R.JOIN, {"groupId": GID1, "groupKey": GROUP_KEY_1, "flags": 1}))  # not AUTHED now
    out.append(s.to_json())

    # 17. JOIN with a key that does not match its groupId
    c, p = pair("bad join", None, G1, c_kind=R.KIND_ANDROID)
    s = SessionScript("central: JOIN whose key does not hash to its groupId -> FOREIGN", c, BASE_MS)
    hello = sends(s.do(0, {"in": "link_up", "mtu": 247}))[0]
    p.handle(0, {"in": "link_up", "mtu": 247})
    rep = sends(p.handle(15, {"in": "rx", "hex": hexu(hello)}))
    s.rx(30, rep[0])
    s.rx(30, R.encode_msg(R.JOIN, {"groupId": GID1, "groupKey": GROUP_KEY_2}))
    out.append(s.to_json())
    return out


# ---------------------------------------------------------------------------------------------
# Node simulator for golden transcripts
# ---------------------------------------------------------------------------------------------

LAT_MS = 15
PHONE_SAVE_DEBOUNCE_MS = 300
HUB_FLUSH_MS = 2000


class NodeCtx(R.SessionCtx):
    def __init__(self, node):
        self.node = node
        self.nonce_log = []
        self.nonces = []

    group = property(lambda s: s.node.group, lambda s, v: s.node.set_group_raw(v))
    db_id = property(lambda s: s.node.db_id)
    feed_high = property(lambda s: s.node.durable_high)
    ready = property(lambda s: s.node.ready)
    peers = property(lambda s: s.node.peers)

    def clock(self, t):
        return self.node.clock(t)

    def next_nonce(self):
        n = self.node.gen_nonce()
        self.nonce_log.append(n)
        return n


class Link(object):
    def __init__(self, lid, central, peripheral, mtu, gen):
        self.id, self.c, self.p, self.mtu, self.gen = lid, central, peripheral, mtu, gen
        self.frag = {central.name: R.Fragmenter(), peripheral.name: R.Fragmenter()}
        self.reasm = {central.name: R.Reassembler(central.max_msg), peripheral.name: R.Reassembler(peripheral.max_msg)}
        self.up = True

    def other(self, node):
        return self.p if node is self.c else self.c


class Sim(object):
    def __init__(self, name, description):
        self.name, self.description = name, description
        self.t = 0
        self.q = []
        self.n = 0
        self.steps = []
        self.nodes = {}
        self.links = {}
        self.gens = {}
        self.timer_keys = set()
        self.nonce_logs = []

    def add(self, node):
        self.nodes[node.name] = node
        node.sim = self
        return node

    def at(self, t, fn, *args, **kw):
        heapq.heappush(self.q, (t, self.n, fn, args, kw))
        self.n += 1

    def run(self, until):
        while self.q and self.q[0][0] <= until:
            t, _, fn, args, kw = heapq.heappop(self.q)
            self.t = t
            fn(*args, **kw)
        self.t = until

    def log(self, **kw):
        step = {"i": len(self.steps), "t": self.t}
        step.update(kw)
        self.steps.append(step)

    def note(self, text):
        self.log(ev="note", text=text)

    # links
    def link_up(self, lid, central, peripheral, mtu):
        c, p = self.nodes[central], self.nodes[peripheral]
        gen = self.gens.get(lid, 0) + 1
        self.gens[lid] = gen
        link = Link(lid, c, p, mtu, gen)
        self.links[lid] = link
        self.log(ev="link_up", link=lid, gen=gen, central=central, peripheral=peripheral, mtu=mtu)
        p.attach(link, "peripheral", c)
        c.attach(link, "central", p)
        p.core_input(lid, {"in": "link_up", "mtu": mtu})
        c.core_input(lid, {"in": "link_up", "mtu": mtu})

    def link_down(self, lid, reason):
        link = self.links.get(lid)
        if link is None or not link.up:
            return
        link.up = False
        self.log(ev="link_down", link=lid, reason=reason)
        for node in (link.p, link.c):
            node.core_input(lid, {"in": "link_down"})
            node.detach(lid)

    def schedule_disconnect(self, lid, reason):
        link = self.links.get(lid)
        if link is None or not link.up:
            return
        gen = link.gen
        self.at(self.t + LAT_MS + 1, self._disc, lid, gen, reason)

    def _disc(self, lid, gen, reason):
        link = self.links.get(lid)
        if link is not None and link.gen == gen and link.up:
            self.link_down(lid, reason)

    def send(self, lid, frm, data, by):
        link = self.links.get(lid)
        if link is None or not link.up:
            return
        to = link.other(frm)
        frames = link.frag[frm.name].fragment(data, link.mtu)
        try:
            mt, f = R.decode_msg(data)
            fj, decode_error = R.msg_fields_to_json(mt, f), None
        except R.SyncError as e:
            mt, fj, decode_error = data[0], None, e.reason
        step = {"ev": "msg", "link": lid, "gen": link.gen, "from": frm.name, "to": to.name, "by": by,
                "type": R.MSG_NAMES.get(mt, mt), "hex": hexu(data), "fields": fj,
                "frames": [hexu(x) for x in frames]}
        if decode_error:
            step["decodeError"] = decode_error
        self.log(**step)
        self.at(self.t + LAT_MS, self._deliver, lid, link.gen, to.name, frames)

    def _deliver(self, lid, gen, to_name, frames):
        link = self.links.get(lid)
        if link is None or link.gen != gen or not link.up:
            return
        to = self.nodes[to_name]
        for fr in frames:
            for a in link.reasm[to_name].feed(fr):
                assert a[0] == "deliver", a
                to.rx(lid, a[1])

    # timers
    def sync_timers(self, node, lid):
        core = node.cores.get(lid)
        if core is None:
            return
        for name, due in core.timers.items():
            key = (node.name, lid, self.links[lid].gen, name, due)
            if key not in self.timer_keys:
                self.timer_keys.add(key)
                self.at(due, self._fire, node.name, lid, self.links[lid].gen, name, due)

    def _fire(self, node_name, lid, gen, name, due):
        node = self.nodes[node_name]
        core = node.cores.get(lid)
        link = self.links.get(lid)
        if core is None or link is None or link.gen != gen or core.timers.get(name) != due:
            return
        self.log(ev="timer", node=node_name, link=lid, name=name)
        node.core_input(lid, {"in": "timer", "name": name})

    def to_json(self, nodes_initial):
        return {"schema": SCHEMA, "name": self.name, "description": self.description,
                "latencyMs": LAT_MS, "clockBaseMs": BASE_MS, "nodes": nodes_initial,
                "nonces": [{"link": x["link"], "gen": x["gen"], "node": x["node"],
                            "nonces": [hexu(n) for n in x["nonces"]]} for x in self.nonce_logs],
                "steps": self.steps,
                "final": {"t": self.t, "nodes": {n: node.final_json() for n, node in self.nodes.items()
                                                 if not getattr(node, "scripted", False)}}}


class Node(object):
    def __init__(self, name, kind, device_id, boot_id, db_id, group=None, version=None, devname=None,
                 battery=(-1, -1, -1, -1), state_bits=0, hub_air_ago=None, ring_cap=2000, epoch=None,
                 clock_known=True):
        self.name, self.kind, self.id, self.boot_id, self.db_id = name, kind, device_id, boot_id, db_id
        self.group = group
        self.version, self.devname = version, devname
        self.max_msg = R.HUB_MAXMSG if kind == R.KIND_HUB else R.PHONE_MAXMSG
        self.caps = R.CAPS_BY_KIND[kind]
        self.ledger = R.Ledger()
        self.durable_high = 0
        self.peers = {}
        self.cores = {}
        self.link_of = {}
        self.ready = True
        self.nonce_n = 0
        self.hb_seq = 0
        self.last_hb_t = -10 ** 9
        self.hb_round_pending = False
        self.page_accepted = False
        self.save_pending = False
        self.battery = battery
        self.state_bits = state_bits
        self.hub_air_ago = hub_air_ago
        self.hbs = {}
        self.hub_hb = None
        self.clock_known = clock_known
        # events (android origin)
        self.epoch = epoch
        self.evt_seq = 0
        self.ring = []
        self.ring_cap = ring_cap
        self.replays_served = {}
        # events (iphone receiver)
        self.dedupe = R.EvtDedupe()
        self.since_sent = {}
        self.sim = None
        self.uptime0 = 1000

    # -- identity helpers -----------------------------------------------------------------------
    def gen_nonce(self):
        n = R.sha256(b"mm-sync-nonce:" + self.id + self.nonce_n.to_bytes(4, "little"))[:8]
        self.nonce_n += 1
        return n

    def clock(self, t):
        return BASE_MS + t if self.clock_known else 0

    def now_or_none(self, t):
        return BASE_MS + t if self.clock_known else None

    def set_group_raw(self, g):
        self.group = g

    def initial_json(self):
        return {"deviceId": hexu(self.id), "kind": self.kind, "bootId": self.boot_id, "dbId": hexu(self.db_id),
                "maxMsg": self.max_msg, "caps": self.caps, "version": self.version, "name": self.devname,
                "groupId": hexu(self.group[0]) if self.group else None,
                "groupKey": hexu(self.group[1]) if self.group else None,
                "clockKnown": self.clock_known, "durableHigh": self.durable_high,
                "nextSyncSeq": self.ledger.next_sync_seq, "ledger": self.ledger.to_json(),
                "peers": {k: v.to_json() for k, v in sorted(self.peers.items())},
                "ringCap": self.ring_cap if self.kind == R.KIND_ANDROID else None,
                "epoch": self.epoch if self.kind == R.KIND_ANDROID else None}

    def final_json(self):
        j = {"dbId": hexu(self.db_id), "groupId": hexu(self.group[0]) if self.group else None,
             "durableHigh": self.durable_high, "nextSyncSeq": self.ledger.next_sync_seq,
             "ledger": self.ledger.to_json(),
             "peers": {k: v.to_json() for k, v in sorted(self.peers.items())}}
        if self.kind == R.KIND_IOS:
            j["evtWindows"] = self.dedupe.to_json()
        if self.kind == R.KIND_ANDROID:
            j["epoch"], j["evtSeq"] = self.epoch, self.evt_seq
            j["ring"] = [[e, q] for e, q, _ in self.ring]
        return j

    # -- session plumbing -------------------------------------------------------------------------
    def attach(self, link, role, peer_node):
        cfg = R.SessionConfig(role, self.id, self.kind, self.boot_id, self.max_msg, version=self.version,
                              name=self.devname, peer_kind=peer_node.kind if role == "central" else None,
                              tracks_events=(self.kind == R.KIND_IOS))
        ctx = NodeCtx(self)
        self.sim.nonce_logs.append({"link": link.id, "gen": link.gen, "node": self.name, "nonces": ctx.nonce_log})
        self.cores[link.id] = R.SessionCore(cfg, ctx)
        self.link_of[link.id] = link

    def detach(self, lid):
        self.cores.pop(lid, None)
        self.link_of.pop(lid, None)

    def authed_sessions(self):
        return [(lid, c) for lid, c in self.cores.items() if c.state in R.AUTHED_STATES]

    def core_input(self, lid, inp, raw=None):
        core = self.cores.get(lid)
        if core is None:
            return
        acts = core.handle(self.sim.t, inp)
        self._raw = raw
        deferred = []
        for a in acts:
            k = a["a"]
            if k == "send":
                self.sim.send(lid, self, unhex(a["hex"]), "session")
            elif k == "state":
                self.sim.log(ev="state", node=self.name, link=lid, state=a["to"])
                if a["to"] == R.S_AUTHED:
                    self.on_authed(lid, core)
            elif k == "deliver":
                self.on_deliver(lid, core, a["type"], a.get("msg"))
            elif k == "commit":
                self.on_commit(lid, core, a["wm"])
            elif k == "group":
                self.sim.log(ev="group", node=self.name, link=lid, groupId=a["groupId"], rekey=a["rekey"])
                deferred.append(a)
            elif k == "node":
                if a["what"] == "send_hb":
                    self.send_hb([lid])
                elif a["what"] == "evt_since":
                    self.send_evt_since_all(lid)
                elif a["what"] == "foreign":
                    self.sim.log(ev="foreign", node=self.name, link=lid)
            elif k == "disconnect":
                self.sim.log(ev="disconnect", node=self.name, link=lid, reason=a["reason"],
                             retryMs=a["retryMs"])
                self.sim.schedule_disconnect(lid, a["reason"])
        if lid in self.cores:
            self.sim.sync_timers(self, lid)
        for a in deferred:
            for other in list(self.cores):
                if other == lid:
                    continue
                oc = self.cores[other]
                if a["rekey"] and oc.state in R.AUTHED_STATES:
                    self.core_input(other, {"in": "rekey"})
                else:
                    self.core_input(other, {"in": "group_changed"})

    def rx(self, lid, data):
        self._rx_raw = data
        self.core_input(lid, {"in": "rx", "hex": hexu(data)})

    def peer_kind(self, core):
        return core.peer["kind"] if core.peer else None

    # -- node behaviour --------------------------------------------------------------------------
    def on_authed(self, lid, core):
        if self.kind == R.KIND_HUB and core.peer.get("clockMs", 0) > 0 and not self.clock_known:
            self.clock_known = True
            self.sim.log(ev="note", text="%s learns the time from %s's HELLO clockMs" %
                         (self.name, self.link_of[lid].other(self).name))

    def send_node(self, lid, mtype, fields):
        self.sim.send(lid, self, R.encode_msg(mtype, fields), "node")

    def send_node_raw(self, lid, data):
        self.sim.send(lid, self, data, "node")

    def on_deliver(self, lid, core, typ, m):
        peer = core.peer_id
        if typ == "PULL":
            ps = self.peers[hexu(peer)]
            excl = m.get("exclude", 0) == 1 and ps.exclude_ok
            recs, pe = R.serve_page(self.ledger.entries.values(), self.durable_high, m["since"],
                                    m.get("limit", R.PULL_LIMIT_DEFAULT), m.get("maxBytes", R.PULL_MAXBYTES_DEFAULT),
                                    excl, peer, m["reqId"])
            for r in recs:
                self.send_node_raw(lid, r)
            self.send_node(lid, R.PAGE_END, pe)
            if pe["more"] == 0:
                ps.exclude_ok = True
        elif typ == "REC":
            self.on_rec(lid, core, m)
        elif typ == "HB":
            self.on_hb(lid, core, m, self._rx_raw)
        elif typ == "EVT":
            self.on_evt(lid, core, m)
        elif typ == "EVT_SINCE":
            self.on_evt_since(lid, core, m, self._rx_raw)
        elif typ == "EVT_GAP":
            self.on_evt_gap(lid, core, m, self._rx_raw)

    def on_rec(self, lid, core, m):
        peer = core.peer_id
        if "bodyError" in m:
            st, key = R.ERR_NAMES[m["bodyError"].code], None
        else:
            st, e, ev = self.ledger.apply_remote(m["body"], peer, self.now_or_none(self.sim.t))
            key = {"ns": m["bodyFields"]["ns"], "packet": m["bodyFields"]["packet"]}
        kstr = R.key_string(key["ns"], key["packet"]) if key else None
        self.sim.log(ev="apply", node=self.name, link=lid, key=kstr, status=st, live=(m["reqId"] == 0))
        if st in ("BAD_MSG", "CLOCK"):
            f = {"code": R.ERR_CODES[st], "refType": R.REC}
            if key:
                f["key"] = key
            self.send_node(lid, R.ERR, f)
            return
        if st != R.ACCEPT:
            return
        self.mark_dirty()
        if m["reqId"] == 0:
            sess = [(c.peer_id, bool(c.peer_subs & R.SUB_RECORDS), True) for l2, c in self.authed_sessions()]
            targets, seen = R.route_live_rec(self.id, peer, e.origin, m.get("seenBy", []), sess)
            for tgt in targets:
                l2 = self.lid_for(tgt)
                self.send_node(l2, R.REC, {"seq": e.s, "reqId": 0, "seenBy": seen, "body": e.body})
        else:
            self.page_accepted = True

    def lid_for(self, peer_id):
        for lid, c in self.cores.items():
            if c.peer_id == peer_id and c.state in R.AUTHED_STATES:
                return lid
        return None

    def on_commit(self, lid, core, wm):
        if self.kind == R.KIND_HUB:
            self.mark_dirty_if_needed()
        else:
            self.save_now()

    def mark_dirty_if_needed(self):
        if self.ledger.next_sync_seq - 1 > self.durable_high:
            self.mark_dirty()

    def mark_dirty(self):
        if self.save_pending:
            return
        self.save_pending = True
        delay = HUB_FLUSH_MS if self.kind == R.KIND_HUB else PHONE_SAVE_DEBOUNCE_MS
        self.sim.at(self.sim.t + delay, self.save_now)

    def save_now(self):
        self.save_pending = False
        new_high = self.ledger.next_sync_seq - 1
        if new_high != self.durable_high:
            self.durable_high = new_high
            self.sim.log(ev="durable", node=self.name, durableHigh=new_high)
        if self.page_accepted:
            self.page_accepted = False
            self.request_hb()

    # heartbeats
    def request_hb(self):
        if self.hb_round_pending:
            return
        self.hb_round_pending = True
        due = max(self.sim.t, self.last_hb_t + R.T_HB_SPACING_MS)
        self.sim.at(due, self._hb_round)

    def _hb_round(self):
        self.hb_round_pending = False
        lids = [lid for lid, c in self.authed_sessions() if c.peer_subs & R.SUB_HEARTBEATS]
        if lids:
            self.send_hb(lids)

    def build_hb(self):
        self.hb_seq += 1
        links = []
        for lid, c in self.authed_sessions():
            fl = (R.HB_LINK_SYNCED if c.state == R.S_SYNCED else 0) | \
                 (R.HB_LINK_TX_READY if c.peer.get("caps", 0) & R.CAP_TRANSMITTER else 0)
            links.append({"peerId": c.peer_id, "peerKind": c.peer["kind"], "flags": fl})
        pct, mv, chg, rt = self.battery
        f = {"deviceId": self.id, "kind": self.kind, "bootId": self.boot_id, "hbSeq": self.hb_seq,
             "ts": self.clock(self.sim.t), "uptimeS": self.uptime0 + self.sim.t // 1000, "battPct": pct,
             "battMv": mv, "charging": chg, "runtimeMin": rt, "version": self.version, "name": self.devname,
             "link": links[:R.HB_LINKS_MAX], "state": self.state_bits, "hops": 0,
             "feedHigh": self.durable_high, "dbId": self.db_id, "records": len(self.ledger.entries)}
        if self.kind == R.KIND_ANDROID and self.hub_air_ago is not None:
            f["hubAirAgoS"] = self.hub_air_ago
        if self.kind == R.KIND_IOS:
            wms = []
            for o, ws in self.dedupe.by_origin.items():
                w = ws[-1]
                wms.append({"origin": o, "epoch": w.epoch, "seq": w.hc})
            if wms:
                f["evtWm"] = wms[:R.HB_EVTWM_MAX]
        return {k: v for k, v in f.items() if v is not None and v != []}

    def send_hb(self, lids):
        f = self.build_hb()
        self.last_hb_t = self.sim.t
        for lid in lids:
            self.send_node(lid, R.HB, f)

    def on_hb(self, lid, core, m, raw):
        described = m["deviceId"]
        prev = self.hbs.get(described)
        if R.hb_replaces(prev, m):
            self.hbs[described] = {"bootId": m["bootId"], "hbSeq": m["hbSeq"]}
        direct = m["hops"] == 0 and described == core.peer_id
        if direct:
            sess = [(c.peer_id, bool(c.peer_subs & R.SUB_HEARTBEATS), True) for l2, c in self.authed_sessions()]
            for tgt in R.route_hb(self.id, core.peer_id, described, 0, sess):
                self.send_node_raw(self.lid_for(tgt), R.hb_set_hops(raw, 1))
            if self.kind == R.KIND_ANDROID and m["kind"] == R.KIND_HUB:
                self.hub_hb = (self.sim.t, m.get("link", []))
            if self.kind == R.KIND_HUB and m["kind"] != R.KIND_HUB and m["ts"] > 0 and not self.clock_known:
                self.clock_known = True
        if self.kind == R.KIND_ANDROID and m["kind"] == R.KIND_IOS:
            for w in m.get("evtWm", []):
                if w["origin"] == self.id:
                    if w["epoch"] < self.epoch or (w["epoch"] == self.epoch and w["seq"] < self.evt_seq):
                        self.catch_up(described, w["epoch"], w["seq"], "hb")

    # events: Android origin
    def android_route(self):
        ios = hub = None
        for lid, c in self.authed_sessions():
            if c.peer["kind"] == R.KIND_IOS:
                ios = (c.peer_id, True, bool(c.peer_subs & R.SUB_EVENTS))
            elif c.peer["kind"] == R.KIND_HUB:
                hub = (c.peer_id, True)
        age = links = None
        if self.hub_hb is not None:
            age, links = self.sim.t - self.hub_hb[0], self.hub_hb[1]
        return R.android_event_route(self.id, ios, hub, age, links or [])

    def originate(self, packet, rssi=-60, count=1, fix=True):
        self.evt_seq += 1
        f = {"origin": self.id, "epoch": self.epoch, "seq": self.evt_seq, "ts": self.clock(self.sim.t),
             "packet": packet, "rssi": rssi, "count": count}
        if fix:
            f.update(lat=283852000 + self.evt_seq, lon=-815639000, acc=8)
        f["addr"] = bytes.fromhex("D0C1B2A39400") + bytes([self.evt_seq & 0xFF])[:0]
        self.ring.append((self.epoch, self.evt_seq, f))
        if len(self.ring) > self.ring_cap:
            self.ring.pop(0)
        route, tgt, seen = self.android_route()
        self.sim.log(ev="local", node=self.name, op="heard", epoch=self.epoch, seq=self.evt_seq,
                     packet=hexu(packet), route=route)
        if route != 3:
            g = dict(f)
            g["seenBy"] = seen
            self.send_node(self.lid_for(tgt), R.EVT, g)

    def restart_service(self, new_boot):
        self.boot_id = new_boot
        self.epoch = max(self.epoch_now(), self.epoch + 1)
        self.evt_seq = 0
        self.ring = []
        self.replays_served = {}
        self.sim.log(ev="local", node=self.name, op="service_restart", bootId=new_boot, epoch=self.epoch)

    def epoch_now(self):
        return (BASE_MS + self.sim.t) // 1000

    def catch_up(self, requester, epoch, after, why):
        key = (requester, epoch, after)
        last = self.replays_served.get(key)
        if last is not None and self.sim.t - last < R.EVT_REPLAY_DEDUPE_MS:
            self.sim.log(ev="note", text="%s skips a repeated catch-up request (%s, epoch %d, after %d)" %
                         (self.name, why, epoch, after))
            return
        self.replays_served[key] = self.sim.t
        plan = R.replay_plan([(e, q) for e, q, _ in self.ring], self.epoch, self.evt_seq, epoch, after)
        route, tgt, seen = self.android_route()
        if route == 3:
            return
        lid = self.lid_for(tgt)
        by_key = {(e, q): f for e, q, f in self.ring}
        for item in plan:
            if item[0] == "replay":
                g = dict(by_key[(item[1], item[2])])
                g["flags"] = g.get("flags", 0) | R.EVT_FLAG_REPLAY
                g["seenBy"] = seen
                self.send_node(lid, R.EVT, g)
            else:
                self.send_node(lid, R.EVT_GAP, {"origin": self.id, "epoch": item[1], "firstAvail": item[2],
                                                "lastAvail": item[3], "curEpoch": item[4], "requester": requester})

    def on_evt(self, lid, core, m):
        if self.kind == R.KIND_HUB:
            sess = [(c.peer_id, bool(c.peer_subs & R.SUB_EVENTS), True) for l2, c in self.authed_sessions()]
            targets, seen = R.route_evt_relay(self.id, core.peer_id, m["origin"], m.get("seenBy", []), sess)
            for tgt in targets:
                g = dict(m)
                g["seenBy"] = seen
                self.send_node(self.lid_for(tgt), R.EVT, g)
            return
        if self.kind == R.KIND_IOS:
            res, lost = self.dedupe.receive(m["origin"], m["epoch"], m["seq"])
            self.sim.log(ev="ingest", node=self.name, link=lid, origin=hexu(m["origin"]), epoch=m["epoch"],
                         seq=m["seq"], result=res, replay=bool(m.get("flags", 0) & R.EVT_FLAG_REPLAY), lost=lost)
            if res == R.ACCEPT and self.dedupe.has_holes(m["origin"], m["epoch"]):
                w = self.dedupe.window(m["origin"], m["epoch"])
                self.send_since(lid, m["origin"], m["epoch"], w.hc)

    def send_since(self, lid, origin, epoch, after):
        key = (origin, epoch)
        if self.since_sent.get(key) == after:
            return
        self.since_sent[key] = after
        self.send_node(lid, R.EVT_SINCE, {"origin": origin, "epoch": epoch, "afterSeq": after,
                                          "requester": self.id})

    def send_evt_since_all(self, lid):
        for o, ws in self.dedupe.by_origin.items():
            w = ws[-1]
            self.since_sent.pop((o, w.epoch), None)
            self.send_since(lid, o, w.epoch, w.hc)

    def on_evt_since(self, lid, core, m, raw):
        if self.kind == R.KIND_HUB:
            tl = self.lid_for(m["origin"])
            if tl is not None and tl != lid:
                self.send_node_raw(tl, raw)
            return
        if self.kind == R.KIND_ANDROID and m["origin"] == self.id:
            self.catch_up(m["requester"], m["epoch"], m["afterSeq"], "EVT_SINCE")

    def on_evt_gap(self, lid, core, m, raw):
        if self.kind == R.KIND_HUB:
            tl = self.lid_for(m["requester"])
            if tl is not None and tl != lid:
                self.send_node_raw(tl, raw)
            return
        if self.kind == R.KIND_IOS:
            lost, reqs = self.dedupe.on_gap(m["origin"], m["epoch"], m["firstAvail"], m["lastAvail"],
                                            m["curEpoch"])
            self.sim.log(ev="gap", node=self.name, link=lid, origin=hexu(m["origin"]), epoch=m["epoch"],
                         lost=lost, requests=[{"epoch": a, "afterSeq": b} for a, b in reqs])
            for e, s in reqs:
                self.send_since(lid, m["origin"], e, s)

    # local user actions
    def local_edit(self, cls, ns, packet, **kw):
        e, _ = self.ledger.local_edit(cls, ns, packet, self.clock(self.sim.t), self.id, **kw)
        self.sim.log(ev="local", node=self.name, op="edit", cls=cls, key=e.key_string, bodyHex=hexu(e.body),
                     seq=e.s)
        self.mark_dirty()
        self.push_local(e)
        return e

    def local_learn(self, packet):
        e = self.ledger.local_learn(packet)
        self.sim.log(ev="local", node=self.name, op="learn", key=R.key_string(0, packet), created=e is not None)
        if e is not None:
            self.mark_dirty()
            self.push_local(e)

    def push_local(self, e):
        sess = [(c.peer_id, bool(c.peer_subs & R.SUB_RECORDS), True) for l2, c in self.authed_sessions()]
        targets, seen = R.route_local_rec(self.id, sess)
        for tgt in targets:
            self.send_node(self.lid_for(tgt), R.REC, {"seq": e.s, "reqId": 0, "seenBy": seen, "body": e.body})

    def sync_reset(self, new_db):
        self.db_id = new_db
        self.ledger = R.Ledger()
        self.durable_high = 0
        self.peers.clear()
        self.sim.log(ev="local", node=self.name, op="sync_reset", dbId=hexu(new_db))
        # A dbId change closes every session, so each peer re-handshakes and sees the new dbId in
        # HELLO (resetting its wm and excludeOk for this node) before any PULL crosses.
        for lid in list(self.cores):
            self.sim.log(ev="disconnect", node=self.name, link=lid, reason="db_reset", retryMs=None)
            self.sim.schedule_disconnect(lid, "db_reset")


class ScriptedNode(object):
    """A raw peer that sends scripted messages and records nothing but the transcript."""
    scripted = True

    def __init__(self, name, kind, device_id):
        self.name, self.kind, self.id = name, kind, device_id
        self.max_msg = R.PHONE_MAXMSG
        self.cores = {}
        self.received = []
        self.sim = None

    def attach(self, link, role, peer_node):
        self.link = link

    def detach(self, lid):
        pass

    def core_input(self, lid, inp):
        pass

    def rx(self, lid, data):
        self.received.append(data)

    def send(self, lid, data):
        self.sim.send(lid, self, data, "script")

    def initial_json(self):
        return {"deviceId": hexu(self.id), "kind": self.kind, "scripted": True}


# ---------------------------------------------------------------------------------------------
# Scenario fixtures
# ---------------------------------------------------------------------------------------------

def node_I(**kw):
    return Node("I", R.KIND_IOS, ID_I, 0x1001, det("db-I", 8), group=(GID1, GROUP_KEY_1), version="1.4.0",
                devname="iPhone", battery=(81, -1, 0, 290), state_bits=0x0080, **kw)


def node_A(group=True, **kw):
    return Node("A", R.KIND_ANDROID, ID_A, 0x2002, det("db-A", 8), group=(GID1, GROUP_KEY_1) if group else None,
                version="1.4.0", devname="Pixel 8", battery=(54, 3912, 0, 180), state_bits=0x0001,
                hub_air_ago=12, epoch=(BASE_MS // 1000) - 3600, **kw)


def node_H(group=True, **kw):
    return Node("H", R.KIND_HUB, ID_H, 0x3003, det("db-H", 8), group=(GID1, GROUP_KEY_1) if group else None,
                version="2.0 heltec-v3", devname="MM_ESP", battery=(68, 3910, 0, 300), **kw)


def seed(node, edits):
    """Local history before the scenario starts (times before t=0), all durable."""
    for i, (cls, ns, packet, kw) in enumerate(edits):
        if cls == "learn":
            node.ledger.local_learn(packet)
        else:
            node.ledger.local_edit(cls, ns, packet, BASE_MS - 86_400_000 + i * 1000, node.id, **kw)
    node.durable_high = node.ledger.next_sync_seq - 1


def presync(src, dst):
    """dst already holds every record of src (as if pulled earlier); both have peer state."""
    for e in src.ledger.sorted_entries():
        st, _, _ = dst.ledger.apply_remote(e.body, src.id, None)
        assert st in (R.ACCEPT, R.DUPLICATE, R.STALE)
    dst.durable_high = dst.ledger.next_sync_seq - 1
    dst.peers[hexu(src.id)] = R.PeerState(src.db_id, src.durable_high, True)
    src.peers[hexu(dst.id)] = R.PeerState(dst.db_id, dst.durable_high, True)


I_SEED = [
    (R.CLASS_USER, 0, P_SHOW, dict(label="Main Street Glow", category=R.CAT_SHOW, kind="show",
                                   place=R.PLACE_LIBRARY)),
    ("learn", 0, P_ANIM, {}),
    (R.CLASS_NEWWAND, 1, P_WAND, dict(label="Lights out")),
]
A_SEED = [
    ("learn", 0, P_COLOR, {}),
    ("learn", 0, P_COLOR2, {}),
    (R.CLASS_USER, 0, P_SHOW2, dict(label="Kiss Goodnight", category=R.CAT_SHOW, kind="show",
                                    place=R.PLACE_LIBRARY)),
]


def finish(sim, nodes_initial, until):
    sim.run(until)
    return sim.to_json(nodes_initial)


def sc_first_contact():
    sim = Sim("first_contact_group_handover",
              "A grouped iPhone meets a fresh, ungrouped hub: HELLO exchange, the iPhone hands the group key "
              "over (JOIN), both restart at LINKED, the HMAC challenge passes, both pull, the hub flushes and "
              "advertises its new feedHigh in an on-change HB, the iPhone re-pulls and exclusion makes that "
              "page empty.")
    I, H = sim.add(node_I()), sim.add(node_H(group=False, clock_known=False))
    seed(I, I_SEED)
    init = {"I": I.initial_json(), "H": H.initial_json()}
    sim.at(0, sim.link_up, "I-H", "I", "H", 185)
    return finish(sim, init, 9000)


def sc_grouped_hub_two_phones():
    sim = Sim("grouped_hub_two_phones",
              "The hub is grouped and already holds the iPhone's records. The iPhone links and resumes from "
              "its stored watermark. An ungrouped Android links next: the hub hands it the key (JOIN from the "
              "peripheral), both pull. Then live pushes: an iPhone rename goes I->H {I,H} and H->A {I,H,A}; "
              "an Android rename goes A->H->I; an Android-heard packet takes route 2 (via the hub) to the "
              "iPhone. LIVE_PULL re-pulls follow 2 s after each live record.")
    I, H, A = sim.add(node_I()), sim.add(node_H()), sim.add(node_A(group=False))
    seed(I, I_SEED)
    seed(A, A_SEED)
    presync(I, H)
    init = {"I": I.initial_json(), "H": H.initial_json(), "A": A.initial_json()}
    sim.at(0, sim.link_up, "I-H", "I", "H", 185)
    sim.at(1000, sim.link_up, "A-H", "A", "H", 247)
    sim.at(9000, I.local_edit, R.CLASS_USER, 0, P_ANIM,
           label="Sparkle Trail", category=R.CAT_ANIMATION, kind="animation", place=R.PLACE_LIBRARY)
    sim.at(10000, A.local_edit, R.CLASS_USER, 0, P_COLOR, label="Blue", category=R.CAT_COLOR, kind="color",
           place=R.PLACE_COLORS)
    sim.at(11000, A.originate, P_EV1, -58)
    sim.at(11400, A.originate, P_EV2, -71)
    return finish(sim, init, 16000)


def sc_reconnect():
    sim = Sim("reconnect_watermarks",
              "Android and the hub resume from stored watermarks; Android edits (a rename that supersedes an "
              "older entry, a new record, a learned presence) while the iPhone is away. The iPhone relinks at "
              "MTU 23 (18-byte chunks, PULL limit 8 / maxBytes 512) and pulls only what is new since its "
              "watermark; superseded entries are skipped. Then the hub's library is reset (sync_reset: new "
              "dbId). A dbId change closes every session; Android edits while unlinked; both phones "
              "relink, see the new dbId in HELLO, reset their watermark and exclusion state for the hub, "
              "and every record flows back into the hub, including the Android edit.")
    I, H, A = sim.add(node_I()), sim.add(node_H()), sim.add(node_A())
    seed(I, I_SEED)
    seed(A, A_SEED)
    presync(I, H)
    presync(A, H)
    presync(H, I)
    presync(H, A)
    init = {"I": I.initial_json(), "H": H.initial_json(), "A": A.initial_json()}
    sim.at(0, sim.link_up, "A-H", "A", "H", 247)
    sim.at(1500, A.local_edit, R.CLASS_USER, 0, P_SHOW, label="Main Street Glow (night)", category=R.CAT_SHOW,
           kind="show", place=R.PLACE_LIBRARY)
    sim.at(1600, A.local_edit, R.CLASS_USER, 0, P_RAW, label="Band noise?", category=R.CAT_UNKNOWN,
           place=R.PLACE_RAW)
    sim.at(1700, A.local_learn, P_PING[:-1] + b"\x07")
    sim.at(6000, sim.link_up, "I-H", "I", "H", 23)
    sim.at(14000, H.sync_reset, det("db-H-after-reset", 8))
    sim.at(14500, A.local_edit, R.CLASS_TOMBSTONE, 0, P_RAW)
    sim.at(15000, sim.link_up, "A-H", "A", "H", 247)
    sim.at(15500, sim.link_up, "I-H", "I", "H", 23)
    return finish(sim, init, 24000)


def sc_stranger():
    sim = Sim("stranger_rejected",
              "A grouped hub meets: (1) a stranger's iPhone in another group: HELLO, HELLO reply, ERR AUTH, "
              "FOREIGN on both, the hub disconnects; (2) an impostor that copies the groupId but has no key: "
              "it gets a valid proofP it cannot use, sends a wrong AUTH, gets ERR AUTH and is dropped; (3) an "
              "old app that connects but never says HELLO: dropped at the 10 s member deadline; (4) a "
              "future-protocol central (proto 2): ERR PROTO, INCOMPATIBLE, then dropped at the deadline.")
    H = sim.add(node_H())
    seed(H, [("learn", 0, P_SHOW, {})])
    S = sim.add(Node("S", R.KIND_IOS, ID_S, 0x5005, det("db-S", 8), group=(GID2, GROUP_KEY_2), version="1.4.0",
                     devname="iPhone"))
    X = sim.add(ScriptedNode("X", R.KIND_IOS, ID_X))
    Y = sim.add(ScriptedNode("Y", R.KIND_IOS, bytes.fromhex("01D0A99000000001")))
    Z = sim.add(ScriptedNode("Z", R.KIND_IOS, bytes.fromhex("2222222222222222")))
    init = {"H": H.initial_json(), "S": S.initial_json(), "X": X.initial_json(), "Y": Y.initial_json(),
            "Z": Z.initial_json()}
    sim.at(0, sim.link_up, "S-H", "S", "H", 185)
    sim.at(2000, sim.link_up, "X-H", "X", "H", 185)
    x_nonce = det("impostor-nonce", 8)
    x_hello = R.encode_msg(R.HELLO, {"proto": 1, "deviceId": ID_X, "kind": 3, "dbId": det("db-X", 8),
                                     "clockMs": BASE_MS + 2000, "feedHigh": 0, "subs": 7, "caps": 1,
                                     "maxMsg": 1024, "bootId": 7, "groupId": GID1, "nonce": x_nonce})
    sim.at(2000, X.send, "X-H", x_hello)
    sim.at(2040, X.send, "X-H", R.encode_msg(R.AUTH, {"proof": bytes(16)}))
    sim.at(4000, sim.link_up, "Y-H", "Y", "H", 185)
    sim.at(16000, sim.link_up, "Z-H", "Z", "H", 185)
    z_hello = bytes([R.HELLO]) + R.tlv(1, b"\x02") + R.tlv(2, Z.id) + R.tlv(0x60, b"proto 2 fields")
    sim.at(16000, Z.send, "Z-H", z_hello)
    return finish(sim, init, 30000)


def sc_live_forwarding():
    sim = Sim("live_push_forwarding_seenby",
              "All three nodes grouped and already in sync. Triangle: I-H, A-H and I-A (iPhone central to "
              "Android). An iPhone edit goes to both peers with seenBy {I,H,A} and nobody forwards; an "
              "Android edit likewise. Heartbeats arrive twice (direct and forwarded once). Then the A-H link "
              "drops (partial topology I-H + I-A): an Android edit reaches the iPhone {A,I} and the iPhone "
              "forwards it to the hub {A,I,H}.")
    I, H, A = sim.add(node_I()), sim.add(node_H()), sim.add(node_A())
    seed(I, I_SEED)
    seed(A, A_SEED)
    presync(I, H)
    presync(A, H)
    presync(H, I)
    presync(H, A)
    presync(I, A)
    presync(A, I)
    init = {"I": I.initial_json(), "H": H.initial_json(), "A": A.initial_json()}
    sim.at(0, sim.link_up, "I-H", "I", "H", 185)
    sim.at(300, sim.link_up, "A-H", "A", "H", 247)
    sim.at(600, sim.link_up, "I-A", "I", "A", 185)
    sim.at(4000, I.local_edit, R.CLASS_USER, 0, P_SHOW2, label="Kiss Goodnight (castle)", category=R.CAT_SHOW,
           kind="show", place=R.PLACE_LIBRARY)
    sim.at(4500, A.local_edit, R.CLASS_TOMBSTONE, 0, P_COLOR2)
    sim.at(8000, sim.link_down, "A-H", "out of range")
    sim.at(9000, A.local_edit, R.CLASS_USER, 0, P_COLOR, label="Deep Blue", category=R.CAT_COLOR,
           kind="color", place=R.PLACE_COLORS)
    sim.at(9500, I.local_edit, R.CLASS_NEWWAND, 1, P_WAND, label="Off (end of night)")
    return finish(sim, init, 14000)


def sc_event_catchup():
    sim = Sim("event_catchup",
              "Android-heard packets reach the iPhone directly (route 1). With the link down they go to "
              "Android's ring only (ring capacity 5 in this scenario). On relink the iPhone's HB (evtWm) and "
              "EVT_SINCE ask for the missing range and Android replays it (flags.replay); the repeated request "
              "is skipped. After a longer outage the ring no longer covers the range: EVT_GAP, the iPhone "
              "advances its floor and asks again. After an Android service restart (new epoch, empty ring) "
              "the old epoch is gone: EVT_GAP with curEpoch, the iPhone asks for the new epoch from 1.")
    I, A = sim.add(node_I()), sim.add(node_A(ring_cap=5))
    seed(I, I_SEED[:1])
    seed(A, A_SEED[:1])
    presync(I, A)
    presync(A, I)
    init = {"I": I.initial_json(), "A": A.initial_json()}
    sim.at(0, sim.link_up, "I-A", "I", "A", 185)
    pk = [P_EV1, P_EV2, P_SHOW, P_SHOW2, P_ANIM]
    t = 2000
    for k in range(3):
        sim.at(t + 200 * k, A.originate, pk[k % 5], -60 - k)
    sim.at(3000, sim.link_down, "I-A", "out of range")
    for k in range(5):
        sim.at(3500 + 300 * k, A.originate, pk[(k + 3) % 5], -70)
    sim.at(6000, sim.link_up, "I-A", "I", "A", 185)
    sim.at(9000, sim.link_down, "I-A", "out of range")
    for k in range(8):
        sim.at(9200 + 200 * k, A.originate, pk[k % 5], -75)
    sim.at(12000, sim.link_up, "I-A", "I", "A", 185)
    sim.at(15000, sim.link_down, "I-A", "out of range")
    sim.at(15500, A.restart_service, 0x2003)
    sim.at(16000, A.originate, P_EV1, -66)
    sim.at(16500, A.originate, P_EV2, -67)
    sim.at(18000, sim.link_up, "I-A", "I", "A", 185)
    sim.at(20000, A.originate, P_ANIM, -50)
    return finish(sim, init, 22000)


SCENARIOS = [sc_first_contact, sc_grouped_hub_two_phones, sc_reconnect, sc_stranger, sc_live_forwarding,
             sc_event_catchup]


# ---------------------------------------------------------------------------------------------
# Assembly
# ---------------------------------------------------------------------------------------------

def constants():
    return {
        "proto": R.PROTO, "frameVersion": R.FRAME_VERSION, "frameHeaderLen": R.FRAME_HEADER_LEN,
        "attOverhead": R.ATT_OVERHEAD, "mtuMin": R.MTU_MIN, "smallMtuBelow": R.SMALL_MTU_BELOW,
        "maxMsgMin": R.MAXMSG_MIN, "hubMaxMsg": R.HUB_MAXMSG, "phoneMaxMsg": R.PHONE_MAXMSG,
        "packetMin": R.PACKET_MIN, "packetMax": R.PACKET_MAX, "labelMax": R.LABEL_MAX, "noteMax": R.NOTE_MAX,
        "kindMax": R.KIND_MAX, "bodyMax": R.BODY_MAX, "seenByMax": R.SEENBY_MAX, "hbLinksMax": R.HB_LINKS_MAX,
        "hbEvtWmMax": R.HB_EVTWM_MAX, "uPresence": R.U_PRESENCE, "uLegacyAndroid": R.U_LEGACY_ANDROID,
        "uLegacyIos": R.U_LEGACY_IOS, "uMinMs": R.U_MIN_MS, "futureBoundMs": R.FUTURE_BOUND_MS,
        "pullLimitDefault": R.PULL_LIMIT_DEFAULT, "pullMaxBytesDefault": R.PULL_MAXBYTES_DEFAULT,
        "pullLimitSmall": R.PULL_LIMIT_SMALL, "pullMaxBytesSmall": R.PULL_MAXBYTES_SMALL,
        "pullMaxBytesMin": R.PULL_MAXBYTES_MIN, "helloTimeoutMs": R.T_HELLO_MS, "helloTries": R.HELLO_TRIES,
        "incompatibleRetryMs": R.T_RETRY_INCOMPATIBLE_MS, "authTimeoutMs": R.T_AUTH_MS,
        "memberDeadlineMs": R.T_DEADLINE_MS, "pageTimeoutMs": R.T_PAGE_MS, "pageTries": R.PAGE_TRIES,
        "pageFailRetryMs": R.T_PAGE_FAIL_RETRY_MS, "livePullMs": R.T_LIVE_PULL_MS, "hbIntervalMs": R.T_HB_MS,
        "hbSpacingMs": R.T_HB_SPACING_MS, "pathFreshMs": R.T_PATH_FRESH_MS, "notReadyRetryMs": R.NOT_READY_RETRY_MS,
        "busyRetryMs": R.BUSY_RETRY_MS, "defaultRetryMs": R.DEFAULT_RETRY_MS, "evtWindowBits": R.EVT_WINDOW_BITS,
        "evtEpochsKept": R.EVT_EPOCHS_KEPT, "evtReplayDedupeMs": R.EVT_REPLAY_DEDUPE_MS,
        "tombstoneCapPhone": R.TOMBSTONE_CAP_PHONE, "fnv64Offset": "%016X" % R.FNV64_OFFSET,
        "fnv64Prime": "%016X" % R.FNV64_PRIME, "groupIdPrefix": hexu(R.GROUP_ID_PREFIX),
        "proofPPrefix": hexu(R.PROOF_P_PREFIX), "proofCPrefix": hexu(R.PROOF_C_PREFIX),
        "messageTypes": {v: k for k, v in R.MSG_NAMES.items()}, "errorCodes": {v: k for k, v in R.ERR_NAMES.items()},
        "fixtures": {"clockBaseMs": BASE_MS, "groupKey1": hexu(GROUP_KEY_1), "groupId1": hexu(GID1),
                     "groupKey2": hexu(GROUP_KEY_2), "groupId2": hexu(GID2), "idI": hexu(ID_I), "idA": hexu(ID_A),
                     "idH": hexu(ID_H), "idS": hexu(ID_S), "idX": hexu(ID_X)},
    }


def build_vectors():
    return {
        "schema": SCHEMA,
        "proto": R.PROTO,
        "generator": "tools/sync/gen_vectors.py",
        "spec": "docs/SYNC_PROTOCOL.md",
        "constants": constants(),
        "crc32": v_crc32(),
        "fnv1a64": v_fnv(),
        "sha256": v_sha256(),
        "hmacSha256": v_hmac(),
        "groupIds": v_group_ids(),
        "proofs": v_proofs(),
        "textNormalize": v_text(),
        "keys": v_keys(),
        "bodies": v_bodies(),
        "bodyRejects": v_body_rejects(),
        "clock": v_clock(),
        "comparator": v_comparator(),
        "localStamp": v_local_stamp(),
        "apply": v_apply(),
        "messages": v_messages(),
        "messageNonCanonical": v_message_noncanonical(),
        "messageRejects": v_message_rejects(),
        "messageBadBody": v_message_bad_body(),
        "messageIgnored": v_message_ignored(),
        "hbHops": v_hb_hops(),
        "frames": v_frames(),
        "reassembly": v_reassembly(),
        "pages": v_pages(),
        "routing": v_routing(),
        "eventDedupe": v_event_dedupe(),
        "replayPlan": v_replay_plan(),
        "sessions": v_sessions(),
    }


def dump(obj):
    check_js_safe(obj)
    return json.dumps(obj, indent=1, ensure_ascii=False, sort_keys=False) + "\n"


def outputs():
    files = {os.path.join(HERE, "vectors.json"): dump(build_vectors())}
    for sc in SCENARIOS:
        j = sc()
        files[os.path.join(HERE, "transcripts", j["name"] + ".json")] = dump(j)
    return files


def main(argv):
    check = "--check" in argv
    files = outputs()
    again = outputs()
    assert files == again, "generator is not deterministic"
    stale = []
    for path, text in files.items():
        if check:
            try:
                with open(path, encoding="utf-8") as fh:
                    if fh.read() != text:
                        stale.append(path)
            except FileNotFoundError:
                stale.append(path)
        else:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(text)
    if check:
        tdir = os.path.join(HERE, "transcripts")
        if os.path.isdir(tdir):
            for fn in os.listdir(tdir):
                if os.path.join(tdir, fn) not in files:
                    stale.append(os.path.join(tdir, fn) + " (not generated)")
        if stale:
            print("stale or missing:\n  " + "\n  ".join(os.path.relpath(p, HERE) for p in stale))
            return 1
        print("tools/sync vectors and transcripts are current (%d files)" % len(files))
        return 0
    for path in files:
        print("wrote", os.path.relpath(path, os.path.dirname(HERE)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
