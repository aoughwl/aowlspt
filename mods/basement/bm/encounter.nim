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
import ontology
import hearing
import rng
import util
import items
import gen
import speech
import offscreen

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
var gEncBarkMs: seq[int64] = @[]       # when this person last barked at the player
var gEncAimTicks: seq[int] = @[]       # aim reports SUPPRESSED since that bark
var gEncStanceSent: seq[string] = @[]  # last npc.stance word actually emitted
var gEncAttackFor: seq[string] = @[]   # the transition an npc.attack was sent for

# How long a person stays barked-out. MEASURED 2026-09-07 in the first SPT
# 4.1.5 raid: `player_aimed_at` arrives every client tick while the crosshair
# rests on someone, so the threat transition re-fired dozens of times -- ~40
# `npc.attack` directives in two minutes, and every person in the world saying
# the one sentence "Weapon down. Now." over and over. The state machine was
# right; it simply had no hysteresis.
var gBarkCooldownMs: int64 = 20000

# The per-turn bound on what a single reply may do to a relationship. See the
# MOOD/ATTITUDE cases in `applyTags` for the measurement that produced them.
const MaxAttitudeStep = 15
const MaxMoodStep = 0.4

proc encounterConfigureBarks*(cooldownMs: int) =
  if cooldownMs >= 0: gBarkCooldownMs = int64(cooldownMs)

proc barkCooldownMs*(): int64 = gBarkCooldownMs

# Player-side facts the client reports, remembered so `situationFor` can answer
# without the caller having to pass them in.
var gPlayerArmed: int = 1
var gPlayerAiming: int = 0
var gLastAmbushMs: int64 = 0
var gAmbushCooldownMs: int64 = 300000

# What the player has handed over, by item word. `resolveClaim` needs it: a
# token can be a passphrase OR an object, and "he gave me the thing the bearer
# was supposed to bring" is the strongest evidence an impostor can produce.
var gGaveItems: seq[string] = @[]

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
  gEncBarkMs.add -1
  gEncAimTicks.add 0
  gEncStanceSent.add ""
  gEncAttackFor.add ""
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
  hearingReset()
  gEncPerson = @[]
  gEncState = @[]
  gEncCaptor = @[]
  gEncEscortTo = @[]
  gEncSinceMs = @[]
  gEncWhy = @[]
  gEncEscapes = @[]
  gEncBarkMs = @[]
  gEncAimTicks = @[]
  gEncStanceSent = @[]
  gEncAttackFor = @[]

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

proc transitionToken(i: int): string =
  if i < 0 or i >= gEncState.len: return ""
  result = gEncState[i] & "@" & $gEncSinceMs[i]

proc emitStanceOnce(i: int; personId, word: string): int =
  ## `npc.stance` is a LEVEL, not an edge: re-sending "hostile" every tick the
  ## player keeps aiming tells the client nothing it does not already know, and
  ## that is most of what filled the ring. Emitted only when the word changes.
  if i >= 0 and i < gEncStanceSent.len:
    if gEncStanceSent[i] == word: return 0
    gEncStanceSent[i] = word
  result = emitStance(personId, word)

proc emitAttackOnce(i: int; personId: string): int =
  ## One `npc.attack` per STATE TRANSITION. It needs an ack, so a repeat is not
  ## merely noise: every un-acked copy is journaled `directive.dropped` at ttl,
  ## which is where the "directive N (npc.attack) was never acked" flood in the
  ## first SPT 4.1.5 raid came from.
  let tok = transitionToken(i)
  if i >= 0 and i < gEncAttackFor.len:
    if gEncAttackFor[i] == tok and tok.len > 0: return 0
    gEncAttackFor[i] = tok
  result = directive("npc.attack",
    jsonOf2("personId", personId, "target", "player"), true, 15000)

# The bark pools. Seven threats and five stand-downs, picked by a hash of the
# person's id, so ten people covered by one rifle do not speak in chorus. They
# are deliberately plain and short: a bark is shouted across a yard.
proc threatLineFor(personId: string): string =
  let lines = ["Weapon down. Now.",
               "Point that somewhere else. I will not ask twice.",
               "Muzzle down, or this ends badly for one of us.",
               "You want to do this? Because I am ready to.",
               "Barrel down. Slow. I am watching your hands.",
               "Hey. Off me with that thing.",
               "Lower it. Whatever you came for, it is not worth this."]
  result = lines[int(fnv1a64("threat\x1f" & personId) mod uint64(lines.len))]

proc standDownLineFor(personId: string): string =
  let lines = ["Better. Keep it down and we can talk.",
               "Good. Now say what you want, and say it quick.",
               "That is smarter than you looked. Talk.",
               "Alright. Hands where I can see them, and speak.",
               "Fine. You get one conversation out of me."]
  result = lines[int(fnv1a64("standdown\x1f" & personId) mod uint64(lines.len))]

proc emitBarkEx(personId, text: string; reaction, quiet: bool;
                yellText: string; note: var string): int =
  ## A canned line from the machine itself, NOT from the brain. It is tagged
  ## `"source":"encounter"` precisely so nobody reads a barked threat as model
  ## output on the stream.
  ##
  ## It goes through `speech.sayPayload`, the same builder `/say` uses, so a
  ## bark is SPOKEN and not merely printed: before 2026-09-07 this built its
  ## own object with `"wav":""` hardcoded and every encounter line arrived at
  ## the client mute. Split per sentence for the same reason the brain streams
  ## per sentence -- the client plays segments in order.
  ##
  ## And since 2026-09-07 it is HEARING-GATED (`bm/hearing`). Three outcomes,
  ## never two:
  ##   * within `hearSpeakM` -> spoken, `mode:"speak"`;
  ##   * within `hearYellM`  -> the line is REPLACED by its shouted form and
  ##     goes out as `mode:"yell"`, so the player is not asked to overhear a
  ##     conversational sentence from forty metres;
  ##   * beyond that -> NOTHING is emitted, `say.suppressed` is journaled and
  ##     the person remembers that they saw the player and could not be heard.
  ## `note` always says which, including the distance it used.
  result = 0
  note = ""
  var mode = "speak"
  var audible = true
  var why = ""
  let d = hearingDecide(personId, quiet, mode, audible, why)
  if not audible:
    journalSuppressed(personId, text, why)
    note = "not said: " & why
    return 0
  var line = text
  if mode == "yell":
    if yellText.len > 0:
      line = yellText
      note = "shouted (table variant); " & why
    else:
      var yn = ""
      line = yellVersionOf(personId, text, yn)
      note = "shouted (" & yn & "); " & why
  else:
    note = why
  let pi = findPerson(personId)
  let voice = (if pi >= 0: personVoice(pi) else: "")
  var parts = splitSentences(line)
  if parts.len == 0: parts = @[line]
  # QUEUED, not synthesised here -- MEASURED 2026-09-07: `sayPayload` called
  # `ttsSegment`, which for kokoro is a ~1.3 s blocking HTTP round trip, and a
  # bark raised from the tick ran it under the mod lock. `sayEnqueue` starts
  # the request and returns; `sayDrain` emits the segment when the wav lands.
  # The audibility verdict travels WITH the segment because `emitBarkEx`
  # decided it before it picked these words -- re-deciding at drain time would
  # use a distance a second or two stale.
  var i = 0
  while i < parts.len:
    discard sayEnqueue(personId, voice, parts[i], i, i == parts.len - 1,
                       "encounter", false, deco = true, distanceM = d,
                       mode = mode, audible = audible, reaction = reaction,
                       why = why)
    result = result + 1
    i = i + 1
  # For a synchronous engine (piper, sapi) every segment is already resolved,
  # so this emits all of them before the route returns and piper's timing is
  # unchanged; a kokoro segment simply stays queued for the tick.
  discard sayDrain()

proc emitBark(personId, text: string): int =
  var note = ""
  result = emitBarkEx(personId, text, false, false, "", note)

proc emitTrigger(personId, trigger: string; gapMs: int64;
                 reaction, quiet, markOnSuppress: bool;
                 note: var string): int =
  ## The proactive path: a person speaks because the MACHINE noticed something,
  ## not because the player said anything. Every one of them is
  ##   rate-limited (`hearing.triggerAllowed`)  ->
  ##   picked from `data/ontology.json`'s bark table (never written in code) ->
  ##   hearing-gated exactly like any other line.
  ## Returns the directive count; `note` names the gate that refused when it is
  ## zero, because a silent NPC is the hardest symptom there is to diagnose.
  result = 0
  note = ""
  let pi = findPerson(personId)
  if pi < 0 or not personAlive(pi):
    note = "'" & personId & "' is not a living person we know"
    return 0
  let now = wallMs()
  var why = ""
  if not triggerAllowed(personId, trigger, now, gapMs, why):
    note = trigger & " refused: " & why
    return 0
  # Decide speak/yell FIRST, so the line is chosen from the right column of the
  # table rather than written normally and then shouted.
  var mode = "speak"
  var audible = true
  var hwhy = ""
  discard hearingDecide(personId, quiet, mode, audible, hwhy)
  if not audible:
    # `markOnSuppress` is FALSE for `first_sight`, and that is a decision, not
    # an oversight: a person who first laid eyes on the player at 200 m has not
    # greeted them, and marking the trigger there would mean they never do,
    # however close the player walks afterwards.
    if markOnSuppress: markTrigger(personId, trigger, now)
    journalSuppressed(personId, "(" & trigger & ")", hwhy)
    note = trigger & " not said: " & hwhy
    return 0
  var onote = ""
  let bucket = bucketOf(personId)
  let salt = nextSalt(personId)
  let text = ontologyBark(trigger, bucket, personId, salt, mode == "yell", onote)
  if text.len == 0:
    note = trigger & " produced no line: " & onote
    return 0
  # `text` is ALREADY in the right register (the table has a yell column), so
  # the shout rewrite must not run over it again.
  var bnote = ""
  result = emitBarkEx(personId, text, reaction, quiet, text, bnote)
  if result > 0:
    markTrigger(personId, trigger, now)
    var jo = obj()
    jo.put("personId", personId)
    jo.put("trigger", trigger)
    jo.put("bucket", bucket)
    jo.put("mode", mode)
    jo.put("text", text)
    discard journal("say.proactive", personId, "player", done(jo).text)
  note = trigger & ": " & text & " [" & bucket & "/" & mode & "] " & bnote &
         (if onote.len > 0: " (" & onote & ")" else: "")

proc tauntGapMs(personId: string): int64 =
  ## 8-15 s, fixed per person. A single constant would have every fighter in a
  ## group taunt on the same beat, which reads as one voice with an echo.
  result = 8000'i64 + int64(fnv1a64("taunt\x1f" & personId) mod 7000'u64)

proc bystanderReactions*(addresseeId, utterance: string;
                         note: var string): int =
  ## ONLY THE ADDRESSEE ANSWERS. This is the other half of that rule.
  ##
  ## The user, 2026-09-07: *"everyone in the vicinity replies even if I can't
  ## hear their reply -- that's not good"*. The full reply belongs to the person
  ## the player was talking to, full stop. Everyone else who was close enough to
  ## OVERHEAR it (within `hearSpeakM` -- a conversation does not carry as far as
  ## a shout) may throw in at most a short table bark, marked `reaction:true` on
  ## the wire so a client, a log or a check can tell the two apart. It is never
  ## an LLM call: a reaction that cost a model turn would be a reply wearing a
  ## different hat.
  result = 0
  note = ""
  var spoke = 0
  var considered = 0
  var i = 0
  while i < gEncPerson.len:
    let who = gEncPerson[i]
    if who != addresseeId and gEncState[i] != "dead":
      let d = distanceOf(who)
      if d >= 0.0 and d <= hearSpeakM():
        considered = considered + 1
        # A hash, not a die: the same person overhearing the same sentence
        # behaves the same way twice, so this is reproducible in a check.
        let roll = float(fnv1a64("react\x1f" & who & "\x1f" &
                                 normalizeText(utterance)) mod 1000'u64) / 1000.0
        if roll < bystanderReactChance():
          var tn = ""
          let n = emitTrigger(who, "bystander", bystanderCooldownMs(),
                              true, true, true, tn)
          if n > 0:
            spoke = spoke + 1
            result = result + n
    i = i + 1
  note = $considered & " bystander(s) within " & $int(hearSpeakM()) &
         " m could hear it; " & $spoke & " reacted with a table bark " &
         "(chance " & $int(bystanderReactChance() * 100.0) & "%). Only " &
         addresseeId & " gets a reply."

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
                      inventoryNote: "", placeName: "", map: "", objective: "",
                      known: "")
  let i = findPerson(personId)
  if i < 0: return
  result.known = renderKnown(i, 12)
  # What their group is actually doing right now. It comes from the objective
  # ROW, so a person can never describe an errand the world is not running.
  discard rebuildGroups()
  result.objective = objectiveSentence(i)
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
                     recentEvents: recentEventsText(), yell: false)
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
  # A reported distance OVERRIDES the sim's, and it is the only one that can
  # make the model shout: `Yell: true` in the volatile suffix.
  let reported = distanceOf(personId)
  if reported >= 0.0:
    result.distanceM = reported
    result.yell = reported > hearSpeakM() and reported <= hearYellM()
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


# ---------------------------------------------------------------------------
# GROUNDING (DESIGN.md 11) -- caches, scenes, claims.
#
# The rule the whole section exists for: a person may only talk about entities
# the world holds, and the ONLY way a person creates truth is a tag the world
# materialises here. So `[PLANT:]` does not annotate a reply, it writes a Cache
# row with items, a story and living guards; `sceneJson` builds the scene out
# of those rows and nothing else; and `observeLootTaken` walks the consequence
# back into faction standing and a rumour. Nothing below invents a name, an
# item or a position that is not already in the world or in `data/`.
# ---------------------------------------------------------------------------

proc groundRng(salt, id: string): Rng =
  ## Deterministic per (world, clock, subject). The claim roll must be
  ## reproducible from the world, not from whatever a generator had reached.
  result = initRng(worldSeed() xor
                   fnv1a64(salt & "|" & id & "|" & $worldClockMs()))

proc nameWordsMatch(utterance, full: string): bool =
  ## Any word of a person's name that is long enough to be a name and not a
  ## title. A four-character floor is deliberate: "the" and "of" in a callsign
  ## would otherwise make every sentence a match, which is a check that cannot
  ## fail.
  let u = normalizeText(utterance)
  if u.len == 0 or full.len == 0: return false
  for w in normalizeText(full).split(' '):
    if w.len >= 4 and containsWord(u, w): return true
  result = false

proc applyPlant*(speakerId, spec: string; note: var string): string =
  ## `[PLANT: cache | <placeId or "near"> | <what> | guarded by <factionId> xN]`
  ## -> a real Cache. Returns the new cache id, or "" with a note saying why
  ## not. Every refusal names the part of the spec it could not use.
  result = ""
  let pi = findPerson(speakerId)
  if pi < 0:
    note = "[PLANT] refused: no such person '" & speakerId & "'"
    return
  var parts = pipeSplit(spec)
  if parts.len > 0 and normalizeText(parts[0]) == "cache":
    var rest: seq[string] = @[]
    var i = 1
    while i < parts.len:
      rest.add parts[i]
      i = i + 1
    parts = rest
  let placeTok = (if parts.len > 0: parts[0] else: "")
  let what = (if parts.len > 1: parts[1] else: "")
  let guardTok = (if parts.len > 2: parts[2] else: "")
  if what.len == 0:
    note = "[PLANT] refused: the spec said nothing about what is in the cache " &
           "(expected `cache | <place> | <what> | guarded by <faction> xN`, got '" &
           spec & "')"
    return
  let map = personMap(pi)
  var px = 0.0
  var py = 0.0
  var pz = 0.0
  personPos(pi, px, py, pz)
  var placeId2 = personPlace(pi)
  let pl = findPlace(placeTok)
  if pl >= 0:
    placeId2 = placeId(pl)
    placePos(pl, px, py, pz)
  var facId = personFaction(pi)
  var count = 2
  if guardTok.len > 0:
    for w in guardTok.split(' '):
      let t = strip(w)
      if findFaction(t) >= 0: facId = t
      elif t.len >= 2 and (t[0] == 'x' or t[0] == 'X'):
        let n = parseIntOr(t.substr(1), 0)
        if n > 0 and n <= 8: count = n
  let cid = "plant." & speakerId & "." & $cacheCount()
  var r = groundRng("plant", cid)
  let ci = addCache(cid, personName(pi) & "'s cache", placeId2, map, facId, "",
                    personName(pi) & " says: " & what, speakerId, px, py, pz)
  var tpls: seq[string] = @[]
  var counts: seq[int] = @[]
  var inote = ""
  discard resolveItems(what, r, tpls, counts, inote)
  var t2 = 0
  while t2 < tpls.len:
    cacheAddItem(ci, tpls[t2], (if t2 < counts.len: counts[t2] else: 1))
    t2 = t2 + 1
  let grp = spawnGuardGroup(cid, facId, map, placeId2, px, py, pz, count, r)
  setCacheGuardGroup(ci, grp)
  addPersonKnows(pi, cid)
  addCacheKnownBy(ci, speakerId)
  let rid = cid & "-rumour"
  addFactRef(rid, "cache " & cid & " " & facId, personName(pi) & " says: " & what,
             "cache", cid, "plant")
  addPersonKnows(pi, rid)
  var jo = obj()
  jo.put("cacheId", cid)
  jo.put("map", map)
  jo.put("place", placeId2)
  jo.put("guards", count)
  jo.put("guardGroup", grp)
  jo.put("items", cacheItemCount(ci))
  jo.put("itemNote", inote)
  discard journal("cache.planted", speakerId, cid, done(jo).text)
  note = "planted cache " & cid & " at " & (if placeId2.len > 0: placeId2 else: map) &
         " with " & $cacheItemCount(ci) & " item row(s) (" & inote & ") and " &
         $count & " guard(s) in group '" & grp & "'"
  result = cid

proc applyReveal*(speakerId, entityId: string; note: var string): bool =
  ## `[REVEAL: <entityId>]` -- a disclosure. An id the world does not hold is
  ## REFUSED and journaled, because a person handing the player a name for
  ## something that does not exist is the exact failure 11 is about.
  if not worldHasId(entityId):
    note = "[REVEAL] refused: '" & entityId & "' is not an entity in this " &
           "world; nothing was disclosed"
    discard journal("claim.unknown", speakerId, entityId, "{}")
    return false
  let ci = findCache(entityId)
  if ci >= 0: addCacheKnownBy(ci, "player")
  discard journal("reveal", speakerId, entityId, "{}")
  var o = obj()
  o.put("personId", speakerId)
  o.put("entityId", entityId)
  discard directive("world.reveal", done(o).text, false)
  note = "revealed " & entityId & " to the player"
  result = true

proc applyExpect*(speakerId, spec: string; note: var string): bool =
  ## `[EXPECT: <cacheId> | bearer <personId> | token <passphrase>]`.
  let parts = pipeSplit(spec)
  if parts.len < 3:
    note = "[EXPECT] refused: expected `<cacheId> | bearer <personId> | token " &
           "<passphrase>`, got '" & spec & "'"
    return false
  let cid = parts[0]
  let ci = findCache(cid)
  if ci < 0:
    note = "[EXPECT] refused: '" & cid & "' is not a cache in this world"
    return false
  var bearer = strip(parts[1])
  if bearer.len > 7 and normalizeText(bearer.substr(0, 5)) == "bearer":
    bearer = strip(bearer.substr(6))
  var token = strip(parts[2])
  if token.len > 6 and normalizeText(token.substr(0, 4)) == "token":
    token = strip(token.substr(5))
  if findPerson(bearer) < 0:
    note = "[EXPECT] refused: bearer '" & bearer & "' is nobody in this world"
    return false
  if token.len == 0:
    note = "[EXPECT] refused: no token; a pickup with no token cannot be " &
           "failed, so it would be a contract nobody could get wrong"
    return false
  discard addPickupContract(cid & "-pickup." & $contractCount(), cid, bearer,
                            token, worldClockMs() + 604800000'i64)
  addPersonKnows(findPerson(bearer), cid)
  addCacheKnownBy(ci, bearer)
  for gi in peopleOfGroup(cacheGuardGroup(ci)):
    remember(gi, "We are expecting " & personName(findPerson(bearer)) &
             ". The word is \"" & token & "\".")
  discard journal("pickup.expected", speakerId, cid,
                  jsonOf2("bearer", bearer, "token", token))
  note = "guards at " & cid & " now expect " & bearer & " with the word \"" &
         token & "\""
  result = true

proc resolveClaim*(personId, utterance: string; note: var string): bool =
  ## Impersonation. Scored, rolled with the world's own rng, and JOURNALED
  ## WITH THE PARTS -- `claim.ok` / `claim.fail` carry every term, so a verdict
  ## can be argued with afterwards instead of being taken on trust.
  result = false
  let pi = findPerson(personId)
  if pi < 0:
    note = "claim refused: no such person '" & personId & "'"
    return
  var cands: seq[int] = @[]
  for id in personKnows(pi):
    let ci = findCache(id)
    if ci >= 0: cands.add ci
  var px = 0.0
  var py = 0.0
  var pz = 0.0
  personPos(pi, px, py, pz)
  for ci in cachesNear(personMap(pi), px, py, pz, 120.0):
    var dup = false
    for c in cands:
      if c == ci: dup = true
    if not dup: cands.add ci
  var bestC = -1
  var bestK = -1
  for ci in cands:
    for k in pickupsAt(cacheId(ci)):
      if contractStatus(k) == "active" and bestK < 0:
        bestC = ci
        bestK = k
  if bestK < 0:
    note = "claim heard, but there is no open pickup contract at any cache " &
           personName(pi) & " knows or stands near (" & $cands.len &
           " cache(s) considered) -- nothing to impersonate, so nothing was rolled"
    return
  let bearerId = contractPartyB(bestK)
  let bi = findPerson(bearerId)
  let token = contractTerms(bestK)
  let bearerNamed = bi >= 0 and nameWordsMatch(utterance, personName(bi))
  let tokenSpoken = nameWordsMatch(utterance, token)
  var tokenGiven = false
  for g in gGaveItems:
    if nameWordsMatch(g, token) or nameWordsMatch(token, g): tokenGiven = true
  let fi = findFaction(cacheOwner(bestC))
  var rep = 0
  if fi >= 0: rep = factionRep(fi)
  let repPart = clampI(rep div 5, -20, 20)
  let role = personRole(pi)
  var rolePart = 0
  if role == "guard" or role == "grunt": rolePart = 15
  elif role == "scout" or role == "medic": rolePart = 5
  elif role == "lieutenant": rolePart = -10
  elif role == "leader": rolePart = -20
  var score = repPart + rolePart
  if bearerNamed: score = score + 40
  if tokenSpoken or tokenGiven: score = score + 40
  var r = groundRng("claim", personId & "|" & cacheId(bestC))
  let threshold = nextInt(r, 35, 85)
  let believed = score >= threshold
  var jo = obj()
  jo.put("cacheId", cacheId(bestC))
  jo.put("contractId", contractId(bestK))
  jo.put("bearerId", bearerId)
  jo.put("bearerNamed", bearerNamed)
  jo.put("tokenSpoken", tokenSpoken)
  jo.put("tokenGiven", tokenGiven)
  jo.put("factionRep", repPart)
  jo.put("guardRole", role)
  jo.put("rolePart", rolePart)
  jo.put("score", score)
  jo.put("threshold", threshold)
  jo.put("believed", believed)
  let ei = ensureEnc(personId)
  if believed:
    discard journal("claim.ok", personId, "player", done(jo).text)
    setContractStatus(bestK, "broken")
    setState(ei, "talking", "the claim was believed")
    var so = obj()
    so.put("personId", personId)
    so.put("groupId", cacheGuardGroup(bestC))
    so.put("cacheId", cacheId(bestC))
    so.put("reason", "the player was taken for " &
           (if bi >= 0: personName(bi) else: bearerId))
    discard directive("npc.stand_down", done(so).text, false)
    for gi in peopleOfGroup(cacheGuardGroup(bestC)):
      setPersonActivity(gi, "idle")
      remember(gi, "We handed the cache to someone who gave the word.")
    var go = obj()
    go.put("personId", personId)
    go.put("item", cacheId(bestC))
    go.put("cacheId", cacheId(bestC))
    discard directive("npc.give", done(go).text, true, 30000)
    if bi >= 0:
      setPersonAttitude(bi, clampAtt(personAttitude(bi) - 40))
      remember(bi, "Somebody used my name to take " & cacheName(bestC) & ".")
      let qid = "hunt." & bearerId
      if findQuest(qid) < 0:
        var objectives: seq[string] = @[]
        objectives.add "find whoever used " & personName(bi) & "'s name"
        objectives.add "take back what was handed over"
        discard addQuest(qid, bearerId, "Somebody used my name",
                         personName(bi) & " was expected at " &
                         cacheName(bestC) & ". Somebody else was believed.",
                         "hunt", "player", "whatever is left of the cache",
                         objectives)
      var qo = obj()
      qo.put("questId", qid)
      qo.put("giverId", bearerId)
      qo.put("title", "Somebody used my name")
      qo.put("factionId", personFaction(bi))
      discard directive("quest.offer", done(qo).text, true, 60000)
    note = "claim BELIEVED at " & cacheId(bestC) & ": score " & $score &
           " vs threshold " & $threshold & " (bearer named " & $bearerNamed &
           ", token " & $(tokenSpoken or tokenGiven) & ", rep " & $repPart &
           ", role " & role & " " & $rolePart & ")"
    result = true
  else:
    discard journal("claim.fail", personId, "player", done(jo).text)
    setState(ei, "threatened", "the claim was not believed")
    setPersonAttitude(pi, clampAtt(personAttitude(pi) - 10))
    discard emitStance(personId, "hostile")
    discard emitBark(personId, "That is not the word, and you are not him.")
    note = "claim REFUSED at " & cacheId(bestC) & ": score " & $score &
           " vs threshold " & $threshold & " (bearer named " & $bearerNamed &
           ", token " & $(tokenSpoken or tokenGiven) & ", rep " & $repPart &
           ", role " & role & " " & $rolePart & ")"

proc materialiseCache(ci: int): int =
  ## Turn a cache's item rows into real loot rows, once. Returns how many were
  ## created. Idempotent by the FINISHED STATE (`lootOfCache` is empty), not by
  ## a flag: a flag would survive a load that dropped the loot kind.
  result = 0
  if lootOfCache(cacheId(ci)).len > 0: return
  var cx = 0.0
  var cy = 0.0
  var cz = 0.0
  cachePos(ci, cx, cy, cz)
  let tpls = cacheItemTpls(ci)
  let counts = cacheItemCounts(ci)
  var r = groundRng("materialise", cacheId(ci))
  var k = 0
  while k < tpls.len:
    discard addLoot(cacheId(ci) & "-l" & $(k + 1), cacheId(ci), tpls[k],
                    cacheMap(ci), (if k < counts.len: counts[k] else: 1),
                    cx + float(nextInt(r, -2, 2)), cy,
                    cz + float(nextInt(r, -2, 2)))
    result = result + 1
    k = k + 1

proc sceneJson*(map: string; x, y, z, radius: float): JsonObject =
  ## What must EXIST around a point right now, and the directives that build
  ## it. Calling this MATERIALISES: a rumoured cache becomes intact and its
  ## items become loot rows, because the player is standing there and the thing
  ## people have been talking about has to be real now.
  var rad = radius
  if rad <= 0.0: rad = gNoticeM
  var people = arr()
  var groups = arr()
  var seenGroups: seq[string] = @[]
  discard rebuildGroups()
  for pi in peopleNear(map, x, y, z, rad):
    var po = personJson(pi)
    po.put("encounterState", encounterState(personId(pi)))
    # What this person is DOING, from the objective row their group holds. The
    # client shows it and the dialogue tiers talk about it; both read the same
    # row, so they cannot describe two different errands.
    var okind = ""
    var otarget = ""
    var orole = ""
    if objectiveOfPerson(pi, okind, otarget, orole):
      var oo = obj()
      oo.put("kind", okind)
      oo.put("target", otarget)
      oo.put("targetName", objectiveTargetName(
        objectiveTargetKind(activeObjectiveOf(personGroup(pi))), otarget))
      oo.put("role", orole)
      oo.put("sentence", objectiveSentence(pi))
      po.put("objective", oo)
    else:
      po.put("objective", raw("null"))
    people.add po
  var caches = arr()
  var lootA = arr()
  var made = 0
  for ci in cachesNear(map, x, y, z, rad):
    if cacheStatus(ci) == "rumoured": setCacheStatus(ci, "intact")
    made = made + materialiseCache(ci)
    caches.add cacheJson(ci)
    let grp = cacheGuardGroup(ci)
    var dup = false
    for g in seenGroups:
      if g == grp: dup = true
    if grp.len > 0 and not dup:
      seenGroups.add grp
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
      if count > 0:
        var go = obj()
        go.put("groupId", grp)
        go.put("factionId", cacheOwner(ci))
        go.put("role", "guard")
        go.put("count", count)
        go.put("names", names)
        go.put("map", cacheMap(ci))
        go.put("x", gx)
        go.put("y", gy)
        go.put("z", gz)
        go.put("reason", "guarding " & cacheName(ci))
        groups.add go
  var lootItems = arr()
  var lootN2 = 0
  for li in lootOnMap(map):
    if lootStatus(li) != "placed": continue
    var lx = 0.0
    var ly = 0.0
    var lz = 0.0
    lootPos(li, lx, ly, lz)
    let dx = lx - x
    let dy = ly - y
    let dz = lz - z
    if dx*dx + dy*dy + dz*dz > rad*rad: continue
    lootA.add lootJson(li)
    var io = obj()
    io.put("id", lootId(li))
    io.put("tpl", lootTpl(li))
    io.put("count", lootN(li))
    io.put("x", lx)
    io.put("y", ly)
    io.put("z", lz)
    io.put("cacheId", lootCache(li))
    # A corpse is a loot row whose tpl names the dead. Their inventoryNote is
    # what makes the body identifiable -- without it the client would spawn an
    # anonymous pile and the person who died offscreen would leave no trace.
    let tpl = lootTpl(li)
    if tpl.len > 7 and tpl.substr(0, 6) == "corpse:":
      let who = tpl.substr(7, tpl.len - 1)
      let wi = findPerson(who)
      io.put("personId", who)
      io.put("corpse", true)
      if wi >= 0:
        io.put("name", personName(wi))
        io.put("inventoryNote", personInventoryNote(wi))
        io.put("factionId", personFaction(wi))
    lootItems.add io
    lootN2 = lootN2 + 1
  # Whatever the OFFSCREEN state says is on this map right now: groups that are
  # mid-objective and are not guarding a cache would otherwise never appear,
  # because the loop above only walks caches.
  var gotoA = arr()
  var gi2 = 0
  while gi2 < groupCount():
    if groupMap(gi2) == map:
      let gid = groupId(gi2)
      var dup = false
      for g in seenGroups:
        if g == gid: dup = true
      var gx = 0.0
      var gy = 0.0
      var gz = 0.0
      groupPos(gi2, gx, gy, gz)
      let inRange = (gx - x) * (gx - x) + (gz - z) * (gz - z) <= rad * rad
      let oi = activeObjectiveOf(gid)
      if not dup and inRange and groupSize(gi2) > 0:
        seenGroups.add gid
        var names = arr()
        for pj in groupMembers(gi2):
          names.add personName(pj)
        var go = obj()
        go.put("groupId", gid)
        go.put("factionId", groupFactionOf(gi2))
        go.put("role", (if oi >= 0: objectiveKind(oi) else: "idle"))
        go.put("count", groupSize(gi2))
        go.put("names", names)
        go.put("map", map)
        go.put("x", gx)
        go.put("y", gy)
        go.put("z", gz)
        if oi >= 0:
          var oo = obj()
          oo.put("kind", objectiveKind(oi))
          oo.put("targetKind", objectiveTargetKind(oi))
          oo.put("target", objectiveTarget(oi))
          oo.put("targetName", objectiveTargetName(objectiveTargetKind(oi),
                                                   objectiveTarget(oi)))
          oo.put("note", objectiveNote(oi))
          go.put("objective", oo)
          go.put("reason", objectiveNote(oi))
        else:
          go.put("objective", raw("null"))
          go.put("reason", "no objective")
        groups.add go
      # The bots must WALK toward what their group is for, once spawned. The
      # point comes from the objective's target, never from a guess.
      if oi >= 0 and inRange:
        var tmap = ""
        var tx = 0.0
        var ty = 0.0
        var tz = 0.0
        if targetPos(objectiveTargetKind(oi), objectiveTarget(oi),
                     tmap, tx, ty, tz) and tmap == map:
          for pj in groupMembers(gi2):
            var d = obj()
            d.put("personId", personId(pj))
            d.put("map", map)
            d.put("x", tx)
            d.put("y", ty)
            d.put("z", tz)
            d.put("why", objectiveKind(oi) & ": " & objectiveNote(oi))
            gotoA.add d
            # emitted here, one per bot, because a JsonArray cannot be walked
            # back afterwards -- and a directive nobody sent is a group that
            # spawns and then stands still.
            discard directive("npc.goto", done(d).text, true, 30000)
    gi2 = gi2 + 1

  var directives = arr()
  if groups.len > 0:
    var d1 = obj()
    d1.put("kind", "group.spawn")
    d1.put("groups", groups)
    directives.add d1
    discard directive("group.spawn", done(objOf("groups", groups)).text, true, 60000)
  if lootN2 > 0:
    var d2 = obj()
    d2.put("kind", "loot.spawn")
    d2.put("items", lootItems)
    directives.add d2
    discard directive("loot.spawn", done(objOf("items", lootItems)).text, true, 60000)
  if gotoA.len > 0:
    var d3 = obj()
    d3.put("kind", "npc.goto")
    d3.put("orders", gotoA)
    directives.add d3
  let sceneId = map & "@" & $int(x) & "," & $int(z) & "#" & $worldClockMs()
  discard journal("scene.built", "", map,
                  jsonOf2("scene", sceneId, "note",
                          $people.len & " people, " & $caches.len & " caches, " &
                          $lootN2 & " loot, " & $made & " newly materialised"))
  result = obj()
  result.put("ok", true)
  result.put("sceneId", sceneId)
  result.put("map", map)
  result.put("radiusM", rad)
  result.put("people", people)
  result.put("caches", caches)
  result.put("loot", lootA)
  result.put("directives", directives)
  result.put("materialised", made)

proc observeLootTaken*(cacheId2, itemId, by: string; note: var string) =
  ## The loop closes here: what the client says was taken flips the row, moves
  ## the owning faction's standing, is REMEMBERED by whichever guards could see
  ## it, and becomes a fact with `origin: outcome` -- which is the thing the
  ## next conversation will bring up.
  var cid = cacheId2
  var took = 0
  if itemId.len > 0:
    let li = findLoot(itemId)
    if li >= 0:
      setLootStatus(li, "taken")
      took = took + 1
      if cid.len == 0: cid = lootCache(li)
  if cid.len == 0:
    note = "loot.taken named neither a cacheId nor a loot id we know ('" &
           itemId & "') -- nothing was marked taken"
    return
  let ci = findCache(cid)
  if ci < 0:
    note = "loot.taken names cache '" & cid & "', which is not in this world"
    return
  for li in lootOfCache(cid):
    if lootStatus(li) == "placed":
      setLootStatus(li, "taken")
      took = took + 1
  setCacheStatus(ci, "looted")
  var repNote = ""
  let fi = findFaction(cacheOwner(ci))
  if fi >= 0:
    setFactionRep(fi, clampAtt(factionRep(fi) - 12))
    repNote = factionName(fi) & " rep is now " & $factionRep(fi)
  var witnesses = 0
  var cx = 0.0
  var cy = 0.0
  var cz = 0.0
  cachePos(ci, cx, cy, cz)
  for wi in peopleNear(cacheMap(ci), cx, cy, cz, gNoticeM):
    setPersonAttitude(wi, clampAtt(personAttitude(wi) - 8))
    remember(wi, "Somebody emptied " & cacheName(ci) & " while I was standing there.")
    witnesses = witnesses + 1
  let fid = cid & "-hit"
  addFactRef(fid, "outcome cache " & cid,
             "Somebody hit " & cacheName(ci) & ". It is empty now.",
             "cache", cid, "outcome")
  for who in cacheKnownBy(ci):
    let wi2 = findPerson(who)
    if wi2 >= 0: addPersonKnows(wi2, fid)
  discard journal("loot.taken", by, cid,
                  jsonOf2("items", $took, "witnesses", $witnesses))
  note = $took & " item row(s) taken from " & cacheName(ci) & " (" & cid &
         "); status " & cacheStatus(ci) & "; " & $witnesses &
         " witness(es) remember it; rumour '" & fid & "' created with origin " &
         "outcome" & (if repNote.len > 0: "; " & repNote else: "")

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
      # ONE TURN IS NOT A LIFETIME. MEASURED 2026-09-07, first turn on the
      # OpenAI engine: a mildly unwelcome question came back [MOOD: -1] and
      # [ATTITUDE: -100], which floors a relationship in a single exchange and
      # leaves nowhere for the story to go. The tag still decides the
      # DIRECTION; the machine bounds the STEP, and says so when it bit.
      let wantM = fclamp(parseFloatOr(val, personMood(pi)), -1.0, 1.0)
      let haveM = personMood(pi)
      let stepM = fclamp(wantM - haveM, -MaxMoodStep, MaxMoodStep)
      setPersonMood(pi, fclamp(haveM + stepM, -1.0, 1.0))
      if wantM - haveM > MaxMoodStep or haveM - wantM > MaxMoodStep:
        notes.add "mood CLAMPED: [MOOD: " & val & "] asked for " &
                  fmtF(wantM) & " from " & fmtF(haveM) & "; a single turn may " &
                  "move mood by at most " & fmtF(MaxMoodStep) & ", so it is now " &
                  fmtF(personMood(pi))
        discard journal("tag.clamped", personId, "player",
                        jsonOf2("tag", "MOOD", "asked", val))
      else:
        notes.add "mood set"
    of "ATTITUDE":
      let wantA = parseIntOr(val, 0)
      let stepA = clampI(wantA, -MaxAttitudeStep, MaxAttitudeStep)
      bump(pi, stepA)
      result = result + emitStanceOnce(ei, personId, stanceWord(pi))
      if stepA != wantA:
        notes.add "attitude CLAMPED: [ATTITUDE: " & val & "] asked for " &
                  $wantA & " in one turn; the bound is " & $MaxAttitudeStep &
                  ", so " & $stepA & " was applied and attitude is now " &
                  $personAttitude(pi)
        discard journal("tag.clamped", personId, "player",
                        jsonOf2("tag", "ATTITUDE", "asked", val))
      else:
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
      result = result + emitStanceOnce(ei, personId, "hostile")
      result = result + emitAttackOnce(ei, personId)
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
    of "PLANT":
      var n = ""
      let cid = applyPlant(personId, val, n)
      if cid.len > 0:
        var o = obj()
        o.put("personId", personId)
        o.put("cacheId", cid)
        result = result + directive("world.plant", done(o).text, false)
      notes.add n
    of "REVEAL":
      var n = ""
      let before = latestSeq()
      discard applyReveal(personId, val, n)
      if latestSeq() > before: result = result + 1
      notes.add n
    of "EXPECT":
      var n = ""
      discard applyExpect(personId, val, n)
      notes.add n
    of "CLAIM_OK", "CLAIM_FAIL":
      # The encounter machine's own verdict, never a speaker's. It is mapped
      # (so the grammar check is honest) and it is REFUSED (so a reply cannot
      # award itself a believability roll it did not win).
      discard journal("claim.unknown", personId, name, "{}")
      notes.add "[" & name & "] refused: only the believability roll in " &
                "resolveClaim may write that verdict; nothing was changed"
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
    # The CLIENT's metres, kept apart from the sim's: only a reported distance
    # feeds `bm/hearing` (see the header of that file for why).
    let reported = dataFloat(dataJson, "distanceM", -1.0)
    var d = reported
    if d < 0.0: d = situationFor(who).distanceM
    setPersonLastSeenMs(pi, worldClockMs())
    let nowW = wallMs()
    var prevMs = 0'i64
    var prevD = -1.0
    if reported >= 0.0:
      prevD = distanceOf(who)
      prevMs = distanceAtMs(who)
      noteDistance(who, reported, nowW)
    if d <= gNoticeM and gEncState[ei] == "none":
      setState(ei, "noticed", "saw the player at " & $int(d) & " m")
      result = result + emitStance(who, stanceWord(pi))
    notes.add "distance " & $int(d) & " m, state " & gEncState[ei]

    # --- proactive speech (DESIGN.md 6; the triggers are in data) -----------
    var tn = ""
    if triggerLastMs(who, "first_sight") < 0:
      # ONCE PER RAID, and `hearingReset` is what makes "per raid" true.
      result = result + emitTrigger(who, "first_sight", 0, false, false,
                                    false, tn)
      if tn.len > 0: notes.add tn
    elif reported >= 0.0 and prevD >= 0.0 and prevMs > 0:
      let dt = nowW - prevMs
      let closed = prevD - reported
      # A PUSH is an approach fast enough to be a sprint: more than 5 m/s of
      # closing. Nothing else the client reports distinguishes the two, and
      # inventing a `sprinting` flag we cannot measure would be worse.
      # dt >= 0, not dt > 0. MEASURED 2026-09-07: two samples landing in the
      # SAME wall millisecond -- which is what the offline check produces, and
      # what a fast client tick can produce too -- gave dt == 0 and were
      # rejected as "not within 3 s". Selfcheck 23 failed on exactly that leg.
      if dt >= 0 and dt <= 3000 and closed >= 15.0 and reported <= hearYellM():
        result = result + emitTrigger(who, "push", 20000, false, false,
                                      true, tn)
        if tn.len > 0: notes.add tn
      elif dt >= 0 and dt <= 3000 and closed >= 10.0:
        result = result + emitTrigger(who, "approach", 20000, false, false,
                                      true, tn)
        if tn.len > 0: notes.add tn
    # LINGER is a clock, started here and read on `tick`.
    if reported >= 0.0:
      if reported <= 8.0:
        if nearSince(who) < 0: setNearSince(who, nowW)
      else:
        setNearSince(who, -1)

  of "player_aimed_at":
    if pi < 0:
      note = "player_aimed_at names no person we know ('" & who & "')"
      return 0
    gPlayerAiming = 1
    gPlayerArmed = 1
    let aimD = dataFloat(dataJson, "distanceM", -1.0)
    if aimD >= 0.0: noteDistance(who, aimD, wallMs())
    # WALL milliseconds, and -1 for "never barked". The world clock starts at
    # 0 and advances in sim steps, so `worldClockMs()` made a fresh row's last
    # bark indistinguishable from a bark that happened this instant -- measured
    # by tools/basement_check.py, which served five barks for five aim reports.
    let nowMs = wallMs()
    let barked = gEncBarkMs[ei] >= 0 and nowMs - gEncBarkMs[ei] < gBarkCooldownMs
    if barked and gEncState[ei] == "threatened":
      # HYSTERESIS. The crosshair resting on someone is ONE fact, not sixty:
      # count the ticks and say so, and emit nothing at all. The count is
      # carried into the journal at the NEXT transition, so the record is a
      # number rather than a row per frame.
      gEncAimTicks[ei] = gEncAimTicks[ei] + 1
      notes.add personName(pi) & " is already threatened; this is aim report " &
                $gEncAimTicks[ei] & " within the " & $(gBarkCooldownMs div 1000) &
                " s bark cooldown, so no bark, no stance and no attack was " &
                "emitted and their attitude was not dropped again"
    else:
      bump(pi, -15)
      setState(ei, "threatened", "the player aimed a weapon")
      result = result + emitStanceOnce(ei, who, "hostile")
      var bnote = ""
      result = result + emitBarkEx(who, threatLineFor(who), false, false,
                                   "", bnote)
      if bnote.len > 0: notes.add bnote
      remember(pi, "The player pointed a gun at me.")
      var jo = obj()
      jo.put("by", "player")
      jo.put("how", "aimed")
      jo.put("suppressedAimTicks", gEncAimTicks[ei])
      discard journal("threatened", who, "player", done(jo).text)
      gEncBarkMs[ei] = nowMs
      gEncAimTicks[ei] = 0
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
        let wasThreat = gEncState[ci] == "threatened"
        setState(ci, "talking", "weapon lowered")
        if wasThreat:
          result = result + emitBark(personId(captor),
                                     standDownLineFor(personId(captor)))
        notes.add personName(captor) & " lets it go for now"
    elif pi >= 0:
      let wasThreat = gEncState[ei] == "threatened"
      # De-escalate to TALKING, never to `none`: a person who just had a rifle
      # in their face remembers it, and dropping them back to `none` would let
      # the whole threat cycle start over from scratch.
      setState(ei, "talking", "weapon lowered")
      result = result + emitStanceOnce(ei, who, stanceWord(pi))
      if wasThreat:
        result = result + emitBark(who, standDownLineFor(who))
        var lo = obj()
        lo.put("by", "player")
        lo.put("how", "lowered")
        lo.put("suppressedAimTicks", gEncAimTicks[ei])
        discard journal("stand_down", who, "player", done(lo).text)
        gEncAimTicks[ei] = 0
        notes.add "weapon lowered; " & personName(pi) & " stands down and talks"
      else:
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
      result = result + emitStanceOnce(hi, held, "hostile")
      result = result + emitAttackOnce(hi, held)
      notes.add "the captivity is broken by force; " & held & " is fighting"
    elif pi >= 0:
      bump(pi, -35)
      setState(ei, "fighting", "the player fired")
      result = result + emitStanceOnce(ei, who, "hostile")
      result = result + emitAttackOnce(ei, who)
      notes.add personName(pi) & " is fighting"
    else:
      notes.add "player_fired at nobody we know ('" & who & "')"

  of "player_hit":
    let hp = dataFloat(dataJson, "hp", playerHp())
    setPlayerHp(fclamp(hp, 0.0, 1.0))
    if pi >= 0:
      setState(ei, "fighting", "hit the player")
      result = result + emitStance(who, "hostile")
      var tn = ""
      result = result + emitTrigger(who, "hurt", 6000, false, false, true, tn)
      if tn.len > 0: notes.add tn
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
    # Anyone standing within 30 m of the body shouts about it. The distance is
    # between two PEOPLE, so it is measured in the sim's own frame (both
    # coordinates come from the same place, and `npc_moved` overwrites them
    # with live ones when the client reports them).
    var dx = 0.0
    var dy = 0.0
    var dz = 0.0
    personPos(pi, dx, dy, dz)
    var k = 0
    while k < gEncPerson.len:
      let other = gEncPerson[k]
      if other != who and gEncState[k] != "dead":
        let oi = findPerson(other)
        if oi >= 0 and personAlive(oi):
          var ox = 0.0
          var oy = 0.0
          var oz = 0.0
          personPos(oi, ox, oy, oz)
          if dist3(dx, dy, dz, ox, oy, oz) <= 30.0:
            var tn = ""
            result = result + emitTrigger(other, "saw_death", 15000, false,
                                          false, true, tn)
            if tn.len > 0: notes.add tn
      k = k + 1
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

  of "npc_moved":
    # Where the BOUND bots are, batched: the client posts one of these every
    # 2 s carrying every person it has bound to a live bot, because forty
    # separate POSTs a scan is a different kind of bug. A single-person body
    # (`personId`,`x`,`y`,`z`) is accepted too, for a hand-written probe.
    var pmap = ""
    var px = 0.0
    var py = 0.0
    var pz = 0.0
    playerPos(pmap, px, py, pz)
    let mapName = dataText(dataJson, "map", pmap)
    var moved = 0
    var unknown = 0
    let people = jr.each(jr.field(dataJson, "people"))
    var rows: seq[string] = @[]
    for e in people:
      let id = jr.asText(jr.child(e, "personId"), "")
      if id.len == 0: continue
      let mi = findPerson(id)
      if mi < 0:
        unknown = unknown + 1
        continue
      let mx = jr.asFloat(jr.child(e, "x"), 0.0)
      let my = jr.asFloat(jr.child(e, "y"), 0.0)
      let mz = jr.asFloat(jr.child(e, "z"), 0.0)
      setPersonPos(mi, mapName, personPlace(mi), mx, my, mz)
      noteDistance(id, dist3(px, py, pz, mx, my, mz), wallMs())
      # A row, so this person can OVERHEAR. Being close enough to hear
      # something does not require having been seen: `player_seen` needs the
      # view cone, and the whole point of the bystander rule is the people
      # standing behind you.
      discard ensureEnc(id)
      moved = moved + 1
      rows.add id
    if people.len == 0 and pi >= 0:
      let mx = dataFloat(dataJson, "x", 0.0)
      let my = dataFloat(dataJson, "y", 0.0)
      let mz = dataFloat(dataJson, "z", 0.0)
      setPersonPos(pi, mapName, personPlace(pi), mx, my, mz)
      noteDistance(who, dist3(px, py, pz, mx, my, mz), wallMs())
      moved = 1
      rows.add who
    if moved == 0:
      notes.add "npc_moved carried no person this world knows (" &
                $unknown & " unknown id(s), " & $people.len &
                " row(s)); no distance was updated, so nothing will be " &
                "hearing-gated on it"
    else:
      notes.add $moved & " person position(s) updated on " & mapName &
                (if unknown > 0: ", " & $unknown & " unknown id(s) ignored"
                 else: "")

  of "loot.taken":
    let cid = dataText(dataJson, "cacheId", "")
    let iid = dataText(dataJson, "itemId", "")
    var n = ""
    let before = latestSeq()
    observeLootTaken(cid, iid, dataText(dataJson, "by", "player"), n)
    result = result + (latestSeq() - before)
    notes.add n

  of "scene.built":
    notes.add "client acknowledged scene " & dataText(dataJson, "sceneId", "") &
              "; the backend built it from world rows, so there is nothing to " &
              "apply here beyond the record"
    discard journal("scene.acked", "", dataText(dataJson, "sceneId", ""), "{}")

  of "player_gave":
    if pi < 0:
      note = "player_gave names no person we know ('" & who & "')"
      return 0
    let item = dataText(dataJson, "item", "")
    if item.len > 0: gGaveItems.add item
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
      notePlayerSpokeTo(who, wallMs())
      if gEncState[ei] == "none" or gEncState[ei] == "noticed":
        setState(ei, "hailed", "the player spoke")
      elif gEncState[ei] == "hailed":
        setState(ei, "talking", "the conversation continued")
      notes.add "state " & gEncState[ei]
      # Impersonation goes through the SAME classifier the reply tier uses, so
      # "I am Vadim, Kostya sent me" cannot be a claim for the brain and small
      # talk for the world.
      let said = dataText(dataJson, "text", "")
      if said.len > 0:
        var conf = 0.0
        let intent = classifyIntent(said, conf)
        if intent == "claim":
          var n = ""
          let before = latestSeq()
          discard resolveClaim(who, said, n)
          result = result + (latestSeq() - before)
          notes.add n
    else:
      notes.add "player_spoke with nobody named"

  of "player_extracted", "raid_ended":
    hearingReset()
    var i = 0
    while i < gEncPerson.len:
      if gEncState[i] != "dead" and gEncState[i] != "captive" and
         gEncState[i] != "escorted":
        setState(i, "none", kind)
      i = i + 1
    discard journal(kind, "player", "", "{}")
    # The raid is over: the map goes back to being emulated. A map left frozen
    # would silently stop for the rest of the session, and "the world stopped"
    # looks exactly like "the world is quiet".
    let wasFrozen = offscreenFrozenMap()
    offscreenThaw()
    if wasFrozen.len > 0:
      discard journal("region.thawed", "player", wasFrozen,
                      jsonOf2("map", wasFrozen, "why", "the raid ended"))
      notes.add wasFrozen & " is emulated again"
    notes.add "encounters reset; captivity (if any) survives the raid"

  of "raid_started":
    hearingReset()
    let map = dataText(dataJson, "map", "")
    # The client owns this map from here until the raid ends. Freezing BEFORE
    # anything else in this branch is deliberate: the emulator must not get one
    # more step on a map the player is already standing in.
    offscreenFreezeMap(map)
    discard journal("region.frozen", "player", map,
                    jsonOf2("map", map, "why", "the player is in a raid here"))
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
    # The two triggers that are about ELAPSED TIME rather than about a fact:
    # standing near someone saying nothing, and a firefight that has gone
    # quiet for a few seconds.
    let nowW = wallMs()
    var ti = 0
    while ti < gEncPerson.len:
      let who2 = gEncPerson[ti]
      var tn = ""
      if gEncState[ti] == "fighting":
        result = result + emitTrigger(who2, "combat_taunt", tauntGapMs(who2),
                                      false, false, true, tn)
        if tn.len > 0 and find(tn, "refused") < 0: notes.add tn
      elif gEncState[ti] != "dead":
        let ns = nearSince(who2)
        if ns >= 0 and nowW - ns >= 10000 and
           nowW - playerSpokeToMs(who2) >= 10000:
          result = result + emitTrigger(who2, "linger", 30000, false, false,
                                        true, tn)
          if tn.len > 0 and find(tn, "refused") < 0: notes.add tn
          setNearSince(who2, nowW)
      ti = ti + 1

  else:
    note = "unknown fact kind '" & kind & "'; nothing was applied. Known " &
           "kinds: player_seen player_aimed_at player_fired " &
           "player_lowered_weapon player_spoke player_hit npc_died " &
           "player_died player_moved player_gave player_took " &
           "player_extracted raid_started raid_ended tick loot.taken " &
           "npc_moved " &
           "scene.built"
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
    o.put("reportedDistanceM", distanceOf(gEncPerson[i]))
    var hm = "speak"
    var ha = true
    var hw = ""
    discard hearingDecide(gEncPerson[i], false, hm, ha, hw)
    o.put("hearingMode", hm)
    o.put("audible", ha)
    o.put("hearingNote", hw)
    result.add o
    i = i + 1
