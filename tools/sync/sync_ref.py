#!/usr/bin/env python3
"""MagicMaker SYNC protocol v1 -- executable reference (Python 3 stdlib only).

Normative text: docs/SYNC_PROTOCOL.md. Where this file and the document disagree, the
document wins and this file is a bug. gen_vectors.py imports this module to write the shared
test vectors (tools/sync/vectors.json) and golden transcripts (tools/sync/transcripts/).

Contents (same order as the document):
  primitives      CRC-32/ISO-HDLC, FNV-1a 64, SHA-256, HMAC-SHA256, groupId, proofs
  text            label / note / kind normalisation for local edits
  body            record key + record body TLV codec, canonical form, class rules, clock
  version         comparator, local stamp
  ledger          apply rules, local edits, tombstone cap, learn check
  feed            durable-only page serving (PULL -> REC* + PAGE_END)
  messages        message TLV codec for every message type
  frames          fragmentation and reassembly
  events          dedupe window, EVT_GAP handling, Android replay plan
  routing         live record / event / heartbeat forwarding
  session         the per-link session state machine (pure logic, no transport)

Everything here is deterministic: no clocks, no randomness. Callers inject time and nonces.
"""

import hashlib
import hmac as _hmac
import zlib

# ---------------------------------------------------------------------------------------------
# Constants (docs/SYNC_PROTOCOL.md section 17)
# ---------------------------------------------------------------------------------------------

PROTO = 1
FRAME_VERSION = 1
FRAME_HEADER_LEN = 2
ATT_OVERHEAD = 3
MTU_MIN = 23
MTU_MAX = 517
SMALL_MTU_BELOW = 64          # MTU < 64 -> small pull profile
MAXMSG_MIN = 512
HUB_MAXMSG = 512
PHONE_MAXMSG = 1024

PACKET_MIN = 3
PACKET_MAX = 29
LABEL_MAX = 64
NOTE_MAX = 160
KIND_MAX = 16
BODY_MAX = 360
SEENBY_MAX = 4
HB_LINKS_MAX = 4
HB_EVTWM_MAX = 4

NS_LIB = 0
NS_NEWWAND = 1

FLAG_DELETED = 0x01
FLAG_USER_EDITED = 0x02
FLAG_PRESET = 0x04
FLAG_MASK = 0x07

CAT_UNKNOWN, CAT_SHOW, CAT_ANIMATION, CAT_COLOR = 0, 1, 2, 3
PLACE_PRESETS, PLACE_COLORS, PLACE_LIBRARY, PLACE_RAW = 1, 2, 3, 4

U_PRESENCE = 1
U_LEGACY_ANDROID = 2
U_LEGACY_IOS = 3
U_MIN_MS = 1_500_000_000_000
FUTURE_BOUND_MS = 86_400_000

KIND_HUB, KIND_ANDROID, KIND_IOS = 1, 2, 3

SUB_RECORDS = 0x01
SUB_EVENTS = 0x02
SUB_HEARTBEATS = 0x04

CAP_FEED = 0x0001
CAP_EVENTS = 0x0002
CAP_TRANSMITTER = 0x0008
CAP_PROGRAMS = 0x0010
CAP_LOOPS_BY_HEX = 0x0020

CAPS_BY_KIND = {
    KIND_HUB: CAP_FEED | CAP_TRANSMITTER | CAP_PROGRAMS | CAP_LOOPS_BY_HEX,               # 0x0039
    KIND_ANDROID: CAP_FEED | CAP_EVENTS | CAP_TRANSMITTER | CAP_PROGRAMS | CAP_LOOPS_BY_HEX,  # 0x003B
    KIND_IOS: CAP_FEED,                                                                 # 0x0001
}

PULL_LIMIT_DEFAULT = 24
PULL_MAXBYTES_DEFAULT = 1536
PULL_LIMIT_SMALL = 8
PULL_MAXBYTES_SMALL = 512
PULL_MAXBYTES_MIN = 256

T_HELLO_MS = 5000
HELLO_TRIES = 3
T_RETRY_INCOMPATIBLE_MS = 60000
T_AUTH_MS = 5000
T_DEADLINE_MS = 10000
T_PAGE_MS = 10000
PAGE_TRIES = 3
T_PAGE_FAIL_RETRY_MS = 30000
T_LIVE_PULL_MS = 2000
T_HB_MS = 60000
T_HB_SPACING_MS = 5000
T_PATH_FRESH_MS = 90000
NOT_READY_RETRY_MS = 500
BUSY_RETRY_MS = 1000
DEFAULT_RETRY_MS = 1000

EVT_WINDOW_BITS = 64
EVT_EPOCHS_KEPT = 2
EVT_REPLAY_DEDUPE_MS = 5000

TOMBSTONE_CAP_PHONE = 5000

# Message types
HELLO, PULL, REC, PAGE_END, EVT, EVT_SINCE, EVT_GAP, HB, SUB, ERR, AUTH, JOIN = range(1, 13)
MSG_NAMES = {HELLO: "HELLO", PULL: "PULL", REC: "REC", PAGE_END: "PAGE_END", EVT: "EVT",
             EVT_SINCE: "EVT_SINCE", EVT_GAP: "EVT_GAP", HB: "HB", SUB: "SUB", ERR: "ERR",
             AUTH: "AUTH", JOIN: "JOIN"}
MSG_TYPES = {v: k for k, v in MSG_NAMES.items()}

# Error codes
E_BAD_FRAME, E_TOO_BIG, E_BAD_MSG, E_PROTO, E_DB_CHANGED, E_FULL, E_CLOCK, E_BUSY, \
    E_COLLISION, E_AUTH, E_NOT_READY = range(1, 12)
ERR_NAMES = {E_BAD_FRAME: "BAD_FRAME", E_TOO_BIG: "TOO_BIG", E_BAD_MSG: "BAD_MSG",
             E_PROTO: "PROTO", E_DB_CHANGED: "DB_CHANGED", E_FULL: "FULL", E_CLOCK: "CLOCK",
             E_BUSY: "BUSY", E_COLLISION: "COLLISION", E_AUTH: "AUTH",
             E_NOT_READY: "NOT_READY"}
ERR_CODES = {v: k for k, v in ERR_NAMES.items()}

ZERO8 = bytes(8)


class SyncError(Exception):
    """A decode / validation failure. code is an ERR code (BAD_MSG or CLOCK); reason is a
    short machine-readable tag used by the vectors (informative, not normative)."""

    def __init__(self, code, reason):
        super().__init__("%s:%s" % (ERR_NAMES.get(code, code), reason))
        self.code = code
        self.reason = reason


def hexu(b):
    return b.hex().upper() if b is not None else None


def unhex(s):
    return bytes.fromhex(s) if s is not None else None


# ---------------------------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------------------------

def crc32(data):
    """CRC-32/ISO-HDLC (zlib): poly 0x04C11DB7 reflected, init/xorout 0xFFFFFFFF."""
    return zlib.crc32(data) & 0xFFFFFFFF


FNV64_OFFSET = 0xCBF29CE484222325
FNV64_PRIME = 0x00000100000001B3


def fnv1a64(data):
    h = FNV64_OFFSET
    for byte in data:
        h ^= byte
        h = (h * FNV64_PRIME) & 0xFFFFFFFFFFFFFFFF
    return h


def sha256(data):
    return hashlib.sha256(data).digest()


def hmac_sha256(key, data):
    return _hmac.new(key, data, hashlib.sha256).digest()


GROUP_ID_PREFIX = b"MMGROUP1"
PROOF_P_PREFIX = b"MMSYNC1P"
PROOF_C_PREFIX = b"MMSYNC1C"


def group_id(group_key):
    assert len(group_key) == 16
    return sha256(GROUP_ID_PREFIX + group_key)[:8]


def auth_transcript(nonce_c, nonce_p, id_c, id_p):
    for x in (nonce_c, nonce_p, id_c, id_p):
        assert len(x) == 8
    return nonce_c + nonce_p + id_c + id_p


def proof_p(group_key, nonce_c, nonce_p, id_c, id_p):
    return hmac_sha256(group_key, PROOF_P_PREFIX + auth_transcript(nonce_c, nonce_p, id_c, id_p))[:16]


def proof_c(group_key, nonce_c, nonce_p, id_c, id_p):
    return hmac_sha256(group_key, PROOF_C_PREFIX + auth_transcript(nonce_c, nonce_p, id_c, id_p))[:16]


# ---------------------------------------------------------------------------------------------
# Text normalisation for local edits (labels, notes, kind)
# ---------------------------------------------------------------------------------------------

# Unicode White_Space property (Unicode 15): the exact trim set. Implementations must use this
# set, not their platform's notion of whitespace.
WHITE_SPACE = frozenset(
    [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680]
    + list(range(0x2000, 0x200B))
    + [0x2028, 0x2029, 0x202F, 0x205F, 0x3000])


def _trim_cps(cps):
    a, b = 0, len(cps)
    while a < b and cps[a] in WHITE_SPACE:
        a += 1
    while b > a and cps[b - 1] in WHITE_SPACE:
        b -= 1
    return cps[a:b]


def normalize_text(s, max_bytes):
    """trim -> truncate to max_bytes UTF-8 bytes at a code-point boundary -> trim again.
    Returns None when the result is empty (the field is then absent)."""
    cps = _trim_cps([ord(c) for c in s])
    out, n = [], 0
    for cp in cps:
        w = len(chr(cp).encode("utf-8"))
        if n + w > max_bytes:
            break
        out.append(cp)
        n += w
    out = _trim_cps(out)
    if not out:
        return None
    return "".join(chr(c) for c in out)


def normalize_kind(s):
    """typeInfo -> kind: code points outside 0x20..0x7E become '?', then normalize_text(16)."""
    mapped = "".join(c if 0x20 <= ord(c) <= 0x7E else "?" for c in s)
    return normalize_text(mapped, KIND_MAX)


# ---------------------------------------------------------------------------------------------
# Record key and body
# ---------------------------------------------------------------------------------------------

T_KEY, T_UPDATED, T_ORIGIN, T_FLAGS, T_LABEL, T_CATEGORY, T_NOTE, T_KIND, T_PLACE = range(0x10, 0x19)
BODY_TAGS = (T_KEY, T_UPDATED, T_ORIGIN, T_FLAGS, T_LABEL, T_CATEGORY, T_NOTE, T_KIND, T_PLACE)

CLASS_PRESENCE = "PRESENCE"
CLASS_USER = "USER"
CLASS_RESET = "RESET"
CLASS_TOMBSTONE = "TOMBSTONE"
CLASS_NEWWAND = "NEWWAND"


def check_packet(packet):
    if not (PACKET_MIN <= len(packet) <= PACKET_MAX):
        raise SyncError(E_BAD_MSG, "packet_length")
    if packet[0] != 0x83 or packet[1] != 0x01:
        raise SyncError(E_BAD_MSG, "packet_prefix")


def encode_key(ns, packet):
    return bytes([ns]) + packet


def decode_key(v):
    if not (1 + PACKET_MIN <= len(v) <= 1 + PACKET_MAX):
        raise SyncError(E_BAD_MSG, "length")
    ns = v[0]
    if ns not in (NS_LIB, NS_NEWWAND):
        raise SyncError(E_BAD_MSG, "range")
    packet = bytes(v[1:])
    check_packet(packet)
    return ns, packet


def key_string(ns, packet):
    """Phones' ledger map key: "<ns>:<HEX>" (decimal ns, uppercase hex)."""
    return "%d:%s" % (ns, hexu(packet))


def tlv(tag, value):
    assert 0 <= tag <= 255 and len(value) <= 255, (tag, len(value))
    return bytes([tag, len(value)]) + value


def parse_tlvs(data, start=0):
    """[(tag, value, rawbytes)] or BAD_MSG on overrun."""
    out, i = [], start
    while i < len(data):
        if i + 2 > len(data):
            raise SyncError(E_BAD_MSG, "truncated")
        tag, ln = data[i], data[i + 1]
        if i + 2 + ln > len(data):
            raise SyncError(E_BAD_MSG, "truncated")
        out.append((tag, bytes(data[i + 2:i + 2 + ln]), bytes(data[i:i + 2 + ln])))
        i += 2 + ln
    return out


def _le(n, width, signed=False):
    return int(n).to_bytes(width, "little", signed=signed)


def _from_le(b, signed=False):
    return int.from_bytes(b, "little", signed=signed)


def _utf8(v, reason="utf8"):
    try:
        return v.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        raise SyncError(E_BAD_MSG, reason)


def body_shape(f):
    """Class implied by ns + flags + origin + content (time not considered)."""
    flags = f.get("flags", 0)
    if f["ns"] == NS_NEWWAND:
        return CLASS_NEWWAND
    if flags & FLAG_DELETED:
        return CLASS_TOMBSTONE
    if flags & (FLAG_USER_EDITED | FLAG_PRESET):
        return CLASS_USER
    if f.get("origin") is None and not any(k in f for k in ("label", "category", "note", "kind", "place")):
        return CLASS_PRESENCE
    return CLASS_RESET


def validate_body_fields(f):
    """Class/field/time rules (section 4.4). Raises SyncError. Returns the class name."""
    u = f["updatedAt"]
    if u <= 0:
        raise SyncError(E_BAD_MSG, "time")
    flags = f.get("flags", 0)
    has = lambda k: k in f
    ns = f["ns"]
    shape = body_shape(f)

    def need(*ks):
        for k in ks:
            if not has(k):
                raise SyncError(E_BAD_MSG, "class")

    def forbid(*ks):
        for k in ks:
            if has(k):
                raise SyncError(E_BAD_MSG, "class")

    if ns == NS_NEWWAND:
        if flags & (FLAG_USER_EDITED | FLAG_PRESET):
            raise SyncError(E_BAD_MSG, "class")
        need("origin")
        forbid("category", "kind", "place")
        if flags & FLAG_DELETED:
            forbid("label", "note")
            allowed_small = ()
        else:
            need("label")
            allowed_small = (U_LEGACY_ANDROID, U_LEGACY_IOS)
    elif shape == CLASS_TOMBSTONE:
        if flags != FLAG_DELETED:
            raise SyncError(E_BAD_MSG, "class")
        need("origin")
        forbid("label", "category", "note", "kind", "place")
        allowed_small = ()
    elif shape == CLASS_USER:
        need("origin", "label", "category", "place")
        allowed_small = (U_LEGACY_ANDROID, U_LEGACY_IOS)
    elif shape == CLASS_PRESENCE:
        if u != U_PRESENCE:
            raise SyncError(E_BAD_MSG, "class")
        return CLASS_PRESENCE
    else:  # RESET
        need("origin")
        forbid("label", "category", "kind", "place")
        allowed_small = ()
    # time rules for every non-PRESENCE shape
    if u == U_PRESENCE:
        raise SyncError(E_BAD_MSG, "class")
    if u in (U_LEGACY_ANDROID, U_LEGACY_IOS):
        if u not in allowed_small:
            raise SyncError(E_BAD_MSG, "class")
    elif u < U_MIN_MS:
        raise SyncError(E_CLOCK, "clock_invalid")
    return shape


def decode_body(data):
    """Canonical body bytes -> fields dict. Raises SyncError(BAD_MSG|CLOCK)."""
    if len(data) > BODY_MAX:
        raise SyncError(E_BAD_MSG, "oversize")
    tl = parse_tlvs(data)
    f = {}
    prev = -1
    for tag, v, _raw in tl:
        if tag not in BODY_TAGS:
            raise SyncError(E_BAD_MSG, "unknown_tag")
        if tag == prev:
            raise SyncError(E_BAD_MSG, "duplicate")
        if tag < prev:
            raise SyncError(E_BAD_MSG, "order")
        prev = tag
        if tag == T_KEY:
            f["ns"], f["packet"] = decode_key(v)
        elif tag == T_UPDATED:
            if len(v) != 8:
                raise SyncError(E_BAD_MSG, "length")
            f["updatedAt"] = _from_le(v, signed=True)
        elif tag == T_ORIGIN:
            if len(v) != 8:
                raise SyncError(E_BAD_MSG, "length")
            if v == ZERO8:
                raise SyncError(E_BAD_MSG, "zero_origin")
            f["origin"] = v
        elif tag == T_FLAGS:
            if len(v) != 1:
                raise SyncError(E_BAD_MSG, "length")
            if v[0] == 0:
                raise SyncError(E_BAD_MSG, "zero_flags")
            if v[0] & ~FLAG_MASK:
                raise SyncError(E_BAD_MSG, "range")
            f["flags"] = v[0]
        elif tag == T_LABEL:
            if not (1 <= len(v) <= LABEL_MAX):
                raise SyncError(E_BAD_MSG, "length")
            f["label"] = _utf8(v)
        elif tag == T_CATEGORY:
            if len(v) != 1:
                raise SyncError(E_BAD_MSG, "length")
            if v[0] > CAT_COLOR:
                raise SyncError(E_BAD_MSG, "range")
            f["category"] = v[0]
        elif tag == T_NOTE:
            if not (1 <= len(v) <= NOTE_MAX):
                raise SyncError(E_BAD_MSG, "length")
            f["note"] = _utf8(v)
        elif tag == T_KIND:
            if not (1 <= len(v) <= KIND_MAX):
                raise SyncError(E_BAD_MSG, "length")
            if any(c < 0x20 or c > 0x7E for c in v):
                raise SyncError(E_BAD_MSG, "ascii")
            f["kind"] = v.decode("ascii")
        elif tag == T_PLACE:
            if len(v) != 1:
                raise SyncError(E_BAD_MSG, "length")
            if not (PLACE_PRESETS <= v[0] <= PLACE_RAW):
                raise SyncError(E_BAD_MSG, "range")
            f["place"] = v[0]
    if "ns" not in f or "updatedAt" not in f:
        raise SyncError(E_BAD_MSG, "missing")
    validate_body_fields(f)
    return f


def encode_body(f):
    """fields dict -> canonical bytes. Validates (raises SyncError) so it can never emit an
    invalid body."""
    out = bytearray()
    out += tlv(T_KEY, encode_key(f["ns"], f["packet"]))
    out += tlv(T_UPDATED, _le(f["updatedAt"], 8, signed=True))
    if f.get("origin") is not None:
        out += tlv(T_ORIGIN, f["origin"])
    if f.get("flags", 0):
        out += tlv(T_FLAGS, bytes([f["flags"]]))
    if f.get("label") is not None:
        out += tlv(T_LABEL, f["label"].encode("utf-8"))
    if f.get("category") is not None:
        out += tlv(T_CATEGORY, bytes([f["category"]]))
    if f.get("note") is not None:
        out += tlv(T_NOTE, f["note"].encode("utf-8"))
    if f.get("kind") is not None:
        out += tlv(T_KIND, f["kind"].encode("ascii"))
    if f.get("place") is not None:
        out += tlv(T_PLACE, bytes([f["place"]]))
    data = bytes(out)
    back = decode_body(data)  # validates every rule
    assert body_to_json(back) == body_to_json(_clean_body(f)), (back, f)
    return data


def _clean_body(f):
    g = {k: v for k, v in f.items() if v is not None}
    if g.get("flags", 0) == 0:
        g.pop("flags", None)
    return g


def body_class(f):
    return validate_body_fields(f)


def body_to_json(f):
    j = {"key": {"ns": f["ns"], "packet": hexu(f["packet"])}, "updatedAt": f["updatedAt"]}
    if f.get("origin") is not None:
        j["origin"] = hexu(f["origin"])
    if f.get("flags", 0):
        j["flags"] = f["flags"]
    for k in ("label", "category", "note", "kind", "place"):
        if f.get(k) is not None:
            j[k] = f[k]
    return j


def body_from_json(j):
    f = {"ns": j["key"]["ns"], "packet": unhex(j["key"]["packet"]), "updatedAt": j["updatedAt"]}
    if "origin" in j:
        f["origin"] = unhex(j["origin"])
    if "flags" in j:
        f["flags"] = j["flags"]
    for k in ("label", "category", "note", "kind", "place"):
        if k in j:
            f[k] = j[k]
    return f


def check_future(updated_at, now_ms):
    """Receiver clock rule. now_ms None = receiver does not know the time (hub before any
    member clock): no future check."""
    if now_ms is not None and updated_at > now_ms + FUTURE_BOUND_MS:
        raise SyncError(E_CLOCK, "clock_future")


# ---------------------------------------------------------------------------------------------
# Version and comparator
# ---------------------------------------------------------------------------------------------

def version_of(f, body_bytes):
    origin = f.get("origin") or ZERO8
    return (f["updatedAt"], int.from_bytes(origin, "big"), crc32(body_bytes))


def compare_versions(a, b):
    """-1, 0, +1 comparing (updatedAt signed, origin as u64 big-endian, crc u32)."""
    return (a > b) - (a < b)


def local_stamp(now_ms, ledger_updated_at, last_local_stamp):
    """updatedAt for a local edit: max(now, ledger.updatedAt + 1, lastLocalStamp + 1, 1.5e12)."""
    return max(now_ms, ledger_updated_at + 1, last_local_stamp + 1, U_MIN_MS)


# ---------------------------------------------------------------------------------------------
# Ledger (phones; the hub uses the same accept rule over its log)
# ---------------------------------------------------------------------------------------------

ACCEPT = "ACCEPT"
DUPLICATE = "DUPLICATE"
STALE = "STALE"


class LedgerEntry(object):
    __slots__ = ("ns", "packet", "body", "fields", "version", "cls", "s", "f")

    def __init__(self, fields, body, s, f):
        self.ns, self.packet = fields["ns"], fields["packet"]
        self.body = body
        self.fields = fields
        self.version = version_of(fields, body)
        self.cls = body_class(fields)
        self.s = s
        self.f = f

    @property
    def key_string(self):
        return key_string(self.ns, self.packet)

    @property
    def origin(self):
        return self.fields.get("origin")

    def to_json(self):
        return {"key": self.key_string, "u": self.version[0],
                "o": hexu(self.fields.get("origin")), "c": self.version[2],
                "class": self.cls, "b": hexu(self.body), "s": self.s, "f": hexu(self.f)}


class Ledger(object):
    def __init__(self, tombstone_cap=TOMBSTONE_CAP_PHONE, next_sync_seq=1):
        self.entries = {}
        self.next_sync_seq = next_sync_seq
        self.last_local_stamp = 0
        self.tombstone_cap = tombstone_cap

    def get(self, ns, packet):
        return self.entries.get(key_string(ns, packet))

    def _store(self, fields, body, sync_from):
        e = LedgerEntry(fields, body, self.next_sync_seq, sync_from)
        self.next_sync_seq += 1
        self.entries[e.key_string] = e
        evicted = []
        if e.cls == CLASS_TOMBSTONE or (e.ns == NS_NEWWAND and fields.get("flags", 0) & FLAG_DELETED):
            evicted = self._evict_tombstones()
        return e, evicted

    def _evict_tombstones(self):
        tombs = [e for e in self.entries.values() if e.fields.get("flags", 0) & FLAG_DELETED]
        evicted = []
        while len(tombs) > self.tombstone_cap:
            oldest = min(tombs, key=lambda e: (e.version, encode_key(e.ns, e.packet)))
            tombs.remove(oldest)
            del self.entries[oldest.key_string]
            evicted.append(oldest.key_string)
        return evicted

    def apply_remote(self, body, sender, now_ms):
        """Returns (status, entry_or_None, evicted_keys). status in ACCEPT / DUPLICATE / STALE /
        BAD_MSG / CLOCK."""
        try:
            f = decode_body(body)
            check_future(f["updatedAt"], now_ms)
        except SyncError as e:
            return ERR_NAMES[e.code], None, []
        cur = self.get(f["ns"], f["packet"])
        v = version_of(f, body)
        if cur is not None:
            c = compare_versions(v, cur.version)
            if c == 0:
                return DUPLICATE, cur, []
            if c < 0:
                return STALE, cur, []
        e, ev = self._store(f, body, sender)
        return ACCEPT, e, ev

    def local_learn(self, packet):
        """A learn path met a library packet. Creates a PRESENCE entry only when the key has no
        entry at all (a tombstone or any version blocks it). Returns the entry or None."""
        if self.get(NS_LIB, packet) is not None:
            return None
        f = {"ns": NS_LIB, "packet": packet, "updatedAt": U_PRESENCE}
        e, _ = self._store(f, encode_body(f), None)
        return e

    def local_edit(self, cls, ns, packet, now_ms, self_id, label=None, category=None, kind=None,
                   place=None, note=None, preset=False, user_edited=True):
        """A user edit. cls in USER / RESET / TOMBSTONE / NEWWAND. Text is normalised here.
        Returns (entry, evicted)."""
        cur = self.get(ns, packet)
        u = local_stamp(now_ms, cur.version[0] if cur else 0, self.last_local_stamp)
        self.last_local_stamp = u
        f = {"ns": ns, "packet": packet, "updatedAt": u, "origin": self_id}
        nlabel = normalize_text(label, LABEL_MAX) if label is not None else None
        nnote = normalize_text(note, NOTE_MAX) if note is not None else None
        nkind = normalize_kind(kind) if kind is not None else None
        if cls == CLASS_USER:
            assert ns == NS_LIB and nlabel is not None
            f["flags"] = (FLAG_USER_EDITED if user_edited else 0) | (FLAG_PRESET if preset else 0)
            assert f["flags"]
            f.update(label=nlabel, category=category, kind=nkind, place=place, note=nnote)
        elif cls == CLASS_RESET:
            assert ns == NS_LIB
            f["note"] = nnote
        elif cls == CLASS_TOMBSTONE:
            f["flags"] = FLAG_DELETED
        elif cls == CLASS_NEWWAND:
            assert ns == NS_NEWWAND
            if nlabel is None:
                f["flags"] = FLAG_DELETED
            else:
                f["label"] = nlabel
                f["note"] = nnote
        else:
            raise ValueError(cls)
        f = _clean_body(f)
        body = encode_body(f)
        return self._store(decode_body(body), body, None)

    def sorted_entries(self):
        return sorted(self.entries.values(), key=lambda e: e.s)

    def tombstone_count(self):
        return sum(1 for e in self.entries.values() if e.fields.get("flags", 0) & FLAG_DELETED)

    def to_json(self):
        return [e.to_json() for e in sorted(self.entries.values(), key=lambda e: e.key_string)]


# ---------------------------------------------------------------------------------------------
# Feed: serving a PULL (durable-only)
# ---------------------------------------------------------------------------------------------

def serve_page(entries, durable_high, since, limit, max_bytes, exclude_active, puller, req_id):
    """entries: iterable of objects with .s (seq), .body, .origin, .f (syncFrom); only the
    CURRENT entry of each key (superseded entries already skipped, as phones' TreeMap does; the
    hub skips log entries whose index offset is not theirs). Returns (rec_msgs, page_end_fields).
    """
    recs, used = [], 0
    scanned = since
    if since < durable_high:
        for e in sorted((x for x in entries if since < x.s <= durable_high), key=lambda x: x.s):
            if exclude_active and ((e.origin is not None and e.origin == puller) or
                                   (e.f is not None and e.f == puller)):
                scanned = e.s
                continue
            msg = encode_msg(REC, {"seq": e.s, "reqId": req_id, "body": e.body})
            if len(recs) >= limit:
                break
            if recs and used + len(msg) > max_bytes:
                break
            recs.append(msg)
            used += len(msg)
            scanned = e.s
    more = 1 if scanned < durable_high else 0
    pe = {"reqId": req_id, "scannedTo": scanned, "more": more, "feedHigh": durable_high,
          "count": len(recs)}
    return recs, pe


# ---------------------------------------------------------------------------------------------
# Messages
# ---------------------------------------------------------------------------------------------

class F(object):
    """Field spec: tag, name, type, mandatory, repeat max (0 = not repeatable), default, range."""

    def __init__(self, tag, name, typ, mand=False, rep=0, default=None, lo=None, hi=None, size=None):
        self.tag, self.name, self.typ, self.mand, self.rep = tag, name, typ, mand, rep
        self.default, self.lo, self.hi, self.size = default, lo, hi, size


INT_TYPES = {"u8": (1, False), "u16": (2, False), "u32": (4, False), "i8": (1, True),
             "i16": (2, True), "i32": (4, True), "i64": (8, True)}

SPECS = {
    HELLO: [
        F(0x01, "proto", "u8", True),
        F(0x02, "deviceId", "b", True, size=8),
        F(0x03, "kind", "u8", True, lo=1, hi=3),
        F(0x04, "dbId", "b", True, size=8),
        F(0x05, "clockMs", "i64", True, lo=0),
        F(0x06, "feedHigh", "u32", True),
        F(0x07, "subs", "u8", True),
        F(0x08, "caps", "u16", default=0),
        F(0x09, "maxMsg", "u16", True, lo=MAXMSG_MIN),
        F(0x0A, "bootId", "u16", True),
        F(0x0B, "version", "str", size=16),
        F(0x0C, "name", "str", size=20),
        F(0x0D, "groupId", "b", True, size=8),
        F(0x0E, "nonce", "b", True, size=8),
        F(0x0F, "proof", "b", size=16),
    ],
    PULL: [
        F(0x01, "reqId", "u8", True, lo=1, hi=255),
        F(0x02, "since", "u32", True),
        F(0x03, "limit", "u8", default=PULL_LIMIT_DEFAULT, lo=1, hi=32),
        F(0x04, "maxBytes", "u16", default=PULL_MAXBYTES_DEFAULT, lo=PULL_MAXBYTES_MIN, hi=1536),
        F(0x05, "dbId", "b", True, size=8),
        F(0x06, "exclude", "u8", default=0, lo=0, hi=1),
    ],
    REC: [
        F(0x01, "seq", "u32", True),
        F(0x02, "reqId", "u8", True),
        F(0x03, "seenBy", "b", rep=SEENBY_MAX, size=8),
    ],
    PAGE_END: [
        F(0x01, "reqId", "u8", True, lo=1, hi=255),
        F(0x02, "scannedTo", "u32", True),
        F(0x03, "more", "u8", True, lo=0, hi=1),
        F(0x04, "feedHigh", "u32", True),
        F(0x05, "count", "u8", True),
    ],
    EVT: [
        F(0x01, "origin", "b", True, size=8),
        F(0x02, "epoch", "u32", True, lo=1),
        F(0x03, "seq", "u32", True, lo=1),
        F(0x04, "ts", "i64", True, lo=0),
        F(0x05, "packet", "packet", True),
        F(0x06, "rssi", "i8"),
        F(0x07, "count", "u16", default=1, lo=1),
        F(0x08, "lat", "i32", lo=-900000000, hi=900000000),
        F(0x09, "lon", "i32", lo=-1800000000, hi=1800000000),
        F(0x0A, "acc", "u16"),
        F(0x0B, "addr", "b", size=6),
        F(0x0C, "flags", "u8", default=0),
        F(0x0D, "seenBy", "b", rep=SEENBY_MAX, size=8),
    ],
    EVT_SINCE: [
        F(0x01, "origin", "b", True, size=8),
        F(0x02, "epoch", "u32", True),
        F(0x03, "afterSeq", "u32", True),
        F(0x04, "requester", "b", True, size=8),
    ],
    EVT_GAP: [
        F(0x01, "origin", "b", True, size=8),
        F(0x02, "epoch", "u32", True),
        F(0x03, "firstAvail", "u32", True),
        F(0x04, "lastAvail", "u32", True),
        F(0x05, "curEpoch", "u32", True),
        F(0x06, "requester", "b", True, size=8),
    ],
    HB: [
        F(0x01, "deviceId", "b", True, size=8),
        F(0x02, "kind", "u8", True, lo=1, hi=3),
        F(0x03, "bootId", "u16", True),
        F(0x04, "hbSeq", "u32", True),
        F(0x05, "ts", "i64", True, lo=0),
        F(0x06, "uptimeS", "u32", True),
        F(0x07, "battPct", "i8", default=-1, lo=-1, hi=100),
        F(0x08, "battMv", "i16", default=-1, lo=-1),
        F(0x09, "charging", "i8", default=-1, lo=-1, hi=1),
        F(0x0A, "runtimeMin", "i16", default=-1, lo=-1, hi=5999),
        F(0x0B, "version", "str", size=16),
        F(0x0C, "name", "str", size=20),
        F(0x0D, "link", "link", rep=HB_LINKS_MAX),
        F(0x0E, "state", "u16", default=0),
        F(0x0F, "hops", "u8", True, lo=0, hi=1),
        F(0x10, "feedHigh", "u32", True),
        F(0x11, "dbId", "b", True, size=8),
        F(0x12, "records", "u32", True),
        F(0x13, "hubAirAgoS", "u16"),
        F(0x14, "evtWm", "evtwm", rep=HB_EVTWM_MAX),
    ],
    SUB: [
        F(0x01, "subs", "u8", True),
    ],
    ERR: [
        F(0x01, "code", "u8", True, lo=1),
        F(0x02, "refType", "u8"),
        F(0x03, "key", "key"),
        F(0x04, "detail", "str", size=40),
        F(0x05, "dbId", "b", size=8),
        F(0x06, "retryMs", "u16"),
    ],
    AUTH: [
        F(0x01, "proof", "b", True, size=16),
    ],
    JOIN: [
        F(0x01, "groupId", "b", True, size=8),
        F(0x02, "groupKey", "b", True, size=16),
        F(0x03, "flags", "u8", default=0),
    ],
}
SPEC_BY_TAG = {t: {f.tag: f for f in fs} for t, fs in SPECS.items()}

REC_BODY_TAG_LO = 0x10
REC_BODY_TAG_HI = 0x1F
JOIN_FLAG_REKEY = 0x01
EVT_FLAG_TAGGED = 0x01
EVT_FLAG_REPLAY = 0x02
HB_LINK_SYNCED = 0x01
HB_LINK_TX_READY = 0x02
HB_LINK_WIFI = 0x04


def _dec_value(spec, v):
    t = spec.typ
    if t in INT_TYPES:
        w, signed = INT_TYPES[t]
        if len(v) != w:
            raise SyncError(E_BAD_MSG, "length")
        n = _from_le(v, signed)
        if (spec.lo is not None and n < spec.lo) or (spec.hi is not None and n > spec.hi):
            raise SyncError(E_BAD_MSG, "range")
        return n
    if t == "b":
        if len(v) != spec.size:
            raise SyncError(E_BAD_MSG, "length")
        return v
    if t == "str":
        if not (1 <= len(v) <= spec.size):
            raise SyncError(E_BAD_MSG, "length")
        return _utf8(v)
    if t == "packet":
        if not (PACKET_MIN <= len(v) <= PACKET_MAX):
            raise SyncError(E_BAD_MSG, "length")
        check_packet(v)
        return v
    if t == "key":
        ns, packet = decode_key(v)
        return {"ns": ns, "packet": packet}
    if t == "link":
        if len(v) != 10:
            raise SyncError(E_BAD_MSG, "length")
        if not (1 <= v[8] <= 3):
            raise SyncError(E_BAD_MSG, "range")
        return {"peerId": v[:8], "peerKind": v[8], "flags": v[9]}
    if t == "evtwm":
        if len(v) != 16:
            raise SyncError(E_BAD_MSG, "length")
        return {"origin": v[:8], "epoch": _from_le(v[8:12]), "seq": _from_le(v[12:16])}
    raise AssertionError(t)


def _enc_value(spec, x):
    t = spec.typ
    if t in INT_TYPES:
        w, signed = INT_TYPES[t]
        return _le(x, w, signed)
    if t == "b":
        assert len(x) == spec.size, (spec.name, x)
        return x
    if t == "str":
        b = x.encode("utf-8")
        assert 1 <= len(b) <= spec.size
        return b
    if t == "packet":
        return x
    if t == "key":
        return encode_key(x["ns"], x["packet"])
    if t == "link":
        return x["peerId"] + bytes([x["peerKind"], x["flags"]])
    if t == "evtwm":
        return x["origin"] + _le(x["epoch"], 4) + _le(x["seq"], 4)
    raise AssertionError(t)


class Unknown(object):
    def __init__(self, mtype):
        self.mtype = mtype


def decode_msg(data):
    """bytes -> (type, fields). Unknown message type -> (type, None): the caller ignores it.
    REC: fields carry "body" (bytes) and, when the body is invalid, "bodyError" (SyncError);
    the envelope stays valid so the page count is not broken by one bad record."""
    if len(data) < 1:
        raise SyncError(E_BAD_MSG, "empty")
    mtype = data[0]
    if mtype not in SPECS:
        return mtype, None
    specs = SPEC_BY_TAG[mtype]
    fields = {}
    body = bytearray()
    prev = -1
    for tag, v, raw in parse_tlvs(data, 1):
        if mtype == REC and REC_BODY_TAG_LO <= tag <= REC_BODY_TAG_HI:
            body += raw
            continue
        spec = specs.get(tag)
        if tag < prev:
            raise SyncError(E_BAD_MSG, "order")
        if tag == prev and spec is not None and not spec.rep:
            raise SyncError(E_BAD_MSG, "duplicate")
        prev = tag
        if spec is None:
            continue  # unknown tag: skipped
        val = _dec_value(spec, v)
        if spec.rep:
            lst = fields.setdefault(spec.name, [])
            lst.append(val)
            if len(lst) > spec.rep:
                raise SyncError(E_BAD_MSG, "count")
        else:
            fields[spec.name] = val
    for spec in SPECS[mtype]:
        if spec.mand and spec.name not in fields:
            raise SyncError(E_BAD_MSG, "missing")
    if mtype == REC:
        if fields["reqId"] != 0 and "seenBy" in fields:
            raise SyncError(E_BAD_MSG, "seenby_on_page")
        fields["body"] = bytes(body)
        try:
            fields["bodyFields"] = decode_body(fields["body"])
        except SyncError as e:
            fields["bodyError"] = e
    if mtype == EVT:
        pos = [k in fields for k in ("lat", "lon", "acc")]
        if any(pos) and not all(pos):
            raise SyncError(E_BAD_MSG, "fix")
    if mtype == JOIN and fields["groupId"] == ZERO8:
        raise SyncError(E_BAD_MSG, "range")
    return mtype, fields


def encode_msg(mtype, fields):
    """Canonical encoding: tags ascending, repeatable tags consecutive in list order, an
    optional field omitted when absent or equal to its default. REC: "body" bytes verbatim
    after the envelope tags."""
    out = bytearray([mtype])
    for spec in SPECS[mtype]:
        x = fields.get(spec.name)
        if x is None:
            if spec.mand:
                raise ValueError("missing %s.%s" % (MSG_NAMES[mtype], spec.name))
            continue
        if spec.rep:
            assert len(x) <= spec.rep
            for item in x:
                out += tlv(spec.tag, _enc_value(spec, item))
            continue
        if not spec.mand and spec.default is not None and x == spec.default:
            continue
        out += tlv(spec.tag, _enc_value(spec, x))
    if mtype == REC:
        out += fields["body"]
    return bytes(out)


def msg_fields_to_json(mtype, fields):
    """Decoded fields -> JSON object (vector / transcript representation)."""
    j = {}
    for spec in SPECS[mtype]:
        if spec.name not in fields:
            continue
        x = fields[spec.name]
        if spec.rep:
            j[spec.name] = [_val_to_json(spec, i) for i in x]
        else:
            j[spec.name] = _val_to_json(spec, x)
    if mtype == REC:
        j["bodyHex"] = hexu(fields["body"])
        if "bodyFields" in fields:
            j["body"] = body_to_json(fields["bodyFields"])
        if "bodyError" in fields:
            j["bodyError"] = ERR_NAMES[fields["bodyError"].code]
    return j


def _val_to_json(spec, x):
    t = spec.typ
    if t in ("b", "packet"):
        return hexu(x)
    if t == "key":
        return {"ns": x["ns"], "packet": hexu(x["packet"])}
    if t == "link":
        return {"peerId": hexu(x["peerId"]), "peerKind": x["peerKind"], "flags": x["flags"]}
    if t == "evtwm":
        return {"origin": hexu(x["origin"]), "epoch": x["epoch"], "seq": x["seq"]}
    return x


def msg_fields_from_json(mtype, j):
    f = {}
    for spec in SPECS[mtype]:
        if spec.name not in j:
            continue
        x = j[spec.name]
        if spec.rep:
            f[spec.name] = [_val_from_json(spec, i) for i in x]
        else:
            f[spec.name] = _val_from_json(spec, x)
    if mtype == REC:
        f["body"] = unhex(j["bodyHex"])
    return f


def _val_from_json(spec, x):
    t = spec.typ
    if t in ("b", "packet"):
        return unhex(x)
    if t == "key":
        return {"ns": x["ns"], "packet": unhex(x["packet"])}
    if t == "link":
        return {"peerId": unhex(x["peerId"]), "peerKind": x["peerKind"], "flags": x["flags"]}
    if t == "evtwm":
        return {"origin": unhex(x["origin"]), "epoch": x["epoch"], "seq": x["seq"]}
    return x


def hb_set_hops(data, hops):
    """Forwarders change nothing but hops: patch the value byte of tag 0x0F in place (the TLV
    is mandatory and 1 byte wide), so unknown tags survive forwarding."""
    out = bytearray(data)
    parse_tlvs(data, 1)  # well-formed or BAD_MSG
    i = 1
    while i < len(out):
        tag, ln = out[i], out[i + 1]
        if tag == 0x0F:
            assert ln == 1
            out[i + 2] = hops
            return bytes(out)
        i += 2 + ln
    raise ValueError("HB without hops")


# ---------------------------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------------------------

FR_START = 0x20
FR_END = 0x10


def chunk_size(mtu):
    assert MTU_MIN <= mtu <= MTU_MAX
    return mtu - ATT_OVERHEAD - FRAME_HEADER_LEN


class Fragmenter(object):
    """One per link direction. counter: 4-bit message counter, 0 for the first message after
    link-up. seq: 8-bit frame sequence, 0 for the first frame after link-up."""

    def __init__(self, counter=0, seq=0):
        self.counter = counter & 0x0F
        self.seq = seq & 0xFF

    def fragment(self, msg, mtu):
        assert len(msg) >= 1
        n = chunk_size(mtu)
        parts = [msg[i:i + n] for i in range(0, len(msg), n)]
        frames = []
        for k, p in enumerate(parts):
            b0 = (FRAME_VERSION << 6) | self.counter
            if k == 0:
                b0 |= FR_START
            if k == len(parts) - 1:
                b0 |= FR_END
            frames.append(bytes([b0, self.seq]) + p)
            self.seq = (self.seq + 1) & 0xFF
        self.counter = (self.counter + 1) & 0x0F
        return frames


class Reassembler(object):
    """One per link direction. feed(frame) -> list of actions:
         ("deliver", msg_bytes)
         ("bad_frame", reason)        count BAD_FRAME (reasons: short, gap, counter, restart, orphan)
         ("err_too_big", ref_type)    send ERR TOO_BIG{refType}
         ("err_proto", version)       send ERR PROTO (at most once per link)
    """

    def __init__(self, max_msg):
        self.max_msg = max_msg
        self.expected = 0
        self.buf = None
        self.counter = None
        self.skip = False
        self.proto_sent = False

    def feed(self, frame):
        acts = []
        if len(frame) < FRAME_HEADER_LEN + 1:
            return [("bad_frame", "short")]
        ver = frame[0] >> 6
        if ver != FRAME_VERSION:
            if not self.proto_sent:
                self.proto_sent = True
                acts.append(("err_proto", ver))
            return acts
        start = bool(frame[0] & FR_START)
        end = bool(frame[0] & FR_END)
        ctr = frame[0] & 0x0F
        fseq = frame[1]
        chunk = frame[2:]
        if fseq != self.expected:
            acts.append(("bad_frame", "gap"))
            self.buf = None
            self.skip = True
        self.expected = (fseq + 1) & 0xFF
        if start:
            if self.buf is not None:
                acts.append(("bad_frame", "restart"))
            self.buf = bytearray(chunk)
            self.counter = ctr
            self.skip = False
        else:
            if self.buf is None:
                if not self.skip:
                    acts.append(("bad_frame", "orphan"))
                return acts
            if ctr != self.counter:
                acts.append(("bad_frame", "counter"))
                self.buf = None
                self.skip = True
                return acts
            self.buf += chunk
        if len(self.buf) > self.max_msg:
            acts.append(("err_too_big", self.buf[0]))
            self.buf = None
            self.skip = True
            return acts
        if end:
            acts.append(("deliver", bytes(self.buf)))
            self.buf = None
        return acts


# ---------------------------------------------------------------------------------------------
# Events: dedupe window, gap handling, replay plan
# ---------------------------------------------------------------------------------------------

def _popcount(x):
    return bin(x).count("1")


class EvtWindow(object):
    __slots__ = ("epoch", "hc", "bits")

    def __init__(self, epoch, hc=0, bits=0):
        self.epoch, self.hc, self.bits = epoch, hc, bits

    def normalize(self):
        while self.bits & 1:
            self.hc += 1
            self.bits >>= 1

    def advance_floor(self, floor):
        """Move hc up to floor; returns how many seqs in (hc, floor] were never received."""
        if floor <= self.hc:
            return 0
        shift = floor - self.hc
        if shift >= EVT_WINDOW_BITS:
            got = _popcount(self.bits)
            self.bits = 0
        else:
            got = _popcount(self.bits & ((1 << shift) - 1))
            self.bits >>= shift
        self.hc = floor
        self.normalize()
        return shift - got

    def to_json(self):
        return {"epoch": self.epoch, "hc": self.hc, "bits": "%016X" % self.bits}


class EvtDedupe(object):
    """Receiver state per origin: the last EVT_EPOCHS_KEPT epochs, each {hc, 64-bit bitmap};
    bit i = seq hc+1+i received."""

    def __init__(self):
        self.by_origin = {}

    def windows(self, origin):
        return self.by_origin.get(origin, [])

    def window(self, origin, epoch):
        for w in self.by_origin.get(origin, []):
            if w.epoch == epoch:
                return w
        return None

    def _open(self, origin, epoch, hc):
        ws = self.by_origin.setdefault(origin, [])
        w = EvtWindow(epoch, hc)
        ws.append(w)
        ws.sort(key=lambda x: x.epoch)
        while len(ws) > EVT_EPOCHS_KEPT:
            ws.pop(0)
        return w

    def receive(self, origin, epoch, seq):
        """-> (result, lost) with result ACCEPT or DUPLICATE."""
        ws = self.by_origin.get(origin)
        w = self.window(origin, epoch)
        if w is None:
            if not ws:
                w = self._open(origin, epoch, seq - 1)   # first contact: no history
            elif epoch > ws[-1].epoch:
                w = self._open(origin, epoch, 0)          # new epoch: from seq 1
            else:
                return DUPLICATE, 0                       # older than the kept epochs
        if seq <= w.hc:
            return DUPLICATE, 0
        lost = 0
        if seq > w.hc + EVT_WINDOW_BITS:
            lost = w.advance_floor(seq - EVT_WINDOW_BITS)
        idx = seq - w.hc - 1
        if (w.bits >> idx) & 1:
            return DUPLICATE, lost
        w.bits |= 1 << idx
        w.normalize()
        return ACCEPT, lost

    def has_holes(self, origin, epoch):
        w = self.window(origin, epoch)
        return w is not None and w.bits != 0

    def newest(self, origin):
        ws = self.by_origin.get(origin)
        return ws[-1] if ws else None

    def on_gap(self, origin, epoch, first_avail, last_avail, cur_epoch):
        """EVT_GAP handling. Returns (lost, [ (epoch, afterSeq) EVT_SINCE requests ])."""
        reqs, lost = [], 0
        w = self.window(origin, epoch)
        if first_avail > 0:
            if w is not None and first_avail > w.hc + 1:
                lost = w.advance_floor(first_avail - 1)
                reqs.append((epoch, w.hc))
        elif cur_epoch > epoch:
            wc = self.window(origin, cur_epoch)
            if wc is None:
                newest = self.newest(origin)
                if newest is None or cur_epoch > newest.epoch:
                    wc = self._open(origin, cur_epoch, 0)
            if wc is not None:
                reqs.append((cur_epoch, wc.hc))
        return lost, reqs

    def to_json(self):
        return {hexu(o): [w.to_json() for w in ws] for o, ws in sorted(self.by_origin.items())}


def replay_plan(ring, cur_epoch, cur_seq, epoch, after_seq):
    """Android's answer to a catch-up request (EVT_SINCE, or an iPhone HB evtWm entry).
    ring: [(epoch, seq)] oldest first. Returns a list of ("replay", epoch, seq) and
    ("gap", epoch, firstAvail, lastAvail, curEpoch) items, in send order."""

    def seqs(ep):
        return [q for (x, q) in ring if x == ep]

    def plan_cur(s):
        if s >= cur_seq:
            return []
        qs = seqs(cur_epoch)
        if (s + 1) in qs:
            return [("replay", cur_epoch, q) for q in qs if q > s]
        return [("gap", cur_epoch, min(qs) if qs else 0, max(qs) if qs else 0, cur_epoch)]

    if epoch > cur_epoch:
        return []
    if epoch == cur_epoch:
        return plan_cur(after_seq)
    qs = seqs(epoch)
    if qs and (after_seq + 1) in qs:
        return [("replay", epoch, q) for q in qs if q > after_seq] + plan_cur(0)
    if qs and after_seq >= max(qs):
        return plan_cur(0)
    return [("gap", epoch, min(qs) if qs else 0, max(qs) if qs else 0, cur_epoch)]


# ---------------------------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------------------------

def merge_seen(base, extra):
    out = []
    for x in list(base) + list(extra):
        if x not in out:
            out.append(x)
    return out[:SEENBY_MAX]


def route_local_rec(self_id, sessions):
    """sessions: [(peerId, records_subscribed, authed)] in session order."""
    targets = [p for p, sub, ok in sessions if ok and sub]
    return targets, merge_seen([], [self_id] + targets)


def route_live_rec(self_id, sender, origin, seen_by, sessions):
    """First accept of a live REC from sender. origin None/zero = PRESENCE (no origin)."""
    excl = set(seen_by) | {sender}
    if origin is not None and origin != ZERO8:
        excl.add(origin)
    targets = [p for p, sub, ok in sessions if ok and sub and p not in excl and p != self_id]
    if not targets:
        return [], list(seen_by)
    return targets, merge_seen(seen_by, [self_id] + targets)


def route_evt_relay(self_id, sender, origin, seen_by, sessions):
    """Hub relay of an EVT. sessions: [(peerId, events_subscribed, member)]."""
    excl = set(seen_by) | {sender, origin}
    targets = [p for p, sub, ok in sessions if ok and sub and p not in excl and p != self_id]
    if not targets:
        return [], list(seen_by)
    return targets, merge_seen(seen_by, [self_id] + targets)


def android_event_route(self_id, ios_session, hub_session, hub_hb_age_ms, hub_hb_links):
    """ios_session: (peerId, up, events_subscribed) or None; up = session AUTHED/SYNCING/SYNCED.
    hub_session: (peerId, up) or None. hub_hb_*: the hub's latest DIRECT HB (age, links).
    Returns (route 1|2|3, target peerId or None, seenBy list)."""
    if ios_session is not None and ios_session[1] and ios_session[2]:
        return 1, ios_session[0], [self_id, ios_session[0]]
    if hub_session is not None and hub_session[1] and hub_hb_age_ms is not None \
            and hub_hb_age_ms <= T_PATH_FRESH_MS:
        if any(l["peerKind"] == KIND_IOS and l["flags"] & HB_LINK_SYNCED for l in hub_hb_links):
            return 2, hub_session[0], [self_id, hub_session[0]]
    return 3, None, []


def route_hb(self_id, sender, described, hops, sessions):
    """sessions: [(peerId, hb_subscribed, member)]. Only hops=0 HBs are forwarded, once."""
    if hops != 0:
        return []
    return [p for p, sub, ok in sessions if ok and sub and p not in (sender, described, self_id)]


def hb_replaces(stored, incoming):
    """stored/incoming: dicts with bootId, hbSeq (stored None = nothing kept)."""
    if stored is None:
        return True
    if incoming["bootId"] != stored["bootId"]:
        return True
    return incoming["hbSeq"] > stored["hbSeq"]


def subs_for(self_kind, peer_kind):
    """The subs a node sends in HELLO to a peer of peer_kind (section 11.1)."""
    if self_kind == KIND_HUB:
        return SUB_RECORDS | SUB_EVENTS | SUB_HEARTBEATS
    if self_kind == KIND_IOS:
        return SUB_RECORDS | SUB_EVENTS | SUB_HEARTBEATS
    if self_kind == KIND_ANDROID:
        return SUB_RECORDS | SUB_HEARTBEATS
    raise ValueError(self_kind)


# ---------------------------------------------------------------------------------------------
# Session state machine (pure logic)
# ---------------------------------------------------------------------------------------------

S_IDLE, S_LINKED, S_HELLO_X, S_AUTHED, S_SYNCING, S_SYNCED, S_FOREIGN, S_NOGROUP, \
    S_INCOMPATIBLE, S_CLOSED = ("IDLE", "LINKED", "HELLO_X", "AUTHED", "SYNCING", "SYNCED",
                                "FOREIGN", "NOGROUP", "INCOMPATIBLE", "CLOSED")
AUTHED_STATES = (S_AUTHED, S_SYNCING, S_SYNCED)
DATA_TYPES = (PULL, REC, PAGE_END, EVT, EVT_SINCE, EVT_GAP, HB, SUB)


class PeerState(object):
    """Per peer deviceId: {dbId of the peer, wm on the peer's feed, excludeOk for the peer
    pulling from us}. Persisted by the node."""

    def __init__(self, db_id=ZERO8, wm=0, exclude_ok=False):
        self.db_id, self.wm, self.exclude_ok = db_id, wm, exclude_ok

    def to_json(self):
        return {"dbId": hexu(self.db_id), "wm": self.wm, "excludeOk": self.exclude_ok}

    @staticmethod
    def from_json(j):
        return PeerState(unhex(j["dbId"]), j["wm"], j["excludeOk"])


class SessionConfig(object):
    def __init__(self, role, device_id, kind, boot_id, max_msg, caps=None, version=None,
                 name=None, peer_kind=None, tracks_events=False, is_hub=None):
        assert role in ("central", "peripheral")
        self.role = role
        self.device_id = device_id
        self.kind = kind
        self.boot_id = boot_id
        self.max_msg = max_msg
        self.caps = CAPS_BY_KIND[kind] if caps is None else caps
        self.version = version
        self.name = name
        self.peer_kind = peer_kind
        self.tracks_events = tracks_events
        self.is_hub = (kind == KIND_HUB) if is_hub is None else is_hub


class SessionCtx(object):
    """Node-owned values the session reads. Mutated by the node between inputs."""

    def __init__(self, group=None, db_id=ZERO8, feed_high=0, clock=None, nonces=None,
                 ready=True, peers=None):
        self.group = group               # None or (groupId, groupKey)
        self.db_id = db_id
        self.feed_high = feed_high
        self.clock = clock or (lambda t: 0)   # t -> clockMs
        self.nonces = list(nonces or [])
        self.nonce_log = []
        self.ready = ready
        self.peers = peers if peers is not None else {}

    def next_nonce(self):
        n = self.nonces.pop(0)
        self.nonce_log.append(n)
        return n


class SessionCore(object):
    """One end of one link. handle(t, input) -> [action]. Inputs (dicts):
        {"in": "link_up", "mtu": n}      {"in": "link_down"}
        {"in": "rx", "hex": ...}          {"in": "timer", "name": ...}
        {"in": "group_changed"}           {"in": "rekey"}       {"in": "pull_now"}
    Actions (dicts, in emission order):
        {"a": "send", "type": NAME, "hex": HEX}
        {"a": "state", "to": STATE}
        {"a": "deliver", "type": NAME}        (+ "msg": decoded, not serialised)
        {"a": "commit", "wm": n}
        {"a": "group", "groupId": HEX, "groupKey": HEX, "rekey": bool}
        {"a": "node", "what": "send_hb" | "evt_since" | "foreign"}
        {"a": "disconnect", "reason": R, "retryMs": n|None}
    After every input the observable snapshot is state, timers {name: dueMs}, peer state.
    """

    def __init__(self, cfg, ctx):
        self.cfg, self.ctx = cfg, ctx
        self.state = S_IDLE
        self.timers = {}
        self.peer = None          # decoded peer HELLO fields
        self.peer_subs = 0
        self.alike = False
        self.nonce_c = None
        self.nonce_p = None
        self.hello_tries = 0
        self.last_reply = None
        self.req_id = 0
        self.pull = None          # {"reqId", "since", "recs", "tries"}
        self.pending_high = -1
        self.limit = PULL_LIMIT_DEFAULT
        self.max_bytes = PULL_MAXBYTES_DEFAULT
        self.backoff = None
        self.out = []

    # -- helpers ------------------------------------------------------------------------------
    @property
    def central(self):
        return self.cfg.role == "central"

    @property
    def peer_id(self):
        return self.peer["deviceId"] if self.peer else None

    def _emit(self, **a):
        self.out.append(a)

    def _send(self, mtype, fields):
        b = encode_msg(mtype, fields)
        self._emit(a="send", type=MSG_NAMES[mtype], hex=hexu(b))
        return b

    def _set_state(self, s):
        if s != self.state:
            self.state = s
            self._emit(a="state", to=s)

    def _arm(self, name, t, ms):
        self.timers[name] = t + ms

    def _cancel(self, *names):
        for n in names:
            self.timers.pop(n, None)

    def _cancel_all(self):
        self.timers = {}

    def _err(self, code, ref=None, **extra):
        f = {"code": code}
        if ref is not None:
            f["refType"] = ref
        f.update(extra)
        self._send(ERR, f)

    def _peer_state(self):
        pid = hexu(self.peer_id)
        ps = self.ctx.peers.get(pid)
        if ps is None:
            ps = self.ctx.peers[pid] = PeerState()
        return ps

    def _disconnect(self, reason, retry_ms=None):
        self._cancel_all()
        self._emit(a="disconnect", reason=reason, retryMs=retry_ms)

    def snapshot(self):
        snap = {"state": self.state, "timers": dict(sorted(self.timers.items()))}
        if self.peer is not None:
            ps = self.ctx.peers.get(hexu(self.peer_id))
            if ps is not None:
                snap["peer"] = ps.to_json()
        return snap

    # -- entry point --------------------------------------------------------------------------
    def handle(self, t, inp):
        self.out = []
        kind = inp["in"]
        if kind == "link_up":
            self._link_up(t, inp.get("mtu", 185))
        elif kind == "link_down":
            self._cancel_all()
            self._set_state(S_CLOSED)
        elif kind == "rx":
            self._rx(t, unhex(inp["hex"]))
        elif kind == "timer":
            name = inp["name"]
            if self.timers.get(name) == t:
                del self.timers[name]
                self._on_timer(t, name)
        elif kind == "group_changed":
            self._group_changed(t)
        elif kind == "rekey":
            self._rekey(t)
        elif kind == "pull_now":
            if self.state in AUTHED_STATES:
                self._trigger_pull(t, None)
        else:
            raise ValueError(kind)
        return self.out

    # -- link / handshake -------------------------------------------------------------------
    def _link_up(self, t, mtu):
        if mtu < SMALL_MTU_BELOW:
            self.limit, self.max_bytes = PULL_LIMIT_SMALL, PULL_MAXBYTES_SMALL
        else:
            self.limit, self.max_bytes = PULL_LIMIT_DEFAULT, PULL_MAXBYTES_DEFAULT
        self._set_state(S_LINKED)
        if self.central:
            self._start_hello(t)
        elif self.cfg.is_hub and self.ctx.group is not None:
            self._arm("DEADLINE", t, T_DEADLINE_MS)

    def _hello_fields(self, t, nonce, proof=None):
        peer_kind = self.cfg.peer_kind if self.central else self.peer["kind"]
        f = {"proto": PROTO, "deviceId": self.cfg.device_id, "kind": self.cfg.kind,
             "dbId": self.ctx.db_id, "clockMs": self.ctx.clock(t), "feedHigh": self.ctx.feed_high,
             "subs": subs_for(self.cfg.kind, peer_kind), "caps": self.cfg.caps,
             "maxMsg": self.cfg.max_msg, "bootId": self.cfg.boot_id,
             "groupId": self.ctx.group[0] if self.ctx.group else ZERO8, "nonce": nonce}
        if self.cfg.version:
            f["version"] = self.cfg.version
        if self.cfg.name:
            f["name"] = self.cfg.name
        if proof is not None:
            f["proof"] = proof
        return f

    def _start_hello(self, t):
        self._set_state(S_LINKED)
        self.nonce_c = self.ctx.next_nonce()
        self.hello_tries = 1
        self._send(HELLO, self._hello_fields(t, self.nonce_c))
        self._arm("HELLO", t, T_HELLO_MS)

    def _resend_hello(self, t):
        self._send(HELLO, self._hello_fields(t, self.nonce_c))
        self._arm("HELLO", t, T_HELLO_MS)

    def _ids(self):
        """(idC, idP) for the proof transcript."""
        if self.central:
            return self.cfg.device_id, self.peer_id
        return self.peer_id, self.cfg.device_id

    def _proofs(self):
        key = self.ctx.group[1]
        id_c, id_p = self._ids()
        return (proof_p(key, self.nonce_c, self.nonce_p, id_c, id_p),
                proof_c(key, self.nonce_c, self.nonce_p, id_c, id_p))

    def _groups(self, m):
        mine = self.ctx.group[0] if self.ctx.group else None
        theirs = m["groupId"] if m["groupId"] != ZERO8 else None
        return mine, theirs

    def _c_hello(self, t, m):
        if self.state != S_LINKED or self.nonce_c is None or "HELLO" not in self.timers:
            return  # late duplicate, or not waiting
        self._cancel("HELLO", "BACKOFF")
        self.peer = m
        self.peer_subs = m["subs"]
        self.nonce_p = m["nonce"]
        mine, theirs = self._groups(m)
        if mine is not None and theirs is not None:
            if mine != theirs:
                return self._foreign(t, HELLO)
            pp, pc = self._proofs()
            if m.get("proof") is None or not _hmac.compare_digest(m["proof"], pp):
                return self._foreign(t, HELLO)
            self.alike = True
            self._set_state(S_HELLO_X)
            self._send(AUTH, {"proof": pc})
            self._authed(t)
        elif mine is not None:
            self._send(JOIN, {"groupId": self.ctx.group[0], "groupKey": self.ctx.group[1]})
            self._start_hello(t)
        elif theirs is not None:
            self._set_state(S_HELLO_X)
            self._arm("AUTH", t, T_AUTH_MS)
        else:
            self._set_state(S_NOGROUP)

    def _p_hello(self, t, m):
        if self.nonce_c is not None and m["nonce"] == self.nonce_c and self.last_reply is not None:
            if self.state in (S_LINKED, S_HELLO_X, S_NOGROUP):
                for mtype, hx in self.last_reply:
                    self._emit(a="send", type=MSG_NAMES[mtype], hex=hx)
            return
        if not self.ctx.ready:
            self._err(E_NOT_READY, HELLO, retryMs=NOT_READY_RETRY_MS)
            return
        if self.state in AUTHED_STATES:
            self._reset_sync()
        self._cancel("AUTH")
        self.peer = m
        self.peer_subs = m["subs"]
        self.nonce_c = m["nonce"]
        self.nonce_p = self.ctx.next_nonce()
        self.alike = False
        mine, theirs = self._groups(m)
        reply = []
        if mine is not None and theirs is not None and mine == theirs:
            self.alike = True
            pp, _ = self._proofs()
            b = self._send(HELLO, self._hello_fields(t, self.nonce_p, proof=pp))
            reply.append((HELLO, hexu(b)))
            self._set_state(S_HELLO_X)
            self._arm("AUTH", t, T_AUTH_MS)
        elif mine is not None and theirs is not None:
            self._send(HELLO, self._hello_fields(t, self.nonce_p))
            self.last_reply = None
            return self._foreign(t, HELLO)
        elif mine is not None:
            b = self._send(HELLO, self._hello_fields(t, self.nonce_p))
            reply.append((HELLO, hexu(b)))
            b = self._send(JOIN, {"groupId": self.ctx.group[0], "groupKey": self.ctx.group[1]})
            reply.append((JOIN, hexu(b)))
            self._set_state(S_LINKED)
        elif theirs is not None:
            b = self._send(HELLO, self._hello_fields(t, self.nonce_p))
            reply.append((HELLO, hexu(b)))
            self._set_state(S_HELLO_X)
            self._arm("AUTH", t, T_AUTH_MS)
        else:
            b = self._send(HELLO, self._hello_fields(t, self.nonce_p))
            reply.append((HELLO, hexu(b)))
            self._set_state(S_NOGROUP)
        self.last_reply = reply

    def _p_auth(self, t, m):
        if self.central or self.state != S_HELLO_X or not self.alike:
            return
        _, pc = self._proofs()
        if _hmac.compare_digest(m["proof"], pc):
            self._cancel("AUTH")
            self._authed(t)
        else:
            self._foreign(t, AUTH)

    def _join(self, t, m):
        gid, key, rekey = m["groupId"], m["groupKey"], bool(m.get("flags", 0) & JOIN_FLAG_REKEY)
        if group_id(key) != gid:
            return self._foreign(t, JOIN)
        mine = self.ctx.group[0] if self.ctx.group else None
        if mine == gid:
            return  # already in that group (e.g. a rekey that reached us on two links)
        if rekey:
            if self.state not in AUTHED_STATES:
                return self._foreign(t, JOIN)
            self.ctx.group = (gid, key)
            self._emit(a="group", groupId=hexu(gid), groupKey=hexu(key), rekey=True)
            return self._restart(t)
        if mine is None and self.state in (S_HELLO_X, S_NOGROUP) and self.peer is not None:
            self.ctx.group = (gid, key)
            self._emit(a="group", groupId=hexu(gid), groupKey=hexu(key), rekey=False)
            return self._restart(t)
        return self._foreign(t, JOIN)

    def _restart(self, t):
        self._reset_sync()
        self._cancel("AUTH", "HELLO", "BACKOFF", "RETRY")
        self.alike = False
        self.last_reply = None
        if self.central:
            self._start_hello(t)
        else:
            self.nonce_c = None
            self._set_state(S_LINKED)
            if self.cfg.is_hub and self.ctx.group is not None and "DEADLINE" not in self.timers:
                self._arm("DEADLINE", t, T_DEADLINE_MS)

    def _reset_sync(self):
        self._cancel("PAGE", "LIVE_PULL", "HB", "BACKOFF")
        self.pull = None
        self.pending_high = -1

    def _foreign(self, t, ref, send_err=True):
        if send_err:
            self._err(E_AUTH, ref)
        self._cancel_all()
        self._set_state(S_FOREIGN)
        self._emit(a="node", what="foreign")
        self._emit(a="disconnect", reason="foreign", retryMs=None)

    def _incompatible(self, t, reason):
        deadline = self.timers.get("DEADLINE")
        self._cancel_all()
        if deadline is not None:
            self.timers["DEADLINE"] = deadline   # a grouped hub still drops non-members at 10 s
        self._set_state(S_INCOMPATIBLE)
        if reason == "timeout" and self.central:
            self._arm("RETRY", t, T_RETRY_INCOMPATIBLE_MS)

    def _authed(self, t):
        self._set_state(S_AUTHED)
        self._cancel("AUTH", "DEADLINE", "HELLO", "BACKOFF", "RETRY")
        ps = self._peer_state()
        if ps.db_id != self.peer["dbId"]:
            ps.db_id = self.peer["dbId"]
            ps.wm = 0
            ps.exclude_ok = False
        self.pull = None
        self.pending_high = -1
        if self.peer.get("caps", 0) & CAP_FEED:
            self._send_pull(t, retry=False)
            self._set_state(S_SYNCING)
        else:
            self._set_state(S_SYNCED)
        if self.peer_subs & SUB_HEARTBEATS:
            self._emit(a="node", what="send_hb")
            self._arm("HB", t, T_HB_MS)
        if self.cfg.tracks_events and (subs_for(self.cfg.kind, self.peer["kind"]) & SUB_EVENTS) \
                and (self.peer.get("caps", 0) & CAP_EVENTS or self.peer["kind"] == KIND_HUB):
            self._emit(a="node", what="evt_since")

    def _group_changed(self, t):
        if self.state in (S_IDLE, S_CLOSED, S_FOREIGN, S_INCOMPATIBLE):
            return
        if self.ctx.group is None:
            return self._disconnect("left_group")
        if self.state == S_NOGROUP:
            self._send(JOIN, {"groupId": self.ctx.group[0], "groupKey": self.ctx.group[1]})
        self._restart(t)

    def _rekey(self, t):
        if self.state in AUTHED_STATES and self.ctx.group is not None:
            self._send(JOIN, {"groupId": self.ctx.group[0], "groupKey": self.ctx.group[1],
                              "flags": JOIN_FLAG_REKEY})
            return self._restart(t)
        self._group_changed(t)

    # -- pulls --------------------------------------------------------------------------------
    def _send_pull(self, t, retry):
        self.req_id = self.req_id % 255 + 1
        ps = self._peer_state()
        tries = (self.pull["tries"] + 1) if (retry and self.pull) else 1
        self._send(PULL, {"reqId": self.req_id, "since": ps.wm, "limit": self.limit,
                          "maxBytes": self.max_bytes, "dbId": ps.db_id, "exclude": 1})
        self.pull = {"reqId": self.req_id, "since": ps.wm, "recs": 0, "tries": tries}
        self._arm("PAGE", t, T_PAGE_MS)

    def _trigger_pull(self, t, feed_high):
        if not (self.peer.get("caps", 0) & CAP_FEED):
            return
        if self.pull is not None or "BACKOFF" in self.timers:
            self.pending_high = max(self.pending_high,
                                    feed_high if feed_high is not None else 0xFFFFFFFF)
            return
        self._send_pull(t, retry=False)

    def _page_failed(self, t):
        if self.pull["tries"] >= PAGE_TRIES:
            self.pull = None
            return self._disconnect("page_timeout", T_PAGE_FAIL_RETRY_MS)
        self._send_pull(t, retry=True)

    # -- receive ------------------------------------------------------------------------------
    def _rx(self, t, data):
        if self.state in (S_IDLE, S_CLOSED, S_FOREIGN) or not data:
            return
        mtype = data[0]
        if mtype == HELLO and len(data) >= 4 and data[1] == 0x01 and data[2] == 1 \
                and data[3] != PROTO:
            self._err(E_PROTO, HELLO)
            return self._incompatible(t, "proto")
        try:
            mtype, m = decode_msg(data)
        except SyncError:
            if mtype != ERR:
                self._err(E_BAD_MSG, mtype)
            return
        if m is None:
            return  # unknown message type: ignored
        if mtype == HELLO:
            return self._c_hello(t, m) if self.central else self._p_hello(t, m)
        if mtype == AUTH:
            return self._p_auth(t, m)
        if mtype == JOIN:
            return self._join(t, m)
        if mtype == ERR:
            return self._on_err(t, m)
        if self.state not in AUTHED_STATES:
            return
        self._data(t, mtype, m)

    def _data(self, t, mtype, m):
        ps = self._peer_state()
        if mtype == PULL:
            if m["dbId"] != self.ctx.db_id:
                return self._err(E_DB_CHANGED, PULL, dbId=self.ctx.db_id)
            self._emit(a="deliver", type="PULL", msg=m)
            return
        if mtype == REC:
            self._emit(a="deliver", type="REC", msg=m)
            if m["reqId"] == 0:
                self._arm("LIVE_PULL", t, T_LIVE_PULL_MS)
            elif self.pull is not None and m["reqId"] == self.pull["reqId"]:
                self.pull["recs"] += 1
                self._arm("PAGE", t, T_PAGE_MS)
            return
        if mtype == PAGE_END:
            if self.pull is None or m["reqId"] != self.pull["reqId"]:
                return
            self._cancel("PAGE")
            if m["count"] != self.pull["recs"]:
                return self._page_failed(t)
            ps.wm = max(self.pull["since"], m["scannedTo"])
            self._emit(a="commit", wm=ps.wm)
            if m["more"]:
                return self._send_pull(t, retry=False)
            self.pull = None
            if self.state == S_SYNCING:
                self._set_state(S_SYNCED)
            if self.pending_high > ps.wm:
                self.pending_high = -1
                self._send_pull(t, retry=False)
            else:
                self.pending_high = -1
            return
        if mtype == HB:
            self._emit(a="deliver", type="HB", msg=m)
            if m["hops"] == 0 and m["deviceId"] == self.peer_id:
                if m["dbId"] != ps.db_id:
                    ps.db_id = m["dbId"]
                    ps.wm = 0
                    ps.exclude_ok = False
                    if self.pull is not None:
                        self.pull = None
                        self._cancel("PAGE")
                    self._trigger_pull(t, m["feedHigh"])
                elif m["feedHigh"] > ps.wm:
                    self._trigger_pull(t, m["feedHigh"])
            return
        if mtype == SUB:
            self.peer_subs = m["subs"]
        self._emit(a="deliver", type=MSG_NAMES[mtype], msg=m)

    def _on_err(self, t, m):
        self._emit(a="deliver", type="ERR", msg=m)
        code = m["code"]
        retry = m.get("retryMs", DEFAULT_RETRY_MS)
        if code == E_AUTH:
            return self._foreign(t, None, send_err=False)
        if code == E_PROTO:
            return self._incompatible(t, "proto")
        if code == E_NOT_READY and self.central and self.state == S_LINKED and "HELLO" in self.timers:
            self._cancel("HELLO")
            self.backoff = "hello"
            return self._arm("BACKOFF", t, retry)
        if self.state not in AUTHED_STATES:
            return
        if code in (E_NOT_READY, E_BUSY) and self.pull is not None and m.get("refType") == PULL:
            self._cancel("PAGE")
            self.pull = None
            self.backoff = "pull"
            return self._arm("BACKOFF", t, retry)
        if code == E_TOO_BIG and self.pull is not None:
            self.max_bytes = max(PULL_MAXBYTES_MIN, self.max_bytes // 2)
            return self._send_pull(t, retry=False)
        if code == E_DB_CHANGED and m.get("dbId") is not None:
            ps = self._peer_state()
            ps.db_id = m["dbId"]
            ps.wm = 0
            ps.exclude_ok = False
            self.pull = None
            self._cancel("PAGE")
            if self.peer.get("caps", 0) & CAP_FEED:
                self._send_pull(t, retry=False)

    # -- timers -------------------------------------------------------------------------------
    def _on_timer(self, t, name):
        if name == "HELLO":
            if self.hello_tries >= HELLO_TRIES:
                return self._incompatible(t, "timeout")
            self.hello_tries += 1
            return self._resend_hello(t)
        if name == "RETRY":
            return self._start_hello(t)
        if name == "AUTH":
            return self._disconnect("auth_timeout")
        if name == "DEADLINE":
            return self._disconnect("auth_deadline")
        if name == "PAGE":
            if self.pull is not None:
                return self._page_failed(t)
            return
        if name == "LIVE_PULL":
            if self.pull is not None:
                return self._arm("LIVE_PULL", t, T_LIVE_PULL_MS)
            return self._send_pull(t, retry=False)
        if name == "HB":
            self._emit(a="node", what="send_hb")
            return self._arm("HB", t, T_HB_MS)
        if name == "BACKOFF":
            what, self.backoff = self.backoff, None
            if what == "hello":
                self.hello_tries = 1
                return self._resend_hello(t)
            if what == "pull":
                self._send_pull(t, retry=False)
                return
        raise ValueError(name)


def public_actions(actions):
    """Strip non-serialisable parts (decoded messages) from an action list."""
    out = []
    for a in actions:
        out.append({k: v for k, v in a.items() if k != "msg"})
    return out
