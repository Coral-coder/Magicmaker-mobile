// C++11 smoke test of the SYNC headers: known answers, a body/message round trip, the event and
// routing helpers, the ledger, and an iPhone (central) and a grouped hub (peripheral) Session
// handshaking and pulling through real Fragmenter/Reassembler pairs until both are SYNCED.
//
// Built by `make test` with -std=gnu++11 (the Arduino-ESP32 sketch standard) and -Werror, so the
// headers stay C++11 clean; the shared-vector conformance is test_sync.cc. Also compiled for the
// ESP32 with the Xtensa toolchain by defining MMSYNC_SMOKE_ON_TARGET (it then provides
// mmsyncSmoke() and no main()).
//
// PlatformIO builds every source under the sketch folder: without MMSYNC_SMOKE_ON_TARGET this file
// is empty when ARDUINO is defined.
#if !defined(ARDUINO) || defined(MMSYNC_SMOKE_ON_TARGET)

#include <stdio.h>
#include <string.h>

#include "../../sync_codec.h"
#include "../../sync_events.h"
#include "../../sync_ledger.h"
#include "../../sync_session.h"

namespace mmsync_smoke {

using namespace mmsync;

struct SmokeNode : public SessionNode {
  PeerTable<4> table;
  uint8_t nonceSeed;
  int64_t clock;
  explicit SmokeNode(uint8_t seed) : nonceSeed(seed), clock(0) {}
  int64_t clockMs(uint32_t t) override { return clock ? clock + (int64_t)t : 0; }
  void nextNonce(uint8_t out[8]) override {
    for (int i = 0; i < 8; i++) out[i] = (uint8_t)(nonceSeed * 31 + i * 7 + 1);
    nonceSeed++;
  }
  PeerState* findPeer(const Id8& id) override { return table.find(id); }
  PeerState* peer(const Id8& id) override { return table.getOrCreate(id); }
};

static const size_t SLOT = 256;  // every message of this handshake is <= 136 bytes

// One direction of a link: fragment at the sender, reassemble at the receiver.
struct Pipe {
  Fragmenter frag;
  Reassembler<PHONE_MAXMSG> reasm;
  uint8_t queue[8][SLOT];
  size_t qlen[8];
  size_t qn;
  uint16_t mtu;
  bool broken;

  Pipe(uint16_t maxMsg, uint16_t linkMtu) : reasm(maxMsg), qn(0), mtu(linkMtu), broken(false) {}

  void send(const uint8_t* msg, size_t n) {
    uint8_t frame[MTU_MAX];
    size_t off = 0, fl;
    while ((fl = frag.next(msg, n, &off, mtu, frame)) != 0) {
      const ReasmResult r = reasm.feed(frame, fl);
      for (uint8_t i = 0; i < r.n; i++) {
        if (r.ev[i].kind != RA_DELIVER) {
          broken = true;
          continue;
        }
        if (qn < 8 && r.msgLen <= SLOT) {
          memcpy(queue[qn], r.msg, r.msgLen);
          qlen[qn++] = r.msgLen;
        } else {
          broken = true;
        }
      }
    }
  }
};

// Plays a node for its Session's actions: sends go into the pipe, a delivered PULL is served
// (empty feed), anything else is ignored. Returns false on an unexpected action.
inline bool runActions(const ActionList& acts, Session& s, SmokeNode& node, Pipe& out,
                       uint32_t* commits) {
  for (size_t i = 0; i < acts.size(); i++) {
    const Action& a = acts[i];
    if (a.kind == ACT_SEND) {
      out.send(acts.bytes(a), a.len);
    } else if (a.kind == ACT_DELIVER && a.msgType == MSG_PULL) {
      PageServer ps;
      const PeerState* p = s.peerEntry();
      ps.begin(s.received().pull, node.feedHigh, p ? p->excludeOk : false, s.peerId());
      PageEnd pe = ps.end();
      uint8_t buf[64];
      const size_t n = encode(pe, buf, sizeof(buf));
      if (!n) return false;
      out.send(buf, n);
    } else if (a.kind == ACT_COMMIT) {
      (*commits)++;
    } else if (a.kind == ACT_DISCONNECT) {
      return false;
    }
  }
  return !acts.overflowed();
}

inline int run() {
  // 1. primitives (known answers from SYNC_PROTOCOL.md §2)
  const uint8_t check[] = {'1', '2', '3', '4', '5', '6', '7', '8', '9'};
  if (crc32(check, 9) != 0xCBF43926u) return 1;
  const uint8_t a = 'a';
  if (fnv1a64(&a, 1) != 0xAF63DC4C8601EC8Cull) return 2;
  const uint8_t jefe[] = {'J', 'e', 'f', 'e'};
  const char* what = "what do ya want for nothing?";
  uint8_t mac[32];
  hmacSha256(jefe, 4, reinterpret_cast<const uint8_t*>(what), strlen(what), mac);
  if (mac[0] != 0x5B || mac[1] != 0xDC || mac[31] != 0x43) return 3;

  // 2. a USER body round trip and its version
  const uint8_t packet[] = {0x83, 0x01, 0xE1, 0x00, 0xE9, 0x0C, 0x00, 0x01};
  Body b;
  clearBody(&b);
  b.key = makeKey(NS_LIB, packet, sizeof(packet));
  b.updatedAt = 1796000000000LL;
  b.hasOrigin = true;
  memset(b.origin.b, 0x4A, 8);
  b.flags = FLAG_USER_EDITED;
  const char* label = "  Main Street  ";
  size_t ll = 0;
  if (!normalizeText(reinterpret_cast<const uint8_t*>(label), strlen(label), LABEL_MAX, b.label, &ll))
    return 4;
  b.labelLen = (uint8_t)ll;
  b.hasCategory = true;
  b.category = CAT_SHOW;
  b.hasPlace = true;
  b.place = PLACE_LIBRARY;
  uint8_t body[BODY_MAX];
  size_t bl = 0;
  if (!encodeBody(b, body, sizeof(body), &bl).ok()) return 5;
  Body back;
  RecordClass cls = CLS_NONE;
  if (!decodeBody(body, bl, &back, &cls).ok() || cls != CLS_USER || back.labelLen != 11) return 6;
  const Version v1 = versionOf(back, body, bl);
  if (applyCheck(body, bl, true, 1796000000000LL, &v1, NULL, NULL, NULL) != APPLY_DUPLICATE) return 7;

  // 3. a REC message round trip
  Rec r;
  memset(&r, 0, sizeof(r));
  r.seq = 7;
  r.reqId = 0;
  r.seenByCount = 1;
  r.seenBy[0] = back.origin;
  memcpy(r.body, body, bl);
  r.bodyLen = (uint16_t)bl;
  uint8_t msg[512];
  const size_t ml = encode(r, msg, sizeof(msg));
  Msg m;
  if (!ml || !decodeMsg(msg, ml, &m).ok() || m.type != MSG_REC || !m.rec.bodyStatus.ok()) return 8;
  uint8_t again[512];
  if (encodeMsg(m, again, sizeof(again)) != ml || memcmp(again, msg, ml) != 0) return 9;

  // 4. ledger, events, routing
  Ledger led;
  LedgerEntry e;
  std::vector<Key> ev;
  if (led.applyRemote(body, bl, back.origin, true, 1796000000000LL, &e, &ev) != APPLY_ACCEPT) return 10;
  if (led.localLearn(packet, sizeof(packet), &e)) return 11;  // the entry blocks a learn
  EvtDedupe<4> dd;
  uint32_t lost = 0;
  if (dd.receive(back.origin, 1796000000u, 40, &lost) != EVT_ACCEPT) return 12;
  if (dd.receive(back.origin, 1796000000u, 40, &lost) != EVT_DUPLICATE) return 13;
  RingEvt ring[3] = {{5, 1}, {5, 2}, {5, 3}};
  uint32_t replays = 0;
  struct Count {
    uint32_t* n;
    void operator()(const PlanItem& p) const {
      if (!p.gap) (*n)++;
    }
  } counter = {&replays};
  replayPlan(ring, 3, 5, 3, 5, 1, counter);
  if (replays != 2) return 14;
  RouteSession rs[2];
  memset(rs, 0, sizeof(rs));
  memset(rs[0].peer.b, 1, 8);
  memset(rs[1].peer.b, 2, 8);
  rs[0].sub = rs[0].ok = rs[1].sub = rs[1].ok = true;
  const Route rt = routeLiveRec(back.origin, rs[0].peer, &back.origin, NULL, 0, rs, 2);
  if (rt.nTargets != 1 || rt.targets[0] != 1 || rt.nSeen != 2) return 15;

  // 5. an iPhone and a grouped hub handshake and pull through the framer (MTU 23: multi-frame)
  uint8_t key[16];
  for (int i = 0; i < 16; i++) key[i] = (uint8_t)(0xB0 + i);
  SmokeNode phone(1), hub(100);
  phone.clock = 1796000000000LL;
  phone.group.grouped = hub.group.grouped = true;
  phone.group.id = hub.group.id = groupIdOf(key);
  memcpy(phone.group.key, key, 16);
  memcpy(hub.group.key, key, 16);
  memset(phone.dbId.b, 0x9E, 8);
  memset(hub.dbId.b, 0x12, 8);
  SessionConfig pc, hc;
  memset(&pc, 0, sizeof(pc));
  memset(&hc, 0, sizeof(hc));
  pc.role = ROLE_CENTRAL;
  memset(pc.deviceId.b, 0xA1, 8);
  pc.kind = KIND_IOS;
  pc.bootId = 4097;
  pc.maxMsg = PHONE_MAXMSG;
  pc.caps = CAPS_IOS;
  pc.version = "1.4.0";
  pc.name = "iPhone";
  pc.peerKind = KIND_HUB;
  pc.tracksEvents = true;
  hc.role = ROLE_PERIPHERAL;
  hc.deviceId.b[0] = 0x01;
  hc.kind = KIND_HUB;
  hc.bootId = 12291;
  hc.maxMsg = HUB_MAXMSG;
  hc.caps = CAPS_HUB;
  hc.version = "2.0";
  hc.name = "MM_ESP";
  hc.isHub = true;
  Session ps, hs;
  ps.attach(&pc, &phone);
  hs.attach(&hc, &hub);
  Pipe toHub(HUB_MAXMSG, 23), toPhone(PHONE_MAXMSG, 23);
  uint32_t commits = 0;
  if (!runActions(hs.linkUp(0, 23), hs, hub, toPhone, &commits)) return 16;
  if (!hs.timerArmed(TM_DEADLINE)) return 17;
  if (!runActions(ps.linkUp(0, 23), ps, phone, toHub, &commits)) return 18;
  for (uint32_t t = 1; t < 50; t++) {
    const size_t nh = toHub.qn, np = toPhone.qn;
    toHub.qn = 0;
    toPhone.qn = 0;
    uint8_t hq[8][SLOT], pq[8][SLOT];
    size_t hl[8], pl[8];
    for (size_t i = 0; i < nh; i++) {
      memcpy(hq[i], toHub.queue[i], toHub.qlen[i]);
      hl[i] = toHub.qlen[i];
    }
    for (size_t i = 0; i < np; i++) {
      memcpy(pq[i], toPhone.queue[i], toPhone.qlen[i]);
      pl[i] = toPhone.qlen[i];
    }
    for (size_t i = 0; i < nh; i++)
      if (!runActions(hs.rx(t, hq[i], hl[i]), hs, hub, toPhone, &commits)) return 19;
    for (size_t i = 0; i < np; i++)
      if (!runActions(ps.rx(t, pq[i], pl[i]), ps, phone, toHub, &commits)) return 20;
    if (nh == 0 && np == 0) break;
  }
  if (toHub.broken || toPhone.broken) return 21;
  if (ps.state() != ST_SYNCED || hs.state() != ST_SYNCED) return 22;
  if (hs.timerArmed(TM_DEADLINE) || commits != 2) return 23;
  const PeerState* hubSeen = phone.findPeer(hc.deviceId);
  if (!hubSeen || hubSeen->dbId != hub.dbId) return 24;
  return 0;
}

}  // namespace mmsync_smoke

inline int mmsyncSmoke() { return mmsync_smoke::run(); }

#if !defined(MMSYNC_SMOKE_ON_TARGET)
int main() {
  const int rc = mmsyncSmoke();
  if (rc != 0) {
    printf("FAIL cxx11 smoke check %d\n", rc);
    return 1;
  }
  printf("cxx11 smoke: ok\n");
  return 0;
}
#endif

#endif
