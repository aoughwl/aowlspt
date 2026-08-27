## ORBIT's HIGH-LEVEL half: where the bots on this map should want to be.
##
## ## What this is a reimplementation of, and what it is not
##
## ORBIT (github.com/Chazut/ORBIT, MIT) is an SPT bot-AI mod. Its README is
## explicit that it "operates entirely client-side ... there is no server
## component": it is a BepInEx C# plugin that builds its cell grid by walking
## the LOADED SCENE, then hands per-bot goals to BigBrain layers.
##
## We cannot do that half. Post-1.0 EFT is IL2CPP, there is no BepInEx, and
## every by-NAME route into the runtime is fatal the moment it is USED (facts
## #143/#144/#145). So the split is not a stylistic preference: the part of
## ORBIT that is a SCENE SCAN is re-derived here from `db.json`, which the
## backend already owns, and the part that is a PER-BOT ORDER goes out over
## `aowlspt/botnav` from `mods/sain`.
##
## Nothing was copied. ORBIT is C#; this is nimony; the licence (MIT) would
## permit copying with attribution and there is nothing to copy anyway. The
## LOGIC that is reimplemented here is: the cell grid, the primary anchor and
## its splinter targets, the per-personality coverage roll, the personality
## distribution, and the loot-value gates. See `README.md`.
##
## ## What positional data this server actually has -- MEASURED, and it is less
## ## than it looks
##
## The plan was designed around two layers. Only one of them exists.
##
##   locations.<map>.base.SpawnPointParams               318 rows on Customs,
##     each `{Position:{x,y,z}, Categories:[...], Sides:[...], BotZoneName}`
##     -- REAL world coordinates. 273 of the 318 carry a non-zero position and
##     a `Categories` array, and that is the whole positional layer this
##     backend owns.
##
##   locations.<map>.staticContainers.staticContainers   552 rows on Customs,
##     each `{probability, template:{Id, Position:{x,y,z}, Items, ...}}`
##     -- and **every single `Position` is `{"x":0,"y":0,"z":0}`**. Measured
##     over the live 41 MB `db.json` at rows 0, 1, 50, 200, 400 and 551, and
##     confirmed end to end by this module: 552 rows read, 0 survived the
##     position filter. `staticWeapons[0].Position` is zero too. The container
##     layer is a LOOT TABLE keyed by `Id`; the client resolves the id against
##     the scene and the server never needed the coordinate, so the field is
##     shipped as a zero placeholder.
##
## This was caught by the CHECK rather than by reading the data, and only
## because the check counts loot anchors SEPARATELY. The first run produced six
## anchors, a 587 m by 292 m spread and a PASS -- a completely plausible plan
## with the entire loot layer missing from it. `tools/bigjson.py --width 60`
## had clipped the row before the `Position` member, so the zeros were not
## visible from the tool either.
##
## **Consequence, stated plainly: there is no server-side loot-density field on
## this build.** ORBIT loot cells cannot be reproduced here from the database.
## The container reader below is kept -- it is correct, and a future `db.json`
## that carries real positions would light it up with no change -- but it
## produces nothing today and the plan says so rather than shipping an empty
## layer as a supported one.
##
## What IS left is the spawn-point layer, split two ways: points a HUMAN may
## enter on (`Categories` contains "Player") are the closest thing to ORBIT
## contested-ground hotspots, and points a BOT may enter on (`Categories`
## contains "Bot") are roam anchors spread over the playable area. Both are
## real coordinates on real navmesh -- they are where the game itself puts
## people -- which makes them better `GoToPoint` targets than a centroid of
## container positions would have been anyway.
##
## ## What is NOT expressible on this build, stated rather than faked
##
## * **Quest-location objectives.** ORBIT routes bots to real quest markers.
##   `locations.<map>.base` carries no quest marker positions, and quest
##   conditions in `db.json` name ZONES (`"zoneId"`), not coordinates. There is
##   no positional quest layer here, so this plan emits none. It does not emit
##   an empty one and call it supported.
## * **Extract destinations.** `base.exits[*]` has `Name`, `EntryPoints`,
##   `ExfiltrationTime` -- and NO position field at all. So the extract
##   *policy* (when a squad should leave) is expressible and is emitted; the
##   *place* is not, and `mods/sain` says so at the same point its own
##   `cdExtract` already did.
## * **Looting itself.** Picking an item up needs `Player.HandsController` and
##   an inventory operation on a live bot. `aowlspt/botnav` exposes exactly
##   `GoToPoint`, `SetTargetMoveSpeed` and `stop`. So the value gates below are
##   emitted as POLICY -- they select which anchors a bot bothers to walk to --
##   and no bot picks anything up. That is the honest ceiling and it is not
##   moved by more code on this side.
##
## ## The cell height problem, named because it is a real defect
##
## Cells are binned on (x, z) with y IGNORED. On Interchange and Labs that
## merges floors: a dense ground-floor cell and the mall level above it score
## as one. The anchor is then a probability-weighted CENTROID of the containers
## in the cell, which lands somewhere between the two floors and may be inside
## geometry. `GoToPoint` answers that honestly -- `navStatus == 2`, no path --
## and the dispatcher on the other side drops the anchor for that bot rather
## than retrying. So the failure is announced, not silent, but it IS a failure
## and a y-band in the key would fix it.

import aowlspt
import aowlspt/server
import aowlspt/json
import raid

const
  MaxCells* = 512
    ## Cells kept while binning. A bound, not a limit: Customs at 50 m is about
    ## 90 occupied cells. A map whose coordinates are corrupt must not turn this
    ## into an unbounded table.
  MaxContainers* = 4096
    ## Rows walked out of `staticContainers`. Customs has 552; Streets is the
    ## largest and is well under this.
  MaxSpawnPoints* = 2048
  MaxAnchors* = 24
    ## Anchors emitted. The dispatcher tracks 32 bots and gives each one a
    ## primary plus splinters, so more anchors than this buys nothing and makes
    ## the plan payload larger for no behaviour.

type
  AnchorKind* = enum
    akLoot          ## a cell dense in static containers. NEVER PRODUCED on
                    ## this build: every container Position in db.json is
                    ## (0,0,0). See the header.
    akPvp           ## a cell dense in player-eligible spawn points
    akRoam          ## a cell dense in bot-eligible spawn points

  Anchor* = object
    kind*: AnchorKind
    x*, y*, z*: float
    score*: float
    cx*, cz*: int

  OrbitPlan* = object
    ok*: bool
    map*: string
    cellSize*: float
    anchors*: seq[Anchor]
    containersSeen*: int
    containerRows*: int      ## rows the database actually handed back
    spawnPointsSeen*: int
    spawnRows*: int
    why*: string      ## why `ok` is false, when it is

  Cell = object
    used: bool
    cx, cz: int
    score: float
    sx, sy, sz: float   ## score-weighted position sum

# The cell tables live at module scope rather than on the stack of `buildPlan`.
# Two reasons, and the second is the one that matters: nimony refuses a local
# array it cannot prove initialised, and a 512-entry table is not something to
# put on a stack frame on a loading screen. They are reused per raid; only the
# `used` counter needs resetting, because `bump` fully assigns every row it
# claims and nothing ever reads past `used`.
var
  gLootCells: array[MaxCells, Cell]
  gPvpCells: array[MaxCells, Cell]
  gRoamCells: array[MaxCells, Cell]
  gCheckCells: array[MaxCells, Cell]
    ## The self-check's own table, kept separate so that running the check can
    ## never disturb a plan that is live.

# ---------------------------------------------------------------------------
# Config -- the whole high-level policy surface, flat keys in config.json
# ---------------------------------------------------------------------------
#
# Flat rather than an `"orbit": {...}` block on purpose: `setting()` resolves a
# key through three different hosts and only a top-level key is known to behave
# the same on all three. A nested read that silently returns the default on one
# host is exactly the "setting that changes nothing" this repo keeps shipping.

proc orbitEnabled*(): bool = setting("orbitEnabled").asBool(true)
proc orbitCellSize*(): float = setting("orbitCellSize").asFloat(50.0)
proc orbitLootAnchors*(): int = setting("orbitLootAnchors").asInt(12)
proc orbitPvpAnchors*(): int = setting("orbitPvpAnchors").asInt(6)
proc orbitLeashM*(): float = setting("orbitLeashM").asFloat(45.0)
proc orbitSplinterM*(): float = setting("orbitSplinterM").asFloat(90.0)
proc orbitReachM*(): float = setting("orbitReachM").asFloat(8.0)
proc orbitHoldMs*(): int = setting("orbitHoldMs").asInt(30000)
proc orbitExtractFraction*(): float =
  setting("orbitExtractFraction").asFloat(0.75)

proc clampf(v, lo, hi: float): float =
  if v < lo: lo elif v > hi: hi else: v

proc floorDiv(v: float; cell: float): int =
  ## Bin index that is correct for negative coordinates. `int(-3.2)` truncates
  ## toward zero in nimony, so `int(x / cell)` puts -10 m and +10 m in the SAME
  ## cell 0 at a 50 m grid -- a map's whole western half folded onto its
  ## eastern half, which reads as "the anchors are all in the middle".
  let q = v / cell
  var i = int(q)
  if q < 0.0 and float(i) != q:
    dec i
  result = i

# ---------------------------------------------------------------------------
# Binning
# ---------------------------------------------------------------------------

proc bump(cells: var array[MaxCells, Cell]; used: var int;
          cx, cz: int; x, y, z, score: float) =
  var i = 0
  while i < used:
    if cells[i].used and cells[i].cx == cx and cells[i].cz == cz:
      cells[i].score = cells[i].score + score
      cells[i].sx = cells[i].sx + x * score
      cells[i].sy = cells[i].sy + y * score
      cells[i].sz = cells[i].sz + z * score
      return
    inc i
  if used >= MaxCells:
    return
  cells[used] = Cell(used: true, cx: cx, cz: cz, score: score,
                     sx: x * score, sy: y * score, sz: z * score)
  inc used

proc topInto(cells: var array[MaxCells, Cell]; used: int; want: int;
             kind: AnchorKind; into: var seq[Anchor]) =
  ## Selection sort by score, `want` times, marking each taken cell consumed.
  ## Selection rather than a full sort because `want` is 6..12 and `used` is
  ## about 90: two nested bounded loops beat introducing a sort dependency.
  var taken = 0
  while taken < want and into.len < MaxAnchors:
    var best = -1
    var bestScore = 0.0
    var i = 0
    while i < used:
      if cells[i].used and cells[i].score > bestScore:
        best = i
        bestScore = cells[i].score
      inc i
    if best < 0:
      return
    let c = cells[best]
    cells[best].used = false
    # The anchor is the score-weighted CENTROID of the things in the cell, not
    # the cell's centre. A cell centre is an arbitrary point on a grid nobody
    # built the map to; a centroid of container positions is at least near
    # something a bot can stand next to. See the header on why this is still
    # not sufficient on a multi-storey map.
    if c.score <= 0.0:
      return
    # Cross-LAYER de-duplication. A spawn point whose `Categories` names both
    # "Player" and "Bot" -- most of them on Customs -- bins into the pvp table
    # AND the roam table, so the same cell was emitted twice with two kinds.
    # Two anchors at one point waste the dispatcher's budget and make
    # "arrived" ambiguous, and the check caught it: `anchors 0 and 6 are the
    # same point`. First layer to claim a cell keeps it.
    var dup = false
    var d = 0
    while d < into.len:
      if into[d].cx == c.cx and into[d].cz == c.cz:
        dup = true
        break
      inc d
    if dup:
      continue
    into.add Anchor(kind: kind, x: c.sx / c.score, y: c.sy / c.score,
                    z: c.sz / c.score, score: c.score, cx: c.cx, cz: c.cz)
    inc taken

proc hasText(j: JsonRef; want: string): bool =
  ## Does this JSON array contain the string `want`? Used for `Categories` and
  ## `Sides`, both of which are short arrays of short strings.
  let n = count(j)
  var i = 0
  while i < n and i < 16:
    if asText(at(j, i), "") == want:
      return true
    inc i
  result = false

# ---------------------------------------------------------------------------
# The plan
# ---------------------------------------------------------------------------

proc buildPlan*(locationId: string): OrbitPlan =
  ## Read the map's two positional layers out of the database and reduce them
  ## to anchors. Called once per raid, off the raid-configured path.
  # THE MAP KEY, not the name the client said. The client sends `base.Id`
  # ("Interchange", "Woods"); `db.json` keys its `locations` table by the SPT
  # directory ("interchange", "bigmap"). Reading `locations.<clientId>`
  # directly found NOTHING on 13 of 19 maps and this code reported that as
  # "a map with no positional data here" -- a confidently wrong diagnosis of a
  # database that has 3,762 spawn points across 24 locations. It is the same
  # defect that served empty loot on ten of thirteen maps.
  #
  # `canonicalLocation` (emu/raid) is the ONE resolver: key -> `_Id` -> `Id` ->
  # case-insensitive, with post-1.0 VARIANTS (Sandbox_start, Lighthouse2, ...)
  # reaching their parent through the shared `Name`. Do not add a second one
  # here and do not special-case a map by name.
  let key = canonicalLocation(locationId)
  result = OrbitPlan(ok: false, map: locationId, cellSize: orbitCellSize(),
                     anchors: @[], containersSeen: 0, containerRows: 0,
                     spawnPointsSeen: 0, spawnRows: 0, why: "")
  let cell = clampf(result.cellSize, 5.0, 500.0)
  result.cellSize = cell

  var lootUsed = 0
  var pvpUsed = 0
  var roamUsed = 0

  let cont = dbRead("locations." & key &
                    ".staticContainers.staticContainers")
  if cont.ok:
    let list = whole(cont.raw)
    let n = count(list)
    result.containerRows = n
    var i = 0
    while i < n and i < MaxContainers:
      let row = at(list, i)
      # Two single-key steps, not the dotted path `template.Position`.
      # MEASURED: the dotted form returned not-found for all 552 rows of
      # Customs while the single-key form on the same JsonRef returns the
      # object -- `containerRows` 552, `containersSeen` 0, every anchor a
      # spawn point. The plan looked plausible and had no loot layer in it at
      # all, which is why `orbitCheck` now counts loot anchors separately.
      let tpl = field(row, "template")
      let pos = field(tpl, "Position")
      if exists(pos):
        let x = asFloat(field(pos, "x"), 0.0)
        let y = asFloat(field(pos, "y"), 0.0)
        let z = asFloat(field(pos, "z"), 0.0)
        # A probability of 0 is a container that never spawns; it must not pull
        # the centroid, and it must not count as density.
        let p = clampf(asFloat(field(row, "probability"), 0.0), 0.0, 1.0)
        if p > 0.0 and (x != 0.0 or z != 0.0):
          inc result.containersSeen
          bump(gLootCells, lootUsed, floorDiv(x, cell), floorDiv(z, cell),
               x, y, z, p)
      inc i

  let sp = dbRead("locations." & key & ".base.SpawnPointParams")
  if sp.ok:
    let list = whole(sp.raw)
    let n = count(list)
    result.spawnRows = n
    var i = 0
    while i < n and i < MaxSpawnPoints:
      let row = at(list, i)
      let cats = field(row, "Categories")
      # "Player" is the category the game marks a point a HUMAN may enter on.
      # Contested ground is where humans arrive, which is the closest thing the
      # database has to ORBIT's PvP hotspot; ORBIT gets the same idea from
      # engagement telemetry it collects in the scene, which we have none of.
      let pos = field(row, "Position")
      if exists(cats) and exists(pos):
        let x = asFloat(field(pos, "x"), 0.0)
        let y = asFloat(field(pos, "y"), 0.0)
        let z = asFloat(field(pos, "z"), 0.0)
        if x != 0.0 or z != 0.0:
          var counted = false
          if hasText(cats, "Player"):
            counted = true
            bump(gPvpCells, pvpUsed, floorDiv(x, cell), floorDiv(z, cell),
                 x, y, z, 1.0)
          if hasText(cats, "Bot"):
            counted = true
            bump(gRoamCells, roamUsed, floorDiv(x, cell), floorDiv(z, cell),
                 x, y, z, 1.0)
          if counted:
            inc result.spawnPointsSeen
      inc i

  if result.containerRows > 0 and result.containersSeen == 0:
    # Say WHAT was in the row rather than that nothing was. A layer that reads
    # zero of 552 rows is a parse mismatch, and a parse mismatch is only
    # diagnosable from the bytes.
    let row0 = at(whole(cont.raw), 0)
    var head = raw(row0)
    if head.len > 200:
      head = head.substr(0, 200)
    result.why = "0 of " & $result.containerRows &
                 " static-container rows parsed. First row begins: " & head
    warn "orbit: " & result.why
  topInto(gLootCells, lootUsed, orbitLootAnchors(), akLoot, result.anchors)
  topInto(gPvpCells, pvpUsed, orbitPvpAnchors(), akPvp, result.anchors)
  # Roam anchors fill whatever the other two layers left. With the loot layer
  # producing nothing on this build that is most of the budget, and it is spent
  # on the only other real coordinates the database has.
  topInto(gRoamCells, roamUsed, orbitLootAnchors(), akRoam, result.anchors)

  if result.anchors.len == 0:
    # Name BOTH ids. "no data for 'Interchange'" and "no data for
    # 'interchange'" are different bugs and the old message could not tell
    # them apart: the first is an unresolved id, the second a genuinely
    # empty map.
    result.why = "no anchor could be built for '" & locationId &
                 "' (database key '" &
                 (if key.len > 0: key else: "<unresolved>") & "'): " &
                 $result.containersSeen & " usable containers and " &
                 $result.spawnPointsSeen & " player spawn points were read " &
                 "from the database. This is a map with no positional data " &
                 "here, not a map with no loot"
    return
  result.ok = true

# ---------------------------------------------------------------------------
# The wire shape
# ---------------------------------------------------------------------------

proc kindName(k: AnchorKind): string =
  case k
  of akLoot: "loot"
  of akPvp: "pvp"
  of akRoam: "roam"

proc planJson*(p: OrbitPlan): string =
  ## The plan as it goes on the bus, and as `/aowlspt/orbit/plan` serves it.
  ##
  ## The personality distribution, the coverage rolls and the loot-value gates
  ## ride here rather than being read again on the sain side, and that is the
  ## split doing its job: `mods/sain` is the ACTUATOR, and an actuator that
  ## re-reads policy has two places to change a number in.
  var o = obj()
  put(o, "ok", p.ok)
  put(o, "map", p.map)
  put(o, "cellSize", p.cellSize)
  put(o, "containersSeen", p.containersSeen)
  put(o, "containerRows", p.containerRows)
  put(o, "spawnPointsSeen", p.spawnPointsSeen)
  put(o, "spawnRows", p.spawnRows)
  if p.why.len > 0:
    put(o, "why", p.why)

  var a = arr()
  var i = 0
  while i < p.anchors.len:
    let an = p.anchors[i]
    var e = obj()
    put(e, "kind", kindName(an.kind))
    put(e, "x", an.x)
    put(e, "y", an.y)
    put(e, "z", an.z)
    put(e, "score", an.score)
    a.add e
    inc i
  put(o, "anchors", a)

  # Movement policy: the numbers the dispatcher needs and must not invent.
  var m = obj()
  put(m, "leashM", orbitLeashM())
  put(m, "splinterM", orbitSplinterM())
  put(m, "reachM", orbitReachM())
  put(m, "holdMs", orbitHoldMs())
  put(o, "movement", m)

  # ORBIT's personality distribution. These are its published defaults,
  # renormalised to sum to 1.0. The sain side draws from this deterministically
  # per bot id, because the game never tells us a bot's SAIN personality --
  # there is no SAIN running in the client at all on this build.
  var pers = obj()
  put(pers, "rat", setting("orbitPersonalityRat").asFloat(0.15))
  put(pers, "coward", setting("orbitPersonalityCoward").asFloat(0.10))
  put(pers, "normal", setting("orbitPersonalityNormal").asFloat(0.45))
  put(pers, "chad", setting("orbitPersonalityChad").asFloat(0.20))
  put(pers, "gigachad", setting("orbitPersonalityGigaChad").asFloat(0.05))
  put(pers, "timmy", setting("orbitPersonalityTimmy").asFloat(0.05))
  put(o, "personality", pers)

  # ORBIT's coverage roll: the chance a bot BOTHERS with a POI it has reached
  # the cell of. Its whole point is that a 100% vacuum reads as inhuman, so a
  # cautious bot clears nearly everything and a gigachad walks past most of it.
  var cov = obj()
  put(cov, "rat", setting("orbitCoverageRat").asFloat(0.90))
  put(cov, "coward", setting("orbitCoverageCoward").asFloat(0.90))
  put(cov, "normal", setting("orbitCoverageNormal").asFloat(0.70))
  put(cov, "chad", setting("orbitCoverageChad").asFloat(0.55))
  put(cov, "gigachad", setting("orbitCoverageGigaChad").asFloat(0.38))
  put(cov, "timmy", setting("orbitCoverageTimmy").asFloat(0.80))
  put(o, "coverage", cov)

  # ORBIT's per-personality value gates, in roubles per inventory slot. NOTHING
  # ON THIS BUILD PICKS AN ITEM UP -- `aowlspt/botnav` has no inventory verb --
  # so these are carried for the one thing they CAN still do: bias which
  # anchors a bot walks to, by requiring a loot cell's density to clear the
  # bot's own gate. Emitted with that meaning and no other.
  var val = obj()
  put(val, "rat", setting("orbitValueRat").asInt(5000))
  put(val, "coward", setting("orbitValueCoward").asInt(5000))
  put(val, "normal", setting("orbitValueNormal").asInt(10000))
  put(val, "chad", setting("orbitValueChad").asInt(15000))
  put(val, "gigachad", setting("orbitValueGigaChad").asInt(20000))
  put(val, "timmy", setting("orbitValueTimmy").asInt(0))
  put(o, "lootValue", val)

  # ORBIT's extract layer, minus its destination. See the header.
  var ex = obj()
  put(ex, "raidFractionElapsed", clampf(orbitExtractFraction(), 0.0, 1.0))
  put(ex, "destinationKnown", false)
  put(ex, "why", "locations.<map>.base.exits carries Name, EntryPoints and " &
      "ExfiltrationTime and NO position. There is nowhere to send a bot, so " &
      "no extract order is issued and none is faked")
  put(o, "extract", ex)

  result = done(o).text

# ---------------------------------------------------------------------------
# Emission and the check
# ---------------------------------------------------------------------------

var gLastPlan = ""
var gLastMap = ""
var gPlans = 0

proc emitPlan*(locationId: string) =
  ## Build and broadcast the plan for a raid that is starting.
  ##
  ## Broadcast rather than served-and-polled, for the same reason the bot census
  ## is: the value changes exactly once per raid, so a poller would spin.
  if not orbitEnabled():
    return
  if locationId.len == 0:
    return
  let p = buildPlan(locationId)
  gLastPlan = planJson(p)
  gLastMap = locationId
  inc gPlans
  if not p.ok:
    warn "orbit: " & p.why
  else:
    info "orbit: plan for " & locationId & " -- " & $p.anchors.len &
         " anchors from " & $p.containersSeen & " containers and " &
         $p.spawnPointsSeen & " player spawn points at " &
         $int(p.cellSize) & "m cells"
  discard broadcast("tarkov.orbit.plan", gLastPlan)

proc lastPlanJson*(): string =
  if gLastPlan.len == 0:
    return "{\"ok\":false,\"why\":\"no raid has been configured this session, " &
           "so no plan has been built. This is not a failure to build one\"}"
  result = gLastPlan

proc orbitCheck*(): string =
  ## PASS / FAIL / INCONCLUSIVE on the FINISHED PLAN, asserted as negatives.
  ##
  ## What would falsify each: a grid whose `floorDiv` truncated toward zero
  ## folds the map's negative half onto its positive half and every anchor
  ## lands in one quadrant -- caught by the spread test. A centroid computed
  ## with a zero weight sum produces (0,0,0) -- caught by the origin test. A
  ## selection sort that failed to consume its pick emits the same cell twice
  ## -- caught by the duplicate test. None of these can be produced by
  ## re-reading what this file just wrote, which is why they are the check.
  if gPlans == 0:
    return "INCONCLUSIVE: no raid configured this session, so no plan was " &
           "built and there is nothing to look at"
  let j = whole(gLastPlan)
  if not asBool(field(j, "ok"), false):
    return "FAIL: the last plan for '" & gLastMap & "' has ok=false: " &
           asText(field(j, "why"), "(no reason recorded, which is itself a bug)")
  let anchors = field(j, "anchors")
  let n = count(anchors)
  if n < 2:
    return "INCONCLUSIVE: only " & $n & " anchor was produced for '" &
           gLastMap & "'; two are needed before spread or duplication can " &
           "be tested"
  var minX = 1.0e9
  var maxX = -1.0e9
  var minZ = 1.0e9
  var maxZ = -1.0e9
  var i = 0
  while i < n:
    let a = at(anchors, i)
    let x = asFloat(field(a, "x"), 0.0)
    let z = asFloat(field(a, "z"), 0.0)
    let y = asFloat(field(a, "y"), 0.0)
    if x == 0.0 and y == 0.0 and z == 0.0:
      return "FAIL: anchor " & $i & " for '" & gLastMap &
             "' is at the world origin, which is what a centroid divided by " &
             "a zero score looks like"
    var k = i + 1
    while k < n:
      let b = at(anchors, k)
      if asFloat(field(b, "x"), 0.0) == x and
         asFloat(field(b, "z"), 0.0) == z:
        return "FAIL: anchors " & $i & " and " & $k & " for '" & gLastMap &
               "' are the same point; the cell selection is emitting one " &
               "cell twice"
      inc k
    if x < minX: minX = x
    if x > maxX: maxX = x
    if z < minZ: minZ = z
    if z > maxZ: maxZ = z
    inc i
  # A plan made entirely of PvP anchors is not a working plan: the loot layer
  # is ORBIT's primary objective type, and a check that passed without it is a
  # check that cannot fail on the exact defect this had on its first run --
  # `containerRows` came back 552 and `containersSeen` 0, and every anchor was
  # a spawn point. Counted as its own outcome rather than folded into the
  # spread test, because "the container layer did not parse" and "the grid
  # collapsed" need different fixes.
  var lootAnchors = 0
  var q = 0
  while q < n:
    if asText(field(at(anchors, q), "kind"), "") == "loot":
      inc lootAnchors
    inc q
  let cRows = asInt(field(j, "containerRows"), 0)
  let cSeen = asInt(field(j, "containersSeen"), 0)
  if lootAnchors == 0 and cSeen > 0:
    return "FAIL: " & $cSeen & " static containers were read for '" &
           gLastMap & "' and NOT ONE became a loot anchor. The binning or " &
           "the selection is dropping them"
  var lootNote = ""
  if lootAnchors == 0:
    lootNote = " NO LOOT LAYER: " & $cRows & " container rows were read and " &
               "0 carried a non-zero Position. That is a measured property " &
               "of this db.json -- every staticContainers Position is " &
               "(0,0,0) -- and not a defect here; see emu/orbit.nim's header."
  let cell = asFloat(field(j, "cellSize"), 50.0)
  if (maxX - minX) < cell and (maxZ - minZ) < cell:
    return "FAIL: all " & $n & " anchors for '" & gLastMap &
           "' fit inside one " & $int(cell) & "m cell (x spread " &
           $int(maxX - minX) & "m, z spread " & $int(maxZ - minZ) &
           "m). A whole map's objectives in one cell is what a binning " &
           "function that truncates toward zero produces"
  result = "PASS: " & $n & " anchors for '" & gLastMap &
           "', all distinct, none at the origin, spread " &
           $int(maxX - minX) & "m by " & $int(maxZ - minZ) &
           "m across a " & $int(cell) & "m grid. This proves the PLAN is " &
           "well formed; it does NOT prove a bot ever walked to one -- that " &
           "is `/sain/status`'s dispatchCheck, in a raid, with botNav on." & lootNote

proc orbitState*(): string =
  result = "orbit: " & $gPlans & " plan(s), last '" & gLastMap & "'"

# ---------------------------------------------------------------------------
# Offline self-check
# ---------------------------------------------------------------------------

proc selfCheckOrbit*(into: var seq[string]): bool =
  ## Runs without a raid and without a client: the binning function is pure
  ## arithmetic and its one historical defect is testable at the desk.
  result = true
  if floorDiv(-10.0, 50.0) == floorDiv(10.0, 50.0):
    into.add "orbit: floorDiv puts -10 and +10 in the same 50m cell; the " &
             "western half of every map folds onto the eastern half"
    result = false
  if floorDiv(-50.0, 50.0) != -1:
    into.add "orbit: floorDiv(-50, 50) is " & $floorDiv(-50.0, 50.0) &
             ", expected -1"
    result = false
  if floorDiv(49.0, 50.0) != 0 or floorDiv(50.0, 50.0) != 1:
    into.add "orbit: floorDiv is off by one at a cell boundary"
    result = false
  var used = 0
  bump(gCheckCells, used, 0, 0, 10.0, 1.0, 10.0, 0.5)
  bump(gCheckCells, used, 0, 0, 30.0, 1.0, 30.0, 0.5)
  bump(gCheckCells, used, 1, 0, 60.0, 1.0, 0.0, 0.25)
  if used != 2:
    into.add "orbit: two positions in one cell produced " & $used & " cells"
    result = false
  var got: seq[Anchor] = @[]
  topInto(gCheckCells, used, 4, akLoot, got)
  if got.len != 2:
    into.add "orbit: topInto returned " & $got.len &
             " anchors from 2 cells; it is emitting a cell more than once"
    result = false
  elif got[0].x != 20.0 or got[0].z != 20.0:
    into.add "orbit: the dense cell's anchor is at " & $got[0].x & "," &
             $got[0].z & "; the weighted centroid of (10,10) and (30,30) at " &
             "equal weight is (20,20)"
    result = false
