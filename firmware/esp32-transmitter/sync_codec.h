// MagicMaker SYNC protocol v1 codec, ESP32 hub side (docs/SYNC_PROTOCOL.md is normative; the
// executable reference is tools/sync/sync_ref.py and the shared vectors tools/sync/vectors.json).
//
//   §2  ids, groupId, HMAC proofs            §5.3 text normalisation for local edits
//   §3  record key (+ key string, hub hash)  §9   frames: fragmenter + reassembler
//   §4  record body TLV codec, canonical form, record classes, time rules
//   §5  versions, comparator, local stamp, §7 future check
//   §10/§11  every message (HELLO … JOIN): canonical encoder, strict decoder, HB hops patch
//
// Events, routing and page serving are in sync_events.h, the ledger model in sync_ledger.h and
// the session state machine in sync_session.h.
//
// Portable C++11 (the Arduino-ESP32 2.0.x sketch build uses -std=gnu++11), no Arduino, NimBLE,
// heap or exceptions, so it also builds on the host (test/host, `make test`). Header-only and
// every function `inline`: including it costs nothing until something is used. Not included by
// the sketch yet (P2 wires it in).
//
// Conventions: all wire integers little-endian; byte strings fixed arrays; strings are raw UTF-8
// bytes with a length (0 = absent). A decode result is a Status: code 0 = ok, else an ERR code
// (BAD_MSG or CLOCK) and a short reason tag matching the vectors' "reason" (informative only).
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "sync_crypto.h"

namespace mmsync {

// ---- Constants (§18) -------------------------------------------------------------------------
static const uint8_t PROTO = 1;
static const uint8_t FRAME_VERSION = 1;
static const size_t FRAME_HEADER_LEN = 2;
static const size_t ATT_OVERHEAD = 3;
static const uint16_t MTU_MIN = 23;
static const uint16_t MTU_MAX = 517;
static const uint16_t SMALL_MTU_BELOW = 64;  // MTU < 64 -> small pull profile
static const uint16_t MAXMSG_MIN = 512;
static const uint16_t HUB_MAXMSG = 512;
static const uint16_t PHONE_MAXMSG = 1024;

static const uint8_t PACKET_MIN = 3;
static const uint8_t PACKET_MAX = 29;
static const uint8_t LABEL_MAX = 64;
static const uint8_t NOTE_MAX = 160;
static const uint8_t KIND_MAX = 16;
static const uint16_t BODY_MAX = 360;
static const uint8_t SEENBY_MAX = 4;
static const uint8_t HB_LINKS_MAX = 4;
static const uint8_t HB_EVTWM_MAX = 4;

static const uint8_t NS_LIB = 0;
static const uint8_t NS_NEWWAND = 1;

static const uint8_t FLAG_DELETED = 0x01;
static const uint8_t FLAG_USER_EDITED = 0x02;
static const uint8_t FLAG_PRESET = 0x04;
static const uint8_t FLAG_MASK = 0x07;

static const uint8_t CAT_UNKNOWN = 0, CAT_SHOW = 1, CAT_ANIMATION = 2, CAT_COLOR = 3;
static const uint8_t PLACE_PRESETS = 1, PLACE_COLORS = 2, PLACE_LIBRARY = 3, PLACE_RAW = 4;

static const int64_t U_PRESENCE = 1;
static const int64_t U_LEGACY_ANDROID = 2;
static const int64_t U_LEGACY_IOS = 3;
static const int64_t U_MIN_MS = 1500000000000LL;
static const int64_t FUTURE_BOUND_MS = 86400000LL;
static const int64_t I64_MAX = 9223372036854775807LL;  // largest updatedAt (no signed overflow)

static const uint8_t KIND_HUB = 1, KIND_ANDROID = 2, KIND_IOS = 3;

static const uint8_t SUB_RECORDS = 0x01;
static const uint8_t SUB_EVENTS = 0x02;
static const uint8_t SUB_HEARTBEATS = 0x04;

static const uint16_t CAP_FEED = 0x0001;
static const uint16_t CAP_EVENTS = 0x0002;
static const uint16_t CAP_TRANSMITTER = 0x0008;
static const uint16_t CAP_PROGRAMS = 0x0010;
static const uint16_t CAP_LOOPS_BY_HEX = 0x0020;
static const uint16_t CAPS_HUB = 0x0039;
static const uint16_t CAPS_ANDROID = 0x003B;
static const uint16_t CAPS_IOS = 0x0001;

static const uint8_t PULL_LIMIT_DEFAULT = 24;
static const uint16_t PULL_MAXBYTES_DEFAULT = 1536;
static const uint8_t PULL_LIMIT_SMALL = 8;
static const uint16_t PULL_MAXBYTES_SMALL = 512;
static const uint16_t PULL_MAXBYTES_MIN = 256;

static const uint32_t T_HELLO_MS = 5000;
static const uint8_t HELLO_TRIES = 3;
static const uint32_t T_RETRY_INCOMPATIBLE_MS = 60000;
static const uint32_t T_AUTH_MS = 5000;
static const uint32_t T_DEADLINE_MS = 10000;
static const uint32_t T_PAGE_MS = 10000;
static const uint8_t PAGE_TRIES = 3;
static const uint32_t T_PAGE_FAIL_RETRY_MS = 30000;
static const uint32_t T_LIVE_PULL_MS = 2000;
static const uint32_t T_HB_MS = 60000;
static const uint32_t T_HB_SPACING_MS = 5000;
static const uint32_t T_PATH_FRESH_MS = 90000;
static const uint16_t NOT_READY_RETRY_MS = 500;
static const uint16_t BUSY_RETRY_MS = 1000;
static const uint16_t DEFAULT_RETRY_MS = 1000;

static const uint8_t EVT_WINDOW_BITS = 64;
static const uint8_t EVT_EPOCHS_KEPT = 2;
static const uint16_t EVT_RING_ANDROID = 2000;
static const uint32_t EVT_REPLAY_DEDUPE_MS = 5000;
static const uint32_t TOMBSTONE_CAP_PHONE = 5000;

// Message types (§11)
enum MsgType : uint8_t {
  MSG_HELLO = 0x01,
  MSG_PULL = 0x02,
  MSG_REC = 0x03,
  MSG_PAGE_END = 0x04,
  MSG_EVT = 0x05,
  MSG_EVT_SINCE = 0x06,
  MSG_EVT_GAP = 0x07,
  MSG_HB = 0x08,
  MSG_SUB = 0x09,
  MSG_ERR = 0x0A,
  MSG_AUTH = 0x0B,
  MSG_JOIN = 0x0C
};

// Error codes (§12)
enum ErrCode : uint8_t {
  E_OK = 0,
  E_BAD_FRAME = 1,
  E_TOO_BIG = 2,
  E_BAD_MSG = 3,
  E_PROTO = 4,
  E_DB_CHANGED = 5,
  E_FULL = 6,
  E_CLOCK = 7,
  E_BUSY = 8,
  E_COLLISION = 9,
  E_AUTH = 10,
  E_NOT_READY = 11
};

static const uint8_t JOIN_FLAG_REKEY = 0x01;
static const uint8_t EVT_FLAG_TAGGED = 0x01;
static const uint8_t EVT_FLAG_REPLAY = 0x02;
static const uint8_t HB_LINK_SYNCED = 0x01;
static const uint8_t HB_LINK_TX_READY = 0x02;
static const uint8_t HB_LINK_WIFI = 0x04;

inline const char* msgTypeName(uint8_t t) {
  static const char* const names[] = {"HELLO", "PULL", "REC", "PAGE_END", "EVT", "EVT_SINCE",
                                      "EVT_GAP", "HB", "SUB", "ERR", "AUTH", "JOIN"};
  return (t >= 1 && t <= 12) ? names[t - 1] : "UNKNOWN";
}

inline const char* errCodeName(uint8_t c) {
  static const char* const names[] = {"OK", "BAD_FRAME", "TOO_BIG", "BAD_MSG", "PROTO", "DB_CHANGED",
                                      "FULL", "CLOCK", "BUSY", "COLLISION", "AUTH", "NOT_READY"};
  return c <= 11 ? names[c] : "UNKNOWN";
}

// ---- Status --------------------------------------------------------------------------------
struct Status {
  uint8_t code;        // E_OK, or the ERR code (E_BAD_MSG / E_CLOCK)
  const char* reason;  // short tag, informative ("order", "length", ...)
  bool ok() const { return code == E_OK; }
};

inline Status statusOk() {
  Status s = {E_OK, ""};
  return s;
}
inline Status badMsg(const char* reason) {
  Status s = {E_BAD_MSG, reason};
  return s;
}
inline Status clockErr(const char* reason) {
  Status s = {E_CLOCK, reason};
  return s;
}

// ---- Ids -----------------------------------------------------------------------------------
// deviceId, dbId, groupId, nonce, origin: 8 opaque bytes.
struct Id8 {
  uint8_t b[8];
};

inline Id8 makeId8(const uint8_t* p) {
  Id8 x;
  memcpy(x.b, p, 8);
  return x;
}
inline Id8 zeroId8() {
  Id8 x;
  memset(x.b, 0, 8);
  return x;
}
inline bool operator==(const Id8& a, const Id8& b) { return memcmp(a.b, b.b, 8) == 0; }
inline bool operator!=(const Id8& a, const Id8& b) { return memcmp(a.b, b.b, 8) != 0; }
inline bool isZero(const Id8& a) {
  uint8_t d = 0;
  for (int i = 0; i < 8; i++) d = (uint8_t)(d | a.b[i]);
  return d == 0;
}
// The comparator reads origin as a big-endian u64 (§5.1).
inline uint64_t beU64(const Id8& a) {
  uint64_t v = 0;
  for (int i = 0; i < 8; i++) v = (v << 8) | a.b[i];
  return v;
}

// Uppercase hex of n bytes into out (2n chars + NUL). Returns 2n.
inline size_t hexUpper(const uint8_t* p, size_t n, char* out) {
  static const char digits[] = "0123456789ABCDEF";
  for (size_t i = 0; i < n; i++) {
    out[2 * i] = digits[p[i] >> 4];
    out[2 * i + 1] = digits[p[i] & 15];
  }
  out[2 * n] = 0;
  return 2 * n;
}

// ---- Little-endian helpers -----------------------------------------------------------------
inline void putLE(uint8_t* p, uint64_t v, size_t w) {
  for (size_t i = 0; i < w; i++) p[i] = (uint8_t)(v >> (8 * i));
}
inline uint64_t getLE(const uint8_t* p, size_t w) {
  uint64_t v = 0;
  for (size_t i = 0; i < w; i++) v |= (uint64_t)p[i] << (8 * i);
  return v;
}
inline int64_t getLEs(const uint8_t* p, size_t w) {
  uint64_t v = getLE(p, w);
  if (w < 8 && ((v >> (8 * w - 1)) & 1u)) v |= ~(uint64_t)0 << (8 * w);
  return (int64_t)v;
}

// A byte writer with a fixed capacity; `failed` latches on overflow or an invalid field.
struct Writer {
  uint8_t* p;
  size_t cap;
  size_t len;
  bool failed;

  Writer(uint8_t* out, size_t capacity) : p(out), cap(capacity), len(0), failed(false) {}
  void put(uint8_t b) {
    if (len < cap) {
      p[len++] = b;
    } else {
      failed = true;
    }
  }
  void put(const uint8_t* src, size_t n) {
    if (n == 0) return;
    if (len + n <= cap) {
      memcpy(p + len, src, n);
      len += n;
    } else {
      failed = true;
    }
  }
  void tlv(uint8_t tag, const uint8_t* v, size_t n) {
    if (n > 255) {
      failed = true;
      return;
    }
    put(tag);
    put((uint8_t)n);
    put(v, n);
  }
  void tlvInt(uint8_t tag, uint64_t v, size_t w) {
    uint8_t b[8];
    putLE(b, v, w);
    tlv(tag, b, w);
  }
};

// TLV framing check: [tag][len][value] repeated exactly to the end (`truncated` otherwise).
inline bool tlvFramingOk(const uint8_t* p, size_t n, size_t start) {
  size_t i = start;
  while (i < n) {
    if (i + 2 > n) return false;
    if (i + 2 + p[i + 1] > n) return false;
    i += 2 + (size_t)p[i + 1];
  }
  return true;
}

// ---- UTF-8 (RFC 3629) ------------------------------------------------------------------------
// Decodes one scalar at p[i..n). Returns its byte length (1..4) and the code point, or 0 for an
// invalid sequence (overlong, surrogate, > U+10FFFF, truncated, stray continuation byte).
inline size_t utf8Next(const uint8_t* p, size_t n, size_t i, uint32_t* cp) {
  if (i >= n) return 0;
  const uint8_t c = p[i];
  if (c < 0x80) {
    *cp = c;
    return 1;
  }
  size_t need;
  uint32_t v;
  if (c >= 0xC2 && c <= 0xDF) {
    need = 1;
    v = c & 0x1Fu;
  } else if (c >= 0xE0 && c <= 0xEF) {
    need = 2;
    v = c & 0x0Fu;
  } else if (c >= 0xF0 && c <= 0xF4) {
    need = 3;
    v = c & 0x07u;
  } else {
    return 0;
  }
  if (i + need >= n) return 0;  // truncated sequence
  for (size_t k = 1; k <= need; k++) {
    const uint8_t b = p[i + k];
    if ((b & 0xC0) != 0x80) return 0;
    v = (v << 6) | (b & 0x3Fu);
  }
  if (need == 2 && (v < 0x800u || (v >= 0xD800u && v <= 0xDFFFu))) return 0;
  if (need == 3 && (v < 0x10000u || v > 0x10FFFFu)) return 0;
  *cp = v;
  return need + 1;
}

inline bool utf8Valid(const uint8_t* p, size_t n) {
  size_t i = 0;
  uint32_t cp;
  while (i < n) {
    const size_t w = utf8Next(p, n, i, &cp);
    if (w == 0) return false;
    i += w;
  }
  return true;
}

// ---- Text normalisation for local edits (§5.3) --------------------------------------------------
// The Unicode White_Space set, exactly (not the platform's notion; U+200B is not in it).
inline bool isWhiteSpace(uint32_t cp) {
  return (cp >= 0x09 && cp <= 0x0D) || cp == 0x20 || cp == 0x85 || cp == 0xA0 || cp == 0x1680 ||
         (cp >= 0x2000 && cp <= 0x200A) || cp == 0x2028 || cp == 0x2029 || cp == 0x202F ||
         cp == 0x205F || cp == 0x3000;
}

// Start of the code point that ends at p[end) (UTF-8 is self-synchronising; input is valid).
inline size_t utf8PrevStart(const uint8_t* p, size_t begin, size_t end) {
  size_t i = end - 1;
  while (i > begin && (p[i] & 0xC0) == 0x80) i--;
  return i;
}

// normalize(s, maxBytes): trim White_Space -> keep the longest prefix of whole code points of at
// most maxBytes UTF-8 bytes -> trim again. `in` must be valid UTF-8 (returns false otherwise).
// The result is in[*outStart .. *outStart + *outLen); *outLen == 0 means "absent".
inline bool normalizeTextRange(const uint8_t* in, size_t n, size_t maxBytes, size_t* outStart,
                               size_t* outLen) {
  *outStart = 0;
  *outLen = 0;
  if (!utf8Valid(in, n)) return false;
  uint32_t cp = 0;
  size_t s = 0;
  while (s < n) {
    const size_t w = utf8Next(in, n, s, &cp);
    if (!isWhiteSpace(cp)) break;
    s += w;
  }
  size_t e = n;
  while (e > s) {
    const size_t ps = utf8PrevStart(in, s, e);
    utf8Next(in, n, ps, &cp);
    if (!isWhiteSpace(cp)) break;
    e = ps;
  }
  if (e <= s) return true;
  size_t cut = s;
  while (cut < e) {
    const size_t w = utf8Next(in, n, cut, &cp);
    if ((cut - s) + w > maxBytes) break;
    cut += w;
  }
  while (cut > s) {
    const size_t ps = utf8PrevStart(in, s, cut);
    utf8Next(in, n, ps, &cp);
    if (!isWhiteSpace(cp)) break;
    cut = ps;
  }
  *outStart = s;
  *outLen = cut - s;
  return true;
}

// Copies the normalised text into out (capacity >= maxBytes). *outLen 0 = absent.
inline bool normalizeText(const uint8_t* in, size_t n, size_t maxBytes, uint8_t* out,
                          size_t* outLen) {
  size_t s, len;
  if (!normalizeTextRange(in, n, maxBytes, &s, &len)) {
    *outLen = 0;
    return false;
  }
  if (len) memcpy(out, in + s, len);
  *outLen = len;
  return true;
}

// kind: every code point outside 0x20..0x7E becomes '?', then normalize(..., 16). After the
// mapping the only White_Space left is U+0020. out holds KIND_MAX bytes.
inline bool normalizeKind(const uint8_t* in, size_t n, uint8_t* out, size_t* outLen) {
  *outLen = 0;
  if (!utf8Valid(in, n)) return false;
  size_t i = 0, k = 0;
  bool leading = true;
  uint32_t cp = 0;
  while (i < n && k < KIND_MAX) {
    i += utf8Next(in, n, i, &cp);
    const uint8_t c = (cp >= 0x20 && cp <= 0x7E) ? (uint8_t)cp : (uint8_t)'?';
    if (leading && c == ' ') continue;
    leading = false;
    out[k++] = c;
  }
  while (k > 0 && out[k - 1] == ' ') k--;
  *outLen = k;
  return true;
}

// ---- Record key (§3) -----------------------------------------------------------------------
struct Key {
  uint8_t ns;
  uint8_t len;  // packet length 3..29
  uint8_t packet[PACKET_MAX];
};

inline Status checkPacket(const uint8_t* p, size_t n) {
  if (n < PACKET_MIN || n > PACKET_MAX) return badMsg("packet_length");
  if (p[0] != 0x83 || p[1] != 0x01) return badMsg("packet_prefix");
  return statusOk();
}

inline Key makeKey(uint8_t ns, const uint8_t* packet, size_t n) {
  Key k;
  memset(&k, 0, sizeof(k));
  k.ns = ns;
  k.len = (uint8_t)(n > PACKET_MAX ? PACKET_MAX : n);
  memcpy(k.packet, packet, k.len);
  return k;
}

// key = ns (u8) ‖ packet; out holds 1 + PACKET_MAX bytes. Returns the encoded length.
inline size_t encodeKey(const Key& k, uint8_t* out) {
  out[0] = k.ns;
  memcpy(out + 1, k.packet, k.len);
  return 1 + (size_t)k.len;
}

inline Status decodeKey(const uint8_t* v, size_t n, Key* out) {
  if (n < 1 + (size_t)PACKET_MIN || n > 1 + (size_t)PACKET_MAX) return badMsg("length");
  if (v[0] != NS_LIB && v[0] != NS_NEWWAND) return badMsg("range");
  Status s = checkPacket(v + 1, n - 1);
  if (!s.ok()) return s;
  memset(out, 0, sizeof(*out));
  out->ns = v[0];
  out->len = (uint8_t)(n - 1);
  memcpy(out->packet, v + 1, n - 1);
  return statusOk();
}

inline bool operator==(const Key& a, const Key& b) {
  return a.ns == b.ns && a.len == b.len && memcmp(a.packet, b.packet, a.len) == 0;
}
inline bool operator!=(const Key& a, const Key& b) { return !(a == b); }

// Compares the encoded key bytes (ns ‖ packet) lexicographically: the tombstone-cap tie-break.
inline int compareKeyBytes(const Key& a, const Key& b) {
  if (a.ns != b.ns) return a.ns < b.ns ? -1 : 1;
  const size_t n = a.len < b.len ? a.len : b.len;
  const int c = memcmp(a.packet, b.packet, n);
  if (c != 0) return c < 0 ? -1 : 1;
  if (a.len != b.len) return a.len < b.len ? -1 : 1;
  return 0;
}

// Phones' ledger map key "<ns>:<HEX>"; out holds at least 4 + 2 * PACKET_MAX bytes (63).
inline size_t keyString(const Key& k, char* out) {
  size_t i = 0;
  if (k.ns >= 100) out[i++] = (char)('0' + k.ns / 100);
  if (k.ns >= 10) out[i++] = (char)('0' + (k.ns / 10) % 10);
  out[i++] = (char)('0' + k.ns % 10);
  out[i++] = ':';
  return i + hexUpper(k.packet, k.len, out + i);
}

// The hub's index hash: FNV-1a 64 over the encoded key bytes.
inline uint64_t keyHash(const Key& k) {
  uint8_t b[1 + PACKET_MAX];
  const size_t n = encodeKey(k, b);
  return fnv1a64(b, n);
}

// ---- Record body (§4) ------------------------------------------------------------------------
static const uint8_t T_KEY = 0x10, T_UPDATED = 0x11, T_ORIGIN = 0x12, T_FLAGS = 0x13,
                     T_LABEL = 0x14, T_CATEGORY = 0x15, T_NOTE = 0x16, T_KIND = 0x17,
                     T_PLACE = 0x18;

enum RecordClass : uint8_t {
  CLS_NONE = 0,
  CLS_PRESENCE = 1,
  CLS_USER = 2,
  CLS_RESET = 3,
  CLS_TOMBSTONE = 4,
  CLS_NEWWAND = 5
};

inline const char* recordClassName(uint8_t c) {
  static const char* const names[] = {"NONE", "PRESENCE", "USER", "RESET", "TOMBSTONE", "NEWWAND"};
  return c <= 5 ? names[c] : "NONE";
}

// A decoded record body. Optional strings: length 0 = absent; flags 0 = absent.
struct Body {
  Key key;
  int64_t updatedAt;
  bool hasOrigin;
  Id8 origin;
  uint8_t flags;
  uint8_t labelLen;
  uint8_t label[LABEL_MAX];
  bool hasCategory;
  uint8_t category;
  uint8_t noteLen;
  uint8_t note[NOTE_MAX];
  uint8_t kindLen;
  uint8_t kind[KIND_MAX];
  bool hasPlace;
  uint8_t place;
};

inline void clearBody(Body* b) { memset(b, 0, sizeof(*b)); }

// Class implied by ns + flags + origin + content (time not considered).
inline RecordClass bodyShape(const Body& b) {
  if (b.key.ns == NS_NEWWAND) return CLS_NEWWAND;
  if (b.flags & FLAG_DELETED) return CLS_TOMBSTONE;
  if (b.flags & (FLAG_USER_EDITED | FLAG_PRESET)) return CLS_USER;
  if (!b.hasOrigin && !b.labelLen && !b.hasCategory && !b.noteLen && !b.kindLen && !b.hasPlace)
    return CLS_PRESENCE;
  return CLS_RESET;
}

// Class / field / time rules (§4.4). Check order: updatedAt <= 0 -> fields -> time.
inline Status validateBodyFields(const Body& b, RecordClass* clsOut) {
  const int64_t u = b.updatedAt;
  if (u <= 0) return badMsg("time");
  const RecordClass shape = bodyShape(b);
  bool smallOk = false;  // legacy stamps 2 / 3 allowed
  if (b.key.ns == NS_NEWWAND) {
    if (b.flags & (FLAG_USER_EDITED | FLAG_PRESET)) return badMsg("class");
    if (!b.hasOrigin) return badMsg("class");
    if (b.hasCategory || b.kindLen || b.hasPlace) return badMsg("class");
    if (b.flags & FLAG_DELETED) {
      if (b.labelLen || b.noteLen) return badMsg("class");
    } else {
      if (!b.labelLen) return badMsg("class");
      smallOk = true;
    }
  } else if (shape == CLS_TOMBSTONE) {
    if (b.flags != FLAG_DELETED) return badMsg("class");
    if (!b.hasOrigin) return badMsg("class");
    if (b.labelLen || b.hasCategory || b.noteLen || b.kindLen || b.hasPlace) return badMsg("class");
  } else if (shape == CLS_USER) {
    if (!b.hasOrigin || !b.labelLen || !b.hasCategory || !b.hasPlace) return badMsg("class");
    smallOk = true;
  } else if (shape == CLS_PRESENCE) {
    if (u != U_PRESENCE) return badMsg("class");
    if (clsOut) *clsOut = CLS_PRESENCE;
    return statusOk();
  } else {  // RESET
    if (!b.hasOrigin) return badMsg("class");
    if (b.labelLen || b.hasCategory || b.kindLen || b.hasPlace) return badMsg("class");
  }
  if (u == U_PRESENCE) return badMsg("class");
  if (u == U_LEGACY_ANDROID || u == U_LEGACY_IOS) {
    if (!smallOk) return badMsg("class");
  } else if (u < U_MIN_MS) {
    return clockErr("clock_invalid");
  }
  if (clsOut) *clsOut = shape;
  return statusOk();
}

// Canonical body bytes -> Body (§4.2). BAD_MSG or CLOCK on failure.
inline Status decodeBody(const uint8_t* p, size_t n, Body* out, RecordClass* clsOut) {
  if (clsOut) *clsOut = CLS_NONE;
  if (n > BODY_MAX) return badMsg("oversize");
  if (!tlvFramingOk(p, n, 0)) return badMsg("truncated");
  Body b;
  clearBody(&b);
  bool hasKey = false, hasU = false;
  int prev = -1;
  for (size_t i = 0; i < n;) {
    const uint8_t tag = p[i];
    const uint8_t ln = p[i + 1];
    const uint8_t* v = p + i + 2;
    i += 2 + (size_t)ln;
    if (tag < T_KEY || tag > T_PLACE) return badMsg("unknown_tag");
    if ((int)tag == prev) return badMsg("duplicate");
    if ((int)tag < prev) return badMsg("order");
    prev = tag;
    switch (tag) {
      case T_KEY: {
        Status s = decodeKey(v, ln, &b.key);
        if (!s.ok()) return s;
        hasKey = true;
        break;
      }
      case T_UPDATED:
        if (ln != 8) return badMsg("length");
        b.updatedAt = getLEs(v, 8);
        hasU = true;
        break;
      case T_ORIGIN:
        if (ln != 8) return badMsg("length");
        b.origin = makeId8(v);
        if (isZero(b.origin)) return badMsg("zero_origin");
        b.hasOrigin = true;
        break;
      case T_FLAGS:
        if (ln != 1) return badMsg("length");
        if (v[0] == 0) return badMsg("zero_flags");
        if (v[0] & ~FLAG_MASK) return badMsg("range");
        b.flags = v[0];
        break;
      case T_LABEL:
        if (ln < 1 || ln > LABEL_MAX) return badMsg("length");
        if (!utf8Valid(v, ln)) return badMsg("utf8");
        memcpy(b.label, v, ln);
        b.labelLen = ln;
        break;
      case T_CATEGORY:
        if (ln != 1) return badMsg("length");
        if (v[0] > CAT_COLOR) return badMsg("range");
        b.category = v[0];
        b.hasCategory = true;
        break;
      case T_NOTE:
        if (ln < 1 || ln > NOTE_MAX) return badMsg("length");
        if (!utf8Valid(v, ln)) return badMsg("utf8");
        memcpy(b.note, v, ln);
        b.noteLen = ln;
        break;
      case T_KIND:
        if (ln < 1 || ln > KIND_MAX) return badMsg("length");
        for (uint8_t k = 0; k < ln; k++)
          if (v[k] < 0x20 || v[k] > 0x7E) return badMsg("ascii");
        memcpy(b.kind, v, ln);
        b.kindLen = ln;
        break;
      default:  // T_PLACE
        if (ln != 1) return badMsg("length");
        if (v[0] < PLACE_PRESETS || v[0] > PLACE_RAW) return badMsg("range");
        b.place = v[0];
        b.hasPlace = true;
        break;
    }
  }
  if (!hasKey || !hasU) return badMsg("missing");
  Status s = validateBodyFields(b, clsOut);
  if (!s.ok()) return s;
  if (out) *out = b;
  return statusOk();
}

// Body -> canonical bytes. The result is validated (decoded again), so an invalid Body is never
// emitted. out holds BODY_MAX bytes.
inline Status encodeBody(const Body& b, uint8_t* out, size_t cap, size_t* outLen) {
  *outLen = 0;
  if (b.key.len < PACKET_MIN || b.key.len > PACKET_MAX) return badMsg("length");
  if (b.labelLen > LABEL_MAX || b.noteLen > NOTE_MAX || b.kindLen > KIND_MAX) return badMsg("length");
  Writer w(out, cap);
  uint8_t kb[1 + PACKET_MAX];
  w.tlv(T_KEY, kb, encodeKey(b.key, kb));
  w.tlvInt(T_UPDATED, (uint64_t)b.updatedAt, 8);
  if (b.hasOrigin) w.tlv(T_ORIGIN, b.origin.b, 8);
  if (b.flags) w.tlv(T_FLAGS, &b.flags, 1);
  if (b.labelLen) w.tlv(T_LABEL, b.label, b.labelLen);
  if (b.hasCategory) w.tlv(T_CATEGORY, &b.category, 1);
  if (b.noteLen) w.tlv(T_NOTE, b.note, b.noteLen);
  if (b.kindLen) w.tlv(T_KIND, b.kind, b.kindLen);
  if (b.hasPlace) w.tlv(T_PLACE, &b.place, 1);
  if (w.failed) return badMsg("oversize");
  Status s = decodeBody(out, w.len, NULL, NULL);
  if (!s.ok()) return s;
  *outLen = w.len;
  return statusOk();
}

// The key of an invalid body, for ERR{code, refType 0x03, key}: the 0x10 TLV when it parses (the
// last good one before a bad one). False when there is none or the TLVs do not frame. p[0..n)
// must be the whole body: for a received REC use recErrKey() (Rec keeps at most BODY_MAX bytes).
inline bool bodyErrKey(const uint8_t* p, size_t n, Key* out) {
  if (!tlvFramingOk(p, n, 0)) return false;
  bool found = false;
  for (size_t i = 0; i < n;) {
    const uint8_t tag = p[i];
    const uint8_t ln = p[i + 1];
    if (tag == T_KEY) {
      Key k;
      if (!decodeKey(p + i + 2, ln, &k).ok()) break;
      *out = k;
      found = true;
    }
    i += 2 + (size_t)ln;
  }
  return found;
}

// ---- Versions (§5) ---------------------------------------------------------------------------
struct Version {
  int64_t updatedAt;
  uint64_t origin;  // big-endian value of origin, 0 when absent
  uint32_t crc;     // CRC-32 of the canonical body bytes
};

inline Version versionOf(const Body& b, const uint8_t* bodyBytes, size_t n) {
  Version v;
  v.updatedAt = b.updatedAt;
  v.origin = b.hasOrigin ? beU64(b.origin) : 0;
  v.crc = crc32(bodyBytes, n);
  return v;
}

// -1 / 0 / +1: signed updatedAt, then unsigned origin, then unsigned CRC.
inline int compareVersions(const Version& a, const Version& b) {
  if (a.updatedAt != b.updatedAt) return a.updatedAt < b.updatedAt ? -1 : 1;
  if (a.origin != b.origin) return a.origin < b.origin ? -1 : 1;
  if (a.crc != b.crc) return a.crc < b.crc ? -1 : 1;
  return 0;
}

// updatedAt of a local edit: max(now, ledger.updatedAt + 1, lastLocalStamp + 1, 1.5e12).
// Saturates at I64_MAX instead of overflowing (an entry already at I64_MAX cannot be beaten;
// Ledger::localEdit refuses that edit).
inline int64_t localStamp(int64_t nowMs, int64_t ledgerUpdatedAt, int64_t lastLocalStamp) {
  int64_t u = nowMs;
  if (ledgerUpdatedAt >= u) u = ledgerUpdatedAt < I64_MAX ? ledgerUpdatedAt + 1 : I64_MAX;
  if (lastLocalStamp >= u) u = lastLocalStamp < I64_MAX ? lastLocalStamp + 1 : I64_MAX;
  if (U_MIN_MS > u) u = U_MIN_MS;
  return u;
}

// Receiver clock rule (§7): nowKnown false (hub before any member clock) skips the check. A clock
// within 24 h of I64_MAX sees nothing as future (no signed overflow).
inline Status checkFuture(int64_t updatedAt, bool nowKnown, int64_t nowMs) {
  if (nowKnown && nowMs <= I64_MAX - FUTURE_BOUND_MS && updatedAt > nowMs + FUTURE_BOUND_MS)
    return clockErr("clock_future");
  return statusOk();
}

// ---- Apply rule (§6.2) -------------------------------------------------------------------------
// The accept decision for a received record, shared by the hub's log and the phones' ledger.
enum ApplyStatus : uint8_t {
  APPLY_ACCEPT = 1,
  APPLY_DUPLICATE = 2,
  APPLY_STALE = 3,
  APPLY_BAD_MSG = 4,
  APPLY_CLOCK = 5
};

inline const char* applyStatusName(uint8_t s) {
  static const char* const names[] = {"?", "ACCEPT", "DUPLICATE", "STALE", "BAD_MSG", "CLOCK"};
  return s <= APPLY_CLOCK ? names[s] : "?";
}

// decode + validate (§4) -> future check (§7) -> compare with the current version (NULL: the key
// has no entry, accept). On BAD_MSG / CLOCK *err says why (answer with ERR{code, refType 3, key}).
// *decoded and *version are filled whenever the body is valid.
inline ApplyStatus applyCheck(const uint8_t* body, size_t n, bool nowKnown, int64_t nowMs,
                              const Version* current, Body* decoded, Version* version,
                              Status* err) {
  Body b;
  Status s = decodeBody(body, n, &b, NULL);
  if (s.ok()) s = checkFuture(b.updatedAt, nowKnown, nowMs);
  if (err) *err = s;
  if (!s.ok()) return s.code == E_CLOCK ? APPLY_CLOCK : APPLY_BAD_MSG;
  const Version v = versionOf(b, body, n);
  if (decoded) *decoded = b;
  if (version) *version = v;
  if (current) {
    const int c = compareVersions(v, *current);
    if (c == 0) return APPLY_DUPLICATE;
    if (c < 0) return APPLY_STALE;
  }
  return APPLY_ACCEPT;
}

// ---- Sync group and proofs (§13) ---------------------------------------------------------------
static const uint8_t GROUP_ID_PREFIX[8] = {'M', 'M', 'G', 'R', 'O', 'U', 'P', '1'};
static const uint8_t PROOF_P_PREFIX[8] = {'M', 'M', 'S', 'Y', 'N', 'C', '1', 'P'};
static const uint8_t PROOF_C_PREFIX[8] = {'M', 'M', 'S', 'Y', 'N', 'C', '1', 'C'};

// groupId = SHA-256("MMGROUP1" ‖ groupKey)[0..7]
inline Id8 groupIdOf(const uint8_t key[16]) {
  Sha256 s;
  s.update(GROUP_ID_PREFIX, 8);
  s.update(key, 16);
  uint8_t d[32];
  s.finish(d);
  return makeId8(d);
}

// T = nonceC ‖ nonceP ‖ idC ‖ idP (32 bytes)
inline void authTranscript(const Id8& nonceC, const Id8& nonceP, const Id8& idC, const Id8& idP,
                           uint8_t out[32]) {
  memcpy(out, nonceC.b, 8);
  memcpy(out + 8, nonceP.b, 8);
  memcpy(out + 16, idC.b, 8);
  memcpy(out + 24, idP.b, 8);
}

// proofP = HMAC(groupKey, "MMSYNC1P" ‖ T)[0..15]; proofC with "MMSYNC1C".
inline void authProof(bool peripheral, const uint8_t key[16], const Id8& nonceC, const Id8& nonceP,
                      const Id8& idC, const Id8& idP, uint8_t out[16]) {
  uint8_t t[32];
  authTranscript(nonceC, nonceP, idC, idP, t);
  uint8_t mac[32];
  hmacSha256(key, 16, peripheral ? PROOF_P_PREFIX : PROOF_C_PREFIX, 8, t, 32, mac);
  memcpy(out, mac, 16);
}

inline void proofP(const uint8_t key[16], const Id8& nonceC, const Id8& nonceP, const Id8& idC,
                   const Id8& idP, uint8_t out[16]) {
  authProof(true, key, nonceC, nonceP, idC, idP, out);
}
inline void proofC(const uint8_t key[16], const Id8& nonceC, const Id8& nonceP, const Id8& idC,
                   const Id8& idP, uint8_t out[16]) {
  authProof(false, key, nonceC, nonceP, idC, idP, out);
}

// ---- Messages (§10, §11) -----------------------------------------------------------------------
// One plain struct per message type. Optional scalar fields carry a has* flag (a decoder sets it
// even when the value equals the default, an encoder omits a default); strings and packets are
// {len, bytes} with len 0 = absent; repeatable fields are an array plus a count.

template <size_t N>
struct Str {
  uint8_t len;
  uint8_t b[N];
};
typedef Str<16> Str16;
typedef Str<20> Str20;
typedef Str<40> Str40;

struct Packet {
  uint8_t len;
  uint8_t b[PACKET_MAX];
};

struct HbLink {
  Id8 peerId;
  uint8_t peerKind;  // 1..3
  uint8_t flags;     // HB_LINK_*
};

struct EvtWm {
  Id8 origin;
  uint32_t epoch;
  uint32_t seq;
};

struct Hello {
  uint8_t proto;
  Id8 deviceId;
  uint8_t kind;
  Id8 dbId;
  int64_t clockMs;
  uint32_t feedHigh;
  uint8_t subs;
  bool hasCaps;
  uint16_t caps;
  uint16_t maxMsg;
  uint16_t bootId;
  Str16 version;
  Str20 name;
  Id8 groupId;
  Id8 nonce;
  bool hasProof;
  uint8_t proof[16];

  uint16_t capsValue() const { return hasCaps ? caps : 0; }
};

struct Pull {
  uint8_t reqId;
  uint32_t since;
  bool hasLimit;
  uint8_t limit;
  bool hasMaxBytes;
  uint16_t maxBytes;
  Id8 dbId;
  bool hasExclude;
  uint8_t exclude;

  uint8_t limitValue() const { return hasLimit ? limit : PULL_LIMIT_DEFAULT; }
  uint16_t maxBytesValue() const { return hasMaxBytes ? maxBytes : PULL_MAXBYTES_DEFAULT; }
  uint8_t excludeValue() const { return hasExclude ? exclude : 0; }
};

// REC: the envelope plus the record body bytes (tags 0x10..0x1F, collected in order). A body
// error does not fail the message: bodyStatus says whether the body is a valid record (§11.4).
struct Rec {
  uint32_t seq;
  uint8_t reqId;
  uint8_t seenByCount;
  Id8 seenBy[SEENBY_MAX];
  uint16_t bodyLen;  // collected length; > BODY_MAX means only the first BODY_MAX bytes are kept
  uint8_t body[BODY_MAX];
  Status bodyStatus;
  // The key for ERR{code, refType 0x03, key} when the body is rejected (§11.4): the 0x10 TLV of
  // the whole collected body, as bodyErrKey() would find it. Set by decodeMsg, so it is also
  // right for an oversize body, of which only the first BODY_MAX bytes are kept. Use recErrKey().
  bool hasErrKey;
  Key errKey;

  bool bodyOversize() const { return bodyLen > BODY_MAX; }
};

// The key to put in ERR{BAD_MSG or CLOCK, refType 0x03, key} for a decoded REC whose body was
// rejected (bodyStatus or the apply rule); false = send the ERR without a key.
inline bool recErrKey(const Rec& r, Key* out) {
  if (!r.hasErrKey) return false;
  *out = r.errKey;
  return true;
}

struct PageEnd {
  uint8_t reqId;
  uint32_t scannedTo;
  uint8_t more;
  uint32_t feedHigh;
  uint8_t count;
};

struct Evt {
  Id8 origin;
  uint32_t epoch;
  uint32_t seq;
  int64_t ts;
  Packet packet;
  bool hasRssi;
  int8_t rssi;
  bool hasCount;
  uint16_t count;
  bool hasLat;
  int32_t lat;
  bool hasLon;
  int32_t lon;
  bool hasAcc;
  uint16_t acc;
  bool hasAddr;
  uint8_t addr[6];
  bool hasFlags;
  uint8_t flags;
  uint8_t seenByCount;
  Id8 seenBy[SEENBY_MAX];

  uint16_t countValue() const { return hasCount ? count : 1; }
  uint8_t flagsValue() const { return hasFlags ? flags : 0; }
};

struct EvtSince {
  Id8 origin;
  uint32_t epoch;
  uint32_t afterSeq;
  Id8 requester;
};

struct EvtGap {
  Id8 origin;
  uint32_t epoch;
  uint32_t firstAvail;
  uint32_t lastAvail;
  uint32_t curEpoch;
  Id8 requester;
};

struct Hb {
  Id8 deviceId;
  uint8_t kind;
  uint16_t bootId;
  uint32_t hbSeq;
  int64_t ts;
  uint32_t uptimeS;
  bool hasBattPct;
  int8_t battPct;
  bool hasBattMv;
  int16_t battMv;
  bool hasCharging;
  int8_t charging;
  bool hasRuntimeMin;
  int16_t runtimeMin;
  Str16 version;
  Str20 name;
  uint8_t linkCount;
  HbLink links[HB_LINKS_MAX];
  bool hasState;
  uint16_t state;
  uint8_t hops;
  uint32_t feedHigh;
  Id8 dbId;
  uint32_t records;
  bool hasHubAirAgoS;
  uint16_t hubAirAgoS;
  uint8_t evtWmCount;
  EvtWm evtWm[HB_EVTWM_MAX];

  int8_t battPctValue() const { return hasBattPct ? battPct : (int8_t)-1; }
  int16_t battMvValue() const { return hasBattMv ? battMv : (int16_t)-1; }
  int8_t chargingValue() const { return hasCharging ? charging : (int8_t)-1; }
  int16_t runtimeMinValue() const { return hasRuntimeMin ? runtimeMin : (int16_t)-1; }
  uint16_t stateValue() const { return hasState ? state : 0; }
};

struct Sub {
  uint8_t subs;
};

struct Err {
  uint8_t code;
  bool hasRefType;
  uint8_t refType;
  bool hasKey;
  Key key;
  Str40 detail;
  bool hasDbId;
  Id8 dbId;
  bool hasRetryMs;
  uint16_t retryMs;

  uint16_t retryMsValue() const { return hasRetryMs ? retryMs : DEFAULT_RETRY_MS; }
};

struct Auth {
  uint8_t proof[16];
};

struct Join {
  Id8 groupId;
  uint8_t groupKey[16];
  bool hasFlags;
  uint8_t flags;

  uint8_t flagsValue() const { return hasFlags ? flags : 0; }
};

// Any message. `known` is false for an unknown type (ignored silently, §10 rule 2).
struct Msg {
  uint8_t type;
  bool known;
  union {
    Hello hello;
    Pull pull;
    Rec rec;
    PageEnd pageEnd;
    Evt evt;
    EvtSince evtSince;
    EvtGap evtGap;
    Hb hb;
    Sub sub;
    Err err;
    Auth auth;
    Join join;
  };
};

inline void clearMsg(Msg* m, uint8_t type) {
  memset(m, 0, sizeof(*m));
  m->type = type;
  m->known = type >= MSG_HELLO && type <= MSG_JOIN;
}

// ---- Field tables (one per message type) ----------------------------------------------------------
enum FieldKind : uint8_t {
  FK_U8,
  FK_U16,
  FK_U32,
  FK_I8,
  FK_I16,
  FK_I32,
  FK_I64,
  FK_BYTES,   // fixed size
  FK_STR,     // UTF-8, 1..size bytes; stored as Str<size>
  FK_PACKET,  // 3..29 bytes starting 83 01; stored as Packet
  FK_KEY,     // ns ‖ packet; stored as Key
  FK_LINK,    // HB link, 10 bytes; stored as HbLink
  FK_EVTWM    // HB evtWm, 16 bytes; stored as EvtWm
};

static const uint16_t NO_PRES = 0xFFFF;

struct FieldSpec {
  uint8_t tag;
  uint8_t kind;   // FieldKind
  uint8_t size;   // FK_BYTES exact size, FK_STR max bytes
  uint8_t rep;    // 0 = not repeatable, else the maximum count
  bool mand;
  bool hasDef;
  int64_t lo, hi, def;
  uint16_t off;   // offset of the value (array) in the message struct
  uint16_t pres;  // offset of the bool has* (optional) or uint8_t count (repeatable); NO_PRES
  const char* name;
};

struct MsgSpec {
  uint8_t type;
  const char* name;
  const FieldSpec* fields;
  uint8_t count;
};

inline bool fieldIsInt(uint8_t kind) { return kind <= FK_I64; }

inline uint8_t fieldIntWidth(uint8_t kind) {
  switch (kind) {
    case FK_U8:
    case FK_I8:
      return 1;
    case FK_U16:
    case FK_I16:
      return 2;
    case FK_U32:
    case FK_I32:
      return 4;
    default:
      return 8;
  }
}

inline bool fieldIntSigned(uint8_t kind) {
  return kind == FK_I8 || kind == FK_I16 || kind == FK_I32 || kind == FK_I64;
}

// Storage size of one element in the struct.
inline size_t fieldElemSize(const FieldSpec& f) {
  switch (f.kind) {
    case FK_BYTES:
      return f.size;
    case FK_STR:
      return 1 + (size_t)f.size;
    case FK_PACKET:
      return sizeof(Packet);
    case FK_KEY:
      return sizeof(Key);
    case FK_LINK:
      return sizeof(HbLink);
    case FK_EVTWM:
      return sizeof(EvtWm);
    default:
      return fieldIntWidth(f.kind);
  }
}

#define MMSYNC_I64_MAX 9223372036854775807LL
// mandatory scalar / optional scalar (has flag) / optional with default / optional string /
// repeatable (count field)
#define MMSYNC_M(T, tag, kind, size, lo, hi, mem, name) \
  {tag, kind, size, 0, true, false, lo, hi, 0, (uint16_t)offsetof(T, mem), NO_PRES, name}
#define MMSYNC_O(T, tag, kind, size, lo, hi, mem, has, name) \
  {tag, kind, size, 0, false, false, lo, hi, 0, (uint16_t)offsetof(T, mem), (uint16_t)offsetof(T, has), name}
#define MMSYNC_D(T, tag, kind, lo, hi, def, mem, has, name) \
  {tag, kind, 0, 0, false, true, lo, hi, def, (uint16_t)offsetof(T, mem), (uint16_t)offsetof(T, has), name}
#define MMSYNC_S(T, tag, size, mem, name) \
  {tag, FK_STR, size, 0, false, false, 0, 0, 0, (uint16_t)offsetof(T, mem), NO_PRES, name}
#define MMSYNC_R(T, tag, kind, size, rep, mem, cnt, name) \
  {tag, kind, size, rep, false, false, 0, 0, 0, (uint16_t)offsetof(T, mem), (uint16_t)offsetof(T, cnt), name}

inline const MsgSpec* msgSpec(uint8_t type) {
  static const FieldSpec hello[] = {
      MMSYNC_M(Hello, 0x01, FK_U8, 0, 0, 255, proto, "proto"),
      MMSYNC_M(Hello, 0x02, FK_BYTES, 8, 0, 0, deviceId, "deviceId"),
      MMSYNC_M(Hello, 0x03, FK_U8, 0, 1, 3, kind, "kind"),
      MMSYNC_M(Hello, 0x04, FK_BYTES, 8, 0, 0, dbId, "dbId"),
      MMSYNC_M(Hello, 0x05, FK_I64, 0, 0, MMSYNC_I64_MAX, clockMs, "clockMs"),
      MMSYNC_M(Hello, 0x06, FK_U32, 0, 0, 4294967295LL, feedHigh, "feedHigh"),
      MMSYNC_M(Hello, 0x07, FK_U8, 0, 0, 255, subs, "subs"),
      MMSYNC_D(Hello, 0x08, FK_U16, 0, 65535, 0, caps, hasCaps, "caps"),
      MMSYNC_M(Hello, 0x09, FK_U16, 0, MAXMSG_MIN, 65535, maxMsg, "maxMsg"),
      MMSYNC_M(Hello, 0x0A, FK_U16, 0, 0, 65535, bootId, "bootId"),
      MMSYNC_S(Hello, 0x0B, 16, version, "version"),
      MMSYNC_S(Hello, 0x0C, 20, name, "name"),
      MMSYNC_M(Hello, 0x0D, FK_BYTES, 8, 0, 0, groupId, "groupId"),
      MMSYNC_M(Hello, 0x0E, FK_BYTES, 8, 0, 0, nonce, "nonce"),
      MMSYNC_O(Hello, 0x0F, FK_BYTES, 16, 0, 0, proof, hasProof, "proof"),
  };
  static const FieldSpec pull[] = {
      MMSYNC_M(Pull, 0x01, FK_U8, 0, 1, 255, reqId, "reqId"),
      MMSYNC_M(Pull, 0x02, FK_U32, 0, 0, 4294967295LL, since, "since"),
      MMSYNC_D(Pull, 0x03, FK_U8, 1, 32, PULL_LIMIT_DEFAULT, limit, hasLimit, "limit"),
      MMSYNC_D(Pull, 0x04, FK_U16, PULL_MAXBYTES_MIN, 1536, PULL_MAXBYTES_DEFAULT, maxBytes, hasMaxBytes,
               "maxBytes"),
      MMSYNC_M(Pull, 0x05, FK_BYTES, 8, 0, 0, dbId, "dbId"),
      MMSYNC_D(Pull, 0x06, FK_U8, 0, 1, 0, exclude, hasExclude, "exclude"),
  };
  static const FieldSpec rec[] = {
      MMSYNC_M(Rec, 0x01, FK_U32, 0, 0, 4294967295LL, seq, "seq"),
      MMSYNC_M(Rec, 0x02, FK_U8, 0, 0, 255, reqId, "reqId"),
      MMSYNC_R(Rec, 0x03, FK_BYTES, 8, SEENBY_MAX, seenBy, seenByCount, "seenBy"),
  };
  static const FieldSpec pageEnd[] = {
      MMSYNC_M(PageEnd, 0x01, FK_U8, 0, 1, 255, reqId, "reqId"),
      MMSYNC_M(PageEnd, 0x02, FK_U32, 0, 0, 4294967295LL, scannedTo, "scannedTo"),
      MMSYNC_M(PageEnd, 0x03, FK_U8, 0, 0, 1, more, "more"),
      MMSYNC_M(PageEnd, 0x04, FK_U32, 0, 0, 4294967295LL, feedHigh, "feedHigh"),
      MMSYNC_M(PageEnd, 0x05, FK_U8, 0, 0, 255, count, "count"),
  };
  static const FieldSpec evt[] = {
      MMSYNC_M(Evt, 0x01, FK_BYTES, 8, 0, 0, origin, "origin"),
      MMSYNC_M(Evt, 0x02, FK_U32, 0, 1, 4294967295LL, epoch, "epoch"),
      MMSYNC_M(Evt, 0x03, FK_U32, 0, 1, 4294967295LL, seq, "seq"),
      MMSYNC_M(Evt, 0x04, FK_I64, 0, 0, MMSYNC_I64_MAX, ts, "ts"),
      MMSYNC_M(Evt, 0x05, FK_PACKET, 0, 0, 0, packet, "packet"),
      MMSYNC_O(Evt, 0x06, FK_I8, 0, -128, 127, rssi, hasRssi, "rssi"),
      MMSYNC_D(Evt, 0x07, FK_U16, 1, 65535, 1, count, hasCount, "count"),
      MMSYNC_O(Evt, 0x08, FK_I32, 0, -900000000LL, 900000000LL, lat, hasLat, "lat"),
      MMSYNC_O(Evt, 0x09, FK_I32, 0, -1800000000LL, 1800000000LL, lon, hasLon, "lon"),
      MMSYNC_O(Evt, 0x0A, FK_U16, 0, 0, 65535, acc, hasAcc, "acc"),
      MMSYNC_O(Evt, 0x0B, FK_BYTES, 6, 0, 0, addr, hasAddr, "addr"),
      MMSYNC_D(Evt, 0x0C, FK_U8, 0, 255, 0, flags, hasFlags, "flags"),
      MMSYNC_R(Evt, 0x0D, FK_BYTES, 8, SEENBY_MAX, seenBy, seenByCount, "seenBy"),
  };
  static const FieldSpec evtSince[] = {
      MMSYNC_M(EvtSince, 0x01, FK_BYTES, 8, 0, 0, origin, "origin"),
      MMSYNC_M(EvtSince, 0x02, FK_U32, 0, 0, 4294967295LL, epoch, "epoch"),
      MMSYNC_M(EvtSince, 0x03, FK_U32, 0, 0, 4294967295LL, afterSeq, "afterSeq"),
      MMSYNC_M(EvtSince, 0x04, FK_BYTES, 8, 0, 0, requester, "requester"),
  };
  static const FieldSpec evtGap[] = {
      MMSYNC_M(EvtGap, 0x01, FK_BYTES, 8, 0, 0, origin, "origin"),
      MMSYNC_M(EvtGap, 0x02, FK_U32, 0, 0, 4294967295LL, epoch, "epoch"),
      MMSYNC_M(EvtGap, 0x03, FK_U32, 0, 0, 4294967295LL, firstAvail, "firstAvail"),
      MMSYNC_M(EvtGap, 0x04, FK_U32, 0, 0, 4294967295LL, lastAvail, "lastAvail"),
      MMSYNC_M(EvtGap, 0x05, FK_U32, 0, 0, 4294967295LL, curEpoch, "curEpoch"),
      MMSYNC_M(EvtGap, 0x06, FK_BYTES, 8, 0, 0, requester, "requester"),
  };
  static const FieldSpec hb[] = {
      MMSYNC_M(Hb, 0x01, FK_BYTES, 8, 0, 0, deviceId, "deviceId"),
      MMSYNC_M(Hb, 0x02, FK_U8, 0, 1, 3, kind, "kind"),
      MMSYNC_M(Hb, 0x03, FK_U16, 0, 0, 65535, bootId, "bootId"),
      MMSYNC_M(Hb, 0x04, FK_U32, 0, 0, 4294967295LL, hbSeq, "hbSeq"),
      MMSYNC_M(Hb, 0x05, FK_I64, 0, 0, MMSYNC_I64_MAX, ts, "ts"),
      MMSYNC_M(Hb, 0x06, FK_U32, 0, 0, 4294967295LL, uptimeS, "uptimeS"),
      MMSYNC_D(Hb, 0x07, FK_I8, -1, 100, -1, battPct, hasBattPct, "battPct"),
      MMSYNC_D(Hb, 0x08, FK_I16, -1, 32767, -1, battMv, hasBattMv, "battMv"),
      MMSYNC_D(Hb, 0x09, FK_I8, -1, 1, -1, charging, hasCharging, "charging"),
      MMSYNC_D(Hb, 0x0A, FK_I16, -1, 5999, -1, runtimeMin, hasRuntimeMin, "runtimeMin"),
      MMSYNC_S(Hb, 0x0B, 16, version, "version"),
      MMSYNC_S(Hb, 0x0C, 20, name, "name"),
      MMSYNC_R(Hb, 0x0D, FK_LINK, 10, HB_LINKS_MAX, links, linkCount, "link"),
      MMSYNC_D(Hb, 0x0E, FK_U16, 0, 65535, 0, state, hasState, "state"),
      MMSYNC_M(Hb, 0x0F, FK_U8, 0, 0, 1, hops, "hops"),
      MMSYNC_M(Hb, 0x10, FK_U32, 0, 0, 4294967295LL, feedHigh, "feedHigh"),
      MMSYNC_M(Hb, 0x11, FK_BYTES, 8, 0, 0, dbId, "dbId"),
      MMSYNC_M(Hb, 0x12, FK_U32, 0, 0, 4294967295LL, records, "records"),
      MMSYNC_O(Hb, 0x13, FK_U16, 0, 0, 65535, hubAirAgoS, hasHubAirAgoS, "hubAirAgoS"),
      MMSYNC_R(Hb, 0x14, FK_EVTWM, 16, HB_EVTWM_MAX, evtWm, evtWmCount, "evtWm"),
  };
  static const FieldSpec sub[] = {
      MMSYNC_M(Sub, 0x01, FK_U8, 0, 0, 255, subs, "subs"),
  };
  static const FieldSpec err[] = {
      MMSYNC_M(Err, 0x01, FK_U8, 0, 1, 255, code, "code"),
      MMSYNC_O(Err, 0x02, FK_U8, 0, 0, 255, refType, hasRefType, "refType"),
      MMSYNC_O(Err, 0x03, FK_KEY, 0, 0, 0, key, hasKey, "key"),
      MMSYNC_S(Err, 0x04, 40, detail, "detail"),
      MMSYNC_O(Err, 0x05, FK_BYTES, 8, 0, 0, dbId, hasDbId, "dbId"),
      MMSYNC_O(Err, 0x06, FK_U16, 0, 0, 65535, retryMs, hasRetryMs, "retryMs"),
  };
  static const FieldSpec auth[] = {
      MMSYNC_M(Auth, 0x01, FK_BYTES, 16, 0, 0, proof, "proof"),
  };
  static const FieldSpec join[] = {
      MMSYNC_M(Join, 0x01, FK_BYTES, 8, 0, 0, groupId, "groupId"),
      MMSYNC_M(Join, 0x02, FK_BYTES, 16, 0, 0, groupKey, "groupKey"),
      MMSYNC_D(Join, 0x03, FK_U8, 0, 255, 0, flags, hasFlags, "flags"),
  };
#define MMSYNC_N(a) (uint8_t)(sizeof(a) / sizeof((a)[0]))
  static const MsgSpec specs[] = {
      {MSG_HELLO, "HELLO", hello, MMSYNC_N(hello)},
      {MSG_PULL, "PULL", pull, MMSYNC_N(pull)},
      {MSG_REC, "REC", rec, MMSYNC_N(rec)},
      {MSG_PAGE_END, "PAGE_END", pageEnd, MMSYNC_N(pageEnd)},
      {MSG_EVT, "EVT", evt, MMSYNC_N(evt)},
      {MSG_EVT_SINCE, "EVT_SINCE", evtSince, MMSYNC_N(evtSince)},
      {MSG_EVT_GAP, "EVT_GAP", evtGap, MMSYNC_N(evtGap)},
      {MSG_HB, "HB", hb, MMSYNC_N(hb)},
      {MSG_SUB, "SUB", sub, MMSYNC_N(sub)},
      {MSG_ERR, "ERR", err, MMSYNC_N(err)},
      {MSG_AUTH, "AUTH", auth, MMSYNC_N(auth)},
      {MSG_JOIN, "JOIN", join, MMSYNC_N(join)},
  };
#undef MMSYNC_N
  return (type >= MSG_HELLO && type <= MSG_JOIN) ? &specs[type - 1] : NULL;
}

#undef MMSYNC_M
#undef MMSYNC_O
#undef MMSYNC_D
#undef MMSYNC_S
#undef MMSYNC_R
#undef MMSYNC_I64_MAX

inline const FieldSpec* findField(const MsgSpec* sp, uint8_t tag) {
  for (uint8_t i = 0; i < sp->count; i++)
    if (sp->fields[i].tag == tag) return &sp->fields[i];
  return NULL;
}

// Native integer at a struct offset.
inline int64_t loadFieldInt(const FieldSpec& f, const uint8_t* at) {
  switch (f.kind) {
    case FK_U8: {
      uint8_t v;
      memcpy(&v, at, 1);
      return v;
    }
    case FK_U16: {
      uint16_t v;
      memcpy(&v, at, 2);
      return v;
    }
    case FK_U32: {
      uint32_t v;
      memcpy(&v, at, 4);
      return v;
    }
    case FK_I8: {
      int8_t v;
      memcpy(&v, at, 1);
      return v;
    }
    case FK_I16: {
      int16_t v;
      memcpy(&v, at, 2);
      return v;
    }
    case FK_I32: {
      int32_t v;
      memcpy(&v, at, 4);
      return v;
    }
    default: {
      int64_t v;
      memcpy(&v, at, 8);
      return v;
    }
  }
}

inline void storeFieldInt(const FieldSpec& f, uint8_t* at, int64_t x) {
  switch (f.kind) {
    case FK_U8: {
      const uint8_t v = (uint8_t)x;
      memcpy(at, &v, 1);
      break;
    }
    case FK_U16: {
      const uint16_t v = (uint16_t)x;
      memcpy(at, &v, 2);
      break;
    }
    case FK_U32: {
      const uint32_t v = (uint32_t)x;
      memcpy(at, &v, 4);
      break;
    }
    case FK_I8: {
      const int8_t v = (int8_t)x;
      memcpy(at, &v, 1);
      break;
    }
    case FK_I16: {
      const int16_t v = (int16_t)x;
      memcpy(at, &v, 2);
      break;
    }
    case FK_I32: {
      const int32_t v = (int32_t)x;
      memcpy(at, &v, 4);
      break;
    }
    default:
      memcpy(at, &x, 8);
      break;
  }
}

// Decodes and range-checks one TLV value into its struct storage at dst.
inline Status decodeFieldValue(const FieldSpec& f, const uint8_t* v, uint8_t ln, uint8_t* dst) {
  if (fieldIsInt(f.kind)) {
    const uint8_t w = fieldIntWidth(f.kind);
    if (ln != w) return badMsg("length");
    const int64_t x = fieldIntSigned(f.kind) ? getLEs(v, w) : (int64_t)getLE(v, w);
    if (x < f.lo || x > f.hi) return badMsg("range");
    storeFieldInt(f, dst, x);
    return statusOk();
  }
  switch (f.kind) {
    case FK_BYTES:
      if (ln != f.size) return badMsg("length");
      memcpy(dst, v, ln);
      return statusOk();
    case FK_STR:
      if (ln < 1 || ln > f.size) return badMsg("length");
      if (!utf8Valid(v, ln)) return badMsg("utf8");
      dst[0] = ln;
      memcpy(dst + 1, v, ln);
      return statusOk();
    case FK_PACKET: {
      if (ln < PACKET_MIN || ln > PACKET_MAX) return badMsg("length");
      Status s = checkPacket(v, ln);
      if (!s.ok()) return s;
      Packet p;
      memset(&p, 0, sizeof(p));
      p.len = ln;
      memcpy(p.b, v, ln);
      memcpy(dst, &p, sizeof(p));
      return statusOk();
    }
    case FK_KEY: {
      Key k;
      Status s = decodeKey(v, ln, &k);
      if (!s.ok()) return s;
      memcpy(dst, &k, sizeof(k));
      return statusOk();
    }
    case FK_LINK: {
      if (ln != 10) return badMsg("length");
      if (v[8] < 1 || v[8] > 3) return badMsg("range");
      HbLink l;
      l.peerId = makeId8(v);
      l.peerKind = v[8];
      l.flags = v[9];
      memcpy(dst, &l, sizeof(l));
      return statusOk();
    }
    default: {  // FK_EVTWM
      if (ln != 16) return badMsg("length");
      EvtWm e;
      e.origin = makeId8(v);
      e.epoch = (uint32_t)getLE(v + 8, 4);
      e.seq = (uint32_t)getLE(v + 12, 4);
      memcpy(dst, &e, sizeof(e));
      return statusOk();
    }
  }
}

// Writes one element as a TLV.
inline void encodeFieldValue(const FieldSpec& f, const uint8_t* at, Writer& w) {
  if (fieldIsInt(f.kind)) {
    w.tlvInt(f.tag, (uint64_t)loadFieldInt(f, at), fieldIntWidth(f.kind));
    return;
  }
  switch (f.kind) {
    case FK_BYTES:
      w.tlv(f.tag, at, f.size);
      return;
    case FK_STR:
      if (at[0] < 1 || at[0] > f.size) {
        w.failed = true;
        return;
      }
      w.tlv(f.tag, at + 1, at[0]);
      return;
    case FK_PACKET: {
      Packet p;
      memcpy(&p, at, sizeof(p));
      if (p.len < PACKET_MIN || p.len > PACKET_MAX) {
        w.failed = true;
        return;
      }
      w.tlv(f.tag, p.b, p.len);
      return;
    }
    case FK_KEY: {
      Key k;
      memcpy(&k, at, sizeof(k));
      if (k.len < PACKET_MIN || k.len > PACKET_MAX) {
        w.failed = true;
        return;
      }
      uint8_t b[1 + PACKET_MAX];
      w.tlv(f.tag, b, encodeKey(k, b));
      return;
    }
    case FK_LINK: {
      HbLink l;
      memcpy(&l, at, sizeof(l));
      uint8_t b[10];
      memcpy(b, l.peerId.b, 8);
      b[8] = l.peerKind;
      b[9] = l.flags;
      w.tlv(f.tag, b, 10);
      return;
    }
    default: {  // FK_EVTWM
      EvtWm e;
      memcpy(&e, at, sizeof(e));
      uint8_t b[16];
      memcpy(b, e.origin.b, 8);
      putLE(b + 8, e.epoch, 4);
      putLE(b + 12, e.seq, 4);
      w.tlv(f.tag, b, 16);
      return;
    }
  }
}

// Is the (non-repeatable) field present in the struct?
inline bool fieldPresent(const FieldSpec& f, const uint8_t* base) {
  if (f.mand) return true;
  if (f.kind == FK_STR) return base[f.off] != 0;
  return base[f.pres] != 0;
}

inline uint8_t* msgBase(Msg* m) { return reinterpret_cast<uint8_t*>(&m->hello); }
inline const uint8_t* msgBase(const Msg* m) { return reinterpret_cast<const uint8_t*>(&m->hello); }

// bytes -> Msg (§10). Unknown type: ok with m->known == false (the caller ignores it). REC: the
// envelope must be valid; the body's own status is in m->rec.bodyStatus (§11.4).
inline Status decodeMsg(const uint8_t* d, size_t n, Msg* m) {
  clearMsg(m, n ? d[0] : 0);
  if (n < 1) {
    m->known = false;
    return badMsg("empty");
  }
  const MsgSpec* sp = msgSpec(d[0]);
  if (!sp) return statusOk();
  if (!tlvFramingOk(d, n, 1)) return badMsg("truncated");
  uint8_t* base = msgBase(m);
  const bool isRec = d[0] == MSG_REC;
  uint32_t seen = 0;  // known tags seen (all known tags are < 32)
  int prev = -1;
  size_t bodyLen = 0;
  bool errKeyDone = false;  // a 0x10 TLV failed to decode: later ones do not count (bodyErrKey)
  for (size_t i = 1; i < n;) {
    const uint8_t tag = d[i];
    const uint8_t ln = d[i + 1];
    const uint8_t* v = d + i + 2;
    i += 2 + (size_t)ln;
    if (isRec && tag >= 0x10 && tag <= 0x1F) {  // record body: collected verbatim, in order
      const size_t raw = 2 + (size_t)ln;
      if (bodyLen + raw <= BODY_MAX) {
        memcpy(m->rec.body + bodyLen, v - 2, raw);
      } else if (bodyLen < BODY_MAX) {
        memcpy(m->rec.body + bodyLen, v - 2, BODY_MAX - bodyLen);
      }
      bodyLen += raw;
      if (tag == T_KEY && !errKeyDone) {
        Key k;
        if (decodeKey(v, ln, &k).ok()) {
          m->rec.errKey = k;
          m->rec.hasErrKey = true;
        } else {
          errKeyDone = true;
        }
      }
      continue;
    }
    const FieldSpec* f = findField(sp, tag);
    if ((int)tag < prev) return badMsg("order");
    if ((int)tag == prev && f && !f->rep) return badMsg("duplicate");
    prev = tag;
    if (!f) continue;  // unknown tag: skipped (it still took part in the order rule)
    if (f->rep) {
      uint8_t* cnt = base + f->pres;
      if (*cnt >= f->rep) {
        uint8_t scratch[32];
        Status s = decodeFieldValue(*f, v, ln, scratch);
        if (!s.ok()) return s;
        return badMsg("count");
      }
      Status s = decodeFieldValue(*f, v, ln, base + f->off + (size_t)(*cnt) * fieldElemSize(*f));
      if (!s.ok()) return s;
      (*cnt)++;
    } else {
      Status s = decodeFieldValue(*f, v, ln, base + f->off);
      if (!s.ok()) return s;
      if (f->pres != NO_PRES) base[f->pres] = 1;
    }
    seen |= (uint32_t)1u << tag;
  }
  for (uint8_t k = 0; k < sp->count; k++) {
    const FieldSpec& f = sp->fields[k];
    if (f.mand && !(seen & ((uint32_t)1u << f.tag))) return badMsg("missing");
  }
  if (isRec) {
    Rec& r = m->rec;
    if (r.reqId != 0 && r.seenByCount > 0) return badMsg("seenby_on_page");
    r.bodyLen = (uint16_t)(bodyLen > 0xFFFF ? 0xFFFF : bodyLen);
    if (bodyLen > BODY_MAX) {
      r.bodyStatus = badMsg("oversize");
    } else {
      r.bodyStatus = decodeBody(r.body, bodyLen, NULL, NULL);
    }
  } else if (d[0] == MSG_EVT) {
    const Evt& e = m->evt;
    const int fix = (int)e.hasLat + (int)e.hasLon + (int)e.hasAcc;
    if (fix != 0 && fix != 3) return badMsg("fix");
  } else if (d[0] == MSG_JOIN) {
    if (isZero(m->join.groupId)) return badMsg("range");
  }
  return statusOk();
}

// Canonical encoding of the message struct at `fields` for `type` (§10): tags ascending,
// repeatable tags consecutive, optional fields omitted when absent or equal to their default; a
// REC's body bytes verbatim after the envelope. Returns the length, 0 on overflow / invalid.
inline size_t encodeFields(uint8_t type, const void* fields, uint8_t* out, size_t cap) {
  const MsgSpec* sp = msgSpec(type);
  if (!sp) return 0;
  const uint8_t* base = static_cast<const uint8_t*>(fields);
  Writer w(out, cap);
  w.put(type);
  for (uint8_t k = 0; k < sp->count; k++) {
    const FieldSpec& f = sp->fields[k];
    if (f.rep) {
      const uint8_t cnt = base[f.pres];
      if (cnt > f.rep) return 0;
      for (uint8_t j = 0; j < cnt; j++)
        encodeFieldValue(f, base + f.off + (size_t)j * fieldElemSize(f), w);
      continue;
    }
    if (!fieldPresent(f, base)) continue;
    if (!f.mand && f.hasDef && loadFieldInt(f, base + f.off) == f.def) continue;
    encodeFieldValue(f, base + f.off, w);
  }
  if (type == MSG_REC) {
    const Rec* r = static_cast<const Rec*>(fields);
    if (r->bodyLen > BODY_MAX) return 0;
    w.put(r->body, r->bodyLen);
  }
  return w.failed ? 0 : w.len;
}

inline size_t encodeMsg(const Msg& m, uint8_t* out, size_t cap) {
  return encodeFields(m.type, msgBase(&m), out, cap);
}

inline size_t encode(const Hello& v, uint8_t* o, size_t c) { return encodeFields(MSG_HELLO, &v, o, c); }
inline size_t encode(const Pull& v, uint8_t* o, size_t c) { return encodeFields(MSG_PULL, &v, o, c); }
inline size_t encode(const Rec& v, uint8_t* o, size_t c) { return encodeFields(MSG_REC, &v, o, c); }
inline size_t encode(const PageEnd& v, uint8_t* o, size_t c) {
  return encodeFields(MSG_PAGE_END, &v, o, c);
}
inline size_t encode(const Evt& v, uint8_t* o, size_t c) { return encodeFields(MSG_EVT, &v, o, c); }
inline size_t encode(const EvtSince& v, uint8_t* o, size_t c) {
  return encodeFields(MSG_EVT_SINCE, &v, o, c);
}
inline size_t encode(const EvtGap& v, uint8_t* o, size_t c) {
  return encodeFields(MSG_EVT_GAP, &v, o, c);
}
inline size_t encode(const Hb& v, uint8_t* o, size_t c) { return encodeFields(MSG_HB, &v, o, c); }
inline size_t encode(const Sub& v, uint8_t* o, size_t c) { return encodeFields(MSG_SUB, &v, o, c); }
inline size_t encode(const Err& v, uint8_t* o, size_t c) { return encodeFields(MSG_ERR, &v, o, c); }
inline size_t encode(const Auth& v, uint8_t* o, size_t c) { return encodeFields(MSG_AUTH, &v, o, c); }
inline size_t encode(const Join& v, uint8_t* o, size_t c) { return encodeFields(MSG_JOIN, &v, o, c); }

// Copies a byte string into a Str (len 0 = absent when n == 0). False when it does not fit.
template <size_t N>
inline bool setStr(Str<N>* s, const uint8_t* p, size_t n) {
  if (n > N) {
    s->len = 0;
    return false;
  }
  s->len = (uint8_t)n;
  if (n) memcpy(s->b, p, n);
  return true;
}

template <size_t N>
inline bool setStr(Str<N>* s, const char* z) {
  return setStr(s, reinterpret_cast<const uint8_t*>(z ? z : ""), z ? strlen(z) : 0);
}

// HB forwarding (§16.4): a forwarder changes only the value byte of TLV 0x0F (hops), in place, so
// unknown tags survive. False when the message does not frame or has no 1-byte hops TLV.
inline bool hbSetHops(uint8_t* msg, size_t n, uint8_t hops) {
  if (n < 1 || !tlvFramingOk(msg, n, 1)) return false;
  for (size_t i = 1; i < n;) {
    const uint8_t tag = msg[i];
    const uint8_t ln = msg[i + 1];
    if (tag == 0x0F) {
      if (ln != 1) return false;
      msg[i + 2] = hops;
      return true;
    }
    i += 2 + (size_t)ln;
  }
  return false;
}

// ---- Frames (§9) -----------------------------------------------------------------------------------
static const uint8_t FR_START = 0x20;
static const uint8_t FR_END = 0x10;

// chunk = MTU - 3 (ATT) - 2 (frame header); the MTU is clamped to 23..517.
inline size_t chunkSize(uint16_t mtu) {
  if (mtu < MTU_MIN) mtu = MTU_MIN;
  if (mtu > MTU_MAX) mtu = MTU_MAX;
  return (size_t)mtu - ATT_OVERHEAD - FRAME_HEADER_LEN;
}

inline size_t frameCount(size_t msgLen, uint16_t mtu) {
  const size_t c = chunkSize(mtu);
  return (msgLen + c - 1) / c;
}

// One per link direction, reset at link-up. counter: the 4-bit message counter; seq: the 8-bit
// frame seq; both 0 for the first message / frame after link-up.
class Fragmenter {
 public:
  uint8_t counter;
  uint8_t seq;

  Fragmenter() : counter(0), seq(0) {}
  void reset(uint8_t startCounter = 0, uint8_t startSeq = 0) {
    counter = (uint8_t)(startCounter & 0x0F);
    seq = startSeq;
  }

  // Writes the frame of msg[0..len) that starts at *offset (0 for a new message) into out
  // (capacity >= chunkSize(mtu) + 2), advances *offset and returns the frame length; 0 when the
  // message is complete (or empty). The counter steps after the last frame.
  size_t next(const uint8_t* msg, size_t len, size_t* offset, uint16_t mtu, uint8_t* out) {
    if (len == 0 || *offset >= len) return 0;
    const size_t c = chunkSize(mtu);
    const size_t take = (len - *offset) < c ? (len - *offset) : c;
    uint8_t b0 = (uint8_t)((FRAME_VERSION << 6) | counter);
    if (*offset == 0) b0 |= FR_START;
    const bool last = *offset + take == len;
    if (last) b0 |= FR_END;
    out[0] = b0;
    out[1] = seq;
    memcpy(out + 2, msg + *offset, take);
    seq = (uint8_t)(seq + 1);
    *offset += take;
    if (last) counter = (uint8_t)((counter + 1) & 0x0F);
    return take + 2;
  }

  // Fragments a whole message, calling emit(frame, frameLen) per frame. Returns the frame count.
  template <class F>
  size_t fragment(const uint8_t* msg, size_t len, uint16_t mtu, F emit) {
    uint8_t frame[MTU_MAX];
    size_t off = 0, n = 0, fl;
    while ((fl = next(msg, len, &off, mtu, frame)) != 0) {
      emit(static_cast<const uint8_t*>(frame), fl);
      n++;
    }
    return n;
  }
};

enum ReasmKind : uint8_t { RA_DELIVER = 1, RA_BAD_FRAME, RA_ERR_TOO_BIG, RA_ERR_PROTO };
enum BadFrameReason : uint8_t { BF_SHORT = 1, BF_GAP, BF_COUNTER, BF_RESTART, BF_ORPHAN };

inline const char* badFrameName(uint8_t r) {
  static const char* const names[] = {"?", "short", "gap", "counter", "restart", "orphan"};
  return r <= BF_ORPHAN ? names[r] : "?";
}

struct ReasmEvent {
  uint8_t kind;   // ReasmKind
  uint8_t value;  // BAD_FRAME: BadFrameReason; TOO_BIG: refType; PROTO: frame version
};

// What one frame produced (at most two events, in order). For RA_DELIVER the message is
// msg[0..msgLen), valid until the next feed().
struct ReasmResult {
  uint8_t n;
  ReasmEvent ev[2];
  const uint8_t* msg;
  size_t msgLen;
};

// One per link direction (§9.3). CAP = the largest maxMsg it may be configured for.
template <size_t CAP>
class Reassembler {
 public:
  uint8_t expected;  // next frame seq

  explicit Reassembler(uint16_t maxMsg = (uint16_t)CAP) { reset(maxMsg); }

  void reset(uint16_t maxMsg) {
    maxMsg_ = maxMsg > CAP ? (uint16_t)CAP : maxMsg;
    expected = 0;
    len_ = 0;
    open_ = false;
    counter_ = 0;
    skip_ = false;
    protoSent_ = false;
  }

  ReasmResult feed(const uint8_t* f, size_t n) {
    ReasmResult r;
    r.n = 0;
    r.msg = NULL;
    r.msgLen = 0;
    if (n < FRAME_HEADER_LEN + 1) {
      add(&r, RA_BAD_FRAME, BF_SHORT);
      return r;
    }
    const uint8_t ver = (uint8_t)(f[0] >> 6);
    if (ver != FRAME_VERSION) {  // dropped without touching any state
      if (!protoSent_) {
        protoSent_ = true;
        add(&r, RA_ERR_PROTO, ver);
      }
      return r;
    }
    const bool start = (f[0] & FR_START) != 0;
    const bool end = (f[0] & FR_END) != 0;
    const uint8_t ctr = (uint8_t)(f[0] & 0x0F);
    const uint8_t fseq = f[1];
    const uint8_t* chunk = f + 2;
    const size_t clen = n - 2;
    if (fseq != expected) {
      add(&r, RA_BAD_FRAME, BF_GAP);
      open_ = false;
      len_ = 0;
      skip_ = true;
    }
    expected = (uint8_t)(fseq + 1);
    if (start) {
      if (open_) add(&r, RA_BAD_FRAME, BF_RESTART);
      open_ = true;
      len_ = 0;
      counter_ = ctr;
      skip_ = false;
    } else {
      if (!open_) {
        if (!skip_) add(&r, RA_BAD_FRAME, BF_ORPHAN);
        return r;
      }
      if (ctr != counter_) {
        add(&r, RA_BAD_FRAME, BF_COUNTER);
        open_ = false;
        len_ = 0;
        skip_ = true;
        return r;
      }
    }
    if (len_ + clen > maxMsg_) {
      add(&r, RA_ERR_TOO_BIG, len_ ? buf_[0] : chunk[0]);
      open_ = false;
      len_ = 0;
      skip_ = true;
      return r;
    }
    memcpy(buf_ + len_, chunk, clen);
    len_ += clen;
    if (end) {
      add(&r, RA_DELIVER, 0);
      r.msg = buf_;
      r.msgLen = len_;
      open_ = false;
      len_ = 0;
    }
    return r;
  }

 private:
  static void add(ReasmResult* r, uint8_t kind, uint8_t value) {
    if (r->n < 2) {
      r->ev[r->n].kind = kind;
      r->ev[r->n].value = value;
      r->n++;
    }
  }

  uint8_t buf_[CAP];
  size_t len_;
  bool open_;
  uint8_t counter_;
  bool skip_;
  bool protoSent_;
  uint16_t maxMsg_;
};

}  // namespace mmsync
