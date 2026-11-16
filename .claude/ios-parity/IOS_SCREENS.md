# iOS screens for Android parity (phase C contract)

Read `IOS_PORT_RULES.md` and `IOS_ARCHITECTURE.md` (same directory) first. The engines and store described
there now exist — open the real Swift files for exact names before you use anything:
`ios/MagicMaker/Data/MagicStore.swift`, `ViewModels/ScanEngine.swift`, `ViewModels/TxEngine.swift`,
`ViewModels/AppViewModel.swift`, `Core/*.swift`, `BLE/LocationTracker.swift`, `Data/CrashLog.swift`.

## Goal

Every Android tab gets an iOS screen that does the same job with the same controls, wording and behaviour,
using the iPhone's own data (its scanner, its library, its logs). The Kotlin composables are the
specification: read the whole composable you are porting, and port every control, label, hint, empty state,
confirmation and status string. Android file: `android/app/src/main/java/com/magicmaker/android/ui/`.

What is different on iOS, by design:

- Sending always goes through the linked relay: call `tx.transmit(hex:label:)` (or the loop / replay calls on
  `TxEngine`). Never call the old `vm.transmitAndroidHex` from a new screen. When no relay is linked
  (`vm.remoteLinkReady == false`) the control stays enabled and the engine reports why nothing was sent;
  screens show `tx.status` where Android shows the service status.
- Source addresses are CoreBluetooth peripheral UUID strings, not MACs. Show the last 8 characters where
  Android shows a MAC. There is no manual MAC entry.
- Files live in the app's Documents folder: use `ShareLink` to hand a file to the user and `.fileImporter`
  to pick one, where Android writes to / reads from shared storage.
- Android-only items are left out without a placeholder: battery-optimisation banner, RUN IN BACKGROUND /
  start on boot, all-files access, APK update, relay *host* mode (hotspot, GATT server), cloud dictionary sync.

## Tabs (same order as Android)

`SCAN, TX, WAND, AUTO, LINK, LOGS, MAP, DIAG, LAB, SETTINGS` — LINK is the iOS counterpart of Android's
RELAY tab (the iPhone is the client). Each screen is a `struct <Name>Screen: View` with NO init parameters,
in its own file under `ios/MagicMaker/Views/`, reading what it needs from the environment:

```swift
@EnvironmentObject var vm: AppViewModel
@EnvironmentObject var store: MagicStore
@EnvironmentObject var scan: ScanEngine
@EnvironmentObject var tx: TxEngine
```

`MagicStore` publishes only `revision`; a view that shows library data reads it in `body` (so SwiftUI
tracks it) and calls the store's functions directly — do not copy lists into `@State` unless you refresh
them `.onChange(of: store.revision)`.

"Load in Lab" from any screen: `vm.loadInLab(hex:label:)` (it stores the packet and asks the root view to
switch to the Lab tab).

| Screen | File | Android source to port |
|---|---|---|
| `ScanScreen` | `Views/ScanScreen.swift` | `ScanTab`, `ScanPacketList`, `liveSubtitle`, `BandConfigSection`, `LibraryFileSection`, `CategoryPickerDialog`, `RenameDialog`, `ConfirmDeleteDialog` in `MagicMakerScreens.kt`; `SwipePacketRow.kt`; `PacketActionSheet.kt`; `LastHeardStrip` in `BandPreview.kt` |
| `TxScreen` | `Views/TxScreen.swift` | `TransmitTab`, `TxSwipeRow`, `TxLoopSettingsSection`, `SectionFilterDropdown` |
| `WandScreen` | `Views/WandScreen.swift` | `WandTab`, `NewWandList` and the new-wand name helpers; `StarlightWandView.kt` (iOS already has `Views/StarlightWandView.swift`) |
| `AutoScreen` | `Views/AutoScreen.swift` | `AutoTab` |
| `LabScreen` | `Views/LabScreen.swift` | everything in `LabPacketBuilderPanel.kt` and `LabBuilderUi.kt` that `LabTabScreen` shows (mode bar, preview, builder, hex field, SEND, label / SAVE / TAG, MY PRESETS, packet anatomy, packet inspector with the byte grid and vibration stepper, decode of a loaded packet, random light show, MBLE section, transmission settings). iOS already has `Views/LabBuilderPanel.swift`, `Views/BandPreviewView.swift` and `RemoteLabView` in `Views/RemoteTab.swift` — reuse and extend them |
| `LogsScreen` | `Views/LogsScreen.swift` | `LogsTab` (list, per-log filters, ANALYZE, ADD ALL → LIB, NAME, REPLAY with progress and STOP, DELETE) |
| `MapScreen` | `Views/MapScreen.swift` | `MapTab.kt` (MapKit instead of osmdroid) |
| `DiagScreen` | `Views/DiagScreen.swift` | `DiagnosticsTab`, `SourceRow`, crash-log viewer |
| `SettingsScreen` | `Views/SettingsScreen.swift` | `SettingsTabScreen` (find it with grep) and `SettingSlider.kt` |
| `LinkScreen` | `Views/LinkScreen.swift` | no Android twin: relay backend picker, pairing, link status, and the remote panel for an Android relay (its RX feed and switches), built from the existing `RemoteLinkView` / `RemoteScanView` in `Views/RemoteTab.swift` |

Pure logic a screen needs (analysis grouping for Logs, capture-point bucketing and transmitter estimates
for the Map, anything testable) goes in a Foundation-only file under `Core/` (e.g. `Core/LogAnalysis.swift`,
`Core/MapMath.swift`) with the same maths and constants as the Kotlin; tell the lead about every new file.

## Shared components (`Views/SharedViews.swift`, written first — read it before writing a screen)

Use these instead of inventing per-screen copies; they give every screen the same look and gestures as
Android's shared composables. Existing pieces in `Views/AppTheme.swift` (`MMTheme`, `MMCompactButton`,
`MMPrimaryButton`, `CollapsibleSectionHeader`) stay available.

- `PacketRow` — one packet line (label, hex, subtitle, optional colour dot / band tag), tap and long-press.
- `PacketList` helpers — a `List` styled for this app (plain, navy background, hidden separators, tight
  insets) so `.swipeActions` work; the section header style.
- `packetActionSheet` — the long-press sheet (Android `PacketActionSheet`): title, hex, colours line,
  subtitle, and a list of actions the caller passes in.
- `confirmDelete` — Android `ConfirmDeleteDialog` (title, label, hex, destructive confirm).
- `CategoryPickerSheet` / `RenamePrompt` — Android `CategoryPickerDialog` / `RenameDialog`.
- `SettingSlider` — Android `SettingSlider` (title, value text, −/+ step buttons, slider, range, step).
- `SectionFilterMenu` — Android `SectionFilterDropdown`.
- `MMScrollTabBar` — horizontally scrolling tab bar for ten tabs.
- `StatusLine` — one-line status text (dim, uppercase tech font).

## SwiftUI rules for this code base (no compiler here — these are the usual failures)

- Rows that swipe must be direct children of a `List` (`ForEach` inside `List`/`Section`). `.swipeActions`
  does nothing inside `ScrollView`/`VStack`. Do not nest a `List` inside a `ScrollView`.
- Keep every `body` and `@ViewBuilder` small: at most ~8 child views per container, and move each section
  into its own `private var sectionName: some View` or small `private struct`. Large bodies fail with
  "unable to type-check this expression in reasonable time".
- Inside view builders use only `if`/`if let`/`switch`/`ForEach`; no `guard`, no `return` in the middle, no
  variable assignment statements other than `let`.
- `ForEach` needs stable ids: use `Identifiable` models or `id: \.self` on unique `Hashable` values.
- Alerts with a text field: `.alert("Title", isPresented: $flag) { TextField("…", text: $text); Button("Save") {…}; Button("Cancel", role: .cancel) {} }`.
  Sheets: `.sheet(item:)` needs an `Identifiable` item.
- `.onChange(of:)` uses the two-parameter closure on iOS 17: `.onChange(of: x) { _, newValue in … }`.
- Colours and fonts come from `MMTheme`; labels are uppercase tech-style like the rest of the app.
- Binding to engine state: engines expose `private(set)` values plus setter functions, so build bindings
  with `Binding(get: { scan.scanActive }, set: { scan.setScan($0) })`.
- MapKit (iOS 17): `Map(position: $camera) { Annotation(…) { … }; MapCircle(center:radius:) }`,
  `import MapKit`. Location strings come from `LocationTracker`.
- Never block the main thread: reading a big log, listing logs, building map points → `Task.detached` or a
  background queue, then assign on the main actor.
- Private helper types in different files must not share a name unless they are `private`/`fileprivate`.
  Prefix file-local helpers with the screen name (`ScanRow`, `LogsFilterBar`) to avoid module-level clashes.
