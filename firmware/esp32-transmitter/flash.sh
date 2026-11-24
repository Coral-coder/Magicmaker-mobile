#!/usr/bin/env bash
# Flash the MagicMaker ESP32 transmitter firmware from macOS / Linux.
#
# No compiling, no Arduino toolchain: flashes the PREBUILT merged image that CI commits
# next to this script, picking the right one for the board that's plugged in:
#   classic ESP32 (DevKit / WROOM / WROVER)            -> magicmaker-esp32.bin
#   Heltec WiFi LoRa 32 V3 / V3.1 / V3.2 (ESP32-S3)    -> magicmaker-heltec-v3.bin
#
# USAGE (in this folder):
#   ./flash.sh                       # auto-detect port + board, flash the matching firmware
#   ./flash.sh --board heltec-v3     # skip board detection (or --board esp32)
#   ./flash.sh --list-ports          # list serial ports and exit
#   ./flash.sh --port /dev/ttyUSB0   # force a port (macOS: /dev/cu.usbserial-0001 or similar)
#   ./flash.sh --bin ./my.bin        # flash a local merged .bin instead of the prebuilt one
#   ./flash.sh --token ghp_xxx       # download from this PRIVATE repo's release (or set GITHUB_TOKEN)
#   ./flash.sh --baud 460800         # slower upload speed if 921600 is flaky
#
# Needs python3: esptool is used if already installed (v4+), otherwise esptool 4.8.1 is
# installed into ./.tools/venv on first run. Linux: your user needs access to the serial
# port (the dialout group on Debian/Ubuntu, uucp on Arch).
# Board won't connect? Heltec V3: hold PRG, tap RST, release PRG. Classic: hold BOOT.

# Re-run under bash if started as `sh flash.sh` (this script uses bash arrays / [[ =~ ]]).
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLS="$HERE/.tools"
ESPTOOL_VER="4.8.1"
REPO="Coral-coder/Magicmaker-mobile"
RELEASE_URL="https://github.com/$REPO/releases/download/esp32-firmware"

PORT=""
BOARD="auto"
BIN=""
BAUD=921600
LIST=0
TOKEN="${GITHUB_TOKEN:-}"

say()   { printf '\033[36m==> %s\033[0m\n' "$*"; }
warn()  { printf '\033[33m%s\033[0m\n' "$*"; }
die()   { printf '\033[31mError: %s\033[0m\n' "$*" >&2; exit 1; }
usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; }
need()  { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value (see --help)"; }

# Accept the PowerShell-style names too (-Board, -Port, ...), for muscle memory.
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--port|-Port)     need "$@"; PORT="$2";  shift 2 ;;
    -b|--board|-Board)   need "$@"; BOARD="$2"; shift 2 ;;
    --bin|-Bin)          need "$@"; BIN="$2";   shift 2 ;;
    --baud|-Baud)        need "$@"; BAUD="$2";  shift 2 ;;
    --token|-Token)      need "$@"; TOKEN="$2"; shift 2 ;;
    -l|--list-ports|-ListPorts) LIST=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *)                   usage; die "unknown option: $1" ;;
  esac
done

BOARD="$(printf '%s' "$BOARD" | tr '[:upper:]' '[:lower:]')"
case "$BOARD" in
  auto|esp32|heltec-v3) ;;
  heltec|heltec_v3|heltecv3) BOARD="heltec-v3" ;;
  classic) BOARD="esp32" ;;
  *) die "--board must be auto, esp32 or heltec-v3 (got '$BOARD')" ;;
esac

# ---------------------------------------------------------------- serial ports
list_ports() {
  local p
  for p in /dev/cu.SLAB_USBtoUART* /dev/cu.usbserial* /dev/cu.wchusbserial* /dev/cu.usbmodem* \
           /dev/ttyUSB* /dev/ttyACM*; do
    if [ -e "$p" ]; then echo "$p"; fi
  done
}

# Linux: the /dev/serial/by-id name (e.g. usb-Silicon_Labs_CP2102_...), if any.
describe_port() {
  local l
  if [ -d /dev/serial/by-id ]; then
    for l in /dev/serial/by-id/*; do
      if [ -e "$l" ] && [ "$(readlink -f "$l")" = "$1" ]; then basename "$l"; return 0; fi
    done
  fi
  return 0
}

if [ "$LIST" = 1 ]; then
  ports="$(list_ports)"
  if [ -z "$ports" ]; then echo "No serial ports found."; exit 0; fi
  for p in $ports; do printf '%-28s %s\n' "$p" "$(describe_port "$p")"; done
  exit 0
fi

find_port() {
  local ports p n
  ports="$(list_ports)"
  if [ -z "$ports" ]; then
    warn "No serial ports found - the board isn't plugged in, the USB cable is charge-only,"
    warn "or (macOS) the USB-serial driver is missing:"
    warn "  * CP2102 / CP210x boards (incl. Heltec V3): Silicon Labs CP210x VCP driver"
    warn "  * CH340 / CH9102 boards: WCH CH34x driver"
    die "No serial port detected."
  fi
  echo "Serial ports:"
  for p in $ports; do printf '    %-28s %s\n' "$p" "$(describe_port "$p")"; done
  # Prefer a USB-UART bridge (the Heltec V3 uses a CP2102).
  for p in $ports; do
    case "$p $(describe_port "$p")" in
      *SLAB*|*usbserial*|*CP210*|*Silicon_Labs*|*CH340*|*CH910*|*1a86*|/dev/ttyUSB*)
        PORT="$p"; return 0 ;;
    esac
  done
  n="$(printf '%s\n' "$ports" | wc -l | tr -d ' ')"
  if [ "$n" = 1 ]; then PORT="$ports"; return 0; fi
  die "More than one serial port and none obviously the ESP32. Rerun with --port (e.g. --port $(printf '%s\n' "$ports" | head -n 1))."
}

# --------------------------------------------------------------------- esptool
ESPTOOL=()
esptool_ok() {   # esptool_ok <cmd...>: true if it runs and is v4 or newer
  local v
  v="$("$@" version 2>/dev/null | tail -n 1)" || return 1
  case "$v" in [4-9].*|[1-9][0-9].*) return 0 ;; *) return 1 ;; esac
}
find_esptool() {
  local c
  if [ -x "$TOOLS/venv/bin/python" ] && esptool_ok "$TOOLS/venv/bin/python" -m esptool; then
    ESPTOOL=("$TOOLS/venv/bin/python" -m esptool); return 0
  fi
  if command -v python3 >/dev/null 2>&1 && esptool_ok python3 -m esptool; then
    ESPTOOL=(python3 -m esptool); return 0
  fi
  for c in esptool esptool.py; do
    if command -v "$c" >/dev/null 2>&1 && esptool_ok "$c"; then ESPTOOL=("$c"); return 0; fi
  done
  command -v python3 >/dev/null 2>&1 || die "python3 not found. Install Python 3 (macOS: brew install python, or xcode-select --install), or install esptool yourself."
  say "Installing esptool $ESPTOOL_VER into $TOOLS/venv (one-time)..."
  mkdir -p "$TOOLS"
  python3 -m venv "$TOOLS/venv" || die "couldn't create a Python venv (Debian/Ubuntu: sudo apt install python3-venv), or install esptool yourself (pipx install esptool)."
  "$TOOLS/venv/bin/python" -m pip install --quiet "esptool==$ESPTOOL_VER" || die "installing esptool failed."
  ESPTOOL=("$TOOLS/venv/bin/python" -m esptool)
}

# ------------------------------------------------------------ board detection
# Chip name from esptool's connect banner:
#   v4: "Detecting chip type... ESP32-S3" / "Chip is ESP32-D0WD-V3 (revision v3.1)"
#   v5: "Connected to ESP32-S3 on /dev/ttyUSB0:" / "Chip type:   ESP32-S3 (QFN56) ..."
chip_name() {
  local re
  for re in 'Detecting chip type\.\.\. *(ESP[-A-Za-z0-9]+)' 'Connected to (ESP[-A-Za-z0-9]+)' \
            'Chip is (ESP[-A-Za-z0-9]+)' 'Chip type: *(ESP[-A-Za-z0-9]+)'; do
    if [[ $1 =~ $re ]]; then printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]'; return 0; fi
  done
  return 0
}

# Read-only: --no-stub + --after no_reset leave the chip in its ROM bootloader, so the
# flash step still connects even if the board was put into download mode by hand.
detect_board() {
  local out chip
  say "Detecting which board is on $PORT (read-only, a few seconds)..."
  out="$("${ESPTOOL[@]}" --chip auto --port "$PORT" --baud 115200 \
          --before default_reset --after no_reset --no-stub read_mac 2>&1)" || true
  printf '%s\n' "$out" | sed 's/^/    /'
  chip="$(chip_name "$out")"
  if [ -z "$chip" ]; then
    warn "Couldn't talk to the board on $PORT to see which one it is."
    warn "Put it in download mode, then rerun ./flash.sh:"
    warn "  * Heltec WiFi LoRa 32 V3: hold PRG, tap RST, release PRG."
    warn "  * Classic ESP32: hold BOOT, run the script, release BOOT once it says 'Connecting...'."
    warn "  * Close any serial monitor that holds the port, or try another USB cable."
    if [ ! -w "$PORT" ]; then
      warn "  * No write access to $PORT: add yourself to the dialout group (Arch: uucp), log out and back in."
    fi
    warn "Or skip detection and name the board: ./flash.sh --board heltec-v3   (or --board esp32)"
    die "Board detection failed on $PORT."
  fi
  case "$chip" in
    ESP32-S3*) BOARD="heltec-v3"
               say "Found an $chip -> Heltec WiFi LoRa 32 V3 firmware (other ESP32-S3 boards are not supported)" ;;
    ESP32-S2*|ESP32-C[0-9]*|ESP32-H[0-9]*|ESP32-P[0-9]*) BOARD="" ;;
    ESP32|ESP32-*) BOARD="esp32"
               say "Found an $chip -> classic ESP32 firmware" ;;
    *) BOARD="" ;;
  esac
  if [ -z "$BOARD" ]; then
    warn "This board is an $chip, which this firmware doesn't support. Supported boards:"
    warn "  * classic ESP32 (DevKit / WROOM / WROVER)            -> --board esp32"
    warn "  * Heltec WiFi LoRa 32 V3 / V3.1 / V3.2 (ESP32-S3)    -> --board heltec-v3"
    warn "Nothing was written. Tap RST (or replug) to restart it."
    die "Unsupported chip: $chip."
  fi
}

# Which board a merged image is for, from its ESP image header: ESP32-S3 images have the
# bootloader (magic 0xE9, chip id 9 at byte 12) at 0x0; classic ESP32 images have it at
# 0x1000 (chip id 0). Both carry the partition table (magic AA 50) at 0x8000, which a bare
# app .bin (also 0xE9 + chip id at 0x0) doesn't. Prints heltec-v3, esp32, or nothing.
hexbytes() { { od -An -tx1 -j "$2" -N "$3" "$1" 2>/dev/null || true; } | tr -d ' \n'; }
image_board() {
  local h0 h1 size
  [ -f "$1" ] || return 0
  size="$(wc -c < "$1" | tr -d ' ')"
  if [ "${size:-0}" -lt 65536 ] || [ "$(hexbytes "$1" 32768 2)" != "aa50" ]; then return 0; fi
  h0="$(hexbytes "$1" 0 16)"
  h1="$(hexbytes "$1" 4096 16)"
  if [ "${h0:0:2}" = "e9" ] && [ "${h0:24:4}" = "0900" ]; then echo "heltec-v3"
  elif [ "${h1:0:2}" = "e9" ] && [ "${h1:24:4}" = "0000" ]; then echo "esp32"
  fi
  return 0
}

# ------------------------------------------------------------------------ main
if [ -z "$PORT" ]; then find_port; fi
say "Using port $PORT (override with --port if wrong)"

find_esptool
FORCED=0
if [ "$BOARD" = "auto" ]; then
  detect_board
else
  FORCED=1
  say "Board forced: $BOARD (skipping detection)"
fi

if [ "$BOARD" = "heltec-v3" ]; then
  CHIP="esp32s3"; ASSET="magicmaker-heltec-v3.bin"; NAME="Heltec WiFi LoRa 32 V3"
else
  CHIP="esp32";   ASSET="magicmaker-esp32.bin";     NAME="classic ESP32"
fi

# Firmware: --bin, else the prebuilt bin committed next to this script, else the release.
if [ -n "$BIN" ]; then
  [ -f "$BIN" ] || die "Firmware file not found: $BIN"
  say "Using local firmware $BIN"
elif [ -f "$HERE/$ASSET" ]; then
  BIN="$HERE/$ASSET"
  say "Using prebuilt $ASSET from the repo ($(( $(wc -c < "$BIN") / 1024 )) KB) - git pull keeps it current"
else
  mkdir -p "$TOOLS"
  BIN="$TOOLS/$ASSET"
  rm -f "$BIN"
  say "No $ASSET next to this script - downloading the latest prebuilt firmware..."
  if [ -n "$TOKEN" ]; then
    # Private repo: resolve the asset's API URL, then fetch it as octet-stream with the token.
    url="$(curl -fsSL -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
             "https://api.github.com/repos/$REPO/releases/tags/esp32-firmware" \
           | python3 -c 'import json,sys; n=sys.argv[1]; print(next((a["url"] for a in json.load(sys.stdin).get("assets", []) if a.get("name") == n), ""))' "$ASSET" 2>/dev/null)" || url=""
    [ -n "$url" ] || die "Release asset $ASSET not found (bad token, or CI hasn't built it yet)."
    curl -fL -H "Authorization: Bearer $TOKEN" -H "Accept: application/octet-stream" -o "$BIN" "$url" || true
  else
    curl -fL -o "$BIN" "$RELEASE_URL/$ASSET" || true
  fi
  size=0
  if [ -f "$BIN" ]; then size="$(wc -c < "$BIN" | tr -d ' ')"; fi
  if [ "$size" -lt 102400 ] || [ "$(image_board "$BIN")" != "$BOARD" ]; then
    rm -f "$BIN"
    warn "Couldn't download the firmware - this repo is private. Do ONE of these:"
    warn "  1) git pull (CI commits $ASSET next to this script), then rerun."
    warn "  2) Download it in a browser logged into GitHub, then: ./flash.sh --bin ./$ASSET"
    warn "       $RELEASE_URL/$ASSET"
    warn "  3) Pass a GitHub token (repo read scope): ./flash.sh --token ghp_xxx"
    die "No valid $NAME firmware image."
  fi
  say "Downloaded $(( size / 1024 )) KB"
fi

# Refuse an image for the other board (or not a merged image): we write it all at 0x0.
IMG="$(image_board "$BIN")"
if [ "$IMG" != "$BOARD" ]; then
  if [ -n "$IMG" ]; then die "$BIN is the $IMG firmware, but the board is a $NAME. Use $ASSET (or drop --bin)."; fi
  die "$BIN isn't a merged $NAME image (bootloader + partition table not where expected; a bare app .bin won't do). Use $ASSET."
fi

say "Flashing $ASSET to the $NAME on $PORT at $BAUD baud..."
if ! "${ESPTOOL[@]}" --chip "$CHIP" --port "$PORT" --baud "$BAUD" \
       --before default_reset --after hard_reset write_flash 0x0 "$BIN"; then
  warn "Flashing failed. Common fixes:"
  if [ "$BOARD" = "heltec-v3" ]; then
    warn "  * Put the Heltec in download mode: hold PRG, tap RST, release PRG - then rerun."
    warn "    (After flashing in that mode, tap RST once to start the new firmware.)"
  else
    warn "  * Hold the BOOT button while it says 'Connecting...', release after it starts."
  fi
  if [ "$FORCED" = 1 ]; then
    warn "  * esptool said 'Wrong --chip argument?' -> this board isn't a $NAME: rerun without --board."
  fi
  if [ -e "$PORT" ] && [ ! -w "$PORT" ]; then
    warn "  * No write access to $PORT: add yourself to the dialout group (Arch: uucp), log out and back in."
  fi
  warn "  * Try a slower speed: ./flash.sh --baud 460800"
  warn "  * Close any serial monitor / Arduino IDE that may hold the port."
  die "esptool failed."
fi

if [ "$BOARD" = "heltec-v3" ]; then
  say "Done. The Heltec V3 is now advertising as MagicMaker-ESP32 - pick the ESP32 backend in the app."
  say "The screen stays dark to save battery: press PRG to light the screen."
else
  say "Done. The ESP32 is now advertising as MagicMaker-ESP32 - pick the ESP32 backend in the app."
fi
