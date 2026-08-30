<#
autoraid.ps1 -- launch the client and drop straight into an offline raid, hands-off.

This is the "auto put us into a raid on launch" wrapper (Phase 1): it starts
aowlspt-launch.exe and then runs enterraid.py, which clears the mode selector
(entergame.py), navigates the menu by name+visible+actuate, enables practice
mode, and presses through to the raid. Point a desktop shortcut at this instead
of the launcher and a double-click puts you in a raid.

Requires the live inspector write channel (liveInspector + liveInspectorWrite in
aowlspt-host.json) -- Phase 2 will bake the sequence into the host so no dev
tooling is needed. See docs / fact #248.

Usage:
    powershell -ExecutionPolicy Bypass -File tools\autoraid.ps1 [-Map Woods] [-Loop] [-Install <dir>]

  -Map     which map (default Woods)
  -Loop    keep re-entering: after each raid ends (or a long timeout) the client
           is killed and relaunched into a fresh raid. This is the UNATTENDED
           testing loop; a human who wants to actually play should NOT pass it.
  -Install the live install dir (default D:\Aowlspt\aowlspt)
#>
param(
    [string]$Map = "Woods",
    [switch]$Loop,
    [string]$Install = "D:\Aowlspt\aowlspt"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot   # tools\ -> repo root
$launch = Join-Path $Install "aowlspt-launch.exe"
$hostlog = Join-Path $Install "aowlspt-host.log"

function Stop-Game {
    Get-Process -Name EscapeFromTarkov,aowlspt-backend,aowlspt-launch -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 4
}

function Start-Game {
    Write-Host "[autoraid] launching $launch"
    Start-Process -FilePath $launch -WorkingDirectory $Install
}

function Enter-Raid {
    Write-Host "[autoraid] entering raid on $Map ..."
    & python (Join-Path $PSScriptRoot "enterraid.py") $Map
    return $LASTEXITCODE
}

do {
    Stop-Game
    Start-Game
    $code = Enter-Raid
    if ($code -eq 0) {
        Write-Host "[autoraid] IN RAID ($Map)."
    } else {
        Write-Host "[autoraid] enterraid.py exited $code (see output above)."
    }

    if ($Loop) {
        # Unattended cycle: hold in the raid, then recycle. Graceful in-raid exit
        # is not solved yet (needs the ESC-menu RVA), so the interim close is a
        # kill+relaunch at the top of the loop. Hold ~6 min per raid.
        Write-Host "[autoraid] loop mode: holding this raid ~6 min, then recycling."
        Start-Sleep -Seconds 360
    }
} while ($Loop)
