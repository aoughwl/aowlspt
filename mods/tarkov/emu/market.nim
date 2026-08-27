## The flea market.
##
## Three things share one module because they share one list: the offers the
## server invents, the search that filters them, and the player's own offers.
##
## **Offers are built once and cached.** The obvious implementation reads the
## handbook per request, and the handbook is tens of thousands of entries in a
## multi-megabyte document that `aowlspt/json` scans linearly -- so "price this
## template" costs a walk of the whole table, and doing it per offer per request
## is quadratic over the largest document the server holds. Everything the
## market needs comes out of **one** pass over the handbook and one pass per
## trader assort, into `gOffers`, and a search is then a filter over a few
## hundred small records. The cache is rebuilt when it expires, which is also
## how offers get fresh expiry timestamps.
##
## **The cap is shared, and the search is not capped.** The list is bounded --
## see `TraderSharePercent` -- and a bound filled from one source before the
## other gets a turn is not a bound, it is a preference nobody wrote down: the
## traders' assorts used to fill it entirely, so on a real database the flea was
## the trader screens over again and nothing that was not already on one could
## be bought anywhere. Half the cap each now, and a search that names one
## template materialises an offer for it whether or not the rebuild reached it,
## because a cap applied before the filter is a cap on the *answer*.
##
## **Money is stacks, not a balance.** Buying goes through `takePayment` in
## `emu/trading`, unchanged and for the same reason: the request names which
## stacks to pay from, every one of them is verified before anything is taken,
## and a half-applied payment has nothing to roll back to. The flea has exactly
## the same constraint as the trader counter and must not grow a second, laxer
## copy of the rule.
##
## **A player's offers are not the client's to hold.** They live in this mod's
## store under `market.<profile id>`, not in the profile document: an offer
## holds the *items*, which have left the stash, and putting them in the profile
## would mean the client's copy of the profile is the record of what the player
## is owed. Then a client that drops a field -- or a player who edits one --
## loses or duplicates gear. The store is the server's, and the profile only
## ever sees the diff.
##
## **It degrades to an empty market.** Every source is a `dbRead` with a
## fallback, so a server started against `tests/fixtures/emu-db.json`, or
## against nothing at all, still opens the flea screen with a valid (possibly
## empty) response rather than failing the request. That is the same rule the
## static tables follow and it is what makes the screen testable at all.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import numbers
import store
import ids
import templates
import inventory
import trading
import traders
import grid
import mail

const
  StoreKeyPrefix* = "market."

  DefaultSpreadPercent* = 20
  ## What the market charges over the handbook. The flea being *more* expensive
  ## than the handbook is the game's own economy: the handbook price is what a
  ## trader pays you, and a player selling to another player wants more than
  ## that or they would have sold it to the trader.

  DefaultOfferHours* = 12
  DefaultMaxOffers* = 600
  ## A cap, not a target. Generating an offer for all ~25,000 handbook entries
  ## would produce a response the client spends longer parsing than the raid
  ## takes to load, and no player scrolls past the first few pages of a
  ## category. The cap is per *rebuild*, and the search filters within it.

  TraderSharePercent = 50
  ## How much of the cap the traders' own stock may take.
  ##
  ## This number is here because leaving it out was a bug, and a quiet one.
  ## `offersFromTraders` used to fill the whole cap and `offersFromHandbook`
  ## ran afterwards against a list that was already full -- so against a real
  ## 39 MiB database the flea was **600 rows of Prapor, Therapist and Skier
  ## stock and not one generated offer**, and since no trader sells a bolt or a
  ## screw nut at any loyalty level, in any currency, in any barter, neither
  ## did the flea. Most hideout stage materials were then obtainable only by
  ## raiding for them, which is not the game's economy and which nothing
  ## announced.
  ##
  ## A ratio rather than "generate first" or "raise the cap":
  ##
  ## - Generating first inverts the same bug -- the handbook is forty times the
  ##   size of every assort put together, so the traders would get nothing and
  ##   the flea would stop showing the one half of it whose prices are real
  ##   data rather than derived.
  ## - Raising the cap does not fix it at all. Whatever the cap is, one source
  ##   filling it first empties the other, and the client pages the list: it
  ##   asks for fifteen rows at a time, so a bigger pool costs every request
  ##   more and shows the player nothing extra.
  ## - Interleaving the two sources is what a ratio *is*, once the shares are
  ##   fixed; the ratio is the part that can be stated and checked.
  ##
  ## Half and half, with either side taking the slack the other cannot use, so
  ## a database with one trader still fills the market off the handbook and a
  ## database with no handbook still fills it off the traders. The split is not
  ## a number recovered from the game -- the real flea's composition is a live
  ## player population and there is nothing in the dump that determines it --
  ## so it is stated here as a choice rather than presented as data.

  MinTargetedOffers = 1
  ## How many offers a search naming one template guarantees for it. See
  ## `ensureOffersFor`: the cap is applied when the market is *built*, and a
  ## cap applied before the filter is the same bug wearing a different hat --
  ## the player searches for a screw nut, the unfiltered pool never had one,
  ## and the market answers "nobody is selling that" about an item it prices.

  DefaultSaleMinutes* = 30
  ## How long a competitively priced player offer sits before it sells.

  MaxCategoryDepth = 16
    ## A handbook with a parent cycle in it would otherwise hang the request
    ## thread. Depth-limited rather than visited-checked: the real tree is three
    ## deep and a limit is cheaper than a set per lookup.

  MemberTypeTrader = 4
  MemberTypePlayer = 0

# The three currencies the client's price filter knows. Everything else is a
# barter, and this market does not list barters -- see `offersFromTraders`.
const
  CurrencyRoubles* = trading.Roubles
  CurrencyDollars* = trading.Dollars
  CurrencyEuros* = trading.Euros

type
  Offer* = object
    ## One row of the flea. Kept as a record rather than as rendered JSON so
    ## that filtering and sorting are field comparisons -- rendering happens
    ## once, for the page actually returned.
    id*: string
    tpl*: string
    itemsJson*: string   ## the offer's item list, raw JSON array
    rootId*: string      ## `_id` of the first item; the client's `root`
    sellerId*: string
    seller*: string
    memberType*: int
    rating*: float
    ratingGrowing*: bool
    price*: int
    currency*: string
    loyalty*: int
    quantity*: int
    unlimited*: bool
    sellInOnePiece*: bool
    startTime*: int
    endTime*: int
    category*: string    ## the handbook `ParentId` of `tpl`
    name*: string        ## the localised name, filled in lazily; see `nameOf`
    nameKnown*: bool

  Category = object
    id: string
    parent: string

  Filter* = object
    ## The client's search request, read once into something comparable.
    category*: string
    text*: string
    priceFrom*: int
    priceTo*: int
    quantityFrom*: int
    quantityTo*: int
    currency*: int       ## 0 any, 1 RUB, 2 USD, 3 EUR -- the client's numbering
    ownerType*: int      ## 0 any, 1 traders, 2 players
    inStockOnly*: bool
    oneHourExpiry*: bool
    sortType*: int
    sortDirection*: int  ## 0 ascending, 1 descending
    page*: int
    limit*: int
    linkedTpl*: string   ## `linkedSearchId`: an exact template match

var gSpreadPercent = DefaultSpreadPercent
var gOfferHours = DefaultOfferHours
var gMaxOffers = DefaultMaxOffers
var gSaleMinutes = DefaultSaleMinutes

var gPriceMultiplier = 1.0
  ## What every flea asking price is multiplied by.
  ##
  ## Applied at the TWO places an offer's price is born -- the trader-derived
  ## rows in `traderCandidates` and the handbook-derived rows in
  ## `generatedOffer` -- and nowhere else, because `buyOffer` charges
  ## `o.price`. Scaling one origin and not the other is a market where half the
  ## rows ignore the setting, which reads as "the setting does nothing".
var gSellFeePercent = 0
  ## A percentage of the asking price, taken out of the stash when the player
  ## LISTS something. 0 is the default and means listing is free, which is what
  ## this server did before the setting existed.

var gOffers: seq[Offer] = @[]
var gCategories: seq[Category] = @[]
var gBuiltAt = 0
var gBuilt = false
var gTargeted = 0
  ## How many offers were added *after* the rebuild, by a search that named one
  ## template the built market had no row for. Counted so the pool cannot grow
  ## without bound over a long session: past a second capful the market is
  ## rebuilt, which drops them all and starts the count again.

proc configureMarket*(spreadPercent, offerHours, maxOffers,
                      saleMinutes: int; priceMultiplier: float;
                      sellFeePercent: int) =
  ## Called once at load, from config. Out-of-range values are corrected rather
  ## than refused: a spread of -100% would list every item for nothing and a cap
  ## of zero would produce a flea screen that is empty for a reason no log line
  ## explains.
  gSpreadPercent = spreadPercent
  if gSpreadPercent < 0: gSpreadPercent = 0
  if gSpreadPercent > 1000: gSpreadPercent = 1000
  gOfferHours = offerHours
  if gOfferHours < 1: gOfferHours = 1
  gMaxOffers = maxOffers
  if gMaxOffers < 1: gMaxOffers = 1
  gSaleMinutes = saleMinutes
  if gSaleMinutes < 0: gSaleMinutes = 0
  gPriceMultiplier = priceMultiplier
  if gPriceMultiplier < 0.0: gPriceMultiplier = 0.0
  gSellFeePercent = sellFeePercent
  if gSellFeePercent < 0: gSellFeePercent = 0
  if gSellFeePercent > 100: gSellFeePercent = 100
  # Any change to pricing invalidates what was already generated.
  gBuilt = false

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

proc textLess(a, b: string): bool =
  ## Byte-wise "before". Written out because nimony has no `reverse` and the
  ## sort here needs a comparison it can flip, not one it can only call.
  var i = 0
  while i < a.len and i < b.len:
    if a[i] != b[i]:
      return ord(a[i]) < ord(b[i])
    inc i
  result = a.len < b.len

proc containsFold(haystack, needle: string): bool =
  ## Case-insensitive substring. `toLowerAscii` on both sides rather than a
  ## Unicode fold: the search box is used for ASCII item names and a wrong fold
  ## on Cyrillic would silently drop matches instead of reporting anything.
  if needle.len == 0:
    return true
  if haystack.len < needle.len:
    return false
  let h = toLowerAscii(haystack)
  let n = toLowerAscii(needle)
  var i = 0
  while i + n.len <= h.len:
    var k = 0
    var same = true
    while k < n.len:
      if h[i + k] != n[k]:
        same = false
        break
      inc k
    if same:
      return true
    inc i
  result = false

proc hashOf(s: string): int =
  ## A stable small hash. The market has no random number generator, for the
  ## same reason `emu/ids` has none: a bug report that says "the offer for X was
  ## priced wrongly" is only reproducible if X always produces the same offer.
  var acc = 0
  for ch in s:
    acc = (acc * 31 + ord(ch)) and 0x3FFFFFF
  result = acc

proc currencyTplOf(code: string): string =
  ## A trader's `currency` field is a three-letter code; a price is an item.
  case code
  of "USD": result = CurrencyDollars
  of "EUR": result = CurrencyEuros
  else: result = CurrencyRoubles

proc currencyIndex(tpl: string): int =
  ## The client's own numbering for its currency filter.
  if tpl == CurrencyRoubles: return 1
  if tpl == CurrencyDollars: return 2
  if tpl == CurrencyEuros: return 3
  result = 0

proc isCurrency(tpl: string): bool = currencyIndex(tpl) != 0

proc spreadPrice(base, tpl: string; handbook: int): int =
  ## The handbook price plus the spread, plus a deterministic wobble of up to a
  ## quarter of the spread either way, so a category is not a column of
  ## identical numbers. Never below 1: an offer priced at zero is one the client
  ## lets a player take the entire market with.
  var p = (handbook * (100 + gSpreadPercent)) div 100
  let span = (handbook * gSpreadPercent) div 400
  if span > 0:
    let wobble = (hashOf(base & tpl) mod (span * 2 + 1)) - span
    p = p + wobble
  if p < 1: p = 1
  result = p

proc scaleFleaPrice*(price: int): int =
  ## An asking price with `fleaPriceMultiplier` applied.
  ##
  ## A multiplier of exactly 0 is the ONE case that may produce 0 -- that is
  ## the "everything is free" setting, asked for by name, and rounding it up to
  ## 1 would make the row lie. Any other multiplier floors at 1, because a
  ## price rounded down to nothing turns "cheap" into "free" for whichever
  ## items happened to be cheapest, which is not what the number says.
  if gPriceMultiplier == 1.0:
    return price
  if gPriceMultiplier == 0.0:
    return 0
  if price <= 0:
    return price
  result = int(float(price) * gPriceMultiplier + 0.5)
  if result < 1:
    result = 1

const SellerNames = ["Kappa", "Zryachiy", "Tagilla", "Reshala", "Killa",
                     "Glukhar", "Sanitar", "Shturman", "Kaban", "Partisan",
                     "Cultist", "Knight", "BigPipe", "BirdEye"]

proc sellerFor(tpl: string): string =
  ## A stable seller per *template*. Not a player database -- the client only
  ## ever renders the nickname and the rating, and inventing a persistent
  ## population of fake traders would be state to keep for something nothing
  ## reads back.
  ##
  ## Per template and not per position in the list, which it used to be. The
  ## seller is what the price is wobbled from, so a seller that depended on
  ## where the offer happened to land meant the same screw nut was priced one
  ## way by a rebuild and another way by the targeted lookup in
  ## `ensureOffersFor` -- a market with two prices for one item, differing by
  ## nothing a player could see.
  result = SellerNames[hashOf(tpl) mod SellerNames.len]

proc ratingFor(seller: string): float =
  ## 0.0 .. 6.0, stable per seller, because the rating column must not change
  ## between two searches for the same thing.
  result = float(hashOf(seller) mod 61) / 10.0

# ---------------------------------------------------------------------------
# Building the market
# ---------------------------------------------------------------------------

proc syntheticItems(tpl: string; count: int; itemId: string): string =
  ## The item list of a generated offer: one item, with a stack count when the
  ## offer is for more than one. The client reads `_tpl` out of this to draw the
  ## row -- an offer with an empty `items` renders as a blank line it cannot
  ## click.
  var d = newDoc()
  setText(d, "_id", itemId)
  setText(d, "_tpl", tpl)
  setText(d, "parentId", "hideout")
  setText(d, "slotId", "hideout")
  if count > 1:
    var upd = newDoc()
    setNumber(upd, "StackObjectsCount", count)
    setRaw(d, "upd", text(upd))
  var l = newList()
  l.add d
  result = text(l)

proc parentText(j: JsonRef): string =
  ## A handbook `ParentId`, with JSON null read as "no parent". `asText` on a
  ## null gives the four characters "null", and a category whose parent is
  ## literally named "null" turns every root node into a child of a node that
  ## does not exist -- which makes the whole tree unreachable from the top.
  if not j.found or isNull(j):
    return ""
  result = j.asText("")

proc loadCategories() =
  ## The handbook's category tree, flattened to id/parent pairs. Read once per
  ## rebuild because a category filter has to walk it per offer, and reading it
  ## per walk is the quadratic version of this whole module.
  gCategories = @[]
  let v = dbRead("templates.handbook.Categories")
  if not v.ok or v.raw.len == 0:
    return
  let list = each(whole(v.raw))
  for c in list:
    let id = c.field("Id").asText("")
    if id.len == 0:
      continue
    gCategories.add Category(id: id, parent: parentText(c.field("ParentId")))

proc inCategory(leaf, wanted: string): bool =
  ## Is `leaf` `wanted`, or under it? The client sends the node the player
  ## clicked, and clicking "Weapons" must show the assault rifles beneath it --
  ## matching only the exact id gives a tree whose branches are all empty.
  if wanted.len == 0:
    return true
  var cur = leaf
  var depth = 0
  while cur.len > 0 and depth < MaxCategoryDepth:
    if cur == wanted:
      return true
    var parent = ""
    for c in gCategories:
      if c.id == cur:
        parent = c.parent
        break
    cur = parent
    inc depth
  result = false

proc traderCandidates(nowSec: int; onlyTpl: string; cand: var seq[Offer];
                      first, last: var seq[int]) =
  ## Every trader's stock, as flea offers, grouped by trader: trader `t`'s
  ## offers are `cand[first[t] ..< last[t]]`. Grouped rather than concatenated
  ## because the caller takes a *share* of them and has to take it round-robin
  ## -- a flat list in document order is how Prapor came to own the flea.
  ##
  ## `onlyTpl` empty means every template; naming one is the targeted lookup in
  ## `ensureOffersFor`, and it is the same code so that an offer found that way
  ## is identical to the one a rebuild would have produced.
  ##
  ## Only offers whose requirement is a single currency. A barter offer -- "two
  ## bolts for a bandage" -- has no price, and the flea sorts and filters on
  ## price: listing barters at zero puts every one of them at the top of every
  ## "cheapest first" search, and the buy path here pays in money, so the player
  ## could not complete the trade anyway. They stay on the trader screen, which
  ## is where they can be honoured.
  let ids = traderIds()
  for tid in ids:
    first.add cand.len
    last.add cand.len
    let base = dbRead("traders." & tid & ".base")
    var nickname = tid
    var currency = CurrencyRoubles
    if base.ok and base.raw.len > 0:
      let b = whole(base.raw)
      let n = b.field("nickname").asText("")
      if n.len > 0: nickname = n
      currency = currencyTplOf(b.field("currency").asText("RUB"))

    let assort = dbRead("traders." & tid & ".assort")
    if not assort.ok or assort.raw.len == 0:
      continue
    let a = whole(assort.raw)
    let scheme = a.field("barter_scheme")
    let loyalties = a.field("loyal_level_items")
    let items = each(a.field("items"))
    for it in items:
      # Root items only. A scope that is part of a rifle in the assort is not
      # something the trader sells separately, and listing it would sell the
      # player a duplicate of a part they already bought attached.
      if it.field("slotId").asText("") != "hideout":
        continue
      let offerItemId = it.field("_id").asText("")
      let tpl = it.field("_tpl").asText("")
      if tpl.len == 0 or offerItemId.len == 0:
        continue
      if onlyTpl.len > 0 and tpl != onlyTpl:
        continue

      let req = scheme.child(offerItemId).at(0).at(0)
      if not req.found:
        continue
      let reqTpl = req.field("_tpl").asText("")
      if not isCurrency(reqTpl):
        continue
      let price = req.field("count").asInt(0)
      if price <= 0:
        continue

      var count = it.field("upd.StackObjectsCount").asInt(1)
      if count < 1: count = 1
      var o = Offer(id: newId(), tpl: tpl, itemsJson: "", rootId: "",
                    sellerId: tid, seller: nickname,
                    memberType: MemberTypeTrader, rating: 1.0,
                    ratingGrowing: true, price: scaleFleaPrice(price), currency: reqTpl,
                    loyalty: loyalties.child(offerItemId).asInt(1),
                    quantity: count, unlimited: true, sellInOnePiece: false,
                    startTime: nowSec, endTime: nowSec + gOfferHours * 3600,
                    category: "", name: nickname, nameKnown: false)
      o.rootId = newId()
      o.itemsJson = syntheticItems(tpl, count, o.rootId)
      o.currency = reqTpl
      # The trader's own currency is what its base says; the barter scheme is
      # what it actually charges, and they disagree in real dumps. The scheme
      # wins -- it is what the trading screen bills.
      if not isCurrency(o.currency):
        o.currency = currency
      cand.add o
      last[last.len - 1] = cand.len

proc generatedOffer(nowSec: int; tpl, category: string; base: int): Offer =
  ## One invented player offer for a template the handbook prices. Split out of
  ## the handbook pass so that the pass and the targeted lookup produce the same
  ## row for the same template -- a search that materialises a different offer
  ## from the one a rebuild would have made is a market with two prices.
  let seller = sellerFor(tpl)
  let stackLimit = itemStackLimit(tpl)
  var count = 1
  if stackLimit > 1:
    count = 1 + (hashOf(tpl) mod 3)
    if count > stackLimit: count = stackLimit
  result = Offer(id: newId(), tpl: tpl, itemsJson: "", rootId: "",
                 sellerId: "", seller: seller, memberType: MemberTypePlayer,
                 rating: ratingFor(seller), ratingGrowing: true,
                 price: scaleFleaPrice(spreadPrice(seller, tpl, base) * count),
                 currency: CurrencyRoubles, loyalty: 1, quantity: count,
                 unlimited: false, sellInOnePiece: count > 1,
                 startTime: nowSec, endTime: nowSec + gOfferHours * 3600,
                 category: category, name: "", nameKnown: false)
  result.sellerId = hex(int64(hashOf(seller)), 24)
  result.rootId = newId()
  result.itemsJson = syntheticItems(tpl, count, result.rootId)

proc pricedEntry(e: JsonRef; tpl: var string; base: var int): bool =
  ## Is this handbook entry one an offer can be made from? Its own proc because
  ## the handbook is walked twice per rebuild -- once to count what is eligible,
  ## so the stride below can be worked out, and once to take every nth of them
  ## -- and the two walks agreeing is the whole of the arithmetic.
  tpl = e.field("Id").asText("")
  base = e.field("Price").asInt(0)
  if tpl.len == 0 or base <= 0:
    return false
  # Currency itself is in the handbook. An offer selling roubles for roubles
  # is a row every search matches and nobody wants.
  if isCurrency(tpl):
    return false
  result = true

proc handbookEligible(): int =
  ## How many offers the handbook could supply. Read before the shares are
  ## worked out, so that a database whose handbook is smaller than the
  ## handbook's share hands what it cannot use back to the traders instead of
  ## leaving the market short.
  result = 0
  let hb = dbRead("templates.handbook.Items")
  if not hb.ok or hb.raw.len == 0:
    return
  var tpl = ""
  var base = 0
  for e in each(whole(hb.raw)):
    if pricedEntry(e, tpl, base):
      inc result

proc offersFromHandbook(nowSec: int; out1: var seq[Offer]; quota: int;
                        stocked: seq[string]) =
  ## The generated half of the market: player offers for what the handbook
  ## prices, up to `quota`.
  ##
  ## **Spread over the whole handbook, not the first `quota` entries of it.**
  ## The handbook is written in category order, so taking a prefix gives a
  ## market that is entirely ammunition -- the same failure as taking the
  ## traders in document order, one level down. Every nth eligible entry is
  ## taken instead, n chosen so the last one taken is near the end of the table.
  ##
  ## `stocked` is the templates the trader half of the list already carries. A
  ## generated offer for one of those buys the player nothing they could not
  ## already get from the trader screen, and the offers that are worth spending
  ## the quota on are exactly the ones no trader has -- which is the whole
  ## finding this split came out of. When a skipped entry costs the market an
  ## offer the next eligible entry takes its place, so the quota is still spent.
  ##
  ## One pass over the table, twice. `handbookPrice` in `emu/templates` scans
  ## the whole table per call, which is right for the one lookup a sale needs
  ## and wrong by a factor of the table size here.
  if quota <= 0:
    return
  let hb = dbRead("templates.handbook.Items")
  if not hb.ok or hb.raw.len == 0:
    return
  let entries = each(whole(hb.raw))
  var tpl = ""
  var base = 0
  var eligible = 0
  for e in entries:
    if pricedEntry(e, tpl, base):
      inc eligible
  if eligible == 0:
    return
  var step = eligible div quota
  if step < 1:
    step = 1

  var index = 0     ## how many eligible entries have been seen
  var due = 0       ## the eligible index the next offer is taken at
  var taken = 0
  for e in entries:
    if taken >= quota:
      return
    if not pricedEntry(e, tpl, base):
      continue
    let mine = index >= due
    inc index
    if not mine:
      continue
    var already = false
    for s in stocked:
      if s == tpl:
        already = true
        break
    if already:
      # `due` deliberately not advanced: the next eligible entry is taken in
      # this one's place rather than the slot being lost.
      continue
    out1.add generatedOffer(nowSec, tpl, parentText(e.field("ParentId")), base)
    inc taken
    due = index + step - 1

proc categoryOf(tpl: string): string =
  ## The handbook parent of one template. Used for the offers that did not come
  ## out of the handbook pass -- trader stock and player listings -- where the
  ## per-offer scan is bounded by the assort size rather than by the table.
  let hb = dbRead("templates.handbook.Items")
  if not hb.ok:
    return ""
  let entries = each(whole(hb.raw))
  for e in entries:
    if e.field("Id").asText("") == tpl:
      return parentText(e.field("ParentId"))
  result = ""

proc rebuild(nowSec: int) =
  ## The cap, shared out. See `TraderSharePercent` for why it is shared at all.
  var built: seq[Offer] = @[]
  loadCategories()

  var cand: seq[Offer] = @[]
  var firstOf: seq[int] = @[]
  var lastOf: seq[int] = @[]
  traderCandidates(nowSec, "", cand, firstOf, lastOf)

  # The traders' share, and the slack. Neither source is *made* to use its half:
  # the handbook's half goes to the traders when there is no handbook, and the
  # traders' half goes to the handbook when the assorts are small -- which is
  # every server running on `tests/fixtures`, where both sources fit twice over
  # and the split never binds at all.
  var traderQuota = (gMaxOffers * TraderSharePercent) div 100
  if traderQuota > cand.len:
    traderQuota = cand.len
  let hbEligible = handbookEligible()
  if gMaxOffers - traderQuota > hbEligible:
    traderQuota = gMaxOffers - hbEligible
    if traderQuota > cand.len:
      traderQuota = cand.len
  if traderQuota < 0:
    traderQuota = 0

  # Round-robin, one offer per trader per pass. In document order the first two
  # or three traders in a real database spend the whole share between them and
  # every trader after them is absent from the flea entirely; a pass at a time
  # gives each of them the same number of rows until it runs out of stock.
  var round1 = 0
  var more = true
  while more and built.len < traderQuota:
    more = false
    for t in 0 ..< firstOf.len:
      if built.len >= traderQuota:
        break
      let at = firstOf[t] + round1
      if at < lastOf[t]:
        built.add cand[at]
        more = true
    inc round1

  # Trader offers were built before the handbook was read, so their category is
  # filled in here rather than looked up inside that loop.
  var stocked: seq[string] = @[]
  for i in 0 ..< built.len:
    if built[i].category.len == 0 and built[i].memberType == MemberTypeTrader:
      built[i].category = categoryOf(built[i].tpl)
    stocked.add built[i].tpl

  offersFromHandbook(nowSec, built, gMaxOffers - built.len, stocked)
  gOffers = built
  gTargeted = 0
  gBuiltAt = nowSec
  gBuilt = true

proc ensureMarket*(nowSec: int) =
  ## Rebuilds when the market has never been built, or when what is there has
  ## run out. Offers carry an expiry the client counts down to, so a cache that
  ## outlives it shows a market of offers that all expired hours ago.
  if gBuilt and nowSec < gBuiltAt + gOfferHours * 3600:
    return
  rebuild(nowSec)

proc isCategoryId(id: string): bool =
  for c in gCategories:
    if c.id == id:
      return true
  result = false

proc ensureOffersFor*(tpl: string; nowSec: int) =
  ## Makes sure a search that names one template has something to find.
  ##
  ## **The cap is applied when the market is built, and the filter runs after
  ## it.** That is the same bug as the one the trader/handbook split fixes,
  ## one layer up: however the shares are divided, the pool is a few hundred
  ## rows out of thousands of templates, so a player searching for a screw nut
  ## by id -- which is what `linkedSearchId` and an item id in `handbookId` are
  ## -- gets "nobody is selling that" about an item the handbook prices and a
  ## trader stocks. A page cap is a page cap; a *search* cap is a lie.
  ##
  ## So a search for one template materialises what the rebuild did not reach:
  ## every currency-priced trader offer for it, and one generated offer if the
  ## handbook has a price. They go into `gOffers` rather than into a temporary
  ## list because the client's next request is `RagFairBuyOffer` naming the id
  ## it was shown, and `findOffer` has to be able to find it.
  ##
  ## Also when the only offers for it have been bought out: an offer with
  ## nothing left is filtered out of the search, and without this the flea
  ## would answer "nobody is selling that" for the rest of the twelve hours to
  ## the next rebuild -- and a hideout stage that asks for ten of something
  ## could not be supplied by a market that lists three. The seller lists
  ## another, at the same price: everything about a generated offer is derived
  ## from the template id, so there is no second price for it to appear at.
  ##
  ## Which does mean the flea's supply of a template is not exhaustible, and
  ## `buyOffer` says the opposite about *one offer id* -- deliberately, and the
  ## two are not in conflict. An offer id that keeps answering "yes" is an
  ## infinite supply of a thing for one payment's worth of checking; a fresh
  ## offer is a fresh row at a fresh price with the stock counted down again,
  ## and every purchase is still paid for at the offer's own price out of stacks
  ## the profile is verified to hold. What is unbounded here is the *market*,
  ## which is what a market with sellers in it is; what is bounded is any one
  ## offer, which is what stops the same row being bought twice.
  if tpl.len == 0:
    return
  # A handbook *category* id is the ordinary case for `handbookId` and it is not
  # a template. Answered from the category table, which is already in memory, so
  # that the common search does not pay for the walks below.
  if isCategoryId(tpl):
    return
  # And an id the item table has never heard of is not a template either. One
  # member scan, and it is what keeps this cheap for a client that is not
  # asking in good faith: without it, any 24-character string in `handbookId`
  # bought a walk of every trader's assort and of the whole handbook, from a
  # request that costs nothing to send.
  if not itemExists(tpl):
    return
  var have = 0
  for o in gOffers:
    if o.tpl == tpl and (o.unlimited or o.quantity > 0):
      inc have
      if have >= MinTargetedOffers:
        return

  # Past a second capful of these, start again rather than grow for ever. A
  # session that searches for a thousand different templates is a session whose
  # pool would otherwise be a thousand rows longer than the cap says.
  if gTargeted >= gMaxOffers:
    rebuild(nowSec)
    for o in gOffers:
      if o.tpl == tpl and (o.unlimited or o.quantity > 0):
        return

  var cand: seq[Offer] = @[]
  var firstOf: seq[int] = @[]
  var lastOf: seq[int] = @[]
  traderCandidates(nowSec, tpl, cand, firstOf, lastOf)
  let cat = categoryOf(tpl)
  for o in cand:
    var withCat = o
    withCat.category = cat
    gOffers.add withCat
    inc gTargeted

  # And one from the handbook, if it prices this template. `handbookPrice` and
  # `categoryOf` are each a walk of the table, which is the cost this module
  # goes to some trouble to keep out of the rebuild -- here it is paid once per
  # template ever searched for, and never again while the market stands.
  let base = handbookPrice(tpl)
  if base > 0:
    gOffers.add generatedOffer(nowSec, tpl, cat, base)
    inc gTargeted

proc nameOf(index: int): string =
  ## The localised name of an offer's item, fetched at most once per offer.
  ##
  ## Lazily, and this is the reason: the locale is one object with a hundred
  ## thousand members and `dbRead` finds a key by scanning it, so naming every
  ## offer up front costs a full scan per offer for a column that only a text
  ## search reads. Nothing else in the response needs it -- the client
  ## localises the row itself from the template id.
  if index < 0 or index >= gOffers.len:
    return ""
  if gOffers[index].nameKnown:
    return gOffers[index].name
  var n = ""
  let loc = dbRead("locales.global.en." & gOffers[index].tpl & " Name")
  if loc.ok:
    n = asText(loc)
  if n.len == 0:
    let prop = itemProp(gOffers[index].tpl, "Name")
    if prop.ok:
      n = asText(prop)
  if n.len == 0:
    n = gOffers[index].tpl
  gOffers[index].name = n
  gOffers[index].nameKnown = true
  result = n

# ---------------------------------------------------------------------------
# Player offers
# ---------------------------------------------------------------------------

proc marketKey*(profileId: string): string = StoreKeyPrefix & profileId

proc playerDoc*(profileId: string; usable: var bool): Doc =
  ## `{"rating":..,"offers":[..]}`, and whether the key could be read.
  ##
  ## A profile that has never listed anything has no key at all, which is the
  ## normal first-run case and not a fault. A key that is there and unreadable
  ## is a fault, and answering it as "no offers" would let the next listing
  ## write one offer over every offer the player has items tied up in -- and the
  ## items in a listed offer are *out of the profile*, so that is the items
  ## gone. See `emu/store`.
  let raw1 = readKey(marketKey(profileId), usable)
  if raw1.len > 0:
    var d = parseObject(raw1)
    if d.ok:
      return d
  result = newDoc()
  setRaw(result, "rating", numText(0.0))
  setRaw(result, "offers", "[]")

proc playerDoc*(profileId: string): Doc =
  ## For the read-only callers.
  var usable = true
  result = playerDoc(profileId, usable)

proc savePlayerDoc(profileId: string; d: Doc): bool =
  result = save(marketKey(profileId), text(d)) == Ok

proc playerOffers*(profileId: string): List =
  let d = playerDoc(profileId)
  var l = parseArray(getRaw(d, "offers"))
  if not l.ok:
    l = newList()
  result = l

proc playerRating*(profileId: string): float =
  result = get(playerDoc(profileId), "rating").asFloat(0.0)

proc setPlayerOffers(profileId: string; offers: List; rating: float): bool =
  var d = playerDoc(profileId)
  setRaw(d, "offers", text(offers))
  setRaw(d, "rating", numText(rating))
  result = savePlayerDoc(profileId, d)

proc playerOfferRecords(profileId: string; nickname: string;
                        nowSec: int): seq[Offer] =
  ## The player's own listings, in the same shape as a generated one, so the
  ## search does not need a second code path to include them. A player who
  ## cannot see their own offer in the market has no way to tell whether the
  ## listing worked.
  result = @[]
  let list = playerOffers(profileId)
  let rating = playerRating(profileId)
  for i in 0 ..< list.len:
    let e = whole(list.items[i])
    let tpl = e.field("tpl").asText("")
    if tpl.len == 0:
      continue
    var count = e.field("count").asInt(1)
    if count < 1: count = 1
    result.add Offer(id: e.field("_id").asText(""), tpl: tpl,
                     itemsJson: raw(e.field("items")),
                     rootId: e.field("rootId").asText(""),
                     sellerId: profileId, seller: nickname,
                     memberType: MemberTypePlayer, rating: rating,
                     ratingGrowing: true,
                     price: e.field("price").asInt(0),
                     currency: e.field("currency").asText(CurrencyRoubles),
                     loyalty: 1, quantity: count, unlimited: false,
                     sellInOnePiece: e.field("sellInOnePiece").asBool(false),
                     startTime: e.field("startTime").asInt(nowSec),
                     endTime: e.field("endTime").asInt(nowSec),
                     category: "", name: "", nameKnown: false)

# ---------------------------------------------------------------------------
# Search
# ---------------------------------------------------------------------------

proc readFilter*(body: string): Filter =
  ## The client's search request.
  ##
  ## The free-text box has changed key across client versions -- and an unknown
  ## key read as "no filter" is a search that silently ignores what the player
  ## typed, which looks like a broken market rather than a missing field. All
  ## three spellings seen in the wild are accepted; whichever is present wins.
  let b = whole(body)
  var text1 = b.field("text").asText("")
  if text1.len == 0: text1 = b.field("searchText").asText("")
  if text1.len == 0: text1 = b.field("nameFilter").asText("")
  var limit = b.field("limit").asInt(15)
  if limit < 1: limit = 15
  if limit > 500: limit = 500
  var page = b.field("page").asInt(0)
  if page < 0: page = 0
  result = Filter(category: b.field("handbookId").asText(""),
                  text: text1,
                  priceFrom: b.field("priceFrom").asInt(0),
                  priceTo: b.field("priceTo").asInt(0),
                  quantityFrom: b.field("quantityFrom").asInt(0),
                  quantityTo: b.field("quantityTo").asInt(0),
                  currency: b.field("currency").asInt(0),
                  ownerType: b.field("offerOwnerType").asInt(0),
                  inStockOnly: b.field("onlyInStock").asBool(
                               b.field("inStockOnly").asBool(false)),
                  oneHourExpiry: b.field("oneHourExpiration").asBool(false),
                  sortType: b.field("sortType").asInt(0),
                  sortDirection: b.field("sortDirection").asInt(0),
                  page: page, limit: limit,
                  linkedTpl: b.field("linkedSearchId").asText(""))

proc matchesExceptCategory(o: Offer; index: int; f: Filter;
                           nowSec: int): bool =
  ## Everything but the handbook category. Split out because the category
  ## counts the client draws its tree from are counts of the offers that match
  ## *the rest* of the filter -- counting post-category would make every
  ## unselected branch read zero.
  if f.linkedTpl.len > 0 and o.tpl != f.linkedTpl:
    return false
  if f.priceFrom > 0 and o.price < f.priceFrom:
    return false
  if f.priceTo > 0 and o.price > f.priceTo:
    return false
  if f.quantityFrom > 0 and o.quantity < f.quantityFrom:
    return false
  if f.quantityTo > 0 and o.quantity > f.quantityTo:
    return false
  if f.currency != 0 and currencyIndex(o.currency) != f.currency:
    return false
  if f.ownerType == 1 and o.memberType != MemberTypeTrader:
    return false
  if f.ownerType == 2 and o.memberType == MemberTypeTrader:
    return false
  # Sold out is not a filter, it is gone. An offer whose stock a purchase took
  # to zero is dropped whether or not the player ticked "in stock only" --
  # leaving it visible means the next click is refused by the buy path, which
  # reads to the player as a broken market rather than as an empty one. The
  # tick-box is honoured for the same reason it exists on trader rows.
  if not o.unlimited and o.quantity <= 0:
    return false
  if f.inStockOnly and o.quantity <= 0:
    return false
  if f.oneHourExpiry and o.endTime > nowSec + 3600:
    return false
  if f.text.len > 0:
    # The template id is matched too. A player pasting an id out of a wiki or a
    # log finds the item, which is what the id is for.
    if not containsFold(o.tpl, f.text):
      # `index >= 0` means the offer is in the cache and its name can be filled
      # in there; a player's own offer is not, and matches on its id only.
      if index < 0:
        return false
      if not containsFold(nameOf(index), f.text):
        return false
  result = true

proc lessThan(a, b: Offer; sortType: int): bool =
  case sortType
  of 3: result = a.rating < b.rating
  of 4: result = textLess(a.name, b.name)
  of 5: result = a.price < b.price
  of 6: result = a.endTime < b.endTime
  else: result = textLess(a.id, b.id)

proc sortOffers(offers: var seq[Offer]; sortType, direction: int) =
  ## Insertion sort, and deliberately: the input is one page's worth of a capped
  ## list, `algorithm.sorted` in nimony takes a comparator this cannot express
  ## without a closure, and a wrong sort is invisible in a screenshot.
  var i = 1
  while i < offers.len:
    let cur = offers[i]
    var k = i - 1
    while k >= 0:
      var before = lessThan(cur, offers[k], sortType)
      if direction == 1:
        before = lessThan(offers[k], cur, sortType)
      if not before:
        break
      offers[k + 1] = offers[k]
      dec k
    offers[k + 1] = cur
    inc i

proc offerJson(o: Offer; nowSec: int): JsonObject =
  var user = obj()
  put(user, "id", if o.sellerId.len > 0: o.sellerId else: o.seller)
  put(user, "memberType", o.memberType)
  put(user, "nickname", o.seller)
  put(user, "rating", o.rating)
  put(user, "isRatingGrowing", o.ratingGrowing)
  put(user, "avatar", "/files/trader/avatar/unknown.jpg")

  var req = obj()
  put(req, "_tpl", o.currency)
  put(req, "count", o.price)
  put(req, "onlyFunctional", true)
  var reqs = arr()
  reqs.add req

  var out1 = obj()
  put(out1, "_id", o.id)
  put(out1, "intId", 0)
  put(out1, "user", user)
  put(out1, "root", o.rootId)
  put(out1, "items", raw(o.itemsJson))
  put(out1, "itemsCost", o.price)
  put(out1, "requirements", reqs)
  put(out1, "requirementsCost", o.price)
  put(out1, "summaryCost", o.price)
  put(out1, "sellInOnePiece", o.sellInOnePiece)
  put(out1, "startTime", o.startTime)
  put(out1, "endTime", o.endTime)
  put(out1, "priority", false)
  put(out1, "loyaltyLevel", o.loyalty)
  put(out1, "locked", false)
  put(out1, "unlimitedCount", o.unlimited)
  put(out1, "quantity", o.quantity)
  put(out1, "notAvailable", false)
  # The two names the client has used for the same number across versions. Both
  # are sent because a row whose count reads zero is drawn greyed out and
  # cannot be bought, and finding out which name this client wanted costs a
  # session of guessing.
  put(out1, "CurrentItemCount", o.quantity)
  put(out1, "buyRestrictionMax", 0)
  put(out1, "buyRestrictionCurrent", 0)
  result = out1

proc searchResult*(body, profileId, nickname: string; nowSec: int): string =
  ## `/client/ragfair/find`. Returns the response's `data`; the caller wraps it
  ## in the envelope.
  ensureMarket(nowSec)
  let f = readFilter(body)

  # A search that names one template must be able to find it, whether or not the
  # rebuild's cap reached it. All three of these are the client asking for one
  # item rather than for a category: `linkedSearchId` is the "offers for this"
  # button, an item id in `handbookId` is the same thing from the item screen,
  # and a template id typed into the box is a player pasting one out of a wiki.
  ensureOffersFor(f.linkedTpl, nowSec)
  ensureOffersFor(f.category, nowSec)
  if f.text.len == 24:
    ensureOffersFor(f.text, nowSec)

  # Candidates: the generated market plus this player's own listings. Indices
  # into `gOffers` are carried alongside so `nameOf` can cache into the record
  # that stays; -1 marks an offer that is not in the cache.
  var pool: seq[Offer] = @[]
  var poolIndex: seq[int] = @[]
  for i in 0 ..< gOffers.len:
    pool.add gOffers[i]
    poolIndex.add i
  if profileId.len > 0:
    let mine = playerOfferRecords(profileId, nickname, nowSec)
    for m in mine:
      pool.add m
      poolIndex.add -1

  var counts: seq[int] = @[]
  var countTpls: seq[string] = @[]
  var matched: seq[Offer] = @[]
  for k in 0 ..< pool.len:
    if not matchesExceptCategory(pool[k], poolIndex[k], f, nowSec):
      continue
    # The category tree's counts: every offer that passes the rest of the
    # filter, by template, whether or not the selected category holds it.
    var at = -1
    for c in 0 ..< countTpls.len:
      if countTpls[c] == pool[k].tpl:
        at = c
        break
    if at < 0:
      countTpls.add pool[k].tpl
      counts.add 1
    else:
      counts[at] = counts[at] + 1
    if not inCategory(pool[k].category, f.category):
      # An exact template id in the category box is how the client asks for
      # "offers for this item", and it is not a category at all.
      if pool[k].tpl != f.category:
        continue
    var picked = pool[k]
    if f.sortType == 4 and poolIndex[k] >= 0:
      picked.name = nameOf(poolIndex[k])
    matched.add picked

  sortOffers(matched, f.sortType, f.sortDirection)

  let first = f.page * f.limit
  var rows = arr()
  var k = first
  while k < matched.len and k < first + f.limit:
    rows.add offerJson(matched[k], nowSec)
    inc k

  var cats = obj()
  for c in 0 ..< countTpls.len:
    put(cats, countTpls[c], counts[c])

  var data = obj()
  put(data, "offers", rows)
  put(data, "offersCount", matched.len)
  put(data, "selectedCategory", f.category)
  put(data, "categories", cats)
  result = done(data).text

proc marketPrice*(body: string; nowSec: int): string =
  ## `/client/ragfair/itemMarketPrice`: what the item goes for.
  ##
  ## Averaged over the offers that actually exist, so the number the player is
  ## shown is the number they will pay. When nothing is listed it falls back to
  ## the handbook plus the spread rather than to zero -- a market price of zero
  ## is what the client shows when it thinks the item is worthless, and it is
  ## not the same statement as "nobody is selling one".
  ensureMarket(nowSec)
  var tpl = field(body, "templateId").asText("")
  if tpl.len == 0:
    tpl = field(body, "templateid").asText("")
  # The same materialisation the search does, for the same reason: the number
  # shown on the item screen has to be the number the flea will charge, and
  # falling through to the handbook for a template the cap did not reach quotes
  # a price no offer is actually at.
  ensureOffersFor(tpl, nowSec)
  var lowest = 0
  var highest = 0
  var total = 0
  var n = 0
  for o in gOffers:
    if o.tpl != tpl:
      continue
    let unit = if o.quantity > 1: o.price div o.quantity else: o.price
    if n == 0 or unit < lowest: lowest = unit
    if unit > highest: highest = unit
    total = total + unit
    inc n
  if n == 0:
    let hb = handbookPrice(tpl)
    if hb > 0:
      let p = (hb * (100 + gSpreadPercent)) div 100
      lowest = p
      highest = p
      total = p
      n = 1
  var o1 = obj()
  put(o1, "avg", if n > 0: total div n else: 0)
  put(o1, "min", lowest)
  put(o1, "max", highest)
  result = done(o1).text

# ---------------------------------------------------------------------------
# Buying and listing
# ---------------------------------------------------------------------------

proc stashTemplateOf(inv: Inventory; stashId: string): string =
  ## The stash container's own template, so the grid is the size this profile's
  ## stash actually is. `emu/trading` has the same three lines and keeps them
  ## private; duplicated rather than reached into, because making it public
  ## would be an edit to a file this module does not own.
  let at = indexOf(inv, stashId)
  if at < 0:
    return ""
  result = field(inv.items.items[at], "_tpl").asText("")

proc findOffer(id, profileId, nickname: string; nowSec: int;
               found: var Offer): bool =
  for o in gOffers:
    if o.id == id:
      found = o
      return true
  if profileId.len > 0:
    let mine = playerOfferRecords(profileId, nickname, nowSec)
    for o in mine:
      if o.id == id:
        found = o
        return true
  result = false

proc buyOffer*(inv: var Inventory; action: JsonRef; stashId, profileId,
               nickname: string; ch: var Change; nowSec: int): bool =
  ## `RagFairBuyOffer`.
  ##
  ## Payment goes through `takePayment` unchanged: the request names the stacks
  ## to pay from, and every one of them is verified before a coin moves. The
  ## flea is not a second place where that rule gets a looser copy.
  ##
  ## The item is placed in a real free cell. If the stash is full the purchase
  ## is refused *before* the payment, because there is no transaction to roll
  ## back and a player who paid for something that could not be placed has lost
  ## the money with nothing to show for it.
  ensureMarket(nowSec)
  let purchases = each(action.field("offers"))
  if purchases.len == 0:
    ch.problems.add "that flea purchase names no offers"
    return false

  for pr in purchases:
    let offerId = pr.field("id").asText("")
    var o = Offer(id: "", tpl: "", itemsJson: "", rootId: "", sellerId: "",
                  seller: "", memberType: 0, rating: 0.0, ratingGrowing: false,
                  price: 0, currency: "", loyalty: 0, quantity: 0,
                  unlimited: false, sellInOnePiece: false, startTime: 0,
                  endTime: 0, category: "", name: "", nameKnown: false)
    if not findOffer(offerId, profileId, nickname, nowSec, o):
      ch.problems.add "there is no offer " & offerId & " on the flea market"
      return false
    if o.sellerId == profileId and profileId.len > 0:
      ch.problems.add "you cannot buy your own offer"
      return false
    if o.endTime <= nowSec:
      ch.problems.add "that offer has expired"
      return false

    var count = pr.field("count").asInt(1)
    if count < 1: count = 1
    if not o.unlimited and count > o.quantity:
      ch.problems.add "that offer only has " & $o.quantity & " left"
      return false

    # Room first. `findSpace` on a grid built from the current item list, so a
    # second purchase in the same batch sees the first one's item.
    var g = stashGrid(stashTemplateOf(inv, stashId))
    markOccupied(g, text(inv.items), stashId)
    if not findSpace(g, o.tpl).ok:
      ch.problems.add "there is no room in the stash for that"
      return false

    var scheme = pr.field("items")
    if not scheme.found:
      scheme = pr.field("scheme_items")

    # **The price is the offer's, not the request's.** `takePayment` verifies
    # that the stacks named hold what the request claims they hold -- it has no
    # idea what the thing being bought costs, so on its own it let a body naming
    # one rouble buy a 60000-rouble offer, `err:0`, item delivered. Summed by
    # template so paying out of three stacks still works.
    let owed = o.price * count
    var offered = 0
    let paid = each(scheme)
    for pe in paid:
      let at = indexOf(inv, pe.field("id").asText(""))
      if at < 0:
        continue
      if field(inv.items.items[at], "_tpl").asText("") != o.currency:
        continue
      offered = offered + pe.field("count").asInt(0)
    if offered < owed:
      ch.problems.add "that offer costs " & $owed & " and the payment covers " &
                      $offered
      return false

    if not takePayment(inv, scheme, ch):
      return false
    let perOffer = if o.sellInOnePiece: o.quantity else: 1
    if not giveItem(inv, o.tpl, stashId, count * perOffer, ch):
      return false

    # The stock goes down. Without this the same one-of-a-kind offer can be
    # bought until the cache next rebuilds -- the client keeps showing the row
    # it was given, and a server that answers "yes" every time to one offer id
    # is an infinite supply of anything with a handbook price.
    #
    # An offer sold in one piece is *spent*, not decremented: "in one piece"
    # means the lot goes whole, and it was already paid for whole -- `perOffer`
    # above hands over the entire quantity for the entire price. Taking one off
    # the count instead left a lot of three that could be bought three times,
    # three items each. Nobody got anything for nothing, which is why it was
    # quiet, but nine items came out of an offer for three.
    if not o.unlimited:
      for i in 0 ..< gOffers.len:
        if gOffers[i].id == offerId:
          if o.sellInOnePiece:
            gOffers[i].quantity = 0
          else:
            gOffers[i].quantity = gOffers[i].quantity - count
          if gOffers[i].quantity < 0:
            gOffers[i].quantity = 0
          break
  result = true

proc addOffer*(inv: var Inventory; action: JsonRef; profileId, stashId: string;
               ch: var Change; nowSec: int): bool =
  ## `RagFairAddOffer`: the player lists something.
  ##
  ## The items leave the stash and are kept, whole, in the offer record. They
  ## have to be kept rather than remembered by id: when the offer expires the
  ## items are posted back, and by then there is nothing left in the profile to
  ## look them up in.
  let ids = each(action.field("items"))
  if ids.len == 0:
    ch.problems.add "an offer with no items in it is not an offer"
    return false

  # Only things *in the stash* may be listed, and that is not a tidiness rule.
  #
  # `RagFairAddOffer` naming the stash itself was accepted -- `err:0`, no
  # warning -- and listing an item takes it and everything under it out of the
  # profile. The stash is everything under it. The answer came back with
  # `Inventory.stash` naming an item that was no longer in `items`, and every
  # rouble and every purchase went with it.
  #
  # The five containers a profile is built on are exactly the items with no
  # `parentId`, so "walk up and see where you land" catches all of them without
  # this module needing to know their ids -- and it catches equipped gear too,
  # which hangs off the equipment root rather than the stash and is not for
  # sale either.
  for e in ids:
    let id = e.asText("")
    if id.len == 0:
      continue
    let at = indexOf(inv, id)
    if at < 0:
      # Reported by the per-item pass below, which says which one.
      continue
    if field(inv.items.items[at], "parentId").asText("").len == 0:
      ch.problems.add "that is a container the inventory is built on, " &
                      "not something to sell"
      return false
    if stashId.len > 0 and rootOf(inv, id) != stashId:
      ch.problems.add "only what is in the stash can be listed"
      return false

  let req = action.field("requirements").at(0)
  let currency = req.field("_tpl").asText(CurrencyRoubles)
  if not isCurrency(currency):
    ch.problems.add "this market lists items for money, not for barter"
    return false
  let price = req.field("count").asInt(0)
  if price <= 0:
    ch.problems.add "an offer priced at " & $price & " is not an offer"
    return false

  # Collected before anything is removed, for the same reason payment is
  # verified before it is taken: a listing that fails halfway has removed items
  # from the stash and recorded nothing that owes them back.
  var kept = newList()
  var rootTpl = ""
  var rootId = ""
  var total = 0
  var toRemove: seq[string] = @[]
  for e in ids:
    let id = e.asText("")
    let at = indexOf(inv, id)
    if at < 0:
      ch.problems.add "listing an item that is not here: " & id
      return false
    kept.add inv.items.items[at]
    if rootTpl.len == 0:
      rootTpl = field(inv.items.items[at], "_tpl").asText("")
      rootId = id
    var n = field(inv.items.items[at], "upd.StackObjectsCount").asInt(1)
    if n < 1: n = 1
    total = total + n
    toRemove.add id
    # Everything inside it goes up with it: a rifle listed without its
    # magazine comes back from expiry as a rifle without its magazine.
    let kids = descendantsOf(inv, id)
    for k in kids:
      let ki = indexOf(inv, k)
      if ki >= 0:
        kept.add inv.items.items[ki]

  # The listing fee, if `fleaSellFeePercent` is above zero. Charged HERE --
  # after every item in the offer has been found and before any of them is
  # removed -- so a listing that is refused for naming an item that is not
  # there has not already taken money for it. `spendCurrency` refuses when the
  # stash cannot cover it, and refusing is the whole point of a fee.
  if gSellFeePercent > 0:
    let lots = (if action.field("sellInOnePiece").asBool(false): 1 else: total)
    var fee = (price * lots * gSellFeePercent) div 100
    if fee < 1: fee = 1
    if not spendCurrency(inv, CurrencyRoubles, fee, stashId, ch):
      ch.problems.add "the flea market's listing fee is " & $fee &
                      " roubles and the stash cannot cover it; nothing " &
                      "was listed"
      return false

  for id in toRemove:
    if not removeItem(inv, id, ch):
      return false

  var rec = newDoc()
  setText(rec, "_id", newId())
  setText(rec, "tpl", rootTpl)
  setText(rec, "rootId", rootId)
  setText(rec, "currency", currency)
  setNumber(rec, "price", price)
  setNumber(rec, "count", total)
  setBool(rec, "sellInOnePiece", action.field("sellInOnePiece").asBool(false))
  setNumber(rec, "startTime", nowSec)
  setNumber(rec, "endTime", nowSec + gOfferHours * 3600)
  setNumber(rec, "sellsAt", nowSec + gSaleMinutes * 60)
  setRaw(rec, "items", text(kept))

  var list = playerOffers(profileId)
  list.add rec
  if not setPlayerOffers(profileId, list, playerRating(profileId)):
    ch.problems.add "the offer could not be recorded; nothing was listed"
    return false
  result = true

proc isRagfairAction*(kind: string): bool =
  result = kind == "RagFairBuyOffer" or kind == "RagFairAddOffer" or
           kind == "RagFairRemoveOffer" or kind == "RagFairRenewOffer"

proc maxRenewHours*(): int =
  ## `globals.config.RagFair.maxRenewOfferTimeInHour`, 48 in this database.
  ##
  ## Read rather than assumed, and defaulted to zero rather than to a number:
  ## a database that does not say how long an offer may be renewed for is one
  ## this server cannot bound a renewal against, and `renewOffer` refuses on it
  ## by name. Guessing 48 there would let a client extend an offer for as long
  ## as it liked on any database that happened to be missing the field.
  let v = dbRead("globals.config.RagFair.maxRenewOfferTimeInHour")
  if not v.ok:
    return 0
  result = whole(v.raw).asInt(0)

proc renewOffer*(action: JsonRef; profileId: string; ch: var Change;
                 nowSec: int): bool =
  ## `RagFairRenewOffer` -- `ExtendOfferRequestData`, which is `{offerId,
  ## renewalTime}` with `renewalTime` in hours.
  ##
  ## What it does is move one offer's `endTime` forward. What it deliberately
  ## does **not** do is charge for it, and that is worth stating rather than
  ## leaving to be noticed:
  ##
  ## **This server charges nothing to renew, because it charges nothing to
  ## list.** `addOffer` above takes no listing fee and no flea tax; a renewal
  ## fee would be the only money this market ever took from a seller. The
  ## database has one number that is plainly about the price --
  ## `RagFair.renewPricePerHour`, which is `0.5` here -- and nothing in it or in
  ## the reference dump says whether that is roubles per hour or a percentage of
  ## the asking price per hour. Those two readings differ by four orders of
  ## magnitude on an ordinary offer, and picking one would be inventing a price
  ## rather than reading one. The consequence for the player is that renewals
  ## are free on this server. That is more generous than the game, it is stated
  ## here and in `docs/EMULATOR-COVERAGE.md`, and it is not an oversight.
  ##
  ## Everything the database *does* decide is enforced: the offer must be the
  ## player's, it must not have expired already, and the extension may not
  ## exceed `maxRenewOfferTimeInHour`.
  let offerId = action.field("offerId").asText("")
  if offerId.len == 0:
    ch.problems.add "that request names no offer to renew"
    return false
  let hours = action.field("renewalTime").asInt(0)
  if hours <= 0:
    ch.problems.add "renewing an offer for " & $hours & " hours is not a " &
                    "renewal"
    return false
  let cap = maxRenewHours()
  if cap <= 0:
    ch.problems.add "this server's database does not say how long an offer " &
                    "may be renewed for, so it will not renew one; the offer " &
                    "was left as it is and will expire on time"
    return false
  if hours > cap:
    ch.problems.add "an offer may be renewed for " & $cap &
                    " hours at a time and that asked for " & $hours
    return false

  let list = playerOffers(profileId)
  var keep = newList()
  var hit = false
  for i in 0 ..< list.len:
    let e = whole(list.items[i])
    if e.field("_id").asText("") != offerId:
      keep.add list.items[i]
      continue
    let endTime = e.field("endTime").asInt(0)
    if endTime <= nowSec:
      # Kept in the list rather than dropped: `settleOffers` owns expiry and
      # owes the items back, and a renewal path that quietly deleted an expired
      # offer would owe them to nobody.
      keep.add list.items[i]
      ch.problems.add "that offer has already expired; it cannot be renewed"
      return false
    var rec = parseObject(list.items[i])
    if not rec.ok:
      keep.add list.items[i]
      ch.problems.add "that offer could not be read, so it was not renewed"
      return false
    setNumber(rec, "endTime", endTime + hours * 3600)
    keep.add text(rec)
    hit = true
  if not hit:
    ch.problems.add "there is no offer " & offerId & " to renew"
    return false
  result = setPlayerOffers(profileId, keep, playerRating(profileId))
  if not result:
    ch.problems.add "the renewal could not be recorded; the offer was left " &
                    "as it is"

proc removeOffer*(action: JsonRef; profileId: string; ch: var Change;
                  nowSec: int): bool =
  ## Taking a listing down. The items go back by mail rather than straight into
  ## the stash: the stash may be full by now, and the ordinary "no room"
  ## refusal would strand the items in an offer that no longer exists.
  let offerId = action.field("offerId").asText("")
  let list = playerOffers(profileId)
  var keep = newList()
  var hit = false
  for i in 0 ..< list.len:
    let e = whole(list.items[i])
    if e.field("_id").asText("") != offerId:
      keep.add list.items[i]
      continue
    hit = true
    discard deliver(profileId, "ragfair", "Your offer was withdrawn.",
                    mkAuction, nowSec, raw(e.field("items")))
  if not hit:
    ch.problems.add "there is no offer " & offerId & " to remove"
    return false
  result = setPlayerOffers(profileId, keep, playerRating(profileId))

proc applyRagfair*(inv: var Inventory; action: JsonRef; stashId, profileId,
                   nickname: string; ch: var Change; nowSec: int): bool =
  case action.field("Action").asText("")
  of "RagFairBuyOffer":
    result = buyOffer(inv, action, stashId, profileId, nickname, ch, nowSec)
  of "RagFairAddOffer":
    result = addOffer(inv, action, profileId, stashId, ch, nowSec)
  of "RagFairRemoveOffer":
    result = removeOffer(action, profileId, ch, nowSec)
  of "RagFairRenewOffer":
    result = renewOffer(action, profileId, ch, nowSec)
  else:
    ch.problems.add "unhandled flea action: " &
                    action.field("Action").asText("")
    result = false

# ---------------------------------------------------------------------------
# The passage of time
# ---------------------------------------------------------------------------

proc settleOffers*(profileId: string; nowSec: int): int =
  ## Sells what should have sold and returns what expired. Called on a timer
  ## *and* at login, for the reason `emu/insurance` gives: a server that was off
  ## when an offer came due must still settle it, and a timer alone never does.
  ##
  ## Whether an offer sells is a *price* question, not a dice roll. An offer at
  ## or below what the market charges for the same template sells once
  ## `sellsAt` passes; anything above it sits until it expires and comes back.
  ## That is a rule a player can act on, which random would not be, and it makes
  ## the outcome reproducible in a bug report.
  result = 0
  let list = playerOffers(profileId)
  if list.len == 0:
    return
  ensureMarket(nowSec)
  var rating = playerRating(profileId)
  var keep = newList()
  for i in 0 ..< list.len:
    let e = whole(list.items[i])
    let endTime = e.field("endTime").asInt(0)
    let sellsAt = e.field("sellsAt").asInt(0)
    let tpl = e.field("tpl").asText("")
    let price = e.field("price").asInt(0)
    let currency = e.field("currency").asText(CurrencyRoubles)

    var going = handbookPrice(tpl)
    if going > 0:
      going = (going * (100 + gSpreadPercent)) div 100

    if nowSec >= sellsAt and going > 0 and price <= going:
      # Paid by mail, in the currency the offer asked for. Mail rather than a
      # direct stash write because there may be nobody logged in to receive a
      # diff, and money that appears in a profile the client is not holding is
      # money the next save overwrites.
      var payment = newDoc()
      setText(payment, "_id", newId())
      setText(payment, "_tpl", currency)
      setText(payment, "parentId", "hideout")
      setText(payment, "slotId", "hideout")
      var upd = newDoc()
      setNumber(upd, "StackObjectsCount", price)
      setRaw(payment, "upd", text(upd))
      var items = newList()
      items.add payment
      if deliver(profileId, "ragfair", "Your offer sold.", mkAuction, nowSec,
                 text(items)):
        # A completed sale is what the rating is *for*. Capped at the client's
        # own maximum so the column does not run off the end of the row.
        rating = rating + 0.01
        if rating > 6.0: rating = 6.0
        inc result
      else:
        keep.add list.items[i]
      continue

    if nowSec >= endTime:
      if deliver(profileId, "ragfair", "Your offer expired.", mkAuction,
                 nowSec, raw(e.field("items"))):
        inc result
      else:
        # Undeliverable stays listed rather than being dropped. A player whose
        # gear vanished because a write failed has no way to tell.
        keep.add list.items[i]
      continue

    keep.add list.items[i]

  discard setPlayerOffers(profileId, keep, rating)

# ---------------------------------------------------------------------------
# Self-check
# ---------------------------------------------------------------------------

proc mkOffer(id, tpl, seller: string; price, quantity, endTime: int;
             currency: string; trader: bool; category: string): Offer =
  result = Offer(id: id, tpl: tpl, itemsJson: "[]", rootId: id,
                 sellerId: seller, seller: seller,
                 memberType: MemberTypePlayer, rating: 1.0, ratingGrowing: true, price: price,
                 currency: currency, loyalty: 1, quantity: quantity,
                 unlimited: trader, sellInOnePiece: false, startTime: 0,
                 endTime: endTime, category: category, name: tpl,
                 nameKnown: true)
  if trader:
    result.memberType = MemberTypeTrader

proc selfCheck*(): seq[string] =
  ## The parts that are pure text: the filter, the sort, the category walk and
  ## the response shape. Written as a proc rather than as a test binary because
  ## the module has to be provable before anything imports it -- and because the
  ## checks that matter here are about JSON the client parses, not about the
  ## database.
  result = @[]

  # The filter reads what the client sends, including the two other spellings
  # of the text box.
  let f = readFilter("{\"page\":2,\"limit\":10,\"sortType\":5," &
                     "\"sortDirection\":1,\"priceFrom\":100,\"currency\":1," &
                     "\"handbookId\":\"cat1\",\"searchText\":\"ak\"}")
  if f.page != 2 or f.limit != 10: result.add "readFilter: pagination"
  if f.sortType != 5 or f.sortDirection != 1: result.add "readFilter: sort"
  if f.priceFrom != 100 or f.currency != 1: result.add "readFilter: price"
  if f.category != "cat1": result.add "readFilter: category"
  if f.text != "ak": result.add "readFilter: searchText spelling"

  # An absent limit must not become zero -- a page size of zero is an empty
  # market on a server that has offers, which reads as a broken database.
  let f2 = readFilter("{}")
  if f2.limit < 1: result.add "readFilter: an absent limit must have a default"

  # Sorting, both directions.
  var offers: seq[Offer] = @[]
  offers.add mkOffer("c", "t1", "s1", 300, 1, 100, CurrencyRoubles, false, "x")
  offers.add mkOffer("a", "t2", "s2", 100, 1, 300, CurrencyRoubles, true, "x")
  offers.add mkOffer("b", "t3", "s3", 200, 1, 200, CurrencyDollars, false, "y")
  var byPrice = offers
  sortOffers(byPrice, 5, 0)
  if byPrice[0].price != 100 or byPrice[2].price != 300:
    result.add "sortOffers: ascending price"
  var byPriceDesc = offers
  sortOffers(byPriceDesc, 5, 1)
  if byPriceDesc[0].price != 300:
    result.add "sortOffers: descending price"
  var byExpiry = offers
  sortOffers(byExpiry, 6, 0)
  if byExpiry[0].endTime != 100:
    result.add "sortOffers: expiry"

  # The filter itself.
  let priced = readFilter("{\"priceFrom\":150,\"priceTo\":250}")
  var kept = 0
  for o in offers:
    if matchesExceptCategory(o, -1, priced, 0): inc kept
  if kept != 1: result.add "filter: a price range must exclude both ends"

  let dollars = readFilter("{\"currency\":2}")
  kept = 0
  for o in offers:
    if matchesExceptCategory(o, -1, dollars, 0): inc kept
  if kept != 1: result.add "filter: currency"

  let tradersOnly = readFilter("{\"offerOwnerType\":1}")
  kept = 0
  for o in offers:
    if matchesExceptCategory(o, -1, tradersOnly, 0): inc kept
  if kept != 1: result.add "filter: owner type"

  let byId = readFilter("{\"text\":\"T2\"}")
  kept = 0
  for o in offers:
    if matchesExceptCategory(o, -1, byId, 0): inc kept
  if kept != 1: result.add "filter: text must match a template id, case-free"

  # The category walk, over a tree that is two deep.
  gCategories = @[]
  gCategories.add Category(id: "rifles", parent: "weapons")
  gCategories.add Category(id: "weapons", parent: "")
  gCategories.add Category(id: "meds", parent: "")
  if not inCategory("rifles", "weapons"):
    result.add "inCategory: a child must be inside its parent"
  if inCategory("meds", "weapons"):
    result.add "inCategory: an unrelated branch must not match"
  if not inCategory("meds", ""):
    result.add "inCategory: an empty filter must match everything"

  # A cycle must terminate rather than hang the request thread.
  gCategories = @[]
  gCategories.add Category(id: "a", parent: "b")
  gCategories.add Category(id: "b", parent: "a")
  if inCategory("a", "nowhere"):
    result.add "inCategory: a cycle must not match"

  # The response shape. The client reads `err` first, then indexes `offers` and
  # `categories` without checking either.
  let row = done(offerJson(offers[0], 0)).text
  if field(row, "_id").asText("") != "c": result.add "offerJson: _id"
  if field(row, "requirements[0].count").asInt(0) != 300:
    result.add "offerJson: the price must be in requirements"
  if field(row, "user.nickname").asText("") != "s1":
    result.add "offerJson: seller"
  if not field(row, "endTime").found: result.add "offerJson: expiry"
  if not field(row, "unlimitedCount").found: result.add "offerJson: stock"

  # An empty market is a valid market: this is the response a server with no
  # database has to give, and the flea screen must open on it.
  gOffers = @[]
  gBuilt = true
  gBuiltAt = 0
  let empty = searchResult("{}", "", "", 0)
  if not field(empty, "offers").isArray():
    result.add "searchResult: offers must be an array even when empty"
  if field(empty, "offersCount").asInt(-1) != 0:
    result.add "searchResult: offersCount"
  if not field(empty, "categories").isObject():
    result.add "searchResult: categories must be an object"
  gBuilt = false
