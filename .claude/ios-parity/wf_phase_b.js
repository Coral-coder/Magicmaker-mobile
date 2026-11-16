export const meta = {
  name: 'ios-spine',
  description: 'iOS local library, logs, location, scan pipeline and relay-driven send engines (Android parity, phase B)',
  phases: [
    { title: 'Store+Infra', detail: 'MagicStore port; BLE source ids, location, crash log' },
    { title: 'Review 1', detail: 'store and infra checked against Kotlin and for compile errors' },
    { title: 'Engines', detail: 'ScanEngine, TxEngine, AppViewModel wiring' },
    { title: 'Review 2', detail: 'engines checked against the Android service' },
    { title: 'Integrate', detail: 'whole-target consistency' },
  ],
}

const S = '/tmp/claude-0/-home-user-Magicmaker-mobile/8956e220-2c18-5594-88a6-966886e08e67/scratchpad/'
const RULES = 'FIRST read ' + S + 'IOS_PORT_RULES.md and ' + S + 'IOS_ARCHITECTURE.md in full and follow them exactly. There is no Swift compiler here; your code is compiled later in CI, so precision matters more than speed. The Core/ packet logic (DisneyTlv, MagicClassifier, BandEffectModel, PacketPatterns, PresetCatalog, LabPacketBuilder, HexUtils, MagicModels…) has ALREADY been ported and reviewed: read those Swift files for exact names and use them; do not re-port them.'
const AND = '/home/user/Magicmaker-mobile/android/app/src/main/java/com/magicmaker/android/'
const IOS = '/home/user/Magicmaker-mobile/ios/MagicMaker/'

const PORT_SCHEMA = {
  type: 'object',
  properties: {
    filesCreated: { type: 'array', items: { type: 'string' } },
    filesChanged: { type: 'array', items: { type: 'string' } },
    apiAddedOrChanged: { type: 'array', items: { type: 'string' } },
    leftOut: { type: 'array', items: { type: 'string' } },
    unsure: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
  required: ['filesCreated', 'filesChanged', 'apiAddedOrChanged', 'summary'],
}
const REVIEW_SCHEMA = {
  type: 'object',
  properties: {
    compileProblemsFixed: { type: 'array', items: { type: 'string' } },
    parityProblemsFixed: { type: 'array', items: { type: 'string' } },
    remainingConcerns: { type: 'array', items: { type: 'string' } },
    filesChanged: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
  required: ['compileProblemsFixed', 'parityProblemsFixed', 'remainingConcerns', 'summary'],
}

const STORE_FILES = [IOS + 'Data/MagicStore.swift', IOS + 'Core/SessionLog.swift', IOS + 'Core/TransmitTiming.swift']
const STORE_TASK = [
  'TASK: the iPhone\'s own packet library, preferences and capture logs — the "MagicStore" section of IOS_ARCHITECTURE.md.',
  'YOUR FILES: ' + IOS + 'Data/MagicStore.swift (rewrite it as a faithful port of ' + AND + 'data/MagicStore.kt — read all 1200+ lines of the Kotlin), NEW ' + IOS + 'Core/SessionLog.swift, NEW ' + IOS + 'Core/TransmitTiming.swift (constants from ' + AND + 'core/TransmitTiming.kt).',
  'Also read: ' + IOS + 'Core/MagicModels.swift (Recording, MagicPacket, AutoResponseRule, RecordEvent), ' + IOS + 'Core/MagicClassifier.swift, ' + IOS + 'Core/PacketPatterns.swift, ' + IOS + 'Core/PresetCatalog.swift, ' + IOS + 'Core/LabPacketBuilder.swift (NewWandCatalog), ' + IOS + 'BLE/AndroidRemoteCatalog.swift (for importAndroidCatalog), ' + AND + 'core/MagicModels.kt, ' + AND + 'sync/PacketSync.kt (do NOT port cloud sync — the iOS app carries no token; leave it out and say so), and the "store", "logs" and "map" entries of the parity map.',
  'Implement EVERY member listed for MagicStore in IOS_ARCHITECTURE.md with exactly those signatures, plus the private helpers the Kotlin has (addClassifiedToLibrary, hearRawPacket with the O(1) raw index and noise rule, addStarlightToLibrary, addColorToLibrary, addShowAnimToLibrary, libraryPacketFrom, updateLearnedColor with the changed-only guard, persistRecording with the 500 cap and no JSON save, accumulateUnique + the _unique.csv export at session end, the band sidecar log, mergeBuiltInPresets, snapshot/restore of preferences as PrefEntry maps for export/import).',
  'Compatibility shims so files you do not own keep compiling: keep `func processHeardPacket(hex: String, rssi: Int, persistToSession: Bool) -> RecordEvent?` (forwarding with empty address and nil location), `func findAutoResponse(classified: ClassifiedPacket, rawHex: String) -> String?` (first of findAutoResponses), `func tryAddRecorded(hex:rssi:)`, `func loadIntoLab(hex: String, label: String = "")`, `@Published`-free `scanSessions: [ScanSessionFile]` with `refreshSessions()` if anything outside Data/ still uses them (grep ios/MagicMaker; the five dead views RecordTab/FilesTab/AutoTab/PresetsTab/LabTab are already deleted). The `MagicPacket.toClassified()` / `ClassifiedPacket.toPacket(userRecorded:)` extensions live in Core/MagicModels.swift — do not redeclare them.',
  'The persisted JSON: write the same top-level keys as Kotlin PersistedState (presets, learnedColors, learnedLibrary, learnedRaw, recordings (always []), autoRules, nextPacketId, nextRecordingId, nextRuleId, starlightSerial, labHex, labLabel, settings, uiSettings). An existing iOS store file (older format, no settings maps) and an Android-exported library file must both load. Loading must never wipe a library on a decode error: if decoding fails, keep the file aside as magicmaker_store.corrupt.json and start from presets.',
  'Core/SessionLog.swift must be Foundation-only and contain the CSV header/row/parse logic, LogFile, LoggedPacket, the unique-tally row format and `fileName(for:)`, as the architecture file specifies. MagicStore uses it for all log IO.',
  'Thread model: MagicStore is @MainActor. JSON encoding+writing and CSV appends happen on private serial DispatchQueues from value snapshots; nothing on those queues touches self\'s mutable state.',
].join('\n')

const INFRA_FILES = [IOS + 'BLE/BleCentral.swift', IOS + 'BLE/BleCoordinator.swift', IOS + 'BLE/LocationTracker.swift', IOS + 'Data/CrashLog.swift', IOS + 'BLE/AndroidRemoteClient.swift', IOS + 'MagicMakerApp.swift', IOS + 'Info.plist']
const INFRA_TASK = [
  'TASK: the "Infrastructure" section of IOS_ARCHITECTURE.md.',
  'YOUR FILES: ' + IOS + 'BLE/BleCentral.swift, ' + IOS + 'BLE/BleCoordinator.swift, NEW ' + IOS + 'BLE/LocationTracker.swift, NEW ' + IOS + 'Data/CrashLog.swift, ' + IOS + 'BLE/AndroidRemoteClient.swift (only the AndroidRemoteStatus struct and its parse), ' + IOS + 'MagicMakerApp.swift, ' + IOS + 'Info.plist. You may make ONE-LINE call-site edits in ' + IOS + 'ViewModels/AppViewModel.swift where a callback signature you changed is assigned.',
  'Android references: ' + AND + 'ble/BleScanner.kt, ' + AND + 'core/HexUtils.kt (payload candidate extraction), ' + AND + 'core/CrashLog.kt, the location code in ' + AND + 'service/MagicMakerForegroundService.kt (startLocationUpdates/stopLocationUpdates/lastLocation), ' + AND + 'service/ServiceState.kt statusJson, and the "scan", "map" and "diag" entries of the parity map.',
  '1) BleCentral: `BleCentralDelegate.bleCentral(didReceive hex: String, rssi: Int, address: String)` — address is `peripheral.identifier.uuidString.uppercased()`. Remove the 1.5 s `recentKeys` dedupe entirely (every advert is delivered). Build the payload from ALL candidates present in the advertisement (manufacturer data, service data values, service UUID bytes, local name) using the HexUtils candidate helpers that now exist in Core/HexUtils.swift (read it: extractDisneyCandidates / bestDisneyHex or whatever they are named) so the choice matches Android. Add `private(set) var stateDescription: String` updated in centralManagerDidUpdateState ("Bluetooth ready", "Turn on Bluetooth", "Allow Bluetooth in Settings", "Bluetooth unavailable") and keep calling the existing delegate status method. Everything about the relay link (relayGatt, discovery, reconnect) must stay exactly as it is.',
  '2) BleCoordinator: `var onPacket: ((String, Int, String) -> Void)?` (hex, rssi, address) and pass it through; add `var onBluetoothState: ((String) -> Void)?` fired on state changes; keep everything else (play, updateModes, the legacy auto path) compiling and behaving as before. Add a method the new send engine can use: `func send(hex: String, durationMs: Int, onComplete: @escaping (Bool) -> Void)` which transmits through the linked relay for exactly durationMs using the existing BleTransmitter.transmit(hex:durationMs:onComplete:) path (read BLE/BleTransmitter.swift; if its completion carries no success flag, add one there without changing existing callers\' behaviour), pausing/resuming the local Disney scan around it the same way `play` does, and reporting false when no relay is ready. Update the single assignment of onPacket in ViewModels/AppViewModel.swift so it compiles (`{ [weak self] hex, rssi, _ in … }`).',
  '3) LocationTracker and CrashLog exactly as the architecture file says. CrashLog signal handlers must only use async-signal-safe calls (open/write/close on a path prepared in advance as a C string; no Swift allocation, no Foundation) and must re-raise with the default handler. Keep the log under 200 KB (trim the oldest half when larger) like Android trims. Call `CrashLog.install()` from MagicMakerApp.init().',
  '4) Info.plist: add NSLocationWhenInUseUsageDescription ("MagicMaker tags each captured packet with where it was heard, for the capture map."). Do not touch other keys.',
  '5) AndroidRemoteStatus: add `lastLightHex`, `lastLightLabel`, `lightsHeard`, `keepAwake: Bool?`, `txPowerLevel: Int?`, `txInterleave: Bool?`, `showControlOnly: Bool?` and parse them (all optional in the JSON). Keep Equatable.',
].join('\n')

const ENGINE_FILES = [IOS + 'ViewModels/ScanEngine.swift', IOS + 'ViewModels/TxEngine.swift', IOS + 'ViewModels/AppViewModel.swift', IOS + 'Views/LaunchBootstrapView.swift', IOS + 'Core/MagicModels.swift']

function reviewPrompt(what, files, kotlin, report) {
  return RULES + '\n\nTASK: adversarial review of ' + what + ' that another engineer just wrote without a compiler. Assume it contains mistakes and find them. You may edit ONLY: ' + files.join(', ') + '.\n' +
    'Android sources (the specification): ' + kotlin.join(', ') + '.\n' +
    'The author reported: ' + JSON.stringify(report || {}) + '\n\n' +
    'PASS 1 — be the Swift compiler, line by line, for every one of those files: every identifier and argument label resolved against its real definition (open the defining file — Core/, Data/, BLE/, ViewModels/ — do not trust memory); optionals; Int/Int64/Double/UInt8 mixing; String indexing; `let` initialised on every path; closures capturing self in a @MainActor class from a background queue (must hop back with `Task { @MainActor in }` or DispatchQueue.main.async); non-Sendable captures are fine in Swift 5 mode but calling a @MainActor method synchronously from a non-isolated closure is an error; protocol conformances complete (CLLocationManagerDelegate, CBCentralManagerDelegate methods have exact signatures); `@Published private(set)` used correctly; exhaustive switches; duplicate type/extension declarations across the module (grep the whole ios/MagicMaker tree for each new type name); Core/ files Foundation-only; braces balanced (count with python). Fix everything you find.\n' +
    'PASS 2 — be the Kotlin. Walk the Android source function by function and confirm the Swift does the same: conditions and order, caps and clamps, defaults, preference keys, file names, CSV columns and escaping, reason/status strings, dedupe rules, sort orders, which calls save and which do not. Trace six concrete scenarios end to end by hand and compare (first launch with no file; a wand colour heard twice; an unclassified packet from a tagged band and from a stranger; a ping; a session begin → three packets → end with the sidecars; export then import). Fix every difference.\n' +
    'PASS 3 — check the exact API in IOS_ARCHITECTURE.md is all there with the exact signatures, and that every existing call site elsewhere in ios/MagicMaker still compiles against these files.\n' +
    'Do not rewrite working code for style. Report what you fixed and what still worries you.'
}

phase('Store+Infra')
const [store, infra] = await parallel([
  () => agent(RULES + '\n\n' + STORE_TASK, { label: 'store', phase: 'Store+Infra', schema: PORT_SCHEMA }),
  () => agent(RULES + '\n\n' + INFRA_TASK, { label: 'infra', phase: 'Store+Infra', schema: PORT_SCHEMA }),
])

phase('Review 1')
const [storeReview, infraReview] = await parallel([
  () => agent(reviewPrompt('the iOS MagicStore port and session-log code', STORE_FILES, [AND + 'data/MagicStore.kt', AND + 'core/MagicModels.kt', AND + 'core/TransmitTiming.kt'], store), { label: 'review:store', phase: 'Review 1', schema: REVIEW_SCHEMA, effort: 'high' }),
  () => agent(reviewPrompt('the iOS BLE source-id passthrough, LocationTracker, CrashLog and relay-status parsing', INFRA_FILES.concat([IOS + 'BLE/BleTransmitter.swift']), [AND + 'ble/BleScanner.kt', AND + 'core/HexUtils.kt', AND + 'core/CrashLog.kt', AND + 'service/MagicMakerForegroundService.kt', AND + 'service/ServiceState.kt'], infra), { label: 'review:infra', phase: 'Review 1', schema: REVIEW_SCHEMA, effort: 'high' }),
])

phase('Engines')
const engines = await agent(
  RULES + '\n\nTASK: the "ScanEngine", "TxEngine" and "AppViewModel wiring" sections of IOS_ARCHITECTURE.md.\n' +
  'YOUR FILES: NEW ' + IOS + 'ViewModels/ScanEngine.swift, NEW ' + IOS + 'ViewModels/TxEngine.swift, ' + IOS + 'ViewModels/AppViewModel.swift (additive wiring only — every existing member the views use must stay), ' + IOS + 'Views/LaunchBootstrapView.swift (inject the extra environment objects), ' + IOS + 'Core/MagicModels.swift (add the LivePacket, SeenAddress, SourceStat structs from the architecture file; nothing else).\n' +
  'The store and infrastructure were just written and reviewed by others — READ the real files before using them: ' + IOS + 'Data/MagicStore.swift, ' + IOS + 'Core/SessionLog.swift, ' + IOS + 'Core/TransmitTiming.swift, ' + IOS + 'BLE/BleCoordinator.swift, ' + IOS + 'BLE/BleCentral.swift, ' + IOS + 'BLE/BleTransmitter.swift, ' + IOS + 'BLE/LocationTracker.swift, ' + IOS + 'Data/CrashLog.swift, ' + IOS + 'BLE/AndroidRemoteClient.swift, ' + IOS + 'BLE/RelayBackend.swift. Their authors and reviewers reported: ' + JSON.stringify({ store, storeReview, infra, infraReview }) + '\n' +
  'Android sources to port from: ' + AND + 'service/MagicMakerForegroundService.kt (read ALL of it: handleHeard, onHeard, ensureLoggingStarted/stopLogging, scan start/stop intent handling and prefs, queueSend, enqueueRadioWork/drainRadioQueue/finishRadioWork, runManufacturerTx, the Starlight loop, TX loop, random show, replay, loadPrefs/savePrefs, dispatchCommand) and ' + AND + 'service/ServiceState.kt (appendLive, source stats, seen addresses, clearLive/removeLive/removeRawLive), plus ' + AND + 'core/MagicTransmitter.kt for how a send is sequenced. Also the "scan", "tabs" and "settings" entries of the parity map.\n' +
  'Implement ScanEngine and TxEngine with exactly the API in the architecture file. Notes:\n' +
  '- ScanEngine publishes with a 200 ms throttle (plain private(set) vars + objectWillChange.send()); TxEngine uses @Published.\n' +
  '- ScanEngine.start(): read scan_active / record_session / auto_enabled (UserDefaults, Android defaults true/true/true) and apply. setScan(true) calls onScanWanted(true) and, like Android\'s ensureLoggingStarted, opens a log session; setScan(false) stops scanning and ends the session. setRecording follows Android\'s ACTION_SET_RECORDING.\n' +
  '- handleHeard must not do any slow work synchronously beyond what the store does; it runs for every advertisement.\n' +
  '- TxEngine sends via `radioSend`. For a band command Android transmits wake ping then the command (the relay does the wake itself here), so one radioSend per packet with the burst duration; wait for its completion before the next queued send. Replay steps and stacked auto-responses go through the same queue. While keep-awake is active on the relay nothing changes on the iPhone side.\n' +
  '- TX loop / Starlight loop packet lookup uses store.findTransmitPacket / findLearnedStarlight (and NewWandCatalog ids), labels and state strings as Android. Random show uses LabPacketBuilder.buildRandomShow().\n' +
  '- AppViewModel: create store/location/scan/tx in init (replace the lazy `_store`, keeping a `var store: MagicStore` accessor), wire the closures as the architecture file says, forward packets from BleCoordinator.onPacket to scan.handleHeard, forward Bluetooth state to scan.noteBluetoothStatus, start location + scan in bootstrapAfterLaunch, add labLoadTick / requestedTab / loadInLab(hex:label:) / importAndroidLibrary(). The legacy iScan feed code (appendLocalLivePacket etc.) stays so existing views compile, but it must not double-log or double-learn: the legacy path only fills its in-memory lists.\n' +
  '- LaunchBootstrapView: `.environmentObject(viewModel.store).environmentObject(viewModel.scan).environmentObject(viewModel.tx)` next to the existing one.',
  { label: 'engines', phase: 'Engines', schema: PORT_SCHEMA }
)

phase('Review 2')
const enginesReview = await agent(
  reviewPrompt('the iOS ScanEngine, TxEngine and AppViewModel wiring', ENGINE_FILES, [AND + 'service/MagicMakerForegroundService.kt', AND + 'service/ServiceState.kt', AND + 'core/MagicTransmitter.kt'], engines) +
  '\nExtra scenarios for PASS 2: a packet arrives while the show-control filter is on and it is band telemetry; a light effect arrives inside the 250 ms throttle window; an auto rule with two stacked responses fires twice within 800 ms; TX loop is started while the Starlight loop is running; replay of a 5-row log with one row filtered out; the relay drops mid-loop.',
  { label: 'review:engines', phase: 'Review 2', schema: REVIEW_SCHEMA, effort: 'high' }
)

phase('Integrate')
const integrate = await agent(
  RULES + '\n\nTASK: whole-target integration check after the store, infrastructure and engines were written by different engineers. You may edit any Swift file under ' + IOS + ' with the smallest possible edits to make the app target compile; do not change behaviour that matches Android.\n' +
  'Reports: ' + JSON.stringify({ store, storeReview, infra, infraReview, engines, enginesReview }) + '\n' +
  '1) For every file changed or created in this phase (run `git -C /home/user/Magicmaker-mobile status --short` and `git diff --stat`), re-read it fully and check each cross-file reference against the real definition: names, labels, argument order, optionality, return types, actor isolation.\n' +
  '2) Grep ios/MagicMaker for every public member that changed or was removed (compare `git diff` of Data/MagicStore.swift, BLE/BleCoordinator.swift, BLE/BleCentral.swift, ViewModels/AppViewModel.swift, Core/MagicModels.swift) and make every remaining use compile — especially in Views/RemoteTab.swift, Views/ContentView.swift, Views/BandPreviewView.swift, Views/StarlightWandView.swift, Views/LabBuilderPanel.swift, Views/AppTheme.swift.\n' +
  '3) Duplicate declarations across the module (same type or extension twice). Missing imports (CoreLocation, CoreBluetooth, UIKit, Combine where ObservableObject/@Published are used without SwiftUI).\n' +
  '4) @MainActor isolation: delegate callbacks from CoreLocation/CoreBluetooth and closures run on background queues must hop to the main actor before touching @MainActor state; a `nonisolated` delegate method must not read isolated properties directly.\n' +
  '5) Brace/paren/bracket balance by python for every changed file.\n' +
  'List every new file that must be added to the Xcode project (path relative to ios/MagicMaker). Report every edit and remaining risk.',
  { label: 'integrate', phase: 'Integrate', effort: 'high', schema: {
    type: 'object',
    properties: {
      edits: { type: 'array', items: { type: 'string' } },
      newFilesForXcodeProject: { type: 'array', items: { type: 'string' } },
      risks: { type: 'array', items: { type: 'string' } },
      summary: { type: 'string' },
    },
    required: ['edits', 'newFilesForXcodeProject', 'risks', 'summary'],
  } }
)

return { store, storeReview, infra, infraReview, engines, enginesReview, integrate }
