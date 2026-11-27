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
// that fixes it, so the board turns modem sleep off by itself when it looks like the cause; the
// rules are in btsleep_guard.h, host-tested):
//   NVS "mm"/"radioSleep" (u8): 1 = on (also when missing), 0 = off (the app's set_radio_sleep),
//   2 = off by the board. Read once at boot, before the controller starts; it only changes there.
//   - Off by the board when, with modem sleep on: the previous boot ended in a crash (panic or
//     watchdog reset); BTS_NOLINK_BOOTS boots in a row never had a phone link (a radio that
//     cannot advertise or accept a link: RST a few times and the next boot starts without it);
//     the controller refused to start with it (the start is retried without); the NimBLE host
//     lost the controller (an HCI command timed out, a hardware error: it resets the stack); or
//     BTS_TRIP_LINKS links in a row (within BTS_TRIP_WINDOW_MS) ended in a radio failure
//     (supervision timeout, failed establishment, LL response timeout, missed instant, MIC
//     failure) less than BTS_SHORT_LINK_MS after they began. A link that lasted BTS_SHORT_LINK_MS
//     or more clears the count. After a trip loop() restarts the board as soon as no phone is
//     linked and nothing runs, else the next boot applies it (it is stored at once).
//     NVS "mm"/"rsNoLink" (u8) holds the no-link boot count: +1 at a boot with modem sleep on,
//     0 at its first link.
//   - set_radio_sleep {"enabled":bool} stores 1 / 0; the board restarts (after the app's STATUS
//     read) when the radio has to change. STATUS "radioSleep": 0 / 2 while it is off.
//   Images without the wrap (or with MM_BT_MODEM_SLEEP 0) never read or write either key.
//
// The classic ESP32 is untouched: its core already runs modem sleep (ORIG mode).
#pragma once

#include <esp_system.h>
#include "board.h"
#include "btsleep_guard.h"

#ifndef MM_BT_MODEM_SLEEP
#define MM_BT_MODEM_SLEEP 1
#endif

#if MM_HELTEC_V3 && defined(CONFIG_IDF_TARGET_ESP32S3)

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <Preferences.h>
#include <esp_bt.h>

static_assert(BTS_HS_HCI_BASE == BLE_HS_ERR_HCI_BASE, "btsRadioFailure() decodes NimBLE's HCI reasons");

static const char*    BTS_NVS_NAMESPACE   = "mm";          // the board's settings (power.h too)
static const char*    BTS_NVS_KEY         = "radioSleep";
static const char*    BTS_NVS_KEY_NOLINK  = "rsNoLink";    // boots in a row with modem sleep on, no link

static volatile bool gBtModemSleep = false;     // modem sleep is on now (STATUS "btSleep")
static volatile bool gBtWrapRan = false;        // linked with the wrap: the setting exists
static volatile bool gBtInitRetried = false;    // the controller refused to start with sleep on
static uint8_t       gBtSleepCfg = BTS_CFG_ON;  // the stored setting (loop() / setup only)
static bool          gBtsBootCounted = false;   // this boot is in "rsNoLink" until its first link

// The radio-failure guard (NimBLE host task writes, loop() reads gBtsTrip).
static BtsGuard                      gBtsGuard;
static volatile bool                 gBtsTrip = false;
static struct ble_gap_event_listener gBtsListener;
static ble_hs_reset_fn*              gBtsPrevReset = nullptr;  // NimBLEDevice::onReset

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
  // Never lose Bluetooth over it: start the controller the usual way. In IDF 4.4.7's S3 init the
  // failures that depend on sleep (the wakeup semaphore, the controller library's init) take its
  // error path, which frees everything and returns to IDLE, so a second call starts clean; the
  // others fail the same way without sleep (then NimBLE aborts: the crash rule, next boot).
  if (want && err != ESP_OK) {
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

// Linked with the wrap: __real_esp_bt_controller_init is the controller's init; without it, an
// unresolved weak reference (0). Known before NimBLE starts (gBtWrapRan only after).
static inline bool btsWrapLinked() { return &__real_esp_bt_controller_init != nullptr; }

// NVS: the setting and the no-link boot count, each written only when it changes.
static void btsStore(uint8_t cfg, uint8_t noLink) {
  Preferences prefs;
  if (prefs.begin(BTS_NVS_NAMESPACE, false)) {
    if (prefs.getUChar(BTS_NVS_KEY, BTS_CFG_ON) != cfg) prefs.putUChar(BTS_NVS_KEY, cfg);
    if (prefs.getUChar(BTS_NVS_KEY_NOLINK, 0) != noLink) prefs.putUChar(BTS_NVS_KEY_NOLINK, noLink);
    prefs.end();
  }
}

// setup(), before NimBLEDevice::init(): the stored setting, the crash and no-link boot rules.
static void btSleepBegin(esp_reset_reason_t reason) {
  if (!MM_BT_MODEM_SLEEP || !btsWrapLinked()) return;  // no setting in this image: NVS untouched
  uint8_t cfg = BTS_CFG_ON, noLink = 0;
  Preferences prefs;
  if (prefs.begin(BTS_NVS_NAMESPACE, true)) {  // fails (nothing stored yet) on a fresh board
    cfg = prefs.getUChar(BTS_NVS_KEY, BTS_CFG_ON);
    noLink = prefs.getUChar(BTS_NVS_KEY_NOLINK, 0);
    prefs.end();
  }
  const bool crashed = reason == ESP_RST_PANIC || reason == ESP_RST_INT_WDT || reason == ESP_RST_TASK_WDT ||
                       reason == ESP_RST_WDT;
  const BtsBoot b = btsBootRule(cfg, noLink, crashed, true);
  if (b.cfg != cfg || b.noLink != noLink) btsStore(b.cfg, b.noLink);
  gBtSleepCfg = b.cfg;
  gBtsBootCounted = b.counted;
}

static int btsGapEvent(struct ble_gap_event* ev, void* arg) {
  (void)arg;
  if (!gBtModemSleep) return 0;
  if (ev->type == BLE_GAP_EVENT_CONNECT) {
    if (ev->connect.status == 0) gBtsGuard.onConnect(ev->connect.conn_handle, millis());
  } else if (ev->type == BLE_GAP_EVENT_DISCONNECT) {
    if (gBtsGuard.onDisconnect(ev->disconnect.conn.conn_handle, ev->disconnect.reason, millis())) {
      gBtsTrip = true;  // taken (and cleared) by loop()'s btSleepTakeTrip()
    }
  }
  return 0;
}

// NimBLE host task: the host lost the controller and resets the stack (every link ends with the
// reset's reason). With modem sleep on that is the radio failing.
static void btsHostReset(int reason) {
  if (gBtsPrevReset) gBtsPrevReset(reason);
  if (gBtModemSleep) gBtsTrip = true;
}

// setup(), after NimBLEDevice::init() and before advertising starts (no GAP event yet).
static void btSleepStart() {
  if (gBtInitRetried && gBtSleepCfg == BTS_CFG_ON) {  // the controller refused modem sleep
    gBtSleepCfg = BTS_CFG_OFF_AUTO;
    gBtsBootCounted = false;
    btsStore(gBtSleepCfg, 0);
  }
  if (gBtModemSleep) {
    gBtsGuard.reset();
    ble_gap_event_listener_register(&gBtsListener, btsGapEvent, nullptr);
    gBtsPrevReset = ble_hs_cfg.reset_cb;  // set by NimBLEDevice::init()
    __sync_synchronize();                 // stored before the host task can call the new one
    ble_hs_cfg.reset_cb = btsHostReset;
  }
}

// loop(), once a phone linked this boot: the radio works (the no-link boot count starts again).
static void btSleepLinked() {
  if (!gBtsBootCounted) return;
  gBtsBootCounted = false;
  btsStore(gBtSleepCfg, 0);
}

// loop(): true once the guard turned modem sleep off this boot (stored at once; restart pending).
// One trip is taken once: a later set_radio_sleep ON (still in this boot) is not undone by it.
static bool btSleepTakeTrip() {
  if (!gBtsTrip) return false;
  gBtsTrip = false;
  if (gBtSleepCfg != BTS_CFG_ON) return false;  // already off (the user chose so meanwhile)
  gBtSleepCfg = BTS_CFG_OFF_AUTO;
  gBtsBootCounted = false;
  btsStore(gBtSleepCfg, 0);
  return true;
}

// loop(): the app's set_radio_sleep. Stores it (the no-link count starts again); true when the
// radio has to change (restart).
static bool btSleepSet(bool on) {
  gBtSleepCfg = on ? BTS_CFG_ON : BTS_CFG_OFF_USER;
  gBtsBootCounted = false;
  btsStore(gBtSleepCfg, 0);
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
static inline void btSleepLinked() {}
static inline bool btSleepTakeTrip() { return false; }
static inline bool btSleepSet(bool) { return false; }
static inline bool mmBtModemSleep() { return false; }
static inline bool mmBtSleepAvailable() { return false; }
static inline uint8_t mmBtSleepOffReason() { return 0; }

#endif
