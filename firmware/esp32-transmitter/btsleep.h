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
// stay exactly as before (no modem sleep). STATUS "btSleep":true shows the wrap took effect.
// MM_BT_MODEM_SLEEP 0 keeps the wrapper but leaves the config untouched.
//
// The classic ESP32 is untouched: its core already runs modem sleep (ORIG mode).
#pragma once

#include "board.h"

#if MM_HELTEC_V3 && defined(CONFIG_IDF_TARGET_ESP32S3)

#include <esp_bt.h>

#ifndef MM_BT_MODEM_SLEEP
#define MM_BT_MODEM_SLEEP 1
#endif

static volatile bool gBtModemSleep = false;  // STATUS "btSleep"

extern "C" esp_err_t __real_esp_bt_controller_init(esp_bt_controller_config_t* cfg) __attribute__((weak));
extern "C" esp_err_t __wrap_esp_bt_controller_init(esp_bt_controller_config_t* cfg) {
#if MM_BT_MODEM_SLEEP
  cfg->sleep_mode = ESP_BT_SLEEP_MODE_1;            // PHY/RF off between radio events
  cfg->sleep_clock = ESP_BT_SLEEP_CLOCK_MAIN_XTAL;  // the only LP clock without PM in this core
#endif
  const esp_err_t err = __real_esp_bt_controller_init(cfg);
  gBtModemSleep = MM_BT_MODEM_SLEEP && err == ESP_OK;
  return err;
}

static inline bool mmBtModemSleep() { return gBtModemSleep; }

#else

static inline bool mmBtModemSleep() { return false; }

#endif
