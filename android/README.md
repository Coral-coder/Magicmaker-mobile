# MagicMaker Android

Native Disney MagicBand+ research tool for Android. Scan, transmit, auto-response, Starlight wand loop, and **iPhone remote control** (WiFi hotspot + BLE GATT relay).

Timing and packet builders ported from [esp32_magicband](https://github.com/xxfunprojectsxx/esp32_magicband).

## Features

- **SCAN** — listen for 0x0183 manufacturer packets, grouped live feed, session logging
- **TX** — preset library (built-ins + learned), vibrate, interrogate
- **WAND** — Starlight color library, loop interval slider
- **AUTO** — auto-response rules
- **RELAY** — standalone, WiFi hotspot (`MagicMaker` / QR pairing), or BLE GATT for iPhone remote
- **LAB** — packet builder, transmission timing (preamble / burst sliders)

## Transmit timing

| Step | Default |
|------|---------|
| Wakeup preamble | 520ms |
| Command burst | 2000ms |
| Standalone ping | 2000ms |
| Starlight wand | 500ms (no band wakeup) |

Band commands prepend wakeup ping automatically.

## iPhone remote (relay)

| Mode | Use |
|------|-----|
| Standalone | Everything on device |
| WiFi / iPhone | Hotspot + HTTP `:8765`, QR on Relay tab |
| BLE GATT / iPhone | GATT service `A7830001`, device name `MagicMaker-Android` |

## Build & deploy

```bash
./tools/deploy.sh
```

Requires USB debugging, JDK 17+, Android SDK. Grant Bluetooth, location, notifications; disable battery optimization for background scan.

## License

See [LICENSE](LICENSE).
