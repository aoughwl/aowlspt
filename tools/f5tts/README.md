# tools/f5tts -- F5-TTS on CUDA: the `ai-companion` voice

The deliberately corny, AI-sounding voice for `mods/basement`. On 2026-09-07
the user judged the calm F5 sample "AWFUL AI" and the shouted one
(`samples/f5tts-2.wav`) "hilarious... that exact clip must be used", then
decided the F5 voice is kept ON PURPOSE as "a funny AI robot companion thing".
So this engine is NOT the general voice (that is Orpheus via Groq, wired by
the backend's cloud path) -- it is the voice of one character, `ai-companion`.

`f5tts-2.wav` is kept verbatim as `mods/basement/data/voices/keep-f5-yell.wav`
(md5 `cbd7c0a62e8a98d33d89c56f28ad9ed1`). Never regenerate over it.

## Install (once, outside the repo)

    powershell -ExecutionPolicy Bypass -File tools\f5tts\setup.ps1 [-Bench]

Under `%LOCALAPPDATA%\aowlspt\f5tts\` (override `-Root` / `AOWLSPT_F5TTS_ROOT`):

| what | source | size |
|---|---|---|
| `venv\` | `uv venv --python 3.12`; `torch==2.6.0+cu124 torchaudio==2.6.0+cu124` from https://download.pytorch.org/whl/cu124, then `f5-tts==1.1.22` (transformers 5.16, numpy 2.5, librosa 1.0, vocos) | ~5 GB |
| `hf\` (`HF_HOME`) | `SWivid/F5-TTS` `F5TTS_v1_Base/model_1250000.safetensors` 1.35 GB + `charactr/vocos-mel-24khz` | 1.4 GB |
| `server.py` | copy of `tools/f5tts/server.py` | |

Setup loads the model once so the download happens there, not on the first
spoken line, and warns for every voice wav without a `.txt` transcript.

## Run

    "%LOCALAPPDATA%\aowlspt\f5tts\venv\Scripts\python.exe" "%LOCALAPPDATA%\aowlspt\f5tts\server.py" --voices-dir mods\basement\data\voices --port 6977

Model load: 3.6 s warm (measured), first synth adds ~0.6 s of CUDA warm-up.

## API (the tools/kokoro contract)

    GET  /health        -> {"ok":true,"engine":"f5-tts","role":"ai-companion","device":"cuda","voices":[stems],
                            "voicesDir","sampleRate":24000,"defaults":{"nfe":32,"cfg":2.0,"speed":1.0},
                            "loadMs","synths","firstMs","lastMs","meanMs","lastFirstChunkMs","licence"}
    POST /tts           {"text","voice":"<stem>","yell":false,"nfe":32,"cfg":2.0,"speed":1.0,"seed":N[,"out":path]}
                        -> audio/wav 24 kHz mono 16-bit, or with "out": the wav is written there plus
                           "<out>.done" (written LAST, so its presence means the wav is complete) and the
                           answer is {"ok":true,"path","done","bytes","ms","ref","seed","nfe","cfg","speed","yell"}.
                           The seed is ALWAYS reported: a line the user likes is reproducible bit-for-bit
                           (verified: seed 777 twice -> identical md5; 778 -> different).
    POST /tts/stream    same body -> chunked audio/pcm s16le 24 kHz, ONE CHUNK PER SENTENCE. F5 is a
                        flow-matching model (one denoising run per sentence), so a single sentence
                        streams no earlier than /tts finishes; the first sentence of a multi-sentence
                        line is out while the rest generate. Sentence i uses seed+i.
    Errors: JSON {"ok":false,"error":...} with 4xx/5xx, never a wav. An unknown stem is a 400
    (F5 has no built-in voice, so there is nothing safe to fall back to); a stem without a
    `<stem>.txt` transcript is a 400 naming the file to write.

A voice is `<stem>.wav` + `<stem>.txt` (its transcript) in `--voices-dir`,
rescanned per request. The three `placeholder-*` wavs are PLACEHOLDERS (piper
+ Windows SAPI); their `.txt` is the whisper base.en transcript. Real
references will replace them -- keep the transcript convention.

`yell`: F5 has no emotion/energy control, so the shouted style is a
post-process: gain +6 dB, RBJ high-shelf +4 dB at 3 kHz, tanh soft clip (x1.2,
normalised). That chain is what made `f5tts-2.wav`; `yell:true` IS the
companion's shouted style. `defaults` are f5tts-2's exact settings.

## Measured on this machine (RTX 2060 SUPER 8 GB, driver 581.42) 2026-09-07

13-word sentence "The basement door is locked, and nobody here is going to open it.",
ref `placeholder-sapi-david.wav`, in-process (`bench_f5.py`):

    model load 3.6 s; first synth 3757 ms
    nfe 32 (default): 3067-3236 ms, mean 3144 ms for 3.75 s of audio -> RTF 0.84
    nfe 16:           1604-1718 ms, mean 1656 ms                     -> RTF 0.44
    VRAM: +680 MiB (nvidia-smi total delta), torch peak 776 MiB
    over HTTP: /tts 3210 ms; /tts/stream first chunk of a 2-sentence line 3.18 s, total 5.73 s

That is OVER the 1.5 s per-sentence budget by 2x at nfe 32; nfe 16 is
within it and the user has not yet compared the two by ear (the
`f5tts-yell-29..42-nfe16.wav` samples exist for that). Streaming inside a
sentence is impossible with this architecture.

Licence: code MIT; `F5TTS_v1_Base` weights CC-BY-4.0 (attribute SWivid).
