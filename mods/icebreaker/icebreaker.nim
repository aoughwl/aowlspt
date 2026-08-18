## Icebreaker — a from-scratch nimony port of the *ManimalIcebreaker* map
## backport's server half, `com.manimal.icebreaker`, for aowlspt.
##
##     aowl build-mod mods/icebreaker
##
## Upstream: Manimal / danauraborealis —
## https://github.com/danauraborealis/ManimalIcebreaker — MIT, see LICENSE.txt
## beside this file. This is a modified redistribution under the same terms; the
## copyright holder is unchanged. Upstream depends on tarkin's Climbable Ladders
## (`bmpq/spt-ladders`) for the ship's ladders; that is a separate client mod and
## is not part of this port.
##
## ---------------------------------------------------------------------------
## WHAT A MAP MOD ACTUALLY IS
## ---------------------------------------------------------------------------
##
## Almost all of Icebreaker's mass is **assets**: a scene bundle, a scenes
## preset, culling bakes, acoustics, an AI navmesh bake, weather and sky
## tables, five prop bundles, and about 16MB of authored loot JSON. None of
## that is code and none of it is portable — it is shipped as files and loaded
## by the client's own bundle system.
##
## What the *mod* does is make the server and the client agree that the map
## exists, and this file is that job:
##
##   * **Rebind a slot.** Upstream does not add a location; it rebinds the
##     dormant `suburbs` slot — a stub BSG ships disabled, with an empty scene
##     and a real entry everywhere the server enumerates maps. Hijacking it
##     means every native lookup (`GetLocation("suburbs")`, the raid
##     configuration, local loot, insurance, scav timings) resolves with no
##     patching at all. A genuinely new id is the thing that keeps failing for
##     people, because every table keyed by location has to learn about it.
##   * **Point the slot at the scene.** `Base.Scene` is a bundle path plus an
##     rcid. Scene loading is data-driven, so this one field is the whole
##     handoff from "the server says the map is here" to "the client loads it".
##   * **Rebrand it.** The map screen prints the *locale* string for the slot,
##     not `Base.Name`, so without a locale pass the dot on the map still says
##     SUBURBS under an Icebreaker banner. Keys are `<_Id> Name`,
##     `<_Id> Description`, and the bare `Suburbs`.
##   * **Watch for crossings.** Several of upstream's quests are gated on
##     "come back alive from the icebreaker", which is not a start condition
##     any server evaluates — Quest, Level, TraderStanding and TraderLoyalty
##     are the whole vocabulary. Upstream watches raid ends and records the
##     profile. This does the same, through the emulator's `tarkov.raid.*`
##     events instead of by intercepting `/client/match/local/end`.
##
## Everything here goes through `dbWrite`, which **merges**: the location base
## keeps every field the database already had for the slot, and two mods
## editing sibling fields of the same location do not clobber each other. What
## `dbWrite` will not do is *create* a path, so `dbPut` below wraps it — see the
## comment there, which is one of the two things this port had to work around.
##
## ---------------------------------------------------------------------------
## WHAT IS DELIBERATELY LEFT OUT
## ---------------------------------------------------------------------------
##
## * **The scene bundle and every other asset.** Out of scope, as above.
## * **The authored loot tables.** `looseLoot.json` and `staticContainers.json`
##   are 8MB and 50KB of extracted coordinates. They are data files, not code,
##   and this mod writes the *table shape* (empty, valid) so a raid starts
##   clean; dropping the real files in under the same paths is a data step.
## * **The banner image routes.** Upstream calls `ImageRouter.AddRoute` to
##   serve `/files/banners/<name>` off disk. This ABI has no static-file route
##   and a mod cannot read its own directory, so the banner *entries* are
##   written into the base and the images are not served. Named as a gap in the
##   report rather than faked with an empty response, which would render a
##   broken image instead of the default art.
## * **Per-profile map locking.** Upstream recomputes `Enabled`/`Locked` per
##   request inside its own `/client/locations` router, which runs after the
##   core one and rewrites its output. Here `/client/locations` belongs to
##   `mods/tarkov` and the backend refuses a second registration of the same
##   exact route — there is no route chaining and no output filter. So the lock
##   is applied at the database level and is therefore **global**: on or off for
##   the install, from `lockUntilQuestComplete`. The per-profile answer is
##   still computed and served at `/icebreaker/state`, so a client or a future
##   route-chaining API can use it.
## * **The quest-visibility gates.** Same reason: `/client/quest/list` is the
##   emulator's. The gate *evaluation* is here and answers at
##   `/icebreaker/state`; the filtering is not.
## * **The Fika coop paths.** No Fika on this side of 1.0.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json

const
  ModGuid = "aowl.icebreaker"
  ModName = "Icebreaker"
  ModAuthor = "Manimal (ported by savannt)"
  ModVersion = "1.0.0"

  # The ship blurb, shared by the loading-screen banner and the map-select card
  # so the two cannot drift. Live breaks it into two paragraphs at "It appears",
  # so the break lives in the text rather than being a card-only flourish.
  Blurb =
    "In the Gulf of Finland, trapped within the blockade surrounding Tarkov, " &
    "lies the nuclear-powered icebreaker \"Boreas\", owned by the logistics " &
    "corporation Paradigm Shipping. The exact purpose of \"Boreas\" and the " &
    "cargo it carries remain unknown.\n\nIt appears that Paradigm Shipping " &
    "and TerraGroup made special efforts to minimize any mention of the " &
    "icebreaker in the press and keep its routes and assignments classified."

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

var cfgSlotId = "suburbs"
var cfgSlotObjectId = "5714dc342459777137212e0b"
var cfgDisplayName = "Icebreaker"
var cfgDescription = ""
var cfgScenePath = "maps/icebreaker.bundle"
var cfgSceneRcid = "icebreaker.scenespreset.asset"

var cfgEnabled = true
var cfgDisabledForScav = true
var cfgDisabledScavExits = "Cellars,Gate 0"
var cfgInsurance = true
var cfgSafeLocation = false
var cfgOpenZones = "ZoneIcebreaker"

var cfgEscapeTimeLimit = 50
var cfgEscapeTimeLimitCoop = 50
var cfgEscapeTimeLimitPve = 50
var cfgMinPlayers = 1
var cfgMaxPlayers = 3
var cfgMaxCoopGroup = 6
var cfgRequiredPlayerLevelMin = 0
var cfgRequiredPlayerLevelMax = 100
var cfgAveragePlayerLevel = 60
var cfgAveragePlayTime = 50

var cfgIconX = 91
var cfgIconY = 747

var cfgBotCap = 40
var cfgMaxBotPerZone = 2
var cfgBotStop = 2400

var cfgGlobalLootChanceModifier = 0.27
var cfgGlobalContainerChanceModifier = 1.0

var cfgExitLocaleKey = "Icebreaker_Exit_Heli"
var cfgExitLocaleName = "Helicopter"
var cfgRebrandLocales = true

var cfgLockUntilQuestComplete = false
var cfgFinalQuestId = ""

var cfgCrossingWatch = true
var cfgGateQuests: seq[string] = @[]
var cfgBundles: seq[string] = @[]

proc cfgText(key, default: string): string =
  ## Config strings, with the JSON quotes taken off if the host left them on.
  ##
  ## The backend strips them and the client/sim host does not -- it hands back
  ## the raw token so a caller can tell `"1"` from `1`. A value used to build a
  ## database path must be the string either way: without this, the slot id
  ## reads `"suburbs"` and every write lands at `locations."suburbs".base`,
  ## which is a real path that nothing else ever reads.
  var s = setting(key).asText(default)
  if s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"':
    s = s.substr(1, s.len - 2)
  result = s

proc textList(key: string): seq[string] =
  ## A JSON array of strings out of config, as a seq. `aowlspt/json` reads it
  ## rather than a hand-rolled scan so that a trailing comma or a stray escape
  ## is a parse failure here instead of a silently truncated list later.
  result = @[]
  let rawText = setting(key).asText("[]")
  let items = each(whole(rawText))
  for it in items:
    let s = it.asText("")
    if s.len > 0:
      result.add s

proc loadConfig() =
  cfgSlotId = cfgText("slotId", "suburbs")
  cfgSlotObjectId = cfgText("slotObjectId", "5714dc342459777137212e0b")
  cfgDisplayName = cfgText("displayName", "Icebreaker")
  cfgDescription = cfgText("description",
                           "The nuclear icebreaker BOREAS, locked in arctic ice.")
  cfgScenePath = cfgText("scenePath", "maps/icebreaker.bundle")
  cfgSceneRcid = cfgText("sceneRcid", "icebreaker.scenespreset.asset")

  cfgEnabled = setting("enabled").asBool(true)
  cfgDisabledForScav = setting("disabledForScav").asBool(true)
  cfgDisabledScavExits = cfgText("disabledScavExits", "Cellars,Gate 0")
  cfgInsurance = setting("insurance").asBool(true)
  cfgSafeLocation = setting("safeLocation").asBool(false)
  cfgOpenZones = cfgText("openZones", "ZoneIcebreaker")

  cfgEscapeTimeLimit = setting("escapeTimeLimit").asInt(50)
  cfgEscapeTimeLimitCoop = setting("escapeTimeLimitCoop").asInt(50)
  cfgEscapeTimeLimitPve = setting("escapeTimeLimitPVE").asInt(50)
  cfgMinPlayers = setting("minPlayers").asInt(1)
  cfgMaxPlayers = setting("maxPlayers").asInt(3)
  cfgMaxCoopGroup = setting("maxCoopGroup").asInt(6)
  cfgRequiredPlayerLevelMin = setting("requiredPlayerLevelMin").asInt(0)
  cfgRequiredPlayerLevelMax = setting("requiredPlayerLevelMax").asInt(100)
  cfgAveragePlayerLevel = setting("averagePlayerLevel").asInt(60)
  cfgAveragePlayTime = setting("averagePlayTime").asInt(50)

  cfgIconX = setting("iconX").asInt(91)
  cfgIconY = setting("iconY").asInt(747)

  cfgBotCap = setting("botCap").asInt(40)
  cfgMaxBotPerZone = setting("maxBotPerZone").asInt(2)
  cfgBotStop = setting("botStop").asInt(2400)

  cfgGlobalLootChanceModifier = setting("globalLootChanceModifier").asFloat(0.27)
  cfgGlobalContainerChanceModifier =
    setting("globalContainerChanceModifier").asFloat(1.0)

  cfgExitLocaleKey = cfgText("exitLocaleKey", "Icebreaker_Exit_Heli")
  cfgExitLocaleName = cfgText("exitLocaleName", "Helicopter")
  cfgRebrandLocales = setting("rebrandLocales").asBool(true)

  cfgLockUntilQuestComplete = setting("lockUntilQuestComplete").asBool(false)
  cfgFinalQuestId = cfgText("finalQuestId", "")

  cfgCrossingWatch = setting("crossingWatch").asBool(true)
  cfgGateQuests = textList("crossingGateQuests")
  cfgBundles = textList("bundles")

  if cfgDescription.len == 0:
    cfgDescription = Blurb

var gRegistered = false

proc lastDot(s: string): int =
  ## strutils here has no `rfind`, and a hand-rolled backward scan is shorter
  ## than the alternative anyway.
  result = -1
  for i in 0 ..< s.len:
    if s[i] == '.':
      result = i

proc dbPut(path: string; value: Json): Status =
  ## Write `value` at `path`, creating the path if it is not there yet.
  ##
  ## `dbWrite` **merges into an object that already exists**: patching
  ## `locations.suburbs.looseLoot` on a database where that member has never
  ## been written is refused with "no such database path", which is the right
  ## call for a patch and the wrong one for a mod that is adding a table. So a
  ## miss falls back to merging a one-member object into the parent -- and if
  ## the parent is missing too, into *its* parent, wrapping as it goes.
  ##
  ## The recursion stops one segment from the root: the root document itself
  ## cannot be patched (an empty path locates nothing), so a database with no
  ## top-level `locations` at all is reported rather than silently skipped.
  if dbWrite(path, value) == Ok:
    return Ok
  let cut = lastDot(path)
  if cut < 0:
    return ErrNotFound
  let parent = path.substr(0, cut - 1)
  let leaf = path.substr(cut + 1)
  result = dbPut(parent, raw("{\"" & leaf & "\":" & value.text & "}"))

proc dbPut(path: string; valueText: string): Status =
  result = dbPut(path, raw(valueText))

proc dbPut(path: string; value: JsonObject): Status =
  result = dbPut(path, done(value))

proc basePath(): string = "locations." & cfgSlotId & ".base"

# ---------------------------------------------------------------------------
# Registering the location
# ---------------------------------------------------------------------------

proc sceneObject(): JsonObject =
  result = obj()
  put(result, "path", cfgScenePath)
  put(result, "rcid", cfgSceneRcid)

proc bannerEntry(id, file: string): JsonObject =
  ## One entry of `Base.Banners`. The client asks for the picture by its path;
  ## nothing in this ABI serves it (see the module comment), so the entry is
  ## written and the image is the install's problem.
  var pic = obj()
  put(pic, "file", file)
  put(pic, "path", "banners/" & file)
  put(pic, "rcid", "")
  result = obj()
  put(result, "id", id)
  put(result, "pic", pic)

proc locationBase(): JsonObject =
  ## The fields that make the slot into the map. A *merge*, so everything the
  ## slot already carried -- spawn points, exits, bot settings the database has
  ## -- survives untouched; only what Icebreaker actually changes is named.
  result = obj()
  put(result, "Id", cfgSlotId)
  put(result, "_Id", cfgSlotObjectId)
  put(result, "Name", cfgDisplayName)
  put(result, "Description", cfgDescription)
  put(result, "Scene", sceneObject())

  # `Enabled` is the dormant flag the suburbs stub ships with: false hides the
  # dot from the map screen entirely rather than greying it out. The entry stays
  # in the response either way, which matters because the client resolves a
  # transit's TARGET through the location list -- deleting it breaks crossings
  # from other maps.
  put(result, "Enabled", cfgEnabled)
  put(result, "Locked", false)
  put(result, "DisabledForScav", cfgDisabledForScav)
  put(result, "DisabledScavExits", cfgDisabledScavExits)
  put(result, "Insurance", cfgInsurance)
  put(result, "SafeLocation", cfgSafeLocation)
  put(result, "OpenZones", cfgOpenZones)
  put(result, "IsSecret", false)

  put(result, "EscapeTimeLimit", cfgEscapeTimeLimit)
  put(result, "EscapeTimeLimitCoop", cfgEscapeTimeLimitCoop)
  put(result, "EscapeTimeLimitPVE", cfgEscapeTimeLimitPve)
  put(result, "MinPlayers", cfgMinPlayers)
  put(result, "MaxPlayers", cfgMaxPlayers)
  put(result, "MaxCoopGroup", cfgMaxCoopGroup)
  put(result, "RequiredPlayerLevelMin", cfgRequiredPlayerLevelMin)
  put(result, "RequiredPlayerLevelMax", cfgRequiredPlayerLevelMax)
  put(result, "AveragePlayerLevel", cfgAveragePlayerLevel)
  put(result, "AveragePlayTime", cfgAveragePlayTime)

  # Where the dot sits on the world map: top-left coastal, matching live.
  put(result, "IconX", cfgIconX)
  put(result, "IconY", cfgIconY)

  put(result, "MaxBotPerZone", cfgMaxBotPerZone)
  put(result, "BotStop", cfgBotStop)
  put(result, "GlobalLootChanceModifier", cfgGlobalLootChanceModifier)
  put(result, "GlobalLootChanceModifierPvE", cfgGlobalLootChanceModifier)
  put(result, "GlobalContainerChanceModifier", cfgGlobalContainerChanceModifier)

  # Upstream replaces the retail banner list wholesale rather than appending:
  # the shipped list names MongoId files nobody has, so appending rolls a
  # missing image most loading screens.
  var banners = arr()
  add(banners, bannerEntry("icebreaker_cover", "icebreaker_cover.jpg"))
  add(banners, bannerEntry("blackdiv_banner", "blackdiv_banner.jpg"))
  add(banners, bannerEntry("wedge_banner", "wedge_banner.jpg"))
  put(result, "Banners", banners)

proc lootTables(): Status =
  ## Valid, empty loot tables for the slot.
  ##
  ## The suburbs stub ships a base and nothing else, so a server that generates
  ## raid loot for it walks into a null loose-loot set, a null static-loot set
  ## and a null container set. An empty table is not a placeholder here: it is
  ## the difference between a raid that starts with nothing on the floor and a
  ## raid that does not start. Dropping upstream's authored files in over these
  ## paths is a data step and needs no code change -- `dbWrite` merges.
  var loose = obj()
  var count = obj()
  put(count, "mean", 0)
  put(count, "std", 0)
  put(loose, "spawnpointCount", count)
  put(loose, "spawnpoints", arr())
  put(loose, "spawnpointsForced", arr())

  var containers = obj()
  put(containers, "staticWeapons", arr())
  put(containers, "staticContainers", arr())
  put(containers, "staticForced", arr())

  let root = "locations." & cfgSlotId
  var st = dbPut(root & ".looseLoot", done(loose))
  if st != Ok: return st
  st = dbPut(root & ".staticContainers", done(containers))
  if st != Ok: return st
  st = dbPut(root & ".staticLoot", emptyObject())
  if st != Ok: return st
  st = dbPut(root & ".staticAmmo", emptyObject())
  result = st

proc localeDocument(): JsonObject =
  ## The rebrand. The map screen and the raid summaries print the *locale*
  ## string for the slot, not `Base.Name` -- `LocationInfoPanel` does
  ## `(location._Id + " Description").Localized()` -- so without this the dot
  ## keeps saying SUBURBS and the card keeps advertising the commuter areas of
  ## Tarkov underneath an Icebreaker banner.
  result = obj()
  put(result, cfgSlotObjectId & " Name", cfgDisplayName)
  put(result, cfgSlotObjectId & " Description", cfgDescription)
  put(result, "Suburbs", cfgDisplayName)

  # The extraction panel prints the exit's own name through the locale, and the
  # "EXFIL01" tag beside it is generated from the point index rather than from
  # us. With no entry the raw exit id renders, underscores and all. Renaming the
  # exit itself is not an option: that name is the key the panel, the exfil
  # controller and the raid-end ExitName all match on.
  put(result, cfgExitLocaleKey, cfgExitLocaleName)

  put(result, "icebreaker_cover Name", cfgDisplayName)
  put(result, "icebreaker_cover Description", cfgDescription)
  put(result, "blackdiv_banner Name", "Black Division")
  put(result, "wedge_banner Name", "\"The Wedge's\" Special Squadron")

proc rebrandLocales(): int =
  ## Written into *every* language the database carries. English text in every
  ## language beats a raw key showing through on the loading screen, and it is
  ## what upstream does.
  result = 0
  let doc = done(localeDocument())
  let globals = dbRead("locales.global")
  var langs: seq[string] = @[]
  if globals.ok and globals.raw.len > 0:
    langs = keys(whole(globals.raw))
  if langs.len == 0:
    # A database with no locales at all: seed English, so the slot still reads
    # as Icebreaker on a server started with nothing.
    langs = @["en"]
  for lang in langs:
    if dbPut("locales.global." & lang, doc) == Ok:
      inc result

# ---------------------------------------------------------------------------
# Crossings
# ---------------------------------------------------------------------------
#
# "Extract from the icebreaker once" is not a quest start condition any server
# evaluates -- Quest, Level, TraderStanding and TraderLoyalty are the whole
# vocabulary -- so upstream watches raid ends instead and records the profile.
#
# Here the same fact arrives as events from the emulator: `tarkov.raid.configured`
# names the location a raid is being set up on, and `tarkov.raid.ended` names the
# profile that came out of it. Watching events rather than intercepting
# `/client/match/local/end` means this mod never sits in the path of a request it
# does not own, and the raid endpoint keeps exactly one handler.

var gCurrentLocation = ""
var gCrossings = 0

proc crossingKey(profile: string): string = "crossed." & profile

proc onRaidConfigured(payload: string): string =
  ## The location comes through as it was configured; hold it until the raid
  ## ends, because the end event carries the profile and not the map.
  let loc = field(payload, "location").asText("")
  if loc.len > 0:
    gCurrentLocation = loc
  result = ""

proc onRaidEnded(payload: string): string =
  result = ""
  if gCurrentLocation != cfgSlotId:
    return
  let profile = field(payload, "profile").asText("")
  if profile.len == 0:
    return
  # A flat key of `[A-Za-z0-9._-]`, which a MongoId already is.
  var rec = obj()
  put(rec, "profile", profile)
  put(rec, "atMs", int(nowMs()))
  put(rec, "location", cfgSlotId)
  if save(crossingKey(profile), rec) == Ok:
    inc gCrossings
    success "icebreaker: " & profile & " came back from the crossing"
  else:
    warn "icebreaker: could not record a crossing for " & profile & ": " &
         lastError()

proc hasCrossed(profile: string): bool =
  result = profile.len > 0 and saved(crossingKey(profile))

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

proc onStatus(url, body, session: string): string =
  ## What the registration actually did, so an install can be checked without
  ## reading the log or guessing from the map screen.
  var o = obj()
  put(o, "mod", ModName)
  put(o, "version", ModVersion)
  put(o, "slot", cfgSlotId)
  put(o, "id", cfgSlotObjectId)
  put(o, "name", cfgDisplayName)
  put(o, "scene", sceneObject())
  put(o, "enabled", cfgEnabled)
  put(o, "locked", cfgLockUntilQuestComplete)
  put(o, "escapeTimeLimit", cfgEscapeTimeLimit)
  put(o, "botCap", cfgBotCap)
  put(o, "crossingsRecorded", gCrossings)
  put(o, "registered", gRegistered)
  let registered = dbRead(basePath() & ".Scene.path")
  put(o, "sceneInDatabase", registered.ok)
  result = done(o).text

proc onBundles(url, body, session: string): string =
  ## Upstream's `bundles.json` manifest. The bundles themselves are files this
  ## mod does not ship and cannot serve; naming them is still worth doing,
  ## because a client that knows which keys to expect can say which one is
  ## missing instead of failing to load the scene with no reason given.
  var manifest = arr()
  for key in cfgBundles:
    var e = obj()
    put(e, "key", key)
    put(e, "dependencyKeys", arr())
    add(manifest, e)
  var o = obj()
  put(o, "manifest", manifest)
  result = done(o).text

proc onState(url, body, session: string): string =
  ## The per-profile answers upstream computed inside its own copies of
  ## `/client/locations` and `/client/quest/list`. Those routes belong to the
  ## emulator here and the backend refuses a second registration of an exact
  ## route, so the *answers* are served and the *filtering* is not -- see the
  ## module comment. `session` is the client's session id, which is the only
  ## profile-shaped identity a route is handed.
  let crossed = hasCrossed(session)
  var gates = arr()
  for questId in cfgGateQuests:
    var g = obj()
    put(g, "quest", questId)
    put(g, "earned", crossed)
    add(gates, g)
  var o = obj()
  put(o, "session", session)
  put(o, "crossed", crossed)
  put(o, "locked", cfgLockUntilQuestComplete)
  put(o, "finalQuestId", cfgFinalQuestId)
  put(o, "gates", gates)
  result = done(o).text

proc onCrossings(url, body, session: string): string =
  var list = arr()
  let recorded = savedKeys("crossed.")
  for key in recorded:
    add(list, key.substr("crossed.".len))
  var o = obj()
  put(o, "profiles", list)
  result = done(o).text

# ---------------------------------------------------------------------------
# Load
# ---------------------------------------------------------------------------

proc registerLocation(): Status =
  ## Always returns `Ok`, and that is deliberate.
  ##
  ## A server started with no database at all is the normal first run -- the
  ## emulator is built to reach the menu on one -- and there the location write
  ## has nowhere to land. Failing the load there would take the mod's own
  ## routes down with it, so a status endpoint could not even be asked what
  ## went wrong. It degrades instead: the failure is logged once, `gRegistered`
  ## records it, and `/icebreaker/status` answers `false` for anyone who asks.
  let st = dbPut(basePath(), done(locationBase()))
  if st != Ok:
    gRegistered = false
    error "icebreaker: could not write " & basePath() & " (" & lastError() &
          "); the map is NOT registered. A database has to be loaded before " &
          "a location can be rebound -- start the backend with --db, or " &
          "check /icebreaker/status"
    return Ok
  gRegistered = true
  success "icebreaker: " & cfgSlotId & " rebound to " & cfgDisplayName &
          " -- scene " & cfgScenePath
  if lootTables() != Ok:
    warn "icebreaker: loot tables could not be seeded (" & lastError() &
         "); a raid on this slot may not start"
  else:
    info "icebreaker: empty-but-valid loot tables seeded; drop the authored " &
         "files over locations." & cfgSlotId & ".{looseLoot,staticLoot," &
         "staticContainers} to replace them"

  # The alive-bot cap. An unlisted map falls through to the shared default,
  # which on this map truncates the late trigger waves -- squads arriving short,
  # and half-built bots where a spawn was cut off partway. 40 is the trigger
  # table's own ceiling.
  if dbPut("configs.bot.maxBotCap." & cfgSlotId, $cfgBotCap) == Ok:
    info "icebreaker: alive-bot cap for " & cfgSlotId & " set to " & $cfgBotCap
  else:
    info "icebreaker: no bot config in this database; the cap was not written"

  # Scav raid timings are keyed by map id; without an entry the lookup misses.
  let factory = dbRead("configs.location.scavRaidTimeSettings.maps.factory4_day")
  if factory.ok and factory.raw.len > 0:
    discard dbPut("configs.location.scavRaidTimeSettings.maps." & cfgSlotId,
                  factory.raw)
    info "icebreaker: scav raid timings cloned from factory4_day"

  if cfgRebrandLocales:
    let n = rebrandLocales()
    if n > 0:
      success "icebreaker: rebranded " & $n & " locale(s) to " & cfgDisplayName
    else:
      warn "icebreaker: locale rebrand wrote nothing; the map dot will still " &
           "read Suburbs"

  if cfgLockUntilQuestComplete:
    if cfgFinalQuestId.len == 0:
      warn "icebreaker: lockUntilQuestComplete is on but finalQuestId is " &
           "empty; leaving the map open, which is what an unauthored chain " &
           "should do"
    else:
      discard dbPut(basePath(), "{\"Enabled\":false,\"Locked\":true}")
      warn "icebreaker: the map is locked for everyone until " &
           cfgFinalQuestId & " is complete. Per-profile locking needs a " &
           "route filter this ABI does not have; /icebreaker/state carries " &
           "the per-session answer"
  result = Ok

proc onLoad(): Status =
  loadConfig()
  success ModName & " " & ModVersion & " loaded on " & hostName()
  if side() != sideServer:
    info "icebreaker is a server mod; the scene and its assets are the " &
         "client's half and are not code"
    return Ok

  discard registerLocation()

  discard serve("/icebreaker/status", onStatus)
  discard serve("/icebreaker/bundles", onBundles)
  discard serve("/icebreaker/state", onState)
  discard serve("/icebreaker/crossings", onCrossings)

  if cfgCrossingWatch:
    if not storeReady():
      warn "icebreaker: this host has no persistent store, so crossings " &
           "cannot survive a restart; the gates will reopen every boot"
    discard onEvent("tarkov.raid.configured", onRaidConfigured)
    discard onEvent("tarkov.raid.ended", onRaidEnded)
    info "icebreaker: watching raid events for crossings of " & cfgSlotId &
         " (" & $cfgGateQuests.len & " gated quest(s))"
  Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideServer, sideSim},
  onLoad = onLoad)
