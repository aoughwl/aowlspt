## Buying and selling.
##
## Both arrive as a `TradingConfirm` action on the item-moving endpoint, and both
## are the same two steps in opposite order: take something out of the player's
## inventory and put something else in. What makes them worth their own module
## is that the taking has to be exact.
##
## Money is stacks, not a number. Paying 25,000 roubles from a stack of 500,000
## means editing that stack; paying from three stacks of 10,000 means consuming
## two and editing the third. A server that treats currency as a balance and
## rewrites one stack loses the rest of the player's money, and it loses it
## silently, because the client believes whatever the diff says.
##
## Nothing here trusts the client's arithmetic. The request says which stacks to
## pay from and how much from each; the server checks each of those stacks holds
## what the request claims before it takes anything.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import ids
import templates
import inventory
import grid
import profile
import traders

const
  Roubles* = "5449016a4bdc2d6f028b456f"
  Dollars* = "5696686a4bdc2da3298b456a"
  Euros* = "569668774bdc2da2298b4568"

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

proc takePayment*(inv: var Inventory; scheme: JsonRef; ch: var Change): bool =
  ## `scheme` is the request's `scheme_items`: which stacks to pay from and how
  ## much from each.
  ##
  ## Checked completely before anything is taken. A half-applied payment leaves
  ## the player short with nothing to show for it, and there is no transaction
  ## to roll back -- so the transaction is "verify everything, then act".
  let entries = each(scheme)
  var indices: seq[int] = @[]
  var amounts: seq[int] = @[]
  for e in entries:
    let id = e.field("id").asText("")
    let want = e.field("count").asInt(0)
    let at = indexOf(inv, id)
    if at < 0:
      ch.problems.add "payment names an item that is not here: " & id
      return false
    if want <= 0:
      ch.problems.add "a payment of " & $want & " is not a payment"
      return false
    if stackOf(inv, at) < want:
      ch.problems.add "not enough in that stack to pay " & $want
      return false
    indices.add at
    amounts.add want

  # Consumed stacks are removed after the loop, by id: removing inside it would
  # shift every index still to be used.
  var spent: seq[string] = @[]
  for k in 0 ..< indices.len:
    let at = indices[k]
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
  result = true

proc topLevelStack(inv: Inventory; index: int; stashId, tpl: string): bool

proc spendCurrency*(inv: var Inventory; tpl: string; amount: int;
                    stashId: string; ch: var Change): bool =
  ## Takes money out of the stash when the **server** picks the stacks.
  ##
  ## `takePayment` is the other half of this and is not a substitute: it applies
  ## when the client names the stacks to pay from, which is what a trade does.
  ## An `Insure` carries no `scheme_items` at all -- the real server decides
  ## where the premium comes from -- and a server that answered "no payment
  ## named" to that would make insurance unbuyable.
  ##
  ## Smallest stacks first, and that is not tidiness. `tools/soak` holds the
  ## profile to money living in the fewest stacks it will fit in --
  ## `ceil(total / StackMaxSize)` -- and paying out of the largest stack breaks
  ## it: 500000 + 100 paying 200 leaves 499800 + 100, which is two stacks where
  ## one would do. Consuming the small change first leaves 499900 in one.
  ##
  ## Verified before anything is taken, like every other payment here.
  if amount <= 0:
    return true
  var indices: seq[int] = @[]
  var have = 0
  for i in 0 ..< inv.items.len:
    if not topLevelStack(inv, i, stashId, tpl):
      continue
    indices.add i
    have = have + stackOf(inv, i)
  if have < amount:
    ch.problems.add "that costs " & $amount & " and the stash holds " & $have
    return false

  # Smallest first, by repeated selection into a second list rather than by
  # swapping in place. The list is the handful of loose currency stacks in one
  # stash, so the cost of the sort does not matter and the order does.
  var order: seq[int] = @[]
  var taken: seq[bool] = @[]
  for i in 0 ..< indices.len:
    taken.add false
  for step in 0 ..< indices.len:
    var pick = -1
    var pickSize = 0
    for k in 0 ..< indices.len:
      if taken[k]:
        continue
      let size = stackOf(inv, indices[k])
      if pick < 0 or size < pickSize:
        pick = k
        pickSize = size
    if pick < 0:
      break
    taken[pick] = true
    order.add indices[pick]

  var left = amount
  var spent: seq[string] = @[]
  for at in order:
    if left <= 0:
      break
    let held = stackOf(inv, at)
    if held <= left:
      left = left - held
      spent.add field(inv.items.items[at], "_id").asText("")
    else:
      setStack(inv, at, held - left)
      ch.changed.add inv.items.items[at]
      left = 0
  for id in spent:
    let at = indexOf(inv, id)
    if at >= 0:
      inv.items.removeAt(at)
      ch.deleted.add id
  inv.dirty = true
  result = true

proc stashTemplate(inv: Inventory; stashId: string): string =
  let at = indexOf(inv, stashId)
  if at < 0:
    return ""
  result = field(inv.items.items[at], "_tpl").asText("")

proc topLevelStack(inv: Inventory; index: int; stashId, tpl: string): bool =
  ## Is this item a loose stack of `tpl` lying in the stash itself?
  ##
  ## Loose is the whole question. A stack inside a rig, a backpack or a weapon
  ## is not somewhere a payout may silently be added to -- the player put it
  ## there, the container has its own grid, and growing a stack inside one can
  ## push it over that container's capacity.
  let it = whole(inv.items.items[index])
  if it.field("_tpl").asText("") != tpl:
    return false
  if it.field("parentId").asText("") != stashId:
    return false
  result = it.field("slotId").asText("") == "hideout"

proc giveItem*(inv: var Inventory; tpl, stashId: string; count: int;
               ch: var Change; newIdIn: string = ""): bool =
  ## Puts items in the stash: merged into the stacks already there where they
  ## fit, and in real free cells where a new stack is needed.
  ##
  ## The merge is not a nicety. Without it every payout, purchase, craft output
  ## and mail reward opened a *fresh* stack, and a soak of 200 play cycles ended
  ## with 407 loose items in a stash that started with five -- roubles in fifty
  ## separate stacks, the largest of them 471125 of a possible 500000, because
  ## the fifty-first sale opened stack #51 rather than putting 1100 roubles into
  ## the 28875 cells of headroom sitting next to it. A stash fills with change,
  ## every request carries the whole item list, and latency tracks it: the same
  ## soak measured 797 us per request at the start and 105 ms at the end.
  ##
  ## `StackMaxSize` is honoured on the way in, which is the other half. Writing
  ## `count` straight into `StackObjectsCount` produced a stack over the
  ## template's own limit -- a stack the client will not render and `doMerge`
  ## will not touch, from a single large payout.
  ##
  ## Refused, rather than placed at 0,0, when the stash has no room: an item
  ## overlapping another is drawn on top of it and cannot be picked up, which
  ## looks exactly like never having been given it. And refused *whole* --
  ## nothing is written until every stack this needs has somewhere to go, for
  ## the same reason payment is verified before it is taken.
  var remaining = count
  if remaining < 1:
    remaining = 1

  # Zero means "the database does not have this template", which is a different
  # answer from one. An unknown limit merges and splits at nothing, so a server
  # with no item table behaves exactly as it did before.
  let limit = itemStackLimit(tpl)

  # ---- plan the merges (nothing is written yet) --------------------------
  var mergeAt: seq[int] = @[]
  var mergeTo: seq[int] = @[]
  if limit > 1 and newIdIn.len == 0:
    for i in 0 ..< inv.items.len:
      if remaining <= 0:
        break
      if not topLevelStack(inv, i, stashId, tpl):
        continue
      let have = stackOf(inv, i)
      if have >= limit:
        continue
      var room = limit - have
      if room > remaining:
        room = remaining
      mergeAt.add i
      mergeTo.add have + room
      remaining = remaining - room

  # ---- plan the new stacks ----------------------------------------------
  var g = stashGrid(stashTemplate(inv, stashId))
  markOccupied(g, text(inv.items), stashId)
  var places: seq[Placement] = @[]
  var sizes: seq[int] = @[]
  var w = 1
  var h = 1
  itemSize(tpl, w, h)
  while remaining > 0:
    var take = remaining
    if limit > 0 and take > limit:
      take = limit
    let place = findSpace(g, tpl)
    if not place.ok:
      ch.problems.add "there is no room in the stash for that"
      return false
    # Occupied on the planning grid too, so the second stack of a split payout
    # is not placed in the cell the first one just took.
    if place.rotated:
      occupy(g, place.x, place.y, h, w)
    else:
      occupy(g, place.x, place.y, w, h)
    places.add place
    sizes.add take
    remaining = remaining - take

  # ---- act ---------------------------------------------------------------
  for k in 0 ..< mergeAt.len:
    setStack(inv, mergeAt[k], mergeTo[k])
    ch.changed.add inv.items.items[mergeAt[k]]
    inv.dirty = true

  for k in 0 ..< places.len:
    var d = newDoc()
    setText(d, "_id", if k == 0 and newIdIn.len > 0: newIdIn else: newId())
    setText(d, "_tpl", tpl)
    setText(d, "parentId", stashId)
    setText(d, "slotId", "hideout")
    setRaw(d, "location", locationJson(places[k]))
    # `upd.StackObjectsCount` is always present, even on a stack of one: the
    # real backend sends it on every `items.new` entry, and the post-1.0 client
    # builds the item's stack component from it -- a new item with no `upd` is
    # one it cannot construct, which is a purchase that never lands and a buy
    # button that spins.
    block:
      var upd = newDoc()
      setNumber(upd, "StackObjectsCount", sizes[k])
      setRaw(d, "upd", text(upd))
    inv.items.add d
    inv.dirty = true
    ch.created.add text(d)
  result = true

proc assortItem*(traderId, itemId: string): string =
  ## One offer out of a trader's assort, as raw JSON. Empty when the trader or
  ## the offer is not there -- which is a refusal, not a reason to invent one.
  let assort = dbRead("traders." & traderId & ".assort.items")
  if not assort.ok:
    return ""
  let list = each(whole(assort.raw))
  for it in list:
    if it.field("_id").asText("") == itemId:
      return raw(it)
  result = ""

var gScaledArm = ""
  ## Backing text for the rewritten arm below. A `JsonRef` is a view into a
  ## string, so the string it views has to outlive the call that made it --
  ## returning a view of a local is a read of freed memory, and the shape of
  ## bug that reads as "prices are sometimes wrong".

proc schemeArm(traderId, offerId: string; index: int): JsonRef =
  ## What an offer costs: one arm of its `barter_scheme`, as the array of
  ## `{_tpl, count}` the player has to hand over. An offer the scheme does not
  ## mention is `notFound`, which is a trader whose stock has no prices -- the
  ## database's problem, not a licence to charge nothing.
  result = notFound()
  let v = dbRead("traders." & traderId & ".assort.barter_scheme." & offerId)
  if not v.ok or v.raw.len == 0:
    return
  let arms = whole(v.raw)
  var arm = at(arms, index)
  if not arm.found:
    arm = at(arms, 0)
  if not arm.found or traderPriceMultiplier() == 1.0:
    return arm
  # The trader price multiplier, applied to what the server CHARGES.
  #
  # Here rather than in the caller, and returning a rewritten arm rather than
  # offering a second "scaled" accessor beside this one: `emu/traders` already
  # scales the same `count` on the way out to the trade screen, and two
  # accessors is one accessor somebody calls by mistake. A shop that shows half
  # price and refuses the payment is the failure that costs, and it is the
  # failure that a second entry point makes possible.
  var outArr = arr()
  for req in each(arm):
    var r = obj()
    for k in keys(req):
      if k == "count":
        put(r, "count", scaleTraderCount(field(req, k).asInt(0)))
      else:
        put(r, k, raw(field(req, k).raw()))
    outArr.add r
  gScaledArm = done(outArr).text
  result = whole(gScaledArm)

proc roubleValue*(tpl: string; count: int): int =
  ## What `count` of a currency is worth in roubles, for the purpose of a
  ## trader's `salesSum`.
  ##
  ## Roubles are worth themselves. Anything else is converted through its own
  ## handbook price, which is where the game keeps the exchange rate -- and a
  ## currency the handbook does not price returns **zero**, meaning "not
  ## counted", rather than being counted at face value. A dollar counted as a
  ## rouble is a loyalty level reached a hundred times too slowly, silently.
  if count <= 0:
    return 0
  if tpl == Roubles:
    return count
  let unit = handbookPrice(tpl)
  if unit <= 0:
    return 0
  result = unit * count

proc buyFromTrader*(p: var Profile; inv: var Inventory; action: JsonRef;
                    ch: var Change): bool =
  ## **The price is the trader's, not the request's.** `takePayment` only ever
  ## checked that the stacks the request named held what the request claimed --
  ## so a body naming one rouble bought a 25000-rouble rifle, and a body naming
  ## `count: 100` bought a hundred of them for the same one rouble. The offer's
  ## own `barter_scheme` is now the authority, matched by template so a barter
  ## is checked the same way money is, and multiplied by the count asked for.
  let traderId = action.field("tid").asText("")
  let offerId = action.field("item_id").asText("")
  var count = action.field("count").asInt(1)
  if count < 1: count = 1

  let offer = assortItem(traderId, offerId)
  if offer.len == 0:
    ch.problems.add "that trader has no offer " & offerId
    return false

  # And no lower than the loyalty level the assort gates it behind. The client
  # greys the offer out, which means a request for it is either a stale screen
  # or an edited client -- and selling past the gate makes every trader's whole
  # stock available at LL1, which is the entire progression the trader screen
  # is about.
  let gate = offerLoyalty(traderId, offerId)
  if gate > 0 and loyaltyOf(p, traderId) < gate:
    ch.problems.add "that offer needs loyalty level " & $gate & " and you are " &
                    $loyaltyOf(p, traderId)
    return false

  # And no more than the trader has. Zero means the assort does not say, which
  # on this server means unlimited -- an invented limit would refuse purchases
  # a live database allows.
  #
  # `traderIgnoreStockLimits` removes this bound and only this one: it is the
  # per-item purchase limit the settings page names.
  let stock = field(offer, "upd.StackObjectsCount").asInt(0)
  if not traderIgnoreStockLimits() and stock > 0 and count > stock:
    ch.problems.add "that trader has only " & $stock & " of those"
    return false

  let scheme = action.field("scheme_items")
  let arm = schemeArm(traderId, offerId, action.field("scheme_id").asInt(0))
  if arm.found and isArray(arm):
    let paid = each(scheme)
    let wants = each(arm)
    for w in wants:
      let wantTpl = w.field("_tpl").asText("")
      let need = w.field("count").asInt(0) * count
      if need <= 0 or wantTpl.len == 0:
        continue
      # Summed by *template*, not by the ids the request happens to name: what
      # matters is that 25000 roubles' worth of roubles is on the table, from
      # however many stacks the player is paying out of.
      var have = 0
      for pe in paid:
        let at = indexOf(inv, pe.field("id").asText(""))
        if at < 0:
          continue
        if field(inv.items.items[at], "_tpl").asText("") != wantTpl:
          continue
        have = have + pe.field("count").asInt(0)
      if have < need:
        ch.problems.add "that offer costs " & $need & " of " & wantTpl &
                        " and the payment covers " & $have
        return false
  else:
    ch.problems.add "that trader has no price for " & offerId
    return false

  if not takePayment(inv, scheme, ch):
    return false
  if not giveItem(inv, field(offer, "_tpl").asText(""), p.stashId, count, ch):
    return false

  # What the purchase was worth, credited to this trader's `salesSum`. Summed
  # off the *offer's* barter scheme rather than off the payment, for the same
  # reason the payment was checked against it: the request's numbers are the
  # request's.
  if arm.found and isArray(arm):
    var spent = 0
    for w in each(arm):
      spent = spent + roubleValue(w.field("_tpl").asText(""),
                                  w.field("count").asInt(0) * count)
    addSalesSum(p, traderId, spent)
  result = true

proc sellToTrader*(p: var Profile; inv: var Inventory; action: JsonRef;
                   ch: var Change): bool =
  ## The items go, the money arrives. The price is the trader's, and when the
  ## database has no handbook price for something the sale is refused rather
  ## than paid at zero -- a player who sells a rifle for nothing has lost it.
  ##
  ## **The count is the server's, not the request's.** This used to pay
  ## `price * count` straight off the body: one water bottle sold as five paid
  ## 75000 roubles for a 15000-rouble item, `err:0`, no warning, and the stack
  ## in the stash was a stack of one the whole time. Free money is the worst
  ## thing an emulator can hand out, so every entry is now checked against the
  ## `StackObjectsCount` the profile actually holds -- including the same id
  ## named twice in one request, which is the obvious way round a per-entry
  ## check.
  ##
  ## A partial sale leaves the rest of the stack. Selling 3 of 10 used to
  ## delete all ten and pay for three.
  let entries = each(action.field("items"))
  var total = 0
  var soldIds: seq[string] = @[]
  var soldN: seq[int] = @[]
  for e in entries:
    let id = e.field("id").asText("")
    let at = indexOf(inv, id)
    if at < 0:
      ch.problems.add "selling an item that is not here: " & id
      return false
    let tpl = field(inv.items.items[at], "_tpl").asText("")
    let price = handbookPrice(tpl)
    if price <= 0:
      ch.problems.add "no price is known for that item; refusing to sell it"
      return false
    var n = e.field("count").asInt(1)
    if n < 1: n = 1
    let have = stackOf(inv, at)
    var already = 0
    var seen = -1
    for k in 0 ..< soldIds.len:
      if soldIds[k] == id:
        already = already + soldN[k]
        seen = k
    if already + n > have:
      ch.problems.add "that stack holds " & $have & ", not " & $(already + n)
      return false
    total = total + price * n
    if seen >= 0:
      soldN[seen] = soldN[seen] + n
    else:
      soldIds.add id
      soldN.add n

  # Verified in full above, so the removals below cannot fail partway and leave
  # the player short with the money already paid.
  for k in 0 ..< soldIds.len:
    let at = indexOf(inv, soldIds[k])
    if at < 0:
      ch.problems.add "selling an item that is not here: " & soldIds[k]
      return false
    let have = stackOf(inv, at)
    if soldN[k] >= have:
      if not removeItem(inv, soldIds[k], ch):
        return false
    else:
      setStack(inv, at, have - soldN[k])
      ch.changed.add inv.items.items[at]
      inv.dirty = true
  if total <= 0:
    return true
  if not giveItem(inv, Roubles, p.stashId, total, ch):
    return false
  # Money the trader paid out counts towards the player's standing with them
  # exactly as money paid in does -- `TraderInfo.salesSum` is the turnover, not
  # the spend.
  addSalesSum(p, action.field("tid").asText(""), total)
  result = true

proc applyTrading*(p: var Profile; inv: var Inventory; action: JsonRef;
                   ch: var Change): bool =
  case action.field("type").asText("")
  of "buy_from_trader": result = buyFromTrader(p, inv, action, ch)
  of "sell_to_trader": result = sellToTrader(p, inv, action, ch)
  else:
    ch.problems.add "unhandled trade type: " & action.field("type").asText("")
    result = false
