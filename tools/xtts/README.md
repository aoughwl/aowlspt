# tools/xtts -- Coqui XTTS-v2 on CUDA: offline realistic fallback (cloning + streaming)

The local engine that gets a sentence's FIRST AUDIO out in ~0.5 s on the RTX
2060 SUPER, cloning from a 6-15 s reference wav. Role after the 2026-09-07
listening session: the OFFLINE fallback when the Orpheus cloud path (Groq) is
unavailable. The user has not rated the XTTS samples (`samples/xtts-1.wav`,
`xtts-2.wav`) either way; Kokoro was rejected ("wayyy too AI"), F5 was kept
only as the `ai-companion` joke voice.

## Install (once, outside the repo)

    powershell -ExecutionPolicy Bypass -File tools\xtts\setup.ps1 [-Bench]

Under `%LOCALAPPDATA%\aowlspt\xtts\` (override `-Root` / `AOWLSPT_XTTS_ROOT`):

| what | source | size |
|---|---|---|
| `venv\` | `uv venv --python 3.12`; torch 2.6.0+cu124 + torchaudio from https://download.pytorch.org/whl/cu124; `coqui-tts==0.27.5` with `transformers>=4.54,<5` (MEASURED: transformers 5.16 breaks `isin_mps_friendly`, 4.49 lacks `is_torchcodec_available`; 4.57.6 works) | ~5 GB |
| `tts\` (`TTS_HOME`) | `tts_models/multilingual/multi-dataset/xtts_v2`: model.pth 1.87 GB, dvae, vocab, config | 1.8 GB |
| `server.py` | copy of `tools/xtts/server.py` | |

`COQUI_TOS_AGREED=1` is set by setup and by the server: **the XTTS-v2 weights
are CPML (Coqui Public Model License) -- non-commercial use only.** Fine for a
private mod; not for anything sold.

## Run

    "%LOCALAPPDATA%\aowlspt\xtts\venv\Scripts\python.exe" "%LOCALAPPDATA%\aowlspt\xtts\server.py" --voices-dir mods\basement\data\voices --port 6976

Model load 14 s warm in-process (35 s when the GPU was shared with two other
loaded engines). Conditioning latents per reference: 0.66 s, cached per
(path, mtime).

## API (the tools/kokoro contract)

    GET  /health        -> {"ok":true,"engine":"xtts-v2","device":"cuda","voices":[stems],"voicesDir",
                            "sampleRate":24000,"loadMs","synths","firstMs","lastMs","meanMs",
                            "lastFirstChunkMs","streaming","yell","licence"}
    POST /tts           {"text","voice":"<stem>","yell":false,"speed":1.0,"temperature":0.75,"lang":"en"[,"out":path]}
                        -> audio/wav 24 kHz mono 16-bit, or with "out": wav written there plus "<out>.done"
                           (written LAST) and {"ok":true,"path","done","bytes","ms","ref","yell"}.
    POST /tts/stream    same body -> chunked audio/pcm s16le 24 kHz. TRUE streaming: a chunk every 20
                        GPT tokens from `Xtts.inference_stream`, headers sent with the first chunk, so
                        the client's time-to-first-byte IS time-to-first-audio. With "out" the whole
                        wav (+ .done) is written when the stream ends.
    Errors: JSON {"ok":false,"error":...}, never a wav. Unknown stem = 400 (no built-in voice).

A voice is `<stem>.wav` in `--voices-dir`, rescanned per request. The
`placeholder-*` wavs are PLACEHOLDERS (piper + SAPI); real references will
replace them. `keep-f5-yell.wav` is an F5 output kept for another purpose --
it shows up as a voice because it is a wav in the folder; do not clone it.

`yell`: XTTS has no emotion/energy control (temperature and speed are the only
levers), so a yelled line is post-processed: +6 dB gain, RBJ high-shelf +4 dB
at 3 kHz, tanh soft clip. In `/tts/stream` the chain runs per chunk (the
filter has no cross-chunk state); the wav written to `out` is the same chunks.

## Measured on this machine (RTX 2060 SUPER 8 GB, driver 581.42) 2026-09-07

13-word sentence, ref `placeholder-sapi-david.wav`, in-process (`bench_xtts.py`):

    whole sentence (inference):        1806-2034 ms, mean 1960 ms for 2.92 s audio -> RTF 0.67
    inference_stream, 20 tok/chunk:    first chunk 478-572 ms (mean 528), total 1755-2555 ms
    VRAM: +1895 MiB (nvidia-smi delta); torch peak 1895 MiB
    over HTTP (curl time_starttransfer): /tts/stream first byte 0.513 / 0.519 s (1.45 s on the
    first request after load), total 2.02-2.98 s; /tts 2136 ms

So: OVER the 1.5 s whole-sentence budget, but UNDER 0.55 s to first audio,
and the audio keeps up after that (RTF 0.67 < 1). A streaming client hears
the sentence start half a second after the request.

## The whole comparison (same sentence, same GPU, same day)

| engine | TTFA | total | RTF | VRAM | streaming | cloning | emotion | licence |
|---|---|---|---|---|---|---|---|---|
| Orpheus-3B Q4_K_M local (llama-cpp 0.3.4 cu124 + SNAC) | 376 ms | 5036 ms / 4.3 s audio | 1.17 | 2975 MiB | yes, 85 ms per 7 tokens | no (8 fixed voices) | tags (`<laugh>` `<sigh>` ...), no shout | Apache-2.0 |
| XTTS-v2 (coqui-tts 0.27.5) | 528 ms | 1960 ms / 2.9 s | 0.67 | 1895 MiB | yes, 20-token chunks | yes | none (post-process) | CPML non-commercial |
| F5-TTS v1 nfe32 | 3144 ms | 3144 ms / 3.75 s | 0.84 | 680 MiB | per sentence only | yes | none (post-process) | CC-BY-4.0 |
| F5-TTS v1 nfe16 | 1656 ms | 1656 ms | 0.44 | 680 MiB | per sentence only | yes | none | CC-BY-4.0 |
| Kokoro-82M CUDA (ORT 1.22 + cuDNN 9.1.0) | 336 ms | 336 ms / 4.27 s | 0.08 | 1212 MiB | per sentence only | no | none | Apache-2.0 -- REJECTED by ear |
| Kokoro-82M CPU (tools/kokoro) | 1252 ms | 1252 ms | 0.29 | 0 | per sentence | no | none | Apache-2.0 -- rejected |
| Chatterbox 0.1.7 (tools/chatterbox) | 3.2-5.2 s | same | ~1.2 | ~2 GB | per sentence | yes | `exaggeration` | MIT |

Local Orpheus is SLOWER THAN REALTIME on this GPU (75 tok/s where 82 tok/s is
break-even): with a ~0.8 s buffer it plays a 4 s line without a stall, longer
lines need proportionally more. That is why the Orpheus in production is the
Groq-hosted one.
