## The vanilla `WildSpawnType` table.
##
## Every bot role the game knows is an integer, and the game's own difficulty
## settings name their enemies by that integer — `ENEMY_BOT_TYPES: [24, 51]`
## rather than `["exUsec", "pmcBEAR"]`. So a faction system that lets a mod say
## "hostile to the rogues" has to be able to turn a name into a number.
##
## The numbers below were read out of the shipped assemblies rather than typed
## from memory: `EFT.WildSpawnType` in `Assembly-CSharp.dll` and
## `SPTarkov.Server.Core.Models.Eft.Common.WildSpawnType` in
## `SPTarkov.Server.Core.dll` were both decoded from their ECMA-335 metadata and
## agree on all 64 names. The gaps at 31, 54, 55 and 56 are real — those values
## were removed upstream, and they are absent here rather than guessed at.
##
## They are still *data*, not truth: BSG renumbers this enum between wipes. A
## deployment whose client disagrees can override any entry from
## `config.json`'s `wildSpawnTypes` object without touching this file.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json

const
  VanillaNames* = [
    "marksman", "assault", "bossTest", "bossBully", "followerTest",
    "followerBully", "bossKilla", "bossKojaniy", "followerKojaniy", "pmcBot",
    "cursedAssault", "bossGluhar", "followerGluharAssault",
    "followerGluharSecurity", "followerGluharScout", "followerGluharSnipe",
    "followerSanitar", "bossSanitar", "test", "assaultGroup", "sectantWarrior",
    "sectantPriest", "bossTagilla", "followerTagilla", "exUsec", "gifter",
    "bossKnight", "followerBigPipe", "followerBirdEye", "bossZryachiy",
    "followerZryachiy", "bossBoar", "followerBoar", "arenaFighter",
    "arenaFighterEvent", "bossBoarSniper", "crazyAssaultEvent",
    "peacefullZryachiyEvent", "sectactPriestEvent", "ravangeZryachiyEvent",
    "followerBoarClose1", "followerBoarClose2", "bossKolontay",
    "followerKolontayAssault", "followerKolontaySecurity", "shooterBTR",
    "bossPartisan", "spiritWinter", "spiritSpring", "peacemaker", "pmcBEAR",
    "pmcUSEC", "skier", "sectantPredvestnik", "sectantPrizrak", "sectantOni",
    "infectedAssault", "infectedPmc", "infectedCivil", "infectedLaborant",
    "infectedTagilla", "bossTagillaAgro", "bossKillaAgro", "tagillaHelperAgro"]

  VanillaValues* = [
    0, 1, 2, 3, 4,
    5, 6, 7, 8, 9,
    10, 11, 12,
    13, 14, 15,
    16, 17, 18, 19, 20,
    21, 22, 23, 24, 25,
    26, 27, 28, 29,
    30, 32, 33, 34,
    35, 36, 37,
    38, 39, 40,
    41, 42, 43,
    44, 45, 46,
    47, 48, 49, 50, 51,
    52, 53, 57, 58, 59,
    60, 61, 62, 63,
    64, 65, 66, 67]

# Overrides, read once from this mod's `config.json`. Kept as two parallel
# sequences rather than a table: nimony's `Table` would work, but every other
# registry in this mod is a pair of seqs and one shape is easier to read than
# two.
var gOverrideNames: seq[string] = @[]
var gOverrideValues: seq[int] = @[]

proc lower*(s: string): string =
  ## Bot table keys are lower-case, always. SPT requires it and the emulator's
  ## database follows, so every path built from a type name goes through here.
  result = ""
  for ch in s:
    if ch >= 'A' and ch <= 'Z':
      result.add char(ord(ch) + 32)
    else:
      result.add ch

proc loadOverrides*() =
  ## `"wildSpawnTypes": {"pmcUSEC": 52}` in `config.json`. An entry here wins
  ## over the compiled table, which is how a deployment survives a renumbering
  ## without a rebuild.
  gOverrideNames = @[]
  gOverrideValues = @[]
  let c = setting("wildSpawnTypes")
  if not c.ok or c.raw.len == 0:
    return
  let doc = whole(c.raw)
  let names = keys(doc)
  for n in names:
    let v = child(doc, n)
    if v.found:
      gOverrideNames.add n
      gOverrideValues.add v.asInt(-1)
  if gOverrideNames.len > 0:
    info "morebots: " & $gOverrideNames.len &
         " WildSpawnType value(s) overridden from config.json"

proc vanillaId*(name: string): int =
  ## The value for a vanilla role name, or -1 when this build does not have it.
  ## -1 rather than 0, because 0 is `marksman` and a wrong-but-plausible id is
  ## the kind of mistake that shows up as "the scav sniper hates everyone".
  for i in 0 ..< gOverrideNames.len:
    if gOverrideNames[i] == name:
      return gOverrideValues[i]
  for i in 0 ..< VanillaNames.len:
    if VanillaNames[i] == name:
      return VanillaValues[i]
  result = -1
