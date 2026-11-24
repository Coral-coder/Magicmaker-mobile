# MagicMaker sync hub — implementation spec

> **Amendments (2026-11-24, after this spec was written — these override the body):**
>
> **A1 — OTA keeps the stock partition tables (supersedes D13 and the partitions section).** The user asked for
> firmware OTA through the app after this spec was written; firmware 1.2 (ota.h, characteristic A7830007) is already
> on the user's board with the stock layout. An OTA update can never change a board's partition table, so the hub
> must NOT ship a custom `partitions.csv`. Keep Arduino's `default.csv` on the classic ESP32 (nvs, otadata,
> app0/app1 1.25 MB each, `spiffs` 1.375 MB, coredump) and `default_8MB.csv` on the Heltec V3, and mount LittleFS on
> the existing `spiffs` data partition (`LittleFS.begin(true, "/littlefs", 10, "spiffs")`). Re-derive the hub
> capacity from ~1.375 MB of LittleFS (classic) and the Heltec's data partition; everything else about storage,
> wear and caps stays as specified. The app image must stay well under 1.25 MB (today ~0.58 MB).
>
> **A2 — Open questions answered with the spec's defaults** (user: "figure it out"): keep-awake is not migrated
> when the ESP32 dies (notify; TX/wand loops migrate after 90 s); deleted means deleted (tombstones, re-save as a
> preset to restore); auto rules stay per-phone in v1; group join is trust-on-first-use with no pairing step; the
> iPhone's name wins at first sync (no review list in v1); iOS Bluetooth state restoration stays off in v1 (the
> keep-running setting covers most of it); heard packets go Android -> iPhone directly when linked, via the hub only
> when the direct link is down.
>
> **A3 — Primary transmitter + heartbeats** are part of this spec (D8–D11) and unchanged.

# MagicMaker Sync Hub, Direct-BLE Fallback, Primary Transmitter and Heartbeats: Implementation Spec (v2, final)

Status: implementation spec. It replaces v1. Scope: `firmware/esp32-transmitter/`, `android/`, `ios/`, `tools/sync/`, `docs/`, CI.

Baseline: this spec builds on the parallel workflow's code that is now in the working tree:
- Firmware: `relay_engine.h` and `relay_proto.h`. `relay_engine.h` holds the job and program engine: `timedJob()`, `msUntilDue()`, and the RAM-only keep-awake / TX loop / wand loop programs that keep running after a disconnect.
- Firmware sketch: the loop()-owned advertising manager `advManage()`/`advApply()`. `loop()` sleeps on `ulTaskNotifyTake` and callbacks wake it with `wakeLoop()`. STATUS is capped at `RELAY_STATUS_LIMIT` = 508 B. `MM_RELAY_PROTO` is 2 and `MM_FW_VERSION` is "1.2". `oled_ui.h` holds `batteryPoll()`/`screenBatteryMv()`.
- iPhone: `sendEsp32Program`, `raw_burst`, chip-side loop routing, and the keep-running-in-background setting, which uses background location.

`relay_engine.h` is still untracked and changing. If a name used here changes before merge, keep the behaviour this spec describes and re-point the name.

## 0. Decisions

| # | Decision |
|---|---|
| D1 | **The ESP32 is the hub.** It stores the **library** (records and tombstones) in LittleFS. It relays live records, heard-packet events and heartbeats between the phones. It **never scans**. Transmit timing always comes first. |
| D2 | **Dual path, one protocol.** The same SYNC protocol runs phone↔hub and **iPhone↔Android directly**, over the Android relay GATT server that already exists. Every node serves a changes feed and pulls the feed of every peer it is linked to. Any link that is up therefore converges both of its ends. Discovery, connection, path choice and catch-up are automatic. |
| D3 | **Record key = (namespace, canonical packet bytes).** Packet bytes are 3..29 B (`RELAY_PACKET_MIN..MAX`). Device-local numeric ids are never sent. |
| D4 | **LWW per record.** Order by `(updatedAt, origin, bodyCrc)`; the larger wins and equal is a duplicate. A local edit is stamped `max(now, current.updatedAt + 1, lastLocalStamp + 1)`. A record with `updatedAt > now + 24 h` is rejected. |
| D5 | **Durable-only feeds.** A node serves pages, and reports `feedHigh`, only for entries already on its own disk. Live pushes may go out before durability but never advance a watermark. A crash can therefore never leave a peer's watermark ahead of the data, and no seq-ceiling machinery is needed. |
| D6 | **Each node keeps a ledger of verbatim record bodies.** Every node stores the winning canonical body as received; list rows are only a projection of it. Convergence therefore never depends on two platforms rebuilding identical bytes from their own row models. |
| D7 | **Auto-learned rows replicate as presence records** (version 1, origin 0, no label), which are byte-identical on every node. Only user actions create epoch-ms versions. |
| D8 | **Forwarding never guesses the topology.** A live record carries a `seenBy` set, and a node forwards a version once, on first accept, to linked peers not in `seenBy ∪ {sender, origin}`. A heartbeat is forwarded once (hops 0→1). For heard-packet events, Android picks one path: direct to the iPhone if that link is up, otherwise through the hub. The iPhone's heartbeat advertises its event watermark, so Android replays any gap. Pull-based anti-entropy heals everything else. |
| D9 | **The iPhone keeps both links up** (ESP32 and Android), one `RelayLink` each. The new setting **Primary transmitter: ESP32 / Android** decides where transmits go. `TransmitRouter` covers **every** transmit-producing action. On failure it sends through the backup link and shows a notice, and it returns to the primary automatically. |
| D10 | **Programs** (keep-awake, TX loop, wand loop) run on exactly one transmitter: the owner, which is the primary while the primary is alive. The iPhone never runs timer loops when the owner can run device-side programs. A program moves only when its owner is presumed dead. |
| D11 | **Heartbeats** go out every 60 s, plus on change (at least 5 s apart), on every link. The iPhone gets a DEVICES panel in both themes, Android gets a compact card, and the Heltec gets a DEVICES page. |
| D12 | **Sync group (trust on first use).** Devices sync only with peers that share a 16-byte group key, checked by an HMAC challenge inside HELLO. The first grouped device to meet an ungrouped one hands the key over automatically. A stranger's MagicMaker device never exchanges library data, events (which carry GPS positions) or heartbeats, and cannot hold a hub slot. |
| D13 | **One sketch-level `partitions.csv`** (4 MB layout, also used on the 8 MB Heltec): app 1.5 MB, LittleFS 2.375 MB, no OTA slot. Hub metadata (dbId, peer watermarks, group) lives in NVS. |
| D14 | **Binary TLV wire format**, normative in `docs/SYNC_PROTOCOL.md`. Shared test vectors and golden session transcripts in `tools/sync/` must pass in C++, Kotlin and Swift. |
| D15 | **Sync identity never leaves its device.** deviceId, dbId, issuedSeq, event epoch and group are kept outside backups and exports: Android `noBackupFilesDir`; iOS Application Support excluded from backup (group key in the Keychain). A restored, replaced or rolled-back store is detected and resynced. |

Glossary: **H** = ESP32 hub, **A** = Android, **I** = iPhone. **Link** = one BLE connection. **Session** = the SYNC state machine on a link. **Member** = a peer that passed the group check on a session. **Record** = one version of one key. **Feed** = a node's ledger ordered by local `seq`. **durableHigh** = the highest seq already on disk. **wm** = the highest feed seq of a peer that this node has durably applied.

### 0.1 What changed from v1, and why

1. **Event forwarding contradicted itself.** In v1, the generic rule `¬linked(Q, origin)` blocked the hub from relaying Android's events to the iPhone in the triangle topology, while the topology table assumed the hub did relay them. Events would have been lost. v2 routes events explicitly (3.9) and drops the `linked()` inference everywhere.
2. **Phone feeds could serve records not yet saved.** A crash then reused seqs below a peer's watermark, and the peer skipped those records forever. v2 serves durable entries only (D5) on all nodes, which removes the need for seqCeiling and meta files on the hub.
3. **Phones rebuilt bodies from rows.** Two rows for one hex, a missing `place`, or `PRESET` differences produced different CRCs for the same version, which could cause accept loops. v2 stores verbatim bodies in a ledger (D6).
4. **Rollback, restore and replacement were not detected.** Cases: Android auto-backup restore, Android device transfer, iOS backup restore, the user swapping `Documents/magicmaker_store.json` (Files access is on), and the auto-loaded `/sdcard` library. v2 adds an identity file outside backups with an issuedSeq check (D15), and imports the external file as a diff of local edits.
5. **Android writes `magicmaker_store.json` non-atomically** (truncate, then write). A crash mid-write leaves JSON that will not parse, and the next launch reseeds the presets. v2 makes the write atomic.
6. **The firmware baseline moved.**
   - `gPhase`/`TX_WAKE`/`delay(2)` no longer exist. v2 uses `gEngine.timedJob()`/`msUntilDue()`, the sleep-until-deadline `loop()` and `advManage()`.
   - STATUS has no room for a `sync` object (508 B cap), so a separate `sync_status` reply is used.
   - The battery is read only while the screen is lit, so v2 extends `batteryPoll`.
7. **Non-connectable beacons have a 100 ms minimum interval on the classic ESP32.** The landed firmware deliberately keeps ADV_IND. v2 keeps ADV_IND at 20–30 ms and blocks connections with a connect-whitelist filter policy whose white list is empty. The reconnect-window scheme is dropped, because the keep-awake beacon is already connectable with a scan response.
8. **NULL mbuf hazard.** If `ble_hs_mbuf_from_flat` returns NULL, passing NULL to `ble_gattc_notify_custom` sends the characteristic's stored value. v2 checks for NULL.
9. **Frame loss inside a message went undetected**, because the counter is the same for all frames of a message. v2 uses a 2-byte header with a per-direction frame sequence.
10. **Connection parameters.** v1's 60–100 ms / latency 4 would add up to about 350 ms of transmit latency, and its "bulk" 15 ms profile risked the radio schedule near bursts. v2 keeps the landed 30–50 ms / latency 2 and has no bulk profile.
11. **Sorted-index insert cost** is about 0.2–0.5 ms per memmove at 80 MHz, not 50 µs. v2 batch-merges inserts once per page.
12. **LittleFS appends** copy the partially filled last block on every sync. v2 flushes in larger batches, only when `msUntilDue ≥ 400 ms`, uses a single file handle and an atomic rename, and keeps peers and dbId in NVS.
13. **Transmit routing covered only the TX characteristic.** The iPhone actually transmits through CMD `transmit`, `vibrate`, `interrogate`, `raw_burst` and `mble_tap`, and the ESP32 firmware has supported `raw_burst` since 1.2. All are routed now, and timing settings are pushed to both transmitters.
14. **Loop ownership** ignored that ESP32 programs are RAM-only, and mixed iPhone-timer loops with device loops. v2 uses one owner, migrates on a presumed-dead signal that includes Android hearing the hub's beacon, and reconciles from heartbeat state bits.
15. **Event epoch.** Service-start seconds could repeat. v2 persists a monotonic epoch.
16. **Tombstone TTL** caused permanent divergence after garbage collection. v2 never expires tombstones on phones (capped at 5,000) and evicts them on the hub only under capacity pressure.
17. **Event learning on the iPhone echoed presence records back** to Android through pulls. v2 sets `syncFrom` = event origin.
18. **No group check.** In a public build, a stranger's app would sync libraries and GPS-stamped events and take hub slots. v2 adds the sync group (D12).
19. **PlatformIO version.** The locally installed platform is espressif32 6.9.0, with framework 3.20017.241212 = Arduino-ESP32 2.0.17.
20. **SYNCED state.** In v1 it waited for the peer to pull, which an old peer never does. v2 reaches SYNCED when the node's own pull completes.

---

## 1. Baseline inventory (checked against the tree)

### 1.1 Android library (`data/MagicStore.kt`, `core/MagicModels.kt`)

| Collection | Type | Id | Created by | Bound | Size |
|---|---|---|---|---|---|
| `presets` | `MagicPacket{id, hex, label, category, typeInfo, colors, simKey, userRecorded, rssi?, wandVerified}` | `Long` from `nextPacketId` (device-local) | 17 built-ins from `PresetCatalog` (re-merged by hex at launch); `saveCustomPreset` (`userRecorded=true`, replaces the same hex) | none | 17 + 0–50 |
| `learnedColors` | same | same | `addStarlightToLibrary` (keyed by canonical hex), `addColorToLibrary` (skips built-in duplicates by `libraryDedupeKey`) | none | 10–200 |
| `learnedLibrary` | same | same | `addShowAnimToLibrary`, `importCloudEntries` (`typeInfo="imported"`, label = dictionary function), `importHexesToLibrary` | none | 100–3,000 |
| `learnedRaw` | same | same | `hearRawPacket` (band noise excluded unless the address is tagged), `importHexesToLibrary` | `MAX_RAW_LIBRARY = 20000` | 1k–20k |
| `recordings` | `Recording{…}` | `Long` | every heard packet while recording | 500 in memory; not written to the library JSON | CSV logs unbounded |
| `autoRules` | `AutoResponseRule{…}` | `Long` | UI / relay command | none | < 20 |
| New-wand names | prefs `newwand_names` = JSON `{HEX: name}` | hex | UI | none | < 50 |

Persistence:
- Gson (`GsonBuilder().create()`) rewrites the whole state to `filesDir/magicmaker_store.json` and to `/sdcard/MagicMaker/magicmaker_library.json`.
- At launch the newer file **by mtime** wins (`readBestState`).
- `storeFile.writeText` is **not atomic**. If the JSON does not parse, `readBestState` returns null and `init` reseeds the built-in presets.
- The prefs snapshot (`settings`, `uiSettings`) is embedded in the library JSON.
- Backup rules (`backup_rules.xml`, `data_extraction_rules.xml`) exclude only `magicmaker_secrets.xml`.

Labels:
- `renamePacket(id)` and `recategorizePacket(id)` change only the first list holding that id.
- `applyLabLabelToMatchingRaw` relabels one raw row.
- **Re-hearing a packet reverts renames.** `addShowAnimToLibrary` copies `label = classified.label`, and `updateLearnedColor` matches by `simKey` and overwrites `hex` and `label`.

Other facts:
- Deletes are hard deletes, with no tombstones. Built-in presets cannot be deleted.
- No record has a timestamp. `ServiceState.storeRevision` is an in-memory counter.
- Gson builds `MagicPacket` (which has no no-arg constructor) with Unsafe, so a new non-null field reads as null from an old file. New fields must be nullable.

### 1.2 iPhone library (`Data/MagicStore.swift`, `Core/MagicModels.swift`)

A port with the same lists, caps and semantics. Codable, lenient decode, Android-compatible JSON, `Documents/magicmaker_store.json`.

- Store writes use `.atomic` and are coalesced. A background task flushes them on backgrounding.
- `Info.plist` sets **`UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`**, so the user can replace the store file through Files.
- `isAppPrefKey` exports only keys whose first character is lowercase.
- `renameLearnedRaw(id:label:)` with a blank label restores the generated label.
- `importAndroidCatalog` adds missing hexes **with Android's labels**. It never replaces anything.
- The same auto-relabel bug as Android.
- Background modes: `bluetooth-central` and `location`. CoreBluetooth state restoration is off.
- One `AndroidRelayGattClient` (`relayGatt`), chosen by `RelayBackend.load()` (`androidBle` | `esp32` | `androidWifi`).
- Transmits go out as:
  - TX char `"{hex}|{ms}"` with response (Lab / `BleTransmitter`);
  - CMD `transmit`, `vibrate`, `interrogate`, `mble_tap`, `raw_burst` (`sendRawBurst`);
  - loops: chip-side `set_tx_loop` / `set_starlight_loop` / `keep_awake` through `sendEsp32Program` when the backend is the ESP32. Otherwise iPhone-timer loops in `TxEngine`.

### 1.3 Existing sync paths

| Path | Direction | Transport | Content | Kept? |
|---|---|---|---|---|
| CatalogSync (`catalog_sync_begin/chunk`; iOS `AndroidRemoteClient.fetchCatalog`) | A→I | CMD + STATUS/CATALOG reads | presets, wand colours, auto rules, timings | kept for auto rules and loop state; "Import Android library" hidden once SYNCED |
| `live` pages | A→I | CMD + STATUS polling (~2 s) | live feed | polling stops while the Android event stream is SYNCED |
| PacketSync | A↔GitHub `packets.csv` | HTTPS | known packets | unchanged |
| Library export/import | manual | file | whole state | import becomes a **diff of local edits** (5.2) |
| ESP32 CATALOG / `catalog*` | | | always `{"ok":true,"items":[]}` | kept for old apps; superseded by SYNC |

### 1.4 ESP32 baseline (as landed)

- **Engine:** one job on air (NORMAL / RAW / STREAM), and at most one RAM-only program. Nothing is persisted, so the board always boots idle. `timedJob()` is true during NORMAL and RAW jobs. `msUntilDue(now)` returns the next deadline, or `RELAY_NO_DEADLINE`.
- **Advertising:** owned by `loop()` through `advManage()`.
  - The beacon is **connectable ADV_IND at 20–30 ms**. The code says why: "a non-connectable advert has a 100 ms minimum interval".
  - With no phone linked, the beacon carries a scan response with the name and the UUID.
  - Idle advertising runs fast (200–400 ms) for 30 s after a change, then about 1 s.
  - Once any phone is linked, advertising is OFF.
  - `advertiseOnDisconnect(false)` is set.
- **Callbacks** push to `gCmdQueue` and call `wakeLoop()`. `onConnect` requests 24–40 (30–50 ms), latency 2, supervision 4 s.
- **STATUS** comes from `relayFormatStatus()`, at most 508 B.
- **Battery** (Heltec): `batteryPoll(now, lit)` reads only while the screen is lit. `screenBatteryMv()` returns -1 when the reading is stale.
- **NimBLE-Arduino 1.4.3** facts:
  - `CONFIG_BT_NIMBLE_MAX_CONNECTIONS` = 3.
  - `NimBLEAdvertising::start()` returns false when `getConnectedCount() >= 3`, in any connection mode.
  - `setScanFilter(scanWL, connWL)` sets `filter_policy`.
  - `notify()` fans out through `ble_gattc_notify_custom`, and `onStatus` fires on `BLE_GAP_EVENT_NOTIFY_TX`.
  - ACL buffers 12 × 255; MSYS1 12 × 292.
  - CCCDs and bonds are persisted in NVS.
- **Core 2.0.17** facts (PlatformIO framework 3.20017.241212):
  - Classic `CONFIG_BTDM_CTRL_BLE_MAX_CONN=3`; S3 `CONFIG_BT_CTRL_BLE_MAX_ACT=6`.
  - `LittleFS.begin(formatOnFail, basePath, maxOpenFiles, partitionLabel="spiffs")`.
  - Coredump to flash is enabled.
  - `-std=gnu++11 -fno-rtti`.
  - Default partitions: classic app 0x140000; Heltec `default_8MB` app 0x330000.
  - `upload.maximum_size`: classic 1,310,720; Heltec 3,342,336.
- **Flashers:** `flash.sh` / `flash.ps1` run `write_flash 0x0 <merged>` **without erase**.

### 1.5 Gaps closed

Cross-device key; per-record version and origin; tombstones; the auto-relabel bug; Gson nulls; identity outside backups and exports; rollback detection; atomic Android writes; the group check.

### 1.6 What the hub stores

| Data | Hub | Why |
|---|---|---|
| Library records (presence + user + reset + tombstones, ns LIB and NEWWAND) | **Stored** (LittleFS log, verbatim bodies) | the "database of commands and names". 200–3,500 records, low write rate |
| Unedited raw/unknown rows | not stored, not synced | volume; each phone relearns them from what it hears or from events |
| Heard-packet events | **relayed only**, never stored, no ring | thousands per hour; Android's CSV log and RAM ring are the record |
| Heartbeats | relayed; latest per device in RAM | ephemeral |
| Auto rules, settings | not in v1 | rules reference device-local ids |
| CSV logs, recordings | never | phones only |

---

## 2. Shared data model (identical in C++, Kotlin, Swift)

### 2.1 Key

`key = [ns u8][packet 3..29 B]`. The packet is the decoded `HexUtils.canonicalHex` (full manufacturer field starting `83 01`).

| ns | Meaning |
|---|---|
| 0 `LIB` | library rows with that hex (all lists) |
| 1 `NEWWAND` | user name for a generated New-Wand code (`newwand_names`) |

Hub hash: 64-bit FNV-1a over the key bytes. Ledger map key on phones: `"<ns>:<HEX>"`.

### 2.2 Record body (TLV `[tag u8][len u8][value]`; canonical = tags ascending, each once, absent fields omitted, fixed-width little-endian integers, no unknown tags)

| Tag | Field | Type | Present when |
|---|---|---|---|
| 0x10 | key | ns + packet | always |
| 0x11 | updatedAt | i64 | always |
| 0x12 | origin | 8 B device id | non-zero |
| 0x13 | flags | u8: bit0 DELETED, bit1 USER_EDITED, bit2 PRESET, others 0 | non-zero |
| 0x14 | label | UTF-8 1..64 B | USER_EDITED or PRESET or ns=NEWWAND; not DELETED; non-empty |
| 0x15 | category | u8 0 UNKNOWN, 1 SHOW, 2 ANIMATION, 3 COLOR | ns=LIB, USER_EDITED or PRESET, not DELETED |
| 0x16 | note | UTF-8 1..160 B | non-empty, not DELETED |
| 0x17 | kind | ASCII typeInfo 1..16 B | USER_EDITED or PRESET |
| 0x18 | place | u8 1 presets, 2 colors, 3 library, 4 raw | USER_EDITED or PRESET (placement hint when the receiver has no row) |

- `bodyCrc` = CRC-32/ISO-HDLC (zlib) over the canonical body.
- Receivers parse, check validity and recompute the CRC over the canonical re-encoding. A body that is not canonical is BAD_MSG.
- Local edit APIs trim the label and truncate it to 64 bytes **before** storing (at a code-point boundary; the UI caps input), so the local row and the record never differ. The note gets the same treatment at 160 bytes.

### 2.3 Record classes, versions, comparator

| Class | updatedAt | flags | Content |
|---|---|---|---|
| PRESENCE | 1 | 0 | key + updatedAt only (byte-identical on every node) |
| USER | 2 `LEGACY_USER_ANDROID`, 3 `LEGACY_USER_IOS`, or ≥ 1.5e12 ms | USER_EDITED and/or PRESET | label, category, kind, place, note |
| RESET | ≥ 1.5e12 ms | 0 | optional note. The user cleared the name; label and category are derived locally |
| TOMBSTONE | ≥ 1.5e12 ms | DELETED | key, updatedAt, origin |
| NEWWAND | ≥ 2 | 0 or DELETED | label = the name |

- `updatedAt` 0 = no record; 4 … 1,499,999,999,999 = invalid (ERR CLOCK). PRESENCE with any flag or content = BAD_MSG.
- `version = (updatedAt, origin as 8-byte big-endian unsigned, bodyCrc)`, compared lexicographically. Incoming is accepted iff `version(incoming) > version(ledger)`. Equal is a duplicate: no-op, not forwarded.
- **A local edit** is stamped `updatedAt = max(nowMs, ledger.updatedAt + 1, lastLocalStamp + 1)` with `origin = self`. An edit always beats the version it edits, whatever the clock skew.

### 2.4 Ledger (phones)

`sync.ledger: Map<keyString, LedgerEntry{u updatedAt, o origin hex?, c crc u32, b canonical body base64? (null for PRESENCE, which is recomputable), s syncSeq, f syncFrom hex?}>`.

- The ledger is the replicated state. List rows are its projection (2.6).
- Pages and live pushes serve `b` verbatim.
- The feed is an in-memory `TreeMap<syncSeq, key>`, rebuilt at load.
- A key is **syncable** iff it has a ledger entry. Entries are created by:
  - learning a row into `presets` (user), `learnedColors` or `learnedLibrary` (PRESENCE);
  - any user edit on any row, raw rows included (USER/RESET);
  - deletes of syncable keys (TOMBSTONE);
  - New-Wand names (NEWWAND).
- Unedited raw rows and built-in presets have no entry.

### 2.5 Hub storage

The hub stores bodies verbatim in its log. It never interprets labels.

### 2.6 Apply (phones)

On accept: store the ledger entry with `s = nextSyncSeq++` and `f = sender`; project; save (debounced); bump the store revision once per page.

| Incoming class | Projection |
|---|---|
| TOMBSTONE (LIB) | Remove every learned row and user preset with that hex. Reset a built-in preset row to its built-in label and category (`userEdited=false`, note cleared). |
| USER (LIB) | Set label, category, typeInfo=kind, note and `userEdited=true` on **all** rows with the hex. If PRESET is set and there is no user preset row, add one (`userRecorded=true`). If PRESET is clear, remove a user preset row only when the version is newer than that preset's ledger version (LWW is full state). If no row exists, create one in `place` (raw: `simKey="RAW:hex"`; colors/simKey from the classifier when it knows the packet). |
| RESET (LIB) | On all rows: label and category = `derived(hex)`, `userEdited=false`, note = record note. If no row exists: as PRESENCE. |
| PRESENCE (LIB) | If a row exists: nothing to project. If none exists: run the same learn routine as hearing it (`addClassifiedToLibrary` without rssi or log). If the routine declines (ping, built-in duplicate by `libraryDedupeKey`, tombstoned, raw), keep the ledger entry anyway (so the version is not re-accepted) but create no row, and count it as `skipped`. |
| NEWWAND | Set or remove `newwand_names[HEX]`. |

`derived(hex)` = built-in preset label/category if the hex is a built-in, else `MagicClassifier.classify(hex)`, else `rawLabel`/UNKNOWN.

### 2.7 Deletion and tombstones

- A user delete of a syncable key writes a TOMBSTONE. Bulk deletes tombstone syncable keys only (`deleteSavedBands` removes raw noise and creates none).
- **Learn paths check the ledger.** A tombstoned hex is not re-learned. It still shows live and is still logged. An explicit save-as-preset creates a newer USER version that beats the tombstone.
- **No time-based garbage collection on phones.** Garbage collection on only some nodes causes permanent divergence. Cap: 5,000 tombstones per phone; past the cap, drop the oldest and leave the key with no entry.
- The hub keeps tombstones as ordinary log records, subject to the capacity policy (4.8).

### 2.8 Heard-packet events

- `eventId = (origin 8 B, epoch u32, seq u32)`.
- `epoch = max(nowSeconds, lastEpoch + 1)`, persisted in the identity file at each service start.
- `seq` restarts at 1 per epoch.
- Receivers keep, per (origin, epoch), the highest contiguous seq plus a 64-bit bitmap, for the last 2 epochs per origin. Anything at or below the window floor is a duplicate.

---

## 3. GATT protocol

### 3.1 Characteristic and advertising identity

| Item | Value |
|---|---|
| Service | `A7830001-0000-1000-8000-00805F9B34FB` (unchanged) |
| **SYNC** | `A7830006-0000-1000-8000-00805F9B34FB`. WRITE \| WRITE_NO_RESPONSE \| NOTIFY, CCCD 0x2902. Central→peripheral = write without response; peripheral→central = notification |
| Hosts | ESP32 (NimBLE) and Android `RelayGattServer`. The iPhone is always the central. Android is central to the hub and peripheral to the iPhone. |
| Optional | A peer without SYNC (old firmware or app) is "transmit-only, no sync", and the UI says so. |

- **ESP32 idle advertising:** primary ADV = flags + 128-bit UUID + complete name `MM_ESP` (3 + 18 + 8 = 29 B); scan response = name. The beacon is unchanged (4.9).
- **Android advertising:** primary ADV = flags + 32-bit service UUID + service data on that UUID = `"MM_AND"` + `groupId[0..1]` (3 + 6 + 14 = 23 B). The scan response repeats the same service data for older iPhone builds. The iOS `relayKind(forTag:)` prefix match still works.

### 3.2 MTU and framing

- MTU: iOS negotiates by itself (185+). The Android central calls `requestMtu(247)`. NimBLE prefers 255.
- **Frame** = 2-byte header + chunk, where `chunk = MTU − 3 − 2`.

| Byte | Bits | Field |
|---|---|---|
| 0 | 7..6 | protocol version `01` |
| 0 | 5 | START |
| 0 | 4 | END |
| 0 | 3..0 | message counter (the same for all frames of one message) |
| 1 | 7..0 | frame seq, +1 per frame per link direction, 0 at link-up |

- Frames of different messages are never interleaved in one direction of a link (one outbox per link).
- Reassembly:
  - START resets the buffer.
  - A frame-seq gap, or a counter change without START, drops the partial message (count BAD_FRAME) and waits for the next START.
  - END delivers the message.
  - A message larger than the receiver's `maxMsg` is dropped and answered with ERR TOO_BIG.
  - A version other than `01` is dropped and answered once with ERR PROTO.
- At MTU 23 (18-byte chunks) everything still works: PULL limit 8, maxBytes 512, Android event coalescing window 3 s, and STATUS/Diag show `MTU23`.

### 3.3 Message encoding

`message = [type u8] + TLV*`. Unknown tags are skipped (except inside a record body, 2.2). A missing mandatory tag is answered with ERR BAD_MSG. Integers are little-endian. Strings are UTF-8 without a terminator.

### 3.4 Messages

| Type | Name | Sent by | Purpose |
|---|---|---|---|
| 0x01 | HELLO | both | identity, group, nonce, feed position, subscriptions |
| 0x02 | PULL | both | request a feed page |
| 0x03 | REC | both | one record version (page or live) |
| 0x04 | PAGE_END | both | ends a page |
| 0x05 | EVT | A (origin), H (relay) | heard packet |
| 0x06 | EVT_SINCE | I (or H relaying) | replay request |
| 0x07 | EVT_GAP | A (or H relaying) | the origin's ring no longer covers the request |
| 0x08 | HB | all | heartbeat |
| 0x09 | SUB | both | change subscriptions |
| 0x0A | ERR | both | error |
| 0x0B | AUTH | central | group proof |
| 0x0C | JOIN | grouped node | hand over the group key (or rekey) |

**HELLO 0x01**

| Tag | Field | Type | M/O |
|---|---|---|---|
| 0x01 | proto | u8 = 1 | M |
| 0x02 | deviceId | 8 B | M |
| 0x03 | kind | u8: 1 hub, 2 android, 3 ios | M |
| 0x04 | dbId | 8 B (random; regenerated on reset, rollback or corruption) | M |
| 0x05 | clockMs | i64 epoch ms (0 = unknown) | M |
| 0x06 | feedHigh | u32 = durableHigh | M |
| 0x07 | subs | u8: bit0 records, bit1 events, bit2 heartbeats | M |
| 0x08 | caps | u16: bit0 serves feed, bit1 originates events, bit3 transmitter, bit4 device-side programs, bit5 loops-by-hex | O |
| 0x09 | maxMsg | u16 | M |
| 0x0A | bootId | u16 random per boot / service start / launch | M |
| 0x0B | version | str ≤ 16 | O |
| 0x0C | name | str ≤ 20 | O |
| 0x0D | groupId | 8 B (all zero = ungrouped) | M |
| 0x0E | nonce | 8 B random per session | M |
| 0x0F | proof | 16 B; only in the peripheral's reply, and only when both groupIds are equal and non-zero | O |

subs: I→H 0x05, I→A 0x07, A→H 0x05, H→anyone 0x05, A→I 0x05.

**AUTH 0x0B:** 0x01 proof 16 B. **JOIN 0x0C:** 0x01 groupId 8 B, 0x02 groupKey 16 B, 0x03 flags u8 (bit0 rekey).

**PULL 0x02:** 0x01 reqId u8 1..255, 0x02 since u32, 0x03 limit u8 1..32 (default 24), 0x04 maxBytes u16 256..1536 (default 1536), 0x05 dbId 8 B (the server dbId that `since` refers to), 0x06 exclude u8.

**REC 0x03:** 0x01 seq u32 (sender's feed seq), 0x02 reqId u8 (0 = live), 0x03 seenBy 8 B (repeatable, at most 4, live only), then body tags 0x10–0x18. At most about 370 B.

**PAGE_END 0x04:** 0x01 reqId, 0x02 scannedTo u32 (≤ durableHigh, counting skipped entries), 0x03 more u8, 0x04 feedHigh u32, 0x05 count u8.

**EVT 0x05:**

| Tag | Field | Type |
|---|---|---|
| 0x01 | origin | 8 B |
| 0x02 | epoch | u32 |
| 0x03 | seq | u32 |
| 0x04 | ts | i64 ms |
| 0x05 | packet | 3..29 B |
| 0x06 | rssi | i8 |
| 0x07 | count | u16 |
| 0x08 | lat | i32 1e-7° |
| 0x09 | lon | i32 1e-7° |
| 0x0A | acc | u16 m (absent = no fix) |
| 0x0B | addr | 6 B advertiser address |
| 0x0C | flags | u8: bit0 tagged own-band address, bit1 replay |
| 0x0D | seenBy | 8 B, repeatable, at most 4 |

**EVT_SINCE 0x06:** 0x01 origin, 0x02 epoch, 0x03 afterSeq, 0x04 requester 8 B.
**EVT_GAP 0x07:** 0x01 origin, 0x02 epoch, 0x03 firstAvail u32 (0 = none), 0x04 lastAvail u32, 0x05 curEpoch u32, 0x06 requester 8 B.
**HB 0x08:** see 9.1. **SUB 0x09:** 0x01 subs.
**ERR 0x0A:** 0x01 code, 0x02 refType, 0x03 key, 0x04 detail str ≤ 40, 0x05 dbId 8 B, 0x06 retryMs u16.

| Code | Name | Receiver behaviour |
|---|---|---|
| 1 | BAD_FRAME | count, continue |
| 2 | TOO_BIG | lower maxBytes, retry the page |
| 3 | BAD_MSG | log |
| 4 | PROTO | no sync on this link (transmit still works); UI "update app/firmware" |
| 5 | DB_CHANGED | wm[peer]=0, store the new dbId, re-PULL |
| 6 | FULL | hub library full; record not stored there (phones keep it) |
| 7 | CLOCK | record rejected (future or invalid time). The originator shows "Phone clock is ahead — N edits not synced" and re-stamps those records with `now` once its clock is sane |
| 8 | BUSY | retry after retryMs |
| 9 | COLLISION | 64-bit hash collision on the hub; log; not stored |
| 10 | AUTH | group mismatch or bad proof; the link is marked FOREIGN |
| 11 | NOT_READY | hub index still building; retry after retryMs |

### 3.5 Session state machine (one code shape on all three nodes)

| State | Entered when | Actions | Timers |
|---|---|---|---|
| LINKED | transport up, SYNC found, notifications enabled (central) or CCCD written (peripheral) | central sends HELLO | HELLO timeout 5 s × 3 tries, then INCOMPATIBLE (retry in 60 s) |
| HELLO_X | HELLOs exchanged (the peripheral answers the central's HELLO with its own, plus `proof` when grouped alike) | group logic (3.6) | AUTH timeout 5 s |
| AUTHED | proofs verified both ways | resolve wm (3.7); send PULL; send own HB; iPhone sends EVT_SINCE for tracked origins | |
| SYNCING | own PULL outstanding and/or serving the peer | page loop | page timeout 10 s, then re-PULL the same `since`; after 3 tries drop the session and retry in 30 s |
| SYNCED | own pull reached `more=0` | live traffic | HB 60 s; re-pull on triggers (3.7) |
| FOREIGN | group mismatch | no sync. Hub: disconnect within 1 s. Phones: do not auto-reconnect to this peer (iPhone: identifier; Android: hub MAC) | |
| NOGROUP | both sides ungrouped | transmit only, until one side gets a group | re-check on every HB / link change |
| CLOSED | link down | wm is already persisted with the data | |

### 3.6 Sync group and authentication

- `groupKey` = 16 random bytes. `groupId = SHA-256("MMGROUP1" ‖ key)[0..7]`.
- The **iPhone creates the group** the first time this version runs. Android and the hub start ungrouped.
- Proofs, over `T = nonceC ‖ nonceP ‖ idC ‖ idP`:
  - `proofP = HMAC-SHA256(key, "MMSYNC1P" ‖ T)[0..15]`
  - `proofC = HMAC-SHA256(key, "MMSYNC1C" ‖ T)[0..15]`
  - The central checks proofP, then sends AUTH{proofC}.
- **Trust on first use.** If exactly one side is grouped, after the HELLO exchange the grouped side sends `JOIN{groupId, groupKey}`. The receiver persists the key and both restart at LINKED. Any grouped node may JOIN an ungrouped one, so the hub can be grouped by the iPhone or by an already-grouped Android.
- **Rekey.** A JOIN with `rekey=1` is accepted only on an AUTHED session.
- **Leaving a group:**
  - Heltec: PRG held 5 s; short presses still page the screen.
  - Classic ESP32: BOOT/GPIO0 held 5 s.
  - Android: Diag → "Leave sync group".
  - iPhone: Diag → "New sync group", which rekeys the members currently linked.
- **Once grouped, the hub serves members only.** A connection that has not authenticated within 10 s is disconnected; old, SYNC-less apps lose access to a grouped hub. An ungrouped hub behaves as before for any app.
- Payloads are authenticated at session start but not encrypted (see risks).

### 3.7 Pull, paging, watermarks, exclusion (durable-only)

- **Peer state** is kept per `peerDeviceId`: `{peerDbId, wm, excludeOk, lastSyncMs}`. Phones keep it in the same JSON write as the ledger; the hub keeps it in NVS. On HELLO, if the peer's dbId differs from the stored one: wm = 0 and excludeOk = false.
- **Serving a PULL:**
  - Iterate the feed from `since + 1` up to **durableHigh** only.
  - Skip superseded entries (hub: `index[key].off == entry.off`; phones: the TreeMap holds only current seqs).
  - When `exclude=1` and `excludeOk[puller]` is true, also skip entries with `origin == puller` or `syncFrom == puller`.
  - Stop at `limit`, `maxBytes`, or the scan budget (hub: 32 entries or 4 KB read per loop pass; the page continues on later passes).
  - Send `PAGE_END{scannedTo, more, feedHigh=durableHigh}`.
- **The puller** applies the page, persists the data, **then** persists `wm = scannedTo`. Phones do both in the same atomic JSON write; the hub writes wm to NVS only after the records are flushed. It then sends the next PULL if `more` is set. The server sets `excludeOk[puller] = true` after a `more=0` page sent to the puller's current dbId.
- **Pull triggers:**
  - AUTHED;
  - a **direct** HB or HELLO showing `feedHigh > wm` (hops=0 only);
  - 2 s after the last live REC from that peer (coalesced);
  - DB_CHANGED;
  - the hub's `hubFull` clearing (4.8).
- **Hub backpressure.** The hub sends its next PULL only when its dirty queue has room for `maxBytes`.
- Durable-only consequence: a crash may lose unsaved entries and their seqs may be reused, but no peer ever recorded a wm above durableHigh. Lost records come back from their sender through its own pull path.

### 3.8 Live push and forwarding (records)

- **Local change** (user edit, or a newly learned presence): send a live REC to every AUTHED/SYNCED session subscribed to records, with `seenBy = {self} ∪ {all target peer ids}`.
- **First accept of a live REC from P:**
  - targets = record-subscribed sessions whose peer ∉ `seenBy ∪ {P, origin}`;
  - send with `seenBy' = seenBy ∪ {self} ∪ targets`, at most 4 ids.
  - Equal version = duplicate: nothing is forwarded.
- **Records accepted from pages** are not live-forwarded. The node sends an on-change HB (`feedHigh` advanced), and peers pull.
- **Bulk local changes** (more than 4 within 1 s: migration, import, the first learn burst) are not pushed live; the HB triggers a pull.
- **Live RECs never advance wm.**
- Bounds: each version crosses each directed link live at most once. A pull may add at most one duplicate per link. A message is never sent back to its sender, or to the origin, as a live push.

### 3.9 Events: routing and catch-up

- Only Android originates events (`caps.bit1`). The iPhone ingests them. The hub only relays and keeps no ring.
- **Android route per event:**
  1. If the A–I session is SYNCED and subscribed to events: direct, `seenBy {A, I}`.
  2. Else, if A–H is SYNCED and the hub's latest **direct** HB (≤ 90 s old) lists a kind-3 link with the synced flag: send to H with `seenBy {A, H}`.
  3. Else: ring only.
- **Hub relay.** An EVT from P goes to every events-subscribed member session whose peer ∉ `seenBy ∪ {origin}`, with those ids added to seenBy.
- **Android ring:** the last 2,000 encoded EVTs in RAM.
- **Catch-up:**
  - The iPhone's HB carries `evtWm` (origin, epoch, highest contiguous seq) for each tracked origin.
  - When Android receives the iPhone's HB on any path, or an EVT_SINCE, and sees the iPhone behind, it replays the missing range (`flags.replay=1`) over the current best route.
  - If the ring no longer covers the range, Android sends EVT_GAP with `curEpoch`, so the iPhone advances (counting the gap) and asks for the current epoch from 1.
  - The iPhone also sends EVT_SINCE as soon as it sees a seq jump, and on AUTHED.
  - An EVT_SINCE that reaches the hub is relayed to A if A is a member on a session. Otherwise the hub drops it, and the HB path heals the gap later.
- **Pacing:** at most 20 EVT/s per link. Replays rank below live events.
- The iPhone dedupes by event id (2.8).

### 3.10 Ordering and idempotency

ATT keeps order per link, but pages, live pushes, relays and replays may arrive in any relative order. Record merge is order-independent (LWW over verbatim bodies) and events dedupe by id. Every message is safe to receive twice.

### 3.11 Clock

- Phones reject a REC with `updatedAt > now + 24 h`, or in the invalid range, and answer ERR CLOCK with the key.
- The hub's clock is `esp_timer_get_time()/1000 + epochOffset`. `epochOffset` is the median of the latest `clockMs` per member phone (from HELLO and direct HBs). The hub rejects future records only once it knows the time.
- If the phones' clocks differ by more than 5 min, the hub sets HB state bit `clockSkew`. The iPhone shows "Phone clocks differ by N min".

### 3.12 Versioning

`proto=1`. New optional tags need no bump. Incompatible changes bump `proto`. A peer with a different `proto` gets ERR PROTO: no sync on that link, but transmit still works.

### 3.13 Topology behaviour

| Item | Hub only (I–H, A–H) | Direct only (I–A) | Triangle |
|---|---|---|---|
| iPhone edit | I→H {I,H}; H→A {I,H,A} | I→A | I→H and I→A with {I,H,A}; nobody forwards |
| Android edit / new presence | A→H; H→I | A→I | A→H, A→I; nobody forwards |
| Android heard event | A→H (route 2); H→I | A→I | A→I direct (route 1); the hub is not involved |
| HBs | own HB to H; H forwards once to the other phone | A↔I | each node sends its own HB to both peers and forwards the others' once. Every HB arrives twice (DIRECT and VIA); duplicates are dropped and the panel shows both paths |
| Partial: I–H + I–A (A not on H) | | | A's edit → I {A,I} → I forwards to H {A,I,H}. Events A→I. I forwards A's HB to H and H's HB to A |
| Partial: A–H + I–A (I not on H) | | | A forwards I's edits to H and H's to I. Events A→I |
| Hub returns | reconnect, AUTH, both sides pull from their stored wm, converge. Durable-only means nothing is skipped | | |

---

## 4. ESP32 hub firmware

### 4.1 Files

| Path | Content | Arduino deps |
|---|---|---|
| `partitions.csv` | 4.2 | |
| `src/mmsync/sync_codec.{h,cpp}` | frames, TLV, messages, canonical body, CRC-32, FNV-64 | none (host-testable) |
| `src/mmsync/sync_crypto.{h,cpp}` | portable SHA-256 + HMAC (checked against vectors; the same code on host and target) | none |
| `src/mmsync/sync_merge.{h,cpp}` | comparator, class validity, clock rules, seenBy routing | none |
| `src/mmsync/mmdb.{h,cpp}` | log store, index, durable tracking, compaction, recovery, over `Storage` and `KvStore` interfaces | none |
| `src/mmsync/storage_littlefs.cpp`, `kv_nvs.cpp` | LittleFS file and Preferences (NVS) back-ends | `LittleFS.h`, `Preferences.h` |
| `src/mmsync/hub.{h,cpp}` | sessions, group/auth, outbox and pacing, pulls, relay, HB, roster; uses a `Radio` interface and a `TxGate` (`timedJob`, `msUntilDue`, command queue depth) | none |
| `src/mmsync/hub_nimble.cpp` | SYNC characteristic, callbacks into queues, per-connection notify | NimBLE |
| `test/host/` | g++ tests, `storage_posix.cpp`, `kv_mem.cpp`, `radio_sim.cpp`, `Makefile` (ignored by arduino-cli) | |

- arduino-cli compiles the sketch's `src/` folder recursively.
- All firmware C++ is **gnu++11** with `-fno-rtti`: no `std::optional`, no structured bindings, no `if constexpr`.
- Host tests: `-std=gnu++11 -Wall -Werror -fsanitize=address,undefined`.
- Bump `MM_FW_VERSION` from "1.2" to "2.0".

### 4.2 Partitions (one CSV for both boards) and CI

```
# Name,    Type, SubType,  Offset,   Size
nvs,       data, nvs,      0x9000,   0x5000
otadata,   data, ota,      0xE000,   0x2000
app0,      app,  ota_0,    0x10000,  0x180000
littlefs,  data, spiffs,   0x190000, 0x260000
coredump,  data, coredump, 0x3F0000, 0x10000
```

- **Sizes.** App 1.5 MB, against today's ~576 KB classic and ~538 KB Heltec images. LittleFS 2.375 MB (608 blocks).
- `otadata` and `ota_0` stay, so CI's `merge_bin … 0xe000 boot_app0.bin` stays valid. The coredump partition stays, because the core enables coredump to flash.
- **Both boards get the sketch CSV** through the core's prebuild hook. The FS offset never changes, and the Heltec leaves its upper 4 MB unused.
- **First boot after the upgrade:** `LittleFS.begin(true, "/mm", 4, "littlefs")` fails on old app1/spiffs bytes and formats once. littlefs formatting writes only the superblock pair, and blocks are erased when they are allocated, so the leftover data is harmless.
- **Library across updates.** The flashers never erase, so the library survives updates. Document in the README that Arduino IDE "Erase All Flash" wipes it; the phones refill it.
- **CI (`esp32-firmware.yml`):**
  - Add `firmware/esp32-transmitter/**.csv` and `firmware/esp32-transmitter/src/**` to the path triggers.
  - Pass `--build-property upload.maximum_size=1507328` (0x170000, a 64 KB margin) to **both** compiles. The classic default of 1,310,720 would wrongly reject an image that fits; the Heltec default of 3,342,336 would wrongly accept one that does not.
  - Add a step that fails if `*.ino.bin` > 0x170000.
  - Add a step that decodes `*.partitions.bin` with `gen_esp32part.py` and asserts `littlefs @ 0x190000`.
  - Add a `host-tests` job (`make -C firmware/esp32-transmitter/test/host test`).
- **PlatformIO (optional dev path):**
  - `platform = espressif32 @ 6.9.0` (verified locally: framework-arduinoespressif32 3.20017.241212 = core 2.0.17);
  - `board_build.partitions = partitions.csv`, `board_build.filesystem = littlefs`;
  - envs `esp32dev` and `heltec_wifi_lora_32_V3`;
  - `lib_deps = h2zero/NimBLE-Arduino@1.4.3, olikraus/U8g2@2.35.30`;
  - a `native` env for the host tests.

### 4.3 Storage layout

**LittleFS `/mm/lib.log`**, append-only, little-endian:

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | magic `0xA7` |
| 1 | 1 | type: 1 record, 2 END trailer (compaction output only), 3 HEADER (first entry: `{dbId 8, formatEpochS u32}`) |
| 2 | 2 | len (≤ 360) |
| 4 | 4 | seq (0 for HEADER/END) |
| 8 | 8 | syncFrom device id (0 = local/unknown) |
| 16 | len | payload (canonical record body / header / trailer `{count u32, maxSeq u32}`) |
| 16+len | 4 | CRC-32 over bytes 1 … 16+len−1 |

- **Exactly one `File` handle on `lib.log`**, opened in `"a+"` mode for its whole life and used only from `loop()`. Appends go to the end; reads `seek()` on the same handle after a flush. A second handle never opens the file.
- **NVS namespace `mmsync`:**
  - `db`: dbId, 8 B.
  - `grp`: groupId 8 + key 16.
  - `peers`: blob of at most 8 × `{deviceId 8, dbId 8, wm u32, excludeOk u8, kind u8, lastSyncEpochS u32}`.
  - `full`: hubFull flag.
  - NVS writes are atomic per key, so no A/B slot scheme is needed.

### 4.4 RAM

| Item | Classic | S3 |
|---|---|---|
| Index: sorted array `{hashLo u32, hashHi u32, off u32}`, where bit31 of `off` marks a dirty slot | 4,096 → 48 KB | 8,192 → 96 KB |
| Seq checkpoints `{seq, off}` every 32 entries | 1 KB | 2 KB |
| Dirty queue (bytes) | 4 KB | 8 KB |
| RX MessageBuffer `[conn u16][frame]` | 4 KB | 4 KB |
| Reassembly 3 × 512 B; outboxes 3 × 2 KB (2 members + 1 transient) | 7.5 KB | 7.5 KB |
| Device/HB table (8), peers, sessions, auth | 1.5 KB | 1.5 KB |
| LittleFS caches (≤ 2 open files) | ~4 KB | ~4 KB |
| **Total** | **≈ 70 KB** | **≈ 123 KB** |

- **Adaptive cap.** All other buffers are allocated first, at boot after `NimBLEDevice::init`. Then `cap = clamp((heap_caps_get_largest_free_block(MALLOC_CAP_8BIT) − 64 KB) / 12, 1024, MAX)`.
- Report `cap`, `heap` and `heapMin` in `sync_status` and in the boot log.
- **Inserts are batched per page.** Sort the page's new keys and merge them into the array from the end in one pass: about 0.3–0.6 ms for 48 KB at 80 MHz. A single live insert does one memmove of the same order. Inserts run only when flash work is allowed (4.5) or no timed job is on air.
- **Collision guard.** On a hash match, read the stored key (flash or dirty queue) and compare it. On a mismatch, answer ERR COLLISION.

### 4.5 Flush, durability and flash-work gating

- An accepted version gets `seq = nextSeq++` and is encoded into the dirty queue; the index points at the dirty slot. Live relaying may happen before the flush. Pages and `feedHigh` only use **durableHigh** = the last seq flushed.
- **Flush** means one append of all dirty bytes plus `file.flush()`. It runs when dirty ≥ 2 KB, **or** 2 s after the first dirty entry, **or** before compaction, **or** before persisting peers. It runs **only when flash work is allowed**:
  - `!gEngine.timedJob()`, and
  - `gEngine.msUntilDue(now) ≥ 400 ms` (the keep-awake STREAM has no deadline, so it qualifies), and
  - the command queue is empty.

  Why: after a sync, the next littlefs append copies the partly filled last block into a freshly erased block (`lfs_ctz_extend`), and may also compact metadata. That is one 4 KB erase plus up to 4 KB of programming, roughly 20–150 ms. During it `loop()` stalls, and with the flash cache off so does the NimBLE host task. The controller keeps advertising from IRAM.
- **Starvation guard.** If dirty data is older than 30 s, allow a flush in the next gap with `msUntilDue ≥ 200 ms`.
- **Peers** are written to NVS after a flush that completes a page (at most once per 60 s per peer) and at session end, with the same gating.
- **Backpressure.** When the dirty queue cannot take a page, the hub stops issuing PULLs. A live REC that does not fit gets ERR BUSY (retryMs 1000); the phone keeps it in its feed and it arrives by pull. Nothing is lost.
- **Wear.** About 50–200 flushes a day means that many block erases, spread over 608 blocks by littlefs (`block_cycles` 512). NVS peers take at most 150 small writes a day over 5 pages. Both last decades.

### 4.6 Boot and recovery

- **Order in `setup()`:** existing engine, queue and screen setup → `LittleFS.begin` → NimBLE init (transmit works at once) → allocate buffers → `loop()` builds the index incrementally (≤ 8 KB read per pass).
- Until the index is ready, a SYNC HELLO is answered with ERR NOT_READY (retryMs 500).
- dbId is generated with `esp_random()` **after** NimBLE init, when the RF RNG is live.

| Found at boot | Action |
|---|---|
| mount fails | format; new dbId; zero peers |
| `lib.log` missing | create with HEADER(dbId from NVS, or new). If NVS peers have wm > 0: new dbId, zero peers |
| HEADER dbId ≠ NVS `db` | new dbId in both; zero peers |
| torn or bad-CRC tail (last entries only) | keep the valid prefix; compact at the first allowed moment |
| bad CRC followed by valid entries | corruption: compact the valid entries; new dbId; zero peers (full resync both ways) |
| `lib.new` present | delete it (an unfinished compaction; `lib.log` is intact because the last step is one rename) |
| `lib.new` with a valid END and no `lib.log` | rename `lib.new` → `lib.log` (only reachable through the remove-then-rename fallback in 4.7) |

`nextSeq = maxSeqInLog + 1`. A seq that was never flushed was never served (D5), so reusing it is harmless.

### 4.7 Compaction

- **Trigger:** `logBytes > max(128 KB, 2 × liveBytes)`, or FS free < 256 KB. Start only when flash work is allowed and there has been no page traffic for 10 s.
- **Steps:**
  1. Write `lib.new`: HEADER, then the live entries in seq order (keeping seq and syncFrom), then the END trailer. Work in ≤ 4 KB steps, one per allowed pass. Flushes are held meanwhile (dirty queue, BUSY).
  2. Close both files.
  3. `rename("/mm/lib.new", "/mm/lib.log")`. littlefs replaces the target atomically. If the VFS refuses to replace it, remove `lib.log` first and rely on the recovery row.
  4. Reopen, rebuild offsets and checkpoints incrementally (NOT_READY for pulls meanwhile).

### 4.8 Capacity

- At `count == cap` with a new key:
  - If the version is not PRESENCE, evict the oldest PRESENCE (lowest seq, `updatedAt == 1`). If there is none, evict the oldest TOMBSTONE.
  - Otherwise answer ERR FULL, still advance wm past the record (counted as skipped), and set `hubFull` (NVS, HB state bit 9).
- When space frees up (compaction, eviction, `sync_reset`) while `hubFull` is set: zero every phone's wm, so the hub re-pulls everything (idempotent), then clear `hubFull`.
- FS free < 64 KB: refuse new keys the same way and force compaction.

### 4.9 Connections and advertising (extends the landed `advManage`)

- **Counts:** `conns` = all connections; `members` = AUTHED sessions; `pending` = connections not yet authenticated.
- **Desired advertising state:**

| Situation | Advertising |
|---|---|
| Job or STREAM on air | **BEACON: ADV_IND at 20–30 ms**, the PDU type and interval used today, so bands see no change. Connect filter on (`setScanFilter(false, true)`, white list kept empty) whenever `conns ≥ 2` **or** `gEngine.timedJob()`. No phone can cut a timed burst by connecting, and no third phone can connect. During keep-awake STREAM with `conns < 2` the beacon stays connectable, so phones (whose pending connections target the hub's public address) relink mid-stream. Scan response (name + UUID) whenever `conns < 2`. |
| Nothing on air, `conns < 2` | idle connectable: fast 200–400 ms for 30 s after a change, then ~1 s (landed) |
| Nothing on air, `conns ≥ 2` | OFF |

- `AdvState`/`advSame` gain the filter bit, and the beacon's scan response now follows `conns < 2` instead of `linked == 0`.
- **Slot policy (2 phones):**
  - A new connection whose HELLO deviceId matches an existing session: disconnect the **old** one (stale).
  - Group mismatch: disconnect at once.
  - A grouped hub disconnects connections that have not authenticated within 10 s.
  - If `conns` reaches 3 in a race, disconnect the newest non-member at once. While `conns ≥ 3`, the beacon cannot start (`NimBLEAdvertising::start()` refuses at 3 connections in any mode); `advManage` retries every pass, and the disconnect event wakes `loop()`.
- No advertising calls from callbacks (already the case). `advertiseOnDisconnect(false)` (already set).

### 4.10 Connection parameters

- Keep the landed request on every link: 24–40 (30–50 ms), latency 2, supervision 4 s. It is within Apple's rules: 50 × 3 = 150 ms ≤ 2 s; × 3 < 4 s; min + 15 ≤ max.
- No bulk profile. Pages move at 10–20 KB/s with data length extension and several PDUs per event, enough for a 200 KB first sync in under 20 s.
- No parameter change is ever requested near a burst.
- Worst-case transmit-command latency stays about 150 ms plus processing.

### 4.11 Pacing and notify

- **Per-connection notify:**
  - `om = ble_hs_mbuf_from_flat(buf, len)`. **If om is NULL, stop and retry later; never pass NULL**, because NimBLE would then send the characteristic's stored value.
  - Then `rc = ble_gattc_notify_custom(conn, syncHandle, om)` (it consumes `om`). If `rc ≠ 0`, stop for this pass.
  - `onStatus` (`BLE_GAP_EVENT_NOTIFY_TX`) wakes `loop()` to continue.
- **During a timed job:**
  - At most 1 frame per session per 40 ms.
  - Priority ERR > HELLO/AUTH > HB > EVT > live REC.
  - Page serving, page scanning, index inserts and flash work are paused.
  - On outbox overflow, the oldest EVTs are dropped; the evtWm replay heals the gap.
- **STREAM or idle:** up to 4 frames per session per pass; page scanning ≤ 32 entries or 4 KB read per pass.
- **`loop()` order:**
  1. Apply commands and run `gEngine.service()` (unchanged, always first).
  2. `advManage`.
  3. Sync work, within its budget: ≤ 4 messages handled, ≤ 1 flush, ≤ 1 compaction step, ≤ 1 page-scan step, ≤ 1 index-build step.
  4. LED, screen, snapshot.
  5. Sleep.

### 4.12 Callbacks vs `loop()`, and sleep

- **NimBLE host callbacks** (`onConnect`, `onDisconnect`, `onMTUChange`, SYNC `onWrite(chr, desc)`, `onSubscribe(chr, desc, sub)`, `onStatus`) only:
  - push a fixed-size `LinkEvent{type, conn, value}` (queue depth 16), or `[conn u16][frame]` to the RX MessageBuffer (`xMessageBufferSend(…, 0)`);
  - then call `wakeLoop()`.
  - If the RX buffer is full, mark that connection "drop until next START" and count it; `loop()` then sends ERR BUSY.
  - No flash I/O, no advertising, no notify, no malloc. `onConnect` keeps its existing `updateConnParams`.
- **Sleep.** `loop()`'s wait also takes `syncNextDueMs()`:
  - 0 while frames are queued, sendable outbox frames remain, or a scan, compaction or index step is pending (each bounded by the budgets above);
  - otherwise the earliest of: next HB, flush deadline, page/HELLO/AUTH timeouts, the 10 s authentication deadline.

  This keeps the landed sleep-until-deadline power model.

### 4.13 Heartbeat, battery and clock on the hub

- **Hub HB** every 60 s on each member session, and on member-set change (≥ 5 s apart). Fields per 9.1. deviceId = `[0x01][0x00][MAC6]`.
- **Battery** (Heltec):
  - Change `batteryPoll(now, lit)` to `batteryPoll(now, lit || hbBatteryDue)`, so the same non-blocking divider sequence also runs every 60 s with the screen dark.
  - mV from `screenBatteryMv()`; pct from `scrBatteryPercent()`.
  - runtime from the parallel workflow's model when it provides one, else from the shared estimator (9.4).
  - The classic board reports -1 for everything.
- **Clock** per 3.11. HB `ts = 0` until the hub knows the time.

### 4.14 Commands

- `{"action":"sync_status"}`: the next STATUS read (within 3 s) returns `{"ok":true,"sync":{…}}` (7.1, ≤ 508 B) instead of the normal status object. The normal object has no room for it.
- `{"action":"sync_reset"}`: accepted only from a connection that is an AUTHED member. Wipes `/mm`, new dbId, keeps the group; members resync.
- The group reset uses the button (3.6).

---

## 5. Android

### 5.1 Placement

| File | Change |
|---|---|
| `sync/SyncCodec.kt`, `sync/SyncMerge.kt`, `sync/SyncCrypto.kt` | pure Kotlin port of 4.1 (shared vectors). HMAC via `javax.crypto.Mac("HmacSHA256")` |
| `sync/SyncIdentity.kt` | `noBackupFilesDir/sync_identity.json`: deviceId, dbId, issuedSeq, evtEpoch, groupId, groupKey. Written atomically |
| `sync/SyncSession.kt` | transport-agnostic state machine (3.5–3.7) |
| `sync/SyncEngine.kt` | sessions, routing (3.8–3.9), ledger calls, event coalescer and ring, HB, device roster. Runs on `HandlerThread("mm-sync")` |
| `sync/HubClient.kt` | GATT central to the ESP32 (5.5) |
| `sync/BatteryInfo.kt`, `sync/RuntimeEstimator.kt` | 5.8, 9.4 |
| `relay/RelayGattServer.kt` | SYNC characteristic, CCCD, per-device notify queue, advertising changes (5.6) |
| `relay/RelayProtocol.kt` | `SYNC_UUID`, `CCCD_UUID`, `relayTagBytes(groupId)` |
| `relay/RelayCommands.kt` | `set_tx_loop` / `set_starlight_loop` accept `hex`, `intervalMs` and `label`, resolve by canonical hex, and run a hex that is not in the library as given. Advertise `caps.bit5` |
| `ble/BleScanner.kt` | in the `skipRelay` branch, report `MM_ESP` / relay adverts to `SyncEngine.hubSeen(device, rssi)` before returning. Add `ScanFilter(serviceUuid=A7830001)` to the screen-off filters until a hub MAC is known |
| `service/MagicMakerForegroundService.kt` | `boot()` starts `SyncEngine`. `restartRelay()` **always** starts the GATT server (WiFi mode adds HTTP); the STANDALONE relay mode is removed from the UI. `handleHeard()` adds the hub echo filter, `hubAirAgoS`, and `SyncEngine.onHeard(...)` after the show-control filter. Publish sync and device state into `ServiceState` |
| `data/MagicStore.kt`, `core/MagicModels.kt` | 5.2–5.4 |
| `ui/MagicMakerScreens.kt`, `ui/vfd/VFDRelayScreen.kt` | compact DEVICES/SYNC card (9.7). New-wand renames go through `store.setNewWandName(hex, name)` |
| `res/xml/backup_rules.xml`, `data_extraction_rules.xml` | nothing to add (`noBackupFilesDir` is excluded by the platform); add a comment saying identity must stay there |

### 5.2 Store fields, identity, migration

- **Row fields.** `MagicPacket` adds the **nullable** UI fields `note: String?` and `userEdited: Boolean?`. Versions live only in `PersistedState.sync: SyncState?` = `{schema: Int, nextSyncSeq: Long, ledger: Map<String, LedgerEntry>, peers: Map<String, PeerState{dbId, wm, excludeOk, lastSyncMs}>}`. All nullable; normalized in `applyState`. The ledger is saved in the **same** JSON write as the rows. Rows without sync data keep those fields null, which Gson omits, so 20k raw rows do not grow the file.
- **Atomic write.** `saveNow()` writes `magicmaker_store.json.tmp` and renames it over the target. The external copy is written the same way.
- **durableSeq** = `nextSyncSeq − 1` as of the last completed write. It is what the feed serves and what `feedHigh` reports.
- **Identity** never goes into the library JSON, an export, Auto Backup or device transfer.
  - After each completed store write: `issuedSeq = max(issuedSeq, written nextSyncSeq)` (atomic identity write).
  - At load:
    - (a) No identity file: new deviceId and dbId. This covers a backup restore or a device transfer.
    - (b) `store.sync == null`: migrate (below).
    - (c) `store.nextSyncSeq < identity.issuedSeq` (rollback or replaced file), or the store came from the external file while no internal store existed (restore): new dbId, every peer's wm = 0, `excludeOk = false`, `issuedSeq = store.nextSyncSeq`.
- **External library file.** When `readBestState` picks `/sdcard/MagicMaker/magicmaker_library.json` over an existing internal store and their content differs, treat the difference as **user edits**:
  - diff rows by canonical hex against the internal store;
  - stamp label/category/note changes as local edits;
  - tombstone removed syncable keys;
  - send added rows through the import/learn path (plus a USER edit where the label is not generated).
  - The file's own `sync` section is ignored.

  `importLibrary()` does the same diff instead of a replace. The identity is not reset, because the store was not rolled back.
- **Migration (schema 0 → 1, once):**
  - A label is **generated** if it equals `derived(hex).label` or matches the `rawLabel`/`rawPacketLabel` forms.
  - A user preset, or a row whose label is not generated or whose category differs from derived: USER entry, `u = 2` (iOS 3), `o = self`, body built from the row with `place` = its list.
  - Any other row in colors or library: PRESENCE.
  - `newwand_names` entries: NEWWAND, `u = 2` (iOS 3).
  - `syncSeq` 1..N in the order presets, colors, library, raw, newwand.
  - Migration counts as a bulk change (pulled, not pushed live).

### 5.3 Ledger operations

| Existing function | Sync action |
|---|---|
| `renamePacket(id)`, `applyLabLabelToMatchingRaw` | resolve the hex; apply the label to **all** rows with it; `localEdit` USER |
| `recategorizePacket(id)` | same, category |
| new `setNote(id, note)` | same, note (USER if userEdited, else RESET + note) |
| `saveCustomPreset` | `localEdit` USER\|PRESET; replaces any tombstone |
| `deletePacketById`, `deleteLearned*`, `deleteCustomPreset`, `clearLearnedStarlight` | TOMBSTONE for each syncable key (2.7) |
| `addStarlightToLibrary`, `addColorToLibrary`, `addShowAnimToLibrary`, `importCloudEntries`, `importHexesToLibrary` (classified rows) | check the ledger (tombstone = skip); a new row gets a PRESENCE entry, `syncSeq++`; pushed live only if ≤ 4 are pending |
| `importLibrary()` | diff as edits (5.2) |
| new `setNewWandName(hex, name)` | NEWWAND `localEdit` (blank = DELETED) |
| new `feedSince(since, limit, maxBytes, excludePeer)` | TreeMap over the ledger, ≤ durableSeq |
| new `applyRemote(rec, fromId)` / `applyPage(recs, fromId)` | 2.6; one `save()` and one `bumpStoreRevision()` per page |

### 5.4 Fix the auto-relabel

In `addShowAnimToLibrary` and `updateLearnedColor`, update the label only when `userEdited != true`, and never touch the ledger. Match starlight rows by canonical hex, not by `simKey`, so a learn path never changes a row's hex (key stability). The iOS port gets the identical change.

### 5.5 HubClient (Android as a BLE central)

- **Discovery.** The existing Disney scan reports relay adverts through `hubSeen`; no extra `startScan` (the 5-starts-per-30 s quota). After the first AUTHED session, remember the hub MAC in the identity file. From then on use `connectGatt(ctx, false, cb, TRANSPORT_LE)` when the hub was just seen, otherwise `connectGatt(autoConnect = true)`, a background pending connection that survives Doze.
- **Setup:** `requestMtu(247)` → `discoverServices()` → SYNC (and TX for diagnostics) → `setCharacteristicNotification` + CCCD `01 00` → session.
- **Op queue:** one outstanding operation, 5 s timeout.
  - API 33+: `writeCharacteristic(chr, value, WRITE_TYPE_NO_RESPONSE)` returns a status; on `ERROR_GATT_WRITE_REQUEST_BUSY` retry after 20 ms.
  - Older APIs: the legacy call.
  - The next write waits for `onCharacteristicWrite`.
- **Errors:** status 133 or another failure: `gatt.close()`, then back off 1, 2, 5, 10, 30 s. Always `close()` on disconnect. On AUTH failure (FOREIGN), forget the MAC.
- **Echo filter.** A Disney packet whose `address == hub MAC` is the hub's own beacon. Show it live with the note "ESP32", but do not learn it, do not auto-respond, and do not make an event of it. Update `hubAirAgoS` (9.1).

### 5.6 RelayGattServer as the direct sync peer

- Add SYNC (WRITE \| WRITE_NO_RESPONSE \| NOTIFY, permission WRITE) with a CCCD descriptor.
- Implement `onDescriptorWriteRequest`/`onDescriptorReadRequest` (always `sendResponse`), `onMtuChanged`, and `onNotificationSent` (the next frame goes out only after it). Use `notifyCharacteristicChanged(device, chr, false, value)` on API 33+ (status-returning; retry on busy) and the legacy call below that.
- SYNC writes are copied to the `SyncEngine` thread at once; the binder thread is never blocked.
- **Advertising:**
  - The tag moves to the primary ADV (3.1).
  - LOW_LATENCY for 60 s after start or after the iPhone disconnects, then BALANCED.
  - **Stopped while the iPhone is linked**: the server has one client; this saves power and keeps strangers out.
  - Still paused for manufacturer bursts and keep-awake (existing behaviour; see risks).
- Old iPhone builds identify Android by the scan-response tag, which stays.

### 5.7 Event origin (Android-heard packets)

- **Input:** every packet that passes `handleHeard`'s show-control and echo filters, with `lastLocation` and the address.
- **Coalescer per canonical hex:**
  - The first sighting emits at once (count 1).
  - Later sightings within 1,000 ms are counted and emitted at the end of the window (`count = n`, `rssi = max`, `ts = last`).
  - At most 256 open windows (LRU).
  - Above 20 EVT/s on a link, the window becomes 3 s.
- `epoch` per 2.8. The ring holds the last 2,000 encoded EVTs.
- Routing and catch-up per 3.9.
- Setting "Share heard packets with iPhone", default ON.

### 5.8 Heartbeat and battery

- `BatteryInfo`:
  - `BatteryManager.getIntProperty(BATTERY_PROPERTY_CAPACITY)`;
  - sticky `ACTION_BATTERY_CHANGED` for `EXTRA_VOLTAGE` (mV) and `EXTRA_STATUS`/`EXTRA_PLUGGED` (charging);
  - `PowerManager.isPowerSaveMode` → state bit 5.
- Runtime from the estimator (9.4). HB rules per 9.2.

### 5.9 Threading, background, permissions

- Everything runs inside the existing foreground service (`connectedDevice`, partial wake lock, battery-optimization exemption).
- GATT callbacks post to `mm-sync`. `MagicStore` stays `@Synchronized`; page applies run on the sync thread.
- No new permissions.
- BLE connections and notifications continue in Doze.

---

## 6. iPhone

### 6.1 Files

| File | Change |
|---|---|
| `Core/SyncCodec.swift`, `Core/SyncMerge.swift`, `Core/SyncCrypto.swift` (CryptoKit is not on Linux: use the portable SHA-256/HMAC port), `Core/SyncLedgerCore.swift` (Foundation-only: codec, comparator, ledger, apply/projection on `[MagicPacket]` arrays, routing) | compiled in `ios-core-parity.yml` with a new `ios/SyncCheck/main.swift` |
| `BLE/RelayLink.swift` | split `AndroidRelayGattClient` into **one instance per kind** (`.esp32`, `.android`), each matched by its own kind, never through `RelayBackend.load()`. Adds SYNC discovery, notify subscribe, write-without-response flow control (`canSendWriteWithoutResponse` / `peripheralIsReady(toSendWriteWithoutResponse:)`), chunk = `maximumWriteValueLength(for: .withoutResponse)` − 2 |
| `BLE/BleCentral.swift` | owns `esp32Link` and `androidLink` on the one `CBCentralManager`. Routes delegate callbacks by `peripheral.identifier`. Assigns discoveries by `advertisedRelayKind`, ignoring advertisers with neither a tag nor a name, and Android advertisers whose 2-byte group tag differs from ours |
| `BLE/TransmitRouter.swift` | section 8 |
| `Sync/SyncSession.swift`, `Sync/SyncEngine.swift` (@MainActor), `Sync/DeviceRoster.swift`, `Sync/SyncIdentity.swift` | sessions, routing, HB, alerts, identity |
| `Data/MagicStore.swift`, `Core/MagicModels.swift` | 6.3 |
| `ViewModels/ScanEngine.swift` | `ingestRemote(_:)` (6.5) |
| `ViewModels/AppViewModel.swift`, `BLE/AndroidRemoteClient.swift`, `BLE/BleCoordinator.swift` | Android-only commands (`status`, `live`, `catalog*`, `set_scan`, `set_auto`, `set_recording`, `clear_live`, `remove_live`, `delete_wand_color`, `clear_wand_library`, `set_auto_rule`, `delete_auto_rule`, `pairing`) target `androidLink`. Every transmit-producing action goes through `TransmitRouter`. Programs follow 8.4 |
| `Views/SettingsScreen.swift`, `VFD/VFDSettingsScreen.swift` | Primary transmitter + notify toggle (8.1) |
| `Views/LinkScreen.swift`, `VFD/VFDLinkScreen.swift` | DEVICES panel and two link rows (9.6) |
| `Views/DiagScreen.swift`, `VFD/VFDDiagScreen.swift` | sync diagnostics, "New sync group", hub `sync_reset` |
| `Views/ContentView.swift`, `VFD/VFDRootView.swift` | link-notice banner |

- Register new files with `.claude/ios-parity/add_swift.py` (pbxproj); `project.yml` sources pick them up.
- Add the Core files to the explicit list in `ios-core-parity.yml`.
- VFD layouts follow the vfd-theme preview-first workflow (`tools/vfd/screens/link.py`, `settings.py`, `diag.py`).

### 6.2 Dual links and discovery

- Both links are kept up whenever Bluetooth is on, whatever the primary.
- **ESP32** (public, static address): after the first link, `retrievePeripherals(withIdentifiers:)` + `connect()`, a pending connection with no timeout that also works in the background. It connects on the keep-awake beacon too, because that beacon stays connectable while fewer than 2 phones are linked.
- **Android** (private address, which also changes whenever advertising restarts):
  - Foreground: the existing scan.
  - Background, while the Android link is down: `scanForPeripherals(withServices: [CBUUID(string: "A7830001")])`, identified by the primary-ADV tag.
  - An unknown advertiser gets at most 1 connection attempt per 60 s per identifier.
- `pauseScanForRelayConnect` is used only for a connect the user starts in the foreground. Background pending connects never pause the Disney scan.
- **Echo filter:** Disney packets heard locally from the ESP32 link's `identifier` are ignored, in addition to the existing `isRelayEcho`.

### 6.3 Store fields, identity, migration

- **Fields.** `MagicPacket` adds `note: String = ""` and `userEdited: Bool = false`, decoded leniently and encoded only when non-default. `StorePersistedState.sync` has the same shape and JSON keys as Android (5.2).
- **Identity file:** `Application Support/sync_identity.json`, with `URLResourceValues.isExcludedFromBackup = true`. It holds deviceId, dbId and issuedSeq. A backup restore therefore yields a new deviceId, and a reinstall deletes the file together with Documents.
- **Group key** in the Keychain with `kSecAttrAccessibleAfterFirstUnlock` (not ThisDeviceOnly), so an iPhone restored from an encrypted backup stays in the group.
- **Rollback detection** as 5.2(c). This matters because `Documents/magicmaker_store.json` can be swapped through Files.
- **Migration** as 5.2, with `LEGACY_USER_IOS = 3`.
- **`importLibrary(from:)`** = diff as edits.
- **Ledger hooks:** `renamePacket`, `recategorizePacket`, `renameLearnedRaw` (a blank label means RESET), the delete functions, `saveCustomPreset`, the learn paths (ledger check plus the 5.4 fix), `importAndroidCatalog`, `setNewWandName`. Same table as 5.3.
- **Background saves.** While backgrounded, raw-learn saves are spaced at least 60 s apart (`rawSaveIntervalMs`), so the multi-MB JSON rewrite does not run on every remote event.

### 6.4 Sync engine behaviour

- A session is created when a `RelayLink` is command-ready with SYNC present.
- Initial pull in pages; each page goes into `store.applyPage` with one revision bump.
- User edits go out as live RECs within 100 ms.
- "Import Android library" is hidden while the Android session is SYNCED.
- **Polling:** while Android events are flowing (A–I SYNCED, or A events via H), stop `fetchLivePackets` polling and slow STATUS polling to 10 s. Keep `catalog_sync` for auto rules and loop state only.

### 6.5 Ingesting forwarded heard-packet events (`ScanEngine.ingestRemote`)

1. Dedupe by event id (2.8). Detect seq jumps (send EVT_SINCE).
2. If the local scan is active and the same canonical hex was heard **locally** within 1,500 ms, mark the live row "+AND" only: no count, no log, no learn.
3. Apply the iPhone's own `showControlOnly` filter, as `handleHeard` does.
4. `appendLive` with the note "Android" and address = event MAC, only for non-replay events younger than 30 s.
5. `store.processHeardPacket(hex, rssi, persistToSession: recordSession, address, lat/lng/accuracy from the event, timestampMs: evt.ts)`. Add `timestampMs` to `persistRecording`.
   - The log note gets ` · AND×n`. One CSV row per EVT.
   - **A PRESENCE entry created by this learn gets `syncFrom = evt.origin`**, so Android's pulls exclude it and it does not echo back.
6. Counters: `packetsHeard += count`. If the packet lights a band, `lightsHeard += count` and the strip updates. A starlight packet updates the wand colour index.
7. **Remote events never trigger iPhone auto-responses.** Android owns auto-responses for what it hears.
8. Ingest runs whether or not the local scan is on, and in the background.

### 6.6 Background behaviour

- `bluetooth-central` delivers notifications and connection events to a suspended app. The keep-running setting (background location) keeps the app alive.
- **HB while backgrounded:** when any SYNC message arrives and the iPhone's own HB is due (> 60 s), send it then. The hub's 60 s HB guarantees a wake while it is linked.
- Local notifications are posted from background wakes (8.3).
- State restoration stays off, as now. If iOS terminates the app, sync, alerts and failover stop until the next launch (open question 6).

---

## 7. Status, telemetry, screen

### 7.1 Hub `sync_status` reply (≤ 508 B)

```
{"ok":true,"sync":{"rec":1234,"cap":3900,"tomb":12,"full":0,"logKB":96,"fsKB":[180,2432],
 "db":"a1b2c3d4","seq":5678,"dur":5670,"grp":"9f3e","rdy":1,"heap":[123456,98765],
 "ph":[{"k":"i","id":"9f3e","s":3,"mtu":185,"wm":5600,"ago":12,"b":81},
       {"k":"a","id":"07c1","s":3,"mtu":247,"wm":5590,"ago":3,"b":54}]}}
```

- `s`: 0 linked, 1 auth, 2 syncing, 3 synced, 4 foreign.
- `dur`: durableHigh. `grp`: the last 4 hex digits of groupId ("" when ungrouped). `rdy`: index ready.

### 7.2 Heltec screen (`oled_pages.h`, `oled_ui.h`)

- **STATUS** line 5: `SYN  2PH 1234 REC`. Other values: `SYN  NO PHONES`, `SYN  1PH FULL`, `SYN  MTU23`, `SYN  NO GROUP`, `SYN  LOADING`.
- **DEVICES** page (new) after STATUS. Page order: STATUS → DEVICES → LAST PACKET → (BATTERY from the other workflow) → DEVICE. Labels in columns 0–3, values from column 4 (17 characters):

```
IPH  81% CHG    12S
     ~5H DIRECT
AND  54%        40S
     ~3H VIA IPH
REC  1234/3900
FS   12% GRP 9F3E
```

- `--` when unknown; `LOST` after 10 min of silence.
- `ScreenInputs` gains `phones[2]{kind, pct, charging, runtimeMin, ageS, path}`, `syncPhones`, `records`, `cap`, `fsPct`, `group4`, `ready`. It is filled in `loop()` only.
- The BATTERY page, if present, gets `SYN 2PH` as its last line.

### 7.3 Phone diagnostics

iPhone DIAG and Android Diag show per session:
- state, MTU, wm/feedHigh/durable, pages;
- dup / skip / reject / BAD_FRAME counts;
- events received / deduped / gaps / replays;
- failovers, the last ERR, and the group short id.

---

## 8. Transmit routing and failover (iPhone)

### 8.1 Setting

- **Primary transmitter: ESP32 / ANDROID** (UserDefaults `primary_transmitter`).
  - Classic Settings: segmented picker.
  - VFD Settings: `[ESP32] [ANDROID]` selectors, the selected one inverted.
- Toggle **Notify when using backup**, default ON.
- **Migration from `relay_backend`:** `esp32` → ESP32; `androidBle` → ANDROID; `androidWifi` → ANDROID with the Android transport = WiFi HTTP (the BLE links still run for sync).
- The LINK screen backend picker becomes "Android link: BLE / WiFi".

### 8.2 Router

**Scope: every transmit-producing operation.**
- TX characteristic `"{hex}|{ms}"` (Lab / `BleTransmitter`);
- CMD `transmit`, `vibrate`, `interrogate`, `raw_burst`, `mble_tap`;
- `TxEngine.radioSend` bursts (random show, replay, auto-response sequences).

Programs follow 8.4. Timing settings (`set_wakeup_preamble`, `set_command_burst`, `set_starlight_burst`, tx power and interleave, in the names `relay_proto.h` parses) are pushed to **both** transmitters on link and on every change, so a failover send uses the same timing. Android's TX characteristic ignores the duration and uses its own settings, which is why the push matters.

**Algorithm (`TransmitRouter.send(op, completion)`):**
1. `order = [primary, backup]`.
2. For each candidate: skip it if it is not command-ready or is `suspect`. Otherwise send the operation.
3. **Ack** = the ATT write response without an error. TX characteristic writes use with-response. Both the ESP32 (which parses CMD before the write response goes out) and Android (`sendResponse` with ok/failure) answer at the write response. An ESP32 reply of `busy` (command queue full) gets one retry after 100 ms on the same link.
4. An error, or no ack within **1,500 ms**: mark the candidate `suspect`, raise the notice, and try the next candidate with the same operation.
5. Success on the backup: route state = `failover(reason)`.
6. No candidate left: `completion(false)` and "No transmitter linked".

The broadcast completion keeps today's semantics (the full duration), separate from the ack.

**Caveat.** A timed-out write may still have reached the primary, so one packet can occasionally go out from both transmitters. The notice for that case reads "ESP32 not answering — sent via Android".

| Detection | Mechanism | Time |
|---|---|---|
| Primary not linked when sending | link state | immediate |
| Write error | `didWriteValueFor` error | ~1 connection event |
| No ack | timer (normal ack ≤ ~300 ms at 30–50 ms / latency 2, plus at most one deferred-free flush window) | 1.5 s |
| Link lost | supervision: ESP32 4 s; iOS↔Android set by iOS (≤ 6 s) | ≤ 6 s |
| Suspect cleared | link ready again + AUTH OK, or a successful write; or retry after 10 s with the link up | |
| Back to primary | primary command-ready + AUTH OK (or 5 s for SYNC-less firmware) + stable 2 s | 2–5 s |

### 8.3 Notices and notifications

| Trigger | Banner / status line | Local notification (only when not active; the same key at most once per 2 min) |
|---|---|---|
| failover start | `ESP32 UNREACHABLE — SENT VIA ANDROID`. If an ESP32 HB arrived on another path within 90 s: `ESP32 OUT OF RANGE (ALIVE VIA ANDROID) — SENT VIA ANDROID`. The reverse wording for an Android primary | yes (if the toggle is on) |
| primary back | `ESP32 BACK — TRANSMITTING VIA ESP32` | yes |
| no transmitter | `NO TRANSMITTER LINKED` | yes |
| program moved (8.4) | `TX LOOP MOVED TO ANDROID` / `KEEP-AWAKE STOPPED: ESP32 UNREACHABLE` | yes |
| device silent > 3 min | `ANDROID SILENT 3 MIN` | yes, once per silence |
| battery low / critical | `ESP32 BATTERY 18%` | yes, once per threshold per discharge |
| hub full / clock skew / incompatible / foreign peer / no group | status line | no |

- The banner is non-blocking: a 6 s top overlay in the classic theme; an inverted status-block row in VFD. While failover lasts, the state stays on the LINK status line.
- `UNUserNotificationCenter` authorization is requested the first time the toggle is used, or the first time a failover happens in the foreground.

### 8.4 Program ownership (keep-awake, TX loop, wand loop)

- **Owner** = the primary while it is alive. "Alive" means it is linked to the iPhone, **or** its HB arrived on any path within 90 s, **or** (ESP32 only) Android's `hubAirAgoS` ≤ 90 s.
- A program runs on the owner's device-side engine: the ESP32 program, or the Android service loop via `set_*_loop{hex, intervalMs, label}` / `keep_awake{hex}`.
- iPhone-timer loops in `TxEngine` are used only when the owner cannot run device-side programs (`caps.bit4/bit5` absent: old firmware or app).

| Situation | TX / wand loop | Keep-awake |
|---|---|---|
| Primary linked | runs on the primary | runs on the primary |
| Primary not linked to the iPhone but alive | stays on the primary (it runs by itself); status line "Loop continues on ESP32" | stays |
| Primary presumed dead (no alive evidence for 90 s) | start on the backup; notify "Loop moved to Android" | ESP32 → Android: **not moved** by default (Android keep-awake pauses Android scanning); notify. Android → ESP32: moved |
| Primary back | stop on the backup (await ok), then read the primary's HB state bits; start there only if it is not already running (ESP32 programs are RAM-only and vanish on reboot) | same |

- **Single owner.** On every HB, if the same program runs on both transmitters (HB state bits 1–3), stop it on the non-owner.
- **When the iPhone is not running** (terminated), nothing migrates (risk).
- With primary = Android, Android keep-awake pauses Android scanning and its connectable advertising (existing behaviour). The DEVICES panel shows "Android scan paused".

---

## 9. Heartbeats and DEVICES

### 9.1 HB message (0x08)

| Tag | Field | Type | Hub | Android | iPhone |
|---|---|---|---|---|---|
| 0x01 | deviceId | 8 B | `[1][0][MAC6]` | random | random |
| 0x02 | kind | u8 | 1 | 2 | 3 |
| 0x03 | bootId | u16 | per boot | per service start | per launch |
| 0x04 | hbSeq | u32 | +1 per HB | | |
| 0x05 | ts | i64 ms (0 = unknown) | estimate | clock | clock |
| 0x06 | uptimeS | u32 | `esp_timer` | service | app |
| 0x07 | battPct | i8 (−1 = unknown) | Heltec reader, −1 classic | CAPACITY | `UIDevice.batteryLevel` |
| 0x08 | battMv | i16 (−1) | divider | `EXTRA_VOLTAGE` | −1 |
| 0x09 | charging | i8 (−1/0/1) | model or −1 | STATUS/PLUGGED | `batteryState` |
| 0x0A | runtimeMin | i16 (−1) | model or estimator | estimator | estimator |
| 0x0B | version | str ≤ 16 | `MM_FW_VERSION` + board | versionName | CFBundleShortVersion |
| 0x0C | name | str ≤ 20 | `MM_ESP` | `Build.MODEL` | "iPhone" |
| 0x0D | link (repeatable) | `[peerId 8][peerKind 1][flags 1: bit0 synced, bit1 tx-ready, bit2 wifi]` | members | hub, iPhone | hub, Android |
| 0x0E | state | u16 | | | |
| 0x0F | hops | u8 | 0 originated, 1 forwarded | | |
| 0x10 | feedHigh | u32 (durable) | | | |
| 0x11 | dbId | 8 B | | | |
| 0x12 | records | u32 | stored | ledger size | ledger size |
| 0x13 | hubAirAgoS | u16 | | seconds since Android last heard the hub's own beacon (0xFFFF = never) | |
| 0x14 | evtWm (repeatable) | `[origin 8][epoch u32][seq u32]` | | | per tracked origin |

State bits (0x0E): bit0 scanning, bit1 keepAwake, bit2 txLoop, bit3 wandLoop, bit4 randomShow, bit5 lowPower, bit6 txBusy, bit7 primary=ESP32, bit8 failoverActive, bit9 hubFull, bit10 clockSkew, bit11 syncNotReady.

- Size ≤ ~180 B: one frame at MTU 185+.
- Receivers keep the latest HB per deviceId: a new one replaces the old when bootId changed or hbSeq is greater.
- A forwarder changes nothing but `hops`.

### 9.2 Interval

- 60 s base, on every member link.
- Also on change, at least 5 s apart: link set, charging, battery 1 % step (iPhone: its reported step), state bits, crossing a threshold, `feedHigh` advanced by a page or a bulk change.
- One immediate HB when a link reaches AUTHED.

### 9.3 Forwarding and path

- An HB with `hops = 0` received from P is forwarded once, with `hops = 1`, to every other HB-subscribed member session except P and the described device. An HB with `hops = 1` is never forwarded.
- **Path:** `DIRECT` if received from the described device itself within 90 s; `VIA <forwarder>` otherwise; both are shown when both are fresh.
- Pull triggers and the hub clock use direct HBs only.

### 9.4 Runtime estimator (identical on all three)

- Samples `(t, pct)` every 60 s for 60 min, reset on a charging change.
- While discharging, with Δpct ≥ 3 over ≥ 10 min: `rate` = least-squares slope, `runtimeMin = pct / rate`, clamped to 0..5999. Otherwise −1.
- The ESP32 derives pct from mV with `scrBatteryPercent`, unless the other workflow's model supplies runtime.

### 9.5 Alerts (iPhone; shown in DEVICES and notified per 8.3)

| Alert | Threshold | Clears at |
|---|---|---|
| Phone low / critical | ≤ 20 % / ≤ 10 % while discharging | +3 % or charging |
| ESP32 low / critical | ≤ 20 % or ≤ 3.55 V / ≤ 10 % or ≤ 3.40 V | +3 % / +0.05 V |
| Silent | no HB on any path for > 3 min (warn), > 10 min (LOST) | next HB |
| Clock skew | > 5 min between phones | ≤ 1 min |
| Hub full | `hubFull` | cleared |
| Foreign / no group | a session in FOREIGN or NOGROUP | resolved |

### 9.6 iPhone DEVICES panel (LINK tab, both themes)

| Row | Shows |
|---|---|
| ESP32 (MM_ESP) | battery % and V, charging, `~5H`, last-seen age, path `DIRECT` / `VIA ANDROID` / both, role `PRIMARY`/`BACKUP`, TX state (`READY`, `SUSPECT`, `DOWN`), program running, records `1234/3900`, alerts |
| ANDROID | %, charging, runtime, age, path, scanning on/off, "hears ESP32 12S ago" (`hubAirAgoS`), role, alerts |
| THIS IPHONE | %, charging, runtime |
| SYNC | per peer: state, last sync age, records, pending pushes, group short id |

VFD: one 2-line block per device; alarms in the alarm colour per the vfd-theme palette rules.

### 9.7 Android compact

- Relay tab card and `VFDRelayScreen`: one line per device, for example `ESP32 68% 3.91V ~5H 12S HUB` and `IPHONE 81% CHG 4S DIRECT+HUB`, plus `SYNC 1234 REC`.
- The foreground notification text appends `· hub ✓ · iPhone 81%`.
- No Android notifications in v1.

---

## 10. Security and privacy

- **The sync group (3.6)** keeps libraries, GPS-stamped events and heartbeats within the user's own devices, and keeps strangers' phones off hub slots.
- **Identity and keys** never go into library files, exports or Android backups (D15).
- **Not covered:** BLE payloads are not encrypted. A JOIN sends the key in clear text once, at the first meeting. The TX and CMD characteristics stay unauthenticated on an ungrouped hub and on Android, as today (risks).

---

## 11. Test plan

### 11.1 Shared vectors and transcripts

`tools/sync/gen_vectors.py` (Python stdlib reference encoder) writes `tools/sync/vectors.json`:
- frames at MTU 23/185/247, including frame-seq gaps;
- every message type, with and without optional tags;
- canonical bodies, CRCs, invalid class combinations;
- comparator cases (PRESENCE vs legacy vs ms; origin tie; CRC tie; invalid range; future);
- apply/projection scenarios, including a hex in several lists and a PRESET clear;
- seenBy routing tables for records, events and HB in every topology of 3.13;
- event dedupe windows across epochs;
- HMAC/groupId vectors with fixed keys and nonces;
- HB decode.

The C++ three-node simulation also writes **golden session transcripts** (`tools/sync/transcripts/*.txt`: the message sequence per link for scripted scenarios). The Kotlin and Swift `SyncSession` tests replay them against a fake transport and must emit identical messages. CI checks that the committed files are current.

### 11.2 Host C++ (`firmware/esp32-transmitter/test/host`, `make test`, new CI job)

- **Codec:** vectors, reassembly with dropped or reordered frames, oversize.
- **Merge:** comparator, class validity, clock, routing.
- **Crypto:** SHA-256 and HMAC known answers.
- **mmdb on POSIX storage + in-memory KV:**
  - append, flush, reload; the index after reload equals the index before;
  - batch merge;
  - superseded entries skipped; `exclude` and `excludeOk`;
  - paging with `limit` / `maxBytes` / scan budget / `scannedTo`;
  - **durable-only:** crash at every point between accept and flush, then assert no served `scannedTo` or `feedHigh` ever exceeded the flushed seq;
  - **power-loss fuzz:** truncate or corrupt every byte of the last 3 entries, then recovery = durable prefix, plus the new-dbId rule;
  - compaction crash at each step;
  - HEADER/NVS dbId mismatch;
  - full and eviction, including re-pull after `hubFull` clears;
  - forced hash collision.
- **Gating:** a fake `TxGate` asserts that no flush, insert or compaction step runs while `timedJob()` is true or `msUntilDue < 400`.
- **Three-node simulation** (H, A, I plus a stranger node in another group, on in-memory transports): random edits, deletes, presence learns, events, HBs, link up/down, topology changes, phone crashes and store rollbacks, clock skew. Assert:
  - eventual convergence of the ledgers (identical key → version maps);
  - no live record or event is ever sent to its sender or origin;
  - each version crosses each directed link live at most once;
  - events reach I exactly once after dedupe whenever a path existed before A's ring overflowed, and EVT_GAP only when it did overflow;
  - no message of any kind crosses to the stranger;
  - wm never exceeds the server's durableHigh.

### 11.3 Kotlin (`android/app/src/test/.../sync/`)

Extend `android-ci.yml`'s filter to `--tests 'com.magicmaker.android.sync.*'`.
- `SyncCodecTest`, `SyncMergeTest`, `SyncCryptoTest` (vectors); `SyncSessionTest` (transcripts, timeouts, DB_CHANGED, AUTH/JOIN).
- `MagicStoreSyncTest`:
  - Gson load of an old JSON (nulls);
  - migration classes, including the generated-label heuristic;
  - rename applies to all rows; re-hear no longer relabels;
  - a tombstone blocks re-learn;
  - `applyRemote` projection per 2.6;
  - feed order, exclusion, durable-only;
  - atomic write (a crash mid-write leaves the old file intact);
  - identity rollback detection (an older store file → new dbId);
  - external-file diff becomes local edits.
- `EventCoalescerTest`, `EventRouteTest`, `RuntimeEstimatorTest`.

### 11.4 Swift (`ios-core-parity.yml`)

Compile `Core/Sync*.swift` with `ios/SyncCheck/main.swift` on Linux and run the vectors, transcripts and `SyncLedgerCore` store scenarios (migration, projection, rollback detection). The app target builds through the existing TestFlight/Xcode workflow.

### 11.5 Firmware builds

- arduino-cli for classic and Heltec: size gate ≤ 0x170000; partition table check.
- PlatformIO `pio run -e esp32dev -e heltec_wifi_lora_32_V3`, `pio test -e native` (optional job).
- The boot log prints free heap, the largest block, cap, FS usage and the index build time.

### 11.6 Hardware matrix (manual; results recorded in the PR)

| Scenario | Pass criteria |
|---|---|
| Both phones on the hub, iPhone locked | a rename on the iPhone appears on Android in ≤ 2 s; Android-heard packets appear in the iPhone log with Android's lat/lon |
| Triangle | events arrive direct; each HB shows DIRECT+VIA; no duplicate events in the iPhone CSV |
| Hub powered off mid-session | direct sync takes over in ≤ 10 s; events continue; transmit fails over with a notice |
| Hub back | converges in ≤ 60 s; no duplicates in the iPhone log |
| Third phone (stranger, other group) | no sync, no data; disconnected in ≤ 1 s; beacons unaffected |
| Fresh hub, first iPhone link | the hub joins the iPhone's group automatically |
| Timing with 2 phones + first sync (200 KB) running | wake/command phase durations within ±20 ms of nominal (sniffer or a scanning phone); no burst cut by a connection; a command sent during a flush starts within 200 ms |
| Beacon filter on the classic ESP32 | ADV_IND at 20–30 ms with the connect filter; a phone's pending connect waits until the burst ends |
| Keep-awake + iPhone out of range, then back | relinks on the keep-awake beacon within ≤ 10 s |
| Primary ESP32 switched off | the next send goes via Android in ≤ 1.5 s, with a notice (notification when backgrounded); after 90 s the loop moves to Android; returns ≤ 5 s after the ESP32 comes back, the loop is restored on the ESP32 and stopped on Android |
| ESP32 alive but out of the iPhone's range, near Android | notice says "alive via Android"; the loop stays on the ESP32 |
| Android app reinstall with Auto Backup restore; iPhone restore from backup | the restored device gets a new identity (or dbId); full resync; nothing lost |
| User replaces `magicmaker_store.json` (Files) with an older copy | rollback detected; resync restores newer records |
| 24 h soak | heap min stable; FS < 20 %; no resets; flash erase count logged |
| Power | idle current with 0/1/2 phones linked against the pre-sync baseline |

---

## 12. Implementation order and acceptance

| Phase | Deliverable | Gate |
|---|---|---|
| P0 | the parallel workflow (engine, chip-side programs, battery page, keep-running) merged on main | its own gates |
| P1 | `docs/SYNC_PROTOCOL.md`, vector + transcript generator, C++/Kotlin/Swift codec, merge, crypto | all three pass the vectors in CI |
| P2 | Firmware: partitions, mmdb, NVS meta, SYNC characteristic, auth/group, sessions, advertising filter, slot policy, gating and pacing, HB, `sync_status`, screen | host tests green; size gate; timing and beacon-filter rows pass |
| P3 | Android: identity, atomic write, ledger, migration, relabel fix, external diff, HubClient, server SYNC, events, HB, loops by hex, compact UI | Kotlin tests green; hub-only and direct-only rows pass with a test iPhone build |
| P4 | iPhone: RelayLink split, identity, ledger, SyncEngine, ingestRemote, TransmitRouter, program ownership, settings, banner, DEVICES (both themes), Diag | full hardware matrix |
| P5 | Docs: firmware README sync/devices pages, user guide (group reset, primary transmitter, alerts), polish | |

### Appendix: constants

| Constant | Value |
|---|---|
| SYNC UUID | `A7830006-0000-1000-8000-00805F9B34FB` |
| proto / frame version / header | 1 / `01` / 2 B |
| Key packet length | 3..29 B |
| Hub phones / NimBLE max conns | 2 / 3 |
| Hub maxMsg / record body max | 512 / 360 B |
| PULL default limit / maxBytes | 24 / 1536 (8 / 512 at MTU 23) |
| Hub page scan budget | 32 entries or 4 KB per pass |
| HELLO / AUTH / page timeouts | 5 s × 3 / 5 s / 10 s × 3 |
| Member auth deadline (grouped hub) | 10 s |
| HB interval / change spacing / path freshness | 60 s / 5 s / 90 s |
| Flush thresholds | 2 KB dirty or 2 s; starvation 30 s |
| Flash-work gate | `!timedJob && msUntilDue ≥ 400 ms && cmd queue empty` (starvation: ≥ 200 ms) |
| Compaction trigger | log > max(128 KB, 2 × live) or FS free < 256 KB |
| Tombstones | phones: no TTL, cap 5,000; hub: evicted only under the capacity policy |
| Future-time bound / clock-skew warning | 24 h / 5 min |
| Event coalesce window / rate cap / Android ring | 1 s (3 s over the cap) / 20 EVT/s per link / 2,000 |
| iPhone local-dup window / live-feed max age | 1.5 s / 30 s |
| TX ack timeout / busy retry / primary stable / suspect retry | 1.5 s / 100 ms / 2 s / 10 s |
| Program migration (owner presumed dead) | 90 s with no HB on any path and no `hubAirAgoS` ≤ 90 s |
| Silent warn / lost | 3 min / 10 min |
| Connection params (all links) | 30–50 ms, latency 2, supervision 4 s |
| Beacon | ADV_IND 20–30 ms; connect filter when conns ≥ 2 or a timed job is on air |
| Idle connectable adv | 200–400 ms for 30 s after a change, then ~1 s; OFF at 2 phones |
| Android relay adv | LOW_LATENCY 60 s after start/disconnect, then BALANCED; off while the iPhone is linked |
| Group button reset | PRG / BOOT held 5 s |
