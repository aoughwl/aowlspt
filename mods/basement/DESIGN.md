# aowl.basement — Escape From My Basement, the always-in-raid RPG backend

**Status: being built 2026-09-06. Nothing here has touched a running game.**
Every claim below is either MEASURED (with the command), DERIVED (from a file
named here), or DESIGN (a decision). Read §9 before trusting anything.

---

## 0. The one-paragraph idea

Tarkov stops being an extraction game. There is no main menu, no stash, no
loadout screen: you are **always in a world**, and the world is a persistent
place full of people who keep living while you are gone. Every world is
generated from a seed and a **world prompt**; factions, who runs what, who
hates whom, what people want from you are all different each time. People
(NPCs) talk — real speech in, real speech out — remember you, make deals,
jump you, rob you, hire you, take you prisoner and march you across the map,
and are exactly where they were doing what they were doing when you come
back. The entire brain lives in the backend, written in nimony, and is
**engine-agnostic**: the game client (the aowlspt IL2CPP host, or a BepInEx
plugin on SPT 4.1.5) is a thin bridge that reports facts and executes
directives. That bridge is the LAST thing to build; everything else is
provable today with `aowlspt-sim` and `curl`.

## 1. Lineage — what exists and what this reuses

| Thing | Where | Status | Used how |
|---|---|---|---|
| `EscapeFromMyBasement` (C#, SPT 4.1.2 scaffold + Mono BepInEx voice client) | `C:\Users\savant\Projects\EscapeFromMyBasement` | dead client (pre-1.0 Mono), scaffold server | the voice pipeline PATTERN, the `[OBJ:]` tag grammar, the name |
| `mods/voice` (`aowl.voice`) | this repo | Phase 2 partial, default OFF, no game bridge | its engine helpers (`runCmd`, `spawnDetached`, curl-as-HTTP-client), cache design and radio routing were the prototype. **`aowl.basement` is self-contained** — the import audit (`modbuild.py --audit-imports`) forbids importing another mod's files, so the small helpers are copied, not imported. `aowl.voice` stays as-is. |
| `mods/autoraid` | this repo | PROVEN 2026-09-05: `--raid Woods` enters a raid and exits it with no mouse, 9/9 entries | the aowlspt "always in raid" actuator. `aowl.basement` emits `basement.raid.request {map, spawn}`; autoraid is the client-side mechanism (integration TODO, §8). |
| `mods/sain` + `docs/BOT_AI_OBJECTIVES.md` | this repo | driver does not yet actuate live bots (fact #227) | the bot-side actuator for directives like `follow`, `hold`, `attack`. Contract only (§6). |
| Speech assets (whisper.cpp server, piper, winmm recorder) | `D:/SPT/BepInEx/plugins/EscapeFromMyBasement/tools` | MEASURED present 2026-08-22 (DESIGN.md of aowl.voice §1.4) | STT / TTS engines |
| LLM | none local. `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` **unset** (MEASURED 2026-09-06, `[Environment]::GetEnvironmentVariable` User+Machine); no `.gguf` on C: or D: | the `builtin` tier answers everything offline; `anthropic` is the real engine when a key exists |

## 2. Architecture

```
   game client (aowlspt host bridge | SPT 4.1.5 BepInEx plugin)  == THIN, LAST
        |  facts in:   POST /aowlspt/basement/observe   {kind, actor, ...}
        |  speech in:  POST /aowlspt/basement/speech/chunk (progressive wav)
        |  directives: GET  /aowlspt/basement/events?since=N&wait=ms  (long-poll)
        |              + notifyPush() over the game websocket when the host has it
        v
 +---------------------------------------------------------------------+
 | mods/basement  (aowl.basement, sides = {sideServer}, nimony)         |
 |                                                                      |
 |  bm/util.nim      subprocess, files, json helpers, hashing, time     |
 |  bm/rng.nim       splitmix64, seeded, deterministic                  |
 |  bm/world.nim     the model + persistence (store) + journal          |
 |  bm/gen.nim       seed + preset -> factions, people, places, rumours |
 |  bm/sim.nim       the clock: people move, factions drift, catch-up   |
 |  bm/encounter.nim the interaction state machine (deal/captive/...)   |
 |  bm/prompt.nim    presets, prompt assembly (STABLE prefix / suffix)  |
 |  bm/ontology.nim  intents, stances, rule-based replies (tier 1)      |
 |  bm/llm.nim       engines: builtin | anthropic | openai | llamacpp   |
 |  bm/brain.nim     decide(): cache -> ontology -> LLM; tag parsing    |
 |  bm/speech.nim    STT (progressive) + TTS (per-sentence, cached)     |
 |  bm/stream.nim    event log, cursor, long-poll, push                 |
 |  basement.nim     routes, config, settings schema, selfcheck         |
 +---------------------------------------------------------------------+
        |               |                 |
   whisper-server    piper.exe        curl.exe -> api.anthropic.com
```

**Rule:** everything expensive, stateful, or likely to be wrong lives here,
where a mistake is a bad HTTP response and not a crashed raid. The client
never reasons; it reports facts and executes directives.

## 3. The model (`bm/world.nim`)

Parallel `seq`s per entity kind (nimony idiom used by every mod here; no
`std/tables`). Every entity has a stable string id. Everything serialises to
JSON through `aowlspt/json` (reader) and `aowlspt/server` (writer).

```
World     { seed:uint64, presetId, worldPrompt, name, createdMs, clockMs,
            day, weatherNote, version:int }
Faction   { id, name, creed, colour, homeMap, strength 0..1,
            stance[otherFactionId] in {allied, neutral, rival, war},
            playerRep -100..100, wants: seq[string], forbids: seq[string] }
Person    { id, name, factionId, role (leader|lieutenant|grunt|trader|medic|
            scout|hermit|slaver|prisoner), traits: seq[string], voice,
            map, placeId, x,y,z, activity (idle|patrol|trade|sleep|hunt|
            travel|guard|captive_escort), alive, hp 0..1, mood -1..1,
            attitude toward player -100..100, memory: seq[string] (bounded),
            knows: seq[string] (fact ids), inventoryNote, lastSeenMs,
            groupId (people who move together), escortingPlayer:bool }
Place     { id, name, map, x,y,z, kind (camp|market|outpost|ruin|cache|
            checkpoint|hideout), ownerFactionId, danger 0..1 }
Contract  { id, kind (deal|debt|bounty|escort|captivity|employment|truce),
            partyA (person or faction id), partyB ("player" or id),
            terms: string, status (offered|active|fulfilled|broken|expired),
            expiresMs, stakes: string }
Quest     { id, giverId, title, brief, kind (fetch|kill|escort|deliver|
            find|survive), targetRef, reward, status (offered|active|done|
            failed), objectives: seq[string] }
Event     { seq:int, atMs, kind, actorId, targetId, data: json text }  -- the journal
```

**Persistence** (`storeSet`/`storeGet`, key = `world.<kind>` one JSON
document per kind plus `world.meta`; the journal is appended to
`world.journal.<n>` chunks of 500 events). A save is atomic per key; a torn
process leaves the previous document. `world.meta.version` is bumped on every
save and read back on load — a load that reads a version older than the last
save it wrote prints a WARNING naming both numbers (that is the check that
can fail). `GET /aowlspt/basement/world` returns the whole state; **the
selfcheck asserts that saving then loading yields byte-identical JSON** for
each kind, and that a deliberately corrupted document loads as an empty kind
with a reported error rather than a crash.

## 4. Generation (`bm/gen.nim`) and the world prompt (`bm/prompt.nim`)

A **preset** is a JSON file under `data/presets/`:

```json
{ "id": "warlords", "name": "Warlords of Tarkov",
  "worldPrompt": "…free text the player edits: what this world IS…",
  "rules": ["no faction is friendly at start", "slavery exists", "..."],
  "factionCount": 4, "peoplePerFaction": 6, "tone": "grim",
  "archetypes": ["militia", "cult", "traders", "raiders"],
  "maps": ["Woods", "Customs", "Interchange"] }
```

Presets shipped (fun, distinct): `warlords` (four armed gangs, land grabs,
enslavement is a real outcome), `quiet_apocalypse` (few people, mostly
traders and hermits, scarcity, deals matter), `cult_of_the_reactor`
(one cult, one resistance, conversions and rescues), `the_long_road`
(convoys and escorts, everything is about travel), `sandbox` (neutral
everything, for testing). The user picks one or writes their own;
`worldPrompt` is the top of every LLM system prompt.

`gen.generate(seed, preset)` is **deterministic**: same seed + same preset →
byte-identical world (the selfcheck asserts this, and asserts that two
different seeds differ). It builds factions from archetypes, names people
from `data/names.json`, places from the preset's maps, initial stances (at
least one `war` pair when the preset has 3+ factions), 2–3 rumours per
faction that seed quests, and a few open contracts (a bounty, a debt).

**Prompt assembly** produces two strings so provider prompt caching works:

* `stablePrefix(world, faction, person)` — world prompt, rules, the faction
  card, the person card (persona, traits, voice, what they want), the tag
  grammar. Byte-stable across turns for the same person: NO timestamps, NO
  counters. This block carries `cache_control` on the `anthropic` engine.
* `volatileSuffix(person, situation, memory, retrievedFacts, utterance)` —
  changes every turn.

### The tag grammar (the LLM's only actuator)

The reply may end with tags on their own lines. Parsed and stripped before
TTS; unknown tags are stripped and logged, never spoken.

```
[MOOD: -1..1]                       [ATTITUDE: +N | -N]
[OFFER: <terms>]                    [ACCEPT] [REFUSE]
[DEMAND: <item or act> | <or else>] [GIVE: <item>] [TAKE: <item>]
[CAPTURE]      -- take the player prisoner (needs the encounter to allow it)
[RELEASE]      [FOLLOW_ME]  [FOLLOW_YOU]  [STAY]  [LEAVE]
[ATTACK]       [STAND_DOWN]
[QUEST: <title> | <brief> | <reward>]   [QUEST_DONE: <id>]
[REMEMBER: <one line>]              [RUMOUR: <one line>]
[CALL: <personId>]  -- summon a group member / radio
[OBJ: …] [ADD: …] [CLEAR]          -- EFMB's originals, kept
```

## 5. The BRAIN (`bm/brain.nim`) — three tiers, cheap first

`decide(personId, situation, utterance) -> Decision{text, tags, tier, cached,
ms, notes}`. A `situation` is a small struct the encounter machine fills:
`{encounterState, playerArmed, playerAiming, distanceM, playerHp, npcHp,
groupSize, timeOfDay, recentEvents}`. Its **signature** is a coarse string
(`state|armed|near|day`) so the cache matches "the same kind of moment".

0. **Line cache** (`data/cache/brain.json` + wavs): key = hash(personId,
   normalized utterance, situation signature, engine, voice). HIT returns
   text + wav, no LLM, no TTS. Bounded LRU, persisted, hits/misses reported
   on `/status`. It is keyed WITHOUT memory on purpose (repeated stateless
   lines), and the status text says so.
1. **Ontology** (`bm/ontology.nim`, `data/ontology.json`): classify the
   utterance into an **intent** (greet, threaten, plead, offer_trade,
   accept, refuse, ask_help, ask_quest, ask_directions, insult, surrender,
   demand, smalltalk, unknown) by keyword/regex-lite patterns; combine with
   the person's stance (attitude bucket × faction rep bucket × role) to pick
   a **response template** with slots (`{name}`, `{faction}`, `{want}`,
   `{place}`) and a fixed tag set. Deterministic, sub-millisecond, no
   tokens. Used when the intent is confident (score above threshold) AND the
   stance table has a row; otherwise falls through. Every ontology reply is
   marked `tier:"ontology"` so nobody mistakes it for a model. This is what
   "aoughwl ontology" concretely is here: a typed intent × stance × role
   table with effects, in data, and it must NOT be described as a graph
   or as reasoning.
2. **LLM** (`bm/llm.nim`): engines by config string.
   * `builtin` — the ontology's fallback row; explicitly labelled "not a
     language model" in every note. Default, because nothing else works on
     this machine today.
   * `anthropic` — `curl.exe` POST `https://api.anthropic.com/v1/messages`,
     headers `x-api-key: $ANTHROPIC_API_KEY`, `anthropic-version:
     2023-06-01`; body: `model` (config `anthropicModel`, default
     `claude-opus-5`), `max_tokens` (config, default 200), `system: [{type:
     text, text: <stablePrefix>, cache_control: {type: ephemeral}}]`,
     `messages: [{role: user, content: <volatileSuffix>}]`,
     `output_config: {effort: "low"}` (a 1–3 sentence spoken line does not
     need deep thinking), `stream: true`. **Streaming:** curl `-N` writes SSE
     to a file; the engine parses `content_block_delta` `text_delta` events
     as they land and hands each completed SENTENCE to `speech.ttsSegment`
     and to `stream.emit("say.segment")` — so the first sentence is spoken
     before the last is generated. `usage.cache_read_input_tokens` is
     recorded per call and reported on `/status.llm` so a zero across
     repeated calls is visible (a silent invalidator). Key from env ONLY.
     Fallback: `stop_reason: "refusal"` → the ontology row, note says so.
   * `openai` — kept from aowl.voice, non-streaming, key from env only.
   * `llamacpp` — `<llamaExe> -m <gguf> -p … -n …`; probes as missing.

Every `Decision` carries `tier`, `cached`, `engine`, `ms` and `notes`. A
turn that falls all the way to `builtin` says so.

**Token budget:** memory fed to the LLM is the last `maxTurns` lines
(default 8) plus `[REMEMBER:]` lines the person chose to keep (bounded 24);
retrieved facts are top-4 by keyword overlap (utterance weighted 3:1 over
the person's tags, the fix aowl.voice measured).

## 6. Encounters (`bm/encounter.nim`) — "all the way"

State machine per (person or group, player):

```
none -> noticed -> hailed -> talking -> {dealing, threatened, fighting}
threatened -> {robbed, captive, fighting, escaped}
captive -> escorted -> {released, sold, escaped, dead}
dealing -> {deal_struck, refused}
talking -> parted
```

Inputs are **facts the client reports** (`/observe`):
`player_seen {personId, distanceM}`, `player_aimed_at {personId}`,
`player_fired {at}`, `player_lowered_weapon`, `player_spoke {text|wav}`,
`player_hit {by, hp}`, `npc_died {personId, by}`, `player_died {by}`,
`player_moved {map, x,y,z}`, `player_gave {personId, item}`,
`player_took {item}`, `player_extracted`, `raid_started {map}`,
`raid_ended`, `tick {nowMs}`.

Outputs are **directives** on the event stream, each with a `seq`, an
`ack` requirement and a `ttlMs`:
`say {personId, text, wav, segmentIdx, final}`, `npc.stance {personId,
hostile|neutral|friendly}`, `npc.follow {personId, target: player|personId}`,
`npc.hold {personId}`, `npc.goto {personId, x,y,z}`, `npc.attack {personId}`,
`npc.give {personId, item}`, `npc.take {personId, item}`,
`player.captive {captorId, allowedActions: [...], escortTo: placeId}`,
`player.release`, `player.spawn {map, x,y,z, reason}` (the "always in raid"
gesture), `group.spawn {factionId, count, near}`, `quest.offer`,
`quest.update`, `hud.note {text}`, `world.saved {version}`.

**Captivity** ("they may enforce your enslavement"): a `[CAPTURE]` tag or
`threatened` + `player_lowered_weapon` with a slaver-role captor opens a
`captivity` contract. Directive `player.captive` tells the client to strip
the weapon slots the contract names, and to keep the player within `leashM`
of the captor's group (the client enforces; the backend re-checks from
`player_moved`, and a leash break is `escape_attempt` which the machine
resolves by captor attitude and group size). The group's `activity` becomes
`captive_escort` toward `escortTo`; the sim moves the whole group; arriving
resolves to `released`, `sold` (a new captor from another faction; a new
contract) or a `deal` (work off the debt: a `quest`). Every transition
writes a journal event, and the person's memory gets a `[REMEMBER:]` line.

**Being jumped:** the sim schedules an `ambush` when the player's reported
position is within a hostile faction's place `danger` radius; the directive
is `group.spawn` (the client actually spawns bots; on aowlspt that is
`mods/morebots` / the emulator's `bot/generate`, contract only) followed by
`say` from the leader and state `threatened`.

## 7. Speech (`bm/speech.nim`) and the stream (`bm/stream.nim`)

* **STT, progressive.** The client posts 16 kHz mono PCM chunks
  (`/speech/chunk {sessionId, seq, wavBase64|path, final}`); the backend
  appends to a per-session wav and, every `sttPartialMs` (default 1200 ms)
  of new audio, runs whisper on the whole buffer and emits `heard.partial
  {text}`; on `final` it runs once more and emits `heard.final`, which is
  what feeds the brain. A partial is never fed to the brain (measured in
  aowl.voice: whisper's partials are unstable). If whisper is missing the
  chunk route says so and `heard.*` is never emitted — INCONCLUSIVE, not a
  silent nothing.
* **TTS, per sentence, cached.** `ttsSegment(voice, sentence) -> wav path`;
  cache key = hash(engine, voice, normalized sentence), `data/cache/tts/`.
  A cached sentence costs 0 ms. The brain's streaming path calls it per
  sentence, so the client receives `say` segments in order and plays them
  back-to-back. Engines: `piper`, `sapi`, `none`.
* **The stream** is an in-memory ring (`streamMax`, default 2048) of
  `{seq, atMs, kind, json}` with a monotonic `seq`, persisted tail on save.
  `GET /events?since=N&wait=MS` long-polls up to `wait` (max 25 s) using
  the backend's tick (`everyMs`) — no thread is blocked; the route returns
  immediately with `[]` if `wait` is 0. When `notifyReady()` and a game
  session is known, each event is ALSO pushed with `notifyPush(session,
  json)`; the client may use either. Directives that need an ack keep a
  `pending` list; `POST /ack {seq, ok, note}` clears them and an un-acked
  directive past its `ttlMs` is journaled as `directive.dropped` — the
  failure path announces itself.

## 8. Routes

| Route | Body | Does |
|---|---|---|
| `GET /aowlspt/basement/status` | — | enabled, engines (resolved path, present/missing), world summary, cache tallies, llm cache_read counts, stream cursor, pending acks, `tier` histogram |
| `GET /aowlspt/basement/presets` | — | the shipped presets |
| `POST /aowlspt/basement/world/new` | `{preset, seed?, worldPrompt?}` | generate + save; returns the summary |
| `GET /aowlspt/basement/world` | — | full state |
| `GET /aowlspt/basement/world/people?map=&near=x,y,z&radius=` | — | who is where (what the client spawns) |
| `GET /aowlspt/basement/world/person/<id>` | — | one card incl. memory and contracts |
| `POST /aowlspt/basement/world/save` | — | force a save; returns version |
| `POST /aowlspt/basement/world/advance` | `{ms}` | run the sim forward (catch-up is automatic on load) |
| `POST /aowlspt/basement/observe` | `{kind, ...}` | a client fact (§6) |
| `POST /aowlspt/basement/say` | `{person, text, situation?}` | text in → decision → say segments (the shortest proof) |
| `POST /aowlspt/basement/speech/chunk` | `{session, seq, path|wavBase64, final}` | progressive STT |
| `GET /aowlspt/basement/events?since=&wait=` | — | the directive stream |
| `POST /aowlspt/basement/ack` | `{seq, ok, note}` | directive acknowledged |
| `GET /aowlspt/basement/spawn` | — | where the player should be next (`player.spawn` on demand) |
| `GET /aowlspt/basement/selfcheck` | — | the falsifiable checks (§9), PASS/FAIL/INCONCLUSIVE each |
| `GET /aowlspt/settings/aowl.basement` | — | the F12 schema |

Events emitted on the mod bus (for other mods): `basement.raid.request
{map, x,y,z}` (autoraid consumes — TODO), `basement.say`, `basement.directive`.
Consumed: `tarkov.raid.configured`, `tarkov.profile.listing` (to know the
session id for `notifyPush`).

## 9. Verification — checks that CAN fail

`/selfcheck` (and `tools/basement_check.py`, which runs the mod under
`aowlspt-sim --side server` with a scratch `--store`) asserts:

1. determinism: `generate(seed 7, warlords)` twice → identical JSON; seed 8 →
   differs in at least one person name (negative control).
2. persistence: save → load → identical per-kind JSON; corrupt one document
   → that kind loads empty with `notes` naming the key; others intact.
3. catch-up: advance 6 h → at least one person changed place; advance 0 →
   nothing changed (negative control).
4. brain tiers: the same line twice → second is `cached:true`; a clear
   `greet` → `tier:"ontology"`; a nonsense line with `builtin` → `tier:
   "builtin"` and the note "not a language model"; an `[ATTACK]` tag in a
   canned reply → the directive `npc.attack` appears on the stream with the
   next `seq`; an unknown tag `[FOO]` is stripped and NOT spoken.
5. encounter: `player_aimed_at` on a `grunt` of a `war` faction → state
   `threatened`; then `player_lowered_weapon` with a `slaver` captor →
   contract `captivity` active + directive `player.captive`; `player_moved`
   beyond leash → `escape_attempt` journaled; `player_fired` at the captor
   while captive → `fighting`.
6. stream: `since=N` returns only `seq > N`; `wait=0` returns at once; an
   un-acked directive past its ttl is journaled as dropped; `ack` clears.
7. engines: each probe prints an absolute path and present/missing;
   `anthropic` with no key probes **missing** and `say` never calls curl.
8. speech: with whisper present, a known wav transcribes to text containing
   an expected word (INCONCLUSIVE with a stated reason when the exe is
   missing, never PASS); TTS of one sentence twice → second is a cache hit
   with the same wav bytes.

Three outcomes everywhere. "Could not look" is INCONCLUSIVE.

## 10. What is NOT done (keep this list honest) — updated 2026-09-06 15:10

* **Nothing has run inside the game.** The aowlspt client half (`bridge/`)
  loads in the sim and refuses by name; it has never long-polled a real
  backend from inside the client, never played a wav, never armed autoraid.
  The host verbs it needs (`aowlspt.host::http`, `play_wav`, commit ac45f94)
  compiled only after seven `toCString` fixes and the host build was still
  queued when this was written. Flags `hostHttp`, `hostPlayWav`,
  `bridgeEnabled`, `enabled` are all default OFF.
* **No SPT 4.1.5 plugin exists** (`PORT-SPT415.md` is the plan).
* **No live LLM key on this machine**: `anthropic` is wired and probed,
  never exercised end-to-end; the `builtin` tier answers and says so.
* **The microphone is INCONCLUSIVE here** (`waveInGetNumDevs()==0`); PTT is
  proven up to "the recorder ran and reported NO_DEVICES".
* **Bot actuation** (`npc.follow/attack/goto`) is acked `ok:false` by the
  bridge; the SAIN driver does not yet move bots live (fact #227).
  `player_seen/aimed/moved` facts are stubs: no measured read path for the
  player's position/aim exists on the bus yet.
* **Captivity on aowlspt** is backend-enforced by contract; nothing strips a
  weapon slot in the live client yet.
* **Streaming is post-hoc**: the anthropic SSE parser hands sentences to the
  sink in order but only after curl exits (no threads in a mod).
* **Engine processes are unsupervised**: each offline check leaves a
  whisper-server behind (measured, four orphans in one afternoon).
* `/events?wait=` is a bounded poll on the request thread (no sleep/condvar
  in the mod SDK) and says so in every reply.

---

## 11. GROUNDING — everything anyone says is something that exists (added 2026-09-06, user)

The user's clarification: *"this entire system should be responsible for
everything, not just the bots — also loot in the world and why it exists…
stuff a bot is talking about is actually happening when I visit those
locations: there is a real weapons cache an NPC talks about, and bots
defending it for whatever reason; I can pretend to be the real person
picking it up; none of this is hard coded."*

So the backend owns the **truth of the world**, and the client renders it.
Three rules, each enforced by code, not by prompt hygiene:

1. **A person can only talk about entities the world holds.** The prompt's
   `Known facts:` block is built from `person.knows` = ids of real
   `Fact`/`Cache`/`Place`/`Person`/`Contract` rows, rendered with their
   ids (`[cache:c17 "the Quarry crates"]`). The LLM is told to refer to
   them by name; the ontology tier fills `{cache}`/`{place}` slots from the
   same rows. A reply that names an entity id the person does not know is
   NOT stripped (people lie) but is journaled `claim.unknown` so a lie is a
   deliberate fiction the world can later contradict, never an accident.
2. **A person can CREATE truth only through tags the world materialises.**
   `[PLANT: cache | <placeId or "near"> | <what, free text> | guarded by
   <factionId> x<n>]` makes a real `Cache` row with generated contents
   (resolved to item templates by the item resolver, below), a guard
   group, a `story` string (the "why it exists"), and adds it to the
   speaker's `knows`. `[REVEAL: <entityId>]` copies an existing id into the
   player's known-list and journals the disclosure. `[EXPECT: <cacheId> |
   bearer <personId> | token <passphrase or item tpl>]` opens a `pickup`
   contract: the cache's guards expect a specific bearer and a token.
3. **Every scene is materialised from state, and the outcome flows back.**
   `GET /aowlspt/basement/world/scene?map=&x=&y=&z=&radius=` returns what
   must exist around a point RIGHT NOW: people (with `groupId`, activity,
   stance to the player), caches (items + positions), planted loose loot,
   and the directives to build them (`group.spawn`, `loot.spawn`). The
   client reports `loot.taken {cacheId, by}`, `npc_died`, `player_seen`
   etc.; the sim marks the cache `looted`, the owning faction's `playerRep`
   moves, guards who saw it `remember`, a rumour fact is created
   ("someone hit the Quarry crates") and spreads along faction lines on the
   next sim step. That is how "the thing they talked about actually
   happened" closes the loop.

**Impersonation.** `player_spoke` whose intent classifies as `claim`
(`"I'm Vadim, Kostya sent me for the crates"`) resolves against active
`pickup` contracts at the encounter's place: the machine scores
believability = (bearer name mentioned) + (token spoken or `player_gave`
the token item) + faction rep bucket + guard role (a `grunt` is easier
than a `lieutenant`), rolled with the world rng. Success → guards
`stand down`, `[GIVE]` the cache, the REAL bearer's contract becomes
`broken` and that person gains a grudge (attitude −40, a `hunt` quest
against the player is offered to their faction). Failure → `threatened`.
Nothing about names, tokens or outcomes is hard coded: contracts are
generated by `gen` and by `[EXPECT:]`.

**New model rows** (`bm/world.nim`):

```
Cache { id, name, placeId, map, x,y,z, ownerFactionId, guardGroupId,
        items: seq[(tpl, count)], story, status (rumoured|intact|looted|moved),
        knownBy: seq[personId], plantedByPersonId, createdMs }
LootItem { id, cacheId ("" = loose), tpl, count, map, x,y,z, status }
Fact gains: refKind, refId (an entity a fact is ABOUT), origin (gen|plant|rumour|outcome), spreadMs
Contract gains kind `pickup` with fields bearerId, token, cacheId
```

**Item resolver** (`bm/items.nim`): free text → item templates. Reads
`dbRead("templates.items")` KEYS lazily on the backend (never the 41 MB
document as a whole — `dbKeys` + per-item `_name`/`_parent` reads), builds
a small class index (weapon, ammo, meds, food, armor, key, valuables) and
resolves "a crate of 5.45 and two AKs" → `[(tpl 5.45 BP, 300), (tpl AK-74N, 2)]`
with a note listing what it could not resolve. On the sim (no db) it
answers INCONCLUSIVE with an empty list and the scene still materialises
guards and the story. Everything else: `data/lootkinds.json` maps a cache
kind word (weapons|meds|food|valuables|keys|ammo) to class weights and
count ranges.

**Emulator integration (aowlspt side, `mods/tarkov`)** — two synchronous
bus round-trips, because `emit` returns no payload:

```
tarkov emits   tarkov.loot.compose {map, raidId}            (before it serves getLocalloot)
basement emits tarkov.loot.plant   {raidId, items:[{id,tpl,count,x,y,z,cacheId}]} from inside that handler
tarkov emits   tarkov.bots.compose {map, raidId, wave}      (before bot/generate answers)
basement emits tarkov.bots.plant   {raidId, groups:[{groupId, factionId, role, count, x,y,z, names[]}]}
tarkov emits   tarkov.loot.taken   {raidId, itemIds[]}       (from the raid-end profile diff)
```
`mods/tarkov` appends planted loose items to the served loose-loot array
and planted groups to the next bot waves; its selfcheck asserts a planted
item appears in the served payload at the planted position and that a run
with no planter changes nothing (negative control). On SPT 4.1.5 the
plugin does the same through `world/scene` (PORT-SPT415.md).

**Checks that can fail (added to §9):** 9. `[PLANT:]` in a reply creates a
Cache with ≥1 item (or an INCONCLUSIVE item note on the sim), a guard
group whose people exist, and adds the id to the speaker's `knows`;
`world/scene` at that place lists it; `loot.taken` flips it to `looted`
and a rumour fact appears with `origin: outcome`; a scene query at a
different map lists nothing from it (negative). 10. a `claim` naming the
expected bearer + token → guards `stand_down` + `npc.give` directive; the
same claim with the wrong token → `threatened`. 11. a person's prompt
`Known facts:` never names an id absent from the world (assert over every
person after generation).

## 12. THE OFFSCREEN WORLD (`bm/offscreen.nim`) — added 2026-09-07 (user)

> "make the mod do what it was fully intended with all the bots having their own
> full objectives, they interact with each other even if you are not there — the
> idea should be all of this happens in our backend so we can pretend or emulate
> regions that are not directly loaded."

**Objectives.** A GROUP (derived from `person.group`, never stored — a stored
roster can disagree with the people it claims) holds exactly one active
`Objective`: `kind` (patrol | guard | raid | trade | hunt | loot | escort |
rest | scout), `targetKind`/`target` (place | cache | person), `priority`,
`startedMs`/`untilMs`, `status`, and the planner's own reason in `note`. It is
a persisted world kind (`aowl.basement.objectives/1`); each person carries their
role inside it (`objRole`: leader | cover | carrier), which is an OPTIONAL field
on `people` and deliberately not a schema bump, so an older save still loads
whole. The planner is a ladder — a looted cache makes its owner hunt, dead
members plus a war stance make a raid, then live contracts, then quests, then
the faction's own `wants`, then somebody else's cache, then guard, then patrol,
then rest — and **no two groups of one faction may hold the identical target**,
asked of the objective table rather than of a flag.

**Resolution.** `offscreenStep` runs inside `simAdvance`'s loop (one clock, not
two): objectives expire, groups march toward their target at a speed per
activity, arrival resolves the objective, and two groups of different factions
within 60 m resolve an ENCOUNTER by STANCE — war fights, rival stands off (or
fights, 35 %), allied trades, neutral meets. A fight is decided by strength ×
numbers × condition with the rng as a rider, never as the verdict: 15 % of the
losing side die, 35 % are wounded, 12 % are taken captive, caches change owner,
bounties and quests naming the dead close, and the loser breaks off. A per-pair
**disengage window of 6 h** exists because without it the same two groups
re-fought every hour — MEASURED: 107 resolutions in 12 h, which depopulated the
world and broke two unrelated selfchecks by killing the people they addressed.

Every resolution journals `offscreen.fight` / `.trade` / `.meet` / `.loot` /
`.hunt` with a one-line narrative from the `offscreen` table in
`data/ontology.json` (a TABLE — a missing row is reported as missing, never
replaced by a sentence the code invented), and seeds exactly ONE fact with
`origin: "offscreen"`; `bm/sim.spreadRumours` carries it outward from there, so
there is one spreading rate, not two.

**Regions.** The map the player is raiding is FROZEN on `raid_started` and
thawed on `raid_ended` / `player_extracted`: the client is the truth for it and
both `bm/sim`'s person loop and this engine skip it BEFORE reading anything.
Every other map keeps running. `GET /aowlspt/basement/world/regions` reports
per map: state (frozen | emulated), the groups, each group's objective, and the
last thing that resolved there.

**Client-facing.** `world/scene` now carries every group on the map with its
objective, each person's `objective` (kind, target, role, sentence), corpses as
`loot.spawn` rows tagged with the dead person's `inventoryNote`, and one
`npc.goto` per bot toward the objective's target so a materialised group WALKS.
`/world/person/<id>` carries the same objective plus the `objective.*` journal
rows for their group. The ontology gained the `ask_activity` intent and a
`{objective}` slot, and the row is REFUSED for a person who has no objective
rather than served with an empty slot.

**Checks (CHECK 24-26).** (a) every group has an objective, none of one faction
collide, and the same seed twice produces a byte-identical objectives document;
(b) 12 h produces a resolution with a narrative and an `origin: offscreen`
rumour, with advance(0) as the negative control; (c) 6 h replayed from the same
generated state is a byte-identical journal; (d) with the player on one map,
that map's position signature is unchanged over 2 h while another map's changes;
(e) `world/regions` answers per map; (f) the scene carries a group objective and
an `npc.goto`; (g) asked "what are you doing" a person answers with their own
objective clause, and a person WITHOUT one is refused (the control).
