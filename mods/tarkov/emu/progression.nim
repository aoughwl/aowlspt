## Progression overrides -- player level, skills and weapon mastery, set
## directly rather than earned.
##
## What this module is, and what it deliberately is not
## -----------------------------------------------------
##
## It is a **floor**, applied to the stored profile every time the profile is
## served. Never a ceiling and never a reset: a value already above the
## configured one is left exactly as it is. That is what makes it safe to leave
## switched on -- turning `Player level` to 20 does not undo the levelling that
## happened after it was set, and turning it back to 0 does not take anything
## away.
##
## Each of the three writes the field the CLIENT actually reads, which for two
## of them is not the field the setting is named after:
##
## * **Player level.** The client derives the level it draws from
##   `Info.Experience` against `globals.config.exp.level.exp_table`; it does not
##   trust `Info.Level`. So the setting is a LEVEL and the write is the matching
##   EXPERIENCE (`xpForLevel`), with `Info.Level` set alongside so the server's
##   own `loyaltyLevelFor` and quest conditions agree with the screen. Writing
##   `Info.Level` alone is the version of this feature that looks like it works
##   and is recomputed away on the first frame.
## * **Skills.** `Skills.Common[].Progress`, in points: level N is N * 100
##   (`ProgressPerLevel` in `emu/skills`), clamped at elite. Only ids ALREADY in
##   the profile are touched -- `emu/starter` cut the starter list from 54 to 37
##   because the client answers `Can't find skill to upgrade:` for the 17 it no
##   longer knows, and the measured oracle for that set is the client's log, not
##   `EFT.ESkillId` (fact #178). Reading the ids off the profile means this
##   module can never reintroduce a rejected one.
## * **Mastery.** `Skills.Mastering[].Progress`, in points, against the
##   thresholds each family carries in `globals.config.Mastering` (`Level2` /
##   `Level3`). Mastery is per weapon FAMILY, not per weapon: all 79 families on
##   this database cover several templates each, so "per gun" is expressed as a
##   family filter rather than as 79 rows.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import numbers
import profile
import skills
import traders

const
  MaxPlayerLevel* = 79
    ## The exp table on this database has 79 entries. A request above the table
    ## cannot be honoured with an experience value, so it is clamped rather than
    ## extrapolated.

var
  gPlayerLevel = 0
  gSkillLevel = 0
  gSkillIds = ""
  gMasteryLevel = 0
  gMasteryFamilies = ""
  gExperience = 0
  gExperienceReads = 0

proc configureExperienceFloor*(xp: int) =
  ## The SVM/profile-manager "set XP" knob, as a FLOOR like every other row in
  ## this module. Kept off `configureProgression`'s parameter list on purpose:
  ## that proc has two call sites, and widening a five-argument signature to six
  ## is how a caller silently passes the new value into the old slot.
  gExperience = xp
  inc gExperienceReads

proc experienceFloorReads*(): int = gExperienceReads
  ## For the read ledger in `emu/svm`: proof this key was CONSULTED. It is not
  ## proof the profile changed -- `applyExperienceFloor`'s note is that.

proc configureProgression*(playerLevel, skillLevel: int; skillIds: string;
                           masteryLevel: int; masteryFamilies: string) =
  gPlayerLevel = playerLevel
  gSkillLevel = skillLevel
  gSkillIds = skillIds
  gMasteryLevel = masteryLevel
  gMasteryFamilies = masteryFamilies

proc progressionActive*(): bool =
  gPlayerLevel > 0 or gSkillLevel > 0 or gMasteryLevel > 0 or gExperience > 0

# ---------------------------------------------------------------------------
# Level <-> experience
# ---------------------------------------------------------------------------

proc expTable(): seq[JsonRef] =
  let v = dbRead("globals.config.exp.level.exp_table")
  if not v.ok or v.raw.len == 0:
    return @[]
  result = each(whole(v.raw))

proc xpForLevel*(level: int): int =
  ## The experience at which the client draws `level`.
  ##
  ## `exp_table[i].exp` is what it costs to leave level `i + 1`, so the total at
  ## level L is the sum of the first L entries -- entry 0 is 0, which is why
  ## level 1 sits at zero experience. A server with no globals has no table and
  ## gets 0 back, which this module then treats as "cannot do it" rather than as
  ## "set the player to zero".
  if level <= 1:
    return 0
  let table = expTable()
  if table.len == 0:
    return 0
  var total = 0
  var i = 0
  while i < table.len and i < level:
    total = total + table[i].field("exp").asInt(0)
    inc i
  result = total

proc levelForXp*(xp: int): int =
  ## The inverse, by the same table. Used only to report.
  let table = expTable()
  if table.len == 0:
    return 1
  var total = 0
  var i = 0
  var lvl = 1
  while i < table.len:
    total = total + table[i].field("exp").asInt(0)
    if xp < total:
      break
    lvl = i + 1
    inc i
  result = lvl

# ---------------------------------------------------------------------------
# The filters
# ---------------------------------------------------------------------------

proc wanted(filter, name: string): bool =
  ## An empty filter means everything. Otherwise a comma-separated list, matched
  ## case-insensitively on the whole name -- a substring match would make
  ## `AK` select `AKM`, `AKSU` and `AK74`, which is a different feature.
  if filter.strip().len == 0:
    return true
  for part in filter.split(','):
    if part.strip().toLowerAscii() == name.toLowerAscii():
      return true
  result = false

# ---------------------------------------------------------------------------
# The three writes
# ---------------------------------------------------------------------------

proc applyPlayerLevel(p: var Profile; notes: var seq[string]): bool =
  if gPlayerLevel <= 0:
    return false
  var target = gPlayerLevel
  if target > MaxPlayerLevel:
    target = MaxPlayerLevel
  let xp = xpForLevel(target)
  if xp <= 0 and target > 1:
    notes.add "progression: no globals.config.exp.level.exp_table, so a " &
              "player level of " & $target & " has no experience value and " &
              "was NOT applied"
    return false
  if p.experience >= xp:
    return false
  setNumber(p, "Info.Experience", xp)
  setNumber(p, "Info.Level", target)
  notes.add "progression: player level -> " & $target & " (Info.Experience " &
            "= " & $xp & ")"
  result = true

proc applyExperienceFloor(p: var Profile; notes: var seq[string]): bool =
  ## Raise `Info.Experience` to an exact number, and re-derive `Info.Level` from
  ## it rather than leaving the two disagreeing.
  ##
  ## `Info.Level` is written from `levelForXp`, not from anything the player
  ## typed, because the client draws the level it shows from the EXPERIENCE
  ## against `exp_table` (see the module header). Writing an experience without
  ## re-deriving the level is the same defect the level row already documents,
  ## in the other direction: the screen would agree with nothing.
  if gExperience <= 0:
    return false
  if p.experience >= gExperience:
    return false
  let lvl = levelForXp(gExperience)
  setNumber(p, "Info.Experience", gExperience)
  if lvl > 0:
    setNumber(p, "Info.Level", lvl)
  notes.add "progression: Info.Experience -> " & $gExperience &
            " (level " & $lvl & ", re-derived from the exp table)"
  result = true

proc applySkillLevels(p: var Profile; notes: var seq[string]): bool =
  if gSkillLevel <= 0:
    return false
  var target = gSkillLevel
  if target > MaxSkillLevel:
    target = MaxSkillLevel
  let want = ProgressPerLevel * float(target)
  let common = p.field("Skills.Common")
  if not common.found:
    notes.add "progression: this profile has no Skills.Common, so no skill " &
              "level was applied"
    return false
  var list = parseArray(raw(common))
  if not list.ok:
    return false
  var touched = 0
  for i in 0 ..< list.len:
    let id = field(list.items[i], "Id").asText("")
    if id.len == 0 or not wanted(gSkillIds, id):
      continue
    if field(list.items[i], "Progress").asFloat(0.0) >= want:
      continue
    var d = parseObject(list.items[i])
    if not d.ok:
      continue
    setRaw(d, "Progress", numText(want))
    list.replaceAt(i, text(d))
    inc touched
  if touched == 0:
    return false
  setRaw(p, "Skills.Common", text(list))
  notes.add "progression: " & $touched & " skills raised to level " & $target
  result = true

proc applyMastery(p: var Profile; notes: var seq[string]): bool =
  if gMasteryLevel <= 0:
    return false
  var target = gMasteryLevel
  if target > 3:
    target = 3
  let families = each(whole(masteringTable()))
  if families.len == 0:
    notes.add "progression: no globals.config.Mastering table, so no weapon " &
              "mastery was applied -- without it there is no way to know " &
              "which family a weapon belongs to"
    return false
  let existing = p.field("Skills.Mastering")
  var list = parseArray(if existing.found: raw(existing) else: "[]")
  if not list.ok:
    list = newList()
  var touched = 0
  for f in families:
    let name = f.field("Name").asText("")
    if name.len == 0 or not wanted(gMasteryFamilies, name):
      continue
    # Level 1 is "has fired it at all" -- zero points. Level 2 and 3 are the
    # family's own two thresholds, read from the database rather than assumed,
    # because they differ per family (M4 is 1600/2000, SKS 200/300).
    var want = 0
    if target == 2:
      want = f.field("Level2").asInt(0)
    elif target == 3:
      want = f.field("Level3").asInt(0)
    var at = -1
    for i in 0 ..< list.len:
      if field(list.items[i], "Id").asText("") == name:
        at = i
    if at >= 0:
      if field(list.items[at], "Progress").asInt(0) >= want:
        continue
      var d = parseObject(list.items[at])
      if not d.ok:
        continue
      setNumber(d, "Progress", want)
      list.replaceAt(at, text(d))
    else:
      var d = newDoc()
      setText(d, "Id", name)
      setNumber(d, "Progress", want)
      list.add d
    inc touched
  if touched == 0:
    return false
  setRaw(p, "Skills.Mastering", text(list))
  notes.add "progression: " & $touched & " weapon mastery families raised to " &
            "level " & $target
  result = true

proc applyTraderLoyalty(p: var Profile; notes: var seq[string]): bool =
  ## `traderMaxLoyalty` changes what `loyaltyLevelFor` DERIVES, but the number
  ## the rest of the server reads is the one stored on
  ## `TradersInfo.<id>.loyaltyLevel`, and that is only rewritten by
  ## `refreshLoyalty` after a trade, a quest reward or a scav run. Without this
  ## the switch would appear to do nothing until the player happened to buy
  ## something -- so the stored number is re-derived here, on the same fetch as
  ## the rest of the floors.
  if not gMaxLoyalty:
    return false
  let info = p.field("TradersInfo")
  if not info.found:
    return false
  var raised = 0
  for tid in keys(info):
    let before = loyaltyOf(p, tid)
    let after = refreshLoyalty(p, tid)
    if after > before:
      inc raised
  if raised == 0:
    return false
  notes.add "progression: " & $raised & " trader(s) re-derived to their top " &
            "loyalty level"
  result = true

proc applyProgression*(p: var Profile; notes: var seq[string]): bool =
  ## Returns true when the profile was CHANGED and therefore needs storing.
  ## False is the steady state -- once the floor is met, every later call is a
  ## no-op, which is what makes this safe to run on every profile fetch.
  if not p.ok or not (progressionActive() or gMaxLoyalty):
    return false
  var changed = false
  if applyTraderLoyalty(p, notes): changed = true
  if applyPlayerLevel(p, notes): changed = true
  # AFTER the level row, so that when both are set the higher of the two wins
  # by the same floor rule rather than by which ran first.
  if applyExperienceFloor(p, notes): changed = true
  if applySkillLevels(p, notes): changed = true
  if applyMastery(p, notes): changed = true
  result = changed

# ---------------------------------------------------------------------------
# Self-check
# ---------------------------------------------------------------------------

proc selfCheckProgression*(failures: var seq[string]) =
  ## Pure over the filter and the table maths. Every assertion here is one a
  ## wrong implementation FAILS -- the exp maths is checked against the shape of
  ## the table rather than against itself.
  if not wanted("", "M4"):
    failures.add "progression: an empty family filter excluded M4"
  if not wanted("M4, AKM", "AKM"):
    failures.add "progression: an explicit filter excluded a listed family"
  if wanted("AK", "AKM"):
    failures.add "progression: the filter matched AKM on the substring AK"
  if wanted("M4", "AKM"):
    failures.add "progression: the filter matched an unlisted family"
  if xpForLevel(1) != 0:
    failures.add "progression: level 1 is not zero experience"
  if xpForLevel(0) != 0:
    failures.add "progression: level 0 is not zero experience"
  let table = expTable()
  if table.len > 0:
    # Monotone, and the round trip closes. Both fail on an off-by-one in the
    # cumulative sum, which is the one bug this maths can have.
    var prev = -1
    var l = 1
    while l <= 5 and l <= table.len:
      let xp = xpForLevel(l)
      if xp <= prev and l > 2:
        failures.add "progression: experience for level " & $l &
                     " did not increase"
      if levelForXp(xp) != l:
        failures.add "progression: level " & $l & " -> " & $xp &
                     " -> level " & $levelForXp(xp)
      prev = xp
      inc l
