// MemKv: an in-memory KvStore (NVS namespace "mmsync") for the hub DB host tests
// (docs/SYNC_P2_FIRMWARE_PLAN.md §4.11): atomic puts, write counters (total and per key), failure
// injection and a flash-gate violation counter (same rule as MemStorage). NVS writes are atomic,
// so a crash changes nothing: crash() is a no-op kept for symmetry.
//
// Host only (C++11 clean).
#pragma once
#if !defined(ARDUINO)

#include <stdint.h>
#include <string.h>

#include <map>
#include <string>
#include <vector>

#include "../../hub_ports.h"

namespace mmsync_test {

class MemKv : public mmsync::KvStore {
 public:
  MemKv() : writes(0), violations(0), allowUngated(false), fail_(0), gate_(NULL) {}

  uint32_t writes;
  uint32_t violations;
  bool allowUngated;
  std::map<std::string, int> keyWrites;

  void attachGate(mmsync::TxGate* g) { gate_ = g; }
  void failNext(int count = 1) { fail_ = count; }
  void crash() {}
  bool has(const char* key) const { return blobs_.count(key) || u32s_.count(key); }
  std::vector<uint8_t> blob(const char* key) const {
    std::map<std::string, std::vector<uint8_t> >::const_iterator it = blobs_.find(key);
    return it == blobs_.end() ? std::vector<uint8_t>() : it->second;
  }
  uint32_t u32(const char* key, uint32_t dflt = 0) const {
    std::map<std::string, uint32_t>::const_iterator it = u32s_.find(key);
    return it == u32s_.end() ? dflt : it->second;
  }
  // Direct edits while the DB is "off" (no counters).
  void putBlob(const char* key, const std::vector<uint8_t>& v) {
    u32s_.erase(key);
    blobs_[key] = v;
  }
  void putU32(const char* key, uint32_t v) {
    blobs_.erase(key);
    u32s_[key] = v;
  }
  void remove(const char* key) {
    blobs_.erase(key);
    u32s_.erase(key);
  }

  // ---- KvStore -------------------------------------------------------------------------------
  bool getBlob(const char* key, uint8_t* out, size_t cap, size_t* len) override {
    std::map<std::string, std::vector<uint8_t> >::const_iterator it = blobs_.find(key);
    if (it == blobs_.end() || it->second.size() > cap) return false;
    if (!it->second.empty()) memcpy(out, it->second.data(), it->second.size());
    *len = it->second.size();
    return true;
  }
  bool setBlob(const char* key, const uint8_t* data, size_t len) override {
    if (failing()) return false;
    mutate(key);
    u32s_.erase(key);
    blobs_[key] = std::vector<uint8_t>(data, data + len);
    return true;
  }
  bool getU32(const char* key, uint32_t* v) override {
    std::map<std::string, uint32_t>::const_iterator it = u32s_.find(key);
    if (it == u32s_.end()) return false;
    *v = it->second;
    return true;
  }
  bool setU32(const char* key, uint32_t v) override {
    if (failing()) return false;
    mutate(key);
    blobs_.erase(key);
    u32s_[key] = v;
    return true;
  }
  bool erase(const char* key) override {
    if (!has(key)) return true;  // like NvsKv: nothing to write
    if (failing()) return false;
    mutate(key);
    blobs_.erase(key);
    u32s_.erase(key);
    return true;
  }

 private:
  std::map<std::string, std::vector<uint8_t> > blobs_;
  std::map<std::string, uint32_t> u32s_;
  int fail_;
  mmsync::TxGate* gate_;

  bool failing() {
    if (fail_ <= 0) return false;
    fail_--;
    return true;
  }
  void mutate(const char* key) {
    writes++;
    keyWrites[key]++;
    if (allowUngated || !gate_) return;
    mmsync::TxGate& g = *gate_;
    if (g.timedJob() || g.otaBusy() || !g.cmdQueueEmpty() ||
        g.msUntilDue(0) < mmsync::HUB_GATE_STARVED_GAP_MS)
      violations++;
  }
};

}  // namespace mmsync_test

#endif  // !ARDUINO
