## bm/encounter — the interaction state machine (DESIGN.md §6).
##
## Everything the player DOES to a person arrives here as a fact from the
## client (`POST /observe`), and everything a person does back leaves here as a
## directive on the stream (`bm/stream.emitEvent`). Nothing in this file talks
## to the network, to a model, or to the game: it is a pure transition table
## over `bm/world` plus two side effects — a journal line and a directive.
##
##     none -> noticed -> hailed -> talking -> {dealing, threatened, fighting}
##     threatened -> {robbed, captive, fighting, escaped}
##     captive -> escorted -> {released, sold, escaped, dead}
##     dealing -> {deal_struck, refused}
##     talking -> parted
##
## Two rules this file is written to obey:
##
## * **Every transition journals.** `world.journal` is the only record that
##   survives a restart, and a state change nobody can see afterwards is
##   indistinguishable from one that never happened. `escape_attempt` in
##   particular is journaled whether the player gets away or not, because the
##   attempt is the fact — the outcome is a second field, not a second event.
## * **A refusal is a note, never silence.** `observe` returns the number of
##   directives it emitted and fills `note`; an unknown fact kind, a person id
##   that is not in the world, a tag with no meaning here all come back with a
##   sentence naming what was wrong. Zero directives with an empty note would
##   be exactly the silent nothing DESIGN.md §6 forbids.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json as jr

import world
import stream
import prompt

# ---------------------------------------------------------------------------
# Configuration. Literal initialisers only — nimony zeroes a DLL global whose
# initialiser is a call.
# ---------------------------------------------------------------------------

var gLeashM: float = 25.0
var gNoticeM: float = 60.0
var gThreatM: float = 18.0

proc encounterConfigure*(leashM: float; noticeM: float; threatM: float) =
  if leashM > 0.0: gLeashM = leashM
  if noticeM > 0.0: gNoticeM = noticeM
  if threatM > 0.0: gThreatM = threatM

proc leashM*(): float = gLeashM
proc noticeM*(): float = gNoticeM
proc threatM*(): float = gThreatM

# ---------------------------------------------------------------------------
# Per-person encounter rows. Parallel seqs (the repo idiom); `seq[int]` rather
# than `seq[bool]` because that is what every other mod here uses.
# ---------------------------------------------------------------------------

var gEncPerson: seq[string] = @[]
var gEncState: seq[string] = @[]
var gEncCaptor: seq[string] = @[]      # who holds the player, when captive
var gEncEscortTo: seq[string] = @[]    # place id the escort is walking to
var gEncSinceMs: seq[int64] = @[]
var gEncWhy: seq[string] = @[]
var gEncEscapes: seq[int] = @[]        # escape attempts made against this row

# Player-side facts the client reports, remembered so `situationFor` can answer
# without the caller having to pass them in.
var gPlayerArmed: int = 1
var gPlayerAiming: int = 0
var gLastAmbushMs: int64 = 0
var gAmbushCooldownMs: int64 = 300000

# A small ring of recent facts, in words, for the prompt's `recentEvents`.
var gRecent: seq[string] = @[]

proc pushRecent(line: string) =
  if line.len == 0: return
  var keep: seq[string] = @[]
  var start = 0
  if gRecent.len >= 8: start = gRecent.len - 7
  var i = start
  while i < gRecent.len:
    keep.add gRecent[i]
    i = i + 1
  keep.add line
  gRecent = keep

proc recentEventsText*(): string =
  result = ""
  var i = 0
  while i < gRecent.len:
    if result.len > 0: result.add "\n"
    result.add gRecent[i]
    i = i + 1

# ---------------------------------------------------------------------------
# Tiny numeric helpers. std/math is not imported by any mod in this repo, so
# the one thing needed from it is written out rather than assumed present.
# ---------------------------------------------------------------------------

proc fabsf(v: float): float =
  if v < 0.0: -v else: v

proc fsqrt(v: float): float =
  ## Newton–Raphson. Deterministic, and it never divides by zero.
  if v <= 0.0: return 0.0
  var x = v
  if x < 1.0: x = 1.0
  var i = 0
  while i < 24:
    x = 0.5 * (x + v / x)
    i = i + 1
  result = x

proc dist3(ax, ay, az, bx, by, bz: float): float =
  let dx = ax - bx
  let dy = ay - by
  let dz = az - bz
  result = fsqrt(dx * dx + dy * dy + dz * dz)

proc clampAtt(v: int): int =
  if v < -100: -100 elif v > 100: 100 else: v

proc fclamp(v, lo, hi: float): float =
  if v < lo: lo elif v > hi: hi else: v

# ---------------------------------------------------------------------------
# Rows
# ---------------------------------------------------------------------------

proc findEnc(personId: string): int =
  result = -1
  var i = 0
  while i < gEncPerson.len:
    if gEncPerson[i] == personId: return i
    i = i + 1

proc ensureEnc(personId: string): int =
  result = findEnc(personId)
  if result >= 0: return
  gEncPerson.add personId
  gEncState.add "none"
  gEncCaptor.add ""
  gEncEscortTo.add ""
  gEncSinceMs.add worldClockMs()
  gEncWhy.add "created"
  gEncEscapes.add 0
  result = gEncPerson.len - 1

proc encounterState*(personId: string): string =
  let i = findEnc(personId)
  if i < 0: return "none"
  result = gEncState[i]

proc encounterCaptor*(personId: string): string =
  let i = findEnc(personId)
  if i < 0: return ""
  result = gEncCaptor[i]

proc captiveOf*(): string =
  ## The person currently holding the player, or "" — the one global fact the
  ## routes and the tick both need, so it is derived from the rows rather than
  ## kept as a second copy that can disagree with them.
  result = ""
  var i = 0
  while i < gEncPerson.len:
    if gEncState[i] == "captive" or gEncState[i] == "escorted":
      return gEncPerson[i]
    i = i + 1

proc encounterCount*(): int = gEncPerson.len

proc resetEncounters*() =
  gEncPerson = @[]
  gEncState = @[]
  gEncCaptor = @[]
  gEncEscortTo = @[]
  gEncSinceMs = @[]
  gEncWhy = @[]
  gEncEscapes = @[]

# ---------------------------------------------------------------------------
# Directives + journal. Both go through one place so a transition cannot emit
# without a record of why.
# ---------------------------------------------------------------------------

proc jsonOf2(k1, v1, k2, v2: string): string =
  var o = obj()
  o.put(k1, v1)
  o.put(k2, v2)
  result = done(o).text

proc directive(kind, payload: string; needsAck: bool; ttlMs: int64 = 0): int =
  ## One directive on the stream. Returns 1 so callers can sum them.
  discard emitEvent(kind, payload, needsAck, ttlMs)
  result = 1

proc setState(i: int; to, why: string) =
  if i < 0 or i >= gEncPerson.len: return
  let frm = gEncState[i]
  if frm == to and gEncWhy[i] == why: return
  gEncState[i] = to
  gEncWhy[i] = why
  gEncSinceMs[i] = worldClockMs()
  var o = obj()
  o.put("person", gEncPerson[i])
  o.put("from", frm)
  o.put("to", to)
  o.put("why", why)
  discard journal("encounter.state", gEncPerson[i], "player", done(o).text)
  pushRecent(gEncPerson[i] & ": " & frm & " -> " & to & " (" & why & ")")

proc bump(pi: int; delta: int) =
  if pi < 0: return
  setPersonAttitude(pi, clampAtt(personAttitude(pi) + delta))

proc stanceWord(pi: int): string =
  if pi < 0: return "neutral"
  let a = personAttitude(pi)
  if a <= -25: "hostile"
  elif a >= 25: "friendly"
  else: "neutral"

proc emitStance(personId: string; word: string): int =
  result = directive("npc.stance", jsonOf2("personId", personId,
                                           "stance", word), false)

proc emitBark(personId, text: string): int =
  ## A canned line from the machine itself, NOT from the brain. It is tagged
  ## `"source":"encounter"` precisely so nobody reads a barked threat as model
  ## output on the stream.
  var o = obj()
  o.put("personId", personId)
  o.put("text", text)
  o.put("wav", "")
  o.put("segmentIdx", 0)
  o.put("final", true)
  o.put("source", "encounter")
  result = directive("say", done(o).text, false)

# ---------------------------------------------------------------------------
# Captivity
# ---------------------------------------------------------------------------

const CaptorRoles = ["slaver", "raider", "lieutenant", "leader"]

proc canCapture(pi: int): bool =
  ## Only some roles enslave; DESIGN.md §6 names the slaver. The others are
  ## here because a raider lieutenant marching a prisoner is the same fiction,
  ## and a `[CAPTURE]` tag from a hermit medic is not.
  if pi < 0: return false
  let r = personRole(pi)
  for c in CaptorRoles:
    if r == c: return true
  result = false

proc escortTargetFor(pi: int): string =
  ## Where a captor marches the player: their faction's own camp if there is
  ## one, otherwise the place they are standing in.
  result = ""
  let fac = personFaction(pi)
  var i = 0
  while i < placeCount():
    if placeOwner(i) == fac:
      let k = placeKind(i)
      if k == "camp" or k == "outpost" or k == "market":
        return placeName(i)
    i = i + 1
  if result.len == 0: result = personPlace(pi)

proc captivityContractId(personId: string): string =
  result = "captivity." & personId

proc beginCaptivity(i, pi: int; why: string; note: var string): int =
  ## A `captivity` contract plus the `player.captive` directive that tells the
  ## client which slots to strip and how far the leash reaches.
  result = 0
  let personId = gEncPerson[i]
  let dest = escortTargetFor(pi)
  gEncCaptor[i] = personId
  gEncEscortTo[i] = dest
  let cid = captivityContractId(personId)
  # `addContract` opens a contract as "offered"; captivity is not an offer, so
  # the status is set explicitly whether the row is new or reused. (It was
  # only set on the reuse path once, and selfcheck 5 caught it: the state said
  # captive while the contract said offered.)
  discard addContract(cid, "captivity", personId, "player",
                      "the player is held by " & personName(pi) &
                      " and marched to " & dest,
                      "release, sale to another faction, or work",
                      worldClockMs() + 7200000)
  setContractStatus(findContract(cid), "active")
  setPersonActivity(pi, "captive_escort")
  setPersonEscorting(pi, true)
  let grp = personGroup(pi)
  if grp.len > 0:
    for gi in peopleOfGroup(grp):
      setPersonActivity(gi, "captive_escort")
      setPersonEscorting(gi, true)
  setState(i, "captive", why)
  remember(pi, "I took the player prisoner and started for " & dest & ".")

  var allowed = arr()
  allowed.add "walk"
  allowed.add "talk"
  allowed.add "drop"
  var o = obj()
  o.put("captorId", personId)
  o.put("captorName", personName(pi))
  o.put("allowedActions", allowed)
  o.put("escortTo", dest)
  o.put("leashM", gLeashM)
  o.put("stripWeapons", true)
  result = result + directive("player.captive", done(o).text, true, 20000)
  discard journal("captivity.begin", personId, "player",
                  jsonOf2("escortTo", dest, "why", why))
  note = personName(pi) & " has taken the player prisoner; escort to " & dest

proc endCaptivity(i: int; outcome, why: string; note: var string): int =
  result = 0
  let personId = gEncPerson[i]
  let pi = findPerson(personId)
  let ci = findContract(captivityContractId(personId))
  if ci >= 0:
    setContractStatus(ci, (if outcome == "released" or outcome == "sold": "fulfilled" else: "broken"))
  if pi >= 0:
    setPersonEscorting(pi, false)
    setPersonActivity(pi, "idle")
    let grp = personGroup(pi)
    if grp.len > 0:
      for gi in peopleOfGroup(grp):
        setPersonEscorting(gi, false)
        setPersonActivity(gi, "idle")
  gEncCaptor[i] = ""
  gEncEscortTo[i] = ""
  setState(i, outcome, why)
  discard journal("captivity.end", personId, "player",
                  jsonOf2("outcome", outcome, "why", why))
  if outcome != "sold":
    result = result + directive("player.release",
                                jsonOf2("captorId", personId,
                                        "outcome", outcome), false)
  note = "captivity over: " & outcome & " (" & why & ")"

proc sellPlayer(i: int; note: var string): int =
  ## The `sold` branch: a person of ANOTHER faction becomes the new captor and
  ## a fresh captivity contract opens under them.
  result = 0
  let oldId = gEncPerson[i]
  let oi = findPerson(oldId)
  var buyer = -1
  var pi = 0
  while pi < personCount():
    if personAlive(pi) and personFaction(pi) != personFaction(oi) and canCapture(pi):
      buyer = pi
      break
    pi = pi + 1
  if buyer < 0:
    note = "nobody to sell the player to (no live captor-capable person of " &
           "another faction); releasing instead"
    return endCaptivity(i, "released", "no buyer", note)
  result = result + endCaptivity(i, "sold", "sold to " & personName(buyer), note)
  let bi = ensureEnc(personId(buyer))
  var n2 = ""
  result = result + beginCaptivity(bi, buyer, "bought the player", n2)
  if oi >= 0: remember(oi, "I sold the player to " & personName(buyer) & ".")
  note = "the player was sold to " & personName(buyer) & "; " & n2

proc offerWorkQuest(i, pi: int; note: var string): int =
  ## The third arrival branch: work the debt off.
  result = 0
  let qid = "debt." & gEncPerson[i]
  if findQuest(qid) < 0:
    var objectives: seq[string] = @[]
    objectives.add "do what " & personName(pi) & " asks"
    discard addQuest(qid, gEncPerson[i], "Work it off",
                     personName(pi) & " will let the player walk in exchange " &
                     "for a job", "fetch", "", "freedom", objectives)
  var o = obj()
  o.put("questId", qid)
  o.put("giverId", gEncPerson[i])
  o.put("title", "Work it off")
  o.put("reward", "freedom")
  result = result + directive("quest.offer", done(o).text, true, 60000)
  result = result + endCaptivity(i, "released", "took the work instead", note)
  note = "released on a debt-work quest (" & qid & ")"

# ---------------------------------------------------------------------------
# Ambush ("being jumped", DESIGN.md §6)
# ---------------------------------------------------------------------------

proc maybeAmbush(map: string; x, y, z: float; note: var string): int =
  ## The player walked into a dangerous place owned by a faction that dislikes
  ## them. Emits `group.spawn` + a leader's bark and puts the leader in
  ## `threatened`. Rate-limited, so walking in circles is not a war.
  result = 0
  if worldClockMs() - gLastAmbushMs < gAmbushCooldownMs: return
  var i = 0
  while i < placeCount():
    if placeMap(i) == map and placeDanger(i) >= 0.6:
      var px = 0.0
      var py = 0.0
      var pz = 0.0
      placePos(i, px, py, pz)
      let d = dist3(x, y, z, px, py, pz)
      if d <= gNoticeM:
        let fi = findFaction(placeOwner(i))
        if fi >= 0 and factionRep(fi) < 0:
          gLastAmbushMs = worldClockMs()
          var o = obj()
          o.put("factionId", placeOwner(i))
          o.put("count", 3)
          o.put("near", placeName(i))
          o.put("map", map)
          o.put("reason", "ambush: the player is inside " & placeName(i) &
                          ", which " & factionName(fi) & " holds")
          result = result + directive("group.spawn", done(o).text, true, 30000)
          discard journal("ambush", placeOwner(i), "player",
                          jsonOf2("place", placeName(i), "map", map))
          # The leader of that faction, if one is alive, does the talking.
          for pj in peopleOfFaction(fi):
            if personAlive(pj) and canCapture(pj):
              let ei = ensureEnc(personId(pj))
              setState(ei, "threatened", "ambush")
              result = result + emitStance(personId(pj), "hostile")
              result = result + emitBark(personId(pj),
                "Far enough. You are standing on " & factionName(fi) & " ground.")
              break
          note = "ambush near " & placeName(i)
          return
    i = i + 1

# ---------------------------------------------------------------------------
# The prompt types (bm/prompt) built from world state
# ---------------------------------------------------------------------------

proc joinSeq(items: seq[string]; sep: string): string =
  result = ""
  var i = 0
  while i < items.len:
    if result.len > 0: result.add sep
    result.add items[i]
    i = i + 1

proc cardFor*(personId: string): PersonCard =
  ## Plain strings only — `bm/prompt` and `bm/brain` never see `bm/world`.
  result = PersonCard(id: personId, name: "", faction: "", factionCreed: "",
                      role: "", voice: "", traits: "", wants: "", forbids: "",
                      attitude: 0, factionRep: 0, mood: 0.0,
                      inventoryNote: "", placeName: "", map: "")
  let i = findPerson(personId)
  if i < 0: return
  result.name = personName(i)
  result.role = personRole(i)
  result.voice = personVoice(i)
  result.traits = joinSeq(personTraits(i), ", ")
  result.attitude = personAttitude(i)
  result.mood = personMood(i)
  result.inventoryNote = personInventoryNote(i)
  result.map = personMap(i)
  let pl = findPlace(personPlace(i))
  result.placeName = (if pl >= 0: placeName(pl) else: personPlace(i))
  let fi = findFaction(personFaction(i))
  if fi >= 0:
    result.faction = factionName(fi)
    result.factionCreed = factionCreed(fi)
    result.factionRep = factionRep(fi)
    result.wants = joinSeq(factionWants(fi), ", ")
    result.forbids = joinSeq(factionForbids(fi), ", ")

proc timeOfDayText(): string =
  ## The world's own clock, not the wall clock: a world that has been advanced
  ## six hours is in a different part of its day even though nothing outside
  ## moved.
  let hour = int((worldClockMs() div 3600000) mod 24)
  if hour < 5: "night"
  elif hour < 11: "morning"
  elif hour < 17: "afternoon"
  elif hour < 21: "evening"
  else: "night"

proc situationFor*(personId: string): Situation =
  result = Situation(state: encounterState(personId),
                     playerArmed: gPlayerArmed == 1,
                     playerAiming: gPlayerAiming == 1,
                     distanceM: 0.0, playerHp: playerHp(), npcHp: 1.0,
                     groupSize: 1, timeOfDay: timeOfDayText(),
                     recentEvents: recentEventsText())
  let i = findPerson(personId)
  if i < 0: return
  result.npcHp = personHp(i)
  var pmap = ""
  var px = 0.0
  var py = 0.0
  var pz = 0.0
  playerPos(pmap, px, py, pz)
  var x = 0.0
  var y = 0.0
  var z = 0.0
  personPos(i, x, y, z)
  if pmap.len == 0 or pmap == personMap(i):
    result.distanceM = dist3(px, py, pz, x, y, z)
  else:
    result.distanceM = 9999.0
  let grp = personGroup(i)
  if grp.len > 0:
    var n = 0
    for gi in peopleOfGroup(grp):
      if personAlive(gi): n = n + 1
    if n > 0: result.groupSize = n

# ---------------------------------------------------------------------------
# Tags — the LLM's only actuator (DESIGN.md §4). EVERY tag of the grammar is
# mapped here; an unknown one is dropped WITH a note.
# ---------------------------------------------------------------------------

proc tagName(tag: string): string =
  var t = tag
  if t.len > 0 and t[0] == '[': t = t.substr(1)
  if t.len > 0 and t[t.len - 1] == ']': t = t.substr(0, t.len - 2)
  let c = find(t, ":")
  if c >= 0: t = t.substr(0, c - 1)
  result = toUpperAscii(strip(t))

proc tagValue(tag: string): string =
  var t = tag
  if t.len > 0 and t[0] == '[': t = t.substr(1)
  if t.len > 0 and t[t.len - 1] == ']': t = t.substr(0, t.len - 2)
  let c = find(t, ":")
  if c < 0: return ""
  result = strip(t.substr(c + 1))

proc pipeSplit(s: string): seq[string] =
  result = @[]
  for part in s.split('|'):
    result.add strip(part)

proc parseIntOr(s: string; default: int): int =
  ## Hand-written because nimony forbids exceptions as control flow and a
  ## malformed tag value must be a DEFAULT with a note, never a raise across a
  ## route. Accepts a leading '+' or '-' and stops at the first non-digit.
  var t = strip(s)
  if t.len == 0: return default
  var i = 0
  var sign = 1
  if t[0] == '+': i = 1
  elif t[0] == '-':
    sign = -1
    i = 1
  var seen = 0
  var v = 0
  while i < t.len:
    let c = t[i]
    if c >= '0' and c <= '9':
      v = v * 10 + (int(c) - int('0'))
      seen = seen + 1
    else:
      break
    i = i + 1
  if seen == 0: return default
  result = sign * v

proc parseFloatOr(s: string; default: float): float =
  var t = strip(s)
  if t.len == 0: return default
  var i = 0
  var sign = 1.0
  if t[0] == '+': i = 1
  elif t[0] == '-':
    sign = -1.0
    i = 1
  var seen = 0
  var whole = 0.0
  while i < t.len and t[i] >= '0' and t[i] <= '9':
    whole = whole * 10.0 + float(int(t[i]) - int('0'))
    seen = seen + 1
    i = i + 1
  var frac = 0.0
  var scale = 1.0
  if i < t.len and t[i] == '.':
    i = i + 1
    while i < t.len and t[i] >= '0' and t[i] <= '9':
      scale = scale * 10.0
      frac = frac + float(int(t[i]) - int('0')) / scale
      seen = seen + 1
      i = i + 1
  if seen == 0: return default
  result = sign * (whole + frac)

proc applyTags*(personId: string; tags: seq[string]; note: var string): int =
  ## Tag -> state / contract / directive. Returns directives emitted.
  result = 0
  var notes: seq[string] = @[]
  let pi = findPerson(personId)
  if pi < 0:
    note = "no such person '" & personId & "'; no tag was applied"
    return 0
  let ei = ensureEnc(personId)
  for tag in tags:
    let name = tagName(tag)
    let val = tagValue(tag)
    case name
    of "MOOD":
      setPersonMood(pi, fclamp(parseFloatOr(val, personMood(pi)), -1.0, 1.0))
      notes.add "mood set"
    of "ATTITUDE":
      bump(pi, parseIntOr(val, 0))
      result = result + emitStance(personId, stanceWord(pi))
      notes.add "attitude " & val
    of "OFFER":
      let cid = "offer." & personId & "." & $contractCount()
      discard addContract(cid, "deal", personId, "player", val, "",
                          worldClockMs() + 1800000)
      setState(ei, "dealing", "offered terms")
      var o = obj()
      o.put("personId", personId)
      o.put("contractId", cid)
      o.put("terms", val)
      result = result + directive("quest.update", done(o).text, false)
      notes.add "offer recorded as contract " & cid
    of "ACCEPT":
      let ci = activeContractOfKind("deal", "player")
      if ci >= 0: setContractStatus(ci, "active")
      setState(ei, "deal_struck", "accepted")
      bump(pi, 5)
      notes.add "deal struck"
    of "REFUSE":
      setState(ei, "refused", "refused")
      notes.add "refused"
    of "DEMAND":
      let parts = pipeSplit(val)
      var o = obj()
      o.put("personId", personId)
      o.put("demand", (if parts.len > 0: parts[0] else: val))
      o.put("orElse", (if parts.len > 1: parts[1] else: ""))
      setState(ei, "threatened", "demand")
      result = result + directive("hud.note",
        jsonOf2("text", personName(pi) & " demands: " & val, "personId", personId), false)
      result = result + directive("quest.update", done(o).text, false)
      notes.add "demand issued"
    of "GIVE":
      result = result + directive("npc.give",
        jsonOf2("personId", personId, "item", val), true, 20000)
      bump(pi, 3)
      notes.add "gives " & val
    of "TAKE":
      result = result + directive("npc.take",
        jsonOf2("personId", personId, "item", val), true, 20000)
      notes.add "takes " & val
    of "CAPTURE":
      if not canCapture(pi):
        notes.add "[CAPTURE] refused: " & personName(pi) & " is a " &
                  personRole(pi) & ", which does not take prisoners"
      elif captiveOf().len > 0:
        notes.add "[CAPTURE] refused: the player is already held by " & captiveOf()
      else:
        var n = ""
        result = result + beginCaptivity(ei, pi, "captured by tag", n)
        notes.add n
    of "RELEASE":
      if gEncState[ei] == "captive" or gEncState[ei] == "escorted":
        var n = ""
        result = result + endCaptivity(ei, "released", "released by tag", n)
        notes.add n
      else:
        notes.add "[RELEASE] had no effect: the player is not held by this person"
    of "FOLLOW_ME":
      result = result + directive("npc.follow",
        jsonOf2("personId", personId, "target", "player"), true, 20000)
      notes.add "asks the player to follow"
    of "FOLLOW_YOU":
      result = result + directive("npc.follow",
        jsonOf2("personId", personId, "target", "player"), true, 20000)
      setPersonActivity(pi, "travel")
      notes.add "follows the player"
    of "STAY":
      result = result + directive("npc.hold",
        jsonOf2("personId", personId, "reason", "told to stay"), false)
      setPersonActivity(pi, "guard")
      notes.add "holds position"
    of "LEAVE":
      setState(ei, "parted", "left")
      setPersonActivity(pi, "patrol")
      var x = 0.0
      var y = 0.0
      var z = 0.0
      personPos(pi, x, y, z)
      var o = obj()
      o.put("personId", personId)
      o.put("x", x)
      o.put("y", y)
      o.put("z", z)
      result = result + directive("npc.goto", done(o).text, false)
      notes.add "leaves"
    of "ATTACK":
      setState(ei, "fighting", "attack tag")
      setPersonAttitude(pi, clampAtt(personAttitude(pi) - 30))
      result = result + emitStance(personId, "hostile")
      result = result + directive("npc.attack",
        jsonOf2("personId", personId, "target", "player"), true, 15000)
      notes.add "attacks"
    of "STAND_DOWN":
      if gEncState[ei] == "fighting" or gEncState[ei] == "threatened":
        setState(ei, "talking", "stood down")
      result = result + emitStance(personId, stanceWord(pi))
      notes.add "stands down"
    of "QUEST":
      let parts = pipeSplit(val)
      let title = (if parts.len > 0: parts[0] else: val)
      let brief = (if parts.len > 1: parts[1] else: "")
      let reward = (if parts.len > 2: parts[2] else: "")
      let qid = "q." & personId & "." & $questCount()
      var objectives: seq[string] = @[]
      if brief.len > 0: objectives.add brief
      discard addQuest(qid, personId, title, brief, "fetch", "", reward, objectives)
      var o = obj()
      o.put("questId", qid)
      o.put("giverId", personId)
      o.put("title", title)
      o.put("brief", brief)
      o.put("reward", reward)
      result = result + directive("quest.offer", done(o).text, true, 60000)
      notes.add "offers quest " & qid
    of "QUEST_DONE":
      let qi = findQuest(val)
      if qi < 0:
        notes.add "[QUEST_DONE] names no quest we know: " & val
      else:
        setQuestStatus(qi, "done")
        result = result + directive("quest.update",
          jsonOf2("questId", val, "status", "done"), false)
        notes.add "quest done " & val
    of "REMEMBER":
      remember(pi, val)
      notes.add "remembers"
    of "RUMOUR":
      addFact("rumour." & personId & "." & $factCount(), "rumour " & personId, val)
      notes.add "rumour recorded"
    of "CALL":
      let ti = findPerson(val)
      if ti < 0:
        notes.add "[CALL] names nobody: " & val
      else:
        var x = 0.0
        var y = 0.0
        var z = 0.0
        personPos(pi, x, y, z)
        var o = obj()
        o.put("personId", val)
        o.put("target", personId)
        result = result + directive("npc.follow", done(o).text, true, 30000)
        notes.add "calls " & personName(ti)
    of "OBJ":
      result = result + directive("hud.note",
        jsonOf2("text", val, "mode", "set"), false)
      notes.add "objective set"
    of "ADD":
      result = result + directive("hud.note",
        jsonOf2("text", val, "mode", "add"), false)
      notes.add "objective added"
    of "CLEAR":
      result = result + directive("hud.note",
        jsonOf2("text", "", "mode", "clear"), false)
      notes.add "objectives cleared"
    else:
      notes.add "unknown tag '" & name & "' dropped (not in the grammar)"
  note = joinSeq(notes, "; ")

# ---------------------------------------------------------------------------
# observe — the client's facts
# ---------------------------------------------------------------------------

proc dataText(dataJson, key, default: string): string =
  if dataJson.len == 0: return default
  result = jr.asText(jr.field(dataJson, key), default)

proc dataFloat(dataJson, key: string; default: float): float =
  if dataJson.len == 0: return default
  result = jr.asFloat(jr.field(dataJson, key), default)

proc whoIsIt(actorId, targetId, dataJson: string): string =
  ## Which person this fact is about. The route may name them as the actor, as
  ## the target, or inside the payload; all three are accepted rather than
  ## making the client guess which one this particular fact wants.
  if actorId.len > 0 and findPerson(actorId) >= 0: return actorId
  if targetId.len > 0 and findPerson(targetId) >= 0: return targetId
  let d1 = dataText(dataJson, "personId", "")
  if d1.len > 0: return d1
  let d2 = dataText(dataJson, "at", "")
  if d2.len > 0: return d2
  let d3 = dataText(dataJson, "by", "")
  if d3.len > 0: return d3
  result = actorId

proc nearestCaptorCandidate(): int =
  ## Who takes the player prisoner when the weapon goes down and nobody was
  ## named: the closest live capture-capable person inside the threat radius.
  result = -1
  var best = gNoticeM
  var pmap = ""
  var px = 0.0
  var py = 0.0
  var pz = 0.0
  playerPos(pmap, px, py, pz)
  var i = 0
  while i < personCount():
    if personAlive(i) and canCapture(i) and (pmap.len == 0 or personMap(i) == pmap):
      var x = 0.0
      var y = 0.0
      var z = 0.0
      personPos(i, x, y, z)
      let d = dist3(px, py, pz, x, y, z)
      if d <= best:
        best = d
        result = i
    i = i + 1

proc escortStep(note: var string): int =
  ## One step of every escort in progress. Arriving resolves the captivity by
  ## the captor's attitude (DESIGN.md �6): released, sold, or work.
  result = 0
  var i = 0
  while i < gEncPerson.len:
    let marching = gEncState[i] == "captive" or gEncState[i] == "escorted"
    let pi = findPerson(gEncPerson[i])
    if marching and pi >= 0:
      if not personAlive(pi):
        var n = ""
        result = result + endCaptivity(i, "escaped", "the captor is dead", n)
        note = n
      else:
        var dest = -1
        var j = 0
        while j < placeCount():
          if placeName(j) == gEncEscortTo[i] or placeId(j) == gEncEscortTo[i]:
            dest = j
            j = placeCount()
          else:
            j = j + 1
        if dest < 0:
          # An escort with a destination we cannot find is not a silent no-op:
          # it says so in the note the caller prints.
          note = "escort target '" & gEncEscortTo[i] & "' is not a place in " &
                 "this world; " & gEncPerson[i] & " is standing still"
        else:
          var dx = 0.0
          var dy = 0.0
          var dz = 0.0
          placePos(dest, dx, dy, dz)
          var x = 0.0
          var y = 0.0
          var z = 0.0
          personPos(pi, x, y, z)
          let d = dist3(x, y, z, dx, dy, dz)
          if d <= 6.0:
            let att = personAttitude(pi)
            var n = ""
            if att >= 10:
              result = result + endCaptivity(i, "released",
                                             "arrived; the captor relented", n)
            elif att <= -30:
              result = result + sellPlayer(i, n)
            else:
              result = result + offerWorkQuest(i, pi, n)
            note = n
          else:
            if gEncState[i] == "captive": setState(i, "escorted", "marching")
            # A third of the way each tick, and the player is dragged along:
            # the client enforces the leash, the backend keeps the position it
            # will answer /world/people with.
            let nx = x + (dx - x) / 3.0
            let ny = y + (dy - y) / 3.0
            let nz = z + (dz - z) / 3.0
            setPersonPos(pi, personMap(pi), personPlace(pi), nx, ny, nz)
            setPlayerPos(personMap(pi), nx, ny, nz)
            let grp = personGroup(pi)
            if grp.len > 0:
              for gi in peopleOfGroup(grp):
                if gi != pi:
                  setPersonPos(gi, personMap(pi), personPlace(pi), nx, ny, nz)
            var o = obj()
            o.put("personId", gEncPerson[i])
            o.put("x", dx)
            o.put("y", dy)
            o.put("z", dz)
            result = result + directive("npc.goto", done(o).text, false)
    i = i + 1

proc observe*(kind, actorId, targetId, dataJson: string; note: var string): int =
  ## One reported fact -> transitions -> directives. Returns how many
  ## directives were emitted; `note` always says what happened, including when
  ## the answer is "nothing, and here is why".
  result = 0
  var notes: seq[string] = @[]
  let who = whoIsIt(actorId, targetId, dataJson)
  let pi = findPerson(who)
  let ei = (if pi >= 0: ensureEnc(who) else: -1)

  case kind
  of "player_seen":
    if pi < 0:
      note = "player_seen names no person we know ('" & who & "')"
      return 0
    var d = dataFloat(dataJson, "distanceM", -1.0)
    if d < 0.0: d = situationFor(who).distanceM
    setPersonLastSeenMs(pi, worldClockMs())
    if d <= gNoticeM and gEncState[ei] == "none":
      setState(ei, "noticed", "saw the player at " & $int(d) & " m")
      result = result + emitStance(who, stanceWord(pi))
    notes.add "distance " & $int(d) & " m, state " & gEncState[ei]

  of "player_aimed_at":
    if pi < 0:
      note = "player_aimed_at names no person we know ('" & who & "')"
      return 0
    gPlayerAiming = 1
    gPlayerArmed = 1
    bump(pi, -15)
    setState(ei, "threatened", "the player aimed a weapon")
    result = result + emitStance(who, "hostile")
    result = result + emitBark(who, "Weapon down. Now.")
    remember(pi, "The player pointed a gun at me.")
    discard journal("threatened", who, "player", jsonOf2("by", "player", "how", "aimed"))
    notes.add personName(pi) & " is threatened and hostile"

  of "player_lowered_weapon":
    gPlayerAiming = 0
    var captor = pi
    if captor < 0 or not canCapture(captor):
      let alt = nearestCaptorCandidate()
      if alt >= 0 and (captor < 0 or not canCapture(captor)): captor = alt
    if captor >= 0 and canCapture(captor) and captiveOf().len == 0:
      let ci = ensureEnc(personId(captor))
      if gEncState[ci] == "threatened" or gEncState[ci] == "noticed" or
         gEncState[ci] == "hailed" or gEncState[ci] == "talking":
        var n = ""
        result = result + beginCaptivity(ci, captor, "surrendered to a captor", n)
        notes.add n
      else:
        setState(ci, "talking", "weapon lowered")
        notes.add personName(captor) & " lets it go for now"
    elif pi >= 0:
      setState(ei, "talking", "weapon lowered")
      result = result + emitStance(who, stanceWord(pi))
      notes.add "weapon lowered; talking"
    else:
      notes.add "weapon lowered, but no capture-capable person is within " &
                $int(gNoticeM) & " m and none was named"

  of "player_fired":
    gPlayerArmed = 1
    let held = captiveOf()
    if held.len > 0 and (who == held or who.len == 0):
      let hi = ensureEnc(held)
      let hp = findPerson(held)
      discard journal("escape_by_force", held, "player",
                      jsonOf2("from", gEncState[hi], "how", "fired on the captor"))
      let ci = findContract(captivityContractId(held))
      if ci >= 0: setContractStatus(ci, "broken")
      if hp >= 0:
        setPersonEscorting(hp, false)
        setPersonActivity(hp, "hunt")
        setPersonAttitude(hp, clampAtt(personAttitude(hp) - 40))
      gEncCaptor[hi] = ""
      gEncEscortTo[hi] = ""
      setState(hi, "fighting", "the player fired on their captor")
      result = result + emitStance(held, "hostile")
      result = result + directive("npc.attack",
        jsonOf2("personId", held, "target", "player"), true, 15000)
      notes.add "the captivity is broken by force; " & held & " is fighting"
    elif pi >= 0:
      bump(pi, -35)
      setState(ei, "fighting", "the player fired")
      result = result + emitStance(who, "hostile")
      result = result + directive("npc.attack",
        jsonOf2("personId", who, "target", "player"), true, 15000)
      notes.add personName(pi) & " is fighting"
    else:
      notes.add "player_fired at nobody we know ('" & who & "')"

  of "player_hit":
    let hp = dataFloat(dataJson, "hp", playerHp())
    setPlayerHp(fclamp(hp, 0.0, 1.0))
    if pi >= 0:
      setState(ei, "fighting", "hit the player")
      result = result + emitStance(who, "hostile")
    notes.add "player hp " & $int(hp * 100.0) & "%"

  of "npc_died":
    if pi < 0:
      note = "npc_died names no person we know ('" & who & "')"
      return 0
    setPersonAlive(pi, false)
    setPersonHp(pi, 0.0)
    discard journal("npc.died", who, dataText(dataJson, "by", "unknown"), "{}")
    setState(ei, "dead", "died")
    let held = captiveOf()
    if held == who:
      var n = ""
      result = result + endCaptivity(ei, "escaped", "the captor is dead", n)
      notes.add n
    # Their faction remembers it.
    let fi = findFaction(personFaction(pi))
    if fi >= 0 and dataText(dataJson, "by", "") == "player":
      setFactionRep(fi, clampAtt(factionRep(fi) - 15))
      for pj in peopleOfFaction(fi):
        if personAlive(pj):
          setPersonAttitude(pj, clampAtt(personAttitude(pj) - 10))
          remember(pj, "The player killed " & personName(pi) & ".")
      notes.add factionName(fi) & " rep is now " & $factionRep(fi)

  of "player_died":
    discard journal("player.died", dataText(dataJson, "by", "unknown"), "player", "{}")
    setPlayerHp(0.0)
    let held = captiveOf()
    if held.len > 0:
      var n = ""
      result = result + endCaptivity(findEnc(held), "dead", "the player died in captivity", n)
      notes.add n
    var i = 0
    while i < gEncPerson.len:
      if gEncState[i] != "dead": setState(i, "none", "the player died")
      i = i + 1
    result = result + directive("hud.note",
      jsonOf2("text", "You died. The world kept going.", "mode", "set"), false)

  of "player_moved":
    let map = dataText(dataJson, "map", "")
    let x = dataFloat(dataJson, "x", 0.0)
    let y = dataFloat(dataJson, "y", 0.0)
    let z = dataFloat(dataJson, "z", 0.0)
    setPlayerPos(map, x, y, z)
    let held = captiveOf()
    if held.len > 0:
      let hi = findEnc(held)
      let hp = findPerson(held)
      if hp >= 0:
        var cx = 0.0
        var cy = 0.0
        var cz = 0.0
        personPos(hp, cx, cy, cz)
        let d = dist3(x, y, z, cx, cy, cz)
        if d > gLeashM:
          gEncEscapes[hi] = gEncEscapes[hi] + 1
          # Resolved by the captor's attitude and how many of them there are —
          # journaled EITHER WAY, because the attempt is the fact.
          var group = 1
          let grp = personGroup(hp)
          if grp.len > 0:
            var n = 0
            for gi in peopleOfGroup(grp):
              if personAlive(gi): n = n + 1
            if n > group: group = n
          let att = personAttitude(hp)
          let caught = group >= 2 or att <= -20 or gEncEscapes[hi] < 2
          var o = obj()
          o.put("captorId", held)
          o.put("distanceM", d)
          o.put("leashM", gLeashM)
          o.put("groupSize", group)
          o.put("captorAttitude", att)
          o.put("outcome", (if caught: "recaptured" else: "escaped"))
          o.put("attempt", gEncEscapes[hi])
          discard journal("escape_attempt", held, "player", done(o).text)
          if caught:
            setPersonAttitude(hp, clampAtt(att - 10))
            result = result + emitBark(held, "Back in line.")
            result = result + directive("npc.follow",
              jsonOf2("personId", held, "target", "player"), false)
            notes.add "escape attempt " & $gEncEscapes[hi] &
                      " at " & $int(d) & " m: recaptured (group " & $group &
                      ", attitude " & $att & ")"
          else:
            var n = ""
            result = result + endCaptivity(hi, "escaped", "broke the leash", n)
            notes.add "escape attempt " & $gEncEscapes[hi] & ": " & n
    var n2 = ""
    result = result + maybeAmbush(map, x, y, z, n2)
    if n2.len > 0: notes.add n2

  of "player_gave":
    if pi < 0:
      note = "player_gave names no person we know ('" & who & "')"
      return 0
    let item = dataText(dataJson, "item", "")
    bump(pi, 10)
    remember(pi, "The player gave me " & item & ".")
    discard journal("player.gave", "player", who, jsonOf2("item", item, "to", who))
    result = result + emitStance(who, stanceWord(pi))
    # A gift settles a debt or a captivity if the terms name the thing.
    var ci = 0
    while ci < contractCount():
      if contractPartyA(ci) == who and contractStatus(ci) == "active" and
         item.len > 0 and contains(toLowerAscii(contractTerms(ci)), toLowerAscii(item)):
        setContractStatus(ci, "fulfilled")
        notes.add "contract " & contractKind(ci) & " fulfilled by the gift"
        if contractKind(ci) == "captivity" and ei >= 0:
          var n = ""
          result = result + endCaptivity(ei, "released", "paid their way out", n)
          notes.add n
      ci = ci + 1
    notes.add personName(pi) & " attitude " & $personAttitude(pi)

  of "player_took":
    let item = dataText(dataJson, "item", "")
    discard journal("player.took", "player", "", jsonOf2("item", item, "map", ""))
    var pmap = ""
    var px = 0.0
    var py = 0.0
    var pz = 0.0
    playerPos(pmap, px, py, pz)
    var seenBy = 0
    for wi in peopleNear(pmap, px, py, pz, gNoticeM):
      setPersonAttitude(wi, clampAtt(personAttitude(wi) - 5))
      remember(wi, "The player took " & item & " in front of me.")
      seenBy = seenBy + 1
    notes.add $seenBy & " people saw it"

  of "player_spoke":
    # The words themselves go through /say -> brain; this only records that a
    # conversation is happening, so `situationFor` is honest about the state.
    if pi >= 0:
      if gEncState[ei] == "none" or gEncState[ei] == "noticed":
        setState(ei, "hailed", "the player spoke")
      elif gEncState[ei] == "hailed":
        setState(ei, "talking", "the conversation continued")
      notes.add "state " & gEncState[ei]
    else:
      notes.add "player_spoke with nobody named"

  of "player_extracted", "raid_ended":
    var i = 0
    while i < gEncPerson.len:
      if gEncState[i] != "dead" and gEncState[i] != "captive" and
         gEncState[i] != "escorted":
        setState(i, "none", kind)
      i = i + 1
    discard journal(kind, "player", "", "{}")
    notes.add "encounters reset; captivity (if any) survives the raid"

  of "raid_started":
    let map = dataText(dataJson, "map", "")
    setPlayerPos(map, dataFloat(dataJson, "x", 0.0),
                 dataFloat(dataJson, "y", 0.0), dataFloat(dataJson, "z", 0.0))
    discard journal("raid.started", "player", "", jsonOf2("map", map, "why", "client"))
    notes.add "player is on " & map

  of "tick":
    let nowMs = int64(jr.asInt(jr.field(dataJson, "nowMs"), 0))
    if nowMs > 0: discard nowMs   # the world clock is the sim's to advance
    var n = ""
    result = result + escortStep(n)
    if n.len > 0: notes.add n

  else:
    note = "unknown fact kind '" & kind & "'; nothing was applied. Known " &
           "kinds: player_seen player_aimed_at player_fired " &
           "player_lowered_weapon player_spoke player_hit npc_died " &
           "player_died player_moved player_gave player_took " &
           "player_extracted raid_started raid_ended tick"
    return 0

  if notes.len == 0: notes.add kind & " applied; nothing changed"
  note = joinSeq(notes, "; ")
  pushRecent(kind & (if who.len > 0: " (" & who & ")" else: ""))

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

proc encounterJson*(): JsonArray =
  result = arr()
  var i = 0
  while i < gEncPerson.len:
    var o = obj()
    o.put("personId", gEncPerson[i])
    let pi = findPerson(gEncPerson[i])
    o.put("name", (if pi >= 0: personName(pi) else: ""))
    o.put("role", (if pi >= 0: personRole(pi) else: ""))
    o.put("state", gEncState[i])
    o.put("why", gEncWhy[i])
    o.put("captorOfPlayer", gEncCaptor[i])
    o.put("escortTo", gEncEscortTo[i])
    o.put("escapeAttempts", gEncEscapes[i])
    o.put("sinceMs", int(gEncSinceMs[i]))
    o.put("distanceM", situationFor(gEncPerson[i]).distanceM)
    result.add o
    i = i + 1
