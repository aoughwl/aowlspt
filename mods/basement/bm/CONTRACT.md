# bm/ module contract — what each module EXPORTS, so they can be built in parallel

Rules every module obeys (nimony, mod = DLL):

* **Globals are literal-initialised only** (`var g: string = ""`), filled at
  run time. nimony silently zeroes a DLL global whose initialiser is a call.
* No `std/tables`, no `std/json`, no `std/times`, no `std/random`, no
  exceptions as control flow. Use parallel `seq`s, `aowlspt/json` (reader:
  `field`, `asText`, `asInt`, `asFloat`, `asBool`, `each`, `keys`, `child`,
  `whole`, `parseObject`/`Doc`, `parseArray`/`List`) and `aowlspt/server`
  (writer: `obj()`, `put`, `arr()`, `add`, `done`, `.text`, `jstr`).
  `std/strutils`, `std/syncio`, `std/envvars`, `std/osproc` are used by
  other mods and are known to work.
* Time is `nowMs()` from `aowlspt` (ms since host start) — for wall-clock
  persistence the world keeps its own `clockMs` advanced by the sim; util
  offers `wallMs()` (see below) for cache TTLs.
* Every proc that can fail returns a note or a bool; nothing throws across a
  route. A failure path logs at `warn` with a sentence a person can act on.
* Cross-module imports are RELATIVE within `bm/` only (`import util`,
  `import world`). NOTHING outside `mods/basement/`.
* Only `basement.nim` (the root) calls `route`/`serve`, `on`, `every`,
  `exportMod`. bm/ modules are pure library code plus `storeGet/storeSet`.

## bm/util.nim  (owner: agent A)

```nim
type RunResult* = object
  code*: int; output*: string; failed*: bool
proc runCmd*(command: string; input: string = ""): RunResult   # execCmdEx wrapper
proc spawnDetached*(exe, args: string): bool      # PowerShell Start-Process, no handle inheritance
proc quoteArg*(s: string): string                 # "…" with inner quotes escaped
proc psQuote*(s: string): string                  # '…' for PowerShell
proc exists*(path: string): bool
proc readAll*(path: string): string               # "" when missing
proc writeAll*(path, content: string): bool
proc appendAll*(path, content: string): bool
proc sizeOfFile*(path: string): int               # -1 when missing
proc joinPath*(a, b: string): string
proc ensureDir*(path: string): bool
proc baseName*(path: string): string
proc wallMs*(): int64                             # epoch ms (via PowerShell once + nowMs delta, or std if available; say which)
proc fnv1a64*(s: string): uint64
proc hex64*(v: uint64): string                    # 16 hex chars
proc normalizeText*(s: string): string            # lower, collapse space, strip punctuation
proc oneLine*(s: string): string
proc splitSentences*(s: string): seq[string]      # ". ! ?" boundaries, keeps punctuation, drops empties
proc stripTags*(s: string; tags: var seq[string]): string   # removes [TAG: …]/[TAG] lines, returns them
proc clampF*(v, lo, hi: float): float
proc clampI*(v, lo, hi: int): int
proc containsWord*(hay, needle: string): bool     # whole-word, case-insensitive
```

## bm/rng.nim  (owner: agent A)

```nim
type Rng* = object
  state*: uint64
proc initRng*(seed: uint64): Rng                  # splitmix64
proc next*(r: var Rng): uint64
proc nextInt*(r: var Rng; lo, hi: int): int       # inclusive
proc nextFloat*(r: var Rng): float                # [0,1)
proc pick*(r: var Rng; items: seq[string]): string
proc shuffle*(r: var Rng; items: var seq[string])
proc seedFromText*(s: string): uint64             # fnv1a64
```

## bm/world.nim  (owner: agent A)  — the model, JSON (de)serialisation, store

Entity kinds exactly as DESIGN.md §3. Parallel seqs, one `find<Kind>(id): int`
(-1 when absent) and one `add<Kind>(...)`/`<kind>Json(i): JsonObject` per kind.

```nim
# world meta
proc worldExists*(): bool
proc worldSeed*(): uint64;  proc worldPreset*(): string;  proc worldPrompt*(): string
proc worldName*(): string;  proc worldClockMs*(): int64;  proc worldVersion*(): int
proc setWorldMeta*(seed: uint64; preset, prompt, name: string; clockMs: int64)
proc advanceClock*(ms: int64)
proc resetWorld*()                                # empties every kind

# factions
proc factionCount*(): int;  proc findFaction*(id: string): int
proc addFaction*(id, name, creed, colour, homeMap: string; strength: float): int
proc factionName*(i: int): string;  proc factionCreed*(i: int): string
proc factionHomeMap*(i: int): string
proc factionRep*(i: int): int;  proc setFactionRep*(i: int; v: int)   # clamped -100..100
proc stance*(a, b: int): string;  proc setStance*(a, b: int; s: string)  # symmetric; allied|neutral|rival|war
proc factionWants*(i: int): seq[string];  proc addFactionWant*(i: int; w: string)
proc factionForbids*(i: int): seq[string]; proc addFactionForbid*(i: int; w: string)

# people
proc personCount*(): int;  proc findPerson*(id: string): int
proc addPerson*(id, name, factionId, role, voice, map, placeId: string;
                x, y, z: float; traits: seq[string]): int
proc personName*(i: int): string;  proc personFaction*(i: int): string
proc personRole*(i: int): string;  proc personVoice*(i: int): string
proc personTraits*(i: int): seq[string]
proc personMap*(i: int): string;  proc personPlace*(i: int): string
proc personPos*(i: int; x, y, z: var float)
proc setPersonPos*(i: int; map, placeId: string; x, y, z: float)
proc personActivity*(i: int): string;  proc setPersonActivity*(i: int; a: string)
proc personAlive*(i: int): bool;  proc setPersonAlive*(i: int; v: bool)
proc personHp*(i: int): float;  proc setPersonHp*(i: int; v: float)
proc personMood*(i: int): float;  proc setPersonMood*(i: int; v: float)
proc personAttitude*(i: int): int;  proc setPersonAttitude*(i: int; v: int)  # clamped
proc personGroup*(i: int): string;  proc setPersonGroup*(i: int; g: string)
proc personEscorting*(i: int): bool;  proc setPersonEscorting*(i: int; v: bool)
proc personInventoryNote*(i: int): string;  proc setPersonInventoryNote*(i: int; s: string)
proc remember*(i: int; line: string)              # bounded 48; oldest dropped
proc memoryOf*(i: int; last: int): string         # newline-joined tail
proc memoryLines*(i: int): int
proc personKnows*(i: int): seq[string];  proc addPersonKnows*(i: int; factId: string)
proc personLastSeenMs*(i: int): int64;  proc setPersonLastSeenMs*(i: int; v: int64)
proc peopleNear*(map: string; x, y, z, radius: float): seq[int]   # alive only
proc peopleOfFaction*(fi: int): seq[int]
proc peopleOfGroup*(g: string): seq[int]

# places
proc placeCount*(): int;  proc findPlace*(id: string): int
proc addPlace*(id, name, map, kind, ownerFactionId: string; x, y, z, danger: float): int
proc placeName*(i: int): string;  proc placeMap*(i: int): string;  proc placeKind*(i: int): string
proc placeOwner*(i: int): string;  proc setPlaceOwner*(i: int; f: string)
proc placePos*(i: int; x, y, z: var float);  proc placeDanger*(i: int): float
proc placesOnMap*(map: string): seq[int]

# contracts
proc contractCount*(): int;  proc findContract*(id: string): int
proc addContract*(id, kind, partyA, partyB, terms, stakes: string; expiresMs: int64): int
proc contractKind*(i: int): string;  proc contractPartyA*(i: int): string
proc contractPartyB*(i: int): string;  proc contractTerms*(i: int): string
proc contractStatus*(i: int): string;  proc setContractStatus*(i: int; s: string)
proc contractExpiresMs*(i: int): int64;  proc contractStakes*(i: int): string
proc contractsOf*(party: string; status: string = ""): seq[int]   # "" = any status
proc activeContractOfKind*(kind, party: string): int             # -1 when none

# quests
proc questCount*(): int;  proc findQuest*(id: string): int
proc addQuest*(id, giverId, title, brief, kind, targetRef, reward: string;
               objectives: seq[string]): int
proc questTitle*(i: int): string;  proc questGiver*(i: int): string
proc questStatus*(i: int): string;  proc setQuestStatus*(i: int; s: string)
proc questBrief*(i: int): string;  proc questReward*(i: int): string
proc questsOf*(giverId: string): seq[int]

# facts (world knowledge, retrievable) -- {id, tags, text}
proc factCount*(): int;  proc addFact*(id, tags, text: string)
proc retrieveFacts*(query, tags: string; limit: int; hitIds: var string): string
   # keyword overlap, query weighted 3:1 over tags; returns "- text\n" lines

# journal
proc journal*(kind, actorId, targetId, dataJson: string): int     # returns seq
proc journalCount*(): int
proc journalTail*(n: int): JsonArray

# player
proc playerPos*(map: var string; x, y, z: var float)
proc setPlayerPos*(map: string; x, y, z: float)
proc playerHp*(): float;  proc setPlayerHp*(v: float)

# whole-world JSON
proc worldJson*(): JsonObject          # everything, deterministic key order
proc factionJson*(i: int): JsonObject; proc personJson*(i: int): JsonObject
proc placeJson*(i: int): JsonObject;   proc contractJson*(i: int): JsonObject
proc questJson*(i: int): JsonObject

# persistence (store keys world.meta, world.factions, world.people,
# world.places, world.contracts, world.quests, world.facts, world.journal.<n>)
proc saveWorld*(note: var string): bool           # bumps version; note names keys written
proc loadWorld*(note: var string): bool           # false when no world.meta; note names problems
proc loadKindFromJson*(kind, text: string; note: var string): bool   # exposed for the corrupt-document selfcheck
proc kindJsonText*(kind: string): string          # the document saveWorld writes for one kind
```

## bm/gen.nim  (owner: agent A)

```nim
type Preset* = object
  id*, name*, worldPrompt*, tone*: string
  rules*, archetypes*, maps*: seq[string]
  factionCount*, peoplePerFaction*: int
  ok*: bool; note*: string
proc parsePreset*(text: string): Preset
proc presetFromFile*(path: string): Preset
proc listPresets*(dir: string): seq[Preset]        # reads data/presets/*.json (dir listing via PowerShell or std/dirs)
proc generate*(seed: uint64; p: Preset; worldPromptOverride: string; note: var string): bool
   # resets the world and fills every kind deterministically; note = summary counts
```
Data: `data/presets/{warlords,quiet_apocalypse,cult_of_the_reactor,the_long_road,sandbox}.json`,
`data/names.json` (`{"first":[...],"last":[...],"callsigns":[...],"factionWords":[...]}` ≥ 60 each),
`data/archetypes.json` (`militia|cult|traders|raiders|hermits|convoy|resistance|slavers`:
creed template, roles distribution, wants, forbids, default stance bias).

## bm/sim.nim  (owner: agent A)

```nim
proc simAdvance*(ms: int64; note: var string): int
   # moves people between places by activity + rng(seed, clock), drifts stances,
   # schedules ambushes near dangerous places when the player is near,
   # expires contracts, heals/wounds; returns the number of changes; journals each
proc simCatchUp*(note: var string): int             # advance by (wallMs - lastSavedWallMs), capped at simMaxCatchUpMs
proc simPendingAmbush*(factionId: var string; count: var int; near: var string): bool  # pop one
proc setSimConfig*(maxCatchUpMs: int64; moveEveryMs: int64; ambushChance: float)
```

## bm/prompt.nim  (owner: agent B)

```nim
type PersonCard* = object      # plain strings so brain/prompt never import world
  id*, name*, faction*, factionCreed*, role*, voice*, traits*, wants*, forbids*: string
  attitude*, factionRep*: int; mood*: float; inventoryNote*: string
  placeName*, map*: string
type Situation* = object
  state*: string               # encounter state name
  playerArmed*, playerAiming*: bool
  distanceM*: float; playerHp*, npcHp*: float; groupSize*: int
  timeOfDay*: string; recentEvents*: string     # newline list, newest last
proc situationSignature*(s: Situation): string   # coarse: state|armed|near/mid/far|day
proc stablePrefix*(worldPrompt, rules: string; c: PersonCard): string   # byte-stable per person; includes the tag grammar
proc volatileSuffix*(c: PersonCard; s: Situation; memory, facts, utterance: string): string
proc tagGrammar*(): string
proc knownTags*(): seq[string]
```

## bm/ontology.nim  (owner: agent B) — data/ontology.json

```nim
proc ontologyLoad*(text: string; note: var string): bool    # intents + templates
proc classifyIntent*(utterance: string; confidence: var float): string
proc stanceBucket*(attitude, factionRep: int): string       # hostile|wary|neutral|warm|loyal
proc ontologyReply*(intent: string; c: PersonCard; s: Situation; reply: var string; tags: var seq[string]): bool
   # false when no row; fills slots {name} {faction} {want} {place}
proc ontologyIntentCount*(): int;  proc ontologyRowCount*(): int
```

## bm/llm.nim  (owner: agent B)

```nim
type LlmProbe* = object
  engine*, path*, model*, note*: string; ok*: bool
proc llmConfigure*(engine, anthropicModel, openAiModel, llamaExe, llamaModel, curlExe, workDir: string; maxTokens: int)
proc llmProbe*(): LlmProbe
type SegmentSink* = proc (sentence: string; final: bool) {.closure.}
proc llmComplete*(system, user: string; sink: SegmentSink; note: var string;
                  cacheRead: var int; stopReason: var string): string
   # streams sentences to sink as they complete (anthropic SSE via curl -N to a file, polled by
   # reading the growing file; other engines call sink once per sentence after completion);
   # returns the full text; cacheRead = usage.cache_read_input_tokens when reported, -1 otherwise
proc llmEngine*(): string
```

## bm/brain.nim  (owner: agent B)

```nim
type Decision* = object
  text*: string; tags*: seq[string]; tier*: string   # cache|ontology|llm|builtin
  cached*: bool; engine*: string; ms*: int64; notes*: seq[string]; segments*: seq[string]
proc brainConfigure*(cacheDir: string; cacheMax: int; memoryTurns: int; ontologyMinConfidence: float)
proc brainLoadCache*(note: var string)
proc decide*(worldPrompt, rules: string; c: PersonCard; s: Situation;
             memory, facts, utterance: string; sink: SegmentSink): Decision
proc brainStats*(): JsonObject     # hits, misses, entries, tier histogram, last cacheRead
proc brainCacheClear*()
```
`decide` order: cache → ontology (confidence ≥ min) → llm (engine ≠ builtin) →
builtin (ontology fallback row). Tags parsed with `util.stripTags`; unknown
tags dropped and noted. Text never contains a tag. `sink` receives each
sentence (cache hits replay their sentences through the sink too).

## bm/speech.nim  (owner: agent C)

```nim
type SpeechProbe* = object
  slot*, engine*, path*, model*, note*: string; ok*: bool
proc speechConfigure*(sttEngine, ttsEngine, toolsDir, whisperExe, whisperModel, piperExe,
                      piperVoice, curlExe, workDir, cacheDir: string; whisperPort, sttPartialMs: int)
proc sttProbe*(): SpeechProbe;  proc ttsProbe*(): SpeechProbe
proc ttsSegment*(voice, sentence: string; note: var string; cached: var bool): string   # wav path or ""
proc ttsStats*(): JsonObject
proc sttSessionChunk*(session: string; seq: int; wavPath, wavBase64: string; final: bool;
                      partial: var string; finalText: var string; note: var string): bool
   # appends PCM to the session buffer (a 16k mono wav on disk; base64 decoded here);
   # every sttPartialMs of new audio runs whisper and sets partial; final runs once more, sets finalText, closes the session
proc sttSessionCount*(): int
proc voiceToPiperModel*(voice: string): string    # maps a person's voice tag to a .onnx path (default voice when unknown)
```

## bm/stream.nim  (owner: agent C)

```nim
proc streamConfigure*(maxEvents: int; defaultTtlMs: int64)
proc emitEvent*(kind, json: string; needsAck: bool; ttlMs: int64 = 0): int   # returns seq
proc eventsSince*(since: int; limit: int): JsonArray     # each {seq, atMs, kind, data}
proc latestSeq*(): int
proc ackEvent*(seq: int; ok: bool; note: string): bool   # false when not pending
proc pendingAcks*(): JsonArray
proc expirePending*(nowMs: int64; dropped: var seq[int]): int   # called from the tick; journals via a callback set below
type DropSink* = proc (seq: int; kind: string) {.closure.}
proc setDropSink*(s: DropSink)
proc setPushSession*(session: string)     # when known, emitEvent also notifyPush()es
proc pushSession*(): string
proc streamStats*(): JsonObject
proc streamSnapshotJson*(): string;  proc streamRestore*(text: string): int   # tail persisted with the world
```

## bm/encounter.nim  (owner: agent D) — uses world, stream, prompt types

```nim
proc encounterConfigure*(leashM: float; noticeM: float; threatM: float)
proc encounterState*(personId: string): string
proc observe*(kind, actorId, targetId, dataJson: string; note: var string): int   # returns directives emitted
proc applyTags*(personId: string; tags: seq[string]; note: var string): int      # tag -> state/contract/directive
proc situationFor*(personId: string): Situation
proc cardFor*(personId: string): PersonCard
proc encounterJson*(): JsonArray
```

## basement.nim  (owner: agent D) — routes as DESIGN.md §8, config.json, settings schema, selfcheck.

---

# GROUNDING additions (DESIGN.md §11, added 2026-09-06) — owner: agent E, after integration

## bm/world.nim additions

```nim
# caches
proc cacheCount*(): int;  proc findCache*(id: string): int
proc addCache*(id, name, placeId, map, ownerFactionId, guardGroupId, story, plantedBy: string;
               x, y, z: float): int
proc cacheName*(i: int): string;  proc cachePlace*(i: int): string;  proc cacheMap*(i: int): string
proc cacheOwner*(i: int): string;  proc cacheGuardGroup*(i: int): string;  proc cacheStory*(i: int): string
proc cacheStatus*(i: int): string;  proc setCacheStatus*(i: int; s: string)   # rumoured|intact|looted|moved
proc cachePos*(i: int; x, y, z: var float)
proc cacheAddItem*(i: int; tpl: string; count: int)
proc cacheItems*(i: int): seq[(string, int)]        # (tpl, count) -- or two parallel getters if tuples misbehave in nimony
proc cacheKnownBy*(i: int): seq[string];  proc addCacheKnownBy*(i: int; personId: string)
proc cachesOnMap*(map: string): seq[int];  proc cachesNear*(map: string; x, y, z, radius: float): seq[int]
proc cacheJson*(i: int): JsonObject

# loose loot items (planted, not inside a cache, or the expansion of a cache)
proc lootCount*(): int;  proc findLoot*(id: string): int
proc addLoot*(id, cacheId, tpl, map: string; count: int; x, y, z: float): int
proc lootStatus*(i: int): string;  proc setLootStatus*(i: int; s: string)   # placed|taken|gone
proc lootOnMap*(map: string): seq[int];  proc lootOfCache*(cacheId: string): seq[int]
proc lootJson*(i: int): JsonObject

# facts gain a reference and an origin
proc addFactRef*(id, tags, text, refKind, refId, origin: string)   # origin gen|plant|rumour|outcome
proc factRef*(i: int; refKind, refId: var string);  proc factOrigin*(i: int): string
proc factsAbout*(refKind, refId: string): seq[int]
proc factText*(i: int): string;  proc factId*(i: int): string

# pickup contracts: kind "pickup", partyA = cacheId, partyB = bearer personId, terms = token
proc addPickupContract*(id, cacheId, bearerId, token: string; expiresMs: int64): int
proc pickupsAt*(cacheId: string): seq[int]

# knowledge is entity ids; the prompt renders them
proc renderKnown*(personIdx: int; limit: int): string   # "[cache:c17 \"the Quarry crates\" -- intact, 3 guards]\n[place:p4 ...]" ...
proc worldHasId*(id: string): bool                     # any kind; the §9 check 11 assertion uses it
```
Persistence: two new kinds `world.caches`, `world.loot`; `worldJson` includes them; save/load byte-identity extends to them.

## bm/items.nim (new)

```nim
proc itemsConfigure*(lootKindsJson: string)            # data/lootkinds.json
proc itemsIndexReady*(): bool                          # false on the sim / no db
proc itemsIndexBuild*(note: var string): int           # dbKeys("templates.items") + per-item _name/_parent reads; NEVER dbRead the whole table
proc resolveItems*(text: string; r: var Rng; tpls: var seq[string]; counts: var seq[int]; note: var string): int
   # "a crate of 5.45 and two AKs" -> resolved templates; unresolved words listed in note; 0 + INCONCLUSIVE note when no index
proc itemName*(tpl: string): string
```

## bm/gen.nim additions
`generate` also creates 1-3 caches per faction (kind word from archetype wants), each with a story, a guard group (2-4 people, role guard), `knownBy` = the owning faction's leader + lieutenants + 1 random outsider, one rumour fact per cache (`origin: gen`, refKind cache), and one `pickup` contract per faction with a generated bearer and token (a passphrase from data/names.json callsigns).

## bm/sim.nim additions
`simAdvance` spreads rumours: each step, every person with a `knows` entry whose fact has `spreadMs` older than N tells one group-mate (adds the id to their knows, journals `rumour.spread`); a `looted` cache produces an `outcome` fact for its owner faction within one step.

## bm/prompt.nim / bm/ontology.nim / bm/brain.nim additions
* `PersonCard.known: string` (from `renderKnown`) rendered under `What you know (refer to these by name):` in the STABLE prefix ONLY if it does not change per turn — it does (knowledge grows), so put it at the top of the VOLATILE suffix instead, and say why in a comment.
* Tags added to the grammar and to `knownTags`: `PLANT`, `REVEAL`, `EXPECT`, `CLAIM_OK`, `CLAIM_FAIL` (the last two are emitted by the encounter machine, never by the LLM; strip them if the LLM produces them).
* Intent `claim` in ontology.json (patterns: "i am X", "X sent me", "i'm here for the", "kostya sent", "the password is", ...).

## bm/encounter.nim additions
```nim
proc applyPlant*(speakerId, spec: string; note: var string): string      # returns the new cacheId or ""
proc resolveClaim*(personId, utterance: string; note: var string): bool   # believability roll; journals claim.ok / claim.fail with the score parts
proc sceneJson*(map: string; x, y, z, radius: float): JsonObject          # people, caches, loot + the directives (group.spawn, loot.spawn) to build them; marks materialised
proc observeLootTaken*(cacheId, itemId, by: string; note: var string)
```
New observe kinds: `loot.taken {cacheId?, itemId, by}`, `scene.built {sceneId}`. New directives: `loot.spawn {items:[...]}`, `npc.give`, `npc.stand_down`.

## basement.nim additions
Routes `GET /aowlspt/basement/world/scene?map=&x=&y=&z=&radius=`, `GET /aowlspt/basement/world/loot?map=`, `GET /aowlspt/basement/world/caches`. Bus: subscribe `tarkov.loot.compose` → emit `tarkov.loot.plant` with `lootOnMap(map)` (status placed) inside the handler; subscribe `tarkov.bots.compose` → emit `tarkov.bots.plant` with guard groups on that map; subscribe `tarkov.loot.taken` → `observeLootTaken`. Selfcheck items 9-11 of DESIGN §11.
