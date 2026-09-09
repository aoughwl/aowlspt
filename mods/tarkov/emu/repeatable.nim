## Repeatable quests: the dailies, the weekly, and the scav's one.
##
## These are not a route this server was missing. They are a **generator**: the
## real server builds a quest per day per trader out of a template, a pool of
## targets and a reward budget, and answers `/client/repeatalbeQuests/
## activityPeriods` with the result. Until now that route answered an empty
## list, which the client draws as "no dailies", because none of the three
## tables the generator needs were in the database `aowl importdb` produced.
##
## They are now. `aowl importdb` brings across two sections, and this module
## reads both and nothing else:
##
## | read from | what is in it |
## |---|---|
## | `templates.repeatableQuests` | one **quest skeleton** per type (`Elimination`, `Completion`, `Exploration`, `Pickup`) with its conditions already shaped the way the client parses them, the `changeCost` and `changeStandingCost` a reroll costs, and `data.<type>.itemsWhitelist` -- the Completion target pool, banded by player level |
## | `configs.quest.repeatableQuests` | the three **sets** -- `Daily`, `Weekly`, `Daily_Savage` -- each with `resetTime`, `numQuests`, `minPlayerLevel`, the `traderWhitelist` saying which traders offer which types, `rewardScaling` (the reward budget, banded by level) and `questConfig` (the per-type level bands that size a quest's targets) |
##
## Neither is invented and neither is a fixture: both come out of a real SPT
## install, and `docs/IMPORTDB.md` says where. **Where the data does not decide
## something, this file says so in a comment rather than making a rule up** --
## there are four such places and they are all marked.
##
## ## Nothing is stored that can be derived
##
## A set's quests are a pure function of `(profile id, set name, period)`, where
## the period is `now div resetTime`. There is no "today's dailies" record to
## write, to migrate, or to lose: the same request answers the same three quests
## for the whole day, a restart in the middle of the day changes nothing, and
## the day after tomorrow's are as computable as today's. It is the same
## reasoning `emu/production` uses for a craft's progress -- derived from a
## timestamp rather than counted -- and it has the same payoff: a server that
## was switched off for a week comes back agreeing with one that was not.
##
## The **one** thing that cannot be derived is a reroll, because it is a choice
## the player made. `repeat.<profile id>` holds, per set, the period it is about
## and how many times each slot has been rerolled; the slot's seed includes that
## count, so a reroll produces a different quest and the same different quest
## every time afterwards. The record is a handful of integers and it is thrown
## away as soon as the period it names has passed.
##
## ## What is generated, and what is deliberately not
##
## - **Elimination**: kill *n* of a target drawn from the level band's weighted
##   `targets` list, optionally on a named map (`specificLocationChance`) and
##   optionally into a named body part (`bodyPartChance`). The count comes from
##   `minKills`/`maxKills`, or `minPmcKills`/`maxPmcKills` for a PMC target, or
##   `minBossKills`/`maxBossKills` for a boss -- the band names all three pairs.
## - **Completion**: hand over *n* of an item drawn from
##   `data.Completion.itemsWhitelist` for the player's level, with *n* from the
##   band's `requestedItemCount`.
## - **Exploration**: extract *n* times, from the band's `minExtracts`/
##   `maxExtracts`, optionally from a named map.
## - **Pickup** is **not** generated. Its band is `ItemTypeToFetchWithMaxCount`,
##   a list of *handbook categories* with counts, and turning a category into a
##   pool of item templates means walking the handbook tree for every template
##   in the game on every request. It is only in the scav set, whose `types`
##   list this server therefore reads as its other three. Named here rather
##   than left to be found.
##
## Three qualifiers the band offers are read and **not applied**, and the reason
## is this server's own evaluator: `questcond.killCredit` refuses to credit a
## kill carrying a qualifier it cannot check -- a weapon, a distance, a time of
## day -- because crediting one hands out progress that was not earned. So
## `weaponRequirementChance`, `weaponCategoryRequirementChance` and `distProb`
## would generate a quest whose only route to completion is the client's own
## counter agreeing with it. The two qualifiers the evaluator *can* check --
## `bodyPart` and `Location` -- are applied.
##
## ## The reward budget is the config's, in the currency the config states it in
##
## `rewardScaling` gives, per level band: `experience`, `roubles`, `reputation`,
## `items`, `gpCoins`, and a `rewardSpread`. The first three are paid. The last
## two are not:
##
## - `items` is a **count** of item rewards and the config does not say what
##   they are worth, nor how much of the rouble budget they replace. Paying
##   *n* items on top of the full rouble figure would be a repeatable quest
##   worth more than the config says; taking a guess at the split would be a
##   number nobody can check. So the budget is paid in roubles, whole.
## - `gpCoins` names a currency this server has no other dealing with.
##
## `rewardSpread` is read as a **fraction either way** -- a spread of 0.25 pays
## between 75% and 125% of the band's figure. The config gives the number and
## not its units; this reading is the one that makes 0 mean "exactly the
## figure", which is the only reading that degrades sensibly. *(unverified)*
##
## And the bands themselves **step** rather than interpolate: `levels` is a list
## of points and the config says nothing about the curve between them, so a
## level 17 player gets the level 10 row. A player at exactly a band's level
## gets that band.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import numbers
import profile
import inventory
import trading
import traders
import store
import rand

const
  KeyPrefix* = "repeat."
  MaxSlots = 16
    ## A bound on `numQuests`, so that a config naming a thousand cannot make
    ## one request build a thousand quests. The real sets ask for three and one.

proc repeatKey*(profileId: string): string = KeyPrefix & profileId

# ---------------------------------------------------------------------------
# The two tables
# ---------------------------------------------------------------------------

proc setsTable*(): string =
  ## `configs.quest.repeatableQuests` -- the three sets. Empty when the
  ## database has no import of it, and every route below then behaves exactly
  ## as it did before this module existed: an empty activity list, which the
  ## client draws as "no dailies".
  let v = dbRead("configs.quest.repeatableQuests")
  if v.ok and v.raw.len > 0:
    return v.raw
  result = ""

proc skeletonFor*(kind: string): string =
  ## `templates.repeatableQuests.templates.<kind>` -- the quest as BSG shapes
  ## it, conditions and all. This generator edits a copy of it rather than
  ## building a quest from nothing, because the client parses these and the
  ## members it needs are the ones already on the skeleton.
  let v = dbRead("templates.repeatableQuests.templates." & kind)
  if v.ok and v.raw.len > 0:
    return v.raw
  result = ""

proc completionPool*(level: int): seq[string] =
  ## `templates.repeatableQuests.data.Completion.itemsWhitelist`, flattened to
  ## the templates a player of this level may be asked for. Each band carries a
  ## `minPlayerLevel` and the bands are cumulative -- a level 40 player may be
  ## asked for anything in the level 1, 15, 25 and 40 bands, which is what makes
  ## the pool grow with the character rather than move.
  result = @[]
  let v = dbRead("templates.repeatableQuests.data.Completion.itemsWhitelist")
  if not v.ok or v.raw.len == 0:
    return
  let bands = each(whole(v.raw))
  for b in bands:
    if b.field("minPlayerLevel").asInt(1) > level:
      continue
    let ids = each(b.field("itemIds"))
    for id in ids:
      let tpl = id.asText("")
      if tpl.len > 0:
        result.add tpl

# ---------------------------------------------------------------------------
# Bands and weighted picks
# ---------------------------------------------------------------------------

proc bandFor(bands: JsonRef; level: int): JsonRef =
  ## The `questConfig.<type>` entry whose `levelRange` holds this level.
  ##
  ## Not found rather than the first entry when nothing matches: sizing a
  ## quest off a band that does not apply to the player is how a level 5
  ## character is asked for four PMC kills, and "the config does not cover this
  ## level" has to be a refusal rather than a default.
  result = notFound()
  if not bands.found:
    return
  let list = each(bands)
  for b in list:
    let lo = b.field("levelRange.min").asInt(0)
    let hi = b.field("levelRange.max").asInt(0)
    if level >= lo and level <= hi:
      return b
  result = notFound()

proc rowFor(scaling: JsonRef; name: string; level: int; fallback: float): float =
  ## One figure out of `rewardScaling`, taken from the highest `levels` entry
  ## that is not above the player. See the header: the config gives points and
  ## not a curve, so this steps.
  let levels = each(scaling.field("levels"))
  let row = each(scaling.field(name))
  if levels.len == 0 or row.len == 0:
    return fallback
  var best = -1
  for i in 0 ..< levels.len:
    if levels[i].asInt(0) <= level:
      best = i
  if best < 0:
    # Below the first band. The set's own `minPlayerLevel` should already have
    # refused this player, so reaching here means a config whose two gates
    # disagree; the lowest row is the answer that is never a payout the config
    # did not name.
    best = 0
  if best >= row.len:
    best = row.len - 1
  result = row[best].asFloat(fallback)

proc pickKeyed(entries: seq[JsonRef]; r: var Rng; picked: var JsonRef): bool =
  ## One entry of a `[{key, relativeProbability, data}]` list, in proportion to
  ## `relativeProbability`. False when every weight is zero -- and there are
  ## plenty of those: every boss in the Daily band is weighted 0, which means
  ## "not in this set" and not "as likely as the others".
  picked = notFound()
  var weights: seq[float] = @[]
  for e in entries:
    weights.add e.field("relativeProbability").asFloat(0.0)
  let at = pickWeighted(r, weights)
  if at < 0:
    return false
  picked = entries[at]
  result = true

proc between(r: var Rng; lo, hi: int): int =
  ## An integer in `[lo, hi]`, inclusive at both ends because that is how the
  ## config's `min`/`max` pairs read: `minKills: 2, maxKills: 4` is a quest for
  ## two, three or four.
  if hi <= lo:
    return lo
  result = lo + nextInt(r, hi - lo + 1)

# ---------------------------------------------------------------------------
# Building one quest
# ---------------------------------------------------------------------------

proc questId(r: var Rng): string =
  ## The quest's own id, out of the seeded stream rather than `emu/ids.newId`.
  ##
  ## This is the whole reason the set can be derived instead of stored: the id
  ## is a function of the seed, so the quest the client accepted this morning
  ## has the same id this afternoon, and `Quests` in the profile -- which
  ## records progress by `qid` -- still points at something this module can
  ## produce a template for.
  result = mongoId(r)

proc rewardsFor(setJson: JsonRef; traderId: string; level: int;
                r: var Rng): string =
  ## The `rewards.Success` array: experience, roubles and standing, each the
  ## band's figure moved by the spread.
  let scaling = setJson.field("rewardScaling")
  let spread = scaling.field("rewardSpread").asFloat(0.0)
  # One draw, applied to all three, so a generous daily is generous in every
  # currency rather than three independent rolls that average out to the middle
  # every time.
  var factor = 1.0
  if spread > 0.0:
    factor = 1.0 - spread + nextFloat(r) * spread * 2.0

  var list = newList()
  var index = 0

  let experience = int(rowFor(scaling, "experience", level, 0.0) * factor)
  if experience > 0:
    var d = newDoc()
    setText(d, "id", mongoId(r))
    setNumber(d, "index", index)
    setText(d, "type", "Experience")
    setNumber(d, "value", experience)
    list.add d
    inc index

  let roubles = int(rowFor(scaling, "roubles", level, 0.0) * factor)
  if roubles > 0:
    # An `Item` reward is a list of item documents, exactly as a hand-written
    # quest template writes one, because `quests.grantRewardList` re-ids that
    # list and posts it. Building it any other way would need a second payout
    # path, and a second payout path is a second place for the next reward kind
    # to be forgotten.
    var money = newDoc()
    setText(money, "_id", mongoId(r))
    setText(money, "_tpl", trading.Roubles)
    var upd = newDoc()
    setNumber(upd, "StackObjectsCount", roubles)
    setRaw(money, "upd", text(upd))
    var items = newList()
    items.add money
    var d = newDoc()
    setText(d, "id", mongoId(r))
    setNumber(d, "index", index)
    setText(d, "type", "Item")
    setNumber(d, "value", roubles)
    setRaw(d, "items", text(items))
    list.add d
    inc index

  let standing = rowFor(scaling, "reputation", level, 0.0) * factor
  if standing > 0.0 and traderId.len > 0:
    var d = newDoc()
    setText(d, "id", mongoId(r))
    setNumber(d, "index", index)
    setText(d, "type", "TraderStanding")
    setText(d, "target", traderId)
    setRaw(d, "value", numText(standing))
    list.add d
    inc index

  result = text(list)

proc locationPool(setJson: JsonRef): seq[string] =
  ## The maps a quest may name, out of the set's own `locations` map. Each key
  ## is a quest location and its value is the list of raid maps that count as
  ## it -- `factory4_day` covers the night version too -- and the raid result
  ## reports one of those, so the *values* are what a condition must list.
  ##
  ## `any` is skipped: a condition naming it restricts nothing, and this
  ## generator's choice is between "no location condition" and "a real one".
  result = @[]
  let node = setJson.field("locations")
  if not node.found or not isObject(node):
    return
  let names = keys(node)
  for n in names:
    if n == "any":
      continue
    result.add n

proc locationTargets(setJson: JsonRef; name: string): seq[string] =
  result = @[]
  let list = each(setJson.field("locations").field(name))
  for e in list:
    let m = e.asText("")
    if m.len > 0:
      result.add m

proc stringList(values: seq[string]): string =
  var l = newList()
  for v in values:
    l.add quoted(v)
  result = text(l)

proc locationCondition(r: var Rng; setJson: JsonRef; chancePct: int;
                       mapName: var string): string =
  ## A `Location` sub-condition, or "" for a quest that is not tied to a map.
  mapName = ""
  if chancePct <= 0:
    return ""
  if not chance(r, float(chancePct) / 100.0):
    return ""
  let pool = locationPool(setJson)
  if pool.len == 0:
    return ""
  mapName = pool[nextInt(r, pool.len)]
  let targets = locationTargets(setJson, mapName)
  if targets.len == 0:
    mapName = ""
    return ""
  var d = newDoc()
  setText(d, "id", mongoId(r))
  setText(d, "conditionType", "Location")
  setRaw(d, "target", stringList(targets))
  result = text(d)

proc counterCondition(r: var Rng; kind, subs: string; value: int): string =
  ## The `CounterCreator` wrapper every one of these quests finishes with. The
  ## shape is the skeleton's own -- `questcond.subConditions` reads
  ## `counter.conditions`, and `advanceQuestsAfterRaid` reads `id` as the key
  ## `TaskConditionCounters` is written under.
  var counter = newDoc()
  setText(counter, "id", mongoId(r))
  setRaw(counter, "conditions", subs)
  var d = newDoc()
  setText(d, "id", mongoId(r))
  setNumber(d, "index", 0)
  setText(d, "parentId", "")
  setBool(d, "dynamicLocale", false)
  setRaw(d, "visibilityConditions", "[]")
  setText(d, "globalQuestCounterId", "")
  setNumber(d, "value", value)
  setText(d, "type", kind)
  setBool(d, "oneSessionOnly", false)
  setNumber(d, "completeInSeconds", 0)
  setBool(d, "doNotResetIfCounterCompleted", false)
  setRaw(d, "counter", text(counter))
  setText(d, "conditionType", "CounterCreator")
  result = text(d)

proc eliminationFinish(r: var Rng; setJson, band: JsonRef;
                       description: var string): string =
  ## Kill *n* of something. "" when the band names no target that can be drawn,
  ## which is a config this generator will not guess around.
  description = ""
  var target = notFound()
  if not pickKeyed(each(band.field("targets")), r, target):
    return ""
  let who = target.field("key").asText("")
  if who.len == 0:
    return ""

  # The band names three count ranges and which one applies is decided by the
  # target's own `data` flags, which is the only thing in the config that
  # distinguishes them.
  var lo = band.field("minKills").asInt(1)
  var hi = band.field("maxKills").asInt(1)
  if target.field("data.isBoss").asBool(false):
    lo = band.field("minBossKills").asInt(lo)
    hi = band.field("maxBossKills").asInt(hi)
  elif target.field("data.isPmc").asBool(false):
    lo = band.field("minPmcKills").asInt(lo)
    hi = band.field("maxPmcKills").asInt(hi)
  let count = between(r, lo, hi)

  var kills = newDoc()
  setText(kills, "id", mongoId(r))
  setText(kills, "target", who)
  setText(kills, "compareMethod", ">=")
  setNumber(kills, "value", 1)
  setText(kills, "conditionType", "Kills")
  # A body part, when the band's chance says so. This one is applied because
  # `questcond.killCredit` checks it against the victim's own `BodyPart`; the
  # weapon and distance qualifiers beside it in the band are not, and the
  # header says why.
  var partName = ""
  let partChance = band.field("bodyPartChance").asInt(0)
  if partChance > 0 and chance(r, float(partChance) / 100.0):
    var chosenPart = notFound()
    if pickKeyed(each(band.field("bodyParts")), r, chosenPart):
      var names: seq[string] = @[]
      let data = each(chosenPart.field("data"))
      for e in data:
        let n = e.asText("")
        if n.len > 0:
          names.add n
      if names.len > 0:
        setRaw(kills, "bodyPart", stringList(names))
        partName = chosenPart.field("key").asText("")

  var subs = newList()
  subs.add kills
  var mapName = ""
  let where = locationCondition(r, setJson,
                                band.field("specificLocationChance").asInt(0),
                                mapName)
  if where.len > 0:
    subs.add where

  description = "eliminate " & $count & " " & who &
                (if mapName.len > 0: " on " & mapName else: "") &
                (if partName.len > 0: " with a hit to the " & partName
                 else: "")
  var finish = newList()
  finish.add counterCondition(r, "Elimination", text(subs), count)
  result = text(finish)

proc explorationFinish(r: var Rng; setJson, band: JsonRef;
                       description: var string): string =
  ## Extract *n* times, optionally from one map.
  description = ""
  let lo = band.field("minExtracts").asInt(1)
  let hi = band.field("maxExtracts").asInt(lo)
  let count = between(r, lo, hi)
  if count <= 0:
    return ""

  var exit1 = newDoc()
  setText(exit1, "id", mongoId(r))
  setRaw(exit1, "status", "[\"Survived\"]")
  setText(exit1, "conditionType", "ExitStatus")
  var subs = newList()
  subs.add exit1
  var mapName = ""
  # The band's `specificExits.chance` is about naming an *exit point*, which
  # this server is never told about -- `EMULATOR-COVERAGE.md` says exit points
  # come out of the client's own bundles. It is reused here as the chance of
  # naming a *map*, which is the part of the same restriction this server can
  # actually check, and that substitution is a reading rather than the config's
  # own rule. *(unverified)*
  let where = locationCondition(r, setJson,
                                band.field("specificExits.chance").asInt(0),
                                mapName)
  if where.len > 0:
    subs.add where

  description = "extract " & $count & " time(s)" &
                (if mapName.len > 0: " from " & mapName else: "")
  var finish = newList()
  finish.add counterCondition(r, "Completion", text(subs), count)
  result = text(finish)

proc completionFinish(r: var Rng; band: JsonRef; level: int;
                      description: var string): string =
  ## Hand over *n* of one item from the level's pool.
  ##
  ## One template rather than the band's `uniqueItemCount` of them: a
  ## `HandoverItem` condition names one target, and `emu/quests` credits a
  ## handover against one condition id. A second item would be a second
  ## condition, which the client draws and this server would then have to
  ## credit separately -- correct, and a bigger change than this pass.
  ## *(deliberate)*
  description = ""
  let pool = completionPool(level)
  if pool.len == 0:
    return ""
  let tpl = pool[nextInt(r, pool.len)]
  let lo = band.field("requestedItemCount.min").asInt(1)
  let hi = band.field("requestedItemCount.max").asInt(lo)
  let count = between(r, lo, hi)
  if count <= 0:
    return ""

  var d = newDoc()
  setText(d, "id", mongoId(r))
  setNumber(d, "index", 0)
  setText(d, "parentId", "")
  setBool(d, "dynamicLocale", false)
  setRaw(d, "visibilityConditions", "[]")
  setText(d, "globalQuestCounterId", "")
  setRaw(d, "target", stringList(@[tpl]))
  setNumber(d, "value", count)
  setNumber(d, "minDurability", 0)
  setNumber(d, "maxDurability", 100)
  setNumber(d, "dogtagLevel", 0)
  # `requiredItemsAreFiR` is in the band and is **not** written as
  # `onlyFoundInRaid: true`. Nothing in this server marks an item found-in-raid
  # -- there is no `upd.SpawnedInSession` anywhere in it -- so a condition
  # demanding it would be one no handover could ever satisfy.
  setBool(d, "onlyFoundInRaid", false)
  setBool(d, "isEncoded", false)
  setBool(d, "countInRaid", false)
  setText(d, "conditionType", "HandoverItem")

  description = "hand over " & $count & " of " & tpl
  var finish = newList()
  finish.add d
  result = text(finish)

proc buildQuest(setJson: JsonRef; kind, traderId: string; level, endTime: int;
                seed: string; groupName: string): string =
  ## One repeatable quest, whole. "" when the tables cannot produce one, which
  ## the caller must treat as "this slot has no quest" rather than filling it.
  let skeleton = skeletonFor(kind)
  if skeleton.len == 0:
    return ""
  var r = seededRng(seed)
  let band = bandFor(setJson.field("questConfig").field(kind), level)
  if not band.found:
    return ""

  var description = ""
  var finish = ""
  case kind
  of "Elimination":
    finish = eliminationFinish(r, setJson, band, description)
  of "Exploration":
    finish = explorationFinish(r, setJson, band, description)
  of "Completion":
    finish = completionFinish(r, band, level, description)
  else:
    # `Pickup` and anything a later config adds. See the header: a type with no
    # generator here is skipped rather than emitted empty, because a quest with
    # no finish condition is one the client shows and the player completes by
    # walking up to the trader.
    return ""
  if finish.len == 0 or finish == "[]":
    return ""

  var d = parseObject(skeleton)
  if not d.ok:
    return ""
  let id = questId(r)
  setText(d, "_id", id)
  setText(d, "traderId", traderId)
  setText(d, "type", kind)
  setText(d, "sptRepatableGroupName", groupName)
  # The skeleton is written `side: Pmc` whatever type it is; the *set* is what
  # says whose quest this is, and the scav set's is `Scav`. Read off the set,
  # because a scav daily filed as a PMC quest is one the client shows on the
  # wrong character.
  setText(d, "side", setJson.field("side").asText("Pmc"))
  var conditions = newDoc()
  setRaw(conditions, "AvailableForStart", "[]")
  setRaw(conditions, "AvailableForFinish", finish)
  setRaw(conditions, "Fail", "[]")
  setRaw(d, "conditions", text(conditions))
  var rewards = newDoc()
  setRaw(rewards, "Started", "[]")
  setRaw(rewards, "Success", rewardsFor(setJson, traderId, level, r))
  setRaw(rewards, "Fail", "[]")
  setRaw(d, "rewards", text(rewards))
  # The skeleton's `name`/`description` are locale placeholders -- literally
  # `"{templateId} name {traderId}"` -- which the client resolves against a
  # locale table that has no entry for a quest this server just invented. So
  # they are replaced with the plain-English description the generator already
  # built: a player reading "eliminate 3 Savage on bigmap" is better served than
  # one reading a template string.
  setText(d, "name", description)
  setText(d, "description", description)
  setText(d, "note", description)
  setNumber(d, "startTime", 0)
  setNumber(d, "endTime", endTime)
  setNumber(d, "status", 2)
  var status = newDoc()
  setText(status, "id", mongoId(r))
  setText(status, "uid", "")
  setText(status, "qid", id)
  setNumber(status, "startTime", 0)
  setNumber(status, "status", 2)
  setRaw(status, "statusTimers", "{}")
  setRaw(d, "questStatus", text(status))
  result = text(d)

# ---------------------------------------------------------------------------
# The reroll record
# ---------------------------------------------------------------------------

proc loadRecord(profileId: string; usable: var bool): Doc =
  ## `{ "<set name>": {"period": N, "bumps": [0,1,0], "paid": 2} }`.
  ##
  ## `usable` is the store's "present and unreadable" flag, and a caller about
  ## to write must refuse on it -- an unreadable record answered as "no rerolls"
  ## is a player's paid reroll silently undone on the next write. `emu/store`
  ## is the whole argument.
  let raw1 = readKey(repeatKey(profileId), usable)
  if raw1.len == 0:
    return newDoc()
  result = parseObject(raw1)
  if not result.ok:
    result = newDoc()

proc loadRecord(profileId: string): Doc =
  ## For the read-only paths -- the activity list and the template lookup --
  ## which take the empty answer and let `emu/store` do the logging.
  var usable = true
  result = loadRecord(profileId, usable)

proc bumpsOf(record: Doc; setName: string; period: int): seq[int] =
  ## How many times each slot of this set has been rerolled, or all zeroes when
  ## the record is about a period that has since passed.
  result = @[]
  let entry = get(record, setName)
  if not entry.found:
    return
  if entry.field("period").asInt(-1) != period:
    return
  let list = each(entry.field("bumps"))
  for e in list:
    result.add e.asInt(0)

proc paidOf(record: Doc; setName: string; period: int): int =
  let entry = get(record, setName)
  if not entry.found or entry.field("period").asInt(-1) != period:
    return 0
  result = entry.field("paid").asInt(0)

# ---------------------------------------------------------------------------
# One set
# ---------------------------------------------------------------------------

proc traderFor(setJson: JsonRef; kind: string; r: var Rng): string =
  ## A trader who offers this type, out of the set's own `traderWhitelist`.
  ## Empty when none does, which is a real case -- `mechanic` has no
  ## `Elimination` in his list.
  var candidates: seq[string] = @[]
  let list = each(setJson.field("traderWhitelist"))
  for w in list:
    let types = each(w.field("questTypes"))
    var offers = false
    for t in types:
      if t.asText("") == kind:
        offers = true
    if not offers:
      continue
    let id = w.field("traderId").asText("")
    if id.len > 0:
      candidates.add id
  if candidates.len == 0:
    return ""
  result = candidates[nextInt(r, candidates.len)]

proc slotSeed(profileId, setName: string; period, slot, bump: int): string =
  ## Everything a slot's quest depends on, in one string. The profile id is in
  ## it so two players do not get the same dailies; the bump is in it so a
  ## reroll produces a different quest and the *same* different quest for the
  ## rest of the period.
  result = profileId & ":" & setName & ":" & $period & ":" & $slot & ":" & $bump

proc questsForSet(p: Profile; setJson: JsonRef; nowSec: int;
                  bumps: seq[int]; ids: var seq[string]): string =
  ## The `activeQuests` array for one set.
  ids = @[]
  let setName = setJson.field("name").asText("")
  let reset = setJson.field("resetTime").asInt(0)
  if setName.len == 0 or reset <= 0:
    return "[]"
  let lvl = level(p)
  if lvl < setJson.field("minPlayerLevel").asInt(1):
    return "[]"
  let period = nowSec div reset
  let endTime = (period + 1) * reset
  var want = setJson.field("numQuests").asInt(0)
  if want < 0: want = 0
  if want > MaxSlots: want = MaxSlots

  var types: seq[string] = @[]
  let list = each(setJson.field("types"))
  for t in list:
    let n = t.asText("")
    if n.len > 0:
      types.add n
  if types.len == 0:
    return "[]"

  var out1 = newList()
  var slot = 0
  while slot < want:
    var bump = 0
    if slot < bumps.len:
      bump = bumps[slot]
    let seed = slotSeed(p.id, setName, period, slot, bump)
    # The type and the trader are drawn from a generator seeded the same way
    # the quest is, and *before* the quest's own, so that a reroll changes both.
    var r = seededRng(seed & ":pick")
    let kind = types[nextInt(r, types.len)]
    let traderId = traderFor(setJson, kind, r)
    if traderId.len > 0:
      let quest = buildQuest(setJson, kind, traderId, lvl, endTime, seed,
                             setName)
      if quest.len > 0:
        out1.add quest
        ids.add field(quest, "_id").asText("")
    inc slot
  result = text(out1)

proc changeCostFor*(kind: string): JsonRef =
  ## `changeCost` off the skeleton for a type: a template id and a count. The
  ## reference calls it `List<ChangeCost>` with `TemplateId` and `Count`.
  result = field(skeletonFor(kind), "changeCost")

proc changeStandingCostFor*(kind: string): float =
  result = field(skeletonFor(kind), "changeStandingCost").asFloat(0.0)

# ---------------------------------------------------------------------------
# The route
# ---------------------------------------------------------------------------

proc activityPeriods*(p: Profile; nowSec: int): string =
  ## `/client/repeatalbeQuests/activityPeriods` -- a
  ## `List<PmcDataRepeatableQuest>`, one per set.
  ##
  ## Shaped against the reference's own DTO: `id`, `name`, `activeQuests`,
  ## `inactiveQuests`, `endTime`, `changeRequirement` (a map of quest id to what
  ## rerolling it costs), `freeChanges` and `freeChangesAvailable`.
  ##
  ## A set the player is too low a level for is answered as an **empty set**
  ## rather than omitted, because the client draws the tab either way and a
  ## missing entry is a tab with nothing behind it.
  let table = setsTable()
  if table.len == 0:
    return "[]"
  var record = loadRecord(p.id)
  var out1 = newList()
  let sets = each(whole(table))
  for s in sets:
    let setName = s.field("name").asText("")
    let reset = s.field("resetTime").asInt(0)
    if setName.len == 0 or reset <= 0:
      continue
    let period = nowSec div reset
    var ids: seq[string] = @[]
    let quests = questsForSet(p, s, nowSec, bumpsOf(record, setName, period),
                              ids)

    var requirement = newDoc()
    var kinds: seq[string] = @[]
    let active = parseArray(quests)
    for i in 0 ..< active.len:
      let qid = field(active.items[i], "_id").asText("")
      let kind = field(active.items[i], "type").asText("")
      kinds.add kind
      var one = newDoc()
      let cost = changeCostFor(kind)
      setRaw(one, "changeCost", if cost.found: raw(cost) else: "[]")
      setRaw(one, "changeStandingCost", numText(changeStandingCostFor(kind)))
      setRaw(requirement, qid, text(one))

    let freeTotal = s.field("freeChanges").asInt(0)
    var left = freeTotal - paidOf(record, setName, period)
    if left < 0: left = 0

    var d = newDoc()
    setText(d, "_id", s.field("id").asText(setName))
    setText(d, "name", setName)
    setRaw(d, "activeQuests", quests)
    setRaw(d, "inactiveQuests", "[]")
    setNumber(d, "endTime", (period + 1) * reset)
    setRaw(d, "changeRequirement", text(requirement))
    setNumber(d, "freeChanges", left)
    setNumber(d, "freeChangesAvailable", s.field("freeChangesAvailable").asInt(0))
    setText(d, "unavailableTime", "")
    out1.add d
  result = text(out1)

proc questTemplateFor*(p: Profile; qid: string; nowSec: int): string =
  ## The template of a repeatable quest the player currently has, or "".
  ##
  ## This is what makes accept, hand over and complete work with **no new code
  ## in `emu/quests`**: that module looks a quest up in `templates.quests` and
  ## falls back to here, and everything downstream of the lookup -- the
  ## condition evaluator, the counters, the reward payout -- is the one that was
  ## already tested. A repeatable quest is an ordinary quest whose template
  ## happens to be computed rather than read.
  ##
  ## The consequence worth naming: a repeatable quest **accepted and not
  ## finished before the period ends** becomes a quest with no template, exactly
  ## like a quest the database does not have, and `emu/quests` already handles
  ## that -- it completes with whatever rewards the missing template does not
  ## name, and says so. Which is the right answer: the alternative is a player
  ## stranded on yesterday's daily forever.
  let table = setsTable()
  if table.len == 0:
    return ""
  var record = loadRecord(p.id)
  let sets = each(whole(table))
  for s in sets:
    let setName = s.field("name").asText("")
    let reset = s.field("resetTime").asInt(0)
    if setName.len == 0 or reset <= 0:
      continue
    let period = nowSec div reset
    var ids: seq[string] = @[]
    let quests = questsForSet(p, s, nowSec, bumpsOf(record, setName, period),
                              ids)
    let active = parseArray(quests)
    for i in 0 ..< active.len:
      if field(active.items[i], "_id").asText("") == qid:
        return active.items[i]
  result = ""

proc currentIds*(p: Profile; nowSec: int): seq[string] =
  ## Every repeatable quest id this profile has *right now*, across all sets.
  ##
  ## What it is for: an accepted daily leaves an entry in the profile's `Quests`
  ## array, and three a day for the life of a character is a document that grows
  ## forever with nothing announcing it -- the same shape as the mailbox bug
  ## `emu/mail` is bounded for, and measured the same way. `emu/quests` prunes
  ## finished entries that are not on this list, and only entries it marked as
  ## generated when it accepted them, so a real quest's history is never
  ## touched by it.
  result = @[]
  let table = setsTable()
  if table.len == 0:
    return
  var record = loadRecord(p.id)
  let sets = each(whole(table))
  for s in sets:
    let setName = s.field("name").asText("")
    let reset = s.field("resetTime").asInt(0)
    if setName.len == 0 or reset <= 0:
      continue
    var ids: seq[string] = @[]
    discard questsForSet(p, s, nowSec, bumpsOf(record, setName, nowSec div reset),
                         ids)
    for id in ids:
      result.add id

# ---------------------------------------------------------------------------
# Rerolling one
# ---------------------------------------------------------------------------

proc undo(profileId, previous: string) =
  ## Puts a reroll record back after the charge for it was refused.
  ##
  ## A failure here is logged and not raised: the record is now one reroll
  ## ahead of what the player paid for, which costs them one change of one
  ## daily and nothing else. There is no answer that is better than saying so.
  if save(repeatKey(profileId), previous) != Ok:
    error "could not undo a repeatable-quest change record for " & profileId &
          "; that profile has been charged one change it did not get"

proc changeQuest*(p: var Profile; inv: var Inventory; action: JsonRef;
                  nowSec: int; ch: var Change): bool =
  ## `RepeatableQuestChange` -- the client asking for a different daily.
  ##
  ## The reference's request is `{Action, qid}` (`RepeatableQuestChangeRequest`
  ## carries one `QuestId`); the wire member name is *(unverified)*, so `qid`
  ## and `QuestId` are both read.
  ##
  ## **The cost is the skeleton's, not the request's.** The body carries no
  ## price and it would not be believed if it did: `changeCost` comes off
  ## `templates.repeatableQuests.templates.<type>` and is verified against the
  ## player's own stacks before anything is taken, the same resolve-verify-then-
  ## take the rest of this server does. The set's first `freeChanges` rerolls of
  ## a period cost nothing, and the count of those used is the one number this
  ## module stores.
  var qid = action.field("qid").asText("")
  if qid.len == 0:
    qid = action.field("QuestId").asText("")
  if qid.len == 0:
    ch.problems.add "that reroll names no quest"
    return false

  let table = setsTable()
  if table.len == 0:
    ch.problems.add "this server has no repeatable quests to change"
    return false

  var usable = true
  var record = loadRecord(p.id, usable)
  if not usable:
    # About to write. See `emu/store`: an unreadable record treated as empty is
    # every earlier reroll of this period undone and paid for again.
    ch.problems.add "this profile's repeatable-quest record could not be " &
                    "read; refusing to overwrite it"
    return false

  # ---- find the quest, and which slot it is ------------------------------
  var foundSet = notFound()
  var setName = ""
  var period = 0
  var slot = -1
  var kind = ""
  var questTrader = ""
  let sets = each(whole(table))
  for s in sets:
    let name = s.field("name").asText("")
    let reset = s.field("resetTime").asInt(0)
    if name.len == 0 or reset <= 0:
      continue
    let thisPeriod = nowSec div reset
    var ids: seq[string] = @[]
    let quests = questsForSet(p, s, nowSec,
                              bumpsOf(record, name, thisPeriod), ids)
    let active = parseArray(quests)
    for i in 0 ..< active.len:
      if field(active.items[i], "_id").asText("") == qid:
        foundSet = s
        setName = name
        period = thisPeriod
        slot = i
        kind = field(active.items[i], "type").asText("")
        questTrader = field(active.items[i], "traderId").asText("")
  if slot < 0:
    ch.problems.add "no repeatable quest of this profile's is " & qid
    return false

  # A quest already accepted is not rerolled. The player has progress on it and
  # rerolling would leave `Quests` naming a template this module will never
  # produce again -- which is recoverable, and is still a player's afternoon.
  let status = field(p.text, "Quests")
  let started = each(status)
  for q in started:
    if q.field("qid").asText("") == qid:
      ch.problems.add "that quest has already been accepted and cannot be " &
                      "changed"
      return false

  # ---- record it, then charge for it -------------------------------------
  #
  # This order is deliberate and it is the only one with a recoverable failure.
  #
  # Charging first and recording afterwards means a store write that fails
  # leaves the money gone and the quest unchanged -- the player is 7,000
  # roubles down for nothing. Recording first and charging afterwards means a
  # *refused* charge -- which is the ordinary case, not a rare one: it is what
  # "you cannot afford this" looks like -- would leave the reroll recorded and
  # unpaid, which is a free reroll for anyone with an empty stash.
  #
  # So: record, charge, and put the record back if the charge is refused. A
  # store write can be undone by another store write, which is the one thing in
  # this server that *does* have something to roll back with.
  let before = text(record)
  var bumps = bumpsOf(record, setName, period)
  while bumps.len <= slot:
    bumps.add 0
  bumps[slot] = bumps[slot] + 1
  var list = newList()
  for b in bumps:
    list.add $b
  let freeTotal = foundSet.field("freeChanges").asInt(0)
  var paid = paidOf(record, setName, period)
  var entry = newDoc()
  setNumber(entry, "period", period)
  setRaw(entry, "bumps", text(list))
  setNumber(entry, "paid", paid + 1)
  setRaw(record, setName, text(entry))
  if save(repeatKey(p.id), text(record)) != Ok:
    ch.problems.add "the change could not be recorded, so it was not made"
    return false

  var chargeable = paid >= freeTotal

  if chargeable:
    let cost = changeCostFor(kind)
    var wanted = each(cost)
    if wanted.len == 0:
      # The skeleton names no price. Refused rather than done for nothing, for
      # the same reason a repair with no `RepairCost` is refused: "the database
      # does not say" must not become "free".
      ch.problems.add "this server has no change cost for a " & kind &
                      " quest, so it will not change one"
      undo(p.id, before)
      return false
    # Resolved whole before anything is taken, and merged by template first,
    # exactly like every other payment here. Two entries naming the same
    # template would otherwise be two separate `spendCurrency` calls off two
    # separate readings of the stacks -- which is a reroll charged once for a
    # cost written twice.
    var tpls: seq[string] = @[]
    var counts: seq[int] = @[]
    for c in wanted:
      var tpl = c.field("templateId").asText("")
      if tpl.len == 0:
        tpl = c.field("TemplateId").asText("")
      var count = c.field("count").asInt(0)
      if count <= 0:
        count = c.field("Count").asInt(0)
      if tpl.len == 0 or count <= 0:
        ch.problems.add "that quest's change cost is not a price"
        undo(p.id, before)
        return false
      var merged = false
      for k in 0 ..< tpls.len:
        if tpls[k] == tpl:
          counts[k] = counts[k] + count
          merged = true
      if not merged:
        tpls.add tpl
        counts.add count
    if tpls.len != 1:
      # A cost in two different currencies would be two payments with nothing
      # to roll the first one back with if the second failed, and there is no
      # transaction anywhere in this server. No table this importer produces
      # has one -- every `changeCost` in a live database is a single rouble
      # entry -- so this is a refusal rather than a half-built two-currency
      # payment path.
      ch.problems.add "this server will not charge a change cost in " &
                      $tpls.len & " different currencies"
      undo(p.id, before)
      return false
    if not spendCurrency(inv, tpls[0], counts[0], p.stashId, ch):
      undo(p.id, before)
      return false
    let standingCost = changeStandingCostFor(kind)
    if standingCost > 0.0 and questTrader.len > 0:
      addStanding(p, questTrader, -standingCost)

  result = true
