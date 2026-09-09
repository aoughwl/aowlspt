## The player's own bookkeeping: insurance, the wishlist, favourites, pins and
## hotkeys.
##
## These arrive down `/client/game/profile/items/moving` like everything else,
## and they have one thing in common that earns them a module: **they edit the
## profile, not the item list.** `Inventory` deliberately knows nothing about a
## profile, and every one of these writes to `InsuredItems`, `WishList`,
## `Inventory.favoriteItems` or `Inventory.fastPanel` — so putting them in
## `emu/inventory` would mean handing it the profile, and putting them in
## `emu/quests` would mean calling a quest module to bookmark a rifle.
##
## The shapes are the reference's, not guesses. `InsureRequestData` is
## `{tid, items:[id...]}`, `AddToWishlistRequest` is `{items:{tpl:category}}`,
## `RemoveFromWishlistRequest` is `{items:[tpl...]}`,
## `ChangeWishlistItemCategoryRequest` is `{item, category}`, `SetFavoriteItems`
## is `{items:[id...]}`, `PinOrLockItemRequest` is `{Item, State}` with `State`
## one of `Free`/`Locked`/`Pinned`, and `InventoryBindRequestData` is
## `{item, index}`.
##
## ## Insurance was quoted and could not be bought
##
## `/client/insurance/items/list/cost` has always answered with a premium per
## item, and `emu/insurance` has always returned exactly the insured items that
## did not come home. What was missing between the two was the `Insure` action:
## nothing ever wrote `InsuredItems`, so the list was empty on every profile,
## every raid, forever. The quote screen worked, the money was never taken, and
## nothing ever came back.
##
## Which means the premium is charged **here**, out of the stash, and not by
## `takePayment`: the client's `Insure` body carries no `scheme_items`, because
## the real server picks the currency itself. So the money is found in the
## player's own loose stacks — `spendCurrency` in `emu/trading` — and the
## whole premium is verified before any of it is taken, the same rule as
## everywhere else in this server.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import profile
import inventory
import templates
import trading
import insurance

type
  PersonalAction* = enum
    peNone, peInsure, peWishlistAdd, peWishlistRemove, peWishlistCategory,
    peFavourites, pePinLock, peBind, peUnbind

proc personalAction*(kind: string): PersonalAction =
  ## The `Action` names are `ItemEventActions` in the reference, spelled the way
  ## the client spells them on the wire.
  case kind
  of "Insure": peInsure
  of "AddToWishList": peWishlistAdd
  of "RemoveFromWishList": peWishlistRemove
  of "ChangeWishlistItemCategory": peWishlistCategory
  of "SetFavoriteItems": peFavourites
  of "PinLock": pePinLock
  of "Bind": peBind
  of "Unbind": peUnbind
  else: peNone

# ---------------------------------------------------------------------------
# Insurance
# ---------------------------------------------------------------------------

proc alreadyInsured(list: List; itemId: string): bool =
  for i in 0 ..< list.len:
    if field(list.items[i], "itemId").asText("") == itemId:
      return true
  result = false

proc doInsure(p: var Profile; inv: var Inventory; action: JsonRef;
              percent: int; ch: var Change): bool =
  ## Pays a trader to insure a list of items.
  ##
  ## The price is the server's: the handbook price of each item's template,
  ## through `premiumFor`, which is the same arithmetic `/client/insurance/
  ## items/list/cost` quoted on the screen the player just clicked. An item the
  ## handbook has no price for is **refused**, not insured for nothing — free
  ## insurance makes insuring strictly better than not, and the whole point of
  ## the system is that it is a decision.
  ##
  ## Verified whole, then applied: the premium for every item is worked out and
  ## the money checked before a single rouble moves or a single entry is
  ## written. A half-paid insurance is a player charged for cover they do not
  ## have.
  var trader = action.field("tid").asText("")
  if trader.len == 0:
    # `InsureRequestData.TransactionId`. The client sends `tid`; the long name
    # is accepted because it costs nothing and the dump names the property, not
    # the wire key.
    trader = action.field("transactionId").asText("")
  if trader.len == 0:
    ch.problems.add "insure: no trader named"
    return false

  var insured = parseArray(p.field("InsuredItems").raw())
  if not insured.ok:
    insured = newList()

  var wanted: seq[string] = @[]
  var total = 0
  let ids = each(action.field("items"))
  for entry in ids:
    let id = entry.asText("")
    if id.len == 0:
      continue
    if alreadyInsured(insured, id):
      # Not a failure: the client re-sends the whole selection, and charging
      # twice for the same rifle is the bug this check exists to prevent.
      continue
    let at = indexOf(inv, id)
    if at < 0:
      ch.problems.add "insure: no such item " & id
      return false
    let tpl = field(inv.items.items[at], "_tpl").asText("")
    let premium = premiumFor(handbookPrice(tpl), percent)
    if premium <= 0:
      ch.problems.add "insure: no price is known for " & tpl
      return false
    total = total + premium
    wanted.add id

  if wanted.len == 0:
    # Everything named was insured already. Nothing to charge, nothing wrong.
    return true

  if not spendCurrency(inv, trading.Roubles, total, p.stashId, ch):
    return false

  for id in wanted:
    var e = newDoc()
    setText(e, "tid", trader)
    setText(e, "itemId", id)
    insured.add e
  p.setTopLevel("InsuredItems", text(insured))
  result = true

# ---------------------------------------------------------------------------
# The wishlist
# ---------------------------------------------------------------------------
#
# `WishList` on the profile is a map of **template** id to category number --
# the player is wishing for a kind of item, not for one particular one. The
# category is the client's own grouping and this server does not interpret it;
# it is stored and handed back.

proc wishlist(p: Profile): Doc =
  result = parseObject(p.field("WishList").raw())
  if not result.ok:
    result = newDoc()

proc doWishlistAdd(p: var Profile; action: JsonRef; ch: var Change): bool =
  var w = wishlist(p)
  let items = action.field("items")
  var added = 0
  for name in keys(items):
    if name.len == 0:
      continue
    setNumber(w, name, items.child(name).asInt(0))
    inc added
  if added == 0:
    ch.problems.add "wishlist: nothing to add"
    return false
  p.setTopLevel("WishList", text(w))
  result = true

proc doWishlistRemove(p: var Profile; action: JsonRef; ch: var Change): bool =
  var w = wishlist(p)
  var removed = 0
  for entry in each(action.field("items")):
    let tpl = entry.asText("")
    if tpl.len == 0 or not has(w, tpl):
      continue
    remove(w, tpl)
    inc removed
  if removed == 0:
    ch.problems.add "wishlist: nothing there to remove"
    return false
  p.setTopLevel("WishList", text(w))
  result = true

proc doWishlistCategory(p: var Profile; action: JsonRef; ch: var Change): bool =
  let tpl = action.field("item").asText("")
  var w = wishlist(p)
  if tpl.len == 0 or not has(w, tpl):
    ch.problems.add "wishlist: " & tpl & " is not on it"
    return false
  setNumber(w, tpl, action.field("category").asInt(0))
  p.setTopLevel("WishList", text(w))
  result = true

# ---------------------------------------------------------------------------
# Favourites, pins and the hotkey panel
# ---------------------------------------------------------------------------

proc doFavourites(p: var Profile; inv: Inventory; action: JsonRef;
                  ch: var Change): bool =
  ## `Inventory.favoriteItems` is a list of the player's **item** ids, and the
  ## request replaces it wholesale rather than adding to it -- the client sends
  ## the whole selection every time.
  ##
  ## Every id is checked against the inventory first. A favourite naming an item
  ## the player does not own is a star the client draws on nothing, and it
  ## survives every save until somebody notices.
  var list = newList()
  for entry in each(action.field("items")):
    let id = entry.asText("")
    if id.len == 0:
      continue
    if indexOf(inv, id) < 0:
      ch.problems.add "favourites: no such item " & id
      return false
    list.add quoted(id)
  var inventoryDoc = parseObject(p.field("Inventory").raw())
  if not inventoryDoc.ok:
    ch.problems.add "favourites: this profile has no inventory"
    return false
  setRaw(inventoryDoc, "favoriteItems", text(list))
  p.setTopLevel("Inventory", text(inventoryDoc))
  result = true

proc doPinLock(inv: var Inventory; action: JsonRef; ch: var Change): bool =
  ## `upd.PinLockState`, one of `Free`, `Locked`, `Pinned` -- the reference's
  ## `PinLockState`. An unknown state is refused rather than stored: the client
  ## compares this against its own enum and a value outside it pins nothing and
  ## reports nothing.
  let id = action.field("Item").asText(action.field("item").asText(""))
  let state = action.field("State").asText(action.field("state").asText(""))
  if state != "Free" and state != "Locked" and state != "Pinned":
    ch.problems.add "pin: " & state & " is not a pin state"
    return false
  let at = indexOf(inv, id)
  if at < 0:
    ch.problems.add "pin: no such item " & id
    return false
  var d = itemAt(inv, at)
  var upd = parseObject(getRaw(d, "upd"))
  if not upd.ok:
    upd = newDoc()
  setText(upd, "PinLockState", state)
  setRaw(d, "upd", text(upd))
  inv.items.replaceAt(at, text(d))
  inv.dirty = true
  ch.changed.add text(d)
  result = true

proc doBind(p: var Profile; inv: Inventory; action: JsonRef; bound: bool;
            ch: var Change): bool =
  ## The hotkey bar. `Inventory.fastPanel` is a map of slot index to item id,
  ## and binding an item to a slot that already holds one replaces it -- which
  ## is what the client draws, so anything else leaves the two disagreeing.
  ##
  ## `index` is a string in `InventoryBindRequestData` and it is kept as the
  ## map's key rather than turned into a number, because the client reads the
  ## key back and a "1" that came back as 1 is a different key.
  let id = action.field("item").asText("")
  let slot = action.field("index").asText("")
  var panel = parseObject(p.field("Inventory.fastPanel").raw())
  if not panel.ok:
    panel = newDoc()
  # The slots this item is on now, worked out before anything is removed: the
  # same item bound to a second slot must leave the first, or the client draws
  # one rifle in two places.
  let panelText = text(panel)
  var holding: seq[string] = @[]
  for existing in keys(whole(panelText)):
    if field(panelText, existing).asText("") == id:
      holding.add existing
  if bound:
    if slot.len == 0:
      ch.problems.add "bind: no slot named"
      return false
    if indexOf(inv, id) < 0:
      ch.problems.add "bind: no such item " & id
      return false
    for existing in holding:
      remove(panel, existing)
    setText(panel, slot, id)
  else:
    if holding.len == 0:
      ch.problems.add "unbind: " & id & " is not on the panel"
      return false
    for existing in holding:
      remove(panel, existing)
  var inventoryDoc = parseObject(p.field("Inventory").raw())
  if not inventoryDoc.ok:
    ch.problems.add "bind: this profile has no inventory"
    return false
  setRaw(inventoryDoc, "fastPanel", text(panel))
  p.setTopLevel("Inventory", text(inventoryDoc))
  result = true

# ---------------------------------------------------------------------------

proc applyPersonal*(p: var Profile; inv: var Inventory; kind: PersonalAction;
                    action: JsonRef; insurancePercent: int;
                    ch: var Change): bool =
  ## Returns whether the *profile* was changed, so the caller knows whether to
  ## save it. A refusal changes nothing and says why in `ch.problems`.
  case kind
  of peInsure: result = doInsure(p, inv, action, insurancePercent, ch)
  of peWishlistAdd: result = doWishlistAdd(p, action, ch)
  of peWishlistRemove: result = doWishlistRemove(p, action, ch)
  of peWishlistCategory: result = doWishlistCategory(p, action, ch)
  of peFavourites: result = doFavourites(p, inv, action, ch)
  of pePinLock:
    # The only one of these that touches an item rather than the profile.
    discard doPinLock(inv, action, ch)
    result = false
  of peBind: result = doBind(p, inv, action, true, ch)
  of peUnbind: result = doBind(p, inv, action, false, ch)
  of peNone: result = false
