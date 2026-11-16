export const meta = {
  name: 'ios-screens',
  description: 'iOS screens ported from the Android tabs: Scan, TX, Wand, Auto, Lab, Logs, Map, Diag, Settings, Link (phase C)',
  phases: [
    { title: 'Shared', detail: 'shared rows, sheets, slider, tab bar' },
    { title: 'Screens', detail: 'five groups of screens ported from the Compose tabs' },
    { title: 'Review', detail: 'each group checked against the Kotlin and for compile errors' },
    { title: 'Root', detail: 'Link screen, ten-tab root, remove the old remote views' },
    { title: 'Integrate', detail: 'whole-target consistency' },
  ],
}

const S = '/tmp/claude-0/-home-user-Magicmaker-mobile/8956e220-2c18-5594-88a6-966886e08e67/scratchpad/'
const RULES = 'FIRST read ' + S + 'IOS_PORT_RULES.md, ' + S + 'IOS_ARCHITECTURE.md and ' + S + 'IOS_SCREENS.md in full and follow them exactly. There is no Swift compiler here; your code is compiled later in CI, so precision matters more than speed. The Core logic, MagicStore, ScanEngine, TxEngine and the AppViewModel wiring already exist and compile — open the real Swift files and use their exact names; do not re-implement them and do not change their behaviour (if a screen needs something an engine lacks, add the smallest possible accessor to that engine and report it).'
const UI = '/home/user/Magicmaker-mobile/android/app/src/main/java/com/magicmaker/android/ui/'
const AND = '/home/user/Magicmaker-mobile/android/app/src/main/java/com/magicmaker/android/'
const IOS = '/home/user/Magicmaker-mobile/ios/MagicMaker/'

const PORT_SCHEMA = {
  type: 'object',
  properties: {
    filesCreated: { type: 'array', items: { type: 'string' } },
    filesChanged: { type: 'array', items: { type: 'string' } },
    filesDeleted: { type: 'array', items: { type: 'string' } },
    apiAddedOrChanged: { type: 'array', items: { type: 'string' } },
    androidControlsNotPorted: { type: 'array', items: { type: 'string' } },
    unsure: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
  required: ['filesCreated', 'filesChanged', 'summary'],
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

phase('Shared')
const shared = await agent(
  RULES + '\n\nTASK: write ' + IOS + 'Views/SharedViews.swift — the shared components listed under "Shared components" in IOS_SCREENS.md. Five other engineers will build ten screens on top of this file right after you, so the API must be complete, simple and obviously correct.\n' +
  'Read the Android shared composables you are mirroring: ' + UI + 'SwipePacketRow.kt, ' + UI + 'PacketActionSheet.kt, ' + UI + 'SettingSlider.kt, ' + UI + 'AppTheme.kt, and in ' + UI + 'MagicMakerScreens.kt: SectionFilterDropdown, CollapsibleSectionHeader, ConfirmDeleteDialog, CategoryPickerDialog, RenameDialog, liveSubtitle. Read the existing iOS pieces in ' + IOS + 'Views/AppTheme.swift (MMTheme, MMCompactButton, MMPrimaryButton, RemotePacketRow, SwipeRemotePacketRow, CollapsibleSectionHeader, MMCompactTabBar) and match their look.\n' +
  'Write, with doc comments that show a usage example for each:\n' +
  '- `struct PacketRow: View` — init(label: String, hex: String, subtitle: String = "", accent: Color? = nil, tag: String? = nil, selected: Bool = false, onTap: @escaping () -> Void, onLongPress: (() -> Void)? = nil). Two text lines plus the hex, uppercase tech style, full-width tappable, long-press via `.onLongPressGesture` that does not break swipe actions or scrolling (use `.contentShape(Rectangle())`, `.onTapGesture` + `.onLongPressGesture(minimumDuration: 0.4)`).\n' +
  '- `extension View { func mmListRow() -> some View }` (row background/insets/separator for a List row) and `extension View { func mmListStyle() -> some View }` (plain list, hidden scroll background, navy). A `struct MMListSectionHeader: View` (title, count, collapsed, action) for use as a List Section header.\n' +
  '- `struct PacketAction: Identifiable { let id = UUID(); let title: String; let destructive: Bool; let action: () -> Void }` with a convenience init (title:destructive: = false, action:), and `struct PacketSheetInfo: Identifiable` (id, title, hex, colorsLine, subtitle, actions: [PacketAction]) plus `extension View { func packetActionSheet(_ info: Binding<PacketSheetInfo?>) -> some View }` implemented with `.sheet(item:)` presenting a compact list of buttons (title, hex, COLORS line when not empty, subtitle, then one button per action; tapping one dismisses the sheet first and then runs the action on the next main-queue turn), `.presentationDetents([.medium])`.\n' +
  '- `struct DeleteRequest: Identifiable` (id, title, label, hex, confirm: () -> Void) and `extension View { func confirmDelete(_ request: Binding<DeleteRequest?>) -> some View }` using `.alert` with a destructive "REMOVE" and a cancel button, message = label + newline + hex.\n' +
  '- `struct CategoryPickRequest: Identifiable` (id, title, current: MagicCategory?, pick: (MagicCategory) -> Void) and `func categoryPicker(_:)` view extension (confirmationDialog listing MagicCategory.allCases with Android\'s names).\n' +
  '- `struct RenameRequest: Identifiable` (id, title, initial: String, save: (String) -> Void) and `func renamePrompt(_:)` view extension (alert with a TextField pre-filled with `initial`).\n' +
  '- `struct SettingSlider: View` — port of SettingSlider.kt: init(title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String = "", hint: String = "", onCommit: @escaping (Double) -> Void = { _ in }) with −/+ step buttons, the value text, and onCommit fired when dragging ends or a step button is tapped.\n' +
  '- `struct SectionFilterMenu: View` — init(visible: Binding<Set<LivePacketSection>>) showing "CLASS n/8" with a Menu of checkmarked sections.\n' +
  '- `struct MMScrollTabBar<Tab: Hashable & Identifiable>: View` — init(selection: Binding<Tab>, tabs: [Tab], title: @escaping (Tab) -> String, icon: @escaping (Tab) -> String): a horizontally scrolling bar of icon+label buttons that keeps the selected tab visible (ScrollViewReader, scrollTo on change), same colours as MMCompactTabBar.\n' +
  '- `struct StatusLine: View` (text, colour default dim) and `struct MMSectionTitle: View` (cyan tech header) and `struct MMPanel<Content: View>: View` (padded panel with the hairline border used across the app).\n' +
  '- `func shortAddress(_ address: String) -> String` (last 8 characters, uppercased; empty stays empty) and `func agoText(_ ms: Int64) -> String` ("3s", "2m", "1h" since a timestamp).\n' +
  'Keep the file self-contained (SwiftUI only), every type internal (not private) so other files can use it, no name that already exists anywhere in ios/MagicMaker (grep each name first). Report the exact final API.',
  { label: 'shared', phase: 'Shared', schema: PORT_SCHEMA }
)

const GROUPS = [
  {
    key: 'scan',
    files: [IOS + 'Views/ScanScreen.swift'],
    kotlin: [UI + 'MagicMakerScreens.kt', UI + 'SwipePacketRow.kt', UI + 'PacketActionSheet.kt', UI + 'BandPreview.kt', AND + 'service/ServiceState.kt', AND + 'core/LivePacketSort.kt'],
    task: 'YOUR FILE: NEW ' + IOS + 'Views/ScanScreen.swift (`struct ScanScreen: View`).\n' +
      'Port the Android SCAN tab for the iPhone\'s own scanner: in ' + UI + 'MagicMakerScreens.kt read ScanTab (all of it), ScanPacketList, liveSubtitle, BandConfigSection, LibraryFileSection, CategoryPickerDialog, RenameDialog, ConfirmDeleteDialog, CollapsibleSectionHeader, WideScreenColumns; plus ' + UI + 'SwipePacketRow.kt, ' + UI + 'PacketActionSheet.kt, LastHeardStrip in ' + UI + 'BandPreview.kt, ' + AND + 'core/LivePacketSort.kt. Read the "scan" entry of the parity map.\n' +
      'Requirements: the strip pinned at the top shows `scan.lastLightHex` with title "LAST LIGHTS · #<scan.lightsHeard>" (empty text "LAST LIGHTS · NONE HEARD YET") using the existing BandPreviewView(hex:compact:title:) at 40 pt height — only packets that light the band ever appear there. Below it the controls exactly as Android orders them (scan on/off, log on/off with the session name, clear, GROUPED/RAW, CLASS filter, show-control-only switch, counters, the hint line "TAP REPLAY · HOLD MENU · SWIPE ← DEL · SWIPE → TX/TAG"), collapsible like Android, then the live feed as a List so swipes work: swipe left = delete with confirmation (unique row → scan.removeLive(dedupeKey:), raw row → scan.removeRawLive), swipe right = the "Packet action" dialog (ADD TO TX → store.saveCustomPreset, RECATEGORIZE → category picker → store.recategorizePacket after making sure the packet is in the library the way Android does), tap = replay through the relay (tx.transmit), long-press = the action sheet (Transmit, Load in Lab, Add to TX library, Recategorize, Remove). Each row shows what Android\'s row shows (label, hex, liveSubtitle with RSSI / note / short source id, BAND tag). GROUPED view uses LivePacketSort sections with collapsible headers and persisted collapse state (UserDefaults, same idea as Android UiPrefs). MY MAGICBAND section: the last 8 seen source ids with rssi/count and TAG / UNTAG (store.addBandAddress / removeBandAddress), the tagged list, saved-band count and delete. LIBRARY FILE section: EXPORT (store.exportLibrary() → ShareLink / share sheet) and IMPORT (.fileImporter → store.importLibrary(from:)) with Android\'s result messages.',
  },
  {
    key: 'txwand',
    files: [IOS + 'Views/TxScreen.swift', IOS + 'Views/WandScreen.swift', IOS + 'Views/StarlightWandView.swift'],
    kotlin: [UI + 'MagicMakerScreens.kt', UI + 'StarlightWandView.kt', AND + 'core/NewWandCatalog.kt', AND + 'service/MagicMakerForegroundService.kt'],
    task: 'YOUR FILES: NEW ' + IOS + 'Views/TxScreen.swift (`struct TxScreen: View`), NEW ' + IOS + 'Views/WandScreen.swift (`struct WandScreen: View`); you may edit ' + IOS + 'Views/StarlightWandView.swift only if the Android wand view has something it lacks.\n' +
      'Port the Android TX and WAND tabs onto the iPhone\'s own library: in ' + UI + 'MagicMakerScreens.kt read TransmitTab, TxSwipeRow, TxLoopSettingsSection, SectionFilterDropdown, WandTab, NewWandList, isNewWandHex / loadNewWandNames / saveNewWandName; ' + UI + 'StarlightWandView.kt. The existing iOS remote versions are RemoteTxView / RemoteWandView / NewWandList in ' + IOS + 'Views/RemoteTab.swift (read them for layout ideas and for the pieces that already work: New Wand names and the wand quick button live in AppViewModel — keep using those). Read the "tabs" and "settings" entries of the parity map.\n' +
      'TX: rows = store.allTransmitPackets() grouped with LivePacketSort.groupedMagicPackets, section filter, collapsible sections with persisted state, Android\'s row subtitle; tap = tx.transmit; long-press sheet = Transmit / Load in Lab / Rename / Recategorize / Delete (built-in presets cannot be deleted, as on Android); swipe left = delete with confirm; swipe right = recategorize; TX LOOP controls (pick the packet, interval slider with Android\'s range and step, start/stop → tx.setTxLoop) with the loop label/state from TxEngine; VIBRATE and INTERROGATE buttons; TRANSMISSION settings exactly as TxLoopSettingsSection shows them.\n' +
      'WAND: the wand view showing vm.wandDisplayColorIndex, the learned Starlight colours (store.learnedStarlightPackets()) as on Android, tap = send that colour (tx.transmit; update the wand display), WAND LOOP controls (tx.setStarlightLoop), the Starlight burst slider, delete one colour / CLR LIB with confirmation, the New Wand mode with the generated list (store.newWandPackets()), custom names, the quick button, and every label and count as Android shows them.',
  },
  {
    key: 'autosetdiag',
    files: [IOS + 'Views/AutoScreen.swift', IOS + 'Views/SettingsScreen.swift', IOS + 'Views/DiagScreen.swift'],
    kotlin: [UI + 'MagicMakerScreens.kt', UI + 'LabPacketBuilderPanel.kt', UI + 'LabBuilderUi.kt', UI + 'SettingSlider.kt', AND + 'core/PacketPatterns.kt', AND + 'core/CrashLog.kt', AND + 'service/ServiceState.kt'],
    task: 'YOUR FILES: NEW ' + IOS + 'Views/AutoScreen.swift (`struct AutoScreen: View`), NEW ' + IOS + 'Views/SettingsScreen.swift (`struct SettingsScreen: View`), NEW ' + IOS + 'Views/DiagScreen.swift (`struct DiagScreen: View`).\n' +
      'AUTO: port AutoTab from ' + UI + 'MagicMakerScreens.kt: the arm switch (scan.autoEnabled / scan.setAuto), counters, the rule list (enable/disable, delete with confirm, the trigger → responses description exactly as Android words it), and the rule builder: name, trigger picker (PacketPatterns.buildTriggerOptions with learned + user presets), a response STACK built from a picker (PacketPatterns.buildResponseOptions, New Wand codes including the random one), then store.addAutoRule(name:triggerId:responseIds:responseHexes:). Read ' + AND + 'core/PacketPatterns.kt and its Swift port for the option lists.\n' +
      'SETTINGS: find SettingsTabScreen (grep in ' + UI + ') and port every section and control with the same titles, hints, ranges, steps and defaults: wake preamble / command burst / Starlight burst sliders (store get/save…, and when an Android relay is linked also push the value with the existing vm.setAndroidWakeupPreamble / setAndroidCommandBurst / setAndroidStarlightBurst), TX MODE (sustained / interleave) and BROADCAST STRENGTH (store get/saveTxInterleave / TxPowerLevel; these act on an Android relay: send the relay commands `set_tx_interleave {enabled}` / `set_tx_power {level}` through a new small AppViewModel method `sendRelaySetting(_ action: String, _ params: [String: Any])` that wraps the existing remote.sendCommand — add that one method to ' + IOS + 'ViewModels/AppViewModel.swift), the show-control-only scan filter, random light show interval if Android has it there, anything else on that screen that is not Android-only. Add an ABOUT line with the app version (Bundle short version + build).\n' +
      'DIAG: port DiagnosticsTab and SourceRow: the status block (Bluetooth state, scan/log state, RX and lights counters, auto replies sent, relay link, location authorisation), BROADCAST SOURCES from scan.sources with the same columns, sort and priority marking, and the crash log viewer (CrashLog.read(), CLEAR with confirm, share).',
  },
  {
    key: 'lab',
    files: [IOS + 'Views/LabScreen.swift', IOS + 'Views/LabBuilderPanel.swift'],
    kotlin: [UI + 'LabPacketBuilderPanel.kt', UI + 'LabBuilderUi.kt', UI + 'BandPreview.kt', AND + 'core/LabPacketBuilder.kt', AND + 'core/LabPacketTools.kt', AND + 'core/DisneyTlv.kt', AND + 'core/MbleBeaconBuilder.kt'],
    task: 'YOUR FILES: NEW ' + IOS + 'Views/LabScreen.swift (`struct LabScreen: View`), and you may edit ' + IOS + 'Views/LabBuilderPanel.swift.\n' +
      'Port the Android LAB tab: read ALL of ' + UI + 'LabPacketBuilderPanel.kt and ' + UI + 'LabBuilderUi.kt, and the existing iOS Lab: RemoteLabView in ' + IOS + 'Views/RemoteTab.swift (mode bar with the Standard/Extended switch and keep-awake, the pinned band preview at one sixth of the height, hex field, SEND, MBLE section) and ' + IOS + 'Views/LabBuilderPanel.swift. Read the "tabs" and "core" entries of the parity map.\n' +
      'LabScreen keeps what RemoteLabView does today and adds what Android has: the Lab packet persists (store.getLabHex / saveLabHex / getLabLabel / saveLabLabel; reload when vm.labLoadTick changes, as Android reloads on labLoadTick); the single SEND button calls tx.transmit; a LABEL field with SAVE (store.saveCustomPreset, showing its error text) and TAG (store.applyLabLabelToMatchingRaw); MY PRESETS list (store.customPresets: tap to load, delete with confirm); LOAD HEX / decode of a loaded packet back into the builder fields with LabPacketBuilder.decode (and Android\'s "Loaded … from received packet" line); the summary card driven by the packet itself (classification label, DisneyTlv effect name, timing caption, framing, buzz, validity) as Android computes it; PACKET ANATOMY (DisneyTlv.anatomy segments as coloured chips, tap one to read its detail); PACKET INSPECTOR (live classification, the vibration stepper using LabPacketTools.tailVibration / withVibration, the per-byte hex grid with tap-to-edit as on Android); RANDOM LIGHT SHOW (tx.setRandomShow with the interval control and the current label); the transmission settings block if Android shows one in the Lab. Extended mode keeps its RGB sliders, LED masks and experiments.',
  },
  {
    key: 'logsmap',
    files: [IOS + 'Views/LogsScreen.swift', IOS + 'Views/MapScreen.swift', IOS + 'Core/LogAnalysis.swift', IOS + 'Core/MapMath.swift'],
    kotlin: [UI + 'MagicMakerScreens.kt', UI + 'MapTab.kt', AND + 'data/MagicStore.kt', AND + 'service/MagicMakerForegroundService.kt'],
    task: 'YOUR FILES: NEW ' + IOS + 'Views/LogsScreen.swift (`struct LogsScreen: View`), NEW ' + IOS + 'Views/MapScreen.swift (`struct MapScreen: View`), NEW ' + IOS + 'Core/LogAnalysis.swift and NEW ' + IOS + 'Core/MapMath.swift (Foundation only: the pure maths both screens need).\n' +
      'LOGS: port LogsTab from ' + UI + 'MagicMakerScreens.kt in full: the session list (name, size, packet count, modified time, newest first; the active session marked), opening a log (read off the main thread via store.readLog), the per-log filters (type/category chips, source id, band-only), the chronological rows, ANALYZE (unique packets grouped by MagicClassifier.groupKey with counts, "hide bands and pings" using MagicClassifier.isLibraryNoise, the noise count), row actions (tap to transmit via tx.transmit, NAME → store.saveCustomPreset), ADD ALL → LIB (store.importHexesToLibrary with Android\'s result text), REPLAY with the same filters (tx.startReplay(path:categories:address:bandOnly:)), the progress banner with STOP (tx.replayActive / replayProgress / replayTotal / replayLabel, tx.stopReplay()), DELETE with confirmation (store.deleteLog). iOS addition: a SHARE button for the open log file (ShareLink on its file URL). Put the grouping/counting in Core/LogAnalysis.swift as pure functions over [LoggedPacket].\n' +
      'MAP: port ' + UI + 'MapTab.kt in full with MapKit: load points off the main thread with store.forEachLoggedLocation (check how MagicStore exposes it and whether it must be called on the main actor — if so, use the non-isolated SessionLogFiles helper the store file provides), bucket capture points and estimate transmitter positions with exactly the Kotlin constants and formulas (bucket size, the RSSI weighting, the minimum-observation threshold, the uncertainty radius) in Core/MapMath.swift, show capture markers, transmitter pins with uncertainty circles (MapCircle), the CAPTURES / TRANSMITTERS / BOTH switch, the counts line, the empty state text, a refresh action, and centre on the data (or the current location from vm.location when there is none). Marker tap shows what Android\'s info window shows.',
  },
]

function reviewPrompt(g, report) {
  return RULES + '\n\nTASK: adversarial review of iOS screens another engineer just wrote without a compiler. Assume there are mistakes and find them. You may edit ONLY: ' + g.files.join(', ') + '.\n' +
    'Android sources (the specification): ' + g.kotlin.join(', ') + '.\n' +
    'The author reported: ' + JSON.stringify(report || {}) + '\n\n' +
    'PASS 1 — be the Swift compiler, line by line. For every identifier, initialiser and argument label, open the real definition (Views/SharedViews.swift, Views/AppTheme.swift, the engines, the store, Core/) and check name, labels, order, optionality and types. Check: view builders contain only views/if/switch/ForEach/let; every `ForEach` has stable ids; bindings are real `Binding`s (engine values are private(set): must be `Binding(get:set:)`); `.sheet(item:)`/`.alert` state types are Identifiable where needed; `.onChange` uses the two-parameter form; no `private` type name clashes with another file\'s internal type (grep the module for every type and top-level function name declared in these files); enum switches exhaustive; Int/Int64/Double conversions explicit; no force unwraps on data; optional chaining results used correctly; closures that capture `self` in a struct are fine but `mutating` state must be @State; long bodies split up (any `body` or builder with more than ~10 children or deeply nested generics must be broken into smaller properties — do it); string interpolation with nested quotes valid; no Java-style escapes; braces/parens/brackets balanced (count with python).\n' +
    'PASS 2 — be the Kotlin. Walk the Android composables control by control and confirm the screen has each one with the same label, hint, default, range, enabled-condition, confirmation and result text, and that each action calls the right store/engine function with the right arguments. List anything Android has that is missing and add it (unless IOS_SCREENS.md says it is Android-only).\n' +
    'PASS 3 — behaviour traps: swipe actions only inside List; no List inside ScrollView; heavy work off the main thread; views that read the library re-read on store.revision; nothing calls the old vm.transmitAndroidHex / androidCatalog for local data.\n' +
    'Fix everything directly. Do not rewrite working code for style. Report what you fixed and what still worries you.'
}

phase('Screens')
const screens = await pipeline(
  GROUPS,
  g => agent(RULES + '\n\nShared components were just written — read ' + IOS + 'Views/SharedViews.swift first; its author reported: ' + JSON.stringify(shared || {}) + '\n\nTASK: ' + g.task + '\nEvery control on the Android screen must exist on the iOS screen unless IOS_SCREENS.md lists it as Android-only; report anything you did not port in androidControlsNotPorted with the reason.', { label: 'screen:' + g.key, phase: 'Screens', schema: PORT_SCHEMA }),
  (port, g) => agent(reviewPrompt(g, port), { label: 'review:' + g.key, phase: 'Review', schema: REVIEW_SCHEMA, effort: 'high' })
    .then(review => ({ key: g.key, port, review }))
)
const done = screens.filter(Boolean)
log('screens done: ' + done.map(d => d.key).join(', '))

phase('Root')
const root = await agent(
  RULES + '\n\nTASK: the LINK screen, the ten-tab root, and removal of the old remote-control screens. The ten screens other engineers wrote: ' + JSON.stringify(done.map(d => ({ key: d.key, files: (d.port || {}).filesCreated, api: (d.port || {}).apiAddedOrChanged, concerns: (d.review || {}).remainingConcerns }))) + '\n' +
  'YOUR FILES: NEW ' + IOS + 'Views/LinkScreen.swift (`struct LinkScreen: View`), ' + IOS + 'Views/ContentView.swift, ' + IOS + 'Views/AppTheme.swift, ' + IOS + 'Views/BandPreviewView.swift (only to remove the old LastHeardStrip if nothing uses it any more), ' + IOS + 'Views/RemoteTab.swift (to be deleted), ' + IOS + 'ViewModels/AppViewModel.swift (cleanup), ' + IOS + 'Core/ISCanBackupLogger.swift (to be deleted).\n' +
  '1) LinkScreen: move RemoteLinkView / RemoteLinkTabView and the Android remote scan panel (RemoteScanView: the relay phone\'s own RX feed, its Scan / Log / Clr / Vib buttons and its auto-response switch) out of Views/RemoteTab.swift into LinkScreen.swift, keeping their behaviour, with the remote feed rendered in a List so its swipe actions work. Add an "IMPORT ANDROID LIBRARY" button (vm.importAndroidLibrary()) with the number of packets added, shown when an Android catalog is available. Relay backend picker, pairing by QR, IP entry, retry and status stay as they are.\n' +
  '2) ContentView: ten tabs in Android\'s order (SCAN, TX, WAND, AUTO, LINK, LOGS, MAP, DIAG, LAB, SETTINGS) using MMScrollTabBar from Views/SharedViews.swift and SF Symbols icons; start on SCAN like Android; switch to the Lab when vm.requestedTab asks for it (then clear it). Keep the periodic relay refresh logic that is there now. The telemetry line at the top becomes a port of Android\'s TelemetryLine (in ' + UI + 'MagicMakerScreens.kt) built from the iPhone\'s own state (scan.packetsHeard, scan.lightsHeard, scan.autoResponsesSent, scan/log/auto/loop/replay flags from ScanEngine and TxEngine, relay link state) — update TelemetryBar in Views/AppTheme.swift.\n' +
  '3) Delete Views/RemoteTab.swift entirely once LinkScreen has what it needs (RemoteTxView, RemoteWandView, RemoteAutoView, RemoteLabView, RemoteScanTabView, ISCanView, RemoteMoreView, MoreThemesView, MoreLightningLaneView and their helpers are replaced or unreachable). Use `git rm` is NOT allowed — just delete the file with `rm` on that exact path and report it in filesDeleted. Before deleting, grep the whole ios/MagicMaker tree for every type and function it declares and make sure nothing else uses them (RemoteUIState in ContentView.swift goes too if unused; move anything still needed).\n' +
  '4) AppViewModel cleanup: remove the legacy iPhone scan feed and logging that the engines replaced (iscanUniqueLive / iscanRawLive / appendLocalLivePacket / maybeIscanAutoRespond / iscanAutoEnabled / isBackupLogging / backupLogFileName / livePackets / isRecording / isAutoEnabled / toggleRecording / setLocalListening and friends), but ONLY members that no remaining file uses — grep each one. Then delete Core/ISCanBackupLogger.swift if unused (and report it; it must also leave the parity workflow\'s file list, which the lead edits). BleCoordinator\'s legacy auto path can stay if removing it is risky.\n' +
  '5) Old LastHeardStrip in Views/BandPreviewView.swift: delete it if ScanScreen has its own strip and nothing references it.\n' +
  'Finish by grepping for every identifier you removed. Report files created, changed and deleted.',
  { label: 'root', phase: 'Root', schema: PORT_SCHEMA }
)

const rootReview = await agent(
  reviewPrompt({ files: [IOS + 'Views/LinkScreen.swift', IOS + 'Views/ContentView.swift', IOS + 'Views/AppTheme.swift', IOS + 'Views/BandPreviewView.swift', IOS + 'ViewModels/AppViewModel.swift'], kotlin: [UI + 'MagicMakerScreens.kt'] }, root) +
  '\nExtra for this review: confirm nothing in ios/MagicMaker still references a type, function or property that was deleted with Views/RemoteTab.swift, Core/ISCanBackupLogger.swift or the AppViewModel cleanup (grep each deleted name), and that every one of the ten screens is reachable from ContentView.',
  { label: 'review:root', phase: 'Root', schema: REVIEW_SCHEMA, effort: 'high' }
)

phase('Integrate')
const integrate = await agent(
  RULES + '\n\nTASK: whole-target integration check after ten screens, the shared components and the root were written by different engineers without a compiler. You may edit any Swift file under ' + IOS + ' with the smallest possible edits to make the app target compile; do not change behaviour.\n' +
  'Reports: ' + JSON.stringify({ shared, screens: done, root, rootReview }) + '\n' +
  '1) List every Swift file under ios/MagicMaker and every top-level type / function / extension-method name declared in each (a python script with a regex is fine). Report and resolve every duplicate name across files (two internal types or functions with the same name in one module is a compile error; `private`/`fileprivate` ones only clash within their own file).\n' +
  '2) For every screen file, check each use of SharedViews, MMTheme, the engines, the store and Core against the real definitions (names, labels, optionality). Fix mismatches.\n' +
  '3) Grep for references to anything that no longer exists (RemoteTab types, RemoteUIState, ISCanBackupLogger, removed AppViewModel members, androidLabHex if removed, LastHeardStrip…).\n' +
  '4) Imports: MapKit / CoreLocation / UniformTypeIdentifiers / UIKit where used. Environment objects: every screen\'s @EnvironmentObject types are injected at the root (LaunchBootstrapView / ContentView).\n' +
  '5) Core/ files must be Foundation-only. Balance braces/parens/brackets for every file changed in this phase with python.\n' +
  'Report: every edit, the full list of files to ADD to and REMOVE from the Xcode project (paths relative to ios/MagicMaker), new Core files for the Linux parity build list, and remaining risks.',
  { label: 'integrate', phase: 'Integrate', effort: 'high', schema: {
    type: 'object',
    properties: {
      edits: { type: 'array', items: { type: 'string' } },
      addToXcodeProject: { type: 'array', items: { type: 'string' } },
      removeFromXcodeProject: { type: 'array', items: { type: 'string' } },
      newCoreFiles: { type: 'array', items: { type: 'string' } },
      risks: { type: 'array', items: { type: 'string' } },
      summary: { type: 'string' },
    },
    required: ['edits', 'addToXcodeProject', 'removeFromXcodeProject', 'risks', 'summary'],
  } }
)

return { shared, screens: done, root, rootReview, integrate }
