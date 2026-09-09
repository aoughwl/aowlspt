## bm/hearing — WHO CAN HEAR THIS, and how loudly it has to be said.
##
## The bug this file exists for, in the user's words on 2026-09-07: *"everyone
## in the vicinity replies even if I can't hear their reply -- that's not
## good"*. The backend was emitting a `say` for every person the machine
## touched, at any distance, and the client played every one of them. A voice
## arriving from 300 m away through a wall is not a world; it is a chat log
## read aloud.
##
## So every spoken segment now carries three fields the client obeys:
##
##   `distanceM`  speaker -> player, in metres, from the LAST distance the
##                CLIENT reported. -1 means "nobody has told us", and that is
##                never silently treated as far -- see `hearingDecide`.
##   `mode`       "speak" (normal voice, <= hearSpeakM),
##                "yell"  (shouted, <= hearYellM, TEXT REWRITTEN),
##                "mutter"(quiet, an aside nobody was meant to answer).
##   `audible`    false only when the segment is emitted anyway for the record;
##                the client plays and subtitles ONLY `audible:true`.
##
## Beyond `hearYellM` nothing is emitted at all: the person's memory records
## that they saw the player and could not be heard, and `say.suppressed` is
## journaled. A dropped line that leaves no trace would be indistinguishable
## from a bug in the state machine, which is the whole reason it is journaled
## rather than simply skipped.
##
## THE DISTANCE IS THE CLIENT'S, NOT THE SIM'S. The sim's person coordinates
## are world-generation coordinates and are not in the same frame as the live
## raid; using them would have suppressed everything in the offline selfcheck
## (where the player's position is the origin) for reasons that have nothing to
## do with hearing. Only `player_seen.distanceM`, `player_aimed_at.distanceM`
## and a matching (`npc_moved`, `player_moved`) pair set a distance here.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json as jr

import world
import ontology
import util

# ---------------------------------------------------------------------------
# Configuration. Literal initialisers only (nimony zeroes a DLL global whose
# initialiser is a call).
# ---------------------------------------------------------------------------

var gHearSpeakM: float = 25.0
var gHearYellM: float = 70.0
var gMutterM: float = 6.0
var gBystanderChance: float = 0.3
var gBystanderCooldownMs: int64 = 20000
var gChatterLevel: int = 1        ## 0 off, 1 normal, 2 talkative

const TriggerNames* = ["first_sight", "approach", "linger", "hurt",
                       "saw_death", "combat_taunt", "push", "bystander"]
const NTrig = 8

# Per-trigger toggles, in `TriggerNames` order, stored as OFF flags in a fixed
# ARRAY rather than as ON flags in a seq. Two reasons, and the first one cost a
# whole acceptance run on 2026-09-07: a `seq` DLL global whose initialiser is
# `@[1, 1, ...]` came back EMPTY at runtime (nimony zeroes a global built by a
# call), so the very first `gTrigOn[t]` in loadConfig raised
# `i < s.len [AssertionDefect]` and every route in the process answered null.
# An array cannot be empty. And storing OFF means the zero value is ON, so even
# a zeroed global is the documented default rather than universal silence.
var gTrigOff: array[NTrig, int]

proc triggerIndex*(name: string): int =
  result = -1
  var i = 0
  while i < NTrig:
    if TriggerNames[i] == name: return i
    i = i + 1

proc hearingConfigure*(speakM, yellM, bystanderChance: float;
                       chatterLevel: int; bystanderCooldownMs: int) =
  if speakM > 0.0: gHearSpeakM = speakM
  if yellM > 0.0: gHearYellM = yellM
  # A yell that does not carry further than a normal voice is a configuration
  # mistake, not a preference: say so by clamping and leaving a note nobody
  # has to go looking for.
  if gHearYellM < gHearSpeakM: gHearYellM = gHearSpeakM
  if bystanderChance >= 0.0 and bystanderChance <= 1.0:
    gBystanderChance = bystanderChance
  if chatterLevel >= 0 and chatterLevel <= 2: gChatterLevel = chatterLevel
  if bystanderCooldownMs >= 0: gBystanderCooldownMs = int64(bystanderCooldownMs)

proc hearingConfigureTrigger*(name: string; on: bool): bool =
  let t = triggerIndex(name)
  if t < 0: return false
  gTrigOff[t] = (if on: 0 else: 1)
  result = true

proc hearSpeakM*(): float = gHearSpeakM
proc hearYellM*(): float = gHearYellM
proc chatterLevel*(): int = gChatterLevel
proc bystanderReactChance*(): float = gBystanderChance
proc bystanderCooldownMs*(): int64 = gBystanderCooldownMs
proc triggerEnabled*(name: string): bool =
  let t = triggerIndex(name)
  if t < 0: return false
  result = gTrigOff[t] == 0

# ---------------------------------------------------------------------------
# What the CLIENT last told us about each person's distance, and the per-person
# rate-limit clocks for the proactive triggers.
# ---------------------------------------------------------------------------

var gHPerson: seq[string] = @[]
var gHDist: seq[float] = @[]       ## metres, -1.0 = never reported
var gHDistMs: seq[int64] = @[]     ## wall ms of that report
var gHPrevDist: seq[float] = @[]   ## the one before it (for `approach`)
var gHPrevMs: seq[int64] = @[]
var gHNearSince: seq[int64] = @[]  ## when the player got within lingerM, -1 = not near
var gHLastSpokeMs: seq[int64] = @[]## when the PLAYER last addressed this person
var gHSalt: seq[int] = @[]         ## bumped per bark, so repeats differ
var gHFired: seq[int64] = @[]      ## NTrig entries per person: last fire, wall ms

proc findHear(personId: string): int =
  result = -1
  var i = 0
  while i < gHPerson.len:
    if gHPerson[i] == personId: return i
    i = i + 1

proc ensureHear*(personId: string): int =
  result = findHear(personId)
  if result >= 0: return result
  gHPerson.add personId
  gHDist.add -1.0
  gHDistMs.add 0'i64
  gHPrevDist.add -1.0
  gHPrevMs.add 0'i64
  gHNearSince.add -1'i64
  gHLastSpokeMs.add 0'i64
  gHSalt.add 0
  var k = 0
  while k < NTrig:
    gHFired.add -1'i64
    k = k + 1
  result = gHPerson.len - 1

proc hearingReset*() =
  ## A new raid. Distances and first-sight memory are per-raid by definition:
  ## `first_sight` means "the first time this raid", and a distance measured
  ## before an extract says nothing about where anyone is now.
  gHPerson = @[]
  gHDist = @[]
  gHDistMs = @[]
  gHPrevDist = @[]
  gHPrevMs = @[]
  gHNearSince = @[]
  gHLastSpokeMs = @[]
  gHSalt = @[]
  gHFired = @[]

proc hearingPeopleTracked*(): int = gHPerson.len

proc noteDistance*(personId: string; d: float; nowMs: int64) =
  ## The client measured it. Keeps ONE previous sample, which is all `approach`
  ## needs and is deliberately not a history: a ring buffer here would be state
  ## nothing reads.
  if personId.len == 0 or d < 0.0: return
  let i = ensureHear(personId)
  gHPrevDist[i] = gHDist[i]
  gHPrevMs[i] = gHDistMs[i]
  gHDist[i] = d
  gHDistMs[i] = nowMs

proc distanceOf*(personId: string): float =
  let i = findHear(personId)
  if i < 0: return -1.0
  result = gHDist[i]

proc distanceAtMs*(personId: string): int64 =
  let i = findHear(personId)
  if i < 0: return 0
  result = gHDistMs[i]

proc previousDistanceOf*(personId: string; prevMs: var int64): float =
  prevMs = 0
  let i = findHear(personId)
  if i < 0: return -1.0
  prevMs = gHPrevMs[i]
  result = gHPrevDist[i]

proc notePlayerSpokeTo*(personId: string; nowMs: int64) =
  if personId.len == 0: return
  let i = ensureHear(personId)
  gHLastSpokeMs[i] = nowMs
  gHNearSince[i] = -1   # a conversation is not lingering

proc playerSpokeToMs*(personId: string): int64 =
  let i = findHear(personId)
  if i < 0: return 0
  result = gHLastSpokeMs[i]

proc nearSince*(personId: string): int64 =
  let i = findHear(personId)
  if i < 0: return -1
  result = gHNearSince[i]

proc setNearSince*(personId: string; ms: int64) =
  let i = ensureHear(personId)
  gHNearSince[i] = ms

proc nextSalt*(personId: string): string =
  let i = ensureHear(personId)
  gHSalt[i] = gHSalt[i] + 1
  result = $gHSalt[i]

# ---------------------------------------------------------------------------
# Rate limiting
# ---------------------------------------------------------------------------

proc triggerLastMs*(personId, trigger: string): int64 =
  let t = triggerIndex(trigger)
  let i = findHear(personId)
  if t < 0 or i < 0: return -1
  result = gHFired[i * NTrig + t]

proc markTrigger*(personId, trigger: string; nowMs: int64) =
  let t = triggerIndex(trigger)
  if t < 0: return
  let i = ensureHear(personId)
  gHFired[i * NTrig + t] = nowMs

proc triggerAllowed*(personId, trigger: string; nowMs: int64;
                     gapMs: int64; why: var string): bool =
  ## PASS / refuse-with-a-reason. Never a silent false: `why` names which of
  ## the four gates said no, because "the NPC did not say anything" is the
  ## single hardest symptom to diagnose from the outside.
  why = ""
  let t = triggerIndex(trigger)
  if t < 0:
    why = "'" & trigger & "' is not a trigger this build knows"
    return false
  if gChatterLevel == 0:
    why = "chatterLevel is 0 (proactive speech is off entirely)"
    return false
  if gTrigOff[t] != 0:
    why = "the '" & trigger & "' trigger is switched off in the config"
    return false
  let i = ensureHear(personId)
  let last = gHFired[i * NTrig + t]
  # `chatterLevel 2` halves every gap; `1` is the configured gap.
  var gap = gapMs
  if gChatterLevel >= 2: gap = gap div 2
  if last >= 0 and nowMs - last < gap:
    why = "'" & trigger & "' fired " & $((nowMs - last) div 1000) &
          " s ago and its gap is " & $(gap div 1000) & " s"
    return false
  result = true

# ---------------------------------------------------------------------------
# The hearing decision
# ---------------------------------------------------------------------------

proc bucketOf*(personId: string): string =
  ## The stance bucket a BARK is picked from. Same function the reply tier
  ## uses, so a hostile person does not greet you warmly in one channel and
  ## coldly in the other.
  let pi = findPerson(personId)
  if pi < 0: return "neutral"
  let fi = findFaction(personFaction(pi))
  let rep = (if fi >= 0: factionRep(fi) else: 0)
  result = stanceBucket(personAttitude(pi), rep)

proc hearingDecide*(personId: string; quiet: bool; mode: var string;
                    audible: var bool; why: var string): float =
  ## Returns the distance used (-1 when unknown) and fills the three fields
  ## that go on the wire.
  ##
  ## UNKNOWN IS AUDIBLE. A distance nobody reported is not evidence of
  ## distance, and refusing to speak on missing data would silently mute the
  ## whole mod the moment `player_seen` stopped arriving -- which is exactly
  ## the failure mode that is impossible to tell from "the brain is broken".
  ## `why` says so on every such segment.
  let d = distanceOf(personId)
  if d < 0.0:
    mode = "speak"
    audible = true
    why = "no distance has been reported for " & personId &
          " this raid, so the line is spoken; it is NOT evidence they are near"
    return -1.0
  if quiet and d <= gMutterM:
    mode = "mutter"
    audible = true
    why = "an aside at " & $int(d) & " m"
    return d
  if d <= gHearSpeakM:
    mode = "speak"
    audible = true
    why = $int(d) & " m, within the " & $int(gHearSpeakM) & " m speaking range"
    return d
  if d <= gHearYellM:
    mode = "yell"
    audible = true
    why = $int(d) & " m: too far to speak, within the " & $int(gHearYellM) &
          " m yelling range"
    return d
  mode = "yell"
  audible = false
  why = $int(d) & " m is beyond the " & $int(gHearYellM) &
        " m yelling range; the player could not have heard this"
  result = d

proc shoutify*(text: string): string =
  ## The fallback rewrite for a line the ontology has no `yell` variant for --
  ## an LLM reply, most often. It keeps the FIRST sentence only and upper-cases
  ## it: a shout across forty metres is short by physics, not by style. The
  ## result is deliberately never equal to the input for any line containing a
  ## lower-case letter, which is what the check asserts.
  var first = text
  var i = 0
  while i < text.len:
    if text[i] == '.' or text[i] == '!' or text[i] == '?':
      first = text[0 .. i]
      break
    i = i + 1
  var s = toUpperAscii(first)
  if s.len == 0: return text
  if s[s.len - 1] == '.': s[s.len - 1] = '!'
  result = s

proc yellVersionOf*(personId, text: string; note: var string): string =
  ## The shouted form of a line, from the table when the table has one.
  let fromTable = ontologyYellFor(text, personId)
  if fromTable.len > 0:
    note = "yell variant from ontology.json"
    return fromTable
  note = "no yell variant in the table for this line; shortened and shouted"
  result = shoutify(text)

# ---------------------------------------------------------------------------
# Decorating a `say` payload
# ---------------------------------------------------------------------------

proc hearingFields*(distanceM: float; mode: string; audible: bool;
                    reaction: bool; why: string): string =
  ## The fields, WITHOUT the enclosing braces, so they can be spliced into a
  ## payload `bm/speech` built. Built with the real JSON writer rather than
  ## string concatenation, because a hand-rolled float would be the one thing
  ## that makes a payload unparseable at 3 a.m.
  var o = obj()
  o.put("distanceM", distanceM)
  o.put("mode", mode)
  o.put("audible", audible)
  o.put("reaction", reaction)
  o.put("hearSpeakM", gHearSpeakM)
  o.put("hearYellM", gHearYellM)
  o.put("hearingNote", why)
  let t = done(o).text
  if t.len < 2: return ""
  result = t[1 ..< t.len - 1]

proc decorateSay*(payload: string; distanceM: float; mode: string;
                  audible, reaction: bool; why: string): string =
  ## Splices the hearing fields (and, for a yell, `voiceSpec.yell:true`) into a
  ## `say` payload. It is a splice rather than a parameter on `sayPayload`
  ## because `bm/speech` is the ONE builder of that object and this is the ONE
  ## place that decides who can hear it; keeping them apart means a change to
  ## either cannot silently drop the other.
  if payload.len < 2 or payload[payload.len - 1] != '}': return payload
  let fields = hearingFields(distanceM, mode, audible, reaction, why)
  if fields.len == 0: return payload
  var s = payload[0 ..< payload.len - 1] & "," & fields & "}"
  if mode == "yell":
    # `voiceSpec.yell` is what the TTS engine reads to actually shout. The
    # marker is the literal key `bm/speech.voiceSpecJson` writes; if that key
    # ever moves, the splice does nothing rather than corrupting the object.
    let mark = "\"voiceSpec\":{"
    let at = find(s, mark)
    if at >= 0:
      s = s[0 ..< at + mark.len] & "\"yell\":true," & s[at + mark.len .. s.high]
  result = s

proc journalSuppressed*(personId, text, why: string) =
  ## The record of a line nobody could hear. WITHOUT this, a suppressed reply
  ## and a broken state machine look identical from the outside.
  var o = obj()
  o.put("personId", personId)
  o.put("text", text)
  o.put("why", why)
  o.put("distanceM", distanceOf(personId))
  o.put("hearYellM", gHearYellM)
  discard journal("say.suppressed", personId, "player", done(o).text)
  let pi = findPerson(personId)
  if pi >= 0:
    remember(pi, "I saw the player but they were too far away to hear me.")

proc hearingJson*(): JsonObject =
  var o = obj()
  o.put("hearSpeakM", gHearSpeakM)
  o.put("hearYellM", gHearYellM)
  o.put("mutterM", gMutterM)
  o.put("chatterLevel", gChatterLevel)
  o.put("bystanderReactChance", gBystanderChance)
  o.put("bystanderCooldownMs", int(gBystanderCooldownMs))
  o.put("tracked", gHPerson.len)
  var trig = arr()
  var i = 0
  while i < NTrig:
    var t = obj()
    t.put("trigger", TriggerNames[i])
    t.put("on", gTrigOff[i] == 0)
    trig.add t
    i = i + 1
  o.put("triggers", trig)
  o.put("barkRows", ontologyBarkRowCount())
  result = o
