# Builds and runs everything the overlay owns.
#
# This is a standalone script rather than a case in `tools/aowl.nim` because
# `aowl.nim` belongs to another part of the tree; the change needed there is
# described in README.md. Everything below is what that change would run.
#
#   .\build.ps1              build + run the headless test, no backend
#   .\build.ps1 -Backend     also start tests/overlayhost/fakebackend.py and
#                            exercise the HTTP client against it. Serves the
#                            capture in tests/overlayhost/panel.golden.json,
#                            which is bytes the real manager produced.
#   .\build.ps1 -Real        first drive the *real* backend with the *real*
#                            mods/manager and re-take that capture, so the run
#                            checks today's manager and not last week's
#   .\build.ps1 -Control x   absent (default) | present | stubborn -- which of
#                            the manager's three control states the stand-in
#                            answers in. See fakebackend.py.
#   .\build.ps1 -Interactive build and run the test host in a visible window;
#                            INSERT toggles the panel, ESC closes it
#   .\build.ps1 -Regen       regenerate the baked font and shader tables
#
param(
    [switch]$Backend,
    [switch]$Real,
    [string]$Control = 'absent',
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

# The honest test first, when asked for it: the real backend, loading the real
# manager mod, driven over the wire. It checks every field the overlay reads and
# leaves panel.golden.json behind for the stand-in to serve. It cannot serve the
# overlay directly -- aowlspt-backend deflates every response body and the
# overlay has no inflater; see README.md, "What the rest of the tree needs".
$realRc = 0
if ($Real) {
    Step 'driving the real backend with mods/manager'
    & (Join-Path $repo 'installer\build\aowl.exe') build-mod (Join-Path $repo 'mods\manager')
    python (Join-Path $tests 'realbackend.py') 7283
    $realRc = $LASTEXITCODE
    if ($realRc -ne 0) { Write-Host 'error the real backend check failed' }
}

$server = $null
$port = 0
if ($Backend) {
    Step "starting the stand-in backend on 7261 (control: $Control)"
    # --golden: serve the rows captured off the real manager rather than the
    # hand-written ones, so what the overlay parses in CI is what the manager
    # actually emits. The control mode stays a switch because it is behaviour,
    # not shape, and a capture cannot carry it.
    $fakeArgs = @((Join-Path $tests 'fakebackend.py'), '7261', '--control', $Control)
    if (Test-Path (Join-Path $tests 'panel.golden.json')) { $fakeArgs += '--golden' }
    $server = Start-Process python -ArgumentList $fakeArgs -PassThru
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
        # Three things, and each one is a different way the click can be lost:
        # the route the manager actually serves, the body it actually reads, and
        # the header without which the backend answers in zlib.
        if ($posts -match '/aowlspt/mods/toggle/' -and $posts -match 'enabled' -and
            $posts -match 'identity') {
            Write-Host "ok    the click reached the manager's toggle route: $posts"
        } else {
            Write-Host "error the click did not arrive as the manager expects it: $posts"
            $hostRc = 1
        }
    }
} finally {
    if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host "screenshots in $shots"
if ($hostRc -ne 0 -or $nimRc -ne 0 -or $realRc -ne 0) { exit 1 }
