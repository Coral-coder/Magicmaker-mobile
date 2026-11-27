// Power of the Heltec WiFi LoRa 32 V3 build: the SX1262 LoRa radio put to sleep, the UART pads
// released, and the battery (readings, capacity, charge left, expected runtime, the low-battery
// warning and cutoff).
//
// Everything here runs in loop() context (setup() for loraSleep() / uartRelease() / powerBegin() /
// powerBootCheck()).
//
// Battery readings: the divider is switched on (ADC_CTRL, GPIO37) for ~10 ms per reading and
// off again, once a minute while the screen is dark, every 5 s while it is lit, every 15 s in the
// low-battery warning zone (cutoff on) and every 5 s after a reading below 3.10 V. Each reading is
// 32 samples 250 us apart (~8 ms: loop() waits meanwhile) and keeps their p75, so the short dips
// of a beacon's TX bursts barely move it; their spread flags an unstable reading. Outside the
// warning zone a reading is put off while a beacon is on air, for at most BAT_DEFER_MAX_MS;
// inside it never is (keep-awake must not starve the cutoff). battery_model.h turns the readings
// into %, charge left, the runtime (to the cutoff) and the cutoff decision.
//
// Low-battery cutoff (battery_model.h LowCutoff): OFF / 3.20 / 3.30 / 3.40 V, 3.30 V unless one
// was picked (LOW BATTERY page, or the app's set_low_cutoff). When it fires, the sketch turns the
// board off (shutdown.h); RST starts it again, and powerBootCheck() refuses a start that is still
// too low. The board itself has no over-discharge protection: this is it (plus the cell's PCM).
//
// USB hint (MM_USB_SENSE, needs MM_UART_RELEASE): the CP2102 is powered from USB only, and a
// powered CP2102 holds its TXD (our GPIO44) HIGH at UART idle. With GPIO44 pulled down, HIGH means
// "on USB": no runtime, no warning, no cutoff. Unverified on hardware: build with MM_USB_SENSE 0
// if a board reads HIGH on battery alone.
//
// Settings: the capacity (hold PRG on the DEVICE page) and the cutoff level are kept in NVS
// (namespace "mm": "batMah", "lowCut"). Those are the only flash writes in this firmware: each
// key is written BAT_CAP_SAVE_DELAY_MS after its last change, only if it changed, and at once by
// a power-off.
#pragma once

#include "board.h"

#if MM_HELTEC_V3

#include <SPI.h>
#include <Preferences.h>
#include <driver/gpio.h>
#include <esp_timer.h>
#include <esp_system.h>
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
static const uint32_t BAT_PERIOD_NEAR_MS    = 15000;   // in the warning zone, cutoff on
static const uint32_t BAT_PERIOD_FAST_MS    = 5000;    // after a reading below CUT_COLLAPSE_MV
static const uint32_t BAT_DEFER_MAX_MS      = 10000;   // a beacon on air delays a reading at most this long
static const uint32_t BAT_SETTLE_MS         = 10;      // divider switched on -> ADC reading
static const uint8_t  BAT_SAMPLES           = 32;      // per reading ...
static const uint32_t BAT_SAMPLE_GAP_US     = 250;     // ... this far apart (~8 ms window)
static const uint8_t  BAT_CLEAN_RANK        = 24;      // the reading: sample 24 of 32 ascending (p75)
static const float    BAT_DIVIDER           = 4.9f * 1.045f;  // pin mV -> battery mV
static const int32_t  BAT_DIVIDER_ON_MV     = 1000;    // below this the divider was off (wrong ADC_CTRL level)
static const int32_t  BAT_MIN_MV            = 2500;    // plausible single-cell LiPo range
static const int32_t  BAT_MAX_MV            = 4600;
static const uint32_t BAT_CAP_SAVE_DELAY_MS = 3000;    // a picked capacity / cutoff is saved this long after the last change
static const uint32_t BAT_BOOT_GAP_MS       = 50;      // boot check: two readings this far apart
static const uint32_t LORA_BUSY_TIMEOUT_MS  = 30;

// Capacities the DEVICE page steps through (hold PRG).
static const uint16_t BATTERY_PRESETS_MAH[] = {400, 500, 1000, 1100, 2000, 3000, 5000};
static const uint8_t  BATTERY_PRESET_COUNT  = sizeof(BATTERY_PRESETS_MAH) / sizeof(BATTERY_PRESETS_MAH[0]);
// Cutoff levels the LOW BATTERY page steps through (hold PRG): 3.20 / 3.30 / 3.40 V and OFF.
static const uint8_t  CUTOFF_PRESET_COUNT   = CUT_PRESET_COUNT + 1;
static const char*    POWER_NVS_NAMESPACE   = "mm";
static const char*    POWER_NVS_CAP_KEY     = "batMah";   // u16 mAh
static const char*    POWER_NVS_CUT_KEY     = "lowCut";   // u16 mV, 0 = off (missing: CUT_DEFAULT_MV)

// ---- State (loop-owned) ----------------------------------------------------------------
static BatteryModel gBat;
static LowCutoff    gCut;
static uint32_t gPwrBootMs      = 0;
static bool     gPwrLit         = false;    // screen lit at the last powerPoll()
// Divider: switched on by ADC_CTRL, LOW on V3.0/V3.1 and HIGH on V3.2. powerBegin() guesses the
// level from GPIO37's idle level; if a reading is ~0 V the divider stayed off, so the other level
// is tried and the one that worked is kept. Between readings the pin is released (input): the
// divider is off and draws nothing.
static int8_t   gBatOnLevel     = -1;       // ADC_CTRL level that switches the divider on; -1 unknown
static uint8_t  gBatGuessLevel  = LOW;      // first level to try while unknown
static uint8_t  gBatLevel       = LOW;      // level under test
static uint8_t  gBatTries       = 0;
static bool     gBatBusy        = false;    // divider on, waiting to settle
static bool     gBatAdcReady    = false;
static uint32_t gBatSwitchMs    = 0;        // divider switched on
static bool     gBatAttempted   = false;    // a reading has finished since boot
static uint32_t gBatLastMs      = 0;        // last reading finished
static bool     gBatDeferring   = false;
static uint32_t gBatDeferSince  = 0;
static bool     gUsbHint        = false;    // the CP2102 is powered (MM_USB_SENSE)
static bool     gCutoffDue      = false;    // the cutoff fired: powerTakeCutoff() hands it over
static bool     gPwrSavePending = false;    // a setting changed: saved BAT_CAP_SAVE_DELAY_MS later
static uint32_t gPwrChangedMs   = 0;
static bool     gCapDirty       = false;
static bool     gCutDirty       = false;

static void pwrDueAt(uint32_t& due, uint32_t at, uint32_t now) {
  const int32_t d = (int32_t)(at - now);
  const uint32_t ms = d < 0 ? 0 : (uint32_t)d;
  if (ms < due) due = ms;
}

static uint32_t pwrUptimeS() { return (uint32_t)(esp_timer_get_time() / 1000000LL); }

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

// ---- UART pads ----------------------------------------------------------------------------
// setup(), right after screenBegin(): the firmware never uses Serial, and on battery the CP2102
// is unpowered, so the UART0 pads should not drive it. GPIO43 (TX, 499 R to the CP2102) is
// switched off entirely: no output, no pull, and no input buffer either (nothing reads it, and an
// input left floating can draw current); GPIO44 (RX) an input with the pull-down, which is also the
// USB hint (a powered CP2102 holds it HIGH). Flashing is unaffected (the ROM bootloader sets the
// pads up again).
static void uartRelease() {
#if MM_UART_RELEASE
  pinMode(HV3_UART_TX_PIN, INPUT);                                     // GPIO function: U0TXD off the pad
  gpio_set_direction((gpio_num_t)HV3_UART_TX_PIN, GPIO_MODE_DISABLE);  // input buffer off as well
  pinMode(HV3_UART_RX_PIN, INPUT_PULLDOWN);
#endif
}

static void usbHintSample() {
#if MM_USB_SENSE && MM_UART_RELEASE
  gUsbHint = digitalRead(HV3_UART_RX_PIN) == HIGH;
#endif
}

// ---- Settings (NVS) -----------------------------------------------------------------------
static bool powerIsPreset(uint16_t mah) {
  for (uint8_t i = 0; i < BATTERY_PRESET_COUNT; i++) {
    if (BATTERY_PRESETS_MAH[i] == mah) return true;
  }
  return false;
}

static void powerSettingChanged(uint32_t now) {
  gPwrSavePending = true;
  gPwrChangedMs = now;
}

// Writes each changed key that differs from what is stored (never anything at boot).
static void powerFlushSaves() {
  if (!gPwrSavePending) return;
  gPwrSavePending = false;
  Preferences prefs;
  if (prefs.begin(POWER_NVS_NAMESPACE, false)) {
    if (gCapDirty && prefs.getUShort(POWER_NVS_CAP_KEY, 0) != gBat.capMah) prefs.putUShort(POWER_NVS_CAP_KEY, gBat.capMah);
    const uint16_t cut = (uint16_t)gCut.cutMv;
    if (gCutDirty && prefs.getUShort(POWER_NVS_CUT_KEY, (uint16_t)CUT_DEFAULT_MV) != cut) prefs.putUShort(POWER_NVS_CUT_KEY, cut);
    prefs.end();
  }
  gCapDirty = false;
  gCutDirty = false;
}

// ---- Capacity ------------------------------------------------------------------------------
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
  gCapDirty = true;
  powerSettingChanged(now);
  return next;
}

// ---- Cutoff level --------------------------------------------------------------------------
static int32_t powerCutoffMv() { return gCut.cutMv; }

static void powerApplyCutoff(int32_t mv) {
  gCut.setCut(mv);
  gBat.setFloorPct(gCut.cutMv ? batteryPercentFromMv((float)gCut.cutMv) : 0.0f);
}

// The app (set_low_cutoff, already snapped) or the LOW BATTERY page: 0 = off, 3200 / 3300 /
// 3400 mV; anything else is snapped (or ignored). Saved a few seconds after the last change.
static void powerSetCutoff(int32_t mv, uint32_t now) {
  if (!LowCutoff::isSetting(mv)) mv = LowCutoff::snap(mv);
  if (mv < 0) return;
  if (mv != gCut.cutMv) {
    powerApplyCutoff(mv);
    gCutDirty = true;
    powerSettingChanged(now);
  }
}

// Hold PRG on the LOW BATTERY page: 3.20 -> 3.30 -> 3.40 V -> OFF -> 3.20 V.
static int32_t powerCycleCutoff(uint32_t now) {
  powerSetCutoff(LowCutoff::next(gCut.cutMv), now);
  return gCut.cutMv;
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

// One reading of the switched-on divider: BAT_SAMPLES samples BAT_SAMPLE_GAP_US apart, sorted;
// `mv` = their p75 at the battery, `unstable` = their spread over CUT_UNSTABLE_MV. Blocks ~8 ms.
static void batterySample(int32_t* mv, bool* unstable) {
  uint16_t v[BAT_SAMPLES];
  for (uint8_t i = 0; i < BAT_SAMPLES; i++) {
    if (i) delayMicroseconds(BAT_SAMPLE_GAP_US);
    const uint32_t x = analogReadMilliVolts(HV3_VBAT_ADC_PIN);
    v[i] = (uint16_t)(x > 0xFFFFu ? 0xFFFFu : x);
  }
  for (uint8_t i = 1; i < BAT_SAMPLES; i++) {  // insertion sort, ascending
    const uint16_t x = v[i];
    uint8_t j = i;
    while (j > 0 && v[j - 1] > x) {
      v[j] = v[j - 1];
      j--;
    }
    v[j] = x;
  }
  *mv = (int32_t)((float)v[BAT_CLEAN_RANK] * BAT_DIVIDER + 0.5f);
  *unstable = (float)(v[BAT_SAMPLES - 1] - v[0]) * BAT_DIVIDER > (float)CUT_UNSTABLE_MV;
}

static void batteryRead(uint32_t now) {
  int32_t mv;
  bool unstable;
  batterySample(&mv, &unstable);
  batteryRelease();
  usbHintSample();
  if (mv < BAT_DIVIDER_ON_MV && ++gBatTries < 2) {
    batterySwitchOn(gBatLevel == LOW ? HIGH : LOW, now);  // divider stayed off: other board revision
    return;
  }
  gBatAttempted = true;
  gBatLastMs = now;
  if (mv >= BAT_DIVIDER_ON_MV) gBatOnLevel = (int8_t)gBatLevel;
  if (mv >= BAT_MIN_MV && mv <= BAT_MAX_MV) {
    const uint32_t tS = pwrUptimeS();
    gBat.addReading(tS, mv);
    if (gCut.onReading(tS, mv, unstable, gBat, gUsbHint)) gCutoffDue = true;
  } else {
    gBat.lostReading();  // nothing at either level, or out of range: no battery fitted
    gCut.noReading();
  }
}

// ms between readings in the current state.
static uint32_t batteryPeriodMs() {
  uint32_t period = gPwrLit ? BAT_PERIOD_LIT_MS : BAT_PERIOD_DARK_MS;
  if (gBat.have && gCut.near(gBat.filtMv) && period > BAT_PERIOD_NEAR_MS) period = BAT_PERIOD_NEAR_MS;
  if (gCut.collapse > 0 && period > BAT_PERIOD_FAST_MS) period = BAT_PERIOD_FAST_MS;
  return period;
}

// In the warning zone a beacon on air does not delay the reading (p75 handles its dips).
static bool batteryNoDefer() { return gBat.have && gCut.near(gBat.filtMv); }

// ---- Sketch interface ----------------------------------------------------------------------
// setup(), after screenBegin() / uartRelease(): capacity and cutoff level from NVS (read only:
// nothing is written at boot); the divider's level guessed from GPIO37's idle level.
static void powerBegin(uint16_t defaultMah) {
  gPwrBootMs = millis();
  uint16_t cap = defaultMah;
  int32_t cut = CUT_DEFAULT_MV;
  Preferences prefs;
  if (prefs.begin(POWER_NVS_NAMESPACE, true)) {  // fails (nothing stored yet) until a setting is picked
    const uint16_t saved = prefs.getUShort(POWER_NVS_CAP_KEY, 0);
    const uint16_t savedCut = prefs.getUShort(POWER_NVS_CUT_KEY, (uint16_t)CUT_DEFAULT_MV);
    prefs.end();
    if (powerIsPreset(saved)) cap = saved;
    if (LowCutoff::isSetting(savedCut)) cut = savedCut;  // anything else: the default
  }
  gBat.begin(cap);
  gCut.begin(cut);
  powerApplyCutoff(gCut.cutMv);
  // V3.0/V3.1 pull ADC_CTRL up (divider on = LOW); V3.2 does not (on = HIGH). With the pull-down
  // the idle level tells them apart; a wrong guess still falls back to the other level.
  pinMode(HV3_VBAT_CTRL_PIN, INPUT_PULLDOWN);
  delayMicroseconds(200);
  gBatGuessLevel = digitalRead(HV3_VBAT_CTRL_PIN) == HIGH ? LOW : HIGH;
  pinMode(HV3_VBAT_CTRL_PIN, INPUT);  // divider off
}

// One blocking reading for the boot check (both levels if the divider stayed off). False when
// nothing plausible was read.
static bool powerBootRead(int32_t* mv, bool* unstable) {
  for (uint8_t t = 0; t < 2; t++) {
    const uint8_t level = gBatOnLevel >= 0 ? (uint8_t)gBatOnLevel : (t == 0 ? gBatGuessLevel : (gBatGuessLevel == LOW ? HIGH : LOW));
    batterySwitchOn(level, millis());
    delay(BAT_SETTLE_MS);
    batterySample(mv, unstable);
    batteryRelease();
    if (*mv >= BAT_DIVIDER_ON_MV) {
      gBatOnLevel = (int8_t)level;
      return *mv >= BAT_MIN_MV && *mv <= BAT_MAX_MV;
    }
    if (gBatOnLevel >= 0) return false;
  }
  return false;
}

// setup(), before NimBLE (Vext off): after RST / power-on / brownout / a deep-sleep wake, two
// readings BAT_BOOT_GAP_MS apart. True = refuse to start (the battery is below cutoff +
// BOOT_MARGIN_MV and the board is not on USB): the sketch shows the notice (not after a brownout)
// and turns the board off again. Skipped after a software restart (an update: the app expects the
// board back), a panic or a watchdog, with the cutoff off, or when the readings are implausible,
// unstable or disagree. A plausible reading seeds the battery model either way.
static bool powerBootCheck(esp_reset_reason_t reason) {
  if (!(reason == ESP_RST_POWERON || reason == ESP_RST_EXT || reason == ESP_RST_BROWNOUT ||
        reason == ESP_RST_DEEPSLEEP || reason == ESP_RST_UNKNOWN)) {
    return false;
  }
  if (gCut.cutMv == 0) return false;
  int32_t a, b;
  bool ua, ub;
  if (!powerBootRead(&a, &ua)) return false;
  delay(BAT_BOOT_GAP_MS);
  if (!powerBootRead(&b, &ub)) return false;
  usbHintSample();
  if (ua || ub || a - b > CUT_UNSTABLE_MV || b - a > CUT_UNSTABLE_MV) return false;
  const int32_t mv = (a + b) / 2;
  const uint32_t now = millis();
  gBat.addReading(pwrUptimeS(), mv);
  gBatAttempted = true;   // the next reading follows the normal cadence
  gBatLastMs = now;
  return LowCutoff::bootRefuse(gCut.cutMv, mv, gUsbHint);
}

// Every loop() pass, after screenPoll(): the modelled draw, the battery readings, a pending
// settings save. `lit`: the screen is powered; `onAir`: a beacon is on air; `linked`: a phone.
static void powerPoll(uint32_t now, bool lit, bool onAir, bool linked) {
  gPwrLit = lit;
  gBat.noteDraw(now, onAir, lit, linked);
  if (gPwrSavePending && now - gPwrChangedMs >= BAT_CAP_SAVE_DELAY_MS) powerFlushSaves();

  if (gBatBusy) {
    if (now - gBatSwitchMs >= BAT_SETTLE_MS) batteryRead(now);
    return;
  }
  const bool due = gBatAttempted ? now - gBatLastMs >= batteryPeriodMs() : now - gPwrBootMs >= BAT_FIRST_MS;
  if (!due) {
    gBatDeferring = false;
    return;
  }
  if (onAir && !batteryNoDefer()) {
    if (!gBatDeferring) {
      gBatDeferring = true;
      gBatDeferSince = now;
    }
    if (now - gBatDeferSince < BAT_DEFER_MAX_MS) return;  // read once the air is free (or anyway, later)
  }
  gBatDeferring = false;
  gBatTries = 0;
  batterySwitchOn(gBatOnLevel >= 0 ? (uint8_t)gBatOnLevel : gBatGuessLevel, now);
}

// ms until powerPoll() has work: the divider settling, the next reading, a settings save. A
// reading put off by a beacon waits for the job's end (which wakes loop() anyway) or the limit.
static uint32_t powerNextDueMs(uint32_t now) {
  uint32_t due = 0xFFFFFFFFu;
  if (gPwrSavePending) pwrDueAt(due, gPwrChangedMs + BAT_CAP_SAVE_DELAY_MS, now);
  if (gBatBusy) {
    pwrDueAt(due, gBatSwitchMs + BAT_SETTLE_MS, now);
  } else if (gBatDeferring) {
    pwrDueAt(due, gBatDeferSince + BAT_DEFER_MAX_MS, now);
  } else if (gBatAttempted) {
    pwrDueAt(due, gBatLastMs + batteryPeriodMs(), now);
  } else {
    pwrDueAt(due, gPwrBootMs + BAT_FIRST_MS, now);
  }
  return due;
}

// The cutoff fired since the last call (once): the sketch turns the board off.
static bool powerTakeCutoff() {
  const bool due = gCutoffDue;
  gCutoffDue = false;
  return due;
}

// Results (-1: unknown).
static int32_t powerBatteryMv() { return gBat.have ? (int32_t)(gBat.filtMv + 0.5f) : -1; }
static int powerBatteryPct() { return gBat.percent(); }
static float powerBatteryPctExact() { return gBat.have ? gBat.pct : -1.0f; }  // unrounded, 0..100
static int32_t powerLeftMah() { return gBat.leftMah(); }
static bool powerCharging() { return gBat.have && gBat.charging; }
static bool powerOnUsb() { return (gBat.have && gBat.usb) || gUsbHint; }
static int32_t powerRuntimeMin() { return gUsbHint ? -1 : gBat.runtimeMin(); }  // to the cutoff
static bool powerBatteryLow() { return gBat.have && gCut.low; }  // the warning stage

#endif  // MM_HELTEC_V3
