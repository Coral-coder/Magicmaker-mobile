# Sync hub, phase P3 (Android): implementation plan

Status: plan for phase P3 of [SYNC_HUB_SPEC.md](SYNC_HUB_SPEC.md) (§12). Normative wire rules are in
[SYNC_PROTOCOL.md](SYNC_PROTOCOL.md); the spec's amendments A1–A3 (top of that file) override its
body. Where this plan decides something the spec leaves open, the decision is listed in §11.

## Where the hub work stands

| Phase | What | State |
|---|---|---|
| P1 | Protocol, vectors, transcripts; Kotlin, C++ and Swift codec/session cores | **done** (Kotlin: `android/app/src/main/java/com/magicmaker/android/sync/Sync*.kt`, tests green) |
| **P3** | **Android: identity, ledger, migration, HubClient, direct peer for the iPhone, events, heartbeats, SYNC/DEVICES card** | **built** (part 1 data + part 2 runtime; unit tests green; on-device smoke test pending, §9.3) |
| P2 | ESP32 hub firmware (SYNC characteristic, library DB) | not started (the board runs firmware 1.2: no SYNC) |
| P4 | iPhone: dual links, sync engine, DEVICES panel, primary transmitter | not started |

What the user gets from P3 alone: the Android side is complete and tested against the shared
transcripts and in loopback, and the Android app has an always-visible sync/devices status (Relay tab
card, VFD Relay screen, and the foreground notification). That status reports honestly what is not
ready yet: until P2 lands, the ESP32 row shows its advert battery and `NO SYNC FW`. Until P4 lands,
the iPhone row shows `UPDATE APP` once an old iPhone build links. When P2 and P4 land, the rows turn
`IN SYNC` with no further Android work.

---

## 0. Ground rules for the implementers

- Repo `/home/user/Magicmaker-mobile`, branch `main`. **No commits, pushes or other git state
  changes.**
- Do not touch `firmware/`, `ios/`, `web/` or `.github/`. On Android, a parallel workflow owns
  `ble/Esp32Heartbeat.kt` (and its test) and `telemetryLineText` in `ui/MagicMakerScreens.kt`. Do not
  edit them. Re-read every shared file right before editing it, and keep edits minimal and anchored on
  exact strings.
- P1 files (`sync/SyncBytes.kt`, `SyncConstants.kt`, `SyncCrypto.kt`, `SyncEvents.kt`,
  `SyncFrames.kt`, `SyncLedger.kt`, `SyncMessages.kt`, `SyncRecord.kt`, `SyncRouting.kt`,
  `SyncSession.kt`, `SyncText.kt`) are **frozen**. P3 only adds new files beside them. A P1 bug is
  reported, not patched in place.
- `core/` must stay pure Kotlin with no `sync/` imports, because `tools/parity` compiles
  `android/app/src/main/java/com/magicmaker/android/core` on a plain JVM.
- All new pure logic lives in package `com.magicmaker.android.sync`, and so do its tests (see §10.5
  about CI).
- Build and test, one Gradle at a time:
  `cd android && ./gradlew -q :app:compileDebugKotlin`, then
  `./gradlew -q :app:testDebugUnitTest --tests 'com.magicmaker.android.sync.*'`, then the full
  `./gradlew -q :app:testDebugUnitTest`.

---

## 1. Requirement map

| # | Requirement (spec ref) | Where (part) |
|---|---|---|
| R1 | Identity outside backups: deviceId, dbId, issuedSeq, event epoch, group key, hub MAC, foreign list (D15, §5.2) | `sync/SyncIdentity.kt` → `noBackupFilesDir/sync_identity.json` (1) |
| R2 | Atomic writes of the store, the external copy and identity (§0.1 item 5, §5.2) | `sync/AtomicFiles.kt`; `MagicStore.saveNow/writeExternal/exportLibrary` (1) |
| R3 | Ledger of verbatim bodies, feed index, durable-only serving (D5, D6, §2.4, PROTOCOL §6, §15.2) | `sync/LedgerStore.kt`, `sync/SyncStateJson.kt` (1) |
| R4 | Migration of existing rows to records (§5.2) | `sync/LibraryMigration.kt`; `MagicStore.load` (1) |
| R5 | Auto-relabel fix (§5.4) | `MagicStore.addShowAnimToLibrary/updateLearnedColor` + `LibraryRows.relabelOnRehear` (1) |
| R6 | Every library edit, rename and delete becomes a record version (§5.3); external file and import become diffs (§5.2) | `sync/LibrarySync.kt` hooks, `sync/LibraryDiff.kt`; every mutation point in §4.7 (1) |
| R7 | Projection of remote records onto rows (§2.6, PROTOCOL §6.5) | `LibrarySync.applyRemote/commitPage` (1) |
| R8 | Rollback, restore and replacement detection (§5.2 a–c) | `sync/SyncIdentity.kt` `IdentityReconcile` (1) |
| R9 | Driving the P1 session core: sessions, timers, peer table, pulls (§3.5–3.7, PROTOCOL §14–15) | `sync/SyncNode.kt` (2) |
| R10 | Live push, forwarding, bulk rule, durability rule (§3.8, PROTOCOL §16.2, §15.4) | `SyncNode` (2) |
| R11 | HubClient: Android as BLE central to the ESP32 SYNC characteristic `A7830006` on `A7830001` (§5.5) | `sync/HubLinkMachine.kt` (pure) + `sync/HubClient.kt` (2) |
| R12 | RelayGattServer gets SYNC as the iPhone's direct peer; tag in primary ADV; advertising policy (§3.1, §5.6) | `relay/RelayGattServer.kt`, `relay/RelayProtocol.kt`, `sync/GattServerLinks.kt`, `sync/RelayAdvPolicy.kt` (2) |
| R13 | Framing, MTU, flow control, pacing (§3.2, PROTOCOL §9, §16.3) | `sync/LinkChannel.kt` (2) |
| R14 | Event origin for Android-heard packets: coalescer, epoch, ring, route choice, catch-up (§5.7, §3.9, PROTOCOL §8.5, §16.3) | model `sync/EventOrigin.kt` (1); routing and catch-up in `SyncNode`/`AndroidRole` (2) |
| R15 | Heartbeats with Android battery; estimator; roster (§5.8, §9.1–9.4) | model `sync/HeartbeatModel.kt` (1); `sync/BatteryInfo.kt`, HB build/send/forward/on-change in `SyncNode` (2) |
| R16 | Threading, background, permissions (§5.9) | `sync/SyncEngine.kt`, service wiring (2); §6 |
| R17 | Compact SYNC/DEVICES card: every device, link path, HB age, battery, sync state (§9.7, user request) | `sync/SyncStatus.kt`, `ui/SyncDevicesCard.kt`, `ui/vfd/VFDSyncDevices.kt`, RelayTab, `VFDRelayScreen`, notification (2) |
| R18 | Group TOFU, rekey, leave (§3.6, PROTOCOL §13) | `SyncNode` + identity; "Leave sync group" on the Relay tab (2) |
| R19 | Loops by hex: HELLO advertises caps `0x003B` incl. bit5 (§5.1 RelayCommands, §12 P3) | `relay/RelayCommands.kt` + service (2) |
| R20 | Scanner hooks: relay adverts → `hubSeen`; screen-off filter (§5.1 BleScanner) | `ble/BleScanner.kt` + service (2) |
| R21 | GATT server always on; STANDALONE gone from the UI (§5.1 service) | service, RelayTab, `VFDRelayScreen` (2) |
| R22 | Hub echo filter, `hubAirAgoS` (§5.5) | service `handleHeard` + `SyncEngine` (2) |
| R23 | Backup rules note (§5.1) | `res/xml/backup_rules.xml`, `data_extraction_rules.xml` comments (1) |
| R24 | Diagnostics per session (§7.3) | `SyncStatus.diag` shown under the card's DETAILS (2) |

---

## 2. Architecture

```
 UI (Compose / VFD)  ── SyncStatus.state (StateFlow<SyncDashboard>) ◄────────────────┐
   RelayTab: SyncDevicesCard     VFDRelayScreen: VFDSyncDevices     notification   │
                                                                                     │
 MagicMakerForegroundService ── boot/shutdown/BT ──►  SyncEngine (HandlerThread "mm-sync")
   handleHeard ─ onHeard/onHubAir (post) ─────────►    ├─ SyncNode (pure engine, port of gen_vectors.Node)
   BleScanner relay adverts ─ hubSeen (post) ─────►    │    ├─ SessionCore per link (P1, frozen)
                                                       │    ├─ AndroidRole (events route, catch-up, HB extras)
                                                       │    └─ uses SyncPorts.data: identity / library / events / roster / estimator
                                                       ├─ LinkChannel per link (framing, 2-lane outbox, flow control)
                                                       ├─ HubClient (GATT central → ESP32 A7830006) ── HubLinkMachine (pure)
                                                       ├─ server endpoint ◄─ RelayGattServer SYNC (binder → post) ── GattServerLinks (pure)
                                                       └─ BatteryInfo (sticky ACTION_BATTERY_CHANGED on mm-sync)

 MagicStore (@Synchronized, leaf lock) ── LibrarySync (pure) ── LedgerStore (pure, P1 Ledger + feed index)
   rows: presets/learnedColors/learnedLibrary/learnedRaw + newwand_names
   files: filesDir/magicmaker_store.json (+ sync section), /sdcard/MagicMaker/magicmaker_library.json (+ sidecar)
 SyncIdentityFile ── noBackupFilesDir/sync_identity.json
```

Part 1 = everything under MagicStore, plus the identity, events and heartbeat models. Part 2 = everything
above it. The seam is `sync/SyncPorts.kt` (§8), which a step-0 run writes before either part starts.

---

## 3. Persistence: formats and locations

### 3.1 Store JSON: `filesDir/magicmaker_store.json`

`MagicStore.PersistedState` gains one nullable field, `sync: SyncStateJson? = null` (Gson leaves it
null for old files). Shape (keys are short; Gson omits nulls):

```json
"sync": {
  "schema": 1,
  "nextSyncSeq": 1235,
  "lastLocalStamp": 1796000000123,
  "ledger": {
    "0:8301E100E90C00010F4D575A940705488BB0": {"u": 1, "c": 3462829778, "s": 12},
    "0:8301E100E90600220F5C57B0": {"u": 1790000000020, "o": "4A1D0B5E77C2903F", "c": 291775751,
                                   "b": "EA0AAIMB4QDpBgAiD1xXsBEIFGxQxKABAAASCEodC153wpA/EwEB", "s": 13, "f": "9F3E0011AABBCCDD"}
  },
  "peers": {"9F3E0011AABBCCDD": {"dbId": "1269208CA2190C2D", "wm": 5600, "excludeOk": true, "lastSyncMs": 1796000001000}}
}
```

- Ledger entry = PROTOCOL §6.1: `u` updatedAt, `o` origin hex (absent for PRESENCE), `c` bodyCrc
  (u32 as a JSON number), `b` canonical body base64 (**absent for PRESENCE**; rebuilt as
  `RecordBody(key, 1).encode()`), `s` syncSeq, `f` syncFrom hex (absent for local entries).
- On load, every entry goes through `LedgerEntry.restore(bodyBytes, s, f)` (decode plus validate), and
  `c` must equal the CRC of `b`. **Any bad entry = corruption** (§3.6 row "corrupt ledger").
- `lastLocalStamp` = P1 `Ledger.lastLocalStamp` (PROTOCOL §5.2).
- The ledger is written in the **same** JSON write as the rows (spec §5.2).

### 3.2 Row fields

`core/MagicModels.kt`: `MagicPacket` adds, as its **last** two constructor parameters,
`var note: String? = null` and `var userEdited: Boolean? = null`. Gson reads them as null from old
files and omits them when null, so 20k raw rows do not grow the file. Positional constructor calls
stay valid. No other `core/` change.

### 3.3 Identity: `noBackupFilesDir/sync_identity.json`

```json
{"v": 1, "deviceId": "4A1D0B5E77C2903F", "dbId": "1269208CA2190C2D", "issuedSeq": 1235,
 "evtEpoch": 1796000015, "groupId": "9F3E…", "groupKey": "32 hex digits",
 "hubAddress": "AA:BB:CC:DD:EE:FF", "foreign": ["11:22:33:44:55:66"], "createdMs": 1796000000000}
```

- `noBackupFilesDir` is excluded from Auto Backup and device transfer by the platform, and deleted on
  uninstall. The group key lives here too (D15 for Android), so a restored phone rejoins by TOFU.
- deviceId and dbId: 8 bytes from `SecureRandom`, regenerated while all-zero. groupKey per
  PROTOCOL §2: discard a key whose groupId is all zero.
- `foreign` holds at most 16 hub MACs (oldest dropped). An unreadable or invalid file counts as
  **missing** (case (a) below).
- Written only through `AtomicFiles.write` (§3.5), under its own lock (a leaf lock), synchronously.

### 3.4 External library copy and its sidecar

- `/sdcard/MagicMaker/magicmaker_library.json` gets **the same JSON bytes** as the internal file
  (sync section included), written atomically after the internal file.
- New sidecar `filesDir/magicmaker_library.ext.json` =
  `{"size": n, "mtimeMs": t, "crc": c}` of the external file just written. It is updated after every
  successful external write (`saveNow`, `exportLibrary`, the seeding write in `load`).
- The sidecar is only a fast "unchanged" check that saves parsing a multi-MB file at every launch.
  The diff (§4.5) is the authority, and an unchanged file diffs to nothing.

### 3.5 Atomic write procedure (`AtomicFiles.write(target, bytes)`)

1. Write `target.tmp` through a `FileOutputStream`, then `flush()` and `fd.sync()`.
2. `tmp.renameTo(target)`. If that returns false, delete the target and rename again (recovery: at
   load a leftover `.tmp` is deleted, and the target is used when present).
3. Any exception leaves the old target intact and returns false (the caller logs it via
   `CrashLog.record`).

**Store save path** (replaces `saveNow`, `MagicStore.kt:303–308`):

- `val snap = synchronized(this) { buildSnapshot() }`. Inside: `buildState()` with the current list
  **references** (rows are never mutated in place: every writer uses `copy()`), plus a deep copy of
  the ledger DTO and peers, plus `seqAtSnapshot = ledger.nextSyncSeq`.
- Outside the store lock, under a separate `writeLock` that `exportLibrary` shares: run
  `gson.toJson(snap.state)`, atomic-write the internal file, then (if allowed) the external file and
  its sidecar.
- Then, in this order: `durableSeq = seqAtSnapshot − 1`, `identity.noteWritten(seqAtSnapshot)`
  (`issuedSeq = max(issuedSeq, seqAtSnapshot)`, which writes the identity file only when it grows),
  then `listener.onDurable(durableSeq)`.
- The store monitor is therefore never held during serialization or disk I/O. This matters because
  sync increases save frequency, and the packet executor takes the same monitor.

### 3.6 Load decision table (`MagicStore.load` + `IdentityReconcile`)

Inputs: internal file I (may be missing or unparseable), external file E (may be missing), identity
file ID (may be missing).

| Case | Action |
|---|---|
| I parses, has `sync`, ID present, `I.sync.nextSyncSeq ≥ ID.issuedSeq` | normal. `durableSeq = nextSyncSeq − 1` |
| I parses, `sync == null` (first P3 launch) | **migrate** (§4.4). Bulk; saved at once |
| I parses, has `sync`, `nextSyncSeq < ID.issuedSeq` (rollback / replaced file) — case (c) | new dbId; every peer `wm = 0`, `excludeOk = false`; `issuedSeq = I.sync.nextSyncSeq` |
| ID missing or invalid — case (a): backup restore, device transfer | new deviceId and dbId; every peer reset as in (c). Ledger kept |
| I missing or unparseable, E parses (reinstall with `/sdcard` kept, or a store lost) | load E fully, **including** its `sync` (migrate if it has none); then new dbId and peers reset as in (c) |
| I has `sync` but the ledger is corrupt (§3.1) | keep the valid entries; new dbId; peers reset; `nextSyncSeq = max(s) + 1` |
| I parses and E differs (sidecar mismatch or missing), and `E.lastModified() > I.lastModified()` | after the I path above: **external diff** (§4.5); E's `sync` is ignored |
| E older than I, or the sidecar matches | E ignored (it will be rewritten by the next save) |
| neither parses | seed presets as today; no ledger entries (built-ins have none); `sync = {schema 1, nextSyncSeq 1}` |

`readBestState()` (`MagicStore.kt:196`) changes accordingly: **the internal file is always the
base** whenever it parses. Today it picks E whenever E's mtime ≥ I's, which is the normal case after
every save. That would silently drop the internal ledger, or re-migrate.

A dbId change happens only here, at load, before any session exists, so the protocol's "a dbId
change closes all sessions" rule needs no runtime path in P3.

### 3.7 Durable bookkeeping

- `durableSeq` (`@Volatile`) is the highest feed seq on disk. It is what pages serve up to, what
  `feedHigh` reports, and what `SyncLibraryPort.durableHigh()` returns.
- `issuedSeq` (identity) is ≥ every seq that has ever left the phone. It is raised in two places: by
  each completed store write (§3.5), and by `identity.ensureIssued(s + 1)` immediately before a live
  REC carrying feed seq `s` is queued (PROTOCOL §15.4).
- **No headroom**: raise to exactly `s + 1`, never more. Headroom would make every ordinary
  process kill look like a rollback at the next load, because issuedSeq would exceed the store's
  nextSyncSeq.

---

## 4. Data layer (part 1)

### 4.1 `LedgerStore` (pure)

Wraps the P1 `Ledger` (unchanged) and adds what a phone needs:

- `feed: TreeMap<Long, String>` (seq → key string), always holding the **current** seq of each key.
  It is updated from every `applyRemote` / `localEdit` / `localLearn` result (remove the key's old seq,
  add the new one) and from `evicted` lists.
- `restore(entries, nextSyncSeq, lastLocalStamp)` from §3.1.
- `servePage(pull, excludeOk, puller, durableHigh): PageResult` = `SyncRouting.servePage` over
  `feed.subMap(pull.since + 1, durableHigh + 1)` values mapped to entries. It is durable-only by
  construction.
- `toJson()` / `fromJson()` via `SyncStateJson`.
- `tombstoneCount()`, `size`, `nextSyncSeq`, `get(key)`.

### 4.2 `LibrarySync` (pure; implements `SyncLibraryPort`)

```kotlin
class LibrarySync(
    rows: RowsAccess,             // MagicStore adapter (tests: FakeRows)
    ledger: LedgerStore,
    identity: SyncIdentityPort,
    saves: SaveSink,              // fun requestSave(urgent: Boolean)
    lock: Any,                    // MagicStore instance (tests: any object)
    clock: () -> Long,            // wall ms
) : SyncLibraryPort
```

- `RowsAccess`: get and set `presets`, `learnedColors`, `learnedLibrary`, `learnedRaw` and
  `newWandNames: Map<String, String>`; `allocId()` (`nextPacketId++`);
  `learnFromSync(hex: String): Boolean` (the store's learn routine with `fromSync = true`, §4.3);
  `bumpRevision()`; `rebuildRawIndex()`.
- `SaveSink.requestSave(urgent)`: MagicStore → `save()` (urgent: also skips the raw-save coalescing).
  `LibrarySync.onSaved(seqAtSnapshot)` is called by the store after a completed write and fires
  `onDurable`.
- Every public method runs `synchronized(lock)`. Listener callbacks may run while the lock is held;
  the contract (§8) is that listeners only post.
- **Local-edit hooks** (called by MagicStore inside its synchronized mutators; each applies the same
  projection as the matching remote class, so the local rows always equal the ledger's projection):
  `onUserEdit(hex, label, category, note)` (USER or RESET), `onSavePreset(hex, label, userTyped)`
  (USER\|PRESET), `onDelete(hexes, bulk)` (TOMBSTONE per syncable key), `onLearned(hex)` (PRESENCE iff
  no entry), `isTombstoned(hex)`, `onNewWandName(hex, name)` (NEWWAND),
  `onDiff(edits: List<LocalEditOp>)` (bulk).
- Body building for USER = full state (PROTOCOL §4.5). `label` = `SyncText.normalizeLabel`;
  `category` from `MagicCategory` (SHOW 1, ANIMATION 2, COLOR 3, UNKNOWN 0); `kind` =
  `SyncText.normalizeKind(row.typeInfo)`; `place` = the row's list (presets 1, colors 2, library 3, raw
  4; first in that order when the hex is in several); `note`; PRESET bit = a user preset row exists for
  the hex; USER_EDITED = the label was typed, or the category was changed by the user. The normalised
  label and note are written back into the rows **before** the record is built (spec §2.2).
- After a local entry is stored: `listener.onLocalChanges(listOf(entry), bulk)` (bulk for migration,
  diff/import, `clearLearnedStarlight`, multi-key deletes), and `saves.requestSave(false)`.

### 4.3 Projection (spec §2.6; Android specifics)

- **Live** `applyRemote(..., live = true)` projects the one key at once and calls
  `requestSave(false)`. **Page** records are only stored in the ledger; their keys queue in
  `pendingProjection`. `commitPage` projects all queued keys in **one pass per list** (index the
  queued hexes, map each list once), calls `bumpRevision()` once, stores the peer, then
  `requestSave(true)`.
- TOMBSTONE (LIB): remove every learned row and every user preset row with the hex; reset a built-in
  preset row to its `PresetCatalog` label and category (`userEdited = null`, `note = null`).
  `rebuildRawIndex()` when raw rows changed.
- USER (LIB): on all rows with the hex set label, category, `typeInfo = kind ?: row.typeInfo`, note,
  and `userEdited = true`. PRESET set and no user preset row → add one (`userRecorded = true`, colors
  and simKey from `MagicClassifier.classify(hex)`, else `colors = ""`, `simKey = "USER:$hex"`). PRESET
  clear → remove the user preset row. No row at all → create one in `place` (raw:
  `simKey = "RAW:$hex"`, `typeInfo = "raw"`).
- RESET: on all rows label and category = `derived(hex)`, `userEdited = null`, note = record note. No
  row → as PRESENCE.
- PRESENCE: a row exists → nothing. Else `rows.learnFromSync(hex)`. It declines (ping, built-in
  duplicate by `libraryDedupeKey`, raw/unclassified, noise) → keep the entry, create no row, and
  count `skippedPresence`.
- NEWWAND: set or remove `newwand_names[HEX]` in the `magicmaker` prefs (the same JSON format as
  `saveNewWandName`, `ui/MagicMakerScreens.kt:1750`).
- `derived(hex)` = the built-in preset label/category if the hex is a `PresetCatalog` hex, else
  `MagicClassifier.classify(hex)`, else `MagicClassifier.rawLabel(hex)` / UNKNOWN.
- `learnFromSync` (MagicStore) runs `addClassifiedToLibrary` with `fromSync = true`. That means no
  ledger entry (the entry already exists), no `cloudSync`, no `starlight_serial` pref write
  (`libraryPacketFrom`, `MagicStore.kt:876`), no rssi and no recording.

### 4.4 Migration (schema 0 → 1, once; `LibraryMigration`, pure)

- **Generated label**: equals `derived(hex).label`; or equals `MagicClassifier.rawLabel(hex)` or the
  `rawPacketLabel` forms (`"Raw: $h"`, `"Raw: ${h.take(16)}…${h.takeLast(4)}"`,
  `MagicStore.kt:866`); or the row's `typeInfo == "imported"` (cloud dictionary labels; D-P3-8).
- Per canonical hex, visited in the order presets, colors, library, raw, then `newwand_names`:
  - a user preset row, or any row whose label is not generated or whose category differs from
    `derived`: USER, `u = 2` (`LEGACY_USER_ANDROID`), `o = self`, body from the **first qualifying
    row** in list order, PRESET bit iff a user preset row exists; that body is then projected onto all
    rows with the hex (they get the same label, category and `userEdited = true`);
  - else a row in colors or library: PRESENCE;
  - raw rows with generated labels and built-in preset rows: no entry;
  - `newwand_names` entries: NEWWAND, `u = 2`, label = the name.
- syncSeq 1..N in that visit order. One save. `onLocalChanges(all, bulk = true)` (not pushed live;
  the on-change HB makes peers pull).
- Cost: one pass over ≤ 20k rows. Raw rows check the raw-label forms before calling `classify`. It
  runs inside `MagicStore` init on the main thread at `Application.onCreate`, as the JSON load already
  does; it is ≤ ~200 ms once.

### 4.5 External diff and import (`LibraryDiff`, pure)

`diff(internal: LibraryRows, external: LibraryRows, ledger): List<LocalEditOp>`, by canonical hex:

| External vs internal | Op |
|---|---|
| hex in both; label, category or note differ | USER (RESET if the new label is generated or blank) |
| user preset added / removed for a hex | USER with PRESET set / USER with PRESET clear |
| hex only internal, key syncable | TOMBSTONE |
| hex only internal, not syncable (unedited raw, built-in) | remove the rows only (built-ins come back through `mergeBuiltInPresets`) |
| hex only external, classifies | learn path (PRESENCE) + USER if its label is not generated |
| hex only external, raw | add a raw row (+ USER if its label is not generated) |
| `newwand_names` key added / changed / removed (from E's `settings` snapshot) | NEWWAND set / set / deleted |

- All ops are stamped `now`, `origin = self`, and are bulk. Non-library state of E (autoRules,
  settings/prefs, lab, starlight serial) is applied as `applyState` does today.
- `importLibrary()` (`MagicStore.kt:332`) runs the same diff instead of replacing state. The identity
  is not reset (spec §5.2: nothing was rolled back).

### 4.6 Auto-relabel fix (spec §5.4)

- `addShowAnimToLibrary` (`MagicStore.kt:835–848`): never rewrite `hex`. Update `label` only when
  `existing.userEdited != true` and the classifier label changed. Never touch the ledger.
- `updateLearnedColor` (`MagicStore.kt:898`): match by **canonical hex** (not `simKey`) and never
  change `hex`. Update `label` only when `userEdited != true`; colors and `wandVerified` as today.
- The decision lives in `LibraryRows.relabelOnRehear(existing, classified): MagicPacket` (pure,
  tested).

### 4.7 MagicStore mutation points (every one; line numbers as of this plan)

| Function (line) | Today | P3 sync action |
|---|---|---|
| `init` seeding (152–159) | seeds built-ins | none (built-ins have no entry) |
| `mergeBuiltInPresets` (166) | adds missing built-ins | none |
| `load` / `readBestState` / `applyState` (182 / 196 / 210) | newer file by mtime wins; replace | §3.6 table; migration; external diff; ledger restore; identity reconcile |
| `buildState` / `save` / `saveNow` / `writeExternal` (235 / 288 / 304 / 310) | non-atomic, serialize under lock | §3.5: snapshot under lock, atomic writes, sidecar, durable + issuedSeq, `onDurable` |
| `exportLibrary` (323) | writes E | atomic, includes `sync`, updates sidecar |
| `importLibrary` (332) | replace from E | diff as edits (§4.5) |
| `applyLabLabelToMatchingRaw` (430, **not** synchronized today) | relabels one raw row | make `@Synchronized`; label applied to all rows with the hex; `onUserEdit` USER |
| `saveCustomPreset` (443) | replaces the user preset with the same hex | `onSavePreset` USER\|PRESET (beats a tombstone); `userTyped = label.isNotBlank()` |
| `deleteCustomPreset` (480) | removes the preset row | `onDelete([hex])` TOMBSTONE + projection (all rows with the hex) |
| `recategorizePacket` (488) | first list holding the id | resolve the hex; category applied to all rows with it; `onUserEdit` USER |
| `renamePacket` (505) | first list; blank ignored | resolve the hex; all rows; blank → RESET (D-P3-7) |
| `deletePacketById` (524) | dispatches | unchanged (the callees act) |
| `deleteSavedBands` (557) | removes raw noise | no tombstones (spec §2.7) |
| `processHeardPacket` (600) | learn + log | unchanged; the learn callees act |
| `importCloudEntries` (667) | adds cloud rows | per added row: skip if tombstoned; `onLearned` (PRESENCE) |
| `addClassifiedToLibrary` / `Inner` (696 / 704) | dispatch | add a `fromSync: Boolean = false` parameter, passed down |
| `hearRawPacket` (720) | learns unknown raw | skip if `isTombstoned(hex)` (an edited raw row that was deleted); no entry for new raw |
| `importHexesToLibrary` (766) | bulk import | classified: through the learn path (PRESENCE); raw: no entry; tombstoned: skipped; bulk |
| `addStarlightToLibrary` (801) | learns starlight | tombstone check; new row → `onLearned` unless `fromSync` |
| `addColorToLibrary` (821) | learns colors | same |
| `addShowAnimToLibrary` (835) | learns or **relabels** | same + §4.6 |
| `updateLearnedColor` (898) | matched by simKey, rewrites hex/label | §4.6 |
| `deleteLearnedColor` / `Library` / `Raw` (1028 / 1035 / 1042) | hard delete | `onDelete([hex])` (TOMBSTONE iff syncable; projection) |
| `clearLearnedStarlight` (1050) | removes starlight rows | `onDelete(all starlight hexes, bulk = true)` |
| **new** `setNewWandName(hex, name)` (step 0 stub, §8.2) | prefs only | `onNewWandName` NEWWAND (blank = DELETED); prefs as today |
| **new** `setNote(id, note)` | — | USER if the row is userEdited, else RESET + note (no UI in P3; the iPhone sets notes) |
| **new** `val sync: SyncLibraryPort` | — | the `LibrarySync` instance |

Callers outside MagicStore keep their calls. Relay-command callers
(`MagicMakerForegroundService.kt:1401` `saveCustomPreset`, `:1416` `deleteLearnedColor`, `:1435`
`clearLearnedStarlight`) need no change. New-wand UI call sites move to `store.setNewWandName` (part 2,
§5.8): `ui/MagicMakerScreens.kt:1680` and `ui/vfd/VFDWandScreen.kt:685`.

### 4.8 Events model (`EventOrigin`, pure; implements `EventOriginPort`)

- **Epoch** (spec §2.8): `SyncData.startEventOrigin(nowMs, ringCap)` sets
  `epoch = max(nowMs / 1000, identity.evtEpoch + 1)`, persists it before returning, and starts
  `seq = 0`.
- **Coalescer** per canonical hex (spec §5.7):
  - The first sighting with no open window emits at once (count 1) and opens a window that ends at
    `monoMs + W`, with W = 1,000 ms (3,000 ms while `setWideWindow(true)`).
  - Sightings inside the window are counted. At the window end, if n ≥ 1 were counted, one event
    goes out with `count = n`, `rssi = max`, `ts` = the last wallMs, the last fix and the last address.
  - At most 256 open windows (LRU; evicting a window flushes its pending event).
- Each emitted event takes the next seq and is appended to the ring (capacity `ringCap`, oldest
  dropped) **before** it is returned. Fields: lat/lon in 1e-7°, acc in metres; all three or none.
  `addr` from `"AA:BB:…"`; `flags` bit0 = tagged own band.
- `catchUp(requester, epoch, afterSeq, monoMs)`:
  - returns null when an identical `(requester, epoch, afterSeq)` was answered less than 5,000 ms ago
    (PROTOCOL §8.5);
  - otherwise records the time and maps `SyncEvents.replayPlan(ringIds, epoch, seq, epoch, afterSeq)`
    to `CatchUpItem`s. Replays are the stored `Evt` with flags | REPLAY and empty seenBy; gaps are an
    `EvtGap` with `requester`.
- `originate(...)` issues one event without coalescing, for tests and the transcript replay.

### 4.9 Heartbeat model (`HeartbeatModel.kt`, pure)

- `RuntimeEstimator : RuntimeEstimatorPort` (spec §9.4): one sample `(t, pct)` per ≥ 60 s, kept 60
  min; reset on a charging change. While discharging with Δpct ≥ 3 over ≥ 10 min: least-squares
  slope `rate`, `runtimeMin = pct / rate`, clamped to 0..5999. Otherwise −1.
- `DeviceRoster : DeviceRosterPort` (PROTOCOL §16.4):
  - stores the latest HB per deviceId using `SyncRouting.hbReplaces`;
  - updates `lastAnyMs`, `lastDirectMs` (hops 0 and `hb.deviceId == fromPeer`) and
    `lastViaMs[fromPeer]` for every copy, replaced or not;
  - `forget()` removes a device.

### 4.10 `SyncDataModule` and app start

- `SyncDataModule(identity, store) : SyncData`: `identity` = the `SyncIdentityFile` that MagicStore
  loaded, `library = store.sync`, plus factories for `EventOrigin`, `RuntimeEstimator` and
  `DeviceRoster`.
- `MagicMakerApp.onCreate`: `store = MagicStore(this)`, then
  `SyncPorts.install(SyncDataModule.create(this, store))`.
- MagicStore loads the identity itself (it needs it for §3.6) and exposes it as `internal val syncIdentity`.
- `res/xml/backup_rules.xml` and `data_extraction_rules.xml`: add an XML comment saying that sync
  identity lives in `noBackupFilesDir` and must never move. No rule change.

---

## 5. Runtime (part 2)

### 5.1 `SyncNode` (pure engine)

`SyncNode` is a Kotlin port of `tools/sync/gen_vectors.py` `class Node` (lines 1767–2227). That code
is the executable model of node behaviour that produced the transcripts. Kind-specific behaviour goes
through `NodeRole`: `AndroidRole` lives in main; `IosStandInRole` and `HubStandInRole` live in test
sources, ported from the same class (§10.2).

```kotlin
class SyncNode(
    val cfg: NodeConfig,               // deviceId, kind, maxMsg, version (≤16 B), name (≤20 B, SyncText.normalize)
    val identity: SyncIdentityPort,
    val library: SyncLibraryPort,
    val roster: DeviceRosterPort,
    var events: EventOriginPort?,      // Android only; replaced on service restart
    val sched: SyncScheduler,          // now(): mono ms; wallMs(); at(t, task): Cancel
    val role: NodeRole,
    val self: () -> SelfStatus,        // battery, runtime, state bits, hubAirAgoS (read on mm-sync)
    val policy: NodePolicy,            // HB on-change triggers; bulk window; NodePolicy.TRANSCRIPT for replay
    val nonces: (linkId: String) -> Bytes,
    var bootId: Int,
)
```

**Inputs** (all on mm-sync; production posts everything to it, tests call inline):
`linkUp(link: LinkPort, role, mtu, peerKindHint)`, `linkDown(linkId)`, `onMessage(linkId, bytes)`,
`onLocalChanges(entries, bulk)`, `onDurable(high)`, `onSighting(HeardSighting)`, `originate(...)`
(tests), `onEventsTick()`, `onHubAir(monoMs)`, `selfChanged()`, `leaveGroup()`,
`serviceRestart(bootId, events)` (tests), `snapshot(): NodeSnapshot` (for `SyncStatus`).

**Outputs**: `LinkPort.send(type, bytes, lane)`, `LinkPort.disconnect(reason, retryMs)`, plus
callbacks `onGroupChanged(group)` (re-advertise) and `onForeign(linkId)` (HubClient: mark and forget
the MAC).

Behaviour, mirroring the Python node:

- **Link up**: create `SessionCore(SessionConfig(role, deviceId, kind = 2, bootId, maxMsg = 1024,
  version, name, peerKind = hint), ctx)`. Sessions are kept in a `LinkedHashMap` in attach order, which
  is also the order of HB `link` entries (≤ 4). Then feed `SessionInput.LinkUp(mtu)`.
- **PULL** → `library.servePage(pull, ps.excludeOk, peer)` → send the RECs, then PAGE_END. If
  `more = 0`: `ps.excludeOk = true` and `servedTo[peer] = scannedTo`.
- **REC**:
  - body error → `Err(BAD_MSG or CLOCK, refType 0x03, key)`;
  - else `library.applyRemote(body, peer, wallNow, live = reqId == 0)`, then by status:
    - ACCEPT live → forward per `SyncRouting.routeLiveRec` with `seq = entry.seq` and merged seenBy,
      after `identity.ensureIssued(entry.seq + 1)`;
    - ACCEPT page → `pageAccepted = true`;
    - DUPLICATE / STALE → nothing;
    - BAD_MSG / CLOCK → ERR as above.
- **Commit(wm)** → `library.commitPage(peer, ps, wallNow)`.
- **HB**:
  - `roster.onHb(hb, peer, now)`;
  - a direct HB (hops 0, `deviceId == peer`) is forwarded raw with hops patched to 1
    (`SyncMsgs.hbSetHops`) to `SyncRouting.routeHb` targets. The node keeps the raw rx bytes of the
    input being handled, as the Python node's `_rx_raw` does;
  - the `role.onHb` hooks run.
- **Local changes** (`onLocalChanges`): if not `bulk` and the trailing-1 s count of local entries
  (this one included) is ≤ 4, push each one per `SyncRouting.routeLocalRec`, after
  `identity.ensureIssued(e.seq + 1)`. Otherwise set `bulkPending = true`.
- **onDurable**: if `pageAccepted` or `bulkPending` was set, clear it and `requestHb()`.
- **Heartbeats**:
  - `buildHb()`: `hbSeq + 1`, ts = wall, uptimeS, battery fields, version, name, links
    (`peerId`, `peerKind`, flags `SYNCED` when that session is SYNCED, `TX_READY` when peer caps
    bit3), state bits, hops 0, `feedHigh = library.durableHigh()`, `dbId`, `records`, and Android's
    `hubAirAgoS` (0xFFFF = never, capped at 0xFFFE);
  - `NodeRequest.SEND_HB` sends on that one session;
  - `requestHb()` schedules one round at `max(now, lastHbT + 5,000)` to every AUTHED+ session whose
    peer subscribed to heartbeats.
  - **Production on-change triggers** (`NodePolicy.PRODUCTION`, spec §9.2): a session entering or
    leaving AUTHED+ or SYNCED; charging change; battery 1 % step; crossing 20 % or 10 %; state bits;
    `pageAccepted` / `bulkPending` durable. `NodePolicy.TRANSCRIPT` keeps only the last one, so replays
    match the simulation.
- **Group**: a `Group` action → `identity.setGroup(g)` (persisted before anything else), then, after
  the current action list, every *other* session gets `Rekey` (if `rekey` and AUTHED+) or
  `GroupChanged`, then `onGroupChanged(g)`. `leaveGroup()` → `identity.setGroup(null)` →
  `GroupChanged` to all sessions (they disconnect `left_group`) → re-advertise with tag `00 00`.
- **Node requests**: FOREIGN → `onForeign(linkId)`; EVT_SINCE → `role.sendEvtSinceAll` (iPhone
  stand-in only).

`AndroidRole` (events, spec §3.9, PROTOCOL §16.3):

- `route()` = `SyncRouting.androidEventRoute(self, ios, hub, hubHbAgeMs, hubHbLinks)`. `ios` = the
  AUTHED+ session with peer kind 3 (subscribed = peer subs bit1); `hub` = the AUTHED+ kind-1 session;
  `hubHb` = time and links of the hub's last **direct** HB.
- `onSighting` → `events.onSighting(s)` → for each event, route 1/2: `send(EVT with seenBy)`; route
  3: ring only. `onEventsTick` drains `events.tick(now)`. `SyncEngine` keeps one `sched.at` armed at
  `events.nextDueMs()`.
- Catch-up runs on an EVT_SINCE whose `origin == self`, and on any HB of kind 3 (direct or forwarded)
  whose `evtWm` for `self` is behind (`epoch < cur`, or the same epoch with `seq < curSeq`). It calls
  `events.catchUp(requester, epoch, afterSeq, now)`; null → skip; else, for the current route, send
  every item in lane 1. Route 3 → drop.
- Pacing: count EVT per link per second. Above 20/s → `events.setWideWindow(true)`; below 10/s for
  5 s → false.
- EVT / EVT_GAP / foreign EVT_SINCE arriving at Android → count and drop.

### 5.2 How the P1 `SessionCore` is driven

1. **One `SessionCtx` per session.** Right before every `handle()` the node refreshes it from node
   state: `group = identity.group`, `dbId = identity.dbId`, `feedHigh = library.durableHigh()`,
   `ready = true`, `clock = { wallNow() }` (tests: `{ t -> clockBase + t }`),
   `nextNonce = { nonces(linkId) }` (production: `SecureRandom` 8 bytes). `peers` is **the node's
   one shared map**, seeded from `library.loadPeers()`.
2. `acts = core.handle(t, input)`. Here `t = sched.now()` for every input **except timers, which
   carry `t = due`**: the core ignores a timer whose armed due time is not exactly `t`
   (`SyncSession.kt` `handle`), and a Handler callback always runs a little after its due time.
3. Execute the actions in order: Send → `link.send(type, bytes, lane 0)`; State → status and HB
   triggers; Deliver → the handlers above; Commit → `commitPage`; Group → deferred (step 5); Node →
   SEND_HB / EVT_SINCE / FOREIGN; Disconnect → `link.disconnect`.
4. Re-sync timers: for each `(name, due)` in `core.snapshot().timers` not already scheduled for that
   exact pair, `sched.at(due) { input(linkId, SessionInput.Timer(name), t = due) }`.
5. Run the deferred group propagation. Then, if any `PeerState` differs from the last persisted copy,
   call `library.putPeer` (dbId resets, `excludeOk`). wm is persisted by `commitPage`, never ahead of
   its data.
6. Mark `SyncStatus` dirty.

### 5.3 Transport abstraction: `LinkChannel` (pure)

```kotlin
interface FrameLink {                       // implemented by HubClient, the server endpoint, test pipes
    val id: String                          // "hub:AA:BB:CC:DD:EE:FF" / "ios:<address>"
    val role: SessionRole
    fun mtu(): Int
    /** Send one ATT value (≤ mtu − 3 bytes). At most one outstanding; completion via onFrameSent. */
    fun writeFrame(frame: ByteArray): Boolean
    fun close(reason: String)
}
```

Per link, created at link-up:

- **Framing**: one `Fragmenter` (TX) and one `Reassembler(1024)` (RX), both counters at 0 at
  link-up.
- **Inbound**: for each `FrameEvent` from the reassembler:
  - `Deliver` → `node.onMessage`;
  - `BadFrame` → count it (and send `ERR{BAD_FRAME}` at most once per 10 s);
  - `ErrTooBig(ref)` → send `Err(TOO_BIG, ref)`;
  - `ErrProto` → send `Err(PROTO)`.
- **Outbox**: whole messages in two lanes. Lane 0 is FIFO and carries everything except replays.
  Lane 1 carries replay EVTs and EVT_GAPs from catch-ups, so a plan stays in order. It drains only
  when lane 0 is empty, through a token bucket of 20 EVT/s minus the live EVTs of that second.
- **Fragmenting**: a message is fragmented when it starts (`fragment(msg, mtu())`). Its frames go
  strictly in order, and the next message never starts before the last frame of this one, so frames
  of different messages never interleave.
- **Flow control**: one frame in flight. The next is sent on `onFrameSent`. A frame not acknowledged
  within 5 s → `close("stall")` → link down.
- **MTU**: the chunk is `mtu − 5` (`SyncFrames.chunkSize`). An `onMtu` change applies from the next
  message. The session's pull profile is fixed at link-up (MTU < 64 → limit 8 / 512 B).
- **Bounds**: lane 0 overflows past 256 messages → `close("outbox")` (pulls heal it); lane 1 is capped
  at 2,000 (oldest dropped).
- `pendingLive()` = live RECs still in lane 0, used by `SyncStatus`.
- No GATT callback ever touches a `LinkChannel` directly: callers post to mm-sync first.

### 5.4 HubClient (Android as GATT central)

`HubLinkMachine` (pure) holds all decisions; `HubClient` performs the `BluetoothGatt` calls.

- **Discovery**:
  - The service forwards relay adverts from `BleScanner` (§5.7) as `hubSeen(address, name, rssi)`
    when the name starts with `MM_ESP` or `MagicMaker-ESP32`. Adverts carrying the `MM_AND` tag
    (other Androids) are ignored. No extra `startScan`.
  - No known hub: connect to the strongest unseen, non-foreign candidate.
  - Known `identity.hubAddress`: keep `connectGatt(autoConnect = true)` pending. When `hubSeen`
    reports it, switch to a direct `autoConnect = false` attempt.
  - Use `connectGatt(ctx, auto, cb, TRANSPORT_LE, PHY_LE_1M_MASK, syncHandler)` (API 26+) so callbacks
    arrive on mm-sync.
- **Setup**: `requestMtu(247)` → `discoverServices()` → service `A7830001`, characteristic SYNC
  `A7830006` → `setCharacteristicNotification(true)` + CCCD `01 00` → link up with the negotiated MTU
  and `peerKindHint = 1`.
- **Op queue**: one outstanding GATT op, 5 s timeout. Frame writes use write-without-response.
  API 33+: `writeCharacteristic(chr, value, WRITE_TYPE_NO_RESPONSE)` returns a status; on
  `ERROR_GATT_WRITE_REQUEST_BUSY` retry after 20 ms. Older APIs: set `value` and `writeType`, then the
  boolean call. The next write waits for `onCharacteristicWrite`, which maps to `onFrameSent`.
- **Notifications**: override both `onCharacteristicChanged` variants. On API 33+ handle only the
  value-carrying one. Copy the bytes at once.
- **No SYNC characteristic** (firmware < 2.0): disconnect at once and mark
  `noSync[address] = now`. No re-probe of that address for 30 min (landed firmware stops advertising
  while any phone is linked, so holding the link would hide the ESP32 from the iPhone). The status
  shows `NO SYNC FW`.
- **Errors**: status 133 or any failure → `gatt.close()`, back off 1, 2, 5, 10, 30 s (a disconnect
  `retryMs` from the session raises the floor). Always `close()` on disconnect.
- **FOREIGN**: `identity.markForeign(address)`; if it was the hub address, `setHubAddress(null)`.
  **First AUTHED** on a hub link: `setHubAddress(address)`.
- Connection priority is left at the default (BALANCED, matching the hub's 30–50 ms request). Never
  request HIGH.

### 5.5 RelayGattServer SYNC (direct peer for the iPhone)

`relay/RelayProtocol.kt`:

- add `SYNC_UUID = "A7830006-0000-1000-8000-00805F9B34FB"` and
  `CCCD_UUID = "00002902-0000-1000-8000-00805F9B34FB"`;
- add `relayTagBytes(groupId: ByteArray?)` = `"MM_AND"` plus `groupId[0..1]` (`00 00` when
  ungrouped). Keep the no-argument form.

`relay/RelayGattServer.kt`, all through a `SyncServerEndpoint` that `SyncEngine` implements (callbacks
copy the bytes and post to mm-sync; the binder thread never blocks):

- Add the SYNC characteristic (`WRITE | WRITE_NO_RESPONSE | NOTIFY`, `PERMISSION_WRITE`) with a CCCD
  descriptor (`PERMISSION_READ | PERMISSION_WRITE`).
- `onDescriptorWriteRequest` (always `sendResponse` when needed): `01 00` → link up (MTU = the last
  `onMtuChanged` for that device, else 23, `peerKindHint = null`); `00 00` → link down.
- `onDescriptorReadRequest` → the stored value. `onMtuChanged` → endpoint `onMtu`.
  `onNotificationSent` → `onFrameSent`.
- SYNC `onCharacteristicWriteRequest` → copy → `onFrame`; `GATT_SUCCESS` if a response is needed;
  prepared writes are refused.
- `onConnectionStateChange` DISCONNECTED → link down for that device. `cancelConnection(device)`
  implements `close`.
- Notify: API 33+ `notifyCharacteristicChanged(device, chr, false, value)` (status; retry busy after
  20 ms); older APIs set `chr.value` then make the boolean call (safe, because only mm-sync calls it).
- Per-device state (connected, MTU, CCCD, session link id) lives in `GattServerLinks` (pure, tested).
- **Advertising**, decided by `RelayAdvPolicy` (pure):
  - primary ADV = flags + 32-bit service UUID + service data `relayTagBytes(groupId)`
    (3 + 6 + 14 = 23 B); the scan response repeats the service data;
  - LOW_LATENCY for 60 s after start or after a disconnect, then BALANCED (a restart);
  - **off while any central is connected**;
  - still paused for manufacturer bursts and keep-awake (`pause/resumeConnectableAdvertising`; resume
    only when the policy allows);
  - re-advertise on a group change.

### 5.6 `SyncEngine` (Android wrapper)

- Owns a `HandlerThread("mm-sync")` and a `HandlerScheduler`: `now()` = `SystemClock.uptimeMillis()`,
  `at(t)` = `postAtTime(task, token, t)`, `wallMs()` = `System.currentTimeMillis()`.
- Owns `SyncNode`, the `LinkChannel`s, `HubClient`, the server endpoint and `BatteryInfo`, and
  publishes `SyncStatus`.
- `start(service, data: SyncData, selfState: () -> ServiceSelfState)`: `bootId` = random u16;
  `events = data.startEventOrigin(wallNow, 2000)` when "Share heard packets with iPhone" is on (pref
  `sync_share_heard` in `magicmaker`, default true); `roster = data.newRoster()`; peers from
  `loadPeers()`; `library.setListener` (each callback posts); register the battery receiver on the
  mm-sync handler.
- `stop()`: close every link, unregister, quit the thread. Bluetooth off → all links down; Bluetooth on
  → HubClient resumes (the service re-runs `restartRelay`).
- Public, thread-safe (post-only) API used by the service: `onHeard(hex, rssi, address, loc,
  isBand)`, `onHubAir(address)`, `hubSeen(address, name, rssi)`, `onRelayLinked(linked)`,
  `serverEndpoint`, `leaveGroup()`, `setShareHeard(on)`.
- `BatteryInfo` reads `BatteryManager.getIntProperty(BATTERY_PROPERTY_CAPACITY)`, the sticky
  `ACTION_BATTERY_CHANGED` (`EXTRA_VOLTAGE` mV; `EXTRA_STATUS` / `EXTRA_PLUGGED` → charging) and
  `PowerManager.isPowerSaveMode` (state bit5). It feeds `RuntimeEstimator`, and changes call
  `node.selfChanged()`.
- State bits from `ServiceState.state.value`: bit0 `scanActive`, bit1 `keepAwakeActive`, bit2
  `txLoopEnabled`, bit3 `starlightLoopEnabled`, bit4 `randomShowEnabled`, bit5 power save, bit6
  transmit busy. The other bits stay 0 on Android.

### 5.7 Service, scanner, protocol and commands (exact edits)

`service/MagicMakerForegroundService.kt`:

- `boot()` (480): after `restartRelay()`, `SyncPorts.data?.let { syncEngine = SyncEngine(...).also {
  it.start(...) } }`. `shutdown()` (1567): `syncEngine?.stop()`.
- `BleScanner(...)` (525–532): add `onRelayAdvert = { address, name, rssi -> syncEngine?.hubSeen(address, name, rssi) }`.
  The existing `onEsp32Heartbeat` lambda also calls `syncEngine?.onHubAir(address)`.
- `handleHeard` (1111):
  - the own-ESP32 echo check (1125) also matches `identity.hubAddress` and calls `onHubAir`;
  - after `ServiceState.appendLive` (non-echo path), call `syncEngine?.onHeard(hex, rssi, address,
    loc, isBand)`. It is a post, so it never blocks the packet executor.
- `restartRelay()` (1201): **always** `startGattRelay(handlers)`; WiFi mode adds HTTP.
  `loadPrefs()` (1591) maps a stored `STANDALONE` to `BLE_GATT`. `startGattRelay` (1266) passes
  `syncEngine?.serverEndpoint` and the current group tag.
- `notification(text)` (1703): append `SyncStatus.state.value.notificationToken` (§5.8). SyncEngine
  status changes call `refreshNotification()` (the existing 800 ms throttle).
- `relayCommandHandlers()` (1300; `setStarlightLoop` 1348, `setTxLoop` 1365): accept the new
  hex/label form (below).
- The systemEventsReceiver Bluetooth branch (273–285): STATE_OFF → `syncEngine?.bluetoothOff()`.

`ble/BleScanner.kt`:

- constructor gains `onRelayAdvert: ((address: String, name: String?, rssi: Int) -> Unit)? = null`;
- `handleResult`: in the `skipRelay` branch (96–102), call it with `record.deviceName` before
  returning;
- `scanFilters(screenOn = false)` adds `ScanFilter.Builder().setServiceUuid(ParcelUuid(A7830001))`
  while no hub address is known (a provider lambda). No forced scan restart when that changes;
- do not touch the Esp32Heartbeat lines.

`relay/RelayCommands.kt`:

- `set_tx_loop` / `set_starlight_loop` (95 / 88) accept `hex`, `intervalMs` and `label`.
  `Handlers.setTxLoop` / `setStarlightLoop` gain `hex: String?, label: String?`;
- the service resolves the hex by canonical hex to a library packet id, or else runs the hex as given
  (`txLoopHexOverride`);
- `status` reports `caps` 0x003B.

### 5.8 Sync state and the SYNC/DEVICES card

`sync/SyncStatus.kt`: `object SyncStatus { val state: StateFlow<SyncDashboard> }`. The engine
recomputes it on mm-sync at most every 250 ms when dirty, and every 1 s while visible (ages tick).
`SyncStatusBuilder.build(node.snapshot(), roster, library.stats(), esp32Advert, relayLinked, monoNow)`
is pure and tested.

Rows: **IPHONE**, **ESP32**, **THIS PHONE** (an unknown device row is shown once it has been seen:
PeerState, HB or advert).

| Column | Rule |
|---|---|
| battery | from the device's latest HB: `81%`, `CHG`, ESP32 `3.91V`, runtime `~5H` (`Esp32Heartbeat.runtimeText` style). ESP32 with no HB: from `ServiceState.esp32Battery` (advert, read-only use). THIS: `BatteryInfo` + estimator. `--` unknown |
| age | seconds since the last HB on any path (`4S`, `12S`, `3M`); `LOST` after 10 min; `--` never. ESP32 advert-only: age of the advert |
| path | `DIRECT` (direct HB ≤ 90 s), `VIA IPHONE` / `VIA ESP32` (a forwarded copy ≤ 90 s), `DIRECT+VIA` (both), `AIR` (ESP32 heard only in adverts), `--` |
| sync | the badge below |

Badge per peer P (first match wins):

1. Link issues: FOREIGN → `OTHER GROUP`; INCOMPATIBLE → `UPDATE APP` (iPhone) / `UPDATE FW` (ESP32);
   NOGROUP → `NO GROUP`; HubClient `noSync` → `NO SYNC FW`; iPhone connected to the GATT server
   (`relayLinked`) with no SYNC session after 10 s → `UPDATE APP`; P's HB state bit9 → `HUB FULL`.
2. Session LINKED / HELLO_X → `LINKING`.
3. Session SYNCING, or SYNCED with N > 0 → `SYNCING N`. Here N = `max(0, P.feedHigh − wm)` +
   `max(0, durableHigh − servedTo[P])` + `pendingLive(P)`, and P.feedHigh is the highest of HELLO,
   PAGE_END and HB values.
4. Session SYNCED and N = 0 → `IN SYNC`.
5. No session: P's latest HB ≤ 90 s old, its `records` equal ours, and its link to the forwarder has
   the synced flag → `IN SYNC` (path shows VIA). A fresh HB with different records →
   `BEHIND |Δrecords|`. No fresh HB but P was ever synced or heard → `BEHIND`. Nothing ever → `NEVER`.

THIS PHONE: `records` (ledger size) and `SAVING` while `nextSyncSeq − 1 > durableHigh`. Header:
`ALL IN SYNC` iff every known device is `IN SYNC` and nothing is unsaved, else the first problem, or
`NOT LINKED`. Group short id: `GRP 9F3E` (the last 4 hex digits of groupId) or `NO GROUP`.

Text forms (one line per device, spec §9.7):

```
SYNC / DEVICES                       ALL IN SYNC · GRP 9F3E
IPHONE   81% CHG          4S  DIRECT+VIA   IN SYNC
ESP32    68% 3.91V ~5H   12S  DIRECT       SYNCING 12
THIS     54% ~3H              1234 REC     IN SYNC
```

- **Classic** (`ui/SyncDevicesCard.kt`): a card at the top of `RelayTab`
  (`ui/MagicMakerScreens.kt:2243`). Cyan text when in sync, Amber for problems, using the existing
  `techLabel`/`techHeader` styles. A **DETAILS** toggle shows the diagnostics (spec §7.3; see below)
  and a **LEAVE SYNC GROUP** button with a confirm dialog.
- **VFD** (`ui/vfd/VFDSyncDevices.kt`): `fun draw(ctx, fb, L, c, y, w, dash): Int` draws a section
  `SYNC / DEVICES` with a two-line block per device. Line 1: name, battery, age. Line 2: path and
  badge, with problems in alarm ink and the status dot from `VFDRelayScreen`. `VFDRelayScreen.draw`
  calls it right after the intro note. Leave group is a `VFDW.button`. No `tools/vfd` change in P3
  (P4 owns the shared LINK/DEVICES previews).
- **Notification**: `· hub ✓ · iPhone ✓ 81%`. Per device: `✓` in sync, `↻` syncing, `!` otherwise.
  The device is omitted when never seen; the battery is shown when known.
- **Relay tab**: chips list `RelayControlMode.entries.filter { it != STANDALONE }`; the STANDALONE
  intro text goes. The same goes for the `VFDRelayScreen` mode selectors (56–70).
- **New-wand renames**: `ui/MagicMakerScreens.kt:1680` and `ui/vfd/VFDWandScreen.kt:685` call
  `app.store.setNewWandName(hex, name)` instead of `saveNewWandName(prefs, ...)`.
- **Diagnostics** (`SyncDashboard.diag`, per session): state, MTU, wm / peer feedHigh / own
  durableHigh, pages pulled and served, dup / stale / reject / BAD_FRAME counts, events sent /
  replayed / gaps, last ERR, link uptime.
- **Follow-up, not in P3** (blocked by the parallel workflow's ownership): a `| SYNC:OK` /
  `| SYNC:12` / `| SYNC:!` token in `telemetryLineText`, so the state shows on every screen in both
  themes.

---

## 6. Threading model

| Thread | Runs | Never does |
|---|---|---|
| main | UI; scan callbacks (`BleScanner.handleResult`); service handler and radio queue (transmit); battery-unrelated broadcasts | sync work: it only posts to mm-sync |
| packet executor (service) | `handleHeard`, `store.processHeardPacket` | blocks on sync: `syncEngine.onHeard` is a post |
| MagicStore `saveExecutor` | JSON serialization and atomic writes **outside** the store lock (§3.5), then the `onDurable` post | holds the store lock during I/O |
| **mm-sync** (`HandlerThread`) | everything in `SyncNode`, `LinkChannel`, `HubLinkMachine`, `GattServerLinks`, the roster, the event coalescer, `SyncStatus` builds, the battery receiver, every `BluetoothGatt` client callback (via the `connectGatt` handler) and every GATT call (`writeCharacteristic`, `notifyCharacteristicChanged`, `connectGatt`, `close`) | blocking I/O, except `identity.ensureIssued` (a ~100 B atomic write, only when a live REC leaves) |
| binder threads | `BluetoothGattServerCallback` | anything but copying the value and posting to mm-sync, plus `sendResponse` |

Locks and order:

- MagicStore monitor (leaf for sync purposes; `ServiceState`'s lock may be taken inside it, as
  today). The identity lock is a leaf. mm-sync takes the store monitor only through `SyncLibraryPort`
  calls, which are bounded: one REC, one page (≤ 32 RECs), or one page projection (one pass per list).
- `SyncLibraryListener` and identity callbacks may run with the store lock held, on any thread, so
  their implementations **only post**. No component calls into `SyncNode` from another thread.
- The scanner and transmitter never wait on mm-sync, the store write, or a GATT operation.

Background and permissions:

- Everything runs inside the existing `connectedDevice` foreground service, with its partial wake
  lock (Handler `uptimeMillis` timers keep running) and battery-optimisation exemption.
- BLE connections, `autoConnect` pending connections and notifications continue in Doze.
- **No new permissions**: `BLUETOOTH_CONNECT/SCAN/ADVERTISE` are present, and battery reads need none.
- With the scan off, or keep-awake on, hub discovery pauses; a known hub still reconnects through the
  pending `autoConnect`.

---

## 7. Interface between the parts

### 7.1 Step 0 (orchestrator, before either part starts)

1. Create `android/app/src/main/java/com/magicmaker/android/sync/SyncPorts.kt` **verbatim** from §8.1.
2. Add `setNewWandName` to `data/MagicStore.kt` **verbatim** from §8.2, placed right before
   `fun processHeardPacket`.
3. `./gradlew -q :app:compileDebugKotlin` must pass.

After step 0, neither part edits `SyncPorts.kt`. Changing it needs an amendment to this plan, applied
to both parts.

### 7.2 Rules across the seam

- Part 2 reaches part 1 only through `SyncPorts.data` (null until part 1 installs it: the service then
  simply does not start `SyncEngine`) and `MagicStore.setNewWandName`.
- Part 1 never imports part 2 classes.
- Part 2's tests use their own fakes of the ports (§10.2) and never part 1's classes. The integration
  step (§9.3) re-runs them against the real ones.

---

## 8. Exact interface

### 8.1 `sync/SyncPorts.kt` (verbatim)

```kotlin
package com.magicmaker.android.sync

// P3 seam between the data layer (part 1: identity, ledger, rows, events and heartbeat models) and
// the runtime (part 2: SyncNode, transports, UI). docs/SYNC_P3_ANDROID_PLAN.md §8. Pure Kotlin.
// Frozen: change only by amending that plan.

/** The data layer. Installed once by MagicMakerApp.onCreate (part 1); read by part 2. */
object SyncPorts {
    @Volatile
    private var current: SyncData? = null

    fun install(data: SyncData) {
        current = data
    }

    /** Null until installed (part 1 not merged, or a unit test). */
    val data: SyncData? get() = current
}

interface SyncData {
    val identity: SyncIdentityPort
    val library: SyncLibraryPort

    /** Once per service start: epoch = max(nowMs / 1000, lastEpoch + 1), persisted before return (§2.8). */
    fun startEventOrigin(nowMs: Long, ringCap: Int): EventOriginPort

    fun newRuntimeEstimator(): RuntimeEstimatorPort

    fun newRoster(): DeviceRosterPort
}

/**
 * noBackupFilesDir/sync_identity.json. Thread-safe; every write is atomic and synchronous.
 * [dbId] is fixed for the process lifetime (rollback is decided at load).
 */
interface SyncIdentityPort {
    val deviceId: Bytes
    val dbId: Bytes
    val group: SyncGroup?

    /** Persist the group (a JOIN was accepted) or null (leave). Returns once the file is on disk. */
    fun setGroup(group: SyncGroup?)

    /** PROTOCOL §15.4: issuedSeq >= [seq] on disk before a live REC carrying feed seq (seq - 1) is sent. */
    fun ensureIssued(seq: Long)

    /** The ESP32 hub's BLE address, remembered after the first AUTHED hub session. */
    val hubAddress: String?

    fun setHubAddress(address: String?)

    fun isForeign(address: String): Boolean

    fun markForeign(address: String)
}

/** A persisted peer-table row (§15.1) plus when this phone last completed a pull from it (0 = never). */
class StoredPeer(val state: PeerState, val lastSyncMs: Long)

data class LibrarySyncStats(
    val records: Int,
    val tombstones: Int,
    val nextSyncSeq: Long,
    val durableHigh: Long,
    val skippedPresence: Int,
    val rejected: Int,
)

/**
 * Called on whatever thread made the change (main, packet executor, save executor), possibly while
 * the store lock is held. Implementations MUST only post (no locks, no I/O, no store calls).
 */
interface SyncLibraryListener {
    /** Local edits / new learns, in seq order. [bulk]: migration, import, diff, multi-key delete. */
    fun onLocalChanges(entries: List<LedgerEntry>, bulk: Boolean)

    /** A store write completed; [durableHigh] is the new served / reported ceiling. */
    fun onDurable(durableHigh: Long)
}

/** The phone's ledger and rows. Thread-safe (the store lock); called from mm-sync. */
interface SyncLibraryPort {
    fun durableHigh(): Long

    fun recordCount(): Int

    fun stats(): LibrarySyncStats

    /** Fresh copies of the persisted peer table. */
    fun loadPeers(): Map<Bytes, StoredPeer>

    /** Store a copy of [state] (and [lastSyncMs] when non-null); written with the next save. */
    fun putPeer(peerId: Bytes, state: PeerState, lastSyncMs: Long?)

    /** Serve a PULL durable-only (§15.2). Does not touch the peer table. */
    fun servePage(pull: Pull, excludeOk: Boolean, puller: Bytes): PageResult

    /**
     * Apply one received REC body from [sender] (§6.2). [nowMs] null = clock unknown. live = true:
     * projected onto the rows at once and saved soon; false: projected at [commitPage].
     */
    fun applyRemote(body: Bytes, sender: Bytes, nowMs: Long?, live: Boolean): ApplyResult

    /** A page completed (SessionAction.Commit): project pending records, store the peer, save now. */
    fun commitPage(peerId: Bytes, state: PeerState, lastSyncMs: Long)

    fun requestSave()

    fun setListener(listener: SyncLibraryListener?)
}

/** One packet that passed handleHeard's filters (§5.7). lat/lon 1e-7 degrees; lat, lon, accM all or none. */
data class HeardSighting(
    val packet: Bytes,
    val rssi: Int?,
    val wallMs: Long,
    val monoMs: Long,
    val lat: Int?,
    val lon: Int?,
    val accM: Int?,
    val addr: Bytes?,
    val taggedOwnBand: Boolean,
)

sealed class CatchUpItem {
    /** A ring event to resend: flags carry REPLAY, seenBy is empty (the router sets it). */
    data class Replay(val evt: Evt) : CatchUpItem()

    /** Sent as is (requester set). */
    data class Gap(val gap: EvtGap) : CatchUpItem()
}

/** Android's event origin for one service start (§2.8, §5.7, PROTOCOL §8.5). mm-sync only. */
interface EventOriginPort {
    val origin: Bytes
    val epoch: Long

    /** The last seq issued in [epoch] (0 = none). */
    val seq: Long

    /** Coalesce one sighting; returns the events to send now (already in the ring, seenBy empty). */
    fun onSighting(s: HeardSighting): List<Evt>

    /** Close the windows due at or before [monoMs]; returns their events (already in the ring). */
    fun tick(monoMs: Long): List<Evt>

    /** The earliest open window's end, or null. */
    fun nextDueMs(): Long?

    /** While true (a link carries > 20 EVT/s), new windows last 3 s instead of 1 s. */
    fun setWideWindow(wide: Boolean)

    /** Issue one event without coalescing (tests, transcript replay); it goes into the ring. */
    fun originate(
        packet: Bytes,
        ts: Long,
        rssi: Int?,
        count: Int,
        lat: Int?,
        lon: Int?,
        accM: Int?,
        addr: Bytes?,
        flags: Int,
    ): Evt

    /** null: the same (requester, epoch, afterSeq) was answered less than 5 s before [monoMs]. */
    fun catchUp(requester: Bytes, epoch: Long, afterSeq: Long, monoMs: Long): List<CatchUpItem>?
}

/** §9.4. Returns runtimeMin (0..5999) or -1. */
interface RuntimeEstimatorPort {
    fun sample(monoMs: Long, pct: Int, charging: Boolean): Int
}

/** The latest HB of one device and when it was last heard, by path (§16.4). */
class RosterEntry(
    val hb: Hb,
    val lastAnyMs: Long,
    /** The last HB with hops 0 received from the described device itself. */
    val lastDirectMs: Long?,
    /** Forwarder deviceId -> the last time a copy of this device's HB arrived through it. */
    val lastViaMs: Map<Bytes, Long>,
)

/** mm-sync only. */
interface DeviceRosterPort {
    /** Record [hb] received on the session whose peer is [fromPeer]; true when it replaced the stored HB. */
    fun onHb(hb: Hb, fromPeer: Bytes, monoMs: Long): Boolean

    fun get(deviceId: Bytes): RosterEntry?

    fun entries(): List<RosterEntry>

    fun forget(deviceId: Bytes)
}
```

### 8.2 `MagicStore.setNewWandName` (verbatim stub from step 0; part 1 adds the NEWWAND record)

```kotlin
    /** A New-Wand code's custom name (blank removes it); returns the new map. P3: also a NEWWAND record. */
    @Synchronized
    fun setNewWandName(hex: String, name: String): Map<String, String> {
        val current: MutableMap<String, String> = runCatching {
            val o = org.json.JSONObject(prefs.getString("newwand_names", null) ?: "{}")
            buildMap { o.keys().forEach { k -> put(k, o.getString(k)) } }.toMutableMap()
        }.getOrDefault(mutableMapOf())
        val key = hex.uppercase()
        val trimmed = name.trim()
        if (trimmed.isEmpty()) current.remove(key) else current[key] = trimmed
        val o = org.json.JSONObject()
        current.forEach { (k, v) -> o.put(k, v) }
        prefs.edit().putString("newwand_names", o.toString()).apply()
        ServiceState.bumpStoreRevision()
        return current
    }
```

(`prefs` in MagicStore is the `magicmaker` file, the same one the UI's `loadNewWandNames` reads.)

---

## 9. Parallel split

### 9.1 File ownership (disjoint)

| Owner | Main sources (`android/app/src/main/...`) | Tests (`android/app/src/test/java/com/magicmaker/android/sync/`) |
|---|---|---|
| step 0 | NEW `sync/SyncPorts.kt`; `data/MagicStore.kt` (`setNewWandName` only) | — |
| **part 1: data** | NEW `sync/AtomicFiles.kt`, `sync/SyncIdentity.kt` (`SyncIdentityFile`, `IdentityReconcile`), `sync/SyncStateJson.kt`, `sync/LedgerStore.kt`, `sync/LibraryRows.kt`, `sync/LibrarySync.kt` (`RowsAccess`, `SaveSink`, `LibrarySync`), `sync/LibraryMigration.kt`, `sync/LibraryDiff.kt`, `sync/EventOrigin.kt`, `sync/HeartbeatModel.kt` (`RuntimeEstimator`, `DeviceRoster`), `sync/SyncDataModule.kt`; EDIT `core/MagicModels.kt`, `data/MagicStore.kt`, `MagicMakerApp.kt`, `res/xml/backup_rules.xml`, `res/xml/data_extraction_rules.xml` | `AtomicFilesTest`, `SyncIdentityTest`, `IdentityReconcileTest`, `SyncStateJsonTest`, `LedgerStoreTest`, `LibrarySyncTest`, `LibraryMigrationTest`, `LibraryDiffTest`, `RelabelTest`, `EventOriginTest`, `RuntimeEstimatorTest`, `DeviceRosterTest`, fixture `DataFixtures.kt` (`FakeRows`, `MemIdentity`) |
| **part 2: runtime** | NEW `sync/SyncNode.kt`, `sync/NodeRole.kt` (`NodeRole`, `AndroidRole`, `NodePolicy`, `SyncScheduler`, `LinkPort`), `sync/LinkChannel.kt` (`FrameLink`, `LinkChannel`), `sync/HubLinkMachine.kt`, `sync/HubClient.kt`, `sync/GattServerLinks.kt`, `sync/RelayAdvPolicy.kt`, `sync/BatteryInfo.kt`, `sync/SyncEngine.kt`, `sync/SyncStatus.kt`, `ui/SyncDevicesCard.kt`, `ui/vfd/VFDSyncDevices.kt`; EDIT `relay/RelayGattServer.kt`, `relay/RelayProtocol.kt`, `relay/RelayCommands.kt`, `ble/BleScanner.kt`, `service/MagicMakerForegroundService.kt`, `ui/MagicMakerScreens.kt` (RelayTab, GattRelayPanel, line-1680 call site only), `ui/vfd/VFDRelayScreen.kt`, `ui/vfd/VFDWandScreen.kt` (line-685 call site only) | `SyncNodeReplayTest`, `SyncLoopbackTest`, `LinkChannelTest`, `HubLinkMachineTest`, `GattServerLinksTest`, `RelayAdvPolicyTest`, `SyncStatusBuilderTest`, support `RuntimeFakes.kt` (`FakeLibraryPort`, `FakeIdentity`, `FakeEventOrigin`, `FakeRoster`, `VirtualScheduler`, `LoopbackGatt`), `StandInRoles.kt` (`IosStandInRole`, `HubStandInRole`), `TranscriptDriver.kt` |
| nobody in P3 | P1 `sync/Sync*.kt` files, `sync/PacketSync.kt`, `ble/Esp32Heartbeat.kt`, `telemetryLineText`, `service/ServiceState.kt`, Diag screens, everything under `firmware/`, `ios/`, `web/`, `.github/`, `tools/` | P1 test files |

### 9.2 Order

1. Step 0, then compile.
2. Parts 1 and 2 in parallel. Each keeps `:app:compileDebugKotlin` green on its own; their files never
   overlap.
3. Integration (§9.3), then the full test suite.

### 9.3 Integration step (after both parts)

- `TestPorts.real()` in part 2's test support switches the fakes for part 1's `LibrarySync` (with
  `FakeRows` from `DataFixtures.kt`, `MemIdentity`, a virtual `SaveSink` that follows the 300 ms /
  immediate rule), `EventOrigin` and `DeviceRoster`. Re-run `SyncNodeReplayTest` and `SyncLoopbackTest`
  in both modes.
- Add `SyncIntegrationTest`:
  - a rename on the iPhone stand-in renames **all** Android rows of that hex;
  - a re-hear does not revert the rename;
  - an Android delete tombstones the key and blocks re-learn;
  - migration → on-change HB → the stand-in pulls everything;
  - an atomic-write crash leaves the old file and the same durableHigh;
  - a rollback (an older store file) → new dbId → the stand-in refills it.
- Manual smoke test on a device: the Relay tab card renders, ESP32 `AIR`/`NO SYNC FW` with firmware
  1.2, the notification token appears, and a rename survives an app restart.

---

## 10. Test plan

### 10.1 Part 1 (pure JVM, no Android)

| Test | Cases |
|---|---|
| `AtomicFilesTest` | write/read; failure between tmp and rename leaves the old target; a leftover `.tmp` is ignored and cleaned; rename fallback |
| `SyncIdentityTest` | fresh identity (8-byte non-zero ids); reload equal; `ensureIssued` monotonic and on disk; group round trip and `isConsistent`; hub address and foreign cap; a corrupt file counts as missing |
| `IdentityReconcileTest` | every row of §3.6 |
| `SyncStateJsonTest` | Gson round trip; an old JSON without `sync`/`note`/`userEdited` loads (nulls); PRESENCE `b` omitted and rebuilt; a bad entry → corruption; rows without the new fields serialize byte-identically to before |
| `LedgerStoreTest` | the feed index holds current seqs only; pages never include `seq > durableHigh`; `feedHigh = durableHigh`; exclusion by origin and syncFrom; tombstone-cap eviction updates the index; equals `SyncRouting.servePage` over the same entries; the `pages` vectors |
| `LibrarySyncTest` | rename → all rows + USER with full state; blank → RESET (derived label); recategorize; save preset → USER\|PRESET beats a tombstone; delete → TOMBSTONE, rows gone, built-in reset; `deleteSavedBands` → no tombstones; `clearLearnedStarlight` → bulk tombstones; learn → PRESENCE iff no entry; a tombstone blocks re-learn (classified and edited raw); an unedited raw row gets no entry; remote projection per class (TOMBSTONE, USER with PRESET add/clear, USER with no row → created in `place`, RESET, PRESENCE learn and decline → skipped, NEWWAND set/remove); page records projected only at `commitPage`, one revision bump; listener bulk flags; `onDurable` after `onSaved`; label/note normalisation (trim, 64/160 B at a code-point boundary) before storing |
| `LibraryMigrationTest` | generated-label heuristic (derived, `rawLabel`, `rawPacketLabel`, `imported`); user presets → USER\|PRESET, u = 2; renamed rows → USER; colors/library → PRESENCE; unedited raw → none; newwand → NEWWAND u = 2; seq order; a hex in several lists → one entry projected onto all rows; runs once |
| `LibraryDiffTest` | every row of the §4.5 table; identical files → no ops; an older external file → no diff |
| `RelabelTest` | §4.6: a renamed show row keeps its label on re-hear; starlight verify matches by canonical hex and never changes hex; unedited rows still follow the classifier |
| `EventOriginTest` | immediate first sighting; window end with count, max rssi and last ts; a new window after it; 256-window LRU flush; 3 s wide window; epoch rule and persistence; seq restarts per epoch; ring cap; `catchUp` equals the `replayPlan` vectors; repeat within 5 s → null; fix all-or-none |
| `RuntimeEstimatorTest` | 60 s sampling, 60 min horizon, reset on a charging change, Δ ≥ 3 % over ≥ 10 min, least squares, clamp, −1 |
| `DeviceRosterTest` | `hbReplaces` (bootId change, greater hbSeq); direct vs via times; a non-replacing copy still updates path times |

### 10.2 Part 2

**`SyncNodeReplayTest`: node-level transcript conformance (exact).**

- Coverage: node **A** in `grouped_hub_two_phones`, `live_push_forwarding_seenby`,
  `reconnect_watermarks` and `event_catchup` (required). Nodes I and H via the stand-in roles in
  every transcript where they appear (required for I and H wherever A also appears, since that is
  what makes the loopback meaningful; optional for `stranger_rejected`, whose `script` messages need
  a puppet).
- Setup from `nodes.<X>`: deviceId, bootId, dbId, group, `durableHigh`, `nextSyncSeq`, ledger
  (`LedgerEntry.restore`), peers, `ringCap`, epoch. The clock is `clockBaseMs + t` (the hub reads 0
  until it learns the time, as in `gen_vectors.py`). Nonces come from `nonces[link, gen, X]`. Self
  status (battery tuple, state bits, `hubAirAgoS`) comes from X's first HB in the transcript;
  `uptimeS = 1000 + t / 1000`.
- Driver: a `VirtualScheduler` heap keyed `(t, seq)`, mirroring `gen_vectors.Sim`:
  - the transcript's scenario stimuli (link_up, link_down, `local` ops) are pushed first, so at equal
    `t` they run first, in step order;
  - each `msg` to X is delivered at `t + latencyMs`, pushed when its step is read;
  - X's timers are pushed when armed;
  - disconnects land 16 ms after they are decided (`LAT_MS + 1`);
  - phones save 300 ms after a live accept or local edit and at once on a page commit; the hub flushes
    2,000 ms after its first dirty record (in `FakeLibraryPort` / the stand-ins);
  - `local heard` ops call `originate` with the fields of the first EVT for that `(epoch, seq)` from
    X in the transcript (placeholders when it was never sent, since it is unobservable);
  - `local edit` uses the fields decoded from `bodyHex`;
  - `service_restart` → `serviceRestart(bootId, epoch)`;
  - `sync_reset` → the hub stand-in.
- Assert:
  - X's emitted messages equal the transcript's `msg` steps with `from == X`, byte for byte (`hex`)
    and in order;
  - X's `state`, `apply`, `durable`, `disconnect` and `foreign` steps, and I's `ingest`/`gap` steps,
    match;
  - the final state equals `final.nodes.X`: dbId, groupId, durableHigh, nextSyncSeq, ledger, peers,
    and for A `epoch`/`evtSeq`/`ring`, for I `evtWindows`.
- `NodePolicy.TRANSCRIPT`; listeners wired inline.

**`SyncLoopbackTest`: convergence through the real transport (two nodes required, three
recommended).**

- **Two-node: Android ↔ iPhone stand-in.** For every transcript, take the local ops of A and I. The
  H-only ops (`sync_reset`) are dropped, and scenarios whose meaning depends on the hub are skipped.
  Run them over one I–A link mirroring the transcript's I–A link_up/link_down times (or kept up when
  the transcript has none).
- **Three-node:** A, I-stand-in and H-stand-in on every transcript link, using the transcript's own
  stimuli.
- Links are a `LoopbackGatt`: the transcript's MTU per link, a seeded random latency of 5–40 ms, an
  `onFrameSent` 1–10 ms after each write, one frame in flight, and `LinkChannel` + `Fragmenter` +
  `Reassembler` on both ends.
- Assert after quiescence (all links up for 30 s):
  - every node's ledger maps key → `(u, o, c, b)` identically to the transcript's final ledger;
  - no live REC was ever sent to its sender or to its origin;
  - I accepted exactly the event ids the transcript's `ingest ACCEPT` steps list;
  - no PAGE_END's `scannedTo` exceeded the server's durableHigh at that moment;
  - every session on a link that is up ends SYNCED.
- A seeded fuzz variant: 60 virtual seconds of random renames, learns, deletes, presets, new-wand
  names, heard packets and link flaps across A/I/H, plus one dropped frame per 200. Assert the same
  invariants, and that a dropped frame causes a count mismatch and a re-PULL, never divergence.

| Other part-2 test | Cases |
|---|---|
| `LinkChannelTest` | fragment/reassemble round trip at MTU 23/185/247 through the loopback; one frame in flight; lane 0 before lane 1; replay pacing ≤ 20 EVT/s; no interleaving of messages; counters reset at link-up; `ErrTooBig` / `ErrProto` / `BadFrame` → ERR messages and counts; stall → close; lane-0 overflow → close; an MTU change applies to the next message |
| `HubLinkMachineTest` | setup order (MTU → discover → notify → CCCD → up); no SYNC → disconnect + 30 min no-probe; 133 → close + backoff 1/2/5/10/30; a session retryMs floor; FOREIGN → forget and never auto-connect; first AUTHED → remember the address; autoConnect vs direct on `hubSeen`; the 5 s op timeout |
| `GattServerLinksTest` | CCCD on/off → up/down; MTU before and after CCCD; disconnect → down; per-device isolation (two centrals) |
| `RelayAdvPolicyTest` | off while connected; LOW_LATENCY 60 s then BALANCED; burst/keep-awake pause and resume never re-enables while connected; group tag bytes (`MM_AND` + 2 bytes, `00 00` when ungrouped); primary ADV ≤ 31 B |
| `SyncStatusBuilderTest` | each badge rule in §5.8; path tokens; LOST at 10 min; ESP32 advert fallback (`AIR`); `UPDATE APP` after 10 s linked without SYNC; header and notification token; the text lines of §5.8 |
| `AndroidRole` cases (in `SyncNodeReplayTest`) | route 1 > route 2 > ring; route 2 needs a direct hub HB ≤ 90 s with a synced kind-3 link; catch-up from an HB `evtWm` and from EVT_SINCE; skip within 5 s |

### 10.3 What is not covered by unit tests

The real Android BLE stack (`HubClient`/`RelayGattServer` adapters), Doze behaviour, and the hardware
matrix rows of spec §11.6. These need P2 firmware and a P4 iPhone build. The P3 gate's hardware rows
("hub-only and direct-only pass with a test iPhone build") therefore run when those exist.

### 10.4 Commands

```
cd android
./gradlew -q :app:compileDebugKotlin
./gradlew -q :app:testDebugUnitTest --tests 'com.magicmaker.android.sync.*'
./gradlew -q :app:testDebugUnitTest
```

### 10.5 CI note

`.github/workflows/android-ci.yml:78` runs only `--tests 'com.magicmaker.android.ui.vfd.*'`, so sync
tests do not run in CI today (P1's included). `.github` is outside this workflow; the filter must
also include `com.magicmaker.android.sync.*` (spec §11.3). That is an open item for the workflow that
owns `.github`.

---

## 11. Decisions made in P3

1. **SyncNode is a port of `gen_vectors.Node`**, verified by node-level transcript replay, so the
   Android engine behaves exactly like the model that produced the shared transcripts.
2. **Timer inputs carry `t = due`** (the P1 core ignores any other `t`).
3. **One `SessionCtx` per session**, refreshed before each input; the peer map is shared per node.
4. **The internal store is always the base.** The external file gets the same JSON (sync included).
   It is diffed only when its sidecar mismatches and it is newer than the internal file; its sync
   section is used only when no internal store exists.
5. **Serialization and disk I/O happen outside the store lock**, which is safe because rows are
   immutable (every writer uses `copy()`).
6. **A local delete applies the TOMBSTONE projection locally**: every learned row and user preset with
   that hex goes, matching what peers do. This changes today's UX, where deleting a preset kept a
   learned row with the same hex.
7. **A blank rename is RESET** (the label becomes derived), matching iOS.
8. **Migration treats `typeInfo = "imported"` labels as generated**, so cloud-dictionary labels do
   not outrank real user names.
9. **Identity case (a) also resets the peer table** (one extra full resync; always safe).
10. **HubClient never holds a SYNC-less ESP32 link**, and does not re-probe it for 30 min.
11. **"Leave sync group" sits on the Relay tab** (both themes) instead of Diag, so Diag screens stay
    untouched in P3.
12. **Sync status is its own StateFlow** (`SyncStatus`), not new `ServiceState` fields.
13. **The ESP32 row falls back to the advert heartbeat** (`ServiceState.esp32Battery`, path `AIR`)
    until hub HBs exist.
14. **STANDALONE disappears from the UI**, and a stored value maps to BLE_GATT. It ships together with
    the tag in the primary ADV. Current iOS builds in ESP32 mode need an ESP32 name, so they cannot
    grab Android.
15. **Relay advertising is off while any central is connected.**
16. **`issuedSeq` is raised to exactly `s + 1`** (§3.7).
17. **HB on-change triggers are a policy**: the full spec set in production, the simulation's set in
    replays.
18. **Live records are projected immediately; page records are batched at commit.**
19. **PRESENCE from sync uses the learn routine with `fromSync`**: no ledger write, no cloud push, no
    serial pref change.
20. **New-wand names go through `MagicStore.setNewWandName`** (step-0 stub).
21. **All new tests live in `com.magicmaker.android.sync`.**
22. **Loops by hex land in P3**, because HELLO already advertises caps `0x003B` (bit5).

### 11.1 Implementation notes (part 2)

- `SyncNodeReplayTest` replays **all six** transcripts with every node as a `SyncNode` (Android role,
  iPhone and hub stand-ins, scripted strangers): every step matches, message bytes included.
- Production policy only: a local change that no session took live (none was AUTHED+ yet) is
  announced like a bulk change, by the on-change HB after its write, instead of waiting up to 60 s.
- `RelayGattServer` ignores this phone's own client link to the ESP32 in its connection callback
  (Android reports outgoing client links there too), so advertising and `UPDATE APP` follow real
  centrals only.
- A central that has connected but not yet enabled SYNC shows `LINKING` for 10 s, then `UPDATE APP`.
- `SyncStatusBuilder` subtracts records accepted from a peer from what that peer is owed, so a
  rename made on the iPhone does not read `SYNCING 1` toward the iPhone itself.
- No "share heard packets" switch in the UI yet; the pref `sync_share_heard` defaults to on.

## 12. Risks and open questions

**Risks**

- Save volume during a first sync with a 20k-row library (multi-MB JSON per write). Mitigated by
  coalescing, at most one write in flight, and serialization outside the lock. Watch for it in the
  manual smoke test.
- Firmware 1.2 stops advertising while any phone is linked, so one probe by HubClient can hide the
  ESP32 from the iPhone for about 1–2 s, at most once per 30 min.
- Android BLE stack variance: status 133, concurrent central + peripheral, and the private address
  changing on each advertising restart (iOS rediscovers by tag).
- The delete behaviour change in D-P3-6.
- Nothing can be verified end to end on hardware until P2/P4 exist; P3 is proven by the replay and
  loopback tests.

**Open questions (for other phases; P3 proceeds with the defaults above)**

1. CI filter for `com.magicmaker.android.sync.*` (§10.5).
2. **P2**: advertise SYNC capability before connection (for example a scan-response marker, or
   `Esp32Heartbeat` advert version ≥ 2), so Android never probes old firmware.
3. **P4**: the iPhone must not drop Android advertisers whose tag is `MM_AND 00 00` (ungrouped):
   that is the TOFU path.
4. ERR CLOCK re-stamping (spec §3.4 code 7): P3 only counts rejections and shows them in DETAILS.
5. Shared vectors for the runtime estimator, so all three platforms agree (a `tools/sync` change for
   a later phase).
6. The telemetry-line `SYNC:` token (§5.8), once the parallel workflow's `telemetryLineText` work has
   merged.

## 13. Acceptance checklist (P3 done)

- [ ] Step 0 done; `SyncPorts.kt` matches §8.1 byte for byte.
- [ ] `compileDebugKotlin` green; all `com.magicmaker.android.sync.*` tests green; full
      `testDebugUnitTest` green.
- [ ] `SyncNodeReplayTest`: A exact in all 4 transcripts (plus the stand-ins).
- [ ] `SyncLoopbackTest`: two-node and three-node convergence, fuzz invariants.
- [ ] Identity in `noBackupFilesDir`; rollback cases detected; the store, the external copy and the
      identity are written atomically.
- [ ] Every mutation point in §4.7 produces the stated record, and re-hearing never relabels a
      user-named row.
- [ ] The Relay tab and VFD Relay show the SYNC/DEVICES block for iPhone, ESP32 and this phone,
      with path, HB age, battery and badge; the notification carries the sync token.
- [ ] No edits under `firmware/`, `ios/`, `web/`, `.github/`, to `ble/Esp32Heartbeat.kt`, to
      `telemetryLineText`, or to the P1 files; no git state changes.
