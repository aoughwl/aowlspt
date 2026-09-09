## aowlspt/voice — conversational agents with voice, served from the backend.
##
## ---------------------------------------------------------------------------
## WHAT THIS IS
## ---------------------------------------------------------------------------
##
## A **system**, not a Tarkov feature. The unit is a *conversational agent with
## an identity*; "a scav in a raid" and "your personal assistant" are two rows of
## `data/agents.json` differing in one boolean. On top of that sits a **radio**:
## channels are addressable endpoints agents subscribe to, so calling an NPC on
## channel 3 and standing next to them reach the same agent through different
## routing. There is one pipeline underneath both.
##
##   POST /aowlspt/voice/listen   mic -> whisper -> reason -> piper -> a .wav
##   POST /aowlspt/voice/turn     a .wav in, the same from there
##   POST /aowlspt/voice/say      text in, reason -> speak (the shortest proof)
##   POST /aowlspt/voice/radio/transmit   the same, routed through a channel
##
## ---------------------------------------------------------------------------
## WHY ALL OF IT IS SERVER-SIDE
## ---------------------------------------------------------------------------
##
## Bot AI runs in the client; this does not. Speech-to-text is a 141 MB model and
## seconds of CPU, reasoning is worse, and both are restartable. Anything that
## stalls here must not stall a frame, and a mistake here must be a bad HTTP
## response rather than a crashed raid. So the whole stack lives in the backend
## and the client/host side is a **thin bridge**: something polls
## `/aowlspt/voice/last`, gets `{reply, wav}`, and plays the file. That bridge is
## deliberately not written here -- another agent owns the host side.
##
## The practical consequence is that everything below is testable **right now,
## with no game running**, with `curl`. That was the point.
##
## ---------------------------------------------------------------------------
## HONESTY
## ---------------------------------------------------------------------------
##
## Default OFF. Every engine is probed and `/aowlspt/voice/status` reports the
## exact path it resolved, present or missing. There is **no local LLM on this
## machine** (no .gguf anywhere; Docker ships llama.cpp binaries but an empty
## model store), so the default reasoning engine is `builtin`, which is a
## template responder and **not a language model** -- and it says so in the
## `notes` of every response it produces. See `DESIGN.md` §5 for the full list of
## what is not done.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/settings
import aowlspt/json as jr
import aowlspt/sync

import "vx" / engine
import "vx" / agents
import "vx" / pipeline
import "vx" / cache

const
  ModGuid = "aowl.voice"
  ModName = "Voice Agents"
  ModAuthor = "savannt"
  ModVersion = "0.1.0"

  StatusRoute   = "/aowlspt/voice/status"
  AgentsRoute   = "/aowlspt/voice/agents"
  SayRoute      = "/aowlspt/voice/say"
  TurnRoute     = "/aowlspt/voice/turn"
  ListenRoute   = "/aowlspt/voice/listen"
  ObserveRoute  = "/aowlspt/voice/observe"
  LastRoute     = "/aowlspt/voice/last"
  ChannelsRoute = "/aowlspt/voice/radio/channels"
  TuneRoute     = "/aowlspt/voice/radio/tune"
  TransmitRoute = "/aowlspt/voice/radio/transmit"

# ---------------------------------------------------------------------------
# State. Literal initialisers only: nimony silently zeroes any DLL global whose
# initialiser is a call, and a mod is a DLL.
# ---------------------------------------------------------------------------

var gEnabled: bool = false
var gDefaultAgent: string = "assistant"
var gLoadNote: string = "not loaded"

var gLastAgent: string = ""
var gLastHeard: string = ""
var gLastReply: string = ""
var gLastWav: string = ""
var gLastChannel: string = ""
var gLastStatus: string = ""
var gLastMs: int64 = 0
var gLastCached: bool = false

proc loadConfig() =
  gEnabled = setting("enabled").asBool(false)
  gDefaultAgent = setting("defaultAgent").asText("assistant")
  setAssumeBots(setting("assumeBotsPresent").asBool(true))
  configure(
    toolsDir     = setting("toolsDir").asText(""),
    stt          = setting("sttEngine").asText("whisper-server"),
    llm          = setting("llmEngine").asText("builtin"),
    tts          = setting("ttsEngine").asText("piper"),
    whisperExe   = setting("whisperExe").asText(""),
    whisperModel = setting("whisperModel").asText(""),
    piperExe     = setting("piperExe").asText(""),
    piperVoice   = setting("piperVoice").asText(""),
    recorderExe  = setting("recorderExe").asText(""),
    curlExe      = setting("curlExe").asText("curl.exe"),
    llamaExe     = setting("llamaExe").asText(""),
    llamaModel   = setting("llamaModel").asText(""),
    openAiModel  = setting("openAiModel").asText("gpt-4o-mini"),
    workDir      = setting("workDir").asText(""),
    whisperPort  = setting("whisperPort").asInt(9000),
    maxTurns     = setting("maxTurns").asInt(12),
    maxTokens    = setting("maxTokens").asInt(160))
  # The response + TTS-line cache. Default dir is beside the mod's data so it
  # survives a restart; an explicit cacheDir setting overrides it.
  var cdir = setting("cacheDir").asText("")
  if cdir.len == 0: cdir = joinPath(dataDir(), "cache")
  cacheConfigure(
    enabled    = setting("cacheEnabled").asBool(true),
    maxEntries = setting("cacheMaxEntries").asInt(256),
    dir        = cdir,
    ttlMs      = int64(setting("cacheTtlSeconds").asInt(0)) * 1000)

# ---------------------------------------------------------------------------
# Small JSON helpers
# ---------------------------------------------------------------------------

proc probeJson(p: Probe): JsonObject =
  result = obj()
  result.put("slot", p.slot)
  result.put("id", p.id)
  result.put("path", p.path)
  result.put("model", p.extra)
  result.put("ok", p.ok)
  result.put("note", p.note)

proc notesArray(items: seq[string]): JsonArray =
  result = arr()
  for n in items:
    if n.len > 0: result.add n

proc disabledJson(): string =
  var o = obj()
  o.put("ok", false)
  o.put("err", "aowl.voice is disabled; set \"enabled\": true in " &
        "mods/voice/config.json (it is off by default because it spawns " &
        "subprocesses and loads large models)")
  result = done(o).text

# ---------------------------------------------------------------------------
# The one pipeline. Everything -- proximity, radio, text-only -- ends up here.
# ---------------------------------------------------------------------------

proc converse(agentIdx: int; heard: string; channel: string;
              notes: var seq[string]): string =
  ## reason -> tag-parse -> speak -> remember. Returns the reply text and leaves
  ## the wav path in `gLastWav`. Held under the mod lock because 16 backend
  ## workers share this state and two overlapping requests would otherwise
  ## interleave one agent's memory with another's.
  let t0 = nowMs()

  # Cache first. The key is (agent, normalized utterance, llm engine, tts+voice);
  # a HIT returns the stored reply and wav WITHOUT running the LLM or piper --
  # that is the whole latency win. It is keyed without conversation memory, so
  # it matches repeated stateless lines, not context-dependent turns.
  let voiceTag = ttsEngine() & ":" & agentVoice(agentIdx)
  let key = cacheKey(agentId(agentIdx), heard, llmEngine(), voiceTag)
  var cReply = ""
  var cWav = ""
  if cacheLookup(key, cReply, cWav):
    notes.add "cache HIT: reply and wav served from cache, LLM and TTS skipped"
    gLastCached = true
    remember(agentIdx, "Them: " & heard)
    if cReply.len > 0: remember(agentIdx, agentName(agentIdx) & ": " & cReply)
    gLastAgent = agentId(agentIdx)
    gLastHeard = heard
    gLastReply = cReply
    gLastWav = cWav
    gLastChannel = channel
    gLastStatus = "ok"
    gLastMs = nowMs() - t0
    return cReply

  notes.add "cache MISS: generating (will be stored for next time)"
  gLastCached = false

  var hits = ""
  var noteLlm = ""
  var reply = reason(agentIdx, heard, hits, noteLlm)
  notes.add noteLlm
  if hits.len > 0: notes.add "knowledge hits: " & hits

  var acted = ""
  reply = applyTags(reply, acted)
  if acted.len > 0:
    notes.add "objective tag '" & acted &
              "' applied (stored only -- nothing renders objectives yet)"

  var noteTts = ""
  let wav = speak(agentIdx, reply, noteTts)
  notes.add noteTts

  # Only store a usable exchange -- an empty reply (llm=none / unavailable) is
  # not worth a cache slot, and caching it would mask the real failure behind a
  # fast empty hit next time.
  if reply.len > 0:
    cacheStore(key, reply, wav)

  remember(agentIdx, "Them: " & heard)
  if reply.len > 0: remember(agentIdx, agentName(agentIdx) & ": " & reply)

  gLastAgent = agentId(agentIdx)
  gLastHeard = heard
  gLastReply = reply
  gLastWav = wav
  gLastChannel = channel
  gLastStatus = "ok"
  gLastMs = nowMs() - t0
  result = reply

proc exchangeJson(agentIdx: int; heard, reply, wav, channel, status: string;
                  notes: seq[string]; ms: int64): string =
  var eng = obj()
  eng.put("stt", sttEngine())
  eng.put("llm", llmEngine())
  eng.put("tts", ttsEngine())
  var o = obj()
  o.put("ok", status == "ok")
  o.put("status", status)
  o.put("agent", (if agentIdx >= 0: agentId(agentIdx) else: ""))
  o.put("agentName", (if agentIdx >= 0: agentName(agentIdx) else: ""))
  o.put("channel", channel)
  o.put("heard", heard)
  o.put("reply", reply)
  o.put("wav", wav)
  o.put("cached", gLastCached and status == "ok")
  o.put("engines", done(eng))
  o.put("ms", int(ms))
  o.put("notes", done(notesArray(notes)))
  result = done(o).text

proc resolveAgent(body: string; notes: var seq[string]): int =
  var want = jr.asText(jr.field(body, "agent"), "")
  if want.len == 0: want = gDefaultAgent
  result = findAgent(want)
  if result < 0:
    notes.add "no such agent '" & want & "'"

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

proc onStatus(url, body, session: string): string =
  var probes = arr()
  probes.add done(probeJson(sttProbe()))
  probes.add done(probeJson(llmProbe()))
  probes.add done(probeJson(ttsProbe()))
  probes.add done(probeJson(recProbe()))
  var o = obj()
  o.put("ok", true)
  o.put("schema", "aowlspt.voice.status/1")
  o.put("enabled", gEnabled)
  o.put("mod", ModGuid)
  o.put("version", ModVersion)
  o.put("engines", done(probes))
  o.put("agents", agentCount())
  o.put("channels", channelCount())
  o.put("facts", factCount())
  o.put("defaultAgent", gDefaultAgent)
  o.put("tuned", tuned())
  o.put("dataLoad", gLoadNote)
  # The cache, reported truthfully: whether it is on, where it lives, how full,
  # and the running hit/miss tally so a client can SEE the cache working rather
  # than take it on faith. It is keyed without conversation memory -- said here
  # so nobody mistakes a hit for context-aware reasoning.
  var cache = obj()
  cache.put("enabled", cacheEnabledP())
  cache.put("dir", cacheDirPath())
  cache.put("entries", cacheCount())
  cache.put("maxEntries", cacheMax())
  cache.put("ttlMs", int(cacheTtlMs()))
  cache.put("hits", cacheHits())
  cache.put("misses", cacheMisses())
  cache.put("load", cacheLoadNote())
  cache.put("note", "keyed on (agent, normalized utterance, llm engine, " &
    "tts+voice); memory is NOT part of the key, so hits match repeated lines " &
    "not context-dependent turns")
  o.put("cache", done(cache))
  # Say plainly whether world agents are being believed or measured. Nothing
  # here should ever let somebody think a live bot census is wired when it is
  # not -- that is a separate agent's host-side surface (DESIGN.md §3.5).
  o.put("botRoster", (if rosterLive(): "live"
                      elif assumeBots(): "absent (assumeBotsPresent=true: " &
                        "world agents treated as alive and in range)"
                      else: "absent (world agents unreachable)"))
  result = done(o).text

proc onAgents(url, body, session: string): string =
  var a = arr()
  var i = 0
  while i < agentCount():
    var o = obj()
    o.put("id", agentId(i))
    o.put("name", agentName(i))
    o.put("tags", agentTags(i))
    o.put("world", agentIsWorld(i))
    o.put("memory", memoryLines(i))
    a.add done(o)
    i = i + 1
  var root = obj()
  root.put("ok", true)
  root.put("agents", done(a))
  result = done(root).text

proc onSay(url, body, session: string): string =
  if not gEnabled: return disabledJson()
  var notes: seq[string] = @[]
  let ai = resolveAgent(body, notes)
  let heard = jr.asText(jr.field(body, "text"), "")
  if ai < 0:
    return exchangeJson(-1, heard, "", "", "", "no_such_agent", notes, 0)
  if heard.len == 0:
    notes.add "no `text` in the body"
    return exchangeJson(ai, "", "", "", "", "empty", notes, 0)
  withModLock:
    discard converse(ai, heard, "local", notes)
  result = exchangeJson(ai, gLastHeard, gLastReply, gLastWav, "local", "ok",
                        notes, gLastMs)

proc turnFromWav(ai: int; wav, channel: string; notes: var seq[string]): string =
  var noteStt = ""
  let heard = transcribe(wav, noteStt)
  notes.add noteStt
  if heard.len == 0:
    gLastStatus = "no_speech"
    return exchangeJson(ai, "", "", "", channel, "no_speech", notes, 0)
  withModLock:
    discard converse(ai, heard, channel, notes)
  result = exchangeJson(ai, gLastHeard, gLastReply, gLastWav, channel, "ok",
                        notes, gLastMs)

proc onTurn(url, body, session: string): string =
  if not gEnabled: return disabledJson()
  var notes: seq[string] = @[]
  let ai = resolveAgent(body, notes)
  if ai < 0: return exchangeJson(-1, "", "", "", "", "no_such_agent", notes, 0)
  let wav = jr.asText(jr.field(body, "wav"), "")
  if wav.len == 0:
    notes.add "no `wav` path in the body"
    return exchangeJson(ai, "", "", "", "", "empty", notes, 0)
  result = turnFromWav(ai, wav, "local", notes)

proc onListen(url, body, session: string): string =
  ## The whole spine: microphone -> transcription -> reasoning -> speech.
  if not gEnabled: return disabledJson()
  var notes: seq[string] = @[]
  let ai = resolveAgent(body, notes)
  if ai < 0: return exchangeJson(-1, "", "", "", "", "no_such_agent", notes, 0)
  var secs = jr.asInt(jr.field(body, "seconds"), 5)
  var noteRec = ""
  let wav = record(secs, noteRec)
  notes.add noteRec
  if wav.len == 0:
    return exchangeJson(ai, "", "", "", "local", "no_audio", notes, 0)
  result = turnFromWav(ai, wav, "local", notes)

proc onObserve(url, body, session: string): string =
  ## Push a world event into an agent's memory -- EFMB's `POST /event/<npcId>`,
  ## except the memory is per-agent and actually reaches the prompt.
  if not gEnabled: return disabledJson()
  var notes: seq[string] = @[]
  let ai = resolveAgent(body, notes)
  if ai < 0: return exchangeJson(-1, "", "", "", "", "no_such_agent", notes, 0)
  let ev = jr.asText(jr.field(body, "event"), "")
  if ev.len == 0: return errJson("no `event` in the body")
  withModLock:
    remember(ai, "(" & ev & ")")
  var o = obj()
  o.put("ok", true)
  o.put("agent", agentId(ai))
  o.put("memory", memoryLines(ai))
  result = done(o).text

proc onLast(url, body, session: string): string =
  ## **The entire client-bridge surface.** A host-side mod polls this, sees a
  ## new `ms`, and plays `wav`. Nothing else about this stack needs to be known
  ## on the client. That bridge is not written -- see DESIGN.md §5.
  var o = obj()
  o.put("ok", gLastReply.len > 0)
  o.put("agent", gLastAgent)
  o.put("channel", gLastChannel)
  o.put("heard", gLastHeard)
  o.put("reply", gLastReply)
  o.put("wav", gLastWav)
  o.put("status", gLastStatus)
  o.put("cached", gLastCached)
  o.put("ms", int(gLastMs))
  result = done(o).text

# ------------------------------------------------------------------- radio

proc onChannels(url, body, session: string): string =
  var a = arr()
  var i = 0
  while i < channelCount():
    var mem = arr()
    let ids = channelMembers(i).split(' ')
    for m in ids:
      if m.len == 0: continue
      var mo = obj()
      mo.put("agent", m)
      let ai = findAgent(m)
      mo.put("name", (if ai >= 0: agentName(ai) else: ""))
      mo.put("presence", presence(ai, i))
      mem.add done(mo)
    var o = obj()
    o.put("id", channelId(i))
    o.put("label", channelLabel(i))
    o.put("private", channelPrivate(i))
    o.put("rangeM", channelRange(i))
    o.put("members", done(mem))
    a.add done(o)
    i = i + 1
  var root = obj()
  root.put("ok", true)
  root.put("tuned", tuned())
  root.put("channels", done(a))
  result = done(root).text

proc onTune(url, body, session: string): string =
  let want = jr.asText(jr.field(body, "channel"), "")
  if findChannel(want) < 0:
    return errJson("no such channel: " & want)
  setTuned(want)
  var o = obj()
  o.put("ok", true)
  o.put("tuned", want)
  result = done(o).text

proc onTransmit(url, body, session: string): string =
  ## The radio is routing over the same pipeline, not a second pipeline: once
  ## `routeChannel` has picked who answers, `converse` is the identical call
  ## `/say` makes. If this needed its own reasoning path the abstraction would
  ## be wrong.
  if not gEnabled: return disabledJson()
  var notes: seq[string] = @[]
  var chan = jr.asText(jr.field(body, "channel"), "")
  if chan.len == 0: chan = tuned()
  let ci = findChannel(chan)
  var status = ""
  let ai = routeChannel(ci, status)
  if ai < 0:
    # Fail in the fiction, not silently: the caller gets a status it can voice
    # as hiss, dead air, or a refusal.
    notes.add "nobody answered on '" & chan & "': " & status
    if status == "unknown":
      notes.add "the bot roster is not wired; see DESIGN.md §3.5 for the " &
                "interface this needs from the host-side bot API"
    gLastStatus = status
    gLastChannel = chan
    return exchangeJson(-1, "", "", "", chan, status, notes, 0)
  let wav = jr.asText(jr.field(body, "wav"), "")
  if wav.len > 0:
    return turnFromWav(ai, wav, chan, notes)
  let heard = jr.asText(jr.field(body, "text"), "")
  if heard.len == 0:
    notes.add "no `text` or `wav` in the body"
    return exchangeJson(ai, "", "", "", chan, "empty", notes, 0)
  withModLock:
    discard converse(ai, heard, chan, notes)
  result = exchangeJson(ai, gLastHeard, gLastReply, gLastWav, chan, "ok",
                        notes, gLastMs)

# ---------------------------------------------------------------------- F12

proc voiceSchema(): seq[Setting] =
  result = @[
    boolSetting("enabled", "Enable voice agents", false, category = "General",
                description = "Off by default: turning it on lets this mod " &
                              "spawn whisper/piper subprocesses"),
    stringSetting("defaultAgent", "Default agent", "assistant",
                  category = "General"),
    enumSetting("sttEngine", "Speech to text", "whisper-server",
                @["whisper-server", "none"], category = "Engines"),
    enumSetting("llmEngine", "Reasoning", "builtin",
                @["builtin", "llamacpp", "openai", "none"], category = "Engines",
                description = "builtin is a template responder, NOT a " &
                              "language model; llamacpp needs a .gguf you supply"),
    enumSetting("ttsEngine", "Text to speech", "piper",
                @["piper", "sapi", "none"], category = "Engines"),
    stringSetting("toolsDir", "Tools directory", "", category = "Paths",
                  description = "Holds whisper/, piper/, recorder/"),
    stringSetting("llamaModel", "llama.cpp model (.gguf)", "", category = "Paths",
                  description = "No .gguf exists on this machine yet"),
    stringSetting("openAiModel", "OpenAI model", "gpt-4o-mini",
                  category = "Engines",
                  description = "Used when llmEngine=openai; the key comes from " &
                                "OPENAI_API_KEY in the environment, never config"),
    intSetting("maxTurns", "Conversation memory (turns)", 12, lo = 0, hi = 64,
               step = 1, category = "Dialogue"),
    boolSetting("cacheEnabled", "Cache voice lines", true, category = "Cache",
                description = "Return a previously generated reply and its wav " &
                              "without re-running the LLM or TTS"),
    intSetting("cacheMaxEntries", "Max cached lines", 256, lo = 0, hi = 100000,
               step = 1, category = "Cache",
               description = "Oldest entries are evicted (LRU) beyond this"),
    stringSetting("cacheDir", "Cache directory", "", category = "Cache",
                  description = "Empty = mods/voice/data/cache beside the mod"),
    intSetting("cacheTtlSeconds", "Cache entry lifetime (s)", 0, lo = 0,
               hi = 31536000, step = 1, category = "Cache",
               description = "0 = never expire"),
    boolSetting("precacheCommonLines", "Pre-generate greetings at load", false,
                category = "Cache",
                description = "On load, generate each agent's greeting into the " &
                              "cache so the first hit is instant"),
    boolSetting("assumeBotsPresent", "Assume world agents are reachable", true,
                category = "Radio",
                description = "Until the host-side bot roster exists, treat " &
                              "world agents as alive and in range"),
    boolSetting("pushToTalk", "In-game push to talk", false, category = "Client",
                implemented = false,
                description = "Not done: needs a host-side bridge"),
    boolSetting("spatialPlayback", "Play replies at the NPC", false,
                category = "Client", implemented = false,
                description = "Not done: needs a host-side bridge"),
    boolSetting("objectiveHud", "Show objectives", false, category = "Client",
                implemented = false,
                description = "Not done: tags are parsed and stored only")]

proc onSettings(url, body, session: string): string =
  if body.len > 0 and applySettingFromBody(body) == Ok:
    loadConfig()
  result = declaredSchemaJson().text

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc loadDataFiles() =
  ## `data/*.json` beside the mod. A missing file is reported, not assumed --
  ## an empty roster served as if it were a choice is exactly the silent
  ## nothing this mod is written to avoid.
  var parts: seq[string] = @[]
  let aText = readAll(joinPath(dataDir(), "agents.json"))
  if aText.len == 0:
    parts.add "agents.json missing or empty"
  else:
    parts.add $loadAgents(aText) & " agents"
  let kText = readAll(joinPath(dataDir(), "knowledge.json"))
  if kText.len == 0:
    parts.add "knowledge.json missing or empty"
  else:
    parts.add $loadKnowledge(kText) & " facts"
  let cText = readAll(joinPath(dataDir(), "channels.json"))
  if cText.len == 0:
    parts.add "channels.json missing or empty"
  else:
    parts.add $loadChannels(cText) & " channels"
  gLoadNote = ""
  for p in parts:
    if gLoadNote.len > 0: gLoadNote.add ", "
    gLoadNote.add p

proc precacheCommon() =
  ## Pre-generate the reply to a few common greeting utterances for every agent,
  ## so the first real request for one is an instant cache HIT rather than a
  ## live LLM+TTS pass. It runs the ordinary generate path (which MISSes and then
  ## stores), so a precached line is byte-identical to what a live request would
  ## have produced -- no separate code path to drift.
  let common = ["hello", "hey", "you there"]
  var i = 0
  while i < agentCount():
    for u in common:
      var notes: seq[string] = @[]
      withModLock:
        discard converse(i, u, "local", notes)
    i = i + 1

proc onLoad(): Status =
  declareSettings(voiceSchema())
  if side() == sideClient:
    info ModName & " is a server mod; its routes do not exist on the client"
    return Ok
  loadConfig()
  loadDataFiles()
  cacheLoad()
  if channelCount() > 0 and tuned().len == 0:
    setTuned(channelId(0))

  discard serve("/aowlspt/settings/" & ModGuid, onSettings)
  discard serve(StatusRoute, onStatus)
  discard serve(AgentsRoute, onAgents)
  discard serve(SayRoute, onSay)
  discard serve(TurnRoute, onTurn)
  discard serve(ListenRoute, onListen)
  discard serve(ObserveRoute, onObserve)
  discard serve(LastRoute, onLast)
  discard serve(ChannelsRoute, onChannels)
  discard serve(TuneRoute, onTune)
  discard serve(TransmitRoute, onTransmit)

  if gEnabled:
    let s = sttProbe()
    let l = llmProbe()
    let t = ttsProbe()
    success ModName & " " & ModVersion & " on: " & gLoadNote &
            " | stt " & s.note & " | llm " & l.note & " | tts " & t.note
    if not s.ok or not t.ok:
      warn ModName & ": an engine is missing -- GET " & StatusRoute &
           " for the exact paths it looked at"
    if setting("precacheCommonLines").asBool(false):
      precacheCommon()
      info ModName & ": precache done -- " & $cacheCount() & " cached lines"
  else:
    info ModName & " " & ModVersion & " loaded but DISABLED (" & gLoadNote &
         "). Set \"enabled\": true in mods/voice/config.json, then GET " &
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
