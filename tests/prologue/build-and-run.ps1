# Two instruments for the shared prologue snapshot table (abi/aowlspt_prologue.h).
#
#   procount.c      -- COUNTS the distinct RVAs the host will ask the table for,
#                      by including the very same abi headers and walking the
#                      very same tables. It counts KEYS, so it needs no game.
#                      Run it whenever you add targets: the answer is the number
#                      AOWL_PRO_MAX_ROWS has to comfortably exceed.
#
#   overflowproof.c -- FORCES the table to overflow (AOWL_PRO_MAX_ROWS is
#                      redefined to 4) and asserts that the resulting refusal is
#                      distinguishable from a real byte mismatch. This is the
#                      falsifiable check for the whole fix: mutate
#                      AOWL_PRO_R_TABLE_FULL back to AOWL_PRO_R_MISMATCH in a
#                      copy of the header and it fails, which is how we know it
#                      is testing something.
#
# PowerShell only -- gcc under Git Bash exits 1 with no output.

$ErrorActionPreference = "Stop"
$repo = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$abi  = Join-Path $repo "abi"
$out  = Join-Path $PSScriptRoot "bin"
$env:PATH = "C:\msys64\ucrt64\bin;$env:PATH"
New-Item -ItemType Directory -Force $out | Out-Null

Write-Host "== procount: how many rows does this host actually need? =="
gcc -I $abi -o "$out\procount.exe" "$PSScriptRoot\procount.c" "$PSScriptRoot\nimstubs.c" -w
& "$out\procount.exe" | Select-Object -Last 4

Write-Host ""
Write-Host "== overflowproof: is a full table distinguishable from a mismatch? =="
gcc -I $abi -o "$out\overflowproof.exe" "$PSScriptRoot\overflowproof.c" -w
& "$out\overflowproof.exe"
if ($LASTEXITCODE -ne 0) { Write-Error "overflowproof FAILED"; exit 1 }
