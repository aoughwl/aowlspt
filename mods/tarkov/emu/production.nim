## Hideout production: materials in, something else out, some hours later.
##
## `emu/hideout.nim` owns what the player has *built*; this owns what those
## buildings are *doing*. The two are separate on purpose — an upgrade is a
## level on an area and a craft is an entry in `Hideout.Production` keyed by
## recipe id, and the only thing they share is that a craft asks the area what
## level it reached before it will start.
##
## Three rules run through the whole file, and each of them is a duplication or
## a theft bug if it is broken:
##
## **Check everything, then take.** Starting a craft consumes inputs out of the
## stash, and there is no transaction to roll back. So the requirements are
## resolved to a list of (stack, amount) pairs, every one of them verified, and
## only then is anything removed — the same shape as `takePayment` in
## `emu/trading.nim`, for the same reason.
##
## **Collecting is destructive to the record, not just to the clock.** A craft
## that can be collected twice is free items. So the entry is removed (or its
## progress is spent down, for a continuous one) in the same step that puts the
## output in the stash, and only if the output actually landed — a full stash
## refuses the collection rather than eating the craft.
##
## **Time is derived, not counted.** A one-shot craft's progress is
## `now - StartTimestamp`, clamped to its duration: nothing accumulates, so a
## server that was switched off for a week comes back with the craft finished
## exactly once, and a server that was running the whole time agrees with it.
## Continuous production cannot be derived that way, because it only runs while
## the generator does, so it accumulates — but it accumulates against a window
## that the *fuel* pays for, which is itself derived from what is in the tank.
## Neither direction fabricates: elapsed time the generator could not have
## covered is not credited, and time it did cover is not lost.
##
## Everything here works against an empty database. No `hideout.production`
## means no recipes, which means `HideoutSingleProductionStart` is refused with
## "no such recipe" and nothing else in the hideout stops working.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import ids
import profile
import inventory
import trading

const
  GeneratorArea* = 4
    ## The generator's area type in the client's own numbering. Named because
    ## the fuel burn is the one place production has to know about a *specific*
    ## area rather than whatever the recipe points at.

  DefaultFuelFlowRate* = 0.0013888
    ## Resource units per second, when the database's `hideout.settings` has no
    ## `generatorFuelFlowRate`. One unit per 720 seconds — a 100-unit fuel can
    ## lasts twenty hours, which is the live game's order of magnitude. A wrong
    ## rate here burns a player's fuel at the wrong speed; a *zero* rate would
    ## make fuel infinite, so the fallback is deliberately non-zero.

type
  ProductionAction* = enum
    paNone, paStart, paTake

proc productionAction*(name: string): ProductionAction =
  ## The client sends three different start actions and one take. They differ in
  ## which recipe table they mean, not in what the server does, so they collapse
  ## to one — with scav case excluded, because its recipes live in a different
  ## table this does not read and answering it out of the craft table would
  ## produce the wrong item.
  case name
  of "HideoutSingleProductionStart": paStart
  of "HideoutContinuousProductionStart": paStart
  of "HideoutTakeProduction": paTake
  else: paNone

# ---------------------------------------------------------------------------
# Recipes, out of the database
# ---------------------------------------------------------------------------

proc recipesJson*(): string =
  ## `hideout.production`, normalised to an array.
  ##
  ## Databases disagree about the shape: older dumps are a bare array of
  ## recipes, newer ones an object with `recipes` beside `scavRecipes` and the
  ## rest. Both are accepted here rather than in three call sites, and anything
  ## else is "no recipes" — which is the same answer as no database at all, and
  ## is a server where crafting is refused instead of one that crashes.
  let v = dbRead("hideout.production")
  if not v.ok or v.raw.len == 0:
    return "[]"
  let j = whole(v.raw)
  if isArray(j):
    return v.raw
  let inner = j.field("recipes")
  if inner.found and isArray(inner):
    return raw(inner)
  result = "[]"

proc recipeById*(recipesJson, recipeId: string): string =
  ## One recipe as raw JSON, or empty. Pure: the self-check feeds it a fixture
  ## rather than needing a loaded database.
  if recipeId.len == 0:
    return ""
  let list = each(whole(recipesJson))
  for r in list:
    if r.field("_id").asText("") == recipeId:
      return raw(r)
  result = ""

proc recipe*(recipeId: string): string = recipeById(recipesJson(), recipeId)

proc areaTable*(): string =
  ## `hideout.areas`, which is where the *bonuses* a level grants are written.
  ## Empty when the database has none, and then an upgraded area grants nothing
  ## -- which is the emulator's standing rule: content comes from the database,
  ## state from the profile, and a server with neither still runs.
  let v = dbRead("hideout.areas")
  if v.ok and v.raw.len > 0 and isArray(whole(v.raw)):
    return v.raw
  result = "[]"

proc fuelFlowRate*(): float =
  ## Out of `hideout.settings`, then config, then the constant above. Config
  ## sits in the middle so a server owner can slow fuel down without editing a
  ## database dump, and above nothing so an unconfigured server still burns.
  let v = dbRead("hideout.settings.generatorFuelFlowRate")
  if v.ok and v.raw.len > 0:
    let r = asFloat(v, 0.0)
    if r > 0.0:
      return r
  let c = setting("generatorFuelFlowRate")
  if c.ok:
    let r = asFloat(c, 0.0)
    if r > 0.0:
      return r
  result = DefaultFuelFlowRate

# ---------------------------------------------------------------------------
# Areas, read-only
# ---------------------------------------------------------------------------
#
# `emu/hideout.nim` writes the area array; this only ever reads it. Duplicating
# the two-line lookup rather than exporting a getter from there keeps the two
# modules independent — production is a strictly downstream reader, and the day
# the area array grows a field, only the writer has to care.

proc areaEntry*(areasJson: string; areaType: int): JsonRef =
  result = notFound()
  let list = each(whole(areasJson))
  for a in list:
    if a.field("type").asInt(-1) == areaType:
      return a

proc areaLevel*(areasJson: string; areaType: int): int =
  let a = areaEntry(areasJson, areaType)
  if not a.found:
    return 0
  result = a.field("level").asInt(0)

proc areaActive*(areasJson: string; areaType: int): bool =
  ## An area the profile has never heard of is *not* running. Defaulting to
  ## true here would have a hideout with no generator entry burning no fuel and
  ## producing water anyway.
  let a = areaEntry(areasJson, areaType)
  if not a.found:
    return false
  result = a.field("active").asBool(true) and a.field("level").asInt(0) > 0

# ---------------------------------------------------------------------------
# Stacks
# ---------------------------------------------------------------------------

proc stackOf(inv: Inventory; index: int): int =
  let d = itemAt(inv, index)
  let upd = get(d, "upd")
  if not upd.found:
    return 1
  result = upd.field("StackObjectsCount").asInt(1)

proc setStack(inv: var Inventory; index, count: int) =
  var d = itemAt(inv, index)
  var upd = parseObject(getRaw(d, "upd"))
  if not upd.ok:
    upd = newDoc()
  setNumber(upd, "StackObjectsCount", count)
  setRaw(d, "upd", text(upd))
  inv.items.replaceAt(index, text(d))

proc availableOf*(inv: Inventory; tpl, stashId: string): int =
  ## How many of a template are lying loose in the stash.
  ##
  ## Loose, and that word is doing work: only items whose `parentId` is the
  ## stash itself count. Without that restriction a craft needing five 5.45
  ## rounds would happily strip the magazine out of the rifle in the player's
  ## container, which is technically "in the stash" and is not what anyone
  ## means by having five rounds spare.
  result = 0
  for i in 0 ..< inv.items.len:
    let it = whole(inv.items.items[i])
    if it.field("_tpl").asText("") != tpl:
      continue
    if it.field("parentId").asText("") != stashId:
      continue
    result = result + stackOf(inv, i)

proc consume(inv: var Inventory; plan: seq[int]; amounts: seq[int];
             ch: var Change) =
  ## Applies a plan built by `takeInputs`. Stacks that go to zero are removed
  ## after the loop, by id: removing inside it shifts every index still to use.
  var spent: seq[string] = @[]
  for k in 0 ..< plan.len:
    let at = plan[k]
    let left = stackOf(inv, at) - amounts[k]
    if left > 0:
      setStack(inv, at, left)
      ch.changed.add inv.items.items[at]
    else:
      spent.add field(inv.items.items[at], "_id").asText("")
  for id in spent:
    let at = indexOf(inv, id)
    if at >= 0:
      inv.items.removeAt(at)
      ch.deleted.add id
  inv.dirty = true

# ---------------------------------------------------------------------------
# Requirements
# ---------------------------------------------------------------------------

proc checkRequirements*(recipeJson, areasJson: string; inv: Inventory;
                        stashId: string; plan: var seq[int];
                        amounts: var seq[int]; problem: var string): bool =
  ## Resolves a recipe's requirements against the profile without touching
  ## anything. On success `plan`/`amounts` say exactly which stacks to take how
  ## much from; on failure `problem` says why and nothing has moved.
  ##
  ## Four requirement types are understood. `Area` gates on a built level,
  ## `Item` is consumed, `Tool` must be present and is given back untouched
  ## (a craft does not eat the wrench). Everything else — trader loyalty, quest
  ## completion, game edition — is *permitted*, not silently failed: this
  ## emulator does not model a player's trader standing well enough to refuse a
  ## craft over it, and refusing on data it cannot evaluate would lock recipes
  ## the player has legitimately unlocked.
  plan = @[]
  amounts = @[]
  problem = ""
  if recipeJson.len == 0:
    problem = "no such recipe"
    return false

  # The recipe's own area gate, which is separate from any `Area` requirement:
  # every recipe names the area it is crafted in.
  let homeArea = field(recipeJson, "areaType").asInt(-1)
  if homeArea >= 0 and areaLevel(areasJson, homeArea) < 1:
    problem = "that area is not built yet"
    return false

  # Wanted per template first, then resolved to stacks. Two `Item` entries for
  # the same template in one recipe would otherwise each be checked against the
  # full stash and both pass, and the second take would come up short.
  var tpls: seq[string] = @[]
  var wants: seq[int] = @[]
  let reqs = each(field(recipeJson, "requirements"))
  for r in reqs:
    let kind = r.field("type").asText("")
    case kind
    of "Area":
      let at = r.field("areaType").asInt(-1)
      let need = r.field("requiredLevel").asInt(1)
      if at >= 0 and areaLevel(areasJson, at) < need:
        problem = "that recipe needs area " & $at & " at level " & $need
        return false
    of "Tool":
      let tpl = r.field("templateId").asText("")
      if tpl.len > 0 and availableOf(inv, tpl, stashId) < 1:
        problem = "that recipe needs a tool you do not have: " & tpl
        return false
    of "Item":
      let tpl = r.field("templateId").asText("")
      var n = r.field("count").asInt(1)
      if n < 1: n = 1
      if tpl.len == 0:
        problem = "that recipe asks for an item with no template"
        return false
      var at = -1
      for k in 0 ..< tpls.len:
        if tpls[k] == tpl:
          at = k
      if at < 0:
        tpls.add tpl
        wants.add n
      else:
        wants[at] = wants[at] + n
    else:
      discard

  for k in 0 ..< tpls.len:
    var left = wants[k]
    for i in 0 ..< inv.items.len:
      if left <= 0:
        break
      let it = whole(inv.items.items[i])
      if it.field("_tpl").asText("") != tpls[k]:
        continue
      if it.field("parentId").asText("") != stashId:
        continue
      let have = stackOf(inv, i)
      if have <= 0:
        continue
      let take = if have < left: have else: left
      plan.add i
      amounts.add take
      left = left - take
    if left > 0:
      problem = "not enough " & tpls[k] & " for that recipe"
      plan = @[]
      amounts = @[]
      return false
  result = true

# ---------------------------------------------------------------------------
# The production record
# ---------------------------------------------------------------------------

proc newProduction(recipeJson: string; nowSeconds: int): Doc =
  result = newDoc()
  setText(result, "RecipeId", field(recipeJson, "_id").asText(""))
  setNumber(result, "Progress", 0)
  setBool(result, "inProgress", true)
  setNumber(result, "StartTimestamp", nowSeconds)
  setNumber(result, "ProductionTime", field(recipeJson, "productionTime").asInt(0))
  setRaw(result, "Products", "[]")
  setNumber(result, "SkipTime", 0)
  setBool(result, "sptIsComplete", false)
  # Copied onto the record rather than looked up again at collection time. The
  # database can be replaced under a running profile -- a mod adding recipes, an
  # SPT update -- and a craft must finish on the terms it was started on, not on
  # whatever the table says an hour later.
  setBool(result, "continuous", field(recipeJson, "continuous").asBool(false))
  setNumber(result, "sptLimit", field(recipeJson, "productionLimitCount").asInt(0))
  setNumber(result, "sptCount", field(recipeJson, "count").asInt(1))
  setText(result, "sptProduct", field(recipeJson, "endProduct").asText(""))
  setNumber(result, "sptLastTick", nowSeconds)

proc unitsReady*(entryJson: string; nowSeconds: int): int =
  ## How many finished units this record is holding, right now.
  ##
  ## For a one-shot craft that is 0 or 1 and is derived from the clock, so it is
  ## the same answer whether or not the server was running. For a continuous one
  ## it comes off accumulated `Progress`, which the tick maintains, and is
  ## capped by the recipe's own limit -- an uncollected water collector fills up
  ## and stops rather than banking a year of bottles.
  let d = whole(entryJson)
  let duration = d.field("ProductionTime").asInt(0)
  if duration <= 0:
    # A recipe with no duration finishes at once. Permissive by the same
    # argument as `upgradeSeconds` returning zero: a database that does not say
    # how long something takes must not leave the player stuck on it forever.
    return 1
  if d.field("continuous").asBool(false):
    var limit = d.field("sptLimit").asInt(0)
    if limit < 1: limit = 1
    var n = d.field("Progress").asInt(0) div duration
    if n > limit: n = limit
    return n
  let start = d.field("StartTimestamp").asInt(nowSeconds)
  if nowSeconds - start >= duration:
    return 1
  result = 0

proc startProduction*(recipeJson, areasJson, productionJson: string;
                      inv: var Inventory; stashId: string; nowSeconds: int;
                      ch: var Change; problem: var string): string =
  ## Returns the new `Hideout.Production` object. Unchanged, with `problem` set,
  ## on any refusal — and in that case the inventory has not been touched.
  problem = ""
  var prods = parseObject(productionJson)
  if not prods.ok:
    prods = newDoc()
  let recipeId = field(recipeJson, "_id").asText("")
  if recipeId.len == 0:
    problem = "no such recipe"
    return productionJson
  if has(prods, recipeId):
    # Restarting a running craft would reset its clock and take a second set of
    # inputs for one output. The client does not send this; a replayed request
    # does.
    problem = "that recipe is already running"
    return productionJson

  var plan: seq[int] = @[]
  var amounts: seq[int] = @[]
  if not checkRequirements(recipeJson, areasJson, inv, stashId, plan, amounts,
                           problem):
    ch.problems.add problem
    return productionJson

  consume(inv, plan, amounts, ch)
  setRaw(prods, recipeId, text(newProduction(recipeJson, nowSeconds)))
  result = text(prods)

proc takeProduction*(productionJson: string; recipeId: string;
                     inv: var Inventory; stashId: string; nowSeconds: int;
                     ch: var Change; problem: var string): string =
  ## Collects a finished craft. The output lands in a real free cell or the
  ## collection is refused — refused rather than half-done, because clearing the
  ## record and failing to place the item is the craft evaporating.
  problem = ""
  var prods = parseObject(productionJson)
  if not prods.ok:
    problem = "this profile has no production record"
    return productionJson
  if not has(prods, recipeId):
    problem = "nothing is being made from " & recipeId
    return productionJson

  let entry = getRaw(prods, recipeId)
  let ready = unitsReady(entry, nowSeconds)
  if ready < 1:
    problem = "that production is not finished"
    return productionJson

  let d = whole(entry)
  let tpl = d.field("sptProduct").asText("")
  if tpl.len == 0:
    problem = "that recipe makes nothing this server knows about"
    return productionJson
  var per = d.field("sptCount").asInt(1)
  if per < 1: per = 1

  if not giveItem(inv, tpl, stashId, per * ready, ch):
    # `giveItem` has already put the reason in `ch.problems`. The record is
    # left exactly as it was, so the player can clear space and collect again.
    problem = "there is no room in the stash for that"
    return productionJson

  if d.field("continuous").asBool(false):
    # Spent down, not cleared: a continuous line keeps running, and the
    # remainder is the part of the current unit that is genuinely in progress.
    var e = parseObject(entry)
    let duration = d.field("ProductionTime").asInt(1)
    setNumber(e, "Progress", d.field("Progress").asInt(0) - ready * duration)
    setBool(e, "sptIsComplete", false)
    setBool(e, "inProgress", true)
    setNumber(e, "sptLastTick", nowSeconds)
    setRaw(prods, recipeId, text(e))
  else:
    remove(prods, recipeId)
  result = text(prods)

# ---------------------------------------------------------------------------
# The tick
# ---------------------------------------------------------------------------

proc resourceOf(itemJson: string): float =
  let r = field(itemJson, "upd.Resource.Value")
  if not r.found:
    return 0.0
  result = asFloat(r, 0.0)

proc withResource(itemJson: string; value: float): string =
  var d = parseObject(itemJson)
  if not d.ok:
    return itemJson
  var upd = parseObject(getRaw(d, "upd"))
  if not upd.ok:
    upd = newDoc()
  var res = parseObject(getRaw(upd, "Resource"))
  if not res.ok:
    res = newDoc()
  setNumber(res, "Value", value)
  setRaw(upd, "Resource", text(res))
  setRaw(d, "upd", text(upd))
  result = text(d)

proc slotItem(slotJson: string): string =
  ## A slot is `{"item":[{...}],"locationIndex":n}` in the client's own shape,
  ## but an area written by an older emulator holds the item directly. Both are
  ## read; only the shape that was there is written back.
  let inner = field(slotJson, "item")
  if inner.found and isArray(inner):
    let first = at(inner, 0)
    if first.found:
      return raw(first)
    return ""
  if isObject(whole(slotJson)):
    return slotJson
  result = ""

proc withSlotItem(slotJson, itemJson: string): string =
  let inner = field(slotJson, "item")
  if inner.found and isArray(inner):
    var d = parseObject(slotJson)
    var lst = parseArray(getRaw(d, "item"))
    if not lst.ok:
      lst = newList()
    if lst.len == 0:
      lst.add itemJson
    else:
      lst.replaceAt(0, itemJson)
    setRaw(d, "item", text(lst))
    return text(d)
  result = itemJson

proc burnFuel*(areasJson: string; elapsed: int; rate: float;
               poweredSeconds: var int; changed: var bool): string =
  ## Burns `elapsed` seconds of fuel out of the generator's slots and reports
  ## how many of those seconds the tank could actually pay for.
  ##
  ## That number is the point of this proc. It is what stops a hideout that ran
  ## dry on Tuesday from being credited with Wednesday's water — and equally,
  ## what stops a server that was switched off from pretending no time passed.
  ## The fuel is the ledger; the wall clock alone is not evidence of anything.
  poweredSeconds = 0
  changed = false
  if elapsed <= 0 or rate <= 0.0:
    return areasJson
  if not areaActive(areasJson, GeneratorArea):
    return areasJson

  var list = parseArray(areasJson)
  if not list.ok:
    return areasJson
  var at = -1
  for i in 0 ..< list.len:
    if field(list.items[i], "type").asInt(-1) == GeneratorArea:
      at = i
  if at < 0:
    return areasJson

  var area = parseObject(list.items[at])
  var slots = parseArray(getRaw(area, "slots"))
  if not slots.ok:
    slots = newList()

  var need = float(elapsed) * rate
  var burned = 0.0
  var touched = false
  for i in 0 ..< slots.len:
    if need <= 0.0:
      break
    let itemJson = slotItem(slots.items[i])
    if itemJson.len == 0:
      continue
    let have = resourceOf(itemJson)
    if have <= 0.0:
      continue
    let take = if have < need: have else: need
    need = need - take
    burned = burned + take
    touched = true
    slots.replaceAt(i, withSlotItem(slots.items[i],
                                    withResource(itemJson, have - take)))

  if not touched:
    # Nothing in the tank at all. The generator is switched off rather than left
    # showing as running: a generator that draws nothing and powers nothing is a
    # UI lie, and the player needs to see it to know to refuel.
    if areaActive(areasJson, GeneratorArea):
      setBool(area, "active", false)
      list.replaceAt(at, text(area))
      changed = true
      return text(list)
    return areasJson

  poweredSeconds = int(burned / rate)
  if poweredSeconds > elapsed:
    poweredSeconds = elapsed
  setRaw(area, "slots", text(slots))
  if need > 0.0:
    setBool(area, "active", false)
  list.replaceAt(at, text(area))
  changed = true
  result = text(list)

proc tickProductions*(productionJson: string; elapsed, poweredSeconds,
                      nowSeconds: int; changed: var bool): string =
  ## Brings every record up to date with the clock.
  ##
  ## One-shot crafts are *recomputed*, not advanced: their progress is a
  ## function of `StartTimestamp` and now, so running this twice, or not at all
  ## for a week, gives the same answer. Continuous ones are advanced by the
  ## powered window, because there is no timestamp that could tell you after the
  ## fact how long the generator was on.
  changed = false
  var prods = parseObject(productionJson)
  if not prods.ok:
    return productionJson
  for i in 0 ..< prods.fields.len:
    let entry = prods.fields[i].value
    let d = whole(entry)
    let duration = d.field("ProductionTime").asInt(0)
    var e = parseObject(entry)
    if not e.ok:
      continue
    if d.field("continuous").asBool(false):
      var limit = d.field("sptLimit").asInt(0)
      if limit < 1: limit = 1
      let cap = duration * limit
      var progress = d.field("Progress").asInt(0) + poweredSeconds
      if duration > 0 and progress > cap:
        progress = cap
      if progress != d.field("Progress").asInt(0) or
         d.field("sptLastTick").asInt(0) != nowSeconds:
        setNumber(e, "Progress", progress)
        setNumber(e, "sptLastTick", nowSeconds)
        setBool(e, "sptIsComplete", duration > 0 and progress >= duration)
        prods.fields[i].value = text(e)
        changed = true
    else:
      let start = d.field("StartTimestamp").asInt(nowSeconds)
      var progress = nowSeconds - start
      if progress < 0: progress = 0
      if duration > 0 and progress > duration: progress = duration
      let complete = duration <= 0 or progress >= duration
      if progress != d.field("Progress").asInt(-1) or
         complete != d.field("sptIsComplete").asBool(false):
        setNumber(e, "Progress", progress)
        setBool(e, "sptIsComplete", complete)
        setBool(e, "inProgress", not complete)
        prods.fields[i].value = text(e)
        changed = true
  if not changed:
    return productionJson
  discard elapsed
  result = text(prods)

# ---------------------------------------------------------------------------
# Area bonuses
# ---------------------------------------------------------------------------

proc bonusesForStage(areaTableJson: string; areaType, level: int): seq[string] =
  ## The bonuses one built stage grants, as raw JSON objects out of the
  ## database's own `hideout.areas`.
  result = @[]
  let areas = each(whole(areaTableJson))
  for a in areas:
    if a.field("type").asInt(-1) != areaType:
      continue
    let stage = a.field("stages." & $level)
    if not stage.found:
      return
    let list = each(stage.field("bonuses"))
    for b in list:
      result.add raw(b)

proc syncBonuses*(bonusesJson, areaTableJson, areasJson: string;
                  changed: var bool): string =
  ## Rebuilds the hideout-derived half of the profile's `Bonuses`.
  ##
  ## Rebuilt from the levels rather than appended to on upgrade, and that is the
  ## robust choice: a profile that was edited by hand, upgraded on a server
  ## running an older database, or restored from a backup half a level behind
  ## converges to the right set the next time it is loaded. Appending only ever
  ## converges if every upgrade in history went through this code.
  ##
  ## Entries this module did not create are kept untouched — a bonus a *mod*
  ## granted is not the hideout's to delete — and are recognised by the absence
  ## of `sptArea`. Existing ids are reused so the client is not told that every
  ## bonus it already knows about has been replaced.
  changed = false
  var out1 = newList()
  var kept = 0
  let old = parseArray(bonusesJson)
  if old.ok:
    for i in 0 ..< old.len:
      if not field(old.items[i], "sptArea").found:
        out1.add old.items[i]
        inc kept

  let areas = each(whole(areasJson))
  for a in areas:
    let areaType = a.field("type").asInt(-1)
    let level = a.field("level").asInt(0)
    if areaType < 0 or level < 1:
      continue
    var stage = 1
    while stage <= level:
      let raws = bonusesForStage(areaTableJson, areaType, stage)
      for k in 0 ..< raws.len:
        var b = parseObject(raws[k])
        if not b.ok:
          continue
        setNumber(b, "sptArea", areaType)
        setNumber(b, "sptStage", stage)
        setNumber(b, "sptIndex", k)
        # Reuse the id this bonus already had, so a client holding the old
        # profile sees the same bonus rather than one leaving and one arriving.
        var id = ""
        if old.ok:
          for i in 0 ..< old.len:
            let o = whole(old.items[i])
            if o.field("sptArea").asInt(-1) == areaType and
               o.field("sptStage").asInt(-1) == stage and
               o.field("sptIndex").asInt(-1) == k:
              id = o.field("id").asText("")
        if id.len == 0:
          id = newId()
        setText(b, "id", id)
        out1.add text(b)
      inc stage

  let rebuilt = text(out1)
  if rebuilt != bonusesJson:
    changed = true
  result = rebuilt

# ---------------------------------------------------------------------------
# The profile-level entry points
# ---------------------------------------------------------------------------

proc applyProduction*(p: var Profile; inv: var Inventory;
                      action: ProductionAction; body: JsonRef;
                      nowSeconds: int; ch: var Change): bool =
  ## One production action off the item-moving endpoint. Returns whether the
  ## profile was changed; problems are already in `ch`.
  let recipeId = body.field("recipeId").asText("")
  if recipeId.len == 0:
    ch.problems.add "that production action names no recipe"
    return false
  let areasJson = p.field("Hideout.Areas").raw()
  let prodJson = p.field("Hideout.Production").raw()
  var problem = ""
  case action
  of paStart:
    let r = recipe(recipeId)
    if r.len == 0:
      ch.problems.add "no such recipe: " & recipeId
      return false
    let updated = startProduction(r, areasJson, prodJson, inv, p.stashId,
                                  nowSeconds, ch, problem)
    if problem.len > 0:
      return false
    setRaw(p, "Hideout.Production", updated)
    result = true
  of paTake:
    let updated = takeProduction(prodJson, recipeId, inv, p.stashId,
                                 nowSeconds, ch, problem)
    if problem.len > 0:
      ch.problems.add problem
      return false
    setRaw(p, "Hideout.Production", updated)
    result = true
  of paNone:
    ch.problems.add "not a production action"
    result = false

proc tickHideout*(p: var Profile; nowSeconds: int): bool =
  ## Catches a profile up on everything that happened while nobody was looking.
  ##
  ## Driven off `Hideout.sptUpdateLastRunTimestamp` on the profile rather than
  ## off a timer, so it is correct on a server that has been switched off for a
  ## week and on one that has been running the whole time — and so it costs
  ## nothing on a profile nobody is playing. Returns whether the profile needs
  ## saving.
  if not p.ok:
    return false
  let last = p.field("Hideout.sptUpdateLastRunTimestamp").asInt(nowSeconds)
  var elapsed = nowSeconds - last
  if elapsed < 0:
    # The clock went backwards -- a restored backup, or `epochBase` changed
    # under a live profile. Treated as no time passing rather than as negative
    # time, which would refund fuel and un-finish crafts.
    elapsed = 0

  var areasJson = p.field("Hideout.Areas").raw()
  var powered = 0
  var fuelChanged = false
  let newAreas = burnFuel(areasJson, elapsed, fuelFlowRate(), powered,
                          fuelChanged)
  if fuelChanged:
    areasJson = newAreas
    setRaw(p, "Hideout.Areas", newAreas)

  var prodChanged = false
  let newProds = tickProductions(p.field("Hideout.Production").raw(), elapsed,
                                 powered, nowSeconds, prodChanged)
  if prodChanged:
    setRaw(p, "Hideout.Production", newProds)

  var bonusChanged = false
  let newBonuses = syncBonuses(p.field("Bonuses").raw(),
                               areaTable(), areasJson, bonusChanged)
  if bonusChanged:
    setRaw(p, "Bonuses", newBonuses)

  # The stamp only moves when something moved with it. A profile with an idle
  # hideout is then read without being written, which matters because this runs
  # on the way into every request -- and leaving the stamp behind costs nothing:
  # the next tick that does have work to do gets the whole accumulated window,
  # and fuel is what bounds it rather than the wall clock.
  result = fuelChanged or prodChanged or bonusChanged
  if result:
    setNumber(p, "Hideout.sptUpdateLastRunTimestamp", nowSeconds)

# ---------------------------------------------------------------------------
# Self-check
# ---------------------------------------------------------------------------

proc selfCheckProduction*(failures: var seq[string]): bool =
  ## Exercises the parts that are pure over JSON text, against a fixture that
  ## looks like `tests/fixtures/emu-hideout.json` — no database, no host, no
  ## profile store. The duplication bug this file exists to prevent is checked
  ## explicitly: collect twice, and the second one must refuse.
  let before = failures.len
  const recipes = """[
    {"_id":"r1","areaType":3,"productionTime":100,"endProduct":"tplOut",
     "count":2,"continuous":false,
     "requirements":[{"type":"Area","areaType":3,"requiredLevel":1},
                     {"type":"Item","templateId":"tplIn","count":3},
                     {"type":"Tool","templateId":"tplTool"}]},
    {"_id":"water","areaType":6,"productionTime":100,"endProduct":"tplWater",
     "count":1,"continuous":true,"productionLimitCount":2,"requirements":[]}]"""
  const areas = """[{"type":3,"level":1,"active":true},
                    {"type":6,"level":1,"active":true},
                    {"type":4,"level":1,"active":true,
                     "slots":[{"locationIndex":0,
                       "item":[{"_id":"fuel","_tpl":"tplFuel",
                                "upd":{"Resource":{"Value":1.0}}}]}]}]"""
  const stash = "stash1"
  const items = """[{"_id":"stash1","_tpl":"tplStash"},
    {"_id":"i1","_tpl":"tplIn","parentId":"stash1","slotId":"hideout",
     "location":{"x":0,"y":0,"r":"Horizontal"},"upd":{"StackObjectsCount":2}},
    {"_id":"i2","_tpl":"tplIn","parentId":"stash1","slotId":"hideout",
     "location":{"x":1,"y":0,"r":"Horizontal"},"upd":{"StackObjectsCount":5}},
    {"_id":"t1","_tpl":"tplTool","parentId":"stash1","slotId":"hideout",
     "location":{"x":2,"y":0,"r":"Horizontal"}}]"""

  if recipeById(recipes, "r1").len == 0:
    failures.add "production: recipe r1 was not found"
  if recipeById(recipes, "nope").len != 0:
    failures.add "production: an unknown recipe id resolved to something"
  if recipeById("[]", "r1").len != 0:
    failures.add "production: an empty recipe table produced a recipe"

  # Starting takes exactly the inputs, spread across two stacks, and leaves the
  # tool where it was.
  var inv = openInventory(items)
  var ch = newChange()
  var problem = ""
  let r1 = recipeById(recipes, "r1")
  var prods = startProduction(r1, areas, "{}", inv, stash, 1000, ch, problem)
  if problem.len > 0:
    failures.add "production: a legal start was refused: " & problem
  if availableOf(inv, "tplIn", stash) != 4:
    failures.add "production: start took " & $(7 - availableOf(inv, "tplIn", stash)) &
                 " inputs, not 3"
  if availableOf(inv, "tplTool", stash) != 1:
    failures.add "production: the tool was consumed"
  if indexOf(inv, "i1") >= 0:
    failures.add "production: the emptied stack was left behind"

  # And a second start of the same recipe is refused rather than resetting it.
  var problem2 = ""
  discard startProduction(r1, areas, prods, inv, stash, 1000, ch, problem2)
  if problem2.len == 0:
    failures.add "production: a recipe already running was started again"
  if availableOf(inv, "tplIn", stash) != 4:
    failures.add "production: the refused restart still took the inputs"

  # Not finished, then finished, off the clock alone -- no tick in between,
  # which is the case of a server that was switched off.
  var problem3 = ""
  discard takeProduction(prods, "r1", inv, stash, 1050, ch, problem3)
  if problem3.len == 0:
    failures.add "production: an unfinished craft was collected"
  var problem4 = ""
  let after = takeProduction(prods, "r1", inv, stash, 1100, ch, problem4)
  if problem4.len > 0:
    failures.add "production: a finished craft was not collected: " & problem4
  if availableOf(inv, "tplOut", stash) != 2:
    failures.add "production: collecting gave " &
                 $availableOf(inv, "tplOut", stash) & " items, not 2"
  var problem5 = ""
  discard takeProduction(after, "r1", inv, stash, 1200, ch, problem5)
  if problem5.len == 0:
    failures.add "production: the same craft was collected twice"

  # Requirements that cannot be met leave the inventory alone.
  var bare = openInventory("""[{"_id":"stash1","_tpl":"tplStash"}]""")
  var ch2 = newChange()
  var problem6 = ""
  discard startProduction(r1, areas, "{}", bare, stash, 1000, ch2, problem6)
  if problem6.len == 0:
    failures.add "production: a craft with no materials was started"
  var problem7 = ""
  discard startProduction(r1, """[{"type":3,"level":0}]""", "{}", inv, stash,
                          1000, ch2, problem7)
  if problem7.len == 0:
    failures.add "production: a craft in an unbuilt area was started"

  # Fuel pays for the window, and the generator switches itself off when dry.
  # One unit of fuel at one unit per second is one second of power, however
  # long the server was away.
  var powered = 0
  var fuelChanged = false
  let burnt = burnFuel(areas, 3600, 1.0, powered, fuelChanged)
  if powered != 1:
    failures.add "production: 1 unit of fuel paid for " & $powered & "s, not 1s"
  if areaActive(burnt, GeneratorArea):
    failures.add "production: the generator kept running on an empty tank"

  # Continuous production is credited the powered window and no more, and it
  # stops at its own limit rather than banking forever.
  var contProds = "{}"
  var chW = newChange()
  var problemW = ""
  contProds = startProduction(recipeById(recipes, "water"), areas, "{}", inv,
                              stash, 1000, chW, problemW)
  if problemW.len > 0:
    failures.add "production: the water collector would not start: " & problemW
  var tickChanged = false
  contProds = tickProductions(contProds, 10000, 150, 1150, tickChanged)
  if unitsReady(getRaw(parseObject(contProds), "water"), 1150) != 1:
    failures.add "production: 150 powered seconds made " &
                 $unitsReady(getRaw(parseObject(contProds), "water"), 1150) &
                 " units of a 100s recipe, not 1"
  contProds = tickProductions(contProds, 100000, 100000, 2000, tickChanged)
  if unitsReady(getRaw(parseObject(contProds), "water"), 2000) != 2:
    failures.add "production: a continuous line ran past its limit of 2"

  # Bonuses come off the built levels and are stable across a second sync.
  const areaTable = """[{"type":3,"stages":{"1":{"bonuses":[
    {"type":"StashSize","value":1}]}}}]"""
  var bChanged = false
  let b1 = syncBonuses("""[{"id":"mine","type":"FromAMod"}]""", areaTable,
                       areas, bChanged)
  if count(whole(b1)) != 2:
    failures.add "production: sync produced " & $count(whole(b1)) &
                 " bonuses, not the mod's one plus the hideout's one"
  var bChanged2 = false
  let b2 = syncBonuses(b1, areaTable, areas, bChanged2)
  if bChanged2 or b2 != b1:
    failures.add "production: syncing bonuses twice changed them"

  result = failures.len == before
