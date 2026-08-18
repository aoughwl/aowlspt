# Builds and runs everything the overlay owns.
#
# This is a standalone script rather than a case in `tools/aowl.nim` because
# `aowl.nim` belongs to another part of the tree; the change needed there is
# described in README.md. Everything below is what that change would run.
#
#   .\build.ps1              build + run the headless test, no backend
#   .\build.ps1 -Backend     also start tests/overlayhost/fakebackend.py and
#                            exercise the HTTP client against it
#   .\build.ps1 -Interactive build and run the test host in a visible window;
#                            INSERT toggles the panel, ESC closes it
#   .\build.ps1 -Regen       regenerate the baked font and shader tables
#
param(
    [switch]$Backend,
    [switch]$Interactive,
    [switch]$Regen
)

# 'Continue', not 'Stop': Windows PowerShell 5.1 wraps a native program's
# stderr in an ErrorRecord, so gcc printing a single warning would abort the
# script under 'Stop' even though the compile succeeded. Every native call
# below checks $LASTEXITCODE instead, which is the thing that actually says
# whether it worked.
$ErrorActionPreference = 'Continue'
$repo  = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$abi   = Join-Path $repo 'abi'
$tests = Join-Path $repo 'tests\overlayhost'
$env:PATH = "C:\msys64\ucrt64\bin;$env:USERPROFILE\nimony\bin;$env:PATH"

function Step($msg) { Write-Host "==>  $msg" -ForegroundColor Cyan }

if ($Regen) {
    # The tables in abi/aowlspt_overlay.h come from these two. Regenerating is
    # a manual step on purpose: the output is checked in, so a build on a
    # machine with a different Consolas does not silently change the font.
    Step 'regenerating the baked font and shaders'
    Push-Location $tests
    gcc -O2 fontgen.c -o fontgen.exe -lgdi32
    ./fontgen.exe > font.inc
    gcc -O2 shadergen.c -o shadergen.exe -ld3dcompiler
    ./shadergen.exe > shaders.inc
    Pop-Location
    Write-Host 'font.inc and shaders.inc rewritten; paste them into abi/aowlspt_overlay.h'
}

Step 'building the D3D11 test host'
Push-Location $tests
gcc -O1 -g -Wno-unused-function -I"$abi" overlayhost.c -o overlayhost.exe -ld3d11 -ldxgi -luser32
if ($LASTEXITCODE -ne 0) { Pop-Location; throw 'overlayhost failed to build' }
Pop-Location

Step 'checking the header still needs no extra link library'
Push-Location $tests
gcc -O1 -Wno-unused-function -I"$abi" linkprobe.c -o linkprobe.exe
if ($LASTEXITCODE -ne 0) {
    Pop-Location
    throw 'linkprobe failed: the header has grown an import that the injected host cannot afford'
}
Pop-Location

Step 'building the nimony boundary test'
Push-Location $tests
nimony c --passC:-I"$abi" -p:"$PSScriptRoot" -o:overlaynimtest.exe overlaynimtest.nim
if ($LASTEXITCODE -ne 0) { Pop-Location; throw 'overlaynimtest failed to build' }
Pop-Location

if ($Interactive) {
    Step 'running the test host in a window (INSERT toggles the panel)'
    & (Join-Path $tests 'overlayhost.exe')
    return
}

$shots = Join-Path $tests 'shots'
New-Item -ItemType Directory -Force -Path $shots | Out-Null

$server = $null
$port = 0
if ($Backend) {
    Step 'starting the stand-in backend on 7261'
    $server = Start-Process python -ArgumentList (Join-Path $tests 'fakebackend.py'), '7261' -PassThru
    Start-Sleep -Milliseconds 600
    $port = 7261
}

try {
    Step 'running the headless overlay test'
    $args = @('--headless', '--shot', $shots)
    if ($port -gt 0) { $args += @('--port', "$port") }
    & (Join-Path $tests 'overlayhost.exe') @args
    $hostRc = $LASTEXITCODE

    Step 'running the nimony boundary test'
    & (Join-Path $tests 'overlaynimtest.exe')
    $nimRc = $LASTEXITCODE

    if ($Backend) {
        $posts = (Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$port/posts").Content
        if ($posts -match 'enabled') {
            Write-Host "ok    the click reached the backend: $posts"
        } else {
            Write-Host 'error the click never reached the backend'
            $hostRc = 1
        }
    }
} finally {
    if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host "screenshots in $shots"
if ($hostRc -ne 0 -or $nimRc -ne 0) { exit 1 }
