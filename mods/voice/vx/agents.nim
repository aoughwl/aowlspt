## vx/agents — identities, memory, knowledge, and the radio's channel state.
##
## The generality here is the point of the whole mod. An **agent** is
## `{id, name, persona, voice, tags, greeting, world}` and *nothing in that type
## mentions Tarkov*. "A scav in a raid" and "your personal assistant" are two
## rows of the same table; the only field that distinguishes them is `world`,
## which says whether this agent has a body that can be dead or out of range.
##
## A **channel** is an addressable endpoint that agents subscribe to. The radio
## is therefore routing, not a second pipeline: `route(channel)` picks which
## agent answers, and after that the identical reason/speak path runs that a
## proximity conversation runs. Proximity is the degenerate channel `local`.
##
## Everything is held in parallel `seq`s of primitives rather than a `seq` of
## objects. That is the idiom the rest of this repo's mods use for global state
## (`bd/spawns.nim`, `ice/pending.nim`, `classicmovement`), and nimony's `seq`
## has no `delete`/`setLen` anyway, so trimming is always a rebuild.

import std/strutils
import aowlspt
import aowlspt/json as jr
import engine

# --------------------------------------------------------------------- agents

var gAgentId: seq[string] = @[]
var gAgentName: seq[string] = @[]
var gAgentPersona: seq[string] = @[]
var gAgentVoice: seq[string] = @[]
var gAgentTags: seq[string] = @[]
var gAgentGreeting: seq[string] = @[]
var gAgentWorld: seq[int] = @[]

proc agentCount*(): int = gAgentId.len
proc agentId*(i: int): string = gAgentId[i]
proc agentName*(i: int): string = gAgentName[i]
proc agentPersona*(i: int): string = gAgentPersona[i]
proc agentVoice*(i: int): string = gAgentVoice[i]
proc agentTags*(i: int): string = gAgentTags[i]
proc agentGreeting*(i: int): string = gAgentGreeting[i]
proc agentIsWorld*(i: int): bool = gAgentWorld[i] == 1

proc findAgent*(id: string): int =
  ## -1 when there is no such agent. Callers must say so rather than falling
  ## back to a default agent silently -- answering as the wrong character is
  ## exactly the class of quiet wrongness this project keeps getting burned by.
  result = -1
  var i = 0
  while i < gAgentId.len:
    if gAgentId[i] == id: return i
    i = i + 1

proc addAgent*(id, name, persona, voice, tags, greeting: string; world: bool) =
  if findAgent(id) >= 0: return
  gAgentId.add id
  gAgentName.add name
  gAgentPersona.add persona
  gAgentVoice.add voice
  gAgentTags.add tags
  gAgentGreeting.add greeting
  gAgentWorld.add (if world: 1 else: 0)

proc loadAgents*(text: string): int =
  ## `data/agents.json` -> the registry. Returns how many loaded, so the caller
  ## can report a zero honestly instead of serving an empty roster as if it were
  ## a configuration choice.
  let arr = jr.field(text, "agents")
  let items = jr.each(arr)
  for a in items:
    addAgent(jr.asText(jr.child(a, "id"), ""),
             jr.asText(jr.child(a, "name"), ""),
             jr.asText(jr.child(a, "persona"), ""),
             jr.asText(jr.child(a, "voice"), ""),
             jr.asText(jr.child(a, "tags"), ""),
             jr.asText(jr.child(a, "greeting"), ""),
             jr.asBool(jr.child(a, "world"), false))
  result = gAgentId.len

# --------------------------------------------------------------------- memory

var gMemAgent: seq[int] = @[]
var gMemLine: seq[string] = @[]

proc remember*(agent: int; line: string) =
  if agent < 0 or line.len == 0: return
  gMemAgent.add agent
  gMemLine.add line

proc forgetAgent*(agent: int) =
  ## Rebuild without this agent's lines -- `seq` cannot shrink in place.
  var a: seq[int] = @[]
  var l: seq[string] = @[]
  var i = 0
  while i < gMemAgent.len:
    if gMemAgent[i] != agent:
      a.add gMemAgent[i]
      l.add gMemLine[i]
    i = i + 1
  gMemAgent = a
  gMemLine = l

proc memoryOf*(agent: int; maxTurns: int): string =
  ## The last `maxTurns` lines for this agent, oldest first.
  ## EFMB sent the model only a system prompt and the current utterance, so its
  ## NPCs had no conversational memory at all. This is the fix, and it is why
  ## the transcript is kept per agent rather than per raid.
  var keep: seq[string] = @[]
  var i = 0
  while i < gMemAgent.len:
    if gMemAgent[i] == agent: keep.add gMemLine[i]
    i = i + 1
  result = ""
  var start = keep.len - maxTurns
  if start < 0: start = 0
  var k = start
  while k < keep.len:
    result.add keep[k]
    result.add "\n"
    k = k + 1

proc memoryLines*(agent: int): int =
  result = 0
  var i = 0
  while i < gMemAgent.len:
    if gMemAgent[i] == agent: result = result + 1
    i = i + 1

# ------------------------------------------------------------------ knowledge

var gFactTags: seq[string] = @[]
var gFactText: seq[string] = @[]

proc factCount*(): int = gFactText.len

proc loadKnowledge*(text: string): int =
  let arr = jr.field(text, "facts")
  let items = jr.each(arr)
  for f in items:
    gFactTags.add jr.asText(jr.child(f, "tags"), "").toLowerAscii()
    gFactText.add jr.asText(jr.child(f, "text"), "")
  result = gFactText.len

proc tokensOf(s: string): seq[string] =
  result = @[]
  var cur = ""
  let lowered = s.toLowerAscii()
  for ch in lowered:
    if (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9'):
      cur.add ch
    else:
      if cur.len > 2: result.add cur
      cur = ""
  if cur.len > 2: result.add cur

proc retrieve*(query, tags: string; limit: int; hits: var string): string =
  ## Keyword-overlap retrieval: score each fact by how many of its tags appear
  ## in the utterance or in the agent's own tags, take the best `limit`.
  ##
  ## This is deliberately dumb and deliberately visible -- `hits` comes back as
  ## the list of fact indices used and is reported in the response, so you can
  ## see retrieval working or not working instead of guessing. It is not
  ## embeddings and not a graph; upgrading it means replacing this one proc.
  ## (EFMB had no retrieval at all: a 9-entry Python dict keyed by substring on
  ## a per-raid GUID, which meant the lookup essentially never fired.)
  ## What was *said* outweighs who is saying it, 3 to 1. Without that weighting
  ## the agent's own tags swamp the question: asking the assistant "where do I
  ## extract" retrieved the fact tagged `assistant help aowl` ahead of the one
  ## tagged `exit extract`, because the persona contributed more matches than
  ## the sentence did. Measured, not theorised.
  let words = tokensOf(query)
  let personal = tokensOf(tags)
  var bestIdx: seq[int] = @[]
  var bestScore: seq[int] = @[]
  var i = 0
  while i < gFactText.len:
    var score = 0
    let ftags = tokensOf(gFactTags[i])
    for t in ftags:
      for w in words:
        if w == t: score = score + 3
      for w in personal:
        if w == t: score = score + 1
    if score > 0:
      bestIdx.add i
      bestScore.add score
    i = i + 1
  # selection sort by score, `limit` times -- the fact list is tens of entries,
  # not thousands, and nimony's `sorted` on parallel seqs is more trouble.
  result = ""
  hits = ""
  var taken = 0
  while taken < limit:
    var pick = -1
    var pickScore = 0
    var k = 0
    while k < bestIdx.len:
      if bestScore[k] > pickScore:
        pickScore = bestScore[k]
        pick = k
      k = k + 1
    if pick < 0: break
    result.add "- " & gFactText[bestIdx[pick]] & "\n"
    if hits.len > 0: hits.add ","
    hits.add $bestIdx[pick]
    bestScore[pick] = 0
    taken = taken + 1

# ------------------------------------------------------------------- channels

var gChanId: seq[string] = @[]
var gChanLabel: seq[string] = @[]
var gChanPrivate: seq[int] = @[]
var gChanRange: seq[float] = @[]
var gChanMembers: seq[string] = @[]

var gTuned: string = ""
var gAssumeBots: bool = true
var gRosterLive: bool = false

proc channelCount*(): int = gChanId.len
proc channelId*(i: int): string = gChanId[i]
proc channelLabel*(i: int): string = gChanLabel[i]
proc channelPrivate*(i: int): bool = gChanPrivate[i] == 1
proc channelRange*(i: int): float = gChanRange[i]
proc channelMembers*(i: int): string = gChanMembers[i]

proc findChannel*(id: string): int =
  result = -1
  var i = 0
  while i < gChanId.len:
    if gChanId[i] == id: return i
    i = i + 1

proc loadChannels*(text: string): int =
  let arr = jr.field(text, "channels")
  let items = jr.each(arr)
  for c in items:
    let id = jr.asText(jr.child(c, "id"), "")
    if id.len == 0 or findChannel(id) >= 0: continue
    gChanId.add id
    gChanLabel.add jr.asText(jr.child(c, "label"), id)
    gChanPrivate.add (if jr.asBool(jr.child(c, "private"), false): 1 else: 0)
    gChanRange.add jr.asFloat(jr.child(c, "rangeM"), 400.0)
    var mem = ""
    let ms = jr.each(jr.child(c, "members"))
    for m in ms:
      if mem.len > 0: mem.add " "
      mem.add jr.asText(m, "")
    gChanMembers.add mem
  result = gChanId.len

proc setTuned*(id: string) = gTuned = id
proc tuned*(): string = gTuned
proc setAssumeBots*(b: bool) = gAssumeBots = b
proc assumeBots*(): bool = gAssumeBots
proc rosterLive*(): bool = gRosterLive

## Presence: whether one agent can answer on one channel *right now*.
##
## Range and liveness are exactly where a radio differs from a phone, and the
## brief was explicit that failure must land in the fiction rather than being
## silent. So this returns one of a small set of statuses the client can voice:
##
##   ok | out_of_range | dead | unwilling | unknown
##
## `unknown` is what you get when the bot roster is not wired. **It is not
## built here** -- a separate agent owns the host-side bot census, and this mod
## is written against the interface documented in DESIGN.md §3.5. Until it
## exists, `assumeBots` (default true) maps `unknown` to `ok` so the system is
## testable end to end, and `/aowlspt/voice/status` says which is in force.

proc presence*(agentIdx, chanIdx: int): string =
  if agentIdx < 0: return "no_such_agent"
  if chanIdx >= 0 and channelPrivate(chanIdx):
    # A private channel is you talking to something with no body -- your
    # assistant. Range and liveness cannot apply, so they are not consulted.
    return "ok"
  if not agentIsWorld(agentIdx):
    return "ok"
  if not gRosterLive:
    return (if gAssumeBots: "ok" else: "unknown")
  # When the roster is live this is where distanceM/alive are consulted. The
  # branch is written and unreachable today by design, so wiring the roster is
  # a one-proc change rather than a redesign.
  result = "unknown"

proc routeChannel*(chanIdx: int; status: var string): int =
  ## Which agent answers on this channel. First member whose presence is `ok`
  ## wins; otherwise the *reason nobody answered* is returned in `status`, so
  ## the caller can produce dead air, hiss, or a refusal instead of a blank.
  status = "empty"
  if chanIdx < 0:
    status = "no_such_channel"
    return -1
  let members = channelMembers(chanIdx).split(' ')
  var firstFail = ""
  for m in members:
    if m.len == 0: continue
    let ai = findAgent(m)
    if ai < 0:
      if firstFail.len == 0: firstFail = "no_such_agent"
      continue
    let p = presence(ai, chanIdx)
    if p == "ok":
      status = "ok"
      return ai
    if firstFail.len == 0: firstFail = p
  if firstFail.len > 0: status = firstFail
  result = -1
