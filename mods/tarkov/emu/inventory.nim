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
  let id = action.field("item").asText("")
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
# Dispatch
# ---------------------------------------------------------------------------

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
  of "Examine", "ReadEncyclopedia":
    let id = action.field("item").asText("")
    var tpl = id
    let idx = indexOf(inv, id)
    if idx >= 0:
      tpl = field(inv.items.items[idx], "_tpl").asText(id)
    examined.add tpl
    result = true
  else:
    ch.problems.add "unhandled action: " & kind
    result = true
