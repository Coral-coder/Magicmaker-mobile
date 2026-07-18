// MagicMaker ESP32 transmitter
// -----------------------------
// A tiny, battery-friendly BLE relay that lets the iPhone (or Android) app keep
// scanning while THIS board does the transmitting. The phone connects over BLE and
// writes a packet to broadcast; the ESP32 advertises it as Disney manufacturer data,
// waking the band exactly the way the phone's own transmitter does.
//
// It speaks the app's existing relay GATT contract (RelayProtocol), so no app-side
// protocol changes are needed — the app already knows how to talk to this service:
//
//   Service  A7830001-0000-1000-8000-00805F9B34FB
//     TX     A7830002…   write  "{hex}|{durationMs}"  -> broadcast this packet
//     CMD    A7830003…   write  {json}                -> control/library (minimal here)
//     STATUS A7830004…   read   {json}                -> last command reply / telemetry
//     CATALOG A7830005…  read   {json}                -> shared library (empty here)
//
// Board: any ESP32 (classic/S3/C3). Library: NimBLE-Arduino (h2zero) >= 1.4.0
//   Arduino IDE: Tools -> Manage Libraries -> "NimBLE-Arduino".
// Flash: select your ESP32 board, Upload. No secrets, no Wi-Fi.
//
// Power: NimBLE + 80 MHz CPU + relaxed advertising is a few mA idle — good for a
// backpack battery. The Disney beacon only goes on air during a transmit burst.

#include <NimBLEDevice.h>

// ---- RelayProtocol contract (must match the app) -------------------------------------
static const char* SERVICE_UUID  = "A7830001-0000-1000-8000-00805F9B34FB";
static const char* TRANSMIT_UUID = "A7830002-0000-1000-8000-00805F9B34FB";
static const char* COMMAND_UUID  = "A7830003-0000-1000-8000-00805F9B34FB";
static const char* STATUS_UUID   = "A7830004-0000-1000-8000-00805F9B34FB";
static const char* CATALOG_UUID  = "A7830005-0000-1000-8000-00805F9B34FB";
static const char* DEVICE_NAME   = "MagicMaker-ESP32";

// ---- Transmit timing (mirrors the phone's sustained wake->command model) -------------
// Band commands: stream the wake ping, then stream the command. Starlight wands / pings
// are a single burst (no wakeup). Defaults match the app; the wire duration overrides the
// command length when it looks sane.
static const uint32_t WAKE_MS         = 520;    // wake-ping stream length
static const uint32_t DEFAULT_CMD_MS  = 4000;   // command stream length (default)
static const uint32_t MIN_CMD_MS      = 300;
static const uint32_t MAX_CMD_MS      = 12000;
static const char*    WAKEUP_PING_HEX = "8301CC03000100";

// Advertising intervals (units of 0.625 ms). Short during a burst for reliable waking;
// relaxed while idle-connectable to save power.
static const uint16_t BEACON_ADV_MIN  = 0x20;   // 20 ms  (burst)
static const uint16_t BEACON_ADV_MAX  = 0x30;   // 30 ms
static const uint16_t IDLE_ADV_MIN    = 0x140;  // 200 ms (waiting for a phone)
static const uint16_t IDLE_ADV_MAX    = 0x280;  // 400 ms

#ifdef LED_BUILTIN
static const int STATUS_LED = LED_BUILTIN;
#else
static const int STATUS_LED = 2;
#endif

// ---- State ---------------------------------------------------------------------------
NimBLEServer*         gServer   = nullptr;
NimBLEAdvertising*    gAdv      = nullptr;
NimBLECharacteristic* gStatus   = nullptr;
NimBLECharacteristic* gCatalog  = nullptr;

volatile bool  gConnected = false;
std::string    gLastCommandReply = "{\"ok\":true}";

// Non-blocking transmit job, driven from loop().
enum TxPhase : uint8_t { TX_IDLE, TX_WAKE, TX_COMMAND };
TxPhase   gPhase       = TX_IDLE;
uint32_t  gPhaseEndMs  = 0;
uint32_t  gCmdMs       = DEFAULT_CMD_MS;
uint8_t   gCmdBytes[31];
size_t    gCmdLen      = 0;
uint8_t   gWakeBytes[31];
size_t    gWakeLen     = 0;
bool      gCmdNeedsWake = true;

// A single pending request (newest wins — a fresh tap preempts an in-flight burst).
volatile bool gHasPending = false;
uint8_t  gPendingBytes[31];
size_t   gPendingLen = 0;
uint32_t gPendingCmdMs = DEFAULT_CMD_MS;
portMUX_TYPE gPendingMux = portMUX_INITIALIZER_UNLOCKED;

// ---- Hex helpers ---------------------------------------------------------------------
static int hexNibble(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// Decode a hex string into bytes (ignoring non-hex chars). Returns byte count.
static size_t hexToBytes(const char* hex, size_t hexLen, uint8_t* out, size_t maxOut) {
  size_t n = 0;
  int hi = -1;
  for (size_t i = 0; i < hexLen && n < maxOut; i++) {
    int v = hexNibble(hex[i]);
    if (v < 0) continue;
    if (hi < 0) { hi = v; }
    else { out[n++] = (uint8_t)((hi << 4) | v); hi = -1; }
  }
  return n;
}

static bool startsWith(const uint8_t* b, size_t len, uint8_t a, uint8_t c) {
  return len >= 2 && b[0] == a && b[1] == c;
}

// Starlight wand packets carry the CF9B / CF0B marker — a single burst, no band wakeup.
static bool isStarlight(const uint8_t* b, size_t len) {
  for (size_t i = 0; i + 1 < len; i++) {
    if (b[i] == 0xCF && (b[i + 1] == 0x9B || b[i + 1] == 0x0B)) return true;
  }
  return false;
}

// Standalone ping: 8301CC03… with no effect payload — also a single burst.
static bool isStandalonePing(const uint8_t* b, size_t len) {
  if (!(len >= 4 && b[0] == 0x83 && b[1] == 0x01 && b[2] == 0xCC && b[3] == 0x03)) return false;
  for (size_t i = 0; i < len; i++) if (b[i] == 0xE9) return false;
  return true;
}

// ---- Advertising ---------------------------------------------------------------------
static void startIdleAdvertising() {
  gAdv->stop();
  // Primary ADV carries flags + the 128-bit service UUID (how the app discovers a relay).
  NimBLEAdvertisementData ad;
  ad.setFlags(0x06);
  ad.setCompleteServices(NimBLEUUID(SERVICE_UUID)); // NimBLEAdvertisementData uses this, not addServiceUUID
  // The full name goes in the SCAN RESPONSE — a 128-bit UUID already nearly fills the 31-byte
  // primary ADV, so putting the name there too would truncate it. The app needs the complete
  // "MagicMaker-ESP32" name to tell this board apart from a standalone Android relay (which
  // advertises the same service UUID).
  NimBLEAdvertisementData scan;
  scan.setName(DEVICE_NAME);
  gAdv->setAdvertisementData(ad);
  gAdv->setScanResponseData(scan);
  gAdv->setScanResponse(true);
  gAdv->setMinInterval(IDLE_ADV_MIN);
  gAdv->setMaxInterval(IDLE_ADV_MAX);
  gAdv->start();
}

// Put the Disney manufacturer packet on air. `bytes` is the full field: [83 01][payload],
// i.e. company id 0x0183 (little-endian) followed by the payload — exactly the decoded hex.
static void startBeacon(const uint8_t* bytes, size_t len) {
  gAdv->stop();
  NimBLEAdvertisementData ad;
  ad.setManufacturerData(std::string((const char*)bytes, len));
  gAdv->setAdvertisementData(ad);
  gAdv->setScanResponse(false);
  gAdv->setMinInterval(BEACON_ADV_MIN);
  gAdv->setMaxInterval(BEACON_ADV_MAX);
  gAdv->start();
  digitalWrite(STATUS_LED, HIGH);
}

static void stopBeacon() {
  gAdv->stop();
  digitalWrite(STATUS_LED, gConnected ? HIGH : LOW);
  // Idle: only re-advertise (connectable) when no phone is linked; while connected we stay
  // quiet to save power and let the connection carry the next command.
  if (!gConnected) startIdleAdvertising();
}

// ---- Transmit state machine ----------------------------------------------------------
static void beginTransmit(const uint8_t* bytes, size_t len, uint32_t cmdMs) {
  if (len < 2) return;
  memcpy(gCmdBytes, bytes, len);
  gCmdLen = len;
  gCmdMs = (cmdMs >= MIN_CMD_MS && cmdMs <= MAX_CMD_MS) ? cmdMs : DEFAULT_CMD_MS;

  if (isStarlight(bytes, len) || isStandalonePing(bytes, len)) {
    gCmdNeedsWake = false;
    startBeacon(gCmdBytes, gCmdLen);
    gPhase = TX_COMMAND;
    gPhaseEndMs = millis() + gCmdMs;
    return;
  }

  // Band command: wake first, then the command (sustained model).
  gCmdNeedsWake = true;
  gWakeLen = hexToBytes(WAKEUP_PING_HEX, strlen(WAKEUP_PING_HEX), gWakeBytes, sizeof(gWakeBytes));
  startBeacon(gWakeBytes, gWakeLen);
  gPhase = TX_WAKE;
  gPhaseEndMs = millis() + WAKE_MS;
}

static void serviceTransmit() {
  // A newer request always wins (matches the app's "a fresh tap preempts" behaviour).
  if (gHasPending) {
    uint8_t bytes[31]; size_t len; uint32_t cmdMs;
    portENTER_CRITICAL(&gPendingMux);
    len = gPendingLen; memcpy(bytes, gPendingBytes, len); cmdMs = gPendingCmdMs;
    gHasPending = false;
    portEXIT_CRITICAL(&gPendingMux);
    beginTransmit(bytes, len, cmdMs);
    return;
  }

  if (gPhase == TX_IDLE) return;
  if ((int32_t)(millis() - gPhaseEndMs) < 0) return; // phase still running

  if (gPhase == TX_WAKE) {
    startBeacon(gCmdBytes, gCmdLen);
    gPhase = TX_COMMAND;
    gPhaseEndMs = millis() + gCmdMs;
  } else { // TX_COMMAND finished
    gPhase = TX_IDLE;
    stopBeacon();
  }
}

// ---- GATT callbacks ------------------------------------------------------------------
class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* s, ble_gap_conn_desc* desc) override {
    gConnected = true;
    digitalWrite(STATUS_LED, HIGH);
    // Ask for a relaxed connection interval to cut idle wakeups (battery).
    s->updateConnParams(desc->conn_handle, 24, 40, 2, 400); // 30–50 ms, latency 2, 4 s sup.
  }
  void onDisconnect(NimBLEServer* s, ble_gap_conn_desc* desc) override {
    gConnected = false;
    if (gPhase == TX_IDLE) { digitalWrite(STATUS_LED, LOW); startIdleAdvertising(); }
    else startIdleAdvertising(); // resume connectable adv; beacon keeps running if mid-burst
  }
};

class TransmitCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c) override {
    std::string v = c->getValue();
    int pipe = (int)v.rfind('|');
    if (pipe <= 0) return;
    std::string hex = v.substr(0, pipe);
    uint32_t dur = (uint32_t)strtoul(v.c_str() + pipe + 1, nullptr, 10);
    uint8_t bytes[31];
    size_t len = hexToBytes(hex.c_str(), hex.size(), bytes, sizeof(bytes));
    if (len < 2) return;
    portENTER_CRITICAL(&gPendingMux);
    memcpy(gPendingBytes, bytes, len); gPendingLen = len; gPendingCmdMs = dur;
    gHasPending = true;
    portEXIT_CRITICAL(&gPendingMux);
  }
};

class CommandCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c) override {
    // We don't host a library — acknowledge every command so the app's link handshake and
    // catalog sync succeed with an empty set. The phone keeps its own library.
    std::string v = c->getValue();
    if (v.find("catalog") != std::string::npos || v.find("sync") != std::string::npos) {
      gLastCommandReply = "{\"ok\":true,\"items\":[]}";
    } else {
      gLastCommandReply = "{\"ok\":true}";
    }
    if (gStatus)  gStatus->setValue(gLastCommandReply);
    if (gCatalog) gCatalog->setValue(gLastCommandReply);
  }
};

class StatusCallbacks : public NimBLECharacteristicCallbacks {
  void onRead(NimBLECharacteristic* c) override {
    // Freshest telemetry when no command reply is pending.
    c->setValue(gLastCommandReply);
  }
};

class CatalogCallbacks : public NimBLECharacteristicCallbacks {
  void onRead(NimBLECharacteristic* c) override {
    c->setValue("{\"ok\":true,\"items\":[]}");
  }
};

// ---- Setup / loop --------------------------------------------------------------------
void setup() {
  pinMode(STATUS_LED, OUTPUT);
  digitalWrite(STATUS_LED, LOW);
  setCpuFrequencyMhz(80); // plenty for BLE; roughly halves CPU draw vs 240 MHz.

  NimBLEDevice::init(DEVICE_NAME);
  NimBLEDevice::setPower(ESP_PWR_LVL_P9); // strongest TX so the band hears the beacon.

  gServer = NimBLEDevice::createServer();
  gServer->setCallbacks(new ServerCallbacks());

  NimBLEService* svc = gServer->createService(SERVICE_UUID);
  NimBLECharacteristic* tx = svc->createCharacteristic(
      TRANSMIT_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  tx->setCallbacks(new TransmitCallbacks());
  NimBLECharacteristic* cmd = svc->createCharacteristic(
      COMMAND_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  cmd->setCallbacks(new CommandCallbacks());
  gStatus = svc->createCharacteristic(STATUS_UUID, NIMBLE_PROPERTY::READ);
  gStatus->setCallbacks(new StatusCallbacks());
  gStatus->setValue(gLastCommandReply);
  gCatalog = svc->createCharacteristic(CATALOG_UUID, NIMBLE_PROPERTY::READ);
  gCatalog->setCallbacks(new CatalogCallbacks());
  gCatalog->setValue("{\"ok\":true,\"items\":[]}");

  svc->start();

  gAdv = NimBLEDevice::getAdvertising();
  startIdleAdvertising();
}

void loop() {
  serviceTransmit();
  delay(2); // yield to the BLE task; keeps CPU cool and lets modem-sleep kick in.
}
