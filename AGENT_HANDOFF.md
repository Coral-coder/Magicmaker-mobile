# MagicMaker — Agent Handoff

Use this document (or the prompt block at the bottom) when handing work to a new Cursor agent.

---

## What this is

**MagicMaker** is a pair of mobile apps for Disney park BLE research:

- **Android** (`android/`) — full-featured: BLE scan, transmit, auto-response, Starlight wand TX loop, foreground service, iPhone relay server (WiFi hotspot + BLE GATT).
- **iOS** (`ios/`) — scan/record/library/lab + **remote control of Android** for actual on-air transmit (iOS cannot send manufacturer data on stock devices).

Both apps share packet semantics ported from [esp32_magicband](https://github.com/xxfunprojectsxx/esp32_magicband) (wakeup preamble ~420–520ms, 2s command burst, Starlight wand ~500ms without band wakeup).

---

## Repo layout

```
Magicmaker/
├── ios/                          # SwiftUI + CoreBluetooth
│   ├── MagicMaker/               # App source
│   │   ├── BLE/                  # BleCentral, Android relay clients, BleTransmitter
│   │   ├── Core/                 # Hex, classifier, PacketBuilder, presets
│   │   ├── Data/MagicStore.swift
│   │   ├── ViewModels/AppViewModel.swift
│   │   └── Views/                # Tabs + StarlightWandView, RemoteTab, LaunchBootstrapView
│   ├── MagicMaker.xcodeproj
│   └── tools/build_device.sh     # Release device build validator
├── android/
│   ├── app/src/main/java/com/magicmaker/android/
│   │   ├── ble/                  # BleScanner, BleAdvertiser
│   │   ├── core/                 # MagicTransmitter, PacketBuilder, classifier
│   │   ├── relay/                # RelayGattServer, CatalogSync, WiFi relay
│   │   ├── service/              # MagicMakerForegroundService
│   │   └── ui/                   # MagicMakerScreens, StarlightWandView
│   └── tools/deploy.sh
└── AGENT_HANDOFF.md              # This file
```

---

## Current feature state (as of handoff)

### Done

- Android relay: WiFi (`:8765`) + BLE GATT; iPhone Remote tab links and sends transmit commands.
- Starlight wand UI on both platforms: tap wand to cycle color, **narrow centered color button** below wand (25% width), no hold-to-transmit.
- Wand glow: continuous aura (plusLighter/Plus behind wand) + multiply tint on white parts; **not** three separate blobs; extends tip → ~94% of upper wand height.
- TX loop, lab packet builder expansion, default recording behavior, delete confirmations, Sorcerer Mickey app icon.
- iOS launch hardening: `LaunchBootstrapView`, lazy BLE, Release scheme default, `ENABLE_DEBUG_DYLIB=NO`, `tools/build_device.sh`.

### Known issues / open work

1. **iOS device launch on iOS 27** — user reported dyld/XPC crashes; must run **Release** scheme (Debug links DeveloperToolsSupport). Verify clean install after `./tools/build_device.sh`.
2. **Wand glow tuning** — user iterated heavily; current envelope in `StarlightWandView` (both platforms). May need further length/brightness tweaks without returning to “3 blobs” or “giant glob”.
3. **End-to-end wand color sync** — `wandDisplayColorIndex` on iOS should track Android TX/heard colors when relay linked; verify with two devices.
4. **Untracked legacy remotes** — old repos `Coral-coder/Magicmaker-ios` and `Coral-coder/MagicMaker_Droid` may lag this monorepo; this monorepo is the source of truth after push.

---

## Build & deploy commands

```bash
# Android → USB device
cd android && ./tools/deploy.sh

# iOS Release on connected iPhone
cd ios && ./tools/build_device.sh
# or Xcode: MagicMaker scheme → Run → Release
```

Android needs `ANDROID_HOME`, JDK 17, `adb`. iOS needs Xcode 15+, physical device, signing team.

---

## Key files to read first

| Area | iOS | Android |
|------|-----|---------|
| Wand UI + glow | `ios/MagicMaker/Views/StarlightWandView.swift` | `android/.../ui/StarlightWandView.kt` |
| Remote / relay | `ios/MagicMaker/Views/RemoteTab.swift`, `BLE/AndroidRemoteClient.swift` | `android/.../relay/`, `MagicMakerScreens.kt` |
| Transmit | `ios/MagicMaker/BLE/BleTransmitter.swift` | `android/.../core/MagicTransmitter.kt` |
| App state | `ios/MagicMaker/ViewModels/AppViewModel.swift` | `android/.../service/MagicMakerForegroundService.kt` |
| Launch / crash | `ios/MagicMaker/Views/LaunchBootstrapView.swift`, `MagicMaker.xcodeproj` | — |

---

## Copy-paste prompt for next agent

```
You are taking over MagicMaker — a monorepo with iOS (`ios/`) and Android (`android/`) apps for Disney MagicBand+ / Starlight wand BLE research.

READ FIRST: `AGENT_HANDOFF.md` and skim `ios/MagicMaker/ViewModels/AppViewModel.swift`, `android/.../service/MagicMakerForegroundService.kt`, and both `StarlightWandView` files.

CONTEXT:
- Android broadcasts Disney 0x0183 packets; iPhone scans/records and remotely commands Android via WiFi or BLE GATT relay (stock iOS cannot TX manufacturer data).
- Packet timing follows esp32_magicband: wakeup prelude then command burst; Starlight wand colors are ~500ms without band wakeup.
- Wand tab: tap wand to cycle Starlight color, narrow centered transmit button below wand, continuous glow on upper white wand parts (tip/shaft/glove) — user rejected both “3 blobs” and “giant glob”; current implementation uses overlapping aura envelopes + multiply tint in StarlightWandView on both platforms.

YOUR PRIORITIES (in order):
1. Verify iOS launches on physical device using Release scheme (`ios/tools/build_device.sh`); fix any remaining iOS 27 dyld crashes without re-enabling Debug dylib on device.
2. Verify wand glow looks smooth and long enough (tip through glove, ~94% upper fraction) and wand color sync over Android relay works end-to-end.
3. Keep Android deploy path working: `cd android && ./tools/deploy.sh`.
4. Preserve existing behavior: TX loop, lab builder, auto-response, no WiFi catalog fallback when BLE relay mode selected, delete confirmations.

CONSTRAINTS:
- Minimize diff scope; match existing code style.
- Do not commit secrets. Do not force-push main.
- Deploy Android when UI changes need device verification; iOS requires Xcode Release rebuild on device.
- User device: iPhone “Skyward Sushi” on iOS 27; Android tested on Pixel Fold.

When stuck, read git history in `ios/` and `android/` subdirs and the conversation goals in AGENT_HANDOFF.md known-issues section.
```
