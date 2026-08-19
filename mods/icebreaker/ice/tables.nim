## The map tables: exits, waves, boss spawns, locale strings — and the one
## table that cannot be shipped and why.
##
## ---------------------------------------------------------------------------
## THE GAP THIS FILE CLOSES
## ---------------------------------------------------------------------------
##
## Before it, this mod rebound the `suburbs` slot, pointed it at a scene,
## renamed it and stopped. That is enough to put a dot on the map screen and
## nowhere near enough to play a raid on, because the stub BSG ships is not a
## half-finished map — it is an empty record:
##
##     locations.suburbs.base.exits             []      <- no way out
##     locations.suburbs.base.SpawnPointParams  []      <- nowhere to start
##     locations.suburbs.base.BossLocationSpawn []      <- nobody there
##     locations.suburbs.base.waves             2 stubs <- nobody there either
##     locations.suburbs.base.BotMax            0
##     locations.suburbs.base.MaxBotPerZone     0
##     locations.suburbs.base.EscapeTimeLimit   0
##
## Three of those five are shippable here and two are not, and the line between
## them is exactly one property: **whether the record contains world
## coordinates.**
##
##  * An **exit** does not. It carries a name, a chance, an exfil timer and a
##    time window; the geometry is a trigger in the scene and the record is
##    matched to it by `Name`. So a complete exit table is authorable, and it is
##    `data/exits.json`.
##  * A **wave** does not. It names a bot *zone* by string, a role, a count and
##    a time window. `ZoneIcebreaker` is the zone upstream's own `openZones`
##    declares, so a wave naming it is right by construction. `data/waves.json`.
##  * A **boss spawn** does not, for the same reason. Same file.
##  * A **`SpawnPointParams`** entry is nothing *but* coordinates: `Position`,
##    `Rotation`, a collider radius, an `Infiltration` name and a category. A
##    stock map has between 14 and 458 of them. There is no way to author one
##    without the scene open, and a spawn point invented from nothing puts the
##    player inside the hull or under the ice. So this file **refuses**, out
##    loud, with the reason and with what it would take — see `spawnPointsNote`.
##  * The **loot tables** are the same refusal at 8MB.
##
## ---------------------------------------------------------------------------
## WHY THE NAMES IN THE DATA ARE THE NAMES THEY ARE
## ---------------------------------------------------------------------------
##
## Every string in `data/exits.json` and `data/waves.json` that has to match
## something in a scene this port has never seen is a string **upstream's own
## config already names** — `ZoneIcebreaker` from `openZones`, and the
## Helicopter / Cellars / Gate 0 exits from `exitLocaleKey` and
## `disabledScavExits`. That is a real constraint honoured rather than a guess
## dressed up: this port did not choose those names, it read them off the mod it
## is porting. If a scene bundle turns out to disagree, the fix is a data file
## and not a rebuild, which is why `exitsFile` and `wavesFile` are config keys.

import std/strutils
import std/syncio
import aowlspt
import aowlspt/server
import aowlspt/json

type
  TableReport* = object
    exits*: int
    scavDisabled*: int
    waves*: int
    waveSlots*: int
    bosses*: int
    localeKeys*: int
    problems*: int

const
  WaveRoles* = [
    "assault", "assaultGroup", "cursedAssault", "marksman", "pmcBot",
    "exUsec", "sectantWarrior", "sectantPriest", "arenaFighter",
    "arenaFighterEvent", "pmcUSEC", "pmcBEAR", "crazyAssaultEvent"]
    ## The roles a *wave* may legally name. Not the whole `WildSpawnType` table:
    ## a wave is scav-side population, and naming `bossKilla` in one produces a
    ## wave the client silently drops rather than a Killa. Bosses go in
    ## `bossLocationSpawn`, which is a different record with a different shape,
    ## and conflating the two is the most common way a hand-written map table
    ## ends up with an empty map and no error.

  BossSpawnFields* = [
    "BossName", "BossChance", "BossDifficult", "BossEscortAmount",
    "BossEscortDifficult", "BossEscortType", "BossZone", "BossPlayer",
    "Delay", "DependKarma", "DependKarmaPVE", "ForceSpawn", "IgnoreMaxBots",
    "RandomTimeSpawn", "ShowOnTarkovMap", "ShowOnTarkovMapPvE", "SpawnMode",
    "Supports", "Time", "TriggerId", "TriggerName"]
    ## Checked by name, because four of them are spelled *almost* right in every
    ## hand-written map mod there is. `BossDifficult` is not `BossDifficulty`;
    ## `BossPlayer` is not `IsBossPlayer`; `RandomTimeSpawn` is not
    ## `IsRandomTimeSpawn`. A record with the plausible spelling deserialises
    ## with those members at their type defaults and nothing logs a word.

  ExitFields* = [
    "Name", "EntryPoints", "Chance", "ChancePVE", "Count", "CountPVE",
    "EventAvailable", "ExfiltrationTime", "ExfiltrationTimePVE",
    "MinTime", "MinTimePVE", "MaxTime", "MaxTimePVE",
    "PlayersCount", "PlayersCountPVE"]

proc readTextFile*(path: string): string =
  result = ""
  try:
    result = readFile(path)
  except:
    result = ""

proc readData*(relative: string): string =
  result = readTextFile(dataDir() & "/" & relative)

proc stripComments(o: JsonRef): JsonArray =
  ## The shipped data files carry `_note` members on individual records, because
  ## a table of 11 waves with no explanation of why wave 8 is raiders is a table
  ## nobody dares edit. They must not reach the database: a member the client's
  ## deserialiser does not know is at best ignored and at worst a refusal, and
  ## "at worst" on a map record is a raid that does not start.
  result = arr()
  let items = each(o)
  for it in items:
    var d = parseObject(it)
    remove(d, "_note")
    remove(d, "_comment")
    result.add raw(text(d))

# ---------------------------------------------------------------------------
# Exits
# ---------------------------------------------------------------------------

proc exitList*(text: string; r: var TableReport): string =
  ## The `exits` array, checked and stripped. Empty string means unusable, and
  ## the caller leaves the database alone rather than writing half a table.
  if text.len < 3:
    error "icebreaker: data/exits.json is missing or empty. The suburbs stub " &
          "ships zero exits, so without it a raid on this map is a raid you " &
          "cannot leave except by dying."
    inc r.problems
    return ""
  let doc = whole(text)
  let list = child(doc, "exits")
  if not isArray(list) or count(list) == 0:
    error "icebreaker: data/exits.json has no `exits` array"
    inc r.problems
    return ""
  var names: seq[string] = @[]
  let items = each(list)
  for e in items:
    let n = child(e, "Name").asText("")
    if n.len == 0:
      error "icebreaker: an exit with no Name; it can never match a trigger"
      inc r.problems
      continue
    var dup = false
    for x in names:
      if x == n:
        dup = true
    if dup:
      error "icebreaker: two exits are both called `" & n & "`; the extraction " &
            "panel matches on that name and cannot tell them apart"
      inc r.problems
      continue
    names.add n
    for f in ExitFields:
      if not child(e, f).found:
        error "icebreaker: exit `" & n & "` has no `" & f & "`. Every field is " &
              "written even at its default because the client indexes several " &
              "of them without checking first"
        inc r.problems
    let chance = child(e, "Chance").asInt(-1)
    if chance < 0 or chance > 100:
      error "icebreaker: exit `" & n & "` has Chance " & $chance
      inc r.problems
    let t = child(e, "ExfiltrationTime").asInt(-1)
    if t <= 0:
      error "icebreaker: exit `" & n & "` has an exfiltration time of " & $t &
            "; a zero timer is an exit that never completes"
      inc r.problems
  r.exits = names.len
  result = done(stripComments(list)).text

proc exitNames*(text: string): seq[string] =
  result = @[]
  if text.len < 3:
    return
  let items = each(child(whole(text), "exits"))
  for e in items:
    let n = child(e, "Name").asText("")
    if n.len > 0:
      result.add n

proc scavDisabledString*(text: string; r: var TableReport): string =
  ## `Base.DisabledScavExits` is a **comma-separated string of exit names**,
  ## not an array, which is why the config key for it looks out of place beside
  ## every other setting. Built from the data rather than restated in config, so
  ## renaming an exit cannot leave the two disagreeing.
  result = ""
  if text.len < 3:
    return
  let known = exitNames(text)
  let items = each(child(whole(text), "scavDisabled"))
  for it in items:
    let n = it.asText("")
    if n.len == 0:
      continue
    var found = false
    for k in known:
      if k == n:
        found = true
    if not found:
      error "icebreaker: scavDisabled names `" & n & "`, which is not one of " &
            "this map's exits. A scav restriction on an exit that does not " &
            "exist restricts nothing"
      inc r.problems
      continue
    if result.len > 0:
      result.add ","
    result.add n
    inc r.scavDisabled

# ---------------------------------------------------------------------------
# Waves and bosses
# ---------------------------------------------------------------------------

proc isWaveRole(s: string): bool =
  for k in WaveRoles:
    if k == s:
      return true
  result = false

proc waveList*(text, zone: string; r: var TableReport): string =
  ## The `waves` array, checked against the zone the location actually declares.
  ##
  ## The zone check is the one that matters and is the one nobody does. A wave
  ## whose `SpawnPoints` names a zone the scene has no `BotZone` for is not an
  ## error anywhere: it is a wave that quietly never spawns, on a map that
  ## therefore quietly has fewer bots than its author thinks. Here the zone is
  ## `OpenZones` from this mod's own config, so the two are checkable against
  ## each other even with no scene present.
  if text.len < 3:
    error "icebreaker: data/waves.json is missing or empty; the map has the " &
          "two placeholder waves the suburbs stub ships and nothing else"
    inc r.problems
    return ""
  let list = child(whole(text), "waves")
  if not isArray(list) or count(list) == 0:
    error "icebreaker: data/waves.json has no `waves` array"
    inc r.problems
    return ""
  let items = each(list)
  var i = 0
  for w in items:
    let role = child(w, "WildSpawnType").asText("")
    if not isWaveRole(role):
      error "icebreaker: wave " & $i & " names `" & role & "`, which is not a " &
            "role a wave may carry. Bosses belong in bossLocationSpawn; a " &
            "boss named in a wave is a wave the client drops without a word"
      inc r.problems
    let sp = child(w, "SpawnPoints").asText("")
    if sp != zone:
      error "icebreaker: wave " & $i & " spawns into `" & sp & "` but this " &
            "location declares the zone `" & zone & "`. A wave pointed at a " &
            "zone the scene has no BotZone for never spawns, and nothing " &
            "anywhere reports it"
      inc r.problems
    let lo = child(w, "slots_min").asInt(-1)
    let hi = child(w, "slots_max").asInt(-1)
    if lo < 0 or hi < 0 or hi < lo:
      error "icebreaker: wave " & $i & " has slots " & $lo & ".." & $hi
      inc r.problems
    else:
      r.waveSlots = r.waveSlots + hi
    let t0 = child(w, "time_min").asInt(-1)
    let t1 = child(w, "time_max").asInt(-1)
    if t0 < 0 or t1 < t0:
      error "icebreaker: wave " & $i & " has a time window of " & $t0 & ".." &
            $t1 & " seconds"
      inc r.problems
    if not child(w, "SpawnMode").found:
      error "icebreaker: wave " & $i & " has no SpawnMode; a record missing " &
            "it is a null dereference at map load rather than a wave that " &
            "fails to spawn"
      inc r.problems
    inc r.waves
    inc i
  result = done(stripComments(list)).text

proc bossList*(text, zone: string; r: var TableReport): string =
  if text.len < 3:
    return ""
  let list = child(whole(text), "bossLocationSpawn")
  if not isArray(list):
    return ""
  let items = each(list)
  var i = 0
  for b in items:
    for f in BossSpawnFields:
      if not child(b, f).found:
        error "icebreaker: boss spawn " & $i & " has no `" & f & "`. Four of " &
              "these are spelled almost-right in every hand-written map " &
              "table there is; a record with the plausible spelling " &
              "deserialises with that member at its type default and nothing " &
              "logs a word"
        inc r.problems
    let bz = child(b, "BossZone").asText("")
    if bz.len > 0 and bz != zone:
      error "icebreaker: boss spawn " & $i & " is in zone `" & bz &
            "` but this location declares `" & zone & "`"
      inc r.problems
    inc r.bosses
    inc i
  result = done(stripComments(list)).text

# ---------------------------------------------------------------------------
# Locales
# ---------------------------------------------------------------------------

proc substitute(s, slot, name, description: string): string =
  result = s
  result = result.replace("{slot}", slot)
  result = result.replace("{name}", name)
  result = result.replace("{description}", description)

proc localeDocument*(text, slotObjectId, name, description: string;
                     r: var TableReport): string =
  ## Every string this mod puts in front of a player, in one object.
  ##
  ## Built from `data/locales.json` rather than from string literals in code,
  ## because the exit names in it have to stay in step with `data/exits.json`
  ## and two files can be checked against each other where a file and a
  ## hard-coded list cannot.
  var o = obj()
  if text.len < 3:
    # Not fatal. The rebrand is what stops the map dot saying SUBURBS; without
    # it the map still works and reads wrong, which is worth degrading to.
    warn "icebreaker: data/locales.json is missing; the map dot will still " &
         "read Suburbs and the extraction panel will print raw exit ids"
    inc r.problems
    return "{}"
  let doc = whole(text)
  let groups = ["slotKeyed", "bare", "exits", "banners", "zones"]
  for g in groups:
    let section = child(doc, g)
    if not section.found:
      continue
    let ks = keys(section)
    for k in ks:
      let key = substitute(k, slotObjectId, name, description)
      let v = substitute(child(section, k).asText(""),
                         slotObjectId, name, description)
      if key.len == 0 or v.len == 0:
        continue
      put(o, key, v)
      inc r.localeKeys
  result = done(o).text

proc checkLocaleCoversExits*(localeText, exitsText: string;
                             r: var TableReport) =
  ## Both directions, because both are wrong in different ways. An exit with no
  ## locale prints its raw id at the player; a locale entry for an exit that no
  ## longer exists is dead weight that hides the next rename.
  if localeText.len < 3 or exitsText.len < 3:
    return
  let ex = child(whole(localeText), "exits")
  let names = exitNames(exitsText)
  for n in names:
    if not child(ex, n).found:
      error "icebreaker: exit `" & n & "` has no locale string, so the " &
            "extraction panel prints the raw id"
      inc r.problems
  let have = keys(ex)
  for k in have:
    var used = false
    for n in names:
      if n == k:
        used = true
    # Keys of the `Icebreaker_Exit_*` form are the alternate spelling upstream's
    # config uses and are deliberately present for both, so they are not
    # reported as dead.
    if not used and not k.startsWith("Icebreaker_Exit_"):
      warn "icebreaker: locale string for `" & k & "`, which is not one of " &
           "this map's exits"

# ---------------------------------------------------------------------------
# The refusals
# ---------------------------------------------------------------------------

proc spawnPointsNote*(): string =
  ## What is missing, why it is missing, and what closing it would take. Said
  ## with the same words in the log and in README.md on purpose: a refusal that
  ## is only in a document nobody opened is a refusal nobody received.
  result =
    "SpawnPointParams is empty and this mod cannot fill it. A spawn point is " &
    "nothing but coordinates -- Position, Rotation, a collider radius, an " &
    "Infiltration name and a Sides list -- and a stock map has between 14 " &
    "(Labyrinth) and 458 (Streets) of them. There is no way to author one " &
    "without the scene open, and an invented one puts the player inside the " &
    "hull or under the ice, which is worse than a map that refuses to start. " &
    "Closing it takes the Icebreaker scene bundle and a pass over its " &
    "SpawnPointParams objects; the result is a JSON array that drops in at " &
    "locations.<slot>.base.SpawnPointParams with no code change, because " &
    "dbWrite merges. `spawnPointsFile` in config.json points at one."

proc weatherNote*(): string =
  ## The arctic-weather refusal, which is a fact about this stack rather than
  ## about this mod -- and which had to be re-checked, because half of what it
  ## used to say stopped being true. It said "there is no weather table in the
  ## database at all, so writing one would write into a path nothing reads".
  ## `mods/tarkov`'s `emu/raid.nim` now reads `weather` out of the database and
  ## falls back to its constant only when there is none, so that path *is*
  ## read. What remains true is the part that actually blocks this mod, and it
  ## is a different part, so it is said differently.
  result =
    "Arctic weather for this map alone cannot be set from a mod on this " &
    "stack, and it is worth being exact rather than vague about why. The " &
    "database now has a `weather` table that mods/tarkov reads and answers " &
    "/client/weather from, so a mod can set the sky -- but that table is one " &
    "record for the whole install, not one per location, and nothing in the " &
    "response is keyed by map. Writing a winter sky into it would put snow " &
    "and a minus-thirty reading over Customs and Streets as well, which is a " &
    "worse bug than a warm icebreaker and one this mod would have caused on " &
    "every other map in the install. Per-map weather needs the location id to " &
    "reach the weather answer -- either mods/tarkov keying `weather` by map, " &
    "or a route-chaining API this ABI does not have -- and both of those are " &
    "somebody else's file. Until then the ship is locked in ice under an " &
    "18-degree cloudless sky, and this mod says so rather than shipping a " &
    "`winter: true` switch that either does nothing or changes every map."

proc lootNote*(): string =
  result =
    "The authored loot tables are 8MB of extracted world coordinates and are " &
    "the same refusal as SpawnPointParams for the same reason. What is " &
    "written instead is an empty but structurally valid table, which is not a " &
    "placeholder: it is the difference between a raid that starts with " &
    "nothing on the floor and a raid that does not start. Dropping the real " &
    "files over locations.<slot>.{looseLoot,staticLoot,staticContainers} " &
    "needs no code change, because dbWrite merges."

proc describe*(r: TableReport): string =
  result = $r.exits & " exit(s) (" & $r.scavDisabled & " closed to scavs), " &
           $r.waves & " wave(s) totalling " & $r.waveSlots & " bot slot(s), " &
           $r.bosses & " boss spawn(s), " & $r.localeKeys & " locale string(s)"
