# MagicMaker ESP32 transmitter

Turns any ESP32 into a **BLE transmitter** for the MagicMaker app so your **phone keeps
scanning** while the ESP32 does the broadcasting. Drop it in your backpack on a battery;
the phone connects over Bluetooth and tells it what to send.

It implements the app's existing **relay GATT contract**, so nothing in the app's wire
protocol has to change — the app already knows how to drive this service.

## What it does

- Advertises a BLE service the app recognizes (`A7830001-…`, name `MM_ESP`; older firmware used `MagicMaker-ESP32`).
- The phone connects and **writes `"{hex}|{durationMs}"`** to the TX characteristic.
- The ESP32 broadcasts that packet as **Disney manufacturer data (company `0x0183`)**,
  using the same **wake-ping → command** timing the phone's own transmitter uses, so bands
  actually react (Starlight wand codes and pings are a single burst, no wakeup).
- A newer write **preempts** an in-flight burst (a fresh tap wins), matching the app.
- **Chip-side toggles** (firmware 1.2): **keep-awake**, the **TX loop** and the **wand loop** run
  on the chip itself, one at a time, and keep running when the phone disconnects, is locked or
  the app is closed. The app sends the packet (hex + label) and the interval; the chip times the
  bursts. Turning one on turns the others off. They live in RAM only: the board always boots
  idle, and the app reads back what is running when it links.
- **Chip settings**: wake preamble, command burst, wand burst, TX power and interleave mode.
  RAM only; the app pushes its values every time it links (the iPhone is the authority).
- **The chip never scans.** Scanning, logging, auto-responses and the library stay on the
  phone; asking the chip to scan is answered `"unsupported"`.

## Hardware

- Any ESP32 (classic, S3, C3, …). No extra parts. Onboard LED = status, blinks only: a short
  blink every second while waiting for a phone, every 5 s while linked, and one flash per
  transmission (at most one per 250 ms).
- **Heltec WiFi LoRa 32 V3 / V3.1 / V3.2**: the same relay plus its OLED screen, lit with
  the PRG button. See **Heltec WiFi LoRa 32 V3** below.
- Powered from USB or a LiPo. See **Power** below.

## Flashing (Windows)

No toolchain needed: CI builds the firmware for both supported boards and commits one
merged image per board next to the flasher (also attached to the `esp32-firmware` release).

| Board | Image | Chip |
|---|---|---|
| Classic ESP32 (DevKit / WROOM / WROVER) | `magicmaker-esp32.bin` | ESP32, 4 MB flash |
| Heltec WiFi LoRa 32 V3 / V3.1 / V3.2 | `magicmaker-heltec-v3.bin` | ESP32-S3, 8 MB flash |

In PowerShell, in this folder:

```powershell
./flash.ps1                     # find the COM port, detect the board, flash the matching image
./flash.ps1 -Board heltec-v3    # skip detection and name the board (or -Board esp32)
./flash.ps1 -ListPorts          # just list COM ports
./flash.ps1 -Port COM5          # force the port
./flash.ps1 -Bin .\my.bin       # flash a local merged image instead of the prebuilt one
./flash.ps1 -Baud 460800        # slower upload if 921600 is flaky
```

- **Auto-detect (`-Board auto`, the default):** after picking the port (USB-serial bridges
  such as the Heltec's CP2102 are preferred) it asks the chip what it is with esptool,
  read-only, and picks the image: **ESP32-S3 → Heltec V3**, **classic ESP32 → classic**.
  Other chips (S2, C3, C6, H2, …) are refused with a message naming the chip. Before
  writing it also checks the image header matches the board, so the wrong `.bin` can't be
  flashed.
- **esptool:** uses one on PATH or in Python if present and v4 or newer, otherwise downloads
  the standalone esptool v4.8.1 into `.tools/` once (no Python needed).
- **Which image file:** `-Bin`, else the `.bin` committed here (`git pull` keeps it
  current), else the `esp32-firmware` release. The repo is private, so for the download
  pass `-Token ghp_…` (repo read scope) or download the asset in a browser and use `-Bin`.
- **Won't connect?** Heltec V3: hold **PRG**, tap **RST**, release **PRG**, then rerun (if
  you flashed that way, tap **RST** afterwards to start it). Classic ESP32: hold **BOOT**
  while it says `Connecting...`. Close any serial monitor holding the port. Driver: Silicon
  Labs CP210x VCP (Heltec V3, most DevKits) or WCH CH340.
- **Heltec V3:** the screen stays dark to save battery; press **PRG** to light it.
- If PowerShell blocks the script: `Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process`.

**macOS / Linux:** `./flash.sh` does the same (`--board auto|esp32|heltec-v3`, `--port`,
`--bin`, `--baud`, `--token`, `--list-ports`). It needs `python3` and installs esptool 4.8.1
into `.tools/venv` on first run if no esptool is installed.

## Build & flash (Arduino IDE)

1. Install the ESP32 board support (Boards Manager → "esp32" by Espressif; CI uses 2.0.17).
2. Install the library: **Tools → Manage Libraries → "NimBLE-Arduino"** (h2zero), version
   **1.4.x** (CI uses 1.4.3; pick it in the version list, 2.x won't compile).
   For the Heltec V3 also install **"U8g2"** (olikraus) for the OLED.
3. Open `esp32-transmitter.ino`, select your ESP32 board + port, **Upload**. For the
   Heltec, pick **Heltec WiFi LoRa 32(V3)**; the sketch detects it and enables the screen.

No secrets, no Wi-Fi, no config. It just works once flashed.

> Prefer PlatformIO? `platformio.ini` with `framework = arduino`,
> `lib_deps = h2zero/NimBLE-Arduino@^1.4.1`, and `src_dir` set to this folder (or copy the
> `.ino` to `src/main.cpp` together with the `.h` files next to it).
> Heltec V3: `board = heltec_wifi_lora_32_V3` and add `olikraus/U8g2@2.35.30` to `lib_deps`.

## Use it with the app

In the app, choose the **ESP32 transmitter** backend (Remote/Relay settings). The app
finds the ESP32 by its service UUID and links automatically — then every transmit is sent
to the ESP32 instead of the phone advertising, so the phone stays free to scan.

## Heltec WiFi LoRa 32 V3

The Heltec build is the same relay (same name, UUIDs, timing, keep-awake, newest-wins)
plus the onboard 0.96" OLED. The white LED (GPIO35) is the status LED, as on other boards.
The sketch detects the board when it is compiled (`board.h`); no build flags needed.

**The screen is off and unpowered unless you are using it.**

- Press **PRG** → the screen lights on the **STATUS** page.
- Press again → next page: **STATUS → LAST PACKET → DEVICE → STATUS …**
- It goes dark **10 s after the last press** (`SCREEN_ON_MS` at the top of the `.ino`).
- Nothing else lights it: no boot splash, not a phone connecting, not a transmit.
- At runtime PRG is just a button. It only selects flashing mode when held while you tap
  **RST**.

| Page | Shows |
|---|---|
| STATUS | `BLE` LINKED / WAITING FOR PHONE · `TX` IDLE / WAKE / SEND with a progress bar for the current phase · what the chip runs by itself: KEEP AWAKE ON / TX LOOP 3S / WAND LOOP 2.5S / KEEP AWAKE OFF · `PKT` packets sent since boot · the last packet's kind (BAND / WAND / PING / RAW) and how long ago |
| LAST PACKET | kind (RAW = a replay step or an MBLE tap), length and stream time (`WAKE+` when a wake ping ran first), then the packet hex, seven bytes a line |
| DEVICE | `BAT` battery voltage and % (`--` without a plausible reading) · `UP` uptime · `BLE` name and the last three bytes of its address · `FW` firmware version and board |

The text uses the app's VFD 5×7 dot-matrix face. `vfd_font_5x7.h` is generated from
`tools/vfd/vfd_font.py` by `python3 tools/vfd/gen_c.py` (`--check` tells whether it is
current). Screen code: `oled_ui.h` (power, button, battery), `oled_pages.h` (layout).

**Power notes**

- Screen off means: display off, I2C stopped and its pins released (nothing back-powers the
  panel through pull-ups), OLED reset held low, and the **Vext rail (GPIO36) switched off**,
  so the panel and the rail draw nothing. `setup()` puts it in that state first thing at boot.
- While lit it redraws at most 4×/s and sends only the 8-pixel rows that changed. Lighting
  it pauses the firmware's main loop for under 0.1 s (panel reset + first frame); a
  transmit in progress at that moment runs that much longer.
- No Wi-Fi. The SX1262 LoRa radio is never initialised (left in its power-on state).
- CPU stays at 80 MHz and advertising is unchanged, as on other boards.

**Battery**

- A LiPo on the battery connector is read on GPIO1 through the board's divider (×4.9, ×1.045
  calibration). The divider is switched on (GPIO37) only for a reading, **only while the
  screen is lit, at most every 5 s**, and switched off again straight after.
- The divider switch is active LOW on V3.0/V3.1 and active HIGH on V3.2: the firmware tries
  LOW, then HIGH if that reads ~0 V, and remembers which worked.
- The % is a rough LiPo resting-voltage estimate; it reads high while charging. Without a
  battery it shows `--` or the charger's output voltage.

## Power (backpack use)

Tuned to sip battery:

- CPU throttled to **80 MHz** (~half the draw of 240 MHz; still ample for BLE).
- The **Disney beacon is only on air during a transmit burst** — the rest of the time the
  radio is nearly idle.
- Idle-connectable advertising is **relaxed (200–400 ms)** for 30 s after boot or after a phone
  leaves, then **slows to ~1–1.3 s**; a linked connection requests a **30–50 ms interval with
  latency**, so the radio mostly idles between events.
- `loop()` **sleeps until its next deadline** (a phase end, a loop burst, an LED blink, the
  screen) and is woken early by a command, a connect/disconnect or PRG; it no longer polls.

Rough idle draw is a few mA on a bare module; a small LiPo lasts a full park day. For even
longer runtime, drop `NimBLEDevice::setPower()` from `P9` to a lower level (shorter range),
and remove the status-LED writes.

## Tuning (top of the `.ino`)

| Constant | Meaning | Default |
|---|---|---|
| `DEFAULT_WAKE_MS` | wake-ping stream before a band command (chip setting at boot; the app's value replaces it) | 520 ms |
| `DEFAULT_CMD_MS` | band command stream (a duration written with the packet overrides it) | 4000 ms |
| `DEFAULT_STAR_MS` | wand burst | 500 ms |
| `PING_MS` | standalone ping burst | 2000 ms |
| `DEFAULT_POWER_LEVEL` | beacon power 0..3 = −12 / −6 / 0 / +9 dBm | 3 |
| `LOOP_DEFAULT_MS` | TX / wand loop interval until the app sends one | 3000 ms |
| `BEACON_ADV_MIN/MAX` | advertising interval during a burst (lower = stronger/quicker) | 20–30 ms |
| `IDLE_ADV_FAST_MIN/MAX` | advertising interval while waiting for a phone, first 30 s | 200–400 ms |
| `IDLE_ADV_SLOW_MIN/MAX` | … after `IDLE_FAST_WINDOW_MS` | 1022.5–1285 ms |
| `IDLE_FAST_WINDOW_MS` | fast idle advertising after boot / a disconnect | 30 s |
| `LED_MIN_FLASH_GAP_MS` | at most one transmit flash per this long (dense replays still blink) | 250 ms |
| `LOOP_MAX_SLEEP_MS` | longest `loop()` sleep between deadlines | 1000 ms |
| `SCREEN_ON_MS` | Heltec V3: how long the screen stays lit after the last PRG press | 10 s |
| `BATTERY_MAH` | Heltec V3: rated LiPo capacity (STATUS `batMah`) | 400 mAh |

The wire clamps (TX-characteristic duration 60–12000 ms, `raw_burst` 60–10000 ms, loop interval
500–60000 ms, setting ranges) are part of the relay contract and live in `relay_proto.h`.
Screen internals (frame rate, battery period, panel reset timing) are at the top of
`oled_ui.h`.

## Protocol reference

Mirrors `RelayProtocol` / `RelayCommands` (Android) and `AndroidRelayGattClient` (iOS). Code:
`relay_proto.h` (parsing, STATUS), `relay_engine.h` (jobs and programs), the `.ino` (BLE,
advertising, LED, screen).

| Characteristic | UUID | Access | Payload |
|---|---|---|---|
| Service | `A7830001-0000-1000-8000-00805F9B34FB` | — | — |
| TX | `A7830002-…` | write | `"{hex}\|{durationMs}"` |
| Command | `A7830003-…` | write | `{"action":…}` JSON (below) |
| Status | `A7830004-…` | read | one JSON object: the last command's reply + the chip's state |
| Catalog | `A7830005-…` | read | `{"ok":true,"items":[]}` (empty; library lives on the phone) |

**TX characteristic.** Split at the last `|`; invalid hex → the write is ignored. Hex: non-hex
characters skipped, `83 01` put in front when missing, 3–29 bytes. `ms` 0 / absent / not a
number → the kind's default; otherwise clamped to 60–12000. It is a user send (newest wins):
band → wake ping (`wakeupPreambleMs`) then the command for `ms` (interleave: 1:1 slices over a
window of `ms`; under keep-awake: the command alone for `ms`); wand / ping → one burst of `ms`.

**Commands.** `action` is case-insensitive; Android's aliases work. Values: booleans
`true`/`false`, integers as numbers (quoted digits accepted). Every reply is merged into the next
STATUS read: `ok`, plus `error` when it failed.

| Action (aliases) | Params | ESP32 |
|---|---|---|
| `transmit` (`tx`) | `hex` | user send, chip timing (band `commandBurstMs`, wand `starlightBurstMs`, ping 2000 ms) |
| `vibrate` (`vib`) | — | the band Vibrate command as a user send |
| `interrogate` (`ping`, `wakeup`) | — | `8301CC03000100` for 2000 ms |
| `keep_awake` (`keepawake`) | `enabled` (false), `hex` | program KEEP AWAKE: streams `hex` (≥4 bytes, else the stored one; default the wake ping) whenever nothing else is on air; band sends skip the wake phase |
| `set_tx_loop` (`tx_loop`, `repeat_tx`) | `enabled` (false), `hex`, `label`, `intervalMs` | program TX LOOP: one burst every `intervalMs` (500–60000, kept when absent, 3000 at boot) after the previous one ends; first burst at once. `hex`/`label` stored when given; on without any hex ever → `"no packet"`; `packetId` ignored |
| `set_starlight_loop` (`wand_loop`) | same | program WAND LOOP, same rules |
| `set_wakeup_preamble` (`preamble`) | `ms` / `preambleMs` (520) | 100–3000 |
| `set_command_burst` (`command_burst`, `burst`) | `ms` / `burstMs` (2000) | 500–12000 |
| `set_starlight_burst` (`starlight_burst`, `wand_burst`) | `ms` / `burstMs` (500) | 250–5000 |
| `set_tx_power` (`tx_power`) | `level` (3) | 0–3 = beacon −12 / −6 / 0 / +9 dBm |
| `set_tx_interleave` (`tx_interleave`) | `enabled` (false) | band sends as 1:1 wake/command slices |
| `raw_burst` (`replay_burst`) | `hex`, `durationMs` (500) | the packet alone for exactly 60–10000 ms; waits (1 deep, newest replaces) behind a `raw_burst` on air, otherwise preempts |
| `mble_tap` (`mble`, `tap`) | `token`, `durationMs` (5000) | MBLE beacon (`83 01 0F 11 73 93` + 14-byte token body + power) for 60–10000 ms; preempts; < 4 hex digits → `"bad token"` |
| `set_scan` (`scan`), `set_auto` (`auto`), `set_recording` (`record`, `log`) | `enabled` | `false` → ok (no-op); otherwise `"unsupported"` (the chip never scans) |
| `clear_live` (`clear`), `live`, `status` | — | ok |
| `catalog`, `catalog_sync_begin`/`_chunk` (+ aliases) | — | ok + `"items":[]` |
| library, auto-rule, scan-filter, live-feed edits, `pairing` | — | `"unsupported"` |
| anything else | — | `"unknown action"` |

Errors: `bad json`, `bad hex`, `packet too long`, `no packet`, `bad token`, `unsupported`,
`unknown action`, `busy` (command queue full). Programs: at most one runs; turning one on turns
the others off (a loop burst on air finishes first; a keep-awake stream stops at once). A user
send or MBLE tap preempts anything; a preempted loop burst re-arms one interval after the job
that replaced it. Disconnects change nothing; nothing is stored in flash.

**STATUS** (one object, ≤ 508 bytes, keys in this order):

| Key | When | Meaning |
|---|---|---|
| `ok`, `error` | always / on failure | the last command's reply (reset to ok on connect) |
| `running` | always (`true`) | marks a real status (firmware before 1.2 sent a bare `{"ok":true}`) |
| `proto`, `fw`, `board` | always | `2`, `"1.2"`, `"HELTEC V3"` / `"ESP32"` |
| `keepAwake` | always | KEEP AWAKE runs |
| `txLoopEnabled`, `txLoopIntervalMs` | TX LOOP runs | |
| `starlightLoopEnabled`, `starlightIntervalMs` | WAND LOOP runs | |
| `wakeupPreambleMs`, `commandBurstMs`, `starlightBurstMs`, `txPowerLevel`, `txInterleave` | always | chip settings |
| `uptimeS`, `sent` | always | seconds since boot, jobs put on air since boot |
| `batMv`, `batPct`, `batMah` | Heltec V3 with a plausible, recent reading | battery |
| `runMin` / `charging` | with the battery keys | runtime estimate in minutes (omitted while unknown) / `true` while charging |
| `items` | after a catalog action | `[]` |
| `keepAwakeHex` | KEEP AWAKE runs | the streamed packet |
| `txLoopHex`, `txLoopLabel` | TX LOOP runs | its packet and label (label dropped first if the object would exceed 508 bytes) |
| `starlightLoopHex`, `starlightLoopLabel` | WAND LOOP runs | same |

Example (idle, Heltec):

```
{"ok":true,"running":true,"proto":2,"fw":"1.2","board":"HELTEC V3","keepAwake":false,"wakeupPreambleMs":520,"commandBurstMs":4000,"starlightBurstMs":500,"txPowerLevel":3,"txInterleave":false,"uptimeS":8123,"sent":42,"batMv":3921,"batPct":68,"batMah":400,"runMin":431}
```

**Advertising.** Waiting for a phone: flags + service UUID, name `MM_ESP` in the scan response.
While a packet is on air: manufacturer data only, connectable, 20–30 ms; with no phone linked
its scan response carries `MM_ESP` + the service UUID, so the app can find the board and relink
during a keep-awake stream or a loop. Linked and idle: not advertising.
