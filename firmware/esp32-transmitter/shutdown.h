// Power-off of the MagicMaker ESP32 transmitter: the deepest state software can reach.
//
// The Heltec V3 has no software path to its battery (the 3V3 regulator's enable is tied to its
// input, and the battery switch is driven by USB, not a GPIO), so "off" is ESP32-S3 deep sleep
// with NO wake source and every pin parked. Only RST (EN on a DevKit) starts the board again: a
// power-on-type reset that also clears the pad holds. Expected draw at the battery ~15-25 uA on a
// V3.2 (V3.0/V3.1 up to ~9 uA more through the battery divider), against ~35 mA running. Charging
// still works while off (the charger runs from USB). True zero means unplugging the battery.
//
// Classic DevKit: the ESP32 itself drops to ~10 uA, but the DevKit's regulator and USB-UART
// usually keep drawing a few mA.
//
// The NimBLE stack is not shut down first: deep sleep forces the BT and RF domains off anyway,
// and NimBLEDevice::deinit() from loop() is untested in NimBLE-Arduino 1.4.3.
//
// Heltec: include after oled_ui.h (screenPowerOff()) and power.h (loraSleep()).
#pragma once

#include "board.h"
#include <esp_sleep.h>
#include <driver/gpio.h>
#if MM_HELTEC_V3 || defined(CONFIG_IDF_TARGET_ESP32)
#include <driver/rtc_io.h>
#endif

// Why the board turns itself off (the sketch's beginPowerOff()).
enum MmOffReason : uint8_t { MM_OFF_BUTTON = 0, MM_OFF_APP, MM_OFF_LOW };

#if MM_HELTEC_V3
// RTC pads held at a level through deep sleep: the SX1262 bus (asleep; NSS high keeps it asleep).
struct MmPadLevel { uint8_t pin; uint8_t level; };
static const MmPadLevel HV3_SLEEP_HOLD[] = {
    {HV3_LORA_NSS_PIN, 1}, {HV3_LORA_SCK_PIN, 0}, {HV3_LORA_MOSI_PIN, 0}, {HV3_LORA_RST_PIN, 1}};
// RTC pads isolated (no input, no output, no pulls, held): VBAT ADC, header pins, LoRa MISO /
// BUSY / DIO1, OLED SDA / SCL / RST.
static const uint8_t HV3_SLEEP_ISOLATE[] = {1, 2, 3, 4, 5, 6, 7, 11, 13, 14, 17, 18, 21};
// Never touched: 0 (PRG: strapping, R7 pull-up), 15/16 (32 kHz crystal pads), 19/20 (USB D- / D+,
// header pins left to the USB PHY).
// Digital pads (26-48): IDF isolates every one that is not held (35 LED, 36 Vext) at sleep entry,
// which covers 37 (divider switch) and 43 / 44 (UART to the unpowered CP2102).
#endif

// setup(), right after setCpuFrequencyMhz(80): undo any hold left by a previous sleep (a no-op
// after RST, needed after esp_restart() or a future timer wake). A held pad ignores pinMode().
static void mmReleaseSleepHolds() {
#if MM_HELTEC_V3
  gpio_deep_sleep_hold_dis();
  gpio_hold_dis((gpio_num_t)HV3_LED_PIN);
  gpio_hold_dis((gpio_num_t)HV3_VEXT_PIN);
  for (const MmPadLevel& h : HV3_SLEEP_HOLD) {
    rtc_gpio_hold_dis((gpio_num_t)h.pin);
    rtc_gpio_deinit((gpio_num_t)h.pin);
  }
  for (uint8_t p : HV3_SLEEP_ISOLATE) {
    rtc_gpio_hold_dis((gpio_num_t)p);
    rtc_gpio_deinit((gpio_num_t)p);
  }
#elif defined(CONFIG_IDF_TARGET_ESP32)
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
  // rtc_gpio_isolate() turns the RTC side's input, output and pulls off and holds the pad, but it
  // does not route the pad to the RTC mux: a pad still in digital mode would keep its IO_MUX input
  // enable latched through the sleep, a floating input (GPIO1-3 come out of reset with it on, 9-14
  // and 17/18 after the ROM; MISO, BUSY, SDA and SCL are inputs here). Route each pad to the RTC
  // side first, as IDF's own ext1 wake-up set-up does; mmReleaseSleepHolds() routes them back.
  for (uint8_t p : HV3_SLEEP_ISOLATE) {
    rtc_gpio_init((gpio_num_t)p);
    rtc_gpio_isolate((gpio_num_t)p);
  }
  gpio_deep_sleep_hold_en();           // 35/36 keep their level; IDF isolates 37, 43, 44, 33-48 at entry
#else
  digitalWrite(MM_STATUS_LED_PIN, LOW);
#if defined(CONFIG_IDF_TARGET_ESP32)
  rtc_gpio_isolate(GPIO_NUM_12);       // IDF's own deep-sleep advice (WROVER pull-up on MTDI)
#endif
#endif
  esp_sleep_disable_wakeup_source(ESP_SLEEP_WAKEUP_ALL);   // no PRG wake: ext0 alone costs ~120 uA
  esp_sleep_pd_config(ESP_PD_DOMAIN_RTC_PERIPH, ESP_PD_OPTION_OFF);
  esp_sleep_pd_config(ESP_PD_DOMAIN_RTC_SLOW_MEM, ESP_PD_OPTION_OFF);
  esp_deep_sleep_start();
  for (;;) {}
}
