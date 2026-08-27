## Raids: getting into one, and what happens on the way out.
##
## The client asks for a location's loot and a raid configuration, plays the
## raid itself entirely on its own machine, and then tells the server what
## happened. The server's job is at the two ends: hand over a map that is
## consistent enough to load, and take the result seriously enough that dying
## costs something.
##
## The end that matters is the exit. `/client/match/local/end` carries the
## profile the client played with — health, inventory, everything picked up —
## and a server that ignores it is a server where raids have no consequences.
## Saving it is what makes the game a game rather than a menu.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import ids
import loot
import questcond
import post1

type
  RaidResult* = enum
    rrSurvived, rrKilled, rrLeft, rrRunner, rrMissingInAction, rrTransit

proc parseResult*(s: string): RaidResult =
  ## The client's `ExitStatus`. `Transit` had no member here and fell through
  ## the `else` to `rrLeft` -- which keeps the gear, so nothing was ever lost by
  ## it, but it also meant nothing downstream could tell a transit from a normal
  ## extract and say so. It is its own member now precisely so the limitation
  ## below can be announced instead of being invisible.
  case s
  of "Survived": rrSurvived
  of "Killed": rrKilled
  of "Left": rrLeft
  of "Runner": rrRunner
  of "MissingInAction": rrMissingInAction
  of "Transit": rrTransit
  else: rrLeft

proc keepsGear*(r: RaidResult): bool =
  ## Whether the player walks out with what they walked in with. Death and going
  ## missing lose the gear; leaving early, running out and transiting keep it.
  case r
  of rrKilled, rrMissingInAction: false
  else: true

# ---------------------------------------------------------------------------
# What the raid handed over rather than carried out
# ---------------------------------------------------------------------------
#
# `/client/match/local/end` carries `transferItems` alongside the played
# profile, and until now nothing in this server read it. That is the BTR
# container and the transit hold: items the player deliberately handed to
# something that is *not* their character, so they are **not** in the profile
# the client posts back. `onMatchEnd` replaces the stored profile with that
# posted one, so every item in `transferItems` was destroyed -- silently,
# permanently, and with a 200 on the wire.
#
# What is measured about the shape, and what is not:
#
# * MEASURED, from the client's own metadata: the body's top level is the
#   anonymous type `<>f__AnonymousType80`5` with exactly the members
#   `serverId, results, lostInsuredItems, transferItems, locationTransit`.
#   An anonymous type carries its member *names* in metadata and its member
#   *types* only as generic parameters, so the names are certain and the
#   element type is not recoverable from there.
# * MEASURED, from `EFT.TransferItemsController`: the containers behind this
#   member are keyed by profile id --
#   `GetOrAddTransferContainer(string profileId)`,
#   `TryGetTransferContainer(string profileId, Stash)`,
#   `HasNonEmptyTransferContainer(string profileId)`. So the natural
#   serialisation is a map from profile id to that profile's items, which is
#   also what SPT accepts.
# * MEASURED: `EFT.UI.DragAndDrop.MailTransferItemsGridItemView` exists. The
#   client has a *mailbox* view built specifically for transferred items, which
#   is the strongest available evidence that the real backend returns them by
#   post rather than by splicing them into the stash.
# * INFERRED: that the map's values are plain item arrays. There is no request
#   body on disk to check it against -- the recorded capture stores responses
#   only (`manifest.json` seq 204 claims `reqlen: 14800` for this route and the
#   on-disk body is the 81-byte *response*).
#
# Because the last point is inferred, this reader is deliberately tolerant of
# three shapes and **says so in `problems` when it meets a fourth**, rather
# than returning an empty array and letting the caller destroy the items on the
# strength of a shape guess. Nothing here is allowed to fail quietly: an
# unreadable `transferItems` must be louder than a readable one.

proc collectItems(a: JsonRef; into: var List; seen: var seq[string];
                  dropped: var int) =
  ## Every well-formed item in one array, de-duplicated by `_id`.
  ##
  ## An element with no `_id` or no `_tpl` is not an item this server can put
  ## anywhere -- it cannot be parented, drawn or redeemed -- so it is counted
  ## and reported instead of being written into a mailbox as a shape the client
  ## will choke on.
  let elems = each(a)
  for e in elems:
    if not isObject(e):
      inc dropped
      continue
    let id = e.field("_id").asText("")
    let tpl = e.field("_tpl").asText("")
    if id.len == 0 or tpl.len == 0:
      inc dropped
      continue
    var already = false
    for s in seen:
      if s == id:
        already = true
    if already:
      continue
    seen.add id
    into.add raw(e)

proc transferredItems*(body: string; problems: var seq[string]): string =
  ## The items `transferItems` names, as one flat JSON array. `[]` when there
  ## are none -- which is the common case, since most raids do not use the BTR.
  ##
  ## Every key is taken, not just the player's own. The keys are profile ids
  ## and the only profile in an offline raid is the player's, so filtering by
  ## id would buy nothing and would throw the items away on the day that
  ## assumption is wrong. Taking them all can at worst mail the player an item
  ## that was already theirs.
  result = "[]"
  let t = field(body, "transferItems")
  if not t.exists or isNull(t):
    return
  var out1 = newList()
  var seen: seq[string] = @[]
  var dropped = 0
  if isArray(t):
    collectItems(t, out1, seen, dropped)
  elif isObject(t):
    let ms = members(t)
    for m in ms:
      let v = whole(m.value)
      if isArray(v):
        collectItems(v, out1, seen, dropped)
      elif isObject(v) and isArray(v.field("items")):
        collectItems(v.field("items"), out1, seen, dropped)
      elif isObject(v) and isArray(v.field("data")):
        collectItems(v.field("data"), out1, seen, dropped)
      else:
        problems.add "transferItems entry '" & m.name & "' is not an item " &
                     "array and holds no `items` or `data` array either, so " &
                     "whatever it carried could not be brought home"
  else:
    problems.add "transferItems is neither an object nor an array, so " &
                 "nothing could be read out of it"
    return
  if dropped > 0:
    problems.add $dropped & " entr(ies) in transferItems had no _id or no " &
                 "_tpl and could not be brought home"
  result = text(out1)

proc transitDestination*(body: string): string =
  ## Where a transit exit was heading, from `locationTransit.location`.
  ##
  ## MEASURED from `EFT.LocationTransit`: `{hash, playersCount, ip, location,
  ## profiles, transitionRaidId, raidMode, side, dayTime}`. It carries **no
  ## items** -- the items a transit moves travel in `transferItems` above --
  ## so reading it is about being able to name the limitation, not about loss.
  result = field(body, "locationTransit.location").asText("")

# ---------------------------------------------------------------------------
# The map list
# ---------------------------------------------------------------------------
#
# `/client/locations` is the screen that lists nineteen maps, and it used to
# answer with the whole `locations` subtree spliced in verbatim:
#
#     let v = dbRead("locations")
#     put(o, "locations", if v.ok: raw(v.raw) else: emptyObject())
#
# That is every map's `base` **and** its `staticContainers`, `staticLoot`,
# `staticAmmo` and `looseLoot` -- the floor of every map in the game, sent to
# draw a menu. Measured (`docs/IMPORTDB.md`): 12.5 MB and 247 ms on a default
# import, and **560 MiB and 10.8 seconds** on one imported with loose loot, out
# of a 1.3 GB process. Nothing failed. It simply cost that, every time the
# client opened the map list, and it is the single reason loose loot has to be
# opted into per map.
#
# What the client actually wants is narrower than what it was being sent, and
# the reference says so exactly. `LocationsGenerateAllResponse` in the SPT 4.x
# surface dump (`reference/spt-4.1-surface.txt`) is
#
#     prop Dictionary<MongoId, LocationBase> Locations
#     prop List<Path> Paths
#
# -- a map from a map's **`_Id`** to its **`base`**, and nothing else. Not the
# wrapper object the database keys by directory name, and not one byte of loot.
# `Path` is `{Source, Destination, Event}` and both ends of it are `_Id`s,
# which is the second and independent piece of evidence that this route speaks
# `_Id` rather than directory name: a transit graph written in `_Id`s is
# unreadable against a map list keyed by anything else.
#
# So this route answers map *descriptions*, and `looseLoot` belongs to
# `/client/location/getLocalloot`, which already asks one map at a time.
#
# ## What is deliberately still sent
#
# `base` goes out **verbatim**, byte for byte, and that is the whole of the
# compatibility story with the rest of this repository. `mods/morebots` writes
# `BotMax`, `MaxBotPerZone` and `waves[].slots_min/max` into
# `locations.<map>.base`; `mods/icebreaker` writes `BotMax`/`BotMaxPvE` and
# per-map `Enabled`/`Locked` into the same object. Both say in their own
# comments that they write there *because* `/client/locations` carries it to
# the client. Every one of those fields is inside `base`, so every one of them
# still arrives.
#
# SPT clears `base.Loot` before sending. This does not, because it does not
# have to: `Loot` is `[]` in all nineteen stock `base.json` files (measured),
# nothing in this emulator ever writes it, and clearing it would mean parsing
# and re-emitting 1.36 MB per request to blank a field that is already blank.
#
# ## Enumerating the maps, and the one cost that could not be removed
#
# Building the list needs the map *names*, and the plugin ABI has `db_get` for
# a dotted path and no sibling that lists an object's members
# (`abi/aowlspt_abi.h`). So the names can only come from reading `locations`
# whole -- exactly the read this section exists to stop doing.
#
# It is therefore done **once**, lazily, and cached: the key list plus each
# map's `_Id` is a few hundred bytes and does not change while the server runs.
# Every request after the first is nineteen small `dbRead`s of
# `locations.<map>.base`, which the backend's index answers without walking the
# document.
#
# The honest cost of that: **a map added to the database after this server has
# answered its first `/client/locations` is not listed until the server is
# restarted.** No mod in this repository does that -- mods patch existing maps
# at load, before any request -- and the alternative is paying the full read on
# every request, which is the defect being fixed. If the ABI ever grows a key
# enumeration, this cache stops being necessary and should go.

type
  LocationIndex* = object
    ## The map keys of the `locations` table, and the `_Id` each one carries.
    ## Two parallel sequences rather than a table: nineteen entries, looked up
    ## a handful of times per raid.
    ok*: bool
    names*: seq[string]   ## the database key -- the directory the map came from
    ids*: seq[string]     ## `base._Id`, or "" for a map whose base has none
    gameIds*: seq[string] ## `base.Id` -- the name the CLIENT sends, which is
                          ## not the database key: 13 of the 19 maps differ
                          ## from it only in case ("Woods"/"woods",
                          ## "TarkovStreets"/"tarkovstreets"), and a
                          ## case-sensitive lookup missed every one of them.

proc buildLocationIndex*(d: LootDb): LocationIndex =
  ## Every member of `locations` that has a `base`, in document order.
  ##
  ## The `base` test is what keeps this a list of *maps*. `locations` is not
  ## only maps: `locations.paths` is the transit graph, an array, and a route
  ## that listed it as a twentieth map would put an unloadable entry on the
  ## player's map screen.
  result = LocationIndex(ok: false, names: @[], ids: @[], gameIds: @[])
  let names = keys(whole(sub(d, "locations")))
  for name in names:
    let id = whole(sub(d, "locations." & name & ".base._Id")).asText("")
    let gid = whole(sub(d, "locations." & name & ".base.Id")).asText("")
    if id.len > 0:
      result.names.add name
      result.ids.add id
      result.gameIds.add gid
    elif sub(d, "locations." & name & ".base").len > 0:
      # A map whose base carries no `_Id`. It is listed under its database key
      # rather than dropped: a key the client may not recognise costs that one
      # map, and dropping it costs that one map *and* leaves nothing to see.
      result.names.add name
      result.ids.add ""
      result.gameIds.add gid
  result.ok = true

proc lowerAscii(s: string): string =
  result = newString(s.len)
  var i = 0
  while i < s.len:
    let c = s[i]
    result[i] = (if c >= 'A' and c <= 'Z': chr(ord(c) + 32) else: c)
    inc i

proc resolveLocation*(idx: LocationIndex; id: string): string =
  ## The database key for a map named ANY of the three ways the client and the
  ## database name it. Empty when the table has no such map -- never a guess.
  ##
  ## There are three names per map and they are not interchangeable. The
  ## database key is the SPT directory ("woods"); `base._Id` is the GUID
  ## `/client/locations` is keyed on ("5704e3c2..."); `base.Id` is what the
  ## client actually PUTS IN THE REQUEST -- measured from the captured
  ## `/client/match/local/start` body (raid1/requests/158.json), which names
  ## the map "Sandbox_start", an `Id`.
  ##
  ## This used to try only the first two, case-sensitively. MEASURED against
  ## db.json: 13 of the 19 maps carry a `base.Id` that differs from their
  ## database key -- Woods, Shoreline, Interchange, RezervBase, TarkovStreets,
  ## Lighthouse, Labyrinth, Sandbox, Sandbox_high, Terminal, Town, Suburbs,
  ## "Private Area" -- so a client asking for the map by the only name it has
  ## resolved NOTHING and the raid started with an empty loot list. Only
  ## bigmap, factory4_day, factory4_night, laboratory, develop and hideout
  ## happened to spell the two the same, which is exactly why this was never
  ## noticed: Customs and Factory work.
  if id.len == 0:
    return ""
  for name in idx.names:
    if name == id:
      return id
  var i = 0
  while i < idx.ids.len:
    if idx.ids[i] == id:
      return idx.names[i]
    inc i
  i = 0
  while i < idx.gameIds.len:
    if idx.gameIds[i] == id:
      return idx.names[i]
    inc i
  # Case-insensitive last, so an exact hit is never beaten by a fuzzy one.
  let want = lowerAscii(id)
  i = 0
  while i < idx.names.len:
    if lowerAscii(idx.names[i]) == want or lowerAscii(idx.gameIds[i]) == want:
      return idx.names[i]
    inc i
  result = ""

proc locationsBody*(d: LootDb; idx: LocationIndex): string =
  ## `{locations: {<_Id>: base}, paths: [...]}` -- the whole of what the client
  ## reads from `/client/locations`.
  var maps = obj()
  var i = 0
  while i < idx.names.len:
    let base = sub(d, "locations." & idx.names[i] & ".base")
    if base.len > 0:
      var key = idx.ids[i]
      if key.len == 0:
        key = idx.names[i]
      put(maps, key, raw(base))
    inc i
  var o = obj()
  put(o, "locations", maps)
  # `paths` is the map-to-map transit graph -- `{Source, Destination, Event}`
  # with `_Id`s at both ends. It was the literal `[]` here with nothing behind
  # it, which is the shape the weather constant had: a mod shipping transits
  # had nowhere to put them and could not register `/client/locations` either,
  # because the backend refuses a second registration of a path. So it reads
  # `locations.paths`, and the constant is the fallback rather than the only
  # answer.
  #
  # It is still `[]` on every database this repository produces. SPT keeps the
  # graph in `database/locations/base.json` -- a 2 KB sibling of the per-map
  # directories, `{locations: {}, paths: [...]}` -- and `aowl importdb` does
  # not import it, so nothing lands at `locations.paths` today. An empty graph
  # means the client offers no transit between maps, which is a missing feature
  # and not a wrong answer.
  # The transit graph: which maps you can walk from to which. The database
  # first, then BSG's own.
  #
  # SPT keeps the graph in `database/locations/base.json`, a 2 KB sibling of
  # the per-map directories, and `aowl importdb` does not import it -- so
  # `locations.paths` is `[]` on every database this repository produces, and
  # the client is told there is no transit anywhere. That is a wrong answer
  # rather than a missing feature: the maps have transit exits, and a client
  # that reaches one and is told it leads nowhere has been lied to.
  #
  # `data/post1/locationpaths.json` is the real backend's graph for this build
  # -- 18 edges over 10 maps (capture seq 134) -- used when the database has
  # none. The database still wins when it has one, so importing the graph
  # properly later replaces this without another change here.
  #
  # An edge naming a map this server does not have is left in deliberately.
  # The client resolves transits against the location list it was just sent in
  # the same body, so an unknown destination is an edge it ignores; dropping
  # such edges here would mean re-deriving the same conclusion with less
  # information.
  var paths = sub(d, "locations.paths")
  if paths.len == 0 or paths == "[]":
    paths = post1Table("locationpaths")
  put(o, "paths", if paths.len > 0: raw(paths) else: emptyArray())
  result = done(o).text

var gLocations = LocationIndex(ok: false, names: @[], ids: @[])

proc liveLocationIndex*(): LocationIndex =
  ## The index over the host's database, built on first use. See the note above
  ## on why this is cached and what that costs.
  if not gLocations.ok:
    gLocations = buildLocationIndex(liveDb())
    info "the locations table lists " & $gLocations.names.len & " map(s)"
  result = gLocations

proc liveLocationsBody*(): string =
  ## What `/client/locations` answers with.
  result = locationsBody(liveDb(), liveLocationIndex())

proc post1LocationBase*(id: string): string
  ## Forward-declared: `canonicalLocation` needs the post-1.0 table to resolve
  ## a map VARIANT to its parent, and the definition sits below it.

proc canonicalLocation*(id: string): string =
  ## The database key for a map the client named. `id` unchanged when the table
  ## does not have it, because every reader below answers "nothing here" for an
  ## unknown map and that is a better failure than substituting a map.
  ##
  ## The direct hit is tried first and costs one indexed `dbRead`, so the
  ## ordinary case -- the client sending `bigmap`, which is what it sends --
  ## never touches the index and never triggers its one-off build.
  let direct = dbRead("locations." & id & ".base")
  if direct.ok and direct.raw.len > 0:
    return id
  let idx = liveLocationIndex()
  let name = resolveLocation(idx, id)
  if name.len > 0:
    return name
  # Still nothing. The post-1.0 table lists 24 maps where the database has 19,
  # and the five extra ones are VARIANTS of a map the database does have: each
  # carries its own `Id` and `_Id` but shares the parent map's `Name`.
  #
  #   Sandbox_start   Name=Sandbox     scene maps/sandbox_start_preset.bundle
  #   Sandbox_high    Name=Sandbox     scene maps/sandbox_high_preset.bundle
  #   laboratory_dark Name=Laboratory  scene maps/laboratory_dark_preset.bundle
  #   Lighthouse2     Name=Lighthouse  scene maps/lighthouse_preset.bundle
  #   Terminal_ui     Name=Terminal    scene maps/terminal_preset.bundle
  #
  # So `Name` is the general variant->parent edge, and it is DATA, in a table
  # the real server sent us -- not a hardcoded string list that would have to
  # grow by hand every wipe. `Icebreaker` has a `Name` of its own and no
  # database map, so it resolves to nothing, which is the honest answer.
  #
  # That this is the right parent for LOOT purposes is measured, not assumed:
  # of the 41 static containers BSG serves for `Sandbox_start`
  # (raid1/responses/158.json), 38 appear VERBATIM in SPT's `sandbox`
  # staticContainers table. The 3 that do not are `container_ProfileEditor_*`,
  # which exist only in the tutorial scene.
  #
  # It is NOT the right parent for loose loot: zero of BSG's 94 loose entries
  # for `Sandbox_start` match a `sandbox` spawn point by Id, by position, or
  # even by base name. See `looseLootFor` below.
  let variant = post1LocationBase(id)
  if variant.len > 0:
    let parent = field(variant, "Name").asText("")
    if parent.len > 0 and parent != id:
      let byName = resolveLocation(idx, parent)
      if byName.len > 0:
        return byName
  result = id

proc locationBase*(id: string): string =
  ## A map's static description. Looked up by both `_Id` and name, because
  ## `/client/locations` hands the client a list keyed by `_Id` and
  ## `/client/location/getLocalloot` is asked by name.
  ##
  ## This comment used to say exactly that and the code did only half of it --
  ## one lookup, by name. Nothing failed: an `_Id` simply found no base, and a
  ## raid started with the default 40-minute timer on a map with no loot.
  let byKey = dbRead("locations." & canonicalLocation(id) & ".base")
  if byKey.ok and byKey.raw.len > 0:
    return byKey.raw
  result = ""

proc post1LocationBase*(id: string): string =
  ## The full post-1.0 `LocationBase` for a map, out of the installed
  ## `data/post1/locations` table.
  ##
  ## That table (24 real maps, capture seq 134) carries the members the SPT-era
  ## `base.json` predates and that a playable raid cannot do without:
  ## `SpawnPointParams` (Factory 160, Customs 318, Ground Zero 57 -- the points
  ## the player and the bots spawn on), `exits`/`ExitZones` (the extracts),
  ## `waves` and `MinMaxBots`. The SPT-db base has none of them, so a raid built
  ## from it has no spawn and no exit and the client throws while it walks the
  ## `LocationBase` -- the "a task failed" the raid build reports.
  ##
  ## Matched by the map's `Id` (what `match/local/start` names, e.g.
  ## "factory4_day"/"Sandbox_start") first, then by the `_Id` the table is keyed
  ## on. "" when the table is not installed or has no such map, so the SPT-db
  ## path below stays the fallback.
  if id.len == 0:
    return ""
  let table = post1Table("locations")
  if table.len == 0:
    return ""
  let locs = field(table, "locations")
  if not locs.found:
    return ""
  for k in keys(locs):
    let entry = locs.field(k)
    if entry.field("Id").asText("") == id:
      return entry.raw
  # No `Id` matched; the caller may have named the map by its `_Id` key.
  let byKey = locs.field(id)
  if byKey.found and byKey.raw.len > 0:
    return byKey.raw
  result = ""

proc botZonesFor(spawnPointParams: JsonRef): seq[string] =
  ## Takes the map's `SpawnPointParams` array itself rather than the whole
  ## `LocationBase`, so a caller that already holds the base as a parsed `Doc`
  ## can hand over just that one member instead of re-serialising a document
  ## that is megabytes wide.
  ##
  ## The zones an assault scav can actually spawn in on this map: the distinct
  ## `BotZoneName` of every `SpawnPointParams` point that admits a `Bot` of the
  ## `Savage` side. A scav wave whose `SpawnPoints` names a zone with no such
  ## point spawns nothing, so these are the only zones worth pointing a wave at.
  ## An empty name is a real zone -- the map's default, which is all Ground Zero
  ## (`Sandbox`) tags its bot points with -- and is kept as `""`.
  result = @[]
  let spp = spawnPointParams
  if not spp.isArray:
    return
  let n = count(spp)
  var i = 0
  while i < n:
    let p = spp.at(i)
    inc i
    let cats = p.field("Categories")
    var isBot = false
    if cats.isArray:
      var c = 0
      while c < count(cats):
        if cats.at(c).asText("") == "Bot": isBot = true
        inc c
    if not isBot: continue
    let sides = p.field("Sides")
    var isSavage = false
    if sides.isArray:
      var s = 0
      while s < count(sides):
        let sv = sides.at(s).asText("")
        if sv == "Savage" or sv == "All": isSavage = true
        inc s
    if not isSavage: continue
    let zn = p.field("BotZoneName").asText("")
    var seen = false
    for z in result:
      if z == zn: seen = true
    if not seen:
      result.add zn

proc oneWave(number, tmin, tmax, smin, smax: int; zone: string): JsonObject =
  ## One assault-scav wave in BSG's own `waves[]` shape (capture seq 158). Every
  ## member the client's `WildSpawnWave` reads is present, so nothing
  ## deserialises to a null: `SpawnMode` lists all three modes so the wave is
  ## never filtered out by the session's mode, `WildSpawnType`/`BotSide` make it
  ## a scav.
  ##
  ## `time_min`/`time_max` are seconds, and their *sign* selects which of the
  ## client's two dispatch arms the wave takes -- see `offlineScavWaves`. A
  ## negative pair is not a disabled wave; it is the wave that spawns at once.
  var w = obj()
  put(w, "BotPreset", "normal")
  put(w, "BotSide", "Savage")
  put(w, "KeepZoneOnSpawn", false)
  var modes = arr()
  modes.add "regular"
  modes.add "pve"
  modes.add "pvp-season"
  put(w, "SpawnMode", modes)
  put(w, "SpawnPoints", zone)
  put(w, "WildSpawnType", "assault")
  put(w, "isPlayers", false)
  put(w, "number", number)
  put(w, "slots_max", smax)
  put(w, "slots_min", smin)
  put(w, "time_max", tmax)
  put(w, "time_min", tmin)
  result = w

proc offlineScavWaves(zones: seq[string]): string =
  ## Fresh assault waves that fill the map with scavs early and reliably,
  ## replacing BSG's online-tuned table.
  ##
  ## ## Which arm of the client actually places a wave
  ##
  ## This used to say that `factory4_day`'s `time_min/time_max = -1/-1` wave
  ## "never fires". That was read off the data and it is **wrong**, and it is
  ## the reason four attempts at this bug missed. Disassembling
  ## `EFT.WavesSpawnScenario.<Run>d__17::MoveNext` (RVA 0x2556840 in
  ## `GameAssembly.dll`, build 1.1.0.1.46777) shows `Run` takes a *spawn mode*
  ## and splits the wave list on the sign of the wave's rolled time:
  ##
  ##   * `Run(1)` -- `comiss xmm7(0.0f), [wave+0x20]; jbe skip` at +0x2556ad6:
  ##     only waves with **`Time < 0`**, and it invokes the spawn delegate
  ##     **immediately and synchronously**, gathering the tasks into a
  ##     `Task.WhenAll` that `LocalBotsSpawnInitialization` awaits before the
  ##     raid starts. No timer, no scheduler.
  ##   * `Run(2)` -- `comiss` + `ja skip` at +0x2556b24: only waves with
  ##     **`Time >= 0`**, and each one is merely *registered* with
  ##     `TimerManager.MakeTimer(TimeSpan.FromSeconds(Time))`
  ##     (`StaticManager.Instance` + 0x28) plus an `UpdatedEventHandler`; the
  ##     spawn delegate runs only when that timer elapses.
  ##
  ## `EFT.LocalGame.<LocalBotsSpawnInitialization>d__12::MoveNext` calls
  ## `Run(1)` at +0xad3ff9, awaits it, then `Run(2)` at +0xad40c4.
  ##
  ## So `-1/-1` is not a dead wave -- it is the *only* wave that is placed
  ## without depending on the raid's timer service. The previous version of
  ## this proc emitted nothing but non-negative times, which put every single
  ## scav wave on the timer arm, and live the count of
  ## `GameWorld::RegisterPlayer` calls never moved past the boss and his two
  ## escorts. Seeding with negative-time waves takes the arm that is proven to
  ## place bots and costs nothing if the timer arm works too.
  ##
  ## ## What the rest of the shape has to satisfy
  ##
  ## Every gate between here and a placed scav, with the address that proves
  ## it, so the next person does not have to re-derive them:
  ##
  ##   * `Location.OldSpawn` (+0x192) must be true, or both `Run` calls are
  ##     skipped -- +0xad3fc2. Left as the base has it; every map but Terminal
  ##     ships `true`.
  ##   * `WavesSpawnScenario.SpawnWaves` must be non-null and non-empty --
  ##     +0xad3fdf / +0xad3fee. It is `waves.Select(...).OrderBy(...).ToArray()`
  ##     (`Init`, 0x2554f50), one output per input, so a non-empty `waves[]` is
  ##     enough; `Init` is also what sets `Enabled` (+0x50) true.
  ##   * `slots_min`/`slots_max` become `BotsCount` via
  ##     `MyExtensions.RandomInclude` in `<Init>b__15_0` (0x2556300), and a wave
  ##     with `BotsCount == 0` is dropped at +0x6cf395. Both are kept >= 1.
  ##   * `BotPreset` is `Enum.Parse`d, case-sensitively, into `BotDifficulty`
  ##     at +0x255651c -- an unknown string throws inside an async and the wave
  ##     vanishes silently. `"normal"` is a real member.
  ##   * `SpawnPoints` becomes `SpawnWave.SpawnAreaName` verbatim and is matched
  ##     by **exact ordinal string equality** against the scene `BotZone`
  ##     object's `UnityEngine.Object.name`
  ##     (`<>c__DisplayClass67_0::<ActivateBotsByWave>b__0`, 0x6ce730); no
  ##     match and the client logs `Can't spawn wave cause can'f find zone with
  ##     name:{0}   _openZones:{1}` and places nothing (+0x6cf98f). The names
  ##     come from the map's own `SpawnPointParams[].BotZoneName`, which is the
  ##     same spelling BSG's own `waves[]` use.
  ##
  ## `MaxBotPerZone` and `BotMax` (set on the base) cap how many are alive at
  ## once, so a generous wave list does not over-spawn.
  ## ## How many bots a wave actually asks for
  ##
  ## The live client's own AI trace is the oracle here. A wave served as
  ## `slots_min = 2 / slots_max = 4` produced, verbatim:
  ##
  ##   `Checking spawn on max bots v1 _maxBots:0  toDelay:0 toSpawn:2`
  ##   `Activate bots: Side:Savage Type:assault ... spawnPoints:2`
  ##
  ## Two bots out of a 2..4 request. That is the SPAN, not either endpoint:
  ## `LocalGame::ModifySettings` (0xAD12A0) multiplies both slot numbers by 1.5
  ## and hands them to `ToBotAmountSlots(BotAmount, min, max)` (0x6D9B70),
  ## whose `AsOnline` arm (+0x6D9D30) computes
  ##   `trunc((max' - min') * WAVE_COEF_MID(1.4) * 0.5 + 0.5)`
  ## with `min' = 1.5*slots_min`, `max' = 1.5*slots_max`. For 2/4:
  ##   span' = 1.5*(4-2) = 3 ; 3 * 1.4 * 0.5 + 0.5 = 2.6 ; trunc -> **2**.
  ## Exactly the `toSpawn:2` observed. So `slots_min == slots_max` yields ZERO
  ## and the absolute values are discarded -- only `slots_max - slots_min`
  ## counts. Collapsing the constants, for a raw span `S`:
  ##   `toSpawn = trunc(1.05 * S + 0.5)`, i.e. **toSpawn == S** for S in 1..9.
  ##
  ## The waves below therefore use `slots_min = S`, `slots_max = 2*S`, so the
  ## span is `S` under the span model *and* the plain `RandomInclude(min,max)`
  ## reading (the fallback if some other arm than `AsOnline` is taken) still
  ## returns at least `S`. Either way a wave is worth >= S scavs.
  const perWave = 4      ## S: bots requested per seed wave. trunc(1.05*4+0.5)=4.
  const trickle = 3      ## S for the timer-arm bonus waves.
  var useZones = zones
  if useZones.len == 0:
    useZones = @[""]
  var a = arr()
  var number = 0
  # The seed. Negative time, so these take `Run(1)` -- dispatched synchronously
  # while the raid is still loading, which is how BSG seeds a map and the one
  # arm that does not depend on the timer service. Four at minimum so a
  # one-zone map (Factory) still gets 4 * 4 = 16 scavs on the floor at raid
  # start; one per zone beyond that, capped at eight so a many-zoned map does
  # not blow the up-front `bot/generate` budget.
  var seeds = useZones.len
  if seeds < 4: seeds = 4
  if seeds > 8: seeds = 8
  while number < seeds:
    a.add oneWave(number, -1, -1, perWave, perWave * 2,
                  useZones[number mod useZones.len])
    inc number
  # The trickle. Non-negative, so these take `Run(2)`'s timer arm: a bonus if
  # that arm works offline and harmless if it does not. Staggered from 20 s so
  # a swept map does not go quiet after the seed.
  var early = useZones.len
  if early < 6: early = 6
  if early > 10: early = 10
  var i = 0
  while i < early:
    let zone = useZones[(seeds + i) mod useZones.len]
    a.add oneWave(number, 20 + i * 30, 40 + i * 30, trickle, trickle * 2, zone)
    inc i
    inc number
  a.add oneWave(number, 360, 420, trickle, trickle * 2, useZones[0])
  result = done(a).text

proc tuneOfflineSpawns*(d: var Doc) =
  ## Turn one `LocationBase` document into one that populates an offline raid.
  ##
  ## ## Why this is a proc and not four lines inside `localLoot`
  ##
  ## It used to be inline in `localLoot`, and that is the bug this exists to
  ## fix. `localLoot` builds `match/local/start`'s `locationLoot`, which is one
  ## of *two* places the client is handed a `LocationBase`; the other is
  ## `/client/locations`, which `tarkov.onLocations` was answering with
  ## `post1Table("locations")` **verbatim**. The evidence that the client builds
  ## its wave scenario from the latter is exact rather than circumstantial: with
  ## `localLoot` serving four negative-time waves of span 4, a live Factory raid
  ## logged
  ##   `Checking spawn on max bots v1 _maxBots:0  toDelay:0 toSpawn:2`
  ## once and only once -- and `factory4_day`'s own untouched `waves[]` contains
  ## exactly one wave with a negative time, `number 1, -1/-1, slots 2/4`, whose
  ## span of 2 yields precisely `toSpawn:2`. The client was reading the raw
  ## table and had never seen `localLoot`'s waves at all. That also explains why
  ## the earlier `MaxBotPerZone` raise changed nothing.
  ##
  ## So the tuning lives here and both servers apply it.
  ##
  ## ## What it changes
  ##
  ## BSG's `waves[]` is tuned for an online raid and leaves an offline one
  ## nearly empty of assault scavs: `factory4_day` ships `BotStart`/`BotStop`/
  ## `BotMax` all 0 (no spawn window, no bot budget) and one immediate wave
  ## against seven that only land after forty seconds to twenty-eight minutes.
  ## The boss still comes because `BossLocationSpawn` is a separate path that
  ## consults none of this -- exactly the symptom seen live: Tagilla fights, no
  ## scavs roam. The boss path, the PMC `BossLocationSpawn` entries and the loot
  ## are untouched here.
  let zones = botZonesFor(whole(getRaw(d, "SpawnPointParams")))
  setRaw(d, "waves", offlineScavWaves(zones))
  setNumber(d, "BotStart", 0)
  setNumber(d, "BotStop", 86400)
  # Budgets. These are the two throttles that can silently eat the waves above:
  # `BotMax` is the map-wide alive cap and `MaxBotPerZone` the per-`BotZone`
  # one. Factory's own base ships `BotMax = 0` and `MaxBotPerZone = 4` -- with
  # all 19 of its savage spawn points in a single zone named `BotZone`, a
  # 4-per-zone cap alone would hold the map to four scavs however many waves
  # were served. Raise both to fit the ~16-20 the seed waves now request. (The
  # host additionally pokes the client's `_maxBots` to 0 = unlimited, which the
  # AI trace confirms; these served numbers are the belt to that's braces.)
  if get(d, "BotMax").asInt(0) < 30: setNumber(d, "BotMax", 30)
  if get(d, "BotMaxPvE").asInt(0) < 30: setNumber(d, "BotMaxPvE", 30)
  # Per zone: enough that a one-zone map (Factory) is not capped below the seed
  # total, without letting a ten-zone map pile 24 bots into each.
  var zoneCount = zones.len
  if zoneCount < 1: zoneCount = 1
  var perZone = 24 div zoneCount
  if perZone < 8: perZone = 8
  if perZone > 24: perZone = 24
  if get(d, "MaxBotPerZone").asInt(0) < perZone:
    setNumber(d, "MaxBotPerZone", perZone)
  # `OpenZones` must name the zones the waves point at, or the wave has no open
  # zone to spawn into. Built from the same real bot zones; left as the base's
  # own when every bot point is unzoned (`""`, e.g. Ground Zero).
  var openZones = ""
  for z in zones:
    if z.len > 0:
      if openZones.len > 0: openZones.add ","
      openZones.add z
  if openZones.len > 0: setText(d, "OpenZones", openZones)
  # Spawn-lock. `BotLocationModifier` runs the client's anti-spawn-in-sight
  # system: every bot spawn point within `LockSpawnCheckRadius` (120 m on
  # Factory) of a player is locked and cannot place a bot. Factory's whole
  # playable area is smaller than 120 m, so the instant the player is in it
  # every `BotZone` point would stay locked for the rest of the raid -- while
  # the boss spawns anyway, because `BossLocationSpawn` places through a trigger
  # that does not consult this radius. Zero the lock so an offline wave can
  # place a scav regardless of how close the player is; per-map, only the
  # modifier the base already carries is touched.
  if has(d, "BotLocationModifier"):
    var blm = parseObject(get(d, "BotLocationModifier").raw())
    if blm.ok:
      setNumber(blm, "LockSpawnCheckRadius", 0)
      setNumber(blm, "LockSpawnCheckRadiusPvE", 0)
      setNumber(blm, "LockSpawnStartTime", 0)
      setNumber(blm, "LockSpawnStartTimePvE", 0)
      setRaw(d, "BotLocationModifier", text(blm))

var gTunedLocations: string = ""

proc post1LocationsTuned*(): string =
  ## The post-1.0 `locations` table with every map's spawn tuning applied --
  ## what `/client/locations` must answer with.
  ##
  ## This is the payload the client actually builds its wave scenario from (see
  ## `tuneOfflineSpawns` for the proof), so serving the table verbatim served
  ## BSG's online-tuned waves no matter what `match/local/start` said later.
  ##
  ## Computed once and cached: the table is the biggest document the server
  ## owns and the deploy screen asks for it more than once per session, so
  ## re-tuning 24 maps per request would put the cost back where the
  ## `looseLoot` split took it out of. "" when the table is not installed, so
  ## the caller keeps its SPT-db fallback.
  if gTunedLocations.len > 0:
    return gTunedLocations
  let table = post1Table("locations")
  if table.len == 0:
    return ""
  var top = parseObject(table)
  if not top.ok:
    return table
  let locs = field(table, "locations")
  if not locs.found:
    return table
  var tuned = newDoc()
  for k in keys(locs):
    var one = parseObject(locs.field(k).raw)
    if one.ok:
      tuneOfflineSpawns(one)
      setRaw(tuned, k, text(one))
    else:
      setRaw(tuned, k, locs.field(k).raw)
  setRaw(top, "locations", text(tuned))
  gTunedLocations = text(top)
  result = gTunedLocations

proc localLoot*(locationId: string; nowSeconds: int;
                raidId: string = ""): string =
  ## What is lying on the floor when the raid starts.
  ##
  ## The database's static loot when it has any, and an empty map when it does
  ## not -- an empty map loads and plays, which is a great deal better than a
  ## client that cannot enter a raid at all because the server had nothing to
  ## say about the floor.
  # The client normally names a map the way the database keys it (`bigmap`),
  # and that is one indexed read. It may also name it by `_Id`, which is how
  # `/client/locations` lists it, and that used to find no base at all: the
  # raid loaded with the default timer and an empty floor. Resolving once here
  # means every read below is against the key the database actually uses.
  let name = canonicalLocation(locationId)
  # The real post-1.0 base first, when the post1 locations table is installed:
  # it carries SpawnPointParams/exits/waves, which the SPT-db base does not, and
  # which the client needs to build a raid at all. The SPT-db base is the
  # fallback for a map the table has no entry for. `locationId` is tried before
  # the canonicalised `name` because the table is keyed and tagged by the id the
  # client sends (`Sandbox_start`), which for a post-1.0-only map the SPT db has
  # never heard of and `canonicalLocation` leaves unchanged anyway.
  var base = post1LocationBase(locationId)
  if base.len == 0 and name != locationId:
    base = post1LocationBase(name)
  if base.len == 0:
    base = locationBase(name)
  # Seeded from the raid id, so the floor of a given raid is reproducible from
  # a bug report. Falling back to the map name when there is no raid id keeps it
  # deterministic rather than empty -- the same map then has the same loot every
  # time, which is worse for play and better than nothing to debug.
  var seed = raidId
  if seed.len == 0:
    seed = name
  if base.len > 0:
    # The wire `locationLoot` is the WHOLE `LocationBase` (capture seq 158:
    # 107 members -- SpawnPointParams, waves, exits, BossLocationSpawn, doors,
    # transits, areas, limits, ...) with `Loot` filled in. Post-1.0 never calls
    # `/client/location/getLocalloot`, so this is the only place the client is
    # ever told where the exits and spawns are: emitting the six-field subset it
    # used to meant a raid with no exits, no spawn points and no waves. Start
    # from the base document and overlay only the dynamic members.
    var d = parseObject(base)
    setRaw(d, "Loot", lootFor(name, seed))
    setRaw(d, "transitionParameters", "null")
    setNumber(d, "UnixDateTime", nowSeconds)
    # `Id`/`Name` are already in the base; guarantee them for a base that omits
    # one rather than trusting every imported map to carry both.
    if not has(d, "Id"): setText(d, "Id", name)
    if not has(d, "Name"): setText(d, "Name", name)
    # Post-1.0 `LocationBase` members the SPT-era `base.json` predates. The real
    # backend sends all of them in the `match/local/start` `locationLoot`
    # (capture seq 158); an imported base carries none. They matter because the
    # client deserialises this into `LocationBase` and then walks it while it
    # builds the raid: `areas` (the infiltration zones) is a collection it
    # iterates, and a *missing* member deserialises to a null collection, which
    # is a NullReference during `LocalGameMatching` -- and the visible symptom of
    # that is the Ready button doing nothing, because the fault is swallowed by
    # the async state machine that click kicked off. Filled only when the base
    # omits them, so a database that already carries the real values keeps them.
    if not has(d, "areas"): setRaw(d, "areas", "{}")
    if not has(d, "ExitZones"): setText(d, "ExitZones", "")
    if not has(d, "HighLevelLocationId"): setText(d, "HighLevelLocationId", "")
    if not has(d, "ForceOfflineRaidInPVE"): setBool(d, "ForceOfflineRaidInPVE", false)
    if not has(d, "HiddenWhenLockedByQuest"): setBool(d, "HiddenWhenLockedByQuest", false)
    if not has(d, "LockedByQuest"): setBool(d, "LockedByQuest", false)
    if not has(d, "SavageForceOfflineRaidInPVE"):
      setBool(d, "SavageForceOfflineRaidInPVE", false)
    if not has(d, "SavageForceOnlineRaidInPVE"):
      setBool(d, "SavageForceOnlineRaidInPVE", false)
    # Scav waves. BSG's `waves[]` is tuned for an online raid and leaves an
    # offline one nearly empty of assault scavs: `factory4_day` ships
    # `BotStart`/`BotStop`/`BotMax` all 0 (no spawn window, no bot budget) and
    # one immediate wave against six that only land after five to twenty-five
    # minutes. The boss still comes because `BossLocationSpawn` is a separate
    # path that does not consult any of this, which is exactly the symptom seen
    # live: Tagilla fights, no scavs roam.
    #
    # Rewrite the waves to seed the map's real bot zones at raid start (see
    # `offlineScavWaves` for which client arm actually places them), and
    # open the spawn budget and window so they are allowed to. Sourced from the
    # map's own `SpawnPointParams` (the zones scavs can actually stand in), so
    # this stays per-map correct rather than a Factory-only constant. The boss
    # path and the loot are untouched.
    tuneOfflineSpawns(d)

    result = text(d)
  else:
    # No base in the database: an empty-but-valid map that still loads and plays,
    # far better than a client that cannot enter a raid at all.
    var o = obj()
    put(o, "Id", name)
    put(o, "Name", name)
    put(o, "Loot", raw(lootFor(name, seed)))
    put(o, "transitionParameters", jnull())
    put(o, "EscapeTimeLimit", 40)
    put(o, "UnixDateTime", nowSeconds)
    result = done(o).text

proc raidConfiguration*(body: string): string =
  ## Echoed back with the ids the client needs. The client sends its own choice
  ## of map, time and side; the server's part is to accept it and give the raid
  ## an id both ends can refer to afterwards.
  var o = obj()
  put(o, "profileId", field(body, "profileId").asText(""))
  put(o, "raidId", newId())
  put(o, "location", field(body, "location").asText("factory4_day"))
  put(o, "timeVariant", field(body, "timeVariant").asText("CURR"))
  put(o, "raidMode", field(body, "raidMode").asText("Local"))
  put(o, "side", field(body, "side").asText("Pmc"))
  result = done(o).text

proc timeFlow(spelling: string; known: var bool): float =
  ## `TimeFlowType`, as the client spells it, as a multiplier.
  ##
  ## The enum in the reference dump is `x0, x0_14, x0_25, x0_5, x1, x2, x4, x8`
  ## -- a leading `x`, an underscore where the decimal point goes. Read from the
  ## spelling rather than from a table of the eight, so that a client sending
  ## `x3` is understood rather than refused, and a client sending something that
  ## is not a multiplier at all is refused rather than read as 1.
  known = false
  result = 0.0
  if spelling.len < 2 or (spelling[0] != 'x' and spelling[0] != 'X'):
    return
  var digits = ""
  for i in 1 ..< spelling.len:
    let ch = spelling[i]
    if ch == '_':
      digits.add '.'
    elif ch >= '0' and ch <= '9':
      digits.add ch
    else:
      return
  if digits.len == 0:
    return
  known = true
  result = parseNumber(digits)

const MaxTimeFlow = 8.0
  ## The ceiling of `TimeFlowType`, used when the client did not send one.
  ##
  ## It has to be a *ceiling* rather than a guess, and this is the one number
  ## here where that matters. A raid clock that runs slower than the truth
  ## makes the raid's span look shorter than it is, and a span that is too
  ## short is a span that fits inside a window it really crossed -- which is a
  ## kill credited that was not earned. Reading the acceleration this server
  ## publishes in `/client/weather` would be worse still: its shipped value is
  ## **0**, which would collapse every raid to a single instant and credit
  ## almost everything. `x8` is the largest value the enum admits, so the span
  ## it produces cannot be too short, and every error it makes is a refusal.

proc raidClock*(cfgBody: string): RaidClock =
  ## The in-game clock a `RaidSettings` establishes, for
  ## `emu/questcond.daytimeVerdict`.
  ##
  ## ## What it reads, and what it refuses to read
  ##
  ## `RaidSettings.TimeAndWeatherSettings.HourOfDay` is a `Nullable<Int32>` and
  ## is the only member of the whole request that names an hour. Everything
  ## else the client sends about time says *which* time was picked, not what it
  ## is: `TimeVariant` is a two-valued `CURR`/`PAST` selector and
  ## `IsNightRaid` is a boolean. Neither can establish that a raid's whole span
  ## sits inside `22 -> 07`, so neither is read here, and a request carrying
  ## only those is refused rather than turned into an hour by a rule this
  ## repository would have had to invent. *(A raid has never been run against
  ## BSG's client, so which of the three it actually posts is unknown. If it
  ## turns out to post `timeVariant` alone, this closes nothing and the refusal
  ## is the honest answer.)*
  ##
  ## `IsRandomTime` refuses the whole clock: it is the client saying the hour it
  ## sent is not the hour it will play.
  ##
  ## The span is the map's own `EscapeTimeLimit` -- present on all 19 maps,
  ## Customs 40 minutes, `factory4_day` 20, Streets 50 -- times the flow rate.
  ## A map this database has no base for, or one whose limit is absent, zero or
  ## longer than half a day, decides nothing: `develop` at 60000 minutes and
  ## `hideout` at 99999 are exactly that, and neither is a raid.
  result = unknownClock()
  let tw = field(cfgBody, "timeAndWeatherSettings")
  if not tw.found:
    return
  if tw.field("isRandomTime").asBool(false):
    return
  let hourNode = tw.field("hourOfDay")
  if not hourNode.found or hourNode.isNull or hourNode.isText:
    return
  let hour = hourNode.asFloat(-1.0)
  if hour < 0.0 or hour > 23.0:
    return

  var flow = MaxTimeFlow
  let spelling = tw.field("timeFlowType").asText("")
  if spelling.len > 0:
    var flowKnown = false
    let parsed = timeFlow(spelling, flowKnown)
    if not flowKnown or parsed < 0.0:
      return
    flow = parsed

  let name = canonicalLocation(field(cfgBody, "location").asText(""))
  if name.len == 0:
    return
  let base = locationBase(name)
  if base.len == 0:
    return
  let limitNode = field(base, "EscapeTimeLimit")
  if not limitNode.found:
    return
  let limit = limitNode.asFloat(0.0)
  if limit <= 0.0 or limit > 720.0:
    return

  let span = limit / 60.0 * flow
  if span >= 24.0:
    return
  result = RaidClock(known: true, startHour: hour, spanHours: span)

proc civilFromDays(z0: int): (int, int, int) =
  ## Days since 1970-01-01 -> (year, month, day). Howard Hinnant's algorithm.
  var z = z0 + 719468
  let era = (if z >= 0: z else: z - 146096) div 146097
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let d = doy - (153 * mp + 2) div 5 + 1
  let m = (if mp < 10: mp + 3 else: mp - 9)
  result = ((if m <= 2: y + 1 else: y), m, d)

proc p2(n: int): string = (if n < 10: "0" else: "") & $n

proc wxDate(ts: int): string =
  ## "yyyy-MM-dd" -- what the weather serializer parses with ParseExact. An
  ## empty string (what this used to send) is a FormatException in
  ## `EFT.Weather.WeatherSerializer.Deserialize` that stalls the menu load.
  let (y, m, d) = civilFromDays(ts div 86400)
  result = $y & "-" & p2(m) & "-" & p2(d)

proc wxTime(ts: int): string =
  ## "HH:mm:ss"
  let s = ((ts mod 86400) + 86400) mod 86400
  result = p2(s div 3600) & ":" & p2((s mod 3600) div 60) & ":" & p2(s mod 60)

proc wxDateTime(ts: int): string = wxDate(ts) & " " & wxTime(ts)

proc weatherFrom*(stored: string; nowSeconds: int): string =
  ## The sky, out of `stored` when there is one and dull when there is not.
  ##
  ## ## `weather` is a mod extension point, and this is the note that says so
  ##
  ## Write the **whole response** to the database path `weather` and it is what
  ## the client gets:
  ##
  ##     dbWrite("weather", """{"season": 3, "acceleration": 0,
  ##                            "weather": {"temp": -14, "cloud": 0.8,
  ##                                        "rain": 2, "rain_intensity": 0.4,
  ##                                        "wind_speed": 6, "fog": 0.3}}""")
  ##
  ## Only `timestamp`, `time` and `date` are filled in here, because those three
  ## have to be *now* and cannot be written into a static table. Everything else
  ## is taken as written: this does not average, clamp or second-guess a mod's
  ## numbers.
  ##
  ## Why it is a path at all. This used to be a constant with nothing behind it,
  ## which meant a mod shipping arctic weather had nowhere to put it. It could
  ## not register `/client/weather` either -- the backend refuses a second
  ## registration of a path, correctly -- so the whole feature was unreachable
  ## through no fault of the mod. A constant is a fine default and a bad only
  ## answer.
  ##
  ## And why the path is not SPT's own weather file. `aowl importdb`
  ## deliberately does not import `configs/weather.json`, and that decision is
  ## right: that file is the *generator's settings* -- `presetWeights.SUNNY.
  ## clouds` is a weight in a table something rolls against -- not the rendered
  ## `{season, acceleration, weather}` the client reads. Importing it would put
  ## a table of weights where a response goes, and the client would read a
  ## weight as a temperature. The fallback below is the shipped answer until
  ## something *renders* weather; a mod that wants real weather writes the
  ## rendered thing here.
  if stored.len > 0:
    var o = parseObject(stored)
    if o.ok:
      var inner = parseObject(getRaw(o, "weather"))
      if not inner.ok:
        inner = newDoc()
      setNumber(inner, "timestamp", nowSeconds)
      if not has(inner, "time"):
        setText(inner, "time", wxDateTime(nowSeconds))
      if not has(inner, "date"):
        setText(inner, "date", wxDate(nowSeconds))
      setRaw(o, "weather", text(inner))
      if not has(o, "acceleration"):
        setNumber(o, "acceleration", 7)
      if not has(o, "season"):
        setNumber(o, "season", 1)
      setText(o, "time", wxTime(nowSeconds))
      setText(o, "date", wxDate(nowSeconds))
      return text(o)
  var w = obj()
  put(w, "timestamp", nowSeconds)
  put(w, "cloud", 0.0)
  put(w, "wind_speed", 1)
  put(w, "wind_direction", 1)
  put(w, "wind_gustiness", 0.0)
  put(w, "rain", 1)
  put(w, "rain_intensity", 0.0)
  put(w, "fog", 0.0)
  put(w, "temp", 18)
  put(w, "pressure", 760)
  put(w, "time", wxDateTime(nowSeconds))
  put(w, "date", wxDate(nowSeconds))
  var o = obj()
  put(o, "acceleration", 7)
  put(o, "time", wxTime(nowSeconds))
  put(o, "date", wxDate(nowSeconds))
  put(o, "weather", w)
  put(o, "season", 1)
  result = done(o).text

proc weather*(nowSeconds: int): string =
  ## What `/client/weather` answers with: the database's `weather` when it has
  ## one, and the constant above when it does not.
  let stored = dbRead("weather")
  result = weatherFrom(if stored.ok: stored.raw else: "", nowSeconds)

# ---------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------
#
# Two things in this module are arithmetic over a table and are reachable from
# `emutest` only as "a response arrived":
#
# - **what `/client/locations` leaves out.** The defect this replaced was not a
#   wrong answer, it was a right answer that carried the whole game's loot with
#   it. No request the client makes says "and nothing else came back", so the
#   only place that can be asserted is here, against a fixture that carries a
#   map's `looseLoot` and a `staticAmmo` table and then checks they are absent
#   from the body. A test written on a fixture without loot would pass on a
#   route that still sent all of it.
# - **the weather fallback.** The fixtures carry no `weather`, so every route
#   test sees the constant and none of them can tell the constant apart from a
#   mod's table being ignored. Both halves are checked here from literals.

const
  ChkLocations = """{"locations":{
    "bigmap": {"base": {"_Id": "56f40101d2720b2a4d8b45d6", "Name": "Customs",
                        "BotMax": 12, "Loot": []},
               "staticAmmo": {"Caliber762x39": [{"tpl": "ammo1"}]},
               "looseLoot": {"spawnpointsForced": [],
                             "spawnpoints": [{"template": {"Id": "sp1"}}]}},
    "factory4_day": {"base": {"_Id": "55f2d3fd4bdc2d5f408b4567",
                              "Name": "Factory"}},
    "nameless": {"base": {"Name": "a map whose base carries no _Id"}},
    "paths": [{"Source": "55f2d3fd4bdc2d5f408b4567",
               "Destination": "56f40101d2720b2a4d8b45d6", "Event": false}]
  }}"""
    ## Four members under `locations`, and only three of them are maps.

  ChkNoPaths = """{"locations":{
    "bigmap": {"base": {"_Id": "56f40101d2720b2a4d8b45d6", "Name": "Customs"}}
  }}"""

  ChkWeather = """{"season": 3, "acceleration": 5,
                   "weather": {"temp": -14, "cloud": 0.8, "timestamp": 1}}"""

proc selfCheckRaid*(into: var seq[string]): bool =
  ## Pure, over the literals above. True when it added nothing.
  let before = into.len
  let d = textDb(ChkLocations)
  let idx = buildLocationIndex(d)

  # The map list is the maps, and `paths` is not one of them.
  if idx.names.len != 3:
    into.add "raid: the map index lists " & $idx.names.len &
             " map(s) out of a table with three and a paths array"
  for name in idx.names:
    if name == "paths":
      into.add "raid: the transit graph was listed as a map, which puts an " &
               "entry on the map screen that cannot be loaded"

  let body = locationsBody(d, idx)
  let maps = field(body, "locations")
  let listed = keys(maps)
  if listed.len != 3:
    into.add "raid: /client/locations listed " & $listed.len & " map(s)"

  # Keyed by `_Id`, which is what `LocationsGenerateAllResponse` says and what
  # `paths` is written in. The map with no `_Id` keeps its database key rather
  # than vanishing.
  if not maps.field("56f40101d2720b2a4d8b45d6").found:
    into.add "raid: the map list is not keyed by _Id"
  if maps.field("bigmap").found:
    into.add "raid: the map list is keyed by directory name, which no `paths` " &
             "entry can be resolved against"
  if not maps.field("nameless").found:
    into.add "raid: a map whose base has no _Id was dropped from the list " &
             "rather than listed under its database key"

  # What the route is *for*: the descriptions, without the loot. Checked as an
  # absence, because that is what the defect was.
  if not body.contains("\"Customs\"") or not body.contains("\"Factory\""):
    into.add "raid: the map list lost a map description"
  if body.contains("looseLoot") or body.contains("spawnpoints"):
    into.add "raid: /client/locations still carries looseLoot, which is the " &
             "560 MiB this route was answering with"
  if body.contains("staticAmmo") or body.contains("Caliber762x39"):
    into.add "raid: /client/locations still carries staticAmmo"
  if body.len >= sub(d, "locations").len:
    into.add "raid: the map list is no smaller than the whole locations " &
             "subtree it was cut down from"

  # The transit graph: the database's when it has one, BSG's own when it has
  # not, and empty when neither is installed.
  #
  # This used to assert that a database with no graph answers `[]`, on the
  # ground that a graph must never be invented. That is still the rule -- what
  # changed is that `data/post1/locationpaths.json` is not an invention. It is
  # the real backend's own 18 edges for this build, and answering `[]` when it
  # is installed is a client told there is no transit anywhere while the maps
  # it is standing on have transit exits.
  #
  # So the check is now two claims, and the **first** is the one that protects
  # the original rule: a database that carries a graph must have that graph
  # answered, not the fallback. Getting that backwards would silently override
  # a real import with a canned table.
  if count(field(body, "paths")) != 1:
    into.add "raid: the transit graph did not survive the map list"
  let dbPaths = sub(d, "locations.paths")
  if dbPaths.len > 0 and dbPaths != "[]" and
     field(body, "paths").raw != dbPaths:
    into.add "raid: a database with a transit graph had it replaced by " &
             field(body, "paths").raw
  let bare = textDb(ChkNoPaths)
  let bareBody = locationsBody(bare, buildLocationIndex(bare))
  let fallbackPaths = post1Table("locationpaths")
  let wantBare = if fallbackPaths.len > 0: fallbackPaths else: "[]"
  if field(bareBody, "paths").raw != wantBare:
    into.add "raid: a database with no transit graph answered " &
             field(bareBody, "paths").raw & " rather than " &
             (if fallbackPaths.len > 0: "the installed post-1.0 graph"
              else: "an empty list")

  # Naming a map either way round, and refusing to guess at a third.
  if resolveLocation(idx, "bigmap") != "bigmap":
    into.add "raid: a map named by its database key did not resolve"
  if resolveLocation(idx, "56f40101d2720b2a4d8b45d6") != "bigmap":
    into.add "raid: a map named by _Id resolved to " &
             resolveLocation(idx, "56f40101d2720b2a4d8b45d6")
  if resolveLocation(idx, "no_such_map") != "":
    into.add "raid: an unknown map resolved to " &
             resolveLocation(idx, "no_such_map") & " rather than to nothing"

  # The weather fallback, which is what every server without a `weather` table
  # answers with, and the extension point that overrides it.
  let dull = weatherFrom("", 4242)
  if field(dull, "weather.temp").asInt(-1) != 18:
    into.add "raid: the weather fallback answered " &
             $field(dull, "weather.temp").asInt(-1) & " degrees"
  if field(dull, "weather.timestamp").asInt(0) != 4242:
    into.add "raid: the weather fallback did not stamp the current time"
  if not field(dull, "season").found or not field(dull, "acceleration").found:
    into.add "raid: the weather fallback is missing a field the client reads"

  let modded = weatherFrom(ChkWeather, 99)
  if field(modded, "weather.temp").asInt(0) != -14:
    into.add "raid: a mod's weather was overridden by the constant, which " &
             "makes the database path decoration"
  if field(modded, "season").asInt(0) != 3:
    into.add "raid: a mod's season did not survive"
  if field(modded, "weather.timestamp").asInt(0) != 99:
    into.add "raid: a mod's stale timestamp was served instead of now"

  result = into.len == before
