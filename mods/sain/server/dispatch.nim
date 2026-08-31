## ORBIT's LOW-LEVEL half: turning a plan into an order for one bot.
##
## ## What this widens, and why that is the point
##
## Before this file the whole channel out of `mods/sain` was one number:
## `difficulty` -> `BotMover.MoveSpeed`, for every bot at once (`server/drive.nim`).
## Everything `core/decide.nim` works out -- cover scoring, dwell hysteresis,
## path-failure counting, in/near/far banding, personality -- was computed and
## then thrown away, because there was nowhere to send it. `forcePersonality`
## was documented as `implemented = false` for exactly that reason.
##
## This adds the second verb. `aowlspt/botnav` already exposes
## `EFT.BotOwner::GoToPoint` @0x81CB40 through the same byte-verified kind=15
## detour on `UpdateManual` @0x81B7C0 that the census rides. So a per-bot
## DESTINATION now reaches a bot, and personality now means something
## observable: which anchor a bot picks, whether it sprints there, and how much
## of the map it bothers to visit.
##
## **This file resolves no name and adds no RVA.** Zero new ones, same as
## `drive.nim`. Facts #143/#144/#145 make that non-negotiable.
##
## ## Why the orders are merged into drive.nim's send and not sent from here
##
## `botnav` is LAST WRITER WINS over one command set. If this file called
## `sendBotCommands` on its own, its set would replace `drive.nim`'s MoveSpeed
## set, and the difficulty band would silently stop reaching anything -- a
## regression with no error anywhere. So `drive.nim` owns the single send and
## calls `dispatchFor` to fill the rest of the set. One census subscription,
## one command set, one place where a bot's whole instruction is assembled.
##
## ## What this does NOT do
##
## * **No looting.** `botnav` has `GoToPoint`, `SetTargetMoveSpeed` and `stop`.
##   There is no inventory verb, so a bot walks to a loot anchor and stands
##   there. The plan's per-personality value gates are used for the one thing
##   still available -- deciding WHETHER a bot walks to that cell at all.
## * **No extract.** The plan says so itself: `base.exits` carries no position.
##   `cdExtract` remains a decision with no destination.
## * **No combat override.** A bot in a fight ignores nav commands; `botnav`'s
##   own header says so. This steers the roaming half of a raid, which is most
##   of it, and it does not pretend to steer the other half.
## * **Advisory, not authoritative.** The brain re-targets the mover every
##   tick. The host re-issues an active command every 500 ms until `holdMs`
##   expires; expect a bot to argue.

import aowlspt
import aowlspt/server
import aowlspt/botnav
import aowlspt/json
import ".." / core / types
import ".." / core / vec
import ".." / core / objective

const
  MaxAnchors* = 24
  MaxBots* = 32
    ## Same bound as `drive.nim`'s tracker and for the same reason.
  MaxOrdersPerCensus* = 12
    ## `sendBotCommands` takes at most 16 and `drive.nim` spends one of them on
    ## the MoveSpeed row. Twelve leaves headroom rather than sitting on the cap,
    ## because a set that overflows is silently truncated at the far end.
  ArrivedFactor* = 1.5
    ## How close to the anchor counts as arrived, as a multiple of `reach`.
    ## Positions in the census are rounded to whole metres, so anything tighter
    ## than a metre or two is a comparison against noise.
  ProgressM* = 3.0
    ## How much closer a bot must get before `dispatchCheck` counts it as
    ## progress. Above the census's own rounding, deliberately.

type
  Personality* = enum
    ## ORBIT's six, which are SAIN's names. Deliberately NOT `core/types`'
    ## nine-member `Personality`: that enum carries `pWreckless` and
    ## `pSnappingTurtle`, which the plan has no weight for, and mapping a
    ## missing weight onto a real personality would be inventing a
    ## distribution. `toCorePersonality` below converts where the core needs it.
    peRat, peCoward, peNormal, peChad, peGigaChad, peTimmy

  Anchor = object
    isLoot: bool
    isQuest: bool
    x, y, z: float
    score: float

  Slot = object
    used: bool
    id: int
    role: int
    pers: Personality
    anchor: int          ## index into gAnchors, -1 for none assigned
    skip: uint32         ## bit per anchor this bot has given up on
    haveDist: bool
    firstDist: float     ## distance to the CURRENT anchor when it was assigned
    bestDist: float      ## closest it has ever been to that anchor
    sightings: int
    arrivals: int

var
  gHavePlan = false
  gPlanMap = ""
  gAnchors: array[MaxAnchors, Anchor]
  gAnchorLen = 0
  gLeash = 45.0
  gSplinter = 90.0
  gReach = 8.0
  gHoldMs = 30000
  gCoverage: array[Personality, float]
  gWeights: array[Personality, float]
  gValueGate: array[Personality, float]
  gForced = peNormal
  gForcedOn = false
  gLog = false

  gSlots: array[MaxBots, Slot]
  gSlotLen = 0
  gOrdersSent = 0
  gProgressed = 0        ## distinct bots that ever closed on their anchor
  gMeasured = 0          ## distinct bots we ever had two readings for
  gSkipped = 0           ## anchors dropped by a coverage roll or a value gate
  gUnreachable = 0       ## anchors dropped because navStatus said 2

  # ------------------------------------------------------------------
  # The census counters. THE WHOLE POINT OF THIS BLOCK: before it, a raid in
  # which no bot was ever dispatched printed the plan line ("Bots will be
  # dispatched on the next census") and then NOTHING -- and "the dispatcher
  # never ran" was indistinguishable from "it ran and declined every bot".
  # That gap cost this project entire sessions. Every census now prints how
  # many bots it saw, how many were eligible, how many were ordered, and the
  # count for each named reason the rest were not.
  # ------------------------------------------------------------------
  gCensuses = 0          ## censuses `dispatchFor` was actually entered on
  gCensusLogged = 0
  gcNotAlive = 0         ## the census row said the bot is dead
  gcNoSlot = 0           ## the 32-bot slot table is full
  gcUnreachableNow = 0   ## navStatus == 2 this census, anchor surrendered
  gcDeclined = 0         ## no anchor left this bot wants (coverage roll/gate)
  gcTourReset = 0        ## toured every anchor it wanted; skip list cleared
  gcArrived = 0          ## reached its anchor this census, re-assigned
  gcCapped = 0           ## MaxOrdersPerCensus reached, bot not looked at

proc toCorePersonality*(p: Personality): types.Personality =
  ## The bridge to `core/decide.nim`'s ladder, so that the same personality
  ## drives both the objective choice here and the combat thresholds there when
  ## the core is fed. It is a total function on purpose: a personality that
  ## fell through to `pNone` would silently take the core's neutral path.
  case p
  of peRat: pRat
  of peCoward: pCoward
  of peNormal: pNormal
  of peChad: pChad
  of peGigaChad: pGigaChad
  of peTimmy: pTimmy

proc persName*(p: Personality): string =
  case p
  of peRat: "rat"
  of peCoward: "coward"
  of peNormal: "normal"
  of peChad: "chad"
  of peGigaChad: "gigachad"
  of peTimmy: "timmy"

proc fromCorePersonality*(p: types.Personality): (bool, Personality) =
  ## `preset.forcePersonality` is a `core/types.Personality`, which has nine
  ## members to this file's six. Returns whether the value maps, so an
  ## unmappable one can be REFUSED by name in the log rather than quietly
  ## meaning `normal` -- which is what "the setting does nothing" looks like
  ## from the outside.
  ##
  ## The two SAIN personalities the ORBIT plan carries no weight for are mapped
  ## to their nearest neighbour ON THE ONE AXIS THIS FILE USES -- how much of
  ## the map a bot bothers with -- and nothing else is claimed about the
  ## resemblance: `pWreckless` behaves like a gigachad here (skips most of it,
  ## sprints), `pSnappingTurtle` like a rat (clears nearly everything, walks).
  case p
  of pRat: (true, peRat)
  of pCoward: (true, peCoward)
  of pNormal: (true, peNormal)
  of pChad: (true, peChad)
  of pGigaChad: (true, peGigaChad)
  of pTimmy: (true, peTimmy)
  of pWreckless: (true, peGigaChad)
  of pSnappingTurtle: (true, peRat)
  of pNone: (false, peNormal)

# ---------------------------------------------------------------------------
# Deterministic per-bot draws
# ---------------------------------------------------------------------------

proc mix(a, b: int): uint32 =
  ## A small integer hash. Deterministic per (bot id, purpose) so that a bot
  ## keeps its personality and its coverage verdict for the whole raid across
  ## censuses -- a bot that re-rolled every three seconds would flicker between
  ## objectives and look broken rather than look cautious. It is not a good
  ## hash and does not need to be; it needs to be stable and cheap.
  var h = uint32(0x811c9dc5'i64)
  h = (h xor uint32(a and 0xffff)) * 16777619'u32
  h = (h xor uint32((a shr 16) and 0xffff)) * 16777619'u32
  h = (h xor uint32(b and 0xffff)) * 16777619'u32
  result = h

proc unit(a, b: int): float =
  float(mix(a, b) mod 100000'u32) / 100000.0

proc drawPersonality(id: int): Personality =
  ## The bot's personality, drawn from the plan's distribution.
  ##
  ## The game never tells us this. There is no SAIN in the client on this
  ## build -- `mods/sain` is a server-side port whose client half is refused as
  ## fatal -- so a bot's personality is not something to read, it is something
  ## to ASSIGN. ORBIT assigns it too; it just happens to do so inside the
  ## client. Drawing it from the bot's own id makes it stable and makes two
  ## runs with the same bot ids comparable.
  if gForcedOn:
    return gForced
  var total = 0.0
  for p in peRat .. peTimmy:
    total = total + gWeights[p]
  if total <= 0.0:
    return peNormal
  var r = unit(id, 1) * total
  for p in peRat .. peTimmy:
    r = r - gWeights[p]
    if r <= 0.0:
      return p
  result = peNormal

proc sprintFor(p: Personality): bool =
  ## Who runs to an objective. This is the second observable personality gets,
  ## after which anchors it picks, and it is the one a human notices first.
  p == peChad or p == peGigaChad

# ---------------------------------------------------------------------------
# The plan
# ---------------------------------------------------------------------------

proc covFor(j: JsonRef; name: string; d: float): float =
  asFloat(field(j, name), d)

proc onPlan(payload: string): string =
  ## `tarkov.orbit.plan`, broadcast once per raid by `mods/tarkov/emu/orbit`.
  result = ""
  let j = whole(payload)
  if not asBool(field(j, "ok"), false):
    gHavePlan = false
    gAnchorLen = 0
    warn "sain/dispatch: the flanking plan arrived with ok=false (" &
         asText(field(j, "why"), "no reason given") &
         "). No bot will be sent anywhere this raid, and that is the plan " &
         "being empty rather than the channel being down"
    return
  gPlanMap = asText(field(j, "map"), "?")
  let anchors = field(j, "anchors")
  let n = count(anchors)
  gAnchorLen = 0
  var i = 0
  while i < n and gAnchorLen < MaxAnchors:
    let a = at(anchors, i)
    let kind = asText(field(a, "kind"), "")
    gAnchors[gAnchorLen] = Anchor(
      isLoot: kind == "loot",
      isQuest: kind == "questPoi",
      x: asFloat(field(a, "x"), 0.0),
      y: asFloat(field(a, "y"), 0.0),
      z: asFloat(field(a, "z"), 0.0),
      score: asFloat(field(a, "score"), 0.0))
    inc gAnchorLen
    inc i

  let mv = field(j, "movement")
  gLeash = asFloat(field(mv, "leashM"), 45.0)
  gSplinter = asFloat(field(mv, "splinterM"), 90.0)
  gReach = asFloat(field(mv, "reachM"), 8.0)
  gHoldMs = asInt(field(mv, "holdMs"), 30000)

  let cov = field(j, "coverage")
  gCoverage[peRat] = covFor(cov, "rat", 0.9)
  gCoverage[peCoward] = covFor(cov, "coward", 0.9)
  gCoverage[peNormal] = covFor(cov, "normal", 0.7)
  gCoverage[peChad] = covFor(cov, "chad", 0.55)
  gCoverage[peGigaChad] = covFor(cov, "gigachad", 0.38)
  gCoverage[peTimmy] = covFor(cov, "timmy", 0.8)

  let w = field(j, "personality")
  gWeights[peRat] = covFor(w, "rat", 0.15)
  gWeights[peCoward] = covFor(w, "coward", 0.10)
  gWeights[peNormal] = covFor(w, "normal", 0.45)
  gWeights[peChad] = covFor(w, "chad", 0.20)
  gWeights[peGigaChad] = covFor(w, "gigachad", 0.05)
  gWeights[peTimmy] = covFor(w, "timmy", 0.05)

  let v = field(j, "lootValue")
  gValueGate[peRat] = covFor(v, "rat", 5000.0)
  gValueGate[peCoward] = covFor(v, "coward", 5000.0)
  gValueGate[peNormal] = covFor(v, "normal", 10000.0)
  gValueGate[peChad] = covFor(v, "chad", 15000.0)
  gValueGate[peGigaChad] = covFor(v, "gigachad", 20000.0)
  gValueGate[peTimmy] = covFor(v, "timmy", 0.0)

  # Every bot's assignment is void: the anchors it referred to are gone.
  var k = 0
  while k < MaxBots:
    gSlots[k].used = false
    inc k
  gSlotLen = 0
  gHavePlan = gAnchorLen > 0
  gCensuses = 0
  gCensusLogged = 0
  var quest = 0
  var loot = 0
  var k2 = 0
  while k2 < gAnchorLen:
    if gAnchors[k2].isQuest: inc quest
    if gAnchors[k2].isLoot: inc loot
    inc k2
  info "sain/dispatch: flanking plan for '" & gPlanMap & "' -- " &
       $gAnchorLen & " anchors (" & $quest & " questPoi, " & $loot &
       " loot, " & $(gAnchorLen - quest - loot) & " spawn-derived), leash " &
       $int(gLeash) & "m, reach " & $int(gReach) &
       "m. Every census from here on prints a `dispatch census` counter " &
       "line, so a raid where nothing is dispatched now says WHY instead of " &
       "printing nothing at all"

var gObjectivesOwn = false
var gGateSaid = false
var gSuppressed = 0

proc setObjectivesOwnDestinations*(on: bool) =
  ## Hand the destination channel to the client, or take it back.
  ##
  ## Called once from `sain.nim` with `objectives.enabled`. It is the ONLY
  ## thing that decides which of the two GoToPoint actuators is live, and it
  ## is one call in one place on purpose: the previous arrangement had no such
  ## place, which is why both of them ran.
  gObjectivesOwn = on

proc objectivesOwnDestinations*(): bool = gObjectivesOwn
proc suppressedCensuses*(): int = gSuppressed

proc kindFromName(s: string): ObjectiveKind =
  case s
  of "questPoi": okQuestPoi
  of "loot": okLoot
  of "hold": okHold
  of "hunt": okHunt
  of "reposition", "pvp", "roam": okReposition
  else: okNone

proc onCatalog(payload: string): string =
  ## `tarkov.objectives.catalog`, broadcast once per raid by
  ## `mods/tarkov/emu/orbit`. Parsed HERE, in the same module that already
  ## parses the plan, and pushed straight into `core/objective`'s table --
  ## which the client assigner reads. The backend never sees a group.
  result = ""
  let j = whole(payload)
  clearCatalog()
  resetObjectives()
  if not asBool(field(j, "ok"), false):
    warn "sain/objectives: the catalog arrived with ok=false (" &
         asText(field(j, "why"), "no reason given") &
         "). No bot will be given an objective this raid, and that is the " &
         "catalog being empty rather than the channel being down"
    return
  setCatalogMap(asText(field(j, "map"), "?"))
  let entries = field(j, "objectives")
  let n = count(entries)
  var refused = 0
  var i = 0
  while i < n:
    let e = at(entries, i)
    inc i
    let k = kindFromName(asText(field(e, "kind"), ""))
    if k == okNone:
      inc refused
      continue
    if addObjective(k, vec3(asFloat(field(e, "x"), 0.0),
                            asFloat(field(e, "y"), 0.0),
                            asFloat(field(e, "z"), 0.0)),
                    asFloat(field(e, "priority"), 1.0)) < 0:
      inc refused
  info "sain/objectives: " & catalogCheck() &
       (if refused > 0: ". " & $refused & " entry/entries were refused (an " &
        "unknown kind, or a position at world zero, which is what a db.json " &
        "staticContainer looks like)" else: "")

proc startDispatch*(forcePersonality: types.Personality;
                    logDecisions: bool): bool =
  ## Subscribe to the plan. Returns whether the subscription took; the caller
  ## logs the failure, because a dispatcher that silently never armed is the
  ## exact shape of bug this repo keeps paying for.
  gLog = logDecisions
  if forcePersonality != pNone:
    let (ok, p) = fromCorePersonality(forcePersonality)
    if ok:
      gForced = p
      gForcedOn = true
      info "sain/dispatch: forcePersonality -> '" & persName(p) &
           "'. Every bot will use that coverage roll and sprint rule when " &
           "choosing objectives. THIS is the channel that setting never had"
    else:
      warn "sain/dispatch: forcePersonality does not map onto a flanking " &
           "personality and is REFUSED; personalities will be drawn from " &
           "the plan's distribution instead"
  if onEvent("tarkov.objectives.catalog", onCatalog) != Ok:
    warn "sain/objectives: the subscription to `tarkov.objectives.catalog` " &
         "did NOT take. No catalog will arrive, every bot's objective layer " &
         "will decline, and with objectivesEnabled on that means bots decide " &
         "and do not roam -- which is the safe direction and the visibly " &
         "broken one"
  result = onEvent("tarkov.orbit.plan", onPlan) == Ok

# ---------------------------------------------------------------------------
# Assignment
# ---------------------------------------------------------------------------

proc dist2(ax, ay, az, bx, by, bz: float): float =
  let dx = ax - bx
  let dy = ay - by
  let dz = az - bz
  result = dx * dx + dy * dy + dz * dz

proc sqrtApprox(v: float): float =
  ## Newton, six iterations, no `math` import. `mods/sain/core/vec.nim` has a
  ## real one but importing the vector core into the server half to take one
  ## square root would drag the whole decision core's type graph in behind it.
  if v <= 0.0:
    return 0.0
  var x = v
  var i = 0
  while i < 24:
    x = 0.5 * (x + v / x)
    inc i
  result = x

proc slotFor(id: int): int =
  var i = 0
  while i < gSlotLen:
    if gSlots[i].used and gSlots[i].id == id:
      return i
    inc i
  if gSlotLen >= MaxBots:
    return -1
  let idx = gSlotLen
  inc gSlotLen
  gSlots[idx] = Slot(used: true, id: id, role: 0, pers: drawPersonality(id),
                     anchor: -1, skip: 0'u32, haveDist: false, firstDist: 0.0,
                     bestDist: 0.0, sightings: 0, arrivals: 0)
  result = idx

proc skipped(s: Slot; a: int): bool =
  if a < 0 or a >= 32: return true
  (s.skip and (1'u32 shl uint32(a))) != 0'u32

proc markSkipped(i, a: int) =
  if a >= 0 and a < 32:
    gSlots[i].skip = gSlots[i].skip or (1'u32 shl uint32(a))

proc wantsAnchor(i, a: int): bool =
  ## ORBIT's coverage roll and value gate, both of them, in the one place they
  ## can still act: whether this bot walks to this cell at all.
  ##
  ## Deterministic in (bot id, anchor index), so a bot that declined a cell
  ## keeps declining it -- a re-roll every census would send it back and forth
  ## across the map, which is the opposite of the behaviour ORBIT's roll exists
  ## to produce.
  let s = gSlots[i]
  let an = gAnchors[a]
  # MEASURED, and it means this branch is dead today: every static-container
  # Position in this build's db.json is (0,0,0), so `emu/orbit` emits NO loot
  # anchors at all and `isLoot` is false for every anchor that arrives. The
  # gate is kept rather than deleted because the reader on the other side is
  # correct and a database with real positions turns both on together -- but
  # nothing below runs on this build, and saying otherwise would be the
  # "setting that changes nothing" this repo keeps paying for.
  if an.isLoot:
    # The value gate, scaled. `score` is a sum of spawn probabilities, not
    # roubles: the database has no per-container value here without walking
    # every item template in it, which is a 41 MB read on a loading screen.
    # So the gate is applied as a RANK, not as a currency comparison, and it is
    # named `valueRank` rather than pretending the number is money.
    let valueRank = an.score
    let need = gValueGate[s.pers] / 20000.0 * 2.0
    if valueRank < need:
      return false
  result = unit(s.id, 1000 + a) < gCoverage[s.pers]

proc pickAnchor(i: int; x, y, z: float; leaderAnchor: int): int =
  ## Primary for a lone bot or a leader; splinter for a follower.
  ##
  ## A follower takes the highest-scoring anchor within `splinterM` of the
  ## leader's anchor that it has not skipped -- ORBIT's "leader takes the main
  ## target, teammates take nearby secondaries". A lone bot takes the nearest
  ## anchor it wants, weighted toward score, which keeps a raid's bots spread
  ## over the map instead of all converging on the single densest cell.
  result = -1
  var best = -1.0
  var a = 0
  while a < gAnchorLen:
    if not skipped(gSlots[i], a) and wantsAnchor(i, a):
      let an = gAnchors[a]
      var eligible = true
      if leaderAnchor >= 0 and leaderAnchor < gAnchorLen and a != leaderAnchor:
        let la = gAnchors[leaderAnchor]
        if dist2(an.x, an.y, an.z, la.x, la.y, la.z) >
           gSplinter * gSplinter:
          eligible = false
      if eligible:
        let d = sqrtApprox(dist2(an.x, an.y, an.z, x, y, z))
        # Score per metre walked. A dense cell 200 m away loses to a decent one
        # 40 m away, which is what a bot with a raid timer would do.
        let w = an.score / (d + 25.0)
        if w > best:
          best = w
          result = a
    inc a

# ---------------------------------------------------------------------------
# The per-census entry point
# ---------------------------------------------------------------------------

proc dispatchArmed*(): bool = gHavePlan and gAnchorLen > 0

proc dispatchFor*(bots: seq[BotInfo]): seq[BotCommand] =
  ## The orders for this census, to be appended to `drive.nim`'s command set.
  ##
  ## Not sent from here. See the header: one send, or the MoveSpeed row is
  ## silently lost to last-writer-wins.
  result = @[]
  # THE ONE-WRITER GATE, and it is the first thing in the function on purpose.
  #
  # With objectives on, `core/decide.nim` is the single chooser of a
  # destination and this path issues NONE -- not a reduced set, not a
  # lower-priority set: none. Two writers on one bot's Mover is
  # last-writer-wins between two policies neither of which knows the other
  # exists, and the leader this path cohered around was a fiction anyway (the
  # lowest live bot id in the census, which is not a BSG group).
  #
  # Deleting these four lines is the falsifier for `oneWriterCheck`: do that
  # and `dwServer` starts counting, and the check FAILS instead of passing.
  if gObjectivesOwn:
    inc gSuppressed
    if not gGateSaid:
      gGateSaid = true
      info "sain/dispatch: objectives are ON, so this path issues NO " &
           "destination this raid. The client decide ladder owns GoToPoint " &
           "and `core/objective.oneWriterCheck` FAILS if this line is ever " &
           "reached with an order attached. MoveSpeed and the per-role rows " &
           "are unaffected -- they are a different command and a different " &
           "writer"
    return
  if not dispatchArmed():
    return
  inc gCensuses
  var cNotAlive = 0
  var cNoSlot = 0
  var cUnreach = 0
  var cDeclined = 0
  var cTourReset = 0
  var cArrived = 0
  var cCapped = 0

  # The leader is the lowest live bot id in this census. It is not a squad in
  # the game's sense -- the census carries no group id and there is no member
  # to read without a name lookup -- and it is not claimed to be one. It is a
  # stable choice of "who takes the primary", which is the only property the
  # splinter rule needs.
  var leader = -1
  var i = 0
  while i < bots.len:
    if bots[i].alive and (leader < 0 or bots[i].id < leader):
      leader = bots[i].id
    inc i
  var leaderAnchor = -1
  if leader >= 0:
    let ls = slotFor(leader)
    if ls >= 0:
      leaderAnchor = gSlots[ls].anchor

  i = 0
  while i < bots.len:
    let b = bots[i]
    inc i
    if not b.alive:
      inc cNotAlive
      continue
    if result.len >= MaxOrdersPerCensus:
      # Counted rather than silently left out of the loop. A raid where the
      # census is bigger than the order budget looks exactly like a raid where
      # most bots were declined, unless this number exists.
      inc cCapped
      continue
    let s = slotFor(b.id)
    if s < 0:
      inc cNoSlot
      continue
    gSlots[s].role = b.role
    inc gSlots[s].sightings

    # The navmesh's own answer, honoured rather than argued with. `botnav`
    # reports 2 = no path; re-issuing will not change the navmesh's mind, and
    # this is where a centroid that landed inside a wall gets dropped.
    if b.navStatus == 2 and gSlots[s].anchor >= 0:
      markSkipped(s, gSlots[s].anchor)
      inc gUnreachable
      inc cUnreach
      gSlots[s].anchor = -1
      gSlots[s].haveDist = false

    var a = gSlots[s].anchor
    if a >= 0:
      let an = gAnchors[a]
      let d = sqrtApprox(dist2(an.x, an.y, an.z, b.x, b.y, b.z))
      if gSlots[s].haveDist:
        if d < gSlots[s].bestDist - ProgressM:
          if gSlots[s].bestDist >= gSlots[s].firstDist:
            inc gProgressed
          gSlots[s].bestDist = d
      else:
        gSlots[s].haveDist = true
        gSlots[s].firstDist = d
        gSlots[s].bestDist = d
        inc gMeasured
      if d <= gReach * ArrivedFactor:
        # Arrived. Give up this anchor for good and take another, which is what
        # makes a bot tour the map rather than stand on one crate all raid.
        markSkipped(s, a)
        inc cArrived
        inc gSlots[s].arrivals
        gSlots[s].anchor = -1
        gSlots[s].haveDist = false
        a = -1

    if a < 0:
      let want = pickAnchor(s, b.x, b.y, b.z,
                            (if b.id == leader: -1 else: leaderAnchor))
      if want < 0:
        # Nothing left it wants. Clear the skip list ONCE it has actually
        # arrived somewhere, so a bot that toured the map starts again rather
        # than freezing; a bot that skipped everything without arriving keeps
        # its verdicts, which is the coverage roll doing its job.
        if gSlots[s].arrivals > 0:
          gSlots[s].skip = 0'u32
          inc cTourReset
        else:
          inc gSkipped
          inc cDeclined
        continue
      gSlots[s].anchor = want
      gSlots[s].haveDist = false
      a = want

    var tx = gAnchors[a].x
    var ty = gAnchors[a].y
    var tz = gAnchors[a].z

    # The leash. A follower that has drifted further than `leashM` from the
    # leader is sent to the LEADER instead of to its splinter, which is
    # ORBIT's cohesion rule and is the only reason a splinter target is safe
    # to hand out at all.
    if b.id != leader and leader >= 0:
      var k = 0
      while k < bots.len:
        if bots[k].id == leader and bots[k].alive:
          if dist2(b.x, b.y, b.z, bots[k].x, bots[k].y, bots[k].z) >
             gLeash * gLeash:
            tx = bots[k].x
            ty = bots[k].y
            tz = bots[k].z
          break
        inc k

    result.add goTo(b.id, tx, ty, tz, reach = gReach,
                    sprint = sprintFor(gSlots[s].pers), holdMs = gHoldMs)
    # On the ledger BEFORE the counter, so there is no ordering in which this
    # path emits a destination without the check being able to see it. The
    # time argument is the census index rather than a clock: this side has no
    # raid clock, and the check reads the COUNT, not the time.
    noteDestination(dwServer, float(gCensuses))
    inc gOrdersSent
    if gLog:
      info "sain/dispatch: bot " & $b.id & " (" & persName(gSlots[s].pers) &
           ") -> anchor " & $a & " at " & $int(tx) & "," & $int(tz) &
           ", navStatus " & $b.navStatus & (if gAnchors[a].isQuest:
             " [questPoi]" elif gAnchors[a].isLoot: " [loot]" else: "")

  gcNotAlive = gcNotAlive + cNotAlive
  gcNoSlot = gcNoSlot + cNoSlot
  gcUnreachableNow = gcUnreachableNow + cUnreach
  gcDeclined = gcDeclined + cDeclined
  gcTourReset = gcTourReset + cTourReset
  gcArrived = gcArrived + cArrived
  gcCapped = gcCapped + cCapped

  # WHEN this prints. Not `gLog`-gated: the whole defect being fixed is a raid
  # that printed nothing, and a diagnostic behind a flag that is off by default
  # would reproduce it exactly. Not every census either -- a 30-minute raid is
  # thousands of them and a line per census buries everything else. So: the
  # first three, then every 20th, PLUS every census that ordered nothing while
  # there were live bots to order, because that is the case somebody is
  # actually reading the log to understand.
  let eligible = bots.len - cNotAlive - cNoSlot - cCapped
  let loud = (eligible > 0 and result.len == 0)
  if gCensuses <= 3 or (gCensuses mod 20) == 0 or loud:
    inc gCensusLogged
    var line = "sain/dispatch census " & $gCensuses & ": " & $bots.len &
               " bots considered, " & $eligible & " eligible, " &
               $result.len & " ordered."
    if cNotAlive > 0: line = line & " " & $cNotAlive & " dead."
    if cNoSlot > 0:
      line = line & " " & $cNoSlot & " had no slot (the " & $MaxBots &
             "-bot table is full)."
    if cCapped > 0:
      line = line & " " & $cCapped & " past the " & $MaxOrdersPerCensus &
             "-order budget for this census."
    if cUnreach > 0:
      line = line & " " & $cUnreach &
             " surrendered an anchor the navmesh reported unreachable " &
             "(navStatus 2)."
    if cArrived > 0:
      line = line & " " & $cArrived & " arrived and were re-assigned."
    if cDeclined > 0:
      line = line & " " & $cDeclined &
             " wanted no remaining anchor (coverage roll or value gate) and " &
             "have never arrived anywhere, so their verdicts stand."
    if cTourReset > 0:
      line = line & " " & $cTourReset &
             " had toured every anchor they wanted and had their skip list " &
             "cleared."
    if loud:
      line = line & " NOTHING WAS DISPATCHED THIS CENSUS and there were " &
             "live bots to dispatch -- the reasons above are the whole " &
             "explanation, and if none of them is non-zero the bug is in " &
             "this counting, not in the assignment."
    info line

proc dispatchCheck*(): string =
  ## PASS / FAIL / INCONCLUSIVE on the FINISHED STATE, as a negative.
  ##
  ## The property: *of every bot this mod addressed and could measure twice, at
  ## least one got materially closer to the point it was sent to.* What
  ## falsifies it, concretely -- a coordinate order that is wrong (y and z
  ## swapped, a centroid inside geometry, a stale anchor from the previous
  ## map): every bot is ordered somewhere it cannot go, `gMeasured` climbs,
  ## `gProgressed` stays 0, and this returns FAIL. Reading back the order we
  ## sent could not produce that outcome, which is why the order is not what is
  ## read.
  ##
  ## What PASS does NOT establish: that the bot moved BECAUSE of the order.
  ## Bots walk on their own. Separating the two needs the two-run comparison in
  ## `README.md` (`orbitEnabled` false, then true, same map, same seed) and no
  ## single run can do it.
  if not gHavePlan:
    return "INCONCLUSIVE: no ORBIT plan has arrived on `tarkov.orbit.plan`, " &
           "so nothing was dispatched. Check /aowlspt/orbit/plan: a plan " &
           "that was never BUILT and a plan that was built and never " &
           "DELIVERED look identical from here"
  if gOrdersSent == 0:
    # NEVER RAN vs RAN AND ORDERED NOTHING. `gCensuses` is the only thing that
    # separates them and the old message could not: it named both causes and
    # left the reader to guess. Now it says which one happened.
    if gCensuses == 0:
      return "INCONCLUSIVE: a plan with " & $gAnchorLen & " anchors is " &
             "loaded for '" & gPlanMap & "' and `dispatchFor` WAS NEVER " &
             "ENTERED -- not one bot census reached it. That is no raid, or " &
             "no bot in the raid, or `botNav` off in aowlspt-host.json. It " &
             "is NOT evidence that assignment fails, because assignment " &
             "never ran"
    return "INCONCLUSIVE: a plan with " & $gAnchorLen & " anchors is loaded " &
           "for '" & gPlanMap & "' and `dispatchFor` RAN on " & $gCensuses &
           " censuses without issuing one order. Counted reasons: " &
           $gcNotAlive & " dead, " & $gcNoSlot & " no slot, " & $gcCapped &
           " over budget, " & $gcUnreachableNow & " unreachable, " &
           $gcDeclined & " declined every anchor, " & $gcTourReset &
           " tour-reset, " & $gcArrived & " arrived. This is a bot-selection " &
           "failure, not a delivery failure"
  if gMeasured < 3:
    return "INCONCLUSIVE: only " & $gMeasured & " of the 3 bots needed were " &
           "seen twice against the same anchor. The census rotates and a " &
           "bot is re-assigned on arrival, so a short raid can end before " &
           "three pairs exist"
  if gProgressed == 0:
    return "FAIL: " & $gOrdersSent & " orders issued to " & $gMeasured &
           " measurable bots on '" & gPlanMap & "' and NOT ONE closed " &
           $int(ProgressM) & "m on the point it was sent to. That is what a " &
           "wrong coordinate looks like. " & $gUnreachable &
           " anchors were reported unreachable by the navmesh"
  result = "PASS: " & $gProgressed & " of " & $gMeasured &
           " measurable bots closed on the anchor they were sent to across " &
           $gOrdersSent & " orders on '" & gPlanMap & "' (" & $gUnreachable &
           " anchors unreachable, " & $gSkipped &
           " declined by a coverage roll). This proves orders reach bots and " &
           "the coordinates are usable; it does NOT prove the bots moved " &
           "BECAUSE of them -- run the two-band comparison for that"

proc dispatchState*(): string =
  var what = "no plan"
  if gHavePlan:
    what = $gAnchorLen & " anchors on '" & gPlanMap & "'"
  var forced = "drawn from the plan"
  if gForcedOn:
    forced = "forced to " & persName(gForced)
  var quest = 0
  var qi = 0
  while qi < gAnchorLen:
    if gAnchors[qi].isQuest: inc quest
    inc qi
  result = "dispatch: " & what & " (" & $quest & " questPoi), " & $gCensuses &
           " censuses entered, " & $gOrdersSent & " orders, " & $gSlotLen &
           " bots, personality " & forced & "; skips -- " & $gcNotAlive &
           " dead / " & $gcNoSlot & " no slot / " & $gcCapped &
           " over budget / " & $gcUnreachableNow & " unreachable / " &
           $gcDeclined & " declined / " & $gcTourReset & " tour-reset / " &
           $gcArrived & " arrived"

proc stopDispatch*() =
  gHavePlan = false
  gAnchorLen = 0
  gSlotLen = 0

# ---------------------------------------------------------------------------
# Offline self-check
# ---------------------------------------------------------------------------

proc selfCheckDispatch*(into: var seq[string]): bool =
  ## The parts that are arithmetic and testable without a raid.
  result = true
  if sqrtApprox(144.0) < 11.99 or sqrtApprox(144.0) > 12.01:
    into.add "sain/dispatch: sqrtApprox(144) is " & $sqrtApprox(144.0)
    result = false
  if sqrtApprox(0.0) != 0.0:
    into.add "sain/dispatch: sqrtApprox(0) is not 0"
    result = false
  # The draw must be STABLE for one id and must not collapse to one value for
  # every id -- a hash that ignored its input would give every bot in the raid
  # the same personality, which reads as "the distribution setting does
  # nothing".
  gForcedOn = false
  gWeights[peRat] = 0.15
  gWeights[peCoward] = 0.10
  gWeights[peNormal] = 0.45
  gWeights[peChad] = 0.20
  gWeights[peGigaChad] = 0.05
  gWeights[peTimmy] = 0.05
  if drawPersonality(4242) != drawPersonality(4242):
    into.add "sain/dispatch: drawPersonality is not stable for one bot id"
    result = false
  var seen = 0
  var id = 1
  var first = drawPersonality(1)
  while id < 200:
    if drawPersonality(id) != first:
      inc seen
    inc id
  if seen == 0:
    into.add "sain/dispatch: all 200 bot ids drew the same personality; the " &
             "distribution is not being sampled"
    result = false
  let (ok1, p1) = fromCorePersonality(pGigaChad)
  if not ok1 or p1 != peGigaChad:
    into.add "sain/dispatch: forcePersonality pGigaChad did not map"
    result = false
  let (ok2, _) = fromCorePersonality(pNone)
  if ok2:
    into.add "sain/dispatch: forcePersonality accepted pNone as a forced " &
             "personality, so 'unset' silently means 'normal'"
    result = false
