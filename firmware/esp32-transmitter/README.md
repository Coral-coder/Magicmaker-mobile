# MagicMaker ESP32 transmitter

Turns any ESP32 into a **BLE transmitter** for the MagicMaker app so your **phone keeps
scanning** while the ESP32 does the broadcasting. Drop it in your backpack on a battery;
the phone connects over Bluetooth and tells it what to send.

It implements the app's existing **relay GATT contract**, so nothing in the app's wire
protocol has to change — the app already knows how to drive this service.

## What it does

- Advertises a BLE service the app recognizes (`A7830001-…`, name `MagicMaker-ESP32`).
- The phone connects and **writes `"{hex}|{durationMs}"`** to the TX characteristic.
- The ESP32 broadcasts that packet as **Disney manufacturer data (company `0x0183`)**,
  using the same **wake-ping → command** timing the phone's own transmitter uses, so bands
  actually react (Starlight wand codes and pings are a single burst, no wakeup).
- A newer write **preempts** an in-flight burst (a fresh tap wins), matching the app.

## Hardware

- Any ESP32 (classic, S3, C3, …). No extra parts. Onboard LED = status
  (on while connected / transmitting).
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
- **esptool:** uses one on PATH or in Python if present, otherwise downloads the standalone
  esptool v4.8.1 into `.tools/` once (no Python needed).
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
2. Install the library: **Tools → Manage Libraries → "NimBLE-Arduino"** (h2zero), ≥ 1.4.0.
   For the Heltec V3 also install **"U8g2"** (olikraus) for the OLED.
3. Open `esp32-transmitter.ino`, select your ESP32 board + port, **Upload**. For the
   Heltec, pick **Heltec WiFi LoRa 32(V3)**; the sketch detects it and enables the screen.

No secrets, no Wi-Fi, no config. It just works once flashed.

> Prefer PlatformIO? `platformio.ini` with `framework = arduino`,
> `lib_deps = h2zero/NimBLE-Arduino@^1.4.1`, and build this `.ino` as `src/main.cpp`.
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
| STATUS | `BLE` LINKED / WAITING FOR PHONE · `TX` IDLE / WAKE / SEND with a progress bar for the current phase · KEEP AWAKE ON / OFF · `PKT` packets sent since boot · the last packet's kind (BAND / WAND / PING) and how long ago |
| LAST PACKET | kind, length and stream time (`WAKE+` when a wake ping ran first), then the packet hex, seven bytes a line |
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
- Idle-connectable advertising is **relaxed (200–400 ms)**; a linked connection requests a
  **30–50 ms interval with latency**, so the ESP32 mostly sleeps between events (BLE modem
  sleep).

Rough idle draw is a few mA on a bare module; a small LiPo lasts a full park day. For even
longer runtime, drop `NimBLEDevice::setPower()` from `P9` to a lower level (shorter range),
and remove the status-LED writes.

## Tuning (top of the `.ino`)

| Constant | Meaning | Default |
|---|---|---|
| `WAKE_MS` | wake-ping stream length before a band command | 520 ms |
| `DEFAULT_CMD_MS` | command stream length (wire duration overrides if sane) | 4000 ms |
| `BEACON_ADV_MIN/MAX` | advertising interval during a burst (lower = stronger/quicker) | 20–30 ms |
| `IDLE_ADV_MIN/MAX` | advertising interval while waiting for a phone | 200–400 ms |
| `SCREEN_ON_MS` | Heltec V3: how long the screen stays lit after the last PRG press | 10 s |

Screen internals (frame rate, battery period, panel reset timing) are at the top of
`oled_ui.h`.

## Protocol reference

Mirrors `RelayProtocol` (Android) / `AndroidRelayGattClient` (iOS):

| Characteristic | UUID | Access | Payload |
|---|---|---|---|
| Service | `A7830001-0000-1000-8000-00805F9B34FB` | — | — |
| TX | `A7830002-…` | write | `"{hex}\|{durationMs}"` |
| Command | `A7830003-…` | write | JSON (acked with `{"ok":true}`) |
| Status | `A7830004-…` | read | JSON reply / telemetry |
| Catalog | `A7830005-…` | read | `{"ok":true,"items":[]}` (empty; library lives on the phone) |
