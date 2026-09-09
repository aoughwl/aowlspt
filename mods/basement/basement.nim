## aowl.basement — "Escape From My Basement": the always-in-raid RPG backend.
##
## Tarkov stops being an extraction game. There is one persistent WORLD,
## generated from a seed and a world prompt, full of people who keep living
## while the player is away — they talk, remember, deal, rob, hire, and take
## the player prisoner and march them across the map. The whole brain is here,
## in the backend, where a mistake is a bad HTTP response instead of a crashed
## raid; the game client is a thin bridge that reports facts and executes
## directives (`CLIENT-CONTRACT.md`).
##
##   POST /aowlspt/basement/world/new    generate a world from a preset + seed
##   POST /aowlspt/basement/observe      a fact the client saw
##   POST /aowlspt/basement/say          text in -> a decision -> spoken segments
##   GET  /aowlspt/basement/events       the directive stream the client obeys
##   GET  /aowlspt/basement/selfcheck    the nine falsifiable checks of §9
##
## Everything above is exercisable RIGHT NOW with `aowlspt-sim` and `curl`,
## with no game running — that was the point of putting it here.
##
## DEFAULT OFF. Turning it on lets this mod spawn whisper/piper subprocesses
## and (only when a key exists in the environment) call an HTTP API. Read
## `DESIGN.md` §10 for what is NOT done before believing anything works
## end-to-end: there is no client bridge yet, and there is no LLM key on this
## machine, so the default reasoning tier is `builtin`, which is a template
## responder and says so in every note it produces.

import std/[strutils, envvars]
import aowlspt
import aowlspt/server
import aowlspt/settings
import aowlspt/json as jr
import aowlspt/sync

import "bm" / util
import "bm" / rng
import "bm" / world
import "bm" / gen
import "bm" / items
import "bm" / sim
import "bm" / encounter
import "bm" / prompt
import "bm" / ontology
import "bm" / hearing
# --- offscreen begin ---
import "bm" / offscreen
# --- offscreen end ---
import "bm" / llm
import "bm" / brain
import "bm" / speech
import "bm" / stream
import "bridge" / bridge

const
  ModGuid = "aowl.basement"
  ModName = "Escape From My Basement"
  ModAuthor = "savannt"
  ModVersion = "0.1.0"

  Base           = "/aowlspt/basement"
  StatusRoute    = Base & "/status"
  PresetsRoute   = Base & "/presets"
  WorldNewRoute  = Base & "/world/new"
  WorldRoute     = Base & "/world"
  PeopleRoute    = Base & "/world/people"
  PersonRoute    = Base & "/world/person/"
  SaveRoute      = Base & "/world/save"
  AdvanceRoute   = Base & "/world/advance"
  ObserveRoute   = Base & "/observe"
  SayRoute       = Base & "/say"
  ChunkRoute     = Base & "/speech/chunk"
  PttRoute       = Base & "/speech/ptt"
  EventsRoute    = Base & "/events"
  AckRoute       = Base & "/ack"
  SpawnRoute     = Base & "/spawn"
  SptBotsRoute   = Base & "/spt/bots"     ## POST {map, raidId, wave, requested[]} -> the emulator's plant shape + limits
  SptWavesRoute  = Base & "/spt/waves"    ## GET ?map=&raidId= -> {ok, clear, waves[], bossWaves[]} (EFT-native rows)
  SceneRoute     = Base & "/world/scene"
  LootRoute      = Base & "/world/loot"
  CachesRoute    = Base & "/world/caches"
  # --- offscreen begin ---
  RegionsRoute   = Base & "/world/regions"
  # --- offscreen end ---
  SelfcheckRoute = Base & "/selfcheck"
  TickRoute      = Base & "/tick"

# ---------------------------------------------------------------------------
# Config. Literal initialisers only: nimony silently zeroes a DLL global whose
# initialiser is a call, and a mod is a DLL.
# ---------------------------------------------------------------------------

var gEnabled: bool = false
var gPreset: string = "warlords"
var gSeed: int = 0
var gWorldPromptOverride: string = ""
var gAutoRaid: bool = false
var gMaxWaitMs: int = 2000
var gTickMs: int = 1000
var gLoadNote: string = "not loaded"
var gWorldNote: string = "no world loaded"
var gPresetDir: string = ""
var gSaveEveryTicks: int = 60
var gTicks: int = 0
var gSegmentIdx: int = 0
var gSayPerson: string = ""
var gSayVoice: string = ""
var gSayWavs: seq[string] = @[]
var gSaySegments: seq[string] = @[]
var gDebugTickRoute: bool = false

# The last payloads this mod PUBLISHED on the bus. They are kept because the
# simulator does not deliver an emit back to the mod that made it (MEASURED in
# host/Aowlspt.Sim/aowlsim.nim `deliverEvent`), so the selfcheck cannot hear
# its own plant. It asserts over what was composed instead, and says plainly
# that the cross-mod half is unproven here.
var gLastLootPlant: string = ""
var gLastBotsPlant: string = ""
var gLootComposeN: int = 0
var gBotsComposeN: int = 0

proc presetDir(): string = joinPath(dataDir(), "presets")
proc defaultedPath(v, fallback: string): string =
  if v.len > 0: v else: fallback

proc joinWith(items: seq[string]; sep: string): string =
  ## nimony's strutils has no `join`.
  result = ""
  var i = 0
  while i < items.len:
    if result.len > 0: result.add sep
    result.add items[i]
    i = i + 1

proc minConfidenceFor(engine: string; configured: float): float =
  ## 0 in the config means AUTOMATIC, and automatic depends on the engine: the
  ## table is the only responder there is on `builtin`, so it must answer
  ## readily (0.6); with a real model behind it the table should only catch a
  ## dead-certain greeting (0.9) and hand everything else over. A value the
  ## player actually set is never overridden.
  if configured > 0.0: return configured
  if engine == "builtin" or engine == "none": return 0.6
  result = 0.9

proc loadConfig() =
  gEnabled = setting("enabled").asBool(false)
  gPreset = setting("preset").asText("warlords")
  gSeed = setting("seed").asInt(0)
  gWorldPromptOverride = setting("worldPrompt").asText("")
  gAutoRaid = setting("autoRaidRequests").asBool(false)
  gMaxWaitMs = setting("maxWaitMs").asInt(2000)
  gTickMs = setting("tickMs").asInt(1000)
  gSaveEveryTicks = setting("saveEveryTicks").asInt(60)
  gPresetDir = presetDir()

  encounterConfigure(leashM = setting("leashM").asFloat(25.0),
                     noticeM = setting("noticeM").asFloat(60.0),
                     threatM = setting("threatM").asFloat(18.0))
  encounterConfigureBarks(setting("barkCooldownMs").asInt(20000))
  # --- hearing (agent R) ----------------------------------------------------
  hearingConfigure(speakM = setting("hearSpeakM").asFloat(25.0),
                   yellM = setting("hearYellM").asFloat(70.0),
                   bystanderChance = setting("bystanderReactChance").asFloat(0.3),
                   chatterLevel = setting("chatterLevel").asInt(1),
                   bystanderCooldownMs = setting("bystanderCooldownMs").asInt(20000))
  # Written out one by one, NOT as a loop over TriggerNames: the build's
  # `every declared setting resolves to a key in its mod config.json` audit
  # reads `setting("literal")` and cannot follow a computed key -- a loop
  # compiles and then silently escapes the check that these keys exist.
  discard hearingConfigureTrigger("first_sight", setting("trigger_first_sight").asBool(true))
  discard hearingConfigureTrigger("approach", setting("trigger_approach").asBool(true))
  discard hearingConfigureTrigger("linger", setting("trigger_linger").asBool(true))
  discard hearingConfigureTrigger("hurt", setting("trigger_hurt").asBool(true))
  discard hearingConfigureTrigger("saw_death", setting("trigger_saw_death").asBool(true))
  discard hearingConfigureTrigger("combat_taunt", setting("trigger_combat_taunt").asBool(true))
  discard hearingConfigureTrigger("push", setting("trigger_push").asBool(true))
  discard hearingConfigureTrigger("bystander", setting("trigger_bystander").asBool(true))
  # --- end hearing ----------------------------------------------------------
  streamConfigure(maxEvents = setting("streamMax").asInt(2048),
                  defaultTtlMs = int64(setting("directiveTtlSeconds").asInt(30)) * 1000)
  setSimConfig(maxCatchUpMs = int64(setting("simMaxCatchUpHours").asInt(24)) * 3600000,
               moveEveryMs = int64(setting("simMoveEveryMinutes").asInt(20)) * 60000,
               ambushChance = setting("ambushChance").asFloat(0.15))

  let tools = setting("toolsDir").asText("")
  var work = setting("workDir").asText("")
  # Empty means %TEMP% (the config says so) -- and it must resolve to an
  # ABSOLUTE directory here, because the push-to-talk recorder is started by a
  # detached `cmd /c` whose working directory is not this process's.
  if work.len == 0: work = getEnv("TEMP", "")
  if work.len == 0: work = getEnv("TMP", "")
  if work.len == 0: work = joinPath(dataDir(), "work")
  var cache = setting("cacheDir").asText("")
  if cache.len == 0: cache = joinPath(dataDir(), "cache")
  llmConfigure(engine = setting("llmEngine").asText("builtin"),
               anthropicModel = setting("anthropicModel").asText("claude-opus-5"),
               openAiModel = setting("openAiModel").asText("gpt-4o-mini"),
               llamaExe = setting("llamaExe").asText(""),
               llamaModel = setting("llamaModel").asText(""),
               curlExe = setting("curlExe").asText("curl.exe"),
               workDir = work,
               maxTokens = setting("maxTokens").asInt(200))
  # Streaming is ON by default: a turn that answers 4 s after the player
  # stopped talking reads as a broken mod. `llmStreaming: false` restores the
  # synchronous shape byte for byte, which is what the deterministic checks
  # assert against.
  llmStreamingConfigure(streaming = setting("llmStreaming").asBool(true),
                        maxInFlight = setting("maxTurnsInFlight").asInt(4),
                        turnTimeoutMs = setting("turnTimeoutMs").asInt(60000),
                        fakeFile = setting("llmFakeStreamFile").asText(""),
                        fakeStall = setting("llmFakeStreamStall").asBool(false),
                        fakeChunkBytes = setting("llmFakeChunkBytes").asInt(240))
  gDebugTickRoute = setting("debugTickRoute").asBool(false)
  speechConfigure(sttEngine = setting("sttEngine").asText("whisper-server"),
                  ttsEngine = setting("ttsEngine").asText("piper"),
                  toolsDir = tools,
                  whisperExe = setting("whisperExe").asText(""),
                  whisperModel = setting("whisperModel").asText(""),
                  piperExe = setting("piperExe").asText(""),
                  piperVoice = setting("piperVoice").asText(""),
                  curlExe = setting("curlExe").asText("curl.exe"),
                  workDir = work,
                  cacheDir = cache,
                  whisperPort = setting("whisperPort").asInt(9000),
                  sttPartialMs = setting("sttPartialMs").asInt(1200),
                  kokoroUrl = setting("kokoroUrl").asText(""),
                  kokoroRoot = setting("kokoroRoot").asText(""),
                  kokoroExe = setting("kokoroExe").asText(""),
                  chatterboxUrl = setting("chatterboxUrl").asText(""),
                  chatterboxRoot = setting("chatterboxRoot").asText(""),
                  chatterboxExe = setting("chatterboxExe").asText(""),
                  voicesDir = defaultedPath(setting("voicesDir").asText(""),
                                            joinPath(dataDir(), "voices")),
                  localAppData = getEnv("LOCALAPPDATA", ""))
  llmConfigureOpenAi(baseUrl = setting("openAiBaseUrl").asText(""),
                     keyEnv = setting("openAiKeyEnv").asText(""),
                     extraJson = setting("openAiExtraJson").asText(""))
  speechConfigureCloud(sttBaseUrl = setting("sttBaseUrl").asText(""),
                       sttKeyEnv = setting("sttKeyEnv").asText(""),
                       sttModel = setting("sttModel").asText(""),
                       ttsBaseUrl = setting("ttsBaseUrl").asText(""),
                       ttsKeyEnv = setting("ttsKeyEnv").asText(""),
                       ttsModel = setting("ttsModel").asText(""))
  speechConfigureAsync(async = setting("ttsAsync").asBool(true),
                       timeoutMs = setting("ttsTimeoutMs").asInt(8000))
  spawnModeConfigure(setting("spawnMode").asText("process"))
  pttConfigure(recorderExe = setting("recorderExe").asText(""),
               maxSeconds = setting("pttMaxSeconds").asInt(20))
  brainConfigure(cacheDir = cache,
                 cacheMax = setting("cacheMaxEntries").asInt(512),
                 memoryTurns = setting("maxTurns").asInt(8),
                 ontologyMinConfidence = minConfidenceFor(
                   setting("llmEngine").asText("builtin"),
                   setting("ontologyMinConfidence").asFloat(0.0)))

var gTickMaxMs: int64 = 0
var gTickLastMs: int64 = 0
var gTickSlowN: int = 0        ## ticks over gTickSlowMs
var gTickSlowMs: int = 300
var gTickSlowest: string = "no tick has run yet"

proc tickTimingJson(): JsonObject =
  ## The one instrument that answers "did anything block the tick". A route
  ## cannot run while `onTick` holds the mod lock, so the LONGEST tick IS the
  ## worst latency a route could have suffered -- which is why this is measured
  ## here and not guessed at from a client-side stopwatch.
  result = obj()
  result.put("ticks", gTicks)
  result.put("lastMs", int(gTickLastMs))
  result.put("maxMs", int(gTickMaxMs))
  result.put("slowThresholdMs", gTickSlowMs)
  result.put("slowTicks", gTickSlowN)
  result.put("slowest", gTickSlowest)
  result.put("note", "maxMs is the longest single onTick since load. With " &
    "synthesis ON the tick it was ~1300 ms per kokoro sentence; the whole " &
    "point of ttsAsync is that this stays small while a turn streams")

proc disabledJson(): string =
  var o = obj()
  o.put("ok", false)
  o.put("err", "aowl.basement is disabled; set \"enabled\": true in " &
        "mods/basement/config.json (it is off by default because it spawns " &
        "subprocesses, writes a persistent world, and can call a paid API " &
        "when llmEngine is not builtin)")
  result = done(o).text

# ---------------------------------------------------------------------------
# World lifecycle
# ---------------------------------------------------------------------------

proc effectiveSeed(want: int): uint64 =
  ## `seed 0` means "pick one" — from the wall clock, so two worlds made a
  ## second apart differ, and the number that was actually used is stored in
  ## the world and reported by /status. A seed nobody can read back is not a
  ## seed, it is a coincidence.
  if want != 0: return uint64(want)
  result = seedFromText("basement." & $wallMs())

proc newWorld(presetId: string; seed: int; promptOverride: string;
              note: var string): bool =
  var p = presetFromFile(joinPath(gPresetDir, presetId & ".json"))
  if not p.ok:
    note = "preset '" & presetId & "' did not load from " & gPresetDir &
           ": " & p.note
    return false
  let s = effectiveSeed(seed)
  var genNote = ""
  if not generate(s, p, promptOverride, genNote):
    note = "generation failed: " & genNote
    return false
  resetEncounters()
  # --- offscreen begin ---
  # A generated world where nobody has anything to do is not a world. Planning
  # BEFORE the save means the objectives are in the store from version 1, so a
  # backend that never advances still answers "what are you doing".
  var planNote = ""
  discard planAll(planNote)
  # --- offscreen end ---
  var saveNote = ""
  discard saveWorld(saveNote)
  gWorldNote = "generated seed " & $int64(s) & " preset " & presetId &
               ": " & genNote & "; " & planNote
  note = gWorldNote & "; saved: " & saveNote
  result = true

proc worldSummary(): JsonObject =
  result = obj()
  result.put("exists", worldExists())
  result.put("name", worldName())
  result.put("seed", $worldSeed())
  result.put("preset", worldPreset())
  result.put("version", worldVersion())
  result.put("clockMs", int(worldClockMs()))
  result.put("factions", factionCount())
  result.put("people", personCount())
  result.put("places", placeCount())
  result.put("contracts", contractCount())
  result.put("quests", questCount())
  result.put("facts", factCount())
  result.put("journal", journalCount())
  result.put("encounters", encounterCount())
  # --- hearing (agent R) ----------------------------------------------------
  result.put("hearing", hearingJson())
  # --- end hearing ----------------------------------------------------------
  result.put("captiveOf", captiveOf())
  result.put("note", gWorldNote)

# ---------------------------------------------------------------------------
# say — card -> situation -> brain.decide, with a per-sentence sink that speaks
# and streams. This is the shortest end-to-end proof in the whole mod.
# ---------------------------------------------------------------------------

proc saySink(sentence: string; final: bool) =
  ## Called by the brain as each SENTENCE completes — during streaming, so the
  ## first sentence is spoken before the last is generated. Nothing is captured
  ## from the enclosing scope: the person and voice are module globals set just
  ## before `decide`, because a closure over locals in a DLL is a footgun this
  ## project does not need.
  if sentence.len == 0 and not final: return
  # QUEUED, not synthesised here. MEASURED 2026-09-07 on the live sidecar: this
  # line used to call `ttsSegment` -> curl -> kokoro, ~1.3 s per sentence,
  # INSIDE `onTick`'s `withModLock`; a five-sentence turn held the lock for
  # ~6 s and an `/events` long-poll timed out waiting for it. `sayEnqueue`
  # starts the request and returns; `sayDrain` emits the segment when the wav
  # lands, in order, from the tick.
  discard sayEnqueue(gSayPerson, gSayVoice, sentence, gSegmentIdx, final,
                     "brain", false)
  if sentence.len > 0:
    gSaySegments.add sentence
    # The wav is not known yet for kokoro/chatterbox. The /say RESPONSE
    # therefore reports "" for it and the `say` EVENT carries the real path --
    # said out loud in the reply's notes rather than left to look like a
    # failure.
    gSayWavs.add ""
  discard sayDrain()
  gSegmentIdx = gSegmentIdx + 1

proc sayReplyJson(personId: string; d: Decision; tagNote: string;
                  directives: int): string =
  var tags = arr()
  for t in d.tags: tags.add t
  var segs = arr()
  var i = 0
  while i < gSaySegments.len:
    var so = obj()
    so.put("text", gSaySegments[i])
    so.put("wav", (if i < gSayWavs.len: gSayWavs[i] else: ""))
    segs.add so
    i = i + 1
  var notes = arr()
  for n in d.notes: notes.add n
  if tagNote.len > 0: notes.add "tags: " & tagNote
  var o = obj()
  o.put("ok", true)
  o.put("personId", personId)
  o.put("text", d.text)
  o.put("tier", d.tier)
  o.put("cached", d.cached)
  o.put("engine", d.engine)
  o.put("ms", int(d.ms))
  o.put("tags", tags)
  o.put("segments", segs)
  o.put("directives", directives)
  o.put("streaming", d.streaming)
  o.put("turnId", d.turnId)
  o.put("state", encounterState(personId))
  o.put("notes", notes)
  result = done(o).text

# ---------------------------------------------------------------------------
# In-flight streaming turns: the speaking CONTEXT the sink needs
# ---------------------------------------------------------------------------
#
# `saySink` reads module globals rather than a closure (see its own comment),
# so a turn that finishes on a later tick has to have those globals put back
# the way they were when it started. That is all this table is: per turn, who
# is speaking, in which voice, and how many segments have already gone out.
# The tick restores one turn's context, pumps it, and saves it back -- so two
# people can be answering at once without their segment indices interleaving.

var gCtxId: seq[int] = @[]
var gCtxPerson: seq[string] = @[]
var gCtxVoice: seq[string] = @[]
var gCtxSeg: seq[int] = @[]
var gCtxSegs: seq[string] = @[]     ## "\x1f"-joined, empties KEPT
var gCtxWavs: seq[string] = @[]     ## "\x1f"-joined, empties KEPT (index-paired)
var gCtxUtt: seq[string] = @[]
var gTurnsFinished: int = 0

proc joinUs(items: seq[string]): string =
  result = ""
  var i = 0
  while i < items.len:
    if i > 0: result.add "\x1f"
    result.add items[i]
    i = i + 1

proc splitUs(s: string): seq[string] =
  ## Keeps empty fields, because `gSayWavs` is index-paired with the segments
  ## and a dropped empty would shift every wav onto the wrong sentence.
  result = @[]
  if s.len == 0: return
  var cur = ""
  for ch in s:
    if ch == '\x1f':
      result.add cur
      cur = ""
    else: cur.add ch
  result.add cur

proc findCtx(id: int): int =
  result = -1
  var i = 0
  while i < gCtxId.len:
    if gCtxId[i] == id: return i
    i = i + 1

proc ctxSave(idx: int) =
  gCtxSeg[idx] = gSegmentIdx
  gCtxSegs[idx] = joinUs(gSaySegments)
  gCtxWavs[idx] = joinUs(gSayWavs)

proc ctxRestore(idx: int) =
  gSayPerson = gCtxPerson[idx]
  gSayVoice = gCtxVoice[idx]
  gSegmentIdx = gCtxSeg[idx]
  gSaySegments = splitUs(gCtxSegs[idx])
  gSayWavs = splitUs(gCtxWavs[idx])

proc ctxDrop(idx: int) =
  if idx < 0 or idx >= gCtxId.len: return
  var a: seq[int] = @[]
  var b: seq[string] = @[]
  var c: seq[string] = @[]
  var d: seq[int] = @[]
  var e: seq[string] = @[]
  var f: seq[string] = @[]
  var g: seq[string] = @[]
  var i = 0
  while i < gCtxId.len:
    if i != idx:
      a.add gCtxId[i]
      b.add gCtxPerson[i]
      c.add gCtxVoice[i]
      d.add gCtxSeg[i]
      e.add gCtxSegs[i]
      f.add gCtxWavs[i]
      g.add gCtxUtt[i]
    i = i + 1
  gCtxId = a
  gCtxPerson = b
  gCtxVoice = c
  gCtxSeg = d
  gCtxSegs = e
  gCtxWavs = f
  gCtxUtt = g

proc finishStreamedTurn(idx: int; d: Decision) =
  ## What the synchronous path does at the end of `speakTurn`, done once the
  ## last sentence has actually been spoken: the reply goes into memory, the
  ## tags are applied ONCE, and a `turn.done` event tells the client the turn
  ## is over and what it cost.
  let personId = gCtxPerson[idx]
  let pi = findPerson(personId)
  if pi >= 0 and d.text.len > 0:
    remember(pi, personName(pi) & ": " & d.text)
  var tagNote = ""
  let directives = applyTags(personId, d.tags, tagNote)
  discard journal("said", personId, "player",
                  done(objOf("text", d.text)).text)
  var tagsA = arr()
  for t in d.tags: tagsA.add t
  var notesA = arr()
  for n in d.notes: notesA.add n
  if tagNote.len > 0: notesA.add "tags: " & tagNote
  var o = obj()
  o.put("turnId", d.turnId)
  o.put("personId", personId)
  o.put("text", d.text)
  o.put("tier", d.tier)
  o.put("engine", d.engine)
  o.put("ms", int(d.ms))
  o.put("segments", gSegmentIdx)
  o.put("tags", done(tagsA))
  o.put("directives", directives)
  o.put("notes", done(notesA))
  discard emitEvent("turn.done", done(o).text, false)
  gTurnsFinished = gTurnsFinished + 1

proc pumpStreamingTurns() =
  ## Every in-flight turn, once, on the caller's lock. The ids are snapshotted
  ## FIRST because a turn that finishes removes itself, and walking a shrinking
  ## list by index skips the turn that took its place.
  var ids: seq[int] = @[]
  var i = 0
  while i < brainStreamCount():
    ids.add brainStreamIdAt(i)
    i = i + 1
  for id in ids:
    let ci = findCtx(id)
    if ci < 0:
      # No context means nobody can be spoken for. Drain the turn with a nil
      # sink so it cannot sit in flight forever, and say so.
      var dd = Decision(text: "", tags: @[], tier: "", cached: false,
                        engine: "", ms: 0, notes: @[], segments: @[],
                        turnId: 0, streaming: false)
      var pn = ""
      if brainStreamPump(id, nil, dd, pn):
        warn ModName & ": streaming turn " & $id & " finished with no " &
             "speaking context; nothing was spoken (" & pn & ")"
      continue
    ctxRestore(ci)
    var d = Decision(text: "", tags: @[], tier: "", cached: false, engine: "",
                     ms: 0, notes: @[], segments: @[], turnId: 0,
                     streaming: false)
    var pnote = ""
    let finished = brainStreamPump(id, saySink, d, pnote)
    ctxSave(ci)
    if finished:
      finishStreamedTurn(ci, d)
      ctxDrop(ci)

proc speakTurn(personId, utterance: string; directives: var int;
               tagNote: var string): Decision =
  ## The one path. `/say` calls it; the selfcheck calls it; nothing else has a
  ## second copy of this order.
  ##
  ## An EMPTY utterance is REFUSED here, with the reason in `notes`, rather
  ## than handed to the brain. MEASURED 2026-09-07: push-to-talk `up` arrived
  ## before the recorder had written a byte, so the transcript was "" -- and a
  ## turn built from nothing produces the ontology's fallback row, which reads
  ## on screen as the person answering a question the player never asked. The
  ## refusal is the one route out; a silent empty Decision would be
  ## indistinguishable from "the brain had nothing to say".
  result = Decision(text: "", tags: @[], tier: "refused", cached: false,
                    engine: llmEngine(), ms: 0, notes: @[], segments: @[],
                    turnId: 0, streaming: false)
  directives = 0
  tagNote = ""
  if normalizeText(utterance).len == 0:
    result.notes.add "REFUSED: the utterance is empty after normalisation, " &
      "so the brain was not asked. Nothing was spoken and no directive was " &
      "emitted. With push-to-talk this means `up` arrived before the " &
      "recorder wrote any audio, or the transcript was blank -- GET " &
      StatusRoute & " and read `ptt` for the recorder's own account."
    return
  let pi = findPerson(personId)
  gSayPerson = personId
  gSayVoice = (if pi >= 0: personVoice(pi) else: "")
  gSegmentIdx = 0
  gSaySegments = @[]
  gSayWavs = @[]
  # --- hearing (agent R) ----------------------------------------------------
  # ONLY THE ADDRESSEE ANSWERS. Everyone else close enough to overhear may
  # throw in a short table bark, marked `reaction:true`; nobody else gets a
  # brain turn. See `encounter.bystanderReactions`.
  notePlayerSpokeTo(personId, wallMs())
  var bystNote = ""
  let bystDirs = bystanderReactions(personId, utterance, bystNote)
  # --- end hearing ----------------------------------------------------------
  let card = cardFor(personId)
  let situation = situationFor(personId)
  var hits = ""
  let facts = retrieveFacts(utterance, card.traits, 4, hits)
  let memory = (if pi >= 0: memoryOf(pi, 8) else: "")
  var streamed = false
  var turnId = 0
  result = decide(worldPrompt(), worldName(), card, situation,
                  memory, facts, utterance, saySink, streamed, turnId)
  if streamed:
    # The reply has not been generated yet. Everything the tail below does --
    # remembering the answer, applying the tags, journalling -- happens when
    # the LAST sentence has actually been spoken (`finishStreamedTurn`), NOT
    # here: applying a tag for a reply that has not arrived would act on a
    # sentence nobody said.
    if pi >= 0: remember(pi, "Player: " & utterance)
    # --- hearing (agent R) --------------------------------------------------
    directives = directives + bystDirs
    if bystNote.len > 0: result.notes.add bystNote
    # --- end hearing --------------------------------------------------------
    gCtxId.add turnId
    gCtxPerson.add personId
    gCtxVoice.add gSayVoice
    gCtxSeg.add gSegmentIdx
    gCtxSegs.add joinUs(gSaySegments)
    gCtxWavs.add joinUs(gSayWavs)
    gCtxUtt.add utterance
    return
  if pi >= 0:
    remember(pi, "Player: " & utterance)
    if result.text.len > 0: remember(pi, personName(pi) & ": " & result.text)
  directives = applyTags(personId, result.tags, tagNote)
  # --- hearing (agent R) ----------------------------------------------------
  directives = directives + bystDirs
  if bystNote.len > 0: result.notes.add bystNote
  # --- end hearing ----------------------------------------------------------
  discard journal("said", personId, "player",
                  done(objOf("text", result.text)).text)

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

proc queryOf(url: string): string =
  let q = find(url, "?")
  if q < 0: return ""
  result = url.substr(q + 1)

proc queryValue(url, key: string): string =
  result = ""
  for pair in queryOf(url).split('&'):
    let eq = find(pair, "=")
    if eq > 0 and pair.substr(0, eq - 1) == key:
      return pair.substr(eq + 1)

proc queryInt(url, key: string; default: int): int =
  let v = queryValue(url, key)
  if v.len == 0: return default
  var n = 0
  var any = 0
  for c in v:
    if c >= '0' and c <= '9':
      n = n * 10 + (int(c) - int('0'))
      any = 1
    else:
      break
  if any == 0: return default
  result = n

proc onStatus(url, body, session: string): string =
  var engines = arr()
  let lp = llmProbe()
  var lo = obj()
  lo.put("slot", "llm")
  lo.put("engine", lp.engine)
  lo.put("path", lp.path)
  lo.put("model", lp.model)
  lo.put("ok", lp.ok)
  lo.put("note", lp.note)
  engines.add lo
  for p in [sttProbe(), ttsProbe()]:
    var o = obj()
    o.put("slot", p.slot)
    o.put("engine", p.engine)
    o.put("path", p.path)
    o.put("model", p.model)
    o.put("ok", p.ok)
    o.put("note", p.note)
    engines.add o
  var o = obj()
  o.put("ok", true)
  o.put("schema", "aowlspt.basement.status/1")
  o.put("mod", ModGuid)
  o.put("version", ModVersion)
  o.put("enabled", gEnabled)
  o.put("dataLoad", gLoadNote)
  o.put("engines", engines)
  # Every one of these WALKS a global seq that the tick thread mutates, so they
  # are read under the mod lock for the same reason `/events` now is.
  withModLock:
    o.put("world", worldSummary())
    o.put("brain", brainStats())
    o.put("stream", llmStreamStats())
    o.put("stream", streamStats())
    o.put("tts", ttsStats())
    o.put("ttsAsync", ttsAsyncStats())
    o.put("tick", tickTimingJson())
    o.put("sttSessions", sttSessionCount())
    o.put("ptt", pttStatus())
    o.put("pushSession", pushSession())
    o.put("encounters", encounterJson())
  o.put("leashM", leashM())
  o.put("presetDir", gPresetDir)
  var io = obj()
  io.put("indexReady", itemsIndexReady())
  io.put("templates", itemsIndexSize())
  io.put("kinds", itemsKindCount())
  io.put("data", itemsDataNote())
  io.put("build", itemsBuildNote())
  o.put("items", io)
  var bo = obj()
  bo.put("lootComposes", gLootComposeN)
  bo.put("botsComposes", gBotsComposeN)
  bo.put("lastLootPlant", gLastLootPlant)
  bo.put("lastBotsPlant", gLastBotsPlant)
  o.put("bus", bo)
  result = done(o).text

proc onPresets(url, body, session: string): string =
  var a = arr()
  let items = listPresets(gPresetDir)
  for p in items:
    var o = obj()
    o.put("id", p.id)
    o.put("name", p.name)
    o.put("tone", p.tone)
    o.put("worldPrompt", p.worldPrompt)
    o.put("factionCount", p.factionCount)
    o.put("peoplePerFaction", p.peoplePerFaction)
    o.put("ok", p.ok)
    o.put("note", p.note)
    a.add o
  var root = obj()
  root.put("ok", items.len > 0)
  root.put("dir", gPresetDir)
  root.put("presets", a)
  if items.len == 0:
    root.put("err", "no presets under " & gPresetDir &
             " -- data/presets/*.json ships with the mod; an empty list here " &
             "means the data directory did not come along, not that there " &
             "are no presets")
  result = done(root).text

proc onWorldNew(url, body, session: string): string =
  if not gEnabled: return disabledJson()
  var presetId = jr.asText(jr.field(body, "preset"), gPreset)
  let seed = jr.asInt(jr.field(body, "seed"), gSeed)
  let po = jr.asText(jr.field(body, "worldPrompt"), gWorldPromptOverride)
  var note = ""
  var ok = false
  var o = obj()
  withModLock:
    ok = newWorld(presetId, seed, po, note)
    o.put("ok", ok)
    o.put("note", note)
    o.put("world", worldSummary())
  if not ok: o.put("err", note)
  result = done(o).text

proc onWorld(url, body, session: string): string =
  var o = obj()
  o.put("ok", worldExists())
  o.put("summary", worldSummary())
  o.put("world", worldJson())
  if not worldExists():
    o.put("err", "no world yet -- POST " & WorldNewRoute & " {\"preset\":\"" &
          gPreset & "\"}")
  result = done(o).text

proc onPeople(url, body, session: string): string =
  let map = queryValue(url, "map")
  let near = queryValue(url, "near")
  var radius = float(queryInt(url, "radius", 0))
  var x = 0.0
  var y = 0.0
  var z = 0.0
  var haveNear = false
  if near.len > 0:
    let bits = near.split(',')
    if bits.len >= 3:
      haveNear = true
      var n = 0
      for b in bits:
        var v = 0.0
        var neg = false
        var t = b
        if t.len > 0 and t[0] == '-':
          neg = true
          t = t.substr(1)
        var whole = 0.0
        var i = 0
        while i < t.len and t[i] >= '0' and t[i] <= '9':
          whole = whole * 10.0 + float(int(t[i]) - int('0'))
          i = i + 1
        v = (if neg: -whole else: whole)
        if n == 0: x = v
        elif n == 1: y = v
        elif n == 2: z = v
        n = n + 1
  var a = arr()
  var idx: seq[int] = @[]
  if haveNear:
    if radius <= 0.0: radius = noticeM()
    idx = peopleNear(map, x, y, z, radius)
  else:
    var i = 0
    while i < personCount():
      if map.len == 0 or personMap(i) == map: idx.add i
      i = i + 1
  for i in idx:
    var o = personJson(i)
    o.put("encounterState", encounterState(personId(i)))
    a.add o
  var root = obj()
  root.put("ok", true)
  root.put("map", map)
  root.put("near", near)
  root.put("radiusM", radius)
  root.put("count", a.len)
  root.put("people", a)
  result = done(root).text

proc onPerson(url, body, session: string): string =
  var id = pathAfter(url, PersonRoute)
  let q = find(id, "?")
  if q >= 0: id = id.substr(0, q - 1)
  let i = findPerson(id)
  if i < 0:
    return errJson("no person '" & id & "' in this world (" &
                   $personCount() & " people); GET " & PeopleRoute &
                   " for who is here")
  var contracts = arr()
  for ci in contractsOf(id, ""):
    contracts.add contractJson(ci)
  var quests = arr()
  for qi in questsOf(id):
    quests.add questJson(qi)
  let card = cardFor(id)
  var cardo = obj()
  cardo.put("name", card.name)
  cardo.put("faction", card.faction)
  cardo.put("creed", card.factionCreed)
  cardo.put("role", card.role)
  cardo.put("traits", card.traits)
  cardo.put("wants", card.wants)
  cardo.put("forbids", card.forbids)
  cardo.put("attitude", card.attitude)
  cardo.put("factionRep", card.factionRep)
  cardo.put("placeName", card.placeName)
  var o = obj()
  o.put("ok", true)
  o.put("person", personJson(i))
  o.put("card", cardo)
  o.put("memory", memoryOf(i, 24))
  o.put("memoryLines", memoryLines(i))
  o.put("encounterState", encounterState(id))
  o.put("contracts", contracts)
  o.put("quests", quests)
  # --- offscreen begin ---
  var okind = ""
  var otarget = ""
  var orole = ""
  if objectiveOfPerson(i, okind, otarget, orole):
    var oo = obj()
    oo.put("kind", okind)
    oo.put("target", otarget)
    oo.put("role", orole)
    oo.put("sentence", objectiveSentence(i))
    o.put("objective", oo)
  else:
    o.put("objective", raw("null"))
  # The objective rows in the journal tail, so a caller can see what this
  # person's group has been ordered to do and what came of it -- without
  # pulling the whole journal.
  var objRows = arr()
  for e in jr.each(jr.whole(done(journalTail(200)).text)):
    let jk = jr.asText(jr.child(e, "kind"), "")
    let ja = jr.asText(jr.child(e, "actor"), "")
    if ja == personGroup(i) and jk.len >= 9 and jk.substr(0, 8) == "objective":
      # rebuilt, not forwarded: the journal comes back as a READER handle
      # (JsonRef) and the response is a WRITER (JsonArray); they are different
      # types and mixing them is the type error this replaced.
      var jo = obj()
      jo.put("seq", jr.asInt(jr.child(e, "seq"), 0))
      jo.put("atMs", jr.asInt(jr.child(e, "atMs"), 0))
      jo.put("kind", jk)
      jo.put("actor", ja)
      jo.put("target", jr.asText(jr.child(e, "target"), ""))
      jo.put("data", jr.asText(jr.child(e, "data"), ""))
      objRows.add jo
  o.put("objectiveJournal", objRows)
  # --- offscreen end ---
  result = done(o).text

proc onSave(url, body, session: string): string =
  var note = ""
  var ok = false
  withModLock:
    ok = saveWorld(note)
  discard emitEvent("world.saved",
                    done(objOf("version", worldVersion())).text, false)
  var o = obj()
  o.put("ok", ok)
  o.put("version", worldVersion())
  o.put("note", note)
  result = done(o).text

proc onAdvance(url, body, session: string): string =
  if not gEnabled: return disabledJson()
  let ms = int64(jr.asInt(jr.field(body, "ms"), 0))
  var note = ""
  var changes = 0
  withModLock:
    changes = simAdvance(ms, note)
  var o = obj()
  o.put("ok", true)
  o.put("ms", int(ms))
  o.put("changes", changes)
  o.put("note", note)
  o.put("clockMs", int(worldClockMs()))
  result = done(o).text

proc onObserve(url, body, session: string): string =
  if not gEnabled: return disabledJson()
  let kind = jr.asText(jr.field(body, "kind"), "")
  if kind.len == 0:
    return errJson("no `kind` in the body; POST " & ObserveRoute &
                   " {\"kind\":\"player_aimed_at\",\"personId\":\"...\"}")
  let actor = jr.asText(jr.field(body, "actor"), jr.asText(jr.field(body, "actorId"), ""))
  let target = jr.asText(jr.field(body, "target"), jr.asText(jr.field(body, "targetId"), ""))
  var note = ""
  var emitted = 0
  let before = latestSeq()
  withModLock:
    emitted = observe(kind, actor, target, body, note)
  var o = obj()
  o.put("ok", true)
  o.put("kind", kind)
  o.put("directives", emitted)
  o.put("sinceSeq", before)
  o.put("latestSeq", latestSeq())
  o.put("note", note)
  o.put("encounters", encounterJson())
  result = done(o).text

proc onSay(url, body, session: string): string =
  if not gEnabled: return disabledJson()
  let personId = jr.asText(jr.field(body, "person"), "")
  let text = jr.asText(jr.field(body, "text"), "")
  if findPerson(personId) < 0:
    return errJson("no person '" & personId & "'; GET " & PeopleRoute &
                   " for who exists in this world")
  if text.len == 0:
    return errJson("no `text` in the body")
  var directives = 0
  var tagNote = ""
  var d = Decision(text: "", tags: @[], tier: "", cached: false, engine: "",
                   ms: 0, notes: @[], segments: @[], turnId: 0,
                   streaming: false)
  withModLock:
    d = speakTurn(personId, text, directives, tagNote)
  result = sayReplyJson(personId, d, tagNote, directives)

# The addressee of a CHUNK session. CLIENT-CONTRACT §6.7: the plugin sends
# `personId` on seq 0 ONLY, so it has to be remembered here -- the `final`
# chunk, which is the one that needs it, does not carry it. Before this, the
# chunk path emitted `heard.final` and stopped, and the SPT plugin worked
# around the gap by POSTing /say itself; the reply now carries `spokeTo`,
# which is the flag that makes the plugin skip that second call.
var gChunkSess: seq[string] = @[]
var gChunkPerson: seq[string] = @[]

proc chunkRemember(sess, personId: string) =
  if sess.len == 0 or personId.len == 0: return
  var i = 0
  while i < gChunkSess.len:
    if gChunkSess[i] == sess:
      gChunkPerson[i] = personId
      return
    i = i + 1
  gChunkSess.add sess
  gChunkPerson.add personId

proc chunkPersonOf(sess: string): string =
  result = ""
  var i = 0
  while i < gChunkSess.len:
    if gChunkSess[i] == sess: return gChunkPerson[i]
    i = i + 1

proc chunkForget(sess: string) =
  var a: seq[string] = @[]
  var b: seq[string] = @[]
  var i = 0
  while i < gChunkSess.len:
    if gChunkSess[i] != sess:
      a.add gChunkSess[i]
      b.add gChunkPerson[i]
    i = i + 1
  gChunkSess = a
  gChunkPerson = b

proc onChunk(url, body, session: string): string =
  if not gEnabled: return disabledJson()
  let sess = jr.asText(jr.field(body, "session"), session)
  let seqNo = jr.asInt(jr.field(body, "seq"), 0)
  let path = jr.asText(jr.field(body, "path"), "")
  let b64 = jr.asText(jr.field(body, "wavBase64"), "")
  let final = jr.asBool(jr.field(body, "final"), false)
  let claimed = jr.asText(jr.field(body, "personId"), "")
  var o = obj()
  if claimed.len > 0:
    if findPerson(claimed) < 0:
      o.put("addresseeNote", "the client named person '" & claimed &
            "' but no such person exists in this world; the session keeps " &
            "whatever addressee it already had")
    else:
      chunkRemember(sess, claimed)
  var partial = ""
  var finalText = ""
  var note = ""
  var ok = false
  withModLock:
    ok = sttSessionChunk(sess, seqNo, path, b64, final, partial, finalText, note)
  if partial.len > 0:
    discard emitEvent("heard.partial",
                      done(objOf("text", partial)).text, false)
  if finalText.len > 0:
    discard emitEvent("heard.final",
                      done(objOf("text", finalText)).text, false)
  o.put("ok", ok)
  o.put("session", sess)
  o.put("seq", seqNo)
  o.put("partial", partial)
  o.put("final", finalText)
  o.put("note", note)
  if final:
    # The SAME order `up` uses in onPtt, deliberately: one turn is started by
    # exactly one piece of code whichever way the audio arrived.
    var addressee = chunkPersonOf(sess)
    chunkForget(sess)
    if addressee.len == 0: addressee = captiveOf()
    if addressee.len == 0:
      o.put("spokeTo", "")
      o.put("sayNote", "nobody was addressed: the chunk session carried no " &
            "`personId` on seq 0 and the encounter machine holds no " &
            "captive/escorted person, so the brain was NOT asked. Send " &
            "personId with seq 0 (CLIENT-CONTRACT 6.7) or POST " & SayRoute)
    elif normalizeText(finalText).len == 0:
      o.put("spokeTo", "")
      o.put("sayNote", "'" & addressee & "' was addressed, but the " &
            "transcript is empty, so the brain was not asked with an empty " &
            "utterance -- a turn built from nothing answers a question the " &
            "player never asked")
    else:
      var directives = 0
      var tagNote = ""
      var d = Decision(text: "", tags: @[], tier: "", cached: false,
                       engine: "", ms: 0, notes: @[], segments: @[],
                       turnId: 0, streaming: false)
      withModLock:
        d = speakTurn(addressee, finalText, directives, tagNote)
      o.put("spokeTo", addressee)
      o.put("reply", d.text)
      o.put("tier", d.tier)
      o.put("turnId", d.turnId)
      o.put("streaming", d.streaming)
      o.put("directives", directives)
      o.put("sayNote", "the brain answered " & addressee &
            (if d.streaming: "; the reply is STREAMING and its segments " &
                             "arrive on /events as they are spoken"
             else: ""))
  result = done(o).text

proc onPtt(url, body, session: string): string =
  ## Push to talk, aowlspt-side. `/speech/chunk` is the SPT shape (the plugin
  ## captured the audio); here the CLIENT CANNOT CAPTURE -- EFT holds the mic
  ## exclusively -- so `down` starts a recorder process on this machine, the
  ## tick feeds the growing file, and `up` finalises. `poll` is the manual
  ## pump: the simulator runs every route before it runs a single tick, so
  ## without it the progressive half could not be exercised without a game.
  if not gEnabled: return disabledJson()
  let sess = jr.asText(jr.field(body, "session"), session)
  let state = jr.asText(jr.field(body, "state"), "")
  var o = obj()
  o.put("session", sess)
  o.put("state", state)
  case state
  of "down":
    var wav = ""
    var already = false
    var note = ""
    var ok = false
    withModLock:
      ok = pttStart(sess, wav, already, note)
    o.put("ok", ok)
    o.put("already", already)
    o.put("wav", wav)
    o.put("note", (if already: "already recording -- " & note else: note))
  of "poll":
    var partial = ""
    var note = ""
    var ok = false
    withModLock:
      ok = pttPump(partial, note)
    if partial.len > 0:
      discard emitEvent("heard.partial",
                        done(objOf("text", partial)).text, false)
    o.put("ok", ok)
    o.put("partial", partial)
    o.put("note", note)
  of "up":
    var closed = ""
    var finalText = ""
    var note = ""
    var ok = false
    withModLock:
      ok = pttStop(closed, finalText, note)
    o.put("ok", ok)
    o.put("closed", closed)
    o.put("final", finalText)
    o.put("note", note)
    if ok:
      # Emitted on EVERY close, empty text included, and the note travels with
      # it: with sttEngine=none or no capture device there is legitimately
      # nothing to transcribe, and an event that only appears on success cannot
      # tell the client "the utterance ended and produced nothing" apart from
      # "the backend never noticed the key came up".
      var eo = obj()
      eo.put("text", finalText)
      eo.put("source", "ptt")
      eo.put("note", note)
      discard emitEvent("heard.final", done(eo).text, false)
      # The addressee is whoever the CLIENT says the player is talking to
      # (`personId` in the ptt body -- the SPT plugin latches the bot in the
      # view cone; bridge/see.nim will do the same), falling back to the
      # captor when the client names nobody. MEASURED 2026-09-07 (first live
      # transcripts "Hey, how are you doing?"): the brain was never asked
      # because only captiveOf() was consulted, so nobody ever answered.
      var addressee = jr.asText(jr.field(body, "personId"), "")
      if addressee.len > 0 and findPerson(addressee) < 0:
        o.put("addresseeNote", "the client named person '" & addressee &
              "' but no such person exists in this world; falling back")
        addressee = ""
      if addressee.len == 0: addressee = captiveOf()
      if addressee.len == 0:
        o.put("spokeTo", "")
        o.put("sayNote", "nobody was addressed: the encounter machine holds " &
              "no captive/escorted person, so the brain was NOT asked. The " &
              "client picks the addressee on aowlspt (bridge/see.nim); until " &
              "it does, POST " & SayRoute & " with a personId.")
      elif finalText.len == 0:
        o.put("spokeTo", "")
        o.put("sayNote", "'" & addressee & "' holds the player, but nothing " &
              "was transcribed, so the brain was not asked with an empty " &
              "utterance")
      else:
        var directives = 0
        var tagNote = ""
        var d = Decision(text: "", tags: @[], tier: "", cached: false,
                         engine: "", ms: 0, notes: @[], segments: @[],
                         turnId: 0, streaming: false)
        withModLock:
          d = speakTurn(addressee, finalText, directives, tagNote)
        o.put("spokeTo", addressee)
        o.put("reply", d.text)
        o.put("tier", d.tier)
        o.put("directives", directives)
        o.put("sayNote", "the brain answered " & addressee &
              " (the person the encounter machine currently holds)")
  else:
    o.put("ok", false)
    o.put("err", "state must be \"down\", \"up\" or \"poll\" (got '" &
          state & "'); `poll` feeds whatever the recorder has written so far " &
          "and is what the backend tick does every tickMs")
  withModLock:
    o.put("ptt", pttStatus())
  result = done(o).text

proc onEvents(url, body, session: string): string =
  ## `since` + `wait`. HONESTY, because it matters to whoever writes the
  ## client: the wait is a BOUNDED POLL on this request thread, not a parked
  ## socket -- the mod SDK exposes no sleep or condition variable, so a real
  ## long-poll needs a host-side primitive that does not exist yet
  ## (DESIGN.md §10). `waitedMs` and `mechanism` are in every reply so nobody
  ## has to guess which one they got.
  let since = queryInt(url, "since", jr.asInt(jr.field(body, "since"), 0))
  var wait = queryInt(url, "wait", jr.asInt(jr.field(body, "wait"), 0))
  if wait > gMaxWaitMs: wait = gMaxWaitMs
  let limit = queryInt(url, "limit", 200)
  let t0 = nowMs()
  var spins = 0
  # THE POLL IS UNLOCKED, THE PAYLOAD IS NOT. This is the bug that killed the
  # backend on 2026-09-07: the whole route ran without `withModLock` while the
  # tick thread's `expirePending` -> `dropPendingAt` REBUILDS gPendSeq /
  # gPendKind / gPendDue and `emitEvent` appends to the ring. `pendingAcks`
  # then read `gPendKind[i]` after `gPendSeq.len` had already been replaced by
  # a shorter seq, and nimony killed the process with
  # `seqimpl.nim(167, 41): i < s.len and 0 <= i [AssertionDefect]` -- no stack,
  # every subsequent request refused because there was no process left.
  #
  # The spin must NOT hold the lock (`sync.nim`: never hold it across a wait,
  # and the tick needs it to make progress or `latestSeq` could never change),
  # so each probe takes it for one read and drops it again. The payload is then
  # built under ONE hold, so `events` and `pending` describe the same instant.
  var latest = 0
  withModLock:
    latest = latestSeq()
  while wait > 0 and latest <= since and (nowMs() - t0) < int64(wait):
    spins = spins + 1
    withModLock:
      latest = latestSeq()
  var o = obj()
  o.put("ok", true)
  o.put("since", since)
  o.put("waitedMs", int(nowMs() - t0))
  o.put("mechanism", (if wait > 0: "bounded poll on the request thread (no " &
                        "sleep primitive in the mod SDK)" else: "immediate"))
  withModLock:
    o.put("latestSeq", latestSeq())
    o.put("events", eventsSince(since, limit))
    o.put("pending", pendingAcks())
    o.put("tornReads", streamTornReads())
  result = done(o).text

proc onAck(url, body, session: string): string =
  let s = jr.asInt(jr.field(body, "seq"), -1)
  let ok = jr.asBool(jr.field(body, "ok"), true)
  let note = jr.asText(jr.field(body, "note"), "")
  var cleared = false
  var o = obj()
  withModLock:
    cleared = ackEvent(s, ok, note)
    o.put("ok", cleared)
    o.put("seq", s)
    if not cleared:
      o.put("err", "seq " & $s & " is not a pending directive (already " &
            "acked, expired, or never needed an ack)")
    # Inside the lock with the ack itself: read outside it and the tick's
    # `expirePending` can rebuild the pending columns mid-walk.
    o.put("pending", pendingAcks())
  result = done(o).text

proc onSpawn(url, body, session: string): string =
  ## Where the player should be next — the "always in raid" gesture. Emits the
  ## `player.spawn` directive AND, when `autoRaidRequests` is on, the mod-bus
  ## event `basement.raid.request` that `mods/autoraid` is meant to consume
  ## (it does not yet — DESIGN.md §10).
  var map = ""
  var x = 0.0
  var y = 0.0
  var z = 0.0
  var reason = "resume where the world left the player"
  # Under the lock like every other route that reads world rows: the tick moves
  # people and rebuilds the stream on another thread.
  withModLock:
    playerPos(map, x, y, z)
    let held = captiveOf()
    if held.len > 0:
      let hp = findPerson(held)
      if hp >= 0:
        map = personMap(hp)
        personPos(hp, x, y, z)
        reason = "held prisoner by " & personName(hp)
    if map.len == 0 and placeCount() > 0:
      map = placeMap(0)
      placePos(0, x, y, z)
      reason = "no recorded position; first place in the world"
  var o = obj()
  o.put("map", map)
  o.put("x", x)
  o.put("y", y)
  o.put("z", z)
  o.put("reason", reason)
  let payload = done(o).text
  withModLock:
    discard emitEvent("player.spawn", payload, true, 60000)
  if gAutoRaid:
    discard broadcast("basement.raid.request", payload)
  var root = obj()
  root.put("ok", map.len > 0)
  root.put("spawn", done(o))
  root.put("raidRequested", gAutoRaid)
  if map.len == 0:
    root.put("err", "no map to spawn on: the world has no places and the " &
             "player has no recorded position")
  result = done(root).text


proc queryFloat(url, key: string; default: float): float =
  ## `x=-123.5`. Hand-written for the same reason `parseIntOr` is: a malformed
  ## coordinate must be a DEFAULT with the caller told, never an exception
  ## across a route.
  let v = queryValue(url, key)
  if v.len == 0: return default
  var i = 0
  var sign = 1.0
  if v[0] == '-':
    sign = -1.0
    i = 1
  elif v[0] == '+':
    i = 1
  var whole = 0.0
  var seen = false
  while i < v.len and v[i] >= '0' and v[i] <= '9':
    whole = whole * 10.0 + float(int(v[i]) - int('0'))
    seen = true
    i = i + 1
  var frac = 0.0
  var scale = 1.0
  if i < v.len and v[i] == '.':
    i = i + 1
    while i < v.len and v[i] >= '0' and v[i] <= '9':
      scale = scale * 10.0
      frac = frac + float(int(v[i]) - int('0')) / scale
      seen = true
      i = i + 1
  if not seen: return default
  result = sign * (whole + frac)

proc onScene(url, body, session: string): string =
  ## The materialiser. GET it and the caches around that point stop being
  ## rumours: they become intact, their items become loot rows, and the
  ## directives that build them go on the stream.
  if not gEnabled: return disabledJson()
  var map = queryValue(url, "map")
  if map.len == 0: map = jr.asText(jr.field(body, "map"), "")
  let x = queryFloat(url, "x", jr.asFloat(jr.field(body, "x"), 0.0))
  let y = queryFloat(url, "y", jr.asFloat(jr.field(body, "y"), 0.0))
  let z = queryFloat(url, "z", jr.asFloat(jr.field(body, "z"), 0.0))
  let radius = queryFloat(url, "radius", jr.asFloat(jr.field(body, "radius"), 0.0))
  if map.len == 0:
    return errJson("no `map`: GET " & SceneRoute &
                   "?map=Woods&x=0&y=0&z=0&radius=150")
  var scene = obj()
  withModLock:
    scene = sceneJson(map, x, y, z, radius)
  result = done(scene).text

proc onLoot(url, body, session: string): string =
  let map = queryValue(url, "map")
  var a = arr()
  var placed = 0
  for li in lootOnMap(map):
    a.add lootJson(li)
    if lootStatus(li) == "placed": placed = placed + 1
  var o = obj()
  o.put("ok", true)
  o.put("map", map)
  o.put("count", a.len)
  o.put("placed", placed)
  o.put("loot", a)
  result = done(o).text

proc onCaches(url, body, session: string): string =
  let map = queryValue(url, "map")
  var a = arr()
  for ci in cachesOnMap(map):
    var co = cacheJson(ci)
    var pk = arr()
    for k in pickupsAt(cacheId(ci)):
      pk.add contractJson(k)
    co.put("pickups", pk)
    a.add co
  var o = obj()
  o.put("ok", true)
  o.put("map", map)
  o.put("count", a.len)
  o.put("caches", a)
  result = done(o).text

# --- offscreen begin ---
proc onRegions(url, body, session: string): string =
  ## Per map: the groups, what each is doing, the last thing that resolved
  ## there, and whether the map is FROZEN (the player is in a raid on it, so
  ## the client is the truth) or EMULATED (the backend keeps it running).
  if not gEnabled: return disabledJson()
  var o = obj()
  withModLock:
    o = regionsJson()
  result = done(o).text
# --- offscreen end ---

# ---------------------------------------------------------------------------
# The emulator bus (DESIGN.md 11). `emit` returns no payload, so each of these
# is a round trip: mods/tarkov asks, this composes from world rows, this emits
# the answer, mods/tarkov's subscriber applies it.
#
# HONESTY: an emit is NOT delivered back to the mod that made it (MEASURED by
# agent F in host/Aowlspt.Sim/aowlsim.nim `deliverEvent`), so nothing in this
# process can hear its own plant. The compose halves are therefore written as
# plain procs and the handlers are two lines each: the selfcheck exercises the
# proc, and the cross-mod delivery is left INCONCLUSIVE rather than faked.
# ---------------------------------------------------------------------------

proc composeLootPlant(raidId, map: string): string =
  var items = arr()
  for li in lootOnMap(map):
    if lootStatus(li) != "placed": continue
    var lx = 0.0
    var ly = 0.0
    var lz = 0.0
    lootPos(li, lx, ly, lz)
    var io = obj()
    io.put("id", lootId(li))
    io.put("tpl", lootTpl(li))
    io.put("count", lootN(li))
    io.put("x", lx)
    io.put("y", ly)
    io.put("z", lz)
    io.put("cacheId", lootCache(li))
    items.add io
  var o = obj()
  o.put("raidId", raidId)
  o.put("map", map)
  o.put("items", items)
  result = done(o).text

proc composeBotsPlant(raidId, map: string): string =
  var groups = arr()
  var seen: seq[string] = @[]
  for ci in cachesOnMap(map):
    let grp = cacheGuardGroup(ci)
    if grp.len == 0: continue
    var dup = false
    for g in seen:
      if g == grp: dup = true
    if dup: continue
    seen.add grp
    var names = arr()
    var count = 0
    var gx = 0.0
    var gy = 0.0
    var gz = 0.0
    for gi in peopleOfGroup(grp):
      if not personAlive(gi): continue
      names.add personName(gi)
      personPos(gi, gx, gy, gz)
      count = count + 1
    if count == 0: continue
    var go = obj()
    go.put("groupId", grp)
    go.put("factionId", cacheOwner(ci))
    go.put("role", "guard")
    go.put("count", count)
    go.put("names", names)
    go.put("x", gx)
    go.put("y", gy)
    go.put("z", gz)
    groups.add go
  var o = obj()
  o.put("raidId", raidId)
  o.put("map", map)
  o.put("groups", groups)
  result = done(o).text

proc onLootCompose(payload: string): string =
  let map = jr.asText(jr.field(payload, "map"), "")
  let raidId = jr.asText(jr.field(payload, "raidId"), "")
  var text = ""
  withModLock:
    text = composeLootPlant(raidId, map)
  gLastLootPlant = text
  gLootComposeN = gLootComposeN + 1
  # Emitted from INSIDE the handler, which is the whole shape of the round
  # trip: `emit` returns nothing, so the answer has to be a second event.
  discard emit("tarkov.loot.plant", text)
  result = ""

proc onBotsCompose(payload: string): string =
  let map = jr.asText(jr.field(payload, "map"), "")
  let raidId = jr.asText(jr.field(payload, "raidId"), "")
  var text = ""
  withModLock:
    text = composeBotsPlant(raidId, map)
  gLastBotsPlant = text
  gBotsComposeN = gBotsComposeN + 1
  discard emit("tarkov.bots.plant", text)
  result = ""

proc onLootTakenEvent(payload: string): string =
  var n = 0
  var last = ""
  withModLock:
    for e in jr.each(jr.field(payload, "itemIds")):
      let id = jr.asText(e, "")
      if id.len == 0: continue
      var note = ""
      observeLootTaken("", id, "player", note)
      last = note
      n = n + 1
  if n > 0:
    info ModName & ": tarkov.loot.taken applied " & $n & " item(s): " & last
  result = ""

# ---------------------------------------------------------------------------
# The selfcheck — DESIGN.md §9. Every line is PASS / FAIL / INCONCLUSIVE, and
# "I could not look" is INCONCLUSIVE, never PASS.
#
# It REGENERATES the world in memory (checks 1-3 and 5 need a known one) and
# restores the saved world from the store at the end. It never saves over the
# player's world.
# ---------------------------------------------------------------------------

var gCheckLines: seq[string] = @[]
var gPassN: int = 0
var gFailN: int = 0
var gIncN: int = 0

proc check(n: int; name, verdict, evidence: string) =
  gCheckLines.add "CHECK " & $n & " " & name & ": " & verdict & " -- " & evidence
  if verdict == "PASS": gPassN = gPassN + 1
  elif verdict == "FAIL": gFailN = gFailN + 1
  else: gIncN = gIncN + 1

proc verdictOf(ok: bool): string =
  if ok: "PASS" else: "FAIL"

proc chk1Determinism() =
  var p = presetFromFile(joinPath(gPresetDir, "warlords.json"))
  if not p.ok:
    check(1, "determinism", "INCONCLUSIVE",
          "warlords.json did not load from " & gPresetDir & ": " & p.note)
    return
  var n1 = ""
  if not generate(7'u64, p, "", n1):
    check(1, "determinism", "FAIL", "generate(seed 7) failed: " & n1)
    return
  let a = kindJsonText("people")
  var n2 = ""
  discard generate(7'u64, p, "", n2)
  let b = kindJsonText("people")
  var n3 = ""
  discard generate(8'u64, p, "", n3)
  let c = kindJsonText("people")
  let same = a == b
  let differs = a != c
  check(1, "determinism", verdictOf(same and differs),
        "seed7==seed7 " & $same & " (" & $a.len & " bytes), seed7!=seed8 " &
        $differs & " (negative control: " & $c.len & " bytes)")

proc chk2Persistence() =
  var saveNote = ""
  let vBefore = worldVersion()
  if not saveWorld(saveNote):
    check(2, "persistence", "FAIL", "saveWorld refused: " & saveNote)
    return
  # All TEN persisted kinds, not just `people`: caches and loot joined the
  # store with grounding, and a byte-identity check that looks at one kind
  # cannot fail for the nine it does not look at.
  let kinds: seq[string] = @["meta", "factions", "people", "places",
                             "contracts", "quests", "facts", "caches",
                             "loot", "objectives", "journal"]
  var before: seq[string] = @[]
  var bytes = 0
  for k in kinds:
    let t = kindJsonText(k)
    before.add t
    bytes = bytes + t.len
  var loadNote = ""
  if not loadWorld(loadNote):
    check(2, "persistence", "FAIL", "loadWorld refused: " & loadNote)
    return
  var differing: seq[string] = @[]
  var i = 0
  while i < kinds.len:
    if kindJsonText(kinds[i]) != before[i]: differing.add kinds[i]
    i = i + 1
  var corruptNote = ""
  let corruptOk = loadKindFromJson("quests", "{ this is not json", corruptNote)
  let roundTrip = differing.len == 0
  let peopleIntact = personCount() > 0
  check(2, "persistence", verdictOf(roundTrip and (not corruptOk) and peopleIntact),
        $kinds.len & " kinds round-tripped byte-identically " & $roundTrip &
        " (" & $bytes & " bytes; differing: " & joinWith(differing, " ") &
        "), version " & $vBefore & "->" & $worldVersion() &
        "; a corrupt document was refused " & $(not corruptOk) & " (" &
        corruptNote & "); people still loaded " & $personCount())

proc chk3CatchUp() =
  if personCount() == 0:
    check(3, "sim catch-up", "INCONCLUSIVE", "no people in the world to move")
    return
  var before: seq[string] = @[]
  var i = 0
  while i < personCount():
    before.add personPlace(i)
    i = i + 1
  var n = ""
  let moved = simAdvance(6 * 3600000, n)
  var changed = 0
  i = 0
  while i < personCount():
    if i < before.len and personPlace(i) != before[i]: changed = changed + 1
    i = i + 1
  var n0 = ""
  var after0: seq[string] = @[]
  i = 0
  while i < personCount():
    after0.add personPlace(i)
    i = i + 1
  let zeroChanges = simAdvance(0, n0)
  var changed0 = 0
  i = 0
  while i < personCount():
    if i < after0.len and personPlace(i) != after0[i]: changed0 = changed0 + 1
    i = i + 1
  check(3, "sim catch-up", verdictOf(changed > 0 and changed0 == 0),
        "advance 6h moved " & $changed & " of " & $personCount() &
        " people (" & $moved & " changes: " & n &
        "); advance 0 moved " & $changed0 & " (negative control, " &
        $zeroChanges & " changes)")

proc firstPersonOfRole(role: string): int =
  result = -1
  var i = 0
  while i < personCount():
    if personAlive(i) and personRole(i) == role: return i
    i = i + 1

proc chk4BrainTiers() =
  if personCount() == 0:
    check(4, "brain tiers", "INCONCLUSIVE", "no people in the world to talk to")
    return
  let pid = personId(0)
  var d1 = 0
  var t1 = ""
  let first = speakTurn(pid, "hello there", d1, t1)
  var d2 = 0
  var t2 = ""
  let second = speakTurn(pid, "hello there", d2, t2)
  var d3 = 0
  var t3 = ""
  let nonsense = speakTurn(pid, "zzxq frobnicate the wibble", d3, t3)
  # An unknown tag must be dropped WITH a note, and must never reach a
  # directive. This is the negative control of the tag path.
  var unknownNote = ""
  let beforeSeq = latestSeq()
  var fooTags: seq[string] = @[]
  fooTags.add "[FOO: nonsense]"
  let fooDirectives = applyTags(pid, fooTags, unknownNote)
  # A canned [ATTACK] must reach the stream as npc.attack.
  var attackTags: seq[string] = @[]
  attackTags.add "[ATTACK]"
  var attackNote = ""
  let attackSeqBefore = latestSeq()
  let attackDirectives = applyTags(pid, attackTags, attackNote)
  let attackEmitted = latestSeq() > attackSeqBefore and attackDirectives > 0
  let cachedSecond = second.cached
  let builtinSaid = contains(toLowerAscii(nonsense.tier & " " &
                             (if nonsense.notes.len > 0: nonsense.notes[0] else: "")),
                             "not a language model") or nonsense.tier != "llm"
  let ok = cachedSecond and fooDirectives == 0 and attackEmitted
  check(4, "brain tiers", verdictOf(ok),
        "first tier=" & first.tier & " cached=" & $first.cached &
        "; repeat cached=" & $second.cached &
        "; nonsense tier=" & nonsense.tier & " (builtin honest " & $builtinSaid &
        "); [FOO] emitted " & $fooDirectives & " directives (" & unknownNote &
        "); [ATTACK] emitted " & $attackDirectives & " directives, seq " &
        $beforeSeq & "->" & $latestSeq())

proc chk5Encounter() =
  let grunt = firstPersonOfRole("grunt")
  let slaver = firstPersonOfRole("slaver")
  if grunt < 0:
    check(5, "encounter machine", "INCONCLUSIVE",
          "this world has no living 'grunt' to aim at (" & $personCount() &
          " people)")
    return
  var note = ""
  discard observe("player_aimed_at", personId(grunt), "", "{}", note)
  let threatened = encounterState(personId(grunt))
  if slaver < 0:
    check(5, "encounter machine", "INCONCLUSIVE",
          "aim -> " & threatened & " (expected threatened), but this world " &
          "has no 'slaver' so captivity could not be exercised")
    return
  let sid = personId(slaver)
  discard observe("player_aimed_at", sid, "", "{}", note)
  var n2 = ""
  discard observe("player_lowered_weapon", sid, "", "{}", n2)
  let captiveState = encounterState(sid)
  let contractIdx = findContract("captivity." & sid)
  let contractActive = contractIdx >= 0 and contractStatus(contractIdx) == "active"
  # Break the leash: report a position far from the captor.
  var cx = 0.0
  var cy = 0.0
  var cz = 0.0
  personPos(slaver, cx, cy, cz)
  let jBefore = journalCount()
  var mo = obj()
  mo.put("kind", "player_moved")
  mo.put("map", personMap(slaver))
  mo.put("x", cx + leashM() * 4.0)
  mo.put("y", cy)
  mo.put("z", cz)
  var n3 = ""
  discard observe("player_moved", "", "", done(mo).text, n3)
  let escapeJournaled = journalCount() > jBefore and contains(n3, "escape attempt")
  var n4 = ""
  discard observe("player_fired", sid, "", "{}", n4)
  let fighting = encounterState(sid)
  let ok = threatened == "threatened" and
           (captiveState == "captive" or captiveState == "escorted") and
           contractActive and escapeJournaled and fighting == "fighting"
  check(5, "encounter machine", verdictOf(ok),
        "aim->" & threatened & "; lowered weapon at a slaver->" & captiveState &
        " with contract active " & $contractActive & "; leash break journaled " &
        $escapeJournaled & " (" & n3 & "); fired at captor->" & fighting)

proc chk6Stream() =
  let base = latestSeq()
  let s1 = emitEvent("selfcheck.probe", "{\"i\":1}", false)
  let s2 = emitEvent("selfcheck.needsack", "{\"i\":2}", true, 1)
  let since = eventsSince(s1, 100)
  let immediate = eventsSince(base, 100)
  var dropped: seq[int] = @[]
  let expired = expirePending(worldClockMs() + 60000, dropped)
  let clearedNonPending = ackEvent(s1, true, "selfcheck")
  let ok = s2 > s1 and since.len >= 1 and immediate.len >= 2 and
           expired >= 1 and not clearedNonPending
  check(6, "stream cursor and acks", verdictOf(ok),
        "seq " & $s1 & "->" & $s2 & "; since=" & $s1 & " returned " &
        $since.len & " event(s); since=" & $base & " returned " &
        $immediate.len & "; " & $expired & " un-acked directive(s) past ttl " &
        "were dropped; acking a non-pending seq returned " &
        $clearedNonPending & " (must be false)")

proc chk7Engines() =
  let lp = llmProbe()
  let hasKey = getEnv("ANTHROPIC_API_KEY", "").len > 0
  let anthropicHonest = (lp.engine != "anthropic") or (lp.ok == hasKey)
  check(7, "engine probes", verdictOf(anthropicHonest and lp.path.len >= 0),
        "llm engine=" & lp.engine & " path=" & lp.path & " ok=" & $lp.ok &
        " (" & lp.note & "); ANTHROPIC_API_KEY present " & $hasKey &
        "; with no key the anthropic engine must probe MISSING and /say must " &
        "never call curl")

proc chk8Speech() =
  let sp = sttProbe()
  let tp = ttsProbe()
  if not tp.ok:
    check(8, "speech", "INCONCLUSIVE",
          "tts engine " & tp.engine & " is missing at '" & tp.path & "' (" &
          tp.note & "); stt " & sp.engine & " ok=" & $sp.ok &
          " -- a missing exe is INCONCLUSIVE, never PASS")
    return
  var n1 = ""
  var c1 = false
  let w1 = ttsSegment("", "The basement door is locked.", n1, c1)
  var n2 = ""
  var c2 = false
  let w2 = ttsSegment("", "The basement door is locked.", n2, c2)
  if tp.engine == "client":
    # The finished state for `client` is NO wav and a note that says which
    # engine declined -- a wav here would be the bug.
    let okc = w1.len == 0 and w2.len == 0 and contains(n1, "tts=client")
    check(8, "speech", verdictOf(okc),
          "tts=client: wav '" & w1 & "' (must be empty), note '" & n1 &
          "' (must name tts=client); stt " & sp.engine & " ok=" & $sp.ok)
    return
  let ok = w1.len > 0 and w1 == w2 and c2
  check(8, "speech", verdictOf(ok),
        "tts wav '" & w1 & "' cached-on-second " & $c2 & " same path " &
        $(w1 == w2) & "; stt " & sp.engine & " ok=" & $sp.ok & " (" & sp.note & ")")

proc chk9TagGrammar() =
  ## The tag grammar is the LLM's ONLY actuator, so an unactuated tag is a
  ## silent nothing by construction. This asserts the FINISHED STATE: every tag
  ## `prompt.knownTags()` declares produces an effect here (a directive, a
  ## state change, or a note that says why it legitimately did not), and a tag
  ## that is not in the grammar produces zero directives and names itself.
  if personCount() == 0:
    check(9, "tag grammar actuated", "INCONCLUSIVE", "no people to act on")
    return
  let pid = personId(0)
  let tags = knownTags()
  if tags.len == 0:
    check(9, "tag grammar actuated", "INCONCLUSIVE",
          "prompt.knownTags() is empty, so there is nothing to check against")
    return
  var unmapped: seq[string] = @[]
  for t in tags:
    var n = ""
    var one: seq[string] = @[]
    one.add "[" & t & ": x]"
    let before = latestSeq()
    let d = applyTags(pid, one, n)
    if contains(n, "unknown tag"): unmapped.add t
    discard before
    discard d
  var badNote = ""
  var bad: seq[string] = @[]
  bad.add "[NOT_A_REAL_TAG: x]"
  let badDirectives = applyTags(pid, bad, badNote)
  let ok = unmapped.len == 0 and badDirectives == 0 and
           contains(badNote, "unknown tag")
  check(9, "tag grammar actuated", verdictOf(ok),
        $tags.len & " declared tags, " & $unmapped.len & " unmapped (" &
        joinWith(unmapped, " ") & "); an invented tag emitted " & $badDirectives &
        " directives and said: " & badNote)


# --------------------------------------------------------------- grounding
# DESIGN.md 11 numbers its three new checks 9, 10 and 11; they are 10, 11 and
# 12 here because 9 was already taken by the tag-grammar check. The names say
# which is which so nobody has to reconcile two numbering schemes later.

proc firstCacheWithPickup(): int =
  result = -1
  var i = 0
  while i < cacheCount():
    for k in pickupsAt(cacheId(i)):
      if contractStatus(k) == "active" and result < 0: result = i
    i = i + 1

proc chk10Plant() =
  ## DESIGN 11 check 9. A [PLANT:] tag in a reply makes a REAL cache: items
  ## (or an INCONCLUSIVE item note), guards who are people in this world, the
  ## speaker knows it, `world/scene` at that place lists it, `loot.taken` flips
  ## it to looted and produces a rumour with origin `outcome` -- and a scene on
  ## ANOTHER map lists nothing of it, which is the negative control.
  if personCount() == 0:
    check(10, "grounding: plant -> scene -> loot.taken (11.9)", "INCONCLUSIVE",
          "no people in the world to plant anything")
    return
  let pid = personId(0)
  let pi = 0
  let map = personMap(pi)
  var tags: seq[string] = @[]
  tags.add "[PLANT: cache | near | two crates of ammunition and a rifle | " &
           "guarded by " & personFaction(pi) & " x3]"
  var tnote = ""
  let before = cacheCount()
  discard applyTags(pid, tags, tnote)
  if cacheCount() != before + 1:
    check(10, "grounding: plant -> scene -> loot.taken (11.9)", "FAIL",
          "[PLANT] did not create a cache (" & $before & " -> " &
          $cacheCount() & "): " & tnote)
    return
  let ci = cacheCount() - 1
  let cid = cacheId(ci)
  # guards must be PEOPLE, not a number in a field
  var guards = 0
  for gi in peopleOfGroup(cacheGuardGroup(ci)):
    if personAlive(gi) and findPerson(personId(gi)) >= 0: guards = guards + 1
  var speakerKnows = false
  for k in personKnows(pi):
    if k == cid: speakerKnows = true
  let items = cacheItemCount(ci)
  # the scene AT the cache
  var cx = 0.0
  var cy = 0.0
  var cz = 0.0
  cachePos(ci, cx, cy, cz)
  let scene = sceneJson(map, cx, cy, cz, 60.0)
  let sceneText = done(scene).text
  let listed = contains(sceneText, cid)
  # the negative control: a scene on a map this cache is not on
  var otherMap = ""
  var mi = 0
  while mi < placeCount():
    if placeMap(mi) != map and otherMap.len == 0: otherMap = placeMap(mi)
    mi = mi + 1
  var absentElsewhere = true
  var otherNote = "no second map in this world -- the negative control could " &
                  "NOT be run"
  if otherMap.len > 0:
    let other = done(sceneJson(otherMap, cx, cy, cz, 60.0)).text
    absentElsewhere = not contains(other, cid)
    otherNote = "a scene on " & otherMap & " lists it " &
                $(not absentElsewhere) & " (must be false)"
  # take it
  let lootRows = lootOfCache(cid).len
  var lnote = ""
  observeLootTaken(cid, "", "player", lnote)
  let looted = cacheStatus(ci) == "looted"
  var outcome = false
  for fi in factsAbout("cache", cid):
    if factOrigin(fi) == "outcome": outcome = true
  let itemsOk = items > 0 or contains(tnote, "INCONCLUSIVE")
  let ok = guards >= 1 and speakerKnows and itemsOk and listed and
           absentElsewhere and looted and outcome
  check(10, "grounding: plant -> scene -> loot.taken (11.9)", verdictOf(ok),
        "cache " & cid & ": " & $items & " item row(s) (ok " & $itemsOk &
        "), " & $guards & " guard(s) who are real people, speaker knows it " &
        $speakerKnows & "; scene at the cache lists it " & $listed &
        " and materialised " & $lootRows & " loot row(s); " & otherNote &
        "; loot.taken -> status " & cacheStatus(ci) & ", outcome fact " &
        $outcome & " (" & lnote & ")")

proc chk11Claim() =
  ## DESIGN 11 check 10. The same guard, the same cache, two utterances: the
  ## bearer's name plus the token, and a name and word that are neither. One
  ## must be believed and the other must not -- a test with only the positive
  ## half cannot fail.
  let ci = firstCacheWithPickup()
  if ci < 0:
    check(11, "grounding: impersonation (11.10)", "INCONCLUSIVE",
          "no cache in this world has an active pickup contract (" &
          $cacheCount() & " caches), so a claim has nothing to be measured " &
          "against")
    return
  let cid = cacheId(ci)
  var bearer = ""
  var token = ""
  for k in pickupsAt(cid):
    if contractStatus(k) == "active" and bearer.len == 0:
      bearer = contractPartyB(k)
      token = contractTerms(k)
  let bi = findPerson(bearer)
  var guard = -1
  for gi in peopleOfGroup(cacheGuardGroup(ci)):
    if personAlive(gi) and guard < 0: guard = gi
  if guard < 0 or bi < 0:
    check(11, "grounding: impersonation (11.10)", "INCONCLUSIVE",
          "cache " & cid & " has a pickup but no living guard (" &
          cacheGuardGroup(ci) & ") or no bearer we can name (" & bearer & ")")
    return
  let gid = personId(guard)
  let attBefore = personAttitude(bi)
  # negative FIRST, so a machine that simply says yes to everything is caught
  # before the positive case can paper over it.
  var badNote = ""
  let badOk = resolveClaim(gid, "I am nobody at all and the word is zzzzqqqq",
                           badNote)
  # the guard is threatened now; that is the point, and it does not stop the
  # second roll from being scored.
  var goodNote = ""
  let goodOk = resolveClaim(gid, "I am " & personName(bi) & ", the word is " &
                            token, goodNote)
  var stoodDown = false
  var gave = false
  let evText = done(eventsSince(0, 400)).text
  stoodDown = contains(evText, "npc.stand_down")
  gave = contains(evText, "npc.give")
  var broken = false
  for k in pickupsAt(cid):
    if contractStatus(k) == "broken": broken = true
  # The DELTA, not an absolute: the bearer's starting attitude is generated,
  # so `<= -30` would pass or fail on the seed rather than on the code.
  let grudge = personAttitude(bi) <= attBefore - 40 or personAttitude(bi) == -100
  let hunted = findQuest("hunt." & bearer) >= 0
  let ok = goodOk and (not badOk) and stoodDown and gave and broken and
           grudge and hunted
  check(11, "grounding: impersonation (11.10)", verdictOf(ok),
        "guard " & gid & " at " & cid & ": right name + right token believed " &
        $goodOk & " (" & goodNote & "); WRONG name + wrong token believed " &
        $badOk & " (negative control -- must be false: " & badNote &
        "); npc.stand_down " & $stoodDown & ", npc.give " & $gave &
        ", the real bearer's contract broken " & $broken & ", bearer attitude " &
        $attBefore & "->" & $personAttitude(bi) & " (grudge " & $grudge &
        "), hunt quest offered " & $hunted)

proc chk12KnownIds() =
  ## DESIGN 11 check 11. No person's knowledge names an id this world does not
  ## hold -- asserted over the RAW `knows` list, not over the rendered block,
  ## because `renderKnown` skips what it cannot find and a check over its
  ## output could never fail. The negative control plants one bogus id and
  ## requires the same scan to catch it.
  if personCount() == 0:
    check(12, "grounding: nobody knows a thing that does not exist (11.11)",
          "INCONCLUSIVE", "no people to check")
    return
  var bad: seq[string] = @[]
  var known = 0
  var i = 0
  while i < personCount():
    for id in personKnows(i):
      known = known + 1
      if not worldHasId(id):
        if bad.len < 6: bad.add personId(i) & "->" & id
    i = i + 1
  # negative control
  let bogus = "no-such-entity-deadbeef"
  addPersonKnows(0, bogus)
  var caught = false
  for id in personKnows(0):
    if not worldHasId(id): caught = true
  discard dropPersonKnows(0, bogus)
  var stillThere = false
  for id in personKnows(0):
    if id == bogus: stillThere = true
  # and the rendered block must never contain the bogus id either
  let rendered = renderKnown(0, 12)
  let leaked = contains(rendered, bogus)
  let ok = bad.len == 0 and caught and (not stillThere) and (not leaked) and
           known > 0
  check(12, "grounding: nobody knows a thing that does not exist (11.11)",
        verdictOf(ok),
        $known & " knowledge row(s) over " & $personCount() & " people, " &
        $bad.len & " naming an id the world does not hold (" &
        joinWith(bad, " ") & "); negative control: a planted bogus id WAS " &
        "caught " & $caught & ", removed again " & $(not stillThere) &
        ", never rendered " & $(not leaked))

proc chk13LootBus() =
  ## The emulator hand-off. What can be proven in ONE process is that a
  ## compose produces a plant payload naming the loot rows that exist. What
  ## CANNOT be proven here is delivery: an emit is not delivered back to the
  ## mod that made it, and mods/tarkov is not loaded in this process, so that
  ## half is stated as unproven instead of being simulated.
  var map = ""
  var i = 0
  while i < lootCount():
    if lootStatus(i) == "placed" and map.len == 0: map = lootMap(i)
    i = i + 1
  var built = ""
  if map.len == 0:
    # Nothing is placed yet (check 10 emptied the only cache it made), so
    # build a scene around a cache that is still intact -- materialising is
    # what puts loot rows on a map in the first place.
    var ci2 = 0
    while ci2 < cacheCount():
      if cacheStatus(ci2) != "looted" and map.len == 0:
        var mx = 0.0
        var my = 0.0
        var mz = 0.0
        cachePos(ci2, mx, my, mz)
        discard sceneJson(cacheMap(ci2), mx, my, mz, 60.0)
        var li2 = 0
        while li2 < lootCount():
          if lootStatus(li2) == "placed" and map.len == 0: map = lootMap(li2)
          li2 = li2 + 1
        built = "built a scene at " & cacheId(ci2) & " first; "
      ci2 = ci2 + 1
  if map.len == 0:
    check(13, "grounding: loot/bots compose payloads", "INCONCLUSIVE",
          "no placed loot row on any map (" & $lootCount() &
          " loot rows) and no intact cache to materialise -- nothing to compose")
    return
  let plant = composeLootPlant("selfcheck-raid", map)
  var listed = 0
  var missing = 0
  i = 0
  while i < lootCount():
    if lootMap(i) == map and lootStatus(i) == "placed":
      if contains(plant, lootId(i)): listed = listed + 1
      else: missing = missing + 1
    i = i + 1
  let bots = composeBotsPlant("selfcheck-raid", map)
  var groups = 0
  var ci = 0
  while ci < cacheCount():
    if cacheMap(ci) == map and cacheGuardGroup(ci).len > 0 and
       contains(bots, cacheGuardGroup(ci)): groups = groups + 1
    ci = ci + 1
  # negative control: a map with no rows composes an EMPTY items array, not
  # every row in the world.
  let empty = composeLootPlant("selfcheck-raid", "no-such-map-zzz")
  let emptyOk = contains(empty, "\"items\":[]")
  let ok = listed > 0 and missing == 0 and emptyOk
  check(13, "grounding: loot/bots compose payloads", verdictOf(ok),
        built & $listed & " placed loot row(s) on " & map & " are in the plant " &
        "payload, " & $missing & " missing; " & $groups &
        " guard group(s) in the bots payload; an unknown map composes an " &
        "empty items array " & $emptyOk & " (negative control). NOT PROVEN " &
        "HERE: that mods/tarkov receives it -- an emit is not delivered to " &
        "the emitting mod and tarkov is not loaded in this process.")

proc chk14PushToTalk() =
  ## Push-to-talk end to end, in one route, with no game and no client.
  ##
  ## The falsifiable property is the FINISHED STATE, not our own write: after
  ## `up` the file the recorder was told to write must EXIST and be past its
  ## 44-byte header, PCM must actually have been fed into the session, and the
  ## stt session must be GONE from the session table. A second `up` is the
  ## negative control -- it must be refused.
  ##
  ## TWO THINGS THIS USED TO GET WRONG, both MEASURED 2026-09-07:
  ## * it read the wav size BEFORE `up`. recorder.exe writes the RIFF sizes and
  ##   closes the file only when it stops, so the size was always -1 and the
  ##   check reported INCONCLUSIVE ("the recorder produced no audio") in the
  ##   same breath as a note quoting 40684 bytes on disk.
  ## * it looked for `heard.final` on the stream. `pttStop` does not emit that
  ##   -- the ROUTE does -- and the route cannot be called from here, because
  ##   the selfcheck already holds the non-reentrant mod lock. That half is
  ##   asserted through the real route by tools/basement_check.py.
  ##
  ## Three outcomes. A missing recorder.exe, or a recorder that exited
  ## NO_DEVICES because `waveInGetNumDevs()` is 0 on this machine (aowl.voice
  ## DESIGN 5.1 measured exactly that), is INCONCLUSIVE with the exit code
  ## quoted -- never a PASS, and never reported as silence.
  let rp = recProbe()
  if not rp.ok:
    check(14, "push to talk", "INCONCLUSIVE",
          "no recorder: " & rp.note & " -- capture cannot be exercised, and a " &
          "missing exe is INCONCLUSIVE, never PASS")
    return
  if pttActive():
    var s0 = ""
    var f0 = ""
    var n0 = ""
    discard pttStop(s0, f0, n0)
  var wav = ""
  var already = false
  var startNote = ""
  if not pttStart("selfcheck-ptt", wav, already, startNote):
    check(14, "push to talk", "FAIL", "`down` refused: " & startNote)
    return
  # A bounded busy wait, for the same reason /events long-polls that way: the
  # mod SDK has no sleep primitive. 1.5 s is enough audio for the header and
  # several partial windows at 16 kHz.
  let t0 = nowMs()
  while (nowMs() - t0) < 1500:
    discard
  var partial = ""
  var pumpNote = ""
  let pumped = pttPump(partial, pumpNote)
  let midBytes = sizeOfFile(wav)
  let statusMid = pttStatus()
  var closed = ""
  var finalText = ""
  var stopNote = ""
  let stopped = pttStop(closed, finalText, stopNote)
  # The negative control: a second `up` has no recording to end.
  var c2 = ""
  var f2 = ""
  var n2 = ""
  let secondRefused = not pttStop(c2, f2, n2)
  # Read AFTER `up`: that is when the recorder has closed the file.
  let finalBytes = sizeOfFile(wav)
  let grew = finalBytes > 44
  let statusEnd = pttStatus()
  let fed = jr.asInt(jr.field(done(statusEnd).text, "pcmFed"), 0)
  let sessionGone = not pttActive()
  let evidence = "wav " & wav & " is " & $finalBytes & " bytes after `up` " &
    "(>44 " & $grew & "; mid-recording it was " & $midBytes &
    ", which is EXPECTED -- the recorder writes the sizes only when it " &
    "stops), " & $fed & " PCM byte(s) fed, pump " & $pumped & ": " & pumpNote &
    "; mid-recording status " & done(statusMid).text & "; `up` " & $stopped &
    " final text " & $finalText.len & " chars, session closed " &
    $sessionGone & ", a second `up` refused " & $secondRefused & " (" & n2 &
    "); " & stopNote
  if not grew:
    check(14, "push to talk", "INCONCLUSIVE",
          "the recorder produced no audio -- this is a capture-device " &
          "question, not a code one. " & evidence)
    return
  check(14, "push to talk",
        verdictOf(stopped and fed > 0 and sessionGone and secondRefused),
        evidence)

proc chk15AckFlagAndEmptyTurn() =
  ## The two halves of the 2026-09-07 live failure, both asserted on the
  ## FINISHED STATE that is actually SERVED -- never on our own write.
  ##
  ## A. THE ACK FLAG. `bm/stream` kept `needsAck` only in the server-side
  ##    pending list, so the served event carried no ack field at all and the
  ##    SPT client (`Link.cs`, which reads `ack`) could not know any directive
  ##    wanted one. Every needsAck directive was therefore dropped after its
  ##    ttl while the client logged "carries no ack. Ignored". The assertion
  ##    parses the SERVED document out of `eventsSince` and demands ack:true
  ##    on the needsAck event AND ack:false on the plain one -- the second half
  ##    is the negative control: a `put("ack", true)` on every event would pass
  ##    the first and fail this.
  ##
  ## B. THE EMPTY TURN. `ptt down` then `up` with the recorder having written
  ##    nothing: 0 PCM bytes, an empty transcript. The finished state must be a
  ##    `heard.final` on the stream carrying the empty text AND a REFUSAL note
  ##    naming why the brain was not asked -- not a silent skip, and not a turn
  ##    spoken with an empty utterance. This is the exact sequence that ran on
  ##    the live sidecar immediately before it died.
  let base = latestSeq()
  let sPlain = emitEvent("selfcheck.ackflag.plain", "{\"i\":1}", false)
  let sAck = emitEvent("selfcheck.ackflag.needsack", "{\"i\":2}", true, 30000)
  var plainFlag = -2
  var ackFlag = -2
  var ackTtl = -1
  let served = done(objOf("events", eventsSince(base, 100))).text
  for e in jr.each(jr.field(served, "events")):
    let k = jr.asText(jr.child(e, "kind"), "")
    if k == "selfcheck.ackflag.plain":
      plainFlag = (if jr.asBool(jr.child(e, "ack"), true): 1 else: 0)
    elif k == "selfcheck.ackflag.needsack":
      ackFlag = (if jr.asBool(jr.child(e, "ack"), false): 1 else: 0)
      ackTtl = jr.asInt(jr.child(e, "ttlMs"), -1)
  discard ackEvent(sAck, true, "selfcheck")
  let flagsOk = plainFlag == 0 and ackFlag == 1 and ackTtl == 30000

  # B -- the empty push-to-talk turn.
  if pttActive():
    var s0 = ""
    var f0 = ""
    var n0 = ""
    discard pttStop(s0, f0, n0)
  let emptyBase = latestSeq()
  var wav = ""
  var already = false
  var startNote = ""
  var emptyOk = false
  var emptyWhy = ""
  if not pttStart("selfcheck-emptyturn", wav, already, startNote):
    emptyWhy = "`down` refused (" & startNote & ") -- the empty-turn half " &
               "could not be exercised"
  else:
    var closed = ""
    var finalText = ""
    var stopNote = ""
    # NO pump and no wait: `up` lands before the recorder has written a byte,
    # which is the live sequence (1563 ms held, 0 PCM bytes fed, wav -1 bytes).
    let stopped = pttStop(closed, finalText, stopNote)
    # `heard.final` is emitted by the ROUTE (`onPtt`), not by `pttStop`, and
    # the route cannot be called from here -- the selfcheck already holds the
    # mod lock and it is not reentrant. So what is asserted here is what
    # `pttStop` itself finishes with; `tools/basement_check.py` asserts the
    # `heard.final` half through the real route, where it belongs.
    let sawFinal = closed == "selfcheck-emptyturn"
    let finalWasEmpty = finalText.len == 0
    let sessionGone = not pttActive()
    # The say path must REFUSE an empty utterance with a note, not speak it.
    var directives = 0
    var tagNote = ""
    var spokeAnyway = false
    if personCount() > 0:
      let pid = personId(0)
      let before = latestSeq()
      let d = speakTurn(pid, "", directives, tagNote)
      spokeAnyway = d.text.len > 0 or latestSeq() != before
    emptyOk = stopped and sawFinal and finalWasEmpty and sessionGone and
              not spokeAnyway
    emptyWhy = "`up` " & $stopped & " closed session '" & closed & "' (" &
               $sawFinal & ") with an EMPTY transcript " & $finalWasEmpty &
               ", session gone " & $sessionGone &
               "; an empty utterance was spoken anyway " & $spokeAnyway &
               " (must be false); " & stopNote

  check(15, "ack flag on the wire + the empty push-to-talk turn",
        verdictOf(flagsOk and emptyOk),
        "SERVED ack flags: plain=" & $plainFlag & " (must be 0), needsAck=" &
        $ackFlag & " (must be 1), ttlMs=" & $ackTtl & " (must be 30000); " &
        "torn stream reads " & $streamTornReads() & " (must be 0); " & emptyWhy)

proc chk16BarkCarriesWav() =
  ## An ENCOUNTER-emitted line must arrive with a playable wav.
  ##
  ## MEASURED 2026-09-07: `/say` produced piper wavs while the threat bark
  ## after `player_aimed_at` reached the client as `"wav":""` -- the plugin
  ## logged "(no wav -- TTS is off, missing or failed; the text IS the line)".
  ## Two copies of the say payload had drifted; only one called `ttsSegment`.
  ##
  ## The assertion is on the SERVED event, not on `emitBark`'s return value,
  ## and on the FILE: the wav path in the payload must exist on disk. The
  ## negative control is the `text` -- a payload with a wav and no text would
  ## fail, so this cannot pass by emitting an empty segment.
  ##
  ## With `ttsEngine` none or an absent piper the honest answer is
  ## INCONCLUSIVE with the probe's own note; it is never a PASS.
  if personCount() == 0:
    check(16, "an encounter bark carries a wav", "INCONCLUSIVE",
          "no people in the world to bark at")
    return
  let tp = ttsProbe()
  let pid = personId(0)
  let base = latestSeq()
  var note = ""
  let n = observe("player_aimed_at", pid, "", "{}", note)
  var sayText = ""
  var sayWav = ""
  var sayNote = ""
  var sayTts = ""
  var saySpecTag = ""
  var source = ""
  let served = done(objOf("events", eventsSince(base, 100))).text
  for e in jr.each(jr.field(served, "events")):
    if jr.asText(jr.child(e, "kind"), "") == "say":
      let d = jr.child(e, "data")
      if jr.asText(jr.child(d, "source"), "") == "encounter":
        sayText = jr.asText(jr.child(d, "text"), "")
        sayWav = jr.asText(jr.child(d, "wav"), "")
        sayNote = jr.asText(jr.child(d, "ttsNote"), "")
        sayTts = jr.asText(jr.child(d, "tts"), "")
        saySpecTag = jr.asText(jr.child(jr.child(d, "voiceSpec"), "tag"), "")
        source = "encounter"
  let evidence = "observe emitted " & $n & " directive(s) (" & note &
    "); the served encounter say is text=" & $sayText.len & " chars, wav='" &
    sayWav & "' exists=" & $exists(sayWav) & ", ttsNote=" & sayNote &
    "; tts probe " & tp.engine & " ok=" & $tp.ok & " (" & tp.note & ")"
  if source.len == 0:
    check(16, "an encounter bark carries a wav", "FAIL",
          "no `say` event with source=encounter reached the stream at all. " &
          evidence)
    return
  if not tp.ok:
    check(16, "an encounter bark carries a wav", "INCONCLUSIVE",
          "tts is unavailable, so whether the bark WOULD carry a wav cannot " &
          "be established here -- and a missing engine is never a PASS. " &
          evidence)
    return
  if tp.engine == "client":
    # The served segment must TELL the client to synthesise: tts:"client",
    # the text, and the voiceSpec it maps a voice from. A wav would be wrong.
    check(16, "an encounter bark carries a wav",
          verdictOf(sayText.len > 0 and sayWav.len == 0 and sayTts == "client" and
                    saySpecTag.len > 0),
          "tts=client: served tts='" & sayTts & "' (must be client), voiceSpec.tag='" &
          saySpecTag & "' (must be set), wav='" & sayWav & "' (must be empty). " &
          evidence)
    return
  check(16, "an encounter bark carries a wav",
        verdictOf(sayText.len > 0 and sayWav.len > 0 and exists(sayWav)),
        evidence)

proc countKind(fromSeq: int; kind: string; sayText: var string): int =
  ## How many directives of `kind` reached the stream since `fromSeq`, and the
  ## text of the last encounter-sourced `say` among them. Reading the SERVED
  ## events, not a return value: what the client got is the only fact here.
  result = 0
  let served = done(objOf("events", eventsSince(fromSeq, 200))).text
  for e in jr.each(jr.field(served, "events")):
    if jr.asText(jr.child(e, "kind"), "") == kind:
      result = result + 1
      if kind == "say":
        let d = jr.child(e, "data")
        if jr.asText(jr.child(d, "source"), "") == "encounter":
          sayText = jr.asText(jr.child(d, "text"), "")

proc chk17AimHysteresis() =
  ## FIVE aim reports on one person inside two seconds are ONE threat.
  ##
  ## MEASURED 2026-09-07 in the first SPT 4.1.5 raid: the client reports
  ## `player_aimed_at` every tick the crosshair rests on someone, so the threat
  ## transition re-fired dozens of times -- every person barked the same
  ## sentence over and over and the backend logged ~40 "directive N
  ## (npc.attack) was never acked".
  ##
  ## The assertion is on the SERVED stream, and it has a NEGATIVE CONTROL that
  ## can fail: with the cooldown set to zero a sixth aim MUST bark again. A
  ## check that only asserted "1 say" would also pass if barking were broken
  ## entirely.
  if personCount() == 0:
    check(17, "aim hysteresis", "INCONCLUSIVE", "no people in the world to aim at")
    return
  let pid = personId(0)
  resetEncounters()
  let base = latestSeq()
  var note = ""
  var i = 0
  while i < 5:
    discard observe("player_aimed_at", pid, "", "{}", note)
    i = i + 1
  var barkText = ""
  let says = countKind(base, "say", barkText)
  var ignore = ""
  let attacks = countKind(base, "npc.attack", ignore)
  let stances = countKind(base, "npc.stance", ignore)

  # negative control: no cooldown, a fresh aim must speak again.
  let keep = barkCooldownMs()
  encounterConfigureBarks(0)
  let base2 = latestSeq()
  discard observe("player_aimed_at", pid, "", "{}", note)
  var again = ""
  let says2 = countKind(base2, "say", again)
  encounterConfigureBarks(int(keep))

  let ok = says == 1 and attacks <= 1 and stances == 1 and says2 >= 1
  check(17, "aim hysteresis: five aim reports are one threat", verdictOf(ok),
        "5 x player_aimed_at at " & pid & " within the " &
        $(keep div 1000) & " s cooldown served " & $says & " say (expected 1), " &
        $attacks & " npc.attack (expected at most 1), " & $stances &
        " npc.stance (expected 1); bark=" & barkText &
        " -- NEGATIVE CONTROL with the cooldown at 0: a further aim served " &
        $says2 & " say (expected at least 1), " & again)

proc chk18TalkWhileThreatened() =
  ## A GREETING to a person you are aiming at is a conversation, not a bark.
  ##
  ## MEASURED 2026-09-07: "Hey, how are you doing?" to a threatened person came
  ## back as the threat bark, so the conversation could not move at all. The
  ## assertions are: the greeting is answered from the TABLE (tier ontology),
  ## its text is not the bark this same person just shouted, and it carries no
  ## [ATTACK]. The negative control is the last clause: the same person asked
  ## twice must give the SAME text (the line cache), so "they differ" cannot be
  ## passing merely because something is random.
  if personCount() < 2:
    check(18, "talking to a threatened person", "INCONCLUSIVE",
          "fewer than two people in the world")
    return
  let a = personId(0)
  let b = personId(1)
  resetEncounters()
  var note = ""
  let base = latestSeq()
  discard observe("player_aimed_at", a, "", "{}", note)
  discard observe("player_aimed_at", b, "", "{}", note)
  var barkA = ""
  discard countKind(base, "say", barkA)

  var dirs = 0
  var tagNote = ""
  let d1 = speakTurn(a, "hey there, how are you doing", dirs, tagNote)
  var dirs2 = 0
  var tagNote2 = ""
  let d2 = speakTurn(b, "hey there, how are you doing", dirs2, tagNote2)
  var dirs3 = 0
  var tagNote3 = ""
  let d3 = speakTurn(a, "hey there, how are you doing", dirs3, tagNote3)

  var attacked = false
  for t in d1.tags:
    if t == "ATTACK" or startsWith(t, "ATTACK"): attacked = true
  let notABark = d1.text != barkA and d1.text.len > 0
  let differ = d1.text != d2.text
  let stable = d1.text == d3.text
  let fromTable = d1.tier == "ontology" or d1.tier == "cache"
  let ok = fromTable and notABark and not attacked and differ and stable and
           encounterState(a) == "threatened"
  check(18, "talking to a threatened person answers from the table",
        verdictOf(ok),
        "state=" & encounterState(a) & "; the bark was " & barkA &
        "; the greeting came back tier=" & d1.tier & " text=" & d1.text &
        " tags=" & $d1.tags.len & " attack=" & $attacked &
        "; a SECOND person answered " & d2.text & " (different=" & $differ &
        "); NEGATIVE CONTROL, the same person asked again answered " & d3.text &
        " (identical=" & $stable & ")")

proc chk19DistinctVoices() =
  ## Two people with DIFFERENT voice tags must not sound the same: the same
  ## sentence through two tags yields two wavs whose BYTES differ. Negative
  ## control: the same tag twice is one cache entry, byte-identical. Every
  ## outcome that could not look (engine missing, server absent, only one
  ## piper model on disk) is INCONCLUSIVE with the reason.
  let tp = ttsProbe()
  if voiceTagCount() < 2:
    check(19, "distinct voices", "INCONCLUSIVE",
          "voices.json holds " & $voiceTagCount() & " tags (" & voicesNote() &
          "), so there is no second tag to compare")
    return
  if tp.engine == "none" or tp.engine == "client":
    check(19, "distinct voices", "INCONCLUSIVE",
          "tts=" & tp.engine & " produces no wav here, so bytes cannot be compared")
    return
  if not tp.ok:
    check(19, "distinct voices", "INCONCLUSIVE",
          "tts engine " & tp.engine & " is missing (" & tp.note & ")")
    return
  # Two tags whose resolved model keys differ under THIS engine. With piper
  # and a single .onnx on disk every tag resolves to the same path, and that
  # is reported rather than passed.
  let tagA = voiceTagAt(0)
  var tagB = ""
  var i = 1
  let keyA = voiceModelKey(resolveVoice(tagA, "p-a"), tagA)
  while i < voiceTagCount():
    let t = voiceTagAt(i)
    if voiceModelKey(resolveVoice(t, "p-b"), t) != keyA:
      tagB = t
      break
    i = i + 1
  if tagB.len == 0:
    check(19, "distinct voices", "INCONCLUSIVE",
          "every tag resolves to the same " & tp.engine & " model key '" &
          keyA & "' (one voice on disk?), so no two tags CAN differ")
    return
  let line = "Nobody leaves this basement until I say so."
  var nA = ""
  var cA = false
  let wA = ttsSegment(tagA, line, nA, cA, "p-a")
  var nB = ""
  var cB = false
  let wB = ttsSegment(tagB, line, nB, cB, "p-b")
  var nA2 = ""
  var cA2 = false
  let wA2 = ttsSegment(tagA, line, nA2, cA2, "p-a")
  if wA.len == 0 or wB.len == 0:
    # A server that is not up is "could not look", not a failure of the
    # mapping; the note names the url and the setup command.
    check(19, "distinct voices", "INCONCLUSIVE",
          "no wav for " & (if wA.len == 0: tagA & " (" & nA & ")" else: "") &
          (if wB.len == 0: " " & tagB & " (" & nB & ")" else: ""))
    return
  let bytesA = readAll(wA)
  let bytesB = readAll(wB)
  let bytesA2 = readAll(wA2)
  let differ = bytesA != bytesB and bytesA.len > 44 and bytesB.len > 44
  let same = wA2 == wA and cA2 and bytesA2 == bytesA
  check(19, "distinct voices", verdictOf(differ and same),
        tp.engine & ": " & tagA & " -> " & baseName(wA) & " (" & $bytesA.len &
        " B) vs " & tagB & " -> " & baseName(wB) & " (" & $bytesB.len &
        " B) bytes differ " & $differ & "; " & tagA & " again cache-hit " &
        $cA2 & " identical " & $same & "; " & nA)

proc chk20StreamingParser() =
  ## The property that makes streaming STREAMING: text reaches the caller on a
  ## poll STRICTLY BEFORE the poll that ends the stream. Asserting "the text
  ## came out right" cannot fail differently for the synchronous path, so it
  ## would prove nothing; the poll INDEX is the falsifiable part.
  ##
  ## No curl and no key: a fixture SSE file stands in for the process, revealed
  ## a few bytes per poll, which is exactly how the real file grows.
  let dir = getEnv("TEMP", "")
  if dir.len == 0:
    check(20, "streaming parser", "INCONCLUSIVE",
          "no TEMP in the environment, so no fixture could be written")
    return
  let fixture = joinPath(dir, "aowlbm_selfcheck_stream.sse")
  var sse = ""
  sse.add "data: {\"choices\":[{\"delta\":{\"content\":\"Hold still. \"}}]}\n\n"
  sse.add "data: {\"choices\":[{\"delta\":{\"content\":\"I know a way \"}}]}\n\n"
  sse.add "data: {\"choices\":[{\"delta\":{\"content\":\"out of here.\"}}]}\n\n"
  sse.add "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
  sse.add "data: [DONE]\n\n"
  if not writeAll(fixture, sse):
    check(20, "streaming parser", "INCONCLUSIVE",
          "could not write the fixture to " & fixture)
    return
  let curlBefore = llmCurlCalls()
  llmStreamingConfigure(true, 4, 60000, fixture, false, 60)
  var id = 0
  var snote = ""
  if not llmStreamStart("system", "user", id, snote):
    loadConfig()
    check(20, "streaming parser", "FAIL",
          "llmStreamStart refused the fixture: " & snote)
    return
  var full = ""
  var polls = 0
  var firstTextPoll = -1
  var endPoll = -1
  var fin = false
  while polls < 40 and endPoll < 0:
    polls = polls + 1
    var nt = ""
    var pn = ""
    if not llmStreamPoll(id, nt, fin, pn):
      break
    if nt.len > 0:
      full.add nt
      if firstTextPoll < 0: firstTextPoll = polls
    if fin: endPoll = polls
  llmStreamDrop(id)
  let curlAfter = llmCurlCalls()
  loadConfig()
  let ok = firstTextPoll > 0 and endPoll > firstTextPoll and
           full == "Hold still. I know a way out of here." and
           curlAfter == curlBefore
  check(20, "streaming yields text before the stream ends", verdictOf(ok),
        "first text on poll " & $firstTextPoll & ", stream ended on poll " &
        $endPoll & " (the first must be STRICTLY earlier, or nothing was " &
        "streamed); assembled " & $full.len & " chars = " & full &
        "; curl invocations " & $curlBefore & "->" & $curlAfter &
        " (the fixture must not start a process)")

proc saySurvey(fromSeq: int; person: var string; mode: var string;
               text: var string; audible: var bool; reaction: var bool;
               reactions: var int; others: var int; who: string): int =
  ## Every `say` served since `fromSeq`, reported as the FINISHED STATE of the
  ## stream. `person`/`mode`/`text` are the LAST non-reaction segment, which is
  ## the one a player would call "the answer"; `reactions` and `others` are the
  ## two counts checks 22 and 23 turn on.
  result = 0
  person = ""
  mode = ""
  text = ""
  audible = false
  reaction = false
  reactions = 0
  others = 0
  let served = done(objOf("events", eventsSince(fromSeq, 400))).text
  for e in jr.each(jr.field(served, "events")):
    if jr.asText(jr.child(e, "kind"), "") != "say": continue
    result = result + 1
    let d = jr.child(e, "data")
    let pid = jr.asText(jr.child(d, "personId"), "")
    let isReaction = jr.asBool(jr.child(d, "reaction"), false)
    if isReaction: reactions = reactions + 1
    elif who.len > 0 and pid != who: others = others + 1
    if not isReaction:
      person = pid
      mode = jr.asText(jr.child(d, "mode"), "")
      text = jr.asText(jr.child(d, "text"), "")
      audible = jr.asBool(jr.child(d, "audible"), false)
      reaction = isReaction

proc journalHas(kind: string; n: int): bool =
  ## Is there a row of this kind in the last `n` journal entries? The journal
  ## is the only record a suppressed line leaves, so "it was not said" is
  ## checked HERE and not by the absence of a directive -- an absence is also
  ## what a broken state machine produces.
  let tail = done(objOf("rows", journalTail(n))).text
  for r in jr.each(jr.field(tail, "rows")):
    if jr.asText(jr.child(r, "kind"), "") == kind: return true
  result = false

proc chk21Hearing() =
  ## THE HEARING BANDS. Three distances, three different outcomes, and the
  ## far one must leave a JOURNAL ROW rather than merely nothing.
  ##
  ## The user, 2026-09-07: *"everyone in the vicinity replies even if I can't
  ## hear their reply"*. Before this, all three distances produced the same
  ## audible line.
  if personCount() == 0:
    check(21, "hearing bands", "INCONCLUSIVE", "no people in the world")
    return
  let pid = personId(0)

  resetEncounters()
  encounterConfigureBarks(0)
  noteDistance(pid, 500.0, wallMs())
  let b1 = latestSeq()
  var note = ""
  discard observe("player_aimed_at", pid, "", "{}", note)
  var p1 = ""
  var m1 = ""
  var t1 = ""
  var a1 = false
  var r1 = false
  var rc1 = 0
  var ot1 = 0
  let far = saySurvey(b1, p1, m1, t1, a1, r1, rc1, ot1, pid)
  let farJournaled = journalHas("say.suppressed", 12)

  resetEncounters()
  encounterConfigureBarks(0)
  noteDistance(pid, 45.0, wallMs())
  let b2 = latestSeq()
  discard observe("player_aimed_at", pid, "", "{}", note)
  var p2 = ""
  var m2 = ""
  var t2 = ""
  var a2 = false
  var r2 = false
  var rc2 = 0
  var ot2 = 0
  let mid = saySurvey(b2, p2, m2, t2, a2, r2, rc2, ot2, pid)

  resetEncounters()
  encounterConfigureBarks(0)
  noteDistance(pid, 10.0, wallMs())
  let b3 = latestSeq()
  discard observe("player_aimed_at", pid, "", "{}", note)
  var p3 = ""
  var m3 = ""
  var t3 = ""
  var a3 = false
  var r3 = false
  var rc3 = 0
  var ot3 = 0
  let near = saySurvey(b3, p3, m3, t3, a3, r3, rc3, ot3, pid)

  loadConfig()
  let ok = far == 0 and farJournaled and
           mid >= 1 and m2 == "yell" and a2 and
           near >= 1 and m3 == "speak" and a3 and
           t2 != t3 and t2.len > 0 and t3.len > 0
  check(21, "hearing: 500 m silent, 45 m shouted, 10 m spoken", verdictOf(ok),
        "at 500 m the stream carried " & $far & " say (expected 0) and the " &
        "journal " & (if farJournaled: "DOES" else: "does NOT") &
        " hold a say.suppressed row; at 45 m " & $mid & " say, mode=" & m2 &
        " audible=" & $a2 & " text=" & t2 & "; at 10 m " & $near &
        " say, mode=" & m3 & " audible=" & $a3 & " text=" & t3 &
        " -- the yelled and spoken texts must DIFFER, and they " &
        (if t2 != t3: "do" else: "DO NOT"))

# --- offscreen begin ---
proc livingPersonId(n: int): string =
  ## The n-th LIVING person. `personId(0)` was fine while nothing could die
  ## between the checks; the offscreen engine can now kill someone during
  ## CHECK 3`s six-hour advance, and a check that asks a corpse to speak fails
  ## for a reason that is not the code under test.
  result = ""
  var seen = 0
  var i = 0
  while i < personCount():
    if personAlive(i):
      if seen == n: return personId(i)
      seen = seen + 1
    i = i + 1

proc livingPeople(): int =
  result = 0
  var i = 0
  while i < personCount():
    if personAlive(i): result = result + 1
    i = i + 1
# --- offscreen end ---

proc chk22OneReply() =
  ## ONE utterance, three people in earshot: exactly ONE of them replies.
  ##
  ## The others may bark a REACTION, and the assertion separates the two by
  ## the `reaction` flag on the wire rather than by counting -- a check that
  ## only counted `say` would pass a build where the reply itself had been
  ## turned into a bark. The NEGATIVE CONTROL is the second half: with
  ## `bystanderReactChance` at 0 the same utterance must produce ZERO
  ## reactions, so "3 people were in range" cannot be passing vacuously.
  if livingPeople() < 3:
    check(22, "only the addressee replies", "INCONCLUSIVE",
          "fewer than three LIVING people in the world (" & $livingPeople() &
          " of " & $personCount() & ")")
    return
  let a = livingPersonId(0)
  let b = livingPersonId(1)
  let c = livingPersonId(2)
  resetEncounters()
  # The three of them have to EXIST as encounter rows and have to have a
  # reported distance, and `player_seen` is the one fact that does both. It is
  # done before `base` so their first_sight greetings are not counted as
  # replies -- and, having fired, cannot fire again inside the window below.
  var seen = obj()
  seen.put("distanceM", 5.0)
  var note0 = ""
  discard observe("player_seen", a, "", done(seen).text, note0)
  var seenB = obj()
  seenB.put("distanceM", 8.0)
  discard observe("player_seen", b, "", done(seenB).text, note0)
  var seenC = obj()
  seenC.put("distanceM", 12.0)
  discard observe("player_seen", c, "", done(seenC).text, note0)
  hearingConfigure(0.0, 0.0, 1.0, 1, 0)     # every bystander reacts
  let base = latestSeq()
  var dirs = 0
  var tagNote = ""
  discard speakTurn(a, "hey there, how are you doing", dirs, tagNote)
  var person = ""
  var mode = ""
  var text = ""
  var audible = false
  var reaction = false
  var reactions = 0
  var others = 0
  let total = saySurvey(base, person, mode, text, audible, reaction,
                        reactions, others, a)

  # negative control: nobody reacts.
  resetEncounters()
  discard observe("player_seen", a, "", done(seen).text, note0)
  discard observe("player_seen", b, "", done(seenB).text, note0)
  discard observe("player_seen", c, "", done(seenC).text, note0)
  hearingConfigure(0.0, 0.0, 0.0, 1, 0)
  let base2 = latestSeq()
  var p2 = ""
  var m2 = ""
  var t2 = ""
  var a2 = false
  var r2 = false
  var rc2 = 0
  var ot2 = 0
  discard speakTurn(a, "hey there, how are you doing", dirs, tagNote)
  discard saySurvey(base2, p2, m2, t2, a2, r2, rc2, ot2, a)
  loadConfig()

  let ok = total > 0 and others == 0 and reactions >= 1 and
           person == a and rc2 == 0
  check(22, "one utterance, three in earshot: one reply", verdictOf(ok),
        "the stream carried " & $total & " say: " & $reactions &
        " marked reaction:true and " & $others &
        " NON-reaction segments from somebody other than the addressee " &
        "(expected 0). The reply came from " & person & " (expected " & a &
        "), " & b & " and " & c & " were 8 m and 12 m away. NEGATIVE " &
        "CONTROL with bystanderReactChance 0: " & $rc2 &
        " reactions (expected 0)")

proc chk23Triggers() =
  ## PROACTIVE SPEECH, and the two negatives that make it falsifiable:
  ## a second `player_seen` must be SILENT (first_sight is once per raid), and
  ## a 3 m drift must NOT read as an approach.
  if livingPeople() == 0:
    check(23, "proactive triggers", "INCONCLUSIVE",
          "nobody in the world is alive (" & $personCount() & " rows)")
    return
  let pid = livingPersonId(0)
  var note = ""
  var person = ""
  var mode = ""
  var text = ""
  var audible = false
  var reaction = false
  var reactions = 0
  var others = 0

  resetEncounters()
  var so = obj()
  so.put("distanceM", 20.0)
  let seen1 = done(so).text
  let b1 = latestSeq()
  discard observe("player_seen", pid, "", seen1, note)
  let first = saySurvey(b1, person, mode, text, audible, reaction,
                        reactions, others, pid)
  let firstText = text

  # negative: seen again, same distance -> nothing.
  let b2 = latestSeq()
  discard observe("player_seen", pid, "", seen1, note)
  let second = saySurvey(b2, person, mode, text, audible, reaction,
                         reactions, others, pid)

  # a 3 m drift is not an approach.
  var s3 = obj()
  s3.put("distanceM", 17.0)
  let b3 = latestSeq()
  discard observe("player_seen", pid, "", done(s3).text, note)
  let drift = saySurvey(b3, person, mode, text, audible, reaction,
                        reactions, others, pid)

  # a 12 m drop in one step is.
  var s4 = obj()
  s4.put("distanceM", 5.0)
  let b4 = latestSeq()
  discard observe("player_seen", pid, "", done(s4).text, note)
  let closed = saySurvey(b4, person, mode, text, audible, reaction,
                         reactions, others, pid)

  let ok = first >= 1 and second == 0 and drift == 0 and closed >= 1
  check(23, "first_sight once per raid; approach needs 10 m in 3 s",
        verdictOf(ok),
        "first player_seen at 20 m served " & $first & " say (expected >=1): " &
        firstText & "; the SECOND at the same distance served " & $second &
        " (expected 0 -- first_sight is once per raid); a 3 m drift to 17 m " &
        "served " & $drift & " (expected 0); a 12 m drop to 5 m served " &
        $closed & " (expected >=1): " & text)

# --- offscreen begin ---
proc chk24Offscreen() =
  ## (a)-(e) come from `bm/offscreen.offscreenChecks`, which lives next to the
  ## engine so the two cannot drift. (f) and (g) are here because they need the
  ## scene builder and the dialogue tiers, which this file owns.
  for r in offscreenChecks(joinPath(gPresetDir, "warlords.json")):
    var parts: seq[string] = @[]
    var cur = ""
    for ch in r:
      if ch == '\x1f':
        parts.add cur
        cur = ""
      else:
        cur.add ch
    parts.add cur
    if parts.len == 3: check(24, parts[1], parts[0], parts[2])
    else: check(24, "offscreen: a check row was malformed", "FAIL", r)

  # (f) the scene on the player`s map lists a group AND its objective.
  var mapWithGroups = ""
  discard rebuildGroups()
  var gi = 0
  while gi < groupCount():
    if mapWithGroups.len == 0 and activeObjectiveOf(groupId(gi)) >= 0:
      mapWithGroups = groupMap(gi)
    gi = gi + 1
  if mapWithGroups.len == 0:
    check(25, "offscreen: world/scene carries a group objective", "INCONCLUSIVE",
          "no group in the generated world holds an objective, so there is " &
          "nothing for a scene to carry")
  else:
    var gx = 0.0
    var gy = 0.0
    var gz = 0.0
    groupPos(0, gx, gy, gz)
    let scene = done(sceneJson(mapWithGroups, gx, gy, gz, 4000.0)).text
    let hasObjective = find(scene, "\"objective\"") >= 0
    let hasSentence = find(scene, "\"sentence\"") >= 0
    let hasGoto = find(scene, "npc.goto") >= 0
    check(25, "offscreen: world/scene on the player`s map carries each group`s objective",
          verdictOf(hasObjective and hasSentence),
          "the scene on " & mapWithGroups & " is " & $scene.len &
          " bytes; it names an objective " & $hasObjective &
          ", a person`s objective sentence " & $hasSentence &
          ", and an npc.goto order toward the objective target " & $hasGoto &
          " (npc.goto is absent when every group is already standing on its " &
          "target, which is a real answer and not a failure)")

  # (g) asked what they are doing, a person answers about their objective --
  #     from the ontology TABLE, no model. The negative control is the person
  #     with no objective: the row must be REFUSED, not served empty.
  var who = -1
  var none = -1
  var pi = 0
  while pi < personCount():
    var k = ""
    var t = ""
    var r2 = ""
    if objectiveOfPerson(pi, k, t, r2):
      if who < 0: who = pi
    elif none < 0:
      none = pi
    pi = pi + 1
  if who < 0:
    check(26, "offscreen: a person answers about their objective", "INCONCLUSIVE",
          "nobody in the generated world is inside an objective")
  else:
    var conf = 0.0
    let intent = classifyIntent("what are you doing", conf)
    let card = cardFor(personId(who))
    let sit = situationFor(personId(who))
    var reply = ""
    var tags: seq[string] = @[]
    let served = ontologyReply(intent, card, sit, "what are you doing", reply, tags)
    let sentence = objectiveSentence(who)
    var mentions = false
    if sentence.len > 0 and reply.len > 0:
      if find(reply, sentence) >= 0: mentions = true
    var refusedForNone = true
    var noneNote = "no objective-less person exists to use as a control"
    if none >= 0:
      var reply2 = ""
      var tags2: seq[string] = @[]
      let card2 = cardFor(personId(none))
      let sit2 = situationFor(personId(none))
      refusedForNone = not ontologyReply(intent, card2, sit2,
                                         "what are you doing", reply2, tags2)
      noneNote = personName(none) & " has no objective and the row was " &
                 (if refusedForNone: "REFUSED (correct)"
                  else: "SERVED anyway: " & reply2)
    check(26, "offscreen: asked what they are doing, a person answers about their objective",
          verdictOf(served and mentions and refusedForNone),
          "intent classified as " & intent & " (confidence " & fmtF(conf) &
          "); " & personName(who) & " answered: " & reply &
          " -- their objective clause is [" & sentence &
          "] and the reply contains it " & $mentions & "; control: " & noneNote)
# --- offscreen end ---

proc onSelfcheck(url, body, session: string): string =
  gCheckLines = @[]
  gPassN = 0
  gFailN = 0
  gIncN = 0
  withModLock:
    chk1Determinism()
    chk2Persistence()
    chk3CatchUp()
    chk4BrainTiers()
    chk5Encounter()
    chk6Stream()
    chk7Engines()
    chk8Speech()
    chk9TagGrammar()
    chk10Plant()
    chk11Claim()
    chk12KnownIds()
    chk13LootBus()
    chk14PushToTalk()
    chk15AckFlagAndEmptyTurn()
    chk16BarkCarriesWav()
    chk17AimHysteresis()
    chk18TalkWhileThreatened()
    chk19DistinctVoices()
    chk20StreamingParser()
    chk21Hearing()
    chk22OneReply()
    chk23Triggers()
    # --- offscreen begin ---
    chk24Offscreen()
    # --- offscreen end ---
    # Put back whatever was on disk: the checks above generated and advanced a
    # world in memory, and leaving that in place would quietly replace the
    # player's.
    var restoreNote = ""
    if not loadWorld(restoreNote):
      gCheckLines.add "NOTE: no saved world to restore after the selfcheck (" &
                      restoreNote & ")"
    resetEncounters()
  var verdict = "PASS"
  if gFailN > 0: verdict = "FAIL"
  elif gIncN > 0: verdict = "INCONCLUSIVE"
  var lines = arr()
  var text = ""
  for l in gCheckLines:
    lines.add l
    text.add l
    text.add "\n"
  text.add "SELFCHECK VERDICT " & verdict
  var o = obj()
  o.put("ok", gFailN == 0)
  o.put("verdict", verdict)
  o.put("pass", gPassN)
  o.put("fail", gFailN)
  o.put("inconclusive", gIncN)
  o.put("checks", lines)
  o.put("text", text)
  result = done(o).text

# ---------------------------------------------------------------------------
# F12 settings
# ---------------------------------------------------------------------------

proc basementSchema(): seq[Setting] =
  result = @[
    boolSetting("enabled", "Enable Escape From My Basement", false,
                category = "General",
                description = "Off by default: turning it on lets this mod " &
                  "spawn whisper/piper subprocesses, write a persistent " &
                  "world, and call a paid API when llmEngine is not builtin"),
    stringSetting("preset", "World preset", "warlords", category = "World",
                  description = "An id under data/presets: warlords, " &
                    "quiet_apocalypse, cult_of_the_reactor, the_long_road, sandbox"),
    intSetting("seed", "World seed", 0, lo = 0, hi = 2000000000, step = 1,
               category = "World",
               description = "0 = pick one from the wall clock; the seed " &
                 "actually used is stored in the world and shown on /status"),
    stringSetting("worldPrompt", "World prompt override", "", category = "World",
                  description = "Empty = the preset's own prompt. This is the " &
                    "top of every system prompt: what this world IS"),
    enumSetting("llmEngine", "Reasoning", "builtin",
                @["builtin", "anthropic", "openai", "llamacpp", "none"],
                category = "Engines",
                description = "builtin is the ontology's fallback row and is " &
                  "NOT a language model; anthropic needs ANTHROPIC_API_KEY in " &
                  "the environment, never in config"),
    stringSetting("anthropicModel", "Anthropic model", "claude-opus-5",
                  category = "Engines"),
    intSetting("maxTokens", "Reply length (tokens)", 200, lo = 32, hi = 4096,
               step = 1, category = "Engines"),
    boolSetting("llmStreaming", "Speak while the model is still writing", true,
                category = "Engines",
                description = "On: curl is spawned detached and each sentence " &
                  "is spoken the moment it completes, so /say answers with a " &
                  "receipt and the segments arrive on the event stream. Off: " &
                  "the old synchronous shape -- one reply, after the whole " &
                  "response has arrived (~4 s on gpt-4o-mini, MEASURED)"),
    intSetting("maxTurnsInFlight", "Streaming turns at once", 4, lo = 1,
               hi = 32, step = 1, category = "Engines",
               description = "A turn beyond this bound is answered " &
                 "synchronously rather than queued or dropped"),
    intSetting("turnTimeoutMs", "Streaming turn timeout (ms)", 60000,
               lo = 1000, hi = 600000, step = 1000, category = "Engines",
               description = "A turn whose stream never ends speaks the " &
                 "ontology's fallback line and says in its note that it " &
                 "timed out -- it is never mistaken for a short reply"),
    enumSetting("sttEngine", "Speech to text", "whisper-server",
                @["whisper-server", "openai-whisper", "none"],
                category = "Engines",
                description = "openai-whisper = any OpenAI-compatible " &
                  "/audio/transcriptions endpoint, which is how Groq's " &
                  "whisper-large-v3-turbo is reached (MEASURED 2026-09-07: " &
                  "0.53 s round trip for a 42 KB wav)"),
    stringSetting("openAiBaseUrl", "OpenAI-compatible chat base URL", "",
                  category = "Engines",
                  description = "Empty = https://api.openai.com/v1. Groq " &
                    "serves the identical chat + SSE shapes at " &
                    "https://api.groq.com/openai/v1"),
    stringSetting("openAiKeyEnv", "Env var holding the chat key", "",
                  category = "Engines",
                  description = "Empty = OPENAI_API_KEY. This NAMES a " &
                    "variable; the key itself is never read from config.json " &
                    "or from source"),
    stringSetting("openAiExtraJson", "Extra chat request fields", "",
                  category = "Engines",
                  description = "A raw JSON fragment WITHOUT braces spliced " &
                    "into the request, e.g. \"reasoning_effort\":\"low\". " &
                    "MEASURED 2026-09-07 on Groq openai/gpt-oss-120b: without " &
                    "it the model spent max_tokens on a `reasoning` field and " &
                    "the spoken content came back empty at 80 tokens; with it " &
                    "reasoning fell 487 -> 57 chars. Real OpenAI would 400 on " &
                    "that field, which is why it is configuration"),
    stringSetting("sttBaseUrl", "Cloud STT base URL", "", category = "Engines"),
    stringSetting("sttKeyEnv", "Env var holding the STT key", "",
                  category = "Engines"),
    stringSetting("sttModel", "Cloud STT model", "", category = "Engines",
                  description = "Empty = whisper-large-v3-turbo"),
    stringSetting("ttsBaseUrl", "Cloud TTS base URL", "", category = "Engines"),
    stringSetting("ttsKeyEnv", "Env var holding the TTS key", "",
                  category = "Engines"),
    stringSetting("ttsModel", "Cloud TTS model", "", category = "Engines",
                  description = "Empty = canopylabs/orpheus-v1-english"),
    enumSetting("ttsEngine", "Text to speech", "piper",
                @["piper", "kokoro", "chatterbox", "openai-tts", "client",
                  "sapi", "none"],
                category = "Engines",
                description = "kokoro = local CPU (onnx), chatterbox = local " &
                  "CUDA voice cloning from data/voices/*.wav, client = the " &
                  "game-side plugin synthesises (no wav from here)"),
    boolSetting("ttsAsync", "Synthesise off the tick", true,
                category = "Engines",
                description = "kokoro/chatterbox only: the request is spawned " &
                  "detached and the segment is emitted when the wav lands, so " &
                  "the mod lock is never held across a network call. MEASURED " &
                  "2026-09-07 with it OFF: one kokoro sentence blocked every " &
                  "route for ~1.3 s and a 5-sentence turn timed an /events " &
                  "long-poll out. piper and sapi are subprocesses we run to " &
                  "completion and stay synchronous whatever this says"),
    intSetting("ttsTimeoutMs", "Bounded wait for a wav (ms)", 8000,
               lo = 500, hi = 120000, step = 500, category = "Engines",
               description = "After this the segment is emitted WITHOUT audio " &
                 "and the note says the wait was given up on -- the client " &
                 "shows the subtitle. The request is still watched, so a late " &
                 "wav still fills the cache"),
    enumSetting("spawnMode", "How a detached process is started", "process",
                @["process", "powershell"], category = "Engines",
                description = "process = CreateProcess directly (MEASURED " &
                  "2026-09-07: ~1 ms). powershell = Start-Process (~200 ms " &
                  "idle, 300-500 ms on the live sidecar). cmd /c start is NOT " &
                  "offered: it hung our own runCmd for the child's full " &
                  "lifetime, 10110 ms, measured"),
    stringSetting("toolsDir", "Tools directory", "", category = "Paths",
                  description = "Holds whisper/ and piper/"),
    floatSetting("leashM", "Captivity leash (m)", 25.0, lo = 5.0, hi = 200.0,
                 category = "Encounters",
                 description = "How far a prisoner may stray before it is an " &
                   "escape attempt"),
    floatSetting("noticeM", "Notice range (m)", 60.0, lo = 5.0, hi = 500.0,
                 category = "Encounters"),
    floatSetting("threatM", "Threat range (m)", 18.0, lo = 1.0, hi = 200.0,
                 category = "Encounters"),
    intSetting("barkCooldownMs", "Threat bark cooldown (ms)", 20000, lo = 0,
               hi = 600000, step = 1000, category = "Encounters",
               description = "How long a person stays barked-out. The client " &
                 "reports player_aimed_at every tick the crosshair rests on " &
                 "someone; within this window that is counted, not re-barked, " &
                 "and no second npc.attack or npc.stance is emitted"),
    intSetting("pttMaxSeconds", "Push-to-talk max (s)", 20, lo = 1, hi = 600,
               step = 1, category = "Engines",
               description = "The recorder is spawned with this bound and " &
                 "CANNOT be interrupted from here (its stop protocol is a " &
                 "line on stdin and a detached spawn has no stdin), so key-up " &
                 "transcribes what is on disk at that moment"),
    intSetting("maxTurns", "Conversation memory (turns)", 8, lo = 0, hi = 64,
               step = 1, category = "Dialogue"),
    intSetting("cacheMaxEntries", "Cached lines", 512, lo = 0, hi = 100000,
               step = 1, category = "Cache"),
    intSetting("streamMax", "Directive ring size", 2048, lo = 64, hi = 65536,
               step = 1, category = "Stream"),
    intSetting("maxWaitMs", "Long-poll cap (ms)", 2000, lo = 0, hi = 25000,
               step = 1, category = "Stream",
               description = "The wait is a bounded poll on the request " &
                 "thread; the mod SDK has no sleep primitive yet"),
    intSetting("tickMs", "Backend tick (ms)", 1000, lo = 100, hi = 60000,
               step = 1, category = "Stream"),
    boolSetting("autoRaidRequests", "Ask autoraid to place the player", false,
                category = "Client", implemented = false,
                description = "Emits basement.raid.request on /spawn. " &
                  "mods/autoraid does not consume it yet (DESIGN.md §10)")]

proc onSettings(url, body, session: string): string =
  if body.len > 0 and applySettingFromBody(body) == Ok:
    loadConfig()
  result = declaredSchemaJson().text

# ---------------------------------------------------------------------------
# Events in, tick, lifecycle
# ---------------------------------------------------------------------------

proc onProfileListing(payload: string): string =
  ## `tarkov.profile.listing` carries the session the game websocket is keyed
  ## on; once known, every directive is ALSO pushed with notifyPush.
  var s = jr.asText(jr.field(payload, "session"), "")
  if s.len == 0: s = jr.asText(jr.field(payload, "sessionId"), "")
  if s.len == 0: s = jr.asText(jr.field(payload, "id"), "")
  if s.len > 0:
    setPushSession(s)
    info ModName & ": push session is " & s &
         (if notifyReady(): " (notifyPush available)"
          else: " (the host has no notifyPush; the client must poll /events)")
  result = ""

proc onRaidConfigured(payload: string): string =
  let map = jr.asText(jr.field(payload, "location"),
                      jr.asText(jr.field(payload, "map"), ""))
  var note = ""
  withModLock:
    discard observe("raid_started", "", "", payload, note)
  info ModName & ": raid configured on '" & map & "': " & note
  result = ""

proc onDirectiveDropped(seqNo: int; kind: string) =
  discard journal("directive.dropped", "", "",
                  done(objOf("kind", kind)).text)
  warn ModName & ": directive " & $seqNo & " (" & kind & ") was never acked " &
       "and passed its ttl -- the client is not executing directives"

proc onTick(payload: string): string =
  gTicks = gTicks + 1
  let tickT0 = nowMs()
  var note = ""
  withModLock:
    discard observe("tick", "", "", "{}", note)
    var dropped: seq[int] = @[]
    discard expirePending(worldClockMs(), dropped)
    var simNote = ""
    discard simAdvance(int64(gTickMs), simNote)
    pumpStreamingTurns()
    # Both are pure memory/stat work: `sayDrain` emits the segments whose wav
    # has appeared on disk and `ttsPumpLate` files the ones that arrived after
    # their bounded wait. Neither opens a socket or waits on a process, which
    # is the whole point -- the lock is held across reads, never across I/O.
    discard sayDrain()
    discard ttsPumpLate()
    if pttActive():
      # The progressive half of push-to-talk. Pumping every tick is free: the
      # session only runs whisper once `sttPartialMs` of NEW audio has arrived.
      var pttPartial = ""
      var pttNote = ""
      discard pttPump(pttPartial, pttNote)
      if pttPartial.len > 0:
        discard emitEvent("heard.partial",
                          done(objOf("text", pttPartial)).text, false)
    if gSaveEveryTicks > 0 and (gTicks mod gSaveEveryTicks) == 0:
      var saveNote = ""
      if saveWorld(saveNote):
        discard emitEvent("world.saved",
                          done(objOf("version", worldVersion())).text, false)
  gTickLastMs = nowMs() - tickT0
  if gTickLastMs > gTickMaxMs:
    gTickMaxMs = gTickLastMs
    gTickSlowest = "tick " & $gTicks & " took " & $gTickLastMs &
                   " ms (streams in flight " & $brainStreamCount() &
                   ", say queue " & $sayQueueDepth() & ", tts pending " &
                   $ttsPendingCount() & ")"
  if gTickLastMs > int64(gTickSlowMs): gTickSlowN = gTickSlowN + 1
  result = ""

proc onDebugTick(url, body, session: string): string =
  ## The sim runs every route BEFORE it runs a single tick, so without this
  ## there is no way to drive the streaming parser offline at all. Gated twice
  ## (`enabled` and `debugTickRoute`) and it does exactly what the timer does:
  ## it calls `onTick`, it does not reimplement it.
  if not gEnabled: return disabledJson()
  if not gDebugTickRoute:
    return errJson("the debug tick route is off; set \"debugTickRoute\": " &
                   "true in mods/basement/config.json. It exists so the " &
                   "offline checks can drive the tick, and it is not " &
                   "something a client should ever call")
  var n = queryInt(url, "n", jr.asInt(jr.field(body, "n"), 1))
  if n < 1: n = 1
  if n > 1000: n = 1000
  var i = 0
  while i < n:
    discard onTick("")
    i = i + 1
  var o = obj()
  o.put("ok", true)
  o.put("ticks", n)
  o.put("totalTicks", gTicks)
  o.put("streamsInFlight", brainStreamCount())
  o.put("turnsFinished", gTurnsFinished)
  result = done(o).text

# --- spt begin (docs/SPT415-BOT-CONTROL.md section 4: Basement.Server's two routes) ---
proc onSptBots(url, body, session: string): string =
  ## Basement.Server (SPT 4.1.5) asks once per /client/game/bot/generate.
  ## Same brain, same rows as tarkov.bots.compose; `requested` is the client's
  ## own {role, limit, difficulty} list and every group is re-keyed onto one
  ## of those roles (a "guard" is an "assault" to SPT). `limits` is left out:
  ## SPT keeps the client's counts unless the world decides otherwise.
  if not gEnabled: return disabledJson()
  var map = jr.asText(jr.field(body, "map"), "")
  if map.len == 0: map = queryValue(url, "map")
  let raidId = jr.asText(jr.field(body, "raidId"), "")
  if map.len == 0:
    return errJson("no `map`: POST " & SptBotsRoute & " {map, raidId, wave, requested:[{role,limit,difficulty}]}")
  var firstRole = "assault"
  var requestedRoles: seq[string] = @[]
  let reqJ = jr.field(body, "requested")
  for i in 0 ..< jr.count(reqJ):
    let role = jr.asText(jr.field(jr.at(reqJ, i), "role"), "")
    if role.len > 0:
      requestedRoles.add role
      if requestedRoles.len == 1: firstRole = role
  var text = ""
  withModLock:
    text = composeBotsPlant(raidId, map)
  # Re-key: a group whose role is not one the client asked for is served under
  # the first requested role, and its basement role survives as `factionRole`.
  var groups = arr()
  let groupsJ = jr.field(text, "groups")
  for gi in 0 ..< jr.count(groupsJ):
    let g = jr.at(groupsJ, gi)
    var go = obj()
    let role = jr.asText(jr.field(g, "role"), "")
    var known = false
    for r in requestedRoles:
      if r == role: known = true
    go.put("groupId", jr.asText(jr.field(g, "groupId"), ""))
    go.put("factionId", jr.asText(jr.field(g, "factionId"), ""))
    go.put("factionRole", role)
    go.put("role", if known: role else: firstRole)
    go.put("count", jr.asInt(jr.field(g, "count"), 0))
    var names = arr()
    let namesJ = jr.field(g, "names")
    for ni in 0 ..< jr.count(namesJ):
      names.add jr.asText(jr.at(namesJ, ni), "")
    go.put("names", names)
    go.put("x", jr.asFloat(jr.field(g, "x"), 0.0))
    go.put("y", jr.asFloat(jr.field(g, "y"), 0.0))
    go.put("z", jr.asFloat(jr.field(g, "z"), 0.0))
    groups.add go
  var o = obj()
  o.put("ok", true)
  o.put("raidId", raidId)
  o.put("map", map)
  o.put("wave", jr.asInt(jr.field(body, "wave"), 0))
  o.put("groups", groups)
  gBotsComposeN = gBotsComposeN + 1
  result = done(o).text

proc onSptWaves(url, body, session: string): string =
  ## Stub until the world model owns waves: `ok:false` tells Basement.Server
  ## to keep SPT's stock waves for this raid, and says why on the SPT log.
  ## When it is real, `waves`/`bossWaves` carry EFT-native rows exactly as in
  ## locations/<map>/base.json (Wave: BotPreset, BotSide, SpawnPoints=zone,
  ## WildSpawnType, slots_min/max, time_min/max; BossLocationSpawn: BossName,
  ## BossZone, BossChance, Time, Delay, ...).
  if not gEnabled: return disabledJson()
  let map = queryValue(url, "map")
  var o = obj()
  o.put("ok", false)
  o.put("map", map)
  o.put("clear", false)
  o.put("note", "no wave plan for `" & map & "`: the basement world does not decide waves yet; SPT's own waves stand")
  result = done(o).text
# --- spt end ---

proc onLoad(): Status =
  declareSettings(basementSchema())
  if side() == sideClient:
    # The CLIENT HALF: the thin bridge of CLIENT-CONTRACT.md / BRIDGE-AOWLSPT.md.
    # It never reasons; it long-polls /events through `aowlspt.host::http`,
    # plays `say` segments through `aowlspt.host::play_wav`, hands the next
    # map to mods/autoraid at MENU, and reports raid facts. Every missing host
    # verb or OFF flag is refused ONCE, by name, and the half stays inert.
    info ModName & ": client side -- starting the bridge (server routes do " &
         "not exist here)"
    return bridgeInit()
  loadConfig()

  var parts: seq[string] = @[]

  # Generation REFUSES with a note when the name and archetype tables are not
  # loaded, so they are loaded here before anything can ask for a world -- and
  # a zero count is reported rather than left to look like an empty world.
  let namesN = loadNames(readAll(joinPath(dataDir(), "names.json")))
  let archN = loadArchetypes(readAll(joinPath(dataDir(), "archetypes.json")))
  let voicesN = voicesLoad(readAll(joinPath(dataDir(), "voices.json")))
  if voicesN == 0:
    warn ModName & ": data/voices.json did not load from " & dataDir() &
         " (" & voicesNote() & ") -- every person's voice will be a hash " &
         "pick from an EMPTY pool, i.e. the engine default"
  parts.add $namesN & " names"
  parts.add $archN & " archetypes"
  if namesN == 0 or archN == 0:
    warn ModName & ": data/names.json or data/archetypes.json did not load " &
         "from " & dataDir() & " -- POST " & WorldNewRoute & " will refuse " &
         "rather than generate a world of nameless people"

  var ontNote = ""
  let ontText = readAll(joinPath(dataDir(), "ontology.json"))
  if ontText.len == 0:
    parts.add "ontology.json missing or empty"
  elif ontologyLoad(ontText, ontNote):
    parts.add $ontologyIntentCount() & " intents / " & $ontologyRowCount() & " rows"
  else:
    parts.add "ontology.json did not load: " & ontNote
  # The item resolver: kind words from data, templates from whatever database
  # this host loaded. Both halves report a COUNT, because "0 templates" and
  # "no database" are different answers and only one of them is a problem.
  itemsConfigure(readAll(joinPath(dataDir(), "lootkinds.json")))
  parts.add "lootkinds: " & itemsDataNote()
  var itemNote = ""
  let itemN = itemsIndexBuild(itemNote)
  parts.add "items: " & itemNote
  if itemN == 0:
    info ModName & ": no item index (" & itemNote & ") -- caches will still " &
         "be created with their story and their guards, and every resolve " &
         "will say INCONCLUSIVE rather than report an empty cache"

  var cacheNote = ""
  brainLoadCache(cacheNote)
  parts.add "brain cache: " & cacheNote
  parts.add $listPresets(gPresetDir).len & " presets"
  gLoadNote = joinWith(parts, ", ")

  setDropSink(onDirectiveDropped)

  # Catch-up on load: the world kept going while the process was not running.
  var loadNote = ""
  if loadWorld(loadNote):
    var catchNote = ""
    let changes = simCatchUp(catchNote)
    gWorldNote = "loaded version " & $worldVersion() & " (" & loadNote &
                 "), caught up " & $changes & " changes: " & catchNote
  else:
    gWorldNote = "no saved world: " & loadNote & " -- POST " & WorldNewRoute

  discard serve("/aowlspt/settings/" & ModGuid, onSettings)
  discard serve(StatusRoute, onStatus)
  discard serve(PresetsRoute, onPresets)
  discard serve(WorldNewRoute, onWorldNew)
  discard serve(SaveRoute, onSave)
  discard serve(AdvanceRoute, onAdvance)
  discard servePrefix(PeopleRoute, onPeople)
  discard servePrefix(PersonRoute, onPerson)
  discard servePrefix(SceneRoute, onScene)
  discard servePrefix(LootRoute, onLoot)
  discard servePrefix(CachesRoute, onCaches)
  # --- offscreen begin ---
  discard servePrefix(RegionsRoute, onRegions)
  # --- offscreen end ---
  discard servePrefix(WorldRoute, onWorld)
  discard serve(ObserveRoute, onObserve)
  discard serve(SayRoute, onSay)
  discard serve(ChunkRoute, onChunk)
  discard serve(PttRoute, onPtt)
  discard servePrefix(EventsRoute, onEvents)
  discard serve(AckRoute, onAck)
  discard serve(SpawnRoute, onSpawn)
  discard serve(SptBotsRoute, onSptBots)
  discard servePrefix(SptWavesRoute, onSptWaves)
  discard serve(SelfcheckRoute, onSelfcheck)
  if gDebugTickRoute: discard serve(TickRoute, onDebugTick)

  discard on("tarkov.profile.listing", onProfileListing)
  discard on("tarkov.raid.configured", onRaidConfigured)
  discard on("tarkov.loot.compose", onLootCompose)
  discard on("tarkov.bots.compose", onBotsCompose)
  discard on("tarkov.loot.taken", onLootTakenEvent)

  if gEnabled:
    # THE DEBUG TICK ROUTE OWNS THE CLOCK. With both the timer and the route
    # running, `drainWork()` in aowlspt-sim fires a tick BETWEEN two routes
    # whenever more than `tickMs` of wall time has passed -- MEASURED
    # 2026-09-07: `/tick n=1` answered `totalTicks:2, streamsInFlight:1` and
    # the very next `/events` already carried the finished turn, because a
    # background tick had run in between. The offline streaming check reads
    # the tick's counter and the stream and compares them, so that race made
    # it report a segment "spoken after the stream ended" that had in fact
    # been spoken before it. A check driving the tick explicitly must be the
    # ONLY thing driving it; this flag is off in every real deployment.
    if gDebugTickRoute:
      info ModName & ": the periodic tick is OFF because debugTickRoute is " &
           "on -- POST " & TickRoute & " is the only clock in this process"
    else:
      discard everyMs(gTickMs, onTick)
    success ModName & " " & ModVersion & " on: " & gLoadNote & " | " & gWorldNote
    let lp = llmProbe()
    if not lp.ok:
      warn ModName & ": reasoning engine '" & lp.engine & "' is " & lp.note &
           " -- replies will come from the ontology/builtin tier, which is " &
           "NOT a language model. GET " & StatusRoute & " for the paths."
  else:
    info ModName & " " & ModVersion & " loaded but DISABLED (" & gLoadNote &
         "). Set \"enabled\": true in mods/basement/config.json, then GET " &
         StatusRoute
  Ok

proc onUpdate(elapsedMs: int64): Status =
  ## Only the client half ticks here; the server half runs on `everyMs`.
  if side() == sideClient:
    bridgeTick(elapsedMs)
  Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideServer, sideClient, sideSim},
  onLoad = onLoad,
  onUpdate = onUpdate)
