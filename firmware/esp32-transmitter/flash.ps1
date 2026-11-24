<#
  Flash the MagicMaker ESP32 transmitter firmware from Windows.

  NO compiling. No Arduino toolchain. This flashes the PREBUILT firmware that GitHub
  Actions already compiled, auto-detects your board's COM port AND which board it is,
  and flashes the matching image with esptool. That's it.

  Supported boards (picked automatically from the chip, or force one with -Board):
    -Board esp32      classic ESP32 (DevKit / WROOM / WROVER)   -> magicmaker-esp32.bin
    -Board heltec-v3  Heltec WiFi LoRa 32 V3 / V3.1 / V3.2      -> magicmaker-heltec-v3.bin
                      (ESP32-S3 + OLED; press PRG to light the screen)
  Auto mode asks the chip (read-only): ESP32-S3 -> Heltec V3 image, classic ESP32 -> classic
  image; any other chip (S2, C3, C6, H2) is refused. The image header is checked against the
  board before anything is written.

  USAGE (PowerShell, in this folder):
    ./flash.ps1                       # auto-detect port + board, flash the matching firmware
    ./flash.ps1 -Board heltec-v3      # skip board detection: Heltec WiFi LoRa 32 V3
    ./flash.ps1 -Board esp32          # skip board detection: classic ESP32
    ./flash.ps1 -ListPorts            # just list COM ports and exit
    ./flash.ps1 -Port COM5            # force a port (skip port auto-detect)
    ./flash.ps1 -Bin .\my.bin         # flash a local merged .bin instead of the prebuilt one
    ./flash.ps1 -Token ghp_xxx        # auto-download from this PRIVATE repo with a GitHub token
    ./flash.ps1 -Baud 460800          # slower upload speed if 921600 is flaky

  Where the firmware comes from, in order: -Bin; the prebuilt .bin committed next to this
  script (CI keeps it fresh, so `git pull` gets you the latest); a download from the
  "esp32-firmware" release. This repo is private, so the anonymous download won't work:
  either download the .bin in your browser and use -Bin, or pass a -Token (repo read scope).

  Board won't connect? Put it in download mode and rerun:
    Heltec V3:     hold PRG, tap RST, release PRG.
    Classic ESP32: hold BOOT while it says "Connecting...".

  If PowerShell blocks the script, run this once in the same window:
    Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
#>

param(
    [string]$Port = "",
    [string]$Bin = "",
    [int]$Baud = 921600,
    [string]$Token = $env:GITHUB_TOKEN,   # needed to auto-download from a PRIVATE repo
    [switch]$ListPorts,
    [ValidateSet("auto", "esp32", "heltec-v3", "heltec", "classic")]
    [string]$Board = "auto"
)

$ErrorActionPreference = "Stop"
$Tools      = Join-Path $PSScriptRoot ".tools"
$EsptoolVer = "v4.8.1"
$RepoSlug   = "Coral-coder/Magicmaker-mobile"
$ReleaseUrl = "https://github.com/$RepoSlug/releases/download/esp32-firmware"

# The boards this firmware supports. Chip = esptool --chip; Asset = merged image name
# (committed next to this script and attached to the esp32-firmware release).
$BoardInfo = @{
    "esp32"     = @{ Name = "classic ESP32";                     Chip = "esp32";   Asset = "magicmaker-esp32.bin" }
    "heltec-v3" = @{ Name = "Heltec WiFi LoRa 32 V3 (ESP32-S3)"; Chip = "esp32s3"; Asset = "magicmaker-heltec-v3.bin" }
}

function Say($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Warn($msg) { Write-Host $msg -ForegroundColor Yellow }

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
        Warn "No COM ports found - the board's USB-serial driver is probably missing,"
        Warn "or this is a charge-only USB cable, or the board isn't plugged in."
        Warn "  * CP2102 / CP210x boards (incl. Heltec V3): install the Silicon Labs CP210x VCP driver"
        Warn "  * CH340 / CH9102 boards:  install the WCH CH340 driver"
        Warn "Then replug and rerun, or check Device Manager > Ports (COM & LPT)."
        throw "No serial port detected."
    }
    Write-Host "COM ports Windows sees:"
    foreach ($p in $ports) { Write-Host ("    {0,-6} {1}" -f $p, $map[$p]) }
    # Prefer a port whose name looks like an ESP32 USB-serial bridge (the Heltec V3 uses a CP2102).
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

# True if this esptool runs and is v4 or newer (older ones predate full ESP32-S3 support).
# `esptool version` prints a banner, then the bare version ("4.8.1") as its last line.
function Test-Esptool([string]$Exe, [string[]]$Pre) {
    $ErrorActionPreference = "Continue"
    try {
        $out = @(& $Exe @Pre version 2>$null)
        if ($LASTEXITCODE -ne 0) { return $false }
        $v = ("" + ($out | Select-Object -Last 1)).Trim()
        return ($v -match '^v?(\d+)\.' -and [int]$Matches[1] -ge 4)
    } catch { return $false }
}

# Find esptool (v4+): an already-downloaded portable exe, one on PATH, python -m esptool, or
# download the standalone Windows build (no Python needed). Returns {Exe, Pre}.
function Get-Esptool {
    $local = Get-ChildItem -Path $Tools -Recurse -Filter esptool.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($local) { return [pscustomobject]@{ Exe = $local.FullName; Pre = @() } }
    foreach ($c in @("esptool.exe", "esptool")) {
        if ((Get-Command $c -ErrorAction SilentlyContinue) -and (Test-Esptool $c @())) { return [pscustomobject]@{ Exe = $c; Pre = @() } }
    }
    foreach ($py in @("python", "py")) {
        if ((Get-Command $py -ErrorAction SilentlyContinue) -and (Test-Esptool $py @("-m", "esptool"))) { return [pscustomobject]@{ Exe = $py; Pre = @("-m", "esptool") } }
    }
    Say "Downloading esptool $EsptoolVer (one-time)..."
    New-Item -ItemType Directory -Force -Path $Tools | Out-Null
    $zip = Join-Path $Tools "esptool.zip"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = "SilentlyContinue"   # the PS 5.1 progress bar makes downloads crawl
    Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/espressif/esptool/releases/download/$EsptoolVer/esptool-$EsptoolVer-win64.zip" -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $Tools -Force
    Remove-Item $zip
    $local = Get-ChildItem -Path $Tools -Recurse -Filter esptool.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $local) { throw "esptool.exe not found after download." }
    return [pscustomobject]@{ Exe = $local.FullName; Pre = @() }
}

# Run esptool, echo its output (dimmed) AND capture it. Returns {Code, Text}.
# Locally relax ErrorActionPreference: under "Stop", Windows PowerShell 5.1 turns the first
# stderr line of a native command redirected with 2>&1 into a terminating error.
function Invoke-EsptoolCapture($Tool, [string[]]$EsArgs) {
    $ErrorActionPreference = "Continue"
    $oldUnbuffered = $env:PYTHONUNBUFFERED
    $env:PYTHONUNBUFFERED = "1"            # show esptool's lines as they happen, not at exit
    $all = @($Tool.Pre) + $EsArgs
    $lines = @(& $Tool.Exe @all 2>&1 | ForEach-Object {
        $s = "$_"
        Write-Host "    $s" -ForegroundColor DarkGray
        $s
    })
    $code = $LASTEXITCODE
    $env:PYTHONUNBUFFERED = $oldUnbuffered
    return [pscustomobject]@{ Code = $code; Text = ($lines -join "`n") }
}

# Pull the chip name out of esptool's connect banner:
#   esptool v4: "Detecting chip type... ESP32-S3" / "Chip is ESP32-D0WD-V3 (revision v3.1)"
#   esptool v5: "Connected to ESP32-S3 on COM5:" / "Chip type:   ESP32-S3 (QFN56) ..."
function Get-ChipName([string]$Text) {
    $patterns = @(
        'Detecting chip type\.\.\.\s*(ESP[-A-Za-z0-9]+)',
        'Connected to (ESP[-A-Za-z0-9]+)',
        'Chip is (ESP[-A-Za-z0-9]+)',
        'Chip type:\s*(ESP[-A-Za-z0-9]+)'
    )
    foreach ($re in $patterns) {
        if ($Text -match $re) { return $Matches[1].ToUpper() }
    }
    return ""
}

# ESP32-S3 -> Heltec V3 image; classic ESP32 (ESP32, ESP32-D0WD..., -PICO..., -U4WDH, -S0WD)
# -> classic image; anything else (S2, C3, C6, H2, P4, ESP8266) -> "" (unsupported).
function Get-BoardForChip([string]$Chip) {
    if ($Chip -match '^ESP32-S3') { return "heltec-v3" }
    if ($Chip -match '^ESP32-(S2|C\d|H\d|P\d)') { return "" }
    if ($Chip -match '^ESP32(-|$)') { return "esp32" }
    return ""
}

# Ask the board which chip it is. Read-only: nothing is written. --no-stub + --after no_reset
# leave the chip sitting in its ROM bootloader, so the flash step still connects even when
# the board had to be put into download mode by hand (PRG/BOOT button).
function Resolve-Board($Tool, [string]$ComPort) {
    Say "Detecting which board is on $ComPort (read-only, a few seconds)..."
    $r = Invoke-EsptoolCapture $Tool @(
        "--chip", "auto", "--port", $ComPort, "--baud", "115200",
        "--before", "default_reset", "--after", "no_reset", "--no-stub", "read_mac"
    )
    $chip = Get-ChipName $r.Text
    if (-not $chip) {
        Write-Host ""
        Warn "Couldn't talk to the board on $ComPort to see which one it is."
        Warn "Put it in download mode, then rerun ./flash.ps1:"
        Warn "  * Heltec WiFi LoRa 32 V3: hold PRG, tap RST, release PRG."
        Warn "  * Classic ESP32: hold BOOT, run the script, release BOOT once it says 'Connecting...'."
        Warn "  * Close any serial monitor / Arduino IDE that holds the port, or try another USB cable."
        Warn "Or skip detection and name the board: ./flash.ps1 -Board heltec-v3   (or -Board esp32)"
        throw "Board detection failed on $ComPort (esptool exit code $($r.Code))."
    }
    $b = Get-BoardForChip $chip
    if (-not $b) {
        Write-Host ""
        Warn "This board is an $chip, which this firmware doesn't support. Supported boards:"
        Warn "  * classic ESP32 (DevKit / WROOM / WROVER)   -> -Board esp32"
        Warn "  * Heltec WiFi LoRa 32 V3 / V3.1 / V3.2 (ESP32-S3)   -> -Board heltec-v3"
        Warn "Nothing was written. Tap RST (or replug) to restart it."
        throw "Unsupported chip: $chip."
    }
    if ($b -eq "heltec-v3") {
        Say "Found an $chip -> Heltec WiFi LoRa 32 V3 firmware (other ESP32-S3 boards are not supported)"
    } else {
        Say "Found an $chip -> classic ESP32 firmware"
    }
    return $b
}

# Which board a merged image is for, from its ESP image header. ESP32-S3 images have the
# bootloader (magic 0xE9, chip id 9 at byte 12) at offset 0x0; classic ESP32 images have it at
# 0x1000 (chip id 0) after 4 KB of 0xFF. Both carry the partition table (magic AA 50) at
# 0x8000, which a bare app .bin (also 0xE9 + chip id at 0x0) doesn't.
# Returns "heltec-v3", "esp32" or "" (not a merged image).
function Get-ImageBoard([string]$Path) {
    $b = [System.IO.File]::ReadAllBytes($Path)
    if ($b.Length -lt 0x10000 -or $b[0x8000] -ne 0xAA -or $b[0x8001] -ne 0x50) { return "" }
    if ($b[0] -eq 0xE9 -and $b[12] -eq 9 -and $b[13] -eq 0) { return "heltec-v3" }
    if ($b[0x1000] -eq 0xE9 -and $b[0x100C] -eq 0 -and $b[0x100D] -eq 0) { return "esp32" }
    return ""
}

# 1. Find the port FIRST so we fail fast with a helpful message.
if (-not $Port) { $Port = Find-Esp32Port }
Say "Using port $Port (override with -Port COMx if wrong)"

# 2. Which board? -Board wins; otherwise ask the chip.
$t = Get-Esptool
$Target = $Board.ToLower()
if ($Target -eq "heltec")  { $Target = "heltec-v3" }
if ($Target -eq "classic") { $Target = "esp32" }
if ($Target -eq "auto") {
    $Target = Resolve-Board $t $Port
} else {
    Say "Board forced: $($BoardInfo[$Target].Name) (skipping detection)"
}
$Info  = $BoardInfo[$Target]
$Asset = $Info.Asset

# 3. Get the firmware .bin for that board.
#    Priority: -Bin you pass  ->  the prebuilt bin committed next to this script (CI keeps it
#    fresh, so a plain `git pull` gives you the latest)  ->  download as a last resort.
$RepoBin = Join-Path $PSScriptRoot $Asset
$BinUrl  = "$ReleaseUrl/$Asset"
if ($Bin) {
    if (-not (Test-Path -LiteralPath $Bin)) { throw "Firmware file not found: $Bin" }
    $Bin = (Resolve-Path -LiteralPath $Bin).ProviderPath
    Say "Using local firmware $Bin"
} elseif (Test-Path -LiteralPath $RepoBin) {
    $Bin = $RepoBin
    Say "Using prebuilt $Asset from the repo ($([math]::Round((Get-Item -LiteralPath $Bin).Length/1KB)) KB) - git pull keeps it current"
} else {
    New-Item -ItemType Directory -Force -Path $Tools | Out-Null
    $Bin = Join-Path $Tools $Asset
    Say "No $Asset next to this script - downloading the latest prebuilt firmware..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = "SilentlyContinue"
    # This repo is PRIVATE, so an anonymous download returns GitHub's HTML login page, not the
    # .bin. With a token we fetch via the API asset endpoint (Accept: octet-stream) which auth's.
    try {
        if ($Token) {
            $headers = @{ Authorization = "Bearer $Token"; Accept = "application/octet-stream"; "User-Agent" = "magicmaker-flash" }
            $api = "https://api.github.com/repos/$RepoSlug/releases/tags/esp32-firmware"
            $rel = Invoke-RestMethod -Uri $api -Headers @{ Authorization = "Bearer $Token"; "User-Agent" = "magicmaker-flash"; Accept = "application/vnd.github+json" }
            # (not $asset: PowerShell names are case-insensitive, that would clobber $Asset)
            $relAsset = $rel.assets | Where-Object { $_.name -eq $Asset } | Select-Object -First 1
            if (-not $relAsset) { throw "Release asset $Asset not found (has CI built it yet?)." }
            Invoke-WebRequest -UseBasicParsing -Uri $relAsset.url -Headers $headers -OutFile $Bin
        } else {
            Invoke-WebRequest -UseBasicParsing -Uri $BinUrl -OutFile $Bin -Headers @{ "User-Agent" = "magicmaker-flash" }
        }
    } catch {
        throw "Download failed: $($_.Exception.Message)"
    }

    # A real image is ~600 KB with the right bootloader header; GitHub's HTML login/error page
    # (what an anonymous fetch of a private repo returns) is neither.
    $size = (Get-Item -LiteralPath $Bin).Length
    if ($size -lt 100KB -or (Get-ImageBoard $Bin) -ne $Target) {
        Remove-Item -LiteralPath $Bin -Force -ErrorAction SilentlyContinue
        Write-Host ""
        Warn "The download wasn't firmware - this repo is private, so an anonymous fetch gets"
        Warn "GitHub's login page instead of the .bin. Do ONE of these:"
        Warn "  1) In your browser (logged into GitHub) download the file, then flash it:"
        Warn "       $BinUrl"
        Warn "       .\flash.ps1 -Bin .\$Asset"
        Warn "  2) Or pass a GitHub token (repo read scope):"
        Warn "       .\flash.ps1 -Token ghp_xxx"
        Warn "  3) Or git pull - CI commits $Asset next to this script."
        throw "Firmware download invalid (got $([math]::Round($size/1KB)) KB, not a valid $($Info.Name) image)."
    }
    Say "Downloaded $([math]::Round($size/1KB)) KB"
}

# Refuse an image built for the other board (or not a merged image at all): this script
# always writes the whole image at flash offset 0x0.
$ImgBoard = Get-ImageBoard $Bin
if ($ImgBoard -ne $Target) {
    if ($ImgBoard) {
        throw "$Bin is the $($BoardInfo[$ImgBoard].Name) firmware, but the board is a $($Info.Name). Use $Asset (or drop -Bin)."
    }
    throw "$Bin isn't a merged $($Info.Name) image (bootloader + partition table not where expected; a bare app .bin won't do). Use $Asset from the esp32-firmware release."
}

# 4. Flash. The .bin is a single merged image built to sit at flash offset 0x0.
$flashArgs = @($t.Pre) + @(
    "--chip", $Info.Chip, "--port", $Port, "--baud", "$Baud",
    "--before", "default_reset", "--after", "hard_reset",
    "write_flash", "0x0", $Bin
)
Say "Flashing $Asset to the $($Info.Name) on $Port at $Baud baud..."
& $t.Exe @flashArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Warn "Flashing failed. Common fixes:"
    if ($Target -eq "heltec-v3") {
        Warn "  * Put the Heltec in download mode: hold PRG, tap RST, release PRG - then rerun."
        Warn "    (After flashing in that mode, tap RST once to start the new firmware.)"
    } else {
        Warn "  * Hold the BOOT button while it says 'Connecting...', release after it starts."
    }
    if ($Board -ne "auto") {
        Warn "  * esptool said 'Wrong --chip argument?' -> this board isn't a $($Info.Name): rerun without -Board."
    }
    Warn "  * Try a slower speed: ./flash.ps1 -Baud 460800"
    Warn "  * Close any serial monitor / Arduino IDE that may hold the port."
    throw "esptool exited with code $LASTEXITCODE."
}

if ($Target -eq "heltec-v3") {
    Say "Done. The Heltec V3 is now advertising as MagicMaker-ESP32 - pick the ESP32 backend in the app."
    Say "The screen stays dark to save battery: press PRG to light the screen."
} else {
    Say "Done. The ESP32 is now advertising as MagicMaker-ESP32 - pick the ESP32 backend in the app."
}
