## Healing and eating outside a raid.
##
## Two item events -- `Heal` and `Eat` -- and until now neither was handled at
## all, which is a worse failure than it sounds. The client applies a heal to
## its own copy of the profile the instant it is clicked, so a player watches
## their leg go green, plays on, and finds it broken again the next time
## `/client/game/start` hands them the server's copy. The bandage is still in
## the stash too. Nothing errors anywhere.
##
## ## What is the server's and what is the item's
##
## The **amount** is the server's. `OffraidHealRequestData` carries a `count`
## and this server does not believe it any more than it believes a trade's
## count: the restore is bounded by the damage that part has actually taken and
## by the resource the item has actually got left. A client asking to heal 9999
## gets a full part and an item down by exactly what a full part cost.
##
## The **rates** are the item's. A medkit's remaining charge is
## `upd.MedKit.HpResource`, filled from the template's `MaxHpResource` the first
## time it is used. A food item's remaining charge is `upd.FoodDrink.HpPercent`
## against the template's `MaxResource`, and what one unit of it is worth is
## `_props.effects_health.<factor>.value / MaxResource` -- the template's
## `value` is what consuming the *whole* item is worth, which is why it has to
## be divided by the whole item's size to get the value of one sip.
##
## A template the database does not have has neither, and this refuses rather
## than guessing: an unknown medkit that healed for free would be an infinite
## medkit, and on a server with no item table that is every medkit there is.
##
## ## Healing at a trader
##
## `RestoreHealth` is the third event here, and it is the one the player reaches
## for after a bad raid: a fractured leg and twenty hit points, at Therapist.
## `docs/BACKLOG.md` recorded it as blocked on "the treatment price table"; the
## table is in the database and always was, under `globals.config.Health`:
##
## | what | where | live value |
## |---|---|---|
## | a hit point | `HealPrice.HealthPointPrice` | 30 |
## | a point of energy | `HealPrice.EnergyPointPrice` | 0 |
## | a point of hydration | `HealPrice.HydrationPointPrice` | 0 |
## | removing one effect | `Effects.<name>.RemovePrice` | Fracture 1000, LightBleeding 400, HeavyBleeding 1200, BreakPart 1000, Intoxication 42700 |
## | the trader's markup | that trader's `loyaltyLevels[n].heal_price_coef` | Therapist 100 / 110 / 120 / 135; every other trader 0 |
##
## Four things about that are decisions rather than readings, and each is here
## rather than in a commit message:
##
## - **A database with no `HealPrice` refuses.** Free healing is not the same
##   answer as "the price is not known", and free healing removes the whole
##   system — which is the same rule `emu/repair` applies to a template with no
##   `RepairCost` and `emu/trading` applies to selling something the handbook
##   does not price.
## - **An effect with no `RemovePrice` is refused by name.** Five of the
##   effects in a live table carry one; `Contusion`, `Dehydration` and the rest
##   do not, because they are not things a trader treats. Refusing names the
##   effect, so the sentence a player gets is one they can act on.
## - **The coefficient is read as a percentage, exactly as `repair_price_coef`
##   is in `emu/repair` — and its *direction* is *(unverified)*.** Therapist's
##   rises with loyalty (100 → 135) where a discount would fall, and the
##   reference gives the member and not the arithmetic. Read directly it agrees
##   with `repair_price_coef`, whose direction *is* established by Fence's 300;
##   read inverted it would make one member of one object mean the opposite of
##   its neighbour. At loyalty level 1 the coefficient is 100 and the two
##   readings agree exactly, which is where most treatment happens.
## - **The request's `items` — the money stacks the client picked — are not
##   used to price anything.** The reference puts a payment scheme on
##   `HealthTreatmentRequestData`, and believing it would let a client name its
##   own price. The amount is the server's, as it is for `Heal` above: the cost
##   is computed from the table and found in the player's own loose roubles by
##   `spendCurrency`, the same as an `Insure` and a `TraderRepair`.
##
## And one bound that is the module's existing rule applied to a third event:
## **a treatment is priced for the damage that is actually there.** A client
## asking to restore 200 points on a leg missing 40 pays for 40, and an effect
## the profile does not carry is neither charged for nor invented.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import profile
import inventory
import templates
import trading
import traders

type
  HealthAction* = enum
    hxNone, hxHeal, hxEat, hxTreatment

proc healthAction*(name: string): HealthAction =
  case name
  of "Heal": hxHeal
  of "Eat": hxEat
  of "RestoreHealth": hxTreatment
  else: hxNone

proc bodyPartNames(): seq[string] =
  ## The client's own seven, and the only keys `Health.BodyParts` has. A request
  ## naming anything else is refused rather than adding an eighth part the
  ## client cannot draw.
  result = @["Head", "Chest", "Stomach", "LeftArm", "RightArm", "LeftLeg",
             "RightLeg"]

proc isBodyPart(name: string): bool =
  let parts = bodyPartNames()
  for p in parts:
    if p == name:
      return true
  result = false

proc updSub(d: Doc; group, name: string; found: var bool): float =
  ## One number out of `upd.<group>.<name>`, saying whether it was there --
  ## which is the whole question for a resource: absent means "full, from the
  ## template", zero means "empty".
  found = false
  let upd = get(d, "upd")
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

proc setUpdSub(d: var Doc; group, name: string; value: int) =
  var upd = parseObject(getRaw(d, "upd"))
  if not upd.ok:
    upd = newDoc()
  var g = parseObject(getRaw(upd, group))
  if not g.ok:
    g = newDoc()
  setNumber(g, name, value)
  setRaw(upd, group, text(g))
  setRaw(d, "upd", text(upd))

proc doHeal(p: var Profile; inv: var Inventory; action: JsonRef;
            ch: var Change): bool =
  let id = action.field("item").asText("")
  let part = action.field("part").asText("")
  if not isBodyPart(part):
    ch.problems.add "heal: " & part & " is not a body part"
    return false
  let at = indexOf(inv, id)
  if at < 0:
    ch.problems.add "heal: no such item " & id
    return false
  var item = itemAt(inv, at)
  let tpl = get(item, "_tpl").asText("")

  # What the kit has left. Absent means unused, which is the template's full
  # charge -- and a template the database has no charge for is refused, because
  # "unknown" healing for free is an unlimited medkit.
  var haveResource = false
  var resource = int(updSub(item, "MedKit", "HpResource", haveResource))
  if not haveResource:
    let maxRes = itemProp(tpl, "MaxHpResource")
    if not maxRes.ok:
      ch.problems.add "heal: no charge is known for " & tpl
      return false
    resource = maxRes.asInt(0)
  if resource <= 0:
    ch.problems.add "heal: that is used up"
    return false

  let partPath = "Health.BodyParts." & part & ".Health"
  let current = p.field(partPath & ".Current").asInt(0)
  let maximum = p.field(partPath & ".Maximum").asInt(0)
  if maximum <= 0:
    ch.problems.add "heal: this profile has no " & part
    return false
  let missing = maximum - current
  if missing <= 0:
    ch.problems.add "heal: " & part & " is not damaged"
    return false

  var restore = action.field("count").asInt(missing)
  if restore <= 0 or restore > missing:
    restore = missing
  if restore > resource:
    restore = resource

  setNumber(p, partPath & ".Current", current + restore)

  let left = resource - restore
  if left <= 0:
    # A kit used to nothing is gone. Left in the stash it is a kit that heals
    # zero and cannot be thrown away without the player wondering why.
    if not removeItem(inv, id, ch):
      return false
  else:
    setUpdSub(item, "MedKit", "HpResource", left)
    inv.items.replaceAt(at, text(item))
    inv.dirty = true
    ch.changed.add text(item)
  result = true

proc doEat(p: var Profile; inv: var Inventory; action: JsonRef;
           ch: var Change): bool =
  let id = action.field("item").asText("")
  let at = indexOf(inv, id)
  if at < 0:
    ch.problems.add "eat: no such item " & id
    return false
  var item = itemAt(inv, at)
  let tpl = get(item, "_tpl").asText("")

  let maxRes = itemProp(tpl, "MaxResource")
  if not maxRes.ok or maxRes.asInt(0) <= 0:
    ch.problems.add "eat: no size is known for " & tpl
    return false
  let whole1 = maxRes.asInt(0)

  var haveResource = false
  var resource = int(updSub(item, "FoodDrink", "HpPercent", haveResource))
  if not haveResource:
    resource = whole1
  if resource <= 0:
    ch.problems.add "eat: that is finished"
    return false

  var take = action.field("count").asInt(resource)
  if take <= 0 or take > resource:
    take = resource

  # `effects_health.<factor>.value` is what the *whole* item is worth, so one
  # unit is worth `value / MaxResource` and `take` units are worth that times
  # `take`. Multiplied before dividing, so a bottle worth 60 hydration in 60
  # units does not round every sip to zero.
  #
  # Only Hydration and Energy are applied. `effects_health` can also carry
  # Health, Temperature, Poisoning and Radiation; those are timed effects with a
  # `delay` and a `duration` this server has nowhere to run, and applying their
  # `value` as an instant change would be inventing a meaning the reference does
  # not give them.
  let factors = @["Hydration", "Energy"]
  for factor in factors:
    let v = itemProp(tpl, "effects_health." & factor & ".value")
    if not v.ok:
      continue
    let perWhole = v.asInt(0)
    if perWhole == 0:
      continue
    let gain = (perWhole * take) div whole1
    if gain == 0:
      continue
    let current = p.field("Health." & factor & ".Current").asInt(0)
    let maximum = p.field("Health." & factor & ".Maximum").asInt(0)
    var now1 = current + gain
    if maximum > 0 and now1 > maximum:
      now1 = maximum
    if now1 < 0:
      now1 = 0
    setNumber(p, "Health." & factor & ".Current", now1)

  let left = resource - take
  if left <= 0:
    if not removeItem(inv, id, ch):
      return false
  else:
    setUpdSub(item, "FoodDrink", "HpPercent", left)
    inv.items.replaceAt(at, text(item))
    inv.dirty = true
    ch.changed.add text(item)
  result = true

# ---------------------------------------------------------------------------
# Healing at a trader
# ---------------------------------------------------------------------------

proc ceilInt(v: float): int =
  ## Rounded up, so a price of 0.2 roubles is 1 rather than free. A treatment
  ## that rounds to nothing is a treatment the player got for nothing.
  result = int(v)
  if float(result) < v:
    inc result

proc healthConfigJson*(): string =
  ## `globals.config.Health`, or empty. Empty is a refusal at every call site
  ## rather than a default price: see the header.
  let v = dbRead("globals.config.Health")
  if v.ok and v.raw.len > 0:
    return v.raw
  result = ""

proc healPriceCoefficient*(traderId: string; level: int): float =
  ## The loyalty level's `heal_price_coef`, as a percentage, with the same
  ## shape and the same fallback as `repairPriceCoefficient` in `emu/repair`.
  ##
  ## **Zero means "not named", not "free".** Every trader but Therapist has a
  ## literal 0 on every one of its loyalty rows in live data, because none of
  ## them heals; a zero taken as a multiplier would make healing at Prapor cost
  ## nothing rather than cost the table's price. So a coefficient that is not a
  ## positive number reads as 100 -- full price -- which is also what a trader
  ## base with no coefficients at all means.
  let base = traderBase(traderId)
  if base.len == 0:
    return 100.0
  let levels = each(field(base, "loyaltyLevels"))
  var index = 0
  for l in levels:
    inc index
    if index != level:
      continue
    var c = l.field("heal_price_coef")
    if not c.found:
      # The reference's property spelling, in case a database was written from
      # it rather than from the game's own dump. *(unverified)*
      c = l.field("HealPriceCoefficient")
    if c.found:
      let r = c.asFloat(0.0)
      if r > 0.0:
        return r
    return 100.0
  result = 100.0

proc treatmentCost*(healthConfigJson: string;
                    healthPoints, energyPoints, hydrationPoints: int;
                    effectNames: seq[string]; coefficientPercent: float;
                    problem: var string): int =
  ## What one treatment costs, out of `globals.config.Health` and nothing else.
  ##
  ## Pure on purpose: it takes the price table as text rather than reading the
  ## database, so `selfCheckHealth` below can price a treatment against a
  ## literal without a server, a profile or a database under it -- which is the
  ## only way to pin arithmetic that a route would otherwise hide behind a
  ## loaded 40 MB dump.
  ##
  ## `problem` non-empty is a refusal and the return is meaningless. There is no
  ## "0" that means free: a price the table does not give is refused.
  problem = ""
  if healthConfigJson.len == 0:
    problem = "this server's database has no healing prices " &
              "(globals.config.Health); healing at a trader is refused " &
              "rather than given away"
    return 0
  let cfg = whole(healthConfigJson)
  var total = 0.0

  # Three point prices, each only consulted when something of that kind is
  # actually being restored -- a database that prices hit points and not
  # hydration must still be able to heal a leg.
  if healthPoints > 0:
    let v = cfg.field("HealPrice.HealthPointPrice")
    if not v.found:
      problem = "this server's database does not price a hit point " &
                "(globals.config.Health.HealPrice.HealthPointPrice)"
      return 0
    total = total + v.asFloat(0.0) * float(healthPoints)
  if energyPoints > 0:
    let v = cfg.field("HealPrice.EnergyPointPrice")
    if not v.found:
      problem = "this server's database does not price a point of energy " &
                "(globals.config.Health.HealPrice.EnergyPointPrice)"
      return 0
    total = total + v.asFloat(0.0) * float(energyPoints)
  if hydrationPoints > 0:
    let v = cfg.field("HealPrice.HydrationPointPrice")
    if not v.found:
      problem = "this server's database does not price a point of hydration " &
                "(globals.config.Health.HealPrice.HydrationPointPrice)"
      return 0
    total = total + v.asFloat(0.0) * float(hydrationPoints)

  for e in effectNames:
    if e.len == 0:
      continue
    let v = cfg.field("Effects." & e & ".RemovePrice")
    if not v.found:
      # Named, so the sentence the player gets says which one. A live table
      # prices five effects; the rest are not things a trader treats.
      problem = "this trader does not treat " & e
      return 0
    total = total + v.asFloat(0.0)

  var coefficient = coefficientPercent
  if coefficient <= 0.0:
    coefficient = 100.0
  result = ceilInt(total * coefficient / 100.0)
  if result < 0:
    result = 0

proc partEffects(p: Profile; part: string): Doc =
  ## `Health.BodyParts.<part>.Effects`, the reference's `Dictionary<String,
  ## Int32>`. An absent key is an empty document rather than a failure: a
  ## profile that has never been in a raid has no effects at all.
  let raw = p.field("Health.BodyParts." & part & ".Effects").raw()
  if raw.len == 0:
    return newDoc()
  result = parseObject(raw)
  if not result.ok:
    result = newDoc()

proc doTreatment(p: var Profile; inv: var Inventory; action: JsonRef;
                 ch: var Change): bool =
  ## `RestoreHealth`: the whole of what a visit to Therapist does.
  ##
  ## Plan, verify, then take -- the same three phases as every other payment in
  ## this emulator, and for the same reason: there is no transaction to roll
  ## back, so a treatment that half-applied would be a player charged for a leg
  ## that is still broken.
  var traderId = action.field("tid").asText("")
  if traderId.len == 0: traderId = action.field("trader").asText("")
  if traderId.len == 0: traderId = action.field("Trader").asText("")
  if traderId.len == 0:
    ch.problems.add "treatment: the request names no trader"
    return false
  if traderBase(traderId).len == 0:
    ch.problems.add "treatment: there is no trader " & traderId
    return false

  var diff = action.field("difference")
  if not diff.found:
    diff = action.field("Difference")
  if not diff.found:
    ch.problems.add "treatment: the request names nothing to treat"
    return false

  # ---- plan: nothing is written and nothing is paid ----------------------
  var parts: seq[string] = @[]
  var points: seq[int] = @[]
  var effectParts: seq[string] = @[]
  var effectNames: seq[string] = @[]
  var healthPoints = 0

  let bodyParts = diff.field("BodyParts")
  if bodyParts.found:
    let named = keys(bodyParts)
    for part in named:
      if not isBodyPart(part):
        # Refused rather than skipped: an eighth body part is a client this
        # server does not understand, and quietly treating six of seven is a
        # bill the player cannot reconcile with what they clicked.
        ch.problems.add "treatment: " & part & " is not a body part"
        return false
      let entry = bodyParts.field(part)
      let current = p.field("Health.BodyParts." & part &
                            ".Health.Current").asInt(0)
      let maximum = p.field("Health.BodyParts." & part &
                            ".Health.Maximum").asInt(0)
      if maximum <= 0:
        ch.problems.add "treatment: this profile has no " & part
        return false
      var asked = int(entry.field("Health").asFloat(0.0))
      let missing = maximum - current
      # The client's figure is an upper bound and the damage is the other one.
      # A client asking for 200 on a leg missing 40 pays for 40.
      if asked < 0: asked = 0
      if asked > missing: asked = missing
      if asked > 0:
        parts.add part
        points.add asked
        healthPoints = healthPoints + asked

      # Only effects the profile actually carries are charged for and removed.
      # An effect the client thinks is there and the server does not is already
      # in the state the player asked for, so there is nothing to bill.
      let have = partEffects(p, part)
      let wanted = entry.field("Effects")
      if wanted.found:
        for w in each(wanted):
          let name = w.asText("")
          if name.len == 0 or not has(have, name):
            continue
          var seen = false
          for k in 0 ..< effectNames.len:
            if effectNames[k] == name and effectParts[k] == part:
              seen = true
          if seen:
            continue
          effectParts.add part
          effectNames.add name

  var energy = int(diff.field("Energy").asFloat(0.0))
  if energy < 0: energy = 0
  let energyNow = p.field("Health.Energy.Current").asInt(0)
  let energyMax = p.field("Health.Energy.Maximum").asInt(0)
  if energyMax > 0 and energy > energyMax - energyNow:
    energy = energyMax - energyNow
  if energy < 0: energy = 0

  var hydration = int(diff.field("Hydration").asFloat(0.0))
  if hydration < 0: hydration = 0
  let hydrationNow = p.field("Health.Hydration.Current").asInt(0)
  let hydrationMax = p.field("Health.Hydration.Maximum").asInt(0)
  if hydrationMax > 0 and hydration > hydrationMax - hydrationNow:
    hydration = hydrationMax - hydrationNow
  if hydration < 0: hydration = 0

  if healthPoints == 0 and energy == 0 and hydration == 0 and
     effectNames.len == 0:
    ch.problems.add "treatment: nothing on this profile needs treating"
    return false

  var problem = ""
  let level = loyaltyOf(p, traderId)
  let total = treatmentCost(healthConfigJson(), healthPoints, energy,
                            hydration, effectNames,
                            healPriceCoefficient(traderId, level), problem)
  if problem.len > 0:
    ch.problems.add "treatment: " & problem
    return false

  # ---- act ---------------------------------------------------------------
  # Charged in roubles whatever the trader's own `currency` says, for the same
  # reason `emu/repair` gives: the only rate in this database prices a stack of
  # notes rather than an exchange. `spendCurrency` verifies the whole amount is
  # present before it takes any of it.
  if not spendCurrency(inv, trading.Roubles, total, p.stashId, ch):
    return false

  for k in 0 ..< parts.len:
    let path = "Health.BodyParts." & parts[k] & ".Health.Current"
    setNumber(p, path, p.field(path).asInt(0) + points[k])
  for k in 0 ..< effectParts.len:
    var have = partEffects(p, effectParts[k])
    remove(have, effectNames[k])
    setRaw(p, "Health.BodyParts." & effectParts[k] & ".Effects", text(have))
  if energy > 0:
    setNumber(p, "Health.Energy.Current", energyNow + energy)
  if hydration > 0:
    setNumber(p, "Health.Hydration.Current", hydrationNow + hydration)

  # Money paid to a trader is turnover with that trader, the same as a purchase
  # or a repair, and it is what moves the loyalty level.
  addSalesSum(p, traderId, total)
  result = true

# ---------------------------------------------------------------------------
# The self-check
# ---------------------------------------------------------------------------

proc selfCheckHealth*(into: var seq[string]): bool =
  ## Prices treatments against a literal price table, with no server under it.
  ##
  ## Runs at load through `emu/selfchecks`, so a defect in this arithmetic is a
  ## mod that refuses to serve rather than one that quietly overcharges. What is
  ## checked is the arithmetic and the refusals, not that a proc exists.
  let before = into.len
  # A cut-down `globals.config.Health` with the live figures in it.
  let cfg = "{\"HealPrice\":{\"EnergyPointPrice\":2,\"HealthPointPrice\":30," &
            "\"HydrationPointPrice\":3}," &
            "\"Effects\":{\"Fracture\":{\"RemovePrice\":1000}," &
            "\"LightBleeding\":{\"RemovePrice\":400}," &
            "\"Dehydration\":{\"DefaultDelay\":50}}}"
  var problem = ""
  var none: seq[string] = @[]

  # 40 hit points at 30 each, at full price.
  if treatmentCost(cfg, 40, 0, 0, none, 100.0, problem) != 1200 or
     problem.len > 0:
    into.add "health: 40 points at 30 should be 1200"
  # The coefficient is a percentage: 1200 at 135% is 1620.
  if treatmentCost(cfg, 40, 0, 0, none, 135.0, problem) != 1620:
    into.add "health: 40 points at 30 and 135% should be 1620"
  # A coefficient that is not a positive number is "not named", not "free".
  if treatmentCost(cfg, 1, 0, 0, none, 0.0, problem) != 30:
    into.add "health: a zero coefficient must read as full price"
  # Rounded up, so a fraction of a rouble is not free.
  if treatmentCost(cfg, 1, 0, 0, none, 101.0, problem) != 31:
    into.add "health: a part-rouble price must round up"
  # Effects are added to the points, not charged instead of them.
  var two: seq[string] = @["Fracture", "LightBleeding"]
  if treatmentCost(cfg, 10, 0, 0, two, 100.0, problem) != 1700 or
     problem.len > 0:
    into.add "health: 10 points plus a fracture and a light bleed is 1700"
  # Energy and hydration are priced separately and only when asked for.
  if treatmentCost(cfg, 0, 10, 10, none, 100.0, problem) != 50:
    into.add "health: 10 energy at 2 and 10 hydration at 3 is 50"
  # An effect the table does not price is refused by name rather than freed.
  var untreatable: seq[string] = @["Dehydration"]
  discard treatmentCost(cfg, 0, 0, 0, untreatable, 100.0, problem)
  if problem.len == 0 or find(problem, "Dehydration") < 0:
    into.add "health: an effect with no RemovePrice must be refused by name"
  # No table at all is a refusal, not free healing.
  discard treatmentCost("", 10, 0, 0, none, 100.0, problem)
  if problem.len == 0:
    into.add "health: an absent price table must refuse"
  # A table that prices nothing must refuse rather than charge nothing.
  discard treatmentCost("{\"HealPrice\":{}}", 10, 0, 0, none, 100.0, problem)
  if problem.len == 0:
    into.add "health: a table with no hit-point price must refuse"
  # Asking for nothing costs nothing and is not an error -- the caller has
  # already refused an empty request before it gets here.
  if treatmentCost(cfg, 0, 0, 0, none, 100.0, problem) != 0 or problem.len > 0:
    into.add "health: an empty treatment costs nothing"
  result = into.len == before

proc applyHealth*(p: var Profile; inv: var Inventory; kind: HealthAction;
                  action: JsonRef; ch: var Change): bool =
  ## Returns whether the profile changed. All three of these always change it
  ## when they succeed -- that is the point of them.
  case kind
  of hxHeal: result = doHeal(p, inv, action, ch)
  of hxEat: result = doEat(p, inv, action, ch)
  of hxTreatment: result = doTreatment(p, inv, action, ch)
  of hxNone: result = false
