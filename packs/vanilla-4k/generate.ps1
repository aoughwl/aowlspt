<#
  generate.ps1 -- Vanilla 4K resource-pack GENERATOR (runs on YOUR machine).

  This pack ships NO game assets. It builds a 4K texture pack FROM YOUR OWN local
  Escape from Tarkov install: it extracts your textures from the game's Unity
  asset bundles, upscales them to 4K, and writes a resource pack into .\assets +
  .\manifest.json that the aowlspt resource-pack loader consumes. Nothing
  copyrighted is ever distributed -- everything is produced locally from files
  you already own.

  PIPELINE (staged, idempotent, resumable -- re-run any time; done work is skipped)

    extract   Dump textures from the game bundles to PNG   (needs an EXTRACTOR, see below)
    upscale   4x-upscale each PNG to 4K                    (needs Real-ESRGAN, see below)
    manifest  Build manifest.json from the upscaled files  (no external dependency)
    all       extract -> upscale -> manifest

  USAGE
    .\generate.ps1 -Stage all
    .\generate.ps1 -Stage upscale                 # resume from already-extracted PNGs
    .\generate.ps1 -Stage all -TarkovDir "C:\Battlestate Games\EFT" `
                   -Extractor "C:\tools\AssetStudioModCLI\AssetStudioModCLI.exe" `
                   -Upscaler "C:\tools\realesrgan\realesrgan-ncnn-vulkan.exe"

  EXTERNAL DEPENDENCIES (NOT bundled -- you download these once)
    * Real-ESRGAN (portable, no Python): "realesrgan-ncnn-vulkan"
        https://github.com/xinntao/Real-ESRGAN/releases  (a single .exe + models/)
    * An asset extractor CLI, one of:
        - AssetStudioModCLI  https://github.com/aelurum/AssetStudio
        - AssetRipper        https://github.com/AssetRipper/AssetRipper
      (see the "extract" stage note below -- extraction wiring is provided but
       marked NOT-DONE where it needs validation against a real install.)
#>
[CmdletBinding()]
param(
  [ValidateSet("extract","upscale","manifest","all")]
  [string]$Stage = "all",
  [string]$TarkovDir = "",
  [string]$Extractor = "",
  [string]$Upscaler  = "",
  [string]$Model     = "realesrgan-x4plus",   # 4x general model
  [int]$Scale        = 4
)
$ErrorActionPreference = "Stop"
$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$rawDir   = Join-Path $here "work\extracted"    # extracted PNGs (intermediate)
$upDir    = Join-Path $here "assets"            # upscaled 4K outputs (the pack)
$manifest = Join-Path $here "manifest.json"
$template = Join-Path $here "manifest.template.json"

function Info($m){ Write-Host "[vanilla-4k] $m" }
function Warn($m){ Write-Warning $m }
function Die($m){ Write-Error $m; exit 1 }

# ---------------------------------------------------------------------------
# locate the Tarkov install
# ---------------------------------------------------------------------------
function Resolve-TarkovDir {
  if ($TarkovDir -ne "") { return $TarkovDir }
  # Registry: BSG installer records the install path.
  $keys = @(
    "HKLM:\SOFTWARE\WOW6432Node\Battlestate Games\EscapeFromTarkov",
    "HKLM:\SOFTWARE\Battlestate Games\EscapeFromTarkov"
  )
  foreach ($k in $keys) {
    try {
      $p = (Get-ItemProperty -Path $k -ErrorAction Stop).InstallLocation
      if ($p -and (Test-Path $p)) { return $p }
    } catch {}
  }
  return ""
}

# ---------------------------------------------------------------------------
# locate an external tool: explicit param -> PATH -> .\tools
# ---------------------------------------------------------------------------
function Resolve-Tool([string]$explicit, [string]$exeName) {
  if ($explicit -ne "") {
    if (Test-Path $explicit) { return $explicit }
    Die "Specified tool not found: $explicit"
  }
  $cmd = Get-Command $exeName -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $local = Join-Path $here ("tools\" + $exeName)
  if (Test-Path $local) { return $local }
  return ""
}

# ===========================================================================
# STAGE: extract
# ===========================================================================
function Invoke-Extract {
  $tk = Resolve-TarkovDir
  if ($tk -eq "") {
    Die "Could not find your Tarkov install. Pass -TarkovDir `"<path to EFT>`"."
  }
  Info "Tarkov install: $tk"

  # Bundles live under <install>\EscapeFromTarkov_Data\StreamingAssets\Windows
  # (and referenced bundles). Texture-bearing bundles are the target.
  $bundleRoot = Join-Path $tk "EscapeFromTarkov_Data\StreamingAssets\Windows"
  if (-not (Test-Path $bundleRoot)) {
    Warn "Bundle root not found at $bundleRoot -- your layout may differ."
  }

  $ex = Resolve-Tool $Extractor "AssetStudioModCLI.exe"
  if ($ex -eq "") {
    Die @"
No asset extractor found. Download one (once) and pass -Extractor, or put it on PATH / in .\tools:
  * AssetStudioModCLI : https://github.com/aelurum/AssetStudio
  * AssetRipper       : https://github.com/AssetRipper/AssetRipper
"@
  }
  New-Item -ItemType Directory -Force -Path $rawDir | Out-Null

  # --- NOT DONE YET -------------------------------------------------------
  # The exact CLI invocation and the set of texture-bearing bundles has NOT
  # been validated against a live install. The line below is the intended
  # AssetStudioModCLI form (dump all Texture2D as PNG). VERIFY the flags for
  # your extractor version before trusting output, and narrow $bundleRoot to
  # the bundles you actually want to replace (dumping everything is large/slow).
  #
  #   AssetStudioModCLI <input> -t tex2d -o <out> -m export   (aelurum fork)
  #
  # AssetRipper uses a different CLI/GUI export flow entirely.
  # ------------------------------------------------------------------------
  Info "Extracting Texture2D -> PNG via: $ex"
  Warn "extract stage is NOT-DONE-YET: CLI flags unvalidated against a real install; verify before trusting output."
  & $ex $bundleRoot "-t" "tex2d" "-o" $rawDir "-m" "export"
  if ($LASTEXITCODE -ne 0) { Die "Extractor exited $LASTEXITCODE." }

  $n = (Get-ChildItem -Path $rawDir -Recurse -Filter *.png -ErrorAction SilentlyContinue | Measure-Object).Count
  Info "Extracted $n PNG(s) to $rawDir"
  if ($n -eq 0) { Warn "No PNGs extracted -- check extractor flags / bundle path." }
}

# ===========================================================================
# STAGE: upscale  (fully implemented; needs the Real-ESRGAN exe present)
# ===========================================================================
function Invoke-Upscale {
  if (-not (Test-Path $rawDir)) {
    Die "No extracted textures at $rawDir. Run -Stage extract first."
  }
  $up = Resolve-Tool $Upscaler "realesrgan-ncnn-vulkan.exe"
  if ($up -eq "") {
    Die @"
Real-ESRGAN not found. Download the portable build (a single .exe + models/) once:
  https://github.com/xinntao/Real-ESRGAN/releases   (asset: realesrgan-ncnn-vulkan-*-windows.zip)
Then pass -Upscaler "<path>\realesrgan-ncnn-vulkan.exe", or put it on PATH / in .\tools.
"@
  }
  Info "Upscaler: $up  (model $Model, x$Scale)"
  New-Item -ItemType Directory -Force -Path $upDir | Out-Null

  $pngs = Get-ChildItem -Path $rawDir -Recurse -Filter *.png
  $done = 0; $skip = 0; $fail = 0
  foreach ($f in $pngs) {
    # Preserve the source's relative sub-path under assets/.
    $rel = $f.FullName.Substring($rawDir.Length).TrimStart('\','/')
    $out = Join-Path $upDir $rel
    if ((Test-Path $out) -and ((Get-Item $out).Length -gt 0)) { $skip++; continue }   # idempotent/resumable
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $out) | Out-Null
    & $up "-i" $f.FullName "-o" $out "-s" $Scale "-n" $Model
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) {
      Warn "upscale failed: $($f.Name) (exit $LASTEXITCODE)"; $fail++; continue
    }
    $done++
  }
  Info "Upscaled: $done new, $skip skipped, $fail failed (of $($pngs.Count))"
  if ($fail -gt 0) { Warn "$fail file(s) failed; re-run -Stage upscale to retry (it resumes)." }
}

# ===========================================================================
# STAGE: manifest  (fully implemented; no external dependency)
# ===========================================================================
function Invoke-Manifest {
  if (-not (Test-Path $upDir)) {
    Die "No upscaled assets at $upDir. Run -Stage upscale first."
  }
  $tpl = Get-Content -Raw -Path $template | ConvertFrom-Json

  $textures = New-Object System.Collections.ArrayList
  Get-ChildItem -Path $upDir -Recurse -Filter *.png | ForEach-Object {
    $rel  = "assets/" + ($_.FullName.Substring($upDir.Length).TrimStart('\','/') -replace '\\','/')
    $name = [System.IO.Path]::GetFileNameWithoutExtension($_.Name).ToLower()
    # Infer the map channel from BSG's suffix convention.
    $map = switch -Regex ($name) {
      '_n$'        { 'normal' }
      '_(g|r)$'    { 'roughness' }
      '_ao$'       { 'ao' }
      '_h$'        { 'height' }
      '_m$'        { 'metalness' }
      default      { 'albedo' }
    }
    [void]$textures.Add([ordered]@{
      name = $name; file = $rel; map = $map; cat = "Vanilla"; tier = "4K"; conf = 1.0
    })
  }

  # Emit final aowlspt.resourcepack v1 shape: textures[] rows, capabilities array.
  $tpl.textures = $textures
  $tpl.PSObject.Properties.Remove('_note') 2>$null
  # Serialise with generous depth; PS 5.1 ConvertTo-Json needs -Depth.
  ($tpl | ConvertTo-Json -Depth 8) | Out-File -Encoding utf8 $manifest
  Info "Wrote $manifest with $($textures.Count) textures"
}

# ---------------------------------------------------------------------------
switch ($Stage) {
  "extract"  { Invoke-Extract }
  "upscale"  { Invoke-Upscale }
  "manifest" { Invoke-Manifest }
  "all"      { Invoke-Extract; Invoke-Upscale; Invoke-Manifest }
}
Info "done (stage: $Stage)"
