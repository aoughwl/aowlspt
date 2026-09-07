# tools/chatterbox/setup.ps1 -- install Chatterbox (Resemble AI, chatterbox-tts)
# on CUDA for aowl.basement.
#
# Everything lands OUTSIDE the repo, under $Root (default
# %LOCALAPPDATA%\aowlspt\chatterbox, override with -Root or AOWLSPT_CHATTERBOX_ROOT):
#
#   <Root>\venv\        Python 3.12 venv: torch 2.6.0+cu124 (the version
#                       chatterbox-tts 0.1.7 pins), torchaudio, chatterbox-tts
#   <Root>\server.py    a copy of tools/chatterbox/server.py so the mod needs
#                       ONE path (chatterboxRoot) to start it
#   <Root>\hf\          HF_HOME: the model weights `ChatterboxTTS.from_pretrained`
#                       downloads on first load from huggingface.co/ResembleAI/chatterbox
#                       (t3_cfg.safetensors 2,129,653,744 B, s3gen.safetensors
#                       1,056,484,620 B, ve.safetensors 5,695,784 B, conds.pt
#                       107,374 B, tokenizer.json 25,470 B -- ~3.2 GB)
#
# Needs an NVIDIA GPU with a driver that runs CUDA 12.4 (this machine: RTX 2060
# SUPER 8 GB, driver 581.42). `uv` on PATH makes this fast; without it a
# CPython 3.10-3.12 for win32 must be on PATH.
#
#   powershell -ExecutionPolicy Bypass -File tools\chatterbox\setup.ps1 [-Root DIR] [-Bench] [-VoicesDir DIR]
param(
    [string]$Root = "",
    [string]$VoicesDir = "",
    [switch]$Bench,
    [int]$Port = 6971
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($Root -eq "") { $Root = $env:AOWLSPT_CHATTERBOX_ROOT }
if (-not $Root) { $Root = Join-Path $env:LOCALAPPDATA "aowlspt\chatterbox" }
if ($VoicesDir -eq "") { $VoicesDir = Join-Path $here "..\..\mods\basement\data\voices" }
New-Item -ItemType Directory -Force -Path $Root | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Root "hf") | Out-Null
Write-Host "chatterbox root: $Root"

$venv = Join-Path $Root "venv"
$py = Join-Path $venv "Scripts\python.exe"
$env:HF_HOME = Join-Path $Root "hf"

function Test-Chatterbox {
    if (-not (Test-Path $py)) { return $false }
    & $py -c "import torch, chatterbox.tts; assert torch.cuda.is_available(), 'no cuda'; print('torch', torch.__version__, 'cuda', torch.version.cuda, torch.cuda.get_device_name(0))" 2>$null
    return ($LASTEXITCODE -eq 0)
}

if (Test-Chatterbox) {
    Write-Host "present  venv imports chatterbox on CUDA: $py"
} else {
    $uv = Get-Command uv -ErrorAction SilentlyContinue
    if ($uv) {
        Write-Host "venv     via uv (python 3.12): $venv"
        & uv venv --python 3.12 --seed $venv
        if ($LASTEXITCODE -ne 0) { throw "uv venv failed (exit $LASTEXITCODE)" }
        # torch FIRST from the cu124 index, pinned to what chatterbox-tts pins,
        # so the plain-PyPI resolve afterwards finds them satisfied and does
        # not swap in the CPU wheel.
        & uv pip install --python $py --index-url https://download.pytorch.org/whl/cu124 "torch==2.6.0" "torchaudio==2.6.0"
        if ($LASTEXITCODE -ne 0) { throw "uv pip install torch (cu124) failed (exit $LASTEXITCODE)" }
        & uv pip install --python $py "chatterbox-tts==0.1.7"
        if ($LASTEXITCODE -ne 0) { throw "uv pip install chatterbox-tts failed (exit $LASTEXITCODE)" }
    } else {
        $base_py = $null
        foreach ($n in @("python3.12", "python3.11", "python3.10", "python")) {
            $c = Get-Command $n -ErrorAction SilentlyContinue
            if (-not $c) { continue }
            $v = & $c.Source -c "import sys; print('%d.%d' % sys.version_info[:2]); print(sys.platform)" 2>$null
            if ($LASTEXITCODE -ne 0) { continue }
            if ($v[1] -ne "win32") { continue }
            if (@("3.10", "3.11", "3.12") -contains $v[0]) { $base_py = $c.Source; break }
        }
        if (-not $base_py) { throw "no CPython 3.10-3.12 for win32 on PATH and no uv. Install uv (https://astral.sh/uv) then re-run." }
        Write-Host "venv     via $base_py : $venv"
        & $base_py -m venv $venv
        & $py -m pip install --upgrade pip
        & $py -m pip install --index-url https://download.pytorch.org/whl/cu124 "torch==2.6.0" "torchaudio==2.6.0"
        if ($LASTEXITCODE -ne 0) { throw "pip install torch (cu124) failed" }
        & $py -m pip install "chatterbox-tts==0.1.7"
        if ($LASTEXITCODE -ne 0) { throw "pip install chatterbox-tts failed" }
    }
    if (-not (Test-Chatterbox)) { throw "venv exists but chatterbox on CUDA does not import: $py" }
    Write-Host "ok       venv imports chatterbox on CUDA"
}

Copy-Item -Force (Join-Path $here "server.py") (Join-Path $Root "server.py")
Write-Host "ok       server.py copied to $Root"

# The weights: fetched by from_pretrained on first load into HF_HOME. Do it
# now so the FIRST /tts is not a 3 GB download, and check the finished state.
Write-Host "weights  loading once (downloads ~3.2 GB into $env:HF_HOME on the first run)"
& $py -c "import os,time; t=time.time(); from chatterbox.tts import ChatterboxTTS; m=ChatterboxTTS.from_pretrained(device='cuda'); print('loaded in %.0f s, sr=%d' % (time.time()-t, m.sr))"
if ($LASTEXITCODE -ne 0) { throw "ChatterboxTTS.from_pretrained failed" }
$snap = Get-ChildItem -Recurse -File (Join-Path $env:HF_HOME "hub") -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "\.(safetensors|pt|json)$" }
foreach ($f in $snap) { Write-Host ("weights  {0,14:N0}  {1}" -f $f.Length, $f.Name) }

Write-Host ""
Write-Host "SETUP OK"
Write-Host "  start:  `$env:HF_HOME='$($env:HF_HOME)'; `"$py`" `"$Root\server.py`" --voices-dir `"$VoicesDir`" --port $Port"
Write-Host "  health: curl.exe -s http://127.0.0.1:$Port/health"
if ($Bench) {
    & $py (Join-Path $Root "server.py") --voices-dir $VoicesDir --bench "The basement door is locked, and nobody here is going to open it." --n 5
}
