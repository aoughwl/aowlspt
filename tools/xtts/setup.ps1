# tools/xtts/setup.ps1 -- install Coqui XTTS-v2 (the maintained `coqui-tts` fork)
# on CUDA for aowl.basement: the OFFLINE realistic fallback with voice cloning
# and true chunked streaming.
#
# Everything lands OUTSIDE the repo, under $Root (default
# %LOCALAPPDATA%\aowlspt\xtts, override with -Root or AOWLSPT_XTTS_ROOT):
#
#   <Root>\venv\        Python 3.12 venv: torch 2.6.0+cu124, torchaudio, coqui-tts 0.27.5,
#                       transformers 4.57 (coqui-tts 0.27.5 needs >=4.54,<5 -- MEASURED:
#                       5.x lacks isin_mps_friendly, <4.54 lacks is_torchcodec_available)
#   <Root>\tts\         TTS_HOME: tts_models--multilingual--multi-dataset--xtts_v2 (1.8 GB)
#   <Root>\server.py    a copy of tools/xtts/server.py
#
# LICENCE: the XTTS-v2 weights are CPML (Coqui Public Model License), NON-COMMERCIAL.
# Setting COQUI_TOS_AGREED=1 (done below) is accepting that.
#
#   powershell -ExecutionPolicy Bypass -File tools\xtts\setup.ps1 [-Root DIR] [-Bench] [-VoicesDir DIR] [-Port 6976]
param(
    [string]$Root = "",
    [string]$VoicesDir = "",
    [switch]$Bench,
    [int]$Port = 6976
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($Root -eq "") { $Root = $env:AOWLSPT_XTTS_ROOT }
if (-not $Root) { $Root = Join-Path $env:LOCALAPPDATA "aowlspt\xtts" }
if ($VoicesDir -eq "") { $VoicesDir = Join-Path $here "..\..\mods\basement\data\voices" }
New-Item -ItemType Directory -Force -Path $Root | Out-Null
Write-Host "xtts root: $Root"

$venv = Join-Path $Root "venv"
$py = Join-Path $venv "Scripts\python.exe"
$env:TTS_HOME = $Root
$env:COQUI_TOS_AGREED = "1"

function Find-Uv {
    $c = Get-Command uv -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:USERPROFILE ".local\bin\uv.exe"
    if (Test-Path $p) { return $p }
    return $null
}

function Test-Xtts {
    if (-not (Test-Path $py)) { return $false }
    & $py -c "import torch, TTS; assert torch.cuda.is_available(), 'no cuda'; from TTS.tts.models.xtts import Xtts; print('torch', torch.__version__, 'TTS', TTS.__version__, torch.cuda.get_device_name(0))" 2>$null
    return ($LASTEXITCODE -eq 0)
}

if (Test-Xtts) {
    Write-Host "present  venv imports TTS (xtts) on CUDA: $py"
} else {
    $uv = Find-Uv
    if (-not $uv) { throw "uv not found (PATH or ~/.local/bin). Install it: https://astral.sh/uv" }
    Write-Host "venv     via uv (python 3.12): $venv"
    & $uv venv --python 3.12 --seed $venv
    if ($LASTEXITCODE -ne 0) { throw "uv venv failed (exit $LASTEXITCODE)" }
    & $uv pip install --python $py --index-url https://download.pytorch.org/whl/cu124 "torch==2.6.0" "torchaudio==2.6.0"
    if ($LASTEXITCODE -ne 0) { throw "uv pip install torch (cu124) failed (exit $LASTEXITCODE)" }
    & $uv pip install --python $py "coqui-tts==0.27.5" "transformers>=4.54,<5"
    if ($LASTEXITCODE -ne 0) { throw "uv pip install coqui-tts failed (exit $LASTEXITCODE)" }
    if (-not (Test-Xtts)) { throw "venv exists but TTS on CUDA does not import: $py" }
    Write-Host "ok       venv imports TTS on CUDA"
}

Copy-Item -Force (Join-Path $here "server.py") (Join-Path $Root "server.py")
Write-Host "ok       server.py copied to $Root"

Write-Host "weights  loading once (downloads 1.8 GB into $env:TTS_HOME\tts on the first run; CPML non-commercial)"
& $py -c "import time; t=time.time(); from TTS.api import TTS; m=TTS('tts_models/multilingual/multi-dataset/xtts_v2').to('cuda'); print('loaded in %.0f s' % (time.time()-t))"
if ($LASTEXITCODE -ne 0) { throw "TTS(xtts_v2) failed" }
$snap = Get-ChildItem -Recurse -File (Join-Path $Root "tts") -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "\.(pth|json|safetensors)$" }
foreach ($f in $snap) { Write-Host ("weights  {0,14:N0}  {1}" -f $f.Length, $f.Name) }

Write-Host ""
Write-Host "SETUP OK"
Write-Host "  start:  `"$py`" `"$Root\server.py`" --voices-dir `"$VoicesDir`" --port $Port"
Write-Host "  health: curl.exe -s http://127.0.0.1:$Port/health"
if ($Bench) {
    & $py (Join-Path $Root "server.py") --voices-dir $VoicesDir --bench "The basement door is locked, and nobody here is going to open it." --n 4
}
