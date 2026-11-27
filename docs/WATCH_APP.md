# MagicMaker for Apple Watch: design (v1)

Status: implementation spec. Scope: `ios/` (iPhone app, new watch app, Xcode project) and
`.github/workflows/ios-testflight.yml`. Nothing changes on Android or the ESP32.

The user asked for two things on the wrist:

1. **Quick transmit favourites**: one tap on the watch sends a packet starred on the iPhone.
2. **Cluster status**: the iPhone app, the ESP32 transmitter (Heltec V3 / classic ESP32 relay) and
   the Android phone (relay backend and scanner), as far as the iPhone knows today.

The watch never talks Bluetooth to a relay. It is a remote for the iPhone app: every send goes
watch → iPhone (WatchConnectivity) → the iPhone's linked relay, through the same code a tap on
the iPhone uses.

---

## 0. Decisions

| # | Decision |
|---|---|
| W1 | **Single-target watchOS 10 app** (SwiftUI, `WKApplication`), embedded in the iPhone app and shipped in the same TestFlight build. Bundle id `Com.lightwave.mmios.watchkitapp`, companion `Com.lightwave.mmios`, not independent. No complications or widgets in v1. |
| W2 | **Favourites live on the iPhone only**: a small Codable file in Application Support, separate from `MagicStore`, at most **24**. The iPhone sends the list to the watch, and the watch sends back only a favourite's id. |
| W3 | **One transport, both directions.** iPhone → watch: `updateApplicationContext` with `{v, at, favorites, status, theme, lastSend}`, sent at most every 2 s, and at once when the favourites or the theme change. Watch → iPhone: `sendMessage` with a reply handler (`send`, `stop_programs`, `refresh`), only while the iPhone is reachable. Nothing is queued: no `transferUserInfo`. |
| W4 | **A watch send is the iPhone row's own send.** It goes through `TxEngine.transmit` (and the loop rules of the TX and WAND tabs), so burst lengths, wake preambles, relay choice, loops and queueing are exactly the iPhone's. |
| W5 | **Status is what the iPhone knows today**: the selected relay backend's link state, its STATUS JSON (ESP32 battery, program, firmware, uptime; Android scan, auto, program), and the iPhone's own battery, scan, AUTO and last heard packet. Sync-hub heartbeats (SYNC_HUB_SPEC §9) are added later as optional fields; see §10. |
| W6 | **The watch link starts at app launch** (`MagicMakerApp.init`). A watch message that wakes the iPhone app in the background can start the app's engines with no screen (`BootstrapController.shared`). |
| W7 | **Look**: black background, monospaced SF type, the five VFD inks of the iPhone's VFD base colour (amber by default), large tap targets, solid "inverted" blocks for busy and selected states. |
| W8 | **Project change by one verified script** (Appendix A), run on a fresh read of `project.pbxproj`. CI drops its `PRODUCT_BUNDLE_IDENTIFIER` override, which would otherwise rename the watch app, and checks the embedded watch app after archiving. |

Files that do **not** change: `AppViewModel.swift`, `ScanEngine.swift`, `BLE/*`, `Sync/*`,
`MagicStore.swift`, the iPhone `Info.plist` and the entitlements. The only edit to a file the
latency workflow owns is an additive, defaulted `completion` parameter on `TxEngine.transmit`
(§4.6).

---

## 1. Baseline (checked against the tree)

### 1.1 How the iPhone sends today

Every packet UI in both themes calls **`TxEngine.transmit(hex:label:)`**. The TX tab rows, the
WAND quick button, the Starlight and New Wand colours, the Lab SEND button, the LINK, SCAN and
LOGS rows and the VFD twins of all of these use it. `TxEngine.vibrate()` and
`transmitSequence` (auto-responses) are the only other single-send paths.
`AppViewModel.transmitAndroidHex` / `transmitWandQuick` exist, but nothing in the UI calls them
any more (the WAND quick button calls `tx.transmit` with `vm.wandQuickHex`).

`transmit` is a **manual** radio job: it drops whatever is queued (`preempt: true`) and goes out
as soon as the send on air ends. `sendPacket` picks the time on air from the packet:

| Burst kind (`TxEngine.burstKind`) | Test | Time on air | Wake |
|---|---|---|---|
| `.starlight` (wand) | `HexUtils.isStarlightPacket` (`CF9B` Starlight or `CF0B` New Wand) | `store.getStarlightBurstMs()`: default 500, 250…5000 ms | none |
| `.ping` | `== PacketBuilder.wakeupPing`, or classified `typeInfo == "ping"` | `TransmitTiming.pingBurstMs` = 2000 ms | none |
| `.band` (everything else) | | `store.getCommandBurstMs()`: default **4000**, 500…12000 ms total interleave window | wake slices `getWakeupPreambleMs()`: default 520, 100…3000 ms; the relay holds `preamble + 150 ms` settle afterwards |

The ESP32 clamps one TX write to 60…12000 ms (`AppViewModel.wireEngines`). `BleCoordinator.send`
completes only **after** the burst (the BLE relay answers when the burst ends; the Wi-Fi relay
answers on queueing, and the iPhone then waits out the duration). A default band command
therefore completes about 4.7 s after it starts, and a wand colour about 0.65 s.

Loop rules that the watch must copy (§4.2):

- **TX tab** (`TxScreen.selectPacket`): send, and while the TX loop runs, the tapped packet also
  becomes the loop's packet (`setTxLoop(enabled: true, packetId:)`).
- **WAND tab** (`WandScreen.transmitColor`, same in VFD): while the wand loop runs, a colour tap
  **only** makes it the loop's colour (`setStarlightLoop`), and the loop sends it at once. With
  no loop, the tap is a plain send.
- **Quick button** and **Lab SEND**: always a plain send.

### 1.2 What can be starred (sources)

| Source | Where | Model |
|---|---|---|
| TX library | `store.allTransmitPackets()`: presets, saved Lab presets, learned colours, library and raw rows, deduped by canonical hex | `MagicPacket` (`id` is device-local and changes on import; never sent anywhere) |
| Saved Lab packets | `store.customPresets` (Lab MY PRESETS; also in the TX library) | `MagicPacket.userRecorded` |
| Starlight colours | `StarlightColors.wandColors(store.learnedStarlightPackets())` | `MagicPacket` |
| New Wand codes | `store.newWandPackets()` = `NewWandCatalog.packets` (288 generated), custom names in `vm.newWandNames` | `MagicPacket` |
| Wand quick button | `vm.wandQuickLabel` / `vm.wandQuickHex` (UserDefaults `wand_quick_*`, default New Wand OFF `…6F1D`), reprogrammable | strings |

Lowercase UserDefaults keys are exported in the library file (`MagicStore.isAppPrefKey`), and
the sync workflow is reworking the library, so favourites stay out of both (W2).

### 1.3 Status sources

| Shown | Source (all `@MainActor`, internal, readable from a new file) |
|---|---|
| Selected backend | `vm.relayBackend` (`.esp32`, `.androidBle`, `.androidWifi`); one backend at a time today |
| Link | `vm.remoteLinkReady`, `vm.relayGattReady`, `vm.remoteLinkHint` (`""` when linked, "Finishing … link…" while linking) |
| Relay STATUS | `vm.androidRemote: AndroidRemoteStatus?`, polled every 2 s by `ContentView.pollRelay` while the UI exists. ESP32 fields: `batteryPercent`, `batteryMv`, `runtimeMinutes`, `charging`, `firmware`, `board`, `uptimeS`, `keepAwake`, `txLoopEnabled`/`txLoopIntervalMs`, `starlightLoopEnabled`/`starlightIntervalMs`; text helpers `esp32ProgramText`, `esp32BatteryText`, `esp32DeviceText`. Android: `scanActive`, `autoEnabled`, `lastHeardLabel`, the same program fields |
| ESP32 too old | `vm.esp32FirmwareOutdated` |
| iPhone scan | `vm.scan.scanActive`, `.autoEnabled`, `.bluetoothStatus`, `.lastHeardLabel`, `.rawLivePackets.first?.timestampMs` (epoch ms), `.packetsHeard` |
| iPhone TX | `vm.tx.status`, `.isTransmitting`, `.lastTransmitHex`, the loops, `.randomShowEnabled`, `.replayActive`/`replayProgress`/`replayTotal`; `vm.keepAwakeActive` |
| Firmware transfer | `vm.firmware.isBusy` |
| Theme | `VFDSettings.shared.base` → `VFDPalette.colors(for:)` = `[unlit, highlight, text, dim, alarm]`, `VFDPalette.alarmInverted(base)` |

`TelemetryBar.esp32BatteryToken` shows the battery only while `relayBackend == .esp32 &&
relayGattReady`. The watch uses the same rule, so an unlinked board never shows its old battery.

---

## 2. Favourites on the iPhone

### 2.1 Model

Each favourite is a `WatchFavorite` (defined in the shared `WatchProtocol.swift`, §3.5):

| Field | Meaning |
|---|---|
| `id` | `UUID().uuidString` made when starred; stable for the favourite's life |
| `label` | the row's label when starred (trimmed, at most 40 characters), renamable in the list |
| `hex` | `HexUtils.canonicalHex(hex)` |
| `kind` | `"band"`, `"wand"` or `"other"` (strings, so a later value never breaks an older watch) |
| `source` | `"library"`, `"labPreset"`, `"wandColor"`, `"newWand"`, `"wandQuick"`: picks the send rule (§4.2) |
| `burst` | `"command"`, `"starlight"`, `"ping"`: the `TxEngine.burstKind` the hex gets |
| `wake` | true for `"command"` (the relay sends wake slices first) |
| `swatch` | wand kinds: `"#RRGGBB"` of the glow colour, for a dot on the watch; otherwise nil |
| `onAirMs` | time on air at the current settings, filled when the context is built (display only; the iPhone reads its settings at send time) |
| `addedAt` | Unix seconds |

`WatchFavoritesStore.describe(hex:label:source:)` derives the fields from the same tests as
`TxEngine` (§1.1):

```swift
let canonical: String = HexUtils.canonicalHex(hex)
if HexUtils.isStarlightPacket(canonical) {
    // As TxEngine.transmit picks the colour it reports.
    let index: Int = MagicClassifier.starlightLearnColorIndex(canonical) ?? MagicClassifier.starlightColorIndex(canonical)
    let rgb = starlightGlowRGB(index & 0x1F)          // Views/StarlightWandView.swift, 0...1 doubles
    let swatch: String = VFDRGB(unitRed: rgb.red, green: rgb.green, blue: rgb.blue).hex
    // kind "wand", burst "starlight", wake false, swatch
} else if canonical == PacketBuilder.wakeupPing || MagicClassifier.classify(canonical)?.typeInfo == "ping" {
    // kind "other", burst "ping", wake false
} else {
    // kind "band", burst "command", wake true
}
```

`onAirMs`: command → `store.getCommandBurstMs()`, starlight → `store.getStarlightBurstMs()`,
ping → `TransmitTiming.pingBurstMs`.

**Identity**: a row shows a filled star when a favourite with the same canonical hex exists,
whatever its source. So a Lab preset starred in the Lab also shows starred in the TX tab, and a
hex can be starred only once. The **quick button** is the exception: its favourite is
`source == "wandQuick"`, at most one, and it **follows the button**. When the quick button is
reprogrammed, that favourite's `label` and `hex` are updated
(`WatchFavoritesStore.followQuick(label:hex:)`, called by the bridge when it builds a context and
before it sends a quick favourite, after `vm.reloadWandQuickIfChanged()`).

Favourites are self-contained snapshots: deleting the library row does **not** remove the
favourite, which keeps its own hex and stays sendable.

### 2.2 Store: `ios/MagicMaker/Watch/WatchFavoritesStore.swift`

```swift
@MainActor
final class WatchFavoritesStore: ObservableObject {
    static let shared: WatchFavoritesStore = WatchFavoritesStore()
    @Published private(set) var items: [WatchFavorite] = []   // the watch's order

    func isStarred(hex: String) -> Bool             // canonical-hex match, source != wandQuick
    var isQuickStarred: Bool { get }
    /// Adds (at the end) or removes. Returns false when it was not added because 24 are stored.
    @discardableResult func toggle(hex: String, label: String, source: String) -> Bool
    @discardableResult func toggleQuick(label: String, hex: String) -> Bool
    func favorite(id: String) -> WatchFavorite?
    func remove(id: String)
    func move(id: String, by offset: Int)            // -1 up, +1 down; clamped
    func rename(id: String, label: String)           // blank is ignored
    func followQuick(label: String, hex: String)     // no-op when unchanged
    static func describe(hex: String, label: String, source: String) -> WatchFavorite
}
```

- **File**: `Application Support/watch_favorites.json` (`FileManager.default.urls(for:
  .applicationSupportDirectory, in: .userDomainMask)[0]`; create the directory). Content
  `{"v":1,"items":[WatchFavorite…]}`. Load synchronously in `init` (tiny). Every change saves
  with `Data.write(to:options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])`,
  so a background wake after the first unlock can read it. Not in the library export and not
  synced; Android has no watch.
- An unreadable file is moved aside to `watch_favorites.corrupt.json`, and the store starts
  empty.
- `objectWillChange` drives the star views, the SETTINGS list and an **immediate** context push
  (§3.2).
- When a toggle is refused because the list is full, the caller shows its theme's alert:
  **"FAVORITES FULL (24)"**, message "Remove one in SETTINGS → APPLE WATCH." Standard:
  `.alert`. VFD: `ctx.confirm(title:message:confirmLabel: "OK") {}`.

### 2.3 Star toggles: standard theme

One shared control in `Watch/WatchFavoritesSection.swift`:

```swift
/// The watch star: filled amber when starred, an outline in textDim otherwise. 36 x 36 tap area.
struct FavoriteStarButton: View {
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: on ? "star.fill" : "star")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? MMTheme.amber : MMTheme.textDim)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)      // inside List rows: only the star is the target
        .accessibilityLabel(on ? "Remove from watch favorites" : "Add to watch favorites")
    }
}
```

Each screen that shows stars observes the store
(`@ObservedObject private var favorites = WatchFavoritesStore.shared`), so stars redraw on any
change.

| Screen | Edit |
|---|---|
| `Views/SharedViews.swift` `PacketRow` | New optional init parameter `star: PacketRowStar? = nil` (`struct PacketRowStar { let on: Bool; let toggle: () -> Void }`), placed last so every existing call compiles. In `rowBody`, after `Spacer(minLength: 0)`: `if let star { FavoriteStarButton(on: star.on, action: star.toggle) }`. The row keeps `.accessibilityElement(children: .combine)` and gains `.accessibilityAction(named: star.on ? "Remove from watch" : "Add to watch") { star.toggle() }` when `star != nil`. A child `Button` wins over the row's `onTapGesture`, so a tap on the star never sends. |
| `Views/TxScreen.swift` `packetRow` | `star: PacketRowStar(on: favorites.isStarred(hex: row.packet.hex)) { toggleStar(row.packet) }`. `toggleStar` calls `favorites.toggle(hex:label:source: "library")` and shows the FULL alert on false. |
| `Views/LabScreen.swift` `LabPresetRow` | Add `starred: Bool` and `onStar: () -> Void`. A `FavoriteStarButton` goes between the text button and the trash button. Source `"labPreset"`. |
| `Views/StarlightWandView.swift` | The `packets:` init gains `isStarred: ((MagicPacket) -> Bool)? = nil, onStar: ((MagicPacket) -> Void)? = nil`, stored as index closures the way `sendAt` and `deleteAt` are (`starredAt`, `starAt`; the `colors:` init sets both to nil). In `pickerRow`, between the `Menu` and SEND: `if let starAt, selectedEntry != nil { FavoriteStarButton(on: starredAt?(selectedIndex) ?? false) { starAt(selectedIndex) } }`. LINK's Android-colour picker is unchanged. |
| `Views/WandScreen.swift` | Starlight: pass `isStarred:` / `onStar:` (source `"wandColor"`, label `packet.label`). New Wand: `WandCodeRow` gains `starred` and `onStar`, with the star after the name (source `"newWand"`, label = custom name if set, else `packet.label`). Quick button: `HStack(spacing: 4) { quickButton; FavoriteStarButton(on: favorites.isQuickStarred) { … toggleQuick(label: vm.wandQuickLabel, hex: vm.wandQuickHex) } }`. |

The Lab's current packet is not starred directly: SAVE makes it a preset, and presets have stars.

### 2.4 Star toggles: VFD theme

`Watch/VFDWatchSection.swift` holds the star glyph and the list section (§2.5):

```swift
/// The watch star on the VFD grid: a 7 x 7 glyph, highlight when starred, dim otherwise.
@MainActor
enum VFDStar {
    static let glyph: [String] = ["...#...", "..###..", "#######", ".#####.", "..###..", ".##.##.", ".#...#."]
    static let size: Int = 7
    /// Cells a star column takes at a row's right edge: 3 air, glyph, 4 air.
    static let colW: Int = 14
    /// A boxed star cell (WAND picker row, quick button): this wide.
    static let boxW: Int = 19

    static func draw(_ fb: VFDFrameBuffer, _ x: Int, _ y: Int, on: Bool) {
        let ink: UInt8 = on ? VFDInk.highlight : VFDInk.dim
        var j: Int = 0
        for row in glyph {
            var i: Int = 0
            for ch in row {
                if ch == "#" { fb.set(x + i, y + j, ink) }
                i += 1
            }
            j += 1
        }
    }
}
```

It is drawn like the Lab's trash glyph (`VFDLabScreen.trash`). `VFDWidgets.swift` is **not**
changed: it is the Python port checked by the golden test (`ios/VFDCheck`), and no golden output
moves. The ★ character is not in the VFD font, so VFD text says "STAR" instead.

| Screen | Edit |
|---|---|
| `VFDTxScreen.drawRow` | Call `VFDW.packetRow` with `w: L.width - VFDStar.colW` (the label then fits the narrower row; row heights do not depend on width). `VFDStar.draw(fb, L.left + L.width - VFDStar.colW + 3, y + 3, on:)` on the label row. Tap `VFDW.tap(fb, L.left + L.width - VFDStar.colW, y, VFDStar.colW, end - y, "star:" + label, action:)`, registered **after** the row's tap so it is topmost. `end` = `packetRow`'s return value; the divider row is `end - 1`. Continue the dotted divider under the star column at the same parity: `var x = L.left + L.width - VFDStar.colW; if (x - L.left) % 2 == 1 { x += 1 }; fb.hline(x, end - 1, L.left + L.width - x, VFDInk.dim, step: 2)`. |
| `VFDLabScreen.presetRow` | `starX = binX - 4 - VFDStar.size - 8`. The label/hex `limit` becomes `starX - 6 - c - 2`. The glyph goes at `(starX, y + 5)`. Three taps: load `[c, starX - 4)`, star `[starX - 4, binX - 4)` named `"preset:star:" + label`, bin as today. |
| `VFDWandScreen.pickerRow` | `bw = w - sendW - gap - VFDStar.boxW - gap`. Star box at `x = c + bw + gap`: `fb.box(x, r, VFDStar.boxW, h, on ? VFDInk.highlight : VFDInk.dim)`, glyph centred, tap `"button:STAR"`. SEND moves right by `boxW + gap`. No star while the library is empty. |
| `VFDWandScreen.drawCodes` | The name is right-aligned at `c + w - 1 - VFDStar.colW` instead of `c + w - 1`, and the glyph is drawn in the last `colW` cells on the name row. Its tap `"code:star:" + key` is registered after the row tap. |
| `VFDWandScreen.drawControls` quick button | `VFDW.button(fb, L, c, y, w - VFDStar.boxW - 4, quickLabel, …)` plus a star box `boxW x ctrlH` at the right, tap `"button:QUICK STAR"`. The returned `y` is unchanged. |
| `VFDRootView.observe` | Append `subs.append(watch(WatchFavoritesStore.shared.objectWillChange))` and `subs.append(watch(WatchBridge.shared.objectWillChange))`, so the grid redraws on a star, rename or reorder, and on watch-link changes (SETTINGS). |

Star taps run `WatchFavoritesStore.shared.toggle…` and, when it returns false, the FULL confirm.
The Python previews (`tools/vfd/screens/tx.py`, `wand.py`, `lab.py`, `settings.py`) may get the
same columns to check fit at 207 and 241 cells. This is optional: no golden changes.

### 2.5 FAVORITES list: SETTINGS → APPLE WATCH (both themes)

The section goes between BACKGROUND and BOARD FIRMWARE in both SETTINGS screens. It takes one
inserted line in each:

- `Views/SettingsScreen.swift`: `SettingsWatchSection().padding(.top, 8)` after
  `SettingsBackgroundSection()`.
- `VFD/VFDSettingsScreen.swift` `draw`: `y = VFDWatchSection.draw(ctx, c, y, w)` after
  `y = background(ctx, c, y, w)`.

Content (same order and copy in both):

1. Section title **APPLE WATCH**, with `n/24` on the right (VFD: `VFDW.section(… right:)`).
2. The link line from `WatchBridge.shared.linkText`:

   | State | Text | Ink |
   |---|---|---|
   | `!WCSession.isSupported()` (iPad) | `NOT AVAILABLE ON THIS DEVICE` | dim |
   | not activated yet | `STARTING…` | dim |
   | `!isPaired` | `NO APPLE WATCH PAIRED` | dim |
   | paired, `!isWatchAppInstalled` | `WATCH APP NOT INSTALLED — WATCH APP ON IPHONE → AVAILABLE APPS` | alarm |
   | installed, `!isReachable` | `WATCH APP INSTALLED · SYNCED 12S AGO` (last context push; `NOT SYNCED YET`) | dim |
   | `isReachable` | `WATCH APP OPEN · LIVE` | highlight |

3. When empty: `Star a packet on TX, WAND (colours, codes, quick button) or LAB (MY PRESETS) to
   add it here. The watch sends through this iPhone and its relay.` (dim).
4. Otherwise the hint `TAP SENDS · HOLD RENAMES`, then one row per favourite in order:
   - line 1: label (text ink, uppercased, truncated); a `QUICK` tag box for `wandQuick`
   - line 2: `BAND · 8301CC…` / `WAND · …` / `PING · …` (dim, truncated) and, for wand, a
     true-colour 5 x 5 dot (VFD `ledDot`) or a 9 pt circle (standard) of `swatch`
   - right: **up**, **down**, **star (filled)**. Standard: `chevron.up` / `chevron.down` /
     `star.fill` buttons, 32 x 32, `.borderless`. VFD: three 13-cell columns with
     `VFDW.chevronUp`, `VFDW.chevron(…, false)` and `VFDStar.draw(on: true)`, each its own tap;
     up is disabled (dim, no tap) on the first row, down on the last.
   - tap the row: send now from the iPhone through the same path as a watch send (§4.2, the
     result is not reported to the watch); hold: rename (`RenameRequest(title: "Rename
     favorite", …)` / `ctx.prompt(title: "RENAME FAVORITE", text: label)`); star: remove after
     a confirm (`DeleteRequest(title: "Remove from watch favorites?", label:, hex:,
     confirmLabel: "REMOVE")` / `ctx.confirm(… destructive: true)`). A star on a packet row
     removes at once, with no confirm, because the row can star it again. Here the source row
     may be gone.

---

## 3. WatchConnectivity protocol (version 1)

### 3.1 Sessions

- **iPhone**: `WatchBridge.shared.start()` in `MagicMakerApp.init()` sets `WCSession.default`'s
  delegate and calls `activate()` (guarded by `WCSession.isSupported()`; false on iPad). Apple
  delivers a message that launched the app only to a session activated during launch, so this
  must not wait for the UI. `sessionDidDeactivate` calls `activate()` again (watch switching).
- **Watch**: `WatchModel.init` activates. On `activationDidComplete` it applies
  `session.receivedApplicationContext` (the last one delivered while the app was not running),
  then sends `refresh` if reachable.

### 3.2 iPhone → watch: application context

```
[ "v": 1,                    Int
  "at": 1764023456.25,       Double, iPhone clock, Unix seconds, when built
  "favorites": Data,         JSON [WatchFavorite]              (always present in a context)
  "status": Data,            JSON WatchStatus                  (present once an AppViewModel exists)
  "theme": Data,             JSON WatchThemeColors             (always)
  "lastSend": Data ]         JSON WatchSendResult              (optional, §3.3)
```

Property-list types only. The structured parts are JSON (`JSONEncoder`, `.sortedKeys`) inside
`Data`, so both sides share one Codable definition. Size: 24 favourites plus status is well under
10 KB.

**When.**
- Favourites or theme (`VFDSettings.shared.$base`) changed: push now (on the next main-queue
  turn, because `objectWillChange` fires before the change).
- Anything else (`vm`, `vm.tx`, `vm.scan` `objectWillChange`, `UIDevice` battery
  notifications, app foreground/background): coalesce to **at most one push per 2 s**, on the
  trailing edge.
- Skip the push when the content digest is unchanged. The digest is the sorted-keys JSON of
  favourites + theme + status + lastSend, with `at` left out and `phone.lastHeardAt` rounded down
  to 30 s. A park full of repeating packets therefore pushes when the heard **label** changes,
  not on every packet.
- **Telemetry waits.** When the only change is telemetry, the push waits until 60 s after the
  last one (`telemetrySpacingSeconds`). Telemetry here means values that move by themselves: the
  ESP32's battery %, mV, runtime and uptime, which are new on every 2 s STATUS read, and the
  iPhone's battery, TX line, last heard packet and replay step. Otherwise a linked board would
  push every 2 s for as long as the iPhone app is open. A second digest with these values blanked
  decides this. It keeps whether each value is present, so link states, programs, charging,
  scan, AUTO and a board's first battery reading still push within 2 s. STATUS on the watch asks
  for a fresh snapshot every 10 s while it is shown.
- With no watch app to push to (not activated, not paired, not installed), a change schedules
  nothing.
- Only when `activationState == .activated && isPaired && isWatchAppInstalled`.
  `sessionWatchStateDidChange` triggers a push, so the first install gets data.
  `updateApplicationContext` errors are ignored (the next change retries).

The watch shows "UPDATED 12S AGO" from the newest `at` it has (context or reply). While the watch
is reachable it polls `refresh` (§5.2), so the age only grows when the iPhone really is out of
touch.

### 3.3 Watch → iPhone: messages and replies

Requests (`sendMessage(_:replyHandler:errorHandler:)`; the watch sends **only** when
`session.isReachable`, otherwise it shows the error locally and queues nothing):

| Request | Meaning |
|---|---|
| `["v": 1, "op": "send", "id": "<favourite id>", "sentAt": Double]` | transmit that favourite (§4.2) |
| `["v": 1, "op": "stop_programs"]` | stop keep-awake, TX loop, wand loop, random show, replay (§4.3) |
| `["v": 1, "op": "refresh"]` | re-read the relay, reply with a fresh full context (§4.4) |

Every request carries the optional `sentAt`: the watch's clock, in Unix seconds, when it was
sent. A **send** that reaches the iPhone more than `WatchProtocol.lateSendSeconds` (20 s) after
it was sent is refused with `ARRIVED LATE — NOT SENT, TAP AGAIN`. The watch gives up on a reply
after 30 s, so a band lighting up after that would surprise the user. A paired watch's clock
follows the iPhone's. A request without `sentAt` is not checked.

Reply (always exactly one):

```
[ "v": 1, "ok": Bool, "state": String, "via": String, "error": String, "label": String,
  "id": String (send only),
  "at", "status"                       — every reply
  "favorites", "theme"                 — refresh replies, and a send whose id was not found ]
```

| `state` | When | Watch shows / haptic |
|---|---|---|
| `sent` | the packet went out and its burst ended | `✓ VIA ESP32` / `.success` |
| `on_air` | still on air at the reply deadline (long band burst) | `ON AIR · VIA ESP32` / `.start`; the final result follows in `lastSend` |
| `queued` | waiting behind a send on air at the deadline | `QUEUED · VIA …` / `.start`; final in `lastSend` |
| `loop` | the wand or TX loop now runs this packet (§4.2) | `LOOP · VIA …` / `.success` |
| `stopped` | stop_programs done | `STOPPED · VIA …` / `.success` |
| `refreshed` | refresh | (no haptic) |
| `failed` | any failure; `error` says why | `✕ <error>` in alarm ink / `.failure` |

`via`: `"ESP32"`, `"ANDROID BLE"`, `"ANDROID WIFI"` for the backend that carried it, or
`"IPHONE"` when the iPhone did it alone (refresh; a failure before any relay; a stop with no
relay linked).

`lastSend` (`WatchSendResult {id, ok, state, via, error, label, at}`) is set only for
**watch-originated** sends whose reply went out before the final result (`on_air`, `queued`).
When the result arrives it is set and the context is pushed **immediately**. The watch applies it
to the row with that id if the row is still waiting, `at` is under 60 s old and `at` is not
before the iPhone time (`at`) of the reply that left the row waiting. Then it plays the final
haptic. That last check matters because the iPhone keeps the last `lastSend` in every context.
Without it, an earlier tap's result could finish a newer tap of the same favourite. The context
can also overtake the `on_air` reply, since the two travel separately. So the watch keeps the
newest `lastSend` for each favourite and checks it when a row starts waiting.

**Error texts** (uppercase, short; the bridge maps them):

| Cause | `error` |
|---|---|
| favourite id unknown (removed meanwhile) | `FAVORITE REMOVED ON IPHONE` (reply also carries the new favourites) |
| protocol `v` differs | `UPDATE MAGICMAKER ON IPHONE AND WATCH` |
| firmware transfer running | `ESP32 FIRMWARE UPDATE RUNNING` |
| send more than 20 s after the tap (`sentAt`) | `ARRIVED LATE — NOT SENT, TAP AGAIN` |
| Bluetooth off / denied on a BLE backend | `vm.scan.bluetoothStatus.uppercased()` (e.g. `TURN ON BLUETOOTH`), at once; `BLUETOOTH UNAVAILABLE` (also the value before the radio first reports, as on a launch by this message) only after the link wait |
| relay not linked after the link wait | `vm.remoteLinkHint.uppercased()`, else `NO RELAY LINKED` |
| `TxEngine.notLinkedStatus` | `NO RELAY LINKED` |
| `TxEngine.sendFailedStatus` | `RELAY DID NOT SEND IT` |
| `TxEngine.droppedStatus` (§4.6) | `REPLACED BY A NEWER SEND OR STOP` |
| `HexUtils.legacyAdvertiseRejectReason` | that text, uppercased, ≤ 48 chars |
| watch: not reachable | `IPHONE NOT REACHABLE` (never sent) |
| watch: `WCError.messageReplyTimedOut` | `NO REPLY — OPEN MAGICMAKER ON IPHONE` |
| watch: `WCError.notReachable` | `IPHONE NOT REACHABLE` |
| watch: other `WCError` | `IPHONE ERROR <code>` |

**Timing budget.** The bridge replies within **7 s** of receiving a message. The link wait
(§4.2 step 4) uses at most 4 s of that. The send then has the rest: a wand colour (≈0.65 s) and a
default band command (≈4.7 s) normally get a final `sent`. Longer bursts get `on_air` and then
`lastSend`.

### 3.4 Versioning

- `v` = 1. Both apps ship in one build, so a mismatch is transient: the watch app updates after
  the iPhone app. A peer that sees another `v` ignores the context (watch) or replies `failed`
  with `UPDATE MAGICMAKER ON IPHONE AND WATCH` (iPhone).
- **New fields must be optional** (decoding a missing optional gives nil). Then `v` stays 1.
  Enumerations travel as strings for the same reason. Bump `v` only for a change an older peer
  would misread.

### 3.5 `ios/MagicMaker/Watch/WatchProtocol.swift` (both targets)

Foundation only. No UIKit, WatchKit, SwiftUI or WatchConnectivity, so it compiles in both targets
(and with `swiftc` on Linux, should a round-trip check be added to `ios-core-parity.yml`).

```swift
import Foundation

// The iPhone <-> Apple Watch contract over WatchConnectivity (docs/WATCH_APP.md section 3).
// Compiled into BOTH targets, MagicMaker (iOS) and MagicMakerWatch (watchOS): Foundation only.
// Every payload is a property-list dictionary; the structured parts travel as JSON Data.

enum WatchProtocol {
    /// Bumped only for a change an older peer would misread. New fields are optional and keep 1.
    static let version: Int = 1
    /// Most favourites the iPhone keeps (and so the watch shows).
    static let maxFavorites: Int = 24

    static let keyVersion: String = "v"
    static let keyAt: String = "at"
    static let keyFavorites: String = "favorites"
    static let keyStatus: String = "status"
    static let keyTheme: String = "theme"
    static let keyLastSend: String = "lastSend"
    static let keyOp: String = "op"
    static let keyId: String = "id"
    static let keyOk: String = "ok"
    static let keyState: String = "state"
    static let keyVia: String = "via"
    static let keyError: String = "error"
    static let keyLabel: String = "label"
    /// watch -> iPhone, optional: when the watch sent the request (its clock, Unix seconds).
    static let keySentAt: String = "sentAt"

    /// A favourite that reaches the iPhone this long after the tap is not sent: the watch gives
    /// up on a reply after 30 s, so a band lighting up later would be a surprise. A paired
    /// watch's clock follows the iPhone's, far closer than this.
    static let lateSendSeconds: Double = 20

    static let opSend: String = "send"
    static let opStopPrograms: String = "stop_programs"
    static let opRefresh: String = "refresh"

    static let stateSent: String = "sent"
    static let stateOnAir: String = "on_air"
    static let stateQueued: String = "queued"
    static let stateLoop: String = "loop"
    static let stateStopped: String = "stopped"
    static let stateRefreshed: String = "refreshed"
    static let stateFailed: String = "failed"

    static let viaEsp32: String = "ESP32"
    static let viaAndroidBle: String = "ANDROID BLE"
    static let viaAndroidWifi: String = "ANDROID WIFI"
    static let viaIphone: String = "IPHONE"

    static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
        guard let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// The version a dictionary carries; 0 when it has none.
    static func versionOf(_ dictionary: [String: Any]) -> Int {
        return dictionary[keyVersion] as? Int ?? 0
    }
}

/// One starred packet (docs/WATCH_APP.md 2.1). kind / source / burst are strings so that a value
/// added later never makes an older peer drop the whole list.
struct WatchFavorite: Codable, Equatable, Identifiable {
    enum Kind {
        static let band: String = "band"
        static let wand: String = "wand"
        static let other: String = "other"
    }
    enum Source {
        static let library: String = "library"
        static let labPreset: String = "labPreset"
        static let wandColor: String = "wandColor"
        static let newWand: String = "newWand"
        static let wandQuick: String = "wandQuick"
    }
    enum Burst {
        static let command: String = "command"
        static let starlight: String = "starlight"
        static let ping: String = "ping"
    }

    var id: String
    var label: String
    var hex: String
    var kind: String
    var source: String
    var burst: String
    var wake: Bool
    var swatch: String?
    var onAirMs: Int?
    var addedAt: Double
}

/// The ESP32 transmitter as the iPhone knows it.
struct WatchEsp32Status: Codable, Equatable {
    /// "LINKED", "LINKING", "NOT LINKED" or "NOT SELECTED".
    var state: String
    var batteryPct: Int?
    var batteryMv: Int?
    var runtimeMin: Int?
    var charging: Bool
    /// "KEEP AWAKE", "TX LOOP · 3S", "WAND LOOP · 2.5S" or "IDLE"; nil without a status.
    var program: String?
    var firmware: String?
    var board: String?
    var uptimeS: Int?
    var outdated: Bool
    /// The board warns of a low battery (firmware 1.5+ `batLow`). Optional so that a peer from
    /// before it decodes this status (nil = not reported) and an older watch simply ignores it.
    var batteryLow: Bool?
}

/// The Android phone as the iPhone knows it (relay backend and scanner).
struct WatchAndroidStatus: Codable, Equatable {
    /// "LINKED", "LINKING", "NOT LINKED" or "NOT SELECTED".
    var state: String
    /// "BLE", "WIFI", or "" when not selected.
    var transport: String
    var scanning: Bool?
    var autoArmed: Bool?
    var keepAwake: Bool?
    var program: String?
    var lastHeardLabel: String?
}

/// This iPhone.
struct WatchPhoneStatus: Codable, Equatable {
    var batteryPct: Int?
    var charging: Bool
    /// ScanEngine.bluetoothStatus, uppercased ("BLUETOOTH READY", "TURN ON BLUETOOTH", ...).
    var bluetooth: String
    var scanning: Bool
    /// The app is frontmost (iOS passes band packets to it only then).
    var foreground: Bool
    var autoArmed: Bool
    var lastHeardLabel: String
    /// Unix seconds of the newest heard packet; nil when none this run.
    var lastHeardAt: Double?
    var txStatus: String
    var transmitting: Bool
    /// Programs this iPhone times itself: "TX LOOP · 3S", "WAND LOOP · 3S", "RANDOM SHOW", "REPLAY 3/40".
    var programs: [String]
}

struct WatchStatus: Codable, Equatable {
    /// The selected backend's via name ("ESP32", "ANDROID BLE", "ANDROID WIFI").
    var selected: String
    var linked: Bool
    /// AppViewModel.remoteLinkHint, uppercased; "" when linked.
    var hint: String
    var esp32: WatchEsp32Status
    var android: WatchAndroidStatus
    var phone: WatchPhoneStatus
}

/// The five VFD inks of the iPhone's base colour ("#RRGGBB").
struct WatchThemeColors: Codable, Equatable {
    var highlight: String
    var text: String
    var dim: String
    var alarm: String
    /// A red-ish base: alarms are drawn as inverted highlight blocks.
    var alarmInverted: Bool

    static let amber: WatchThemeColors = WatchThemeColors(
        highlight: "#FFB014", text: "#FFE8C4", dim: "#966428", alarm: "#FF5028", alarmInverted: false)
}

/// The final result of a watch send whose reply went out before it ended.
struct WatchSendResult: Codable, Equatable {
    var id: String
    var ok: Bool
    var state: String
    var via: String
    var error: String
    var label: String
    var at: Double
}

/// The application context and the snapshot part of a reply. A part that is absent stays nil;
/// the watch applies only the parts that are present.
struct WatchContext: Equatable {
    var at: Double
    var favorites: [WatchFavorite]?
    var status: WatchStatus?
    var theme: WatchThemeColors?
    var lastSend: WatchSendResult?

    init(at: Double, favorites: [WatchFavorite]? = nil, status: WatchStatus? = nil,
         theme: WatchThemeColors? = nil, lastSend: WatchSendResult? = nil) {
        self.at = at
        self.favorites = favorites
        self.status = status
        self.theme = theme
        self.lastSend = lastSend
    }

    func dictionary() -> [String: Any] {
        var d: [String: Any] = [WatchProtocol.keyVersion: WatchProtocol.version, WatchProtocol.keyAt: at]
        if let favorites, let data = WatchProtocol.encode(favorites) { d[WatchProtocol.keyFavorites] = data }
        if let status, let data = WatchProtocol.encode(status) { d[WatchProtocol.keyStatus] = data }
        if let theme, let data = WatchProtocol.encode(theme) { d[WatchProtocol.keyTheme] = data }
        if let lastSend, let data = WatchProtocol.encode(lastSend) { d[WatchProtocol.keyLastSend] = data }
        return d
    }

    /// nil for another protocol version or a dictionary with no `at`.
    init?(dictionary d: [String: Any]) {
        guard WatchProtocol.versionOf(d) == WatchProtocol.version,
              let at = d[WatchProtocol.keyAt] as? Double else { return nil }
        self.at = at
        self.favorites = WatchProtocol.decode([WatchFavorite].self, d[WatchProtocol.keyFavorites])
        self.status = WatchProtocol.decode(WatchStatus.self, d[WatchProtocol.keyStatus])
        self.theme = WatchProtocol.decode(WatchThemeColors.self, d[WatchProtocol.keyTheme])
        self.lastSend = WatchProtocol.decode(WatchSendResult.self, d[WatchProtocol.keyLastSend])
    }
}

/// watch -> iPhone.
struct WatchRequest {
    var version: Int
    var op: String
    var id: String?
    /// When the watch sent it (watch clock, Unix seconds); nil from a peer that does not send it.
    var sentAt: Double?

    init(op: String, id: String? = nil) {
        self.version = WatchProtocol.version
        self.op = op
        self.id = id
        self.sentAt = Date().timeIntervalSince1970
    }

    init?(dictionary d: [String: Any]) {
        guard let op = d[WatchProtocol.keyOp] as? String else { return nil }
        self.version = WatchProtocol.versionOf(d)
        self.op = op
        self.id = d[WatchProtocol.keyId] as? String
        self.sentAt = d[WatchProtocol.keySentAt] as? Double
    }

    func dictionary() -> [String: Any] {
        var d: [String: Any] = [WatchProtocol.keyVersion: version, WatchProtocol.keyOp: op]
        if let id { d[WatchProtocol.keyId] = id }
        if let sentAt { d[WatchProtocol.keySentAt] = sentAt }
        return d
    }

    /// Seconds from the watch's send to `now` on this device's clock; nil without `sentAt`.
    func age(now: Date = Date()) -> Double? {
        guard let sentAt else { return nil }
        return now.timeIntervalSince1970 - sentAt
    }
}

/// iPhone -> watch, the reply to one request.
struct WatchReply {
    var ok: Bool
    var state: String
    var via: String
    var error: String
    var label: String
    var id: String?
    var context: WatchContext?

    init(ok: Bool, state: String, via: String, error: String = "", label: String = "",
         id: String? = nil, context: WatchContext? = nil) {
        self.ok = ok
        self.state = state
        self.via = via
        self.error = error
        self.label = label
        self.id = id
        self.context = context
    }

    init?(dictionary d: [String: Any]) {
        guard let ok = d[WatchProtocol.keyOk] as? Bool,
              let state = d[WatchProtocol.keyState] as? String else { return nil }
        self.ok = ok
        self.state = state
        self.via = d[WatchProtocol.keyVia] as? String ?? ""
        self.error = d[WatchProtocol.keyError] as? String ?? ""
        self.label = d[WatchProtocol.keyLabel] as? String ?? ""
        self.id = d[WatchProtocol.keyId] as? String
        self.context = WatchContext(dictionary: d)
    }

    func dictionary() -> [String: Any] {
        var d: [String: Any] = context?.dictionary() ?? [WatchProtocol.keyVersion: WatchProtocol.version]
        d[WatchProtocol.keyOk] = ok
        d[WatchProtocol.keyState] = state
        d[WatchProtocol.keyVia] = via
        d[WatchProtocol.keyError] = error
        d[WatchProtocol.keyLabel] = label
        if let id { d[WatchProtocol.keyId] = id }
        return d
    }
}
```

**Added with the board power work (firmware 1.5):** `WatchEsp32Status.batteryLow` (`Bool?`).
It is `true` while the ESP32 reports its low-battery warning (STATUS `batLow`: the warning stage
before the cutoff) and is not charging, `false` when a status without the warning was read, and
nil when the iPhone has no status for the board (backend not ESP32, or not linked). It is
optional, so `v` stays 1 (§3.4): an older watch ignores it, and a newer watch decodes a context
from an older iPhone with nil. The watch's STATUS page draws the battery in alarm with it and
adds `BATTERY LOW — CHARGE SOON` (§5.3).

---

## 4. iPhone side

### 4.1 Start at launch, and a background wake with no screen

`MagicMakerApp.swift`, one added line:

```swift
init() {
    CrashLog.install()
    VFDSettings.shared.armLaunchGuard()
    // Before any scene: a watch message can launch the app in the background, and iOS delivers
    // it only to a session activated during launch.
    WatchBridge.shared.start()
}
```

`Views/LaunchBootstrapView.swift`: the controller becomes a per-process singleton, so the watch
bridge can start the engines when no view exists. iOS does not always connect a scene on a
background launch, so the view's `.task` may never run.

```swift
@MainActor
final class BootstrapController: ObservableObject {
    /// One per process: the launch view shows it, and the watch bridge starts it when a watch
    /// message wakes the app in the background with no screen.
    static let shared: BootstrapController = BootstrapController()

    @Published private(set) var viewModel: AppViewModel?

    func start() {
        guard viewModel == nil else { return }
        let vm = AppViewModel()
        vm.bootstrapAfterLaunch()
        viewModel = vm
        WatchBridge.shared.attach(vm)
    }
}
```

and in `LaunchBootstrapView`:
`@StateObject private var bootstrap: BootstrapController = BootstrapController.shared`.
When the user then opens the app, the view finds the model already built and shows
`ContentView` at once.

`WatchBridge` (`Watch/WatchBridge.swift`) is `final class WatchBridge: NSObject, ObservableObject,
WCSessionDelegate`. The class itself is **not** actor-isolated, so `start()` is callable from
anywhere. The members that touch the app are `@MainActor`, and the delegate methods hop to the
main actor (`Task { @MainActor in … }`) after parsing the dictionary into the value types of
§3.5. It is Swift 5.9 mode with minimal concurrency checking, as in the iPhone target: no strict
`Sendable` errors, and no `SWIFT_DEFAULT_ACTOR_ISOLATION`.

| Member | Does |
|---|---|
| `static let shared` | |
| `func start()` | `guard WCSession.isSupported()`, set the delegate, `activate()` |
| `@MainActor func attach(_ vm: AppViewModel)` | keeps `vm`; `UIDevice.current.isBatteryMonitoringEnabled = true`; subscribes to `vm`, `vm.tx`, `vm.scan`, `WatchFavoritesStore.shared`, `VFDSettings.shared.$base`, `UIDevice.batteryLevelDidChangeNotification`, `batteryStateDidChangeNotification`, `UIApplication.didBecomeActiveNotification` / `didEnterBackgroundNotification`; schedules the first push |
| `@Published private(set) var linkText: String`, `lastPushAt: Date?` | the SETTINGS line (§2.5); written only from `@MainActor` methods, refreshed on every delegate callback |
| `@MainActor func ensureViewModel() -> AppViewModel` | `BootstrapController.shared.viewModel`, or `BootstrapController.shared.start()` then that |
| `@MainActor func sendFromPhone(_ favorite: WatchFavorite)` | the SETTINGS row tap: §4.2 without reply and without `lastSend` |
| `nonisolated` delegate | `activationDidCompleteWith`, `sessionDidBecomeInactive`, `sessionDidDeactivate` (→ `activate()`), `sessionWatchStateDidChange` (→ push), `sessionReachabilityDidChange`, `didReceiveMessage(_:replyHandler:)`, `didReceiveMessage(_:)` (handled the same, reply dropped) |

**Every incoming message** runs inside
`UIApplication.shared.beginBackgroundTask(withName: "watch-op")`, ended after the reply (and
after a pending `lastSend`, with a 20 s ceiling). It follows this order:

1. `guard request.version == WatchProtocol.version` → `failed`.
2. `let vm = ensureViewModel()`.
3. If `!vm.relayCommandReady { vm.ensureRelayLink() }` and `vm.refreshRelayStatus()`. These are
   what `ContentView.startRelayLink` does on screen. A screenless wake has no 2 s poll.
4. Handle the op (§4.2 to §4.4) and reply exactly once (a `replied` flag guards every path).
5. **VFD launch guard**: if `UIApplication.shared.applicationState == .background` when the
   background task ends, clear `UserDefaults` `VFDSettings.launchGuardKey`. `armLaunchGuard()`
   set it in `App.init`, and a background wake that is suspended before the 6 s timer fires
   would otherwise flip a VFD user to the standard theme on the next cold launch. A background
   wake draws nothing, so it cannot have crashed in the VFD renderer.

### 4.2 `send`

```text
handleSend(id, reply):
  fav = WatchFavoritesStore.shared.favorite(id)         else reply failed FAVORITE REMOVED ON IPHONE
                                                          (+ favorites, status, theme)
  if arrival age (now - sentAt, taken on arrival) > 20 s  reply failed ARRIVED LATE — NOT SENT, TAP AGAIN
  if vm.firmware.isBusy                                   reply failed ESP32 FIRMWARE UPDATE RUNNING
  if vm.relayBackend.usesBleRelayLink && bluetoothStatus is neither "Bluetooth ready" nor
     "Bluetooth unavailable" (the value until the radio first reports: a launch by this message)
                                                          reply failed <bluetoothStatus uppercased>
  deadline = receivedAt + 7 s
  waitForLink(vm, until: min(receivedAt + 4 s, deadline)):
      every 250 ms check vm.remoteLinkReady; every 1 s: vm.ensureRelayLink(), and on Wi-Fi
      vm.refreshAndroidRemote() (the Wi-Fi link state comes from that status read)
  if already replied (iOS ended the background time: NO REPLY went out)   send nothing; return
  if !vm.remoteLinkReady                                  reply failed <bluetoothStatus uppercased if a BLE
                                                          backend's radio is not ready, else remoteLinkHint
                                                          uppercased or NO RELAY LINKED>
  via = viaName(vm.relayBackend)
  (hex, label) = fav.source == wandQuick
        ? { vm.reloadWandQuickIfChanged(); store.followQuick(vm.wandQuickLabel, vm.wandQuickHex);
            (vm.wandQuickHex, vm.wandQuickLabel) }
        : (fav.hex, fav.label)
  switch fav.source:
    wandColor, newWand:   // WandScreen.transmitColor
      if vm.tx.starlightLoopEnabled, let pid = wandPacketId(hex):
          vm.tx.setStarlightLoop(enabled: true, packetId: pid, intervalMs: nil)
          reply ok state=loop                              (loop sends it at once)
          return
      transmit(hex, label)
    library:              // TxScreen.selectPacket
      transmit(hex, label); if vm.tx.txLoopEnabled, let pid = libraryPacketId(hex):
          vm.tx.setTxLoop(enabled: true, packetId: pid, intervalMs: nil)
    labPreset, wandQuick: // Lab SEND, quick button
      transmit(hex, label)

transmit(hex, label):
  vm.tx.transmit(hex: hex, label: label, completion: { failure in finish(failure) })
  at deadline, if not finished:
      state = (vm.tx.isTransmitting && vm.tx.lastTransmitHex == canonical(hex)) ? on_air : queued
      reply ok state; remember (id, label, via) for lastSend
finish(failure):
  result = failure == nil ? (ok, sent) : (failed, errorText(failure))
  if not replied: reply result
  else: lastSend = WatchSendResult(...); push context now
```

- `wandPacketId(hex)`: the first of `store.learnedStarlightPackets()` and then
  `NewWandCatalog.packets` whose canonical hex matches → `id`.
- `libraryPacketId(hex)`: the first of `store.allTransmitPackets()` whose canonical hex matches.
  When none is found (the library row was deleted), the loop part is skipped and the packet is
  still sent.
- `viaName`: `.esp32` → `"ESP32"`, `.androidBle` → `"ANDROID BLE"`, `.androidWifi` →
  `"ANDROID WIFI"`. When the sync workflow's `TransmitRouter` lands (SYNC_HUB_SPEC D9), report
  the link it actually used instead.
- The iPhone's TX status line shows the watch's send like any other ("TX…", then the done
  status), and the relay-echo filter (`isRelayEcho`) works unchanged, because the send is an
  ordinary `TxEngine` job.
- A second watch tap on another favourite preempts the first one's queued job, exactly like two
  iPhone taps. The first then gets `REPLACED BY A NEWER SEND OR STOP`.

### 4.3 `stop_programs`

```swift
let linked: Bool = await waitForLink(vm, until: receivedAt + 4 s)
let report: AndroidRemoteStatus? = vm.androidRemote          // read before stopping
let relayRunsLoops: Bool = vm.relayBackend == .esp32
let txWas: Bool = vm.tx.txLoopEnabled
let wandWas: Bool = vm.tx.starlightLoopEnabled
// No STATUS read yet: what the relay runs is unknown.
let unknown: Bool = report == nil && (linked || relayRunsLoops)
vm.tx.stopAll()      // iPhone timers, random show, replay, queue; tells the ESP32 about loops it knew of
if vm.keepAwakeActive || report?.keepAwake == true || unknown { vm.setKeepAwake(false) }
if (report?.txLoopEnabled == true || unknown) && !(relayRunsLoops && txWas) { vm.setAndroidTxLoop(enabled: false) }
if (report?.starlightLoopEnabled == true || unknown) && !(relayRunsLoops && wandWas) { vm.setAndroidStarlightLoop(enabled: false) }
```

The two `setAndroid…Loop(enabled: false)` calls also cover a loop started on the Android phone
itself, and an ESP32 loop the iPhone had not adopted yet. Both route to `sendEsp32Program` for
the ESP32. AUTO stays armed: it is not a program.

**`unknown`** covers the case where the iPhone has no STATUS yet: this message launched the app,
the link has only just come up, or the ESP32 is away (its status is cleared when the link drops).
The ESP32 keeps keep-awake and its loops running through iPhone restarts. Without this, STOP
after a cold launch would report `STOPPED` while the board went on transmitting. So all three
are told to stop: the ESP32 now, or on its next link (`sendEsp32Program` keeps one command of
each kind), and a linked Android relay at once. An Android relay that is not linked is not
asked, because the command would only fail.

Reply: `ok: true, state: stopped`. The `error` text is a note:

- `""` when the relay was linked.
- `ESP32 NOT LINKED — IT STOPS WHEN IT LINKS` (ESP32: `sendEsp32Program` keeps the commands and
  sends them on the next link).
- `RELAY NOT LINKED — STOPPED ON IPHONE ONLY` (Android), with `via: "IPHONE"`.

Then push the context (programs changed). The relay's own state shows on the next status read.

### 4.4 `refresh`

`vm.refreshRelayStatus()`; `if !vm.isCatalogSyncInFlight { vm.refreshAndroidRemote() }`; wait
1.2 s (one GATT status round trip; `androidRemote` changes are seen through the `vm`
subscription). Then reply `ok: true, state: refreshed, via: "IPHONE"` with a **full** context
(favorites, status, theme, at).

### 4.5 Context builder: `Watch/WatchContextBuilder.swift`

`@MainActor enum WatchContextBuilder { static func context(vm: AppViewModel?, lastSend:
WatchSendResult?) -> WatchContext }`. It fills `favorites` (with `onAirMs`, after `followQuick`),
`theme` and, when `vm != nil`, `status`:

| Field | From |
|---|---|
| `selected` | `viaName(vm.relayBackend)` |
| `linked`, `hint` | `vm.remoteLinkReady`, `vm.remoteLinkHint.uppercased()` |
| `esp32.state` | backend ≠ `.esp32` → `NOT SELECTED`; `remoteLinkReady` → `LINKED`; hint starts with "Finishing" → `LINKING`; else `NOT LINKED` |
| `esp32` numbers | only when `.esp32 && vm.relayGattReady`, from `vm.androidRemote`: `batteryPercent`, `batteryMv`, `runtimeMinutes`, `charging`, `esp32ProgramText`, `firmware`, `board`, `uptimeS` |
| `esp32.outdated` | `vm.esp32FirmwareOutdated` |
| `esp32.batteryLow` | with the `esp32` numbers: `batteryLow && !charging` from `vm.androidRemote` (STATUS `batLow`, firmware 1.5+); nil otherwise |
| `android.state` / `transport` | as ESP32 for `.androidBle` (`"BLE"`) / `.androidWifi` (`"WIFI"`); otherwise `NOT SELECTED`, `""` |
| `android` details | only when linked, from `vm.androidRemote`: `scanActive`, `autoEnabled`, `keepAwake`, `esp32ProgramText` (generic over the status fields), `lastHeardLabel` (nil if empty) |
| `phone.batteryPct` / `charging` | `UIDevice.current.batteryLevel` (`-1` → nil, else `Int((level * 100).rounded())`), `batteryState == .charging \|\| .full` |
| `phone.bluetooth`, `scanning`, `autoArmed` | `vm.scan.bluetoothStatus.uppercased()`, `vm.scan.scanActive`, `vm.scan.autoEnabled` |
| `phone.foreground` | `UIApplication.shared.applicationState == .active` |
| `phone.lastHeardLabel` / `lastHeardAt` | `vm.scan.lastHeardLabel`, `vm.scan.rawLivePackets.first.map { Double($0.timestampMs) / 1000 }` |
| `phone.txStatus`, `transmitting` | `vm.tx.status.uppercased()`, `vm.tx.isTransmitting` |
| `phone.programs` | when `relayBackend != .esp32`: `"TX LOOP · " + TxLoopInterval.text(TxLoopInterval.seconds(fromMilliseconds: tx.txLoopIntervalMs)) + "S"` if `txLoopEnabled`, the same `"WAND LOOP · …"` from `starlightIntervalMs` for `starlightLoopEnabled`; always `"RANDOM SHOW"` if `randomShowEnabled`, `"REPLAY \(replayProgress)/\(replayTotal)"` if `replayActive`. Keep-awake and ESP32 loops show under their relay's `program`. |
| `theme` | `let p = VFDPalette.colors(for: VFDSettings.shared.base)` → `highlight: p[1].hex, text: p[2].hex, dim: p[3].hex, alarm: p[4].hex`, `alarmInverted: VFDPalette.alarmInverted(base)`. The watch always uses the VFD look, so the base is sent whichever iPhone theme is on. |

### 4.6 `TxEngine` change (additive; re-read the file first, the latency workflow may edit it)

```swift
/// Status given to a manual send's completion when another manual send or stopAll took it out
/// of the queue before it ran.
static let droppedStatus = "Not sent — replaced by a newer send or STOP"

/// One packet, ahead of anything queued. ... `completion` (the watch) gets nil once the packet
/// went out and its burst ended, otherwise why it did not; also when a newer manual send or
/// stopAll drops it from the queue. Called exactly once, on the main actor.
func transmit(hex: String, label: String, completion: ((String?) -> Void)? = nil) {
    // ... unchanged up to runRadioJob ...
    runRadioJob(
        .manual,
        status: starlight ? "Wand TX…" : "TX…",
        onCompleteStatus: keepAwakeOn() ? "Keeping band awake" : doneStatus,
        preempt: true,
        onDropped: { completion?(TxEngine.droppedStatus) },
        send: { [weak self] done in
            guard let self else { return }
            self.sendPacket(txHex, durationMs: nil, { (failure: String?) -> Void in
                done(failure)
                completion?(failure)
            })
        },
        afterComplete: { /* unchanged */ }
    )
}
```

Every existing `tx.transmit(hex:label:)` call compiles unchanged. `onDropped` is a no-op when
`completion` is nil, so the behaviour without a completion is identical. If the latency workflow
has reshaped `transmit`, apply the same three things to the new body: a defaulted `completion`,
completion after the job's `done`, and completion on drop.

### 4.7 Background behaviour

| iPhone app | Relay link | Watch tap |
|---|---|---|
| foreground | linked | sends; WC hop ≈ 0.2–1 s plus the burst |
| background, still running (keep-running, a loop timed here) | linked | sends |
| suspended | BLE (ESP32 / Android BLE): CoreBluetooth keeps the connection under `bluetooth-central` | `sendMessage` wakes the app in the background, and the write goes out while backgrounded |
| suspended | Android Wi-Fi | woken; HTTP to the hotspot works while awake, if the iPhone is still on that Wi-Fi |
| not running (iOS ended it) | down | WC launches the app in the background; `ensureViewModel` builds the engines and the relay reconnects. If it is not linked within 4 s: `failed` + the link hint (often `FINISHING ESP32 LINK…`); the next tap usually works |
| force-quit by the user | | iOS may not relaunch it: the watch shows `NO REPLY — OPEN MAGICMAKER ON IPHONE` |
| iPhone out of range / Bluetooth off | | watch shows `IPHONE NOT REACHABLE`; nothing is sent later |

The ESP32's own programs (keep-awake, loops) keep running on the chip whatever the iPhone does.
The iPhone hears no band packets while in the background (iOS limit), so the watch's STATUS shows
`SCAN ON · PAUSED (IPHONE APP IN BACKGROUND)` when `scanning && !foreground`.

### 4.8 Interactions

- **Sync workflow**: no `Sync/*` file is touched. Favourites are not library records. The
  `pbxproj` script re-reads the file and refuses to write if the file changed during the run.
  When D9's `TransmitRouter` and §9 heartbeats land, see §10.
- **Latency workflow**: only `TxEngine.transmit` gains a parameter (§4.6); no `BLE/*`,
  `AppViewModel` or `ScanEngine` edits.
- `TxEngine.refreshIdleTimer` touches `UIApplication.shared.isIdleTimerDisabled` on a
  background bootstrap, which is harmless.
- `MagicStore`'s background-save task works the same on a background bootstrap.

---

## 5. Watch app (`ios/MagicMakerWatch/`, watchOS 10+)

### 5.1 Files

| File | Contents |
|---|---|
| `MagicMakerWatchApp.swift` | `@main struct MagicMakerWatchApp: App` (`@StateObject private var model = WatchModel()`, `WindowGroup { WatchRootView().environmentObject(model) }`) and `WatchRootView` |
| `WatchModel.swift` | the session, state and actions (§5.2) |
| `WatchTheme.swift` | `Color(watchHex:)`, `WatchInk`, `WatchFont`, `watchAgeText` (§5.4) |
| `FavoritesPage.swift`, `StatusPage.swift`, `StopPage.swift` | the pages (§5.3) |
| `Assets.xcassets` | `Contents.json` and `AppIcon.appiconset` (§6.5) |
| `Info.plist` | partial: `WKApplication` only (§6.5) |
| (shared) `../MagicMaker/Watch/WatchProtocol.swift` | §3.5 |

### 5.2 `WatchModel`

```swift
import Foundation
import WatchConnectivity
import WatchKit

enum WatchRowState: Equatable {
    case idle
    case sending
    /// final == false: on air or queued, a lastSend is still due.
    case result(ok: Bool, text: String, final: Bool)
}

@MainActor
final class WatchModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var favorites: [WatchFavorite] = []
    @Published private(set) var status: WatchStatus?
    @Published private(set) var theme: WatchThemeColors = WatchThemeColors.amber
    /// iPhone time of the newest snapshot (context or reply), Unix seconds; 0 = never.
    @Published private(set) var updatedAt: Double = 0
    @Published private(set) var reachable: Bool = false
    @Published private(set) var companionInstalled: Bool = true
    @Published private(set) var rows: [String: WatchRowState] = [:]
    @Published private(set) var stopState: WatchRowState = .idle
    @Published private(set) var refreshing: Bool = false
    /// The app is frontmost (scenePhase .active); the STATUS poll runs only then.
    private(set) var active: Bool = true
    ...
}
```

- **Init**: load the cache (`UserDefaults` `MMWatchSnapshot`: the last
  `WatchContext.dictionary()` this model applied), then activate the session.
- **Delegate** (`nonisolated`): parse into `WatchContext` / `Bool`s on the delegate queue, then
  `Task { @MainActor in … }`.
  - `activationDidCompleteWith`: apply `receivedApplicationContext`; set `reachable`,
    `companionInstalled` (`session.isCompanionAppInstalled`); `await refresh()` if reachable.
  - `didReceiveApplicationContext`: apply.
  - `sessionReachabilityDidChange`: set `reachable`; refresh if it became reachable while
    `active`.
  - `sessionCompanionAppInstalledDidChange`: set `companionInstalled`.
- **`apply(_ c: WatchContext)`**: ignore if `c.at < updatedAt - 1` (an older snapshot arriving
  late). Otherwise take each non-nil part, set `updatedAt = c.at`, and save the cache. For
  `lastSend`: keep it as the newest for its id (`latestSends`). If `rows[id]` is
  `.result(final: false)`, `at >= pendingSince[id]` and `now - at < 60`, set
  `.result(ok:, text:, final: true)` and play `.success` / `.failure`. `pendingSince[id]` is the
  iPhone `at` of the `on_air` / `queued` reply, recorded when the row starts waiting. At that
  point `latestSends[id]` is checked too, in case the result's context arrived first (§3.3).
- **`send(_ f: WatchFavorite)`**: ignore if `rows[f.id] == .sending`. Without
  `activationState == .activated && isReachable`: row `IPHONE NOT REACHABLE`, `.failure`, done
  (no send, no queue). Otherwise `.click`, `.sending`, and
  `sendMessage(WatchRequest(op: opSend, id: f.id).dictionary(), replyHandler:, errorHandler:)`.
  The handlers parse `WatchReply(dictionary:)` or map the `Error`, then hop to the main actor:
  apply `reply.context`, set the row from the table in §3.3, and play the haptic. Clear the row
  to `.idle` 5 s after a final result (a per-row token makes sure a newer state is not cleared).
- **`stopPrograms()`**: as `send`, with `opStopPrograms` and `stopState`.
- **`refresh() async`**: `guard` activated, reachable and `!refreshing`.
  `await withCheckedContinuation { cont in sendMessage(…, replyHandler: { cont.resume(returning:
  WatchReply(dictionary: $0)) }, errorHandler: { _ in cont.resume(returning: nil) }) }`. WC
  calls exactly one of the two handlers. Then apply the context.
- `func setActive(_ on: Bool)`: `WatchRootView` calls it from `onChange(of: scenePhase)`.
  Becoming active triggers `refresh()`.
- `static func errorText(_ error: Error) -> String`: `WCError.Code(rawValue: (error as NSError).code)`
  → the texts in §3.3.
- Haptics: `WKInterfaceDevice.current().play(.click / .success / .failure / .start)`.

### 5.3 Pages

`WatchRootView`:

```swift
TabView(selection: $page) {
    FavoritesPage().tag(0)
    StatusPage().tag(1)
    StopPage().tag(2)
}
.tabViewStyle(.page)                              // horizontal pages; the favourites list scrolls vertically
.containerBackground(Color.black, for: .tabView)  // watchOS 10
.onChange(of: scenePhase) { _, phase in model.setActive(phase == .active) }
.task(id: page) {                                 // STATUS and STOP stay fresh while shown
    if page == 0 { return }
    while !Task.isCancelled {
        if model.active { await model.refresh() }
        try? await Task.sleep(nanoseconds: 10_000_000_000)
    }
}
```

`.page` (horizontal) instead of watchOS 10's `.verticalPage`: a 24-row list inside a vertical
pager would have to be scrolled to its end to reach STATUS.

**FAVORITES** (`ScrollView { VStack(alignment: .leading, spacing: 6) }`, 4 pt side padding):
- Header: `FAVORITES` (highlight, `WatchFont.small` semibold). Below it, the link line:
  `VIA ESP32 · LINKED` (dim) / `ESP32 NOT LINKED` (alarm) from `status`, or `IPHONE NOT
  REACHABLE` (alarm, inverted block when `alarmInverted`) when `!reachable`. When
  `!companionInstalled`: `INSTALL MAGICMAKER ON IPHONE`.
- One `Button(action: { model.send(fav) })` per favourite, `.buttonStyle(.plain)`, full width,
  **min height 52 pt**, 8 pt padding, `RoundedRectangle(cornerRadius: 6)` 1 pt stroke in dim:
  - line 1: label uppercased, `WatchFont.title`, text ink, `lineLimit(2)`
  - line 2: swatch dot (wand, 8 pt circle in the true colour) + `BAND` / `WAND` / `PING` / `QUICK`
    + `· …6F1D` (last 4 hex digits), `WatchFont.small`, dim
  - state: `.sending` → the whole card inverted (fill highlight, all text black) with `SENDING…`;
    `.result` → a third line `✓ VIA ESP32` (highlight) or `✕ NOT LINKED` (alarm); non-final ones
    read `ON AIR · VIA ESP32`
  - rows are dimmed (60 % opacity of the inks) while `!reachable` but stay tappable, and a tap
    then explains why nothing happens.
- Empty: `NO FAVORITES` (text) and `STAR ★ PACKETS IN THE IPHONE APP: TX, WAND, LAB` (dim).

**STATUS** (`List`, `.listStyle(.plain)`, `.refreshable { await model.refresh() }`, rows with
`.listRowBackground(Color.clear)`). Sections have dim monospaced headers:

| Section | Rows |
|---|---|
| ESP32 | state (`LINKED` highlight / `LINKING…` dim / `NOT LINKED` alarm / `NOT SELECTED` dim); battery `68%` in `WatchFont.hero` + `~9H 40M` (`AndroidRemoteStatus.runtimeText` rule: `~40M`, `~9H 40M`, `~99H+`), or `CHARGING · 4.18V`, or `4.05V` (alarm when ≤ 20 %, ≤ 3.55 V or `batteryLow`); `BATTERY LOW — CHARGE SOON` (alarm, small) under it while `batteryLow` and not charging; program; `FW 1.2 · HELTEC V3 · UP 2H 14M`; `outdated` → `REFLASH — FIRMWARE TOO OLD` (alarm) |
| ANDROID | state + transport (`LINKED · BLE`); `SCAN ON · AUTO ON`; program; `HEARD <label>` |
| IPHONE | `81%` + `CHG`; `SCAN ON · AUTO ARMED`, or `SCAN ON · PAUSED (IPHONE APP IN BACKGROUND)`, or `BLUETOOTH OFF`; `LAST HEARD <label> · 12S AGO` (age from `lastHeardAt`, ticking); TX status; programs |
| footer | `UPDATED 12S AGO` (from `updatedAt`, ticking via `TimelineView(.periodic(from: .now, by: 1))`), `PULL TO REFRESH`, and a `REFRESH` button row (spinner text `REFRESHING…` while `refreshing`) |

Before any status: `NO DATA YET — OPEN MAGICMAKER ON IPHONE`.

**STOP**:
- `PROGRAMS` header. The running programs, one per line: `ESP32: TX LOOP · 3S`,
  `ANDROID: KEEP AWAKE`, `IPHONE: RANDOM SHOW` (from `esp32.program`, `android.program` when not
  `IDLE`, `phone.programs`), or `NOTHING RUNNING` (dim).
- One full-width button, **min height 60 pt**: `STOP PROGRAMS`, an inverted alarm block (fill
  alarm, black text; fill highlight when `alarmInverted`). Disabled look while `!reachable`.
- It opens `.alert("STOP PROGRAMS?", isPresented: $confirming) { Button("STOP", role:
  .destructive) { model.stopPrograms() }; Button("CANCEL", role: .cancel) { } } message: {
  Text("Ends keep-awake, the TX and wand loops, the random show and any replay.") }`.
- Under it, `stopState`'s result line: `STOPPED · VIA ESP32` or the note/error.

Always-on display (`@Environment(\.isLuminanceReduced)`): hide line 2 of the cards and the hex,
and draw the inks at 50 %.

### 5.4 Look (`WatchTheme.swift`)

- Background `Color.black`; nothing else is filled except inverted blocks. No gradients, glows
  or materials.
- `WatchInk(model.theme)`: `highlight`, `text`, `dim`, `alarm` from `Color(watchHex:)`:

  ```swift
  extension Color {
      /// "#RRGGBB" (leading # optional); black for anything else.
      init(watchHex: String) {
          var digits: String = watchHex.trimmingCharacters(in: .whitespaces)
          if digits.hasPrefix("#") { digits.removeFirst() }
          let value: UInt32 = digits.count == 6 ? (UInt32(digits, radix: 16) ?? 0) : 0
          self.init(red: Double((value >> 16) & 0xFF) / 255.0,
                    green: Double((value >> 8) & 0xFF) / 255.0,
                    blue: Double(value & 0xFF) / 255.0)
      }
  }
  ```

- `WatchFont`: `title` = `.system(size: 15, weight: .semibold, design: .monospaced)`, `body` 13
  regular, `small` 11 regular, `hero` 24 bold, all monospaced. Text is uppercase. Fixed sizes fit
  40 mm (162 pt wide) to 49 mm (205 pt wide) with `lineLimit` and `minimumScaleFactor(0.8)` on
  single lines.
- `watchAgeText(_ seconds: Double)`: `<60` → `12S`, `<3600` → `4M`, else `2H 5M`; negative
  values (clock skew) → `0S`.

### 5.5 API availability (watchOS 10.0 deployment target)

All used APIs are available at 10.0: `TabView` + `.tabViewStyle(.page)` (7.0),
`containerBackground(_:for: .tabView)` (10.0), `onChange(of:_:)` with two-parameter closure
(10.0), `task(id:)` (8.0), `List.refreshable` (8.0), `alert(_:isPresented:actions:message:)`
(8.0), `Button(role:)` (8.0), `TimelineView(.periodic)` (8.0), `isLuminanceReduced` (8.0),
`Font.system(size:weight:design:)` (6.0), `WKInterfaceDevice.play` (2.0),
`WCSession.isCompanionAppInstalled` (6.0), `sendMessage` / `receivedApplicationContext` (2.0),
`withCheckedContinuation` (back-deployed). Do **not** use `handGestureShortcut` (11.0) or
`.verticalPage` paging inside a long list.

iPhone side: `WCSession` (9.0), `isPaired` / `isWatchAppInstalled` / `isReachable`,
`updateApplicationContext` (9.0) and `beginBackgroundTask(withName:expirationHandler:)` are all
fine at iOS 17.

---

## 6. Project plan

### 6.1 New files and their targets

| Path (under `ios/`) | Target(s) | Group |
|---|---|---|
| `MagicMaker/Watch/WatchProtocol.swift` | **MagicMaker + MagicMakerWatch** | MagicMaker/Watch |
| `MagicMaker/Watch/WatchFavoritesStore.swift` | MagicMaker | MagicMaker/Watch |
| `MagicMaker/Watch/WatchBridge.swift` | MagicMaker | MagicMaker/Watch |
| `MagicMaker/Watch/WatchContextBuilder.swift` | MagicMaker | MagicMaker/Watch |
| `MagicMaker/Watch/WatchFavoritesSection.swift` (`FavoriteStarButton`, `SettingsWatchSection`; `PacketRowStar` goes in `Views/SharedViews.swift` next to `PacketRow`) | MagicMaker | MagicMaker/Watch |
| `MagicMaker/Watch/VFDWatchSection.swift` (`VFDStar`, `VFDWatchSection`) | MagicMaker | MagicMaker/Watch |
| `MagicMakerWatch/MagicMakerWatchApp.swift`, `WatchModel.swift`, `WatchTheme.swift`, `FavoritesPage.swift`, `StatusPage.swift`, `StopPage.swift` | MagicMakerWatch (Sources) | MagicMakerWatch |
| `MagicMakerWatch/Assets.xcassets` | MagicMakerWatch (Resources) | MagicMakerWatch |
| `MagicMakerWatch/Info.plist` | none (referenced by `INFOPLIST_FILE`) | MagicMakerWatch |

No new file goes into `MagicMaker/Core/`: `ios-core-parity.yml` lists every Core file on
purpose. No new file goes into `MagicMaker/VFD/` either: those three Foundation-only files are
the golden-checked module.

### 6.2 `project.pbxproj` objects

IDs are `md5("MagicMakerWatch/" + name)[:24]`, uppercase. They are deterministic, so a rerun or a
review gives the same values. The script checks that they are unique.

| Object | isa | ID | Notes |
|---|---|---|---|
| watch product | PBXFileReference | `29A8E8578F064480110EDA68` | `MagicMakerWatch.app`, `explicitFileType = wrapper.application`, `includeInIndex = 0`, `sourceTree = BUILT_PRODUCTS_DIR`; child of Products |
| watch target | PBXNativeTarget | `06B0450173F659BB8BEDE66B` | `productType = "com.apple.product-type.application"`, phases Sources, Frameworks, Resources; no dependencies |
| watch group | PBXGroup | `D4CA0B53AD7C708933E91824` | `path = MagicMakerWatch`; child of the main group after `MagicMaker` |
| iPhone Watch group | PBXGroup | `C80108D6A3FAE36362A16F0F` | `path = Watch`; child of the `MagicMaker` group |
| watch Sources | PBXSourcesBuildPhase | `A4CB0D4FA8D8DD633CA7C569` | 6 watch files + `WatchProtocol.swift` |
| watch Frameworks | PBXFrameworksBuildPhase | `B95A5EF8ED998CABFD3687B1` | empty (WatchConnectivity and WatchKit auto-link from `import`) |
| watch Resources | PBXResourcesBuildPhase | `E17D14D38F8339D2872F49B6` | `Assets.xcassets` |
| Embed Watch Content | PBXCopyFilesBuildPhase | `0CD277682464D3C5D3FED787` | iPhone target, after its Resources phase; `dstPath = "$(CONTENTS_FOLDER_PATH)/Watch"`, `dstSubfolderSpec = 16`, `name = "Embed Watch Content"`, `runOnlyForDeploymentPostprocessing = 0` |
| embed build file | PBXBuildFile | `2C057B9229DCEF16401CF86F` | `fileRef` = product, `settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }` |
| proxy | PBXContainerItemProxy | `8A08B6A9C615D4C03FCDEF79` | `containerPortal` = project object `2A3216FC15416A36C0A4E386`, `proxyType = 1`, `remoteGlobalIDString` = watch target, `remoteInfo = MagicMakerWatch` |
| dependency | PBXTargetDependency | `8E7F78114BBAA8843CD233BE` | `target` = watch target, `targetProxy` = proxy; in the iPhone target's `dependencies` |
| config list | XCConfigurationList | `96336B2F7114D988C695E8D6` | Debug, Release; default Debug |
| Debug / Release | XCBuildConfiguration | `42AF6563619A5C463028B565` / `13FC2F9BBF590DC497235855` | §6.3 |
| file references | PBXFileReference | `uid("fileref:<group path>/<name>")` | 6 iPhone + 8 watch; `sourcecode.swift`, `folder.assetcatalog`, `text.plist.xml` |
| source / resource build files | PBXBuildFile | `uid("buildfile:ios:…")`, `uid("buildfile:watch:…")` | `WatchProtocol.swift` has **two** (one per target) on one file reference |

Changes to existing objects:
- main group `children` += watch group
- `MagicMaker` group += `Watch`
- Products += watch product
- iPhone Sources += the 6 `Watch/` files
- iPhone `buildPhases` += Embed Watch Content (after Resources)
- iPhone `dependencies` += the dependency
- PBXProject `targets` += watch target
- `TargetAttributes` += `{ CreatedOnToolsVersion = 26.0; ProvisioningStyle = Automatic; }`

The file has no PBXContainerItemProxy, PBXCopyFilesBuildPhase, PBXFrameworksBuildPhase or
PBXTargetDependency section yet. The script creates them in Xcode's alphabetical places.

### 6.3 Watch build settings (Debug and Release identical)

```
ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
CODE_SIGN_STYLE = Automatic;
CURRENT_PROJECT_VERSION = <iPhone target's, now 21>;
DEVELOPMENT_TEAM = <iPhone target's, 9BQDEVHKJZ>;
ENABLE_DEBUG_DYLIB = NO;
ENABLE_PREVIEWS = NO;
GENERATE_INFOPLIST_FILE = YES;
INFOPLIST_FILE = MagicMakerWatch/Info.plist;
INFOPLIST_KEY_CFBundleDisplayName = MagicMaker;
INFOPLIST_KEY_UISupportedInterfaceOrientations = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown";
INFOPLIST_KEY_WKCompanionAppBundleIdentifier = Com.lightwave.mmios;
INFOPLIST_KEY_WKRunsIndependentlyOfCompanionApp = NO;
LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks");
MARKETING_VERSION = <iPhone target's, now 1.3.0>;
PRODUCT_BUNDLE_IDENTIFIER = Com.lightwave.mmios.watchkitapp;
PRODUCT_NAME = "$(TARGET_NAME)";
SDKROOT = watchos;
SKIP_INSTALL = YES;
SUPPORTED_PLATFORMS = "watchos watchsimulator";
SWIFT_VERSION = 5.9;
TARGETED_DEVICE_FAMILY = 4;
WATCHOS_DEPLOYMENT_TARGET = 10.0;
```

- `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` (the catalog's `AccentColor`, amber) and the
  portrait / upside-down orientations are Xcode's watch-app template defaults, added when the
  target was applied.
- The script reads `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, `DEVELOPMENT_TEAM` and
  `PRODUCT_BUNDLE_IDENTIFIER` from the iPhone target at run time, because CI may have bumped them.
  Every `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` line in the file then agrees, and the CI's
  "Record the version and build" `sed` rewrites all of them, so the two targets stay in step. The
  watch app's `CFBundleVersion` and `CFBundleShortVersionString` **must** equal the iPhone app's,
  or App Store Connect rejects the upload.
- **`SKIP_INSTALL = YES`** is essential: without it, the archive carries a second app in
  `Products/Applications` and can no longer be exported for the App Store.
- The project-level `IPHONEOS_DEPLOYMENT_TARGET`, `SDKROOT = iphoneos` and
  `TARGETED_DEVICE_FAMILY = "1,2"` are overridden by the target. `CODE_SIGN_IDENTITY = "iPhone
  Developer"`, `-ld_classic` and the entitlements stay on the iPhone target only.
- Deliberately **not** set: Xcode 26 template defaults `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
  and `SWIFT_APPROACHABLE_CONCURRENCY`. The watch code is written for the iPhone target's
  semantics (Swift 5.9 mode, nonisolated by default).

### 6.4 Applying it

1. Save Appendix A as `ios/tools/add_watch_target.py`. It was tested against the current file,
   including the sync workflow's newly registered `Sync/*` files.
2. Create every file in §6.1 first.
3. `python3 ios/tools/add_watch_target.py --check`, then `python3 ios/tools/add_watch_target.py`.

The script parses the whole file (an OpenStep plist parser). It refuses to run twice. It inserts
the objects and list entries, then verifies on a re-parse:
- all new ids are unique 24-hex
- every reference in `fileRef`, `children`, `files`, `buildPhases`, `dependencies`, `target`,
  `targetProxy`, `containerPortal`, `remoteGlobalIDString`, `buildConfigurationList`,
  `buildConfigurations`, `productReference`, `mainGroup`, `productRefGroup` and `targets`
  resolves
- every file reference is in exactly one group
- every build file is in exactly one phase, and no phase lists a file twice
- the watch Sources phase is exactly the 6 watch files plus `WatchProtocol.swift`
- the iPhone Sources phase has each `Watch/` file once and no watch file
- the embed phase, the dependency and the bundle ids are right
- all version lines agree

It re-reads the file right before writing and aborts if another workflow changed it meanwhile.
The write is atomic (`os.replace`).

`ios/tools/generate_xcode_project.py` is stale (it lists files that no longer exist). It must not
be run; it would drop both targets' real file lists.

### 6.5 Asset catalog and Info.plist

```
ios/MagicMakerWatch/Assets.xcassets/Contents.json
  {"info":{"author":"xcode","version":1}}
ios/MagicMakerWatch/Assets.xcassets/AppIcon.appiconset/Contents.json
  {"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"watchos","size":"1024x1024"}],
   "info":{"author":"xcode","version":1}}
ios/MagicMakerWatch/Assets.xcassets/AppIcon.appiconset/AppIcon.png
  a byte copy (cp, not a symlink) of ios/MagicMaker/Assets.xcassets/AppIcon.appiconset/AppIcon.png
  (1024 x 1024, 8-bit RGB without alpha: what watchOS icons need)
```

`ios/MagicMakerWatch/Info.plist` is merged with the generated keys:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>WKApplication</key>
	<true/>
</dict>
</plist>
```

`WKApplication` marks a single-target watch app. Xcode normally generates it. It is written
explicitly here so the bundle cannot ship without it, and the CI check (§6.7) reads it back. The
file is in the group but in no build phase.

### 6.6 Scheme

Not needed. The shared `MagicMaker.xcscheme` archives the iPhone target. The explicit
`PBXTargetDependency` builds `MagicMakerWatch` for `generic/platform=watchOS` as part of the iOS
archive, and the embed phase copies it into `MagicMaker.app/Watch/`.

Locally, Xcode auto-creates a `MagicMakerWatch` scheme for running on a watch, because the
workspace has no `IDEWorkspaceSharedSettings` that turns auto-creation off. A shared watch scheme
can be added later if wanted; CI never uses it.

### 6.7 CI changes (`.github/workflows/ios-testflight.yml`)

1. **Archive step: remove `PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \`.** A build setting on the
   `xcodebuild` command line applies to **every** target. The watch app would become
   `Com.lightwave.mmios` too, and the build would fail: the embedded bundle id must be prefixed
   by the parent's. The project already sets the iPhone target's id. Keep the `BUNDLE_ID` env for
   `next_build_number.py`. Keep `DEVELOPMENT_TEAM`, `CODE_SIGN_STYLE`, `MARKETING_VERSION`,
   `CURRENT_PROJECT_VERSION`, `ENABLE_DEBUG_DYLIB` and `ENABLE_PREVIEWS` overrides: applying them
   to both targets is exactly right (versions in step).

2. **Before Archive**, make sure a watchOS simulator runtime for the SDK's major.minor exists
   (26.1 SDK: watchOS 26.1 or 26.1.x). `actool` compiles a watchOS asset catalog against one, a
   runner image may lack it, and an older runtime alone (when a newer Xcode is selected) is not
   enough. Unavailable runtimes do not count; a failed download only warns:

   ```yaml
   - name: watchOS platform (asset catalog compiler)
     run: |
       sdk=$(xcrun --sdk watchos --show-sdk-version 2>/dev/null || true)
       sdk_re=$(printf '%s' "$sdk" | sed 's/\./\\./g')
       runtimes=$(xcrun simctl list runtimes 2>/dev/null | grep -v 'unavailable' || true)
       if [ -n "$sdk" ] && grep -qE "^watchOS ${sdk_re}[ .]" <<< "$runtimes"; then
         echo "watchOS $sdk simulator runtime present"
       else
         xcodebuild -downloadPlatform watchOS || echo "::warning::Couldn't download the watchOS platform"
       fi
   ```

3. **After Archive**, check the embedded watch app:

   ```yaml
   - name: Check the embedded watch app
     run: |
       apps="build/$SCHEME.xcarchive/Products/Applications"
       app="$apps/MagicMaker.app"
       watch="$app/Watch/MagicMakerWatch.app"
       count=$(ls "$apps" | wc -l | tr -d ' ')
       [ "$count" = "1" ] || { echo "::error::The archive holds $count apps (the watch target needs SKIP_INSTALL = YES)"; exit 1; }
       [ -d "$watch" ] || { echo "::error::No watch app at MagicMaker.app/Watch/MagicMakerWatch.app"; exit 1; }
       get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Info.plist"; }
       fail() { echo "::error::Watch app: $1"; exit 1; }
       [ "$(get "$watch" CFBundleIdentifier)" = "$BUNDLE_ID.watchkitapp" ] || fail "bundle id $(get "$watch" CFBundleIdentifier)"
       [ "$(get "$watch" WKCompanionAppBundleIdentifier)" = "$BUNDLE_ID" ] || fail "companion id"
       [ "$(get "$watch" WKApplication)" = "true" ] || fail "WKApplication missing"
       [ "$(get "$watch" CFBundleVersion)" = "$(get "$app" CFBundleVersion)" ] || fail "build number differs from the iPhone app"
       [ "$(get "$watch" CFBundleShortVersionString)" = "$(get "$app" CFBundleShortVersionString)" ] || fail "version differs from the iPhone app"
       echo "Watch app: $(get "$watch" CFBundleIdentifier) $(get "$watch" CFBundleShortVersionString) ($(get "$watch" CFBundleVersion))"
   ```

4. Header comment: add "The archive embeds the watch app (ios/MagicMakerWatch, bundle id
   Com.lightwave.mmios.watchkitapp); docs/WATCH_APP.md."

Unchanged:
- **ExportOptions** (`app-store-connect`, automatic signing) signs the embedded app too.
- **`-allowProvisioningUpdates`** with the API key registers `Com.lightwave.mmios.watchkitapp`
  and makes its profiles on the first run.
- **`next_build_number.py`** asks about the iPhone bundle id, and the watch app shares that App
  Store record and build number.
- **The build-number check and the version `sed`** cover the watch lines automatically.
- The error annotation `grep` already matches `ios/MagicMakerWatch/*.swift` paths.

### 6.8 Mirrors and docs

- `ios/project.yml` (mirror only; the CI `sed` keeps its version lines in step): add a
  `MagicMakerWatch` target (`type: application`, `platform: watchOS`,
  `deploymentTarget: "10.0"`, sources `MagicMakerWatch` + `MagicMaker/Watch/WatchProtocol.swift`,
  the §6.3 settings with `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` lines), and give
  `MagicMaker` `dependencies: [{target: MagicMakerWatch}]`.
- `ios/README.md`: a short "Apple Watch" section (install from the Watch app on the iPhone →
  Available Apps; star packets; SETTINGS → APPLE WATCH).

---

## 7. Implementation order and edit list

No Swift compiler is available outside CI. Read each line as the compiler would, then use one
`*b` commit (archive only) before `*u`.

| Step | Files | Notes |
|---|---|---|
| 1 | new `Watch/WatchProtocol.swift`, `Watch/WatchFavoritesStore.swift` | §3.5, §2.2 |
| 2 | `Views/SharedViews.swift` (PacketRow `star:`), new `Watch/WatchFavoritesSection.swift`, `Views/TxScreen.swift`, `Views/LabScreen.swift`, `Views/StarlightWandView.swift`, `Views/WandScreen.swift`, `Views/SettingsScreen.swift` (1 line) | standard stars + list |
| 3 | new `Watch/VFDWatchSection.swift`, `VFD/VFDTxScreen.swift`, `VFD/VFDLabScreen.swift`, `VFD/VFDWandScreen.swift`, `VFD/VFDSettingsScreen.swift` (1 line), `VFD/VFDRootView.swift` (2 lines) | VFD stars + list |
| 4 | `ViewModels/TxEngine.swift` (§4.6, **re-read first**), new `Watch/WatchContextBuilder.swift`, `Watch/WatchBridge.swift`, `Views/LaunchBootstrapView.swift`, `MagicMakerApp.swift` (1 line) | bridge |
| 5 | new `ios/MagicMakerWatch/*` (6 Swift, asset catalog, Info.plist) | watch app |
| 6 | `ios/tools/add_watch_target.py` (Appendix A), run it | **re-read `project.pbxproj` right before**; the sync workflow also registers files |
| 7 | `.github/workflows/ios-testflight.yml` (§6.7), `ios/project.yml`, `ios/README.md` | |
| 8 | `*b` commit → fix → `*u` | |

---

## 8. Test plan

**CI**: the `*b` archive must pass the "Check the embedded watch app" step. After `*u`,
TestFlight shows one build with an Apple Watch app.

**Device matrix** (iPhone + Apple Watch on watchOS 10 or later, ESP32 Heltec V3, Android relay):

| # | Case | Expect |
|---|---|---|
| 1 | Star a TX row, a Lab preset, a Starlight colour, a New Wand code and the quick button, in both themes | stars fill (amber / VFD highlight); SETTINGS → APPLE WATCH lists 5 in order; the watch shows them within ~1 s |
| 2 | 25th star | FAVORITES FULL alert, nothing added |
| 3 | Reorder, rename, remove (confirm) in both themes | watch follows at once |
| 4 | Reprogram the quick button | its favourite's label and hex follow |
| 5 | Watch: tap a wand colour, ESP32 linked, iPhone app open | colour on air, ✓ VIA ESP32 + success haptic in ~1 s; iPhone TX status shows it |
| 6 | Watch: band command with the default 4 s burst | ✓ within ~6 s; with a 12 s burst: ON AIR, then ✓ via lastSend |
| 7 | Wand loop running, tap a wand favourite | the loop switches colour, `LOOP · VIA …` |
| 8 | iPhone app suspended (home screen, locked), ESP32 linked | tap works (background wake + BLE write) |
| 9 | iPhone app killed by iOS (e.g. after a reboot, opened once, then left) | first tap: link-hint error or success; second tap works |
| 10 | iPhone in another room / Bluetooth off | IPHONE NOT REACHABLE, nothing sent later |
| 11 | STOP PROGRAMS with an ESP32 TX loop, then keep-awake | confirm; STOPPED · VIA ESP32; STATUS shows IDLE after the next read |
| 12 | STATUS: ESP32 battery / runtime / charging / FW / uptime; Android backend linked; iPhone battery, scan, AUTO, last heard age | values match LINK and the telemetry bar; pull to refresh updates "UPDATED" |
| 13 | Change the VFD base colour to GREEN | watch inks turn green at once |
| 14 | VFD theme on; a watch tap wakes the suspended app; the app is later killed and relaunched | the app still opens in the VFD theme (launch guard cleared, §4.1) |
| 15 | iPad | SETTINGS shows NOT AVAILABLE ON THIS DEVICE; no crash |
| 16 | ESP32 keep-awake (or a loop) running; iOS has ended the iPhone app; watch STOP PROGRAMS | STOPPED · VIA ESP32, and the board really stops (keep-awake / loop off are sent although the iPhone had read no STATUS yet) |
| 17 | 12 s band burst: tap A (ON AIR, then ✓), wait, tap A again | the second tap stays ON AIR until its own result; it is not finished early by the first tap's result |
| 18 | iPhone app open, ESP32 linked, watch app closed, 5 min | the watch gets a context about once a minute, not every 2 s (uptime and battery alone wait 60 s); a link drop or a program change still arrives within ~2 s |
| 19 | iPhone app ended by iOS, ESP32 on, watch tap | the reply is never `BLUETOOTH UNAVAILABLE` while the radio is starting: it waits for the link (success, or the link hint after 4 s) |

---

## 9. Risks and open items

- **Watch development profile on CI.** The archive is signed for development first. Automatic
  signing must create a development profile for the new watch App ID. If the API key's role
  cannot register identifiers, or the team has no registered device, the first `*b` fails
  during signing. Remedy: register `Com.lightwave.mmios.watchkitapp` once by hand in
  Certificates, Identifiers & Profiles (and register the watch's UDID if asked), then rerun.
- **watchOS runtime download** (§6.7 step 2) adds minutes when the image lacks it.
- **WatchConnectivity reply window** is not documented. The 7 s reply budget plus `lastSend`
  keeps replies short whatever the burst length.
- **Force-quit**: iOS may refuse to relaunch an app the user swiped away. The watch then says
  so, and the user opens the iPhone app.
- **A screenless wake builds the whole app** (store load, BLE, location start). This is the same
  work as a launch and is bounded by the background task. Location permission is never prompted
  in the background.
- **Swift 6 compiler in Swift 5 mode**: the handler closures are captured across actors in
  ways Swift 6 mode would reject. This is fine at `SWIFT_VERSION = 5.9`. Moving either target to
  Swift 6 needs `@Sendable` / `sending` work in `WatchBridge` and `WatchModel`.
- **VFD fit**: the star column takes 14 cells from TX rows and 19 + 6 from the wand picker row.
  The 207-cell (2x) layout keeps 179+ cells for labels, so check it in the previews if they are
  updated.

---

## 10. Later (not v1)

- **Sync hub heartbeats (SYNC_HUB_SPEC §9)**: add optional `devices: [WatchDevice]` to
  `WatchStatus` (`id`, `kind`, `name`, `battPct`, `battMv`, `charging`, `runtimeMin`,
  `lastSeenAt`, `path` DIRECT / VIA, `role` PRIMARY / BACKUP, `txState`, `program`, `alerts`)
  from the iPhone's HB table. The STATUS page then shows both relays at once with ages and paths,
  and §9.5 alerts in alarm ink. `v` stays 1.
- **TransmitRouter (D9)**: `via` from the link actually used. Add an optional `failover: String?`
  notice (e.g. `ESP32 UNREACHABLE — SENT VIA ANDROID`).
- Complications / Smart Stack widget (WidgetKit) for one-tap favourites and ESP32 battery. This
  needs an App Group or a watch-side cache shared with the widget extension.
- Double-tap (`handGestureShortcut(.primaryAction)`, watchOS 11) on the first favourite, behind
  `if #available(watchOS 11.0, *)`.

---

## Appendix A: `ios/tools/add_watch_target.py`

Tested against the current `project.pbxproj` (with the sync workflow's `Sync/*` entries):
`--check` verifies, the first run adds 42 objects, the second refuses. Saved as `ios/tools/add_watch_target.py` and applied
(the file below is that script).

```python
#!/usr/bin/env python3
"""Adds the MagicMakerWatch target (watchOS 10 app embedded in MagicMaker) to project.pbxproj.

Re-reads the file, inserts the watch objects and the iPhone Watch/ files, verifies the result and
writes it back in one go. Refuses to run twice. Usage:

    python3 add_watch_target.py [path/to/project.pbxproj] [--check]

--check: build and verify in memory only, write nothing.
"""
import hashlib
import os
import re
import sys

PBX = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else \
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "MagicMaker.xcodeproj", "project.pbxproj")
CHECK_ONLY = "--check" in sys.argv

WATCH_TARGET = "MagicMakerWatch"
IOS_TARGET = "MagicMaker"
WATCH_BUNDLE_SUFFIX = ".watchkitapp"

# iPhone files: group MagicMaker/Watch. (name, in iOS Sources, in watch Sources)
IPHONE_FILES = [
    ("WatchProtocol.swift", True, True),
    ("WatchFavoritesStore.swift", True, False),
    ("WatchBridge.swift", True, False),
    ("WatchContextBuilder.swift", True, False),
    ("WatchFavoritesSection.swift", True, False),
    ("VFDWatchSection.swift", True, False),
]
# Watch files: group MagicMakerWatch. (name, phase) phase: sources / resources / none
WATCH_FILES = [
    ("MagicMakerWatchApp.swift", "sources"),
    ("WatchModel.swift", "sources"),
    ("WatchTheme.swift", "sources"),
    ("FavoritesPage.swift", "sources"),
    ("StatusPage.swift", "sources"),
    ("StopPage.swift", "sources"),
    ("Assets.xcassets", "resources"),
    ("Info.plist", "none"),
]


def uid(name):
    return hashlib.md5(("MagicMakerWatch/" + name).encode()).hexdigest()[:24].upper()


# ---------------------------------------------------------------- OpenStep plist parser (verify)

class Parser:
    TOKEN = re.compile(r'\s+|/\*.*?\*/|//[^\n]*|"(?:[^"\\]|\\.)*"|[{}()=;,]|[^\s{}()=;,"]+', re.S)

    def __init__(self, text):
        self.toks = []
        for m in self.TOKEN.finditer(text):
            t = m.group(0)
            if t[0].isspace() or t.startswith("/*") or t.startswith("//"):
                continue
            self.toks.append(t)
        self.i = 0

    def next(self):
        t = self.toks[self.i]
        self.i += 1
        return t

    def value(self):
        t = self.next()
        if t == "{":
            d = {}
            while self.toks[self.i] != "}":
                k = self.scalar(self.next())
                if k in d:
                    raise ValueError("duplicate key " + k)
                if self.next() != "=":
                    raise ValueError("expected = after " + k)
                d[k] = self.value()
                if self.next() != ";":
                    raise ValueError("expected ; after value of " + k)
            self.i += 1
            return d
        if t == "(":
            a = []
            while self.toks[self.i] != ")":
                a.append(self.value())
                if self.toks[self.i] == ",":
                    self.i += 1
            self.i += 1
            return a
        return self.scalar(t)

    @staticmethod
    def scalar(t):
        if t.startswith('"'):
            return bytes(t[1:-1], "utf-8").decode("unicode_escape")
        return t


def parse(text):
    p = Parser(text)
    root = p.value()
    if p.i != len(p.toks):
        raise ValueError("trailing tokens")
    return root


# ---------------------------------------------------------------- text helpers

def object_block(text, oid):
    """(start, end) of the object `oid` (from its tab-indented key line to its closing '};')."""
    m = re.search(r"^\t\t" + oid + r"(?: /\*.*?\*/)? = \{", text, re.M)
    if not m:
        raise SystemExit("object %s not found" % oid)
    if text[m.end():m.end() + 1] != "\n":   # one-line object
        end = text.index("};\n", m.end()) + 3
        return m.start(), end
    end = text.index("\n\t\t};\n", m.end()) + len("\n\t\t};\n")
    return m.start(), end


def insert_in_list(text, oid, key, line, after=None):
    """Adds `line` (one list entry) to list `key` of object `oid`, after the entry containing
    `after` (or at the end)."""
    s, e = object_block(text, oid)
    block = text[s:e]
    m = re.search(r"^(\t+)" + re.escape(key) + r" = \(\n(.*?)^\1\);", block, re.M | re.S)
    if not m:
        raise SystemExit("list %s not found in %s" % (key, oid))
    indent = m.group(1) + "\t"
    body = m.group(2)
    entry = indent + line + ",\n"
    if after:
        idx = body.find(after)
        if idx < 0:
            raise SystemExit("%s not in %s.%s" % (after, oid, key))
        cut = body.index("\n", idx) + 1
        body = body[:cut] + entry + body[cut:]
    else:
        body = body + entry
    block = block[:m.start(2)] + body + block[m.end(2):]
    return text[:s] + block + text[e:]


SECTION_ORDER = [
    "PBXBuildFile", "PBXContainerItemProxy", "PBXCopyFilesBuildPhase", "PBXFileReference",
    "PBXFileSystemSynchronizedBuildFileExceptionSet", "PBXFileSystemSynchronizedRootGroup",
    "PBXFrameworksBuildPhase", "PBXGroup", "PBXHeadersBuildPhase", "PBXNativeTarget", "PBXProject",
    "PBXResourcesBuildPhase", "PBXShellScriptBuildPhase", "PBXSourcesBuildPhase", "PBXTargetDependency",
    "PBXVariantGroup", "XCBuildConfiguration", "XCConfigurationList",
]


def add_to_section(text, isa, chunk):
    """Appends `chunk` (complete object lines) at the end of section `isa`, creating the section
    in Xcode's alphabetical place when it does not exist yet."""
    end_marker = "/* End %s section */" % isa
    if end_marker in text:
        i = text.index(end_marker)
        return text[:i] + chunk + text[i:]
    later = SECTION_ORDER[SECTION_ORDER.index(isa) + 1:]
    pos = None
    for other in later:
        m = "/* Begin %s section */" % other
        if m in text:
            pos = text.index(m)
            break
    if pos is None:
        pos = text.index("\t};\n\trootObject")
    section = "/* Begin %s section */\n%s/* End %s section */\n\n" % (isa, chunk, isa)
    return text[:pos] + section + text[pos:]


# ---------------------------------------------------------------- build

def main():
    with open(PBX, "r", encoding="utf-8") as f:
        original = f.read()
    tree = parse(original)
    objs = tree["objects"]
    if any(o.get("isa") == "PBXNativeTarget" and o.get("name") == WATCH_TARGET for o in objs.values()):
        raise SystemExit("MagicMakerWatch is already in the project; nothing to do")

    root_id = tree["rootObject"]
    project = objs[root_id]
    main_group = project["mainGroup"]
    products_group = project["productRefGroup"]
    ios_target = next(k for k, o in objs.items()
                      if o.get("isa") == "PBXNativeTarget" and o.get("name") == IOS_TARGET)
    ios = objs[ios_target]
    ios_sources = next(p for p in ios["buildPhases"] if objs[p]["isa"] == "PBXSourcesBuildPhase")
    ios_resources = next(p for p in ios["buildPhases"] if objs[p]["isa"] == "PBXResourcesBuildPhase")
    app_group = next(c for c in objs[main_group]["children"]
                     if objs[c].get("isa") == "PBXGroup" and objs[c].get("path") == "MagicMaker")
    if any(objs[c].get("path") == "Watch" for c in objs[app_group]["children"]):
        raise SystemExit("MagicMaker/Watch group already exists")

    # The iPhone target's values, so the watch app starts in step (the CI sed keeps it so).
    ios_cfgs = [objs[c] for c in objs[ios["buildConfigurationList"]]["buildConfigurations"]]
    def ios_setting(key):
        vals = {c["buildSettings"].get(key) for c in ios_cfgs}
        if len(vals) != 1 or None in vals:
            raise SystemExit("iPhone target %s differs between configurations: %s" % (key, vals))
        return vals.pop()
    marketing = ios_setting("MARKETING_VERSION")
    build = ios_setting("CURRENT_PROJECT_VERSION")
    team = ios_setting("DEVELOPMENT_TEAM")
    ios_bundle = ios_setting("PRODUCT_BUNDLE_IDENTIFIER")

    ID = {
        "product": uid("product:MagicMakerWatch.app"),
        "target": uid("target:MagicMakerWatch"),
        "watchGroup": uid("group:MagicMakerWatch"),
        "phoneGroup": uid("group:Watch"),
        "wSources": uid("phase:watch.sources"),
        "wFrameworks": uid("phase:watch.frameworks"),
        "wResources": uid("phase:watch.resources"),
        "embed": uid("phase:ios.embedWatch"),
        "proxy": uid("proxy:watch"),
        "dep": uid("dep:watch"),
        "cfgList": uid("configlist:watch"),
        "cfgDebug": uid("config:watch.Debug"),
        "cfgRelease": uid("config:watch.Release"),
        "embedFile": uid("buildfile:embed:MagicMakerWatch.app"),
    }

    def ftype(name):
        if name.endswith(".swift"):
            return "sourcecode.swift"
        if name.endswith(".xcassets"):
            return "folder.assetcatalog"
        if name.endswith(".plist"):
            return "text.plist.xml"
        raise SystemExit("unknown file type " + name)

    buildfiles, filerefs = [], []
    ios_src_lines, w_src_lines, w_res_lines = [], [], []
    phone_children, watch_children = [], []

    for name, in_ios, in_watch in IPHONE_FILES:
        ref = uid("fileref:Watch/" + name)
        filerefs.append('\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; path = %s; sourceTree = "<group>"; };\n'
                        % (ref, name, ftype(name), name))
        phone_children.append("%s /* %s */" % (ref, name))
        if in_ios:
            bf = uid("buildfile:ios:Watch/" + name)
            buildfiles.append("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (bf, name, ref, name))
            ios_src_lines.append("%s /* %s in Sources */" % (bf, name))
        if in_watch:
            bf = uid("buildfile:watch:Watch/" + name)
            buildfiles.append("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (bf, name, ref, name))
            w_src_lines.append("%s /* %s in Sources */" % (bf, name))

    for name, phase in WATCH_FILES:
        ref = uid("fileref:MagicMakerWatch/" + name)
        filerefs.append('\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; path = %s; sourceTree = "<group>"; };\n'
                        % (ref, name, ftype(name), name))
        watch_children.append("%s /* %s */" % (ref, name))
        if phase == "none":
            continue
        bf = uid("buildfile:watch:MagicMakerWatch/" + name)
        label = "Sources" if phase == "sources" else "Resources"
        buildfiles.append("\t\t%s /* %s in %s */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (bf, name, label, ref, name))
        (w_src_lines if phase == "sources" else w_res_lines).append("%s /* %s in %s */" % (bf, name, label))

    filerefs.append("\t\t%s /* MagicMakerWatch.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = MagicMakerWatch.app; sourceTree = BUILT_PRODUCTS_DIR; };\n" % ID["product"])
    buildfiles.append("\t\t%s /* MagicMakerWatch.app in Embed Watch Content */ = {isa = PBXBuildFile; fileRef = %s /* MagicMakerWatch.app */; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };\n" % (ID["embedFile"], ID["product"]))

    def lst(lines, indent="\t\t\t\t"):
        return "".join(indent + l + ",\n" for l in lines)

    groups = (
        "\t\t%s /* Watch */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n%s\t\t\t);\n\t\t\tpath = Watch;\n\t\t\tsourceTree = \"<group>\";\n\t\t};\n"
        % (ID["phoneGroup"], lst(phone_children))
        + "\t\t%s /* MagicMakerWatch */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n%s\t\t\t);\n\t\t\tpath = MagicMakerWatch;\n\t\t\tsourceTree = \"<group>\";\n\t\t};\n"
        % (ID["watchGroup"], lst(watch_children))
    )

    proxy = ("\t\t%s /* PBXContainerItemProxy */ = {\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = %s /* Project object */;\n"
             "\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = %s;\n\t\t\tremoteInfo = %s;\n\t\t};\n"
             % (ID["proxy"], root_id, ID["target"], WATCH_TARGET))
    embed = ("\t\t%s /* Embed Watch Content */ = {\n\t\t\tisa = PBXCopyFilesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
             "\t\t\tdstPath = \"$(CONTENTS_FOLDER_PATH)/Watch\";\n\t\t\tdstSubfolderSpec = 16;\n\t\t\tfiles = (\n"
             "\t\t\t\t%s /* MagicMakerWatch.app in Embed Watch Content */,\n\t\t\t);\n\t\t\tname = \"Embed Watch Content\";\n"
             "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n" % (ID["embed"], ID["embedFile"]))
    frameworks = ("\t\t%s /* Frameworks */ = {\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
                  "\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n" % ID["wFrameworks"])
    target = ("\t\t%s /* %s */ = {\n\t\t\tisa = PBXNativeTarget;\n"
              "\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget \"%s\" */;\n"
              "\t\t\tbuildPhases = (\n\t\t\t\t%s /* Sources */,\n\t\t\t\t%s /* Frameworks */,\n\t\t\t\t%s /* Resources */,\n\t\t\t);\n"
              "\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = %s;\n"
              "\t\t\tpackageProductDependencies = (\n\t\t\t);\n\t\t\tproductName = %s;\n"
              "\t\t\tproductReference = %s /* MagicMakerWatch.app */;\n"
              "\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t};\n"
              % (ID["target"], WATCH_TARGET, ID["cfgList"], WATCH_TARGET, ID["wSources"], ID["wFrameworks"],
                 ID["wResources"], WATCH_TARGET, WATCH_TARGET, ID["product"]))
    resources = ("\t\t%s /* Resources */ = {\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
                 "\t\t\tfiles = (\n%s\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n"
                 % (ID["wResources"], lst(w_res_lines)))
    sources = ("\t\t%s /* Sources */ = {\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
               "\t\t\tfiles = (\n%s\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n"
               % (ID["wSources"], lst(w_src_lines)))
    dep = ("\t\t%s /* PBXTargetDependency */ = {\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = %s /* %s */;\n"
           "\t\t\ttargetProxy = %s /* PBXContainerItemProxy */;\n\t\t};\n" % (ID["dep"], ID["target"], WATCH_TARGET, ID["proxy"]))

    def cfg(oid, name):
        s = [
            "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;",
            "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;",
            "CODE_SIGN_STYLE = Automatic;",
            "CURRENT_PROJECT_VERSION = %s;" % build,
            "DEVELOPMENT_TEAM = %s;" % team,
            "ENABLE_DEBUG_DYLIB = NO;",
            "ENABLE_PREVIEWS = NO;",
            "GENERATE_INFOPLIST_FILE = YES;",
            "INFOPLIST_FILE = MagicMakerWatch/Info.plist;",
            "INFOPLIST_KEY_CFBundleDisplayName = MagicMaker;",
            "INFOPLIST_KEY_UISupportedInterfaceOrientations = \"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown\";",
            "INFOPLIST_KEY_WKCompanionAppBundleIdentifier = %s;" % ios_bundle,
            "INFOPLIST_KEY_WKRunsIndependentlyOfCompanionApp = NO;",
            "LD_RUNPATH_SEARCH_PATHS = (\n\t\t\t\t\t\"$(inherited)\",\n\t\t\t\t\t\"@executable_path/Frameworks\",\n\t\t\t\t);",
            "MARKETING_VERSION = %s;" % marketing,
            "PRODUCT_BUNDLE_IDENTIFIER = %s%s;" % (ios_bundle, WATCH_BUNDLE_SUFFIX),
            "PRODUCT_NAME = \"$(TARGET_NAME)\";",
            "SDKROOT = watchos;",
            "SKIP_INSTALL = YES;",
            "SUPPORTED_PLATFORMS = \"watchos watchsimulator\";",
            "SWIFT_VERSION = 5.9;",
            "TARGETED_DEVICE_FAMILY = 4;",
            "WATCHOS_DEPLOYMENT_TARGET = 10.0;",
        ]
        body = "".join("\t\t\t\t" + l + "\n" for l in s)
        return ("\t\t%s /* %s */ = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n%s\t\t\t};\n\t\t\tname = %s;\n\t\t};\n"
                % (oid, name, body, name))

    cfglist = ("\t\t%s /* Build configuration list for PBXNativeTarget \"%s\" */ = {\n\t\t\tisa = XCConfigurationList;\n"
               "\t\t\tbuildConfigurations = (\n\t\t\t\t%s /* Debug */,\n\t\t\t\t%s /* Release */,\n\t\t\t);\n"
               "\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Debug;\n\t\t};\n"
               % (ID["cfgList"], WATCH_TARGET, ID["cfgDebug"], ID["cfgRelease"]))

    text = original
    text = add_to_section(text, "PBXBuildFile", "".join(buildfiles))
    text = add_to_section(text, "PBXContainerItemProxy", proxy)
    text = add_to_section(text, "PBXCopyFilesBuildPhase", embed)
    text = add_to_section(text, "PBXFileReference", "".join(filerefs))
    text = add_to_section(text, "PBXFrameworksBuildPhase", frameworks)
    text = add_to_section(text, "PBXGroup", groups)
    text = add_to_section(text, "PBXNativeTarget", target)
    text = add_to_section(text, "PBXResourcesBuildPhase", resources)
    text = add_to_section(text, "PBXSourcesBuildPhase", sources)
    text = add_to_section(text, "PBXTargetDependency", dep)
    text = add_to_section(text, "XCBuildConfiguration", cfg(ID["cfgDebug"], "Debug") + cfg(ID["cfgRelease"], "Release"))
    text = add_to_section(text, "XCConfigurationList", cfglist)

    # Existing objects: groups, the iPhone target, the project.
    text = insert_in_list(text, main_group, "children", "%s /* MagicMakerWatch */" % ID["watchGroup"], after=app_group)
    text = insert_in_list(text, app_group, "children", "%s /* Watch */" % ID["phoneGroup"])
    text = insert_in_list(text, products_group, "children", "%s /* MagicMakerWatch.app */" % ID["product"])
    for line in ios_src_lines:
        text = insert_in_list(text, ios_sources, "files", line)
    text = insert_in_list(text, ios_target, "buildPhases", "%s /* Embed Watch Content */" % ID["embed"], after=ios_resources)
    s, e = object_block(text, ios_target)
    block = text[s:e].replace("\t\t\tdependencies = (\n\t\t\t);",
                              "\t\t\tdependencies = (\n\t\t\t\t%s /* PBXTargetDependency */,\n\t\t\t);" % ID["dep"])
    if ID["dep"] not in block:
        raise SystemExit("iPhone target dependencies list is not empty; add the dependency by hand")
    text = text[:s] + block + text[e:]
    text = insert_in_list(text, root_id, "targets", "%s /* %s */" % (ID["target"], WATCH_TARGET))
    s, e = object_block(text, root_id)
    block = text[s:e]
    anchor = "\t\t\t\tTargetAttributes = {\n"
    if anchor not in block:
        raise SystemExit("TargetAttributes not found")
    block = block.replace(anchor, anchor + "\t\t\t\t\t%s = {\n\t\t\t\t\t\tCreatedOnToolsVersion = 26.0;\n"
                          "\t\t\t\t\t\tProvisioningStyle = Automatic;\n\t\t\t\t\t};\n" % ID["target"], 1)
    text = text[:s] + block + text[e:]

    verify(original, text, ID, ios_target, ios_bundle)

    if CHECK_ONLY:
        print("check only: verified, nothing written")
        return
    with open(PBX, "r", encoding="utf-8") as f:
        if f.read() != original:
            raise SystemExit("project.pbxproj changed while this ran (another workflow?); run again")
    tmp = PBX + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, PBX)
    print("added %s (%s %s (%s)) to %s" % (WATCH_TARGET, ios_bundle + WATCH_BUNDLE_SUFFIX, marketing, build, PBX))


REF_KEYS = {"fileRef", "children", "files", "buildPhases", "dependencies", "target", "targetProxy",
            "containerPortal", "remoteGlobalIDString", "buildConfigurationList", "buildConfigurations",
            "productReference", "mainGroup", "productRefGroup", "targets"}


def verify(original, text, ID, ios_target, ios_bundle):
    old = parse(original)["objects"]
    tree = parse(text)
    objs = tree["objects"]
    new_ids = set(objs) - set(old)
    hexid = re.compile(r"^[0-9A-F]{24}$")
    bad = [i for i in new_ids if not hexid.match(i)]
    if bad:
        raise SystemExit("new ids not 24-hex: %s" % bad)
    if len(new_ids) != len(set(objs)) - len(set(old)) or not set(old) <= set(objs):
        raise SystemExit("objects lost")
    # Every reference resolves.
    def refs(o):
        for k, v in o.items():
            if k in REF_KEYS:
                for r in (v if isinstance(v, list) else [v]):
                    yield k, r
    for oid, o in objs.items():
        for k, r in refs(o):
            if r not in objs:
                raise SystemExit("%s.%s -> %s does not resolve" % (oid, k, r))
    if tree["rootObject"] not in objs:
        raise SystemExit("rootObject does not resolve")
    # Each file reference in exactly one group (products included).
    owner = {}
    for oid, o in objs.items():
        if o.get("isa") in ("PBXGroup", "PBXVariantGroup"):
            for c in o["children"]:
                owner.setdefault(c, []).append(oid)
    for oid, o in objs.items():
        if o.get("isa") == "PBXFileReference" and len(owner.get(oid, [])) != 1:
            raise SystemExit("file %s (%s) is in %d groups" % (oid, o.get("path"), len(owner.get(oid, []))))
    # Each build file in exactly one phase; no file twice in one target's phase.
    phase_of = {}
    for oid, o in objs.items():
        if "files" in o and o.get("isa", "").endswith("BuildPhase"):
            seen = set()
            for bf in o["files"]:
                phase_of.setdefault(bf, []).append(oid)
                fr = objs[bf]["fileRef"]
                if fr in seen:
                    raise SystemExit("%s twice in phase %s" % (fr, oid))
                seen.add(fr)
    for oid, o in objs.items():
        if o.get("isa") == "PBXBuildFile" and len(phase_of.get(oid, [])) != 1:
            raise SystemExit("build file %s is in %d phases" % (oid, len(phase_of.get(oid, []))))
    # Targets: phases as designed.
    watch = objs[ID["target"]]
    ios = objs[ios_target]
    def phase(t, isa):
        return [p for p in t["buildPhases"] if objs[p]["isa"] == isa]
    def names(p):
        return sorted(objs[objs[bf]["fileRef"]]["path"] for bf in objs[p]["files"])
    w_src = names(phase(watch, "PBXSourcesBuildPhase")[0])
    want = sorted([n for n, ph in WATCH_FILES if ph == "sources"] + [n for n, _, w in IPHONE_FILES if w])
    if w_src != want:
        raise SystemExit("watch Sources %s != %s" % (w_src, want))
    if names(phase(watch, "PBXResourcesBuildPhase")[0]) != ["Assets.xcassets"]:
        raise SystemExit("watch Resources wrong")
    ios_src = names(phase(ios, "PBXSourcesBuildPhase")[0])
    for n, in_ios, _ in IPHONE_FILES:
        if ios_src.count(n) != 1:
            raise SystemExit("%s in iPhone Sources %d times" % (n, ios_src.count(n)))
    for n, _ in WATCH_FILES:
        if n in ios_src and n not in [x for x, _, _ in IPHONE_FILES]:
            raise SystemExit("watch file %s in iPhone Sources" % n)
    embeds = phase(ios, "PBXCopyFilesBuildPhase")
    if len(embeds) != 1 or objs[embeds[0]]["dstSubfolderSpec"] != "16" \
            or objs[embeds[0]]["dstPath"] != "$(CONTENTS_FOLDER_PATH)/Watch" or names(embeds[0]) != ["MagicMakerWatch.app"]:
        raise SystemExit("Embed Watch Content wrong")
    if ios["dependencies"] != [ID["dep"]] or objs[ID["dep"]]["target"] != ID["target"]:
        raise SystemExit("iPhone target dependency wrong")
    for c in objs[watch["buildConfigurationList"]]["buildConfigurations"]:
        bs = objs[c]["buildSettings"]
        if bs["PRODUCT_BUNDLE_IDENTIFIER"] != ios_bundle + WATCH_BUNDLE_SUFFIX or bs["SDKROOT"] != "watchos" \
                or bs["INFOPLIST_KEY_WKCompanionAppBundleIdentifier"] != ios_bundle \
                or bs.get("SKIP_INSTALL") != "YES":
            raise SystemExit("watch build settings wrong")
    # Every MARKETING_VERSION / CURRENT_PROJECT_VERSION line agrees (the CI sed rewrites them all).
    for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        vals = set(re.findall(r"^\s*" + key + r" = \"?([^\";]+)\"?;", text, re.M))
        if len(vals) != 1:
            raise SystemExit("%s values differ: %s" % (key, vals))
    print("verified: %d new objects, every reference resolves" % len(new_ids))


if __name__ == "__main__":
    main()
```
