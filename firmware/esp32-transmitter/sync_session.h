// MagicMaker SYNC v1 session state machine (docs/SYNC_PROTOCOL.md §13, §14, §15.3): one end of
// one BLE link as a pure function of (state, node context, input) -> (state', actions).
//
// No I/O and no clock reads: time is the input's `t` (ms, e.g. millis()); timers are absolute
// due times the node delivers back with timer(t = due, id). The session builds HELLO, AUTH, JOIN,
// PULL and ERR itself; everything else it hands to the node as actions:
//
//   SEND{type, bytes}  STATE{to}  DELIVER{type} (session.received())  COMMIT{wm}
//   GROUP{groupId, groupKey, rekey}  NODE{send_hb | evt_since | foreign}  DISCONNECT{reason, retryMs}
//
// in exactly the order the shared `sessions` vectors pin (tools/sync/vectors.json). Each call
// returns the action list, valid until the next call on the same session.
//
// Portable C++11, no heap. One Session per link; linkUp() starts a fresh session.
#pragma once

#include "sync_codec.h"
#include "sync_events.h"

namespace mmsync {

enum SessionState : uint8_t {
  ST_IDLE = 0,
  ST_LINKED,
  ST_HELLO_X,
  ST_AUTHED,
  ST_SYNCING,
  ST_SYNCED,
  ST_FOREIGN,
  ST_NOGROUP,
  ST_INCOMPATIBLE,
  ST_CLOSED
};

inline const char* sessionStateName(uint8_t s) {
  static const char* const names[] = {"IDLE",   "LINKED",  "HELLO_X", "AUTHED",       "SYNCING",
                                      "SYNCED", "FOREIGN", "NOGROUP", "INCOMPATIBLE", "CLOSED"};
  return s <= ST_CLOSED ? names[s] : "?";
}

enum TimerId : uint8_t {
  TM_HELLO = 0,
  TM_AUTH,
  TM_DEADLINE,
  TM_PAGE,
  TM_LIVE_PULL,
  TM_HB,
  TM_RETRY,
  TM_BACKOFF,
  TM_COUNT
};

inline const char* timerName(uint8_t t) {
  static const char* const names[] = {"HELLO", "AUTH", "DEADLINE", "PAGE",
                                      "LIVE_PULL", "HB", "RETRY", "BACKOFF"};
  return t < TM_COUNT ? names[t] : "?";
}

enum ActionKind : uint8_t {
  ACT_SEND = 1,
  ACT_STATE,
  ACT_DELIVER,
  ACT_COMMIT,
  ACT_GROUP,
  ACT_NODE,
  ACT_DISCONNECT
};

enum NodeWhat : uint8_t { NODE_SEND_HB = 1, NODE_EVT_SINCE, NODE_FOREIGN };

inline const char* nodeWhatName(uint8_t w) {
  static const char* const names[] = {"?", "send_hb", "evt_since", "foreign"};
  return w <= NODE_FOREIGN ? names[w] : "?";
}

enum DisconnectReason : uint8_t {
  DISC_FOREIGN = 1,
  DISC_AUTH_TIMEOUT,
  DISC_AUTH_DEADLINE,
  DISC_PAGE_TIMEOUT,
  DISC_LEFT_GROUP
};

inline const char* disconnectReasonName(uint8_t r) {
  static const char* const names[] = {"?", "foreign", "auth_timeout", "auth_deadline",
                                      "page_timeout", "left_group"};
  return r <= DISC_LEFT_GROUP ? names[r] : "?";
}

enum SessionRole : uint8_t { ROLE_CENTRAL = 0, ROLE_PERIPHERAL = 1 };

struct Action {
  uint8_t kind;     // ActionKind
  uint8_t msgType;  // SEND, DELIVER
  uint8_t state;    // STATE
  uint8_t what;     // NODE
  uint8_t reason;   // DISCONNECT
  bool rekey;       // GROUP
  bool hasRetry;    // DISCONNECT
  uint16_t off;     // SEND: message bytes; GROUP: groupId (8) ‖ groupKey (16)
  uint16_t len;
  uint32_t value;   // COMMIT: wm; DISCONNECT: retryMs
};

class ActionList {
 public:
  static const size_t MAX_ACTIONS = 16;
  static const size_t ARENA = 640;

  ActionList() : n_(0), used_(0), overflow_(false) {}

  size_t size() const { return n_; }
  const Action& operator[](size_t i) const { return items_[i]; }
  // The bytes of a SEND (the message) or GROUP (groupId ‖ groupKey) action.
  const uint8_t* bytes(const Action& a) const { return arena_ + a.off; }
  // True if an action or its bytes did not fit (never in v1; a bug guard).
  bool overflowed() const { return overflow_; }

  void clear() {
    n_ = 0;
    used_ = 0;
    overflow_ = false;
  }

  Action* push(uint8_t kind) {
    if (n_ >= MAX_ACTIONS) {
      overflow_ = true;
      return NULL;
    }
    Action* a = &items_[n_++];
    memset(a, 0, sizeof(*a));
    a->kind = kind;
    return a;
  }

  // Reserves `cap` arena bytes; commit(n) keeps the first n.
  uint8_t* reserve(size_t cap, uint16_t* off) {
    if (used_ + cap > ARENA) {
      overflow_ = true;
      return NULL;
    }
    *off = (uint16_t)used_;
    return arena_ + used_;
  }
  void commit(size_t n) { used_ += n; }

 private:
  Action items_[MAX_ACTIONS];
  size_t n_;
  uint8_t arena_[ARENA];
  size_t used_;
  bool overflow_;
};

// Per peer deviceId (§15.1), persisted by the node.
struct PeerState {
  Id8 dbId;      // the peer's dbId that wm refers to
  uint32_t wm;   // highest seq of the peer's feed durably applied (puller side)
  bool excludeOk;  // the peer may be served with exclusion (server side)
};

struct GroupState {
  bool grouped;
  Id8 id;
  uint8_t key[16];
};

// The node as the session sees it. The data members are node-level state shared by all of the
// node's sessions (a session writes `group` when it accepts a JOIN, and emits ACT_GROUP so the node
// persists it); the hooks give time, nonces and the peer table.
class SessionNode {
 public:
  GroupState group;
  Id8 dbId;
  uint32_t feedHigh;  // durableHigh
  bool ready;         // hub: index built

  // Unix ms for HELLO clockMs (0 = unknown) at session time t.
  virtual int64_t clockMs(uint32_t t) = 0;
  // A fresh random handshake nonce.
  virtual void nextNonce(uint8_t out[8]) = 0;
  // The peer table: find (NULL when absent) / find or create (never NULL; a fresh entry is
  // {zero dbId, wm 0, excludeOk false}).
  virtual PeerState* findPeer(const Id8& id) = 0;
  virtual PeerState* peer(const Id8& id) = 0;

 protected:
  SessionNode() : dbId(zeroId8()), feedHigh(0), ready(true) { memset(&group, 0, sizeof(group)); }
  ~SessionNode() {}
};

// A small fixed peer table a node can embed (the oldest entry is reused when it is full).
template <size_t N>
class PeerTable {
 public:
  PeerTable() : n_(0), next_(0) {}

  PeerState* find(const Id8& id) {
    for (size_t i = 0; i < n_; i++)
      if (ids_[i] == id) return &st_[i];
    return NULL;
  }

  PeerState* getOrCreate(const Id8& id) {
    PeerState* p = find(id);
    if (p) return p;
    size_t i;
    if (n_ < N) {
      i = n_++;
    } else {
      i = next_;
      next_ = (next_ + 1) % N;
    }
    ids_[i] = id;
    st_[i].dbId = zeroId8();
    st_[i].wm = 0;
    st_[i].excludeOk = false;
    return &st_[i];
  }

  size_t size() const { return n_; }
  const Id8& idAt(size_t i) const { return ids_[i]; }
  PeerState* at(size_t i) { return &st_[i]; }

 private:
  Id8 ids_[N];
  PeerState st_[N];
  size_t n_;
  size_t next_;
};

struct SessionConfig {
  SessionRole role;
  Id8 deviceId;
  uint8_t kind;  // KIND_*
  uint16_t bootId;
  uint16_t maxMsg;
  uint16_t caps;
  const char* version;  // NULL / "" = not sent
  const char* name;
  uint8_t peerKind;  // central: the peer's kind, known from discovery
  bool tracksEvents;  // iPhone
  bool isHub;
};

class Session {
 public:
  Session() : cfg_(NULL), node_(NULL) { reset(); }

  void attach(const SessionConfig* cfg, SessionNode* node) {
    cfg_ = cfg;
    node_ = node;
    reset();
  }

  // ---- inputs ---------------------------------------------------------------------------------
  const ActionList& linkUp(uint32_t t, uint16_t mtu) {
    reset();
    out_.clear();
    if (mtu < SMALL_MTU_BELOW) {
      limit_ = PULL_LIMIT_SMALL;
      maxBytes_ = PULL_MAXBYTES_SMALL;
    } else {
      limit_ = PULL_LIMIT_DEFAULT;
      maxBytes_ = PULL_MAXBYTES_DEFAULT;
    }
    setState(ST_LINKED);
    if (central()) {
      startHello(t);
    } else if (cfg_->isHub && node_->group.grouped) {
      arm(TM_DEADLINE, t, T_DEADLINE_MS);
    }
    return out_;
  }

  const ActionList& linkDown(uint32_t t) {
    (void)t;
    out_.clear();
    cancelAll();
    setState(ST_CLOSED);
    return out_;
  }

  const ActionList& rx(uint32_t t, const uint8_t* d, size_t n) {
    out_.clear();
    if (state_ == ST_IDLE || state_ == ST_CLOSED || state_ == ST_FOREIGN || n == 0) return out_;
    const uint8_t mtype = d[0];
    // A HELLO whose first TLV is 01 01 xx with xx != 1: ERR PROTO before any other decoding.
    if (mtype == MSG_HELLO && n >= 4 && d[1] == 0x01 && d[2] == 1 && d[3] != PROTO) {
      sendErr(E_PROTO, true, MSG_HELLO, NULL, false, 0);
      incompatible(t, false);
      return out_;
    }
    const Status s = decodeMsg(d, n, &rx_);
    if (!s.ok()) {
      if (mtype != MSG_ERR) sendErr(E_BAD_MSG, true, mtype, NULL, false, 0);
      return out_;
    }
    if (!rx_.known) return out_;  // unknown message type: ignored
    switch (mtype) {
      case MSG_HELLO:
        if (central()) {
          centralHello(t);
        } else {
          peripheralHello(t);
        }
        break;
      case MSG_AUTH:
        peripheralAuth(t);
        break;
      case MSG_JOIN:
        onJoin(t);
        break;
      case MSG_ERR:
        onErr(t);
        break;
      default:
        if (authed()) onData(t, mtype);
        break;
    }
    return out_;
  }

  // A timer is delivered at its due time; one that was re-armed or cancelled is ignored.
  const ActionList& timer(uint32_t t, TimerId id) {
    out_.clear();
    if (id < TM_COUNT && timers_[id].armed && timers_[id].due == t) {
      timers_[id].armed = false;
      onTimer(t, id);
    }
    return out_;
  }

  // The node joined or left a group on another link or by the user.
  const ActionList& groupChanged(uint32_t t) {
    out_.clear();
    doGroupChanged(t);
    return out_;
  }

  // The node has a new key to spread ("New sync group", or a rekey accepted elsewhere).
  const ActionList& rekey(uint32_t t) {
    out_.clear();
    if (authed() && node_->group.grouped) {
      sendJoin(true);
      restart(t);
    } else {
      doGroupChanged(t);
    }
    return out_;
  }

  // Node-level pull trigger (e.g. the hub's hubFull clearing).
  const ActionList& pullNow(uint32_t t) {
    out_.clear();
    if (authed()) triggerPull(t, false, 0);
    return out_;
  }

  // ---- observation ----------------------------------------------------------------------------
  SessionState state() const { return (SessionState)state_; }
  bool authed() const {
    return state_ == ST_AUTHED || state_ == ST_SYNCING || state_ == ST_SYNCED;
  }
  bool timerArmed(TimerId id) const { return id < TM_COUNT && timers_[id].armed; }
  uint32_t timerDue(TimerId id) const { return id < TM_COUNT ? timers_[id].due : 0; }
  // The earliest armed timer relative to now (wrap-safe); false when none is armed.
  bool nextTimer(uint32_t now, TimerId* id, uint32_t* due) const {
    bool any = false;
    int32_t best = 0;
    for (uint8_t i = 0; i < TM_COUNT; i++) {
      if (!timers_[i].armed) continue;
      const int32_t d = (int32_t)(timers_[i].due - now);
      if (!any || d < best) {
        best = d;
        *id = (TimerId)i;
        *due = timers_[i].due;
        any = true;
      }
    }
    return any;
  }
  bool hasPeer() const { return hasPeer_; }
  const Hello& peerHello() const { return peer_; }
  const Id8& peerId() const { return peer_.deviceId; }
  uint8_t peerSubs() const { return peerSubs_; }
  // The peer-table entry of this session's peer, once the peer is known and has one.
  PeerState* peerEntry() { return hasPeer_ ? node_->findPeer(peer_.deviceId) : NULL; }
  // The message of the last ACT_DELIVER (valid until the next input).
  const Msg& received() const { return rx_; }
  bool pullOutstanding() const { return pullActive_; }

 private:
  struct Timer {
    bool armed;
    uint32_t due;
  };

  enum Backoff : uint8_t { BO_NONE = 0, BO_HELLO, BO_PULL };

  bool central() const { return cfg_->role == ROLE_CENTRAL; }

  void reset() {
    state_ = ST_IDLE;
    for (uint8_t i = 0; i < TM_COUNT; i++) {
      timers_[i].armed = false;
      timers_[i].due = 0;
    }
    hasPeer_ = false;
    memset(&peer_, 0, sizeof(peer_));
    peerSubs_ = 0;
    alike_ = false;
    hasNonceC_ = false;
    hasNonceP_ = false;
    nonceC_ = zeroId8();
    nonceP_ = zeroId8();
    helloTries_ = 0;
    hasReply_ = false;
    replyCount_ = 0;
    reqId_ = 0;
    pullActive_ = false;
    pullReqId_ = 0;
    pullSince_ = 0;
    pullRecs_ = 0;
    pullTries_ = 0;
    pendingHigh_ = -1;
    limit_ = PULL_LIMIT_DEFAULT;
    maxBytes_ = PULL_MAXBYTES_DEFAULT;
    backoff_ = BO_NONE;
    scratchPeer_.dbId = zeroId8();
    scratchPeer_.wm = 0;
    scratchPeer_.excludeOk = false;
    clearMsg(&rx_, 0);
  }

  // ---- emit helpers ---------------------------------------------------------------------------
  void setState(uint8_t s) {
    if (s == state_) return;
    state_ = s;
    Action* a = out_.push(ACT_STATE);
    if (a) a->state = s;
  }

  void sendBytes(uint8_t type, const uint8_t* p, size_t n) {
    uint16_t off = 0;
    uint8_t* dst = out_.reserve(n, &off);
    Action* a = dst ? out_.push(ACT_SEND) : NULL;
    if (!a) return;
    memcpy(dst, p, n);
    out_.commit(n);
    a->msgType = type;
    a->off = off;
    a->len = (uint16_t)n;
  }

  // Encodes and sends; returns the encoded length (0 on failure) and, when copy is given, keeps
  // a copy of the bytes (the peripheral's reply, re-sent on a duplicate HELLO).
  // Session-built messages (HELLO, AUTH, JOIN, PULL, ERR) are at most 136 bytes.
  size_t send(uint8_t type, const void* fields, uint8_t* copy = NULL, size_t copyCap = 0) {
    static const size_t MAX_BUILT = 256;
    uint16_t off = 0;
    uint8_t* dst = out_.reserve(MAX_BUILT, &off);
    if (!dst) return 0;
    const size_t n = encodeFields(type, fields, dst, MAX_BUILT);
    if (n == 0) return 0;
    Action* a = out_.push(ACT_SEND);
    if (!a) return 0;
    out_.commit(n);
    a->msgType = type;
    a->off = off;
    a->len = (uint16_t)n;
    if (copy && n <= copyCap) memcpy(copy, dst, n);
    return n;
  }

  void deliver(uint8_t type) {
    Action* a = out_.push(ACT_DELIVER);
    if (a) a->msgType = type;
  }

  void emitNode(uint8_t what) {
    Action* a = out_.push(ACT_NODE);
    if (a) a->what = what;
  }

  void emitGroup(bool rekey) {
    uint16_t off = 0;
    uint8_t* dst = out_.reserve(24, &off);
    Action* a = dst ? out_.push(ACT_GROUP) : NULL;
    if (!a) return;
    memcpy(dst, node_->group.id.b, 8);
    memcpy(dst + 8, node_->group.key, 16);
    out_.commit(24);
    a->off = off;
    a->len = 24;
    a->rekey = rekey;
  }

  void emitDisconnect(uint8_t reason, bool hasRetry, uint32_t retryMs) {
    Action* a = out_.push(ACT_DISCONNECT);
    if (!a) return;
    a->reason = reason;
    a->hasRetry = hasRetry;
    a->value = retryMs;
  }

  void sendErr(uint8_t code, bool hasRef, uint8_t ref, const Id8* dbId, bool hasRetry,
               uint16_t retryMs) {
    Err e;
    memset(&e, 0, sizeof(e));
    e.code = code;
    e.hasRefType = hasRef;
    e.refType = ref;
    if (dbId) {
      e.hasDbId = true;
      e.dbId = *dbId;
    }
    e.hasRetryMs = hasRetry;
    e.retryMs = retryMs;
    send(MSG_ERR, &e);
  }

  size_t sendJoin(bool rekey, uint8_t* copy = NULL, size_t copyCap = 0) {
    Join j;
    memset(&j, 0, sizeof(j));
    j.groupId = node_->group.id;
    memcpy(j.groupKey, node_->group.key, 16);
    if (rekey) {
      j.hasFlags = true;
      j.flags = JOIN_FLAG_REKEY;
    }
    return send(MSG_JOIN, &j, copy, copyCap);
  }

  // ---- timers -----------------------------------------------------------------------------------
  void arm(uint8_t id, uint32_t t, uint32_t ms) {
    timers_[id].armed = true;
    timers_[id].due = t + ms;
  }
  void cancel(uint8_t id) { timers_[id].armed = false; }
  void cancelAll() {
    for (uint8_t i = 0; i < TM_COUNT; i++) timers_[i].armed = false;
  }

  void disconnect(uint8_t reason, bool hasRetry, uint32_t retryMs) {
    cancelAll();
    emitDisconnect(reason, hasRetry, retryMs);
  }

  // ---- handshake ------------------------------------------------------------------------------
  void helloFields(uint32_t t, const Id8& nonce, const uint8_t* proof, Hello* h) {
    memset(h, 0, sizeof(*h));
    h->proto = PROTO;
    h->deviceId = cfg_->deviceId;
    h->kind = cfg_->kind;
    h->dbId = node_->dbId;
    const int64_t clock = node_->clockMs(t);
    h->clockMs = clock > 0 ? clock : 0;
    h->feedHigh = node_->feedHigh;
    h->subs = subsFor(cfg_->kind, central() ? cfg_->peerKind : peer_.kind);
    h->hasCaps = true;
    h->caps = cfg_->caps;
    h->maxMsg = cfg_->maxMsg;
    h->bootId = cfg_->bootId;
    setStr(&h->version, cfg_->version);
    setStr(&h->name, cfg_->name);
    h->groupId = node_->group.grouped ? node_->group.id : zeroId8();
    h->nonce = nonce;
    if (proof) {
      h->hasProof = true;
      memcpy(h->proof, proof, 16);
    }
  }

  size_t sendHello(uint32_t t, const Id8& nonce, const uint8_t* proof, uint8_t* copy = NULL,
                   size_t copyCap = 0) {
    Hello h;
    helloFields(t, nonce, proof, &h);
    return send(MSG_HELLO, &h, copy, copyCap);
  }

  Id8 freshNonce() {
    uint8_t b[8];
    node_->nextNonce(b);
    return makeId8(b);
  }

  void startHello(uint32_t t) {
    setState(ST_LINKED);
    nonceC_ = freshNonce();
    hasNonceC_ = true;
    helloTries_ = 1;
    sendHello(t, nonceC_, NULL);
    arm(TM_HELLO, t, T_HELLO_MS);
  }

  void resendHello(uint32_t t) {
    sendHello(t, nonceC_, NULL);
    arm(TM_HELLO, t, T_HELLO_MS);
  }

  // (idC, idP) for the proof transcript.
  void ids(Id8* idC, Id8* idP) const {
    if (central()) {
      *idC = cfg_->deviceId;
      *idP = peer_.deviceId;
    } else {
      *idC = peer_.deviceId;
      *idP = cfg_->deviceId;
    }
  }

  void proofs(uint8_t pp[16], uint8_t pc[16]) const {
    Id8 idC, idP;
    ids(&idC, &idP);
    proofP(node_->group.key, nonceC_, nonceP_, idC, idP, pp);
    proofC(node_->group.key, nonceC_, nonceP_, idC, idP, pc);
  }

  void rememberPeer(const Hello& m) {
    peer_ = m;
    hasPeer_ = true;
    peerSubs_ = m.subs;
  }

  void centralHello(uint32_t t) {
    if (state_ != ST_LINKED || !hasNonceC_ || !timers_[TM_HELLO].armed) return;
    cancel(TM_HELLO);
    cancel(TM_BACKOFF);
    const Hello m = rx_.hello;
    rememberPeer(m);
    nonceP_ = m.nonce;
    hasNonceP_ = true;
    const bool mine = node_->group.grouped;
    const bool theirs = !isZero(m.groupId);
    if (mine && theirs) {
      if (node_->group.id != m.groupId) {
        foreign(t, true, MSG_HELLO, true);
        return;
      }
      uint8_t pp[16], pc[16];
      proofs(pp, pc);
      if (!m.hasProof || !ctEqual(m.proof, pp, 16)) {
        foreign(t, true, MSG_HELLO, true);
        return;
      }
      alike_ = true;
      setState(ST_HELLO_X);
      Auth a;
      memcpy(a.proof, pc, 16);
      send(MSG_AUTH, &a);
      enterAuthed(t);
    } else if (mine) {
      sendJoin(false);
      startHello(t);
    } else if (theirs) {
      setState(ST_HELLO_X);
      arm(TM_AUTH, t, T_AUTH_MS);
    } else {
      setState(ST_NOGROUP);
    }
  }

  void addReply(uint8_t type, size_t n) {
    if (n == 0 || replyCount_ >= 2) return;
    replyType_[replyCount_] = type;
    replyLen_[replyCount_] = (uint16_t)n;
    replyCount_++;
  }

  void peripheralHello(uint32_t t) {
    const Hello m = rx_.hello;
    if (hasNonceC_ && m.nonce == nonceC_ && hasReply_) {
      // a duplicate of the HELLO already answered: the identical reply again
      if (state_ == ST_LINKED || state_ == ST_HELLO_X || state_ == ST_NOGROUP) {
        for (uint8_t i = 0; i < replyCount_; i++) sendBytes(replyType_[i], reply_[i], replyLen_[i]);
      }
      return;
    }
    if (!node_->ready) {
      sendErr(E_NOT_READY, true, MSG_HELLO, NULL, true, NOT_READY_RETRY_MS);
      return;
    }
    if (authed()) resetSync();
    cancel(TM_AUTH);
    rememberPeer(m);
    nonceC_ = m.nonce;
    hasNonceC_ = true;
    nonceP_ = freshNonce();
    hasNonceP_ = true;
    alike_ = false;
    replyCount_ = 0;
    const bool mine = node_->group.grouped;
    const bool theirs = !isZero(m.groupId);
    if (mine && theirs && node_->group.id == m.groupId) {
      alike_ = true;
      uint8_t pp[16], pc[16];
      proofs(pp, pc);
      addReply(MSG_HELLO, sendHello(t, nonceP_, pp, reply_[0], sizeof(reply_[0])));
      setState(ST_HELLO_X);
      arm(TM_AUTH, t, T_AUTH_MS);
    } else if (mine && theirs) {
      sendHello(t, nonceP_, NULL);
      hasReply_ = false;
      foreign(t, true, MSG_HELLO, true);
      return;
    } else if (mine) {
      addReply(MSG_HELLO, sendHello(t, nonceP_, NULL, reply_[0], sizeof(reply_[0])));
      addReply(MSG_JOIN, sendJoin(false, reply_[1], sizeof(reply_[1])));
      setState(ST_LINKED);
    } else if (theirs) {
      addReply(MSG_HELLO, sendHello(t, nonceP_, NULL, reply_[0], sizeof(reply_[0])));
      setState(ST_HELLO_X);
      arm(TM_AUTH, t, T_AUTH_MS);
    } else {
      addReply(MSG_HELLO, sendHello(t, nonceP_, NULL, reply_[0], sizeof(reply_[0])));
      setState(ST_NOGROUP);
    }
    hasReply_ = true;
  }

  void peripheralAuth(uint32_t t) {
    if (central() || state_ != ST_HELLO_X || !alike_) return;
    // Left the group after the HELLO exchange (group_changed already asked for a disconnect):
    // there is no key to check against, so the AUTH is dropped. (sync_ref.py leaves this case
    // undefined: it fails on the missing key.)
    if (!node_->group.grouped) return;
    uint8_t pp[16], pc[16];
    proofs(pp, pc);
    if (ctEqual(rx_.auth.proof, pc, 16)) {
      cancel(TM_AUTH);
      enterAuthed(t);
    } else {
      foreign(t, true, MSG_AUTH, true);
    }
  }

  void onJoin(uint32_t t) {
    const Join j = rx_.join;
    if (groupIdOf(j.groupKey) != j.groupId) {
      foreign(t, true, MSG_JOIN, true);
      return;
    }
    if (node_->group.grouped && node_->group.id == j.groupId) return;  // already in that group
    const bool rekey = (j.flagsValue() & JOIN_FLAG_REKEY) != 0;
    if (rekey) {
      if (!authed()) {
        foreign(t, true, MSG_JOIN, true);
        return;
      }
      setGroup(j);
      emitGroup(true);
      restart(t);
      return;
    }
    if (!node_->group.grouped && (state_ == ST_HELLO_X || state_ == ST_NOGROUP) && hasPeer_) {
      setGroup(j);
      emitGroup(false);
      restart(t);
      return;
    }
    foreign(t, true, MSG_JOIN, true);
  }

  void setGroup(const Join& j) {
    node_->group.grouped = true;
    node_->group.id = j.groupId;
    memcpy(node_->group.key, j.groupKey, 16);
  }

  void restart(uint32_t t) {
    resetSync();
    cancel(TM_AUTH);
    cancel(TM_HELLO);
    cancel(TM_BACKOFF);
    cancel(TM_RETRY);
    alike_ = false;
    hasReply_ = false;
    if (central()) {
      startHello(t);
    } else {
      hasNonceC_ = false;
      setState(ST_LINKED);
      if (cfg_->isHub && node_->group.grouped && !timers_[TM_DEADLINE].armed)
        arm(TM_DEADLINE, t, T_DEADLINE_MS);
    }
  }

  void resetSync() {
    cancel(TM_PAGE);
    cancel(TM_LIVE_PULL);
    cancel(TM_HB);
    cancel(TM_BACKOFF);
    pullActive_ = false;
    pendingHigh_ = -1;
  }

  void foreign(uint32_t t, bool hasRef, uint8_t ref, bool withErr) {
    (void)t;
    if (withErr) sendErr(E_AUTH, hasRef, ref, NULL, false, 0);
    cancelAll();
    setState(ST_FOREIGN);
    emitNode(NODE_FOREIGN);
    emitDisconnect(DISC_FOREIGN, false, 0);
  }

  void incompatible(uint32_t t, bool afterTimeouts) {
    const Timer deadline = timers_[TM_DEADLINE];
    cancelAll();
    timers_[TM_DEADLINE] = deadline;  // a grouped hub still drops non-members at 10 s
    setState(ST_INCOMPATIBLE);
    if (afterTimeouts && central()) arm(TM_RETRY, t, T_RETRY_INCOMPATIBLE_MS);
  }

  void enterAuthed(uint32_t t) {
    setState(ST_AUTHED);
    cancel(TM_AUTH);
    cancel(TM_DEADLINE);
    cancel(TM_HELLO);
    cancel(TM_BACKOFF);
    cancel(TM_RETRY);
    PeerState* ps = peerState();
    if (ps->dbId != peer_.dbId) {
      ps->dbId = peer_.dbId;
      ps->wm = 0;
      ps->excludeOk = false;
    }
    pullActive_ = false;
    pendingHigh_ = -1;
    if (peer_.capsValue() & CAP_FEED) {
      sendPull(t, false);
      setState(ST_SYNCING);
    } else {
      setState(ST_SYNCED);
    }
    if (peerSubs_ & SUB_HEARTBEATS) {
      emitNode(NODE_SEND_HB);
      arm(TM_HB, t, T_HB_MS);
    }
    if (cfg_->tracksEvents && (subsFor(cfg_->kind, peer_.kind) & SUB_EVENTS) &&
        ((peer_.capsValue() & CAP_EVENTS) || peer_.kind == KIND_HUB)) {
      emitNode(NODE_EVT_SINCE);
    }
  }

  void doGroupChanged(uint32_t t) {
    if (state_ == ST_IDLE || state_ == ST_CLOSED || state_ == ST_FOREIGN ||
        state_ == ST_INCOMPATIBLE)
      return;
    if (!node_->group.grouped) {
      disconnect(DISC_LEFT_GROUP, false, 0);
      return;
    }
    if (state_ == ST_NOGROUP) sendJoin(false);
    restart(t);
  }

  // ---- pulls ----------------------------------------------------------------------------------
  PeerState* peerState() {
    PeerState* p = node_->peer(peer_.deviceId);
    if (!p) {  // the node broke its contract; keep going on a scratch entry
      p = &scratchPeer_;
    }
    return p;
  }

  void sendPull(uint32_t t, bool retry) {
    reqId_ = (uint8_t)(reqId_ % 255 + 1);
    PeerState* ps = peerState();
    const uint8_t tries = (retry && pullActive_) ? (uint8_t)(pullTries_ + 1) : (uint8_t)1;
    Pull p;
    memset(&p, 0, sizeof(p));
    p.reqId = reqId_;
    p.since = ps->wm;
    p.hasLimit = true;
    p.limit = limit_;
    p.hasMaxBytes = true;
    p.maxBytes = maxBytes_;
    p.dbId = ps->dbId;
    p.hasExclude = true;
    p.exclude = 1;
    send(MSG_PULL, &p);
    pullActive_ = true;
    pullReqId_ = reqId_;
    pullSince_ = ps->wm;
    pullRecs_ = 0;
    pullTries_ = tries;
    arm(TM_PAGE, t, T_PAGE_MS);
  }

  void triggerPull(uint32_t t, bool hasFeedHigh, uint32_t feedHigh) {
    if (!(peer_.capsValue() & CAP_FEED)) return;
    if (pullActive_ || timers_[TM_BACKOFF].armed) {
      const int64_t h = hasFeedHigh ? (int64_t)feedHigh : (int64_t)0xFFFFFFFFu;
      if (h > pendingHigh_) pendingHigh_ = h;
      return;
    }
    sendPull(t, false);
  }

  void pageFailed(uint32_t t) {
    if (pullTries_ >= PAGE_TRIES) {
      pullActive_ = false;
      disconnect(DISC_PAGE_TIMEOUT, true, T_PAGE_FAIL_RETRY_MS);
      return;
    }
    sendPull(t, true);
  }

  // ---- data (AUTHED+) -------------------------------------------------------------------------
  void onData(uint32_t t, uint8_t mtype) {
    PeerState* ps = peerState();
    switch (mtype) {
      case MSG_PULL:
        if (rx_.pull.dbId != node_->dbId) {
          const Id8 own = node_->dbId;
          sendErr(E_DB_CHANGED, true, MSG_PULL, &own, false, 0);
          return;
        }
        deliver(MSG_PULL);
        return;
      case MSG_REC:
        deliver(MSG_REC);
        if (rx_.rec.reqId == 0) {
          arm(TM_LIVE_PULL, t, T_LIVE_PULL_MS);
        } else if (pullActive_ && rx_.rec.reqId == pullReqId_) {
          pullRecs_++;
          arm(TM_PAGE, t, T_PAGE_MS);
        }
        return;
      case MSG_PAGE_END: {
        const PageEnd& e = rx_.pageEnd;
        if (!pullActive_ || e.reqId != pullReqId_) return;  // stale
        cancel(TM_PAGE);
        if (e.count != pullRecs_) {
          pageFailed(t);
          return;
        }
        ps->wm = e.scannedTo > pullSince_ ? e.scannedTo : pullSince_;
        Action* a = out_.push(ACT_COMMIT);
        if (a) a->value = ps->wm;
        if (e.more) {
          sendPull(t, false);
          return;
        }
        pullActive_ = false;
        if (state_ == ST_SYNCING) setState(ST_SYNCED);
        if (pendingHigh_ > (int64_t)ps->wm) {
          pendingHigh_ = -1;
          sendPull(t, false);
        } else {
          pendingHigh_ = -1;
        }
        return;
      }
      case MSG_HB: {
        deliver(MSG_HB);
        const Hb& h = rx_.hb;
        if (h.hops == 0 && h.deviceId == peer_.deviceId) {  // direct
          if (h.dbId != ps->dbId) {
            ps->dbId = h.dbId;
            ps->wm = 0;
            ps->excludeOk = false;
            if (pullActive_) {
              pullActive_ = false;
              cancel(TM_PAGE);
            }
            triggerPull(t, true, h.feedHigh);
          } else if (h.feedHigh > ps->wm) {
            triggerPull(t, true, h.feedHigh);
          }
        }
        return;
      }
      case MSG_SUB:
        peerSubs_ = rx_.sub.subs;
        deliver(MSG_SUB);
        return;
      default:  // EVT, EVT_SINCE, EVT_GAP
        deliver(mtype);
        return;
    }
  }

  void onErr(uint32_t t) {
    deliver(MSG_ERR);
    const Err e = rx_.err;
    const uint16_t retry = e.retryMsValue();
    if (e.code == E_AUTH) {
      foreign(t, false, 0, false);
      return;
    }
    if (e.code == E_PROTO) {
      incompatible(t, false);
      return;
    }
    if (e.code == E_NOT_READY && central() && state_ == ST_LINKED && timers_[TM_HELLO].armed) {
      cancel(TM_HELLO);
      backoff_ = BO_HELLO;
      arm(TM_BACKOFF, t, retry);
      return;
    }
    if (!authed()) return;
    if ((e.code == E_NOT_READY || e.code == E_BUSY) && pullActive_ && e.hasRefType &&
        e.refType == MSG_PULL) {
      cancel(TM_PAGE);
      pullActive_ = false;
      backoff_ = BO_PULL;
      arm(TM_BACKOFF, t, retry);
      return;
    }
    if (e.code == E_TOO_BIG && pullActive_) {
      maxBytes_ = (uint16_t)(maxBytes_ / 2 > PULL_MAXBYTES_MIN ? maxBytes_ / 2 : PULL_MAXBYTES_MIN);
      sendPull(t, false);
      return;
    }
    if (e.code == E_DB_CHANGED && e.hasDbId) {
      PeerState* ps = peerState();
      ps->dbId = e.dbId;
      ps->wm = 0;
      ps->excludeOk = false;
      pullActive_ = false;
      cancel(TM_PAGE);
      if (peer_.capsValue() & CAP_FEED) sendPull(t, false);
    }
  }

  void onTimer(uint32_t t, uint8_t id) {
    switch (id) {
      case TM_HELLO:
        if (helloTries_ >= HELLO_TRIES) {
          incompatible(t, true);
          return;
        }
        helloTries_++;
        resendHello(t);
        return;
      case TM_RETRY:
        startHello(t);
        return;
      case TM_AUTH:
        disconnect(DISC_AUTH_TIMEOUT, false, 0);
        return;
      case TM_DEADLINE:
        disconnect(DISC_AUTH_DEADLINE, false, 0);
        return;
      case TM_PAGE:
        if (pullActive_) pageFailed(t);
        return;
      case TM_LIVE_PULL:
        if (pullActive_) {
          arm(TM_LIVE_PULL, t, T_LIVE_PULL_MS);
        } else {
          sendPull(t, false);
        }
        return;
      case TM_HB:
        emitNode(NODE_SEND_HB);
        arm(TM_HB, t, T_HB_MS);
        return;
      default: {  // TM_BACKOFF
        const uint8_t what = backoff_;
        backoff_ = BO_NONE;
        if (what == BO_HELLO) {
          helloTries_ = 1;
          resendHello(t);
        } else if (what == BO_PULL) {
          sendPull(t, false);
        }
        return;
      }
    }
  }

  const SessionConfig* cfg_;
  SessionNode* node_;
  uint8_t state_;
  Timer timers_[TM_COUNT];
  bool hasPeer_;
  Hello peer_;
  uint8_t peerSubs_;
  bool alike_;
  bool hasNonceC_;
  bool hasNonceP_;
  Id8 nonceC_;
  Id8 nonceP_;
  uint8_t helloTries_;
  // the peripheral's last reply (HELLO, and JOIN when it sent one), re-sent verbatim
  bool hasReply_;
  uint8_t replyCount_;
  uint8_t replyType_[2];
  uint16_t replyLen_[2];
  uint8_t reply_[2][160];
  uint8_t reqId_;
  bool pullActive_;
  uint8_t pullReqId_;
  uint32_t pullSince_;
  uint16_t pullRecs_;
  uint8_t pullTries_;
  int64_t pendingHigh_;  // -1 = no pending trigger
  uint8_t limit_;
  uint16_t maxBytes_;
  uint8_t backoff_;
  PeerState scratchPeer_;
  ActionList out_;
  Msg rx_;
};

}  // namespace mmsync
