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

proc stashTemplate(inv: Inventory; stashId: string): string =
  let at = indexOf(inv, stashId)
  if at < 0:
    return ""
  result = field(inv.items.items[at], "_tpl").asText("")

proc giveItem*(inv: var Inventory; tpl, stashId: string; count: int;
               ch: var Change; newIdIn: string = ""): bool =
  ## Puts a new item in the stash, in a cell that is actually free.
  ##
  ## Stacked in one item when the template says it stacks and the count fits,
  ## and refused when the stash has no room -- refused rather than placed at
  ## 0,0, because an item overlapping another is drawn on top of it and cannot
  ## be picked up, which looks like the item was never given.
  var g = stashGrid(stashTemplate(inv, stashId))
  markOccupied(g, text(inv.items), stashId)
  let place = findSpace(g, tpl)
  if not place.ok:
    ch.problems.add "there is no room in the stash for that"
    return false

  var d = newDoc()
  setText(d, "_id", if newIdIn.len > 0: newIdIn else: newId())
  setText(d, "_tpl", tpl)
  setText(d, "parentId", stashId)
  setText(d, "slotId", "hideout")
  setRaw(d, "location", locationJson(place))
  if count > 1:
    var upd = newDoc()
    setNumber(upd, "StackObjectsCount", count)
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

proc buyFromTrader*(inv: var Inventory; action: JsonRef; stashId: string;
                    ch: var Change): bool =
  let traderId = action.field("tid").asText("")
  let offerId = action.field("item_id").asText("")
  var count = action.field("count").asInt(1)
  if count < 1: count = 1

  let offer = assortItem(traderId, offerId)
  if offer.len == 0:
    ch.problems.add "that trader has no offer " & offerId
    return false

  if not takePayment(inv, action.field("scheme_items"), ch):
    return false
  result = giveItem(inv, field(offer, "_tpl").asText(""), stashId, count, ch)

proc sellToTrader*(inv: var Inventory; action: JsonRef; stashId: string;
                   ch: var Change): bool =
  ## The items go, the money arrives. The price is the trader's, and when the
  ## database has no handbook price for something the sale is refused rather
  ## than paid at zero -- a player who sells a rifle for nothing has lost it.
  let entries = each(action.field("items"))
  var total = 0
  var toRemove: seq[string] = @[]
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
    total = total + price * n
    toRemove.add id

  for id in toRemove:
    if not removeItem(inv, id, ch):
      return false
  if total <= 0:
    return true
  result = giveItem(inv, Roubles, stashId, total, ch)

proc applyTrading*(inv: var Inventory; action: JsonRef; stashId: string;
                   ch: var Change): bool =
  case action.field("type").asText("")
  of "buy_from_trader": result = buyFromTrader(inv, action, stashId, ch)
  of "sell_to_trader": result = sellToTrader(inv, action, stashId, ch)
  else:
    ch.problems.add "unhandled trade type: " & action.field("type").asText("")
    result = false
