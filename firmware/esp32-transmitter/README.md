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
  phone; asking the chip to scan is answered `"unsupported"`. Between transmissions it just
  sits idle, waiting for the phone.
- **Battery (Heltec V3):** % left, charge left in mAh and the **expected runtime in hours and
  minutes** on the screen and in STATUS (the app's LINK tab). See **Battery** below.

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
  current), else the `esp32-firmware` release. The repo is public, so that download needs
  no token (`-Token ghp_…` only matters for a private fork).
- **Won't connect?** Heltec V3: hold **PRG**, tap **RST**, release **PRG**, then rerun (if
  you flashed that way, tap **RST** afterwards to start it). Classic ESP32: hold **BOOT**
  while it says `Connecting...`. Close any serial monitor holding the port. Driver: Silicon
  Labs CP210x VCP (Heltec V3, most DevKits) or WCH CH340.
- **Heltec V3:** the screen stays dark to save battery; press **PRG** to light it.
- If PowerShell blocks the script: `Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process`.

**macOS / Linux:** `./flash.sh` does the same (`--board auto|esp32|heltec-v3`, `--port`,
`--bin`, `--baud`, `--token`, `--list-ports`). It needs `python3` and installs esptool 4.8.1
into `.tools/venv` on first run if no esptool is installed.

## Updating

CI (`.github/workflows/esp32-firmware.yml`) builds every firmware change and puts the
latest images in four places:

| Where | What | Used for |
|---|---|---|
| The iPhone app | app images, bundled from `ios/MagicMaker/Firmware/` | Bluetooth update (firmware 1.2+) |
| [Web flasher](https://coral-coder.github.io/Magicmaker-mobile/flasher/) | merged images, from `web/flasher/` | flashing from Chrome / Edge |
| [`esp32-firmware` release](https://github.com/Coral-coder/Magicmaker-mobile/releases/tag/esp32-firmware) | merged + app images, `firmware.json`, `MagicMaker-Flasher-Windows.zip` | downloads |
| This folder | merged images | `flash.ps1` / `flash.sh` |

The **merged** image (`magicmaker-<board>.bin`) is bootloader + partition table + app, flashed
at `0x0`. The **app** image (`magicmaker-<board>-app.bin`) is the same file from `0x10000` on,
which is what an over-the-air update sends. Every image carries the text
`MMFW:<version>:<board>` (board `esp32` or `heltec-v3`), so a tool can read its version;
`firmware.json` lists the version and each board's files, sizes and MD5s.

**From the iPhone app, over Bluetooth** (the board already runs firmware **1.2 or newer**; no
cable):

1. Link the app to the board as usual.
2. Press the board's button once: **PRG** on a Heltec V3, **BOOT** on a classic DevKit. For the
   next **2 minutes** the board accepts an update. Without that press it refuses one, so nobody
   nearby can reflash it.
3. Start the firmware update in the app. It sends the app image it carries for that board;
   the board checks it (MD5, the image's own SHA-256 and chip type) and restarts into it about
   1.5 s after the last byte, and the app relinks. If the update fails or is interrupted, the
   board keeps running its current firmware.

A board on firmware older than 1.2 has no Bluetooth update: flash it once by cable (below).

**From the browser:** [coral-coder.github.io/Magicmaker-mobile/flasher](https://coral-coder.github.io/Magicmaker-mobile/flasher/).
Chrome or Edge on a computer, or Chrome on Android with a USB OTG adapter (Safari and iPhone
browsers can't reach a serial port). Click **Connect**, pick the port, then **Install**: the page
asks the chip what it is and writes the matching merged image (**ESP32 → classic**,
**ESP32-S3 → Heltec V3**), erasing the board first. Same boot-button and driver tips as
**Won't connect?** above. Built with ESP Web Tools; deployed by `.github/workflows/pages.yml`.

**Windows, one click:** download
[`MagicMaker-Flasher-Windows.zip`](https://github.com/Coral-coder/Magicmaker-mobile/releases/download/esp32-firmware/MagicMaker-Flasher-Windows.zip),
unzip it, plug the board in and double-click `flash.bat`. It runs `flash.ps1` (above) with
the two merged images next to it.

**Bluetooth update protocol** (`ota.h`): characteristic `A7830007-0000-1000-8000-00805F9B34FB`
on the relay service, write / write without response / notify; integers little-endian.

| App → board | Payload |
|---|---|
| `01` BEGIN | `[u32 size][16-byte MD5]` of the app image |
| `02` DATA | `[u32 offset][bytes…]`, continuing at the expected offset |
| `03` END | — (board restarts ~1.5 s after an OK) |
| `04` ABORT | — |
| `05` QUERY | — |

The board notifies `[0x80 | op][status][u32 value][text]`. Status 0 = OK; 1 not armed (no
button press in the last 120 s), 2 size, 3 begin, 4 offset, 5 write, 6 verify, 7 state,
8 format. `value` is the next expected offset (BEGIN, DATA, offset errors), the image size (END)
or the seconds left in the armed window (QUERY). QUERY's text is
`MMFW:<version>:<board>;s=<state>;o=<offset>;n=<size>` (state 0 idle, 1 receiving, 2 done,
3 error). During DATA the board acks every 4096 bytes (and on any error), so the app keeps a
bounded window of bytes in flight.

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
- Press again → next page: **STATUS → LAST PACKET → DEVICE → STATUS …** (on DEVICE the page
  turns when you let go).
- On **DEVICE**, **hold PRG for 1 s** → the next battery capacity: 400 → 500 → 1000 → 1100 →
  2000 → 3000 → 5000 → 400 mAh (keep holding to step again every second, at most one round;
  the `CAP` line is highlighted). The choice is saved and survives reboots.
- It goes dark **10 s after the last press** (`SCREEN_ON_MS` at the top of the `.ino`).
- Nothing else lights it: no boot splash, not a phone connecting, not a transmit.
- At runtime PRG is just a button. It only selects flashing mode when held while you tap
  **RST**.

| Page | Shows |
|---|---|
| STATUS | `BLE` LINKED / WAITING FOR PHONE · `TX` IDLE / WAKE / SEND with a progress bar for the current phase · what the chip runs by itself: KEEP AWAKE ON / TX LOOP 3S / WAND LOOP 2.5S / KEEP AWAKE OFF · `PKT` packets sent since boot · the last packet's kind (BAND / WAND / PING / RAW) and how long ago · `BAT` % and expected runtime (`68% ~9H 40M`), or `68% CHARGING` / `100% USB POWER` / `--` |
| LAST PACKET | kind (RAW = a replay step or an MBLE tap), length and stream time (`WAKE+` when a wake ping ran first), then the packet hex, seven bytes a line |
| DEVICE | `BAT` battery voltage and % · `CAP` charge left of the capacity (`272 OF 400MAH`; hold PRG to change the capacity) · `RUN` expected runtime (`~9H 40M LEFT`, `~40M LEFT`, `~99H+ LEFT`) or CHARGING / USB POWER · `UP` uptime · `BLE` name and the last three bytes of its address · `FW` firmware version and board (`--` wherever there is no plausible battery reading) |

The text uses the app's VFD 5×7 dot-matrix face. `vfd_font_5x7.h` is generated from
`tools/vfd/vfd_font.py` by `python3 tools/vfd/gen_c.py` (`--check` tells whether it is
current). Screen code: `oled_ui.h` (power, button), `oled_pages.h` (layout). Battery and LoRa:
`power.h` (hardware), `battery_model.h` (%, charging, runtime; pure C++).

**Power notes**

- Screen off means: display off, I2C stopped and its pins released (nothing back-powers the
  panel through pull-ups), OLED reset held low, and the **Vext rail (GPIO36) switched off**,
  so the panel and the rail draw nothing. `setup()` puts it in that state first thing at boot.
- While lit it redraws at most 4×/s and sends only the 8-pixel rows that changed. Lighting
  it pauses the firmware's main loop for under 0.1 s (panel reset + first frame); a
  transmit in progress at that moment runs that much longer.
- No Wi-Fi. The SX1262 LoRa radio, which this firmware never uses, is **put to sleep at boot**
  (reset, wait until ready, `SetSleep`; its chip select then stays high). Out of power-on it
  would idle in standby at ~0.6 mA. `MM_LORA_SLEEP 0` (top of `power.h`) leaves it alone.

**Battery**

- A LiPo on the battery connector is read on GPIO1 through the board's divider (×4.9, ×1.045
  calibration). The divider is switched on (GPIO37) **only for a reading** (~10 ms) and off
  again straight after: **once a minute while the screen is dark**, every 5 s while it is lit,
  and 0.1 s after boot. A reading waits while a beacon is on air (its transmit bursts dip the
  voltage), at most 10 s.
- The divider switch is active LOW on V3.0/V3.1 and active HIGH on V3.2: the firmware tries
  LOW, then HIGH if that reads ~0 V, and remembers which worked.
- **%** comes from the filtered voltage on a LiPo resting-voltage curve (rough; it reads high
  while charging). **Charge left** = capacity × %. The capacity is `BATTERY_MAH` (400 mAh) until
  you pick another on the DEVICE page (hold PRG); that choice is the only thing the firmware
  ever writes to flash, and only when you change it.
- **Expected runtime** = charge left ÷ estimated draw. The board cannot measure its current,
  only the voltage, so the estimate starts from a **model**: a ~15-minute time-weighted average
  of per-state draws (`DRAW_*` at the top of `battery_model.h`: base, advertising, phone
  linked, beacon on air, screen lit). Once the battery has visibly drained (≥ 2 % over ≥ 20 min,
  counted from 10 min after boot or charging), the **measured** drain takes over: the % slope
  over the last hour (or since the discharge began, for big cells), smoothed, and kept within
  0.5–2.5× the model, because the flat middle of a LiPo curve makes single slopes noisy.
- **Charging** = the voltage rose ≥ 15 mV within 5 min (it ends when the voltage falls 10 mV
  from its peak, i.e. unplugged); **USB POWER** = above 4.25 V. Neither shows a runtime. On USB
  with a full, idle cell the voltage looks like a resting battery, so the screen then shows a
  runtime as if on battery: the board has no USB-sense pin.
- **Tune the model with a USB meter** (battery unplugged, board on the meter): the screen-dark,
  no-phone, nothing-on-air reading is `DRAW_BASE_MA + DRAW_ADV_MA`; link a phone, start
  keep-awake and light the screen one at a time to see what each adds. Until then the runtime
  is only as good as the seed `DRAW_BASE_MA` (37.5 mA) for the first half hour.
- Without a battery the screen shows `--` (or the charger's output voltage, as USB POWER).

## Power (backpack use)

The board sits idle between transmissions and does what it can to save battery. Each measure,
honestly:

- **CPU at 80 MHz** (about half the draw of 240 MHz). This is the floor: BLE needs the 80 MHz
  APB clock.
- **The Disney beacon is on air only while something is being sent** (a tap, a replay step,
  a loop burst, the keep-awake stream), and only then at full power (the app's TX power
  setting, +9 dBm by default).
- **Waiting for a phone:** connectable advertising at **+3 dBm**, every 200–400 ms for 30 s
  after boot or after a phone leaves (quick relink), then every **546–760 ms** (Apple's
  recommended intervals).
- **Linked:** the link runs at **+3 dBm** with a 30–50 ms connection interval and slave latency
  2, so the radio idles between events. (A longer latency would save ~0.3 mA but add up to
  ~0.2 s to every tap.)
- **`loop()` sleeps until its next deadline** (a phase end, a loop burst, an LED blink, a
  battery reading, the screen; at most 5 s) and is woken early by a command, a
  connect/disconnect or PRG. It does not poll.
- **Heltec V3:** the LoRa radio is asleep (~0.6 mA saved, check with a meter), the OLED and its
  Vext rail are unpowered unless you use PRG, and the battery divider is on for ~10 ms a
  minute. The LED only blinks.
- **No Wi-Fi, nothing written to flash** (except a battery capacity you pick on the screen).

What it can't do in this core (Arduino-ESP32 2.0.17):

- **No automatic light sleep:** `CONFIG_PM_ENABLE` is off in the prebuilt core, so the CPU wakes
  for every 1 ms FreeRTOS tick. Manual light sleep would drop the BLE link.
- **ESP32-S3 (Heltec V3): no BLE modem sleep** either (compiled out of this core's S3
  controller), so the radio's clocks stay up between events. Expect roughly **30–45 mA idle**
  (estimate; measure yours), i.e. about **9–13 h on a 400 mAh cell**. The screen shows the live
  estimate.
- The **classic ESP32** does use BLE modem sleep between radio events; its datasheet figures
  for modem sleep at 80 MHz are ~20–30 mA. It has no battery reader.

For longer runtime: a bigger cell, fewer loops/keep-awake (the beacon is the biggest extra), or
a lower beacon power in the app (shorter range).

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
| `IDLE_ADV_SLOW_MIN/MAX` | … after `IDLE_FAST_WINDOW_MS` | 546.25–760 ms |
| `IDLE_FAST_WINDOW_MS` | fast idle advertising after boot / a disconnect | 30 s |
| `IDLE_ADV_POWER` | TX power while waiting for a phone | +3 dBm |
| `LINK_POWER` | TX power of the link to the phone (BLE default power); raise to `P9` if it drops at range | +3 dBm |
| `LED_MIN_FLASH_GAP_MS` | at most one transmit flash per this long (dense replays still blink) | 250 ms |
| `LOOP_MAX_SLEEP_MS` | longest `loop()` sleep between deadlines (all deadlines are tracked; a safety net) | 5000 ms |
| `SCREEN_ON_MS` | Heltec V3: how long the screen stays lit after the last PRG press | 10 s |
| `BATTERY_MAH` | Heltec V3: LiPo capacity until one is picked on the screen (STATUS `batMah`) | 400 mAh |

The wire clamps (TX-characteristic duration 60–12000 ms, `raw_burst` 60–10000 ms, loop interval
500–60000 ms, setting ranges) are part of the relay contract and live in `relay_proto.h`.
Screen internals (frame rate, long press, panel reset timing) are at the top of `oled_ui.h`;
battery timing (reading periods, capacity presets) and `MM_LORA_SLEEP` at the top of
`power.h`; the per-state draw estimates (`DRAW_*`) and the runtime model at the top of
`battery_model.h`.

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
| OTA | `A7830007-…` | write, write without response, notify | firmware update over Bluetooth (1.2+); see **Updating** and `ota.h` |

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
| `batMv`, `batPct`, `batMah` | Heltec V3 with a plausible reading | filtered battery mV, %, capacity (mAh) |
| `runMin` / `charging` | with the battery keys | expected runtime in minutes / `true` while charging or on USB power (then no `runMin`) |
| `items` | after a catalog action | `[]` |
| `keepAwakeHex` | KEEP AWAKE runs | the streamed packet |
| `txLoopHex`, `txLoopLabel` | TX LOOP runs | its packet and label (label dropped first if the object would exceed 508 bytes) |
| `starlightLoopHex`, `starlightLoopLabel` | WAND LOOP runs | same |

Example (idle, Heltec):

```
{"ok":true,"running":true,"proto":2,"fw":"1.2","board":"HELTEC V3","keepAwake":false,"wakeupPreambleMs":520,"commandBurstMs":4000,"starlightBurstMs":500,"txPowerLevel":3,"txInterleave":false,"uptimeS":8123,"sent":42,"batMv":3921,"batPct":68,"batMah":400,"runMin":431}
```

**Advertising.** Waiting for a phone: flags + service UUID, name `MM_ESP` in the scan response,
+3 dBm. While a packet is on air: manufacturer data only, connectable, 20–30 ms, at the app's
beacon power; with no phone linked
its scan response carries `MM_ESP` + the service UUID, so the app can find the board and relink
during a keep-awake stream or a loop. Linked and idle: not advertising.
