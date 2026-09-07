# XTTS-v2 engine -- what `mods/basement/bm/speech.nim` needs (one edit)

Mirrors the kokoro/chatterbox shape in `speech.nim` (`cKokoroUrl`/`cKokoroRoot`/
`cKokoroExe`, `serverProbe`, `ensureKokoro`). Not applied here: agent P holds
`speech.nim`. Role: OFFLINE realistic fallback (cloning + 0.5 s TTFA) when the
Groq Orpheus path is down; `tools/f5tts/ENGINE-NOTES.md` is the `ai-companion`
engine.

## config.json keys

    "_xtts": "xttsUrl / xttsRoot / xttsExe: the CUDA XTTS-v2 cloning+streaming server (root default %LOCALAPPDATA%/aowlspt/xtts). Reuses voicesDir. CPML licence: non-commercial.",
    "xttsUrl":  "http://127.0.0.1:6976",
    "xttsRoot": "",
    "xttsExe":  "",

`ttsEngine` gains `xtts`:

    cXttsUrl  = defaulted(xttsUrl,  "http://127.0.0.1:6976")
    cXttsRoot = defaulted(xttsRoot, joinPath(lad, "aowlspt/xtts"))
    cXttsExe  = defaulted(xttsExe,  joinPath(cXttsRoot, "venv/Scripts/python.exe"))

## Probe / spawn

    of "xtts":
      result = serverProbe("xtts", cXttsUrl, cXttsExe, joinPath(cXttsRoot, "server.py"),
                           joinPath(cXttsRoot, "tts"),        # TTS_HOME/tts holds the weights
                           "powershell -ExecutionPolicy Bypass -File tools/xtts/setup.ps1")

Spawn (detached, PowerShell `Start-Process`):

    <cXttsExe> <cXttsRoot>/server.py --voices-dir <cVoicesDir> --port <port of cXttsUrl>

Environment: `TTS_HOME=<cXttsRoot>`, `COQUI_TOS_AGREED=1` (the server sets both
if absent). `GET /health` -> `{"ok":true,"engine":"xtts-v2",...}`; load 14-35 s.

## Request shape (POST /tts, curl with a body file, like kokoro)

    {"text": <sentence>, "voice": <stem>, "yell": <bool>, "speed": 1.0,
     "temperature": 0.75, "lang": "en", "out": <cache wav path>}

* `voice` = `<stem>.wav` in voicesDir. No built-in voice; unknown stem = 400.
* `yell: true` -> post-process (+6 dB, +4 dB shelf @3 kHz, soft clip); the
  answer says `"yell":"post-process"`. No engine-side emotion control.
* `out` -> wav + `<out>.done` (written last). Success = RIFF at `out` and
  `.done` present; non-200 carries `error`.

## Streaming (the reason to use this engine)

`POST /tts/stream`, same body, answers `Transfer-Encoding: chunked`,
`Content-Type: audio/pcm` (s16le, `X-Sample-Rate: 24000`, `X-Channels: 1`,
`X-Bits: 16`, `X-First-Chunk-Ms`). Chunks arrive every 20 GPT tokens (~0.4 s
of audio each); MEASURED over HTTP: first byte 0.51 s, total 2.0 s for a
13-word sentence. If the say-segment path can feed PCM to the game before the
file is complete, use this route and let `out` fill the cache afterwards;
otherwise `/tts` at ~2.1 s per sentence.

## voices.json

Add an `xtts` stem per tag (same shape as `chatterbox`), pool
`["placeholder-sapi-david", "placeholder-sapi-zira", "placeholder-piper-lessac"]`.
XTTS has no `exaggeration`; `temperature` 0.65-0.85 is the only expressiveness
knob (0.75 default).

## Local Orpheus (for the record; not stood up as a server)

`%LOCALAPPDATA%\aowlspt\xtts\venv` also holds `llama-cpp-python==0.3.4` (the
cu124 wheel from https://abetlen.github.io/llama-cpp-python/whl/cu124 -- PyPI's
0.3.35 faults with STATUS_ILLEGAL_INSTRUCTION in `llama_init_from_model` on
this i9-10850K) and `snac==1.2.1`; the GGUF is
`%LOCALAPPDATA%\aowlspt\orpheus\orpheus-3b-0.1-ft-q4_k_m.gguf` (2,363,760,768 B,
isaiahbjork/orpheus-3b-0.1-ft-Q4_K_M-GGUF). `import torch` must precede
`import llama_cpp` (the CUDA DLLs come from torch/lib). Measured: TTFA 376 ms,
74.7 tok/s = RTF 1.17 (needs ~0.8 s of buffer per 4 s line), 2975 MiB. Token
path: ids `[128259] + tok("<voice>: <text>") + [128009, 128260]`, audio ids
>= 128266, code = id - 128266 - 4096*(i mod 7), SNAC-decode a 28-token window
every 7 tokens keeping samples 2048:4096, stop at 128258; sampling temp 0.6,
top_p 0.9, repeat_penalty 1.1. Bench script: scratchpad `bench_orpheus.py`
(not promoted -- the production Orpheus is Groq's).
