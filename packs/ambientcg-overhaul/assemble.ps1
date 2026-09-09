<#
  assemble.ps1 -- one command to materialise the ambientCG Overhaul pack.

  Copies the ~2.2 GB of CC0 ambientCG images referenced by manifest.json out of
  your local TarkovTextures source tree into .\assets, producing the complete,
  self-contained resource pack. Idempotent and resumable.

  Usage:
    .\assemble.ps1                       # auto-detect source (sibling TarkovTextures
                                         #   or mods/textures config.json packRoot)
    .\assemble.ps1 -Src D:\TarkovTextures
#>
param(
  [string]$Src = "",
  [switch]$RegenManifest
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$py = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $py) { $py = (Get-Command python3 -ErrorAction SilentlyContinue) }
if (-not $py) { throw "Python 3 not found on PATH. Install Python 3 and retry." }

$pyArgs = @(Join-Path $here "assemble_pack.py")
if ($RegenManifest) { $pyArgs += "--regen-manifest" }
if ($Src -ne "")    { $pyArgs += @("--src", $Src) }

& $py.Source @pyArgs
exit $LASTEXITCODE
