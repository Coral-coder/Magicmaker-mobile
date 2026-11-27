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
  minutes** on the screen and in STATUS (the app's LINK tab). From firmware 1.4 it is also in a
  **battery heartbeat** advert that the Android app reads without connecting (top bar
  `ESP32:68% ~9H 40M`). See **Battery** and **Battery heartbeat** below.
- **Power off** (firmware 1.5): hold **PRG** for 2 s on the screen's **POWER** page (Heltec V3),
  or **POWER OFF** in the iPhone app (both boards). The board goes into its deepest sleep with no
  wake-up source; **RST** (EN on a DevKit) turns it on again. See **Turning it off and on** below.
- **Low-battery cutoff** (firmware 1.5, Heltec V3): the board turns itself off at **3.30 V** (or
  3.20 / 3.40 V, or never) so the cell is not run flat, and warns before that (`LOW`). On by
  default, also on boards updated from 1.4. See **Low-battery cutoff** below.

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
3. Start the firmware update in the app (Settings, **BOARD FIRMWARE**, **UPDATE**; you can also
   tap UPDATE first and press the button when the app asks). It sends the newest app image it
   has for that board: the one bundled with the app, or a newer one downloaded from the
   `esp32-firmware` release with **CHECK WEB** (checked against `firmware.json`'s MD5);
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
> Heltec V3: `board = heltec_wifi_lora_32_V3`, add `olikraus/U8g2@2.35.30` to `lib_deps`, and
> `build_flags = -Wl,--wrap=esp_bt_controller_init` for BLE modem sleep (see **Power**).
>
> An Arduino IDE build has no modem sleep (the IDE has no per-sketch linker flags); everything
> else is the same.

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
- Press again → next page: **STATUS → LAST PACKET → DEVICE → LOW BATTERY → POWER → STATUS …**
  (on DEVICE, LOW BATTERY and POWER the page turns when you let go, so a hold never carries over
  to the next page).
- On **DEVICE**, **hold PRG for 1 s** → the next battery capacity: 400 → 500 → 1000 → 1100 →
  2000 → 3000 → 5000 → 400 mAh (keep holding to step again every second, at most one round;
  the `CAP` line is highlighted). The choice is saved and survives reboots.
- On **LOW BATTERY**, **hold PRG for 1 s** → the next cutoff level: 3.20 → 3.30 → 3.40 V → OFF →
  3.20 V (same rules; the `CUT` line is highlighted). Saved and kept across reboots.
- On **POWER**, **hold PRG for 2 s** (the bar fills) → the board turns off. A tap (under 0.4 s)
  goes on to STATUS; letting go earlier than 2 s cancels. The hold only counts if the press
  started on the lit POWER page. See **Turning it off and on**.
- It goes dark **10 s after the last press** (`SCREEN_ON_MS` at the top of the `.ino`).
- Nothing else lights it: no boot splash, not a phone connecting, not a transmit. **One
  exception:** after you press **RST** with the battery too low to start, the screen shows
  `TOO LOW TO START` for 2 s (the only sign RST did anything), then the board turns off again;
  pressing PRG during those 2 s starts it anyway.
- At runtime PRG is just a button. It only selects flashing mode when held while you tap
  **RST**: then the board looks dead (dark, LED off) and keeps draining the battery. Tap RST
  again without PRG.

| Page | Shows |
|---|---|
| STATUS | `BLE` LINKED / WAITING FOR PHONE · `TX` IDLE / WAKE / SEND with a progress bar for the current phase · what the chip runs by itself: KEEP AWAKE ON / TX LOOP 3S / WAND LOOP 2.5S / KEEP AWAKE OFF · `PKT` packets sent since boot · the last packet's kind (BAND / WAND / PING / RAW) and how long ago · `BAT` % and expected runtime (`68% ~9H 40M`), or `68% CHARGING` / `100% USB POWER` / `--` |
| LAST PACKET | kind (RAW = a replay step or an MBLE tap), length and stream time (`WAKE+` when a wake ping ran first), then the packet hex, seven bytes a line |
| DEVICE | `BAT` battery voltage and % · `CAP` charge left of the capacity (`272 OF 400MAH`; hold PRG to change the capacity) · `RUN` expected runtime (`~9H 40M LEFT`, `~40M LEFT`, `~99H+ LEFT`) or CHARGING / USB POWER · `UP` uptime · `BLE` name and the last three bytes of its address · `FW` firmware version and board (`--` wherever there is no plausible battery reading) |
| LOW BATTERY | `CUT` the cutoff level (`3.30V` or `OFF`; hold PRG to change it) · `BAT` voltage and % · the state: OK / `LOW - CHARGE SOON` / CHARGING / USB POWER / `--` · `LOW` the warning level (`BELOW 3.40V`) · what the cutoff leaves in the cell (`OFF AT ~10% LEFT`, or `NO AUTO POWER-OFF`) · `HOLD PRG: NEXT LEVEL` |
| POWER | `HOLD PRG TO POWER OFF` · `RST TURNS ON` · the hold bar · `CHARGES WHILE OFF` · `UNPLUG FOR STORAGE` (`UPDATE RUNNING` / `POWER OFF WHEN DONE` and no bar while a Bluetooth update is received) |

In the low-battery warning stage the STATUS page's `BAT` value is drawn inverse with `LOW`
(`8% LOW ~25M`).

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
- **UART pads released** after boot (`MM_UART_RELEASE`, `board.h`): on battery the USB-serial
  chip (CP2102) is unpowered, and the ESP32's TX pin would otherwise push current into it through
  its 499 Ω resistor. Cost: no serial logs or crash text after boot (the firmware never prints
  anyway). Flashing is unaffected. Build with `-DMM_UART_RELEASE=0` to get them back.

**Turning it off and on** (firmware 1.5)

- **Off:** hold PRG 2 s on the POWER page, or **POWER OFF** in the iPhone app (SETTINGS → BOARD
  POWER, with a confirm), or the low-battery cutoff. The board stops transmitting, shows
  `POWERING OFF...` on a lit screen and waits until you let go of PRG (PRG held while pressing RST
  would start flashing mode), shows `PRESS RST TO TURN ON` for 1 s, disconnects the phone (reason
  0x15 "power off", so the app sees it at once), saves a capacity or cutoff picked in the last few
  seconds, and goes into deep sleep with **no wake-up source**. From the app the screen is not
  lit.
- **On:** press **RST**. The board starts like after any power-up: screen dark, LED blinking once a
  second, the app relinks by itself and pushes its settings. Keep-awake and the loops are off
  (the board always boots idle). If the battery is too low to start, see the exception above.
- **What "off" is:** the ESP32-S3 in deep sleep with every pin parked: the LED and the Vext rail
  held off, the LoRa radio asleep with its bus held, the OLED, battery-divider, header and UART
  pins isolated. Expected **~15–25 µA** at the battery on a V3.2 (estimate; a V3.0/V3.1 can draw up
  to ~9 µA more through the battery divider while the cell is above ~3.8 V, which software can't
  fix), against **~35 mA** running.
- **It is not a full disconnect.** The V3 has no software switch for its battery, so the only
  true zero is unplugging the battery (or adding a switch). **Unplug it for storage.**
- **Charging still works while off** (the charger runs from USB, not from the ESP32). A computer
  opening the serial port can reset, and so turn on, the board.
- **Classic DevKit:** the ESP32 itself drops to ~10 µA, but most DevKits' regulator and USB-serial
  chip keep drawing a few mA (5–15 mA is common), so on a DevKit "off" mainly stops the radio.
  EN turns it on again.

**Battery**

- A LiPo on the battery connector is read on GPIO1 through the board's divider (×4.9, ×1.045
  calibration). The divider is switched on (GPIO37) **only for a reading** (~10 ms) and off
  again straight after: **once a minute while the screen is dark**, every 5 s while it is lit,
  every 15 s in the low-battery warning zone (cutoff on), every 5 s after a reading below 3.10 V,
  and 0.1 s after boot. Outside the warning zone a reading waits while a beacon is on air (its
  transmit bursts dip the voltage), at most 10 s; inside it, it never waits.
- **Each reading is 32 samples, 250 µs apart** (~8 ms), and keeps the **75th percentile**, so the
  short dips of a beacon's transmit bursts barely move it (about +5–10 mV against a plain mean).
  A sample spread over 300 mV marks the reading unstable. `loop()` waits those ~8 ms (once a
  minute; a tap landing in them starts up to 8 ms later).
- The divider switch is active LOW on V3.0/V3.1 and active HIGH on V3.2: the firmware guesses
  from GPIO37's idle level at boot, falls back to the other level if a reading is ~0 V, and
  remembers which worked.
- **%** comes from the filtered voltage on a LiPo resting-voltage curve (rough; it reads high
  while charging). **Charge left** = capacity × %. The capacity is `BATTERY_MAH` (400 mAh) until
  you pick another on the DEVICE page (hold PRG).
- **Expected runtime** = the charge above the cutoff ÷ estimated draw, so `~0M` is when the
  cutoff turns the board off (with the cutoff OFF: down to empty). % and charge left stay the
  cell's own. The board cannot measure its current, only the voltage, so the estimate starts
  from a **model**: a ~15-minute time-weighted average of per-state draws (`DRAW_*` at the top
  of `battery_model.h`: base, advertising, phone linked, beacon on air, screen lit). Once the
  battery has visibly drained (≥ 2 % over ≥ 20 min, counted from 10 min after boot or charging),
  the **measured** drain takes over: the % slope over the last hour (or since the discharge
  began, for big cells), smoothed, and kept within 0.5–2.5× the model, because the flat middle of
  a LiPo curve makes single slopes noisy.
- **Charging** = the voltage rose ≥ 15 mV within 5 min (it ends when the voltage falls 10 mV
  from its peak, i.e. unplugged); **USB POWER** = above 4.25 V, or the **USB hint**: the board has
  no USB-sense pin, but the CP2102 is powered from USB only and a powered CP2102 holds its TX
  line (GPIO44, pulled down by the firmware) high. Neither shows a runtime, a warning or a
  cutoff. The hint is **unverified on hardware**: if a board shows USB POWER on battery alone,
  build with `-DMM_USB_SENSE=0` (a false "USB" would silence the cutoff); a wall charger whose
  CP2102 sits idle just falls back to the voltage rules.
- **Tune the model in the battery lead**: a current meter in series with the battery, USB
  unplugged. (A USB meter on a PC port also counts ~20 mA of the enumerated CP2102.) The
  screen-dark, no-phone, nothing-on-air reading is `DRAW_BASE_MA + DRAW_ADV_MA`; link a phone,
  start keep-awake and light the screen one at a time to see what each adds. Until then the
  runtime is only as good as the seeds (`DRAW_BASE_MA` 37.5 mA, `DRAW_BEACON_MA` 10 mA) for the
  first half hour.
- Without a battery the screen shows `--` (or the charger's output voltage, as USB POWER).
- **Charge current** is set by the board's charger at ~500 mA, i.e. **1.25 C for a 400 mAh cell**
  (hardware, not firmware): use a cell rated for it.
- **Flash writes:** the capacity and the cutoff level (NVS namespace `mm`, keys `batMah` and
  `lowCut`) are the only things the firmware ever writes to flash: each 3 s after its last change,
  only if it changed, and at once by a power-off.

**Low-battery cutoff** (firmware 1.5)

The board has **no over-discharge protection of its own**; only the cell's protection circuit,
if it has one. So 1.5 turns the board off before the cell runs flat:

| Setting | Turns off at | Left in the cell (curve) | `LOW` warning below |
|---|---|---|---|
| OFF | never | — | 3.40 V (warning only) |
| 3.20 V | 3.20 V | ~5 % | 3.30 V |
| **3.30 V (default)** | 3.30 V | ~10 % | 3.40 V |
| 3.40 V | 3.40 V | ~18 % | 3.50 V |

- Change it on the **LOW BATTERY** page (hold PRG) or in the iPhone app (SETTINGS → BOARD POWER).
  The board keeps it (NVS); the app does not push it on link. Boards updated from 1.4 start at
  3.30 V.
- **Warning:** below cutoff + 0.10 V (filtered), off again from 50 mV above that; never while
  charging or on USB. STATUS `batLow`, heartbeat flag bit 3, `LOW` on the screen and in both apps.
- **Cutoff:** 3 clean readings in a row below the level with the filtered value below it too
  (~30–45 s in the warning cadence); or, fast, 2 readings below 3.10 V at least 5 s apart. The
  count starts over once a reading is 50 mV above the level. Never on USB, while charging, on an
  unstable reading (spread or a jump over 300 mV), or for 10 min after the voltage steps up by
  50 mV or more (a charger plugged in). The filtered value lags a fast bench ramp by a minute or
  more; a real cell near 3.3 V falls a few mV a minute, so there it barely lags.
- **Boot check:** after RST / power-on / a brownout, two readings 50 ms apart before Bluetooth
  starts; below cutoff + 0.10 V and not on USB, the board shows `TOO LOW TO START` for 2 s and
  turns off again (after a brownout: without lighting the screen). **PRG during the notice
  starts it anyway** (also the way out for a USB-only board with an odd charger reading). Skipped
  after a software restart (a Bluetooth update), a crash, or with the cutoff OFF.
- Readings vary between boards by roughly ±30–100 mV at the battery, so "3.30 V" acts somewhere
  between ~3.25 and 3.35 V real.
- After a cutoff the cell holds ~20–40 mAh, enough for weeks at the off current, but
  **recharge it within a month**, then press RST.

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
  ~0.2 s to every tap.) Firmware 1.4 adds one slow non-connectable advert while linked: the
  battery heartbeat, every 1–2 s at +3 dBm.
- **`loop()` sleeps until its next deadline** (a phase end, a loop burst, an LED blink, a
  battery reading, the screen; at most 5 s) and is woken early by a command, a
  connect/disconnect or PRG. It does not poll.
- **Heltec V3:** the LoRa radio is asleep (~0.6 mA saved, check with a meter), the OLED and its
  Vext rail are unpowered unless you use PRG, the battery divider is on for ~10 ms a minute, and
  the UART pads are released (0 to ~1 mA, unmeasured). The LED only blinks.
- **CPU at 80 MHz from the first line of `setup()`** (it used to switch after the boot work).
- **BLE modem sleep on the Heltec V3** (firmware 1.5, `btsleep.h`): the Bluetooth controller
  turns its radio off between radio events (estimated 3–10 mA of the ~35 mA base; unmeasured).
  The S3 controller supports it at runtime, but NimBLE-Arduino's default config leaves it off and
  sets the controller up itself, so the firmware switches it on with a **link-time wrap**:
  builds linked with `-Wl,--wrap=esp_bt_controller_init` (CI's images; PlatformIO with the
  `build_flags` below) have it, STATUS says `"btSleep":true`; a plain Arduino IDE build does not
  (it runs exactly as 1.4 did). The controller wakes itself 2.5 ms before each radio event, so
  connection parameters, beacon timing and send latency are unchanged. `-DMM_BT_MODEM_SLEEP=0`
  keeps the wrap but leaves sleep off.
- **Off and cutoff:** a real off state (~15–25 µA, see **Turning it off and on**) and the
  low-battery cutoff, so a forgotten board neither drains for days nor runs the cell flat.
- **No Wi-Fi, nothing else written to flash** (only a battery capacity or cutoff level you pick).

What it can't do in this core (Arduino-ESP32 2.0.17):

- **No automatic light sleep:** `CONFIG_PM_ENABLE` is off in the prebuilt core, so the CPU wakes
  for every 1 ms FreeRTOS tick. Manual light sleep would drop the BLE link.
- **No CPU below 80 MHz while Bluetooth runs** (it needs the 80 MHz APB clock).
- Expect roughly **30–45 mA idle** on the Heltec V3 without modem sleep (estimate; measure yours
  in the battery lead), i.e. about **8–12 h on a 400 mAh cell down to the 3.30 V cutoff**; with
  modem sleep somewhat more. The screen shows the live estimate.
- The **classic ESP32** core already uses BLE modem sleep between radio events; its datasheet
  figures for modem sleep at 80 MHz are ~20–30 mA. It has no battery reader.
- **Latency note:** the link asks for slave latency 2, so the first write after an idle stretch
  can wait up to 3 connection intervals (~90–150 ms) if the phone accepts it. iOS may run its own
  parameters; STATUS `conn` shows what was actually negotiated. 1.5 leaves the request as it was.

For longer runtime: a bigger cell, fewer loops/keep-awake (the beacon is the biggest extra), a
lower beacon power in the app (shorter range), and turning the board off when it is not in use.

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
| `HEARTBEAT_ADV_MIN/MAX` | battery heartbeat advert interval while a phone is linked | 1–2 s |
| `LINK_POWER` | TX power of the link to the phone (BLE default power); raise to `P9` if it drops at range | +3 dBm |
| `LED_MIN_FLASH_GAP_MS` | at most one transmit flash per this long (dense replays still blink) | 250 ms |
| `LOOP_MAX_SLEEP_MS` | longest `loop()` sleep between deadlines (all deadlines are tracked; a safety net) | 5000 ms |
| `SCREEN_ON_MS` | Heltec V3: how long the screen stays lit after the last PRG press | 10 s |
| `BATTERY_MAH` | Heltec V3: LiPo capacity until one is picked on the screen (STATUS `batMah`) | 400 mAh |
| `POWER_OFF_NOTICE_MS` / `POWER_OFF_GRACE_MS` | power-off: the off frame on a lit screen / the app's STATUS read, before the disconnect | 1000 / 750 ms |

Elsewhere:

| Constant | Where | Meaning | Default |
|---|---|---|---|
| `POWER_HOLD_MS` | `oled_ui.h` | POWER page: hold PRG this long to turn off | 2000 ms |
| `POWER_TAP_MS` | `oled_ui.h` | POWER page: a shorter press is a tap (next page) | 400 ms |
| `BAT_PERIOD_NEAR_MS` | `power.h` | battery reading period in the warning zone (cutoff on) | 15 s |
| `CUT_DEFAULT_MV` | `battery_model.h` | cutoff level when none was picked | 3300 mV |
| `MM_USB_SENSE` | build flag (`board.h`) | the CP2102 USB hint; `0` if a board reads USB on battery | 1 |
| `MM_UART_RELEASE` | build flag (`board.h`) | release the UART pads after boot; `0` for serial logs | 1 |
| `MM_BT_MODEM_SLEEP` | build flag (`btsleep.h`) | BLE modem sleep in wrap-linked builds; `0` to leave it off | 1 |
| `MM_DEBUG_TIMING` | build flag (`board.h`) | STATUS `advMaxUs`: the longest advertising restart (bench) | 0 |

The wire clamps (TX-characteristic duration 60–12000 ms, `raw_burst` 60–10000 ms, loop interval
500–60000 ms, setting ranges) are part of the relay contract and live in `relay_proto.h`.
Screen internals (frame rate, long press, power hold, panel reset timing) are at the top of
`oled_ui.h`; battery timing (reading periods, sampling, capacity presets) and `MM_LORA_SLEEP` at
the top of `power.h`; the per-state draw estimates (`DRAW_*`), the runtime model and the cutoff
rules (`CUT_*`, `LOW_WARN_*`) at the top of `battery_model.h`; the off state in `shutdown.h`.

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
| `power_off` (`poweroff`, `shutdown`) | `confirm` must be `true` | firmware 1.5, both boards: the power-off sequence (STATUS still readable for ~0.75 s, 1 s with the screen lit, then a disconnect with reason 0x15 and deep sleep until RST / EN); `"confirm required"` without it, `"busy"` while a Bluetooth update is being received |
| `set_low_cutoff` (`low_cutoff`, `set_cutoff`) | `mv` | firmware 1.5, Heltec V3: the cutoff level. `0` = off, `3200` / `3300` / `3400`; 3000–3600 snaps (< 3250 → 3200, < 3350 → 3300, else 3400); anything else (missing, not a number, out of range) → `"bad mv"`; a classic ESP32 → `"unsupported"`. Kept in NVS |
| anything else | — | `"unknown action"` |

Errors: `bad json`, `bad hex`, `packet too long`, `no packet`, `bad token`, `unsupported`,
`unknown action`, `busy` (command queue full, or `power_off` during an update), `confirm
required`, `bad mv`, `powering off` (every command once a power-off began). Programs: at most one runs; turning one on turns
the others off (a loop burst on air finishes first; a keep-awake stream stops at once). A user
send or MBLE tap preempts anything; a preempted loop burst re-arms one interval after the job
that replaced it. Disconnects change nothing; nothing but the cutoff level (and the capacity
picked on the screen) is stored in flash.

**STATUS** (one object, ≤ 508 bytes, keys in this order; protocol 3 from firmware 1.5):

| Key | When | Meaning |
|---|---|---|
| `ok`, `error` | always / on failure | the last command's reply (reset to ok on connect) |
| `running` | always (`true`) | marks a real status (firmware before 1.2 sent a bare `{"ok":true}`) |
| `proto`, `fw`, `board` | always | `3` (1.5; `2` before), `MM_FW_VERSION` (`"1.5"`), `"HELTEC V3"` / `"ESP32"` |
| `keepAwake` | always | KEEP AWAKE runs |
| `txLoopEnabled`, `txLoopIntervalMs` | TX LOOP runs | |
| `starlightLoopEnabled`, `starlightIntervalMs` | WAND LOOP runs | |
| `wakeupPreambleMs`, `commandBurstMs`, `starlightBurstMs`, `txPowerLevel`, `txInterleave` | always | chip settings |
| `uptimeS`, `sent` | always | seconds since boot, jobs put on air since boot |
| `batMv`, `batPct`, `batMah` | Heltec V3 with a plausible reading | filtered battery mV, %, capacity (mAh) |
| `runMin` / `charging` | with the battery keys | expected runtime in minutes, to the cutoff / `true` while charging or on USB power (then no `runMin`) |
| `batLow` | with the battery keys, only when `true` | 1.5: the low-battery warning stage (below cutoff + 0.10 V) |
| `cutMv` | Heltec V3 1.5, always (also without a reading) | the cutoff level: `0` = off, `3200` / `3300` / `3400` |
| `items` | after a catalog action | `[]` |
| `keepAwakeHex` | KEEP AWAKE runs | the streamed packet |
| `txLoopHex`, `txLoopLabel` | TX LOOP runs | its packet and label |
| `starlightLoopHex`, `starlightLoopLabel` | WAND LOOP runs | same |
| `conn` | 1.5, a BLE read (diagnostic) | the reading phone's link: `[interval in 1.25 ms units, peripheral latency, supervision timeout in 10 ms units]` |
| `btSleep` | 1.5, when BLE modem sleep is on (diagnostic) | `true` |
| `advMaxUs` | `MM_DEBUG_TIMING` builds only (diagnostic) | the longest advertising restart since boot, µs |

When the object would exceed 508 bytes the diagnostics are left out first, then the label, then
the hex (in practice only the label of a 29-byte wand loop next to an error and every battery key
can fall off).

Example (idle, Heltec, 1.5, battery in the warning stage):

```
{"ok":true,"running":true,"proto":3,"fw":"1.5","board":"HELTEC V3","keepAwake":false,"wakeupPreambleMs":520,"commandBurstMs":4000,"starlightBurstMs":500,"txPowerLevel":3,"txInterleave":false,"uptimeS":8123,"sent":42,"batMv":3381,"batPct":17,"batMah":400,"runMin":51,"batLow":true,"cutMv":3300,"conn":[24,2,400],"btSleep":true}
```

**Advertising.** Waiting for a phone: flags + service UUID, name `MM_ESP` + the battery
heartbeat in the scan response, +3 dBm. While a packet is on air: manufacturer data only,
connectable, 20–30 ms, at the app's beacon power; with no phone linked
its scan response carries `MM_ESP` + the service UUID, so the app can find the board and relink
during a keep-awake stream or a loop. Linked and idle: `MM_ESP` + the battery heartbeat,
non-connectable, every 1–2 s, +3 dBm.

**Battery heartbeat** (firmware 1.4+, read by the Android app without connecting):
manufacturer data with company id `0xFFFF`: `FF FF 4D 42 01 <battery % or FF> <flags>
<runtime minutes, u16 little-endian, or FFFF>`; flags bit 0 charging, bit 1 USB power, bit 2
battery reading present, bit 3 battery low (1.5: the warning stage; the version byte stays 1,
older readers ignore the bit) (a classic ESP32 sends `FF 00 FFFF`). The % holds until the reading is
0.75 points away and the runtime moves in steps of 5 min (under 10 h), 15 min (under 24 h) or
30 min, up to 99 h, so the advert only changes when the battery does.
