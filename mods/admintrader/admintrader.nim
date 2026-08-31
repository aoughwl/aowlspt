## Admin Trader — the "copy this one" example mod.
##
##     aowl build-mod mods/admintrader
##
## It adds a brand new trader to the game, gives him every item in the
## handbook for free, and hands him one quest to give out. That is three
## things, and each one is the same move: **write some JSON into the
## database the emulator already serves from.**
##
## ## The one idea
##
## `mods/tarkov` IS the game server. It does not have a "trader" type or a
## "quest" type — it reads `traders.<id>` and `templates.quests.<id>` straight
## out of the loaded database and serves whatever is there. So a mod does not
## need a trader API. It needs `dbWrite`, and the right shape.
##
##     dbWrite("traders." & MyId, myTraderJson)
##
## That is genuinely the whole mechanism. Everything below is shapes.
##
## ## Want to rename him?
##
## Open `config.json`, change `"nickname"`, restart the backend. Or change it
## in-game on the settings page — this mod's `onSettingsApplied` rewrites the
## trader on the spot. Nothing else needs touching.
##
## ## Want to make your OWN trader instead?
##
## 1. Copy this folder to `mods/yourtrader/` and rename the `.nim`.
## 2. Change `ModGuid`, `ModName`, and `TraderId` at the top. `TraderId` must
##    be 24 hex characters and must not collide with a real trader.
## 3. Add an entry to `registry/mods.json` whose `id` is EXACTLY your
##    `ModGuid` — `aowl selfcheck` fails the build if it is not.
## 4. `aowl build mods`.
##
## ## Getting it to actually load (this trips everyone up)
##
## Three things, all required, and missing any one looks identical to a
## broken mod because nothing complains:
##
##   1. the built `.dll` on disk in the install,
##   2. an entry in `registry/mods.json` with a matching guid,
##   3. the mod enabled in the manager-owned selection
##      (`mods/aowlspt-selection.json`).
##
## Number 3 is written by `aowl.manager`. **Hand-editing it gets reverted** —
## enable the mod through the manager (or through a list in `registry/mods.json`
## that the selection inherits) instead.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/settings
import aowlspt/json

const
  ModGuid = "aowl.admintrader"
  ModName = "Admin Trader"
  ModAuthor = "aowlspt"
  ModVersion = "1.0.0"

  TraderId = "ad0000000000000000000001"
    ## 24 hex characters, like every id the client handles. Ours starts `ad`
    ## so it is obvious in a log which ids this mod invented.
  QuestId = "ad0000000000000000000101"

  Roubles = "5449016a4bdc2d6f028b456f"
    ## The currency template a barter requirement names. We ask for **zero** of
    ## them, which is this database's honest spelling of "free" — there is no
    ## price field to set to 0, a price IS a barter requirement.

  QuestItem = "544fb37f4bdc2dee738b4567"
    ## Painkillers. The quest asks for one, and the Admin Trader sells it for
    ## nothing, so the whole loop is completable from a fresh profile.

  StatusRoute = "/admintrader/status"

# ---------------------------------------------------------------------------
# Settings — three knobs, and every one of them is in config.json
# ---------------------------------------------------------------------------
#
# The rule the build enforces: a key you DECLARE here must also exist in
# `config.json`, or the control renders, moves, and resolves to nothing.
# `declareSettings` backfills missing keys for you, but ship them in the file
# anyway so a reader can see the defaults without running anything.

proc adminSchema(): seq[Setting] =
  result = @[
    boolSetting("enabled", "Add the Admin Trader", true,
                category = "Admin Trader",
                appliesOn = "restart",
                description = "Off removes nothing already written; it stops " &
                              "the trader being written at the next start."),
    stringSetting("nickname", "Trader name", "Admin Trader",
                  category = "Admin Trader",
                  description = "What the trader is called on the trading " &
                                "screen. Changing it here rewrites him live."),
    intSetting("maxOffers", "How many items he stocks", 4500,
               lo = 1, hi = 100000,
               category = "Admin Trader",
               appliesOn = "restart",
               description = "Everything in the handbook, capped. The " &
                             "handbook holds about 4,300 items, so the " &
                             "default is 'all of them'.")]

proc cfgBool(key: string; default: bool): bool = setting(key).asBool(default)
proc cfgInt(key: string; default: int): int = setting(key).asInt(default)
proc cfgStr(key: string; default: string): string = setting(key).asText(default)

# ---------------------------------------------------------------------------
# Ids
# ---------------------------------------------------------------------------

proc hex24(prefix: string; n: int): string =
  ## A stable 24-character hex id from a counter. Every assort offer needs its
  ## own `_id`, and the barter scheme and the loyalty table are keyed by it, so
  ## the three must agree — deriving all three from `n` is what makes that
  ## true by construction instead of by care.
  const Digits = "0123456789abcdef"
  var tail = ""
  var v = n
  var i = 0
  while i < 24 - prefix.len:
    tail = $Digits[v and 15] & tail
    v = v shr 4
    inc i
  result = prefix & tail

# ---------------------------------------------------------------------------
# 1. The trader himself
# ---------------------------------------------------------------------------

proc traderBaseJson(nickname: string): Json =
  ## `base` is the trader: who he is, what currency he takes, what loyalty
  ## levels he has. The client reads every one of these at the menu, and a
  ## missing field is a hang rather than an error — the shape matters more
  ## than the values, so this spells out the full set rather than the subset
  ## that happens to be read today.
  var lvl = obj()
  put(lvl, "buy_price_coef", 0)          # what he pays you: nothing
  put(lvl, "exchange_price_coef", 0)
  put(lvl, "heal_price_coef", 0)
  put(lvl, "insurance_price_coef", "0")  # a string in the real data. Match it.
  put(lvl, "minLevel", 1)
  put(lvl, "minSalesSum", 0)
  put(lvl, "minStanding", 0)
  put(lvl, "repair_price_coef", 0)
  var levels = arr()
  levels.add lvl

  var emptyList = obj()
  put(emptyList, "category", arr())
  put(emptyList, "id_list", arr())

  var insurance = obj()
  put(insurance, "availability", false)
  put(insurance, "excluded_category", arr())
  put(insurance, "max_return_hour", 0)
  put(insurance, "max_storage_time", 0)
  put(insurance, "min_payment", 0)
  put(insurance, "min_return_hour", 0)

  var repair = obj()
  put(repair, "availability", false)
  put(repair, "currency", Roubles)
  put(repair, "currency_coefficient", 1)
  put(repair, "excluded_category", arr())
  put(repair, "excluded_id_list", arr())
  put(repair, "quality", "1")

  var itemsSell = obj()
  put(itemsSell, "category", arr())
  put(itemsSell, "id_list", arr())

  var o = obj()
  put(o, "_id", TraderId)
  put(o, "availableInRaid", false)
  put(o, "avatar", "/files/trader/avatar/unknown.jpg")
  put(o, "balance_dol", 0)
  put(o, "balance_eur", 0)
  put(o, "balance_rub", 0)
  put(o, "buyer_up", false)
  put(o, "currency", "RUB")
  put(o, "customization_seller", false)
  put(o, "discount", 0)
  put(o, "discount_end", 0)
  put(o, "gridHeight", 160)
  put(o, "insurance", insurance)
  put(o, "isAvailableInPVE", true)
  put(o, "isCanTransferItems", false)
  put(o, "isCanTransferItemsFromPve", false)
  put(o, "items_buy", emptyList)
  put(o, "items_buy_prohibited", emptyList)
  put(o, "items_sell", itemsSell)
  put(o, "location", "Everywhere")
  put(o, "loyaltyLevels", levels)
  put(o, "mainDialogue", jnull())
  put(o, "medic", false)
  put(o, "name", nickname)
  put(o, "nextResupply", 0)
  put(o, "nickname", nickname)
  put(o, "prohibitedTransferableItems", emptyList)
  put(o, "repair", repair)
  put(o, "sell_category", arr())
  put(o, "sell_modifier_for_prohibited_items", 0)
  put(o, "surname", "")
  put(o, "transferableItems", emptyList)
  put(o, "unlockedByDefault", true)
  result = done(o)

# ---------------------------------------------------------------------------
# 2. The stock — everything, free
# ---------------------------------------------------------------------------

proc assortJson(maxOffers: int; offers: var int): Json =
  ## An assort is three collections that agree with each other:
  ##
  ##   `items`             one row per offer: what it is, and how many
  ##   `barter_scheme`     keyed by the offer's `_id`: what it costs
  ##   `loyal_level_items` keyed by the offer's `_id`: what LL unlocks it
  ##
  ## An offer present in `items` and missing from the other two is an offer
  ## the client draws and cannot price. All three are filled here in one loop,
  ## from the same `_id`, so they cannot drift.
  ##
  ## The catalogue comes from `templates.handbook.Items`, not from
  ## `templates.items`: the handbook is the list of things that are *tradeable*
  ## (about 4,300 entries and ~400 KB), while `templates.items` is 4,673 raw
  ## templates including hideout nodes and stashes, and is tens of megabytes to
  ## read. Reading the small correct list is not an optimisation; the big one
  ## has the wrong contents.
  offers = 0
  var items = arr()
  var barter = obj()
  var loyal = obj()

  let book = dbRead("templates.handbook.Items")
  if not book.ok:
    warn "no templates.handbook.Items in this database -- the Admin Trader " &
         "will exist and have nothing to sell"
  else:
    # One free-of-charge cost object, reused for every offer. `count: 0` is the
    # honest representation of free here: a price IS a barter requirement, and
    # a requirement for zero roubles is a requirement nothing can fail.
    var cost = obj()
    put(cost, "count", 0)
    put(cost, "_tpl", Roubles)
    var costRow = arr()
    costRow.add cost
    var costRows = arr()
    costRows.add costRow
    let freeCost = done(costRows)

    for entry in each(whole(book.raw)):
      if offers >= maxOffers:
        break
      let tpl = entry.field("Id").asText("")
      if tpl.len == 0:
        continue
      let offerId = hex24("ad01", offers)

      var upd = obj()
      put(upd, "UnlimitedCount", true)
      put(upd, "StackObjectsCount", 9999999)
      put(upd, "BuyRestrictionMax", 0)
      put(upd, "BuyRestrictionCurrent", 0)

      var it = obj()
      put(it, "_id", offerId)
      put(it, "_tpl", tpl)
      put(it, "parentId", "hideout")
      put(it, "slotId", "hideout")
      put(it, "upd", upd)
      items.add it

      put(barter, offerId, freeCost)
      put(loyal, offerId, 1)
      inc offers

  var o = obj()
  put(o, "nextResupply", 0)
  put(o, "items", items)
  put(o, "barter_scheme", barter)
  put(o, "loyal_level_items", loyal)
  result = done(o)

# ---------------------------------------------------------------------------
# 3. The quest
# ---------------------------------------------------------------------------

proc reward(kind: string; id: string; value: float; target: string): Json =
  var o = obj()
  put(o, "availableInGameEditions", arr())
  var modes = arr()
  modes.add "regular"
  modes.add "pve"
  put(o, "gameMode", modes)
  put(o, "id", id)
  put(o, "isHidden", false)
  put(o, "type", kind)
  put(o, "unknown", false)
  put(o, "value", value)
  if target.len > 0:
    put(o, "target", target)
  result = done(o)

proc questJson(): Json =
  ## One quest, complete: who gives it, when you may start it, what finishes
  ## it, and what you get.
  ##
  ##   start   `Level >= 1`  — i.e. immediately.
  ##   finish  hand one painkiller back to the Admin Trader.
  ##   reward  500 XP and a little standing with him.
  ##
  ## The two conditions are written out in full rather than through a helper,
  ## because the shape is the thing a reader came here for.
  var startCond = obj()
  put(startCond, "compareMethod", ">=")
  put(startCond, "conditionType", "Level")
  put(startCond, "dynamicLocale", false)
  put(startCond, "globalQuestCounterId", "")
  put(startCond, "id", "ad0000000000000000000201")
  put(startCond, "index", 0)
  put(startCond, "parentId", "")
  put(startCond, "value", 1)
  put(startCond, "visibilityConditions", arr())
  var starts = arr()
  starts.add startCond

  var targets = arr()
  targets.add QuestItem
  var finishCond = obj()
  put(finishCond, "conditionType", "HandoverItem")
  put(finishCond, "dogtagLevel", 0)
  put(finishCond, "dynamicLocale", false)
  put(finishCond, "globalQuestCounterId", "")
  put(finishCond, "id", "ad0000000000000000000202")
  put(finishCond, "index", 0)
  put(finishCond, "isEncoded", false)
  put(finishCond, "maxDurability", 100)
  put(finishCond, "minDurability", 0)
  put(finishCond, "onlyFoundInRaid", false)
  put(finishCond, "parentId", "")
  put(finishCond, "target", targets)
  put(finishCond, "value", 1)
  put(finishCond, "visibilityConditions", arr())
  var finishes = arr()
  finishes.add finishCond

  var conditions = obj()
  put(conditions, "AvailableForStart", starts)
  put(conditions, "AvailableForFinish", finishes)
  put(conditions, "Fail", arr())

  var success = arr()
  success.add reward("Experience", "ad0000000000000000000301", 500.0, "")
  success.add reward("TraderStanding", "ad0000000000000000000302", 0.1, TraderId)
  var rewards = obj()
  put(rewards, "Started", arr())
  put(rewards, "Success", success)
  put(rewards, "Fail", arr())

  # Every one of these text fields is a LOCALE KEY, not the text itself. The
  # client looks each one up in `locales.global.en`; a literal sentence here
  # renders as that literal sentence only if the lookup misses, which is not
  # something to rely on. `writeLocale` below supplies the strings.
  var o = obj()
  put(o, "QuestName", "Admin Induction")
  put(o, "_id", QuestId)
  put(o, "acceptPlayerMessage", QuestId & " acceptPlayerMessage")
  put(o, "acceptanceAndFinishingSource", "eft")
  put(o, "arenaLocations", arr())
  put(o, "canShowNotificationsInGame", true)
  put(o, "changeQuestMessageText", QuestId & " changeQuestMessageText")
  put(o, "completePlayerMessage", QuestId & " completePlayerMessage")
  put(o, "conditions", conditions)
  put(o, "declinePlayerMessage", QuestId & " declinePlayerMessage")
  put(o, "description", QuestId & " description")
  put(o, "failMessageText", QuestId & " failMessageText")
  put(o, "gameModes", arr())
  put(o, "image", "/files/quest/icon/unknown.jpg")
  put(o, "instantComplete", false)
  put(o, "isKey", false)
  put(o, "location", "any")
  put(o, "name", QuestId & " name")
  put(o, "note", QuestId & " note")
  put(o, "progressSource", "eft")
  put(o, "rankingModes", arr())
  put(o, "restartable", false)
  put(o, "rewards", rewards)
  put(o, "secretQuest", false)
  put(o, "side", "Pmc")
  put(o, "startedMessageText", QuestId & " startedMessageText")
  put(o, "status", 0)
  put(o, "successMessageText", QuestId & " successMessageText")
  put(o, "traderId", TraderId)
  put(o, "type", "Standing")
  result = done(o)

# ---------------------------------------------------------------------------
# 4. The words
# ---------------------------------------------------------------------------

proc writeLocale(nickname: string): Status =
  ## Names and sentences live in `locales.global.en`, keyed by
  ## `"<id> <FieldName>"` — with a space in the key, which is why this is one
  ## patch object rather than a dotted `dbWrite` path per key.
  ##
  ## Skip this and the trading screen shows a raw 24-hex id where a name goes.
  var o = obj()
  put(o, TraderId & " Nickname", nickname)
  put(o, TraderId & " FullName", nickname)
  put(o, TraderId & " FirstName", nickname)
  put(o, TraderId & " Location", "Everywhere")
  put(o, TraderId & " Description",
      "A test trader added by the Admin Trader example mod. Everything he " &
      "has is free, and he has everything.")

  put(o, QuestId & " name", "Admin Induction")
  put(o, QuestId & " description",
      "Bring me one pack of painkillers. I sell them for nothing, so this " &
      "should not take long.")
  put(o, QuestId & " note", "Hand over 1 x Painkillers.")
  put(o, QuestId & " startedMessageText", "Take your time. Or do not.")
  put(o, QuestId & " successMessageText", "Good. You now know how a quest works.")
  put(o, QuestId & " failMessageText", "That should not have been possible.")
  put(o, QuestId & " changeQuestMessageText", "The terms have changed.")
  put(o, QuestId & " acceptPlayerMessage", "I will do it.")
  put(o, QuestId & " completePlayerMessage", "Done.")
  put(o, QuestId & " declinePlayerMessage", "No thanks.")
  result = dbWrite("locales.global.en", done(o))

# ---------------------------------------------------------------------------
# Putting it in
# ---------------------------------------------------------------------------

var gOffers = 0
var gInstalled = false
var gWhyNot = ""

proc install(): bool =
  ## Three writes: the trader, the quest, the words. Each is checked, because
  ## `dbWrite` returning Ok means the call succeeded and NOT that the value
  ## landed where it was aimed — so each write is read back.
  gInstalled = false
  gWhyNot = ""

  let nickname = cfgStr("nickname", "Admin Trader")
  let maxOffers = cfgInt("maxOffers", 4500)

  var assort = assortJson(maxOffers, gOffers)
  var trader = obj()
  put(trader, "base", traderBaseJson(nickname))
  put(trader, "assort", assort)
  put(trader, "questassort", obj())

  if dbWrite("traders." & TraderId, done(trader)) != Ok:
    gWhyNot = "dbWrite of traders." & TraderId & " failed: " & lastError()
    warn gWhyNot
    return false

  # Read the finished state back, not the thing we just handed over.
  let back = dbRead("traders." & TraderId & ".base.nickname")
  if not back.ok or back.asText() != nickname:
    gWhyNot = "the trader is not in the database after writing it"
    warn gWhyNot
    return false

  if dbWrite("templates.quests." & QuestId, questJson()) != Ok:
    gWhyNot = "dbWrite of the quest failed: " & lastError()
    warn gWhyNot
    return false
  let q = dbRead("templates.quests." & QuestId & ".traderId")
  if not q.ok or q.asText() != TraderId:
    gWhyNot = "the quest is not in the database after writing it"
    warn gWhyNot
    return false

  if writeLocale(nickname) != Ok:
    warn "the trader and quest are in, but their names are not: " & lastError()

  gInstalled = true
  result = true

proc onStatus(url, body, session: string): string =
  ## `GET /admintrader/status` — what actually happened, in numbers you can
  ## assert on. Every mod should have one of these.
  ##
  ## Every field below is read back out of the database. None of it reports
  ## what this mod *did*; all of it reports what is now *there*. And the two
  ## counters are deliberately NEGATIVE — `offersNotFree`, `offersUnpriced` —
  ## because "we wrote 4288 free offers" cannot fail and "no offer in the
  ## database costs anything" can.
  var o = obj()
  put(o, "ok", gInstalled)
  put(o, "mod", ModGuid)
  put(o, "traderId", TraderId)
  put(o, "questId", QuestId)
  put(o, "offers", gOffers)
  let base = dbRead("traders." & TraderId & ".base.nickname")
  put(o, "nickname", (if base.ok: base.asText() else: ""))
  put(o, "traderInDatabase", base.ok)
  put(o, "questInDatabase", dbRead("templates.quests." & QuestId & "._id").ok)

  # Is he in the table the trader list is BUILT from? `emu/traders` serves the
  # menu by enumerating the members of `traders` -- so the falsifiable
  # question is whether our id is one of them, not whether our write returned
  # Ok.
  #
  # Three outcomes, not two. `dbKeys` needs a host that can enumerate keys;
  # `aowlspt-backend` can and `aowlspt-sim` cannot, so on the simulator the
  # honest answer is "unknown". Reporting `false` there would be a check that
  # says the trader is missing whenever we were unable to look, which is worse
  # than no check at all.
  var traderIds: seq[string] = @[]
  var looked = false
  if dbKeysReady():
    looked = dbKeys("traders", traderIds) == Ok
  else:
    # The fallback `emu/traders` itself uses: read the whole `traders` table
    # and take its member names. It is a big read -- tens of megabytes -- and
    # happens only here, only on a diagnostic route, and only on a host that
    # cannot answer the cheap question. `aowlspt-sim` is such a host.
    let all = dbRead("traders")
    if all.ok:
      traderIds = keys(whole(all.raw))
      looked = true
  if not looked:
    put(o, "listedInTradersTable", "unknown: could not enumerate the traders " &
        "table (" & lastError() & ")")
    put(o, "tradersInTable", -1)
  else:
    var listed = false
    for id in traderIds:
      if id == TraderId:
        listed = true
    put(o, "listedInTradersTable", (if listed: "yes" else: "no"))
    put(o, "tradersInTable", traderIds.len)

  # Price every offer in the stored assort, from the stored assort.
  var stored = 0
  var notFree = 0
  var unpriced = 0
  let items = dbRead("traders." & TraderId & ".assort.items")
  let barter = dbRead("traders." & TraderId & ".assort.barter_scheme")
  if items.ok and barter.ok:
    let scheme = whole(barter.raw)
    for it in each(whole(items.raw)):
      inc stored
      let offerId = it.field("_id").asText("")
      let rows = scheme.field(offerId)
      if not rows.found:
        inc unpriced
        continue
      var priced = false
      for row in each(rows):
        for req in each(row):
          priced = true
          if req.field("count").asInt(0) != 0:
            inc notFree
      if not priced:
        inc unpriced
  put(o, "offersStored", stored)
  put(o, "offersNotFree", notFree)
  put(o, "offersUnpriced", unpriced)

  # The quest, read back and checked for the four things that make it usable
  # rather than merely present.
  let q = dbRead("templates.quests." & QuestId)
  if q.ok:
    let qd = whole(q.raw)
    put(o, "questTrader", qd.field("traderId").asText(""))
    put(o, "questStartConditions",
        each(qd.field("conditions.AvailableForStart")).len)
    put(o, "questFinishConditions",
        each(qd.field("conditions.AvailableForFinish")).len)
    put(o, "questRewards", each(qd.field("rewards.Success")).len)
  let loc = dbRead("locales.global.en")
  if loc.ok:
    put(o, "questNameLocalised",
        field(loc.raw, QuestId & " name").asText("").len > 0)
    put(o, "traderNameLocalised",
        field(loc.raw, TraderId & " Nickname").asText("").len > 0)

  if gWhyNot.len > 0:
    put(o, "problem", gWhyNot)
  result = done(o).text

proc onApply(key: string) =
  ## Hot-apply. Only `nickname` can change without a restart — the stock and
  ## the enable flag are declared `appliesOn = "restart"` and say so on the
  ## page, which is the honest answer rather than a control that silently
  ## does nothing.
  if key == "nickname":
    let nickname = cfgStr("nickname", "Admin Trader")
    var patch = obj()
    put(patch, "nickname", nickname)
    put(patch, "name", nickname)
    if dbWrite("traders." & TraderId & ".base", done(patch)) == Ok and
       writeLocale(nickname) == Ok:
      settingApplied("the trader is now called \"" & nickname & "\"")
    else:
      settingIgnored("could not rewrite the trader: " & lastError())
  else:
    settingAppliesOnRestart("takes effect when the backend restarts")

proc onLoad(): Status =
  if side() != sideServer:
    info ModName & " is a server mod; nothing to do on this side"
    return Ok

  declareSettings(adminSchema())
  discard serveSettingsRoutes()      # the two settings routes, in one line
  onSettingsApplied(onApply)

  if serve(StatusRoute, onStatus) != Ok:
    warn "could not register " & StatusRoute

  if not cfgBool("enabled", true):
    info ModName & " is disabled in config.json; no trader was added"
    return Ok

  if install():
    success ModName & ": trader " & TraderId & " added with " & $gOffers &
            " free offers, and quest " & QuestId
  else:
    warn ModName & " did not install: " & gWhyNot
  Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideServer, sideSim},
  onLoad = onLoad)
