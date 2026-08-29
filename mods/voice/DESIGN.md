# `aowl.voice` — conversational agents with voice, server-side

**Status: Phase 2 partial. Default OFF. Read "What is NOT done" before trusting anything here.**

This is the design and the inventory that produced it. It is written to be read by
somebody who has to either use this or finish it.

---

## 1. Inventory — what `EscapeFromMyBasement` actually is

`C:\Users\savant\Projects\EscapeFromMyBasement` (not a git repo, last touched
2025-08-17). Two assemblies plus a tools tree.

### 1.1 What it is built on

| Half | Path | Built on | State |
|---|---|---|---|
| Server mod | `server\EscapeFromMyBasement.Server.csproj` | `net10.0`, `SPTarkov.Server.Core` (SPT **4.x C#** server mod shape), `SptVersion = "~4.1.0"`, `data/modpack.json` `targetSpt: 4.1.2` | **Scaffold only.** `ModEntry.cs` loads three JSON files on `IOnLoad` and logs counts. No routes, no DB patches. |
| Client plugin | `client\EscapeFromMyBasement.Client.csproj` | `netstandard2.1`, **BepInEx**, Mono `Assembly-CSharp.dll` / `Comfort.dll` / `spt-reflection.dll` | **Fully implemented and installed** — `D:\SPT\BepInEx\plugins\EscapeFromMyBasement\EscapeFromMyBasement.Client.dll`, 54,272 B, 2025-08-17. |

Target game is the `D:\SPT` install: `compatibleTarkovVersion 0.16.9.40743` — i.e.
**pre-1.0 Mono EFT**. That single fact is what kills the client half here.

`Plugin.cs::Awake` adds four MonoBehaviours: `ServiceLauncher` (spawns the
sidecars), `PersistentWorldController` (player position + `WorldInteractiveObject`
door states, 30 s autosave, 24 h staleness), `ObjectiveHud` (IMGUI panel), and
`NpcVoiceSystem` (the voice pipeline). The `data/*.json` NPCs (Mara, Nikolai) and
hand-authored dialogue trees belong to an unbuilt design in `docs/` and are **not
wired to the voice system at all**.

> ⚠️ **`client\Plugin.cs:52` hardcodes a live OpenAI API key** as a
> `ConfigEntry` default ("Pre-seeded from the developer's environment"). It is in
> source and compiled into the shipped DLL. **Treat it as leaked and rotate it.**
> Nothing in this new mod carries a key; the OpenAI backend here reads
> `OPENAI_API_KEY` from the environment and refuses to run without it.

### 1.2 The voice pipeline as it exists

Driver: `client\NpcVoiceSystem.cs::RunPipelineAsync`. Four of the five stages are
already out-of-process; only orchestration and playback are in Unity.

| Stage | How | Process | Transport |
|---|---|---|---|
| Capture | push-to-talk **V**, 1.2–8 s, `tools\recorder\recorder.exe` (raw `winmm` P/Invoke, tries 16k→44.1k→48k→22.05k, resamples to 16 kHz mono 16-bit, hand-written RIFF header) | **child process** | `Process.Start`, handshake `RECORDING:<rate>` on stdout, `stop` written to stdin, `DONE:<bytes>`, WAV read from `%TEMP%\efmb_<ticks>.wav` |
| STT | whisper.cpp **v1.9.2** `whisper-server.exe -m ggml-base.en.bin --port 9000`, `[...]` tokens regex-stripped | **child process (HTTP server)** | multipart POST `file` → `http://localhost:9000/inference` |
| Reason | **OpenAI cloud**, `gpt-4o-mini`, `max_tokens 200`, `temperature 0.8`, system+user only, **no history sent** | cloud | HTTPS |
| Knowledge | `tools\tarkov_serve.py` (bottle.py, embeddable CPython 3.11.9) | **child process (HTTP server)** | `GET /context/<npcId>`, `POST /event/<npcId>` on :7070 |
| TTS | `piper.exe --model en_US-lessac-medium.onnx --output-raw`, text in on stdin, raw PCM out on stdout, hand-built 22050/mono/16-bit WAV header, stderr drained on a separate task to avoid deadlock | **child process** | stdin/stdout pipe |
| Playback | `AudioClip.Create` + `AudioSource` on the NPC GameObject, `spatialBlend 1`, linear rolloff, `maxDistance 40` | Unity main thread | in-process, marshalled via `_mainThreadQueue` drained in `Update()` |

Target selection: `NpcDetector.FindNearestTalkableNpc` scores
`Singleton<GameWorld>.Instance.AllAlivePlayersList` by `(dot*2) - (dist/maxRange)`
within 150 m; the winner's `Player.ProfileId` is the NPC identity key.

Tool grammar: the LLM reply is scanned for inline `[OBJ: …]` / `[ADD: …]` /
`[CLEAR]` tags, which drive `ObjectiveSystem`; tags are stripped before TTS.
Objectives persist to `BepInEx\config\EscapeFromMyBasement.objectives.json`.
**This grammar is the real design asset in that repo** and is carried forward here.

### 1.3 The "aoughwl ontology / knowledge integration" — what it concretely is

It is **one 3.1 KB Python file**, `tools\tarkov_serve.py`. Despite the
"belief-graph service" naming in `AoughwlClient.cs`, there is **no graph, no
ontology file, no aoughwl/aowl code, and no persistence**. It is:

* `_KNOWN_NPCS` — a **9-entry hardcoded dict** of one-line boss personas
  (reshala, shturman, sanitar, gluhar, killa, tagilla, knight, bigpipe, birdeye).
* `infer_personality(npc_id)` — **substring match** of the id against those names,
  else a generic scav persona.
* `_npc_events` — an **in-RAM ring buffer**, 20 kept / 10 injected, wiped on exit.

And it has a real bug: the id passed in is `Player.ProfileId`, a per-raid GUID, so
the substring match against `"reshala"` **essentially never fires** — every NPC in
a real raid gets the generic fallback persona.

`tools\Setup-EFMyBasement.ps1`'s first source path for `tarkov_serve.py` is
`\\wsl$\Ubuntu\home\savant\aowltarkov\tarkov_serve.py`, so the actual aowltarkov
work lives in WSL and never made it into this repo.

**Conclusion:** there is no ontology to port. There is a persona table, a
retrieval-into-prompt *pattern*, and an event log. This mod implements that
pattern properly (tagged facts, keyword retrieval, persisted per-agent memory)
rather than porting 3 KB of Python.

### 1.4 Assets on disk (all present, verified 2026-08-22)

Not in the repo — under `D:\SPT\BepInEx\plugins\EscapeFromMyBasement\tools\`,
fetched by `tools\Setup-EFMyBasement.ps1`.

| Path | Size |
|---|---|
| `whisper\ggml-base.en.bin` | 147,964,211 B |
| `whisper\whisper-server.exe` (+ `whisper.dll`, 9 `ggml*.dll`, SDL2) | 725,504 B (+~10 MB) |
| `piper\piper.exe` | 509,952 B |
| `piper\en_US-lessac-medium.onnx` | 63,201,294 B |
| `piper\onnxruntime.dll`, `espeak-ng.dll` + data | ~27 MB |
| `python\` CPython 3.11.9 embeddable | ~21 MB |
| `recorder\recorder.exe` | 9,728 B |

**There is no local LLM anywhere on this machine.** A full-disk sweep for
`*.gguf` / `ggml-*.bin` / `*.onnx` found only the whisper and piper assets above.
Docker Desktop ships a llama.cpp build at
`C:\Users\savant\.docker\bin\inference\` (`com.docker.llama-server.exe`,
`llama-mtmd-cli.exe`, `llama.dll`) but `C:\Users\savant\.docker\models\` is
**empty**. `ollama` is not installed. This is the single largest gap and it is
stated as a gap, not papered over — see §5.

### 1.5 Dead on post-1.0 IL2CPP vs portable

**Dead** — the entire `client/` assembly as written: `BaseUnityPlugin`,
`ConfigEntry`, `BepInEx.Paths`, all four MonoBehaviours; every managed EFT type
(`Singleton<GameWorld>`, `Player`, `ProfileId`, `EFT.Interactive.WorldInteractiveObject`);
`PersistentWorldController`'s `System.Reflection` `GetMethods()/Invoke` on
`SetState(EDoorState)`; `AudioClip.Create`/`AudioSource`; all IMGUI (`OnGUI`,
`GUI.Window`, `ObjectiveHud`). Server side, `SptVersion = "~4.1.0"` and the
`SPTarkov.Server.Core` references are pre-1.0-SPT-bound.

**Portable** — `recorder.exe` (pure winmm, standalone, and the exclusive-mic
problem it solves is still real); the whisper multipart protocol + `[...]` strip;
the piper spawn args, the 22050/mono/16-bit assumption, the stderr-drain and the
WAV header build; the prompt text and the `[OBJ:]/[ADD:]/[CLEAR]` tag grammar;
`tarkov_serve.py` and its 9 personas as *data*; `Setup-EFMyBasement.ps1` as an
asset provisioner; `data/*.json` and `docs/*.md`.

**The structural point:** only two things genuinely need the game — "who am I
looking at and where is he", and "play this WAV there" — plus a HUD. Everything
between the mic and the speaker is sidecar orchestration, and it belongs on the
server.

---

## 2. What runs where, and why

| Concern | Side | Why |
|---|---|---|
| Mic capture (`recorder.exe`) | **server** (host process spawns it) | It is already a standalone winmm exe; nothing about it needs the game. It exists precisely *because* the game holds the mic exclusively, so it must not be in-process. |
| STT (whisper.cpp) | **server** | 141 MB model, seconds of CPU. A stall here must not stall a frame. |
| Reasoning (LLM) | **server** | Same, more so. Restartable, swappable, cannot crash the game. |
| Knowledge / ontology retrieval | **server** | It is a data lookup feeding a prompt string. Zero game coupling. |
| Agent identity, persona, memory, transcript | **server** | Must outlive a raid, must be shared between "the scav you shot at" and "your assistant". |
| Tool-tag parsing (`[OBJ:]` …) | **server** | Pure text. The *effect* of an objective may be client-side; the parse is not. |
| TTS (piper) | **server** | 63 MB voice, subprocess, produces a WAV file. |
| **"who am I looking at, where is he"** | **host/client** | Only the game knows. Out of scope for this mod — a separate agent owns the bot/nav API. |
| **playing a WAV at a world position** | **host/client** | Only the game can. Out of scope here; the WAV path is published over a route for that bridge to consume. |
| Push-to-talk keybind in-game | **host/client** | Out of scope. Today the trigger is an HTTP POST, which is what makes the whole spine testable with no game running. |

The rule this follows: **the host/client side is a thin bridge and nothing else.**
Everything expensive, stateful, or likely to be wrong lives server-side where a
mistake is a bad HTTP response instead of a crashed raid.

---

## 3. Architecture

```
                 POST /aowlspt/voice/listen        (mic → everything)
                 POST /aowlspt/voice/turn          (a .wav path → everything)
                 POST /aowlspt/voice/say           (text → reason → speak)
                        |
                        v
  +----------------------------------------------------------+
  |  mods/voice — one aowlspt mod, sides = {sideServer}       |
  |                                                          |
  |  vx/agents.nim   identities + memory + knowledge         |
  |  vx/pipeline.nim STT / LLM / TTS, one swappable iface    |
  |  vx/engine.nim   subprocess + probe + path resolution    |
  +----------------------------------------------------------+
        |            |             |              |
   recorder.exe  whisper-server  <LLM engine>   piper.exe
   (winmm)       via curl POST    (see below)   (stdin→wav)
```

### 3.1 The engine abstraction

Every external dependency is an **engine**: a `(name, resolved path, probe,
invoke)` tuple. Three properties are deliberate:

1. **Probe before use.** `GET /aowlspt/voice/status` reports, for every engine,
   the *exact path it resolved* and whether that file exists. A missing model is
   reported as `"missing: D:\...\ggml-base.en.bin"` — never as a silent failure
   and never as a fabricated answer. This is the direct answer to "do not assume
   a model file exists".
2. **Swappable by config string**, not by code. `sttEngine`, `llmEngine`,
   `ttsEngine` are config values dispatched by name.
3. **Subprocess, not linkage.** nimony's `std/osproc` is real (`startProcess`,
   `execCmdEx` with `input`, Windows `CreateProcess` path) and is already used by
   `tools/aowl.nim`. Nothing is dynamically linked into the backend, so a broken
   engine cannot take the backend down.

### 3.2 Engines implemented

| Slot | `id` | Invocation | Needs |
|---|---|---|---|
| STT | `whisper-server` | spawns `whisper-server.exe -m <model> --port <p>`, then `curl.exe -s -F file=@<wav> http://127.0.0.1:<p>/inference` | `whisper-server.exe` + `ggml-base.en.bin` (**present**) |
| STT | `none` | returns empty, honestly | — |
| LLM | `builtin` | zero-dependency persona responder: retrieves knowledge by keyword, picks a reply template by intent, echoes the agent's voice. **Not a language model.** Exists so the spine is provable with no model on disk. | nothing |
| LLM | `llamacpp` | `<llamaExe> -m <gguf> -p <prompt> -n <tokens> --no-display-prompt` | a `.gguf` (**absent — see §5**) |
| LLM | `openai` | `curl.exe` POST to `api.openai.com/v1/chat/completions`, key from `OPENAI_API_KEY` env only | network + env key |
| TTS | `piper` | `piper.exe --model <onnx> --output_file <wav>`, text on stdin | `piper.exe` + voice (**present**) |
| TTS | `sapi` | `powershell -c System.Speech.Synthesis` to a wav | Windows only, always present |
| TTS | `none` | writes no audio, returns the text | — |

### 3.3 Agents — why this is not a Tarkov feature

An **agent** is `{id, name, persona, voice, tags, greeting}`. Nothing in the type
mentions Tarkov. `data/agents.json` ships three:

* `assistant` — the Cortana-style personal assistant. No game involvement at all.
  This is a first-class configuration, not a demo.
* `scav` — the generic raid scav (the persona EFMB actually shipped, since its
  boss lookup never fired).
* `tagilla` — a named boss, carrying EFMB's persona text, to show that "an NPC in
  a raid" is just another row.

"A scav in a raid" and "your personal assistant" are the same object with
different fields. That generality is the point of the layer.

Each agent has **memory**: a bounded transcript (`maxTurns`, default 12) that is
actually fed back into the prompt — unlike EFMB, which sent only system+user and
so had no conversational memory at all.

### 3.4 Knowledge

`data/knowledge.json` is a flat list of `{tags, text}` facts. Retrieval is
keyword-overlap between the utterance + the agent's tags and each fact's tags;
the top matches are injected under a `Known facts:` heading. It is deliberately
dumb and deliberately transparent — `GET /aowlspt/voice/status` will tell you how
many facts loaded, and the reply JSON reports which fact ids were injected, so
you can see the retrieval working or not working. **It is not embeddings and not
a graph**; upgrading retrieval means replacing one proc.

### 3.5 The radio — a transport over agents, not a second system

The radio ("a phone, exactly") is **routing**. It adds no pipeline. An utterance
reaches an agent either by *proximity* (you are standing next to them) or by
*radio* (you are tuned to a channel they are on); after routing resolves *which
agent answers*, the identical `reason → speak` path runs. If porting proximity
dialogue meant a second pipeline, the abstraction would be wrong — so it does not.

Three types, and only the third is new:

```
Agent    { id, name, persona, voice, tags, greeting }      — an identity
Channel  { id, label, freq, private, members[] }           — an addressable endpoint
Presence { agentId, channelId, live, distance, canAnswer } — an agent ON a channel, right now
```

**Routing.** `POST /aowlspt/voice/radio/transmit {channel, text|wav}` →
`route(channel)` returns the ordered set of agents whose `Presence` says they can
answer → the first one that can, does → the reply is published on that channel
and on `GET /aowlspt/voice/last` exactly as a proximity reply is. Proximity is
the degenerate case: the implicit channel `local`, whose membership is "the agent
you named".

**Liveness and range are where a radio differs from a phone**, and they must fail
*in fiction*, never silently. Each transmit resolves each member's presence and,
on failure, returns a fiction-shaped `status` the client can voice or print:

| status | meaning | what the player gets |
|---|---|---|
| `ok` | answered | the reply + wav |
| `out_of_range` | alive, but beyond `channel.rangeM` | static / no response, just carrier hiss |
| `dead` | the agent's bot is dead | dead air |
| `unwilling` | alive, in range, persona refuses (hostile, busy) | a refusal line, spoken |
| `no_such_channel` / `empty` | nobody is tuned | the fiction of an empty band |

`private` channels (you ↔ `assistant`) skip range and liveness entirely — the
assistant is not a body in the world, so it is always `ok`. That is the whole
difference between calling your assistant and calling a scav, and it is one flag.

**Presentation belongs to the mod, not the core.** The core answers "who is on
channel 3 and can they hear me". What channel 3 is *called*, who is put on it, and
how it is tuned is `data/channels.json` — the RPG mod's data, editable without
touching code.

#### The bot-roster interface this needs (NOT built here — dependency)

"Bots in the world are on the radio" needs a live census. A separate agent owns
that host-side surface (promoting `botDiag`). **This mod does not build it and
must not.** It is written against this assumed interface, and everything degrades
cleanly when it is absent:

```
GET /aowlspt/bots/roster
{"bots":[{"id":"<stable id>","name":"...","role":"scav|boss|pmc",
          "alive":true,"distanceM":142.0,"map":"factory4_day"}...]}
```

Only four fields are load-bearing here: **`id`** (stable enough to key an agent's
memory across a raid — note EFMB's fatal flaw was keying on a per-raid GUID, so a
role/name-derived id is strictly better than a GUID), **`alive`**, **`distanceM`**
(from the local player), and optionally **`role`** to pick a default persona.

Until it exists, `botRosterUrl` is unset, every world agent resolves as presence
`unknown`, and the config flag `assumeBotsPresent` (default **true**, so the
system is testable) treats them as alive and in range. `GET /aowlspt/voice/status`
states which of the two is in force, so nobody is fooled into thinking a live
census is wired when it is not.

### 3.6 Routes

| Route | Body | Does |
|---|---|---|
| `GET /aowlspt/voice/status` | — | every engine, its resolved path, present/missing; agent + fact counts |
| `GET /aowlspt/voice/agents` | — | the agent roster |
| `POST /aowlspt/voice/say` | `{"agent":"assistant","text":"..."}` | reason → TTS. **The shortest proof the spine works.** |
| `POST /aowlspt/voice/turn` | `{"agent":"scav","wav":"C:/…/x.wav"}` | STT → reason → TTS |
| `POST /aowlspt/voice/listen` | `{"agent":"assistant","seconds":6}` | record → STT → reason → TTS. Full mic-to-speaker. |
| `POST /aowlspt/voice/observe` | `{"agent":"scav","event":"..."}` | append to that agent's memory (the `POST /event/<id>` equivalent) |
| `GET /aowlspt/voice/last` | — | the most recent exchange + its wav path — **this is the whole client-bridge surface**: a host-side mod polls this and plays the file. |
| `GET /aowlspt/voice/radio/channels` | — | every channel, its members, and each member's resolved presence right now |
| `POST /aowlspt/voice/radio/tune` | `{"channel":"3"}` | select the active channel (the RPG comms-device gesture) |
| `POST /aowlspt/voice/radio/transmit` | `{"channel":"3","text":"..."}` or `{"wav":"…"}` | route → the agent who can answer → the same reason/speak path; returns `status` per the table in §3.5 |
| `GET /aowlspt/settings/aowl.voice` | — | the F12 schema, with `implemented=false` on everything not done |

Every reply carries `{ok, agent, heard, reply, wav, engines:{stt,llm,tts}, ms:{…}, notes:[…]}`.
`notes` is where a degraded path says so.

---

## 4. Config

`mods/voice/config.json`. **`enabled` defaults to `false`** — nothing spawns a
subprocess until it is turned on.

---

## 5. What was measured

Run through `aowlspt-sim mods/voice --side server --route <url>[,<body>]`, with
no game and no backend. All numbers are wall clock on this machine, 2026-08-22.

| Path | Result |
|---|---|
| Load | 4 agents, 10 facts, 4 channels; 11 routes registered |
| Probe | all four engines resolved and **present** — whisper-server, ggml-base.en.bin, piper.exe, the lessac voice, recorder.exe |
| `say` (reason → speak) | **609–750 ms**, produced a real `.wav`; `ffprobe`: `pcm_s16le, 22050 Hz, 1 channel, 4.93 s` |
| `turn` (wav → transcribe → reason → speak) | **2.67 s** including whisper-server's cold start; transcript came back correct |
| `listen` (mic → everything) | **worked once, end to end.** The mic picked up the machine's own playback of an earlier piper wav; whisper transcribed it correctly and the agent answered and spoke. Subsequent attempts returned `recorder produced -1 bytes (exit 2): NO_DEVICES` — see §5.1. |
| `radio/transmit` on channel 3 | routed to Tagilla, answered, spoke |
| `radio/transmit` to a world agent with `assumeBotsPresent: false` | `{"ok":false,"status":"unknown"}` plus a note naming the missing host-side bot API — the dependency degrades honestly instead of pretending |
| `radio/transmit` on the private channel, same config | unaffected: the assistant has no body, so range and liveness are never consulted. That is the private/world split working. |
| Memory | two turns with `testagent` left it at 4 lines and every other agent at 0 — per-agent, isolated |
| `radio/transmit` on a channel that does not exist | `{"ok":false,"status":"no_such_channel"}` — fails in the fiction, as designed |
| `aowl-regcheck --repo .` | 183 checks, **3 failures, all pre-existing** (`mods/admin`, `mods/graphics`, `mods/settingshub` have no registry entry on this branch). `aowl.voice` adds no failure; it raises the unconditional "in no list" *soft warning*, which is the intended state for a mod meant to be switched on by hand. |

Two things were found by running it, not by reading it, and both are fixed:

* **Retrieval let the persona outshout the question.** Asking the assistant
  "where do I extract" returned the fact tagged `assistant help aowl` ahead of
  the one tagged `exit extract`, because the agent's own tags contributed more
  matches than the sentence did. The utterance is now weighted 3 to 1 over the
  agent's tags.
* **A directly spawned whisper-server hangs every reader of our output.**
  `CreateProcess` (which `startProcess` and `cmd /c start` both reach) passes
  handle inheritance on, so the server holds a duplicate of our stdout pipe for
  the rest of the session and the read end never sees EOF. The route answered
  and then the process hung at exit — twice, reproducibly. It is now launched
  through PowerShell's `Start-Process`, which passes `bInheritHandles = FALSE`.

### 5.1 The microphone is not reliable here

`record` worked once and has since returned `NO_DEVICES` (`waveInGetNumDevs()`
returned 0). That is the recorder reporting honestly, not a silent failure, and
`/listen` surfaces it verbatim. It is a machine/permissions condition rather than
a code path — EFMB's own source notes the fix as *Settings → Privacy →
Microphone → "Allow desktop apps to access your microphone"*. **The stage either
side of it is proven**: `turn` takes a `.wav` and does everything from there, so
the mic is the only unconfirmed link in the chain.

### 5.2 emutest was not re-run against a self-built backend

The gate's number could not be honestly produced. Running it needs `mods/tarkov`,
the backend and `emutest.exe` all built from **this** worktree, and for the whole
session this machine had up to four concurrent `aowl` builds and a dozen `gcc`
processes belonging to other agents — and this repo's documented hazard is that
concurrent nimony builds corrupt each other through a shared cache and fail
naming identifiers from files nobody touched. Building into that would have
produced a number worth nothing.

Mixing binaries across branches was tried and correctly refused: staging the main
checkout's `tarkov.dll` against this worktree gave
`{"err":"no route","url":"/aowlspt/tarkov/selfcheck"}`, which is the cross-branch
mismatch and not a regression. **That result is discarded, not reported.**

What can be said instead: this change adds one directory under `mods/` and one
entry to `registry/mods.json`, and touches nothing `emutest` stages — it stages
only `mods/tarkov`, its data and `tests/fixtures/emu-full.json`. The six
regression markers are all present (`ensurePockets`, `post1LocationsTuned`,
`tuneOfflineSpawns`, `imageCdnRedirect`, `onFiles`, `creation-session`). The
command to run when the machine is quiet:

```
installer\build\aowl.exe build
installer\build\emutest.exe --root installer\build\emustage ^
    --backend backend\bin\aowlspt-backend.exe --port 6975
```

Baseline is **18 failures**.

## 6. What is NOT done — read this

* **There is no local LLM.** No `.gguf` exists on this machine and none is
  downloaded by this mod. `llmEngine: "llamacpp"` is wired and will run, but it
  probes as `missing` and refuses. The default is `builtin`, which is a
  **template responder, not a language model** — it proves the spine, and it says
  so in every response it produces (`notes: ["llm=builtin: template responder, not a language model"]`).
  To get real reasoning: drop a `.gguf` somewhere, set `llamaExe` (Docker's
  `com.docker.llama-server.exe` sibling CLI, or any llama.cpp build) and
  `llamaModel`, set `llmEngine: "llamacpp"`.
* **Nothing client-side exists.** No push-to-talk keybind, no NPC targeting, no
  spatialised playback. `GET /aowlspt/voice/last` is the seam a host-side bridge
  would consume; that bridge is not written and is out of scope per the brief.
* **The `[OBJ:]/[ADD:]/[CLEAR]` tag grammar is parsed and stripped, but the
  objectives are only stored** — nothing renders or acts on them.
* **No persistence across backend restarts.** Agent memory is in RAM, exactly
  like EFMB's was. `store*` in the aowlspt API is the intended home; not wired.
  **Exception: the response/line cache (§7) does persist across restarts.**
* **Engine processes are spawned but not supervised.** whisper-server is started
  on first use and left running; there is no health check, restart, or shutdown
  hook. `curl --retry-connrefused` covers the start-up race, so a cold start
  costs about two seconds and is not a failure -- but nothing notices if the
  server dies.
* **The microphone is unconfirmed on this machine** -- see §5.1.
* **Not tested against a live raid.** Nothing here has touched the game.

---

## 7. The response + line cache (added on `feat-voice-port`)

`vx/cache.nim`. Every reply used to be generated live -- LLM then piper -- on
every `say`/`turn`, even for lines that repeat (a scav's greeting, a taunt).
The cache returns a stored `{reply, wav}` for a key it has seen **without
touching the LLM or piper**, which is the latency win.

* **Key** = `(agentId, normalized utterance, llmEngine, ttsEngine+voice)`. It
  deliberately does **not** include conversation memory, so it matches repeated
  stateless LINES, not context-dependent turns. `/status` says so, in words, so
  a hit is never mistaken for memory-aware reasoning. Changing engine or voice
  changes the key and misses -- a cached wav is only ever replayed for the exact
  engine and voice that made it.
* **Flow.** `converse` checks the cache first. HIT -> return the stored reply
  and wav, mark it MRU, `cached:true`. MISS -> generate, then `cacheStore` copies
  the wav out of the backend temp dir into the cache dir under a stable name and
  writes the index. An empty reply (llm=none/unavailable) is not cached, so a
  real failure is never masked by a fast empty hit.
* **Bounded.** `cacheMaxEntries` (LRU eviction) plus an optional
  `cacheTtlSeconds`. Eviction removes the entry and its wav.
* **Persisted** under `cacheDir` (default `mods/voice/data/cache/`) as
  `index.json` + one wav per entry, sentinel-tailed so a torn write is detected
  and the cache starts empty rather than parsing garbage. The key is **hex-
  encoded** in the index: `aowlspt/json`'s reader does not decode a ``
  escape back to the byte, so a raw separator did not round-trip and every
  persisted entry missed (measured, then fixed).
* **Config**: `cacheEnabled` (default true), `cacheMaxEntries` (256),
  `cacheDir`, `cacheTtlSeconds` (0 = never), `precacheCommonLines` (default off:
  on load, generate each agent's greeting utterances into the cache).
* **Reported truthfully** on `/status.cache`: enabled, dir, entries, maxEntries,
  ttlMs, and a running hits/misses tally, so a client can SEE the cache working
  rather than take it on faith. Each reply also carries `cached: true|false`.

Measured offline through `aowlspt-sim` (no game, no backend), builtin LLM:
say the same utterance twice -> 2nd is `cached:true` and the hit/miss counters
move; a different utterance is `cached:false`. With piper as TTS the MISS was
`ms 2266` and the HIT `ms 0` returning the same 292 KB wav. `cacheMaxEntries=2`
fed three distinct utterances left `entries:2`. A fresh process re-loaded the
index and the prior utterance hit from disk. STT (whisper) and the microphone
remain the only stages unrunnable/unconfirmed on this machine (DESIGN §5.1) --
INCONCLUSIVE, not faked.
