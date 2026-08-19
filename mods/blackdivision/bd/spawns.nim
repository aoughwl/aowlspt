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
    enabled*: bool        ## the hunt at all
    labsEnabled*: bool    ## the Labs event
    gatesEnabled*: bool   ## the two Labs extract ambushes
    showOnMap*: bool      ## a marker on the map screen; off, it is a hunt
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
  SpawnConfig(enabled: true, labsEnabled: true, gatesEnabled: true,
              showOnMap: false,
              chance: 25, minTimeTenths: 1, maxTimeTenths: 8,
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
  result.enabled = child(s, "enabled").asBool(result.enabled)
  result.labsEnabled = child(s, "labsEvent").asBool(result.labsEnabled)
  result.gatesEnabled = child(s, "labsGateAmbushes").asBool(result.gatesEnabled)
  result.showOnMap = child(s, "showOnMap").asBool(result.showOnMap)
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

const
  SpawnRecordFields* = 21
    ## How many members `spawnRecord` writes. Named so the self-test can assert
    ## on it rather than on a number typed twice.

proc spawnRecord(bossName, escortType, escortAmount, zone, triggerId,
                 triggerName: string; chance, delay, time: int;
                 forceSpawn, ignoreMaxBots, showOnMap: bool): JsonObject =
  ## One `BossLocationSpawn` record, in **the field names the shipped database
  ## actually uses**, which is not what an earlier revision of this file wrote.
  ##
  ## That earlier revision is worth recording rather than quietly fixing,
  ## because it is the exact failure mode this whole pass exists to find. It
  ## wrote `BossDifficulty`, `BossEscortDifficulty`, `IsBossPlayer` and
  ## `IsRandomTimeSpawn` — four plausible, readable, *wrong* names. The 140
  ## `BossLocationSpawn` records in a real SPT database spell them
  ## `BossDifficult`, `BossEscortDifficult`, `BossPlayer` and `RandomTimeSpawn`,
  ## on 140 of 140 entries. A record with the wrong spelling deserialises with
  ## those four members at their type defaults — difficulty `null`, and a squad
  ## that either does not spawn or spawns wrong — and nothing anywhere logs a
  ## word about it. The mod looks installed and does nothing, which is the worst
  ## available outcome and is indistinguishable from the map not being reached.
  ##
  ## `ShowOnTarkovMap` / `ShowOnTarkovMapPvE` are on 135 of 140 and were absent
  ## here entirely. They are false for this faction on purpose: Black Division
  ## hunting you is not supposed to be a marker on the map screen.
  ##
  ## Every field is written even at its default, because the client indexes
  ## several of them without checking first — a record missing `SpawnMode` is a
  ## null dereference at map load rather than a bot that fails to spawn.
  var modes = arr()
  modes.add "regular"
  modes.add "pve"
  result = obj()
  put(result, "BossName", bossName)
  put(result, "BossChance", chance)
  put(result, "BossDifficult", "normal")
  put(result, "BossEscortAmount", escortAmount)
  put(result, "BossEscortDifficult", "normal")
  put(result, "BossEscortType", escortType)
  put(result, "BossZone", zone)
  put(result, "BossPlayer", false)
  put(result, "Delay", delay)
  put(result, "DependKarma", false)
  put(result, "DependKarmaPVE", false)
  put(result, "ForceSpawn", forceSpawn)
  put(result, "IgnoreMaxBots", ignoreMaxBots)
  put(result, "RandomTimeSpawn", false)
  put(result, "ShowOnTarkovMap", showOnMap)
  put(result, "ShowOnTarkovMapPvE", showOnMap)
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

proc spawnable*(mapKey: string): bool =
  ## Whether a squad written onto this map could ever arrive.
  ##
  ## `locationExists` is not enough, and the case that proves it is `suburbs`.
  ## A stock SPT 4.x database carries `locations.suburbs.base` as a **record
  ## with no map behind it** -- it has fields, so it passes any "is it there"
  ## probe, and it has `SpawnPointParams: []`, `BotMax: 0` and no exits. Put
  ## `suburbs` in `huntMaps` and this mod writes a perfectly well-formed
  ## `BossLocationSpawn` entry onto a slot with nowhere to put a bot. Nothing
  ## errors, nothing logs, and the squad simply never exists.
  ##
  ## It is not a hypothetical: `mods/icebreaker` rebinds exactly that slot, and
  ## it rebinds it *without* `SpawnPointParams`, which it refuses to invent
  ## because a spawn point is nothing but world coordinates and a guessed one
  ## puts the player inside the hull. So the slot becomes a real map with a
  ## name, a cap, waves and exits, and it still cannot host a spawn. A user who
  ## adds `suburbs` to `huntMaps` after installing Icebreaker has done a
  ## reasonable thing and must be told why it does not work.
  ##
  ## The test is `SpawnPointParams`, not the map name: it is the property that
  ## actually decides the question, it needs no list of known-bad slots to keep
  ## up to date, and the day somebody drops a spawn-point array into the
  ## database this starts working with no code change. On the real 39 MiB
  ## import four slots answer no -- `suburbs`, `terminal`, `town` and
  ## `privatearea` -- and every playable map answers yes, including
  ## `factory4_day`, which has `BotMax: 0` and 145 spawn points and would have
  ## been the false negative of any cap-based test.
  ##
  ## **Present and empty is the refusal; absent is not.** A partial database
  ## dump -- the emulator's own fixture is one -- carries no `SpawnPointParams`
  ## on any location, and refusing there would mean this mod wrote nothing at
  ## all on a database that is simply incomplete rather than wrong. An empty
  ## array is a statement; a missing key is silence, and this mod does not get
  ## to read a refusal into silence.
  if not locationExists(mapKey):
    return false
  let sp = dbRead("locations." & mapKey & ".base.SpawnPointParams")
  if not sp.ok or sp.raw.len == 0:
    return true
  let a = whole(sp.raw)
  if not isArray(a):
    return true
  result = count(a) > 0

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

# ---------------------------------------------------------------------------
# One write for every map, not one per map
# ---------------------------------------------------------------------------
#
# `dbWrite` costs the size of the *database*, not the size of the patch: the
# backend holds one text document and a patch splices into it, so every call
# copies the whole thing twice and throws the member index away. On an imported
# SPT database that is 41 MB and about 130 ms, per call, whatever the call says.
#
# Eleven maps used to be eleven calls -- 1.5 s of copying the same forty-one
# megabytes eleven times to change eleven arrays. They are now collected into
# one `locations` document and written once. The merge rule makes that exactly
# equivalent: a patch of `{"bigmap":{"base":{"BossLocationSpawn":[...]}}}`
# merged into `locations` reaches the same member as a patch of `[...]` merged
# into `locations.bigmap.base.BossLocationSpawn`, because an object member
# present in both sides recurses and anything else replaces.

var gPendingMaps: seq[string] = @[]
var gPendingLists: seq[string] = @[]

proc stageSpawns(mapKey: string; list: JsonArray) =
  ## Remember this map's rebuilt list. The last word for a map wins, which is
  ## what a second pass over the same map means.
  let text = done(list).text
  for i in 0 ..< gPendingMaps.len:
    if gPendingMaps[i] == mapKey:
      gPendingLists[i] = text
      return
  gPendingMaps.add mapKey
  gPendingLists.add text

proc commitSpawns(): int =
  ## Every staged map, in one `dbWrite`. Returns how many maps it carried.
  result = 0
  if gPendingMaps.len == 0:
    return 0
  var doc = obj()
  for i in 0 ..< gPendingMaps.len:
    var base1 = obj()
    put(base1, "BossLocationSpawn", raw(gPendingLists[i]))
    var m = obj()
    put(m, "base", base1)
    put(doc, gPendingMaps[i], m)
  let n = gPendingMaps.len
  gPendingMaps = @[]
  gPendingLists = @[]
  if not dbPut("locations", done(doc).text):
    error "blackdivision: could not write the spawn lists for " & $n & " map(s)"
    return 0
  result = n

# ---------------------------------------------------------------------------
# The three kinds
# ---------------------------------------------------------------------------

proc huntLeader(): string =
  ## Who is running this particular squad.
  ##
  ## Upstream sent `blackDivAssault` every time and this file copied it, which
  ## meant five of the six roles this mod registers — the lead, the breacher and
  ## the support especially — were declared, given templates, given hostility
  ## relations and then never spawned anywhere at all. A faction with three
  ## unreachable members is three quarters of a faction. The lead runs most
  ## squads because that is what a lead is for; the rest is the mix.
  let r = randomBelow(100)
  if r < 45: return "blackDivLead"
  if r < 75: return "blackDivAssault"
  if r < 90: return "blackDivSupport"
  result = "blackDivBreacher"

proc huntEscort(leader: string): string =
  ## And who is following. Never the same role as the leader, so a squad reads
  ## as a squad rather than as four copies of one man.
  let r = randomBelow(100)
  var pick = "blackDivAssault"
  if r < 40: pick = "blackDivAssault"
  elif r < 65: pick = "blackDivBreacher"
  elif r < 85: pick = "blackDivSupport"
  else: pick = "blackDivIb"
  if pick == leader:
    pick = (if leader == "blackDivAssault": "blackDivBreacher"
            else: "blackDivAssault")
  result = pick

proc huntSquad*(cfg: SpawnConfig; mapKey: string): JsonObject =
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
  let leader = huntLeader()
  result = spawnRecord(leader, huntEscort(leader), $followers,
                       "", HuntTrigger, "", cfg.chance, 0, at, true, true,
                       cfg.showOnMap)

proc labsEvent*(cfg: SpawnConfig): JsonObject =
  ## Wedge, with raiders. `BossEscortAmount` is a comma list of candidate counts
  ## and the game picks one, which is how the escort ends up between three and
  ## six without a second roll here.
  result = spawnRecord("bossWedge", "blackDivIb", "3,3,3,4,4,6",
                       "BotZoneFloor2,BotZoneFloor1,BotZoneBasement",
                       HuntTrigger, "", cfg.labsStartChance, 0, -1, true, false,
                       cfg.showOnMap)

proc gateAmbush*(cfg: SpawnConfig; zone, trigger: string): JsonObject =
  ## Waiting at an extract. `BossChance` is 100 because the roll already
  ## happened — whether the ambush exists at all is the `labsGateChances` roll;
  ## once it does, it fires. `IgnoreMaxBots` because an ambush that does not
  ## spawn for want of a bot slot is an ambush that never happened.
  ##
  ## The breacher leads a gate ambush and always has: an ambush at a door is
  ## the one situation the role exists for.
  result = spawnRecord("blackDivBreacher", "blackDivAssault", "3,3,4,5",
                       zone, trigger, "interactObject", 100, 8, -1, true, true,
                       false)

# ---------------------------------------------------------------------------
# The whole pass
# ---------------------------------------------------------------------------

proc adjustLabs*(cfg: SpawnConfig): bool =
  if not cfg.labsEnabled and not cfg.gatesEnabled:
    return false
  if not spawnable(LabsKey):
    if locationExists(LabsKey):
      warn "blackdivision: " & LabsKey & " has an empty SpawnPointParams, so " &
           "the Labs event and the two gate ambushes were not written. A " &
           "record there would be accepted and never fire."
    return false
  var list = keepForeign(LabsKey)
  if cfg.labsEnabled:
    list.add labsEvent(cfg)
  # The two gates are independent rolls, as upstream had them: the interesting
  # case is the raid where one of them is live and the other is not.
  if cfg.gatesEnabled:
    if rollPercent(cfg.labsGateChance):
      list.add gateAmbush(cfg, "BotZoneGate1", GateTriggerB)
      info "blackdivision: gate 1 is watched this raid"
    if rollPercent(cfg.labsGateChance):
      list.add gateAmbush(cfg, "BotZoneGate2", GateTriggerA)
      info "blackdivision: gate 2 is watched this raid"
  stageSpawns(LabsKey, list)
  result = true

proc adjustHuntMaps*(cfg: SpawnConfig): int =
  ## Returns how many maps were given a squad. A map the database does not have
  ## is skipped quietly at info level rather than warned about: a server running
  ## a partial database dump is a normal state here, not a fault.
  result = 0
  if not cfg.enabled:
    return 0
  var refused: seq[string] = @[]
  for m in cfg.huntMaps:
    if not locationExists(m):
      continue
    if not spawnable(m):
      refused.add m
      continue
    var list = keepForeign(m)
    list.add huntSquad(cfg, m)
    stageSpawns(m, list)
    inc result
  if refused.len > 0:
    var names = refused[0]
    for i in 1 ..< refused.len:
      names = names & ", " & refused[i]
    warn "blackdivision: " & $refused.len & " map(s) in huntMaps have an " &
         "empty SpawnPointParams -- " & names & ". They are in the database " &
         "and they have no places to put a bot, so no squad was written to " &
         "them: a BossLocationSpawn record on such a map is accepted, never " &
         "fires, and reports nothing. The usual cause is a map mod that " &
         "rebinds a location slot without shipping its spawn points (the " &
         "`suburbs` slot and mods/icebreaker are the case this exists for). " &
         "Nothing is lost on the other maps; remove these from huntMaps to " &
         "stop seeing this."

proc clearAll*(cfg: SpawnConfig): int =
  ## Every entry this mod owns, removed and nothing put back.
  ##
  ## Needed because turning `spawns.enabled` off in `config.json` has to
  ## *un-write* a previous run's records — the database persists, so a switch
  ## that only stops adding leaves the last raid's squads in place for ever and
  ## reads as a switch that does not work.
  result = 0
  var all: seq[string] = @[]
  for m in cfg.huntMaps:
    all.add m
  all.add LabsKey
  for m in all:
    if not locationExists(m):
      continue
    let before = count(whole(dbRead("locations." & m &
                                    ".base.BossLocationSpawn").raw))
    let kept = keepForeign(m)
    if kept.len == before:
      continue
    stageSpawns(m, kept)
    inc result

proc adjustAll*(cfg: SpawnConfig): int =
  ## Every spawn this mod owns, rebuilt from scratch, and written once.
  ##
  ## The reads all happen before the write, which matters for more than tidiness:
  ## a `dbWrite` invalidates the backend's member index, so a read-write-read-write
  ## walk pays for a fresh index on every map. Reading eleven maps and then
  ## writing once pays for it a single time.
  if not cfg.enabled and not cfg.labsEnabled and not cfg.gatesEnabled:
    let cleared = clearAll(cfg)
    let written = commitSpawns()
    if cleared > 0:
      info "blackdivision: spawns are off in config.json; " & $written &
           " map(s) had this mod's previous entries removed"
    return 0
  var staged = adjustHuntMaps(cfg)
  if adjustLabs(cfg):
    inc staged
  result = commitSpawns()
  if result != staged:
    warn "blackdivision: staged " & $staged & " map(s) and wrote " & $result
