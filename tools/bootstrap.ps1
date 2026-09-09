# bootstrap.ps1 -- make a bare git worktree buildable, from NOTHING.
#
# Why this file exists, measured: `installer/build/` is gitignored, so a fresh
# `git worktree add` has no `aowl.exe`, and `aowl bootstrap` is a subcommand OF
# `aowl.exe`. Three agents in one night hit that and each reached for the same
# workaround -- copy `aowl.exe` in from another checkout -- which is exactly the
# hazard CLAUDE.md 3 warns about: the copy runs THAT checkout's `tools/aowl.nim`,
# so a build step added on your branch goes silently unexercised.
#
# There is no real chicken-and-egg. `tools/aowl.nim` is a NIMONY program, and
# nimony compiles it directly with no driver present. That is all this script
# does -- the same command line `cmdBootstrap` uses, run from PowerShell.
#
# It does NOT touch D:\Aowlspt, does not deploy, and does not start the game.

[CmdletBinding()]
param(
  [string] $Nimony = (Join-Path $env:USERPROFILE 'nimony'),
  [string] $Ucrt64 = 'C:\msys64\ucrt64\bin',
  # Where to copy .cache\global-metadata.dec.dat from, if this worktree has none.
  [string] $Metadata = ''
)

$ErrorActionPreference = 'Stop'

function Say  ($m) { Write-Host "    $m" }
function Ok   ($m) { Write-Host "ok  $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "!!  $m" -ForegroundColor Yellow }
function Die  ($m) { Write-Host "ERR $m" -ForegroundColor Red; exit 1 }

# --- repo root: the directory holding abi\aowlspt_abi.h, same rule as repoRoot()
$repo = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $repo 'abi\aowlspt_abi.h'))) {
  Die "not an aowlspt checkout: no abi\aowlspt_abi.h under $repo"
}
Say "repo    $repo"
Say "nimony  $Nimony"

$nimonyExe = Join-Path $Nimony 'bin\nimony.exe'
if (-not (Test-Path $nimonyExe)) { Die "nimony not found at $nimonyExe (pass -Nimony PATH)" }

# --- 1. the output directory nobody has in a fresh worktree
$outDir = Join-Path $repo 'installer\build'
if (-not (Test-Path $outDir)) {
  New-Item -ItemType Directory -Path $outDir | Out-Null
  Ok "created installer\build"
} else {
  Ok "installer\build exists"
}

# --- 2. the metadata cache, which is gitignored and NOT shared between worktrees
#
# Without it `aowl build host` cannot check abi\aowlspt_symtab.h for staleness
# and emits no name->RVA index. That used to be one polite line mid-build; the
# driver now refuses when the cache is missing but GameAssembly.dll is present,
# because in that state the only thing missing is this copy.
$cacheDst = Join-Path $repo '.cache\global-metadata.dec.dat'
if (Test-Path $cacheDst) {
  Ok "metadata cache present"
} else {
  $candidates = @()
  if ($Metadata)          { $candidates += $Metadata }
  if ($env:AOWLSPT_METADATA) { $candidates += $env:AOWLSPT_METADATA }
  $cur = Split-Path -Parent $repo
  for ($i = 0; $i -lt 4 -and $cur; $i++) {
    $candidates += (Join-Path $cur 'aowlspt\.cache\global-metadata.dec.dat')
    $up = Split-Path -Parent $cur
    if (-not $up -or $up -eq $cur) { break }
    $cur = $up
  }
  $seeded = $false
  foreach ($c in $candidates) {
    if ($c -eq $cacheDst) { continue }
    if (-not (Test-Path $c)) { continue }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cacheDst) | Out-Null
    Copy-Item -LiteralPath $c -Destination $cacheDst
    Ok "seeded .cache\global-metadata.dec.dat from $c"
    $seeded = $true
    break
  }
  if (-not $seeded) {
    Warn "no .cache\global-metadata.dec.dat, and none found to copy"
    Say  "pass -Metadata <path>, or decrypt it with tools\metablob.py"
    Say  'until then the IL2CPP build gates cannot run, and `aowl build host` says so and refuses'
  }
}

# --- 3. build the driver from THIS worktree's source
# ucrt64 must come first: a Git-for-Windows mingw64 ahead of it gives a cc1 that
# dies with no message at all.
$env:PATH = "$Ucrt64;" + (Join-Path $Nimony 'bin') + ";$env:PATH"

$src     = Join-Path $repo 'tools\aowl.nim'
$exe     = Join-Path $outDir 'aowl.exe'
$nextExe = Join-Path $outDir 'aowl-next.exe'
$oldExe  = Join-Path $outDir 'aowl.exe.old'
if (Test-Path $nextExe) { Remove-Item -Force $nextExe }

Say "compiling tools\aowl.nim with nimony (this is a minute, not a build)"
Push-Location $repo
try {
  & $nimonyExe c "--passC:-I$(Join-Path $repo 'abi')" `
      "-p:$(Join-Path $repo 'installer\src')" `
      "-p:$(Join-Path $repo 'aowl\src')" `
      "-o:$nextExe" $src
  $rc = $LASTEXITCODE
} finally { Pop-Location }
if ($rc -ne 0)              { Die "nimony exited $rc" }
if (-not (Test-Path $nextExe)) { Die "nimony reported success but produced no aowl-next.exe" }

# The running image cannot be overwritten but can be renamed, so swap by two
# renames -- this works whether or not aowl.exe is the process doing it.
if (Test-Path $exe) {
  if (Test-Path $oldExe) { Remove-Item -Force $oldExe }
  Move-Item -LiteralPath $exe -Destination $oldExe
}
Move-Item -LiteralPath $nextExe -Destination $exe
Ok "installer\build\aowl.exe built from this worktree's tools\aowl.nim"

# --- 4. the stamp
#
# CONTENT, not mtime: djb2 over the file's bytes (BOM stripped), byte-identical
# to `textStamp` in aowl.nim. A mtime comparison would fire on every fresh
# checkout, and a warning that always fires trains people past the one that
# matters.
$bytes = [System.IO.File]::ReadAllBytes($src)
$start = 0
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
$h = 5381
for ($i = $start; $i -lt $bytes.Length; $i++) {
  $h = (($h * 33) + $bytes[$i]) -band 0x3FFFFFFF
}
[System.IO.File]::WriteAllText((Join-Path $outDir '.aowlstamp'), "$h")
Ok "stamped ($h)"

# --- 5. prove it. A bootstrap that reported success and left the old-driver
# state in place would be the exact defect class this is fixing.
# `--no-lock` because `build` now REFUSES outside tools\buildlock.py (it checks
# for AOWL_BUILDLOCK). This probe compiles nothing -- it exists to make the new
# exe answer -- so the serialisation the lock provides is irrelevant here, but
# without the flag the refusal would arrive instead of 'unknown build target'
# and bootstrap would Die claiming the driver is broken.
$probe = & $exe build __bootstrap_probe__ --no-lock 2>&1 | Out-String
if ($probe -match 'has changed since aowl\.exe was last built' -or
    $probe -match 'has NO build stamp beside it' -or
    $probe -match 'there is no installer.build.aowl\.exe') {
  Write-Host $probe
  Die "the driver still reports itself stale after bootstrap -- stamp mismatch, NOT resolved"
}
if ($probe -notmatch 'unknown build target') {
  Write-Host $probe
  Die "the new aowl.exe did not answer as expected"
}
Ok "verified: the driver is the local build and reports no staleness"
Say "next: aowl build host"
exit 0
