<#
  Flash the MagicMaker ESP32 transmitter firmware from Windows.

  NO compiling. No Arduino toolchain. This downloads the PREBUILT firmware that
  GitHub Actions already compiled (magicmaker-esp32.bin), auto-detects your
  ESP32's COM port, and flashes it with esptool. That's it.

  USAGE (PowerShell, in this folder):
    ./flash.ps1                       # download latest firmware + auto-detect port + flash
    ./flash.ps1 -ListPorts            # just list COM ports and exit
    ./flash.ps1 -Port COM5            # force a port (skip auto-detect)
    ./flash.ps1 -Bin .\my.bin         # flash a local .bin instead of downloading
    ./flash.ps1 -Baud 460800          # slower upload speed if 921600 is flaky

  If PowerShell blocks the script, run this once in the same window:
    Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
#>

param(
    [string]$Port = "",
    [string]$Bin = "",
    [int]$Baud = 921600,
    [switch]$ListPorts
)

$ErrorActionPreference = "Stop"
$Tools     = Join-Path $PSScriptRoot ".tools"
$EsptoolVer = "v4.8.1"
$BinUrl    = "https://github.com/Coral-coder/Magicmaker-mobile/releases/download/esp32-firmware/magicmaker-esp32.bin"

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

# Find esptool: an already-downloaded portable exe, one on PATH, python -m esptool, or
# download the standalone Windows build (no Python needed). Returns {Exe, Pre}.
function Get-Esptool {
    $local = Get-ChildItem -Path $Tools -Recurse -Filter esptool.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($local) { return [pscustomobject]@{ Exe = $local.FullName; Pre = @() } }
    if (Get-Command esptool.exe -ErrorAction SilentlyContinue) { return [pscustomobject]@{ Exe = "esptool.exe"; Pre = @() } }
    if (Get-Command esptool    -ErrorAction SilentlyContinue) { return [pscustomobject]@{ Exe = "esptool";     Pre = @() } }
    foreach ($py in @("python", "py")) {
        if (Get-Command $py -ErrorAction SilentlyContinue) {
            try { & $py -m esptool version *> $null; if ($LASTEXITCODE -eq 0) { return [pscustomobject]@{ Exe = $py; Pre = @("-m", "esptool") } } } catch {}
        }
    }
    Say "Downloading esptool $EsptoolVer (one-time)..."
    New-Item -ItemType Directory -Force -Path $Tools | Out-Null
    $zip = Join-Path $Tools "esptool.zip"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri "https://github.com/espressif/esptool/releases/download/$EsptoolVer/esptool-$EsptoolVer-win64.zip" -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $Tools -Force
    Remove-Item $zip
    $local = Get-ChildItem -Path $Tools -Recurse -Filter esptool.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $local) { throw "esptool.exe not found after download." }
    return [pscustomobject]@{ Exe = $local.FullName; Pre = @() }
}

# 1. Detect the board FIRST so we fail fast with a helpful message.
if (-not $Port) { $Port = Find-Esp32Port }
Say "Using port $Port (override with -Port COMx if wrong)"

# 2. Get the firmware .bin. Use a local one if given; otherwise download the latest prebuilt.
if ($Bin) {
    if (-not (Test-Path $Bin)) { throw "Firmware file not found: $Bin" }
    Say "Using local firmware $Bin"
} else {
    New-Item -ItemType Directory -Force -Path $Tools | Out-Null
    $Bin = Join-Path $Tools "magicmaker-esp32.bin"
    Say "Downloading latest prebuilt firmware..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $BinUrl -OutFile $Bin
    Say "Downloaded $([math]::Round((Get-Item $Bin).Length/1KB)) KB"
}

# 3. Flash. The .bin is a single merged image built to sit at flash offset 0x0.
$t = Get-Esptool
$flashArgs = $t.Pre + @(
    "--chip", "esp32", "--port", $Port, "--baud", "$Baud",
    "--before", "default_reset", "--after", "hard_reset",
    "write_flash", "0x0", $Bin
)
Say "Flashing to $Port at $Baud baud..."
& $t.Exe @flashArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Flashing failed. Common fixes:" -ForegroundColor Yellow
    Write-Host "  * Hold the BOOT button while it says 'Connecting...', release after it starts." -ForegroundColor Yellow
    Write-Host "  * Try a slower speed: ./flash.ps1 -Baud 460800" -ForegroundColor Yellow
    Write-Host "  * Close any serial monitor / Arduino IDE that may hold the port." -ForegroundColor Yellow
    throw "esptool exited with code $LASTEXITCODE."
}

Say "Done. The ESP32 is now advertising as MagicMaker-ESP32 - pick the ESP32 backend in the app."
