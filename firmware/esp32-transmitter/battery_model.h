// Battery model of the Heltec V3 build: state of charge, charging, and the expected runtime,
// from the battery voltage readings (power.h takes them) and an estimate of the board's draw.
//
// Pure C++ (no Arduino), so it is tested on a desktop too. power.h is its only user.
//
// The board cannot measure its own current, only the battery voltage. So the runtime starts
// from a MODEL: a time-weighted average of the estimated draw of each state below (screen dark
// or lit, a phone linked or not, a beacon on air or not). Once the battery has visibly drained
// (at least BAT_MEAS_MIN_DROP_PCT over at least BAT_MEAS_MIN_S), the MEASURED drain takes over:
// the % slope of the readings, smoothed, kept within BAT_EST_MIN/MAX_FACTOR of the model (the
// flat middle of a LiPo's curve makes single slopes noisy).
//
//   runtime = charge left (capacity x %) / estimated draw
#pragma once

#include <stdint.h>
#include <string.h>

// ---- Estimated draw per state (mA): SEEDS, tune them with a USB power meter --------------
// How: power the board from a USB meter with the battery unplugged, screen dark, no phone
// linked, nothing transmitting; DRAW_BASE_MA + DRAW_ADV_MA is that reading. Then link a phone
// (DRAW_LINK_MA), start keep-awake (DRAW_BEACON_MA) and light the screen (DRAW_SCREEN_MA), one
// at a time, and note what each adds. Only the first ~20-60 minutes of a charge use these
// numbers alone; the measured drain corrects them after that.
static const float DRAW_BASE_MA   = 37.5f;  // ESP32-S3 at 80 MHz + BLE controller (no modem sleep in this core), LoRa asleep, screen off
static const float DRAW_ADV_MA    = 0.5f;   // + connectable advertising while no phone is linked
static const float DRAW_LINK_MA   = 1.0f;   // + a phone linked (connection events every 30-50 ms)
static const float DRAW_BEACON_MA = 8.0f;   // + a beacon on air (20-30 ms advertising: sends, keep-awake, loops)
static const float DRAW_SCREEN_MA = 8.0f;   // + the OLED lit

// ---- Model constants -----------------------------------------------------------------------
static const uint32_t DRAW_AVG_TAU_MS        = 900000;  // the modelled draw is averaged over ~15 minutes
static const uint32_t DRAW_MAX_STEP_MS       = 60000;
static const float    BAT_FILTER_ALPHA       = 0.25f;   // reading filter: filt += alpha * (mV - filt)
static const uint8_t  BAT_HISTORY            = 64;      // filtered readings kept, one per ~minute
static const uint32_t BAT_HISTORY_STEP_S     = 55;
static const uint32_t BAT_CHARGE_WINDOW_S    = 300;     // charging: compared with a reading >= 5 min old ...
static const float    BAT_CHARGE_RISE_MV     = 15.0f;   // ... the voltage rose this much
static const float    BAT_CHARGE_END_DROP_MV = 10.0f;   // charging ended: this far below the peak while charging
static const float    BAT_USB_MV             = 4250.0f; // above this the cell is on the charger (USB power)
static const uint32_t BAT_RELAX_S            = 600;     // after charging the voltage settles: not measured for 10 min
static const uint32_t BAT_MEAS_MIN_S         = 1200;    // measured drain: over at least 20 minutes ...
static const float    BAT_MEAS_MIN_DROP_PCT  = 2.0f;    // ... and at least this much charge used
static const float    BAT_SLOPE_SMOOTH       = 0.3f;    // successive measured slopes, smoothed
static const float    BAT_EST_MIN_FACTOR     = 0.5f;    // measured drain kept within these factors of the model
static const float    BAT_EST_MAX_FACTOR     = 2.5f;

// Rough state of charge of a single LiPo cell from its resting voltage (10 % steps, linear between).
static inline float batteryPercentFromMv(float mv) {
  static const int16_t kCurve[11] = {4190, 4050, 3990, 3890, 3800, 3720, 3630, 3530, 3420, 3300, 3100};
  if (mv >= kCurve[0]) return 100.0f;
  for (int i = 1; i < 11; i++) {
    if (mv >= kCurve[i]) return 100.0f - 10.0f * (float)i + 10.0f * (mv - (float)kCurve[i]) / (float)(kCurve[i - 1] - kCurve[i]);
  }
  return 0.0f;
}

struct BatteryModel {
  struct Entry {
    uint32_t t;    // uptime, s
    float    mv;   // filtered
    float    pct;
  };

  uint16_t capMah;
  // readings
  bool     have;          // a plausible reading is current
  float    filtMv;
  float    pct;
  Entry    ring[BAT_HISTORY];
  uint8_t  ringHead;      // next slot
  uint8_t  ringCount;
  // charging / USB
  bool     charging;
  float    chargePeakMv;
  bool     usb;
  // measured drain
  uint32_t measureFromS;  // readings before this are not used (charging, settling after it)
  bool     anchorSet;     // first reading of this discharge
  uint32_t anchorT;
  float    anchorPct;
  bool     slopeValid;
  float    slopePctPerH;  // smoothed
  // modelled draw
  bool     drawStarted;
  uint32_t drawLastMs;
  float    drawInstMa;    // the state since drawLastMs
  float    drawAvgMa;

  void begin(uint16_t capacityMah) {
    memset((void*)this, 0, sizeof(*this));
    capMah = capacityMah;
    drawInstMa = DRAW_BASE_MA + DRAW_ADV_MA;
    drawAvgMa = drawInstMa;
  }

  static float drawFor(bool onAir, bool lit, bool linked) {
    return DRAW_BASE_MA + (linked ? DRAW_LINK_MA : DRAW_ADV_MA) + (onAir ? DRAW_BEACON_MA : 0.0f) +
           (lit ? DRAW_SCREEN_MA : 0.0f);
  }

  // Every loop() pass with the state from now on: the time since the last call counts at the
  // state that was current then.
  void noteDraw(uint32_t nowMs, bool onAir, bool lit, bool linked) {
    const float inst = drawFor(onAir, lit, linked);
    if (!drawStarted) {
      drawStarted = true;
      drawLastMs = nowMs;
      drawInstMa = inst;
      drawAvgMa = inst;
      return;
    }
    uint32_t dt = nowMs - drawLastMs;
    if (dt > DRAW_MAX_STEP_MS) dt = DRAW_MAX_STEP_MS;
    float k = (float)dt / (float)DRAW_AVG_TAU_MS;
    if (k > 1.0f) k = 1.0f;
    drawAvgMa += (drawInstMa - drawAvgMa) * k;
    drawLastMs = nowMs;
    drawInstMa = inst;
  }

  // The battery reads implausibly (unplugged, or no battery on USB): start over when it is back.
  void lostReading() {
    have = false;
    ringCount = 0;
    ringHead = 0;
    charging = false;
    usb = false;
    anchorSet = false;
    slopeValid = false;
  }

  const Entry& entry(uint8_t ageIndex) const {  // 0 = newest
    return ring[(uint8_t)((ringHead + BAT_HISTORY - 1 - ageIndex) % BAT_HISTORY)];
  }

  // A plausible reading (battery mV) at uptime tS.
  void addReading(uint32_t tS, int32_t mv) {
    const bool first = !have;
    if (first) filtMv = (float)mv;
    else filtMv += BAT_FILTER_ALPHA * ((float)mv - filtMv);
    have = true;
    pct = batteryPercentFromMv(filtMv);

    // Charging: the voltage rose against a reading at least 5 minutes old. It ends when the
    // voltage falls back from its peak (unplugged); the cell then settles for a while.
    const bool wasCharging = charging || usb;
    const Entry* ref = nullptr;
    for (uint8_t i = 0; i < ringCount; i++) {
      const Entry& e = entry(i);
      if (tS - e.t >= BAT_CHARGE_WINDOW_S) {
        ref = &e;
        break;
      }
    }
    if (!charging) {
      if (ref && filtMv - ref->mv >= BAT_CHARGE_RISE_MV) {
        charging = true;
        chargePeakMv = filtMv;
      }
    } else if (filtMv > chargePeakMv) {
      chargePeakMv = filtMv;
    } else if (chargePeakMv - filtMv >= BAT_CHARGE_END_DROP_MV) {
      charging = false;
    }
    usb = filtMv > BAT_USB_MV;
    if (charging || usb) {
      anchorSet = false;
      slopeValid = false;
      measureFromS = tS + BAT_RELAX_S;
    } else if (wasCharging) {
      measureFromS = tS + BAT_RELAX_S;
    }

    if (!charging && !usb && tS >= measureFromS) updateSlope(tS);

    if (ringCount == 0 || tS - entry(0).t >= BAT_HISTORY_STEP_S) {
      ring[ringHead] = Entry{tS, filtMv, pct};
      ringHead = (uint8_t)((ringHead + 1) % BAT_HISTORY);
      if (ringCount < BAT_HISTORY) ringCount++;
    }
  }

  // The drain in %/h: over the last hour of history if it shows enough, else since this
  // discharge's first reading.
  void updateSlope(uint32_t tS) {
    if (!anchorSet) {
      anchorSet = true;
      anchorT = tS;
      anchorPct = pct;
      return;
    }
    float slope = -1.0f;
    for (int i = (int)ringCount - 1; i >= 0; i--) {  // oldest first: the first one in this discharge
      const Entry& e = entry((uint8_t)i);
      if (e.t < measureFromS || e.t < anchorT) continue;
      const uint32_t age = tS - e.t;
      if (age >= BAT_MEAS_MIN_S && e.pct - pct >= BAT_MEAS_MIN_DROP_PCT) {
        slope = (e.pct - pct) * 3600.0f / (float)age;
      }
      break;
    }
    if (slope < 0.0f && tS - anchorT >= BAT_MEAS_MIN_S && anchorPct - pct >= BAT_MEAS_MIN_DROP_PCT) {
      slope = (anchorPct - pct) * 3600.0f / (float)(tS - anchorT);
    }
    if (slope > 0.0f) {
      slopePctPerH = slopeValid ? slopePctPerH + BAT_SLOPE_SMOOTH * (slope - slopePctPerH) : slope;
      slopeValid = true;
    }
  }

  // ---- Results ---------------------------------------------------------------------------
  int percent() const { return have ? (int)(pct + 0.5f) : -1; }
  int32_t leftMah() const { return have ? (int32_t)((float)capMah * pct / 100.0f + 0.5f) : -1; }
  bool measured() const { return slopeValid; }

  // The draw the runtime uses, mA.
  float estimateMa() const {
    const float model = drawAvgMa > 1.0f ? drawAvgMa : 1.0f;
    if (!slopeValid) return model;
    float meas = (float)capMah * slopePctPerH / 100.0f;
    if (meas < model * BAT_EST_MIN_FACTOR) meas = model * BAT_EST_MIN_FACTOR;
    if (meas > model * BAT_EST_MAX_FACTOR) meas = model * BAT_EST_MAX_FACTOR;
    return meas;
  }

  // Minutes left on the battery; -1 without a reading, while charging or on USB power.
  int32_t runtimeMin() const {
    if (!have || charging || usb) return -1;
    const float left = (float)capMah * pct / 100.0f;
    return (int32_t)(left / estimateMa() * 60.0f + 0.5f);
  }
};
