// MagicMaker sync hub, phase P2 part 'db': the hub's library store (HubDbImpl : HubDb).
//
//   docs/SYNC_P2_FIRMWARE_PLAN.md §4 (exact on-flash format §4.2, NVS §4.3, index §4.4, accept and
//   durability §4.5, boot and recovery §4.6, flush and compaction §4.7, capacity §4.8, peers §4.9,
//   contract §4.10); SYNC_HUB_SPEC.md §4.3-§4.8 with amendment A1; SYNC_PROTOCOL.md §15.
//
// Pure C++11 (gnu++11, -fno-rtti, no exceptions, no heap): every buffer comes from HubDbConfig or
// is a member of the (static) HubDbImpl; no function-local buffer is over 512 B. No Arduino header:
// storage and NVS are reached through the Storage / KvStore ports (hub_ports.h), whose target
// back-ends are storage_posix.h + storage_littlefs.h and kv_nvs.h.
//
// What lives where:
//   lib.log  HEADER{dbId, formatEpochS}, then RECORDs in strictly ascending seq (after a compaction
//            also one END, then later appends). Only the valid, synced prefix [0, logBytes) is ever
//            read. Entries above durableHigh live in the dirty queue (RAM) until the next flush.
//   lib.new  compaction output; promoted over lib.log by one rename.
//   NVS      db, grp, peers, full, live (namespace "mmsync").
//
// RAM index (plan §4.4, decision D-P2-2): a sorted array of {hashLo, hashHi, ref} triples in
// cfg.indexMem plus 32 unsorted pending inserts. ref = seq (bits 0..29) | PRESENCE << 30 |
// DELETED << 31; ref 0 marks a dead slot (an evicted key; the merge drops it). The top 9 bits of
// hashHi hold the entry's body length, so liveBytes stays exact without reading flash: the index
// compares the low 55 bits of the FNV-1a 64 key hash, and the collision guard (the stored key is
// compared on every match) turns a 55-bit match of two different keys into DBR_COLLISION.
//
// Gates (hub_ports.h): flash erase / program (append, sync, rename, remove, every NVS write) only
// while hubFlashWorkAllowed(); index merges and the boot scan only while hubLightWorkAllowed();
// flush(now, true) is the one ungated path (power-off, restart, OTA reboot).
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "hub_ports.h"
#include "sync_codec.h"
#include "sync_crypto.h"
#include "sync_session.h"

namespace mmsync {

// =================================================================================================
// Log entry codec (plan §4.2)
// =================================================================================================

struct HubLogHead {
  uint8_t type;
  uint16_t len;
  uint32_t seq;
  Id8 syncFrom;
};

inline bool hubLogLenOk(uint8_t type, uint32_t len) {
  switch (type) {
    case HUB_LOG_RECORD: return len >= 1 && len <= HUB_LOG_MAX_PAYLOAD;
    case HUB_LOG_HEADER: return len >= HUB_LOG_HEADER_PAYLOAD && len <= HUB_LOG_MAX_PAYLOAD;
    case HUB_LOG_END: return len == HUB_LOG_END_PAYLOAD;
    default: return false;
  }
}

// The 16-byte head: magic, known type, len in range, seq rule. No CRC.
inline bool hubLogParseHead(const uint8_t* p, size_t avail, HubLogHead* h) {
  if (avail < HUB_LOG_HEAD_BYTES || p[0] != HUB_LOG_MAGIC) return false;
  h->type = p[1];
  h->len = (uint16_t)getLE(p + 2, 2);
  h->seq = (uint32_t)getLE(p + 4, 4);
  h->syncFrom = makeId8(p + 8);
  if (!hubLogLenOk(h->type, h->len)) return false;
  if (h->type == HUB_LOG_RECORD) return h->seq >= 1 && h->seq <= HUB_SEQ_MAX;
  return h->seq == 0;
}

// The key of a stored body: its first TLV is 0x10 with 4..30 bytes that decode as a key.
inline bool hubBodyKey(const uint8_t* body, size_t n, Key* out) {
  if (n < 2 || body[0] != T_KEY) return false;
  const uint8_t ln = body[1];
  if (ln < 1 + PACKET_MIN || ln > 1 + PACKET_MAX || (size_t)ln + 2 > n) return false;
  return decodeKey(body + 2, ln, out).ok();
}

// A whole entry at p (avail bytes readable): the entry size when valid (head, bounds, CRC and, for
// a RECORD, the key TLV), else 0.
inline uint32_t hubLogCheck(const uint8_t* p, size_t avail, HubLogHead* h) {
  if (!hubLogParseHead(p, avail, h)) return 0;
  const uint32_t size = HUB_LOG_OVERHEAD + (uint32_t)h->len;
  if (avail < size) return 0;
  const uint32_t crc = (uint32_t)getLE(p + HUB_LOG_HEAD_BYTES + h->len, 4);
  if (crc32(p + 1, HUB_LOG_HEAD_BYTES - 1 + (size_t)h->len) != crc) return 0;
  if (h->type == HUB_LOG_RECORD) {
    Key k;
    if (!hubBodyKey(p + HUB_LOG_HEAD_BYTES, h->len, &k)) return 0;
  }
  return size;
}

// Encodes one entry into out; returns its size (20 + len), 0 when it does not fit.
inline size_t hubLogEncode(uint8_t* out, size_t cap, uint8_t type, uint32_t seq, const Id8& syncFrom,
                           const uint8_t* payload, uint16_t len) {
  const size_t n = HUB_LOG_OVERHEAD + (size_t)len;
  if (n > cap) return 0;
  out[0] = HUB_LOG_MAGIC;
  out[1] = type;
  putLE(out + 2, len, 2);
  putLE(out + 4, seq, 4);
  memcpy(out + 8, syncFrom.b, 8);
  if (len) memcpy(out + HUB_LOG_HEAD_BYTES, payload, len);
  putLE(out + HUB_LOG_HEAD_BYTES + len, crc32(out + 1, HUB_LOG_HEAD_BYTES - 1 + (size_t)len), 4);
  return n;
}

inline size_t hubLogEncodeHeader(uint8_t* out, size_t cap, const Id8& dbId, uint32_t formatEpochS) {
  uint8_t pl[HUB_LOG_HEADER_PAYLOAD];
  memcpy(pl, dbId.b, 8);
  putLE(pl + 8, formatEpochS, 4);
  return hubLogEncode(out, cap, HUB_LOG_HEADER, 0, zeroId8(), pl, HUB_LOG_HEADER_PAYLOAD);
}

inline size_t hubLogEncodeEnd(uint8_t* out, size_t cap, uint32_t count, uint32_t maxSeq) {
  uint8_t pl[HUB_LOG_END_PAYLOAD];
  putLE(pl, count, 4);
  putLE(pl + 4, maxSeq, 4);
  return hubLogEncode(out, cap, HUB_LOG_END, 0, zeroId8(), pl, HUB_LOG_END_PAYLOAD);
}

// What the store needs of a (validated) body without a full decode: key, version inputs, class.
struct HubBodyPeek {
  Key key;
  int64_t updatedAt;
  bool hasOrigin;
  Id8 origin;
  uint8_t flags;
  uint8_t cls;  // RecordClass, as bodyShape() (sync_codec.h) gives it
};

inline bool hubPeekBody(const uint8_t* p, size_t n, HubBodyPeek* out) {
  memset(out, 0, sizeof(*out));
  bool hasKey = false, other = false;
  for (size_t i = 0; i < n;) {
    if (i + 2 > n) return false;
    const uint8_t tag = p[i];
    const uint8_t ln = p[i + 1];
    if (i + 2 + (size_t)ln > n) return false;
    const uint8_t* v = p + i + 2;
    switch (tag) {
      case T_KEY:
        if (!decodeKey(v, ln, &out->key).ok()) return false;
        hasKey = true;
        break;
      case T_UPDATED:
        if (ln != 8) return false;
        out->updatedAt = getLEs(v, 8);
        break;
      case T_ORIGIN:
        if (ln != 8) return false;
        out->origin = makeId8(v);
        out->hasOrigin = true;
        break;
      case T_FLAGS:
        if (ln != 1) return false;
        out->flags = v[0];
        break;
      default:
        other = true;  // label, category, note, kind, place
        break;
    }
    i += 2 + (size_t)ln;
  }
  if (!hasKey) return false;
  if (out->key.ns == NS_NEWWAND) out->cls = CLS_NEWWAND;
  else if (out->flags & FLAG_DELETED) out->cls = CLS_TOMBSTONE;
  else if (out->flags & (FLAG_USER_EDITED | FLAG_PRESET)) out->cls = CLS_USER;
  else if (!out->hasOrigin && !other) out->cls = CLS_PRESENCE;
  else out->cls = CLS_RESET;
  return true;
}

inline Version hubPeekVersion(const HubBodyPeek& pk, const uint8_t* body, size_t n) {
  Version v;
  v.updatedAt = pk.updatedAt;
  v.origin = pk.hasOrigin ? beU64(pk.origin) : 0;
  v.crc = crc32(body, n);
  return v;
}

// =================================================================================================
// NVS value codecs (plan §4.3)
// =================================================================================================

struct HubPeerRecord {
  Id8 id;
  Id8 dbId;
  uint32_t wm;
  bool excludeOk;
  uint8_t kind;
  uint32_t lastSyncEpochS;
};

static const size_t HUB_PEER_BLOB_MAX = 1 + (size_t)HUB_PEERS_MAX * HUB_PEER_BLOB_ENTRY;
static const size_t HUB_GROUP_BLOB = 24;

// [version 1] + n x {deviceId 8, dbId 8, wm u32, excludeOk u8, kind u8, lastSyncEpochS u32}.
inline size_t hubPeersBlobEncode(const HubPeerRecord* p, uint8_t n, uint8_t* out) {
  if (n > HUB_PEERS_MAX) n = HUB_PEERS_MAX;
  out[0] = HUB_PEER_BLOB_VERSION;
  uint8_t* q = out + 1;
  for (uint8_t i = 0; i < n; i++, q += HUB_PEER_BLOB_ENTRY) {
    memcpy(q, p[i].id.b, 8);
    memcpy(q + 8, p[i].dbId.b, 8);
    putLE(q + 16, p[i].wm, 4);
    q[20] = p[i].excludeOk ? 1 : 0;
    q[21] = p[i].kind;
    putLE(q + 22, p[i].lastSyncEpochS, 4);
  }
  return 1 + (size_t)n * HUB_PEER_BLOB_ENTRY;
}

// The number of peers decoded, -1 when the blob is not a version-1 peers blob.
inline int hubPeersBlobDecode(const uint8_t* b, size_t len, HubPeerRecord* out, uint8_t max) {
  if (len < 1 || b[0] != HUB_PEER_BLOB_VERSION || (len - 1) % HUB_PEER_BLOB_ENTRY != 0) return -1;
  size_t n = (len - 1) / HUB_PEER_BLOB_ENTRY;
  if (n > max) n = max;
  const uint8_t* q = b + 1;
  for (size_t i = 0; i < n; i++, q += HUB_PEER_BLOB_ENTRY) {
    out[i].id = makeId8(q);
    out[i].dbId = makeId8(q + 8);
    out[i].wm = (uint32_t)getLE(q + 16, 4);
    out[i].excludeOk = q[20] != 0;
    out[i].kind = q[21];
    out[i].lastSyncEpochS = (uint32_t)getLE(q + 22, 4);
  }
  return (int)n;
}

inline void hubGroupBlobEncode(const GroupState& g, uint8_t out[HUB_GROUP_BLOB]) {
  memcpy(out, g.id.b, 8);
  memcpy(out + 8, g.key, 16);
}

// =================================================================================================
// HubDbImpl
// =================================================================================================

// Internal constants (namespace scope: defined once, safe to bind in gnu++11).
static const uint32_t HUBDB_REF_SEQ = 0x3FFFFFFFu;    // index ref: seq bits
static const uint32_t HUBDB_REF_P = 0x40000000u;      // ... PRESENCE
static const uint32_t HUBDB_REF_D = 0x80000000u;      // ... DELETED
static const uint32_t HUBDB_HI_MASK = 0x007FFFFFu;    // 23 hash bits of hashHi
static const uint32_t HUBDB_LEN_SHIFT = 23;           // the body length in hashHi's top 9 bits
static const uint32_t HUBDB_NO_OFF = 0xFFFFFFFFu;
static const uint32_t HUBDB_FEED_MAGIC = 0x4D4D4644u;
static const uint32_t HUBDB_WIN_SMALL = 512;          // locate / compaction read window
static const uint32_t HUBDB_WIN_FEED = 4096;          // sequential reads (feed, boot scan)
static const uint32_t HUBDB_CK_K0 = 32;               // checkpoint stride at start
static const uint32_t HUBDB_NVS_RETRY_MS = 1000;      // after a failed NVS write
static const uint8_t HUBDB_MAX_HOLES = 4;             // bad regions skipped until the rewrite
static const uint8_t HUBDB_MAX_EVICT = 4;             // evictions per accepted record

class HubDbImpl : public HubDb {
 public:
  HubDbImpl() { clearAll(); }

  // ---- lifecycle ---------------------------------------------------------------------------
  void begin(const HubDbConfig& cfg, uint32_t now) override {
    clearAll();
    cfg_ = cfg;
    st_ = cfg.storage;
    kv_ = cfg.kv;
    gate_ = cfg.gate;
    rng_ = cfg.rng;
    beginMs_ = now;
    cap_ = cfg.indexBytes / HUB_INDEX_ENTRY_BYTES;
    ckSlots_ = cfg.ckptBytes / 16;  // two tables of {seq u32, off u32}
    if (!st_ || !kv_ || !gate_ || !rng_ || !cfg.indexMem || !cfg.dirtyMem || !cfg.ckptMem ||
        !cfg.ioMem || cap_ < 1 || cfg.dirtyBytes < 512 || cfg.ioBytes < 1024 || ckSlots_ < 2) {
      state_ = DB_FAILED;
      return;
    }
    idx_ = cfg.indexMem;
    ck_[0] = cfg.ckptMem;
    ck_[1] = cfg.ckptMem + 2u * ckSlots_;
    dirty_ = cfg.dirtyMem;
    dirtyCap_ = cfg.dirtyBytes;
    io_ = cfg.ioMem;
    ioCap_ = cfg.ioBytes;
    outCap_ = ioCap_ - HUBDB_WIN_SMALL;
    if (outCap_ > HUB_COMPACT_STEP_BYTES) outCap_ = HUB_COMPACT_STEP_BYTES;
    useWindow(io_, ioCap_);
    if (!st_->mounted()) {
      state_ = DB_FAILED;
      bootFlags_ |= DB_BOOT_FORMAT_FAILED;
      return;
    }
    fsTotal_ = cfg.fsTotalBytes;
    if (!fsTotal_) {
      uint32_t t = 0, u = 0;
      if (st_->usage(&t, &u)) fsTotal_ = t;
    }
    if (cfg.liveMaxBytes) liveMax_ = cfg.liveMaxBytes;
    else liveMax_ = fsTotal_ ? hubLiveMaxBytes(fsTotal_) : 0xFFFFFFFFu;
    loadNvs();
    state_ = DB_BUILDING;
    phase_ = BP_RESOLVE;
    // Which files are there decides whether resolving needs a flash write (nothing is changed
    // before the flash gate allows it).
    logExists_ = st_->exists(HUB_FILE_LOG);
    newExists_ = st_->exists(HUB_FILE_NEW);
    logSize0_ = 0;
    if (logExists_) {
      if (!st_->open(HUB_FILE_LOG, false)) {
        state_ = DB_FAILED;
        return;
      }
      const int32_t s = st_->size(HUB_FILE_LOG);
      if (s < 0) {
        state_ = DB_FAILED;
        return;
      }
      logSize0_ = (uint32_t)s;
    }
    resolveNeedsFlash_ = newExists_ || !logExists_ || logSize0_ == 0;
    if (!resolveNeedsFlash_ || flashOk(now)) resolve(now);
  }

  uint8_t state() const override { return state_; }
  bool ready() const override { return state_ == DB_READY; }

  bool maintain(uint32_t now) override { return step(now, true); }
  bool maintenanceDue(uint32_t now) override { return step(now, false); }

  // ---- identity ------------------------------------------------------------------------------
  Id8 dbId() const override { return dbId_; }
  uint32_t durableHigh() const override { return durableHigh_; }
  uint32_t lastSeq() const override { return lastSeq_; }

  // ---- records -------------------------------------------------------------------------------
  DbAccept accept(const uint8_t* body, size_t len, const Id8& syncFrom, bool nowKnown, int64_t nowMs,
                  bool live, uint32_t now) override {
    DbAccept r;
    memset(&r, 0, sizeof(r));
    if (state_ != DB_READY) {
      r.result = DBR_NOT_READY;
      r.hasKey = body && len && bodyErrKey(body, len, &r.key);
      return r;
    }
    if (!body || len == 0) {
      r.result = DBR_BAD_MSG;
      return r;
    }
    Version ver;
    Status err;
    const ApplyStatus a = applyCheck(body, len, nowKnown, nowMs, NULL, NULL, &ver, &err);
    if (a == APPLY_BAD_MSG || a == APPLY_CLOCK) {
      r.result = a == APPLY_CLOCK ? DBR_CLOCK : DBR_BAD_MSG;
      r.hasKey = bodyErrKey(body, len, &r.key);
      return r;
    }
    HubBodyPeek pk;
    if (!hubPeekBody(body, len, &pk)) {  // cannot happen for a body applyCheck accepted
      r.result = DBR_BAD_MSG;
      return r;
    }
    r.hasKey = true;
    r.key = pk.key;
    if (nowKnown && nowMs > 0) lastWallS_ = (uint32_t)(nowMs / 1000);
    uint32_t lo, hi;
    hashParts(pk.key, &lo, &hi);
    uint32_t* e = find(lo, hi);
    const bool exists = e && e[2] != 0;
    if (exists) {
      HubLogHead oh;
      const uint8_t* ob = readEntry(e[2] & HUBDB_REF_SEQ, &oh);
      HubBodyPeek opk;
      if (ob && hubPeekBody(ob, oh.len, &opk)) {
        if (opk.key != pk.key) {
          collisions_++;
          r.result = DBR_COLLISION;
          return r;
        }
        const int c = compareVersions(ver, hubPeekVersion(opk, ob, oh.len));
        if (c == 0) {
          r.result = DBR_DUPLICATE;
          return r;
        }
        if (c < 0) {
          r.result = DBR_STALE;
          return r;
        }
      }
      // An unreadable stored entry (runtime corruption, already reported) is simply replaced.
    }
    const uint32_t esz = HUB_LOG_OVERHEAD + (uint32_t)len;
    if (lastSeq_ >= HUB_SEQ_MAX || dirtyLen_ + esz > dirtyCap_) return busy(&r, live);
    const uint32_t seq = lastSeq_ + 1;
    const uint32_t ref = seq | (pk.cls == CLS_PRESENCE ? HUBDB_REF_P : 0) |
                         ((pk.flags & FLAG_DELETED) ? HUBDB_REF_D : 0);
    if (!exists) {
      // A new key: an index slot (a dead slot of the same hash, a pending slot, or a merge now).
      if (!e && pendN_ >= HUB_PENDING_INSERTS && !hubLightWorkAllowed(*gate_)) return busy(&r, live);
      if (fsFree() < HUB_FS_REFUSE_FREE) {
        compactWanted_ = true;  // refuse new keys and compact (spec §4.8)
        return fullResult(&r);
      }
      if (records_ >= cap_ || liveBytes_ + esz > liveMax_) {
        if (pk.cls == CLS_PRESENCE || !evictFor(esz)) return fullResult(&r);
        r.evicted = true;
      }
      if (!e && pendN_ >= HUB_PENDING_INSERTS) mergePending();
    }
    const size_t n = hubLogEncode(dirty_ + dirtyLen_, dirtyCap_ - dirtyLen_, HUB_LOG_RECORD, seq,
                                  syncFrom, body, (uint16_t)len);
    if (n == 0) return busy(&r, live);
    if (dirtyLen_ == 0) dirtySince_ = now;
    dirtyLen_ += (uint32_t)n;
    lastSeq_ = seq;
    if (exists) {
      countRemove(e[2], entLen(e));
      setEnt(e, lo, hi, ref, (uint32_t)len);
      countAdd(ref, (uint32_t)len);
    } else {
      insertNew(e, lo, hi, ref, (uint32_t)len);
    }
    r.result = DBR_ACCEPT;
    r.seq = seq;
    return r;
  }

  bool lookup(const Key& key, DbEntry* out) override {
    if (state_ != DB_READY) return false;
    uint32_t lo, hi;
    hashParts(key, &lo, &hi);
    const uint32_t* e = find(lo, hi);
    if (!e || e[2] == 0) return false;
    HubLogHead h;
    const uint8_t* b = readEntry(e[2] & HUBDB_REF_SEQ, &h);
    if (!b) return false;
    Key k;
    if (!hubBodyKey(b, h.len, &k) || k != key) return false;
    return fillEntry(out, h, b);
  }

  bool canTakePage(uint16_t maxBytes, uint32_t now) override {
    (void)now;
    if (state_ != DB_READY || !hubLightWorkAllowed(*gate_)) return false;
    const uint32_t need = (maxBytes > 330 ? (uint32_t)maxBytes : 330u) + 10u * 32u;
    if (dirtyCap_ - dirtyLen_ < need) return false;
    if (pendN_ != 0) return false;  // room for PULL_LIMIT max (32) new keys
    if (cPhase_ == C_FINISH || cPhase_ == C_SWAP) return false;  // a compaction swap is waiting
    return true;
  }

  bool reserveLive(uint32_t seq, uint32_t now) override {
    if (seq <= durableHigh_ || seq <= nvsLive_) return true;
    if (state_ != DB_READY || !flashOk(now)) {
      liveSkipped_++;
      return false;
    }
    // A pending identity change (new dbId) goes first, so the NVS order stays peers -> db -> live.
    if ((nvsDbDirty_ || peersForce_) && !writeIdentity(now)) {
      liveSkipped_++;
      return false;
    }
    if (!kv_->setU32(HUB_NVS_LIVE, seq)) {
      liveSkipped_++;
      return false;
    }
    nvsLive_ = seq;
    nvsLive0Dirty_ = false;
    return true;
  }

  void notePageTraffic(uint32_t now) override {
    lastTraffic_ = now;
    hadTraffic_ = true;
  }

  // ---- durability ----------------------------------------------------------------------------
  uint32_t dirtyBytes() const override { return dirtyLen_; }

  uint8_t flush(uint32_t now, bool force) override {
    if (state_ != DB_READY) return DB_FLUSH_NONE;
    if (!force) {
      if (dirtyLen_ == 0) return DB_FLUSH_NONE;
      if (cPhase_ != C_IDLE) return DB_FLUSH_DEFERRED;  // compaction holds flushes
      if (appendHold_) return compactBackoff_ ? DB_FLUSH_ERROR : DB_FLUSH_DEFERRED;
      if (!flashOk(now)) return DB_FLUSH_DEFERRED;
      return doFlush(now);
    }
    uint8_t r = DB_FLUSH_NONE;
    if (dirtyLen_ > 0) {
      if (appendHold_) {
        // The file ends in a torn tail: appending now would turn it into mid-log corruption.
        r = DB_FLUSH_DEFERRED;
      } else {
        if (cPhase_ != C_IDLE) abortCompaction();
        r = doFlush(now);
      }
    }
    writeNvs(now, true);
    return r;
  }

  // ---- feed ----------------------------------------------------------------------------------
  void feedBegin(FeedCursor* c, uint32_t since, uint32_t limit) override {
    c->w[0] = since;  // the last seq scanned
    c->w[1] = limit;
    c->w[2] = gen_;
    c->w[3] = HUBDB_NO_OFF;  // lib.log offset hint (an entry boundary at or before the next entry)
    c->w[4] = HUBDB_FEED_MAGIC;
    c->w[5] = 0;
  }

  uint8_t feedNext(FeedCursor* c, FeedBudget* budget, DbEntry* out) override {
    if (state_ != DB_READY) return DB_FEED_NOT_READY;
    if (!c || c->w[4] != HUBDB_FEED_MAGIC) return DB_FEED_END;
    useWindow(io_, ioCap_);
    for (;;) {
      const uint32_t last = c->w[0], limit = c->w[1];
      if (last >= limit || last >= lastSeq_) return DB_FEED_END;
      if (budget->entries == 0 || budget->bytes == 0) return DB_FEED_YIELD;
      if (last >= durableHigh_) {
        // The dirty queue: the first entry above last.
        uint32_t off = 0;
        HubLogHead h;
        while (off < dirtyLen_) {
          hubLogParseHead(dirty_ + off, dirtyLen_ - off, &h);
          if (h.seq > last) break;
          off += HUB_LOG_OVERHEAD + h.len;
        }
        if (off >= dirtyLen_) {
          c->w[0] = lastSeq_;
          continue;
        }
        if (h.seq > limit) {
          c->w[0] = limit;
          return DB_FEED_END;
        }
        charge(budget, HUB_LOG_OVERHEAD + h.len);
        c->w[0] = h.seq;
        const uint8_t* b = dirty_ + off + HUB_LOG_HEAD_BYTES;
        if (isCurrent(h.seq, b, h.len) && fillEntry(out, h, b)) return DB_FEED_ENTRY;
        continue;
      }
      // lib.log: walk from the hint (or a checkpoint) to the first RECORD above last.
      uint32_t off;
      if (c->w[2] != gen_ || c->w[3] == HUBDB_NO_OFF) {
        off = ckStart(ckCur_, last + 1);
        c->w[2] = gen_;
      } else {
        off = c->w[3];
      }
      HubLogHead h;
      const uint8_t* p = NULL;
      for (;;) {
        off = skipHoles(off);
        if (off >= logBytes_) break;
        p = winGet(off, HUB_LOG_HEAD_BYTES, HUBDB_WIN_FEED, logBytes_);
        if (!p || !hubLogParseHead(p, HUB_LOG_HEAD_BYTES, &h)) {
          p = NULL;
          runtimeCorruption();
          off = logBytes_;
          break;
        }
        if (h.type == HUB_LOG_RECORD && h.seq > last) break;
        off += HUB_LOG_OVERHEAD + h.len;
        p = NULL;
      }
      if (!p) {  // every durable entry above last was scanned
        c->w[3] = off;
        c->w[0] = durableHigh_ < limit ? durableHigh_ : limit;
        continue;
      }
      if (h.seq > limit) {
        c->w[0] = limit;
        c->w[3] = off;
        return DB_FEED_END;
      }
      const uint32_t size = HUB_LOG_OVERHEAD + h.len;
      p = winGet(off, size, HUBDB_WIN_FEED, logBytes_);
      HubLogHead fh;
      charge(budget, size);
      c->w[0] = h.seq;
      c->w[3] = off + size;
      if (!p || hubLogCheck(p, size, &fh) != size) {
        runtimeCorruption();
        continue;
      }
      const uint8_t* b = p + HUB_LOG_HEAD_BYTES;
      if (isCurrent(h.seq, b, h.len) && fillEntry(out, h, b)) return DB_FEED_ENTRY;
    }
  }

  // ---- peers ---------------------------------------------------------------------------------
  PeerState* peerFind(const Id8& id) override {
    Peer* p = findPeerSlot(id);
    return p ? &p->st : NULL;
  }

  PeerState* peerGet(const Id8& id, uint8_t kind) override {
    Peer* p = findPeerSlot(id);
    if (!p) {
      p = &peers_[0];
      for (uint8_t i = 0; i < HUB_PEERS_MAX; i++) {
        if (!peers_[i].used) {
          p = &peers_[i];
          break;
        }
        if (peers_[i].use < p->use) p = &peers_[i];
      }
      clearPeer(p);
      p->used = true;
      p->id = id;
      p->use = ++peerClock_;
    }
    if (kind) p->kind = kind;
    return &p->st;
  }

  void peerCommitted(const Id8& id, uint32_t wallS, uint32_t now) override {
    (void)now;
    Peer* p = findPeerSlot(id);
    if (!p) return;
    p->pendWm = p->st.wm;
    p->pendDbId = p->st.dbId;
    p->needSeq = lastSeq_;
    p->pendCommit = true;
    if (wallS) p->lastSyncS = wallS;
    peerCheckSafe(p);
  }

  void peerSessionEnd(const Id8& id, uint32_t now) override {
    (void)now;
    Peer* p = findPeerSlot(id);
    if (!p) return;
    p->ended = true;
    p->due = true;
    peerCheckSafe(p);
  }

  void zeroAllWm(uint32_t now) override {
    (void)now;
    for (uint8_t i = 0; i < HUB_PEERS_MAX; i++) {
      Peer& p = peers_[i];
      if (!p.used) continue;
      p.st.wm = 0;
      p.safeWm = 0;
      p.pendWm = 0;
      p.due = true;
    }
    peersForce_ = true;
  }

  uint8_t peerCount() const override {
    uint8_t n = 0;
    for (uint8_t i = 0; i < HUB_PEERS_MAX; i++)
      if (peers_[i].used) n++;
    return n;
  }

  bool peerAt(uint8_t i, DbPeer* out) const override {
    for (uint8_t k = 0; k < HUB_PEERS_MAX; k++) {
      if (!peers_[k].used) continue;
      if (i-- == 0) {
        out->id = peers_[k].id;
        out->st = peers_[k].st;
        out->kind = peers_[k].kind;
        out->lastSyncEpochS = peers_[k].lastSyncS;
        return true;
      }
    }
    return false;
  }

  // ---- group ---------------------------------------------------------------------------------
  const GroupState& group() const override { return group_; }
  void setGroup(const GroupState& g, uint32_t now) override {
    (void)now;
    group_ = g;
    if (!group_.grouped) {
      group_.id = zeroId8();
      memset(group_.key, 0, sizeof(group_.key));
    }
    nvsGrpDirty_ = true;
  }

  // ---- capacity ------------------------------------------------------------------------------
  bool full() const override { return full_; }
  bool takeRepullNeeded() override {
    if (state_ != DB_READY || !repullNeeded_) return false;
    repullNeeded_ = false;
    return true;
  }

  // ---- sync_reset ----------------------------------------------------------------------------
  void requestReset(const Id8& newDbId, uint32_t now) override {
    (void)now;
    if (state_ == DB_OFF || state_ == DB_FAILED) return;
    resetId_ = newDbId;
    state_ = DB_RESETTING;
    dirtyLen_ = 0;  // the records are wiped anyway
    dirtyAppended_ = 0;
    resetRetryAt_ = now;
  }

  // ---- status --------------------------------------------------------------------------------
  void stats(DbStats* o) const override {
    memset(o, 0, sizeof(*o));
    o->state = state_;
    o->records = records_;
    o->cap = cap_;
    o->tombstones = tombstones_;
    o->presences = presences_;
    o->liveBytes = liveBytes_;
    o->liveMaxBytes = liveMax_;
    o->logBytes = logBytes_;
    o->fsTotalBytes = fsTotal_;
    o->fsUsedBytes = fsUsedEst();
    o->lastSeq = lastSeq_;
    o->durableHigh = durableHigh_;
    o->dirtyBytes = dirtyLen_;
    o->dirtyCap = dirtyCap_;
    o->pendingInserts = pendN_;
    o->full = full_;
    o->repull = repull_;
    o->compacting = cPhase_ != C_IDLE;
    o->bootFlags = bootFlags_;
    o->buildMs = buildMs_;
    o->flushes = flushes_;
    o->flushErrors = flushErrors_;
    o->compactions = compactions_;
    o->evictions = evictions_;
    o->collisions = collisions_;
    o->liveSkipped = liveSkipped_;
  }

  // ---- diagnostics / tests (not part of HubDb) -----------------------------------------------
  // Compact at the next allowed moment, without waiting for page quiet (like a recovery need).
  void requestCompaction() { compactWanted_ = true; }
  // 0 idle, 1 copying, 2 END + sync pending, 3 swap pending.
  uint8_t compactPhase() const { return cPhase_; }
  // Appends are held until a compaction rewrites a torn / corrupt lib.log.
  bool appendHeld() const { return appendHold_; }
  // The offset just past the HEADER and the valid lib.log length (tests).
  uint32_t logValidBytes() const { return logBytes_; }

 private:
  enum BuildPhase : uint8_t { BP_RESOLVE = 0, BP_SCAN = 1 };
  enum CompactPhase : uint8_t { C_IDLE = 0, C_COPY = 1, C_FINISH = 2, C_SWAP = 3 };

  struct Peer {
    bool used;
    Id8 id;
    PeerState st;
    uint8_t kind;
    uint32_t lastSyncS;
    uint32_t safeWm;
    Id8 safeDbId;
    uint32_t pendWm;
    Id8 pendDbId;
    uint32_t needSeq;
    bool pendCommit;
    bool due;
    bool written;
    bool ended;
    uint32_t lastWriteMs;
    uint32_t use;
  };

  struct Hole {
    uint32_t start, end;
  };

  // ---- state -------------------------------------------------------------------------------
  HubDbConfig cfg_;
  Storage* st_;
  KvStore* kv_;
  TxGate* gate_;
  Rng* rng_;
  uint8_t state_;
  uint8_t phase_;
  uint16_t bootFlags_;
  uint32_t beginMs_, buildMs_;

  // index
  uint32_t* idx_;
  uint32_t cap_, sortedN_, deadN_;
  uint32_t pend_[3 * HUB_PENDING_INSERTS];
  uint8_t pendN_;
  uint32_t records_, presences_, tombstones_, liveBytes_;

  // seqs and lib.log
  uint32_t lastSeq_, durableHigh_;
  uint32_t logBytes_, firstOff_, recsInFile_;
  Id8 dbId_, headerDbId_;
  uint32_t formatEpochS_, lastWallS_;
  bool appendHold_, runtimeCorrupt_;
  Hole holes_[HUBDB_MAX_HOLES];
  uint8_t nHoles_;
  uint32_t gen_;

  // checkpoints: table t holds ckN_[t] pairs {seq, off} at ck_[t], one every ckK_[t] records
  uint32_t* ck_[2];
  uint32_t ckSlots_;
  uint32_t ckN_[2], ckK_[2];
  uint8_t ckCur_;

  // dirty queue
  uint8_t* dirty_;
  uint32_t dirtyCap_, dirtyLen_, dirtyAppended_, dirtySince_;
  uint8_t flushFails_;

  // io scratch and the read window over lib.log
  uint8_t* io_;
  uint32_t ioCap_, outCap_;
  uint8_t* winBuf_;
  uint32_t winCap_, winOff_, winLen_;
  bool winValid_;

  // capacity
  uint32_t fsTotal_, fsBase_, liveMax_;
  bool full_, repull_, repullNeeded_;

  // NVS
  bool nvsHaveDb_;
  Id8 nvsDb_;
  uint32_t nvsLive_;
  bool nvsDbDirty_, nvsLive0Dirty_, nvsGrpDirty_, nvsFlagsDirty_, peersForce_;
  uint32_t nvsFlags_;
  GroupState grpStored_;
  bool peersBlobKnown_;
  size_t peersBlobLen_;
  uint32_t peersBlobCrc_;
  bool nvsBackoff_;
  uint32_t nvsRetryAt_;

  GroupState group_;
  Peer peers_[HUB_PEERS_MAX];
  uint32_t peerClock_;

  // boot: resolve + scan
  bool logExists_, newExists_, resolveNeedsFlash_, promoted_, headerOk_;
  uint32_t logSize0_;
  uint32_t scanOff_, scanSize_, scanMax_, scanBad_, searchPos_;
  bool scanSearching_, scanCorrupt_, scanTorn_;
  uint8_t lastType_;
  uint32_t endCount_, endMax_;

  // compaction
  uint8_t cPhase_;
  uint32_t cRd_, cEnd_, cNewBytes_, cRecs_, cMax_;
  Id8 cHeaderId_;
  bool recoveryCompact_, compactWanted_, compactBackoff_, newStale_;
  uint32_t compactRetryAt_;
  uint32_t lastTraffic_;
  bool hadTraffic_;

  // reset
  Id8 resetId_;
  uint32_t resetRetryAt_;

  // counters
  uint32_t flushes_, flushErrors_, compactions_, evictions_, collisions_, liveSkipped_;

  // ---- reset of every member ---------------------------------------------------------------
  void clearAll() {
    memset(&cfg_, 0, sizeof(cfg_));
    st_ = NULL;
    kv_ = NULL;
    gate_ = NULL;
    rng_ = NULL;
    state_ = DB_OFF;
    phase_ = BP_RESOLVE;
    bootFlags_ = 0;
    beginMs_ = buildMs_ = 0;
    idx_ = NULL;
    cap_ = sortedN_ = deadN_ = 0;
    memset(pend_, 0, sizeof(pend_));
    pendN_ = 0;
    records_ = presences_ = tombstones_ = liveBytes_ = 0;
    lastSeq_ = durableHigh_ = 0;
    logBytes_ = firstOff_ = recsInFile_ = 0;
    dbId_ = headerDbId_ = zeroId8();
    formatEpochS_ = lastWallS_ = 0;
    appendHold_ = runtimeCorrupt_ = false;
    memset(holes_, 0, sizeof(holes_));
    nHoles_ = 0;
    gen_ = 1;
    ck_[0] = ck_[1] = NULL;
    ckSlots_ = 0;
    ckN_[0] = ckN_[1] = 0;
    ckK_[0] = ckK_[1] = HUBDB_CK_K0;
    ckCur_ = 0;
    dirty_ = NULL;
    dirtyCap_ = dirtyLen_ = dirtyAppended_ = dirtySince_ = 0;
    flushFails_ = 0;
    io_ = NULL;
    ioCap_ = outCap_ = 0;
    winBuf_ = NULL;
    winCap_ = winOff_ = winLen_ = 0;
    winValid_ = false;
    fsTotal_ = 0;
    fsBase_ = 4u * 4096u;
    liveMax_ = 0xFFFFFFFFu;
    full_ = repull_ = repullNeeded_ = false;
    nvsHaveDb_ = false;
    nvsDb_ = zeroId8();
    nvsLive_ = 0;
    nvsDbDirty_ = nvsLive0Dirty_ = nvsGrpDirty_ = nvsFlagsDirty_ = peersForce_ = false;
    nvsFlags_ = 0;
    memset(&grpStored_, 0, sizeof(grpStored_));
    peersBlobKnown_ = false;
    peersBlobLen_ = 0;
    peersBlobCrc_ = 0;
    nvsBackoff_ = false;
    nvsRetryAt_ = 0;
    memset(&group_, 0, sizeof(group_));
    for (uint8_t i = 0; i < HUB_PEERS_MAX; i++) clearPeer(&peers_[i]);
    peerClock_ = 0;
    logExists_ = newExists_ = resolveNeedsFlash_ = promoted_ = headerOk_ = false;
    logSize0_ = 0;
    scanOff_ = scanSize_ = scanMax_ = scanBad_ = searchPos_ = 0;
    scanSearching_ = scanCorrupt_ = scanTorn_ = false;
    lastType_ = 0;
    endCount_ = endMax_ = 0;
    cPhase_ = C_IDLE;
    cRd_ = cEnd_ = cNewBytes_ = cRecs_ = cMax_ = 0;
    cHeaderId_ = zeroId8();
    recoveryCompact_ = compactWanted_ = compactBackoff_ = newStale_ = false;
    compactRetryAt_ = 0;
    lastTraffic_ = 0;
    hadTraffic_ = false;
    resetId_ = zeroId8();
    resetRetryAt_ = 0;
    flushes_ = flushErrors_ = compactions_ = evictions_ = collisions_ = liveSkipped_ = 0;
  }

  static void clearPeer(Peer* p) {
    memset(p, 0, sizeof(*p));
  }

  // ---- gates ---------------------------------------------------------------------------------
  bool starved(uint32_t now) const {
    return dirtyLen_ > 0 && (int32_t)(now - dirtySince_) >= (int32_t)HUB_DIRTY_STARVED_MS;
  }
  bool flashOk(uint32_t now) { return gate_ && hubFlashWorkAllowed(*gate_, now, starved(now)); }
  bool lightOk() { return gate_ && hubLightWorkAllowed(*gate_); }

  // ---- NVS: load ---------------------------------------------------------------------------
  void loadNvs() {
    uint8_t b[HUB_PEER_BLOB_MAX];
    size_t n = 0;
    if (kv_->getBlob(HUB_NVS_DB, b, 8, &n) && n == 8) {
      nvsHaveDb_ = true;
      nvsDb_ = makeId8(b);
    }
    n = 0;
    if (kv_->getBlob(HUB_NVS_GROUP, b, HUB_GROUP_BLOB, &n) && n == HUB_GROUP_BLOB) {
      group_.grouped = true;
      group_.id = makeId8(b);
      memcpy(group_.key, b + 8, 16);
    }
    grpStored_ = group_;
    n = 0;
    peersBlobKnown_ = true;
    peersBlobLen_ = 0;
    if (kv_->getBlob(HUB_NVS_PEERS, b, sizeof(b), &n)) {
      peersBlobLen_ = n;
      peersBlobCrc_ = crc32(b, n);
      HubPeerRecord recs[HUB_PEERS_MAX];
      const int k = hubPeersBlobDecode(b, n, recs, HUB_PEERS_MAX);
      for (int i = 0; i < k; i++) {
        Peer& p = peers_[i];
        clearPeer(&p);
        p.used = true;
        p.id = recs[i].id;
        p.st.dbId = recs[i].dbId;
        p.st.wm = recs[i].wm;
        p.st.excludeOk = recs[i].excludeOk;
        p.kind = recs[i].kind;
        p.lastSyncS = recs[i].lastSyncEpochS;
        p.safeWm = recs[i].wm;
        p.safeDbId = recs[i].dbId;
        p.use = ++peerClock_;
      }
    }
    uint32_t v = 0;
    if (kv_->getU32(HUB_NVS_FLAGS, &v)) {
      nvsFlags_ = v;
      full_ = (v & HUB_FLAG_FULL) != 0;
      repull_ = (v & HUB_FLAG_REPULL) != 0;
    }
    v = 0;
    if (kv_->getU32(HUB_NVS_LIVE, &v)) nvsLive_ = v;
  }

  // ---- identity ------------------------------------------------------------------------------
  Id8 randomId() {
    uint8_t b[8];
    for (int i = 0; i < 8; i++) {
      rng_->random(b, 8);
      bool nz = false;
      for (int k = 0; k < 8; k++) nz = nz || b[k] != 0;
      if (nz) return makeId8(b);
    }
    b[7] = 1;
    return makeId8(b);
  }

  void clearPeers() {
    for (uint8_t i = 0; i < HUB_PEERS_MAX; i++) clearPeer(&peers_[i]);
    peersForce_ = true;
  }

  // New dbId, zero peers, liveHigh 0 (NVS order: peers, db, live). The library stays; only the
  // feed identity changes (SYNC_PROTOCOL §15.1).
  void newIdentity(bool atBoot) {
    if (atBoot && (bootFlags_ & DB_BOOT_NEW_DBID)) return;  // one new dbId per boot
    dbId_ = randomId();
    bootFlags_ |= atBoot ? DB_BOOT_NEW_DBID : 0;
    clearPeers();
    nvsDbDirty_ = true;
    nvsLive_ = 0;
    nvsLive0Dirty_ = true;
    if (headerDbId_ != dbId_) recoveryCompact_ = true;  // rewrite the HEADER
  }

  void runtimeCorruption() {
    if (runtimeCorrupt_) return;
    runtimeCorrupt_ = true;
    newIdentity(false);
    recoveryCompact_ = true;
  }

  // ---- resolve (boot): which file is the log, its HEADER --------------------------------------
  void resolve(uint32_t now) {
    const bool emptyLog = logExists_ && logSize0_ == 0;
    if (newExists_ && logExists_ && !emptyLog) {
      st_->close(HUB_FILE_NEW);
      if (!st_->remove(HUB_FILE_NEW)) {
        state_ = DB_FAILED;
        return;
      }
      bootFlags_ |= DB_BOOT_NEW_REMOVED;
    } else if (newExists_) {
      if (logExists_) {
        st_->close(HUB_FILE_LOG);
        st_->remove(HUB_FILE_LOG);
      }
      st_->close(HUB_FILE_NEW);
      if (!st_->promoteNew() || !st_->open(HUB_FILE_LOG, false)) {
        state_ = DB_FAILED;
        return;
      }
      promoted_ = true;
      bootFlags_ |= DB_BOOT_NEW_PROMOTED;
      logExists_ = true;
      const int32_t s = st_->size(HUB_FILE_LOG);
      logSize0_ = s > 0 ? (uint32_t)s : 0;
    } else if (emptyLog) {
      st_->close(HUB_FILE_LOG);
      st_->remove(HUB_FILE_LOG);
      logExists_ = false;
    }
    if (!logExists_ || logSize0_ == 0) {
      createLog(now);
      return;
    }
    // An existing lib.log: check its HEADER.
    useWindow(io_, ioCap_);
    HubLogHead h;
    const uint8_t* p = winGet(0, HUB_LOG_HEAD_BYTES, HUBDB_WIN_SMALL, logSize0_);
    uint32_t hsz = 0;
    if (p && hubLogParseHead(p, HUB_LOG_HEAD_BYTES, &h) && h.type == HUB_LOG_HEADER) {
      const uint32_t size = HUB_LOG_OVERHEAD + h.len;
      p = winGet(0, size, HUBDB_WIN_SMALL, logSize0_);
      if (p && hubLogCheck(p, size, &h) == size) hsz = size;
    }
    if (hsz) {
      headerOk_ = true;
      headerDbId_ = makeId8(p + HUB_LOG_HEAD_BYTES);
      formatEpochS_ = (uint32_t)getLE(p + HUB_LOG_HEAD_BYTES + 8, 4);
      firstOff_ = hsz;
      dbId_ = headerDbId_;
      if (!nvsHaveDb_ || nvsDb_ != headerDbId_ || isZero(headerDbId_)) {
        bootFlags_ |= DB_BOOT_HEADER_MISMATCH;
        newIdentity(true);
      }
    } else {
      headerOk_ = false;  // corruption: the scan searches for valid entries from offset 0
      firstOff_ = 0;
    }
    scanOff_ = firstOff_;
    scanSize_ = logSize0_;
    phase_ = BP_SCAN;
  }

  // No (usable) lib.log: a new dbId and a fresh log with its HEADER (plan §4.6).
  void createLog(uint32_t now) {
    if (nvsHaveDb_) bootFlags_ |= DB_BOOT_NEW_DBID;  // D-P2-17: phones may hold a wm into it
    bootFlags_ |= DB_BOOT_LOG_CREATED;
    dbId_ = randomId();
    clearPeers();
    nvsDbDirty_ = true;
    nvsLive_ = 0;
    nvsLive0Dirty_ = true;
    if (!writeFreshLog(dbId_)) {
      state_ = DB_FAILED;
      return;
    }
    finishBuild(now);
  }

  // Creates lib.log = HEADER(id) and syncs it (flash gate held by the caller).
  bool writeFreshLog(const Id8& id) {
    uint8_t h[HUB_LOG_OVERHEAD + HUB_LOG_HEADER_PAYLOAD];
    if (formatEpochS_ == 0) formatEpochS_ = lastWallS_;
    const size_t n = hubLogEncodeHeader(h, sizeof(h), id, formatEpochS_);
    if (!st_->open(HUB_FILE_LOG, true) || !st_->append(HUB_FILE_LOG, h, (uint32_t)n) ||
        !st_->sync(HUB_FILE_LOG))
      return false;
    headerDbId_ = id;
    headerOk_ = true;
    firstOff_ = logBytes_ = (uint32_t)n;
    scanMax_ = 0;
    recsInFile_ = 0;
    winValid_ = false;
    return true;
  }

  // ---- scan (boot): validate every entry, build the index and the checkpoints -----------------
  void scanStep(uint32_t now) {
    useWindow(io_, ioCap_);
    uint32_t budget = HUB_BUILD_BYTES;
    bool merged = false;
    while (budget > 0) {
      if (scanSearching_) {
        if (searchPos_ >= scanSize_) {  // nothing valid after the bad entry: a torn tail
          scanTorn_ = true;
          scanSize_ = scanBad_;
          scanSearching_ = false;
          continue;
        }
        const uint8_t* w = winGet(searchPos_, 1, HUBDB_WIN_FEED, scanSize_);
        if (!w) {
          searchPos_ = scanSize_;
          continue;
        }
        const uint32_t avail = winOff_ + winLen_ - searchPos_;
        const void* m = memchr(w, HUB_LOG_MAGIC, avail);
        if (!m) {
          searchPos_ += avail;
          budget = budget > avail ? budget - avail : 0;
          continue;
        }
        const uint32_t pos = searchPos_ + (uint32_t)((const uint8_t*)m - w);
        budget = budget > pos - searchPos_ + 1 ? budget - (pos - searchPos_ + 1) : 0;
        HubLogHead h;
        if (scanValidAt(pos, &h)) {
          if (nHoles_ >= HUBDB_MAX_HOLES) {  // too many bad regions: keep the prefix (a new dbId anyway)
            scanTorn_ = true;
            scanSize_ = scanBad_;
            scanSearching_ = false;
            continue;
          }
          holes_[nHoles_].start = scanBad_;
          holes_[nHoles_].end = pos;
          nHoles_++;
          scanCorrupt_ = true;
          scanOff_ = pos;
          scanSearching_ = false;
        } else {
          searchPos_ = pos + 1;
        }
        continue;
      }
      if (scanOff_ >= scanSize_) {
        finishScan(now);
        return;
      }
      HubLogHead h;
      if (!scanValidAt(scanOff_, &h)) {
        scanBad_ = scanOff_;
        scanSearching_ = true;
        searchPos_ = scanOff_ + 1;
        continue;
      }
      const uint32_t size = HUB_LOG_OVERHEAD + h.len;
      if (h.type == HUB_LOG_RECORD) {
        const uint8_t* p = winGet(scanOff_, size, HUBDB_WIN_FEED, scanSize_);
        const uint8_t* body = p + HUB_LOG_HEAD_BYTES;
        HubBodyPeek pk;
        if (!hubPeekBody(body, h.len, &pk)) {  // a CRC-valid RECORD that is no body: corruption
          scanBad_ = scanOff_;
          scanSearching_ = true;
          searchPos_ = scanOff_ + 1;
          continue;
        }
        uint32_t lo, hi;
        hashParts(pk.key, &lo, &hi);
        uint32_t* e = find(lo, hi);
        if (!(e && e[2] != 0) && !e && pendN_ >= HUB_PENDING_INSERTS) {
          if (merged) return;  // one merge per step
          mergePending();
          merged = true;
          e = find(lo, hi);
        }
        const uint32_t ref = h.seq | (pk.cls == CLS_PRESENCE ? HUBDB_REF_P : 0) |
                             ((pk.flags & FLAG_DELETED) ? HUBDB_REF_D : 0);
        if (e && e[2] != 0) {  // a newer version of an indexed key
          countRemove(e[2], entLen(e));
          setEnt(e, lo, hi, ref, h.len);
          countAdd(ref, h.len);
        } else {
          // An evicted key comes back at boot; at capacity the same eviction policy applies.
          bool room = records_ < cap_;
          if (!room) room = evictFor(0);
          if (room) insertNew(e, lo, hi, ref, h.len);
        }
        addCheckpoint(ckCur_, h.seq, scanOff_, recsInFile_);
        recsInFile_++;
        scanMax_ = h.seq;
      } else if (h.type == HUB_LOG_END) {
        const uint8_t* p = winGet(scanOff_, size, HUBDB_WIN_FEED, scanSize_);
        endCount_ = (uint32_t)getLE(p + HUB_LOG_HEAD_BYTES, 4);
        endMax_ = (uint32_t)getLE(p + HUB_LOG_HEAD_BYTES + 4, 4);
      }
      lastType_ = h.type;
      scanOff_ += size;
      budget = budget > size ? budget - size : 0;
    }
  }

  // A valid entry at pos for the scan: CRC-valid, a RECORD above every seq so far or an END; a
  // HEADER only as the first entry.
  bool scanValidAt(uint32_t pos, HubLogHead* h) {
    const uint8_t* p = winGet(pos, HUB_LOG_HEAD_BYTES, HUBDB_WIN_FEED, scanSize_);
    if (!p || !hubLogParseHead(p, HUB_LOG_HEAD_BYTES, h)) return false;
    const uint32_t size = HUB_LOG_OVERHEAD + h->len;
    p = winGet(pos, size, HUBDB_WIN_FEED, scanSize_);
    if (!p || hubLogCheck(p, size, h) != size) return false;
    if (h->type == HUB_LOG_HEADER) return false;  // offset 0 is handled by resolve()
    if (h->type == HUB_LOG_RECORD && h->seq <= scanMax_) return false;
    return true;
  }

  void finishScan(uint32_t now) {
    if (pendN_) mergePending();
    logBytes_ = scanSize_;
    if (promoted_ && (scanTorn_ || scanCorrupt_ || lastType_ != HUB_LOG_END ||
                      endCount_ != recsInFile_ || endMax_ != scanMax_))
      scanCorrupt_ = true;  // a promoted lib.new must end with its END
    if (!headerOk_) scanCorrupt_ = true;
    if (scanTorn_) {
      bootFlags_ |= DB_BOOT_TORN_TAIL;
      appendHold_ = true;
      recoveryCompact_ = true;
    }
    if (scanCorrupt_) {
      bootFlags_ |= DB_BOOT_CORRUPT;
      newIdentity(true);
      appendHold_ = true;
      recoveryCompact_ = true;
    }
    if (nvsLive_ > scanMax_) {
      bootFlags_ |= DB_BOOT_LIVE_LOST;
      newIdentity(true);
    }
    lastSeq_ = durableHigh_ = scanMax_;
    finishBuild(now);
  }

  void finishBuild(uint32_t now) {
    refreshUsage();
    buildMs_ = now - beginMs_;
    state_ = DB_READY;
    winValid_ = false;
  }

  // ---- background step (maintain / maintenanceDue) -------------------------------------------
  bool step(uint32_t now, bool run) {
    switch (state_) {
      case DB_RESETTING:
        if ((int32_t)(now - resetRetryAt_) < 0 || !flashOk(now)) return false;
        if (run) doReset(now);
        return true;
      case DB_BUILDING:
        if (phase_ == BP_RESOLVE) {
          if (resolveNeedsFlash_ && !flashOk(now)) return false;
          if (run) resolve(now);
          return true;
        }
        if (!lightOk()) return false;
        if (run) scanStep(now);
        return true;
      case DB_READY:
        break;
      default:
        return false;
    }
    bool did = false;
    if (flagClearDue()) {
      if (!run) return true;
      clearFlags();
      did = true;
    }
    if (pendN_ > 0 && lightOk()) {
      if (!run) return true;
      mergePending();
      return true;
    }
    if (!flashOk(now)) return did;
    if (newStale_) {
      if (!run) return true;
      st_->close(HUB_FILE_NEW);
      if (st_->remove(HUB_FILE_NEW)) newStale_ = false;
      return true;
    }
    if (nvsDue(now)) {
      if (!run) return true;
      writeNvs(now, false);
      return true;
    }
    if (compactDue(now)) {
      if (!run) return true;
      compactStep(now);
      return true;
    }
    return did;
  }

  // ---- capacity flags ------------------------------------------------------------------------
  bool fullClearOk() const {
    if (!full_) return false;
    if ((uint64_t)records_ + 64u > cap_) return false;
    if (liveMax_ != 0xFFFFFFFFu && (uint64_t)liveBytes_ + 16384u > liveMax_) return false;
    return fsFree() >= 131072u;
  }
  bool repullClearOk() const {
    return repull_ && !full_ && dirtyLen_ == 0 && pendN_ == 0 && cPhase_ == C_IDLE && !appendHold_;
  }
  bool flagClearDue() const { return fullClearOk() || repullClearOk(); }
  void clearFlags() {
    if (fullClearOk()) {
      full_ = false;
      repull_ = false;  // one re-pull covers both
      repullNeeded_ = true;
      nvsFlagsDirty_ = true;
    } else if (repullClearOk()) {
      repull_ = false;
      repullNeeded_ = true;
      nvsFlagsDirty_ = true;
    }
  }

  DbAccept busy(DbAccept* r, bool live) {
    r->result = DBR_BUSY;
    if (!live && !repull_) {
      repull_ = true;  // D-P2-18: the wm goes past it; a re-pull follows once the DB can store
      nvsFlagsDirty_ = true;
    }
    return *r;
  }

  DbAccept fullResult(DbAccept* r) {
    r->result = DBR_FULL;
    if (!full_) {
      full_ = true;
      nvsFlagsDirty_ = true;
    }
    return *r;
  }

  static uint32_t blocks4k(uint32_t bytes) { return (bytes + 4095u) / 4096u * 4096u; }
  uint32_t fsUsedEst() const {
    return fsBase_ + blocks4k(logBytes_ + dirtyLen_) + (cPhase_ != C_IDLE ? blocks4k(cNewBytes_) : 0);
  }
  uint32_t fsFree() const {
    if (!fsTotal_) return 0xFFFFFFFFu;
    const uint32_t u = fsUsedEst();
    return u >= fsTotal_ ? 0 : fsTotal_ - u;
  }
  void refreshUsage() {
    uint32_t t = 0, u = 0;
    if (st_ && st_->usage(&t, &u)) {
      const uint32_t lb = blocks4k(logBytes_);
      fsBase_ = u > lb ? u - lb : 0;
    } else {
      fsBase_ = 4u * 4096u;
    }
  }

  // ---- index ---------------------------------------------------------------------------------
  void hashParts(const Key& k, uint32_t* lo, uint32_t* hi) const {
    const uint64_t h = cfg_.keyHash ? cfg_.keyHash(k) : keyHash(k);
    *lo = (uint32_t)h;
    *hi = (uint32_t)(h >> 32) & HUBDB_HI_MASK;
  }
  static uint32_t entLen(const uint32_t* e) { return e[1] >> HUBDB_LEN_SHIFT; }
  static void setEnt(uint32_t* e, uint32_t lo, uint32_t hi, uint32_t ref, uint32_t len) {
    e[0] = lo;
    e[1] = (hi & HUBDB_HI_MASK) | (len << HUBDB_LEN_SHIFT);
    e[2] = ref;
  }
  static bool entLess(const uint32_t* a, const uint32_t* b) {
    const uint32_t ha = a[1] & HUBDB_HI_MASK, hb = b[1] & HUBDB_HI_MASK;
    return ha < hb || (ha == hb && a[0] < b[0]);
  }

  // The slot (live or dead) holding this hash, NULL when none.
  uint32_t* find(uint32_t lo, uint32_t hi) {
    uint32_t a = 0, b = sortedN_;
    while (a < b) {
      const uint32_t m = a + (b - a) / 2;
      const uint32_t* e = idx_ + 3u * m;
      const uint32_t he = e[1] & HUBDB_HI_MASK;
      if (he < hi || (he == hi && e[0] < lo)) a = m + 1;
      else b = m;
    }
    if (a < sortedN_) {
      uint32_t* e = idx_ + 3u * a;
      if ((e[1] & HUBDB_HI_MASK) == hi && e[0] == lo) return e;
    }
    for (uint8_t i = 0; i < pendN_; i++) {
      uint32_t* e = pend_ + 3u * i;
      if ((e[1] & HUBDB_HI_MASK) == hi && e[0] == lo) return e;
    }
    return NULL;
  }

  void countAdd(uint32_t ref, uint32_t len) {
    records_++;
    liveBytes_ += HUB_LOG_OVERHEAD + len;
    if (ref & HUBDB_REF_P) presences_++;
    if (ref & HUBDB_REF_D) tombstones_++;
  }
  void countRemove(uint32_t ref, uint32_t len) {
    records_--;
    liveBytes_ -= HUB_LOG_OVERHEAD + len;
    if (ref & HUBDB_REF_P) presences_--;
    if (ref & HUBDB_REF_D) tombstones_--;
  }

  bool inSorted(const uint32_t* e) const { return e >= idx_ && e < idx_ + 3u * sortedN_; }

  // Stores a new key (records_ < cap_ guaranteed by the caller): revives a dead slot of the same
  // hash, else takes a pending slot (the caller made room).
  void insertNew(uint32_t* dead, uint32_t lo, uint32_t hi, uint32_t ref, uint32_t len) {
    if (dead) {
      if (inSorted(dead)) deadN_--;
      setEnt(dead, lo, hi, ref, len);
    } else {
      setEnt(pend_ + 3u * pendN_, lo, hi, ref, len);
      pendN_++;
    }
    countAdd(ref, len);
  }

  void markDead(uint32_t* e) {
    countRemove(e[2], entLen(e));
    e[2] = 0;
    if (inSorted(e)) deadN_++;
    evictions_++;
  }

  // The oldest live entry with the class bit, not one of skip[0..nSkip).
  uint32_t* oldestWith(uint32_t bit, uint32_t* const* skip, uint8_t nSkip) {
    uint32_t* best = NULL;
    uint32_t bestSeq = 0xFFFFFFFFu;
    for (uint32_t pass = 0; pass < 2; pass++) {
      uint32_t* base = pass == 0 ? idx_ : pend_;
      const uint32_t n = pass == 0 ? sortedN_ : pendN_;
      for (uint32_t i = 0; i < n; i++) {
        uint32_t* e = base + 3u * i;
        if (e[2] == 0 || !(e[2] & bit)) continue;
        const uint32_t s = e[2] & HUBDB_REF_SEQ;
        if (s >= bestSeq) continue;
        bool skipped = false;
        for (uint8_t k = 0; k < nSkip; k++) skipped = skipped || skip[k] == e;
        if (skipped) continue;
        best = e;
        bestSeq = s;
      }
    }
    return best;
  }

  // Makes room for one new entry of esz bytes (esz 0: just one index slot) by evicting the oldest
  // PRESENCE entries, then the oldest TOMBSTONEs, at most HUBDB_MAX_EVICT. Nothing is evicted when that
  // cannot make it fit.
  bool evictFor(uint32_t esz) {
    uint32_t* pick[HUBDB_MAX_EVICT];
    uint8_t n = 0;
    uint32_t recs = records_;
    uint64_t live = liveBytes_;
    const uint64_t liveMax = liveMax_;
    while (recs >= cap_ || (esz && live + esz > liveMax)) {
      if (n >= HUBDB_MAX_EVICT) return false;
      uint32_t* e = oldestWith(HUBDB_REF_P, pick, n);
      if (!e) e = oldestWith(HUBDB_REF_D, pick, n);
      if (!e) return false;
      pick[n++] = e;
      recs--;
      live -= HUB_LOG_OVERHEAD + entLen(e);
    }
    for (uint8_t i = 0; i < n; i++) markDead(pick[i]);
    return true;
  }

  // Sorts the pending inserts into the array (one backward pass; dead slots dropped first).
  void mergePending() {
    // drop dead pending entries, then insertion-sort (32 at most)
    uint8_t m = 0;
    for (uint8_t i = 0; i < pendN_; i++) {
      if (pend_[3u * i + 2] == 0) continue;
      if (m != i) memcpy(pend_ + 3u * m, pend_ + 3u * i, 12);
      m++;
    }
    for (uint8_t i = 1; i < m; i++) {
      uint32_t t[3];
      memcpy(t, pend_ + 3u * i, 12);
      int j = (int)i - 1;
      while (j >= 0 && entLess(t, pend_ + 3u * (uint32_t)j)) {
        memcpy(pend_ + 3u * (uint32_t)(j + 1), pend_ + 3u * (uint32_t)j, 12);
        j--;
      }
      memcpy(pend_ + 3u * (uint32_t)(j + 1), t, 12);
    }
    if (deadN_) {
      uint32_t k = 0;
      for (uint32_t i = 0; i < sortedN_; i++) {
        if (idx_[3u * i + 2] == 0) continue;
        if (k != i) memcpy(idx_ + 3u * k, idx_ + 3u * i, 12);
        k++;
      }
      sortedN_ = k;
      deadN_ = 0;
    }
    if (sortedN_ + m > cap_) m = (uint8_t)(cap_ - sortedN_);  // cannot happen (records <= cap)
    int64_t i = (int64_t)sortedN_ - 1, j = (int64_t)m - 1, k = (int64_t)sortedN_ + m - 1;
    while (j >= 0) {
      if (i >= 0 && entLess(pend_ + 3u * (uint32_t)j, idx_ + 3u * (uint32_t)i)) {
        memcpy(idx_ + 3u * (uint32_t)k, idx_ + 3u * (uint32_t)i, 12);
        i--;
      } else {
        memcpy(idx_ + 3u * (uint32_t)k, pend_ + 3u * (uint32_t)j, 12);
        j--;
      }
      k--;
    }
    sortedN_ += m;
    pendN_ = 0;
  }

  // Is the RECORD with this seq and body the current version of its key?
  bool isCurrent(uint32_t seq, const uint8_t* body, uint16_t len) {
    Key k;
    if (!hubBodyKey(body, len, &k)) return false;
    uint32_t lo, hi;
    hashParts(k, &lo, &hi);
    const uint32_t* e = find(lo, hi);
    return e && e[2] != 0 && (e[2] & HUBDB_REF_SEQ) == seq;
  }

  bool fillEntry(DbEntry* out, const HubLogHead& h, const uint8_t* body) {
    HubBodyPeek pk;
    if (!hubPeekBody(body, h.len, &pk)) return false;
    out->seq = h.seq;
    out->durable = h.seq <= durableHigh_;
    out->hasSyncFrom = !isZero(h.syncFrom);
    out->syncFrom = h.syncFrom;
    out->hasOrigin = pk.hasOrigin;
    out->origin = pk.origin;
    out->version = hubPeekVersion(pk, body, h.len);
    out->cls = pk.cls;
    out->body = body;
    out->bodyLen = h.len;
    return true;
  }

  // ---- checkpoints -------------------------------------------------------------------------
  void addCheckpoint(uint8_t t, uint32_t seq, uint32_t off, uint32_t recIndex) {
    if (recIndex % ckK_[t] != 0) return;
    if (ckN_[t] >= ckSlots_) {  // full: keep every other slot, double the stride
      uint32_t* c = ck_[t];
      uint32_t k = 0;
      for (uint32_t i = 0; i < ckN_[t]; i += 2, k++) {
        c[2u * k] = c[2u * i];
        c[2u * k + 1] = c[2u * i + 1];
      }
      ckN_[t] = k;
      ckK_[t] *= 2;
      if (recIndex % ckK_[t] != 0) return;
    }
    ck_[t][2u * ckN_[t]] = seq;
    ck_[t][2u * ckN_[t] + 1] = off;
    ckN_[t]++;
  }

  // The offset to start a walk for the first RECORD with seq >= target.
  uint32_t ckStart(uint8_t t, uint32_t target) const {
    const uint32_t* c = ck_[t];
    uint32_t a = 0, b = ckN_[t];
    while (a < b) {  // the first checkpoint with seq > target
      const uint32_t m = a + (b - a) / 2;
      if (c[2u * m] <= target) a = m + 1;
      else b = m;
    }
    return a == 0 ? firstOff_ : c[2u * (a - 1) + 1];
  }

  uint32_t skipHoles(uint32_t off) const {
    for (uint8_t i = 0; i < nHoles_; i++)
      if (off >= holes_[i].start && off < holes_[i].end) off = holes_[i].end;
    return off;
  }

  // ---- reads -------------------------------------------------------------------------------
  void useWindow(uint8_t* buf, uint32_t cap) {
    if (winBuf_ != buf || winCap_ != cap) winValid_ = false;
    winBuf_ = buf;
    winCap_ = cap;
  }

  // need bytes of lib.log at off (below limit), reading `refill` bytes when the window misses.
  const uint8_t* winGet(uint32_t off, uint32_t need, uint32_t refill, uint32_t limit) {
    if (winValid_ && off >= winOff_ && off + need <= winOff_ + winLen_) return winBuf_ + (off - winOff_);
    if (off >= limit || need > limit - off) return NULL;
    uint32_t n = refill < need ? need : refill;
    if (n > winCap_) n = winCap_;
    if (n > limit - off) n = limit - off;
    if (n < need) return NULL;
    uint32_t got = 0;
    while (got < n) {
      const int32_t r = st_->read(HUB_FILE_LOG, off + got, winBuf_ + got, n - got);
      if (r <= 0) break;
      got += (uint32_t)r;
    }
    if (got < need) {
      winValid_ = false;
      return NULL;
    }
    winOff_ = off;
    winLen_ = got;
    winValid_ = true;
    return winBuf_;
  }

  // The RECORD with exactly this seq (dirty queue or lib.log); its body, NULL when not found or
  // unreadable.
  const uint8_t* readEntry(uint32_t seq, HubLogHead* h) {
    if (seq > durableHigh_) {
      uint32_t off = 0;
      while (off < dirtyLen_) {
        hubLogParseHead(dirty_ + off, dirtyLen_ - off, h);
        if (h->seq == seq) return dirty_ + off + HUB_LOG_HEAD_BYTES;
        if (h->seq > seq) return NULL;
        off += HUB_LOG_OVERHEAD + h->len;
      }
      return NULL;
    }
    useWindow(io_, ioCap_);
    uint32_t off = ckStart(ckCur_, seq);
    for (;;) {
      off = skipHoles(off);
      if (off >= logBytes_) return NULL;
      const uint8_t* p = winGet(off, HUB_LOG_HEAD_BYTES, HUBDB_WIN_SMALL, logBytes_);
      if (!p || !hubLogParseHead(p, HUB_LOG_HEAD_BYTES, h)) {
        runtimeCorruption();
        return NULL;
      }
      const uint32_t size = HUB_LOG_OVERHEAD + h->len;
      if (h->type == HUB_LOG_RECORD && h->seq >= seq) {
        if (h->seq != seq) return NULL;
        p = winGet(off, size, HUBDB_WIN_SMALL, logBytes_);
        HubLogHead fh;
        if (!p || hubLogCheck(p, size, &fh) != size) {
          runtimeCorruption();
          return NULL;
        }
        return p + HUB_LOG_HEAD_BYTES;
      }
      off += size;
    }
  }

  static void charge(FeedBudget* b, uint32_t size) {
    if (b->entries) b->entries--;
    b->bytes = b->bytes > size ? (uint16_t)(b->bytes - size) : 0;
  }

  // ---- flush -------------------------------------------------------------------------------
  uint8_t doFlush(uint32_t now) {
    if (dirtyAppended_ < dirtyLen_) {
      const uint32_t base = logBytes_ + dirtyAppended_;
      const uint32_t n = dirtyLen_ - dirtyAppended_;
      if (!st_->append(HUB_FILE_LOG, dirty_ + dirtyAppended_, n)) {
        flushErrors_++;
        flushFails_++;
        const int32_t sz = st_->size(HUB_FILE_LOG);
        if (sz >= 0 && (uint32_t)sz == base + n) {
          dirtyAppended_ = dirtyLen_;  // everything landed after all
        } else if (sz < 0 || (uint32_t)sz != base) {
          holdForCompaction();  // a partial write: lib.log ends in a torn tail now
        } else if (flushFails_ >= 3) {
          compactWanted_ = true;  // maybe ENOSPC
        }
        return DB_FLUSH_ERROR;
      }
      dirtyAppended_ = dirtyLen_;
    }
    if (!st_->sync(HUB_FILE_LOG)) {
      flushErrors_++;
      flushFails_++;
      if (flushFails_ >= 3) holdForCompaction();
      return DB_FLUSH_ERROR;
    }
    uint32_t off = 0;
    while (off < dirtyLen_) {
      HubLogHead h;
      hubLogParseHead(dirty_ + off, dirtyLen_ - off, &h);
      addCheckpoint(ckCur_, h.seq, logBytes_ + off, recsInFile_);
      recsInFile_++;
      off += HUB_LOG_OVERHEAD + h.len;
    }
    logBytes_ += dirtyLen_;
    durableHigh_ = lastSeq_;
    dirtyLen_ = 0;
    dirtyAppended_ = 0;
    flushFails_ = 0;
    flushes_++;
    for (uint8_t i = 0; i < HUB_PEERS_MAX; i++)
      if (peers_[i].used) peerCheckSafe(&peers_[i]);
    (void)now;
    return DB_FLUSH_DONE;
  }

  // lib.log may hold bytes past logBytes_ that are not whole entries: no more appends until a
  // compaction rewrote it (the dirty queue is appended to the new file after the swap).
  void holdForCompaction() {
    appendHold_ = true;
    recoveryCompact_ = true;
    dirtyAppended_ = 0;
  }

  // ---- peers -------------------------------------------------------------------------------
  Peer* findPeerSlot(const Id8& id) {
    for (uint8_t i = 0; i < HUB_PEERS_MAX; i++) {
      if (peers_[i].used && peers_[i].id == id) {
        peers_[i].use = ++peerClock_;
        return &peers_[i];
      }
    }
    return NULL;
  }

  // A committed wm becomes safe (persistable) once every record accepted before it is durable.
  void peerCheckSafe(Peer* p) {
    if (p->pendCommit && durableHigh_ >= p->needSeq) {
      p->safeWm = p->pendWm;
      p->safeDbId = p->pendDbId;
      p->pendCommit = false;
      p->due = true;
    }
  }

  bool peerEligible(const Peer& p, uint32_t now) const {
    return p.used && p.due &&
           (!p.written || p.ended || (int32_t)(now - p.lastWriteMs) >= (int32_t)HUB_PEER_PERSIST_MS);
  }

  bool peersDue(uint32_t now) const {
    if (peersForce_) return true;
    for (uint8_t i = 0; i < HUB_PEERS_MAX; i++)
      if (peerEligible(peers_[i], now)) return true;
    return false;
  }

  bool writePeers(uint32_t now) {
    HubPeerRecord recs[HUB_PEERS_MAX];
    uint8_t n = 0;
    for (uint8_t i = 0; i < HUB_PEERS_MAX; i++) {
      const Peer& p = peers_[i];
      if (!p.used) continue;
      recs[n].id = p.id;
      recs[n].dbId = p.st.dbId;
      recs[n].wm = p.st.dbId == p.safeDbId ? p.safeWm : 0;
      recs[n].excludeOk = p.st.excludeOk;
      recs[n].kind = p.kind;
      recs[n].lastSyncEpochS = p.lastSyncS;
      n++;
    }
    uint8_t b[HUB_PEER_BLOB_MAX];
    const size_t len = n ? hubPeersBlobEncode(recs, n, b) : 0;
    const uint32_t crc = len ? crc32(b, len) : 0;
    if (!(peersBlobKnown_ && peersBlobLen_ == len && (len == 0 || peersBlobCrc_ == crc))) {
      const bool ok = len ? kv_->setBlob(HUB_NVS_PEERS, b, len) : kv_->erase(HUB_NVS_PEERS);
      if (!ok) return false;
      peersBlobKnown_ = true;
      peersBlobLen_ = len;
      peersBlobCrc_ = crc;
    }
    for (uint8_t i = 0; i < HUB_PEERS_MAX; i++) {
      Peer& p = peers_[i];
      if (!p.used || !p.due) continue;
      p.due = false;
      p.ended = false;
      p.written = true;
      p.lastWriteMs = now;
    }
    peersForce_ = false;
    return true;
  }

  // peers (zeroed) before db: a crash in between can only cost one more new dbId.
  bool writeIdentity(uint32_t now) {
    if ((peersForce_ || nvsDbDirty_) && !writePeers(now)) return false;
    if (nvsDbDirty_) {
      if (!kv_->setBlob(HUB_NVS_DB, dbId_.b, 8)) return false;
      nvsDbDirty_ = false;
      nvsHaveDb_ = true;
      nvsDb_ = dbId_;
    }
    return true;
  }

  bool grpDiffers() const {
    if (group_.grouped != grpStored_.grouped) return true;
    if (!group_.grouped) return false;
    return group_.id != grpStored_.id || memcmp(group_.key, grpStored_.key, 16) != 0;
  }

  uint32_t flagsValue() const { return (full_ ? HUB_FLAG_FULL : 0) | (repull_ ? HUB_FLAG_REPULL : 0); }

  bool nvsDue(uint32_t now) const {
    if (nvsBackoff_ && (int32_t)(now - nvsRetryAt_) < 0) return false;
    if (nvsDbDirty_ || nvsLive0Dirty_) return true;
    if (nvsGrpDirty_ || nvsFlagsDirty_) return true;
    return peersDue(now);
  }

  // Every NVS write that is due, in order (identity first). all: every due peer regardless of
  // the 60 s rule (flushNow). A failed write stops the batch and is retried after 1 s.
  void writeNvs(uint32_t now, bool all) {
    nvsBackoff_ = true;
    nvsRetryAt_ = now + HUBDB_NVS_RETRY_MS;
    if (writeNvsBatch(now, all)) nvsBackoff_ = false;
  }

  bool writeNvsBatch(uint32_t now, bool all) {
    if (all) {
      for (uint8_t i = 0; i < HUB_PEERS_MAX; i++)
        if (peers_[i].used && peers_[i].due) peersForce_ = true;
    }
    if (peersDue(now) || nvsDbDirty_) {
      if (!writeIdentity(now)) return false;
      if (peersDue(now) && !writePeers(now)) return false;
    }
    if (nvsLive0Dirty_) {
      if (!kv_->setU32(HUB_NVS_LIVE, nvsLive_)) return false;
      nvsLive0Dirty_ = false;
    }
    if (nvsGrpDirty_) {
      if (grpDiffers()) {
        bool ok;
        if (group_.grouped) {
          uint8_t b[HUB_GROUP_BLOB];
          hubGroupBlobEncode(group_, b);
          ok = kv_->setBlob(HUB_NVS_GROUP, b, HUB_GROUP_BLOB);
        } else {
          ok = kv_->erase(HUB_NVS_GROUP);
        }
        if (!ok) return false;
        grpStored_ = group_;
      }
      nvsGrpDirty_ = false;
    }
    if (nvsFlagsDirty_) {
      const uint32_t v = flagsValue();
      if (v != nvsFlags_) {
        if (!kv_->setU32(HUB_NVS_FLAGS, v)) return false;
        nvsFlags_ = v;
      }
      nvsFlagsDirty_ = false;
    }
    return true;
  }

  // ---- compaction ----------------------------------------------------------------------------
  bool compactNeeded() const {
    if (recoveryCompact_ || compactWanted_ || appendHold_) return true;
    const uint64_t twice = 2ull * liveBytes_;
    const uint64_t lim = twice > HUB_COMPACT_MIN_LOG ? twice : (uint64_t)HUB_COMPACT_MIN_LOG;
    if (logBytes_ > lim) return true;
    const bool gain = logBytes_ > firstOff_ + liveBytes_ + 4096u;  // something to drop
    if (gain && fsTotal_ && fsFree() < HUB_COMPACT_FREE_MIN) return true;
    return false;
  }

  bool compactDue(uint32_t now) const {
    if (cPhase_ != C_IDLE) return true;
    if (!compactNeeded()) return false;
    if (compactBackoff_ && (int32_t)(now - compactRetryAt_) < 0) return false;
    const bool urgent = recoveryCompact_ || compactWanted_ || appendHold_;
    if (!urgent && hadTraffic_ && (int32_t)(now - lastTraffic_) < (int32_t)HUB_COMPACT_QUIET_MS)
      return false;
    return true;
  }

  void compactStep(uint32_t now) {
    winValid_ = false;  // the output buffer overlaps the window
    useWindow(io_ + outCap_, ioCap_ - outCap_);
    switch (cPhase_) {
      case C_IDLE: {
        if (dirtyLen_ > 0 && !appendHold_ && flushFails_ == 0) {
          doFlush(now);  // flush first, so the copy covers everything (not after a failure)
          break;
        }
        st_->close(HUB_FILE_NEW);
        if (st_->exists(HUB_FILE_NEW) && !st_->remove(HUB_FILE_NEW)) {
          compactFail(now);
          break;
        }
        newStale_ = false;
        cHeaderId_ = dbId_;
        const size_t n = hubLogEncodeHeader(io_, outCap_, cHeaderId_, formatEpochS_);
        if (!st_->open(HUB_FILE_NEW, true) || !st_->append(HUB_FILE_NEW, io_, (uint32_t)n)) {
          compactFail(now);
          break;
        }
        cNewBytes_ = (uint32_t)n;
        cRecs_ = 0;
        cMax_ = 0;
        cRd_ = firstOff_;
        cEnd_ = logBytes_;
        const uint8_t t = (uint8_t)(ckCur_ ^ 1);
        ckN_[t] = 0;
        ckK_[t] = HUBDB_CK_K0;
        cPhase_ = C_COPY;
        break;
      }
      case C_COPY: {
        const uint8_t t = (uint8_t)(ckCur_ ^ 1);
        uint32_t outLen = 0, inBudget = 2u * HUB_COMPACT_STEP_BYTES;
        while (cRd_ < cEnd_ && inBudget > 0) {
          const uint32_t s = skipHoles(cRd_);
          if (s != cRd_) {
            cRd_ = s;
            continue;
          }
          HubLogHead h;
          const uint8_t* p = winGet(cRd_, HUB_LOG_HEAD_BYTES, HUBDB_WIN_SMALL, cEnd_);
          if (!p || !hubLogParseHead(p, HUB_LOG_HEAD_BYTES, &h)) {
            runtimeCorruption();  // validated at boot: flash went bad since; drop the rest
            cRd_ = cEnd_;
            break;
          }
          const uint32_t size = HUB_LOG_OVERHEAD + h.len;
          if (h.type == HUB_LOG_RECORD) {
            p = winGet(cRd_, size, HUBDB_WIN_SMALL, cEnd_);
            HubLogHead fh;
            const uint8_t* body = p ? p + HUB_LOG_HEAD_BYTES : NULL;
            if (!p || hubLogCheck(p, size, &fh) != size) {
              runtimeCorruption();
              Key k;
              if (body && hubBodyKey(body, h.len, &k)) dropIfCurrent(h.seq, k);
            } else if (isCurrent(h.seq, body, h.len)) {
              if (outLen + size > outCap_) break;
              memcpy(io_ + outLen, p, size);
              addCheckpoint(t, h.seq, cNewBytes_ + outLen, cRecs_);
              cRecs_++;
              cMax_ = h.seq;
              outLen += size;
            }
          }
          cRd_ += size;
          inBudget = inBudget > size ? inBudget - size : 0;
        }
        if (outLen && !st_->append(HUB_FILE_NEW, io_, outLen)) {
          compactFail(now);
          break;
        }
        cNewBytes_ += outLen;
        if (cRd_ >= cEnd_) cPhase_ = C_FINISH;
        break;
      }
      case C_FINISH: {
        const size_t n = hubLogEncodeEnd(io_, outCap_, cRecs_, cMax_);
        if (!st_->append(HUB_FILE_NEW, io_, (uint32_t)n) || !st_->sync(HUB_FILE_NEW)) {
          compactFail(now);
          break;
        }
        st_->close(HUB_FILE_NEW);
        cNewBytes_ += (uint32_t)n;
        cPhase_ = C_SWAP;
        break;
      }
      case C_SWAP: {
        st_->close(HUB_FILE_LOG);
        if (!st_->promoteNew()) {
          if (st_->exists(HUB_FILE_LOG) && st_->open(HUB_FILE_LOG, false)) {
            newStale_ = true;  // the rename failed cleanly: lib.log is intact
            cPhase_ = C_IDLE;
            compactBackoff_ = true;
            compactRetryAt_ = now + HUB_COMPACT_QUIET_MS;
          } else {
            state_ = DB_FAILED;  // lib.log gone, lib.new not promoted: the next boot promotes it
          }
          break;
        }
        if (!st_->open(HUB_FILE_LOG, false)) {
          state_ = DB_FAILED;
          break;
        }
        ckCur_ = (uint8_t)(ckCur_ ^ 1);
        gen_++;
        logBytes_ = cNewBytes_;
        firstOff_ = HUB_LOG_OVERHEAD + HUB_LOG_HEADER_PAYLOAD;
        recsInFile_ = cRecs_;
        nHoles_ = 0;
        appendHold_ = false;
        dirtyAppended_ = 0;
        flushFails_ = 0;
        headerDbId_ = cHeaderId_;
        headerOk_ = true;
        recoveryCompact_ = headerDbId_ != dbId_;
        compactWanted_ = false;
        compactBackoff_ = false;
        runtimeCorrupt_ = false;
        compactions_++;
        cPhase_ = C_IDLE;
        winValid_ = false;
        refreshUsage();
        break;
      }
      default:
        cPhase_ = C_IDLE;
        break;
    }
    useWindow(io_, ioCap_);
  }

  void dropIfCurrent(uint32_t seq, const Key& k) {
    uint32_t lo, hi;
    hashParts(k, &lo, &hi);
    uint32_t* e = find(lo, hi);
    if (e && e[2] != 0 && (e[2] & HUBDB_REF_SEQ) == seq) {
      markDead(e);
      evictions_--;  // not an eviction
    }
  }

  void compactFail(uint32_t now) {
    st_->close(HUB_FILE_NEW);
    newStale_ = true;
    cPhase_ = C_IDLE;
    compactBackoff_ = true;
    compactRetryAt_ = now + HUB_COMPACT_QUIET_MS;
    flushErrors_++;
  }

  // flush(force) while compacting: lib.log is still the log; lib.new is dropped (removed at the
  // next flash-gated step or at boot).
  void abortCompaction() {
    st_->close(HUB_FILE_NEW);
    newStale_ = true;
    cPhase_ = C_IDLE;
  }

  // ---- sync_reset wipe (flash gate) ------------------------------------------------------------
  void doReset(uint32_t now) {
    st_->close(HUB_FILE_NEW);
    st_->close(HUB_FILE_LOG);
    cPhase_ = C_IDLE;
    newStale_ = false;
    const Id8 id = isZero(resetId_) ? randomId() : resetId_;
    formatEpochS_ = lastWallS_;
    if (!st_->wipe() || !writeFreshLog(id)) {
      resetRetryAt_ = now + 1000;
      flushErrors_++;
      return;
    }
    sortedN_ = deadN_ = 0;
    pendN_ = 0;
    records_ = presences_ = tombstones_ = liveBytes_ = 0;
    lastSeq_ = durableHigh_ = 0;
    dirtyLen_ = dirtyAppended_ = 0;
    nHoles_ = 0;
    ckN_[0] = ckN_[1] = 0;
    ckK_[0] = ckK_[1] = HUBDB_CK_K0;
    appendHold_ = recoveryCompact_ = compactWanted_ = compactBackoff_ = runtimeCorrupt_ = false;
    flushFails_ = 0;
    cNewBytes_ = 0;
    gen_++;
    dbId_ = id;
    clearPeers();
    nvsDbDirty_ = true;
    nvsLive_ = 0;
    nvsLive0Dirty_ = true;
    if (full_ || repull_) repullNeeded_ = true;
    full_ = repull_ = false;
    nvsFlagsDirty_ = true;
    refreshUsage();
    state_ = DB_READY;
    writeNvs(now, false);
  }
};

}  // namespace mmsync
