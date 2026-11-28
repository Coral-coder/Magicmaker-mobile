# Sync hub, phase P2 (ESP32 firmware): implementation plan

Status: plan for phase P2 of [SYNC_HUB_SPEC.md](SYNC_HUB_SPEC.md) §12. Normative wire rules are in
[SYNC_PROTOCOL.md](SYNC_PROTOCOL.md). The spec's amendments A1–A3 (top of that file) override its
body; this plan applies them. Where the spec's file layout or baseline names differ from today's
tree, this plan follows the tree (firmware 1.5). Decisions this plan makes are listed in §1.

The frozen interface every part codes against is
[`firmware/esp32-transmitter/hub_ports.h`](../firmware/esp32-transmitter/hub_ports.h). It compiles
with `g++ -std=gnu++11 -Wall -Wextra -Werror -fsyntax-only` together with the P1 headers (and with
the Makefile's full gnu++11 flag set, C++17, clang and the Xtensa gnu++11 toolchain).

## Where the hub work stands

| Phase | What | State |
|---|---|---|
| P1 | protocol, vectors, transcripts; C++ core `sync_codec.h`, `sync_crypto.h`, `sync_events.h`, `sync_ledger.h`, `sync_session.h`; host tests | **done** |
| **P2** | **ESP32 hub firmware: library store on LittleFS, hub node, NimBLE glue, advertising, status, screen** | **this plan** |
| P3 | Android: identity, ledger, HubClient (central to the hub), direct peer for the iPhone, events, HB, card | **done** (the interop counterpart) |
| P4 | iPhone | later |

What the user gets from P2: firmware 2.0. The board keeps every 1.5 feature and also becomes the
library hub. It stores the shared library in flash, serves up to two phones on the SYNC
characteristic, relays live edits, heard-packet events and heartbeats between them, and shows a
DEVICES page on the Heltec. Phones that do not speak SYNC keep transmitting through it as before.
The only exception is a grouped hub, which serves group members only (spec §3.6).

---

## 0. Ground rules for the implementers

- Repo `/home/user/Magicmaker-mobile`, branch `main`. **No commits, pushes or other git state
  changes**: the orchestrator commits.
- **Frozen:** the P1 headers `sync_*.h`, `tools/sync/**` and `hub_ports.h`. Report a P1 bug or a
  needed interface change to the orchestrator instead of patching it.
- All firmware C++ is **gnu++11 with `-fno-rtti`** and no exceptions. That rules out
  `std::optional`, structured bindings, `if constexpr` and `dynamic_cast`. Everything is
  header-only and lives in the sketch folder, like P1 (`static`/`inline`, no new `.cpp`: arduino-cli
  compiles every `.cpp` in the sketch folder). Pure headers include no Arduino, FreeRTOS or NimBLE
  header. Only the thin back-ends `storage_littlefs.h`, `kv_nvs.h` and `hub_nimble.h` may, and the
  sketch includes them only from the `.ino`. Host test sources go in `test/host/`, which arduino-cli
  never compiles and PlatformIO's default `src_filter` excludes. Still guard them with
  `#if !defined(ARDUINO)` like `cxx11_smoke.cc`.
- No heap in the hub code: buffers come from the sketch (`HubDbConfig`) or are static. No
  function-local buffer over 512 B, because `loopTask` has an 8 KB stack.
- **One PlatformIO build and one Gradle run at a time, machine-wide.** Before starting one, run
  `pgrep -fa 'platformio|pio run|GradleWrapperMain'` and wait while anything matches. Builds:
  - `/home/user/pio-venv/bin/pio run -d <scratch>/pio-main -e heltec_v3` and `-e esp32dev`;
  - the strict check `-d <scratch>/pio-strict15` (`-Wall -Wextra -DMM_DEBUG_TIMING=1`), which must
    show **zero warnings from sketch files**.

  `<scratch>` is `/tmp/claude-0/-home-user-Magicmaker-mobile/8956e220-2c18-5594-88a6-966886e08e67/scratchpad`.
  LittleFS needs no `board_build` setting: the core's built-in `LittleFS` library is found by the
  LDF, and `board_build.filesystem` only matters for `buildfs`/`uploadfs`, which we never use.
- Host tests: `make -C firmware/esp32-transmitter/test/host test` (ASan + UBSan). Every new header
  must also pass a gnu++11 `-Werror` smoke compile (§4.12, §5.13).
- **User rules (non-negotiable), and where each one is enforced:**

| Rule | How P2 keeps it |
|---|---|
| The ESP32 never scans | the hub is a GATT peripheral only; no scan API is linked |
| Transmit timing comes first | flash work only through `hubFlashWorkAllowed` (no timed job, ≥ 400 ms to the next deadline, no command waiting, no OTA); index merges and page scans only with no timed job on air; ≤ 1 frame per link per 40 ms while a job is on air; `loop()` handles commands and `gEngine.service()` before any sync work |
| Lowest power | `loop()` keeps sleeping until its next deadline; `HubSync::nextDueMs()` returns 0 only for work that may run now; no polling; HBs read cached battery values (power.h already reads once a minute) |
| OLED lights only on PRG presses (plus 1.5's 2 s TOO LOW TO START) | sync never touches the screen power; DEVICES is drawn only while lit |
| LED: 1 s blink waiting, 5 s linked, one flash per transmission, never steady | no LED change in P2 (two linked phones still read "linked") |
| Advertises as `MM_ESP` | unchanged name; idle advert layout unchanged; only heartbeat flag bit4 is new |
| 400 mAh battery | unchanged defaults; budget in §10 |
| Never a delete-all for the library | none is added. `sync_reset` resets the **hub's copy** only: no tombstones, the phones' libraries are untouched, and the phones refill the hub within a minute |
| Keep every 1.5 power feature | power-off, cutoff, modem sleep + guard, RADIO SLEEP restart and OTA are untouched; the hub flushes before deep sleep and before each restart (§8.2) |

---

## 1. Decisions made in P2

1. **Stock partition tables (A1).** No `partitions.csv`. LittleFS is mounted on the existing
   `spiffs` data partition with `LittleFS.begin(true, "/littlefs", 10, "spiffs")`. The files are
   `/littlefs/mm/lib.log` and `/littlefs/mm/lib.new`. Capacity is re-derived from the stock sizes
   (§4.8).
2. **The RAM index stores the entry's seq, not its file offset.** The spec's `{hash, off}` becomes
   `{hashLo, hashHi, seq:30 | PRESENCE | DELETED}`. Offsets come from seq checkpoints. Why:
   compaction keeps seqs, so the index never goes stale, and there is no rebuild window after the
   rename. The class bits make eviction a RAM scan. "Current" for a log entry means
   `index[hash].seq == entry.seq`.
3. **An exhausted page ends at durableHigh (hub only).** When a page scan reaches its durableHigh
   without stopping on `limit`/`maxBytes`, `scannedTo = durableHigh` and `more = 0`. Otherwise a
   superseded tail entry (its replacement still dirty) makes the puller re-pull empty pages until
   the next flush. The rule is safe, because every current entry ≤ durableHigh was offered. It
   changes no vector and no transcript: every hub `PAGE_END` in `tools/sync/transcripts` already has
   `more = 0`, and no `pages` vector has a superseded tail. It is proposed as a clarification for
   SYNC_PROTOCOL.md §15.2/§19 (§8.12), and for Android later.
4. **A live forward needs `reserveLive` (SYNC_PROTOCOL §15.4).** Before the hub forwards a live
   REC carrying its non-durable seq `s`, it writes NVS `live = s`. At boot, `live > maxSeqInLog`
   means a forwarded record was lost: the hub takes a new dbId. When the flash gate is closed, the
   forward is skipped, and the record reaches peers through the on-change HB and their pulls.
5. **Node owns timing, DB owns gating.** The node decides *when* to ask: the 2 s flush timer, the
   2 KB trigger, the HB round. The DB decides *whether* flash work may run, through `TxGate`.
   `HubDb` never touches flash while the gate is closed, except in `flush(now, true)` at power-off
   and restart.
6. **One ordered radio event stream.** Connect, disconnect, subscribe, MTU and frame events travel
   in one FIFO (`Radio::take`). A frame can therefore never overtake its own link's disconnect.
7. **A `Scheduler` port**, so the transcript replay reproduces the simulation's tie order exactly.
   Production uses a fixed `TaskTable`; the replay uses the simulation's event queue (Kotlin's
   `SyncScheduler` did the same).
8. **The outbox is FIFO while no timed job is on air**, so wire order equals emission order. While
   a job is on air it switches to priority order (ERR > HELLO/AUTH/JOIN/PULL > HB > EVT and relays
   > live REC > page RECs), at one frame per link per 40 ms.
9. **Sessions start at the SYNC CCCD write** (`HUB_EV_SUBSCRIBE`), not at connect. On a grouped
   hub, a connection without a session is dropped 10 s after connect (reason `deadline`). Old
   SYNC-less apps keep 1.5 behaviour on an ungrouped hub.
10. **Advertising.** With 0 or 1 connection the board advertises connectable (`ADV_IDLE`, 1.5's
    layout), so a second phone can join. It runs fast for 30 s after any connect or disconnect,
    then 546–760 ms with 0 connections and 1–2 s with 1 (1.5's heartbeat interval, so the power is
    the same as 1.5's one-phone advert). With 2 or more connections and nothing on air, 1.5's
    non-connectable `ADV_HEARTBEAT` is kept instead of the spec's OFF: it is 1.5's battery
    heartbeat. The beacon gets the connect filter while a timed job is on air or with 2 or more
    connections, and its scan response follows `conns < 2` (§8.3).
11. **Pre-connection capability signal:** heartbeat flags **bit4 (0x10) = this board serves SYNC**.
    The version byte stays 1, so the 1.4/1.5 parsers ignore the bit. Bytes and the Android change
    are in §8.7.
12. **sync_status is per connection**: the STATUS read from the same connection within 3 s returns
    the `sync` object. **sync_reset** needs an AUTHED member connection (checked in the callback
    against a shadow) and closes the sessions after a 750 ms grace, so the app can read the reply.
13. **Screen.** DEVICES comes right after STATUS and POWER stays last: STATUS → DEVICES → LAST PACKET
    → DEVICE → LOW BATTERY → POWER. STATUS's 5th line (index 4) becomes `SYN …`, and the last-packet
    age moves into the `PKT` line. Holding PRG 5 s on a lit DEVICES page leaves the group; on the
    classic board, BOOT held 5 s does.
14. **Battery for HB:** no `batteryPoll` change. 1.5 already reads every 60 s with the screen dark,
    and the HB uses the cached values (`charging = charging || on USB`). Runtime comes from 1.5's
    model, so the classic board reports −1.
15. **Identity strings:** deviceId `[01][00][MAC, printed order]`; HELLO/HB version
    `MM_FW_VERSION " heltec-v3"` or `" esp32"` (the OTA marker's board names; `"2.0 heltec-v3"` as
    in the transcripts); name `MM_ESP`; bootId random per boot.
16. **Versions:** `MM_FW_VERSION "2.0"`, `MM_RELAY_PROTO 4` (§8.8 checks every parser).
17. **A missing `lib.log` with an NVS dbId present always takes a new dbId.** The spec only does so
    when the NVS peers hold a wm > 0, but phones may hold a wm into the hub's feed even when the
    hub's own peers are all 0 (records it got live).
18. **A page REC the DB cannot store (BUSY) sets the persistent `repull` flag.** The hub's wm then
    goes past it like a FULL record, and once the DB can store again, every wm is zeroed and
    re-pulled (spec §4.8). Nothing is lost silently.
19. **ERR for a rejected REC body carries the key when the 0x10 TLV parsed** (SYNC_PROTOCOL §11.4,
    `recErrKey()`). The Python sim omits it, but no transcript has that case.
20. **txBusy (HB state bit6) is not an on-change trigger.** Otherwise every transmission would cause
    two HB rounds.
21. **No boot serial log** (1.5 has none, and on the Heltec the UART pads are released). cap, heap
    and the index build time are in `sync_status`.
22. **Image size gate `0x130000`** (the classic stock app slot 0x140000 minus 64 KB) for **both**
    boards, plus a partition-table check in CI.
23. **The node tests run against a `FakeHubDb`**, so the two parts build in parallel. At integration
    the same replay runs once more with the real `HubDbImpl`.

---

## 2. Requirement map

`db` = part 'db', `node` = part 'node', `int` = the integration agent, P1 = already done.

| Requirement (ref) | Files / functions | Part |
|---|---|---|
| SYNC characteristic A7830006, WRITE \| WRITE_NR \| NOTIFY + CCCD (spec §3.1) | `hub_nimble.h` `hubNimbleSetup(svc)`, `SyncChrCallbacks` | int |
| Idle advert layout unchanged; heartbeat flag bit4 (§3.1, D-P2-11) | `.ino` `heartbeatBytes()`, `advManage()` | int |
| MTU 247, chunk = MTU − 5, frame header and per-direction frame seq (§3.2) | `hub_outbox.h` `Outbox` (P1 `Fragmenter`), `hub_node.h` link `Reassembler<512>` | node |
| Reassembly: BAD_FRAME counted, ERR TOO_BIG, ERR PROTO once per link (§3.2, PROTOCOL §9.3) | `HubNode::onFrame()` | node |
| MTU 23 small pull profile; `mtu23` status (§3.2) | P1 `Session::linkUp(t, mtu)`; `HubStatus.mtu23` | P1 / node |
| Messages and codec (§3.3–3.4) | `sync_codec.h` | P1 |
| Session state machine (§3.5) | P1 `Session`, one per link, through a `HubSessionNode` adapter | node |
| Group, proofs, TOFU JOIN, rekey fan-out (§3.6) | P1 `Session`; `HubNode` ACT_GROUP → `HubDb::setGroup` + `groupChanged`/`rekey` on the other sessions | node; NVS `grp` db |
| Members only on a grouped hub, 10 s (§3.6) | session `DEADLINE`; node connect deadline for links without a session | node |
| Leave the group by button (§3.6) | `oled_ui.h` DEVICES hold, `.ino` BOOT hold → `HubSync::leaveGroup` | int + node |
| Peer state persisted in NVS (§3.7) | `HubDb` peers (`peerGet`, `peerCommitted`, blob `peers`) | db |
| Serving a PULL: durable-only, superseded skipped, exclusion, scan budget, `more`, `excludeOk` (§3.7) | `HubNode` page server (P1 `PageServer` + `HubDb::feedBegin/feedNext`) | node + db |
| Puller persists wm only after the page's records are flushed (§3.7) | `HubDb::peerCommitted` + flush rule (§4.9) | db |
| Pull triggers (§3.7) | P1 `Session`; `pull_now` after `takeRepullNeeded()` | P1 / node |
| Hub backpressure: pull only with room (§3.7, §4.5) | `HubDb::canTakePage` + the held PULL (§5.5) | db + node |
| Live push forwarding with seenBy (§3.8) | `HubNode::onRec` + P1 `routeLiveRec` + `HubDb::reserveLive` | node + db |
| Page accepts not forwarded; on-change HB after the flush (§3.8) | `HubNode` flush task → `requestHb()` | node |
| EVT relay, EVT_SINCE / EVT_GAP verbatim relay, ≤ 20 EVT/s per link (§3.9) | `HubNode::onEvt/onEvtSince/onEvtGap`, `Outbox` pacing | node |
| Idempotency, LWW (§3.10) | `HubDb::accept` (P1 `applyCheck`) | db |
| Clock: median of the member clocks; future check only when known (§3.11) | `hub_clock.h` `HubWallClock`; `HubNode` calls `observe`; `HubDb::accept(nowKnown, nowMs)` | node + db |
| Versioning, ERR PROTO (§3.12) | P1 `Session` + reassembler | P1 / node |
| Topologies (§3.13) | loopback simulation tests (§5.13) | node |
| Partitions: stock tables (§4.2 → A1) | no CSV; CI decodes the partition tables (§8.9) | int |
| Log layout (§4.3) | `hub_db.h` (§4.2) | db |
| RAM index, adaptive cap (§4.4) | `hub_db.h`; `.ino` buffer allocation (§8.2) | db + int |
| Flush, durability, gating (§4.5) | `HubDb::flush`, `hubFlashWorkAllowed`; node flush timing (§5.10) | db + node |
| Boot and recovery (§4.6) | `HubDbImpl::begin` / `maintain` (§4.6) | db |
| Compaction (§4.7) | `hub_db.h` (§4.7) | db |
| Capacity, FULL, eviction (§4.8) | `hub_db.h` (§4.8) | db |
| Connections, advertising, slot policy (§4.9) | `.ino` `advManage` (§8.3); `HubNode` slot policy (§5.7) | int + node |
| Connection parameters unchanged (§4.10) | `.ino` `onConnect` (no change) | — |
| Pacing; notify with the NULL-mbuf rule (§4.11) | `hub_outbox.h`; `hub_nimble.h` `NimbleRadio::sendFrame` | node + int |
| `loop()` order and budgets (§4.11) | `.ino` (§8.2), `HubSync::service` | int + node |
| Callbacks only enqueue; sleep takes `syncNextDueMs` (§4.12) | `hub_nimble.h`; `HubSync::nextDueMs`; `.ino` sleep | int + node |
| Hub HB, battery, clock (§4.13) | `HubNode::buildHb`; `.ino` `SketchSelf` over power.h | node + int |
| `sync_status`, `sync_reset` (§4.14, §7.1) | `relay_proto.h` actions + `relayFormatSyncStatus`; `.ino`; `HubSync::syncReset/status` | int + node |
| Heltec STATUS line and DEVICES page (§7.2) | `oled_pages.h`, `oled_ui.h` | int |
| HB fields and state bits (§9.1) | `HubNode::buildHb` | node |
| HB interval and on-change (§9.2) | session `TM_HB`; `HubNode::requestHb` | node |
| HB forwarding hops 0 → 1, path (§9.3) | `HubNode::onHb` + `hub_roster.h` | node |
| Runtime estimator (§9.4) → the 1.5 battery model | `SketchSelf` (`powerRuntimeMin()`) | int |
| D5 durable-only | `HubDb` (durableHigh) + node (`limit = durableHigh`) | db + node |
| D15 identity outside backups | the hub's dbId, peers and group live in NVS `mmsync` | db |

---

## 2a. The frozen seam (`hub_ports.h`)

| Interface | Implemented by | Used by |
|---|---|---|
| `Storage` (two files: log, new) | db: `PosixStorage` (host and target VFS), `LittleFsStorage` (mount + usage), test `MemStorage` | `HubDbImpl` |
| `KvStore` (NVS `mmsync`) | db: `NvsKv` (Preferences), test `MemKv` | `HubDbImpl` |
| `TxGate` (+ `hubFlashWorkAllowed`, `hubLightWorkAllowed`) | int: `SketchGate`; tests: `FakeGate` | `HubDbImpl`, `HubNode` |
| `Radio` (event FIFO in, frames out) | int: `NimbleRadio`; tests: the simulation's link | `HubNode` |
| `Clock` (wall estimate) | node: `HubWallClock`; replay: `TranscriptClock` | `HubNode` |
| `Rng` | int: `EspRng`; tests: scripted | `HubDbImpl` (dbId), `HubNode` (nonces, reset) |
| `SelfInfo` | int: `SketchSelf`; tests: fixed values | `HubNode` (HB) |
| `Scheduler` | node: `TaskTable`; replay: the event queue | `HubNode` |
| `HubTrace` (optional) | tests: step logger | `HubNode` |
| `HubDb` | db: `HubDbImpl`; node tests: `FakeHubDb` | `HubNode` |
| `HubSync` | node: `HubNode` | the sketch |

Shared value types: `HubConfig`, `HubPorts`, `HubDbConfig`, `DbEntry`, `DbAccept`, `FeedCursor`,
`FeedBudget`, `DbPeer`, `DbStats`, `HubSelf`, `HubTask`, `HubRadioEvent`, `HubCounts`,
`HubPhoneRow`, `HubStatus`, and the constants (`HUB_*`, `HB_STATE_*`, NVS keys, log format, paths).

---

## 3. Architecture

### 3.1 New files and owners

| File (sketch folder unless noted) | Content | Part | Arduino? |
|---|---|---|---|
| `hub_ports.h` | the frozen seam | done | no |
| `hub_db.h` | `HubDbImpl : HubDb`: log codec, index, checkpoints, dirty queue, recovery, compaction, capacity, peers / group / flag NVS codec | db | no |
| `storage_posix.h` | `PosixStorage : Storage` over `open/read/write/fsync/rename/unlink/mkdir/stat` (base dir) | db | no |
| `storage_littlefs.h` | `hubFsMount(uint32_t* total)`; `LittleFsStorage : PosixStorage` (`usage()` from `LittleFS.totalBytes/usedBytes`) | db | yes |
| `kv_nvs.h` | `NvsKv : KvStore` over `Preferences` (namespace `mmsync`, opened once) | db | yes |
| `test/host/storage_mem.h` | `MemStorage`: durable image + volatile tail, crash / tear / fail injection, gate-violation counter | db | — |
| `test/host/kv_mem.h` | `MemKv` with a write counter and gate checks | db | — |
| `test/host/hub_db_seed.h` | `hubDbSeed(Storage&, KvStore&, const HubDbSeed&)`: writes a log + NVS from a transcript node's state | db | — |
| `test/host/test_hub_db.cc`, `hub_db_smoke11.cc`, `hub_db.mk` | db tests (§4.12) | db | — |
| `hub_node.h` | `HubNode : HubSync`: links, sessions, actions, page server, routing, HB, slot policy, status | node | no |
| `hub_outbox.h` | `Outbox`: per-link message arena, FIFO / priority, pacing, fragmentation | node | no |
| `hub_roster.h` | `Roster`: latest HB per device, paths, ages | node | no |
| `hub_clock.h` | `HubWallClock : Clock` | node | no |
| `hub_tasks.h` | `TaskTable : Scheduler` | node | no |
| `test/host/fake_hub_db.h` | `FakeHubDb : HubDb` (map-backed, same observable behaviour) | node | — |
| `test/host/hub_sim.h` | the gen_vectors `Sim` and the phone `Node` (kinds 2 and 3) ported to C++, scripted nodes, the hub adapter | node | — |
| `test/host/test_hub_node.cc`, `test_hub_replay.cc`, `hub_node_smoke11.cc`, `hub_node.mk` | node tests (§5.13) | node | — |
| `hub_nimble.h` | `NimbleRadio : Radio`, the SYNC characteristic and callbacks | int | yes |
| `esp32-transmitter.ino`, `board.h`, `relay_proto.h`, `oled_pages.h`, `oled_ui.h`, `ota.h`, `README.md`, `test/host/test_relay.cc`, `Makefile` | wiring (§8) | int | — |

### 3.2 Data flow

```
NimBLE host task (callbacks only enqueue + wakeLoop)          loop() task
  onConnect/onDisconnect/onMTUChange ─┐
  SYNC onSubscribe / onWrite ─────────┼─> RX MessageBuffer ─> HubNode::service(now)
  onStatus (NOTIFY_TX) ──────── wakeLoop                         │ Radio::take() (≤ 4 messages)
                                                                 ├─ link Reassembler<512> → P1 Session
                                                                 │     actions → HubNode
                                                                 │       ├─ HubDb (accept, feed, peers, group)
                                                                 │       └─ Outbox (FIFO / priority)
                                                                 ├─ page scan (PageServer + feed)
                                                                 ├─ Outbox → Fragmenter → Radio::sendFrame
                                                                 │         (ble_hs_mbuf_from_flat; NULL → retry)
                                                                 └─ flush / HubDb::maintain (gated)
```

### 3.3 RAM budget (sizes measured on a 32-bit build: `Session` 1,984 B, `Reassembler<512>` 536 B)

| Item | Classic ESP32 | Heltec V3 (S3) |
|---|---|---|
| Index, adaptive: `cap × 12` | ≈ 3,900 × 12 ≈ 46 KB (≤ 4,096 → 48 KB) | 8,192 × 12 = 96 KB |
| Pending inserts 32 × 12, checkpoints 2 × 1 KB | 2.4 KB | 2.4 KB |
| Dirty queue | 4 KB | 8 KB |
| DB I/O scratch | 4.5 KB | 4.5 KB |
| RX MessageBuffer | 4 KB | 4 KB |
| 3 links × (Session 2.0 + reassembler 0.5 + outbox 2.0 + link state 0.2 KB) | 14.1 KB | 14.1 KB |
| Peers 8, roster 4, task table 48 × 16 B, clock 4 | ≈ 1.6 KB | ≈ 1.6 KB |
| LittleFS caches (read 512, prog 512, lookahead 128, 1–2 file caches) | ≈ 2–3 KB | ≈ 2–3 KB |
| **Total** | **≈ 79 KB** | **≈ 135 KB** |

The cap is `hubIndexCap(heap_caps_get_largest_free_block(MALLOC_CAP_8BIT), max)`, measured after
every other buffer is allocated: `clamp((largest − 64 KB) / 12, 1024, 4096 | 8192)`. A 110 KB
largest block gives 3,925; this is the spec's `cap 3900`. The classic board's largest DRAM block
after NimBLE init is unmeasured (expected 100–120 KB), so the boot value is reported in
`sync_status` `cap` / `heap`. 1.5's static RAM is 37.2 KB (classic) and 34.1 KB (S3).

---

## 4. Part 'db': the library store

### 4.1 Classes

- `HubDbImpl : HubDb` (`hub_db.h`). One instance, owned by the sketch. It gets its buffers and ports
  through `HubDbConfig` (`hub_ports.h`) and never calls `malloc`.
- `PosixStorage : Storage` takes a base directory (host: a temp dir; target: `/littlefs/mm`). It
  uses the POSIX fd API: one `open(O_RDWR | O_CREAT | O_APPEND)` handle per file, `lseek` + `read`
  for reads, `write` for appends, and `fsync` for `sync()`. `promoteNew()` is `rename(new, log)`;
  if that fails with `EEXIST`/`EACCES`, it does `unlink(log)` then `rename`. `mkdir` runs at
  mount.
- `LittleFsStorage : PosixStorage` (target) adds `hubFsMount(&total)` =
  `LittleFS.begin(true, HUB_FS_BASE, HUB_FS_MAX_FILES, HUB_FS_PARTITION)`, plus `usage()`.
- `NvsKv : KvStore` (target): `Preferences::begin(HUB_NVS_NAMESPACE, false)` once,
  `getBytes/putBytes/getUInt/putUInt/remove`. Each put commits.

### 4.2 On-flash format (exact)

Files: `/littlefs/mm/lib.log` (the log) and `/littlefs/mm/lib.new` (compaction output). All
integers are little-endian. An entry is:

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | magic `0xA7` (`HUB_LOG_MAGIC`) |
| 1 | 1 | type: 1 RECORD, 2 END, 3 HEADER |
| 2 | 2 | `len`, the payload length: RECORD 1..360, HEADER ≥ 12, END 8 |
| 4 | 4 | seq (RECORD: ≥ 1, ≤ `HUB_SEQ_MAX`; HEADER / END: 0) |
| 8 | 8 | syncFrom: the peer's deviceId (all zero = unknown; the hub has no local records) |
| 16 | len | payload |
| 16 + len | 4 | CRC-32 (zlib, `crc32()` of sync_crypto.h) over bytes `[1, 16 + len)`: type through payload |

- **HEADER** payload (12 B): `dbId[8] ‖ formatEpochS u32` (wall seconds at creation, 0 = unknown).
  It is the first entry of every log. Readers accept `len ≥ 12` and ignore the extra bytes (room for
  a later format).
- **RECORD** payload: the canonical body, verbatim (bodies were validated at accept).
- **END** payload (8 B): `count u32 ‖ maxSeq u32` (count = RECORD entries in the file). It is the
  last entry a compaction writes. After a promote, appends follow it; readers skip it.
- Entry size = `20 + len`. RECORDs appear in strictly ascending seq in every file.
- Example: the PRESENCE of `8301E100E90C00010F4D575A940705488BB0` at seq 1, syncFrom
  `A1B2C3D4E5F60718`, is 51 bytes: `A7 01 1F00 01000000 A1B2C3D4E5F60718` + the 31-byte body
  (SYNC_PROTOCOL §4.3) + CRC. `test_hub_db` pins the full bytes.
- Validity of an entry at offset `o`: magic, known type, `len` in range for the type,
  `o + 20 + len ≤ size`, and CRC. A RECORD body must also yield its key (the first TLV is `0x10`
  with 4..30 bytes); otherwise it counts as corrupt.

### 4.3 NVS namespace `mmsync` (exact)

| Key | Type | Content | Written |
|---|---|---|---|
| `db` | blob 8 | dbId | at boot when created or changed; at `sync_reset` |
| `grp` | blob 24 | `groupId[8] ‖ groupKey[16]`; absent = ungrouped | `setGroup` (erased when ungrouped), next allowed moment |
| `peers` | blob `1 + 26·n` | `[version 1]` + n ≤ 8 × `{deviceId 8, dbId 8, wm u32, excludeOk u8, kind u8, lastSyncEpochS u32}` | rules in §4.9 |
| `full` | u32 | bit0 hubFull, bit1 repull (`HUB_FLAG_*`) | when it changes |
| `live` | u32 | liveHigh (D-P2-4) | `reserveLive`; 0 at reset / new dbId |

Every NVS write needs the flash gate. RAM changes at once; the write happens at the next allowed
`maintain()`. `power.h` and `btsleep.h` keep their own namespace `mm`.

### 4.4 RAM index, pending inserts, checkpoints, dirty queue

- **Index**: a sorted array of `cap` entries `{hashLo, hashHi, ref}` with
  `ref = seq (bits 0..29) | PRESENCE << 30 | DELETED << 31`. The hash is
  `cfg.keyHash ? cfg.keyHash(key) : keyHash(key)` (FNV-1a 64 over `ns ‖ packet`). Lookup is a
  binary search, then a linear check of the pending list.
- **Pending inserts**: up to 32 unsorted entries for new keys. They are merged into the array in
  one backward pass (sort the pending list, then merge from the end: one memmove-equivalent, about
  0.3–0.6 ms for 48 KB at 80 MHz) by `maintain()` when the light gate is open, or synchronously
  when the list is full and the light gate is open. Full with the gate closed means `DBR_BUSY`.
- **Collision guard**: a hash match with a different key (compared against the stored body's key
  TLV, read by seq) means `DBR_COLLISION`.
- **Checkpoints**: two tables (current, and the one compaction builds) of `{seq, off}`. Each holds
  `ckptBytes / 2 / 8` slots and keeps every K-th durable RECORD; K starts at 32 and doubles (every
  other slot dropped) when a table fills. `locate(seq)` binary-searches the checkpoints, then reads
  entry heads forward (16 B each, through a 512 B read window in `ioMem`).
- **Dirty queue**: the encoded log entries awaiting the flush, in seq order. An entry with
  seq > durableHigh is found by scanning the queue (at most about 130 entries in 8 KB).
- **Counters** kept exactly: `records`, `presences`, `tombstones` (from the class bits),
  `liveBytes` (Σ of `20 + bodyLen` over current entries), `logBytes`, `lastSeq`, `durableHigh`.

### 4.5 Accept path and durability

`accept(body, len, syncFrom, nowKnown, nowMs, live, now)`:

1. Not `DB_READY` → `DBR_NOT_READY`.
2. Run `applyCheck()` (sync_codec.h) against the current version. That needs `lookup(key)`, a read
   by seq (dirty queue or file), and the CRC of the stored body. BAD_MSG and CLOCK map to
   `DBR_BAD_MSG` and `DBR_CLOCK` (with the key when it parsed); DUPLICATE and STALE map through
   unchanged.
3. A new key goes through the capacity rules (§4.8), which can give `DBR_FULL`. A new key with the
   pending list full and the light gate closed gives `DBR_BUSY`. So does a dirty queue without room
   for `20 + len`. A BUSY for a page REC (`live == false`) also sets `HUB_FLAG_REPULL` (D-P2-18).
4. **ACCEPT**: `seq = lastSeq + 1`. Encode the RECORD into the dirty queue, update or insert the
   index (class bits from the body), adjust the counters, and record the first-dirty time.
5. Flash is never touched here.

**durableHigh** is the highest seq appended **and** synced. Only entries ≤ durableHigh are on
flash. HELLO and HB `feedHigh`, `PAGE_END` `feedHigh`, and pages (the node passes
`limit = durableHigh()`) use only that.

**`reserveLive(seq, now)`**: true when `seq ≤ durableHigh` or `seq ≤ persistedLive`. Otherwise,
when the flash gate is open, it writes NVS `live = seq` and returns true. When the gate is closed it
returns false and counts `liveSkipped`.

### 4.6 Boot and recovery (`begin()` + build steps in `maintain()`)

Order in `begin()`: storage mounted? → read NVS (`db`, `grp`, `peers`, `full`, `live`) → resolve
the files → open `lib.log` → read and check the HEADER → `DB_BUILDING`. The scan (and with it the
torn-tail, corruption and liveHigh checks) runs in `maintain()`, at most `HUB_BUILD_BYTES` per call,
light gate. A new dbId comes from `Rng::random(8)`, retried until it is non-zero; this runs after
NimBLE init.

| Found | Action | bootFlags |
|---|---|---|
| storage not mounted (the format inside `LittleFS.begin` failed too) | `DB_FAILED`; the node starts no sessions; heartbeat bit4 cleared | `FORMAT_FAILED` |
| `lib.new` and `lib.log` both present | remove `lib.new` (an unfinished compaction) | `NEW_REMOVED` |
| `lib.new` present, `lib.log` missing | only reachable through the remove-then-rename fallback, and the compactor syncs and closes `lib.new` first: `promoteNew()`. If its END is missing or bad at the end of the scan, treat it as corruption | `NEW_PROMOTED` |
| no `lib.log`, no NVS `db` (first boot) | new dbId → NVS `db`; create `lib.log` with HEADER | `LOG_CREATED` |
| no `lib.log`, NVS `db` present (D-P2-17) | new dbId, zero peers, `live = 0`; create `lib.log` | `LOG_CREATED \| NEW_DBID` |
| first entry not a valid HEADER | corruption (below) | `CORRUPT` |
| HEADER dbId ≠ NVS `db` (or NVS `db` missing) | new dbId (RAM + NVS now; the HEADER is rewritten by the next compaction), zero peers | `HEADER_MISMATCH \| NEW_DBID` |
| scan: an invalid entry with no valid entry after it (searched byte-wise for magic + valid CRC) | keep the valid prefix; **hold appends** until a compaction rewrites the file (start it at the first allowed moment, quiet rule waived) | `TORN_TAIL` |
| scan: an invalid entry followed by valid entries | index every valid entry; new dbId, zero peers; compaction (quiet rule waived) | `CORRUPT \| NEW_DBID` |
| scan done, NVS `live` > maxSeqInLog | new dbId, zero peers, then `live = 0` | `LIVE_LOST \| NEW_DBID` |
| NVS `full` bits set | restore hubFull / repull; repull → `takeRepullNeeded()` after ready | — |

Then `nextSeq = maxSeqInLog + 1` (`lastSeq = durableHigh = maxSeqInLog`) and `DB_READY`. A seq that
was never flushed was never served (D5), and a lost live-forwarded one forces a new dbId (above),
so reusing a seq is safe. "New dbId" never deletes records: the library stays and only its feed
identity changes, so every peer re-pulls and re-serves without exclusion (SYNC_PROTOCOL §15.1).

### 4.7 Flush and compaction

**Flush** (`flush(now, force)`):
- Without `force`, it runs only when `hubFlashWorkAllowed(gate, now, starved)` holds, where
  starved = the oldest dirty entry is ≥ 30 s old; else `DB_FLUSH_DEFERRED`. While compaction holds
  flushes, also `DEFERRED`.
- One `append` of the whole dirty queue, then `sync`. On success: durableHigh = the last dirty seq,
  checkpoints added, queue cleared, and peers whose pending commit is now durable become due
  (§4.9).
- On failure: the dirty data is kept and counted, and a retry comes on a later pass. After three
  failures in a row a compaction is forced (it may be ENOSPC).
- Cost per flush: littlefs copies the partly filled last block into a fresh block (one 4 KB erase
  plus ≤ 4 KB of programming) and commits metadata: roughly 20–150 ms with the cache off. That is
  why it needs the ≥ 400 ms gap.

**Compaction**:
- Trigger: `logBytes > max(128 KB, 2 × liveBytes)`, or the FS free estimate drops below 256 KB, or
  a recovery needs it (torn tail, corruption, or a new dbId's HEADER rewrite).
- It starts only under the flash gate and, unless recovery needs it, after 10 s with no page
  traffic (`notePageTraffic`).
- Steps, one per allowed `maintain()`, each ≤ 4 KB:
  1. `open(NEW, create)`; write the HEADER with the **current** dbId.
  2. Copy the current RECORDs of `lib.log` in order, keeping seq and syncFrom, and build the second
     checkpoint table as you go. Flushes are held meanwhile: accepts keep going into the dirty
     queue, and BUSY when it is full.
  3. Write END `{count, maxSeq}`, `sync(NEW)`, `close(NEW)`.
  4. `close(LOG)`; `promoteNew()`; `open(LOG)`; switch the checkpoint tables; `gen++`, so feed
     cursors re-position by seq; refresh `usage()`. Release the held flush.
- Crash at any step: the old `lib.log` stays valid until the atomic rename (step 4). Boot removes a
  stray `lib.new`, or promotes it in the fallback case (§4.6).
- Because the index holds seqs (D-P2-2), the index never needs a rebuild after the swap, and pages
  keep being served during the whole compaction.

### 4.8 Capacity (the stock partitions, A1)

| | Classic ESP32 (`default.csv`) | Heltec V3 (`default_8MB.csv`) |
|---|---|---|
| App slots | app0 / app1 `0x140000` (1,310,720 B) each | `0x330000` (3,342,336 B) each |
| `spiffs` partition | `0x290000`, size `0x160000` = 1,441,792 B = 352 × 4 KB blocks | `0x670000`, size `0x180000` = 1,572,864 B = 384 blocks |
| `liveMax = hubLiveMaxBytes(total)` = `(total − 96 KB) / 3`, rounded to 4 KB | **446,464 B (436 KB)** | **491,520 B (480 KB)** |
| Index cap (RAM) | ≈ 3,900 (floor 1,024, max 4,096) | 8,192 |
| Records at ~55 B per entry (PRESENCE-heavy) | **≈ 3,900** (RAM-bound) | **≈ 8,192** (RAM-bound; flash would allow ≈ 8,900) |
| Records at ~95 B per entry (named USER records) | ≈ 3,900 (RAM-bound) | ≈ 5,200 (flash-bound) |
| Worst case (307 B bodies, 327 B entries) | ≈ 1,360 | ≈ 1,500 |

Why `/3`: during a compaction the old log (up to ~2 × live + one batch) and the new file (live)
coexist. `3 × liveMax + 96 KB` fits each partition. After one 8 KB batch and 4 metadata blocks,
about 76 KB (classic) or 72 KB (Heltec) stays free at the worst moment, above the 64 KB refusal
threshold. The spec's 200–3,500 records fit on both boards.

**Rules**, applied to a **new key** only (a new version of a stored key is always stored):
- At `records == cap`, or `liveBytes + 20 + len > liveMax`, or FS free < 64 KB:
  - Incoming class not PRESENCE: evict the oldest current PRESENCE, i.e. the lowest seq among
    PRESENCE-flagged index entries (a RAM scan). If there is none, evict the oldest TOMBSTONE.
    Repeat (up to 4 times) until it fits, then store it. An evicted entry stays in the log as a
    superseded entry until compaction drops it. `evicted = true`.
  - Otherwise: `DBR_FULL`, and hubFull is set (NVS `full` bit0; HB state bit 9).
- hubFull clears with hysteresis, when `records ≤ cap − 64`, `liveBytes ≤ liveMax − 16 KB` and FS
  free ≥ 128 KB (after `sync_reset` or a compaction that freed bytes). Clearing hubFull or repull
  makes `takeRepullNeeded()` return true once. The node then calls `zeroAllWm()` and `pull_now` on
  every member (spec §4.8).
- **FS free estimate**: `fsUsed ≈ blocks(logBytes) + blocks(newBytes) + 4 metadata blocks`. It is
  refreshed from `Storage::usage()` at boot and after each compaction, never per accept (`usage()`
  walks the FS).

### 4.9 Peers (spec §3.7, SYNC_PROTOCOL §15.1)

- **RAM table**: up to 8 entries `{id, PeerState st, kind, lastSyncEpochS, safeWm, safeDbId,
  pendingWm, pendingDbId, needSeq, due, lastWriteMs, lastUse}`.
  - `peerGet` creates `{zero dbId, wm 0, excludeOk false}` and, when the table is full, reuses the
    least recently used entry. Strangers never reach `peer()`: P1 calls it only from AUTHED on, so
    they cannot flood the table.
  - A pointer stays valid until the next `peerGet` of an unknown id. Sessions do not hold pointers
    across inputs.
- **Loaded** from NVS `peers` at `begin()`: `st = {dbId, wm, excludeOk}` and `safeWm = wm`.
- **`peerCommitted(id, wallS, now)`**: `pendingWm = st.wm`, `pendingDbId = st.dbId`,
  `needSeq = lastSeq`, `lastSyncEpochS = wallS`. When `durableHigh ≥ needSeq`, the pair becomes
  safe (`safeWm, safeDbId`) and the peer is **due**. So a wm is never persisted ahead of the records
  it covers. `HubDb::flush` checks this after every flush.
- **Persisted wm** = `st.dbId == safeDbId ? safeWm : 0`. `st.excludeOk` and `kind` are persisted as
  they are.
- **Writing the blob**: one `peers` write covers every due peer. It happens in `maintain()` under the
  flash gate, when a peer is due **and** (it has not been written for 60 s, or its session ended, or
  `zeroAllWm` / reset / new dbId happened). It is skipped when the bytes are unchanged.
- **`zeroAllWm`**: every `st.wm = 0`, `safeWm = 0`, `excludeOk` unchanged; written at the next
  allowed moment.

### 4.10 `HubDb` contract details (what `FakeHubDb` must mirror)

| Method | Observable behaviour |
|---|---|
| `begin` | `state()` is `DB_BUILDING` or `DB_FAILED` after it; `ready()` once the build is done. With an empty or new log, `ready()` may already be true after the first `maintain()`. |
| `maintain` / `maintenanceDue` | `maintenanceDue` is true only if `maintain` would do something now (gates checked). The node turns it into `nextDueMs() == 0`. |
| `dbId`, `durableHigh`, `lastSeq` | as in §4.5. `lastSeq ≥ durableHigh`; both 0 for an empty store. |
| `accept` | statuses as in §4.5. The seq of an ACCEPT is `lastSeq + 1` (no gaps). The entry is "current" at once: `lookup` and a feed with a dirty-inclusive limit see it. |
| `lookup` | the current entry, dirty or durable. |
| `canTakePage(maxBytes)` | light gate open, dirty free ≥ `max(maxBytes, 330) + 10 × 32`, pending room ≥ 32, no compaction swap waiting. |
| `reserveLive` | as in §4.5. |
| `flush(force)` | `DONE` → `durableHigh == lastSeq`; `NONE` when nothing is dirty; `DEFERRED` when gated (nothing written). |
| `feedBegin(since, limit)` + `feedNext` | yields current entries with `since < seq ≤ limit` in ascending seq. Superseded and evicted entries are skipped but spend budget. `YIELD` when the budget (32 entries / 4 KB read per pass) is spent, `END` after `limit`. The cursor survives flush and compaction. |
| peers | as in §4.9. `peerAt` iterates in table order. |
| `setGroup` | `group()` returns the new value at once. NVS follows. |
| `full`, `takeRepullNeeded` | as in §4.8. |
| `requestReset(newDbId)` | `DB_RESETTING` (`ready()` false) until the wipe ran under the flash gate. Then `DB_READY` with `lastSeq = durableHigh = 0`, `dbId = newDbId`, peers zeroed (table emptied), full / repull / live cleared, group kept. |
| `stats` | every `DbStats` field. |

### 4.11 Back-end specifics

- **`MemStorage`** (host): per file, a durable image and a volatile tail.
  - `sync` moves the tail into the image.
  - `crash(mode)` drops the tail, keeps it, or tears it at a given byte, and can corrupt a given
    byte of the image.
  - `promoteNew` is atomic; `failNext(op)` injects errors; `setTotal(bytes)` simulates a small FS.
  - Every mutating call made while the attached fake gate is closed is counted as a violation; the
    tests assert 0.
- **`MemKv`** (host): atomic puts, a write counter, gate-violation counting, `crash()` (no-op: NVS
  writes are atomic).
- **`PosixStorage`** runs in the host tests on a `mkdtemp` directory (rename-over, fsync, read after
  append) **and** on the target over the LittleFS VFS. The only Arduino-dependent code is the mount
  and `usage()`.
- **First boot after the upgrade from 1.x**: the `spiffs` partition was never formatted, so
  `LittleFS.begin(true, …)` formats it in `setup()` before NimBLE starts. This is a one-time cost of
  up to a few seconds if the core's esp_littlefs erases the whole partition (measure it in
  integration, §11). It happens before `NimBLEDevice::init`, so no link or burst is affected.

### 4.12 Tests (part db): `test/host/test_hub_db.cc` (C++17, ASan / UBSan) + `hub_db_smoke11.cc` (gnu++11 `-Werror`)

1. **Format**: entry encode/decode; CRC; HEADER / END; the pinned 51-byte PRESENCE entry; reject
   every single-byte corruption of an entry.
2. **Accept ≡ apply**: every `apply` vector script with only `remote` steps, run through `HubDb`,
   gives the same status per step and the same final `{u, o, c, b, s, f}` per key. Exception:
   scripts with tombstone-cap evictions, because the hub's policy differs (assert the status only).
3. **Append / flush / reload**: the index, counters, durableHigh, lastSeq and peers after a
   `begin()` on the same storage equal those before.
4. **Durable-only**: with dirty entries, a feed with `limit = durableHigh` never yields them. Crash
   at every point between accept and flush: after reload, durableHigh ≤ the flushed seq and nothing
   beyond it is served.
5. **Power-loss fuzz**: truncate the log at every byte of the last 3 entries, and flip every byte of
   them. Recovery = the durable prefix. Torn tail → no new dbId; middle corruption → new dbId and
   zeroed peers; flushes are held until the compaction rewrite, then reload is clean.
6. **Compaction crash at each step** (1–4, and between remove and rename in the fallback): reload
   gives the same current set; `lib.new` is removed or promoted per §4.6.
7. **HEADER / NVS mismatch; missing log with NVS db (D-P2-17); liveHigh > maxSeq** → new dbId,
   zeroed peers.
8. **Feed**: superseded entries skipped; the budget yields; END semantics; the cursor across flush
   and across compaction (`gen`) gives identical pages before and after compaction for the same
   pulls; with P1 `PageServer`, the `pages` vectors reproduce byte for byte when the DB holds
   exactly the vector's entries (seeded through `hubDbSeed`).
9. **Capacity**: with a small `indexBytes` (cap 1,024) and a small `liveMaxBytes` — eviction order
   (oldest PRESENCE, then TOMBSTONE), FULL for PRESENCE at cap, hubFull persisted and restored, the
   clear hysteresis, `takeRepullNeeded` once; FS free < 64 KB refusal with `MemStorage::setTotal`.
10. **Forced collision** through `cfg.keyHash` (a hash that maps two keys alike) → `DBR_COLLISION`,
    nothing stored.
11. **Gating**: a scripted `FakeGate` (timed job, `msUntilDue` 0..1000, a command waiting, OTA) —
    zero `MemStorage` / `MemKv` mutations while the flash gate is closed; no merge while a timed job
    is on air; the starvation rule (≥ 200 ms after 30 s); `flush(force)` is the only exception.
12. **Peers**: wm persisted only after the flush that covers the page; ≤ once per 60 s per peer;
    at session end; LRU reuse; blob round trip; `zeroAllWm`; reset.
13. **`sync_reset`**: wipe, new dbId, group kept, peers empty, full / repull / live cleared;
    `DB_RESETTING` until the gate opens.
14. **`reserveLive`**: durable → true without a write; gate closed → false and counted; written
    exactly once per new high.
15. **Back-ends**: `PosixStorage` on a temp dir passes the same `Storage` conformance test as
    `MemStorage`.
16. **Target compile**: `storage_littlefs.h` and `kv_nvs.h` compile in a scratch PlatformIO project
    of the db agent's own (a stub `.ino` that includes them, both envs). This follows the
    one-build-at-a-time rule.

---

## 5. Part 'node': the hub role

`HubNode` is to the C++ P1 core what the Kotlin `SyncNode` + `HubStandInRole` are to the Kotlin
core: a port of `tools/sync/gen_vectors.py` `class Node` with kind 1, driven by real inputs.

| gen_vectors `Node` / Kotlin `SyncNode` | `HubNode` |
|---|---|
| `cores[lid]` (one `SessionCore` per link) | one P1 `Session` per link slot + a `HubSessionNode : SessionNode` adapter (holds the link slot) |
| `SessionCtx` refreshed before each input | `adapter.group = db.group()`, `dbId = db.dbId()`, `feedHigh = db.durableHigh()`, `ready = db.ready()` before every Session call |
| `ctx.peers` | `findPeer` → `db.peerFind`; `peer` → `db.peerGet(id, peerHello.kind)` |
| `next_nonce` | `rng.nonce(conn, out)` |
| `clock(t)` | `clock.wallMs(t, &ms) ? ms : 0` |
| `core_input` action loop, deferred group fan-out | `HubNode::input(link, …)`, the same order (§5.2) |
| `sim.sync_timers` | after every input, each newly armed `(timer, due)` → `sched.at(TK_TIMER)` |
| `on_deliver` PULL → `serve_page` | page server (§5.5) |
| `on_rec`, `on_hb`, `on_evt`, `on_evt_since`, `on_evt_gap` | §5.6, §5.9, §5.8 |
| `mark_dirty` / `save_now` (`HUB_FLUSH_MS` 2,000) | `markDirty()` → `TK_FLUSH` at +2 s → `db.flush` (§5.10) |
| `request_hb` / `_hb_round` / `build_hb` | `requestHb()` / `TK_HB_ROUND` / `buildHb()` (§5.9) |
| `sync_reset` | `syncReset(conn)` (§5.7) |
| `authed_sessions()` in dict order | links in **session creation order** (a counter assigned at SUBSCRIBE): every iteration (routes, HB links, HB round) uses it. Slot order is not session order. |

### 5.1 Link table

`HUB_MAX_LINKS = 3` slots. Each slot holds:
- `conn`, a `gen` (incremented per CONNECT), `mtu`, `subscribed`, `order` (session creation
  counter), `connectAt`;
- the `Session`, the `SessionConfig`, the adapter;
- `Reassembler<512>`, `Outbox` (P1 `Fragmenter` inside);
- the page-serving state `{active, reqId, PageServer, FeedCursor, since, limit}` and a held PULL
  (≤ 64 B);
- the registered timers (≤ 16 `(id, due)`), counters (bad frames, ERRs, pages, recs), `lastErr`;
- `closing {reason, deadline}`, `txBlockedUntil`, `lastFrameMs`, the EVT rate bucket and
  `protoErrSent`.

`SessionConfig` for every link: `{ROLE_PERIPHERAL, cfg.deviceId, KIND_HUB, cfg.bootId, HUB_MAXMSG
512, CAPS_HUB 0x0039, cfg.version, cfg.name, peerKind 0, tracksEvents false, isHub true}`.

### 5.2 Inputs and the action loop

Radio events (`service()` takes them in order, ≤ 4 reassembled messages per pass):

| Event | Reaction |
|---|---|
| `CONNECT(conn, mtu)` | allocate a slot. With 3 connections, disconnect the **newest non-member** at once (`slots`). If grouped, arm `TK_CONN_DEADLINE` at +10 s (dropped as `deadline` unless a session reached AUTHED by then). |
| `MTU(conn, mtu)` | `link.mtu = mtu`, used from the next frame. |
| `SUBSCRIBE(conn, 1)` | `DB_FAILED` → ignored (no session). Otherwise `session.linkUp(now, mtu)` and process its actions. The session arms its own DEADLINE on a grouped hub. |
| `SUBSCRIBE(conn, 0)` | `session.linkDown`; `db.peerSessionEnd(peer)`; the connection stays (1.5 behaviour). Grouped: `TK_CONN_DEADLINE` again. |
| `FRAME(conn, data)` | no session → dropped and counted. Otherwise `reasm.feed()`: `RA_DELIVER` → `input(rx)`; `RA_BAD_FRAME` → count; `RA_ERR_TOO_BIG` → `ERR{TOO_BIG, refType}`; `RA_ERR_PROTO` → `ERR{PROTO}` once per link. |
| `TX_DONE` | clear `txBlockedUntil` for that link (or all links when conn is NONE). |
| `RX_OVERFLOW(conn)` | count; `ERR{BUSY, retryMs 1000}` at most once per second per link. The reassembler finds the gap itself. |
| `DISCONNECT(conn)` | `session.linkDown`; `db.peerSessionEnd`; free the slot (the outbox is dropped). |

`input(link, call)` runs one Session call, then its actions in order:

| Action | `HubNode` |
|---|---|
| `SEND` | PULL: if `db.canTakePage(maxBytes)` → enqueue, else hold it in the link's held-PULL slot (a later PULL replaces it). Anything else → enqueue. `trace.sent` at enqueue. |
| `STATE` | `trace.state`. AUTHED → `clock.observe(peer, hello.clockMs)` when > 0. Leaving LINKED with a known peer: another link's session with the same peer deviceId is disconnected (`stale`, the older one). PRODUCTION: an AUTHED+/SYNCED edge → `requestHb()`. Status memo for FOREIGN / INCOMPATIBLE / NOGROUP. |
| `DELIVER` | by type: PULL → page server (§5.5); REC → §5.6; HB → §5.9; EVT, EVT_SINCE, EVT_GAP → §5.8; SUB → nothing (the session keeps the subs). ERR → counters / `lastErr` only: the P1 session has already reacted (NOT_READY / BUSY with refType PULL back off the hub's pull, TOO_BIG halves maxBytes, DB_CHANGED resets the peer and re-pulls from 0, AUTH → FOREIGN, PROTO → INCOMPATIBLE). FULL / CLOCK / COLLISION from a phone are counted. |
| `COMMIT` | `db.peerCommitted(peer, wallS, now)`; then, as `mark_dirty_if_needed`: if `db.lastSeq() > db.durableHigh()` → `markDirty()`. |
| `GROUP` | `db.setGroup(adapter.group, now)`; `trace.group`; deferred fan-out after the loop: every other link with a session gets `rekey(t)` (rekey and AUTHED+) or `groupChanged(t)`. Links without a session now get the 10 s connect deadline. |
| `NODE` | `send_hb` → `sendHb({link})`; `foreign` → `trace.foreign` + memo; `evt_since` never happens on the hub. |
| `DISCONNECT` | `trace.disconnect(reason, retry)`. TRANSCRIPT: `radio.disconnect` at once. PRODUCTION: `closing`, then `radio.disconnect` once the outbox is empty or after 1 s (`HUB_DRAIN_BEFORE_DISCONNECT_MS`), so ERR AUTH reaches the phone. |

After the actions, if the link still has a session: register the newly armed timers. A
`TK_TIMER{due, gen = link.gen, link, arg = id}` fires only when `link.gen` matches and
`session.timerArmed(id) && timerDue(id) == due`. It then emits `trace.timer` and calls
`session.timer(due, id)` (t = due, as in P1).

### 5.3 RX and reassembly

There is one `Reassembler<HUB_MAXMSG>` per link, reset at SUBSCRIBE. Delivered messages go to the
Session exactly as `gen_vectors` delivers them. The raw bytes stay available until the input
returns (HB forwarding and EVT_SINCE / EVT_GAP relays copy them).

### 5.4 Outbox and pacing (`hub_outbox.h`)

- Per link: a 2 KB arena of whole messages `[class u8][len u16][bytes]` plus the `Fragmenter`, reset
  at SUBSCRIBE. The head message is being fragmented; it is never removed or reordered once its
  first frame left.
- **Selection**: FIFO while no timed job is on air (D-P2-8). While one is on air: the highest class
  first (`ERR 0 > control 1 (HELLO, AUTH, JOIN, PULL) > HB 2 > EVT / relays 3 > live REC 4 > page
  REC / PAGE_END 5`), FIFO within a class.
- **Sending**: ≤ `HUB_FRAMES_PER_PASS` (4) frames per link per pass. While a timed job is on air,
  1 frame per link per 40 ms (`lastFrameMs`). `Radio::sendFrame` false → stop that link and set
  `txBlockedUntil = now + 20 ms`; `TX_DONE` or that time lets it try again.
- **Overflow** (a message does not fit):
  - ERR and control are never dropped (the room is reserved: 2 × 160 B);
  - an HB replaces a queued HB describing the same device;
  - EVT: drop the oldest queued EVT (counted; the evtWm replay heals it);
  - live REC: drop the new one (counted; it arrives by pull);
  - page RECs: the page scan only produces a REC when the room holds one (370 B), so it never
    overflows.
- **EVT pacing**: ≤ 20 EVT relayed per link per second; beyond that, drop and count.

### 5.5 Pull and page serving

**Serving a phone's PULL** (DELIVER PULL; the session already sent ERR DB_CHANGED for a wrong dbId):
- `db.ready()` false → `ERR{NOT_READY, refType 2, retryMs 500}`.
- Otherwise start or replace the link's page:
  `PageServer.begin(pull, limit = db.durableHigh(), excludeOk = peer.excludeOk, peer)`, then
  `db.feedBegin(cursor, pull.since, limit)`, then `db.notePageTraffic`.
- **Scan step** (one per link per pass, light gate; **paused while a timed job is on air** or while
  OTA is busy):
  - While the outbox has room for a 370 B REC: `db.feedNext(budget 32 / 4 KB)`.
  - ENTRY → `PageServer.offer(seq, body, origin?, syncFrom?)`; PAGE_SEND → enqueue the REC
    (class 5); PAGE_SKIP → continue; PAGE_STOP → finish.
  - YIELD → continue on the next pass. END → finish as exhausted. NOT_READY → finish early.
- **Finish**: `e = PageServer.end()`; if exhausted and `since < limit` → `e.scannedTo = limit,
  e.more = 0` (D-P2-3); enqueue PAGE_END. If `e.more == 0` → `peer.excludeOk = true`.

**The hub as puller.** The session sends the PULL itself (AUTHED, PAGE_END `more`, triggers). The
node holds it while `!db.canTakePage(maxBytes)` (no room, or a timed job on air) or
`gate.otaBusy()`. It goes out once the condition clears (checked every pass and after each flush). Holding longer than 10 s
lets the session's PAGE timer re-PULL (replacing the held one); after 3 tries the session
disconnects `page_timeout` and retries in 30 s. That is acceptable and rare.

### 5.6 Records (`onRec`)

- **Body error** (`rec.bodyStatus` not ok): `trace.apply(conn, NULL, BAD_MSG | CLOCK, live)` and
  `ERR{code, refType 3, key = recErrKey()}` (D-P2-19).
- Otherwise: `r = db.accept(body, peer, clock known?, wall, live, now)`, then
  `trace.apply(conn, &key, r.result, live)`. Then by result:

| Result | Reaction |
|---|---|
| `DBR_BAD_MSG` / `DBR_CLOCK` / `DBR_FULL` / `DBR_COLLISION` | `ERR{code, refType 3, key}` |
| `DBR_BUSY` | `ERR{BUSY, refType 3, key, retryMs 1000}` |
| `DBR_NOT_READY` | `ERR{NOT_READY, refType 3, retryMs 500}` |
| `DBR_DUPLICATE` / `DBR_STALE` | nothing |
| `DBR_ACCEPT`, page REC | `markDirty()`, `pageAccepted = true`, `db.notePageTraffic` |
| `DBR_ACCEPT`, live REC | `markDirty()`, then forward: `route = routeLiveRec(self, peer, origin?, rec.seenBy, members-in-session-order with sub = peerSubs & RECORDS)`. If it has targets and `db.reserveLive(r.seq)`: encode once `REC{seq = r.seq, reqId 0, seenBy = route.seenBy, body}` and enqueue to each target (class 4). Otherwise count `liveSkipped`. |

### 5.7 Group, deadlines, slot policy, reset, leave

- JOIN, rekey and FOREIGN come from the P1 session; the node persists the group (`db.setGroup`),
  fans out, and disconnects per the actions.
- **Slot policy** (spec §4.9):
  - a duplicate deviceId drops the older link (`stale`);
  - a third connection drops the newest non-member (`slots`);
  - a grouped hub drops links that are not AUTHED 10 s after connect / subscribe (`deadline` /
    session `auth_deadline`);
  - FOREIGN disconnects after the ERR drained (≤ 1 s).
- **`syncReset(conn)`**: false unless `isMember(conn)`. Otherwise:
  1. `newDb = rng.random(8)` (not zero), then `db.requestReset(newDb)`.
  2. Every session: `trace.disconnect(db_reset)`; `radio.disconnect` after `HUB_RESET_GRACE_MS`
     (TRANSCRIPT: at once).
  3. Reset the node's pending flags: `pageAccepted`, `flushPending`, held PULLs, pages.
  The DB is not ready until the wipe runs, so a quick relink gets NOT_READY (500 ms).
- **`leaveGroup()`**: `db.setGroup(ungrouped)`, then `groupChanged` on every session (each
  disconnects `left_group`).

### 5.8 Events (hub relay only; no ring, no dedupe)

- **EVT from P**: `routeEvtRelay(self, P, origin, seenBy, members with sub = peerSubs & EVENTS)` →
  a copy with the new seenBy → enqueue (class 3) to each target, paced.
- **EVT_SINCE**: forwarded verbatim (the raw bytes) to the first member whose peer == `origin`, if
  that is not the sender.
- **EVT_GAP**: forwarded verbatim to the member whose peer == `requester`.
- Otherwise dropped. The events bit of `subs` gates EVT only (SYNC_PROTOCOL §16.1).

### 5.9 Heartbeats, roster, clock

- **`buildHb()`**: `hbSeq++`, with
  - `deviceId`, `kind` 1, `bootId`, `ts` (wall or 0), `uptimeS` / `battPct` / `battMv` / `charging`
    / `runtimeMin` from `SelfInfo` (−1 values are omitted by the canonical encoder), `version`,
    `name`;
  - `link` = members in session order `{peerId, peerKind, flags: synced (SYNCED), tx-ready (peer
    caps bit3)}`;
  - `state` = `self.state | hubFull (bit9) | clockSkew (bit10) | !db.ready() (bit11)`;
  - `hops` 0, `feedHigh = durableHigh`, `dbId`, `records = DbStats.records` (dirty included, like
    the sim's ledger size).
- **`sendHb(links)`**: one build, the same bytes to each link (class 2); `lastHbT = now`.
- **`requestHb()`**: if no round is pending, `TK_HB_ROUND` at `max(now, lastHbT + 5 s)`. The round
  sends to the members whose `peerSubs & HEARTBEATS`.
- **Triggers**: the session's `send_hb` (at AUTHED and every 60 s from `TM_HB`), and a flush after
  page accepts (both policies). PRODUCTION also uses member-set and SYNCED edges, `selfChanged()`,
  and hubFull / clockSkew / ready changes.
- **`onHb(link, hb, raw)`**:
  - `roster.update(hb, fromPeer, direct, now)` with `hbReplaces`.
  - If direct (hops 0 and `deviceId == peer`): forward
    `routeHb(self, peer, hb.deviceId, 0, members with sub = peerSubs & HEARTBEATS)` with
    `hbSetHops(copy, 1)`; and `clock.observe(peer, hb.ts)` when `ts > 0` and kind ≠ hub.
- **`Roster`** (≤ 4 devices, LRU, never the hub itself) keeps:
  - `{id, kind, bootId, hbSeq, battPct, charging, runtimeMin, name}`;
  - `lastAnyMs`, `lastDirectMs`, `lastViaMs`, `viaKind`.

  Path: DIRECT if a direct HB is ≤ 90 s old, VIA if a forwarded one is, BOTH if both; age = now −
  `lastAnyMs`.
- **`HubWallClock`**: per phone (≤ 4) `offset = phoneMs − now` (int64) and the time it was seen.
  - wall = `now + median(offsets seen in the last 6 h)`. With no recent offset, the last one; never
    "unknown" again once learned. For two values the median is their mean; with three or more, the
    middle one.
  - `skewed()`: max − min > 5 min sets it; ≤ 1 min clears it.

### 5.10 Policies, flush timing, on-change rules

| | PRODUCTION | TRANSCRIPT (`HUB_POLICY_TRANSCRIPT`) |
|---|---|---|
| `markDirty` (an ACCEPT, or a commit with dirty data) | if no flush is pending: `TK_FLUSH` at +2 s | same |
| `TK_FLUSH` | `db.flush(now, false)`; `DEFERRED` → `flushWanted`, retried every pass while the gate allows | `db.flush`, never deferred (open gate) |
| Size trigger | dirty ≥ 2 KB → flush on the next allowed pass | off |
| After `DB_FLUSH_DONE` | `trace.durable(durableHigh)` if it changed; if `pageAccepted` → `pageAccepted = false`, `requestHb()` | same |
| On-change HB | flush after page accepts, member-set / SYNCED edges, `selfChanged`, hubFull / skew / ready | flush after page accepts only |
| Disconnect | after the outbox drains (≤ 1 s) | at once |
| Live forward | needs `reserveLive` | same (the fake DB always grants) |

### 5.11 Status (`status()`, `counts()`)

`HubStatus` (`hub_ports.h`) is filled from `DbStats`, the link table, the roster and the clock:
- `phones[]`: members first, in session order, then roster devices that are not linked (most recent
  first).
- `state` mapping: LINKED → 0; HELLO_X / AUTHED → 1; SYNCING 2; SYNCED 3; FOREIGN 4; NOGROUP 5;
  INCOMPATIBLE 6; not linked 0xFF.
- `memberConns[]` feeds the `sync_reset` shadow (§8.5).
- `heapFree` / `heapMin` are left 0 for the sketch to fill.

### 5.12 Scheduler, `TaskTable`, `nextDueMs`

- **`TaskTable : Scheduler`**: 48 entries. `at()` replaces a pending entry with the same
  `(kind, link, arg)`, since a re-armed timer makes the older one a no-op anyway, and keeps an
  insertion counter. `popDue(now)` returns entries in `(due, counter)` order.
- **Node task kinds**:
  - `TK_TIMER` (session timer, gen = link gen);
  - `TK_HB_ROUND`;
  - `TK_FLUSH`;
  - `TK_CONN_DEADLINE` (link, gen);
  - `TK_DRAIN` (a closing link's 1 s limit);
  - `TK_TX_RETRY` (link, 20 ms);
  - `TK_RESET` (the 750 ms reset grace).
- **`service()` budget**: ≤ `HUB_MSGS_PER_PASS` delivered messages and ≤ 32 radio events per
  pass. When it stops on the budget, more may be queued (`Radio` has no peek). An empty `take()`
  means the queue is empty, and the callbacks' `wakeLoop()` covers anything that arrives later.
- **`nextDueMs(now)`** returns **0** when any of these holds:
  - the last `service()` stopped on its radio budget;
  - a link has a sendable frame (not paced and not blocked);
  - a page scan can step (light gate open, outbox room);
  - a held PULL can go out;
  - `flushWanted` or the size trigger, with the flash gate open;
  - `db.maintenanceDue(now)`.

  Otherwise it returns the scheduler's next due, the pacing deadline (40 ms) or `txBlockedUntil`.
  **Work that waits for a closed gate never yields 0**: the engine's own deadline (a job's end)
  wakes `loop()`.

### 5.13 Tests (part node)

1. **`test_hub_replay.cc`: the transcript replay** (the P2 gate). It ports `gen_vectors.Sim` and the
   phone `Node` (kinds 2 and 3) to C++ in `test/host/hub_sim.h`, like Kotlin's `TranscriptDriver`
   + `StandInRoles`:
   - **Stand-in phones**: P1 `Ledger` (sync_ledger.h), `PeerTable`, `Session`, the routing
     functions, `EvtDedupe`, `replayPlan`; the phones' save debounce (300 ms) and immediate save on
     commit. Battery and state come from each node's first hops-0 HB in the transcript.
   - **Scripted nodes**: X, Y, Z send the transcript's raw messages.
   - **H** is a real `HubNode` with:
     - `FakeHubDb` seeded from `nodes.H` (ledger `s/b/f`, `durableHigh`, `nextSyncSeq`, peers,
       dbId, group);
     - `TranscriptClock` (`clockKnown`, then `clockBaseMs + t` after the first `observe`);
     - a scripted `Rng` (the transcript's nonces for `(link, gen, H)`, and the `sync_reset` dbId);
     - `SelfInfo` from H's first HB, with `uptimeS = 1000 + t / 1000`;
     - the simulation's event queue as `Scheduler`;
     - a sim-link `Radio`: frames emitted by H are checked against the step's `frames` and
       delivered at +15 ms; a disconnect lands at +16 ms.
   - **Stimuli** come from the transcript's scenario steps (`link_up`, scenario `link_down`, `local`
     ops, `script` messages), pushed first so they win ties as in Kotlin. After every event the
     harness calls `H.service(t)` until `nextDueMs(t) > 0`.
   - **Assert**: the produced step list equals the transcript's, notes excluded: every `msg`
     (from, to, type, **hex**, **frames**), `state`, `apply`, `durable`, `group`, `foreign`,
     `disconnect`, `timer`, `ingest`, `gap`, `local` step, in order. Then the `final` nodes: H's
     dbId, groupId, durableHigh, nextSyncSeq (`lastSeq + 1`), ledger (from a dirty-inclusive feed)
     and peers.
   - All six transcripts. `event_catchup` has no H, but it proves the C++ stand-ins.
   - A `--real-db` switch (used at integration) seeds `HubDbImpl` + `MemStorage` + `MemKv` through
     `hubDbSeed()` and must pass identically.
2. **Loopback** (the same simulation, randomised, many seeds). Random MTU 23..247, latency 5–80 ms,
   1 % frame drops (counted BAD_FRAME, recovered by page re-pulls), link up / down, hub reboot from
   `MemStorage` (FakeHubDb then real DB at integration), `sync_reset`, a stranger in another group, a
   third connection, a duplicate deviceId, MTU 23 pages, route-2 events through the hub, the
   triangle, the hub full (small cap), the outbox full (EVT drops), RX overflow, timed jobs on a
   scripted `TxGate`. Invariants:
   - the ledgers converge (key → u, o, c, b);
   - no live REC or EVT goes to its sender or origin;
   - each version crosses each directed link live at most once;
   - no message of any kind reaches the stranger;
   - every `PAGE_END.scannedTo` ≤ the hub's durableHigh at begin;
   - a peer's wm into the hub ≤ the hub's durableHigh;
   - EVTs reach I exactly once after dedupe whenever a path existed;
   - during a timed job: no page RECs, no flash work, ≤ 1 frame per link per 40 ms, no index merge.
3. **Unit tests**:
   - `Outbox`: FIFO vs priority, fragmentation at MTU 23 / 185 / 247 against P1 frames, overflow
     rules, pacing, `sendFrame` false → 20 ms retry;
   - `TaskTable`: order, replacement, capacity;
   - `HubWallClock`: median, skew hysteresis;
   - `Roster`: replace rule, paths, LOST;
   - `buildHb` bytes;
   - the page exhaustion rule (a superseded tail with a dirty replacement → `more = 0`);
   - the held PULL;
   - the slot policy; `syncReset` membership; `leaveGroup`;
   - DB_FAILED → no sessions;
   - `nextDueMs`: never 0 with only gated work pending.
4. **`hub_node_smoke11.cc`**: every node header under gnu++11 `-Werror -fno-rtti`.

---

## 6. `FakeHubDb` (part node; test/host)

A sorted map `key → {body, seq, syncFrom, version, cls}` with `lastSeq`, `durableHigh`, and the
peer table (8, LRU), group, full flags and counters.
- `accept` = P1 `applyCheck` + `seq = lastSeq + 1`.
- `flush` → `durableHigh = lastSeq`.
- The feed iterates current entries in seq order within `(since, limit]`, a budget of 32 entries
  per call.
- `reserveLive` / `canTakePage` → true unless a test scripts otherwise.
- `requestReset` applies at once.
- `maintain` / `maintenanceDue` → false.

An optional `cap` gives FULL. It must satisfy every row of §4.10 that a test relies on.

---

## 7. Interface rules across the seam

- The node calls `HubDb` only through `hub_ports.h`, and only from `loop()`.
- `DbEntry` and `received()` pointers die at the next call on the same object: copy what you keep.
- `PeerState*` from `peerFind`/`peerGet` is used within one Session input only.
- The node never calls `flush(force = true)` except from `flushNow()`.
- New HubTask kinds, new trace events and new `HubStatus` fields need an orchestrator change to
  `hub_ports.h`; do not overload existing fields.

---

## 8. Integration (one agent, after both parts)

### 8.1 `hub_nimble.h`

- `hubNimbleSetup(NimBLEService* svc)`, before `svc->start()`: creates SYNC `A7830006` with
  `WRITE | WRITE_NR | NOTIFY` (NimBLE 1.4.3 adds the 0x2902 CCCD itself) and sets
  `SyncChrCallbacks`.
- **Callbacks (host task) only enqueue and wake**:
  - `onWrite(chr, desc)` → `[kind FRAME][conn][0][len][bytes]`;
  - `onSubscribe(chr, desc, sub)` → `SUBSCRIBE` with value `sub & 1`;
  - `onStatus(chr, s, code)` → `wakeLoop()` only (1.4.3 gives no conn; the node's 20 ms retry
    covers it);
  - in the sketch's `ServerCallbacks`: `onConnect` → `CONNECT` (value 23, or the conn's MTU from
    `ble_att_mtu(conn)`); `onDisconnect` → `DISCONNECT` (1.4.3 passes no reason: value 0); a new
    `onMTUChange(mtu, desc)` → `MTU`.
  - Each record goes into one 4 KB FreeRTOS **MessageBuffer** with `xMessageBufferSend(…, 0)`.
    Only the host task writes and only `loop()` reads, so no lock is needed. When the send returns
    0, set the per-conn overflow bit (an atomic bitmask on `conn & 31`); `take()` reports
    `RX_OVERFLOW` first.
  - No flash, no advertising, no notify, no malloc in any callback. `onConnect` keeps its
    `updateConnParams(…, 24, 40, 2, 400)`.
- **`NimbleRadio::sendFrame`**:
  ```cpp
  os_mbuf* om = ble_hs_mbuf_from_flat(frame, len);
  if (om == NULL) return false;            // never pass NULL: NimBLE would send the stored value
  return ble_gattc_notify_custom(conn, gSyncChr->getHandle(), om) == 0;  // om consumed either way
  ```
  `BLE_GAP_EVENT_NOTIFY_TX` reaches `onStatus` for `notify_custom` too: `NimBLEServer.cpp` looks
  the characteristic up by `attr_handle` in `m_notifyChrVec` (checked in the 1.4.3 source).
- `disconnect(conn, reason)` → `gServer->disconnect(conn, reason)`.

### 8.2 Sketch wiring (`esp32-transmitter.ino`)

**Ports**:
- `SketchGate` = `gEngine.timedJob()`, `gEngine.msUntilDue(now)`,
  `uxQueueMessagesWaiting(gCmdQueue) == 0`, `otaBusy()`.
- `SketchSelf`:
  - Heltec: mv = `powerBatteryMv()`; pct = `mv < 0 ? -1 : powerBatteryPct()`;
    charging = `mv < 0 ? -1 : (powerCharging() || powerOnUsb())`; runtime = `powerRuntimeMin()`.
  - Classic: all −1.
  - state = program bits (KEEP_AWAKE bit1, TX_LOOP bit2, WAND_LOOP bit3) | `powerBatteryLow()`
    bit5 | `gEngine.timedJob()` bit6.
  - uptimeS = `esp_timer_get_time() / 1e6`.
- `EspRng` = `esp_random()`.
- `HubWallClock`, `TaskTable`, `NimbleRadio`, `LittleFsStorage`, `NvsKv`, `HubDbImpl gDb`,
  `HubNode gHub`: all static.

**`setup()`**:
1. 1.5 order unchanged up to `gCmdQueue`.
2. `hubFsMount(&fsTotal)`. This may format on the first boot after the upgrade.
3. `NimBLEDevice::init` … (unchanged); `hubNimbleSetup(svc)` before `svc->start()`.
4. Allocate in this order: RX MessageBuffer 4 KB, dirty (4 KB classic / 8 KB S3), checkpoints 2 KB,
   I/O 4.6 KB.
5. Allocate the index: `cap = hubIndexCap(heap_caps_get_largest_free_block(MALLOC_CAP_8BIT),
   MM_HELTEC_V3 ? HUB_CAP_MAX_S3 : HUB_CAP_MAX_CLASSIC)`, then `heap_caps_malloc(cap × 12)`. On
   failure halve, down to 1,024; then DB_FAILED.
6. `gDb.begin(cfg, now)`.
7. deviceId = `hubDeviceId(NimBLEDevice::getAddress().getNative(), true)`; bootId =
   `esp_random()`; then `gHub.begin({deviceId, bootId, MM_FW_VERSION " heltec-v3" | " esp32",
   "MM_ESP", PRODUCTION}, ports, now)`.

**`loop()`** (spec §4.11, adapted to 1.5):
1. `otaLoop()`; `offService()` (unchanged).
2. Disconnect/connect tracking: `gIdleSince` also resets when `gLinked` changes.
3. Commands, as 1.5, plus `RELAY_CMD_SYNC_RESET` → `gHub.syncReset(cmd.conn, now)`. Then
   `gEngine.service()` and `restartService()`. **Always first.**
4. The LED flash note, then `advManage(now, gLinked)` (§8.3).
5. **`gHub.service(millis())`**: sync work within its budgets.
6. `ledService`; screen and power (1.5) with the sync fields; the leave-group and power-off requests.
7. `publishSnapshot()`, plus the sync shadow: `gHub.status()` copied under `gSnapMux`, with
   `heapFree = ESP.getFreeHeap()` and `heapMin = ESP.getMinFreeHeap()`, and the member conns.
8. Self-change check: compare `{pct, charging, state bits 1–5}` with the last pass →
   `gHub.selfChanged()`.
9. Sleep: `waitMs = min(…, gHub.nextDueMs(after))`. The callbacks' `wakeLoop()` covers frames and
   events.

**Flush hooks (user rule: keep every 1.5 power feature)**: call `gHub.flushNow(millis())`
- in `offService()` right before `powerFlushSaves()` / `mmDeepSleepForever()` (power-off and
  cutoff);
- in `restartNow()` before `esp_restart()` (RADIO SLEEP, the modem-sleep guard);
- before the OTA reboot, through a new hook in `ota.h`: `static void (*gOtaBeforeRestart)() =
  nullptr;`, called right before `ESP.restart()` in `otaLoop()`.

### 8.3 Advertising (spec §4.9 on 1.5's `advManage`)

- `AdvState` gains `bool connFilter`; `advSame` compares it (beacon).
- `advApplyNow` calls `gAdv->setScanFilter(false, want.connFilter)` for the beacon and
  `setScanFilter(false, false)` for every other kind, with an empty white list.

| conns (`gLinked`) | Job / stream on air | Advert |
|---|---|---|
| any | yes | **BEACON** ADV_IND 20–30 ms (unchanged). `connFilter = conns ≥ 2 \|\| gEngine.timedJob()`. `scanResp` (name + UUID) `= conns < 2` (was `linked == 0`) |
| 0 | no | **IDLE** (1.5 layout: flags + UUID; scan response = name + heartbeat), 200–400 ms for 30 s after a change, then 546–760 ms |
| 1 | no | **IDLE** (connectable, so the second phone can join), 200–400 ms for 30 s after a change, then 1–2 s (`HEARTBEAT_ADV_MIN/MAX`) |
| ≥ 2 | no | **HEARTBEAT** (1.5: name + heartbeat, non-connectable, 1–2 s) |
| 3 | — | `NimBLEAdvertising::start()` refuses; `advManage` retries each pass; the node drops the newest non-member at once |

"A change" = boot, or `gLinked` going up or down. `heartbeatBytes()` sets flag bit4
(`HUB_ADV_FLAG_SYNC`) unless `gDb.state() == DB_FAILED`. No advertising call from callbacks;
`advertiseOnDisconnect(false)` stays.

### 8.4 HB battery and clock (spec §4.13)

There is no `batteryPoll` change (D-P2-14); `SketchSelf` reads the cached power.h values. The hub
clock is `HubWallClock` (§5.9). HB `ts` is 0 until it is known.

### 8.5 Commands (`relay_proto.h`, spec §4.14, §7.1)

- Actions `{"sync_status", RELAY_ACT_SYNC_STATUS}` and `{"sync_reset", RELAY_ACT_SYNC_RESET}`.
  Neither collides with `sync_begin` / `sync_chunk`, which stay catalog aliases.
- `ChipCmd` gains `uint16_t conn`. The CMD callback switches to the
  `onWrite(chr, ble_gap_conn_desc* desc)` overload to know it.
- **`sync_status`**: the callback stores `gSyncStatusConn = conn` and
  `gSyncStatusUntil = millis() + 3000` under `gSnapMux` and replies ok. A STATUS read
  (`onRead(c, desc)`) from that conn before the deadline formats
  `relayFormatSyncStatus(gSyncSnap, …)` instead of `relayFormatStatus`, once.
- **`sync_reset`**: the callback checks `conn` against the published member conns (shadow): not a
  member → `{"ok":false,"error":"not a member"}`. Otherwise it queues `RELAY_CMD_SYNC_RESET` with
  conn; `loop()` calls `gHub.syncReset`. The board goes `DB_RESETTING`, and the sessions close after
  750 ms.
- **`relayFormatSyncStatus(const mmsync::HubStatus&, char* out, size_t cap)`** (`relay_proto.h`
  includes `hub_ports.h`), ≤ `RELAY_STATUS_LIMIT` 508 B:
  ```json
  {"ok":true,"sync":{"rec":1234,"cap":3900,"tomb":12,"full":0,"logKB":96,"fsKB":[180,1408],
   "live":[96,436],"db":"a1b2c3d4","seq":5678,"dur":5670,"grp":"9f3e","rdy":1,
   "heap":[123456,98765],"ph":[{"k":"i","id":"9f3e","s":3,"mtu":185,"wm":5600,"ago":12,"b":81},
                             {"k":"a","id":"07c1","s":3,"mtu":247,"wm":5590,"ago":3,"b":54}]}}
  ```
  - `db` = the first 4 bytes of the dbId as lowercase hex; `grp` / `id` = the last 2 bytes.
  - `s` as in §5.11 (offline rows: `"s":-1` and no `mtu`/`wm`).
  - `b` = battPct (−1 omitted); `ago` = agoS (omitted when none).
  - `ph` rows are dropped from the end until the object fits; `live` (P2 addition) is dropped first.
- **Host tests in `test_relay.cc`**: parsing both actions and the aliases unchanged; `ChipCmd.conn`;
  the formatter with 0 / 2 / 4 rows, worst-case values, always ≤ 508 B and valid JSON (json_mini);
  `heartbeatBytes`' flag logic if it is extracted pure.

### 8.6 Screen (`oled_pages.h`, `oled_ui.h`; spec §7.2 on 1.5's pages)

- `ScreenPage` becomes `PAGE_STATUS, PAGE_DEVICES, PAGE_PACKET, PAGE_DEVICE, PAGE_CUTOFF,
  PAGE_POWER` (6 dots; the titles still fit).
- **STATUS**: line 3 = `PKT  12 SENT 2M AGO`. Drop ` AGO` past 17 columns; `0 SENT` before the
  first send; the kind stays on LAST PACKET. Line 4 = `SYN  …`, first match wins:
  `LOADING` (not ready), `FS ERROR` (DB_FAILED), `NO GROUP`, `NO PHONES` (no member),
  `<n>PH FULL`, `<n>PH MTU23`, `<n>PH <rec> REC` (e.g. `SYN  2PH 1234 REC`).
- **DEVICES** (labels in columns 0–3, values from column 4, 17 characters):
  ```
  IPH  81% CHG    12S       pct, CHG when charging, age right-aligned ("--" none, LOST > 10 min)
       ~5H DIRECT           runtime in hours only ("~45M" under 1 h, "~99H+"), path DIRECT / VIA AND / DIRECT+VIA
  AND  54%        40S
       ~3H VIA IPH
  REC  1234/3900            + " FULL" when full
  FS   12% GRP 9F3E         fs used %, last 4 hex digits of groupId ("GRP --" ungrouped)
  ```
  The IPH row is the most recent kind-3 row and the AND row the most recent kind-2 row of
  `HubStatus.phones`.
- `ScreenInputs` / `ScreenModel` gain `synState, synPhones, synFull, synMtu23, synRecords, synCap,
  synFsPct, synGroup4[5]`, `phones[2]{present, kind, pct, charging, runtimeMin, ageS, path,
  viaKind}` and `groupHoldPermille`, filled in `loop()` only.
- **Leave group**:
  - A PRG hold on a lit DEVICES page works like POWER: a tap (< 400 ms) goes to the next page; held
    5 s with the hub grouped → `screenTakeLeaveGroupRequest()` → `gHub.leaveGroup()`. While it is
    held, line 5 shows `HOLD: LEAVE GROUP` inverted with the bar.
  - Classic (no screen): `loop()` tracks GPIO0 LOW since its first observation (the OTA FALLING
    interrupt wakes it), adds `since + 5000` to the sleep, and at 5 s still LOW → `leaveGroup()`
    once per press. No LED feedback (LED rules).
- The pure string builders (`scrSynLine`, `scrDevicesLines`) are host-tested in `test_relay.cc` or a
  new `test_screen.cc`.

### 8.7 Capability signal and the Android change (D-P2-11)

- **Bytes** (manufacturer data, company `FF FF`):
  `FF FF 4D 42 01 <pct | FF> <flags> <runtime u16 LE | FF FF>`.
  - flags: bit0 charging, bit1 USB, bit2 battery reading present, bit3 low battery, **bit4 SYNC hub
    (firmware ≥ 2.0, storage OK)**, bits 5–7 = 0.
  - Classic 2.0: `FF FF 4D 42 01 FF 10 FF FF`. Heltec at 68 %, 300 min:
    `FF FF 4D 42 01 44 14 2C 01`.
  - flags ≤ 0x1F can never form the wand marker `CF 0B` / `CF 9B`.
  - The heartbeat is in the IDLE scan response (≤ 1 phone linked) and in the HEARTBEAT advert
    (≥ 2).
- **Android** (Gradle one at a time):
  - `ble/Esp32Heartbeat.kt`: `val syncHub: Boolean = false` ← `flags and 0x10 != 0`, plus a KDoc
    line.
  - `ble/BleScanner.reportRelayAdvert`: parse the heartbeat from the same `ScanRecord` and pass
    `sync: Boolean?` (null = no heartbeat in this record, e.g. a beacon scan response) to
    `onRelayAdvert(address, name, rssi, sync)`. Call sites follow: `MagicMakerForegroundService`,
    `SyncEngine.hubSeen`, `HubClient.hubSeen`.
  - `sync/HubLinkMachine.hubSeen(address, name, rssi, now, sync: Boolean?)`:
    - `true` → remember `capable[a] = true`;
    - `false` → `noSync[a] = now` (status `NO SYNC FW` **without probing**);
    - `null` → no change.
    - Unknown candidates need `capable[a] == true`; the known `identity.hubAddress` (once AUTHED)
      is exempt. The 30-minute no-probe rule stays for a board that answers without SYNC anyway.
  - Tests: `Esp32HeartbeatTest` (bit4 parse; version 1 kept; bits 0–3 unchanged);
    `HubLinkMachineTest` (no Connect to a 1.x board, `NO SYNC FW` shown; Connect on `sync = true`;
    null keeps the previous state; the known hub still autoConnects).
  - Run `./gradlew -q :app:compileDebugKotlin`, then `--tests 'com.magicmaker.android.sync.*'` and
    the `Esp32Heartbeat` test.
- **iPhone** (P4): it reads STATUS, not the heartbeat. P4 may use bit4 from CoreBluetooth
  `advertisementData` to skip probing. Nothing to change now.

### 8.8 Versions and parser compatibility

- `board.h`: `MM_FW_VERSION "2.0"`; `MM_RELAY_PROTO 4` with the comment "4: SYNC characteristic
  A7830006, sync_status / sync_reset, heartbeat flags bit4".
- Checked:
  - iOS gates power features on `proto >= Esp32PowerCopy.minProto` (3), so 4 passes.
  - iOS `FirmwareVersion.compare` is numeric, so "2.0" > "1.5" and the update is offered.
  - `tools/firmware_manifest.py` `MARKER` accepts `MMFW:2.0:<board>`.
  - Android parses neither `proto` nor `fw` of the ESP32's STATUS.
  - The Watch only displays the string.
  - The heartbeat version byte stays 1 (Android accepts `version ≥ 1`).
  - Downgrading to 1.5 leaves the library on flash untouched; upgrading again finds it (NVS `db`
    matches the HEADER).

### 8.9 CI

- **`esp32-firmware.yml`**:
  - Path triggers: add `"tools/sync/**"`; `**.h` already covers the new headers.
  - Replace the step "Relay protocol host test" (`make … relay`) with "Host tests":
    `sudo sysctl -w vm.mmap_rnd_bits=28` (as `sync-vectors.yml` does, for ASan), then
    `make -C firmware/esp32-transmitter/test/host test`.
  - New step **"Check image sizes vs the stock app slot"**, after both compiles: fail if any
    `build-*/*.ino.bin` > `0x130000` (1,245,184 B); print each size against its slot (classic
    `0x140000`, Heltec `0x330000`).
  - New step **"Check the partition tables (LittleFS on spiffs)"**: decode
    `build-esp32/*.partitions.bin` and `build-heltec-v3/*.partitions.bin` with the core's
    `gen_esp32part.py` (found under `~/.arduino15/packages/esp32/hardware/esp32/2.0.17/tools/`).
    Assert `spiffs,data,spiffs,0x290000,0x160000` and `app0 … 0x140000` (classic), and
    `spiffs … 0x670000,0x180000` and `app0 … 0x330000` (Heltec).
  - Windows flasher README text: "the sync library survives flashing with flash.bat; the web flasher
    and Erase All wipe it and the phones refill it."
- **`sync-vectors.yml`** paths (both triggers): add `"firmware/esp32-transmitter/hub_*"`,
  `"firmware/esp32-transmitter/storage_*"` and `"firmware/esp32-transmitter/kv_*"`.

### 8.10 README (`firmware/esp32-transmitter/README.md`)

- **What it does**: the sync hub (two phones, library, relays), and that it never scans.
- **Updating**: the library survives `flash.sh/.ps1/.bat` and OTA; the **web flasher erases** the
  board, and so does Arduino IDE "Erase All Flash" (the phones refill it); downgrading to 1.5 keeps
  it.
- **Heltec**: the page list with DEVICES, the STATUS `SYN` line, and hold PRG 5 s on DEVICES =
  leave group. **Classic**: BOOT held 5 s.
- **Use it with the app**: sync needs a grouped phone (the iPhone app with sync, P4); before that
  the hub shows `SYN NO GROUP` and transmits as before.
- **Power**: §10 numbers.
- **Protocol reference**: SYNC `A7830006`, `sync_status` / `sync_reset`, heartbeat bit4,
  `proto` 4, NVS `mmsync`, the LittleFS files.

### 8.11 Integration test steps

1. `make test` green: P1, `test_relay` additions, db tests, node tests, the replay with **both**
   `FakeHubDb` and `--real-db`, and the loopback with the real DB.
2. PlatformIO: `heltec_v3` and `esp32dev` build; the strict build shows zero sketch warnings; the
   image sizes are recorded (expected ≈ 0.70–0.75 MB).
3. Android: `compileDebugKotlin` and the sync / heartbeat tests green.
4. Hardware (§11) rows recorded in the hand-off.

### 8.12 Docs

Add to SYNC_PROTOCOL.md §15.2 a note and to §19 item 28: "A server whose feed holds superseded
entries MAY report `scannedTo = durableHigh` when its scan reached durableHigh without stopping"
(D-P2-3). The orchestrator decides whether Android adopts it too (open question 2).

---

## 9. Parallel split, step 0, order

### 9.1 Step 0 (orchestrator, before the parts start)

- `hub_ports.h`: in place (this hand-off).
- `test/host/Makefile`: hooks so each part owns a fragment and nobody edits the Makefile in
  parallel. Add before `.PHONY`:
  ```make
  HUB_BINS :=
  HUB_RUNS :=
  -include $(HERE)hub_db.mk
  -include $(HERE)hub_node.mk
  ```
  Make `all` depend on `$(HUB_BINS)`, and add the line `$(foreach r,$(HUB_RUNS),$(r) &&) true` to
  the end of the `test` recipe. Each fragment appends its binaries to `HUB_BINS` and their run
  commands (with `$(SYNC_DIR)` where needed) to `HUB_RUNS`, using `CXXFLAGS_17` / `CXXFLAGS_11`.

### 9.2 File ownership (disjoint)

| Part | Files |
|---|---|
| db | `hub_db.h`, `storage_posix.h`, `storage_littlefs.h`, `kv_nvs.h`; `test/host/storage_mem.h`, `kv_mem.h`, `hub_db_seed.h`, `test_hub_db.cc`, `hub_db_smoke11.cc`, `hub_db.mk` |
| node | `hub_node.h`, `hub_outbox.h`, `hub_roster.h`, `hub_clock.h`, `hub_tasks.h`; `test/host/fake_hub_db.h`, `hub_sim.h`, `test_hub_node.cc`, `test_hub_replay.cc`, `hub_node_smoke11.cc`, `hub_node.mk` |
| integration | `hub_nimble.h`, `esp32-transmitter.ino`, `board.h`, `relay_proto.h`, `oled_pages.h`, `oled_ui.h`, `ota.h`, `README.md`, `test/host/test_relay.cc`, `Makefile` (merge the fragments if wanted), `.github/workflows/esp32-firmware.yml`, `sync-vectors.yml`; Android `ble/Esp32Heartbeat.kt`, `ble/BleScanner.kt`, `sync/HubLinkMachine.kt`, `sync/HubClient.kt`, `sync/SyncEngine.kt`, `service/MagicMakerForegroundService.kt` (the call site only) and their tests; `docs/SYNC_PROTOCOL.md` (§8.12) |
| nobody | `sync_*.h`, `hub_ports.h`, `tools/sync/**`, `ios/`, `web/` |

### 9.3 Order

1. Step 0.
2. Parts db and node in parallel. Each finishes with its own tests green and its gnu++11 smoke
   compile. db also compiles its Arduino back-ends in its own scratch PlatformIO project, one build
   at a time.
3. Integration: wiring, the real-DB replay, PlatformIO, Android, CI, README, docs.

### 9.4 Acceptance (P2 done)

- [ ] `make -C firmware/esp32-transmitter/test/host test` green under ASan / UBSan. It includes the
      replay of all six transcripts, byte for byte (hub `msg` hex and frames, `state`, `apply`,
      `durable`, `group`, `foreign`, `disconnect`, `timer` steps, the final state), with `FakeHubDb`
      **and** the real `HubDbImpl`.
- [ ] Loopback invariants hold for ≥ 200 seeds; the db crash fuzz passes; zero gate violations.
- [ ] Both PlatformIO envs build; the strict build shows zero sketch warnings; both `*.ino.bin` ≤
      `0x130000`; CI has the size and partition-table steps and runs the full `make test`.
- [ ] Every 1.5 feature still works (power-off, cutoff, modem sleep + guard, RADIO SLEEP, OTA,
      LED, screen-on-PRG-only); the advert name is `MM_ESP`; heartbeat bit4 is set.
- [ ] Android compiles; heartbeat and HubLinkMachine tests are green; no probe of 1.x boards.
- [ ] The hardware rows of §11 are recorded.

---

## 10. Flash and power budget

**Flash writes per day** (estimates; a typical day = 2 phones, ~30 renames, ~300 new learns, ~10
relinks):

| Source | Count / day | Erases / day | Wear |
|---|---|---|---|
| LittleFS flushes (one per 2 s burst of accepts; 1 block copy + a metadata commit) | 50–200 | 50–200 + ~10 metadata compactions | over 352 / 384 blocks with `block_cycles` 512: < 1 erase per block per day → centuries at 100 k cycles |
| Compaction (log > max(128 KB, 2 × live); ~20 KB log growth a day) | one every ~5 days | ≈ live / 4 KB ≈ 25–110 per compaction → ≤ 20 a day amortised | negligible |
| NVS `peers` (≤ once per minute per peer, only when the value changed) | typically 10–50; worst case 2,880 | NVS page GC: worst ~46 erases a day per page over 4 pages → ≥ 6 years even in the impossible worst case | fine |
| NVS `live` (one u32 per live-forwarded record) | ≈ live edits + learns forwarded (~50–330) | ~1–3 page erases a day | fine |
| NVS `grp`, `full`, `db` | rare | — | — |

**Current** (POWER_V3 model; baseline ~38 mA running, Heltec):

| State | 1.5 | 2.0 | Extra |
|---|---|---|---|
| No phone linked, idle | idle advert | same advert (bit4 only) | ≈ 0 |
| One phone linked, idle | non-connectable heartbeat 1–2 s | connectable IDLE 1–2 s (listens briefly after each advert), HB 1 per minute | ≈ +0.01–0.05 mA |
| Two phones linked | not possible in 1.5 | second link at 30–50 ms / latency 2 + heartbeat advert | **≈ +0.4–0.8 mA** (POWER_V3's "+0.4–0.8 mA linked") |
| Sync traffic (pages, HBs, flushes) | — | flushes ~0.1 s × 25 mA × 200 / day; HB frames | < 0.02 mA averaged |
| CPU wakes | — | HB timers 1 per minute per member, flush timers | < 0.01 mA |

Runtime on 400 mAh to the 3.30 V cutoff (360 mAh): about 9.4 h → about 9.2 h with two phones
linked (no modem sleep), and about 10.7 h → about 10.5 h with it. Nothing changes for keep-awake or
bursts. The battery model's "linked" term (battery_model.h) counts one link; counting the second is
optional (open question 4).

---

## 11. Hardware checks (manual, at integration; results go in the hand-off)

| Check | Pass |
|---|---|
| First boot after OTA from 1.5 (LittleFS format) | boots; time to advertising recorded; transmit works right after |
| `sync_status` at boot (both boards) | `cap`, `heap`, `fsKB` recorded; classic cap ≥ 3,000 hoped |
| Timing with 2 phones and a 200 KB first sync running | wake / command phases within ±20 ms; no burst cut; a command sent during a flush starts within 200 ms |
| Beacon connect filter (classic and S3) | no connection lands during a timed job; a pending connect waits until it ends |
| Keep-awake + one phone away and back | relinks on the connectable beacon in ≤ 10 s |
| Third phone | dropped at once; beacons unaffected |
| Power-off / cutoff / RADIO SLEEP restart / OTA during sync | `flushNow` runs; after the reboot no new dbId (`bootFlags` 0) |
| Pull the battery mid-sync | reboot recovers (torn tail at most); the phones resync |
| 24 h soak | heap min stable; FS < 20 %; no resets; flush and compaction counters recorded |
| Current with 0 / 1 / 2 phones against 1.5 | within §10 |

End-to-end sync on hardware needs a grouped phone: P4, or open question 1.

---

## 12. Risks and open questions

**Risks**

- **Classic RAM**: if the largest free block after NimBLE is well under 100 KB, the cap drops toward
  1,024 records. Mitigations: the cap is measured and reported; dirty and outbox can shrink;
  eviction keeps named records.
- **First-boot format time**: esp_littlefs may erase the whole partition (seconds, once). It runs
  before NimBLE, so no link is affected, but the board advertises later on that one boot.
- **Flash stalls**: each flush or compaction step stalls `loop()` and the NimBLE host task (cache
  off) for 20–150 ms. The gate keeps them out of bursts and away from commands; one command can
  wait up to ~150 ms (inside the matrix's 200 ms).
- **No hardware end-to-end sync before P4**: Android and the hub both start ungrouped, which means
  NOGROUP and transmit only. P2 is proven by the replay and loopback tests (as P3 was).
- **Old SYNC-less apps lose a grouped hub after 10 s** (spec §3.6 by design). It only bites once a
  grouped phone has grouped the hub.
- **Superseded-tail re-pulls on Android** (the D-P2-3 situation exists on phones too: up to its
  300 ms save debounce). Harmless but wasteful.
- **NimBLE 1.4.3 gives no conn in `onStatus` and no reason in `onDisconnect`**: covered by the
  20 ms TX retry and by status that does not need the reason.
- **FakeHubDb vs HubDbImpl divergence**: caught by the `--real-db` replay and loopback at
  integration.
- **The web flasher and "Erase All" wipe the library** (documented; the phones refill it). A crash
  with unflushed live-forwarded records (brownout) makes a new dbId and a full resync (bounded by
  the library size).
- **30-bit seqs in the index**: 10^9 seqs. At 10 k seqs a day that is 290 years. On reaching it,
  the DB takes a new dbId and compacts (never in practice).

**Open questions** (P2 proceeds with the defaults)

1. Add a hidden Android Diag action "create sync group" so P2 + P3 can be tested end to end on
   hardware before P4? Default: no; test in P4.
2. Adopt D-P2-3 (`scannedTo = durableHigh` on an exhausted scan) in SYNC_PROTOCOL.md for all nodes,
   and in Android? Default: document it as a MAY for the hub only.
3. Keep old SYNC-less apps connected (transmit only) on a grouped hub instead of the spec's 10 s
   drop? Default: the spec.
4. Count the second link's draw in `battery_model.h` (runtime estimate)? Default: no change in P2.
5. P4: use heartbeat bit4 on the iPhone to skip probing 1.x boards.
