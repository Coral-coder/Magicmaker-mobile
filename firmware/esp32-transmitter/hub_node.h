// MagicMaker sync hub, phase P2: HubNode, the hub's sync node (docs/SYNC_P2_FIRMWARE_PLAN.md §5;
// protocol: docs/SYNC_PROTOCOL.md; spec: docs/SYNC_HUB_SPEC.md §3, §4.9-§4.14, §9).
//
// HubNode is to the P1 C++ core what tools/sync/gen_vectors.py `Node` (kind 1) is to sync_ref.py:
// one P1 Session per link slot (through a HubSessionNode adapter), and around it the node-level
// behaviour: page serving, live-record forwarding with seenBy, event / EVT_SINCE / EVT_GAP relay,
// heartbeats (build, round, forwarding, roster), the flush timer, the group fan-out, the slot
// policy, sync_reset and leave-group. It talks to the library only through HubDb and to the radio
// only through Radio (hub_ports.h), so it has no Arduino, FreeRTOS or NimBLE dependency and runs
// unchanged in the host tests (test/host/test_hub_replay.cc replays every golden transcript byte
// for byte with HUB_POLICY_TRANSCRIPT).
//
// Order rules that make the replay exact (plan §5.2):
//   - every Session input runs its actions in order; SEND / node messages are traced at enqueue;
//   - newly armed session timers are scheduled after the action loop, then the deferred group
//     fan-out runs on the other sessions in session-creation order;
//   - "session order" (a counter assigned at SUBSCRIBE) drives every iteration over links.
//
// Timing rules (user rules; plan §0): pages are scanned and frames sent only from service(); while
// a timed job is on air page scans pause and each link sends at most one frame per 40 ms, in class
// priority; flash work is the DB's (HubDb::flush / maintain apply the TxGate); nextDueMs() never
// returns 0 for work that waits for a closed gate.
//
// Pure C++11 (gnu++11, -fno-rtti, no exceptions), no heap: every buffer is a member.
#pragma once

#include "hub_ports.h"
#include "hub_outbox.h"
#include "hub_roster.h"

namespace mmsync {

// Task kinds of HubTask.kind (the Scheduler port).
enum HubTaskKind : uint8_t {
  TK_TIMER = 1,         // a session timer: link = slot, arg = TimerId, gen = link gen
  TK_HB_ROUND = 2,      // the on-change HB round
  TK_FLUSH = 3,         // HUB_FLUSH_DELAY_MS after the first dirty record (gen = flush gen)
  TK_CONN_DEADLINE = 4, // grouped hub: a connection without a session is dropped (link, gen)
  TK_DRAIN = 5,         // a closing link's 1 s drain limit (link, gen)
  TK_TX_RETRY = 6,      // wake to retry a refused / paced frame (link)
  TK_RESET = 7          // sync_reset: close the sessions after HUB_RESET_GRACE_MS
};

static const uint8_t HUB_SLOT_NONE = 0xFF;
static const uint8_t HUB_HCI_REMOTE_USER = 0x13;
static const uint8_t HUB_RX_EVENTS_PER_PASS = 32;
static const uint8_t HUB_HELD_PULL_MAX = 64;
static const uint32_t HUB_RX_OVERFLOW_ERR_MS = 1000;
static const uint32_t HUB_FLUSH_RETRY_MS = 200;    // the DB deferred with the gate open, or failed
static const uint16_t HUB_TXBUF_BYTES = 520;       // >= HUB_MAXMSG: any message the hub builds or relays

// The Session's view of the hub (one per link slot): node-level state is refreshed from HubDb
// before every Session call; the peer table is HubDb's.
class HubSessionNode : public SessionNode {
 public:
  HubSessionNode() : db(NULL), clock(NULL), rng(NULL), session(NULL), conn(HUB_CONN_NONE) {}

  HubDb* db;
  Clock* clock;
  Rng* rng;
  const Session* session;
  uint16_t conn;

  int64_t clockMs(uint32_t t) override {
    int64_t ms = 0;
    return (clock && clock->wallMs(t, &ms) && ms > 0) ? ms : 0;
  }
  void nextNonce(uint8_t out[8]) override {
    if (rng) {
      rng->nonce(conn, out);
    } else {
      memset(out, 0, 8);
    }
  }
  PeerState* findPeer(const Id8& id) override { return db->peerFind(id); }
  PeerState* peer(const Id8& id) override {
    const uint8_t kind = (session && session->hasPeer()) ? session->peerHello().kind : 0;
    return db->peerGet(id, kind);
  }
};

// One connection slot.
struct HubLink {
  bool used;
  uint16_t conn;
  uint32_t gen;          // new per CONNECT and per SUBSCRIBE / unsubscribe (task check value)
  uint16_t mtu;
  bool subscribed;       // has a session (SYNC notifications on)
  bool everSubscribed;
  uint32_t order;        // session creation order (SUBSCRIBE)
  uint32_t connectAt;
  uint8_t lastState;     // SessionState after the last input (edges)

  Session session;
  HubSessionNode adapter;
  Reassembler<HUB_MAXMSG> reasm;
  Outbox outbox;

  // page serving
  bool pageActive;
  PageServer page;
  FeedCursor cursor;
  uint32_t pageSince;
  uint32_t pageLimit;

  // the hub's own PULL, held while the DB cannot take a page
  uint8_t heldLen;
  uint8_t held[HUB_HELD_PULL_MAX];

  // session timers handed to the scheduler: the last due registered per TimerId
  bool timerReg[TM_COUNT];
  uint32_t timerDue[TM_COUNT];

  // closing (PRODUCTION: ERR first, then the disconnect)
  bool closing;
  bool discSent;
  uint8_t closeReason;

  // TX
  bool txBlocked;
  uint32_t txBlockedUntil;
  bool sentAny;
  uint32_t lastFrameMs;
  uint32_t framesSent;

  // EVT pacing
  uint32_t evtWindowStart;
  uint8_t evtInWindow;

  // counters
  uint32_t badFrames;
  uint32_t rxMsgs;
  uint32_t rxNoSession;
  uint32_t rxOverflows;
  bool overflowErrSent;
  uint32_t lastOverflowErrMs;
  uint32_t errsIn;
  uint8_t lastErrIn;
  uint32_t pagesServed;
  uint32_t recsIn;
  uint32_t evtDropped;
};

class HubNode : public HubSync {
 public:
  HubNode()
      : begun_(false), db_(NULL), radio_(NULL), gate_(NULL), clock_(NULL), rng_(NULL),
        self_(NULL), sched_(NULL), trace_(NULL) {
    memset(&cfg_, 0, sizeof(cfg_));
    memset(&scfg_, 0, sizeof(scfg_));
    resetCounters();
    for (uint8_t i = 0; i < HUB_MAX_LINKS; i++) clearLink(i);
  }

  // ---- HubSync ----------------------------------------------------------------------------------
  void begin(const HubConfig& cfg, const HubPorts& ports, uint32_t now) override {
    cfg_ = cfg;
    db_ = ports.db;
    radio_ = ports.radio;
    gate_ = ports.gate;
    clock_ = ports.clock;
    rng_ = ports.rng;
    self_ = ports.self;
    sched_ = ports.sched;
    trace_ = ports.trace;
    scfg_.role = ROLE_PERIPHERAL;
    scfg_.deviceId = cfg.deviceId;
    scfg_.kind = KIND_HUB;
    scfg_.bootId = cfg.bootId;
    scfg_.maxMsg = HUB_MAXMSG;
    scfg_.caps = CAPS_HUB;
    scfg_.version = cfg.version;
    scfg_.name = cfg.name;
    scfg_.peerKind = 0;
    scfg_.tracksEvents = false;
    scfg_.isHub = true;
    resetCounters();
    for (uint8_t i = 0; i < HUB_MAX_LINKS; i++) {
      clearLink(i);
      HubLink& L = links_[i];
      L.adapter.db = db_;
      L.adapter.clock = clock_;
      L.adapter.rng = rng_;
      L.adapter.session = &L.session;
      L.session.attach(&scfg_, &L.adapter);
    }
    tracedDurable_ = db_->durableHigh();
    lastFull_ = db_->full();
    lastReady_ = db_->ready();
    lastSkew_ = clock_->skewed();
    now_ = now;
    begun_ = true;
  }

  void service(uint32_t now) override {
    if (!begun_) return;
    now_ = now;
    // 1. due tasks (TaskTable; an event-queue scheduler runs them itself and returns none)
    HubTask t;
    for (uint8_t guard = 0; guard < 64 && sched_->popDue(now, &t); guard++) runTaskAt(t, now);
    // 2. radio events, in order, within the budgets
    radioBudgetHit_ = false;
    uint8_t msgs = 0, evs = 0;
    HubRadioEvent ev;
    for (;;) {
      if (msgs >= HUB_MSGS_PER_PASS || evs >= HUB_RX_EVENTS_PER_PASS) {
        radioBudgetHit_ = true;
        break;
      }
      if (!radio_->take(&ev)) break;
      evs++;
      msgs = (uint8_t)(msgs + onRadioEvent(ev, now));
    }
    // 3. hubFull / repull cleared: zero every wm and pull from every member (spec §4.8)
    if (db_->ready() && db_->takeRepullNeeded()) repullAll(now);
    // 4. held PULLs
    releaseHeldPulls(now);
    // 5. one page-scan step per link
    uint8_t ord[HUB_MAX_LINKS];
    const uint8_t n = sessionOrder(ord, false);
    for (uint8_t i = 0; i < n; i++) pageStep(ord[i], now);
    // 6. frames
    for (uint8_t i = 0; i < n; i++) sendFrames(ord[i], now);
    // 7. a deferred flush once its gate opens; PRODUCTION: the 2 KB size trigger
    wantedFlush(now);
    // 8. one DB maintenance step (its own gates)
    db_->maintain(now);
    // 9. closing links whose ERR went out
    for (uint8_t s = 0; s < HUB_MAX_LINKS; s++) {
      HubLink& L = links_[s];
      if (L.used && L.closing && !L.discSent && L.outbox.empty()) closeNow(s);
    }
    // 10. on-change HB triggers (PRODUCTION)
    if (cfg_.policy == HUB_POLICY_PRODUCTION) watchEdges(now);
  }

  // Called by an event-queue Scheduler at task.due (the transcript replay), or by service().
  void runTask(const HubTask& task) override { runTaskAt(task, task.due); }

  uint32_t nextDueMs(uint32_t now) override {
    if (!begun_) return HUB_NO_DEADLINE;
    if (radioBudgetHit_) return 0;
    const bool light = hubLightWorkAllowed(*gate_);
    const bool ota = gate_->otaBusy();
    const bool timed = gate_->timedJob();
    for (uint8_t s = 0; s < HUB_MAX_LINKS; s++) {
      const HubLink& L = links_[s];
      if (!L.used) continue;
      if (L.closing && !L.discSent && L.outbox.empty()) return 0;
      if (!L.subscribed) continue;
      if (L.outbox.hasFrame() && (!L.discSent || cfg_.policy == HUB_POLICY_TRANSCRIPT)) {
        const bool blocked = L.txBlocked && (int32_t)(now - L.txBlockedUntil) < 0;
        const bool paced = timed && L.sentAny && (now - L.lastFrameMs) < HUB_TIMED_FRAME_GAP_MS;
        if (!blocked && !paced) return 0;
      }
      if (L.pageActive && light && !ota && L.outbox.hasRoomFor(OC_PAGE, HUB_PAGE_REC_ROOM)) return 0;
      if (L.heldLen && !ota && db_->canTakePage(heldMaxBytes(L), now)) return 0;
    }
    if (wantedFlushDue(now)) return 0;
    if (db_->maintenanceDue(now)) return 0;
    return sched_->nextDueMs(now);
  }

  void selfChanged(uint32_t now) override {
    if (cfg_.policy == HUB_POLICY_PRODUCTION) requestHb(now);
  }

  bool isMember(uint16_t conn) const override {
    const uint8_t s = slotOf(conn);
    return s != HUB_SLOT_NONE && links_[s].subscribed && links_[s].session.authed();
  }

  bool syncReset(uint16_t conn, uint32_t now) override {
    if (!begun_ || !isMember(conn)) return false;
    uint8_t b[8];
    for (uint8_t tries = 0; tries < 16; tries++) {
      rng_->random(b, 8);
      if (!isZero(makeId8(b))) break;
    }
    if (isZero(makeId8(b))) b[0] = 1;
    db_->requestReset(makeId8(b), now);
    tracedDurable_ = 0;
    pageAccepted_ = false;
    uint8_t ord[HUB_MAX_LINKS];
    const uint8_t n = sessionOrder(ord, false);
    for (uint8_t i = 0; i < n; i++) {
      HubLink& L = links_[ord[i]];
      L.pageActive = false;
      L.heldLen = 0;
      traceDisconnect(L.conn, HUB_DISC_DB_RESET, false, 0);
      if (cfg_.policy == HUB_POLICY_TRANSCRIPT) {
        closeNow(ord[i]);
      } else {
        L.closeReason = HUB_DISC_DB_RESET;
      }
    }
    if (cfg_.policy != HUB_POLICY_TRANSCRIPT) {
      resetPending_ = true;
      schedule(now + HUB_RESET_GRACE_MS, ++resetGen_, TK_RESET, HUB_SLOT_NONE, 0);
    }
    resets_++;
    return true;
  }

  void leaveGroup(uint32_t now) override {
    if (!begun_) return;
    GroupState g;
    memset(&g, 0, sizeof(g));
    db_->setGroup(g, now);
    uint8_t ord[HUB_MAX_LINKS];
    const uint8_t n = sessionOrder(ord, false);
    for (uint8_t i = 0; i < n; i++) {
      refresh(ord[i]);
      processActions(ord[i], links_[ord[i]].session.groupChanged(now), NULL, 0, now);
    }
  }

  void flushNow(uint32_t now) override {
    if (!begun_) return;
    const uint8_t r = db_->flush(now, true);
    if (r == DB_FLUSH_DONE || r == DB_FLUSH_NONE) afterFlush(now);
  }

  void counts(HubCounts* out) const override {
    memset(out, 0, sizeof(*out));
    for (uint8_t s = 0; s < HUB_MAX_LINKS; s++) {
      const HubLink& L = links_[s];
      if (!L.used) continue;
      out->conns++;
      if (L.subscribed) out->subscribed++;
      if (L.subscribed && L.session.authed()) out->members++;
    }
    out->pending = (uint8_t)(out->conns - out->members);
  }

  void status(HubStatus* out, uint32_t now) override {
    memset(out, 0, sizeof(*out));
    if (!begun_) return;
    DbStats st;
    db_->stats(&st);
    out->dbState = db_->state();
    out->ready = db_->ready();
    out->full = db_->full();
    const GroupState& g = db_->group();
    out->grouped = g.grouped;
    out->groupId = g.grouped ? g.id : zeroId8();
    out->dbId = db_->dbId();
    out->records = st.records;
    out->cap = st.cap;
    out->tombstones = st.tombstones;
    out->liveKB = (st.liveBytes + 1023) / 1024;
    out->liveMaxKB = st.liveMaxBytes / 1024;
    out->logKB = (st.logBytes + 1023) / 1024;
    out->fsUsedKB = (st.fsUsedBytes + 1023) / 1024;
    out->fsTotalKB = st.fsTotalBytes / 1024;
    out->lastSeq = db_->lastSeq();
    out->durableHigh = db_->durableHigh();
    counts(&out->counts);
    int64_t wall = 0;
    out->clockKnown = clock_->wallMs(now, &wall);
    out->clockSkew = clock_->skewed();
    out->rxOverflows = 0;
    out->badFrames = badFramesClosed_;
    out->liveDropped = liveDroppedClosed_ + liveSkipped_;
    uint8_t ord[HUB_MAX_LINKS];
    const uint8_t n = sessionOrder(ord, false);
    // rows: members first (session order), then other linked peers, then devices known from HBs
    for (uint8_t pass = 0; pass < 2; pass++) {
      for (uint8_t i = 0; i < n; i++) {
        const HubLink& L = links_[ord[i]];
        const bool member = L.session.authed();
        if (pass == 0) {
          out->badFrames += L.badFrames;
          out->rxOverflows += L.rxOverflows;
          out->liveDropped += L.outbox.droppedLive() + L.outbox.droppedEvt() + L.evtDropped;
          if (member && L.mtu < SMALL_MTU_BELOW) out->mtu23 = true;
          if (member && out->nMemberConns < HUB_MAX_LINKS) out->memberConns[out->nMemberConns++] = L.conn;
        }
        if (member != (pass == 0)) continue;
        if (!L.session.hasPeer() || out->nPhones >= HUB_ROSTER_MAX) continue;
        HubPhoneRow& r = out->phones[out->nPhones++];
        fillRow(&r, L.session.peerId(), now);
        r.kind = L.session.peerHello().kind;
        r.state = phoneState(L.session.state());
        r.conn = L.conn;
        r.mtu = L.mtu;
        const PeerState* ps = db_->peerFind(L.session.peerId());
        r.wm = ps ? ps->wm : 0;
      }
    }
    for (uint8_t i = 0; out->nPhones < HUB_ROSTER_MAX; i++) {
      const RosterEntry* e = roster_.byRecency(i);
      if (!e) break;
      bool linked = false;
      for (uint8_t k = 0; k < out->nPhones; k++)
        if (out->phones[k].id == e->id) linked = true;
      if (linked) continue;
      HubPhoneRow& r = out->phones[out->nPhones++];
      fillRow(&r, e->id, now);
      r.kind = e->kind;
      r.state = HUB_PH_OFFLINE;
      r.conn = HUB_CONN_NONE;
      r.mtu = 0;
      const PeerState* ps = db_->peerFind(e->id);
      r.wm = ps ? ps->wm : 0;
    }
  }

  // ---- observation (tests, the sketch's diagnostics) ---------------------------------------------
  const HubLink* linkAt(uint8_t slot) const { return slot < HUB_MAX_LINKS ? &links_[slot] : NULL; }
  const HubLink* linkByConn(uint16_t conn) const {
    const uint8_t s = slotOf(conn);
    return s == HUB_SLOT_NONE ? NULL : &links_[s];
  }
  const Roster& roster() const { return roster_; }
  uint32_t hbSeq() const { return hbSeq_; }
  bool flushPending() const { return flushPending_; }
  bool hbRoundPending() const { return hbRoundPending_; }
  uint32_t liveSkipped() const { return liveSkipped_; }
  uint32_t rxNoLink() const { return rxNoLink_; }
  uint32_t resets() const { return resets_; }

 private:
  // ---- setup ------------------------------------------------------------------------------------
  void resetCounters() {
    now_ = 0;
    genCounter_ = 0;
    orderCounter_ = 0;
    hbSeq_ = 0;
    hbEver_ = false;
    lastHbT_ = 0;
    hbRoundPending_ = false;
    flushPending_ = false;
    flushGen_ = 0;
    flushWanted_ = false;
    dirtySinceSet_ = false;
    dirtySince_ = 0;
    pageAccepted_ = false;
    tracedDurable_ = 0;
    radioBudgetHit_ = false;
    resetPending_ = false;
    resetGen_ = 0;
    lastFull_ = false;
    lastReady_ = false;
    lastSkew_ = false;
    liveSkipped_ = 0;
    rxNoLink_ = 0;
    resets_ = 0;
    badFramesClosed_ = 0;
    liveDroppedClosed_ = 0;
  }

  void clearLink(uint8_t s) {
    HubLink& L = links_[s];
    L.used = false;
    L.conn = HUB_CONN_NONE;
    L.gen = 0;
    L.mtu = MTU_MIN;
    L.subscribed = false;
    L.everSubscribed = false;
    L.order = 0;
    L.connectAt = 0;
    L.lastState = ST_IDLE;
    L.reasm.reset(HUB_MAXMSG);
    L.outbox.reset();
    L.pageActive = false;
    memset(&L.cursor, 0, sizeof(L.cursor));
    L.pageSince = 0;
    L.pageLimit = 0;
    L.heldLen = 0;
    for (uint8_t i = 0; i < TM_COUNT; i++) {
      L.timerReg[i] = false;
      L.timerDue[i] = 0;
    }
    L.closing = false;
    L.discSent = false;
    L.closeReason = 0;
    L.txBlocked = false;
    L.txBlockedUntil = 0;
    L.sentAny = false;
    L.lastFrameMs = 0;
    L.framesSent = 0;
    L.evtWindowStart = 0;
    L.evtInWindow = 0;
    L.badFrames = 0;
    L.rxMsgs = 0;
    L.rxNoSession = 0;
    L.rxOverflows = 0;
    L.overflowErrSent = false;
    L.lastOverflowErrMs = 0;
    L.errsIn = 0;
    L.lastErrIn = 0;
    L.pagesServed = 0;
    L.recsIn = 0;
    L.evtDropped = 0;
    L.adapter.conn = HUB_CONN_NONE;
  }

  // ---- helpers ------------------------------------------------------------------------------------
  uint8_t slotOf(uint16_t conn) const {
    if (conn == HUB_CONN_NONE) return HUB_SLOT_NONE;
    for (uint8_t s = 0; s < HUB_MAX_LINKS; s++)
      if (links_[s].used && links_[s].conn == conn) return s;
    return HUB_SLOT_NONE;
  }

  // Links with a session (membersOnly: AUTHED+), in session-creation order.
  uint8_t sessionOrder(uint8_t* out, bool membersOnly) const {
    uint8_t n = 0;
    for (uint8_t s = 0; s < HUB_MAX_LINKS; s++) {
      const HubLink& L = links_[s];
      if (!L.used || !L.subscribed) continue;
      if (membersOnly && !L.session.authed()) continue;
      out[n++] = s;
    }
    for (uint8_t a = 1; a < n; a++) {
      const uint8_t x = out[a];
      int b = a - 1;
      while (b >= 0 && (int32_t)(links_[out[b]].order - links_[x].order) > 0) {
        out[b + 1] = out[b];
        b--;
      }
      out[b + 1] = x;
    }
    return n;
  }

  // Members as routing sees them: sub = the peer subscribed to `bit`.
  uint8_t routeSessions(uint8_t bit, RouteSession* rs, uint8_t* slots) const {
    uint8_t ord[HUB_MAX_LINKS];
    const uint8_t n = sessionOrder(ord, true);
    for (uint8_t i = 0; i < n; i++) {
      const HubLink& L = links_[ord[i]];
      rs[i].peer = L.session.peerId();
      rs[i].sub = (L.session.peerSubs() & bit) != 0;
      rs[i].ok = true;
      slots[i] = ord[i];
    }
    return n;
  }

  // The first member link whose peer is id (gen_vectors lid_for).
  uint8_t memberFor(const Id8& id) const {
    uint8_t ord[HUB_MAX_LINKS];
    const uint8_t n = sessionOrder(ord, true);
    for (uint8_t i = 0; i < n; i++)
      if (links_[ord[i]].session.peerId() == id) return ord[i];
    return HUB_SLOT_NONE;
  }

  void refresh(uint8_t s) {
    HubLink& L = links_[s];
    HubSessionNode& a = L.adapter;
    a.group = db_->group();
    a.dbId = db_->dbId();
    a.feedHigh = db_->durableHigh();
    a.ready = db_->ready();
    a.conn = L.conn;
  }

  void schedule(uint32_t due, uint32_t gen, uint8_t kind, uint8_t link, uint8_t arg) {
    HubTask t;
    memset(&t, 0, sizeof(t));
    t.due = due;
    t.gen = gen;
    t.kind = kind;
    t.link = link;
    t.arg = arg;
    if (!sched_->at(t)) runTaskAt(t, now_);  // no room: the work is due now (Scheduler contract)
  }

  void traceState(uint16_t conn, uint8_t st) {
    if (trace_) trace_->state(conn, st);
  }
  void traceDisconnect(uint16_t conn, uint8_t reason, bool hasRetry, uint32_t retryMs) {
    if (trace_) trace_->disconnect(conn, reason, hasRetry, retryMs);
  }

  bool enqueue(uint8_t s, uint8_t cls, const uint8_t* msg, size_t len) {
    HubLink& L = links_[s];
    if (!L.used || !L.subscribed || len == 0 || len > 0xFFFF) return false;
    if (L.discSent && cfg_.policy != HUB_POLICY_TRANSCRIPT) return false;
    if (!L.outbox.push(cls, msg, (uint16_t)len)) return false;
    if (trace_) trace_->sent(L.conn, msg, len);
    return true;
  }

  // ERR is never answered with an ERR and a FOREIGN session sends nothing more (SYNC_PROTOCOL §12).
  void sendErr(uint8_t s, uint8_t code, bool hasRef, uint8_t ref, const Key* key, bool hasRetry,
               uint16_t retryMs) {
    HubLink& L = links_[s];
    if (!L.subscribed) return;
    const uint8_t st = L.session.state();
    if (st == ST_FOREIGN || st == ST_CLOSED || st == ST_IDLE) return;
    Err e;
    memset(&e, 0, sizeof(e));
    e.code = code;
    e.hasRefType = hasRef;
    e.refType = ref;
    if (key) {
      e.hasKey = true;
      e.key = *key;
    }
    e.hasRetryMs = hasRetry;
    e.retryMs = retryMs;
    const size_t n = encode(e, txBuf_, sizeof(txBuf_));
    enqueue(s, OC_ERR, txBuf_, n);
  }

  static uint8_t phoneState(uint8_t st) {
    switch (st) {
      case ST_LINKED: return HUB_PH_LINKED;
      case ST_HELLO_X:
      case ST_AUTHED: return HUB_PH_AUTH;
      case ST_SYNCING: return HUB_PH_SYNCING;
      case ST_SYNCED: return HUB_PH_SYNCED;
      case ST_FOREIGN: return HUB_PH_FOREIGN;
      case ST_NOGROUP: return HUB_PH_NOGROUP;
      case ST_INCOMPATIBLE: return HUB_PH_INCOMPATIBLE;
      default: return HUB_PH_LINKED;
    }
  }

  void fillRow(HubPhoneRow* r, const Id8& id, uint32_t now) const {
    r->id = id;
    r->agoS = 0xFFFFFFFFu;
    r->battPct = -1;
    r->charging = -1;
    r->runtimeMin = -1;
    r->path = HUB_PATH_NONE;
    r->viaKind = 0;
    const RosterEntry* e = roster_.find(id);
    if (!e) return;
    r->agoS = roster_.ageS(*e, now);
    r->battPct = e->battPct;
    r->charging = e->charging;
    r->runtimeMin = e->runtimeMin;
    r->path = roster_.path(*e, now);
    r->viaKind = e->viaKind;
  }

  // ---- tasks --------------------------------------------------------------------------------------
  void runTaskAt(const HubTask& task, uint32_t now) {
    now_ = now;
    switch (task.kind) {
      case TK_TIMER: {
        if (task.link >= HUB_MAX_LINKS || task.arg >= TM_COUNT) return;
        HubLink& L = links_[task.link];
        if (!L.used || !L.subscribed || L.gen != task.gen) return;
        const TimerId id = (TimerId)task.arg;
        if (!L.session.timerArmed(id) || L.session.timerDue(id) != task.due) return;
        if (trace_) trace_->timer(L.conn, task.arg);
        refresh(task.link);
        processActions(task.link, L.session.timer(task.due, id), NULL, 0, now);
        return;
      }
      case TK_HB_ROUND: {
        hbRoundPending_ = false;
        uint8_t ord[HUB_MAX_LINKS], sel[HUB_MAX_LINKS];
        const uint8_t n = sessionOrder(ord, true);
        uint8_t k = 0;
        for (uint8_t i = 0; i < n; i++)
          if (links_[ord[i]].session.peerSubs() & SUB_HEARTBEATS) sel[k++] = ord[i];
        if (k) sendHb(sel, k, now);
        return;
      }
      case TK_FLUSH:
        if (task.gen != flushGen_ || !flushPending_) return;
        flushPending_ = false;
        doFlush(now);
        return;
      case TK_CONN_DEADLINE: {
        if (task.link >= HUB_MAX_LINKS) return;
        HubLink& L = links_[task.link];
        if (!L.used || L.gen != task.gen || L.subscribed || L.discSent) return;
        if (!db_->group().grouped) return;
        traceDisconnect(L.conn, L.everSubscribed ? HUB_DISC_UNSUBSCRIBED : HUB_DISC_DEADLINE, false, 0);
        closeNow(task.link);
        return;
      }
      case TK_DRAIN: {
        if (task.link >= HUB_MAX_LINKS) return;
        HubLink& L = links_[task.link];
        if (!L.used || L.gen != task.gen || !L.closing || L.discSent) return;
        closeNow(task.link);
        return;
      }
      case TK_TX_RETRY:
        return;  // a wake-up: service() retries the frames
      case TK_RESET: {
        if (!resetPending_ || task.gen != resetGen_) return;
        resetPending_ = false;
        for (uint8_t s = 0; s < HUB_MAX_LINKS; s++)
          if (links_[s].used && links_[s].subscribed && !links_[s].discSent) closeNow(s);
        return;
      }
      default:
        return;
    }
  }

  void closeNow(uint8_t s) {
    HubLink& L = links_[s];
    if (!L.used || L.discSent) return;
    L.discSent = true;
    L.closing = true;
    radio_->disconnect(L.conn, HUB_HCI_REMOTE_USER);
  }

  // ---- radio events ---------------------------------------------------------------------------------
  // Returns the number of messages delivered (0 or 1).
  uint8_t onRadioEvent(const HubRadioEvent& ev, uint32_t now) {
    switch (ev.kind) {
      case HUB_EV_CONNECT:
        onConnect(ev.conn, ev.value, now);
        return 0;
      case HUB_EV_DISCONNECT:
        onDisconnect(ev.conn, now);
        return 0;
      case HUB_EV_SUBSCRIBE:
        onSubscribe(ev.conn, ev.value != 0, now);
        return 0;
      case HUB_EV_MTU: {
        const uint8_t s = slotOf(ev.conn);
        if (s != HUB_SLOT_NONE) links_[s].mtu = clampMtu(ev.value);
        return 0;
      }
      case HUB_EV_FRAME:
        return onFrame(ev.conn, ev.data, ev.len, now);
      case HUB_EV_TX_DONE:
        for (uint8_t s = 0; s < HUB_MAX_LINKS; s++)
          if (links_[s].used && (ev.conn == HUB_CONN_NONE || links_[s].conn == ev.conn))
            links_[s].txBlocked = false;
        return 0;
      case HUB_EV_RX_OVERFLOW: {
        const uint8_t s = slotOf(ev.conn);
        if (s == HUB_SLOT_NONE) return 0;
        HubLink& L = links_[s];
        L.rxOverflows++;
        if (L.subscribed && L.session.authed() &&
            (!L.overflowErrSent || now - L.lastOverflowErrMs >= HUB_RX_OVERFLOW_ERR_MS)) {
          L.overflowErrSent = true;
          L.lastOverflowErrMs = now;
          sendErr(s, E_BUSY, false, 0, NULL, true, BUSY_RETRY_MS);
        }
        return 0;
      }
      default:
        return 0;
    }
  }

  static uint16_t clampMtu(uint16_t mtu) {
    if (mtu < MTU_MIN) return MTU_MIN;
    if (mtu > MTU_MAX) return MTU_MAX;
    return mtu;
  }

  bool isMemberSlot(uint8_t s) const { return links_[s].subscribed && links_[s].session.authed(); }

  void onConnect(uint16_t conn, uint16_t mtu, uint32_t now) {
    const uint8_t old = slotOf(conn);
    if (old != HUB_SLOT_NONE) onDisconnect(conn, now);  // a missed DISCONNECT: the handle is reused
    uint8_t s = HUB_SLOT_NONE;
    for (uint8_t i = 0; i < HUB_MAX_LINKS; i++) {
      if (!links_[i].used) {
        s = i;
        break;
      }
    }
    if (s == HUB_SLOT_NONE) {  // more connections than slots (NimBLE allows 3): refuse
      traceDisconnect(conn, HUB_DISC_SLOTS, false, 0);
      radio_->disconnect(conn, HUB_HCI_REMOTE_USER);
      return;
    }
    clearLink(s);
    HubLink& L = links_[s];
    L.used = true;
    L.conn = conn;
    L.gen = ++genCounter_;
    L.mtu = clampMtu(mtu);
    L.connectAt = now;
    L.adapter.conn = conn;
    // slot policy (spec §4.9): beyond two phones, drop the newest non-member at once
    uint8_t conns = 0;
    for (uint8_t i = 0; i < HUB_MAX_LINKS; i++)
      if (links_[i].used && !links_[i].discSent) conns++;
    if (conns > HUB_MAX_MEMBERS) {
      uint8_t victim = HUB_SLOT_NONE;
      for (uint8_t i = 0; i < HUB_MAX_LINKS; i++) {
        const HubLink& c = links_[i];
        if (!c.used || c.discSent || isMemberSlot(i)) continue;
        if (victim == HUB_SLOT_NONE || (int32_t)(c.gen - links_[victim].gen) > 0) victim = i;
      }
      if (victim != HUB_SLOT_NONE) {
        traceDisconnect(links_[victim].conn, HUB_DISC_SLOTS, false, 0);
        closeNow(victim);
      }
    }
    if (db_->group().grouped && !L.discSent)
      schedule(now + T_DEADLINE_MS, L.gen, TK_CONN_DEADLINE, s, 0);
  }

  void onDisconnect(uint16_t conn, uint32_t now) {
    const uint8_t s = slotOf(conn);
    if (s == HUB_SLOT_NONE) return;
    HubLink& L = links_[s];
    if (L.subscribed) endSession(s, now);
    badFramesClosed_ += L.badFrames;
    liveDroppedClosed_ += L.outbox.droppedLive() + L.outbox.droppedEvt() + L.evtDropped;
    clearLink(s);
  }

  void endSession(uint8_t s, uint32_t now) {
    HubLink& L = links_[s];
    const bool hadPeer = L.session.hasPeer();
    const Id8 peer = L.session.peerId();
    refresh(s);
    processActions(s, L.session.linkDown(now), NULL, 0, now);
    if (hadPeer) db_->peerSessionEnd(peer, now);
    L.subscribed = false;
    L.pageActive = false;
    L.heldLen = 0;
    L.lastState = ST_CLOSED;
  }

  void onSubscribe(uint16_t conn, bool on, uint32_t now) {
    const uint8_t s = slotOf(conn);
    if (s == HUB_SLOT_NONE) return;
    HubLink& L = links_[s];
    if (!on) {
      if (!L.subscribed) return;
      endSession(s, now);
      L.outbox.reset();
      L.gen = ++genCounter_;
      if (db_->group().grouped && !L.discSent)
        schedule(now + T_DEADLINE_MS, L.gen, TK_CONN_DEADLINE, s, 0);
      return;
    }
    if (db_->state() == DB_FAILED) return;  // no sessions without storage (transmit unaffected)
    if (L.subscribed) endSession(s, now);
    L.subscribed = true;
    L.everSubscribed = true;
    L.gen = ++genCounter_;
    L.order = ++orderCounter_;
    L.reasm.reset(HUB_MAXMSG);
    L.outbox.reset();
    L.pageActive = false;
    L.heldLen = 0;
    L.closing = false;
    L.txBlocked = false;
    L.sentAny = false;
    for (uint8_t i = 0; i < TM_COUNT; i++) {
      L.timerReg[i] = false;
      L.timerDue[i] = 0;
    }
    L.lastState = ST_IDLE;
    refresh(s);
    processActions(s, L.session.linkUp(now, L.mtu), NULL, 0, now);
  }

  uint8_t onFrame(uint16_t conn, const uint8_t* data, uint16_t len, uint32_t now) {
    const uint8_t s = slotOf(conn);
    if (s == HUB_SLOT_NONE) {
      rxNoLink_++;
      return 0;
    }
    HubLink& L = links_[s];
    if (!L.subscribed || data == NULL) {
      L.rxNoSession++;
      return 0;
    }
    const ReasmResult r = L.reasm.feed(data, len);
    uint8_t delivered = 0;
    for (uint8_t i = 0; i < r.n; i++) {
      switch (r.ev[i].kind) {
        case RA_DELIVER:
          L.rxMsgs++;
          delivered = 1;
          refresh(s);
          processActions(s, L.session.rx(now, r.msg, r.msgLen), r.msg, r.msgLen, now);
          break;
        case RA_BAD_FRAME:
          L.badFrames++;
          break;
        case RA_ERR_TOO_BIG:
          L.badFrames++;
          if (r.ev[i].value != MSG_ERR) sendErr(s, E_TOO_BIG, true, r.ev[i].value, NULL, false, 0);
          break;
        case RA_ERR_PROTO:
          sendErr(s, E_PROTO, false, 0, NULL, false, 0);
          break;
        default:
          break;
      }
      if (!links_[s].used || !links_[s].subscribed) break;
    }
    return delivered;
  }

  // ---- the action loop ----------------------------------------------------------------------------
  void processActions(uint8_t s, const ActionList& acts, const uint8_t* raw, size_t rawLen,
                      uint32_t now) {
    HubLink& L = links_[s];
    bool fan = false, fanRekey = false;
    for (size_t i = 0; i < acts.size(); i++) {
      const Action& a = acts[i];
      switch (a.kind) {
        case ACT_SEND:
          onSend(s, a.msgType, acts.bytes(a), a.len, now);
          break;
        case ACT_STATE:
          onState(s, a.state, now);
          break;
        case ACT_DELIVER:
          onDeliver(s, a.msgType, raw, rawLen, now);
          break;
        case ACT_COMMIT:
          onCommit(s, now);
          break;
        case ACT_GROUP: {
          const uint8_t* b = acts.bytes(a);
          GroupState g;
          g.grouped = true;
          g.id = makeId8(b);
          memcpy(g.key, b + 8, 16);
          db_->setGroup(g, now);
          if (trace_) trace_->group(L.conn, g.id, a.rekey);
          fan = true;
          fanRekey = a.rekey;
          break;
        }
        case ACT_NODE:
          if (a.what == NODE_SEND_HB) {
            sendHb(&s, 1, now);
          } else if (a.what == NODE_FOREIGN) {
            if (trace_) trace_->foreign(L.conn);
          }
          break;
        case ACT_DISCONNECT:
          traceDisconnect(L.conn, a.reason, a.hasRetry, a.value);
          if (cfg_.policy == HUB_POLICY_TRANSCRIPT) {
            closeNow(s);
          } else if (!L.closing) {
            L.closing = true;
            L.closeReason = a.reason;
            schedule(now + HUB_DRAIN_BEFORE_DISCONNECT_MS, L.gen, TK_DRAIN, s, 0);
          }
          break;
        default:
          break;
      }
    }
    if (L.used && L.subscribed) registerTimers(s);
    if (fan) fanOut(s, fanRekey, now);
  }

  void registerTimers(uint8_t s) {
    HubLink& L = links_[s];
    for (uint8_t id = 0; id < TM_COUNT; id++) {
      if (!L.session.timerArmed((TimerId)id)) continue;
      const uint32_t due = L.session.timerDue((TimerId)id);
      if (L.timerReg[id] && L.timerDue[id] == due) continue;
      L.timerReg[id] = true;
      L.timerDue[id] = due;
      schedule(due, L.gen, TK_TIMER, s, id);
    }
  }

  // The group changed on link s: every other session restarts (rekey) or re-evaluates.
  void fanOut(uint8_t s, bool rekey, uint32_t now) {
    uint8_t ord[HUB_MAX_LINKS];
    const uint8_t n = sessionOrder(ord, false);
    for (uint8_t i = 0; i < n; i++) {
      const uint8_t o = ord[i];
      if (o == s || !links_[o].subscribed) continue;
      refresh(o);
      Session& ses = links_[o].session;
      processActions(o, (rekey && ses.authed()) ? ses.rekey(now) : ses.groupChanged(now), NULL, 0, now);
    }
    if (!db_->group().grouped) return;
    for (uint8_t o = 0; o < HUB_MAX_LINKS; o++) {  // links without a session now have 10 s
      HubLink& c = links_[o];
      if (c.used && !c.subscribed && !c.discSent) schedule(now + T_DEADLINE_MS, c.gen, TK_CONN_DEADLINE, o, 0);
    }
  }

  void onSend(uint8_t s, uint8_t type, const uint8_t* bytes, size_t len, uint32_t now) {
    HubLink& L = links_[s];
    if (type == MSG_PULL) {
      // hub backpressure (spec §3.7): the hub's PULL waits until a page fits
      if (gate_->otaBusy() || !db_->canTakePage(pullMaxBytes(bytes, len), now)) {
        if (len <= HUB_HELD_PULL_MAX) {
          memcpy(L.held, bytes, len);
          L.heldLen = (uint8_t)len;
        }
        return;
      }
      L.heldLen = 0;
    }
    enqueue(s, outClassOf(type, false), bytes, len);
  }

  static uint16_t pullMaxBytes(const uint8_t* m, size_t n) {
    if (n < 1 || !tlvFramingOk(m, n, 1)) return PULL_MAXBYTES_DEFAULT;
    for (size_t i = 1; i < n;) {
      const uint8_t tag = m[i], ln = m[i + 1];
      if (tag == 0x04 && ln == 2) return (uint16_t)(m[i + 2] | (m[i + 3] << 8));
      i += 2 + (size_t)ln;
    }
    return PULL_MAXBYTES_DEFAULT;
  }

  uint16_t heldMaxBytes(const HubLink& L) const { return pullMaxBytes(L.held, L.heldLen); }

  void releaseHeldPulls(uint32_t now) {
    if (gate_->otaBusy()) return;
    for (uint8_t s = 0; s < HUB_MAX_LINKS; s++) {
      HubLink& L = links_[s];
      if (!L.used || !L.subscribed || !L.heldLen) continue;
      if (!db_->canTakePage(heldMaxBytes(L), now)) continue;
      const uint8_t n = L.heldLen;
      L.heldLen = 0;
      enqueue(s, OC_CONTROL, L.held, n);
    }
  }

  void onState(uint8_t s, uint8_t st, uint32_t now) {
    HubLink& L = links_[s];
    traceState(L.conn, st);
    const bool wasMember = L.lastState == ST_AUTHED || L.lastState == ST_SYNCING || L.lastState == ST_SYNCED;
    const bool isMem = st == ST_AUTHED || st == ST_SYNCING || st == ST_SYNCED;
    const bool syncedEdge = (st == ST_SYNCED) != (L.lastState == ST_SYNCED);
    L.lastState = st;
    if (st == ST_AUTHED) {
      const Hello& h = L.session.peerHello();
      if (h.clockMs > 0) clock_->observe(h.deviceId, h.clockMs, now);
      dropStale(s);
    }
    if (cfg_.policy == HUB_POLICY_PRODUCTION && (wasMember != isMem || syncedEdge)) requestHb(now);
  }

  // A new member link of a deviceId that already has a session replaces the older link (spec
  // §4.9 "stale"). Checked at AUTHED, so a stranger that copies a member's deviceId cannot evict it.
  void dropStale(uint8_t s) {
    const HubLink& L = links_[s];
    for (uint8_t o = 0; o < HUB_MAX_LINKS; o++) {
      HubLink& c = links_[o];
      if (o == s || !c.used || !c.subscribed || c.discSent || !c.session.hasPeer()) continue;
      if (c.session.peerId() != L.session.peerId()) continue;
      if ((int32_t)(c.order - L.order) >= 0) continue;  // only older links
      traceDisconnect(c.conn, HUB_DISC_STALE, false, 0);
      closeNow(o);
    }
  }

  void onCommit(uint8_t s, uint32_t now) {
    HubLink& L = links_[s];
    int64_t wall = 0;
    const uint32_t wallS = (clock_->wallMs(now, &wall) && wall > 0) ? (uint32_t)(wall / 1000) : 0;
    db_->peerCommitted(L.session.peerId(), wallS, now);
    if (db_->lastSeq() > db_->durableHigh()) markDirty(now);
  }

  void onDeliver(uint8_t s, uint8_t type, const uint8_t* raw, size_t rawLen, uint32_t now) {
    HubLink& L = links_[s];
    const Msg& m = L.session.received();
    switch (type) {
      case MSG_PULL:
        servePull(s, m.pull, now);
        return;
      case MSG_REC:
        L.recsIn++;
        onRec(s, m.rec, now);
        return;
      case MSG_HB:
        onHb(s, m.hb, raw, rawLen, now);
        return;
      case MSG_EVT:
        onEvt(s, m.evt, now);
        return;
      case MSG_EVT_SINCE:
        relayRaw(s, m.evtSince.origin, raw, rawLen);
        return;
      case MSG_EVT_GAP:
        relayRaw(s, m.evtGap.requester, raw, rawLen);
        return;
      case MSG_ERR:
        L.errsIn++;
        L.lastErrIn = m.err.code;
        return;
      default:  // SUB: the session keeps the subs
        return;
    }
  }

  // ---- pages --------------------------------------------------------------------------------------
  void servePull(uint8_t s, const Pull& p, uint32_t now) {
    HubLink& L = links_[s];
    if (!db_->ready()) {
      sendErr(s, E_NOT_READY, true, MSG_PULL, NULL, true, NOT_READY_RETRY_MS);
      return;
    }
    const Id8 peer = L.session.peerId();
    const PeerState* ps = db_->peerFind(peer);
    const uint32_t limit = db_->durableHigh();  // D5: durable-only
    L.page.begin(p, limit, ps != NULL && ps->excludeOk, peer);
    db_->feedBegin(&L.cursor, p.since, limit);
    L.pageActive = true;
    L.pageSince = p.since;
    L.pageLimit = limit;
    db_->notePageTraffic(now);
  }

  void pageStep(uint8_t s, uint32_t now) {
    HubLink& L = links_[s];
    if (!L.pageActive || L.discSent) return;
    if (!hubLightWorkAllowed(*gate_) || gate_->otaBusy()) return;  // paused while a job is on air
    if (!db_->ready()) {
      finishPage(s, false, now);
      return;
    }
    FeedBudget b;
    b.entries = HUB_SCAN_ENTRIES;
    b.bytes = HUB_SCAN_BYTES;
    while (L.pageActive) {
      if (!L.outbox.hasRoomFor(OC_PAGE, HUB_PAGE_REC_ROOM)) return;
      DbEntry e;
      const uint8_t st = db_->feedNext(&L.cursor, &b, &e);
      if (st == DB_FEED_ENTRY) {
        size_t n = 0;
        const PageStep ps = L.page.offer(e.seq, e.body, e.bodyLen, e.hasOrigin ? &e.origin : NULL,
                                         e.hasSyncFrom ? &e.syncFrom : NULL, txBuf_, sizeof(txBuf_), &n);
        if (ps == PAGE_SEND) {
          enqueue(s, OC_PAGE, txBuf_, n);
        } else if (ps == PAGE_STOP) {
          finishPage(s, false, now);
        }
      } else if (st == DB_FEED_YIELD) {
        return;
      } else if (st == DB_FEED_END) {
        finishPage(s, true, now);
      } else {
        finishPage(s, false, now);
      }
    }
  }

  void finishPage(uint8_t s, bool exhausted, uint32_t now) {
    HubLink& L = links_[s];
    PageEnd e = L.page.end();
    // D-P2-3: a scan that reached durableHigh without stopping covered every current entry, even
    // when the tail entries are superseded (their replacement still dirty).
    if (exhausted && L.pageSince < L.pageLimit) {
      e.scannedTo = L.pageLimit;
      e.more = 0;
    }
    const size_t n = encode(e, txBuf_, sizeof(txBuf_));
    enqueue(s, OC_PAGE, txBuf_, n);
    if (e.more == 0) {
      PeerState* ps = db_->peerFind(L.session.peerId());
      if (ps) ps->excludeOk = true;
    }
    L.pageActive = false;
    L.pagesServed++;
    db_->notePageTraffic(now);
  }

  // ---- records ------------------------------------------------------------------------------------
  static bool bodyOrigin(const uint8_t* p, size_t n, Id8* out) {
    if (!tlvFramingOk(p, n, 0)) return false;
    for (size_t i = 0; i < n;) {
      const uint8_t tag = p[i], ln = p[i + 1];
      if (tag == T_ORIGIN && ln == 8) {
        *out = makeId8(p + i + 2);
        return !isZero(*out);
      }
      i += 2 + (size_t)ln;
    }
    return false;
  }

  void onRec(uint8_t s, const Rec& r, uint32_t now) {
    HubLink& L = links_[s];
    const bool live = r.reqId == 0;
    if (!r.bodyStatus.ok()) {
      const uint8_t code = r.bodyStatus.code == E_CLOCK ? E_CLOCK : E_BAD_MSG;
      if (trace_) trace_->apply(L.conn, NULL, code == E_CLOCK ? DBR_CLOCK : DBR_BAD_MSG, live);
      Key k;
      const bool hk = recErrKey(r, &k);  // D-P2-19
      sendErr(s, code, true, MSG_REC, hk ? &k : NULL, false, 0);
      return;
    }
    const Id8 peer = L.session.peerId();
    int64_t wall = 0;
    const bool known = clock_->wallMs(now, &wall);
    const DbAccept a = db_->accept(r.body, r.bodyLen, peer, known, wall, live, now);
    if (trace_) trace_->apply(L.conn, a.hasKey ? &a.key : NULL, a.result, live);
    const Key* key = a.hasKey ? &a.key : NULL;
    switch (a.result) {
      case DBR_BAD_MSG:
        sendErr(s, E_BAD_MSG, true, MSG_REC, key, false, 0);
        return;
      case DBR_CLOCK:
        sendErr(s, E_CLOCK, true, MSG_REC, key, false, 0);
        return;
      case DBR_FULL:
        sendErr(s, E_FULL, true, MSG_REC, key, false, 0);
        return;
      case DBR_COLLISION:
        sendErr(s, E_COLLISION, true, MSG_REC, key, false, 0);
        return;
      case DBR_BUSY:
        sendErr(s, E_BUSY, true, MSG_REC, key, true, BUSY_RETRY_MS);
        return;
      case DBR_NOT_READY:
        sendErr(s, E_NOT_READY, true, MSG_REC, NULL, true, NOT_READY_RETRY_MS);
        return;
      case DBR_ACCEPT:
        break;
      default:  // DUPLICATE, STALE
        return;
    }
    markDirty(now);
    if (!live) {
      pageAccepted_ = true;
      db_->notePageTraffic(now);
      return;
    }
    // first accept of a live REC: forward once to members not in seenBy u {sender, origin}
    RouteSession rs[HUB_MAX_LINKS];
    uint8_t slots[HUB_MAX_LINKS];
    const uint8_t n = routeSessions(SUB_RECORDS, rs, slots);
    Id8 origin;
    const bool hasOrigin = bodyOrigin(r.body, r.bodyLen, &origin);
    const Route route = routeLiveRec(cfg_.deviceId, peer, hasOrigin ? &origin : NULL, r.seenBy,
                                     r.seenByCount, rs, n);
    if (route.nTargets == 0) return;
    if (!db_->reserveLive(a.seq, now)) {  // D-P2-4: the HB and the pulls deliver it instead
      liveSkipped_++;
      return;
    }
    Rec& out = scratch_.rec;
    memset(&out, 0, sizeof(out));
    out.seq = a.seq;
    out.reqId = 0;
    out.seenByCount = route.nSeen;
    for (uint8_t k = 0; k < route.nSeen; k++) out.seenBy[k] = route.seenBy[k];
    out.bodyLen = r.bodyLen;
    memcpy(out.body, r.body, r.bodyLen);
    const size_t len = encode(out, txBuf_, sizeof(txBuf_));
    for (uint8_t k = 0; k < route.nTargets; k++) enqueue(slots[route.targets[k]], OC_LIVE, txBuf_, len);
  }

  // ---- flush --------------------------------------------------------------------------------------
  void markDirty(uint32_t now) {
    if (!dirtySinceSet_) {
      dirtySinceSet_ = true;
      dirtySince_ = now;
    }
    if (flushPending_) return;
    flushPending_ = true;
    schedule(now + HUB_FLUSH_DELAY_MS, ++flushGen_, TK_FLUSH, HUB_SLOT_NONE, 0);
  }

  void doFlush(uint32_t now) {
    const uint8_t r = db_->flush(now, false);
    if (r == DB_FLUSH_DONE || r == DB_FLUSH_NONE) {
      afterFlush(now);
      return;
    }
    if (r == DB_FLUSH_DEFERRED && !hubFlashWorkAllowed(*gate_, now, false)) {
      flushWanted_ = true;  // the gate is closed: tried again on the first pass it is open
      return;
    }
    // failed, or deferred with the gate open (compaction holds flushes): retry a little later
    flushWanted_ = false;
    flushPending_ = true;
    schedule(now + HUB_FLUSH_RETRY_MS, ++flushGen_, TK_FLUSH, HUB_SLOT_NONE, 0);
  }

  void afterFlush(uint32_t now) {
    flushWanted_ = false;
    if (db_->lastSeq() == db_->durableHigh()) dirtySinceSet_ = false;
    const uint32_t dh = db_->durableHigh();
    if (dh != tracedDurable_) {
      tracedDurable_ = dh;
      if (trace_) trace_->durable(dh);
    }
    if (pageAccepted_) {  // records from pages are announced by an HB once durable (spec §3.8)
      pageAccepted_ = false;
      requestHb(now);
    }
  }

  // A deferred flush whose gate is open now, or (PRODUCTION) the 2 KB size trigger.
  bool wantedFlushDue(uint32_t now) {
    const bool sizeTrigger =
        cfg_.policy == HUB_POLICY_PRODUCTION && db_->dirtyBytes() >= HUB_FLUSH_DIRTY_BYTES;
    if (!flushWanted_ && !sizeTrigger) return false;
    if (db_->lastSeq() == db_->durableHigh()) return false;
    return hubFlashWorkAllowed(*gate_, now, dirtyStarved(now));
  }

  bool dirtyStarved(uint32_t now) const {
    return dirtySinceSet_ && now - dirtySince_ >= HUB_DIRTY_STARVED_MS;
  }

  void wantedFlush(uint32_t now) {
    if (flushWanted_ && db_->lastSeq() == db_->durableHigh()) {
      afterFlush(now);  // a forced flush or the DB's own covered it
      return;
    }
    if (!wantedFlushDue(now)) return;
    flushPending_ = false;
    ++flushGen_;  // the pending timer, if any, is now a no-op
    doFlush(now);
  }

  // ---- heartbeats ---------------------------------------------------------------------------------
  size_t buildHb(uint32_t now) {
    Hb& h = scratch_.hb;
    memset(&h, 0, sizeof(h));
    h.deviceId = cfg_.deviceId;
    h.kind = KIND_HUB;
    h.bootId = cfg_.bootId;
    h.hbSeq = ++hbSeq_;
    int64_t wall = 0;
    h.ts = (clock_->wallMs(now, &wall) && wall > 0) ? wall : 0;
    HubSelf me;
    memset(&me, 0, sizeof(me));
    me.battPct = -1;
    me.battMv = -1;
    me.charging = -1;
    me.runtimeMin = -1;
    if (self_) self_->read(&me);
    h.uptimeS = me.uptimeS;
    // the HB field ranges (SYNC_PROTOCOL §11.8): out-of-range values read as unknown (-1)
    h.hasBattPct = true;
    h.battPct = (me.battPct >= -1 && me.battPct <= 100) ? me.battPct : (int8_t)-1;
    h.hasBattMv = true;
    h.battMv = me.battMv >= -1 ? me.battMv : (int16_t)-1;
    h.hasCharging = true;
    h.charging = (me.charging >= -1 && me.charging <= 1) ? me.charging : (int8_t)-1;
    h.hasRuntimeMin = true;
    h.runtimeMin = (me.runtimeMin >= -1 && me.runtimeMin <= 5999) ? me.runtimeMin : (int16_t)-1;
    setStr(&h.version, cfg_.version);
    setStr(&h.name, cfg_.name);
    uint8_t ord[HUB_MAX_LINKS];
    const uint8_t n = sessionOrder(ord, true);
    for (uint8_t i = 0; i < n && h.linkCount < HB_LINKS_MAX; i++) {
      const HubLink& L = links_[ord[i]];
      HbLink& l = h.links[h.linkCount++];
      l.peerId = L.session.peerId();
      l.peerKind = L.session.peerHello().kind;
      l.flags = (uint8_t)((L.session.state() == ST_SYNCED ? HB_LINK_SYNCED : 0) |
                          ((L.session.peerHello().capsValue() & CAP_TRANSMITTER) ? HB_LINK_TX_READY : 0));
    }
    uint16_t state = (uint16_t)(me.state & (HB_STATE_KEEP_AWAKE | HB_STATE_TX_LOOP | HB_STATE_WAND_LOOP |
                                            HB_STATE_LOW_POWER | HB_STATE_TX_BUSY));
    if (db_->full()) state |= HB_STATE_HUB_FULL;
    if (clock_->skewed()) state |= HB_STATE_CLOCK_SKEW;
    if (!db_->ready()) state |= HB_STATE_SYNC_NOT_READY;
    h.hasState = true;
    h.state = state;
    h.hops = 0;
    h.feedHigh = db_->durableHigh();
    h.dbId = db_->dbId();
    DbStats st;
    db_->stats(&st);
    h.records = st.records;
    return encode(h, hbBuf_, sizeof(hbBuf_));
  }

  void sendHb(const uint8_t* slots, uint8_t n, uint32_t now) {
    const size_t len = buildHb(now);
    lastHbT_ = now;
    hbEver_ = true;
    if (len == 0) return;
    for (uint8_t i = 0; i < n; i++) enqueue(slots[i], OC_HB, hbBuf_, len);
  }

  void requestHb(uint32_t now) {
    if (hbRoundPending_) return;
    hbRoundPending_ = true;
    uint32_t due = now;
    if (hbEver_ && (int32_t)(lastHbT_ + T_HB_SPACING_MS - now) > 0) due = lastHbT_ + T_HB_SPACING_MS;
    schedule(due, 0, TK_HB_ROUND, HUB_SLOT_NONE, 0);
  }

  void onHb(uint8_t s, const Hb& hb, const uint8_t* raw, size_t rawLen, uint32_t now) {
    HubLink& L = links_[s];
    const Id8 peer = L.session.peerId();
    const bool direct = hb.hops == 0 && hb.deviceId == peer;
    roster_.update(hb, direct, L.session.peerHello().kind, cfg_.deviceId, now);
    if (!direct) return;
    RouteSession rs[HUB_MAX_LINKS];
    uint8_t slots[HUB_MAX_LINKS], tg[HUB_MAX_LINKS];
    const uint8_t n = routeSessions(SUB_HEARTBEATS, rs, slots);
    const uint8_t k = routeHb(cfg_.deviceId, peer, hb.deviceId, 0, rs, n, tg);
    if (k && raw && rawLen <= sizeof(txBuf_)) {
      memcpy(txBuf_, raw, rawLen);
      if (hbSetHops(txBuf_, rawLen, 1)) {
        for (uint8_t i = 0; i < k; i++) enqueue(slots[tg[i]], OC_HB, txBuf_, rawLen);
      }
    }
    if (hb.kind != KIND_HUB && hb.ts > 0) clock_->observe(peer, hb.ts, now);
  }

  // ---- events (relay only: no ring, no dedupe) ------------------------------------------------------
  bool evtPaced(HubLink& L, uint32_t now) {
    if (now - L.evtWindowStart >= 1000) {
      L.evtWindowStart = now;
      L.evtInWindow = 0;
    }
    if (L.evtInWindow >= HUB_EVT_PER_S) {
      L.evtDropped++;
      return false;
    }
    L.evtInWindow++;
    return true;
  }

  void onEvt(uint8_t s, const Evt& evt, uint32_t now) {
    HubLink& L = links_[s];
    RouteSession rs[HUB_MAX_LINKS];
    uint8_t slots[HUB_MAX_LINKS];
    const uint8_t n = routeSessions(SUB_EVENTS, rs, slots);
    const Route route = routeEvtRelay(cfg_.deviceId, L.session.peerId(), evt.origin, evt.seenBy,
                                      evt.seenByCount, rs, n);
    if (route.nTargets == 0) return;
    Evt& out = scratch_.evt;
    out = evt;
    out.seenByCount = route.nSeen;
    for (uint8_t k = 0; k < route.nSeen; k++) out.seenBy[k] = route.seenBy[k];
    const size_t len = encode(out, txBuf_, sizeof(txBuf_));
    for (uint8_t k = 0; k < route.nTargets; k++) {
      const uint8_t t = slots[route.targets[k]];
      if (evtPaced(links_[t], now)) enqueue(t, OC_EVT, txBuf_, len);
    }
  }

  // EVT_SINCE -> the member whose peer is origin; EVT_GAP -> the member whose peer is requester.
  void relayRaw(uint8_t s, const Id8& to, const uint8_t* raw, size_t rawLen) {
    const uint8_t t = memberFor(to);
    if (t == HUB_SLOT_NONE || t == s || !raw) return;
    enqueue(t, OC_EVT, raw, rawLen);
  }

  // ---- repull, edges, frames ----------------------------------------------------------------------
  void repullAll(uint32_t now) {
    db_->zeroAllWm(now);
    uint8_t ord[HUB_MAX_LINKS];
    const uint8_t n = sessionOrder(ord, true);
    for (uint8_t i = 0; i < n; i++) {
      refresh(ord[i]);
      processActions(ord[i], links_[ord[i]].session.pullNow(now), NULL, 0, now);
    }
  }

  void watchEdges(uint32_t now) {
    const bool full = db_->full(), ready = db_->ready(), skew = clock_->skewed();
    if (full != lastFull_ || ready != lastReady_ || skew != lastSkew_) requestHb(now);
    lastFull_ = full;
    lastReady_ = ready;
    lastSkew_ = skew;
  }

  void sendFrames(uint8_t s, uint32_t now) {
    HubLink& L = links_[s];
    if (!L.used || !L.subscribed || !L.outbox.hasFrame()) return;
    if (L.discSent && cfg_.policy != HUB_POLICY_TRANSCRIPT) return;
    if (L.txBlocked) {
      if ((int32_t)(now - L.txBlockedUntil) < 0) return;
      L.txBlocked = false;
    }
    const bool timed = gate_->timedJob();
    if (timed && L.sentAny && (now - L.lastFrameMs) < HUB_TIMED_FRAME_GAP_MS) {
      schedule(L.lastFrameMs + HUB_TIMED_FRAME_GAP_MS, 0, TK_TX_RETRY, s, 0);
      return;
    }
    const uint8_t maxN = timed ? 1 : HUB_FRAMES_PER_PASS;
    for (uint8_t k = 0; k < maxN; k++) {
      size_t fl = 0;
      const uint8_t* f = L.outbox.peekFrame(L.mtu, timed, &fl);
      if (!f) break;
      if (!radio_->sendFrame(L.conn, f, fl)) {
        L.txBlocked = true;
        L.txBlockedUntil = now + HUB_TX_RETRY_MS;
        schedule(L.txBlockedUntil, 0, TK_TX_RETRY, s, 0);
        break;
      }
      L.outbox.popFrame();
      L.sentAny = true;
      L.lastFrameMs = now;
      L.framesSent++;
    }
    if (timed && L.outbox.hasFrame()) schedule(now + HUB_TIMED_FRAME_GAP_MS, 0, TK_TX_RETRY, s, 0);
  }

  // ---- state ----------------------------------------------------------------------------------------
  bool begun_;
  HubConfig cfg_;
  SessionConfig scfg_;
  HubDb* db_;
  Radio* radio_;
  TxGate* gate_;
  Clock* clock_;
  Rng* rng_;
  SelfInfo* self_;
  Scheduler* sched_;
  HubTrace* trace_;

  HubLink links_[HUB_MAX_LINKS];
  Roster roster_;

  uint32_t now_;
  uint32_t genCounter_;
  uint32_t orderCounter_;
  uint32_t hbSeq_;
  bool hbEver_;
  uint32_t lastHbT_;
  bool hbRoundPending_;
  bool flushPending_;
  uint32_t flushGen_;
  bool flushWanted_;
  bool dirtySinceSet_;
  uint32_t dirtySince_;
  bool pageAccepted_;
  uint32_t tracedDurable_;
  bool radioBudgetHit_;
  bool resetPending_;
  uint32_t resetGen_;
  bool lastFull_;
  bool lastReady_;
  bool lastSkew_;
  uint32_t liveSkipped_;
  uint32_t rxNoLink_;
  uint32_t resets_;
  uint32_t badFramesClosed_;
  uint32_t liveDroppedClosed_;

  // scratch (members, not stack: loopTask has 8 KB)
  uint8_t txBuf_[HUB_TXBUF_BYTES];
  uint8_t hbBuf_[300];
  union Scratch {  // never two at once: buildHb, onRec and onEvt do not nest
    Hb hb;
    Rec rec;
    Evt evt;
  } scratch_;
};

}  // namespace mmsync
