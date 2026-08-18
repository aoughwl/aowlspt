## Where Black Division turns up.
##
## Three kinds of spawn, all written into `locations.<map>.base.BossLocationSpawn`
## — the game's own boss-spawn list, which is how anything that is not a plain
## scav gets onto a map:
##
##  * **The Labs event.** Wedge with an escort of raiders, on a chance roll, in
##    the three interior zones.
##  * **The Labs gate ambushes.** Two of them, each on its own roll, hung off
##    the two extraction triggers — so the squad is waiting when the player goes
##    for the door rather than wandering the map for forty minutes first.
##  * **The hunt.** One squad on each configured map, arriving at a randomised
##    point in the raid rather than at the start.
##
## All of it is re-rolled at the end of every raid, so two raids on the same map
## are not the same raid. Upstream did that by hanging a router on
## `/client/match/local/end`; here the emulator broadcasts `tarkov.raid.ended`
## and this mod listens, which is the same thing without two mods fighting over
## one route.
##
## `BossLocationSpawn` is an **array**, and `dbWrite` replaces an array rather
## than merging into it. That is what makes this safe to run repeatedly: the
## list is read, this mod's own entries are dropped, the new ones are appended
## and the whole thing goes back. Entries belonging to anyone else are copied
## through byte for byte.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import data
import dbpath

type
  SpawnConfig* = object
    chance*: int
    minTimeTenths*: int   ## tenths, so the config's 0.1 stays exact in ints
    maxTimeTenths*: int
    minHuntSize*: int
    maxHuntSize*: int
    labsGateChance*: int
    labsStartChance*: int
    huntMaps*: seq[string]

const
  LabsKey* = "laboratory"
  GateTriggerA* = "autoId_00014_EXFIL"
  GateTriggerB* = "autoId_00632_EXFIL"
  HuntTrigger* = "hunt"

proc defaultSpawnConfig*(): SpawnConfig =
  SpawnConfig(chance: 25, minTimeTenths: 1, maxTimeTenths: 8,
              minHuntSize: 3, maxHuntSize: 5,
              labsGateChance: 20, labsStartChance: 15,
              huntMaps: @["bigmap", "tarkovstreets", "shoreline", "lighthouse",
                          "factory4_day", "factory4_night", "interchange",
                          "sandbox_high", "rezervbase", "labyrinth"])

proc tenthsOf(j: JsonRef; default: int): int =
  ## The config writes fractions (`0.1`, `0.8`); the arithmetic here is integer.
  ## Read as tenths once at the edge rather than carrying a float through.
  if not j.found:
    return default
  result = int(j.asFloat(float(default) / 10.0) * 10.0 + 0.5)

proc readSpawnConfig*(raw1: string): SpawnConfig =
  result = defaultSpawnConfig()
  if raw1.len < 2:
    return
  let s = whole(raw1)
  if not s.found:
    return
  result.chance = child(s, "chance").asInt(result.chance)
  result.minTimeTenths = tenthsOf(child(s, "minTime"), result.minTimeTenths)
  result.maxTimeTenths = tenthsOf(child(s, "maxTime"), result.maxTimeTenths)
  result.minHuntSize = child(s, "minHuntSize").asInt(result.minHuntSize)
  result.maxHuntSize = child(s, "maxHuntSize").asInt(result.maxHuntSize)
  result.labsGateChance = child(s, "labsGateChances").asInt(result.labsGateChance)
  result.labsStartChance = child(s, "labsStartChance").asInt(result.labsStartChance)
  let maps = child(s, "huntMaps")
  if maps.found and count(maps) > 0:
    result.huntMaps = @[]
    let items = each(maps)
    for m in items:
      let n = m.asText("")
      if n.len > 0:
        result.huntMaps.add n

# ---------------------------------------------------------------------------
# Building one spawn record
# ---------------------------------------------------------------------------

proc spawnRecord(bossName, escortType, escortAmount, zone, triggerId,
                 triggerName: string; chance, delay, time: int;
                 forceSpawn, ignoreMaxBots: bool): JsonObject =
  ## The shape the game reads. Every field is written even when it is the
  ## default: the client indexes several of them without checking, and a record
  ## missing `SpawnMode` is a null dereference at map load rather than a bot
  ## that fails to spawn.
  var modes = arr()
  modes.add "regular"
  modes.add "pve"
  result = obj()
  put(result, "BossName", bossName)
  put(result, "BossChance", chance)
  put(result, "BossDifficulty", "normal")
  put(result, "BossEscortAmount", escortAmount)
  put(result, "BossEscortDifficulty", "normal")
  put(result, "BossEscortType", escortType)
  put(result, "BossZone", zone)
  put(result, "IsBossPlayer", false)
  put(result, "Delay", delay)
  put(result, "ForceSpawn", forceSpawn)
  put(result, "IgnoreMaxBots", ignoreMaxBots)
  put(result, "IsRandomTimeSpawn", false)
  put(result, "SpawnMode", modes)
  put(result, "Supports", jnull())
  put(result, "Time", time)
  put(result, "TriggerId", triggerId)
  put(result, "TriggerName", triggerName)

proc isOurs(entry: JsonRef): bool =
  ## An entry this mod put there on a previous pass. Matched on the boss and
  ## escort names, which is the only marker the game's own record has room for.
  let boss = field(entry, "BossName").asText("")
  let escort = field(entry, "BossEscortType").asText("")
  result = boss.startsWith("blackDiv") or boss == "bossWedge" or
           escort.startsWith("blackDiv") or escort == "bossWedge"

# ---------------------------------------------------------------------------
# Reading and writing the list
# ---------------------------------------------------------------------------

proc locationExists*(mapKey: string): bool =
  let v = dbRead("locations." & mapKey & ".base")
  result = v.ok and v.raw.len > 2

proc escapeMinutes*(mapKey: string): int =
  let v = dbRead("locations." & mapKey & ".base.EscapeTimeLimit")
  var m = v.asInt(0)
  if m <= 0:
    m = 45
  result = m

proc keepForeign(mapKey: string): JsonArray =
  ## Everyone else's spawns, in order, with ours removed.
  result = arr()
  let cur = dbRead("locations." & mapKey & ".base.BossLocationSpawn")
  if not cur.ok or cur.raw.len < 2:
    return
  let items = each(whole(cur.raw))
  for it in items:
    if isOurs(it):
      continue
    result.add raw(it.raw())

proc writeSpawns(mapKey: string; list: JsonArray): bool =
  result = dbPut("locations." & mapKey & ".base.BossLocationSpawn",
                 done(list).text)

# ---------------------------------------------------------------------------
# The three kinds
# ---------------------------------------------------------------------------

proc huntSquad(cfg: SpawnConfig; mapKey: string): JsonObject =
  ## A squad of `minHuntSize`..`maxHuntSize`, arriving somewhere between
  ## `minTime` and `maxTime` of the way through the raid, low-biased.
  ##
  ## `BossZone` is empty on purpose: the squad may arrive anywhere the map has a
  ## bot zone. Pinning it to a named zone makes the hunt predictable after two
  ## raids, which is the opposite of what it is for.
  let size = randomBetween(cfg.minHuntSize, cfg.maxHuntSize)
  let followers = size - 1
  let limitSeconds = escapeMinutes(mapKey) * 60
  let span = cfg.maxTimeTenths - cfg.minTimeTenths
  let factor = biasedFraction()
  let tenths = cfg.minTimeTenths + int(float(span) * factor)
  let at = (limitSeconds * tenths) div 10
  result = spawnRecord("blackDivAssault", "blackDivAssault", $followers,
                       "", HuntTrigger, "", cfg.chance, 0, at, true, true)

proc labsEvent(cfg: SpawnConfig): JsonObject =
  ## Wedge, with raiders. `BossEscortAmount` is a comma list of candidate counts
  ## and the game picks one, which is how the escort ends up between three and
  ## six without a second roll here.
  result = spawnRecord("bossWedge", "blackDivIb", "3,3,3,4,4,6",
                       "BotZoneFloor2,BotZoneFloor1,BotZoneBasement",
                       HuntTrigger, "", cfg.labsStartChance, 0, -1, true, false)

proc gateAmbush(zone, trigger: string): JsonObject =
  ## Waiting at an extract. `BossChance` is 100 because the roll already
  ## happened — whether the ambush exists at all is the `labsGateChances` roll;
  ## once it does, it fires. `IgnoreMaxBots` because an ambush that does not
  ## spawn for want of a bot slot is an ambush that never happened.
  result = spawnRecord("blackDivAssault", "blackDivAssault", "3,3,4,5",
                       zone, trigger, "interactObject", 100, 8, -1, true, true)

# ---------------------------------------------------------------------------
# The whole pass
# ---------------------------------------------------------------------------

proc adjustLabs*(cfg: SpawnConfig): bool =
  if not locationExists(LabsKey):
    return false
  var list = keepForeign(LabsKey)
  list.add labsEvent(cfg)
  # The two gates are independent rolls, as upstream had them: the interesting
  # case is the raid where one of them is live and the other is not.
  if rollPercent(cfg.labsGateChance):
    list.add gateAmbush("BotZoneGate1", GateTriggerB)
    info "blackdivision: gate 1 is watched this raid"
  if rollPercent(cfg.labsGateChance):
    list.add gateAmbush("BotZoneGate2", GateTriggerA)
    info "blackdivision: gate 2 is watched this raid"
  result = writeSpawns(LabsKey, list)

proc adjustHuntMaps*(cfg: SpawnConfig): int =
  ## Returns how many maps were given a squad. A map the database does not have
  ## is skipped quietly at info level rather than warned about: a server running
  ## a partial database dump is a normal state here, not a fault.
  result = 0
  for m in cfg.huntMaps:
    if not locationExists(m):
      continue
    var list = keepForeign(m)
    list.add huntSquad(cfg, m)
    if writeSpawns(m, list):
      inc result

proc adjustAll*(cfg: SpawnConfig): int =
  ## Every spawn this mod owns, rebuilt from scratch.
  result = adjustHuntMaps(cfg)
  if adjustLabs(cfg):
    inc result
