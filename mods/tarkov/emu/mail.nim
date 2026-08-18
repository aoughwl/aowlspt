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
## Redeeming an attachment is **not implemented** and says so rather than
## pretending. Moving an item out of a message means the item has to exist in a
## container the client can drag from, with the message as its parent, and then
## the ordinary inventory move has to work across that boundary. Half of that is
## worse than none: a player who drags a reward out and finds it gone next
## restart has lost it.

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
    setRaw(result, "items", "{\"stash\":\"" & newId() & "\",\"data\":" &
                            attachments & "}")
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
  for i in 0 ..< messages.len:
    let m = whole(messages.items[i])
    let uid = m.field("uid").asText("")
    var at = -1
    for k in 0 ..< senders.len:
      if senders[k] == uid:
        at = k
    if at < 0:
      senders.add uid
      newest.add messages.items[i]
      counts.add 1
    else:
      newest[at] = messages.items[i]
      counts[at] = counts[at] + 1

  var out1 = arr()
  for k in 0 ..< senders.len:
    var d = obj()
    put(d, "_id", senders[k])
    put(d, "type", ord(mkNpcTrader))
    put(d, "message", raw(newest[k]))
    put(d, "pinned", false)
    put(d, "new", 0)
    put(d, "attachmentsNew", 0)
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
