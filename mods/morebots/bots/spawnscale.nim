## More bots: the population knobs, and the reason they are computed from a
## shipped baseline rather than from the database.
##
## ---------------------------------------------------------------------------
## WHAT THIS ACTUALLY CHANGES
## ---------------------------------------------------------------------------
##
## Three fields per map, all inside `locations.<map>.base`, which is served to
## the client verbatim by `/client/locations`:
##
##   * **`BotMax`** / **`BotMaxPvE`** — how many AI may be alive at once.
##   * **`MaxBotPerZone`** — how many may be alive in one bot zone. Raising
##     `BotMax` alone does very little: the spawner will not put a fifth bot in
##     a zone that allows four, so the extra headroom is never used and the mod
##     reads as broken. Both move together or neither is worth moving.
##   * **`waves[].slots_min` / `slots_max`** — how many bots each scav wave
##     brings. This is the one that actually changes how a raid *feels*; the cap
##     only sets the ceiling.
##
## ---------------------------------------------------------------------------
## WHY THERE IS A SHIPPED BASELINE AND NOT A READ-MODIFY-WRITE
## ---------------------------------------------------------------------------
##
## The obvious implementation is: read `BotMax`, multiply it, write it back.
## That implementation is wrong, and wrong in the way that takes a month to
## notice. The database **persists**. Every server start reads back the number
## the last start wrote, multiplies it again, and writes it again. At 1.5x, a
## map at 30 is at 45, then 68, then 101, then 152. Nothing errors. Nothing logs.
## The only symptom is that the game gets slower every week and the player
## eventually blames their hardware.
##
## So the numbers this scales *from* are a shipped data file — `data/vanilla.json`,
## read out of a stock SPT 4.x database, all nineteen location slots, 154 waves.
## Applying the multiplier twice gives the same answer as applying it once,
## which is the only property that makes a config knob safe to keep turning.
##
## The same file is what makes **`preset: "vanilla"` mean something**. Turning
## the mod off has to be able to put the numbers *back*, and a mod that has
## forgotten what they were cannot.
##
## ---------------------------------------------------------------------------
## WHAT THE EMULATOR DOES AND DOES NOT DO WITH THIS
## ---------------------------------------------------------------------------
##
## `mods/tarkov` does not read `waves`, `BotMax` or `MaxBotPerZone`, and it is
## worth being exact about why that is not a reason to skip writing them.
## `/client/locations` answers with `dbRead("locations")` **verbatim** — the
## whole table, untouched — so every field written here reaches the client
## inside that response and the client is what spawns bots. The server reads
## none of it because the server does not run the raid.
##
## The one genuinely unreachable knob is `/client/game/bot/limit`, which the
## emulator answers with the literal string `30` and which is not backed by any
## database path. That is reported by `report()` below rather than worked
## around, because there is no way around it that does not involve editing a mod
## this one does not own.

import std/strutils
import std/syncio
import aowlspt
import aowlspt/server
import aowlspt/json
import dbpath

type
  ScaleConfig* = object
    enabled*: bool
    preset*: string
    botCap*: float          ## multiplier on BotMax / BotMaxPvE
    perZone*: float         ## multiplier on MaxBotPerZone
    waveSlots*: float       ## multiplier on every wave's slots_min/slots_max
    capFloor*: int          ## never write a cap below this
    capCeiling*: int        ## never write a cap above this, whatever the maths
    perZoneCeiling*: int
    waveCeiling*: int       ## the largest slots_max any one wave may reach
    onlyMaps*: seq[string]  ## empty means every map in the baseline

  ScaleReport* = object
    maps*: int
    mapsChanged*: int
    waves*: int
    wavesChanged*: int
    capBefore*: int
    capAfter*: int
    slotsBefore*: int
    slotsAfter*: int
    clamped*: int
    skipped*: int
    donated*: int            ## maps scaled from a baseline another mod donated
    skippedMaps*: seq[string] ## by name: a count alone is not actionable

const
  Presets* = ["vanilla", "more", "lots", "horde"]
    ## Named settings, so a player does not have to reason about three
    ## multipliers at once to get a busier map. `custom` is any other string and
    ## means "use the three numbers below as written".

var gBaseline = ""            ## data/vanilla.json, read once
var gBaselineMaps = 0

proc readTextFile*(path: string): string =
  result = ""
  try:
    result = readFile(path)
  except:
    result = ""

proc loadBaseline*(): bool =
  ## `data/vanilla.json`, once. Without it this module refuses to do anything at
  ## all rather than falling back to read-modify-write — see the header. A mod
  ## that silently switches to the unsafe algorithm when its data is missing is
  ## worse than one that stops.
  if gBaseline.len > 0:
    return true
  gBaseline = readTextFile(dataDir() & "/vanilla.json")
  if gBaseline.len < 3:
    gBaseline = ""
    return false
  gBaselineMaps = keys(child(whole(gBaseline), "maps")).len
  result = gBaselineMaps > 0

proc baselineMapCount*(): int = gBaselineMaps

proc baselineWaveCount*(): int =
  result = 0
  if gBaseline.len < 3:
    return
  let maps = child(whole(gBaseline), "maps")
  let names = keys(maps)
  for n in names:
    result = result + count(child(child(maps, n), "waves"))

proc isBaselineMap*(name: string): bool =
  if gBaseline.len < 3:
    return false
  result = child(child(whole(gBaseline), "maps"), name).found

proc baselineMapNames*(): seq[string] =
  result = @[]
  if gBaseline.len < 3:
    return
  result = keys(child(whole(gBaseline), "maps"))

proc defaultScaleConfig*(): ScaleConfig =
  ScaleConfig(enabled: false, preset: "vanilla",
              botCap: 1.0, perZone: 1.0, waveSlots: 1.0,
              capFloor: 4, capCeiling: 60, perZoneCeiling: 12,
              waveCeiling: 12, onlyMaps: @[])

proc applyPreset*(c: var ScaleConfig) =
  ## The three multipliers a named preset stands for.
  ##
  ## The ceilings are not part of the preset and are not scaled by it: they are
  ## the machine's limit rather than the player's taste, and a preset that
  ## quietly raised them would defeat the point of having them.
  case c.preset
  of "vanilla":
    c.botCap = 1.0
    c.perZone = 1.0
    c.waveSlots = 1.0
  of "more":
    # Noticeably busier and still comfortably inside what a stock raid's
    # spawn-point count can place.
    c.botCap = 1.35
    c.perZone = 1.5
    c.waveSlots = 1.35
  of "lots":
    c.botCap = 1.75
    c.perZone = 2.0
    c.waveSlots = 1.75
  of "horde":
    # Past the point where any of this is balanced. Named honestly.
    c.botCap = 2.5
    c.perZone = 3.0
    c.waveSlots = 2.5
  else:
    discard   # "custom", or anything else: the numbers as written

proc readScaleConfig*(rawText: string): ScaleConfig =
  result = defaultScaleConfig()
  if rawText.len < 2:
    return
  let s = whole(rawText)
  if not s.found:
    return
  result.enabled = child(s, "enabled").asBool(result.enabled)
  result.preset = child(s, "preset").asText(result.preset)
  applyPreset(result)
  # Read after the preset, so an explicit number in config.json beats the
  # preset it sits beside rather than being silently overwritten by it.
  result.botCap = child(s, "botCapMultiplier").asFloat(result.botCap)
  result.perZone = child(s, "maxBotPerZoneMultiplier").asFloat(result.perZone)
  result.waveSlots = child(s, "waveSlotMultiplier").asFloat(result.waveSlots)
  result.capFloor = child(s, "capFloor").asInt(result.capFloor)
  result.capCeiling = child(s, "capCeiling").asInt(result.capCeiling)
  result.perZoneCeiling = child(s, "perZoneCeiling").asInt(result.perZoneCeiling)
  result.waveCeiling = child(s, "waveSlotCeiling").asInt(result.waveCeiling)
  let only = child(s, "onlyMaps")
  if only.found and count(only) > 0:
    result.onlyMaps = @[]
    let items = each(only)
    for m in items:
      let n = m.asText("")
      if n.len > 0:
        result.onlyMaps.add n

proc scaled(base: int; mul: float; floor1, ceil1: int; clamped: var int): int =
  ## One number, scaled and clamped, with the clamp counted.
  ##
  ## A clamp is reported rather than silent. "I asked for 3x and got 1.9x" is a
  ## fact the player needs, and the alternative -- a mod that quietly ignores
  ## the number you typed -- is the reason people stop trusting config files.
  if base <= 0:
    return base    # 0 means "the map does not use this field"; leave it alone
  var v = int(float(base) * mul + 0.5)
  if v < floor1:
    v = floor1
  if v > ceil1:
    v = ceil1
    inc clamped
  result = v

proc wantsMap(c: ScaleConfig; m: string): bool =
  if c.onlyMaps.len == 0:
    return true
  for x in c.onlyMaps:
    if x == m:
      return true
  result = false

proc scaleWaves(baseWaves: JsonRef; current: string; mapKey: string;
                c: ScaleConfig; r: var ScaleReport): string =
  ## The map's `waves` array, rebuilt.
  ##
  ## Positional against the baseline, and every field of the live entry is
  ## copied through except the two this mod owns. That matters: a wave record
  ## carries `SpawnPoints`, `BotSide`, `BotPreset`, `KeepZoneOnSpawn`,
  ## `SpawnMode` and `WildSpawnType`, and rebuilding one from scratch would drop
  ## whatever this mod's author had not heard of -- which on a modded install is
  ## another mod's work.
  ##
  ## A live array that is a different length from the baseline is left entirely
  ## alone and named as skipped: somebody else has edited it, and guessing
  ## which of their entries corresponds to which of ours would be a coin toss
  ## with a raid on the other side of it.
  ##
  ## Named, not just counted. "1 map was skipped" is not something a player can
  ## act on; "suburbs was skipped, so its waves are stock while every other
  ## map is at 2.5x" is. The mod that owns the map can close it by donating a
  ## baseline -- see `donate` above.
  result = ""
  let live = whole(current)
  if not isArray(live):
    return
  let n = count(live)
  if n == 0 or n != count(baseWaves):
    inc r.skipped
    r.skippedMaps.add mapKey
    return
  var out1 = arr()
  var i = 0
  while i < n:
    let b = at(baseWaves, i)
    let l = at(live, i)
    var d = parseObject(l)
    let bMin = child(b, "slotsMin").asInt(0)
    let bMax = child(b, "slotsMax").asInt(0)
    var clamped = 0
    let sMin = scaled(bMin, c.waveSlots, 0, c.waveCeiling, clamped)
    var sMax = scaled(bMax, c.waveSlots, 0, c.waveCeiling, clamped)
    if sMax < sMin:
      sMax = sMin
    r.clamped = r.clamped + clamped
    inc r.waves
    r.slotsBefore = r.slotsBefore + bMax
    r.slotsAfter = r.slotsAfter + sMax
    if sMax != d.get("slots_max").asInt(bMax) or
       sMin != d.get("slots_min").asInt(bMin):
      inc r.wavesChanged
    setNumber(d, "slots_min", sMin)
    setNumber(d, "slots_max", sMax)
    out1.add raw(text(d))
    inc i
  result = done(out1).text

# ---------------------------------------------------------------------------
# Baselines a map's own mod donates
# ---------------------------------------------------------------------------
#
# `data/vanilla.json` covers the nineteen slots a stock database ships and
# nothing else, and that is a hard limit rather than an oversight: this mod
# cannot scale a map it has never seen stock, because the number it would have
# to scale *from* is the live one, and multiplying the live one compounds on
# every restart. That is the bug the whole shipped-baseline design exists to
# prevent, and it does not stop being that bug for a modded map.
#
# It **was** also a real gap, and it is closed. `mods/icebreaker` rebinds the
# dormant `suburbs` slot into a working map with eleven waves; the vanilla
# baseline has that slot at `botMax: 0` with two stub waves, so the cap was
# skipped for being zero and the wave array skipped for being a different
# length. A player who installed Icebreaker and asked for `horde` got a busier
# raid on eighteen maps and stock numbers on the nineteenth, with nothing said.
#
# That paragraph described an open gap for as long as it was true and then
# outlived the fix, which is the failure this file's own comments keep warning
# about. Icebreaker's `populationBaseline` now puts that map's cap, per-zone
# limit and eleven wave slot pairs into every announcement it makes; a donated
# entry wins over the shipped stub for the same slot; all nineteen scale.
#
# The way out is not for this mod to guess. It is for the mod that *owns* the
# map to say what its own stock numbers are, which it knows exactly, because it
# ships them as data and rewrites them from that data on every boot. So the
# `aowlspt.locations.changed` announcement may carry a `population` object in
# the same shape as an entry in `data/vanilla.json`, and a map announced with
# one is scaled from it. A map announced without one is refused by name, with
# what closing it would take -- see `donate` below and `onLocationsChanged`
# in ../morebots.nim.

var gDonatedNames: seq[string] = @[]
var gDonatedDocs: seq[string] = @[]

proc donate*(name, entryJson: string): bool =
  ## A map mod's own stock numbers for a slot it owns. A later word replaces an
  ## earlier one, so a mod that re-announces is not a mod that accumulates.
  ##
  ## Refused rather than half-accepted when the entry carries neither a cap nor
  ## a wave list: an entry that says nothing would make this mod report the map
  ## as covered while changing nothing on it, which is worse than the gap.
  if name.len == 0 or entryJson.len < 2:
    return false
  let e = whole(entryJson)
  if not e.found:
    return false
  if child(e, "botMax").asInt(0) <= 0 and count(child(e, "waves")) == 0:
    return false
  for i in 0 ..< gDonatedNames.len:
    if gDonatedNames[i] == name:
      gDonatedDocs[i] = entryJson
      return true
  gDonatedNames.add name
  gDonatedDocs.add entryJson
  result = true

proc donatedCount*(): int = gDonatedNames.len

proc donatedBaseline*(name: string): string =
  result = ""
  for i in 0 ..< gDonatedNames.len:
    if gDonatedNames[i] == name:
      return gDonatedDocs[i]

proc isDonated*(name: string): bool =
  for i in 0 ..< gDonatedNames.len:
    if gDonatedNames[i] == name:
      return true
  result = false

proc applyOne(m: string; b: JsonRef; c: ScaleConfig; r: var ScaleReport) =
  ## One map, from one baseline entry. Split out of `apply` so a donated
  ## baseline goes through exactly the same arithmetic, clamps and reporting as
  ## a shipped one -- a second code path for modded maps would be a second
  ## place for the idempotence property to be lost.
  if not wantsMap(c, m):
    return
  let basePath = "locations." & m & ".base"
  let probe = dbView(basePath)
  if not probe.ok or probe.raw.len < 2:
    return          # a database without this map is an ordinary state
  var changed = false

  var clamped = 0
  let baseCap = child(b, "botMax").asInt(0)
  let basePvE = child(b, "botMaxPvE").asInt(baseCap)
  let baseZone = child(b, "maxBotPerZone").asInt(0)
  let newCap = scaled(baseCap, c.botCap, c.capFloor, c.capCeiling, clamped)
  let newPvE = scaled(basePvE, c.botCap, c.capFloor, c.capCeiling, clamped)
  let newZone = scaled(baseZone, c.perZone, 1, c.perZoneCeiling, clamped)
  r.clamped = r.clamped + clamped
  r.capBefore = r.capBefore + baseCap
  r.capAfter = r.capAfter + newCap

  var patch = obj()
  if baseCap > 0:
    put(patch, "BotMax", newCap)
    put(patch, "BotMaxPvE", newPvE)
    if newCap != baseCap:
      changed = true
  if baseZone > 0:
    put(patch, "MaxBotPerZone", newZone)
    if newZone != baseZone:
      changed = true
  if len(patch) > 0:
    discard dbPut(basePath, done(patch).text)

  let baseWaves = child(b, "waves")
  if count(baseWaves) > 0:
    let cur = dbView(basePath & ".waves")
    if cur.ok and cur.raw.len > 1:
      let rebuilt = scaleWaves(baseWaves, cur.raw, m, c, r)
      if rebuilt.len > 2:
        if dbPut(basePath & ".waves", rebuilt):
          changed = true
  if changed:
    inc r.mapsChanged

proc apply*(c: ScaleConfig; r: var ScaleReport): bool =
  ## Every map in the baseline that this database also has, plus every map a
  ## mod has donated a baseline for.
  ##
  ## Returns false only when the baseline itself is missing, because that is the
  ## one failure that must not degrade into doing something approximate.
  if not loadBaseline():
    error "morebots: data/vanilla.json is missing, so the population scaler " &
          "has no baseline to scale from. It will not fall back to reading " &
          "the live values and multiplying those -- that compounds on every " &
          "restart and the only symptom is a server that gets slower every " &
          "week. Nothing was changed."
    return false

  let maps = child(whole(gBaseline), "maps")
  let names = keys(maps)
  for m in names:
    inc r.maps
    if isDonated(m):
      # A slot the shipped baseline covers *and* a mod has claimed: the mod's
      # numbers win, because the shipped ones describe the dormant slot rather
      # than the map now sitting in it. `suburbs` is exactly this case, and
      # scaling the stub's two stub waves under a map with eleven real ones
      # would be the coin toss `scaleWaves` refuses to make.
      continue
    applyOne(m, child(maps, m), c, r)
  for i in 0 ..< gDonatedNames.len:
    if not isBaselineMap(gDonatedNames[i]):
      inc r.maps
    inc r.donated
    applyOne(gDonatedNames[i], whole(gDonatedDocs[i]), c, r)
  result = true

proc describe*(r: ScaleReport): string =
  result = $r.mapsChanged & " of " & $r.maps & " map(s) changed; alive-bot " &
           "cap " & $r.capBefore & " -> " & $r.capAfter & " summed over " &
           "every map, wave slots " & $r.slotsBefore & " -> " & $r.slotsAfter &
           " over " & $r.waves & " wave(s) (" & $r.wavesChanged & " rewritten)"
  if r.donated > 0:
    result = result & "; " & $r.donated &
             " of them from a baseline another mod donated"

proc emptyReport*(): ScaleReport =
  ## One place to build a zeroed report, because there were four and they had
  ## to be edited together every time the type gained a field.
  ScaleReport(maps: 0, mapsChanged: 0, waves: 0, wavesChanged: 0,
              capBefore: 0, capAfter: 0, slotsBefore: 0, slotsAfter: 0,
              clamped: 0, skipped: 0, donated: 0, skippedMaps: @[])

proc baselineText*(): string =
  ## The raw baseline document, for the self-test to walk. Empty until
  ## `loadBaseline` has succeeded.
  result = gBaseline
