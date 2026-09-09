# tools/inspect.ps1 -- drive the LIVE INSPECTOR from a shell while the game runs.
#
# The whole point of the inspector is that a question about the live client
# costs SECONDS instead of a rebuild-deploy-relaunch cycle. This script is the
# other half of that: it writes a command batch into the file the running host
# polls, waits for the answer file to be rewritten, and prints it. No restart,
# no rebuild, and the player never leaves the menu.
#
#   .\tools\inspect.ps1 -Deploy D:\Aowlspt\aowlspt "anchors"
#   .\tools\inspect.ps1 "read `$verlabel+0xe0 str" "canvas `$verlabel"
#   Get-Content .\probe.txt | .\tools\inspect.ps1
#
# A SERIAL LINE is prepended to every batch. The host re-runs the file whenever
# its CONTENT changes, so sending the same commands twice needs something in the
# file to differ -- that is what the serial is for, and why re-running is not
# something you have to think about.

[CmdletBinding()]
param(
    # Where the host DLL lives -- the same directory the host reads its
    # aowlspt-host.json from. Defaults to the deploy path the project uses.
    [string] $Deploy = 'D:\Aowlspt\aowlspt',
    # Seconds to wait for the answer. A batch runs on the next PreloaderUI
    # frame, so this is normally well under a second; the budget is generous
    # because a client sitting on a loading screen is not ticking that method.
    [int] $TimeoutSec = 20,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Commands
)

$ErrorActionPreference = 'Stop'

$cmdPath = Join-Path $Deploy 'aowlspt-inspect.txt'
$outPath = Join-Path $Deploy 'aowlspt-inspect-out.txt'

if (-not (Test-Path $Deploy)) {
    Write-Error "no such directory: $Deploy (pass -Deploy <dir beside the host DLL>)"
}

# Commands from the argument list, or from the pipeline when there are none --
# so a saved probe script is `Get-Content probe.txt | .\tools\inspect.ps1`.
$lines = @()
if ($Commands -and $Commands.Count -gt 0) {
    $lines = $Commands
} else {
    $lines = @($input)
}
if (-not $lines -or $lines.Count -eq 0) {
    Write-Error 'nothing to send: pass commands as arguments or on stdin'
}

# Remember what the answer file looked like, so we wait for a genuinely new one
# rather than reading the previous batch's answer back.
$before = ''
if (Test-Path $outPath) { $before = Get-Content -Raw -Path $outPath }

$serial = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$body = "# serial $serial`n" + ($lines -join "`n") + "`n"
Set-Content -Path $cmdPath -Value $body -Encoding utf8

Write-Host "sent $($lines.Count) command(s) to $cmdPath (serial $serial)" -ForegroundColor DarkGray

$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 200
    if (-not (Test-Path $outPath)) { continue }
    $now = Get-Content -Raw -Path $outPath
    if ($now -and $now -ne $before) {
        Write-Output $now
        exit 0
    }
}

Write-Warning @"
no answer within $TimeoutSec s. Check, in order:
  * is the game running with this host injected?
  * is `liveInspector: true` in $Deploy\aowlspt-host.json?
  * does the host log say 'live inspector armed'? If it says it did not arm,
    PreloaderUI::Update is neither claimed by another feature nor verifiable.
  * is the client past the preloader? The batch runs on that method's next
    frame, and a client still on a loading screen is not calling it.
"@
exit 1
