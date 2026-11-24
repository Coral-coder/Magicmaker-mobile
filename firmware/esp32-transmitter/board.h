// Board selection for the MagicMaker ESP32 transmitter.
//
// One sketch, two builds:
//   * any classic ESP32 (DevKit / WROOM / WROVER): BLE relay + status LED, nothing else;
//   * Heltec WiFi LoRa 32 V3 / V3.1 / V3.2 (ESP32-S3): the same relay, plus the onboard OLED,
//     lit only while you use the PRG button (see oled_ui.h).
//
// The Heltec build is picked at compile time, so no extra build flags are needed: the core's
// heltec_wifi_lora_32_V3 variant defines WIFI_LoRa_32_V3, arduino-cli defines
// ARDUINO_heltec_wifi_32_lora_V3 and PlatformIO ARDUINO_heltec_wifi_lora_32_V3. On any other
// ESP32-S3 board with the same wiring, build with -DMM_BOARD_HELTEC_V3.
#pragma once

#include <Arduino.h>

#if defined(MM_BOARD_HELTEC_V3) || defined(WIFI_LoRa_32_V3) || \
    defined(ARDUINO_heltec_wifi_32_lora_V3) || defined(ARDUINO_heltec_wifi_lora_32_V3)
#define MM_HELTEC_V3 1
#else
#define MM_HELTEC_V3 0
#endif

// Shown on the OLED's DEVICE page and in STATUS ("fw"). Bump it when the firmware's behaviour changes.
#define MM_FW_VERSION "1.2"
// Relay protocol version in STATUS ("proto"). 2: chip-side keep-awake / loops / settings, full
// STATUS object (the app treats a STATUS without "running" as firmware before 1.2).
#define MM_RELAY_PROTO 2

#if !MM_HELTEC_V3
#define MM_BOARD_LABEL "ESP32"
#endif

#if MM_HELTEC_V3
#define MM_BOARD_LABEL "HELTEC V3"

// Heltec WiFi LoRa 32 V3 pin map (the variant's Vext / RST_OLED / SCL_OLED / SDA_OLED / LED,
// spelled out here so a -DMM_BOARD_HELTEC_V3 build on another S3 variant gets the same pins).
static const uint8_t HV3_LED_PIN      = 35;  // white LED (LED_BUILTIN)
static const uint8_t HV3_VEXT_PIN     = 36;  // Vext rail switch: LOW = on, HIGH = off (powers the OLED)
static const uint8_t HV3_OLED_RST_PIN = 21;  // SSD1306 reset
static const uint8_t HV3_OLED_SCL_PIN = 18;  // SSD1306 I2C clock (not the variant's default SCL 42)
static const uint8_t HV3_OLED_SDA_PIN = 17;  // SSD1306 I2C data  (not the variant's default SDA 41)
static const uint8_t HV3_PRG_PIN      = 0;   // PRG button, active LOW (strapping pin: only read it)
static const uint8_t HV3_VBAT_ADC_PIN = 1;   // battery through a ~1:4.9 divider (ADC1 channel 0)
static const uint8_t HV3_VBAT_CTRL_PIN = 37; // divider switch: V3.0/V3.1 on = LOW, V3.2 on = HIGH
#endif
