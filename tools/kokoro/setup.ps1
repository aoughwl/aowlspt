# tools/kokoro/setup.ps1 -- install Kokoro-82M (kokoro-onnx, CPU) for aowl.basement.
#
# Everything lands OUTSIDE the repo, under $Root (default
# %LOCALAPPDATA%\aowlspt\kokoro, override with -Root or AOWLSPT_KOKORO_ROOT):
#
#   <Root>\venv\                 a Python 3.12 venv (uv-managed interpreter if
#                                uv is on PATH; else a python >=3.10 <3.14 found
#                                on PATH -- kokoro-onnx refuses 3.14)
#   <Root>\kokoro-v1.0.onnx      325,532,387 bytes
#   <Root>\voices-v1.0.bin        28,214,398 bytes
#   <Root>\server.py             a copy of tools/kokoro/server.py, so the mod
#                                needs ONE path (kokoroRoot) to start it
#
# Sources (thewh1teagle/kokoro-onnx, release tag model-files-v1.0):
#   https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx
#   https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin
#
# Every step is checked by its FINISHED STATE (the file exists at the expected
# byte size; the venv's python imports kokoro_onnx), never by its exit code,
# and the script re-runs safely: a complete step is skipped, a partial download
# is re-fetched.
#
#   powershell -ExecutionPolicy Bypass -File tools\kokoro\setup.ps1 [-Root DIR] [-Bench]
param(
    [string]$Root = "",
    [switch]$Bench,
    [int]$Port = 6971
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($Root -eq "") { $Root = $env:AOWLSPT_KOKORO_ROOT }
if (-not $Root) { $Root = Join-Path $env:LOCALAPPDATA "aowlspt\kokoro" }
New-Item -ItemType Directory -Force -Path $Root | Out-Null
Write-Host "kokoro root: $Root"

$files = @(
    @{ name = "kokoro-v1.0.onnx"; size = 325532387 },
    @{ name = "voices-v1.0.bin";  size = 28214398 }
)
$base = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/"

# ---------------------------------------------------------------- 1. models
foreach ($f in $files) {
    $dst = Join-Path $Root $f.name
    if ((Test-Path $dst) -and ((Get-Item $dst).Length -eq $f.size)) {
        Write-Host ("present  {0} ({1} bytes)" -f $f.name, $f.size)
        continue
    }
    Write-Host ("download {0} -> {1}" -f ($base + $f.name), $dst)
    $tmp = "$dst.part"
    & curl.exe -L --fail --retry 5 --retry-delay 2 -o $tmp ($base + $f.name)
    if ($LASTEXITCODE -ne 0) { throw "curl failed for $($f.name) (exit $LASTEXITCODE)" }
    $got = (Get-Item $tmp).Length
    if ($got -ne $f.size) {
        Remove-Item $tmp -Force
        throw ("{0}: got {1} bytes, expected {2} -- the release file changed or the download was cut" -f $f.name, $got, $f.size)
    }
    Move-Item -Force $tmp $dst
    Write-Host ("ok       {0} ({1} bytes)" -f $f.name, $got)
}

# ---------------------------------------------------------------- 2. venv
$venv = Join-Path $Root "venv"
$py = Join-Path $venv "Scripts\python.exe"
function Test-Kokoro {
    if (-not (Test-Path $py)) { return $false }
    & $py -c "import kokoro_onnx, numpy, onnxruntime; print('kokoro_onnx', kokoro_onnx.__version__ if hasattr(kokoro_onnx,'__version__') else '?', 'onnxruntime', onnxruntime.__version__)" 2>$null
    return ($LASTEXITCODE -eq 0)
}
if (Test-Kokoro) {
    Write-Host "present  venv imports kokoro_onnx: $py"
} else {
    $uv = Get-Command uv -ErrorAction SilentlyContinue
    if ($uv) {
        Write-Host "venv     via uv (python 3.12): $venv"
        & uv venv --python 3.12 --seed $venv
        if ($LASTEXITCODE -ne 0) { throw "uv venv failed (exit $LASTEXITCODE)" }
        & uv pip install --python $py "kokoro-onnx>=0.4.0" soundfile
        if ($LASTEXITCODE -ne 0) { throw "uv pip install failed (exit $LASTEXITCODE)" }
    } else {
        # No uv: find a CPython 3.10..3.13 on PATH. MSYS python (3.14 here)
        # cannot install onnxruntime wheels and kokoro-onnx pins <3.14.
        $cand = @()
        foreach ($n in @("python3.13", "python3.12", "python3.11", "python3.10", "python", "py")) {
            $c = Get-Command $n -ErrorAction SilentlyContinue
            if ($c) { $cand += $c.Source }
        }
        $base_py = $null
        foreach ($c in $cand) {
            $v = & $c -c "import sys; print('%d.%d' % sys.version_info[:2]); print(sys.platform)" 2>$null
            if ($LASTEXITCODE -ne 0) { continue }
            $ver = $v[0]; $plat = $v[1]
            if ($plat -ne "win32") { continue }
            if (@("3.10", "3.11", "3.12", "3.13") -contains $ver) { $base_py = $c; break }
        }
        if (-not $base_py) {
            throw "no CPython 3.10-3.13 for win32 on PATH and no uv. Install uv (https://astral.sh/uv) or python.org 3.12, then re-run."
        }
        Write-Host "venv     via $base_py : $venv"
        & $base_py -m venv $venv
        if ($LASTEXITCODE -ne 0) { throw "python -m venv failed (exit $LASTEXITCODE)" }
        & $py -m pip install --upgrade pip
        & $py -m pip install "kokoro-onnx>=0.4.0" soundfile
        if ($LASTEXITCODE -ne 0) { throw "pip install failed (exit $LASTEXITCODE)" }
    }
    if (-not (Test-Kokoro)) { throw "venv exists but `import kokoro_onnx` fails: $py" }
    Write-Host "ok       venv imports kokoro_onnx"
}

# ---------------------------------------------------------------- 3. server.py copy
Copy-Item -Force (Join-Path $here "server.py") (Join-Path $Root "server.py")
Write-Host "ok       server.py copied to $Root"

# ---------------------------------------------------------------- 4. summary
Write-Host ""
Write-Host "SETUP OK"
Write-Host "  start:  `"$py`" `"$Root\server.py`" --root `"$Root`" --port $Port"
Write-Host "  health: curl.exe -s http://127.0.0.1:$Port/health"
Write-Host "  tts:    curl.exe -s -X POST http://127.0.0.1:$Port/tts -H `"Content-Type: application/json`" -d '{\"text\":\"The basement door is locked.\",\"voice\":\"am_michael\"}' -o out.wav"
if ($Bench) {
    & $py (Join-Path $Root "server.py") --root $Root --bench "The basement door is locked, and nobody here is going to open it." --n 5
}
