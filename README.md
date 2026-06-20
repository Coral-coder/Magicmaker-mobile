# MagicMaker

Disney MagicBand+ / Starlight wand research tools for **iPhone** and **Android**.

**Monorepo:** https://github.com/Coral-coder/Magicmaker-mobile

```bash
git clone https://github.com/Coral-coder/Magicmaker-mobile.git
```

| Platform | Path | Build |
|----------|------|-------|
| iOS | [`ios/`](ios/) | Open `ios/MagicMaker.xcodeproj` in Xcode — use **Release** scheme on device |
| Android | [`android/`](android/) | `./android/tools/deploy.sh` (USB debugging) |

## Architecture

- **Android** broadcasts Disney `0x0183` BLE manufacturer packets (scan, TX, auto-response, wand loop).
- **iPhone** scans and records; cannot broadcast on stock iOS — controls Android via **WiFi relay** or **BLE GATT** remote.
- Shared logic: packet builders, Starlight color classification, preset catalog, lab builder.

## Quick start

### Android

```bash
cd android
./tools/deploy.sh
```

### iOS

```bash
cd ios
open MagicMaker.xcodeproj
# Product → Scheme → Edit Scheme → Run → Release (Debug crashes on device due to dylib)
./tools/build_device.sh   # optional CLI Release build + install
```

## Handoff

See [`AGENT_HANDOFF.md`](AGENT_HANDOFF.md) for project context and a copy-paste prompt for the next agent.

## License

See `android/LICENSE` (Android). iOS inherits same research/educational use intent.
