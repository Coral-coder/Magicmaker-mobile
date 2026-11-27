// The BLE modem-sleep safety net's rules (btsleep.h), plain C++ with no Arduino or NimBLE types so
// the host tests run them (test/host/test_relay.cc). btsleep.h feeds them NVS, the reset reason
// and the NimBLE GAP events, and acts on what they return.
#pragma once

#include <stdint.h>

// NVS "mm"/"radioSleep": the setting.
enum : uint8_t { BTS_CFG_OFF_USER = 0, BTS_CFG_ON = 1, BTS_CFG_OFF_AUTO = 2 };

static const uint32_t BTS_SHORT_LINK_MS  = 120000;        // a failure this soon after connecting counts
static const uint8_t  BTS_TRIP_LINKS     = 4;             // ... this many in a row turn modem sleep off
static const uint32_t BTS_TRIP_WINDOW_MS = 30UL * 60000;  // ... within this long of the first
static const uint8_t  BTS_MAX_TRACKED    = 4;             // links whose start time is kept
static const uint8_t  BTS_NOLINK_BOOTS   = 3;             // boots in a row with modem sleep on and no
                                                          // phone linking: the next one starts without it
static const int      BTS_HS_HCI_BASE    = 0x200;         // NimBLE's BLE_HS_ERR_HCI_BASE (checked in btsleep.h)

// What a boot runs and stores. cfg: the stored setting (anything else reads as on); noLink: the
// stored no-link boot count; crashed: the last boot ended in a panic or a watchdog reset; canSleep:
// this image can run modem sleep (linked with the wrap, MM_BT_MODEM_SLEEP on). Only a boot that
// starts with modem sleep on is counted (cleared again at its first link: btSleepLinked()).
struct BtsBoot {
  uint8_t cfg;     // the setting this boot (and what NVS holds after it)
  uint8_t noLink;  // the count NVS holds after it
  bool    counted; // this boot was added to the count
};

static inline BtsBoot btsBootRule(uint8_t cfg, uint8_t noLink, bool crashed, bool canSleep) {
  BtsBoot b;
  b.cfg = cfg > BTS_CFG_OFF_AUTO ? (uint8_t)BTS_CFG_ON : cfg;
  b.noLink = noLink;
  b.counted = false;
  if (!canSleep || b.cfg != BTS_CFG_ON) return b;  // nothing to guard: NVS is left as it is
  if (crashed || noLink >= BTS_NOLINK_BOOTS) {
    b.cfg = BTS_CFG_OFF_AUTO;
    b.noLink = 0;
  } else {
    b.noLink = (uint8_t)(noLink + 1);
    b.counted = true;
  }
  return b;
}

// A disconnect reason (NimBLE's: an HCI code is BTS_HS_HCI_BASE + code; host codes are below)
// that means the radio failed: supervision timeout, LL response timeout, a missed instant, MIC
// failure, a link that failed to be established. A clean end (0x13 remote user, 0x16 local) or a
// host code is not one.
static inline bool btsRadioFailure(int reason) {
  if (reason <= BTS_HS_HCI_BASE || reason > BTS_HS_HCI_BASE + 0xFF) return false;
  const int hci = reason - BTS_HS_HCI_BASE;
  return hci == 0x08 || hci == 0x22 || hci == 0x28 || hci == 0x3D || hci == 0x3E;
}

// The link guard: BTS_TRIP_LINKS links (within BTS_TRIP_WINDOW_MS of the first) that ended in a
// radio failure less than BTS_SHORT_LINK_MS after they began. A link that lasted longer clears the
// count; other short links change nothing. A link it did not see begin (more than BTS_MAX_TRACKED
// at once) counts as a long one. now: millis() (wraps).
struct BtsGuard {
  struct Link {
    uint16_t handle;
    uint32_t since;
  };
  Link     links[BTS_MAX_TRACKED];
  uint8_t  count;
  uint8_t  failures;
  uint32_t firstFailureMs;

  void reset() {
    count = 0;
    failures = 0;
    firstFailureMs = 0;
  }

  void onConnect(uint16_t handle, uint32_t now) {
    for (uint8_t i = 0; i < count; i++) {
      if (links[i].handle == handle) {  // a handle seen again without its end: starts afresh
        links[i].since = now;
        return;
      }
    }
    if (count < BTS_MAX_TRACKED) {
      links[count].handle = handle;
      links[count].since = now;
      count++;
    }
  }

  // True when this end trips the guard (the count starts again after it).
  bool onDisconnect(uint16_t handle, int reason, uint32_t now) {
    uint32_t lived = BTS_SHORT_LINK_MS;  // untracked: treated as a long link (never counts)
    for (uint8_t i = 0; i < count; i++) {
      if (links[i].handle == handle) {
        lived = now - links[i].since;
        links[i] = links[--count];
        break;
      }
    }
    if (lived >= BTS_SHORT_LINK_MS) {
      failures = 0;  // a link that held: the radio works
      return false;
    }
    if (!btsRadioFailure(reason)) return false;
    if (failures == 0 || now - firstFailureMs > BTS_TRIP_WINDOW_MS) {
      failures = 0;
      firstFailureMs = now;
    }
    if (++failures < BTS_TRIP_LINKS) return false;
    failures = 0;
    return true;
  }
};
