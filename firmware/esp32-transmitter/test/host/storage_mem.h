// MemStorage: an in-memory Storage for the hub DB host tests (docs/SYNC_P2_FIRMWARE_PLAN.md §4.11),
// with power-loss, tear, corruption and failure injection and a flash-gate violation counter.
//
// Model (LittleFS-like): per file a durable image and a volatile tail. append() adds to the tail,
// sync() and close() move it into the image (lfs_file_close syncs), a crash drops / keeps / tears
// the tails. open(create) of a missing file, remove, promoteNew and wipe are durable at once.
// promoteNew() is one atomic rename, or (fallbackPromote) remove + rename with an optional crash
// in between.
//
// Every mutating call while the attached gate forbids flash work (timed job, OTA, a command
// waiting, or msUntilDue < 200 ms — the weakest gap the DB may ever use) counts as a violation,
// unless allowUngated is set (flush(now, true)). Tests assert violations == 0.
//
// Host only (C++11 clean); PlatformIO never compiles test/host headers on their own.
#pragma once
#if !defined(ARDUINO)

#include <stdint.h>
#include <string.h>

#include <vector>

#include "../../hub_ports.h"

namespace mmsync_test {

class MemStorage : public mmsync::Storage {
 public:
  enum Op { OP_OPEN = 0, OP_APPEND, OP_SYNC, OP_REMOVE, OP_PROMOTE, OP_READ, OP_WIPE, OP_COUNT };
  enum CrashMode { CRASH_DROP_TAIL = 0, CRASH_KEEP_TAIL, CRASH_TEAR_TAIL };

  MemStorage()
      : mutations(0),
        violations(0),
        reads(0),
        misuse(0),
        allowUngated(false),
        fallbackPromote(false),
        crashInPromote(false),
        mounted_(true),
        dead_(false),
        total_(1441792),
        gate_(NULL) {
    for (int i = 0; i < OP_COUNT; i++) {
      fail_[i] = 0;
      partial_[i] = 0;
    }
  }

  // ---- test controls -------------------------------------------------------------------------
  uint32_t mutations;   // every durable or volatile change
  uint32_t violations;  // mutations while the gate forbids flash work
  uint32_t reads;
  uint32_t misuse;      // contract misuse (promote / remove of an open file, ...)
  bool allowUngated;    // the test calls flush(now, true): mutations are allowed
  bool fallbackPromote; // promoteNew() = remove(LOG) then rename (a VFS that does not replace)
  bool crashInPromote;  // with fallbackPromote: "power fails" after the remove (until crash())

  void attachGate(mmsync::TxGate* g) { gate_ = g; }
  void setTotal(uint32_t bytes) { total_ = bytes; }
  void setMounted(bool m) { mounted_ = m; }
  // The next `count` calls of op fail. OP_APPEND: `partial` bytes land before the failure.
  void failNext(Op op, int count = 1, uint32_t partial = 0) {
    fail_[op] = count;
    partial_[op] = partial;
  }
  // Power loss: every handle is closed; each tail is dropped, kept, or torn after tearAt bytes.
  void crash(CrashMode mode, uint32_t tearAt = 0) {
    for (int f = 0; f < mmsync::HUB_FILE_COUNT; f++) {
      File& x = files_[f];
      if (mode == CRASH_KEEP_TAIL) x.img.insert(x.img.end(), x.tail.begin(), x.tail.end());
      if (mode == CRASH_TEAR_TAIL) {
        const size_t n = tearAt < x.tail.size() ? tearAt : x.tail.size();
        x.img.insert(x.img.end(), x.tail.begin(), x.tail.begin() + (long)n);
      }
      x.tail.clear();
      x.open = false;
    }
    dead_ = false;
    crashInPromote = false;
  }
  bool fileExists(uint8_t f) const { return files_[f].exists; }
  bool fileOpen(uint8_t f) const { return files_[f].open; }
  // The durable bytes (tests truncate / corrupt them while the DB is "off").
  std::vector<uint8_t>& image(uint8_t f) { return files_[f].img; }
  size_t tailBytes(uint8_t f) const { return files_[f].tail.size(); }
  void setFile(uint8_t f, const std::vector<uint8_t>& bytes) {
    files_[f].exists = true;
    files_[f].img = bytes;
    files_[f].tail.clear();
  }
  void deleteFile(uint8_t f) {
    files_[f].exists = false;
    files_[f].open = false;
    files_[f].img.clear();
    files_[f].tail.clear();
  }

  // ---- Storage -------------------------------------------------------------------------------
  bool mounted() override { return mounted_; }

  bool exists(uint8_t f) override { return f < mmsync::HUB_FILE_COUNT && files_[f].exists; }

  bool open(uint8_t f, bool create) override {
    if (f >= mmsync::HUB_FILE_COUNT || dead_ || failing(OP_OPEN)) return false;
    File& x = files_[f];
    if (x.open) return true;
    if (!x.exists) {
      if (!create) return false;
      mutate();
      x.exists = true;
      x.img.clear();
      x.tail.clear();
    }
    x.open = true;
    return true;
  }

  void close(uint8_t f) override {
    if (f >= mmsync::HUB_FILE_COUNT) return;
    File& x = files_[f];
    if (!x.open) return;
    if (!x.tail.empty() && !dead_) {
      mutate();
      commit(x);
    }
    x.open = false;
  }

  int32_t size(uint8_t f) override {
    if (f >= mmsync::HUB_FILE_COUNT || !files_[f].open) return -1;
    return (int32_t)(files_[f].img.size() + files_[f].tail.size());
  }

  int32_t read(uint8_t f, uint32_t off, uint8_t* buf, uint32_t n) override {
    if (f >= mmsync::HUB_FILE_COUNT || !files_[f].open || dead_ || failing(OP_READ)) return -1;
    reads++;
    const File& x = files_[f];
    const size_t total = x.img.size() + x.tail.size();
    if (off >= total) return 0;
    if (n > total - off) n = (uint32_t)(total - off);
    for (uint32_t i = 0; i < n; i++) {
      const size_t p = off + i;
      buf[i] = p < x.img.size() ? x.img[p] : x.tail[p - x.img.size()];
    }
    return (int32_t)n;
  }

  bool append(uint8_t f, const uint8_t* data, uint32_t n) override {
    if (f >= mmsync::HUB_FILE_COUNT || !files_[f].open || dead_) return false;
    File& x = files_[f];
    if (failing(OP_APPEND)) {
      const uint32_t part = partial_[OP_APPEND] < n ? partial_[OP_APPEND] : n;
      if (part) {
        mutate();
        x.tail.insert(x.tail.end(), data, data + part);
      }
      return false;
    }
    mutate();
    x.tail.insert(x.tail.end(), data, data + n);
    return true;
  }

  bool sync(uint8_t f) override {
    if (f >= mmsync::HUB_FILE_COUNT || !files_[f].open || dead_ || failing(OP_SYNC)) return false;
    File& x = files_[f];
    if (!x.tail.empty()) {
      mutate();
      commit(x);
    }
    return true;
  }

  bool remove(uint8_t f) override {
    if (f >= mmsync::HUB_FILE_COUNT || dead_ || failing(OP_REMOVE)) return false;
    File& x = files_[f];
    if (x.open) {
      misuse++;
      x.open = false;
    }
    if (x.exists) {
      mutate();
      deleteFile(f);
    }
    return true;
  }

  bool promoteNew() override {
    if (dead_ || failing(OP_PROMOTE)) return false;
    File& lg = files_[mmsync::HUB_FILE_LOG];
    File& nw = files_[mmsync::HUB_FILE_NEW];
    if (lg.open || nw.open) {
      misuse++;
      return false;
    }
    if (!nw.exists) return false;
    if (fallbackPromote) {
      if (lg.exists) {
        mutate();
        deleteFile(mmsync::HUB_FILE_LOG);
      }
      if (crashInPromote) {
        dead_ = true;  // power fails between the remove and the rename
        return false;
      }
    }
    mutate();
    lg.exists = true;
    lg.img = nw.img;
    lg.tail.clear();
    deleteFile(mmsync::HUB_FILE_NEW);
    return true;
  }

  bool usage(uint32_t* totalBytes, uint32_t* usedBytes) override {
    if (!total_) return false;
    uint32_t used = 2u * 4096u;
    for (int f = 0; f < mmsync::HUB_FILE_COUNT; f++) {
      const size_t s = files_[f].img.size() + files_[f].tail.size();
      if (files_[f].exists) used += (uint32_t)((s + 4095u) / 4096u * 4096u);
    }
    *totalBytes = total_;
    *usedBytes = used;
    return true;
  }

  bool wipe() override {
    if (dead_ || failing(OP_WIPE)) return false;
    for (int f = 0; f < mmsync::HUB_FILE_COUNT; f++) {
      if (files_[f].exists) mutate();
      deleteFile((uint8_t)f);
    }
    return true;
  }

 private:
  struct File {
    File() : exists(false), open(false) {}
    bool exists;
    bool open;
    std::vector<uint8_t> img;
    std::vector<uint8_t> tail;
  };

  File files_[mmsync::HUB_FILE_COUNT];
  bool mounted_;
  bool dead_;
  uint32_t total_;
  mmsync::TxGate* gate_;
  int fail_[OP_COUNT];
  uint32_t partial_[OP_COUNT];

  bool failing(Op op) {
    if (fail_[op] <= 0) return false;
    fail_[op]--;
    return true;
  }

  static void commit(File& x) {
    x.img.insert(x.img.end(), x.tail.begin(), x.tail.end());
    x.tail.clear();
  }

  void mutate() {
    mutations++;
    if (allowUngated || !gate_) return;
    mmsync::TxGate& g = *gate_;
    if (g.timedJob() || g.otaBusy() || !g.cmdQueueEmpty() ||
        g.msUntilDue(0) < mmsync::HUB_GATE_STARVED_GAP_MS)
      violations++;
  }
};

}  // namespace mmsync_test

#endif  // !ARDUINO
