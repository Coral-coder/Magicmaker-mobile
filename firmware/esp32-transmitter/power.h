// Power of the Heltec WiFi LoRa 32 V3 build: the SX1262 LoRa radio put to sleep, and the
// battery (readings, capacity, charge left, expected runtime).
//
// Everything here runs in loop() context (setup() for loraSleep() / powerBegin()).
//
// Battery readings: the divider is switched on (ADC_CTRL, GPIO37) for ~10 ms per reading and
// off again, once a minute while the screen is dark and every 5 s while it is lit, so the
// charge and its slope are known even with the screen off. A reading is put off while a beacon
// is on air (its TX bursts dip the voltage), for at most BAT_DEFER_MAX_MS. battery_model.h turns
// the readings into %, charge left and the runtime.
//
// Capacity: BATTERY_MAH (top of the .ino) unless a capacity was picked on the screen (hold PRG
// on the DEVICE page); that choice is kept in NVS. It is the only thing this firmware writes to
// flash, and only when you change it.
#pragma once

#include "board.h"

#if MM_HELTEC_V3

#include <SPI.h>
#include <Preferences.h>
#include <esp_timer.h>
#include "battery_model.h"

// Put the SX1262 to sleep at boot (~0.6 mA saved: it otherwise idles in STDBY_RC). 0 leaves it
// untouched, as firmware 1.1 did.
#ifndef MM_LORA_SLEEP
#define MM_LORA_SLEEP 1
#endif

// ---- Tuning ----------------------------------------------------------------------------
static const uint32_t BAT_FIRST_MS          = 100;     // first reading after boot
static const uint32_t BAT_PERIOD_DARK_MS    = 60000;   // screen dark
static const uint32_t BAT_PERIOD_LIT_MS     = 5000;    // screen lit
static const uint32_t BAT_DEFER_MAX_MS      = 10000;   // a beacon on air delays a reading at most this long
static const uint32_t BAT_SETTLE_MS         = 10;      // divider switched on -> ADC reading
static const uint8_t  BAT_SAMPLES           = 8;
static const float    BAT_DIVIDER           = 4.9f * 1.045f;  // pin mV -> battery mV
static const int32_t  BAT_DIVIDER_ON_MV     = 1000;    // below this the divider was off (wrong ADC_CTRL level)
static const int32_t  BAT_MIN_MV            = 2500;    // plausible single-cell LiPo range
static const int32_t  BAT_MAX_MV            = 4600;
static const uint32_t BAT_CAP_SAVE_DELAY_MS = 3000;    // a picked capacity is saved this long after the last change
static const uint32_t LORA_BUSY_TIMEOUT_MS  = 30;

// Capacities the DEVICE page steps through (hold PRG).
static const uint16_t BATTERY_PRESETS_MAH[] = {400, 500, 1000, 1100, 2000, 3000, 5000};
static const uint8_t  BATTERY_PRESET_COUNT  = sizeof(BATTERY_PRESETS_MAH) / sizeof(BATTERY_PRESETS_MAH[0]);
static const char*    POWER_NVS_NAMESPACE   = "mm";
static const char*    POWER_NVS_CAP_KEY     = "batMah";

// ---- State (loop-owned) ----------------------------------------------------------------
static BatteryModel gBat;
static uint32_t gPwrBootMs      = 0;
static bool     gPwrLit         = false;    // screen lit at the last powerPoll()
// Divider: switched on by ADC_CTRL, LOW on V3.0/V3.1 and HIGH on V3.2. Try LOW first; if the
// reading is ~0 V the divider stayed off, so try the other level and remember the one that
// worked. Between readings the pin is released (input): the divider is off and draws nothing.
static int8_t   gBatOnLevel     = -1;       // ADC_CTRL level that switches the divider on; -1 unknown
static uint8_t  gBatLevel       = LOW;      // level under test
static uint8_t  gBatTries       = 0;
static bool     gBatBusy        = false;    // divider on, waiting to settle
static bool     gBatAdcReady    = false;
static uint32_t gBatSwitchMs    = 0;        // divider switched on
static bool     gBatAttempted   = false;    // a reading has finished since boot
static uint32_t gBatLastMs      = 0;        // last reading finished
static bool     gBatDeferring   = false;
static uint32_t gBatDeferSince  = 0;
static bool     gCapSavePending = false;
static uint32_t gCapChangedMs   = 0;

static void pwrDueAt(uint32_t& due, uint32_t at, uint32_t now) {
  const int32_t d = (int32_t)(at - now);
  const uint32_t ms = d < 0 ? 0 : (uint32_t)d;
  if (ms < due) due = ms;
}

// ---- LoRa radio --------------------------------------------------------------------------
// setup(): the SX1262 (on 3V3, not Vext) comes out of power-on in STDBY_RC (~0.6 mA) and this
// firmware never uses it: reset it, wait until it is ready, send SetSleep (cold start, no RTC
// wake-up: ~0.2 uA). Its NSS then stays driven HIGH for good: a falling NSS edge would wake it.
// A radio that never reports ready is left alone (a few ms spent at boot, nothing else).
static void loraSleep() {
#if MM_LORA_SLEEP
  digitalWrite(HV3_LORA_NSS_PIN, HIGH);
  pinMode(HV3_LORA_NSS_PIN, OUTPUT);
  digitalWrite(HV3_LORA_NSS_PIN, HIGH);
  pinMode(HV3_LORA_BUSY_PIN, INPUT);
  digitalWrite(HV3_LORA_RST_PIN, LOW);
  pinMode(HV3_LORA_RST_PIN, OUTPUT);
  digitalWrite(HV3_LORA_RST_PIN, LOW);
  delay(2);                                   // reset pulse (>= 100 us)
  digitalWrite(HV3_LORA_RST_PIN, HIGH);       // stays an output, HIGH
  delay(5);                                   // start-up calibration (~3.5 ms), BUSY high meanwhile
  const uint32_t t0 = millis();
  while (digitalRead(HV3_LORA_BUSY_PIN) == HIGH) {
    if (millis() - t0 > LORA_BUSY_TIMEOUT_MS) return;  // not ready: leave it as it is
    delayMicroseconds(200);
  }
  SPI.begin(HV3_LORA_SCK_PIN, HV3_LORA_MISO_PIN, HV3_LORA_MOSI_PIN, -1);
  SPI.beginTransaction(SPISettings(2000000, MSBFIRST, SPI_MODE0));
  digitalWrite(HV3_LORA_NSS_PIN, LOW);
  SPI.transfer(0x84);                         // SetSleep
  SPI.transfer(0x00);                         // cold start, RTC wake-up off
  digitalWrite(HV3_LORA_NSS_PIN, HIGH);
  SPI.endTransaction();
  SPI.end();
  // Defined levels on the idle bus (a floating input can draw current on either side).
  digitalWrite(HV3_LORA_SCK_PIN, LOW);
  pinMode(HV3_LORA_SCK_PIN, OUTPUT);
  digitalWrite(HV3_LORA_SCK_PIN, LOW);
  digitalWrite(HV3_LORA_MOSI_PIN, LOW);
  pinMode(HV3_LORA_MOSI_PIN, OUTPUT);
  digitalWrite(HV3_LORA_MOSI_PIN, LOW);
  pinMode(HV3_LORA_MISO_PIN, INPUT_PULLDOWN);
#endif
}

// ---- Capacity ------------------------------------------------------------------------------
static bool powerIsPreset(uint16_t mah) {
  for (uint8_t i = 0; i < BATTERY_PRESET_COUNT; i++) {
    if (BATTERY_PRESETS_MAH[i] == mah) return true;
  }
  return false;
}

static uint16_t powerCapacityMah() { return gBat.capMah; }

// Hold PRG on the DEVICE page: the next preset (after the largest, the smallest again). Saved
// to NVS a few seconds after the last change.
static uint16_t powerCycleCapacity(uint32_t now) {
  uint16_t next = BATTERY_PRESETS_MAH[0];
  for (uint8_t i = 0; i < BATTERY_PRESET_COUNT; i++) {
    if (BATTERY_PRESETS_MAH[i] > gBat.capMah) {
      next = BATTERY_PRESETS_MAH[i];
      break;
    }
  }
  gBat.capMah = next;
  gCapSavePending = true;
  gCapChangedMs = now;
  return next;
}

static void powerSaveCapacity() {
  gCapSavePending = false;
  Preferences prefs;
  if (prefs.begin(POWER_NVS_NAMESPACE, false)) {
    if (prefs.getUShort(POWER_NVS_CAP_KEY, 0) != gBat.capMah) prefs.putUShort(POWER_NVS_CAP_KEY, gBat.capMah);
    prefs.end();
  }
}

// ---- Battery readings ------------------------------------------------------------------------
static void batteryRelease() {
  pinMode(HV3_VBAT_CTRL_PIN, INPUT);
  gBatBusy = false;
}

static void batterySwitchOn(uint8_t level, uint32_t now) {
  if (!gBatAdcReady) {
    analogSetPinAttenuation(HV3_VBAT_ADC_PIN, ADC_2_5db);  // 0..~1.25 V: a full cell is ~0.82 V at the pin
    gBatAdcReady = true;
  }
  digitalWrite(HV3_VBAT_CTRL_PIN, level);
  pinMode(HV3_VBAT_CTRL_PIN, OUTPUT);
  digitalWrite(HV3_VBAT_CTRL_PIN, level);
  gBatLevel = level;
  gBatBusy = true;
  gBatSwitchMs = now;
}

static void batteryRead(uint32_t now) {
  uint32_t sum = 0;
  for (uint8_t i = 0; i < BAT_SAMPLES; i++) sum += analogReadMilliVolts(HV3_VBAT_ADC_PIN);
  batteryRelease();
  const int32_t mv = (int32_t)((float)sum / BAT_SAMPLES * BAT_DIVIDER + 0.5f);
  if (mv < BAT_DIVIDER_ON_MV && ++gBatTries < 2) {
    batterySwitchOn(gBatLevel == LOW ? HIGH : LOW, now);  // divider stayed off: other board revision
    return;
  }
  gBatAttempted = true;
  gBatLastMs = now;
  if (mv >= BAT_DIVIDER_ON_MV) gBatOnLevel = (int8_t)gBatLevel;
  if (mv >= BAT_MIN_MV && mv <= BAT_MAX_MV) {
    gBat.addReading((uint32_t)(esp_timer_get_time() / 1000000LL), mv);
  } else {
    gBat.lostReading();  // nothing at either level, or out of range: no battery fitted
  }
}

// ---- Sketch interface ----------------------------------------------------------------------
// setup(), after screenBegin(): capacity from NVS (read only: nothing is written at boot).
static void powerBegin(uint16_t defaultMah) {
  gPwrBootMs = millis();
  uint16_t cap = defaultMah;
  Preferences prefs;
  if (prefs.begin(POWER_NVS_NAMESPACE, true)) {  // fails (nothing stored yet) until a capacity is picked
    const uint16_t saved = prefs.getUShort(POWER_NVS_CAP_KEY, 0);
    prefs.end();
    if (powerIsPreset(saved)) cap = saved;
  }
  gBat.begin(cap);
  pinMode(HV3_VBAT_CTRL_PIN, INPUT);  // divider off
}

// Every loop() pass, after screenPoll(): the modelled draw, the battery readings, a pending
// capacity save. `lit`: the screen is powered; `onAir`: a beacon is on air; `linked`: a phone.
static void powerPoll(uint32_t now, bool lit, bool onAir, bool linked) {
  gPwrLit = lit;
  gBat.noteDraw(now, onAir, lit, linked);
  if (gCapSavePending && now - gCapChangedMs >= BAT_CAP_SAVE_DELAY_MS) powerSaveCapacity();

  if (gBatBusy) {
    if (now - gBatSwitchMs >= BAT_SETTLE_MS) batteryRead(now);
    return;
  }
  const bool due = gBatAttempted ? now - gBatLastMs >= (lit ? BAT_PERIOD_LIT_MS : BAT_PERIOD_DARK_MS)
                                 : now - gPwrBootMs >= BAT_FIRST_MS;
  if (!due) {
    gBatDeferring = false;
    return;
  }
  if (onAir) {
    if (!gBatDeferring) {
      gBatDeferring = true;
      gBatDeferSince = now;
    }
    if (now - gBatDeferSince < BAT_DEFER_MAX_MS) return;  // read once the air is free (or anyway, later)
  }
  gBatDeferring = false;
  gBatTries = 0;
  batterySwitchOn(gBatOnLevel >= 0 ? (uint8_t)gBatOnLevel : (uint8_t)LOW, now);
}

// ms until powerPoll() has work: the divider settling, the next reading, a capacity save. A
// reading put off by a beacon waits for the job's end (which wakes loop() anyway) or the limit.
static uint32_t powerNextDueMs(uint32_t now) {
  uint32_t due = 0xFFFFFFFFu;
  if (gCapSavePending) pwrDueAt(due, gCapChangedMs + BAT_CAP_SAVE_DELAY_MS, now);
  if (gBatBusy) {
    pwrDueAt(due, gBatSwitchMs + BAT_SETTLE_MS, now);
  } else if (gBatDeferring) {
    pwrDueAt(due, gBatDeferSince + BAT_DEFER_MAX_MS, now);
  } else if (gBatAttempted) {
    pwrDueAt(due, gBatLastMs + (gPwrLit ? BAT_PERIOD_LIT_MS : BAT_PERIOD_DARK_MS), now);
  } else {
    pwrDueAt(due, gPwrBootMs + BAT_FIRST_MS, now);
  }
  return due;
}

// Results (-1: unknown).
static int32_t powerBatteryMv() { return gBat.have ? (int32_t)(gBat.filtMv + 0.5f) : -1; }
static int powerBatteryPct() { return gBat.percent(); }
static float powerBatteryPctExact() { return gBat.have ? gBat.pct : -1.0f; }  // unrounded, 0..100
static int32_t powerLeftMah() { return gBat.leftMah(); }
static int32_t powerRuntimeMin() { return gBat.runtimeMin(); }
static bool powerCharging() { return gBat.have && gBat.charging; }
static bool powerOnUsb() { return gBat.have && gBat.usb; }

#endif  // MM_HELTEC_V3
