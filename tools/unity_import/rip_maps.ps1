<#
    rip_maps.ps1  --  one-command AssetRipper driver for the EFT map importer.

    Rips the Escape From Tarkov game data into a fresh, openable Unity project so
    the Editor menu "Aowlspt/Import + Unify World (grid)" can load every map at
    once. Then copies the Editor importer into the exported project so the menu is
    there when you open it.

    The official *free* AssetRipper build (AssetRipper.GUI.Free) has NO true CLI,
    but it can run --headless with a fixed --port and be driven entirely over its
    localhost HTTP API. This script uses that: launch headless -> POST /LoadFolder
    -> POST /Export/UnityProject -> stop. No windows, no clicks.

    If your AssetRipper build is too old to accept --headless (or the HTTP drive
    fails), re-run with -Interactive and it launches the GUI and prints the exact
    clicks instead.

    USAGE (PowerShell, from anywhere):
        pwsh -File tools\unity_import\rip_maps.ps1
        pwsh -File tools\unity_import\rip_maps.ps1 -AssetRipperPath "D:\Tools\AssetRipper\AssetRipper.GUI.Free.exe"
        pwsh -File tools\unity_import\rip_maps.ps1 -Interactive

    This script does NOT modify the game, the deploy at D:\Aowlspt\aowlspt, and
    never launches Escape From Tarkov. It only reads the game DATA folder.
#>

[CmdletBinding()]
param(
    # Folder that contains globalgamemanagers + the level* files.
    [string]$GameDataDir = "D:\Aowlspt\EscapeFromTarkov_Data",

    # Where the exported Unity project is written (needs many GB free).
    [string]$OutputDir = "D:\Aowlspt\ripped\eft-unity",

    # AssetRipper.GUI.Free.exe. If omitted, common locations + $env:ASSETRIPPER_HOME
    # are probed.
    [string]$AssetRipperPath = "",

    # Fixed localhost port for the headless HTTP drive.
    [int]$Port = 57893,

    # Launch the GUI with a browser for manual export instead of driving headless.
    [switch]$Interactive
)

$ErrorActionPreference = "Stop"
$UNITY_VERSION = "2022.3.43f2"   # measured from globalgamemanagers on this build

function Note($m)  { Write-Host "[rip_maps] $m" -ForegroundColor Cyan }
function Warn($m)  { Write-Host "[rip_maps] $m" -ForegroundColor Yellow }
function Die($m)   { Write-Host "[rip_maps] ERROR: $m" -ForegroundColor Red; exit 2 }

# ---------------------------------------------------------------- validate input

if (-not (Test-Path (Join-Path $GameDataDir "globalgamemanagers"))) {
    Die "No 'globalgamemanagers' under '$GameDataDir'. Point -GameDataDir at the *_Data folder."
}
Note "Game data:   $GameDataDir"
Note "Unity build: $UNITY_VERSION  (your Unity Editor MUST match this exactly)"
Note "Output:      $OutputDir"

# ------------------------------------------------------------- locate AssetRipper

function Find-AssetRipper {
    param([string]$Explicit)
    if ($Explicit) {
        if (Test-Path $Explicit) { return (Resolve-Path $Explicit).Path }
        Die "-AssetRipperPath '$Explicit' does not exist."
    }
    $candidates = @()
    if ($env:ASSETRIPPER_HOME) {
        $candidates += (Join-Path $env:ASSETRIPPER_HOME "AssetRipper.GUI.Free.exe")
    }
    $candidates += @(
        "D:\Tools\AssetRipper\AssetRipper.GUI.Free.exe",
        "C:\Tools\AssetRipper\AssetRipper.GUI.Free.exe",
        "$env:LOCALAPPDATA\AssetRipper\AssetRipper.GUI.Free.exe"
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path } }
    return $null
}

$ar = Find-AssetRipper -Explicit $AssetRipperPath
if (-not $ar) {
    Warn "AssetRipper not found. To install (one time):"
    Warn "  1. Open https://github.com/AssetRipper/AssetRipper/releases/latest"
    Warn "  2. Download the Windows x64 asset: AssetRipper_win_x64.zip"
    Warn "  3. Extract it to  D:\Tools\AssetRipper\"
    Warn "  4. Confirm  D:\Tools\AssetRipper\AssetRipper.GUI.Free.exe  exists"
    Warn "  5. Re-run this script (or pass -AssetRipperPath <exe>)."
    Die  "AssetRipper.GUI.Free.exe not located."
}
Note "AssetRipper: $ar"

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# The Editor importer that we copy into the exported project.
$editorSrc = Join-Path $PSScriptRoot "Editor\AowlEftMapImporter.cs"
if (-not (Test-Path $editorSrc)) {
    Warn "Editor importer not found next to this script ($editorSrc); export will still run."
    $editorSrc = $null
}

# --------------------------------------------------------------------- interactive

if ($Interactive) {
    Note "Launching AssetRipper GUI for a MANUAL export."
    Start-Process -FilePath $ar
    Write-Host ""
    Write-Host "  In the AssetRipper window:" -ForegroundColor Green
    Write-Host "    1. File -> Open Folder  ->  $GameDataDir" -ForegroundColor Green
    Write-Host "       (wait for it to finish loading; EFT is large -> minutes)" -ForegroundColor Green
    Write-Host "    2. Export -> Export all files to Unity project" -ForegroundColor Green
    Write-Host "    3. Choose output folder:  $OutputDir" -ForegroundColor Green
    Write-Host "    4. When done, close AssetRipper and run:" -ForegroundColor Green
    Write-Host "         pwsh -File tools\unity_import\rip_maps.ps1 -PostExport" -ForegroundColor Green
    Write-Host "       (or copy Editor\AowlEftMapImporter.cs into <project>\Assets\Editor\ yourself)" -ForegroundColor Green
    exit 0
}

# ----------------------------------------------------------- headless HTTP drive

$baseUrl = "http://127.0.0.1:$Port"
Note "Starting AssetRipper headless on $baseUrl ..."

$proc = Start-Process -FilePath $ar -ArgumentList @("--headless", "--port", "$Port") -PassThru

function Wait-Server {
    param([string]$Url, [int]$TimeoutSec = 90)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec 5 -UseBasicParsing | Out-Null
            return $true
        } catch {
            if ($proc.HasExited) { return $false }
            Start-Sleep -Milliseconds 800
        }
    }
    return $false
}

function Post-Command {
    param([string]$Path, [hashtable]$Body, [int]$TimeoutSec = 7200)
    # AssetRipper's form endpoints are POST application/x-www-form-urlencoded.
    Invoke-WebRequest -Uri "$baseUrl$Path" -Method Post -Body $Body `
        -ContentType "application/x-www-form-urlencoded" `
        -TimeoutSec $TimeoutSec -UseBasicParsing | Out-Null
}

try {
    if (-not (Wait-Server -Url $baseUrl -TimeoutSec 90)) {
        Warn "Headless server did not answer on $baseUrl."
        Warn "Your AssetRipper build may predate --headless. Re-run with -Interactive."
        Die  "Could not reach the AssetRipper HTTP API."
    }
    Note "Server up. Loading game folder (this can take several minutes for EFT) ..."
    Post-Command -Path "/LoadFolder" -Body @{ Path = $GameDataDir }

    Note "Exporting full Unity project to $OutputDir (long; tens of minutes, many GB) ..."
    Post-Command -Path "/Export/UnityProject" -Body @{ Path = $OutputDir; CreateSubfolder = "true" }

    Note "Export finished. Resetting AssetRipper."
    try { Post-Command -Path "/Reset" -Body @{ } -TimeoutSec 60 } catch { }
}
finally {
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
}

# ------------------------------------------------- locate exported project + wire

# AssetRipper writes a Unity project (Assets/ + ProjectSettings/) under $OutputDir,
# usually in a subfolder. Find the folder that holds ProjectSettings\ProjectVersion.txt.
$projRoot = $null
$pv = Get-ChildItem -Path $OutputDir -Recurse -Filter "ProjectVersion.txt" -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match "ProjectSettings\\ProjectVersion.txt$" } |
      Select-Object -First 1
if ($pv) { $projRoot = Split-Path (Split-Path $pv.FullName -Parent) -Parent }

if (-not $projRoot) {
    Warn "Could not locate the exported project (no ProjectSettings\ProjectVersion.txt under $OutputDir)."
    Warn "The export may have failed, or the layout differs. Inspect $OutputDir by hand."
    Die  "Export verification failed."
}

Note "Exported Unity project: $projRoot"
try {
    $ver = (Get-Content $pv.FullName -First 1)
    Note "Project's Unity version line: $ver  (open with $UNITY_VERSION)"
} catch { }

# Copy the Editor importer in so the menu appears on open.
if ($editorSrc) {
    $editorDst = Join-Path $projRoot "Assets\Editor"
    New-Item -ItemType Directory -Force -Path $editorDst | Out-Null
    Copy-Item $editorSrc (Join-Path $editorDst "AowlEftMapImporter.cs") -Force
    Note "Installed importer -> $editorDst\AowlEftMapImporter.cs"
}

Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Green
Write-Host "  1. Install Unity $UNITY_VERSION via Unity Hub (exact version)." -ForegroundColor Green
Write-Host "  2. Unity Hub -> Add -> select:  $projRoot" -ForegroundColor Green
Write-Host "  3. Open it (first import is slow; textures/meshes reprocess)." -ForegroundColor Green
Write-Host "  4. Menu bar -> Aowlspt -> 'Import + Unify World (grid)'." -ForegroundColor Green
Write-Host "     (or 'EFT Map Importer Window' to load one map at a time)" -ForegroundColor Green
Write-Host ""
Write-Host "Caveat: BSG shaders/scripts do not survive the rip -- geometry + textures" -ForegroundColor Yellow
Write-Host "are real; materials fall back to Standard shader; MonoBehaviours are stubs." -ForegroundColor Yellow
