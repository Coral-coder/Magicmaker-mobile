# iOS architecture for Android parity (the contract between agents)

Read `IOS_PORT_RULES.md` (same directory) first. This file says WHO owns WHAT and the exact API that crosses
object boundaries. If you own an object, implement exactly these names and signatures (you may add more).
If you use another object, use exactly these.

## Principle

The iPhone is the brain. It scans, classifies, learns, logs, maps, edits its own library and decides what to
send. The relay (an Android phone or an ESP32) is only a radio: the iPhone hands it a hex packet and a
duration. Everything except the broadcast itself must work with no relay linked.

Android's equivalents: `MagicStore.kt` (library/logs/prefs), `MagicMakerForegroundService.kt` (scan
pipeline, loops, replay, random show, auto-response), `ServiceState.kt` (live feed, source stats, counters).

## Objects (all `@MainActor final class … : ObservableObject`, one instance each, owned by AppViewModel)

| Swift object | File | Android source |
|---|---|---|
| `MagicStore` | `Data/MagicStore.swift` | `data/MagicStore.kt` |
| `ScanEngine` | `ViewModels/ScanEngine.swift` | `handleHeard` + scan/log control in the service, `ServiceState.appendLive` and friends |
| `TxEngine` | `ViewModels/TxEngine.swift` | `queueSend`, TX loop, Starlight loop, random show, replay in the service |
| `AppViewModel` | `ViewModels/AppViewModel.swift` | relay link + Android remote control (already exists) + wiring |
| `LocationTracker` | `BLE/LocationTracker.swift` | location code in the service |
| `CrashLog` (enum, not observable) | `Data/CrashLog.swift` | `core/CrashLog.kt` |

Pure logic with no UI or OS dependency goes in `Core/` (Foundation only): the session CSV format, parsing,
analysis grouping and map bucketing live in `Core/SessionLog.swift` so they can be parity-tested.

The root view injects `AppViewModel`, `MagicStore`, `ScanEngine` and `TxEngine` with `.environmentObject`.

## Phase B is ADDITIVE

Screens are rewritten in a later phase. Until then the existing views must keep compiling: do not remove or
rename anything in `AppViewModel`, `BleCoordinator`, `BleCentral`, `AndroidRemoteClient`,
`AndroidRelayGattClient` that a file under `Views/` uses. Add the new objects next to the old code. (The
five unreachable views RecordTab, FilesTab, AutoTab, PresetsTab, LabTab have been deleted, and
`Core/ISCanBackupLogger.swift` stays until the screens are replaced.)

## MagicStore (owner: store agent)

Port `data/MagicStore.kt` function by function, same behaviour, same strings (reasons such as
`"Learned X → Colors"`), same caps (`MAX_RAW_LIBRARY = 20000`, `MAX_RECORDINGS = 500`), same dedupe rules
(library keeps every distinct canonical hex; pings are never saved; raw packets are learned unless
`isLibraryNoise` and the source is not a tagged band; presets win in `allTransmitPackets`).

Publishing: the lists are plain `private(set) var` (NOT `@Published` — they change on every heard packet).
The only published value is `@Published private(set) var revision: Int`. Bump it immediately on a user edit
(rename, delete, recategorize, preset saved, rule change, band tagged, pref changed, import) and at most once
per second for packets learned while scanning. Views re-read the lists when `revision` changes.

Persistence: `Documents/magicmaker_store.json`, written by a coalescing background save (mark dirty, one
write per burst, encode off the main thread from a value snapshot). Raw-learn saves are throttled to one per
2.5 s like Android. `recordings` is in-memory only (never written to the JSON; the CSV is the record).
The JSON must stay readable by the Android app and vice versa (same top-level keys as Kotlin
`PersistedState`, including `settings`/`uiSettings` as `[String: PrefEntry]` with `type` b|i|l|f|s|ss).
Decode tolerantly; before decoding, replace bare `NaN`/`Infinity` tokens (`:NaN`, `:-Infinity`…) with
`null` in the text, because an Android-written file can contain them.

Preferences: `UserDefaults.standard`, same key names and defaults and clamps as Android's "magicmaker"
SharedPreferences (`wakeup_preamble_ms`, `command_burst_ms`, `starlight_burst_ms`, `tx_power_level`,
`tx_interleave`, `show_control_only`, `band_addresses` comma-joined, `starlight_serial`, `lab_hex`,
`lab_label`). Timing ranges come from `core/TransmitTiming.kt` — add `enum TransmitTiming` to
`Core/TransmitTiming.swift` with the same constants.

Exact API (Swift):

```swift
@MainActor final class MagicStore: ObservableObject {
    @Published private(set) var revision: Int
    private(set) var presets: [MagicPacket]
    private(set) var learnedColors: [MagicPacket]
    private(set) var learnedLibrary: [MagicPacket]
    private(set) var learnedRaw: [MagicPacket]
    private(set) var recordings: [Recording]
    private(set) var autoRules: [AutoResponseRule]

    func prepareIfNeeded()                                  // load, seed/merge built-in presets (idempotent)
    var allLearnedPackets: [MagicPacket] { get }
    var customPresets: [MagicPacket] { get }
    func allTransmitPackets() -> [MagicPacket]
    func packets(for category: MagicCategory) -> [MagicPacket]
    func learnedStarlightPackets() -> [MagicPacket]
    func newWandPackets() -> [MagicPacket]
    func findLearnedStarlight(id: Int64) -> MagicPacket?
    func findTransmitPacket(id: Int64) -> MagicPacket?     // also resolves NewWandCatalog ids

    // preferences (clamped like Android)
    func getStarlightSerial() -> String
    func getLabHex() -> String
    func getLabLabel() -> String
    func saveLabHex(_ hex: String)                          // prefs only, no JSON save
    func saveLabLabel(_ label: String)
    func loadIntoLab(hex: String, label: String)
    func getWakeupPreambleMs() -> Int;  func saveWakeupPreambleMs(_ ms: Int)
    func getCommandBurstMs() -> Int;    func saveCommandBurstMs(_ ms: Int)
    func getStarlightBurstMs() -> Int;  func saveStarlightBurstMs(_ ms: Int)
    func getTxPowerLevel() -> Int;      func saveTxPowerLevel(_ level: Int)
    func getTxInterleave() -> Bool;     func saveTxInterleave(_ on: Bool)
    func getShowControlOnly() -> Bool;  func saveShowControlOnly(_ on: Bool)

    // library editing
    func applyLabLabelToMatchingRaw()
    @discardableResult func saveCustomPreset(label: String, hex: String) -> String?   // error text, or nil = saved
    func deleteCustomPreset(id: Int64)
    func recategorizePacket(id: Int64, category: MagicCategory)
    func renamePacket(id: Int64, newLabel: String)
    func deletePacketById(_ id: Int64)
    func deleteLearnedColor(id: Int64)
    func deleteLearnedLibrary(id: Int64)
    func deleteLearnedRaw(id: Int64)
    func clearLearnedStarlight()
    func importHexesToLibrary(_ hexes: [String]) -> Int

    // my MagicBand (addresses are CoreBluetooth peripheral UUID strings on iOS, uppercased)
    func bandAddresses() -> Set<String>
    func isBandAddress(_ address: String) -> Bool
    func addBandAddress(_ address: String)
    func removeBandAddress(_ address: String)
    func savedBandCount() -> Int
    @discardableResult func deleteSavedBands() -> Int

    // scan pipeline
    func processHeardPacket(hex: String, rssi: Int, persistToSession: Bool, address: String,
                            lat: Double?, lng: Double?, accuracy: Double?) -> RecordEvent?

    // auto rules
    func findAutoResponses(classified: ClassifiedPacket, rawHex: String) -> [String]?
    func addAutoRule(name: String, triggerId: String, responseIds: [String], responseHexes: [String])
    func setAutoRuleEnabled(id: Int64, enabled: Bool)
    func deleteAutoRule(id: Int64)

    // capture logs (13-column CSV identical to Android; see Core/SessionLog.swift)
    var sessionActive: Bool { get }
    @discardableResult func beginScanSession() -> URL
    @discardableResult func endScanSession() -> String?
    func listLogs() -> [LogFile]
    func readLog(path: String) -> [LoggedPacket]
    @discardableResult func deleteLog(path: String) -> Bool
    func forEachLoggedLocation(_ action: (_ lat: Double, _ lng: Double, _ rssi: Int, _ address: String, _ label: String, _ category: String) -> Void)

    // library file
    func exportLibrary() -> URL?                             // writes Documents/magicmaker_library.json, returns it
    @discardableResult func importLibrary(from url: URL) -> Bool
    @discardableResult func importAndroidCatalog(_ catalog: AndroidRemoteCatalog) -> Int   // additive merge by canonical hex; returns rows added
}
```

Log files: `Documents/logs/scan_<yyyy-MM-dd'T'HH-mm-ss>.csv` (local time, `en_US_POSIX`), plus
`scan_<stamp>_band.csv` and, at session end, `scan_<stamp>_unique.csv` — the same header, columns, escaping
and sidecar formats as Android. `listLogs`/`readLog`/`forEachLoggedLocation` also read the two legacy iOS
directories `Documents/scan_sessions` (8 columns) and `Documents/iscan_backup` (3 columns:
`timestamp_ms,hex,rssi` — fill label/category/type by classifying the hex). CSV appends go through one
serial background queue with an open `FileHandle` (never block the main thread per packet); `endScanSession`
flushes synchronously on that queue.

`Core/SessionLog.swift` (Foundation only) owns: `struct LogFile` (`path`, `name`, `sizeBytes: Int64`,
`modifiedMs: Int64`, `packetCount: Int`), `struct LoggedPacket` (`timestampMs: Int64`, `hex`, `rssi`,
`label`, `category: String`, `typeInfo`, `sourceAddress`, `isBand`, `lat: Double?`, `lng: Double?`,
`accuracy: Double?`), `enum SessionLog` with `static let header`, `static let uniqueHeader`,
`static func csvField(_:)`, `static func row(_ rec: Recording) -> String`,
`static func parseRow(_ line: String) -> LoggedPacket?` (accepts 13-, 8- and 3-column rows),
`static func fileName(for date: Date) -> String`. Number formatting in `row` must match Kotlin's
`Double.toString()`/`Float.toString()` closely enough to round-trip (plain decimal, no exponent for
coordinates; write accuracy with one decimal).

## ScanEngine (owner: engines agent)

Port of the service's `handleHeard` path plus `ServiceState.appendLive/clearLive/removeLive/removeRawLive`,
source stats and seen-address list (same caps: 120 live, 80 addresses, 300 sources shown, 500 tracked; same
sort orders), `ensureLoggingStarted`/`stopLogging`, and the `scan_active` / `record_session` /
`auto_enabled` preferences (same keys and defaults as Android `loadPrefs`).

State is plain `private(set) var` and the engine publishes with a throttle: after mutating, call a private
`publish()` that sends `objectWillChange` at most every 200 ms (immediately for user actions). Do NOT make
per-packet state `@Published`.

```swift
struct LivePacket: Identifiable, Equatable {       // Core/MagicModels.swift
    let hex: String; let label: String; let rssi: Int; let note: String
    let category: MagicCategory; let typeInfo: String; let dedupeKey: String
    let timestampMs: Int64; let address: String; let isBand: Bool
    var id: String { "\(timestampMs)-\(dedupeKey)" }
}
struct SeenAddress: Identifiable, Equatable { let address: String; let rssi: Int; let lastSeenMs: Int64; let count: Int; var id: String { address } }
struct SourceStat: Identifiable, Equatable { let address: String; let count: Int; let bestRssi: Int; let lastRssi: Int; let lastSeenMs: Int64; let priority: Bool; let categories: [String]; var id: String { address } }

@MainActor final class ScanEngine: ObservableObject {
    init(store: MagicStore, location: LocationTracker)
    var onAutoResponses: ((_ hexes: [String], _ label: String) -> Void)?   // AppViewModel wires this to TxEngine
    var onScanWanted: ((Bool) -> Void)?                                     // AppViewModel starts/stops the BLE scan
    var onWandColorHeard: ((Int) -> Void)?

    private(set) var livePackets: [LivePacket]        // unique by dedupeKey, newest first
    private(set) var rawLivePackets: [LivePacket]
    private(set) var seenAddresses: [SeenAddress]
    private(set) var sources: [SourceStat]
    private(set) var packetsHeard: Int
    private(set) var lightsHeard: Int
    private(set) var lastHeardHex: String
    private(set) var lastHeardLabel: String
    private(set) var lastLightHex: String              // last heard packet with BandEffectModel.lightsBand
    private(set) var lastLightLabel: String
    private(set) var scanActive: Bool                  // the user wants scanning
    private(set) var recordSessionActive: Bool
    private(set) var activeSessionName: String
    private(set) var autoEnabled: Bool
    private(set) var autoResponsesSent: Int
    private(set) var bluetoothStatus: String           // "Bluetooth ready", "Turn on Bluetooth", …
    var showControlOnly: Bool { get set }              // store.getShowControlOnly / saveShowControlOnly

    func start()                                       // apply saved prefs: start scan + logging if wanted
    func handleHeard(hex: String, rssi: Int, address: String)
    func setScan(_ on: Bool)
    func setRecording(_ on: Bool)
    func setAuto(_ on: Bool)
    func clearLive()
    func removeLive(dedupeKey: String)                 // unique AND raw rows with that key, like Android
    func removeRawLive(timestampMs: Int64, hex: String)
    func noteBluetoothStatus(_ status: String)
}
```

`handleHeard` follows Android's order exactly: classify → show-control filter (count and return) →
band lookup → append to live feed FIRST → `store.processHeardPacket` → last-light / last-heard / wand colour →
auto-response (800 ms cooldown, only when classified).

## TxEngine (owner: engines agent)

Everything that sends. It never talks to CoreBluetooth; AppViewModel gives it a radio:

```swift
@MainActor final class TxEngine: ObservableObject {
    init(store: MagicStore)
    var radioReady: () -> Bool = { false }
    /// Send one packet for durationMs through the linked relay; completion(false) when it could not be sent.
    var radioSend: (_ hex: String, _ durationMs: Int, _ completion: @escaping (Bool) -> Void) -> Void = { _, _, done in done(false) }
    var onWandColor: ((Int) -> Void)?

    @Published private(set) var status: String
    @Published private(set) var lastTransmitHex: String
    @Published private(set) var isTransmitting: Bool
    @Published private(set) var txLoopEnabled: Bool
    @Published private(set) var txLoopPacketId: Int64
    @Published private(set) var txLoopIntervalMs: Int
    @Published private(set) var txLoopLabel: String
    @Published private(set) var starlightLoopEnabled: Bool
    @Published private(set) var starlightLoopPacketId: Int64
    @Published private(set) var starlightIntervalMs: Int
    @Published private(set) var starlightLoopLabel: String
    @Published private(set) var randomShowEnabled: Bool
    @Published private(set) var randomShowIntervalMs: Int
    @Published private(set) var randomShowLabel: String
    @Published private(set) var replayActive: Bool
    @Published private(set) var replayProgress: Int
    @Published private(set) var replayTotal: Int
    @Published private(set) var replayLabel: String

    func transmit(hex: String, label: String)          // one packet; duration from the packet kind + store timing prefs
    func transmitSequence(_ hexes: [String], label: String)
    func vibrate()
    func setTxLoop(enabled: Bool, packetId: Int64?, intervalMs: Int?)
    func setStarlightLoop(enabled: Bool, packetId: Int64?, intervalMs: Int?)
    func setRandomShow(enabled: Bool, intervalMs: Int?)
    func startReplay(path: String, categories: Set<String>, address: String, bandOnly: Bool)
    func stopReplay()
    func stopAll()
}
```

Sends are serialised through one queue (Android `enqueueRadioWork`): a send in progress finishes before the
next starts; a user tap preempts queued loop iterations. Loops, random show and replay are timers on the
iPhone (they run while the app is in the foreground; set `UIApplication.shared.isIdleTimerDisabled = true`
while any of them is active and restore it after). Loop prefs use Android's keys and clamps
(`tx_loop_*`, `starlight_loop_*`, `random_show_*`, interval 500…60000 ms). Loops are mutually exclusive the
same way Android makes them. Replay reproduces Android `startReplay`/`runReplayStep` (same filtering, same
step timing rules and caps, same progress/label strings).

Burst duration per packet kind (Android `queueSend`): Starlight/New Wand colour → `store.getStarlightBurstMs()`;
everything else → `store.getCommandBurstMs()`. The relay adds the wake ping itself.

## AppViewModel wiring (owner: engines agent)

- Owns `let store`, `let location`, `let scan`, `let tx` (create them in `init`; keep `bootstrapAfterLaunch()`).
- `tx.radioReady = { self.remoteLinkReady }`; `tx.radioSend` sends through the linked relay: for the ESP32
  and Android-BLE backends use the existing GATT transmit path that carries a duration
  (`BleTransmitter.transmit(hex:durationMs:onComplete:)` via `BleCoordinator`), for the Android WiFi
  backend the existing WiFi transmit. Pause the local scan while a send is on air only if the existing
  `BleCoordinator.play` already does so (keep that behaviour).
- BLE packets: `BleCoordinator.onPacket` gains the source id; AppViewModel forwards every packet to
  `scan.handleHeard(hex:rssi:address:)` in addition to the existing legacy feed code.
- `scan.onAutoResponses = { hexes, label in self.tx.transmitSequence(hexes, label: label) }`,
  `scan.onScanWanted` starts/stops the local BLE scan, `scan.onWandColorHeard`/`tx.onWandColor` update
  `wandDisplayColorIndex`.
- New: `@Published var labLoadTick: Int`, `@Published var requestedTab: String?`,
  `func loadInLab(hex: String, label: String)` (store.loadIntoLab, set `androidLabHex`, bump the tick,
  request the Lab tab), `func importAndroidLibrary()` (merge `androidCatalog` into the store).
- Keep-awake stays a relay command (already there); reconcile `keepAwakeActive` from relay status.

## Infrastructure (owner: infra agent)

- `BleCentral`/`BleCoordinator`: pass `peripheral.identifier.uuidString` (uppercased) as the source id;
  remove the 1.5 s radio-level dedupe (Android has none — counts, logs and RSSI weighting need every
  advert); report Bluetooth state changes; use `HexUtils` candidate ranking when several payload sources are
  present.
- `LocationTracker`: `CLLocationManager`, when-in-use authorisation requested on `start()`,
  `kCLLocationAccuracyBest`, `distanceFilter` 3 m; `private(set) var latest: (lat: Double, lng: Double, accuracy: Double)?`,
  `func start()`, `func stop()`, `var authorizationDescription: String`. Add
  `NSLocationWhenInUseUsageDescription` to `ios/MagicMaker/Info.plist`.
- `CrashLog`: `static func install()` (NSSetUncaughtExceptionHandler + signal handlers that write a short
  record to `Documents/crash_log.txt` using only async-signal-safe calls), `static func record(_ error: Error, _ context: String)`,
  `static func note(_ text: String)`, `static func read() -> String`, `static func clear()`, capped file size
  like Android. Call `CrashLog.install()` first thing at launch.
- `AndroidRemoteStatus`: parse the new relay status keys `lastLightHex`, `lastLightLabel`, `lightsHeard`,
  `keepAwake`, `txPowerLevel`, `txInterleave`, `showControlOnly` (all optional).
