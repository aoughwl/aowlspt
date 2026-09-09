## Taking an item out of a message.
##
## The client does not have a "redeem" endpoint. Dragging a reward out of the
## mail window, and pressing "receive all" in it, both come down
## `/client/game/profile/items/moving` as an ordinary `Move` — the only thing
## marking them out is `fromOwner: {"id": <message id>, "type": "Mail"}`. So
## redemption is not a feature bolted onto the inventory; it is the inventory
## move, with one extra step in front of it: the item is not in the profile yet,
## so it has to be brought across before it can be placed.
##
## Two failure modes govern the design, and they pull in opposite directions.
##
## **Collected twice.** A retried request, a client that sends the batch again,
## a crash between the two writes. Guarded by *identity*: a reward keeps its own
## `_id` when it crosses into the profile, so "is this already in the
## inventory?" is a complete answer to "has this already been redeemed?". No
## ordering of the two writes can give that, which is why it is not attempted
## with ordering.
##
## **Gone after a restart.** Guarded by *ordering*: the mailbox is not edited
## during the move at all. The removals are staged, and committed only once the
## caller has saved the profile that now holds the items. A crash in between
## leaves the reward sitting in the mailbox where the player can see it, and the
## retry is refused duplication by the identity check above.
##
## The staging is a module-level list rather than a return value because the
## commit point is several layers up — the batch handler saves the profile once,
## after every action in the request — and threading a list of pending mailbox
## edits through `applyAction` would put mail in the signature of every
## inventory operation that has nothing to do with it.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import inventory
import grid
import mail

type
  Pending = object
    profileId: string
    messageId: string
    itemIds: seq[string]

var gPending: seq[Pending] = @[]

# ---------------------------------------------------------------------------
# Recognising one
# ---------------------------------------------------------------------------

proc mailSource*(action: JsonRef): string =
  ## The message an action takes its item out of, or "" when the item is
  ## already in the profile and this is an ordinary move.
  let owner = action.field("fromOwner")
  if not owner.found or isNull(owner):
    return ""
  if owner.field("type").asText("") != "Mail":
    return ""
  result = owner.field("id").asText("")

# ---------------------------------------------------------------------------
# Placing it
# ---------------------------------------------------------------------------

proc stashTemplate(inv: Inventory; stashId: string): string =
  let at = indexOf(inv, stashId)
  if at < 0:
    return ""
  result = field(inv.items.items[at], "_tpl").asText("")

proc place(d: var Doc; to: JsonRef; inv: Inventory; stashId: string;
           ch: var Change): bool =
  ## Where the redeemed item lands.
  ##
  ## The client's `to` when the player dragged it somewhere, and a first-fit
  ## cell in the stash when it did not send one — which is what "receive all"
  ## does: it names the destination container and leaves the arithmetic to the
  ## server. Refused when the stash is full, because an item without a free cell
  ## is drawn on top of another one and cannot be picked up, and the message it
  ## came from is about to be emptied.
  var parent = to.field("id").asText("")
  var container = to.field("container").asText("")
  if parent.len == 0:
    parent = stashId
  if container.len == 0:
    container = "hideout"
  setText(d, "parentId", parent)
  setText(d, "slotId", container)

  let loc = to.field("location")
  if loc.found and not isNull(loc):
    setRaw(d, "location", raw(loc))
    return true

  if container != "hideout" and container != "main":
    # A slot -- a holster, a headwear slot -- has no grid, and writing a
    # position into one puts the item at the top-left of something that has no
    # top-left.
    remove(d, "location")
    return true

  var g = stashGrid(stashTemplate(inv, parent))
  markOccupied(g, text(inv.items), parent)
  let spot = findSpace(g, get(d, "_tpl").asText(""))
  if not spot.ok:
    ch.problems.add "there is no room in the stash for that reward"
    return false
  setRaw(d, "location", locationJson(spot))
  result = true

# ---------------------------------------------------------------------------
# The move
# ---------------------------------------------------------------------------

proc subtreeOf(items: List; rootId: string): seq[int] =
  ## The indices of a root and everything beneath it, breadth-first, with a
  ## visited check: a reward array with a parent cycle in it would otherwise
  ## spin here rather than report a bad message.
  result = @[]
  var frontier: seq[string] = @[rootId]
  var seen: seq[string] = @[]
  while frontier.len > 0:
    let cur = frontier[frontier.len - 1]
    shrink(frontier, frontier.len - 1)
    var already = false
    for s in seen:
      if s == cur:
        already = true
    if already:
      continue
    seen.add cur
    for i in 0 ..< items.len:
      let id = field(items.items[i], "_id").asText("")
      if id == cur:
        result.add i
      elif field(items.items[i], "parentId").asText("") == cur:
        frontier.add id

proc redeem*(inv: var Inventory; profileId, stashId: string; action: JsonRef;
             ch: var Change): bool =
  ## One reward, out of a message and into the profile.
  ##
  ## Nothing is written to the mailbox here. See `commitRedemptions`.
  let messageId = mailSource(action)
  let itemId = action.field("item").asText("")
  if messageId.len == 0 or itemId.len == 0:
    ch.problems.add "a mail move named no message or no item"
    return false

  var usable = true
  var messages = loadMail(profileId, usable)
  if not usable:
    # The mailbox is there and could not be read. Staging a removal against an
    # empty list would commit an empty mailbox over a full one.
    return false
  let mi = indexOfMessage(messages, messageId)
  if mi < 0:
    ch.problems.add "there is no message " & messageId
    return false
  let rewards = attachmentsOf(messages, mi)
  let picked = subtreeOf(rewards, itemId)

  if indexOf(inv, itemId) >= 0:
    # Already here. Not an error and not a second copy: this is the retried
    # request, and the honest answer is to do nothing and say so. Whatever the
    # message still holds of that tree is staged for removal, so a mailbox
    # commit missed the first time round still happens -- and it is the whole
    # subtree, because leaving a rifle's mods behind in an emptied message
    # leaves items in there with no parent to hang off.
    if picked.len > 0:
      var stale: seq[string] = @[]
      for k in 0 ..< picked.len:
        stale.add field(rewards.items[picked[k]], "_id").asText("")
      gPending.add Pending(profileId: profileId, messageId: messageId,
                           itemIds: stale)
    ch.problems.add "that reward has already been collected"
    return true

  if picked.len == 0:
    ch.problems.add "message " & messageId & " no longer holds " & itemId
    return false

  # The root first, so that its placement is decided against a stash that does
  # not yet contain its own children -- and so a refusal costs nothing, because
  # nothing has been added.
  var root = parseObject(rewards.items[picked[0]])
  if not root.ok:
    ch.problems.add "that reward is not a readable item"
    return false
  if not place(root, action.field("to"), inv, stashId, ch):
    return false

  var taken: seq[string] = @[]
  inv.items.add text(root)
  ch.created.add text(root)
  taken.add itemId
  for k in 1 ..< picked.len:
    # Children cross unchanged. Their parent is the root or another child, both
    # of which came with them, so the tree is intact on the far side -- and
    # rewriting a mod's `slotId` on the way is how a rifle arrives with its
    # sight in the magazine well.
    inv.items.add rewards.items[picked[k]]
    ch.created.add rewards.items[picked[k]]
    taken.add field(rewards.items[picked[k]], "_id").asText("")
  inv.dirty = true

  gPending.add Pending(profileId: profileId, messageId: messageId,
                       itemIds: taken)
  result = true

# ---------------------------------------------------------------------------
# Committing
# ---------------------------------------------------------------------------

proc commitRedemptions*() =
  ## Empties the redeemed items out of their messages. Called by the batch
  ## handler *after* the profile has been saved, and only then: this is the
  ## write that makes the reward unreachable from the mailbox, so it must not
  ## happen while the only other copy of it is in memory.
  for p in gPending:
    if not removeAttachments(p.profileId, p.messageId, p.itemIds):
      # Left in the mailbox. The player sees a reward they already have, which
      # is confusing; `redeem` refuses to hand it over twice, which is the part
      # that matters.
      warn "could not empty message " & p.messageId & " after redeeming " &
           $p.itemIds.len & " item(s)"
  gPending = @[]

proc discardRedemptions*() =
  ## Drops the staged mailbox edits without applying them. For the path where
  ## the profile could not be saved: the items never arrived, so the message
  ## must keep them.
  gPending = @[]

proc pendingRedemptions*(): int = gPending.len
