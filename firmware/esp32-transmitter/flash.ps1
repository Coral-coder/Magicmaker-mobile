<#
  Flash the MagicMaker ESP32 transmitter firmware from Windows.

  It bootstraps everything: downloads a portable arduino-cli if you don't have one,
  installs the ESP32 board core + NimBLE-Arduino library, compiles the sketch, and
  uploads it to your board. Run it from this folder (it flashes the .ino next to it).

  USAGE (PowerShell, in this folder):
    # let it auto-detect the COM port:
    ./flash.ps1

    # or name the port + board explicitly:
    ./flash.ps1 -Port COM5 -Fqbn esp32:esp32:esp32s3

  If PowerShell blocks the script, run this once in the same window:
    Set-ExecutionPolicy -Scope Process -Bypass
#>

param(
    [string]$Port = "",
    # Common FQBNs: esp32:esp32:esp32 (classic dev board), esp32:esp32:esp32s3,
    # esp32:esp32:esp32c3. Pick the one matching your board.
    [string]$Fqbn = "esp32:esp32:esp32",
    [string]$SketchDir = $PSScriptRoot
)

$ErrorActionPreference = "Stop"
$Esp32IndexUrl = "https://espressif.github.io/arduino-esp32/package_esp32_index.json"
$Tools = Join-Path $PSScriptRoot ".tools"
$CliExe = Join-Path $Tools "arduino-cli.exe"

function Say($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# 1. Get arduino-cli (portable, kept in a local .tools folder — nothing installed system-wide).
if (-not (Test-Path $CliExe)) {
    if (Get-Command arduino-cli -ErrorAction SilentlyContinue) {
        $CliExe = "arduino-cli"
    } else {
        Say "Downloading arduino-cli (one-time)…"
        New-Item -ItemType Directory -Force -Path $Tools | Out-Null
        $zip = Join-Path $Tools "arduino-cli.zip"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri "https://downloads.arduino.cc/arduino-cli/arduino-cli_latest_Windows_64bit.zip" -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath $Tools -Force
        Remove-Item $zip
    }
}

function Cli { & $CliExe @args; if ($LASTEXITCODE -ne 0) { throw "arduino-cli failed: $args" } }

# 2. Board core + library (skips work if already present).
Say "Updating board index…"
Cli config init --overwrite | Out-Null
Cli config set board_manager.additional_urls $Esp32IndexUrl
Cli core update-index
Say "Installing ESP32 core (first run takes a few minutes)…"
Cli core install esp32:esp32
Say "Installing NimBLE-Arduino library…"
Cli lib install "NimBLE-Arduino"

# 3. Pick the port if not given.
if (-not $Port) {
    Say "Detecting board…"
    $list = & $CliExe board list
    $list | Write-Host
    $line = $list | Where-Object { $_ -match "^COM\d+" } | Select-Object -First 1
    if ($line) {
        $Port = ($line -split "\s+")[0]
        Say "Using $Port (override with -Port COMx if wrong)"
    } else {
        throw "No COM port found. Plug in the ESP32 and pass -Port COMx (see Device Manager)."
    }
}

# 4. Compile + upload.
Say "Compiling for $Fqbn…"
Cli compile --fqbn $Fqbn "$SketchDir"
Say "Flashing to $Port…"
Cli upload -p $Port --fqbn $Fqbn "$SketchDir"

Say "Done. The ESP32 is now advertising as MagicMaker-ESP32 — pick the ESP32 backend in the app."
