// MagicMaker SYNC v1: heard-packet events, routing and page serving (docs/SYNC_PROTOCOL.md
// §8, §15.2, §16). Pure logic over sync_codec.h types: no I/O, no clocks, no heap.
//
//   EvtDedupe     iPhone receiver window per origin (§8.2) + EVT_GAP handling (§8.4)
//   replayPlan    Android's answer to a catch-up request (§8.5)
//   route*        live record / event / heartbeat forwarding, Android route 1/2/3 (§16)
//   subsFor, capsForKind, hbReplaces
//   PageServer    durable-only PULL serving with exclusion (§15.2), incremental so the hub can
//                 spread one page over several loop passes
//
// The hub uses the routing and page-serving parts; the event window and replay plan are the
// phones' logic, kept here so the shared vectors (and the P2 node simulation) cover them in C++.
#pragma once

#include "sync_codec.h"

namespace mmsync {

// ---- Event dedupe window (§8.2) ----------------------------------------------------------------
struct EvtWindow {
  uint32_t epoch;
  uint32_t hc;    // highest contiguous seq received
  uint64_t bits;  // bit i: seq hc + 1 + i received
};

enum EvtResult : uint8_t { EVT_ACCEPT = 1, EVT_DUPLICATE = 2 };

struct EvtRequest {  // an EVT_SINCE to send: (origin, epoch, afterSeq)
  uint32_t epoch;
  uint32_t afterSeq;
};

inline uint32_t popcount64(uint64_t x) {
  uint32_t n = 0;
  while (x) {
    x &= x - 1;
    n++;
  }
  return n;
}

inline void evtNormalize(EvtWindow* w) {
  while (w->bits & 1u) {
    w->hc++;
    w->bits >>= 1;
  }
}

// Moves hc up to floor; returns how many seqs in (hc, floor] were never received.
inline uint32_t evtAdvanceFloor(EvtWindow* w, uint32_t floor) {
  if (floor <= w->hc) return 0;
  const uint32_t shift = floor - w->hc;
  uint32_t got;
  if (shift >= EVT_WINDOW_BITS) {
    got = popcount64(w->bits);
    w->bits = 0;
  } else {
    got = popcount64(w->bits & ((((uint64_t)1) << shift) - 1));
    w->bits >>= shift;
  }
  w->hc = floor;
  evtNormalize(w);
  return shift - got;
}

// Receiver state for up to N origins, each with the windows of its EVT_EPOCHS_KEPT newest epochs
// (oldest first). When a new origin arrives and all N slots are used, the least recently used
// origin is forgotten (only Android originates events, so N = 4 is plenty).
template <size_t N = 4>
class EvtDedupe {
 public:
  EvtDedupe() { clear(); }

  void clear() {
    memset(slots_, 0, sizeof(slots_));
    tick_ = 0;
  }

  // -> EVT_ACCEPT or EVT_DUPLICATE; *lost = seqs passed over by a slide (never received).
  EvtResult receive(const Id8& origin, uint32_t epoch, uint32_t seq, uint32_t* lost) {
    *lost = 0;
    if (seq == 0) return EVT_DUPLICATE;  // not a valid seq (EVT decode rejects it)
    Slot* s = find(origin);
    EvtWindow* w = s ? windowIn(s, epoch) : NULL;
    if (!w) {
      if (!s || s->count == 0) {
        if (!s) s = alloc(origin);
        w = open(s, epoch, seq - 1);  // first contact: no history
      } else if (epoch > s->w[s->count - 1].epoch) {
        w = open(s, epoch, 0);  // new epoch: from seq 1
      } else {
        return EVT_DUPLICATE;  // older than the kept epochs
      }
    }
    touch(s);
    if (seq <= w->hc) return EVT_DUPLICATE;
    if ((uint64_t)seq > (uint64_t)w->hc + EVT_WINDOW_BITS)
      *lost = evtAdvanceFloor(w, seq - EVT_WINDOW_BITS);
    const uint32_t idx = seq - w->hc - 1;
    if ((w->bits >> idx) & 1u) return EVT_DUPLICATE;
    w->bits |= ((uint64_t)1) << idx;
    evtNormalize(w);
    return EVT_ACCEPT;
  }

  bool hasHoles(const Id8& origin, uint32_t epoch) const {
    const EvtWindow* w = window(origin, epoch);
    return w != NULL && w->bits != 0;
  }

  const EvtWindow* window(const Id8& origin, uint32_t epoch) const {
    const Slot* s = find(origin);
    if (!s) return NULL;
    for (uint8_t i = 0; i < s->count; i++)
      if (s->w[i].epoch == epoch) return &s->w[i];
    return NULL;
  }

  const EvtWindow* newest(const Id8& origin) const {
    const Slot* s = find(origin);
    return (s && s->count) ? &s->w[s->count - 1] : NULL;
  }

  // The origin's windows, oldest first; returns the count (0..EVT_EPOCHS_KEPT).
  uint8_t windows(const Id8& origin, const EvtWindow** out) const {
    const Slot* s = find(origin);
    if (!s) return 0;
    for (uint8_t i = 0; i < s->count; i++) out[i] = &s->w[i];
    return s->count;
  }

  // EVT_GAP handling (§8.4). Returns the number of EVT_SINCE requests written to req (0 or 1).
  uint8_t onGap(const Id8& origin, uint32_t epoch, uint32_t firstAvail, uint32_t lastAvail,
                uint32_t curEpoch, uint32_t* lost, EvtRequest* req) {
    (void)lastAvail;
    *lost = 0;
    Slot* s = find(origin);
    if (firstAvail > 0) {
      EvtWindow* w = s ? windowIn(s, epoch) : NULL;
      if (w && (uint64_t)firstAvail > (uint64_t)w->hc + 1) {
        *lost = evtAdvanceFloor(w, firstAvail - 1);
        req->epoch = epoch;
        req->afterSeq = w->hc;
        return 1;
      }
      return 0;
    }
    if (curEpoch > epoch) {
      EvtWindow* wc = s ? windowIn(s, curEpoch) : NULL;
      if (!wc) {
        if (!s || s->count == 0 || curEpoch > s->w[s->count - 1].epoch) {
          if (!s) s = alloc(origin);
          wc = open(s, curEpoch, 0);
        }
      }
      if (wc) {
        req->epoch = curEpoch;
        req->afterSeq = wc->hc;
        return 1;
      }
    }
    return 0;
  }

 private:
  struct Slot {
    bool used;
    Id8 origin;
    uint8_t count;
    EvtWindow w[EVT_EPOCHS_KEPT];
    uint32_t lastUse;
  };

  Slot* find(const Id8& origin) {
    for (size_t i = 0; i < N; i++)
      if (slots_[i].used && slots_[i].origin == origin) return &slots_[i];
    return NULL;
  }
  const Slot* find(const Id8& origin) const {
    for (size_t i = 0; i < N; i++)
      if (slots_[i].used && slots_[i].origin == origin) return &slots_[i];
    return NULL;
  }

  static EvtWindow* windowIn(Slot* s, uint32_t epoch) {
    for (uint8_t i = 0; i < s->count; i++)
      if (s->w[i].epoch == epoch) return &s->w[i];
    return NULL;
  }

  void touch(Slot* s) { s->lastUse = ++tick_; }

  Slot* alloc(const Id8& origin) {
    Slot* pick = &slots_[0];
    for (size_t i = 0; i < N; i++) {
      if (!slots_[i].used) {
        pick = &slots_[i];
        break;
      }
      if (slots_[i].lastUse < pick->lastUse) pick = &slots_[i];
    }
    memset(pick, 0, sizeof(*pick));
    pick->used = true;
    pick->origin = origin;
    touch(pick);
    return pick;
  }

  // Adds a window, keeps them sorted by epoch and only the newest EVT_EPOCHS_KEPT.
  EvtWindow* open(Slot* s, uint32_t epoch, uint32_t hc) {
    EvtWindow nw;
    nw.epoch = epoch;
    nw.hc = hc;
    nw.bits = 0;
    EvtWindow all[EVT_EPOCHS_KEPT + 1];
    uint8_t n = 0;
    bool placed = false;
    for (uint8_t i = 0; i < s->count; i++) {
      if (!placed && epoch < s->w[i].epoch) {
        all[n++] = nw;
        placed = true;
      }
      all[n++] = s->w[i];
    }
    if (!placed) all[n++] = nw;
    const uint8_t drop = n > EVT_EPOCHS_KEPT ? (uint8_t)(n - EVT_EPOCHS_KEPT) : 0;
    s->count = 0;
    EvtWindow* res = NULL;
    for (uint8_t i = drop; i < n; i++) {
      s->w[s->count] = all[i];
      if (all[i].epoch == epoch) res = &s->w[s->count];
      s->count++;
    }
    return res;  // NULL only if the new window was itself the oldest dropped
  }

  Slot slots_[N];
  uint32_t tick_;
};

// ---- Android replay plan (§8.5) --------------------------------------------------------------------
struct RingEvt {
  uint32_t epoch;
  uint32_t seq;
};

struct PlanItem {
  bool gap;  // false: replay (epoch, seq); true: EVT_GAP{epoch, firstAvail, lastAvail, curEpoch}
  uint32_t epoch;
  uint32_t seq;
  uint32_t firstAvail;
  uint32_t lastAvail;
  uint32_t curEpoch;
};

namespace detail {

inline bool ringHas(const RingEvt* ring, size_t n, uint32_t epoch, uint32_t seq) {
  for (size_t i = 0; i < n; i++)
    if (ring[i].epoch == epoch && ring[i].seq == seq) return true;
  return false;
}

// min / max seq of an epoch in the ring (0 / 0 when none); returns whether any exist.
inline bool ringRange(const RingEvt* ring, size_t n, uint32_t epoch, uint32_t* mn, uint32_t* mx) {
  bool any = false;
  *mn = 0;
  *mx = 0;
  for (size_t i = 0; i < n; i++) {
    if (ring[i].epoch != epoch) continue;
    if (!any || ring[i].seq < *mn) *mn = ring[i].seq;
    if (!any || ring[i].seq > *mx) *mx = ring[i].seq;
    any = true;
  }
  return any;
}

template <class F>
inline void replayEpoch(const RingEvt* ring, size_t n, uint32_t epoch, uint32_t after, F& emit) {
  for (size_t i = 0; i < n; i++) {
    if (ring[i].epoch != epoch || ring[i].seq <= after) continue;
    PlanItem p;
    memset(&p, 0, sizeof(p));
    p.epoch = epoch;
    p.seq = ring[i].seq;
    emit(p);
  }
}

template <class F>
inline void planGap(const RingEvt* ring, size_t n, uint32_t epoch, uint32_t curEpoch, F& emit) {
  PlanItem p;
  memset(&p, 0, sizeof(p));
  p.gap = true;
  p.epoch = epoch;
  ringRange(ring, n, epoch, &p.firstAvail, &p.lastAvail);
  p.curEpoch = curEpoch;
  emit(p);
}

template <class F>
inline void planCur(const RingEvt* ring, size_t n, uint32_t curEpoch, uint32_t curSeq, uint32_t s,
                    F& emit) {
  if (s >= curSeq) return;
  if (ringHas(ring, n, curEpoch, s + 1)) {
    replayEpoch(ring, n, curEpoch, s, emit);
  } else {
    planGap(ring, n, curEpoch, curEpoch, emit);
  }
}

}  // namespace detail

// The plan for a catch-up request (epoch, afterSeq) against the ring (oldest first), calling
// emit(const PlanItem&) per item, in send order.
template <class F>
inline void replayPlan(const RingEvt* ring, size_t n, uint32_t curEpoch, uint32_t curSeq,
                       uint32_t epoch, uint32_t afterSeq, F emit) {
  if (epoch > curEpoch) return;
  if (epoch == curEpoch) {
    detail::planCur(ring, n, curEpoch, curSeq, afterSeq, emit);
    return;
  }
  uint32_t mn, mx;
  const bool any = detail::ringRange(ring, n, epoch, &mn, &mx);
  if (any && detail::ringHas(ring, n, epoch, afterSeq + 1)) {
    detail::replayEpoch(ring, n, epoch, afterSeq, emit);
    detail::planCur(ring, n, curEpoch, curSeq, 0, emit);
    return;
  }
  if (any && afterSeq >= mx) {
    detail::planCur(ring, n, curEpoch, curSeq, 0, emit);
    return;
  }
  detail::planGap(ring, n, epoch, curEpoch, emit);
}

// ---- Routing (§16) -------------------------------------------------------------------------------
// A session as routing sees it: the peer, whether the peer subscribed to the kind of message
// being routed, and whether the session is AUTHED+ ("member").
struct RouteSession {
  Id8 peer;
  bool sub;
  bool ok;
};

// seenBy merge: the existing list in order, then new ids not yet present, first SEENBY_MAX kept.
inline uint8_t mergeSeen(const Id8* base, size_t nBase, const Id8* extra, size_t nExtra,
                         Id8 out[SEENBY_MAX]) {
  uint8_t n = 0;
  for (size_t pass = 0; pass < 2; pass++) {
    const Id8* src = pass == 0 ? base : extra;
    const size_t cnt = pass == 0 ? nBase : nExtra;
    for (size_t i = 0; i < cnt && n < SEENBY_MAX; i++) {
      bool dup = false;
      for (uint8_t k = 0; k < n; k++)
        if (out[k] == src[i]) dup = true;
      if (!dup) out[n++] = src[i];
    }
  }
  return n;
}

inline bool idIn(const Id8& x, const Id8* list, size_t n) {
  for (size_t i = 0; i < n; i++)
    if (list[i] == x) return true;
  return false;
}

// Result of a routing decision: indices into the sessions array (in session order) and the seenBy
// list to send with.
struct Route {
  uint8_t nTargets;
  uint8_t targets[16];
  uint8_t nSeen;
  Id8 seenBy[SEENBY_MAX];
};

namespace detail {

inline void routeSeen(const Id8& self, const RouteSession* s, Route* r, const Id8* base,
                      size_t nBase) {
  Id8 extra[1 + 16];
  size_t ne = 0;
  extra[ne++] = self;
  for (uint8_t i = 0; i < r->nTargets; i++) extra[ne++] = s[r->targets[i]].peer;
  r->nSeen = mergeSeen(base, nBase, extra, ne, r->seenBy);
}

}  // namespace detail

// A local change: every AUTHED+, records-subscribed session; seenBy = [self] + targets.
inline Route routeLocalRec(const Id8& self, const RouteSession* s, size_t n) {
  Route r;
  memset(&r, 0, sizeof(r));
  for (size_t i = 0; i < n && r.nTargets < 16; i++)
    if (s[i].ok && s[i].sub) r.targets[r.nTargets++] = (uint8_t)i;
  detail::routeSeen(self, s, &r, NULL, 0);
  return r;
}

// First accept of a live REC from `sender`. origin NULL (or zero) = PRESENCE (no origin). No
// targets: seenBy is returned unchanged and nothing is sent.
inline Route routeLiveRec(const Id8& self, const Id8& sender, const Id8* origin, const Id8* seenBy,
                          size_t nSeen, const RouteSession* s, size_t n) {
  Route r;
  memset(&r, 0, sizeof(r));
  const bool hasOrigin = origin != NULL && !isZero(*origin);
  for (size_t i = 0; i < n && r.nTargets < 16; i++) {
    const Id8& p = s[i].peer;
    if (!s[i].ok || !s[i].sub) continue;
    if (idIn(p, seenBy, nSeen) || p == sender || (hasOrigin && p == *origin) || p == self) continue;
    r.targets[r.nTargets++] = (uint8_t)i;
  }
  if (r.nTargets == 0) {
    r.nSeen = (uint8_t)(nSeen > SEENBY_MAX ? SEENBY_MAX : nSeen);
    for (uint8_t k = 0; k < r.nSeen; k++) r.seenBy[k] = seenBy[k];
    return r;
  }
  detail::routeSeen(self, s, &r, seenBy, nSeen);
  return r;
}

// Hub relay of an EVT from `sender` (§16.3): sessions are (peer, events-subscribed, member).
inline Route routeEvtRelay(const Id8& self, const Id8& sender, const Id8& origin, const Id8* seenBy,
                           size_t nSeen, const RouteSession* s, size_t n) {
  Route r;
  memset(&r, 0, sizeof(r));
  for (size_t i = 0; i < n && r.nTargets < 16; i++) {
    const Id8& p = s[i].peer;
    if (!s[i].ok || !s[i].sub) continue;
    if (idIn(p, seenBy, nSeen) || p == sender || p == origin || p == self) continue;
    r.targets[r.nTargets++] = (uint8_t)i;
  }
  if (r.nTargets == 0) {
    r.nSeen = (uint8_t)(nSeen > SEENBY_MAX ? SEENBY_MAX : nSeen);
    for (uint8_t k = 0; k < r.nSeen; k++) r.seenBy[k] = seenBy[k];
    return r;
  }
  detail::routeSeen(self, s, &r, seenBy, nSeen);
  return r;
}

// HB forwarding (§16.4): only hops-0 HBs, once, to member heartbeat-subscribed sessions whose peer
// is neither the sender nor the described device. Returns the target count (indices in out).
inline uint8_t routeHb(const Id8& self, const Id8& sender, const Id8& described, uint8_t hops,
                       const RouteSession* s, size_t n, uint8_t* out) {
  if (hops != 0) return 0;
  uint8_t k = 0;
  for (size_t i = 0; i < n; i++) {
    const Id8& p = s[i].peer;
    if (!s[i].ok || !s[i].sub) continue;
    if (p == sender || p == described || p == self) continue;
    out[k++] = (uint8_t)i;
  }
  return k;
}

// Android route per event (§16.3): 1 = direct to the iPhone, 2 = via the hub, 3 = ring only.
struct AndroidSessionView {
  bool present;
  Id8 peer;
  bool up;         // AUTHED / SYNCING / SYNCED
  bool subEvents;  // the iPhone subscribed to events (iPhone session only)
};

struct EvtRoute {
  uint8_t route;
  bool hasTarget;
  Id8 target;
  uint8_t nSeen;
  Id8 seenBy[2];
};

inline EvtRoute androidEventRoute(const Id8& self, const AndroidSessionView& ios,
                                  const AndroidSessionView& hub, bool hubHbKnown,
                                  uint32_t hubHbAgeMs, const HbLink* hubLinks, size_t nLinks) {
  EvtRoute r;
  memset(&r, 0, sizeof(r));
  if (ios.present && ios.up && ios.subEvents) {
    r.route = 1;
    r.hasTarget = true;
    r.target = ios.peer;
    r.nSeen = 2;
    r.seenBy[0] = self;
    r.seenBy[1] = ios.peer;
    return r;
  }
  if (hub.present && hub.up && hubHbKnown && hubHbAgeMs <= T_PATH_FRESH_MS) {
    for (size_t i = 0; i < nLinks; i++) {
      if (hubLinks[i].peerKind == KIND_IOS && (hubLinks[i].flags & HB_LINK_SYNCED)) {
        r.route = 2;
        r.hasTarget = true;
        r.target = hub.peer;
        r.nSeen = 2;
        r.seenBy[0] = self;
        r.seenBy[1] = hub.peer;
        return r;
      }
    }
  }
  r.route = 3;
  return r;
}

// Keep-latest rule for heartbeats: a new one replaces the stored one iff bootId differs or
// hbSeq is greater.
inline bool hbReplaces(bool haveStored, uint16_t storedBootId, uint32_t storedHbSeq,
                       uint16_t bootId, uint32_t hbSeq) {
  if (!haveStored) return true;
  if (bootId != storedBootId) return true;
  return hbSeq > storedHbSeq;
}

// The subs a node sends in HELLO to a peer (§16.1). Does not depend on the peer's kind in v1.
inline uint8_t subsFor(uint8_t selfKind, uint8_t peerKind) {
  (void)peerKind;
  switch (selfKind) {
    case KIND_HUB:
    case KIND_IOS:
      return SUB_RECORDS | SUB_EVENTS | SUB_HEARTBEATS;
    case KIND_ANDROID:
      return SUB_RECORDS | SUB_HEARTBEATS;
    default:
      return 0;
  }
}

inline uint16_t capsForKind(uint8_t kind) {
  switch (kind) {
    case KIND_HUB:
      return CAPS_HUB;
    case KIND_ANDROID:
      return CAPS_ANDROID;
    case KIND_IOS:
      return CAPS_IOS;
    default:
      return 0;
  }
}

// ---- Page serving (§15.2) --------------------------------------------------------------------------
enum PageStep : uint8_t {
  PAGE_SEND = 1,  // a REC was written to out: send it
  PAGE_SKIP = 2,  // not served (excluded, or outside since..durableHigh); keep offering
  PAGE_STOP = 3   // the page is full: send PAGE_END (end()) now
};

// Serves one PULL. Offer the server's CURRENT entries (one per key) in ascending seq; stop at the
// first PAGE_STOP. Then send end(). When end().more == 0 the node sets excludeOk[puller] = true.
class PageServer {
 public:
  PageServer()
      : reqId_(0), since_(0), limit_(0), maxBytes_(0), durableHigh_(0), exclusion_(false),
        puller_(zeroId8()), scanned_(0), used_(0), count_(0), stopped_(true) {}

  void begin(uint8_t reqId, uint32_t since, uint8_t limit, uint16_t maxBytes, uint32_t durableHigh,
             bool exclusion, const Id8& puller) {
    reqId_ = reqId;
    since_ = since;
    limit_ = limit;
    maxBytes_ = maxBytes;
    durableHigh_ = durableHigh;
    exclusion_ = exclusion;
    puller_ = puller;
    scanned_ = since;
    used_ = 0;
    count_ = 0;
    stopped_ = since >= durableHigh;
  }

  // Exclusion is active iff the PULL asked for it and excludeOk[puller] holds.
  void begin(const Pull& p, uint32_t durableHigh, bool excludeOk, const Id8& puller) {
    begin(p.reqId, p.since, p.limitValue(), p.maxBytesValue(), durableHigh,
          p.excludeValue() == 1 && excludeOk, puller);
  }

  // origin / syncFrom: NULL when absent. out: capacity for the REC (BODY_MAX + 10 is enough).
  PageStep offer(uint32_t seq, const uint8_t* body, size_t bodyLen, const Id8* origin,
                 const Id8* syncFrom, uint8_t* out, size_t cap, size_t* outLen) {
    *outLen = 0;
    if (stopped_) return PAGE_STOP;
    if (seq <= since_ || seq > durableHigh_) return PAGE_SKIP;
    if (exclusion_ && ((origin && *origin == puller_) || (syncFrom && *syncFrom == puller_))) {
      scanned_ = seq;  // skipped, still scanned
      return PAGE_SKIP;
    }
    const size_t len = recLen(bodyLen);
    if (count_ >= limit_ || (count_ > 0 && used_ + len > maxBytes_) || len > cap ||
        bodyLen > BODY_MAX) {
      stopped_ = true;
      return PAGE_STOP;
    }
    Writer w(out, cap);
    w.put(MSG_REC);
    w.tlvInt(0x01, seq, 4);
    w.tlvInt(0x02, reqId_, 1);
    w.put(body, bodyLen);
    *outLen = w.len;
    used_ += len;
    count_++;
    scanned_ = seq;
    return PAGE_SEND;
  }

  bool stopped() const { return stopped_; }
  uint8_t count() const { return count_; }

  PageEnd end() const {
    PageEnd e;
    e.reqId = reqId_;
    e.scannedTo = scanned_;
    e.more = scanned_ < durableHigh_ ? 1 : 0;
    e.feedHigh = durableHigh_;
    e.count = count_;
    return e;
  }

  // Encoded size of a page REC (seq, reqId, body; no seenBy on pages).
  static size_t recLen(size_t bodyLen) { return 1 + 6 + 3 + bodyLen; }

 private:
  uint8_t reqId_;
  uint32_t since_;
  uint8_t limit_;
  uint16_t maxBytes_;
  uint32_t durableHigh_;
  bool exclusion_;
  Id8 puller_;
  uint32_t scanned_;
  size_t used_;
  uint8_t count_;
  bool stopped_;
};

}  // namespace mmsync
