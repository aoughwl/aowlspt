# tools/f5tts/setup.ps1 -- install F5-TTS (SWivid) on CUDA for aowl.basement's
# `ai-companion` voice (the deliberately corny AI voice the user chose 2026-09-07).
#
# Everything lands OUTSIDE the repo, under $Root (default
# %LOCALAPPDATA%\aowlspt\f5tts, override with -Root or AOWLSPT_F5TTS_ROOT):
#
#   <Root>\venv\        Python 3.12 venv: torch 2.6.0+cu124, torchaudio, f5-tts 1.1.22
#   <Root>\hf\          HF_HOME: SWivid/F5-TTS F5TTS_v1_Base model_1250000.safetensors
#                       (1.35 GB) + charactr/vocos-mel-24khz, pulled on the first load
#   <Root>\server.py    a copy of tools/f5tts/server.py so the mod needs ONE path
#
# Needs an NVIDIA driver that runs CUDA 12.4 (this machine: RTX 2060 SUPER 8 GB,
# driver 581.42). `uv` on PATH (or ~/.local/bin/uv) makes the venv; the MSYS
# python on PATH has no pip and cannot host this.
#
#   powershell -ExecutionPolicy Bypass -File tools\f5tts\setup.ps1 [-Root DIR] [-Bench] [-VoicesDir DIR] [-Port 6977]
param(
    [string]$Root = "",
    [string]$VoicesDir = "",
    [switch]$Bench,
    [int]$Port = 6977
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($Root -eq "") { $Root = $env:AOWLSPT_F5TTS_ROOT }
if (-not $Root) { $Root = Join-Path $env:LOCALAPPDATA "aowlspt\f5tts" }
if ($VoicesDir -eq "") { $VoicesDir = Join-Path $here "..\..\mods\basement\data\voices" }
New-Item -ItemType Directory -Force -Path $Root | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Root "hf") | Out-Null
Write-Host "f5tts root: $Root"

$venv = Join-Path $Root "venv"
$py = Join-Path $venv "Scripts\python.exe"
$env:HF_HOME = Join-Path $Root "hf"

function Find-Uv {
    $c = Get-Command uv -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:USERPROFILE ".local\bin\uv.exe"
    if (Test-Path $p) { return $p }
    return $null
}

function Test-F5 {
    if (-not (Test-Path $py)) { return $false }
    & $py -c "import torch, f5_tts.api; assert torch.cuda.is_available(), 'no cuda'; print('torch', torch.__version__, 'cuda', torch.version.cuda, torch.cuda.get_device_name(0))" 2>$null
    return ($LASTEXITCODE -eq 0)
}

if (Test-F5) {
    Write-Host "present  venv imports f5_tts on CUDA: $py"
} else {
    $uv = Find-Uv
    if (-not $uv) { throw "uv not found (PATH or ~/.local/bin). Install it: https://astral.sh/uv" }
    Write-Host "venv     via uv (python 3.12): $venv"
    & $uv venv --python 3.12 --seed $venv
    if ($LASTEXITCODE -ne 0) { throw "uv venv failed (exit $LASTEXITCODE)" }
    # torch FIRST from the cu124 index so the PyPI resolve afterwards finds it satisfied
    # and does not swap in the CPU wheel.
    & $uv pip install --python $py --index-url https://download.pytorch.org/whl/cu124 "torch==2.6.0" "torchaudio==2.6.0"
    if ($LASTEXITCODE -ne 0) { throw "uv pip install torch (cu124) failed (exit $LASTEXITCODE)" }
    & $uv pip install --python $py "f5-tts==1.1.22"
    if ($LASTEXITCODE -ne 0) { throw "uv pip install f5-tts failed (exit $LASTEXITCODE)" }
    if (-not (Test-F5)) { throw "venv exists but f5_tts on CUDA does not import: $py" }
    Write-Host "ok       venv imports f5_tts on CUDA"
}

Copy-Item -Force (Join-Path $here "server.py") (Join-Path $Root "server.py")
Write-Host "ok       server.py copied to $Root"

# Every voice needs a transcript beside it (F5 conditions on the reference's text;
# without one the library would download a 1.6 GB Whisper on first use).
$missing = Get-ChildItem (Join-Path $VoicesDir "*.wav") | Where-Object { -not (Test-Path ($_.FullName -replace "\.wav$", ".txt")) }
foreach ($m in $missing) { Write-Host "WARN     no transcript for $($m.Name) -- write $($m.BaseName).txt or the server refuses that voice" }

Write-Host "weights  loading once (downloads ~1.4 GB into $env:HF_HOME on the first run)"
& $py -c "import os,time; t=time.time(); from f5_tts.api import F5TTS; m=F5TTS(model='F5TTS_v1_Base', device='cuda', hf_cache_dir=os.environ['HF_HOME']); print('loaded in %.0f s, sr=%d' % (time.time()-t, m.target_sample_rate))"
if ($LASTEXITCODE -ne 0) { throw "F5TTS(...) failed" }
$snap = Get-ChildItem -Recurse -File (Join-Path $env:HF_HOME "hub") -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "\.(safetensors|pt|bin)$" }
foreach ($f in $snap) { Write-Host ("weights  {0,14:N0}  {1}" -f $f.Length, $f.Name) }

Write-Host ""
Write-Host "SETUP OK"
Write-Host "  start:  `"$py`" `"$Root\server.py`" --voices-dir `"$VoicesDir`" --port $Port"
Write-Host "  health: curl.exe -s http://127.0.0.1:$Port/health"
if ($Bench) {
    & $py (Join-Path $Root "server.py") --voices-dir $VoicesDir --bench "The basement door is locked, and nobody here is going to open it." --n 4
}
