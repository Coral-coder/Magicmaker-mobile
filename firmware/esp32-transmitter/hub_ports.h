// MagicMaker sync hub, phase P2: the FROZEN seams between the hub's parts
// (docs/SYNC_P2_FIRMWARE_PLAN.md §2a; protocol: docs/SYNC_PROTOCOL.md; storage: SYNC_HUB_SPEC.md
// §4.3-§4.8 with amendment A1).
//
//   part 'db'    implements HubDb (hub_db.h: HubDbImpl) over Storage + KvStore (+ TxGate, Rng),
//                and the Storage / KvStore back-ends (storage_posix.h, storage_littlefs.h,
//                kv_nvs.h; test/host: storage_mem.h, kv_mem.h).
//   part 'node'  implements HubSync (hub_node.h: HubNode) over HubDb + Radio + TxGate + Clock +
//                Rng + SelfInfo + Scheduler (+ HubTrace), reusing the P1 Session core as is, and the
//                pure helpers HubWallClock (Clock), TaskTable (Scheduler).
//   integration  provides Radio (NimBLE), TxGate (the relay engine), SelfInfo (power.h), Rng
//                (esp_random) and the sketch wiring; formats HubStatus for sync_status and the screen.
//
// Nobody edits this file during P2: a needed change goes back to the orchestrator.
//
// Rules for everything behind these interfaces (and for this file): gnu++11, -fno-rtti, no
// exceptions, no std::optional / structured bindings / if constexpr, no Arduino or NimBLE types.
// All calls happen on loop()'s task only; nothing here is thread-safe or needs to be. Times are
// mono ms from millis() ("now", wraps after 49 days: compare with (int32_t)(a - b)); wall time is
// Unix ms (int64_t) and only ever comes from Clock.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "sync_codec.h"
#include "sync_events.h"
#include "sync_session.h"

namespace mmsync {

// =================================================================================================
// Constants (plan §4, §5, §8). Changing one is a plan change.
// =================================================================================================

static const uint8_t HUB_MAX_LINKS = 3;     // NimBLE CONFIG_BT_NIMBLE_MAX_CONNECTIONS (2 members + 1)
static const uint8_t HUB_MAX_MEMBERS = 2;   // phone slots (spec §4.9)
static const uint16_t HUB_CONN_NONE = 0xFFFF;
static const uint32_t HUB_NO_DEADLINE = 0xFFFFFFFFu;  // == RELAY_NO_DEADLINE (relay_engine.h)

// Flash-work gate (spec §4.5)
static const uint32_t HUB_GATE_GAP_MS = 400;          // msUntilDue at least this
static const uint32_t HUB_GATE_STARVED_GAP_MS = 200;  // ... or this once dirty data is old
static const uint32_t HUB_DIRTY_STARVED_MS = 30000;   // "old"

// Flush (spec §4.5)
static const uint32_t HUB_FLUSH_DIRTY_BYTES = 2048;   // production: flush once this much is dirty
static const uint32_t HUB_FLUSH_DELAY_MS = 2000;      // ... or this long after the first dirty entry

// Work budgets per loop() pass (spec §4.11)
static const uint8_t HUB_MSGS_PER_PASS = 4;           // reassembled messages handled
static const uint8_t HUB_FRAMES_PER_PASS = 4;         // frames sent per link, no timed job on air
static const uint32_t HUB_TIMED_FRAME_GAP_MS = 40;    // timed job on air: 1 frame per link per 40 ms
static const uint32_t HUB_TX_RETRY_MS = 20;           // Radio::sendFrame refused: retry this soon
static const uint16_t HUB_SCAN_ENTRIES = 32;          // page scan per pass
static const uint16_t HUB_SCAN_BYTES = 4096;
static const uint32_t HUB_BUILD_BYTES = 8192;         // index build read per pass
static const uint8_t HUB_EVT_PER_S = 20;              // EVT relay pacing per link

// Log store, LittleFS on the stock 'spiffs' data partition (amendment A1)
static const char* const HUB_FS_BASE = "/littlefs";
static const char* const HUB_FS_PARTITION = "spiffs";
static const uint8_t HUB_FS_MAX_FILES = 10;           // LittleFS.begin(true, "/littlefs", 10, "spiffs")
static const char* const HUB_DIR_PATH = "/littlefs/mm";
static const char* const HUB_LOG_PATH = "/littlefs/mm/lib.log";
static const char* const HUB_NEW_PATH = "/littlefs/mm/lib.new";

// Log entry: [magic][type][len u16][seq u32][syncFrom 8][payload len][crc32 u32] (plan §4.2)
static const uint8_t HUB_LOG_MAGIC = 0xA7;
static const uint8_t HUB_LOG_RECORD = 1;
static const uint8_t HUB_LOG_END = 2;                 // compaction trailer {count u32, maxSeq u32}
static const uint8_t HUB_LOG_HEADER = 3;              // first entry {dbId 8, formatEpochS u32}
static const uint8_t HUB_LOG_HEAD_BYTES = 16;         // before the payload
static const uint8_t HUB_LOG_OVERHEAD = 20;           // head + CRC
static const uint8_t HUB_LOG_HEADER_PAYLOAD = 12;
static const uint8_t HUB_LOG_END_PAYLOAD = 8;
static const uint16_t HUB_LOG_MAX_PAYLOAD = 360;      // == BODY_MAX

// RAM index (spec §4.4; plan §4.4): {hashLo u32, hashHi u32, seq:30 | PRESENCE<<30 | DELETED<<31}
static const uint32_t HUB_INDEX_ENTRY_BYTES = 12;
static const uint32_t HUB_CAP_MIN = 1024;
static const uint32_t HUB_CAP_MAX_CLASSIC = 4096;
static const uint32_t HUB_CAP_MAX_S3 = 8192;
static const uint32_t HUB_HEAP_RESERVE = 65536;       // kept free after the index
static const uint32_t HUB_SEQ_MAX = 0x3FFFFFFFu;      // 30-bit seqs in the index
static const uint32_t HUB_DIRTY_BYTES_CLASSIC = 4096;
static const uint32_t HUB_DIRTY_BYTES_S3 = 8192;
static const uint32_t HUB_CKPT_BYTES = 2048;          // two checkpoint tables {seq u32, off u32}
static const uint32_t HUB_DB_IO_BYTES = 4608;         // read / compaction scratch (4 KB + 1 entry)
static const uint8_t HUB_PENDING_INSERTS = 32;        // unsorted inserts awaiting a batch merge

// Compaction and capacity (spec §4.7, §4.8; plan §4.7)
static const uint32_t HUB_COMPACT_MIN_LOG = 131072;   // log > max(128 KB, 2 x live) ...
static const uint32_t HUB_COMPACT_FREE_MIN = 262144;  // ... or FS free < 256 KB
static const uint32_t HUB_COMPACT_QUIET_MS = 10000;   // no page traffic this long before it starts
static const uint32_t HUB_COMPACT_STEP_BYTES = 4096;
static const uint32_t HUB_FS_REFUSE_FREE = 65536;     // FS free < 64 KB: new keys refused (FULL)
static const uint32_t HUB_FS_RESERVE = 98304;         // liveMax = (fsTotal - 96 KB) / 3

// Peers in NVS (spec §4.3, §4.5)
static const uint8_t HUB_PEERS_MAX = 8;
static const uint8_t HUB_PEER_BLOB_ENTRY = 26;        // deviceId 8, dbId 8, wm 4, excludeOk 1, kind 1, lastSyncS 4
static const uint8_t HUB_PEER_BLOB_VERSION = 1;       // blob = [version][n x entry]
static const uint32_t HUB_PEER_PERSIST_MS = 60000;    // at most once per peer per minute (+ session end)

// NVS namespace "mmsync" (power.h / btsleep.h keep "mm")
static const char* const HUB_NVS_NAMESPACE = "mmsync";
static const char* const HUB_NVS_DB = "db";           // blob 8: dbId
static const char* const HUB_NVS_GROUP = "grp";       // blob 24: groupId 8 | groupKey 16 (absent = ungrouped)
static const char* const HUB_NVS_PEERS = "peers";     // blob 1 + 26 n
static const char* const HUB_NVS_FLAGS = "full";      // u32: HUB_FLAG_*
static const char* const HUB_NVS_LIVE = "live";       // u32: liveHigh (plan §4.5)
static const uint32_t HUB_FLAG_FULL = 0x01;           // hubFull (HB state bit 9)
static const uint32_t HUB_FLAG_REPULL = 0x02;         // a page record was refused BUSY: re-pull all

// Node timing (plan §5)
static const uint32_t HUB_DRAIN_BEFORE_DISCONNECT_MS = 1000;  // FOREIGN etc.: ERR first, then drop
static const uint32_t HUB_RESET_GRACE_MS = 750;       // sync_reset: the app reads STATUS first
static const uint8_t HUB_ROSTER_MAX = 4;              // devices whose latest HB is kept
static const uint32_t HUB_LOST_S = 600;               // DEVICES page: LOST after 10 min of silence
static const uint32_t HUB_CLOCK_SKEW_SET_MS = 300000; // HB state bit 10 on above 5 min ...
static const uint32_t HUB_CLOCK_SKEW_CLEAR_MS = 60000;  // ... off again at or below 1 min

// HB state bits (SYNC_PROTOCOL.md §11.8). SelfInfo supplies 1-6; the node adds 9-11.
static const uint16_t HB_STATE_SCANNING = 1u << 0;    // never set by the hub
static const uint16_t HB_STATE_KEEP_AWAKE = 1u << 1;
static const uint16_t HB_STATE_TX_LOOP = 1u << 2;
static const uint16_t HB_STATE_WAND_LOOP = 1u << 3;
static const uint16_t HB_STATE_RANDOM_SHOW = 1u << 4; // never set by the hub
static const uint16_t HB_STATE_LOW_POWER = 1u << 5;   // the battery warning stage (power.h)
static const uint16_t HB_STATE_TX_BUSY = 1u << 6;     // a timed job on air (not an on-change trigger)
static const uint16_t HB_STATE_PRIMARY_ESP32 = 1u << 7;  // iPhone only
static const uint16_t HB_STATE_FAILOVER = 1u << 8;    // iPhone only
static const uint16_t HB_STATE_HUB_FULL = 1u << 9;
static const uint16_t HB_STATE_CLOCK_SKEW = 1u << 10;
static const uint16_t HB_STATE_SYNC_NOT_READY = 1u << 11;

// Battery heartbeat advert (sketch heartbeatBytes(): FF FF 'M' 'B' 01 <pct> <flags> <runtime u16>):
// flags bit4 = this board serves SYNC (firmware 2.0+, storage not failed). Version byte stays 1
// (plan §8.7).
static const uint8_t HUB_ADV_FLAG_SYNC = 0x10;

enum HubPolicy : uint8_t {
  HUB_POLICY_PRODUCTION = 0,
  // The transcript replay: behave exactly like tools/sync/gen_vectors.py Node (kind 1): flush only
  // HUB_FLUSH_DELAY_MS after the first dirty record (no size trigger), on-change HB only after a
  // flush that followed page accepts (plan §5.10).
  HUB_POLICY_TRANSCRIPT = 1
};

// (fsTotal - 96 KB) / 3, rounded down to 4 KB (plan §4.8). 0 when the partition is too small.
inline uint32_t hubLiveMaxBytes(uint32_t fsTotalBytes) {
  if (fsTotalBytes <= HUB_FS_RESERVE) return 0;
  return ((fsTotalBytes - HUB_FS_RESERVE) / 3) & ~(uint32_t)4095;
}

// Index capacity from the largest free heap block after every other buffer (spec §4.4):
// clamp((largest - 64 KB) / 12, 1024, capMax).
inline uint32_t hubIndexCap(uint32_t largestFreeBlock, uint32_t capMax) {
  uint32_t cap = largestFreeBlock > HUB_HEAP_RESERVE
                     ? (largestFreeBlock - HUB_HEAP_RESERVE) / HUB_INDEX_ENTRY_BYTES
                     : 0;
  if (cap < HUB_CAP_MIN) cap = HUB_CAP_MIN;
  if (cap > capMax) cap = capMax;
  return cap;
}

// The hub's deviceId: [01][00][MAC as printed, most significant byte first] (SYNC_PROTOCOL §2).
// NimBLEAddress::getNative() is least significant first: pass it with nativeOrder = true.
inline Id8 hubDeviceId(const uint8_t mac[6], bool nativeOrder) {
  Id8 id;
  id.b[0] = 0x01;
  id.b[1] = 0x00;
  for (int i = 0; i < 6; i++) id.b[2 + i] = nativeOrder ? mac[5 - i] : mac[i];
  return id;
}

// =================================================================================================
// Storage: the two log files (plan §4.2). Back-ends: PosixStorage (host and target VFS),
// LittleFS mount (target), MemStorage (host tests, with power-loss injection).
// =================================================================================================

enum HubFile : uint8_t { HUB_FILE_LOG = 0, HUB_FILE_NEW = 1, HUB_FILE_COUNT = 2 };

class Storage {
 public:
  // The file system is usable (mounted, the directory exists).
  virtual bool mounted() = 0;
  virtual bool exists(uint8_t file) = 0;
  // Opens THE handle of `file` for reading anywhere and appending at the end (one handle per file
  // for its whole life, spec §4.3). create: an empty file when it is missing. Idempotent.
  virtual bool open(uint8_t file, bool create) = 0;
  virtual void close(uint8_t file) = 0;
  // Current length of an open file (appended bytes included, synced or not); -1 on error.
  virtual int32_t size(uint8_t file) = 0;
  // Reads up to n bytes at off; returns the count (0 at the end), -1 on error. Sees every byte
  // appended before, synced or not.
  virtual int32_t read(uint8_t file, uint32_t off, uint8_t* buf, uint32_t n) = 0;
  // Appends n bytes at the end; false on error (nothing is known about partial writes: recovery
  // finds a torn tail). Not durable until sync().
  virtual bool append(uint8_t file, const uint8_t* data, uint32_t n) = 0;
  // Everything appended so far is durable when this returns true (fflush + fsync / lfs_file_sync).
  virtual bool sync(uint8_t file) = 0;
  // Deletes a closed file (true when it is gone, also when it never existed).
  virtual bool remove(uint8_t file) = 0;
  // Both closed: NEW becomes LOG, replacing it. Atomic on LittleFS (rename over the target); a VFS
  // that refuses to replace does remove(LOG) then rename (recovery handles "NEW only", spec §4.6).
  virtual bool promoteNew() = 0;
  // File system size and use in bytes (LittleFS.totalBytes() / usedBytes(): slow, call rarely).
  virtual bool usage(uint32_t* totalBytes, uint32_t* usedBytes) = 0;
  // Deletes both files (sync_reset); the file system stays mounted.
  virtual bool wipe() = 0;

 protected:
  ~Storage() {}
};

// =================================================================================================
// KvStore: NVS namespace "mmsync" (Preferences on the target, MemKv on the host).
// Every set / erase is atomic and durable when it returns true. Keys are HUB_NVS_* (<= 15 chars).
// =================================================================================================

class KvStore {
 public:
  // false: absent or error (*len untouched). A stored blob longer than cap is an error.
  virtual bool getBlob(const char* key, uint8_t* out, size_t cap, size_t* len) = 0;
  virtual bool setBlob(const char* key, const uint8_t* data, size_t len) = 0;
  virtual bool getU32(const char* key, uint32_t* v) = 0;
  virtual bool setU32(const char* key, uint32_t v) = 0;
  // true when the key is gone (also when it never existed).
  virtual bool erase(const char* key) = 0;

 protected:
  ~KvStore() {}
};

// =================================================================================================
// TxGate: what the transmit engine is doing (spec §4.5). The sketch implements it over gEngine,
// gCmdQueue and ota.h; tests use a scripted fake.
// =================================================================================================

class TxGate {
 public:
  virtual bool timedJob() = 0;                     // gEngine.timedJob(): a NORMAL / RAW job on air
  virtual uint32_t msUntilDue(uint32_t now) = 0;   // gEngine.msUntilDue(now); HUB_NO_DEADLINE: none
  virtual bool cmdQueueEmpty() = 0;                // no phone command waiting for loop()
  virtual bool otaBusy() = 0;                      // a firmware update is being written

 protected:
  ~TxGate() {}
};

// Index merges, page scans, frame bursts: anything but flash erase / program.
inline bool hubLightWorkAllowed(TxGate& g) { return !g.timedJob(); }

// Flash erase / program (LittleFS append + sync, compaction, rename / remove, every NVS write):
// !timedJob && msUntilDue >= 400 ms (200 ms once dirty data is older than 30 s) && no command
// waiting && no update being written. The keep-awake STREAM has no deadline, so it qualifies.
inline bool hubFlashWorkAllowed(TxGate& g, uint32_t now, bool starved) {
  if (g.timedJob() || g.otaBusy() || !g.cmdQueueEmpty()) return false;
  return g.msUntilDue(now) >= (starved ? HUB_GATE_STARVED_GAP_MS : HUB_GATE_GAP_MS);
}

// =================================================================================================
// Radio: the SYNC characteristic A7830006 on every connection (integration: hub_nimble.h).
// NimBLE host callbacks only enqueue (spec §4.12); the node takes the events from loop().
// =================================================================================================

enum HubRadioEventKind : uint8_t {
  HUB_EV_CONNECT = 1,     // value = ATT MTU now (23 until exchanged)
  HUB_EV_DISCONNECT = 2,  // value = HCI reason
  HUB_EV_SUBSCRIBE = 3,   // SYNC CCCD written: value 1 = notifications on, 0 = off
  HUB_EV_MTU = 4,         // value = the new ATT MTU
  HUB_EV_FRAME = 5,       // one SYNC write = one frame: data[0..len)
  HUB_EV_TX_DONE = 6,     // a notification left (BLE_GAP_EVENT_NOTIFY_TX); conn may be HUB_CONN_NONE
  HUB_EV_RX_OVERFLOW = 7  // frames of conn were dropped (the queue was full)
};

struct HubRadioEvent {
  uint8_t kind;          // HubRadioEventKind
  uint16_t conn;         // NimBLE connection handle
  uint16_t value;
  uint16_t len;          // HUB_EV_FRAME
  const uint8_t* data;   // HUB_EV_FRAME: valid until the next take()
};

class Radio {
 public:
  // The next event, in the order the callbacks saw them; false when there is none.
  virtual bool take(HubRadioEvent* ev) = 0;
  // One notification on conn's SYNC characteristic (the node only sends to subscribed links).
  // NimBLE: om = ble_hs_mbuf_from_flat(); om == NULL -> false (NEVER pass NULL: NimBLE would send
  // the characteristic's stored value); rc = ble_gattc_notify_custom(conn, handle, om) != 0 ->
  // false. false = not now: the node retries after HUB_EV_TX_DONE or HUB_TX_RETRY_MS.
  virtual bool sendFrame(uint16_t conn, const uint8_t* frame, size_t len) = 0;
  // Asynchronous; the HUB_EV_DISCONNECT event follows. hciReason e.g. 0x13 (remote user).
  virtual void disconnect(uint16_t conn, uint8_t hciReason) = 0;

 protected:
  ~Radio() {}
};

// =================================================================================================
// Clock: the hub's wall-clock estimate (SYNC_PROTOCOL §7, spec §3.11). Production: HubWallClock
// (hub_clock.h, part node): esp_timer + the median offset of the latest member clocks. The
// transcript replay injects a clock that reads clockBaseMs + t once it has observed anything.
// =================================================================================================

class Clock {
 public:
  // Unix ms at mono time now; false while the hub does not know the time.
  virtual bool wallMs(uint32_t now, int64_t* out) = 0;
  // A member phone's clock: HELLO clockMs when its session reaches AUTHED, or the ts of a DIRECT
  // HB from it; only values > 0 are passed.
  virtual void observe(const Id8& phone, int64_t phoneMs, uint32_t now) = 0;
  // The member clocks differ by more than 5 min (HB state bit 10; hysteresis inside).
  virtual bool skewed() = 0;

 protected:
  ~Clock() {}
};

// =================================================================================================
// Rng (esp_random() on the target: call it after NimBLEDevice::init, when the RF RNG is live).
// =================================================================================================

class Rng {
 public:
  virtual void random(uint8_t* out, size_t n) = 0;
  // A fresh handshake nonce for the session on conn (the replay injects the transcript's).
  virtual void nonce(uint16_t conn, uint8_t out[8]) = 0;

 protected:
  ~Rng() {}
};

// =================================================================================================
// SelfInfo: the hub's own HB fields (spec §4.13, §9.1). Read only when an HB is built and when the
// sketch reports a change: no extra battery reads (power.h already reads once a minute).
// =================================================================================================

struct HubSelf {
  int8_t battPct;      // -1 unknown (classic ESP32: always -1)
  int16_t battMv;      // -1 unknown
  int8_t charging;     // -1 unknown, 0 on battery, 1 charging or on USB power
  int16_t runtimeMin;  // -1 unknown (power.h's model: minutes to the cutoff)
  uint16_t state;      // HB_STATE_* bits 1..6 the sketch knows (keep-awake, loops, lowPower, txBusy)
  uint32_t uptimeS;    // esp_timer seconds since boot
};

class SelfInfo {
 public:
  virtual void read(HubSelf* out) = 0;

 protected:
  ~SelfInfo() {}
};

// =================================================================================================
// Scheduler: deferred work of the node (session timers, the HB round, the flush timer, drains,
// deadlines). Production: TaskTable (hub_tasks.h, part node). The transcript replay implements it
// with the simulation's event queue, so ties at equal due times run in scheduling order exactly as
// tools/sync/gen_vectors.py Sim does.
// =================================================================================================

struct HubTask {
  uint32_t due;    // mono ms
  uint32_t gen;    // the node's check value (a link generation, a timer due, ...)
  uint8_t kind;    // node-defined
  uint8_t link;    // node-defined (a link slot)
  uint8_t arg;     // node-defined (a TimerId, ...)
  uint8_t spare;
};

class Scheduler {
 public:
  // Run the task at task.due (as soon as possible when due has passed); among equal due times in
  // the order at() was called. false: no room (the node treats the work as due now).
  virtual bool at(const HubTask& task) = 0;
  // Production: the next task with due <= now, removed, in (due, order) order; false when none.
  // An event-queue scheduler (the replay) runs tasks itself through HubSync::runTask and returns
  // false here.
  virtual bool popDue(uint32_t now, HubTask* out) = 0;
  // ms until the earliest task (0 when one is due), HUB_NO_DEADLINE when none.
  virtual uint32_t nextDueMs(uint32_t now) = 0;

 protected:
  ~Scheduler() {}
};

// =================================================================================================
// HubTrace: observation only (transcript replay, diagnostics). Every method is optional.
// =================================================================================================

// Node disconnect reasons beyond the session's DisconnectReason (sync_session.h, 1..5).
enum HubDiscReason : uint8_t {
  HUB_DISC_DB_RESET = 16,   // "db_reset": sync_reset closes every session
  HUB_DISC_STALE = 17,      // "stale": a new link of the same deviceId replaced this one
  HUB_DISC_SLOTS = 18,      // "slots": a third connection that is not a member
  HUB_DISC_DEADLINE = 19,   // "deadline": grouped hub, no session 10 s after connect
  HUB_DISC_UNSUBSCRIBED = 20  // "unsubscribed": SYNC notifications turned off on a grouped hub
};

inline const char* hubDiscReasonName(uint8_t r) {
  if (r >= DISC_FOREIGN && r <= DISC_LEFT_GROUP) return disconnectReasonName(r);
  switch (r) {
    case HUB_DISC_DB_RESET: return "db_reset";
    case HUB_DISC_STALE: return "stale";
    case HUB_DISC_SLOTS: return "slots";
    case HUB_DISC_DEADLINE: return "deadline";
    case HUB_DISC_UNSUBSCRIBED: return "unsubscribed";
    default: return "?";
  }
}

class HubTrace {
 public:
  virtual void state(uint16_t /*conn*/, uint8_t /*sessionState*/) {}
  // key NULL: the body did not yield one. status: DbResult.
  virtual void apply(uint16_t /*conn*/, const Key* /*key*/, uint8_t /*status*/, bool /*live*/) {}
  virtual void durable(uint32_t /*durableHigh*/) {}
  virtual void group(uint16_t /*conn*/, const Id8& /*groupId*/, bool /*rekey*/) {}
  virtual void foreign(uint16_t /*conn*/) {}
  // reason: DisconnectReason or HubDiscReason (hubDiscReasonName()).
  virtual void disconnect(uint16_t /*conn*/, uint8_t /*reason*/, bool /*hasRetry*/, uint32_t /*retryMs*/) {}
  virtual void timer(uint16_t /*conn*/, uint8_t /*timerId*/) {}
  // A whole message handed to conn's outbox, in emission order (what the replay compares).
  virtual void sent(uint16_t /*conn*/, const uint8_t* /*msg*/, size_t /*len*/) {}
  virtual void note(const char* /*text*/) {}

 protected:
  ~HubTrace() {}
};

// =================================================================================================
// HubDb: the hub's library store (part 'db'; the node's only way to records, peers and the group).
// Contract details: docs/SYNC_P2_FIRMWARE_PLAN.md §4.10. The node's tests use FakeHubDb
// (test/host/fake_hub_db.h, part node) with the same observable behaviour.
// =================================================================================================

enum DbState : uint8_t {
  DB_OFF = 0,        // before begin()
  DB_BUILDING = 1,   // recovering / building the index (maintain() steps); HELLO -> NOT_READY
  DB_READY = 2,
  DB_RESETTING = 3,  // sync_reset accepted, the wipe waits for the flash gate
  DB_FAILED = 4      // storage unusable: no sync (transmit unaffected)
};

// accept() results. 1..5 equal ApplyStatus (sync_codec.h).
enum DbResult : uint8_t {
  DBR_ACCEPT = 1,     // stored (dirty until flushed) with a new seq
  DBR_DUPLICATE = 2,
  DBR_STALE = 3,
  DBR_BAD_MSG = 4,    // -> ERR BAD_MSG, refType 3, key
  DBR_CLOCK = 5,      // -> ERR CLOCK (invalid range, or > now + 24 h once the time is known)
  DBR_FULL = 6,       // -> ERR FULL: new key at capacity (spec §4.8); hubFull set
  DBR_COLLISION = 7,  // -> ERR COLLISION: 64-bit hash of another key
  DBR_BUSY = 8,       // -> ERR BUSY retryMs 1000: no room right now (dirty queue / pending inserts)
  DBR_NOT_READY = 9   // not DB_READY
};

enum DbFlushResult : uint8_t {
  DB_FLUSH_NONE = 0,      // nothing dirty
  DB_FLUSH_DONE = 1,      // durableHigh advanced to the last dirty seq
  DB_FLUSH_DEFERRED = 2,  // the flash gate is closed (or compaction holds flushes); nothing written
  DB_FLUSH_ERROR = 3      // the append / sync failed; dirty data kept, retried later
};

enum DbFeedStep : uint8_t {
  DB_FEED_ENTRY = 1,      // *out is the next current entry
  DB_FEED_YIELD = 2,      // budget spent: call again on a later pass (same cursor)
  DB_FEED_END = 3,        // no current entry with seq <= the cursor's limit is left
  DB_FEED_NOT_READY = 4   // not DB_READY: end the page early (PAGE_END with what was scanned)
};

// What a current entry looks like to the node. Pointers stay valid until the next HubDb call.
struct DbEntry {
  uint32_t seq;
  bool durable;          // seq <= durableHigh()
  bool hasSyncFrom;      // the peer it was accepted from (the hub has no local records)
  Id8 syncFrom;
  bool hasOrigin;
  Id8 origin;
  Version version;
  uint8_t cls;           // RecordClass
  const uint8_t* body;   // the verbatim canonical body
  uint16_t bodyLen;
};

struct DbAccept {
  uint8_t result;   // DbResult
  uint32_t seq;     // DBR_ACCEPT: the entry's new seq
  bool hasKey;      // the body's key (for ERR{..., key} and the trace)
  Key key;
  bool evicted;     // DBR_ACCEPT made room by evicting the oldest PRESENCE / TOMBSTONE
};

// A feed position (opaque: only the DB reads or writes the words).
struct FeedCursor {
  uint32_t w[6];
};

struct FeedBudget {
  uint16_t entries;  // log entries still allowed this pass (superseded ones count)
  uint16_t bytes;    // log bytes still allowed this pass
};

struct DbPeer {
  Id8 id;
  PeerState st;           // the RAM state the sessions use
  uint8_t kind;           // KIND_* last seen (0 unknown)
  uint32_t lastSyncEpochS;  // wall seconds of the last committed page (0 unknown)
};

// What recovery did at boot (DbStats.bootFlags).
static const uint16_t DB_BOOT_LOG_CREATED = 1u << 0;     // lib.log was missing
static const uint16_t DB_BOOT_HEADER_MISMATCH = 1u << 1; // HEADER dbId != NVS db
static const uint16_t DB_BOOT_TORN_TAIL = 1u << 2;       // bad tail dropped (compaction rewrites)
static const uint16_t DB_BOOT_CORRUPT = 1u << 3;         // bad entry followed by valid ones
static const uint16_t DB_BOOT_NEW_REMOVED = 1u << 4;     // an unfinished lib.new was deleted
static const uint16_t DB_BOOT_NEW_PROMOTED = 1u << 5;    // lib.new (valid END, no lib.log) became lib.log
static const uint16_t DB_BOOT_LIVE_LOST = 1u << 6;       // NVS liveHigh > max seq in the log
static const uint16_t DB_BOOT_NEW_DBID = 1u << 7;        // a new dbId was taken (peers zeroed)
static const uint16_t DB_BOOT_FORMAT_FAILED = 1u << 8;   // storage unusable (DB_FAILED)

struct DbStats {
  uint8_t state;           // DbState
  uint32_t records;        // current entries (keys)
  uint32_t cap;            // index capacity
  uint32_t tombstones;     // current entries with DELETED
  uint32_t presences;      // current PRESENCE entries
  uint32_t liveBytes;      // log bytes of the current entries
  uint32_t liveMaxBytes;
  uint32_t logBytes;       // lib.log size
  uint32_t fsTotalBytes;
  uint32_t fsUsedBytes;    // estimate (files + metadata), refreshed by usage() at boot / compaction
  uint32_t lastSeq;        // highest seq assigned
  uint32_t durableHigh;
  uint32_t dirtyBytes;
  uint32_t dirtyCap;
  uint8_t pendingInserts;
  bool full;
  bool repull;
  bool compacting;
  uint16_t bootFlags;      // DB_BOOT_*
  uint32_t buildMs;        // index build time at boot
  uint32_t flushes;
  uint32_t flushErrors;
  uint32_t compactions;
  uint32_t evictions;
  uint32_t collisions;
  uint32_t liveSkipped;    // live forwards refused by reserveLive()
};

struct HubDbConfig {
  Storage* storage;
  KvStore* kv;
  TxGate* gate;
  Rng* rng;                // new dbIds
  uint32_t* indexMem;      // the index; cap = indexBytes / 12, clamped to [HUB_CAP_MIN, ...]
  uint32_t indexBytes;
  uint8_t* dirtyMem;       // the dirty queue (encoded log entries awaiting the flush)
  uint32_t dirtyBytes;     // HUB_DIRTY_BYTES_CLASSIC / _S3
  uint32_t* ckptMem;       // two checkpoint tables (current + the one compaction builds)
  uint32_t ckptBytes;      // HUB_CKPT_BYTES
  uint8_t* ioMem;          // read / compaction scratch
  uint32_t ioBytes;        // >= HUB_DB_IO_BYTES
  uint32_t fsTotalBytes;   // the partition's file system size (Storage::usage at mount)
  uint32_t liveMaxBytes;   // 0: hubLiveMaxBytes(fsTotalBytes)
  uint64_t (*keyHash)(const Key& k);  // NULL: keyHash() (sync_codec.h); tests force collisions
  uint8_t policy;          // HubPolicy
};

class HubDb {
 public:
  // ---- lifecycle -------------------------------------------------------------------------------
  // Reads NVS and the log header, runs the recovery table (plan §4.6) as far as it can without a
  // long scan, then DB_BUILDING (or DB_FAILED). maintain() finishes the build.
  virtual void begin(const HubDbConfig& cfg, uint32_t now) = 0;
  virtual uint8_t state() const = 0;               // DbState
  virtual bool ready() const = 0;                  // state() == DB_READY
  // One bounded step of background work, each part only when its gate allows: index build
  // (<= HUB_BUILD_BYTES read + one merge; light gate), pending-insert merge (light gate), NVS
  // writes due (group, flags, liveHigh clear, peers; flash gate), a flush the DB needs itself
  // (before compaction or a peers write), one compaction step (flash gate, no page traffic for
  // HUB_COMPACT_QUIET_MS), the sync_reset wipe (flash gate). Returns true when it did something.
  virtual bool maintain(uint32_t now) = 0;
  // Work is pending AND its gate is open right now (the node's nextDueMs() returns 0 then; work
  // that waits for a gate never makes loop() spin).
  virtual bool maintenanceDue(uint32_t now) = 0;

  // ---- identity and feed position -----------------------------------------------------------
  virtual Id8 dbId() const = 0;
  virtual uint32_t durableHigh() const = 0;        // the highest seq on flash (D5: all that is served)
  virtual uint32_t lastSeq() const = 0;            // the highest seq assigned (dirty included)

  // ---- records -------------------------------------------------------------------------------
  // A received record body from syncFrom (validated again here: decode, class rules, CLOCK when
  // nowKnown and updatedAt > nowMs + 24 h; then LWW against the current version, spec §2.3).
  // ACCEPT stores it with seq = lastSeq() + 1 in the dirty queue (never touches flash). live: a
  // live REC (BUSY is allowed; a page REC that cannot be stored sets HUB_FLAG_REPULL instead of
  // being lost silently, plan §4.8).
  virtual DbAccept accept(const uint8_t* body, size_t len, const Id8& syncFrom, bool nowKnown,
                          int64_t nowMs, bool live, uint32_t now) = 0;
  // The current entry of key (dirty or durable); false when the key has none.
  virtual bool lookup(const Key& key, DbEntry* out) = 0;
  // Room to accept one more incoming page now: the light gate is open, the dirty queue has room
  // for a page of maxBytes, pending inserts have room for PULL_LIMIT max, no compaction swap is
  // waiting. The node sends its own PULLs only then (spec §3.7 hub backpressure).
  virtual bool canTakePage(uint16_t maxBytes, uint32_t now) = 0;
  // May the entry with this seq be live-forwarded now (SYNC_PROTOCOL §15.4)? True when it is
  // durable, or when NVS liveHigh >= seq (written here if the flash gate is open). false: skip
  // the live forward (the record reaches peers through the on-change HB and their pulls).
  virtual bool reserveLive(uint32_t seq, uint32_t now) = 0;
  // A page went out or came in (compaction waits for HUB_COMPACT_QUIET_MS of none).
  virtual void notePageTraffic(uint32_t now) = 0;

  // ---- durability ----------------------------------------------------------------------------
  virtual uint32_t dirtyBytes() const = 0;
  // One append of every dirty entry + sync. force = false: only when hubFlashWorkAllowed() (with
  // the starvation rule; compaction in progress also defers). force = true: now, ungated
  // (power-off, restart, OTA reboot).
  virtual uint8_t flush(uint32_t now, bool force) = 0;   // DbFlushResult

  // ---- feed (durable-only serving is the caller's rule: pass limit = durableHigh()) -----------
  // Positions c at the first entry with seq > since; the feed ends after seq `limit`.
  virtual void feedBegin(FeedCursor* c, uint32_t since, uint32_t limit) = 0;
  // The next CURRENT entry (superseded and evicted ones are skipped but spend budget), in
  // ascending seq; dirty entries (seq > durableHigh) only when limit includes them. Survives
  // flushes and compaction (the cursor re-positions by seq).
  virtual uint8_t feedNext(FeedCursor* c, FeedBudget* budget, DbEntry* out) = 0;  // DbFeedStep

  // ---- peers (spec §3.7 peer state; SYNC_PROTOCOL §15.1) ---------------------------------------
  // The RAM table the sessions mutate through SessionNode::findPeer / peer. Pointers stay valid
  // until the next peerGet() of an unknown id (at most HUB_PEERS_MAX entries; LRU reuse).
  virtual PeerState* peerFind(const Id8& id) = 0;
  virtual PeerState* peerGet(const Id8& id, uint8_t kind) = 0;  // find or create {0, 0, false}
  // A page from that peer committed (the session's ACT_COMMIT): its wm is persisted once every
  // record accepted so far is durable (at most once per HUB_PEER_PERSIST_MS per peer).
  virtual void peerCommitted(const Id8& id, uint32_t wallS, uint32_t now) = 0;
  // Its session ended: persist at the next allowed moment (same durability rule).
  virtual void peerSessionEnd(const Id8& id, uint32_t now) = 0;
  // Every wm = 0 (hubFull / repull cleared, spec §4.8); persisted like a commit.
  virtual void zeroAllWm(uint32_t now) = 0;
  virtual uint8_t peerCount() const = 0;
  virtual bool peerAt(uint8_t i, DbPeer* out) const = 0;

  // ---- group (spec §3.6) ---------------------------------------------------------------------
  virtual const GroupState& group() const = 0;
  // RAM at once; NVS "grp" at the next allowed moment (erased when ungrouped).
  virtual void setGroup(const GroupState& g, uint32_t now) = 0;

  // ---- capacity (spec §4.8) ------------------------------------------------------------------
  virtual bool full() const = 0;                   // hubFull (HB state bit 9)
  // true once each time hubFull or repull cleared (the node then zeroes every wm via
  // zeroAllWm() and sends pull_now to every member session).
  virtual bool takeRepullNeeded() = 0;

  // ---- sync_reset (spec §4.14) ---------------------------------------------------------------
  // Wipe the library, take newDbId, zero the peers, clear full / repull / liveHigh, keep the
  // group. DB_RESETTING until the flash gate lets it run, then DB_READY with an empty log.
  virtual void requestReset(const Id8& newDbId, uint32_t now) = 0;

  // ---- status --------------------------------------------------------------------------------
  virtual void stats(DbStats* out) const = 0;

 protected:
  ~HubDb() {}
};

// =================================================================================================
// HubSync: the hub node (part 'node', hub_node.h: HubNode) as the sketch drives it.
// =================================================================================================

struct HubConfig {
  Id8 deviceId;          // hubDeviceId(MAC)
  uint16_t bootId;       // random per boot
  const char* version;   // HELLO / HB version, <= 16 bytes: MM_FW_VERSION " heltec-v3" | " esp32"
  const char* name;      // "MM_ESP"
  uint8_t policy;        // HubPolicy
};

struct HubPorts {
  HubDb* db;
  Radio* radio;
  TxGate* gate;
  Clock* clock;
  Rng* rng;
  SelfInfo* self;
  Scheduler* sched;
  HubTrace* trace;       // may be NULL
};

struct HubCounts {
  uint8_t conns;         // connections the node knows of
  uint8_t subscribed;    // with SYNC notifications on (a session)
  uint8_t members;       // AUTHED / SYNCING / SYNCED sessions
  uint8_t pending;       // conns - members
};

// sync_status "s" and the DEVICES page.
enum HubPhoneState : uint8_t {
  HUB_PH_LINKED = 0,       // LINKED (also before SUBSCRIBE)
  HUB_PH_AUTH = 1,         // HELLO_X / AUTHED
  HUB_PH_SYNCING = 2,
  HUB_PH_SYNCED = 3,
  HUB_PH_FOREIGN = 4,
  HUB_PH_NOGROUP = 5,
  HUB_PH_INCOMPATIBLE = 6,
  HUB_PH_OFFLINE = 0xFF    // not linked to the hub (known from HBs only)
};

enum HubPath : uint8_t { HUB_PATH_NONE = 0, HUB_PATH_DIRECT = 1, HUB_PATH_VIA = 2, HUB_PATH_BOTH = 3 };

struct HubPhoneRow {
  Id8 id;
  uint8_t kind;          // KIND_ANDROID / KIND_IOS (0 unknown)
  uint8_t state;         // HubPhoneState
  uint16_t conn;         // HUB_CONN_NONE when not linked
  uint16_t mtu;          // 0 when not linked
  uint32_t wm;           // the hub's wm into its feed (0 unknown)
  uint32_t agoS;         // since its latest HB on any path; 0xFFFFFFFF none
  int8_t battPct;        // -1 unknown
  int8_t charging;       // -1 / 0 / 1
  int16_t runtimeMin;    // -1 unknown
  uint8_t path;          // HubPath (fresh = within T_PATH_FRESH_MS)
  uint8_t viaKind;       // the forwarder's kind when path has VIA
};

struct HubStatus {
  uint8_t dbState;       // DbState
  bool ready;
  bool full;
  bool grouped;
  Id8 groupId;
  Id8 dbId;
  uint32_t records;
  uint32_t cap;
  uint32_t tombstones;
  uint32_t liveKB;
  uint32_t liveMaxKB;
  uint32_t logKB;
  uint32_t fsUsedKB;
  uint32_t fsTotalKB;
  uint32_t lastSeq;      // sync_status "seq"
  uint32_t durableHigh;  // "dur"
  HubCounts counts;
  bool mtu23;            // a member link runs below SMALL_MTU_BELOW
  bool clockKnown;
  bool clockSkew;
  uint32_t heapFree;     // filled by the sketch (the node leaves 0)
  uint32_t heapMin;      // filled by the sketch
  uint32_t badFrames;
  uint32_t rxOverflows;
  uint32_t liveDropped;  // live RECs / EVTs dropped by the outbox
  uint8_t nPhones;       // rows used, members first, then other recent devices
  HubPhoneRow phones[HUB_ROSTER_MAX];
  uint8_t nMemberConns;  // sync_reset is accepted from these connections only
  uint16_t memberConns[HUB_MAX_LINKS];
};

class HubSync {
 public:
  // Once, in setup() after NimBLE init and HubDb::begin(). Keeps the pointers.
  virtual void begin(const HubConfig& cfg, const HubPorts& ports, uint32_t now) = 0;
  // loop() step 3 (spec §4.11): runs due tasks (Scheduler::popDue), then at most HUB_MSGS_PER_PASS
  // messages from Radio::take, one page-scan step per link, frames per the pacing rules, one flush
  // and one HubDb::maintain step. Never blocks; flash work only through the gate.
  virtual void service(uint32_t now) = 0;
  // A scheduled task is due (called by service() for TaskTable, or by an event-queue scheduler).
  virtual void runTask(const HubTask& task) = 0;
  // For loop()'s sleep: 0 = call service() again now (messages queued, sendable frames, a page
  // scan or allowed DB work pending); else ms until the earliest task; HUB_NO_DEADLINE: nothing.
  // Work waiting for a closed gate does not count (the engine's own deadline wakes loop()).
  virtual uint32_t nextDueMs(uint32_t now) = 0;
  // Battery %, charging or HB state bits 1-5 changed (production: an on-change HB, >= 5 s apart).
  virtual void selfChanged(uint32_t now) = 0;
  virtual bool isMember(uint16_t conn) const = 0;
  // {"action":"sync_reset"} from conn: false unless conn is a member. Closes every session after
  // HUB_RESET_GRACE_MS and resets the DB with a new random dbId.
  virtual bool syncReset(uint16_t conn, uint32_t now) = 0;
  // PRG (Heltec) / BOOT (classic) held 5 s: forget the group, every session ends left_group.
  virtual void leaveGroup(uint32_t now) = 0;
  // Power-off / restart / OTA reboot: HubDb::flush(now, true) and the due NVS writes, ungated.
  virtual void flushNow(uint32_t now) = 0;
  virtual void counts(HubCounts* out) const = 0;
  virtual void status(HubStatus* out, uint32_t now) = 0;

 protected:
  ~HubSync() {}
};

}  // namespace mmsync
