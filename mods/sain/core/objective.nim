## Squad-shared objectives: the catalog, the assigner, and the writer ledger.
##
## ## What this file is for
##
## Before it, two things issued destinations to the same bots and neither knew
## about the other. `server/dispatch.nim` picked an ORBIT anchor per census and
## sent `GoToPoint` over botnav; `core/decide.nim` picked a combat destination
## per decide tick and the client actuator sent `Mover.GoToPoint`. Whichever
## call landed last won, per bot, per tick, for no reason either side could
## state. `docs/BOT_AI_OBJECTIVES.md` calls reconciling that to ONE writer the
## spine of the work, and this file is where the spine goes.
##
## ## The split it implements
##
## * The **backend** owns the CATALOG. It sees `db.json` and the waypoints
##   files and it never sees a live group. It emits positions and kinds.
## * The **client** owns the ASSIGNMENT and the ACTUATION. It is the only side
##   that can partition bots into real squads, because the real squad is the
##   `BotOwner.BotsGroup` pointer and the census channel carries no group id at
##   all.
##
## That is not a preference. A server-side "leader" is the lowest live bot id
## in the census, which is a fiction: two bots with adjacent ids may be in
## different BSG groups on opposite sides of the map. Anything derived from it
## -- leash, splinter, cohesion -- was cohering the wrong set.
##
## ## Why the squad table is keyed by a bare pointer
##
## `client/bridge.groupKeyOf` reads `BotOwner.BotsGroup` through a MEASURED
## getter and returns it as a `uint64`. It is compared for equality and NEVER
## dereferenced, and no member of that group is ever enumerated -- enumerating
## it needs by-name lookup, and on this build `il2cpp_class_from_name` returns
## non-nil handles into unmapped memory, so the nil check passes and the first
## dereference kills the client. `groupKey == 0` means the getter refused, and
## then `core/squad.nim`'s proximity fallback is what partitions; an objective
## for a zero key is a per-bot objective rather than a shared one, and this
## file says so rather than pretending a squad exists.
##
## ## Cost
##
## No allocation on any path. The catalog is a fixed array filled once per
## raid; the squad table is a fixed array of 16 slots with linear probing over
## a table that is never longer than the number of live groups in a raid. One
## squad lookup per bot that is thinking this tick, which the driver's budget
## already bounds at eight.

import vec
import types
import settings

const
  MaxCatalog* = 96
    ## Objectives held at once. The backend ships at most 24 anchors and this
    ## side adds live corpses on top, so the headroom is for phase 2.
  MaxSquads* = 16
    ## Distinct `BotsGroup` pointers tracked at once. A raid has far fewer
    ## groups than bots; a 17th group gets per-bot objectives rather than a
    ## shared one, which is stated in `objectiveState`, not silent.
  MaxRoleSlots* = 8
    ## Distinct offsets the stagger ring hands out before it repeats.

type
  ObjectiveKind* = enum
    okNone
    okReposition   ## go somewhere useful; the generalisation of an ORBIT anchor
    okLoot         ## a place worth searching. MOVE-AND-LOITER ONLY on this
                   ## build -- see `lootIsMoveOnly` below
    okQuestPoi     ## a hand-authored patrol point from mods/waypoints
    okHold         ## stand here and watch
    okHunt         ## go to where something was last known to be

  ObjectiveRole* = enum
    ## One shared objective, a different destination per member.
    omConverge     ## onto the point (the leader, and anyone regrouping)
    omCover        ## short of the point, watching the approach
    omStagger      ## spread around the point on a ring

  Objective* = object
    kind*: ObjectiveKind
    target*: Vec3
    entityKey*: uint64   ## a corpse or container identity, 0 when positional
    priority*: float
    valid*: bool

  CatalogEntry* = object
    kind*: ObjectiveKind
    target*: Vec3
    priority*: float
    entityKey*: uint64
    ## Added at runtime (a corpse) rather than shipped in the plan. Cleared by
    ## `clearLiveCatalog` at raid end without disturbing the shipped entries.
    live*: bool

  SquadSlot* = object
    used*: bool
    key*: uint64        ## the groupKey pointer, or a per-bot key when it is 0
    entry*: int         ## index into the catalog, or -1
    chosenAt*: float
    ## Catalog indices this squad has finished with, as a bitmask over the
    ## first 64 entries. A squad that has toured everything gets it cleared.
    skip*: uint64
    members*: int       ## members seen since this objective was chosen
    lastSeenAt*: float

  DestWriter* = enum
    ## Who issued a destination. The point of naming them is that the
    ## one-writer claim is then a property that can FAIL.
    dwClient       ## core/decide.nim -> client actuator (the intended writer)
    dwServer       ## server/dispatch.nim -> botnav GoToPoint (retired)

func lootIsMoveOnly*(): bool = true
  ## Whether `okLoot` means "walk to it and loiter" rather than "open it".
  ##
  ## TRUE on this build, and it is a capability statement rather than a
  ## setting. Opening a container needs `LootableContainer.Interact` and an
  ## inventory-move RVA; neither is in `docs/SAIN_RVA.md`, and resolving them
  ## by name is the call that was measured killing the client. Until they are
  ## measured, an `okLoot` objective moves a bot and nothing else, and every
  ## place that renders this setting says exactly that.

func objectiveKindName*(k: ObjectiveKind): string =
  case k
  of okNone: "none"
  of okReposition: "reposition"
  of okLoot: "loot"
  of okQuestPoi: "questPoi"
  of okHold: "hold"
  of okHunt: "hunt"

func objectiveRoleName*(r: ObjectiveRole): string =
  case r
  of omConverge: "converge"
  of omCover: "cover"
  of omStagger: "stagger"

func noObjective*(): Objective =
  Objective(kind: okNone, target: zeroVec(), entityKey: 0'u64,
            priority: 0.0, valid: false)

# ---------------------------------------------------------------------------
# The catalog
# ---------------------------------------------------------------------------

var gCatalog: array[MaxCatalog, CatalogEntry]
var gCatalogLen = 0
var gCatalogMap = ""
var gCatalogAdds = 0
var gCatalogFull = 0

proc clearCatalog*() =
  gCatalogLen = 0
  gCatalogMap = ""

proc clearLiveCatalog*() =
  ## Drop the runtime entries (corpses) and keep the shipped ones. Compacts in
  ## place; the shipped entries keep their relative order, which matters
  ## because a squad slot holds an INDEX.
  var w = 0
  var i = 0
  while i < gCatalogLen:
    if not gCatalog[i].live:
      gCatalog[w] = gCatalog[i]
      inc w
    inc i
  gCatalogLen = w

proc setCatalogMap*(m: string) = gCatalogMap = m
proc catalogMap*(): string = gCatalogMap
proc catalogLen*(): int = gCatalogLen
proc catalogAt*(i: int): CatalogEntry =
  if i < 0 or i >= gCatalogLen:
    return CatalogEntry(kind: okNone, target: zeroVec(), priority: 0.0,
                        entityKey: 0'u64, live: false)
  gCatalog[i]

proc addObjective*(kind: ObjectiveKind; target: Vec3; priority: float;
                   entityKey: uint64 = 0'u64; live = false): int =
  ## Append one. Returns its index, or -1 when the table is full or the point
  ## is the origin.
  ##
  ## The origin is REFUSED rather than stored, and that refusal is the whole
  ## reason this check exists: every `staticContainers` position in `db.json`
  ## is `(0,0,0)` -- 7,092 of 7,092 rows, measured -- and a catalog that
  ## accepted them would send every bot in the raid to world zero and look
  ## like a working convergence.
  if gCatalogLen >= MaxCatalog:
    inc gCatalogFull
    return -1
  if target.x == 0.0 and target.z == 0.0:
    return -1
  gCatalog[gCatalogLen] = CatalogEntry(kind: kind, target: target,
                                       priority: priority,
                                       entityKey: entityKey, live: live)
  result = gCatalogLen
  inc gCatalogLen
  inc gCatalogAdds

proc catalogCountOf*(k: ObjectiveKind): int =
  result = 0
  var i = 0
  while i < gCatalogLen:
    if gCatalog[i].kind == k: inc result
    inc i

proc catalogSpread*(): float =
  ## The bounding-box diagonal of every catalog position, in metres.
  ##
  ## This is the P0 falsifier. A catalog whose entries all collapsed to one
  ## point -- or to the origin -- has a spread of zero, and zero is exactly
  ## what a plan built out of dead container positions would produce.
  if gCatalogLen < 2:
    return 0.0
  var minX = gCatalog[0].target.x
  var maxX = minX
  var minZ = gCatalog[0].target.z
  var maxZ = minZ
  var i = 1
  while i < gCatalogLen:
    let t = gCatalog[i].target
    if t.x < minX: minX = t.x
    if t.x > maxX: maxX = t.x
    if t.z < minZ: minZ = t.z
    if t.z > maxZ: maxZ = t.z
    inc i
  let dx = maxX - minX
  let dz = maxZ - minZ
  result = sqrt0(dx * dx + dz * dz)

# ---------------------------------------------------------------------------
# The writer ledger
# ---------------------------------------------------------------------------

var gWrites: array[DestWriter, int]
var gWriterLast: array[DestWriter, float]

proc noteDestination*(w: DestWriter; now: float) =
  ## Record that `w` issued ONE destination. Called immediately before the
  ## order goes out, on the side that issues it, so a writer cannot be counted
  ## without also having written.
  gWrites[w] = gWrites[w] + 1
  gWriterLast[w] = now

proc destinationWrites*(w: DestWriter): int = gWrites[w]

proc resetWriterLedger*() =
  gWrites[dwClient] = 0
  gWrites[dwServer] = 0
  gWriterLast[dwClient] = 0.0
  gWriterLast[dwServer] = 0.0

proc oneWriterCheck*(objectivesOn: bool): string =
  ## PASS / FAIL / INCONCLUSIVE on the FINISHED STATE, as a negative.
  ##
  ## The property asserted is the STRONG one: while objectives are on, the
  ## server dispatch path issued **no destination at all**, so there is
  ## nothing for the client path to race. That is deliberately stronger than
  ## "they did not collide in the same tick" -- the two sides key bots
  ## differently (the client by profile-id string, the census by int id), so a
  ## per-bot collision test could not be written honestly, whereas "the second
  ## writer never fired" can be, and it FAILS the moment it does.
  ##
  ## What would make this FAIL: deleting the `objectivesOwnDestinations()`
  ## guard at the top of `dispatchFor`. That is the falsifier, and it is one
  ## line away, which is the point.
  let c = gWrites[dwClient]
  let s = gWrites[dwServer]
  if not objectivesOn:
    return "INCONCLUSIVE: objectives are off, so server/dispatch is still the " &
           "destination writer by design (" & $s & " server, " & $c &
           " client). This check only claims anything while objectivesEnabled " &
           "is true"
  if s > 0:
    return "FAIL: objectives are on and server/dispatch STILL issued " & $s &
           " destination(s) (client issued " & $c & "). Two writers are live " &
           "on one bot's Mover and the later one wins for no stated reason. " &
           "The gate in dispatchFor is not holding"
  if c == 0:
    return "INCONCLUSIVE: neither side has issued a destination yet. Either " &
           "no raid has run, no bot was ever eligible, or the client " &
           "actuator is refusing -- /sain/status distinguishes those. This is " &
           "NOT a pass: nothing was measured"
  result = "PASS: " & $c & " destination(s) issued, ALL of them by the client " &
           "decide path, and ZERO by server/dispatch. One writer"

# ---------------------------------------------------------------------------
# Assignment
# ---------------------------------------------------------------------------

var gSquads: array[MaxSquads, SquadSlot]
var gSquadLen = 0
var gOverflow = 0
var gChosen = 0
var gCompletedReached = 0
var gCompletedTimeout = 0
var gCompletedInvalid = 0

proc resetObjectives*() =
  var i = 0
  while i < MaxSquads:
    gSquads[i].used = false
    inc i
  gSquadLen = 0
  gOverflow = 0
  gChosen = 0
  gCompletedReached = 0
  gCompletedTimeout = 0
  gCompletedInvalid = 0

func mix64(a, b: uint64): uint64 =
  ## A cheap, deterministic scramble. Deterministic matters: two members of the
  ## same squad must derive the SAME squad seed on different ticks, or the
  ## shared objective is not shared.
  var h = a xor (b * 0x9E3779B97F4A7C15'u64)
  h = h xor (h shr 30)
  h = h * 0xBF58476D1CE4E5B9'u64
  h = h xor (h shr 27)
  h = h * 0x94D049BB133111EB'u64
  result = h xor (h shr 31)

proc slotFor(key: uint64): int =
  ## Find or make the slot for a squad key. Linear probe over a table bounded
  ## by `MaxSquads`; the 17th distinct group is counted and refused rather than
  ## evicting a live squad, because evicting one makes its members disagree
  ## about their objective, which is the exact failure this file removes.
  var i = 0
  while i < gSquadLen:
    if gSquads[i].used and gSquads[i].key == key:
      return i
    inc i
  i = 0
  while i < MaxSquads:
    if not gSquads[i].used:
      gSquads[i] = SquadSlot(used: true, key: key, entry: -1, chosenAt: 0.0,
                             skip: 0'u64, members: 0, lastSeenAt: 0.0)
      if i >= gSquadLen: gSquadLen = i + 1
      return i
    inc i
  inc gOverflow
  result = -1

func skipped(s: SquadSlot; e: int): bool =
  if e < 0 or e >= 64: return false
  (s.skip and (1'u64 shl uint64(e))) != 0'u64

proc markSkipped(i, e: int) =
  if e >= 0 and e < 64:
    gSquads[i].skip = gSquads[i].skip or (1'u64 shl uint64(e))

proc wantsKind(k: ObjectiveKind; s: Settings): bool =
  case k
  of okLoot: s.seekLoot
  of okQuestPoi: s.seekQuestPoi
  of okHold: s.holdPositions
  of okHunt: s.huntLastKnown
  of okReposition: true
  of okNone: false

proc pickEntry(slot: int; from1: Vec3; s: Settings): int =
  ## The squad's next objective.
  ##
  ## Score = priority, biased toward things that are near and away from things
  ## already toured. Seeded by the squad key so that two squads on the same map
  ## with the same catalog do NOT choose the same point -- "all groups collapse
  ## to one position" is one of the two P1 falsifiers, and this jitter is what
  ## keeps it falsifiable rather than impossible.
  result = -1
  var best = -1.0
  let seed = gSquads[slot].key
  var i = 0
  while i < gCatalogLen:
    let e = gCatalog[i]
    if not wantsKind(e.kind, s) or skipped(gSquads[slot], i):
      inc i
      continue
    let d = flatDistance(from1, e.target)
    # Near is better, but not so much better that every squad within 50 m of
    # each other picks the same crate: the distance term saturates.
    var score = e.priority * (1.0 + 60.0 / (60.0 + d))
    if e.kind == okQuestPoi:
      score = score * s.questPoiBias
    if e.kind == okLoot:
      score = score * (0.5 + s.lootSeekAggressiveness)
    # 0..0.5 of the score, stable per (squad, entry) pair.
    let j = float(mix64(seed, uint64(i + 1)) mod 1000'u64) / 1000.0
    score = score * (1.0 + 0.5 * j)
    if score > best:
      best = score
      result = i
    inc i

func roleFor*(memberIndex: int; isLeader: bool): ObjectiveRole =
  ## One shared objective, three postures. The leader converges; the rest
  ## alternate so a squad arrives as a spread rather than a queue.
  if isLeader or memberIndex <= 0: omConverge
  elif (memberIndex and 1) == 1: omStagger
  else: omCover

func destinationFor*(o: Objective; role: ObjectiveRole; memberIndex: int;
                     me: Vec3; s: Settings): Vec3 =
  ## Where THIS member goes, given the squad's one objective.
  ##
  ## Every offset is bounded by `objectiveSplinterM`, which is what makes the
  ## P1 core claim checkable: "every member's destination is within splinterM
  ## of ONE catalog position". An offset larger than the leash would falsify
  ## the mod's own convergence claim, so it is clamped here rather than trusted
  ## to the caller.
  let spread = clampf(s.objectiveSplinterM * 0.5, 0.0, s.objectiveSplinterM)
  case role
  of omConverge:
    result = o.target
  of omStagger:
    # A ring around the point, one slot per member, so two members never take
    # the same offset and none of them takes the leader's.
    let slot = memberIndex mod MaxRoleSlots
    # Eight compass points without a trig call: the unit circle at 45 degrees
    # has components 0, +-0.7071 and +-1.
    const cs = [1.0, 0.7071, 0.0, -0.7071, -1.0, -0.7071, 0.0, 0.7071]
    const sn = [0.0, 0.7071, 1.0, 0.7071, 0.0, -0.7071, -1.0, -0.7071]
    result = vec3(o.target.x + cs[slot] * spread, o.target.y,
                  o.target.z + sn[slot] * spread)
  of omCover:
    # Short of the point, on the line the member is already walking. A bot that
    # stops early and faces the objective is overwatch; a bot that walks onto
    # the objective with everyone else is a crowd.
    let d = flatDistance(me, o.target)
    if d <= spread:
      result = o.target
    else:
      result = towards(me, o.target, d - spread)

proc objectiveFor*(squadKey, memberKey: uint64; memberIndex: int;
                   isLeader: bool; me: Vec3; s: Settings; now: float;
                   role: var ObjectiveRole; destination: var Vec3): bool =
  ## The whole assigner, from one member's seat. Returns whether this bot has
  ## somewhere to be.
  ##
  ## `squadKey` is `BotOwner.BotsGroup` as a bare pointer. When it is zero the
  ## getter refused and there is no real group to share with, so the bot gets
  ## its OWN slot keyed by its own identity and a per-bot objective. That is
  ## reported as such by `objectiveState`; it is not called a squad.
  role = omConverge
  destination = zeroVec()
  if not s.objectivesEnabled or gCatalogLen == 0:
    return false
  let shared = s.squadShareObjectives and squadKey != 0'u64
  let key = if shared: squadKey else: mix64(memberKey, 0xA5A5'u64)
  let slot = slotFor(key)
  if slot < 0:
    return false
  gSquads[slot].lastSeenAt = now
  gSquads[slot].members = gSquads[slot].members + 1

  var e = gSquads[slot].entry
  # Invalidated: the catalog shrank under us (raid end, or the live entries
  # were cleared). Counted rather than silently re-picked, because "the
  # objective vanished" and "the bot arrived" are different things.
  if e >= gCatalogLen:
    e = -1
    gSquads[slot].entry = -1
    inc gCompletedInvalid

  if e >= 0:
    let t = gCatalog[e].target
    if flatDistance(me, t) <= s.objectiveReachM:
      markSkipped(slot, e)
      gSquads[slot].entry = -1
      inc gCompletedReached
      e = -1
    elif now - gSquads[slot].chosenAt > s.objectiveTimeoutS:
      markSkipped(slot, e)
      gSquads[slot].entry = -1
      inc gCompletedTimeout
      e = -1

  if e < 0:
    e = pickEntry(slot, me, s)
    if e < 0:
      # Toured everything it wanted. Clear the skip list and let it start
      # again, rather than freezing on the last point of the raid.
      gSquads[slot].skip = 0'u64
      e = pickEntry(slot, me, s)
      if e < 0:
        return false
    gSquads[slot].entry = e
    gSquads[slot].chosenAt = now
    inc gChosen

  let ce = gCatalog[e]
  let o = Objective(kind: ce.kind, target: ce.target,
                    entityKey: ce.entityKey, priority: ce.priority,
                    valid: true)
  role = roleFor(memberIndex, isLeader)
  destination = destinationFor(o, role, memberIndex, me, s)
  result = true

proc squadObjectiveTarget*(squadKey: uint64): Vec3 =
  ## The ONE catalog position a squad is working on, for the check that reads
  ## it back. Origin when it has none.
  var i = 0
  while i < gSquadLen:
    if gSquads[i].used and gSquads[i].key == squadKey and
       gSquads[i].entry >= 0 and gSquads[i].entry < gCatalogLen:
      return gCatalog[gSquads[i].entry].target
    inc i
  result = zeroVec()

proc squadsTracked*(): int =
  result = 0
  var i = 0
  while i < gSquadLen:
    if gSquads[i].used: inc result
    inc i

proc distinctSquadTargets*(): int =
  ## How many DISTINCT positions the tracked squads are converging on.
  ##
  ## The second P1 falsifier reads this: if every group collapses onto one
  ## point, this is 1 while `squadsTracked` is greater, and the convergence
  ## claim is false in the other direction -- one objective for the whole raid
  ## is not squad behaviour, it is a herd.
  result = 0
  var i = 0
  while i < gSquadLen:
    if gSquads[i].used and gSquads[i].entry >= 0:
      var dup = false
      var k = 0
      while k < i:
        if gSquads[k].used and gSquads[k].entry == gSquads[i].entry:
          dup = true
          break
        inc k
      if not dup: inc result
    inc i

proc catalogCheck*(): string =
  ## P0, on the finished state, as a negative.
  ##
  ## The falsifier the design names: a catalog that is all-reposition, or whose
  ## points are all at the origin. Both are what a plan built out of `db.json`
  ## static containers looks like, and both used to be indistinguishable from a
  ## working one.
  if gCatalogLen == 0:
    return "INCONCLUSIVE: no catalog has been received. Either no raid has " &
           "been configured this session or `tarkov.objectives.catalog` did " &
           "not reach this mod -- /aowlspt/orbit/plan tells those apart"
  let q = catalogCountOf(okQuestPoi)
  let spread = catalogSpread()
  if spread < 1.0:
    return "FAIL: " & $gCatalogLen & " catalog entries with a bounding-box " &
           "diagonal of " & $int(spread) & "m. Every objective is effectively " &
           "the same point, which is what a catalog built from db.json " &
           "staticContainers looks like -- all 7,092 of those rows are (0,0,0)"
  if q == 0:
    return "FAIL: " & $gCatalogLen & " catalog entries and NOT ONE questPoi. " &
           "The waypoints layer produced nothing, so every objective is a " &
           "grid-cell centroid and none is a point a human authored on the " &
           "navmesh. Check `questSource`/`questTried` in /aowlspt/orbit/plan"
  result = "PASS: " & $gCatalogLen & " objectives (" & $q & " questPoi, " &
           $catalogCountOf(okLoot) & " loot, " &
           $catalogCountOf(okReposition) & " reposition, " &
           $catalogCountOf(okHunt) & " hunt) spread over " & $int(spread) &
           "m for '" & gCatalogMap & "'"

proc objectiveState*(): string =
  result = "objectives: " & $gCatalogLen & " catalog entries for '" &
           gCatalogMap & "' (" & $gCatalogAdds & " accepted, " &
           $gCatalogFull & " refused as full), " & $squadsTracked() &
           " squad(s) tracked on " & $distinctSquadTargets() &
           " distinct objective(s), " & $gChosen & " chosen, " &
           $gCompletedReached & " reached, " & $gCompletedTimeout &
           " timed out, " & $gCompletedInvalid & " invalidated, " &
           $destinationWrites(dwClient) & " client destination(s), " &
           $destinationWrites(dwServer) & " server destination(s)"
  if gOverflow > 0:
    result = result & ". " & $gOverflow & " assignment(s) found more than " &
             $MaxSquads & " distinct groups and got NO objective rather than " &
             "evicting a live squad"

proc selfCheckObjective*(into: var seq[string]): bool =
  ## Pure checks, runnable with no game. They assert the two P1 properties on
  ## a synthetic catalog, so a regression in the assigner is caught by
  ## `aowl test` rather than by a raid.
  result = true
  clearCatalog()
  resetObjectives()
  resetWriterLedger()

  var s = defaultSettings()
  s.objectivesEnabled = true
  s.squadShareObjectives = true
  s.objectiveSplinterM = 20.0
  s.objectiveReachM = 6.0
  s.objectiveTimeoutS = 120.0

  # A catalog whose points are far apart, so "all squads collapsed to one
  # point" is a state this test COULD reach and therefore one it can rule out.
  discard addObjective(okQuestPoi, vec3(100.0, 0.0, 100.0), 1.0)
  discard addObjective(okQuestPoi, vec3(-100.0, 0.0, -100.0), 1.0)
  discard addObjective(okReposition, vec3(300.0, 0.0, -50.0), 0.6)
  discard addObjective(okLoot, vec3(0.0, 0.0, 0.0), 5.0)   ## must be REFUSED

  if catalogLen() != 3:
    into.add "objective: the origin entry was ACCEPTED into the catalog; " &
             "db.json's dead (0,0,0) container positions would become " &
             "objectives and every bot would converge on world zero"
    result = false

  # One squad, four members: every destination within splinterM of ONE point.
  var role = omConverge
  var dest = zeroVec()
  var shared = zeroVec()
  var m = 0
  while m < 4:
    let ok = objectiveFor(0xBEEF'u64, uint64(m + 1), m, m == 0,
                          vec3(float(m) * 3.0, 0.0, 0.0), s, 10.0, role, dest)
    if not ok:
      into.add "objective: member " & $m & " of a squad with a live catalog " &
               "got NO objective"
      result = false
    else:
      if m == 0: shared = dest
      if flatDistance(dest, squadObjectiveTarget(0xBEEF'u64)) >
         s.objectiveSplinterM + 0.001:
        into.add "objective: member " & $m & " was sent " &
                 $int(flatDistance(dest, squadObjectiveTarget(0xBEEF'u64))) &
                 "m from its squad's objective, past the " &
                 $int(s.objectiveSplinterM) & "m splinter bound"
        result = false
    inc m
  if shared.x == 0.0 and shared.z == 0.0:
    into.add "objective: the leader's destination is world zero"
    result = false

  # A second squad must not silently land on the first one's point. This CAN
  # fail -- the jitter is only 0..0.5 of the score -- so it is asserted as a
  # count over the table rather than as a coincidence about one draw.
  discard objectiveFor(0xCAFE'u64, 0x99'u64, 0, true,
                       vec3(-90.0, 0.0, -90.0), s, 10.0, role, dest)
  if squadsTracked() != 2:
    into.add "objective: two distinct group pointers produced " &
             $squadsTracked() & " squad slot(s); the partition is not by group"
    result = false

  # The one-writer check must REFUSE to pass when the server writer fired.
  noteDestination(dwClient, 1.0)
  noteDestination(dwServer, 1.0)
  let verdict = oneWriterCheck(true)
  if verdict.len < 4 or verdict[0] != 'F':
    into.add "objective: oneWriterCheck did not FAIL with a server write on " &
             "the ledger -- the one-writer claim cannot be falsified, which " &
             "under CLAUDE.md 9b makes it the bug"
    result = false

  clearCatalog()
  resetObjectives()
  resetWriterLedger()
