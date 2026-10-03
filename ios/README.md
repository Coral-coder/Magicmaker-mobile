# MagicMaker iOS

iPhone port of MagicMaker — Disney `0x0183` BLE scan, record, replay, presets, and auto-response.

## Get the project (any Mac)

```bash
git clone https://github.com/Coral-coder/Magicmaker-ios.git
cd Magicmaker-ios
open MagicMaker.xcodeproj
```

## Requirements

- Mac with **Xcode 15+**
- Physical iPhone (BLE does not work in Simulator)
- Apple Developer account for device install (free account OK for personal use)

## Open & run

After cloning (see above), or if you already have the folder:

```bash
cd Magicmaker-ios
open MagicMaker.xcodeproj
```

The repo includes a ready-to-open **Xcode project** (`MagicMaker.xcodeproj`). You do not need XcodeGen.

If you change source files and need to refresh the project file:

```bash
python3 tools/generate_xcode_project.py
```

1. Select your **iPhone** as the run destination (not Simulator — BLE requires a real device)  
2. **Signing & Capabilities** → enable your team  
3. Add capability **Background Modes** → **Uses Bluetooth LE accessories** (central + peripheral)  
4. Run — grant Bluetooth when prompted  

## TestFlight from GitHub Actions

`.github/workflows/ios-testflight.yml` archives the app (bundle ID `com.lightwave.MMIOS`)
and uploads it to TestFlight. Pushes to `main` are controlled by markers in the commit message:

| Commit message | What happens |
| --- | --- |
| no marker | nothing |
| contains `*b` | archive and sign only, as a check; nothing is uploaded |
| contains `*u` | archive and upload to TestFlight: same version, build number plus one |

- **New version:** put `*u` in the commit message, tag the commit and push both:
  `git tag v1.4.0 && git push origin main v1.4.0`. That uploads 1.4.0, build 1.
- **By hand:** **Actions → iOS TestFlight → Run workflow** always uploads. Its version and
  build fields are optional overrides.

The current version and build are `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
`MagicMaker.xcodeproj/project.pbxproj` (mirrored in `project.yml`); after each upload the
workflow commits the numbers it used. The build number is also checked against App Store
Connect (`tools/next_build_number.py`), so a build uploaded by hand from Xcode never collides.

Signing is automatic: the App Store Connect API key lets Xcode create and use the distribution
certificate and profiles. The secrets (`APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`,
`ASC_KEY_P8`, and optionally `DEV_CERT_P12` / `DEV_CERT_PASSWORD`) are the same ones the ePTT
repo uses; copy them here with its **Actions → Share secrets** workflow (repos:
`Magicmaker-mobile`). The app record for `com.lightwave.MMIOS` must exist in App Store
Connect before the first upload.

## Park checklist

- Enable **Scan** or **Auto** (persistent “Listening” banner while active)  
- Settings → MagicMaker → **Background App Refresh** ON  
- Disable Low Power Mode while using auto-response  
- iOS may throttle BLE more than Android when locked — keep the app in foreground when possible for best results  

## Parity with Android

| Feature | iOS |
|--------|-----|
| Scan / record Disney packets | Yes |
| Colors library (starlight) | Yes |
| Show / animation presets | Yes |
| Auto-response rules | Yes |
| Replay / transmit | Yes |
| Wakeup before show/anim | Yes |
| CSV scan sessions | Yes |
| Locked-screen reliability | Good, not identical to Android FGS |

## Project layout

- `MagicMaker/Core/` — hex, classifier, presets (shared logic with Android)  
- `MagicMaker/BLE/` — Core Bluetooth central + peripheral  
- `MagicMaker/Data/` — `MagicStore` persistence  
- `MagicMaker/Views/` — SwiftUI tabs  
