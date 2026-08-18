## Messages.
##
## The client's inbox is a list of dialogs — one per trader, plus system — each
## holding messages, and some of those messages carry items. It is how a trader
## tells you a quest reward is waiting and how insurance gives your gear back,
## so it is not decoration: several systems have nowhere to put their output
## without it.
##
## Stored per profile in this mod's own store, under `mail.<profile id>`. Not in
## the profile document: the inbox grows without bound over a campaign, and
## every request that touches the profile would carry it.
##
## Redeeming an attachment **is** implemented, and the shape of a message is
## what makes it possible. A message that carries items owns a container: an id
## in `items.stash`, with every root reward item parented onto it and slotted
## `main`. That container id is the thing the client drags out of, and it is
## stored, so it is the same container after a restart.
##
## The refusal this module used to carry was that half a redemption is worse
## than none -- a player who drags a reward out and finds it gone next restart
## has lost it. The half that was missing was not the container; it was the
## ordinary inventory move working across the boundary, and that lives in
## `emu/redeem`. What is here is only the mailbox side of it: find a message,
## read what is still in it, take some of it out.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import ids

const KeyPrefix* = "mail."

type
  MessageKind* = enum
    ## The client's own numbering. `mkSystem` renders without a sender, which is
    ## what an insurance return or a server notice wants.
    mkUserMessage = 1
    mkNpcTrader = 2
    mkAuction = 3
    mkSystem = 4
    mkInsuranceReturn = 5
    mkQuestStart = 10
    mkQuestFail = 11
    mkQuestSuccess = 12

proc mailKey*(profileId: string): string = KeyPrefix & profileId

proc loadMail*(profileId: string): List =
  ## Every message for a profile, oldest first. An empty inbox is `[]`, not an
  ## error: a new profile has one.
  let stored = load(mailKey(profileId))
  if not stored.ok or stored.raw.len == 0:
    return newList()
  result = parseArray(stored.raw)
  if not result.ok:
    result = newList()

proc saveMail*(profileId: string; messages: List): bool =
  result = save(mailKey(profileId), text(messages)) == Ok

proc parented*(attachments, containerId: string): string =
  ## Re-parents the roots of an item tree onto a container.
  ##
  ## An item is a root here if nothing else in the same array is its parent --
  ## which is the only workable test, because the arrays arriving at this
  ## function come from three different places (a quest reward built by hand, an
  ## insurance return lifted out of a profile, a trader's gift) and only the
  ## middle one has parents worth believing. Mods and magazines keep the parent
  ## they came with; the rifle they hang off gets the message's container.
  ##
  ## `location` is dropped from the roots on purpose: the coordinates an
  ## insured rifle had in a 10x68 stash mean nothing in a mail window, and a
  ## position outside the container is an item drawn where it cannot be reached.
  let list = parseArray(attachments)
  if not list.ok:
    return "[]"
  var ids: seq[string] = @[]
  for i in 0 ..< list.len:
    ids.add field(list.items[i], "_id").asText("")
  var out1 = newList()
  for i in 0 ..< list.len:
    var d = parseObject(list.items[i])
    if not d.ok:
      continue
    let parent = get(d, "parentId").asText("")
    var inside = false
    if parent.len > 0:
      for id in ids:
        if id.len > 0 and id == parent:
          inside = true
    if not inside:
      setText(d, "parentId", containerId)
      setText(d, "slotId", "main")
      remove(d, "location")
    out1.add d
  result = text(out1)

proc newMessage*(sender, text1: string; kind: MessageKind; nowSeconds: int;
                 attachments: string = ""): Doc =
  ## One message. `attachments` is a raw JSON array of items when there are any;
  ## a message with an empty one is a message with no rewards, which is the
  ## common case and must not be reported as having them -- the client puts a
  ## badge on the inbox for messages with rewards and a wrong badge sends the
  ## player looking for something that is not there.
  result = newDoc()
  setText(result, "_id", newId())
  setText(result, "uid", sender)
  setNumber(result, "type", ord(kind))
  setNumber(result, "dt", nowSeconds)
  setText(result, "templateId", "")
  setText(result, "text", text1)
  let has = attachments.len > 0 and attachments != "[]"
  setBool(result, "hasRewards", has)
  setBool(result, "rewardCollected", false)
  if has:
    # The message's own container. Every root reward item is re-parented onto
    # it, which is what gives the client something to drag *from* -- an item
    # whose parent is a stash the profile no longer has (an insurance return is
    # exactly that) draws in no window at all.
    let container = newId()
    var box = newDoc()
    setText(box, "stash", container)
    setRaw(box, "data", parented(attachments, container))
    setRaw(result, "items", text(box))
    # 72 hours, the game's own default. A message whose items have no expiry is
    # one the client draws a blank timer on.
    setNumber(result, "maxStorageTime", 259200)
  setBool(result, "systemData", false)

proc deliver*(profileId, sender, text1: string; kind: MessageKind;
              nowSeconds: int; attachments: string = ""): bool =
  ## Appends a message and saves. The whole inbox is rewritten, which is the
  ## right trade at inbox sizes and the wrong one at a hundred thousand -- if
  ## that ever matters, the fix is a key per message, not a partial write.
  var messages = loadMail(profileId)
  messages.add newMessage(sender, text1, kind, nowSeconds, attachments)
  result = saveMail(profileId, messages)

proc dialogList*(profileId: string): string =
  ## The inbox screen: one entry per sender, with the newest message as its
  ## preview and an unread count.
  let messages = loadMail(profileId)
  var senders: seq[string] = @[]
  var newest: seq[string] = @[]
  var counts: seq[int] = @[]
  var waiting: seq[int] = @[]
  for i in 0 ..< messages.len:
    let m = whole(messages.items[i])
    let uid = m.field("uid").asText("")
    # A message still holding something is what puts the parcel badge on the
    # dialog. Counted rather than hard-coded to zero: a badge that never appears
    # sends a player who was posted an insurance return looking for it in the
    # wrong screen, and a badge that never clears sends them looking for
    # something they already took.
    let pending = m.field("hasRewards").asBool(false) and
                  not m.field("rewardCollected").asBool(false)
    var at = -1
    for k in 0 ..< senders.len:
      if senders[k] == uid:
        at = k
    if at < 0:
      senders.add uid
      newest.add messages.items[i]
      counts.add 1
      waiting.add (if pending: 1 else: 0)
    else:
      newest[at] = messages.items[i]
      counts[at] = counts[at] + 1
      if pending:
        waiting[at] = waiting[at] + 1

  var out1 = arr()
  for k in 0 ..< senders.len:
    var d = obj()
    put(d, "_id", senders[k])
    put(d, "type", ord(mkNpcTrader))
    put(d, "message", raw(newest[k]))
    put(d, "pinned", false)
    put(d, "new", 0)
    put(d, "attachmentsNew", waiting[k])
    put(d, "Users", arr())
    out1.add d
  result = done(out1).text

proc dialogView*(profileId, dialogId: string): string =
  ## Every message from one sender.
  let messages = loadMail(profileId)
  var out1 = arr()
  var withRewards = false
  for i in 0 ..< messages.len:
    let m = whole(messages.items[i])
    if dialogId.len > 0 and m.field("uid").asText("") != dialogId:
      continue
    if m.field("hasRewards").asBool(false):
      withRewards = true
    out1.add messages.items[i]
  var o = obj()
  put(o, "messages", out1)
  put(o, "profiles", arr())
  put(o, "hasMessagesWithRewards", withRewards)
  result = done(o).text

proc allAttachments*(profileId: string): string =
  ## Only the messages that carry something. The client's "collect all" screen.
  let messages = loadMail(profileId)
  var out1 = arr()
  for i in 0 ..< messages.len:
    let m = whole(messages.items[i])
    if m.field("hasRewards").asBool(false) and
       not m.field("rewardCollected").asBool(false):
      out1.add messages.items[i]
  var o = obj()
  put(o, "messages", out1)
  put(o, "profiles", arr())
  put(o, "hasMessagesWithRewards", out1.len > 0)
  result = done(o).text

# ---------------------------------------------------------------------------
# What redemption needs from the mailbox
# ---------------------------------------------------------------------------
#
# Three questions and one edit, kept here rather than in `emu/redeem` because
# they are all "what does a message look like" -- and a second module deciding
# that for itself is how the two drift apart.

proc indexOfMessage*(messages: List; messageId: string): int =
  result = -1
  for i in 0 ..< messages.len:
    if field(messages.items[i], "_id").asText("") == messageId:
      return i

proc attachmentsOf*(messages: List; index: int): List =
  ## What is still in a message, as an editable list. An empty list for a
  ## message that never had anything, which is a normal answer and not a fault:
  ## the client will happily ask to redeem out of a message it has already
  ## emptied, and that has to come back as "there is nothing there".
  result = newList()
  if index < 0 or index >= messages.len:
    return
  let data = field(messages.items[index], "items.data")
  if not data.found or not isArray(data):
    return
  let parsed = parseArray(data)
  if parsed.ok:
    result = parsed

proc containerOf*(messages: List; index: int): string =
  ## The message's own container id -- the parent every root reward carries.
  if index < 0 or index >= messages.len:
    return ""
  result = field(messages.items[index], "items.stash").asText("")

proc removeAttachments*(profileId, messageId: string;
                        ids: seq[string]): bool =
  ## Takes items out of a message, permanently.
  ##
  ## Called *after* the profile holding them has been saved, so that a crash in
  ## between leaves the items visible in the mailbox rather than nowhere. That
  ## ordering would duplicate them on a retry if nothing else prevented it --
  ## and something else does: a redeemed item keeps its id, so `emu/redeem`
  ## refuses to bring across an item the profile already has. Identity is the
  ## guard here, not ordering, because ordering cannot be both ways at once.
  var messages = loadMail(profileId)
  let mi = indexOfMessage(messages, messageId)
  if mi < 0:
    return false
  var m = parseObject(messages.items[mi])
  if not m.ok:
    return false
  var box = parseObject(getRaw(m, "items"))
  if not box.ok:
    return false
  let data = parseArray(getRaw(box, "data"))
  if not data.ok:
    return false
  var keep = newList()
  for i in 0 ..< data.len:
    let id = field(data.items[i], "_id").asText("")
    var drop = false
    for wanted in ids:
      if wanted == id:
        drop = true
    if not drop:
      keep.add data.items[i]
  setRaw(box, "data", text(keep))
  setRaw(m, "items", text(box))
  if keep.len == 0:
    # An emptied message keeps its text and loses its badge. Deleting it would
    # take the only record the player has of where the items came from.
    setBool(m, "rewardCollected", true)
    setBool(m, "hasRewards", false)
  messages.replaceAt(mi, text(m))
  result = saveMail(profileId, messages)
