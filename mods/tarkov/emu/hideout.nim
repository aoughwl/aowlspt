## The hideout: areas, and the levels the player has built them to.
##
## The profile carries one entry per area — its type, its level, whether it is
## running — and the database carries what each level costs and produces. As
## everywhere else here, the state is the profile's and the content is the
## database's, so a server with no hideout data still tracks a hideout: the
## player can upgrade areas the server knows nothing about, and the client draws
## them from its own bundles.
##
## Upgrades are two steps, and it matters that they are. `HideoutUpgrade` starts
## one and takes the materials; `HideoutUpgradeComplete` raises the level when
## the timer has run. Collapsing them into one would give a player the level the
## moment they clicked, which is the difference between a hideout and a menu.
##
## ## Both halves of that sentence used to be untrue
##
## Found by running against a real database rather than the fixture, which is
## the only way either could have been found: the fixture's areas require
## nothing and its first stages are instant, so both faults were invisible in it
## by construction.
##
## **The materials were never taken.** `applyHideout` never read
## `stages.<n>.requirements` at all. `{"Action":"HideoutUpgrade","areaType":6}`
## followed by `HideoutUpgradeComplete` answered `err:0` twice with an empty
## `warnings` array, granted the level, and left the stash untouched. It scales:
## area 10 stage 3 wants 395,000 roubles, Mechanic at loyalty 3, and areas 3 and
## 4 at level 2 -- and a profile with 468,989 roubles and none of the rest went
## 1 -> 2 -> 3 in four requests with its money unchanged. The whole hideout was
## free.
##
## **The timer was computed and then ignored.** `completeTime` was worked out
## correctly and written onto the area, and `haUpgradeComplete` checked only the
## `constructing` flag -- so the level was granted on the very next request. An
## area recorded `completeTime: 1700010905` and completed at server time
## 1700000105, three hours early.
##
## Both are now the same rule the rest of this server follows: resolve the whole
## requirement, verify every part of it, and only then take anything. There is
## no transaction to roll back here either.
##
## ## What a stage is allowed to refuse: everything it asks for
##
## A stage resolves through `resolveRequirements` in `emu/production` — the same
## resolver a craft uses, because a hideout stage and a recipe carry the same
## `requirements` shape and two copies of that arithmetic is two places for the
## next requirement type to be forgotten — and it applies the same rule to both:
## every requirement in full, or the upgrade is refused naming what is missing.
##
## That rule was briefly relaxed for stages, and it is worth writing down why,
## because the pressure that relaxed it was real and will come back.
##
## Against an imported `hideout.areas`, twenty-five of the twenty-eight areas
## ask for items at stage 1 — the workbench wants two bolts, two screw nuts and
## a multitool — and a new profile has a stash, 500,000 roubles and none of
## them. A server that refuses those upgrades is a server whose hideout a fresh
## profile cannot start building, and four checks in `tools/realtest.nim` failed
## on that one cause. The fix was to take stage materials *partially*: spend
## what the stash holds, report the shortfall as a warning, grant the level.
##
## That is the client being given a level it did not pay for, and it is the one
## rule this server does not bend anywhere else. The actual finding underneath
## it is about the **economy**, not about the rule: no trader in an imported
## database sells a bolt or a screw nut at any loyalty level, and the flea's
## generated pool is exhausted by trader stock before it reaches the handbook,
## so there is no shop anywhere in this server that has one. The route a player
## uses is the one the loot tables describe — every real map spawns both — and
## so `realtest` now buys what it can be sold, brings home what it cannot, and
## says precisely which templates were which. A test that cannot afford a
## hideout acquires the materials; it does not ask the server to lower the
## price.
##
## And an area cannot be upgraded past the last stage its own table describes.
## It could: `stageRequirements` answers "[]" for a stage that is not there and
## `upgradeSeconds` answers zero, so a workbench with three stages went to level
## 4, 5, 6 free and instant, and each of those levels satisfies any recipe's
## `Area` requirement. A database with no hideout table at all is still
## permissive, which is the case those two answers exist for.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import profile
import inventory
import production

type
  HideoutAction* = enum
    haNone, haUpgrade, haUpgradeComplete, haToggleArea, haPutItems, haTakeItems

proc hideoutAction*(name: string): HideoutAction =
  case name
  of "HideoutUpgrade": haUpgrade
  of "HideoutUpgradeComplete": haUpgradeComplete
  of "HideoutToggleArea": haToggleArea
  of "HideoutPutItemsInAreaSlots": haPutItems
  of "HideoutTakeItemsFromAreaSlots": haTakeItems
  else: haNone

proc findArea(list: List; areaType: int): int =
  result = -1
  for i in 0 ..< list.len:
    if field(list.items[i], "type").asInt(-1) == areaType:
      return i

proc newArea(areaType: int): Doc =
  result = newDoc()
  setNumber(result, "type", areaType)
  setNumber(result, "level", 0)
  setBool(result, "active", true)
  setBool(result, "passiveBonusesEnabled", true)
  setNumber(result, "completeTime", 0)
  setBool(result, "constructing", false)
  setRaw(result, "slots", "[]")
  setNumber(result, "lastRecipe", 0)

var gConstructionMultiplier = 1.0

proc configureHideoutTimes*(constructionMultiplier: float) =
  gConstructionMultiplier = constructionMultiplier

proc scaleHideoutTime*(seconds: int): int =
  ## A construction duration with the multiplier applied.
  ##
  ## Zero stays zero: `upgradeSeconds` already uses zero to mean "this database
  ## does not describe that stage", and multiplying that sentinel would turn a
  ## missing row into a wait.
  if seconds <= 0 or gConstructionMultiplier == 1.0:
    return seconds
  result = int(float(seconds) * gConstructionMultiplier + 0.5)
  if result < 0:
    result = 0

proc upgradeSeconds*(areaType, level: int): int =
  ## How long the next level takes, out of the database. Zero when it is not
  ## there -- an upgrade with no known duration completes immediately, which is
  ## a server with no data being permissive rather than a player being stuck.
  let areas = dbRead("hideout.areas")
  if not areas.ok:
    return 0
  let list = each(whole(areas.raw))
  for a in list:
    if a.field("type").asInt(-1) != areaType:
      continue
    let stages = a.field("stages." & $level)
    if stages.found:
      return scaleHideoutTime(stages.field("constructionTime").asInt(0))
  result = 0

proc stageRequirements*(areaType, level: int): string =
  ## A stage's `requirements` array as raw JSON, "[]" when the database has no
  ## stage for that level.
  ##
  ## "[]" is the honest answer to "this database does not describe that stage",
  ## and it is also the permissive one -- an upgrade the server has no
  ## requirements for goes through. That is the same choice `upgradeSeconds`
  ## makes, and for the same reason: a server started without a hideout table
  ## must not be a server where nothing can ever be built.
  let areas = dbRead("hideout.areas")
  if not areas.ok:
    return "[]"
  let list = each(whole(areas.raw))
  for a in list:
    if a.field("type").asInt(-1) != areaType:
      continue
    let stage = a.field("stages." & $level)
    if not stage.found:
      continue
    let reqs = stage.field("requirements")
    if reqs.found and isArray(reqs):
      return raw(reqs)
    return "[]"
  result = "[]"

proc knowsArea*(areaType: int): bool =
  ## Whether the database describes this area at all. The difference between
  ## "no hideout table" and "a hideout table that stops at level 3" -- the first
  ## has to stay permissive, the second must not.
  let areas = dbRead("hideout.areas")
  if not areas.ok:
    return false
  let list = each(whole(areas.raw))
  for a in list:
    if a.field("type").asInt(-1) == areaType:
      return true
  result = false

proc knowsStage*(areaType, level: int): bool =
  let areas = dbRead("hideout.areas")
  if not areas.ok:
    return false
  let list = each(whole(areas.raw))
  for a in list:
    if a.field("type").asInt(-1) != areaType:
      continue
    return a.field("stages." & $level).found
  result = false

proc areaGate*(areaType: int): string =
  ## The area's **own** `requirements` -- the list beside `stages`, not inside
  ## one -- as raw JSON, and "[]" when it does not apply.
  ##
  ## Real data only, and nothing read it until now. An imported `hideout.areas`
  ## carries `requirements` and `enableAreaRequirements` on every area; three of
  ## the twenty-eight set the flag, and all three name the same gate --
  ## `{"areaType":22,"requiredLevel":6,"type":"Area"}`, the emergency wall at
  ## level 6. So the Place of Fame, the Gym and the Cultist Circle could each be
  ## built by a player who had never touched the wall, because this list is a
  ## *sibling* of `stages` and the stage requirements do not repeat it.
  ##
  ## The flag is honoured rather than ignored: an area with `requirements` and
  ## `enableAreaRequirements: false` has a list the game does not apply -- three
  ## areas in the fixture-free real table have exactly that shape and the client
  ## builds them regardless.
  let areas = dbRead("hideout.areas")
  if not areas.ok:
    return "[]"
  let list = each(whole(areas.raw))
  for a in list:
    if a.field("type").asInt(-1) != areaType:
      continue
    if not a.field("enableAreaRequirements").asBool(false):
      return "[]"
    let reqs = a.field("requirements")
    if reqs.found and isArray(reqs):
      return raw(reqs)
    return "[]"
  result = "[]"

proc emptyArray(s: string): bool =
  ## An array with nothing in it, however it was printed. `[]` and `[\n]` are
  ## the same array, and a pretty-printed import produces the second -- pasting
  ## a comma into one of those makes JSON the resolver reads as no requirements
  ## at all, which is the failure mode this exists to rule out.
  var i = 0
  while i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or
                       s[i] == '\r'):
    inc i
  if i >= s.len or s[i] != '[':
    return true
  inc i
  while i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or
                       s[i] == '\r'):
    inc i
  result = i >= s.len or s[i] == ']'

proc mergedRequirements*(a, b: string): string =
  ## Two requirement arrays as one, without parsing either. Both are raw JSON
  ## arrays out of the database and neither is inspected here -- the resolver is
  ## the only thing that needs to know what is in them.
  if emptyArray(a):
    return (if emptyArray(b): "[]" else: b)
  if emptyArray(b):
    return a
  var cut = a.len - 1
  while cut > 0 and a[cut] != ']':
    dec cut
  var from1 = 0
  while from1 < b.len and b[from1] != '[':
    inc from1
  result = a.substr(0, cut - 1) & "," & b.substr(from1 + 1, b.len - 1)

proc applyHideout*(areasJson: string; action: HideoutAction; body: JsonRef;
                   nowSeconds: int; problem: var string): string =
  ## Returns the new `Hideout.Areas` array.
  problem = ""
  var list = parseArray(areasJson)
  if not list.ok:
    list = newList()
  let areaType = body.field("areaType").asInt(-1)
  if areaType < 0:
    problem = "that hideout action names no area"
    return areasJson

  var at = findArea(list, areaType)
  if at < 0:
    list.add newArea(areaType)
    at = list.len - 1

  var d = parseObject(list.items[at])
  case action
  of haUpgrade:
    if get(d, "constructing").asBool(false):
      # A second start of an upgrade already running. Harmless while upgrades
      # were free; now that a start takes the stage materials, letting it
      # through charges for the same upgrade twice and resets its clock.
      problem = "that area is already being upgraded"
      return areasJson
    let level = get(d, "level").asInt(0)
    let seconds = upgradeSeconds(areaType, level + 1)
    setBool(d, "constructing", true)
    setNumber(d, "completeTime", nowSeconds + seconds)
  of haUpgradeComplete:
    if not get(d, "constructing").asBool(false):
      # Refused rather than granted. A complete without a start is either a
      # replayed request or a client out of step, and granting it is a free
      # level either way.
      problem = "that area is not being upgraded"
      return areasJson
    let due = get(d, "completeTime").asInt(0)
    if due > nowSeconds:
      # The timer was written and never read, so every upgrade finished on the
      # request after the one that started it. An area with no known duration
      # still completes at once -- `upgradeSeconds` returns zero for one, which
      # makes `completeTime` the moment it started -- so a server with no
      # hideout table behaves exactly as it did.
      problem = "that area is still under construction for another " &
                $(due - nowSeconds) & " second(s)"
      return areasJson
    setNumber(d, "level", get(d, "level").asInt(0) + 1)
    setBool(d, "constructing", false)
    setNumber(d, "completeTime", 0)
  of haToggleArea:
    setBool(d, "active", body.field("enabled").asBool(true))
  of haPutItems, haTakeItems:
    # The items themselves move through the ordinary inventory actions the
    # client sends alongside; what changes here is only which slots are filled.
    let slots = body.field("items")
    if slots.found:
      setRaw(d, "slots", raw(slots))
  of haNone:
    problem = "not a hideout action"
    return areasJson
  list.replaceAt(at, text(d))
  result = text(list)


# ---------------------------------------------------------------------------
# The entry point that has a profile
# ---------------------------------------------------------------------------

proc applyHideoutOnProfile*(p: var Profile; inv: var Inventory;
                            action: HideoutAction; body: JsonRef;
                            nowSeconds: int; ch: var Change): bool =
  ## One hideout action against the whole profile. Returns whether the profile
  ## changed.
  ##
  ## The array-only `applyHideout` above cannot do this: an upgrade needs items
  ## out of the stash, a level in another area and a loyalty level with a
  ## trader, and none of those is in `Hideout.Areas`. Resolving them is
  ## `resolveRequirements` in `emu/production` -- the same resolver a craft
  ## uses, called the same way, with the profile passed so that the
  ## `TraderLoyalty`, `Skill` and `QuestComplete` gates are evaluated rather
  ## than permitted.
  ##
  ## Order: resolve, then apply, then take. The resolve touches nothing, the
  ## apply can still refuse, and only when both have succeeded is anything
  ## removed from the stash. Anything else can leave a player charged for an
  ## upgrade that did not start.
  var problem = ""
  let areasJson = p.field("Hideout.Areas").raw()
  var plan: seq[int] = @[]
  var amounts: seq[int] = @[]
  var resTpls: seq[string] = @[]
  var resNeeds: seq[float] = @[]
  if action == haUpgrade:
    let areaType = body.field("areaType").asInt(-1)
    if areaType < 0:
      ch.problems.add "upgrade: that hideout action names no area"
      return false
    let next = areaLevel(areasJson, areaType) + 1
    if knowsArea(areaType) and not knowsStage(areaType, next):
      # The database describes this area and stops before this level. Without
      # this an area runs off the end of its own table -- `stageRequirements`
      # answers "[]" for a stage that is not there and `upgradeSeconds` answers
      # zero, so every level past the last one the game has is free and instant,
      # for ever, and each of them satisfies any recipe's `Area` requirement.
      ch.problems.add "upgrade: that area has no level " & $next
      return false
    let reqs = mergedRequirements(stageRequirements(areaType, next),
                                  areaGate(areaType))
    if not resolveRequirements("{\"sptResourceArea\":" & $areaType &
                               ",\"requirements\":" & reqs & "}", areasJson,
                               inv, p.stashId, plan, amounts, resTpls, resNeeds,
                               problem, p.text):
      ch.problems.add "upgrade: " & problem
      return false

  let updated = applyHideout(areasJson, action, body, nowSeconds, problem)
  if problem.len > 0:
    ch.problems.add problem
    return false
  if plan.len > 0:
    consume(inv, plan, amounts, ch)
  # A stage with a `Resource` requirement is paid for out of the area's own
  # slots. No imported area has one -- only a recipe does -- so this take has so
  # far never had anything to take; it is here because the resolver this shares
  # with a craft can produce one and a verified requirement that is never spent
  # is the free-hideout bug in miniature. Applied to the array `applyHideout`
  # returned rather than to the one that went in, so it is not overwritten.
  var finalAreas = updated
  for k in 0 ..< resTpls.len:
    var drawn = false
    let after = drawFromSlots(finalAreas, body.field("areaType").asInt(-1),
                              resTpls[k], resNeeds[k], drawn)
    if drawn:
      finalAreas = after
  setRaw(p, "Hideout.Areas", finalAreas)
  result = true
