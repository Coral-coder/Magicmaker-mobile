// MagicMaker sync hub, phase P2: HubWallClock, the hub's wall-clock estimate
// (docs/SYNC_P2_FIRMWARE_PLAN.md §5.9; SYNC_PROTOCOL.md §7; spec §3.11).
//
// The hub has no RTC. Every member phone tells it the time: HELLO clockMs when its session reaches
// AUTHED, and the ts of each DIRECT HB. Per phone (up to HUB_CLOCK_PHONES) it keeps the offset
// phoneMs - mono and when it was seen. wall(now) = mono(now) + median(offsets seen in the last
// 6 h); with no recent offset the last one observed is used, so once learned the time is never
// "unknown" again. Two values: their mean; more: the middle one (the mean of the two middle ones
// for an even count).
//
// skewed(): the recent member clocks differ by more than 5 min (HB state bit 10); it clears again
// at or below 1 min (hysteresis), evaluated on every observe().
//
// mono is millis(), which wraps after 49 days: it is extended to 64 bits from the deltas between
// calls (every HB round calls in, far more often than once per 24 days).
//
// Pure C++11, no heap, no Arduino dependency.
#pragma once

#include "hub_ports.h"

namespace mmsync {

static const uint8_t HUB_CLOCK_PHONES = 4;
static const uint32_t HUB_CLOCK_RECENT_MS = 6UL * 3600UL * 1000UL;

class HubWallClock : public Clock {
 public:
  HubWallClock() { reset(); }

  void reset() {
    memset(phones_, 0, sizeof(phones_));
    hasLast_ = false;
    lastOffset_ = 0;
    skewed_ = false;
    monoInit_ = false;
    monoLast_ = 0;
    mono64_ = 0;
  }

  bool wallMs(uint32_t now, int64_t* out) override {
    const int64_t m = mono(now);
    if (!hasLast_) return false;
    int64_t off[HUB_CLOCK_PHONES];
    const uint8_t n = recentOffsets(m, off);
    const int64_t o = n ? median(off, n) : lastOffset_;
    *out = m + o;
    return true;
  }

  void observe(const Id8& phone, int64_t phoneMs, uint32_t now) override {
    if (phoneMs <= 0) return;
    const int64_t m = mono(now);
    Phone* p = find(phone);
    if (!p) p = alloc(phone);
    p->used = true;
    p->id = phone;
    p->offset = phoneMs - m;
    p->seenAt = m;
    lastOffset_ = p->offset;
    hasLast_ = true;
    int64_t off[HUB_CLOCK_PHONES];
    const uint8_t n = recentOffsets(m, off);
    if (n >= 2) {
      int64_t lo = off[0], hi = off[0];
      for (uint8_t i = 1; i < n; i++) {
        if (off[i] < lo) lo = off[i];
        if (off[i] > hi) hi = off[i];
      }
      const int64_t spread = hi - lo;
      if (spread > (int64_t)HUB_CLOCK_SKEW_SET_MS) skewed_ = true;
      if (spread <= (int64_t)HUB_CLOCK_SKEW_CLEAR_MS) skewed_ = false;
    } else {
      skewed_ = false;
    }
  }

  bool skewed() override { return skewed_; }

  bool known() const { return hasLast_; }

 private:
  struct Phone {
    bool used;
    Id8 id;
    int64_t offset;
    int64_t seenAt;
  };

  int64_t mono(uint32_t now) {
    if (!monoInit_) {
      monoInit_ = true;
      monoLast_ = now;
      mono64_ = now;
    } else {
      mono64_ += (uint32_t)(now - monoLast_);
      monoLast_ = now;
    }
    return mono64_;
  }

  Phone* find(const Id8& id) {
    for (uint8_t i = 0; i < HUB_CLOCK_PHONES; i++)
      if (phones_[i].used && phones_[i].id == id) return &phones_[i];
    return NULL;
  }

  Phone* alloc(const Id8& id) {
    Phone* pick = &phones_[0];
    for (uint8_t i = 0; i < HUB_CLOCK_PHONES; i++) {
      if (!phones_[i].used) {
        pick = &phones_[i];
        break;
      }
      if (phones_[i].seenAt < pick->seenAt) pick = &phones_[i];
    }
    memset(pick, 0, sizeof(*pick));
    pick->id = id;
    return pick;
  }

  uint8_t recentOffsets(int64_t m, int64_t* out) const {
    uint8_t n = 0;
    for (uint8_t i = 0; i < HUB_CLOCK_PHONES; i++) {
      if (!phones_[i].used) continue;
      if (m - phones_[i].seenAt > (int64_t)HUB_CLOCK_RECENT_MS) continue;
      out[n++] = phones_[i].offset;
    }
    return n;
  }

  static int64_t median(int64_t* v, uint8_t n) {
    for (uint8_t i = 1; i < n; i++) {  // insertion sort, n <= 4
      const int64_t x = v[i];
      int j = i - 1;
      while (j >= 0 && v[j] > x) {
        v[j + 1] = v[j];
        j--;
      }
      v[j + 1] = x;
    }
    if (n & 1) return v[n / 2];
    const int64_t a = v[n / 2 - 1], b = v[n / 2];
    return a + (b - a) / 2;  // no overflow for offsets of the same order
  }

  Phone phones_[HUB_CLOCK_PHONES];
  bool hasLast_;
  int64_t lastOffset_;
  bool skewed_;
  bool monoInit_;
  uint32_t monoLast_;
  int64_t mono64_;
};

}  // namespace mmsync
