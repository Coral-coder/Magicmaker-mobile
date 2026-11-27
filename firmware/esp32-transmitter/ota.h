// ota.h - firmware updates over Bluetooth from the MagicMaker app.
//
// One extra characteristic on the relay service (OTA_UUID: write, write-without-response,
// notify). The app streams the APP image (the bytes a merged release image holds from
// offset 0x10000) into the spare OTA slot; the board checks it and reboots into it. If
// anything goes wrong the running firmware stays the boot image.
//
// Safety: an update is only accepted for OTA_ARM_MS after the board's button was pressed
// (PRG on the Heltec V3, BOOT on a classic DevKit; both GPIO0), so nobody nearby can flash
// the board without physical access. Integrity: the app sends the image's MD5 with BEGIN
// (checked by Update), and the bootloader-format image carries its own SHA-256 that
// esp_ota_end() verifies, including the chip type (an ESP32 image can't land on an S3).
//
// Wire format (all integers little-endian):
//   app -> board (write with response, except DATA which may be write-without-response)
//     01 BEGIN  [u32 size][16-byte MD5]
//     02 DATA   [u32 offset][bytes...]          bytes must continue at the expected offset
//     03 END
//     04 ABORT
//     05 QUERY
//   board -> app (notify): [0x80 | op][status][u32 value][optional ASCII text]
//     status 0 = OK; errors below. value = next expected offset (BEGIN/DATA/ERR_OFFSET),
//     image size (END), or armed seconds left (QUERY). QUERY text:
//     "MMFW:<fw version>:<board>;s=<state>;o=<offset>;n=<size>" (board = heltec-v3 | esp32;
//     state 0 idle, 1 receiving, 2 done, 3 error). The same "MMFW:<version>:<board>" marker
//     is in every image, so the app can read the version of a bundled/downloaded image.
//     During DATA an OK ack is sent every OTA_ACK_EVERY bytes (and on any error), so the
//     app can keep a bounded window of bytes in flight.

#pragma once
#include <NimBLEDevice.h>
#include <Update.h>
#include "board.h"

static const char*    OTA_UUID       = "A7830007-0000-1000-8000-00805F9B34FB";
static const uint32_t OTA_ARM_MS     = 120000;   // update window after a button press
static const uint8_t  OTA_BUTTON_PIN = 0;        // PRG (Heltec V3) / BOOT (DevKit), LOW = down
static const uint32_t OTA_ACK_EVERY  = 4096;     // progress ack spacing (bytes)
static const uint32_t OTA_MAX_SIZE   = 0x300000; // sanity cap; Update checks the real slot

// Version marker the app can find inside a downloaded image ("MMFW:<version>:<board>", board =
// heltec-v3 | esp32).
#if MM_HELTEC_V3
static const char MM_FW_TAG[] = "MMFW:" MM_FW_VERSION ":heltec-v3";
#else
static const char MM_FW_TAG[] = "MMFW:" MM_FW_VERSION ":esp32";
#endif

enum : uint8_t { OTA_OP_BEGIN = 0x01, OTA_OP_DATA = 0x02, OTA_OP_END = 0x03,
                 OTA_OP_ABORT = 0x04, OTA_OP_QUERY = 0x05 };
enum : uint8_t { OTA_OK = 0, OTA_ERR_NOT_ARMED = 1, OTA_ERR_SIZE = 2, OTA_ERR_BEGIN = 3,
                 OTA_ERR_OFFSET = 4, OTA_ERR_WRITE = 5, OTA_ERR_VERIFY = 6, OTA_ERR_STATE = 7,
                 OTA_ERR_FORMAT = 8 };
enum : uint8_t { OTA_ST_IDLE = 0, OTA_ST_RECEIVING = 1, OTA_ST_DONE = 2, OTA_ST_ERROR = 3 };

static NimBLECharacteristic* gOtaChar = nullptr;
static volatile uint32_t gOtaArmedAt  = 0;      // millis() of the last button press (loop)
static volatile bool     gOtaArmed    = false;  // a press happened since boot (loop)
static volatile uint8_t  gOtaState    = OTA_ST_IDLE;
static uint32_t          gOtaSize     = 0;      // NimBLE task only
static uint32_t          gOtaOffset   = 0;      // NimBLE task only
static uint32_t          gOtaLastAck  = 0;      // NimBLE task only
static volatile uint32_t gOtaRebootAt = 0;      // set by END, acted on in loop()
static volatile bool     gOtaAbortReq = false;  // set on disconnect, acted on in loop()

static TaskHandle_t      gOtaWakeTask = nullptr; // loop()'s task: woken for a restart / BOOT press

static void otaWakeLoop() {
  if (gOtaWakeTask) xTaskNotifyGive(gOtaWakeTask);
}

#if !MM_HELTEC_V3
// Classic boards: BOOT wakes loop() at once (on the Heltec the screen's PRG interrupt does).
static void IRAM_ATTR otaButtonIsr() {
  BaseType_t woken = pdFALSE;
  if (gOtaWakeTask) vTaskNotifyGiveFromISR(gOtaWakeTask, &woken);
  if (woken) portYIELD_FROM_ISR();
}
#endif

static bool otaArmedNow(uint32_t now) {
  return gOtaArmed && (now - gOtaArmedAt) < OTA_ARM_MS;
}

static void otaNotify(uint8_t op, uint8_t status, uint32_t value, const char* text = nullptr) {
  if (!gOtaChar) return;
  uint8_t buf[96];
  size_t n = 0;
  buf[n++] = (uint8_t)(0x80 | op);
  buf[n++] = status;
  buf[n++] = (uint8_t)(value & 0xFF);
  buf[n++] = (uint8_t)((value >> 8) & 0xFF);
  buf[n++] = (uint8_t)((value >> 16) & 0xFF);
  buf[n++] = (uint8_t)((value >> 24) & 0xFF);
  if (text) {
    size_t t = strlen(text);
    if (t > sizeof(buf) - n) t = sizeof(buf) - n;
    memcpy(buf + n, text, t);
    n += t;
  }
  gOtaChar->setValue(buf, n);
  gOtaChar->notify();
}

static uint32_t rdU32(const uint8_t* p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void otaFail(uint8_t op, uint8_t status, uint32_t value) {
  if (Update.isRunning()) Update.abort();
  gOtaState = OTA_ST_ERROR;
  otaNotify(op, status, value);
}

class OtaCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c) override {
    std::string v = c->getValue();
    const uint8_t* p = (const uint8_t*)v.data();
    const size_t len = v.size();
    if (len < 1) return;
    const uint8_t op = p[0];
    const uint32_t now = millis();

    if (op == OTA_OP_QUERY) {
      char text[88];
      snprintf(text, sizeof(text), "%s;s=%u;o=%lu;n=%lu", MM_FW_TAG,
               (unsigned)gOtaState, (unsigned long)gOtaOffset, (unsigned long)gOtaSize);
      const uint32_t left = otaArmedNow(now) ? (OTA_ARM_MS - (now - gOtaArmedAt)) / 1000 : 0;
      otaNotify(op, OTA_OK, left, text);
      return;
    }

    if (op == OTA_OP_BEGIN) {
      if (!otaArmedNow(now)) { otaNotify(op, OTA_ERR_NOT_ARMED, 0); return; }
      if (len < 1 + 4 + 16) { otaNotify(op, OTA_ERR_FORMAT, 0); return; }
      const uint32_t size = rdU32(p + 1);
      if (size < 0x1000 || size > OTA_MAX_SIZE) { otaNotify(op, OTA_ERR_SIZE, size); return; }
      if (Update.isRunning()) Update.abort();
      if (!Update.begin(size, U_FLASH)) { otaFail(op, OTA_ERR_BEGIN, size); return; }
      char md5hex[33];
      for (int i = 0; i < 16; i++) snprintf(md5hex + i * 2, 3, "%02x", p[5 + i]);
      Update.setMD5(md5hex);
      gOtaSize = size;
      gOtaOffset = 0;
      gOtaLastAck = 0;
      gOtaState = OTA_ST_RECEIVING;
      otaNotify(op, OTA_OK, 0);
      return;
    }

    if (op == OTA_OP_DATA) {
      if (gOtaState != OTA_ST_RECEIVING) { otaNotify(op, OTA_ERR_STATE, gOtaOffset); return; }
      if (len < 1 + 4) { otaNotify(op, OTA_ERR_FORMAT, gOtaOffset); return; }
      const uint32_t off = rdU32(p + 1);
      if (off != gOtaOffset) { otaNotify(op, OTA_ERR_OFFSET, gOtaOffset); return; }
      size_t n = len - 5;
      if (gOtaOffset + n > gOtaSize) { otaFail(op, OTA_ERR_SIZE, gOtaOffset); return; }
      if (n > 0 && Update.write((uint8_t*)(p + 5), n) != n) { otaFail(op, OTA_ERR_WRITE, gOtaOffset); return; }
      gOtaOffset += (uint32_t)n;
      if (gOtaOffset - gOtaLastAck >= OTA_ACK_EVERY || gOtaOffset == gOtaSize) {
        gOtaLastAck = gOtaOffset;
        otaNotify(op, OTA_OK, gOtaOffset);
      }
      return;
    }

    if (op == OTA_OP_END) {
      if (gOtaState != OTA_ST_RECEIVING || gOtaOffset != gOtaSize) {
        otaNotify(op, OTA_ERR_STATE, gOtaOffset);
        return;
      }
      // Checks the MD5 from BEGIN and the image itself (format, chip, appended SHA-256),
      // then makes it the boot partition.
      if (!Update.end(false)) { otaFail(op, OTA_ERR_VERIFY, gOtaOffset); return; }
      gOtaState = OTA_ST_DONE;
      otaNotify(op, OTA_OK, gOtaSize);
      gOtaRebootAt = now + 1500; // let the reply go out, then restart into the new image
      if (gOtaRebootAt == 0) gOtaRebootAt = 1;
      otaWakeLoop();
      return;
    }

    if (op == OTA_OP_ABORT) {
      if (Update.isRunning()) Update.abort();
      gOtaState = OTA_ST_IDLE;
      gOtaOffset = 0;
      otaNotify(op, OTA_OK, 0);
      return;
    }

    otaNotify(op, OTA_ERR_FORMAT, 0);
  }
};

// setup(), from loop()'s task: add the OTA characteristic to the relay service (before
// svc->start()). On the Heltec the screen code already owns GPIO0's pin mode and interrupt.
static void otaSetup(NimBLEService* svc) {
  gOtaWakeTask = xTaskGetCurrentTaskHandle();
#if !MM_HELTEC_V3
  pinMode(OTA_BUTTON_PIN, INPUT_PULLUP);
  attachInterrupt(OTA_BUTTON_PIN, otaButtonIsr, FALLING);
#endif
  gOtaChar = svc->createCharacteristic(
      OTA_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::NOTIFY);
  gOtaChar->setCallbacks(new OtaCallbacks());
}

// NimBLE disconnect callback: an interrupted transfer is dropped (in loop()).
static void otaOnDisconnect() {
  if (gOtaState == OTA_ST_RECEIVING) gOtaAbortReq = true;
  otaWakeLoop();
}

// An update is being received (the POWER page refuses its hold; power_off answers "busy").
static bool otaBusy() { return gOtaState == OTA_ST_RECEIVING; }

// Power-off: a finished update waiting to restart is not restarted (the new image is already the
// boot partition, so it starts at the next RST).
static void otaCancelRestart() { gOtaRebootAt = 0; }

// loop()'s sleep: wake for a pending restart.
static uint32_t otaNextDueMs(uint32_t now) {
  if (gOtaRebootAt == 0) return 0xFFFFFFFFu;
  const int32_t left = (int32_t)(gOtaRebootAt - now);
  return left <= 0 ? 0 : (uint32_t)left;
}

// loop(): button arming (the button held = armed; the window runs OTA_ARM_MS from the last
// time it was seen down), abort after a lost link, restart after a finished update.
static void otaLoop() {
  const uint32_t now = millis();
  if (digitalRead(OTA_BUTTON_PIN) == LOW) {
    gOtaArmedAt = now;
    gOtaArmed = true;
  }
  if (gOtaAbortReq) {
    gOtaAbortReq = false;
    if (gOtaState == OTA_ST_RECEIVING) {
      if (Update.isRunning()) Update.abort();
      gOtaState = OTA_ST_IDLE;
      gOtaOffset = 0;
    }
  }
  if (gOtaRebootAt != 0 && (int32_t)(now - gOtaRebootAt) >= 0) {
    delay(50);
    ESP.restart();
  }
}
