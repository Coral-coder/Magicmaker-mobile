// Host test of the relay protocol (../../relay_proto.h): the power commands (power_off,
// set_low_cutoff), the commands they sit beside, and the STATUS object of protocol 3 (key order,
// the 508-byte limit, what is dropped first).
//
//   make -C firmware/esp32-transmitter/test/host relay     (this test only)
//   make -C firmware/esp32-transmitter/test/host test      (every host test)
//
// Host only (C++17, g++): PlatformIO builds every source under the sketch folder, so this file is
// empty when ARDUINO is defined. (.cc, not .cpp: the firmware workflow triggers on those.)
#ifndef ARDUINO

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "../../relay_proto.h"
#include "../../relay_engine.h"
#include "json_mini.hpp"

namespace {

int g_checks = 0;
int g_failures = 0;

void check(bool ok, const char* what, int line, const std::string& detail = std::string()) {
  g_checks++;
  if (ok) return;
  g_failures++;
  std::fprintf(stderr, "FAIL line %d: %s%s%s\n", line, what, detail.empty() ? "" : " -- ", detail.c_str());
}
#define CHECK(c) check((c), #c, __LINE__)
#define CHECK_MSG(c, m) check((c), #c, __LINE__, (m))

struct Parsed {
  bool queued;
  ChipCmd c;
  RelayReply r;
};

Parsed cmd(const std::string& json, bool hasBattery = true) {
  RelayShadow sh;
  std::memset(&sh, 0, sizeof(sh));
  sh.hasBattery = hasBattery;
  Parsed p;
  p.queued = relayParseCommand(json.data(), json.size(), sh, p.c, p.r);
  return p;
}

bool isError(const Parsed& p, const char* error) { return !p.queued && !p.r.ok && std::strcmp(p.r.error, error) == 0; }

// ---- power_off -----------------------------------------------------------------------------
void testPowerOff() {
  for (const char* name : {"power_off", "poweroff", "shutdown", "POWER_OFF", "PowerOff"}) {
    const std::string n(name);
    Parsed p = cmd("{\"action\":\"" + n + "\",\"confirm\":true}");
    CHECK_MSG(p.queued && p.r.ok && p.c.type == RELAY_CMD_POWER_OFF, n);
    p = cmd("{\"action\":\"" + n + "\"}");
    CHECK_MSG(isError(p, "confirm required"), n);
  }
  CHECK(isError(cmd("{\"action\":\"power_off\",\"confirm\":false}"), "confirm required"));
  CHECK(isError(cmd("{\"action\":\"power_off\",\"confirm\":1}"), "confirm required"));
  CHECK(isError(cmd("{\"action\":\"power_off\",\"confirm\":\"yes\"}"), "confirm required"));
  CHECK(isError(cmd("{\"action\":\"power_off\",\"confirm\":trueish}"), "confirm required"));
  // Quoted booleans are accepted everywhere else, so here too.
  Parsed p = cmd("{\"action\":\"power_off\",\"confirm\":\"true\"}");
  CHECK(p.queued && p.c.type == RELAY_CMD_POWER_OFF);
  // Key order and whitespace do not matter (iOS JSONSerialization).
  p = cmd("{ \"confirm\" : true , \"action\" : \"power_off\" }");
  CHECK(p.queued && p.c.type == RELAY_CMD_POWER_OFF);
  // A "confirm" inside a nested value is not the top-level key.
  CHECK(isError(cmd("{\"action\":\"power_off\",\"x\":{\"confirm\":true}}"), "confirm required"));
  // Both boards: no battery needed.
  p = cmd("{\"action\":\"power_off\",\"confirm\":true}", false);
  CHECK(p.queued && p.c.type == RELAY_CMD_POWER_OFF);
}

// ---- set_low_cutoff --------------------------------------------------------------------------
void testSetCutoff() {
  struct Case {
    const char* mv;
    int expect;  // -1: "bad mv"
  };
  const Case cases[] = {
      {"0", 0},        {"3200", 3200}, {"3300", 3300}, {"3400", 3400}, {"3000", 3200}, {"3249", 3200},
      {"3250", 3300},  {"3349", 3300}, {"3350", 3400}, {"3600", 3400}, {"\"3300\"", 3300},
      {"\"0\"", 0},    {"3300.7", 3300}, {"2999", -1},  {"3601", -1},   {"1", -1},       {"-3300", -1},
      {"\"abc\"", -1}, {"true", -1},   {"null", -1},   {"[3300]", -1}, {"99999999999", -1},
  };
  for (const Case& k : cases) {
    const std::string json = std::string("{\"action\":\"set_low_cutoff\",\"mv\":") + k.mv + "}";
    const Parsed p = cmd(json);
    if (k.expect < 0) {
      CHECK_MSG(isError(p, "bad mv"), json);
    } else {
      CHECK_MSG(p.queued && p.r.ok && p.c.type == RELAY_CMD_SET_CUTOFF && p.c.ms == (uint16_t)k.expect, json);
    }
  }
  CHECK(isError(cmd("{\"action\":\"set_low_cutoff\"}"), "bad mv"));
  CHECK(isError(cmd("{\"action\":\"set_low_cutoff\",\"ms\":3300}"), "bad mv"));
  for (const char* name : {"set_low_cutoff", "low_cutoff", "set_cutoff", "Set_Low_Cutoff"}) {
    const Parsed p = cmd(std::string("{\"action\":\"") + name + "\",\"mv\":3400}");
    CHECK_MSG(p.queued && p.c.type == RELAY_CMD_SET_CUTOFF && p.c.ms == 3400, name);
  }
  // Classic ESP32 (no battery reader): unsupported, whatever the value.
  CHECK(isError(cmd("{\"action\":\"set_low_cutoff\",\"mv\":3300}", false), "unsupported"));
  CHECK(isError(cmd("{\"action\":\"set_low_cutoff\",\"mv\":12}", false), "unsupported"));
  // The snap rule itself.
  CHECK(relayCutoffSnap(0) == 0);
  CHECK(relayCutoffSnap(2999) == -1 && relayCutoffSnap(3601) == -1 && relayCutoffSnap(-1) == -1);
  CHECK(relayCutoffSnap(3000) == 3200 && relayCutoffSnap(3250) == 3300 && relayCutoffSnap(3350) == 3400);
}

// ---- the commands next to them still parse as before ------------------------------------------
void testNeighbours() {
  Parsed p = cmd("{\"action\":\"status\"}");
  CHECK(!p.queued && p.r.ok);
  p = cmd("{\"action\":\"catalog\"}");
  CHECK(!p.queued && p.r.ok && p.r.items);
  p = cmd("{\"action\":\"set_tx_power\",\"level\":1}");
  CHECK(p.queued && p.c.type == RELAY_CMD_SET_POWER && p.c.interval == 1);
  p = cmd("{\"action\":\"keep_awake\",\"enabled\":true}");
  CHECK(p.queued && p.c.type == RELAY_CMD_KEEP_AWAKE && p.c.en);
  CHECK(isError(cmd("{\"action\":\"set_wifi\"}"), "unknown action"));
  CHECK(isError(cmd("{\"action\":\"set_scan\",\"enabled\":true}"), "unsupported"));
  CHECK(isError(cmd("not json"), "bad json"));
  // Every error string fits RelayReply.error (24 characters + NUL) uncut.
  for (const char* e : {"confirm required", "bad mv", "busy", "powering off", "unsupported"}) {
    RelayReply r;
    relayReplyError(r, e);
    CHECK_MSG(std::strcmp(r.error, e) == 0, e);
  }
}

// ---- STATUS ---------------------------------------------------------------------------------------
RelaySnapshot idleSnapshot() {
  RelaySnapshot s;
  std::memset(&s, 0, sizeof(s));
  s.wakeMs = 520;
  s.cmdMs = 4000;
  s.starMs = 500;
  s.powerLevel = 3;
  s.sent = 42;
  s.batMv = -1;
  s.batPct = -1;
  s.runMin = -1;
  s.cutMv = -1;
  return s;
}

RelayLinkInfo noLink() {
  RelayLinkInfo l;
  std::memset(&l, 0, sizeof(l));
  return l;
}

RelayLinkInfo link(uint16_t itvl, uint16_t lat, uint16_t to) {
  RelayLinkInfo l;
  l.valid = true;
  l.itvl = itvl;
  l.latency = lat;
  l.timeout = to;
  return l;
}

std::string status(const RelaySnapshot& s, const RelayReply& r, const RelayLinkInfo& l, uint32_t uptimeS = 8123,
                   const char* board = "HELTEC V3") {
  char buf[512];
  std::memset(buf, 'x', sizeof(buf));
  const size_t n = relayFormatStatus(s, r, uptimeS, 3, "1.5", board, l, buf, sizeof(buf));
  std::string out(buf, n);
  check(n <= RELAY_STATUS_LIMIT && std::strlen(buf) == n, "STATUS length", __LINE__, out);
  return out;
}

RelayReply okReply() {
  RelayReply r;
  relayReplyOk(r);
  return r;
}

std::vector<std::string> keys(const std::string& json) {
  std::vector<std::string> k;
  try {
    const jmini::Value v = jmini::parse(json);
    for (const auto& kv : v.o) k.push_back(kv.first);
  } catch (const std::exception& e) {
    check(false, "STATUS is valid JSON", __LINE__, std::string(e.what()) + ": " + json);
  }
  return k;
}

jmini::Value parsed(const std::string& json) {
  try {
    return jmini::parse(json);
  } catch (const std::exception& e) {
    check(false, "STATUS is valid JSON", __LINE__, std::string(e.what()) + ": " + json);
    return jmini::Value::obj();
  }
}

std::string join(const std::vector<std::string>& v) {
  std::string s;
  for (const std::string& x : v) s += (s.empty() ? "" : ",") + x;
  return s;
}

void testStatusExample() {
  // docs/POWER_V3.md B9 example: Heltec, 1.5, idle, low.
  RelaySnapshot s = idleSnapshot();
  s.batMv = 3381;
  s.batPct = 17;
  s.batMah = 400;
  s.runMin = 51;
  s.batLow = true;
  s.cutMv = 3300;
  s.btSleep = true;
  const std::string got = status(s, okReply(), link(24, 2, 400));
  const std::string want =
      "{\"ok\":true,\"running\":true,\"proto\":3,\"fw\":\"1.5\",\"board\":\"HELTEC V3\",\"keepAwake\":false,"
      "\"wakeupPreambleMs\":520,\"commandBurstMs\":4000,\"starlightBurstMs\":500,\"txPowerLevel\":3,"
      "\"txInterleave\":false,\"uptimeS\":8123,\"sent\":42,\"batMv\":3381,\"batPct\":17,\"batMah\":400,"
      "\"runMin\":51,\"batLow\":true,\"cutMv\":3300,\"conn\":[24,2,400],\"btSleep\":true}";
  CHECK_MSG(got == want, got);
  const jmini::Value v = parsed(got);
  CHECK(v.has("conn") && v["conn"].size() == 3 && v["conn"][0].asInt() == 24 && v["conn"][2].asInt() == 400);
}

void testStatusKeys() {
  // Classic ESP32: no battery keys, no cutMv; no link info outside a BLE read: no conn.
  RelaySnapshot s = idleSnapshot();
  std::string j = status(s, okReply(), noLink(), 5, "ESP32");
  CHECK_MSG(join(keys(j)) ==
                "ok,running,proto,fw,board,keepAwake,wakeupPreambleMs,commandBurstMs,starlightBurstMs,txPowerLevel,"
                "txInterleave,uptimeS,sent",
            j);
  CHECK(parsed(j)["proto"].asInt() == 3);

  // Heltec without a battery reading: cutMv still there (0 = off too).
  s.cutMv = 0;
  j = status(s, okReply(), noLink());
  CHECK_MSG(parsed(j).has("cutMv") && parsed(j)["cutMv"].asInt() == 0 && !parsed(j).has("batMv"), j);
  s.cutMv = 3400;
  s.batLow = true;  // no reading: batLow rides with the battery keys, so it is not sent
  j = status(s, okReply(), noLink());
  CHECK_MSG(parsed(j)["cutMv"].asInt() == 3400 && !parsed(j).has("batLow"), j);

  // batLow only when true.
  s.batMv = 3900;
  s.batPct = 65;
  s.batMah = 400;
  s.runMin = 400;
  s.batLow = false;
  j = status(s, okReply(), noLink());
  CHECK_MSG(!parsed(j).has("batLow"), j);
  s.batLow = true;
  j = status(s, okReply(), noLink());
  CHECK_MSG(parsed(j)["batLow"].asBool(), j);
  // Charging: "charging" instead of runMin; batLow still in the battery block (the sketch never
  // sets both, the format keeps the order anyway).
  s.charging = true;
  j = status(s, okReply(), noLink());
  CHECK_MSG(join(keys(j)).find("batMah,charging,batLow,cutMv") != std::string::npos, j);
  s.charging = false;

  // Every key, in order: error, a TX loop with hex + label, catalog impossible with an error.
  RelayReply err;
  relayReplyError(err, "confirm required");
  s.program = RELAY_PROG_TX_LOOP;
  s.intervalMs = 3000;
  const char* hex = "8301CC03000100E100E90C000F0F5D465BF005323748B0";
  relayCanonicalPacket(hex, std::strlen(hex), s.bytes, &s.len);
  std::strcpy(s.label, "Vibrate");
  s.btSleep = true;
  s.advMaxUs = 1234;
  j = status(s, err, link(40, 0, 600));
  CHECK_MSG(join(keys(j)) ==
                "ok,error,running,proto,fw,board,keepAwake,txLoopEnabled,txLoopIntervalMs,wakeupPreambleMs,"
                "commandBurstMs,starlightBurstMs,txPowerLevel,txInterleave,uptimeS,sent,batMv,batPct,batMah,runMin,"
                "batLow,cutMv,txLoopHex,txLoopLabel,conn,btSleep,advMaxUs",
            j);
  CHECK(parsed(j)["error"].asStr() == "confirm required" && parsed(j)["advMaxUs"].asInt() == 1234);

  // items (after a catalog action) sits before the program hex.
  j = status(s, [] {
    RelayReply r = okReply();
    r.items = true;
    return r;
  }(), noLink());
  CHECK_MSG(join(keys(j)).find("cutMv,items,txLoopHex") != std::string::npos, j);

  // advMaxUs 0 (release builds) and btSleep false: no key.
  s.btSleep = false;
  s.advMaxUs = 0;
  j = status(s, okReply(), link(24, 2, 400));
  CHECK_MSG(!parsed(j).has("btSleep") && !parsed(j).has("advMaxUs") && parsed(j).has("conn"), j);
}

// The engine reports no cutMv (the sketch adds it on the Heltec): a classic STATUS has no key.
void testEngineSnapshot() {
  RelaySettings set;
  std::memset(&set, 0, sizeof(set));
  set.wakeMs = 520;
  set.cmdMs = 4000;
  set.starMs = 500;
  set.pingMs = 2000;
  set.powerLevel = 3;
  RelayEngine e;
  e.begin(set, 3000);
  RelaySnapshot s;
  e.snapshot(s);
  CHECK(s.cutMv < 0 && s.batMv < 0 && !s.batLow && !s.btSleep && s.advMaxUs == 0);
  CHECK(!parsed(status(s, okReply(), noLink(), 1, "ESP32")).has("cutMv"));

  // halt(): nothing on air, no program, nothing to come.
  ChipCmd c;
  std::memset(&c, 0, sizeof(c));
  c.type = RELAY_CMD_KEEP_AWAKE;
  c.en = true;
  e.apply(c, 0);
  CHECK(e.program == RELAY_PROG_KEEP_AWAKE && e.job.type == RELAY_JOB_STREAM);
  e.halt();
  uint8_t len = 0;
  CHECK(e.program == RELAY_PROG_NONE && e.job.type == RELAY_JOB_NONE && e.airBytes(&len) == nullptr);
  e.service(100000);
  CHECK(e.job.type == RELAY_JOB_NONE && e.msUntilDue(100000) == RELAY_NO_DEADLINE);
}

// The longest STATUS the board can send: an error, the wand loop at 60000 ms with a 29-byte
// packet and a 16-character label, every battery key with 5-digit values, batLow, cutMv, the
// largest counters, both diagnostics. It stays within 508 bytes, the hex is kept, and what is left
// out is dropped in the order diagnostics -> label -> hex.
void testStatusLimits() {
  const char* errors[] = {"", "busy", "bad mv", "confirm required", "unknown action", "123456789012345678901234"};
  const uint32_t uptimes[] = {5, 8123, 4000000000u};
  const uint32_t sents[] = {0, 42, 4000000000u};
  const char* labels[] = {"", "A", "Vibrate", "1234567890123456"};
  const uint8_t programs[] = {RELAY_PROG_KEEP_AWAKE, RELAY_PROG_TX_LOOP, RELAY_PROG_WAND_LOOP};
  size_t longest = 0;
  std::string longestJson;
  int combos = 0;
  for (const char* error : errors)
    for (uint32_t up : uptimes)
      for (uint32_t sent : sents)
        for (const char* label : labels)
          for (uint8_t program : programs)
            for (int diag = 0; diag < 4; diag++)
              for (int bat = 0; bat < 2; bat++) {
                combos++;
                RelaySnapshot s = idleSnapshot();
                s.program = program;
                s.intervalMs = 60000;
                s.wakeMs = 3000;
                s.cmdMs = 12000;
                s.starMs = 5000;
                s.sent = sent;
                s.len = RELAY_PACKET_MAX;
                for (uint8_t i = 0; i < s.len; i++) s.bytes[i] = (uint8_t)(0xA0 + i);
                std::strcpy(s.label, label);
                if (bat) {
                  s.batMv = 4600;
                  s.batPct = 100;
                  s.batMah = 5000;
                  s.runMin = 59999;
                  s.batLow = true;
                }
                s.cutMv = 3400;
                s.btSleep = diag & 1;
                s.advMaxUs = (diag & 2) ? 2147483647u : 0;
                RelayReply r = okReply();
                if (error[0]) relayReplyError(r, error);
                const RelayLinkInfo l = (diag & 1) ? link(3200, 499, 3200) : noLink();
                const std::string j = status(s, r, l, up, "HELTEC V3");
                const jmini::Value v = parsed(j);
                if (j.size() > longest) {
                  longest = j.size();
                  longestJson = j;
                }
                const char* hexKey = program == RELAY_PROG_KEEP_AWAKE
                                         ? "keepAwakeHex"
                                         : (program == RELAY_PROG_TX_LOOP ? "txLoopHex" : "starlightLoopHex");
                const char* labelKey = program == RELAY_PROG_TX_LOOP
                                           ? "txLoopLabel"
                                           : (program == RELAY_PROG_WAND_LOOP ? "starlightLoopLabel" : nullptr);
                CHECK_MSG(v.has(hexKey) && v[hexKey].asStr().size() == 2u * RELAY_PACKET_MAX, j);
                const bool wantLabel = labelKey && label[0];
                const bool gotLabel = wantLabel && v.has(labelKey);
                if (gotLabel) CHECK_MSG(v[labelKey].asStr() == label, j);
                // Diagnostics never cost the label: the label is dropped only when it would not
                // fit even without them (diagnostics are dropped first).
                RelaySnapshot bare = s;
                bare.btSleep = false;
                bare.advMaxUs = 0;
                const std::string jBare = status(bare, r, noLink(), up, "HELTEC V3");
                CHECK_MSG(parsed(jBare).has(labelKey ? labelKey : hexKey) == (labelKey ? gotLabel : true), jBare + " vs " + j);
                if (wantLabel && !gotLabel) {
                  const size_t labelPart = 2 + std::strlen(labelKey) + 3 + std::strlen(label) + 1;
                  CHECK_MSG(jBare.size() + labelPart > RELAY_STATUS_LIMIT, jBare);
                }
                // A diagnostic is dropped only when it would not have fit (with the closing brace).
                if ((diag & 1) && !v.has("conn")) CHECK_MSG(j.size() + std::strlen(",\"conn\":[3200,499,3200]") > RELAY_STATUS_LIMIT, j);
                if ((diag & 1) && !v.has("btSleep")) CHECK_MSG(j.size() + std::strlen(",\"btSleep\":true") > RELAY_STATUS_LIMIT, j);
                // Everything before the diagnostics is identical with and without them.
                CHECK_MSG(j.compare(0, jBare.size() - 1, jBare, 0, jBare.size() - 1) == 0, jBare + " vs " + j);
                if (bat) CHECK_MSG(v.has("batLow") && v["cutMv"].asInt() == 3400, j);
              }
  CHECK(combos > 0);
  std::printf("  STATUS: %d combinations, longest %zu bytes (limit %u)\n", combos, longest,
              (unsigned)RELAY_STATUS_LIMIT);
  CHECK_MSG(longest <= RELAY_STATUS_LIMIT, longestJson);

  // The everyday statuses keep every diagnostic: idle with a battery, a TX loop with its label.
  RelaySnapshot s = idleSnapshot();
  s.batMv = 3921;
  s.batPct = 68;
  s.batMah = 400;
  s.runMin = 431;
  s.cutMv = 3300;
  s.btSleep = true;
  s.program = RELAY_PROG_WAND_LOOP;
  s.intervalMs = 3000;
  s.len = RELAY_PACKET_MAX;
  std::strcpy(s.label, "1234567890123456");
  const std::string j = status(s, okReply(), link(24, 2, 400), 86400 * 30);
  const jmini::Value v = parsed(j);
  CHECK_MSG(v.has("starlightLoopLabel") && v.has("conn") && v.has("btSleep"), j);
}

}  // namespace

int main() {
  testPowerOff();
  testSetCutoff();
  testNeighbours();
  testStatusExample();
  testStatusKeys();
  testEngineSnapshot();
  testStatusLimits();
  if (g_failures) {
    std::fprintf(stderr, "test_relay: %d of %d checks FAILED\n", g_failures, g_checks);
    return 1;
  }
  std::printf("test_relay: all %d checks passed\n", g_checks);
  return 0;
}

#endif  // ARDUINO
