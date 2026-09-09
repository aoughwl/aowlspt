<#
.SYNOPSIS
  Rip the pre-1.0 (SPT 4.1.5 / EFT 0.16.9.5-40743, Unity 2022.3.43f1) maps out of
  D:\SPT415 with a PINNED AssetRipper, headless, one Unity project per location.

.DESCRIPTION
  MEASURED 2026-09-07 (docs/MAP-RIP-AND-REIMPORT.md): the maps are NOT asset bundles.
  Every location is a set of scenes BUILT INTO THE PLAYER as
  EscapeFromTarkov_Data\level{N} + sharedassets{N}.assets (+ .resS); the only thing
  under StreamingAssets\Windows\maps\ is a 6-64 KB ScenesPreset that names those
  scenes. And the sharedassets files reference each other transitively: the
  dependency closure of ONE map is 344-662 files / 17-19 GB (all 13: 1,542 files /
  22.6 GB). So per map this script stages, as HARD LINKS (same volume, zero copy):
  the map's level{N} files + the measured closure of sharedassets (+.resS) +
  globalgamemanagers/resources.assets + Managed\, listed in maps.json
  (`closureFiles`), and points AssetRipper at that folder. Scenes exported = that
  map's only; assets exported = most of the game's (unavoidable, see the doc).

  AssetRipper 2.0.0 has NO export command line (measured: `--help` lists only
  --headless, --port, --log, --log-path, --local-web-file, --version). It is driven
  through its HTTP API (measured from /openapi.json):
     POST /LoadFolder            form Path=<dir>      -> 302 immediately, work is ASYNC
     POST /Settings/Update       form <Setting>=<value>
     POST /Export/UnityProject   form Path=<outdir>   -> 302 immediately, work is ASYNC
  Progress and completion are only visible on the process's STDOUT (measured):
     "Processing : Finished processing assets"   = load done
     "Export : Finished post-export"             = export done
  so the script redirects stdout to <OutRoot>\<map>.assetripper.log and polls it.
  (`/Collections/Count` is per-collection and 404s without a Path -- it is NOT a
  global readiness signal; measured.)

.PARAMETER Maps
  Location ids to rip (keys of maps.json). Default: factory4_day only -- the
  falsifiable first milestone. 'all' = every location.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\maprip\rip.ps1 -DryRun
  powershell -ExecutionPolicy Bypass -File tools\maprip\rip.ps1 -OutRoot D:\aowlspt-maprip -ToolRoot D:\aowlspt-tools\assetripper -TempDir D:\aowlspt-tools\tmp
#>
[CmdletBinding()]
param(
  [string[]]$Maps = @('factory4_day'),
  [string]$GameData = 'D:\SPT415\EscapeFromTarkov_Data',
  [string]$OutRoot = 'D:\aowlspt-maprip',
  [string]$ToolRoot = 'D:\aowlspt-tools\assetripper',
  [string]$TempDir = 'D:\aowlspt-tools\tmp',
  [int]$Port = 47311,
  [int]$LoadTimeoutMin = 180,
  [int]$ExportTimeoutMin = 720,
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
  ScriptExportMode            = 'Hybrid'      # measured default; decompiles what it can, keeps DLLs
  ShaderExportMode            = 'Dummy'       # measured default; EFT shaders are stripped -> Dummy avoids pink-material compile errors at reimport
  ScriptContentLevel          = 'Level1'
  BundledAssetsExportMode     = 'DirectExport'
  LightmapTextureExportFormat = 'Exr'
  ImageExportFormat           = 'Png'
  EnableStaticMeshSeparation  = 'true'
  EnablePrefabOutlining       = 'false'
  IgnoreStreamingAssets       = 'true'
}

function Say([string]$m) { Write-Host ("[maprip {0:HH:mm:ss}] {1}" -f (Get-Date), $m) }
function Fail([string]$m) { Write-Host "[maprip] FAIL: $m" -ForegroundColor Red; exit 1 }

# ---- 0. inputs
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mapsJson = Join-Path $here 'maps.json'
if (-not (Test-Path $mapsJson)) { Fail "missing $mapsJson" }
$catalog = Get-Content -Raw $mapsJson | ConvertFrom-Json
if (-not (Test-Path (Join-Path $GameData 'globalgamemanagers'))) { Fail "$GameData has no globalgamemanagers -- is this EscapeFromTarkov_Data?" }
$unity = (Get-Item (Join-Path (Split-Path $GameData) 'UnityPlayer.dll')).VersionInfo.ProductVersion
if ($unity -notlike '2022.3.43f1*') { Say "WARNING: UnityPlayer.dll reports '$unity'; maps.json was measured on 2022.3.43f1 -- level indices may not match" }

$allNames = @($catalog.locations.PSObject.Properties.Name)
$Maps = @($Maps | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })   # `powershell -File` hands "-Maps a,b" over as ONE string
if ($Maps -contains 'all') { $Maps = $allNames }
foreach ($m in $Maps) { if ($allNames -notcontains $m) { Fail "unknown map '$m'; known: $($allNames -join ', ')" } }
if ((Split-Path -Qualifier $OutRoot) -ieq 'C:') { Say "WARNING: OutRoot is on C: (measured 8.8 GB free on 2026-09-07); exports are tens of GB" }

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

# ---- 2. helpers
function Stage-Map([string]$map, [string]$stage) {
  $loc = $catalog.locations.$map
  $files = @($loc.closureFiles)
  if (-not $files -or $files.Count -eq 0) { Fail "maps.json has no closureFiles for $map (regenerate with the UnityPy closure script in the doc)" }
  if (-not $DryRun) {
    if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
    New-Item -ItemType Directory -Force $stage | Out-Null
  }
  $bytes = 0; $n = 0
  foreach ($f in $files) {
    $src = Join-Path $GameData $f
    if (-not (Test-Path $src)) { continue }
    $bytes += (Get-Item $src).Length; $n++
    if (-not $DryRun) {
      $dst = Join-Path $stage $f
      try { New-Item -ItemType HardLink -Path $dst -Target $src | Out-Null } catch { Copy-Item $src $dst }
    }
  }
  if (-not $DryRun) {
    $man = Join-Path $stage 'Managed'; New-Item -ItemType Directory -Force $man | Out-Null
    Get-ChildItem (Join-Path $GameData 'Managed') -Filter *.dll | ForEach-Object {
      try { New-Item -ItemType HardLink -Path (Join-Path $man $_.Name) -Target $_.FullName | Out-Null } catch { Copy-Item $_.FullName $man }
    }
  }
  Say ("staged {0}: {1} scenes, {2} files, {3:N2} GB (+Managed)" -f $map, $loc.scenes.Count, $n, ($bytes/1GB))
  return $bytes
}

function Post-Form([string]$path, [hashtable]$form) {
  $body = ($form.GetEnumerator() | ForEach-Object { [uri]::EscapeDataString($_.Key) + '=' + [uri]::EscapeDataString([string]$_.Value) }) -join '&'
  # both Load and Export answer 302 at once; -MaximumRedirection 0 keeps IWR from following it and throwing
  try { Invoke-WebRequest -Uri "http://127.0.0.1:$Port$path" -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -TimeoutSec 120 -MaximumRedirection 0 -ErrorAction SilentlyContinue | Out-Null } catch { }
}

function Start-Ripper([string]$outLog, [string]$errLog) {
  New-Item -ItemType Directory -Force $TempDir | Out-Null
  $env:TEMP = $TempDir; $env:TMP = $TempDir
  $p = Start-Process -FilePath $arPath -ArgumentList @('--headless','--port',"$Port") -PassThru -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog
  $deadline = (Get-Date).AddSeconds(120)
  while ((Get-Date) -lt $deadline) {
    if ($p.HasExited) { Fail "AssetRipper exited at startup (code $($p.ExitCode)); see $errLog" }
    try { Invoke-WebRequest -Uri "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 5 | Out-Null; return $p } catch { Start-Sleep -Milliseconds 500 }
  }
  Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  Fail "AssetRipper did not answer on port $Port within 120 s (stderr: $errLog)"
}

# Poll the stdout log for a done-line; track peak RAM; return 'done' | 'died' | 'timeout' | 'error'
function Wait-LogLine($proc, [string]$log, [string]$doneMarker, [int]$timeoutMin, [ref]$peakGB) {
  $deadline = (Get-Date).AddMinutes($timeoutMin); $lastReport = Get-Date; $lastLine = ''
  while ((Get-Date) -lt $deadline) {
    try { $proc.Refresh(); $ws = $proc.PeakWorkingSet64 / 1GB; if ($ws -gt $peakGB.Value) { $peakGB.Value = $ws } } catch { }
    # MEASURED 2026-09-07: [IO.File]::ReadAllText is DENIED while Start-Process's redirect holds the file
    # (the first run loaded in 18 s and the poller never saw it, because a swallowed exception read as "not yet").
    # Open with FileShare.ReadWrite, and never swallow: an unreadable log is a hard failure, not "still loading".
    $text = ''
    try {
      $fs = [IO.FileStream]::new($log, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
      try { $sr = [IO.StreamReader]::new($fs); $text = $sr.ReadToEnd() } finally { $fs.Dispose() }
    } catch { Fail "cannot read $log while AssetRipper runs ($_) -- the poller would spin until timeout" }
    if ($text -match [regex]::Escape($doneMarker)) { return 'done' }
    if ($text -match '(?m)^(Unhandled exception|.*OutOfMemory|Fatal error)') { return 'error' }
    if ($proc.HasExited) { return 'died' }
    if (((Get-Date) - $lastReport).TotalSeconds -ge 60) {
      $lines = @($text -split "`r?`n" | Where-Object { $_ -ne '' }); if ($lines.Count) { $lastLine = $lines[-1] }
      Say ("  ... {0}  (RAM now {1:N1} GB, peak {2:N1} GB)" -f $lastLine, ($proc.WorkingSet64/1GB), $peakGB.Value)
      $lastReport = Get-Date
    }
    Start-Sleep -Seconds 5
  }
  return 'timeout'
}

# ---- 3. per map
if (-not $DryRun) { New-Item -ItemType Directory -Force $OutRoot | Out-Null }
$report = @()
foreach ($map in $Maps) {
  $stage = Join-Path $OutRoot "_staging\$map`_Data"
  $out   = Join-Path $OutRoot $map
  $log   = Join-Path $OutRoot "$map.assetripper.log"
  $elog  = Join-Path $OutRoot "$map.assetripper.err.log"
  $bytes = Stage-Map $map $stage
  if ($DryRun) {
    Say "DRYRUN: would start `"$arPath`" --headless --port $Port (stdout -> $log); POST /Settings/Update; POST /LoadFolder Path=$stage; wait 'Finished processing assets'; POST /Export/UnityProject Path=$out; wait 'Finished post-export'"
    continue
  }
  if (Test-Path $out) { Say "output $out exists -- AssetRipper clears its export dir" }
  $proc = Start-Ripper $log $elog
  $peak = 0.0; $t0 = Get-Date; $verdict = 'INCONCLUSIVE'; $loadSecs = 0; $exportSecs = 0; $have = @()
  try {
    Post-Form '/Settings/Update' $ArSettings
    Say "loading $stage (async; polling $log)"
    Post-Form '/LoadFolder' @{ Path = $stage }
    $r = Wait-LogLine $proc $log 'Processing : Finished processing assets' $LoadTimeoutMin ([ref]$peak)
    $loadSecs = [int]((Get-Date) - $t0).TotalSeconds
    if ($r -ne 'done') { $verdict = "INCONCLUSIVE (load $r after ${loadSecs}s, peak RAM $([math]::Round($peak,1)) GB; read $log / $elog)"; throw 'load' }
    Say "loaded in ${loadSecs}s (peak RAM $([math]::Round($peak,1)) GB); exporting -> $out"
    $t1 = Get-Date
    Post-Form '/Export/UnityProject' @{ Path = $out }
    $r = Wait-LogLine $proc $log 'Export : Finished post-export' $ExportTimeoutMin ([ref]$peak)
    $exportSecs = [int]((Get-Date) - $t1).TotalSeconds
    if ($r -ne 'done') { $verdict = "INCONCLUSIVE (export $r after ${exportSecs}s, peak RAM $([math]::Round($peak,1)) GB; read $log / $elog)"; throw 'export' }
    # a verification that can fail: the export must contain a .unity for every scene the preset names
    $want = @($catalog.locations.$map.scenes | ForEach-Object { $_.name })
    $have = @(Get-ChildItem -Recurse -Filter *.unity $out -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
    $missing = @($want | Where-Object { $have -notcontains $_ })
    $verdict = if ($have.Count -eq 0) { 'INCONCLUSIVE (no .unity files at all -- read the log)' } elseif ($missing.Count -gt 0) { "FAIL (missing scenes: $($missing -join ', '))" } else { 'PASS' }
  } catch {
    if ($_.ToString() -notin @('load','export')) { $verdict = "INCONCLUSIVE (script error: $_)" }
  } finally {
    try { $proc.Refresh(); if ($proc.PeakWorkingSet64/1GB -gt $peak) { $peak = $proc.PeakWorkingSet64/1GB } } catch { }
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    if (-not $KeepStaging) { Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue }
  }
  # log census (counts are evidence, the .unity check above is the verdict)
  $text = ''; try { $text = [IO.File]::ReadAllText($log) } catch { }
  $depMissing = ([regex]::Matches($text, "Dependency '[^']+' wasn't found")).Count
  $errors     = ([regex]::Matches($text, '(?m)^(Error|.*Exception)')).Count
  $outGB = 0; $meshes = 0; $mats = 0; $prefabs = 0
  if (Test-Path $out) {
    $outGB = [math]::Round(((Get-ChildItem -Recurse -File $out | Measure-Object Length -Sum).Sum/1GB), 2)
    $meshes  = @(Get-ChildItem -Recurse -File $out -Include *.fbx,*.obj,*.mesh -ErrorAction SilentlyContinue).Count + @(Get-ChildItem -Recurse -Path (Join-Path $out 'ExportedProject\Assets\Mesh') -File -Filter *.asset -ErrorAction SilentlyContinue).Count
    $mats    = @(Get-ChildItem -Recurse -File $out -Filter *.mat -ErrorAction SilentlyContinue).Count
    $prefabs = @(Get-ChildItem -Recurse -File $out -Filter *.prefab -ErrorAction SilentlyContinue).Count
  }
  $line = "VERDICT $map : $verdict | scenes=$($have.Count)/$(@($catalog.locations.$map.scenes).Count) meshes=$meshes materials=$mats prefabs=$prefabs | load=${loadSecs}s export=${exportSecs}s peakRAM=$([math]::Round($peak,1))GB staged=$([math]::Round($bytes/1GB,2))GB out=${outGB}GB | log: depMissing=$depMissing errorLines=$errors"
  Say $line
  $report += $line
}
if ($report.Count) { $report | ForEach-Object { Write-Host $_ } }
if ($report | Where-Object { $_ -notmatch ': PASS ' }) { exit 1 }
