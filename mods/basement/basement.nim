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
import "bm" / sim
import "bm" / encounter
import "bm" / prompt
import "bm" / ontology
import "bm" / llm
import "bm" / brain
import "bm" / speech
import "bm" / stream

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
  EventsRoute    = Base & "/events"
  AckRoute       = Base & "/ack"
  SpawnRoute     = Base & "/spawn"
  SelfcheckRoute = Base & "/selfcheck"

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

proc presetDir(): string = joinPath(dataDir(), "presets")

proc joinWith(items: seq[string]; sep: string): string =
  ## nimony's strutils has no `join`.
  result = ""
  var i = 0
  while i < items.len:
    if result.len > 0: result.add sep
    result.add items[i]
    i = i + 1

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
  streamConfigure(maxEvents = setting("streamMax").asInt(2048),
                  defaultTtlMs = int64(setting("directiveTtlSeconds").asInt(30)) * 1000)
  setSimConfig(maxCatchUpMs = int64(setting("simMaxCatchUpHours").asInt(24)) * 3600000,
               moveEveryMs = int64(setting("simMoveEveryMinutes").asInt(20)) * 60000,
               ambushChance = setting("ambushChance").asFloat(0.15))

  let tools = setting("toolsDir").asText("")
  var work = setting("workDir").asText("")
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
                  sttPartialMs = setting("sttPartialMs").asInt(1200))
  brainConfigure(cacheDir = cache,
                 cacheMax = setting("cacheMaxEntries").asInt(512),
                 memoryTurns = setting("maxTurns").asInt(8),
                 ontologyMinConfidence = setting("ontologyMinConfidence").asFloat(0.6))

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
  var saveNote = ""
  discard saveWorld(saveNote)
  gWorldNote = "generated seed " & $int64(s) & " preset " & presetId &
               ": " & genNote
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
  var ttsNote = ""
  var cached = false
  var wav = ""
  if sentence.len > 0:
    wav = ttsSegment(gSayVoice, sentence, ttsNote, cached)
    gSaySegments.add sentence
    gSayWavs.add wav
  var o = obj()
  o.put("personId", gSayPerson)
  o.put("text", sentence)
  o.put("wav", wav)
  o.put("segmentIdx", gSegmentIdx)
  o.put("final", final)
  o.put("cachedWav", cached)
  o.put("source", "brain")
  discard emitEvent("say", done(o).text, false)
  discard broadcast("basement.say", done(o))
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
  o.put("state", encounterState(personId))
  o.put("notes", notes)
  result = done(o).text

proc speakTurn(personId, utterance: string; directives: var int;
               tagNote: var string): Decision =
  ## The one path. `/say` calls it; the selfcheck calls it; nothing else has a
  ## second copy of this order.
  let pi = findPerson(personId)
  gSayPerson = personId
  gSayVoice = (if pi >= 0: personVoice(pi) else: "")
  gSegmentIdx = 0
  gSaySegments = @[]
  gSayWavs = @[]
  let card = cardFor(personId)
  let situation = situationFor(personId)
  var hits = ""
  let facts = retrieveFacts(utterance, card.traits, 4, hits)
  let memory = (if pi >= 0: memoryOf(pi, 8) else: "")
  result = decide(worldPrompt(), worldName(), card, situation,
                  memory, facts, utterance, saySink)
  if pi >= 0:
    remember(pi, "Player: " & utterance)
    if result.text.len > 0: remember(pi, personName(pi) & ": " & result.text)
  directives = applyTags(personId, result.tags, tagNote)
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
  o.put("world", worldSummary())
  o.put("brain", brainStats())
  o.put("stream", streamStats())
  o.put("tts", ttsStats())
  o.put("sttSessions", sttSessionCount())
  o.put("pushSession", pushSession())
  o.put("encounters", encounterJson())
  o.put("leashM", leashM())
  o.put("presetDir", gPresetDir)
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
  withModLock:
    ok = newWorld(presetId, seed, po, note)
  var o = obj()
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
                   ms: 0, notes: @[], segments: @[])
  withModLock:
    d = speakTurn(personId, text, directives, tagNote)
  result = sayReplyJson(personId, d, tagNote, directives)

proc onChunk(url, body, session: string): string =
  if not gEnabled: return disabledJson()
  let sess = jr.asText(jr.field(body, "session"), session)
  let seqNo = jr.asInt(jr.field(body, "seq"), 0)
  let path = jr.asText(jr.field(body, "path"), "")
  let b64 = jr.asText(jr.field(body, "wavBase64"), "")
  let final = jr.asBool(jr.field(body, "final"), false)
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
  var o = obj()
  o.put("ok", ok)
  o.put("session", sess)
  o.put("partial", partial)
  o.put("final", finalText)
  o.put("note", note)
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
  while wait > 0 and latestSeq() <= since and (nowMs() - t0) < int64(wait):
    spins = spins + 1
  var o = obj()
  o.put("ok", true)
  o.put("since", since)
  o.put("latestSeq", latestSeq())
  o.put("waitedMs", int(nowMs() - t0))
  o.put("mechanism", (if wait > 0: "bounded poll on the request thread (no " &
                        "sleep primitive in the mod SDK)" else: "immediate"))
  o.put("events", eventsSince(since, limit))
  o.put("pending", pendingAcks())
  result = done(o).text

proc onAck(url, body, session: string): string =
  let s = jr.asInt(jr.field(body, "seq"), -1)
  let ok = jr.asBool(jr.field(body, "ok"), true)
  let note = jr.asText(jr.field(body, "note"), "")
  var cleared = false
  withModLock:
    cleared = ackEvent(s, ok, note)
  var o = obj()
  o.put("ok", cleared)
  o.put("seq", s)
  if not cleared:
    o.put("err", "seq " & $s & " is not a pending directive (already acked, " &
          "expired, or never needed an ack)")
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
  playerPos(map, x, y, z)
  var reason = "resume where the world left the player"
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
  let people = kindJsonText("people")
  var loadNote = ""
  if not loadWorld(loadNote):
    check(2, "persistence", "FAIL", "loadWorld refused: " & loadNote)
    return
  let after = kindJsonText("people")
  var corruptNote = ""
  let corruptOk = loadKindFromJson("quests", "{ this is not json", corruptNote)
  let roundTrip = people == after
  let peopleIntact = personCount() > 0
  check(2, "persistence", verdictOf(roundTrip and (not corruptOk) and peopleIntact),
        "round trip identical " & $roundTrip & " (" & $people.len &
        " bytes, version " & $vBefore & "->" & $worldVersion() &
        "); a corrupt document was refused " & $(not corruptOk) & " (" &
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
    enumSetting("sttEngine", "Speech to text", "whisper-server",
                @["whisper-server", "none"], category = "Engines"),
    enumSetting("ttsEngine", "Text to speech", "piper",
                @["piper", "sapi", "none"], category = "Engines"),
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
  var note = ""
  withModLock:
    discard observe("tick", "", "", "{}", note)
    var dropped: seq[int] = @[]
    discard expirePending(worldClockMs(), dropped)
    var simNote = ""
    discard simAdvance(int64(gTickMs), simNote)
    if gSaveEveryTicks > 0 and (gTicks mod gSaveEveryTicks) == 0:
      var saveNote = ""
      if saveWorld(saveNote):
        discard emitEvent("world.saved",
                          done(objOf("version", worldVersion())).text, false)
  result = ""

proc onLoad(): Status =
  declareSettings(basementSchema())
  if side() == sideClient:
    info ModName & " is a server mod; its routes do not exist on the client"
    return Ok
  loadConfig()

  var parts: seq[string] = @[]

  # Generation REFUSES with a note when the name and archetype tables are not
  # loaded, so they are loaded here before anything can ask for a world -- and
  # a zero count is reported rather than left to look like an empty world.
  let namesN = loadNames(readAll(joinPath(dataDir(), "names.json")))
  let archN = loadArchetypes(readAll(joinPath(dataDir(), "archetypes.json")))
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
  discard servePrefix(WorldRoute, onWorld)
  discard serve(ObserveRoute, onObserve)
  discard serve(SayRoute, onSay)
  discard serve(ChunkRoute, onChunk)
  discard servePrefix(EventsRoute, onEvents)
  discard serve(AckRoute, onAck)
  discard serve(SpawnRoute, onSpawn)
  discard serve(SelfcheckRoute, onSelfcheck)

  discard on("tarkov.profile.listing", onProfileListing)
  discard on("tarkov.raid.configured", onRaidConfigured)

  if gEnabled:
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

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideServer, sideSim},
  onLoad = onLoad)
