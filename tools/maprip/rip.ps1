<#
.SYNOPSIS
  Rip the pre-1.0 (SPT 4.1.5 / EFT 0.16.9.5-40743, Unity 2022.3.43f1) maps out of
  D:\SPT415 with a PINNED AssetRipper, headless, one Unity project per location.

.DESCRIPTION
  MEASURED 2026-09-07 (see docs/MAP-RIP-AND-REIMPORT.md): the maps are NOT asset
  bundles. Every location is a set of scenes BUILT INTO THE PLAYER as
  EscapeFromTarkov_Data\level{N} + sharedassets{N}.assets (+ .resS); the only thing
  under StreamingAssets\Windows\maps\ is a 6-64 KB ScenesPreset that names those
  scenes. So this script stages, per location, exactly the level/sharedassets files
  its preset names (indices from tools\maprip\maps.json) plus the global files and
  Managed\, as HARD LINKS (same volume, zero copy), and points AssetRipper at that
  staging folder.

  AssetRipper 2.0.0 has NO export command line (measured: `--help` lists only
  --headless, --port, --log, --log-path, --local-web-file, --version). It is driven
  through its HTTP API instead (measured from /openapi.json):
     POST /LoadFolder            form Path=<dir>
     POST /Settings/Update       form <SettingName>=<value>
     POST /Export/UnityProject   form Path=<outdir>
  This script starts it with --headless --port and POSTs those.

  UNVERIFIED until the user runs it once: that LoadFolder / Export block until done
  (they are plain form POSTs; the script also polls /Collections/Count as a loaded
  signal), that a staged folder with only a subset of sharedassets{N} resolves every
  cross-file reference (sharedassets0 + resources.assets are always included; a
  missing reference exports as a missing PPtr, not a crash), and the export time
  (estimate: ~1-3 min per GB of staged data; Streets ~4 GB, Customs ~6.3 GB).

.PARAMETER Maps
  Location ids to rip (keys of maps.json). Default: factory4_day only -- the
  falsifiable first milestone. Use 'all' for every location.

.PARAMETER OutRoot
  Output root. Each map exports to <OutRoot>\<map>\ (a Unity project folder).

.PARAMETER DryRun
  Print what would be staged / posted; download nothing, run nothing.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\maprip\rip.ps1 -DryRun
  powershell -ExecutionPolicy Bypass -File tools\maprip\rip.ps1                 # factory4_day
  powershell -ExecutionPolicy Bypass -File tools\maprip\rip.ps1 -Maps Woods,bigmap
#>
[CmdletBinding()]
param(
  [string[]]$Maps = @('factory4_day'),
  [string]$GameData = 'D:\SPT415\EscapeFromTarkov_Data',
  [string]$OutRoot = 'D:\aowlspt-maprip',
  [string]$ToolRoot = (Join-Path $env:LOCALAPPDATA 'aowlspt\assetripper'),
  [int]$Port = 47311,
  [switch]$DryRun,
  [switch]$KeepStaging
)
$ErrorActionPreference = 'Stop'

# ---- pinned AssetRipper (measured 2026-09-07 via api.github.com/repos/AssetRipper/AssetRipper/releases/latest)
$ArVersion = '2.0.0'
$ArUrl     = "https://github.com/AssetRipper/AssetRipper/releases/download/$ArVersion/AssetRipper_win_x64.zip"
$ArSha256  = '9a7ef0e7c5c3ea5b90b4e6d855e2d98d5f7ec8c3f9e26fccbc194c6a7b01baf7'   # measured sha256sum of the 44,439,367-byte zip
$ArExe     = 'AssetRipper.GUI.Free.exe'

# ---- export settings (names measured from GET /Settings/Edit on 2.0.0)
$ArSettings = @{
  ScriptExportMode            = 'Hybrid'      # measured default; decompiles game scripts, keeps DLLs for the rest
  ShaderExportMode            = 'Dummy'       # measured default; EFT shaders are stripped -> Dummy avoids pink-material compile errors at reimport
  ScriptContentLevel          = 'Level1'
  BundledAssetsExportMode     = 'DirectExport'
  LightmapTextureExportFormat = 'Exr'
  ImageExportFormat           = 'Png'
  EnableStaticMeshSeparation  = 'true'
  EnablePrefabOutlining       = 'false'
  IgnoreStreamingAssets       = 'true'        # we stage nothing from StreamingAssets on purpose
}

function Say([string]$m) { Write-Host "[maprip] $m" }
function Fail([string]$m) { Write-Host "[maprip] FAIL: $m" -ForegroundColor Red; exit 1 }

# ---- 0. inputs
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mapsJson = Join-Path $here 'maps.json'
if (-not (Test-Path $mapsJson)) { Fail "missing $mapsJson (generated from the measured BuildSettings; see the doc)" }
$catalog = Get-Content -Raw $mapsJson | ConvertFrom-Json
if (-not (Test-Path (Join-Path $GameData 'globalgamemanagers'))) { Fail "$GameData has no globalgamemanagers -- is this EscapeFromTarkov_Data?" }

$unity = (Get-Item (Join-Path (Split-Path $GameData) 'UnityPlayer.dll')).VersionInfo.ProductVersion
if ($unity -notlike '2022.3.43f1*') { Say "WARNING: UnityPlayer.dll reports '$unity', the catalog was measured on 2022.3.43f1 -- level indices may not match" }

$allNames = @($catalog.locations.PSObject.Properties.Name)
$Maps = @($Maps | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })   # `powershell -File` hands "-Maps a,b" over as ONE string
if ($Maps -contains 'all') { $Maps = $allNames }
foreach ($m in $Maps) { if ($allNames -notcontains $m) { Fail "unknown map '$m'; known: $($allNames -join ', ')" } }

# ---- 1. tool
$arDir = Join-Path $ToolRoot $ArVersion
$arPath = Join-Path $arDir $ArExe
if ($DryRun) {
  Say "DRYRUN: would download $ArUrl -> $arDir (sha256 $ArSha256)"
} elseif (-not (Test-Path $arPath)) {
  New-Item -ItemType Directory -Force $arDir | Out-Null
  $zip = Join-Path $arDir 'AssetRipper_win_x64.zip'
  Say "downloading AssetRipper $ArVersion"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri $ArUrl -OutFile $zip -UseBasicParsing
  $got = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
  if ($got -ne $ArSha256) { Remove-Item $zip; Fail "sha256 mismatch: got $got expected $ArSha256 -- refusing to run an unpinned binary" }
  Expand-Archive -Path $zip -DestinationPath $arDir -Force
  if (-not (Test-Path $arPath)) { Fail "zip did not contain $ArExe" }
}

# ---- 2. per map
$globalFiles = @('globalgamemanagers','globalgamemanagers.assets','resources.assets','resources.assets.resS','resources.resource',
                 'sharedassets0.assets','sharedassets0.assets.resS','level0','level0.resS')

function Stage-Map([string]$map, [string]$stage) {
  $loc = $catalog.locations.$map
  if (-not $DryRun) {
    if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
    New-Item -ItemType Directory -Force $stage | Out-Null
  }
  $files = New-Object System.Collections.Generic.List[string]
  foreach ($g in $globalFiles) { if (Test-Path (Join-Path $GameData $g)) { $files.Add($g) } }
  foreach ($s in $loc.scenes) {
    $i = $s.buildIndex
    foreach ($f in @("level$i", "level$i.resS", "sharedassets$i.assets", "sharedassets$i.assets.resS")) {
      if (Test-Path (Join-Path $GameData $f)) { $files.Add($f) }
    }
  }
  $bytes = 0
  foreach ($f in $files) {
    $src = Join-Path $GameData $f; $dst = Join-Path $stage $f
    $bytes += (Get-Item $src).Length
    if (-not $DryRun) {
      try { New-Item -ItemType HardLink -Path $dst -Target $src | Out-Null }
      catch { Copy-Item $src $dst }   # different volume -> copy
    }
  }
  # Managed\ is needed for script typetrees (AssetRipper "Mono scripts from bundles" note); link the whole dir
  $man = Join-Path $stage 'Managed'
  if (-not $DryRun) {
    New-Item -ItemType Directory -Force $man | Out-Null
    Get-ChildItem (Join-Path $GameData 'Managed') -Filter *.dll | ForEach-Object {
      try { New-Item -ItemType HardLink -Path (Join-Path $man $_.Name) -Target $_.FullName | Out-Null } catch { Copy-Item $_.FullName $man }
    }
  }
  Say ("staged {0}: {1} scenes, {2} files, {3:N2} GB (+Managed)" -f $map, $loc.scenes.Count, $files.Count, ($bytes/1GB))
  return $bytes
}

function Post-Form([string]$path, [hashtable]$form, [int]$timeoutSec) {
  $body = ($form.GetEnumerator() | ForEach-Object { [uri]::EscapeDataString($_.Key) + '=' + [uri]::EscapeDataString([string]$_.Value) }) -join '&'
  return Invoke-WebRequest -Uri "http://127.0.0.1:$Port$path" -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -TimeoutSec $timeoutSec
}

function Start-Ripper([string]$logPath) {
  $p = Start-Process -FilePath $arPath -ArgumentList @('--headless','--port',"$Port",'--log','true','--log-path',"`"$logPath`"") -PassThru -WindowStyle Hidden
  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $deadline) {
    try { Invoke-WebRequest -Uri "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 5 | Out-Null; return $p } catch { Start-Sleep -Milliseconds 500 }
  }
  Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  Fail "AssetRipper did not answer on port $Port within 60 s (log: $logPath)"
}

if (-not $DryRun) { New-Item -ItemType Directory -Force $OutRoot | Out-Null }
$report = @()
foreach ($map in $Maps) {
  $stage = Join-Path $OutRoot "_staging\$map`_Data"
  $out   = Join-Path $OutRoot $map
  $log   = Join-Path $OutRoot "$map.assetripper.log"
  $bytes = Stage-Map $map $stage
  if ($DryRun) {
    Say "DRYRUN: would start `"$arPath`" --headless --port $Port; POST /Settings/Update; POST /LoadFolder Path=$stage; POST /Export/UnityProject Path=$out"
    continue
  }
  if (Test-Path $out) { Say "output $out exists -- AssetRipper clears its export dir; delete it yourself if you want a clean run" }
  $proc = Start-Ripper $log
  try {
    $t0 = Get-Date
    Post-Form '/Settings/Update' $ArSettings 60 | Out-Null
    Say "loading $stage"
    Post-Form '/LoadFolder' @{ Path = $stage } 7200 | Out-Null
    $cnt = (Invoke-WebRequest -Uri "http://127.0.0.1:$Port/Collections/Count" -UseBasicParsing -TimeoutSec 60).Content
    Say "loaded: collections=$cnt in $([int]((Get-Date)-$t0).TotalSeconds)s"
    if ("$cnt" -match '^\s*0\s*$') { Fail "AssetRipper loaded 0 collections from $stage -- nothing to export (check $log)" }
    Say "exporting Unity project -> $out (this is the slow part)"
    Post-Form '/Export/UnityProject' @{ Path = $out } 21600 | Out-Null
    $secs = [int]((Get-Date)-$t0).TotalSeconds
    # a verification that can fail: the export must contain scene files named like the preset's scenes
    $want = @($catalog.locations.$map.scenes | ForEach-Object { $_.name })
    $have = @(Get-ChildItem -Recurse -Filter *.unity $out -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
    $missing = @($want | Where-Object { $have -notcontains $_ })
    $verdict = if ($have.Count -eq 0) { 'INCONCLUSIVE (no .unity files at all -- read the log)' } elseif ($missing.Count -gt 0) { "FAIL (missing scenes: $($missing -join ', '))" } else { 'PASS' }
    Say "$map : $verdict  scenes exported=$($have.Count)/$($want.Count) in ${secs}s"
    $report += [pscustomobject]@{ map=$map; verdict=$verdict; scenes="$($have.Count)/$($want.Count)"; seconds=$secs; stagedGB=[math]::Round($bytes/1GB,2); out=$out }
  } finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    if (-not $KeepStaging) { Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue }
  }
}
if ($report.Count) { $report | Format-Table -AutoSize | Out-String | Write-Host }
if ($report | Where-Object { $_.verdict -ne 'PASS' }) { exit 1 }
