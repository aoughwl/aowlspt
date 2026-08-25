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
## `emu/trading.nim`, for the same reason. `resolveRequirements` is that
## resolver, it is shared with `emu/hideout`, and the rule it applies is the
## same for a craft and for a hideout stage: **every requirement in full, or
## refused naming what is missing.** Neither of them has a laxer copy.
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
import skills
import questcond
import rand

const
  GeneratorArea* = 4
    ## The generator's area type in the client's own numbering. Named because
    ## the fuel burn is the one place production has to know about a *specific*
    ## area rather than whatever the recipe points at.

  ScavCaseArea* = 14
    ## The scav case's area type, in the same numbering — and **read out of the
    ## database rather than remembered**, which matters because the obvious
    ## guess is wrong. The reference dump carries `HideoutAreas` as an enum with
    ## its values stripped, so the number is not in it; what *is* in the
    ## database is the English locale, where `hideout_area_14_name` is
    ## "Scav Case" and `hideout_area_16_name` is "Hall of Fame". `_4_` is
    ## "Generator", which is the constant above, so the same table confirms
    ## both.

  DefaultFuelFlowRate* = 0.0013888
    ## Resource units per second, when the database's `hideout.settings` has no
    ## `generatorFuelFlowRate`. One unit per 720 seconds — a 100-unit fuel can
    ## lasts twenty hours, which is the live game's order of magnitude. A wrong
    ## rate here burns a player's fuel at the wrong speed; a *zero* rate would
    ## make fuel infinite, so the fallback is deliberately non-zero.

type
  ProductionAction* = enum
    paNone, paStart, paTake, paCancel, paScavCase

proc productionAction*(name: string): ProductionAction =
  ## The client sends four different start actions and one take. Two of the
  ## starts differ in which recipe table they mean, not in what the server does,
  ## so they collapse to one; the scav case has its own arm because its recipes
  ## are a different table with a different shape — no `endProduct`, but a count
  ## of items per *rarity*.
  ##
  ## `HideoutCircleOfCultistProductionStart` is deliberately still absent: the
  ## database's `cultistRecipes` is a single entry carrying nothing but an
  ## `_id`, so there is no table behind it to answer from.
  case name
  of "HideoutSingleProductionStart": paStart
  of "HideoutContinuousProductionStart": paStart
  of "HideoutScavCaseProductionStart": paScavCase
  of "HideoutTakeProduction": paTake
  of "HideoutDeleteProductionCommand": paCancel
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

# ---------------------------------------------------------------------------
# The scav case
# ---------------------------------------------------------------------------
#
# `docs/EMULATOR-COVERAGE.md` recorded this as "not served -- its recipes are a
# different table", and the table is imported: `hideout.production.scavRecipes`,
# five entries on a live dump. What was actually missing was the *reward pool*,
# and the shape of a scav recipe says exactly what it has to be:
#
#     "endProducts": {"Common":    {"min": 0, "max": 0},
#                     "Rare":      {"min": 1, "max": 1},
#                     "Superrare": {"min": 3, "max": 5}}
#
# — a count per rarity and no template ids at all. The real server draws its
# pool from a rouble price band held in its own config (`ScavCaseConfig.
# RewardItemValueRangeRub`), which is not in any database and is not here.
#
# **But every item template carries `_props.RarityPvE`, and its three values are
# `Common`, `Rare` and `Superrare` — the same three strings, spelled the same
# way, that `endProducts` is keyed by.** On a live dump that is 567 common,
# 1,287 rare and 757 superrare templates. So the pool is a join on the data
# rather than a band invented here, and the one place a judgement is still
# needed is which templates are eligible at all:
#
# - **it must have a handbook entry with a price above zero.** The handbook is
#   what this server prices everything by; an item it does not price cannot be
#   sold (`emu/trading` refuses), so putting one in a case is putting in
#   something the player cannot do anything with. It also bounds the walk: the
#   handbook is 4,288 rows against 4,673 templates.
# - **it must not be a quest item.** 144 of them are, and a quest item that
#   appears from nowhere is a quest the player can no longer fail properly.
# - **`Not_exist` is not a rarity.** 1,505 templates carry it and it is the
#   database saying the item does not drop.
#
# What is *not* modelled, and is named here rather than left to be found: the
# real server's blacklists, its "at most one money reward per rarity" rule and
# its ammo handling all live in that same config. Without it the case can roll
# a stack of roubles or a box of ammo where the live game would have re-rolled.
# That is a difference in the *distribution*, not in the arithmetic, and it is
# visible to a player as an occasionally dull case rather than as a wrong one.

proc scavRecipesJson*(): string =
  ## `hideout.production.scavRecipes`, normalised to an array.
  ##
  ## A database whose `hideout.production` is a bare array is the older shape,
  ## which has no scav recipes in it at all — answered as "none" rather than as
  ## the craft table, because answering a scav case out of the craft table would
  ## charge for one thing and make another.
  let v = dbRead("hideout.production")
  if not v.ok or v.raw.len == 0:
    return "[]"
  let j = whole(v.raw)
  if isArray(j):
    return "[]"
  let inner = j.field("scavRecipes")
  if inner.found and isArray(inner):
    return raw(inner)
  result = "[]"

proc scavRecipe*(recipeId: string): string =
  recipeById(scavRecipesJson(), recipeId)

var gPoolCommon: seq[string] = @[]
var gPoolRare: seq[string] = @[]
var gPoolSuperrare: seq[string] = @[]
var gPoolsBuilt = false

proc buildRewardPools() =
  ## One walk of the handbook, once per process, on the first scav case that is
  ## started. Nothing else in this server needs it and a server nobody runs a
  ## scav case on never pays for it.
  ##
  ## The flag is set *before* the walk rather than after, so a database with no
  ## handbook is not re-walked on every request: "built" means "asked", and the
  ## answer to an empty database is three empty pools, which the caller refuses
  ## on by name.
  if gPoolsBuilt:
    return
  gPoolsBuilt = true
  let hb = dbRead("templates.handbook.Items")
  if not hb.ok or hb.raw.len == 0:
    return
  let rows = each(whole(hb.raw))
  for row in rows:
    let id = row.field("Id").asText("")
    if id.len == 0:
      continue
    if row.field("Price").asInt(0) <= 0:
      continue
    let quest = dbRead("templates.items." & id & "._props.QuestItem")
    if quest.ok and asText(quest) == "true":
      continue
    let rarity = dbRead("templates.items." & id & "._props.RarityPvE")
    if not rarity.ok:
      continue
    case asText(rarity)
    of "Common": gPoolCommon.add id
    of "Rare": gPoolRare.add id
    of "Superrare": gPoolSuperrare.add id
    else: discard

proc rewardPool*(rarity: string): seq[string] =
  buildRewardPools()
  case rarity
  of "Common": result = gPoolCommon
  of "Rare": result = gPoolRare
  of "Superrare": result = gPoolSuperrare
  else: result = @[]

proc scavCaseRarities*(): seq[string] =
  ## The three keys `endProducts` is written with, in a fixed order so that a
  ## roll is reproducible from its seed rather than from a map's iteration.
  result = @["Common", "Rare", "Superrare"]

proc scavCaseRoll*(endProductsJson: string;
                   common, rare, superrare: seq[string]; seed: string;
                   problem: var string): seq[string] =
  ## The templates one scav case will produce. Pure: the pools are handed in, so
  ## `selfCheckScavCase` can roll a case against three literal lists with no
  ## database under it.
  ##
  ## Rolled at **start** and stored on the record, not at collection. Rolling at
  ## collection would let a player who did not like what came out restart the
  ## server and collect again, which is a re-roll for free; and the reference
  ## puts `Products` on the production record, which is the same decision.
  ##
  ## `problem` non-empty means the case must not be started: the money has not
  ## been taken yet, and a case that produced nothing because the database had
  ## no items of a rarity it asked for would be a theft with a shrug attached.
  problem = ""
  result = @[]
  var rng = seededRng(seed)
  let ends = whole(endProductsJson)
  let rarities = scavCaseRarities()
  for rarity in rarities:
    let band = ends.field(rarity)
    if not band.found:
      continue
    var low = band.field("min").asInt(0)
    var high = band.field("max").asInt(0)
    if high < low:
      # The database contradicting itself. Read as the pair the two numbers
      # agree on rather than as a negative count.
      high = low
    if low < 0: low = 0
    if high <= 0:
      # `max` of zero is the ordinary case, not an error: every live recipe
      # names all three rarities and zeroes the ones it does not pay in.
      continue
    var count = low
    if high > low:
      count = low + rng.nextInt(high - low + 1)
    if count <= 0:
      continue
    var pool: seq[string] = @[]
    case rarity
    of "Common": pool = common
    of "Rare": pool = rare
    of "Superrare": pool = superrare
    else: pool = @[]
    if pool.len == 0:
      problem = "this server's database has no " & rarity &
                " items to put in a scav case; it names no _props.RarityPvE " &
                "or has no handbook to price them by"
      result = @[]
      return
    for k in 0 ..< count:
      result.add pool[rng.nextInt(pool.len)]

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

proc consume*(inv: var Inventory; plan: seq[int]; amounts: seq[int];
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
# What is in an area's slots
# ---------------------------------------------------------------------------
#
# The generator's fuel and the water collector's filters live here rather than
# in the stash: an area carries `slots`, each slot carries an item, and each of
# those items carries `upd.Resource.Value` -- how much of itself is left. It is
# read by the fuel burn below and by a recipe's `Resource` requirement, which is
# the one input a craft takes out of the hideout rather than out of the player's
# stash.

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

proc resourceInSlots*(areasJson: string; areaType: int; tpl: string): float =
  ## How much of one template's `Resource` the area's slots are holding, added
  ## up across every slot that has one. Zero for an area that is not there, has
  ## no slots, or has nothing of that template in them.
  ##
  ## Restricted by template, and that word is doing the same work as "loose" in
  ## `availableOf`: the water collector's slots take filters, and a recipe that
  ## asks for 66 units of filter must not be paid for out of whatever else the
  ## player has dropped in beside them.
  result = 0.0
  let area = areaEntry(areasJson, areaType)
  if not area.found:
    return
  let slots = each(area.field("slots"))
  for s in slots:
    let itemJson = slotItem(raw(s))
    if itemJson.len == 0:
      continue
    if tpl.len > 0 and field(itemJson, "_tpl").asText("") != tpl:
      continue
    let have = resourceOf(itemJson)
    if have > 0.0:
      result = result + have

proc drawFromSlots*(areasJson: string; areaType: int; tpl: string;
                    amount: float; changed: var bool): string =
  ## Takes `amount` of one template's resource out of the area's slots, filling
  ## from the first slot that has any. The caller has already established that
  ## the slots hold it -- this is the take half of check-everything-then-take,
  ## and it does not refuse.
  ##
  ## A slot drawn to zero is left in place at zero rather than emptied. An empty
  ## water filter is still an item the player owns and has to take out; deleting
  ## it here would be the server throwing away something it was only asked to
  ## spend.
  changed = false
  if amount <= 0.0:
    return areasJson
  var list = parseArray(areasJson)
  if not list.ok:
    return areasJson
  var at1 = -1
  for i in 0 ..< list.len:
    if field(list.items[i], "type").asInt(-1) == areaType:
      at1 = i
  if at1 < 0:
    return areasJson
  var area = parseObject(list.items[at1])
  var slots = parseArray(getRaw(area, "slots"))
  if not slots.ok:
    return areasJson
  var need = amount
  for i in 0 ..< slots.len:
    if need <= 0.0:
      break
    let itemJson = slotItem(slots.items[i])
    if itemJson.len == 0:
      continue
    if tpl.len > 0 and field(itemJson, "_tpl").asText("") != tpl:
      continue
    let have = resourceOf(itemJson)
    if have <= 0.0:
      continue
    let take = if have < need: have else: need
    need = need - take
    changed = true
    slots.replaceAt(i, withSlotItem(slots.items[i],
                                    withResource(itemJson, have - take)))
  if not changed:
    return areasJson
  setRaw(area, "slots", text(slots))
  list.replaceAt(at1, text(area))
  result = text(list)

# ---------------------------------------------------------------------------
# Requirements
# ---------------------------------------------------------------------------

proc isCurrency*(tpl: string): bool =
  ## Roubles, dollars or euros. The three templates this server is *fully*
  ## authoritative about: a stack of them carries nothing but a count, so
  ## "the profile does not hold 395,000 roubles" is a statement it can make
  ## without reservation. See `partialItems` below for why that matters.
  result = tpl == trading.Roubles or tpl == trading.Dollars or
           tpl == trading.Euros

proc resolveRequirements*(recipeJson, areasJson: string; inv: Inventory;
                          stashId: string; plan: var seq[int];
                          amounts: var seq[int]; resTpls: var seq[string];
                          resNeeds: var seq[float]; problem: var string;
                          profileText: string): bool =
  ## Resolves a requirement list against the profile without touching anything.
  ## On success `plan`/`amounts` say exactly which stacks to take how much from
  ## and `resTpls`/`resNeeds` how much resource to draw out of the area's slots;
  ## on failure `problem` says why and nothing has moved.
  ##
  ## **Every requirement in full, or the request is refused naming what is
  ## missing.** There is one rule here and it is the same one for a craft and
  ## for a hideout stage, because the two carry the same `requirements` shape
  ## and the difference between them is not a difference in what a player has to
  ## have. A version of this file briefly made stage materials *partial* -- take
  ## what the stash holds, warn about the rest, grant the level -- so that a
  ## real hideout could be started from a profile owning none of the bolts every
  ## real area asks for at stage 1. That is the client being given something it
  ## did not pay for. The reason the profile owns no bolts is that no trader in
  ## an imported database sells one: that is a fact about the economy, and the
  ## place to answer it is the acquisition step in `tools/realtest.nim`, not a
  ## weaker rule here.
  ##
  ## Seven requirement types are understood:
  ##
  ## - `Area` gates on a built level.
  ## - `Item` is consumed out of the stash.
  ## - `Tool` must be present and is given back untouched: a craft does not eat
  ##   the wrench.
  ## - `Resource` is drawn out of the *area's own slots* rather than the stash --
  ##   the water collector's filter, the generator's fuel -- and is verified
  ##   here and spent by `startProduction`.
  ## - `TraderLoyalty`, `Skill` and `QuestComplete` gate on what the profile has
  ##   earned, and **only when `profileText` is given**. A caller that does not
  ##   hand over a profile has nothing to evaluate them against, and refusing on
  ##   data it cannot see would lock content the player has legitimately
  ##   unlocked. Both request paths pass it now; the parameter stays because a
  ##   proc that is handed an inventory is not entitled to assume a profile.
  ##
  ## `GameVersion` is *permitted*, not silently failed: this server does not
  ## model game editions, and the standing rule for a requirement it genuinely
  ## cannot evaluate is to let it through rather than lock a player out on a
  ## guess.
  plan = @[]
  amounts = @[]
  resTpls = @[]
  resNeeds = @[]
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
        problem = "that needs area " & $at & " at level " & $need
        return false
    of "Tool":
      let tpl = r.field("templateId").asText("")
      if tpl.len > 0 and availableOf(inv, tpl, stashId) < 1:
        problem = "that needs a tool you do not have: " & tpl
        return false
    of "Resource":
      # `{"templateId":"<filter>","resource":66,"type":"Resource"}` -- one recipe
      # in the imported table, and it used to start without touching the filter
      # at all: the craft ran, the output landed, and the filter it was supposed
      # to have used up was still full. Drawn from the area the recipe is made
      # in, because that is where the slots that hold it are.
      let tpl = r.field("templateId").asText("")
      var need = asFloat(r.field("resource"), 0.0)
      if need <= 0.0:
        need = asFloat(r.field("count"), 0.0)
      if tpl.len > 0 and need > 0.0:
        var at = -1
        for k in 0 ..< resTpls.len:
          if resTpls[k] == tpl:
            at = k
        if at < 0:
          resTpls.add tpl
          resNeeds.add need
        else:
          resNeeds[at] = resNeeds[at] + need
    of "TraderLoyalty":
      # Read straight off `TradersInfo.<id>.loyaltyLevel`, which is the number
      # `emu/traders` re-derives from level, turnover and standing after every
      # move -- so this gates on the level the player has actually earned rather
      # than on one stored once and never revisited.
      if profileText.len > 0:
        let tid = r.field("traderId").asText("")
        var need = r.field("loyaltyLevel").asInt(0)
        if need <= 0:
          need = r.field("requiredLevel").asInt(0)
        if tid.len > 0 and need > 0:
          let have = field(profileText,
                           "TradersInfo." & tid & ".loyaltyLevel").asInt(1)
          if have < need:
            problem = "that needs loyalty level " & $need & " with " & tid &
                      " and you are " & $have
            return false
    of "Skill":
      # `{"skillName":"HideoutManagement","skillLevel":5,"type":"Skill"}` --
      # nine of them across the imported area table and none in the fixture,
      # which is why nothing here read them until now. The level is derived from
      # `Skills.Common.<name>.Progress` through the game's own curve rather than
      # stored, so it is the level the player has actually trained.
      if profileText.len > 0:
        let name = r.field("skillName").asText("")
        var need = r.field("skillLevel").asInt(0)
        if need <= 0:
          need = r.field("requiredLevel").asInt(0)
        if name.len > 0 and need > 0:
          let have = skillLevel(skillProgress(
            field(profileText, "Skills.Common").raw(), name))
          if have < need:
            problem = "that needs " & name & " at level " & $need &
                      " and you are " & $have
            return false
    of "QuestComplete":
      # Forty-three of these in the imported recipe table and none in the
      # fixture -- the crafts a quest unlocks. They were permitted because the
      # production path resolved its requirements without a profile and had
      # nothing to read them against; it passes one now, so a locked recipe is
      # locked.
      if profileText.len > 0:
        var qid = r.field("questId").asText("")
        if qid.len == 0:
          qid = r.field("templateId").asText("")
        if qid.len > 0 and questStatus(profileText, qid) != "Success":
          problem = "that is unlocked by finishing quest " & qid
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

  # The slots, before anything is planned out of the stash. Checked rather than
  # spent: `startProduction` draws them down once everything else has passed.
  #
  # Which area's slots is `areaType` for a recipe -- every recipe names the area
  # it is crafted in -- and `sptResourceArea` for a hideout stage, which has no
  # `areaType` of its own: giving it one would make the resolver refuse to build
  # level 1 of an area on the grounds that the area is not built.
  let slotArea = field(recipeJson, "sptResourceArea").asInt(homeArea)
  for k in 0 ..< resTpls.len:
    let have = resourceInSlots(areasJson, slotArea, resTpls[k])
    if have < resNeeds[k]:
      problem = "that needs " & $int(resNeeds[k]) & " resource of " &
                resTpls[k] & " in the area and there is " & $int(have)
      plan = @[]
      amounts = @[]
      resTpls = @[]
      resNeeds = @[]
      return false

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
      problem = "not enough " & tpls[k]
      plan = @[]
      amounts = @[]
      resTpls = @[]
      resNeeds = @[]
      return false
  result = true

# ---------------------------------------------------------------------------
# The production record
# ---------------------------------------------------------------------------

var gCraftMultiplier = 1.0

proc configureCraftTimes*(craftMultiplier: float) =
  gCraftMultiplier = craftMultiplier

proc scaleCraftTime*(seconds: int): int =
  ## A craft duration with the multiplier applied.
  ##
  ## Stamped onto the production record at START, not applied at collection.
  ## That is the same choice the surrounding code already makes and for the same
  ## reason: a craft finishes on the terms it was started on, so changing this
  ## setting does not retroactively shorten or lengthen something already
  ## running -- which would be indistinguishable from the server losing track.
  if seconds <= 0 or gCraftMultiplier == 1.0:
    return seconds
  result = int(float(seconds) * gCraftMultiplier + 0.5)
  if result < 0:
    result = 0

proc newProduction(recipeJson: string; nowSeconds: int): Doc =
  result = newDoc()
  setText(result, "RecipeId", field(recipeJson, "_id").asText(""))
  setNumber(result, "Progress", 0)
  setBool(result, "inProgress", true)
  setNumber(result, "StartTimestamp", nowSeconds)
  setNumber(result, "ProductionTime",
            scaleCraftTime(field(recipeJson, "productionTime").asInt(0)))
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

proc startProduction*(recipeJson: string; areasJson: var string;
                      productionJson: string; inv: var Inventory;
                      stashId: string; nowSeconds: int; ch: var Change;
                      problem: var string; profileText: string = ""): string =
  ## Returns the new `Hideout.Production` object. Unchanged, with `problem` set,
  ## on any refusal — and in that case neither the inventory nor the areas have
  ## been touched.
  ##
  ## `areasJson` is a `var` because a recipe with a `Resource` requirement is
  ## paid for out of the area's slots and not out of the stash: the filter in
  ## the water collector comes back with less in it. The caller writes it back.
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
  var resTpls: seq[string] = @[]
  var resNeeds: seq[float] = @[]
  if not resolveRequirements(recipeJson, areasJson, inv, stashId, plan, amounts,
                             resTpls, resNeeds, problem, profileText):
    # Reported by `applyProduction`, in one place for every refusal this proc
    # can make. It used to be added here and *only* here, so the two refusals
    # above it -- "no such recipe" and "that recipe is already running" -- set
    # `problem`, returned unchanged, and reached the client as `err:0` with an
    # empty `warnings` list: an action that did nothing and said nothing.
    return productionJson

  # Everything is verified; now it is taken. The slots first, because that is
  # the only half that can still be told apart afterwards if the process dies
  # between the two -- a stash short of its inputs with no craft running is a
  # loss the player can see, and a filter drawn down with no craft running is
  # the same shape.
  let homeArea = field(recipeJson, "areaType").asInt(-1)
  for k in 0 ..< resTpls.len:
    var drawn = false
    let updated = drawFromSlots(areasJson, homeArea, resTpls[k], resNeeds[k],
                                drawn)
    if drawn:
      areasJson = updated
  consume(inv, plan, amounts, ch)
  setRaw(prods, recipeId, text(newProduction(recipeJson, nowSeconds)))
  result = text(prods)

proc newScavCaseProduction(recipeJson: string; products: seq[string];
                           nowSeconds: int): Doc =
  ## The scav case's record. Same shape as an ordinary craft's, with the rolled
  ## templates written onto it instead of a single `endProduct`.
  ##
  ## `sptIsScavCase` is the reference's own member — `Nullable<Boolean>
  ## SptIsScavCase` on the production record — so the client is told what this
  ## is in the spelling its own server uses. *(unverified)* only in casing.
  result = newDoc()
  setText(result, "RecipeId", field(recipeJson, "_id").asText(""))
  setNumber(result, "Progress", 0)
  setBool(result, "inProgress", true)
  setNumber(result, "StartTimestamp", nowSeconds)
  setNumber(result, "ProductionTime",
            scaleCraftTime(field(recipeJson, "productionTime").asInt(0)))
  setRaw(result, "Products", "[]")
  setNumber(result, "SkipTime", 0)
  setBool(result, "sptIsComplete", false)
  setBool(result, "sptIsScavCase", true)
  setBool(result, "continuous", false)
  setNumber(result, "sptLimit", 0)
  setNumber(result, "sptCount", 1)
  setText(result, "sptProduct", "")
  setNumber(result, "sptLastTick", nowSeconds)
  var list = newList()
  for tpl in products:
    list.add quoted(tpl)
  setRaw(result, "sptScavProducts", text(list))

proc startScavCase*(recipeJson, areasJson: string; productionJson: string;
                    inv: var Inventory; stashId: string; nowSeconds: int;
                    seed: string; ch: var Change; problem: var string;
                    profileText: string = ""): string =
  ## One scav case, started. Same resolve-verify-then-take rule as every other
  ## production: the requirements are planned, the roll is made, and only then
  ## is anything removed from the stash — so a case that could not be filled
  ## costs nothing.
  problem = ""
  var prods = parseObject(productionJson)
  if not prods.ok:
    prods = newDoc()
  let recipeId = field(recipeJson, "_id").asText("")
  if recipeId.len == 0:
    problem = "no such scav case"
    return productionJson
  if has(prods, recipeId):
    problem = "that scav case is already running"
    return productionJson
  if areaLevel(areasJson, ScavCaseArea) < 1:
    # A scav recipe carries no `areaType`, so there is no `Area` requirement for
    # `resolveRequirements` to find and this gate has to be made here. Without
    # it a profile with no hideout at all could run scav cases.
    problem = "the scav case is not built yet"
    return productionJson

  var plan: seq[int] = @[]
  var amounts: seq[int] = @[]
  var resTpls: seq[string] = @[]
  var resNeeds: seq[float] = @[]
  var areas = areasJson
  if not resolveRequirements(recipeJson, areas, inv, stashId, plan, amounts,
                             resTpls, resNeeds, problem, profileText):
    return productionJson

  var rollProblem = ""
  let products = scavCaseRoll(raw(field(recipeJson, "endProducts")),
                              rewardPool("Common"), rewardPool("Rare"),
                              rewardPool("Superrare"), seed, rollProblem)
  if rollProblem.len > 0:
    problem = rollProblem
    return productionJson
  if products.len == 0:
    problem = "that scav case is written to produce nothing"
    return productionJson

  consume(inv, plan, amounts, ch)
  setRaw(prods, recipeId,
         text(newScavCaseProduction(recipeJson, products, nowSeconds)))
  result = text(prods)

proc takeScavCase(entry: string; prods: var Doc; recipeId: string;
                  inv: var Inventory; stashId: string; ch: var Change;
                  problem: var string): bool =
  ## Collects a finished scav case: several distinct templates rather than one
  ## template several times.
  ##
  ## **What lands is struck off the record as it lands.** A craft that makes one
  ## thing can be refused whole when the stash is full, because refusing and
  ## collecting are the only two outcomes. A case that makes five cannot: three
  ## may fit and two may not, and there is no way to put the three back. So the
  ## record is rewritten with exactly what is still owed, the player is told how
  ## many are waiting, and collecting again after clearing space gives them the
  ## rest — once.
  problem = ""
  let d = whole(entry)
  var owed: seq[string] = @[]
  for t in each(d.field("sptScavProducts")):
    let tpl = t.asText("")
    if tpl.len > 0:
      owed.add tpl
  if owed.len == 0:
    problem = "that scav case has already been emptied"
    return false

  var left: seq[string] = @[]
  var landed = 0
  for k in 0 ..< owed.len:
    if left.len > 0:
      # Once one has failed to fit, the rest are owed too: trying them anyway
      # would hand out the small items and strand the large ones, which is a
      # different case from the one that was rolled.
      left.add owed[k]
      continue
    if giveItem(inv, owed[k], stashId, 1, ch):
      inc landed
    else:
      left.add owed[k]

  if landed == 0:
    # `giveItem` has already said why in `ch.problems`.
    problem = "there is no room in the stash for that"
    return false

  if left.len == 0:
    remove(prods, recipeId)
  else:
    var e = parseObject(entry)
    var list = newList()
    for tpl in left:
      list.add quoted(tpl)
    setRaw(e, "sptScavProducts", text(list))
    setRaw(prods, recipeId, text(e))
    ch.problems.add "the stash had room for " & $landed & " of " & $owed.len &
                    "; the rest are still in the scav case"
  result = true

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
  if d.field("sptIsScavCase").asBool(false):
    if not takeScavCase(entry, prods, recipeId, inv, stashId, ch, problem):
      return productionJson
    return text(prods)
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
    # The profile goes in. Without it `TraderLoyalty`, `Skill` and
    # `QuestComplete` were resolved against nothing and therefore permitted --
    # forty-three recipes in an imported table are unlocked by a quest, and
    # every one of them could be crafted by a player who had never accepted it.
    # The areas come back out, because a `Resource` requirement is spent from
    # them.
    var areas = areasJson
    let updated = startProduction(r, areas, prodJson, inv, p.stashId,
                                  nowSeconds, ch, problem, p.text)
    if problem.len > 0:
      ch.problems.add problem
      return false
    if areas != areasJson:
      setRaw(p, "Hideout.Areas", areas)
    setRaw(p, "Hideout.Production", updated)
    result = true
  of paScavCase:
    let r = scavRecipe(recipeId)
    if r.len == 0:
      ch.problems.add "no such scav case: " & recipeId
      return false
    # Seeded from the profile, the recipe and the moment it started, so the roll
    # is reproducible from a bug report and is not the same for two players who
    # start the same case in the same second. `emu/rand` has the argument for
    # why loot varies through an explicit seed rather than a global generator.
    let seed = p.id & ":" & recipeId & ":" & $nowSeconds
    let updated = startScavCase(r, areasJson, prodJson, inv, p.stashId,
                                nowSeconds, seed, ch, problem, p.text)
    if problem.len > 0:
      ch.problems.add problem
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
  of paCancel:
    # Cancelling loses the inputs. That is the game's own rule and it is the
    # reason the action exists: a craft the player can back out of for free is
    # a free reservation on every material in the stash. Refusing to cancel a
    # craft that is not running is the same rule as refusing to collect one
    # twice -- it means the client and the server disagree, and answering
    # "done" leaves them disagreeing.
    var prods = parseObject(prodJson)
    if not prods.ok or not has(prods, recipeId):
      ch.problems.add "no craft of " & recipeId & " is running"
      return false
    remove(prods, recipeId)
    setRaw(p, "Hideout.Production", text(prods))
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
# The self-check
# ---------------------------------------------------------------------------

proc selfCheckScavCase*(into: var seq[string]): bool =
  ## Rolls scav cases against literal pools, with no database under them.
  ##
  ## Runs at load through `emu/selfchecks`. It is here rather than in `emutest`
  ## because the roll is only reachable through a route on a database that
  ## carries `_props.RarityPvE` and a priced handbook, which the test fixture
  ## does not -- so a check written at the wire would be a check that never ran.
  let before = into.len
  var common: seq[string] = @["c1", "c2"]
  var rare: seq[string] = @["r1", "r2"]
  var superrare: seq[string] = @["s1"]
  var none: seq[string] = @[]
  var problem = ""

  # The live shape: nothing common, exactly one rare, three to five superrare.
  let live = "{\"Common\":{\"min\":0,\"max\":0}," &
             "\"Rare\":{\"min\":1,\"max\":1}," &
             "\"Superrare\":{\"min\":3,\"max\":5}}"
  let rolled = scavCaseRoll(live, common, rare, superrare, "seed-a", problem)
  if problem.len > 0:
    into.add "scavcase: a well-formed recipe must roll"
  if rolled.len < 4 or rolled.len > 6:
    into.add "scavcase: 1 rare plus 3..5 superrare is 4 to 6 items"
  var supers = 0
  var rares = 0
  for tpl in rolled:
    if tpl == "s1": inc supers
    elif tpl == "r1" or tpl == "r2": inc rares
    else: into.add "scavcase: rolled " & tpl & " from a band that excludes it"
  if rares != 1:
    into.add "scavcase: a band of min 1 max 1 must produce exactly one"
  if supers < 3 or supers > 5:
    into.add "scavcase: the superrare band must be honoured"

  # The same seed is the same case. This is what makes the roll something a bug
  # report can name rather than something that happened once.
  let again = scavCaseRoll(live, common, rare, superrare, "seed-a", problem)
  if again.len != rolled.len:
    into.add "scavcase: the same seed must roll the same case"
  else:
    for k in 0 ..< again.len:
      if again[k] != rolled[k]:
        into.add "scavcase: the same seed must roll the same case"

  # A band of zero is the ordinary case, not an error -- and it must not consult
  # the pool, because every live recipe zeroes at least one rarity and two of
  # the five zero two.
  let onlyRare = "{\"Common\":{\"min\":0,\"max\":0}," &
                 "\"Rare\":{\"min\":2,\"max\":2}," &
                 "\"Superrare\":{\"min\":0,\"max\":0}}"
  let two = scavCaseRoll(onlyRare, none, rare, none, "seed-b", problem)
  if problem.len > 0 or two.len != 2:
    into.add "scavcase: a zeroed rarity must not need a pool"

  # A rarity that is asked for and has no pool is refused by name, and refused
  # before anything is charged -- the caller has not taken the entry fee yet.
  discard scavCaseRoll(live, common, rare, none, "seed-c", problem)
  if problem.len == 0 or find(problem, "Superrare") < 0:
    into.add "scavcase: an empty pool for a rarity that is asked for must " &
             "refuse by name"

  # A recipe with nothing in `endProducts` produces nothing rather than
  # something: the caller turns that into its own refusal.
  let empty = scavCaseRoll("{}", common, rare, superrare, "seed-d", problem)
  if problem.len > 0 or empty.len != 0:
    into.add "scavcase: a recipe with no endProducts produces nothing"

  # A `max` below `min` is the database contradicting itself. It must not
  # produce a negative count, and it must not spin.
  let backwards = "{\"Rare\":{\"min\":2,\"max\":1}}"
  let b = scavCaseRoll(backwards, none, rare, none, "seed-e", problem)
  if problem.len > 0 or b.len != 2:
    into.add "scavcase: max below min must read as min rather than as a " &
             "negative count"
  result = into.len == before
