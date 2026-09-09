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

import std/syncio
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
  MaxQuestPoints* = 4096
    ## Patrol points walked out of one `mods/waypoints/data/<key>.json`.
    ## MEASURED over all ten shipped files: 8,556 points total, largest single
    ## map 2,408 (Customs / `bigmap`). This bound is headroom, not a limit --
    ## but a corrupt file must not turn the walk into an unbounded loop.
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
    akQuestPoi      ## a cell dense in SPT-Waypoints PATROL points. These are
                    ## the only anchor source in this file whose coordinates
                    ## were authored ON the navmesh by a human, rather than
                    ## being a centroid of a grid cell -- see `questLayer`.

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
    questPointsSeen*: int    ## patrol points binned out of the waypoints file
    questZones*: int         ## zones the file carried
    questSource*: string     ## the path that was READ, or "" if none was
    questTried*: string      ## every path tried, when none of them opened
    why*: string      ## why `ok` is false, when it is

  ContainerCensus* = object
    ## What the loot-table walker actually SAW, counted per rejection reason.
    ##
    ## This exists because the old diagnostic said "0 of 429 static-container
    ## rows parsed", which is false and was read as a parser bug by everyone
    ## who saw it. The rows parse perfectly: 429 of 429 carry `template`, 429
    ## of 429 carry `template.Position`. Every one of those positions is
    ## `(0,0,0)` -- MEASURED here, in `D:\Aowlspt\aowlspt\db.json` AND in the
    ## SPT source it was imported from
    ## (`SPT_Data\database\locations\woods\staticContainers.json`), on all 13
    ## maps that have the table: 0 rows with a non-zero x or z, out of 7,092.
    ## A count of rejections per REASON cannot say "did not parse" about a row
    ## it read three fields out of.
    map*: string      ## the id we were asked about
    key*: string      ## the database key `canonicalLocation` resolved it to
    rows*: int        ## rows the tables handed back
    withTemplate*: int      ## rows carrying `template`
    withPosition*: int      ## ... and `template.Position`
    positioned*: int        ## ... whose x or z is non-zero
    zeroProbability*: int   ## positioned, but `probability` <= 0
    usable*: int            ## positioned and spawnable: what binning gets
    tables*: string   ## which db tables were read, and their row counts

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
  gQuestCells: array[MaxCells, Cell]
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
proc orbitQuestPoi*(): bool = setting("orbitQuestPoi").asBool(true)
proc orbitQuestAnchors*(): int = setting("orbitQuestAnchors").asInt(8)
proc orbitQuestBias*(): float = setting("orbitQuestBias").asFloat(1.25)
  ## How much a quest POI outweighs the best spawn-derived anchor AFTER the
  ## quest layer has been rescaled onto the same scale. Not a raw multiplier on
  ## the raw score: the two layers count different things (patrol points per
  ## cell runs to the hundreds, spawn points per cell to single digits), so a
  ## raw multiplier would not be a preference, it would be a takeover. See
  ## `rescaleKind`.

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
# The loot tables
# ---------------------------------------------------------------------------

proc scanLootTable(path: string; cell: float; bin: bool;
                   lootUsed: var int; c: var ContainerCensus) =
  ## Walk ONE positional loot table, counting every row and every reason a row
  ## was not used. Both tables SPT ships have the identical row shape
  ## `{probability, template:{Id, IsContainer, useGravity, Position:{x,y,z},
  ## ...}}`, so one walker reads both -- and, more importantly, the counting
  ## and the binning are the SAME pass. A separate counting pass could report
  ## a census the binner does not agree with, which is the failure mode this
  ## whole change is about.
  let t = dbRead(path)
  if not t.ok:
    return
  let list = whole(t.raw)
  let n = count(list)
  if n <= 0:
    return
  if c.tables.len > 0:
    c.tables.add ", "
  c.tables.add path & " (" & $n & " rows)"
  c.rows = c.rows + n
  var i = 0
  while i < n and i < MaxContainers:
    let row = at(list, i)
    # Two single-key steps, not the dotted path `template.Position`.
    # MEASURED: the dotted form returned not-found for all 552 rows of
    # Customs while the single-key form on the same JsonRef returns the
    # object. That WAS a parse bug; it is fixed, and the counters below are
    # what tell a returning parse bug apart from a table of zeroes.
    let tpl = field(row, "template")
    if exists(tpl):
      inc c.withTemplate
      let pos = field(tpl, "Position")
      if exists(pos):
        inc c.withPosition
        let x = asFloat(field(pos, "x"), 0.0)
        let y = asFloat(field(pos, "y"), 0.0)
        let z = asFloat(field(pos, "z"), 0.0)
        if x != 0.0 or z != 0.0:
          inc c.positioned
          # A probability of 0 is a container that never spawns; it must not
          # pull the centroid, and it must not count as density.
          let p = clampf(asFloat(field(row, "probability"), 0.0), 0.0, 1.0)
          if p <= 0.0:
            inc c.zeroProbability
          else:
            inc c.usable
            if bin:
              bump(gLootCells, lootUsed, floorDiv(x, cell), floorDiv(z, cell),
                   x, y, z, p)
    inc i

proc lootCensus*(key: string; cell: float; bin: bool;
                 lootUsed: var int): ContainerCensus =
  ## Every positional loot table this database has for one map.
  ##
  ## `staticContainers` is the table ORBIT was written against and it carries
  ## no coordinates on any build we have (see `ContainerCensus`). `looseLoot`
  ## carries REAL ones -- 1,689 rows on Woods, 1,689 of them non-zero, same
  ## row shape -- and is imported only when `importdb` was run with `--loose`,
  ## which is why the loot layer is empty on the shipped db.json and lights up
  ## with no further change on a db that has it. Reading both is the fix: it
  ## is the only positional loot source SPT actually ships.
  ##
  ## `key` must already be a DATABASE key. Callers resolve through
  ## `canonicalLocation` (emu/raid) -- do NOT add a second resolver here; the
  ## client sends `base.Id` ("Woods") and the tables are keyed "woods", and
  ## that confusion has already failed silently in four places.
  result = ContainerCensus(map: key, key: key, rows: 0, withTemplate: 0,
                           withPosition: 0, positioned: 0, zeroProbability: 0,
                           usable: 0, tables: "")
  if key.len == 0:
    return
  scanLootTable("locations." & key & ".staticContainers.staticContainers",
                cell, bin, lootUsed, result)
  scanLootTable("locations." & key & ".looseLoot.spawnpoints",
                cell, bin, lootUsed, result)

proc censusJson*(c: ContainerCensus): string =
  var o = obj()
  put(o, "map", c.map)
  put(o, "key", c.key)
  put(o, "rows", c.rows)
  put(o, "withTemplate", c.withTemplate)
  put(o, "withPosition", c.withPosition)
  put(o, "positioned", c.positioned)
  put(o, "zeroProbability", c.zeroProbability)
  put(o, "usable", c.usable)
  put(o, "tables", c.tables)
  # The verdict, computed HERE so every consumer agrees on it. Three outcomes,
  # never two.
  var verdict = "PASS"
  var why = ""
  if c.key.len == 0:
    verdict = "INCONCLUSIVE"
    why = "'" & c.map & "' does not resolve to a database key"
  elif c.rows == 0:
    verdict = "INCONCLUSIVE"
    why = "no positional loot table exists for '" & c.key & "'"
  elif c.withTemplate < c.rows or c.withPosition < c.withTemplate:
    verdict = "FAIL"
    why = "PARSE MISMATCH: of " & $c.rows & " rows, " & $c.withTemplate &
          " carried 'template' and " & $c.withPosition &
          " carried 'template.Position'. The row shape changed under the " &
          "reader; this is a code fix, not a data property"
  elif c.positioned == 0:
    verdict = "PASS"
    why = "all " & $c.rows & " rows parsed (" & $c.withPosition &
          " with template.Position) and every Position is (0,0,0). That is " &
          "a measured property of SPT's staticContainers table, not a parse " &
          "failure. Import with --loose to get looseLoot.spawnpoints, which " &
          "carries real coordinates"
  elif c.usable == 0:
    verdict = "FAIL"
    why = $c.positioned & " rows carry a real coordinate and NOT ONE is " &
          "spawnable (" & $c.zeroProbability & " have probability <= 0). A " &
          "table of positioned containers that all never spawn is a filter " &
          "bug here, not a database property"
  put(o, "verdict", verdict)
  put(o, "why", why)
  result = done(o).text

proc lootCensusFor*(locationId: string): string =
  ## The census for one map, by the id the CLIENT uses ("Woods"), resolved
  ## through the one resolver. Needs no raid, which is what lets a test assert
  ## the negative over all 24 maps instead of over the one that happened to be
  ## loaded.
  var used = 0
  var c = lootCensus(canonicalLocation(locationId), orbitCellSize(), false,
                     used)
  c.map = locationId
  result = censusJson(c)

# ---------------------------------------------------------------------------
# The quest / objective layer
# ---------------------------------------------------------------------------
#
# ## Where these points come from, and why they are the best coordinates here
#
# `mods/waypoints` already ships, and already serves, upstream SPT-Waypoints'
# patrol geometry: MEASURED 8,556 points across ten maps, in Unity world
# metres, y up, in `mods/waypoints/data/<key>.json`. Those points were authored
# BY HAND on each map's navmesh so that a bot patrol could walk them. That is
# exactly the property every other anchor in this file lacks:
#
#   * the loot layer has no coordinates at all on this build (all 429
#     staticContainers rows are (0,0,0) -- see `ContainerCensus`);
#   * the pvp and roam layers have real coordinates, but the ANCHOR is a
#     score-weighted CENTROID of a 50 m cell, which on a multi-storey map can
#     land inside geometry, and `dispatchCheck` counts exactly that as
#     `navStatus == 2`.
#
# A patrol point is a point a bot is known to be able to stand on. Binning them
# is still done -- 2,408 points on Customs would otherwise swamp the anchor
# budget -- but the emitted anchor is the centroid of a cluster of walkable
# points, which is a much better prior than the centroid of a cluster of spawn
# markers.
#
# ## What this does NOT do
#
# It is NOT the quest system. Nothing here reads `quests.json`, nothing knows
# what a quest OBJECTIVE is, and no bot is told to complete one. What it does is
# widen the catalogue of places worth walking to from "where players spawn" to
# "where the map's authors routed patrols", and it labels them `questPoi` so the
# dispatcher and `/aowlspt/orbit/plan` can tell the two apart. Calling it
# questing would be the "setting that changes nothing" this repo keeps paying
# for; calling it a better anchor source is what was measured.
#
# ## Why the file is read from a SIBLING mod directory
#
# `modDir()` is per-mod, and there is no cross-mod data API. The deployed layout
# is flat (`mods/tarkov`, `mods/waypoints`, ... -- verified on
# `D:\Aowlspt\aowlspt\mods`), so the sibling path resolves. Every candidate
# tried is recorded and reported, because "the quest layer is empty" and "the
# quest layer could not find its file" are different bugs and a silent zero
# cannot tell them apart.

proc readWholeFile(path: string; into: var string): bool =
  ## Line by line and rejoined -- the same shape `mods/waypoints/waypoints.nim`
  ## and `emu/post1.nim` use, and for the same reason: nimony's `readAll` is not
  ## dependable across these sizes, and JSON does not care where newlines are.
  var f: File
  if not open(f, path, fmRead):
    return false
  into = ""
  var line = ""
  var first = true
  while readLine(f, line):
    if not first: into.add "\n"
    into.add line
    first = false
  close(f)
  result = true

proc questCandidates(key: string): seq[string] =
  ## Ordered, and ALL of them reported when none opens.
  let md = modDir()
  result = @[]
  if md.len > 0:
    result.add md & "/../waypoints/data/" & key & ".json"
    result.add md & "/waypoints/data/" & key & ".json"
  let dd = dataDir()
  if dd.len > 0:
    result.add dd & "/../mods/waypoints/data/" & key & ".json"

proc questLayer(key: string; cell: float; bin: bool; questUsed: var int;
                p: var OrbitPlan) =
  ## Bin one map's patrol points. Shape, from the shipped schema
  ## `aowlspt.waypoints/1`: `zones[].patrols[].points[]`, each point a bare
  ## `[x, y, z]` array of metres.
  if key.len == 0:
    return
  var text = ""
  var tried = ""
  var opened = ""
  for cand in questCandidates(key):
    if tried.len > 0: tried.add ", "
    tried.add cand
    if readWholeFile(cand, text):
      opened = cand
      break
  if opened.len == 0:
    p.questTried = tried
    return
  p.questSource = opened

  let doc = whole(text)
  # The schema is checked, not assumed. A file whose shape changed under this
  # reader must say so rather than bin zero points and look like an empty map.
  let schema = asText(field(doc, "schema"), "")
  if schema != "aowlspt.waypoints/1":
    warn "orbit: quest layer: " & opened & " says schema '" & schema &
         "', not 'aowlspt.waypoints/1'. REFUSING to read it rather than " &
         "binning a shape this reader cannot trust"
    p.questSource = ""
    p.questTried = opened & " (wrong schema '" & schema & "')"
    return

  let zones = field(doc, "zones")
  let nz = count(zones)
  p.questZones = nz
  var seen = 0
  var zi = 0
  while zi < nz and zi < 256:
    let pats = field(at(zones, zi), "patrols")
    let np = count(pats)
    var pi = 0
    while pi < np and pi < 256:
      let pts = field(at(pats, pi), "points")
      let n = count(pts)
      var i = 0
      while i < n and seen < MaxQuestPoints:
        let pt = at(pts, i)
        if count(pt) >= 3:
          let x = asFloat(at(pt, 0), 0.0)
          let y = asFloat(at(pt, 1), 0.0)
          let z = asFloat(at(pt, 2), 0.0)
          if x != 0.0 or z != 0.0:
            inc seen
            if bin:
              bump(gQuestCells, questUsed, floorDiv(x, cell), floorDiv(z, cell),
                   x, y, z, 1.0)
        inc i
      inc pi
    inc zi
  p.questPointsSeen = seen

proc rescaleKind(anchors: var seq[Anchor]; kind: AnchorKind;
                 target: float): float =
  ## Put one layer's scores onto another's scale, preserving order within the
  ## layer. Returns the factor applied, so the caller can LOG it -- an implicit
  ## rescale is indistinguishable from a bug in the binner.
  result = 1.0
  var mx = 0.0
  var i = 0
  while i < anchors.len:
    if anchors[i].kind == kind and anchors[i].score > mx:
      mx = anchors[i].score
    inc i
  if mx <= 0.0 or target <= 0.0:
    return
  result = target / mx
  i = 0
  while i < anchors.len:
    if anchors[i].kind == kind:
      anchors[i].score = anchors[i].score * result
    inc i

proc maxScoreExcept(anchors: seq[Anchor]; kind: AnchorKind): float =
  result = 0.0
  var i = 0
  while i < anchors.len:
    if anchors[i].kind != kind and anchors[i].score > result:
      result = anchors[i].score
    inc i

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
                     spawnPointsSeen: 0, spawnRows: 0, questPointsSeen: 0,
                     questZones: 0, questSource: "", questTried: "", why: "")
  let cell = clampf(result.cellSize, 5.0, 500.0)
  result.cellSize = cell

  var lootUsed = 0
  var pvpUsed = 0
  var roamUsed = 0
  var questUsed = 0

  if orbitQuestPoi():
    questLayer(key, cell, true, questUsed, result)

  let census = lootCensus(key, cell, true, lootUsed)
  result.containerRows = census.rows
  result.containersSeen = census.usable

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

  if census.rows > 0 and census.usable == 0:
    # The old message here said "0 of 429 static-container rows parsed" and
    # was READ AS A PARSER BUG, because that is what it says. It was wrong:
    # every one of those rows parses. Say which rejection reason actually
    # fired, counted, and escalate only the reason that IS a defect.
    #
    # FATAL-loud vs merely reported is the whole point of splitting these:
    #   - a PARSE MISMATCH is ours and is an `error`, and the plan is refused;
    #   - an all-zero position table is a measured property of SPT's data on
    #     every build we have, and shouting it once per raid taught everyone
    #     to ignore the loot layer's log line entirely.
    let cj = censusJson(census)
    let verdict = field(cj, "verdict").asText("")
    let why = field(cj, "why").asText("")
    result.why = "loot layer: " & verdict & ": " & why & " [" & census.tables &
                 "]"
    if verdict == "FAIL":
      error "orbit: " & result.why
      # A shape mismatch must not degrade into a raid with a silently missing
      # loot layer. It refuses, and the caller reports `why`.
      return
    else:
      warn "orbit: " & result.why
  topInto(gLootCells, lootUsed, orbitLootAnchors(), akLoot, result.anchors)
  topInto(gPvpCells, pvpUsed, orbitPvpAnchors(), akPvp, result.anchors)
  # Roam anchors fill whatever the other two layers left. With the loot layer
  # producing nothing on this build that is most of the budget, and it is spent
  # on the only other real coordinates the database has.
  # The quest layer runs BEFORE roam, and the ORDER here is a measured decision
  # rather than a preference. Two things follow from it:
  #
  #  * BUDGET. `MaxAnchors` is 24 and `topInto` stops at it. Loot wants 12 and
  #    produces 0 on this build, pvp 6, roam 12 -- so a quest layer placed last
  #    would be handed whatever the roam layer left, which on Woods is 6 of the
  #    8 it asked for and on a map with a fuller loot layer would be none.
  #  * COORDINATE QUALITY. `topInto` de-duplicates by cell and the FIRST layer
  #    to claim a cell keeps it. Running before roam means a cell that both
  #    layers like is represented by the centroid of hand-authored navmesh
  #    points rather than by the centroid of spawn markers, which is the whole
  #    reason this layer is worth having.
  topInto(gQuestCells, questUsed, orbitQuestAnchors(), akQuestPoi,
          result.anchors)
  topInto(gRoamCells, roamUsed, orbitLootAnchors(), akRoam, result.anchors)
  # The rescale, AFTER every layer has been emitted so the comparison is
  # against the final catalogue. Without it a Customs cell holding 109 patrol
  # points -- MEASURED, the densest of the ten shipped maps is Streets at 128 --
  # outscores every spawn anchor on the map, whose cell scores are single
  # digits, by a factor of twenty. `pickAnchor` weights by score, so that is
  # not a preference for quest POIs, it is ORBIT becoming a waypoints-only
  # dispatcher wearing ORBIT's name.
  let otherMax = maxScoreExcept(result.anchors, akQuestPoi)
  var questAnchors = 0
  var qi = 0
  while qi < result.anchors.len:
    if result.anchors[qi].kind == akQuestPoi:
      inc questAnchors
    inc qi
  if questAnchors > 0:
    let target = (if otherMax > 0.0: otherMax * orbitQuestBias()
                  else: orbitQuestBias())
    let factor = rescaleKind(result.anchors, akQuestPoi, target)
    info "orbit: quest layer -- " & $questAnchors & " questPoi anchor(s) from " &
         $result.questPointsSeen & " patrol points in " & $result.questZones &
         " zones (" & result.questSource & "), rescaled by " & $factor &
         " onto the spawn layers' scale (best non-quest anchor scored " &
         $otherMax & ", quest bias " & $orbitQuestBias() & ")"
  elif not orbitQuestPoi():
    info "orbit: quest layer is OFF (orbitQuestPoi=false); anchors come from " &
         "the spawn layers only"
  elif result.questSource.len > 0:
    warn "orbit: quest layer read " & result.questSource & " and binned " &
         $result.questPointsSeen & " points, but produced NO anchor. That is " &
         "the anchor budget of " & $MaxAnchors & " already being full before " &
         "it ran, or a file whose every point duplicated a cell the loot or " &
         "pvp layer had already taken -- not a missing file, which is a " &
         "different message"
  else:
    warn "orbit: quest layer found no waypoints file for '" & key &
         "'. Tried: " & (if result.questTried.len > 0: result.questTried
                         else: "<no candidate path -- modDir() is empty>") &
         ". Upstream SPT-Waypoints 1.3.4 ships ten maps; a map outside that " &
         "ten legitimately has none, and this is that message either way"

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
  of akQuestPoi: "questPoi"

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
  put(o, "questPointsSeen", p.questPointsSeen)
  put(o, "questZones", p.questZones)
  put(o, "questSource", p.questSource)
  put(o, "questTried", p.questTried)
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

proc objectiveKindName(k: AnchorKind): string =
  ## The catalog's vocabulary, which is `docs/BOT_AI_OBJECTIVES.md`'s and not
  ## this file's. `akPvp` and `akRoam` are both "somewhere worth being" and
  ## collapse onto one kind; the client has no use for the distinction and
  ## carrying it would be inventing a difference the assigner cannot act on.
  case k
  of akLoot: "loot"
  of akQuestPoi: "questPoi"
  of akPvp, akRoam: "reposition"

proc catalogJson*(p: OrbitPlan): string =
  ## `tarkov.objectives.catalog` -- the OBJECTIVE CATALOG, and a strict
  ## superset of the anchor list in `planJson`.
  ##
  ## Data only. This side sees `db.json` and the waypoints files and it never
  ## sees a live bot, so it emits POSITIONS AND KINDS and assigns nothing. The
  ## squad that shares an objective exists only in the client, because the
  ## only readable squad identity on this build is the `BotOwner.BotsGroup`
  ## pointer and the bot census carries no group id at all -- a "leader"
  ## computed here would be the lowest live bot id, which is not a group.
  ##
  ## `okHold` and `okHunt` are NOT emitted here and their absence is
  ## deliberate: a hold point depends on where a fight is and a hunt point on
  ## where something was last seen, and neither is knowable from a database.
  ## The client adds those at runtime (a corpse is an `okHunt`), which is the
  ## same split one layer down.
  var o = obj()
  put(o, "ok", p.ok)
  put(o, "schema", "aowlspt.objectives/1")
  put(o, "map", p.map)
  put(o, "questSource", p.questSource)
  put(o, "questPointsSeen", p.questPointsSeen)
  if p.why.len > 0:
    put(o, "why", p.why)

  var a = arr()
  var i = 0
  while i < p.anchors.len:
    let an = p.anchors[i]
    # The origin is dropped HERE as well as on the client, because a catalog
    # that carries it has already lost the argument: every `staticContainers`
    # position in db.json is (0,0,0) -- 7,092 of 7,092 rows on all 13 maps
    # that have the table -- and one such entry sends a whole squad to world
    # zero and looks exactly like convergence working.
    if an.x != 0.0 or an.z != 0.0:
      var e = obj()
      put(e, "kind", objectiveKindName(an.kind))
      put(e, "x", an.x)
      put(e, "y", an.y)
      put(e, "z", an.z)
      # `priority` rather than `score`: the client compares it against a bot's
      # own urgency, so the name says what it is FOR rather than where it came
      # from. The number is the anchor score, unmodified -- biasing it twice,
      # here and in `pickEntry`, is how a tuning knob stops being findable.
      put(e, "priority", an.score)
      a.add e
    inc i
  put(o, "objectives", a)

  # The movement policy the client's assigner needs and must not invent. Same
  # numbers `planJson` carries, under the names the objective code uses, so
  # there is still exactly one place to change any of them.
  var m = obj()
  put(m, "leashM", orbitLeashM())
  put(m, "splinterM", orbitSplinterM())
  put(m, "reachM", orbitReachM())
  put(m, "holdMs", orbitHoldMs())
  put(o, "movement", m)

  # The honest capability statement, ON THE WIRE, so a reader of the payload
  # does not have to find this comment.
  var loot = obj()
  put(loot, "positionsFrom", "waypoints patrol points and live corpses")
  put(loot, "canOpenContainers", false)
  put(loot, "why", "opening a container needs LootableContainer.Interact and " &
      "an inventory-move RVA. Neither is measured in docs/SAIN_RVA.md, and " &
      "resolving them BY NAME kills the client on this build. An okLoot " &
      "objective moves a bot and loiters; it does not loot")
  put(o, "loot", loot)

  result = done(o).text

# ---------------------------------------------------------------------------
# Emission and the check
# ---------------------------------------------------------------------------

var gLastPlan = ""
var gLastCatalog = ""
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
         " anchors from " & $p.containersSeen & " containers, " &
         $p.spawnPointsSeen & " player spawn points and " &
         $p.questPointsSeen & " patrol points at " &
         $int(p.cellSize) & "m cells"
  discard broadcast("tarkov.orbit.plan", gLastPlan)
  # The objective catalog, on its own channel and from the same build. Two
  # channels rather than one field added to the plan, because the plan carries
  # ORBIT's personality/coverage/value policy and the catalog carries none of
  # it -- a consumer of one has no business parsing the other, and a mod that
  # subscribes to objectives should not have to know ORBIT exists.
  gLastCatalog = catalogJson(p)
  discard broadcast("tarkov.objectives.catalog", gLastCatalog)

proc lastPlanJson*(): string =
  if gLastPlan.len == 0:
    return "{\"ok\":false,\"why\":\"no raid has been configured this session, " &
           "so no plan has been built. This is not a failure to build one\"}"
  result = gLastPlan

proc lastCatalogJson*(): string =
  if gLastCatalog.len == 0:
    return "{\"ok\":false,\"why\":\"no raid has been configured this session, " &
           "so no objective catalog has been built. This is not a failure to " &
           "build one\"}"
  result = gLastCatalog

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
  # The quest layer, asserted as the same negative. Falsified by: a waypoints
  # file that opened and binned points and produced no anchor (a binning or
  # budget bug), which is a different outcome from a file that was never found.
  var questAnchors = 0
  q = 0
  while q < n:
    if asText(field(at(anchors, q), "kind"), "") == "questPoi":
      inc questAnchors
    inc q
  let qSeen = asInt(field(j, "questPointsSeen"), 0)
  let qSrc = asText(field(j, "questSource"), "")
  if questAnchors == 0 and qSeen > 0:
    return "FAIL: " & $qSeen & " patrol points were binned for '" & gLastMap &
           "' from " & qSrc & " and NOT ONE became a questPoi anchor. The " &
           "binning or the selection is dropping them"
  var questNote = ""
  if questAnchors > 0:
    questNote = " QUEST LAYER: " & $questAnchors & " questPoi anchor(s) from " &
                $qSeen & " patrol points (" & qSrc & "). These are the only " &
                "anchors here whose coordinates were authored on the navmesh."
  else:
    questNote = " NO QUEST LAYER: no waypoints file was read for '" &
                gLastMap & "' (tried: " &
                asText(field(j, "questTried"), "<nothing recorded>") &
                "). Ten maps ship points; a map outside that ten has none."
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
           "is `/sain/status`'s dispatchCheck, in a raid, with botNav on." &
           lootNote & questNote

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
