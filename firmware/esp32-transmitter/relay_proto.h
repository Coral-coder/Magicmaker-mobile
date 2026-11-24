// MagicMaker relay protocol, ESP32 side: commands, packets and the STATUS object.
//
// Pure C++ (stdint / string / stdio / ctype only, no Arduino), so the same file also builds on a
// desktop for tests. It mirrors the Android relay (RelayCommands.kt, HexUtils.canonicalHex,
// MbleBeaconBuilder): same action names and aliases, same defaults and clamps. Where the chip
// does not do what Android does (it never scans, keeps no library and no auto rules) it says so
// with ok:false,"error":"unsupported" instead of pretending.
//
// Nothing here touches hardware or shared state: the NimBLE callbacks call the parsers, loop()
// owns what they produce (relay_engine.h).
#pragma once

#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// ---- Wire limits (the relay contract; Android RelayCommands / TransmitTiming / HexUtils) ------
static const uint8_t  RELAY_PACKET_MIN      = 3;      // company id 83 01 + at least one payload byte
static const uint8_t  RELAY_PACKET_MAX      = 29;     // 83 01 + 27 payload bytes (one legacy advert)
static const uint8_t  RELAY_KEEP_MIN        = 4;      // a shorter keep-awake hex keeps the stored one
static const uint8_t  RELAY_LABEL_MAX       = 16;     // loop labels: printable ASCII
static const uint16_t RELAY_TXCHAR_MIN_MS   = 60;     // TX characteristic "{hex}|{ms}": ms clamp
static const uint16_t RELAY_TXCHAR_MAX_MS   = 12000;  //   (0, absent or garbage = the kind's default)
static const uint16_t RELAY_RAW_MIN_MS      = 60;     // raw_burst / mble_tap durationMs clamp
static const uint16_t RELAY_RAW_MAX_MS      = 10000;
static const uint16_t RELAY_RAW_DEFAULT_MS  = 500;    // raw_burst without durationMs
static const uint16_t RELAY_MBLE_DEFAULT_MS = 5000;   // mble_tap without durationMs
static const uint32_t RELAY_LOOP_MIN_MS     = 500;    // set_tx_loop / set_starlight_loop intervalMs
static const uint32_t RELAY_LOOP_MAX_MS     = 60000;
static const uint16_t RELAY_WAKE_MIN_MS     = 100;    // set_wakeup_preamble
static const uint16_t RELAY_WAKE_MAX_MS     = 3000;
static const uint16_t RELAY_WAKE_ABSENT_MS  = 520;    //   value used when "ms" is missing
static const uint16_t RELAY_CMD_MIN_MS      = 500;    // set_command_burst
static const uint16_t RELAY_CMD_MAX_MS      = 12000;
static const uint16_t RELAY_CMD_ABSENT_MS   = 2000;   //   (Android's default when "ms" is missing)
static const uint16_t RELAY_STAR_MIN_MS     = 250;    // set_starlight_burst
static const uint16_t RELAY_STAR_MAX_MS     = 5000;
static const uint16_t RELAY_STAR_ABSENT_MS  = 500;
static const uint16_t RELAY_STATUS_LIMIT    = 508;    // STATUS object stays under one 512-byte value

// The band's standalone wake ping, and the "Vibrate" band command (the app's vibrate action
// carries no hex: the relay knows the packet).
static const char* const RELAY_WAKE_PING_HEX = "8301CC03000100";
static const char* const RELAY_VIBRATE_HEX   = "8301CC03000100E100E90C000F0F5D465BF005323748B0";

// ---- Packets -------------------------------------------------------------------------------
// Values shared with the OLED's packet kinds (oled_pages.h PACKET_*).
enum RelayKind : uint8_t { RELAY_KIND_NONE = 0, RELAY_KIND_BAND, RELAY_KIND_WAND, RELAY_KIND_PING, RELAY_KIND_RAW };

enum RelayHexResult : uint8_t { RELAY_HEX_OK = 0, RELAY_HEX_SHORT, RELAY_HEX_LONG };

static inline int relayHexNibble(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// Decodes the hex digits of s[0..n) into out (anything else is skipped, an odd last digit is
// dropped). Returns the byte count, or cap + 1 when there are more bytes than fit.
static inline size_t relayHexDecode(const char* s, size_t n, uint8_t* out, size_t cap) {
  size_t k = 0;
  int hi = -1;
  for (size_t i = 0; i < n; i++) {
    const int v = relayHexNibble(s[i]);
    if (v < 0) continue;
    if (hi < 0) {
      hi = v;
      continue;
    }
    if (k >= cap) return cap + 1;
    out[k++] = (uint8_t)((hi << 4) | v);
    hi = -1;
  }
  return k;
}

// A packet as the relay puts it on air: the decoded hex, with company id 83 01 in front when it
// is missing (HexUtils.canonicalHex). 3..29 bytes. `out` holds RELAY_PACKET_MAX bytes.
static inline RelayHexResult relayCanonicalPacket(const char* s, size_t n, uint8_t* out, uint8_t* len) {
  uint8_t raw[RELAY_PACKET_MAX + 2];
  const size_t k = relayHexDecode(s, n, raw, sizeof(raw));
  *len = 0;
  if (k > sizeof(raw)) return RELAY_HEX_LONG;
  const bool hasCompany = k >= 2 && raw[0] == 0x83 && raw[1] == 0x01;
  const size_t total = hasCompany ? k : k + 2;
  if (total > RELAY_PACKET_MAX) return RELAY_HEX_LONG;
  if (total < RELAY_PACKET_MIN) return RELAY_HEX_SHORT;
  size_t o = 0;
  if (!hasCompany) {
    out[o++] = 0x83;
    out[o++] = 0x01;
  }
  memcpy(out + o, raw, k);
  *len = (uint8_t)total;
  return RELAY_HEX_OK;
}

// Starlight wand packets carry CF 9B / CF 0B (byte-aligned): one burst, no band wake.
static inline bool relayIsWand(const uint8_t* b, size_t len) {
  for (size_t i = 0; i + 1 < len; i++) {
    if (b[i] == 0xCF && (b[i + 1] == 0x9B || b[i + 1] == 0x0B)) return true;
  }
  return false;
}

// Standalone ping: 83 01 CC 03 ... with no effect payload (no E9 byte): one burst.
static inline bool relayIsPing(const uint8_t* b, size_t len) {
  if (!(len >= 4 && b[0] == 0x83 && b[1] == 0x01 && b[2] == 0xCC && b[3] == 0x03)) return false;
  for (size_t i = 0; i < len; i++) {
    if (b[i] == 0xE9) return false;
  }
  return true;
}

static inline uint8_t relayPacketKind(const uint8_t* b, size_t len) {
  if (relayIsWand(b, len)) return RELAY_KIND_WAND;
  if (relayIsPing(b, len)) return RELAY_KIND_PING;
  return RELAY_KIND_BAND;
}

// ---- JSON (just enough for the app's flat command objects) ---------------------------------
// The app's JSON comes from JSONSerialization (iOS: keys in any order, "/" written as "\/") or
// org.json (Android). Only top-level keys are looked up; nested values are skipped whole, so a
// key name inside a string or a nested object never matches.

static inline size_t relayJsonWs(const char* s, size_t n, size_t i) {
  while (i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++;
  return i;
}

// Index just past the string that opens at s[i] ('"'), or n + 1 when it never closes.
static inline size_t relayJsonSkipString(const char* s, size_t n, size_t i) {
  for (i++; i < n; i++) {
    if (s[i] == '\\') {
      i++;
      continue;
    }
    if (s[i] == '"') return i + 1;
  }
  return n + 1;
}

// Index just past the value that starts at s[i], or n + 1 when it is cut off.
static inline size_t relayJsonSkipValue(const char* s, size_t n, size_t i) {
  if (i >= n) return n + 1;
  if (s[i] == '"') return relayJsonSkipString(s, n, i);
  if (s[i] == '{' || s[i] == '[') {
    int depth = 0;
    while (i < n) {
      const char c = s[i];
      if (c == '"') {
        i = relayJsonSkipString(s, n, i);
        continue;
      }
      if (c == '{' || c == '[') {
        depth++;
      } else if (c == '}' || c == ']') {
        if (--depth == 0) return i + 1;
      }
      i++;
    }
    return n + 1;
  }
  while (i < n && s[i] != ',' && s[i] != '}' && s[i] != ']') i++;  // number or literal
  return i;
}

// Where the value of top-level `key` starts in the object s[0..n), or -1 when it is absent (or
// the text is not an object).
static inline int relayJsonFind(const char* s, size_t n, const char* key) {
  const size_t klen = strlen(key);
  size_t i = relayJsonWs(s, n, 0);
  if (i >= n || s[i] != '{') return -1;
  i++;
  for (;;) {
    i = relayJsonWs(s, n, i);
    if (i >= n || s[i] != '"') return -1;  // '}' (no more keys) or not JSON
    const size_t k0 = i + 1;
    i = relayJsonSkipString(s, n, i);
    if (i > n) return -1;
    const size_t k1 = i - 1;  // the closing quote
    i = relayJsonWs(s, n, i);
    if (i >= n || s[i] != ':') return -1;
    i = relayJsonWs(s, n, i + 1);
    if (i >= n) return -1;
    if (k1 - k0 == klen && memcmp(s + k0, key, klen) == 0) return (int)i;
    i = relayJsonSkipValue(s, n, i);
    if (i > n) return -1;
    i = relayJsonWs(s, n, i);
    if (i >= n || s[i] != ',') return -1;
    i++;
  }
}

// The string value at s[at], unescaped into out (NUL-terminated, cut to cap - 1 bytes): \" \\ \/
// \b \f \n \r \t decoded (control characters become a space), \uXXXX becomes '?'. `full` gets
// the unescaped length before any cut. False when there is no string at `at`.
static inline bool relayJsonString(const char* s, size_t n, int at, char* out, size_t cap, size_t* full) {
  if (cap == 0) return false;
  out[0] = '\0';
  if (full) *full = 0;
  if (at < 0 || (size_t)at >= n || s[at] != '"') return false;
  size_t o = 0, total = 0;
  for (size_t i = (size_t)at + 1; i < n; i++) {
    char c = s[i];
    if (c == '"') {
      out[o] = '\0';
      if (full) *full = total;
      return true;
    }
    if (c == '\\') {
      if (++i >= n) break;
      switch (s[i]) {
        case 'u':
          c = '?';
          for (int h = 0; h < 4 && i + 1 < n && relayHexNibble(s[i + 1]) >= 0; h++) i++;
          break;
        case 'b': case 'f': case 'n': case 'r': case 't':
          c = ' ';
          break;
        default:  // \" \\ \/ and anything else: the character itself
          c = s[i];
          break;
      }
    } else if ((unsigned char)c < 0x20) {
      c = ' ';
    }
    if (o + 1 < cap) out[o++] = c;
    total++;
  }
  out[o] = '\0';
  return false;  // never closed
}

// Integer value at s[at]: optional quotes, optional '-', digits (a fraction is ignored); clamped
// to int32. False when there is no number there.
static inline bool relayJsonInt(const char* s, size_t n, int at, int32_t* v) {
  if (at < 0 || (size_t)at >= n) return false;
  size_t i = (size_t)at;
  if (s[i] == '"') i++;
  bool neg = false;
  if (i < n && s[i] == '-') {
    neg = true;
    i++;
  }
  if (i >= n || !isdigit((unsigned char)s[i])) return false;
  int64_t x = 0;
  for (; i < n && isdigit((unsigned char)s[i]); i++) {
    if (x < 10000000000LL) x = x * 10 + (s[i] - '0');
  }
  if (neg) x = -x;
  if (x > 2147483647LL) x = 2147483647LL;
  if (x < -2147483647LL - 1) x = -2147483647LL - 1;
  *v = (int32_t)x;
  return true;
}

// true / false at s[at] (also quoted). False when it is neither.
static inline bool relayJsonBool(const char* s, size_t n, int at, bool* v) {
  if (at < 0 || (size_t)at >= n) return false;
  size_t i = (size_t)at;
  const bool quoted = s[i] == '"';
  if (quoted) i++;
  bool value;
  size_t len;
  if (n - i >= 4 && memcmp(s + i, "true", 4) == 0) {
    value = true;
    len = 4;
  } else if (n - i >= 5 && memcmp(s + i, "false", 5) == 0) {
    value = false;
    len = 5;
  } else {
    return false;
  }
  i += len;
  if (quoted) {
    if (i >= n || s[i] != '"') return false;
  } else if (i < n && (isalnum((unsigned char)s[i]) || s[i] == '_')) {
    return false;
  }
  *v = value;
  return true;
}

static inline int32_t relayClamp(int32_t v, int32_t lo, int32_t hi) { return v < lo ? lo : (v > hi ? hi : v); }

// A loop label as the chip keeps and reports it: bytes 0x20..0x7E except '"' and '\' (so it
// needs no escaping), everything else (UTF-8 included) dropped, spaces trimmed, at most 16.
// `out` holds RELAY_LABEL_MAX + 1 bytes. Returns the length.
static inline size_t relaySanitizeLabel(const char* in, char* out) {
  size_t o = 0;
  for (const char* p = in; *p && o < RELAY_LABEL_MAX; p++) {
    const unsigned char c = (unsigned char)*p;
    if (c < 0x20 || c > 0x7E || c == '"' || c == '\\') continue;
    if (c == ' ' && o == 0) continue;  // leading spaces
    out[o++] = (char)c;
  }
  while (o > 0 && out[o - 1] == ' ') o--;
  out[o] = '\0';
  return o;
}

// ---- MBLE tap (Android MbleBeaconBuilder) ---------------------------------------------------
// 83 01 | 0F 11 | 73 93 (beacon id "987393", last 4 digits) | token body (rightmost 28 hex digits,
// left-padded with 0: 14 bytes) | power (the token's last 2 digits). 21 bytes. False when the
// token has fewer than 4 hex digits.
static const uint8_t RELAY_MBLE_LEN = 21;

static inline bool relayMbleBytes(const char* token, size_t n, uint8_t* out) {
  char digits[29];
  size_t count = 0;
  for (size_t i = 0; i < n; i++) {
    if (relayHexNibble(token[i]) >= 0) count++;
  }
  if (count < 4) return false;
  // The rightmost 28 digits, left-padded with '0'.
  size_t skip = count > 28 ? count - 28 : 0;
  size_t pad = count < 28 ? 28 - count : 0;
  size_t d = 0;
  for (; d < pad; d++) digits[d] = '0';
  for (size_t i = 0; i < n; i++) {
    if (relayHexNibble(token[i]) < 0) continue;
    if (skip) {
      skip--;
      continue;
    }
    digits[d++] = (char)toupper((unsigned char)token[i]);
  }
  digits[28] = '\0';
  size_t o = 0;
  out[o++] = 0x83;
  out[o++] = 0x01;
  out[o++] = 0x0F;
  out[o++] = 0x11;
  out[o++] = 0x73;
  out[o++] = 0x93;
  for (int b = 0; b < 14; b++) {
    out[o++] = (uint8_t)((relayHexNibble(digits[2 * b]) << 4) | relayHexNibble(digits[2 * b + 1]));
  }
  out[o++] = (uint8_t)((relayHexNibble(digits[26]) << 4) | relayHexNibble(digits[27]));  // power
  return true;
}

// ---- Commands -------------------------------------------------------------------------------
enum RelayAction : uint8_t {
  RELAY_ACT_UNKNOWN = 0,
  RELAY_ACT_TRANSMIT,
  RELAY_ACT_VIBRATE,
  RELAY_ACT_INTERROGATE,
  RELAY_ACT_KEEP_AWAKE,
  RELAY_ACT_TX_LOOP,
  RELAY_ACT_WAND_LOOP,
  RELAY_ACT_PREAMBLE,
  RELAY_ACT_COMMAND_BURST,
  RELAY_ACT_STARLIGHT_BURST,
  RELAY_ACT_TX_POWER,
  RELAY_ACT_TX_INTERLEAVE,
  RELAY_ACT_RAW_BURST,
  RELAY_ACT_MBLE_TAP,
  RELAY_ACT_SET_SCAN,         // the chip never scans: enabled:false is a no-op, anything else unsupported
  RELAY_ACT_SET_AUTO,
  RELAY_ACT_SET_RECORDING,
  RELAY_ACT_CLEAR_LIVE,       // nothing to clear: ok
  RELAY_ACT_LIVE,             // no live feed: ok, no packets
  RELAY_ACT_STATUS,
  RELAY_ACT_CATALOG,          // empty library: ok + "items":[]
  RELAY_ACT_UNSUPPORTED,      // library, auto rules, scan filter, live-feed edits, Wi-Fi pairing
};

struct RelayActionName {
  const char* name;
  uint8_t action;
};

// Every action name and alias the Android relay accepts (RelayCommands.execute).
static const RelayActionName RELAY_ACTIONS[] = {
    {"transmit", RELAY_ACT_TRANSMIT},
    {"tx", RELAY_ACT_TRANSMIT},
    {"vibrate", RELAY_ACT_VIBRATE},
    {"vib", RELAY_ACT_VIBRATE},
    {"interrogate", RELAY_ACT_INTERROGATE},
    {"ping", RELAY_ACT_INTERROGATE},
    {"wakeup", RELAY_ACT_INTERROGATE},
    {"keep_awake", RELAY_ACT_KEEP_AWAKE},
    {"keepawake", RELAY_ACT_KEEP_AWAKE},
    {"set_tx_loop", RELAY_ACT_TX_LOOP},
    {"tx_loop", RELAY_ACT_TX_LOOP},
    {"repeat_tx", RELAY_ACT_TX_LOOP},
    {"set_starlight_loop", RELAY_ACT_WAND_LOOP},
    {"wand_loop", RELAY_ACT_WAND_LOOP},
    {"set_wakeup_preamble", RELAY_ACT_PREAMBLE},
    {"preamble", RELAY_ACT_PREAMBLE},
    {"set_command_burst", RELAY_ACT_COMMAND_BURST},
    {"command_burst", RELAY_ACT_COMMAND_BURST},
    {"burst", RELAY_ACT_COMMAND_BURST},
    {"set_starlight_burst", RELAY_ACT_STARLIGHT_BURST},
    {"starlight_burst", RELAY_ACT_STARLIGHT_BURST},
    {"wand_burst", RELAY_ACT_STARLIGHT_BURST},
    {"set_tx_power", RELAY_ACT_TX_POWER},
    {"tx_power", RELAY_ACT_TX_POWER},
    {"set_tx_interleave", RELAY_ACT_TX_INTERLEAVE},
    {"tx_interleave", RELAY_ACT_TX_INTERLEAVE},
    {"raw_burst", RELAY_ACT_RAW_BURST},
    {"replay_burst", RELAY_ACT_RAW_BURST},
    {"mble_tap", RELAY_ACT_MBLE_TAP},
    {"mble", RELAY_ACT_MBLE_TAP},
    {"tap", RELAY_ACT_MBLE_TAP},
    {"set_scan", RELAY_ACT_SET_SCAN},
    {"scan", RELAY_ACT_SET_SCAN},
    {"set_auto", RELAY_ACT_SET_AUTO},
    {"auto", RELAY_ACT_SET_AUTO},
    {"set_recording", RELAY_ACT_SET_RECORDING},
    {"record", RELAY_ACT_SET_RECORDING},
    {"log", RELAY_ACT_SET_RECORDING},
    {"clear_live", RELAY_ACT_CLEAR_LIVE},
    {"clear", RELAY_ACT_CLEAR_LIVE},
    {"live", RELAY_ACT_LIVE},
    {"status", RELAY_ACT_STATUS},
    {"catalog", RELAY_ACT_CATALOG},
    {"catalog_sync_begin", RELAY_ACT_CATALOG},
    {"catalog_begin", RELAY_ACT_CATALOG},
    {"sync_begin", RELAY_ACT_CATALOG},
    {"catalog_sync_chunk", RELAY_ACT_CATALOG},
    {"catalog_chunk", RELAY_ACT_CATALOG},
    {"sync_chunk", RELAY_ACT_CATALOG},
    {"remove_live", RELAY_ACT_UNSUPPORTED},
    {"remove_raw_live", RELAY_ACT_UNSUPPORTED},
    {"save_custom_preset", RELAY_ACT_UNSUPPORTED},
    {"add_tx_preset", RELAY_ACT_UNSUPPORTED},
    {"save_preset", RELAY_ACT_UNSUPPORTED},
    {"delete_wand_color", RELAY_ACT_UNSUPPORTED},
    {"delete_wand", RELAY_ACT_UNSUPPORTED},
    {"clear_wand_library", RELAY_ACT_UNSUPPORTED},
    {"clear_wand", RELAY_ACT_UNSUPPORTED},
    {"add_auto_rule", RELAY_ACT_UNSUPPORTED},
    {"delete_auto_rule", RELAY_ACT_UNSUPPORTED},
    {"set_auto_rule", RELAY_ACT_UNSUPPORTED},
    {"auto_rule", RELAY_ACT_UNSUPPORTED},
    {"set_show_control_only", RELAY_ACT_UNSUPPORTED},
    {"show_control_only", RELAY_ACT_UNSUPPORTED},
    {"pairing", RELAY_ACT_UNSUPPORTED},
    {"pairing_info", RELAY_ACT_UNSUPPORTED},
};

static inline uint8_t relayActionFor(const char* lowerName) {
  for (size_t i = 0; i < sizeof(RELAY_ACTIONS) / sizeof(RELAY_ACTIONS[0]); i++) {
    if (strcmp(lowerName, RELAY_ACTIONS[i].name) == 0) return RELAY_ACTIONS[i].action;
  }
  return RELAY_ACT_UNKNOWN;
}

// Work for loop(), handed over from the NimBLE task through a queue.
enum RelayCmdType : uint8_t {
  RELAY_CMD_NONE = 0,
  RELAY_CMD_SEND,            // user send (TX char, transmit, vibrate, interrogate): bytes; ms 0 = kind default
  RELAY_CMD_RAW,             // the packet alone for exactly ms: raw_burst (RELAY_CMDF_REPLAY) or mble_tap
  RELAY_CMD_KEEP_AWAKE,      // en; bytes when RELAY_CMDF_PACKET
  RELAY_CMD_TX_LOOP,         // en; bytes / label / interval when flagged
  RELAY_CMD_WAND_LOOP,
  RELAY_CMD_SET_WAKE,        // ms
  RELAY_CMD_SET_CMD,         // ms
  RELAY_CMD_SET_STAR,        // ms
  RELAY_CMD_SET_POWER,       // interval = level 0..3
  RELAY_CMD_SET_INTERLEAVE,  // en
};

enum : uint8_t {
  RELAY_CMDF_PACKET   = 1,   // bytes/len given
  RELAY_CMDF_LABEL    = 2,   // label given
  RELAY_CMDF_INTERVAL = 4,   // interval given
  RELAY_CMDF_REPLAY   = 8,   // raw_burst: waits behind a raw_burst on air instead of preempting it
};

struct ChipCmd {
  uint8_t  type;
  bool     en;
  uint8_t  len;
  uint8_t  bytes[RELAY_PACKET_MAX];
  uint16_t ms;
  uint32_t interval;
  char     label[RELAY_LABEL_MAX + 1];
  uint8_t  flags;
};

// The reply to the last CMD write, merged into every STATUS read.
struct RelayReply {
  bool ok;
  bool items;       // add "items":[] (after a catalog action)
  char error[25];
};

// What the NimBLE task remembers to validate a command without asking loop(): whether a loop
// packet was ever given (set_*_loop enabled:true without one is refused).
struct RelayShadow {
  bool haveTxLoopPacket;
  bool haveWandLoopPacket;
};

static inline void relayReplyOk(RelayReply& r) {
  r.ok = true;
  r.items = false;
  r.error[0] = '\0';
}

static inline void relayReplyError(RelayReply& r, const char* error) {
  r.ok = false;
  r.items = false;
  strncpy(r.error, error, sizeof(r.error) - 1);
  r.error[sizeof(r.error) - 1] = '\0';
}

// A "hex" parameter: absent -> RELAY_HEX_SHORT with *present false.
static inline RelayHexResult relayHexParam(const char* s, size_t n, const char* key, uint8_t* out, uint8_t* len,
                                           bool* present) {
  char hex[192];
  size_t full = 0;
  const int at = relayJsonFind(s, n, key);
  *len = 0;
  *present = at >= 0;
  if (!relayJsonString(s, n, at, hex, sizeof(hex), &full)) return RELAY_HEX_SHORT;
  if (full >= sizeof(hex)) return RELAY_HEX_LONG;
  return relayCanonicalPacket(hex, strlen(hex), out, len);
}

static inline int32_t relayIntParam(const char* s, size_t n, const char* key, int32_t absent) {
  int32_t v;
  return relayJsonInt(s, n, relayJsonFind(s, n, key), &v) ? v : absent;
}

static inline bool relayBoolParam(const char* s, size_t n, const char* key, bool absent) {
  bool v;
  return relayJsonBool(s, n, relayJsonFind(s, n, key), &v) ? v : absent;
}

static inline bool relayHexError(RelayReply& r, RelayHexResult h) {
  relayReplyError(r, h == RELAY_HEX_LONG ? "packet too long" : "bad hex");
  return false;
}

static inline void relayCmdPacket(ChipCmd& c, const char* hex) {
  relayCanonicalPacket(hex, strlen(hex), c.bytes, &c.len);
  c.flags |= RELAY_CMDF_PACKET;
}

// One CMD write (s[0..n), not NUL-terminated). Always fills `r`; returns true with `c` filled when
// loop() has something to do.
static inline bool relayParseCommand(const char* s, size_t n, const RelayShadow& sh, ChipCmd& c, RelayReply& r) {
  memset(&c, 0, sizeof(c));
  relayReplyOk(r);
  const size_t first = relayJsonWs(s, n, 0);
  if (first >= n || s[first] != '{') {
    relayReplyError(r, "bad json");
    return false;
  }

  char name[32];
  size_t full = 0;
  if (!relayJsonString(s, n, relayJsonFind(s, n, "action"), name, sizeof(name), &full) || full >= sizeof(name)) {
    name[0] = '\0';
  }
  for (char* p = name; *p; p++) *p = (char)tolower((unsigned char)*p);

  bool present = false;
  RelayHexResult h;
  const uint8_t action = relayActionFor(name);
  switch (action) {
    case RELAY_ACT_TRANSMIT:
      h = relayHexParam(s, n, "hex", c.bytes, &c.len, &present);
      if (h != RELAY_HEX_OK) return relayHexError(r, h);
      c.type = RELAY_CMD_SEND;
      c.flags = RELAY_CMDF_PACKET;
      return true;

    case RELAY_ACT_VIBRATE:
      c.type = RELAY_CMD_SEND;
      relayCmdPacket(c, RELAY_VIBRATE_HEX);
      return true;

    case RELAY_ACT_INTERROGATE:
      c.type = RELAY_CMD_SEND;
      relayCmdPacket(c, RELAY_WAKE_PING_HEX);
      return true;

    case RELAY_ACT_KEEP_AWAKE:
      c.type = RELAY_CMD_KEEP_AWAKE;
      c.en = relayBoolParam(s, n, "enabled", false);
      h = relayHexParam(s, n, "hex", c.bytes, &c.len, &present);
      if (h == RELAY_HEX_LONG) return relayHexError(r, h);
      if (h == RELAY_HEX_OK && c.len >= RELAY_KEEP_MIN) c.flags |= RELAY_CMDF_PACKET;
      else c.len = 0;  // too short: the stored ping stays
      return true;

    case RELAY_ACT_TX_LOOP:
    case RELAY_ACT_WAND_LOOP: {
      const bool tx = action == RELAY_ACT_TX_LOOP;
      c.type = tx ? RELAY_CMD_TX_LOOP : RELAY_CMD_WAND_LOOP;
      c.en = relayBoolParam(s, n, "enabled", false);
      h = relayHexParam(s, n, "hex", c.bytes, &c.len, &present);
      if (present) {
        if (h != RELAY_HEX_OK) return relayHexError(r, h);
        c.flags |= RELAY_CMDF_PACKET;
      }
      char raw[96];
      if (relayJsonString(s, n, relayJsonFind(s, n, "label"), raw, sizeof(raw), nullptr)) {
        relaySanitizeLabel(raw, c.label);
        c.flags |= RELAY_CMDF_LABEL;
      }
      int32_t iv;
      if (relayJsonInt(s, n, relayJsonFind(s, n, "intervalMs"), &iv)) {
        c.interval = (uint32_t)relayClamp(iv, (int32_t)RELAY_LOOP_MIN_MS, (int32_t)RELAY_LOOP_MAX_MS);
        c.flags |= RELAY_CMDF_INTERVAL;
      }
      // packetId (Android library ids) means nothing here: the phone sends the packet itself.
      const bool known = tx ? sh.haveTxLoopPacket : sh.haveWandLoopPacket;
      if (c.en && !(c.flags & RELAY_CMDF_PACKET) && !known) {
        relayReplyError(r, "no packet");
        return false;
      }
      return true;
    }

    case RELAY_ACT_PREAMBLE:
      c.type = RELAY_CMD_SET_WAKE;
      c.ms = (uint16_t)relayClamp(relayIntParam(s, n, "ms", relayIntParam(s, n, "preambleMs", RELAY_WAKE_ABSENT_MS)),
                                  RELAY_WAKE_MIN_MS, RELAY_WAKE_MAX_MS);
      return true;

    case RELAY_ACT_COMMAND_BURST:
      c.type = RELAY_CMD_SET_CMD;
      c.ms = (uint16_t)relayClamp(relayIntParam(s, n, "ms", relayIntParam(s, n, "burstMs", RELAY_CMD_ABSENT_MS)),
                                  RELAY_CMD_MIN_MS, RELAY_CMD_MAX_MS);
      return true;

    case RELAY_ACT_STARLIGHT_BURST:
      c.type = RELAY_CMD_SET_STAR;
      c.ms = (uint16_t)relayClamp(relayIntParam(s, n, "ms", relayIntParam(s, n, "burstMs", RELAY_STAR_ABSENT_MS)),
                                  RELAY_STAR_MIN_MS, RELAY_STAR_MAX_MS);
      return true;

    case RELAY_ACT_TX_POWER:
      c.type = RELAY_CMD_SET_POWER;
      c.interval = (uint32_t)relayClamp(relayIntParam(s, n, "level", 3), 0, 3);
      return true;

    case RELAY_ACT_TX_INTERLEAVE:
      c.type = RELAY_CMD_SET_INTERLEAVE;
      c.en = relayBoolParam(s, n, "enabled", false);
      return true;

    case RELAY_ACT_RAW_BURST:
      h = relayHexParam(s, n, "hex", c.bytes, &c.len, &present);
      if (h != RELAY_HEX_OK) return relayHexError(r, h);
      c.type = RELAY_CMD_RAW;
      c.flags = RELAY_CMDF_PACKET | RELAY_CMDF_REPLAY;
      c.ms = (uint16_t)relayClamp(relayIntParam(s, n, "durationMs", RELAY_RAW_DEFAULT_MS), RELAY_RAW_MIN_MS,
                                  RELAY_RAW_MAX_MS);
      return true;

    case RELAY_ACT_MBLE_TAP: {
      char token[96];
      if (!relayJsonString(s, n, relayJsonFind(s, n, "token"), token, sizeof(token), nullptr) ||
          !relayMbleBytes(token, strlen(token), c.bytes)) {
        relayReplyError(r, "bad token");
        return false;
      }
      c.type = RELAY_CMD_RAW;
      c.len = RELAY_MBLE_LEN;
      c.flags = RELAY_CMDF_PACKET;
      c.ms = (uint16_t)relayClamp(relayIntParam(s, n, "durationMs", RELAY_MBLE_DEFAULT_MS), RELAY_RAW_MIN_MS,
                                  RELAY_RAW_MAX_MS);
      return true;
    }

    case RELAY_ACT_SET_SCAN:
    case RELAY_ACT_SET_AUTO:
    case RELAY_ACT_SET_RECORDING:
      // Scanning, auto-responses and logging stay on the phone. Turning them off is true here.
      if (relayBoolParam(s, n, "enabled", true)) relayReplyError(r, "unsupported");
      return false;

    case RELAY_ACT_CLEAR_LIVE:
    case RELAY_ACT_LIVE:
    case RELAY_ACT_STATUS:
      return false;

    case RELAY_ACT_CATALOG:
      r.items = true;  // the library lives on the phone: always empty here
      return false;

    case RELAY_ACT_UNSUPPORTED:
      relayReplyError(r, "unsupported");
      return false;

    default:
      relayReplyError(r, "unknown action");
      return false;
  }
}

// TX characteristic "{hex}|{ms}" (split at the last '|'). False when the hex is not a packet (the
// write is ignored). ms: 0, absent or not a plain number = the kind's default (0 here);
// otherwise clamped to 60..12000.
static inline bool relayParseTransmitWrite(const char* s, size_t n, ChipCmd& c) {
  memset(&c, 0, sizeof(c));
  size_t pipe = n;
  for (size_t i = n; i-- > 0;) {
    if (s[i] == '|') {
      pipe = i;
      break;
    }
  }
  if (relayCanonicalPacket(s, pipe, c.bytes, &c.len) != RELAY_HEX_OK) return false;
  c.type = RELAY_CMD_SEND;
  c.flags = RELAY_CMDF_PACKET;
  uint32_t ms = 0;
  bool digits = false, garbage = false;
  for (size_t i = pipe + 1; i < n; i++) {
    const char ch = s[i];
    if (ch >= '0' && ch <= '9') {
      if (ms < 1000000u) ms = ms * 10u + (uint32_t)(ch - '0');
      digits = true;
    } else if (ch != ' ' && ch != '\r' && ch != '\n' && ch != '\t' && ch != '\0') {
      garbage = true;
    }
  }
  if (garbage || !digits || ms == 0) {
    c.ms = 0;
  } else {
    c.ms = (uint16_t)relayClamp((int32_t)ms, RELAY_TXCHAR_MIN_MS, RELAY_TXCHAR_MAX_MS);
  }
  return true;
}

// ---- STATUS ---------------------------------------------------------------------------------
enum RelayProgram : uint8_t { RELAY_PROG_NONE = 0, RELAY_PROG_KEEP_AWAKE, RELAY_PROG_TX_LOOP, RELAY_PROG_WAND_LOOP };

// Everything a STATUS read reports, copied out of loop() under a lock (plain data only).
struct RelaySnapshot {
  uint8_t  program;      // RelayProgram
  uint32_t intervalMs;   // the running loop's interval
  uint16_t wakeMs, cmdMs, starMs;
  uint8_t  powerLevel;
  bool     interleave;
  uint32_t sent;         // jobs put on air since boot
  int32_t  batMv;        // < 0: no battery keys (classic ESP32, or no plausible reading)
  int16_t  batPct;
  uint16_t batMah;       // rated capacity
  int32_t  runMin;       // < 0: unknown (omitted)
  bool     charging;
  uint8_t  len;          // the running program's packet (keep-awake ping or loop packet)
  uint8_t  bytes[RELAY_PACKET_MAX];
  char     label[RELAY_LABEL_MAX + 1];  // the running loop's label ("" = none)
};

struct RelayOut {
  char*  p;
  size_t cap;
  size_t len;
};

static inline void relayPut(RelayOut& o, const char* s) {
  while (*s && o.len + 1 < o.cap) o.p[o.len++] = *s++;
  o.p[o.len] = '\0';
}

static inline void relayPutInt(RelayOut& o, int32_t v) {
  char buf[12];
  int k = 0;
  uint32_t u = v < 0 ? (uint32_t)(-(int64_t)v) : (uint32_t)v;
  do {
    buf[k++] = (char)('0' + u % 10u);
    u /= 10u;
  } while (u && k < 11);
  if (v < 0 && o.len + 1 < o.cap) o.p[o.len++] = '-';
  while (k > 0 && o.len + 1 < o.cap) o.p[o.len++] = buf[--k];
  o.p[o.len] = '\0';
}

static inline void relayPutHex(RelayOut& o, const uint8_t* b, size_t n) {
  static const char kDigits[] = "0123456789ABCDEF";
  for (size_t i = 0; i < n && o.len + 2 < o.cap; i++) {
    o.p[o.len++] = kDigits[b[i] >> 4];
    o.p[o.len++] = kDigits[b[i] & 15];
  }
  o.p[o.len] = '\0';
}

static inline void relayPutKey(RelayOut& o, const char* key) {
  relayPut(o, ",\"");
  relayPut(o, key);
  relayPut(o, "\":");
}

static inline void relayPutIntKey(RelayOut& o, const char* key, int32_t v) {
  relayPutKey(o, key);
  relayPutInt(o, v);
}

static inline void relayPutBoolKey(RelayOut& o, const char* key, bool v) {
  relayPutKey(o, key);
  relayPut(o, v ? "true" : "false");
}

// The STATUS value: the last command's reply merged with the chip's state, short fields first,
// hex and label last. `cap` >= 512; the result stays <= RELAY_STATUS_LIMIT bytes (the label, then
// the hex, is left out when it would not fit). Returns the length. No printf: this runs on the
// NimBLE task's small stack.
static inline size_t relayFormatStatus(const RelaySnapshot& s, const RelayReply& r, uint32_t uptimeS, int proto,
                                       const char* fw, const char* board, char* out, size_t cap) {
  RelayOut o = {out, cap < RELAY_STATUS_LIMIT + 1u ? cap : RELAY_STATUS_LIMIT + 1u, 0};
  if (o.cap == 0) return 0;
  o.p[0] = '\0';
  relayPut(o, "{\"ok\":");
  relayPut(o, r.ok ? "true" : "false");
  if (!r.ok) {
    relayPutKey(o, "error");
    relayPut(o, "\"");
    relayPut(o, r.error);
    relayPut(o, "\"");
  }
  relayPut(o, ",\"running\":true");
  relayPutIntKey(o, "proto", proto);
  relayPutKey(o, "fw");
  relayPut(o, "\"");
  relayPut(o, fw);
  relayPut(o, "\"");
  relayPutKey(o, "board");
  relayPut(o, "\"");
  relayPut(o, board);
  relayPut(o, "\"");
  relayPutBoolKey(o, "keepAwake", s.program == RELAY_PROG_KEEP_AWAKE);
  if (s.program == RELAY_PROG_TX_LOOP) {
    relayPutBoolKey(o, "txLoopEnabled", true);
    relayPutIntKey(o, "txLoopIntervalMs", (int32_t)s.intervalMs);
  } else if (s.program == RELAY_PROG_WAND_LOOP) {
    relayPutBoolKey(o, "starlightLoopEnabled", true);
    relayPutIntKey(o, "starlightIntervalMs", (int32_t)s.intervalMs);
  }
  relayPutIntKey(o, "wakeupPreambleMs", s.wakeMs);
  relayPutIntKey(o, "commandBurstMs", s.cmdMs);
  relayPutIntKey(o, "starlightBurstMs", s.starMs);
  relayPutIntKey(o, "txPowerLevel", s.powerLevel);
  relayPutBoolKey(o, "txInterleave", s.interleave);
  relayPutIntKey(o, "uptimeS", (int32_t)(uptimeS > 2147483647u ? 2147483647u : uptimeS));
  relayPutIntKey(o, "sent", (int32_t)(s.sent > 2147483647u ? 2147483647u : s.sent));
  if (s.batMv >= 0) {
    relayPutIntKey(o, "batMv", s.batMv);
    relayPutIntKey(o, "batPct", s.batPct);
    relayPutIntKey(o, "batMah", s.batMah);
    if (s.charging) relayPutBoolKey(o, "charging", true);
    else if (s.runMin >= 0) relayPutIntKey(o, "runMin", s.runMin);
  }
  if (r.items) relayPut(o, ",\"items\":[]");

  // The running program's packet (and the loop's label), as far as they fit.
  const char* hexKey = nullptr;
  const char* labelKey = nullptr;
  if (s.program == RELAY_PROG_KEEP_AWAKE) {
    hexKey = "keepAwakeHex";
  } else if (s.program == RELAY_PROG_TX_LOOP) {
    hexKey = "txLoopHex";
    labelKey = "txLoopLabel";
  } else if (s.program == RELAY_PROG_WAND_LOOP) {
    hexKey = "starlightLoopHex";
    labelKey = "starlightLoopLabel";
  }
  if (hexKey && s.len > 0) {
    size_t labelLen = 0;
    while (labelLen < RELAY_LABEL_MAX && s.label[labelLen]) labelLen++;
    const size_t hexPart = 2 + strlen(hexKey) + 3 + 2u * s.len + 1;                         // ,"k":"…"
    const size_t labelPart = (labelKey && labelLen) ? 2 + strlen(labelKey) + 3 + labelLen + 1 : 0;
    if (o.len + hexPart + 1 <= RELAY_STATUS_LIMIT) {
      relayPutKey(o, hexKey);
      relayPut(o, "\"");
      relayPutHex(o, s.bytes, s.len);
      relayPut(o, "\"");
      if (labelPart && o.len + labelPart + 1 <= RELAY_STATUS_LIMIT) {
        char label[RELAY_LABEL_MAX + 1];
        memcpy(label, s.label, labelLen);
        label[labelLen] = '\0';
        relayPutKey(o, labelKey);
        relayPut(o, "\"");
        relayPut(o, label);
        relayPut(o, "\"");
      }
    }
  }
  relayPut(o, "}");
  return o.len;
}
