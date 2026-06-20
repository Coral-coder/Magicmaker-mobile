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
