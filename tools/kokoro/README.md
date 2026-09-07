# tools/kokoro -- Kokoro-82M as a local HTTP TTS server (CPU, ONNX)

The fast, offline voice for `mods/basement` (`ttsEngine: "kokoro"`). 82 M
parameters, 54 voices, 24 kHz, runs on the CPU through `kokoro-onnx` and
onnxruntime -- no GPU, no API key, no network after setup.

## Install (once, outside the repo)

    powershell -ExecutionPolicy Bypass -File tools\kokoro\setup.ps1 [-Bench]

Puts everything under `%LOCALAPPDATA%\aowlspt\kokoro\` (override with `-Root`
or `AOWLSPT_KOKORO_ROOT`):

| file | source | bytes |
|---|---|---|
| `venv\` | `uv venv --python 3.12` + `kokoro-onnx==0.6.1 soundfile` (onnxruntime 1.29, numpy 2.5, espeakng-loader 0.2.4) | ~120 MB |
| `kokoro-v1.0.onnx` | https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx | 325,532,387 |
| `voices-v1.0.bin` | https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin | 28,214,398 |
| `server.py` | copy of `tools/kokoro/server.py` | |

Every step is verified by its finished state (byte size of the download,
`import kokoro_onnx` from the venv) and re-runs are no-ops. The MSYS python on
PATH (3.14) cannot host this -- kokoro-onnx pins `<3.14` and onnxruntime has
no MinGW wheel -- which is why the script prefers `uv` and a managed 3.12.

## Run

    "%LOCALAPPDATA%\aowlspt\kokoro\venv\Scripts\python.exe" "%LOCALAPPDATA%\aowlspt\kokoro\server.py" --root "%LOCALAPPDATA%\aowlspt\kokoro" --port 6971

The basement backend starts this itself (detached, through PowerShell
`Start-Process`) the first time `ttsEngine: "kokoro"` needs a wav and
`GET /health` does not answer. The port is `kokoroUrl` in `config.json`.

## API

    GET  /health                -> {"ok":true,"engine":"kokoro-onnx","voices":[54 ids],"sampleRate":24000,
                                    "loadMs","synths","firstMs","lastMs","meanMs","lastFirstChunkMs",...}
    GET  /voices                -> {"ok":true,"voices":[...]}
    POST /tts                   {"text","voice":"am_michael","speed":1.0,"lang":"en-us"[,"out":path]}
                                -> audio/wav 24 kHz mono 16-bit, or with "out": the server writes the
                                   wav there and answers {"ok":true,"path","bytes","ms",...}
    POST /tts/stream            same body -> Transfer-Encoding: chunked, Content-Type: audio/pcm
                                (s16le, X-Sample-Rate: 24000), ONE CHUNK PER SENTENCE (the text is
                                split on . ! ?); headers are sent WITH the first chunk so the
                                client's time-to-first-byte is time-to-first-audio. With "out" the
                                complete wav is also written when the stream ends. NOT
                                `Kokoro.create_stream`: that batches on ~510 phonemes and returned
                                a 4-sentence line as ONE chunk at 3.1 s (measured 2026-09-07).
    Errors are always JSON {"ok":false,"error":...} with a 4xx/5xx -- never a wav-shaped failure.

## Measured on this machine (i9-10850K, 10c/20t, CPU only) 2026-09-07

13-word sentence "The basement door is locked, and nobody here is going to
open it." (4.10 s of audio), voice `am_michael`, `server.py --bench`:

    model load: 1.6-3.5 s
    first synth: 1510 ms     steady state (4 runs): 1276-1286 ms, mean 1280 ms

That is ~0.31x realtime for a whole sentence, UNDER the 1.5 s per-sentence
budget but not by much; the design streams per sentence so the first sentence
of a reply is audible ~1.3 s after the brain produced it. Through HTTP
(`curl -w %{time_starttransfer}`, voice am_onyx speed 0.92, same sentence):
`/tts` 1.08-1.24 s, `/tts/stream` first chunk 1.07-1.10 s -- for ONE sentence
streaming cannot beat the whole-sentence time; for a 4-sentence line the first
sentence is out at ~1 s instead of 3.1-3.3 s. Two concurrent synths share one
lock (they would not be faster in parallel on a CPU).

Quality: Kokoro-82M topped the TTS Spaces Arena (Elo, human blind pairwise
preference) at release in Jan 2025 ahead of models 10-100x its size; there is
no published MOS from the authors. It is a fixed-voice model -- it cannot
clone -- which is what `tools/chatterbox` is for.

## Voices

`voices-v1.0.bin` holds 54: `af_*` / `am_*` American female/male, `bf_*` /
`bm_*` British, then `e f h i j p z` (Spanish, French, Hindi, Italian,
Japanese, Portuguese, Chinese). `mods/basement/data/voices.json` maps each
gen voice tag to one `(id, speed)` pair, all distinct.
