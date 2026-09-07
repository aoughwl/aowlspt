## bm/world — the model, its JSON, and the store.
##
## Parallel `seq`s of primitives, one set per entity kind, exactly as every
## other mod in this repo keeps global state; nimony's `seq` has no `delete`,
## so anything that removes is a rebuild.
##
## DECISIONS MADE HERE (the contract left them open):
##
## * **List-valued fields (wants, forbids, traits, memory, knows, objectives)
##   are FLAT side tables** (`owner index` + `text`), not a joined string. A
##   joined string needs a separator, and the only separators that cannot occur
##   in prose are control characters -- which `aowlspt/json`'s reader does NOT
##   decode back (`` comes back as the six literal characters; that is a
##   measured bug in aowl.voice's cache, see vx/cache.nim's `hexEncode`
##   comment). A flat table sidesteps the escaping question entirely.
## * **The seed is stored as 16 hex characters**, not as a number. `asInt` goes
##   through `asFloat`, so a `uint64` seed above 2^53 would come back a
##   different number and the "same seed, same world" check would pass while
##   being false.
## * **Every float goes through `util.quant3` on the way in and `util.fmtF` on
##   the way out.** That is what makes save -> load -> save byte-identical
##   (DESIGN §9.2) instead of merely nearly so.
## * **Every kind document carries a `schema` string and an `items` array, and
##   a load that does not find both leaves that kind EMPTY and names the store
##   key in `note`.** A partial parse is the failure this model must not have:
##   half a faction table is indistinguishable from a small world.
## * **The journal is chunked at 500 events per store key** (`world.journal.0`,
##   `.1`, …) as DESIGN §3 says. `kindJsonText("journal")` returns the WHOLE
##   journal as one document, because the byte-identity check compares whole
##   kinds, not chunks.

import std/strutils
import aowlspt
import aowlspt/server as sv
import aowlspt/json as jr
import util

const
  SchemaMeta      = "aowl.basement.meta/1"
  SchemaFactions  = "aowl.basement.factions/1"
  SchemaPeople    = "aowl.basement.people/1"
  SchemaPlaces    = "aowl.basement.places/1"
  SchemaContracts = "aowl.basement.contracts/1"
  SchemaQuests    = "aowl.basement.quests/1"
  SchemaFacts     = "aowl.basement.facts/2"
  SchemaCaches    = "aowl.basement.caches/1"
  SchemaLoot      = "aowl.basement.loot/1"
  SchemaJournal   = "aowl.basement.journal/1"
  SchemaObjectives = "aowl.basement.objectives/1"
  JournalChunk    = 500
  MemoryBound     = 48

# ---------------------------------------------------------------------------
# State. Literal initialisers only -- nimony silently zeroes a DLL global whose
# initialiser is a call.
# ---------------------------------------------------------------------------

var gHasWorld: bool = false
var gSeed: uint64 = 0
var gPreset: string = ""
var gPrompt: string = ""
var gWName: string = ""
var gCreatedMs: int64 = 0
var gClockMs: int64 = 0
var gDay: int = 1
var gWeather: string = ""
var gVersion: int = 0

var gPlayerMap: string = ""
var gPlayerX: float = 0.0
var gPlayerY: float = 0.0
var gPlayerZ: float = 0.0
var gPlayerHp: float = 1.0

# factions
var gFacId: seq[string] = @[]
var gFacName: seq[string] = @[]
var gFacCreed: seq[string] = @[]
var gFacColour: seq[string] = @[]
var gFacHome: seq[string] = @[]
var gFacStrength: seq[float] = @[]
var gFacRep: seq[int] = @[]
var gStance: seq[string] = @[]        ## flattened n*n, symmetric by construction
var gWantFac: seq[int] = @[]
var gWantText: seq[string] = @[]
var gForbidFac: seq[int] = @[]
var gForbidText: seq[string] = @[]

# people
var gPId: seq[string] = @[]
var gPName: seq[string] = @[]
var gPFac: seq[string] = @[]
var gPRole: seq[string] = @[]
var gPVoice: seq[string] = @[]
var gPMap: seq[string] = @[]
var gPPlace: seq[string] = @[]
var gPX: seq[float] = @[]
var gPY: seq[float] = @[]
var gPZ: seq[float] = @[]
var gPActivity: seq[string] = @[]
var gPAlive: seq[int] = @[]
var gPHp: seq[float] = @[]
var gPMood: seq[float] = @[]
var gPAtt: seq[int] = @[]
var gPGroup: seq[string] = @[]
var gPEscort: seq[int] = @[]
var gPInv: seq[string] = @[]
var gPLastSeen: seq[int64] = @[]
var gTraitP: seq[int] = @[]
var gTraitText: seq[string] = @[]
var gMemP: seq[int] = @[]
var gMemText: seq[string] = @[]
var gKnowP: seq[int] = @[]
var gKnowText: seq[string] = @[]
var gPObjRole: seq[string] = @[]    ## this person's role INSIDE their group's
                                    ## objective: leader | cover | carrier | "".
                                    ## Deliberately NOT a schema bump: the loader
                                    ## defaults it to "", so a world saved before
                                    ## objectives existed still loads whole.

# places
var gPlId: seq[string] = @[]
var gPlName: seq[string] = @[]
var gPlMap: seq[string] = @[]
var gPlKind: seq[string] = @[]
var gPlOwner: seq[string] = @[]
var gPlX: seq[float] = @[]
var gPlY: seq[float] = @[]
var gPlZ: seq[float] = @[]
var gPlDanger: seq[float] = @[]

# contracts
var gCId: seq[string] = @[]
var gCKind: seq[string] = @[]
var gCA: seq[string] = @[]
var gCB: seq[string] = @[]
var gCTerms: seq[string] = @[]
var gCStakes: seq[string] = @[]
var gCStatus: seq[string] = @[]
var gCExpires: seq[int64] = @[]

# quests
var gQId: seq[string] = @[]
var gQGiver: seq[string] = @[]
var gQTitle: seq[string] = @[]
var gQBrief: seq[string] = @[]
var gQKind: seq[string] = @[]
var gQTarget: seq[string] = @[]
var gQReward: seq[string] = @[]
var gQStatus: seq[string] = @[]
var gObjQ: seq[int] = @[]
var gObjText: seq[string] = @[]

# facts. A fact now REFERS to an entity (refKind/refId) and knows where it came
# from (origin gen|plant|rumour|outcome). That is the whole grounding rule: a
# person's `knows` holds entity ids, and a fact about a cache carries the cache
# id, so "what they talk about" and "what the world holds" are the same rows.
var gFtId: seq[string] = @[]
var gFtTags: seq[string] = @[]
var gFtText: seq[string] = @[]
var gFtRefKind: seq[string] = @[]
var gFtRefId: seq[string] = @[]
var gFtOrigin: seq[string] = @[]
var gFtSpread: seq[int64] = @[]

# caches. `items` is a FLAT side table of (cache index, tpl, count) rather than
# a `seq[(string,int)]` field: the contract asked for a tuple-valued getter and
# said to use two parallel getters if tuples misbehave in nimony. They do -- a
# `seq` of tuples has no literal initialiser here -- so `cacheItemTpls` and
# `cacheItemCounts` are the two getters, index-aligned by construction because
# they are produced by the same walk.
var gChId: seq[string] = @[]
var gChName: seq[string] = @[]
var gChPlace: seq[string] = @[]
var gChMap: seq[string] = @[]
var gChOwner: seq[string] = @[]
var gChGuard: seq[string] = @[]
var gChStory: seq[string] = @[]
var gChStatus: seq[string] = @[]
var gChPlanted: seq[string] = @[]
var gChX: seq[float] = @[]
var gChY: seq[float] = @[]
var gChZ: seq[float] = @[]
var gChCreated: seq[int64] = @[]
var gChItemC: seq[int] = @[]
var gChItemTpl: seq[string] = @[]
var gChItemN: seq[int] = @[]
var gChKnowC: seq[int] = @[]
var gChKnowP: seq[string] = @[]

# loose loot (planted, or the expansion of a cache into pickable rows)
var gLtId: seq[string] = @[]
var gLtCache: seq[string] = @[]
var gLtTpl: seq[string] = @[]
var gLtMap: seq[string] = @[]
var gLtCount: seq[int] = @[]
var gLtX: seq[float] = @[]
var gLtY: seq[float] = @[]
var gLtZ: seq[float] = @[]
var gLtStatus: seq[string] = @[]

# journal
var gJSeq: seq[int] = @[]
var gJAt: seq[int64] = @[]
var gJKind: seq[string] = @[]
var gJActor: seq[string] = @[]
var gJTarget: seq[string] = @[]
var gJData: seq[string] = @[]
var gJNext: int = 1

# objectives. An objective belongs to a GROUP (ownerKind "group") or to one
# person (ownerKind "person"), points at one target entity, and has exactly
# one status. It is a first-class persisted kind and not a field on the group,
# because a group is DERIVED from `person.group` (see bm/offscreen) and a row
# hanging off a derived thing cannot survive a load.
var gObId: seq[string] = @[]
var gObOwnerKind: seq[string] = @[]
var gObOwner: seq[string] = @[]
var gObKind: seq[string] = @[]
var gObTargetKind: seq[string] = @[]
var gObTarget: seq[string] = @[]
var gObPriority: seq[int] = @[]
var gObStarted: seq[int64] = @[]
var gObUntil: seq[int64] = @[]
var gObStatus: seq[string] = @[]
var gObNote: seq[string] = @[]

# ---------------------------------------------------------------------------
# meta
# ---------------------------------------------------------------------------

proc worldExists*(): bool = gHasWorld
proc worldSeed*(): uint64 = gSeed
proc worldPreset*(): string = gPreset
proc worldPrompt*(): string = gPrompt
proc worldName*(): string = gWName
proc worldClockMs*(): int64 = gClockMs
proc worldVersion*(): int = gVersion
proc worldDay*(): int = gDay
proc worldWeather*(): string = gWeather
proc setWorldWeather*(s: string) = gWeather = s

proc setWorldMeta*(seed: uint64; preset, prompt, name: string; clockMs: int64) =
  gSeed = seed
  gPreset = preset
  gPrompt = prompt
  gWName = name
  gClockMs = clockMs
  gCreatedMs = clockMs
  gDay = 1 + int(clockMs div 86400000'i64)
  gHasWorld = true

proc advanceClock*(ms: int64) =
  if ms <= 0: return
  gClockMs = gClockMs + ms
  gDay = 1 + int(gClockMs div 86400000'i64)

proc resetWorld*() =
  gHasWorld = false
  gSeed = 0; gPreset = ""; gPrompt = ""; gWName = ""
  gCreatedMs = 0; gClockMs = 0; gDay = 1; gWeather = ""; gVersion = 0
  gPlayerMap = ""; gPlayerX = 0.0; gPlayerY = 0.0; gPlayerZ = 0.0; gPlayerHp = 1.0
  gFacId = @[]; gFacName = @[]; gFacCreed = @[]; gFacColour = @[]
  gFacHome = @[]; gFacStrength = @[]; gFacRep = @[]; gStance = @[]
  gWantFac = @[]; gWantText = @[]; gForbidFac = @[]; gForbidText = @[]
  gPId = @[]; gPName = @[]; gPFac = @[]; gPRole = @[]; gPVoice = @[]
  gPMap = @[]; gPPlace = @[]; gPX = @[]; gPY = @[]; gPZ = @[]
  gPActivity = @[]; gPAlive = @[]; gPHp = @[]; gPMood = @[]; gPAtt = @[]
  gPGroup = @[]; gPEscort = @[]; gPInv = @[]; gPLastSeen = @[]
  gTraitP = @[]; gTraitText = @[]; gMemP = @[]; gMemText = @[]
  gKnowP = @[]; gKnowText = @[]
  gPlId = @[]; gPlName = @[]; gPlMap = @[]; gPlKind = @[]; gPlOwner = @[]
  gPlX = @[]; gPlY = @[]; gPlZ = @[]; gPlDanger = @[]
  gCId = @[]; gCKind = @[]; gCA = @[]; gCB = @[]; gCTerms = @[]
  gCStakes = @[]; gCStatus = @[]; gCExpires = @[]
  gQId = @[]; gQGiver = @[]; gQTitle = @[]; gQBrief = @[]; gQKind = @[]
  gQTarget = @[]; gQReward = @[]; gQStatus = @[]; gObjQ = @[]; gObjText = @[]
  gFtId = @[]; gFtTags = @[]; gFtText = @[]
  gFtRefKind = @[]; gFtRefId = @[]; gFtOrigin = @[]; gFtSpread = @[]
  gChId = @[]; gChName = @[]; gChPlace = @[]; gChMap = @[]; gChOwner = @[]
  gChGuard = @[]; gChStory = @[]; gChStatus = @[]; gChPlanted = @[]
  gChX = @[]; gChY = @[]; gChZ = @[]; gChCreated = @[]
  gChItemC = @[]; gChItemTpl = @[]; gChItemN = @[]
  gChKnowC = @[]; gChKnowP = @[]
  gLtId = @[]; gLtCache = @[]; gLtTpl = @[]; gLtMap = @[]; gLtCount = @[]
  gLtX = @[]; gLtY = @[]; gLtZ = @[]; gLtStatus = @[]
  gPObjRole = @[]
  gObId = @[]; gObOwnerKind = @[]; gObOwner = @[]; gObKind = @[]
  gObTargetKind = @[]; gObTarget = @[]; gObPriority = @[]
  gObStarted = @[]; gObUntil = @[]; gObStatus = @[]; gObNote = @[]
  gJSeq = @[]; gJAt = @[]; gJKind = @[]; gJActor = @[]; gJTarget = @[]
  gJData = @[]; gJNext = 1

# ---------------------------------------------------------------------------
# factions
# ---------------------------------------------------------------------------

proc factionCount*(): int = gFacId.len

proc findFaction*(id: string): int =
  result = -1
  var i = 0
  while i < gFacId.len:
    if gFacId[i] == id: return i
    i = i + 1

proc growStance(n: int) =
  ## The matrix is flat, so adding a faction reshapes it. Rebuild rather than
  ## index arithmetic in place: an off-by-one here would silently rewrite half
  ## the world's diplomacy.
  let old = n - 1
  var m: seq[string] = @[]
  var a = 0
  while a < n:
    var b = 0
    while b < n:
      if a < old and b < old: m.add gStance[a * old + b]
      elif a == b: m.add "allied"
      else: m.add "neutral"
      b = b + 1
    a = a + 1
  gStance = m

proc addFaction*(id, name, creed, colour, homeMap: string; strength: float): int =
  let seen = findFaction(id)
  if seen >= 0: return seen
  gFacId.add id
  gFacName.add name
  gFacCreed.add creed
  gFacColour.add colour
  gFacHome.add homeMap
  gFacStrength.add quant3(clampF(strength, 0.0, 1.0))
  gFacRep.add 0
  growStance(gFacId.len)
  result = gFacId.len - 1

proc factionId*(i: int): string =
  if i < 0 or i >= gFacId.len: return ""
  result = gFacId[i]
proc factionName*(i: int): string =
  if i < 0 or i >= gFacName.len: return ""
  result = gFacName[i]
proc factionCreed*(i: int): string =
  if i < 0 or i >= gFacCreed.len: return ""
  result = gFacCreed[i]
proc factionColour*(i: int): string =
  if i < 0 or i >= gFacColour.len: return ""
  result = gFacColour[i]
proc factionHomeMap*(i: int): string =
  if i < 0 or i >= gFacHome.len: return ""
  result = gFacHome[i]
proc factionStrength*(i: int): float =
  if i < 0 or i >= gFacStrength.len: return 0.0
  result = gFacStrength[i]
proc setFactionStrength*(i: int; v: float) =
  if i < 0 or i >= gFacStrength.len: return
  gFacStrength[i] = quant3(clampF(v, 0.0, 1.0))
proc factionRep*(i: int): int =
  if i < 0 or i >= gFacRep.len: return 0
  result = gFacRep[i]
proc setFactionRep*(i: int; v: int) =
  if i < 0 or i >= gFacRep.len: return
  gFacRep[i] = clampI(v, -100, 100)

proc stance*(a, b: int): string =
  let n = gFacId.len
  if a < 0 or b < 0 or a >= n or b >= n: return ""
  result = gStance[a * n + b]

proc setStance*(a, b: int; s: string) =
  ## Symmetric by construction: there is no way to express "A is at war with B
  ## while B is neutral" through this API, because every place that reads it
  ## would then have to decide which side it believed.
  let n = gFacId.len
  if a < 0 or b < 0 or a >= n or b >= n: return
  if s != "allied" and s != "neutral" and s != "rival" and s != "war": return
  gStance[a * n + b] = s
  gStance[b * n + a] = s

proc factionWants*(i: int): seq[string] =
  result = @[]
  var k = 0
  while k < gWantFac.len:
    if gWantFac[k] == i: result.add gWantText[k]
    k = k + 1

proc addFactionWant*(i: int; w: string) =
  if i < 0 or i >= gFacId.len or w.len == 0: return
  gWantFac.add i
  gWantText.add w

proc factionForbids*(i: int): seq[string] =
  result = @[]
  var k = 0
  while k < gForbidFac.len:
    if gForbidFac[k] == i: result.add gForbidText[k]
    k = k + 1

proc addFactionForbid*(i: int; w: string) =
  if i < 0 or i >= gFacId.len or w.len == 0: return
  gForbidFac.add i
  gForbidText.add w

# ---------------------------------------------------------------------------
# people
# ---------------------------------------------------------------------------

proc personCount*(): int = gPId.len

proc findPerson*(id: string): int =
  result = -1
  var i = 0
  while i < gPId.len:
    if gPId[i] == id: return i
    i = i + 1

proc addPerson*(id, name, factionId, role, voice, map, placeId: string;
                x, y, z: float; traits: seq[string]): int =
  let seen = findPerson(id)
  if seen >= 0: return seen
  gPId.add id
  gPName.add name
  gPFac.add factionId
  gPRole.add role
  gPVoice.add voice
  gPMap.add map
  gPPlace.add placeId
  gPX.add quant3(x)
  gPY.add quant3(y)
  gPZ.add quant3(z)
  gPActivity.add "idle"
  gPAlive.add 1
  gPHp.add 1.0
  gPMood.add 0.0
  gPAtt.add 0
  gPGroup.add ""
  gPEscort.add 0
  gPInv.add ""
  gPLastSeen.add 0'i64
  gPObjRole.add ""
  let idx = gPId.len - 1
  for t in traits:
    if t.len > 0:
      gTraitP.add idx
      gTraitText.add t
  result = idx

proc personId*(i: int): string =
  if i < 0 or i >= gPId.len: return ""
  result = gPId[i]
proc personName*(i: int): string =
  if i < 0 or i >= gPName.len: return ""
  result = gPName[i]
proc personFaction*(i: int): string =
  if i < 0 or i >= gPFac.len: return ""
  result = gPFac[i]
proc personRole*(i: int): string =
  if i < 0 or i >= gPRole.len: return ""
  result = gPRole[i]
proc personVoice*(i: int): string =
  if i < 0 or i >= gPVoice.len: return ""
  result = gPVoice[i]

proc personTraits*(i: int): seq[string] =
  result = @[]
  var k = 0
  while k < gTraitP.len:
    if gTraitP[k] == i: result.add gTraitText[k]
    k = k + 1

proc personMap*(i: int): string =
  if i < 0 or i >= gPMap.len: return ""
  result = gPMap[i]
proc personPlace*(i: int): string =
  if i < 0 or i >= gPPlace.len: return ""
  result = gPPlace[i]

proc personPos*(i: int; x, y, z: var float) =
  if i < 0 or i >= gPX.len:
    x = 0.0; y = 0.0; z = 0.0
    return
  x = gPX[i]; y = gPY[i]; z = gPZ[i]

proc setPersonPos*(i: int; map, placeId: string; x, y, z: float) =
  if i < 0 or i >= gPX.len: return
  gPMap[i] = map
  gPPlace[i] = placeId
  gPX[i] = quant3(x); gPY[i] = quant3(y); gPZ[i] = quant3(z)

proc personActivity*(i: int): string =
  if i < 0 or i >= gPActivity.len: return ""
  result = gPActivity[i]
proc setPersonActivity*(i: int; a: string) =
  if i < 0 or i >= gPActivity.len: return
  gPActivity[i] = a

proc personAlive*(i: int): bool =
  if i < 0 or i >= gPAlive.len: return false
  result = gPAlive[i] == 1
proc setPersonAlive*(i: int; v: bool) =
  if i < 0 or i >= gPAlive.len: return
  gPAlive[i] = (if v: 1 else: 0)

proc personHp*(i: int): float =
  if i < 0 or i >= gPHp.len: return 0.0
  result = gPHp[i]
proc setPersonHp*(i: int; v: float) =
  if i < 0 or i >= gPHp.len: return
  gPHp[i] = quant3(clampF(v, 0.0, 1.0))

proc personMood*(i: int): float =
  if i < 0 or i >= gPMood.len: return 0.0
  result = gPMood[i]
proc setPersonMood*(i: int; v: float) =
  if i < 0 or i >= gPMood.len: return
  gPMood[i] = quant3(clampF(v, -1.0, 1.0))

proc personAttitude*(i: int): int =
  if i < 0 or i >= gPAtt.len: return 0
  result = gPAtt[i]
proc setPersonAttitude*(i: int; v: int) =
  if i < 0 or i >= gPAtt.len: return
  gPAtt[i] = clampI(v, -100, 100)

proc personGroup*(i: int): string =
  if i < 0 or i >= gPGroup.len: return ""
  result = gPGroup[i]
proc setPersonGroup*(i: int; g: string) =
  if i < 0 or i >= gPGroup.len: return
  gPGroup[i] = g

proc personEscorting*(i: int): bool =
  if i < 0 or i >= gPEscort.len: return false
  result = gPEscort[i] == 1
proc setPersonEscorting*(i: int; v: bool) =
  if i < 0 or i >= gPEscort.len: return
  gPEscort[i] = (if v: 1 else: 0)

proc personInventoryNote*(i: int): string =
  if i < 0 or i >= gPInv.len: return ""
  result = gPInv[i]
proc setPersonInventoryNote*(i: int; s: string) =
  if i < 0 or i >= gPInv.len: return
  gPInv[i] = s

proc memoryLines*(i: int): int =
  result = 0
  var k = 0
  while k < gMemP.len:
    if gMemP[k] == i: result = result + 1
    k = k + 1

proc remember*(i: int; line: string) =
  ## Bounded at 48 lines per person; the oldest is dropped. A rebuild, because
  ## a nimony `seq` cannot shrink in place.
  if i < 0 or i >= gPId.len or line.len == 0: return
  gMemP.add i
  gMemText.add oneLine(line)
  if memoryLines(i) <= MemoryBound: return
  var dropped = false
  var p: seq[int] = @[]
  var t: seq[string] = @[]
  var k = 0
  while k < gMemP.len:
    if gMemP[k] == i and not dropped:
      dropped = true
    else:
      p.add gMemP[k]
      t.add gMemText[k]
    k = k + 1
  gMemP = p
  gMemText = t

proc memoryList*(i: int): seq[string] =
  result = @[]
  var k = 0
  while k < gMemP.len:
    if gMemP[k] == i: result.add gMemText[k]
    k = k + 1

proc memoryOf*(i: int; last: int): string =
  var keep: seq[string] = @[]
  var k = 0
  while k < gMemP.len:
    if gMemP[k] == i: keep.add gMemText[k]
    k = k + 1
  var start = keep.len - last
  if start < 0: start = 0
  result = ""
  var j = start
  while j < keep.len:
    if j > start: result.add "\n"
    result.add keep[j]
    j = j + 1

proc personKnows*(i: int): seq[string] =
  result = @[]
  var k = 0
  while k < gKnowP.len:
    if gKnowP[k] == i: result.add gKnowText[k]
    k = k + 1

proc addPersonKnows*(i: int; factId: string) =
  if i < 0 or i >= gPId.len or factId.len == 0: return
  var k = 0
  while k < gKnowP.len:
    if gKnowP[k] == i and gKnowText[k] == factId: return
    k = k + 1
  gKnowP.add i
  gKnowText.add factId

proc personObjRole*(i: int): string =
  if i < 0 or i >= gPObjRole.len: return ""
  result = gPObjRole[i]

proc setPersonObjRole*(i: int; s: string) =
  if i >= 0 and i < gPObjRole.len: gPObjRole[i] = s

proc personLastSeenMs*(i: int): int64 =
  if i < 0 or i >= gPLastSeen.len: return 0'i64
  result = gPLastSeen[i]
proc setPersonLastSeenMs*(i: int; v: int64) =
  if i < 0 or i >= gPLastSeen.len: return
  gPLastSeen[i] = v

proc peopleNear*(map: string; x, y, z, radius: float): seq[int] =
  ## Alive only. A dead person is not "near" anything the client should spawn.
  result = @[]
  let r2 = radius * radius
  var i = 0
  while i < gPId.len:
    if gPAlive[i] == 1 and gPMap[i] == map:
      let dx = gPX[i] - x
      let dy = gPY[i] - y
      let dz = gPZ[i] - z
      if dx*dx + dy*dy + dz*dz <= r2: result.add i
    i = i + 1

proc peopleOfFaction*(fi: int): seq[int] =
  result = @[]
  if fi < 0 or fi >= gFacId.len: return
  let fid = gFacId[fi]
  var i = 0
  while i < gPId.len:
    if gPFac[i] == fid: result.add i
    i = i + 1

proc peopleOfGroup*(g: string): seq[int] =
  result = @[]
  if g.len == 0: return
  var i = 0
  while i < gPId.len:
    if gPGroup[i] == g: result.add i
    i = i + 1

# ---------------------------------------------------------------------------
# places
# ---------------------------------------------------------------------------

proc placeCount*(): int = gPlId.len

proc findPlace*(id: string): int =
  result = -1
  var i = 0
  while i < gPlId.len:
    if gPlId[i] == id: return i
    i = i + 1

proc addPlace*(id, name, map, kind, ownerFactionId: string;
               x, y, z, danger: float): int =
  let seen = findPlace(id)
  if seen >= 0: return seen
  gPlId.add id
  gPlName.add name
  gPlMap.add map
  gPlKind.add kind
  gPlOwner.add ownerFactionId
  gPlX.add quant3(x)
  gPlY.add quant3(y)
  gPlZ.add quant3(z)
  gPlDanger.add quant3(clampF(danger, 0.0, 1.0))
  result = gPlId.len - 1

proc placeId*(i: int): string =
  if i < 0 or i >= gPlId.len: return ""
  result = gPlId[i]
proc placeName*(i: int): string =
  if i < 0 or i >= gPlName.len: return ""
  result = gPlName[i]
proc placeMap*(i: int): string =
  if i < 0 or i >= gPlMap.len: return ""
  result = gPlMap[i]
proc placeKind*(i: int): string =
  if i < 0 or i >= gPlKind.len: return ""
  result = gPlKind[i]
proc placeOwner*(i: int): string =
  if i < 0 or i >= gPlOwner.len: return ""
  result = gPlOwner[i]
proc setPlaceOwner*(i: int; f: string) =
  if i < 0 or i >= gPlOwner.len: return
  gPlOwner[i] = f

proc placePos*(i: int; x, y, z: var float) =
  if i < 0 or i >= gPlX.len:
    x = 0.0; y = 0.0; z = 0.0
    return
  x = gPlX[i]; y = gPlY[i]; z = gPlZ[i]

proc placeDanger*(i: int): float =
  if i < 0 or i >= gPlDanger.len: return 0.0
  result = gPlDanger[i]

proc placesOnMap*(map: string): seq[int] =
  result = @[]
  var i = 0
  while i < gPlId.len:
    if gPlMap[i] == map: result.add i
    i = i + 1

# ---------------------------------------------------------------------------
# contracts
# ---------------------------------------------------------------------------

proc contractCount*(): int = gCId.len

proc findContract*(id: string): int =
  result = -1
  var i = 0
  while i < gCId.len:
    if gCId[i] == id: return i
    i = i + 1

proc addContract*(id, kind, partyA, partyB, terms, stakes: string;
                  expiresMs: int64): int =
  let seen = findContract(id)
  if seen >= 0: return seen
  gCId.add id
  gCKind.add kind
  gCA.add partyA
  gCB.add partyB
  gCTerms.add terms
  gCStakes.add stakes
  gCStatus.add "offered"
  gCExpires.add expiresMs
  result = gCId.len - 1

proc contractId*(i: int): string =
  if i < 0 or i >= gCId.len: return ""
  result = gCId[i]
proc contractKind*(i: int): string =
  if i < 0 or i >= gCKind.len: return ""
  result = gCKind[i]
proc contractPartyA*(i: int): string =
  if i < 0 or i >= gCA.len: return ""
  result = gCA[i]
proc contractPartyB*(i: int): string =
  if i < 0 or i >= gCB.len: return ""
  result = gCB[i]
proc contractTerms*(i: int): string =
  if i < 0 or i >= gCTerms.len: return ""
  result = gCTerms[i]
proc contractStakes*(i: int): string =
  if i < 0 or i >= gCStakes.len: return ""
  result = gCStakes[i]
proc contractStatus*(i: int): string =
  if i < 0 or i >= gCStatus.len: return ""
  result = gCStatus[i]
proc setContractStatus*(i: int; s: string) =
  if i < 0 or i >= gCStatus.len: return
  gCStatus[i] = s
proc contractExpiresMs*(i: int): int64 =
  if i < 0 or i >= gCExpires.len: return 0'i64
  result = gCExpires[i]

proc contractsOf*(party: string; status: string = ""): seq[int] =
  result = @[]
  var i = 0
  while i < gCId.len:
    if gCA[i] == party or gCB[i] == party:
      if status.len == 0 or gCStatus[i] == status: result.add i
    i = i + 1

proc activeContractOfKind*(kind, party: string): int =
  result = -1
  var i = 0
  while i < gCId.len:
    if gCKind[i] == kind and gCStatus[i] == "active" and
       (gCA[i] == party or gCB[i] == party): return i
    i = i + 1

# ---------------------------------------------------------------------------
# quests
# ---------------------------------------------------------------------------

proc questCount*(): int = gQId.len

proc findQuest*(id: string): int =
  result = -1
  var i = 0
  while i < gQId.len:
    if gQId[i] == id: return i
    i = i + 1

proc addQuest*(id, giverId, title, brief, kind, targetRef, reward: string;
               objectives: seq[string]): int =
  let seen = findQuest(id)
  if seen >= 0: return seen
  gQId.add id
  gQGiver.add giverId
  gQTitle.add title
  gQBrief.add brief
  gQKind.add kind
  gQTarget.add targetRef
  gQReward.add reward
  gQStatus.add "offered"
  let idx = gQId.len - 1
  for o in objectives:
    if o.len > 0:
      gObjQ.add idx
      gObjText.add o
  result = idx

proc questId*(i: int): string =
  if i < 0 or i >= gQId.len: return ""
  result = gQId[i]
proc questTitle*(i: int): string =
  if i < 0 or i >= gQTitle.len: return ""
  result = gQTitle[i]
proc questGiver*(i: int): string =
  if i < 0 or i >= gQGiver.len: return ""
  result = gQGiver[i]
proc questBrief*(i: int): string =
  if i < 0 or i >= gQBrief.len: return ""
  result = gQBrief[i]
proc questKind*(i: int): string =
  if i < 0 or i >= gQKind.len: return ""
  result = gQKind[i]
proc questTarget*(i: int): string =
  if i < 0 or i >= gQTarget.len: return ""
  result = gQTarget[i]
proc questReward*(i: int): string =
  if i < 0 or i >= gQReward.len: return ""
  result = gQReward[i]
proc questStatus*(i: int): string =
  if i < 0 or i >= gQStatus.len: return ""
  result = gQStatus[i]
proc setQuestStatus*(i: int; s: string) =
  if i < 0 or i >= gQStatus.len: return
  gQStatus[i] = s

proc questObjectives*(i: int): seq[string] =
  result = @[]
  var k = 0
  while k < gObjQ.len:
    if gObjQ[k] == i: result.add gObjText[k]
    k = k + 1

proc questsOf*(giverId: string): seq[int] =
  result = @[]
  var i = 0
  while i < gQId.len:
    if gQGiver[i] == giverId: result.add i
    i = i + 1

# ---------------------------------------------------------------------------
# facts
# ---------------------------------------------------------------------------

proc factCount*(): int = gFtId.len

proc addFactRef*(id, tags, text, refKind, refId, origin: string) =
  ## A fact that is ABOUT something. `origin` is gen | plant | rumour | outcome
  ## and is never inferred later: a rumour that a cache was hit must be
  ## distinguishable from the generated rumour that it exists, or the loop in
  ## DESIGN §11.3 cannot be checked.
  if id.len == 0: return
  var i = 0
  while i < gFtId.len:
    if gFtId[i] == id: return
    i = i + 1
  gFtId.add id
  gFtTags.add tags
  gFtText.add text
  gFtRefKind.add refKind
  gFtRefId.add refId
  gFtOrigin.add (if origin.len > 0: origin else: "gen")
  gFtSpread.add gClockMs

proc addFact*(id, tags, text: string) =
  ## The un-referenced form every caller before grounding used. It is the same
  ## row with empty refs, so the parallel seqs cannot drift out of alignment.
  addFactRef(id, tags, text, "", "", "gen")

proc factRef*(i: int; refKind, refId: var string) =
  if i < 0 or i >= gFtId.len:
    refKind = ""; refId = ""
    return
  refKind = gFtRefKind[i]; refId = gFtRefId[i]

proc factOrigin*(i: int): string =
  if i < 0 or i >= gFtOrigin.len: return ""
  result = gFtOrigin[i]

proc factSpreadMs*(i: int): int64 =
  if i < 0 or i >= gFtSpread.len: return 0'i64
  result = gFtSpread[i]

proc setFactSpreadMs*(i: int; v: int64) =
  if i < 0 or i >= gFtSpread.len: return
  gFtSpread[i] = v

proc findFact*(id: string): int =
  result = -1
  var i = 0
  while i < gFtId.len:
    if gFtId[i] == id: return i
    i = i + 1

proc factsAbout*(refKind, refId: string): seq[int] =
  result = @[]
  if refId.len == 0: return
  var i = 0
  while i < gFtId.len:
    if gFtRefId[i] == refId and (refKind.len == 0 or gFtRefKind[i] == refKind):
      result.add i
    i = i + 1

proc factId*(i: int): string =
  if i < 0 or i >= gFtId.len: return ""
  result = gFtId[i]
proc factText*(i: int): string =
  if i < 0 or i >= gFtText.len: return ""
  result = gFtText[i]

proc wordsOf(s: string): seq[string] =
  result = @[]
  for w in normalizeText(s).split(' '):
    if w.len >= 3: result.add w

proc retrieveFacts*(query, tags: string; limit: int; hitIds: var string): string =
  ## Keyword overlap, the query weighted 3:1 over the person's tags -- the
  ## ratio aowl.voice measured. Ties break by fact order, so the result is
  ## deterministic for a given world.
  hitIds = ""
  result = ""
  if gFtId.len == 0 or limit <= 0: return
  let qw = wordsOf(query)
  let tw = wordsOf(tags)
  var score: seq[int] = @[]
  var i = 0
  while i < gFtId.len:
    let fw = wordsOf(gFtTags[i] & " " & gFtText[i])
    var s = 0
    for w in qw:
      for f in fw:
        if f == w:
          s = s + 3
          break
    for w in tw:
      for f in fw:
        if f == w:
          s = s + 1
          break
    score.add s
    i = i + 1
  var taken = 0
  var used: seq[int] = @[]
  while taken < limit:
    var best = -1
    var bestScore = 0
    var k = 0
    while k < score.len:
      var already = false
      for u in used:
        if u == k: already = true
      if not already and score[k] > bestScore:
        bestScore = score[k]
        best = k
      k = k + 1
    if best < 0: break
    used.add best
    if hitIds.len > 0: hitIds.add " "
    hitIds.add gFtId[best]
    result.add "- " & gFtText[best] & "\n"
    taken = taken + 1

# ---------------------------------------------------------------------------
# caches -- the real thing an NPC is talking about (DESIGN §11)
# ---------------------------------------------------------------------------

proc cacheCount*(): int = gChId.len

proc findCache*(id: string): int =
  result = -1
  var i = 0
  while i < gChId.len:
    if gChId[i] == id: return i
    i = i + 1

proc addCache*(id, name, placeId, map, ownerFactionId, guardGroupId, story,
               plantedBy: string; x, y, z: float): int =
  let seen = findCache(id)
  if seen >= 0: return seen
  gChId.add id
  gChName.add name
  gChPlace.add placeId
  gChMap.add map
  gChOwner.add ownerFactionId
  gChGuard.add guardGroupId
  gChStory.add story
  gChStatus.add "rumoured"
  gChPlanted.add plantedBy
  gChX.add quant3(x)
  gChY.add quant3(y)
  gChZ.add quant3(z)
  gChCreated.add gClockMs
  result = gChId.len - 1

proc cacheId*(i: int): string =
  if i < 0 or i >= gChId.len: return ""
  result = gChId[i]
proc cacheName*(i: int): string =
  if i < 0 or i >= gChName.len: return ""
  result = gChName[i]
proc cachePlace*(i: int): string =
  if i < 0 or i >= gChPlace.len: return ""
  result = gChPlace[i]
proc cacheMap*(i: int): string =
  if i < 0 or i >= gChMap.len: return ""
  result = gChMap[i]
proc cacheOwner*(i: int): string =
  if i < 0 or i >= gChOwner.len: return ""
  result = gChOwner[i]
proc setCacheOwner*(i: int; factionId: string) =
  if i >= 0 and i < gChOwner.len: gChOwner[i] = factionId

proc cacheGuardGroup*(i: int): string =
  if i < 0 or i >= gChGuard.len: return ""
  result = gChGuard[i]
proc cacheStory*(i: int): string =
  if i < 0 or i >= gChStory.len: return ""
  result = gChStory[i]
proc cachePlantedBy*(i: int): string =
  if i < 0 or i >= gChPlanted.len: return ""
  result = gChPlanted[i]
proc setCacheGuardGroup*(i: int; g: string) =
  ## The guards are created after the cache row exists (they stand ON it), so
  ## the group id is written back rather than guessed at the call site.
  if i < 0 or i >= gChGuard.len: return
  gChGuard[i] = g

proc cacheStatus*(i: int): string =
  if i < 0 or i >= gChStatus.len: return ""
  result = gChStatus[i]

proc setCacheStatus*(i: int; s: string) =
  ## rumoured | intact | looted | moved. An unknown word is REFUSED rather than
  ## stored: a status nobody handles reads on the wire exactly like one that
  ## does, and the scene would then materialise a cache in a state no branch
  ## covers.
  if i < 0 or i >= gChStatus.len: return
  if s != "rumoured" and s != "intact" and s != "looted" and s != "moved": return
  gChStatus[i] = s

proc cachePos*(i: int; x, y, z: var float) =
  if i < 0 or i >= gChX.len:
    x = 0.0; y = 0.0; z = 0.0
    return
  x = gChX[i]; y = gChY[i]; z = gChZ[i]

proc setCachePos*(i: int; map, placeId: string; x, y, z: float) =
  if i < 0 or i >= gChX.len: return
  gChMap[i] = map
  gChPlace[i] = placeId
  gChX[i] = quant3(x); gChY[i] = quant3(y); gChZ[i] = quant3(z)

proc cacheAddItem*(i: int; tpl: string; count: int) =
  if i < 0 or i >= gChId.len or tpl.len == 0 or count <= 0: return
  gChItemC.add i
  gChItemTpl.add tpl
  gChItemN.add count

proc cacheItemTpls*(i: int): seq[string] =
  result = @[]
  var k = 0
  while k < gChItemC.len:
    if gChItemC[k] == i: result.add gChItemTpl[k]
    k = k + 1

proc cacheItemCounts*(i: int): seq[int] =
  ## Index-aligned with `cacheItemTpls` by construction: same table, same walk.
  result = @[]
  var k = 0
  while k < gChItemC.len:
    if gChItemC[k] == i: result.add gChItemN[k]
    k = k + 1

proc cacheItemCount*(i: int): int =
  result = 0
  var k = 0
  while k < gChItemC.len:
    if gChItemC[k] == i: result = result + 1
    k = k + 1

proc cacheKnownBy*(i: int): seq[string] =
  result = @[]
  var k = 0
  while k < gChKnowC.len:
    if gChKnowC[k] == i: result.add gChKnowP[k]
    k = k + 1

proc addCacheKnownBy*(i: int; personId: string) =
  if i < 0 or i >= gChId.len or personId.len == 0: return
  var k = 0
  while k < gChKnowC.len:
    if gChKnowC[k] == i and gChKnowP[k] == personId: return
    k = k + 1
  gChKnowC.add i
  gChKnowP.add personId

proc cachesOnMap*(map: string): seq[int] =
  result = @[]
  var i = 0
  while i < gChId.len:
    if map.len == 0 or gChMap[i] == map: result.add i
    i = i + 1

proc cachesNear*(map: string; x, y, z, radius: float): seq[int] =
  result = @[]
  let r2 = radius * radius
  var i = 0
  while i < gChId.len:
    if gChMap[i] == map:
      let dx = gChX[i] - x
      let dy = gChY[i] - y
      let dz = gChZ[i] - z
      if dx*dx + dy*dy + dz*dz <= r2: result.add i
    i = i + 1

# ---------------------------------------------------------------------------
# loose loot
# ---------------------------------------------------------------------------

proc lootCount*(): int = gLtId.len

proc findLoot*(id: string): int =
  result = -1
  var i = 0
  while i < gLtId.len:
    if gLtId[i] == id: return i
    i = i + 1

proc addLoot*(id, cacheId, tpl, map: string; count: int; x, y, z: float): int =
  let seen = findLoot(id)
  if seen >= 0: return seen
  gLtId.add id
  gLtCache.add cacheId
  gLtTpl.add tpl
  gLtMap.add map
  gLtCount.add (if count > 0: count else: 1)
  gLtX.add quant3(x)
  gLtY.add quant3(y)
  gLtZ.add quant3(z)
  gLtStatus.add "placed"
  result = gLtId.len - 1

proc lootId*(i: int): string =
  if i < 0 or i >= gLtId.len: return ""
  result = gLtId[i]
proc lootCache*(i: int): string =
  if i < 0 or i >= gLtCache.len: return ""
  result = gLtCache[i]
proc lootTpl*(i: int): string =
  if i < 0 or i >= gLtTpl.len: return ""
  result = gLtTpl[i]
proc lootMap*(i: int): string =
  if i < 0 or i >= gLtMap.len: return ""
  result = gLtMap[i]
proc lootN*(i: int): int =
  if i < 0 or i >= gLtCount.len: return 0
  result = gLtCount[i]
proc lootStatus*(i: int): string =
  if i < 0 or i >= gLtStatus.len: return ""
  result = gLtStatus[i]

proc setLootStatus*(i: int; s: string) =
  if i < 0 or i >= gLtStatus.len: return
  if s != "placed" and s != "taken" and s != "gone": return
  gLtStatus[i] = s

proc lootPos*(i: int; x, y, z: var float) =
  if i < 0 or i >= gLtX.len:
    x = 0.0; y = 0.0; z = 0.0
    return
  x = gLtX[i]; y = gLtY[i]; z = gLtZ[i]

proc lootOnMap*(map: string): seq[int] =
  result = @[]
  var i = 0
  while i < gLtId.len:
    if map.len == 0 or gLtMap[i] == map: result.add i
    i = i + 1

proc lootOfCache*(cacheId: string): seq[int] =
  result = @[]
  if cacheId.len == 0: return
  var i = 0
  while i < gLtId.len:
    if gLtCache[i] == cacheId: result.add i
    i = i + 1

# ---------------------------------------------------------------------------
# pickup contracts -- "the guards expect a named bearer carrying a token"
# ---------------------------------------------------------------------------

proc addPickupContract*(id, cacheId, bearerId, token: string;
                        expiresMs: int64): int =
  ## kind "pickup", partyA = the cache, partyB = the bearer, terms = the token.
  ## Reusing the contract table rather than a fifth entity keeps expiry, status
  ## and the journal identical to every other promise in this world.
  result = addContract(id, "pickup", cacheId, bearerId, token,
                       "the cache changes hands", expiresMs)
  setContractStatus(result, "active")

proc pickupsAt*(cacheId: string): seq[int] =
  result = @[]
  if cacheId.len == 0: return
  var i = 0
  while i < contractCount():
    if contractKind(i) == "pickup" and contractPartyA(i) == cacheId:
      result.add i
    i = i + 1

# ---------------------------------------------------------------------------
# knowledge -- ids in, rendered prose out
# ---------------------------------------------------------------------------

proc worldHasId*(id: string): bool =
  ## Any kind. DESIGN §11 check 11 asserts over this, so it must cover every
  ## kind a `knows` entry can legitimately name -- and nothing else.
  if id.len == 0: return false
  if findPerson(id) >= 0: return true
  if findFaction(id) >= 0: return true
  if findPlace(id) >= 0: return true
  if findCache(id) >= 0: return true
  if findLoot(id) >= 0: return true
  if findContract(id) >= 0: return true
  if findQuest(id) >= 0: return true
  if findFact(id) >= 0: return true
  result = false

proc dropPersonKnows*(i: int; entityId: string): bool =
  ## Removes one knowledge row. A `seq` here cannot shrink in place, so this is
  ## a rebuild. It exists for the selfcheck's negative control: a bogus id is
  ## planted, the check must FAIL on it, and then it has to be taken back out.
  result = false
  var p: seq[int] = @[]
  var t: seq[string] = @[]
  var k = 0
  while k < gKnowP.len:
    if gKnowP[k] == i and gKnowText[k] == entityId:
      result = true
    else:
      p.add gKnowP[k]
      t.add gKnowText[k]
    k = k + 1
  gKnowP = p
  gKnowText = t

proc renderKnown*(personIdx: int; limit: int): string =
  ## One line per entity this person knows, with its ID, so a reply can name it
  ## and `resolveClaim` / the journal can find it again.
  ##
  ## An id that is not in the world is SKIPPED and counted, never rendered:
  ## the prompt must not teach a person to talk about something that does not
  ## exist. It is not silent either -- the trailing note says how many were
  ## dropped, and DESIGN §11 check 11 asserts over the RAW `knows` list so the
  ## skipping here cannot hide a generator bug.
  result = ""
  if personIdx < 0 or personIdx >= gPId.len or limit <= 0: return
  var shown = 0
  var dropped = 0
  let ids = personKnows(personIdx)
  var k = 0
  while k < ids.len:
    let id = ids[k]
    k = k + 1
    if shown >= limit: continue
    let ci = findCache(id)
    if ci >= 0:
      var guards = 0
      let grp = gChGuard[ci]
      if grp.len > 0:
        for gi in peopleOfGroup(grp):
          if personAlive(gi): guards = guards + 1
      result.add "[cache:" & id & " \"" & gChName[ci] & "\" -- " &
                 gChStatus[ci] & ", " & $guards & " guards, at " &
                 gChPlace[ci] & " on " & gChMap[ci] & "] " & gChStory[ci] & "\n"
      shown = shown + 1
      continue
    let fi = findFact(id)
    if fi >= 0:
      result.add "[fact:" & id & "] " & gFtText[fi] & "\n"
      shown = shown + 1
      continue
    let pl = findPlace(id)
    if pl >= 0:
      result.add "[place:" & id & " \"" & gPlName[pl] & "\" on " &
                 gPlMap[pl] & "]\n"
      shown = shown + 1
      continue
    let pe = findPerson(id)
    if pe >= 0:
      result.add "[person:" & id & " \"" & gPName[pe] & "\", " & gPRole[pe] &
                 " of " & gPFac[pe] & "]\n"
      shown = shown + 1
      continue
    let co = findContract(id)
    if co >= 0:
      result.add "[contract:" & id & " " & gCKind[co] & "] " & gCTerms[co] & "\n"
      shown = shown + 1
      continue
    dropped = dropped + 1
  if dropped > 0:
    result.add "(" & $dropped & " thing(s) this person supposedly knows are " &
               "not in the world and were left out)\n"

# ---------------------------------------------------------------------------
# objectives
#
# Two rules, both so that a check CAN fail:
#
# * `activeObjectiveOf` answers over the FINISHED STATE (a row whose status is
#   "active"), never over a flag a planner set. An objective that was abandoned
#   without being marked stays visible as a row with its own status.
# * `objectiveTaken` is what enforces "no two groups of one faction chase the
#   identical target": it asks the TABLE, so a planner that forgets to record
#   its choice cannot satisfy it by accident.
# ---------------------------------------------------------------------------

proc objectiveCount*(): int = gObId.len

proc findObjective*(id: string): int =
  result = -1
  var i = 0
  while i < gObId.len:
    if gObId[i] == id: return i
    i = i + 1

proc addObjective*(id, ownerKind, ownerId, kind, targetKind, targetId: string;
                   priority: int; startedMs, untilMs: int64;
                   note: string): int =
  let seen = findObjective(id)
  if seen >= 0: return seen
  gObId.add id
  gObOwnerKind.add ownerKind
  gObOwner.add ownerId
  gObKind.add kind
  gObTargetKind.add targetKind
  gObTarget.add targetId
  gObPriority.add priority
  gObStarted.add startedMs
  gObUntil.add untilMs
  gObStatus.add "active"
  gObNote.add note
  result = gObId.len - 1

proc objectiveId*(i: int): string =
  if i < 0 or i >= gObId.len: return ""
  result = gObId[i]

proc objectiveOwnerKind*(i: int): string =
  if i < 0 or i >= gObOwnerKind.len: return ""
  result = gObOwnerKind[i]

proc objectiveOwner*(i: int): string =
  if i < 0 or i >= gObOwner.len: return ""
  result = gObOwner[i]

proc objectiveKind*(i: int): string =
  if i < 0 or i >= gObKind.len: return ""
  result = gObKind[i]

proc objectiveTargetKind*(i: int): string =
  if i < 0 or i >= gObTargetKind.len: return ""
  result = gObTargetKind[i]

proc objectiveTarget*(i: int): string =
  if i < 0 or i >= gObTarget.len: return ""
  result = gObTarget[i]

proc objectivePriority*(i: int): int =
  if i < 0 or i >= gObPriority.len: return 0
  result = gObPriority[i]

proc objectiveStartedMs*(i: int): int64 =
  if i < 0 or i >= gObStarted.len: return 0'i64
  result = gObStarted[i]

proc objectiveUntilMs*(i: int): int64 =
  if i < 0 or i >= gObUntil.len: return 0'i64
  result = gObUntil[i]

proc setObjectiveUntilMs*(i: int; v: int64) =
  if i >= 0 and i < gObUntil.len: gObUntil[i] = v

proc objectiveStatus*(i: int): string =
  if i < 0 or i >= gObStatus.len: return ""
  result = gObStatus[i]

proc setObjectiveStatus*(i: int; s: string) =
  if i >= 0 and i < gObStatus.len: gObStatus[i] = s

proc objectiveNote*(i: int): string =
  if i < 0 or i >= gObNote.len: return ""
  result = gObNote[i]

proc setObjectiveNote*(i: int; s: string) =
  if i >= 0 and i < gObNote.len: gObNote[i] = s

proc activeObjectiveOf*(ownerId: string): int =
  ## The highest-priority ACTIVE objective of one owner, or -1. Ties break on
  ## row order, which is creation order, which is deterministic.
  result = -1
  var best = -1
  var i = 0
  while i < gObId.len:
    if gObOwner[i] == ownerId and gObStatus[i] == "active":
      if result < 0 or gObPriority[i] > best:
        result = i
        best = gObPriority[i]
    i = i + 1

proc objectivesOf*(ownerId: string): seq[int] =
  result = @[]
  var i = 0
  while i < gObId.len:
    if gObOwner[i] == ownerId: result.add i
    i = i + 1

proc objectiveTaken*(targetKind, targetId, ownerPrefix: string): bool =
  ## Is some ACTIVE objective whose owner id starts with `ownerPrefix` already
  ## pointed at this target? A group id carries its faction as its prefix
  ## (`<faction>.<group>`); an empty prefix asks about the whole world.
  result = false
  var i = 0
  while i < gObId.len:
    if gObStatus[i] == "active" and gObTargetKind[i] == targetKind and
       gObTarget[i] == targetId:
      if ownerPrefix.len == 0 or gObOwner[i].startsWith(ownerPrefix):
        return true
    i = i + 1

proc activeObjectiveCount*(): int =
  result = 0
  var i = 0
  while i < gObStatus.len:
    if gObStatus[i] == "active": result = result + 1
    i = i + 1

# ---------------------------------------------------------------------------
# player
# ---------------------------------------------------------------------------

proc playerPos*(map: var string; x, y, z: var float) =
  map = gPlayerMap; x = gPlayerX; y = gPlayerY; z = gPlayerZ

proc setPlayerPos*(map: string; x, y, z: float) =
  gPlayerMap = map
  gPlayerX = quant3(x); gPlayerY = quant3(y); gPlayerZ = quant3(z)

proc playerHp*(): float = gPlayerHp
proc setPlayerHp*(v: float) = gPlayerHp = quant3(clampF(v, 0.0, 1.0))

# ---------------------------------------------------------------------------
# journal
# ---------------------------------------------------------------------------

proc journal*(kind, actorId, targetId, dataJson: string): int =
  let s = gJNext
  gJNext = gJNext + 1
  gJSeq.add s
  gJAt.add gClockMs
  gJKind.add kind
  gJActor.add actorId
  gJTarget.add targetId
  gJData.add dataJson
  result = s

proc journalCount*(): int = gJSeq.len

proc journalEntryJson(i: int): JsonObject =
  var o = obj()
  o.put("seq", gJSeq[i])
  o.put("atMs", int(gJAt[i]))
  o.put("kind", gJKind[i])
  o.put("actor", gJActor[i])
  o.put("target", gJTarget[i])
  o.put("data", gJData[i])
  result = o

proc journalTail*(n: int): JsonArray =
  result = arr()
  var start = gJSeq.len - n
  if start < 0: start = 0
  var i = start
  while i < gJSeq.len:
    result.add journalEntryJson(i)
    i = i + 1

# ---------------------------------------------------------------------------
# JSON per entity
# ---------------------------------------------------------------------------

proc fnum(v: float): Json = sv.raw(fmtF(v))

proc strArr(items: seq[string]): JsonArray =
  result = arr()
  for s in items: result.add s

proc factionJson*(i: int): JsonObject =
  var o = obj()
  o.put("id", gFacId[i])
  o.put("name", gFacName[i])
  o.put("creed", gFacCreed[i])
  o.put("colour", gFacColour[i])
  o.put("homeMap", gFacHome[i])
  o.put("strength", fnum(gFacStrength[i]))
  o.put("rep", gFacRep[i])
  o.put("wants", strArr(factionWants(i)))
  o.put("forbids", strArr(factionForbids(i)))
  var st = arr()
  let n = gFacId.len
  var b = 0
  while b < n:
    st.add gStance[i * n + b]
    b = b + 1
  o.put("stances", st)
  result = o

proc personJson*(i: int): JsonObject =
  var o = obj()
  o.put("id", gPId[i])
  o.put("name", gPName[i])
  o.put("faction", gPFac[i])
  o.put("role", gPRole[i])
  o.put("voice", gPVoice[i])
  o.put("map", gPMap[i])
  o.put("place", gPPlace[i])
  o.put("x", fnum(gPX[i]))
  o.put("y", fnum(gPY[i]))
  o.put("z", fnum(gPZ[i]))
  o.put("activity", gPActivity[i])
  o.put("alive", gPAlive[i] == 1)
  o.put("hp", fnum(gPHp[i]))
  o.put("mood", fnum(gPMood[i]))
  o.put("attitude", gPAtt[i])
  o.put("group", gPGroup[i])
  o.put("escorting", gPEscort[i] == 1)
  o.put("inventoryNote", gPInv[i])
  o.put("lastSeenMs", int(gPLastSeen[i]))
  o.put("objRole", personObjRole(i))
  o.put("traits", strArr(personTraits(i)))
  o.put("memory", strArr(memoryOf(i, MemoryBound).split('\n')))
  o.put("knows", strArr(personKnows(i)))
  result = o

proc placeJson*(i: int): JsonObject =
  var o = obj()
  o.put("id", gPlId[i])
  o.put("name", gPlName[i])
  o.put("map", gPlMap[i])
  o.put("kind", gPlKind[i])
  o.put("owner", gPlOwner[i])
  o.put("x", fnum(gPlX[i]))
  o.put("y", fnum(gPlY[i]))
  o.put("z", fnum(gPlZ[i]))
  o.put("danger", fnum(gPlDanger[i]))
  result = o

proc contractJson*(i: int): JsonObject =
  var o = obj()
  o.put("id", gCId[i])
  o.put("kind", gCKind[i])
  o.put("partyA", gCA[i])
  o.put("partyB", gCB[i])
  o.put("terms", gCTerms[i])
  o.put("stakes", gCStakes[i])
  o.put("status", gCStatus[i])
  o.put("expiresMs", int(gCExpires[i]))
  result = o

proc questJson*(i: int): JsonObject =
  var o = obj()
  o.put("id", gQId[i])
  o.put("giver", gQGiver[i])
  o.put("title", gQTitle[i])
  o.put("brief", gQBrief[i])
  o.put("kind", gQKind[i])
  o.put("targetRef", gQTarget[i])
  o.put("reward", gQReward[i])
  o.put("status", gQStatus[i])
  o.put("objectives", strArr(questObjectives(i)))
  result = o

proc factJson*(i: int): JsonObject =
  var o = obj()
  o.put("id", gFtId[i])
  o.put("tags", gFtTags[i])
  o.put("text", gFtText[i])
  o.put("refKind", gFtRefKind[i])
  o.put("refId", gFtRefId[i])
  o.put("origin", gFtOrigin[i])
  o.put("spreadMs", int(gFtSpread[i]))
  result = o

proc cacheJson*(i: int): JsonObject =
  var o = obj()
  o.put("id", gChId[i])
  o.put("name", gChName[i])
  o.put("place", gChPlace[i])
  o.put("map", gChMap[i])
  o.put("owner", gChOwner[i])
  o.put("guardGroup", gChGuard[i])
  o.put("story", gChStory[i])
  o.put("status", gChStatus[i])
  o.put("plantedBy", gChPlanted[i])
  o.put("x", fnum(gChX[i]))
  o.put("y", fnum(gChY[i]))
  o.put("z", fnum(gChZ[i]))
  o.put("createdMs", int(gChCreated[i]))
  var items = arr()
  let tpls = cacheItemTpls(i)
  let counts = cacheItemCounts(i)
  var k = 0
  while k < tpls.len:
    var it = obj()
    it.put("tpl", tpls[k])
    it.put("count", (if k < counts.len: counts[k] else: 1))
    items.add it
    k = k + 1
  o.put("items", items)
  o.put("knownBy", strArr(cacheKnownBy(i)))
  result = o

proc lootJson*(i: int): JsonObject =
  var o = obj()
  o.put("id", gLtId[i])
  o.put("cacheId", gLtCache[i])
  o.put("tpl", gLtTpl[i])
  o.put("map", gLtMap[i])
  o.put("count", gLtCount[i])
  o.put("x", fnum(gLtX[i]))
  o.put("y", fnum(gLtY[i]))
  o.put("z", fnum(gLtZ[i]))
  o.put("status", gLtStatus[i])
  result = o

proc objectiveJson*(i: int): JsonObject =
  var o = obj()
  o.put("id", gObId[i])
  o.put("ownerKind", gObOwnerKind[i])
  o.put("owner", gObOwner[i])
  o.put("kind", gObKind[i])
  o.put("targetKind", gObTargetKind[i])
  o.put("target", gObTarget[i])
  o.put("priority", gObPriority[i])
  o.put("startedMs", int(gObStarted[i]))
  o.put("untilMs", int(gObUntil[i]))
  o.put("status", gObStatus[i])
  o.put("note", gObNote[i])
  result = o

proc metaJson*(): JsonObject =
  var o = obj()
  o.put("schema", SchemaMeta)
  o.put("seedHex", hex64(gSeed))
  o.put("preset", gPreset)
  o.put("prompt", gPrompt)
  o.put("name", gWName)
  o.put("createdMs", int(gCreatedMs))
  o.put("clockMs", int(gClockMs))
  o.put("day", gDay)
  o.put("weather", gWeather)
  o.put("version", gVersion)
  o.put("journalNext", gJNext)
  o.put("playerMap", gPlayerMap)
  o.put("playerX", fnum(gPlayerX))
  o.put("playerY", fnum(gPlayerY))
  o.put("playerZ", fnum(gPlayerZ))
  o.put("playerHp", fnum(gPlayerHp))
  result = o

# ---------------------------------------------------------------------------
# whole-kind documents
# ---------------------------------------------------------------------------

proc kindDoc(schema: string; items: JsonArray): JsonObject =
  var o = obj()
  o.put("schema", schema)
  o.put("items", items)
  result = o

proc kindJsonText*(kind: string): string =
  ## The exact document `saveWorld` writes for one kind. The byte-identity
  ## check compares THIS before a save with THIS after a load; it never
  ## compares a value with the value we just assigned.
  if kind == "meta":
    return done(metaJson()).text
  var items = arr()
  var schema = ""
  var i = 0
  if kind == "factions":
    schema = SchemaFactions
    while i < gFacId.len:
      items.add factionJson(i)
      i = i + 1
  elif kind == "people":
    schema = SchemaPeople
    while i < gPId.len:
      items.add personJson(i)
      i = i + 1
  elif kind == "places":
    schema = SchemaPlaces
    while i < gPlId.len:
      items.add placeJson(i)
      i = i + 1
  elif kind == "contracts":
    schema = SchemaContracts
    while i < gCId.len:
      items.add contractJson(i)
      i = i + 1
  elif kind == "quests":
    schema = SchemaQuests
    while i < gQId.len:
      items.add questJson(i)
      i = i + 1
  elif kind == "facts":
    schema = SchemaFacts
    while i < gFtId.len:
      items.add factJson(i)
      i = i + 1
  elif kind == "caches":
    schema = SchemaCaches
    while i < gChId.len:
      items.add cacheJson(i)
      i = i + 1
  elif kind == "loot":
    schema = SchemaLoot
    while i < gLtId.len:
      items.add lootJson(i)
      i = i + 1
  elif kind == "objectives":
    schema = SchemaObjectives
    while i < gObId.len:
      items.add objectiveJson(i)
      i = i + 1
  elif kind == "journal":
    schema = SchemaJournal
    while i < gJSeq.len:
      items.add journalEntryJson(i)
      i = i + 1
  else:
    return ""
  result = done(kindDoc(schema, items)).text

proc worldJson*(): JsonObject =
  ## Everything, in a fixed key order. `obj()` appends, so the order here IS
  ## the order on the wire.
  var o = obj()
  o.put("meta", sv.raw(kindJsonText("meta")))
  o.put("factions", sv.raw(kindJsonText("factions")))
  o.put("people", sv.raw(kindJsonText("people")))
  o.put("places", sv.raw(kindJsonText("places")))
  o.put("contracts", sv.raw(kindJsonText("contracts")))
  o.put("quests", sv.raw(kindJsonText("quests")))
  o.put("facts", sv.raw(kindJsonText("facts")))
  o.put("caches", sv.raw(kindJsonText("caches")))
  o.put("loot", sv.raw(kindJsonText("loot")))
  o.put("objectives", sv.raw(kindJsonText("objectives")))
  o.put("journalCount", gJSeq.len)
  result = o

# ---------------------------------------------------------------------------
# loading
# ---------------------------------------------------------------------------

proc hexVal(c: char): int =
  if c >= '0' and c <= '9': return ord(c) - ord('0')
  if c >= 'a' and c <= 'f': return 10 + ord(c) - ord('a')
  if c >= 'A' and c <= 'F': return 10 + ord(c) - ord('A')
  result = -1

proc parseHex64(s: string): uint64 =
  result = 0'u64
  for ch in s:
    let v = hexVal(ch)
    if v < 0: return 0'u64
    result = result * 16'u64 + uint64(v)

proc clearKind(kind: string) =
  if kind == "factions":
    gFacId = @[]; gFacName = @[]; gFacCreed = @[]; gFacColour = @[]
    gFacHome = @[]; gFacStrength = @[]; gFacRep = @[]; gStance = @[]
    gWantFac = @[]; gWantText = @[]; gForbidFac = @[]; gForbidText = @[]
  elif kind == "people":
    gPId = @[]; gPName = @[]; gPFac = @[]; gPRole = @[]; gPVoice = @[]
    gPMap = @[]; gPPlace = @[]; gPX = @[]; gPY = @[]; gPZ = @[]
    gPActivity = @[]; gPAlive = @[]; gPHp = @[]; gPMood = @[]; gPAtt = @[]
    gPGroup = @[]; gPEscort = @[]; gPInv = @[]; gPLastSeen = @[]
    gTraitP = @[]; gTraitText = @[]; gMemP = @[]; gMemText = @[]
    gKnowP = @[]; gKnowText = @[]; gPObjRole = @[]
  elif kind == "places":
    gPlId = @[]; gPlName = @[]; gPlMap = @[]; gPlKind = @[]; gPlOwner = @[]
    gPlX = @[]; gPlY = @[]; gPlZ = @[]; gPlDanger = @[]
  elif kind == "contracts":
    gCId = @[]; gCKind = @[]; gCA = @[]; gCB = @[]; gCTerms = @[]
    gCStakes = @[]; gCStatus = @[]; gCExpires = @[]
  elif kind == "quests":
    gQId = @[]; gQGiver = @[]; gQTitle = @[]; gQBrief = @[]; gQKind = @[]
    gQTarget = @[]; gQReward = @[]; gQStatus = @[]; gObjQ = @[]; gObjText = @[]
  elif kind == "facts":
    gFtId = @[]; gFtTags = @[]; gFtText = @[]
    gFtRefKind = @[]; gFtRefId = @[]; gFtOrigin = @[]; gFtSpread = @[]
  elif kind == "caches":
    gChId = @[]; gChName = @[]; gChPlace = @[]; gChMap = @[]; gChOwner = @[]
    gChGuard = @[]; gChStory = @[]; gChStatus = @[]; gChPlanted = @[]
    gChX = @[]; gChY = @[]; gChZ = @[]; gChCreated = @[]
    gChItemC = @[]; gChItemTpl = @[]; gChItemN = @[]
    gChKnowC = @[]; gChKnowP = @[]
  elif kind == "loot":
    gLtId = @[]; gLtCache = @[]; gLtTpl = @[]; gLtMap = @[]; gLtCount = @[]
    gLtX = @[]; gLtY = @[]; gLtZ = @[]; gLtStatus = @[]
  elif kind == "objectives":
    gObId = @[]; gObOwnerKind = @[]; gObOwner = @[]; gObKind = @[]
    gObTargetKind = @[]; gObTarget = @[]; gObPriority = @[]
    gObStarted = @[]; gObUntil = @[]; gObStatus = @[]; gObNote = @[]
  elif kind == "journal":
    gJSeq = @[]; gJAt = @[]; gJKind = @[]; gJActor = @[]; gJTarget = @[]
    gJData = @[]

proc schemaFor(kind: string): string =
  if kind == "meta": return SchemaMeta
  if kind == "factions": return SchemaFactions
  if kind == "people": return SchemaPeople
  if kind == "places": return SchemaPlaces
  if kind == "contracts": return SchemaContracts
  if kind == "quests": return SchemaQuests
  if kind == "facts": return SchemaFacts
  if kind == "caches": return SchemaCaches
  if kind == "loot": return SchemaLoot
  if kind == "objectives": return SchemaObjectives
  if kind == "journal": return SchemaJournal
  result = ""

proc textsOf(j: JsonRef): seq[string] =
  result = @[]
  for e in jr.each(j):
    let t = jr.asText(e, "")
    if t.len > 0: result.add t

proc loadKindFromJson*(kind, text: string; note: var string): bool =
  ## Replace one kind from a document. On ANY structural doubt the kind is left
  ## EMPTY and `note` names the store key -- there is no partial load, because
  ## half a table reads exactly like a small world.
  let want = schemaFor(kind)
  if want.len == 0:
    note = "world." & kind & ": unknown kind"
    return false
  clearKind(kind)
  if text.len == 0:
    note = "world." & kind & ": empty document"
    return false
  let root = jr.whole(text)
  if not jr.exists(root) or not jr.isObject(root):
    note = "world." & kind & ": not a JSON object -- kind left empty"
    return false
  let sch = jr.asText(jr.child(root, "schema"), "")
  if sch != want:
    note = "world." & kind & ": schema is \"" & sch & "\", expected \"" &
           want & "\" -- kind left empty"
    return false
  if kind == "meta":
    gSeed = parseHex64(jr.asText(jr.child(root, "seedHex"), ""))
    gPreset = jr.asText(jr.child(root, "preset"), "")
    gPrompt = jr.asText(jr.child(root, "prompt"), "")
    gWName = jr.asText(jr.child(root, "name"), "")
    gCreatedMs = int64(jr.asInt(jr.child(root, "createdMs"), 0))
    gClockMs = int64(jr.asInt(jr.child(root, "clockMs"), 0))
    gDay = jr.asInt(jr.child(root, "day"), 1)
    gWeather = jr.asText(jr.child(root, "weather"), "")
    gVersion = jr.asInt(jr.child(root, "version"), 0)
    gJNext = jr.asInt(jr.child(root, "journalNext"), 1)
    gPlayerMap = jr.asText(jr.child(root, "playerMap"), "")
    gPlayerX = quant3(jr.asFloat(jr.child(root, "playerX"), 0.0))
    gPlayerY = quant3(jr.asFloat(jr.child(root, "playerY"), 0.0))
    gPlayerZ = quant3(jr.asFloat(jr.child(root, "playerZ"), 0.0))
    gPlayerHp = quant3(jr.asFloat(jr.child(root, "playerHp"), 1.0))
    gHasWorld = true
    note = "world.meta: version " & $gVersion
    return true
  let itemsRef = jr.child(root, "items")
  if not jr.exists(itemsRef) or not jr.isArray(itemsRef):
    note = "world." & kind & ": \"items\" is missing or not an array -- " &
           "kind left empty"
    return false
  let items = jr.each(itemsRef)
  var n = 0
  # Stances are applied only after every faction exists, so an out-of-order
  # document cannot silently drop half the diplomacy.
  var stanceRows: seq[string] = @[]
  for it in items:
    if kind == "factions":
      let i = addFaction(jr.asText(jr.child(it, "id"), ""),
                         jr.asText(jr.child(it, "name"), ""),
                         jr.asText(jr.child(it, "creed"), ""),
                         jr.asText(jr.child(it, "colour"), ""),
                         jr.asText(jr.child(it, "homeMap"), ""),
                         jr.asFloat(jr.child(it, "strength"), 0.0))
      setFactionRep(i, jr.asInt(jr.child(it, "rep"), 0))
      for w in textsOf(jr.child(it, "wants")): addFactionWant(i, w)
      for w in textsOf(jr.child(it, "forbids")): addFactionForbid(i, w)
      var row = ""
      for s in textsOf(jr.child(it, "stances")):
        if row.len > 0: row.add " "
        row.add s
      stanceRows.add row
    elif kind == "people":
      let i = addPerson(jr.asText(jr.child(it, "id"), ""),
                        jr.asText(jr.child(it, "name"), ""),
                        jr.asText(jr.child(it, "faction"), ""),
                        jr.asText(jr.child(it, "role"), ""),
                        jr.asText(jr.child(it, "voice"), ""),
                        jr.asText(jr.child(it, "map"), ""),
                        jr.asText(jr.child(it, "place"), ""),
                        jr.asFloat(jr.child(it, "x"), 0.0),
                        jr.asFloat(jr.child(it, "y"), 0.0),
                        jr.asFloat(jr.child(it, "z"), 0.0),
                        textsOf(jr.child(it, "traits")))
      setPersonActivity(i, jr.asText(jr.child(it, "activity"), "idle"))
      setPersonAlive(i, jr.asBool(jr.child(it, "alive"), true))
      setPersonHp(i, jr.asFloat(jr.child(it, "hp"), 1.0))
      setPersonMood(i, jr.asFloat(jr.child(it, "mood"), 0.0))
      setPersonAttitude(i, jr.asInt(jr.child(it, "attitude"), 0))
      setPersonGroup(i, jr.asText(jr.child(it, "group"), ""))
      setPersonEscorting(i, jr.asBool(jr.child(it, "escorting"), false))
      setPersonInventoryNote(i, jr.asText(jr.child(it, "inventoryNote"), ""))
      setPersonLastSeenMs(i, int64(jr.asInt(jr.child(it, "lastSeenMs"), 0)))
      setPersonObjRole(i, jr.asText(jr.child(it, "objRole"), ""))
      for m in textsOf(jr.child(it, "memory")): remember(i, m)
      for k in textsOf(jr.child(it, "knows")): addPersonKnows(i, k)
    elif kind == "places":
      discard addPlace(jr.asText(jr.child(it, "id"), ""),
                       jr.asText(jr.child(it, "name"), ""),
                       jr.asText(jr.child(it, "map"), ""),
                       jr.asText(jr.child(it, "kind"), ""),
                       jr.asText(jr.child(it, "owner"), ""),
                       jr.asFloat(jr.child(it, "x"), 0.0),
                       jr.asFloat(jr.child(it, "y"), 0.0),
                       jr.asFloat(jr.child(it, "z"), 0.0),
                       jr.asFloat(jr.child(it, "danger"), 0.0))
    elif kind == "contracts":
      let i = addContract(jr.asText(jr.child(it, "id"), ""),
                          jr.asText(jr.child(it, "kind"), ""),
                          jr.asText(jr.child(it, "partyA"), ""),
                          jr.asText(jr.child(it, "partyB"), ""),
                          jr.asText(jr.child(it, "terms"), ""),
                          jr.asText(jr.child(it, "stakes"), ""),
                          int64(jr.asInt(jr.child(it, "expiresMs"), 0)))
      setContractStatus(i, jr.asText(jr.child(it, "status"), "offered"))
    elif kind == "quests":
      let i = addQuest(jr.asText(jr.child(it, "id"), ""),
                       jr.asText(jr.child(it, "giver"), ""),
                       jr.asText(jr.child(it, "title"), ""),
                       jr.asText(jr.child(it, "brief"), ""),
                       jr.asText(jr.child(it, "kind"), ""),
                       jr.asText(jr.child(it, "targetRef"), ""),
                       jr.asText(jr.child(it, "reward"), ""),
                       textsOf(jr.child(it, "objectives")))
      setQuestStatus(i, jr.asText(jr.child(it, "status"), "offered"))
    elif kind == "facts":
      addFactRef(jr.asText(jr.child(it, "id"), ""),
                 jr.asText(jr.child(it, "tags"), ""),
                 jr.asText(jr.child(it, "text"), ""),
                 jr.asText(jr.child(it, "refKind"), ""),
                 jr.asText(jr.child(it, "refId"), ""),
                 jr.asText(jr.child(it, "origin"), "gen"))
      let fi = findFact(jr.asText(jr.child(it, "id"), ""))
      if fi >= 0: gFtSpread[fi] = int64(jr.asInt(jr.child(it, "spreadMs"), 0))
    elif kind == "caches":
      let ci = addCache(jr.asText(jr.child(it, "id"), ""),
                        jr.asText(jr.child(it, "name"), ""),
                        jr.asText(jr.child(it, "place"), ""),
                        jr.asText(jr.child(it, "map"), ""),
                        jr.asText(jr.child(it, "owner"), ""),
                        jr.asText(jr.child(it, "guardGroup"), ""),
                        jr.asText(jr.child(it, "story"), ""),
                        jr.asText(jr.child(it, "plantedBy"), ""),
                        jr.asFloat(jr.child(it, "x"), 0.0),
                        jr.asFloat(jr.child(it, "y"), 0.0),
                        jr.asFloat(jr.child(it, "z"), 0.0))
      setCacheStatus(ci, jr.asText(jr.child(it, "status"), "rumoured"))
      if ci >= 0 and ci < gChCreated.len:
        gChCreated[ci] = int64(jr.asInt(jr.child(it, "createdMs"), 0))
      for e in jr.each(jr.child(it, "items")):
        cacheAddItem(ci, jr.asText(jr.child(e, "tpl"), ""),
                     jr.asInt(jr.child(e, "count"), 1))
      for who in textsOf(jr.child(it, "knownBy")): addCacheKnownBy(ci, who)
    elif kind == "loot":
      let li = addLoot(jr.asText(jr.child(it, "id"), ""),
                       jr.asText(jr.child(it, "cacheId"), ""),
                       jr.asText(jr.child(it, "tpl"), ""),
                       jr.asText(jr.child(it, "map"), ""),
                       jr.asInt(jr.child(it, "count"), 1),
                       jr.asFloat(jr.child(it, "x"), 0.0),
                       jr.asFloat(jr.child(it, "y"), 0.0),
                       jr.asFloat(jr.child(it, "z"), 0.0))
      setLootStatus(li, jr.asText(jr.child(it, "status"), "placed"))
    elif kind == "objectives":
      let oi = addObjective(jr.asText(jr.child(it, "id"), ""),
                            jr.asText(jr.child(it, "ownerKind"), "group"),
                            jr.asText(jr.child(it, "owner"), ""),
                            jr.asText(jr.child(it, "kind"), ""),
                            jr.asText(jr.child(it, "targetKind"), ""),
                            jr.asText(jr.child(it, "target"), ""),
                            jr.asInt(jr.child(it, "priority"), 0),
                            int64(jr.asInt(jr.child(it, "startedMs"), 0)),
                            int64(jr.asInt(jr.child(it, "untilMs"), 0)),
                            jr.asText(jr.child(it, "note"), ""))
      setObjectiveStatus(oi, jr.asText(jr.child(it, "status"), "active"))
    elif kind == "journal":
      gJSeq.add jr.asInt(jr.child(it, "seq"), 0)
      gJAt.add int64(jr.asInt(jr.child(it, "atMs"), 0))
      gJKind.add jr.asText(jr.child(it, "kind"), "")
      gJActor.add jr.asText(jr.child(it, "actor"), "")
      gJTarget.add jr.asText(jr.child(it, "target"), "")
      gJData.add jr.asText(jr.child(it, "data"), "")
    n = n + 1
  if kind == "factions":
    var a = 0
    while a < stanceRows.len and a < gFacId.len:
      var b = 0
      for s in stanceRows[a].split(' '):
        if b < gFacId.len and s.len > 0: setStance(a, b, s)
        b = b + 1
      a = a + 1
  note = "world." & kind & ": " & $n & " loaded"
  result = true

# ---------------------------------------------------------------------------
# persistence
# ---------------------------------------------------------------------------

proc journalChunkText(chunk: int): string =
  var items = arr()
  var i = chunk * JournalChunk
  let stop = i + JournalChunk
  while i < gJSeq.len and i < stop:
    items.add journalEntryJson(i)
    i = i + 1
  result = done(kindDoc(SchemaJournal, items)).text

proc journalChunkCount(): int =
  if gJSeq.len == 0: return 0
  result = (gJSeq.len + JournalChunk - 1) div JournalChunk

proc saveWorld*(note: var string): bool =
  if not gHasWorld:
    note = "no world to save"
    return false
  gVersion = gVersion + 1
  var written: seq[string] = @[]
  var failed: seq[string] = @[]
  # meta LAST, so a torn process leaves a version number that is behind the
  # kinds rather than ahead of them; a load then re-reads a consistent set.
  let kinds: seq[string] = @["factions", "people", "places", "contracts", "quests", "facts",
                          "caches", "loot", "objectives"]
  for k in kinds:
    if save("world." & k, kindJsonText(k)) == Ok: written.add "world." & k
    else: failed.add "world." & k
  var c = 0
  let chunks = journalChunkCount()
  while c < chunks:
    let key = "world.journal." & $c
    if save(key, journalChunkText(c)) == Ok: written.add key
    else: failed.add key
    c = c + 1
  # A shrinking journal would otherwise leave a stale trailing chunk that the
  # next load would read as real events.
  discard save("world.journalChunks", $chunks)
  if save("world.meta", kindJsonText("meta")) == Ok: written.add "world.meta"
  else: failed.add "world.meta"
  note = $written.len & " keys written (version " & $gVersion & ")"
  if failed.len > 0:
    note.add "; FAILED: "
    var i = 0
    while i < failed.len:
      if i > 0: note.add ", "
      note.add failed[i]
      i = i + 1
  result = failed.len == 0

proc loadWorld*(note: var string): bool =
  let meta = load("world.meta")
  if not meta.ok:
    if meta.missing: note = "no world saved yet (world.meta absent)"
    else: note = "world.meta is present but UNREADABLE: " & meta.error &
                 " -- refusing to start a new world over it"
    return false
  let priorVersion = gVersion
  resetWorld()
  var notes: seq[string] = @[]
  var n = ""
  if not loadKindFromJson("meta", meta.raw, n): notes.add n
  let kinds: seq[string] = @["factions", "people", "places", "contracts", "quests", "facts",
                          "caches", "loot", "objectives"]
  for k in kinds:
    let st = load("world." & k)
    if st.ok:
      if not loadKindFromJson(k, st.raw, n): notes.add n
    elif not st.missing:
      notes.add "world." & k & " is present but UNREADABLE: " & st.error
  # journal chunks
  let chunkSt = load("world.journalChunks")
  var chunks = 0
  if chunkSt.ok:
    for ch in chunkSt.raw:
      if ch >= '0' and ch <= '9': chunks = chunks * 10 + (ord(ch) - ord('0'))
  var c = 0
  clearKind("journal")
  while c < chunks:
    let st = load("world.journal." & $c)
    if st.ok:
      var cn = ""
      let root = jr.whole(st.raw)
      if jr.exists(root) and
         jr.asText(jr.child(root, "schema"), "") == SchemaJournal:
        for it in jr.each(jr.child(root, "items")):
          gJSeq.add jr.asInt(jr.child(it, "seq"), 0)
          gJAt.add int64(jr.asInt(jr.child(it, "atMs"), 0))
          gJKind.add jr.asText(jr.child(it, "kind"), "")
          gJActor.add jr.asText(jr.child(it, "actor"), "")
          gJTarget.add jr.asText(jr.child(it, "target"), "")
          gJData.add jr.asText(jr.child(it, "data"), "")
      else:
        cn = "world.journal." & $c & ": unreadable chunk -- events dropped"
        notes.add cn
    c = c + 1
  if priorVersion > 0 and gVersion < priorVersion:
    notes.add "WARNING: loaded version " & $gVersion &
              " is OLDER than the version this process last saved (" &
              $priorVersion & ") -- the store may have rolled back"
  note = "loaded version " & $gVersion & ", " & $gFacId.len & " factions, " &
         $gPId.len & " people, " & $gPlId.len & " places, " &
         $gChId.len & " caches, " & $gLtId.len & " loot rows, " &
         $gJSeq.len & " journal events"
  if notes.len > 0:
    note.add " | problems: "
    var i = 0
    while i < notes.len:
      if i > 0: note.add " ; "
      note.add notes[i]
      i = i + 1
  result = true
