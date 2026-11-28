// Host test doubles for the hub node (docs/SYNC_P2_FIRMWARE_PLAN.md §6): FakeLedger, FakeGate and
// FakeHubDb : HubDb.
//
//   FakeLedger  the reference ledger of tools/sync/sync_ref.py (one current entry per key, feed seq
//               s, syncFrom f, the tombstone cap) with restore() for seeding a transcript node's
//               exact state. The stand-in phones of hub_sim.h use it too.
//   FakeGate    a scripted TxGate (timed job, the engine's next deadline, a command waiting, OTA).
//   FakeHubDb   a map-backed HubDb with the observable behaviour of plan §4.10: accept = P1
//               applyCheck + seq = lastSeq + 1, flush -> durableHigh = lastSeq, a feed over the
//               current entries in seq order, peers (LRU), group, full / repull flags, reset. It
//               also models the durability rules the node depends on: a crash() keeps only the
//               flushed snapshot, peers whose wm was persisted after its records were flushed, and
//               takes a new dbId when a live-forwarded seq was lost (D-P2-4).
//
// Host only (C++17 or gnu++11; std::vector): PlatformIO builds every source under the sketch
// folder, so this file is empty when ARDUINO is defined.
#pragma once
#if !defined(ARDUINO)

#include <vector>

#include "../../hub_ports.h"

namespace mmsync {

// ---- the reference ledger ---------------------------------------------------------------------------
struct FakeEntry {
  Key key;
  Version version;
  uint8_t cls;
  uint8_t flags;
  bool hasOrigin;
  Id8 origin;
  uint16_t bodyLen;
  uint8_t body[BODY_MAX];
  uint32_t s;
  bool hasF;
  Id8 f;

  bool deleted() const { return (flags & FLAG_DELETED) != 0; }
};

class FakeLedger {
 public:
  std::vector<FakeEntry> entries;  // current entries, in insertion order
  uint32_t nextSyncSeq;
  int64_t lastLocalStamp;
  uint32_t tombstoneCap;

  FakeLedger() : nextSyncSeq(1), lastLocalStamp(0), tombstoneCap(TOMBSTONE_CAP_PHONE) {}

  FakeEntry* get(const Key& k) {
    for (size_t i = 0; i < entries.size(); i++)
      if (entries[i].key == k) return &entries[i];
    return NULL;
  }
  const FakeEntry* get(const Key& k) const {
    for (size_t i = 0; i < entries.size(); i++)
      if (entries[i].key == k) return &entries[i];
    return NULL;
  }

  size_t tombstones() const {
    size_t n = 0;
    for (size_t i = 0; i < entries.size(); i++)
      if (entries[i].deleted()) n++;
    return n;
  }

  // Current entries sorted by s.
  std::vector<const FakeEntry*> bySeq() const {
    std::vector<const FakeEntry*> v;
    for (size_t i = 0; i < entries.size(); i++) v.push_back(&entries[i]);
    for (size_t a = 1; a < v.size(); a++) {
      const FakeEntry* x = v[a];
      size_t b = a;
      while (b > 0 && v[b - 1]->s > x->s) {
        v[b] = v[b - 1];
        b--;
      }
      v[b] = x;
    }
    return v;
  }

  // sync_ref.Ledger.apply_remote. *out: the stored entry on ACCEPT, the current one on DUPLICATE /
  // STALE.
  ApplyStatus applyRemote(const uint8_t* body, size_t n, const Id8& sender, bool nowKnown,
                          int64_t nowMs, FakeEntry* out, Status* err = NULL) {
    const FakeEntry* cur = NULL;
    {
      Body probe;
      if (decodeBody(body, n, &probe, NULL).ok()) cur = get(probe.key);
    }
    Body b;
    Version v;
    Status e;
    const ApplyStatus st = applyCheck(body, n, nowKnown, nowMs, cur ? &cur->version : NULL, &b, &v, &e);
    if (err) *err = e;
    if (st == APPLY_DUPLICATE || st == APPLY_STALE) {
      if (out && cur) *out = *cur;
      return st;
    }
    if (st != APPLY_ACCEPT) return st;
    store(b, body, n, true, sender, out);
    return APPLY_ACCEPT;
  }

  // sync_ref.Ledger.local_learn: PRESENCE only when the key has no entry at all.
  bool localLearn(const uint8_t* packet, size_t n, FakeEntry* out) {
    if (!checkPacket(packet, n).ok()) return false;
    const Key k = makeKey(NS_LIB, packet, n);
    if (get(k)) return false;
    Body b;
    clearBody(&b);
    b.key = k;
    b.updatedAt = U_PRESENCE;
    uint8_t buf[BODY_MAX];
    size_t len = 0;
    if (!encodeBody(b, buf, sizeof(buf), &len).ok()) return false;
    store(b, buf, len, false, zeroId8(), out);
    return true;
  }

  // A local edit whose fields (key, flags, texts, category, place) are already normalised: the
  // stamp is max(now, current + 1, lastLocalStamp + 1, U_MIN) and origin = self (§5.2, §6.4).
  bool localEdit(const Body& fields, int64_t nowMs, const Id8& self, FakeEntry* out) {
    const FakeEntry* cur = get(fields.key);
    Body b = fields;
    b.updatedAt = localStamp(nowMs, cur ? cur->version.updatedAt : 0, lastLocalStamp);
    lastLocalStamp = b.updatedAt;
    b.hasOrigin = true;
    b.origin = self;
    RecordClass cls = CLS_NONE;
    if (!validateBodyFields(b, &cls).ok()) return false;
    uint8_t buf[BODY_MAX];
    size_t len = 0;
    if (!encodeBody(b, buf, sizeof(buf), &len).ok()) return false;
    store(b, buf, len, false, zeroId8(), out);
    return true;
  }

  // Inserts a known entry verbatim (seeding a transcript node).
  bool restore(const uint8_t* body, size_t n, uint32_t s, bool hasF, const Id8& f) {
    Body b;
    RecordClass cls = CLS_NONE;
    if (!decodeBody(body, n, &b, &cls).ok()) return false;
    FakeEntry e;
    fill(&e, b, body, n, s, hasF, f);
    FakeEntry* cur = get(b.key);
    if (cur) {
      *cur = e;
    } else {
      entries.push_back(e);
    }
    return true;
  }

 private:
  static void fill(FakeEntry* e, const Body& b, const uint8_t* body, size_t n, uint32_t s, bool hasF,
                   const Id8& f) {
    memset(e, 0, sizeof(*e));
    e->key = b.key;
    e->version = versionOf(b, body, n);
    RecordClass cls = CLS_NONE;
    validateBodyFields(b, &cls);
    e->cls = cls;
    e->flags = b.flags;
    e->hasOrigin = b.hasOrigin;
    e->origin = b.hasOrigin ? b.origin : zeroId8();
    e->bodyLen = (uint16_t)n;
    memcpy(e->body, body, n);
    e->s = s;
    e->hasF = hasF;
    e->f = hasF ? f : zeroId8();
  }

  // s = nextSyncSeq++, then the tombstone cap (sync_ref Ledger._store / _evict_tombstones).
  void store(const Body& b, const uint8_t* body, size_t n, bool hasF, const Id8& f, FakeEntry* out) {
    FakeEntry e;
    fill(&e, b, body, n, nextSyncSeq++, hasF, f);
    if (out) *out = e;
    FakeEntry* cur = get(e.key);
    if (cur) {
      *cur = e;
    } else {
      entries.push_back(e);
    }
    if (!e.deleted()) return;
    size_t tombs = tombstones();
    while (tombs > tombstoneCap) {
      size_t victim = entries.size();
      for (size_t i = 0; i < entries.size(); i++) {
        if (!entries[i].deleted()) continue;
        if (victim == entries.size()) {
          victim = i;
          continue;
        }
        const int c = compareVersions(entries[i].version, entries[victim].version);
        if (c < 0 || (c == 0 && compareKeyBytes(entries[i].key, entries[victim].key) < 0)) victim = i;
      }
      if (victim == entries.size()) break;
      entries.erase(entries.begin() + (std::vector<FakeEntry>::difference_type)victim);
      tombs--;
    }
  }
};

// ---- a scripted gate --------------------------------------------------------------------------------
class FakeGate : public TxGate {
 public:
  bool timed;
  bool hasDue;
  uint32_t dueAt;   // absolute mono ms of the engine's next deadline
  bool cmdWaiting;
  bool ota;

  FakeGate() : timed(false), hasDue(false), dueAt(0), cmdWaiting(false), ota(false) {}

  bool timedJob() override { return timed; }
  uint32_t msUntilDue(uint32_t now) override {
    if (!hasDue) return HUB_NO_DEADLINE;
    const int32_t rel = (int32_t)(dueAt - now);
    return rel > 0 ? (uint32_t)rel : 0;
  }
  bool cmdQueueEmpty() override { return !cmdWaiting; }
  bool otaBusy() override { return ota; }

  bool flashOpen(uint32_t now) { return hubFlashWorkAllowed(*this, now, false); }
};

// ---- the fake library store -------------------------------------------------------------------------
class FakeHubDb : public HubDb {
 public:
  // scripting
  bool allowPage;      // canTakePage
  bool allowLive;      // reserveLive
  uint32_t capRecords; // 0: no cap; else FULL for a new key at capRecords
  TxGate* gate;        // NULL: always open
  // state
  uint8_t st;
  FakeLedger ledger;
  FakeLedger snap;     // the flushed image
  uint32_t durable;
  Id8 id;
  GroupState grp;
  bool fullFlag;
  bool repullFlag;
  bool repullNeeded;
  uint32_t liveHigh;   // NVS "live"
  // counters
  uint32_t flushes;
  uint32_t forcedFlushes;
  uint32_t flashWhileClosed;  // flushes / live writes done while the flash gate was closed (unforced)
  uint32_t liveSkipped;
  uint32_t liveReserved;
  uint32_t pageTraffic;
  uint32_t resets;
  uint32_t feedEntries;

  struct Peer {
    bool used;
    Id8 id;
    PeerState st;
    uint8_t kind;
    uint32_t lastSyncS;
    uint32_t lastUse;
    bool pending;
    PeerState pendingSt;
    uint32_t needSeq;
    bool hasPersisted;
    PeerState persisted;
  };
  Peer peers[HUB_PEERS_MAX];
  uint32_t useTick;

  FakeHubDb() { wipeAll(zeroId8()); }

  void wipeAll(const Id8& dbId) {
    allowPage = true;
    allowLive = true;
    capRecords = 0;
    gate = NULL;
    st = DB_READY;
    ledger = FakeLedger();
    snap = FakeLedger();
    durable = 0;
    id = dbId;
    memset(&grp, 0, sizeof(grp));
    fullFlag = false;
    repullFlag = false;
    repullNeeded = false;
    liveHigh = 0;
    flushes = forcedFlushes = flashWhileClosed = liveSkipped = liveReserved = pageTraffic = resets = 0;
    feedEntries = 0;
    memset(peers, 0, sizeof(peers));
    useTick = 0;
  }

  // ---- seeding (a transcript node's initial state: everything durable) ------------------------
  void seedEntry(const uint8_t* body, size_t n, uint32_t s, bool hasF, const Id8& f) {
    ledger.restore(body, n, s, hasF, f);
  }
  void seedDone(uint32_t nextSyncSeq, uint32_t durableHigh) {
    ledger.nextSyncSeq = nextSyncSeq;
    durable = durableHigh;
    snap = ledger;
  }
  void seedPeer(const Id8& peer, const Id8& dbId, uint32_t wm, bool excludeOk) {
    PeerState* p = peerGet(peer, 0);
    p->dbId = dbId;
    p->wm = wm;
    p->excludeOk = excludeOk;
    Peer* e = slot(peer);
    e->hasPersisted = true;
    e->persisted = *p;
  }

  // ---- crash / reboot: only what was flushed (and persisted) survives -----------------------------
  void crash(const Id8& newDbIdIfLost) {
    ledger = snap;
    ledger.nextSyncSeq = durable + 1;
    for (uint8_t i = 0; i < HUB_PEERS_MAX; i++) {
      Peer& p = peers[i];
      if (!p.used) continue;
      p.pending = false;
      if (p.hasPersisted) {
        p.st = p.persisted;
      } else {
        p.used = false;
      }
    }
    if (liveHigh > durable) {  // a live-forwarded seq was lost: a new feed identity (D-P2-4)
      id = newDbIdIfLost;
      memset(peers, 0, sizeof(peers));
      liveHigh = 0;
    }
    st = DB_READY;
  }

  // ---- HubDb ------------------------------------------------------------------------------------
  void begin(const HubDbConfig& cfg, uint32_t now) override {
    (void)cfg;
    (void)now;
    if (st == DB_OFF) st = DB_READY;
  }
  uint8_t state() const override { return st; }
  bool ready() const override { return st == DB_READY; }
  bool maintain(uint32_t now) override {
    (void)now;
    return false;
  }
  bool maintenanceDue(uint32_t now) override {
    (void)now;
    return false;
  }

  Id8 dbId() const override { return id; }
  uint32_t durableHigh() const override { return durable; }
  uint32_t lastSeq() const override { return ledger.nextSyncSeq - 1; }

  DbAccept accept(const uint8_t* body, size_t len, const Id8& syncFrom, bool nowKnown, int64_t nowMs,
                  bool live, uint32_t now) override {
    (void)live;
    (void)now;
    DbAccept r;
    memset(&r, 0, sizeof(r));
    Key k;
    if (bodyErrKey(body, len, &k)) {
      r.hasKey = true;
      r.key = k;
    }
    if (!ready()) {
      r.result = DBR_NOT_READY;
      return r;
    }
    if (capRecords) {
      Body b;
      Version v;
      Status e;
      const ApplyStatus pre = applyCheck(body, len, nowKnown, nowMs, NULL, &b, &v, &e);
      if (pre == APPLY_ACCEPT && !ledger.get(b.key) && ledger.entries.size() >= capRecords) {
        fullFlag = true;
        r.result = DBR_FULL;
        return r;
      }
    }
    FakeEntry e;
    const ApplyStatus s = ledger.applyRemote(body, len, syncFrom, nowKnown, nowMs, &e);
    r.result = s;
    if (s == APPLY_ACCEPT) r.seq = e.s;
    return r;
  }

  bool lookup(const Key& key, DbEntry* out) override {
    const FakeEntry* e = ledger.get(key);
    if (!e) return false;
    toDbEntry(*e, out);
    return true;
  }

  bool canTakePage(uint16_t maxBytes, uint32_t now) override {
    (void)maxBytes;
    (void)now;
    if (gate && !hubLightWorkAllowed(*gate)) return false;
    return allowPage && ready();
  }

  bool reserveLive(uint32_t seq, uint32_t now) override {
    if (seq <= durable || seq <= liveHigh) return true;
    if (!allowLive || (gate && !hubFlashWorkAllowed(*gate, now, false))) {
      liveSkipped++;
      return false;
    }
    liveHigh = seq;
    liveReserved++;
    return true;
  }

  void notePageTraffic(uint32_t now) override {
    (void)now;
    pageTraffic++;
  }

  uint32_t dirtyBytes() const override {
    uint32_t n = 0;
    for (size_t i = 0; i < ledger.entries.size(); i++)
      if (ledger.entries[i].s > durable) n += HUB_LOG_OVERHEAD + ledger.entries[i].bodyLen;
    return n;
  }

  uint8_t flush(uint32_t now, bool force) override {
    const bool open = gate == NULL || hubFlashWorkAllowed(*gate, now, false);
    if (!force && !open) return DB_FLUSH_DEFERRED;
    if (lastSeq() == durable) return DB_FLUSH_NONE;
    if (force) forcedFlushes++;
    durable = lastSeq();
    snap = ledger;
    flushes++;
    for (uint8_t i = 0; i < HUB_PEERS_MAX; i++) persistIfSafe(peers[i]);
    return DB_FLUSH_DONE;
  }

  void feedBegin(FeedCursor* c, uint32_t since, uint32_t limit) override {
    memset(c, 0, sizeof(*c));
    c->w[0] = since;
    c->w[1] = limit;
  }

  uint8_t feedNext(FeedCursor* c, FeedBudget* budget, DbEntry* out) override {
    if (!ready()) return DB_FEED_NOT_READY;
    const FakeEntry* best = NULL;
    for (size_t i = 0; i < ledger.entries.size(); i++) {
      const FakeEntry& e = ledger.entries[i];
      if (e.s <= c->w[0] || e.s > c->w[1]) continue;
      if (!best || e.s < best->s) best = &e;
    }
    if (!best) return DB_FEED_END;
    if (budget->entries == 0) return DB_FEED_YIELD;
    budget->entries--;
    const uint16_t sz = (uint16_t)(HUB_LOG_OVERHEAD + best->bodyLen);
    budget->bytes = budget->bytes > sz ? (uint16_t)(budget->bytes - sz) : 0;
    c->w[0] = best->s;
    feedEntries++;
    toDbEntry(*best, out);
    return DB_FEED_ENTRY;
  }

  PeerState* peerFind(const Id8& pid) override {
    Peer* p = slot(pid);
    return p ? &p->st : NULL;
  }

  PeerState* peerGet(const Id8& pid, uint8_t kind) override {
    Peer* p = slot(pid);
    if (!p) {
      p = &peers[0];
      for (uint8_t i = 0; i < HUB_PEERS_MAX; i++) {
        if (!peers[i].used) {
          p = &peers[i];
          break;
        }
        if (peers[i].lastUse < p->lastUse) p = &peers[i];
      }
      memset(p, 0, sizeof(*p));
      p->used = true;
      p->id = pid;
      p->st.dbId = zeroId8();
    }
    if (kind) p->kind = kind;
    p->lastUse = ++useTick;
    return &p->st;
  }

  void peerCommitted(const Id8& pid, uint32_t wallS, uint32_t now) override {
    (void)now;
    Peer* p = slot(pid);
    if (!p) return;
    p->lastSyncS = wallS;
    p->pending = true;
    p->pendingSt = p->st;
    p->needSeq = lastSeq();
    persistIfSafe(*p);
  }

  void peerSessionEnd(const Id8& pid, uint32_t now) override {
    (void)pid;
    (void)now;
  }

  void zeroAllWm(uint32_t now) override {
    (void)now;
    for (uint8_t i = 0; i < HUB_PEERS_MAX; i++) {
      Peer& p = peers[i];
      if (!p.used) continue;
      p.st.wm = 0;
      p.pending = true;
      p.pendingSt = p.st;
      p.needSeq = lastSeq();
      persistIfSafe(p);
    }
  }

  uint8_t peerCount() const override {
    uint8_t n = 0;
    for (uint8_t i = 0; i < HUB_PEERS_MAX; i++)
      if (peers[i].used) n++;
    return n;
  }

  bool peerAt(uint8_t i, DbPeer* out) const override {
    uint8_t k = 0;
    for (uint8_t j = 0; j < HUB_PEERS_MAX; j++) {
      if (!peers[j].used) continue;
      if (k++ != i) continue;
      out->id = peers[j].id;
      out->st = peers[j].st;
      out->kind = peers[j].kind;
      out->lastSyncEpochS = peers[j].lastSyncS;
      return true;
    }
    return false;
  }

  const GroupState& group() const override { return grp; }
  void setGroup(const GroupState& g, uint32_t now) override {
    (void)now;
    grp = g;
    if (!grp.grouped) memset(&grp, 0, sizeof(grp));
  }

  bool full() const override { return fullFlag; }
  bool takeRepullNeeded() override {
    if (!repullNeeded) return false;
    repullNeeded = false;
    return true;
  }
  // Test hook: hubFull clears (spec §4.8) -> takeRepullNeeded() once.
  void clearFull() {
    if (fullFlag || repullFlag) repullNeeded = true;
    fullFlag = false;
    repullFlag = false;
  }

  void requestReset(const Id8& newDbId, uint32_t now) override {
    (void)now;
    const GroupState keep = grp;
    TxGate* g = gate;
    const uint32_t cap = capRecords;
    const uint32_t r = resets;
    wipeAll(newDbId);
    grp = keep;
    gate = g;
    capRecords = cap;
    resets = r + 1;
  }

  void stats(DbStats* out) const override {
    memset(out, 0, sizeof(*out));
    out->state = st;
    out->records = (uint32_t)ledger.entries.size();
    out->cap = capRecords;
    for (size_t i = 0; i < ledger.entries.size(); i++) {
      const FakeEntry& e = ledger.entries[i];
      if (e.deleted()) out->tombstones++;
      if (e.cls == CLS_PRESENCE) out->presences++;
      out->liveBytes += HUB_LOG_OVERHEAD + e.bodyLen;
    }
    out->lastSeq = lastSeq();
    out->durableHigh = durable;
    out->dirtyBytes = dirtyBytes();
    out->full = fullFlag;
    out->repull = repullFlag;
    out->flushes = flushes;
    out->liveSkipped = liveSkipped;
  }

 private:
  Peer* slot(const Id8& pid) {
    for (uint8_t i = 0; i < HUB_PEERS_MAX; i++)
      if (peers[i].used && peers[i].id == pid) return &peers[i];
    return NULL;
  }

  void persistIfSafe(Peer& p) {
    if (!p.used || !p.pending || p.needSeq > durable) return;
    p.pending = false;
    p.hasPersisted = true;
    p.persisted = p.pendingSt;
  }

  void toDbEntry(const FakeEntry& e, DbEntry* out) const {
    memset(out, 0, sizeof(*out));
    out->seq = e.s;
    out->durable = e.s <= durable;
    out->hasSyncFrom = e.hasF;
    out->syncFrom = e.f;
    out->hasOrigin = e.hasOrigin;
    out->origin = e.origin;
    out->version = e.version;
    out->cls = e.cls;
    out->body = e.body;
    out->bodyLen = e.bodyLen;
  }
};

}  // namespace mmsync

#endif  // !ARDUINO
