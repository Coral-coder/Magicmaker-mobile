// MagicMaker ESP32 transmitter
// -----------------------------
// A tiny, battery-friendly BLE relay that lets the iPhone (or Android) app keep
// scanning while THIS board does the transmitting. The phone connects over BLE and
// writes a packet to broadcast; the ESP32 advertises it as Disney manufacturer data,
// waking the band exactly the way the phone's own transmitter does.
//
// It speaks the app's relay GATT contract (RelayProtocol), the same one the Android relay serves:
//
//   Service  A7830001-0000-1000-8000-00805F9B34FB
//     TX     A7830002…   write  "{hex}|{durationMs}"  -> broadcast this packet (newest wins)
//     CMD    A7830003…   write  {"action":…}          -> transmit, keep-awake, loops, settings (relay_proto.h)
//     STATUS A7830004…   read   {json}                -> last command's ok/error + the chip's state
//     CATALOG A7830005…  read   {json}                -> shared library (always empty: it lives on the phone)
//
// The chip NEVER scans: scanning, logging, auto-responses and the library stay on the phone. What
// it runs by itself, with or without a phone linked, is one program at a time: keep-awake (stream
// a wake ping so the band keeps listening), a TX loop or a wand loop (relay_engine.h). Programs
// and settings live in RAM only, so the board always boots idle; the iPhone pushes its settings
// and reads the running program back from STATUS when it links.
//
// Board: any ESP32 (classic/S3/C3). Library: NimBLE-Arduino (h2zero) 1.4.x.
//   Arduino IDE: Tools -> Manage Libraries -> "NimBLE-Arduino".
// Flash: select your ESP32 board, Upload. No secrets, no Wi-Fi.
//
// Heltec WiFi LoRa 32 V3 / V3.1 / V3.2: pick that board and also install "U8g2" (olikraus).
// The build detects the board (board.h) and adds the onboard OLED, which stays dark and
// unpowered until you press PRG (oled_ui.h). Every other board builds exactly as before.
//
// Power: 80 MHz CPU, the Disney beacon only on air while something is being sent (full power
// only then), idle advertising that relaxes after 30 s, +3 dBm for idle advertising and the
// link, and loop() asleep until its next deadline (a command, a phase end, an LED edge, the PRG
// button) instead of polling. Heltec V3: the LoRa radio asleep, the screen unpowered unless PRG
// is used, and the battery read once a minute for its % and expected runtime (power.h).

#include <NimBLEDevice.h>
#include <esp_timer.h>
#include "board.h"
#include "ota.h"   // firmware updates over Bluetooth from the app (button-armed, A7830007)
#include "relay_proto.h"
#include "relay_engine.h"
#if MM_HELTEC_V3
#include "oled_ui.h"
#endif

// ---- RelayProtocol contract (must match the app) -------------------------------------
static const char* SERVICE_UUID  = "A7830001-0000-1000-8000-00805F9B34FB";
static const char* TRANSMIT_UUID = "A7830002-0000-1000-8000-00805F9B34FB";
static const char* COMMAND_UUID  = "A7830003-0000-1000-8000-00805F9B34FB";
static const char* STATUS_UUID   = "A7830004-0000-1000-8000-00805F9B34FB";
static const char* CATALOG_UUID  = "A7830005-0000-1000-8000-00805F9B34FB";
// Incognito name (the iPhone app also still accepts the older "MagicMaker-ESP32").
static const char* DEVICE_NAME   = "MM_ESP";
static const char* EMPTY_CATALOG = "{\"ok\":true,\"items\":[]}";

// ---- Transmit timing (chip settings at boot; the phone's values replace them on link) --
// Band commands: stream the wake ping, then stream the command (sustained), or 1:1 wake/command
// slices over the command window (interleave). Wands and pings are a single burst. A duration
// written with the packet ("{hex}|{ms}") replaces the default for that send.
static const uint16_t DEFAULT_WAKE_MS     = 520;    // wake-ping stream before a band command
static const uint16_t DEFAULT_CMD_MS      = 4000;   // band command stream
static const uint16_t DEFAULT_STAR_MS     = 500;    // wand burst
static const uint16_t PING_MS             = 2000;   // standalone ping burst
static const uint8_t  DEFAULT_POWER_LEVEL = 3;      // beacon power 0..3 = -12 / -6 / 0 / +9 dBm
static const uint32_t LOOP_DEFAULT_MS     = 3000;   // TX / wand loop interval until the phone sends one
// Wire clamps (raw_burst 60..10000 ms, TX char 60..12000 ms, loops 500..60000 ms, ...) are the
// relay contract and live in relay_proto.h.

// Advertising intervals (units of 0.625 ms). Short during a burst for reliable waking; while
// waiting for a phone, quicker for 30 s after boot or a disconnect (fast relink), then relaxed
// (Apple's recommended 546.25 / 760 ms pair).
static const uint16_t BEACON_ADV_MIN      = 0x20;   // 20 ms  (burst)
static const uint16_t BEACON_ADV_MAX      = 0x30;   // 30 ms
static const uint16_t IDLE_ADV_FAST_MIN   = 0x140;  // 200 ms (just booted / phone just left)
static const uint16_t IDLE_ADV_FAST_MAX   = 0x280;  // 400 ms
static const uint16_t IDLE_ADV_SLOW_MIN   = 0x36A;  // 546.25 ms (after IDLE_FAST_WINDOW_MS)
static const uint16_t IDLE_ADV_SLOW_MAX   = 0x4C0;  // 760 ms
static const uint32_t IDLE_FAST_WINDOW_MS = 30000;
// TX power. Full power only where it matters, the Disney beacon (the app's TX power setting,
// 0..3 = -12 / -6 / 0 / +9 dBm); less for advertising while waiting for a phone and for the
// link to it (the phone is close by). Raise these to ESP_PWR_LVL_P9 if the link drops at range.
static const esp_power_level_t BEACON_POWER[4] = {ESP_PWR_LVL_N12, ESP_PWR_LVL_N6, ESP_PWR_LVL_N0, ESP_PWR_LVL_P9};
static const esp_power_level_t IDLE_ADV_POWER = ESP_PWR_LVL_P3;  // +3 dBm, waiting for a phone
static const esp_power_level_t LINK_POWER     = ESP_PWR_LVL_P3;  // +3 dBm, the connection (BLE default power)

// loop() sleeps until its next deadline (every one is tracked), at most this long.
static const uint32_t LOOP_MAX_SLEEP_MS   = 5000;
static const UBaseType_t CMD_QUEUE_DEPTH  = 8;

#if MM_HELTEC_V3
// Heltec V3 OLED: lit only while you use the PRG button; dark this long after the last press.
static const uint32_t SCREEN_ON_MS        = 10000;
// LiPo on the battery connector, rated capacity (STATUS "batMah", the screen's runtime). A
// capacity picked on the screen (hold PRG on the DEVICE page: 400 / 500 / 1000 / 1100 / 2000 /
// 3000 / 5000 mAh) replaces it and is kept across reboots. Draw estimates: battery_model.h.
static const uint16_t BATTERY_MAH         = 400;
#endif

#if MM_HELTEC_V3
static const int STATUS_LED = HV3_LED_PIN;  // white LED, GPIO35
#elif defined(LED_BUILTIN)
static const int STATUS_LED = LED_BUILTIN;
#else
static const int STATUS_LED = 2;
#endif

// ---- Status LED: short blinks only, never on steadily ---------------------------------
// Waiting for a phone: a tiny blink every second. Phone linked: a tiny blink every 5 s.
// Every job put on air (send, replay step, MBLE tap, loop burst): one short flash, at most one
// per LED_MIN_FLASH_GAP_MS so a dense replay still reads as blinks. The keep-awake stream does
// not flash. Driven from loop() only.
static const uint32_t LED_BLINK_MS         = 25;    // heartbeat blink length
static const uint32_t LED_WAITING_EVERY    = 1000;  // no phone linked
static const uint32_t LED_LINKED_EVERY     = 5000;  // phone linked
static const uint32_t LED_TX_FLASH_MS      = 60;    // one flash per job
static const uint32_t LED_MIN_FLASH_GAP_MS = 250;

// ---- State ---------------------------------------------------------------------------
// Owned by loop(): the engine, the advertising state, the LED. The NimBLE callbacks (host task)
// only parse, write the reply under gSnapMux, queue work and wake loop().
enum AdvKind : uint8_t { ADV_OFF = 0, ADV_IDLE, ADV_BEACON, ADV_HEARTBEAT };

// Battery heartbeat other devices read without connecting (the Android app's scanner shows it):
// manufacturer data, company id 0xFFFF (reserved for testing, so nothing mistakes it for a
// Disney packet): FF FF 'M' 'B' <version 1> <battery % or 0xFF> <flags> <runtime min, u16 LE or
// 0xFFFF>. flags: bit0 charging, bit1 on USB power, bit2 battery reading present.
// In the scan response while no phone is linked; while one is, a slow non-connectable advert
// (name + heartbeat) keeps it visible.
static const uint8_t  HEARTBEAT_LEN     = 9;
static const uint16_t HEARTBEAT_ADV_MIN = 0x640;  // 1 s
static const uint16_t HEARTBEAT_ADV_MAX = 0xC80;  // 2 s

struct AdvState {
  uint8_t kind;      // AdvKind
  bool    slow;      // idle: the slow interval
  bool    scanResp;  // beacon: answer scan requests with the name + service UUID (no phone linked)
  uint8_t power;     // beacon power level 0..3
  uint8_t hb[HEARTBEAT_LEN];  // idle / heartbeat: the battery heartbeat bytes
  uint8_t len;
  uint8_t bytes[RELAY_PACKET_MAX];
};

NimBLEServer*         gServer   = nullptr;
NimBLEAdvertising*    gAdv      = nullptr;

static RelayEngine    gEngine;
static AdvState       gAdvNow;              // what the advertiser is set up for
static QueueHandle_t  gCmdQueue = nullptr;  // ChipCmd: NimBLE task -> loop()
static TaskHandle_t   gLoopTask = nullptr;  // woken by commands, connects and PRG

// Shared with the NimBLE task (copied under gSnapMux, never formatted under it).
static portMUX_TYPE   gSnapMux = portMUX_INITIALIZER_UNLOCKED;
static RelaySnapshot  gSnap;    // written by loop()
static RelayReply     gReply;   // written by the CMD callback (and onConnect)

// NimBLE task only.
static RelayShadow    gShadow;  // loop packets the chip has been given

// Written by the NimBLE task, read by loop().
static volatile int      gLinked = 0;       // phones connected
static volatile uint32_t gDisconnects = 0;  // count, so loop() sees every one

// loop() only.
static uint32_t gIdleSince = 0;             // boot / last disconnect: the idle fast-advertising window
static uint32_t gSeenDisconnects = 0;
static uint32_t gSeenSent = 0;
static uint32_t gLedBeat = 0;               // last heartbeat (or flash) start
static uint32_t gLedOnUntil = 0;
static uint32_t gLedFlashAt = 0;
static bool     gLedFlashed = false;        // a flash happened since boot (gLedFlashAt valid)
static bool     gLedFlashWanted = false;
static bool     gLedOn = false;

// ---- Wake loop() ---------------------------------------------------------------------
static void wakeLoop() {
  if (gLoopTask) xTaskNotifyGive(gLoopTask);
}

// A characteristic value from a C string, without its NUL. (NimBLE's setValue(T) template would
// store a const char*'s pointer bytes, or a literal's trailing NUL.)
static void setText(NimBLECharacteristic* c, const char* text) {
  c->setValue((const uint8_t*)text, strlen(text));
}

// ---- Advertising manager (loop() only; the only code that drives gAdv) ------------------
static void heartbeatBytes(uint8_t out[HEARTBEAT_LEN]) {
  uint8_t pct = 0xFF, flags = 0;
  uint16_t runMin = 0xFFFF;
#if MM_HELTEC_V3
  if (powerBatteryMv() >= 0) {
    const int p = powerBatteryPct();
    pct = (uint8_t)(p < 0 ? 0 : (p > 100 ? 100 : p));
    flags |= 0x04;
    if (powerCharging()) flags |= 0x01;
    if (powerOnUsb()) flags |= 0x02;
    const int32_t r = powerRuntimeMin();
    if (r >= 0) runMin = (uint16_t)(r > 0xFFFE ? 0xFFFE : r);
  }
#endif
  out[0] = 0xFF; out[1] = 0xFF; out[2] = 'M'; out[3] = 'B'; out[4] = 1;
  out[5] = pct; out[6] = flags;
  out[7] = (uint8_t)(runMin & 0xFF); out[8] = (uint8_t)(runMin >> 8);
}

static bool advSame(const AdvState& a, const AdvState& b) {
  if (a.kind != b.kind) return false;
  if (a.kind == ADV_IDLE) return a.slow == b.slow && memcmp(a.hb, b.hb, HEARTBEAT_LEN) == 0;
  if (a.kind == ADV_HEARTBEAT) return memcmp(a.hb, b.hb, HEARTBEAT_LEN) == 0;
  if (a.kind == ADV_BEACON) {
    return a.scanResp == b.scanResp && a.power == b.power && a.len == b.len && memcmp(a.bytes, b.bytes, a.len) == 0;
  }
  return true;
}

static void advApply(const AdvState& want) {
  gAdv->stop();
  gAdvNow = want;
  if (want.kind == ADV_OFF) return;

  NimBLEAdvertisementData ad;
  NimBLEAdvertisementData scan;
  if (want.kind == ADV_IDLE) {
    // Waiting for a phone: flags + the 128-bit service UUID (how the app finds a relay). The
    // name goes in the scan response: the UUID nearly fills the 31-byte primary advert.
    NimBLEDevice::setPower(IDLE_ADV_POWER, ESP_BLE_PWR_TYPE_ADV);
    gAdv->setAdvertisementType(BLE_GAP_CONN_MODE_UND);
    ad.setFlags(0x06);
    ad.setCompleteServices(NimBLEUUID(SERVICE_UUID));
    scan.setName(DEVICE_NAME);
    scan.setManufacturerData(std::string((const char*)want.hb, HEARTBEAT_LEN));
    gAdv->setAdvertisementData(ad);
    gAdv->setScanResponseData(scan);
    gAdv->setScanResponse(true);
    gAdv->setMinInterval(want.slow ? IDLE_ADV_SLOW_MIN : IDLE_ADV_FAST_MIN);
    gAdv->setMaxInterval(want.slow ? IDLE_ADV_SLOW_MAX : IDLE_ADV_FAST_MAX);
  } else if (want.kind == ADV_HEARTBEAT) {
    // A phone is linked and nothing is on air: name + battery heartbeat, non-connectable and
    // slow (1-2 s), at the low idle power, so the other phone can see the battery.
    NimBLEDevice::setPower(IDLE_ADV_POWER, ESP_BLE_PWR_TYPE_ADV);
    gAdv->setAdvertisementType(BLE_GAP_CONN_MODE_NON);
    ad.setFlags(0x06);
    ad.setName(DEVICE_NAME);
    ad.setManufacturerData(std::string((const char*)want.hb, HEARTBEAT_LEN));
    gAdv->setAdvertisementData(ad);
    gAdv->setScanResponseData(scan);
    gAdv->setScanResponse(false);
    gAdv->setMinInterval(HEARTBEAT_ADV_MIN);
    gAdv->setMaxInterval(HEARTBEAT_ADV_MAX);
  } else {
    // The Disney manufacturer packet: [83 01][payload] = company id 0x0183 + payload, exactly the
    // decoded hex. Connectable, as always (a non-connectable advert has a 100 ms minimum
    // interval). With no phone linked the scan response carries the name and the service UUID,
    // so the app can find the board and relink in the middle of a keep-awake stream.
    NimBLEDevice::setPower(BEACON_POWER[want.power & 3], ESP_BLE_PWR_TYPE_ADV);
    gAdv->setAdvertisementType(BLE_GAP_CONN_MODE_UND);
    ad.setManufacturerData(std::string((const char*)want.bytes, want.len));
    if (want.scanResp) {
      scan.setName(DEVICE_NAME);
      scan.setCompleteServices(NimBLEUUID(SERVICE_UUID));
    }
    gAdv->setAdvertisementData(ad);
    gAdv->setScanResponseData(scan);
    gAdv->setScanResponse(want.scanResp);
    gAdv->setMinInterval(BEACON_ADV_MIN);
    gAdv->setMaxInterval(BEACON_ADV_MAX);
  }
  gAdv->start();
}

// Beacon while a job or the stream is on air; idle advertising while no phone is linked; else
// quiet (the link carries the next command). Restarts advertising that stopped by itself (a
// phone connecting ends a connectable advert).
static void advManage(uint32_t now, int linked) {
  AdvState want;
  memset(&want, 0, sizeof(want));
  uint8_t len = 0;
  const uint8_t* bytes = gEngine.airBytes(&len);
  if (bytes) {
    want.kind = ADV_BEACON;
    want.scanResp = linked == 0;
    want.power = gEngine.set.powerLevel;
    want.len = len;
    memcpy(want.bytes, bytes, len);
  } else if (linked == 0) {
    want.kind = ADV_IDLE;
    want.slow = now - gIdleSince >= IDLE_FAST_WINDOW_MS;
    heartbeatBytes(want.hb);
  } else {
    want.kind = ADV_HEARTBEAT;  // linked, nothing on air: the battery heartbeat
    heartbeatBytes(want.hb);
  }
  if (advSame(want, gAdvNow) && (want.kind == ADV_OFF || gAdv->isAdvertising())) return;
  advApply(want);
}

// ---- Status LED --------------------------------------------------------------------------
static void ledService(uint32_t now, int linked) {
  if (gLedFlashWanted && (!gLedFlashed || now - gLedFlashAt >= LED_MIN_FLASH_GAP_MS)) {
    gLedFlashWanted = false;
    gLedFlashed = true;
    gLedFlashAt = now;
    gLedOnUntil = now + LED_TX_FLASH_MS;
    gLedBeat = now;  // the next heartbeat counts from this flash
  }
  const uint32_t every = linked ? LED_LINKED_EVERY : LED_WAITING_EVERY;
  if ((int32_t)(gLedOnUntil - now) <= 0 && now - gLedBeat >= every) {
    gLedBeat = now;
    gLedOnUntil = now + LED_BLINK_MS;
  }
  const bool on = (int32_t)(gLedOnUntil - now) > 0;
  if (on != gLedOn) {
    gLedOn = on;
    digitalWrite(STATUS_LED, on ? HIGH : LOW);
  }
}

// ms until the LED next changes.
static uint32_t ledNextMs(uint32_t now, int linked) {
  if (gLedOn) {
    const int32_t d = (int32_t)(gLedOnUntil - now);
    return d > 0 ? (uint32_t)d : 0;
  }
  const uint32_t every = linked ? LED_LINKED_EVERY : LED_WAITING_EVERY;
  const uint32_t sinceBeat = now - gLedBeat;
  uint32_t d = sinceBeat >= every ? 0 : every - sinceBeat;
  if (gLedFlashWanted) {
    const uint32_t sinceFlash = now - gLedFlashAt;
    const uint32_t f = (!gLedFlashed || sinceFlash >= LED_MIN_FLASH_GAP_MS) ? 0 : LED_MIN_FLASH_GAP_MS - sinceFlash;
    if (f < d) d = f;
  }
  return d;
}

// ---- STATUS snapshot -----------------------------------------------------------------
static void publishSnapshot() {
  RelaySnapshot s;
  gEngine.snapshot(s);
#if MM_HELTEC_V3
  const int32_t mv = powerBatteryMv();
  if (mv >= 0) {
    s.batMv = mv;
    s.batPct = (int16_t)powerBatteryPct();
    s.batMah = powerCapacityMah();
    s.charging = powerCharging() || powerOnUsb();  // on USB power: no runtime either
    s.runMin = powerRuntimeMin();
  }
#endif
  portENTER_CRITICAL(&gSnapMux);
  gSnap = s;
  portEXIT_CRITICAL(&gSnapMux);
}

// ---- GATT callbacks (NimBLE host task) ---------------------------------------------------
class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* s, ble_gap_conn_desc* desc) override {
    gLinked = gLinked + 1;
    portENTER_CRITICAL(&gSnapMux);
    relayReplyOk(gReply);  // a fresh link starts from a clean reply
    portEXIT_CRITICAL(&gSnapMux);
    // Ask for a relaxed connection interval to cut idle wakeups (battery).
    s->updateConnParams(desc->conn_handle, 24, 40, 2, 400);  // 30–50 ms, latency 2, 4 s sup.
    wakeLoop();
  }
  void onDisconnect(NimBLEServer* s, ble_gap_conn_desc* desc) override {
    (void)s;
    (void)desc;
    // Programs and settings keep running: keep-awake and the loops do not need a phone.
    // loop() restarts advertising (advertiseOnDisconnect is off).
    if (gLinked > 0) gLinked = gLinked - 1;
    gDisconnects = gDisconnects + 1;
    otaOnDisconnect();                    // an interrupted firmware update is dropped
    wakeLoop();
  }
};

class TransmitCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c) override {
    // "{hex}|{durationMs}": a user send, the newest wins. Not a command: the reply stays as it is.
    const NimBLEAttValue v = c->getValue();
    ChipCmd cmd;
    if (!relayParseTransmitWrite((const char*)v.data(), v.length(), cmd)) return;
    if (xQueueSend(gCmdQueue, &cmd, 0) == pdTRUE) wakeLoop();
  }
};

class CommandCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c) override {
    // Parsed and answered here, before the write response goes out, so the app's STATUS read
    // right after sees this command's ok/error. loop() does the work.
    const NimBLEAttValue v = c->getValue();
    ChipCmd cmd;
    RelayReply reply;
    if (relayParseCommand((const char*)v.data(), v.length(), gShadow, cmd, reply)) {
      if (xQueueSend(gCmdQueue, &cmd, 0) == pdTRUE) {
        if (cmd.flags & RELAY_CMDF_PACKET) {
          if (cmd.type == RELAY_CMD_TX_LOOP) gShadow.haveTxLoopPacket = true;
          if (cmd.type == RELAY_CMD_WAND_LOOP) gShadow.haveWandLoopPacket = true;
        }
        wakeLoop();
      } else {
        relayReplyError(reply, "busy");
      }
    }
    portENTER_CRITICAL(&gSnapMux);
    gReply = reply;
    portEXIT_CRITICAL(&gSnapMux);
  }
};

class StatusCallbacks : public NimBLECharacteristicCallbacks {
  void onRead(NimBLECharacteristic* c) override {
    // The chip's state merged with the last command's reply. Formatted outside the lock; static
    // buffer (the NimBLE task's stack is small, and only that task reads characteristics).
    static char buf[512];
    RelaySnapshot s;
    RelayReply r;
    portENTER_CRITICAL(&gSnapMux);
    s = gSnap;
    r = gReply;
    portEXIT_CRITICAL(&gSnapMux);
    const uint32_t uptimeS = (uint32_t)(esp_timer_get_time() / 1000000LL);
    const size_t n = relayFormatStatus(s, r, uptimeS, MM_RELAY_PROTO, MM_FW_VERSION, MM_BOARD_LABEL, buf, sizeof(buf));
    c->setValue((const uint8_t*)buf, n);
  }
};

class CatalogCallbacks : public NimBLECharacteristicCallbacks {
  void onRead(NimBLECharacteristic* c) override {
    setText(c, EMPTY_CATALOG);
  }
};

// ---- Setup / loop --------------------------------------------------------------------
void setup() {
  gLoopTask = xTaskGetCurrentTaskHandle();  // Arduino runs setup() and loop() in loopTask
#if MM_HELTEC_V3
  screenBegin(SCREEN_ON_MS, DEVICE_NAME); // first thing: the OLED's Vext rail off from boot
  loraSleep();                            // the unused SX1262 out of standby (MM_LORA_SLEEP)
  powerBegin(BATTERY_MAH);                // battery capacity (NVS, read only), first reading in 100 ms
#endif
  pinMode(STATUS_LED, OUTPUT);
  digitalWrite(STATUS_LED, LOW);
  setCpuFrequencyMhz(80); // plenty for BLE (its 80 MHz APB clock is the floor); ~half the draw of 240 MHz.

  RelaySettings defaults;
  defaults.wakeMs = DEFAULT_WAKE_MS;
  defaults.cmdMs = DEFAULT_CMD_MS;
  defaults.starMs = DEFAULT_STAR_MS;
  defaults.pingMs = PING_MS;
  defaults.powerLevel = DEFAULT_POWER_LEVEL;
  defaults.interleave = false;
  gEngine.begin(defaults, LOOP_DEFAULT_MS);
  relayReplyOk(gReply);
  gEngine.snapshot(gSnap);
  gCmdQueue = xQueueCreate(CMD_QUEUE_DEPTH, sizeof(ChipCmd));

  NimBLEDevice::init(DEVICE_NAME);
  NimBLEDevice::setMTU(247);              // larger packets for firmware updates from the app
  NimBLEDevice::setPower(LINK_POWER);     // default (the link); advertising power is set per advert

  gServer = NimBLEDevice::createServer();
  gServer->setCallbacks(new ServerCallbacks());
  gServer->advertiseOnDisconnect(false);  // loop()'s advertising manager decides

  NimBLEService* svc = gServer->createService(SERVICE_UUID);
  NimBLECharacteristic* tx = svc->createCharacteristic(
      TRANSMIT_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  tx->setCallbacks(new TransmitCallbacks());
  NimBLECharacteristic* cmd = svc->createCharacteristic(
      COMMAND_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  cmd->setCallbacks(new CommandCallbacks());
  NimBLECharacteristic* status = svc->createCharacteristic(STATUS_UUID, NIMBLE_PROPERTY::READ);
  status->setCallbacks(new StatusCallbacks());
  setText(status, "{\"ok\":true}");  // replaced by onRead() on every read
  NimBLECharacteristic* catalog = svc->createCharacteristic(CATALOG_UUID, NIMBLE_PROPERTY::READ);
  catalog->setCallbacks(new CatalogCallbacks());
  setText(catalog, EMPTY_CATALOG);
  otaSetup(svc);                          // OTA characteristic (A7830007)

  svc->start();

  gAdv = NimBLEDevice::getAdvertising();
  memset(&gAdvNow, 0, sizeof(gAdvNow));
  gIdleSince = millis();
  advManage(gIdleSince, 0);  // idle, fast
}

void loop() {
  otaLoop();  // button arming, lost-link abort, restart after a firmware update
  // A phone left: advertise fast again for a while so it (or another) relinks quickly.
  const uint32_t disconnects = gDisconnects;
  if (disconnects != gSeenDisconnects) {
    gSeenDisconnects = disconnects;
    gIdleSince = millis();
  }

  // The phone's commands, oldest first (the newest send wins), then the clock.
  ChipCmd cmd;
  while (xQueueReceive(gCmdQueue, &cmd, 0) == pdTRUE) gEngine.apply(cmd, millis());
  gEngine.service(millis());

  const uint32_t now = millis();
  const int linked = gLinked;
  if (gEngine.sent != gSeenSent) {  // a job went on air: one LED flash (+ the screen's LAST PACKET)
    gSeenSent = gEngine.sent;
    gLedFlashWanted = true;
#if MM_HELTEC_V3
    const RelayStarted& st = gEngine.started;
    screenNotePacket(st.bytes, st.len, st.ms, st.wake, st.kind);
#endif
  }
  advManage(now, linked);
  ledService(now, linked);

#if MM_HELTEC_V3
  screenPoll(); // PRG button, screen power + timeout
  powerPoll(millis(), screenLit(), gEngine.job.type != RELAY_JOB_NONE, linked > 0);  // battery, runtime model
  if (screenFrameDue()) {
    ScreenInputs in;
    memset(&in, 0, sizeof(in));
    in.linked = linked > 0;
    in.program = gEngine.program;
    in.programIntervalMs = gEngine.loopIntervalMs();
    const RelayJob& job = gEngine.job;
    if (job.type == RELAY_JOB_NORMAL || job.type == RELAY_JOB_RAW) {
      in.txState = job.phase == RELAY_PHASE_WAKE ? SCREEN_TX_WAKE : SCREEN_TX_SEND;
      in.txPermille = gEngine.phasePermille(millis());
    } else {
      in.txState = SCREEN_TX_IDLE;  // nothing on air, or the keep-awake stream (STATUS line 2 says so)
    }
    screenDraw(in);
  }
#endif

  publishSnapshot();

  // Sleep until the next deadline; a command, a connect/disconnect or PRG wakes us sooner.
  const uint32_t after = millis();
  uint32_t waitMs = LOOP_MAX_SLEEP_MS;
  const uint32_t engineMs = gEngine.msUntilDue(after);
  if (engineMs < waitMs) waitMs = engineMs;
  const uint32_t ledMs = ledNextMs(after, linked);
  if (ledMs < waitMs) waitMs = ledMs;
  if (linked == 0 && gEngine.job.type == RELAY_JOB_NONE && after - gIdleSince < IDLE_FAST_WINDOW_MS) {
    const uint32_t slowMs = IDLE_FAST_WINDOW_MS - (after - gIdleSince);  // idle advertising slows down
    if (slowMs < waitMs) waitMs = slowMs;
  }
#if MM_HELTEC_V3
  const uint32_t screenMs = screenNextDueMs(after);
  if (screenMs < waitMs) waitMs = screenMs;
  const uint32_t powerMs = powerNextDueMs(after);
  if (powerMs < waitMs) waitMs = powerMs;
#endif
  const uint32_t otaMs = otaNextDueMs(after);
  if (otaMs < waitMs) waitMs = otaMs;
  if (waitMs < 1) waitMs = 1;
  ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(waitMs));
}
