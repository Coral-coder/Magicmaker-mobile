# MagicMaker — Agent Handoff

Use this document (or the **copy-paste prompt** at the bottom) when handing work to a new Cursor agent.

---

## Canonical repo

| What | URL |
|------|-----|
| **Monorepo (source of truth)** | https://github.com/Coral-coder/Magicmaker-mobile |
| iOS-only mirror (legacy) | https://github.com/Coral-coder/Magicmaker-ios |
| Android-only mirror (legacy) | https://github.com/Coral-coder/MagicMaker_Droid |

Clone the monorepo:

```bash
git clone https://github.com/Coral-coder/Magicmaker-mobile.git
cd Magicmaker-mobile
```

**Do all new work in the monorepo.** The separate iOS/Android repos are mirrors; they may drift if only the monorepo is updated.

> Note: `Coral-coder/Magicmaker` (no `-mobile`) is a different project — ESP32 / Home Assistant bridge. Do not confuse them.

---

## What this is

**MagicMaker** is a pair of mobile apps for Disney park BLE research:

- **Android** (`android/`) — BLE scan, transmit, auto-response, Starlight wand TX loop, foreground service, iPhone relay (WiFi hotspot + BLE GATT).
- **iOS** (`ios/`) — scan, record, library, lab + **remote control of Android** for on-air transmit (stock iOS cannot send Disney manufacturer data).

Packet timing is ported from [esp32_magicband](https://github.com/xxfunprojectsxx/esp32_magicband):

| Step | Typical |
|------|---------|
| Wakeup preamble | ~420–520 ms |
| Command burst | 2000 ms |
| Starlight wand color | ~500 ms (no band wakeup) |

---

## Repo layout

```
Magicmaker-mobile/
├── ios/                          # SwiftUI + CoreBluetooth
│   ├── MagicMaker/
│   │   ├── BLE/                  # BleCentral, Android relay clients, BleTransmitter
│   │   ├── Core/                 # Hex, classifier, PacketBuilder, presets
│   │   ├── Data/MagicStore.swift
│   │   ├── ViewModels/AppViewModel.swift
│   │   └── Views/                # Tabs, StarlightWandView, RemoteTab, LaunchBootstrapView
│   ├── MagicMaker.xcodeproj
│   └── tools/build_device.sh     # Release device build + dylib check
├── android/
│   ├── app/src/main/java/com/magicmaker/android/
│   │   ├── ble/                  # BleScanner, BleAdvertiser
│   │   ├── core/                 # MagicTransmitter, PacketBuilder, classifier
│   │   ├── relay/                # RelayGattServer, CatalogSync, WiFi relay
│   │   ├── service/              # MagicMakerForegroundService
│   │   └── ui/                   # MagicMakerScreens, StarlightWandView
│   └── tools/deploy.sh
├── AGENT_HANDOFF.md              # This file
├── README.md
└── tools/publish.sh              # Re-publish helper (gh auth required)
```

---

## Architecture (relay)

```
iPhone (ios)                         Android (android)
────────────                         ─────────────────
Scan / record / library              BLE advertise (0x0183)
Remote tab ──WiFi :8765 or BLE GATT──► ForegroundService TX
Cannot TX on stock iOS               Wand tab TX + loop
```

Relay modes on Android: **Standalone**, **WiFi hotspot** (QR pairing), **BLE GATT** (`MagicMaker-Android`, service `A7830001`).

---

## Current feature state

### Shipped

- Full tab parity: Scan, TX, Wand, Auto, Relay, Lab (both platforms where applicable).
- iPhone → Android remote: transmit, library sync, wand color commands.
- **Wand tab UX:** tap wand to cycle Starlight color; **transmit button = 25% width, centered** below wand (no hold-to-transmit).
- **Wand glow** (both `StarlightWandView` files):
  - **Aura layer** behind wand: `plusLighter` (iOS) / `Plus` (Android), soft blur, spills past wand edges onto dark UI.
  - **Tint layer** on top: `multiply` on white wand parts (screen blend was invisible on white).
  - Single continuous column (two overlapping envelopes), **not** three separate blobs.
  - Clip + envelope: `upperGlowFraction = 0.94`, centerY `0.28`, outer ry `0.30` / inner ry `0.265`.
- TX loop, lab packet builder, delete confirmations, Sorcerer Mickey app icon.
- iOS launch hardening: `LaunchBootstrapView`, lazy BLE init, Release scheme default, `ENABLE_DEBUG_DYLIB=NO`, `tools/build_device.sh`.

### Wand glow — design constraints (read before changing)

The user explicitly rejected:

1. **Giant glob** — full-width capsule / screen wash.
2. **Three visible blobs** — separate tip/shaft/glove circles.

Approach that worked: one tall soft envelope + stronger inner core + multiply tint. Glow must **reach the tip** and extend **~94% down the upper white wand** (not the navy handle/crystal). Further tweaks should adjust envelope `centerY` / `ry` / blur / peak opacity — not add more hotspot circles.

### Open work / verify on device

1. **iOS launch on iOS 27** — user device “Skyward Sushi”; Debug crashes (DeveloperToolsSupport dylib). Always **Release** for device runs; validate with `ios/tools/build_device.sh`.
2. **Wand glow polish** — may still need length/brightness tuning; keep smooth column, not blobs.
3. **Wand color sync E2E** — `wandDisplayColorIndex` on iOS via `AppViewModel` when relay linked; Android updates on TX/heard in `MagicMakerForegroundService`.
4. **Monorepo hygiene** — if you change code, commit to `Magicmaker-mobile`; optionally sync mirrors only if user asks.

---

## Build & deploy

```bash
# Clone (first time)
git clone https://github.com/Coral-coder/Magicmaker-mobile.git && cd Magicmaker-mobile

# Android → USB device (Pixel Fold tested)
cd android && ./tools/deploy.sh

# iOS → connected iPhone (Release only on device)
cd ios && ./tools/build_device.sh
# or: open MagicMaker.xcodeproj → Scheme → Run → Release
```

Requirements: Android — `ANDROID_HOME`, JDK 17, `adb`. iOS — Xcode 15+, physical device, signing team.

---

## Key files

| Area | iOS | Android |
|------|-----|---------|
| Wand UI + glow | `ios/MagicMaker/Views/StarlightWandView.swift` | `android/.../ui/StarlightWandView.kt` |
| Remote / relay | `ios/MagicMaker/Views/RemoteTab.swift`, `BLE/AndroidRemoteClient.swift` | `android/.../relay/`, `ui/MagicMakerScreens.kt` |
| Transmit | `ios/MagicMaker/BLE/BleTransmitter.swift` | `android/.../core/MagicTransmitter.kt` |
| App state | `ios/MagicMaker/ViewModels/AppViewModel.swift` | `android/.../service/MagicMakerForegroundService.kt` |
| Launch / crash | `ios/MagicMaker/Views/LaunchBootstrapView.swift`, `MagicMaker.xcodeproj` | — |
| Persistence | `ios/MagicMaker/Data/MagicStore.swift` | `android/.../data/MagicStore.kt` |

---

## Git workflow

- Branch from `main` on **Magicmaker-mobile**.
- Do not force-push `main`.
- Do not commit secrets (`.env`, credentials, `deploy.local.sh`).
- Android UI changes: `./android/tools/deploy.sh` to verify on device.
- iOS: Release rebuild in Xcode or `./ios/tools/build_device.sh`.

---

## Copy-paste prompt for next agent

```
You are taking over MagicMaker — a GitHub monorepo with iOS (`ios/`) and Android (`android/`) apps for Disney MagicBand+ / Starlight wand BLE research.

REPO: https://github.com/Coral-coder/Magicmaker-mobile
Clone: git clone https://github.com/Coral-coder/Magicmaker-mobile.git

READ FIRST:
- AGENT_HANDOFF.md (full context)
- ios/MagicMaker/ViewModels/AppViewModel.swift
- android/app/src/main/java/com/magicmaker/android/service/MagicMakerForegroundService.kt
- ios/MagicMaker/Views/StarlightWandView.swift
- android/app/src/main/java/com/magicmaker/android/ui/StarlightWandView.kt

ARCHITECTURE:
- Android broadcasts Disney 0x0183 BLE manufacturer data (scan, TX, auto-response, wand loop, foreground service).
- iPhone scans/records and controls Android via WiFi relay (:8765) or BLE GATT — stock iOS cannot TX manufacturer data.
- Timing from esp32_magicband: wakeup prelude ~420–520ms, command burst 2s, Starlight wand ~500ms without band wakeup.

WAND TAB (both platforms):
- Tap wand → cycle Starlight color; narrow centered color button below wand (25% width) → transmit.
- Glow: continuous column (dual aura envelopes + multiply tint), upperGlowFraction 0.94, centerY 0.28 — NOT three blobs, NOT a giant full-width glob. Aura spills past wand edges; tint colors white plastic via multiply.

PRIORITIES:
1. iOS Release device launch on iOS 27 (Skyward Sushi) — fix remaining crashes; never ship Debug dylib on device.
2. Wand glow polish if needed (smooth, tip-to-glove, visible but not blobby) + relay wand color sync E2E.
3. Keep android/tools/deploy.sh working.
4. Preserve: TX loop, lab builder, auto-response, delete confirmations, no WiFi catalog fallback when BLE relay mode selected.

CONSTRAINTS:
- Work in Magicmaker-mobile monorepo only unless user asks to sync legacy mirrors.
- Minimize diff scope; match existing code style.
- Do not force-push main or commit secrets.
- Test Android on device after UI changes; iOS needs Release rebuild.

When stuck: read AGENT_HANDOFF.md open-work section and git log on main.
```
