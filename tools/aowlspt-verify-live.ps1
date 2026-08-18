<#
.SYNOPSIS
  Prove the aowlspt server host works inside a real SPT server.

.DESCRIPTION
  aowlspt-sim exercises the ABI, but it cannot prove the SPT-side integration:
  that SPT's mod loader accepts the host, that the DI container hands over the
  database tables, that a native route survives SPT's HTTP pipeline. Only a real
  server shows that.

  Running against your actual install would mean writing into it, so this builds
  a throwaway copy instead:

    * every assembly and config from <SptRoot>\SPT_Runtime  (about 50 MB)
    * a copy of SPT_Data                                    (about 800 MB)
    * a fresh, empty user\ directory

  user\ in a real install is mostly profiles and backups — several gigabytes we
  neither need nor should touch. The sandbox listens on its own port so it can
  coexist with a server already running, and is deleted afterwards unless -Keep.

  Your SPT installation is only ever READ.

.EXAMPLE
  powershell tools/aowlspt-verify-live.ps1 -SptRoot D:\SPT
  powershell tools/aowlspt-verify-live.ps1 -SptRoot D:\SPT -Port 6971 -Keep
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $SptRoot,

    [int] $Port = 6970,
    [string] $SandboxRoot = (Join-Path $env:TEMP 'aowlspt-live'),
    [switch] $Keep,
    [switch] $Reuse
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = @()

function Fail([string] $m) { Write-Host "aowlspt-verify-live: $m" -ForegroundColor Red; exit 1 }
function Step([string] $m) { Write-Host "" ; Write-Host "=== $m ===" -ForegroundColor Cyan }

$runtime = Join-Path $SptRoot 'SPT_Runtime'
if (-not (Test-Path -LiteralPath $runtime)) {
    # A standalone server directory is a valid target too.
    if (Test-Path -LiteralPath (Join-Path $SptRoot 'SPT.Server.exe')) { $runtime = $SptRoot }
    else { Fail "no SPT_Runtime or SPT.Server.exe under $SptRoot" }
}

# --------------------------------------------------------------- sandbox

if ($Reuse -and (Test-Path -LiteralPath (Join-Path $SandboxRoot 'SPT.Server.exe'))) {
    Step "Reusing sandbox at $SandboxRoot"
} else {
    Step "Building sandbox at $SandboxRoot"
    if (Test-Path -LiteralPath $SandboxRoot) { Remove-Item -Recurse -Force $SandboxRoot }
    New-Item -ItemType Directory -Force -Path $SandboxRoot | Out-Null

    Get-ChildItem -LiteralPath $runtime -File |
        Where-Object { $_.Extension -in '.dll', '.exe', '.json', '.xml' } |
        Copy-Item -Destination $SandboxRoot -Force

    $data = Join-Path $runtime 'SPT_Data'
    if (-not (Test-Path -LiteralPath $data)) { Fail "no SPT_Data under $runtime" }
    Write-Host '  copying SPT_Data (this is the slow part)' -ForegroundColor DarkGray
    Copy-Item -LiteralPath $data -Destination (Join-Path $SandboxRoot 'SPT_Data') -Recurse -Force

    New-Item -ItemType Directory -Force -Path (Join-Path $SandboxRoot 'user\mods') | Out-Null
}

# A distinct port lets this run alongside a server that is already up.
$httpConfig = Join-Path $SandboxRoot 'SPT_Data\configs\http.json'
if (Test-Path -LiteralPath $httpConfig) {
    $cfg = Get-Content -Raw -LiteralPath $httpConfig | ConvertFrom-Json
    $cfg.port = $Port
    $cfg.backendPort = $Port
    $cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $httpConfig -Encoding utf8
    Write-Host "  sandbox will listen on $Port" -ForegroundColor DarkGray
}

# ----------------------------------------------------------------- build

Step 'Building hosts, tools and example mods'
foreach ($proj in @('host\Aowlspt.Host.Server', 'host\Aowlspt.Sim', 'tools\SptProbe')) {
    & dotnet build (Join-Path $repoRoot $proj) -c Release -v q --nologo | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "$proj failed to build" }
}
foreach ($mod in @('examples\hello', 'examples\backend')) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $repoRoot 'tools\aowlspt-build.ps1') -Mod (Join-Path $repoRoot $mod) | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "$mod failed to build" }
}

Step 'Installing into the sandbox'
& powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $repoRoot 'tools\aowlspt-deploy.ps1') -SptRoot $SandboxRoot -Server -Confirm | Out-Null
if ($LASTEXITCODE -ne 0) { Fail 'deploy failed' }

# ------------------------------------------------------------------- run

Step 'Starting the SPT server'
$log = Join-Path $SandboxRoot 'verify.log'
Remove-Item $log -ErrorAction SilentlyContinue
$proc = Start-Process -FilePath (Join-Path $SandboxRoot 'SPT.Server.exe') -WorkingDirectory $SandboxRoot `
        -RedirectStandardOutput $log -RedirectStandardError (Join-Path $SandboxRoot 'verify.err') -PassThru

try {
    $ready = $false
    for ($i = 0; $i -lt 240; $i++) {
        Start-Sleep -Milliseconds 500
        if ((Test-Path $log) -and (Select-String -Path $log -Pattern 'Started webserver' -Quiet)) { $ready = $true; break }
        if ($proc.HasExited) { break }
    }
    if (-not $ready) {
        Get-Content $log -Tail 25 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        Fail 'the server never reported listening'
    }
    Write-Host '  listening' -ForegroundColor Green

    Step 'Checking the host loaded the native mods'
    $patterns = @(
        'aowlspt host version',
        'native mod',
        'loaded Hello',
        'loaded Backend Example'
    )
    foreach ($pattern in $patterns) {
        if (Select-String -Path $log -Pattern $pattern -Quiet) {
            Write-Host "  ok    $pattern" -ForegroundColor Green
        } else {
            Write-Host "  FAIL  $pattern" -ForegroundColor Red
            $failures += $pattern
        }
    }

    Step 'Calling the native mod routes over HTTP'
    $probe = Join-Path $repoRoot 'tools\SptProbe\bin\Release\net10.0\sptprobe.dll'

    # Written to a file because Windows PowerShell strips double quotes from the
    # arguments it passes to a native executable, which would corrupt the JSON.
    $bodyFile = Join-Path $SandboxRoot 'probe-body.json'
    Set-Content -LiteralPath $bodyFile -Encoding ascii -NoNewline -Value '{"probe":true,"n":42}'

    $checks = @(
        @{ Url = "https://127.0.0.1:$Port/aowlspt/hello";          Expect = 'nimony' },
        @{ Url = "https://127.0.0.1:$Port/aowlspt/hello";          Expect = 'echo' },
        @{ Url = "https://127.0.0.1:$Port/aowlspt/backend/status"; Expect = 'itemsPatched' },
        @{ Url = "https://127.0.0.1:$Port/aowlspt/backend/nope";   Expect = 'unknown endpoint' }
    )
    # sptprobe writes the body to stdout and its status line to stderr. Do NOT
    # redirect that stderr: under $ErrorActionPreference = 'Stop', Windows
    # PowerShell wraps a native command's stderr in an ErrorRecord and treats it
    # as terminating, so a perfectly successful probe aborts the script.
    $probeEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    foreach ($c in $checks) {
        $out = (& dotnet $probe $c.Url --body-file $bodyFile --session '000000000000000000000001' --quiet) -join "`n"
        if ($out -like ('*' + $c.Expect + '*')) {
            Write-Host "  ok    $($c.Url) -> $($c.Expect)" -ForegroundColor Green
        } else {
            Write-Host "  FAIL  $($c.Url) expected '$($c.Expect)'" -ForegroundColor Red
            Write-Host "        got: $out" -ForegroundColor DarkGray
            $failures += $c.Url
        }
    }
    $ErrorActionPreference = $probeEap

    Step 'Checking the live database was read and patched'
    # "dbPatch returned Ok" only says the call succeeded. The mod reads the value
    # back afterwards, so this line is what proves the object graph changed.
    $weight = Select-String -Path $log -Pattern 'weight [\d.]+ -> [\d.]+'
    if ($weight) {
        Write-Host "  ok    $($weight.Matches[0].Value)" -ForegroundColor Green
    } else {
        Write-Host '  FAIL  no weight change logged' -ForegroundColor Red
        $failures += 'db patch'
    }
}
finally {
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
    if (-not $Keep) {
        Write-Host ''
        Write-Host "cleaning up $SandboxRoot" -ForegroundColor DarkGray
        Remove-Item -Recurse -Force $SandboxRoot -ErrorAction SilentlyContinue
    } else {
        Write-Host ''
        Write-Host "sandbox kept at $SandboxRoot" -ForegroundColor DarkGray
    }
}

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host 'live verification passed' -ForegroundColor Green
    exit 0
}
Write-Host "live verification FAILED: $($failures -join ', ')" -ForegroundColor Red
exit 1
