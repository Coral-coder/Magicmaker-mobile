<#
  Flash the MagicMaker ESP32 transmitter firmware from Windows.

  It bootstraps everything: downloads a portable arduino-cli if you don't have one,
  installs the ESP32 board core + NimBLE-Arduino library, compiles the sketch, and
  uploads it to your board. Run it from this folder (it flashes the .ino next to it).

  USAGE (PowerShell, in this folder):
    ./flash.ps1                 # auto-detect the ESP32's COM port
    ./flash.ps1 -ListPorts      # just list COM ports and exit
    ./flash.ps1 -Port COM5      # force a port
    ./flash.ps1 -Fqbn esp32:esp32:esp32s3   # for an S3/C3 board

  If PowerShell blocks the script, run this once in the same window:
    Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
#>

param(
    [string]$Port = "",
    [string]$Fqbn = "esp32:esp32:esp32",
    [string]$SketchDir = $PSScriptRoot,
    [switch]$ListPorts
)

$ErrorActionPreference = "Stop"
$Esp32IndexUrl = "https://espressif.github.io/arduino-esp32/package_esp32_index.json"
$Tools = Join-Path $PSScriptRoot ".tools"
$CliExe = Join-Path $Tools "arduino-cli.exe"

function Say($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# Map each COM port Windows sees to its device name, so we can spot the ESP32's USB-serial chip.
function Get-ComPortMap {
    $map = [ordered]@{}
    try {
        foreach ($n in [System.IO.Ports.SerialPort]::GetPortNames()) { $map[$n.ToUpper()] = "" }
    } catch {}
    try {
        Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '\(COM\d+\)' } |
            ForEach-Object {
                if ($_.Name -match '\((COM\d+)\)') { $map[$Matches[1].ToUpper()] = $_.Name }
            }
    } catch {}
    return $map
}

function Find-Esp32Port {
    $map = Get-ComPortMap
    $ports = @($map.Keys)
    if ($ports.Count -eq 0) {
        Write-Host ""
        Write-Host "No COM ports found - the ESP32's USB-serial driver is probably missing," -ForegroundColor Yellow
        Write-Host "or this is a charge-only USB cable, or the board isn't plugged in." -ForegroundColor Yellow
        Write-Host "  * CP2102 / CP210x boards: install the Silicon Labs CP210x VCP driver" -ForegroundColor Yellow
        Write-Host "  * CH340 / CH9102 boards:  install the WCH CH340 driver" -ForegroundColor Yellow
        Write-Host "Then replug and rerun, or check Device Manager > Ports (COM & LPT)." -ForegroundColor Yellow
        throw "No serial port detected."
    }
    Write-Host "COM ports Windows sees:"
    foreach ($p in $ports) { Write-Host ("    {0,-6} {1}" -f $p, $map[$p]) }
    # Prefer a port whose name looks like an ESP32 USB-serial bridge.
    $likely = $ports | Where-Object { $map[$_] -match 'CP210|CH340|CH910|CH9102|Silicon Labs|USB.?SERIAL|UART|ESP32' } | Select-Object -First 1
    if ($likely) { return $likely }
    if ($ports.Count -eq 1) { return $ports[0] }
    throw "More than one COM port and none obviously the ESP32. Rerun with -Port (e.g. -Port $($ports[0]))."
}

if ($ListPorts) {
    $map = Get-ComPortMap
    if ($map.Count -eq 0) { Write-Host "No COM ports found." } else { foreach ($p in $map.Keys) { Write-Host ("{0,-6} {1}" -f $p, $map[$p]) } }
    return
}

# 1. Get arduino-cli (portable, kept in a local .tools folder - nothing installed system-wide).
if (-not (Test-Path $CliExe)) {
    if (Get-Command arduino-cli -ErrorAction SilentlyContinue) {
        $CliExe = "arduino-cli"
    } else {
        Say "Downloading arduino-cli (one-time)..."
        New-Item -ItemType Directory -Force -Path $Tools | Out-Null
        $zip = Join-Path $Tools "arduino-cli.zip"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri "https://downloads.arduino.cc/arduino-cli/arduino-cli_latest_Windows_64bit.zip" -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath $Tools -Force
        Remove-Item $zip
    }
}

# NOTE: don't name this 'Cli' - that's a built-in alias for Clear-Item and would shadow it.
function Acli { & $CliExe @args; if ($LASTEXITCODE -ne 0) { throw "arduino-cli failed: $args" } }

# 2. Detect the board FIRST, so we fail fast with a helpful message before the long installs.
if (-not $Port) { $Port = Find-Esp32Port }
Say "Using port $Port (override with -Port COMx if wrong)"

# 3. Board core + library (skips work if already present).
Say "Updating board index..."
Acli config init --overwrite | Out-Null
Acli config set board_manager.additional_urls $Esp32IndexUrl
Acli core update-index
Say "Installing ESP32 core (first run takes a few minutes)..."
Acli core install esp32:esp32
Say "Installing NimBLE-Arduino library..."
Acli lib install "NimBLE-Arduino"

# 4. Compile + upload.
Say "Compiling for $Fqbn..."
Acli compile --fqbn $Fqbn "$SketchDir"
Say "Flashing to $Port..."
Acli upload -p $Port --fqbn $Fqbn "$SketchDir"

Say "Done. The ESP32 is now advertising as MagicMaker-ESP32 - pick the ESP32 backend in the app."
