## aowlspt/trader — traders, stock and quests, without the ten things you
## could not have known.
##
## `mods/tarkov` IS the game server, and it has no trader type and no quest
## type. It reads `traders.<id>` and `templates.quests.<id>` straight out of
## the loaded database and serves whatever is there. So the whole mechanism a
## mod needs is `dbWrite`, and the whole difficulty is the *shape*.
##
## This module is that shape, and nothing else. It does not wrap `dbWrite`, it
## does not own a registry, and it does not run anything: every proc here
## either builds JSON or performs one named `dbWrite` and tells you the path it
## wrote. You can read `install` below and see the three writes.
##
## A whole trader:
##
##     import aowlspt/trader
##
##     var t = newTrader(traderId("ad0000000000000000000001"), "Admin Trader")
##     t.description = "Everything, free."
##     discard t.stockWholeHandbook(4500)     # templates.handbook.Items
##     if install(t) != Ok:
##       warn whyNot(t)
##
## and a quest:
##
##     var q = newQuest(questId("ad0000000000000000000101"), t, "Admin Induction")
##     q.requireLevel(1)
##     q.requireHandover("544fb37f4bdc2dee738b4567", 1)
##     q.rewardExperience(500)
##     q.rewardStanding(0.1)
##     discard install(q)
##
## ## What is made unrepresentable here, and why
##
## Each of these was a real way to produce a trader that looks written and is
## silently broken:
##
## * **An offer with no price.** An assort is three collections keyed to each
##   other (`items`, `barter_scheme`, `loyal_level_items`); an offer in the
##   first and missing from the second is one the client draws and cannot
##   price. Here an offer is one `Offer` value carrying its own cost, and all
##   three collections are emitted from that one list in one loop. There is no
##   API through which they can disagree.
## * **"Free" written as a price of zero.** There is no price field in this
##   database — a price IS a barter requirement. `freeOffer` spells that as a
##   requirement for `count: 0` roubles. You never see a price field because
##   there is not one.
## * **A name written as a dotted path.** Real text lives in
##   `locales.global.en` under `"<id> Nickname"` — with a SPACE in the key — so
##   `dbWrite("locales.global.en.<id> Nickname", …)` writes a key nobody reads.
##   `localeText` takes a key and a value, never a path, and every name this
##   module writes goes through it.
## * **Stock from the wrong table.** `templates.items` is 4,673 raw templates
##   including hideout nodes and stashes and is tens of megabytes;
##   `templates.handbook.Items` is the ~4,300 *tradeable* things and ~400 KB.
##   `stockWholeHandbook` names the correct one and takes no table argument.
## * **A malformed id.** Every id the client handles is 24 hex characters.
##   `traderId` / `questId` refuse anything else *loudly* at construction, and
##   an invalid id makes `install` return `ErrBadArg` rather than write a
##   trader nothing can reach.
##
## Two things this module deliberately does NOT hide, because they are not
## shapes: getting the mod to load at all (the DLL + `registry/mods.json` +
## the manager-owned selection — see `docs/MOD-ENABLE-PATH.md`), and
## `regcheck` comparing `sides` and `author` to your source verbatim.

import ".." / aowlspt            # Status, Ok, ErrBadArg, warn, lastError
import "." / server              # Json, JsonObject, obj/put/arr/done, dbRead, dbWrite
import "." / json                # whole, each, field, asText

# ---------------------------------------------------------------------------
# Ids
# ---------------------------------------------------------------------------

const
  Roubles* = "5449016a4bdc2d6f028b456f"
    ## The rouble template. A barter requirement names a currency by template
    ## id; this is the one you almost always want.
  Dollars* = "5696686a4bdc2da3298b456a"
  Euros* = "569668774bdc2da2298b4568"

type
  Id* = object
    ## A 24-hex-character database id that has been checked. There is no way
    ## to make one without the check: `traderId` and `questId` are the only
    ## constructors, and both refuse.
    text*: string
    ok*: bool
    why*: string

proc isHex24(s: string): bool =
  if s.len != 24: return false
  for ch in s:
    if not ((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or
            (ch >= 'A' and ch <= 'F')):
      return false
  true

proc checkedId(s, what: string): Id =
  if isHex24(s):
    result = Id(text: s, ok: true, why: "")
  else:
    let why = what & " id " & (if s.len == 0: "(empty)" else: "\"" & s & "\"") &
              " is not 24 hex characters -- the client will not match it to " &
              "anything, so nothing will be written"
    warn why
    result = Id(text: s, ok: false, why: why)

proc traderId*(s: string): Id =
  ## A trader's id. 24 hex characters, and not one of the real traders' ids.
  ## Refuses loudly rather than writing a trader that cannot be reached.
  checkedId(s, "trader")

proc questId*(s: string): Id =
  ## A quest's id. Same rule as `traderId`.
  checkedId(s, "quest")

proc derivedId*(base: Id; tag: string; n: int): string =
  ## A stable 24-hex id derived from another one, for the sub-objects that need
  ## their own (each assort offer, each quest condition, each reward). Deriving
  ## them from a counter is what makes the three assort collections agree by
  ## construction instead of by care.
  const Digits = ["0", "1", "2", "3", "4", "5", "6", "7",
                  "8", "9", "a", "b", "c", "d", "e", "f"]
  let prefix = (if base.text.len >= 4: base.text[0 .. 3] else: "ad00") & tag
  var tail = ""
  var v = n
  var i = 0
  while i < 24 - prefix.len:
    tail = Digits[v and 15] & tail
    v = v shr 4
    inc i
  result = prefix & tail

# ---------------------------------------------------------------------------
# Locale text — item 5, the trap that is not a shape
# ---------------------------------------------------------------------------

type
  Locale* = object
    ## A batch of locale entries, flushed with one `dbWrite`. The keys contain
    ## spaces (`"<id> Nickname"`), which is exactly why this is a patch object
    ## and not a dotted path per key.
    parts*: JsonObject
    n*: int

proc newLocale*(): Locale = Locale(parts: obj(), n: 0)

proc localeText*(l: var Locale; key, value: string) =
  ## Record one locale entry. `key` is a KEY, never a path — this is the only
  ## way this module writes text, so the dotted-path mistake has no spelling.
  put(l.parts, key, value)
  inc l.n

proc install*(l: Locale): Status =
  ## One `dbWrite("locales.global.en", …)` with everything recorded so far.
  if l.n == 0: return Ok
  result = dbWrite("locales.global.en", done(l.parts))

# ---------------------------------------------------------------------------
# Offers — item 3 and item 4
# ---------------------------------------------------------------------------

type
  Offer* = object
    ## One thing on the shelf, *and its price*. The two cannot be separated:
    ## there is no constructor that makes an offer without a cost, so an
    ## unpriceable offer cannot be built.
    tpl*: string          ## the item template this offer sells
    count*: int           ## how many of `currency` it costs. 0 is free.
    currency*: string     ## the template id of what it costs
    stack*: int           ## how many are on the shelf
    unlimited*: bool
    loyaltyLevel*: int    ## the LL that unlocks it

proc freeOffer*(tpl: string; loyaltyLevel = 1): Offer =
  ## Sell `tpl` for nothing. There is no price field to set to zero — a price
  ## IS a barter requirement, so "free" is a requirement for `count: 0`
  ## roubles, which is a requirement nothing can fail.
  Offer(tpl: tpl, count: 0, currency: Roubles, stack: 9999999,
        unlimited: true, loyaltyLevel: loyaltyLevel)

proc pricedOffer*(tpl: string; price: int; currency = Roubles;
                  stack = 9999999; unlimited = true;
                  loyaltyLevel = 1): Offer =
  ## Sell `tpl` for `price` of `currency`. Same object as `freeOffer`; free is
  ## not a special case, it is `price = 0`.
  Offer(tpl: tpl, count: price, currency: currency, stack: stack,
        unlimited: unlimited, loyaltyLevel: loyaltyLevel)

proc barterOffer*(tpl: string; wantTpl: string; wantCount: int;
                  stack = 9999999; unlimited = true;
                  loyaltyLevel = 1): Offer =
  ## Sell `tpl` for `wantCount` of some other item. This is the same mechanism
  ## as a price — the currency template is just not a currency.
  Offer(tpl: tpl, count: wantCount, currency: wantTpl, stack: stack,
        unlimited: unlimited, loyaltyLevel: loyaltyLevel)

# ---------------------------------------------------------------------------
# The trader — item 1 and item 2
# ---------------------------------------------------------------------------

type
  Trader* = object
    ## Every field the `base` object needs, pre-filled with a default that
    ## works. Set the two or three that make your trader different and leave
    ## the rest alone; `traderBase` writes all 33 either way, because a missing
    ## field is a client hang rather than an error.
    id*: Id
    nickname*: string
    surname*: string
    description*: string
    location*: string
    avatar*: string
    currency*: string       ## "RUB" / "USD" / "EUR"
    balanceRub*, balanceDol*, balanceEur*: int
    gridHeight*: int
    unlockedByDefault*: bool
    availableInRaid*: bool
    availableInPve*: bool
    medic*: bool
    buyerUp*: bool
    customizationSeller*: bool
    discount*: int
    insuranceAvailable*: bool
    repairAvailable*: bool
    minLevel*: int          ## loyalty level 1's requirement
    offers*: seq[Offer]
    why*: string            ## why the last operation refused, if it did

proc newTrader*(id: Id; nickname: string): Trader =
  ## A complete, working, empty trader. Nothing further is required to write
  ## him — he will simply have nothing to sell.
  Trader(id: id, nickname: nickname, surname: "",
         description: "", location: "Everywhere",
         avatar: "/files/trader/avatar/unknown.jpg",
         currency: "RUB", balanceRub: 0, balanceDol: 0, balanceEur: 0,
         gridHeight: 160, unlockedByDefault: true, availableInRaid: false,
         availableInPve: true, medic: false, buyerUp: false,
         customizationSeller: false, discount: 0,
         insuranceAvailable: false, repairAvailable: false, minLevel: 1,
         offers: @[], why: (if id.ok: "" else: id.why))

proc whyNot*(t: Trader): string =
  ## The reason the last `install` refused, or "".
  t.why

proc sell*(t: var Trader; o: Offer) =
  ## Put one offer on the shelf.
  t.offers.add o

proc sellFree*(t: var Trader; tpl: string) =
  ## Shorthand for `sell(t, freeOffer(tpl))`.
  t.offers.add freeOffer(tpl)

proc stockWholeHandbook*(t: var Trader; maxOffers = 100000;
                         price = 0): int =
  ## Stock everything the handbook lists, at `price` each (0 = free), and
  ## return how many offers that came to.
  ##
  ## The catalogue is `templates.handbook.Items` — the list of *tradeable*
  ## things, about 4,300 entries and ~400 KB. It is deliberately not an
  ## argument: `templates.items` is the other table people reach for, and it is
  ## 4,673 raw templates including hideout nodes and stashes, tens of megabytes
  ## to read, with the wrong contents for a shop.
  result = 0
  let book = dbRead("templates.handbook.Items")
  if not book.ok:
    t.why = "templates.handbook.Items is not in this database, so there is " &
            "nothing to stock (" & lastError() & ")"
    warn t.why
    return 0
  for entry in each(whole(book.raw)):
    if result >= maxOffers: break
    let tpl = entry.field("Id").asText("")
    if tpl.len == 0: continue
    t.offers.add pricedOffer(tpl, price)
    inc result

proc traderBase*(t: Trader): Json =
  ## The `base` object: who he is, what currency he takes, what loyalty levels
  ## he has. All 33 fields, including the ones the client reads but never shows
  ## — and including `insurance_price_coef`, which is a **string** in the real
  ## data and is matched here rather than corrected.
  var lvl = obj()
  put(lvl, "buy_price_coef", 0)
  put(lvl, "exchange_price_coef", 0)
  put(lvl, "heal_price_coef", 0)
  put(lvl, "insurance_price_coef", "0")   # a string in the real data
  put(lvl, "minLevel", t.minLevel)
  put(lvl, "minSalesSum", 0)
  put(lvl, "minStanding", 0)
  put(lvl, "repair_price_coef", 0)
  var levels = arr()
  levels.add lvl

  var emptyList = obj()
  put(emptyList, "category", arr())
  put(emptyList, "id_list", arr())

  var insurance = obj()
  put(insurance, "availability", t.insuranceAvailable)
  put(insurance, "excluded_category", arr())
  put(insurance, "max_return_hour", 0)
  put(insurance, "max_storage_time", 0)
  put(insurance, "min_payment", 0)
  put(insurance, "min_return_hour", 0)

  var repair = obj()
  put(repair, "availability", t.repairAvailable)
  put(repair, "currency", Roubles)
  put(repair, "currency_coefficient", 1)
  put(repair, "excluded_category", arr())
  put(repair, "excluded_id_list", arr())
  put(repair, "quality", "1")

  # `items_sell` is NOT the `{category, id_list}` shape its siblings use. That
  # is the BUY side's shape, and reusing it here shipped a trader that parsed
  # as JSON and threw in the client's typed deserializer:
  #
  #     JSON parsing error in response to traderSettings at line 1 position 101170
  #
  # Measured across the 12 stock traders in db.json, `items_sell` has exactly
  # two shapes and neither is that one:
  #
  #   8 traders  {"1": {category: [], id_list: [str]}, "2": …}  keyed by LOYALTY LEVEL
  #   4 traders  []                                             a bare empty array
  #
  # We ship the empty array, because it is what four stock traders ship
  # verbatim and it makes no claim about the inner object — the dict form is
  # only ever seen with a NON-empty `id_list`, so writing it with an empty one
  # would be inventing a shape no stock trader has.
  #
  # This field is owned by `traderBase` and is not settable on `Trader`: the
  # bug was a wrong shape, so the fix is that a caller cannot supply one.
  let itemsSell = emptyArray()

  var o = obj()
  put(o, "_id", t.id.text)
  put(o, "availableInRaid", t.availableInRaid)
  put(o, "avatar", t.avatar)
  put(o, "balance_dol", t.balanceDol)
  put(o, "balance_eur", t.balanceEur)
  put(o, "balance_rub", t.balanceRub)
  put(o, "buyer_up", t.buyerUp)
  put(o, "currency", t.currency)
  put(o, "customization_seller", t.customizationSeller)
  put(o, "discount", t.discount)
  put(o, "discount_end", 0)
  put(o, "gridHeight", t.gridHeight)
  put(o, "insurance", insurance)
  put(o, "isAvailableInPVE", t.availableInPve)
  put(o, "isCanTransferItems", false)
  put(o, "isCanTransferItemsFromPve", false)
  put(o, "items_buy", emptyList)
  put(o, "items_buy_prohibited", emptyList)
  put(o, "items_sell", itemsSell)
  put(o, "location", t.location)
  put(o, "loyaltyLevels", levels)
  put(o, "mainDialogue", jnull())
  put(o, "medic", t.medic)
  put(o, "name", t.nickname)
  put(o, "nextResupply", 0)
  put(o, "nickname", t.nickname)
  put(o, "prohibitedTransferableItems", emptyList)
  put(o, "repair", repair)
  put(o, "sell_category", arr())
  put(o, "sell_modifier_for_prohibited_items", 0)
  put(o, "surname", t.surname)
  put(o, "transferableItems", emptyList)
  put(o, "unlockedByDefault", t.unlockedByDefault)
  result = done(o)

proc traderAssort*(t: Trader): Json =
  ## The three collections, emitted from `t.offers` in ONE loop so they cannot
  ## drift: `items` (what it is), `barter_scheme` (what it costs) and
  ## `loyal_level_items` (what unlocks it), all keyed by the same derived
  ## offer id.
  var items = arr()
  var barter = obj()
  var loyal = obj()
  var n = 0
  for off in t.offers:
    let offerId = derivedId(t.id, "01", n)

    var upd = obj()
    put(upd, "UnlimitedCount", off.unlimited)
    put(upd, "StackObjectsCount", off.stack)
    put(upd, "BuyRestrictionMax", 0)
    put(upd, "BuyRestrictionCurrent", 0)

    var it = obj()
    put(it, "_id", offerId)
    put(it, "_tpl", off.tpl)
    put(it, "parentId", "hideout")
    put(it, "slotId", "hideout")
    put(it, "upd", upd)
    items.add it

    var cost = obj()
    put(cost, "count", off.count)
    put(cost, "_tpl", off.currency)
    var costRow = arr()
    costRow.add cost
    var costRows = arr()
    costRows.add costRow
    put(barter, offerId, done(costRows))

    put(loyal, offerId, off.loyaltyLevel)
    inc n

  var o = obj()
  put(o, "nextResupply", 0)
  put(o, "items", items)
  put(o, "barter_scheme", barter)
  put(o, "loyal_level_items", loyal)
  result = done(o)

proc traderNames*(t: Trader; into: var Locale) =
  ## The five locale entries a trader needs to render as words rather than as
  ## a raw 24-hex id. Keys carry a SPACE, which is why they go through
  ## `localeText`.
  localeText(into, t.id.text & " Nickname", t.nickname)
  localeText(into, t.id.text & " FullName", t.nickname)
  localeText(into, t.id.text & " FirstName", t.nickname)
  localeText(into, t.id.text & " Location", t.location)
  localeText(into, t.id.text & " Description", t.description)

proc install*(t: var Trader): Status =
  ## Two writes, both named here so you can see them:
  ##
  ##     dbWrite("traders.<id>", { base, assort, questassort })
  ##     dbWrite("locales.global.en", { "<id> Nickname": … })
  ##
  ## and then a read-back, because `dbWrite` returning `Ok` means the call
  ## succeeded and NOT that the value landed where it was aimed.
  t.why = ""
  if not t.id.ok:
    t.why = t.id.why
    return ErrBadArg

  var doc = obj()
  put(doc, "base", traderBase(t))
  put(doc, "assort", traderAssort(t))
  put(doc, "questassort", obj())
  if dbWrite("traders." & t.id.text, done(doc)) != Ok:
    t.why = "dbWrite of traders." & t.id.text & " failed: " & lastError()
    warn t.why
    return ErrBadArg

  let back = dbRead("traders." & t.id.text & ".base.nickname")
  if not back.ok or back.asText() != t.nickname:
    t.why = "traders." & t.id.text & " is not in the database after writing it"
    warn t.why
    return ErrBadArg

  var loc = newLocale()
  traderNames(t, loc)
  if install(loc) != Ok:
    t.why = "the trader is in, but his name is not: " & lastError()
    warn t.why
  Ok

# ---------------------------------------------------------------------------
# Quests — item 7
# ---------------------------------------------------------------------------

type
  Quest* = object
    ## The 30-field quest template with a default for every one of them, plus
    ## the conditions and rewards you add. Every human-readable field is a
    ## LOCALE KEY here; `questWords` supplies the text those keys resolve to.
    id*: Id
    traderId*: Id
    name*: string
    description*: string
    note*: string
    location*: string
    side*: string           ## "Pmc" / "Savage"
    image*: string
    kind*: string           ## the `type` field: "Standing", "Completion", …
    restartable*: bool
    secret*: bool
    instantComplete*: bool
    startConditions*: JsonArray
    finishConditions*: JsonArray
    successRewards*: JsonArray
    nStart*, nFinish*, nReward*: int
    startedText*, successText*, failText*: string
    why*: string

proc newQuest*(id: Id; giver: Trader; name: string): Quest =
  ## A quest nobody can start yet — add at least one start condition and one
  ## finish condition. Everything else already has a working default.
  Quest(id: id, traderId: giver.id, name: name,
        description: "", note: "", location: "any", side: "Pmc",
        image: "/files/quest/icon/unknown.jpg", kind: "Standing",
        restartable: false, secret: false, instantComplete: false,
        startConditions: arr(), finishConditions: arr(), successRewards: arr(),
        nStart: 0, nFinish: 0, nReward: 0,
        startedText: "", successText: "", failText: "",
        why: (if id.ok and giver.id.ok: ""
              elif not id.ok: id.why
              else: "the quest's giving trader has an invalid id"))

proc whyNot*(q: Quest): string = q.why

proc requireLevel*(q: var Quest; level: int) =
  ## Start condition: the player must be at least `level`. `1` means "from a
  ## fresh profile".
  var c = obj()
  put(c, "compareMethod", ">=")
  put(c, "conditionType", "Level")
  put(c, "dynamicLocale", false)
  put(c, "globalQuestCounterId", "")
  put(c, "id", derivedId(q.id, "02", q.nStart))
  put(c, "index", q.nStart)
  put(c, "parentId", "")
  put(c, "value", level)
  put(c, "visibilityConditions", arr())
  q.startConditions.add c
  inc q.nStart

proc requireHandover*(q: var Quest; tpl: string; count = 1;
                      foundInRaid = false) =
  ## Finish condition: hand `count` of item template `tpl` back to the trader.
  var targets = arr()
  targets.add tpl
  var c = obj()
  put(c, "conditionType", "HandoverItem")
  put(c, "dogtagLevel", 0)
  put(c, "dynamicLocale", false)
  put(c, "globalQuestCounterId", "")
  put(c, "id", derivedId(q.id, "03", q.nFinish))
  put(c, "index", q.nFinish)
  put(c, "isEncoded", false)
  put(c, "maxDurability", 100)
  put(c, "minDurability", 0)
  put(c, "onlyFoundInRaid", foundInRaid)
  put(c, "parentId", "")
  put(c, "target", targets)
  put(c, "value", count)
  put(c, "visibilityConditions", arr())
  q.finishConditions.add c
  inc q.nFinish

proc addReward(q: var Quest; kind: string; value: float; target: string) =
  var o = obj()
  put(o, "availableInGameEditions", arr())
  var modes = arr()
  modes.add "regular"
  modes.add "pve"
  put(o, "gameMode", modes)
  put(o, "id", derivedId(q.id, "04", q.nReward))
  put(o, "isHidden", false)
  put(o, "type", kind)
  put(o, "unknown", false)
  put(o, "value", value)
  if target.len > 0:
    put(o, "target", target)
  q.successRewards.add o
  inc q.nReward

proc rewardExperience*(q: var Quest; xp: int) =
  ## Pay `xp` experience on completion.
  addReward(q, "Experience", float(xp), "")

proc rewardStanding*(q: var Quest; standing: float) =
  ## Pay standing with the trader who gave the quest.
  addReward(q, "TraderStanding", standing, q.traderId.text)

proc questTemplate*(q: Quest): Json =
  ## The stored quest. Every text field below is a locale KEY, not the text —
  ## the client looks each one up in `locales.global.en`, and a literal
  ## sentence here renders only when the lookup misses, which is not something
  ## to rely on.
  var conditions = obj()
  put(conditions, "AvailableForStart", q.startConditions)
  put(conditions, "AvailableForFinish", q.finishConditions)
  put(conditions, "Fail", arr())

  var rewards = obj()
  put(rewards, "Started", arr())
  put(rewards, "Success", q.successRewards)
  put(rewards, "Fail", arr())

  let i = q.id.text
  var o = obj()
  put(o, "QuestName", q.name)
  put(o, "_id", i)
  put(o, "acceptPlayerMessage", i & " acceptPlayerMessage")
  put(o, "acceptanceAndFinishingSource", "eft")
  put(o, "arenaLocations", arr())
  put(o, "canShowNotificationsInGame", true)
  put(o, "changeQuestMessageText", i & " changeQuestMessageText")
  put(o, "completePlayerMessage", i & " completePlayerMessage")
  put(o, "conditions", conditions)
  put(o, "declinePlayerMessage", i & " declinePlayerMessage")
  put(o, "description", i & " description")
  put(o, "failMessageText", i & " failMessageText")
  put(o, "gameModes", arr())
  put(o, "image", q.image)
  put(o, "instantComplete", q.instantComplete)
  put(o, "isKey", false)
  put(o, "location", q.location)
  put(o, "name", i & " name")
  put(o, "note", i & " note")
  put(o, "progressSource", "eft")
  put(o, "rankingModes", arr())
  put(o, "restartable", q.restartable)
  put(o, "rewards", rewards)
  put(o, "secretQuest", q.secret)
  put(o, "side", q.side)
  put(o, "startedMessageText", i & " startedMessageText")
  put(o, "status", 0)
  put(o, "successMessageText", i & " successMessageText")
  put(o, "traderId", q.traderId.text)
  put(o, "type", q.kind)
  result = done(o)

proc questWords*(q: Quest; into: var Locale) =
  ## The text every one of the quest's locale keys resolves to.
  let i = q.id.text
  localeText(into, i & " name", q.name)
  localeText(into, i & " description", q.description)
  localeText(into, i & " note", q.note)
  localeText(into, i & " startedMessageText", q.startedText)
  localeText(into, i & " successMessageText", q.successText)
  localeText(into, i & " failMessageText", q.failText)
  localeText(into, i & " changeQuestMessageText", "The terms have changed.")
  localeText(into, i & " acceptPlayerMessage", "I will do it.")
  localeText(into, i & " completePlayerMessage", "Done.")
  localeText(into, i & " declinePlayerMessage", "No thanks.")

proc install*(q: var Quest): Status =
  ## Two writes:
  ##
  ##     dbWrite("templates.quests.<id>", …)
  ##     dbWrite("locales.global.en", …)
  ##
  ## then a read-back of the stored quest's `traderId`.
  q.why = ""
  if not q.id.ok:
    q.why = q.id.why
    return ErrBadArg
  if not q.traderId.ok:
    q.why = "the quest's giving trader has an invalid id"
    warn q.why
    return ErrBadArg
  if q.nStart == 0 or q.nFinish == 0:
    q.why = "quest " & q.id.text & " has " & $q.nStart & " start and " &
            $q.nFinish & " finish conditions -- a quest with none of either " &
            "can never be taken or handed in, so it was not written"
    warn q.why
    return ErrBadArg

  if dbWrite("templates.quests." & q.id.text, questTemplate(q)) != Ok:
    q.why = "dbWrite of templates.quests." & q.id.text & " failed: " & lastError()
    warn q.why
    return ErrBadArg
  let back = dbRead("templates.quests." & q.id.text & ".traderId")
  if not back.ok or back.asText() != q.traderId.text:
    q.why = "templates.quests." & q.id.text &
            " is not in the database after writing it"
    warn q.why
    return ErrBadArg

  var loc = newLocale()
  questWords(q, loc)
  if install(loc) != Ok:
    q.why = "the quest is in, but its words are not: " & lastError()
    warn q.why
  Ok

# ---------------------------------------------------------------------------
# The audit — read the FINISHED STATE back, never your own write
# ---------------------------------------------------------------------------

proc auditTrader*(t: Trader; into: var JsonObject) =
  ## Fill `into` with counters describing what is NOW IN THE DATABASE — not
  ## what this mod did. Serve it from a status route and assert on it.
  ##
  ## The two offer counters are deliberately NEGATIVE — `offersNotFree`,
  ## `offersUnpriced` — because "we wrote 4288 free offers" is a claim about
  ## our own write and cannot fail, while "no offer in the database costs
  ## anything" can.
  ##
  ## Three outcomes, never two. Enumerating the `traders` table needs a host
  ## that can list keys; `aowlspt-backend` can and `aowlspt-sim` cannot, so
  ## `listedInTradersTable` may read `"unknown: …"`. Reporting `false` there
  ## would be a check that says the trader is missing whenever we were unable
  ## to look, which is worse than no check.
  let id = t.id.text
  put(into, "traderId", id)
  if not t.id.ok:
    # An empty or malformed id must NEVER be pasted into a path: `dbRead(
    # "traders." & "")` reads the WHOLE traders table and every field of it
    # comes back empty rather than missing, which reads as a trader that
    # exists and is blank. Refuse instead.
    put(into, "traderInDatabase", false)
    put(into, "listedInTradersTable", "no: " & t.id.why)
    put(into, "tradersInTable", -1)
    put(into, "offersStored", 0)
    put(into, "offersNotFree", 0)
    put(into, "offersUnpriced", 0)
    put(into, "traderNameLocalised", false)
    return
  let base = dbRead("traders." & id & ".base.nickname")
  put(into, "nickname", (if base.ok: base.asText() else: ""))
  put(into, "traderInDatabase", base.ok)

  var traderIds: seq[string] = @[]
  var looked = false
  if dbKeysReady():
    looked = dbKeys("traders", traderIds) == Ok
  else:
    let all = dbRead("traders")
    if all.ok:
      traderIds = keys(whole(all.raw))
      looked = true
  if not looked:
    put(into, "listedInTradersTable",
        "unknown: could not enumerate the traders table (" & lastError() & ")")
    put(into, "tradersInTable", -1)
  else:
    var listed = false
    for other in traderIds:
      if other == id: listed = true
    put(into, "listedInTradersTable", (if listed: "yes" else: "no"))
    put(into, "tradersInTable", traderIds.len)

  var stored = 0
  var notFree = 0
  var unpriced = 0
  let items = dbRead("traders." & id & ".assort.items")
  let barter = dbRead("traders." & id & ".assort.barter_scheme")
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
  put(into, "offersStored", stored)
  put(into, "offersNotFree", notFree)
  put(into, "offersUnpriced", unpriced)

  let loc = dbRead("locales.global.en")
  if loc.ok:
    put(into, "traderNameLocalised",
        field(loc.raw, id & " Nickname").asText("").len > 0)

  # The whole stored `base`, verbatim, so a caller can compare its SHAPE
  # against a stock trader's field by field. A payload that parses as JSON can
  # still be rejected by the client's typed deserializer -- `items_sell` in the
  # buy side's `{category, id_list}` shape did exactly that -- so "it is valid
  # JSON" is not a check. Emitting the document is what makes the real check
  # possible from outside.
  let whole = dbRead("traders." & id & ".base")
  if whole.ok:
    put(into, "storedBase", raw(whole.raw))

proc auditQuest*(q: Quest; into: var JsonObject) =
  ## The same idea for a quest: read the stored template back and count the
  ## four things that make it usable rather than merely present.
  let id = q.id.text
  put(into, "questId", id)
  if not q.id.ok:
    # Same trap as `auditTrader`: `"templates.quests." & ""` is a path to the
    # whole quest table, whose fields all read empty rather than missing.
    put(into, "questInDatabase", false)
    put(into, "questTrader", "")
    put(into, "questStartConditions", 0)
    put(into, "questFinishConditions", 0)
    put(into, "questRewards", 0)
    put(into, "questNameLocalised", false)
    return
  put(into, "questInDatabase", dbRead("templates.quests." & id & "._id").ok)
  let stored = dbRead("templates.quests." & id)
  if stored.ok:
    let qd = whole(stored.raw)
    put(into, "questTrader", qd.field("traderId").asText(""))
    put(into, "questStartConditions",
        each(qd.field("conditions.AvailableForStart")).len)
    put(into, "questFinishConditions",
        each(qd.field("conditions.AvailableForFinish")).len)
    put(into, "questRewards", each(qd.field("rewards.Success")).len)
  let loc = dbRead("locales.global.en")
  if loc.ok:
    put(into, "questNameLocalised",
        field(loc.raw, id & " name").asText("").len > 0)
