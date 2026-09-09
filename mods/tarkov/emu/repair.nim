## Repair and durability.
##
## Two item events -- `Repair` (a kit out of the stash) and `TraderRepair` (paid
## for at a trader) -- and one piece of item state they both edit:
## `upd.Repairable`, which the reference spells `UpdRepairable` and gives two
## members, `Durability` and `MaxDurability`.
##
## ## Who wears the gun out
##
## **The client does.** Nothing in this server reduces durability, and that is
## not a gap: there is no route that would. `/client/match/local/end` carries
## the profile the client played the raid with, and `onMatchEnd` saves *that
## document* -- so a rifle that started the raid at 94/100 and finished it at
## 71/100 arrives with 71 already written into `upd.Repairable.Durability`. The
## reference has no per-shot, per-hit or per-raid wear callback for the server
## to run: `SaveProgress` is one of SPT's own singleplayer routes, the
## item-event action list has no wear action in it, and the only two actions in
## it that touch `Repairable` are the two below.
##
## That is worth stating rather than assuming, because the obvious design --
## "apply a percentage of wear at raid end" -- would apply it *on top of* the
## wear the client already applied, and the two are indistinguishable in the
## document that arrives.
##
## The consequence, named because it looks like an oversight: a client that
## hands back a profile with the durability put **up** is not caught. It is the
## same trust the rest of the raid result already gets, and closing it means
## comparing every item's `upd` against the pre-raid profile, which is a
## different piece of work from this one. It is in EMULATOR-COVERAGE.md.
##
## ## Repairing costs the item something
##
## Both kinds of repair reduce `MaxDurability`, which is what stops a rifle
## being a rifle forever. The rates are the *template's*, from four `_props` the
## reference names -- `MinRepairDegradation`/`MaxRepairDegradation` for a trader
## repair and `MinRepairKitDegradation`/`MaxRepairKitDegradation` for a kit --
## read as a multiplier applied to the number of points restored. A template
## carrying none of them degrades by **nothing**, because "the database does not
## say" must not become an invented penalty on the player's gear.
##
## Where the two ends of the range differ, the draw is from a generator seeded
## by the item's id and its durability at the moment of the repair -- `emu/rand`
## explains why nothing here uses a global source of entropy. Repairing the same
## item from the same state twice therefore degrades it identically, which is
## reproducible and is also the only way a test can assert an exact figure.
##
## ## What the reference gives and what it does not
##
## It gives the two request shapes (`RepairActionDataRequest` is
## `{Action, Target, RepairKitsInfo:[{Id, Count}]}`,
## `TraderRepairActionDataRequest` is `{Action, TraderId, RepairItems:[{Id,
## Count}]}`), the item state, the four degradation props, `_props.RepairCost`,
## `_props.MaxRepairResource`, `UpdRepairKit.Resource`,
## `TraderLoyaltyLevel.RepairPriceCoefficient` and the three numbers on
## `RepairSettings` -- `DurabilityPointCostArmor`, `DurabilityPointCostGuns` and
## `ArmorClassDivisor`.
##
## It does **not** give the arithmetic that joins them, because a metadata dump
## carries names and not method bodies. So the two formulas below are a reading
## of those names, and they are written out here so that a reader can disagree
## with them rather than reverse-engineer them:
##
## - **A trader's price** is `RepairCost` per point of durability, times the
##   points restored, times the loyalty level's `repair_price_coef` as a
##   percentage, rounded up. A coefficient of 100 is therefore "full price",
##   which is how the fixture's and the live database's LL1 rows read.
## - **A kit's cost** is `DurabilityPointCostGuns` units of the kit's `Resource`
##   per point of durability restored on a firearm, and
##   `DurabilityPointCostArmor * armorClass / ArmorClassDivisor` on armour.
##   Absent settings mean one unit per point, which makes a server with no
##   globals table behave sensibly rather than refuse every repair.
##
## Neither number is ever taken from the request. The count in the body is
## clamped to the damage the item has actually taken and to what the kit can
## actually pay for, exactly as a heal is clamped to the damage and a trade to
## the stack -- and the price is worked out from the template afterwards, so a
## request asking to restore 9999 points pays for the damage and not for 9999.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import numbers
import profile
import inventory
import templates
import trading
import traders
import rand

type
  RepairAction* = enum
    reNone, reKit, reTrader

  Plan = object
    ## One item's repair, worked out before anything is written. Every field
    ## here is the server's arithmetic; none of it came out of the request.
    index: int
    id: string
    points: float
    durability: float
    maxDurability: float
    cost: int

proc repairAction*(name: string): RepairAction =
  case name
  of "Repair": reKit
  of "TraderRepair": reTrader
  else: reNone

# ---------------------------------------------------------------------------
# Numbers
# ---------------------------------------------------------------------------

proc ceilInt(v: float): int =
  ## Rounded **up**, so a repair never costs less than its arithmetic says. A
  ## price truncated downwards is free money one rouble at a time, and there is
  ## no upper bound on how often a player can click repair.
  result = int(v)
  if float(result) < v:
    inc result

proc propFloat(tpl, name: string; found: var bool): float =
  let v = itemProp(tpl, name)
  found = v.ok
  if not v.ok:
    return 0.0
  result = v.asFloat(0.0)

proc updFloat(item: Doc; group, name: string; found: var bool): float =
  ## One number out of `upd.<group>.<name>`. `found` distinguishes "absent, so
  ## fall back to the template" from "present and zero", which for a resource is
  ## the difference between a fresh kit and a spent one.
  found = false
  let upd = get(item, "upd")
  if not upd.found:
    return 0.0
  let g = upd.field(group)
  if not g.found:
    return 0.0
  let v = g.field(name)
  if not v.found:
    return 0.0
  found = true
  result = v.asFloat(0.0)

proc setUpdFloat(item: var Doc; group, name: string; value: float) =
  var upd = parseObject(getRaw(item, "upd"))
  if not upd.ok:
    upd = newDoc()
  var g = parseObject(getRaw(upd, group))
  if not g.ok:
    g = newDoc()
  setRaw(g, name, numText(value))
  setRaw(upd, group, text(g))
  setRaw(item, "upd", text(upd))

# ---------------------------------------------------------------------------
# The item's durability
# ---------------------------------------------------------------------------

proc readDurability(item: Doc; tpl: string; dur, maxDur: var float): bool =
  ## The item's durability, or the template's when the item has never carried
  ## any. False when neither knows -- which is a refusal and not a default: an
  ## item repaired from an assumed maximum is an item whose maximum the server
  ## just invented, and on a database with no item table that is every item
  ## there is.
  var haveDur = false
  var haveMax = false
  dur = updFloat(item, "Repairable", "Durability", haveDur)
  maxDur = updFloat(item, "Repairable", "MaxDurability", haveMax)
  if not haveMax:
    maxDur = propFloat(tpl, "MaxDurability", haveMax)
  if not haveMax:
    return false
  if not haveDur:
    var haveTplDur = false
    dur = propFloat(tpl, "Durability", haveTplDur)
    if not haveTplDur:
      dur = maxDur
  if maxDur <= 0.0:
    return false
  if dur > maxDur:
    # A profile that arrived claiming more durability than the item can hold.
    # Clamped rather than believed, and clamped here rather than at raid end
    # because this is the one place the server has a reason to read it.
    dur = maxDur
  if dur < 0.0:
    dur = 0.0
  result = true

proc armourClassOf(tpl: string): float =
  ## Zero means "not armour". The live database spells this `armorClass`; the
  ## reference's property is `ArmorClass`. Both are read, because the dump names
  ## the property and the database names the key and they do not have to agree.
  var found = false
  var v = propFloat(tpl, "armorClass", found)
  if not found:
    v = propFloat(tpl, "ArmorClass", found)
  if not found or v <= 0.0:
    return 0.0
  result = v

var gRepairPriceMultiplier = 1.0
  ## What a TRADER repair bill is multiplied by.
  ##
  ## Trader repairs only. A kit repair is paid for in the kit's own `Resource`,
  ## not in roubles, so there is no bill for this to scale -- pretending
  ## otherwise would be a row that changes nothing for half the repairs in the
  ## game.

proc configureRepairPrices*(priceMultiplier: float) =
  gRepairPriceMultiplier = priceMultiplier
  if gRepairPriceMultiplier < 0.0:
    gRepairPriceMultiplier = 0.0

proc repairSetting(name: string; fallback: float): float =
  ## One number off `globals.config.RepairSettings`. Read under both the
  ## reference's spelling and the lower-camel one the live globals file uses,
  ## because this is exactly the kind of key that differs between the dump and
  ## the data, and reading it wrong is a silent factor-of-one.
  let a = dbRead("globals.config.RepairSettings." & name)
  if a.ok:
    return a.asFloat(fallback)
  var other = name
  if other.len > 0:
    other = toLowerAscii(other.substr(0, 0)) & other.substr(1)
  let b = dbRead("globals.config.RepairSettings." & other)
  if b.ok:
    return b.asFloat(fallback)
  result = fallback

proc degradationFactor(tpl: string; byKit: bool; seed: string): float =
  ## How much `MaxDurability` one point of repair costs.
  ##
  ## Zero when the template names neither end of the range: an unknown rate is
  ## not a licence to damage somebody's rifle. When both ends are named and
  ## equal the answer is exact; when they differ it is drawn from a generator
  ## seeded by `seed`, so the same repair of the same item from the same state
  ## always costs the same and a bug report can be replayed.
  let minName = if byKit: "MinRepairKitDegradation" else: "MinRepairDegradation"
  let maxName = if byKit: "MaxRepairKitDegradation" else: "MaxRepairDegradation"
  var haveMin = false
  var haveMax = false
  let lo = propFloat(tpl, minName, haveMin)
  let hi = propFloat(tpl, maxName, haveMax)
  if not haveMin and not haveMax:
    return 0.0
  let low = if haveMin: lo else: hi
  let high = if haveMax: hi else: lo
  if high <= low:
    if low > 0.0:
      return low
    return 0.0
  var r = seededRng(seed)
  result = low + nextFloat(r) * (high - low)

proc kitCostPerPoint(tpl: string): float =
  ## Units of a kit's `Resource` spent per point of durability restored.
  ##
  ## One per point when the globals table says nothing, which is the answer that
  ## keeps a server with no database working rather than one that refuses every
  ## repair. The armour form scales by the item's own class, which is the only
  ## reading of `ArmorClassDivisor` that makes a class 6 plate cost more to fix
  ## than a class 2 rig.
  let cls = armourClassOf(tpl)
  if cls <= 0.0:
    result = repairSetting("DurabilityPointCostGuns", 1.0)
  else:
    let divisor = repairSetting("ArmorClassDivisor", 0.0)
    result = repairSetting("DurabilityPointCostArmor", 1.0)
    if divisor > 0.0:
      result = result * cls / divisor
  if result <= 0.0:
    result = 1.0

# ---------------------------------------------------------------------------
# Applying one planned repair
# ---------------------------------------------------------------------------

proc applyPlan(inv: var Inventory; pl: Plan; tpl: string; byKit: bool;
               ch: var Change) =
  ## Writes the repair the planner worked out. Called only after every entry in
  ## a request has been verified and paid for.
  var item = itemAt(inv, pl.index)
  let factor = degradationFactor(tpl, byKit,
                                 pl.id & ":" & numText(pl.durability) & ":" &
                                 numText(pl.maxDurability))
  var newMax = pl.maxDurability - pl.points * factor
  if newMax < 1.0:
    # A floor rather than zero. An item at zero maximum durability divides by
    # nothing in every ratio the client draws with it, and there is no way back
    # from it -- a repair of an item that can hold no durability restores none.
    newMax = 1.0
  var newDur = pl.durability + pl.points
  if newDur > newMax:
    newDur = newMax
  setUpdFloat(item, "Repairable", "Durability", newDur)
  setUpdFloat(item, "Repairable", "MaxDurability", newMax)
  inv.items.replaceAt(pl.index, text(item))
  inv.dirty = true
  ch.changed.add text(item)

proc planFor(inv: Inventory; id: string; asked: float; ch: var Change;
             out1: var Plan): bool =
  ## Resolves "repair this item by this much" to what the server will actually
  ## do. The number in the request is an upper bound and nothing else.
  out1 = Plan(index: -1, id: id, points: 0.0, durability: 0.0,
              maxDurability: 0.0, cost: 0)
  let at = indexOf(inv, id)
  if at < 0:
    ch.problems.add "repair: no such item " & id
    return false
  let item = itemAt(inv, at)
  let tpl = get(item, "_tpl").asText("")
  var dur = 0.0
  var maxDur = 0.0
  if not readDurability(item, tpl, dur, maxDur):
    ch.problems.add "repair: no durability is known for " & tpl
    return false
  let missing = maxDur - dur
  if missing <= 0.0:
    ch.problems.add "repair: that item is not damaged"
    return false
  var points = asked
  if points <= 0.0 or points > missing:
    points = missing
  out1 = Plan(index: at, id: id, points: points, durability: dur,
              maxDurability: maxDur, cost: 0)
  result = true

# ---------------------------------------------------------------------------
# Trader repair
# ---------------------------------------------------------------------------

proc repairPriceCoefficient(traderId: string; level: int): float =
  ## The loyalty level's `repair_price_coef`, as a percentage. 100 -- full price
  ## -- when the level does not name one, which is what a trader base with no
  ## coefficients means and what every level after the first in the live data
  ## means too: the coefficient is written on the rows that change it.
  let base = traderBase(traderId)
  if base.len == 0:
    return 100.0
  let levels = each(field(base, "loyaltyLevels"))
  var index = 0
  for l in levels:
    inc index
    if index != level:
      continue
    let c = l.field("repair_price_coef")
    if c.found:
      return c.asFloat(100.0)
    # The reference's property name, in case a database was written from it.
    let d = l.field("RepairPriceCoefficient")
    if d.found:
      return d.asFloat(100.0)
    return 100.0
  result = 100.0

proc traderRefuses(traderId, tpl: string): bool =
  ## What a trader will not repair: `ExcludedIdList`, and now
  ## `ExcludedCategory` as well.
  ##
  ## The wire spelling of both members is *(unverified)*: the reference dump
  ## names the properties and a live trader base keys them `excluded_id_list`
  ## and `excluded_category`, so both spellings are read. A dump and the data it
  ## describes do not have to agree, and a key read wrong here is a silent
  ## "refuses nothing".
  ##
  ## `ExcludedCategory` names **handbook categories**, not templates, and a
  ## category names a branch rather than a leaf: on real data the ids a trader
  ## excludes sit several levels above the category an item's own handbook entry
  ## is filed under. So the test is "is any category on this item's path to the
  ## root of the handbook tree excluded" -- `handbookCategories` in
  ## `emu/templates` is that walk.
  ##
  ## An item the handbook has no entry for is **not** refused. Its categories
  ## are unknown rather than empty, and refusing every unplaced item would make
  ## a trader with one exclusion refuse the whole game on a database with no
  ## handbook. Forgiving is the right direction for a refusal to repair: the
  ## cost of getting it wrong is a repair that should not have happened, and the
  ## player paid the trader's price for it either way.
  let base = traderBase(traderId)
  if base.len == 0:
    return false
  var node = field(base, "repair.excluded_id_list")
  if not node.found:
    node = field(base, "repair.ExcludedIdList")
  if node.found:
    for e in each(node):
      if e.asText("") == tpl:
        return true
  var cats = field(base, "repair.excluded_category")
  if not cats.found:
    cats = field(base, "repair.ExcludedCategory")
  if not cats.found:
    return false
  let excluded = each(cats)
  if excluded.len == 0:
    return false
  let path = handbookCategories(tpl)
  for e in excluded:
    let want = e.asText("")
    if want.len == 0:
      continue
    for got in path:
      if got == want:
        return true
  result = false

proc doTraderRepair(p: var Profile; inv: var Inventory; action: JsonRef;
                    ch: var Change): bool =
  var traderId = action.field("tid").asText("")
  if traderId.len == 0:
    traderId = action.field("traderId").asText("")
  if traderId.len == 0:
    ch.problems.add "repair: no trader named"
    return false
  if traderBase(traderId).len == 0:
    ch.problems.add "repair: there is no trader " & traderId
    return false

  var entries = action.field("repairItems")
  if not entries.found:
    entries = action.field("RepairItems")
  if not entries.found or not isArray(entries):
    ch.problems.add "repair: nothing to repair"
    return false

  let level = loyaltyOf(p, traderId)
  let coefficient = repairPriceCoefficient(traderId, level)

  # ---- plan: nothing is written and nothing is paid ----------------------
  var plans: seq[Plan] = @[]
  var tpls: seq[string] = @[]
  var total = 0
  for e in each(entries):
    var id = e.field("_id").asText("")
    if id.len == 0: id = e.field("Id").asText("")
    if id.len == 0: id = e.field("id").asText("")
    if id.len == 0:
      ch.problems.add "repair: an entry named no item"
      return false
    # The same id twice in one body would otherwise be planned twice off the
    # same starting durability: one repair, charged and applied twice.
    for done in plans:
      if done.id == id:
        ch.problems.add "repair: " & id & " is named twice in one request"
        return false
    var asked = e.field("count").asFloat(0.0)
    if asked <= 0.0:
      asked = e.field("Count").asFloat(0.0)
    var one = Plan(index: -1, id: "", points: 0.0, durability: 0.0,
                   maxDurability: 0.0, cost: 0)
    if not planFor(inv, id, asked, ch, one):
      return false
    let tpl = field(inv.items.items[one.index], "_tpl").asText("")
    if traderRefuses(traderId, tpl):
      ch.problems.add "repair: that trader does not repair " & tpl
      return false
    var havePrice = false
    let perPoint = propFloat(tpl, "RepairCost", havePrice)
    if not havePrice or perPoint <= 0.0:
      # Refused rather than repaired for nothing, for the same reason selling an
      # item the handbook does not price is refused: free is not the same answer
      # as unknown, and a free repair removes the whole system.
      ch.problems.add "repair: no repair price is known for " & tpl
      return false
    one.cost = ceilInt(perPoint * one.points * coefficient / 100.0 *
                       gRepairPriceMultiplier)
    # A multiplier of exactly 0 is the "repairs are free" setting and is
    # allowed to reach 0. Every other multiplier keeps the floor of 1, so a
    # bill is never rounded away by accident.
    if one.cost <= 0 and gRepairPriceMultiplier != 0.0:
      one.cost = 1
    if one.cost < 0:
      one.cost = 0
    total = total + one.cost
    plans.add one
    tpls.add tpl

  if plans.len == 0:
    ch.problems.add "repair: nothing to repair"
    return false

  # ---- act ---------------------------------------------------------------
  # The price is found in the player's own loose stacks: a `TraderRepair`
  # carries no `scheme_items`, exactly like an `Insure`, so the server picks
  # them -- and `spendCurrency` verifies the whole amount is there before it
  # takes any of it.
  #
  # Charged in the trader's own currency, at the trader's own rate.
  #
  # This used to be roubles unconditionally, on the grounds that "converting
  # would need a rate, and the only rate in this database is the handbook price
  # of a currency item, which prices a *stack of notes* rather than an
  # exchange". Both halves of that were wrong.
  # `traders.<id>.base.repair.currency_coefficient` **is** the rate, and it sits
  # in the same object as the currency it converts: 1 for every rouble trader,
  # `0.00847457627118644` for Peacekeeper -- which is 1/118. And the handbook
  # prices are per note, not per stack: RUB is 1, USD 121, EUR 134, and 1/121
  # agrees with Peacekeeper's own coefficient to within 2.5%.
  #
  # It is worth being plain about how much this buys today: **nothing**. Only
  # Prapor, Skier and Mechanic have `repair.availability` true, all three
  # charge roubles and all three carry a coefficient of exactly 1. Peacekeeper
  # is the one non-rouble repairer in the database and he does not repair. So
  # this is a wrong reason corrected rather than a feature added, and the
  # reason mattered: a trader added by a mod who charges dollars would have
  # been silently billed in roubles at 118 times the price.
  var payTpl = trading.Roubles
  var payTotal = total
  let currency = field(traderBase(traderId), "repair.currency").asText("")
  if currency.len > 0 and currency != trading.Roubles:
    let rate = field(traderBase(traderId),
                     "repair.currency_coefficient").asFloat(0.0)
    if rate <= 0.0:
      # A currency with no coefficient beside it. Refused rather than billed in
      # roubles: the player would be charged 118 times what the screen said.
      ch.problems.add "repair: " & traderId & " charges in " & currency &
                      " and this database gives no rate to convert it at"
      return false
    payTpl = currency
    payTotal = ceilInt(float(total) * rate)
    if payTotal <= 0:
      payTotal = 1
  if not spendCurrency(inv, payTpl, payTotal, p.stashId, ch):
    return false
  for k in 0 ..< plans.len:
    applyPlan(inv, plans[k], tpls[k], false, ch)
  # Money paid to a trader is turnover with that trader, the same as a purchase.
  addSalesSum(p, traderId, total)
  result = true

# ---------------------------------------------------------------------------
# Repair with a kit
# ---------------------------------------------------------------------------

proc doKitRepair(p: var Profile; inv: var Inventory; action: JsonRef;
                 ch: var Change): bool =
  var target = action.field("target").asText("")
  if target.len == 0:
    target = action.field("Target").asText("")
  if target.len == 0:
    ch.problems.add "repair: no item to repair"
    return false

  var kits = action.field("repairKitsInfo")
  if not kits.found:
    kits = action.field("RepairKitsInfo")
  if not kits.found or not isArray(kits):
    ch.problems.add "repair: no kit named"
    return false

  # The request's counts are an upper bound on the points asked for; the damage
  # is the other bound, and `planFor` applies it.
  var asked = 0.0
  for e in each(kits):
    var one = e.field("count").asFloat(0.0)
    if one <= 0.0:
      one = e.field("Count").asFloat(0.0)
    asked = asked + one
  var plan = Plan(index: -1, id: "", points: 0.0, durability: 0.0,
                  maxDurability: 0.0, cost: 0)
  if not planFor(inv, target, asked, ch, plan):
    return false
  let tpl = field(inv.items.items[plan.index], "_tpl").asText("")
  let perPoint = kitCostPerPoint(tpl)

  # ---- check the kits the request names, all of them ---------------------
  #
  # Before the planning loop, and that ordering is the whole point: the planner
  # stops as soon as the damage is covered, so a duplicate that happened to sit
  # after the last kit it needed was never looked at -- and a body naming one
  # kit twice was answered with a repair rather than a refusal. "Check it all,
  # then act" means checking the entries the plan does not reach.
  var named: seq[string] = @[]
  for e in each(kits):
    var id = e.field("_id").asText("")
    if id.len == 0: id = e.field("Id").asText("")
    if id.len == 0: id = e.field("id").asText("")
    if id.len == 0:
      ch.problems.add "repair: a kit entry named no item"
      return false
    if indexOf(inv, id) < 0:
      ch.problems.add "repair: no such kit " & id
      return false
    if id == target:
      ch.problems.add "repair: an item cannot repair itself"
      return false
    for used in named:
      if used == id:
        # The same kit named twice would be spent twice off the same reading of
        # its resource, which is a kit that repairs for free.
        ch.problems.add "repair: that kit is named twice in one request"
        return false
    named.add id

  # ---- plan the kits -----------------------------------------------------
  var kitIds: seq[string] = @[]
  var kitLeft: seq[float] = @[]
  var remaining = plan.points
  var achievable = 0.0
  for e in each(kits):
    if remaining <= 0.0:
      break
    var id = e.field("_id").asText("")
    if id.len == 0: id = e.field("Id").asText("")
    if id.len == 0: id = e.field("id").asText("")
    let at = indexOf(inv, id)
    if at < 0:
      ch.problems.add "repair: no such kit " & id
      return false
    let kit = itemAt(inv, at)
    let kitTpl = get(kit, "_tpl").asText("")
    var haveRes = false
    var resource = updFloat(kit, "RepairKit", "Resource", haveRes)
    if not haveRes:
      var haveMax = false
      resource = propFloat(kitTpl, "MaxRepairResource", haveMax)
      if not haveMax:
        ch.problems.add "repair: no charge is known for " & kitTpl
        return false
    if resource <= 0.0:
      ch.problems.add "repair: that kit is used up"
      return false
    var points = resource / perPoint
    if points > remaining:
      points = remaining
    let spend = points * perPoint
    kitIds.add id
    kitLeft.add resource - spend
    achievable = achievable + points
    remaining = remaining - points

  if achievable <= 0.0:
    ch.problems.add "repair: those kits have nothing left in them"
    return false
  plan.points = achievable

  # ---- act ---------------------------------------------------------------
  # The item first, then the kits, and the kits looked up by id rather than by
  # the index the plan recorded: a spent kit is removed and every index after it
  # moves.
  applyPlan(inv, plan, tpl, true, ch)
  var spent: seq[string] = @[]
  for k in 0 ..< kitIds.len:
    let at = indexOf(inv, kitIds[k])
    if at < 0:
      continue
    if kitLeft[k] <= 0.0:
      spent.add kitIds[k]
    else:
      var kit = itemAt(inv, at)
      setUpdFloat(kit, "RepairKit", "Resource", kitLeft[k])
      inv.items.replaceAt(at, text(kit))
      ch.changed.add text(kit)
  for id in spent:
    # A kit used to nothing is gone, like a medkit healed to nothing: left in
    # the stash it is a kit that repairs zero and looks broken.
    discard removeItem(inv, id, ch)
  inv.dirty = true
  result = true

# ---------------------------------------------------------------------------

proc applyRepair*(p: var Profile; inv: var Inventory; kind: RepairAction;
                  action: JsonRef; ch: var Change): bool =
  ## Returns whether the *profile* changed. A kit repair only touches items, so
  ## it returns false and the item list's own `dirty` flag carries the write.
  case kind
  of reTrader: result = doTraderRepair(p, inv, action, ch)
  of reKit:
    discard doKitRepair(p, inv, action, ch)
    result = false
  of reNone: result = false
