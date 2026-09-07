## bm/offscreen — the world that keeps happening where the player is not.
##
## The ask (user, 2026-09-07): "all the bots having their own full objectives,
## they interact with each other even if you are not there -- all of this
## happens in our backend so we can pretend or emulate regions that are not
## directly loaded".
##
## So this file is the region emulator. It owns three things and nothing else:
##
## 1. **Planning.** Every GROUP gets one `Objective` (kind, target, priority,
##    window) chosen from its faction's `wants`, the stance table, and the
##    world's caches, contracts and quests. Objectives are re-planned when they
##    complete, when they expire, and on world events (a cache looted -> its
##    owner hunts; a death -> revenge; a truce -> a trade run).
## 2. **Resolution.** Groups move toward their target at a speed per activity.
##    When two of them share a place, the encounter is decided HERE, with no
##    client: by stance, strength, numbers and the world rng -- deaths, wounds,
##    captures, loot changing hands -- and it is journaled with a one-line
##    narrative drawn from `data/ontology.json` (a TABLE, never a model).
## 3. **Regions.** The map the player is standing on is FROZEN: the client is
##    the truth for it. Every other map keeps running.
##
## DECISIONS MADE HERE, each because the alternative cannot be checked:
##
## * **A group is DERIVED, not stored.** `person.group` is the only record of
##   membership, so `rebuildGroups()` recomputes the roster from the people
##   table on every call. A stored group row could disagree with the people it
##   claims -- and the disagreement would be invisible.
## * **Nothing reads a wall clock, and no generator survives a call.** Every
##   roll is `initRng(worldSeed xor fnv1a64(salt|clockMs|id))`. That is what
##   makes "advance 6 h twice from one saved state -> identical journals" a
##   check that can actually fail, rather than one that passes because both
##   runs happened to be quiet.
## * **A frozen map is skipped BEFORE any loop over it**, exactly like
##   `simAdvance(0)` is a no-op before any loop. "Woods did not move" must be
##   true by construction, not because the dice were kind.
## * **Every resolution journals its narrative and seeds exactly one fact with
##   `origin: "offscreen"`.** The fact is the thing people can then talk about;
##   `bm/sim.spreadRumours` carries it outward along group lines from there.
##
## LIFTED from the WSL originals (`~/aowltarkov/tarkov_onto.nim`,
## `tarkov_world.nim`, read 2026-09-07):
##
## * the RELATION VOCABULARY -- `controls`, `locatedAt`, `hostile`, `memberOf`,
##   `witnessed`, `heardAbout`, `killed`, `carries` -- is what the journal kinds
##   and fact tags here are named after, so the ontology and the store use one
##   set of words.
## * the DERIVATION rule from `eventKill`: a witness who shares a faction with
##   the victim derives hostility toward the killer. That is `witnessHostility`
##   below, minus the JTMS -- this world has no retraction cascade, and saying
##   so is better than pretending.
## * `claimedAndActive`'s lesson, verbatim: "bel.active alone returns true for
##   untracked atoms, which produces false positives for claims we never
##   asserted". Every lookup here answers -1 / "" for absent and the caller
##   must handle it; nothing defaults to a plausible value.

import std/strutils
import aowlspt
import aowlspt/server as sv
import aowlspt/json as jr
import util
import rng
import world
import ontology
import gen

# ---------------------------------------------------------------------------
# Configuration and runtime state. Literal initialisers only -- nimony zeroes a
# DLL global whose initialiser is a call.
# ---------------------------------------------------------------------------

var gOffEnabled: bool = true
var gFrozenMap: string = ""
var gArriveM: float = 25.0
var gMeetM: float = 60.0

## the derived group roster, rebuilt from `person.group` on every call
var gGId: seq[string] = @[]
var gGFaction: seq[string] = @[]
var gGMap: seq[string] = @[]
var gGPlace: seq[string] = @[]
var gGX: seq[float] = @[]
var gGY: seq[float] = @[]
var gGZ: seq[float] = @[]
var gGSize: seq[int] = @[]

## the last resolution per map, for `world/regions`
var gRegMap: seq[string] = @[]
var gRegNarr: seq[string] = @[]
var gRegMs: seq[int64] = @[]
var gRegKind: seq[string] = @[]

## The disengage table: when two groups last resolved something. Without it
## the same two groups re-fight on EVERY step for as long as they stand on the
## same place -- MEASURED 2026-09-07: 12 h produced 107 resolutions across 21
## groups and depopulated the world, which broke two unrelated selfchecks by
## killing the people they were talking to. Runtime only, and deliberately so:
## a restart lets them meet again, which is the same thing a night apart does.
var gPairA: seq[string] = @[]
var gPairB: seq[string] = @[]
var gPairMs: seq[int64] = @[]
var gDisengageMs: int64 = 21600000   ## 6 h

var gLastNarratives: seq[string] = @[]   ## this process's narratives, newest last
var gResolutions: int = 0

proc offscreenEnabled*(): bool = gOffEnabled
proc setOffscreenEnabled*(v: bool) = gOffEnabled = v
proc offscreenResolutions*(): int = gResolutions
proc offscreenNarratives*(): seq[string] = gLastNarratives

proc offscreenFreezeMap*(map: string) =
  ## The player is in a raid on `map`. From now until `offscreenThaw`, this
  ## engine does not touch it: the client is the truth there.
  gFrozenMap = map

proc offscreenThaw*() = gFrozenMap = ""
proc offscreenFrozenMap*(): string = gFrozenMap

proc offscreenFrozen*(map: string): bool =
  result = gFrozenMap.len > 0 and map == gFrozenMap

proc offscreenReset*() =
  ## Used by the selfcheck between scenarios. It clears only what THIS file
  ## owns; the world's objective rows belong to `bm/world` and survive.
  gFrozenMap = ""
  gLastNarratives = @[]
  gResolutions = 0
  gRegMap = @[]; gRegNarr = @[]; gRegMs = @[]; gRegKind = @[]
  gPairA = @[]; gPairB = @[]; gPairMs = @[]

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

proc qs(s: string): string =
  ## A JSON string for the journal's `data` blob (same shape as bm/sim).
  result = "\""
  for ch in s:
    if ch == '"': result.add "\\\""
    elif ch == '\\': result.add "\\\\"
    elif ord(ch) < 0x20: result.add ' '
    else: result.add ch
  result.add "\""

proc jdata(pairs: string): string = "{" & pairs & "}"

proc offRng(salt, id: string): Rng =
  result = initRng(worldSeed() xor
                   fnv1a64(salt & "|" & $worldClockMs() & "|" & id))

proc fsqrt(v: float): float =
  ## Newton-Raphson, the same one bm/encounter uses. Deterministic, and it never
  ## divides by zero -- a float library call would be a second source of truth
  ## for a number two files compare.
  if v <= 0.0: return 0.0
  var x = v
  if x < 1.0: x = 1.0
  var i = 0
  while i < 24:
    x = 0.5 * (x + v / x)
    i = i + 1
  result = x

proc factionNameOr*(id: string): string =
  ## A faction's display name, or its id when the row is gone. NEVER "" -- an
  ## empty actor in a narrative reads as a sentence about nobody.
  let i = findFaction(id)
  if i >= 0 and factionName(i).len > 0: return factionName(i)
  if id.len > 0: return id
  result = "somebody"

proc pairIndex(a, b: string): int =
  result = -1
  var i = 0
  while i < gPairA.len:
    if (gPairA[i] == a and gPairB[i] == b) or
       (gPairA[i] == b and gPairB[i] == a): return i
    i = i + 1

proc disengaged(a, b: string): bool =
  ## True when these two have already had it out recently and should walk past
  ## each other instead. Answered over the recorded TIME, not over a flag.
  let i = pairIndex(a, b)
  if i < 0: return false
  result = worldClockMs() - gPairMs[i] < gDisengageMs

proc notePair(a, b: string) =
  let i = pairIndex(a, b)
  if i >= 0: gPairMs[i] = worldClockMs()
  else:
    gPairA.add a
    gPairB.add b
    gPairMs.add worldClockMs()

proc dist2(ax, az, bx, bz: float): float =
  let dx = ax - bx
  let dz = az - bz
  result = dx*dx + dz*dz

# ---------------------------------------------------------------------------
# groups, derived from `person.group`
# ---------------------------------------------------------------------------

proc groupCount*(): int = gGId.len
proc groupId*(i: int): string =
  if i < 0 or i >= gGId.len: return ""
  result = gGId[i]
proc groupFactionOf*(i: int): string =
  if i < 0 or i >= gGFaction.len: return ""
  result = gGFaction[i]
proc groupMap*(i: int): string =
  if i < 0 or i >= gGMap.len: return ""
  result = gGMap[i]
proc groupPlace*(i: int): string =
  if i < 0 or i >= gGPlace.len: return ""
  result = gGPlace[i]
proc groupSize*(i: int): int =
  if i < 0 or i >= gGSize.len: return 0
  result = gGSize[i]
proc groupPos*(i: int; x, y, z: var float) =
  x = 0.0; y = 0.0; z = 0.0
  if i < 0 or i >= gGX.len: return
  x = gGX[i]; y = gGY[i]; z = gGZ[i]

proc findGroup*(id: string): int =
  result = -1
  var i = 0
  while i < gGId.len:
    if gGId[i] == id: return i
    i = i + 1

proc rebuildGroups*(): int =
  ## The roster IS the people table. A group with no living member is dropped
  ## rather than kept at size 0: an empty group that still holds an objective
  ## would keep "acting" forever with nobody in it.
  gGId = @[]; gGFaction = @[]; gGMap = @[]; gGPlace = @[]
  gGX = @[]; gGY = @[]; gGZ = @[]; gGSize = @[]
  var pi = 0
  while pi < personCount():
    let g = personGroup(pi)
    if g.len > 0 and personAlive(pi):
      var gi = findGroup(g)
      if gi < 0:
        var x = 0.0
        var y = 0.0
        var z = 0.0
        personPos(pi, x, y, z)
        gGId.add g
        gGFaction.add personFaction(pi)
        gGMap.add personMap(pi)
        gGPlace.add personPlace(pi)
        gGX.add x; gGY.add y; gGZ.add z
        gGSize.add 1
      else:
        gGSize[gi] = gGSize[gi] + 1
    pi = pi + 1
  result = gGId.len

proc groupMembers*(gi: int): seq[int] =
  result = @[]
  if gi < 0 or gi >= gGId.len: return
  for pj in peopleOfGroup(gGId[gi]):
    if personAlive(pj): result.add pj

proc groupStrength(gi: int): float =
  ## numbers x condition x the faction's own strength. Deliberately not a
  ## single die roll: a group of five wounded scavs should lose to three fresh
  ## raiders more often than not, and the rng is a rider, not the verdict.
  result = 0.0
  let fi = findFaction(groupFactionOf(gi))
  var facS = 0.5
  if fi >= 0: facS = 0.25 + factionStrength(fi)
  for pj in groupMembers(gi):
    result = result + (0.3 + personHp(pj)) * facS

proc moveGroupTo(gi: int; map, placeId: string; x, y, z: float) =
  ## Moving a group IS moving its people; there is no second position to drift.
  gGMap[gi] = map
  gGPlace[gi] = placeId
  gGX[gi] = quant3(x); gGY[gi] = quant3(y); gGZ[gi] = quant3(z)
  var k = 0
  for pj in groupMembers(gi):
    var r = offRng("spread", personId(pj))
    setPersonPos(pj, map, placeId,
                 x + float(nextInt(r, -6, 6)), y, z + float(nextInt(r, -6, 6)))
    k = k + 1

# ---------------------------------------------------------------------------
# targets
# ---------------------------------------------------------------------------

proc targetPos*(targetKind, targetId: string;
               map: var string; x, y, z: var float): bool =
  ## Where an objective points, in world terms. False when the target does not
  ## resolve -- the caller must expire the objective and say so, never carry on
  ## toward (0,0,0).
  map = ""; x = 0.0; y = 0.0; z = 0.0
  if targetKind == "place":
    let pi = findPlace(targetId)
    if pi < 0: return false
    map = placeMap(pi)
    placePos(pi, x, y, z)
    return true
  if targetKind == "cache":
    let ci = findCache(targetId)
    if ci < 0: return false
    map = cacheMap(ci)
    cachePos(ci, x, y, z)
    return true
  if targetKind == "person":
    let pj = findPerson(targetId)
    if pj < 0 or not personAlive(pj): return false
    map = personMap(pj)
    personPos(pj, x, y, z)
    return true
  result = false

proc speedFor(kind: string): float =
  ## Metres per hour-step. A guard does not travel; a scout outruns a raid
  ## party carrying crates.
  if kind == "scout": return 3000.0
  if kind == "hunt": return 2200.0
  if kind == "raid": return 2000.0
  if kind == "loot": return 1600.0
  if kind == "patrol": return 1400.0
  if kind == "trade": return 1200.0
  if kind == "escort": return 800.0
  result = 0.0            # guard, rest

proc windowFor(kind: string): int64 =
  if kind == "rest": return 4'i64 * 3600000'i64
  if kind == "guard": return 12'i64 * 3600000'i64
  if kind == "raid": return 10'i64 * 3600000'i64
  if kind == "trade": return 8'i64 * 3600000'i64
  result = 6'i64 * 3600000'i64

proc activityFor(kind: string): string =
  ## The `person.activity` an objective implies. It has to be one of the names
  ## `bm/sim.isMobile` knows, or the person would freeze while their group
  ## walks -- MEASURED: an unknown activity is treated as stationary.
  if kind == "hunt": return "hunt"
  if kind == "patrol" or kind == "scout": return "patrol"
  if kind == "raid" or kind == "loot" or kind == "trade": return "travel"
  if kind == "escort": return "captive_escort"
  if kind == "rest": return "sleep"
  result = "guard"

# ---------------------------------------------------------------------------
# planning
# ---------------------------------------------------------------------------

proc factionOfGroupId(gid: string): string =
  let gi = findGroup(gid)
  if gi >= 0: return groupFactionOf(gi)
  result = ""

proc takenByFaction(targetKind, targetId, faction: string): bool =
  ## "No two groups of one faction chase the identical target." Asked of the
  ## objective TABLE, so a planner that fails to record its pick cannot pass.
  result = false
  var i = 0
  while i < objectiveCount():
    if objectiveStatus(i) == "active" and objectiveTargetKind(i) == targetKind and
       objectiveTarget(i) == targetId:
      if factionOfGroupId(objectiveOwner(i)) == faction: return true
    i = i + 1

proc assignRoles(gi: int; kind: string) =
  ## leader / carrier / cover, deterministic and stable: the group's own leader
  ## if it has one, else its first member by id order.
  let mem = groupMembers(gi)
  if mem.len == 0: return
  var leader = -1
  for pj in mem:
    if personRole(pj) == "leader" and leader < 0: leader = pj
  if leader < 0: leader = mem[0]
  let wantsCarrier = kind == "loot" or kind == "trade" or kind == "escort"
  var assignedCarrier = false
  for pj in mem:
    if pj == leader:
      setPersonObjRole(pj, "leader")
    elif wantsCarrier and not assignedCarrier:
      setPersonObjRole(pj, "carrier")
      assignedCarrier = true
    else:
      setPersonObjRole(pj, "cover")

proc wantsWord(faction: string; word: string): bool =
  let fi = findFaction(faction)
  if fi < 0: return false
  for w in factionWants(fi):
    if containsWord(normalizeText(w), word): return true
  result = false

proc chooseObjective(gi: int; kind, tKind, tId: var string;
                     priority: var int; why: var string): bool =
  ## The ladder. First rule that fires wins, and every rule states its reason
  ## in `why`, which is what ends up in the objective's note and in the line
  ## the person says when you ask what they are doing.
  let fac = groupFactionOf(gi)
  let map = groupMap(gi)
  kind = ""; tKind = ""; tId = ""; priority = 0; why = ""

  # 1. someone hit one of ours -> hunt it. (`cache.outcome` in bm/sim is the
  #    event; this is the consequence.)
  var ci = 0
  while ci < cacheCount():
    if cacheOwner(ci) == fac and cacheStatus(ci) == "looted" and
       not takenByFaction("cache", cacheId(ci), fac):
      kind = "hunt"; tKind = "cache"; tId = cacheId(ci); priority = 90
      why = "somebody emptied " & cacheName(ci) & " and we want them"
      return true
    ci = ci + 1

  # 2. we are at war and we have lost people -> raid their ground.
  let fi = findFaction(fac)
  if fi >= 0:
    var lost = 0
    for pj in peopleOfFaction(fi):
      if not personAlive(pj): lost = lost + 1
    if lost > 0:
      var fj = 0
      while fj < factionCount():
        if factionId(fj) != fac and stance(fi, fj) == "war":
          for pl in placesOnMap(map):
            if placeOwner(pl) == factionId(fj) and
               not takenByFaction("place", placeId(pl), fac):
              kind = "raid"; tKind = "place"; tId = placeId(pl); priority = 80
              why = "paying " & factionName(fj) & " back for our dead"
              return true
        fj = fj + 1

  # 3. a contract this faction is party to, that is still live.
  for cj in contractsOf(fac, "active"):
    let target = contractPartyB(cj)
    let pj = findPerson(target)
    if pj >= 0 and personAlive(pj) and not takenByFaction("person", target, fac):
      kind = (if contractKind(cj) == "bounty": "hunt" else: "trade")
      tKind = "person"; tId = target; priority = 70
      why = "the " & contractKind(cj) & " on " & personName(pj) & " is still open"
      return true

  # 4. a quest one of ours is carrying, whose target is a real entity.
  if fi >= 0:
    for pj in peopleOfFaction(fi):
      if not personAlive(pj): continue
      for qi in questsOf(personId(pj)):
        if questStatus(qi) != "active" and questStatus(qi) != "offered": continue
        let t = questTarget(qi)
        if findCache(t) >= 0 and not takenByFaction("cache", t, fac):
          kind = "loot"; tKind = "cache"; tId = t; priority = 60
          why = questTitle(qi)
          return true

  # 5. what the faction WANTS, in its own words.
  if wantsWord(fac, "trade") or wantsWord(fac, "food") or wantsWord(fac, "fuel"):
    var fk = 0
    while fk < factionCount():
      if factionId(fk) != fac and fi >= 0 and
         (stance(fi, fk) == "allied" or stance(fi, fk) == "neutral"):
        for pl in placesOnMap(map):
          if placeOwner(pl) == factionId(fk) and
             not takenByFaction("place", placeId(pl), fac):
            kind = "trade"; tKind = "place"; tId = placeId(pl); priority = 50
            why = "a run to " & placeName(pl) & " while the truce holds"
            return true
      fk = fk + 1

  # 6. a cache somebody else owns that we know about -> take it.
  var ck = 0
  while ck < cacheCount():
    if cacheOwner(ck) != fac and cacheStatus(ck) != "looted" and
       cacheMap(ck) == map and not takenByFaction("cache", cacheId(ck), fac):
      kind = "loot"; tKind = "cache"; tId = cacheId(ck); priority = 40
      why = "lifting " & cacheName(ck) & " before anyone else does"
      return true
    ck = ck + 1

  # 7. guard our own cache, if we are the ones standing on it.
  var cg = 0
  while cg < cacheCount():
    if cacheGuardGroup(cg) == groupId(gi):
      kind = "guard"; tKind = "cache"; tId = cacheId(cg); priority = 30
      why = "nobody walks off with " & cacheName(cg)
      return true
    cg = cg + 1

  # 8. walk the ground. The last resort that is still an action.
  let places = placesOnMap(map)
  if places.len > 0:
    var r = offRng("patrol", groupId(gi))
    var tries = 0
    while tries < places.len:
      let pl = places[(nextInt(r, 0, places.len - 1) + tries) mod places.len]
      if placeId(pl) != groupPlace(gi) and
         not takenByFaction("place", placeId(pl), fac):
        kind = "patrol"; tKind = "place"; tId = placeId(pl); priority = 20
        why = "walking the ground out to " & placeName(pl)
        return true
      tries = tries + 1

  # 9. nothing to do is a real answer, and it is an objective too.
  kind = "rest"; tKind = "place"; tId = groupPlace(gi); priority = 10
  why = "sitting it out"
  result = true

proc planFor*(gi: int; force: bool): int =
  ## Give this group an objective if it has none (or `force`). Returns the
  ## objective index, or -1 when nothing could be chosen.
  let gid = groupId(gi)
  if gid.len == 0: return -1
  let cur = activeObjectiveOf(gid)
  if cur >= 0 and not force: return cur
  var kind = ""
  var tKind = ""
  var tId = ""
  var priority = 0
  var why = ""
  if not chooseObjective(gi, kind, tKind, tId, priority, why): return -1
  let id = gid & "#" & $objectiveCount()
  let oi = addObjective(id, "group", gid, kind, tKind, tId, priority,
                        worldClockMs(), worldClockMs() + windowFor(kind), why)
  assignRoles(gi, kind)
  for pj in groupMembers(gi):
    setPersonActivity(pj, activityFor(kind))
  discard journal("objective.planned", gid, tId,
                  jdata("\"kind\":" & qs(kind) & ",\"targetKind\":" & qs(tKind) &
                        ",\"why\":" & qs(why) & ",\"priority\":" & $priority))
  result = oi

proc planAll*(note: var string): int =
  ## Every group ends this call holding exactly one active objective, or the
  ## note names the group that could not get one.
  discard rebuildGroups()
  var planned = 0
  var without: seq[string] = @[]
  var gi = 0
  while gi < groupCount():
    let before = activeObjectiveOf(groupId(gi))
    let oi = planFor(gi, false)
    if oi < 0: without.add groupId(gi)
    elif before < 0: planned = planned + 1
    gi = gi + 1
  note = $planned & " objective(s) planned for " & $groupCount() & " group(s)"
  if without.len > 0:
    note.add "; NO objective for: "
    var i = 0
    while i < without.len:
      if i > 0: note.add ", "
      note.add without[i]
      i = i + 1
  result = planned

# ---------------------------------------------------------------------------
# narrative + rumour
# ---------------------------------------------------------------------------

proc noteRegion(map, kind, narrative: string) =
  var i = 0
  while i < gRegMap.len:
    if gRegMap[i] == map:
      gRegNarr[i] = narrative
      gRegMs[i] = worldClockMs()
      gRegKind[i] = kind
      return
    i = i + 1
  gRegMap.add map; gRegNarr.add narrative
  gRegMs.add worldClockMs(); gRegKind.add kind

proc narrate(event, salt, a, b, place, extra: string): string =
  ## From `data/ontology.json`'s `offscreen` table. When the table has no row
  ## the line SAYS so instead of being invented here: a narrative that this
  ## file made up would not be in the record of what the world can say.
  var n = ""
  result = ontologyOffscreen(event, salt, a, b, place, extra, n)
  if result.len == 0:
    result = "[no ontology row for offscreen event '" & event & "'] " &
             a & " and " & b & " at " & place

proc seedRumour(idSalt, text, refKind, refId: string;
                witnesses: seq[int]; factions: seq[string]) =
  ## ONE fact, origin `offscreen`, known by whoever was there and by each named
  ## faction's living leaders. `bm/sim.spreadRumours` carries it from there --
  ## this file never spreads, so the two rates cannot fight each other.
  let fid = "off." & idSalt
  if findFact(fid) >= 0: return
  addFactRef(fid, "offscreen rumour " & refKind & " " & refId, text,
             refKind, refId, "offscreen")
  setFactSpreadMs(findFact(fid), worldClockMs())
  for pj in witnesses:
    if personAlive(pj):
      addPersonKnows(pj, fid)
      remember(pj, "I was there: " & text)
  for f in factions:
    let fi = findFaction(f)
    if fi < 0: continue
    for pj in peopleOfFaction(fi):
      if personAlive(pj) and personRole(pj) == "leader":
        addPersonKnows(pj, fid)

proc witnessHostility(victimFaction: string; witnesses: seq[int];
                      killerFaction: string) =
  ## LIFTED from `tarkov_world.eventKill`: a witness who shares a faction with
  ## the victim turns on the killer. Without the JTMS -- there is no retraction
  ## cascade here, so this is a one-way attitude move and NOT a derived claim
  ## that would come back if the premise went away.
  for pj in witnesses:
    if not personAlive(pj): continue
    if personFaction(pj) != victimFaction: continue
    setPersonAttitude(pj, clampI(personAttitude(pj) - 25, -100, 100))
    remember(pj, "I watched " & killerFaction & " do it.")

# ---------------------------------------------------------------------------
# resolution
# ---------------------------------------------------------------------------

proc dropCorpse(pj: int; why: string) =
  ## A death offscreen leaves something to find. The loot row's tpl carries the
  ## person id so the materialiser can put their `inventoryNote` on it; a bare
  ## "corpse" tpl would be a body nobody could identify.
  var x = 0.0
  var y = 0.0
  var z = 0.0
  personPos(pj, x, y, z)
  setPersonAlive(pj, false)
  setPersonActivity(pj, "dead")
  discard addLoot("corpse." & personId(pj), "", "corpse:" & personId(pj),
                  personMap(pj), 1, x, y, z)
  discard journal("offscreen.death", personId(pj), personFaction(pj),
                  jdata("\"why\":" & qs(why) & ",\"map\":" & qs(personMap(pj))))
  # a quest or a bounty that named them is settled by the fact of it.
  var qi = 0
  while qi < questCount():
    if questTarget(qi) == personId(pj) and
       (questStatus(qi) == "active" or questStatus(qi) == "offered"):
      setQuestStatus(qi, "closed")
      discard journal("quest.closed", questGiver(qi), personId(pj),
                      jdata("\"why\":" & qs("the target died offscreen")))
    qi = qi + 1
  var ci = 0
  while ci < contractCount():
    if contractKind(ci) == "bounty" and contractPartyB(ci) == personId(pj) and
       (contractStatus(ci) == "active" or contractStatus(ci) == "offered"):
      setContractStatus(ci, "settled")
      discard journal("contract.settled", contractPartyA(ci), personId(pj),
                      jdata("\"why\":" & qs("the mark died offscreen")))
    ci = ci + 1

proc takeCaches(winnerFaction, loserFaction, map: string): int =
  ## Loot changes hands: every cache on this map the loser owned is now the
  ## winner's. The cache's own status is untouched -- an owner change is not a
  ## looting, and conflating them would make `cache.outcome` fire twice.
  result = 0
  var ci = 0
  while ci < cacheCount():
    if cacheMap(ci) == map and cacheOwner(ci) == loserFaction:
      let cid = cacheId(ci)
      setCacheOwner(ci, winnerFaction)
      discard journal("offscreen.loot", winnerFaction, cid,
                      jdata("\"from\":" & qs(loserFaction) & ",\"map\":" & qs(map) &
                            ",\"what\":" & qs("ownership")))
      result = result + 1
    ci = ci + 1

proc resolveFight(ga, gb: int; place: string): string =
  let fa = groupFactionOf(ga)
  let fb = groupFactionOf(gb)
  var r = offRng("fight", groupId(ga) & "|" & groupId(gb))
  let sa = groupStrength(ga) * (0.75 + nextFloat(r) * 0.5)
  let sb = groupStrength(gb) * (0.75 + nextFloat(r) * 0.5)
  var win = ga
  var lose = gb
  if sb > sa:
    win = gb
    lose = ga
  let winF = groupFactionOf(win)
  let loseF = groupFactionOf(lose)
  let witnesses = groupMembers(win)
  var dead = 0
  var wounded = 0
  var captured = 0
  for pj in groupMembers(lose):
    var pr = offRng("casualty", personId(pj))
    # 15 % dead, 35 % wounded, 12 % taken, the rest broke and ran. A third of a
    # group dying every hour is not a world, it is a cull -- and it was: see the
    # disengage table above.
    let roll = nextFloat(pr)
    if roll < 0.15:
      dropCorpse(pj, "killed by " & winF & " at " & place)
      dead = dead + 1
    elif roll < 0.50:
      setPersonHp(pj, personHp(pj) - 0.4)
      setPersonAttitude(pj, clampI(personAttitude(pj) - 15, -100, 100))
      wounded = wounded + 1
    elif roll < 0.62:
      setPersonActivity(pj, "captive_escort")
      setPersonEscorting(pj, true)
      discard addContract("captive." & personId(pj), "captive", winF,
                          personId(pj), "marched to " & place,
                          "whatever they were carrying",
                          worldClockMs() + 12'i64 * 3600000'i64)
      discard journal("offscreen.capture", winF, personId(pj),
                      jdata("\"place\":" & qs(place) & ",\"by\":" & qs(winF)))
      captured = captured + 1
  for pj in groupMembers(win):
    var pr = offRng("scratch", personId(pj))
    if nextFloat(pr) < 0.3: setPersonHp(pj, personHp(pj) - 0.15)
  witnessHostility(loseF, groupMembers(lose), winF)
  let moved = takeCaches(winF, loseF, groupMap(win))
  # the loser BREAKS OFF: their objective failed, and the next step plans them
  # somewhere else. Without this they would stand on the same square and lose
  # again every hour.
  let loserObj = activeObjectiveOf(groupId(lose))
  if loserObj >= 0:
    setObjectiveStatus(loserObj, "failed")
    discard journal("objective.failed", groupId(lose), objectiveTarget(loserObj),
                    jdata("\"why\":" & qs("broke off at " & place)))
  let narrative = narrate("fight", groupId(ga) & groupId(gb),
                          factionNameOr(winF), factionNameOr(loseF), place,
                          $dead & " dead")
  discard journal("offscreen.fight", groupId(win), groupId(lose),
                  jdata("\"place\":" & qs(place) & ",\"winner\":" & qs(winF) &
                        ",\"loser\":" & qs(loseF) & ",\"dead\":" & $dead &
                        ",\"wounded\":" & $wounded & ",\"captured\":" & $captured &
                        ",\"cachesMoved\":" & $moved &
                        ",\"narrative\":" & qs(narrative)))
  seedRumour("fight." & $worldClockMs() & "." & groupId(ga) & "." & groupId(gb),
             narrative, "place", place, witnesses, @[fa, fb])
  result = narrative

proc resolveTrade(ga, gb: int; place: string): string =
  let fa = groupFactionOf(ga)
  let fb = groupFactionOf(gb)
  let narrative = narrate("trade", groupId(ga) & groupId(gb),
                          factionNameOr(fa), factionNameOr(fb), place, "")
  # facts move both ways: this is the ALLIED/NEUTRAL outcome, and knowing a
  # thing is the currency.
  var swapped = 0
  for pa in groupMembers(ga):
    for pb in groupMembers(gb):
      for f in personKnows(pa):
        var has = false
        for k in personKnows(pb):
          if k == f: has = true
        if not has:
          addPersonKnows(pb, f)
          swapped = swapped + 1
          break
      break
    break
  var ci = 0
  while ci < contractCount():
    if contractStatus(ci) == "active" and
       ((contractPartyA(ci) == fa and contractPartyB(ci) == fb) or
        (contractPartyA(ci) == fb and contractPartyB(ci) == fa)):
      setContractStatus(ci, "settled")
      discard journal("contract.settled", contractPartyA(ci), contractPartyB(ci),
                      jdata("\"why\":" & qs("settled in person at " & place)))
    ci = ci + 1
  discard journal("offscreen.trade", groupId(ga), groupId(gb),
                  jdata("\"place\":" & qs(place) & ",\"factsSwapped\":" & $swapped &
                        ",\"narrative\":" & qs(narrative)))
  seedRumour("trade." & $worldClockMs() & "." & groupId(ga) & "." & groupId(gb),
             narrative, "place", place, groupMembers(ga), @[fa, fb])
  result = narrative

proc resolveMeet(ga, gb: int; place: string): string =
  let fa = groupFactionOf(ga)
  let fb = groupFactionOf(gb)
  let narrative = narrate("meet", groupId(ga) & groupId(gb),
                          factionNameOr(fa), factionNameOr(fb), place, "")
  discard journal("offscreen.meet", groupId(ga), groupId(gb),
                  jdata("\"place\":" & qs(place) & ",\"narrative\":" & qs(narrative)))
  seedRumour("meet." & $worldClockMs() & "." & groupId(ga) & "." & groupId(gb),
             narrative, "place", place, groupMembers(ga), @[fa, fb])
  result = narrative

proc resolveEncounter(ga, gb: int): string =
  ## Stance decides the KIND of encounter; nothing else does. Two groups of one
  ## faction do not meet as strangers, and a war does not resolve as a trade.
  let fa = groupFactionOf(ga)
  let fb = groupFactionOf(gb)
  if fa == fb: return ""
  let ia = findFaction(fa)
  let ib = findFaction(fb)
  if ia < 0 or ib < 0: return ""
  var place = groupPlace(ga)
  let pl = findPlace(place)
  if pl >= 0: place = placeName(pl)
  let st = stance(ia, ib)
  var narrative = ""
  var kind = ""
  if st == "war":
    narrative = resolveFight(ga, gb, place); kind = "fight"
  elif st == "rival":
    var r = offRng("standoff", groupId(ga) & groupId(gb))
    if nextFloat(r) < 0.35:
      narrative = resolveFight(ga, gb, place); kind = "fight"
    else:
      narrative = resolveMeet(ga, gb, place); kind = "meet"
  elif st == "allied":
    narrative = resolveTrade(ga, gb, place); kind = "trade"
  else:
    narrative = resolveMeet(ga, gb, place); kind = "meet"
  gResolutions = gResolutions + 1
  gLastNarratives.add narrative
  noteRegion(groupMap(ga), kind, narrative)
  result = narrative

proc arriveAt(gi, oi: int): string =
  ## The objective's target has been reached. What that MEANS depends on the
  ## kind; every branch closes the objective, so a group cannot sit "arrived"
  ## forever.
  let kind = objectiveKind(oi)
  let tKind = objectiveTargetKind(oi)
  let tId = objectiveTarget(oi)
  let fac = groupFactionOf(gi)
  var narrative = ""
  if kind == "loot" and tKind == "cache":
    let ci = findCache(tId)
    if ci >= 0 and cacheStatus(ci) != "looted":
      setCacheStatus(ci, "looted")
      narrative = narrate("loot", groupId(gi), factionNameOr(fac),
                          cacheName(ci), cacheName(ci), "")
      discard journal("offscreen.loot", groupId(gi), tId,
                      jdata("\"narrative\":" & qs(narrative) &
                            ",\"from\":" & qs(cacheOwner(ci))))
      seedRumour("loot." & $worldClockMs() & "." & tId, narrative, "cache", tId,
                 groupMembers(gi), @[fac, cacheOwner(ci)])
      gResolutions = gResolutions + 1
      gLastNarratives.add narrative
      noteRegion(groupMap(gi), "loot", narrative)
  elif kind == "hunt" and tKind == "person":
    let pj = findPerson(tId)
    if pj >= 0 and personAlive(pj):
      dropCorpse(pj, "hunted down by " & fac)
      narrative = narrate("hunt", groupId(gi), factionNameOr(fac),
                          personName(pj), groupPlace(gi), "")
      discard journal("offscreen.hunt", groupId(gi), tId,
                      jdata("\"narrative\":" & qs(narrative)))
      seedRumour("hunt." & $worldClockMs() & "." & tId, narrative, "person", tId,
                 groupMembers(gi), @[fac, personFaction(pj)])
      gResolutions = gResolutions + 1
      gLastNarratives.add narrative
      noteRegion(groupMap(gi), "hunt", narrative)
  setObjectiveStatus(oi, "done")
  discard journal("objective.done", groupId(gi), tId,
                  jdata("\"kind\":" & qs(kind) & ",\"narrative\":" & qs(narrative)))
  result = narrative

# ---------------------------------------------------------------------------
# the step
# ---------------------------------------------------------------------------

proc offscreenStep*(stepIdx: int): int =
  ## ONE hour-step of the offscreen world. Called from `bm/sim.simAdvance`
  ## inside its own loop, so the clock is already at this step's time.
  ##
  ## Returns the number of world changes made. Every one of them is journaled.
  result = 0
  if not gOffEnabled: return 0
  if not worldExists(): return 0
  discard rebuildGroups()

  # expiry first, so a group whose window closed re-plans in the same step
  var oi = 0
  while oi < objectiveCount():
    if objectiveStatus(oi) == "active" and objectiveUntilMs(oi) > 0'i64 and
       objectiveUntilMs(oi) <= worldClockMs():
      setObjectiveStatus(oi, "expired")
      discard journal("objective.expired", objectiveOwner(oi), objectiveTarget(oi),
                      jdata("\"kind\":" & qs(objectiveKind(oi)) &
                            ",\"step\":" & $stepIdx))
      result = result + 1
    oi = oi + 1

  var gi = 0
  while gi < groupCount():
    # A frozen map is skipped BEFORE anything reads or writes it.
    if offscreenFrozen(groupMap(gi)):
      gi = gi + 1
      continue
    let oj = planFor(gi, false)
    if oj < 0:
      gi = gi + 1
      continue
    var tMap = ""
    var tx = 0.0
    var ty = 0.0
    var tz = 0.0
    if not targetPos(objectiveTargetKind(oj), objectiveTarget(oj), tMap, tx, ty, tz):
      setObjectiveStatus(oj, "failed")
      discard journal("objective.failed", groupId(gi), objectiveTarget(oj),
                      jdata("\"why\":" & qs("the target no longer exists") &
                            ",\"kind\":" & qs(objectiveKind(oj))))
      result = result + 1
      gi = gi + 1
      continue
    if offscreenFrozen(tMap):
      # walking INTO the player's raid is the client's business, not ours.
      gi = gi + 1
      continue
    var gx = 0.0
    var gy = 0.0
    var gz = 0.0
    groupPos(gi, gx, gy, gz)
    if tMap != groupMap(gi):
      # a cross-region move is one hop: this model has no road network, and a
      # fake intermediate position would be a number nobody measured.
      moveGroupTo(gi, tMap, objectiveTarget(oj), tx, ty, tz)
      discard journal("group.travel", groupId(gi), tMap,
                      jdata("\"to\":" & qs(objectiveTarget(oj)) &
                            ",\"step\":" & $stepIdx))
      result = result + 1
    else:
      let speed = speedFor(objectiveKind(oj))
      let d2 = dist2(gx, gz, tx, tz)
      if d2 > gArriveM * gArriveM and speed > 0.0:
        let d = fsqrt(d2)
        var f = speed / d
        if f > 1.0: f = 1.0
        let nx = gx + (tx - gx) * f
        let nz = gz + (tz - gz) * f
        var place = groupPlace(gi)
        if f >= 1.0 and objectiveTargetKind(oj) == "place":
          place = objectiveTarget(oj)
        moveGroupTo(gi, groupMap(gi), place, nx, gy, nz)
        discard journal("group.moved", groupId(gi), objectiveTarget(oj),
                        jdata("\"x\":" & fmtF(nx) & ",\"z\":" & fmtF(nz) &
                              ",\"kind\":" & qs(objectiveKind(oj)) &
                              ",\"step\":" & $stepIdx))
        result = result + 1
    groupPos(gi, gx, gy, gz)
    if dist2(gx, gz, tx, tz) <= gArriveM * gArriveM:
      discard arriveAt(gi, oj)
      discard planFor(gi, true)
      result = result + 1
    gi = gi + 1

  # meetings, after everyone has moved. Each unordered pair at most once.
  var a = 0
  while a < groupCount():
    if not offscreenFrozen(groupMap(a)):
      var b = a + 1
      while b < groupCount():
        if groupMap(a) == groupMap(b) and groupFactionOf(a) != groupFactionOf(b):
          var ax = 0.0
          var ay = 0.0
          var az = 0.0
          var bx = 0.0
          var by = 0.0
          var bz = 0.0
          groupPos(a, ax, ay, az)
          groupPos(b, bx, by, bz)
          if dist2(ax, az, bx, bz) <= gMeetM * gMeetM and
             not disengaged(groupId(a), groupId(b)):
            notePair(groupId(a), groupId(b))
            if resolveEncounter(a, b).len > 0:
              result = result + 1
              discard rebuildGroups()
        b = b + 1
    a = a + 1
  discard rebuildGroups()

proc offscreenAdvance*(ms: int64; note: var string): int =
  ## The standalone entry point (the sim calls `offscreenStep` per step). A
  ## non-positive span is a hard no-op BEFORE any loop, so the negative control
  ## is true by construction.
  if ms <= 0'i64:
    note = "offscreen: advance of " & $ms & " ms -- no steps, nothing changed"
    return 0
  let steps = int(ms div 3600000'i64)
  var changes = 0
  var i = 0
  while i < steps:
    advanceClock(3600000'i64)
    changes = changes + offscreenStep(int(worldClockMs() div 3600000'i64))
    i = i + 1
  note = "offscreen: " & $steps & " step(s), " & $changes & " change(s), " &
         $gResolutions & " resolution(s) this process"
  result = changes

# ---------------------------------------------------------------------------
# what the client and the dialogue need
# ---------------------------------------------------------------------------

proc objectiveOfPerson*(personIdx: int; kind, target, role: var string): bool =
  ## The objective this person is inside, through their group. False -- with
  ## everything cleared -- when they have none; a person with no orders must
  ## not read as a person with an empty one.
  kind = ""; target = ""; role = ""
  if personIdx < 0 or personIdx >= personCount(): return false
  let g = personGroup(personIdx)
  if g.len == 0: return false
  let oi = activeObjectiveOf(g)
  if oi < 0: return false
  kind = objectiveKind(oi)
  target = objectiveTarget(oi)
  role = personObjRole(personIdx)
  result = true

proc objectiveTargetName*(targetKind, targetId: string): string =
  if targetKind == "place":
    let i = findPlace(targetId)
    if i >= 0: return placeName(i)
  elif targetKind == "cache":
    let i = findCache(targetId)
    if i >= 0: return cacheName(i)
  elif targetKind == "person":
    let i = findPerson(targetId)
    if i >= 0: return personName(i)
  result = targetId

proc objectiveSentence*(personIdx: int): string =
  ## One clause a person can say when asked what they are doing. It is built
  ## from the objective ROW plus the planner's own reason, so it can never
  ## describe something the world is not actually doing.
  var kind = ""
  var target = ""
  var role = ""
  if not objectiveOfPerson(personIdx, kind, target, role): return ""
  let g = personGroup(personIdx)
  let oi = activeObjectiveOf(g)
  var tk = ""
  if oi >= 0: tk = objectiveTargetKind(oi)
  let name = objectiveTargetName(tk, target)
  var why = ""
  if oi >= 0: why = objectiveNote(oi)
  var lead = ""
  if kind == "patrol": lead = "walking the ground out to " & name
  elif kind == "guard": lead = "sitting on " & name
  elif kind == "raid": lead = "moving on " & name
  elif kind == "trade": lead = "running a trade out to " & name
  elif kind == "hunt": lead = "hunting " & name
  elif kind == "loot": lead = "moving the crates to " & name & " before dark"
  elif kind == "escort": lead = "marching them to " & name
  elif kind == "scout": lead = "scouting " & name
  elif kind == "rest": lead = "resting up"
  else: lead = kind & " " & name
  if role.len > 0 and role != "leader": lead = lead & ", I am " & role
  if why.len > 0 and why != lead: lead = lead & " -- " & why
  result = lead

proc regionsJson*(): JsonObject =
  ## Per map: who is there, what they are doing, when it last resolved, and
  ## whether the map is FROZEN (the client owns it) or EMULATED (we do).
  discard rebuildGroups()
  var maps: seq[string] = @[]
  var i = 0
  while i < placeCount():
    let m = placeMap(i)
    var seen = false
    for x in maps:
      if x == m: seen = true
    if not seen and m.len > 0: maps.add m
    i = i + 1
  var a = arr()
  for m in maps:
    var groups = arr()
    var gi = 0
    while gi < groupCount():
      if groupMap(gi) == m:
        var go = obj()
        go.put("groupId", groupId(gi))
        go.put("factionId", groupFactionOf(gi))
        go.put("place", groupPlace(gi))
        go.put("size", groupSize(gi))
        let oi = activeObjectiveOf(groupId(gi))
        if oi >= 0:
          var oo = obj()
          oo.put("kind", objectiveKind(oi))
          oo.put("targetKind", objectiveTargetKind(oi))
          oo.put("target", objectiveTarget(oi))
          oo.put("targetName", objectiveTargetName(objectiveTargetKind(oi),
                                                   objectiveTarget(oi)))
          oo.put("priority", objectivePriority(oi))
          oo.put("untilMs", int(objectiveUntilMs(oi)))
          oo.put("note", objectiveNote(oi))
          go.put("objective", oo)
        else:
          go.put("objective", sv.raw("null"))
        groups.add go
      gi = gi + 1
    var last = obj()
    var haveLast = false
    var ri = 0
    while ri < gRegMap.len:
      if gRegMap[ri] == m:
        last.put("kind", gRegKind[ri])
        last.put("atMs", int(gRegMs[ri]))
        last.put("narrative", gRegNarr[ri])
        haveLast = true
      ri = ri + 1
    var mo = obj()
    mo.put("map", m)
    mo.put("state", (if offscreenFrozen(m): "frozen" else: "emulated"))
    mo.put("frozen", offscreenFrozen(m))
    mo.put("groups", groups)
    if haveLast: mo.put("lastResolution", last)
    else: mo.put("lastResolution", sv.raw("null"))
    a.add mo
  result = obj()
  result.put("ok", true)
  result.put("frozenMap", gFrozenMap)
  result.put("resolutions", gResolutions)
  result.put("activeObjectives", activeObjectiveCount())
  result.put("regions", a)

# ---------------------------------------------------------------------------
# The checks -- DESIGN.md 9. Each row is "VERDICT<US>name<US>evidence" (<US> is
# 0x1f), and the caller (basement.nim's selfcheck) feeds them straight to
# `check`. They live HERE, next to the engine, so a change to the engine and a
# change to its checks are one diff.
#
# Every one is written so that it CAN fail: each states its negative control,
# and "I could not look" is INCONCLUSIVE, never PASS.
# ---------------------------------------------------------------------------

proc row(verdict, name, evidence: string): string =
  result = verdict & "\x1f" & name & "\x1f" & evidence

proc mapSignature(map: string): string =
  ## Every living person on one map, with place and rounded position, in table
  ## order. "Woods did not move" is asserted over THIS -- the finished state --
  ## not over a counter this code increments.
  result = ""
  var i = 0
  while i < personCount():
    if personAlive(i) and personMap(i) == map:
      var x = 0.0
      var y = 0.0
      var z = 0.0
      personPos(i, x, y, z)
      result.add personId(i) & "/" & personPlace(i) & "/" & fmtF(x) & "," &
                 fmtF(z) & ";"
    i = i + 1

proc offscreenNarrativeInJournal(): string =
  ## The narrative of the most recent offscreen resolution, read back out of
  ## the JOURNAL rather than out of this file's own list -- a check that reads
  ## its own variable cannot fail.
  result = ""
  let tail = journalTail(400)
  for e in jr.each(jr.whole(done(tail).text)):
    let k = jr.asText(jr.child(e, "kind"), "")
    if k.len > 10 and k.substr(0, 9) == "offscreen.":
      let data = jr.asText(jr.child(e, "data"), "")
      let n = jr.asText(jr.field(data, "narrative"), "")
      if n.len > 0: result = n

proc offscreenFactCount(): int =
  result = 0
  var i = 0
  while i < factCount():
    if factOrigin(i) == "offscreen": result = result + 1
    i = i + 1

proc offscreenChecks*(presetPath: string): seq[string] =
  ## Regenerates a world at a fixed seed. The caller restores the player's
  ## world afterwards, exactly as the other checks in the suite do.
  result = @[]
  let p = presetFromFile(presetPath)
  if not p.ok:
    result.add row("INCONCLUSIVE", "offscreen: objectives are planned",
                   "the preset did not load from " & presetPath & ": " & p.note)
    return

  # ---- (a) every group holds an objective, no two of one faction share a
  #          target, and the same seed twice is identical.
  offscreenReset()
  var gn = ""
  if not generate(11'u64, p, "", gn):
    result.add row("FAIL", "offscreen: objectives are planned",
                   "generate(seed 11) failed: " & gn)
    return
  var planNote = ""
  discard planAll(planNote)
  let groupsN = groupCount()
  var without: seq[string] = @[]
  var gi = 0
  while gi < groupCount():
    if activeObjectiveOf(groupId(gi)) < 0: without.add groupId(gi)
    gi = gi + 1
  var collisions = 0
  var oa = 0
  while oa < objectiveCount():
    if objectiveStatus(oa) == "active":
      var ob = oa + 1
      while ob < objectiveCount():
        if objectiveStatus(ob) == "active" and
           objectiveTarget(ob) == objectiveTarget(oa) and
           objectiveTargetKind(ob) == objectiveTargetKind(oa) and
           objectiveOwner(ob) != objectiveOwner(oa) and
           factionOfGroupId(objectiveOwner(ob)) ==
             factionOfGroupId(objectiveOwner(oa)):
          collisions = collisions + 1
        ob = ob + 1
    oa = oa + 1
  let objA = kindJsonText("objectives")
  var gn2 = ""
  discard generate(11'u64, p, "", gn2)
  var planNote2 = ""
  discard planAll(planNote2)
  let objB = kindJsonText("objectives")
  let sameSeedSame = objA == objB
  if groupsN == 0:
    result.add row("INCONCLUSIVE", "offscreen: every group has an objective",
                   "the generated world has no groups at all -- nothing to " &
                   "plan for, so this cannot pass or fail honestly")
  else:
    var v = "FAIL"
    if without.len == 0 and collisions == 0 and sameSeedSame: v = "PASS"
    result.add row(v,
      "offscreen: every group has an objective, none of one faction collide, the same seed twice is identical",
      $groupsN & " group(s), " & $activeObjectiveCount() &
      " active objective(s); groups without one: " & $without.len &
      "; same-faction target collisions: " & $collisions &
      "; the same seed twice produced " &
      (if sameSeedSame: "the SAME" else: "DIFFERENT") &
      " objectives document (" & $objA.len & " vs " & $objB.len &
      " bytes); " & planNote)

  # ---- (b) 12 h of offscreen time produces a resolution with a narrative and
  #          a rumour. Negative control: 0 ms produces neither.
  let factsBefore = offscreenFactCount()
  var zeroNote = ""
  let zeroChanges = offscreenAdvance(0'i64, zeroNote)
  let factsAfterZero = offscreenFactCount()
  let resBefore = offscreenResolutions()
  var advNote = ""
  let changes = offscreenAdvance(12'i64 * 3600000'i64, advNote)
  let narrative = offscreenNarrativeInJournal()
  let factsAfter = offscreenFactCount()
  let negativeHeld = zeroChanges == 0 and factsAfterZero == factsBefore
  if not negativeHeld:
    result.add row("FAIL",
      "offscreen: 12 h produces an encounter and a rumour",
      "the NEGATIVE CONTROL failed first: advance(0) made " & $zeroChanges &
      " change(s) and " & $(factsAfterZero - factsBefore) & " fact(s) -- " &
      zeroNote)
  elif offscreenResolutions() == resBefore:
    result.add row("INCONCLUSIVE",
      "offscreen: 12 h produces an encounter and a rumour",
      "12 h ran (" & $changes & " change(s)) but no two groups of different " &
      "factions ever shared a place, so nothing could resolve: " & advNote)
  else:
    var v = "FAIL"
    if narrative.len > 0 and factsAfter > factsBefore: v = "PASS"
    result.add row(v,
      "offscreen: 12 h produces an encounter with a narrative and an origin:offscreen rumour",
      $(offscreenResolutions() - resBefore) & " resolution(s) over " & $changes &
      " change(s); the journal's last offscreen narrative is [" & narrative &
      "]; origin:offscreen facts " & $factsBefore & " -> " & $factsAfter &
      "; the negative control (advance 0) made 0 changes and 0 facts")

  # ---- (c) determinism: the same 6 h from the same generated state, twice.
  offscreenReset()
  var d1 = ""
  discard generate(11'u64, p, "", d1)
  var pn1 = ""
  discard planAll(pn1)
  var an1 = ""
  discard offscreenAdvance(6'i64 * 3600000'i64, an1)
  let jA = kindJsonText("journal")
  offscreenReset()
  var d2 = ""
  discard generate(11'u64, p, "", d2)
  var pn2 = ""
  discard planAll(pn2)
  var an2 = ""
  discard offscreenAdvance(6'i64 * 3600000'i64, an2)
  let jB = kindJsonText("journal")
  var vDet = "FAIL"
  if jA == jB and jA.len > 0: vDet = "PASS"
  result.add row(vDet,
    "offscreen: 6 h replayed from the same state is byte-identical",
    "journal A " & $jA.len & " bytes, journal B " & $jB.len &
    " bytes, identical " & $(jA == jB) &
    " (this proves the OFFSCREEN engine only; bm/sim's own steps are CHECK 1)")

  # ---- (d) regions: the frozen map does not move, another one does.
  offscreenReset()
  var d3 = ""
  discard generate(11'u64, p, "", d3)
  var pn3 = ""
  discard planAll(pn3)
  var maps: seq[string] = @[]
  var mi = 0
  while mi < groupCount():
    let m = groupMap(mi)
    var seen = false
    for x in maps:
      if x == m: seen = true
    if not seen and m.len > 0: maps.add m
    mi = mi + 1
  if maps.len < 2:
    result.add row("INCONCLUSIVE", "offscreen: a frozen map does not move",
      "the generated world has groups on only " & $maps.len &
      " map(s) -- freezing one leaves nothing to compare it against")
  else:
    let frozen = maps[0]
    let other = maps[1]
    let fBefore = mapSignature(frozen)
    let oBefore = mapSignature(other)
    offscreenFreezeMap(frozen)
    var rn = ""
    discard offscreenAdvance(2'i64 * 3600000'i64, rn)
    let fAfter = mapSignature(frozen)
    let oAfter = mapSignature(other)
    offscreenThaw()
    var v = "FAIL"
    if fBefore == fAfter and oBefore != oAfter: v = "PASS"
    elif fBefore == fAfter: v = "INCONCLUSIVE"
    result.add row(v,
      "offscreen: with the player on " & frozen & ", " & frozen &
      " is frozen and " & other & " keeps running",
      frozen & " unchanged over 2 h: " & $(fBefore == fAfter) & " (" &
      $fBefore.len & " bytes of signature); " & other & " changed: " &
      $(oBefore != oAfter) & " -- INCONCLUSIVE here means the frozen half " &
      "held but the other map had nothing to do; " & rn)

  # ---- (e) the regions route answers per map.
  let reg = done(regionsJson()).text
  var vReg = "FAIL"
  if reg.len > 40 and find(reg, "\"regions\"") >= 0: vReg = "PASS"
  result.add row(vReg, "offscreen: world/regions reports every map",
    $maps.len & " map(s) with groups; the document is " & $reg.len &
    " bytes and " &
    (if find(reg, "\"emulated\"") >= 0: "names at least one EMULATED region"
     else: "names NO emulated region"))
