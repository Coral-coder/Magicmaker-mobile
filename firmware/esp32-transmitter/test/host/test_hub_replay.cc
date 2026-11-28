// The hub node's P2 gate (docs/SYNC_P2_FIRMWARE_PLAN.md §5.13 items 1 and 2):
//
//   replay    every golden transcript in tools/sync/transcripts re-run as a whole simulation
//             (hub_sim.h): H is a real HubNode (HUB_POLICY_TRANSCRIPT, FakeHubDb seeded from
//             nodes.H, the transcript's nonces, a clock that reads clockBaseMs + t once known),
//             the phones are the C++ stand-ins, X / Y / Z send the transcript's raw messages. The
//             produced step list must equal the transcript's (notes excluded): every msg (link,
//             gen, from, to, type, hex, frames), state, apply, durable, group, foreign, disconnect,
//             timer, ingest, gap and local step in order; then every final node state.
//   loopback  the same scenarios, and randomised ones, over a lossy network with random per-frame
//             latency, refused notifies, auto-relink, hub reboots, sync_reset, strangers and timed
//             jobs; the invariants of plan §5.13 item 2 are checked on every message, and the
//             ledgers must converge.
//
//   ./build/test_hub_replay <tools/sync dir> [seeds]       (exit 1 on any failure)
//
// Host only (C++17): PlatformIO builds every source under the sketch folder, so this file is empty
// when ARDUINO is defined.
#ifndef ARDUINO

#include <dirent.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

#include "hub_sim.h"

using namespace hubsim;
using jmini::Value;

namespace {

int g_failures = 0;
int g_checks = 0;

void fail(const std::string& s) {
  g_failures++;
  if (g_failures <= 40) std::printf("FAIL %s\n", s.c_str());
}

void check(bool ok, const std::string& what) {
  g_checks++;
  if (!ok) fail(what);
}

const std::vector<std::string>& internalReasons() {
  static const std::vector<std::string> r = {"foreign",  "auth_timeout", "auth_deadline", "page_timeout",
                                             "left_group", "db_reset",   "stale",         "slots",
                                             "deadline", "unsubscribed"};
  return r;
}
bool isInternal(const std::string& reason) {
  for (auto& x : internalReasons())
    if (x == reason) return true;
  return false;
}

// ---- one transcript as a simulation ------------------------------------------------------------------
struct Driver {
  Value j;
  Sim sim;
  std::vector<std::unique_ptr<SimNode>> owned;
  SimHub* hub = nullptr;
  std::map<std::pair<uint32_t, uint32_t>, int> evtRssi;
  std::map<std::string, Hb> firstHb;
  uint8_t policy = HUB_POLICY_TRANSCRIPT;

  explicit Driver(const Value& tj, const NetParams& net = NetParams(), uint8_t pol = HUB_POLICY_TRANSCRIPT)
      : j(tj), policy(pol) {
    sim.setNet(net);
    sim.base = j["clockBaseMs"].asInt();
    if (!net.loopback) sim.net.latMs = (uint32_t)j["latencyMs"].asInt();
    scanMessages();
    build();
    pushStimuli();
  }

  void scanMessages() {
    for (const auto& st : j["steps"].a) {
      if (st["ev"].asStr() != "msg") continue;
      const Bytes data = unhex(st["hex"].asStr());
      Msg m;
      if (!decodeMsg(data.data(), data.size(), &m).ok() || !m.known) continue;
      if (m.type == MSG_HB && m.hb.hops == 0 && !firstHb.count(st["from"].asStr())) firstHb[st["from"].asStr()] = m.hb;
      if (m.type == MSG_EVT) {
        const auto key = std::make_pair(m.evt.epoch, m.evt.seq);
        if (!evtRssi.count(key)) evtRssi[key] = m.evt.hasRssi ? m.evt.rssi : -60;
      }
    }
  }

  static GroupState groupOf(const Value& n) {
    GroupState g;
    memset(&g, 0, sizeof(g));
    if (n.has("groupKey") && !n["groupKey"].isNull()) {
      g.grouped = true;
      g.id = toId8(n["groupId"].asStr());
      const Bytes k = unhex(n["groupKey"].asStr());
      memcpy(g.key, k.data(), 16);
    }
    return g;
  }

  void build() {
    for (const auto& kv : j["nodes"].o) {
      const std::string& name = kv.first;
      const Value& n = kv.second;
      const Id8 id = toId8(n["deviceId"].asStr());
      const uint8_t kind = (uint8_t)n["kind"].asInt();
      if (n.has("scripted") && n["scripted"].asBool()) {
        owned.emplace_back(new ScriptedNode(name, kind, id));
        sim.add(owned.back().get());
        continue;
      }
      const Hb* hb = firstHb.count(name) ? &firstHb[name] : nullptr;
      if (kind == KIND_HUB) {
        SimHub* h = new SimHub(name, id);
        owned.emplace_back(h);
        sim.add(h);
        hub = h;
        h->bootIdV = (uint16_t)n["bootId"].asInt();
        h->version = n["version"].isNull() ? "" : n["version"].asStr();
        h->devname = n["name"].isNull() ? "" : n["name"].asStr();
        h->db.id = toId8(n["dbId"].asStr());
        h->db.grp = groupOf(n);
        for (const auto& e : n["ledger"].a) {
          const Bytes b = unhex(e["b"].asStr());
          const bool hasF = !e["f"].isNull();
          h->db.seedEntry(b.data(), b.size(), (uint32_t)e["s"].asInt(), hasF, hasF ? toId8(e["f"].asStr()) : zeroId8());
        }
        h->db.seedDone((uint32_t)n["nextSyncSeq"].asInt(), (uint32_t)n["durableHigh"].asInt());
        for (const auto& p : n["peers"].o)
          h->db.seedPeer(toId8(p.first), toId8(p.second["dbId"].asStr()), (uint32_t)p.second["wm"].asInt(),
                         p.second["excludeOk"].asBool());
        h->tclock.known = n["clockKnown"].asBool();
        if (hb) {
          h->self.v.battPct = hb->battPctValue();
          h->self.v.battMv = hb->battMvValue();
          h->self.v.charging = hb->chargingValue();
          h->self.v.runtimeMin = hb->runtimeMinValue();
          h->self.v.state = hb->stateValue();
        }
        for (const auto& x : j["nonces"].a) {
          if (x["node"].asStr() != name) continue;
          auto& dq = h->rng.nonces[x["link"].asStr() + "|" + std::to_string(x["gen"].asInt())];
          for (const auto& nn : x["nonces"].a) dq.push_back(unhex(nn.asStr()));
        }
        h->start(policy);
        continue;
      }
      Phone* p = new Phone(name, kind, id);
      owned.emplace_back(p);
      sim.add(p);
      p->bootId = (uint16_t)n["bootId"].asInt();
      p->version = n["version"].isNull() ? "" : n["version"].asStr();
      p->devname = n["name"].isNull() ? "" : n["name"].asStr();
      p->dbId = toId8(n["dbId"].asStr());
      p->group = groupOf(n);
      p->clockKnown = n["clockKnown"].asBool();
      for (const auto& e : n["ledger"].a) {
        const Bytes b = unhex(e["b"].asStr());
        const bool hasF = !e["f"].isNull();
        p->ledger.restore(b.data(), b.size(), (uint32_t)e["s"].asInt(), hasF, hasF ? toId8(e["f"].asStr()) : zeroId8());
      }
      p->ledger.nextSyncSeq = (uint32_t)n["nextSyncSeq"].asInt();
      p->durableHigh = (uint32_t)n["durableHigh"].asInt();
      for (const auto& pp : n["peers"].o) {
        PeerState* ps = p->peer(toId8(pp.first));
        ps->dbId = toId8(pp.second["dbId"].asStr());
        ps->wm = (uint32_t)pp.second["wm"].asInt();
        ps->excludeOk = pp.second["excludeOk"].asBool();
      }
      if (hb) {
        p->battPct = hb->battPctValue();
        p->battMv = hb->battMvValue();
        p->charging = hb->chargingValue();
        p->runtimeMin = hb->runtimeMinValue();
        p->stateBits = hb->stateValue();
        if (hb->hasHubAirAgoS) {
          p->hasHubAirAgo = true;
          p->hubAirAgo = hb->hubAirAgoS;
        }
      }
      if (n.has("ringCap") && !n["ringCap"].isNull()) p->ringCap = (size_t)n["ringCap"].asInt();
      if (n.has("epoch") && !n["epoch"].isNull()) p->epoch = (uint32_t)n["epoch"].asInt();
    }
  }

  Phone* phone(const std::string& name) { return static_cast<Phone*>(sim.nodes[name]); }

  // The scenario's own sim.at() calls, recovered from the steps they logged (pushed first so they
  // win ties, as in the generator).
  void pushStimuli() {
    for (const auto& st : j["steps"].a) {
      const uint64_t t = (uint64_t)st["t"].asInt();
      const std::string ev = st["ev"].asStr();
      if (ev == "link_up") {
        const std::string lid = st["link"].asStr(), c = st["central"].asStr(), p = st["peripheral"].asStr();
        const uint16_t mtu = (uint16_t)st["mtu"].asInt();
        sim.at(t, [this, lid, c, p, mtu]() { sim.linkUp(lid, c, p, mtu); });
      } else if (ev == "link_down") {
        const std::string reason = st["reason"].asStr();
        if (isInternal(reason)) continue;
        const std::string lid = st["link"].asStr();
        sim.at(t, [this, lid, reason]() { sim.linkDown(lid, reason); });
      } else if (ev == "msg" && st["by"].asStr() == "script") {
        const std::string lid = st["link"].asStr(), from = st["from"].asStr();
        const Bytes data = unhex(st["hex"].asStr());
        sim.at(t, [this, lid, from, data]() { static_cast<ScriptedNode*>(sim.nodes[from])->sendRaw(lid, data); });
      } else if (ev == "local") {
        const std::string node = st["node"].asStr(), op = st["op"].asStr();
        if (op == "sync_reset") {
          const Bytes db = unhex(st["dbId"].asStr());
          sim.at(t, [this, node, db]() { hubReset(node, db); });
        } else if (op == "edit") {
          const std::string cls = st["cls"].asStr();
          const Bytes b = unhex(st["bodyHex"].asStr());
          sim.at(t, [this, node, cls, b]() {
            Body body;
            if (!decodeBody(b.data(), b.size(), &body, NULL).ok()) {
              fail("edit body does not decode");
              return;
            }
            phone(node)->localEdit(cls, body);
          });
        } else if (op == "learn") {
          const std::string key = st["key"].asStr();
          const Bytes packet = unhex(key.substr(key.find(':') + 1));
          sim.at(t, [this, node, packet]() { phone(node)->localLearn(packet); });
        } else if (op == "heard") {
          const Bytes packet = unhex(st["packet"].asStr());
          const auto k = std::make_pair((uint32_t)st["epoch"].asInt(), (uint32_t)st["seq"].asInt());
          const int rssi = evtRssi.count(k) ? evtRssi[k] : -60;
          sim.at(t, [this, node, packet, rssi]() { phone(node)->originate(packet, rssi); });
        } else if (op == "service_restart") {
          const uint16_t boot = (uint16_t)st["bootId"].asInt();
          sim.at(t, [this, node, boot]() { phone(node)->restartService(boot); });
        } else {
          fail("unknown local op " + op);
        }
      }
    }
  }

  void hubReset(const std::string& node, const Bytes& db) {
    Value s = sim.step("local");
    s.set("node", vS(node));
    s.set("op", vS("sync_reset"));
    s.set("dbId", vS(hexOf(db)));
    sim.log(s);
    hub->rng.randoms.push_back(db);
    const uint16_t conn = hub->memberConn();
    if (!hub->node.syncReset(conn, (uint32_t)sim.t)) fail(j["name"].asStr() + ": syncReset refused");
    hub->drive();
  }

  void run(uint64_t extra = 0) { sim.run((uint64_t)j["final"]["t"].asInt() + extra); }

  std::string stepMismatch() const {
    std::vector<const Value*> want;
    for (const auto& st : j["steps"].a)
      if (st["ev"].asStr() != "note") want.push_back(&st);
    const auto& got = sim.steps;
    for (size_t i = 0; i < std::max(want.size(), got.size()); i++) {
      if (i >= got.size()) return "step " + std::to_string(i) + ": got <end>, want " + jmini::dump(*want[i]);
      if (i >= want.size()) return "step " + std::to_string(i) + ": got " + jmini::dump(got[i]) + ", want <end>";
      const Value& g = got[i];
      Value sub = Value::obj();
      for (const auto& kv : g.o) {
        const Value* w = want[i]->find(kv.first);
        sub.set(kv.first, w ? *w : Value::str("<missing>"));
      }
      if (!jmini::equal(g, sub)) {
        std::string ctx;
        for (size_t k = i >= 3 ? i - 3 : 0; k < i; k++) ctx += "\n  ok:   " + jmini::dump(got[k]);
        return "step " + std::to_string(i) + ctx + "\n  got:  " + jmini::dump(g) + "\n  want: " + jmini::dump(sub);
      }
    }
    return std::string();
  }

  Value finalOf(const std::string& name) {
    SimNode* n = sim.nodes[name];
    if (n->isHub()) return static_cast<SimHub*>(n)->finalJson();
    return static_cast<Phone*>(n)->finalJson();
  }

  std::vector<std::string> finalMismatches() {
    std::vector<std::string> out;
    for (const auto& kv : j["final"]["nodes"].o) {
      const Value got = finalOf(kv.first);
      for (const auto& f : kv.second.o) {
        const Value* g = got.find(f.first);
        if (!g || !jmini::equal(*g, f.second))
          out.push_back(kv.first + "." + f.first + "\n  got:  " + (g ? jmini::dump(*g) : "<missing>") +
                        "\n  want: " + jmini::dump(f.second));
      }
    }
    return out;
  }
};

std::vector<std::string> listTranscripts(const std::string& dir) {
  std::vector<std::string> out;
  DIR* d = opendir(dir.c_str());
  if (!d) return out;
  while (dirent* e = readdir(d)) {
    const std::string n = e->d_name;
    if (n.size() > 5 && n.substr(n.size() - 5) == ".json") out.push_back(dir + "/" + n);
  }
  closedir(d);
  std::sort(out.begin(), out.end());
  return out;
}

bool hasHub(const Value& j) {
  for (const auto& kv : j["nodes"].o)
    if (kv.second["kind"].asInt() == KIND_HUB && !(kv.second.has("scripted") && kv.second["scripted"].asBool()))
      return true;
  return false;
}

// ---- 1. the replay ---------------------------------------------------------------------------------
int replayAll(const std::vector<std::string>& paths) {
  int hubTranscripts = 0;
  for (const auto& path : paths) {
    const Value j = jmini::parseFile(path);
    const std::string name = j["name"].asStr();
    const bool withHub = hasHub(j);
    if (withHub) hubTranscripts++;
    Driver d(j);
    d.run();
    for (auto& e : d.sim.errors) fail(name + ": " + e);
    const std::string m = d.stepMismatch();
    check(m.empty(), name + " steps: " + m);
    for (auto& f : d.finalMismatches()) fail(name + " final " + f);
    if (m.empty() && d.sim.errors.empty())
      std::printf("  replay %-32s %3zu steps%s\n", name.c_str(), d.sim.steps.size(), withHub ? "  (hub)" : "");
  }
  return hubTranscripts;
}

}  // namespace

int main(int argc, char** argv) {
  const std::string dir = argc > 1 ? argv[1] : "../../../../tools/sync";
  const std::vector<std::string> paths = listTranscripts(dir + "/transcripts");
  check(paths.size() >= 6, "transcripts found in " + dir + "/transcripts");
  const int hubs = replayAll(paths);
  check(hubs >= 5, "transcripts with a hub node: " + std::to_string(hubs));
  std::printf("test_hub_replay: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures ? 1 : 0;
}

#endif  // ARDUINO
