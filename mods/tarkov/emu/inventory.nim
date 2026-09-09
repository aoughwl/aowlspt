## The inventory: everything the player does by dragging something.
##
## One endpoint carries all of it — `/client/game/profile/items/moving` — and
## the body is a list of actions to apply in order. Move, split, merge, fold,
## examine, tag, bind, discard. The response is not "ok": it is a *diff*, a list
## of the items that were created, changed and deleted, which the client applies
## to its own copy.
##
## That diff is the whole design constraint. The client has already drawn the
## result before the request goes out, so a server that answers correctly but
## describes the change wrongly leaves the two copies disagreeing, and the
## disagreement shows up several actions later as an item in two places. Every
## operation here records what it touched.
##
## Items are edited through `aowlspt/json`'s `Doc`/`List`, member-wise, so an
## item keeps every field this emulator does not model — and the client's items
## carry plenty, from `upd.Repairable` to firearm attachment trees.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import ids
import templates

type
  Change* = object
    ## What one batch of actions did, in the shape the response wants.
    created*: List
    changed*: List
    deleted*: seq[string]
    problems*: seq[string]

  Inventory* = object
    ## The profile's item list, taken apart. `dirty` says whether it needs
    ## writing back -- a batch of actions that all failed must not rewrite the
    ## profile, because rewriting is also how a corrupt edit becomes permanent.
    items*: List
    dirty*: bool

proc newChange*(): Change =
  Change(created: newList(), changed: newList(), deleted: @[], problems: @[])

proc openInventory*(itemsJson: string): Inventory =
  result = Inventory(items: parseArray(itemsJson), dirty: false)

proc indexOf*(inv: Inventory; id: string): int =
  ## Linear, and that is the honest choice: a stash of a few thousand items
  ## searched a handful of times per request is nothing, and an index would have
  ## to be rebuilt on every mutation to stay correct.
  result = -1
  for i in 0 ..< inv.items.len:
    if field(inv.items.items[i], "_id").asText("") == id:
      return i

proc itemAt*(inv: Inventory; index: int): Doc =
  if index < 0 or index >= inv.items.len:
    return Doc(fields: @[], ok: false)
  result = parseObject(inv.items.items[index])

proc childrenOf*(inv: Inventory; parentId: string): seq[string] =
  ## Direct children only. Recursion is the caller's, because "everything under
  ## this" and "what is in this slot" are different questions and conflating
  ## them is how deleting a rig deletes the wrong magazines.
  result = @[]
  for i in 0 ..< inv.items.len:
    if field(inv.items.items[i], "parentId").asText("") == parentId:
      result.add field(inv.items.items[i], "_id").asText("")

proc descendantsOf*(inv: Inventory; rootId: string): seq[string] =
  ## Everything beneath an item, depth-first. An explicit stack rather than
  ## recursion, and a visited check: a profile with a parent cycle in it would
  ## otherwise hang the server rather than report a bad profile.
  result = @[]
  var stack: seq[string] = @[rootId]
  var seen: seq[string] = @[]
  while stack.len > 0:
    let cur = stack[stack.len - 1]
    shrink(stack, stack.len - 1)
    var already = false
    for s in seen:
      if s == cur:
        already = true
    if already:
      continue
    seen.add cur
    let kids = childrenOf(inv, cur)
    for k in kids:
      result.add k
      stack.add k

proc rootOf*(inv: Inventory; id: string): string =
  ## The topmost ancestor of an item: walk `parentId` until something has none.
  ##
  ## Bounded by the size of the list, because a profile that already carries a
  ## cycle -- one written before the check below existed, or handed back by a
  ## client -- must make this return an answer rather than spin. The answer in
  ## that case is the last id seen, which is wrong and is still an answer.
  result = id
  var steps = 0
  while steps <= inv.items.len:
    let at = indexOf(inv, result)
    if at < 0:
      return
    let parent = field(inv.items.items[at], "parentId").asText("")
    if parent.len == 0:
      return
    result = parent
    inc steps

proc wouldCycle*(inv: Inventory; movingId, destId: string): bool =
  ## Would putting `movingId` inside `destId` make it its own ancestor?
  ##
  ## This is the check that was missing, and its absence destroyed profiles
  ## from one ordinary-looking request. `{"Action":"Move","item":X,"to":
  ## {"id":X}}` wrote `parentId: X` onto X and answered `err:0` -- and the same
  ## request naming the **stash** and something the stash holds made the
  ## inventory's root its own descendant. The client draws the stash by walking
  ## `parentId` down from the root, so what it draws afterwards is nothing, and
  ## nothing can undo it: the drag that would fix it has to reach an item the
  ## client can no longer see.
  ##
  ## So: walk up from the destination. If the item being moved is anywhere on
  ## that path -- including *being* the destination -- the move closes a loop.
  if movingId.len == 0 or destId.len == 0:
    return false
  if movingId == destId:
    return true
  var cur = destId
  var steps = 0
  while steps <= inv.items.len:
    if cur == movingId:
      return true
    let at = indexOf(inv, cur)
    if at < 0:
      return false
    let parent = field(inv.items.items[at], "parentId").asText("")
    if parent.len == 0:
      return false
    cur = parent
    inc steps
  # Ran out of steps, which means the list already has a cycle in it. Refusing
  # is the safe answer: the alternative is adding a second one.
  result = true

proc isRootContainer*(inv: Inventory; id: string): bool =
  ## Is this one of the containers the profile is built on?
  ##
  ## They are exactly the items with **no parent** -- the stash, the equipment
  ## root, the quest raid and quest stash containers and the sorting table --
  ## and that is how `emu/market` identifies them too, so neither module has to
  ## carry a list of ids that a profile template could change out from under it.
  ##
  ## The reason this is a separate question from `wouldCycle`: putting the
  ## stash inside the *equipment* root closes no loop at all. It passes every
  ## cycle check there is, and it still leaves a client that draws the stash by
  ## walking `parentId` down from the root with nothing to draw, and no drag
  ## that could undo it. `ApplyInventoryChanges` had the same hole and it was
  ## closed there first; `Move` and `Swap` are the other two ways in.
  if id.len == 0:
    return false
  let at = indexOf(inv, id)
  if at < 0:
    return false
  result = field(inv.items.items[at], "parentId").asText("").len == 0

proc wouldUproot*(inv: Inventory; movingId, destId: string): bool =
  ## Would this move give one of those containers a parent? A destination of
  ## nothing is not a move at all -- `applyLocation` leaves `parentId` alone
  ## when `to.id` is empty -- so it is only an uprooting when there is somewhere
  ## for it to go.
  if destId.len == 0:
    return false
  result = isRootContainer(inv, movingId)

# ---------------------------------------------------------------------------
# The operations
# ---------------------------------------------------------------------------

proc applyLocation(d: var Doc; to: JsonRef) =
  ## `to` is `{"id":..,"container":..,"location":{...}}`. A missing location is
  ## normal and means "into a slot", where position is not a thing -- writing a
  ## zero location there would put a rifle in the top-left of a slot that has no
  ## grid, which the client renders as an item it cannot pick up.
  let parent = to.field("id").asText("")
  let container = to.field("container").asText("")
  if parent.len > 0:
    setText(d, "parentId", parent)
  if container.len > 0:
    setText(d, "slotId", container)
  let loc = to.field("location")
  if loc.found and not isNull(loc):
    setRaw(d, "location", raw(loc))
  else:
    remove(d, "location")

proc doMove*(inv: var Inventory; action: JsonRef; ch: var Change): bool =
  let id = action.field("item").asText("")
  let idx = indexOf(inv, id)
  if idx < 0:
    ch.problems.add "move: no such item " & id
    return false
  let dest = action.field("to").field("id").asText("")
  if wouldCycle(inv, id, dest):
    ch.problems.add "move: that would put " & id & " inside itself"
    return false
  if wouldUproot(inv, id, dest):
    ch.problems.add "move: " & id & " is one of the containers this profile " &
                    "is built on and does not go inside anything"
    return false
  var d = itemAt(inv, idx)
  applyLocation(d, action.field("to"))
  inv.items.replaceAt(idx, text(d))
  inv.dirty = true
  ch.changed.add text(d)
  result = true

proc stackCount(d: Doc): int =
  let upd = get(d, "upd")
  if not upd.found:
    return 1
  result = upd.field("StackObjectsCount").asInt(1)

proc setStackCount(d: var Doc; count: int) =
  var upd = parseObject(getRaw(d, "upd"))
  if not upd.ok:
    upd = newDoc()
  setNumber(upd, "StackObjectsCount", count)
  setRaw(d, "upd", text(upd))

proc doSplit*(inv: var Inventory; action: JsonRef; ch: var Change): bool =
  ## Splitting makes a *new* item with its own id, and the client has already
  ## picked that id -- it is in the request. Generating one here instead would
  ## leave the two copies disagreeing about what the item is called.
  # `splitItem`, not `item`. Split is the one item action that does not name
  # its subject the way every other one does, which is exactly why this was
  # wrong: the two lines under it read `newItem` and `container` and are
  # correct, so the handler looked right and failed on every split.
  # Confirmed against seq 318 of `data/capture/raid1`:
  # `{Action: "Split", splitItem, newItem, container: {id, container}, count}`.
  let id = action.field("splitItem").asText("")
  let idx = indexOf(inv, id)
  if idx < 0:
    ch.problems.add "split: no such item " & id
    return false
  let wanted = action.field("count").asInt(0)
  if wanted <= 0:
    ch.problems.add "split: a count of " & $wanted & " is not a split"
    return false
  var src = itemAt(inv, idx)
  let have = stackCount(src)
  if wanted >= have:
    ch.problems.add "split: cannot take " & $wanted & " from a stack of " & $have
    return false

  var newId = action.field("newItem").asText("")
  if newId.len == 0:
    newId = ids.newId()
  var made = newDoc()
  setText(made, "_id", newId)
  setText(made, "_tpl", get(src, "_tpl").asText(""))
  applyLocation(made, action.field("container"))
  setStackCount(made, wanted)

  setStackCount(src, have - wanted)
  inv.items.replaceAt(idx, text(src))
  inv.items.add made
  inv.dirty = true
  ch.changed.add text(src)
  ch.created.add text(made)
  result = true

proc doMerge*(inv: var Inventory; action: JsonRef; ch: var Change): bool =
  ## The source is consumed. Its whole stack goes onto the target, and the
  ## stack limit is checked against the template rather than assumed -- merging
  ## past a limit produces a stack the client will not render.
  let srcId = action.field("item").asText("")
  let dstId = action.field("with").asText("")
  let si = indexOf(inv, srcId)
  let di = indexOf(inv, dstId)
  if si < 0 or di < 0:
    ch.problems.add "merge: " & (if si < 0: srcId else: dstId) & " is not here"
    return false
  var src = itemAt(inv, si)
  var dst = itemAt(inv, di)
  if get(src, "_tpl").asText("") != get(dst, "_tpl").asText(""):
    ch.problems.add "merge: those are different items"
    return false
  let total = stackCount(src) + stackCount(dst)
  let limit = itemStackLimit(get(dst, "_tpl").asText(""))
  if limit > 0 and total > limit:
    ch.problems.add "merge: " & $total & " is over the stack limit of " & $limit
    return false
  setStackCount(dst, total)
  inv.items.replaceAt(di, text(dst))
  inv.items.removeAt(si)
  inv.dirty = true
  ch.changed.add text(dst)
  ch.deleted.add srcId
  result = true

proc removeItem*(inv: var Inventory; id: string; ch: var Change): bool =
  ## Removes an item and everything inside it. Children first, so a failure
  ## partway through cannot leave a child pointing at a parent that is gone --
  ## an orphan in the item list is a profile the client refuses to load.
  let idx = indexOf(inv, id)
  if idx < 0:
    ch.problems.add "remove: no such item " & id
    return false
  let kids = descendantsOf(inv, id)
  for k in kids:
    let ki = indexOf(inv, k)
    if ki >= 0:
      inv.items.removeAt(ki)
      ch.deleted.add k
  let again = indexOf(inv, id)
  if again >= 0:
    inv.items.removeAt(again)
  ch.deleted.add id
  inv.dirty = true
  result = true

proc doRemove*(inv: var Inventory; action: JsonRef; ch: var Change): bool =
  result = removeItem(inv, action.field("item").asText(""), ch)

proc setUpdFlag(inv: var Inventory; id, key: string; value: bool;
                ch: var Change): bool =
  let idx = indexOf(inv, id)
  if idx < 0:
    ch.problems.add "no such item " & id
    return false
  var d = itemAt(inv, idx)
  var upd = parseObject(getRaw(d, "upd"))
  if not upd.ok:
    upd = newDoc()
  var sub = newDoc()
  setBool(sub, key, value)
  setRaw(upd, key, text(sub))
  setRaw(d, "upd", text(upd))
  inv.items.replaceAt(idx, text(d))
  inv.dirty = true
  ch.changed.add text(d)
  result = true

proc doFold*(inv: var Inventory; action: JsonRef; ch: var Change): bool =
  result = setUpdFlag(inv, action.field("item").asText(""), "Foldable",
                      action.field("value").asBool(true), ch)

proc doToggle*(inv: var Inventory; action: JsonRef; ch: var Change): bool =
  result = setUpdFlag(inv, action.field("item").asText(""), "Togglable",
                      action.field("value").asBool(true), ch)

proc doTag*(inv: var Inventory; action: JsonRef; ch: var Change): bool =
  let id = action.field("item").asText("")
  let idx = indexOf(inv, id)
  if idx < 0:
    ch.problems.add "tag: no such item " & id
    return false
  var d = itemAt(inv, idx)
  var upd = parseObject(getRaw(d, "upd"))
  if not upd.ok:
    upd = newDoc()
  var tag = newDoc()
  setText(tag, "Name", action.field("name").asText(""))
  setNumber(tag, "Color", action.field("color").asInt(0))
  setRaw(upd, "Tag", text(tag))
  setRaw(d, "upd", text(upd))
  inv.items.replaceAt(idx, text(d))
  inv.dirty = true
  ch.changed.add text(d)
  result = true

proc doSwap*(inv: var Inventory; action: JsonRef; ch: var Change): bool =
  ## Two items exchange places in one action, because doing it as two moves
  ## would put both in the same slot in between and the client validates that
  ## intermediate state.
  let id1 = action.field("item").asText("")
  let id2 = action.field("item2").asText("")
  let i1 = indexOf(inv, id1)
  let i2 = indexOf(inv, id2)
  if i1 < 0 or i2 < 0:
    ch.problems.add "swap: one of those items is not here"
    return false
  # Both destinations, against the tree as it is now. Checking the pair against
  # the state *after* the swap would be more exact and is not worth it: the
  # destructive cases -- either item landing inside the other's subtree -- are
  # all caught here, and a swap is two moves the client has already drawn.
  if wouldCycle(inv, id1, action.field("to").field("id").asText("")) or
     wouldCycle(inv, id2, action.field("to2").field("id").asText("")):
    ch.problems.add "swap: that would put an item inside itself"
    return false
  # And the same uprooting check on both halves. A swap of the stash with
  # something hanging off the equipment root closes no loop and destroys the
  # profile exactly as thoroughly.
  if wouldUproot(inv, id1, action.field("to").field("id").asText("")) or
     wouldUproot(inv, id2, action.field("to2").field("id").asText("")):
    ch.problems.add "swap: that would move one of the containers this " &
                    "profile is built on and they do not go inside anything"
    return false
  var a = itemAt(inv, i1)
  var b = itemAt(inv, i2)
  applyLocation(a, action.field("to"))
  applyLocation(b, action.field("to2"))
  inv.items.replaceAt(i1, text(a))
  inv.items.replaceAt(i2, text(b))
  inv.dirty = true
  ch.changed.add text(a)
  ch.changed.add text(b)
  result = true

proc doTransfer*(inv: var Inventory; action: JsonRef; ch: var Change): bool =
  ## Move part of a stack onto another stack without deleting the source.
  let srcId = action.field("item").asText("")
  let dstId = action.field("with").asText("")
  let count = action.field("count").asInt(0)
  let si = indexOf(inv, srcId)
  let di = indexOf(inv, dstId)
  if si < 0 or di < 0 or count <= 0:
    ch.problems.add "transfer: bad source, target or count"
    return false
  var src = itemAt(inv, si)
  var dst = itemAt(inv, di)
  let have = stackCount(src)
  if count > have:
    ch.problems.add "transfer: only " & $have & " to give"
    return false
  setStackCount(src, have - count)
  setStackCount(dst, stackCount(dst) + count)
  if stackCount(src) <= 0:
    inv.items.removeAt(si)
    ch.deleted.add srcId
    let dj = indexOf(inv, dstId)
    inv.items.replaceAt(dj, text(dst))
  else:
    inv.items.replaceAt(si, text(src))
    inv.items.replaceAt(di, text(dst))
    ch.changed.add text(src)
  ch.changed.add text(dst)
  inv.dirty = true
  result = true

# ---------------------------------------------------------------------------
# The client's own batch
# ---------------------------------------------------------------------------
#
# `ApplyInventoryChanges` is the action the client sends when it has rearranged
# the stash itself -- the sort button, and the tidy-up after a raid. It does not
# describe *operations*; it hands back **whole items**, already in their new
# places, and says "make it look like this".
#
# Which is exactly the request this server is not allowed to believe. An item
# document carries `upd.StackObjectsCount` and `_tpl` alongside the position,
# and a body that says "this stack of 12 roubles is now a stack of 12000000, and
# by the way it moved two cells left" is a well-formed sort. So the rule is a
# **whitelist**: the position and the handful of cosmetic `upd` members the
# client legitimately owns are taken, and everything else on the entry is left
# as the profile has it. An entry claiming a different template or a different
# stack size is refused outright rather than partially applied, because a client
# sending one is either out of step or lying and neither is a state to merge.
#
# The shape is marked *(unverified)* on purpose: the reference dump has an
# `APPLY_INVENTORY_CHANGES` action in `ItemEventActions` and **no request DTO**
# for it anywhere in `Models.Eft.*`, so the member names below are the client's
# well-known ones and not something the dump confirms. Both casings are read.
#
# `deletedItems` is refused rather than honoured, for the same reason: a delete
# arm on a batch endpoint whose shape cannot be checked against the reference is
# a way to lose a stash from one malformed body, and the client has `Remove` --
# which is checked -- for everything it actually needs to throw away.

proc updWhitelist(): seq[string] =
  ## The `upd` members a client's own layout pass may set. Every one of them is
  ## something the player toggles by hand and nothing on the list has a price,
  ## a count or a durability in it.
  result = @["Tag", "Foldable", "Togglable", "PinLockState", "Map"]

proc stackCountOf(j: JsonRef): int =
  let upd = j.field("upd")
  if not upd.found:
    return -1
  let v = upd.field("StackObjectsCount")
  if not v.found:
    return -1
  result = v.asInt(-1)

proc doApplyChanges*(inv: var Inventory; action: JsonRef;
                     ch: var Change): bool =
  var entries = action.field("changedItems")
  if not entries.found:
    entries = action.field("ChangedItems")
  var removed = action.field("deletedItems")
  if not removed.found:
    removed = action.field("DeletedItems")
  if removed.found and isArray(removed) and count(removed) > 0:
    ch.problems.add "apply: this server does not delete items from a batch; " &
                    "use Remove"
    return false
  if not entries.found or not isArray(entries):
    ch.problems.add "apply: nothing to apply"
    return false

  # ---- verify everything, including the tree the batch would produce ------
  #
  # The cycle check is done against a *simulated* parent map rather than one
  # entry at a time, because a batch can be a legal rotation -- A into B while B
  # moves out of A -- that each single step would refuse, and an illegal one
  # whose steps are each individually fine. Only the finished tree tells them
  # apart, and only checking the finished tree lets the whole batch be refused
  # instead of half-applied.
  var ids: seq[string] = @[]
  var parents: seq[string] = @[]
  for i in 0 ..< inv.items.len:
    ids.add field(inv.items.items[i], "_id").asText("")
    parents.add field(inv.items.items[i], "parentId").asText("")

  var touched: seq[int] = @[]
  let list = each(entries)
  for e in list:
    let id = e.field("_id").asText("")
    if id.len == 0:
      ch.problems.add "apply: an entry named no item"
      return false
    let at = indexOf(inv, id)
    if at < 0:
      # A batch may not *create* an item. Everything the client can legitimately
      # have made by now already exists here, and an entry for something that
      # does not is a client working from a profile this server never wrote.
      ch.problems.add "apply: no such item " & id
      return false
    let tpl = e.field("_tpl").asText("")
    if tpl.len > 0 and tpl != field(inv.items.items[at], "_tpl").asText(""):
      ch.problems.add "apply: " & id & " is not a " & tpl & " here"
      return false
    let claimed = stackCountOf(e)
    if claimed >= 0 and claimed != stackCount(itemAt(inv, at)):
      ch.problems.add "apply: that would change the stack on " & id &
                      " from " & $stackCount(itemAt(inv, at)) & " to " &
                      $claimed
      return false
    let parent = e.field("parentId")
    if parent.found:
      parents[at] = parent.asText("")
    touched.add at

  if touched.len == 0:
    ch.problems.add "apply: nothing to apply"
    return false

  for at in touched:
    var steps = 0
    var cur = parents[at]
    while cur.len > 0 and steps <= ids.len:
      if cur == ids[at]:
        ch.problems.add "apply: that layout would put " & ids[at] &
                        " inside itself"
        return false
      var next = ""
      for k in 0 ..< ids.len:
        if ids[k] == cur:
          next = parents[k]
      cur = next
      inc steps
    if steps > ids.len:
      ch.problems.add "apply: that layout has a loop in it"
      return false

  # And the five containers a profile is built on stay where they are.
  #
  # The cycle check above does not catch this and it is the same class of
  # damage: those five are exactly the items with no parent, and putting the
  # stash inside the *equipment* root closes no loop at all while still leaving
  # a client that draws the stash by walking down from the root with nothing to
  # draw. `emu/market` already defines the roots this way, for the same reason.
  for at in touched:
    if parents[at].len > 0 and
       field(inv.items.items[at], "parentId").asText("").len == 0:
      ch.problems.add "apply: " & ids[at] &
                      " is one of the containers this profile is built on " &
                      "and does not go inside anything"
      return false

  # ---- act ---------------------------------------------------------------
  let names = updWhitelist()
  for e in list:
    let id = e.field("_id").asText("")
    let at = indexOf(inv, id)
    if at < 0:
      continue
    var d = itemAt(inv, at)
    let parent = e.field("parentId")
    if parent.found:
      setText(d, "parentId", parent.asText(""))
    let slot = e.field("slotId")
    if slot.found:
      setText(d, "slotId", slot.asText(""))
    let loc = e.field("location")
    if loc.found and not isNull(loc):
      setRaw(d, "location", raw(loc))
    elif loc.found:
      remove(d, "location")
    let upd = e.field("upd")
    if upd.found:
      var kept = parseObject(getRaw(d, "upd"))
      if not kept.ok:
        kept = newDoc()
      for name in names:
        let v = upd.field(name)
        if v.found:
          setRaw(kept, name, raw(v))
      setRaw(d, "upd", text(kept))
    inv.items.replaceAt(at, text(d))
    inv.dirty = true
    ch.changed.add text(d)
  result = true

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

proc templateOf(inv {.byref.}: Inventory; id: string): string =
  ## The template an examined id refers to, falling back to the id itself.
  ##
  ## The fallback is deliberate: the client examines items it has seen but does
  ## not own -- on a trader's shelf, in a flea offer -- and for those the id it
  ## sends already *is* a template id. Refusing the ones that are not in the
  ## inventory would lose exactly the examinations that unlock the handbook.
  result = id
  let idx = indexOf(inv, id)
  if idx >= 0:
    result = field(inv.items.items[idx], "_tpl").asText(id)

proc applyAction*(inv: var Inventory; action: JsonRef; ch: var Change;
                  examined: var seq[string]): bool =
  ## One action. An unknown action is *not* an error: the client sends actions
  ## this emulator has never heard of, and answering "bad request" to one of
  ## them stops the whole batch -- including the moves in it that were fine.
  ## It is recorded and skipped.
  let kind = action.field("Action").asText("")
  case kind
  of "Move": result = doMove(inv, action, ch)
  of "Split": result = doSplit(inv, action, ch)
  of "Merge": result = doMerge(inv, action, ch)
  of "Transfer": result = doTransfer(inv, action, ch)
  of "Remove", "Discard": result = doRemove(inv, action, ch)
  of "Fold": result = doFold(inv, action, ch)
  of "Toggle": result = doToggle(inv, action, ch)
  of "Tag": result = doTag(inv, action, ch)
  of "Swap": result = doSwap(inv, action, ch)
  of "ApplyInventoryChanges": result = doApplyChanges(inv, action, ch)
  of "Examine":
    examined.add templateOf(inv, action.field("item").asText(""))
    result = true
  of "ReadEncyclopedia":
    # Not a spelling of `Examine`. The client sends `ids`, an array, and it can
    # be empty -- seq 341 of `data/capture/raid1` is exactly
    # `{"Action":"ReadEncyclopedia","ids":[]}`. Sharing the `Examine` branch
    # read `item`, found nothing, and then recorded the empty string as a
    # template the player had examined.
    let ids = action.field("ids")
    if isArray(ids):
      let elems = each(ids)
      for e in elems:
        let id = e.asText("")
        if id.len > 0:
          examined.add templateOf(inv, id)
    result = true
  else:
    # The batch is not aborted -- that part was right, and answering "bad
    # request" to one unknown action throws away the moves in the same batch
    # that were fine. What was wrong is that `true` was the *whole* answer:
    # the caller reads it as "applied", so an entire unimplemented system
    # returns `err:0` and looks like it works.
    #
    # So the answer stays `true` and the problem is made impossible to miss.
    # `ch.problems` reaches two places -- a `warn` line per problem in
    # `onItemsMoving`, and the response's `warnings` array, which the client
    # shows the player. The message says what this server did with the action
    # rather than only naming it, because "unhandled action: Foo" reads as a
    # note and "nothing was done" reads as the failure it is.
    #
    # An action with no `Action` member at all is called out separately: that
    # is a body this server could not even classify, and reporting it as an
    # action named "" sends whoever reads the log looking for a feature.
    if kind.len == 0:
      ch.problems.add "an action in this batch carried no `Action` name, so " &
                      "it could not be identified and nothing was done for it"
    else:
      ch.problems.add "this server does not implement the action '" & kind &
                      "', so nothing was done for it; the rest of the batch " &
                      "was applied"
    result = true
