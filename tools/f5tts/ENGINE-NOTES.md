# F5-TTS engine -- what `mods/basement/bm/speech.nim` needs (one edit)

Mirrors the kokoro/chatterbox engine shape already in `speech.nim` (measured
2026-09-07 at `cKokoroUrl`/`cKokoroRoot`/`cKokoroExe`, `serverProbe`,
`ensureKokoro`). Not applied here: agent P holds `speech.nim`.

## config.json keys (mods/basement/config.json)

    "_f5tts": "f5ttsUrl / f5ttsRoot / f5ttsExe: the CUDA F5-TTS server for the `ai-companion` voice (root default %LOCALAPPDATA%/aowlspt/f5tts). Reuses voicesDir; every <stem>.wav there needs a <stem>.txt transcript beside it.",
    "f5ttsUrl":  "http://127.0.0.1:6977",
    "f5ttsRoot": "",
    "f5ttsExe":  "",

`ttsEngine` gains the value `f5tts`. Defaults, exactly as the other two:

    cF5Url  = defaulted(f5ttsUrl,  "http://127.0.0.1:6977")
    cF5Root = defaulted(f5ttsRoot, joinPath(lad, "aowlspt/f5tts"))
    cF5Exe  = defaulted(f5ttsExe,  joinPath(cF5Root, "venv/Scripts/python.exe"))

## Probe / spawn (the `serverProbe` shape)

    of "f5tts":
      result = serverProbe("f5tts", cF5Url, cF5Exe, joinPath(cF5Root, "server.py"),
                           joinPath(cF5Root, "hf"),          # the weights dir setup.ps1 fills
                           "powershell -ExecutionPolicy Bypass -File tools/f5tts/setup.ps1")

Spawn line (detached, PowerShell `Start-Process`, like `ensureKokoro`):

    <cF5Exe> <cF5Root>/server.py --voices-dir <cVoicesDir> --port <port of cF5Url>

with `HF_HOME=<cF5Root>/hf` in the environment (the server sets it itself if
absent, so this is belt and braces). `GET /health` answers `{"ok":true,
"engine":"f5-tts","role":"ai-companion",...}` when up; load is ~4 s warm,
~2 min the first time (1.4 GB download -- setup.ps1 does it beforehand).

## Request shape (POST /tts, the same curl-with-body-file path as kokoro)

    {"text": <sentence>, "voice": <stem>, "yell": <bool>, "nfe": 32, "cfg": 2.0,
     "speed": 1.0, "seed": <optional int>, "out": <cache wav path>}

* `voice` = a `<stem>.wav` in voicesDir (`keep-f5-yell`, `placeholder-sapi-david`, ...).
  There is NO built-in voice: an unknown stem is a 400, not a silent substitute.
* `yell: true` for a shouted line (the segment's `yell`/`shout` flag, or the
  archetype's mood); the server post-processes (+6 dB, +4 dB shelf, soft clip)
  and reports `"yell":"post-process"`. F5 has no engine-side emotion control.
* `out` -> the server writes the wav and `<out>.done` (written last). Success
  = RIFF at `out` AND `.done` present; a non-200 carries `error`.
* The answer's `seed` should be logged with the say segment so a hit can be
  regenerated: POST the same body with that `seed` -> identical bytes.

Streaming (`POST /tts/stream`) is one chunk per sentence -- for this engine it
buys nothing on a one-sentence segment, so the file path is the right one.

## voices.json

Add a per-tag `f5tts` stem (the `chatterbox` column already has that shape)
and the tag the user asked for:

    "ai-companion": {"kokoro": "am_michael", "speed": 1.0,
                     "chatterbox": "placeholder-sapi-david", "exaggeration": 0.5, "cfg_weight": 0.5,
                     "f5tts": "placeholder-sapi-david", "f5nfe": 32, "f5cfg": 2.0, "f5yell": true,
                     "piper": "lessac"}

Those `f5*` values are exactly what produced `samples/f5tts-2.wav` (ref
`placeholder-sapi-david.wav`, nfe 32, cfg 2.0, speed 1.0, yell chain); the
seed of that clip was random and NOT recorded (bench_f5.py did not print it),
so it is reproducible in style, not bit-for-bit -- `voices/keep-f5-yell.wav`
is the byte-exact keep. `f5yell: true` means the companion's default delivery
is the shouted chain even for calm text; set per-segment `yell` to override.
Pools: `"f5tts": ["placeholder-sapi-david", "placeholder-sapi-zira", "placeholder-piper-lessac"]`.

## Note for the routing

The user's decision (2026-09-07): `ai-companion` -> f5tts; everyone else ->
Orpheus (Groq, cloud path being wired by another agent). A local Orpheus
exists too (`%LOCALAPPDATA%\aowlspt\orpheus\`, llama-cpp-python 0.3.4 cu124 +
SNAC in the xtts venv; TTFA 376 ms but RTF 1.17 on this GPU -- see
tools/xtts/ENGINE-NOTES.md) and XTTS-v2 (tools/xtts, TTFA 0.51 s streaming)
is the offline realistic fallback.
