# aowl.voice — conversational agents with voice

Talk to things. A scav in a raid, a boss on the radio, or your own assistant —
all the same system, all served from the backend so nothing here can stall a
frame or crash a raid.

**Default OFF.** Read `DESIGN.md` for the architecture, the inventory of
`EscapeFromMyBasement` it was ported from, and — most importantly — **§5, what is
not done**.

---

## Turning it on

1. `mods/voice/config.json` → `"enabled": true`.
2. `config.json` → `toolsDir` must point at a directory containing `whisper/`,
   `piper/` and `recorder/`. It defaults to EscapeFromMyBasement's, which is
   already on this machine:
   `D:/SPT/BepInEx/plugins/EscapeFromMyBasement/tools`.
3. Start the backend, then **ask it what it actually found**:

```
curl http://127.0.0.1:6969/aowlspt/voice/status
```

That reports, per engine, the exact absolute path it resolved and whether that
file exists. A missing model reads `missing: D:\...\ggml-base.en.bin`. Nothing
here fails silently.

## The end-to-end path

Shortest proof the spine works — no microphone, no game:

```
curl -X POST http://127.0.0.1:6969/aowlspt/voice/say \
     -d "{\"agent\":\"assistant\",\"text\":\"where do I extract\"}"
```

You get back the reply text, the path to a spoken `.wav`, which knowledge facts
were retrieved, and a `notes` array saying what each stage did. Play the `wav`.

Full microphone → transcription → reasoning → speech (talks for 5 seconds):

```
curl -X POST http://127.0.0.1:6969/aowlspt/voice/listen \
     -d "{\"agent\":\"assistant\",\"seconds\":5}"
```

On the radio instead:

```
curl http://127.0.0.1:6969/aowlspt/voice/radio/channels
curl -X POST http://127.0.0.1:6969/aowlspt/voice/radio/tune -d "{\"channel\":\"3\"}"
curl -X POST http://127.0.0.1:6969/aowlspt/voice/radio/transmit -d "{\"text\":\"anyone on this band\"}"
```

## Routes

| Route | Body | Does |
|---|---|---|
| `GET /aowlspt/voice/status` | — | every engine, its resolved path, present/missing |
| `GET /aowlspt/voice/agents` | — | the roster, with each agent's memory depth |
| `POST /aowlspt/voice/say` | `{agent,text}` | reason → speak |
| `POST /aowlspt/voice/turn` | `{agent,wav}` | transcribe → reason → speak |
| `POST /aowlspt/voice/listen` | `{agent,seconds}` | record → the above |
| `POST /aowlspt/voice/observe` | `{agent,event}` | push a world event into that agent's memory |
| `GET /aowlspt/voice/last` | — | the last exchange + wav — **the whole client-bridge surface** |
| `GET /aowlspt/voice/radio/channels` | — | channels, members, live presence |
| `POST /aowlspt/voice/radio/tune` | `{channel}` | select the active channel |
| `POST /aowlspt/voice/radio/transmit` | `{channel,text\|wav}` | route → the agent who can answer |

## Data you edit, not code

* `data/agents.json` — identities. `world: false` is a voice with no body (your
  assistant); `world: true` is something that can be dead or out of range.
* `data/channels.json` — the radio. `private: true` skips range and liveness.
* `data/knowledge.json` — tagged facts, retrieved by keyword overlap and injected
  into the prompt.

## Engines

Each stage dispatches on a config string, so swapping a backend is an edit, not
a code change.

| Slot | ids |
|---|---|
| `sttEngine` | `whisper-server`, `none` |
| `llmEngine` | `builtin`, `llamacpp`, `openai`, `none` |
| `ttsEngine` | `piper`, `sapi`, `none` |

> **`builtin` is a template responder, not a language model.** There is no
> `.gguf` anywhere on this machine, so it is the default and it says so in the
> `notes` of every response it produces. For real reasoning: get a `.gguf`, set
> `llamaExe` + `llamaModel`, set `llmEngine: "llamacpp"`.

> **No API key lives in this mod.** `openai` reads `OPENAI_API_KEY` from the
> environment and refuses without it. (EscapeFromMyBasement hardcoded a live key
> into `client/Plugin.cs:52` and compiled it into the shipped DLL — that key
> should be treated as leaked and rotated.)
