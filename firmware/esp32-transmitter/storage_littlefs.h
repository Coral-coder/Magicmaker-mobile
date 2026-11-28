// MagicMaker sync hub, phase P2 part 'db': the LittleFS mount and Storage::usage() on the target
// (docs/SYNC_P2_FIRMWARE_PLAN.md §4.1, §4.11; SYNC_HUB_SPEC.md amendment A1).
//
// LittleFS lives on the stock 'spiffs' data partition (no custom partitions.csv: OTA can never
// change a partition table). Everything else goes through the POSIX calls of PosixStorage over the
// esp_littlefs VFS at /littlefs. This and kv_nvs.h are the only db files with Arduino headers;
// the sketch includes them from the .ino only.
//
// First boot after the upgrade from 1.x: the partition was never formatted, so
// LittleFS.begin(true, ...) formats it once (up to a few seconds). It runs in setup() before
// NimBLEDevice::init, so no link or burst is affected.
#pragma once

#include <Arduino.h>
#include <LittleFS.h>

#include "hub_ports.h"
#include "storage_posix.h"

namespace mmsync {

// LittleFS.begin(true, "/littlefs", 10, "spiffs"). false: the mount failed and so did the format
// (the DB then starts DB_FAILED: no sync, transmit unaffected). *total: the file system size.
inline bool hubFsMount(uint32_t* total) {
  if (total) *total = 0;
  if (!LittleFS.begin(true, HUB_FS_BASE, HUB_FS_MAX_FILES, HUB_FS_PARTITION)) return false;
  if (total) *total = (uint32_t)LittleFS.totalBytes();
  return true;
}

class LittleFsStorage : public PosixStorage {
 public:
  LittleFsStorage() : PosixStorage(HUB_DIR_PATH), total_(0) {}

  // setup(): mount (formats once when needed) and create /littlefs/mm. false = DB_FAILED.
  bool begin() {
    if (!hubFsMount(&total_)) return false;
    return makeDir();
  }

  uint32_t totalBytes() const { return total_; }

  // LittleFS.totalBytes() / usedBytes(): walks the file system, so the DB calls it only at boot
  // and after a compaction.
  bool usage(uint32_t* totalBytes, uint32_t* usedBytes) override {
    const size_t t = LittleFS.totalBytes();
    if (t == 0) return false;
    *totalBytes = (uint32_t)t;
    *usedBytes = (uint32_t)LittleFS.usedBytes();
    return true;
  }

 private:
  uint32_t total_;
};

}  // namespace mmsync
