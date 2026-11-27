// BLE modem sleep on the Heltec V3 (ESP32-S3): the BT controller turns its PHY / RF off between
// radio events instead of idling with them on (estimated 3-10 mA of the ~35 mA base; unmeasured).
//
// Why a link-time wrap: NimBLE-Arduino 1.4.3's NimBLEDevice::init() builds the controller config
// from BT_CONTROLLER_INIT_CONFIG_DEFAULT() (sleep mode 0 in this core's sdkconfig) and calls
// esp_bt_controller_init() itself, so nothing can be set beforehand. Linking with
//   -Wl,--wrap=esp_bt_controller_init
// sends that call through __wrap_esp_bt_controller_init() below, which turns sleep mode 1 on with
// the main crystal as the sleep clock (the only one without power management in this core). The
// controller then wakes itself 2.5 ms before each radio event and never sleeps across gaps under
// 7.5 ms, so connection parameters, advertising intervals and send timing are unchanged.
//
// Without the flag nothing references the wrapper and --gc-sections drops it: Arduino IDE builds
// stay exactly as before (no modem sleep, no setting). STATUS "btSleep":true shows it is on.
// MM_BT_MODEM_SLEEP 0 keeps the wrapper but never turns sleep on.
//
// The setting and its safety net (a board whose radio misbehaves could not even take the update
// that fixes it, so the board turns modem sleep off by itself when it looks like the cause):
//   NVS "mm"/"radioSleep" (u8): 1 = on (also when missing), 0 = off (the app's set_radio_sleep),
//   2 = off by the board. Read once at boot, before the controller starts; it only changes there.
//   - Off by the board when, with modem sleep on: the previous boot ended in a crash (panic or
//     watchdog reset); the controller refused to start with it (the start is retried without);
//     or BTS_TRIP_LINKS links in a row (within BTS_TRIP_WINDOW_MS) ended in a radio failure
//     (supervision timeout, failed establishment, LL response timeout, MIC failure) less than
//     BTS_SHORT_LINK_MS after they began. A link that lasted BTS_SHORT_LINK_MS or more clears the
//     count. After a trip loop() restarts the board as soon as no phone is linked and nothing
//     runs, else the next boot applies it.
//   - set_radio_sleep {"enabled":bool} stores 1 / 0; the board restarts (after the app's STATUS
//     read) when the radio has to change. STATUS "radioSleep": 0 / 2 while it is off.
//
// The classic ESP32 is untouched: its core already runs modem sleep (ORIG mode).
#pragma once

#include <esp_system.h>
#include "board.h"

#ifndef MM_BT_MODEM_SLEEP
#define MM_BT_MODEM_SLEEP 1
#endif

enum : uint8_t { BTS_CFG_OFF_USER = 0, BTS_CFG_ON = 1, BTS_CFG_OFF_AUTO = 2 };

#if MM_HELTEC_V3 && defined(CONFIG_IDF_TARGET_ESP32S3)

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <Preferences.h>
#include <esp_bt.h>

static const char*    BTS_NVS_NAMESPACE   = "mm";          // the board's settings (power.h too)
static const char*    BTS_NVS_KEY         = "radioSleep";
static const uint32_t BTS_SHORT_LINK_MS   = 120000;        // a failure this soon after connecting counts
static const uint8_t  BTS_TRIP_LINKS      = 4;             // ... this many in a row turn modem sleep off
static const uint32_t BTS_TRIP_WINDOW_MS  = 30UL * 60000;  // ... within this long
static const uint8_t  BTS_MAX_TRACKED     = 4;             // links whose start time is kept

static volatile bool gBtModemSleep = false;     // modem sleep is on now (STATUS "btSleep")
static volatile bool gBtWrapRan = false;        // linked with the wrap: the setting exists
static volatile bool gBtInitRetried = false;    // the controller refused to start with sleep on
static uint8_t       gBtSleepCfg = BTS_CFG_ON;  // the stored setting (loop() / setup only)

// The radio-failure guard (NimBLE host task writes, loop() reads gBtsTrip).
struct BtsLink {
  uint16_t handle;
  uint32_t since;
};
static BtsLink                       gBtsLinks[BTS_MAX_TRACKED];
static uint8_t                       gBtsLinkCount = 0;
static uint8_t                       gBtsFailures = 0;
static uint32_t                      gBtsFirstFailureMs = 0;
static volatile bool                 gBtsTrip = false;
static struct ble_gap_event_listener gBtsListener;

extern "C" esp_err_t __real_esp_bt_controller_init(esp_bt_controller_config_t* cfg) __attribute__((weak));
extern "C" esp_err_t __wrap_esp_bt_controller_init(esp_bt_controller_config_t* cfg) {
  gBtWrapRan = true;
  const bool want = MM_BT_MODEM_SLEEP && gBtSleepCfg == BTS_CFG_ON;
  const uint8_t mode0 = cfg->sleep_mode, clock0 = cfg->sleep_clock;
  if (want) {
    cfg->sleep_mode = ESP_BT_SLEEP_MODE_1;            // PHY/RF off between radio events
    cfg->sleep_clock = ESP_BT_SLEEP_CLOCK_MAIN_XTAL;  // the only LP clock without PM in this core
  }
  esp_err_t err = __real_esp_bt_controller_init(cfg);
  if (want && err != ESP_OK) {  // never lose Bluetooth over it: start the controller the usual way
    cfg->sleep_mode = mode0;
    cfg->sleep_clock = clock0;
    err = __real_esp_bt_controller_init(cfg);
    gBtInitRetried = true;
    gBtModemSleep = false;
    return err;
  }
  gBtModemSleep = want && err == ESP_OK;
  return err;
}

static void btSleepStore(uint8_t cfg) {
  Preferences prefs;
  if (prefs.begin(BTS_NVS_NAMESPACE, false)) {
    if (prefs.getUChar(BTS_NVS_KEY, BTS_CFG_ON) != cfg) prefs.putUChar(BTS_NVS_KEY, cfg);
    prefs.end();
  }
}

// setup(), before NimBLEDevice::init(): the stored setting, and the crash rule.
static void btSleepBegin(esp_reset_reason_t reason) {
  uint8_t cfg = BTS_CFG_ON;
  Preferences prefs;
  if (prefs.begin(BTS_NVS_NAMESPACE, true)) {  // fails (nothing stored yet) on a fresh board
    cfg = prefs.getUChar(BTS_NVS_KEY, BTS_CFG_ON);
    prefs.end();
  }
  if (cfg > BTS_CFG_OFF_AUTO) cfg = BTS_CFG_ON;
  const bool crashed = reason == ESP_RST_PANIC || reason == ESP_RST_INT_WDT || reason == ESP_RST_TASK_WDT ||
                       reason == ESP_RST_WDT;
  if (MM_BT_MODEM_SLEEP && cfg == BTS_CFG_ON && crashed) {
    cfg = BTS_CFG_OFF_AUTO;
    btSleepStore(cfg);
  }
  gBtSleepCfg = cfg;
}

static int btsGapEvent(struct ble_gap_event* ev, void* arg) {
  (void)arg;
  if (!gBtModemSleep) return 0;
  const uint32_t now = millis();
  if (ev->type == BLE_GAP_EVENT_CONNECT) {
    if (ev->connect.status == 0 && gBtsLinkCount < BTS_MAX_TRACKED) {
      gBtsLinks[gBtsLinkCount].handle = ev->connect.conn_handle;
      gBtsLinks[gBtsLinkCount].since = now;
      gBtsLinkCount++;
    }
  } else if (ev->type == BLE_GAP_EVENT_DISCONNECT) {
    uint32_t lived = BTS_SHORT_LINK_MS;  // untracked: treated as a long link (never counts)
    for (uint8_t i = 0; i < gBtsLinkCount; i++) {
      if (gBtsLinks[i].handle == ev->disconnect.conn.conn_handle) {
        lived = now - gBtsLinks[i].since;
        gBtsLinks[i] = gBtsLinks[--gBtsLinkCount];
        break;
      }
    }
    const int r = ev->disconnect.reason;
    const bool radioFailure = r == BLE_HS_HCI_ERR(BLE_ERR_CONN_SPVN_TMO) ||
                              r == BLE_HS_HCI_ERR(BLE_ERR_CONN_ESTABLISHMENT) ||
                              r == BLE_HS_HCI_ERR(BLE_ERR_LMP_LL_RSP_TMO) || r == BLE_HS_HCI_ERR(BLE_ERR_CONN_TERM_MIC);
    if (lived >= BTS_SHORT_LINK_MS) {
      gBtsFailures = 0;  // a link that held: the radio works
    } else if (radioFailure) {
      if (gBtsFailures == 0 || now - gBtsFirstFailureMs > BTS_TRIP_WINDOW_MS) {
        gBtsFailures = 0;
        gBtsFirstFailureMs = now;
      }
      if (++gBtsFailures >= BTS_TRIP_LINKS) gBtsTrip = true;
    }
  }
  return 0;
}

// setup(), after NimBLEDevice::init() and before advertising starts.
static void btSleepStart() {
  if (gBtInitRetried && gBtSleepCfg == BTS_CFG_ON) {  // the controller refused modem sleep
    gBtSleepCfg = BTS_CFG_OFF_AUTO;
    btSleepStore(gBtSleepCfg);
  }
  if (gBtModemSleep) ble_gap_event_listener_register(&gBtsListener, btsGapEvent, nullptr);
}

// loop(): true once the guard turned modem sleep off this boot (stored at once; restart pending).
static bool btSleepTakeTrip() {
  if (!gBtsTrip || gBtSleepCfg != BTS_CFG_ON) return false;
  gBtSleepCfg = BTS_CFG_OFF_AUTO;
  btSleepStore(gBtSleepCfg);
  return true;
}

// loop(): the app's set_radio_sleep. Stores it; true when the radio has to change (restart).
static bool btSleepSet(bool on) {
  gBtSleepCfg = on ? BTS_CFG_ON : BTS_CFG_OFF_USER;
  btSleepStore(gBtSleepCfg);
  return on != (bool)gBtModemSleep;
}

static inline bool mmBtModemSleep() { return gBtModemSleep; }
static inline bool mmBtSleepAvailable() { return gBtWrapRan && MM_BT_MODEM_SLEEP; }
// STATUS "radioSleep" (RELAY_RSOFF_*: 0 none, 1 off by the user, 2 off by the board).
static inline uint8_t mmBtSleepOffReason() {
  if (!gBtWrapRan || !MM_BT_MODEM_SLEEP) return 0;
  if (gBtSleepCfg == BTS_CFG_OFF_USER) return 1;
  if (gBtSleepCfg == BTS_CFG_OFF_AUTO) return 2;
  return 0;
}

#else

static inline void btSleepBegin(esp_reset_reason_t) {}
static inline void btSleepStart() {}
static inline bool btSleepTakeTrip() { return false; }
static inline bool btSleepSet(bool) { return false; }
static inline bool mmBtModemSleep() { return false; }
static inline bool mmBtSleepAvailable() { return false; }
static inline uint8_t mmBtSleepOffReason() { return 0; }

#endif
