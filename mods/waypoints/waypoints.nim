## Waypoints — bot patrol geometry, served.
##
##     aowl build-mod mods/waypoints
##
## A port of DrakiaXYZ's SPT-Waypoints (MIT; patrol points contributed by
## Solarint) to post-1.0 aowlspt. Upstream is two halves that have very
## different feasibility on this build, and this mod ships the half that works
## and refuses to pretend about the half that does not.
##
## ## What upstream is, measured
##
## Read at tag 1.3.4 and at master (1.9.0):
##
##  * **1.3.4** carried `Waypoints/Solarint/<map>.json` — 87 zones, 197 patrols,
##    8556 points across ten maps — and injected them into `BotZone.PatrolWays`
##    with Harmony, plus a small SPT **server** mod (`ServerMod/src/mod.ts`)
##    that retuned `bots.types.*.difficulty.*.Patrol`.
##  * **1.9.0** DROPPED the JSON points entirely. What it ships now is
##    `<map>-navmesh.bundle` — Unity `NavMeshData` AssetBundles, ~50 MB a
##    release — loaded with `AssetBundle.LoadFromFile` and installed with
##    `NavMesh.RemoveAllNavMeshData` / `NavMesh.AddNavMeshData`.
##
## So the portable data is the 1.3.4 point set. The navmesh bundles are not
## portable: they are engine assets for a different Unity build, and installing
## one needs `AssetBundle.LoadFromFile` and two `UnityEngine.AI.NavMesh`
## statics called from a mod, which is exactly the call-by-RVA path no mod on
## this build has. That is stated in `README.md` as out of scope, not omitted.
##
## ## What this mod does
##
## **Serves the points.** `data/<map>.json`, converted by
## `tools/import_spt.py` into `aowlspt.waypoints/1` — 1.99 MB of upstream JSON
## down to 233 KB with every one of the 8556 points intact, because the
## conversion hoists four fields that measurement showed are CONSTANT across
## the whole corpus (nested `waypoints` always null, `patrolPointType` always
## `checkPoint`, `canUseByBoss` always true, `patrolType` always `patrolling`)
## and rounds coordinates to the millimetre. The importer FAILS rather than
## drops if a future source file violates any of those.
##
##     GET /waypoints/status          what loaded, what tuned, what refused
##     GET /waypoints/maps            per-map counts + the maps with no data
##     GET /waypoints/points/<map>    one map's document, verbatim
##
## **Applies the patrol tuning**, from upstream's server mod — and only the
## parts this database actually has. Measured against the loaded `db.json`:
## `LOOK_TIME_BASE`, `RESERVE_TIME_STAY`, `SPRINT_BETWEEN_CACHED_POINTS` and
## `Mind.CAN_STAND_BY` exist; `GO_TO_NEXT_POINT_DELTA`,
## `GO_TO_NEXT_POINT_DELTA_RESERV_WAY` and `USE_CHACHE_WAYS` DO NOT — they are
## pre-1.0 SPT key names that post-1.0 does not carry. Writing them would
## create keys nothing reads and make the tuning look complete when it is not,
## so this mod probes each key with `dbRead` before writing it and reports the
## missing ones on `/waypoints/status` under `skipped`, with the count of
## role/difficulty blocks each was absent from -- because SPRINT_BETWEEN_CACHED_POINTS
## turns out to be present at easy/normal/hard and absent at `impossible` for
## both PMC roles, and a bare name would have read as "absent everywhere".
##
## One `dbWrite` for the whole tuning, not one per role: a patch splices into
## the whole loaded database, so a write costs the size of the database and 228
## of them is not a thing to do at boot.
##
## ## What consumes it — read this before expecting bots to patrol
##
## Nothing in the client consumes this automatically. Upstream's injection
## point (`BotZone.PatrolWays`, subclassing `PatrolWay`) needs Harmony and
## reflection, and post-1.0 IL2CPP has neither.
##
## The one live consumption path that exists today is `aowlspt/botnav`:
## `sendBotTo(id, x, y, z)` reaches `EFT.BotOwner::GoToPoint` through the
## client host and answers back a real `NavMeshPathStatus`. The points in
## `data/` are in exactly the frame that call takes — Unity world space,
## metres, y up — so a route is a sequence of `sendBotTo` calls advanced on
## arrival. That path is ADVISORY (the bot's brain re-targets and will argue),
## it is gated on `botNav` in `aowlspt-host.json` which ships `false`, and its
## census is partial and rotating. It is not equivalent to owning the patrol
## graph. It is, however, not nothing, and it is not refused the way SAIN's
## cover and navmesh sensors are refused on this build.
##
## Nothing here has been run against a live raid. `/waypoints/status` reports
## what was loaded and written, which is not the same claim.

import std/syncio
import aowlspt
import aowlspt/server as sv
import aowlspt/json as jr
import aowlspt/settings # the F12 schema this mod declares, nested under Bot AI

const
  ModGuid = "aowl.waypoints"
  ModName = "Bot AI — Patrols"
  ModAuthor = "savannt"
  ModVersion = "1.0.0"
  DataSchema = "aowlspt.waypoints/1"

  StatusRoute = "/waypoints/status"
  MapsRoute = "/waypoints/maps"
  PointsPrefix = "/waypoints/points/"

  Maps = ["bigmap", "factory4_day", "factory4_night", "interchange",
          "laboratory", "lighthouse", "rezervbase", "shoreline",
          "tarkovstreets", "woods"]
    ## The ten maps upstream 1.3.4 shipped points for. These are checked in as
    ## a literal rather than discovered by listing `data/`, so a file that
    ## failed to deploy is reported missing instead of silently reducing the
    ## catalogue to whatever happened to be on disk.

  Unsupported = ["sandbox", "sandbox_high", "labyrinth"]
    ## Location ids this emulator's database has that upstream 1.3.4 predates.
    ## Named so `/waypoints/maps` can say "no data" rather than "no such map".

  Difficulties = ["easy", "normal", "hard", "impossible"]

  MoverRoles = ["bear", "usec"]
    ## Upstream retunes only the PMC roles' patrol pacing. The cache-ways
    ## disable it applied to every role is not portable here (see below), so
    ## these two are the whole of the role list.

type
  MapDoc = object
    name: string
    text: string       ## "" once the file has been found missing
    zones, patrols, points: int

var gDocs: seq[MapDoc] = @[]
var gTuned = 0            ## how many (role, difficulty, key) writes went out
var gSkipped: seq[string] = @[]   ## keys this database does not have, ...
var gSkipCount: seq[int] = @[]    ## ...and in how many role/difficulty blocks
var gSlots = 0                    ## how many role/difficulty blocks were seen
var gTuneError = ""

proc cfgBool(key: string; default: bool): bool =
  result = setting(key).asBool(default)

proc readWhole(path: string; into: var string): bool =
  ## The whole file as one string, read line by line and rejoined — the same
  ## shape `mods/tarkov/emu/post1.nim` uses, and for the same reason: nimony's
  ## `readAll` is not dependable across these sizes, and JSON does not care
  ## where the newlines are.
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

proc loadMaps() =
  ## Every map, once, at load. 233 KB total — small enough to hold, and holding
  ## it is what lets `/waypoints/maps` answer counts without touching disk.
  gDocs = @[]
  for m in Maps:
    var doc = MapDoc(name: m, text: "", zones: 0, patrols: 0, points: 0)
    var text = ""
    if readWhole(modDir() & "/data/" & m & ".json", text):
      let got = jr.asText(jr.field(text, "schema"), "")
      if got != DataSchema:
        warn "data/" & m & ".json says schema " & got & ", not " & DataSchema &
             " -- refusing to serve it rather than serving a shape a reader " &
             "cannot trust"
      else:
        doc.text = text
        let counts = jr.field(text, "counts")
        doc.zones = jr.asInt(jr.child(counts, "zones"), 0)
        doc.patrols = jr.asInt(jr.child(counts, "patrols"), 0)
        doc.points = jr.asInt(jr.child(counts, "points"), 0)
    else:
      warn "data/" & m & ".json is not on disk -- that map will report no data"
    gDocs.add doc

proc totalPoints(): int =
  result = 0
  for d in gDocs:
    result += d.points

# ---------------------------------------------------------------------------
# The patrol tuning
# ---------------------------------------------------------------------------
#
# Upstream's `ServerMod/src/mod.ts`, transcribed, then each key checked against
# the database that is actually loaded. A key that is not already there is NOT
# written: `dbWrite` merges and would happily create it, and a created key that
# nothing reads is indistinguishable from a tuning that worked.

proc note(s: var seq[string]; key: string) =
  ## Record a key this database does not have, and count how many
  ## role/difficulty blocks it was absent from.
  ##
  ## The count is the point. `SPRINT_BETWEEN_CACHED_POINTS` is present at easy,
  ## normal and hard for both PMC roles and absent at `impossible` for both --
  ## measured, not assumed -- so a bare name in this list would read as "this
  ## database does not have it", which is false. "absent in 2 of 8" is the
  ## honest shape, and it is what distinguishes a key post-1.0 dropped outright
  ## from a key that is merely patchy.
  var i = 0
  for existing in s:
    if existing == key:
      gSkipCount[i] += 1
      return
    i += 1
  s.add key
  gSkipCount.add 1

proc hasKey(path: string): bool =
  let v = dbRead(path)
  result = v.ok and v.raw.len > 0 and v.raw != "null"

proc tunePatrol() =
  gSkipCount = @[]
  gSlots = 0
  var types = obj()
  var wrote = 0
  var missing: seq[string] = @[]
  for role in MoverRoles:
    var byDiff = obj()
    for d in Difficulties:
      let base = "bots.types." & role & ".difficulty." & d
      if not hasKey(base):
        continue                # this role has no such difficulty; not an error
      gSlots += 1
      var patrol = obj()
      if hasKey(base & ".Patrol.LOOK_TIME_BASE"):
        patrol.put("LOOK_TIME_BASE", 3)
        wrote += 1
      else:
        missing.note "Patrol.LOOK_TIME_BASE"
      if hasKey(base & ".Patrol.RESERVE_TIME_STAY"):
        patrol.put("RESERVE_TIME_STAY", 12)
        wrote += 1
      else:
        missing.note "Patrol.RESERVE_TIME_STAY"
      if hasKey(base & ".Patrol.SPRINT_BETWEEN_CACHED_POINTS"):
        patrol.put("SPRINT_BETWEEN_CACHED_POINTS", 400)
        wrote += 1
      else:
        missing.note "Patrol.SPRINT_BETWEEN_CACHED_POINTS"
      # Keys upstream sets that post-1.0's database does not have. Probed, not
      # assumed, so a database that DOES carry them starts getting them.
      if hasKey(base & ".Patrol.GO_TO_NEXT_POINT_DELTA"):
        patrol.put("GO_TO_NEXT_POINT_DELTA", 3)
        wrote += 1
      else:
        missing.note "Patrol.GO_TO_NEXT_POINT_DELTA"
      if hasKey(base & ".Patrol.GO_TO_NEXT_POINT_DELTA_RESERV_WAY"):
        patrol.put("GO_TO_NEXT_POINT_DELTA_RESERV_WAY", 15)
        wrote += 1
      else:
        missing.note "Patrol.GO_TO_NEXT_POINT_DELTA_RESERV_WAY"
      if hasKey(base & ".Patrol.USE_CHACHE_WAYS"):
        patrol.put("USE_CHACHE_WAYS", false)
        wrote += 1
      else:
        missing.note "Patrol.USE_CHACHE_WAYS"

      var one = obj()
      if patrol.len > 0:
        one.put("Patrol", done(patrol))
      if hasKey(base & ".Mind.CAN_STAND_BY"):
        var mind = obj()
        mind.put("CAN_STAND_BY", false)
        one.put("Mind", done(mind))
        wrote += 1
      else:
        missing.note "Mind.CAN_STAND_BY"
      if one.len > 0:
        byDiff.put(d, done(one))
    if byDiff.len > 0:
      var roleObj = obj()
      roleObj.put("difficulty", done(byDiff))
      types.put(role, done(roleObj))

  gSkipped = missing
  if types.len == 0:
    gTuneError = "no role/difficulty path in this database matched; nothing written"
    warn ModName & ": " & gTuneError
    return
  var patch = obj()
  patch.put("types", done(types))
  if dbWrite("bots", done(patch)) != Ok:
    gTuneError = "dbWrite(\"bots\") refused: " & lastError()
    warn ModName & ": " & gTuneError
    return
  gTuned = wrote

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

proc mapDoc(name: string): int =
  result = -1
  var i = 0
  for d in gDocs:
    if d.name == name:
      return i
    i += 1

proc onPoints(url, body, session: string): string =
  let want = pathAfter(url, PointsPrefix)
  let i = mapDoc(want)
  if i < 0:
    for u in Unsupported:
      if u == want:
        return "{\"err\":\"no waypoint data for " & want &
               "\",\"reason\":\"this location postdates the shipped patrol dataset, " &
               "which is the last revision that carried patrol points as JSON\"}"
    return "{\"err\":\"no such map\",\"map\":\"" & want & "\"}"
  if gDocs[i].text.len == 0:
    return "{\"err\":\"data file missing or wrong schema\",\"map\":\"" &
           want & "\"}"
  result = gDocs[i].text

proc onMaps(url, body, session: string): string =
  var a = arr()
  for d in gDocs:
    var o = obj()
    o.put("map", d.name)
    o.put("loaded", d.text.len > 0)
    o.put("zones", d.zones)
    o.put("patrols", d.patrols)
    o.put("points", d.points)
    a.add done(o)
  var u = arr()
  for m in Unsupported:
    u.add m
  var root = obj()
  root.put("schema", DataSchema)
  root.put("maps", done(a))
  root.put("noData", done(u))
  result = done(root).text

proc onStatus(url, body, session: string): string =
  var loaded = 0
  for d in gDocs:
    if d.text.len > 0: loaded += 1
  var sk = arr()
  var si = 0
  for s in gSkipped:
    var e = obj()
    e.put("key", s)
    e.put("absentIn", (if si < gSkipCount.len: gSkipCount[si] else: 0))
    e.put("of", gSlots)
    sk.add done(e)
    si += 1
  var tune = obj()
  tune.put("keysWritten", gTuned)
  tune.put("blocks", gSlots)
  tune.put("skipped", done(sk))
  tune.put("error", gTuneError)
  var root = obj()
  root.put("mod", ModName)
  root.put("guid", ModGuid)
  root.put("version", ModVersion)
  root.put("schema", DataSchema)
  root.put("mapsLoaded", loaded)
  root.put("mapsExpected", Maps.len)
  root.put("points", totalPoints())
  root.put("space", "unity-world")
  root.put("units", "metres")
  root.put("consumer", "aowlspt/botnav sendBotTo -- advisory, host flag botNav, default off")
  root.put("tuning", done(tune))
  result = done(root).text

# ---------------------------------------------------------------------------
# Settings, rendered INSIDE the Bot AI page tree
# ---------------------------------------------------------------------------
#
# This mod is a half of Bot AI to a player, not a mod of its own: patrol
# geometry is bot behaviour. So it declares its rows with `inIndex = false` --
# still served, still page-queryable and still writable, but claiming no
# top-level entry in the F12 nav -- and `mods/sain` proxies them into its own
# page under `Bot AI > Waypoints`.
#
# NOTHING ELSE MOVES. The guid stays `aowl.waypoints`, the routes stay
# `/waypoints/*` and `/aowlspt/settings/aowl.waypoints`, and the value is
# still persisted by THIS mod into `mods/waypoints/config.json` under the same
# key it has always had. A write that arrives through the Bot AI page is
# forwarded here over `SettingsApplyQuery` and lands on the same code path a
# direct POST takes, so nesting moves no stored config path and needs no
# migration -- exactly one owner per value.

proc waypointsSchema(): seq[Setting] =
  result = @[
    boolSetting("patrolTuning", "Patrol pacing tuning", true,
                category = "Patrols",
                description = "Apply the shipped server-side patrol pacing tweaks to bots.types.*.difficulty.*.Patrol at server start. Only keys this database already carries are written; the three names post-1.0 dropped are probed, skipped and listed on /waypoints/status. Read at load, so a change takes effect on the next server start -- the patrol point data itself is served either way.",
                implemented = true)]

proc onWaypointsSettings(url, body, session: string): string =
  ## GET serves the schema; a POST body persists one edit into config.json.
  ## The value is read at load, so the write is saved and applied at the next
  ## server start rather than made live here.
  var st = Ok
  if body.len > 0:
    st = applySettingFromBody(body)
  result = declaredSchemaReply(st).text

proc onWaypointsSettingsReset(url, body, session: string): string =
  let st = resetFromBody(body)
  result = declaredSchemaReply(st).text

proc onLoad(): Status =
  if side() != sideServer:
    info ModName & " is a server mod; nothing to do on this side"
    return Ok
  loadMaps()
  if cfgBool("patrolTuning", true):
    tunePatrol()
  else:
    gTuneError = "disabled in config.json"
  declareSettings(waypointsSchema(), inIndex = false)
  discard serve("/aowlspt/settings/" & ModGuid, onWaypointsSettings)
  discard serve("/aowlspt/settings/" & ModGuid & "/reset", onWaypointsSettingsReset)
  if serve(StatusRoute, onStatus) != Ok: warn "could not register " & StatusRoute
  if serve(MapsRoute, onMaps) != Ok: warn "could not register " & MapsRoute
  if servePrefix(PointsPrefix, onPoints) != Ok:
    warn "could not register " & PointsPrefix
  var loaded = 0
  for d in gDocs:
    if d.text.len > 0: loaded += 1
  success ModName & " " & ModVersion & ": " & $loaded & "/" & $Maps.len &
          " maps, " & $totalPoints() & " patrol points served; " & $gTuned &
          " tuning keys written, " & $gSkipped.len &
          " not present in this database"
  Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideServer},
  onLoad = onLoad)
