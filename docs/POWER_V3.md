# Heltec V3 power plan: power-off, low-battery cutoff, efficiency (firmware 1.5)

Status: **decided plan**, ready to implement. Every choice below is final for 1.5; items that
need a bench measurement say so and name the ship gate.

Scope (user, verbatim): *"forget v4 and web flasher... just focus on efficiency for v3"*, after
*"i need an option for low power cutoff to save the battery, make the firmware efficient, and i
need a screen where i can press and hold the button to power off, with reset to turn it on
again... a real poweroff btw"*.

- **In:** Heltec WiFi LoRa 32 V3 / V3.1 / V3.2 (ESP32-S3) firmware, plus what the iPhone needs to
  drive the new options (both themes), the Android heartbeat token, README, user guide, CI.
- **Kept working:** the classic ESP32 build compiles and behaves as before; it only gains the
  `power_off` command.
- **Out:** Heltec V4, the web flasher (CI keeps committing images there as it does today; no
  flasher changes), a power-managed (PM / light-sleep) build.

Base: firmware 1.4.1, Arduino-ESP32 2.0.17 (IDF 4.4.7, `CONFIG_PM_ENABLE` off), NimBLE-Arduino
1.4.3, U8g2 2.35.30. New version: **`MM_FW_VERSION "1.5"`**, **`MM_RELAY_PROTO 3`**.

---

## 0. Decisions at a glance

| # | Decision |
|---|---|
| 1 | Page cycle becomes **STATUS → LAST PACKET → DEVICE → LOW BATTERY → POWER → STATUS**. |
| 2 | **POWER page:** hold PRG **2 s** (progress bar) → `POWERING OFF...` → deep sleep with **no wake source**. Only **RST** (EN on a DevKit) turns the board on. |
| 3 | The hold counts only if the press **started on the lit POWER page**. A tap (< 0.4 s) turns the page; a release between 0.4 s and 2 s cancels and stays on POWER. |
| 4 | "Off" = ESP32-S3 deep sleep with every pin parked (section A4). Expected **~15–25 µA** at the battery (V3.2), against **~35 mA** running. The V3 has no software battery switch. True zero means unplugging the JST or adding a switch, and the UI and docs say so. |
| 5 | **Low-battery cutoff ON by default at 3.30 V.** Options: **OFF / 3.20 / 3.30 / 3.40 V** (about 5 / 10 / 18 % left on the firmware's curve). Stored in NVS (`mm`/`lowCut`, u16 mV, 0 = off). |
| 6 | **Warning stage** below cutoff + 0.10 V (3.40 V by default; 3.40 V base when the cutoff is OFF): STATUS `batLow`, heartbeat flag **bit 3**, inverse `LOW` on the STATUS page, iPhone and Android `LOW`. |
| 7 | **Cutoff rule:** 3 consecutive clean readings below the threshold **and** the filtered value below it. Fast path: 2 readings below 3.10 V at least 5 s apart. Reset at threshold + 50 mV. No cutoff on USB, while charging, on unstable readings, or for 10 min after a step rise. |
| 8 | **Boot check:** after RST / power-on / brownout, if the battery is below cutoff + 0.10 V and not on USB, the OLED shows `TOO LOW TO START` for 2 s and the board goes back off. **PRG during the notice = start anyway.** It is skipped after a software restart (OTA). |
| 9 | On-device cutoff setting: **LOW BATTERY page, hold PRG 1 s = next level** (the same gesture and limits as the capacity on DEVICE). It is a different page from POWER, with a different hold time and look. |
| 10 | Wire: CMD **`power_off`** `{"confirm":true}` (both boards) and **`set_low_cutoff`** `{"mv":3300}` (0 = off; Heltec). STATUS: **`cutMv`**, **`batLow`**, and the diagnostics **`conn`** and **`btSleep`**. |
| 11 | iPhone: new **BOARD POWER** section in SETTINGS (standard + VFD): cutoff chips and **POWER OFF** with a confirm. LINK tab: `LOW` and a `LINK` diagnostics row. |
| 12 | Efficiency now: **BLE modem sleep on the S3** via a link-time wrap (est. −3…10 mA, gated by a soak test), **UART0 pads released** (est. 0…~1 mA), **CPU 80 MHz from the first line**, the real off state, the cutoff. Connection parameters are **unchanged**, so sends get no extra lag. |
| 13 | Rejected for 1.5 (with reasons in C2): 40 MHz CPU, slower idle advertising, lower OLED contrast, lower link/idle power, non-connectable beacons and a slower keep-awake (both need a band test first), higher slave latency, switching parameters on activity, a PM build, USB-JTAG gating, NimBLE deinit before sleep. |

---

## 1. Facts this plan rests on

From the V3.0 / V3.2 schematics, the ESP32-S3 datasheet, the IDF 4.4.7 sources and NimBLE-Arduino
1.4.3 (research pass; the IDF lines below were re-read for this plan):

- **No software path to the battery.** The 3V3 LDO (CE6260, 6 µA quiescent) has EN tied to VIN.
  The battery reaches VSYS through a P-FET gated by VDD_5V, not by a GPIO. CHIP_PU only has RST
  and the CP2102 auto-reset. So deep sleep with no wake source is the deepest "off" software
  can reach. RST pulls CHIP_PU low, which is a power-on-type reset that clears pad holds.
- **The CP2102 is powered from USB only.** On battery it is unpowered. GPIO43 (U0TXD, through
  499 Ω) and GPIO44 (U0RXD, ROM weak pull-up) can back-feed it. The size of that back-feed is
  unmeasured.
- **Vext** (GPIO36) is off when HIGH or floating on every revision. The **battery divider**
  (GPIO37) is off when floating on every revision. The idle level of GPIO37 tells the revision:
  with INPUT_PULLDOWN it reads HIGH on V3.0/V3.1 (R8 pull-up, divider on = LOW) and LOW on V3.2
  (on = HIGH). This is the same trick Meshtastic uses.
- **SX1262:** NSS (R31) and NRESET (R23) have 10 kΩ pull-ups to 3V3. SCK and MOSI have no pulls.
- **Deep sleep (IDF 4.4.7 `sleep_modes.c` / `sleep_gpio.c`):** BT, Wi-Fi, XTAL, VDDSDIO and DIG
  are always forced off. `RTC_FAST_MEM` stays on in this core (`ALLOW_RTC_FAST_MEM_AS_HEAP=y`).
  After `gpio_deep_sleep_hold_en()`, `esp_sleep_isolate_digital_gpio()` isolates every digital
  pad (26–48) that is not individually held: input and output off, no pulls. That covers
  37/43/44 and the header pins. It asserts the caller's stack is in internal RAM, which holds
  for loopTask (no PSRAM).
- **S3 BLE modem sleep without PM works at runtime.** In IDF 4.4.7
  `components/bt/controller/esp32c3/bt.c` (shared by the S3), `cfg->sleep_mode ==
  ESP_BT_SLEEP_MODE_1` enables sleep. The LP clock defaults to the main XTAL, and phase 2 calls
  `esp_phy_disable()`. Without PM there is no wake-up timer; the controller's own scheduler wakes
  it `BTDM_MODEM_WAKE_UP_DELAY` = 8 half-slots = **2.5 ms** before the next event. It never
  sleeps across gaps under `BTDM_MIN_SLEEP_DURATION` = 24 half-slots (7.5 ms). A host HCI
  command to a sleeping controller blocks until it wakes. It is off today only because
  `NimBLEDevice::init()` builds its config from `BT_CONTROLLER_INIT_CONFIG_DEFAULT()`
  (sleep_mode 0) and calls `esp_bt_controller_init()` unconditionally. A pre-init is therefore
  impossible, and a linker wrap is the way in (verified to link in a scratch PlatformIO build).
- **BLE needs 80 MHz APB**: 80 MHz is the CPU floor while BLE is up.
- **Peripheral latency delays phone→board writes** by up to (L+1) × interval. Today's request
  (30–50 ms, L = 2, 4 s timeout) is outside Apple's current rules (timeout 6–18 s), so iOS may be
  running its own parameters. Nobody knows today what is actually negotiated.
- **Readings:** ±6 mV at the pin (calibrated), about ±30–50 mV typical and ±70–100 mV worst case
  at the battery after ×5.12 and the 1 % divider. Beacon TX peaks dip the cell 40–75 mV for well
  under 1 ms per channel.

Budget today (estimates, no meter): base ~28–40 mA (CPU at 80 MHz in WAITI + BT controller with
the PHY on), +0.3–1 mA advertising, +0.4–0.8 mA linked, +9–12 mA beacon on air, +5–15 mA screen
lit.

---

## A. Power-off

### A1. Pages

`enum ScreenPage { PAGE_STATUS, PAGE_PACKET, PAGE_DEVICE, PAGE_CUTOFF, PAGE_POWER, PAGE_COUNT }`.
The header draws 5 dots; the first dot starts at x = 91, so "LAST PACKET" and "LOW BATTERY"
(66 px) still fit. The OLED font is ASCII 32–126, so the screen writes `...` for "…".

**POWER page** (21 columns, lines 0–5):

```
POWER                  o o o o #
- - - - - - - - - - - - - - - - -
HOLD PRG TO POWER OFF
RST TURNS ON
[#########                      ]   <- line 2: frame always drawn, segments = hold progress
                                       (scrBar at x 0, width 128: 41 segments)
CHARGES WHILE OFF
UNPLUG FOR STORAGE
```

While a Bluetooth update is receiving (`otaBusy()`): line 0 `UPDATE RUNNING`, line 1
`POWER OFF WHEN DONE`, no bar, and the hold is ignored.

**Off frames.** No page dots; `scrHeaderPlain(title)`.

```
POWER                         LOW BATTERY                  LOW BATTERY
POWERING OFF...               POWERING OFF...              TOO LOW TO START
                              BAT  3.27V 9%                BAT  3.36V 13%
RELEASE PRG      (inverse)    CHARGE IT, THEN              CHARGE IT, THEN
 -> PRESS RST TO TURN ON      PRESS RST TO TURN ON         PRESS RST TO TURN ON
CHARGES WHILE OFF                                          PRG: START ANYWAY
 (button / app)                (cutoff, if lit)             (boot check)
```

### A2. Gesture and accidental-press safety

1. The press that lights a dark screen always lands on **STATUS** (`screenPowerOn` already does
   this). A held button never steps pages: pages step on fresh debounced edges only.
2. DEVICE, LOW BATTERY and POWER turn the page **on release** (as DEVICE does today), so a hold
   never carries over from one page to the next.
3. POWER counts a hold only if that press **began while POWER was lit** (`gBtnHoldPage ==
   PAGE_POWER`, set at press-down).
4. The bar fills from press-down. At **`POWER_HOLD_MS` = 2000** a power-off request is raised
   once (`gScrPowerOffReq`). Release before `POWER_TAP_MS` = 400 ms = a tap → next page (STATUS).
   Release between 0.4 s and 2 s = cancelled: stay on POWER, bar empty.
5. Reaching POWER from dark takes 5 separate presses inside the 10 s screen timeouts, then a 2 s
   hold. A stuck PRG (bag) only ever lights STATUS for 10 s. The worst accidental outcome is the
   board turning off, which RST undoes.
6. While the hold runs, every frame refreshes `gScrPressMs`, so the screen timeout cannot cut in.
   Once the request is raised, the off sequence owns the screen (no timeout).
7. **OTA arming is unchanged**: any PRG press arms Bluetooth updates for 120 s. That is harmless
   here: power-off cancels a pending post-update restart (`otaCancelRestart()`), and the POWER
   hold is refused while a transfer is receiving.

### A3. The sequence (`.ino`, loop-owned state machine)

`beginPowerOff(reason, now)` with reason ∈ {`MM_OFF_BUTTON`, `MM_OFF_APP`, `MM_OFF_LOW`}:

| Stage | What happens | Ends |
|---|---|---|
| start (once) | `gOffPending = true` (the CMD callback answers `"powering off"` from now on); `gEngine.halt()`; `advApply(ADV_OFF)` (no relaunch: `advManage` is skipped while off); LED LOW (ledService skipped); `otaCancelRestart()`; screen: `screenShowOff(kind)` if lit. Button reason with PRG still down → `OFF_WAIT_RELEASE`, otherwise `OFF_NOTICE`. | — |
| `OFF_WAIT_RELEASE` | Frame `POWERING OFF... / RELEASE PRG`. PRG held during a later RST would boot ROM download mode (looks dead, keeps draining). | PRG released (debounced), or 10 s (`POWER_OFF_RELEASE_MAX_MS`) |
| `OFF_NOTICE` | Frame `PRESS RST TO TURN ON` (or the LOW BATTERY frame). The app path uses this time so its STATUS read after the CMD write completes. | `POWER_OFF_NOTICE_MS` = 1000 if the screen is lit, else `POWER_OFF_GRACE_MS` = 750 |
| `OFF_DISCONNECT` | Copy `gServer->getPeerDevices()` (advertising is already stopped, so the list cannot grow), then `gServer->disconnect(h, BLE_ERR_RD_CONN_TERM_PWROFF /*0x15*/)` for each. The phone sees the drop at once instead of after the supervision timeout. | `gLinked == 0`, or 500 ms (`POWER_OFF_LINK_WAIT_MS`) |
| `OFF_SLEEP` | `powerFlushSaves()` (a capacity or cutoff picked in the last 3 s is written now), then `mmDeepSleepForever()` (A4). | never returns |

`offService(now)` runs right after `otaLoop()` and returns true while a sequence runs; loop then
waits at most 20 ms. Commands are drained and dropped. `publishSnapshot()` keeps running, so a
STATUS read during the grace works. The low-battery cutoff starts the sequence **at once** (a job
on air is cut short). The fast path (< 3.10 V) has the same behaviour.

The NimBLE stack is **not** deinitialised. IDF states that connections are not kept in deep sleep
whatever you call, deep sleep forces the BT and RF domains off, and `NimBLEDevice::deinit()` from
loop() is untested in 1.4.3, so it would only add a hang risk.

### A4. Shutdown code: `shutdown.h` (new, both boards)

```cpp
#include <esp_sleep.h>
#include <driver/gpio.h>
#include <driver/rtc_io.h>

#if MM_HELTEC_V3
// RTC pads held at a level through deep sleep: the SX1262 bus (asleep; NSS high keeps it asleep).
struct MmPadLevel { uint8_t pin; uint8_t level; };
static const MmPadLevel HV3_SLEEP_HOLD[] = {
    {HV3_LORA_NSS_PIN, 1}, {HV3_LORA_SCK_PIN, 0}, {HV3_LORA_MOSI_PIN, 0}, {HV3_LORA_RST_PIN, 1}};
// RTC pads isolated (no input, no output, no pulls, held): VBAT ADC, header pins, LoRa MISO /
// BUSY, OLED SDA / SCL / RST.
static const uint8_t HV3_SLEEP_ISOLATE[] = {1, 2, 3, 4, 5, 6, 7, 11, 13, 14, 17, 18, 21};
// Never touched: 0 (PRG: strapping, R7 pull-up), 15/16 (32 kHz crystal), 19/20 (USB pads, NC).
#endif

// setup(), right after setCpuFrequencyMhz(80): undo any hold left by a previous sleep (a no-op
// after RST, needed after esp_restart() or a future timer wake). A held pad ignores pinMode().
static void mmReleaseSleepHolds() {
#if MM_HELTEC_V3
  gpio_deep_sleep_hold_dis();
  gpio_hold_dis((gpio_num_t)HV3_LED_PIN);
  gpio_hold_dis((gpio_num_t)HV3_VEXT_PIN);
  for (const MmPadLevel& h : HV3_SLEEP_HOLD) { rtc_gpio_hold_dis((gpio_num_t)h.pin); rtc_gpio_deinit((gpio_num_t)h.pin); }
  for (uint8_t p : HV3_SLEEP_ISOLATE)        { rtc_gpio_hold_dis((gpio_num_t)p);     rtc_gpio_deinit((gpio_num_t)p); }
#else
  rtc_gpio_hold_dis(GPIO_NUM_12);
  rtc_gpio_deinit(GPIO_NUM_12);
#endif
}

// Deepest state software can reach. Only RST (EN) starts the board again: power-on reset.
[[noreturn]] static void mmDeepSleepForever() {
#if MM_HELTEC_V3
  screenPowerOff();                    // display off, Wire.end, SDA/SCL inputs, OLED RST low, Vext HIGH
  loraSleep();                         // reset + SetSleep(cold) again: surely asleep, NSS ends HIGH
  digitalWrite(HV3_LED_PIN, LOW);   pinMode(HV3_LED_PIN, OUTPUT);
  digitalWrite(HV3_VEXT_PIN, HIGH); pinMode(HV3_VEXT_PIN, OUTPUT);
  pinMode(HV3_VBAT_CTRL_PIN, INPUT);   // divider off (IDF isolates it at sleep entry anyway)
  gpio_hold_en((gpio_num_t)HV3_LED_PIN);
  gpio_hold_en((gpio_num_t)HV3_VEXT_PIN);
  for (const MmPadLevel& h : HV3_SLEEP_HOLD) {
    const gpio_num_t g = (gpio_num_t)h.pin;
    rtc_gpio_set_level(g, h.level);    // level first: NSS / RST never glitch low (R31 / R23 hold them meanwhile)
    rtc_gpio_init(g);
    rtc_gpio_set_direction(g, RTC_GPIO_MODE_OUTPUT_ONLY);
    rtc_gpio_pullup_dis(g);
    rtc_gpio_pulldown_dis(g);
    rtc_gpio_set_level(g, h.level);
    rtc_gpio_hold_en(g);
  }
  for (uint8_t p : HV3_SLEEP_ISOLATE) rtc_gpio_isolate((gpio_num_t)p);
  gpio_deep_sleep_hold_en();           // 35/36 keep their level; IDF isolates 37, 43, 44, 33-48 at entry
#else
  digitalWrite(STATUS_LED, LOW);
  rtc_gpio_isolate(GPIO_NUM_12);       // IDF's own deep-sleep advice (WROVER pull-up on MTDI)
#endif
  esp_sleep_disable_wakeup_source(ESP_SLEEP_WAKEUP_ALL);   // no PRG wake: ext0 alone costs ~120 uA
  esp_sleep_pd_config(ESP_PD_DOMAIN_RTC_PERIPH, ESP_PD_OPTION_OFF);
  esp_sleep_pd_config(ESP_PD_DOMAIN_RTC_SLOW_MEM, ESP_PD_OPTION_OFF);
  esp_deep_sleep_start();
  for (;;) {}
}
```

Expected battery current when off: S3 ~7 µA + LDO 6 µA + charger ≤ 1–2 µA + SX1262 0.16 µA +
Vext LDO ≤ 1 µA, so **~14–20 µA on V3.2**. V3.0/V3.1 can add up to ~8.6 µA while the cell is above
~3.8 V (AO7801 sub-threshold leak in the divider, not fixable in software). That is about
1/2000 of the running draw. **Charging still works while off**: the charger runs from USB,
independent of the ESP. A PC opening the serial port toggles DTR/RTS and can reset (turn on) the
board.

Classic DevKit: the ESP32 drops to ~10 µA, but the DevKit's own regulator and USB-UART usually
keep drawing 5–15 mA. The README says so.

### A5. Boot, and what the user sees after RST

`setup()` order (Heltec; the classic build keeps steps 1, 2, 9 onward):

1. `setCpuFrequencyMhz(80)`: first line (it was after `powerBegin`). It saves ~10 mA for the
   ~0.1 s of boot work.
2. `mmReleaseSleepHolds()`.
3. `screenBegin(SCREEN_ON_MS, DEVICE_NAME)`: Vext off, PRG interrupt.
4. `uartRelease()` (power.h, `MM_UART_RELEASE`): GPIO43 `INPUT` (no pull), GPIO44
   `INPUT_PULLDOWN` (the USB hint, B5).
5. `loraSleep()`.
6. `powerBegin(BATTERY_MAH)`: reads `batMah` and `lowCut`, detects the divider level from
   GPIO37's idle level (the LOW-then-HIGH trial stays as a fallback).
7. `powerBootCheck(esp_reset_reason())` (B6). It may end in `screenBootLowNotice()` +
   `mmDeepSleepForever()`.
8. LED, engine defaults, `gShadow.hasBattery = true`, then NimBLE init as today.

After **RST** (PRG not held) the board boots like any power-up: the screen stays **dark** (press
PRG to light STATUS), the LED blinks once a second (waiting), and fast advertising runs for 30 s.
The iPhone relinks by itself and pushes its settings. **Keep-awake and the loops are off**: the
board always boots idle, and the app's switches follow the board. The battery filter starts from
a fresh reading, and the runtime comes from the model for the first ~20 min. If the battery is in
the LOW zone (and not on USB), the screen lights for 2 s with `TOO LOW TO START` and the board
goes back off; pressing PRG during those 2 s starts it anyway. If PRG was held while tapping
RST, it is in download mode (dark, LED off): tap RST again.

The boot notice is the **one exception** to "screen only on PRG". It follows a deliberate RST,
lasts 2 s, and is the only sign that RST did anything. After a **brownout** reset it is not
shown (lighting the panel could brown out again); the board just goes off if the reading is low.

### A6. `power_off` command (both boards)

`{"action":"power_off","confirm":true}` (aliases `poweroff`, `shutdown`). Without `confirm:true`
it answers `"confirm required"`; while a Bluetooth update is receiving, `"busy"`. Otherwise it
answers ok and queues `RELAY_CMD_POWER_OFF`. loop() calls `beginPowerOff(MM_OFF_APP)`: 750 ms
grace (the app's STATUS read), disconnect with reason 0x15, deep sleep. Remote power-off **does
not light the screen**. The classic board runs the same sequence without the screen. EN wakes
it.

### A7. Interplay

- **DEVICE** long press (capacity) is unchanged.
- **LOW BATTERY** hold (cutoff level) uses the same 1 s / step-every-1 s / at-most-one-round
  rule (B10).
- **POWER** is the only 2 s hold and the only page with a bar.
- **OTA:** the POWER hold is refused while receiving (page says `UPDATE RUNNING`). The cutoff is
  not refused: its disconnect aborts the transfer, and the running image is untouched.
  `power_off` answers `"busy"`. A finished update that is waiting 1.5 s to restart is cancelled;
  the new image boots at the next RST.
- **Programs:** never persisted, never resumed (unchanged rule).
- **Future sync hub (LittleFS):** `OFF_SLEEP` is the single place to flush it; add it there.

---

## B. Low-battery cutoff

### B1. Options

| Setting | Off at | Left on the curve | Warning below | Notes |
|---|---|---|---|---|
| OFF | never | — | 3.40 V | warning only, no automatic power-off |
| 3.20 V | 3.20 V | ~5 % | 3.30 V | most runtime, least margin |
| **3.30 V (default)** | 3.30 V | ~10 % | 3.40 V | Meshtastic's OCV table is this curve; ~3.33–3.37 V at rest |
| 3.40 V | 3.40 V | ~18 % | 3.50 V | gentlest on the cell |

Updating a 1.4.x board to 1.5 turns the cutoff **on at 3.30 V** (no `lowCut` key yet). The
README and guide say how to switch it OFF. Why it matters: the board has **no over-discharge
protection** of its own and relies on the cell's PCM, if it has one.

### B2. Readings

- `BAT_SAMPLES` 8 → **32**, spaced **250 µs** (`BAT_SAMPLE_GAP_US`): an ~8 ms window, so a TX
  dip (≤ ~1.5 ms per advertising event) touches at most ~20 % of the samples. The value is
  **p75** (`BAT_CLEAN_RANK` = 24 of 32, insertion sort of `uint16_t`). Bias is ≈ +0.7σ, about
  +5–10 mV. **Unstable** = max − min of the samples > 300 mV.
- The window blocks loop() for ~8 ms, once a minute (every 15 s in the warning zone). A tap that
  lands in that window starts ≤ 8 ms later. This is the only latency cost in the plan.
- Cadence: 60 s dark / 5 s lit (unchanged). **15 s** (`BAT_PERIOD_NEAR_MS`) while the filtered
  value is in the warning zone and the cutoff is on. **5 s** (`BAT_PERIOD_FAST_MS`) after a
  reading below 3.10 V.
- On-air deferral (≤ 10 s) stays outside the warning zone. Inside it there is **no deferral**:
  p75 handles the dips, so keep-awake streams cannot starve the cutoff.
- The model gets the same p75 value. Divider ON level: from GPIO37's idle level at
  `powerBegin()`, with the existing ~0 V → other-level trial kept as a fallback.

### B3. Warning stage

`warnMv = (cutMv ? cutMv : 3300) + 100`. **batLow** turns on when filtered < warnMv and off when
filtered ≥ warnMv + 50. It is never set while charging or on USB. It is shown as:

- STATUS key `"batLow":true` (only when true);
- heartbeat flags **bit 3** (also in the idle scan response);
- the OLED STATUS page `BAT` value drawn **inverse**: `8% LOW ~25M`;
- the LOW BATTERY page state line `LOW - CHARGE SOON`;
- iPhone LINK `BATTERY LOW · 8% · …`, top bar `ESP32:8% LOW ~25M`; Android `ESP32:8% LOW ~25M`.

### B4. Cutoff rule (pure C++ `LowCutoff` in battery_model.h)

For each reading, with clean = p75 mV, `f` = the model's filtered mV, and `t` = uptime in s:

1. **Exclusions** reset both counters, and no cutoff happens:
   - cutoff OFF, or no plausible reading (`lostReading`);
   - unstable reading (sample spread > 300 mV), or |clean − previous clean| > 300 mV (USB without
     a battery, the charger output swinging);
   - `f` > 4250 (USB, CV phase), `model.charging`, or the USB hint (B5);
   - a **step rise**: clean − previous clean ≥ +50 mV (charger plugged in, CC rise of 50–150 mV).
     This also blocks counting for **600 s**.
2. **Fast path:** clean < 3100 → `collapse++`. The second such reading ≥ 5 s after the first →
   **cut now**.
3. **Normal:** clean < cutMv **and** f < cutMv → `below++`. At `below` ≥ 3 → **cut**. That is
   ~30–45 s in the warning cadence, ~10–15 s while lit.
4. **Hysteresis:** clean ≥ cutMv + 50 → `below = 0`. Between cutMv and cutMv + 50 the count is
   kept, not reset.
5. Readings are taken by loop() only; the decision runs inside `batteryRead()`, and
   `powerTakeCutoff()` hands it to the sketch once.

### B5. USB detection

Neither VBUS nor VDD_5V has a sense pin. 1.5 uses:

- **Voltage heuristics** (B4): above 4.25 V, the charging trend, a step rise.
- **USB hint** (`MM_USB_SENSE` 1, power.h). GPIO44 is `INPUT_PULLDOWN` (~45 kΩ) and GPIO43 is
  released, so nothing back-feeds the CP2102. A **powered** CP2102 holds its TXD (GPIO44) HIGH at
  UART idle; an unpowered one cannot, so the pin reads LOW. HIGH ⇒ on USB. When the hint is HIGH
  the board runs from USB (Q2 off), so the cell is not at risk. It is sampled with every battery
  reading and at boot.
  - `powerOnUsb()` becomes `gBat.usb || gUsbHint`. The screen's `USB POWER`, heartbeat bit 1 and
    STATUS `charging:true` (no `runMin`) follow automatically. This also fixes README's "full
    cell on USB shows a runtime".
  - **Unverified on hardware.** Ship gate E3-6: on battery only it must read LOW. If it reads
    HIGH, build with `MM_USB_SENSE 0`, because a false HIGH would silently disable the cutoff.
    A false LOW (e.g. a CP2102 suspended on a wall charger) only falls back to the heuristics.

### B6. Boot check (`powerBootCheck(reason)`)

- It runs for `ESP_RST_POWERON`, `ESP_RST_EXT`, `ESP_RST_BROWNOUT`, `ESP_RST_DEEPSLEEP` and
  `ESP_RST_UNKNOWN`. It is skipped for `ESP_RST_SW` (OTA restart: the app expects the board
  back), `PANIC` and the WDTs; the running cutoff covers those within a minute.
- Cutoff OFF → skipped.
- Two blocking readings (B2 sampling) 50 ms apart, before NimBLE, with Vext off. Value = their
  mean. Skipped if either is implausible, unstable, or they differ by > 300 mV.
- **Refuse** when value < cutMv + 100 and the USB hint is LOW:
  - brownout reset → `mmDeepSleepForever()` with no screen;
  - otherwise → `screenBootLowNotice(mv, pct)`: Vext on, 100 ms settle, panel init, frame,
    2000 ms; PRG pressed during it → return and boot normally (escape hatch, also for a USB-only
    board whose charger output happens to read low). Else `mmDeepSleepForever()`.
- A passing reading seeds the model (`gBat.addReading`), so the first STATUS has a battery.

### B7. Runtime counts down to the cutoff

`BatteryModel::floorPct` = `batteryPercentFromMv(cutMv)` (0 when OFF), and
`runtimeMin = cap × (pct − floorPct) / 100 / draw` (floored at 0). `~0M` therefore coincides
with power-off. `%` and "charge left" stay absolute (the cell's own state).

### B8. NVS

Namespace `mm` (unchanged): `batMah` u16 (unchanged) and **`lowCut` u16 mV**. A missing key →
3300; a value not in {0, 3200, 3300, 3400} → 3300. Saves are deferred
(`BAT_CAP_SAVE_DELAY_MS` = 3 s after the last change, one shared timer, each key written only if
it changed) and flushed by power-off. These remain the only flash writes.

### B9. Wire

**CMD** (relay_proto.h):

| Action (aliases) | Params | Result |
|---|---|---|
| `power_off` (`poweroff`, `shutdown`) | `confirm` must be `true` | ok → `RELAY_CMD_POWER_OFF`; errors `"confirm required"`, `"busy"` (OTA receiving) |
| `set_low_cutoff` (`low_cutoff`, `set_cutoff`) | `mv` int: `0` = off, `3200`/`3300`/`3400`; 3000–3600 snaps (< 3250 → 3200, < 3350 → 3300, else 3400) | ok → `RELAY_CMD_SET_CUTOFF` (`c.ms` = mV); `"bad mv"` (missing, not a number, out of range); `"unsupported"` when `!sh.hasBattery` (classic) |

During an off sequence every CMD answers `"powering off"`. All error strings fit `RelayReply.error[25]`.

**STATUS** (proto 3). The new keys come after the existing battery block. **Essential keys come
before the hex and label; diagnostics come last** and are dropped first when the 508-byte limit
is reached:

| Key | Type | When | Meaning |
|---|---|---|---|
| `proto` | int | always | **3** |
| `batLow` | bool | with the battery keys, only when true | warning stage (B3) |
| `cutMv` | int | Heltec, always (even without a reading) | 0 = off, 3200 / 3300 / 3400 |
| `conn` | [int, int, int] | over BLE (diagnostic, last) | the **reading phone's** link: interval (1.25 ms units), peripheral latency, supervision timeout (10 ms units), from `onRead(c, desc)` |
| `btSleep` | bool | when modem sleep is active (diagnostic, last) | the wrap took effect (C1) |
| `advMaxUs` | int | `MM_DEBUG_TIMING` builds only | longest `advApply()` since boot, µs |

Key order: `ok, error, running, proto, fw, board, keepAwake, …loops…, wakeupPreambleMs,
commandBurstMs, starlightBurstMs, txPowerLevel, txInterleave, uptimeS, sent, batMv, batPct,
batMah, runMin|charging, batLow, cutMv, items, <program hex>, <label>, conn, btSleep, advMaxUs`.

Size check (worst case: an error, the wand loop at 60000 ms, every battery key, batLow): the
short fields are ~406 bytes, + hex (29 bytes) = ~486 ≤ 508, so the hex always fits. The label is
dropped in that extreme case, which is the existing documented rule. `conn` and `btSleep` fit in
every normal status.

Example (Heltec, 1.5, idle, low):
```
{"ok":true,"running":true,"proto":3,"fw":"1.5","board":"HELTEC V3","keepAwake":false,"wakeupPreambleMs":520,"commandBurstMs":4000,"starlightBurstMs":500,"txPowerLevel":3,"txInterleave":false,"uptimeS":8123,"sent":42,"batMv":3381,"batPct":17,"batMah":400,"runMin":51,"batLow":true,"cutMv":3300,"conn":[24,2,400],"btSleep":true}
```

**Heartbeat** (`FF FF 'M' 'B' 01 <pct> <flags> <runMin LE>`): flags **bit 3 = low** (B3). The
version byte stays 1, because older parsers ignore unknown bits.

### B10. Device UX: LOW BATTERY page

```
LOW BATTERY            o o o # o
- - - - - - - - - - - - - - - - -
CUT  3.30V                 <- inverse while stepping (like CAP on DEVICE); "OFF" when off
BAT  3.92V 68%             <- "--" without a reading
     OK                    <- LOW - CHARGE SOON | CHARGING | USB POWER | --
LOW  BELOW 3.40V
     OFF AT ~10% LEFT      <- ~5% / ~18% ; "NO AUTO POWER-OFF" when OFF
HOLD PRG: NEXT LEVEL
```

Tap = next page (POWER). **Hold 1 s = next level, again every 1 s while held, at most one round
(4 steps)**. The order is 3.20 → 3.30 → 3.40 → OFF → 3.20 (ascending, OFF after the highest, as
the capacity presets do). It is saved 3 s after the last change. It cannot be confused with
power-off: it is a different page, the action is reversible, the value changes visibly, and
there is no bar. Reaching POWER needs a release and a new press there.

### B11. App UX

**iPhone, SETTINGS → BOARD POWER** (new section after BOARD FIRMWARE, shown when the backend is
the ESP32), in both themes:

- `LOW-BATTERY CUTOFF` chips **OFF · 3.20V · 3.30V · 3.40V**. Shown only when STATUS has `cutMv`
  (Heltec 1.5+); dimmed, with taps ignored, while not linked. A tap →
  `set_low_cutoff {"mv":…}` → STATUS refresh. Caption: "Turns the board off at this voltage
  (about 5 / 10 / 18 % left) so the battery is never run flat. Press RST on the board to turn it
  on again after charging." State line `BATTERY  LOW · 8%` in amber/ALARM while `batLow`.
- **POWER OFF** button (error / ALARM colour). Shown when linked and `proto ≥ 3`. Confirm:
  title "Power off the ESP32?", message "It stops transmitting and disconnects. Press RST (EN on
  a DevKit) on the board to turn it on again. It still charges while off.", buttons
  **POWER OFF** (destructive) / **CANCEL**. On ok: `esp32PoweredOff = true`, status message
  "ESP32 powering off — press RST on the board to turn it on". The flag is cleared on the next
  relay-command-ready.
- Not linked and `esp32PoweredOff` → line "POWERED OFF — PRESS RST ON THE BOARD". Linked with
  `proto < 3` → "Needs board firmware 1.5 — update it in BOARD FIRMWARE."
- Unexpected link loss when the last status had `batLow` → status message "ESP32 off: battery
  low — charge it, then press RST".
- No settings push on link: **the board is the authority** for the cutoff (NVS), and both UIs
  edit it.

**LINK tab** (standard + VFD): `BATTERY` text gets the `LOW · ` prefix, and a new row
**`LINK  30 MS · LAT 2 · TO 4 S`** (+ ` · MODEM SLEEP`) from `conn` / `btSleep`.

**Android:** `Esp32Heartbeat.low` (bit 3); the token is `ESP32:8% LOW ~25M` (charging still
wins: `ESP32:CHG`). `telemetryLineText` needs no change.

---

## C. Efficiency

Rule: **no added transmit lag.** Connection parameters, beacon intervals and powers are
unchanged. The only latency effects are the ≤ 8 ms reading window (B2) and the modem-sleep
wake-up (C4), each with a ship gate.

### C1. Implemented in 1.5

| Measure | Expected saving | Lag | Gate / fallback |
|---|---|---|---|
| **Real off** (A) | ~35 mA → ~15–25 µA while off | — | E3-1: ≤ 30 µA (V3.2) / ≤ 40 µA (V3.0/3.1) in the battery lead |
| **Low-battery cutoff** (B) | keeps 5–18 % in the cell; no deep discharge | — | E3-5 |
| **BLE modem sleep (S3)**: link-time wrap of `esp_bt_controller_init`, `sleep_mode = ESP_BT_SLEEP_MODE_1`, `sleep_clock = ESP_BT_SLEEP_CLOCK_MAIN_XTAL` | **est. 3–10 mA** of the ~35 mA base (PHY/RF off between radio events; unmeasured) | phone→board writes: none (they arrive in events the controller wakes for). Host commands to a sleeping controller: ≤ 2.5 ms (`BTDM_MODEM_WAKE_UP_DELAY`), bounded at ~15 ms for the ~6 HCI commands of an advert restart | E3-2/E3-3: soak; `advApply` p99 ≤ 20 ms; OTA throughput within 10 %. Fallback: remove the link flag (CI, one line) or `-DMM_BT_MODEM_SLEEP=0` |
| **UART0 pads released** (`MM_UART_RELEASE` 1): GPIO43 → INPUT, GPIO44 → INPUT_PULLDOWN after boot | **0 – ~1 mA** (no 3.3 V drive through 499 Ω into the unpowered CP2102) + ≤ 60 µA (ROM pull-up on GPIO44) | none | E3-2 A/B. Cost: no serial logs or panic text after boot (the firmware never uses `Serial`; flashing is unaffected, the ROM re-muxes the pads). `MM_UART_RELEASE 0` restores them |
| **CPU 80 MHz first** (setup line 1) | ~10 mA × ~0.1 s per boot | none | — |
| **Model seeds**: `DRAW_BEACON_MA` 8 → **10** (from PDU timings); `DRAW_BASE_MA` stays 37.5 until measured | better runtime numbers | — | E3-2: re-seed both from the battery-lead readings |

### C2. Rejected for 1.5

| Idea | Why not |
|---|---|
| CPU 40 MHz | Impossible while BLE is up (the `bt` PM lock holds APB at 80 MHz; Arduino 2.0.17 `calculateApb()` is fixed at 80 MHz on the S3). Before init or after shutdown it would save ~9 mA for ~2 s. |
| Change connection parameters (timeout 4 s → 6 s, more latency) | If iOS rejects today's request it now runs latency 0; making the request valid could switch latency 2 on and add up to ~60–120 ms to the first tap after idle, for ≤ ~1 mA. 1.5 reports `conn` instead; decide with data. |
| Fast parameters on activity | A parameter update takes effect ≥ 6 events later, so it cannot speed up the write that triggered it. |
| Idle advertising 1022.5–1285 ms after 5 min unlinked | ~0.2 mA (< 1 %) in exchange for a slower (background) relink. |
| OLED contrast 0x40 | Saves a few mA only while lit (~10 s per press, ≈ 0.3 mAh/day); hurts sunlight legibility. |
| Idle/link TX power below +3 dBm | < 0.02 mA. |
| **Non-connectable beacon while linked** | ~2–3 mA during bursts and keep-awake, but two unknowns: does the S3 controller accept ADV_NONCONN at 20–30 ms in this core, and do bands react the same? **Candidate for 1.5.x** after a band test. |
| **Slower keep-awake stream** (40–60 ms) | Could cut keep-awake's ~10 mA, but band wake reliability is unknown. Candidate for 1.5.x, test with a band. |
| Fewer loop wake-ups, a different ADC period, LED changes | each < 0.05 mA; LED patterns are a user rule. |
| PM build (light sleep, tickless, 32 kHz crystal) | Could reach ~1–3 mA idle, but needs a custom sdkconfig (pioarduino / IDF + Arduino component), NimBLE 2.x, a CI rework, and loses plain Arduino IDE builds. Separate project. |
| Gate the USB-Serial-JTAG controller and PHY | Unknown gain, unclear API in this core; measure first. |
| `NimBLEDevice::deinit()` before sleep | No current benefit (deep sleep forces BT off); untested hang risk. |

### C3. Expected runtime on 400 mAh (model figures; to the 3.30 V cutoff = 360 mAh)

| Use | Today (model) | 1.5 without modem sleep | 1.5 with modem sleep (−5 mA, mid-estimate) |
|---|---|---|---|
| Idle, no phone, dark | 38.0 mA | 9.5 h | ~10.7 h |
| iPhone linked, idle | 38.5 mA | 9.4 h | ~10.7 h |
| Keep-awake on | 48.5 mA (beacon 10 mA) | 7.4 h | ~8.3 h |
| Off | — | ~20 µA: shelf life is set by the cell's self-discharge, not the board | |

After a 3.30 V cutoff the cell holds ~20–40 mAh, enough for 6–12 weeks at ~20 µA. **Recharge
within a month.** Hardware notes for the README: charge current ~500 mA = **1.25 C** for a
400 mAh cell (board design, not firmware); measure current **in the battery lead**, because a
USB meter on a PC port includes ~20 mA of enumerated CP2102 drawn from USB.

### C4. Modem sleep mechanics

`btsleep.h` (new, included once by the `.ino`):

```cpp
#pragma once
#include "board.h"
#if MM_HELTEC_V3 && defined(CONFIG_IDF_TARGET_ESP32S3)
#include <esp_bt.h>
#ifndef MM_BT_MODEM_SLEEP
#define MM_BT_MODEM_SLEEP 1
#endif
static volatile bool gBtModemSleep = false;   // STATUS "btSleep"
// Active only when linked with -Wl,--wrap=esp_bt_controller_init (CI / PlatformIO). Without the
// flag nothing references it and --gc-sections drops it: Arduino IDE builds stay as they are.
extern "C" esp_err_t __real_esp_bt_controller_init(esp_bt_controller_config_t* cfg) __attribute__((weak));
extern "C" esp_err_t __wrap_esp_bt_controller_init(esp_bt_controller_config_t* cfg) {
#if MM_BT_MODEM_SLEEP
  cfg->sleep_mode = ESP_BT_SLEEP_MODE_1;            // PHY/RF off between radio events
  cfg->sleep_clock = ESP_BT_SLEEP_CLOCK_MAIN_XTAL;  // the only LP clock without PM in this core
#endif
  const esp_err_t err = __real_esp_bt_controller_init(cfg);
  gBtModemSleep = MM_BT_MODEM_SLEEP && err == ESP_OK;
  return err;
}
#endif
```

- **CI** (`esp32-firmware.yml`, Heltec compile only): `arduino-cli compile --build-property
  "compiler.c.elf.extra_flags=-Wl,--wrap=esp_bt_controller_init" …`. Then a check step fails the
  build if the ELF lacks the symbol: `xtensa-esp32s3-elf-nm build-heltec-v3/*.ino.elf | grep -q
  __wrap_esp_bt_controller_init` (nm from `~/.arduino15/packages/esp32/tools/xtensa-esp32s3-elf-gcc/*/bin`).
- **PlatformIO** (README note and the local scratch project): `build_flags =
  -Wl,--wrap=esp_bt_controller_init` in the Heltec env only.
- **Classic ESP32:** untouched. Its core already runs ORIG modem sleep.
- **Timing hook:** `MM_DEBUG_TIMING` (default 0) wraps `advApply()` with `esp_timer_get_time()`
  and keeps the maximum (`advMaxUs` in STATUS), for E3-3.

---

## D. File-by-file changes

Firmware folder `firmware/esp32-transmitter/` (do not touch `sync_*.h`).

**`board.h`**
- `MM_FW_VERSION "1.5"`; `MM_RELAY_PROTO 3` (comment: "3: power_off, set_low_cutoff, cutMv /
  batLow, conn / btSleep diagnostics").
- Heltec pins: `HV3_UART_TX_PIN 43`, `HV3_UART_RX_PIN 44`.
- Defaults with `#ifndef`: `MM_USB_SENSE 1`, `MM_UART_RELEASE 1`, `MM_DEBUG_TIMING 0`. Document
  `MM_BT_MODEM_SLEEP` (btsleep.h) and the link flag.

**`btsleep.h`** (new): as in C4.

**`shutdown.h`** (new, both boards): `MmOffReason`, `mmReleaseSleepHolds()`,
`mmDeepSleepForever()` exactly as in A4. Included after `oled_ui.h` (it uses `screenPowerOff`
and `loraSleep`).

**`battery_model.h`** (pure C++)
- Header comment: the seeds are measured **in the battery lead**; the line 26 comment becomes
  "BLE controller; modem sleep only in builds with the link wrap (btsleep.h)".
- `DRAW_BEACON_MA` 8 → 10.
- Cutoff constants: `CUT_PRESETS_MV[] = {3200, 3300, 3400}`, `CUT_DEFAULT_MV 3300`,
  `LOW_WARN_BASE_MV 3300`, `LOW_WARN_MARGIN_MV 100`, `LOW_WARN_HYST_MV 50`, `CUT_READINGS 3`,
  `CUT_RESET_MARGIN_MV 50`, `CUT_COLLAPSE_MV 3100`, `CUT_COLLAPSE_GAP_S 5`,
  `CUT_UNSTABLE_MV 300`, `CUT_STEP_RISE_MV 50`, `CUT_STEP_HOLDOFF_S 600`, `BOOT_MARGIN_MV 100`.
- `BatteryModel`: `float floorPct` + `setFloorPct()`; `runtimeMin()` uses `pct − floorPct`
  (≥ 0).
- `struct LowCutoff { int32_t cutMv; bool low; uint8_t below, collapse; uint32_t collapseT;
  bool haveLast; int32_t lastMv; uint32_t holdOffUntil; void begin(int32_t); int32_t warnMv()
  const; bool near(float filtMv) const; bool onReading(uint32_t tS, int32_t cleanMv, bool
  unstable, const BatteryModel& m, bool usbHint); static bool bootRefuse(int32_t cutMv,
  int32_t mv, bool usbHint); static int32_t snap(int32_t mv); static int32_t next(int32_t mv);
  }` implementing B3/B4 (`onReading` returns true = power off now; it also updates `low`).

**`power.h`**
- Header comment: cutoff, p75 sampling, the two NVS keys ("the only flash writes").
- Constants: `BAT_SAMPLES 32`, `BAT_SAMPLE_GAP_US 250`, `BAT_CLEAN_RANK 24`,
  `BAT_PERIOD_NEAR_MS 15000`, `BAT_PERIOD_FAST_MS 5000`, `POWER_NVS_CUT_KEY "lowCut"`,
  `CUTOFF_PRESET_COUNT 4` (with OFF).
- `uartRelease()` (`MM_UART_RELEASE` / `MM_USB_SENSE`); `gUsbHint` sampled in `batteryRead()`
  and at boot. The first boot read waits ≥ 1 ms after the pull-down is set (`powerBootCheck`
  runs well after it).
- `powerBegin()`: reads `lowCut`, `gCut.begin()`, `gBat.setFloorPct()`; divider level from
  GPIO37 with INPUT_PULLDOWN (HIGH → on = LOW; LOW → on = HIGH), then INPUT; fallback trial kept.
- `batteryRead()`: 32 spaced samples, sort, p75, unstable flag; feeds `gBat` and then
  `gCut.onReading()` → `gCutoffDue`.
- `powerPoll()`: cadence near/fast; no deferral in the warning zone; one save timer
  (`gPwrSavePending`) for capacity + cutoff.
- New API: `powerBootCheck(esp_reset_reason_t)` → bool refuse (B6, blocking reads);
  `powerTakeCutoff()`; `powerCutoffMv()`; `powerSetCutoff(int32_t mv, uint32_t now)` (snapped;
  updates floorPct; deferred save); `powerCycleCutoff(now)`; `powerBatteryLow()`;
  `powerFlushSaves()`; `powerOnUsb()` → `gBat.usb || gUsbHint`; `powerNextDueMs()` covers the new
  cadences.

**`oled_pages.h`**
- Pages enum (A1); `ScreenModel` += `int32_t cutMv; bool batLow; bool cutMark; uint16_t
  powerPermille; uint8_t offStage /* SCREEN_OFFST_NONE, _RELEASE, _GOING, _LOW, _BOOT_LOW */; bool
  otaBusy;`.
- `scrHeaderPlain()`, `scrPageCutoff()`, `scrPagePower()`, `scrPageOff()` (the three off frames
  plus boot-low), and `scrBatteryStatus()` adding `LOW` (STATUS line drawn with
  `scrValueInverse` when `batLow`). `scrDrawPage()` dispatches: `offStage` ≠ NONE wins over the
  page.

**`oled_ui.h`**
- Header comment: 5 pages, the LOW BATTERY and POWER gestures, the boot-notice exception.
- Constants: `POWER_HOLD_MS 2000`, `POWER_TAP_MS 400`, `POWER_OFF_RELEASE_MAX_MS 10000`,
  `SCREEN_BOOT_NOTICE_MS 2000`.
- `gBtnOnDevice` → `uint8_t gBtnHoldPage` (DEVICE / CUTOFF / POWER / none). CUTOFF hold steps
  `powerCycleCutoff()` (≤ 4), with `gScrCutMarked` like `gScrCapMarked`. POWER hold →
  `gScrPowerOffReq` at 2 s unless `otaBusy()`; tap/cancel rules from A2.
- New API: `screenTakePowerOffRequest()`, `screenShowOff(uint8_t stage)` (keeps the panel lit, no
  timeout), `screenPrgDown()` (debounced, for `OFF_WAIT_RELEASE`), `screenBootLowNotice(int32_t
  mv, int pct)` → bool startAnyway (blocking; used in setup).
- `screenNextDueMs()`: POWER hold deadline; frames every 250 ms during the hold (bar).
- `screenDraw()` fills the new model fields.

**`relay_proto.h`** (pure; host-tested)
- `RelayAction` += `RELAY_ACT_POWER_OFF`, `RELAY_ACT_SET_CUTOFF`; names `power_off`,
  `poweroff`, `shutdown`, `set_low_cutoff`, `low_cutoff`, `set_cutoff`.
- `RelayCmdType` += `RELAY_CMD_POWER_OFF`, `RELAY_CMD_SET_CUTOFF`.
- `RelayShadow` += `bool hasBattery`.
- `relayParseCommand()`: B9 rules (`relayBoolParam(…"confirm", false)`, `relayIntParam(…"mv",
  INT32_MIN)` + snap).
- `RelaySnapshot` += `int16_t cutMv` (−1 = absent), `bool batLow`, `bool btSleep`, `uint32_t
  advMaxUs`.
- `struct RelayLinkInfo { bool valid; uint16_t itvl, latency, timeout; }`;
  `relayFormatStatus(s, r, uptimeS, proto, fw, board, link, out, cap)`: key order and drop
  order from B9.

**`relay_engine.h`**: `void halt()`: clears `job`, `program`, `slotFull`, `loopRearm`. Nothing
else changes (unknown command types already fall through `apply()`).

**`ota.h`**: `otaBusy()` (`gOtaState == OTA_ST_RECEIVING`), `otaCancelRestart()`
(`gOtaRebootAt = 0`). Nothing in the wire protocol changes.

**`esp32-transmitter.ino`**
- Includes `btsleep.h` (after board.h) and `shutdown.h`; the header comment's Power paragraph is
  updated.
- Constants `POWER_OFF_NOTICE_MS 1000`, `POWER_OFF_GRACE_MS 750`, `POWER_OFF_LINK_WAIT_MS 500`.
- `setup()` order from A5. Classic: `setCpuFrequencyMhz(80)` and `mmReleaseSleepHolds()` first,
  `gShadow.hasBattery = false`.
- `CommandCallbacks::onWrite`: `gOffPending` → `"powering off"`; `RELAY_CMD_POWER_OFF` with
  `otaBusy()` → `"busy"`, not queued.
- `StatusCallbacks`: override `onRead(NimBLECharacteristic*, ble_gap_conn_desc*)`, building
  `RelayLinkInfo` from `desc->conn_itvl`, `conn_latency`, `supervision_timeout`.
- `loop()`: `if (offService(millis())) return;` after `otaLoop()`. Command drain intercepts
  `POWER_OFF` → `beginPowerOff(MM_OFF_APP)` and `SET_CUTOFF` → `powerSetCutoff()`; the rest goes
  to `gEngine.apply()`. After `screenPoll()`/`powerPoll()`: `screenTakePowerOffRequest()` →
  `MM_OFF_BUTTON`; `powerTakeCutoff()` → `MM_OFF_LOW`.
- `heartbeatBytes()`: `if (powerBatteryLow()) flags |= 0x08;`.
- `publishSnapshot()`: `cutMv` (Heltec), `batLow`, `btSleep`, `advMaxUs`.
- `ServerCallbacks::onConnect`: request **unchanged** (`24, 40, 2, 400`), with a comment
  pointing to C2.

**`test/host/`** (relay_proto tests only)
- `test_relay.cc` (new, C++17, sanitizers, the Makefile's warning set). Cases: `power_off` with
  and without `confirm`, quoted `"true"`, aliases; `set_low_cutoff` with 0 / 3200 / 3300 / 3400,
  snapping (3249 → 3200, 3250 → 3300, 3600 → 3400), quoted digits accepted (`"3300"`, as
  `relayJsonInt` allows), `"bad mv"` (2999, 3601, missing, a non-numeric string),
  `"unsupported"` without a battery; STATUS: `proto 3`, `cutMv` with no reading, `batLow` only
  when true, key order, `conn` / `btSleep` after the hex and label, worst case ≤ 508 with the hex
  kept, diagnostics dropped first.
- `Makefile`: `$(BUILD)/test_relay` in `all` and `test`, plus a `relay` target that builds and
  runs only it.

**`README.md`**
- What it does: power off (POWER page, app), low-battery cutoff.
- Heltec section: the 5-page cycle, LOW BATTERY and POWER rows in the page table, the
  boot-notice exception, the PRG + RST download-mode warning.
- Power notes: the off state (what is parked, ~15–25 µA, charging while off, unplug for storage,
  no software battery switch; V3.0/3.1 divider leak).
- Battery: p75 sampling, warning, cutoff rules, boot check, USB hint, runtime to cutoff, measure
  in the battery lead (replaces line 239's USB-meter advice), no on-board over-discharge
  protection, 1.25 C charge note, recharge within a month after a cutoff.
- Power (backpack): **correct lines 272–277** (S3 modem sleep is available at runtime; NimBLE's
  default config disables it; CI builds enable it with a link-time wrap; Arduino IDE builds don't
  get it). Latency note: the first write after idle can wait up to (L+1) intervals.
- Tuning table: `POWER_HOLD_MS`, `BAT_PERIOD_NEAR_MS`, `MM_USB_SENSE`, `MM_UART_RELEASE`,
  `MM_BT_MODEM_SLEEP`.
- PlatformIO note: the Heltec `build_flags`.
- Protocol reference: the two actions, the STATUS keys, proto 3, heartbeat bit 3, the 1.5 example.

**CI `.github/workflows/esp32-firmware.yml`**: a "Relay protocol host test" step (`make -C
firmware/esp32-transmitter/test/host relay`); the Heltec compile with `--build-property`; the
ELF wrap check (C4); `firmware/esp32-transmitter/test/host/**` added to the paths. The classic
compile is unchanged.

**iOS**
- `BLE/AndroidRemoteClient.swift`: parse `cutMv` → `lowCutoffMv: Int?`, `batLow` →
  `batteryLow: Bool`, `conn` → `linkParams: [Int]?`, `btSleep` → `btModemSleep: Bool`.
  `esp32BatteryText` gets the `LOW · ` prefix; new `esp32LinkText` ("30 MS · LAT 2 · TO 4 S",
  "+ · MODEM SLEEP"; interval × 1.25 ms, timeout × 10 ms).
- `Views/AppTheme.swift` `esp32BatteryToken`: `ESP32:8% LOW ~25M`.
- `ViewModels/AppViewModel.swift`: `setEsp32LowCutoff(_:)`, `powerOffEsp32()`, `@Published
  esp32PoweredOff`, the low-battery disconnect message (B11).
- `Views/SettingsScreen.swift`: `SettingsBoardPowerSection` after `SettingsFirmwareSection`.
- `VFD/VFDSettingsScreen.swift`: `boardPower(ctx, c, y, w)` after `firmware()`
  (`VFDW.section`, `VFDW.options` label `LOW CUTOFF`, `VFDW.kv`, `VFDW.button` alarm →
  `ctx.confirm`); header comment lists the section. No VFD golden impact (the goldens cover only
  `vfd.py` / `widgets.py`).
- `Views/LinkScreen.swift`, `VFD/VFDLinkScreen.swift`: the `LINK` row.

**Android** (only these, while the sync workflow runs): `ble/Esp32Heartbeat.kt` (`val low:
Boolean = false` last; bit 3; token) and `Esp32HeartbeatTest.kt` (`flags 0x0C` → `ESP32:8% LOW
~25M`; `0x0D` → `ESP32:CHG`). `telemetryLineText` unchanged.

**User guide** `tools/guide/build_guide.py` → `docs/ESP32_User_Guide.pdf` (`python3
tools/guide/build_guide.py`)
- `FW_VERSION = "1.5"`, "relay protocol 3", docstring "(firmware 1.5)".
- New screens drawn with the firmware layout: `screen_cutoff()`, `screen_power(permille)`,
  `screen_off(stage)`, `screen_boot_low()`; `screen_status(bat="8% LOW ~25M", inverse)`.
- 4.1 page order; **new 4.6 LOW BATTERY page**; **new 4.7 Turning the board off and on**
  (gesture, safety, RST, download-mode warning, charging while off, storage).
- 5.3 runtime table (C3, to the cutoff); 5.4 **replace the "No low-battery protection" callout**
  with the cutoff summary, and update the "no USB-sense pin" paragraph (USB hint); 5.5 correct
  "no Bluetooth modem sleep", add the UART pads; **new 5.7 Low-battery cutoff** (B1–B7 in plain
  words); **new 5.8 Off and storage**.
- 6.3 LINK rows (`LOW`, `LINK`); 6.7/6.8 `LOW` tokens; **new 6.9 BOARD POWER** (both themes);
  9.5 cross-reference; 11.1 STATUS fields; 11.4 heartbeat bit 3; 11.5 the two commands; 11.7
  build-time settings.

---

## E. Verification

**E1. Host:** `make -C firmware/esp32-transmitter/test/host test` (sync + the new relay test)
passes. `LowCutoff` is pure; exercise it with a scratchpad harness during implementation
(sequences: slow fall, TX-dip noise, step rise, USB, collapse). Committing that test is outside
this round's allowed test scope.

**E2. Builds** (one at a time): PlatformIO `heltec_v3` with the wrap flag and `esp32dev`; CI's
two arduino-cli builds; the ELF wrap check; Heltec image size within the OTA slot; images carry
`MMFW:1.5:…`.

**E3. Bench** (Heltec V3; meter in the **battery lead**; USB unplugged unless stated):

1. **Off current** after a POWER hold: ≤ 30 µA (V3.2), ≤ 40 µA (V3.0/3.1, full cell). If it is
   > 100 µA, check the LED, Vext and LoRa holds.
2. **Running A/B** (wrap on / off; `MM_UART_RELEASE` 1 / 0): dark + no phone, linked idle,
   keep-awake, lit. Record in the README; re-seed `DRAW_BASE_MA` / `DRAW_BEACON_MA`.
3. **Modem-sleep soak:** 2 h linked to an iPhone. No unexpected disconnects; 200 sends with none
   lost; `advMaxUs` (debug build) p99 ≤ 20 ms; one full OTA update with throughput within 10 % of
   the wrap-off build; bands still wake on keep-awake. Any failure → ship without the flag.
4. **Power cycle:** POWER hold → RST → normal boot (dark screen, 1 s blinks, relink, programs
   off). PRG held over RST → download mode (documented).
5. **Cutoff** with a bench supply on the battery connector, stepping down 10 mV / 30 s from
   3.45 V: `batLow` / bit 3 / inverse LOW below 3.40 V; off within ~45 s below 3.30 V; collapse to
   3.05 V → off within ~5–10 s; 3.36 V + RST → refusal notice, and PRG during it starts anyway;
   3.41 V + RST → boots; OFF setting → no power-off.
6. **USB hint:** STATUS `charging`/USB on a PC port and on a wall charger; **must be false on
   battery only** (else `MM_USB_SENSE 0`).
7. **Safety:** PRG held from dark for 20 s → STATUS only, then dark; POWER tap → STATUS; hold
   1.5 s → cancels and stays; hold 2 s → off; LOW BATTERY hold steps one round at most.
8. **Classic DevKit:** `power_off` from the app → LED stops, the iPhone shows POWERED OFF, EN
   restarts.
9. **STATUS `conn`** on the iPhone: record what iOS actually negotiated (input for the 1.5.x
   latency decision).

---

## F. Risks and open items

- **Modem sleep on the S3 without PM is unmeasured at runtime** (link stability, OTA, beacon
  start). Gated by E3-3, and reversible by removing one link flag.
- **USB hint unverified.** A false HIGH would disable the cutoff. Gated by E3-6; `MM_USB_SENSE 0`.
- **Off current depends on the revision** (V3.0/3.1 leak) and on the cell's own protection
  circuit. Which revision and cell the user has is unknown.
- **ADC accuracy** is per board (±30–100 mV), so "3.30 V" can be 3.25–3.35 V real. p75 adds about
  +5–10 mV.
- **Boot refusal on a USB-only board** with an odd charger output: mitigated by the stability
  checks, the USB hint and the PRG escape.
- **UART release** loses serial logs/panic text on a PC (`MM_UART_RELEASE 0` for debugging).
- **The reset reason after RST from deep sleep** is inferred (POWERON); only the brownout branch
  depends on it.
- **iOS parameters** stay as negotiated today; `conn` makes them visible.
- **Future sync hub** (LittleFS) must flush in `OFF_SLEEP`.
- No meter or hardware was available for this plan: every mA figure outside the datasheet tables
  is an estimate.
