# aowl.basement — CLIENT CONTRACT

**The spec that BOTH clients implement**: the aowlspt IL2CPP host bridge, and a
BepInEx plugin for SPT 4.1.5. Neither exists yet (DESIGN.md §10). This file is
written so that someone who has never read the nimony can write the C# plugin
from it alone.

Status of every claim here: **DESIGN** (a decision) unless marked MEASURED.
Nothing in this document has yet talked to a running game.

---

## 0. The client's whole job, in four sentences

1. **Report facts.** Anything the world does that the backend cannot know —
   where the player is, who they can see, what they shot — is POSTed to
   `/observe`. The client never decides what it *means*.
2. **Capture speech.** While the talk key is held, stream PCM to
   `/speech/chunk`. Stop on release with `final:true`.
3. **Execute directives.** Long-poll `/events`, run each directive, `POST /ack`
   with the seq. A directive you cannot run is acked `ok:false` with a reason —
   that is a *correct* response, not a failure to hide.
4. **Play audio.** `say` events carry a wav path; play them **in `seq` order**,
   back to back, without waiting for the sentence marked `final`.

The client holds no game state the backend needs. If the client restarts, it
re-reads `/world/people` and resumes the stream from a stored cursor.

---

## 1. Transport

Base URL: the same host/port the client already uses for the backend
(`https://127.0.0.1:443` on aowlspt, the SPT server on SPT). All routes are
under `/aowlspt/basement/`.

Every response is a JSON object with at least `ok: bool`. On `ok:false` there
is `err: string`. **A route never returns a bare array**, except `/events`
(§4), which returns `{ok, events:[...], latestSeq, firstSeq}`.

Content type is `application/json; charset=utf-8`. Numbers are integers unless
the field name ends in `M` (metres) or the field is documented as a float.
Times are **milliseconds**. `atMs` on an event is the backend's own monotonic
clock (`nowMs()`, ms since backend start) — it is **not** an epoch and must not
be shown to a player as a date.

Ids are opaque strings. Do not parse them. `"player"` is the reserved id for
the human.

---

## 2. `POST /observe` — every fact kind

Body: `{"kind": "...", ...fields}`. Response:
`{"ok":true, "directives": N, "state": "<encounter state or empty>", "note":"..."}`
where `directives` is how many new events landed on the stream as a result —
so the client can decide to poll immediately instead of waiting out its
long-poll.

Send facts **as they happen**, not on a timer, with the two exceptions marked
*throttled* below. A fact the backend already knows is cheap but not free.

| kind | fields | when the client sends it |
|---|---|---|
| `raid_started` | `map: string`, `spawnX/Y/Z: float` | the local player is in a loaded world |
| `raid_ended` | `reason: "extract"\|"death"\|"disconnect"` | leaving the world |
| `tick` | `nowMs: int` | *throttled*: once per second while in world. Drives contract expiry and the sim clock. |
| `player_moved` | `map`, `x`,`y`,`z: float`, `yaw: float` | *throttled*: on movement, at most 4 Hz, and always immediately after a teleport/spawn |
| `player_seen` | `personId: string`, `distanceM: float`, `inViewCone: bool`, `refresh: bool` | a backend-known person entered the player's view (see §6) |
| `player_lost` | `personId` | that person left view or died out of sight |
| `npc_moved` | `map: string`, `people: [{personId, x, y, z}]` | *throttled*: every 2 s, **ONE batched POST** carrying every person the client has bound to a live bot. This is how the backend knows who is close enough to be heard when they are NOT in the view cone -- somebody shouting at your back is exactly what `player_seen` cannot report. A single-person body (`personId`,`x`,`y`,`z`) is accepted too, for a hand-written probe. |
| `player_aimed_at` | `personId`, `distanceM` | the aim reticle rested on that person for ≥ 400 ms while a weapon is raised |
| `player_lowered_weapon` | — | the player holstered or lowered for ≥ 1 s |
| `player_fired` | `at: string` (a personId or `""`), `hit: bool` | a shot leaves the player's weapon |
| `player_hit` | `by: string` (personId or `""`), `hp: float 0..1` | the player took damage |
| `player_died` | `by: string` | |
| `npc_died` | `personId`, `by: string` (`"player"`, a personId, or `""`) | a backend-known person died |
| `player_spoke` | `text: string` | ONLY when the client did the STT itself. Normally speech arrives via §3 and the client never sends this. |
| `player_gave` | `personId`, `item: string`, `count: int` | the player handed something over |
| `player_took` | `item`, `count`, `fromId: string` | looted or was given |
| `player_extracted` | `exitName: string` | |
| `escape_attempt` | `captorId`, `distanceM` | the client's own leash check tripped (§5.6). The backend re-checks from `player_moved`; sending this only makes it immediate. |

`player_seen` is sent AGAIN, with `refresh:true`, whenever that person's
distance has changed by 2 m or more and 0.5 s has passed. That is not chatter:
the `approach` and `push` triggers of 7.1 are derived from CONSECUTIVE
distances, and with an edge-only report there is never a second sample, so they
could never fire at all.

**Unknown `kind` is not an error.** The backend answers `ok:true` with
`note:"unknown fact kind '<k>' — ignored"`. That keeps an older client working
against a newer backend. The reverse (a directive kind the CLIENT does not
know) is handled in §5.

---

## 3. `POST /speech/chunk` — the speech protocol

Body:

```json
{ "session": "<client-chosen id, stable for one utterance>",
  "seq": 0,
  "wavBase64": "<base64 of raw PCM, or of a whole .wav file>",
  "path": "",
  "final": false }
```

Response:

```json
{ "ok": true, "session": "...", "seq": 0,
  "partial": "", "final": "", "closed": false, "note": "..." }
```

### Rules the backend enforces (each of these can refuse you)

* **`session`** is any non-empty string. Use a GUID per utterance. Reusing a
  session id after `final` starts a NEW buffer.
* **`seq` must strictly increase within a session, starting at 0.** A repeated
  or older seq is **refused** (`ok:false`) and **nothing is appended** — the
  note names both seqs. This makes a retried POST safe: a retry that the server
  already applied is rejected rather than doubling the audio.
* **Exactly one of `wavBase64` / `path`.** `path` is an absolute path readable
  by the backend process; use it only when client and backend are on the same
  machine and the chunk is large. `wavBase64` is the portable form.
* **Format.** 16 000 Hz, **mono**, **16-bit signed little-endian PCM**. You may
  send either raw PCM or a complete RIFF/WAVE file per chunk; the backend
  detects `RIFF` and walks the chunk list to find `data` (it does *not* assume
  data is at offset 36 — SAPI writes a `fact` chunk first).
* **The format may not change mid-session.** A chunk whose rate/channels/bits
  differ from the session's first chunk is refused. **There is no resampling
  anywhere in this system.** If your capture device is 48 kHz, downsample in
  the client.

### Chunk size guidance

* **Target 200–400 ms of audio per chunk** = 6 400–12 800 bytes of PCM
  (16 000 × 2 bytes/ms = 32 bytes per ms). Base64 inflates that by 4/3.
* Smaller than ~100 ms wastes a round trip per chunk for no gain: the backend
  only re-runs whisper every `sttPartialMs` (default **1200 ms**) of *new*
  audio, so 3–6 chunks arrive between two transcription passes.
* Larger than ~1000 ms defeats the point — the first partial cannot appear
  before the first chunk does.
* An utterance longer than ~30 s should be split into separate sessions by the
  client; nothing enforces this, but whisper's cost is superlinear in buffer
  length and every partial re-runs the **whole** buffer.

### Partial vs final

* `partial` is a **preview**. It appears on some responses and not others, it
  **changes as more audio arrives**, and it is never fed to the NPC brain.
  Use it for on-screen "what the game heard" feedback only.
* Send `final:true` on release. That chunk may carry the last audio or no audio
  at all. The response's `final` field is the transcript that the brain
  receives, `closed` is `true`, and the session's buffer is freed. **A session
  that is never finalised leaks a buffer** — always send it, including on
  cancel.
* **If whisper is not installed, `ok` is still `true` and `partial`/`final`
  stay empty**, with `note` naming the exact missing path. The client MUST
  treat an empty `final` as "not transcribed", never as "the player said
  nothing". Show the note.

The resulting `heard.final` fact and the NPC's reply arrive on the **event
stream** (§4), not in this response.

---

## 4. `GET /events` — the long poll

```
GET /aowlspt/basement/events?since=<int>&wait=<ms>&limit=<int>
```

```json
{ "ok": true, "latestSeq": 412, "firstSeq": 88,
  "events": [ {"seq": 409, "atMs": 1234567, "kind": "say", "data": { ... }} ] }
```

* **`since` is exclusive**: only `seq > since` is returned, oldest first. Start
  at `0` to get everything the ring holds.
* **`wait`** is milliseconds to hold the request open when there is nothing
  new. **Clamped to 25 000 ms**; `wait=0` (or absent) returns immediately,
  with `"events": []` if there is nothing.
* A timeout returns `ok:true` with an **empty array**, not an error and not a
  204. Re-issue with the same `since`.
* **`limit`** caps the batch (default: all). If you get exactly `limit` events,
  poll again immediately with `wait=0` before going back to long-polling.
* **`firstSeq` is the hole detector.** The ring is bounded (default 2048
  events). If your stored cursor is `< firstSeq - 1`, you have **provably
  missed events**: re-sync by calling `/world` and `/world/people` and set your
  cursor to `latestSeq`. Do not silently resume.
* Persist your cursor across a client restart. Do not reset to 0 — you will
  replay old directives.

### Push (optional, aowlspt only)

When the backend knows the player's session id and the host can push, every
event is **also** sent over the game's notifier websocket with the identical
JSON object. A client that consumes pushes must still de-duplicate by `seq` and
must still long-poll, because a push is best-effort: a session with no open
socket is a normal answer, not an error.
**MEASURED: in `aowlspt-sim`, push is unavailable** (`notifyReady()` is false —
the simulator holds no game websocket), so the long-poll is the only transport
proven today.

---

## 5. Directives — every kind, its fields, and its ack

An event with `"ack": true` in `data` is a **directive**: the backend is
waiting to hear that it happened. Each carries `"ttlMs"`. If no ack arrives
within the ttl the backend journals `directive.dropped` **once** and gives up —
the world then proceeds as though the thing did not happen, which is the
correct outcome but usually the wrong story, so an unacked directive is a bug
in the client, not a shrug.

### `POST /ack`

```json
{ "seq": 409, "ok": true, "note": "spawned 3 at 118,2,-44" }
```

Response `{"ok":true, "cleared":true}`. `cleared:false` means that seq was not
pending — already acked, or already expired. **Ack once.**

**`ok:false` with a reason is a first-class answer.** "no navmesh at that
point", "the player is in a loading screen", "this build cannot spawn bots".
The backend can react to a refusal; it cannot react to silence.

**An unknown directive kind must be acked `ok:false`** with
`note:"unsupported kind"` — not ignored. Ignoring turns a version mismatch
into a mystery.

| kind | data fields | ack | ttl | the client does |
|---|---|---|---|---|
| `say` | `personId`, `text`, `wav` (absolute path or `""`), `segmentIdx: int`, `final: bool`, `voice`, `tts`, `voiceSpec`, `cachedWav`, `ttsNote`, and the hearing fields **`distanceM`, `mode`, `audible`, `reaction`, `hearSpeakM`, `hearYellM`, `hearingNote`** (7.1) | no | — | see §7 |
| `heard.partial` | `session`, `text` | no | — | optional subtitle |
| `heard.final` | `session`, `text` | no | — | show what was understood |
| `npc.stance` | `personId`, `stance: "hostile"\|"neutral"\|"friendly"` | yes | 10 000 | set the bot's hostility toward the player |
| `npc.follow` | `personId`, `target: "player"\|<personId>` | yes | 10 000 | |
| `npc.hold` | `personId` | yes | 10 000 | stop and guard in place |
| `npc.goto` | `personId`, `map`, `x`,`y`,`z` | yes | 30 000 | ack when the order is *accepted*, not when it arrives |
| `npc.attack` | `personId`, `target: "player"\|<personId>` | yes | 10 000 | |
| `npc.give` | `personId`, `item`, `count` | yes | 15 000 | spawn/transfer into the player's inventory |
| `npc.take` | `personId`, `item`, `count` | yes | 15 000 | remove from the player; ack `ok:false` if it is not there |
| `group.spawn` | `factionId`, `count: int`, `near: {map,x,y,z}`, `radiusM`, `people: [ {id,name,role,voice,loadoutNote} ]` | yes | 30 000 | spawn those bots, and remember `id → your bot handle` |
| `player.captive` | `captorId`, `allowedActions: ["walk","talk"]`, `escortTo: <placeId>`, `leashM: float`, `stripSlots: ["FirstPrimaryWeapon", ...]` | yes | 20 000 | §5.6 |
| `player.release` | `captorId` | yes | 10 000 | restore what `player.captive` stripped |
| `player.spawn` | `map`, `x`,`y`,`z`, `reason` | yes | 60 000 | the "always in raid" gesture: put the player *there*. On aowlspt this is `mods/autoraid` (integration TODO). |
| `quest.offer` | `id`, `title`, `brief`, `reward`, `giverId` | no | — | show it |
| `quest.update` | `id`, `status`, `objectives: [string]` | no | — | |
| `hud.note` | `text`, `severity: "info"\|"warn"` | no | — | a transient line on screen |
| `world.saved` | `version: int` | no | — | diagnostics only |
| `directive.acked` | `seq`, `kind`, `ok`, `note` | no | — | echo of your own ack; ignore |
| `directive.dropped` | `seq`, `kind`, `reason` | no | — | **you missed one.** Log it loudly. |

### 5.6 Captivity, concretely

On `player.captive`: remove the equipment in `stripSlots` to a holding
container the client owns (do **not** destroy it — `player.release` must put it
back), and start enforcing `leashM` from the captor's position. The client owns
the enforcement because a frame-accurate leash cannot live in an HTTP backend;
the backend independently re-checks from `player_moved`, so the two must agree
about `leashM`. When the player breaks the leash, send `escape_attempt` and let
the backend decide the consequence — **the client does not decide.**

---

## 6. Who is the player talking to

**Exactly one person answers.** A push-to-talk final is a question put to the
addressee, and the reply -- the brain turn -- belongs to them alone. Anyone else
within `hearSpeakM` of the player may throw in ONE short bark from the
ontology's `bystander` table, with probability `bystanderReactChance` (0.3) and
a 20 s cooldown; every one of those carries `reaction: true`. A client can
therefore separate the answer from the murmuring without heuristics -- the reply
is the non-`reaction` segment from the person it addressed.


The backend supplies the population; the client picks the addressee. It is the
client's decision because only the client knows the camera.

1. `GET /world/people?map=<map>&near=<x>,<y>,<z>&radius=<m>` →
   `{"ok":true,"people":[{"id","name","factionId","role","voice","map","x","y","z","activity","alive","attitude"}]}`.
   Call it on `raid_started` and then no more than once every 10 s, or when a
   `group.spawn` lands.
2. Maintain the mapping `personId → live bot` yourself. A person the backend
   lists that you have not spawned is not addressable; say so in
   `player_seen` by simply not sending it.
3. **The addressee is: the nearest person that is (a) `alive`, (b) within
   `noticeM` (default 25 m, sent in `/status.encounter.noticeM`), and (c)
   inside the view cone — within 35° of the camera forward vector.** Distance
   is 3-D world distance in metres.
4. Ties are broken by the smaller angle to the camera forward, then by the
   lower `personId` string, so the choice is deterministic and reproducible in
   a bug report.
5. **If nothing qualifies, do not open a speech session at all.** Show "nobody
   is listening". Do not pick the nearest person regardless of the cone — that
   produces the single most confusing behaviour available here, an NPC behind a
   wall answering.
6. Once a session is open, the addressee is **latched** for that utterance even
   if the player turns away. Re-evaluate only on the next key press.
7. The client tells the backend who it picked by including
   `"personId": "<id>"` in the FIRST `/speech/chunk` of a session (seq 0).
   Changing it mid-session is refused.

---

## 7. Playing `say` segments

A single NPC reply arrives as **several `say` events**, one per sentence, each
with an increasing `segmentIdx`, the last carrying `final:true`. This exists so
the first sentence is audible while the model is still writing the last.

* **Play in `seq` order. Do NOT wait for `final`.** Waiting for `final`
  discards the entire benefit and adds seconds of silence to every line.
* Maintain **one playback queue per `personId`**. Enqueue on arrival, play
  back-to-back with no gap. Two different people may speak concurrently.
* `wav` may be `""` — TTS is off, missing, or failed. Then the `text` is all
  you get: show it as a subtitle. **Never substitute a beep or silently drop
  the line.**
* `wav` is an absolute path on the backend machine. Same-machine clients read
  it directly. A remote client must fetch it (route TBD — no such route exists
  today; say so rather than assuming one).
* If `segmentIdx` arrives out of order, hold it briefly rather than playing it
  early; if the gap does not fill within 2 s, play what you have and log the
  gap. Segments are lost only if the ring overflowed, which §4's `firstSeq`
  already tells you about.
* If a NEW utterance starts for the same person (a `say` with
  `segmentIdx == 0`) while the queue is still playing, **flush the queue** —
  the world moved on.

### 7.1 Hearing: `distanceM`, `mode`, `audible`

The user, 2026-09-07: *"everyone in the vicinity replies even if I can't hear
their reply -- that's not good"*, and *"only talk when they are in distance, or
have a way to YELL"*. Every `say` segment now carries the backend's answer to
"could the player have heard that", and the client obeys it.

| field | meaning |
|---|---|
| `distanceM` | speaker to player, in metres, from the last distance THIS CLIENT reported (`player_seen.distanceM`, `player_aimed_at.distanceM`, or `npc_moved` against `player_moved`). **`-1` means nobody has reported one**; the backend then treats the line as audible and says so in `hearingNote`. `-1` is not "far". |
| `mode` | `"speak"` within `hearSpeakM` (25 m default); `"yell"` within `hearYellM` (70 m); `"mutter"` an aside within ~6 m that was not addressed to the player |
| `audible` | `false` only ever appears on a segment kept for the record. **Do not play it and do not subtitle it.** In practice the backend does not emit those at all -- it journals `say.suppressed` instead -- so a client that ignores `audible` is wrong but not loud. |
| `reaction` | `true` = a short bark from someone who merely OVERHEARD the player. Not a reply. See section 6. |
| `hearSpeakM` / `hearYellM` | the ranges in force, so the client can size its rolloff without a second config of its own |
| `hearingNote` | the sentence saying which band it fell in and why. Log it when something surprises you; never parse it. |

**A `yell` is REWRITTEN, not amplified.** The backend replaced the line with its
shouted form before synthesis -- the ontology row's `yell` variant when the
table has one, otherwise the first sentence, shortened and upper-cased -- and
set `voiceSpec.yell = true` so a TTS engine that can shout does. The client must
**not** upper-case anything itself. What it should do:

* `maxDistance = max(hearYellM, 40)` on the AudioSource for a yell. At the
  default 40 m rolloff, a shout the backend sent for a 60 m gap is inaudible on
  arrival: the same bug in the other direction.
* louder: `Basement.Client` plays `speak` at volume 0.5 and `yell` at 1.0
  (exactly +6 dB) with pitch 1.06, and `mutter` at 0.3. That is on top of
  whatever the engine did, and is meant to be -- a recorded shout played at
  conversational volume still sounds like a conversation.

**Subtitle only what you played.** `Basement.Client` drops `audible:false` at
the queue, so every subtitle it draws is a line the player could hear.

### 7.2 Proactive speech

People also speak when nobody asked them to. Each trigger is rate-limited per
person, gated by the same hearing rules, and every line comes from the `barks`
table in `data/ontology.json` -- never from code, and never from the LLM.

| trigger | when | example (neutral) |
|---|---|---|
| `first_sight` | the first time this raid that person sees the player | "You there. You alive, or just walking?" |
| `approach` | the player closes 10 m or more within 3 s | "Keep coming, then. Slowly." |
| `push` | the player closes 15 m or more within 3 s (a sprint) inside `hearYellM` | "WALK IT IN!" |
| `linger` | the player stays within 8 m for 10 s without talking | "Well? You came over here for something." |
| `hurt` | that person is shot | "What in hell was that for?" |
| `saw_death` | someone dies within 30 m of them | "Who did that?" |
| `combat_taunt` | every 8-15 s while fighting, yelled | "I SEE YOU MOVING!" |
| `bystander` | they overheard the player address somebody else | "Mm-hm." (`reaction:true`) |

`chatterLevel` is 0 off / 1 normal / 2 talkative (every gap halved), and each
trigger has its own switch in the backend's `config.json`.

---

## 8. Startup and re-sync, in order

1. `GET /status`. If `enabled:false`, do nothing and say why on screen.
2. `GET /world`. No world yet → `POST /world/new {preset, seed?}`.
3. `GET /world/people` for the current map.
4. Set the cursor: a stored one if `>= firstSeq - 1`, otherwise `latestSeq`.
5. `POST /observe {kind:"raid_started", ...}`.
6. Start the long poll and the 1 Hz `tick`.

On any error: keep polling. The backend is allowed to be restarted underneath
you; a `firstSeq` that jumps backwards to a small number means exactly that,
and step 2–4 is the recovery.

---

## 9. What this document does NOT settle

* **No route serves wav bytes over HTTP.** Remote playback is unspecified.
* **`group.spawn` has no proven actuator.** The SAIN driver does not move live
  bots yet (fact #227); `mods/morebots` / the emulator's `bot/generate` is the
  candidate on aowlspt and is contract-only.
* **`player.spawn` has no wiring**: `autoraid` does not consume
  `basement.raid.request` yet.
* **Microphone capture is entirely the client's problem.** On the IL2CPP client
  the game holds the microphone exclusively — that is why EFMB shipped a
  standalone winmm recorder exe, and it is still the fallback.
* Nothing in §5 has been executed by any client. Every `ack` semantic here is a
  decision, not a measurement.
