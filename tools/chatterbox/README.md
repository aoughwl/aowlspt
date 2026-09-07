# tools/chatterbox -- Chatterbox (Resemble AI) voice-cloning TTS on CUDA

The realistic, custom-voice engine for `mods/basement`
(`ttsEngine: "chatterbox"`). A voice is a ~10 s reference wav: every
`<stem>.wav` in `mods/basement/data/voices/` (or `voicesDir` in config.json)
is a voice named `<stem>`, rescanned on every request, so "add a voice" is
"drop a wav in the folder".

**The three wavs shipped there are PLACEHOLDERS** generated with piper
(`en_US-lessac-medium`) and Windows SAPI (David, Zira). They prove the
pipeline, they do not sound like anyone worth cloning. Replace them.

## Install (once, outside the repo)

    powershell -ExecutionPolicy Bypass -File tools\chatterbox\setup.ps1 [-Bench]

Under `%LOCALAPPDATA%\aowlspt\chatterbox\` (override `-Root` /
`AOWLSPT_CHATTERBOX_ROOT`):

| what | source | size |
|---|---|---|
| `venv\` | `uv venv --python 3.12`; `torch==2.6.0+cu124 torchaudio==2.6.0+cu124` from https://download.pytorch.org/whl/cu124 (the version chatterbox-tts pins), then `chatterbox-tts==0.1.7` (+ transformers 5.2.0, numpy 1.26.4, 101 packages) | 5.2 GB |
| `hf\` (`HF_HOME`) | `ChatterboxTTS.from_pretrained` pulls huggingface.co/ResembleAI/chatterbox: `t3_cfg.safetensors` 2,129,653,744 B, `s3gen.safetensors` 1,056,484,620 B, `ve.safetensors` 5,695,784 B, `conds.pt` 107,374 B, `tokenizer.json` 25,470 B | 3.0 GB |
| `server.py` | copy of `tools/chatterbox/server.py` | |

Setup loads the model once so the download happens there, not on the first
spoken line. Needs an NVIDIA driver that runs CUDA 12.4 (here: RTX 2060 SUPER
8 GB, driver 581.42) -- `--device cpu` works but is many times slower.

## Run

    set HF_HOME=%LOCALAPPDATA%\aowlspt\chatterbox\hf
    "%LOCALAPPDATA%\aowlspt\chatterbox\venv\Scripts\python.exe" "%LOCALAPPDATA%\aowlspt\chatterbox\server.py" --voices-dir mods\basement\data\voices --port 6974

The basement backend starts it itself (detached, PowerShell `Start-Process`)
on first use when `GET /health` is silent; `chatterboxUrl` in config.json is
the port. Model load: ~18 s warm, 126 s the first time (download).

## API

    GET  /health        -> {"ok":true,"engine":"chatterbox","device":"cuda","gpu":...,"voices":[stems],
                            "voicesDir","sampleRate":24000,"loadMs","synths","firstMs","lastMs","meanMs",...}
    POST /tts           {"text","voice":"<stem>|default","exaggeration":0.5,"cfg_weight":0.5[,"out":path]}
                        -> audio/wav 24 kHz mono 16-bit, or with "out" the wav is written there and the
                           answer is {"ok":true,"path","bytes","ms","ref":<which wav was used>}.
                           An unknown stem falls back to the built-in voice AND SAYS SO in "ref".
    POST /tts/stream    same body -> chunked audio/pcm s16le, ONE CHUNK PER SENTENCE. chatterbox-tts
                        0.1.7 exposes only `generate` (no generate_stream -- checked in the installed
                        package), so a single sentence streams no earlier than /tts finishes; a
                        multi-sentence line plays its first sentence while the rest generate.
    Errors: JSON {"ok":false,"error":...}, never a wav.

`exaggeration` (0..2, default 0.5) pushes emotion/intensity; `cfg_weight`
(0..1, default 0.5) trades pacing/faithfulness -- lower is more expressive.
`mods/basement/data/voices.json` gives every gen voice tag a distinct
`(stem, exaggeration, cfg_weight)` triple.

## Measured on this machine (RTX 2060 SUPER 8 GB) 2026-09-07

13-word sentence, built-in voice, `server.py --bench`:

    first synth (CUDA warm-up):  14,896 ms
    steady state (4 runs):        3,172-4,176 ms, mean 3,685 ms   (2.6-3.2 s of audio)

**That is OVER the 1.5 s per-sentence budget by 2-3x.** Sampling runs at
~27 it/s on this GPU. It is the trade: cloning + realism at 3-4 s per
sentence, versus Kokoro at ~1.3 s with fixed voices. The backend emits each
sentence's wav the moment it is ready, so a 3-sentence reply is audible after
the first ~3.5 s, not after ~11 s.
