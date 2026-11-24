// Host test runner for the hub's SYNC v1 C++ codec: replays tools/sync/vectors.json and
// tools/sync/transcripts/*.json (schema: tools/sync/README.md) against sync_codec.h,
// sync_events.h, sync_ledger.h and sync_session.h. It mirrors tools/sync/check_vectors.py group by
// group, but keeps going after a mismatch and prints every failure.
//
//   make -C firmware/esp32-transmitter/test/host test
//   ./build/test_sync <tools/sync dir>          (exit 1 on any mismatch)
//
// Host only (C++17, g++): PlatformIO builds every source under the sketch folder, so this file is
// empty when ARDUINO is defined. (.cc / .hpp, not .cpp / .h: the firmware workflow triggers on
// those.)
#ifndef ARDUINO

#include <dirent.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "../../sync_codec.h"
#include "../../sync_events.h"
#include "../../sync_ledger.h"
#include "../../sync_session.h"
#include "json_mini.hpp"

using jmini::Value;
using namespace mmsync;

namespace {

// ---- bookkeeping --------------------------------------------------------------------------------
std::map<std::string, int> g_checked;
std::vector<std::string> g_groupOrder;
int g_failures = 0;
const int kMaxReported = 60;

void ok(const std::string& group) {
  if (!g_checked.count(group)) g_groupOrder.push_back(group);
  g_checked[group]++;
}

void fail(const std::string& what, const std::string& got, const std::string& want) {
  g_failures++;
  if (g_failures <= kMaxReported) {
    std::printf("FAIL %s\n  got:  %s\n  want: %s\n", what.c_str(), got.c_str(), want.c_str());
  }
}

bool expectEq(const Value& got, const Value& want, const std::string& what) {
  if (jmini::equal(got, want)) return true;
  fail(what, jmini::dump(got), jmini::dump(want));
  return false;
}

bool expectStr(const std::string& got, const std::string& want, const std::string& what) {
  if (got == want) return true;
  fail(what, got, want);
  return false;
}

bool expectInt(int64_t got, int64_t want, const std::string& what) {
  if (got == want) return true;
  fail(what, std::to_string(got), std::to_string(want));
  return false;
}

// ---- conversions ----------------------------------------------------------------------------
typedef std::vector<uint8_t> Bytes;

Bytes unhex(const std::string& h) {
  Bytes out;
  auto nib = [](char c) -> int {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    throw std::runtime_error("bad hex");
  };
  if (h.size() % 2) throw std::runtime_error("odd hex");
  for (size_t i = 0; i < h.size(); i += 2) out.push_back((uint8_t)(nib(h[i]) << 4 | nib(h[i + 1])));
  return out;
}

std::string hex(const uint8_t* p, size_t n) {
  std::string s(2 * n, '0');
  static const char d[] = "0123456789ABCDEF";
  for (size_t i = 0; i < n; i++) {
    s[2 * i] = d[p[i] >> 4];
    s[2 * i + 1] = d[p[i] & 15];
  }
  return s;
}
std::string hex(const Bytes& b) { return hex(b.data(), b.size()); }
std::string hex(const Id8& x) { return hex(x.b, 8); }

Id8 id8(const std::string& h) {
  Bytes b = unhex(h);
  if (b.size() != 8) throw std::runtime_error("id8 size");
  return makeId8(b.data());
}

Value vhex(const uint8_t* p, size_t n) { return Value::str(hex(p, n)); }
Value vnum(int64_t x) { return Value::num(x); }
Value vstr(const std::string& s) { return Value::str(s); }
Value vbool(bool b) { return Value::boolean(b); }
Value vnull() { return Value::null(); }

std::string fmtHex16(uint64_t x) {
  char b[17];
  std::snprintf(b, sizeof(b), "%016llX", (unsigned long long)x);
  return b;
}

Key keyFromJson(const Value& j) {
  Bytes p = unhex(j["packet"].asStr());
  return makeKey((uint8_t)j["ns"].asInt(), p.data(), p.size());
}

Value keyToJson(const Key& k) {
  Value o = Value::obj();
  o.set("ns", vnum(k.ns));
  o.set("packet", vhex(k.packet, k.len));
  return o;
}

std::string keyStr(const Key& k) {
  char b[80];
  keyString(k, b);
  return b;
}

// Body object (README "Body object").
Value bodyToJson(const Body& b) {
  Value o = Value::obj();
  o.set("key", keyToJson(b.key));
  o.set("updatedAt", vnum(b.updatedAt));
  if (b.hasOrigin) o.set("origin", vstr(hex(b.origin)));
  if (b.flags) o.set("flags", vnum(b.flags));
  if (b.labelLen) o.set("label", vstr(std::string((const char*)b.label, b.labelLen)));
  if (b.hasCategory) o.set("category", vnum(b.category));
  if (b.noteLen) o.set("note", vstr(std::string((const char*)b.note, b.noteLen)));
  if (b.kindLen) o.set("kind", vstr(std::string((const char*)b.kind, b.kindLen)));
  if (b.hasPlace) o.set("place", vnum(b.place));
  return o;
}

Body bodyFromJson(const Value& j) {
  Body b;
  clearBody(&b);
  b.key = keyFromJson(j["key"]);
  b.updatedAt = j["updatedAt"].asInt();
  if (j.has("origin")) {
    b.hasOrigin = true;
    b.origin = id8(j["origin"].asStr());
  }
  if (j.has("flags")) b.flags = (uint8_t)j["flags"].asInt();
  auto text = [&](const char* name, uint8_t* dst, uint8_t* len, size_t cap) {
    if (!j.has(name)) return;
    const std::string& s = j[name].asStr();
    if (s.size() > cap) throw std::runtime_error("text too long in vector");
    std::memcpy(dst, s.data(), s.size());
    *len = (uint8_t)s.size();
  };
  text("label", b.label, &b.labelLen, LABEL_MAX);
  text("note", b.note, &b.noteLen, NOTE_MAX);
  text("kind", b.kind, &b.kindLen, KIND_MAX);
  if (j.has("category")) {
    b.hasCategory = true;
    b.category = (uint8_t)j["category"].asInt();
  }
  if (j.has("place")) {
    b.hasPlace = true;
    b.place = (uint8_t)j["place"].asInt();
  }
  return b;
}

// Message fields <-> JSON, driven by the codec's own field tables (names are the §11 names).
Value fieldValueToJson(const FieldSpec& f, const uint8_t* at) {
  if (fieldIsInt(f.kind)) return vnum(loadFieldInt(f, at));
  switch (f.kind) {
    case FK_BYTES:
      return vhex(at, f.size);
    case FK_STR:
      return vstr(std::string((const char*)at + 1, at[0]));
    case FK_PACKET: {
      Packet p;
      std::memcpy(&p, at, sizeof(p));
      return vhex(p.b, p.len);
    }
    case FK_KEY: {
      Key k;
      std::memcpy(&k, at, sizeof(k));
      return keyToJson(k);
    }
    case FK_LINK: {
      HbLink l;
      std::memcpy(&l, at, sizeof(l));
      Value o = Value::obj();
      o.set("peerId", vstr(hex(l.peerId)));
      o.set("peerKind", vnum(l.peerKind));
      o.set("flags", vnum(l.flags));
      return o;
    }
    default: {
      EvtWm e;
      std::memcpy(&e, at, sizeof(e));
      Value o = Value::obj();
      o.set("origin", vstr(hex(e.origin)));
      o.set("epoch", vnum(e.epoch));
      o.set("seq", vnum(e.seq));
      return o;
    }
  }
}

void fieldValueFromJson(const FieldSpec& f, const Value& j, uint8_t* at) {
  if (fieldIsInt(f.kind)) {
    storeFieldInt(f, at, j.asInt());
    return;
  }
  switch (f.kind) {
    case FK_BYTES: {
      Bytes b = unhex(j.asStr());
      if (b.size() != f.size) throw std::runtime_error(std::string("size of ") + f.name);
      std::memcpy(at, b.data(), b.size());
      return;
    }
    case FK_STR: {
      const std::string& s = j.asStr();
      if (s.size() > f.size) throw std::runtime_error(std::string("length of ") + f.name);
      at[0] = (uint8_t)s.size();
      std::memcpy(at + 1, s.data(), s.size());
      return;
    }
    case FK_PACKET: {
      Bytes b = unhex(j.asStr());
      Packet p;
      std::memset(&p, 0, sizeof(p));
      p.len = (uint8_t)b.size();
      std::memcpy(p.b, b.data(), std::min(b.size(), sizeof(p.b)));
      std::memcpy(at, &p, sizeof(p));
      return;
    }
    case FK_KEY: {
      Key k = keyFromJson(j);
      std::memcpy(at, &k, sizeof(k));
      return;
    }
    case FK_LINK: {
      HbLink l;
      l.peerId = id8(j["peerId"].asStr());
      l.peerKind = (uint8_t)j["peerKind"].asInt();
      l.flags = (uint8_t)j["flags"].asInt();
      std::memcpy(at, &l, sizeof(l));
      return;
    }
    default: {
      EvtWm e;
      e.origin = id8(j["origin"].asStr());
      e.epoch = (uint32_t)j["epoch"].asInt();
      e.seq = (uint32_t)j["seq"].asInt();
      std::memcpy(at, &e, sizeof(e));
      return;
    }
  }
}

Value msgToJson(const Msg& m) {
  const MsgSpec* sp = msgSpec(m.type);
  const uint8_t* base = msgBase(&m);
  Value o = Value::obj();
  for (uint8_t k = 0; k < sp->count; k++) {
    const FieldSpec& f = sp->fields[k];
    if (f.rep) {
      const uint8_t cnt = base[f.pres];
      if (!cnt) continue;
      Value a = Value::arr();
      for (uint8_t i = 0; i < cnt; i++) a.push(fieldValueToJson(f, base + f.off + i * fieldElemSize(f)));
      o.set(f.name, a);
    } else if (fieldPresent(f, base)) {
      o.set(f.name, fieldValueToJson(f, base + f.off));
    }
  }
  if (m.type == MSG_REC) {
    const Rec& r = m.rec;
    o.set("bodyHex", vhex(r.body, std::min<size_t>(r.bodyLen, BODY_MAX)));
    if (r.bodyStatus.ok()) {
      Body b;
      decodeBody(r.body, r.bodyLen, &b, nullptr);
      o.set("body", bodyToJson(b));
    } else {
      o.set("bodyError", vstr(errCodeName(r.bodyStatus.code)));
    }
  }
  return o;
}

Msg msgFromJson(uint8_t type, const Value& j) {
  Msg m;
  clearMsg(&m, type);
  const MsgSpec* sp = msgSpec(type);
  uint8_t* base = msgBase(&m);
  for (uint8_t k = 0; k < sp->count; k++) {
    const FieldSpec& f = sp->fields[k];
    const Value* v = j.find(f.name);
    if (!v) continue;
    if (f.rep) {
      if (v->size() > f.rep) throw std::runtime_error("too many items");
      for (size_t i = 0; i < v->size(); i++)
        fieldValueFromJson(f, (*v)[i], base + f.off + i * fieldElemSize(f));
      base[f.pres] = (uint8_t)v->size();
    } else {
      fieldValueFromJson(f, *v, base + f.off);
      if (f.pres != NO_PRES) base[f.pres] = 1;
    }
  }
  if (type == MSG_REC) {
    Bytes b = unhex(j["bodyHex"].asStr());
    if (b.size() > BODY_MAX) throw std::runtime_error("body too long");
    std::memcpy(m.rec.body, b.data(), b.size());
    m.rec.bodyLen = (uint16_t)b.size();
    m.rec.bodyStatus = decodeBody(m.rec.body, m.rec.bodyLen, nullptr, nullptr);
  }
  return m;
}

uint8_t msgTypeByName(const std::string& n) {
  for (uint8_t t = MSG_HELLO; t <= MSG_JOIN; t++)
    if (n == msgTypeName(t)) return t;
  throw std::runtime_error("unknown message type name " + n);
}

std::string encodeHex(const Msg& m) {
  uint8_t buf[2048];
  const size_t n = encodeMsg(m, buf, sizeof(buf));
  return n ? hex(buf, n) : std::string("<encode failed>");
}

Value entryToJson(const LedgerEntry& e) {
  Value o = Value::obj();
  o.set("key", vstr(keyStr(e.key)));
  o.set("u", vnum(e.version.updatedAt));
  o.set("o", e.hasOrigin ? vstr(hex(e.origin)) : vnull());
  o.set("c", vnum(e.version.crc));
  o.set("class", vstr(recordClassName(e.cls)));
  o.set("b", vhex(e.body, e.bodyLen));
  o.set("s", vnum(e.s));
  o.set("f", e.hasSyncFrom ? vstr(hex(e.syncFrom)) : vnull());
  return o;
}

Value ledgerToJson(const Ledger& l) {
  std::vector<LedgerEntry> es = l.entries();
  std::sort(es.begin(), es.end(),
            [](const LedgerEntry& a, const LedgerEntry& b) { return keyStr(a.key) < keyStr(b.key); });
  Value arr = Value::arr();
  for (const auto& e : es) arr.push(entryToJson(e));
  return arr;
}

Value keyListToJson(const std::vector<Key>& ks) {
  Value a = Value::arr();
  for (const auto& k : ks) a.push(vstr(keyStr(k)));
  return a;
}

// ---- primitives -----------------------------------------------------------------------------------
void checkPrimitives(const Value& v) {
  for (const auto& c : v["crc32"].a) {
    Bytes d = unhex(c["hex"].asStr());
    if (expectInt(crc32(d.data(), d.size()), c["crc"].asInt(), "crc32 " + c["name"].asStr())) ok("crc32");
  }
  for (const auto& c : v["fnv1a64"].a) {
    Bytes d = unhex(c["hex"].asStr());
    if (expectStr(fmtHex16(fnv1a64(d.data(), d.size())), c["hash"].asStr(), "fnv " + c["name"].asStr()))
      ok("fnv1a64");
  }
  for (const auto& c : v["sha256"].a) {
    Bytes d = unhex(c["hex"].asStr());
    uint8_t out[32];
    Sha256::digest(d.data(), d.size(), out);
    if (expectStr(hex(out, 32), c["digest"].asStr(), "sha " + c["name"].asStr())) ok("sha256");
  }
  for (const auto& c : v["hmacSha256"].a) {
    Bytes k = unhex(c["keyHex"].asStr()), d = unhex(c["dataHex"].asStr());
    uint8_t mac[32];
    hmacSha256(k.data(), k.size(), d.data(), d.size(), mac);
    bool good = expectStr(hex(mac, 32), c["macHex"].asStr(), c["name"].asStr());
    if (c.has("trunc16Hex")) good = expectStr(hex(mac, 16), c["trunc16Hex"].asStr(), c["name"].asStr()) && good;
    if (good) ok("hmacSha256");
  }
  for (const auto& c : v["groupIds"].a) {
    Bytes k = unhex(c["keyHex"].asStr());
    const Id8 g = groupIdOf(k.data());
    if (expectStr(hex(g), c["groupId"].asStr(), c["name"].asStr()) &&
        expectStr(hex(g.b, 2), c["advertTag"].asStr(), c["name"].asStr()))
      ok("groupIds");
  }
  for (const auto& c : v["proofs"].a) {
    Bytes k = unhex(c["keyHex"].asStr());
    const Id8 nc = id8(c["nonceC"].asStr()), np = id8(c["nonceP"].asStr()), ic = id8(c["idC"].asStr()),
              ip = id8(c["idP"].asStr());
    uint8_t t[32], pp[16], pc[16];
    authTranscript(nc, np, ic, ip, t);
    proofP(k.data(), nc, np, ic, ip, pp);
    proofC(k.data(), nc, np, ic, ip, pc);
    std::string inP = hex(PROOF_P_PREFIX, 8) + hex(t, 32), inC = hex(PROOF_C_PREFIX, 8) + hex(t, 32);
    const std::string n = c["name"].asStr();
    bool good = expectStr(hex(t, 32), c["transcriptHex"].asStr(), "transcript " + n);
    good = expectStr(inP, c["macInputPHex"].asStr(), "macInputP " + n) && good;
    good = expectStr(inC, c["macInputCHex"].asStr(), "macInputC " + n) && good;
    good = expectStr(hex(pp, 16), c["proofP"].asStr(), "proofP " + n) && good;
    good = expectStr(hex(pc, 16), c["proofC"].asStr(), "proofC " + n) && good;
    good = expectStr(hex(groupIdOf(k.data())), c["groupId"].asStr(), "groupId " + n) && good;
    if (good) ok("proofs");
  }
  for (const auto& c : v["textNormalize"].a) {
    Bytes in = unhex(c["inputHex"].asStr());
    const std::string n = c["name"].asStr();
    bool good = expectStr(std::string(in.begin(), in.end()), c["input"].asStr(), "input " + n);
    uint8_t out[256];
    size_t len = 0;
    bool valid;
    if (c["fn"].asStr() == "text") {
      valid = normalizeText(in.data(), in.size(), (size_t)c["maxBytes"].asInt(), out, &len);
    } else {
      valid = normalizeKind(in.data(), in.size(), out, &len);
    }
    good = valid && good;
    if (!valid) fail("normalize " + n, "invalid utf-8", "ok");
    const Value got = len ? vstr(hex(out, len)) : vnull();
    good = expectEq(got, c["outputHex"], "normalize " + n) && good;
    if (good) ok("textNormalize");
  }
  for (const auto& c : v["keys"].a) {
    const Key k = keyFromJson(c);
    uint8_t kb[32];
    const size_t n = encodeKey(k, kb);
    bool good = expectStr(hex(kb, n), c["keyHex"].asStr(), "keyHex");
    good = expectStr(keyStr(k), c["keyString"].asStr(), "keyString") && good;
    good = expectStr(fmtHex16(keyHash(k)), c["fnv1a64"].asStr(), "key fnv") && good;
    Key back;
    good = decodeKey(kb, n, &back).ok() && back == k && good;
    if (good) ok("keys");
  }
}

// ---- bodies, clock, comparator, stamps -------------------------------------------------------------------
void checkBodies(const Value& v) {
  for (const auto& c : v["bodies"].a) {
    const std::string n = c["name"].asStr();
    const Body b = bodyFromJson(c["body"]);
    uint8_t buf[BODY_MAX];
    size_t len = 0;
    const Status es = encodeBody(b, buf, sizeof(buf), &len);
    bool good = expectStr(es.ok() ? hex(buf, len) : std::string("error ") + es.reason, c["hex"].asStr(),
                          "encode " + n);
    Bytes h = unhex(c["hex"].asStr());
    Body back;
    RecordClass cls = CLS_NONE;
    const Status ds = decodeBody(h.data(), h.size(), &back, &cls);
    good = expectStr(ds.ok() ? "ok" : ds.reason, "ok", "decode " + n) && good;
    if (ds.ok()) {
      good = expectEq(bodyToJson(back), c["body"], "decode " + n) && good;
      good = expectStr(recordClassName(cls), c["class"].asStr(), "class " + n) && good;
      const Version ver = versionOf(back, h.data(), h.size());
      good = expectInt(ver.updatedAt, c["version"]["updatedAt"].asInt(), "version.u " + n) && good;
      good = expectStr(fmtHex16(ver.origin), c["version"]["origin"].asStr(), "version.o " + n) && good;
      good = expectInt(ver.crc, c["version"]["crc"].asInt(), "version.c " + n) && good;
    }
    good = expectInt(crc32(h.data(), h.size()), c["crc"].asInt(), "crc " + n) && good;
    good = expectInt((int64_t)h.size(), c["len"].asInt(), "len " + n) && good;
    if (good) ok("bodies");
  }
  for (const auto& c : v["bodyRejects"].a) {
    Bytes h = unhex(c["hex"].asStr());
    const Status s = decodeBody(h.data(), h.size(), nullptr, nullptr);
    const std::string n = c["name"].asStr();
    bool good = expectStr(s.ok() ? "OK" : errCodeName(s.code), c["error"].asStr(), "reject " + n);
    good = expectStr(s.ok() ? "" : s.reason, c["reason"].asStr(), "reject reason " + n) && good;
    if (good) ok("bodyRejects");
  }
  for (const auto& c : v["clock"].a) {
    const std::string n = c["name"].asStr();
    const bool known = !c["now"].isNull();
    const int64_t now = known ? c["now"].asInt() : 0;
    std::string got;
    if (c.has("bodyHex")) {
      Bytes h = unhex(c["bodyHex"].asStr());
      Ledger l;
      LedgerEntry e;
      got = applyStatusName(l.applyRemote(h.data(), h.size(), zeroId8(), known, now, &e, nullptr));
    } else {
      const Status s = checkFuture(c["updatedAt"].asInt(), known, now);
      got = s.ok() ? "OK" : errCodeName(s.code);
    }
    if (expectStr(got, c["result"].asStr(), "clock " + n)) ok("clock");
  }
  for (const auto& c : v["comparator"].a) {
    auto ver = [](const Value& j) {
      Version x;
      x.updatedAt = j["updatedAt"].asInt();
      x.origin = std::stoull(j["origin"].asStr(), nullptr, 16);
      x.crc = (uint32_t)j["crc"].asInt();
      return x;
    };
    const Version a = ver(c["a"]), b = ver(c["b"]);
    const int64_t e = c["expect"].asInt();
    const std::string n = c["name"].asStr();
    if (expectInt(compareVersions(a, b), e, "compare " + n) &&
        expectInt(compareVersions(b, a), -e, "compare reversed " + n))
      ok("comparator");
  }
  for (const auto& c : v["localStamp"].a) {
    if (expectInt(localStamp(c["now"].asInt(), c["ledgerUpdatedAt"].asInt(), c["lastLocalStamp"].asInt()),
                  c["expect"].asInt(), "localStamp " + c["name"].asStr()))
      ok("localStamp");
  }
}

// ---- ledger scripts ----------------------------------------------------------------------------------
void checkApply(const Value& v) {
  for (const auto& sc : v["apply"].a) {
    const std::string name = sc["name"].asStr();
    Ledger led((uint32_t)sc["tombstoneCap"].asInt(), (uint32_t)sc["nextSyncSeq"].asInt());
    bool good = true;
    for (size_t i = 0; i < sc["steps"].size(); i++) {
      const Value& st = sc["steps"][i];
      const std::string what = name + " step " + std::to_string(i);
      const std::string op = st["op"].asStr();
      const Value& ex = st["expect"];
      std::vector<Key> ev;
      if (op == "remote") {
        Bytes h = unhex(st["bodyHex"].asStr());
        const bool known = !st["now"].isNull();
        LedgerEntry e;
        const ApplyStatus s = led.applyRemote(h.data(), h.size(), id8(st["from"].asStr()), known,
                                              known ? st["now"].asInt() : 0, &e, &ev);
        good = expectStr(applyStatusName(s), ex["status"].asStr(), what + " status") && good;
        good = expectEq(keyListToJson(ev), ex["evicted"], what + " evicted") && good;
        good = expectEq(s == APPLY_ACCEPT ? entryToJson(e) : vnull(), ex["entry"], what + " entry") && good;
      } else if (op == "edit") {
        const std::string cls = st["class"].asStr();
        uint8_t c = cls == "USER" ? CLS_USER : cls == "RESET" ? CLS_RESET : cls == "TOMBSTONE" ? CLS_TOMBSTONE
                                                                                                : CLS_NEWWAND;
        EditRequest r = makeEdit(c, keyFromJson(st["key"]), st["now"].asInt(), id8(st["self"].asStr()));
        std::string label, kind, note;
        if (st.has("label")) {
          label = st["label"].asStr();
          r.hasLabel = true;
          r.label = (const uint8_t*)label.data();
          r.labelLen = label.size();
        }
        if (st.has("kind")) {
          kind = st["kind"].asStr();
          r.hasKind = true;
          r.kind = (const uint8_t*)kind.data();
          r.kindLen = kind.size();
        }
        if (st.has("note")) {
          note = st["note"].asStr();
          r.hasNote = true;
          r.note = (const uint8_t*)note.data();
          r.noteLen = note.size();
        }
        if (st.has("category")) {
          r.hasCategory = true;
          r.category = (uint8_t)st["category"].asInt();
        }
        if (st.has("place")) {
          r.hasPlace = true;
          r.place = (uint8_t)st["place"].asInt();
        }
        if (c == CLS_USER) {
          r.preset = st["preset"].asBool();
          r.userEdited = st["userEdited"].asBool();
        }
        LedgerEntry e;
        bool kept = false;
        const Status s = led.localEdit(r, &e, &kept, &ev);
        good = expectStr(s.ok() ? "ok" : s.reason, "ok", what + " edit") && good;
        if (s.ok()) {
          good = expectStr(hex(e.body, e.bodyLen), ex["bodyHex"].asStr(), what + " bodyHex") && good;
          good = expectInt(e.version.updatedAt, ex["updatedAt"].asInt(), what + " updatedAt") && good;
          good = expectEq(keyListToJson(ev), ex["evicted"], what + " evicted") && good;
          if (ex.has("entry")) good = expectEq(kept ? entryToJson(e) : vnull(), ex["entry"], what + " entry") && good;
        }
      } else {
        Bytes p = unhex(st["packet"].asStr());
        LedgerEntry e;
        const bool created = led.localLearn(p.data(), p.size(), &e);
        good = expectEq(vbool(created), ex["created"], what + " created") && good;
        if (ex.has("entry")) good = expectEq(created ? entryToJson(e) : vnull(), ex["entry"], what + " entry") && good;
      }
    }
    const Value& fin = sc["final"];
    good = expectInt(led.nextSyncSeq, fin["nextSyncSeq"].asInt(), name + " nextSyncSeq") && good;
    good = expectInt(led.lastLocalStamp, fin["lastLocalStamp"].asInt(), name + " lastLocalStamp") && good;
    good = expectInt((int64_t)led.tombstoneCount(), fin["tombstones"].asInt(), name + " tombstones") && good;
    good = expectEq(ledgerToJson(led), fin["entries"], name + " entries") && good;
    if (good) ok("apply");
  }
}

// ---- messages ------------------------------------------------------------------------------------
void checkMessages(const Value& v) {
  for (const auto& c : v["messages"].a) {
    const std::string n = c["name"].asStr();
    const uint8_t t = msgTypeByName(c["type"].asStr());
    bool good = expectInt(t, c["typeCode"].asInt(), "typeCode " + n);
    const Msg m = msgFromJson(t, c["fields"]);
    good = expectStr(encodeHex(m), c["hex"].asStr(), "encode " + n) && good;
    Bytes h = unhex(c["hex"].asStr());
    Msg d;
    const Status s = decodeMsg(h.data(), h.size(), &d);
    good = expectStr(s.ok() ? "ok" : s.reason, "ok", "decode " + n) && good;
    if (s.ok()) {
      good = expectInt(d.type, t, "decoded type " + n) && good;
      good = expectEq(msgToJson(d), c["fields"], "decode " + n) && good;
    }
    good = expectInt((int64_t)h.size(), c["len"].asInt(), "len " + n) && good;
    if (good) ok("messages");
  }
  for (const auto& c : v["messageNonCanonical"].a) {
    const std::string n = c["name"].asStr();
    Bytes h = unhex(c["hex"].asStr());
    Msg d;
    const Status s = decodeMsg(h.data(), h.size(), &d);
    bool good = expectStr(s.ok() ? "ok" : s.reason, "ok", "decode " + n);
    if (s.ok()) {
      good = expectStr(msgTypeName(d.type), c["type"].asStr(), "type " + n) && good;
      good = expectEq(msgToJson(d), c["fields"], "fields " + n) && good;
      good = expectStr(encodeHex(d), c["canonicalHex"].asStr(), "canonical " + n) && good;
    }
    if (good) ok("messageNonCanonical");
  }
  for (const auto& c : v["messageRejects"].a) {
    const std::string n = c["name"].asStr();
    Bytes h = unhex(c["hex"].asStr());
    Msg d;
    const Status s = decodeMsg(h.data(), h.size(), &d);
    bool good = expectStr(s.ok() ? "OK" : errCodeName(s.code), c["error"].asStr(), "reject " + n);
    good = expectStr(s.ok() ? "" : s.reason, c["reason"].asStr(), "reject reason " + n) && good;
    if (good) ok("messageRejects");
  }
  for (const auto& c : v["messageBadBody"].a) {
    const std::string n = c["name"].asStr();
    Bytes h = unhex(c["hex"].asStr());
    Msg d;
    const Status s = decodeMsg(h.data(), h.size(), &d);
    bool good = expectStr(s.ok() ? "ok" : s.reason, "ok", "envelope " + n);
    if (s.ok()) {
      good = expectStr(d.rec.bodyStatus.ok() ? "OK" : errCodeName(d.rec.bodyStatus.code),
                       c["bodyError"].asStr(), "bodyError " + n) && good;
      good = expectEq(msgToJson(d), c["fields"], "fields " + n) && good;
      Key k;
      const bool hasKey = bodyErrKey(d.rec.body, d.rec.bodyLen, &k);
      good = expectEq(hasKey ? keyToJson(k) : vnull(), c["errKey"], "errKey " + n) && good;
    }
    if (good) ok("messageBadBody");
  }
  for (const auto& c : v["messageIgnored"].a) {
    Bytes h = unhex(c["hex"].asStr());
    Msg d;
    const Status s = decodeMsg(h.data(), h.size(), &d);
    if (expectStr(s.ok() && !d.known ? "ignored" : (s.ok() ? "decoded" : s.reason), "ignored",
                  "ignored " + c["name"].asStr()))
      ok("messageIgnored");
  }
  for (const auto& c : v["hbHops"].a) {
    Bytes h = unhex(c["inHex"].asStr());
    const bool done = hbSetHops(h.data(), h.size(), 1);
    if (expectStr(done ? hex(h) : "<no hops>", c["outHex"].asStr(), "hbHops " + c["name"].asStr())) ok("hbHops");
  }
}

// ---- frames ----------------------------------------------------------------------------------------
Value reasmToJson(const ReasmResult& r) {
  Value a = Value::arr();
  for (uint8_t i = 0; i < r.n; i++) {
    Value o = Value::obj();
    switch (r.ev[i].kind) {
      case RA_DELIVER:
        o.set("deliver", vhex(r.msg, r.msgLen));
        break;
      case RA_BAD_FRAME:
        o.set("badFrame", vstr(badFrameName(r.ev[i].value)));
        break;
      case RA_ERR_TOO_BIG:
        o.set("errTooBig", vnum(r.ev[i].value));
        break;
      default:
        o.set("errProto", vnum(r.ev[i].value));
        break;
    }
    a.push(o);
  }
  return a;
}

std::vector<std::string> fragmentHex(Fragmenter& fr, const Bytes& msg, uint16_t mtu) {
  std::vector<std::string> out;
  fr.fragment(msg.data(), msg.size(), mtu,
              [&](const uint8_t* f, size_t n) { out.push_back(hex(f, n)); });
  return out;
}

void checkFrames(const Value& v) {
  for (const auto& c : v["frames"].a) {
    const std::string n = c["name"].asStr();
    Fragmenter fr;
    fr.reset((uint8_t)c["startCounter"].asInt(), (uint8_t)c["startSeq"].asInt());
    const uint16_t mtu = (uint16_t)c["mtu"].asInt();
    Value frames = Value::arr();
    Value per = Value::arr();
    for (const auto& m : c["messages"].a) {
      Bytes b = unhex(m.asStr());
      auto fs = fragmentHex(fr, b, mtu);
      per.push(vnum((int64_t)fs.size()));
      if ((int64_t)fs.size() != (int64_t)frameCount(b.size(), mtu)) fail("frameCount " + n, "", "");
      for (auto& f : fs) frames.push(vstr(f));
    }
    bool good = expectEq(frames, c["frames"], "frames " + n);
    good = expectEq(per, c["framesPerMessage"], "framesPerMessage " + n) && good;
    good = expectInt((int64_t)chunkSize(mtu), c["chunk"].asInt(), "chunk " + n) && good;
    if (good) ok("frames");
  }
  for (const auto& c : v["reassembly"].a) {
    Reassembler<1024> ra((uint16_t)c["maxMsg"].asInt());
    if (c.has("startExpectedSeq")) ra.expected = (uint8_t)c["startExpectedSeq"].asInt();
    Value got = Value::arr();
    for (const auto& f : c["frames"].a) {
      Bytes b = unhex(f.asStr());
      Value part = reasmToJson(ra.feed(b.data(), b.size()));
      for (auto& x : part.a) got.push(x);
    }
    if (expectEq(got, c["expect"], "reassembly " + c["name"].asStr())) ok("reassembly");
  }
}

// ---- pages ------------------------------------------------------------------------------------------
void checkPages(const Value& v) {
  for (const auto& c : v["pages"].a) {
    const std::string n = c["name"].asStr();
    const Msg pm = msgFromJson(MSG_PULL, c["pull"]);
    bool good = expectStr(encodeHex(pm), c["pullHex"].asStr(), "pullHex " + n);
    PageServer ps;
    ps.begin(pm.pull, (uint32_t)c["durableHigh"].asInt(), c["excludeOk"].asBool(), id8(c["puller"].asStr()));
    Value recs = Value::arr(), seqs = Value::arr();
    for (const auto& e : c["entries"].a) {
      Bytes body = unhex(e["bodyHex"].asStr());
      Body b;
      decodeBody(body.data(), body.size(), &b, nullptr);
      Id8 from;
      const bool hasFrom = !e["syncFrom"].isNull();
      if (hasFrom) from = id8(e["syncFrom"].asStr());
      uint8_t out[512];
      size_t len = 0;
      const PageStep st = ps.offer((uint32_t)e["seq"].asInt(), body.data(), body.size(),
                                   b.hasOrigin ? &b.origin : nullptr, hasFrom ? &from : nullptr, out,
                                   sizeof(out), &len);
      if (st == PAGE_STOP) break;
      if (st == PAGE_SEND) {
        recs.push(vhex(out, len));
        seqs.push(vnum(e["seq"].asInt()));
      }
    }
    const PageEnd pe = ps.end();
    Msg em;
    clearMsg(&em, MSG_PAGE_END);
    em.pageEnd = pe;
    good = expectEq(recs, c["expect"]["recs"], "recs " + n) && good;
    good = expectEq(seqs, c["expect"]["recSeqs"], "recSeqs " + n) && good;
    good = expectEq(msgToJson(em), c["expect"]["pageEnd"], "pageEnd " + n) && good;
    good = expectStr(encodeHex(em), c["expect"]["pageEndHex"].asStr(), "pageEndHex " + n) && good;
    if (good) ok("pages");
  }
}

// ---- routing ----------------------------------------------------------------------------------------
std::vector<RouteSession> routeSessions(const Value& arr, const char* subKey, const char* okKey) {
  std::vector<RouteSession> out;
  for (const auto& s : arr.a) {
    RouteSession r;
    r.peer = id8(s["peer"].asStr());
    r.sub = s[subKey].asBool();
    r.ok = s[okKey].asBool();
    out.push_back(r);
  }
  return out;
}

std::vector<Id8> idList(const Value& arr) {
  std::vector<Id8> out;
  for (const auto& x : arr.a) out.push_back(id8(x.asStr()));
  return out;
}

Value routeToJson(const Route& r, const std::vector<RouteSession>& s) {
  Value o = Value::obj(), t = Value::arr(), sb = Value::arr();
  for (uint8_t i = 0; i < r.nTargets; i++) t.push(vstr(hex(s[r.targets[i]].peer)));
  for (uint8_t i = 0; i < r.nSeen; i++) sb.push(vstr(hex(r.seenBy[i])));
  o.set("targets", t);
  o.set("seenBy", sb);
  return o;
}

void checkRouting(const Value& v) {
  const Value& r = v["routing"];
  for (const auto& c : r["localRec"].a) {
    auto s = routeSessions(c["sessions"], "subRecords", "authed");
    const Route rt = routeLocalRec(id8(c["self"].asStr()), s.data(), s.size());
    if (expectEq(routeToJson(rt, s), c["expect"], "localRec " + c["name"].asStr())) ok("routing.localRec");
  }
  for (const auto& c : r["liveRec"].a) {
    auto s = routeSessions(c["sessions"], "subRecords", "authed");
    auto seen = idList(c["seenBy"]);
    Id8 origin;
    const bool hasOrigin = !c["origin"].isNull();
    if (hasOrigin) origin = id8(c["origin"].asStr());
    const Route rt = routeLiveRec(id8(c["self"].asStr()), id8(c["sender"].asStr()), hasOrigin ? &origin : nullptr,
                                  seen.data(), seen.size(), s.data(), s.size());
    if (expectEq(routeToJson(rt, s), c["expect"], "liveRec " + c["name"].asStr())) ok("routing.liveRec");
  }
  for (const auto& c : r["evtRelay"].a) {
    auto s = routeSessions(c["sessions"], "subEvents", "member");
    auto seen = idList(c["seenBy"]);
    const Route rt = routeEvtRelay(id8(c["self"].asStr()), id8(c["sender"].asStr()), id8(c["origin"].asStr()),
                                   seen.data(), seen.size(), s.data(), s.size());
    if (expectEq(routeToJson(rt, s), c["expect"], "evtRelay " + c["name"].asStr())) ok("routing.evtRelay");
  }
  for (const auto& c : r["androidRoute"].a) {
    AndroidSessionView ios, hub;
    std::memset(&ios, 0, sizeof(ios));
    std::memset(&hub, 0, sizeof(hub));
    if (!c["ios"].isNull()) {
      ios.present = true;
      ios.peer = id8(c["ios"]["peer"].asStr());
      ios.up = c["ios"]["up"].asBool();
      ios.subEvents = c["ios"]["subEvents"].asBool();
    }
    if (!c["hub"].isNull()) {
      hub.present = true;
      hub.peer = id8(c["hub"]["peer"].asStr());
      hub.up = c["hub"]["up"].asBool();
    }
    std::vector<HbLink> links;
    for (const auto& l : c["hubHbLinks"].a) {
      HbLink x;
      x.peerId = id8(l["peerId"].asStr());
      x.peerKind = (uint8_t)l["peerKind"].asInt();
      x.flags = (uint8_t)l["flags"].asInt();
      links.push_back(x);
    }
    const bool known = !c["hubHbAgeMs"].isNull();
    const EvtRoute er = androidEventRoute(id8(c["self"].asStr()), ios, hub, known,
                                          known ? (uint32_t)c["hubHbAgeMs"].asInt() : 0, links.data(), links.size());
    Value o = Value::obj(), sb = Value::arr();
    o.set("route", vnum(er.route));
    o.set("target", er.hasTarget ? vstr(hex(er.target)) : vnull());
    for (uint8_t i = 0; i < er.nSeen; i++) sb.push(vstr(hex(er.seenBy[i])));
    o.set("seenBy", sb);
    if (expectEq(o, c["expect"], "androidRoute " + c["name"].asStr())) ok("routing.androidRoute");
  }
  for (const auto& c : r["hbForward"].a) {
    auto s = routeSessions(c["sessions"], "subHeartbeats", "member");
    uint8_t idx[16];
    const uint8_t n = routeHb(id8(c["self"].asStr()), id8(c["sender"].asStr()), id8(c["deviceId"].asStr()),
                              (uint8_t)c["hops"].asInt(), s.data(), s.size(), idx);
    Value o = Value::obj(), t = Value::arr();
    for (uint8_t i = 0; i < n; i++) t.push(vstr(hex(s[idx[i]].peer)));
    o.set("targets", t);
    if (expectEq(o, c["expect"], "hbForward " + c["name"].asStr())) ok("routing.hbForward");
  }
  for (const auto& c : r["hbReplace"].a) {
    const bool have = !c["stored"].isNull();
    const bool got = hbReplaces(have, have ? (uint16_t)c["stored"]["bootId"].asInt() : 0,
                                have ? (uint32_t)c["stored"]["hbSeq"].asInt() : 0,
                                (uint16_t)c["incoming"]["bootId"].asInt(), (uint32_t)c["incoming"]["hbSeq"].asInt());
    if (expectEq(vbool(got), c["expect"], "hbReplace " + c["name"].asStr())) ok("routing.hbReplace");
  }
  for (const auto& c : r["subs"].a) {
    if (expectInt(subsFor((uint8_t)c["selfKind"].asInt(), (uint8_t)c["peerKind"].asInt()), c["subs"].asInt(),
                  "subs"))
      ok("routing.subs");
  }
  for (const auto& c : r["caps"].a) {
    if (expectInt(capsForKind((uint8_t)c["kind"].asInt()), c["caps"].asInt(), "caps")) ok("routing.caps");
  }
}

// ---- events -----------------------------------------------------------------------------------------
Value windowsToJson(const EvtDedupe<4>& d, const Id8& origin) {
  const EvtWindow* ws[EVT_EPOCHS_KEPT];
  const uint8_t n = d.windows(origin, ws);
  Value a = Value::arr();
  for (uint8_t i = 0; i < n; i++) {
    Value o = Value::obj();
    o.set("epoch", vnum(ws[i]->epoch));
    o.set("hc", vnum(ws[i]->hc));
    o.set("bits", vstr(fmtHex16(ws[i]->bits)));
    a.push(o);
  }
  return a;
}

void checkEvents(const Value& v) {
  for (const auto& sc : v["eventDedupe"].a) {
    EvtDedupe<4> d;
    bool good = true;
    for (size_t i = 0; i < sc["steps"].size(); i++) {
      const Value& st = sc["steps"][i];
      const Id8 o = id8(st["origin"].asStr());
      const uint32_t epoch = (uint32_t)st["epoch"].asInt();
      Value got = Value::obj();
      if (st["op"].asStr() == "evt") {
        uint32_t lost = 0;
        const EvtResult res = d.receive(o, epoch, (uint32_t)st["seq"].asInt(), &lost);
        got.set("result", vstr(res == EVT_ACCEPT ? "ACCEPT" : "DUPLICATE"));
        got.set("lost", vnum(lost));
        got.set("holes", vbool(d.hasHoles(o, epoch)));
        got.set("windows", windowsToJson(d, o));
      } else {
        uint32_t lost = 0;
        EvtRequest req;
        const uint8_t nr = d.onGap(o, epoch, (uint32_t)st["firstAvail"].asInt(), (uint32_t)st["lastAvail"].asInt(),
                                   (uint32_t)st["curEpoch"].asInt(), &lost, &req);
        got.set("lost", vnum(lost));
        Value reqs = Value::arr();
        if (nr) {
          Value q = Value::obj();
          q.set("epoch", vnum(req.epoch));
          q.set("afterSeq", vnum(req.afterSeq));
          reqs.push(q);
        }
        got.set("requests", reqs);
        got.set("windows", windowsToJson(d, o));
      }
      good = expectEq(got, st["expect"], sc["name"].asStr() + " step " + std::to_string(i)) && good;
    }
    if (good) ok("eventDedupe");
  }
  for (const auto& c : v["replayPlan"].a) {
    std::vector<RingEvt> ring;
    for (const auto& e : c["ring"].a) {
      RingEvt x;
      x.epoch = (uint32_t)e[0].asInt();
      x.seq = (uint32_t)e[1].asInt();
      ring.push_back(x);
    }
    Value got = Value::arr();
    replayPlan(ring.data(), ring.size(), (uint32_t)c["curEpoch"].asInt(), (uint32_t)c["curSeq"].asInt(),
               (uint32_t)c["epoch"].asInt(), (uint32_t)c["afterSeq"].asInt(), [&](const PlanItem& p) {
                 Value o = Value::obj(), in = Value::obj();
                 in.set("epoch", vnum(p.epoch));
                 if (p.gap) {
                   in.set("firstAvail", vnum(p.firstAvail));
                   in.set("lastAvail", vnum(p.lastAvail));
                   in.set("curEpoch", vnum(p.curEpoch));
                   o.set("gap", in);
                 } else {
                   in.set("seq", vnum(p.seq));
                   o.set("replay", in);
                 }
                 got.push(o);
               });
    if (expectEq(got, c["expect"], "replayPlan " + c["name"].asStr())) ok("replayPlan");
  }
}

// ---- sessions --------------------------------------------------------------------------------------
class TestNode final : public SessionNode {
 public:
  bool clockKnown = false;
  int64_t clockBase = 0;
  std::vector<Id8> nonces;
  size_t nextNonceIdx = 0;
  std::map<std::string, PeerState> peers;
  bool nonceUnderflow = false;

  int64_t clockMs(uint32_t t) override { return clockKnown ? clockBase + (int64_t)t : 0; }
  void nextNonce(uint8_t out[8]) override {
    if (nextNonceIdx < nonces.size()) {
      std::memcpy(out, nonces[nextNonceIdx++].b, 8);
    } else {
      nonceUnderflow = true;
      std::memset(out, 0xEE, 8);
    }
  }
  PeerState* findPeer(const Id8& id) override {
    auto it = peers.find(hex(id));
    return it == peers.end() ? nullptr : &it->second;
  }
  PeerState* peer(const Id8& id) override {
    PeerState* p = findPeer(id);
    if (p) return p;
    PeerState fresh;
    fresh.dbId = zeroId8();
    fresh.wm = 0;
    fresh.excludeOk = false;
    return &(peers[hex(id)] = fresh);
  }

  void setGroup(const Value& gid, const Value& gkey) {
    std::memset(&group, 0, sizeof(group));
    if (!gid.isNull()) {
      group.grouped = true;
      group.id = id8(gid.asStr());
      Bytes k = unhex(gkey.asStr());
      std::memcpy(group.key, k.data(), 16);
    }
  }
};

Value peerToJson(const PeerState& p) {
  Value o = Value::obj();
  o.set("dbId", vstr(hex(p.dbId)));
  o.set("wm", vnum(p.wm));
  o.set("excludeOk", vbool(p.excludeOk));
  return o;
}

Value actionsToJson(const ActionList& l) {
  Value a = Value::arr();
  for (size_t i = 0; i < l.size(); i++) {
    const Action& x = l[i];
    Value o = Value::obj();
    switch (x.kind) {
      case ACT_SEND:
        o.set("a", vstr("send"));
        o.set("type", vstr(msgTypeName(x.msgType)));
        o.set("hex", vhex(l.bytes(x), x.len));
        break;
      case ACT_STATE:
        o.set("a", vstr("state"));
        o.set("to", vstr(sessionStateName(x.state)));
        break;
      case ACT_DELIVER:
        o.set("a", vstr("deliver"));
        o.set("type", vstr(msgTypeName(x.msgType)));
        break;
      case ACT_COMMIT:
        o.set("a", vstr("commit"));
        o.set("wm", vnum(x.value));
        break;
      case ACT_GROUP:
        o.set("a", vstr("group"));
        o.set("groupId", vhex(l.bytes(x), 8));
        o.set("groupKey", vhex(l.bytes(x) + 8, 16));
        o.set("rekey", vbool(x.rekey));
        break;
      case ACT_NODE:
        o.set("a", vstr("node"));
        o.set("what", vstr(nodeWhatName(x.what)));
        break;
      default:
        o.set("a", vstr("disconnect"));
        o.set("reason", vstr(disconnectReasonName(x.reason)));
        o.set("retryMs", x.hasRetry ? vnum(x.value) : vnull());
        break;
    }
    a.push(o);
  }
  if (l.overflowed()) a.push(vstr("<action list overflow>"));
  return a;
}

Value snapshot(Session& s) {
  Value o = Value::obj(), tm = Value::obj();
  o.set("state", vstr(sessionStateName(s.state())));
  for (uint8_t i = 0; i < TM_COUNT; i++)
    if (s.timerArmed((TimerId)i)) tm.set(timerName(i), vnum(s.timerDue((TimerId)i)));
  o.set("timers", tm);
  PeerState* p = s.peerEntry();
  if (p) o.set("peer", peerToJson(*p));
  return o;
}

TimerId timerByName(const std::string& n) {
  for (uint8_t i = 0; i < TM_COUNT; i++)
    if (n == timerName(i)) return (TimerId)i;
  throw std::runtime_error("unknown timer " + n);
}

void checkSessions(const Value& v) {
  for (const auto& sc : v["sessions"].a) {
    const std::string name = sc["name"].asStr();
    const Value& cj = sc["config"];
    const Value& xj = sc["ctx"];
    SessionConfig cfg;
    std::memset(&cfg, 0, sizeof(cfg));
    cfg.role = cj["role"].asStr() == "central" ? ROLE_CENTRAL : ROLE_PERIPHERAL;
    cfg.deviceId = id8(cj["deviceId"].asStr());
    cfg.kind = (uint8_t)cj["kind"].asInt();
    cfg.bootId = (uint16_t)cj["bootId"].asInt();
    cfg.maxMsg = (uint16_t)cj["maxMsg"].asInt();
    cfg.caps = cj["caps"].isNull() ? capsForKind(cfg.kind) : (uint16_t)cj["caps"].asInt();
    const std::string version = cj["version"].isNull() ? "" : cj["version"].asStr();
    const std::string nodeName = cj["name"].isNull() ? "" : cj["name"].asStr();
    cfg.version = version.c_str();
    cfg.name = nodeName.c_str();
    cfg.peerKind = cj["peerKind"].isNull() ? 0 : (uint8_t)cj["peerKind"].asInt();
    cfg.tracksEvents = cj["tracksEvents"].asBool();
    cfg.isHub = cj["isHub"].isNull() ? cfg.kind == KIND_HUB : cj["isHub"].asBool();

    TestNode node;
    node.setGroup(xj["groupId"], xj["groupKey"]);
    node.dbId = id8(xj["dbId"].asStr());
    node.feedHigh = (uint32_t)xj["feedHigh"].asInt();
    node.ready = xj["ready"].asBool();
    node.clockKnown = !xj["clockBaseMs"].isNull();
    node.clockBase = node.clockKnown ? xj["clockBaseMs"].asInt() : 0;
    for (const auto& n : xj["nonces"].a) node.nonces.push_back(id8(n.asStr()));
    for (const auto& kv : xj["peers"].o) {
      PeerState p;
      p.dbId = id8(kv.second["dbId"].asStr());
      p.wm = (uint32_t)kv.second["wm"].asInt();
      p.excludeOk = kv.second["excludeOk"].asBool();
      node.peers[kv.first] = p;
    }

    Session s;
    s.attach(&cfg, &node);
    bool good = true;
    for (size_t i = 0; i < sc["steps"].size(); i++) {
      const Value& st = sc["steps"][i];
      if (st.has("ctx")) {
        const Value& c = st["ctx"];
        node.setGroup(c["groupId"], c["groupKey"]);
        node.dbId = id8(c["dbId"].asStr());
        node.feedHigh = (uint32_t)c["feedHigh"].asInt();
        node.ready = c["ready"].asBool();
      }
      const uint32_t t = (uint32_t)st["t"].asInt();
      const Value& in = st["in"];
      const std::string kind = in["in"].asStr();
      const ActionList* out;
      Bytes data;
      if (kind == "link_up") {
        out = &s.linkUp(t, in.has("mtu") ? (uint16_t)in["mtu"].asInt() : 185);
      } else if (kind == "link_down") {
        out = &s.linkDown(t);
      } else if (kind == "rx") {
        data = unhex(in["hex"].asStr());
        out = &s.rx(t, data.data(), data.size());
      } else if (kind == "timer") {
        out = &s.timer(t, timerByName(in["name"].asStr()));
      } else if (kind == "group_changed") {
        out = &s.groupChanged(t);
      } else if (kind == "rekey") {
        out = &s.rekey(t);
      } else if (kind == "pull_now") {
        out = &s.pullNow(t);
      } else {
        throw std::runtime_error("unknown input " + kind);
      }
      const std::string what = name + " step " + std::to_string(i) + " (" + kind + ")";
      good = expectEq(actionsToJson(*out), st["out"], what) && good;
      good = expectEq(snapshot(s), st["after"], what + " snapshot") && good;
    }
    if (node.nonceUnderflow) {
      fail(name + " nonces", "ran out", "enough");
      good = false;
    }
    if (good) ok("sessions");
  }
}

// ---- transcripts -------------------------------------------------------------------------------------
struct LinkInfo {
  std::string central, peripheral;
  uint16_t mtu;
};

void checkTranscript(const std::string& path) {
  const Value j = jmini::parseFile(path);
  const std::string base = path.substr(path.find_last_of('/') + 1);
  std::map<std::string, Bytes> keys;  // groupId hex -> key
  std::map<std::string, uint16_t> maxMsg;
  for (const auto& kv : j["nodes"].o) {
    const Value& n = kv.second;
    if (n.has("groupKey") && !n["groupKey"].isNull()) keys[n["groupId"].asStr()] = unhex(n["groupKey"].asStr());
    maxMsg[kv.first] = n.has("maxMsg") && !n["maxMsg"].isNull() ? (uint16_t)n["maxMsg"].asInt() : PHONE_MAXMSG;
  }
  std::map<std::string, Fragmenter> frag;
  std::map<std::string, Reassembler<1024>> reasm;
  std::map<std::string, LinkInfo> links;
  std::map<std::string, Hello> helloC, helloP;
  bool good = true;
  for (const auto& st : j["steps"].a) {
    const std::string ev = st["ev"].asStr();
    if (ev == "link_up") {
      LinkInfo li{st["central"].asStr(), st["peripheral"].asStr(), (uint16_t)st["mtu"].asInt()};
      const std::string link = st["link"].asStr();
      links[link] = li;
      for (const std::string& who : {li.central, li.peripheral}) {
        frag[link + "|" + who] = Fragmenter();
        reasm[link + "|" + who].reset(maxMsg.count(who) ? maxMsg[who] : PHONE_MAXMSG);
      }
      continue;
    }
    if (ev != "msg") continue;
    const std::string link = st["link"].asStr(), from = st["from"].asStr(), to = st["to"].asStr();
    const std::string what = base + " step " + std::to_string(st["i"].asInt()) + " " + st["type"].asStr();
    Bytes data = unhex(st["hex"].asStr());
    Msg m;
    const Status s = decodeMsg(data.data(), data.size(), &m);
    if (st["fields"].isNull()) {
      good = expectStr(s.ok() ? "decoded" : errCodeName(s.code), "BAD_MSG", what + " decodeError") && good;
    } else {
      good = expectStr(s.ok() ? "ok" : s.reason, "ok", what + " decode") && good;
      if (s.ok()) {
        good = expectEq(msgToJson(m), st["fields"], what + " fields") && good;
        good = expectStr(encodeHex(m), st["hex"].asStr(), what + " re-encode") && good;
        const LinkInfo& li = links[link];
        if (m.type == MSG_JOIN) {
          keys[hex(m.join.groupId)] = Bytes(m.join.groupKey, m.join.groupKey + 16);
          good = expectStr(hex(groupIdOf(m.join.groupKey)), hex(m.join.groupId), what + " groupId") && good;
        }
        if (m.type == MSG_HELLO && from == li.central) {
          helloC[link] = m.hello;
        } else if (m.type == MSG_HELLO && m.hello.hasProof) {
          const Hello& hc = helloC[link];
          const Bytes& key = keys[hex(m.hello.groupId)];
          uint8_t pp[16];
          proofP(key.data(), hc.nonce, m.hello.nonce, hc.deviceId, m.hello.deviceId, pp);
          good = expectStr(hex(m.hello.proof, 16), hex(pp, 16), what + " proofP") && good;
          helloP[link] = m.hello;
        } else if (m.type == MSG_AUTH && helloP.count(link) && st["by"].asStr() == "session") {
          const Hello& hc = helloC[link];
          const Hello& hp = helloP[link];
          const Bytes& key = keys[hex(hp.groupId)];
          uint8_t pc[16];
          proofC(key.data(), hc.nonce, hp.nonce, hc.deviceId, hp.deviceId, pc);
          good = expectStr(hex(m.auth.proof, 16), hex(pc, 16), what + " proofC") && good;
        }
      }
    }
    auto frames = fragmentHex(frag[link + "|" + from], data, links[link].mtu);
    Value fv = Value::arr();
    for (auto& f : frames) fv.push(vstr(f));
    good = expectEq(fv, st["frames"], what + " frames") && good;
    Value got = Value::arr();
    for (auto& f : frames) {
      Bytes fb = unhex(f);
      Value part = reasmToJson(reasm[link + "|" + to].feed(fb.data(), fb.size()));
      for (auto& x : part.a) got.push(x);
    }
    Value want = Value::arr(), d = Value::obj();
    d.set("deliver", vstr(st["hex"].asStr()));
    want.push(d);
    good = expectEq(got, want, what + " reassembly") && good;
    ok("transcript messages");
  }
  for (const auto& kv : j["final"]["nodes"].o) {
    for (const auto& e : kv.second["ledger"].a) {
      Bytes b = unhex(e["b"].asStr());
      Body body;
      RecordClass cls;
      const Status s = decodeBody(b.data(), b.size(), &body, &cls);
      const std::string what = base + " final " + kv.first + " " + e["key"].asStr();
      good = expectStr(s.ok() ? "ok" : s.reason, "ok", what + " body") && good;
      if (!s.ok()) continue;
      good = expectStr(keyStr(body.key), e["key"].asStr(), what + " key") && good;
      good = expectInt(crc32(b.data(), b.size()), e["c"].asInt(), what + " crc") && good;
      good = expectInt(body.updatedAt, e["u"].asInt(), what + " u") && good;
      good = expectStr(recordClassName(cls), e["class"].asStr(), what + " class") && good;
    }
  }
  if (good) ok("transcripts");
}

// ---- constants and completeness ------------------------------------------------------------------
// Every protocol constant in vectors.json must equal the C++ one. A constant the table below does
// not know fails too, so a new constant in the generator gets reviewed on the C++ side.
void checkConstants(const Value& v) {
  struct Num {
    const char* name;
    int64_t value;
  };
  static const Num nums[] = {
      {"proto", PROTO},
      {"frameVersion", FRAME_VERSION},
      {"frameHeaderLen", (int64_t)FRAME_HEADER_LEN},
      {"attOverhead", (int64_t)ATT_OVERHEAD},
      {"mtuMin", MTU_MIN},
      {"mtuMax", MTU_MAX},  // not in vectors.json (yet); listed so it is checked once it is
      {"smallMtuBelow", SMALL_MTU_BELOW},
      {"maxMsgMin", MAXMSG_MIN},
      {"hubMaxMsg", HUB_MAXMSG},
      {"phoneMaxMsg", PHONE_MAXMSG},
      {"packetMin", PACKET_MIN},
      {"packetMax", PACKET_MAX},
      {"labelMax", LABEL_MAX},
      {"noteMax", NOTE_MAX},
      {"kindMax", KIND_MAX},
      {"bodyMax", BODY_MAX},
      {"seenByMax", SEENBY_MAX},
      {"hbLinksMax", HB_LINKS_MAX},
      {"hbEvtWmMax", HB_EVTWM_MAX},
      {"uPresence", U_PRESENCE},
      {"uLegacyAndroid", U_LEGACY_ANDROID},
      {"uLegacyIos", U_LEGACY_IOS},
      {"uMinMs", U_MIN_MS},
      {"futureBoundMs", FUTURE_BOUND_MS},
      {"pullLimitDefault", PULL_LIMIT_DEFAULT},
      {"pullMaxBytesDefault", PULL_MAXBYTES_DEFAULT},
      {"pullLimitSmall", PULL_LIMIT_SMALL},
      {"pullMaxBytesSmall", PULL_MAXBYTES_SMALL},
      {"pullMaxBytesMin", PULL_MAXBYTES_MIN},
      {"helloTimeoutMs", T_HELLO_MS},
      {"helloTries", HELLO_TRIES},
      {"incompatibleRetryMs", T_RETRY_INCOMPATIBLE_MS},
      {"authTimeoutMs", T_AUTH_MS},
      {"memberDeadlineMs", T_DEADLINE_MS},
      {"pageTimeoutMs", T_PAGE_MS},
      {"pageTries", PAGE_TRIES},
      {"pageFailRetryMs", T_PAGE_FAIL_RETRY_MS},
      {"livePullMs", T_LIVE_PULL_MS},
      {"hbIntervalMs", T_HB_MS},
      {"hbSpacingMs", T_HB_SPACING_MS},
      {"pathFreshMs", T_PATH_FRESH_MS},
      {"notReadyRetryMs", NOT_READY_RETRY_MS},
      {"busyRetryMs", BUSY_RETRY_MS},
      {"defaultRetryMs", DEFAULT_RETRY_MS},
      {"evtWindowBits", EVT_WINDOW_BITS},
      {"evtEpochsKept", EVT_EPOCHS_KEPT},
      {"evtReplayDedupeMs", EVT_REPLAY_DEDUPE_MS},
      {"evtRingAndroid", EVT_RING_ANDROID},  // not in vectors.json (yet)
      {"tombstoneCapPhone", TOMBSTONE_CAP_PHONE},
  };
  const Value& c = v["constants"];
  for (const auto& kv : c.o) {
    const std::string& k = kv.first;
    const Value& x = kv.second;
    const std::string what = "constant " + k;
    bool good = true;
    bool known = true;
    if (k == "fixtures") {
      continue;  // test fixtures (keys, ids), not protocol constants
    } else if (k == "fnv64Offset") {
      good = expectStr(fmtHex16(FNV64_OFFSET), x.asStr(), what);
    } else if (k == "fnv64Prime") {
      good = expectStr(fmtHex16(FNV64_PRIME), x.asStr(), what);
    } else if (k == "groupIdPrefix") {
      good = expectStr(hex(GROUP_ID_PREFIX, 8), x.asStr(), what);
    } else if (k == "proofPPrefix") {
      good = expectStr(hex(PROOF_P_PREFIX, 8), x.asStr(), what);
    } else if (k == "proofCPrefix") {
      good = expectStr(hex(PROOF_C_PREFIX, 8), x.asStr(), what);
    } else if (k == "messageTypes" || k == "errorCodes") {
      const bool types = k == "messageTypes";
      good = expectInt((int64_t)x.o.size(), types ? (int64_t)MSG_JOIN : (int64_t)E_NOT_READY,
                       what + " count");
      for (const auto& e : x.o) {
        const int64_t code = e.second.asInt();
        const std::string got = types ? msgTypeName((uint8_t)code) : errCodeName((uint8_t)code);
        good = expectStr(got, e.first, what + " " + std::to_string(code)) && good;
        if (types) good = expectStr(msgSpec((uint8_t)code) ? "spec" : "none", "spec", what + " spec") && good;
      }
    } else {
      known = false;
      for (const Num& n : nums) {
        if (k != n.name) continue;
        known = true;
        good = expectInt(n.value, x.asInt(), what);
      }
    }
    if (!known) {
      fail(what, "not in the C++ constants table (test_sync.cc checkConstants)", jmini::dump(x));
      good = false;
    }
    if (good) ok("constants");
  }
}

// Every item of every group must have been checked and passed: a group the generator emptied or
// renamed, or an item a check skipped, fails here instead of silently shrinking the coverage.
void checkComplete(const Value& v, size_t transcripts, size_t transcriptMsgs) {
  auto need = [](const std::string& group, size_t want) {
    const int got = g_checked.count(group) ? g_checked[group] : 0;
    if (want == 0) fail("completeness " + group, "an empty group", "at least one item");
    if ((size_t)got != want)
      fail("completeness " + group, std::to_string(got) + " passed", std::to_string(want) + " items");
  };
  for (const auto& kv : v.o) {
    if (kv.first == "routing") {
      for (const auto& r : kv.second.o) need("routing." + r.first, r.second.size());
    } else if (kv.second.t == Value::ARR) {
      need(kv.first, kv.second.size());
    }
  }
  need("transcripts", transcripts);
  need("transcript messages", transcriptMsgs);
}

size_t countTranscriptMsgs(const std::vector<std::string>& paths) {
  size_t n = 0;
  for (const auto& p : paths) {
    const Value j = jmini::parseFile(p);  // a named value: the steps must outlive the loop
    for (const auto& st : j["steps"].a)
      if (st["ev"].asStr() == "msg") n++;
  }
  return n;
}

std::vector<std::string> listTranscripts(const std::string& dir) {
  std::vector<std::string> out;
  DIR* d = opendir(dir.c_str());
  if (!d) return out;
  while (dirent* e = readdir(d)) {
    const std::string n = e->d_name;
    if (n.size() > 5 && n.compare(n.size() - 5, 5, ".json") == 0) out.push_back(dir + "/" + n);
  }
  closedir(d);
  std::sort(out.begin(), out.end());
  return out;
}

}  // namespace

int main(int argc, char** argv) {
  const std::string dir = argc > 1 ? argv[1] : "../../../../tools/sync";
  try {
    const Value v = jmini::parseFile(dir + "/vectors.json");
    if (v["schema"].asInt() != 1 || v["proto"].asInt() != PROTO) {
      std::printf("FAIL unexpected schema/proto\n");
      return 1;
    }
    checkConstants(v);
    checkPrimitives(v);
    checkBodies(v);
    checkApply(v);
    checkMessages(v);
    checkFrames(v);
    checkPages(v);
    checkRouting(v);
    checkEvents(v);
    checkSessions(v);
    const auto ts = listTranscripts(dir + "/transcripts");
    if (ts.empty()) fail("transcripts", "none found", dir + "/transcripts/*.json");
    for (const auto& p : ts) checkTranscript(p);
    checkComplete(v, ts.size(), countTranscriptMsgs(ts));
  } catch (const std::exception& e) {
    std::printf("FAIL exception: %s\n", e.what());
    return 1;
  }
  std::string summary;
  for (const auto& g : g_groupOrder) {
    if (!summary.empty()) summary += ", ";
    summary += g + " " + std::to_string(g_checked[g]);
  }
  if (g_failures) {
    std::printf("%d failure(s)%s\npassed: %s\n", g_failures,
                g_failures > kMaxReported ? " (first ones shown)" : "", summary.c_str());
    return 1;
  }
  std::printf("all SYNC vectors pass (C++): %s\n", summary.c_str());
  return 0;
}

#endif  // ARDUINO
