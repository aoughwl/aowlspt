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
## WHAT IT CHANGES, WHAT IT ASSUMES, AND WHAT IT HAS NEVER BEEN RUN AGAINST
## ---------------------------------------------------------------------------
##
## **What it changes.** Only the server's database, and only these paths:
##
##   * `locations.<slotId>.base` — 31 fields merged onto the dormant `suburbs`
##     stub: its name, description, scene, time limits, player counts, map-dot
##     coordinates, bot settings and banner list.
##   * `locations.<slotId>.{looseLoot,staticContainers,staticLoot,staticAmmo}` —
##     empty but structurally valid, so a raid on the slot starts rather than
##     walking into a null loot set.
##   * `locales.global.<every language the database has>` — eight rebrand keys,
##     so the map dot stops saying SUBURBS.
##   * `configs.bot.maxBotCap.<slotId>` and, if the database has one to copy,
##     `configs.location.scavRaidTimeSettings.maps.<slotId>`.
##
## Plus four routes of its own under `/icebreaker/`, and a subscription to
## `tarkov.raid.configured` / `tarkov.raid.ended` that records which profiles
## have come back from the map. It writes nothing outside those paths and it
## registers no route the emulator already owns.
##
## It also **announces the location it adds** — `aowlspt.locations.changed`
## when the registration lands, and the same announcement again in answer to
## `aowlspt.locations.hello`. A mod that decorates every location (SAIN sets
## each map's `BotLocationModifier`) otherwise decorates the maps that exist
## when *it* loads, which on a directory-walk load order silently excludes this
## one. See "Announcing the location" below.
##
## **What it assumes about the client.** Nothing, in the sense that matters:
## **this mod has no client half at all.** It never enters the game's process,
## it opens no IL2CPP runtime, it binds no method and it has no per-frame path —
## so there is nothing here to move onto `aowlspt/fast` and the self-test says
## so with a number rather than a shrug. What it assumes about the *game* is
## data-shaped and each assumption is one field: that `suburbs` is a slot the
## client will resolve, that `Base.Scene` is the whole handoff to the client's
## bundle loader, and that the map screen localises `<_Id> Name` and
## `<_Id> Description` rather than printing `Base.Name`. Every one of those is
## a field this mod writes and a reader can check at `/icebreaker/status`.
##
## **It has never been run against BSG's game.** Not once. The slot rebinding,
## the scene handoff and the locale keys are upstream's design and this port's
## reading of it; nothing here has seen a client load the scene.
## `aowl run mods/icebreaker` builds and parses back every document offline,
## which establishes that the JSON is JSON and the fields are the fields — and
## establishes nothing whatever about what Tarkov does with them.
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
import ice/tables
import ice/pending
import aowlspt/fast    # `perfCounter` only: this mod has no fast path to bind

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

var cfgMapTables = true
var cfgBossSpawns = false
var cfgArcticWeather = false
var cfgSpawnPointsFile = ""
var cfgExitsFile = "exits.json"
var cfgWavesFile = "waves.json"
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

  cfgMapTables = setting("mapTables").asBool(true)
  cfgBossSpawns = setting("bossSpawns").asBool(false)
  cfgArcticWeather = setting("arcticWeather").asBool(false)
  cfgSpawnPointsFile = cfgText("spawnPointsFile", "")
  cfgExitsFile = cfgText("exitsFile", "exits.json")
  cfgWavesFile = cfgText("wavesFile", "waves.json")
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

var gDbProbed = false
var gDbLoaded = false

proc databaseLoaded(): bool =
  ## Is there a database to write into at all?
  ##
  ## Asked once, and asked with a read. It used to be answered as a side effect
  ## of the write -- `dbWrite` refusing was how this mod discovered there was no
  ## database, which is what `gRegistered` and `/icebreaker/status` are built
  ## on. Buffered writes cannot answer it, so it is asked directly and the two
  ## concerns come apart: "is there a database" is a fact about the host, and
  ## "did the write land" is a fact about the flush.
  if not gDbProbed:
    gDbProbed = true
    gDbLoaded = dbRead("locations").ok
  result = gDbLoaded

proc dbPut(path: string; value: Json): Status =
  ## Buffer `value` at `path`. It reaches the database at the next `dbFlush()`.
  ##
  ## The path is created if it is not there yet -- `aowlspt/server`'s `dbWrite`
  ## does that now, and `ice/pending.nim` folds this mod's writes into one
  ## document per second-level path first, so the whole registration is three
  ## calls rather than thirteen. That module's header has the measurement; the
  ## short version is that a `dbWrite` costs the size of the database (41 MB on
  ## an import, about 130 ms) and not the size of the patch, so thirteen small
  ## writes were 1.5 seconds of boot.
  ##
  ## The status is the one a real write would have returned: `ErrNotFound` when
  ## there is no database, `Ok` when there is. Every caller here branches on
  ## exactly that question and none of them branches on when the bytes landed.
  if not databaseLoaded():
    return ErrNotFound
  pendPut(path, value.text)
  result = Ok

proc dbFlush() =
  ## Write everything buffered. Called at the end of the registration and at
  ## the top of the one route that reads a path this mod writes.
  if not dirty():
    return
  let n = flush()
  if n > 0:
    info "icebreaker: " & $n & " database write(s) carrying " &
         $bufferedWrites() & " buffered change(s)"

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

var gTables: TableReport

proc localeText(): string =
  ## Every string this mod puts in front of a player, built from
  ## `data/locales.json`.
  ##
  ## It used to be eight `put` calls in this procedure. That was fine until the
  ## exits arrived: an exit name has to have a locale entry or the extraction
  ## panel prints the raw id, and a hard-coded list of locale keys cannot be
  ## checked against `data/exits.json` — where two data files can be, and are,
  ## in both directions. Moving it to data is what made
  ## `checkLocaleCoversExits` possible at all.
  result = localeDocument(readData("locales.json"), cfgSlotObjectId,
                          cfgDisplayName, cfgDescription, gTables)

proc rebrandLocales(): int =
  ## Written into *every* language the database carries. English text in every
  ## language beats a raw key showing through on the loading screen, and it is
  ## what upstream does.
  result = 0
  let doc = raw(localeText())
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
# Announcing the location
# ---------------------------------------------------------------------------
#
# A location is not only a row in `locations`. Other mods *decorate* every
# location: SAIN sets each map's `BotLocationModifier` to 1 so its own
# difficulty maths is not fought by BSG's per-map skew, and it does that by
# reading `locations` and writing onto every map it finds. Which maps it finds
# is decided by the host's load order, and the host's load order is a directory
# walk -- so on the install `tools/allmods.nim` measures, SAIN loaded three
# positions before this mod, `locations.suburbs` did not exist yet, and a
# player raiding the Icebreaker got stock bot behaviour with nothing logged
# anywhere. Both mods were correct alone. Neither could see the other.
#
# The fix is on both sides and neither side depends on the order:
#
#   * this mod **announces** `aowlspt.locations.changed` after its writes have
#     reached the database, naming the slot. A decorator that loaded first is
#     already subscribed and decorates the slot now.
#   * this mod **answers** `aowlspt.locations.hello` with the same
#     announcement. A decorator that loads later asks, and gets told -- which
#     it needs even though it could read the slot out of the database itself,
#     because the answer is also how it learns that a location it can see is
#     one somebody is claiming to own.
#
# The event names are deliberately not `icebreaker.*` or `sain.*`. This is a
# contract between "a mod that adds a location" and "a mod that decorates
# every location", and the next map mod in this tree should be able to join it
# by emitting one event.

proc populationBaseline(): JsonObject =
  ## What this map's numbers are **before any other mod scales them**.
  ##
  ## `mods/morebots` raises every map's bot cap and wave slots, and it computes
  ## them from a shipped `data/vanilla.json` rather than from the live values,
  ## because the database persists and a live-value multiply compounds on every
  ## restart -- 30 becomes 45, then 68, then 101, and nothing logs. That file
  ## covers the nineteen slots a stock database ships, and for `suburbs` it
  ## holds the dormant stub: `botMax: 0` and two placeholder waves. So a player
  ## who installs both and asks for `horde` gets a busier raid on eighteen maps
  ## and stock numbers here, and morebots cannot fix that from its side -- the
  ## numbers it would have to scale from are the ones this mod just wrote.
  ##
  ## This mod does know them, exactly, because it writes them from its own
  ## shipped data on every boot. Saying so is a dozen lines and it is the only
  ## place the answer exists. The shape is an entry in morebots'
  ## `data/vanilla.json`; a mod that has never heard of morebots omits the
  ## member and morebots names the map as unscaled rather than guessing.
  ##
  ## Only the two `slots` fields are declared per wave. They are the only
  ## fields morebots writes, and it copies every other field of the live record
  ## through untouched, so declaring more would be describing work nobody does.
  result = obj()
  put(result, "name", cfgDisplayName)
  put(result, "botMax", cfgBotCap)
  put(result, "botMaxPvE", cfgBotCap)
  put(result, "maxBotPerZone", cfgMaxBotPerZone)
  var waves = arr()
  let wavesText = readData(cfgWavesFile)
  # A throwaway report: `waveList` counts what it builds, and counting the same
  # waves a second time into `gTables` would make the boot line claim twice the
  # waves this mod actually wrote.
  var scratch = TableReport(exits: 0, scavDisabled: 0, waves: 0, waveSlots: 0,
                            bosses: 0, localeKeys: 0, problems: 0)
  let live = whole(waveList(wavesText, cfgOpenZones, scratch))
  if isArray(live):
    for w in each(live):
      var e = obj()
      put(e, "slotsMin", child(w, "slots_min").asInt(0))
      put(e, "slotsMax", child(w, "slots_max").asInt(0))
      add(waves, done(e))
  put(result, "waves", waves)

proc announcement(): JsonObject =
  ## The payload, built separately from the emit so the self-test can check it
  ## on a host with no other mod to hear it. A subscriber reads `locations` and
  ## nothing else has to be understood, which is what makes this joinable.
  ##
  ## `population` is the optional second half of the contract: a decorator that
  ## scales bot counts needs to know what this map's numbers were before it
  ## touched them, and no subscriber can work that out by reading the database
  ## after the fact. See `populationBaseline` above.
  var ids = arr()
  add(ids, cfgSlotId)
  var pop = obj()
  put(pop, cfgSlotId, populationBaseline())
  result = obj()
  put(result, "guid", ModGuid)
  put(result, "reason", "registered")
  put(result, "locations", ids)
  put(result, "population", pop)

proc announceLocation(): Status =
  ## Say that `cfgSlotId` is here. Called after `dbFlush`, never before: an
  ## announcement a subscriber cannot read back is worse than none, because the
  ## subscriber's only sane response is to skip the map.
  result = broadcast("aowlspt.locations.changed", announcement())

proc onLocationsHello(payload: string): string =
  ## A decorator that loaded after this mod did, asking who owns a location.
  ##
  ## Answered unconditionally rather than only the first time, for the reason
  ## `morebots.onHello` gives: two decorators both want an answer, and the
  ## second one's announcement is the only one it will ever see. Not answered
  ## when the registration failed -- there is no location to decorate then, and
  ## naming one that is not in the database would send the asker looking for it.
  result = ""
  if not gRegistered:
    return ""
  discard announceLocation()

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
  dbFlush()
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

proc writeMapTables(): bool =
  ## The exits, the waves and the boss spawns — the three tables that turn a
  ## registered slot into a map you can actually play a raid on.
  ##
  ## The `suburbs` stub ships `exits: []` and two placeholder waves, so before
  ## this the rebound slot was a dot on the map screen that opened onto a raid
  ## with nobody in it and no way out. See `ice/tables.nim` for why these three
  ## are shippable and `SpawnPointParams` is not.
  ##
  ## Written as whole arrays, which is right: `dbWrite` replaces an array rather
  ## than merging into one, and these tables are this mod's to own on this slot.
  ## The slot is dormant in every stock database, so there is nobody else's work
  ## here to preserve.
  gTables = TableReport(exits: 0, scavDisabled: 0, waves: 0, waveSlots: 0,
                        bosses: 0, localeKeys: 0, problems: 0)
  if not cfgMapTables:
    info "icebreaker: mapTables is off, so the exits, waves and boss spawns " &
         "were not written. The slot keeps whatever it already had, which on " &
         "a stock database is no exits at all."
    return false
  result = false
  let base1 = basePath()

  let exitsText = readData(cfgExitsFile)
  let exits = exitList(exitsText, gTables)
  if exits.len > 2:
    if dbPut(base1 & ".exits", raw(exits)) == Ok:
      result = true
    let scav = scavDisabledString(exitsText, gTables)
    discard dbPut(base1 & ".DisabledScavExits", raw(quoted(scav)))

  let wavesText = readData(cfgWavesFile)
  let waves = waveList(wavesText, cfgOpenZones, gTables)
  if waves.len > 2:
    if dbPut(base1 & ".waves", raw(waves)) == Ok:
      result = true

  if cfgBossSpawns:
    let bosses = bossList(wavesText, cfgOpenZones, gTables)
    if bosses.len > 2:
      discard dbPut(base1 & ".BossLocationSpawn", raw(bosses))
  else:
    info "icebreaker: bossSpawns is off (the default). A boss on a map whose " &
         "loot tables are empty is a fight for nothing; turn it on once you " &
         "have dropped the authored loot in."

  checkLocaleCoversExits(readData("locales.json"), exitsText, gTables)
  # Counts the locale strings into the same report, so one line covers every
  # table this mod owns rather than three quarters of them.
  discard localeText()

  if gTables.problems > 0:
    warn "icebreaker: " & $gTables.problems & " problem(s) in the map " &
         "tables; run `aowl run mods/icebreaker` for the detail"
  else:
    success "icebreaker: map tables written -- " & describe(gTables)

var gSlotWasThere = false
var gSlotSpawnPoints = -1
  ## What the database held for the slot *before* this mod wrote anything: was
  ## there a slot at all, and how many spawn points did it come with. -1 means
  ## "not asked yet", which is not the same as "none".

proc probeSlot() =
  ## The one assumption in this mod that is about a table it did not write.
  ##
  ## Everything in this file's header rests on `suburbs` being a dormant slot
  ## BSG already ships: that is what makes `GetLocation("suburbs")`, the raid
  ## configuration, insurance and the scav timings resolve with no patching.
  ## `dbPut` *creates* a path that is not there, so on a database with no such
  ## slot this mod used to report "suburbs rebound to Icebreaker" while
  ## actually inventing a location out of the 31 fields below -- no spawn
  ## points, and no entry in any of the sibling tables keyed by location. That
  ## is a different and much weaker claim, and it should be said rather than
  ## discovered in a raid.
  let stub = dbRead(basePath())
  gSlotWasThere = stub.ok and stub.raw.len > 0
  gSlotSpawnPoints = 0
  if gSlotWasThere:
    let existing = field(stub.raw, "SpawnPointParams")
    if exists(existing) and isArray(existing):
      gSlotSpawnPoints = count(existing)
    info "icebreaker: locations." & cfgSlotId & " is in this database with " &
         $keys(whole(stub.raw)).len & " base field(s) and " &
         $gSlotSpawnPoints & " spawn point(s); rebinding it"
  else:
    warn "icebreaker: locations." & cfgSlotId & " is NOT in this database, " &
         "so this is not a rebind of a dormant slot -- it is a new location " &
         "made of the fields this mod writes and nothing else. Every table " &
         "keyed by location (spawn points, insurance, scav timings) has no " &
         "entry for it, and the client has to resolve an id BSG never " &
         "shipped. That is the failure mode this mod exists to avoid; check " &
         "that the database is a real dump and that slotId names a slot it has."

proc writeSpawnPoints(): bool =
  ## The one table that cannot be shipped, and the refusal said out loud.
  ##
  ## `spawnPointsFile` lets an install that *has* the scene supply the array.
  ## Nothing is invented when it is absent: an invented spawn point puts the
  ## player inside the hull.
  result = false
  if gSlotSpawnPoints > 0 and cfgSpawnPointsFile.len == 0:
    # The refusal below is a claim about this database, not a constant, and on
    # a database whose stub already carries spawn points it would be false.
    # Measured every boot rather than asserted once: `SpawnPointParams` is
    # empty on every stub in the dumps this was checked against (suburbs,
    # terminal, town, privatearea all ship zero), and a dump where it is not is
    # a dump where this mod has nothing to refuse.
    success "icebreaker: the " & cfgSlotId & " slot already carries " &
            $gSlotSpawnPoints & " spawn point(s), so nothing is missing here " &
            "and nothing was written over them"
    return false
  if cfgSpawnPointsFile.len > 0:
    let text = readData(cfgSpawnPointsFile)
    if text.len > 2 and isArray(whole(text)):
      let n = count(whole(text))
      if dbPut(basePath() & ".SpawnPointParams", raw(text)) == Ok:
        success "icebreaker: " & $n & " spawn point(s) loaded from data/" &
                cfgSpawnPointsFile
        return true
    warn "icebreaker: spawnPointsFile names data/" & cfgSpawnPointsFile &
         ", which is missing or is not a JSON array. Nothing was written -- " &
         "an invented spawn point is worse than none."
  warn "icebreaker: " & spawnPointsNote()

proc refuseWeather() =
  ## An arctic map on a stack whose sky is a constant. Refused with the reason
  ## rather than shipped as a switch that does nothing.
  if not cfgArcticWeather:
    return
  error "icebreaker: arcticWeather is on and this mod cannot honour it. " &
        weatherNote()

proc registerLocation(): Status =
  ## Always returns `Ok`, and that is deliberate.
  ##
  ## A server started with no database at all is the normal first run -- the
  ## emulator is built to reach the menu on one -- and there the location write
  ## has nowhere to land. Failing the load there would take the mod's own
  ## routes down with it, so a status endpoint could not even be asked what
  ## went wrong. It degrades instead: the failure is logged once, `gRegistered`
  ## records it, and `/icebreaker/status` answers `false` for anyone who asks.
  probeSlot()
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

  discard writeMapTables()
  discard writeSpawnPoints()
  refuseWeather()

  # The alive-bot cap, written where something actually reads it.
  #
  # This used to write `configs.bot.maxBotCap.<slot>` and log a shrug when that
  # failed, which it always did: a stock SPT 4.x database has no top-level
  # `configs` object at all, so the write had nowhere to land and the cap was
  # never set on any install, ever. The stub ships `BotMax: 0` and
  # `MaxBotPerZone: 0`, and a map with a cap of zero is a map with no bots on
  # it -- so the whole wave table above would have been written into a location
  # that could not spawn a single one of them.
  #
  # `locations.<slot>.base.BotMax` is the field the client reads, and
  # /client/locations serves it verbatim. The old path is still written after
  # it, because an install that does have a `configs` object is not this mod's
  # to break.
  var caps = obj()
  put(caps, "BotMax", cfgBotCap)
  put(caps, "BotMaxPvE", cfgBotCap)
  if dbPut(basePath(), done(caps)) == Ok:
    info "icebreaker: alive-bot cap for " & cfgSlotId & " set to " & $cfgBotCap &
         " in locations." & cfgSlotId & ".base (BotMax/BotMaxPvE), which is " &
         "where the client reads it"
  discard dbPut("configs.bot.maxBotCap." & cfgSlotId, $cfgBotCap)

  # Scav raid timings are keyed by map id; without an entry the lookup misses.
  #
  # The donor is not hard-coded to `factory4_day` any more, and the miss is not
  # silent any more. `configs` is a table this mod did not write: SPT's dump
  # has it, the emulator's database does not, and the 39 MiB import this was
  # checked against has no top-level `configs` object at all -- so the clone
  # never once happened on that install and said nothing about it. Preferring
  # factory4_day when it is there keeps the old behaviour exactly; falling back
  # to whatever map the table does carry is what makes it work on a dump that
  # is keyed differently; and saying so when the table is absent is what turns
  # "the timings are wrong and nobody knows why" into one line at boot.
  const TimingRoot = "configs.location.scavRaidTimeSettings.maps"
  var donor = ""
  var donorRaw = ""
  let preferred = dbRead(TimingRoot & ".factory4_day")
  if preferred.ok and preferred.raw.len > 0:
    donor = "factory4_day"
    donorRaw = preferred.raw
  else:
    let all = dbRead(TimingRoot)
    if all.ok and all.raw.len > 0:
      let doc = whole(all.raw)
      if doc.isObject:
        for id in doc.keys():
          if id == cfgSlotId:
            continue
          let entry = child(doc, id)
          if isObject(entry):
            donor = id
            donorRaw = raw(entry)
            break
  if donor.len > 0:
    discard dbPut(TimingRoot & "." & cfgSlotId, donorRaw)
    info "icebreaker: scav raid timings cloned from " & donor
  else:
    info "icebreaker: this database has no " & TimingRoot & " table, so " &
         "there were no scav raid timings to clone for " & cfgSlotId &
         ". A player scav raid on the slot falls back to whatever the server " &
         "does for a map it has no timings for; on the emulator that is the " &
         "normal case and not a problem."

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
  dbFlush()
  # After the flush, so that a decorator woken by this can read the slot back.
  # See "Announcing the location" above for why this exists at all.
  if gRegistered:
    discard announceLocation()
  result = Ok

# ---------------------------------------------------------------------------
# The self-test
# ---------------------------------------------------------------------------
#
#     aowl run mods/icebreaker                # --side sim
#
# Before this existed, `aowl run mods/icebreaker` printed one line -- "icebreaker
# is a server mod" -- and stopped. That was true and it was also the whole
# output, so nothing about this mod was checkable without a backend and a
# database. Every document below is built out of config and arithmetic, which
# means all of it *is* checkable with neither.
#
# **There is no client half and there are no IL2CPP bindings.** This mod's whole
# content is database writes and four routes: it rebinds the dormant `suburbs`
# location slot, points it at a scene, rebrands its locale strings and watches
# raid events. None of that runs in the game's process, so there is no per-frame
# path, nothing to bind, and nothing to move onto `aowlspt/fast`. What is
# measured instead is the cost of the work this mod *does* do per request and
# per raid end, on the same `perfCounter` clock a client mod measures a frame
# with -- because "there is no hot path here" is a claim, and a claim with a
# number beside it is a better one.

proc checkDoc(name: string; text: string; wantMembers: int): int =
  ## One built document, parsed back with `aowlspt/json` and counted.
  ##
  ## Round-tripping is the point: these documents are assembled by string
  ## concatenation in `aowlspt/server`'s builder, so an unescaped quote in a
  ## config value produces text that is not JSON at all and would be written
  ## into the database as garbage. `keys` refuses to parse it here instead.
  result = 0
  let ks = keys(whole(text))
  if ks.len != wantMembers:
    error "  " & name & ": parsed back with " & $ks.len &
          " members, expected " & $wantMembers &
          " -- a config value probably contains something that broke the JSON"
    return 1
  success "  " & name & ": " & $ks.len & " members, " & $text.len & " bytes"

proc simSelfTest(): Status =
  info "Icebreaker self-test (--side sim)"
  var bad = 0

  # --- the documents, all of which are pure config plus arithmetic.
  bad = bad + checkDoc("locations." & cfgSlotId & ".base",
                       done(locationBase()).text, 31)
  bad = bad + checkDoc("/icebreaker/status", onStatus("", "", "sim"), 13)
  bad = bad + checkDoc("/icebreaker/bundles", onBundles("", "", "sim"), 1)
  bad = bad + checkDoc("/icebreaker/state", onState("", "", "sim-session"), 5)
  bad = bad + checkDoc("/icebreaker/crossings", onCrossings("", "", "sim"), 1)
  bad = bad + checkDoc("aowlspt.locations.changed", done(announcement()).text, 4)

  # --- the population baseline the announcement carries.
  #
  # Checked against the tables this mod actually writes rather than against
  # itself: a baseline that disagrees with the waves on the map is worse than
  # no baseline at all, because morebots would scale from it and write numbers
  # that are wrong by a fixed factor with nothing to compare them to.
  block popCheck:
    let pop = child(whole(done(announcement()).text), "population")
    let mine = child(pop, cfgSlotId)
    if not mine.found:
      error "  the location announcement carries no population baseline for " &
            cfgSlotId & ", so morebots cannot apply its preset to this map " &
            "and every other map in the install would be scaled while this " &
            "one stayed at stock"
      inc bad
      break popCheck
    let cap = child(mine, "botMax").asInt(0)
    let zone = child(mine, "maxBotPerZone").asInt(0)
    let ws = child(mine, "waves")
    var slots = 0
    for w in each(ws):
      slots = slots + child(w, "slotsMax").asInt(0)
    if cap != cfgBotCap or zone != cfgMaxBotPerZone:
      error "  the announced baseline says botMax " & $cap & " / perZone " &
            $zone & " and this mod writes " & $cfgBotCap & " / " &
            $cfgMaxBotPerZone
      inc bad
      break popCheck
    # Against the wave list this mod builds from its own data file, and -- on a
    # host that has actually written the tables -- against what it wrote. In
    # the simulator there is no database, so `gTables` is still zero and only
    # the first comparison is available; checking a zero against a real count
    # would fail every offline run for the wrong reason.
    var scratch2 = TableReport(exits: 0, scavDisabled: 0, waves: 0,
                               waveSlots: 0, bosses: 0, localeKeys: 0,
                               problems: 0)
    discard waveList(readData(cfgWavesFile), cfgOpenZones, scratch2)
    var wroteWaves = scratch2.waves
    var wroteSlots = scratch2.waveSlots
    if gTables.waves > 0:
      wroteWaves = gTables.waves
      wroteSlots = gTables.waveSlots
    if count(ws) != wroteWaves or slots != wroteSlots:
      error "  the announced baseline has " & $count(ws) & " wave(s) and " &
            $slots & " slot(s); this mod writes " & $wroteWaves & " and " &
            $wroteSlots & ". A decorator scaling from a baseline that does " &
            "not match the map writes numbers that are wrong by a constant " &
            "factor and looks like it worked"
      inc bad
      break popCheck
    success "  the announcement declares this map's stock population -- cap " &
            $cap & ", per-zone " & $zone & ", " & $count(ws) & " wave(s) " &
            "totalling " & $slots & " slot(s) -- which is the only place " &
            "that answer exists: morebots scales from a shipped baseline and " &
            "its baseline for this slot is the dormant stub, and reading the " &
            "live values instead would compound on every restart"

  # The announcement is only worth anything if a subscriber can get the slot id
  # back out of it, so that is what is checked rather than that it parses.
  let announced = child(whole(done(announcement()).text), "locations")
  if not exists(announced) or not isArray(announced) or
     count(announced) != 1 or at(announced, 0).asText("") != cfgSlotId:
    error "  the location announcement does not name " & cfgSlotId &
          " in a `locations` array; a decorator subscribed to " &
          "aowlspt.locations.changed would learn nothing from it"
    inc bad
  else:
    success "  aowlspt.locations.changed names " & cfgSlotId &
            ", so a mod that decorates every location -- SAIN's per-map " &
            "BotLocationModifier is the one this was built for -- reaches " &
            "this map whether it loaded before this mod or after it"

  # --- the map tables, which are the difference between a dot on the map
  # screen and a raid. This is the part `checkDoc` cannot express: the counts
  # matter, and so does whether the exits and the locale strings agree with
  # each other. A table that half-loaded is the failure mode -- a map with two
  # of its three exits still lets you extract, so nothing looks wrong.
  gTables = TableReport(exits: 0, scavDisabled: 0, waves: 0, waveSlots: 0,
                        bosses: 0, localeKeys: 0, problems: 0)
  let exitsText = readData(cfgExitsFile)
  let wavesText = readData(cfgWavesFile)
  let localesText = readData("locales.json")

  let exitsDoc = exitList(exitsText, gTables)
  let scavStr = scavDisabledString(exitsText, gTables)
  let wavesDoc = waveList(wavesText, cfgOpenZones, gTables)
  let bossDoc = bossList(wavesText, cfgOpenZones, gTables)
  let localeDoc = localeDocument(localesText, cfgSlotObjectId, cfgDisplayName,
                                 cfgDescription, gTables)
  checkLocaleCoversExits(localesText, exitsText, gTables)

  if gTables.exits == 0:
    error "  no exits loaded. The suburbs stub ships an empty exit list, so " &
          "this is a raid you cannot leave except by dying -- which is the " &
          "single largest gap this mod had and the one it can close"
    inc bad
  if gTables.waves == 0:
    error "  no waves loaded; the map has the stub's two placeholders and " &
          "nothing else on it"
    inc bad
  if gTables.problems > 0:
    error "  " & $gTables.problems & " problem(s) in the shipped map tables"
    bad = bad + gTables.problems
  else:
    success "  map tables: " & describe(gTables)
    info "    every exit has a name, a chance in 0..100, a non-zero " &
         "exfiltration timer and all " & $ExitFields.len & " fields the " &
         "client indexes; every wave names a role a wave may legally carry " &
         "and spawns into `" & cfgOpenZones & "`, the zone this location " &
         "declares; every boss record carries all " & $BossSpawnFields.len &
         " fields including the four whose almost-right spellings " &
         "(BossDifficulty, IsBossPlayer, IsRandomTimeSpawn, " &
         "BossEscortDifficulty) deserialise to nothing without a word"

  # Every built table parsed back, because they are assembled by string
  # concatenation and a stray quote in a config value is text that is not JSON.
  if count(whole(exitsDoc)) != gTables.exits:
    error "  the exit array did not round-trip: built " & $gTables.exits &
          " and parsed back " & $count(whole(exitsDoc))
    inc bad
  if count(whole(wavesDoc)) != gTables.waves:
    error "  the wave array did not round-trip"
    inc bad
  if keys(whole(localeDoc)).len != gTables.localeKeys:
    error "  the locale document did not round-trip"
    inc bad
  else:
    success "  " & $gTables.localeKeys & " locale string(s) built from " &
            "data/locales.json and parsed back, covering the slot name and " &
            "description, the bare `Suburbs` key, every exit name, the " &
            "banner captions and the bot zone"
  if scavStr.len == 0:
    warn "  no exits are closed to player scavs"
  else:
    info "  DisabledScavExits -> \"" & scavStr & "\" (a comma-separated " &
         "string, not an array; that is the game's shape and it is why the " &
         "config key for it looks out of place)"
  if bossDoc.len > 2 and not cfgBossSpawns:
    info "  " & $gTables.bosses & " boss spawn(s) are shipped and are OFF " &
         "(bossSpawns is false): a boss on a map whose loot tables are empty " &
         "is a fight for nothing"

  # --- and the two tables that are not shipped, said here rather than only in
  # README.md, because the output is what somebody reads first.
  warn "  " & spawnPointsNote()
  warn "  " & lootNote()
  warn "  " & weatherNote()

  # The scene is the single field that turns "the server says the map is here"
  # into "the client loads it", so it is checked by name rather than counted.
  let scene = done(sceneObject()).text
  if field(scene, "path").asText("").len == 0 or
     field(scene, "rcid").asText("").len == 0:
    error "  Base.Scene has an empty path or rcid; the client would have " &
          "nothing to load and the map would be a dot that opens onto nothing"
    inc bad
  else:
    success "  Base.Scene -> " & field(scene, "path").asText("") & " / " &
            field(scene, "rcid").asText("")

  # The locale rebrand is keyed on the slot's *object* id, not its string id,
  # because that is what `LocationInfoPanel` localises. An empty one would
  # write `" Name"` into every language.
  if cfgSlotObjectId.len == 0:
    error "  slotObjectId is empty; the locale keys would be \" Name\" and " &
          "\" Description\", which is a rebrand of nothing"
    inc bad
  else:
    success "  locale keys \"" & cfgSlotObjectId & " Name\" and \"" &
            cfgSlotObjectId & " Description\", plus the bare \"Suburbs\""

  # --- the database. On the simulator there is none, and that is the answer.
  let probe = dbRead("locations." & cfgSlotId)
  if probe.ok:
    info "  a database is attached; registering into it"
    discard registerLocation()
  else:
    warn "  no database on this host (" & lastError() & "), so nothing was " &
         "written. That is what the server half needs and what the simulator " &
         "does not have -- registerLocation degrades to a logged failure and " &
         "/icebreaker/status answers registered:false, which is the same " &
         "behaviour as a backend started without --db."

  # --- the crossing watch, which is the one piece of state this mod keeps.
  if storeReady():
    gCurrentLocation = cfgSlotId
    var payload = obj()
    put(payload, "profile", "selftest-profile")
    discard onRaidEnded(done(payload).text)
    if hasCrossed("selftest-profile"):
      success "  a raid end on " & cfgSlotId &
              " recorded a crossing and it read back"
    else:
      error "  a raid end on " & cfgSlotId & " did not record a crossing"
      inc bad
    # A raid end on a different map must not count, or every quest gated on
    # coming back from the icebreaker unlocks on the first Customs run.
    gCurrentLocation = "bigmap"
    var other = obj()
    put(other, "profile", "selftest-elsewhere")
    discard onRaidEnded(done(other).text)
    if hasCrossed("selftest-elsewhere"):
      error "  a raid end on bigmap was recorded as a crossing of " & cfgSlotId
      inc bad
    else:
      success "  a raid end on another map was correctly ignored"
    gCurrentLocation = ""
  else:
    warn "  no persistent store on this host, so the crossing watch could " &
         "not be exercised; on a host without one the gates reopen every boot"

  # --- what this mod does not ship, said in the output rather than only in the
  # module comment, because the output is what somebody reads first.
  info "  not shipped, and why:"
  info "    the scene bundle, the prop bundles, the navmesh and acoustics " &
       "bakes -- assets, not code; " & $cfgBundles.len &
       " bundle key(s) are named at /icebreaker/bundles so a client can say " &
       "which one is missing"
  info "    the authored loot tables -- 8MB of extracted coordinates; empty " &
       "but valid tables are seeded so a raid starts, and dropping the real " &
       "files over the same paths needs no code change because dbWrite merges"
  info "    the banner images -- this ABI has no static-file route, so the " &
       "banner entries are written and the pictures are the install's problem"
  info "    per-profile map locking and quest visibility -- /client/locations " &
       "and /client/quest/list belong to mods/tarkov and the backend refuses " &
       "a second registration of an exact route; the per-session answers are " &
       "served at /icebreaker/state instead"

  # --- cost. There is no frame here; there is a request.
  const Iterations = 2000
  let t0 = perfCounter()
  var i = 0
  var total = 0
  while i < Iterations:
    total = total + done(locationBase()).text.len
    inc i
  let per = nanosBetween(t0, perfCounter()) div int64(Iterations)
  info "  cost: building the location base document is " & $per &
       " ns (" & $(total div Iterations) & " bytes). There is no per-frame " &
       "path in this mod at all -- it is a server mod, it never enters the " &
       "game's process, and it has nothing to bind. The comparable number " &
       "for a client mod is docs/PERF.md's 6-10 ns per bound call."

  if bad == 0:
    success "Icebreaker self-test: every document built and parsed back"
    result = Ok
  else:
    error "Icebreaker self-test: " & $bad & " problem(s)"
    result = ErrGeneric

proc onLoad(): Status =
  loadConfig()
  success ModName & " " & ModVersion & " loaded on " & hostName()
  if side() == sideSim:
    return simSelfTest()
  if side() != sideServer:
    info "icebreaker is a server mod; the scene and its assets are the " &
         "client's half and are not code"
    return Ok

  # Subscribed before the location is registered, so that a decorator which
  # loaded earlier and is still on the stack cannot ask a question this mod is
  # not yet listening for.
  discard onEvent("aowlspt.locations.hello", onLocationsHello)

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
