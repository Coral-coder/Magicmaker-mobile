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
//   runtime = charge above the cutoff (capacity x (% - the cutoff's %)) / estimated draw
//
// LowCutoff (bottom of this file) decides the low-battery warning and the automatic power-off
// from the same readings (power.h acts on it).
#pragma once

#include <stdint.h>
#include <string.h>
#include <math.h>

// ---- Estimated draw per state (mA): SEEDS, measure them IN THE BATTERY LEAD ---------------
// How: a current meter in series with the battery (USB unplugged: a USB meter on a PC port also
// counts ~20 mA of the enumerated CP2102), screen dark, no phone linked, nothing transmitting;
// DRAW_BASE_MA + DRAW_ADV_MA is that reading. Then link a phone (DRAW_LINK_MA), start keep-awake
// (DRAW_BEACON_MA) and light the screen (DRAW_SCREEN_MA), one at a time, and note what each adds.
// Only the first ~20-60 minutes of a charge use these numbers alone; the measured drain corrects
// them after that.
static const float DRAW_BASE_MA   = 37.5f;  // ESP32-S3 at 80 MHz + BLE controller; modem sleep only in builds with the link wrap (btsleep.h); LoRa asleep, screen off
static const float DRAW_ADV_MA    = 0.5f;   // + connectable advertising while no phone is linked
static const float DRAW_LINK_MA   = 1.0f;   // + a phone linked (connection events every 30-50 ms)
static const float DRAW_BEACON_MA = 10.0f;  // + a beacon on air (20-30 ms advertising: sends, keep-awake, loops)
static const float DRAW_SCREEN_MA = 8.0f;   // + the OLED lit

// ---- Model constants -----------------------------------------------------------------------
static const uint32_t DRAW_AVG_TAU_MS        = 900000;  // the modelled draw is averaged over ~15 minutes
static const uint32_t DRAW_MAX_STEP_MS       = 60000;
static const float    BAT_FILTER_TAU_S       = 180.0f;  // reading filter time constant (the same lag lit or dark)
static const uint8_t  BAT_HISTORY            = 64;      // filtered readings kept, one per ~minute
static const uint32_t BAT_HISTORY_STEP_S     = 55;
static const uint32_t BAT_CHARGE_WINDOW_S    = 300;     // charging: compared with a reading >= 5 min old ...
static const float    BAT_CHARGE_RISE_MV     = 15.0f;   // ... the voltage rose this much
static const float    BAT_CHARGE_END_DROP_MV = 10.0f;   // charging ended: this far below the peak while charging
static const float    BAT_USB_MV             = 4250.0f; // above this the cell is on the charger (USB power)
static const uint32_t BAT_RELAX_S            = 600;     // after boot / charging: not measured for 10 min (filter, cell settle)
static const uint32_t BAT_MEAS_MIN_S         = 1200;    // measured drain: over at least 20 minutes ...
static const float    BAT_MEAS_MIN_DROP_PCT  = 2.0f;    // ... and at least this much charge used
static const float    BAT_SLOPE_SMOOTH       = 0.3f;    // successive measured slopes, smoothed
static const float    BAT_EST_MIN_FACTOR     = 0.5f;    // measured drain kept within these factors of the model
static const float    BAT_EST_MAX_FACTOR     = 2.5f;

// ---- Low-battery cutoff (LowCutoff) ----------------------------------------------------------
static const int32_t  CUT_PRESETS_MV[]       = {3200, 3300, 3400};  // the levels besides OFF (0)
static const uint8_t  CUT_PRESET_COUNT       = sizeof(CUT_PRESETS_MV) / sizeof(CUT_PRESETS_MV[0]);
static const int32_t  CUT_DEFAULT_MV         = 3300;    // a board with no saved choice (also after 1.4.x)
static const int32_t  LOW_WARN_BASE_MV       = 3300;    // warning base while the cutoff is OFF
static const int32_t  LOW_WARN_MARGIN_MV     = 100;     // warning below cutoff + this
static const int32_t  LOW_WARN_HYST_MV       = 50;      // ... and off again from warning + this
static const uint8_t  CUT_READINGS           = 3;       // consecutive clean readings below the cutoff
static const int32_t  CUT_RESET_MARGIN_MV    = 50;      // the count restarts from cutoff + this
static const int32_t  CUT_COLLAPSE_MV        = 3100;    // fast path: two readings below this ...
static const uint32_t CUT_COLLAPSE_GAP_S     = 5;       // ... at least this far apart
static const int32_t  CUT_UNSTABLE_MV        = 300;     // sample spread / jump between readings: not counted
static const int32_t  CUT_STEP_RISE_MV       = 50;      // a rise this big (charger plugged in) ...
static const uint32_t CUT_STEP_HOLDOFF_S     = 600;     // ... stops the counting this long
static const int32_t  BOOT_MARGIN_MV         = 100;     // boot refused below cutoff + this

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
  uint32_t lastT;         // its uptime, s
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
  // runtime floor
  float    floorPct;      // the cutoff's % (0 when the cutoff is off): the runtime ends there

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
    // Time-based low-pass: readings come every 5 s (lit) or 60 s (dark), the lag stays ~3 min.
    if (!have) {
      filtMv = (float)mv;
      if (measureFromS < tS + BAT_RELAX_S) measureFromS = tS + BAT_RELAX_S;  // let the filter (and cell) settle
    } else {
      const uint32_t dt = tS - lastT;
      const float k = 1.0f - expf(-(float)dt / BAT_FILTER_TAU_S);
      filtMv += k * ((float)mv - filtMv);
    }
    have = true;
    lastT = tS;
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

  // The % at which the board turns itself off (the low-battery cutoff), 0 when it never does.
  // The runtime counts down to it; % and charge left stay the cell's own.
  void setFloorPct(float p) { floorPct = p < 0.0f ? 0.0f : (p > 100.0f ? 100.0f : p); }

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

  // Minutes until the cutoff (or empty, with the cutoff off); -1 without a reading, while
  // charging or on USB power.
  int32_t runtimeMin() const {
    if (!have || charging || usb) return -1;
    float usable = pct - floorPct;
    if (usable < 0.0f) usable = 0.0f;
    const float left = (float)capMah * usable / 100.0f;
    return (int32_t)(left / estimateMa() * 60.0f + 0.5f);
  }
};

// Low-battery warning and automatic power-off, from the battery readings (power.h calls
// onReading() for each one; it turns the board off when that returns true).
//
//   warning  the filtered voltage below warnMv() (cutoff + 0.10 V, or 3.40 V with the cutoff off);
//            off again from warnMv() + 50 mV; never while charging or on USB power.
//   cutoff   CUT_READINGS consecutive clean readings below the cutoff with the filtered value below
//            it too; or, fast, two clean readings below CUT_COLLAPSE_MV at least CUT_COLLAPSE_GAP_S
//            apart. The count restarts once a reading is back at cutoff + CUT_RESET_MARGIN_MV
//            (between the two it is kept).
//   not counted (both counts restart): cutoff off; an unstable reading (sample spread or a jump
//            from the previous reading over CUT_UNSTABLE_MV); USB power (filtered > 4.25 V, the
//            model's charging trend, or the USB hint); and for CUT_STEP_HOLDOFF_S after a rise of
//            CUT_STEP_RISE_MV or more between two readings (a charger plugged in).
struct LowCutoff {
  int32_t  cutMv;         // 0 = off
  bool     low;           // warning stage
  uint8_t  below;         // consecutive clean readings below the cutoff
  uint8_t  collapse;      // clean readings below CUT_COLLAPSE_MV
  uint32_t collapseT;     // uptime (s) of the first one
  bool     haveLast;      // lastMv is the previous clean reading
  int32_t  lastMv;
  bool     holdOff;       // counting stopped until holdOffUntil (s) after a step rise
  uint32_t holdOffUntil;

  void begin(int32_t mv) {
    memset((void*)this, 0, sizeof(*this));
    cutMv = isSetting(mv) ? mv : CUT_DEFAULT_MV;
  }

  // A new level (0 = off): the counts restart.
  void setCut(int32_t mv) {
    cutMv = isSetting(mv) ? mv : CUT_DEFAULT_MV;
    below = 0;
    collapse = 0;
  }

  int32_t warnMv() const { return (cutMv ? cutMv : LOW_WARN_BASE_MV) + LOW_WARN_MARGIN_MV; }

  // In the warning zone with the cutoff on: power.h reads more often there.
  bool near(float filtMv) const { return cutMv != 0 && filtMv < (float)warnMv(); }

  // No plausible reading (no battery, unplugged): nothing to warn about or count.
  void noReading() {
    low = false;
    below = 0;
    collapse = 0;
    haveLast = false;
  }

  // One reading: `cleanMv` the p75 of its samples, `unstable` their spread over CUT_UNSTABLE_MV,
  // `m` the model after it took this reading, `usbHint` the board's USB-power hint. True = power
  // off now. Updates `low`.
  bool onReading(uint32_t tS, int32_t cleanMv, bool unstable, const BatteryModel& m, bool usbHint) {
    const float f = m.filtMv;
    const bool onUsb = usbHint || m.charging || m.usb || f > BAT_USB_MV;
    const int32_t w = warnMv();
    if (onUsb) low = false;
    else if (!low && f < (float)w) low = true;
    else if (low && f >= (float)(w + LOW_WARN_HYST_MV)) low = false;

    const bool had = haveLast;
    const int32_t step = had ? cleanMv - lastMv : 0;
    haveLast = true;
    lastMv = cleanMv;
    if (had && step >= CUT_STEP_RISE_MV) {
      holdOff = true;
      holdOffUntil = tS + CUT_STEP_HOLDOFF_S;
    }
    if (holdOff && (int32_t)(tS - holdOffUntil) >= 0) holdOff = false;
    const bool jump = had && (step > CUT_UNSTABLE_MV || -step > CUT_UNSTABLE_MV);
    if (cutMv == 0 || unstable || jump || onUsb || holdOff) {
      below = 0;
      collapse = 0;
      return false;
    }

    if (cleanMv < CUT_COLLAPSE_MV) {
      if (collapse == 0) {
        collapse = 1;
        collapseT = tS;
      } else if (tS - collapseT >= CUT_COLLAPSE_GAP_S) {
        return true;
      }
    } else {
      collapse = 0;
    }

    if (cleanMv < cutMv && f < (float)cutMv) {
      if (below < 255) below++;
      if (below >= CUT_READINGS) return true;
    } else if (cleanMv >= cutMv + CUT_RESET_MARGIN_MV) {
      below = 0;
    }
    return false;
  }

  // Boot check (power.h): refuse to start below cutoff + BOOT_MARGIN_MV, unless off or on USB.
  static bool bootRefuse(int32_t cut, int32_t mv, bool usbHint) {
    return cut != 0 && !usbHint && mv < cut + BOOT_MARGIN_MV;
  }

  // A stored or picked level: 0 or one of CUT_PRESETS_MV.
  static bool isSetting(int32_t mv) {
    if (mv == 0) return true;
    for (uint8_t i = 0; i < CUT_PRESET_COUNT; i++) {
      if (CUT_PRESETS_MV[i] == mv) return true;
    }
    return false;
  }

  // The app's value: 0 = off; 3000..3600 to the nearest level (< 3250 -> 3200, < 3350 -> 3300,
  // else 3400); -1 for anything else. (relay_proto.h relayCutoffSnap() is the same rule.)
  static int32_t snap(int32_t mv) {
    if (mv == 0) return 0;
    if (mv < 3000 || mv > 3600) return -1;
    if (mv < 3250) return 3200;
    if (mv < 3350) return 3300;
    return 3400;
  }

  // The next level when PRG is held on the LOW BATTERY page: 3200 -> 3300 -> 3400 -> OFF -> 3200.
  static int32_t next(int32_t mv) {
    if (mv == 0) return CUT_PRESETS_MV[0];
    for (uint8_t i = 0; i < CUT_PRESET_COUNT; i++) {
      if (CUT_PRESETS_MV[i] > mv) return CUT_PRESETS_MV[i];
    }
    return 0;
  }
};
