## Traders: who they are, and what they have for sale.
##
## Two shapes, and they are not interchangeable. `base` is the trader itself —
## name, currency, loyalty levels, insurance — and the client reads every one of
## them at the menu. `assort` is the stock: an item list, a barter scheme naming
## what each costs, and a loyalty gate per offer. A trader with a base and no
## assort is a trader you can visit and cannot buy from, which is a valid state
## and the one used when the database has no stock for them.
##
## Everything comes out of the database under `traders.<id>`, so a server with a
## live dump has the real traders and a server with the test fixture has none —
## and the menu still opens either way, which is the property that matters.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json

proc traderIds*(): seq[string] =
  ## Every trader in the database, in document order.
  result = @[]
  let all = dbRead("traders")
  if not all.ok:
    return
  result = keys(whole(all.raw))

proc traderBase*(id: string): string =
  let v = dbRead("traders." & id & ".base")
  if v.ok and v.raw.len > 0:
    return v.raw
  result = ""

proc traderSettings*(): string =
  ## The array the client's trader screen is built from.
  var a = arr()
  let ids = traderIds()
  for id in ids:
    let base = traderBase(id)
    if base.len > 0:
      a.add raw(base)
  result = done(a).text

proc emptyAssort(): string =
  ## The shape of "this trader has nothing", spelled out. An empty *object*
  ## here instead of these three empty collections is a null dereference in the
  ## trading screen -- the client indexes `items` before it checks it.
  var o = obj()
  put(o, "nextResupply", 0)
  put(o, "items", arr())
  put(o, "barter_scheme", obj())
  put(o, "loyal_level_items", obj())
  result = done(o).text

proc traderAssort*(id: string; resupplyAt: int): string =
  let v = dbRead("traders." & id & ".assort")
  if not v.ok or v.raw.len == 0:
    return emptyAssort()
  # `nextResupply` is a timestamp the client counts down to. Taken from the
  # database when it is there and stamped here when it is not, because a
  # missing one shows as a stock timer that has already expired.
  let existing = field(v.raw, "nextResupply")
  if existing.found:
    return v.raw
  var o = obj()
  put(o, "nextResupply", resupplyAt)
  put(o, "items", raw(field(v.raw, "items").raw()))
  put(o, "barter_scheme", raw(field(v.raw, "barter_scheme").raw()))
  put(o, "loyal_level_items", raw(field(v.raw, "loyal_level_items").raw()))
  result = done(o).text

proc traderExists*(id: string): bool =
  result = traderBase(id).len > 0

proc newTradersInfo*(): string =
  ## What a fresh profile knows about each trader: nothing bought, nothing
  ## unlocked, standing at zero. Built from whatever traders the database has,
  ## so a profile created on a server with no traders does not carry entries for
  ## traders that do not exist.
  var o = obj()
  let ids = traderIds()
  for id in ids:
    var t = obj()
    put(t, "loyaltyLevel", 1)
    put(t, "salesSum", 0)
    put(t, "standing", 0.0)
    put(t, "nextResupply", 0)
    put(t, "unlocked", true)
    put(t, "disabled", false)
    put(o, id, t)
  result = done(o).text
