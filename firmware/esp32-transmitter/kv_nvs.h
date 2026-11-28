// MagicMaker sync hub, phase P2 part 'db': KvStore over Preferences, NVS namespace "mmsync"
// (docs/SYNC_P2_FIRMWARE_PLAN.md §4.1, §4.3). power.h and btsleep.h keep their own namespace "mm".
//
// The namespace is opened once (begin() in setup()) and stays open. Every put commits (NVS writes
// are atomic per key). Like storage_littlefs.h, this is a thin Arduino back-end the sketch
// includes from the .ino only.
#pragma once

#include <Arduino.h>
#include <Preferences.h>

#include "hub_ports.h"

namespace mmsync {

class NvsKv : public KvStore {
 public:
  NvsKv() : open_(false) {}

  bool begin() {
    if (!open_) open_ = prefs_.begin(HUB_NVS_NAMESPACE, false);
    return open_;
  }

  bool getBlob(const char* key, uint8_t* out, size_t cap, size_t* len) override {
    if (!open_ || prefs_.getType(key) != PT_BLOB) return false;
    const size_t n = prefs_.getBytesLength(key);
    if (n == 0 || n > cap) return false;
    if (prefs_.getBytes(key, out, cap) != n) return false;
    *len = n;
    return true;
  }

  bool setBlob(const char* key, const uint8_t* data, size_t len) override {
    return open_ && len > 0 && prefs_.putBytes(key, data, len) == len;
  }

  bool getU32(const char* key, uint32_t* v) override {
    if (!open_ || prefs_.getType(key) != PT_U32) return false;
    *v = prefs_.getUInt(key, 0);
    return true;
  }

  bool setU32(const char* key, uint32_t v) override {
    return open_ && prefs_.putUInt(key, v) == sizeof(uint32_t);
  }

  bool erase(const char* key) override {
    if (!open_) return false;
    if (!prefs_.isKey(key)) return true;  // never existed: gone
    return prefs_.remove(key);
  }

 private:
  Preferences prefs_;
  bool open_;
};

}  // namespace mmsync
