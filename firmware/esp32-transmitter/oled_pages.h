// OLED pages of the Heltec V3 build: layout and drawing only, no hardware access.
//
// Draws into a u8g2 frame buffer (128x64, 1 bit per pixel) through the u8g2 C API, so the same
// code also builds on a desktop to render the pages for review. Text uses the app's VFD 5x7
// dot-matrix face (vfd_font_5x7.h), capitals only.
//
// Grid: 21 columns of 6 px. Row 0 is the header (page title + page dots) over a dotted rule;
// below it six text lines, 9 px apart. Labels sit in columns 0-3, values start at column 4
// (17 columns).
#pragma once

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#if defined(ARDUINO)
#include <U8g2lib.h>
#else
#include "u8g2.h"
#endif
#include "vfd_font_5x7.h"

#ifndef pgm_read_byte
#define pgm_read_byte(p) (*(const uint8_t*)(p))
#endif

enum ScreenPage : uint8_t { PAGE_STATUS = 0, PAGE_PACKET, PAGE_DEVICE, PAGE_COUNT };
enum ScreenTxState : uint8_t { SCREEN_TX_IDLE = 0, SCREEN_TX_WAKE, SCREEN_TX_SEND };
// Same values as relay_proto.h RelayKind / RelayProgram (the sketch passes them straight through).
enum ScreenPacketKind : uint8_t { PACKET_NONE = 0, PACKET_BAND, PACKET_WAND, PACKET_PING, PACKET_RAW };
enum ScreenProgram : uint8_t { SCREEN_PROG_NONE = 0, SCREEN_PROG_KEEP_AWAKE, SCREEN_PROG_TX_LOOP, SCREEN_PROG_WAND_LOOP };

// Everything the pages show. Filled in loop() context only.
struct ScreenModel {
  // STATUS
  bool        linked;          // a phone is connected
  uint8_t     txState;         // ScreenTxState
  uint16_t    txPermille;      // progress through the current WAKE / SEND phase, 0..1000
  uint8_t     program;         // ScreenProgram the chip runs by itself
  uint32_t    programIntervalMs;  // TX / wand loop interval
  uint32_t    sent;            // packets broadcast since boot
  // last packet (STATUS + LAST PACKET)
  uint8_t     lastKind;        // ScreenPacketKind; PACKET_NONE = nothing sent yet
  uint32_t    lastAgeS;
  uint8_t     lastLen;
  uint8_t     lastBytes[31];
  uint32_t    lastCmdMs;       // command stream length
  bool        lastWake;        // a wake-ping phase ran before the command
  // battery (STATUS + DEVICE)
  int32_t     batteryMv;       // < 0: no plausible reading
  int16_t     batteryPct;      // < 0: unknown
  uint16_t    batteryCapMah;   // rated capacity
  int32_t     batteryLeftMah;  // < 0: unknown
  int32_t     runtimeMin;      // < 0: unknown (no reading, charging, USB power)
  bool        charging;
  bool        usb;             // on the charger (USB power)
  bool        capMark;         // the capacity is being changed (hold PRG): highlight it
  // DEVICE
  uint32_t    uptimeS;
  const char* bleName;
  char        bleAddr[9];      // last three address bytes "dd:ee:ff"; "" when unknown
  const char* fwVersion;
  const char* boardLabel;
};

static const int SCR_W          = 128;
static const int SCR_RULE_Y     = 9;
static const int SCR_LINE0_Y    = 12;
static const int SCR_LINE_PITCH = 9;
static const int SCR_VALUE_X    = 4 * VFD5X7_ADVANCE;
static const int SCR_VALUE_COLS = (SCR_W - SCR_VALUE_X - VFD5X7_W) / VFD5X7_ADVANCE + 1;  // 17 characters fit
static const int SCR_BAR_W      = 72;   // 23 segments: 3 px pitch inside a 1 px frame + 1 px gap

static int scrLineY(int line) { return SCR_LINE0_Y + line * SCR_LINE_PITCH; }

// One character, top-left of its 5x9 box at (x, y). Lowercase is drawn as capitals.
static void scrChar(u8g2_t* g, int x, int y, char c) {
  if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
  const int idx = (c >= VFD5X7_FIRST && c <= VFD5X7_LAST) ? c - VFD5X7_FIRST : VFD5X7_FALLBACK;
  for (int r = 0; r < VFD5X7_H; r++) {
    const uint8_t bits = pgm_read_byte(&VFD5X7_GLYPHS[idx][r]);
    for (int col = 0; col < VFD5X7_W; col++) {
      if (bits & (1u << col)) u8g2_DrawPixel(g, (u8g2_uint_t)(x + col), (u8g2_uint_t)(y + r));
    }
  }
}

// A string from (x, y); characters that would cross the right edge are dropped.
static void scrText(u8g2_t* g, int x, int y, const char* s) {
  for (; *s && x + VFD5X7_W <= SCR_W; s++, x += VFD5X7_ADVANCE) scrChar(g, x, y, *s);
}

static void scrLabel(u8g2_t* g, int line, const char* s) { scrText(g, 0, scrLineY(line), s); }
static void scrValue(u8g2_t* g, int line, const char* s) { scrText(g, SCR_VALUE_X, scrLineY(line), s); }

// A value drawn dark on a lit box (1 px margin), for the one being changed.
static void scrValueInverse(u8g2_t* g, int line, const char* s) {
  int cols = (int)strlen(s);
  if (cols > SCR_VALUE_COLS) cols = SCR_VALUE_COLS;
  if (cols == 0) return;
  u8g2_DrawBox(g, (u8g2_uint_t)(SCR_VALUE_X - 1), (u8g2_uint_t)(scrLineY(line) - 1),
               (u8g2_uint_t)(cols * VFD5X7_ADVANCE + 1), (u8g2_uint_t)(VFD5X7_ASCENT + 2));
  u8g2_SetDrawColor(g, 0);
  scrValue(g, line, s);
  u8g2_SetDrawColor(g, 1);
}

// Title on the left, one dot per page on the right (the current one filled), dotted rule below.
static void scrHeader(u8g2_t* g, const char* title, uint8_t page) {
  scrText(g, 0, 0, title);
  for (int i = 0; i < PAGE_COUNT; i++) {
    const int x = SCR_W - 5 - (PAGE_COUNT - 1 - i) * 8;
    if (i == page) u8g2_DrawBox(g, (u8g2_uint_t)x, 1, 5, 5);
    else           u8g2_DrawFrame(g, (u8g2_uint_t)x, 1, 5, 5);
  }
  for (int x = 0; x < SCR_W; x += 2) u8g2_DrawPixel(g, (u8g2_uint_t)x, SCR_RULE_Y);
}

// Segmented progress bar on a text line: a 7 px tall frame holding 2x3 px segments.
static void scrBar(u8g2_t* g, int x, int y, int w, uint16_t permille) {
  u8g2_DrawFrame(g, (u8g2_uint_t)x, (u8g2_uint_t)y, (u8g2_uint_t)w, 7);
  const int segs = (w - 3) / 3;
  const int lit = (int)((uint32_t)(permille > 1000 ? 1000 : permille) * (uint32_t)segs / 1000u);
  for (int k = 0; k < lit; k++) u8g2_DrawBox(g, (u8g2_uint_t)(x + 2 + 3 * k), (u8g2_uint_t)(y + 2), 2, 3);
}

static const char* scrKindName(uint8_t kind) {
  switch (kind) {
    case PACKET_BAND: return "BAND";
    case PACKET_WAND: return "WAND";
    case PACKET_PING: return "PING";
    case PACKET_RAW:  return "RAW";
    default:          return "--";
  }
}

// "12S", "5M", "3H", "2D": the largest whole unit.
static void scrAge(char* out, size_t n, uint32_t s) {
  if (s < 60)         snprintf(out, n, "%luS", (unsigned long)s);
  else if (s < 3600)  snprintf(out, n, "%luM", (unsigned long)(s / 60));
  else if (s < 86400) snprintf(out, n, "%luH", (unsigned long)(s / 3600));
  else                snprintf(out, n, "%luD", (unsigned long)(s / 86400));
}

// "3S" when whole seconds, else one decimal: "2.5S".
static void scrSeconds(char* out, size_t n, uint32_t ms) {
  const uint32_t tenths = (ms + 50) / 100;
  if (tenths % 10 == 0) snprintf(out, n, "%luS", (unsigned long)(tenths / 10));
  else                  snprintf(out, n, "%lu.%luS", (unsigned long)(tenths / 10), (unsigned long)(tenths % 10));
}

// STATUS line 2: what the chip keeps doing by itself.
static void scrProgramText(char* out, size_t n, uint8_t program, uint32_t intervalMs) {
  char secs[12];
  scrSeconds(secs, sizeof(secs), intervalMs);
  switch (program) {
    case SCREEN_PROG_KEEP_AWAKE: snprintf(out, n, "KEEP AWAKE ON"); break;
    case SCREEN_PROG_TX_LOOP:    snprintf(out, n, "TX LOOP %s", secs); break;
    case SCREEN_PROG_WAND_LOOP:  snprintf(out, n, "WAND LOOP %s", secs); break;
    default:                     snprintf(out, n, "KEEP AWAKE OFF"); break;
  }
}

// Expected runtime: "~9H 40M", "~40M" under an hour, "~99H+" from 99 hours.
static void scrRuntime(char* out, size_t n, int32_t minutes) {
  if (minutes < 0) minutes = 0;
  if (minutes >= 99 * 60) snprintf(out, n, "~99H+");
  else if (minutes >= 60) snprintf(out, n, "~%ldH %ldM", (long)(minutes / 60), (long)(minutes % 60));
  else                    snprintf(out, n, "~%ldM", (long)minutes);
}

// STATUS line 6: "68% ~9H 40M", "68% CHARGING", "100% USB POWER", "--".
static void scrBatteryStatus(char* out, size_t n, const ScreenModel& m) {
  char run[12];
  if (m.batteryPct < 0)       snprintf(out, n, "--");
  else if (m.usb)             snprintf(out, n, "%d%% USB POWER", (int)m.batteryPct);
  else if (m.charging)        snprintf(out, n, "%d%% CHARGING", (int)m.batteryPct);
  else if (m.runtimeMin >= 0) {
    scrRuntime(run, sizeof(run), m.runtimeMin);
    snprintf(out, n, "%d%% %s", (int)m.batteryPct, run);
  } else                      snprintf(out, n, "%d%%", (int)m.batteryPct);
}

// BLE  LINKED | WAITING FOR PHONE
// TX   IDLE | WAKE [bar] | SEND [bar]           (raw bursts show SEND)
//      KEEP AWAKE ON | TX LOOP 3S | WAND LOOP 2.5S | KEEP AWAKE OFF
// PKT  12 SENT
//      LAST BAND 4S AGO | LAST --
// BAT  68% ~9H 40M | 68% CHARGING | 100% USB POWER | --
static void scrPageStatus(u8g2_t* g, const ScreenModel& m) {
  char buf[32];
  scrHeader(g, "STATUS", PAGE_STATUS);
  scrLabel(g, 0, "BLE");
  scrValue(g, 0, m.linked ? "LINKED" : "WAITING FOR PHONE");
  scrLabel(g, 1, "TX");
  if (m.txState == SCREEN_TX_IDLE) {
    scrValue(g, 1, "IDLE");
  } else {
    scrValue(g, 1, m.txState == SCREEN_TX_WAKE ? "WAKE" : "SEND");
    scrBar(g, SCR_VALUE_X + 5 * VFD5X7_ADVANCE, scrLineY(1), SCR_BAR_W, m.txPermille);
  }
  scrProgramText(buf, sizeof(buf), m.program, m.programIntervalMs);
  scrValue(g, 2, buf);
  scrLabel(g, 3, "PKT");
  snprintf(buf, sizeof(buf), "%lu SENT", (unsigned long)m.sent);
  scrValue(g, 3, buf);
  if (m.lastKind == PACKET_NONE) {
    scrValue(g, 4, "LAST --");
  } else {
    char age[12];
    scrAge(age, sizeof(age), m.lastAgeS);
    snprintf(buf, sizeof(buf), "LAST %s %s AGO", scrKindName(m.lastKind), age);
    // From 100 days the line is 18 characters: drop " AGO" rather than clip it to " AG".
    if (strlen(buf) > (size_t)SCR_VALUE_COLS) snprintf(buf, sizeof(buf), "LAST %s %s", scrKindName(m.lastKind), age);
    scrValue(g, 4, buf);
  }
  scrLabel(g, 5, "BAT");
  scrBatteryStatus(buf, sizeof(buf), m);
  scrValue(g, 5, buf);
}

// BAND 23B WAKE+4000MS
// 83 01 CC 03 00 01 00     seven bytes a line, up to five lines (31 bytes)
static void scrPagePacket(u8g2_t* g, const ScreenModel& m) {
  char buf[32];
  scrHeader(g, "LAST PACKET", PAGE_PACKET);
  if (m.lastKind == PACKET_NONE) {
    scrLabel(g, 0, "NO PACKET YET");
    return;
  }
  snprintf(buf, sizeof(buf), "%s %uB %s%luMS", scrKindName(m.lastKind), (unsigned)m.lastLen,
           m.lastWake ? "WAKE+" : "", (unsigned long)m.lastCmdMs);
  scrLabel(g, 0, buf);
  const int n = m.lastLen > sizeof(m.lastBytes) ? (int)sizeof(m.lastBytes) : (int)m.lastLen;
  for (int i = 0; i < n; i++) {
    snprintf(buf, sizeof(buf), "%02X", (unsigned)m.lastBytes[i]);
    scrText(g, (i % 7) * 3 * VFD5X7_ADVANCE, scrLineY(1 + i / 7), buf);
  }
}

// BAT  3.92V 68% | --
// CAP  272 OF 400MAH | -- OF 400MAH          (hold PRG here: the next capacity, highlighted)
// RUN  ~9H 40M LEFT | CHARGING | USB POWER | --
// UP   0D 02:14:09
// BLE  MM_ESP DD:EE:FF
// FW   1.2 HELTEC V3
static void scrPageDevice(u8g2_t* g, const ScreenModel& m) {
  char buf[32];
  char run[12];
  scrHeader(g, "DEVICE", PAGE_DEVICE);
  scrLabel(g, 0, "BAT");
  if (m.batteryMv < 0) {
    scrValue(g, 0, "--");
  } else {
    snprintf(buf, sizeof(buf), "%ld.%02ldV %d%%", (long)(m.batteryMv / 1000), (long)((m.batteryMv % 1000) / 10),
             (int)(m.batteryPct < 0 ? 0 : m.batteryPct));
    scrValue(g, 0, buf);
  }
  scrLabel(g, 1, "CAP");
  if (m.batteryLeftMah < 0) snprintf(buf, sizeof(buf), "-- OF %uMAH", (unsigned)m.batteryCapMah);
  else                      snprintf(buf, sizeof(buf), "%ld OF %uMAH", (long)m.batteryLeftMah, (unsigned)m.batteryCapMah);
  if (m.capMark) scrValueInverse(g, 1, buf);
  else           scrValue(g, 1, buf);
  scrLabel(g, 2, "RUN");
  if (m.batteryPct < 0) {
    scrValue(g, 2, "--");
  } else if (m.usb) {
    scrValue(g, 2, "USB POWER");
  } else if (m.charging) {
    scrValue(g, 2, "CHARGING");
  } else if (m.runtimeMin >= 0) {
    scrRuntime(run, sizeof(run), m.runtimeMin);
    snprintf(buf, sizeof(buf), "%s LEFT", run);
    scrValue(g, 2, buf);
  } else {
    scrValue(g, 2, "--");
  }
  scrLabel(g, 3, "UP");
  const uint32_t s = m.uptimeS;
  snprintf(buf, sizeof(buf), "%luD %02lu:%02lu:%02lu", (unsigned long)(s / 86400), (unsigned long)(s / 3600 % 24),
           (unsigned long)(s / 60 % 60), (unsigned long)(s % 60));
  scrValue(g, 3, buf);
  scrLabel(g, 4, "BLE");
  snprintf(buf, sizeof(buf), "%s %s", m.bleName ? m.bleName : "", m.bleAddr[0] ? m.bleAddr : "--");
  scrValue(g, 4, buf);
  scrLabel(g, 5, "FW");
  snprintf(buf, sizeof(buf), "%s %s", m.fwVersion ? m.fwVersion : "", m.boardLabel ? m.boardLabel : "");
  scrValue(g, 5, buf);
}

// Clears the frame buffer and draws one page into it (nothing is sent to the panel here).
static void scrDrawPage(u8g2_t* g, uint8_t page, const ScreenModel& m) {
  u8g2_ClearBuffer(g);
  u8g2_SetDrawColor(g, 1);
  switch (page) {
    case PAGE_PACKET: scrPagePacket(g, m); break;
    case PAGE_DEVICE: scrPageDevice(g, m); break;
    default:          scrPageStatus(g, m); break;
  }
}
