// Host simulation for the hub node tests (docs/SYNC_P2_FIRMWARE_PLAN.md §5.13): a C++ port of
// tools/sync/gen_vectors.py `Sim` and of its phone `Node` (kinds 2 and 3), plus the adapter that
// runs a real mmsync::HubNode (hub_node.h) as node H through its ports.
//
//   Sim        the discrete-event queue ((t, insertion) order, like heapq in the generator), links
//              with one Fragmenter per sender and one Reassembler per receiver, the step log in the
//              transcript format (tools/sync/README.md "Steps"), and two network models: the
//              transcript's (15 ms, whole messages, disconnects land 16 ms later) and the loopback's
//              (per-frame random latency, drops, refused notifies).
//   Phone      the iPhone / Android node of the generator on the P1 core: Session per link,
//              FakeLedger, page serving with PageServer, live push and forwarding, the 300 ms save
//              debounce, HB build / round / forwarding, Android events (ring, route 1/2/3, replay
//              plan, EVT_GAP) and the iPhone's EvtDedupe, EVT_SINCE and gap handling.
//   Scripted   a raw node that only sends what the scenario gives it (X, Y, Z in the transcripts).
//   SimHub     HubNode + FakeHubDb + FakeGate + a radio FIFO + the event-queue Scheduler (or the
//              production TaskTable) + a clock + a scripted Rng + fixed SelfInfo + a step tracer.
//
// Host only (C++17): PlatformIO builds every source under the sketch folder, so this file is empty
// when ARDUINO is defined.
#pragma once
#if !defined(ARDUINO)

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <new>
#include <queue>
#include <random>
#include <set>
#include <string>
#include <tuple>
#include <vector>

#include "../../hub_clock.h"
#include "../../hub_node.h"
#include "../../hub_tasks.h"
#include "../../sync_crypto.h"
#include "fake_hub_db.h"
#include "json_mini.hpp"

namespace hubsim {

using namespace mmsync;
using jmini::Value;
typedef std::vector<uint8_t> Bytes;

static const int64_t SIM_BASE_MS = 1796000000000LL;  // gen_vectors BASE_MS
static const uint32_t PHONE_SAVE_DEBOUNCE_MS = 300;

// ---- conversions ----------------------------------------------------------------------------------
inline std::string hexOf(const uint8_t* p, size_t n) {
  static const char d[] = "0123456789ABCDEF";
  std::string s(2 * n, '0');
  for (size_t i = 0; i < n; i++) {
    s[2 * i] = d[p[i] >> 4];
    s[2 * i + 1] = d[p[i] & 15];
  }
  return s;
}
inline std::string hexOf(const Bytes& b) { return hexOf(b.data(), b.size()); }
inline std::string hexOf(const Id8& x) { return hexOf(x.b, 8); }

inline Bytes unhex(const std::string& h) {
  Bytes out;
  auto nib = [](char c) -> int {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
  };
  for (size_t i = 0; i + 1 < h.size(); i += 2) out.push_back((uint8_t)(nib(h[i]) << 4 | nib(h[i + 1])));
  return out;
}
inline Id8 toId8(const std::string& h) {
  Bytes b = unhex(h);
  Id8 x = zeroId8();
  if (b.size() == 8) memcpy(x.b, b.data(), 8);
  return x;
}
inline std::string keyStr(const Key& k) {
  char b[80];
  keyString(k, b);
  return b;
}

inline Value vS(const std::string& s) { return Value::str(s); }
inline Value vN(int64_t x) { return Value::num(x); }
inline Value vB(bool b) { return Value::boolean(b); }
inline Value vNull() { return Value::null(); }

inline const char* dbResultName(uint8_t r) {
  static const char* const n[] = {"?",    "ACCEPT",    "DUPLICATE", "STALE", "BAD_MSG",
                                  "CLOCK", "FULL", "COLLISION", "BUSY", "NOT_READY"};
  return r <= DBR_NOT_READY ? n[r] : "?";
}

inline Value entryJson(const FakeEntry& e) {
  Value o = Value::obj();
  o.set("key", vS(keyStr(e.key)));
  o.set("u", vN(e.version.updatedAt));
  o.set("o", e.hasOrigin ? vS(hexOf(e.origin)) : vNull());
  o.set("c", vN(e.version.crc));
  o.set("class", vS(recordClassName(e.cls)));
  o.set("b", vS(hexOf(e.body, e.bodyLen)));
  o.set("s", vN(e.s));
  o.set("f", e.hasF ? vS(hexOf(e.f)) : vNull());
  return o;
}

inline Value ledgerJson(const FakeLedger& l) {
  std::vector<std::pair<std::string, const FakeEntry*>> v;
  for (size_t i = 0; i < l.entries.size(); i++) v.push_back(std::make_pair(keyStr(l.entries[i].key), &l.entries[i]));
  std::sort(v.begin(), v.end(), [](const std::pair<std::string, const FakeEntry*>& a,
                                   const std::pair<std::string, const FakeEntry*>& b) { return a.first < b.first; });
  Value a = Value::arr();
  for (auto& x : v) a.push(entryJson(*x.second));
  return a;
}

inline Value peerJson(const PeerState& p) {
  Value o = Value::obj();
  o.set("dbId", vS(hexOf(p.dbId)));
  o.set("wm", vN(p.wm));
  o.set("excludeOk", vB(p.excludeOk));
  return o;
}

// gen_vectors Node.gen_nonce: SHA-256("mm-sync-nonce:" + id + u32le(n))[0..7]
inline void simNonce(const Id8& id, uint32_t n, uint8_t out[8]) {
  Sha256 s;
  static const char pre[] = "mm-sync-nonce:";
  s.update(reinterpret_cast<const uint8_t*>(pre), sizeof(pre) - 1);
  s.update(id.b, 8);
  uint8_t le[4] = {(uint8_t)n, (uint8_t)(n >> 8), (uint8_t)(n >> 16), (uint8_t)(n >> 24)};
  s.update(le, 4);
  uint8_t d[32];
  s.finish(d);
  memcpy(out, d, 8);
}

// ---- network models ---------------------------------------------------------------------------------
struct NetParams {
  bool loopback = false;       // false: the transcript model (whole messages, fixed latency)
  uint32_t latMs = 15;         // transcript latency (gen_vectors LAT_MS)
  uint32_t latMin = 5;         // loopback: per-frame latency range
  uint32_t latMax = 80;
  uint32_t dropPerMille = 0;   // loopback: frames lost
  uint32_t refusePerMille = 0; // loopback: Radio::sendFrame refused (the hub retries)
  uint32_t seed = 1;
};

class Sim;

class SimNode {
 public:
  std::string name;
  uint8_t kind = 0;
  Id8 id = zeroId8();
  bool scripted = false;
  uint16_t maxMsg = PHONE_MAXMSG;
  Sim* sim = nullptr;

  virtual ~SimNode() {}
  virtual bool isHub() const { return false; }
  virtual void linkUp(const std::string& lid, bool central, SimNode* peer, uint16_t mtu) = 0;
  virtual void linkDown(const std::string& lid) = 0;
  virtual void rx(const std::string& lid, const Bytes& msg) = 0;
  virtual void rxFrame(const std::string& lid, const Bytes& frame) {
    (void)lid;
    (void)frame;
  }
  virtual void rxFramesDone(const std::string& lid) { (void)lid; }
};

struct SimLink {
  std::string id, c, p;
  uint16_t mtu = 23;
  int gen = 0;
  bool up = false;
  Fragmenter fragFromC, fragFromP;
  Reassembler<1024> reasmAtC, reasmAtP;
  uint64_t lastArrAtC = 0, lastArrAtP = 0;
  std::deque<uint64_t> hubOut;  // pending hub -> peer messages (ids), in send order
};

struct HubPending {
  std::string lid;
  int gen;
  size_t step;
  Bytes msg;
  Value frames = Value::arr();
  Bytes got;
  bool done = false;
};

class Sim {
 public:
  struct Ev {
    uint64_t t;
    uint64_t n;
    std::function<void()> fn;
  };
  struct EvLater {
    bool operator()(const Ev& a, const Ev& b) const { return a.t != b.t ? a.t > b.t : a.n > b.n; }
  };

  uint64_t t = 0;
  uint64_t n = 0;
  int64_t base = SIM_BASE_MS;
  NetParams net;
  std::mt19937 rng{1};
  std::priority_queue<Ev, std::vector<Ev>, EvLater> q;
  std::vector<Value> steps;
  std::map<std::string, SimNode*> nodes;
  std::map<std::string, SimLink> links;
  std::map<std::string, int> gens;
  std::map<uint64_t, HubPending> pendings;
  uint64_t pendingIds = 0;
  std::vector<std::string> errors;
  uint32_t framesDropped = 0;
  uint32_t framesRefused = 0;
  // every message a node queues on a link (loopback invariants)
  std::function<void(const SimLink&, const SimNode* from, const SimNode* to, const Bytes&)> onMsg;
  // every scenario or node link_down (auto-relink in loopback)
  std::function<void(const std::string& lid, const std::string& reason)> onLinkDown;

  void setNet(const NetParams& p) {
    net = p;
    rng.seed(p.seed);
  }

  void add(SimNode* node) {
    nodes[node->name] = node;
    node->sim = this;
  }

  void at(uint64_t when, std::function<void()> fn) {
    Ev e;
    e.t = when;
    e.n = n++;
    e.fn = std::move(fn);
    q.push(std::move(e));
  }

  void run(uint64_t until) {
    while (!q.empty() && q.top().t <= until) {
      Ev e = q.top();
      q.pop();
      t = e.t;
      e.fn();
    }
    t = until;
  }

  void error(const std::string& s) {
    if (errors.size() < 50) errors.push_back("t=" + std::to_string(t) + " " + s);
  }

  Value step(const char* ev) {
    Value o = Value::obj();
    o.set("t", vN((int64_t)t));
    o.set("ev", vS(ev));
    return o;
  }
  size_t log(Value v) {
    steps.push_back(std::move(v));
    return steps.size() - 1;
  }

  SimNode* other(const SimLink& L, const SimNode* from) { return nodes[from->name == L.c ? L.p : L.c]; }

  uint32_t randLat() {
    if (net.latMax <= net.latMin) return net.latMin;
    return net.latMin + (uint32_t)(rng() % (net.latMax - net.latMin + 1));
  }
  bool chance(uint32_t perMille) { return perMille && (rng() % 1000) < perMille; }

  // ---- links --------------------------------------------------------------------------------------
  void linkUp(const std::string& lid, const std::string& c, const std::string& p, uint16_t mtu) {
    const int gen = ++gens[lid];
    SimLink& L = links[lid];
    L = SimLink();
    L.id = lid;
    L.c = c;
    L.p = p;
    L.mtu = mtu;
    L.gen = gen;
    L.up = true;
    L.reasmAtC.reset(nodes[c]->maxMsg);
    L.reasmAtP.reset(nodes[p]->maxMsg);
    Value s = step("link_up");
    s.set("link", vS(lid));
    s.set("gen", vN(gen));
    s.set("central", vS(c));
    s.set("peripheral", vS(p));
    s.set("mtu", vN(mtu));
    log(s);
    nodes[p]->linkUp(lid, false, nodes[c], mtu);
    nodes[c]->linkUp(lid, true, nodes[p], mtu);
  }

  void linkDown(const std::string& lid, const std::string& reason) {
    auto it = links.find(lid);
    if (it == links.end() || !it->second.up) return;
    it->second.up = false;
    Value s = step("link_down");
    s.set("link", vS(lid));
    s.set("reason", vS(reason));
    log(s);
    const std::string p = it->second.p, c = it->second.c;
    nodes[p]->linkDown(lid);
    nodes[c]->linkDown(lid);
    for (uint64_t id : it->second.hubOut) pendings.erase(id);
    it->second.hubOut.clear();
    if (onLinkDown) onLinkDown(lid, reason);
  }

  void scheduleDisconnect(const std::string& lid, const std::string& reason) {
    auto it = links.find(lid);
    if (it == links.end() || !it->second.up) return;
    const int gen = it->second.gen;
    const uint32_t d = net.loopback ? net.latMax + 1 : net.latMs + 1;
    at(t + d, [this, lid, gen, reason]() {
      auto i2 = links.find(lid);
      if (i2 != links.end() && i2->second.gen == gen && i2->second.up) linkDown(lid, reason);
    });
  }

  Value msgStep(const SimLink& L, const SimNode* from, const SimNode* to, const Bytes& data) {
    Value s = step("msg");
    s.set("link", vS(L.id));
    s.set("gen", vN(L.gen));
    s.set("from", vS(from->name));
    s.set("to", vS(to->name));
    s.set("type", vS(data.empty() ? "?" : msgTypeName(data[0])));
    s.set("hex", vS(hexOf(data)));
    return s;
  }

  // A phone or scripted node sends a whole message.
  void send(const std::string& lid, SimNode* from, const Bytes& data) {
    auto it = links.find(lid);
    if (it == links.end() || !it->second.up) return;
    SimLink& L = it->second;
    SimNode* to = other(L, from);
    Fragmenter& fr = from->name == L.c ? L.fragFromC : L.fragFromP;
    std::vector<Bytes> frames;
    fr.fragment(data.data(), data.size(), L.mtu,
                [&frames](const uint8_t* f, size_t k) { frames.push_back(Bytes(f, f + k)); });
    Value s = msgStep(L, from, to, data);
    Value fv = Value::arr();
    for (auto& f : frames) fv.push(vS(hexOf(f)));
    s.set("frames", fv);
    log(s);
    if (onMsg) onMsg(L, from, to, data);
    const int gen = L.gen;
    const std::string toName = to->name;
    if (!net.loopback) {
      at(t + net.latMs, [this, lid, gen, toName, frames]() { deliver(lid, gen, toName, frames); });
      return;
    }
    for (auto& f : frames) scheduleFrame(L, toName, f);
  }

  void scheduleFrame(SimLink& L, const std::string& toName, const Bytes& f) {
    if (chance(net.dropPerMille)) {
      framesDropped++;
      return;
    }
    uint64_t& last = toName == L.c ? L.lastArrAtC : L.lastArrAtP;
    uint64_t arr = t + randLat();
    if (arr < last) arr = last;
    last = arr;
    const std::string lid = L.id;
    const int gen = L.gen;
    std::vector<Bytes> one(1, f);
    at(arr, [this, lid, gen, toName, one]() { deliver(lid, gen, toName, one); });
  }

  void deliver(const std::string& lid, int gen, const std::string& toName, const std::vector<Bytes>& frames) {
    auto it = links.find(lid);
    if (it == links.end() || it->second.gen != gen || !it->second.up) return;
    SimLink& L = it->second;
    SimNode* to = nodes[toName];
    if (to->isHub()) {
      for (auto& f : frames) to->rxFrame(lid, f);
      to->rxFramesDone(lid);
      return;
    }
    Reassembler<1024>& ra = toName == L.c ? L.reasmAtC : L.reasmAtP;
    for (auto& f : frames) {
      const ReasmResult r = ra.feed(f.data(), f.size());
      for (uint8_t k = 0; k < r.n; k++) {
        if (r.ev[k].kind == RA_DELIVER) {
          const Bytes msg(r.msg, r.msg + r.msgLen);
          to->rx(lid, msg);
          auto i2 = links.find(lid);  // the receiver may not take the link down, but be safe
          if (i2 == links.end() || i2->second.gen != gen || !i2->second.up) return;
        } else if (!net.loopback) {
          error("reassembly event " + std::to_string(r.ev[k].kind) + " at " + toName + " on " + lid);
        }
      }
    }
  }

  // ---- hub messages: traced at enqueue, frames come later through the radio -----------------------
  void hubSent(const std::string& lid, SimNode* hub, const uint8_t* msg, size_t len) {
    auto it = links.find(lid);
    if (it == links.end() || !it->second.up) {
      error("hub queued a message on link " + lid + " that is down");
      return;
    }
    SimLink& L = it->second;
    SimNode* to = other(L, hub);
    const Bytes data(msg, msg + len);
    Value s = msgStep(L, hub, to, data);
    s.set("frames", Value::arr());
    const size_t idx = log(s);
    if (onMsg) onMsg(L, hub, to, data);
    if (net.loopback) return;  // frames travel one by one (hubFrameOut)
    const uint64_t pid = ++pendingIds;
    HubPending& p = pendings[pid];
    p.lid = lid;
    p.gen = L.gen;
    p.step = idx;
    p.msg = data;
    L.hubOut.push_back(pid);
    const int gen = L.gen;
    const std::string toName = to->name;
    at(t + net.latMs, [this, lid, gen, pid, toName]() { deliverHub(lid, gen, pid, toName); });
  }

  // Radio::sendFrame of the hub. false = refused (loopback only).
  bool hubFrameOut(const std::string& lid, SimNode* hub, const uint8_t* f, size_t len) {
    auto it = links.find(lid);
    if (it == links.end() || !it->second.up) {
      error("hub sent a frame on link " + lid + " that is down");
      return true;
    }
    SimLink& L = it->second;
    const std::string toName = other(L, hub)->name;
    const Bytes frame(f, f + len);
    if (net.loopback) {
      if (chance(net.refusePerMille)) {
        framesRefused++;
        return false;
      }
      scheduleFrame(L, toName, frame);
      return true;
    }
    HubPending* p = nullptr;
    for (uint64_t id : L.hubOut) {
      auto pi = pendings.find(id);
      if (pi != pendings.end() && !pi->second.done) {
        p = &pi->second;
        break;
      }
    }
    if (!p) {
      error("hub frame " + hexOf(frame) + " on " + lid + " belongs to no queued message");
      return true;
    }
    p->frames.push(vS(hexOf(frame)));
    Reassembler<1024>& ra = toName == L.c ? L.reasmAtC : L.reasmAtP;
    const ReasmResult r = ra.feed(frame.data(), frame.size());
    for (uint8_t k = 0; k < r.n; k++) {
      if (r.ev[k].kind != RA_DELIVER) {
        error("hub frames do not reassemble on " + lid);
        continue;
      }
      p->got.assign(r.msg, r.msg + r.msgLen);
      p->done = true;
      steps[p->step].set("frames", p->frames);
      if (p->got != p->msg) error("hub frames reassemble to " + hexOf(p->got) + " not " + hexOf(p->msg));
    }
    return true;
  }

  void deliverHub(const std::string& lid, int gen, uint64_t pid, const std::string& toName) {
    auto pi = pendings.find(pid);
    if (pi == pendings.end()) return;  // the link went down
    auto it = links.find(lid);
    if (it == links.end() || it->second.gen != gen || !it->second.up) {
      pendings.erase(pi);
      return;
    }
    SimLink& L = it->second;
    if (!pi->second.done) {
      error("hub message " + hexOf(pi->second.msg) + " on " + lid + " not fully framed by its delivery time");
      return;
    }
    const Bytes msg = pi->second.got;
    for (auto q2 = L.hubOut.begin(); q2 != L.hubOut.end(); ++q2) {
      if (*q2 == pid) {
        L.hubOut.erase(q2);
        break;
      }
    }
    pendings.erase(pi);
    nodes[toName]->rx(lid, msg);
  }

  // ---- step helpers -------------------------------------------------------------------------------
  void logState(const std::string& node, const std::string& lid, uint8_t st) {
    Value s = step("state");
    s.set("node", vS(node));
    s.set("link", vS(lid));
    s.set("state", vS(sessionStateName(st)));
    log(s);
  }
  void logDisconnect(const std::string& node, const std::string& lid, const std::string& reason, bool hasRetry,
                     uint32_t retry) {
    Value s = step("disconnect");
    s.set("node", vS(node));
    s.set("link", vS(lid));
    s.set("reason", vS(reason));
    s.set("retryMs", hasRetry ? vN(retry) : vNull());
    log(s);
  }
  void logSimple(const char* ev, const std::string& node, const std::string& lid) {
    Value s = step(ev);
    s.set("node", vS(node));
    s.set("link", vS(lid));
    log(s);
  }
  void logTimer(const std::string& node, const std::string& lid, uint8_t id) {
    Value s = step("timer");
    s.set("node", vS(node));
    s.set("link", vS(lid));
    s.set("name", vS(timerName(id)));
    log(s);
  }
  void logApply(const std::string& node, const std::string& lid, const Key* key, const char* status, bool live) {
    Value s = step("apply");
    s.set("node", vS(node));
    s.set("link", vS(lid));
    s.set("key", key ? vS(keyStr(*key)) : vNull());
    s.set("status", vS(status));
    s.set("live", vB(live));
    log(s);
  }
  void logDurable(const std::string& node, uint32_t dh) {
    Value s = step("durable");
    s.set("node", vS(node));
    s.set("durableHigh", vN(dh));
    log(s);
  }
  void logGroup(const std::string& node, const std::string& lid, const Id8& gid, bool rekey) {
    Value s = step("group");
    s.set("node", vS(node));
    s.set("link", vS(lid));
    s.set("groupId", vS(hexOf(gid)));
    s.set("rekey", vB(rekey));
    log(s);
  }
};

// ---- a raw scripted peer (gen_vectors ScriptedNode) ------------------------------------------------
class ScriptedNode : public SimNode {
 public:
  std::vector<Bytes> received;
  ScriptedNode(const std::string& nm, uint8_t k, const Id8& i) {
    name = nm;
    kind = k;
    id = i;
    scripted = true;
  }
  void linkUp(const std::string&, bool, SimNode*, uint16_t) override {}
  void linkDown(const std::string&) override {}
  void rx(const std::string&, const Bytes& msg) override { received.push_back(msg); }
  void sendRaw(const std::string& lid, const Bytes& data) { sim->send(lid, this, data); }
};

// ---- the stand-in phone (gen_vectors Node, kinds 2 and 3) --------------------------------------------
class Phone : public SimNode, public SessionNode {
 public:
  struct Core {
    std::string lid;
    int gen = 0;
    SessionConfig cfg;
    Session s;
    std::set<std::pair<int, uint32_t>> timerKeys;
  };
  struct RingItem {
    uint32_t epoch;
    uint32_t seq;
    Evt f;
  };

  uint16_t bootId = 0;
  std::string version, devname;
  uint16_t caps = 0;
  bool clockKnown = true;
  FakeLedger ledger;
  uint32_t durableHigh = 0;
  std::map<std::string, PeerState> peers;  // hex id -> state (stable addresses)
  std::vector<std::unique_ptr<Core>> cores;  // attach order
  uint32_t nonceN = 0;
  uint32_t hbSeq = 0;
  int64_t lastHbT = -1000000000LL;
  bool hbRoundPending = false;
  bool pageAccepted = false;
  bool savePending = false;
  int8_t battPct = -1;
  int16_t battMv = -1;
  int8_t charging = -1;
  int16_t runtimeMin = -1;
  uint16_t stateBits = 0;
  bool hasHubAirAgo = false;
  uint16_t hubAirAgo = 0;
  bool hasHubHb = false;
  uint64_t hubHbT = 0;
  std::vector<HbLink> hubHbLinks;
  // Android events
  uint32_t epoch = 0;
  uint32_t evtSeq = 0;
  size_t ringCap = EVT_RING_ANDROID;
  std::deque<RingItem> ring;
  std::map<std::tuple<std::string, uint32_t, uint32_t>, uint64_t> replaysServed;
  // iPhone events
  EvtDedupe<4> dedupe;
  std::vector<Id8> origins;
  std::map<std::pair<std::string, uint32_t>, uint32_t> sinceSent;
  Bytes rxRaw;
  // loopback bookkeeping
  uint32_t ingestAccepted = 0;

  Phone(const std::string& nm, uint8_t k, const Id8& devId) {
    name = nm;
    kind = k;
    id = devId;
    caps = capsForKind(k);
    maxMsg = PHONE_MAXMSG;
  }

  // ---- SessionNode ----
  int64_t clockMs(uint32_t tt) override { return clockKnown ? sim->base + (int64_t)tt : 0; }
  void nextNonce(uint8_t out[8]) override { simNonce(id, nonceN++, out); }
  PeerState* findPeer(const Id8& pid) override {
    auto it = peers.find(hexOf(pid));
    return it == peers.end() ? nullptr : &it->second;
  }
  PeerState* peer(const Id8& pid) override {
    const std::string k = hexOf(pid);
    auto it = peers.find(k);
    if (it != peers.end()) return &it->second;
    PeerState ps;
    ps.dbId = zeroId8();
    ps.wm = 0;
    ps.excludeOk = false;
    return &(peers[k] = ps);
  }

  int64_t nowMs() const { return sim->base + (int64_t)sim->t; }
  uint32_t t32() const { return (uint32_t)sim->t; }

  Core* core(const std::string& lid) {
    for (auto& c : cores)
      if (c->lid == lid) return c.get();
    return nullptr;
  }

  // ---- SimNode ----
  void linkUp(const std::string& lid, bool central, SimNode* peerNode, uint16_t mtu) override {
    std::unique_ptr<Core> c(new Core());
    c->lid = lid;
    c->gen = sim->links[lid].gen;
    memset(&c->cfg, 0, sizeof(c->cfg));
    c->cfg.role = central ? ROLE_CENTRAL : ROLE_PERIPHERAL;
    c->cfg.deviceId = id;
    c->cfg.kind = kind;
    c->cfg.bootId = bootId;
    c->cfg.maxMsg = maxMsg;
    c->cfg.caps = caps;
    c->cfg.version = version.empty() ? NULL : version.c_str();
    c->cfg.name = devname.empty() ? NULL : devname.c_str();
    c->cfg.peerKind = central ? peerNode->kind : 0;
    c->cfg.tracksEvents = kind == KIND_IOS;
    c->cfg.isHub = false;
    c->s.attach(&c->cfg, this);
    for (auto it = cores.begin(); it != cores.end(); ++it) {
      if ((*it)->lid == lid) {
        cores.erase(it);
        break;
      }
    }
    cores.push_back(std::move(c));
    input(lid, [this, mtu](Session& s) -> const ActionList& { return s.linkUp(t32(), mtu); });
  }

  void linkDown(const std::string& lid) override {
    input(lid, [this](Session& s) -> const ActionList& { return s.linkDown(t32()); });
    for (auto it = cores.begin(); it != cores.end(); ++it) {
      if ((*it)->lid == lid) {
        cores.erase(it);
        break;
      }
    }
  }

  void rx(const std::string& lid, const Bytes& msg) override {
    rxRaw = msg;
    input(lid, [this, &msg](Session& s) -> const ActionList& { return s.rx(t32(), msg.data(), msg.size()); });
  }

  // ---- core_input ----
  template <class F>
  void input(const std::string& lid, F call) {
    Core* c = core(lid);
    if (!c) return;
    feedHigh = durableHigh;
    ready = true;
    const ActionList& acts = call(c->s);
    process(lid, c, acts);
  }

  void send(const std::string& lid, const uint8_t* p, size_t k) { sim->send(lid, this, Bytes(p, p + k)); }
  template <class M>
  void sendMsg(const std::string& lid, const M& m) {
    uint8_t buf[1100];
    const size_t k = encode(m, buf, sizeof(buf));
    if (!k) {
      sim->error(name + ": encode failed");
      return;
    }
    send(lid, buf, k);
  }

  void process(const std::string& lid, Core* c, const ActionList& acts) {
    std::vector<bool> deferred;
    for (size_t i = 0; i < acts.size(); i++) {
      const Action& a = acts[i];
      switch (a.kind) {
        case ACT_SEND:
          send(lid, acts.bytes(a), a.len);
          break;
        case ACT_STATE:
          sim->logState(name, lid, a.state);
          break;
        case ACT_DELIVER:
          onDeliver(lid, c, a.msgType);
          break;
        case ACT_COMMIT:
          saveNow();
          break;
        case ACT_GROUP:
          sim->logGroup(name, lid, makeId8(acts.bytes(a)), a.rekey);
          deferred.push_back(a.rekey);
          break;
        case ACT_NODE:
          if (a.what == NODE_SEND_HB) {
            std::vector<std::string> one(1, lid);
            sendHb(one);
          } else if (a.what == NODE_EVT_SINCE) {
            sendEvtSinceAll(lid);
          } else if (a.what == NODE_FOREIGN) {
            sim->logSimple("foreign", name, lid);
          }
          break;
        case ACT_DISCONNECT:
          sim->logDisconnect(name, lid, disconnectReasonName(a.reason), a.hasRetry, a.value);
          sim->scheduleDisconnect(lid, disconnectReasonName(a.reason));
          break;
        default:
          break;
      }
    }
    if (core(lid)) syncTimers(lid);
    for (bool rk : deferred) {
      std::vector<std::string> others;
      for (auto& oc : cores)
        if (oc->lid != lid) others.push_back(oc->lid);
      for (auto& o : others) {
        Core* oc = core(o);
        if (!oc) continue;
        if (rk && oc->s.authed()) {
          input(o, [this](Session& s) -> const ActionList& { return s.rekey(t32()); });
        } else {
          input(o, [this](Session& s) -> const ActionList& { return s.groupChanged(t32()); });
        }
      }
    }
  }

  void syncTimers(const std::string& lid) {
    Core* c = core(lid);
    if (!c) return;
    for (uint8_t tid = 0; tid < TM_COUNT; tid++) {
      if (!c->s.timerArmed((TimerId)tid)) continue;
      const uint32_t due = c->s.timerDue((TimerId)tid);
      const std::pair<int, uint32_t> key(tid, due);
      if (c->timerKeys.count(key)) continue;
      c->timerKeys.insert(key);
      const int gen = c->gen;
      sim->at(due, [this, lid, gen, tid, due]() { fire(lid, gen, tid, due); });
    }
  }

  void fire(const std::string& lid, int gen, uint8_t tid, uint32_t due) {
    Core* c = core(lid);
    auto it = sim->links.find(lid);
    if (!c || it == sim->links.end() || it->second.gen != gen || c->gen != gen) return;
    if (!c->s.timerArmed((TimerId)tid) || c->s.timerDue((TimerId)tid) != due) return;
    sim->logTimer(name, lid, tid);
    input(lid, [due, tid](Session& s) -> const ActionList& { return s.timer(due, (TimerId)tid); });
  }

  std::vector<std::pair<std::string, Core*>> authed() {
    std::vector<std::pair<std::string, Core*>> v;
    for (auto& c : cores)
      if (c->s.authed()) v.push_back(std::make_pair(c->lid, c.get()));
    return v;
  }

  std::string lidFor(const Id8& pid) {
    for (auto& c : cores)
      if (c->s.authed() && c->s.peerId() == pid) return c->lid;
    return std::string();
  }

  uint8_t routeSessions(uint8_t bit, RouteSession* rs, size_t cap) {
    uint8_t k = 0;
    for (auto& x : authed()) {
      if (k >= cap) break;
      rs[k].peer = x.second->s.peerId();
      rs[k].sub = (x.second->s.peerSubs() & bit) != 0;
      rs[k].ok = true;
      k++;
    }
    return k;
  }

  // ---- on_deliver ----
  void onDeliver(const std::string& lid, Core* c, uint8_t type) {
    const Msg& m = c->s.received();
    switch (type) {
      case MSG_PULL:
        servePull(lid, c, m.pull);
        break;
      case MSG_REC:
        onRec(lid, c, m.rec);
        break;
      case MSG_HB:
        onHb(c, m.hb);
        break;
      case MSG_EVT:
        onEvt(lid, m.evt);
        break;
      case MSG_EVT_SINCE:
        if (kind == KIND_ANDROID && m.evtSince.origin == id)
          catchUp(m.evtSince.requester, m.evtSince.epoch, m.evtSince.afterSeq);
        break;
      case MSG_EVT_GAP:
        onEvtGap(lid, m.evtGap);
        break;
      default:
        break;
    }
  }

  void servePull(const std::string& lid, Core* c, const Pull& p) {
    const Id8 puller = c->s.peerId();
    PeerState* ps = findPeer(puller);
    PageServer pg;
    pg.begin(p, durableHigh, ps && ps->excludeOk, puller);
    for (const FakeEntry* e : ledger.bySeq()) {
      if (e->s <= p.since || e->s > durableHigh) continue;
      uint8_t buf[600];
      size_t k = 0;
      const PageStep st = pg.offer(e->s, e->body, e->bodyLen, e->hasOrigin ? &e->origin : NULL,
                                   e->hasF ? &e->f : NULL, buf, sizeof(buf), &k);
      if (st == PAGE_SEND) {
        send(lid, buf, k);
      } else if (st == PAGE_STOP) {
        break;
      }
    }
    const PageEnd pe = pg.end();
    sendMsg(lid, pe);
    if (pe.more == 0 && ps) ps->excludeOk = true;
  }

  void sendErr(const std::string& lid, uint8_t code, const Key* key) {
    Err e;
    memset(&e, 0, sizeof(e));
    e.code = code;
    e.hasRefType = true;
    e.refType = MSG_REC;
    if (key) {
      e.hasKey = true;
      e.key = *key;
    }
    sendMsg(lid, e);
  }

  void onRec(const std::string& lid, Core* c, const Rec& r) {
    const Id8 from = c->s.peerId();
    const bool live = r.reqId == 0;
    if (!r.bodyStatus.ok()) {
      const uint8_t code = r.bodyStatus.code == E_CLOCK ? E_CLOCK : E_BAD_MSG;
      sim->logApply(name, lid, NULL, errCodeName(code), live);
      sendErr(lid, code, NULL);
      return;
    }
    FakeEntry e;
    const ApplyStatus st = ledger.applyRemote(r.body, r.bodyLen, from, clockKnown, nowMs(), &e);
    Key k;
    const bool hk = bodyErrKey(r.body, r.bodyLen, &k);
    sim->logApply(name, lid, hk ? &k : NULL, applyStatusName(st), live);
    if (st == APPLY_BAD_MSG || st == APPLY_CLOCK) {
      sendErr(lid, st == APPLY_CLOCK ? E_CLOCK : E_BAD_MSG, hk ? &k : NULL);
      return;
    }
    if (st != APPLY_ACCEPT) return;
    markDirty();
    if (!live) {
      pageAccepted = true;
      return;
    }
    RouteSession rs[16];
    const uint8_t n = routeSessions(SUB_RECORDS, rs, 16);
    const Route route = routeLiveRec(id, from, e.hasOrigin ? &e.origin : NULL, r.seenBy, r.seenByCount, rs, n);
    for (uint8_t i = 0; i < route.nTargets; i++) sendRec(lidFor(rs[route.targets[i]].peer), e, route);
  }

  void sendRec(const std::string& lid, const FakeEntry& e, const Route& route) {
    if (lid.empty()) return;
    Rec* rec = new Rec();
    memset(rec, 0, sizeof(*rec));
    rec->seq = e.s;
    rec->reqId = 0;
    rec->seenByCount = route.nSeen;
    for (uint8_t k = 0; k < route.nSeen; k++) rec->seenBy[k] = route.seenBy[k];
    rec->bodyLen = e.bodyLen;
    memcpy(rec->body, e.body, e.bodyLen);
    sendMsg(lid, *rec);
    delete rec;
  }

  void markDirty() {
    if (savePending) return;
    savePending = true;
    sim->at(sim->t + PHONE_SAVE_DEBOUNCE_MS, [this]() { saveNow(); });
  }

  void saveNow() {
    savePending = false;
    const uint32_t nh = ledger.nextSyncSeq - 1;
    if (nh != durableHigh) {
      durableHigh = nh;
      sim->logDurable(name, nh);
    }
    if (pageAccepted) {
      pageAccepted = false;
      requestHb();
    }
  }

  // ---- heartbeats ----
  void requestHb() {
    if (hbRoundPending) return;
    hbRoundPending = true;
    int64_t due = (int64_t)sim->t;
    if (lastHbT + (int64_t)T_HB_SPACING_MS > due) due = lastHbT + T_HB_SPACING_MS;
    sim->at((uint64_t)due, [this]() { hbRound(); });
  }

  void hbRound() {
    hbRoundPending = false;
    std::vector<std::string> lids;
    for (auto& x : authed())
      if (x.second->s.peerSubs() & SUB_HEARTBEATS) lids.push_back(x.first);
    if (!lids.empty()) sendHb(lids);
  }

  size_t buildHb(uint8_t* buf, size_t cap) {
    Hb h;
    memset(&h, 0, sizeof(h));
    h.deviceId = id;
    h.kind = kind;
    h.bootId = bootId;
    h.hbSeq = ++hbSeq;
    h.ts = clockMs(t32());
    h.uptimeS = 1000 + (uint32_t)(sim->t / 1000);
    h.hasBattPct = true;
    h.battPct = battPct;
    h.hasBattMv = true;
    h.battMv = battMv;
    h.hasCharging = true;
    h.charging = charging;
    h.hasRuntimeMin = true;
    h.runtimeMin = runtimeMin;
    setStr(&h.version, version.c_str());
    setStr(&h.name, devname.c_str());
    for (auto& x : authed()) {
      if (h.linkCount >= HB_LINKS_MAX) break;
      HbLink& l = h.links[h.linkCount++];
      const Session& s = x.second->s;
      l.peerId = s.peerId();
      l.peerKind = s.peerHello().kind;
      l.flags = (uint8_t)((s.state() == ST_SYNCED ? HB_LINK_SYNCED : 0) |
                          ((s.peerHello().capsValue() & CAP_TRANSMITTER) ? HB_LINK_TX_READY : 0));
    }
    h.hasState = true;
    h.state = stateBits;
    h.hops = 0;
    h.feedHigh = durableHigh;
    h.dbId = dbId;
    h.records = (uint32_t)ledger.entries.size();
    if (kind == KIND_ANDROID && hasHubAirAgo) {
      h.hasHubAirAgoS = true;
      h.hubAirAgoS = hubAirAgo;
    }
    if (kind == KIND_IOS) {
      for (const Id8& o : origins) {
        const EvtWindow* w = dedupe.newest(o);
        if (!w || h.evtWmCount >= HB_EVTWM_MAX) continue;
        EvtWm& m = h.evtWm[h.evtWmCount++];
        m.origin = o;
        m.epoch = w->epoch;
        m.seq = w->hc;
      }
    }
    return encode(h, buf, cap);
  }

  void sendHb(const std::vector<std::string>& lids) {
    uint8_t buf[400];
    const size_t k = buildHb(buf, sizeof(buf));
    lastHbT = (int64_t)sim->t;
    for (auto& l : lids) send(l, buf, k);
  }

  void onHb(Core* c, const Hb& m) {
    const Id8 from = c->s.peerId();
    const bool direct = m.hops == 0 && m.deviceId == from;
    if (direct) {
      RouteSession rs[16];
      const uint8_t n = routeSessions(SUB_HEARTBEATS, rs, 16);
      uint8_t tg[16];
      const uint8_t k = routeHb(id, from, m.deviceId, 0, rs, n, tg);
      for (uint8_t i = 0; i < k; i++) {
        Bytes copy = rxRaw;
        hbSetHops(copy.data(), copy.size(), 1);
        const std::string l2 = lidFor(rs[tg[i]].peer);
        if (!l2.empty()) sim->send(l2, this, copy);
      }
      if (kind == KIND_ANDROID && m.kind == KIND_HUB) {
        hasHubHb = true;
        hubHbT = sim->t;
        hubHbLinks.assign(m.links, m.links + m.linkCount);
      }
    }
    if (kind == KIND_ANDROID && m.kind == KIND_IOS) {
      for (uint8_t i = 0; i < m.evtWmCount; i++) {
        const EvtWm& w = m.evtWm[i];
        if (w.origin != id) continue;
        if (w.epoch < epoch || (w.epoch == epoch && w.seq < evtSeq)) catchUp(m.deviceId, w.epoch, w.seq);
      }
    }
  }

  // ---- events: Android origin ----
  EvtRoute androidRoute() {
    AndroidSessionView ios, hub;
    memset(&ios, 0, sizeof(ios));
    memset(&hub, 0, sizeof(hub));
    for (auto& x : authed()) {
      const Session& s = x.second->s;
      if (s.peerHello().kind == KIND_IOS) {
        ios.present = true;
        ios.peer = s.peerId();
        ios.up = true;
        ios.subEvents = (s.peerSubs() & SUB_EVENTS) != 0;
      } else if (s.peerHello().kind == KIND_HUB) {
        hub.present = true;
        hub.peer = s.peerId();
        hub.up = true;
      }
    }
    const uint32_t age = hasHubHb ? (uint32_t)(sim->t - hubHbT) : 0;
    return androidEventRoute(id, ios, hub, hasHubHb, age, hubHbLinks.data(), hubHbLinks.size());
  }

  void originate(const Bytes& packet, int rssi) {
    evtSeq++;
    Evt f;
    memset(&f, 0, sizeof(f));
    f.origin = id;
    f.epoch = epoch;
    f.seq = evtSeq;
    f.ts = clockMs(t32());
    f.packet.len = (uint8_t)packet.size();
    memcpy(f.packet.b, packet.data(), packet.size());
    f.hasRssi = true;
    f.rssi = (int8_t)rssi;
    f.hasCount = true;
    f.count = 1;
    f.hasLat = f.hasLon = f.hasAcc = true;
    f.lat = 283852000 + (int32_t)evtSeq;
    f.lon = -815639000;
    f.acc = 8;
    f.hasAddr = true;
    const uint8_t addr[6] = {0xD0, 0xC1, 0xB2, 0xA3, 0x94, 0x00};
    memcpy(f.addr, addr, 6);
    RingItem it;
    it.epoch = epoch;
    it.seq = evtSeq;
    it.f = f;
    ring.push_back(it);
    if (ring.size() > ringCap) ring.pop_front();
    const EvtRoute r = androidRoute();
    Value s = sim->step("local");
    s.set("node", vS(name));
    s.set("op", vS("heard"));
    s.set("epoch", vN(epoch));
    s.set("seq", vN(evtSeq));
    s.set("packet", vS(hexOf(packet)));
    s.set("route", vN(r.route));
    sim->log(s);
    if (r.route != 3) {
      Evt g = f;
      g.seenByCount = r.nSeen;
      for (uint8_t k = 0; k < r.nSeen; k++) g.seenBy[k] = r.seenBy[k];
      const std::string l = lidFor(r.target);
      if (!l.empty()) sendMsg(l, g);
    }
  }

  void restartService(uint16_t newBoot) {
    bootId = newBoot;
    const uint32_t now = (uint32_t)((sim->base + (int64_t)sim->t) / 1000);
    epoch = now > epoch + 1 ? now : epoch + 1;
    evtSeq = 0;
    ring.clear();
    replaysServed.clear();
    Value s = sim->step("local");
    s.set("node", vS(name));
    s.set("op", vS("service_restart"));
    s.set("bootId", vN(newBoot));
    s.set("epoch", vN(epoch));
    sim->log(s);
  }

  void catchUp(const Id8& requester, uint32_t ep, uint32_t after) {
    const auto key = std::make_tuple(hexOf(requester), ep, after);
    auto it = replaysServed.find(key);
    if (it != replaysServed.end() && sim->t - it->second < EVT_REPLAY_DEDUPE_MS) return;  // (a note)
    replaysServed[key] = sim->t;
    std::vector<RingEvt> ids;
    for (auto& x : ring) {
      RingEvt r;
      r.epoch = x.epoch;
      r.seq = x.seq;
      ids.push_back(r);
    }
    std::vector<PlanItem> plan;
    replayPlan(ids.data(), ids.size(), epoch, evtSeq, ep, after, [&plan](const PlanItem& p) { plan.push_back(p); });
    const EvtRoute r = androidRoute();
    if (r.route == 3) return;
    const std::string l = lidFor(r.target);
    for (auto& p : plan) {
      if (!p.gap) {
        for (auto& x : ring) {
          if (x.epoch != p.epoch || x.seq != p.seq) continue;
          Evt g = x.f;
          g.hasFlags = true;
          g.flags = (uint8_t)(g.flagsValue() | EVT_FLAG_REPLAY);
          g.seenByCount = r.nSeen;
          for (uint8_t k = 0; k < r.nSeen; k++) g.seenBy[k] = r.seenBy[k];
          if (!l.empty()) sendMsg(l, g);
          break;
        }
      } else {
        EvtGap gp;
        memset(&gp, 0, sizeof(gp));
        gp.origin = id;
        gp.epoch = p.epoch;
        gp.firstAvail = p.firstAvail;
        gp.lastAvail = p.lastAvail;
        gp.curEpoch = p.curEpoch;
        gp.requester = requester;
        if (!l.empty()) sendMsg(l, gp);
      }
    }
  }

  // ---- events: iPhone receiver ----
  void noteOrigin(const Id8& o) {
    for (auto& x : origins)
      if (x == o) return;
    if (dedupe.newest(o)) origins.push_back(o);
  }

  void onEvt(const std::string& lid, const Evt& m) {
    if (kind != KIND_IOS) return;
    uint32_t lost = 0;
    const EvtResult res = dedupe.receive(m.origin, m.epoch, m.seq, &lost);
    noteOrigin(m.origin);
    if (res == EVT_ACCEPT) ingestAccepted++;
    Value s = sim->step("ingest");
    s.set("node", vS(name));
    s.set("link", vS(lid));
    s.set("origin", vS(hexOf(m.origin)));
    s.set("epoch", vN(m.epoch));
    s.set("seq", vN(m.seq));
    s.set("result", vS(res == EVT_ACCEPT ? "ACCEPT" : "DUPLICATE"));
    s.set("replay", vB((m.flagsValue() & EVT_FLAG_REPLAY) != 0));
    s.set("lost", vN(lost));
    sim->log(s);
    if (res == EVT_ACCEPT && dedupe.hasHoles(m.origin, m.epoch)) {
      const EvtWindow* w = dedupe.window(m.origin, m.epoch);
      if (w) sendSince(lid, m.origin, m.epoch, w->hc);
    }
  }

  void sendSince(const std::string& lid, const Id8& origin, uint32_t ep, uint32_t after) {
    const auto key = std::make_pair(hexOf(origin), ep);
    auto it = sinceSent.find(key);
    if (it != sinceSent.end() && it->second == after) return;
    sinceSent[key] = after;
    EvtSince es;
    memset(&es, 0, sizeof(es));
    es.origin = origin;
    es.epoch = ep;
    es.afterSeq = after;
    es.requester = id;
    sendMsg(lid, es);
  }

  void sendEvtSinceAll(const std::string& lid) {
    for (const Id8& o : origins) {
      const EvtWindow* w = dedupe.newest(o);
      if (!w) continue;
      sinceSent.erase(std::make_pair(hexOf(o), w->epoch));
      sendSince(lid, o, w->epoch, w->hc);
    }
  }

  void onEvtGap(const std::string& lid, const EvtGap& m) {
    if (kind != KIND_IOS) return;
    uint32_t lost = 0;
    EvtRequest req;
    memset(&req, 0, sizeof(req));
    const uint8_t nreq = dedupe.onGap(m.origin, m.epoch, m.firstAvail, m.lastAvail, m.curEpoch, &lost, &req);
    noteOrigin(m.origin);
    Value s = sim->step("gap");
    s.set("node", vS(name));
    s.set("link", vS(lid));
    s.set("origin", vS(hexOf(m.origin)));
    s.set("epoch", vN(m.epoch));
    s.set("lost", vN(lost));
    Value reqs = Value::arr();
    if (nreq) {
      Value r = Value::obj();
      r.set("epoch", vN(req.epoch));
      r.set("afterSeq", vN(req.afterSeq));
      reqs.push(r);
    }
    s.set("requests", reqs);
    sim->log(s);
    if (nreq) sendSince(lid, m.origin, req.epoch, req.afterSeq);
  }

  // ---- local user actions ----
  bool localEdit(const std::string& cls, const Body& fields) {
    FakeEntry e;
    if (!ledger.localEdit(fields, nowMs(), id, &e)) {
      sim->error(name + ": local edit refused");
      return false;
    }
    Value s = sim->step("local");
    s.set("node", vS(name));
    s.set("op", vS("edit"));
    s.set("cls", vS(cls));
    s.set("key", vS(keyStr(e.key)));
    s.set("bodyHex", vS(hexOf(e.body, e.bodyLen)));
    s.set("seq", vN(e.s));
    sim->log(s);
    markDirty();
    pushLocal(e);
    return true;
  }

  void localLearn(const Bytes& packet) {
    FakeEntry e;
    const bool created = ledger.localLearn(packet.data(), packet.size(), &e);
    Value s = sim->step("local");
    s.set("node", vS(name));
    s.set("op", vS("learn"));
    s.set("key", vS(keyStr(makeKey(NS_LIB, packet.data(), packet.size()))));
    s.set("created", vB(created));
    sim->log(s);
    if (!created) return;
    markDirty();
    pushLocal(e);
  }

  void pushLocal(const FakeEntry& e) {
    RouteSession rs[16];
    const uint8_t n = routeSessions(SUB_RECORDS, rs, 16);
    const Route route = routeLocalRec(id, rs, n);
    for (uint8_t i = 0; i < route.nTargets; i++) sendRec(lidFor(rs[route.targets[i]].peer), e, route);
  }

  // ---- final state ----
  Value finalJson() const {
    Value o = Value::obj();
    o.set("dbId", vS(hexOf(dbId)));
    o.set("groupId", group.grouped ? vS(hexOf(group.id)) : vNull());
    o.set("durableHigh", vN(durableHigh));
    o.set("nextSyncSeq", vN(ledger.nextSyncSeq));
    o.set("ledger", ledgerJson(ledger));
    Value p = Value::obj();
    for (auto& kv : peers) p.set(kv.first, peerJson(kv.second));
    o.set("peers", p);
    if (kind == KIND_IOS) {
      std::vector<Id8> sorted = origins;
      std::sort(sorted.begin(), sorted.end(), [](const Id8& a, const Id8& b) { return memcmp(a.b, b.b, 8) < 0; });
      Value w = Value::obj();
      for (const Id8& org : sorted) {
        const EvtWindow* ws[EVT_EPOCHS_KEPT];
        const uint8_t k = dedupe.windows(org, ws);
        Value a = Value::arr();
        for (uint8_t i = 0; i < k; i++) {
          Value x = Value::obj();
          x.set("epoch", vN(ws[i]->epoch));
          x.set("hc", vN(ws[i]->hc));
          char b[20];
          snprintf(b, sizeof(b), "%016llX", (unsigned long long)ws[i]->bits);
          x.set("bits", vS(b));
          a.push(x);
        }
        w.set(hexOf(org), a);
      }
      o.set("evtWindows", w);
    }
    if (kind == KIND_ANDROID) {
      o.set("epoch", vN(epoch));
      o.set("evtSeq", vN(evtSeq));
      Value r = Value::arr();
      for (auto& x : ring) {
        Value pair = Value::arr();
        pair.push(vN(x.epoch));
        pair.push(vN(x.seq));
        r.push(pair);
      }
      o.set("ring", r);
    }
    return o;
  }
};

// ---- the hub under test -------------------------------------------------------------------------------
class SimHub : public SimNode {
 public:
  struct OwnedEv {
    HubRadioEvent ev;
    Bytes data;
  };

  class SimRadio : public Radio {
   public:
    SimHub* h = nullptr;
    std::deque<OwnedEv> q;
    OwnedEv cur;
    uint32_t taken = 0;
    bool take(HubRadioEvent* ev) override {
      if (q.empty()) return false;
      cur = q.front();
      q.pop_front();
      *ev = cur.ev;
      ev->data = cur.data.empty() ? NULL : cur.data.data();
      ev->len = (uint16_t)cur.data.size();
      taken++;
      return true;
    }
    bool sendFrame(uint16_t conn, const uint8_t* frame, size_t len) override {
      const std::string lid = h->linkOf(conn);
      if (lid.empty()) {
        h->sim->error("hub sent a frame on unknown conn " + std::to_string(conn));
        return true;
      }
      return h->sim->hubFrameOut(lid, h, frame, len);
    }
    void disconnect(uint16_t conn, uint8_t hciReason) override {
      (void)hciReason;
      const std::string lid = h->linkOf(conn);
      if (lid.empty()) return;
      auto it = h->lastReason.find(conn);
      h->sim->scheduleDisconnect(lid, it == h->lastReason.end() ? std::string("?") : it->second);
    }
    void push(uint8_t kind, uint16_t conn, uint16_t value, const Bytes& data = Bytes()) {
      OwnedEv e;
      memset(&e.ev, 0, sizeof(e.ev));
      e.ev.kind = kind;
      e.ev.conn = conn;
      e.ev.value = value;
      e.data = data;
      q.push_back(e);
    }
  };

  class TranscriptClock : public Clock {
   public:
    Sim* sim = nullptr;
    bool known = false;
    bool wallMs(uint32_t now, int64_t* out) override {
      if (!known) return false;
      *out = sim->base + (int64_t)now;
      return true;
    }
    void observe(const Id8&, int64_t, uint32_t) override { known = true; }
    bool skewed() override { return false; }
  };

  class ScriptRng : public Rng {
   public:
    SimHub* h = nullptr;
    std::deque<Bytes> randoms;                        // scripted random() outputs (new dbIds)
    std::map<std::string, std::deque<Bytes>> nonces;  // "link|gen" -> transcript nonces
    uint32_t counter = 0;
    void random(uint8_t* out, size_t k) override {
      if (!randoms.empty() && randoms.front().size() == k) {
        memcpy(out, randoms.front().data(), k);
        randoms.pop_front();
        return;
      }
      uint8_t d[8];
      for (size_t i = 0; i < k; i += 8) {
        simNonce(h->id, 0x80000000u + counter++, d);
        memcpy(out + i, d, k - i < 8 ? k - i : 8);
      }
    }
    void nonce(uint16_t conn, uint8_t out[8]) override {
      const std::string lid = h->linkOf(conn);
      auto it = h->sim->links.find(lid);
      if (it != h->sim->links.end()) {
        auto ni = nonces.find(lid + "|" + std::to_string(it->second.gen));
        if (ni != nonces.end() && !ni->second.empty()) {
          memcpy(out, ni->second.front().data(), 8);
          ni->second.pop_front();
          return;
        }
      }
      simNonce(h->id, counter++, out);  // the generator's own rule, per node
    }
  };

  class FixedSelf : public SelfInfo {
   public:
    Sim* sim = nullptr;
    HubSelf v;
    FixedSelf() {
      v.battPct = -1;
      v.battMv = -1;
      v.charging = -1;
      v.runtimeMin = -1;
      v.state = 0;
      v.uptimeS = 0;
    }
    void read(HubSelf* out) override {
      *out = v;
      out->uptimeS = 1000 + (uint32_t)(sim->t / 1000);
    }
  };

  class EvSched : public Scheduler {
   public:
    SimHub* h = nullptr;
    bool at(const HubTask& task) override {
      SimHub* hub = h;
      const HubTask tk = task;
      uint64_t when = (uint64_t)task.due;
      if (when < hub->sim->t) when = hub->sim->t;
      hub->sim->at(when, [hub, tk]() { hub->runTask(tk); });
      return true;
    }
    bool popDue(uint32_t, HubTask*) override { return false; }
    uint32_t nextDueMs(uint32_t) override { return HUB_NO_DEADLINE; }
  };

  class Tracer : public HubTrace {
   public:
    SimHub* h = nullptr;
    void state(uint16_t conn, uint8_t st) override { h->sim->logState(h->name, h->linkOf(conn), st); }
    void apply(uint16_t conn, const Key* key, uint8_t status, bool live) override {
      h->sim->logApply(h->name, h->linkOf(conn), key, dbResultName(status), live);
    }
    void durable(uint32_t dh) override { h->sim->logDurable(h->name, dh); }
    void group(uint16_t conn, const Id8& gid, bool rekey) override {
      h->sim->logGroup(h->name, h->linkOf(conn), gid, rekey);
    }
    void foreign(uint16_t conn) override { h->sim->logSimple("foreign", h->name, h->linkOf(conn)); }
    void disconnect(uint16_t conn, uint8_t reason, bool hasRetry, uint32_t retryMs) override {
      const std::string r = hubDiscReasonName(reason);
      h->lastReason[conn] = r;
      h->sim->logDisconnect(h->name, h->linkOf(conn), r, hasRetry, retryMs);
    }
    void timer(uint16_t conn, uint8_t id) override { h->sim->logTimer(h->name, h->linkOf(conn), id); }
    void sent(uint16_t conn, const uint8_t* msg, size_t len) override {
      h->sim->hubSent(h->linkOf(conn), h, msg, len);
    }
  };

  FakeHubDb db;
  FakeGate gate;
  HubNode node;
  SimRadio radio;
  TranscriptClock tclock;
  HubWallClock wallClock;
  ScriptRng rng;
  FixedSelf self;
  EvSched evsched;
  TaskTable table;
  Tracer tracer;
  bool useTaskTable = false;
  bool useWallClock = false;
  HubConfig cfg;
  std::string version = "2.0 heltec-v3";
  std::string devname = "MM_ESP";
  uint16_t bootIdV = 0x3003;
  std::map<uint16_t, std::string> connLink;
  std::map<std::string, uint16_t> linkConn;
  std::map<uint16_t, std::string> lastReason;
  uint16_t nextConn = 1;
  bool wakePending = false;
  uint64_t wakeAt = 0;
  uint32_t maxDriveLoops = 0;

  SimHub(const std::string& nm, const Id8& devId) {
    name = nm;
    kind = KIND_HUB;
    id = devId;
    maxMsg = HUB_MAXMSG;
    radio.h = this;
    rng.h = this;
    evsched.h = this;
    tracer.h = this;
  }

  bool isHub() const override { return true; }

  std::string linkOf(uint16_t conn) const {
    auto it = connLink.find(conn);
    return it == connLink.end() ? std::string() : it->second;
  }

  // Ports and begin(); call once the sim pointer is set.
  void start(uint8_t policy) {
    tclock.sim = sim;
    self.sim = sim;
    memset(&cfg, 0, sizeof(cfg));
    cfg.deviceId = id;
    cfg.bootId = bootIdV;
    cfg.version = version.c_str();
    cfg.name = devname.c_str();
    cfg.policy = policy;
    HubPorts ports;
    ports.db = &db;
    ports.radio = &radio;
    ports.gate = &gate;
    ports.clock = useWallClock ? static_cast<Clock*>(&wallClock) : static_cast<Clock*>(&tclock);
    ports.rng = &rng;
    ports.self = &self;
    ports.sched = useTaskTable ? static_cast<Scheduler*>(&table) : static_cast<Scheduler*>(&evsched);
    ports.trace = &tracer;
    db.gate = policy == HUB_POLICY_PRODUCTION ? &gate : NULL;
    node.begin(cfg, ports, (uint32_t)sim->t);
  }

  // A reboot: a fresh node over the same (crashed) DB, a new bootId, no links.
  void reboot(uint8_t policy, const Id8& newDbIdIfLost) {
    db.crash(newDbIdIfLost);
    radio.q.clear();
    connLink.clear();
    linkConn.clear();
    lastReason.clear();
    table.clear();
    bootIdV = (uint16_t)(bootIdV + 1);
    node.~HubNode();
    new (&node) HubNode();
    start(policy);
  }

  void drive() {
    uint32_t loops = 0;
    for (;;) {
      node.service((uint32_t)sim->t);
      if (node.nextDueMs((uint32_t)sim->t) != 0) break;
      if (++loops > 200000) {
        sim->error("hub: service() never went idle");
        break;
      }
    }
    if (loops > maxDriveLoops) maxDriveLoops = loops;
    const uint32_t d = node.nextDueMs((uint32_t)sim->t);
    if (useTaskTable && d != HUB_NO_DEADLINE) {
      const uint64_t target = sim->t + (d ? d : 1);
      if (!wakePending || wakeAt > target) {
        wakePending = true;
        wakeAt = target;
        sim->at(target, [this, target]() {
          if (wakeAt == target) wakePending = false;
          drive();
        });
      }
    }
  }

  void runTask(const HubTask& task) {
    node.runTask(task);
    drive();
  }

  void linkUp(const std::string& lid, bool central, SimNode* peerNode, uint16_t mtu) override {
    (void)central;
    (void)peerNode;
    const uint16_t conn = nextConn++;
    connLink[conn] = lid;
    linkConn[lid] = conn;
    radio.push(HUB_EV_CONNECT, conn, mtu);
    radio.push(HUB_EV_SUBSCRIBE, conn, 1);
    drive();
  }

  void linkDown(const std::string& lid) override {
    auto it = linkConn.find(lid);
    if (it == linkConn.end()) return;
    radio.push(HUB_EV_DISCONNECT, it->second, 0x13);
    drive();
    connLink.erase(it->second);
    linkConn.erase(it);
  }

  void rx(const std::string& lid, const Bytes& msg) override {
    (void)lid;
    (void)msg;
    sim->error("hub got a whole message instead of frames");
  }
  void rxFrame(const std::string& lid, const Bytes& frame) override {
    auto it = linkConn.find(lid);
    if (it == linkConn.end()) return;
    radio.push(HUB_EV_FRAME, it->second, 0, frame);
  }
  void rxFramesDone(const std::string& lid) override {
    (void)lid;
    drive();
  }

  uint16_t memberConn() const {
    for (auto& kv : connLink)
      if (node.isMember(kv.first)) return kv.first;
    return HUB_CONN_NONE;
  }

  Value finalJson() const {
    Value o = Value::obj();
    o.set("dbId", vS(hexOf(db.dbId())));
    o.set("groupId", db.group().grouped ? vS(hexOf(db.group().id)) : vNull());
    o.set("durableHigh", vN(db.durableHigh()));
    o.set("nextSyncSeq", vN(db.lastSeq() + 1));
    o.set("ledger", ledgerJson(db.ledger));
    std::vector<std::pair<std::string, PeerState>> ps;
    for (uint8_t i = 0; i < HUB_PEERS_MAX; i++)
      if (db.peers[i].used) ps.push_back(std::make_pair(hexOf(db.peers[i].id), db.peers[i].st));
    std::sort(ps.begin(), ps.end(), [](const std::pair<std::string, PeerState>& a,
                                       const std::pair<std::string, PeerState>& b) { return a.first < b.first; });
    Value p = Value::obj();
    for (auto& x : ps) p.set(x.first, peerJson(x.second));
    o.set("peers", p);
    return o;
  }
};

}  // namespace hubsim

#endif  // !ARDUINO
