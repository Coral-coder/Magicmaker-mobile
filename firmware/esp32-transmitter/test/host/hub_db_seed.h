// hubDbSeed(): writes a hub library store (lib.log + NVS "mmsync") from a node's at-rest state, so a
// HubDbImpl begin() on that Storage / KvStore comes up with exactly those entries, dbId, group,
// peers and flags (docs/SYNC_P2_FIRMWARE_PLAN.md §3.1, §5.13 "--real-db", §4.12 item 8).
//
//   HubDbSeed s = ...;                      // entries in any order, distinct seqs
//   hubDbSeed(storage, kv, s);              // then db.begin(cfg, now) and maintain() until ready()
//
// hubDbSeedTranscriptNode() fills it from a transcript's nodes.<H> object (tools/sync/README.md:
// dbId, groupId / groupKey, durableHigh, nextSyncSeq, ledger [{s, f, b, ...}], peers {id: {dbId,
// wm, excludeOk}}). An at-rest store holds only durable entries, so every ledger entry must have
// s <= durableHigh and nextSyncSeq must be durableHigh + 1 (all six transcripts do); otherwise it
// returns false and says why.
//
// Host only (C++11 clean; the JSON helper throws std::runtime_error on malformed input like
// json_mini.hpp).
#pragma once
#if !defined(ARDUINO)

#include <stdint.h>
#include <string.h>

#include <string>
#include <vector>

#include "../../hub_db.h"
#include "../../hub_ports.h"
#include "json_mini.hpp"

namespace mmsync_test {

struct HubDbSeedEntry {
  uint32_t seq;
  mmsync::Id8 syncFrom;  // all zero: none
  const uint8_t* body;   // the canonical body (not validated here)
  uint16_t bodyLen;
};

struct HubDbSeed {
  mmsync::Id8 dbId;
  mmsync::GroupState group;
  const HubDbSeedEntry* entries;
  size_t nEntries;
  const mmsync::HubPeerRecord* peers;
  uint8_t nPeers;
  uint32_t formatEpochS;
  uint32_t flags;      // NVS "full" (HUB_FLAG_*); 0: not written
  uint32_t liveHigh;   // NVS "live"; 0: not written
};

inline HubDbSeed hubDbSeedEmpty() {
  HubDbSeed s;
  memset(&s, 0, sizeof(s));
  return s;
}

// Replaces whatever the storage and NVS hold. false: storage error or bad input (duplicate seqs,
// a seq of 0 or above HUB_SEQ_MAX, an oversized body).
inline bool hubDbSeed(mmsync::Storage& st, mmsync::KvStore& kv, const HubDbSeed& s) {
  using namespace mmsync;
  st.close(HUB_FILE_LOG);
  st.close(HUB_FILE_NEW);
  if (!st.remove(HUB_FILE_NEW) || !st.remove(HUB_FILE_LOG)) return false;
  if (!st.open(HUB_FILE_LOG, true)) return false;
  uint8_t buf[HUB_LOG_OVERHEAD + HUB_LOG_MAX_PAYLOAD];
  size_t n = hubLogEncodeHeader(buf, sizeof(buf), s.dbId, s.formatEpochS);
  if (!st.append(HUB_FILE_LOG, buf, (uint32_t)n)) return false;
  uint32_t prev = 0;
  for (size_t k = 0; k < s.nEntries; k++) {
    // the entry with the smallest seq above prev (inputs are small: O(n^2) is fine)
    const HubDbSeedEntry* next = NULL;
    for (size_t i = 0; i < s.nEntries; i++) {
      const HubDbSeedEntry& e = s.entries[i];
      if (e.seq > prev && (!next || e.seq < next->seq)) next = &e;
    }
    if (!next || next->seq == 0 || next->seq > HUB_SEQ_MAX || next->bodyLen == 0 ||
        next->bodyLen > HUB_LOG_MAX_PAYLOAD)
      return false;
    n = hubLogEncode(buf, sizeof(buf), HUB_LOG_RECORD, next->seq, next->syncFrom, next->body,
                     next->bodyLen);
    if (!n || !st.append(HUB_FILE_LOG, buf, (uint32_t)n)) return false;
    prev = next->seq;
  }
  if (!st.sync(HUB_FILE_LOG)) return false;
  st.close(HUB_FILE_LOG);
  for (size_t i = 0; i < s.nEntries; i++)  // every seq used exactly once
    for (size_t j = i + 1; j < s.nEntries; j++)
      if (s.entries[i].seq == s.entries[j].seq) return false;

  if (!kv.setBlob(HUB_NVS_DB, s.dbId.b, 8)) return false;
  if (s.group.grouped) {
    uint8_t g[HUB_GROUP_BLOB];
    hubGroupBlobEncode(s.group, g);
    if (!kv.setBlob(HUB_NVS_GROUP, g, sizeof(g))) return false;
  } else if (!kv.erase(HUB_NVS_GROUP)) {
    return false;
  }
  if (s.nPeers) {
    uint8_t b[HUB_PEER_BLOB_MAX];
    const size_t len = hubPeersBlobEncode(s.peers, s.nPeers, b);
    if (!kv.setBlob(HUB_NVS_PEERS, b, len)) return false;
  } else if (!kv.erase(HUB_NVS_PEERS)) {
    return false;
  }
  if (s.flags ? !kv.setU32(HUB_NVS_FLAGS, s.flags) : !kv.erase(HUB_NVS_FLAGS)) return false;
  if (s.liveHigh ? !kv.setU32(HUB_NVS_LIVE, s.liveHigh) : !kv.erase(HUB_NVS_LIVE)) return false;
  return true;
}

// ---- from a transcript node (tools/sync/transcripts/*.json "nodes".<name>) ---------------------

inline std::vector<uint8_t> seedUnhex(const std::string& h) {
  std::vector<uint8_t> out;
  if (h.size() % 2) throw std::runtime_error("odd hex");
  for (size_t i = 0; i < h.size(); i += 2) {
    int v = 0;
    for (int k = 0; k < 2; k++) {
      const char c = h[i + (size_t)k];
      int d;
      if (c >= '0' && c <= '9') d = c - '0';
      else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
      else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
      else throw std::runtime_error("bad hex");
      v = v * 16 + d;
    }
    out.push_back((uint8_t)v);
  }
  return out;
}

inline mmsync::Id8 seedId8(const std::string& h) {
  const std::vector<uint8_t> b = seedUnhex(h);
  if (b.size() != 8) throw std::runtime_error("id8 size");
  return mmsync::makeId8(b.data());
}

// Seeds from a transcript node object. kind of every peer: 0 (transcripts do not record it).
inline bool hubDbSeedTranscriptNode(const jmini::Value& node, mmsync::Storage& st,
                                    mmsync::KvStore& kv, std::string* why) {
  using namespace mmsync;
  const uint32_t durableHigh = (uint32_t)node["durableHigh"].asInt();
  const uint32_t nextSyncSeq = (uint32_t)node["nextSyncSeq"].asInt();
  if (nextSyncSeq != durableHigh + 1) {
    if (why) *why = "nextSyncSeq != durableHigh + 1: not an at-rest store";
    return false;
  }
  std::vector<std::vector<uint8_t> > bodies;
  std::vector<HubDbSeedEntry> entries;
  const jmini::Value& ledger = node["ledger"];
  bodies.reserve(ledger.size());
  uint32_t maxSeq = 0;
  for (size_t i = 0; i < ledger.size(); i++) {
    const jmini::Value& e = ledger[i];
    bodies.push_back(seedUnhex(e["b"].asStr()));
    HubDbSeedEntry x;
    x.seq = (uint32_t)e["s"].asInt();
    x.syncFrom = e["f"].isNull() ? zeroId8() : seedId8(e["f"].asStr());
    x.body = bodies.back().data();
    x.bodyLen = (uint16_t)bodies.back().size();
    if (x.seq > durableHigh) {
      if (why) *why = "a ledger entry above durableHigh: not an at-rest store";
      return false;
    }
    if (x.seq > maxSeq) maxSeq = x.seq;
    entries.push_back(x);
  }
  if (maxSeq != durableHigh) {
    if (why) *why = "the highest ledger seq != durableHigh (HubDb lastSeq = max seq in the log)";
    return false;
  }
  std::vector<HubPeerRecord> peers;
  const jmini::Value& pj = node["peers"];
  for (size_t i = 0; i < pj.o.size(); i++) {
    HubPeerRecord r;
    memset(&r, 0, sizeof(r));
    r.id = seedId8(pj.o[i].first);
    const jmini::Value& v = pj.o[i].second;
    r.dbId = seedId8(v["dbId"].asStr());
    r.wm = (uint32_t)v["wm"].asInt();
    r.excludeOk = v["excludeOk"].asBool();
    peers.push_back(r);
  }
  if (peers.size() > HUB_PEERS_MAX) {
    if (why) *why = "more than 8 peers";
    return false;
  }
  HubDbSeed s = hubDbSeedEmpty();
  s.dbId = seedId8(node["dbId"].asStr());
  const jmini::Value* gid = node.find("groupId");
  if (gid && !gid->isNull()) {
    s.group.grouped = true;
    s.group.id = seedId8(gid->asStr());
    const std::vector<uint8_t> key = seedUnhex(node["groupKey"].asStr());
    if (key.size() != 16) throw std::runtime_error("groupKey size");
    memcpy(s.group.key, key.data(), 16);
  }
  s.entries = entries.empty() ? NULL : entries.data();
  s.nEntries = entries.size();
  s.peers = peers.empty() ? NULL : peers.data();
  s.nPeers = (uint8_t)peers.size();
  if (!hubDbSeed(st, kv, s)) {
    if (why) *why = "storage / NVS write failed or bad seqs";
    return false;
  }
  return true;
}

}  // namespace mmsync_test

#endif  // !ARDUINO
