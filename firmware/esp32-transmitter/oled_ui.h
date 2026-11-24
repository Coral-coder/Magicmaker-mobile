// OLED screen of the Heltec WiFi LoRa 32 V3 build: power, PRG button, frame updates.
//
// Power first: the panel is OFF and UNPOWERED unless you are using it. Pressing PRG (GPIO0)
// powers it up on the STATUS page; further presses step through the pages; it powers down
// again SCREEN_ON_MS (top of the .ino) after the last press. Nothing else wakes it: no boot
// splash, not a phone connecting, not a transmit.
//
// On the DEVICE page a press steps on when PRG is released; holding it BUTTON_LONG_MS instead
// picks the next battery capacity (power.h), and again every BUTTON_LONG_MS while held, for at
// most one round of the presets (a button held down in a bag must not keep the screen lit).
//
//   off  = SSD1306 display off, I2C stopped and its pins released (no back-powering through
//          pull-ups), reset held LOW (never driven high into an unpowered panel), Vext HIGH so
//          the panel and the Vext rail draw nothing
//   wake = Vext LOW, settle, reset + full SSD1306 init, first frame, display on
//
// Everything here runs in loop() context; nothing is touched from the BLE callbacks (they run
// on the NimBLE task). The PRG interrupt only wakes loop() (which sleeps between deadlines);
// debouncing stays in screenPoll(). Battery readings and the runtime live in power.h.
#pragma once

#include "board.h"

#if MM_HELTEC_V3

#include <Wire.h>
#include <U8g2lib.h>
#include <NimBLEDevice.h>
#include <esp_timer.h>
#include "oled_pages.h"
#include "power.h"

// ---- Tuning ----------------------------------------------------------------------------
static const uint32_t SCREEN_FRAME_MS       = 250;    // at most 4 frames/s while lit
static const uint32_t SCREEN_VEXT_SETTLE_MS = 100;    // Vext rail + panel supply settle (loop keeps running)
static const uint16_t OLED_RESET_PULSE_MS   = 10;     // u8g2 default 100: sized for slow clone panels
static const uint16_t OLED_POST_RESET_MS    = 20;     // u8g2 default 100
static const uint32_t OLED_I2C_HZ           = 400000;
static const uint32_t BUTTON_DEBOUNCE_MS    = 25;
static const uint32_t BUTTON_LONG_MS        = 1000;   // DEVICE page: hold PRG this long for the next capacity
static const uint32_t SCREEN_CAP_MARK_MS    = 1500;   // the changed capacity stays highlighted this long

// ---- State (loop-owned) ----------------------------------------------------------------
enum ScreenPower : uint8_t { SCREEN_OFF, SCREEN_POWERING, SCREEN_ON };

static U8G2_SSD1306_128X64_NONAME_F_HW_I2C gOled(U8G2_R0, HV3_OLED_RST_PIN, HV3_OLED_SCL_PIN, HV3_OLED_SDA_PIN);
static u8x8_display_info_t gOledInfo;          // the driver's timings with a shorter reset

static uint8_t  gScrPower      = SCREEN_OFF;
static uint8_t  gScrPage       = PAGE_STATUS;
static uint32_t gScrOnMs       = 10000;
static uint32_t gScrPressMs    = 0;            // last PRG press
static uint32_t gScrPowerMs    = 0;            // Vext switched on
static uint32_t gScrFrameMs    = 0;            // last frame drawn
static bool     gScrFrameNow   = false;        // draw at the next chance (wake, page change)
static bool     gScrSendAll    = false;        // next flush sends every row (panel RAM is stale)
static bool     gScrDisplayOn  = false;        // display switched on after the first frame
static uint32_t gScrRowHash[8];                // per 8-px row of the last frame sent

static bool     gBtnRaw        = false;        // PRG level as last sampled (true = pressed)
static bool     gBtnDown       = false;        // debounced
static uint32_t gBtnChangeMs   = 0;
static uint32_t gBtnDownMs     = 0;            // debounced press start
static bool     gBtnOnDevice   = false;        // this press started on the lit DEVICE page
static uint8_t  gBtnLongSteps  = 0;            // capacity steps taken by this press
static bool     gScrCapMarked  = false;        // a capacity was picked ...
static uint32_t gScrCapMarkMs  = 0;            // ... at this time

// Packet stats, fed by the sketch from beginTransmit().
static uint32_t gScrSent       = 0;
static uint8_t  gScrLastKind   = PACKET_NONE;
static int64_t  gScrLastUs     = 0;            // esp_timer: 64-bit, unlike millis() it never wraps
static uint8_t  gScrLastLen    = 0;
static uint8_t  gScrLastBytes[31];
static uint32_t gScrLastCmdMs  = 0;
static bool     gScrLastWake   = false;

static const char* gScrName   = "";           // BLE device name
static char     gScrAddr[9]    = "";           // last three BLE address bytes, read once

static TaskHandle_t gScrWakeTask = nullptr;    // loop()'s task: the PRG interrupt wakes it

// ---- Panel power -----------------------------------------------------------------------
// Off: also the boot state. Safe to call in any state.
static void screenPowerOff() {
  if (gScrPower == SCREEN_ON) {
    gOled.setPowerSave(1);  // display off
    Wire.end();
  }
  pinMode(HV3_OLED_SDA_PIN, INPUT);  // no driver, no pull-up: nothing feeds the unpowered panel
  pinMode(HV3_OLED_SCL_PIN, INPUT);
  digitalWrite(HV3_OLED_RST_PIN, LOW);
  pinMode(HV3_OLED_RST_PIN, OUTPUT);
  digitalWrite(HV3_VEXT_PIN, HIGH);  // Vext rail off
  pinMode(HV3_VEXT_PIN, OUTPUT);
  digitalWrite(HV3_VEXT_PIN, HIGH);
  gScrPower = SCREEN_OFF;
  gScrDisplayOn = false;
}

static void screenPowerOn(uint32_t now) {
  digitalWrite(HV3_VEXT_PIN, LOW);  // Vext rail on; reset stays LOW while the supply comes up
  gScrPower = SCREEN_POWERING;
  gScrPowerMs = now;
  gScrPage = PAGE_STATUS;
}

// Vext has settled: reset + SSD1306 init (u8g2 also restarts I2C on SDA 17 / SCL 18). The panel
// stays dark until the first frame is in its RAM; screenDraw() then switches it on.
static void screenInitPanel() {
  gOled.beginSimple();
  gScrPower = SCREEN_ON;
  gScrSendAll = true;
  gScrFrameNow = true;
  gScrDisplayOn = false;
}

// PRG changed level: wake loop() so screenPoll() sees it (debounced there).
static void IRAM_ATTR screenPrgIsr() {
  BaseType_t woken = pdFALSE;
  if (gScrWakeTask) vTaskNotifyGiveFromISR(gScrWakeTask, &woken);
  portYIELD_FROM_ISR(woken);
}

// ---- Sketch interface ------------------------------------------------------------------
// What the sketch hands screenDraw() each frame.
struct ScreenInputs {
  bool     linked;             // a phone is connected
  uint8_t  txState;            // ScreenTxState
  uint16_t txPermille;         // progress through the current phase
  uint8_t  program;            // ScreenProgram (= RelayProgram)
  uint32_t programIntervalMs;  // TX / wand loop interval
};

// setup(), first thing, from loop()'s task: panel unpowered from boot, PRG as input with an
// interrupt that wakes that task. `name` must stay valid.
static void screenBegin(uint32_t onMs, const char* name) {
  gScrOnMs = onMs;
  gScrName = name;
  screenPowerOff();
  pinMode(HV3_PRG_PIN, INPUT_PULLUP);
  gBtnRaw = gBtnDown = (digitalRead(HV3_PRG_PIN) == LOW);  // a held button is not a press
  gBtnChangeMs = millis();
  gScrWakeTask = xTaskGetCurrentTaskHandle();
  attachInterrupt(HV3_PRG_PIN, screenPrgIsr, CHANGE);
  // u8g2's SSD1306 driver holds reset 100 ms and then waits 100 ms more (for slow clone panels),
  // which would stall loop() -- and with it the transmit timing -- for ~300 ms on every wake.
  // The Heltec panel only needs a few ms (its supply has already settled by then).
  gOledInfo = *gOled.getU8x8()->display_info;
  gOledInfo.reset_pulse_width_ms = OLED_RESET_PULSE_MS;
  gOledInfo.post_reset_wait_ms = OLED_POST_RESET_MS;
  gOled.getU8x8()->display_info = &gOledInfo;
  gOled.setBusClock(OLED_I2C_HZ);
}

// loop(): a job went on air (kind: ScreenPacketKind).
static void screenNotePacket(const uint8_t* bytes, size_t len, uint32_t cmdMs, bool wake, uint8_t kind) {
  if (len > sizeof(gScrLastBytes)) len = sizeof(gScrLastBytes);
  gScrSent++;
  gScrLastKind = kind;
  gScrLastUs = esp_timer_get_time();
  gScrLastLen = (uint8_t)len;
  memcpy(gScrLastBytes, bytes, len);
  gScrLastCmdMs = cmdMs;
  gScrLastWake = wake;
}

static void screenNextPage() {
  gScrPage = (uint8_t)((gScrPage + 1) % PAGE_COUNT);
  gScrFrameNow = true;
}

// loop(): PRG button, power sequencing, timeout. Cheap while the screen is off.
static void screenPoll() {
  const uint32_t now = millis();

  const bool raw = digitalRead(HV3_PRG_PIN) == LOW;
  if (raw != gBtnRaw) {
    gBtnRaw = raw;
    gBtnChangeMs = now;
  } else if (raw != gBtnDown && now - gBtnChangeMs >= BUTTON_DEBOUNCE_MS) {
    gBtnDown = raw;
    gScrPressMs = now;  // pressing or releasing keeps the screen lit
    if (gBtnDown) {     // a press: acted on when it goes down, except on the DEVICE page
      gBtnDownMs = now;
      gBtnLongSteps = 0;
      gBtnOnDevice = false;
      if (gScrPower == SCREEN_OFF) {
        screenPowerOn(now);
      } else if (gScrPower == SCREEN_ON) {
        if (gScrPage == PAGE_DEVICE) gBtnOnDevice = true;  // short or long: decided by the release
        else screenNextPage();
      }  // still powering up: the press only extends the timeout
    } else {
      if (gBtnOnDevice && gBtnLongSteps == 0 && gScrPower == SCREEN_ON) screenNextPage();
      gBtnOnDevice = false;
    }
  }

  // Held on the DEVICE page: the next battery capacity now, and again every BUTTON_LONG_MS.
  if (gBtnDown && gBtnOnDevice && gScrPower == SCREEN_ON && gBtnLongSteps < BATTERY_PRESET_COUNT &&
      now - gBtnDownMs >= BUTTON_LONG_MS * (uint32_t)(gBtnLongSteps + 1)) {
    powerCycleCapacity(now);
    gBtnLongSteps++;
    gScrPressMs = now;
    gScrCapMarked = true;
    gScrCapMarkMs = now;
    gScrFrameNow = true;
  }

  if (gScrPower != SCREEN_OFF && now - gScrPressMs >= gScrOnMs) {
    screenPowerOff();
  } else if (gScrPower == SCREEN_POWERING && now - gScrPowerMs >= SCREEN_VEXT_SETTLE_MS) {
    screenInitPanel();
  }
}

// The panel is powered (lit or coming up): it draws current.
static bool screenLit() { return gScrPower != SCREEN_OFF; }

// loop(): true when the screen is lit and a frame is due (page change, or SCREEN_FRAME_MS).
static bool screenFrameDue() {
  return gScrPower == SCREEN_ON && (gScrFrameNow || millis() - gScrFrameMs >= SCREEN_FRAME_MS);
}

static void scrDueAt(uint32_t& due, uint32_t at, uint32_t now) {
  const int32_t d = (int32_t)(at - now);
  const uint32_t ms = d < 0 ? 0 : (uint32_t)d;
  if (ms < due) due = ms;
}

// loop(): ms until screenPoll() or a frame has work: PRG debounce, a long press, Vext settle,
// the next frame, the screen timeout. 0xFFFFFFFF while the screen is dark and PRG is idle.
static uint32_t screenNextDueMs(uint32_t now) {
  uint32_t due = 0xFFFFFFFFu;
  if (gBtnRaw != gBtnDown) scrDueAt(due, gBtnChangeMs + BUTTON_DEBOUNCE_MS, now);
  if (gScrPower == SCREEN_OFF) return due;
  if (gBtnDown && gBtnOnDevice && gBtnLongSteps < BATTERY_PRESET_COUNT) {
    scrDueAt(due, gBtnDownMs + BUTTON_LONG_MS * (uint32_t)(gBtnLongSteps + 1), now);
  }
  scrDueAt(due, gScrPressMs + gScrOnMs, now);
  if (gScrPower == SCREEN_POWERING) scrDueAt(due, gScrPowerMs + SCREEN_VEXT_SETTLE_MS, now);
  if (gScrPower == SCREEN_ON) scrDueAt(due, gScrFrameNow ? now : gScrFrameMs + SCREEN_FRAME_MS, now);
  return due;
}

static uint32_t screenRowHash(const uint8_t* p, size_t n) {
  uint32_t h = 2166136261u;  // FNV-1a
  while (n--) h = (h ^ *p++) * 16777619u;
  return h;
}

// Sends only the 8-px rows that changed since the last frame (a moving progress bar or a
// ticking clock is one row: ~128 bytes instead of the whole 1 KB frame).
static void screenFlush() {
  u8g2_t* g = gOled.getU8g2();
  const uint8_t* buf = u8g2_GetBufferPtr(g);
  const uint8_t tilesW = u8g2_GetBufferTileWidth(g);
  uint8_t rows = u8g2_GetBufferTileHeight(g);
  if (rows > 8) rows = 8;
  const size_t rowBytes = (size_t)tilesW * 8;
  uint8_t run = 0;  // changed rows just before `row`, not sent yet
  for (uint8_t row = 0; row < rows; row++) {
    const uint32_t h = screenRowHash(buf + row * rowBytes, rowBytes);
    if (gScrSendAll || h != gScrRowHash[row]) {
      gScrRowHash[row] = h;
      run++;
    } else if (run) {
      u8g2_UpdateDisplayArea(g, 0, (uint8_t)(row - run), tilesW, run);
      run = 0;
    }
  }
  if (run) u8g2_UpdateDisplayArea(g, 0, (uint8_t)(rows - run), tilesW, run);
  gScrSendAll = false;
}

// loop(), when screenFrameDue(): draw the current page from the sketch's transmitter state
// plus the stats and readings kept here, and send what changed.
static void screenDraw(const ScreenInputs& in) {
  const uint32_t now = millis();
  if (!gScrAddr[0]) {
    const std::string a = NimBLEDevice::getAddress().toString();  // "aa:bb:cc:dd:ee:ff"
    if (a.size() == 17) memcpy(gScrAddr, a.c_str() + 9, 9);       // "dd:ee:ff" + NUL
  }

  ScreenModel m;
  memset(&m, 0, sizeof(m));
  m.linked = in.linked;
  m.txState = in.txState;
  m.txPermille = in.txPermille;
  m.program = in.program;
  m.programIntervalMs = in.programIntervalMs;
  m.sent = gScrSent;
  m.lastKind = gScrLastKind;
  const int64_t nowUs = esp_timer_get_time();
  m.lastAgeS = (uint32_t)((nowUs - gScrLastUs) / 1000000LL);
  m.lastLen = gScrLastLen;
  memcpy(m.lastBytes, gScrLastBytes, sizeof(m.lastBytes));
  m.lastCmdMs = gScrLastCmdMs;
  m.lastWake = gScrLastWake;
  m.batteryMv = powerBatteryMv();
  m.batteryPct = (int16_t)powerBatteryPct();
  m.batteryCapMah = powerCapacityMah();
  m.batteryLeftMah = powerLeftMah();
  m.runtimeMin = powerRuntimeMin();
  m.charging = powerCharging();
  m.usb = powerOnUsb();
  if (gScrCapMarked && now - gScrCapMarkMs >= SCREEN_CAP_MARK_MS && !(gBtnDown && gBtnLongSteps > 0)) gScrCapMarked = false;
  m.capMark = gScrCapMarked;
  m.uptimeS = (uint32_t)(nowUs / 1000000LL);
  m.bleName = gScrName;
  memcpy(m.bleAddr, gScrAddr, sizeof(m.bleAddr));
  m.fwVersion = MM_FW_VERSION;
  m.boardLabel = MM_BOARD_LABEL;

  scrDrawPage(gOled.getU8g2(), gScrPage, m);
  screenFlush();
  if (!gScrDisplayOn) {
    gOled.setPowerSave(0);  // first frame is in the panel's RAM: switch the display on
    gScrDisplayOn = true;
  }
  gScrFrameMs = now;
  gScrFrameNow = false;
}

#endif  // MM_HELTEC_V3
